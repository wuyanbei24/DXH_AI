# GMII to RGMII IP 使用说明（Xilinx LogiCORE IP）

> 适用平台：Xilinx Zynq-7020（Zynq-7000 SoC，硬核 GEM）
> 开发工具：Xilinx Vivado Design Suite 2018.2
> 参考手册：Xilinx PG160《GMII to RGMII v4.0》（2018-06）

---

## 1. 概述

**GMII to RGMII** 是 Xilinx 提供的桥接 IP，用于在 Zynq-7000 / Zynq UltraScale+ 的
**硬核千兆以太网控制器（GEM，Gigabit Ethernet MAC）** 与 **外部 RGMII PHY** 之间，
将 GEM 输出的 **GMII（8 位并行）** 接口转换为 **RGMII（4 位 DDR）** 接口。

```
   Zynq-7000 SoC 硬核 GEM  ──GMII/MII/MDIO──►  GMII to RGMII IP  ──RGMII/MDIO──►  外部 PHY
   (PS 内 EMIO 引出到 PL)                        (本 IP，在 PL 中实现)              (千兆 PHY 芯片)
```

### 1.1 为什么需要它

- Zynq-7000 的 GEM 通过 **EMIO** 引出的是 **GMII**（千兆）接口；而大多数板载千兆 PHY
  提供的是 **RGMII** 接口（引脚减半、PCB 更简洁）。
- 本 IP 在 PL（可编程逻辑）中实现 GMII→RGMII 的桥接与时序调整（2 ns 时钟偏移、延迟
  对齐），使 GEM 无需 MIO 直连即可使用 RGMII PHY。
- 支持 **10/100/1000 Mb/s 三速**，可在运行时通过 MDIO 动态切换速率。

### 1.2 支持器件

- **Zynq-7000 SoC（含 Zynq-7020）** ✅
- Zynq UltraScale+ MPSoC

### 1.3 版本与费用

- 本手册版本 **v4.0**（2018-06），与 Vivado 2018.2 时代匹配。
- 该 IP 随 Vivado Design Suite 免费提供（遵循 Xilinx End User License）。

---

## 2. 主要特性（Features）

- 三速（10/100/1000 Mb/s）操作。
- 全双工操作。
- 通过 **MDIO** 接口由 MAC（GEM）设置工作速率与双工模式。
- 速率可在运行期间动态切换（改写控制寄存器中的速率位）。
- 支持 GMII 时钟 **内部生成** 或 **外部输入** 两种方式。

---

## 3. 接口与端口描述

### 3.1 顶层连接（Figure 2-1）

- **GMII 侧（连 GEM，经 EMIO）**：`gmii_txd[7:0]`、`gmii_tx_en`、`gmii_tx_er`、
  `gmii_tx_clk`、`gmii_rx_clk`、`gmii_rxd[7:0]`、`gmii_rx_dv`、`gmii_rx_er`、
  `gmii_crs`、`gmii_col`。
- **RGMII 侧（连外部 PHY）**：`rgmii_txd[3:0]`、`rgmii_tx_ctl`、`rgmii_txc`、
  `rgmii_rxd[3:0]`、`rgmii_rx_ctl`、`rgmii_rxc`。
- **MDIO**：`mdio_gem_*`（连 GEM）、`mdio_phy_*`（连外部 PHY），IP 在二者间转发/监听。
- **状态输出**：`link_status`、`clock_speed[1:0]`、`duplex_status`、`speed_mode[1:0]`。

### 3.2 关键 I/O 信号（Table 2-1，节选）

| 信号 | 方向 | 说明 |
|------|------|------|
| `tx_reset` | In | TX 数据通路复位（高有效） |
| `rx_reset` | In | RX 数据通路复位（高有效） |
| `ref_clk` | In | **200 MHz**（Zynq-7000）/ 375 MHz（UltraScale+），用于 IDELAYCTRL 与管理模块 |
| `speed_mode[1:0]` | Out | 线速率指示：00=10M，01=100M，10=1G，11=保留 |
| `gmii_tx_clk` | In | 来自 GEM 的发送时钟：125/25/2.5 MHz（1G/100M/10M） |
| `gmii_tx_clk_90` | In | `gmii_tx_clk` 的 90° 相位版本 |
| `gmii_tx_en` / `gmii_txd[7:0]` / `gmii_tx_er` | In | GMII 发送 |
| `gmii_rx_clk` / `gmii_rx_dv` / `gmii_rxd[7:0]` / `gmii_rx_er` | Out | GMII 接收（送回 GEM） |
| `gmii_crs` / `gmii_col` | Out | 载波侦听 / 冲突（全双工下 GEM 不使用） |
| `mdio_gem_mdc` / `_i` / `_o` / `_t` | — | 连 GEM 的 MDIO |
| `link_status` | Out | 链路状态（来自 RGMII 带内信令）：0=Down，1=Up |
| `clock_speed[1:0]` | Out | 解码得到的链路速率 |
| `duplex_status` | Out | 解码得到的双工：0=半双工，1=全双工 |
| `rgmii_txc` | Out | 发往外部 PHY 的发送时钟 |
| `rgmii_tx_ctl` / `rgmii_txd[3:0]` | Out | RGMII 发送 |
| `rgmii_rxc` | In | 来自外部 PHY 的接收时钟（**必须放在时钟可用管脚**） |
| `rgmii_rx_ctl` / `rgmii_rxd[3:0]` | In | RGMII 接收 |
| `mdio_phy_mdc` / `_i` / `_o` / `_t` | — | 连外部 PHY 的 MDIO |

### 3.3 Block 级端口（Shared Logic 相关，节选）

当选择 **“Include Shared Logic in Core”** 时，顶层为 `<component_name>_block`，
额外提供 `clkin`、`ref_clk_out`、`gmii_clk*`、`gmii_clk_*_out`、
`gmii_clk_*_90*`、`mmcm_locked_out` 等；当选择 **“Include Shared Logic in Example
Design”** 时，这些信号变为 `_in` 形式，连接到 in-core 实例的输出以共享时钟资源。

---

## 4. 时钟方案（重点）

GMII to RGMII 共有三个主要时钟输入：

### 4.1 200 MHz 自由运行时钟（Zynq-7020）

- `ref_clk`（或 block 级 `clkin`）：**Zynq-7000 为 200 MHz**（UltraScale+ 为 375 MHz）。
- 用途：IDELAYCTRL 参考时钟、管理模块时钟；当 GMII 时钟内部生成时，作为 MMCM 输入
  产生各线速 TX 时钟。
- **注意**：MMCM 参数基于 200 MHz（Zynq-7000）设置；若改用其它频率必须手动修改 MMCM。

### 4.2 GMII 发送时钟（TX Clock）

- 由 GEM 经 EMIO 提供，或核心内部由 MMCM 从 200 MHz 生成。
- 通过 VHDL 泛型 **`C_EXTERNAL_CLOCK`** 选择：
  - `C_EXTERNAL_CLOCK = 1`（外部时钟）：GMII 时钟由外部提供，频率需匹配线速——
    1G=125 MHz，100M=25 MHz，10M=2.5 MHz。无需额外时钟资源。
  - `C_EXTERNAL_CLOCK = 0`（内部时钟）：由 MMCM 从 200 MHz 生成 125/25/2.5 MHz。
- `gmii_clk_90` 为 `gmii_clk` 的 90° 相位版本，仅在“通过 MMCM 给 rgmii_txc 加 2 ns
  偏移”选项启用时生成。

### 4.3 RGMII 接收时钟

- `rgmii_rxc` 来自外部 PHY，进入 FPGA 后驱动接收 DDR 采样。该引脚 **必须放置在
  Zynq 的 clock-capable（时钟可用）管脚**。

### 4.4 Shared Logic（共享逻辑）

- 选项决定将时钟/复位/IDELAYCTRL 逻辑放在 **核内（in core）** 还是 **示例设计内
  （in example design）**，由 IP catalog 的 Shared Logic 选项控制（见 Figure 4-2）。
- 多实例共享时钟时：一个核选 in-core（提供 `ref_clk_out` / `gmii_clk*_out` 等），
  其余核选 in-example-design 复用。

---

## 5. 寄存器空间（通过 MDIO 访问）

### 5.1 控制寄存器（Control Register）

- 位宽 **16 位**，地址 **0x10**。
- 由驱动软件通过 **MDIO** 读写，将线速信息告知 IP，使其动态适配速率变化。
- 组合方式与 IEEE 802.3 标准 MDIO 控制寄存器（0x0）类似（见 Table 2-4）。

| 位 | 名称 | 说明 | R/W |
|----|------|------|-----|
| 15 | Reset | 1=复位核与本寄存器（自清零）；0=正常 | R/W |
| 14 | Reserved | 写 0，读忽略 | R/W |
| 13 | Speed Selection (LSB) | 见下方速率编码 | R/W |
| 12:9 | Reserved | 写 0，读忽略 | R/W |
| 8:7 | Reserved | 写 0，读忽略 | R/W |
| 6 | Speed Selection (MSB) | 见下方速率编码 | R/W |
| 5:0 | Reserved | 写 0，读忽略 | R/W |

**速率编码（位 [13] 与 [6] 共同决定）**：
- `00` = 10 Mb/s
- `01` = 100 Mb/s
- `10` = 1000 Mb/s（1 Gb/s）
- `11` = 保留

### 5.2 重要约束

- 驱动软件访问本 IP 的 PHY 地址 **必须区别于外部 PHY 所使用的 PHY 地址**。
- 本 IP 的 PHY 地址由 VHDL 泛型 **`C_PHYADDR`** 设置。
- IP 内部的 Management 模块监听 `mdio_gem_o`：地址匹配时，写周期将数据锁存到控制
  寄存器，读周期将控制寄存器内容送到 `mdio_gem_i`。

---

## 6. Vivado 2018.2 使用流程（Design Flow）

1. 在 **Vivado IP catalog** 中搜索并选中 **GMII to RGMII**。
2. 双击 / 右键 **Customize IP**，主要配置：
   - **Shared Logic**：选择 “Include Shared Logic in Core” 或 “in Example Design”。
   - 时钟来源选择（对应 `C_EXTERNAL_CLOCK`）：GMII 时钟内部/外部生成。
   - PHY 地址（`C_PHYADDR`）：确保与外部 PHY 地址不同。
   - 200 MHz 参考时钟（Zynq-7020）来源。
3. 生成输出产品，在 Block Design 中将其 GMII 侧连到 Zynq PS 的 GEM（EMIO），RGMII
   侧连到外部 PHY 管脚，MDIO 做相应互连。
4. 添加约束（XDC）：RGMII 引脚、`rgmii_rxc` 时钟管脚、200 MHz 输入时钟、时序例外等
   （参考核提供的 XDC 模板）。
5. 仿真（提供演示测试台）→ 综合 → 实现 → 生成比特流。

### 6.1 示例设计结构

- 设计分为 **block 级** 与 **top-level** 两层。
- 若 Shared Logic 在核内，top-level 例化 block 级；否则例化 support 级。
- 示例设计路径（VHDL，随核生成）：
  `<project>/<name>.srcs/sources_1/ip/<component_name>/.../example_design/<component_name>_example_design.vhd`
- 提供两种示例：**内部 GMII 时钟** 与 **外部 GMII 时钟**（见手册 Figure 5-1 / 5-2）。

---

## 7. Zynq-7020 应用注意事项（小结）

- ✅ Zynq-7020 属 Zynq-7000，本 IP 完全支持，专为其硬核 GEM 设计。
- ✅ **参考时钟 `ref_clk`/`clkin` 固定为 200 MHz**（Zynq-7000）；MMCM 参数基于此，
  改动频率须同步修改 MMCM。
- ✅ **`rgmii_rxc` 必须放在 clock-capable 管脚**。
- ⚠️ **`C_PHYADDR` 必须与外部 PHY 的 PHY 地址不同**，否则 MDIO 访问冲突、速率无法
  正确传递。
- ⚠️ **MDIO 不可或缺**：PHY 自协商得到的速率需经 MDIO 通知 GEM（GEM 再写本 IP 控制
  寄存器 0x10），否则无法动态调速。
- ⚠️ GEM 通过 EMIO 将 GMII 引出到 PL，再经本 IP 转 RGMII；需在 Zynq 处理系统配置中
  使能相应 Ethernet 并选择 EMIO 接口。
- ⚠️ 全双工为唯一模式；`gmii_crs` / `gmii_col` 在全双工下 GEM 不使用。

---

## 8. 参考文档

- **PG160** — GMII to RGMII v4.0 (2018-06)，Xilinx Product Guide
  （本工程参考文件：`ref/pg160-gmii-to-rgmii.pdf`）
- Zynq-7000 SoC Technical Reference Manual（GEM 章节）
- Zynq-7000 SoC DC and AC Switching Characteristics (DS187)
- IEEE 802.3-2012 Clauses 22 & 35；RGMII V2.0 规范

> 版本说明：PG160 v4.0 与 Vivado 2018.2 基本同步，手册内容可直接对应 2018.2 中的
> IP 版本；个别选项卡名称以 2018.2 实际界面为准。
