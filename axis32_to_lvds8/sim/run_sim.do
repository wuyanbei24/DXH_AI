# run_sim.do - ModelSim 仿真脚本 for axis32_to_lvds8
# 使用方法: vsim -c -do run_sim.do

# 退出已有仿真
quit -sim

# 创建工作库
if {[file exists work]} {
    vdel -lib work -all
}
vlib work
vmap work work

# 编译 RTL
vlog -work work +acc ../rtl/axis32_to_lvds8.v

# 编译 Testbench
vlog -work work +acc ../sim/tb_axis32_to_lvds8.v

# 启动仿真
vsim -t 1ns -L work work.tb_axis32_to_lvds8

# 添加波形（可选，批处理模式不显示）
# add wave -divider "Clock & Reset"
# add wave /tb_axis32_to_lvds8/aclk
# add wave /tb_axis32_to_lvds8/aresetn
# add wave -divider "AXI4-Stream Input"
# add wave -hex /tb_axis32_to_lvds8/s_axis_tdata
# add wave /tb_axis32_to_lvds8/s_axis_tvalid
# add wave /tb_axis32_to_lvds8/s_axis_tlast
# add wave /tb_axis32_to_lvds8/s_axis_tready
# add wave -divider "8-bit Output"
# add wave -hex /tb_axis32_to_lvds8/tx_data
# add wave /tb_axis32_to_lvds8/tx_valid
# add wave /tb_axis32_to_lvds8/tx_ready
# add wave -divider "DUT Internal"
# add wave -hex /tb_axis32_to_lvds8/DUT/curr_state
# add wave -hex /tb_axis32_to_lvds8/DUT/tdata_hold
# add wave /tb_axis32_to_lvds8/DUT/tlast_hold

# 运行仿真
run -all
