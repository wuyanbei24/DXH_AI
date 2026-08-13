`timescale 1ns / 1ps
//============================================================================
// Module: lvds_rx_link_1lane
// Description: 单路(1-lane) 接收链路层  —  专用 1-lane 设计(不兼容参数化)
//   - 帧格式(逐字节串行): SOF1 -> SOF2 -> TYPE -> LEN -> PAYLOAD(1字节/周期) -> CHECKSUM
//   - TX逐字节对齐, RX用移位序列检测: F_IDLE(见SOF1)->F_SOF2(见SOF2)->F_TYPE->F_LEN->F_PAYLOAD->F_CHECKSUM
//   - 校验和: 每周期累加1字节, 与CHECKSUM字节比较
//   - 心跳16bit: 第0负载字节=HB[15:8], 第1负载字节=HB[7:0]
//   - 重训练检测, 心跳超时检测
// Source: 基于 lvds_rx_link.v(V13, 3-lane并行) 移植为 1-lane 逐字节串行
//============================================================================
module lvds_rx_link_1lane #(
    parameter DATA_WIDTH = 8,
    parameter HEARTBEAT_TIMEOUT_CNT = 20'd600000,
    parameter MAX_ERR_CNT = 4'd10
)(
    input  wire clk,
    input  wire rst_n,
    // 物理层输入 (8bit)
    input  wire [DATA_WIDTH-1:0] rx_data_in,
    input  wire                  rx_data_valid,
    input  wire                  phy_ready,
    // 用户数据输出 (8bit)
    output reg  [DATA_WIDTH-1:0] rx_data_out,
    output reg                   rx_data_out_valid,
    // 控制帧输出
    output reg                   ctrl_frame_valid,
    output reg  [7:0]            ctrl_frame_type,
    output reg  [7:0]            ctrl_frame_payload,
    // 控制与状态
    output reg  retrain_req,
    input  wire retrain_ack,
    output reg  link_up,
    output reg  heartbeat_err,
    output reg  [15:0] heartbeat_recv_cnt
);

// 帧格式定义(逐字节串行):
// 周期0: SOF1(0xAA)
// 周期1: SOF2(0x55)
// 周期2: TYPE
// 周期3: LEN
// 周期4~N: PAYLOAD(每周期1字节)
// 周期N+1: CHECKSUM

localparam F_IDLE     = 3'd0,
           F_SOF2     = 3'd1,
           F_TYPE     = 3'd2,
           F_LEN      = 3'd3,
           F_PAYLOAD  = 3'd4,
           F_CHECKSUM = 3'd5;
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

// SOF1 检测(单字节)
wire sof1_detected = (rx_data_in == SOF_BYTE1);
wire sof2_detected = (rx_data_in == SOF_BYTE2);

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
        F_IDLE:     if(sof1_detected) f_next_state = F_SOF2;
        F_SOF2:     if(sof2_detected) f_next_state = F_TYPE;  // 确认SOF2
        F_TYPE:     f_next_state = F_LEN;
        // [V11修复同款] F_LEN次态用当前LEN字节判定, 避免寄存器旧值竞争
        F_LEN:      f_next_state = (rx_data_in == 8'd0) ? F_CHECKSUM : F_PAYLOAD;
        F_PAYLOAD:  if(payload_cnt + 8'd1 >= frame_len) f_next_state = F_CHECKSUM;
        F_CHECKSUM: f_next_state = F_IDLE;
        default:    f_next_state = F_IDLE;
    endcase
end

// 第三段：字段提取与校验
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
        retrain_req <= 1'b0;   // LT-09: phy_ready下降时清retrain_req
        link_up <= 1'b0;
        heartbeat_err <= 1'b0;
    end else if(rx_data_valid) begin
        rx_data_out_valid <= 1'b0;
        ctrl_frame_valid <= 1'b0;
        if(link_up)
            heartbeat_timer <= heartbeat_timer + 1'b1;
        else
            heartbeat_timer <= 20'd0;

        // V6 Debug: 非训练数据显示
        if(rx_data_in != 8'hB5 && rx_data_in != 8'h55 && rx_data_in != 8'h00) begin
            $display("[%0t] RX_LINK: non-training data=%h state=%0d", $time, rx_data_in, f_curr_state);
        end

        case(f_curr_state)
            F_IDLE: begin
                if(sof1_detected) begin
                    checksum_calc <= SOF_BYTE1;   // 起始校验和
                    payload_cnt <= 8'd0;
                    $display("[%0t] RX_LINK: SOF1 detected! rx_data_in=%h", $time, rx_data_in);
                end
            end
            F_SOF2: begin
                if(sof2_detected) begin
                    checksum_calc <= checksum_calc + SOF_BYTE2;
                end
            end
            F_TYPE: begin
                frame_type <= rx_data_in;
                checksum_calc <= checksum_calc + rx_data_in;
                $display("[%0t] RX_LINK: TYPE captured=%h", $time, rx_data_in);
            end
            F_LEN: begin
                frame_len <= rx_data_in;
                checksum_calc <= checksum_calc + rx_data_in;
            end
            F_PAYLOAD: begin
                payload_cnt <= payload_cnt + 8'd1;
                checksum_calc <= checksum_calc + rx_data_in;

                if(frame_type == TYPE_USR) begin
                    rx_data_out <= rx_data_in;
                    rx_data_out_valid <= 1'b1;
                end
                if(frame_type == TYPE_HB) begin
                    // 第0负载字节=HB[15:8], 第1负载字节=HB[7:0]
                    if(payload_cnt == 8'd0)
                        heartbeat_recv_cnt[15:8] <= rx_data_in;
                    else
                        heartbeat_recv_cnt[7:0]  <= rx_data_in;
                end
                if(frame_type != TYPE_HB && frame_type != TYPE_USR) begin
                    ctrl_frame_payload <= rx_data_in;
                end
            end
            F_CHECKSUM: begin
                if(rx_data_in == checksum_calc) begin
                    frame_err_cnt <= 4'd0;
                    $display("[%0t] RX_LINK: Frame OK! type=%h checksum_match", $time, frame_type);
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
                    $display("[%0t] RX_LINK: Frame ERR! type=%h calc=%h got=%h", $time, frame_type, checksum_calc, rx_data_in);
                end
                // LT-09: retrain_req保持到phy_ready下降, 不在此清零
                if(frame_err_cnt >= MAX_ERR_CNT) begin
                    retrain_req <= 1'b1;
                end
            end
            default: ;
        endcase

        // 心跳超时检测仅link_up=1后启用
        if(link_up && heartbeat_timer >= HEARTBEAT_TIMEOUT_CNT) begin
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
