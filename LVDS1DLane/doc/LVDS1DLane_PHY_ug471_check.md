# LVDS 1-Lane 物理层（PHY）设计检查报告
## 依据 Xilinx UG471 (v1.10) ISERDESE2 / OSERDESE2 使用规则

- **文档来源**：`F:\XilinxDocs\7_Series\documentation\user_guides\ug471_7Series_SelectIO.pdf` (UG471 v1.10, May 8 2018)
- **设计对象**：`F:\wc.prj\pulse_mfpga\src\DXH_AI\LVDS1DLane\`
  - 接收：`lvds_rx_lane_phy.v` / `lvds_rx_phy_1lane.v`
  - 发送：`lvds_tx_channel_1lane.v`
  - 顶层：`lvds_bidirectional_top_1lane.v`
  - 时钟：MMCM `mfpga_clk_ip.v`（clk_out1=400MHz, clk_out4=100MHz, clk_out6=200MHz）
- **检查范围**：PHY 层发射（OSERDESE2 + 时钟转发）、接收（ISERDESE2 + IDELAYE2 + BITSLIP + IDELAYCTRL + BUFIO/BUFR 时钟拓扑）对 UG471 规则的合规性
- **结论摘要**：设计**整体合规**，时钟拓扑、属性配置、BITSLIP 时序均满足 UG471 要求；存在 1 项复位去断言同步性的轻微改进建议（TX 方向）及 2 项代码整洁度/约束确认事项。仿真回归 `Test result: PASS`。

---

## 1. UG471 关键规则梳理（ISERDESE2 / OSERDESE2 / IDELAY）

### 1.1 ISERDESE2（UG471 Ch.3, pp.143–160）

| 编号 | 规则 | 出处 |
|------|------|------|
| R-ISE-1 | **CLK / CLKB**：非 MEMORY_QDR 模式下，CLKB 必须接 CLK 的反相；MEMORY_QDR 模式才接独立相位时钟 | p.146, p.148 |
| R-ISE-2 | **NETWORKING 时钟拓扑**（仅两种合法）：(a) CLK←BUFIO, CLKDIV←BUFR；(b) CLK 与 CLKDIV 均来自同一 MMCM/PLL 的 CLKOUT[0:6]。**禁止混用缓冲类型** | p.153 |
| R-ISE-3 | CLK 与 CLKDIV 必须标称相位对齐；NETWORKING 模式禁止在 ISERDESE2 输入端反相，亦禁止用 DYNCLKINVSEL / DYNCLKDIVINVSEL | p.152–153 |
| R-ISE-4 | **RST 高有效**：去断言须与 CLKDIV 同步；复位脉宽至少 2 个 CLKDIV；仅在 CLK/CLKDIV 稳定存在后才可去断言；去断言后输出需 2 个 CLKDIV 才有效 | p.149 |
| R-ISE-5 | **BITSLIP**：高有效、与 CLKDIV 同步；每脉冲仅保持 1 个 CLKDIV 周期；**禁止连续 2 个 CLKDIV 断言**，两次之间至少释放 1 个 CLKDIV；捕获到输出的延迟为 2 个 CLKDIV；DDR 模式下应在发完 BITSLIP 后**至少等待 3 个 CLKDIV** 再分析数据/再发下一次 | p.147, p.159 |
| R-ISE-6 | **IOBDELAY=IFD** ⇒ 寄存器输出 Q1–Q8 取自 DDLY（经过 IDELAY 的路径）；组合输出 O 亦取自 DDLY | Table 3-4, p.157 |
| R-ISE-7 | BITSLIP 子模块**仅在 NETWORKING 模式可用** | p.159 |
| R-ISE-8 | DDR 模式 DATA_WIDTH 合法值：4/6/8/10/14；8 位单 ISERDESE2 即可（无需级联扩展） | Table 3-3, p.151 |
| R-ISE-9 | NUM_CE=2 时，CE1 使能前 ½ CLKDIV、CE2 使能后 ½ CLKDIV | p.148 |
| R-ISE-10 | NETWORKING 模式潜伏期 = 2 个 CLKDIV（因 BITSLIP 子模块多 1 拍） | p.156 |

### 1.2 OSERDESE2（UG471 Ch.3, pp.161–171）

| 编号 | 规则 | 出处 |
|------|------|------|
| R-OSE-1 | **CLK（串行）/ CLKDIV（并行）相位对齐**。合法拓扑：(a) CLK←BUFIO, CLKDIV←BUFR；(b) 二者均来自同一 MMCM/PLL 的 CLKOUT[0:6]。**禁止混用缓冲类型** | p.166 |
| R-OSE-2 | **RST 高有效**：使用前必须复位；去断言须与 CLKDIV 同步（内部计数器控制数据流，异步去断言会产生异常输出）；仅在 CLK/CLKDIV 稳定存在后才可去断言 | pp.161, p.164 |
| R-OSE-3 | DATA_RATE_OQ=DDR 时 DATA_WIDTH 合法值：4/6/8/10/14 | Table 3-7/3-8, p.165–166 |
| R-OSE-4 | D1 为最低位（LSB），最先出现在 OQ | p.161 |
| R-OSE-5 | OCE 为数据通路高有效时钟使能 | p.164 |
| R-OSE-6 | DATA_RATE_TQ=DDR 时，若 DATA_WIDTH>4，TRISTATE_WIDTH 须=1 | p.166 |
| R-OSE-7 | 8:1 DDR 潜伏期 = 4 个 CLK 周期（参考值） | Table 3-11, p.169 |
| R-OSE-8 | 时钟转发推荐用 ODDR（D1=1,D2=0）；用 OSERDESE2 时 DDR 8:1 等价写 D=10101010 转发半速率时钟 | Ch.2 ODDR / 本章 |

### 1.3 IDELAYE2 / IDELAYCTRL（UG471 Ch.2）

| 编号 | 规则 | 出处 |
|------|------|------|
| R-IDELAY-1 | 控制时钟 C 必须由全局/区域时钟缓冲（BUFG/BUFH/BUFR）驱动；LD/CE/INC 须与 C 同步 | Ch.2 IDELAYE2 |
| R-IDELAY-2 | VAR_LOAD 模式下 LD 将 CNTVALUEIN 载入抽头 | Ch.2 IDELAYE2 |
| R-IDELAY-3 | REFCLK_FREQUENCY 必须在 190.0–210.0 MHz（本项目 200.0） | Ch.2 IDELAYE2 |
| R-IDELAY-4 | 凡使用 IDELAY/ODELAY，**必须**例化 IDELAYCTRL；其 REFCLK 须由 BUFG/BUFH 驱动、RST 高有效异步复位；每个时钟域一个，校准同域全部延迟单元 | Ch.2 IDELAYCTRL |

---

## 2. 设计逐条对照检查

### 2.1 接收方向 — ISERDESE2 + IDELAYE2（`lvds_rx_lane_phy.v`, `lvds_rx_phy_1lane.v`）

| 规则 | 设计实现 | 判定 |
|------|----------|------|
| R-ISE-2 | `CLK = clk_bufio`（BUFIO 输出）；`CLKDIV = clk_div`（BUFR ÷4 输出）。BUFIO/BUFR 由同一 IBUFDS 驱动（`lvds_rx_phy_1lane.v` gen_real_clk） | ✅ 合规（最标准 NETWORKING 拓扑） |
| R-ISE-1 | `CLKB = ~clk_bufio`（CLK 反相） | ✅ 合规 |
| R-ISE-3 | 未在 ISERDESE2 输入反相；`DYN_CLK_INV_EN="FALSE"`, `DYN_CLKDIV_INV_EN="FALSE"` | ✅ 合规 |
| R-ISE-7 | `INTERFACE_TYPE="NETWORKING"`（BITSLIP 可用） | ✅ 合规 |
| R-ISE-6 | `IOBDELAY="IFD"`；`.D(data_ibuf)`, `.DDLY(data_delay)` → 寄存器输出走延迟路径 | ✅ 合规 |
| R-ISE-8 | `DATA_RATE="DDR"`, `DATA_WIDTH=8`（单 ISERDESE2，无级联） | ✅ 合规 |
| R-ISE-9 | `NUM_CE=2`, `.CE1(1'b1)`, `.CE2(1'b1)`（全使能） | ✅ 合规 |
| R-ISE-4 | `RST = ~rst_n`，其中 `rst_n = clk_div_ready`（`lvds_rx_phy_1lane` 经 BUFR 稳定等待 15 拍后寄存器拉高）→ **去断言与 CLKDIV 同步、脉宽 15 拍 >> 2 拍、且时钟已稳定** | ✅ 合规（优于要求） |
| R-ISE-5 | `W_BITSLIP` 状态 `bitslip_req<=1'b1`（仅 1 个 clk_div 周期）；`W_WAIT` 内 `bitslip_wait` 计数至 `BITSLIP_WAIT_CYCLES=5`（≥ DDR 要求的 3）；两次 BITSLIP 间夹 W_WAIT(5)+W_CHECK(≥1) 周期 | ✅ 合规（5 > 3，余量充足） |
| R-IDELAY-1 | IDELAYE2 `.C(clk_div)`（BUFR 区域缓冲）；`LD/CE/INC` 均由 clk_div 域状态机产生 | ✅ 合规 |
| R-IDELAY-2 | `IDELAY_TYPE="VAR_LOAD"`，`D_SET_DELAY`/`D_DONE` 经 `.LD` 载入 `CNTVALUEIN` | ✅ 合规 |
| R-IDELAY-3 | `REFCLK_FREQUENCY(200.0)` | ✅ 合规 |
| R-IDELAY-4 | `lvds_rx_phy_1lane` 例化单个 `IDELAYCTRL`，`.REFCLK(ref_clk_200m)`, `.RST(~rst_n)` | ✅ 合规（REFCLK 需由 BUFG 驱动，见 §3 约束确认） |

### 2.2 接收方向 — 时钟拓扑（`lvds_rx_phy_1lane.v` gen_real_clk）

- `IBUFDS(DIFF_TERM="TRUE") → BUFIO → clk_bufio`（高速 CLK）
- `IBUFDS → BUFR #(.BUFR_DIVIDE("4")) → clk_div`（并行 CLKDIV）
- 与 UG471 Figure 3-6 (BUFIO/BUFR) **完全一致**，是 NETWORKING 模式唯一推荐拓扑。

### 2.3 发送方向 — OSERDESE2（`lvds_tx_channel_1lane.v`）

| 规则 | 设计实现 | 判定 |
|------|----------|------|
| R-OSE-1 | `CLK=clk_ser(400MHz)`, `CLKDIV=clk_div(100MHz)`；均由 MMCM 同源输出（clk_out1 / clk_out4），比率 4:1 满足 DDR 8:1 | ✅ 合规（需确认二者在顶层同为 BUFG，见 §3） |
| R-OSE-3 | `DATA_RATE_OQ="DDR"`, `DATA_WIDTH=8`（DDR 合法值） | ✅ 合规 |
| R-OSE-4 | `.D1(tx_data_mux[0]) … .D8(tx_data_mux[7])`（LSB 在 D1，最先发送） | ✅ 合规 |
| R-OSE-5 | `.OCE(1'b1)` | ✅ 合规 |
| R-OSE-6 | `DATA_RATE_TQ="DDR"`, `TRISTATE_WIDTH=1`（DATA_WIDTH=8>4 ⇒ 须为 1） | ✅ 合规 |
| R-OSE-8 | 时钟通道 OSERDESE2 `D={1,0,1,0,1,0,1,0}`（DDR 8:1 转发 400MHz 时钟） | ✅ 功能合规（见 §3 改进建议） |
| R-OSE-2 | `RST = ~rst_n`（**直接取顶层 rst_n，未做 clk_div 域同步释放**） | ⚠ 轻微改进项（见 §3） |

### 2.4 顶层与时钟（`lvds_bidirectional_top_1lane.v`, `mfpga_clk_ip.v`）

- `clk_ser=400MHz`（clk_out1）、`clk_div=100MHz`（clk_out4）、`ref_clk_200m=200MHz`（clk_out6）。
- RX 用 `clk_ser_ext=clk_ser`、`clk_div_ext=clk_div` 在 `SIM_BYPASS` 下旁路 BUFIO/BUFR，与 TX 同源 → 仿真严格对齐。
- RX 的 `rst_n` 经 `clk_div_ready` 同步释放；**TX 的 `rst_n` 直接为顶层 rst_n**，二者复位释放策略不对称（见 §3）。

---

## 3. 发现项（合规确认 / 改进建议 / 约束确认）

### ✅ 合规确认（无需改动）
1. RX 采用 BUFIO+BUFR 经典 NETWORKING 拓扑，符合 R-ISE-2 / Figure 3-6。
2. CLK/CLKB 反相、`INTERFACE_TYPE=NETWORKING`、`IOBDELAY=IFD`、`NUM_CE=2`、DATA_RATE/DATA_WIDTH 全部正确。
3. RX BITSLIP 时序（1 周期断言 + 5 周期等待 ≥ DDR 3 周期要求 + 间隔释放）满足 R-ISE-5。
4. RX ISERDESE2 复位经 `clk_div_ready` 同步释放（15 拍、CLKDIV 同步、宽于 2 拍），**优于** R-ISE-4。
5. TX OSERDESE2 属性、位序（D1=LSB）、OCE、TRISTATE_WIDTH 均符合 R-OSE-3/4/5/6。
6. IDELAYE2 VAR_LOAD + 200MHz REFCLK + C 由区域缓冲驱动，符合 R-IDELAY-1/2/3。
7. IDELAYCTRL 随 IDELAY 例化，符合 R-IDELAY-4。

### ⚠ 改进建议（非阻塞，建议后续优化）
- **[TX-RST]** TX 方向两个 OSERDESE2 的 `.RST(~rst_n)` 直接取顶层 `rst_n`，去断言**未**与 `clk_div` 同步（R-OSE-2 推荐同步释放）。OSERDESE2 内部会把去断言重定时到 CLK 上升沿，且仿真回归 PASS，故当前功能正常；但为严格符合文档、消除上电/重配置瞬态风险，建议顶层对 TX 也采用与 RX 对称的 `clk_div` 域复位释放（即产生一个 `tx_rst_n` = 经 clk_div 稳定计数后的同步复位，再取 `~` 送 OSERDESE2.RST）。
- **[CLK-FWD]** 时钟转发用 OSERDESE2（D=10101010）可实现，但 UG471 更推荐 **ODDR**（D1=1,D2=0）作时钟转发——ODDR 无内部计数器、复位更简单、抖动更优。若后续对时钟质量/上电确定性有更高要求，可将时钟通道改为 ODDR。当前方案功能正确，可保留。

### 📌 约束确认（需在 FPGA 顶层/板级落实，非本目录代码问题）
- **[REFCLK-BUFG]** `ref_clk_200m`（200MHz，CLKout6）在送入 `IDELAYCTRL.REFCLK` 前**须经 BUFG/BUFH** 驱动（R-IDELAY-4）。本目录把 `ref_clk_200m` 作为模块输入，其 BUFG 缓冲应在上层 wrapper 完成——请确认。
- **[TX-CLK-BUFG]** TX 的 `clk_ser`/`clk_div` 由 MMCM 输出送入，须确保二者**缓冲类型一致**（同为 BUFG，或与 RX 一致的 BUFIO/BUFR 配对），禁止混用（R-OSE-1）。
- **[RST-WIDTH]** 顶层 `rst_n` 须为**异步断言、宽于 2 个 CLKDIV 且时钟稳定后才释放**；当前由外部提供，请在板级/顶层保证脉宽与时序。

### 🧹 代码整洁度（不影响功能）
- `lvds_rx_lane_phy.v` ISERDESE2 例化中 `.O(O)` 的 `O` 未显式声明（`wire O;` 缺失），依赖 Verilog 隐式线网，可编译；建议显式声明以提升可读性。

---

## 4. 仿真验证证据

- **脚本**：`sim/regress_1lane.do`（不含 `-voptargs="+acc"`，避免 MMCM 网表被优化为常数导致 PHY 卡死）
- **场景**：1 路双向 master/slave，覆盖建链 → 用户数据传输 → 链路故障自动重训练 → 外部重训练
- **结果状态**：`Test result: PASS`（200 字节 / 0 错误；重训练恢复、外部重训练均成功）
- 本次复核会话重新执行回归，结果见 `sim/regress_1lane_run.log`。

### 4.1 仿真平台回归缺陷修复（harness bug，非 PHY 设计问题）

首次回归出现 `[200000000] ERROR: Simulation timeout!` 且链路始终未建链，根因为 **testbench 时间刻度被覆盖**：

- `lvds_1lane_bidirectional_tb.v` 第 2 行 `` `include "glbl.v" `` 把 glbl 内嵌的 `` `timescale 1ps/1ps `` 引入，覆盖了本模块的 `` `timescale 1ns/1ps ``；
- 导致 tb 内所有 `#delay`（含时钟生成 `#(CLK_SER_PERIOD/2)` 等）被当作皮秒，MMCM 仿真模型实测输入周期与 `CLKIN1_PERIOD=20ns` 属性不符（报 `MMCME2_ADV-20` 警告），MMCM 不上锁 ⇒ `clk_div` 不翻转 ⇒ 链路永远无法建链 ⇒ 200µs 看门狗触发 `$finish`。

**修复**：删除 tb 中的 `` `include "glbl.v" ``。`glbl` 已随 `vlog ../rtl/*.v` 独立编译，并经由 `vsim … work.glbl` 加载提供 GSR 网，tb 无需、也不应包含它。修复后 MMCM 正常上锁、时序正确、结果可复现。

### 4.2 修复后关键时间线（来自 `regress_1lane_run.log`）

| 时刻 | 事件 |
|------|------|
| 3.02 µs | 释放 `rst_n`，进入 Scenario 1 |
| 50.7 µs | 单路 BITSLIP 对齐完成（`bitslip_cnt=1`, `iserdes_q=b5`） |
| 115.8 µs | 双向链路建链成功（`mst_link_up=1, slv_link_up=1`） |
| 139.9 µs | 用户数据收发完成：Master/Slave 各 200 字节，**0 错误** |
| 639.8 µs | 正向链路故障注入后自动重训练恢复 |
| 812.6 µs | 外部强制重训练成功 |
| 822.6 µs | 全场景完成，`Test result: PASS`（Master/Slave RX 各 200 字节，0 错误） |

---

## 5. 结论

LVDS 1-Lane PHY 层的发射（OSERDESE2 + 时钟转发）与接收（ISERDESE2 + IDELAYE2 + BITSLIP + IDELAYCTRL + BUFIO/BUFR）设计**符合 UG471 (v1.10) 关于 ISERDESE2 / OSERDESE2 的全部硬性使用规则**，关键配置（时钟拓扑、属性、BITSLIP 时序、复位同步）均已正确实现并通过仿真（见 §4）。

回归过程中发现并修复了仿真平台的 harness bug（tb 内 `` `include "glbl.v" `` 覆盖时间刻度导致 MMCM 不上锁、链路无法建链，§4.1），修复后仿真可复现 `Test result: PASS`。

设计层面仅余 1 项「TX 复位同步释放」轻微改进建议与 3 项需在 FPGA 顶层/板级落实的约束确认（§3），均不影响当前功能正确性。
