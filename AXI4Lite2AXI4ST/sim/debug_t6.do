# debug_t6.do — 追踪 T6 越界写响应路径（native 发出 vs bridge 捕获）
set VIVADO_XPM "E:/EDA/Xilinx/Vivado/2018.2/data/ip/xpm"
if {[file exists "modelsim.ini"] == 0} {
    set f [open "modelsim.ini" w]
    puts $f "\[Library\]"
    puts $f "work = ./work"
    close $f
}
file attributes "modelsim.ini" -readonly 0
vlib work
vmap work ./work
vlog -sv -work work "$VIVADO_XPM/xpm_cdc/hdl/xpm_cdc.sv"
vlog -sv -work work "$VIVADO_XPM/xpm_memory/hdl/xpm_memory.sv"
vlog -sv -work work "$VIVADO_XPM/xpm_fifo/hdl/xpm_fifo.sv"
vlog -work work "../rtl/axi4lite2axist.v"
vlog -work work "../rtl/axist2native.v"
vlog -work work "../rtl/axi_lite_stream_bridge.v"
vlog +define+DEBUG -work work "tb_axi_lite_stream_bridge.v"
vsim -c -work work -voptargs="+acc" tb_axi_lite_stream_bridge
run 9000ns
quit -f
