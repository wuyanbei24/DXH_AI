# ===================== 前置清场 =====================
quit -sim
# 递归创建sim_lib父目录
file mkdir ../sim_lib
vlib ../sim_lib/work
vmap work ../sim_lib/work

## 修改源文件、testbench文件、IP核的netlist.v
# vlog ../new/*.v
# vlog ../new/nr/*.v
# vlog ./*.v

 
# ===================== 编译设计 =====================
# 兜底timescale，消除IP网表无timescale告警
# 编译顺序：IP网表 → 底层接口 → 业务模块 → 顶层 → Testbench
vlog -work work -timescale "1ps/1ps" ./*.v


vsim -voptargs="+acc" -L unisims_ver \
                      -L secureip \
                      -L unimacro_ver \
                      -L simprims_ver \
                      -L xpm \
                      -L unifast \
                      -L unifast_ver \
                      -L unisim \
                      -L unimacro \
                      -L xilinx_vip \
                      -gui work.lvds_3lane_bidirectional_tb work.glbl
radix hex
                                      
log -r /*
                                                                                            
#run -all
run 260000us


 