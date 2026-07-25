`timescale 1ns / 1ps

module lvds_rx_link #(
    parameter DATA_WIDTH = 8,
    // 【修正问题15】心跳超时阈值 = 心跳周期(1ms) × 6 = 6ms
    // 100MHz下 6ms = 600000 周期
    parameter HEARTBEAT_TIMEOUT_CNT = 20'd600000,
    parameter MAX_ERR_CNT = 4'd10
)(
    input  wire clk,
    input  wire rst_n,

    // 物理层输入
    input  wire [DATA_WIDTH-1:0] rx_data_in,
    input  wire                    rx_data_valid,
    input  wire                    phy_ready,

    // 用户数据输出
    output reg  [DATA_WIDTH-1:0] rx_data_out,
    output reg                    rx_data_out_valid,

    // 控制帧输出
    output reg                    ctrl_frame_valid,
    output reg  [7:0]             ctrl_frame_type,
    output reg  [7:0]             ctrl_frame_payload,

    // 控制与状态
    // 【修正问题10】retrain_req改为电平信号，持续拉高直到被外部清除
    output reg  retrain_req,
    input  wire retrain_ack,       // 上游确认后清除retrain_req
    output reg  link_up,
    output reg  heartbeat_err,
    output reg  [15:0] heartbeat_recv_cnt
);

// ==================================================
// 【修正问题18】帧解析状态机 — 合并F_DONE到F_CHECKSUM
// ==================================================
localparam F_IDLE     = 3'd0,
           F_SOF1     = 3'd1,
           F_SOF2     = 3'd2,
           F_TYPE     = 3'd3,
           F_LEN      = 3'd4,
           F_PAYLOAD  = 3'd5,
           F_CHECKSUM = 3'd6;

reg [2:0] f_curr_state;
reg [2:0] f_next_state;

// 内部信号
reg [7:0] frame_type;
reg [7:0] frame_len;
reg [7:0] payload_cnt;
reg [7:0] checksum_calc;
// 【修正问题17】连续错误计数（中间一次正确即清零）
reg [3:0] frame_err_cnt;

// 【修正问题15】心跳超时计数器位宽增大
reg [19:0] heartbeat_timer;
reg [3:0]  heartbeat_miss_cnt;

localparam SOF_BYTE1 = 8'hAA;
localparam SOF_BYTE2 = 8'h55;
localparam TYPE_HB   = 8'h10;
localparam TYPE_USR  = 8'h20;

// 帧解析状态机 - 三段式
always @(posedge clk or negedge rst_n) begin
    if(!rst_n)
        f_curr_state <= F_IDLE;
    else if(phy_ready && rx_data_valid)
        f_curr_state <= f_next_state;
end

always @(*) begin
    f_next_state = f_curr_state;
    case(f_curr_state)
        F_IDLE: if(rx_data_in == SOF_BYTE1) f_next_state = F_SOF1;
        F_SOF1: f_next_state = (rx_data_in == SOF_BYTE2) ? F_SOF2 : F_IDLE;
        F_SOF2: f_next_state = F_TYPE;
        F_TYPE: f_next_state = F_LEN;
        F_LEN:  f_next_state = (frame_len == 8'd0) ? F_CHECKSUM : F_PAYLOAD;
        F_PAYLOAD: if(payload_cnt >= frame_len - 1'b1) f_next_state = F_CHECKSUM;
        // 【修正问题18】F_CHECKSUM直接回到F_IDLE，不再经过F_DONE
        F_CHECKSUM: f_next_state = F_IDLE;
        default: f_next_state = F_IDLE;
    endcase
end

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        frame_type <= 8'd0;
        frame_len <= 8'd0;
        payload_cnt <= 8'd0;
        checksum_calc <= 8'd0;
        rx_data_out <= 8'd0;
        rx_data_out_valid <= 1'b0;
        ctrl_frame_valid <= 1'b0;
        ctrl_frame_type <= 8'd0;
        ctrl_frame_payload <= 8'd0;
        frame_err_cnt <= 4'd0;
        heartbeat_recv_cnt <= 16'd0;
        heartbeat_timer <= 20'd0;
        heartbeat_miss_cnt <= 4'd0;
        retrain_req <= 1'b0;
        link_up <= 1'b0;
        heartbeat_err <= 1'b0;
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
                checksum_calc <= rx_data_in;
                payload_cnt <= 8'd0;
            end

            F_SOF1: checksum_calc <= checksum_calc + rx_data_in;

            F_SOF2: begin
                frame_type <= rx_data_in;
                checksum_calc <= checksum_calc + rx_data_in;
            end

            F_TYPE: begin
                frame_len <= rx_data_in;
                checksum_calc <= checksum_calc + rx_data_in;
                payload_cnt <= 8'd0;
            end

            // 【修正问题11】frame_len=0时，F_LEN状态的rx_data_in就是Checksum字节
            // 但状态机此时跳转到F_CHECKSUM，F_CHECKSUM消费的是下一字节
            // 因此frame_len=0时需要在F_LEN状态直接比对Checksum
            F_LEN: begin
                if(frame_len != 8'd0) begin
                    payload_cnt <= payload_cnt + 1'b1;
                    checksum_calc <= checksum_calc + rx_data_in;

                    case(frame_type)
                        TYPE_USR: begin
                            rx_data_out <= rx_data_in;
                            rx_data_out_valid <= 1'b1;
                        end
                        TYPE_HB: begin
                            if(payload_cnt == 8'd0) heartbeat_recv_cnt[15:8] <= rx_data_in;
                            else heartbeat_recv_cnt[7:0] <= rx_data_in;
                        end
                        default: begin
                            ctrl_frame_payload <= rx_data_in;
                        end
                    endcase
                end else begin
                    // frame_len==0: 当前rx_data_in是Checksum字节，直接比对
                    if(rx_data_in == checksum_calc) begin
                        frame_err_cnt <= 4'd0;
                        // 控制帧输出（无payload的控制帧）
                        if(frame_type != TYPE_HB && frame_type != TYPE_USR) begin
                            ctrl_frame_valid <= 1'b1;
                            ctrl_frame_type <= frame_type;
                        end
                    end else begin
                        frame_err_cnt <= frame_err_cnt + 1'b1;
                    end
                end
            end

            F_PAYLOAD: begin
                payload_cnt <= payload_cnt + 1'b1;
                checksum_calc <= checksum_calc + rx_data_in;

                case(frame_type)
                    TYPE_USR: begin
                        rx_data_out <= rx_data_in;
                        rx_data_out_valid <= 1'b1;
                    end
                    TYPE_HB: begin
                        if(payload_cnt == 8'd0) heartbeat_recv_cnt[15:8] <= rx_data_in;
                        else heartbeat_recv_cnt[7:0] <= rx_data_in;
                    end
                    default: begin
                        ctrl_frame_payload <= rx_data_in;
                    end
                endcase
            end

            // 【修正问题18】F_CHECKSUM合并了原F_DONE的功能
            F_CHECKSUM: begin
                if(rx_data_in == checksum_calc) begin
                    frame_err_cnt <= 4'd0;
                    if(frame_type == TYPE_HB) begin
                        heartbeat_timer <= 20'd0;
                        heartbeat_miss_cnt <= 4'd0;
                        heartbeat_err <= 1'b0;
                        link_up <= 1'b1;
                    end
                    // 控制帧输出脉冲
                    if(frame_type != TYPE_HB && frame_type != TYPE_USR) begin
                        ctrl_frame_valid <= 1'b1;
                        ctrl_frame_type <= frame_type;
                    end
                end else begin
                    // 【修正问题17】连续错误计数，中间一次正确即清零
                    frame_err_cnt <= frame_err_cnt + 1'b1;
                end
                // 【修正问题17】连续10帧校验错误触发重训练
                if(frame_err_cnt >= MAX_ERR_CNT) begin
                    // 【修正问题10】retrain_req置为电平信号，持续拉高
                    retrain_req <= 1'b1;
                end
            end

            default: ;
        endcase

        // 【修正问题15】心跳超时检测（超时阈值=6倍心跳周期）
        if(heartbeat_timer >= HEARTBEAT_TIMEOUT_CNT) begin
            heartbeat_timer <= 20'd0;
            heartbeat_miss_cnt <= heartbeat_miss_cnt + 1'b1;
            if(heartbeat_miss_cnt >= 4'd5) begin
                heartbeat_err <= 1'b1;
                // 【修正问题10】retrain_req电平信号
                retrain_req <= 1'b1;
            end
        end
    end

    // 【修正问题10】retrain_req电平清除：上游确认后清除
    if(retrain_ack) retrain_req <= 1'b0;
end

endmodule
