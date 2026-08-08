`timescale 1ns / 1ps

module lvds_bidirectional_top #(
    parameter IS_MASTER = 1,
    parameter DATA_WIDTH = 8,
    parameter CLK_FREQ = 100_000_000
)(
    input  wire clk_ref,
    // 【修正问题3】IDELAY参考时钟（200MHz）
    input  wire ref_clk_200m,
    input  wire rst_n,
    input  wire clk_ser,   // 串行时钟 = 400MHz
    input  wire clk_div,   // 并行时钟 = 100MHz



    // 发送方向：本端→对端
    output wire tx_lvds_clk_p, output wire tx_lvds_clk_n,
    output wire tx_lvds_data_p, output wire tx_lvds_data_n,

    // 接收方向：对端→本端
    input  wire rx_lvds_clk_p, input wire rx_lvds_clk_n,
    input  wire rx_lvds_data_p, input wire rx_lvds_data_n,

    // 用户数据发送接口
    input  wire [DATA_WIDTH-1:0] user_tx_data,
    input  wire                    user_tx_valid,
    output wire                    user_tx_ready,

    // 用户数据接收接口
    output wire [DATA_WIDTH-1:0] user_rx_data,
    output wire                    user_rx_valid,

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

// 【修正问题7】内部wire接收原始valid信号，再用assign门控
wire rx_valid_raw;

// ==================================================
// MMCM 时钟生成（从 tx_channel 移至顶层）
// DDR + DATA_WIDTH=8 要求 CLK(串行) = 4 × CLKDIV(并行)
// 100MHz 并行 → 400MHz 串行 → 800Mbps 数据率
// ==================================================

// wire clk_ser;   // 串行时钟 = 400MHz
// wire clk_div;   // 并行时钟 = 100MHz

// 发送通道
lvds_tx_channel #(
    .DATA_WIDTH(DATA_WIDTH), .CLK_FREQ(CLK_FREQ)
) u_tx (
    .clk_ser(clk_ser), 
    .clk_div(clk_div), 
    .rst_n(rst_n),
    .train_en(tx_train_en),
    .ctrl_frame_send(ctrl_frame_send),
    .ctrl_frame_type(ctrl_frame_type_out),
    .ctrl_frame_payload(ctrl_frame_payload_out),
    .tx_data_in(user_tx_data),
    .tx_data_valid(user_tx_valid & user_tx_en),
    .tx_ready(user_tx_ready),
    .lvds_clk_p(tx_lvds_clk_p), 
    .lvds_clk_n(tx_lvds_clk_n),
    .lvds_data_p(tx_lvds_data_p), 
    .lvds_data_n(tx_lvds_data_n)
);

// 接收通道
// 【修正问题6】retrain_req = ext_retrain_req | rx_retrain_req
// 链路层检测的错误信号回送到物理层，触发重训练
lvds_rx_channel #(
    .DATA_WIDTH(DATA_WIDTH)
) u_rx (
    .rst_n(rst_n),
    .lvds_clk_p(rx_lvds_clk_p), 
    .lvds_clk_n(rx_lvds_clk_n),
    .lvds_data_p(rx_lvds_data_p), 
    .lvds_data_n(rx_lvds_data_n),
    .ref_clk_200m(ref_clk_200m),
    .retrain_req(ext_retrain_req | rx_retrain_req),  // 【修正问题6】
    .clk_div(rx_clk_div),
    .rx_data_out(user_rx_data),
    // 【修正问题7】输出端口连内部wire，不连表达式
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

// 【修正问题7】用assign做门控，不直接在端口连接表达式
assign user_rx_valid = rx_valid_raw & user_rx_en;

// 链路管理器
lvds_link_manager #(
    .IS_MASTER(IS_MASTER)
) u_link_mgr (
    .clk(clk_ref), .rst_n(rst_n),
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
    .link_all_up(link_all_up)
);

endmodule
