`timescale 1ns / 1ps
//============================================================================
// Module: lvds_link_manager
// Description: 链路管理模块（与V4单路版完全复用）
//   - 主/从模式可配置，控制训练流程、处理握手帧
//   - 管理用户数据使能、联动双向重训练，含跨时钟域同步
//   - 纯RTL逻辑，无Xilinx原语依赖，不感知底层通道数量
//   - [V4修复] LT-04: 增加SLAVE_ACK反向确认, 主机等待从机确认后才进LINK_UP
//   - [V4修复] LT-05: 增加tx_retrain_pulse输出, 同步TX/RX重训练
//   - [V4修复] LT-14: link_all_up仅在S_LINK_UP状态置位, 心跳超时仅在link_up后启用
//   - [V4修复] LT-15: 使用generate-if替代if(IS_MASTER)组合逻辑
// Source: Xilinx 7系列FPGA双向3路数据LVDS通信设计文档_V1.0  §4.6
//============================================================================
module lvds_link_manager #(
    parameter IS_MASTER = 1  // 1=主机模式，0=从机模式
)(
    input  wire clk,       // 本地参考时钟(clk_ref)
    input  wire rst_n,

    // 接收通道状态（来自clk_div域，需CDC同步）
    input  wire rx_phy_ready,
    input  wire rx_link_up,
    input  wire rx_retrain_req,
    input  wire ctrl_frame_valid,
    input  wire [7:0] ctrl_frame_type,
    input  wire [7:0] ctrl_frame_payload,

    // 发送通道控制
    output reg  tx_train_en,
    output reg  ctrl_frame_send,
    output reg  [7:0] ctrl_frame_type_out,
    output reg  [7:0] ctrl_frame_payload_out,

    // 用户数据使能
    output reg  user_tx_en,
    output reg  user_rx_en,

    // 外部控制
    input  wire ext_retrain_req,
    // [V4修复 LT-05] TX重训练脉冲, 通知TX通道重启训练
    output reg  tx_retrain_pulse,
    output reg  link_all_up
);

// ==================================================
// 跨时钟域两级同步器
// 所有来自clk_div域的信号经两级触发器同步到clk_ref域
// ==================================================
reg rx_phy_ready_sync1, rx_phy_ready_sync2;
reg rx_link_up_sync1, rx_link_up_sync2;
reg rx_retrain_req_sync1, rx_retrain_req_sync2;
reg ctrl_frame_valid_sync1, ctrl_frame_valid_sync2;
reg [7:0] ctrl_frame_type_sync1, ctrl_frame_type_sync2;
reg [7:0] ctrl_frame_payload_sync1, ctrl_frame_payload_sync2;

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        rx_phy_ready_sync1  <= 1'b0;  rx_phy_ready_sync2  <= 1'b0;
        rx_link_up_sync1    <= 1'b0;  rx_link_up_sync2    <= 1'b0;
        rx_retrain_req_sync1<= 1'b0;  rx_retrain_req_sync2<= 1'b0;
        ctrl_frame_valid_sync1 <= 1'b0; ctrl_frame_valid_sync2 <= 1'b0;
        ctrl_frame_type_sync1 <= 8'd0; ctrl_frame_type_sync2 <= 8'd0;
        ctrl_frame_payload_sync1 <= 8'd0; ctrl_frame_payload_sync2 <= 8'd0;
    end else begin
        rx_phy_ready_sync1  <= rx_phy_ready;    rx_phy_ready_sync2  <= rx_phy_ready_sync1;
        rx_link_up_sync1    <= rx_link_up;      rx_link_up_sync2    <= rx_link_up_sync1;
        rx_retrain_req_sync1<= rx_retrain_req;  rx_retrain_req_sync2<= rx_retrain_req_sync1;
        ctrl_frame_valid_sync1 <= ctrl_frame_valid; ctrl_frame_valid_sync2 <= ctrl_frame_valid_sync1;
        ctrl_frame_type_sync1 <= ctrl_frame_type; ctrl_frame_type_sync2 <= ctrl_frame_type_sync1;
        ctrl_frame_payload_sync1 <= ctrl_frame_payload; ctrl_frame_payload_sync2 <= ctrl_frame_payload_sync1;
    end
end

// 控制帧有效脉冲边沿检测（同步后只取一拍）
reg ctrl_frame_valid_d;
wire ctrl_frame_valid_pulse;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) ctrl_frame_valid_d <= 1'b0;
    else ctrl_frame_valid_d <= ctrl_frame_valid_sync2;
end
assign ctrl_frame_valid_pulse = ctrl_frame_valid_sync2 & ~ctrl_frame_valid_d;

// ==================================================
// 状态机定义
// ==================================================
localparam S_IDLE     = 3'd0,
           S_TRAINING = 3'd1,
           S_WAIT_PEER= 3'd2,
           S_LINK_UP  = 3'd3,
           S_RETRAIN  = 3'd4;

reg [2:0] curr_state;
reg [2:0] next_state;

reg [15:0] retrain_timer;
reg [15:0] ctrl_send_timer;
localparam CTRL_SEND_INTERVAL = 16'd1000;
localparam RETRAIN_WAIT_CYCLES = 16'd1000;

localparam TYPE_SLAVE_READY = 8'h02;
localparam TYPE_MASTER_ACK  = 8'h03;
localparam TYPE_SLAVE_ACK   = 8'h04;  // V4: 从机确认收到MASTER_ACK
localparam MASTER_ACK_SEND_CNT = 4'd3; // 主机发送MASTER_ACK的次数后才进入LINK_UP

// 主机收到SLAVE_READY标志
reg master_recv_slave_ready;
reg [3:0] master_ack_sent_cnt; // 已发送MASTER_ACK的次数
// [V4修复 LT-04] 主机收到SLAVE_ACK标志
reg master_recv_slave_ack;
// [V4修复 LT-04] 从机已发送SLAVE_ACK标志
reg slave_ack_sent;

// [V4修复 LT-15] 使用generate-if处理IS_MASTER, 避免组合逻辑中的if(parameter)
// S_WAIT_PEER状态完成条件
wire wait_peer_done;
generate
    if (IS_MASTER) begin : gen_master_wait
        // V4: 主机需收到SLAVE_ACK确认后才进LINK_UP
        assign wait_peer_done = master_recv_slave_ready &&
                                master_ack_sent_cnt >= MASTER_ACK_SEND_CNT &&
                                master_recv_slave_ack;
    end else begin : gen_slave_wait
        assign wait_peer_done = ctrl_frame_valid_pulse &&
                                ctrl_frame_type_sync2 == TYPE_MASTER_ACK;
    end
endgenerate

// 三段式状态机 - 第一段：状态寄存器
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) curr_state <= S_IDLE;
    else curr_state <= next_state;
end

// 第二段：次态跳转
always @(*) begin
    next_state = curr_state;
    case(curr_state)
        S_IDLE: begin
            next_state = S_TRAINING;
        end

        S_TRAINING: begin
            if(rx_phy_ready_sync2) begin
                next_state = S_WAIT_PEER;
            end
        end

        // [V4修复 LT-15] 使用wait_peer_done信号替代if(IS_MASTER)
        // [V4修复 LT-04] 主机需等待SLAVE_ACK确认
        S_WAIT_PEER: begin
            if(wait_peer_done) begin
                next_state = S_LINK_UP;
            end
        end

        S_LINK_UP: begin
            if(rx_retrain_req_sync2 || ext_retrain_req) begin
                next_state = S_RETRAIN;
            end
        end

        S_RETRAIN: begin
            if(retrain_timer >= RETRAIN_WAIT_CYCLES) begin
                next_state = S_TRAINING;
            end
        end

        default: next_state = S_IDLE;
    endcase
end

// 第三段：输出控制
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        tx_train_en <= 1'b1;
        ctrl_frame_send <= 1'b0;
        ctrl_frame_type_out <= 8'd0;
        ctrl_frame_payload_out <= 8'd0;
        user_tx_en <= 1'b0;
        user_rx_en <= 1'b0;
        link_all_up <= 1'b0;
        tx_retrain_pulse <= 1'b0;  // V4
        retrain_timer <= 16'd0;
        ctrl_send_timer <= 16'd0;
        master_recv_slave_ready <= 1'b0;
        master_ack_sent_cnt <= 4'd0;
        master_recv_slave_ack <= 1'b0;  // V4
        slave_ack_sent <= 1'b0;  // V4
    end else begin
        ctrl_frame_send <= 1'b0;
        tx_retrain_pulse <= 1'b0;  // V4: 默认低

        case(curr_state)
            S_IDLE: begin
                tx_train_en <= 1'b1;
                user_tx_en <= 1'b0;
                user_rx_en <= 1'b0;
                link_all_up <= 1'b0;
                retrain_timer <= 16'd0;
                master_recv_slave_ready <= 1'b0;
                master_ack_sent_cnt <= 4'd0;
                master_recv_slave_ack <= 1'b0;
                slave_ack_sent <= 1'b0;
            end

            S_TRAINING: begin
                tx_train_en <= 1'b1;
                user_tx_en <= 1'b0;
                user_rx_en <= 1'b0;
                link_all_up <= 1'b0;
                ctrl_send_timer <= 16'd0;
                master_recv_slave_ready <= 1'b0;
                master_ack_sent_cnt <= 4'd0;
                master_recv_slave_ack <= 1'b0;
                slave_ack_sent <= 1'b0;
            end

            // [V4修复 LT-15] 使用generate块替代if(IS_MASTER)组合逻辑
            // 从机在S_WAIT_PEER保持tx_train_en=1
            // 控制帧通过帧调度器与训练码交替发送
            S_WAIT_PEER: begin
                tx_train_en <= 1'b1;  // 保持训练码！
                user_tx_en <= 1'b0;
                user_rx_en <= 1'b0;
                link_all_up <= 1'b0;

                ctrl_send_timer <= ctrl_send_timer + 1'b1;
                if(ctrl_send_timer >= CTRL_SEND_INTERVAL) begin
                    ctrl_send_timer <= 16'd0;
                    ctrl_frame_send <= 1'b1;
                end
            end

            S_LINK_UP: begin
                tx_train_en <= 1'b0;
                user_tx_en <= 1'b1;
                user_rx_en <= 1'b1;
                // [V4修复 LT-14] link_all_up仅在S_LINK_UP状态置位
                link_all_up <= 1'b1;
                ctrl_send_timer <= 16'd0;
                master_recv_slave_ready <= 1'b0;
                master_recv_slave_ack <= 1'b0;
                slave_ack_sent <= 1'b0;
            end

            // [V4修复 LT-05] S_RETRAIN: 生成tx_retrain_pulse同步TX重启
            S_RETRAIN: begin
                tx_train_en <= 1'b1;
                user_tx_en <= 1'b0;
                user_rx_en <= 1'b0;
                link_all_up <= 1'b0;
                retrain_timer <= retrain_timer + 1'b1;
                master_recv_slave_ready <= 1'b0;
                master_recv_slave_ack <= 1'b0;
                slave_ack_sent <= 1'b0;
                // V4: 进入S_RETRAIN的首个周期生成TX重训练脉冲
                if(retrain_timer == 16'd0)
                    tx_retrain_pulse <= 1'b1;
            end

            default: ;
        endcase
    end
end

// [V4修复 LT-15] 使用generate-if处理主从模式的控制帧发送逻辑
generate
    if (IS_MASTER) begin : gen_master_ctrl
        // 主机模式: 收到SLAVE_READY后发MASTER_ACK, 收到SLAVE_ACK后确认
        always @(posedge clk or negedge rst_n) begin
            if(!rst_n) begin
                master_recv_slave_ready <= 1'b0;
                master_ack_sent_cnt <= 4'd0;
                master_recv_slave_ack <= 1'b0;
            end else if(curr_state == S_IDLE || curr_state == S_TRAINING) begin
                master_recv_slave_ready <= 1'b0;
                master_ack_sent_cnt <= 4'd0;
                master_recv_slave_ack <= 1'b0;
            end else if(curr_state == S_WAIT_PEER) begin
                // 检测到SLAVE_READY后置标志
                if(ctrl_frame_valid_pulse && ctrl_frame_type_sync2 == TYPE_SLAVE_READY) begin
                    master_recv_slave_ready <= 1'b1;
                end
                // [V4修复 LT-04] 检测到SLAVE_ACK后置标志
                if(ctrl_frame_valid_pulse && ctrl_frame_type_sync2 == TYPE_SLAVE_ACK) begin
                    master_recv_slave_ack <= 1'b1;
                end
                // 周期性发送MASTER_ACK
                if(ctrl_send_timer >= CTRL_SEND_INTERVAL && master_recv_slave_ready) begin
                    master_ack_sent_cnt <= master_ack_sent_cnt + 1'b1;
                end
                // 立即发送首次MASTER_ACK
                if(ctrl_frame_valid_pulse && ctrl_frame_type_sync2 == TYPE_SLAVE_READY) begin
                    master_ack_sent_cnt <= master_ack_sent_cnt + 1'b1;
                end
            end else if(curr_state == S_LINK_UP) begin
                master_recv_slave_ready <= 1'b0;
                master_recv_slave_ack <= 1'b0;
            end
        end

        // 主机控制帧发送内容
        always @(posedge clk or negedge rst_n) begin
            if(!rst_n) begin
                ctrl_frame_type_out <= 8'd0;
                ctrl_frame_payload_out <= 8'd0;
            end else if(curr_state == S_WAIT_PEER) begin
                if(ctrl_frame_valid_pulse && ctrl_frame_type_sync2 == TYPE_SLAVE_READY) begin
                    // 立即发送MASTER_ACK
                    ctrl_frame_type_out <= TYPE_MASTER_ACK;
                    ctrl_frame_payload_out <= 8'h01;
                end else if(ctrl_send_timer >= CTRL_SEND_INTERVAL && master_recv_slave_ready) begin
                    ctrl_frame_type_out <= TYPE_MASTER_ACK;
                    ctrl_frame_payload_out <= 8'h01;
                end
            end
        end
    end else begin : gen_slave_ctrl
        // 从机模式: 发送SLAVE_READY, 收到MASTER_ACK后发SLAVE_ACK
        always @(posedge clk or negedge rst_n) begin
            if(!rst_n) begin
                slave_ack_sent <= 1'b0;
            end else if(curr_state == S_IDLE || curr_state == S_TRAINING) begin
                slave_ack_sent <= 1'b0;
            end else if(curr_state == S_WAIT_PEER) begin
                // [V4修复 LT-04] 收到MASTER_ACK后发送SLAVE_ACK确认
                if(ctrl_frame_valid_pulse && ctrl_frame_type_sync2 == TYPE_MASTER_ACK) begin
                    slave_ack_sent <= 1'b1;
                end
            end else if(curr_state == S_LINK_UP) begin
                slave_ack_sent <= 1'b0;
            end
        end

        // 从机控制帧发送内容
        always @(posedge clk or negedge rst_n) begin
            if(!rst_n) begin
                ctrl_frame_type_out <= 8'd0;
                ctrl_frame_payload_out <= 8'd0;
            end else if(curr_state == S_WAIT_PEER) begin
                if(ctrl_send_timer >= CTRL_SEND_INTERVAL) begin
                    // [V4修复 LT-04] 收到MASTER_ACK后改发SLAVE_ACK
                    if(slave_ack_sent) begin
                        ctrl_frame_type_out <= TYPE_SLAVE_ACK;
                        ctrl_frame_payload_out <= 8'h01;
                    end else begin
                        ctrl_frame_type_out <= TYPE_SLAVE_READY;
                        ctrl_frame_payload_out <= 8'h01;
                    end
                end
                // 收到MASTER_ACK后立即发送SLAVE_ACK
                if(ctrl_frame_valid_pulse && ctrl_frame_type_sync2 == TYPE_MASTER_ACK) begin
                    ctrl_frame_type_out <= TYPE_SLAVE_ACK;
                    ctrl_frame_payload_out <= 8'h01;
                end
            end
        end
    end
endgenerate

endmodule
