# test_data_gen 详细设计文档

> **版本**：V1.0
> **日期**：2026-08-14
> **模块名称**：test_data_gen
> **功能概述**：可配置位宽测试数据发生器，通过 AXI4-Stream Master 接口输出可配置的测试数据流
> **目标平台**：Xilinx 7 系列 FPGA（Zynq-7020 / 同系列），Vivado 2018.2，Verilog-2001
> **上游模块**：无（由本模块自主产生数据，受 ctrl_start 启动）
> **下游模块**：AI 推理 / 数据处理流水线（消费 AXI4-Stream Master 数据，如 `axis32_to_lvds8` 的 Slave 侧或 AI 加速器 Slave 接口）

---

## 一、功能描述

### 1.1 设计目标

根据 spec 定义，模块需满足：
1. 采用 **Verilog** 语言实现；
2. **数据输出位宽可配置**（通过参数 `DATA_WIDTH` 支持 8 / 16 / 32 / 64 等）；
3. 对外接口采用 **AXI4-Stream Master 接口**。

在此基础上，本设计实现了一个功能完整的测试数据发生器：支持多种数据生成模式、可配置帧长、帧尾 `tlast` 标记，并对下游反压（backpressure）天然兼容。

### 1.2 在系统中的位置

```
           ctrl_start / cfg_mode / cfg_seed / cfg_frame_beats
                          │
                          ▼
    ┌──────────────────────────────┐        AXI4-Stream Master (DATA_WIDTH-bit)
    │          test_data_gen        │ ───► tdata / tvalid / tlast / tuser
    │   (测试数据发生器, 纯 RTL)     │ ◄─── tready (下游反压)
    └──────────────────────────────┘
                          │
                          ▼
                  AI 推理 / 数据处理流水线
```

典型用途：在 FPGA 内对 AI 加速器、数据通路、LVDS/AXI 桥接等模块进行**板级自环 / 压力测试**时，由本模块产生可控、可验证的激励数据。

### 1.3 关键特性

| 特性 | 说明 |
|------|------|
| 位宽可配置 | `DATA_WIDTH` 参数化（默认 32），支持 8/16/32/64 等 |
| AXI4-Stream Master | 标准 `tdata/tvalid/tlast/tready/tuser` 握手 |
| 多生成模式 | INCREMENT（自增）/ PRBS（伪随机）/ CONSTANT（常数）/ WALK_ONE（走 1） |
| 帧结构 | 每帧 `cfg_frame_beats` 个 beat，末拍置 `tlast` |
| 反压兼容 | `tready=0` 时暂停输出，数据不丢、计数不前进 |
| 纯 RTL | 无 Xilinx 原语 / SystemVerilog，可跨平台综合与仿真 |

---

## 二、数据生成模式

生成模式由 `cfg_mode` 选择（复位后默认 `DEFAULT_MODE`）。各模式在当前帧内的第 `k` 拍（`k=0,1,2,...`）输出数据如下：

| 模式 | 编码 | 第 k 拍输出 `tdata` | 说明 |
|------|------|----------------------|------|
| INCREMENT | `2'b00` | `seed + k` | 自增计数，从 `seed` 起始 |
| PRBS | `2'b01` | LFSR 序列第 k 项 | 线性反馈移位寄存器（位宽 = `DATA_WIDTH`，抽头：最高位 / 次高位 / bit1 / bit0） |
| CONSTANT | `2'b10` | `seed` | 恒定值 |
| WALK_ONE | `2'b11` | `seed` 循环左移 k 次 | 单 bit 行走（建议 `seed=1`） |

### 2.1 PRBS 多项式

采用 Fibonacci 型 LFSR，位宽与 `DATA_WIDTH` 一致：
- 反馈位 `fb = reg[DW-1] ^ reg[DW-2] ^ reg[1] ^ reg[0]`
- 下一拍 `reg_next = {fb, reg[DW-1:1]}`（反馈移入最高位，整体右移）

首拍（`k=0`）输出 `seed`；后续各拍为对 `seed` 连续施加 LFSR 的结果。该多项式对任意 `DATA_WIDTH ≥ 8` 均有效，且初值非零（避免全零死锁）。

### 2.2 WALK_ONE 示例（DATA_WIDTH=32，seed=0x1）

```
beat0: 0x0000_0001
beat1: 0x0000_0002
beat2: 0x0000_0004
...
beat31: 0x8000_0000
beat32: 0x0000_0001  (循环回绕)
```

---

## 三、端口定义

### 3.1 端口列表

```verilog
module test_data_gen #(
    parameter integer DATA_WIDTH         = 32,
    parameter integer TUSER_WIDTH        = 8,
    parameter [1:0]  DEFAULT_MODE        = 2'b00,
    parameter integer DEFAULT_FRAME_BEATS = 16
)(
    input  wire                     aclk,
    input  wire                     aresetn,

    // 运行控制
    input  wire                     ctrl_start,         // 脉冲启动一帧
    input  wire [1:0]               cfg_mode,           // 生成模式
    input  wire [DATA_WIDTH-1:0]    cfg_seed,           // 起始/种子值
    input  wire [15:0]              cfg_frame_beats,    // 每帧 beat 数 (>=1)

    // AXI4-Stream Master 输出
    output wire [DATA_WIDTH-1:0]    m_axis_tdata,
    output wire                     m_axis_tvalid,
    output wire                     m_axis_tlast,
    output wire [TUSER_WIDTH-1:0]   m_axis_tuser,
    input  wire                     m_axis_tready,

    // 状态指示
    output wire                     busy                // 正在生成
);
```

### 3.2 端口说明

| 端口 | 方向 | 位宽 | 时钟域 | 说明 |
|------|------|------|--------|------|
| `aclk` | input | 1 | — | 工作时钟（建议 100MHz） |
| `aresetn` | input | 1 | — | 低有效异步复位，异步断言、同步释放 |
| `ctrl_start` | input | 1 | aclk | 启动一帧生成的脉冲（高有效 1 拍） |
| `cfg_mode` | input | 2 | aclk | 生成模式选择（见第二章） |
| `cfg_seed` | input | DATA_WIDTH | aclk | 起始值 / PRBS 种子 |
| `cfg_frame_beats` | input | 16 | aclk | 每帧 beat 数，**必须 ≥ 1** |
| `m_axis_tdata` | output | DATA_WIDTH | aclk | AXI4-Stream 数据 |
| `m_axis_tvalid` | output | 1 | aclk | AXI4-Stream 有效 |
| `m_axis_tlast` | output | 1 | aclk | AXI4-Stream 帧尾（末拍为高） |
| `m_axis_tuser` | output | TUSER_WIDTH | aclk | 用户信号，承载帧内 beat 序号（诊断用） |
| `m_axis_tready` | input | 1 | aclk | 下游准备好 |
| `busy` | output | 1 | aclk | 状态指示，S_RUN 时为高 |

### 3.3 接口对接关系

| 对接方向 | 对接模块 | 信号映射 |
|----------|----------|----------|
| 下游（AXI4-Stream Master） | AI 加速器 / axis32_to_lvds8 的 `s_axis_*` | tdata→s_axis_tdata, tvalid→s_axis_tvalid, tlast→s_axis_tlast, s_axis_tready→tready, tuser→可选 |

---

## 四、参数定义

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `DATA_WIDTH` | integer | 32 | **核心可配置项**：AXI4-Stream 数据位宽 |
| `TUSER_WIDTH` | integer | 8 | `tuser` 位宽（承载帧内 beat 序号） |
| `DEFAULT_MODE` | [1:0] | `2'b00` | 默认生成模式（当 `cfg_mode` 未驱动时的参考值） |
| `DEFAULT_FRAME_BEATS` | integer | 16 | 默认每帧 beat 数（当 `cfg_frame_beats` 未驱动时的参考值） |

> 设计约束：`DATA_WIDTH ≥ 8`（PRBS 抽头与 WALK 循环要求最低位宽）。

---

## 五、状态机设计

### 5.1 状态定义

采用三段式状态机，仅 2 个状态：

| 状态 | 编码 | 含义 |
|------|------|------|
| `S_IDLE` | 1'b0 | 空闲，等待 `ctrl_start` 脉冲；`tvalid=0` |
| `S_RUN` | 1'b1 | 生成并发送数据；每拍握手输出一 beat |

### 5.2 状态转移图

```
              ┌──────────────┐
              │   S_IDLE     │◄───────────────────┐
              │ tvalid = 0   │                    │
              └──────┬───────┘                    │
                     │ ctrl_start 脉冲            │ axis_hs && (beat_cnt == frame_beats-1)
                     ▼                            │ （一帧完成）
              ┌──────────────┐                    │
              │   S_RUN      │────────────────────┘
              │ tvalid = 1   │
              │ (逐拍握手输出) │
              └──────────────┘
```

### 5.3 状态转移条件

- **S_IDLE → S_RUN**：`ctrl_start` 为高（1 拍脉冲），锁存 `cfg_seed` 为首拍数据，进入 S_RUN。
- **S_RUN → S_RUN**：当前拍握手未完成（`!axis_hs`）或尚未到帧尾（`beat_cnt ≠ frame_beats-1`），继续发送。
- **S_RUN → S_IDLE**：当前拍为帧尾且握手成功（`axis_hs && beat_cnt == cfg_frame_beats-1`），一帧结束，回空闲。

### 5.4 关键寄存器

| 寄存器 | 位宽 | 说明 |
|--------|------|------|
| `curr_state` / `next_state` | 1 | 三段式状态机当前/下一状态 |
| `gen_reg` | DATA_WIDTH | 当前输出数据（INC/CONST/WALK 直接驱动；PRBS 由 `prbs_reg` 导出） |
| `prbs_reg` | DATA_WIDTH | PRBS LFSR 状态 |
| `beat_cnt` | 16 | 当前帧内已输出 beat 数（0-based） |
| `frame_id` | TUSER_WIDTH | 已完成帧计数（每帧结束 +1） |

### 5.5 输出逻辑（三段式第三段）

| 信号 | 条件 | 值 |
|------|------|-----|
| `m_axis_tdata` | 任意（S_RUN 期间） | `gen_reg`（首拍 = `cfg_seed`，其后按模式更新） |
| `m_axis_tvalid` | `curr_state == S_RUN` | 1 |
| `m_axis_tvalid` | 其他 | 0 |
| `m_axis_tlast` | `curr_state == S_RUN && beat_cnt == cfg_frame_beats-1` | 1 |
| `m_axis_tuser` | 任意 | `beat_cnt`（帧内 beat 序号） |
| `busy` | `curr_state == S_RUN` | 1 |

数据更新（`axis_hs` 时）：
- `gen_reg <= gen_next`（INC: `+1`；CONST: `= cfg_seed`；WALK: 循环左移；PRBS: `= prbs_next`）
- `prbs_reg <= prbs_next`
- 若 `beat_cnt == cfg_frame_beats-1`：`frame_id <= frame_id + 1`，`beat_cnt <= 0`；否则 `beat_cnt <= beat_cnt + 1`

---

## 六、反压机制

### 6.1 反压传播路径

```
下游（AI 流水线）         本模块               上游控制
    │                     │                      │
    │  m_axis_tready ◄───┤                      │
    │                     │  tready=0 时:        │
    │                     │  - tvalid 保持为高    │
    │                     │  - tdata 保持不变     │
    │                     │  - beat_cnt 不前进    │
    │                     │  等待 tready 恢复     │
```

### 6.2 反压行为

- `m_axis_tready=1`：每个周期完成一次握手，输出一拍数据，`beat_cnt` 递增，直至帧尾。
- `m_axis_tready=0`：`axis_hs=0`，`tvalid` 保持高、`tdata` 与 `beat_cnt` 保持，暂停输出；`tready` 恢复后从当前拍继续，数据零丢失。

由于仅在 `axis_hs` 时更新数据与计数，反压对输出序列无任何影响。

---

## 七、时序分析

### 7.1 无反压时序（INCREMENT，seed=0x10，frame_beats=3）

```
时钟   ctrl_start  m_axis_tvalid  m_axis_tdata  m_axis_tlast  m_axis_tready
─────────────────────────────────────────────────────────────────────────────
 T0       1           0             x             0             1   (启动锁存 seed)
 T1       0           1           0x10            0             1   (beat0)
 T2       0           1           0x11            0             1   (beat1)
 T3       0           1           0x12            1             1   (beat2, tlast, 帧结束)
 T4       0           0             x             0             1   (回到 IDLE)
```

### 7.2 延迟与吞吐

| 指标 | 计算 | 结果（@100MHz, DATA_WIDTH=32） |
|------|------|-------------------------------|
| 单拍输出延迟 | 启动后 1 个时钟周期 | 10 ns |
| 单帧延迟（N beats） | N 个时钟周期（无反压） | N × 10 ns |
| 最大吞吐率 | 1 beat / 周期 | 100 M beats/s（32-bit → 3.2 Gbps） |
| 反压影响 | 仅增加等待周期，不改变序列 | — |

> 吞吐随 `DATA_WIDTH` 线性提升（位宽越宽，每拍携带数据越多）。

---

## 八、复位行为

| 信号 | 复位值 | 说明 |
|------|--------|------|
| `curr_state` | S_IDLE | 复位后处于空闲 |
| `gen_reg` | 0 | 数据清零 |
| `prbs_reg` | 全 1 | 非零 LFSR 初值，避免死锁 |
| `beat_cnt` | 0 | 计数清零 |
| `frame_id` | 0 | 帧计数清零 |
| `m_axis_tvalid` | 0 | 复位期间无输出 |
| `m_axis_tdata` | 0 | 复位期间输出零 |
| `busy` | 0 | 复位期间非忙 |

复位采用异步断言、同步释放（`always @(posedge aclk or negedge aresetn)`），确保复位在时钟域内同步释放，避免亚稳态。

---

## 九、设计约束

| 项目 | 约束 |
|------|------|
| 语法标准 | Verilog-2001，无 SystemVerilog |
| 时钟域 | 单时钟域 `aclk`，无 CDC |
| 复位 | 低有效异步复位 `aresetn` |
| 无 Xilinx 原语 | 纯 RTL，可跨平台综合 |
| 位宽约束 | `DATA_WIDTH ≥ 8`，`cfg_frame_beats ≥ 1` |
| 仿真依赖 | 纯 RTL 仿真，无需 Xilinx 仿真库 |

---

## 十、验证计划

### 10.1 测试用例

| 用例 | 名称 | 验证点 | 预期结果 |
|------|------|--------|----------|
| TC-01 | INCREMENT 单帧 | 自增计数 + tlast | 16 beats 递增，末拍 tlast=1 |
| TC-02 | PRBS 单帧 | 伪随机序列 + tlast | 16 beats PRBS 正确 |
| TC-03 | CONSTANT 单帧 | 恒定数据 | 8 beats 恒等于 seed |
| TC-04 | WALK_ONE 单帧 | 走 1 序列 | 32 beats 循环左移正确 |
| TC-05 | 帧长可配 | 1 / 64 beats | tlast 在正确位置 |
| TC-06 | 下游反压 | tready 周期拉低 | 数据完整有序、无丢失 |
| TC-07 | 连续多帧 | ctrl_start 重复触发 | 3 帧均正确 |
| TC-08 | 位宽=8 | INCREMENT | 高位正确截断 |
| TC-09 | 位宽=64 | INCREMENT | 全 64 位正确 |

### 10.2 仿真环境

| 项目 | 配置 |
|------|------|
| 仿真工具 | ModelSim SE-64 10.6d |
| 时钟 | 100MHz（周期 10ns） |
| 复位 | 上电复位 50ns |
| 自检机制 | 参考模型 + 逐拍比较 |

---

## 附录：模块文件清单

| 文件 | 说明 |
|------|------|
| `rtl/test_data_gen.v` | RTL 源代码 |
| `sim/tb_test_data_gen.v` | 仿真测试平台（32/8/64-bit 三实例） |
| `sim/run_sim.do` | ModelSim 仿真脚本 |
| `sim/test_data_gen.vcd` | 仿真波形（由 `$dumpvars` 生成） |
| `doc/test_data_gen_详细设计文档.md` | 本文档 |
| `doc/test_data_gen_仿真报告.md` | 仿真结果报告 |
| `spec/test_data_gen.spec.md` | 模块规格定义 |
