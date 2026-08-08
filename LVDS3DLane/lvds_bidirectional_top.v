`timescale 1ns / 1ps
//============================================================================
// Module: lvds_bidirectional_top
// Description: 双向顶层模块
//   - 集成3通道收发与链路管理器，统一时钟分发
//   - 对外提供24bit用户接口与状态输出
//   - [V4修复] LT-07: 使用握制型脉冲同步器替代简单2级FF, 确保多比特数据与脉冲同步到达
// Source: Xilinx 7系列FPGA双向3路数据LVDS通信设计文档_V1.0  §4.7
//============================================================================
module lvds_bidirectional_top #(
    parameter IS_MASTER = 1,
    parameter DATA_WIDTH = 8,
    parameter LANE_CNT   = 3,
    parameter CLK_FREQ = 100_000_000
)(
    input  wire clk_ref,
    input  wire ref_clk_200m,
    input  wire rst_n,
    input  wire clk_ser,
    input  wire clk_div,

    // 发送方向LVDS输出
    output wire tx_lvds_clk_p, output wire tx_lvds_clk_n,
    output wire [LANE_CNT-1:0] tx_lvds_data_p,
    output wire [LANE_CNT-1:0] tx_lvds_data_n,

    // 接收方向LVDS输入
    input  wire rx_lvds_clk_p, input wire rx_lvds_clk_n,
    input  wire [LANE_CNT-1:0] rx_lvds_data_p,
    input  wire [LANE_CNT-1:0] rx_lvds_data_n,

    // 用户数据发送接口（24bit）
    input  wire [LANE_CNT*DATA_WIDTH-1:0]  user_tx_data,
    input  wire                            user_tx_valid,
    output wire                            user_tx_ready,

    // 用户数据接收接口（24bit）
    output wire [LANE_CNT*DATA_WIDTH-1:0] user_rx_data,
    output wire                            user_rx_valid,

    // 状态与控制
    input  wire ext_retrain_req,
    output wire link_all_up,
    output wire heartbeat_err,
    output wire align_err
);

wire tx_train_en;
wire ctrl_frame_send;
wire [7:0] ctrl_frame_type_out;
wire [7:0] ctrl_frame_payload_out;

wire rx_clk_div;
wire rx_phy_ready;
wire rx_link_up;
wire rx_retrain_req;
wire ctrl_frame_valid;
wire [7:0] ctrl_frame_type;
wire [7:0] ctrl_frame_payload;

wire user_tx_en;
wire user_rx_en;
wire rx_valid_raw;
wire tx_retrain_pulse;  // V4: TX重训练脉冲

// ==================================================
// CDC同步：clk_ref域 → clk_div域
// link_manager输出在clk_ref域，TX通道在clk_div域
// [V4修复 LT-07] 使用握制型脉冲同步器替代简单2级FF
// 确保多比特数据总线在脉冲到达时已稳定
// ==================================================
reg tx_train_en_s1, tx_train_en_s2;
reg [7:0] ctrl_frame_type_s1, ctrl_frame_type_s2;
reg [7:0] ctrl_frame_payload_s1, ctrl_frame_payload_s2;
reg user_tx_en_s1, user_tx_en_s2;

// [V4修复 LT-07] 握制型脉冲同步器
// clk_ref域: 请求寄存
reg ctrl_frame_send_req;  // clk_ref域请求标志
reg [7:0] ctrl_frame_type_hold;   // clk_ref域锁存的数据
reg [7:0] ctrl_frame_payload_hold;

// clk_div域: 同步与响应
reg ctrl_frame_send_sync1, ctrl_frame_send_sync2;
reg ctrl_frame_send_sync2_d;
reg ack_sync1, ack_sync2;

wire ctrl_frame_send_sync;
assign ctrl_frame_send_sync = ctrl_frame_send_sync2 & ~ctrl_frame_send_sync2_d;

// clk_ref域: 锁存数据并置请求
always @(posedge clk_ref or negedge rst_n) begin
    if(!rst_n) begin
        ctrl_frame_send_req <= 1'b0;
        ctrl_frame_type_hold <= 8'd0;
        ctrl_frame_payload_hold <= 8'd0;
    end else begin
        if(ctrl_frame_send) begin
            // 脉冲到达时锁存数据并置请求
            ctrl_frame_type_hold <= ctrl_frame_type_out;
            ctrl_frame_payload_hold <= ctrl_frame_payload_out;
            ctrl_frame_send_req <= 1'b1;
        end else if(ack_sync2) begin
            // 收到clk_div域的ACK后清请求
            ctrl_frame_send_req <= 1'b0;
        end
    end
end

// clk_div域: 同步请求, 生成脉冲, 发送ACK
always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n) begin
        ctrl_frame_send_sync1 <= 1'b0;
        ctrl_frame_send_sync2 <= 1'b0;
        ctrl_frame_send_sync2_d <= 1'b0;
        ctrl_frame_type_s1 <= 8'd0;
        ctrl_frame_type_s2 <= 8'd0;
        ctrl_frame_payload_s1 <= 8'd0;
        ctrl_frame_payload_s2 <= 8'd0;
    end else begin
        // 请求信号两级同步
        ctrl_frame_send_sync1 <= ctrl_frame_send_req;
        ctrl_frame_send_sync2 <= ctrl_frame_send_sync1;
        ctrl_frame_send_sync2_d <= ctrl_frame_send_sync2;
        // 数据总线两级同步(数据在请求置位时已锁存, 同步期间稳定)
        ctrl_frame_type_s1 <= ctrl_frame_type_hold;
        ctrl_frame_type_s2 <= ctrl_frame_type_s1;
        ctrl_frame_payload_s1 <= ctrl_frame_payload_hold;
        ctrl_frame_payload_s2 <= ctrl_frame_payload_s1;
    end
end

// clk_div域→clk_ref域: ACK同步
always @(posedge clk_ref or negedge rst_n) begin
    if(!rst_n) begin
        ack_sync1 <= 1'b0;
        ack_sync2 <= 1'b0;
    end else begin
        ack_sync1 <= ctrl_frame_send_sync2;  // clk_div域已采样请求
        ack_sync2 <= ack_sync1;
    end
end

// 电平信号同步
always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n) begin
        tx_train_en_s1 <= 1'b1;  // 复位时保持训练模式
        tx_train_en_s2 <= 1'b1;
        user_tx_en_s1 <= 1'b0;
        user_tx_en_s2 <= 1'b0;
    end else begin
        tx_train_en_s1 <= tx_train_en;
        tx_train_en_s2 <= tx_train_en_s1;
        user_tx_en_s1 <= user_tx_en;
        user_tx_en_s2 <= user_tx_en_s1;
    end
end

// [V4修复 LT-05] tx_retrain_pulse CDC同步 (clk_ref→clk_div)
reg tx_retrain_s1, tx_retrain_s2;
reg tx_retrain_s2_d;
wire tx_retrain_sync;
assign tx_retrain_sync = tx_retrain_s2 & ~tx_retrain_s2_d;

always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n) begin
        tx_retrain_s1 <= 1'b0;
        tx_retrain_s2 <= 1'b0;
        tx_retrain_s2_d <= 1'b0;
    end else begin
        tx_retrain_s1 <= tx_retrain_pulse;
        tx_retrain_s2 <= tx_retrain_s1;
        tx_retrain_s2_d <= tx_retrain_s2;
    end
end

// 发送通道（使用clk_div域同步后信号）
lvds_tx_channel #(
    .DATA_WIDTH(DATA_WIDTH),
    .LANE_CNT(LANE_CNT),
    .CLK_FREQ(CLK_FREQ)
) u_tx (
    .clk_ser(clk_ser), 
    .clk_div(clk_div), 
    .rst_n(rst_n),
    .train_en(tx_train_en_s2),
    .ctrl_frame_send(ctrl_frame_send_sync),
    .ctrl_frame_type(ctrl_frame_type_s2),
    .ctrl_frame_payload(ctrl_frame_payload_s2),
    .tx_retrain_req(tx_retrain_sync),  // V4: TX重训练同步
    .tx_data_in(user_tx_data),
    .tx_data_valid(user_tx_valid & user_tx_en_s2),
    .tx_ready(user_tx_ready),
    .lvds_clk_p(tx_lvds_clk_p),
    .lvds_clk_n(tx_lvds_clk_n),
    .lvds_data_p(tx_lvds_data_p), 
    .lvds_data_n(tx_lvds_data_n)
);

// 接收通道
lvds_rx_channel #(
    .DATA_WIDTH(DATA_WIDTH),
    .LANE_CNT(LANE_CNT)
) u_rx (
    .rst_n(rst_n),
    .lvds_clk_p(rx_lvds_clk_p), 
    .lvds_clk_n(rx_lvds_clk_n),
    .lvds_data_p(rx_lvds_data_p), 
    .lvds_data_n(rx_lvds_data_n),
    .ref_clk_200m(ref_clk_200m),
    .retrain_req(ext_retrain_req | rx_retrain_req),
    .clk_div(rx_clk_div),
    .rx_data_out(user_rx_data),
    .rx_data_valid(rx_valid_raw),
    .ctrl_frame_valid(ctrl_frame_valid),
    .ctrl_frame_type(ctrl_frame_type),
    .ctrl_frame_payload(ctrl_frame_payload),
    .phy_ready(rx_phy_ready),
    .link_up(rx_link_up),
    .heartbeat_err(heartbeat_err),
    .align_err(align_err),
    .retrain_trigger(rx_retrain_req)
);

assign user_rx_valid = rx_valid_raw & user_rx_en;

// 链路管理器
lvds_link_manager #(
    .IS_MASTER(IS_MASTER)
) u_link_mgr (
    .clk(clk_ref), 
    .rst_n(rst_n),
    .rx_phy_ready(rx_phy_ready),
    .rx_link_up(rx_link_up),
    .rx_retrain_req(rx_retrain_req),
    .ctrl_frame_valid(ctrl_frame_valid),
    .ctrl_frame_type(ctrl_frame_type),
    .ctrl_frame_payload(ctrl_frame_payload),
    .tx_train_en(tx_train_en),
    .ctrl_frame_send(ctrl_frame_send),
    .ctrl_frame_type_out(ctrl_frame_type_out),
    .ctrl_frame_payload_out(ctrl_frame_payload_out),
    .user_tx_en(user_tx_en),
    .user_rx_en(user_rx_en),
    .ext_retrain_req(ext_retrain_req),
    .tx_retrain_pulse(tx_retrain_pulse),  // V4: TX重训练脉冲
    .link_all_up(link_all_up)
);

endmodule
