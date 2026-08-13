# debug_probe.tcl — 探测设计内部信号，定位死锁
# 配合 run_sim.do 使用：vsim 加载后 do debug_probe.tcl

when -label probe {rising $now(aclk)} {
    # 每当时钟上升沿打印关键内部信号
    echo [format "T=%0t awready=%b wready=%b bvalid=%b rvalid=%b | cmd_tvalid=%b cmd_tready=%b cmd_tlast=%b | rsp_tvalid=%b rsp_tready=%b rsp_tlast=%b | tx_state=%0d rx_state=%0d nat_state=%0d" \
        [expr {$now/1000.0]] \
        [examine -value /tb_axi_lite_stream_bridge/s_axi_awready] \
        [examine -value /tb_axi_lite_stream_bridge/s_axi_wready] \
        [examine -value /tb_axi_lite_stream_bridge/s_axi_bvalid] \
        [examine -value /tb_axi_lite_stream_bridge/s_axi_rvalid] \
        [examine -value /tb_axi_lite_stream_bridge/DUT/axis_cmd_tvalid] \
        [examine -value /tb_axi_lite_stream_bridge/DUT/axis_cmd_tready] \
        [examine -value /tb_axi_lite_stream_bridge/DUT/axis_cmd_tlast] \
        [examine -value /tb_axi_lite_stream_bridge/DUT/axis_rsp_tvalid] \
        [examine -value /tb_axi_lite_stream_bridge/DUT/axis_rsp_tready] \
        [examine -value /tb_axi_lite_stream_bridge/DUT/axis_rsp_tlast] \
        [examine -value /tb_axi_lite_stream_bridge/DUT/u_axi4lite2axist/tx_state] \
        [examine -value /tb_axi_lite_stream_bridge/DUT/u_axi4lite2axist/rx_state] \
        [examine -value /tb_axi_lite_stream_bridge/DUT/u_axist2native/curr_state] \
    ]
}

run 5000ns
