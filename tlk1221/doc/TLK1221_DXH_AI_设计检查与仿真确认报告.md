# TLK1221 (DXH_AI) 设计检查、仿真与确认报告

> 对象：`F:\wc.prj\pulse_mfpga\src\DXH_AI\tlk1221`
> 平台：Xilinx Zynq-7020 + 外部 TLK1221 千兆 PHY（TBI 10-bit 并行接口）
> 基线：TLK1221 芯片手册 SLLS713C（Feb 2007 – Rev Sep 2009）
> 仿真：ModelSim SE-64 10.6d（本地，无网络依赖），行为级 `sim_lib` 替代 Xilinx 原语
> 日期：2026-08-10

---

## 0. 摘要（Executive Summary）

对 `DXH_AI/tlk1221` 五个 RTL 模块做了静态 review，并基于芯片手册建立了检查基线；随后用 ModelSim 跑通了独立 8B10B 验证台（`tb_8b10b_codec`）与全顶层验证台（`tb_tlk1221_full`），得到仿真实测结论。

**总体结论：该设计当前不可直接用于实际千兆链路，必须经过实质性修复并重新验证。** 关键风险按严重度排列：

| 严重度 | 编号 | 缺陷 |
|--------|------|------|
| 严重(S) | LINK-1 | `IDLE_WORD = 10'h0BC` 不是标准 K28.5 comma → TLK1221 永不建立 SYNC，链路死锁 |
| 严重(S) | 8B10B-2 | 编码器/解码器码表不一致且多处错误 → 多字节数据损坏（仿真实测 `0x12→0x0f`、`0x16→0x00`、`0x1e→0x02`） |
| 高(H) | 8B10B-1 | 编码器 K28.5 在 RD+ 状态输出 `0x305` 而非标准 `0x30A` |
| 高(H) | 8B10B-3 | 解码器对 K28.x 消歧忽略 RD 极性 → K28.5/K28.2 被错误解码为 K28.0 |
| 中(M) | CDC-1 | `PL_SFP_SYNC` 在 phy_tx 时钟域 FSM 中直接采样，未经该域同步器（跨时钟域亚稳风险） |
| 低/中(L) | CDC-2 | `clk_phy_rx` 经 `assign` 直驱，IBUFGDS 被注释，恢复时钟未走全局缓冲 |
| 中(M) | TIM-1 | 缺 XDC 时序约束（TD tSU/tH、RD tSU/tH），真实时序签收未完成 |

**已确认通过的部分**：CDC 架构（双时钟异步 FIFO + 3-FF SYNC 同步器）功能正确，链路同步信号 `link_sync` 能在异步 SYNC 抖动后稳定建立；RX 接收时序架构与手册的正常速率 TBI 模式一致；无效码（`code_err`）与偏差错误（`disp_err`）检测逻辑正确。

> ⚠️ **重要更正**：早期 review 曾认为“8B10B 编解码标准正确，仅 K28.5 一处 bug”。**仿真证明这是错误的**——码表存在多处结构性错误导致真实数据损坏，K28.5 只是其中之一。

---

## 1. 设计概览

模块组成（位于 `.../DXH_AI/tlk1221/rtl/`）：

| 文件 | 作用 |
|------|------|
| `tlk1221_axis_top.v` | 顶层，三时钟域互联、复位释放、例化 FIFO |
| `tlk1221_axis_user.v` | AXI4-Stream 用户层 + 8B10B 编解码例化 |
| `tlk1221_phy_if.v` | 与 TLK1221 的 10-bit 并行接口（TX/RX 三段式 FSM） |
| `encode_8b10b.v` | 8B10B 编码器（组合码表 + RD 状态机） |
| `decode_8b10b.v` | 8B10B 解码器（反查表 + RD 状态机） |

**时钟域（3 个）**：
- `clk_user` = 125 MHz（AXI 用户侧）
- `clk_phy_tx` = `IBUFG(PL_SFP_CLK)`（FPGA 提供参考时钟给 PHY）
- `clk_phy_rx` = `assign clk_phy_rx = PL_SFP_RBC0`（PHY 恢复时钟）

**数据流**：
```
AXI-TX ──> [8b10b encode] ──> TX FIFO ──> phy_if(TD0-9@REFCLK) ──> TLK1221 ──> 串行线路
串行线路 ──> TLK1221 ──> (RD0-9@RBC0) ──> phy_if RX FIFO ──> [8b10b decode] ──> AXI-RX
```
空闲时 `phy_if` 发送 `IDLE_WORD` 作为训练字符；`PL_SFP_SYNC`（来自芯片 SYNC 输出）用于门控收发 FSM。

---

## 2. 芯片手册基线（TLK1221 SLLS713C）

从手册 PDF 提取的关键规范（`doc/tlk1221_extracted.txt`）：

- **速率**：0.6–1.3 Gbps；REFCLK 60–130 MHz，Serializer ×10 → 125 MHz 对应 1.25 Gbps。REFCLK 占空比 40–60%，抖动 40 ps，精度 ±100 ppm。
- **发送锁存**：TD0–TD9 在 **REFCLK 上升沿**锁存（表 2 / 第 191–194 行）。建立/保持：`tsu(d4)=1.6 ns`，`th(d4)=0.8 ns`。
- **接收有效**：RD0–RD9 在 **RBC0/RBC1 上升沿**有效。
  - 正常速率模式（RBCMODE=高）：仅 RBC0 有效，=1/10 串行速率（125 MHz），数据相对 RBC0 上升沿 **`tsu(d1)=2.5 ns`、`th(d1)=2 ns`**。
  - 半速率模式（RBCMODE=低）：RBC0/RBC1 180° 反相，byte0/2 在 RBC1 上升沿有效。
- **SYNC 引脚（pin 30，输出 O）**：当检测到 K28.5 comma 时拉高，并与 K28.5 对齐；仅当 `SYNCEN=1` 时使能 comma 检测。注意：**SYNC 是芯片输出**，对 FPGA 而言为输入。
- **K28.5 comma 模式**：`0011 1110 10`（负 disparity 起始），7 MSB = `0011111`。SYNC 脉冲与 K28.5 字符对齐（第 244–289 行）。
- **延迟**：发送 20–22 UI，接收 18–24 UI；relock 256 ns @1.25 Gbps（0.75 UI 抖动）/ 128 ns @0.20 UI。
- **PRBS / Loopback / ENABLE**：内置 BIST，LOOPEN 内部环回，ENABLE 低电平关断。

> 设计采用**正常速率 TBI 模式**（10-bit 并行字，RBC0=125 MHz），与手册一致；恢复时钟走 RBC0 上升沿采样，架构方向正确。

---

## 3. 跨时钟域（CDC）检查

### 3.1 架构（正确）
- TX 方向：`clk_user → clk_phy_tx` 经 `xpm_fifo_async`（FIFO_DEPTH=512，10-bit）。
- RX 方向：`clk_phy_rx → clk_user` 经 `xpm_fifo_async`。
- `PL_SFP_SYNC → clk_user` 经 **3-FF 同步器**产生 `link_sync`（顶层第 141–148 行）。

**仿真验证（tb_tlk1221_full，TEST CDC）**：
```
==== CDC: link_sync after SYNC settle = 1 (expect 1) ====
```
在 SYNC 上施加异步抖动（13/7/19 ns 毛刺）后，`link_sync` 仍能稳定建立为 1 → 3-FF 同步器有效。

### 3.2 缺陷 CDC-1（中/高）
`tlk1221_phy_if.v` 的 TX/RX 三段式 FSM **直接采样 `tlk_rx_sync`（=PL_SFP_SYNC）**（第 50、54、105、109 行），而 `tlk_rx_sync` 来自 `clk_phy_rx`（RBC0）域。`phy_tx` FSM 工作在 `clk_phy_tx`（REFCLK）域——这是**跨时钟域直接采样，缺少该路径的同步器**。3-FF 同步器仅覆盖了 `clk_user` 路径（`link_sync`），未覆盖 `clk_phy_tx` FSM。
**影响**：`PL_SFP_SYNC` 在 phy_tx 域可能出现亚稳，导致收发状态机进入不确定状态。
**修复**：进入 `clk_phy_tx` FSM 前，对 `tlk_rx_sync` 单独做 2–3 级同步器（或统一用 `clk_user` 域的 `link_sync` 驱动 phy 侧 FSM，避免跨域）。

### 3.3 缺陷 CDC-2（低/中）
`tlk1221_axis_top.v` 第 114–121 行：`clk_phy_rx` 由 `assign clk_phy_rx = PL_SFP_RBC0;` 直接驱动，原 `IBUFGDS` 例化被注释。恢复时钟是高速时钟，应经全局缓冲（BUFG/IBUFG）以降低 skew 与抖动；直驱会增加时序不确定性。
**修复**：恢复时钟经 `BUFG` 或保留 `IBUFGDS`（差分）后作为 `clk_phy_rx`。

---

## 4. 8B10B 编解码检查（含仿真）

RD 状态机**机制**本身正确：`disp_flip = disp_6b_flip ^ disp_4b_flip`，下一 RD = 当前 RD 取反当 `disp_flip` 为 1（`encode_8b10b.v` 第 33、44–50 行）。问题出在**码表内容**与**编解码一致性**。

### 4.1 缺陷 8B10B-1（高）— 编码器 K28.5 RD+ 变体错误
`encode_8b10b.v` 第 103 行：
```verilog
5'd5: code_4b = 4'b0101;   // K28.5，硬编码，无 RD 依赖，disp_4b_flip 未置位
```
K28.5 在 RD+ 状态应为 `110000_1010 = 0x30A`，但此处 `code_4b` 恒为 `0101`、且 `disp_4b_flip=0`，导致 RD+ 输出 `0x305`。
**仿真（TEST A）**：
```
OK   vec din=0xbc kin=1 -> 0x0f5      // RD- 正确
FAIL K28.5#2 RD-toggle got=0x305 (expected 0x30A)   // RD+ 错误
```

### 4.2 缺陷 8B10B-2（严重）— 码表不一致导致真实数据损坏
通过仿真回环失败（`tb_8b10b_codec` TEST B）与 RTL 码表比对，确认编码器与解码器的 **6-bit 码映射多处矛盾，且编码器自身非单射**：

| 数据字节 | 编码器 6b 码 | 解码器映射 | 结果 |
|----------|--------------|------------|------|
| D15 (`0x0f`) | `011100`（RD-） | `011100→D15` | 自洽 |
| D18 (`0x12`) | `011100`（无 RD flip） | `011100→D15` | **碰撞：D18 解码为 D15** |
| D2 (`0x02`) | `011110` | `011110→D2` | 自洽 |
| D30 (`0x1e`) | `011110`（flip） | `011110→D2` | **碰撞：D30 解码为 D2** |
| D22 (`0x16`) | `011000` | `011000→D0` | **碰撞：D22 解码为 D0** |
| D28 (`0x1c`, 数据) | `001111` | `001111→K28.x` | 数据被误判为 K 字符 |

根本原因：编码器 `data_5b` 分支将**不同的 x 值映射到相同的 6b 码**（D15/D18 同 `011100`、D2/D30 同 `011110`），而解码器只认其中一个，于是另一字节被错误解码。6-bit 码本应仅由 5-bit 数据值 x 决定，不同 x 必须不同码——当前实现违反该约束。

**仿真（TEST B）实测**：
```
RT-FAIL din=0x12 got=0x0f k=0 cerr=0
RT-FAIL din=0x16 got=0x00 k=0 cerr=0
RT-FAIL din=0x1e got=0x02 k=0 cerr=0
running-disparity violations on encoder stream: 116
8B10B CODEC SUMMARY: pass=177  fail=98  rd_violations=116
RESULT: 8B10B TEST FAIL
```
> 说明：116 个 running-disparity 违例中，部分可能源于 RD 符号约定差异（TB 独立检查器用标准“RD=-1 时 pop∈{5,6}”规则），但**回环失败是确凿的真实 bug**，与 RD 符号无关，证明码表结构性错误。

### 4.3 缺陷 8B10B-3（高）— 解码器 K28.x 消歧忽略 RD 极性
`decode_8b10b.v` 第 111–121 行：`code_4b=4'b0101` 被第 112 行 `4'b1010, 4'b0101 → data_3b=0`（K28.0）**先匹配捕获**，第 117 行 `4'b0101 → data_3b=5`（K28.5）成为不可达死代码。
K28.0 与 K28.5 仅由 RD 极性区分（标准：K28.5 负 disparity = `001111 0101`=`0x0F5`；K28.0 正 disparity = `110000 0101`=`0x305`），但该解码器**未用 RD 状态消歧**，于是 `0x0F5` 被错误解码为 K28.0。
**仿真（TEST C）**：
```
K-FAIL k=0x5c got=0x1c kout=1 cerr=0   // K28.2 也落入 0101 分支 -> K28.0
K-FAIL k=0xbc got=0x1c kout=1 cerr=0   // K28.5 (0x0F5) -> K28.0 (0x1C)
```
（K28.0/K28.1/K28.3/K28.4/K28.6/K28.7 及 K23.7/K27.7/K29.7/K30.7 回环正确。）

### 4.4 修复建议（8B10B）
**不要手工修补个别码字**——码表错误呈系统性（多字节碰撞）。应整体替换为**已验证的 8B10B 码表**（如 Xilinx 官方 `encode_8b10b`/`decode_8b10b` IP 的算法、或经充分验证的开源表），并满足：
- 编码器单射：每个 (din,kin) 唯一对应一个 10-bit 码字；每个 10-bit 码字唯一对应一个 (din,kin)。
- 解码器对 K28.0/K28.5 等 RD-依赖字符用 `curr_rd_state` 消歧。
- RD 状态机与码表 flip 标志严格匹配标准 8B10B（pop=4/5/6 的 RD 规则）。

---

## 5. 接收时序检查

- **架构一致性**：设计采用正常速率 TBI（RBC0=125 MHz），RD 在 RBC0 上升沿被 `phy_if` 采样，与手册第 224–237 行“正常模式数据相对 RBC0 上升沿有效”一致。
- **仿真（tb_tlk1221_full）**：TLK1221 模型将 RD 居中于恢复时钟周期（源同步建模），DUT 在 RBC0 上升沿采样，功能上无时序违例；RX 异步 FIFO 在 125/125.25 MHz 频偏下数据完整、无丢失/重复。
- **缺陷 TIM-1（中）**：尚无 XDC 约束。需补充：
  - 输出：`TD0-9` 相对 `REFCLK` 建立 ≥1.6 ns、保持 ≥0.8 ns（set_output_delay）。
  - 输入：`RD0-9` 相对 `RBC0` 建立 ≥2.5 ns、保持 ≥2 ns（set_input_delay，含时钟偏斜）。
  - `REFCLK`、`RBC0` 用 `create_clock` 定义；异步时钟组（clk_user / clk_phy_tx / clk_phy_rx）设 `set_clock_groups -asynchronous`。

---

## 6. 链路同步 / IDLE_WORD 缺陷（严重）

**缺陷 LINK-1（严重）** — `tlk1221_phy_if.v` 第 28 行：
```verilog
localparam IDLE_WORD = 10'h0BC; // 注释称"空闲默认发送 K28.5 同步字符"
```
`0x0BC`（`001011_1100`）**不是标准 K28.5 comma**（标准 RD−=`0x0F5`/`0x1BC`、RD+=`0x30A`）。后果链条：
1. 解码器收到 `0x0BC` → 6b=`001011` 不在合法表 → `code_valid=0` → `code_err=1`。
2. TLK1221 收到非 comma 的 `0x0BC`，**永不触发 comma 检测 → SYNC 输出永不拉高**。
3. 设计依赖 `PL_SFP_SYNC` 门控收发（phy_if FSM：SYNC 高才进入 RUN）——SYNC 不起则 FSM 卡在 IDLE，**真实链路死锁**。
**仿真（tb_tlk1221_full）实测**：
```
tx_cnt=600 rx_data=5773 rx_idle=184 mismatch=0 code/disp_err=1
RESULT: FULL-TOP TEST FAIL (... err=1)
```
`code/disp_err=1` 即由 `0x0BC` 空闲字触发，确认该缺陷在系统级的真实表现。

> 注：上行的 `mismatch=0` **不是** 8B10B 正确的证据——该测试台的 RX 比较仅在 `rx_idx < tx_cnt` 时执行，而实际产生 5773 个 RX 数据（远超 600），绝大多数未被比较，掩盖了 §4.2 的损坏。**8B10B 正确性以 `tb_8b10b_codec`（TEST B）为准。**

**修复**：`IDLE_WORD` 改为标准 K28.5 comma，例如 RD− 变体 `10'h0F5`（或 `10'h1BC`/`10'h30A`，需与 `SYNCEN` 使能及 RD 状态一致）；并确认 `SYNCEN` 在板上被拉高以启用 comma 检测。

---

## 7. 仿真方法与结果

**环境**：ModelSim SE-64 10.6d（本地）。因无 Vivado/XSIM，用 `sim/sim_lib.v` 行为级替代 `IBUFG`/`IBUFGDS`/`xpm_fifo_async`（带 gray-code 指针的异步 FIFO）。编译脚本 `sim/run_sim_dxh.do`（用 `mywork` 库绕过损坏的 `modelsim.ini` 的 `work` 映射，RTL 路径指向 `../src/DXH_AI/tlk1221/rtl/`）。

**测试台**：
- `tb_8b10b_codec.v`：独立 8B10B 验证——A 已知码字向量（含 K28.5 RD 翻转）、B 256 数据回环 + 独立 RD 合规检查、C 有效 K 字符回环、D 无效码检测、E 偏差错误检测。
- `tb_tlk1221_full.v`：全顶层——CDC（双时钟 FIFO + 8.0/8.02 ns 频偏）、8B10B 闭环、接收时序（源同步 RD 居中）。

**修正记录**：`tb_8b10b_codec.v` 的 `enc1`/`dec1` 原在 `@(posedge clk)` **之后**才驱动输入，导致 DUT 采样到上一拍数据（NBA 流水线时序陷阱，表现为全部 K 向量假失败 `0x27a`）。已修正为**在 posedge 之前**驱动输入。修正后结果可信。

**结果汇总**：

| 测试 | 关键结论 |
|------|----------|
| TEST A（已知码字） | K28.5 RD−=`0x0F5`✓、K28.0=`0x0FA`✓、D0.0=`0x27A`✓；**K28.5 RD+ 错误 `0x305`**（应 `0x30A`） |
| TEST B（256 数据） | **回环失败 `0x12→0x0f`、`0x16→0x00`、`0x1e→0x02`**；116 起 RD 违例；`pass=177 fail=98` |
| TEST C（K 字符） | K28.2/K28.5 误解码为 K28.0；其余 K 字符及 K23.7 等回环正确 |
| TEST D/E（无效码/disp_err） | 通过 |
| CDC（全顶层） | `link_sync` 异步抖动后稳定=1；FIFO 跨频偏无丢失 |
| 全顶层回环 | `code/disp_err=1`（`0x0BC` 触发）→ 链路同步缺陷确认 |

---

## 8. 缺陷清单与修复优先级

| 编号 | 位置 | 描述 | 严重度 | 修复建议 |
|------|------|------|--------|----------|
| LINK-1 | `tlk1221_phy_if.v:28` | `IDLE_WORD=0x0BC` 非标准 comma，链路 SYNC 永不建立 | 严重 | 改为 `10'h0F5`（K28.5 负 disparity），确认 `SYNCEN` 拉高 |
| 8B10B-2 | `encode_8b10b.v` / `decode_8b10b.v` | 码表不一致、非单射 → 多字节数据损坏 | 严重 | 整体替换为已验证 8B10B 码表；保证编解码互逆 |
| 8B10B-1 | `encode_8b10b.v:103` | K28.5 RD+ 硬编码 `0101` → `0x305`（应 `0x30A`） | 高 | 按 RD 选择 `0101`/`1010` 并置 `disp_4b_flip` |
| 8B10B-3 | `decode_8b10b.v:112,117` | K28.x 消歧忽略 RD 极性 → K28.5/K28.2→K28.0 | 高 | 用 `curr_rd_state` 区分 K28.0/K28.5；删除不可达死代码 |
| CDC-1 | `tlk1221_phy_if.v:50,54,105,109` | `tlk_rx_sync` 跨域直接采样（phy_tx FSM） | 中/高 | 进 phy_tx FSM 前加 2–3 级同步，或统一用 `link_sync` |
| CDC-2 | `tlk1221_axis_top.v:114-121` | 恢复时钟直驱，IBUFGDS 注释 | 低/中 | 恢复时钟经 `BUFG`/`IBUFGDS` |
| TIM-1 | 缺 XDC | 无 TD/RD 输入/输出延迟约束、异步时钟组 | 中 | 补 `create_clock` + `set_input/output_delay` + `set_clock_groups` |

---

## 9. 确认结论

**确认通过（Confirmed）**：
- CDC 架构（双时钟异步 FIFO）正确，能在 125/125.25 MHz 频偏下无丢失传输（全顶层实测）。
- 3-FF SYNC 同步器有效，`link_sync` 在异步 SYNC 抖动后稳定建立。
- RX 接收时序架构与手册正常速率 TBI 模式一致（RD 于 RBC0 上升沿采样，源同步居中）。
- 无效码（`code_err`）与偏差错误（`disp_err`）检测逻辑正确（TEST D/E）。

**确认未通过（Not Confirmed / Failed）**：
- 8B10B **数据正确性**失败：多字节因码表错误被错误编解码，链路会静默损坏数据（TEST B 实测，严重）。
- K28.5 编解码错误（8B10B-1/8B10B-3）：comma 训练字本身有缺陷。
- **链路同步**失败：`IDLE_WORD` 非标准 comma，真实 TLK1221 不会建立 SYNC，设计将死锁（LINK-1）。

**交付物**：
- 本报告（设计检查 + 手册比对 + 仿真确认）。
- 仿真测试台（`sim/tb_8b10b_codec.v`、`sim/tb_tlk1221_full.v`、`sim/sim_lib.v`、`sim/run_sim_dxh.do`）。
- 仿真日志（`sim/codec_dxh.log`、`sim/full_dxh.log`）。
- 芯片手册文本（`doc/tlk1221_extracted.txt`）。

**后续建议**：优先修复 LINK-1（改 `IDLE_WORD`）与 8B10B-2（替换码表），随后补齐 CDC-1 同步器与 TIM-1 约束，最后用同一测试台回归并重验通过后再上板。
