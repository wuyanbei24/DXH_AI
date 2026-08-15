# ==============================================================================
# tlk1221_top.xdc  --  Xilinx XDC timing constraints for tlk1221_axis_top
# Target : Xilinx Zynq-7020 (xc7z020).  Tool: Vivado 2018.2
# 时钟拓扑（用户确认 2026-08-15）：
#   clk_user   : 用户/AXI 逻辑时钟 = 100MHz REFCLK 源（顶层 MMCM 生成 -> BUFG 进入本模块）
#               同时作为 clk_phy_tx 驱动 TD[9:0]。FPGA 经 ODDR 将其转发为 PL_SFP_CLK 输出给芯片。
#   clk_rbc    : TLK1221 接收恢复时钟 RBC0（芯片输出给 FPGA，单端全速率），= REFCLK = 100 MHz
#   线速率     : 100MHz REFCLK x10 = 1.0 Gbps（TLK1221 支持 0.6~1.3 Gbps）
# 注意：PL_SFP_CLK 为 FPGA *输出* 的转发时钟，不再对其 create_clock。
# References:
#   UG974  (XPM FIFO/CDC 用法：异步 FIFO/RAM 必须 set_clock_groups -asynchronous)
#   UG912  (XDC 语法)
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. 时钟定义 (create_clock)
# ------------------------------------------------------------------------------
# (1) 用户侧 AXI 时钟 / 发送参考源：clk_user 即 100MHz REFCLK（顶层 MMCM 生成 -> BUFG 进入），
#     同时作为 clk_phy_tx 驱动 TD[9:0]。用户已确认 100 MHz，周期 = 10.0 ns。
#     注：PL_SFP_CLK 是 FPGA 经 ODDR 输出给芯片的 REFCLK（转发时钟），不再是输入时钟，
#         故不再对其 create_clock（由 MMCM/ODDR 自动跟随，TD 输出延迟引用 clk_user 即可）。
create_clock -period 10.000 -name clk_user [get_ports clk_user]

# (2) 接收恢复时钟 RBC0（芯片输出给 FPGA 的恢复时钟，单端 full-rate 模式）。
#     与 REFCLK 同源但物理异步，频率 = REFCLK = 100 MHz（全速率下 RBC0 = REFCLK）。
#     100MHz 全速率 => 线速率 1.0 Gbps（TLK1221 支持 0.6~1.3 Gbps）。
create_clock -period 10.000 -name clk_rbc  [get_ports PL_SFP_RBC0]

# ------------------------------------------------------------------------------
# 2. 输入 / 输出延迟约束 (set_input_delay / set_output_delay)
# ------------------------------------------------------------------------------
# 发送数据 TD[9:0]：由 clk_phy_tx(=clk_user) 域驱动，对链路对侧是源同步输出。
# 以 clk_user 为发射时钟基准，板级走线延迟经验值 ~2 ns（按实际 PCB 调整）。
set_output_delay -clock clk_user -max  2.5 [get_ports {PL_SFP_TD0 PL_SFP_TD1 PL_SFP_TD2 PL_SFP_TD3 PL_SFP_TD4 PL_SFP_TD5 PL_SFP_TD6 PL_SFP_TD7 PL_SFP_TD8 PL_SFP_TD9}]
set_output_delay -clock clk_user -min -0.5 [get_ports {PL_SFP_TD0 PL_SFP_TD1 PL_SFP_TD2 PL_SFP_TD3 PL_SFP_TD4 PL_SFP_TD5 PL_SFP_TD6 PL_SFP_TD7 PL_SFP_TD8 PL_SFP_TD9}]

# 接收数据 RD[9:0]：TLK1221 以恢复时钟 clk_rbc 源同步发出（数据居中于周期）。
# 以 clk_rbc 为采样时钟基准设置输入延迟（板级走线延迟经验值 ~2 ns）。
set_input_delay -clock clk_rbc -max  2.5 [get_ports {PL_SFP_RD0 PL_SFP_RD1 PL_SFP_RD2 PL_SFP_RD3 PL_SFP_RD4 PL_SFP_RD5 PL_SFP_RD6 PL_SFP_RD7 PL_SFP_RD8 PL_SFP_RD9}]
set_input_delay -clock clk_rbc -min -0.5 [get_ports {PL_SFP_RD0 PL_SFP_RD1 PL_SFP_RD2 PL_SFP_RD3 PL_SFP_RD4 PL_SFP_RD5 PL_SFP_RD6 PL_SFP_RD7 PL_SFP_RD8 PL_SFP_RD9}]

# 注：PL_SFP_SYNC 为异步状态输入，仅经 3-FF 同步器，不做时序约束（见第 3 节）。

# ------------------------------------------------------------------------------
# 3. 双时钟域异步声明 (set_clock_groups -asynchronous)
# ------------------------------------------------------------------------------
# clk_user（FPGA 生成的 REFCLK/用户时钟）与 clk_rbc（芯片线路恢复时钟）物理上相互独立，
# 含微小频偏，必须声明为异步；跨域数据经 XPM 异步 FIFO 或 3-FF 同步器处理。
# （PL_SFP_CLK 为输出转发时钟，不再作为独立时钟域。）
set_clock_groups -asynchronous \
    -group [get_clocks clk_user] \
    -group [get_clocks clk_rbc]

# ------------------------------------------------------------------------------
# 4. 备注
# ------------------------------------------------------------------------------
# * 接收恢复时钟采用单端接法（BUFG 直接缓冲 PL_SFP_RBC0），RBC1 在本设计未使用（full-rate 单端模式）。
#   若后续改为差分 RBC0P/RBC0N，应改 IBUFGDS->BUFG 并相应更新此约束。
# * 异步复位为“异步释放、同步释放”，无需时序约束。
# * 实际板级走线延迟 (set_input/output_delay 的 2.5 / -0.5 ns) 应依据 PCB
#   时序报告与板厂走线参数微调。
