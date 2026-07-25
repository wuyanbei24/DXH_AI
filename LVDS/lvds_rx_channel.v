`timescale 1ns / 1ps

module lvds_rx_channel #(
    parameter DATA_WIDTH = 8,
    parameter DELAY_STEPS = 32,
    parameter SAMPLE_CNT  = 16,
    parameter MIN_WIN_SIZE= 4,
    parameter HEARTBEAT_TIMEOUT_CNT = 16'd50000,
    parameter MAX_ERR_CNT = 4'd10
)(
    input  wire rst_n,
    
    // LVDS差分输入
    input  wire lvds_clk_p,
    input  wire lvds_clk_n,
    input  wire lvds_data_p,
    input  wire lvds_data_n,
    
    // 重训练控制
    input  wire retrain_req,
    
    // 用户数据输出
    output wire clk_div,
    output wire [DATA_WIDTH-1:0] rx_data_out,
    output wire                    rx_data_valid,
    
    // 控制帧输出
    output wire                    ctrl_frame_valid,
    output wire [7:0]             ctrl_frame_type,
    output wire [7:0]             ctrl_frame_payload,
    
    // 状态输出
    output wire phy_ready,
    output wire link_up,
    output wire heartbeat_err,
    output wire align_err,
    output wire retrain_trigger
);

wire [DATA_WIDTH-1:0] phy_data;
wire phy_valid;
wire retrain_req_inner;

assign retrain_trigger = retrain_req_inner;

lvds_rx_phy #(
    .DATA_WIDTH(DATA_WIDTH), .DELAY_STEPS(DELAY_STEPS),
    .SAMPLE_CNT(SAMPLE_CNT), .MIN_WIN_SIZE(MIN_WIN_SIZE)
) u_phy (
    .rst_n(rst_n),
    .lvds_clk_p(lvds_clk_p), .lvds_clk_n(lvds_clk_n),
    .lvds_data_p(lvds_data_p), .lvds_data_n(lvds_data_n),
    .retrain_req(retrain_req),
    .rx_data(phy_data), .rx_data_valid(phy_valid),
    .phy_ready(phy_ready), .align_err(align_err),
    .best_delay_val(), .clk_div(clk_div)
);

lvds_rx_link #(
    .DATA_WIDTH(DATA_WIDTH),
    .HEARTBEAT_TIMEOUT_CNT(HEARTBEAT_TIMEOUT_CNT),
    .MAX_ERR_CNT(MAX_ERR_CNT)
) u_link (
    .clk(clk_div), .rst_n(rst_n),
    .rx_data_in(phy_data), .rx_data_valid(phy_valid), .phy_ready(phy_ready),
    .rx_data_out(rx_data_out), .rx_data_out_valid(rx_data_valid),
    .retrain_req(retrain_req_inner),
    .link_up(link_up), .heartbeat_err(heartbeat_err),
    .heartbeat_recv_cnt(),
    .ctrl_frame_valid(ctrl_frame_valid),
    .ctrl_frame_type(ctrl_frame_type),
    .ctrl_frame_payload(ctrl_frame_payload)
);

endmodule