# axi4st_dw_conv 详细设计说明

> **模块名称**：`axi4st_dw_conv`
> **文件路径**：`src/DXH_AI/axi4st_dw_conv/axi4st_dw_conv.v`
> **版本**：V1.0
> **日期**：2026-07-26

---

## 1. 概述

### 1.1 功能描述
本模块实现**单时钟域** AXI4-Stream 接口的**数据位宽转换**，支持输入与输出数据位宽比率为 4:1、2:1（降位宽）和 1:2、1:4（升位宽）。模块采用**三段式 FSM** 完成位宽转换核心逻辑，调用 Xilinx **XPM 宏 `xpm_fifo_sync`** 作为输出侧弹性缓冲，解耦输出背压与输入时序。

### 1.2 设计动机
项目中存在多种数据位宽的 AXI4-Stream 接口（如 TLK1221 的 8 位、以太网 MAC 的 8 位、用户侧的 32/64 位等），需要在同一时钟域内进行位宽适配。本模块提供标准化的位宽转换能力，支持完整的 AXI4-Stream 信号集（tdata / tvalid / tready / tlast / tuser / tkeep）。

### 1.3 关键设计决策

| 决策点 | 选择 | 原因 |
|--------|------|------|
| 位宽转换实现 | 三段式 FSM 累加/移位寄存器 | XPM FIFO 自带位宽转换无法正确处理 tlast 定位和升位宽时的部分字提前终止 |
| 弹性缓冲 | `xpm_fifo_sync`（同宽，FWFT） | 解耦输出背压与输入时序，单时钟域无需异步 FIFO |
| FIFO 位置 | 输出侧（FSM 之后） | 输出 stall 时 FIFO 填满 → FSM 停止产出 → 输入 tready 反压 |
| 数据字节序 | Little-endian（最低字节先出/先入低位） | 与 Xilinx `axis_dwidth_converter` 一致 |
| 复位极性 | `aresetn` 低有效（内部 `fifo_rst = ~aresetn`） | 与项目 AXI4 约定一致，XPM rst 为高有效 |

---

## 2. 端口与参数

### 2.1 参数定义

| 参数名 | 默认值 | 说明 | 约束 |
|--------|--------|------|------|
| `IN_DATA_WIDTH` | 32 | 输入数据位宽 | 须为 8 的整数倍 |
| `OUT_DATA_WIDTH` | 8 | 输出数据位宽 | 须为 8 的整数倍 |
| `TUSER_WIDTH` | 1 | tuser 位宽 | - |
| `FIFO_DEPTH` | 16 | FIFO 深度 | 须为 2 的幂 |

**比率约束**：`max(IN,OUT)/min(IN,OUT) ∈ {2, 4}`，否则综合阶段 `$error` 报错。

### 2.2 端口定义

| 端口名 | 方向 | 位宽 | 说明 |
|--------|------|------|------|
| `aclk` | input | 1 | 时钟（单时钟域） |
| `aresetn` | input | 1 | 异步复位，低有效 |
| **Slave 输入** | | | |
| `s_axis_tdata` | input | IN_DATA_WIDTH | 输入数据 |
| `s_axis_tkeep` | input | IN_DATA_WIDTH/8 | 字节有效 |
| `s_axis_tlast` | input | 1 | 帧结束 |
| `s_axis_tuser` | input | TUSER_WIDTH | 用户信号 |
| `s_axis_tvalid` | input | 1 | 数据有效 |
| `s_axis_tready` | output | 1 | 接收就绪 |
| **Master 输出** | | | |
| `m_axis_tdata` | output | OUT_DATA_WIDTH | 输出数据 |
| `m_axis_tkeep` | output | OUT_DATA_WIDTH/8 | 字节有效 |
| `m_axis_tlast` | output | 1 | 帧结束 |
| `m_axis_tuser` | output | TUSER_WIDTH | 用户信号 |
| `m_axis_tvalid` | output | 1 | 数据有效 |
| `m_axis_tready` | input | 1 | 接收就绪 |

---

## 3. 架构设计

### 3.1 顶层架构

```
                    ┌─────────────────────┐     ┌──────────────────┐     ┌────────────┐
s_axis_tdata ─────► │                     │     │                  │     │            │
s_axis_tkeep ─────► │   三段式 FSM        │────►│  xpm_fifo_sync   │────►│  输出解包   │──► m_axis_tdata
s_axis_tlast ─────► │  (位宽转换核心)      │ wr  │  (弹性缓冲,FWFT)  │ rd  │            │──► m_axis_tkeep
s_axis_tuser ─────► │                     │────►│                  │────►│            │──► m_axis_tlast
s_axis_tvalid───►   │                     │     │                  │     │            │──► m_axis_tuser
              ◄─── s_axis_tready          │     │                  │     │            │──► m_axis_tvalid
                    └─────────────────────┘     └──────────────────┘     └────────────┘
                              ▲                        ▲                       │
                              │                        │                       │
                         fifo_full ◄──────────────────┘                  m_axis_tready
```

### 3.2 复合字格式

FSM 产出的输出位宽复合字打包格式（tdata 在低位）：

```
{ tuser[TUSER_WIDTH-1:0], tlast, tkeep[OUT_BYTES-1:0], tdata[OUT_DATA_WIDTH-1:0] }
```

位段解包：
- `m_axis_tdata` = `fifo_dout[OUT_DATA_WIDTH-1:0]`
- `m_axis_tkeep` = `fifo_dout[OUT_DATA_WIDTH +: OUT_BYTES]`
- `m_axis_tlast` = `fifo_dout[OUT_DATA_WIDTH + OUT_BYTES]`
- `m_axis_tuser` = `fifo_dout[OUT_DATA_WIDTH + OUT_BYTES + 1 +: TUSER_WIDTH]`

### 3.3 XPM FIFO 配置

| 参数 | 值 | 说明 |
|------|-----|------|
| `FIFO_MEMORY_TYPE` | `"distributed"` | 分布式 RAM（小深度场景） |
| `ECC_MODE` | `"no_ecc"` | 无纠错 |
| `FIFO_WRITE_DEPTH` | `FIFO_DEPTH` | 可参数化深度 |
| `WRITE_DATA_WIDTH` | `COMPOSITE_W` | 复合字宽度 |
| `READ_DATA_WIDTH` | `COMPOSITE_W` | 同宽（位宽转换由 FSM 完成） |
| `READ_MODE` | `"fwft"` | 首字直通 |
| `USE_ADV_FEATURES` | `"0000"` | 仅基础功能 |
| `SIM_ASSERT_ON` | `1` | 仿真时启用断言 |

---

## 4. 降位宽核心（IN > OUT）

### 4.1 状态机

采用三段式 FSM，状态：`DS_IDLE`、`DS_SHIFT`。

```
        ┌──────────┐  s_handshake   ┌──────────┐
        │  DS_IDLE │ ─────────────► │ DS_SHIFT │
        │ (等待输入)│                │ (移位输出)│
        └──────────┘ ◄──────────── └──────────┘
                       shift_cnt==RATIO-1
                       & ~fifo_full
```

### 4.2 三段式实现

**第一段：状态寄存器**
```verilog
always @(posedge aclk or negedge aresetn)
    if (!aresetn) ds_curr_state <= DS_IDLE;
    else          ds_curr_state <= ds_next_state;
```

**第二段：次态组合逻辑**
- `DS_IDLE` → `DS_SHIFT`：当输入握手成功（`s_handshake`）
- `DS_SHIFT` → `DS_IDLE`：当移位到最后一拍（`shift_cnt == RATIO-1`）且 FIFO 未满

**第三段：输出时序逻辑**
- **移位寄存器**：`shift_data`（存 tdata）、`shift_keep`、`shift_last`、`shift_user`
- **移位方向**：每拍右移 `OUT_DATA_WIDTH` 位（little-endian，最低字节先出）
- **移位计数器**：`shift_cnt`，0 到 RATIO-1

### 4.3 信号传播规则

| 信号 | 规则 |
|------|------|
| `wr_tdata` | `shift_data[OUT_DATA_WIDTH-1:0]`（当前最低切片） |
| `wr_tkeep` | `shift_keep[OUT_BYTES-1:0]`（对应字节段） |
| `wr_tlast` | `(shift_cnt == RATIO-1) ? shift_last : 0`（最后子节拍） |
| `wr_tuser` | `(shift_cnt == 0) ? shift_user : 0`（第一子节拍，位置语义） |

### 4.4 反压逻辑

```
s_axis_tready = (ds_curr_state == DS_IDLE) & ~fifo_full
fifo_wr_en    = (ds_curr_state == DS_SHIFT) & ~fifo_full
```

- FIFO 满 → `s_axis_tready=0`（不接受新输入）
- DS_SHIFT 期间不接受新输入（`s_axis_tready=0`）

---

## 5. 升位宽核心（IN < OUT）

### 5.1 状态机

状态：`US_IDLE`、`US_ACCUM`。

```
        ┌──────────┐  s_handshake      ┌──────────┐
        │  US_IDLE │ ───无tlast──────► │ US_ACCUM │
        │ (等待输入)│                   │ (累加中)  │
        └──────────┘ ◄─────────────── └──────────┘
                       累加满 或 tlast
                       & ~fifo_full
```

### 5.2 三段式实现

**第一段：状态寄存器**：复位到 `US_IDLE`。

**第二段：次态组合逻辑**
- `US_IDLE` → `US_ACCUM`：输入握手且无 tlast
- `US_IDLE` → `US_IDLE`：输入握手且有 tlast（立即产出）
- `US_ACCUM` → `US_IDLE`：累加满（`accum_cnt == RATIO-1`）或收到 tlast

**第三段：输出时序逻辑**
- **累加寄存器**：`accum_data`（OUT_DATA_WIDTH 位）、`accum_keep`
- **字节位置**：第 N 个输入写到 `accum_data[N*IN_DATA_WIDTH +: IN_DATA_WIDTH]`
- **字节计数器**：`accum_cnt`，0 到 RATIO-1

### 5.3 产出逻辑（组合拼字）

为避免时序问题，产出时用组合逻辑把当前输入拼入累加器对应位置：

```verilog
out_data_comb = accum_data;  // 之前累加的字节
if (s_handshake)
    out_data_comb[accum_cnt*IN_DATA_WIDTH +: IN_DATA_WIDTH] = s_axis_tdata;
```

**产出触发条件**：
- `US_IDLE` 且 `s_handshake` 且（`tlast` 或 `RATIO==1`）
- `US_ACCUM` 且 `s_handshake` 且（`accum_cnt==RATIO-1` 或 `tlast`）

### 5.4 信号传播规则

| 信号 | 规则 |
|------|------|
| `wr_tdata` | `out_data_comb`（累加器 + 当前输入拼字） |
| `wr_tkeep` | `out_keep_comb`（有效字节置 1，未填充字节为 0） |
| `wr_tlast` | `s_axis_tlast`（触发产出的输入节拍 tlast） |
| `wr_tuser` | `s_axis_tuser`（触发产出的输入节拍 tuser） |

### 5.5 反压逻辑

```verilog
will_produce   = (US_ACCUM) & (accum_cnt==RATIO-1 | tlast);
s_axis_tready  = (US_ACCUM & ~will_produce) ? 1'b1 : ~fifo_full;
```

- **累加阶段（不产出）**：`tready=1`（不需要 FIFO 空间）
- **产出时**：`tready=~fifo_full`（确保产出能写入 FIFO）

---

## 6. 时序与反压

### 6.1 反压链

```
m_axis_tready=0 → FIFO 写满 → fifo_full=1 → FSM 停止产出 → s_axis_tready=0 → 输入停止
```

### 6.2 复位行为

- `aresetn=0` 时：
  - FSM 回到空闲态（`DS_IDLE` / `US_IDLE`）
  - 所有寄存器异步清零
  - `fifo_rst = ~aresetn = 1`（FIFO 复位）
  - `m_axis_tvalid = ~fifo_empty = 0`

### 6.3 无组合环路保证

- `s_axis_tready` 仅依赖 `fifo_full` 和状态寄存器（不依赖 `s_axis_tvalid`）
- `m_axis_tvalid` 仅依赖 `fifo_empty`（不依赖 `m_axis_tready`）
- 握手信号无组合反馈路径

---

## 7. 任务分解与完成状态

### Task 1: 重命名文件并搭建模块骨架 ✅
- 1.1 文件重命名 `axaaxi4st_dw_conv.v` → `axi4st_dw_conv.v`
- 1.2 模块声明（端口、参数、`timescale`），比率合法性检查
- 1.3 内部常量定义（`IS_DOWNSIZE`、`RATIO`、`IN_BYTES`/`OUT_BYTES`、`COMPOSITE_W`）

### Task 2: 降位宽转换核心 ✅
- 2.1 三段式 FSM 状态定义（DS_IDLE / DS_SHIFT）
- 2.2 次态组合逻辑
- 2.3 输出逻辑（移位寄存器、计数器、tlast/tuser 定位）
- 2.4 FIFO 写入信号与输入 tready 逻辑

### Task 3: 升位宽转换核心 ✅
- 3.1 三段式 FSM 状态定义（US_IDLE / US_ACCUM）
- 3.2 次态组合逻辑
- 3.3 输出逻辑（累加器、字节计数器、tlast 部分字冲刷）
- 3.4 FIFO 写入信号与输入 tready 逻辑

### Task 4: XPM FIFO 弹性缓冲 ✅
- 4.1 复合字打包/解包
- 4.2 `xpm_fifo_sync` 例化
- 4.3 写侧/读侧连接
- 4.4 输出 tvalid / rd_en 控制

### Task 5: 顶层验证与风格一致性 ✅
- 5.1 AXI4-Stream 握手时序检查（无组合环路）
- 5.2 复位路径检查
- 5.3 XPM FIFO 例化风格一致性
- 5.4 无未使用信号告警

---

## 8. 验证检查清单

| 检查项 | 状态 |
|--------|------|
| 文件名与模块名一致 | ✅ |
| `timescale 1ns / 1ps` | ✅ |
| 端口定义符合 spec | ✅ |
| 4 个参数可配置 | ✅ |
| 比率合法性检查（$error） | ✅ |
| FSM 三段式（3 个独立 always 块） | ✅ |
| 降位宽 tlast 传播到最后子节拍 | ✅ |
| 降位宽 tuser 传播到第一子节拍 | ✅ |
| 升位宽凑满产出 tkeep 全 1 | ✅ |
| 升位宽 tlast 部分字冲刷 | ✅ |
| 升位宽 tuser 取触发节拍 | ✅ |
| FIFO 使用 `xpm_fifo_sync` | ✅ |
| FIFO 配置 FWFT + distributed | ✅ |
| FIFO 复位高有效（~aresetn） | ✅ |
| 单时钟域（aclk） | ✅ |
| 输出 tvalid = !empty | ✅ |
| rd_en = valid & ready | ✅ |
| FIFO 满反压链完整 | ✅ |
| 所有寄存器异步复位 | ✅ |
| 无组合环路 | ✅ |
| XPM 例化风格一致 | ✅ |
| 空端口显式留空 | ✅ |
| 中文注释 | ✅ |

---

## 9. 例化模板

```verilog
//----------- axi4st_dw_conv 例化模板 -----------//
// 降位宽示例：32-bit → 8-bit (4:1)
axi4st_dw_conv #(
    .IN_DATA_WIDTH  (32),
    .OUT_DATA_WIDTH (8),
    .TUSER_WIDTH    (1),
    .FIFO_DEPTH     (16)
) u_dw_conv_downsize (
    .aclk          (aclk),
    .aresetn       (aresetn),
    // Slave 输入
    .s_axis_tdata  (s_axis_tdata),
    .s_axis_tkeep  (s_axis_tkeep),
    .s_axis_tlast  (s_axis_tlast),
    .s_axis_tuser  (s_axis_tuser),
    .s_axis_tvalid (s_axis_tvalid),
    .s_axis_tready (s_axis_tready),
    // Master 输出
    .m_axis_tdata  (m_axis_tdata),
    .m_axis_tkeep  (m_axis_tkeep),
    .m_axis_tlast  (m_axis_tlast),
    .m_axis_tuser  (m_axis_tuser),
    .m_axis_tvalid (m_axis_tvalid),
    .m_axis_tready (m_axis_tready)
);

// 升位宽示例：8-bit → 32-bit (1:4)
axi4st_dw_conv #(
    .IN_DATA_WIDTH  (8),
    .OUT_DATA_WIDTH (32),
    .TUSER_WIDTH    (1),
    .FIFO_DEPTH     (16)
) u_dw_conv_upsize (
    .aclk          (aclk),
    .aresetn       (aresetn),
    // Slave 输入
    .s_axis_tdata  (s_axis_tdata),
    .s_axis_tkeep  (s_axis_tkeep),
    .s_axis_tlast  (s_axis_tlast),
    .s_axis_tuser  (s_axis_tuser),
    .s_axis_tvalid (s_axis_tvalid),
    .s_axis_tready (s_axis_tready),
    // Master 输出
    .m_axis_tdata  (m_axis_tdata),
    .m_axis_tkeep  (m_axis_tkeep),
    .m_axis_tlast  (m_axis_tlast),
    .m_axis_tuser  (m_axis_tuser),
    .m_axis_tvalid (m_axis_tvalid),
    .m_axis_tready (m_axis_tready)
);
```

---

## 10. 设计风险与注意事项

1. **XPM 库依赖**：综合/仿真时需包含 Xilinx XPM 库（`xpm_cdc_gray`、`xpm_fifo_sync` 等），项目 `src/DXH_AI/xilinx2018.2_XPM_Lib` 已提供。
2. **FIFO 深度选择**：默认 16，对于高背压场景建议增大至 32 或 64 以减少反压频次。
3. **tkeep 语义**：降位宽时 tkeep 按字节段映射；升位宽部分字冲刷时未填充字节 tkeep=0，消费方应据此判断有效字节。
4. **tuser 位置语义**：降位宽时 tuser 仅在第一子节拍有效（与 Xilinx `axis_dwidth_converter` 一致）；升位宽时取触发产出的输入节拍 tuser。
5. **不支持比率 1:1**：若 IN==OUT，`RATIO=1` 会触发 `$error`。1:1 场景请直接互联或使用 FIFO 缓冲。
