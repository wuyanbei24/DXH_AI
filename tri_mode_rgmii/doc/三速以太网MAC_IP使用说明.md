# 三速以太网 MAC IP 使用说明（Tri-Mode Ethernet MAC, TEMAC）

> 适用平台：Xilinx Zynq-7020（Zynq-7000 SoC）
> 开发工具：Xilinx Vivado Design Suite 2018.2
> 参考手册：Xilinx PG051《Tri-Mode Ethernet MAC v9.0》（2022-12）

---

## 1. 概述

三速以太网 MAC（Tri-Mode Ethernet MAC，简称 **TEMAC**）是 Xilinx 提供的经过全验证的
以太网介质访问控制层（MAC）IP，支持 10 Mb/s、100 Mb/s、1000 Mb/s（1 Gb/s）以及
可选的 2.5 Gb/s 速率。本工程使用其 **10/100/1000 Mb/s 三速（Tri-Speed）** 配置，配合
**RGMII** 物理接口连接外部 PHY（典型为千兆 PHY 芯片），在 Zynq-7020 上实现三速以太网
端口。

### 1.1 支持器件

- UltraScale+ 系列、UltraScale 系列
- **Zynq-7000 SoC（含 Zynq-7020）** ✅
- 7 Series（Artix-7 / Kintex-7 / Virtex-7）

> 本工程目标器件 Zynq-7020 属于 Zynq-7000 SoC，且在 7 Series / Zynq-7000 时钟与
> I/O 方案之下，相关实现细节见第 5 章。

### 1.2 支持速率与接口

| 数据速率 | 可选物理接口 |
|---------|-------------|
| 10/100/1000 Mb/s（三速） | GMII、MII、RGMII、Internal（连接 PCS/PMA 或 SGMII） |
| 1 Gb/s（仅千兆） | GMII、RGMII、Internal |
| 2.5 Gb/s | 仅 Internal（GMII 内部接口，无 I/O） |

- **GMII**：IEEE 802.3 clause 35，8 位并行，全速 125 MHz。
- **MII**：IEEE 802.3 clause 22，4 位并行，10/100 Mb/s。
- **RGMII**：GMII 的 DDR（双倍数据率）版本，引脚数减半，是 PCB 设计首选；本工程采用。
- **Internal**：无外部物理接口，直接对接 Xilinx Ethernet 1G/2.5G PCS/PMA 或 SGMII IP（PG047）。

### 1.3 核心架构（功能块）

```
                    AXI4-Stream TX ──► Transmit Engine ──┐
                                                          ├──► Configuration
   AXI4-Lite (配置/状态) ──► AXI4-Lite Wrapper            │
                                                          ├──► Flow Control
                    AXI4-Stream RX ◄── Receive Engine ◄──┘
                                       │
                              Statistics Vector Decode ──► Statistics Counters / Interrupt
                                       │
                              PHY Interface (RGMII/GMII/MII) ──► 外部 PHY
                                       │
                                  MDIO (可选，管理 PHY)
```

要点：
- 用户数据通路通过 **AXI4-Stream** 接口（TX / RX 各一组，8 位数据）与 MAC 交互。
- 配置与状态监控通过 **AXI4-Lite** 接口（可选）；若不启用，则用 **Configuration Vector**
  静态配置。
- 物理侧通过 **RGMII/GMII/MII** 连接外部 PHY。
- **MDIO**（可选）用于管理 PHY 层（读取 PHY 自协商结果、链路状态等）。

---

## 2. 主要特性（Features）

- 符合 IEEE 802.3-2008 规范。
- 可配置半双工 / 全双工（默认仅全双工逻辑，半双工需额外 FPGA 资源）。
- 支持 10/100 Mb/s、1 Gb/s、2.5 Gb/s 或 10/100/1000 Mb/s 多种核。
- 支持 RGMII、GMII、MII，以及通过 transceiver/SelectIO/TBI 连接 Ethernet 1G/2.5G
  PCS/PMA 或 SGMII。
- 可选 **MDIO** 接口管理 PHY 层对象。
- 可选帧过滤器（Frame Filter），可配置查找表项数（最多 16 项）。
- 支持流控帧（Pause）、VLAN 帧、Jumbo 帧，可配置帧间距（IFG）。
- 可选基于优先级的流控（PFC，IEEE 802.1Qbb）。
- 可选 Ethernet AVB Endpoint（IEEE 802.1AS / 1588 / 802.1Qav，需付费 license，且
  仅在 GMII/RGMII、100/1000 Mb/s、全双工下可用）。
- 可选统计计数器（Statistics Counters）。
- 用户侧数据通路使用 **AXI4-Stream**；配置/状态使用 **AXI4-Lite**。

---

## 3. 端口描述（关键端口）

> 以下为核（core level）内部端口。随核提供的示例设计（Verilog/VHDL）会将这些端口
> 通过 IOB 寄存器引出到 FPGA 管脚。

### 3.1 AXI4-Stream 发送接口（Table 2-1，时钟域 tx_mac_aclk）

| 信号 | 方向 | 说明 |
|------|------|------|
| `tx_axis_mac_tdata[7:0]` | In | 待发送的帧数据（8 位） |
| `tx_axis_mac_tvalid` | In | 数据有效指示 |
| `tx_axis_mac_tlast` | In | 帧最后一个字节指示 |
| `tx_axis_mac_tuser` | In | 错误指示（如 FIFO 欠载），通知 MAC 发送错误帧 |
| `tx_axis_mac_tready` | Out | 握手信号；10/100 Mb/s 下用于按正确速率节流数据 |

### 3.2 AXI4-Stream 接收接口（Table 2-5，时钟域 rx_mac_aclk）

| 信号 | 方向 | 说明 |
|------|------|------|
| `rx_axis_mac_tdata[7:0]` | Out | 接收到的帧数据 |
| `rx_axis_mac_tvalid` | Out | 数据有效指示 |
| `rx_axis_mac_tlast` | Out | 帧最后字节指示 |
| `rx_axis_mac_tuser` | Out | 帧结束时的错误指示（高表示坏帧） |

### 3.3 旁路/统计信号（Sideband，同 tx/rx_mac_aclk）

- 发送侧：`tx_ifg_delay[7:0]`、`tx_collision`、`tx_retransmit`、
  `tx_statistics_vector[31:0]`、`tx_statistics_valid`。
- 接收侧：`rx_statistics_vector[27:0]`、`rx_statistics_valid`、
  `rx_axis_filter_tuser[x:0]`（帧过滤器输出）。

### 3.4 时钟、速度指示与复位信号（Table 2-13）

| 信号 | 方向 | 说明 |
|------|------|------|
| `glbl_rstn` | In | 整个核的异步复位，**低有效** |
| `rx_axi_rstn` | In | RX 域复位，低有效 |
| `tx_axi_rstn` | In | TX 域复位，低有效 |
| `rx_reset` | Out | 来自 MAC 的 RX 软件复位（高有效） |
| `tx_reset` | Out | 来自 MAC 的 TX 软件复位（高有效） |
| `gtx_clk` | In | 全局 125 MHz 时钟；2.5 Gb/s 时为 312.5 MHz（RGMII/GMII 使用） |
| `refclk` | In | IDELAYCTRL 参考时钟，200–300 MHz |
| `tx_mac_aclk` | Out | 物理接口发送时钟：1 Gb/s=125 MHz，100 Mb/s=25 MHz，10 Mb/s=2.5 MHz |
| `rx_mac_aclk` | Out | 物理接口接收时钟，频率同上 |
| `speedis100` | Out | 当前为 100 Mb/s 时置位（来自配置位 [13:12]） |
| `speedis10100` | Out | 当前为 10/100 Mb/s 时置位 |

### 3.5 物理接口（RGMII，7 Series / Zynq-7000）

| 信号 | 方向 | 说明 |
|------|------|------|
| `rgmii_txd[3:0]` | Out | 发送数据（DDR） |
| `rgmii_tx_ctl` | Out | 发送控制（DDR） |
| `rgmii_txc` | Out | 发送时钟（由 FPGA 转发，含 2 ns 偏移） |
| `rgmii_rxd[3:0]` | In | 接收数据（DDR） |
| `rgmii_rx_ctl` | In | 接收控制（DDR） |
| `rgmii_rxc` | In | 接收时钟（来自外部 PHY） |

> 若选用 GMII/MII 接口，则对应 `gmii_*` / `mii_*` 信号组（详见手册 Table 2-15/2-17）。

### 3.6 配置向量（Configuration Vector，无 AXI4-Lite 时）

当未启用 Management（AXI4-Lite）接口时，使用配置向量静态配置 MAC：

| 信号 | 方向 | 说明 |
|------|------|------|
| `rx_configuration_vector[79:0]` | In | 替代 RX 配置寄存器（时钟域 rx_mac_aclk） |
| `tx_configuration_vector[79:0]` | In | 替代 TX 配置寄存器（时钟域 tx_mac_aclk） |

- 所有位在输入处被寄存，可视为异步输入。
- **速度选择位 [13:12]**：`00`=10 Mb/s，`01`=100 Mb/s，`10`=1 Gb/s，`11`=保留。
  该位同时驱动 `speedis100` / `speedis10100` 输出。
- 详细位定义见手册 Table 2-27 ~ 2-33。

---

## 4. 配置方式：AXI4-Lite 与 Configuration Vector 的选择

TEMAC 有两种配置途径：

1. **AXI4-Lite Management Interface（推荐用于需运行时调速的设计）**
   - 通过处理器（如 Zynq PS 的 AXI GP 总线）或逻辑动态读写 MAC 配置/状态寄存器。
   - 可同时启用可选 MDIO 接口管理 PHY。
   - 启用 AXI4-Lite 后可使用 AVB 选项。
   - 需关注 `s_axi_aclk` 频率（默认可由工具按连接覆盖）。

2. **Configuration Vector（适用于速率固定、无需处理器的简单设计）**
   - 将速度、双工、流控等参数以常量形式接到 `tx/rx_configuration_vector`，
     上电即固定配置，无需软件参与。
   - 此时 **不** 可用 AVB 选项。
   - 本工程若采用“纯逻辑、速率固定/由外部逻辑切换向量”方案，可省去 AXI 互联。

> 提示：Zynq 平台通常让 PS 通过 AXI-Lite 配置 MAC 并配合 MDIO 读取 PHY 自协商结果，
> 实现上电自动调速；若仅需固定千兆全双工，用配置向量最简单。

---

## 5. 时钟方案（重点：Zynq-7020 / 7 Series / HR I/O）

TEMAC 时钟结构随配置与器件族不同而变化。Zynq-7020 仅含 **HR I/O Bank**（无 HP I/O），
因此 RGMII 物理接口采用 **HR I/O 方案（手册 Figure 3-69）**。

### 5.1 RGMII 发送时钟（HR I/O，Zynq-7020 适用）

- `gtx_clk`：用户提供的 **125 MHz** 全局参考时钟（0° 相位），经 BUFG 进入，作为
  RGMII 数据/控制与 TX AXI4-Stream 的时钟。
- `gtx_clk90`：**125 MHz、90° 相位偏移**时钟，仅用于生成 RGMII 发送时钟 `rgmii_txc`。
- 二者由 **MMCM** 产生（驱动 BUFG）。当选择 **“Include shared logic in core”** 时，
  MMCM 逻辑被包含在核的 `<component_name>_support` 层内；否则需自行在示例中例化。

> **为什么需要 90°？** HR I/O 不含 ODELAY，无法直接对 `rgmii_txc` 加 2 ns 延迟。
> 改用 gtx_clk90（相对数据时钟 90° 相位）作为转发时钟，使 rgmii_txc 落在 RGMII
> 数据有效窗口的中心，满足 RGMII 时序要求（等效 2 ns 偏移）。

### 5.2 RGMII 接收时钟

- `rgmii_rxc` 由外部 PHY 提供，进入 FPGA 后先经 **BUFIO**（最小延迟）喂给输入 IOB
  的 IDDR 采样，再经 **BUFR** 形成区域时钟驱动接收逻辑与 RX AXI4-Stream。
- 接收路径使用 **IDELAY** 元件微调建立/保持时间，延迟值通过 XDC 约束写入（可改）。

### 5.3 IDELAYCTRL

- RGMII（及 GMII）接收逻辑用到 IODELAY，设计中必须例化 **IDELAYCTRL**。
- 若选择 Shared Logic，IDELAYCTRL 已包含在 `<component_name>_support` 内；
  否则需自行例化。
- `refclk`：200–300 MHz，提供给 IDELAYCTRL。

### 5.4 Shared Logic（共享逻辑）

- 选项决定将可共享的时钟/复位/IDELAYCTRL 逻辑放在 **核内（Include in core）** 还是
  **示例设计内（Include in example design）**。
- 多核共享时钟时，通常一个核选 “in core”（提供 `gtx_clk_out` / `gtx_clk90_out` /
  `ref_clk_out`），其余核选 “in example design” 复用这些时钟，全器件共用时钟域，
  但每个核的接收时钟独立（不可共享）。

### 5.5 电压标准（Zynq-7020 HR I/O）

- RGMII：HR I/O 支持 ≤ 2.5 V，HP I/O 仅 ≤ 1.8 V。
- Zynq-7020 仅有 HR I/O Bank，可原生支持 RGMII 常用的 2.5 V，**无需外部电平转换**。
- GMII：HR I/O ≤ 3.3 V；若接多标准 PHY 需留意电平匹配。

---

## 6. 寄存器空间（关键寄存器）

MAC 配置/状态通过 AXI4-Lite 访问，关键寄存器（节选）：

| 寄存器 | 地址（字节） | 说明 |
|--------|-------------|------|
| MAC Speed Configuration | — | 位 [13:12] 选择速率（00/01/10/11），与配置向量对应 |
| Transmitter Configuration | — | 发送使能、巨帧、最大帧长、填充/剥离 FCS 等 |
| Receiver Configuration | — | 接收使能、巨帧、最大帧长、地址过滤等 |
| MDIO Configuration/Address/Write Data/Read Data | — | MDIO 管理 PHY 的寄存器组 |

> 完整寄存器定义、位宽与复位值见手册 Chapter 2 “Register Space”（Table 2-18 起）。
> 若使用配置向量（无 AXI4-Lite），这些配置位改为由 `tx/rx_configuration_vector` 提供。

---

## 7. Vivado 2018.2 使用流程（Design Flow）

1. 在 **Vivado IP catalog** 中搜索并选中 **Tri-Mode Ethernet MAC**（或 10/100/1000
   Mb/s Ethernet MAC）。
2. 双击 IP 或右键 **Customize IP** 打开配置界面，主要选项卡：
   - **Data Rate**：选 “1 Gb/s”（支持 GMII/MII/RGMII/Internal）。本工程三速选含
     tri-speed 的最大速率 1 Gb/s。
   - **Interface（物理接口）**：选 **RGMII**；设置 **MAC Speed** 为三速
     （10/100/1000 Mb/s）。
   - **Management**：默认勾选 **AXI4-Lite**（如需软件调速/状态监控）；若不需要可选
     配置向量（去掉 AXI4-Lite）。勾选 **MDIO**（并在需要时勾选 “Add IO Buffers for
     MDIO”）。
   - **Shared Logic**：选择时钟/IDELAYCTRL 逻辑放在核内还是示例设计内（多核共享时
     见 5.4 节）。
   - **MAC Options**：默认不含半双工（如需半双工勾选；注意 1 Gb/s 半双工在接收路径
     使用 MMCM 控制时钟-数据关系时不被支持）。
   - **Features**：可选帧过滤器、PFC、AVB（AVB 需付费 license 且仅限 GMII/RGMII、
     100/1000、全双工）。
3. 生成输出产品（Generate Output Products），在 BD（Block Design）或 RTL 中例化。
4. 绑定约束（XDC）：RGMII 引脚、时钟、IDELAY 延迟、时序例外等（参考核提供的 XDC
   模板）。
5. 仿真（核提供 VHDL/Verilog 仿真模型与演示测试台）→ 综合 → 实现 → 生成比特流。

---

## 8. Zynq-7020 应用注意事项（小结）

- ✅ Zynq-7020 属 Zynq-7000，TEMAC 完全支持。
- ✅ 仅有 HR I/O Bank，RGMII 直接采用 **gtx_clk + gtx_clk90（MMCM）** 方案，
  2.5 V 电平原生支持，无需电平转换。
- ✅ `rgmii_rxc` 必须放在时钟可用管脚（clock-capable pin），输入路径经 BUFIO/BUFR。
- ⚠️ 多核设计注意时钟共享（一个核 in-core 提供 gtx_clk_out / gtx_clk90_out，其余
  in-example-design 复用）。
- ⚠️ IDELAYCTRL 必须例化（由 Shared Logic 提供或自行例化），并提供 200–300 MHz
  `refclk`。
- ⚠️ 若启用 AXI4-Lite，需规划 PS↔PL 的 AXI 互联与时钟（`s_axi_aclk`）。
- ⚠️ 速率动态切换（10/100/1000）时，需通过 AXI4-Lite 改写速度配置位或通过配置向量
  外部逻辑切换，并配合 MDIO 读取 PHY 自协商结果。

---

## 9. 参考文档

- **PG051** — Tri-Mode Ethernet MAC v9.0 (2022-12)，Xilinx Product Guide
  （本工程参考文件：`ref/pg051-tri-mode-eth-mac.pdf`）
- 7 Series Clocking Resources (UG472)
- Vivado Design Suite User Guide: Designing with IP (UG896)
- Vivado Design Suite User Guide: Designing IP Subsystems using IP Integrator (UG994)

> 版本说明：参考手册为 v9.0（对应较新 Vivado）。Vivado 2018.2 内置的 TEMAC IP 版本
> 略早（约 v7.x/v8.x），但架构、接口、时钟与配置原理一致；个别选项卡名称/默认值以
> 2018.2 实际界面为准。
