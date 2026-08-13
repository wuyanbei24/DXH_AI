# Master/Slave FPGA 跨片 AXI4-Lite 寄存器访问系统详细设计文档

> **版本**：V1.0
> **日期**：2026-08-13
> **设计目标**：Master FPGA 将 AXI4-Lite 读写事务转换为 AXI4-Stream 帧，经 LVDS 单通道（1-Lane）链路传输至 Slave FPGA，Slave 端解帧执行本地寄存器读写并回送响应。
> **平台**：Xilinx 7 系列 FPGA（Zynq-7020 / 同系列），Vivado 2018.2，Verilog-2001
> **复用模块**：`AXI4Lite2AXI4ST`（V5 仿真验证通过）、`LVDS1DLane`（仿真验证通过）

---

## 一、需求概述

### 1.1 功能需求

| 编号 | 需求 | 描述 |
|------|------|------|
| REQ-01 | 跨片寄存器写入 | Master FPGA 的 AXI4-Lite Master（如 Zynq PS）通过 LVDS 链路对 Slave FPGA 的本地寄存器执行写操作，支持字节选通（WSTRB） |
| REQ-02 | 跨片寄存器读取 | Master FPGA 通过 LVDS 链路读取 Slave FPGA 的本地寄存器，返回数据与响应码 |
| REQ-03 | 地址越界保护 | 访问超出 Slave 寄存器地址范围的地址时，返回 DECERR 响应 |
| REQ-04 | 链路建链与维护 | LVDS 链路上电后自动训练、建链，链路建立后通过心跳帧维持连接 |
| REQ-05 | 链路故障恢复 | 链路断开或错误超限时自动重训练恢复，恢复后继续传输 |
| REQ-06 | 双向全双工 | 命令帧（Master→Slave）与响应帧（Slave→Master）通过同一条双向 LVDS 链路同时传输 |

### 1.2 性能需求

| 项目 | 指标 |
|------|------|
| LVDS 串行速率 | 400 Mbps（DDR 8:1） |
| 并行接口时钟 | 100 MHz（clk_div） |
| 用户数据宽度 | 8 bit（LVDS 每拍 1 字节） |
| AXI4-Stream 数据宽度 | 32 bit |
| AXI4-Lite 数据/地址宽度 | 32 bit |
| 最大未完成事务数 | 1（outstanding = 1，顺序匹配） |
| 写事务端到端延迟 | ≤ 2 µs（含 LVDS 传播，无反压） |
| 读事务端到端延迟 | ≤ 2 µs（含 LVDS 传播，无反压） |

### 1.3 设计约束

| 项目 | 约束 |
|------|------|
| 语法标准 | Verilog-2001，无 SystemVerilog |
| 目标平台 | Xilinx 7 系列（Zynq-7020 xc7z020clg400-1 或同系列） |
| Vivado 版本 | 2018.3（XPM 宏参数须兼容） |
| 时钟域 | AXI4-Lite 桥接时钟 aclk 与 LVDS 并行时钟 clk_div 为同一 100MHz 同源时钟，无需 CDC |
| 复位 | 低有效异步复位 aresetn / rst_n |
| 现有模块 | 不修改 AXI4Lite2AXI4ST 和 LVDS1DLane 的现有 RTL 文件，通过新建集成 wrapper 实现对接 |

---

## 二、系统架构设计

### 2.1 系统总体框图

```
┌──────────────────────── Master FPGA ────────────────────────┐
│                                                              │
│  AXI4-Lite          ┌─────────────────┐                     │
│  Master (PS)  ─────►│ axi4lite2axist  │── cmd ──┐           │
│  (AW/W/B/AR/R) ◄────┤  (现有模块)      │◄── rsp ─┤           │
│                    └─────────────────┘        │             │
│                           │  32-bit           │  32-bit     │
│                    ┌──────▼──────┐     ┌──────┴──────┐      │
│                    │ axis32_to_   │     │ lvds8_to_   │      │
│                    │ lvds8 (TX)   │     │ axis32 (RX) │      │
│                    └──────┬──────┘     └──────▲──────┘      │
│                       8-bit │              8-bit│            │
│                    ┌───────▼───────────────────┴───────┐    │
│                    │ lvds_bidirectional_top_1lane       │    │
│                    │   (TX ──► LVDS ──► ... )           │    │
│                    │   (RX ◄── LVDS ◄── ... )           │    │
│                    └───────┬───────────────────┬───────┘    │
│                            │                   │             │
│  tx_lvds_clk_p/n ──────────┘                   │             │
│  tx_lvds_data_p/n ─────────┘                   │             │
│  rx_lvds_clk_p/n ──────────────────────────────┘             │
│  rx_lvds_data_p/n ─────────────────────────────┘             │
│                                                              │
└──────────────────────────────────────────────────────────────┘
          │ │ │ │                    │ │ │ │
          │ │ │ │  LVDS 差分对        │ │ │ │
          │ │ │ │  (1 clk + 1 data)  │ │ │ │
          │ │ │ │  双向独立           │ │ │ │
          ▼ ▼ ▼ ▼                    ▼ ▼ ▼ ▼
┌──────────────────────── Slave FPGA ────────────────────────┐
│                                                              │
│                    ┌───────┬───────────────────┬───────┐    │
│                    │ lvds_bidirectional_top_1lane       │    │
│                    │   (RX ◄── LVDS ◄── ... )           │    │
│                    │   (TX ──► LVDS ──► ... )           │    │
│                    └───────▲───────────────────┬───────┘    │
│                       8-bit │              8-bit│            │
│                    ┌──────┴──────┐     ┌──────▼──────┐      │
│                    │ lvds8_to_   │     │ axis32_to_  │      │
│                    │ axis32 (RX) │     │ lvds8 (TX)  │      │
│                    └──────┬──────┘     └──────▲──────┘      │
│                           │  32-bit           │  32-bit     │
│                    ┌──────▼──────┐     ┌──────┴──────┐      │
│                    │ axist2native│────►│ axist2native│      │
│                    │ (命令接收)   │     │ (响应发送)   │      │
│                    └──────┬──────┘     └─────────────┘      │
│                           │                                   │
│                    ┌──────▼──────┐                           │
│                    │ Register    │                           │
│                    │ File        │                           │
│                    │ (C_REG_NUM) │                           │
│                    └─────────────┘                           │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### 2.2 数据流说明

| 方向 | 数据流 | 说明 |
|------|--------|------|
| Master → Slave | AXI4-Lite 写/读命令 → AXI4-Stream 命令帧(32b) → 字节序列化(8b) → LVDS TX → LVDS 链路 → Slave LVDS RX → 字节反序列化(32b) → AXI4-Stream 命令帧 → axist2native 执行寄存器读写 | 命令通道 |
| Slave → Master | axist2native 响应帧(32b) → 字节序列化(8b) → LVDS TX → LVDS 链路 → Master LVDS RX → 字节反序列化(32b) → AXI4-Stream 响应帧 → axi4lite2axist 解包 → AXI4-Lite B/R 通道 | 响应通道 |

### 2.3 协议层次

```
┌─────────────────────────────────────────────────┐
│  应用层：AXI4-Lite 读写事务                      │  ← Master PS 发起
├─────────────────────────────────────────────────┤
│  协议层：AXI4-Stream 帧封装/解封                  │  ← axi4lite2axist / axist2native
│    帧格式：HEAD(0xAA) | TYPE | PAYLOAD | TAIL(0x55)
│    四类帧：写命令(5拍) / 读命令(3拍) / 写响应(3拍) / 读响应(4拍)
├─────────────────────────────────────────────────┤
│  适配层：32b ↔ 8b 宽度转换                        │  ← axis32_to_lvds8 / lvds8_to_axis32
│    字节级序列化协议：[CTRL][B0][B1][B2][B3] / beat
├─────────────────────────────────────────────────┤
│  链路层：LVDS 帧封装/解封                         │  ← lvds_tx/rx_channel_1lane
│    帧格式：SOF1(0xAA) | SOF2(0x55) | TYPE(0x20) | LEN | PAYLOAD | CHECKSUM
│    帧类型：TYPE_USR(0x20) 用户数据 | TYPE_HB(0x10) 心跳 | 控制帧
├─────────────────────────────────────────────────┤
│  物理层：LVDS SERDES                             │  ← OSERDESE2 / ISERDESE2
│    DDR 8:1，400MHz 串行 / 100MHz 并行
└─────────────────────────────────────────────────┘
```

> **关键设计决策**：LVDS 链路作为透明字节传输通道。AXI4-Stream 帧完整地作为 LVDS TYPE_USR(0x20) 帧的 PAYLOAD 传输，形成双层帧封装。LVDS 链路层负责物理传输、建链训练、心跳维护、故障重训练；AXI4-Stream 协议层负责寄存器读写语义、命令/响应配对、地址保护。

---

## 三、模块详细设计

### 3.1 新建模块清单

| 模块名 | 文件名 | 用途 | 实例化位置 |
|--------|--------|------|------------|
| `axis32_to_lvds8` | `axis32_to_lvds8.v` | 32-bit AXI4-Stream → 8-bit 字节序列化 | Master TX 侧、Slave TX 侧 |
| `lvds8_to_axis32` | `lvds8_to_axis32.v` | 8-bit 字节 → 32-bit AXI4-Stream 反序列化 | Master RX 侧、Slave RX 侧 |
| `master_lvds_bridge` | `master_lvds_bridge.v` | Master FPGA 集成顶层 | Master FPGA |
| `slave_lvds_bridge` | `slave_lvds_bridge.v` | Slave FPGA 集成顶层 | Slave FPGA |

### 3.2 现有复用模块

| 模块名 | 来源目录 | 用途 | 是否修改 |
|--------|----------|------|----------|
| `axi4lite2axist` | AXI4Lite2AXI4ST/rtl/ | AXI4-Lite → AXI4-Stream 命令组包 + 响应解包 | 否（V5 仿真验证通过） |
| `axist2native` | AXI4Lite2AXI4ST/rtl/ | AXI4-Stream 命令解包 → 寄存器读写 → 响应组包 | 否（V4 仿真验证通过） |
| `lvds_bidirectional_top_1lane` | LVDS1DLane/rtl/ | LVDS 双向收发顶层（含 TX/RX/link_manager） | 否 |
| `lvds_tx_channel_1lane` | LVDS1DLane/rtl/ | LVDS 发送通道（8bit 帧封装 + OSERDESE2） | 否 |
| `lvds_rx_channel_1lane` | LVDS1DLane/rtl/ | LVDS 接收通道（ISERDESE2 + 链路层解帧） | 否 |
| `lvds_rx_phy_1lane` | LVDS1DLane/rtl/ | LVDS 接收物理层（IDELAY + BITSLIP） | 否 |
| `lvds_rx_lane_phy` | LVDS1DLane/rtl/ | 单通道 ISERDESE2 + 延迟校准 | 否 |
| `lvds_rx_link_1lane` | LVDS1DLane/rtl/ | LVDS 接收链路层（帧解析 + 校验和 + 心跳） | 否 |
| `lvds_link_manager` | LVDS1DLane/rtl/ | 链路管理器（建链握手 + 重训练控制） | 否 |
| `mfpga_clk_ip` | LVDS1DLane/rtl/ | MMCM 时钟 IP（400M/100M/200M） | 否 |

### 3.3 模块一：axis32_to_lvds8（32-bit AXI4-Stream → 8-bit 字节序列化器）

#### 3.3.1 功能描述

将 32-bit AXI4-Stream 接口（tdata/tvalid/tlast/tready）序列化为 8-bit 字节流，适配 LVDS TX 通道的用户接口。每个 32-bit AXI4-Stream beat 序列化为 5 个字节（1 控制字节 + 4 数据字节）。

#### 3.3.2 字节级序列化协议

```
每个 AXI4-Stream beat 序列化为 5 字节：

  Byte 0 (CTRL)   : {7'b0, tlast}     ← 控制字节，bit0 = tlast
  Byte 1 (DATA[0]): tdata[7:0]         ← LSB
  Byte 2 (DATA[1]): tdata[15:8]
  Byte 3 (DATA[2]): tdata[23:16]
  Byte 4 (DATA[3]): tdata[31:24]       ← MSB
```

**帧示例 —— 写命令帧（5 beats = 25 bytes）**：

| AXI4-Stream beat | tdata[31:0] | tlast | 序列化字节（5 bytes） |
|------------------|-------------|-------|----------------------|
| 1 (HEAD) | {0xAA, 0x01, 0x03, 0x00} | 0 | 0x00, 0x00, 0x03, 0x01, 0xAA |
| 2 (ADDR) | AWADDR | 0 | 0x00, ADDR[7:0], ADDR[15:8], ADDR[23:16], ADDR[31:24] |
| 3 (WDATA) | WDATA | 0 | 0x00, DATA[7:0], DATA[15:8], DATA[23:16], DATA[31:24] |
| 4 (WSTRB) | {28'h0, WSTRB[3:0]} | 0 | 0x00, WSTRB, 0x00, 0x00, 0x00 |
| 5 (TAIL) | {0x55, 0x00, 0x00, 0x00} | 1 | 0x01, 0x00, 0x00, 0x00, 0x55 |

#### 3.3.3 端口定义

```verilog
module axis32_to_lvds8 (
    input  wire        aclk,           // 时钟（100MHz，与 LVDS clk_div 同源）
    input  wire        aresetn,        // 低有效复位

    // AXI4-Stream Slave 接口（32-bit 输入）
    input  wire [31:0] s_axis_tdata,   // 数据
    input  wire        s_axis_tvalid,  // 有效
    input  wire        s_axis_tlast,   // 帧尾
    output wire        s_axis_tready,  // 准备好接收

    // 8-bit 输出接口（连接 LVDS TX 用户接口）
    output wire [7:0]  tx_data,        // 字节数据
    output wire        tx_valid,       // 字节有效
    input  wire        tx_ready        // 下游准备好（LVDS TX FIFO 未满且非训练态）
);
```

#### 3.3.4 状态机设计

采用三段式状态机，6 个状态：

| 状态 | 编码 | 含义 |
|------|------|------|
| `S_IDLE` | 3'd0 | 空闲，等待 AXI4-Stream 握手。s_axis_tready = 1（当 tx_ready=1 时） |
| `S_CTRL` | 3'd1 | 发送控制字节 {7'b0, tlast_hold} |
| `S_B0` | 3'd2 | 发送 tdata[7:0] |
| `S_B1` | 3'd3 | 发送 tdata[15:8] |
| `S_B2` | 3'd4 | 发送 tdata[23:16] |
| `S_B3` | 3'd5 | 发送 tdata[31:24]，完成后回 `S_IDLE` |

**状态转移条件**：每个字节发送状态在 `tx_valid && tx_ready`（字节握手成功）后转移到下一状态。

**关键寄存器**：
- `tdata_hold[31:0]`：锁存 AXI4-Stream 握手时的 tdata
- `tlast_hold`：锁存 AXI4-Stream 握手时的 tlast
- `byte_idx[2:0]`：当前发送字节索引（0~4）

**握手逻辑**：
- `s_axis_tready`：仅在 `S_IDLE` 且 `tx_ready=1` 时为高。当 AXI4-Stream 握手成立（tvalid && tready），锁存数据并进入 `S_CTRL`。
- `tx_valid`：在 `S_CTRL` ~ `S_B3` 状态下为高。
- `tx_data`：按当前状态选择控制字节或对应数据字节。

**反压传播**：当 LVDS TX FIFO 满（`tx_ready=0`）时，序列化器暂停字节输出，`s_axis_tready` 保持为 0，反压至上游 AXI4-Stream。

#### 3.3.5 时序示例

```
时钟周期  AXI4-Stream                  序列化输出(8-bit)
─────────────────────────────────────────────────────────
  T0     tvalid=1, tdata=0xAA010300    tx_valid=0 (S_IDLE, 锁存)
  T1     tready=0 (正在序列化)          tx_data=0x00 (CTRL, tlast=0), tx_valid=1
  T2                                   tx_data=0x00 (B0), tx_valid=1
  T3                                   tx_data=0x03 (B1), tx_valid=1
  T4                                   tx_data=0x01 (B2), tx_valid=1
  T5                                   tx_data=0xAA (B3), tx_valid=1
  T6     tvalid=1, tdata=AWADDR        tx_valid=0 (S_IDLE, 锁存)
  T7     tready=0                      tx_data=0x00 (CTRL), tx_valid=1
  ...   （继续序列化第 2 个 beat）
```

### 3.4 模块二：lvds8_to_axis32（8-bit 字节 → 32-bit AXI4-Stream 反序列化器）

#### 3.4.1 功能描述

将 LVDS RX 通道输出的 8-bit 字节流反序列化为 32-bit AXI4-Stream 接口。每 5 个字节重组为 1 个 AXI4-Stream beat。

#### 3.4.2 端口定义

```verilog
module lvds8_to_axis32 (
    input  wire        aclk,           // 时钟（100MHz）
    input  wire        aresetn,        // 低有效复位

    // 8-bit 输入接口（连接 LVDS RX 用户接口）
    input  wire [7:0]  rx_data,        // 字节数据
    input  wire        rx_valid,       // 字节有效（无 rx_ready，LVDS RX 无反压）

    // AXI4-Stream Master 接口（32-bit 输出）
    output wire [31:0] m_axis_tdata,   // 数据
    output wire        m_axis_tvalid,  // 有效
    output wire        m_axis_tlast,   // 帧尾
    input  wire        m_axis_tready   // 下游准备好
);
```

#### 3.4.3 设计要点 —— 无反压输入的缓冲策略

LVDS RX 接口只有 `rx_valid`，没有 `rx_ready`，即 LVDS 链路层不提供反压能力。当下游 AXI4-Stream 消费者（axi4lite2axist 或 axist2native）暂时不能接收数据时（tready=0），反序列化器必须缓冲到达的字节。

**方案**：内部使用一个深度为 64 字节的 FIFO（XPM `xpm_fifo_sync`，8-bit，FWFT 模式）缓冲到达的字节。

- **写入**：`rx_valid` 时无条件写入 FIFO（FIFO 满概率极低，因 AXI4-Stream 消费速率 ≥ LVDS 字节到达速率）。
- **读出**：状态机从 FIFO 读出 5 字节组装为 1 个 AXI4-Stream beat，读出速率受下游 `m_axis_tready` 控制。

#### 3.4.4 状态机设计

采用三段式状态机，7 个状态：

| 状态 | 编码 | 含义 |
|------|------|------|
| `S_IDLE` | 3'd0 | 空闲，检查 FIFO 是否有 ≥5 字节。有则进入 `S_CTRL` |
| `S_CTRL` | 3'd1 | 从 FIFO 读出控制字节，解析 tlast |
| `S_B0` | 3'd2 | 从 FIFO 读出 tdata[7:0] |
| `S_B1` | 3'd3 | 从 FIFO 读出 tdata[15:8] |
| `S_B2` | 3'd4 | 从 FIFO 读出 tdata[23:16] |
| `S_B3` | 3'd5 | 从 FIFO 读出 tdata[31:24]，组装完成 |
| `S_OUT` | 3'd6 | 输出 32-bit AXI4-Stream beat，等待 m_axis_tready。握手后回 `S_IDLE` |

**关键寄存器**：
- `tdata_assemble[31:0]`：字节组装寄存器
- `tlast_assemble`：从控制字节提取的 tlast

**FIFO 读出时序**：FWFT 模式下，`dout` 在 `empty=0` 时即有效。`rd_en` 脉冲弹出当前 `dout` 并更新为下一字。状态机在 `S_CTRL` ~ `S_B3` 每拍执行一次 FIFO 读出。

**输出逻辑**：
- `m_axis_tvalid`：在 `S_OUT` 状态为高
- `m_axis_tdata`：`tdata_assemble`
- `m_axis_tlast`：`tlast_assemble`

#### 3.4.5 FIFO 深度分析

| 因素 | 计算 | 结果 |
|------|------|------|
| 最大 AXI4-Stream 帧 | 写命令帧 5 beats × 5 bytes = 25 bytes | 25 bytes |
| 下游最大反压拍数 | axist2native 单拍执行 + 3 拍响应 = 4 拍 | 4 × 5 = 20 bytes |
| LVDS 连续到达 | 25 bytes / 100MHz = 250ns | — |
| 安全余量 | 2× 最大帧 | 50 bytes |
| **选定 FIFO 深度** | 64（2 的幂，XPM 最小要求 16） | **64 bytes** |

### 3.5 模块三：master_lvds_bridge（Master FPGA 集成顶层）

#### 3.5.1 功能描述

Master FPGA 侧集成顶层。将 `axi4lite2axist`（命令组包/响应解包）、`axis32_to_lvds8`（命令序列化）、`lvds8_to_axis32`（响应反序列化）、`lvds_bidirectional_top_1lane`（LVDS 收发）封装为统一模块，对外提供 AXI4-Lite Slave 接口和 LVDS 物理引脚。

#### 3.5.2 端口定义

```verilog
module master_lvds_bridge #(
    parameter C_S_AXI_DATA_WIDTH = 32,
    parameter C_S_AXI_ADDR_WIDTH = 32,
    parameter C_FIFO_DEPTH       = 16,   // axi4lite2axist 内部 FIFO 深度
    parameter IS_MASTER          = 1,    // LVDS 链路管理器为主机模式
    parameter SIM_BYPASS         = 0     // 仿真旁路（综合时置 0）
)(
    input  wire        clk_ref,          // 参考时钟（100MHz，链路管理器时钟）
    input  wire        ref_clk_200m,     // IDELAY 参考时钟（200MHz）
    input  wire        rst_n,            // 全局复位（低有效）
    input  wire        clk_ser,          // SERDES 串行时钟（400MHz）
    input  wire        clk_div,          // SERDES 并行时钟（100MHz，= aclk）

    // AXI4-Lite Slave 接口（连接 PS / 上游 Master）
    // 写通道
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]  s_axi_awaddr,
    input  wire [2:0]                     s_axi_awprot,
    input  wire                           s_axi_awvalid,
    output wire                           s_axi_awready,
    input  wire [C_S_AXI_DATA_WIDTH-1:0]  s_axi_wdata,
    input  wire [C_S_AXI_DATA_WIDTH/8-1:0] s_axi_wstrb,
    input  wire                           s_axi_wvalid,
    output wire                           s_axi_wready,
    output wire [1:0]                     s_axi_bresp,
    output wire                           s_axi_bvalid,
    input  wire                           s_axi_bready,
    // 读通道
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]  s_axi_araddr,
    input  wire [2:0]                     s_axi_arprot,
    input  wire                           s_axi_arvalid,
    output wire                           s_axi_arready,
    output wire [C_S_AXI_DATA_WIDTH-1:0]  s_axi_rdata,
    output wire [1:0]                     s_axi_rresp,
    output wire                           s_axi_rvalid,
    input  wire                           s_axi_rready,

    // LVDS 发送差分引脚
    output wire tx_lvds_clk_p,  output wire tx_lvds_clk_n,
    output wire tx_lvds_data_p, output wire tx_lvds_data_n,

    // LVDS 接收差分引脚
    input  wire rx_lvds_clk_p,  input  wire rx_lvds_clk_n,
    input  wire rx_lvds_data_p, input  wire rx_lvds_data_n,

    // 外部重训练请求
    input  wire ext_retrain_req,

    // 状态输出
    output wire link_all_up,     // 链路完全建立
    output wire heartbeat_err,   // 心跳错误
    output wire align_err        // 对齐错误
);
```

#### 3.5.3 内部架构

```
                    ┌─────────────────────────┐
  AXI4-Lite ───────►│  axi4lite2axist          │
  (AW/W/B/AR/R) ◄───┤  (现有模块，不修改)       │
                    └────┬───────────┬─────────┘
                  cmd   │  32-bit    │  32-bit   rsp
               (Master) │            │ (Slave)
                        ▼            ▼
                 ┌──────────┐  ┌──────────┐
                 │axis32_to │  │lvds8_to  │
                 │_lvds8    │  │_axis32   │
                 └────┬─────┘  └────▲─────┘
                   8-bit │          │ 8-bit
                        ▼          │
              ┌─────────────────────┴──────────┐
              │  lvds_bidirectional_top_1lane   │
              │  (IS_MASTER=1)                  │
              │                                 │
              │  user_tx_data/valid/ready ──►   │──► LVDS TX
              │  user_rx_data/valid ◄──         │◄── LVDS RX
              └─────────────────────────────────┘
```

#### 3.5.4 内部信号连接

| 信号 | 位宽 | 源 | 目的 | 说明 |
|------|------|------|------|------|
| `cmd_tdata` | 32 | axi4lite2axist.m_axis_cmd_tdata | axis32_to_lvds8.s_axis_tdata | 命令帧数据 |
| `cmd_tvalid` | 1 | axi4lite2axist.m_axis_cmd_tvalid | axis32_to_lvds8.s_axis_tvalid | 命令帧有效 |
| `cmd_tlast` | 1 | axi4lite2axist.m_axis_cmd_tlast | axis32_to_lvds8.s_axis_tlast | 命令帧尾 |
| `cmd_tready` | 1 | axis32_to_lvds8.s_axis_tready | axi4lite2axist.m_axis_cmd_tready | 命令帧准备好 |
| `rsp_tdata` | 32 | lvds8_to_axis32.m_axis_tdata | axi4lite2axist.s_axis_rsp_tdata | 响应帧数据 |
| `rsp_tvalid` | 1 | lvds8_to_axis32.m_axis_tvalid | axi4lite2axist.s_axis_rsp_tvalid | 响应帧有效 |
| `rsp_tlast` | 1 | lvds8_to_axis32.m_axis_tlast | axi4lite2axist.s_axis_rsp_tlast | 响应帧尾 |
| `rsp_tready` | 1 | axi4lite2axist.s_axis_rsp_tready | lvds8_to_axis32.m_axis_tready | 响应帧准备好 |
| `tx_byte_data` | 8 | axis32_to_lvds8.tx_data | lvds_top.user_tx_data | LVDS 发送字节 |
| `tx_byte_valid` | 1 | axis32_to_lvds8.tx_valid | lvds_top.user_tx_valid | LVDS 发送有效 |
| `tx_byte_ready` | 1 | lvds_top.user_tx_ready | axis32_to_lvds8.tx_ready | LVDS 发送准备好 |
| `rx_byte_data` | 8 | lvds_top.user_rx_data | lvds8_to_axis32.rx_data | LVDS 接收字节 |
| `rx_byte_valid` | 1 | lvds_top.user_rx_valid | lvds8_to_axis32.rx_valid | LVDS 接收有效 |

> **时钟连接**：`aclk = clk_div`（同一 100MHz 时钟）。axi4lite2axist 的 aclk/aresetn 与 LVDS 的 clk_div/rst_n 直接相连。链路管理器使用 `clk_ref`（与 clk_div 同源或同频）。

### 3.6 模块四：slave_lvds_bridge（Slave FPGA 集成顶层）

#### 3.6.1 功能描述

Slave FPGA 侧集成顶层。将 `lvds_bidirectional_top_1lane`（LVDS 收发）、`lvds8_to_axis32`（命令反序列化）、`axist2native`（寄存器读写）、`axis32_to_lvds8`（响应序列化）封装为统一模块，对外提供 LVDS 物理引脚和本地寄存器接口。

#### 3.6.2 端口定义

```verilog
module slave_lvds_bridge #(
    parameter C_REG_NUM  = 4,        // 本地寄存器数量（1~16）
    parameter SIM_BYPASS = 0         // 仿真旁路
)(
    input  wire        clk_ref,          // 参考时钟（100MHz）
    input  wire        ref_clk_200m,     // IDELAY 参考时钟（200MHz）
    input  wire        rst_n,            // 全局复位
    input  wire        clk_ser,          // SERDES 串行时钟（400MHz）
    input  wire        clk_div,          // SERDES 并行时钟（100MHz，= aclk）

    // LVDS 发送差分引脚（响应方向）
    output wire tx_lvds_clk_p,  output wire tx_lvds_clk_n,
    output wire tx_lvds_data_p, output wire tx_lvds_data_n,

    // LVDS 接收差分引脚（命令方向）
    input  wire rx_lvds_clk_p,  input  wire rx_lvds_clk_n,
    input  wire rx_lvds_data_p, input  wire rx_lvds_data_n,

    // 外部重训练请求
    input  wire ext_retrain_req,

    // 本地寄存器读出接口（可选，供 Slave FPGA 内部逻辑使用）
    output wire [32*C_REG_NUM-1:0] reg_file_out,

    // 状态输出
    output wire link_all_up,
    output wire heartbeat_err,
    output wire align_err
);
```

#### 3.6.3 内部架构

```
              ┌─────────────────────────────────┐
              │  lvds_bidirectional_top_1lane   │
              │  (IS_MASTER=0)                  │
              │                                 │
  LVDS RX ──► │  user_rx_data/valid ──►        │
  LVDS TX ◄── │  user_tx_data/valid/ready ◄──  │
              └────────┬────────────┬──────────┘
                   8-bit│            │ 8-bit
                       ▼            ▲
                ┌──────────┐  ┌──────────┐
                │lvds8_to  │  │axis32_to │
                │_axis32   │  │_lvds8    │
                └────┬─────┘  └────▲─────┘
                  32-bit│            │ 32-bit
               (Slave)  │            │ (Master)
                       ▼            ▲
                    ┌─────────────────┐
                    │  axist2native   │
                    │  (现有模块)      │
                    └────┬────────────┘
                         │
                    ┌────▼────┐
                    │Register │
                    │File     │
                    │(C_REG_NUM)│
                    └─────────┘
```

#### 3.6.4 内部信号连接

| 信号 | 位宽 | 源 | 目的 | 说明 |
|------|------|------|------|------|
| `cmd_tdata` | 32 | lvds8_to_axis32.m_axis_tdata | axist2native.s_axis_cmd_tdata | 命令帧数据 |
| `cmd_tvalid` | 1 | lvds8_to_axis32.m_axis_tvalid | axist2native.s_axis_cmd_tvalid | 命令帧有效 |
| `cmd_tlast` | 1 | lvds8_to_axis32.m_axis_tlast | axist2native.s_axis_cmd_tlast | 命令帧尾 |
| `cmd_tready` | 1 | axist2native.s_axis_cmd_tready | lvds8_to_axis32.m_axis_tready | 命令帧准备好 |
| `rsp_tdata` | 32 | axist2native.m_axis_rsp_tdata | axis32_to_lvds8.s_axis_tdata | 响应帧数据 |
| `rsp_tvalid` | 1 | axist2native.m_axis_rsp_tvalid | axis32_to_lvds8.s_axis_tvalid | 响应帧有效 |
| `rsp_tlast` | 1 | axist2native.m_axis_rsp_tlast | axis32_to_lvds8.s_axis_tlast | 响应帧尾 |
| `rsp_tready` | 1 | axis32_to_lvds8.s_axis_tready | axist2native.m_axis_rsp_tready | 响应帧准备好 |
| `rx_byte_data` | 8 | lvds_top.user_rx_data | lvds8_to_axis32.rx_data | LVDS 接收字节 |
| `rx_byte_valid` | 1 | lvds_top.user_rx_valid | lvds8_to_axis32.rx_valid | LVDS 接收有效 |
| `tx_byte_data` | 8 | axis32_to_lvds8.tx_data | lvds_top.user_tx_data | LVDS 发送字节 |
| `tx_byte_valid` | 1 | axis32_to_lvds8.tx_valid | lvds_top.user_tx_valid | LVDS 发送有效 |
| `tx_byte_ready` | 1 | lvds_top.user_tx_ready | axis32_to_lvds8.tx_ready | LVDS 发送准备好 |

---

## 四、AXI4-Stream 帧格式规范（复用现有设计）

### 4.1 帧结构总览

所有 AXI4-Stream 报文采用定长帧结构，单拍数据位宽 32-bit，包尾拍同步置位 `tlast` 标识帧结束。

| 帧阶段 | 拍数 | 核心作用 |
|--------|------|----------|
| 包头（SOF） | 固定 1 拍 | 帧头魔数 0xAA + 帧类型 + 净荷长度 + 保留 |
| 净荷域 | 1~3 拍 | 承载地址、数据、选通、响应等业务信息 |
| 包尾（EOF） | 固定 1 拍 | 帧尾魔数 0x55 + 帧状态，同步置 tlast=1 |

### 4.2 四类帧定义

#### 写命令帧（Master → Slave，共 5 拍）

| 节拍 | 帧阶段 | tdata[31:0] | tlast |
|------|--------|-------------|-------|
| 1 | 包头 | {0xAA, 0x01, 0x03, 0x00} | 0 |
| 2 | 净荷1 | AWADDR[31:0] | 0 |
| 3 | 净荷2 | WDATA[31:0] | 0 |
| 4 | 净荷3 | {28'h0, WSTRB[3:0]} | 0 |
| 5 | 包尾 | {0x55, 16'h0000, 0x00} | 1 |

#### 读命令帧（Master → Slave，共 3 拍）

| 节拍 | 帧阶段 | tdata[31:0] | tlast |
|------|--------|-------------|-------|
| 1 | 包头 | {0xAA, 0x02, 0x01, 0x00} | 0 |
| 2 | 净荷1 | ARADDR[31:0] | 0 |
| 3 | 包尾 | {0x55, 16'h0000, 0x00} | 1 |

#### 写响应帧（Slave → Master，共 3 拍）

| 节拍 | 帧阶段 | tdata[31:0] | tlast |
|------|--------|-------------|-------|
| 1 | 包头 | {0xAA, 0x11, 0x01, 0x00} | 0 |
| 2 | 净荷1 | {30'h0, BRESP[1:0]} | 0 |
| 3 | 包尾 | {0x55, 16'h0000, 0x00} | 1 |

#### 读响应帧（Slave → Master，共 4 拍）

| 节拍 | 帧阶段 | tdata[31:0] | tlast |
|------|--------|-------------|-------|
| 1 | 包头 | {0xAA, 0x12, 0x02, 0x00} | 0 |
| 2 | 净荷1 | RDATA[31:0] | 0 |
| 3 | 净荷2 | {30'h0, RRESP[1:0]} | 0 |
| 4 | 包尾 | {0x55, 16'h0000, 0x00} | 1 |

### 4.3 序列化后的字节总量

| 帧类型 | AXI4-Stream 拍数 | 序列化字节数（拍数 × 5） | LVDS MAX_PAYLOAD 限制 |
|--------|------------------|------------------------|----------------------|
| 写命令 | 5 | 25 | 255（满足） |
| 读命令 | 3 | 15 | 255（满足） |
| 写响应 | 3 | 15 | 255（满足） |
| 读响应 | 4 | 20 | 255（满足） |

---

## 五、LVDS 链路层帧格式（复用现有设计）

### 5.1 LVDS 帧结构

LVDS1DLane 逐字节串行帧格式，TX 每 100MHz 并行周期发送 1 字节：

| 周期 | 字节 | 说明 |
|------|------|------|
| 0 | 0xAA (SOF1) | 帧头起始 |
| 1 | 0x55 (SOF2) | 帧头 |
| 2 | TYPE | 帧类型（0x20=用户数据，0x10=心跳，其他=控制帧） |
| 3 | LEN | 负载字节数 |
| 4 ~ 4+LEN-1 | PAYLOAD | 负载，每周期 1 字节 |
| 4+LEN | CHECKSUM | 8bit 累加和（SOF1+SOF2+TYPE+LEN+ΣPAYLOAD） |

### 5.2 AXI4-Stream 帧在 LVDS 帧中的封装

AXI4-Stream 序列化后的字节流作为 LVDS TYPE_USR(0x20) 帧的 PAYLOAD 传输：

```
LVDS 帧：
┌──────┬──────┬──────┬──────┬─────────────────────────────────┬──────────┐
│ SOF1 │ SOF2 │ TYPE │ LEN  │ PAYLOAD                         │ CHECKSUM │
│ 0xAA │ 0x55 │ 0x20 │ N    │ [序列化字节流]                   │ 累加和    │
└──────┴──────┴──────┴──────┴─────────────────────────────────┴──────────┘
                            │                                  │
                            │  N = 帧拍数 × 5                  │
                            │  写命令: N=25                     │
                            │  读命令: N=15                     │
                            │  写响应: N=15                     │
                            │  读响应: N=20                     │
                            └──────────────────────────────────┘
```

### 5.3 帧格式分层关系

```
AXI4-Stream 帧（协议层）           LVDS 帧（链路层）
┌────────────────────┐            ┌───────────────────────────────────┐
│ HEAD {AA,01,03,00} │            │ SOF1=AA, SOF2=55, TYPE=20         │
│ AWADDR             │            │ LEN=25                            │
│ WDATA              │  序列化    │ PAYLOAD:                          │
│ WSTRB              │ ────────►  │   00 00 03 01 AA                  │
│ TAIL {55,00,00,00} │  (25 bytes)│   00 <addr_b0..b3>                │
│                    │            │   00 <data_b0..b3>                │
│                    │            │   00 <strb> 00 00 00              │
│                    │            │   01 00 00 00 55                  │
│                    │            │ CHECKSUM = Σ(all bytes)           │
└────────────────────┘            └───────────────────────────────────┘
```

> **注**：AXI4-Stream 帧头魔数 0xAA 和 LVDS 帧头 SOF1=0xAA 虽然相同，但分属不同协议层，不会产生混淆。LVDS 链路层解析 PAYLOAD 时不做内容解释，仅逐字节转发；AXI4-Stream 协议层在反序列化后的 32-bit 数据中校验魔数。

---

## 六、数据通路与时序分析

### 6.1 写事务端到端时序

```
Master FPGA                                    Slave FPGA
─────────────                                  ──────────

T0: AXI4-Lite AW/W 握手
T1: AW/W → FIFO
T2: WRQ 配对 (pair_armed + 1 拍延迟)
T3: TX 状态机装载帧参数
T4-T8: TX 发送 5 拍命令帧 (32-bit)
      │
      │  T4-T8: 序列化 25 字节 (8-bit)
      │         (每拍 AXI4-Stream → 5 拍 8-bit)
      │
      │  T9-T33: LVDS TX 帧封装 + SERDES
      │          (SOF+SOF+TYPE+LEN+25 payload+CHECKSUM = 29 字节)
      │
      │  ~~~ LVDS 物理传播 ~~~
      │
      │                    T34-T62: LVDS RX SERDES + 链路层解帧
      │                    T63-T87: 反序列化 25 字节 → 5 拍 AXI4-Stream
      │                    T88-T92: axist2native 接收 5 拍命令帧
      │                    T93:     S_EXECUTE 寄存器写入 (1 拍)
      │                    T94-T96: axist2native 发送 3 拍写响应帧
      │
      │  T97-T111: 序列化 15 字节 (8-bit)
      │  T112-T126: LVDS TX 帧封装 + SERDES (19 字节)
      │
      │  ~~~ LVDS 物理传播 ~~~
      │
T127-T145: LVDS RX + 反序列化 15 字节 → 3 拍 AXI4-Stream
T146-T148: axi4lite2axist RX 接收 3 拍响应帧
T149:      B 通道输出 BVALID

端到端延迟 ≈ 149 拍 × 10ns = ~1.5 µs（无反压，无 LVDS 传播延迟）
```

### 6.2 读事务端到端时序

| 阶段 | 拍数 | 累计 | 说明 |
|------|------|------|------|
| AR 入 RDQ FIFO | 1 | 1 | AXI4-Lite AR 握手 |
| TX 装载 | 1 | 2 | 从 RDQ FWFT dout 读取 |
| TX 发送 3 拍 | 3 | 5 | HEAD + ADDR + TAIL |
| 序列化 15 字节 | 15 | 20 | 3 beats × 5 bytes |
| LVDS TX 帧封装 | 4 | 24 | SOF1+SOF2+TYPE+LEN 开销 |
| LVDS SERDES + 传播 | ~5 | 29 | 串行/解串 + 物理延迟 |
| LVDS RX 解帧 | 4 | 33 | 链路层解帧开销 |
| 反序列化 15 字节 | 15 | 48 | → 3 拍 AXI4-Stream |
| axist2native 收包 | 3 | 51 | S_IDLE(包头) + S_RX_PAYLOAD + S_RX_TAIL |
| 执行读 | 1 | 52 | S_EXECUTE |
| 响应回包 4 拍 | 4 | 56 | HEAD + RDATA + RRESP + TAIL |
| 序列化 20 字节 | 20 | 76 | 4 beats × 5 bytes |
| LVDS TX + 传播 + RX | ~13 | 89 | 帧封装 + SERDES + 传播 + 解帧 |
| 反序列化 20 字节 | 20 | 109 | → 4 拍 AXI4-Stream |
| RX 解包 | 4 | 113 | RX_WAIT_HEAD + 2×RX_PAYLOAD + RX_WAIT_TAIL |
| R 通道输出 | 1 | 114 | 从 RRSP FIFO 读出 |
| **总计** | **~114** | **~1.1 µs** | 无反压 |

### 6.3 吞吐量分析

| 场景 | 计算 | 结果 |
|------|------|------|
| 连续写事务 | 每笔 25(TX) + 15(RX) = 40 字节 LVDS 传输，100MHz = 10MB/s | ~25k 笔/s |
| 连续读事务 | 每笔 15(TX) + 20(RX) = 35 字节 LVDS 传输 | ~28k 笔/s |
| LVDS 链路利用率 | 40 字节 / (2 × 255 MAX_PAYLOAD) ≈ 8% | 低负载，无瓶颈 |

---

## 七、建链流程

### 7.1 LVDS 链路建链状态机（复用 lvds_link_manager）

```
                    ┌──────────┐
                    │  S_IDLE  │
                    └────┬─────┘
                         ▼
                    ┌──────────┐
          ┌────────│S_TRAINING│◄────────────────┐
          │        └────┬─────┘                 │
          │             │ rx_phy_ready          │
          │             ▼                       │
          │        ┌──────────┐                 │
          │        │S_WAIT_PEER│                │
          │        └────┬─────┘                 │
          │             │ wait_peer_done        │
          │             ▼                       │
          │        ┌──────────┐                 │
          │        │S_LINK_UP │                 │
          │        └────┬─────┘                 │
          │             │ retrain_req           │
          │             ▼                       │
          │        ┌──────────┐                 │
          └────────│S_RETRAIN │─────────────────┘
                   └──────────┘  retrain_timer
```

### 7.2 建链握手流程

**Master 侧（IS_MASTER=1）**：
1. 上电 → S_IDLE → S_TRAINING：发送训练码（0x55 延迟校准 → 0xB5 字对齐）
2. rx_phy_ready=1 → S_WAIT_PEER：保持训练码，周期性发送控制帧
3. 收到 SLAVE_READY(0x02) → 发送 MASTER_ACK(0x03)
4. 收到 SLAVE_ACK(0x04) 且已发 ≥3 次 MASTER_ACK → S_LINK_UP
5. S_LINK_UP：停止训练，使能用户数据收发（user_tx_en=1, user_rx_en=1），link_all_up=1

**Slave 侧（IS_MASTER=0）**：
1. 上电 → S_IDLE → S_TRAINING：发送训练码
2. rx_phy_ready=1 → S_WAIT_PEER：保持训练码，周期性发送 SLAVE_READY(0x02)
3. 收到 MASTER_ACK(0x03) → 发送 SLAVE_ACK(0x04)
4. SLAVE_ACK 发送成功 → S_LINK_UP
5. S_LINK_UP：停止训练，使能用户数据收发，link_all_up=1

### 7.3 链路建立前的 AXI4-Lite 行为

链路未建立时（link_all_up=0）：
- `user_tx_en=0`：序列化器输出被门控，命令帧无法进入 LVDS TX
- `user_rx_en=0`：LVDS RX 数据被门控，反序列化器无输入
- AXI4-Lite B/R 通道无响应，Master 应设置超时机制

> **建议**：Master PS 侧在发起 AXI4-Lite 事务前轮询 `link_all_up` 状态，或在链路建立后由中断通知 PS。

---

## 八、错误处理与恢复

### 8.1 错误类型与处理

| 错误类型 | 检测机制 | 处理方式 | 恢复时间 |
|----------|----------|----------|----------|
| LVDS 物理层对齐失败 | lvds_rx_phy_1lane: BITSLIP 无法锁定 0xB5 | phy_ready=0, align_err=1 | 自动重训练 |
| LVDS 链路帧校验失败 | lvds_rx_link_1lane: checksum 不匹配 | frame_err_cnt++ | 连续 10 次失败触发重训练 |
| 心跳超时 | lvds_rx_link_1lane: heartbeat_timer 溢出 | retrain_req=1 | 链路管理器重训练 |
| 链路断开 | phy_ready 下降沿 | link_up=0, link_all_up=0 | 自动重训练 |
| AXI4-Stream 帧格式错误 | axist2native: 魔数校验失败 | S_RESYNC 丢弃残余拍 → S_IDLE | 丢弃当前帧，等下一帧 |
| 地址越界 | axist2native: addr_reg[31:2] >= C_REG_NUM | 返回 DECERR(2'b11) | 不影响后续事务 |
| 反序列化 FIFO 溢出 | lvds8_to_axis32: FIFO full | 丢字节（概率极低） | 帧校验失败 → 重训练 |

### 8.2 重训练流程

```
链路故障检测
    │
    ▼
link_manager: S_LINK_UP → S_RETRAIN
    │
    ├──► tx_retrain_pulse (通知 TX 通道重启训练)
    ├──► tx_train_en = 1 (恢复训练码发送)
    ├──► user_tx_en = 0, user_rx_en = 0 (禁止用户数据)
    └──► link_all_up = 0
    │
    ▼ (等待 RETRAIN_WAIT_CYCLES=1000 拍)
    │
S_RETRAIN → S_TRAINING
    │
    ▼ (重新执行训练序列: 0x55 → 0xB5)
    │
    ├──► rx_phy_ready = 1
    │
    ▼ (重新握手: SLAVE_READY → MASTER_ACK → SLAVE_ACK)
    │
S_LINK_UP
    ├──► tx_train_en = 0
    ├──► user_tx_en = 1, user_rx_en = 1
    └──► link_all_up = 1
```

---

## 九、设计约束与限制

### 9.1 功能限制

| 限制项 | 说明 | 影响 |
|--------|------|------|
| Outstanding = 1 | 响应帧无事务 ID，仅靠发送顺序匹配 | 同一时刻只能有 1 笔未完成事务，Master 须等 B/R 响应后才能发下一笔 |
| 数据位宽固定 32-bit | AXI4-Lite 和 AXI4-Stream 均为 32-bit | 不支持 64-bit 或其他位宽 |
| 寄存器数量 ≤ 16 | axist2native 的 REG_IDX_W 最大 4 位 | C_REG_NUM 最大 16 |
| 寄存器 4 字节对齐 | addr[1:0] 被忽略 | 不支持非对齐访问 |
| 无中断回传 | Slave FPGA 无法主动通知 Master | 仅支持 Master 轮询 |

### 9.2 时序约束

| 约束 | 要求 |
|------|------|
| clk_ser (400MHz) | MMCM clk_out1，驱动 OSERDESE2/ISERDESE2 CLK |
| clk_div (100MHz) | MMCM clk_out4，驱动 OSERDESE2/ISERDESE2 CLKDIV + 用户逻辑 |
| ref_clk_200m (200MHz) | MMCM clk_out6，驱动 IDELAYCTRL，须经 BUFG 缓冲 |
| clk_ref (100MHz) | 链路管理器时钟，与 clk_div 同源 |
| aclk = clk_div | AXI4-Lite 桥接与 LVDS 用户接口共享同一时钟域 |
| rst_n | 异步断言、同步释放，脉宽 ≥ 2 个 clk_div 呍期 |

### 9.3 资源预估

| 资源类型 | 估算 | 说明 |
|----------|------|------|
| LUT | ~1500 | axi4lite2axist(~600) + axist2native(~200) + 序列化器(~100×2) + LVDS(~500) |
| FF | ~1200 | 状态机 + FIFO 指针 + 寄存器阵列 |
| BRAM | 0 | 全部使用 distributed RAM (LUT RAM) |
| IDELAYCTRL | 1 | 每个 Slave FPGA 1 个 |
| MMCM | 1 | 每个 FPGA 1 个 (mfpga_clk_ip) |

---

## 十、验证计划

### 10.1 仿真验证

| 阶段 | 工具 | 测试平台 | 覆盖场景 |
|------|------|----------|----------|
| 单元仿真 | ModelSim 10.6d | axis32_to_lvds8 / lvds8_to_axis32 独立 TB | 字节序列化/反序列化正确性、反压、帧边界 |
| 集成仿真 | ModelSim 10.6d | master_lvds_bridge + slave_lvds_bridge 双 DUT | 建链 → 写事务 → 读事务 → 越界 → 重训练 |
| 回归仿真 | ModelSim 10.6d | 现有 AXI4Lite2AXI4ST TB（回环模式） | 确保现有模块行为不受集成影响 |

### 10.2 测试用例

| 用例 | 名称 | 验证点 | 预期结果 |
|------|------|--------|----------|
| TC-01 | 基础单写 | Master 写 Slave reg0 = 0x12345678 | BRESP=OKAY, 读回一致 |
| TC-02 | 基础单读 | Master 读 Slave reg0 | RDATA 正确, RRESP=OKAY |
| TC-03 | AW/W 分离握手 | AW 先发，延迟 3 拍后发 W | 写入正确，BRESP=OKAY |
| TC-04 | 字节选通 | 先全写 0xFFFFFFFF，再写低 2 字节 0x1122 | 读回 0xFFFF1122 |
| TC-05 | 读写并发 | 同时发起写 reg2 和读 reg0 | 轮询仲裁无堵塞，数据正确 |
| TC-06 | 地址越界 | 访问 reg[C_REG_NUM] 以上的地址 | BRESP/RRESP=DECERR, 越界读返回 0xDEADBEEF |
| TC-07 | 连续背靠背 | 对 reg0~3 各写一笔，再依次读回 | 全部一致 |
| TC-08 | 链路断开恢复 | 仿真中注入 LVDS 断链 500µs | 自动重训练，恢复后事务正常 |
| TC-09 | 序列化反压 | LVDS TX FIFO 接近满 | AXI4-Stream tready 正确反压，无数据丢失 |
| TC-10 | 反序列化缓冲 | 下游 AXI4-Stream 暂停接收 | FIFO 正确缓冲，恢复后数据完整 |

### 10.3 板级验证

| 项目 | 方法 |
|------|------|
| 链路建链 | 示波器/逻辑分析仪观测 LVDS 差分信号，确认训练码和建链帧 |
| 寄存器读写 | Master PS 通过 devmem / 应用程序读写 Slave 寄存器 |
| 稳定性 | 长时间（24h+）连续读写压力测试 |
| 热插拔/断电恢复 | 断开 LVDS 线缆后重新连接，验证自动重训练 |

---

## 十一、文件清单

### 11.1 新建文件

| 文件路径 | 说明 |
|----------|------|
| `rtl/axis32_to_lvds8.v` | 32-bit AXI4-Stream → 8-bit 字节序列化器 |
| `rtl/lvds8_to_axis32.v` | 8-bit 字节 → 32-bit AXI4-Stream 反序列化器 |
| `rtl/master_lvds_bridge.v` | Master FPGA 集成顶层 |
| `rtl/slave_lvds_bridge.v` | Slave FPGA 集成顶层 |
| `sim/tb_master_slave_bridge.v` | 集成仿真测试平台 |
| `doc/详细设计文档.md` | 本文档 |

### 11.2 复用文件（不修改）

| 文件路径 | 来源 |
|----------|------|
| `AXI4Lite2AXI4ST/rtl/axi4lite2axist.v` | 现有设计 V5 |
| `AXI4Lite2AXI4ST/rtl/axist2native.v` | 现有设计 V4 |
| `AXI4Lite2AXI4ST/rtl/axi_lite_stream_bridge.v` | 现有设计（仅回环仿真用，集成时不使用） |
| `LVDS1DLane/rtl/lvds_bidirectional_top_1lane.v` | 现有设计 |
| `LVDS1DLane/rtl/lvds_tx_channel_1lane.v` | 现有设计 |
| `LVDS1DLane/rtl/lvds_rx_channel_1lane.v` | 现有设计 |
| `LVDS1DLane/rtl/lvds_rx_phy_1lane.v` | 现有设计 |
| `LVDS1DLane/rtl/lvds_rx_lane_phy.v` | 现有设计 |
| `LVDS1DLane/rtl/lvds_rx_link_1lane.v` | 现有设计 |
| `LVDS1DLane/rtl/lvds_link_manager.v` | 现有设计 |
| `LVDS1DLane/rtl/mfpga_clk_ip.v` | 现有设计 |
| `LVDS1DLane/rtl/mfpga_clk_ip_sim_netlist.v` | 现有设计（仿真用） |
| `LVDS1DLane/rtl/glbl.v` | 现有设计 |

---

## 十二、Slave 寄存器映射（待定义）

> **状态**：寄存器映射待用户补充。当前使用 axist2native 默认配置：
> - C_REG_NUM = 4
> - 地址范围：0x0000_0000 ~ 0x0000_000C（4 字节对齐）
> - 寄存器宽度：32-bit
> - 支持字节选通写入（WSTRB[3:0]）
> - 地址越界返回 DECERR + 0xDEADBEEF

| 地址偏移 | 寄存器名 | 读/写 | 复位值 | 说明 |
|----------|----------|-------|--------|------|
| 0x00 | REG_0 | R/W | 0x0000_0000 | 待定义 |
| 0x04 | REG_1 | R/W | 0x0000_0000 | 待定义 |
| 0x08 | REG_2 | R/W | 0x0000_0000 | 待定义 |
| 0x0C | REG_3 | R/W | 0x0000_0000 | 待定义 |

---

## 附录 A：双层帧格式魔数冲突分析

AXI4-Stream 帧头魔数 0xAA 与 LVDS 帧头 SOF1=0xAA 相同。分析是否会产生冲突：

| 层次 | 魔数位置 | 解析者 | 是否冲突 | 原因 |
|------|----------|--------|----------|------|
| LVDS 链路层 | 帧第 1 字节 = 0xAA | lvds_rx_link_1lane | 否 | LVDS 链路层仅按 SOF1→SOF2→TYPE→LEN 顺序解析帧头，PAYLOAD 内容不解释 |
| AXI4-Stream 协议层 | 帧第 1 拍 tdata[31:24] = 0xAA | axist2native / axi4lite2axist RX | 否 | 反序列化器将 5 字节重组为 32-bit 后，AXI4-Stream 协议层才校验魔数 |

**结论**：两层帧格式的魔数虽然数值相同，但分属不同协议层次，解析时机不同，不会产生冲突。LVDS 链路层完成帧解封后，将 PAYLOAD 字节流交给反序列化器；反序列化器重组为 32-bit AXI4-Stream beat 后，协议层才校验帧头魔数。

---

## 附录 B：关键设计决策记录

| 编号 | 决策 | 选择 | 理由 |
|------|------|------|------|
| D-01 | 帧格式分层 | LVDS 作透传，双层帧封装 | 不修改现有模块，LVDS 链路层与 AXI4-Stream 协议层职责分离 |
| D-02 | 时钟域处理 | aclk = clk_div，无 CDC | 用户确认同源 100MHz |
| D-03 | 宽度转换协议 | 5 字节/beat（1 控制字节 + 4 数据字节） | 自同步，tlast 随控制字节传输，不依赖帧边界检测 |
| D-04 | 反序列化缓冲 | 64 字节 XPM FIFO | LVDS RX 无反压，需 FIFO 缓冲下游暂时不消费的字节 |
| D-05 | 模块复用策略 | 新建 wrapper，不改现有文件 | 保持现有模块的仿真验证状态不被破坏 |
| D-06 | Slave 寄存器 | 待定义，先用 C_REG_NUM=4 通用阵列 | 用户确认待补充 |
| D-07 | 序列化字节序 | LSB first（tdata[7:0] 先发） | 与 Xilinx OSERDESE2 D1=LSB 约定一致 |
