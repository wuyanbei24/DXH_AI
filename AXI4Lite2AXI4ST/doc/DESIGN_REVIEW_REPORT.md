# AXI4-Lite ↔ AXI4-Stream 桥接设计 Review 报告

> **Review 日期**：2026-07-28
> **Review 版本**：V3（2026-07-25 XPM FIFO 版）
> **修正版本**：V4（2026-07-28 Review 修正版）
> **Review 范围**：`axi4lite2axist.v`、`axist2native.v`、`axi_lite_stream_bridge.v`、`tb_axi_lite_stream_frame.v`

---

## 一、缺陷摘要

| 严重度 | 数量 | 说明 |
|--------|------|------|
| **致命（Critical）** | 3 | 系统无法正常工作，编译失败或逻辑死锁 |
| **高（High）** | 5 | 功能错误或综合失败 |
| **中（Medium）** | 5 | 设计健壮性不足，协议不规范 |
| **低（Low）** | 3 | 代码风格、可移植性、测试覆盖 |

---

## 二、致命缺陷（Critical）

### C-01：axist2native RX 首拍在 S_IDLE 被消耗，命令帧永远无法正确解析

**文件**：`axist2native.v`
**位置**：S_IDLE / S_RX_HEAD 状态交界

**问题描述**：

`S_IDLE` 状态通过时序逻辑置位 `s_axis_cmd_tready <= 1'b1`，同时组合逻辑判断 `s_axis_cmd_tvalid` 为高时转移至 `S_RX_HEAD`。由于 `tready=1` 且 `tvalid=1`，AXI-Stream 握手成立，**包头拍在 `S_IDLE` 被消耗（handshake 完成，上游切换到下一拍数据）**。

当状态推进到 `S_RX_HEAD` 时，总线上呈现的是**第二拍（净荷首拍）**，而非包头。此时 `s_axis_cmd_tdata[31:24]` 检查的是净荷数据而非魔数 `8'hAA`，校验必然失败，状态回退至 `S_IDLE`，命令帧被丢弃。

**时序追踪**：
```
Cycle N  : curr_state=S_IDLE,     tready=1, tvalid=1, tdata=HEADER{AA,01,03,00}
           → 握手成立，包头拍被消耗。next_state=S_RX_HEAD
Cycle N+1: curr_state=S_RX_HEAD,  tready=1, tdata=PAYLOAD_0(AWADDR)
           → tdata[31:24]=AWADDR[31:24] ≠ 0xAA → next_state=S_IDLE → 帧丢弃！
```

**影响**：所有命令帧永远无法被 `axist2native` 正确接收，系统完全不工作。

**修正建议**：
- 方案 A（推荐）：在 `S_IDLE` 不置位 `tready`，改为在 `S_RX_HEAD` 首次置位 `tready` 以接收包头拍。
- 方案 B：合并 `S_IDLE` 和 `S_RX_HEAD`，在 `S_IDLE` 中直接完成包头校验和类型解析。

---

### C-02：axi4lite2axist RX 帧类型从错误拍读取，响应帧永远无法正确解析

**文件**：`axi4lite2axist.v`
**位置**：RX 状态机 `RX_WAIT_HEAD` / `RX_WAIT_TYPE`

**问题描述**：

与 C-01 同源的设计缺陷。`RX_WAIT_HEAD` 状态下 `s_axis_rsp_tready=1`（由 `assign` 驱动），当响应帧包头到达时握手成立，包头拍被消耗。状态转移到 `RX_WAIT_TYPE` 后，总线上呈现的已是净荷拍。

在 `RX_WAIT_TYPE` 中：
```verilog
rx_type <= s_axis_rsp_tdata[23:16];  // 读取的是净荷拍的 [23:16]，不是包头的帧类型！
```

对于写响应帧，净荷为 `{30'h0, BRESP[1:0]}`，其 `[23:16]` 位为 `8'h00`，不等于 `FRAME_TYPE_WR_RSP(8'h11)` 或 `FRAME_TYPE_RD_RSP(8'h12)`，帧被判定为未知类型而丢弃。

**影响**：所有响应帧永远无法被 `axi4lite2axist` 正确接收，BRSP/RRSP FIFO 永远为空，AXI4-Lite B/R 通道无响应，**系统死锁**。

**修正建议**：
- 方案 A（推荐）：在 `RX_WAIT_HEAD` 的时序逻辑中同步锁存帧类型和净荷长度，消除 `RX_WAIT_TYPE` 状态。
  ```verilog
  RX_WAIT_HEAD: begin
      if (s_hs && (s_axis_rsp_tdata[31:24] == FRAME_MAGIC_HEAD)) begin
          rx_type <= s_axis_rsp_tdata[23:16];   // 同拍锁存
          rx_need <= s_axis_rsp_tdata[15:8];     // 同拍锁存
      end
  end
  ```
- 方案 B：不在 `RX_WAIT_HEAD` 消耗数据（tready=0），改为在 `RX_WAIT_TYPE` 同时校验魔数和类型。

---

### C-03：`s_axis_rsp_tready` 声明为 `output reg` 但由 `assign` 驱动

**文件**：`axi4lite2axist.v`
**位置**：端口声明 与 RX 反压逻辑

**问题描述**：

端口声明：
```verilog
output reg  s_axis_rsp_tready
```

驱动逻辑：
```verilog
assign s_axis_rsp_tready = !rx_tail_block;
```

在 Verilog-2001 中，`reg` 类型信号不能用 `assign`（连续赋值）驱动，只能在 `always` 过程块中赋值。这将导致**编译/综合直接报错**，代码无法通过 Vivado 的 elaboration 阶段。

**修正方案**：将端口声明改为 `output wire`：
```verilog
output wire  s_axis_rsp_tready
```

---

## 三、高严重度缺陷（High）

### H-01：axist2native TX 状态机仅检查 tready 而未检查 tvalid&&tready 握手

**文件**：`axist2native.v`
**位置**：第二段组合逻辑，`S_TX_HEAD` / `S_TX_PAYLOAD` / `S_TX_TAIL` 转移条件

**问题描述**：

```verilog
S_TX_HEAD:    if (m_axis_rsp_tready) next_state = S_TX_PAYLOAD;
S_TX_PAYLOAD: if (m_axis_rsp_tready) next_state = S_TX_TAIL;
S_TX_TAIL:    if (m_axis_rsp_tready) next_state = S_IDLE;
```

TX 输出信号（`m_axis_rsp_tvalid`、`m_axis_rsp_tdata`、`m_axis_rsp_tlast`）均为时序逻辑驱动（第三段 `always @(posedge aclk)`），输出比状态滞后一拍。当状态进入 `S_TX_HEAD` 且 `tready=1` 时，状态立即推进到 `S_TX_PAYLOAD`，但此时 `tvalid` 尚未置位（下一拍才生效），**AXI-Stream 握手实际未发生**。

若 `tready` 在输出延迟期间变为 0，已设置的输出数据会被下一状态的输出覆盖，**导致响应帧拍丢失**。

**影响**：在 `tready` 波动场景下（如 FIFO 接近满时），响应帧可能丢拍，帧格式损坏。

**修正建议**：TX 发送阶段改为组合输出（与 `axi4lite2axist` TX 一致），或在转移条件中加入 `tvalid` 检查。

---

### H-02：XPM FIFO 深度 C_FIFO_DEPTH=4 低于 Xilinx XPM 最小值

**文件**：`axi4lite2axist.v`
**位置**：所有 6 组 `xpm_fifo_sync` 实例

**问题描述**：

设计默认 `C_FIFO_DEPTH = 4`，但根据 Xilinx UG953（Vivado 2018.3）规定，`xpm_fifo_sync` 的 `FIFO_WRITE_DEPTH` 最小值为 **16**（须为 2 的幂，允许值：16, 32, 64, ...）。

深度为 4 将导致 Vivado 综合阶段 **报错并终止**。

**修正方案**：将默认值改为 16：
```verilog
parameter C_FIFO_DEPTH = 16
```

---

### H-03：XPM 参数 `CASCADE_HEIGHT` 在 Vivado 2018.3 中不存在

**文件**：`axi4lite2axist.v`
**位置**：所有 `xpm_fifo_sync` 实例化的参数列表

**问题描述**：

设计文档声明"完全兼容 Vivado 2018.3 + Zynq-7020 平台"，但 `CASCADE_HEIGHT` 参数在 Vivado 2020.1 之后才引入。在 Vivado 2018.3 中使用此参数将导致 elaboration 报错。

**修正方案**：删除 `.CASCADE_HEIGHT(0)` 参数行，或添加条件编译：
```verilog
`ifdef VIVADO_2020_PLUS
    .CASCADE_HEIGHT  (0),
`endif
```

---

### H-04：XPM 参数名 `SIM_ASSERT_ON` 错误

**文件**：`axi4lite2axist.v`
**位置**：所有 `xpm_fifo_sync` 实例

**问题描述**：

`xpm_fifo_sync` 的仿真断言参数正确名称为 `SIM_ASSERT_CHK`，而非 `SIM_ASSERT_ON`。参数名错误将被 Vivado 视为无效参数，可能导致 elaboration 警告或错误。

**修正方案**：
```verilog
.SIM_ASSERT_CHK  (0)   // 0=disable, 1=enable
```

---

### H-05：axist2native `reg_index` 硬编码 2 位，不支持 C_REG_NUM > 4

**文件**：`axist2native.v`
**位置**：地址索引计算

**问题描述**：

```verilog
wire [1:0] reg_index = addr_in_range ? addr_reg[3:2] : 2'd0;
```

`reg_index` 硬编码为 2 位，仅从 `addr_reg[3:2]` 提取，最多寻址 4 个寄存器。若 `C_REG_NUM` 参数增大（如 8、16），高位地址被截断，实际只能访问前 4 个寄存器。

**修正方案**：使用 `$clog2` 动态计算位宽：
```verilog
localparam REG_IDX_W = $clog2(C_REG_NUM);
wire [REG_IDX_W-1:0] reg_index = addr_in_range ?
    addr_reg[REG_IDX_W+1:2] : {REG_IDX_W{1'b0}};
```

---

## 四、中等严重度缺陷（Medium）

### M-01：S_RESYNC 状态未实现，帧错误后存在帧失步风险

**文件**：`axist2native.v`
**位置**：`S_RX_TAIL` 错误处理

**问题描述**：

`DESIGN_CHANGELOG.md` 记录 D-10 修正方案为"增加 `S_RESYNC` 状态，丢弃到 `tlast` 再回 IDLE"，但代码中未定义 `S_RESYNC` 状态，帧尾错误直接回退 `S_IDLE`。

当包尾魔数校验失败但 `tlast` 未置位时，后续剩余拍会被误判为新帧的包头，导致帧同步丢失和连锁错误。

**修正建议**：添加 `S_RESYNC` 状态，在帧错误后持续丢弃数据直到检测到 `tlast`：
```verilog
S_RESYNC: begin
    s_axis_cmd_tready <= 1'b1;
    if (s_axis_cmd_tvalid && s_axis_cmd_tlast)
        next_state = S_IDLE;
end
```

---

### M-02：axist2native TX 输出滞后状态一拍，AXI-Stream 协议合规性问题

**文件**：`axist2native.v`
**位置**：第三段时序逻辑

**问题描述**：

TX 发送的 `m_axis_rsp_tvalid`/`m_axis_rsp_tdata`/`m_axis_rsp_tlast` 全部在 `always @(posedge aclk)` 中赋值，输出比状态延迟一拍。虽然在 `tready` 恒为 1 的直连场景下数据序列正确，但状态与输出不对齐，违反了典型的三段式 FSM 设计规范。

当设计被复用到 `tready` 可能波动的场景时，该时序错位将导致 H-01 中描述的数据丢失问题。

---

### M-03：axist2native 写命令始终返回 BRESP=OKAY，地址越界不报错

**文件**：`axist2native.v`
**位置**：`S_TX_PAYLOAD` 写响应构造

**问题描述**：

```verilog
S_TX_PAYLOAD: begin
    m_axis_rsp_tvalid <= 1'b1;
    if (is_write_cmd) begin
        m_axis_rsp_tdata <= {30'h0, 2'b00}; // BRESP = OKAY，始终返回 OK
    end
```

即使写地址越界（`addr_in_range=0`），BRESP 仍返回 `OKAY(2'b00)`。AXI4-Lite 规范要求地址越界时返回 `DECERR(2'b11)` 或 `SLVERR(2'b10)`。

**修正建议**：
```verilog
if (is_write_cmd) begin
    m_axis_rsp_tdata <= {30'h0, addr_in_range ? 2'b00 : 2'b11};
end
```

---

### M-04：axi4lite2axist R 通道 rresp 硬编码 OKAY，未传递实际响应

**文件**：`axi4lite2axist.v`
**位置**：R 通道输出逻辑

**问题描述**：

```verilog
if (rrsp_rd_en) begin
    s_axi_rdata  <= rrsp_dout[RRSP_FIFO_W-1:0];
    s_axi_rresp  <= 2'b00; // 硬编码 OKAY
    s_axi_rvalid <= 1'b1;
end
```

RRSP FIFO 仅存储 `rdata`（32 bit），不包含 `rresp`。即使 `axist2native` 返回非 OKAY 响应（修正 M-03 后），`rresp` 也无法传递。

**修正建议**：扩展 RRSP FIFO 位宽至 34 bit（32 data + 2 resp），或在读响应帧中增加 RRESP 字段。

---

### M-05：axist2native `addr_in_range` 比较逻辑在 C_REG_NUM 非 2 的幂时有隐患

**文件**：`axist2native.v`

**问题描述**：

```verilog
wire addr_in_range = (addr_reg[31:2] < C_REG_NUM);
```

当 `C_REG_NUM` 为非 2 的幂值时，比较在综合中会生成减法器，面积较大。更重要的是，`addr_reg[31:2]` 是 30 位与参数 `C_REG_NUM`（默认 4）比较，综合器会将 `C_REG_NUM` 扩展为 30 位常量，虽然功能正确但消耗不必要的比较资源。

**修正建议**：仅比较有效地址位：
```verilog
wire addr_in_range = (addr_reg[31:2+$clog2(C_REG_NUM)] == 0) &&
                     (addr_reg[1+$clog2(C_REG_NUM):2] < C_REG_NUM);
```

---

## 五、低严重度缺陷（Low）

### L-01：Testbench `wait()` + `@(posedge aclk)` 存在竞态风险

**文件**：`tb_axi_lite_stream_frame.v`
**位置**：`axi_lite_write` / `axi_lite_read` task

**问题描述**：

```verilog
wait(s_axi_awready);
@(posedge aclk);
s_axi_awvalid = 1'b0;
```

若 `s_axi_awready` 恰好在时钟上升沿同时变化，`wait()` 可能在当前沿解除，`@(posedge aclk)` 跳到下一沿，导致 `awvalid` 多保持一拍。推荐改为时钟同步轮询：

```verilog
while (!s_axi_awready) @(posedge aclk);
@(posedge aclk);
s_axi_awvalid = 1'b0;
```

---

### L-02：Testbench 缺少负面测试场景

**文件**：`tb_axi_lite_stream_frame.v`

**问题描述**：

当前测试用例仅覆盖正常路径：单写单读、分离握手、并发读写、字节选通、连续事务。缺少以下关键场景：
- 地址越界访问（寄存器地址超出 C_REG_NUM 范围）
- FIFO 满/背压场景
- 帧格式错误注入
- 复位期间事务行为
- 错误响应码验证

---

### L-03：XPM FIFO 实例化缺少 `RD_DATA_COUNT_WIDTH` 等参数显式声明

**文件**：`axi4lite2axist.v`

**问题描述**：

6 组 XPM FIFO 实例化中，部分参数依赖 XPM 默认值（如 `RD_DATA_COUNT_WIDTH`、`FIFO_READ_LATENCY`、`DOUT_RESET_VALUE`）。不同 Vivado 版本默认值可能不同，显式声明所有参数可提升可移植性。

---

## 六、设计文档与代码一致性问题

| 项目 | 文档描述 | 代码实际 | 偏差说明 |
|------|----------|----------|----------|
| RX 状态机 | 4 个状态：RX_WAIT_HEAD / RX_WAIT_TYPE / RX_PAYLOAD / RX_WAIT_TAIL | 同文档 | 但 RX_WAIT_HEAD → RX_WAIT_TYPE 之间存在拍消耗错位（C-02）|
| S_RESYNC | D-10 记录需增加 S_RESYNC 状态 | 代码中未实现，错误直接回 S_IDLE | 文档与代码不一致（M-01）|
| s_axis_rsp_tready | 端口声明为 `reg` | 实际由 `assign` 驱动 | 声明与驱动方式冲突（C-03）|
| FIFO 深度 | 参数 C_FIFO_DEPTH=4 | XPM 最小深度要求 16 | 默认参数不可用（H-02）|

---

## 七、总体评价与修正优先级

### V4 修正状态

| 编号 | 严重度 | 状态 | 修正说明 |
|------|--------|------|----------|
| C-01 | 致命 | **已修正** | `axist2native.v`：合并 S_IDLE 与 S_RX_HEAD，S_IDLE 同拍完成包头校验与类型锁存 |
| C-02 | 致命 | **已修正** | `axi4lite2axist.v`：合并 RX_WAIT_HEAD 与 RX_WAIT_TYPE，同拍校验魔数并锁存帧类型 |
| C-03 | 致命 | **已修正** | `axi4lite2axist.v`：`s_axis_rsp_tready` 声明改为 `output wire` |
| H-01 | 高 | **已修正** | `axist2native.v`：TX 输出改为组合逻辑，转移条件使用 `rsp_hs(tvalid&&tready)` |
| H-02 | 高 | **已修正** | 全部文件：`C_FIFO_DEPTH` 默认值改为 16 |
| H-03 | 高 | **已修正** | `axi4lite2axist.v`：删除所有 XPM 实例的 `CASCADE_HEIGHT` 参数 |
| H-04 | 高 | **已修正** | `axi4lite2axist.v`：删除所有 XPM 实例的 `SIM_ASSERT_ON` 参数 |
| H-05 | 高 | **已修正** | `axist2native.v`：`reg_index` 改为动态位宽 `REG_IDX_W`，支持 C_REG_NUM > 4 |
| M-01 | 中 | **已修正** | `axist2native.v`：新增 S_RESYNC 状态，帧错误后丢弃至 tlast |
| M-02 | 中 | **已修正** | `axist2native.v`：TX 输出改为组合逻辑（随 H-01 一并修正） |
| M-03 | 中 | **已修正** | `axist2native.v`：新增 addr_err 标志，地址越界返回 DECERR(2'b11) |
| M-04 | 中 | **已修正** | 读响应帧扩展为 4 拍（HEAD+RDATA+RRESP+TAIL），RRSP FIFO 扩展至 34 位 |
| M-05 | 中 | 保留 | 低优先级优化，功能正确 |
| L-01 | 低 | **已修正** | `tb_axi_lite_stream_frame.v`：`wait()` 改为 `while()` 时钟同步轮询 |
| L-02 | 低 | 保留 | 建议后续补充负面测试用例 |
| L-03 | 低 | 保留 | 建议后续显式声明所有 XPM 参数 |

### V4 帧格式变更

读响应帧由 3 拍扩展为 4 拍，新增 RRESP 净荷：

| 节拍 | 帧阶段 | tdata[31:0] | tlast |
|------|--------|-------------|-------|
| 1 | 包头 | `{8'hAA, 8'h12, 8'd2, 8'h00}` | 0 |
| 2 | 净荷1 | `RDATA[31:0]` | 0 |
| 3 | 净荷2 | `{30'h0, RRESP[1:0]}` | 0 |
| 4 | 包尾 | `{8'h55, 16'h0000, 8'h00}` | 1 |

1. **P0（阻塞性）**：C-01、C-02、C-03 —— 系统完全无法工作，必须首先修正
2. **P1（综合失败）**：H-02、H-03、H-04 —— 代码无法通过 Vivado 综合
3. **P2（功能缺陷）**：H-01、H-05、M-01、M-02 —— 影响功能正确性和鲁棒性
4. **P3（协议合规）**：M-03、M-04、M-05 —— AXI 协议合规性改进
5. **P4（质量提升）**：L-01、L-02、L-03 —— 测试覆盖和可维护性

### 核心问题根因分析

C-01 和 C-02 的根本原因相同：**三段式状态机中，IDLE/等待状态在置位 tready 的同时检测 tvalid 并转移状态，导致数据拍在转移前被消耗**。这是一个典型的 AXI-Stream 接收侧状态机设计陷阱：

```
错误模式：S_IDLE(tready=1) + tvalid=1 → 握手消耗数据 → 转移到 S_RX_HEAD → 已无数据可处理
正确模式：S_IDLE(tready=0) → 转移到 S_RX_HEAD(tready=1) → 握手消耗数据 → 处理数据
      或：S_IDLE(tready=1) → 握手消耗数据的同时完成数据处理 → 转移到下一状态
```

建议在修正时统一两个模块的 RX 状态机设计模式，确保数据拍的消耗与处理在同一状态内完成。

---

## 八、仿真验证结果补录（V5，2026-08-12）

原 V4 Review 的「四、验证状态」中仿真验证项为「[ ] 仿真验证（需用户在 Vivado 中执行）」。已完成 ModelSim SE-64 10.6d 行为级仿真（Vivado 2018.2 XPM 行为模型），结果如下：

### 8.1 仿真发现的 3 个新增缺陷（原 Review 未覆盖）

仿真复现阶段暴露 3 个硬件级缺陷，均位于 `axi4lite2axist.v` 的 AW/W → WRQ 配对与数据锁存通路，根因均关联 XPM `xpm_fifo_sync` FWFT 模式特性（详见 `SIMULATION_REPORT.md` 第五、六章）：

| 编号 | 严重度 | 缺陷 | 修正 |
|------|--------|------|------|
| S-01 | 高 | WRQ 重复配对（FWFT `empty` 滞后 → 配对脉冲双发） | `pair_armed` 单次配对锁 |
| S-02 | 高 | WDATA 整体滞后一笔（FWFT `dout` 在 rd/wr 同拍反映旧字头） | `aw_hold/wdata_hold/wstrb_hold` 保持寄存器 |
| S-03 | 高 | W FIFO 读-写碰撞（rd_en 与 wr_en 同拍弹出不可靠） | 配对弹出延后 1 拍（`pair_det → pair_pop`） |

### 8.2 仿真结论

全部 7 个测试用例通过（T1 基础写读 / T2 AW-W 分离 / T3 字节选通 / T4 并发仲裁 / T5 背靠背 / T6 越界 DECERR / T7 RRESP 端到端），**错误数 = 0**。设计功能正确，可进入综合/实现阶段。

> 新增缺陷均属「仿真才暴露的边界时序」类问题，正是原始 Review 标注「需仿真验证」的原因。完整根因、修正代码与结果见 `SIMULATION_REPORT.md` 与 `DESIGN_CHANGELOG.md`（V5）。
