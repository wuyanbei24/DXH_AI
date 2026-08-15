# test_data_gen 规格定义（Spec）

> **版本**：V1.0
> **日期**：2026-08-14
> **模块名**：test_data_gen（可配置位宽测试数据发生器）

---

## 1. 核心约束（来源：原始 spec 定义）

1. 采用 **Verilog** 语言实现；
2. 数据输出位宽 **可配置**（通过参数支持 8 / 16 / 32 / 64 等位宽）；
3. 模块对外接口采用 **AXI4-Stream** 接口。

---

## 2. 功能概述

实现一个测试数据发生器（test data generator），自主产生可控、可验证的测试数据流，通过 AXI4-Stream Master 接口输出，用于 FPGA 内 AI 推理 / 数据通路 / 桥接模块的功能与压力测试。

---

## 3. 对外接口（AXI4-Stream Master）

| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| `m_axis_tdata` | output | DATA_WIDTH | 数据 |
| `m_axis_tvalid` | output | 1 | 有效 |
| `m_axis_tlast` | output | 1 | 帧尾（每帧末拍为高） |
| `m_axis_tuser` | output | TUSER_WIDTH | 用户信号（帧内 beat 序号，诊断用） |
| `m_axis_tready` | input | 1 | 下游准备好（反压） |
| `busy` | output | 1 | 生成忙指示 |

辅助控制接口（与 AXI4-Stream 同源时钟 `aclk`）：
- `aclk` / `aresetn`（低有效异步复位）
- `ctrl_start`：启动一帧的脉冲
- `cfg_mode[1:0]`：生成模式选择
- `cfg_seed[DATA_WIDTH-1:0]`：起始 / 种子值
- `cfg_frame_beats[15:0]`：每帧 beat 数（≥ 1）

---

## 4. 可配置参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `DATA_WIDTH` | 32 | **输出位宽（核心可配置项）** |
| `TUSER_WIDTH` | 8 | tuser 位宽 |
| `DEFAULT_MODE` | 2'b00 | 默认生成模式 |
| `DEFAULT_FRAME_BEATS` | 16 | 默认每帧 beat 数 |

约束：`DATA_WIDTH ≥ 8`，`cfg_frame_beats ≥ 1`。

---

## 5. 数据生成模式

| 模式 | 编码 | 行为 |
|------|------|------|
| INCREMENT | 2'b00 | `tdata = seed, seed+1, seed+2, ...` |
| PRBS | 2'b01 | 线性反馈移位寄存器（位宽 = DATA_WIDTH）伪随机序列 |
| CONSTANT | 2'b10 | `tdata = seed`（恒定） |
| WALK_ONE | 2'b11 | 单 bit 循环左移（建议 seed=1） |

---

## 6. 行为要求

- 每帧由 `cfg_frame_beats` 个 beat 组成，末拍 `tlast=1`；
- 仅在 `m_axis_tready=1` 时通过 AXI4-Stream 握手推进输出；
- `tready=0` 时暂停输出，数据不丢失、计数不前进（天然反压兼容）；
- `ctrl_start` 脉冲触发一帧；帧结束后回到空闲，等待下一次启动；
- 复位后处于空闲，输出清零。

---

## 7. 设计约束

- 语法：Verilog-2001，无 SystemVerilog；
- 单时钟域，无 CDC；
- 低有效异步复位 `aresetn`（异步断言、同步释放）；
- 纯 RTL，无 Xilinx 原语，可跨平台综合与仿真。

---

## 8. 验收标准（仿真）

- 编译 0 错误 0 警告（ModelSim SE-64 10.6d）；
- 四种生成模式输出与参考模型逐拍一致；
- 帧长可配（1 / 64 beats）正确；
- 下游反压（tready 周期拉低）下数据无丢失、无错位；
- 连续多帧重启正确；
- 输出位宽可配置（8-bit 截断 / 64-bit 全宽）正确。

---

## 9. 交付物

| 文件 | 说明 |
|------|------|
| `rtl/test_data_gen.v` | RTL 源代码 |
| `sim/tb_test_data_gen.v` | 仿真测试平台 |
| `sim/run_sim.do` | ModelSim 仿真脚本 |
| `sim/test_data_gen.vcd` | 仿真波形 |
| `doc/test_data_gen_详细设计文档.md` | 详细设计 |
| `doc/test_data_gen_仿真报告.md` | 仿真报告 |
