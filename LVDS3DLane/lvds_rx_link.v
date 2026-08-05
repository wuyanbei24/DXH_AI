`timescale 1ns / 1ps
//============================================================================
// Module: lvds_rx_link
// Description: 接收端链路层（24bit位宽适配版）
//   - 帧格式：[SOF1|SOF2|TYPE] [LEN|0|0] [DATA...] [CHECKSUM|0|0]
//   - TX保证3字节对齐，SOF1固定在byte0，简化检测逻辑
//   - 数据/心跳/控制帧分流，重训练检测，心跳超时检测
// Source: Xilinx 7系列FPGA双向3路数据LVDS通信设计文档_V2.0  §4.4
//============================================================================
module lvds_rx_link #(
    parameter DATA_WIDTH = 8,
    parameter LANE_CNT   = 3,
    parameter HEARTBEAT_TIMEOUT_CNT = 20'd600000,
    parameter MAX_ERR_CNT = 4'd10
)(
    input  wire clk,
    input  wire rst_n,
    // 物理层输入 (24bit)
    input  wire [LANE_CNT*DATA_WIDTH-1:0] rx_data_in,
    input  wire                            rx_data_valid,
    input  wire                            phy_ready,
    // 用户数据输出 (24bit)
    output reg  [LANE_CNT*DATA_WIDTH-1:0] rx_data_out,
    output reg                            rx_data_out_valid,
    // 控制帧输出
    output reg                    ctrl_frame_valid,
    output reg  [7:0]             ctrl_frame_type,
    output reg  [7:0]             ctrl_frame_payload,
    // 控制与状态
    output reg  retrain_req,
    input  wire retrain_ack,
    output reg  link_up,
    output reg  heartbeat_err,
    output reg  [15:0] heartbeat_recv_cnt
);

// 帧格式定义（TX 3字节对齐）：
// 周期0: byte0=SOF1(0xAA), byte1=SOF2(0x55), byte2=TYPE
// 周期1: byte0=LEN, byte1=0x00, byte2=0x00
// 周期2~N: byte0-2=PAYLOAD（每周期3字节）
// 周期N+1: byte0=CHECKSUM, byte1=0x00, byte2=0x00

localparam F_IDLE     = 3'd0,
           F_LEN      = 3'd1,
           F_PAYLOAD  = 3'd2,
           F_CHECKSUM = 3'd3;
reg [2:0] f_curr_state;
reg [2:0] f_next_state;

reg [7:0] frame_type;
reg [7:0] frame_len;
reg [7:0] payload_cnt;
reg [7:0] checksum_calc;
reg [3:0] frame_err_cnt;
reg [19:0] heartbeat_timer;
reg [3:0]  heartbeat_miss_cnt;

localparam SOF_BYTE1 = 8'hAA;
localparam SOF_BYTE2 = 8'h55;
localparam TYPE_HB   = 8'h10;
localparam TYPE_USR  = 8'h20;

// 帧头检测：TX保证SOF1在byte0, SOF2在byte1（3字节对齐）
wire sof_detected = (rx_data_in[7:0] == SOF_BYTE1 && rx_data_in[15:8] == SOF_BYTE2);

// 帧解析状态机 - 第一段
always @(posedge clk or negedge rst_n) begin
    if(!rst_n)
        f_curr_state <= F_IDLE;
    else if(!phy_ready)
        f_curr_state <= F_IDLE;
    else if(rx_data_valid)
        f_curr_state <= f_next_state;
end

// 第二段：次态跳转
always @(*) begin
    f_next_state = f_curr_state;
    case(f_curr_state)
        F_IDLE:    if(sof_detected) f_next_state = F_LEN;
        F_LEN:     f_next_state = (frame_len == 8'd0) ? F_CHECKSUM : F_PAYLOAD;
        F_PAYLOAD: if(payload_cnt + LANE_CNT >= frame_len) f_next_state = F_CHECKSUM;
        F_CHECKSUM:f_next_state = F_IDLE;
        default:   f_next_state = F_IDLE;
    endcase
end

// 第三段：字段提取与校验
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        frame_type <= 8'd0;
        frame_len <= 8'd0;
        payload_cnt <= 8'd0;
        checksum_calc <= 8'd0;
        rx_data_out <= 24'd0;
        rx_data_out_valid <= 1'b0;
        ctrl_frame_valid <= 1'b0;
        ctrl_frame_type <= 8'd0;
        ctrl_frame_payload <= 8'd0;
        frame_err_cnt <= 4'd0;
        heartbeat_timer <= 20'd0;
        heartbeat_miss_cnt <= 4'd0;
        retrain_req <= 1'b0;
        link_up <= 1'b0;
        heartbeat_err <= 1'b0;
        heartbeat_recv_cnt <= 16'd0;
    end else if(!phy_ready) begin
        frame_type <= 8'd0;
        frame_len <= 8'd0;
        payload_cnt <= 8'd0;
        checksum_calc <= 8'd0;
        rx_data_out_valid <= 1'b0;
        ctrl_frame_valid <= 1'b0;
        frame_err_cnt <= 4'd0;
        heartbeat_timer <= 20'd0;
        heartbeat_miss_cnt <= 4'd0;
        retrain_req <= 1'b0;
        link_up <= 1'b0;
        heartbeat_err <= 1'b0;
    end else if(rx_data_valid) begin
        rx_data_out_valid <= 1'b0;
        ctrl_frame_valid <= 1'b0;
        heartbeat_timer <= heartbeat_timer + 1'b1;

        case(f_curr_state)
            F_IDLE: begin
                if(sof_detected) begin
                    // SOF_TYPE周期: byte0=SOF1, byte1=SOF2, byte2=TYPE
                    frame_type <= rx_data_in[23:16];
                    checksum_calc <= SOF_BYTE1 + SOF_BYTE2 + rx_data_in[23:16];
                    payload_cnt <= 8'd0;
                end
            end

            F_LEN: begin
                // LEN周期: byte0=LEN, byte1=0, byte2=0
                frame_len <= rx_data_in[7:0];
                checksum_calc <= checksum_calc + rx_data_in[7:0];
            end

            F_PAYLOAD: begin
                payload_cnt <= payload_cnt + LANE_CNT;
                checksum_calc <= checksum_calc + rx_data_in[7:0] + rx_data_in[15:8] + rx_data_in[23:16];

                if(frame_type == TYPE_USR) begin
                    rx_data_out <= rx_data_in;
                    rx_data_out_valid <= 1'b1;
                end

                if(frame_type == TYPE_HB) begin
                    // 心跳payload: TX发 {0, cnt[7:0], cnt[15:8]}
                    heartbeat_recv_cnt[15:8] <= rx_data_in[7:0];
                    heartbeat_recv_cnt[7:0]  <= rx_data_in[15:8];
                end

                if(frame_type != TYPE_HB && frame_type != TYPE_USR) begin
                    // 控制帧payload: byte0=payload数据
                    ctrl_frame_payload <= rx_data_in[7:0];
                end
            end

            F_CHECKSUM: begin
                // CHECKSUM周期: byte0=checksum
                if(rx_data_in[7:0] == checksum_calc) begin
                    frame_err_cnt <= 4'd0;
                    if(frame_type == TYPE_HB) begin
                        heartbeat_timer <= 20'd0;
                        heartbeat_miss_cnt <= 4'd0;
                        heartbeat_err <= 1'b0;
                        link_up <= 1'b1;
                    end
                    if(frame_type != TYPE_HB && frame_type != TYPE_USR) begin
                        ctrl_frame_valid <= 1'b1;
                        ctrl_frame_type <= frame_type;
                    end
                end else begin
                    frame_err_cnt <= frame_err_cnt + 1'b1;
                end
                if(frame_err_cnt >= MAX_ERR_CNT) begin
                    retrain_req <= 1'b1;
                end
            end
            default: ;
        endcase

        // 心跳超时检测（含phy_ready=1但无有效帧的场景）
        if(heartbeat_timer >= HEARTBEAT_TIMEOUT_CNT) begin
            heartbeat_timer <= 20'd0;
            heartbeat_miss_cnt <= heartbeat_miss_cnt + 1'b1;
            if(heartbeat_miss_cnt >= 4'd5) begin
                heartbeat_err <= 1'b1;
                retrain_req <= 1'b1;
            end
        end
    end
end

endmodule
