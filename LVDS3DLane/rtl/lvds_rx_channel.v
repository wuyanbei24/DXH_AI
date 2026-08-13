`timescale 1ns / 1ps
//============================================================================
// Module: lvds_rx_channel
// Description: 接收通道顶层
//   - 封装物理层与链路层，对外提供统一24bit接口
//   - [V4修复] LT-09: retrain_ack等待phy_ready下降后重新上升, 确认物理层已重启
// Source: Xilinx 7系列FPGA双向3路数据LVDS通信设计文档_V1.0  §4.5
//============================================================================
module lvds_rx_channel #(
    parameter DATA_WIDTH = 8,
    parameter LANE_CNT   = 3,
    parameter DELAY_STEPS = 32,
    parameter SAMPLE_CNT  = 16,
    parameter MIN_WIN_SIZE= 4,
    parameter HEARTBEAT_TIMEOUT_CNT = 20'd600000,
    parameter MAX_ERR_CNT = 4'd10,
    parameter SIM_BYPASS  = 0  // V8: 仿真旁路BUFIO/BUFR
)(
    input  wire rst_n,
    // LVDS差分输入
    input  wire lvds_clk_p,
    input  wire lvds_clk_n,
    input  wire [LANE_CNT-1:0] lvds_data_p,
    input  wire [LANE_CNT-1:0] lvds_data_n,
    // IDELAY参考时钟
    input  wire ref_clk_200m,
    // V8: 仿真旁路时钟输入
    input  wire clk_ser_ext,  // SIM_BYPASS=1: TX同源400MHz
    input  wire clk_div_ext,  // SIM_BYPASS=1: TX同源100MHz
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
wire heartbeat_err_inner;

assign retrain_trigger = retrain_req_inner;
assign heartbeat_err = heartbeat_err_inner;

// [V4修复 LT-09] retrain_ack等待phy_ready下降后重新上升
// 确认物理层已完全重启并重新进入校准状态
// 原设计: retrain_req_inner & ~phy_ready (过早清除, 仅3-4周期)
// 新设计: 检测phy_ready的下降-上升序列, 确保物理层已重启
reg phy_ready_d;
reg retrain_ack_pending;

always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n) begin
        phy_ready_d <= 1'b0;
        retrain_ack_pending <= 1'b0;
    end else begin
        phy_ready_d <= phy_ready;
        if(retrain_req_inner && phy_ready && ~phy_ready_d)
            retrain_ack_pending <= 1'b1;  // V4: phy_ready下降, 开始等待重启
        else if(retrain_ack_pending && phy_ready)
            retrain_ack_pending <= 1'b0;  // V4: phy_ready重新上升, 确认重启完成
    end
end

// retrain_ack: 等待phy_ready重新上升后才确认
wire retrain_ack_from_phy = retrain_ack_pending && phy_ready;

lvds_rx_phy #(
    .DATA_WIDTH(DATA_WIDTH),
    .LANE_CNT(LANE_CNT),
    .DELAY_STEPS(DELAY_STEPS),
    .SAMPLE_CNT(SAMPLE_CNT),
    .MIN_WIN_SIZE(MIN_WIN_SIZE),
    .SIM_BYPASS(SIM_BYPASS)  // V8: 传递仿真旁路参数
) u_phy (
    .rst_n(rst_n),
    .lvds_clk_p(lvds_clk_p), .lvds_clk_n(lvds_clk_n),
    .lvds_data_p(lvds_data_p), .lvds_data_n(lvds_data_n),
    .ref_clk_200m(ref_clk_200m),
    .retrain_req(retrain_req | retrain_req_inner),
    .heartbeat_err(heartbeat_err_inner),
    .clk_ser_ext(clk_ser_ext),  // V8: TX同源时钟
    .clk_div_ext(clk_div_ext),  // V8: TX同源时钟
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
    .link_up(link_up), .heartbeat_err(heartbeat_err_inner),
    .heartbeat_recv_cnt(),
    .ctrl_frame_valid(ctrl_frame_valid),
    .ctrl_frame_type(ctrl_frame_type),
    .ctrl_frame_payload(ctrl_frame_payload)
);

endmodule
