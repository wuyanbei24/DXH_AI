vsim -c -work work -voptargs="+acc" tb_axi_lite_stream_bridge
run 200ns
echo "=== @200ns ==="
examine -value /tb_axi_lite_stream_bridge/s_axi_awready
examine -value /tb_axi_lite_stream_bridge/s_axi_wready
examine -value /tb_axi_lite_stream_bridge/s_axi_bvalid
examine -value /tb_axi_lite_stream_bridge/s_axi_bresp
examine -value /tb_axi_lite_stream_bridge/DUT/axis_cmd_tvalid
examine -value /tb_axi_lite_stream_bridge/DUT/axis_cmd_tready
examine -value /tb_axi_lite_stream_bridge/DUT/axis_cmd_tlast
examine -value /tb_axi_lite_stream_bridge/DUT/axis_cmd_tdata
examine -value /tb_axi_lite_stream_bridge/DUT/u_axi4lite2axist/tx_state
examine -value /tb_axi_lite_stream_bridge/DUT/u_axist2native/curr_state
run 1000ns
echo "=== @1200ns ==="
examine -value /tb_axi_lite_stream_bridge/s_axi_bvalid
examine -value /tb_axi_lite_stream_bridge/DUT/axis_cmd_tvalid
examine -value /tb_axi_lite_stream_bridge/DUT/axis_cmd_tready
examine -value /tb_axi_lite_stream_bridge/DUT/axis_cmd_tdata
examine -value /tb_axi_lite_stream_bridge/DUT/axis_rsp_tvalid
examine -value /tb_axi_lite_stream_bridge/DUT/axis_rsp_tready
examine -value /tb_axi_lite_stream_bridge/DUT/u_axi4lite2axist/tx_state
examine -value /tb_axi_lite_stream_bridge/DUT/u_axist2native/curr_state
quit -f
