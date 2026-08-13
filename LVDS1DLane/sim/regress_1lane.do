# ============================================================
# regress_1lane.do  —  1-lane (LANE_CNT=1) 非GUI回归脚本
# 目录约定:
#   ../rtl/*.v                    所有设计/共用 Verilog 源文件
#                                  (含 mfpga_clk_ip 行为级MMCM网表, glbl.v)
#   ./lvds_1lane_bidirectional_tb.v   测试平台 (仿真文件, 本目录)
# 例化 1 路双向 master/slave DUT, 跑全场景直到打印 Test result。
# 专用 1-lane 设计 (不兼容参数化)。
# 注意: 不要用 -voptargs="+acc", 否则 MMCM 时钟网表被优化成常数导致 PHY 卡死。
# 必须在 sim/ 目录下启动:  cd sim && vsim -c -do regress_1lane.do
# ============================================================
quit -sim
vlib work
vmap work work

# 1) 编译所有设计/共用 RTL (含 glbl.v, mfpga_clk_ip 网表)
vlog -work work ../rtl/*.v

# 2) 编译测试平台; +incdir+../rtl 使 `include "glbl.v" 解析到 rtl/glbl.v
vlog -work work +incdir+../rtl lvds_1lane_bidirectional_tb.v

vsim -c -t ps \
     -L unisims_ver -L secureip -L unimacro_ver -L simprims_ver \
     -L xpm -L unifast -L unifast_ver -L unisim -L unimacro -L xilinx_vip \
     work.lvds_1lane_bidirectional_tb work.glbl

# 全场景：建链 + 传输 + 链路故障重训练 + 外部重训练
# scenario 4 注入 500us 固定等待 + 重训练恢复 + scenario 5, 需 >900us 才能到达 Test result 行
run 1200us
quit -f
