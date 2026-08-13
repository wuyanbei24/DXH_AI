`timescale 1ns / 1ps
//============================================================================
// Module: lvds_rx_channel_1lane
// Description: 单路(1-lane) 接收通道顶层  —  专用 1-lane 设计(不兼容参数化)
//   - 封装物理层(lvds_rx_phy_1lane)与链路层(lvds_rx_link_1lane), 对外提供统一8bit接口
//   - [V4修复] LT-09: retrain_ack等待phy_ready下降后重新上升
//============================================================================
module lvds_rx_channel_1lane #(
    parameter DATA_WIDTH = 8,
    parameter DELAY_STEPS = 32,
    parameter SAMPLE_CNT  = 16,
    parameter MIN_WIN_SIZE= 4,
    parameter HEARTBEAT_TIMEOUT_CNT = 20'd600000,
    parameter MAX_ERR_CNT = 4'd10,
    parameter SIM_BYPASS  = 0
)(
    input  wire rst_n,
    // LVDS差分输入
    input  wire lvds_clk_p,
    input  wire lvds_clk_n,
    input  wire lvds_data_p,
    input  wire lvds_data_n,
    // IDELAY参考时钟
    input  wire ref_clk_200m,
    // 仿真旁路时钟输入
    input  wire clk_ser_ext,
    input  wire clk_div_ext,
    // 重训练控制
    input  wire retrain_req,
    // 用户数据输出
    output wire clk_div,
    output wire [DATA_WIDTH-1:0] rx_data_out,
    output wire                  rx_data_valid,
    // 控制帧输出
    output wire                  ctrl_frame_valid,
    output wire [7:0]            ctrl_frame_type,
    output wire [7:0]            ctrl_frame_payload,
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
wire heartbeat_err_inner;

assign retrain_trigger = retrain_req_inner;
assign heartbeat_err = heartbeat_err_inner;

// [V4修复 LT-09] retrain_ack等待phy_ready重新上升后才确认
reg phy_ready_d;
reg retrain_ack_pending;

always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n) begin
        phy_ready_d <= 1'b0;
        retrain_ack_pending <= 1'b0;
    end else begin
        phy_ready_d <= phy_ready;
        if(retrain_req_inner && phy_ready && ~phy_ready_d)
            retrain_ack_pending <= 1'b1;
        else if(retrain_ack_pending && phy_ready)
            retrain_ack_pending <= 1'b0;
    end
end

wire retrain_ack_from_phy = retrain_ack_pending && phy_ready;

lvds_rx_phy_1lane #(
    .DATA_WIDTH(DATA_WIDTH),
    .DELAY_STEPS(DELAY_STEPS),
    .SAMPLE_CNT(SAMPLE_CNT),
    .MIN_WIN_SIZE(MIN_WIN_SIZE),
    .SIM_BYPASS(SIM_BYPASS)
) u_phy (
    .rst_n(rst_n),
    .lvds_clk_p(lvds_clk_p), .lvds_clk_n(lvds_clk_n),
    .lvds_data_p(lvds_data_p), .lvds_data_n(lvds_data_n),
    .ref_clk_200m(ref_clk_200m),
    .retrain_req(retrain_req | retrain_req_inner),
    .heartbeat_err(heartbeat_err_inner),
    .clk_ser_ext(clk_ser_ext),
    .clk_div_ext(clk_div_ext),
    .rx_data(phy_data), .rx_data_valid(phy_valid),
    .phy_ready(phy_ready), .align_err(align_err),
    .clk_div(clk_div)
);

lvds_rx_link_1lane #(
    .DATA_WIDTH(DATA_WIDTH),
    .HEARTBEAT_TIMEOUT_CNT(HEARTBEAT_TIMEOUT_CNT),
    .MAX_ERR_CNT(MAX_ERR_CNT)
) u_link (
    .clk(clk_div), .rst_n(rst_n),
    .rx_data_in(phy_data), .rx_data_valid(phy_valid), .phy_ready(phy_ready),
    .rx_data_out(rx_data_out), .rx_data_out_valid(rx_data_valid),
    .retrain_req(retrain_req_inner),
    .retrain_ack(retrain_ack_from_phy),
    .link_up(link_up), .heartbeat_err(heartbeat_err_inner),
    .heartbeat_recv_cnt(),
    .ctrl_frame_valid(ctrl_frame_valid),
    .ctrl_frame_type(ctrl_frame_type),
    .ctrl_frame_payload(ctrl_frame_payload)
);

endmodule
