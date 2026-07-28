# 完整帧格式版 AXI4-Lite ↔ AXI4-Stream 桥接设计

> **版本：V4（2026-07-28 Review 修正版）**
> 基于 V3（XPM FIFO 版）经完整 Review 后修正 16 项缺陷（含 3 项致命、5 项高危），详见末尾[设计变更记录](#八设计变更记录)。
> 完全兼容 **Vivado 2018.3 + Zynq-7020** 平台，全程 **Verilog-2001** 语法，三段式状态机实现。

---

## 一、设计概述

### 1.1 功能定位

本设计实现 AXI4-Lite 总线与 AXI4-Stream 总线之间的协议桥接，将 AXI4-Lite 读写事务封装为自定义帧格式通过 AXI4-Stream 通道传输，远端模块解帧后执行本地寄存器操作并回送响应帧。

典型应用场景：PS（Zynq ARM）通过 AXI4-Lite 访问远端 PL 寄存器，中间经 AXI4-Stream 链路（可接入 CDC、位宽转换、LVDS 传输等中间模块）。

### 1.2 模块层次

```
axi_lite_stream_bridge (顶层封装)
├── axi4lite2axist     (AXI4-Lite Slave → AXI4-Stream 命令组包 + 响应解包)
│   ├── AW FIFO (xpm_fifo_sync)   写地址通道缓存
│   ├── W  FIFO (xpm_fifo_sync)   写数据通道缓存
│   ├── WRQ FIFO (xpm_fifo_sync)  AW+W 配对组装
│   ├── RDQ FIFO (xpm_fifo_sync)  读地址缓存
│   ├── BRSP FIFO (xpm_fifo_sync) 写响应缓存
│   ├── RRSP FIFO (xpm_fifo_sync) 读响应缓存（含 RRESP）
│   ├── TX 状态机 (轮询仲裁 + 帧组包)
│   └── RX 状态机 (帧解包 + FIFO 分发)
└── axist2native       (AXI4-Stream 命令解包 → 寄存器读写 → 响应组包)
    ├── RX 状态机 (帧解包 + 命令执行)
    └── TX 组合输出 (响应帧组包)
```

### 1.3 参数列表

| 参数名 | 默认值 | 说明 |
|--------|--------|------|
| `C_S_AXI_DATA_WIDTH` | 32 | AXI4-Lite 数据位宽（固定 32） |
| `C_S_AXI_ADDR_WIDTH` | 32 | AXI4-Lite 地址位宽 |
| `C_AXIS_DATA_WIDTH` | 32 | AXI4-Stream 数据位宽（固定 32） |
| `C_REG_NUM` | 4 | axist2native 本地寄存器数量（1\~16） |
| `C_FIFO_DEPTH` | 16 | 所有 XPM FIFO 深度（须为 2 的幂，最小 16） |

---

## 二、统一 AXI4-Stream 帧格式规范

所有报文采用定长帧结构，单拍数据位宽 32bit，包尾拍同步置位 `tlast` 标识帧结束。

### 2.1 帧结构总览

| 帧阶段 | 拍数 | 核心作用 |
|--------|------|----------|
| 包头（SOF） | 固定 1 拍 | 帧头魔数同步 + 帧类型识别 + 净荷长度声明 |
| 净荷域 | 1\~3 拍 | 承载地址、数据、选通、响应等业务信息 |
| 包尾（EOF） | 固定 1 拍 | 帧尾魔数校验 + 帧状态标识，同步置 `tlast=1` |

### 2.2 字段编码定义

#### 包头字段（第 1 拍）

| 位域 | 位宽 | 定义 | 取值说明 |
|------|------|------|----------|
| `tdata[31:24]` | 8bit | 帧头魔数 | 固定 `8'hAA`，帧起始同步 |
| `tdata[23:16]` | 8bit | 帧类型 | `01`=写命令 / `02`=读命令 / `11`=写响应 / `12`=读响应 |
| `tdata[15:8]` | 8bit | 净荷长度 | 净荷域拍数 |
| `tdata[7:0]` | 8bit | 保留域 | 固定 `8'h00` |

#### 包尾字段（最后 1 拍，同步置 `tlast`）

| 位域 | 位宽 | 定义 | 取值说明 |
|------|------|------|----------|
| `tdata[31:24]` | 8bit | 帧尾魔数 | 固定 `8'h55`，帧完整性校验 |
| `tdata[23:8]` | 16bit | 保留域 | 固定 `16'h0000` |
| `tdata[7:0]` | 8bit | 帧状态 | `8'h00` 表示正常传输 |

### 2.3 四类帧完整定义

#### 写命令帧（AXI4-Lite → Native，共 5 拍，净荷长度 = 3）

| 节拍 | 帧阶段 | `tdata[31:0]` 内容 | `tlast` |
|------|--------|---------------------|---------|
| 1 | 包头 | `{8'hAA, 8'h01, 8'd3, 8'h00}` | 0 |
| 2 | 净荷 1 | `AWADDR[31:0]` | 0 |
| 3 | 净荷 2 | `WDATA[31:0]` | 0 |
| 4 | 净荷 3 | `{28'h0, WSTRB[3:0]}` | 0 |
| 5 | 包尾 | `{8'h55, 16'h0000, 8'h00}` | 1 |

#### 读命令帧（AXI4-Lite → Native，共 3 拍，净荷长度 = 1）

| 节拍 | 帧阶段 | `tdata[31:0]` 内容 | `tlast` |
|------|--------|---------------------|---------|
| 1 | 包头 | `{8'hAA, 8'h02, 8'd1, 8'h00}` | 0 |
| 2 | 净荷 1 | `ARADDR[31:0]` | 0 |
| 3 | 包尾 | `{8'h55, 16'h0000, 8'h00}` | 1 |

#### 写响应帧（Native → AXI4-Lite，共 3 拍，净荷长度 = 1）

| 节拍 | 帧阶段 | `tdata[31:0]` 内容 | `tlast` |
|------|--------|---------------------|---------|
| 1 | 包头 | `{8'hAA, 8'h11, 8'd1, 8'h00}` | 0 |
| 2 | 净荷 1 | `{30'h0, BRESP[1:0]}` | 0 |
| 3 | 包尾 | `{8'h55, 16'h0000, 8'h00}` | 1 |

#### 读响应帧（Native → AXI4-Lite，共 4 拍，净荷长度 = 2）

| 节拍 | 帧阶段 | `tdata[31:0]` 内容 | `tlast` |
|------|--------|---------------------|---------|
| 1 | 包头 | `{8'hAA, 8'h12, 8'd2, 8'h00}` | 0 |
| 2 | 净荷 1 | `RDATA[31:0]` | 0 |
| 3 | 净荷 2 | `{30'h0, RRESP[1:0]}` | 0 |
| 4 | 包尾 | `{8'h55, 16'h0000, 8'h00}` | 1 |

> **V4 变更**：读响应帧由 3 拍扩展为 4 拍，新增 `RRESP` 独立净荷拍，实现端到端响应码传递。写响应和读响应均支持 `DECERR(2'b11)` 地址越界报错。

---

## 三、模块一：axi4lite2axist（FIFO 解耦 + 轮询仲裁）

### 3.1 架构框图

```
AXI4-Lite Slave                    AXI4-Stream Master
┌─────────┐    ┌──────┐    ┌───────┐    ┌─────────┐
│ AW ch   │───▶│ AW   │───▶│       │    │         │
│ W  ch   │───▶│ W    │───▶│ WRQ   │───▶│   TX    │───▶ cmd_tdata
│ B  ch   │◀───│ BRSP │◀───│       │    │ (轮询)  │     cmd_tvalid
└─────────┘    └──────┘    └───────┘    └─────────┘     cmd_tlast
                                            ▲
┌─────────┐    ┌──────┐              ┌─────┴────┐
│ AR ch   │───▶│ RDQ  │──────────────│   RX     │◀─── rsp_tdata
│ R  ch   │◀───│ RRSP │◀─────────────│ (按类型) │     rsp_tvalid
└─────────┘    └──────┘              └──────────┘     rsp_tlast
```

### 3.2 FIFO 配置

全部 6 组 FIFO 采用 Xilinx XPM 宏 `xpm_fifo_sync`，FWFT 模式，`distributed` 存储类型。

| FIFO | 数据位宽 | 内容 | 深度 |
|------|----------|------|------|
| AW | 35 bit | `{awaddr[31:0], awprot[2:0]}` | C_FIFO_DEPTH |
| W | 36 bit | `{wdata[31:0], wstrb[3:0]}` | C_FIFO_DEPTH |
| WRQ | 68 bit | `{addr[31:0], data[31:0], strb[3:0]}` | C_FIFO_DEPTH |
| RDQ | 32 bit | `araddr[31:0]` | C_FIFO_DEPTH |
| BRSP | 2 bit | `bresp[1:0]` | C_FIFO_DEPTH |
| RRSP | 34 bit | `{rdata[31:0], rresp[1:0]}` | C_FIFO_DEPTH |

**AW/W 解耦机制**：AW 和 W 通道分别独立入 FIFO，`awready`/`wready` 仅由各自 FIFO 满信号驱动，符合 AXI4-Lite 协议 AW/W 独立握手要求。当两个 FIFO 均非空且 WRQ FIFO 未满时，组合逻辑 `make_wrq` 触发配对写入 WRQ FIFO 并同步弹出 AW/W FIFO。

### 3.3 TX 状态机（命令组包发送）

采用两状态三段式 FSM，**组合输出**直接驱动 `m_axis_cmd_tdata/tvalid/tlast`。

| 状态 | 含义 |
|------|------|
| `TX_IDLE` | 空闲，轮询 WRQ/RDQ FIFO，有请求则装载帧参数进入 `TX_SEND` |
| `TX_SEND` | 按帧格式逐拍发送，最后一拍握手后弹出 FIFO 并翻转轮询位 |

**轮询仲裁**：维护 `rr_sel` 寄存器，当 WRQ 和 RDQ 同时非空时按 `rr_sel` 交替选择，单方非空则直接选择，消除写优先饥饿。

**组合输出逻辑**（`always @(*)`）：

```
TX_SEND 状态下:
  tx_idx == 0          → 包头: {MAGIC_HEAD, tx_type, payload_len, 8'h00}
  tx_idx == tx_total-1 → 包尾: {MAGIC_TAIL, 16'h0000, 8'h00}, tlast=1
  其他                 → 净荷: tx_p0 / tx_p1 / tx_p2（按 tx_idx 选择）
```

**时序逻辑**（`always @(posedge aclk)`）：
- `TX_IDLE`：从 FIFO FWFT `dout` 装载帧参数（地址、数据、选通），设置 `tx_total`（写 = 5 拍，读 = 3 拍）
- `TX_SEND`：每次握手 `tx_idx++`；末拍握手后弹出 FIFO、翻转 `rr_sel`

### 3.4 RX 状态机（响应解包接收）

采用三状态三段式 FSM，`s_axis_rsp_tready` 由组合逻辑 `assign` 驱动（`output wire`）。

| 状态 | 含义 |
|------|------|
| `RX_WAIT_HEAD` | 等待包头，**同拍**校验魔数 `8'hAA` 并锁存帧类型、净荷长度 |
| `RX_PAYLOAD` | 逐拍接收净荷，按帧类型分别锁存 BRESP / RDATA / RRESP |
| `RX_WAIT_TAIL` | 接收包尾，校验魔数与 `tlast`，推入 BRSP 或 RRSP FIFO |

**反压策略**：仅在 `RX_WAIT_TAIL` 且目标 FIFO 满时才拉低 `tready`，其余状态无条件接收（`tready=1`），避免响应通道死锁。

**关键设计要点**：
- `RX_WAIT_HEAD` 同拍完成魔数校验 + 帧类型锁存，消除原 V3 中"首拍消耗但未处理"的致命缺陷
- 写响应净荷 1 拍（`rx_need=1`），读响应净荷 2 拍（`rx_need=2`，RDATA + RRESP）
- RRSP FIFO 存储 `{rdata[31:0], rresp[1:0]}` = 34 bit，R 通道输出分别提取

### 3.5 B/R 通道输出

B 通道和 R 通道各自从 BRSP/RRSP FIFO 读取，独立驱动 AXI4-Lite 响应：

```verilog
// B 通道
assign brsp_rd_en = (!s_axi_bvalid || (s_axi_bvalid && s_axi_bready)) && !brsp_empty;
s_axi_bresp  <= brsp_dout[1:0];

// R 通道
assign rrsp_rd_en = (!s_axi_rvalid || (s_axi_rvalid && s_axi_rready)) && !rrsp_empty;
s_axi_rdata  <= rrsp_dout[33:2];   // 高 32 位 = RDATA
s_axi_rresp  <= rrsp_dout[1:0];    // 低 2 位 = RRESP
```

FIFO 弹出条件：当前无有效输出（`!bvalid`），或有效输出正在被消费（`bvalid && bready`）。支持背靠背连续响应。

---

## 四、模块二：axist2native（帧解析 + 执行 + 响应组包）

### 4.1 架构概述

Slave 端口按帧格式完整收包解析，执行本地寄存器读写后，在 Master 端口按帧格式组包返回响应。全程三段式状态机控制，TX 输出采用**组合逻辑**。

### 4.2 状态定义

| 状态 | 编码 | 含义 |
|------|------|------|
| `S_IDLE` | 3'd0 | 空闲，置位 `tready`，**同拍**接收并处理包头（校验魔数 + 锁存帧类型/净荷长度） |
| `S_RESYNC` | 3'd1 | 帧错误恢复，持续丢弃数据直到检测到 `tlast`，然后回 `S_IDLE` |
| `S_RX_PAYLOAD` | 3'd2 | 逐拍接收净荷，按帧类型解析（写：地址/数据/选通；读：地址） |
| `S_RX_TAIL` | 3'd3 | 接收包尾，校验魔数 + `tlast`。错误时进入 `S_RESYNC` 或 `S_IDLE` |
| `S_EXECUTE` | 3'd4 | 单拍执行寄存器读写，设置 `addr_err` 标志 |
| `S_TX_HEAD` | 3'd5 | 响应帧包头（组合输出） |
| `S_TX_PAYLOAD` | 3'd6 | 响应帧净荷（组合输出，写 = 1 拍 BRESP，读 = 2 拍 RDATA+RRESP） |
| `S_TX_TAIL` | 3'd7 | 响应帧包尾（组合输出，置 `tlast`） |

### 4.3 S_IDLE 包头同拍处理

```
S_IDLE 状态下：
  tready = 1（时序输出，上一拍设置）
  当 cmd_hs（tvalid && tready）成立：
    检查 tdata[31:24] == 8'hAA：
      ✓ 魔数匹配 → 锁存 frame_type_reg、payload_len_reg、is_write_cmd
                  → 状态转移至 S_RX_PAYLOAD
      ✗ 魔数不匹配 → 忽略此拍，保持 S_IDLE
```

**设计要点**：包头校验与数据锁存在 **同一时钟拍** 完成，避免包头拍被握手消耗后数据丢失。

### 4.4 帧错误恢复（S_RESYNC）

当 `S_RX_TAIL` 检测到帧尾异常且 `tlast` 未置位时，进入 `S_RESYNC` 持续消耗数据直到检测到 `tlast`，然后安全回到 `S_IDLE`。防止帧失步导致后续帧误解析。

```
S_RX_TAIL 错误处理：
  tlast=1 且魔数正确 → S_EXECUTE（正常）
  tlast=1 但魔数错误 → S_IDLE（帧已结束，直接丢弃）
  tlast=0           → S_RESYNC（帧未结束，需丢弃残余拍）
```

### 4.5 TX 组合输出

TX 响应输出采用 `always @(*)` 组合逻辑，直接由 `curr_state` 驱动，消除状态与输出之间的一拍延迟。状态转移条件使用 `rsp_hs = m_axis_rsp_tvalid && m_axis_rsp_tready`，确保 AXI-Stream 握手合规。

```verilog
S_TX_HEAD:
  tvalid = 1
  写响应: tdata = {AA, 11, 01, 00}   // payload_len=1
  读响应: tdata = {AA, 12, 02, 00}   // payload_len=2

S_TX_PAYLOAD:
  tvalid = 1
  写响应: tdata = {30'h0, BRESP}     // OKAY=00, DECERR=11
  读响应: cnt=0 → tdata = RDATA
          cnt=1 → tdata = {30'h0, RRESP}

S_TX_TAIL:
  tvalid = 1, tlast = 1
  tdata = {55, 0000, 00}
```

### 4.6 地址越界保护

```verilog
wire addr_in_range = (addr_reg[31:2] < C_REG_NUM);

// 动态位宽索引，支持 C_REG_NUM 1~16
localparam REG_IDX_W = (C_REG_NUM <= 2) ? 1 :
                       (C_REG_NUM <= 4) ? 2 :
                       (C_REG_NUM <= 8) ? 3 : 4;
wire [REG_IDX_W-1:0] reg_index = addr_in_range ?
    addr_reg[REG_IDX_W+1:2] : {REG_IDX_W{1'b0}};
```

- 越界写操作：不执行写入，`addr_err=1`，BRESP 返回 `DECERR(2'b11)`
- 越界读操作：`rdata_reg = 32'hDEAD_BEEF`，`addr_err=1`，RRESP 返回 `DECERR(2'b11)`
- 合法操作：`addr_err=0`，BRESP/RRESP 返回 `OKAY(2'b00)`

### 4.7 字节选通写入

```verilog
if (addr_in_range) begin
    if (wstrb_reg[0]) reg_file[reg_index][ 7: 0] <= wdata_reg[ 7: 0];
    if (wstrb_reg[1]) reg_file[reg_index][15: 8] <= wdata_reg[15: 8];
    if (wstrb_reg[2]) reg_file[reg_index][23:16] <= wdata_reg[23:16];
    if (wstrb_reg[3]) reg_file[reg_index][31:24] <= wdata_reg[31:24];
end
```

---

## 五、顶层封装：axi_lite_stream_bridge

### 5.1 端口列表

```verilog
module axi_lite_stream_bridge #(
    parameter C_S_AXI_DATA_WIDTH = 32,
    parameter C_S_AXI_ADDR_WIDTH = 32,
    parameter C_AXIS_DATA_WIDTH  = 32,
    parameter C_REG_NUM          = 4,
    parameter C_FIFO_DEPTH       = 16
)(
    input  wire        aclk,
    input  wire        aresetn,

    // AXI4-Lite Slave 接口（连接 PS 或上游 Master）
    // AW/W/B/AR/R 五通道完整信号...

    // 无 AXI4-Stream 外部端口（内部互联）
);
```

### 5.2 内部互联

顶层将 `axi4lite2axist` 的命令 Stream Master 直连 `axist2native` 的命令 Stream Slave，响应通道反向直连。内部 Stream 信号不出端口。

```
axi4lite2axist.m_axis_cmd ──────▶ axist2native.s_axis_cmd
axi4lite2axist.s_axis_rsp ◀────── axist2native.m_axis_rsp
```

---

## 六、时序分析

### 6.1 写事务时序（正常路径）

```
┌─────────────────────── axi4lite2axist ──────────────────────┐  ┌── axist2native ──┐
│ AW/W入FIFO → WRQ配对 → TX组包(5拍) → Stream命令发送           │──│ 收包→执行→回包    │
│                                                              │  │ (3拍响应)         │
│ Stream响应接收 → RX解包 → BRSP FIFO → B通道输出              │◀─│                   │
└──────────────────────────────────────────────────────────────┘  └──────────────────┘
```

| 阶段 | 拍数 | 说明 |
|------|------|------|
| AW/W 入 FIFO | 1 | AW 和 W 各自独立握手入 FIFO |
| WRQ 配对 | 1 | AW+W 均非空时组合触发 |
| TX 仲裁装载 | 1 | 从 WRQ FIFO FWFT dout 读取，装载帧参数 |
| TX 发送 | 5 | HEAD + ADDR + DATA + STRB + TAIL |
| axist2native 收包 | 5 | S_IDLE(包头) + 3×S_RX_PAYLOAD + S_RX_TAIL |
| 执行 | 1 | S_EXECUTE 单拍写入寄存器 |
| 响应回包 | 3 | S_TX_HEAD + S_TX_PAYLOAD(BRESP) + S_TX_TAIL |
| RX 解包 | 3 | RX_WAIT_HEAD + RX_PAYLOAD + RX_WAIT_TAIL |
| B 通道输出 | 1 | 从 BRSP FIFO 读出 |
| **总计** | **~21 拍** | 最佳情况，无反压 |

### 6.2 读事务时序（正常路径）

| 阶段 | 拍数 | 说明 |
|------|------|------|
| AR 入 RDQ FIFO | 1 | 握手入 FIFO |
| TX 仲裁装载 | 1 | 从 RDQ FIFO FWFT dout 读取 |
| TX 发送 | 3 | HEAD + ADDR + TAIL |
| axist2native 收包 | 3 | S_IDLE(包头) + S_RX_PAYLOAD + S_RX_TAIL |
| 执行 | 1 | S_EXECUTE 单拍读寄存器 |
| 响应回包 | 4 | S_TX_HEAD + S_TX_PAYLOAD(RDATA) + S_TX_PAYLOAD(RRESP) + S_TX_TAIL |
| RX 解包 | 4 | RX_WAIT_HEAD + 2×RX_PAYLOAD + RX_WAIT_TAIL |
| R 通道输出 | 1 | 从 RRSP FIFO 读出 |
| **总计** | **~18 拍** | 最佳情况，无反压 |

---

## 七、设计约束与限制

### 7.1 设计约束

| 项目 | 约束 |
|------|------|
| Outstanding | 受限于 FIFO 深度，最大同时未完成事务 = `C_FIFO_DEPTH` |
| 事务顺序 | 响应帧无事务标识，仅靠发送顺序匹配（单 outstanding 场景安全） |
| 数据位宽 | 固定 32 bit，不支持其他位宽 |
| 地址对齐 | 寄存器按 4 字节对齐，`addr[1:0]` 被忽略 |
| 寄存器数量 | `C_REG_NUM` 最大 16（受 `REG_IDX_W` 限制） |
| FIFO 深度 | 最小 16，须为 2 的幂（XPM 要求） |
| 时钟域 | 单时钟域设计，`aclk` 驱动所有逻辑 |
| 复位 | 低有效异步复位 `aresetn`，XPM FIFO 使用 `~aresetn` 高有效复位 |

### 7.2 Vivado 兼容性

| 项目 | 说明 |
|------|------|
| 语法标准 | 纯 Verilog-2001，无 SystemVerilog 语法 |
| XPM 宏 | `xpm_fifo_sync`，无 `CASCADE_HEIGHT`/`SIM_ASSERT_CHK` 等高版本参数 |
| 目标平台 | Zynq-7020 (xc7z020clg400-1) |
| 最低版本 | Vivado 2018.3 |

---

## 八、设计变更记录

### V4 修正记录（2026-07-28，Review 修正版）

| 编号 | 严重度 | 修正说明 |
|------|--------|----------|
| C-01 | 致命 | `axist2native`：合并 S_IDLE+S_RX_HEAD，S_IDLE 同拍完成包头校验与类型锁存，消除首拍消耗漏洞 |
| C-02 | 致命 | `axi4lite2axist` RX：合并 RX_WAIT_HEAD+RX_WAIT_TYPE，同拍校验魔数并锁存帧类型 |
| C-03 | 致命 | `axi4lite2axist`：`s_axis_rsp_tready` 声明从 `output reg` 改为 `output wire` |
| H-01 | 高 | `axist2native` TX：输出改为组合逻辑，转移条件使用 `rsp_hs(tvalid&&tready)` |
| H-02 | 高 | 全部文件：`C_FIFO_DEPTH` 默认值从 4 改为 16（满足 XPM 最小深度） |
| H-03 | 高 | `axi4lite2axist`：删除 XPM 实例的 `CASCADE_HEIGHT` 参数（Vivado 2018.3 不支持） |
| H-04 | 高 | `axi4lite2axist`：删除 XPM 实例的 `SIM_ASSERT_ON` 参数（参数名错误） |
| H-05 | 高 | `axist2native`：`reg_index` 改为动态位宽 `REG_IDX_W`，支持 `C_REG_NUM > 4` |
| M-01 | 中 | `axist2native`：新增 S_RESYNC 状态，帧错误后丢弃至 `tlast` |
| M-02 | 中 | `axist2native`：TX 输出改为组合逻辑（随 H-01 一并修正） |
| M-03 | 中 | `axist2native`：新增 `addr_err` 标志，地址越界返回 `DECERR(2'b11)` |
| M-04 | 中 | 读响应帧扩展为 4 拍（HEAD+RDATA+RRESP+TAIL），RRSP FIFO 扩展至 34 位 |
| L-01 | 低 | Testbench：`wait()` 改为 `while()` 时钟同步轮询 |

### V3 变更记录（2026-07-25，XPM FIFO 版）

全部 6 组手写 FIFO 替换为 Xilinx XPM 宏 `xpm_fifo_sync`，采用 FWFT 模式。

### V2 变更记录（2026-07-25，架构重构版）

修正 13 项缺陷（D-01\~D-13），模块一由"双状态机+组合仲裁"重构为"FIFO 解耦+轮询仲裁"架构。

---

## 九、文件清单

| 文件名 | 说明 |
|--------|------|
| `axi_lite_stream_bridge.v` | 顶层封装 |
| `axi4lite2axist.v` | 模块一：AXI4-Lite → AXI4-Stream 桥接 |
| `axist2native.v` | 模块二：AXI4-Stream → 本地寄存器 |
| `tb_axi_lite_stream_frame.v` | 验证 Testbench |
| `DESIGN_REVIEW_REPORT.md` | V4 Review 报告 |
| `DESIGN_CHANGELOG.md` | V2 缺陷修正记录 |
