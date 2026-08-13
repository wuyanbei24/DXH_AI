#=============================================================================
# run_sim.do  —  ModelSim 仿真脚本（AXI4Lite2AXI4ST 桥接设计）
# 说明：
#   本设计使用 Xilinx XPM 宏 xpm_fifo_sync（Vivado 2018.2 提供的行为级源）。
#   仿真时直接从 Vivado 安装目录引用下列 3 个 SystemVerilog 源文件，
#   无需综合/实现，行为级模型即可完整描述 FIFO 功能。
#   修改 VIVADO_XPM 变量指向实际 Vivado 版本目录即可。
#=============================================================================
set VIVADO_XPM "E:/EDA/Xilinx/Vivado/2018.2/data/ip/xpm"

# ---- 0. 准备本地 modelsim.ini（避免写入 ModelSim 安装目录，需写权限）----
#     ModelSim 优先读取当前目录的 modelsim.ini；若缺失则生成一份最小可写配置。
if {[file exists "modelsim.ini"] == 0} {
    set f [open "modelsim.ini" w]
    puts $f "\[Library\]"
    puts $f "work = ./work"
    close $f
}
file attributes "modelsim.ini" -readonly 0

# ---- 1. 建立仿真库（work 映射到本目录 ./work）----
vlib work
vmap work ./work

# ---- 2. 编译 XPM 源（xpm_cdc / xpm_memory / xpm_fifo，顺序无关）----
vlog -sv -work work "$VIVADO_XPM/xpm_cdc/hdl/xpm_cdc.sv"
vlog -sv -work work "$VIVADO_XPM/xpm_memory/hdl/xpm_memory.sv"
vlog -sv -work work "$VIVADO_XPM/xpm_fifo/hdl/xpm_fifo.sv"

# ---- 3. 编译设计 RTL ----
vlog -work work "../rtl/axi4lite2axist.v"
vlog -work work "../rtl/axist2native.v"
vlog -work work "../rtl/axi_lite_stream_bridge.v"

# ---- 4. 编译测试平台 ----
vlog -work work "tb_axi_lite_stream_bridge.v"

# ---- 5. 启动仿真（命令行模式，+acc 开放层级可见性用于 VCD 波形）----
vsim -c -work work -voptargs="+acc" tb_axi_lite_stream_bridge

# ---- 6. 运行至结束（测试平台内 $finish 收尾）----
run -all
quit -f
