# ============================================================
# regress_3lane.do  —  3-lane (LANE_CNT=3) 非GUI回归脚本
# 编译当前目录全部 .v（含 mfpga_clk_ip 仿真网表，提供行为级MMCM），
# 例化 3路双向 master/slave DUT，跑全场景直到打印 Test result。
# 设计固定为 LANE_CNT=3（24bit 并行接口 / 3字节帧对齐）。
# ============================================================
quit -sim
vlib work
vmap work work

# 编译 RTL 源（PHY/链路层/顶层，位于 ../rtl）
vlog -work work ../rtl/*.v
# 编译仿真相关（glbl + tb + 时钟IP仿真网表，位于 sim）
vlog -work work ./*.v

vsim -c -t ps \
     -L unisims_ver -L secureip -L unimacro_ver -L simprims_ver \
     -L xpm -L unifast -L unifast_ver -L unisim -L unimacro -L xilinx_vip \
     work.lvds_3lane_bidirectional_tb work.glbl

# 全场景：建链+传输+偏移对齐+链路故障重训练+外部重训练
# scenario 4 注入 500us 固定等待 + 重训练恢复 + scenario 5，需 >900us 才能到达 Test result 行
run 1200us
quit -f
