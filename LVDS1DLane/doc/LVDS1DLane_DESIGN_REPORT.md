# LVDS 1-Lane 双向通信设计报告

> **设计定位**：在现有 3-lane 设计（`LVDS3DLane`）基础上，移植出**专用单 lane（1 TX + 1 RX）** LVDS 双向通信设计。按需求**不考虑兼容/参数化设计**——所有逻辑硬编码为 1 路收、1 路发、8bit 并行接口、每拍串行 1 字节。
> **路径**：`F:\wc.prj\pulse_mfpga\src\DXH_AI\LVDS1DLane`

---

## 1. 设计概述

| 项目 | 内容 |
|------|------|
| 平台 | Xilinx 7 系列 FPGA |
| 通道数 | **1 路 LVDS 数据 + 1 路 LVDS 时钟**（收发各一套，master/slave 双 DUT 互连） |
| 串行/并行 | DDR 8:1，串行 400MHz / 并行 100MHz |
| 并行接口 | **8bit（单字节）**，每拍承载 **1 字节** |
| 原语 | ISERDESE2 / OSERDESE2（DDR, 1 例化/路）+ IBUFDS / OBUFDS + IDELAYE2 / IDELAYCTRL |
| 时钟 | `mfpga_clk_ip`（MMCM 行为仿真网表）：`clk_out1_400`（ser 400MHz）、`clk_out4_100`（div 100MHz）、`clk_out6_200`（ref 200MHz） |
| 帧格式 | `SOF1 -> SOF2 -> TYPE -> LEN -> PAYLOAD(1字节/周期) -> CHECKSUM`（逐字节串行） |
| 帧类型 | TYPE_HB=0x10（心跳）、TYPE_USR=0x20（用户数据）、其他=控制帧 |
| 校验和 | 8bit 累加和（SOF1+SOF2+TYPE+LEN+ΣPAYLOAD 字节，逐字节累加） |
| 建链 | 物理层训练（延迟校准 0x55 → 字对齐 0xB5）→ 链路层握手控制帧 → 心跳帧 → link_up |

---

## 2. 文件清单

### 2.1 新建模块（1-lane 专用）
| 文件 | 模块 | 说明 |
|------|------|------|
| `lvds_tx_channel_1lane.v` | `lvds_tx_channel_1lane` | 8bit TX，帧逐字节串行；1×OSERDESE2 数据 + 1×OSERDESE2 时钟 |
| `lvds_rx_link_1lane.v` | `lvds_rx_link_1lane` | 接收链路层：顺序 SOF 检测（F_IDLE→F_SOF2→F_TYPE→F_LEN→F_PAYLOAD→F_CHECKSUM），逐字节校验和 |
| `lvds_rx_phy_1lane.v` | `lvds_rx_phy_1lane` | 接收物理层：1 路 lane_phy，状态机 M_IDLE→M_CALIB→M_LOCK_CHECK→M_NORMAL（**无 deskew**） |
| `lvds_rx_channel_1lane.v` | `lvds_rx_channel_1lane` | 接收通道封装（phy + link，8bit） |
| `lvds_bidirectional_top_1lane.v` | `lvds_bidirectional_top_1lane` | 顶层：例化 TX + RX + link_manager，1 位 LVDS 端口 |
| `lvds_1lane_bidirectional_tb.v` | `lvds_1lane_bidirectional_tb` | 测试平台：master/slave 双 DUT，force 旁路 ISERDESE2，逐字节比对 |
| `regress_1lane.do` | — | 非 GUI 回归脚本（默认优化，不含 `+acc`） |

### 2.2 复用（与 lane 数无关，原样拷贝自 LVDS3DLane）
| 文件 | 模块 | 说明 |
|------|------|------|
| `mfpga_clk_ip.v` / `mfpga_clk_ip_sim_netlist.v` | `mfpga_clk_ip` | MMCM 时钟 IP + 行为仿真网表 |
| `glbl.v` | `glbl` | GSR 全局复位释放 |
| `lvds_rx_lane_phy.v` | `lvds_rx_lane_phy` | 单通道 ISERDESE2 + IDELAY 校准 + BITSLIP 对齐（per-lane，1 例化） |
| `lvds_link_manager.v` | `lvds_link_manager` | 链路管理器（纯 RTL，不感知通道数，握手状态机复用） |

---

## 3. 帧格式（1-lane 逐字节串行视角）

TX 每 100MHz 并行周期发送 **1 字节**，帧按字节流顺序：

| 周期 | 字节 | 说明 |
|------|------|------|
| 0 | 0xAA (SOF1) | 帧头起始 |
| 1 | 0x55 (SOF2) | 帧头 |
| 2 | TYPE | 帧类型 |
| 3 | LEN | 负载字节数 |
| 4 ~ 4+LEN-1 | DATA | 负载，每周期 1 字节 |
| 4+LEN | CHECKSUM | 8bit 累加和 |

**校验和计算**（TX/RX 一致，逐字节累加）：
```
checksum = SOF1(0xAA) + SOF2(0x55) + TYPE + LEN + Σ(每拍 1 字节 PAYLOAD)
```

**各帧类型负载**：
- **TYPE_USR (0x20)**：负载 = FIFO 逐字节读出，`payload_len = fifo_occ_cnt`（8bit FIFO，封顶 MAX_PAYLOAD=255）
- **TYPE_HB (0x10)**：负载 2 字节 = `{HB[15:8], HB[7:0]}`（先高后低），`payload_len = 2`
- **控制帧**（type ≠ HB/USR）：负载 1 字节 = `ctrl_frame_payload`，`payload_len = 1`

---

## 4. 与 3-lane 设计的关键差异（为什么不能只改参数）

3-lane 设计的缺陷（在 LANE_CNT=1 时）全部源于"帧头/SOF/校验和/心跳/多路打包"按 24bit（3 字节）硬编码。1-lane 专用设计从根本上改写为**逐字节串行**：

| 环节 | 3-lane（并行 24bit） | 1-lane（串行 8bit） |
|------|----------------------|---------------------|
| 帧头 | 单字 `{TYPE,0x55,0xAA}` | 3 周期：`SOF1`→`SOF2`→`TYPE` 各 1 字节 |
| SOF 检测 | 同字并行：`byte0==0xAA && byte1==0x55` | 顺序：`F_IDLE`见 0xAA → `F_SOF2`见 0x55 → `F_TYPE`取 TYPE |
| 校验和 | 每字加 3 字节 | 每周期加 1 字节 |
| 用户数据 | 每字 3 字节（FIFO 24bit） | 每周期 1 字节（FIFO 8bit） |
| 心跳 | 16bit 塞 24bit 字（byte0 补 0） | 2 周期：HB[15:8]→HB[7:0] |
| Deskew | 必需（3 路相位对齐） | **无**（单路无通道间偏移，去掉 `lane_deskew`） |
| 物理层打包 | `{lane_data[2],lane_data[1],lane_data[0]}` | 单路 `lane_data` 直出 |

> 注：因采用专用（非参数化）设计，上述差异通过**重写**实现，而非条件编译，逻辑更清晰、无越界风险。

---

## 5. 仿真验证

### 5.1 仿真环境
| 项目 | 内容 |
|------|------|
| 工具 | ModelSim SE-64 10.6d（命令行 `-c` 模式） |
| 测试平台 | `lvds_1lane_bidirectional_tb.v`（master/slave 双 DUT，force 旁路 ISERDESE2） |
| 编译 | `vlog -work work ./*.v`（含 mfpga_clk_ip 仿真网表，vlog-2275 重复定义警告，0 错误） |
| 仿真 | `vsim -c -t ps ... work.lvds_1lane_bidirectional_tb work.glbl`，`run 1200us` |
| 回归脚本 | `regress_1lane.do` |

**关键仿真坑（已规避）**：
- `vsim` **不可**用 `-voptargs="+acc"`：会将 MMCM 时钟网表优化成常数，导致 `clk_out4_100` 冻结、PHY 卡 M_IDLE。用**默认优化**即正常。
- force 旁路在 `clk_out4_100` **下降沿**更新 `iserdes_q`，避免与 RX 采样同沿竞争导致丢字。
- `training_mode` 信号须在 `lvds_rx_phy_1lane` 例化前声明（ModelSim 10.6 对未声明 net 的端口连接会隐式声明，导致重复声明报错 vlog-2388）。

### 5.2 仿真结果
```
编译: Errors: 0, Warnings: 1 (vlog-2275 重复模块, 保留网表版)
帧解析: 29 次 SOF1 检测, 29 次 Frame OK, 0 次 Frame ERR
```

| 时刻 (ps) | 事件 |
|-----------|------|
| 3,020,000 | Scenario 1：双向建链握手测试开始 |
| **115,845,000** | **Bidirectional link established! mst_link_up=1, slv_link_up=1** |
| 117,845,000 | Scenario 2：双向用户数据传输（1-lane, 8bit） |
| **139,850,000** | **Master/Slave RX bytes: 200, errors: 0** |
| 139,850,000 | Scenario 4：正向链路故障重训练（断链 500µs） |
| **639,850,000** | **Forward link retrain recovery success!** |
| 649,850,000 | Scenario 5：外部强制重训练 |
| **812,560,000** | **External force retrain success!** |
| **822,560,000** | **=== All test scenarios completed ===** |

### 5.3 最终统计
```
Master RX: 200 bytes, 0 errors
Slave RX: 200 bytes, 0 errors
Test result: PASS
Errors: 0, Warnings: 4
```

### 5.4 场景覆盖
| 场景 | 内容 | 结果 |
|------|------|------|
| 1 | 双向建链握手 | ✅ link_up @115.8µs |
| 2 | 双向用户数据传输（200×1=200 字节/方向） | ✅ 200 bytes, 0 errors |
| 3 | 通道偏移对齐 | ⚠️ **不适用**（1-lane 无通道间 deskew，已跳过） |
| 4 | 正向链路故障重训练（断链 500µs） | ✅ 恢复 @639.8µs |
| 5 | 外部强制重训练 | ✅ 重训练后重新建链 |

---

## 6. 结论

**设计状态：PASS（1-lane 专用设计功能正确）**

1. **编译**：0 错误（1 个无害重复定义警告）。
2. **建链**：双向握手在 115.8µs 完成。
3. **数据传输**：双向各 200 字节（8bit×200），0 错误，所有帧校验和匹配。
4. **重训练**：链路故障断链 500µs 后成功恢复；外部强制重训练后重新建链。
5. **全场景**：4 个有效场景全部通过，`Test result: PASS`。

1-lane 设计在 `LANE_CNT=1` 约束下正确实现了双向 LVDS 通信，相对于 3-lane 设计删除了 deskew 模块、改为逐字节串行帧，是干净、无参数化兼容负担的专用实现。

---

## 7. 复用/移植经验（供后续参考）

- **时钟 IP**：`mfpga_clk_ip` + `_sim_netlist.v` + `glbl.v` 三件套直接拷贝即可提供行为级 MMCM，无需重新生成。
- **单通道 phy**：`lvds_rx_lane_phy` 与链路管理器 `lvds_link_manager` 与通道数无关，可直接复用。
- **force 旁路**：仿真中必须绕过 ISERDESE2 行为模型的 per-lane skew 限制，直接 force `iserdes_q = 对端TX并行字节`，并在时钟下降沿更新以消除采样竞争。
- **`-voptargs="+acc"` 陷阱**：会使 MMCM 输出变常数，PHY 卡死；务必使用默认优化。
