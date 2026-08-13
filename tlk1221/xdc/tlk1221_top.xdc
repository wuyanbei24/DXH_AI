# ==============================================================================
# tlk1221_top.xdc  --  Xilinx XDC timing constraints for tlk1221_axis_top
# Target : Xilinx Zynq-7020 (xc7z020).  Tool: Vivado 2018.2
# Three clock domains:
#   clk_user   : AXI / 用户逻辑时钟 (来自 PS / MMCM)，典型 125 MHz
#   clk_ref    : TLK1221 发送参考时钟 REFCLK (PL_SFP_CLK)  -> IBUFG -> clk_phy_tx
#   clk_rbc    : TLK1221 接收恢复时钟 RBC0  (PL_SFP_RBC0/1) -> IBUFGDS -> clk_phy_rx
# References:
#   UG974  (XPM FIFO/CDC 用法：异步 FIFO/RAM 必须 set_clock_groups -asynchronous)
#   UG912  (XDC 语法)
#   PG047 / XAPP1112 (1G PCS/PMA，125 MHz 线速率)
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. 时钟定义 (create_clock)
# ------------------------------------------------------------------------------
# (1) 用户侧 AXI 时钟：来自 PS / MMCM，这里按 125 MHz 定义
create_clock -period 8.000 -name clk_user [get_ports clk_user]

# (2) 发送参考时钟 REFCLK (PL_SFP_CLK)，125 MHz（1G 线速率，与 clk_phy_tx 同源）
create_clock -period 8.000 -name clk_ref  [get_ports PL_SFP_CLK]

# (3) 接收恢复时钟 RBC0（差分，经 IBUFGDS -> clk_phy_rx）
#     与 REFCLK 同源但物理异步，频率相同 (125 MHz)，含微小频偏
create_clock -period 8.000 -name clk_rbc  [get_ports PL_SFP_RBC0]

# ------------------------------------------------------------------------------
# 2. 输入 / 输出延迟约束 (set_input_delay / set_output_delay)
# ------------------------------------------------------------------------------
# 发送数据 TD[9:0]：由 clk_phy_tx 域驱动，对链路对侧是源同步输出。
# 以 clk_ref（与 clk_phy_tx 同源）为发射时钟基准，板级走线延迟经验值 ~2 ns（按实际 PCB 调整）。
set_output_delay -clock clk_ref -max  2.5 [get_ports {PL_SFP_TD0 PL_SFP_TD1 PL_SFP_TD2 PL_SFP_TD3 PL_SFP_TD4 PL_SFP_TD5 PL_SFP_TD6 PL_SFP_TD7 PL_SFP_TD8 PL_SFP_TD9}]
set_output_delay -clock clk_ref -min -0.5 [get_ports {PL_SFP_TD0 PL_SFP_TD1 PL_SFP_TD2 PL_SFP_TD3 PL_SFP_TD4 PL_SFP_TD5 PL_SFP_TD6 PL_SFP_TD7 PL_SFP_TD8 PL_SFP_TD9}]

# 接收数据 RD[9:0]：TLK1221 以恢复时钟 clk_rbc 源同步发出（数据居中于周期）。
# 以 clk_rbc 为采样时钟基准设置输入延迟（板级走线延迟经验值 ~2 ns）。
set_input_delay -clock clk_rbc -max  2.5 [get_ports {PL_SFP_RD0 PL_SFP_RD1 PL_SFP_RD2 PL_SFP_RD3 PL_SFP_RD4 PL_SFP_RD5 PL_SFP_RD6 PL_SFP_RD7 PL_SFP_RD8 PL_SFP_RD9}]
set_input_delay -clock clk_rbc -min -0.5 [get_ports {PL_SFP_RD0 PL_SFP_RD1 PL_SFP_RD2 PL_SFP_RD3 PL_SFP_RD4 PL_SFP_RD5 PL_SFP_RD6 PL_SFP_RD7 PL_SFP_RD8 PL_SFP_RD9}]

# 注：PL_SFP_SYNC 为异步状态输入，仅经 3-FF 同步器，不做时序约束（见第 3 节）。

# ------------------------------------------------------------------------------
# 3. 三时钟域异步声明 (set_clock_groups -asynchronous)
# ------------------------------------------------------------------------------
# clk_user / clk_ref / clk_rbc 三者物理上相互独立（PS 时钟 / 本地晶振 / 线路恢复时钟），
# 跨域数据均经 XPM 异步 FIFO（TX: user->phy_tx；RX: phy_rx->user）或 3-FF 同步器
# （PL_SFP_SYNC -> user）处理。必须声明为异步，否则 Vivado 会在异步域之间插入
# 无意义的时序检查并可能误报。UG974 明确要求异步 RAM/FIFO/CDC 必须做此约束。
set_clock_groups -asynchronous \
    -group [get_clocks clk_user] \
    -group [get_clocks clk_ref]  \
    -group [get_clocks clk_rbc]

# ------------------------------------------------------------------------------
# 4. 备注
# ------------------------------------------------------------------------------
# * 恢复时钟差分对另一臂 (PL_SFP_RBC1) 无需单独约束，IBUFGDS 自动关联。
# * 异步复位为“异步释放、同步释放”，无需时序约束。
# * 实际板级走线延迟 (set_input/output_delay 的 2.5 / -0.5 ns) 应依据 PCB
#   时序报告与板厂走线参数微调。
