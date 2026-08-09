# LANE_CNT=1 缺陷分析（仅分析，未修改设计）

> 目标：在不修改任何 RTL 的前提下，分析将 `LANE_CNT` 由 3 改为 1 后，LVDS 帧格式与 RTL 设计是否存在缺陷。
> 分析依据：`F:\wc.prj\pulse_mfpga\src\DXH_AI\LVDS3DLane` 下当前源码（V13 基线）。
> 结论：**LANE_CNT=1 不能仅通过改参数实现，当前设计存在多处致命/严重缺陷，链路无法建立、数据无法通过校验。**

---

## 1. 核心结论

| 项 | 结论 |
|---|---|
| 链路能否建立 | ❌ 不能（SOF 检测恒为 0 + deskew_done 卡 0 + 心跳校验和失败） |
| 用户数据能否交付 | ❌ 不能（校验和跨字节越界，帧校验永远失败） |
| 设计文档声明"改 LANE_CNT 即可适配" | ❌ 不成立（对 LANE_CNT=1/2/4 均不成立，仅 LANE_CNT=3 正确） |
| PAYLOAD 计数逻辑本身 | ✅ 可缩放（V13 加法规避下溢 + 逐字 fifo_dout） |

**根因一句话**：帧头/SOF 检测/校验和/心跳字段均按"单字 = 3 字节（3 路并行）"的硬编码 24 位布局实现；LANE_CNT=1 时总线收窄到 8 位，这些硬编码 24 位逻辑会**截断或越界**，导致帧封装与解析彻底失效。

---

## 2. 帧格式在 LANE_CNT=1 下的本质变化

设计文档定义帧为 `[SOF1|SOF2|TYPE][LEN|0|0][PAYLOAD][CHECKSUM|0|0]`，并声明"**TX 保证 3 字节对齐，SOF1 固定在 byte0**"（见 `lvds_rx_link.v:5-6,39-43`）。

- **LANE_CNT=3**：一个"字"=`LANE_CNT×8=24bit`=3 字节并行 → SOF 头在**一个字**内同时送到 3 路，SOF 检测是**单字并行比较**。
- **LANE_CNT=1**：一个"字"=`8bit`=1 字节串行 → 帧应变为**字节串行流** `AA 55 TYPE LEN 0 0 P0 P1 … CK 0 0`，SOF 头需**3 个连续字**分别发送，SOF 检测必须是**移位序列匹配**。

当前 RTL 的帧封装是"单字并行"模型，并未做串行化重构，因此 LANE_CNT=1 下直接崩溃。

---

## 3. 缺陷清单（按模块，含 file:line）

### 🔴 D-1【致命】TX 帧头组装截断 —— SOF2 与 TYPE 丢失
**文件**：`lvds_tx_channel.v:289-291`
```verilog
TX_SOF_TYPE: begin
    tx_data_mux = {tx_type_sel, FRAME_SOF2, FRAME_SOF1};  // 硬编码 24bit：{TYPE,0x55,0xAA}
    ...
end
```
`tx_data_mux` 宽度为 `LANE_CNT*DATA_WIDTH`：
- LANE_CNT=3 → 24bit，正确得到 `{TYPE,SOF2,SOF1}`。
- **LANE_CNT=1 → 8bit**，Verilog 将 24bit 赋给 8bit 信号**截断为低 8 位 = `FRAME_SOF1(0xAA)`**。`SOF2(0x55)` 与 `TYPE` 被直接丢弃。

> 注：该拼接对 LANE_CNT=2 也会丢 TYPE，对 LANE_CNT=4 会多塞一个垃圾字节——**仅 LANE_CNT=3 正确**。

### 🔴 D-2【致命】RX 帧头检测恒假 —— 状态机永远停在 F_IDLE
**文件**：`lvds_rx_link.v:66`
```verilog
wire sof_detected = (rx_data_in[7:0] == SOF_BYTE1 && rx_data_in[15:8] == SOF_BYTE2);
```
- LANE_CNT=1 → `rx_data_in` 仅 8bit，`rx_data_in[15:8]` **越界** → 仿真求值为 `X`、综合为 0 → `sof_detected` 恒为假。
- 后果：`F_IDLE` 无法跳 `F_LEN`，**帧解析状态机永远不启动**，链路不可能建立。

**同文件 `lvds_rx_link.v:146`**：
```verilog
frame_type <= rx_data_in[23:16];   // 越界 → TYPE 为 X/0
```
即便 SOF 被修复，TYPE 也取不到（应是 `rx_data_in[7:0]` 在 F_IDLE 周期即 SOF_TYPE 字的第 1 字节——但当前把 SOF1/SOF2/TYPE 叠在一个字里，串行化后三者分属不同字，逻辑完全错位）。

### 🔴 D-3【致命】校验和跨字节越界 —— 心跳/用户帧校验永远失败
**TX 侧** `lvds_tx_channel.v:265`：
```verilog
checksum_reg <= checksum_reg + fifo_dout[7:0] + fifo_dout[15:8] + fifo_dout[23:16];
```
**RX 侧** `lvds_rx_link.v:161`：
```verilog
checksum_calc <= checksum_calc + rx_data_in[7:0] + rx_data_in[15:8] + rx_data_in[23:16];
```
- LANE_CNT=1 → `fifo_dout`/`rx_data_in` 仅 8bit，`[15:8]`/`[23:16]` **越界** → 累加未定义字节。
- 后果：
  - 心跳帧（`TYPE_HB`）在 `F_CHECKSUM` 校验通过时才会置 `link_up`（`lvds_rx_link.v:185-189`）→ 校验恒失败 → **`link_up` 永不置位 → 链路建立失败**。
  - 用户帧校验恒失败 → `frame_err_cnt` 累加 → 达 `MAX_ERR_CNT` 触发 `retrain_req` → 反复重训练。
  - 仿真中越界位为 `X`，TX/RX 不可能巧合一致通过。

> 注：该累加同样**仅对 LANE_CNT=3 正确**（正好 3 个字节）；LANE_CNT=2 时 `[23:16]` 越界，LANE_CNT=4 时漏加第 4 字节 `[31:24]`。

### 🔴 D-4【严重】lane_deskew 的 LANE_CNT==1 旁路路径越界
**文件**：`lane_deskew.v:133-137`
```verilog
if(&offset_found || LANE_CNT == 1) begin
    if(shift_reg[1][lane_offset[1]] == sync_word &&
       shift_reg[2][lane_offset[2]] == sync_word) begin   // ← 越界
        check_cnt <= check_cnt + 1'b1;
    end
    ...
end
```
- `shift_reg` 声明为 `[LANE_CNT-1:0][...]` → LANE_CNT=1 时仅 `[0:0]`。
- 进入 `LANE_CNT==1` 分支后，`shift_reg[1]`/`shift_reg[2]` **越界** → 比较为假 → `check_cnt` 永不累加 → **`deskew_done` 永远不置 1**。
- 后果：`deskew_output_proc`（`:161`）在 `deskew_done=0` 时输出全零 → 下游 `lvds_rx_link` 永远收到 `0x00`，SOF 检测（需 `0xAA`）必然失败，且 RX 物理层可能因此不拉 `phy_ready`。

### 🔴 D-5【严重】lvds_rx_phy 数据拼接硬编码 3 路
**文件**：`lvds_rx_phy.v:197`
```verilog
.data_in({lane_data[2], lane_data[1], lane_data[0]}),   // 硬编码 3 路拼接
```
- LANE_CNT=1 → `lane_data` 仅 `[0:0]`，`lane_data[2]`/`lane_data[1]` **越界** → 送入 `lane_deskew` 的 `data_in` 为 X/0。
- 即便 D-4 的越界引用被修复，`data_in` 本身已错。应改为按 `LANE_CNT` 的 generate 拼接或 `{LANE_CNT{lane_data[...]}}` 形式。

### 🟠 D-6【严重】心跳 16 位值未能拆分到多字
**TX 侧** `lvds_tx_channel.v:300`：
```verilog
TYPE_HB: tx_data_mux = {8'd0, heartbeat_cnt[7:0], heartbeat_cnt[15:8]};  // 24bit
```
- LANE_CNT=1 → 截断为 8bit = `heartbeat_cnt[15:8]`（高字节），**低字节 `heartbeat_cnt[7:0]` 丢失**。
- **RX 侧** `lvds_rx_link.v:170-171` 从 `rx_data_in[7:0]`/`[15:8]` 重组 → 低字节取自越界的 `[15:8]`（X/0）。
- 后果：心跳计数值重建错误，且仍叠加 D-3 校验越界。

### 🟡 D-7【次要/调试】debug 打印宽度不匹配
**文件**：`lvds_rx_link.v:138`
```verilog
if(rx_data_in != 24'hB5B5B5 && rx_data_in != 24'h555555 && rx_data_in != 24'h000000)
```
- LANE_CNT=1 → 8bit 信号与 24bit 字面量比较（截断），仅影响 `$display` 调试输出，**不影响功能**。

---

## 4. 哪些部分其实能正常缩放（避免误报）

确认以下逻辑在 LANE_CNT=1 下**无缺陷**，无需改动：

1. **PAYLOAD 计数逻辑**（`lvds_tx_channel.v:213,262,266` / `lvds_rx_link.v:89,160`）：
   - 退出条件为加法 `payload_cnt + LANE_CNT >= payload_len`，不依赖减法下溢（V13 修复）；
   - `payload_len <= fifo_occ_cnt[7:0] * LANE_CNT` 在 LANE_CNT=1 时为 `fifo_occ_cnt`（字节数）；
   - `payload_cnt` 按 `LANE_CNT` 步进，LANE_CNT=1 即逐字节。
2. **TX_PAYLOAD 用户数据发送**（`lvds_tx_channel.v:299` `tx_data_mux = fifo_dout`）：LANE_CNT=1 时 `fifo_dout` 为 8bit，直接赋值无截断问题，**数据内容本身发送正确**（只是 D-3 校验算错）。
3. **RX 用户数据输出**（`lvds_rx_link.v:164` `rx_data_out <= rx_data_in`）：8bit↔8bit，正确。
4. **控制帧出口**（payload_len=1）：`payload_cnt+LANE_CNT>=payload_len` → `0+1>=1` 成立，TX_PAYLOAD 单周期发送 `ctrl_frame_payload` 并经截断保留低 8 位，逻辑自洽。
5. **总线/端口宽度**：各模块 `LANE_CNT*DATA_WIDTH`、`[LANE_CNT-1:0]` 端口及 `gen_data_lane`/`gen_rx_lanes` generate 循环均随参数正确收窄，无宽度声明错误。

> 即：问题**集中在"帧头/SOF/校验和/心跳"的 24 位硬编码**，而非总线参数化本身。

---

## 5. 修复方向建议（仅建议，本次未改代码）

要使 LANE_CNT=1 真正可用，需重构帧封装层，使其与 `LANE_CNT` 解耦：

1. **帧头序列化**：将 `TX_SOF_TYPE` 拆为 `SOF1 → SOF2 → TYPE` 多个连续字（或引入 `HEADER_BYTES` 常量 + 状态机逐字节发），适配任意 `LANE_CNT`。
2. **SOF 检测改为移位序列匹配**：用 `HEADER_BYTES` 长的移位寄存器做 `AA,55,TYPE…` 序列检测，替换 `lvds_rx_link.v:66` 的单字并行比较，避免用户数据中的 `0xAA` 误触发帧头。
3. **校验和按实际字节数累加**：用 `genvar`/`for` 循环对 `LANE_CNT` 个字节求和，替换 `lvds_tx_channel.v:265` 与 `lvds_rx_link.v:161` 的定宽 `[15:8]/[23:16]`。
4. **多字节字段按 LANE_CNT 拆分**：心跳等 16 位字段拆分为 `ceil(16/8)=2` 个字发送/接收（`lvds_tx_channel.v:300`、`lvds_rx_link.v:170-171`）。
5. **修复硬编码 3 路引用**：
   - `lane_deskew.v:135-136` 的 `shift_reg[1]/[2]` 越界引用，改为"仅当 `LANE_CNT>1` 才检查其余路"（generate-if / `if(LANE_CNT>1)`）；
   - `lvds_rx_phy.v:197` 的 `{lane_data[2],lane_data[1],lane_data[0]}` 改为 generate 拼接或 `lane_data[0]`。
6. **统一所有定宽位选**：`rx_data_in[15:8]`/`[23:16]`、`fifo_dout[15:8]`/`[23:16]`、`24'hB5B5B5` 字面量等，全部按 `LANE_CNT` 泛化。

---

## 6. 对设计文档声明的更正

设计文档 `Xilinx 7系列FPGA双向3路数据LVDS通信设计文档_V1.0/V2.0/V3.0` 中均声明：

> "通过修改 `LANE_CNT` 参数可快速适配 2 路、4 路等不同通道数需求，链路层与管理层逻辑无需改动。"

**本分析证明该声明不成立**：
- LANE_CNT=**1**：D-1~D-5 全部触发，链路无法建立、数据校验失败。
- LANE_CNT=**2/4**：D-1（header 拼接丢 TYPE）、D-3（校验和仅对 3 字节正确）同样触发。
- 当前实现**仅在 LANE_CNT=3 时功能正确**。若要支持可变通道数，必须按照第 5 节重构帧封装层。

---

*分析基于 V13 基线源码，未作任何设计修改。所有 file:line 均指向当前 `LVDS3DLane` 目录内文件。*
