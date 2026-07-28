# LVDS3DLane 设计 Review 报告（V2 — 独立深度审查）

**项目**：Xilinx 7系列FPGA双向3路数据LVDS通信设计  
**Review日期**：2026-07-28  
**Review范围**：`LVDS3DLane/` 目录下全部9个Verilog源文件 + 1个Testbench  
**审查方法**：逐文件逐行人工审查 + 跨模块时序/数据流追踪  
**对照基线**：已有 `DESIGN_REVIEW_REPORT.md`（V1，2026-07-27，含12项问题及"已修复"声明）

---

## 0. 审查结论摘要

本次独立审查**确认**了V1报告中12项问题的存在性，但发现：

1. **V1声称"已修复"的12项中，至少5项修复不完整或引入了新缺陷**（见§3）。
2. **新发现15项V1报告完全遗漏的问题**，其中包含4项致命、6项严重（见§4）。
3. **Testbench存在3项缺陷**，导致即使RTL正确也无法有效验证（见§5）。

**问题统计（V2总表）**

| 严重程度 | V1已列（含残留） | V2新发现 | 合计 |
|----------|------------------|----------|------|
| 🔴 致命  | 4（3项残留缺陷） | 4        | 8    |
| 🟠 严重  | 4（2项残留缺陷） | 6        | 10   |
| 🟡 一般  | 4（0项残留）     | 5        | 9    |
| **合计** | **12**           | **15**   | **27** |

> 本报告聚焦V1遗漏与残留问题。V1已正确修复的问题不再重复展开。

---

## 1. 文件清单与模块职责

| # | 文件 | 模块 | 职责 | 行数 |
|---|------|------|------|------|
| 1 | `lvds_bidirectional_top.v` | `lvds_bidirectional_top` | 顶层集成、CDC同步 | ~160 |
| 2 | `lvds_tx_channel.v` | `lvds_tx_channel` | 发送通道：FIFO+帧调度+OSERDESE2 | ~350 |
| 3 | `lvds_rx_lane_phy.v` | `lvds_rx_lane_phy` | 单路RX物理层：IDELAY+ISERDES+字对齐 | ~320 |
| 4 | `lvds_rx_phy.v` | `lvds_rx_phy` | 3路RX物理层顶层+全局状态机 | ~190 |
| 5 | `lane_deskew.v` | `lane_deskew` | 通道间相位对齐（移位寄存器法） | ~80 |
| 6 | `lvds_rx_link.v` | `lvds_rx_link` | 接收链路层：帧解析+校验+心跳 | ~175 |
| 7 | `lvds_rx_channel.v` | `lvds_rx_channel` | RX通道封装 | ~115 |
| 8 | `lvds_link_manager.v` | `lvds_link_manager` | 链路管理状态机（主从握手） | ~225 |
| 9 | `lvds_3lane_bidirectional_tb.v` | tb | 双DUT互连测试平台 | ~330 |

---

## 2. 数据通路与时钟域全景

```
                    clk_ref域                    clk_div域(TX)              clk_ser域
                 ┌──────────────┐              ┌─────────────────┐      ┌────────────┐
                 │ link_manager │──CDC同步──▶  │  tx_channel     │────▶│ OSERDESE2  │──LVDS──▶
                 │  (主从FSM)   │              │ (FIFO+帧调度)   │      └────────────┘
                 └──────┬───────┘              └─────────────────┘
                        │ CDC                        ▲
                        │ (clk_div→clk_ref)          │ clk_div(RX,来自BUFR)
                        ▼                            │
                 ┌──────────────┐              ┌─────┴───────────┐      ┌────────────┐
                 │              │◀──状态反馈── │  rx_channel     │◀────│ ISERDESE2  │◀──LVDS──◀
                 │              │              │ (phy+link)      │      └────────────┘
                 └──────────────┘              └─────────────────┘
```

**时钟域**：
- `clk_ref`：100MHz本地参考时钟，驱动 `link_manager`
- `clk_div`（TX）：100MHz，由顶层外部输入，驱动 `tx_channel`
- `clk_ser`（TX）：400MHz，OSERDESE2串行时钟
- `clk_div`（RX）：由接收LVDS随路时钟经BUFR 4分频生成，驱动 `rx_phy`/`rx_link`
- `ref_clk_200m`：IDELAYCTRL参考时钟

---

## 3. V1"已修复"问题的残留缺陷

### R-01 🔴 致命：P-01修复引入训练阶段切换时序窗口缺陷

**文件**：`lvds_tx_channel.v` L120-135

**问题**：V1通过新增 `train_phase_cnt` 实现两阶段训练（0x55→0xB5），但存在两个残留问题：

**(a) 阶段切换时刻与RX延迟校准完成无握手**

`train_phase_cnt` 纯计数切换（2000周期后切0xB5），但RX端延迟校准（`D_CALC_WIN`）的完成时间取决于实际扫描进度，**与TX计数器无任何握手**。若RX延迟校准因通道质量差耗时超过2000周期，TX已切换到0xB5，而RX仍在用0x55做采样判定（`D_WAIT`状态检查 `iserdes_q != 8'h55`），导致：
- 0xB5被RX当作"非0x55"标记为 `sample_valid=0`
- 延迟窗口被错误标记，`best_delay_val` 计算错误

**(b) 退出训练时 `train_phase_cnt` 重置，但RX端无对应通知**

TX退出训练（`train_en=0`）时 `train_phase_cnt` 清零。若后续触发重训练，TX重新从0x55开始，但RX的延迟校准状态机 `D_IDLE` 仅在 `~lane_align_done & ~retrain_req` 时启动。如果 `lane_align_done` 未被正确清零（见R-03），RX不会重新扫描，而TX已重新发0x55，造成收发训练阶段错位。

**修复建议**：
- 增加TX→RX的训练阶段同步信号（如通过控制帧传递阶段切换），或
- RX延迟校准改为**自适应**：不依赖固定训练码，改用边沿过渡密度判定信号质量。

---

### R-02 🔴 致命：P-02/P-03修复后payload_len=0路径仍导致帧结构错误

**文件**：`lvds_tx_channel.v` L168, `lvds_rx_link.v` L84

**问题**：V1修复了下溢问题，但 `TX_LEN` 状态跳转仍保留：
```verilog
TX_LEN: tx_next_state = (payload_len == 8'd0) ? TX_CHECKSUM : TX_PAYLOAD;
```

当 `payload_len=0` 时，帧结构为 `SOF(2B) + TYPE(1B) + LEN(1B=0) + CHECKSUM(1B)`，共5字节。但3通道每周期传3字节，5字节需要2个周期。**第二个周期TX发送什么？** 查看 `tx_data_mux`：

```verilog
TX_LEN:      tx_data_mux = {16'd0, payload_len};  // {0x00, 0x00, 0x00}
TX_CHECKSUM: tx_data_mux = {16'd0, checksum_reg}; // {0x00, 0x00, checksum}
```

`TX_LEN` 周期发送 `{0x00, 0x00, payload_len}`，其中高2字节为0。RX端 `F_LEN` 状态提取 `frame_len = rx_data_in[(sof_offset+1)%3*8 +: 8]`，但**同一周期的另外2字节（0x00）被RX当作什么处理？** RX状态机在 `F_LEN` 后直接跳 `F_CHECKSUM`（因 `frame_len=0`），但 `F_CHECKSUM` 提取的是 `rx_data_in[(sof_offset+2)%3*8 +: 8]`——这是**同一周期**的数据，而TX的checksum在**下一周期**才发送。

**根因**：帧字段在3字节通道中的排布与状态机逐字段解析的时序不匹配。`payload_len=0` 时，`F_LEN` 和 `F_CHECKSUM` 期望的数据不在同一周期。

**影响**：`payload_len=0` 的帧（虽然当前设计未使用，但控制帧 `payload_len=1` 也有类似问题——见N-01）校验必定失败。

**修复建议**：重新设计帧字段在3字节通道中的排布，确保每个状态机周期提取的字段与TX发送周期严格对齐。建议绘制字节级时序图验证。

---

### R-03 🟠 严重：P-05修复后lane_align_done清零条件不完整

**文件**：`lvds_rx_lane_phy.v` L298-302

**问题**：V1修复使 `lane_align_done` 在 `W_IDLE` 不清零，改为仅由 `retrain_req | lane_calib_err` 清零。但代码为：

```verilog
if(align_check_cnt >= 8'd16) begin
    lane_align_done <= 1'b1;
end

if(retrain_req | lane_calib_err) begin
    lane_align_done <= 1'b0;
end
```

这两个 `if` 在同一always块中**顺序执行**。当 `retrain_req=1` 且 `align_check_cnt>=16` 同时成立时（理论上可能），后者覆盖前者，`lane_align_done` 被清零——这是正确的。但问题在于：**`lane_calib_err` 是延迟校准状态机的输出，在字对齐状态机运行期间 `lane_calib_err` 可能为0（校准成功），但如果延迟校准因信号变化重新触发 `lane_calib_err=1`，字对齐结果应作废**。当前代码确实处理了这种情况，✅这部分正确。

但残留问题是：**`lane_align_done` 一旦置1后永不自动清零（除非retrain/err），即使信号质量恶化导致 `iserdes_q` 不再是0xB5**。字对齐状态机在 `W_CHECK` 检测到 `iserdes_q != 0xB5` 时跳回 `W_BITSLIP` 重新对齐，但此时 `lane_align_done` 仍为1，上游 `all_lane_done` 仍为1，全局状态机不会回退。**字对齐的重新调整对上游不可见**。

**影响**：信号恶化时，物理层报告 `phy_ready=1` 但数据实际已错位，链路层收到错误数据直到心跳超时或校验错误计数超限才触发重训练。

**修复建议**：`lane_align_done` 应在字对齐状态机重新进入 `W_BITSLIP` 时清零，通知上游对齐已丢失。

---

### R-04 🟠 严重：P-07修复中CDC同步器对数据总线使用简单两级同步，存在数据不一致风险

**文件**：`lvds_bidirectional_top.v` L60-85

**问题**：V1添加了CDC同步器，但对 `ctrl_frame_type_out`（8bit）和 `ctrl_frame_payload_out`（8bit）使用简单两级寄存器同步：

```verilog
ctrl_frame_type_s1 <= ctrl_frame_type_out;
ctrl_frame_type_s2 <= ctrl_frame_type_s1;
```

**问题1**：多bit数据总线不能直接用两级同步器——各bit路径延迟不同，同步后可能得到**混合值**（部分bit是旧值、部分是新值）。虽然 `ctrl_frame_send` 脉冲同步后作为使能，但 `ctrl_frame_type_s2` 在脉冲有效时可能尚未稳定（`ctrl_frame_send` 在clk_ref域拉高时，`ctrl_frame_type_out` 可能刚好在变化）。

**问题2**：`ctrl_frame_send` 是clk_ref域的**单拍脉冲**，经两级同步后用边沿检测恢复。但如果clk_div频率接近或高于clk_ref，该脉冲可能在clk_div域被**多次采样**（若clk_ref脉冲宽度 > 1个clk_div周期）或**完全丢失**（若clk_ref脉冲在clk_div采样沿之间）。当前设计clk_ref=clk_div=100MHz，同频但不同源，脉冲宽度=1个clk_ref周期≈1个clk_div周期，**存在丢失风险**。

**修复建议**：
- 数据总线改用**握手同步**（req/ack协议）或**异步FIFO**，确保数据完整性。
- 脉冲信号改用**脉冲同步器**（pulse synchronizer）：在源域将脉冲转为电平，同步后在目的域用边沿检测恢复脉冲。

---

### R-05 🟡 一般：P-11修复中lane_deskew偏移检测仍可能对齐到错误位置

**文件**：`lane_deskew.v` L48-60

**问题**：V1修复增加了 `lane_offset[i] == 3'd0 && j > 0` 条件，意图"首次匹配后不再覆盖"。但此条件有缺陷：

```verilog
for(j = 0; j < DESKEW_DEPTH; j = j + 1) begin
    if(shift_reg[i][j] == sync_word && lane_offset[i] == 3'd0 && j > 0)
        lane_offset[i] <= j[2:0];
end
```

**(a)** `j > 0` 条件意味着 `j=0` 时的匹配被忽略。如果lane1与lane0无偏移（`j=0` 即对齐），`lane_offset` 永远不会被赋值，保持初始值0——**这恰好是正确的**，但逻辑上是"碰巧正确"而非"设计正确"。

**(b)** `lane_offset[i] == 3'd0` 条件意图防止覆盖，但在**同一个时钟周期内**的for循环中，`lane_offset[i]` 是寄存器**旧值**，for循环中多次 `<=` 赋值只有最后一次生效。因此条件 `lane_offset[i] == 3'd0` 在整个循环中始终为真（旧值为0），**无法防止循环内覆盖**。最终 `lane_offset[i]` 被赋值为循环中**最后一个** `j` 满足条件的位置，而非第一个。

**(c)** 更严重的是：`deskew_en` 期间每个时钟周期都执行此逻辑。如果第一个周期sync_word出现在 `j=2`，`lane_offset` 被设为2。但下一周期sync_word可能因数据流动出现在 `j=4`，由于 `lane_offset[i]` 现在是2（非0），条件不满足，不再更新——**这是正确的**。但如果第一周期sync_word未出现（`lane_offset` 保持0），第二周期sync_word出现在 `j=3`，则正确赋值。**然而**，如果数据流中恰好包含0xB5（非训练阶段），会导致错误对齐。

**影响**：在训练阶段（sync_word=0xB5持续发送）此逻辑基本可用，但鲁棒性差。

**修复建议**：使用显式 `found` 标志位，在for循环中首次匹配后置位，后续不再赋值。

---

## 4. V1报告遗漏的新发现问题

### N-01 🔴 致命：TX帧调度中控制帧payload_len=1导致RX帧解析错位

**文件**：`lvds_tx_channel.v` L188, `lvds_rx_link.v` L84

**问题**：控制帧 `payload_len=1`，帧结构为 `SOF(2B)+TYPE(1B)+LEN(1B)+PAYLOAD(1B)+CHECKSUM(1B)` = 6字节。在3字节/周期通道中需2个周期。

TX发送时序：
| 周期 | 状态 | tx_data_mux[23:16] | [15:8] | [7:0] |
|------|------|---------------------|--------|-------|
| 0 | TX_SOF_TYPE | tx_type_sel | SOF2(0x55) | SOF1(0xAA) |
| 1 | TX_LEN | 0x00 | 0x00 | payload_len(0x01) |
| 2 | TX_PAYLOAD | 0x00 | 0x00 | ctrl_frame_payload |
| 3 | TX_CHECKSUM | 0x00 | 0x00 | checksum |

RX帧解析时序（假设 `sof_offset=0`，即SOF在byte[7:0]/[15:8]）：
| 周期 | 状态 | 提取字段 | 提取位置 |
|------|------|----------|----------|
| 0 | F_IDLE→F_TYPE | - | 检测SOF |
| 1 | F_TYPE | frame_type | rx_data_in[0*8 +: 8] = byte[7:0] |
| 2 | F_LEN | frame_len | rx_data_in[(0+1)%3*8 +: 8] = rx_data_in[8+:8] = byte[15:8] |

**问题**：RX在 `F_TYPE` 周期提取 `byte[7:0]`，但TX在 `TX_SOF_TYPE` 周期发送的 `byte[7:0]` 是 `SOF1(0xAA)`，`byte[15:8]` 是 `SOF2(0x55)`，`byte[23:16]` 是 `tx_type_sel`。

由于3字节通道每周期传3字节，而帧字段是连续的，**RX的 `sof_offset` 决定了字段在24bit中的位置**。但TX发送时字段排布是固定的（SOF1在byte0，SOF2在byte1，TYPE在byte2），RX的 `sof_offset` 取决于SOF在24bit窗口中的检测位置。

当 `sof_offset=0`（SOF1在byte[7:0]，SOF2在byte[15:8]）时：
- `F_TYPE` 提取 `rx_data_in[0*8 +: 8]` = byte[7:0]——但此时RX收到的24bit是TX的下一个周期（`TX_LEN`），byte[7:0]=payload_len，**不是TYPE！**

**根因**：TX的帧调度状态机每个状态持续1个 `clk_div` 周期，发送3字节。RX的帧解析状态机也每个状态持续1个周期，接收3字节。但TX和RX的**状态机不对齐**——TX在周期0发SOF+TYPE，RX在周期0检测到SOF后，周期1才进入F_TYPE提取TYPE，但此时TX已发LEN。**收发状态机存在1拍错位**。

**影响**：所有帧类型的TYPE、LEN、PAYLOAD、CHECKSUM字段全部提取错误，帧校验必定失败，链路无法建立。这是比P-01更根本的协议级缺陷。

**修复建议**：
- 重新设计帧字段排布，使每个clk_div周期发送的3字节与RX状态机的字段提取严格对齐。
- 或在RX端增加弹性缓冲（elastic buffer），先缓存完整帧再解析。
- 建议绘制TX/RX逐周期字节级时序图，验证每个字段的对齐关系。

---

### N-02 🔴 致命：TX FIFO读时序与payload发送存在1拍错位，导致首字节丢失

**文件**：`lvds_tx_channel.v` L200-215

**问题**：TX_PAYLOAD状态中，`fifo_rd_en` 在 `TX_LEN` 状态置1（当 `payload_len != 0 && tx_type_sel == TYPE_USR`），但FIFO是 `FIFO_READ_LATENCY=0` 的FWFT模式：

```verilog
TX_LEN: begin
    if(payload_len != 8'd0 && tx_type_sel == TYPE_USR) begin
        fifo_rd_en <= 1'b1;  // 周期N置1
    end
end
TX_PAYLOAD: begin
    // 周期N+1: fifo_dout已是第一个数据，tx_data_mux = fifo_dout ✅
    fifo_rd_en <= (payload_cnt + LANE_CNT < payload_len);  // 预读下一拍
end
```

时序分析（FWFT, latency=0）：
- 周期N（TX_LEN）：`fifo_rd_en` 在**周期末**置1
- 周期N+1（TX_PAYLOAD第1拍）：`fifo_dout` 输出第1个数据，`tx_data_mux=fifo_dout` ✅。同时 `fifo_rd_en` 根据 `payload_cnt(0) + 3 < payload_len` 判断是否继续读
- 周期N+2（TX_PAYLOAD第2拍）：`fifo_dout` 输出第2个数据 ✅

**但问题在于**：`fifo_rd_en` 在 `TX_LEN` 状态是**时序赋值**（`<=`），在周期N末才生效。FWFT模式下，`rd_en` 在周期N+1有效时，`fifo_dout` 在周期N+1即输出数据。但 `TX_PAYLOAD` 在周期N+1使用 `fifo_dout`——**这是正确的**。

然而，`fifo_rd_en` 在 `TX_PAYLOAD` 中也是时序赋值：
```verilog
fifo_rd_en <= (payload_cnt + LANE_CNT < payload_len);
```
周期N+1（`payload_cnt=0`）：`fifo_rd_en <= (0+3 < payload_len)`。如果 `payload_len=6`，则 `3<6` 为真，`fifo_rd_en` 在周期N+2置1。
周期N+2（`payload_cnt=3`）：使用 `fifo_dout`（第2个数据），`fifo_rd_en <= (3+3 < 6)` = false。

**问题**：`payload_cnt` 在 `TX_PAYLOAD` 中也是时序赋值 `payload_cnt <= payload_cnt + LANE_CNT`。周期N+1时 `payload_cnt` 仍为0（旧值），`fifo_rd_en <= (0+3<6)=1`。周期N+2时 `payload_cnt` 为3，`fifo_rd_en <= (3+3<6)=0`。但周期N+2的 `fifo_dout` 是周期N+1 `rd_en=1` 的结果——**第2个数据**。✅ 时序正确。

**但**：当 `payload_len` 不是LANE_CNT的整数倍时（如 `payload_len=4`，用户数据4字节）：
- 周期N+1（`payload_cnt=0`）：发第1-3字节，`fifo_rd_en <= (0+3<4)=1`
- 周期N+2（`payload_cnt=3`）：发第4字节+2字节无效数据，`fifo_rd_en <= (3+3<4)=0`

**问题**：`payload_len=4` 时，FIFO读了2次（周期N的 `TX_LEN` 读1次 + 周期N+1的 `rd_en` 读1次），共读出6字节，但实际只需4字节。**多读的2字节被丢弃，FIFO指针前移2字节，导致后续帧数据错位**。

更严重的是，`payload_len` 的计算：
```verilog
payload_len <= fifo_data_cnt[7:0] * LANE_CNT;
```
`fifo_data_cnt` 是FIFO中的**字数**（每字24bit=3字节），`payload_len = 字数 * 3`，所以 `payload_len` 始终是3的倍数。**但控制帧 `payload_len=1` 和心跳帧 `payload_len=2` 不是3的倍数**，这些帧不读FIFO（`tx_type_sel != TYPE_USR`），所以FIFO指针不受影响。✅ 这部分实际正确。

**但残留问题**：用户数据帧的 `payload_len` 是3的倍数，FIFO每次读24bit，`payload_cnt` 每次加3，退出条件 `payload_cnt >= payload_len - 3`。当 `payload_len=3` 时，`payload_cnt` 从0开始，`0 >= 3-3=0` 为真，**立即退出TX_PAYLOAD**。但此时 `fifo_dout` 的数据还没被发送！

**根因**：`TX_PAYLOAD` 的退出条件在进入状态的第一拍就满足（`payload_cnt=0 >= payload_len-LANE_CNT=0`），状态机直接跳 `TX_CHECKSUM`，**用户数据被完全跳过**。

**影响**：`payload_len=3`（即FIFO中只有1个字）的用户数据帧不发送任何payload，接收端收到空帧。

**修复建议**：退出条件应改为 `payload_cnt + LANE_CNT >= payload_len`，确保至少发送1拍payload后再退出。

---

### N-03 🔴 致命：RX帧解析器sof_offset跨状态不保持，导致字段提取位置错误

**文件**：`lvds_rx_link.v` L113-140

**问题**：`sof_offset` 在 `F_IDLE` 状态检测到SOF时锁存：
```verilog
F_IDLE: begin
    if(sof_detected) begin
        sof_offset <= det_offset;
        ...
    end
end
```

但后续状态使用 `sof_offset` 提取字段：
```verilog
F_TYPE: frame_type <= rx_data_in[sof_offset*8 +: 8];
F_LEN:  frame_len <= rx_data_in[(sof_offset+1)%3*8 +: 8];
F_PAYLOAD: ... rx_data_in[(sof_offset+2)%3*8 +: 8];
F_CHECKSUM: rx_data_in[(sof_offset+2)%3*8 +: 8];
```

**问题1**：`sof_offset` 是时序赋值（`<=`），在 `F_IDLE` 周期写入，但 `F_TYPE` 在**下一周期**才使用。由于 `sof_offset` 是寄存器，下一周期值已更新——✅ 这部分正确。

**问题2**：字段提取使用 `(sof_offset+1)%3` 和 `(sof_offset+2)%3`，假设帧字段在3字节通道中**连续排布**。但如N-01所述，TX每个状态周期发送3字节，字段在24bit中的位置取决于TX的 `tx_data_mux` 排布。RX的 `sof_offset` 只表示SOF在24bit窗口中的位置，**不表示后续字段的位置**——因为TX的后续字段在**下一个时钟周期的24bit中**，不在同一周期的其他字节位置。

**根因**：RX帧解析器假设帧字段在3字节通道中**同一周期内连续**（如SOF在byte0-1，TYPE在byte2，LEN在下一周期byte0），但提取公式 `rx_data_in[(sof_offset+1)%3*8 +: 8]` 试图从**同一周期**的其他字节位置提取下一字段。实际上，`sof_offset=0` 时SOF占byte0-1，TYPE在byte2（`sof_offset+2=2`），LEN在**下一周期**的byte0。但代码用 `(sof_offset+1)%3=1` 从byte1提取LEN——**这是SOF2的位置，不是LEN**。

**影响**：所有帧的LEN、PAYLOAD、CHECKSUM字段提取位置错误，帧解析完全失败。

**修复建议**：重新设计帧字段提取逻辑，正确处理跨周期字段。建议使用字节级缓冲区，将多个周期的24bit数据拼接后按字节偏移提取。

---

### N-04 🔴 致命：BUFR分频比"4"与DATA_WIDTH=8 DDR模式不匹配

**文件**：`lvds_rx_phy.v` L83

**问题**：
```verilog
BUFR #(.BUFR_DIVIDE("4"), .SIM_DEVICE("7SERIES")) u_bufr_div (
    .I(clk_ibuf), .O(clk_div), .CE(1'b1), .CLR(~rst_n)
);
```

ISERDESE2配置为 `DATA_RATE="DDR"` + `DATA_WIDTH=8`。根据UG471，DDR模式下 `DATA_WIDTH=8` 要求 `CLK/CLKDIV = 4`（串行时钟是并行时钟的4倍）。

BUFR输入是 `clk_ibuf`（LVDS随路时钟经IBUFDS后的单端时钟）。TX端OSERDESE2用 `clk_ser=400MHz` 串行、`clk_div=100MHz` 并行，发送的LVDS时钟是 `10101010` 模式，即**200MHz**（DDR，每个bit周期2.5ns，8bit=20ns=50MHz并行速率？）。

**仔细计算**：
- TX: `clk_ser=400MHz`，DDR 8:1，并行速率 = 400/4 = 100MHz。LVDS时钟线发送 `10101010`，在400MHz串行下，8bit耗时20ns，即50MHz周期。但DDR模式下时钟线每bit翻转，实际LVDS时钟频率 = 400/2 = 200MHz。
- RX: IBUFDS输出200MHz，BUFIO直通200MHz给ISERDESE2的CLK。BUFR 4分频 = 200/4 = 50MHz。

**但ISERDESE2 DDR DATA_WIDTH=8要求 CLK/CLKDIV=4**，即200/50=4 ✅。

**然而**，TX的 `clk_div=100MHz`，RX的 `clk_div=50MHz`，**收发并行时钟速率不匹配**！TX每100ns发1个24bit，RX每20ns收1个24bit——**RX采样速率是TX发送速率的2倍**，会重复采样。

**根因**：TX端 `clk_div` 由外部100MHz提供，RX端 `clk_div` 由LVDS随路时钟BUFR分频得到50MHz。两端并行时钟不同频。

**影响**：RX以2倍速率采样，每个TX数据被采样2次，帧解析完全错乱。

**修复建议**：
- BUFR分频比改为"2"：200/2=100MHz，与TX `clk_div` 一致。
- 或TX端 `clk_div` 改为50MHz，但需同步调整 `clk_ser`。
- 需要根据实际LVDS时钟频率严格计算，建议在约束文件中验证。

---

### N-05 🟠 严重：lvds_rx_link中retrain_req与retrain_ack时序竞争

**文件**：`lvds_rx_link.v` L168-170, `lvds_rx_channel.v` L65-70

**问题**：`lvds_rx_link` 中 `retrain_req` 的清除依赖 `retrain_ack`：
```verilog
// lvds_rx_link.v 最后
if(retrain_ack) retrain_req <= 1'b0;
```

`lvds_rx_channel.v` 中：
```verilog
assign retrain_trigger = retrain_req_inner;
reg retrain_req_inner_d;
always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n) retrain_req_inner_d <= 1'b0;
    else retrain_req_inner_d <= retrain_req_inner;
end
// ...
.retrain_ack(retrain_req_inner_d),  // 延迟1拍
```

**时序**：
- 周期N：`retrain_req_inner` 置1（由帧错误或心跳超时触发）
- 周期N+1：`retrain_req_inner_d` 置1，`retrain_ack=1`，`retrain_req_inner` 清零
- 周期N+2：`retrain_req_inner_d` 清零

**问题**：`retrain_req_inner` 仅持续2拍（N和N+1）。`u_phy` 的 `retrain_req` 输入是 `retrain_req | retrain_req_inner`。如果外部 `retrain_req=0`，则物理层收到的重训练请求仅持续2拍。

物理层 `lvds_rx_phy` 的全局状态机在 `M_NORMAL` 状态检测 `retrain_req`：
```verilog
M_NORMAL: if(retrain_req) m_next_state = M_IDLE;
```
状态机在周期N+1检测到 `retrain_req=1`，周期N+2跳转到 `M_IDLE`。但 `retrain_req_inner` 在周期N+1已清零（因 `retrain_ack` 在N+1已生效），**物理层可能来不及响应**。

更严重的是，`retrain_req_inner` 清零后，`u_phy.retrain_req` 变为0。如果物理层状态机在 `M_NORMAL` 的检测有1拍延迟，可能**错过**这个2拍脉冲。

**影响**：重训练请求可能被过早清除，物理层不响应，链路无法恢复。

**修复建议**：`retrain_ack` 应在确认物理层已进入重训练状态后（如 `phy_ready=0`）才清除 `retrain_req`，而非简单延迟1拍。

---

### N-06 🟠 严重：lane_deskew的data_out组合输出在deskew_done前输出未对齐数据

**文件**：`lane_deskew.v` L70-76

**问题**：
```verilog
always @(*) begin
    data_out[0*DATA_WIDTH +: DATA_WIDTH] = shift_reg[0][0];
    for(i = 1; i < LANE_CNT; i = i + 1) begin
        data_out[i*DATA_WIDTH +: DATA_WIDTH] = shift_reg[i][lane_offset[i]];
    end
end
```

`data_out` 是组合逻辑，在 `deskew_done` 置1前 `lane_offset` 可能为0或中间值，**输出未对齐的数据**。上游 `lvds_rx_phy` 在 `M_LOCK_CHECK` 状态使用 `deskew_data_out` 检查3路是否均为0xB5：

```verilog
M_LOCK_CHECK: begin
    if(deskew_data_out[7:0] == 8'hB5 && ...)
        lock_match_cnt <= lock_match_cnt + 1'b1;
end
```

但 `M_LOCK_CHECK` 在 `deskew_done` 后才进入，此时 `lane_offset` 应已锁定。**问题在于**：`deskew_done` 置1后，`lane_offset` 不再更新，但如果此时 `lane_offset` 值不正确（如R-05所述首次匹配问题），`data_out` 持续输出错误对齐数据，`lock_match_cnt` 无法达到阈值，状态机进入 `M_FAULT`。

**影响**：如果 `lane_offset` 锁定到错误值，锁定检查失败，链路无法建立。

**修复建议**：`deskew_done` 应在 `lane_offset` 稳定且验证正确后才置1，而非简单计数16次。

---

### N-07 🟠 严重：lvds_rx_phy的M_FAULT状态retry_cnt溢出后死锁

**文件**：`lvds_rx_phy.v` L137, L180-186

**问题**：
```verilog
M_FAULT: if(retry_cnt < MAX_RETRY) m_next_state = M_IDLE;
```
```verilog
always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n) retry_cnt <= 2'd0;
    else if(m_curr_state == M_IDLE && m_next_state == M_CALIB)
        retry_cnt <= retry_cnt + 1'b1;
    else if(m_curr_state == M_NORMAL)
        retry_cnt <= 2'd0;
end
```

`retry_cnt` 是2bit，`MAX_RETRY=3`。当 `retry_cnt` 达到3时，`M_FAULT` 状态条件 `retry_cnt < 3` 为假，**状态机永久卡在 `M_FAULT`**，只有复位才能恢复。

**问题**：`retry_cnt` 仅在 `M_NORMAL` 时清零，但如果链路从未达到 `M_NORMAL`（一直校准失败），`retry_cnt` 递增到3后死锁。**没有外部通知机制**（如中断或状态输出）告知上游链路已永久故障。

**影响**：链路在3次校准失败后永久死锁，无法自恢复。

**修复建议**：
- 增加故障输出信号 `link_permanent_fault`，通知上层。
- 或在 `M_FAULT` 中 `retry_cnt >= MAX_RETRY` 时延迟一段时间后重置 `retry_cnt` 重新尝试。

---

### N-08 🟠 严重：lvds_link_manager主从握手存在死锁窗口

**文件**：`lvds_link_manager.v` L112-120

**问题**：主从握手流程：
1. 从机：`S_TRAINING` → `S_WAIT_PEER`，周期性发送 `SLAVE_READY`
2. 主机：`S_TRAINING` → `S_WAIT_PEER`，等待收到 `SLAVE_READY` 后置 `master_recv_slave_ready`，然后发送 `MASTER_ACK`
3. 从机：收到 `MASTER_ACK` 后 → `S_LINK_UP`
4. 主机：发送 `MASTER_ACK` 后……**何时进入 `S_LINK_UP`？**

查看状态机：
```verilog
S_WAIT_PEER: begin
    if(IS_MASTER) begin
        if(ctrl_frame_valid_pulse && ctrl_frame_type_sync2 == TYPE_SLAVE_READY) begin
            next_state = S_LINK_UP;  // 主机收到SLAVE_READY直接进LINK_UP
        end
    end
end
```

主机收到 `SLAVE_READY` 后**直接进入 `S_LINK_UP`**，但此时从机可能还没收到 `MASTER_ACK`！主机已进入 `S_LINK_UP`（`tx_train_en=0`，停止训练码发送），但从机仍在 `S_WAIT_PEER`（`tx_train_en=1`，继续发训练码）。

**问题**：
- 主机进入 `S_LINK_UP` 后停止发训练码，开始发用户数据/心跳
- 从机仍在 `S_WAIT_PEER`，物理层期望接收训练码（0x55/0xB5）做字对齐
- 从机收到主机的用户数据/心跳帧，物理层字对齐检查失败（非0xB5），可能触发重训练
- 从机可能永远收不到 `MASTER_ACK`（因为主机已停止发控制帧）

**根因**：主机收到 `SLAVE_READY` 后应先发送 `MASTER_ACK`，**等待从机确认**后再进入 `S_LINK_UP`。当前设计主机直接跳 `S_LINK_UP`，跳过了等待从机确认的步骤。

**影响**：主从握手可能死锁——主机进入LINK_UP，从机卡在WAIT_PEER。

**修复建议**：增加 `S_WAIT_ACK` 状态，主机发送 `MASTER_ACK` 后等待从机的确认帧（如 `SLAVE_ACK`）再进入 `S_LINK_UP`。

---

### N-09 🟠 严重：lvds_link_manager中ctrl_frame_send脉冲与数据总线时序不保证

**文件**：`lvds_link_manager.v` L185-200

**问题**：
```verilog
S_WAIT_PEER: begin
    ctrl_send_timer <= ctrl_send_timer + 1'b1;
    if(ctrl_send_timer >= CTRL_SEND_INTERVAL) begin
        ctrl_send_timer <= 16'd0;
        ctrl_frame_send <= 1'b1;  // 脉冲

        if(IS_MASTER) begin
            if(master_recv_slave_ready) begin
                ctrl_frame_type_out <= TYPE_MASTER_ACK;
                ctrl_frame_payload_out <= 8'h01;
            end
        end else begin
            ctrl_frame_type_out <= TYPE_SLAVE_READY;
            ctrl_frame_payload_out <= 8'h01;
        end
    end
end
```

`ctrl_frame_send` 和 `ctrl_frame_type_out`/`ctrl_frame_payload_out` 在**同一时钟周期**赋值。由于都是时序赋值（`<=`），它们在**下一周期**同时生效。顶层CDC同步器在 `clk_div` 域同步这些信号：

```verilog
// lvds_bidirectional_top.v
ctrl_frame_send_s1 <= ctrl_frame_send;
ctrl_frame_type_s1 <= ctrl_frame_type_out;
```

**问题**：`ctrl_frame_send` 是脉冲（仅1拍），`ctrl_frame_type_out` 在脉冲有效时才更新。但CDC同步器对脉冲和数据总线分别同步，**数据总线同步后比脉冲晚1拍**（因数据总线变化与脉冲同时，但同步路径独立）。同步后 `ctrl_frame_send_sync` 有效时，`ctrl_frame_type_s2` 可能还是**旧值**。

**更详细分析**：
- 周期N（clk_ref）：`ctrl_frame_send=1`, `ctrl_frame_type_out=TYPE_MASTER_ACK`（同时赋值，N+1生效）
- 周期N+1（clk_ref）：`ctrl_frame_send=0`（脉冲结束），`ctrl_frame_type_out=TYPE_MASTER_ACK`
- clk_div域同步：`ctrl_frame_send_s1` 在某周期采样到1，`ctrl_frame_type_s1` 同周期采样到 `TYPE_MASTER_ACK`——**如果clk_div与clk_ref同频且相位接近**，数据可能正确。但若相位偏移，`ctrl_frame_type_s1` 可能采样到旧值。

**影响**：跨时钟域后控制帧类型可能错误，导致握手失败。

**修复建议**：`ctrl_frame_type_out`/`ctrl_frame_payload_out` 应在 `ctrl_frame_send` 脉冲**之前1拍**更新并保持稳定，或使用握手协议确保数据与脉冲同步到达。

---

### N-10 🟠 严重：lvds_tx_channel心跳帧checksum计算与发送数据不匹配

**文件**：`lvds_tx_channel.v` L215, L240

**问题**：心跳帧checksum计算：
```verilog
TYPE_HB: begin
    checksum_reg <= checksum_reg + heartbeat_cnt[15:8] + heartbeat_cnt[7:0];
end
```

心跳帧发送数据：
```verilog
TYPE_HB: tx_data_mux = {8'd0, heartbeat_cnt[7:0], heartbeat_cnt[15:8]};
```

**问题**：发送时 `tx_data_mux` = `{0x00, heartbeat_cnt[7:0], heartbeat_cnt[15:8]}`，即byte0=低字节，byte1=高字节，byte2=0x00。但checksum只加了高字节和低字节，**没有加byte2的0x00**（加0无影响，✅）。

但RX端心跳帧checksum计算（`lvds_rx_link.v` L131）：
```verilog
checksum_calc <= checksum_calc + rx_data_in[7:0] + rx_data_in[15:8] + rx_data_in[23:16];
```
RX对3字节都求和。TX的checksum只加了2字节。**如果byte2=0x00，TX和RX的checksum一致** ✅。

**但**：TX发送的心跳payload字节顺序是 `{0x00, heartbeat_cnt[7:0], heartbeat_cnt[15:8]}`，即byte0=低字节在前。RX提取心跳计数：
```verilog
heartbeat_recv_cnt[15:8] <= rx_data_in[(sof_offset+2)%3*8 +: 8];
heartbeat_recv_cnt[7:0]  <= rx_data_in[(sof_offset+3)%3*8 +: 8];
```

`(sof_offset+3)%3 = sof_offset`，所以RX提取 `heartbeat_recv_cnt[7:0] = rx_data_in[sof_offset*8 +: 8]`。但如N-03所述，`sof_offset` 的含义和字段位置不匹配，**心跳计数的高低字节可能被反转**。

**影响**：即使帧校验通过，心跳计数值可能高低字节反转，不影响功能（心跳仅用于超时检测），但违反设计意图。

**修复建议**：统一TX发送字节序和RX提取字节序，建议在设计文档中明确定义字节排布规则。

---

### N-11 🟡 一般：lvds_rx_lane_phy延迟校准D_WAIT状态采样窗口不足

**文件**：`lvds_rx_lane_phy.v` L149-152

**问题**：
```verilog
D_WAIT: begin
    sample_cnt <= sample_cnt + 1'b1;
    if(iserdes_q != 8'h55) sample_valid <= 1'b0;
end
D_SAMPLE: begin
    valid_window[scan_step] <= sample_valid;
    scan_step <= scan_step + 1'b1;
end
```

`D_WAIT` 等待 `SAMPLE_CNT-1=15` 个周期，期间检查 `iserdes_q` 是否始终为0x55。但 `sample_valid` 初始为1，一旦 `iserdes_q != 0x55` 就清零。

**问题**：`SAMPLE_CNT=16`，但16个周期的采样窗口可能不足以覆盖所有数据模式。如果训练码0x55在某个延迟tap下偶尔出现误码（如1bit翻转），16次采样中只要有1次不是0x55就标记为无效。**没有容错机制**。

**影响**：在噪声环境下，有效延迟窗口可能被错误标记为无效，导致 `best_delay_val` 计算错误或 `lane_calib_err` 误报。

**修复建议**：增加容错阈值，如16次采样中允许1-2次非0x55仍判定为有效窗口。

---

### N-12 🟡 一般：lvds_rx_lane_phy字对齐bitslip_cnt溢出无处理

**文件**：`lvds_rx_lane_phy.v` L265

**问题**：
```verilog
W_BITSLIP: begin
    bitslip_req <= 1'b1;
    bitslip_cnt <= bitslip_cnt + 1'b1;
end
```

`bitslip_cnt` 是4bit，`MAX_BITSLIP=8`。但状态机中**没有检查 `bitslip_cnt >= MAX_BITSLIP`**：

```verilog
W_CHECK: begin
    if(align_check_cnt >= 8'd16)
        w_next_state = W_IDLE;
    else if(iserdes_q != 8'hB5)
        w_next_state = W_BITSLIP;  // 回W_BITSLIP继续
end
```

如果8次BITSLIP后仍未对齐（`iserdes_q != 0xB5`），状态机继续回 `W_BITSLIP`，`bitslip_cnt` 继续递增到9、10……15、0（溢出）。**ISERDESE2的BITSLIP在8次后回到初始位置**，继续BITSLIP是无效的循环。

**影响**：字对齐失败时状态机无限循环BITSLIP，无法退出报错。

**修复建议**：在 `W_BITSLIP` 或 `W_CHECK` 中检查 `bitslip_cnt >= MAX_BITSLIP`，若超过则置 `lane_calib_err=1` 并回 `W_IDLE`。

---

### N-13 🟡 一般：lvds_rx_phy的lock_match_cnt阈值与lock_timer周期不匹配

**文件**：`lvds_rx_phy.v` L160-166

**问题**：
```verilog
localparam LOCK_CHECK_CYCLES = 16'd5000;
localparam LOCK_VOTE_THRESHOLD = 8'd200;
```

`lock_timer` 计数到5000周期后检查 `lock_match_cnt >= 200`。即5000个周期中至少200个周期检测到3路0xB5，通过率 200/5000 = 4%。

**问题**：4%的通过率太低。如果训练阶段1（0xB5）持续2000个TX周期，RX在50MHz下约4000个周期收到0xB5，通过率应接近100%。4%阈值可能导致**噪声环境下误通过**（偶尔出现0xB5模式的数据被误判为锁定）。

**影响**：锁定检查可能误判，在非训练数据中偶然出现0xB5时错误进入 `M_NORMAL`。

**修复建议**：提高阈值至80%以上（如4000/5000），或增加连续匹配要求（如连续100拍0xB5才计数）。

---

### N-14 🟡 一般：lvds_rx_link中heartbeat_timer在非phy_ready时未完全清零

**文件**：`lvds_rx_link.v` L100-110

**问题**：
```verilog
end else if(!phy_ready) begin
    ...
    heartbeat_timer <= 20'd0;
    heartbeat_miss_cnt <= 4'd0;
    ...
end else if(rx_data_valid) begin
    ...
    heartbeat_timer <= heartbeat_timer + 1'b1;
```

`heartbeat_timer` 在 `!phy_ready` 时清零，在 `rx_data_valid` 时递增。但**如果 `phy_ready=1` 但 `rx_data_valid=0`**（物理层就绪但无有效数据），`heartbeat_timer` 既不清零也不递增——**保持上一次的值**。

**问题**：`rx_data_valid` 来自物理层 `u_phy` 的 `rx_data_valid = phy_ready`（`lvds_rx_phy.v` L113）。所以 `phy_ready=1` 时 `rx_data_valid=1`，不会出现 `phy_ready=1 && rx_data_valid=0` 的情况。✅ 当前设计无此问题。

但**如果未来修改 `rx_data_valid` 逻辑**（如增加数据有效门控），此隐患会暴露。

**修复建议**：在 `phy_ready=1 && !rx_data_valid` 时也递增 `heartbeat_timer`，确保超时检测不遗漏。

---

### N-15 🟡 一般：lvds_link_manager中IS_MASTER参数在状态机组合逻辑中使用if而非generate

**文件**：`lvds_link_manager.v` L112-120

**问题**：
```verilog
S_WAIT_PEER: begin
    if(IS_MASTER) begin
        ...
    end else begin
        ...
    end
end
```

`IS_MASTER` 是参数（parameter），在综合时为常量。`if(IS_MASTER)` 在综合时会被优化掉，**但 `else` 分支的代码仍会被综合工具解析**。如果 `IS_MASTER=1`，`else` 分支的 `ctrl_frame_type_out <= TYPE_SLAVE_READY` 会被优化掉，但部分综合工具可能报warning。

**影响**：无功能影响，但代码可读性和可维护性差。

**修复建议**：使用 `generate` 块或在模块顶层用两个独立模块（master/slave）替代参数化分支。

---

## 5. Testbench缺陷

### T-01 🔴 致命：Testbench使用独立clk_div，与DUT内部BUFR分频冲突

**文件**：`lvds_3lane_bidirectional_tb.v` L40-47

**问题**：
```verilog
initial clk_div_master = 0;
always #(CLK_REF_PERIOD/2) clk_div_master = ~clk_div_master;
initial clk_div_slave = 0;
always #(CLK_REF_PERIOD/2) clk_div_slave = ~clk_div_slave;
```

Testbench为DUT提供外部 `clk_div`（100MHz），但DUT内部 `lvds_rx_phy` 的 `clk_div` 是**输出信号**（由BUFR分频生成）：

```verilog
// lvds_rx_channel.v
output wire clk_div,
// lvds_rx_phy.v
BUFR u_bufr_div (.I(clk_ibuf), .O(clk_div), ...);
```

**问题**：`lvds_rx_channel` 的 `clk_div` 是输出端口，但 `lvds_bidirectional_top` 的 `clk_div` 是**输入端口**。顶层将外部输入 `clk_div` 连接到 `u_tx`，但 `u_rx` 的 `clk_div` 是输出。**TX和RX使用不同的clk_div**——TX用外部100MHz，RX用BUFR分频的50MHz（见N-04）。

Testbench为TX提供100MHz `clk_div`，但RX的 `clk_div` 由DUT内部BUFR生成，**Testbench无法控制RX时钟频率**。在仿真中BUFR行为模型可能不精确，导致RX时钟频率与预期不符。

**影响**：仿真结果可能与实际硬件行为不一致，无法有效验证设计。

**修复建议**：Testbench应模拟实际时钟拓扑——TX `clk_div` 由外部MMCM/PLL生成，RX `clk_div` 由LVDS随路时钟经BUFR生成。仿真中需使用BUFR行为模型或手动生成对应频率的时钟。

---

### T-02 🟠 严重：Testbench数据比对逻辑在clk_ref域采样rx_data，但rx_data在clk_div域变化

**文件**：`lvds_3lane_bidirectional_tb.v` L215-230

**问题**：
```verilog
always @(posedge clk_ref_slave or negedge rst_n) begin
    if(!rst_n) begin
        ...
    end else if(slv_rx_valid && slv_link_up) begin
        slv_rx_byte_cnt <= slv_rx_byte_cnt + 1;
        if(slv_rx_data != slv_expect_data) begin
            ...
        end
        slv_expect_data <= slv_expect_data + 1'b1;
    end
end
```

`slv_rx_valid` 和 `slv_rx_data` 来自DUT的 `user_rx_valid`/`user_rx_data`，这些信号在 `clk_div`（RX域）变化。Testbench在 `clk_ref` 域采样，**存在跨时钟域采样亚稳态风险**（仿真中可能表现为数据错误或漏采）。

**影响**：仿真中可能误报数据错误，或漏采有效数据。

**修复建议**：在Testbench中使用 `clk_div` 域采样RX数据，或添加同步器。

---

### T-03 🟡 一般：Testbench中lane_delay使用real类型，不可综合且精度依赖仿真器

**文件**：`lvds_3lane_bidirectional_tb.v` L75

**问题**：
```verilog
real lane_delay[0:2];
...
assign #(2.0 + lane_delay[lane]) m2s_data_p_del[lane] = ...;
```

`real` 类型用于延迟建模，但 `#(2.0 + lane_delay[lane])` 的延迟精度依赖仿真器的时间分辨率设置。如果时间分辨率为1ns，1.5ns延迟被舍入为2ns，**通道偏移测试失效**。

**影响**：通道偏移测试可能无法验证亚纳秒级偏移对齐功能。

**修复建议**：使用 `timescale` 配合整数延迟，或在仿真配置中设置高精度时间分辨率（如1ps）。

---

## 6. 问题全量汇总表

| 编号 | 严重程度 | 类型 | 模块 | 问题简述 | V1状态 |
|------|----------|------|------|----------|--------|
| **R-01** | 🔴致命 | 残留 | tx_channel | 训练阶段切换无握手，收发阶段错位 | P-01修复残留 |
| **R-02** | 🔴致命 | 残留 | tx_channel/rx_link | payload_len=0帧字段时序错位 | P-02/P-03修复残留 |
| **R-03** | 🟠严重 | 残留 | rx_lane_phy | lane_align_done信号恶化时不清零 | P-05修复残留 |
| **R-04** | 🟠严重 | 残留 | top | CDC数据总线同步不一致 | P-07修复残留 |
| **R-05** | 🟡一般 | 残留 | lane_deskew | 偏移检测for循环仍可能错误对齐 | P-11修复残留 |
| **N-01** | 🔴致命 | 新发现 | tx_channel/rx_link | 控制帧payload_len=1导致收发状态机1拍错位 | 遗漏 |
| **N-02** | 🔴致命 | 新发现 | tx_channel | payload_len=3时用户数据被跳过 | 遗漏 |
| **N-03** | 🔴致命 | 新发现 | rx_link | sof_offset字段提取跨周期位置错误 | 遗漏 |
| **N-04** | 🔴致命 | 新发现 | rx_phy | BUFR分频比与DATA_WIDTH不匹配 | 遗漏 |
| **N-05** | 🟠严重 | 新发现 | rx_channel/rx_link | retrain_req脉冲过窄，物理层可能漏检 | 遗漏 |
| **N-06** | 🟠严重 | 新发现 | lane_deskew/rx_phy | deskew_done前输出未对齐数据 | 遗漏 |
| **N-07** | 🟠严重 | 新发现 | rx_phy | retry_cnt溢出后M_FAULT永久死锁 | 遗漏 |
| **N-08** | 🟠严重 | 新发现 | link_manager | 主从握手死锁，主机不等从机确认 | 遗漏 |
| **N-09** | 🟠严重 | 新发现 | link_manager/top | ctrl_frame脉冲与数据总线CDC不同步 | 遗漏 |
| **N-10** | 🟠严重 | 新发现 | tx_channel/rx_link | 心跳帧字节序TX/RX不匹配 | 遗漏 |
| **N-11** | 🟡一般 | 新发现 | rx_lane_phy | 延迟校准采样窗口无容错 | 遗漏 |
| **N-12** | 🟡一般 | 新发现 | rx_lane_phy | bitslip_cnt溢出无处理 | 遗漏 |
| **N-13** | 🟡一般 | 新发现 | rx_phy | lock_match_cnt阈值过低 | 遗漏 |
| **N-14** | 🟡一般 | 新发现 | rx_link | heartbeat_timer在无数据时停滞 | 遗漏 |
| **N-15** | 🟡一般 | 新发现 | link_manager | IS_MASTER参数用if而非generate | 遗漏 |
| **T-01** | 🔴致命 | TB | tb | clk_div拓扑与实际硬件不一致 | 遗漏 |
| **T-02** | 🟠严重 | TB | tb | 数据比对跨时钟域采样 | 遗漏 |
| **T-03** | 🟡一般 | TB | tb | real类型延迟精度依赖仿真器 | 遗漏 |

---

## 7. 修复优先级建议

### 第一优先级（必须修复，否则链路无法建立）

1. **N-04**：BUFR分频比修正——收发并行时钟必须同频
2. **N-01/N-03**：帧字段收发时序对齐——重新设计3字节通道中的帧字段排布
3. **N-02**：TX_PAYLOAD退出条件修正——确保至少发送1拍payload
4. **R-01**：训练阶段握手——TX/RX训练阶段切换需同步
5. **T-01**：Testbench时钟拓扑修正

### 第二优先级（严重影响可靠性）

6. **N-08**：主从握手增加等待确认状态
7. **N-05**：retrain_req改为电平信号，由物理层确认后清除
8. **N-07**：M_FAULT死锁增加恢复机制
9. **R-04**：CDC改用握手协议
10. **N-09**：控制帧数据与脉冲同步

### 第三优先级（功能完善与鲁棒性）

11. **R-03**：lane_align_done在重新BITSLIP时清零
12. **N-06**：deskew_done验证后才置位
13. **N-12**：bitslip_cnt溢出处理
14. **N-13**：lock_match_cnt阈值提高
15. **N-10**：心跳字节序统一

### 第四优先级（代码质量）

16. **R-05**：lane_deskew偏移检测增加found标志
17. **N-11**：延迟校准增加容错
18. **N-14/N-15**：代码健壮性改进
19. **T-02/T-03**：Testbench改进

---

## 8. 总体评价

### 8.1 设计优点

- ✅ 全部6个状态机严格采用三段式设计，结构清晰
- ✅ Xilinx原语使用基本正确（OSERDESE2/ISERDESE2/IDELAYE2/BUFIO/BUFR等）
- ✅ 模块层次划分合理，职责清晰
- ✅ 已有V1报告覆盖了主要原语和FSM问题，修复方向正确

### 8.2 核心问题

**最根本的设计缺陷在于帧协议与3字节通道的时序对齐**（N-01/N-03/R-02）。当前设计将帧字段视为字节流，但3字节/周期的通道使每个状态机周期处理3字节，而帧字段（SOF/TYPE/LEN/PAYLOAD/CHECKSUM）的排布未与3字节边界对齐。这导致收发状态机的字段提取存在系统性错位，**即使所有其他问题修复，帧解析仍会失败**。

**建议**：在修复任何代码之前，先绘制完整的字节级时序图，明确每个clk_div周期中3字节的排布规则，然后重新设计TX帧调度和RX帧解析的字段提取逻辑。

### 8.3 与V1报告对比

V1报告发现了12项问题，方向正确但深度不足：
- 原语检查（§2）详尽准确
- FSM检查（§3）结构正确
- 问题分析（§4）覆盖了下溢、多驱动、CDC等常见问题
- **但遗漏了帧协议时序对齐这一最根本的系统性问题**
- **部分修复（P-01/P-05/P-07/P-11）引入了新的残留缺陷**

**建议**：在V1修复基础上，按本报告§7的优先级顺序修复残留缺陷和新发现问题，并重新进行完整的仿真验证。
