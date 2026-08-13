# LVDS 3-Lane 双向通信设计 Review 与仿真报告

> **约束声明**：本设计固定 `LANE_CNT = 3`（3 路收 / 3 路发），并行接口位宽 24bit = 3×8bit。所有帧格式、校验和、SOF 检测、deskew 均按 3-lane 并行对齐实现，不考虑 LANE_CNT 可参数化。本报告基于磁盘上现行 RTL（V13）实测得出。

---

## 1. 设计概述

| 项目 | 内容 |
|------|------|
| 平台 | Xilinx 7 系列 FPGA |
| 通道数 | 3 路 LVDS 数据 + 1 路 LVDS 时钟（收发各一套，master/slave 双 DUT 互连） |
| 串行/并行 | DDR 8:1，串行 400MHz / 并行 100MHz |
| 原语 | ISERDESE2 / OSERDESE2（DDR, DATA_WIDTH=8, MASTER 模式）+ OBUFDS / IBUFDS |
| 时钟 | `mfpga_clk_ip`（MMCM 行为仿真网表）：`clk_out6_200`（ser 200MHz→DDR 400MHz）、`clk_out4_100`（div 100MHz） |
| 并行接口 | 24bit（3×8bit），每拍承载 3 字节 |
| 帧格式 | `[SOF1\|SOF2\|TYPE] [LEN\|0\|0] [DATA…] [CHECKSUM\|0\|0]`，3 字节对齐 |
| 帧类型 | TYPE_HB=0x10（心跳）、TYPE_USR=0x20（用户数据）、其他=控制帧（SLAVE_READY/MASTER_ACK/SLAVE_ACK） |
| 校验和 | 8bit 累加和（SOF1+SOF2+TYPE+LEN+ΣPAYLOAD 字节） |
| 建链 | 物理层训练（延迟校准 0x55 → 字对齐 0xB5）→ 链路层握手控制帧 → 心跳帧 → link_up |

---

## 2. 模块清单与层次结构

```
lvds_bidirectional_top          顶层：例化 TX/RX channel + link_manager + clk_ip
├── mfpga_clk_ip                MMCM：200MHz ser / 100MHz div
├── lvds_tx_channel             发送通道（帧调度 + 训练 + 心跳 + FIFO + 3×OSERDESE2）
│   └── xpm_fifo_sync (u_user_fifo)   用户数据 FIFO（24bit, FWFT）
├── lvds_rx_channel             接收通道封装
│   ├── lvds_rx_phy             接收物理层（训练状态机 + deskew 例化 + 3×ISERDESE2）
│   │   ├── lvds_rx_lane_phy ×3  单通道 ISERDESE2 + BITSLIP 对齐
│   │   └── lane_deskew          3 通道 deskew（shift_reg 对齐 + 连续匹配验证）
│   └── lvds_rx_link            接收链路层（帧解析 + 校验和 + 心跳 + 重训练请求）
└── lvds_link_manager           链路管理器（训练握手状态机 → link_all_up）
```

未例化模块：`lvds_rx_pll`（目录中有 `_sim_netlist.v` 但顶层未调用，编译时产生 vlog-2275 重复定义警告，0 错误，不影响仿真）。

---

## 3. 帧格式详述（3-Lane 并行视角）

TX 保证 **3 字节对齐**：每个 100MHz 并行周期承载 3 字节，SOF1 固定在 byte0（lane0）。

| 周期 | byte0 (lane0) | byte1 (lane1) | byte2 (lane2) | 说明 |
|------|---------------|---------------|---------------|------|
| 0 | 0xAA (SOF1) | 0x55 (SOF2) | TYPE | 帧头 |
| 1 | LEN | 0x00 | 0x00 | 负载长度（字节数） |
| 2~N | DATA[0] | DATA[1] | DATA[2] | 负载，每周期 3 字节 |
| N+1 | CHECKSUM | 0x00 | 0x00 | 8bit 累加和 |

**校验和计算**（TX/RX 一致）：
```
checksum = SOF1(0xAA) + SOF2(0x55) + TYPE + LEN + Σ(每拍 3 字节)
```

**各帧类型负载**：
- **TYPE_USR (0x20)**：负载 = FIFO 读出的 24bit 用户数据，每拍 3 字节，`payload_len = fifo_occ_cnt × 3`（封顶 MAX_PAYLOAD=255，向下按 3 取整）
- **TYPE_HB (0x10)**：负载 = `{0x00, heartbeat_cnt[7:0], heartbeat_cnt[15:8]}`，`payload_len = 2`
- **控制帧**（type ≠ HB/USR）：负载 = `{0x00, 0x00, ctrl_frame_payload}`，`payload_len = 1`

---

## 4. 各模块 Review 结论

### 4.1 lvds_tx_channel（发送通道）— ✅ 正确

- **状态机**：`TX_IDLE → TX_SOF_TYPE → TX_LEN → TX_PAYLOAD → TX_CHECKSUM → TX_IDLE`，三段式。
- **训练码生成**：两阶段——阶段0 发 `0x55`（延迟校准，TRAIN_CALIB_DURATION=4000），阶段1 发 `0xB5`（字对齐，TRAIN_ALIGN_DURATION=8000）。
- **FIFO 占用计数**（V13 修复）：自带 `fifo_occ_cnt` 同步计数器替代 XPM `wr_data_count`（本机 XPM 版本该信号恒 0）。写成功 +1、读成功 −1、同时读写净 0。`payload_len = fifo_occ_cnt × 3`。**实测用户数据真实下发，600 字节 0 错误**。
- **心跳**：`HEARTBEAT_CNT_MAX = CLK_FREQ/1000 × HEARTBEAT_MS`（100MHz × 1ms = 100000 周期）周期生成，TYPE_HB 帧发送完成后清 `heartbeat_pending`。
- **重训练同步**：`tx_retrain_req` 上升沿重置 `train_phase_cnt`，确保 TX/RX 同步从阶段0 重启。
- **结论**：帧调度、校验和累加（`fifo_dout[7:0]+[15:8]+[23:16]`）、训练/心跳/控制帧仲裁逻辑均正确，与 3-lane 并行接口匹配。

### 4.2 lvds_rx_link（接收链路层）— ✅ 正确

- **SOF 检测**：并行检测 `rx_data_in[7:0]==0xAA && rx_data_in[15:8]==0x55`（同一并行字内 byte0+byte1），依赖 TX 的 3 字节对齐保证。
- **状态机**：`F_IDLE → F_LEN → F_PAYLOAD → F_CHECKSUM`。
- **F_LEN 次态**（V11 修复）：用 `rx_data_in[7:0]==0`（当前 LEN 字节）而非寄存器 `frame_len` 判定次态，消除上一帧 len 旧值竞争（len=1 控制帧后接 len=0 USR 帧的 1 拍错位）。
- **校验和验证**：F_CHECKSUM 比较 `rx_data_in[7:0] == checksum_calc`，匹配则 `Frame OK`，不匹配则 `frame_err_cnt++`。
- **心跳→link_up**：TYPE_HB 帧校验通过即置 `link_up=1`，清心跳超时计时器。
- **重训练请求**：`frame_err_cnt >= MAX_ERR_CNT(10)` 或心跳连续丢失 5 次 → `retrain_req=1`，保持到 `phy_ready` 下降（V4 LT-09 修复）。
- **结论**：帧解析、校验和、心跳/控制帧分流、重训练触发逻辑均正确。

### 4.3 lvds_rx_phy（接收物理层）— ✅ 正确

- **状态机**：`M_IDLE(0) → M_CALIB(1) → M_BITSLIP(2) → M_NORMAL(4)`，由 `clk_div` 驱动。
  - M_CALIB：等待 3 路均收到 0x55（延迟校准完成）
  - M_BITSLIP：等待 3 路均收到 0xB5（字对齐完成），调用 deskew
  - M_NORMAL：`phy_ready=1`，输出 deskew 后的 24bit 数据
- **lock check**：验证 3 路均为 0xB5 才进 M_NORMAL。
- **data_in 打包**：`{lane_data[2], lane_data[1], lane_data[0]}` 硬编码 3 路拼接（符合 LANE_CNT=3 固定约束）。
- **结论**：训练状态机、3 路 lock 验证、deskew 调用逻辑正确。

### 4.4 lane_deskew（通道偏移对齐）— ✅ 正确

- **机制**：以 lane0 为基准，对 lane1/lane2 用 `shift_reg` 做延迟对齐；连续 15 拍匹配后 `deskew_done=1`。
- **验证**：重校验 `shift_reg[1]/[2]` 与基准匹配 + 连续匹配计数。
- **结论**：3 路 deskew 逻辑正确，Scenario 3（通道偏移对齐测试）实测通过。

### 4.5 lvds_link_manager（链路管理器）— ✅ 正确

- **握手状态机**：`S_IDLE → S_WAIT_SLAVE_READY → S_SEND_MASTER_ACK → S_WAIT_SLAVE_ACK → S_LINK_UP`。
- **link_all_up**：握手完成（收到 SLAVE_READY → 发 MASTER_ACK → 收 SLAVE_ACK）后置位，不依赖心跳。
- **结论**：双向握手状态机正确，master/slave 双方均到达 S_LINK_UP。

### 4.6 lvds_rx_channel / lvds_rx_lane_phy / lvds_bidirectional_top — ✅ 正确

- `lvds_rx_channel`：封装 phy + link，时钟/数据透传，无参数化隐患。
- `lvds_rx_lane_phy`：单通道 ISERDESE2 + BITSLIP 对齐 + 调试打印。
- `lvds_bidirectional_top`：例化 TX/RX channel + link_manager + clk_ip，`link_all_up` 由 link_manager 驱动。

---

## 5. 仿真验证

### 5.1 仿真环境

| 项目 | 内容 |
|------|------|
| 工具 | ModelSim SE-64 10.6d（命令行 `-c` 模式） |
| 测试平台 | `lvds_3lane_bidirectional_tb.v`（master/slave 双 DUT 互连，force 旁路 ISERDESE2） |
| 编译 | `vlog -work work ./*.v`（含 mfpga_clk_ip 仿真网表，提供行为级 MMCM） |
| 仿真 | `vsim -c -t ps ... work.lvds_3lane_bidirectional_tb work.glbl`，`run 1200us` |
| 回归脚本 | `regress_3lane.do` |

### 5.2 编译结果

```
Errors: 0, Warnings: 2（vlog-2275 重复定义：mfpga_clk_ip / lvds_rx_pll 的 .v 与 _sim_netlist.v，ModelSim 保留网表版本，不影响功能）
```

### 5.3 仿真时间线与结果

| 时刻 (ps) | 事件 |
|-----------|------|
| 3,020,000 | Scenario 1：双向建链握手测试开始 |
| 105,980,000 | RX_LINK: Frame OK! type=02 (SLAVE_READY) checksum_match |
| 110,990,000 | RX_LINK: Frame OK! type=02/03 checksum_match |
| 115,990,000 | RX_LINK: Frame OK! type=04 (SLAVE_ACK) checksum_match |
| **116,015,000** | **Bidirectional link established! mst_link_up=1, slv_link_up=1** |
| 118,015,000 | Scenario 2：双向用户数据传输开始 |
| 118,130,000 ~ 120,460,000 | RX_LINK: Frame OK! type=20 (USR) × 多帧，全部 checksum_match |
| **140,020,000** | **Master RX bytes: 600, errors: 0 / Slave RX bytes: 600, errors: 0** |
| ~282,000,000 | 场景3：通道偏移对齐测试（lane1 +1.0ns, lane2 +1.5ns skew 注入） |
| **302,910,000** | **Link established with lane skew! Lane alignment OK**（deskew 恢复对齐） |
| 312,910,000 | Scenario 4：正向链路故障重训练（link_break_m2s=1，断链 500µs） |
| **812,910,000** | **Forward link retrain recovery success!**（断链恢复后重新建链） |
| 822,910,000 | Scenario 5：外部强制重训练（mst/slave ext_retrain 脉冲） |
| 973,150,000 ~ 983,160,000 | RX_LINK: Frame OK! type=02/03/04 checksum_match（重训练后握手帧） |
| **993,090,000** | **=== All test scenarios completed ===** |

### 5.4 最终统计

```
Final statistics:
Master RX: 600 bytes, 0 errors
Slave RX: 600 bytes, 0 errors
Test result: PASS
Errors: 0, Warnings: 0
```

### 5.5 场景覆盖

| 场景 | 内容 | 结果 |
|------|------|------|
| 1 | 双向建链握手 | ✅ link_up @116µs |
| 2 | 双向用户数据传输（200×3=600 字节/方向） | ✅ 600 bytes, 0 errors |
| 3 | 通道偏移对齐（lane skew 注入） | ✅ deskew 恢复 @302µs |
| 4 | 正向链路故障重训练（断链 500µs） | ✅ 恢复 @812µs |
| 5 | 外部强制重训练 | ✅ 重训练后重新建链 |

---

## 6. 关键设计修复历史（现行版本继承）

| 版本 | 修复点 | 说明 |
|------|--------|------|
| V4 | LT-01/LT-05 | TX 重训练请求同步重启训练阶段；retrain_req 保持到 phy_ready 下降 |
| V4 | LT-09 | retrain_req 保持到物理层重启确认 |
| V4 | LT-14 | 心跳超时检测仅在 link_up=1 后启用 |
| V5 | 训练模式控制帧 | train_en=1 时允许控制帧发送（解决握手帧无法传输） |
| V6 | 帧中断修复 | train_en 仅在 TX_IDLE 阻止非控制帧启动，不中断已开始帧 |
| V9 | 用户接口时钟域 | 用户接口改在 clk_out4_100（100MHz）域驱动，避免跨频窄脉冲漏采 |
| V11 | F_LEN 次态竞争 | 用当前 LEN 字节判定次态，消除寄存器旧值 1 拍错位 |
| V13 | FIFO 占用计数 | 自带 fifo_occ_cnt 替代不可靠的 XPM wr_data_count，确保 USR 帧 payload_len 正确 |

---

## 7. 结论

**设计状态：PASS（LANE_CNT=3 固定约束下功能正确）**

1. **编译**：0 错误，2 个无害的重复定义警告。
2. **建链**：双向握手在 116µs 完成，master/slave 均 link_up。
3. **数据传输**：双向各 600 字节用户数据，0 错误，所有帧校验和匹配。
4. **deskew**：通道偏移注入后 deskew 正确恢复对齐。
5. **重训练**：链路故障断链 500µs 后成功恢复；外部强制重训练后重新建链。
6. **全场景**：5 个场景全部通过，`Test result: PASS`。

现行 RTL 在 `LANE_CNT=3` 固定约束下设计正确、仿真通过，无需修改。
