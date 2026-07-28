`timescale 1ns / 1ps
//============================================================================
// Module: lvds_rx_channel
// Description: 接收通道顶层
//   - 封装物理层与链路层，对外提供统一24bit接口
// Source: Xilinx 7系列FPGA双向3路数据LVDS通信设计文档_V1.0  §4.5
//============================================================================
module lvds_rx_channel #(
    parameter DATA_WIDTH = 8,
    parameter LANE_CNT   = 3,
    parameter DELAY_STEPS = 32,
    parameter SAMPLE_CNT  = 16,
    parameter MIN_WIN_SIZE= 4,
    parameter HEARTBEAT_TIMEOUT_CNT = 20'd600000,
    parameter MAX_ERR_CNT = 4'd10
)(
    input  wire rst_n,
    // LVDS差分输入
    input  wire lvds_clk_p,
    input  wire lvds_clk_n,
    input  wire [LANE_CNT-1:0] lvds_data_p,
    input  wire [LANE_CNT-1:0] lvds_data_n,
    // IDELAY参考时钟
    input  wire ref_clk_200m,
    // 重训练控制
    input  wire retrain_req,
    // 用户数据输出
    output wire clk_div,
    output wire [LANE_CNT*DATA_WIDTH-1:0] rx_data_out,
    output wire                            rx_data_valid,
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

wire [LANE_CNT*DATA_WIDTH-1:0] phy_data;
wire phy_valid;
wire retrain_req_inner;

assign retrain_trigger = retrain_req_inner;

// retrain_req_inner延迟1拍作为ack，确保物理层有时间响应重训练请求
// retrain_req_inner由link层发出，当phy_ready拉低时确认物理层已响应重训练
wire retrain_ack_from_phy = retrain_req_inner & ~phy_ready;

lvds_rx_phy #(
    .DATA_WIDTH(DATA_WIDTH),
    .LANE_CNT(LANE_CNT),
    .DELAY_STEPS(DELAY_STEPS),
    .SAMPLE_CNT(SAMPLE_CNT),
    .MIN_WIN_SIZE(MIN_WIN_SIZE)
) u_phy (
    .rst_n(rst_n),
    .lvds_clk_p(lvds_clk_p), .lvds_clk_n(lvds_clk_n),
    .lvds_data_p(lvds_data_p), .lvds_data_n(lvds_data_n),
    .ref_clk_200m(ref_clk_200m),
    .retrain_req(retrain_req | retrain_req_inner),
    .rx_data(phy_data), .rx_data_valid(phy_valid),
    .phy_ready(phy_ready), .align_err(align_err),
    .clk_div(clk_div)
);

lvds_rx_link #(
    .DATA_WIDTH(DATA_WIDTH),
    .LANE_CNT(LANE_CNT),
    .HEARTBEAT_TIMEOUT_CNT(HEARTBEAT_TIMEOUT_CNT),
    .MAX_ERR_CNT(MAX_ERR_CNT)
) u_link (
    .clk(clk_div), .rst_n(rst_n),
    .rx_data_in(phy_data), .rx_data_valid(phy_valid), .phy_ready(phy_ready),
    .rx_data_out(rx_data_out), .rx_data_out_valid(rx_data_valid),
    .retrain_req(retrain_req_inner),
    .retrain_ack(retrain_ack_from_phy),
    .link_up(link_up), .heartbeat_err(heartbeat_err),
    .heartbeat_recv_cnt(),
    .ctrl_frame_valid(ctrl_frame_valid),
    .ctrl_frame_type(ctrl_frame_type),
    .ctrl_frame_payload(ctrl_frame_payload)
);

endmodule
