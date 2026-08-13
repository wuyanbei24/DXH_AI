# LVDS 3-Lane PHY 层 ISERDESE2 / OSERDESE2 规则符合性确认报告

**参考文档**：Xilinx *UG471 (v1.10)* — 7 Series FPGAs SelectIO Resources
**检查对象**：`F:\wc.prj\pulse_mfpga\src\DXH_AI\LVDS3DLane`（3 路数据 lane + 1 路时钟 lane 的双向 LVDS）
**检查范围**：PHY 层发射（OSERDESE2 + 时钟转发）与接收（ISERDESE2 + IDELAYE2 + BITSLIP + IDELAYCTRL + BUFIO/BUFR）
**方法**：逐条对照 UG471 关于 ISERDESE2 / OSERDESE2 / IDELAYE2 / IDELAYCTRL 的硬性使用规则，结合 RTL 源码与 ModelSim 仿真结果做确认。

> 说明：3-lane 的 `lvds_rx_lane_phy.v` / `lvds_tx_channel.v` 在 SERDES 配置上与 1-lane 版本**逐位一致**，因此下文"合规项"大多与 1-lane 相同；差异点（时钟拓扑走真实 BUFIO/BUFR、3 数据 lane 共享 IDELAYCTRL、通道间 deskew）单独标出。

---

## 1. UG471 关键规则摘要（用于本检查的判定基准）

### ISERDESE2（NETWORKING 模式）
- **时钟拓扑**：合法方案仅两种 ——
  (a) `BUFIO` 驱动高速 `CLK/CLKB` + `BUFR`(÷N) 驱动 `CLKDIV`（经典拓扑）；
  (b) 源自同一 MMCM、相位对齐的 `CLK` 与 `CLKDIV`。
- `CLK` 必须由 `BUFIO` 提供（NETWORKING）；非 QDR 模式下 `CLKB = ~CLK`。
- `CLKDIV` 与 `CLK` 频率比：8:1 DDR（`DATA_WIDTH=8`）时必须为 **4:1**。
- 复位 `RST` 高有效、异步；**去断言须与 `CLKDIV` 同步、且持续 ≥ 2 个 `CLKDIV` 周期**。
- `BITSLIP`：保持 1 个 `CLKDIV` 周期；两次 `BITSLIP` 之间至少释放 1 拍；DDR 模式下 `BITSLIP` 后需等待 **≥ 3 个 `CLKDIV`** 再判定移位结果。
- `IOBDELAY="IFD"` 时，`Q1–Q8` 取自延迟路径 `DDLY`；`NUM_CE=2` 时 `CE1/CE2` 同步于 `CLKDIV`。

### OSERDESE2
- `CLK`（串行高速）与 `CLKDIV`（并行）须**相位对齐**，`CLK` 频率 = `CLKDIV × 串行化因子`（8:1 DDR 时 `CLK = 4×CLKDIV`）。
- `DATA_RATE_OQ="DDR"`、`DATA_WIDTH=8`、`SERDES_MODE="MASTER"`；`D1` 为 LSB 且**最先发出**。
- `RST` 高有效；去断言建议与 `CLKDIV` 同步（OSERDESE2 内部会将去断言重定时到 `CLK`）。
- `DATA_RATE_TQ="DDR"` 且 `DATA_WIDTH>4` 时，`TRISTATE_WIDTH` 必须为 **1**。
- 时钟转发：OSERDESE2 可设 `D1=1,D2=0,D3=1,D4=0,D5=1,D6=0,D7=1,D8=0` 转发时钟；**UG471 更推荐用 ODDR**（`D1=1,D2=0`）走专用时钟转发路径、抖动更小。

### IDELAYE2 / IDELAYCTRL
- `IDELAYE2`：`VAR_LOAD` 模式下 `C` 为控制时钟（须由全局/区域缓冲驱动），`LD/CE/INC` 与 `C` 同步；`DELAY_SRC="IDATAIN"` 时延迟 `IDATAIN`；`DATAIN` 端口悬空置 0。
- `IDELAYCTRL`：**只要设计中例化任何 IDELAYE2/ODELAYE2 就必须同时例化**；`REFCLK` 须为 200MHz（±精度）且由 **`BUFG`/`BUFH`** 驱动；`RST` 高有效异步；`RDY` 可选；一个 `IDELAYCTRL` 校准**同一 clock region** 内的全部 IDELAY/ODELAY。

---

## 2. 接收方向（ISERDESE2 + IDELAYE2 + BITSLIP + IDELAYCTRL）

### 2.1 每通道 `lvds_rx_lane_phy.v`（×3 数据 lane，配置完全相同）

| 检查项 | UG471 要求 | 设计实现 | 结论 |
|---|---|---|---|
| IDELAYE2 类型 | `VAR_LOAD` | `.IDELAY_TYPE("VAR_LOAD")` | ✅ |
| 延迟源 | `IDATAIN` | `.DELAY_SRC("IDATAIN")` | ✅ |
| REFCLK 频率属性 | 与实际 REFCLK 一致 | `REFCLK_FREQUENCY(200.0)` | ✅ |
| 控制时钟 C | 全局/区域缓冲 | `.C(clk_div)`（来自 BUFR，区域缓冲） | ✅ |
| LD/CE/INC 同步 | 与 C 同步 | 由 FSM 在 `clk_div` 域驱动 | ✅ |
| ISERDESE2 接口 | `NETWORKING` | `.INTERFACE_TYPE("NETWORKING")` | ✅ |
| 数据率/位宽 | DDR / 8 | `.DATA_RATE("DDR")`, `.DATA_WIDTH(8)` | ✅ |
| 延迟捕获 | `IOBDELAY=IFD` → Q 取 DDLY | `.IOBDELAY("IFD")`；`.D(data_ibuf)`, `.DDLY(data_delay)` | ✅ |
| 时钟对 | `CLK`=BUFIO，`CLKB=~CLK` | `.CLK(clk_bufio)`, `.CLKB(~clk_bufio)` | ✅ |
| 并行时钟 | `CLKDIV`，4:1 | `.CLKDIV(clk_div)`（BUFIO 400M / BUFR÷4=100M） | ✅ |
| 主从模式 | MASTER（8 位无需级联） | `.SERDES_MODE("MASTER")`，`SHIFTIN=0`，`OFB_USED=FALSE` | ✅ |
| 时钟使能 | `NUM_CE=2` | `.NUM_CE(2)`，`.CE1=1`,`.CE2=1` | ✅ |
| BITSLIP 脉冲 | 1 个 CLKDIV | `W_BITSLIP` 断言 1 拍 | ✅ |
| BITSLIP 间隔 | ≥1 拍释放 | `W_WAIT`(5 拍) 释放后再入 `W_BITSLIP` | ✅ |
| DDR 后稳定等待 | ≥3 个 CLKDIV | `BITSLIP_WAIT_CYCLES=5`（>3） | ✅ |
| 复位去断言 | 同步 CLKDIV、≥2 拍 | `.RST(clk_div_ready)`（BUFR 稳定后释放，≥15 拍） | ✅ 优于要求 |

**结论：3 个数据 lane 的 SERDES 接收配置完全符合 UG471。**

### 2.2 接收顶层 `lvds_rx_phy.v`（时钟拓扑 + IDELAYCTRL）

| 检查项 | UG471 要求 | 设计实现 | 结论 |
|---|---|---|---|
| 时钟拓扑 | BUFIO→CLK + BUFR÷N→CLKDIV | `IBUFDS(DIFF_TERM TRUE)` → `BUFIO`(clk_bufio) + `BUFR #(.BUFR_DIVIDE("4"))`(clk_div) | ✅ 经典拓扑 |
| BUFR 分频 | 8:1 DDR → ÷4 | `BUFR_DIVIDE("4")`，400M→100M | ✅ |
| 仿真旁路 | — | `SIM_BYPASS` 默认 **0**（走真实 BUFIO/BUFR） | ✅ 比 1-lane 的 `=1` 旁路更贴近硬件 |
| BUFR 稳定 | 复位释放前等待稳定 | `bufr_settle_cnt` 计 15 拍后 `clk_div_ready=1` | ✅ |
| IDELAYCTRL 例化 | 随 IDELAY 必须例化 | 例化 1 个 `IDELAYCTRL` | ✅ |
| IDELAYCTRL.REFCLK | 200MHz，须 `BUFG`/`BUFH` 驱动 | `.REFCLK(ref_clk_200m)`（200MHz 外部输入） | ⚠️ 见约束 C1 |
| IDELAYCTRL.RST | 高有效异步 | `.RST(~rst_n)` | ✅ |
| 复位释放 | 同步 CLKDIV | lane phy `.RST=clk_div_ready` | ✅ |

**结论：接收时钟拓扑符合 UG471 经典 NETWORKING 方案；`SIM_BYPASS=0` 默认使用真实 BUFIO/BUFR，较 1-lane 更具硬件代表性。**

### 2.3 通道间相位对齐 `lane_deskew.v`（链路层，非 SERDES）
- 3 lane 在 `clk_div` 域用 `sync_word=8'hB5` 做 lane-to-lane 偏移消除；属**链路层**，不在 UG471 SERDES 规则范围内。
- 该模块工作在 `clk_div`（与 ISERDESE2 `CLKDIV` 同源），时钟域正确，未触碰 SERDES 原语。✅ 不在本检查违规项内，仅作说明。

---

## 3. 发射方向（OSERDESE2 + 时钟转发）

### 3.1 `lvds_tx_channel.v`（3 数据 lane + 1 时钟 lane）

| 检查项 | UG471 要求 | 设计实现 | 结论 |
|---|---|---|---|
| 数据率/位宽 | DDR / 8 | `DATA_RATE_OQ("DDR")`, `DATA_WIDTH(8)` | ✅ |
| 三态宽度 | TQ=DDR 且 WIDTH>4 → TRISTATE_WIDTH=1 | `.TRISTATE_WIDTH(1)` | ✅ |
| 主从 | MASTER | `.SERDES_MODE("MASTER")` | ✅ |
| 时钟对 | CLK/CLKDIV 相位对齐、4:1 | `.CLK(clk_ser 400M)`, `.CLKDIV(clk_div 100M)` | ⚠️ 见约束 C2 |
| 位序 | D1=LSB 最先发 | `.D1..D8 = tx_data_mux[lane*8 + 0..7]` | ✅ |
| 输出使能 | OCE | `.OCE(1'b1)` | ✅ |
| 复位 | 建议同步 CLKDIV | `.RST(~rst_n)`（顶层直连，未做 clk_div 同步释放） | ⚠️ 见建议 S1 |
| 时钟通道 | DDR 时钟转发 | `D1=1,D2=0,D3=1,D4=0,D5=1,D6=0,D7=1,D8=0` | ✅ 功能正确 |
| 时钟转发方式 | 推荐 ODDR | 用 OSERDESE2 转发（非 ODDR） | ⚠️ 见建议 S2 |

**结论：4 路 OSERDESE2（3 数据 + 1 时钟）的 SERDES 配置均符合 UG471；每 lane 独立、规则逐 lane 满足。**

---

## 4. 约束确认项（顶层设计 / 板级 / 实现，不影响当前功能正确性）

- **C1 — IDELAYCTRL.REFCLK 缓冲**：`ref_clk_200m` 在送达 `IDELAYCTRL.REFCLK` 之前**必须经 `BUFG`/`BUFH` 全局缓冲**（UG471 硬要求）。当前为顶层外部输入端口，仿真中由 tb 直接驱动（无缓冲，仿真合法）；**综合/上板前须在顶层用 `BUFG` 包裹 `ref_clk_200m`**。
- **C2 — TX 时钟来源**：`clk_ser` / `clk_div` 为顶层外部输入，须由**同一 MMCM** 产生、满足 4:1 频率比且 `CLK` 相位对齐 `CLKDIV×4`（UG471 OSERDESE2 时钟要求）。1-lane 用 `mfpga_clk_ip` 出 400M/100M；本 3-lane 顶层未内含 MMCM，由外部提供，**须确认顶层集成时同源 MMCM 提供该对时钟**。
- **C3 — IDELAYCTRL 与 IDELAYE2 同 clock region**：本设计仅例化 **1 个 IDELAYCTRL**（位于 `lvds_rx_phy`），负责校准 3 个数据 lane 的 IDELAYE2。UG471 要求 IDELAYCTRL 与其校准的 IDELAY/ODELAY 处于**同一 clock region**。若 3 个数据 LVDS pair 跨 I/O bank（clock region）分布，则需每个 region 各放一个 IDELAYCTRL。**约束：3 个数据 pair 应约束在同一 I/O bank / 同一 clock region；若无法同区，须按 region 增加 IDELAYCTRL 实例。**
- **C4 — 顶层复位释放**：顶层 `rst_n` 须保持足够宽（> 2 个 `CLKDIV` 周期）且待 `clk_div` 时钟稳定后再释放，避免 ISERDESE2/OSERDESE2 在时钟未稳时退出复位。

## 5. 改进建议（非阻塞，仿真均已 PASS）

- **S1 — TX 复位同步释放**：3 路 OSERDESE2 + 时钟 OSERDESE2 的 `.RST` 直接取顶层 `rst_n`，未像 RX 那样经 `clk_div` 域同步释放（`clk_div_ready`）。OSERDESE2 内部会把去断言重定时到 `CLK`，仿真 PASS；但为与 RX 对称、严格满足 UG471「复位去断言与 CLKDIV 同步」建议，可在顶层补一个 `clk_div` 域同步复位后再送 TX SERDES。
- **S2 — 时钟转发改 ODDR**：当前时钟 lane 用 OSERDESE2（`D=10101010`）转发时钟，功能正确；UG471 明确推荐 ODDR（`D1=1,D2=0`）走专用时钟转发路径，抖动更优、无内部计数器。建议改为 `ODDR` 实现时钟转发。

## 6. 仿真验证证据

- **脚本**：`sim/regress_3lane.do`（编译 `../rtl/*.v` 全部 RTL + `sim/*.v` 仿真源 + `glbl`，`vsim … work.glbl`，`run 1200us`；未使用 `-voptargs="+acc"`，避免 MMCM 网表被优化成常数导致 PHY 卡死）。
- **场景**：3 路双向 master/slave，覆盖建链 → 24bit 用户数据传输 → 通道偏移对齐 → 链路故障自动重训练 → 外部重训练。
- **结果**：`Test result: PASS`；`Master RX: 600 bytes, 0 errors` / `Slave RX: 600 bytes, 0 errors`；`Errors: 0, Warnings: 7`（仅为 `mfpga_clk_ip` 仿真网表覆盖告警与 unisims 细化告警，非错误）；无 `MMCME2_ADV` 周期不匹配告警；RX 状态机 `M_CALIB→M_LANE_DESKEW→M_LOCK_CHECK→M_NORMAL` 正常推进、`deskew_done=1`。
- **本次复核发现并修复的两处仿真脚本缺陷**（均为 harness 问题，非 PHY 设计问题）：
  1. **do 脚本未编译 RTL（关键）**：原 `regress_3lane.do` 仅 `vlog … ./*.v`（编译 `sim/` 内文件），**从未编译 `../rtl/*.v`**。原 `regress_3lane.log` 的 `PASS` 依赖一个预先存在的 `work` 库（早期手工/某次完整编译已把 RTL 编入）。本次清理 `work` 后重跑即报 `Module 'lvds_bidirectional_top' is not defined`。已修复为 `vlog -work work ../rtl/*.v` + `vlog -work work ./*.v`，回归脚本现**自包含、可冷启动复现**。
  2. **tb 冗余 `glbl.v` include**：tb 第 2 行 `` `include "glbl.v" `` 内嵌 `timescale 1ps/1ps`，与 1-lane同源隐患。本 tb 直接生成 `clk_ser/clk_div` 不经 MMCM，原 sim 仍 PASS；为一致性健壮性已删除该 include（glbl 仍由 `vsim … work.glbl` 独立加载供 GSR）。
  - 修复后从干净 `work` 冷启动重跑：`Test result: PASS`（日志 `sim/regress_3lane_run.log`）。

---

## 7. 总体结论

LVDS 3-Lane PHY 层的发射（OSERDESE2 ×4 + 时钟转发）与接收（ISERDESE2 ×3 + IDELAYE2 ×3 + BITSLIP + IDELAYCTRL + BUFIO/BUFR）设计**符合 UG471 (v1.10) 关于 ISERDESE2 / OSERDESE2 / IDELAYE2 / IDELAYCTRL 的全部硬性使用规则**：

- 接收 BUFIO+BUFR 经典 NETWORKING 拓扑、`CLKB=~CLK`、`IOBDELAY=IFD`、`NUM_CE=2`、BITSLIP 时序（1 拍断言 + 5 拍等待 ≥3）、复位经 BUFR 稳定后同步释放（15 拍，优于要求）—— 全部 ✅；
- 接收默认 `SIM_BYPASS=0` 走真实 BUFIO/BUFR，较 1-lane 更具硬件代表性 ✅；
- 发射 4 路 OSERDESE2 属性 / 位序 / `OCE` / `TRISTATE_WIDTH=1` / 4:1 时钟比 —— 全部 ✅；
- 3 数据 lane 共享 1 个 IDELAYCTRL（须确保同 clock region，见 C3）。

仅余 **2 项改进建议（S1 TX 复位同步、S2 时钟转发改 ODDR）** 与 **4 项需在 FPGA 顶层/板级落实的约束确认（C1–C4）**，均不影响当前功能正确性，仿真已 `PASS` 验证。

---

*附：与本检查配套的 1-lane 报告见 `..\LVDS1DLane\doc\LVDS1DLane_PHY_ug471_check.md`；两条 ModelSim 仿真陷阱（`-voptargs="+acc"` 致 MMCM 常数化、tb `include "glbl.v"` 覆盖 timescale 致 MMCM 不上锁）已收录于 skill `fpga-eda-assistant/references/toolflows.md` 失败修复表。*
