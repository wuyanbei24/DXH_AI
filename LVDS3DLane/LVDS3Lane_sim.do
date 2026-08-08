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
vlog -work work ./*.v
vsim -voptargs="+acc" -t ps \
                      -L unisims_ver \
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

add wave -position insertpoint sim:/lvds_3lane_bidirectional_tb/mfpga_clk_ip/*                      
add wave -position insertpoint sim:/lvds_3lane_bidirectional_tb/*
add wave -position insertpoint sim:/lvds_3lane_bidirectional_tb/u_master/*
add wave -position insertpoint sim:/lvds_3lane_bidirectional_tb/u_master/*
add wave -position insertpoint sim:/lvds_3lane_bidirectional_tb/u_master/u_tx/*
add wave -position insertpoint sim:/lvds_3lane_bidirectional_tb/u_master/u_rx/*
add wave -position insertpoint sim:/lvds_3lane_bidirectional_tb/u_master/u_rx/u_phy/*
add wave -position insertpoint sim:/lvds_3lane_bidirectional_tb/u_master/u_rx/u_link/*
add wave -position insertpoint sim:/lvds_3lane_bidirectional_tb/u_master/u_link_mgr/*
add wave -position insertpoint {sim:/lvds_3lane_bidirectional_tb/u_slave/u_rx/u_phy/gen_rx_lanes[0]/u_lane_phy/*}                      
# add wave -position insertpoint {sim:/lvds_3lane_bidirectional_tb/u_master/u_rx/u_phy/gen_rx_lanes[0]/u_lane_phy/u_ibufds_data/*}
# add wave -position insertpoint {sim:/lvds_3lane_bidirectional_tb/u_master/u_rx/u_phy/gen_rx_lanes[0]/u_lane_phy/u_idelay_data/*}
  add wave -position insertpoint {sim:/lvds_3lane_bidirectional_tb/u_master/u_rx/u_phy/gen_rx_lanes[0]/u_lane_phy/u_iserdes_data/*}




radix hex
                                      
log -r /*
                                                                                            
run 200us
#run 260000us


 