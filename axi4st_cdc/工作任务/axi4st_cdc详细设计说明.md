# axi4st_cdc 详细设计说明

> **模块名称**：`axi4st_cdc`
> **文件路径**：`src/DXH_AI/axi4st_cdc/axi4st_cdc.v`
> **版本**：V1.0
> **日期**：2026-07-26

---

## 1. 概述

### 1.1 功能描述
本模块实现**单方向 AXI4-Stream 跨时钟域（Clock Domain Crossing, CDC）传输**，支持完整的 AXI4-Stream 信号集（tdata / tvalid / tready / tlast / tuser / tkeep）。模块采用 Xilinx **XPM 宏 `xpm_fifo_async`** 作为异步 FIFO 缓冲，配合写侧/读侧**三段式 FSM** 完成跨时钟域的数据可靠传输，自动处理复位同步与 FIFO 就绪等待。

### 1.2 设计动机
项目中存在多个独立时钟域（如系统时钟域、高速接口时钟域、用户逻辑时钟域等），AXI4-Stream 数据流需在不同时钟域之间安全传递。本模块提供标准化的单方向跨时钟域传输能力，确保数据在跨域过程中不丢失、不错序，符合 AXI4-Stream 握手协议。

### 1.3 关键设计决策

| 决策点 | 选择 | 原因 |
|--------|------|------|
| 跨时钟域方案 | `xpm_fifo_async`（异步 FIFO） | Xilinx 官方 CDC 方案，内置格雷码同步，稳定可靠，避免手动 CDC 设计风险 |
| FIFO 存储器类型 | `block`（Block RAM） | 512 深度属于较大容量，Block RAM 资源更优，且时序更容易收敛 |
| FSM 设计 | 写侧/读侧各一段三段式 FSM | 明确分离复位等待与正常工作态，确保 FIFO 复位完成后才启动传输 |
| 复位策略 | 写侧复位驱动 FIFO 复位（`rst = ~s_aresetn`） | XPM FIFO 单复位端口设计，写侧复位作为主动复位源 |
| 输出模式 | Standard READ（`READ_LATENCY=1`） | Block RAM 固有 1 拍读出延迟，与 Standard 模式匹配 |
| 复合字打包 | `{tuser, tlast, tkeep, tdata}`（tdata 低位） | 与项目其他 AXI4-Stream 模块保持一致的打包格式 |

---

## 2. 端口与参数

### 2.1 参数定义

| 参数名 | 默认值 | 说明 | 约束 |
|--------|--------|------|------|
| `DATA_WIDTH` | 32 | 数据位宽（写侧/读侧相同） | 须为 8 的整数倍 |
| `TUSER_WIDTH` | 1 | tuser 用户信号位宽 | ≥ 0 |
| `FIFO_DEPTH` | 512 | 异步 FIFO 深度 | 须为 2 的幂 |

**参数合法性检查**：`DATA_WIDTH % 8 != 0` 时，仿真阶段 `$error` 报错。

### 2.2 端口定义

| 端口名 | 方向 | 位宽 | 说明 |
|--------|------|------|------|
| **写侧（Slave）** | | | |
| `s_aclk` | input | 1 | 写侧时钟 |
| `s_aresetn` | input | 1 | 写侧异步复位，低有效 |
| `s_axis_tdata` | input | DATA_WIDTH | 写侧输入数据 |
| `s_axis_tkeep` | input | DATA_WIDTH/8 | 写字节有效标志 |
| `s_axis_tlast` | input | 1 | 写帧结束标志 |
| `s_axis_tuser` | input | TUSER_WIDTH | 写用户信号 |
| `s_axis_tvalid` | input | 1 | 写数据有效 |
| `s_axis_tready` | output | 1 | 写接收就绪 |
| **读侧（Master）** | | | |
| `m_aclk` | input | 1 | 读侧时钟 |
| `m_aresetn` | input | 1 | 读侧异步复位，低有效 |
| `m_axis_tdata` | output | DATA_WIDTH | 读侧输出数据 |
| `m_axis_tkeep` | output | DATA_WIDTH/8 | 读字节有效标志 |
| `m_axis_tlast` | output | 1 | 读帧结束标志 |
| `m_axis_tuser` | output | TUSER_WIDTH | 读用户信号 |
| `m_axis_tvalid` | output | 1 | 读数据有效 |
| `m_axis_tready` | input | 1 | 读接收就绪 |

---

## 3. 架构设计

### 3.1 顶层架构

```
         写侧（s_aclk 域）                    异步 FIFO                    读侧（m_aclk 域）
  ┌──────────────────────────┐      ┌──────────────────────┐      ┌──────────────────────────┐
  │  写侧三段式 FSM           │      │                      │      │  读侧三段式 FSM           │
  │  (WR_IDLE / WR_ACTIVE)   │      │   xpm_fifo_async     │      │  (RD_IDLE / RD_ACTIVE)   │
  │                          │      │   (Block RAM, 深度    │      │                          │
  │  输入: s_axis_*          │ wr   │    FIFO_DEPTH)       │ rd   │  输出: m_axis_*          │
  │  输出: s_axis_tready     │─────►│                      │─────►│  输入: m_axis_tready     │
  │                          │      │                      │      │                          │
  │  控制: fifo_wr_en        │      │  fifo_full / empty   │      │  控制: fifo_rd_en        │
  │  状态: wr_rst_busy       │      │  wr_rst_busy         │      │  状态: rd_rst_busy       │
  └──────────────────────────┘      └──────────────────────┘      └──────────────────────────┘
            ▲                                ▲                                ▲
            │                                │                                │
       s_aresetn                       rst = ~s_aresetn                 m_aresetn
```

### 3.2 复合字格式

写入异步 FIFO 的复合字打包格式（tdata 在低位，高位依次为 tkeep、tlast、tuser）：

```
{ tuser[TUSER_WIDTH-1:0], tlast, tkeep[BYTE_WIDTH-1:0], tdata[DATA_WIDTH-1:0] }
```

其中 `BYTE_WIDTH = DATA_WIDTH / 8`，总复合字宽度：

```
COMPOSITE_W = DATA_WIDTH + BYTE_WIDTH + 1 + TUSER_WIDTH
```

### 3.3 位段解包说明

读侧从 FIFO 读出后按位段解包为独立的 AXI4-Stream 信号：

| 信号 | 位段位置 | 说明 |
|------|----------|------|
| `m_axis_tdata` | `fifo_dout[DATA_WIDTH-1:0]` | 最低位段，数据 |
| `m_axis_tkeep` | `fifo_dout[DATA_WIDTH +: BYTE_WIDTH]` | 紧随其后，字节有效 |
| `m_axis_tlast` | `fifo_dout[DATA_WIDTH + BYTE_WIDTH]` | 1 位，帧结束 |
| `m_axis_tuser` | `fifo_dout[DATA_WIDTH + BYTE_WIDTH + 1 +: TUSER_WIDTH]` | 最高位段，用户信号 |

Verilog 实现：
```verilog
assign {m_axis_tuser, m_axis_tlast, m_axis_tkeep, m_axis_tdata} = fifo_dout;
```

---

## 4. 写侧三段式 FSM

### 4.1 状态定义

| 状态 | 编码 | 说明 |
|------|------|------|
| `WR_IDLE` | 1'b0 | 复位等待态：FIFO 复位期间保持此状态，不接受数据 |
| `WR_ACTIVE` | 1'b1 | 正常传输态：FIFO 复位完成后进入，正常处理 AXI4-Stream 握手 |

### 4.2 状态转换图

```
        ┌──────────┐  !wr_rst_busy    ┌────────────┐
        │ WR_IDLE  │ ───────────────► │ WR_ACTIVE  │
        │ (复位等待)│                  │ (正常传输) │
        └──────────┘ ◄─────────────── └────────────┘
                 复位(s_aresetn=0)
```

状态转换条件：
- **WR_IDLE → WR_ACTIVE**：写侧复位释放，且 `wr_rst_busy = 0`（FIFO 写侧复位完成）
- **WR_ACTIVE → WR_IDLE**：写侧复位 `s_aresetn = 0`（异步复位）

### 4.3 三段式实现说明

#### 第一段：状态寄存器段（时序逻辑）

```verilog
always @(posedge s_aclk or negedge s_aresetn) begin
    if (!s_aresetn) begin
        wr_curr_state <= WR_IDLE;
    end else begin
        wr_curr_state <= wr_next_state;
    end
end
```

- 异步复位，复位时进入 `WR_IDLE`
- 时钟沿更新当前状态

#### 第二段：次态组合逻辑段（组合逻辑）

```verilog
always @(*) begin
    case (wr_curr_state)
        WR_IDLE: begin
            if (!wr_rst_busy)
                wr_next_state = WR_ACTIVE;
            else
                wr_next_state = WR_IDLE;
        end
        WR_ACTIVE: begin
            wr_next_state = WR_ACTIVE;
        end
        default: begin
            wr_next_state = WR_IDLE;
        end
    endcase
end
```

- `WR_IDLE` 中等待 `wr_rst_busy` 拉低，表示 FIFO 写侧已就绪
- `WR_ACTIVE` 为终态，正常工作期间一直保持

#### 第三段：输出逻辑段（组合逻辑）

```verilog
assign fifo_wr_en    = s_axis_tvalid & s_axis_tready & (wr_curr_state == WR_ACTIVE);
assign s_axis_tready = (wr_curr_state == WR_ACTIVE) & ~fifo_full;
```

### 4.4 信号传播规则表

| 信号 | 规则 | 说明 |
|------|------|------|
| `s_axis_tready` | `WR_ACTIVE & ~fifo_full` | 仅在激活态且 FIFO 未满时接收数据 |
| `fifo_wr_en` | `s_axis_tvalid & s_axis_tready & WR_ACTIVE` | AXI4-Stream 握手成功且 FSM 激活时写 FIFO |
| `fifo_din` | `{tuser, tlast, tkeep, tdata}` | 输入信号直接打包为复合字 |
| 数据通路 | 透明传输 | 不修改数据内容，仅跨时钟域传递 |

---

## 5. 读侧三段式 FSM

### 5.1 状态定义

| 状态 | 编码 | 说明 |
|------|------|------|
| `RD_IDLE` | 1'b0 | 复位等待态：FIFO 复位期间保持此状态，不输出数据 |
| `RD_ACTIVE` | 1'b1 | 正常传输态：FIFO 复位完成后进入，正常输出 AXI4-Stream 数据 |

### 5.2 状态转换图

```
        ┌──────────┐  !rd_rst_busy    ┌────────────┐
        │ RD_IDLE  │ ───────────────► │ RD_ACTIVE  │
        │ (复位等待)│                  │ (正常传输) │
        └──────────┘ ◄─────────────── └────────────┘
                 复位(m_aresetn=0)
```

状态转换条件：
- **RD_IDLE → RD_ACTIVE**：读侧复位释放，且 `rd_rst_busy = 0`（FIFO 读侧复位完成）
- **RD_ACTIVE → RD_IDLE**：读侧复位 `m_aresetn = 0`（异步复位）

### 5.3 三段式实现说明

#### 第一段：状态寄存器段（时序逻辑）

```verilog
always @(posedge m_aclk or negedge m_aresetn) begin
    if (!m_aresetn) begin
        rd_curr_state <= RD_IDLE;
    end else begin
        rd_curr_state <= rd_next_state;
    end
end
```

- 异步复位，复位时进入 `RD_IDLE`
- 时钟沿更新当前状态

#### 第二段：次态组合逻辑段（组合逻辑）

```verilog
always @(*) begin
    case (rd_curr_state)
        RD_IDLE: begin
            if (!rd_rst_busy)
                rd_next_state = RD_ACTIVE;
            else
                rd_next_state = RD_IDLE;
        end
        RD_ACTIVE: begin
            rd_next_state = RD_ACTIVE;
        end
        default: begin
            rd_next_state = RD_IDLE;
        end
    endcase
end
```

- `RD_IDLE` 中等待 `rd_rst_busy` 拉低，表示 FIFO 读侧已就绪
- `RD_ACTIVE` 为终态，正常工作期间一直保持

#### 第三段：输出逻辑段（组合逻辑）

```verilog
assign fifo_rd_en   = m_axis_tvalid & m_axis_tready & (rd_curr_state == RD_ACTIVE);
assign m_axis_tvalid = (rd_curr_state == RD_ACTIVE) & ~fifo_empty;
```

### 5.4 信号传播规则表

| 信号 | 规则 | 说明 |
|------|------|------|
| `m_axis_tvalid` | `RD_ACTIVE & ~fifo_empty` | 仅在激活态且 FIFO 非空时输出有效 |
| `fifo_rd_en` | `m_axis_tvalid & m_axis_tready & RD_ACTIVE` | AXI4-Stream 握手成功且 FSM 激活时读 FIFO |
| `m_axis_tdata` | 从 `fifo_dout` 解包 | FIFO 读出数据直接映射到输出 |
| `m_axis_tkeep` | 从 `fifo_dout` 解包 | 字节有效标志透传 |
| `m_axis_tlast` | 从 `fifo_dout` 解包 | 帧结束标志透传 |
| `m_axis_tuser` | 从 `fifo_dout` 解包 | 用户信号透传 |

---

## 6. XPM 异步 FIFO

### 6.1 配置参数表

| 参数名 | 值 | 说明 |
|--------|-----|------|
| `FIFO_MEMORY_TYPE` | `"block"` | Block RAM 实现 |
| `ECC_MODE` | `"no_ecc"` | 无纠错编码 |
| `FIFO_WRITE_DEPTH` | `FIFO_DEPTH` | 写深度（默认 512） |
| `WRITE_DATA_WIDTH` | `COMPOSITE_W` | 写数据宽度（复合字宽度） |
| `READ_DATA_WIDTH` | `COMPOSITE_W` | 读数据宽度（与写同宽） |
| `FIFO_READ_LATENCY` | `1` | 读延迟 1 拍（Standard 模式） |
| `WR_DATA_COUNT_WIDTH` | `$clog2(FIFO_DEPTH)+1` | 写数据计数位宽 |
| `RD_DATA_COUNT_WIDTH` | `$clog2(FIFO_DEPTH)+1` | 读数据计数位宽 |
| `PROG_FULL_THRESH` | `FIFO_DEPTH/2` | 可编程满阈值（未使用） |
| `PROG_EMPTY_THRESH` | `16` | 可编程空阈值（未使用） |

### 6.2 端口连接表

#### 写侧端口

| XPM 端口 | 连接信号 | 说明 |
|----------|----------|------|
| `wr_clk` | `s_aclk` | 写时钟 |
| `rst` | `~s_aresetn` | FIFO 复位（高有效） |
| `din` | `fifo_din` | 写数据（复合字） |
| `wr_en` | `fifo_wr_en` | 写使能 |
| `full` | `fifo_full` | FIFO 满标志 |
| `wr_rst_busy` | `wr_rst_busy` | 写侧复位忙标志 |

#### 读侧端口

| XPM 端口 | 连接信号 | 说明 |
|----------|----------|------|
| `rd_clk` | `m_aclk` | 读时钟 |
| `rd_en` | `fifo_rd_en` | 读使能 |
| `dout` | `fifo_dout` | 读数据（复合字） |
| `empty` | `fifo_empty` | FIFO 空标志 |
| `rd_rst_busy` | `rd_rst_busy` | 读侧复位忙标志 |

#### 未使用端口（留空）

| XPM 端口 | 连接 | 说明 |
|----------|------|------|
| `sbiterr` | 开路 | 单比特错误（无 ECC） |
| `dbiterr` | 开路 | 双比特错误（无 ECC） |
| `wr_data_count` | 开路 | 写数据计数（未用） |
| `rd_data_count` | 开路 | 读数据计数（未用） |
| `prog_full` | 开路 | 可编程满（未用） |
| `prog_empty` | 开路 | 可编程空（未用） |
| `overflow` | 开路 | 溢出标志（未用） |
| `underflow` | 开路 | 下溢标志（未用） |

### 6.3 复位说明

XPM 异步 FIFO 的 `rst` 端口为**高有效**异步复位，本设计中接写侧复位的反：

```verilog
.rst (~s_aresetn)
```

即：
- 写侧复位 `s_aresetn = 0` → FIFO 复位 `rst = 1`
- 写侧复位释放 `s_aresetn = 1` → FIFO 复位释放 `rst = 0`

**注意**：读侧复位 `m_aresetn` 不驱动 FIFO 复位，仅控制读侧 FSM。

### 6.4 wr_rst_busy / rd_rst_busy 的使用说明

`wr_rst_busy` 和 `rd_rst_busy` 是 XPM FIFO 提供的复位状态标志：

| 信号 | 时钟域 | 含义 |
|------|--------|------|
| `wr_rst_busy` | 写时钟域 | 高电平表示 FIFO 写侧正在复位，此时写操作无效 |
| `rd_rst_busy` | 读时钟域 | 高电平表示 FIFO 读侧正在复位，此时读操作无效 |

**使用方式**：
- 写侧 FSM 在 `WR_IDLE` 状态等待 `wr_rst_busy` 拉低后才进入 `WR_ACTIVE`
- 读侧 FSM 在 `RD_IDLE` 状态等待 `rd_rst_busy` 拉低后才进入 `RD_ACTIVE`
- 确保 FIFO 完全复位就绪后才进行读写操作，避免潜在的不稳定状态

---

## 7. 时序与反压

### 7.1 反压链

```
m_axis_tready = 0
    ↓（下游不接收）
m_axis_tvalid & m_axis_tready = 0 → fifo_rd_en = 0
    ↓（停止读 FIFO）
FIFO 数据堆积 → fifo_full = 1
    ↓（FIFO 满）
s_axis_tready = 0
    ↓（上游停止发送）
s_axis_tvalid & s_axis_tready = 0 → fifo_wr_en = 0
```

反压传播路径：
1. 下游 `m_axis_tready=0` → 读侧握手失败 → 停止读 FIFO
2. FIFO 逐渐填满 → `fifo_full=1`
3. 写侧 `s_axis_tready=0` → 上游停止发送

### 7.2 复位行为

#### 写侧复位（s_aresetn = 0）

- 写侧 FSM 异步复位到 `WR_IDLE`
- `s_axis_tready = 0`（不接受数据）
- `fifo_wr_en = 0`（停止写 FIFO）
- FIFO `rst = 1`（整个 FIFO 复位）
- FIFO 内部数据清空，指针复位

#### 读侧复位（m_aresetn = 0）

- 读侧 FSM 异步复位到 `RD_IDLE`
- `m_axis_tvalid = 0`（不输出数据）
- `fifo_rd_en = 0`（停止读 FIFO）
- **注意**：读侧复位不影响 FIFO 内部数据，FIFO 数据保持不变

### 7.3 无组合环路保证

- `s_axis_tready` 仅依赖 `wr_curr_state`（寄存器）和 `fifo_full`（FIFO 输出寄存器）
- `m_axis_tvalid` 仅依赖 `rd_curr_state`（寄存器）和 `fifo_empty`（FIFO 输出寄存器）
- 写侧：`s_axis_tready` 不依赖 `s_axis_tvalid`
- 读侧：`m_axis_tvalid` 不依赖 `m_axis_tready`
- 符合 AXI4-Stream 标准握手协议，无组合反馈环路

---

## 8. 任务分解与完成状态

### Task 1: 模块骨架搭建 ✅
- 1.1 文件创建 `axi4st_cdc.v`，`timescale` 声明
- 1.2 模块声明（端口、参数），参数合法性检查
- 1.3 内部常量定义（`BYTE_WIDTH`、`COMPOSITE_W`）

### Task 2: 写侧三段式 FSM ✅
- 2.1 状态定义（`WR_IDLE` / `WR_ACTIVE`）
- 2.2 第一段：状态寄存器段（异步复位）
- 2.3 第二段：次态组合逻辑段
- 2.4 第三段：输出逻辑段（`fifo_wr_en`、`s_axis_tready`）

### Task 3: 读侧三段式 FSM ✅
- 3.1 状态定义（`RD_IDLE` / `RD_ACTIVE`）
- 3.2 第一段：状态寄存器段（异步复位）
- 3.3 第二段：次态组合逻辑段
- 3.4 第三段：输出逻辑段（`fifo_rd_en`、`m_axis_tvalid`）

### Task 4: 复合字打包/解包 ✅
- 4.1 写侧复合字打包 `{tuser, tlast, tkeep, tdata}`
- 4.2 读侧复合字解包到位段信号
- 4.3 位宽参数化计算

### Task 5: XPM 异步 FIFO 例化 ✅
- 5.1 `xpm_fifo_async` 例化
- 5.2 写侧端口连接（wr_clk, din, wr_en, full, wr_rst_busy）
- 5.3 读侧端口连接（rd_clk, dout, rd_en, empty, rd_rst_busy）
- 5.4 复位连接 `rst = ~s_aresetn`
- 5.5 未使用端口显式留空

### Task 6: 顶层验证与风格一致性 ✅
- 6.1 AXI4-Stream 握手时序检查（无组合环路）
- 6.2 写侧/读侧复位路径检查
- 6.3 XPM FIFO 例化风格一致性
- 6.4 无未使用信号告警
- 6.5 与项目其他 CDC 模块风格统一

---

## 9. 验证检查清单

| 检查项 | 状态 |
|--------|------|
| 文件名与模块名一致（`axi4st_cdc`） | ✅ |
| `timescale 1ns / 1ps` | ✅ |
| 端口定义符合 AXI4-Stream 规范 | ✅ |
| 3 个参数可配置（`DATA_WIDTH`/`TUSER_WIDTH`/`FIFO_DEPTH`） | ✅ |
| `DATA_WIDTH % 8` 合法性检查（`$error`） | ✅ |
| 写侧 FSM 三段式（3 个独立 always 块） | ✅ |
| 读侧 FSM 三段式（3 个独立 always 块） | ✅ |
| 写侧状态：`WR_IDLE` → `WR_ACTIVE`（等待 `wr_rst_busy`） | ✅ |
| 读侧状态：`RD_IDLE` → `RD_ACTIVE`（等待 `rd_rst_busy`） | ✅ |
| 写侧异步复位（`negedge s_aresetn`） | ✅ |
| 读侧异步复位（`negedge m_aresetn`） | ✅ |
| FIFO 使用 `xpm_fifo_async` | ✅ |
| FIFO 类型：Block RAM | ✅ |
| FIFO 读延迟：1 拍（Standard 模式） | ✅ |
| FIFO 复位：`rst = ~s_aresetn`（高有效） | ✅ |
| FIFO 深度：`FIFO_DEPTH` 参数化 | ✅ |
| 复合字格式：`{tuser, tlast, tkeep, tdata}` | ✅ |
| 写侧 tready = `WR_ACTIVE & ~fifo_full` | ✅ |
| 读侧 tvalid = `RD_ACTIVE & ~fifo_empty` | ✅ |
| 写使能 = `s_axis_tvalid & s_axis_tready & WR_ACTIVE` | ✅ |
| 读使能 = `m_axis_tvalid & m_axis_tready & RD_ACTIVE` | ✅ |
| 跨时钟域路径经过 FIFO（无直接跨域信号） | ✅ |
| 反压链完整（下游反压 → FIFO 满 → 上游反压） | ✅ |
| 无组合环路（tready/tvalid 互不依赖） | ✅ |
| 未使用端口显式留空（`sbiterr`/`dbiterr` 等） | ✅ |
| 双时钟域独立（`s_aclk` / `m_aclk`） | ✅ |
| tlast / tuser / tkeep 信号透传 | ✅ |
| XPM 例化风格与项目一致 | ✅ |
| 中文注释清晰 | ✅ |
| 综合无 latch 警告 | ✅ |

---

## 10. 例化模板

```verilog
//----------- axi4st_cdc 例化模板 -----------//
// 单方向 AXI4-Stream 跨时钟域传输
// 写侧时钟 s_aclk → 读侧时钟 m_aclk
axi4st_cdc #(
    .DATA_WIDTH     (32),       // 数据位宽，默认 32
    .TUSER_WIDTH    (1),        // tuser 位宽，默认 1
    .FIFO_DEPTH     (512)       // FIFO 深度，默认 512（须为 2 的幂）
) u_axi4st_cdc (
    // 写侧（Slave 接口）
    .s_aclk         (s_aclk),       // 写侧时钟
    .s_aresetn      (s_aresetn),    // 写侧复位，低有效
    .s_axis_tdata   (s_axis_tdata), // 写数据
    .s_axis_tkeep   (s_axis_tkeep), // 写字节有效
    .s_axis_tlast   (s_axis_tlast), // 写帧结束
    .s_axis_tuser   (s_axis_tuser), // 写用户信号
    .s_axis_tvalid  (s_axis_tvalid),// 写数据有效
    .s_axis_tready  (s_axis_tready),// 写接收就绪

    // 读侧（Master 接口）
    .m_aclk         (m_aclk),       // 读侧时钟
    .m_aresetn      (m_aresetn),    // 读侧复位，低有效
    .m_axis_tdata   (m_axis_tdata), // 读数据
    .m_axis_tkeep   (m_axis_tkeep), // 读字节有效
    .m_axis_tlast   (m_axis_tlast), // 读帧结束
    .m_axis_tuser   (m_axis_tuser), // 读用户信号
    .m_axis_tvalid  (m_axis_tvalid),// 读数据有效
    .m_axis_tready  (m_axis_tready) // 读接收就绪
);
```

---

## 11. 设计风险与注意事项

### 11.1 XPM 库依赖
- 综合/仿真时需包含 Xilinx XPM 库（`xpm_fifo_async` 等）
- 项目 `src/DXH_AI/xilinx2018.2_XPM_Lib` 已提供 XPM 仿真模型
- 硬件实现时 Xilinx FPGA 原生支持，无需额外资源

### 11.2 FIFO 深度选择
- 默认深度 512，适用于大多数场景
- 若读写时钟频率差异较大（如写快读慢），需根据吞吐量计算深度：
  - `FIFO_DEPTH > (写速率 - 读速率) × 最大突发时长`
- 深度不足会导致频繁反压，影响系统性能
- 建议预留 20%~30% 余量

### 11.3 时钟频率限制
- 异步 FIFO 支持任意时钟频率比（写时钟可快于/慢于读时钟）
- 最高时钟频率受 FPGA 速度等级和 Block RAM 时序限制
- 设计约束中应分别对 `s_aclk` 和 `m_aclk` 设置时钟约束
- Vivado 会自动识别异步 FIFO 的 CDC 路径，无需额外 set_false_path

### 11.4 复位注意事项
- FIFO 复位由写侧 `s_aresetn` 驱动，读侧复位不影响 FIFO 数据
- 复位时 FIFO 内部数据全部清空，指针复位
- 复位释放后需等待 `wr_rst_busy` / `rd_rst_busy` 拉低后才能正常读写
- 建议写侧复位持续至少 3 个写时钟周期，确保 FIFO 完全复位
- 若需在读侧复位时也清空 FIFO，需额外的跨域复位同步机制

### 11.5 其他注意事项
- 本模块为**单方向**传输，双向传输需例化两个模块
- 写侧和读侧数据位宽必须相同，不支持位宽转换
- `tkeep` 信号透传，消费方需正确处理字节有效标志
- 不支持数据包级别的丢弃或重传，传输失败需上层协议处理
