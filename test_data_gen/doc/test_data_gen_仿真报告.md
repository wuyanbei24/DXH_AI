# test_data_gen 仿真报告

> **版本**：V1.0
> **日期**：2026-08-14
> **模块**：test_data_gen
> **仿真工具**：ModelSim SE-64 10.6d
> **仿真结果**：✅ **TEST PASSED**（12/12 通过，0 错误，0 警告）

---

## 一、仿真环境

| 项目 | 配置 |
|------|------|
| 仿真器 | ModelSim SE-64 10.6d（命令行 `-c` 模式） |
| 编译 | `vlog -work work +acc` （RTL + Testbench） |
| 运行 | `vsim -t 1ns -L work work.tb_test_data_gen` → `run -all` |
| 脚本 | `sim/run_sim.do`（`vsim -c -do "do run_sim.do; quit -f"`） |
| 时钟 | 100MHz（周期 10ns），单时钟域 `aclk` |
| 复位 | 上电 `aresetn=0` 持续 50ns，随后释放 |
| 波形 | `sim/test_data_gen.vcd`（`$dumpvars(0, tb_test_data_gen)`） |
| 仿真耗时 | 14435 ns（约 1444 周期），编译 + 仿真共约 4s |

---

## 二、测试平台结构

测试平台 `tb_test_data_gen.v` 例化了 **3 个不同位宽的 DUT**，以验证“输出位宽可配置”这一核心需求：

| 实例 | DATA_WIDTH | 用途 |
|------|-----------|------|
| `u_dut`（主） | 32 | TC-01 ~ TC-07 全部功能与反压测试 |
| `u_dut8` | 8 | TC-08 高位截断验证 |
| `u_dut64` | 64 | TC-09 全 64 位输出验证 |

**自检机制**：
- 输出采集器在 `m_axis_tvalid && m_axis_tready` 时锁存 `tdata` / `tlast`；
- 参考模型 `build_expected()` 按生成模式计算期望序列（PRBS 单步函数 `prbs_step` 与 RTL 完全一致）；
- 逐拍比较，不匹配则 `$display` 报错并累加失败计数。

---

## 三、测试用例与结果

| 用例 | 名称 | 配置 | 结果 |
|------|------|------|------|
| TC-01 | INCREMENT 单帧 | 32-bit, 16 beats, seed=0 | ✅ PASS |
| TC-02 | PRBS 单帧 | 32-bit, 16 beats, seed=0x12345678 | ✅ PASS |
| TC-03 | CONSTANT 单帧 | 32-bit, 8 beats, seed=0xABCDEF00 | ✅ PASS |
| TC-04 | WALK_ONE 单帧 | 32-bit, 32 beats, seed=0x1 | ✅ PASS |
| TC-05a | 帧长可配（1 beat） | 32-bit, 1 beat, seed=0x100 | ✅ PASS |
| TC-05b | 帧长可配（64 beats） | 32-bit, 64 beats, seed=0x200 | ✅ PASS |
| TC-06 | 下游反压 | 32-bit, 32 beats PRBS, `tready` 周期拉低 | ✅ PASS |
| TC-07 | 连续多帧（重启） | 32-bit, 3×10 beats INCREMENT | ✅ PASS ×3 |
| TC-08 | 位宽=8 | 8-bit, 8 beats INCREMENT, seed=0x34 | ✅ PASS（高位截断正确） |
| TC-09 | 位宽=64 | 64-bit, 8 beats INCREMENT, seed=0xAA | ✅ PASS（全位宽正确） |

---

## 四、关键验证点说明

### 4.1 四种生成模式
TC-01~TC-04 分别验证 INCREMENT / PRBS / CONSTANT / WALK_ONE，逐拍数据与参考模型完全一致，且 `tlast` 仅在末拍为高。

### 4.2 帧长可配置（TC-05）
`cfg_frame_beats` 分别取 1 与 64：
- 1 beat 帧：首拍即末拍，`tlast` 在 beat0 置高；
- 64 beat 帧：64 拍序列完整，`tlast` 在 beat63 置高。
证明帧长参数正确生效。

### 4.3 下游反压（TC-06）
在发送 32-beat PRBS 帧期间，测试平台用独立进程周期性拉低 `m_axis_tready`（1 拍有效 / 2 拍无效，共 400 轮）。
- 结果：采集到的 32 字节序列与期望完全一致，无丢失、无错位；
- 证明反压仅暂停输出，不改变数据序列与帧结构。

### 4.4 连续多帧重启（TC-07）
连续 3 次 `ctrl_start` 脉冲，每帧 10 beats INCREMENT。三帧均通过逐拍比较，证明帧间可无缝重启，且 `frame_id` 正确累加。

### 4.5 输出位宽可配置性（TC-08 / TC-09）
- **8-bit 实例**：INCREMENT 序列 `0x34,0x35,...` 高位被正确截断为 8 位；
- **64-bit 实例**：INCREMENT 序列 `0xAA,0xAB,...` 全 64 位正确输出（`0x0000_0000_0000_00AA` 起）。
证明 `DATA_WIDTH` 参数化工作正常，覆盖窄位宽截断与宽位宽全宽两种边界。

---

## 五、编译与运行日志摘要

```
# vlog ... test_data_gen.v  -> Errors: 0, Warnings: 0
# vlog ... tb_test_data_gen.v -> Errors: 0, Warnings: 0
# vsim -t 1ns -L work work.tb_test_data_gen -> run -all

#  test_data_gen Testbench Simulation Start
# [TC-01] ... [PASS] TC-01 INC: 16 beats verified OK
# [TC-02] ... [PASS] TC-02 PRBS: 16 beats verified OK
# [TC-03] ... [PASS] TC-03 CONST: 8 beats verified OK
# [TC-04] ... [PASS] TC-04 WALK: 32 beats verified OK
# [TC-05] ... [PASS] TC-05a INC 1beat / [PASS] TC-05b INC 64beat
# [TC-06] ... [PASS] TC-06 backpressure PRBS: 32 beats verified OK
# [TC-07] ... [PASS] TC-07 frame ×3
# [TC-08] ... [PASS] TC-08: 8-bit width verified OK (truncated)
# [TC-09] ... [PASS] TC-09: 64-bit width verified OK (full width)

#  Simulation Summary
#    Tests passed : 12
#    Tests failed : 0
#    Total errors : 0
#  TEST PASSED
```

---

## 六、结论

test_data_gen 模块在 ModelSim 10.6d 下完成功能仿真，**全部 12 项用例通过，编译 0 错误 0 警告**。
模块满足 spec 三项核心约束（Verilog 语言、输出位宽可配置、AXI4-Stream Master 接口），并额外验证四种数据生成模式、帧长可配、反压兼容与连续重启，功能与时序正确，可进入综合 / 板级验证阶段。

相关文件：`rtl/test_data_gen.v`、`sim/tb_test_data_gen.v`、`sim/run_sim.do`、`sim/test_data_gen.vcd`、`doc/test_data_gen_详细设计文档.md`
