# axis32_to_lvds8 详细设计文档

> **版本**：V1.0
> **日期**：2026-08-14
> **模块名称**：axis32_to_lvds8
> **功能概述**：将 32-bit AXI4-Stream 接口序列化为 8-bit 字节流，适配 LVDS TX 通道的用户接口
> **目标平台**：Xilinx 7 系列 FPGA（Zynq-7020 / 同系列），Vivado 2018.2，Verilog-2001
> **上游模块**：`axi4lite2axist`（Master 侧）或 `axist2native`（Slave 侧）
> **下游模块**：`lvds_bidirectional_top_1lane` 的 `user_tx_data/valid/ready` 接口

---

## 一、功能描述

### 1.1 设计目标

将 32-bit AXI4-Stream 接口（tdata/tvalid/tlast/tready）序列化为 8-bit 字节流，适配 LVDS TX 通道的 8-bit 用户接口。每个 32-bit AXI4-Stream beat 被序列化为 5 个字节：1 个控制字节 + 4 个数据字节。

### 1.2 在系统中的位置

```
    AXI4-Stream (32-bit)                    LVDS TX User Interface (8-bit)
    ┌──────────────┐                       ┌──────────────┐
    │  tdata[31:0] │  ┌─────────────────┐  │ tx_data[7:0] │
    │  tvalid      │─►│ axis32_to_lvds8 │─►│ tx_valid     │
    │  tlast       │  │   (序列化器)     │  │              │
    │  tready      │◄─│                 │◄─│ tx_ready     │
    └──────────────┘  └─────────────────┘  └──────────────┘
```

该模块在 Master FPGA 和 Slave FPGA 中均被实例化：
- **Master 侧**：序列化 `axi4lite2axist` 输出的命令帧（32-bit → 8-bit）
- **Slave 侧**：序列化 `axist2native` 输出的响应帧（32-bit → 8-bit）

### 1.3 关键特性

| 特性 | 说明 |
|------|------|
| 自同步协议 | 每组 5 字节自带控制字节，无需额外帧边界信号 |
| tlast 透明传输 | tlast 编码在控制字节 bit0，接收端可无损还原 |
| LSB first 字节序 | tdata[7:0] 先发送，与 Xilinx OSERDESE2 D1=LSB 约定一致 |
| 反压传播 | tx_ready=0 时暂停输出，s_axis_tready=0 反压上游 |
| 纯组合/时序逻辑 | 无 Xilinx 原语依赖，可跨平台移植 |

---

## 二、字节级序列化协议

### 2.1 协议定义

每个 32-bit AXI4-Stream beat 序列化为 5 个字节：

```
  Byte 0 (CTRL)   : {7'b0, tlast}     ← 控制字节，bit0 = tlast
  Byte 1 (DATA[0]): tdata[7:0]         ← LSB
  Byte 2 (DATA[1]): tdata[15:8]
  Byte 3 (DATA[2]): tdata[23:16]
  Byte 4 (DATA[3]): tdata[31:24]       ← MSB
```

### 2.2 控制字节格式

```
  Bit 7  Bit 6  Bit 5  Bit 4  Bit 3  Bit 2  Bit 1  Bit 0
┌──────┬──────┬──────┬──────┬──────┬──────┬──────┬──────┐
│  0   │  0   │  0   │  0   │  0   │  0   │  0   │tlast │
└──────┴──────┴──────┴──────┴──────┴──────┴──────┴──────┘
                                                    ↑
                                               tlast 标志位
```

- bit[7:1] = 7'b0：保留位，固定为 0
- bit[0] = tlast：AXI4-Stream 帧尾标志

### 2.3 帧示例 —— 写命令帧（5 beats = 25 bytes）

| AXI4-Stream beat | tdata[31:0] | tlast | 序列化字节（5 bytes） |
|------------------|-------------|-------|----------------------|
| 1 (HEAD) | {0xAA, 0x01, 0x03, 0x00} | 0 | 0x00, 0x00, 0x03, 0x01, 0xAA |
| 2 (ADDR) | AWADDR | 0 | 0x00, ADDR[7:0], ADDR[15:8], ADDR[23:16], ADDR[31:24] |
| 3 (WDATA) | WDATA | 0 | 0x00, DATA[7:0], DATA[15:8], DATA[23:16], DATA[31:24] |
| 4 (WSTRB) | {28'h0, WSTRB[3:0]} | 0 | 0x00, WSTRB, 0x00, 0x00, 0x00 |
| 5 (TAIL) | {0x55, 0x00, 0x00, 0x00} | 1 | 0x01, 0x00, 0x00, 0x00, 0x55 |

### 2.4 各帧类型的序列化字节数

| 帧类型 | AXI4-Stream 拍数 | 序列化字节数（拍数 × 5） |
|--------|------------------|------------------------|
| 写命令 | 5 | 25 |
| 读命令 | 3 | 15 |
| 写响应 | 3 | 15 |
| 读响应 | 4 | 20 |

---

## 三、端口定义

### 3.1 端口列表

```verilog
module axis32_to_lvds8 (
    input  wire        aclk,           // 时钟（100MHz，与 LVDS clk_div 同源）
    input  wire        aresetn,        // 低有效异步复位

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

### 3.2 端口说明

| 端口 | 方向 | 位宽 | 时钟域 | 说明 |
|------|------|------|--------|------|
| `aclk` | input | 1 | — | 100MHz 时钟，与 LVDS clk_div 同源 |
| `aresetn` | input | 1 | — | 低有效异步复位，同步释放 |
| `s_axis_tdata` | input | 32 | aclk | AXI4-Stream 数据输入 |
| `s_axis_tvalid` | input | 1 | aclk | AXI4-Stream 有效信号 |
| `s_axis_tlast` | input | 1 | aclk | AXI4-Stream 帧尾信号 |
| `s_axis_tready` | output | 1 | aclk | AXI4-Stream 准备好信号 |
| `tx_data` | output | 8 | aclk | 输出字节数据 |
| `tx_valid` | output | 1 | aclk | 输出字节有效 |
| `tx_ready` | input | 1 | aclk | 下游准备好信号 |

### 3.3 接口对接关系

| 对接方向 | 对接模块 | 信号映射 |
|----------|----------|----------|
| 上游（AXI4-Stream Slave） | axi4lite2axist.m_axis_cmd_* 或 axist2native.m_axis_rsp_* | tdata→s_axis_tdata, tvalid→s_axis_tvalid, tlast→s_axis_tlast, s_axis_tready→tready |
| 下游（8-bit TX） | lvds_bidirectional_top_1lane.user_tx_* | tx_data→user_tx_data, tx_valid→user_tx_valid, user_tx_ready→tx_ready |

---

## 四、状态机设计

### 4.1 状态定义

采用三段式状态机，6 个状态：

| 状态 | 编码 | 含义 |
|------|------|------|
| `S_IDLE` | 3'd0 | 空闲，等待 AXI4-Stream 握手。s_axis_tready = 1（当 tx_ready=1 时） |
| `S_CTRL` | 3'd1 | 发送控制字节 {7'b0, tlast_hold} |
| `S_B0` | 3'd2 | 发送 tdata[7:0]（LSB） |
| `S_B1` | 3'd3 | 发送 tdata[15:8] |
| `S_B2` | 3'd4 | 发送 tdata[23:16] |
| `S_B3` | 3'd5 | 发送 tdata[31:24]（MSB），完成后回 S_IDLE |

### 4.2 状态转移图

```
                    ┌──────────────┐
              ┌─────│   S_IDLE     │◄──────────────────────┐
              │     │ tready=tx_rdy│                       │
              │     └──────┬───────┘                       │
              │            │ tvalid && tready              │
              │            │ (锁存 tdata/tlast)             │
              │            ▼                                │
              │     ┌──────────────┐                       │
              │     │   S_CTRL     │                       │
              │     │ tx_data={0,  │                       │
              │     │  tlast_hold} │                       │
              │     └──────┬───────┘                       │
              │            │ tx_valid && tx_ready          │
              │            ▼                                │
              │     ┌──────────────┐                       │
              │     │   S_B0       │                       │
              │     │ tx_data=     │                       │
              │     │ tdata[7:0]   │                       │
              │     └──────┬───────┘                       │
              │            │ tx_valid && tx_ready          │
              │            ▼                                │
              │     ┌──────────────┐                       │
              │     │   S_B1       │                       │
              │     │ tx_data=     │                       │
              │     │ tdata[15:8]  │                       │
              │     └──────┬───────┘                       │
              │            │ tx_valid && tx_ready          │
              │            ▼                                │
              │     ┌──────────────┐                       │
              │     │   S_B2       │                       │
              │     │ tx_data=     │                       │
              │     │ tdata[23:16] │                       │
              │     └──────┬───────┘                       │
              │            │ tx_valid && tx_ready          │
              │            ▼                                │
              │     ┌──────────────┐                       │
              └────►│   S_B3       │ (tx_valid && tx_ready)
                    │ tx_data=     │───────────────────────┘
                    │ tdata[31:24] │
                    └──────────────┘
```

### 4.3 状态转移条件

- **S_IDLE → S_CTRL**：当 AXI4-Stream 握手成立（`s_axis_tvalid && s_axis_tready`），锁存 tdata 和 tlast，进入 S_CTRL。
- **S_CTRL → S_B0**：字节握手成功（`tx_valid && tx_ready`）。
- **S_B0 → S_B1**：字节握手成功。
- **S_B1 → S_B2**：字节握手成功。
- **S_B2 → S_B3**：字节握手成功。
- **S_B3 → S_IDLE**：字节握手成功，一个 beat 的 5 字节全部发送完毕。

### 4.4 关键寄存器

| 寄存器 | 位宽 | 说明 |
|--------|------|------|
| `curr_state` | 3 | 当前状态（三段式第一段） |
| `next_state` | 3 | 下一状态（三段式第二段） |
| `tdata_hold` | 32 | 锁存 AXI4-Stream 握手时的 tdata |
| `tlast_hold` | 1 | 锁存 AXI4-Stream 握手时的 tlast |

### 4.5 输出逻辑（三段式第三段）

| 信号 | 条件 | 值 |
|------|------|-----|
| `s_axis_tready` | curr_state == S_IDLE 且 tx_ready == 1 | 1 |
| `s_axis_tready` | 其他 | 0 |
| `tx_valid` | curr_state ∈ {S_CTRL, S_B0, S_B1, S_B2, S_B3} | 1 |
| `tx_valid` | 其他 | 0 |
| `tx_data` | curr_state == S_CTRL | {7'b0, tlast_hold} |
| `tx_data` | curr_state == S_B0 | tdata_hold[7:0] |
| `tx_data` | curr_state == S_B1 | tdata_hold[15:8] |
| `tx_data` | curr_state == S_B2 | tdata_hold[23:16] |
| `tx_data` | curr_state == S_B3 | tdata_hold[31:24] |
| `tx_data` | 其他 | 8'h00 |

---

## 五、反压机制

### 5.1 反压传播路径

```
上游 AXI4-Stream        本模块               下游 LVDS TX
    │                     │                      │
    │  s_axis_tready ◄───┤  ◄── tx_ready ──────┤  FIFO 满 / 训练态
    │                     │                      │
    │  当 tx_ready=0:     │                      │
    │  - tx_valid 保持    │  暂停字节输出          │
    │  - s_axis_tready=0  │  等待 tx_ready=1      │
    │  - 上游保持 tvalid  │                      │
    │                     │                      │
```

### 5.2 反压行为

1. **正常无反压**：tx_ready 始终为 1，每个字节在 1 个时钟周期内完成握手，一个 32-bit beat 需要 6 个周期（1 握手 + 5 字节发送）。

2. **下游反压（tx_ready=0）**：
   - 在 S_IDLE 状态：s_axis_tready=0，不接收新的 AXI4-Stream beat
   - 在 S_CTRL~S_B3 状态：tx_valid 保持为 1，tx_data 保持不变，等待 tx_ready 恢复
   - tx_ready 恢复后，当前字节完成握手，继续下一字节

3. **反压无损保证**：数据在握手时锁存到 tdata_hold/tlast_hold，序列化期间即使上游改变 tdata 也不影响输出正确性。

---

## 六、时序分析

### 6.1 无反压时序

```
时钟周期  AXI4-Stream                  序列化输出(8-bit)
─────────────────────────────────────────────────────────
  T0     tvalid=1, tdata=0xAA010300    tx_valid=0 (S_IDLE, 锁存)
         tready=1 (S_IDLE, tx_ready=1)
  T1     tready=0 (正在序列化)          tx_data=0x00 (CTRL, tlast=0), tx_valid=1
  T2                                   tx_data=0x00 (B0), tx_valid=1
  T3                                   tx_data=0x03 (B1), tx_valid=1
  T4                                   tx_data=0x01 (B2), tx_valid=1
  T5                                   tx_data=0xAA (B3), tx_valid=1
  T6     tvalid=1, tdata=AWADDR        tx_valid=0 (S_IDLE, 锁存)
         tready=1 (S_IDLE, tx_ready=1)
  T7     tready=0                      tx_data=0x00 (CTRL), tx_valid=1
  ...   （继续序列化第 2 个 beat）
```

### 6.2 延迟分析

| 场景 | 周期数 | 延迟（@100MHz） |
|------|--------|-----------------|
| 单 beat 序列化（无反压） | 6 拍（1握手 + 5字节） | 60 ns |
| 写命令帧（5 beats） | 30 拍 | 300 ns |
| 读命令帧（3 beats） | 18 拍 | 180 ns |
| 写响应帧（3 beats） | 18 拍 | 180 ns |
| 读响应帧（4 beats） | 24 拍 | 240 ns |

### 6.3 吞吐量分析

| 指标 | 计算 | 结果 |
|------|------|------|
| 最大字节吞吐率 | 1 byte/100MHz | 10 MB/s |
| AXI4-Stream beat 吞吐率 | 1 beat / 6 cycles | ~16.7 M beats/s |
| 有效数据率 | 32 bit / 6 cycles | ~53.3 Mbps |

---

## 七、复位行为

| 信号 | 复位值 | 说明 |
|------|--------|------|
| curr_state | S_IDLE | 复位后处于空闲状态 |
| tdata_hold | 0 | 数据锁存清零 |
| tlast_hold | 0 | tlast 锁存清零 |
| s_axis_tready | 0 | 复位期间不接收数据 |
| tx_valid | 0 | 复位期间无输出 |
| tx_data | 0x00 | 复位期间输出零 |

复位采用异步断言、同步释放方式（`always @(posedge aclk or negedge aresetn)`），确保复位信号在时钟域内同步释放，避免亚稳态。

---

## 八、设计约束

| 项目 | 约束 |
|------|------|
| 语法标准 | Verilog-2001，无 SystemVerilog |
| 时钟域 | 单时钟域（aclk = clk_div = 100MHz），无 CDC |
| 复位 | 低有效异步复位 aresetn |
| 无 Xilinx 原语 | 纯 RTL，可跨平台综合 |
| 无内部 FIFO | 状态机直接驱动，无缓冲需求 |

---

## 九、验证计划

### 9.1 测试用例

| 用例 | 名称 | 验证点 | 预期结果 |
|------|------|--------|----------|
| TC-01 | 基础单 beat | 单个 32-bit 数据序列化为 5 字节 | 控制字节正确，4 字节数据 LSB first |
| TC-02 | 写命令帧 | 5 beats 写命令帧（HEAD~TAIL） | 25 字节输出正确，tlast 传播正确 |
| TC-03 | 读命令帧 | 3 beats 读命令帧 | 15 字节输出正确 |
| TC-04 | tlast 传播 | 非 tail beat tlast=0，tail beat tlast=1 | 控制字节 bit0 正确反映 tlast |
| TC-05 | 下游反压 | tx_ready 周期性拉低 | tx_valid 保持，数据不丢失，握手正确 |
| TC-06 | 上游反压 | s_axis_tready 在非 IDLE 状态为 0 | 上游正确被反压，无数据丢失 |
| TC-07 | 连续背靠背 | 多个 beat 连续输入 | 每个 beat 正确序列化，无间隙丢失 |
| TC-08 | 复位恢复 | 仿真中途复位 | 状态机回到 S_IDLE，输出清零 |

### 9.2 仿真环境

| 项目 | 配置 |
|------|------|
| 仿真工具 | ModelSim SE-64 10.6d |
| 时钟 | 100MHz（周期 10ns） |
| 复位 | 上电复位 100ns |
| 无 Xilinx 仿真库依赖 | 纯 RTL 仿真 |

---

## 附录：模块文件清单

| 文件 | 说明 |
|------|------|
| `rtl/axis32_to_lvds8.v` | RTL 源代码 |
| `sim/tb_axis32_to_lvds8.v` | 仿真测试平台 |
| `sim/run_sim.do` | ModelSim 仿真脚本 |
| `doc/axis32_to_lvds8_详细设计文档.md` | 本文档 |
