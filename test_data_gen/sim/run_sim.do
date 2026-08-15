# run_sim.do - ModelSim 仿真脚本 for test_data_gen
# 使用方法（在 sim/ 目录）:
#   vsim -c -do run_sim.do
# 或在 ModelSim GUI:  Tools -> Execute Macro -> 选择本文件

# 退出已有仿真
quit -sim

# 创建工作库
if {[file exists work]} {
    vdel -lib work -all
}
vlib work
vmap work work

# 编译 RTL（可配置位宽测试数据发生器）
vlog -work work +acc ../rtl/test_data_gen.v

# 编译 Testbench（含 32/8/64-bit 三种位宽实例化）
vlog -work work +acc ../sim/tb_test_data_gen.v

# 启动仿真（1ns 精度，无需 Xilinx 仿真库）
vsim -t 1ns -L work work.tb_test_data_gen

# 运行仿真直至 $finish
run -all
