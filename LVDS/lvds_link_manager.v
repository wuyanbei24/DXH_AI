`timescale 1ns / 1ps

module lvds_link_manager #(
    parameter IS_MASTER = 1  // 1=主机模式，0=从机模式
)(
    input  wire clk,
    input  wire rst_n,
    
    // 接收通道状态
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
    output reg  link_all_up
);

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
            if(rx_phy_ready) begin
                next_state = S_WAIT_PEER;
            end
        end
        
        S_WAIT_PEER: begin
            if(IS_MASTER) begin
                if(ctrl_frame_valid && ctrl_frame_type == TYPE_SLAVE_READY) begin
                    next_state = S_LINK_UP;
                end
            end else begin
                if(ctrl_frame_valid && ctrl_frame_type == TYPE_MASTER_ACK) begin
                    next_state = S_LINK_UP;
                end
            end
        end
        
        S_LINK_UP: begin
            if(rx_retrain_req || ext_retrain_req) begin
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
        retrain_timer <= 16'd0;
        ctrl_send_timer <= 16'd0;
    end else begin
        ctrl_frame_send <= 1'b0;
        
        case(curr_state)
            S_IDLE: begin
                tx_train_en <= 1'b1;
                user_tx_en <= 1'b0;
                user_rx_en <= 1'b0;
                link_all_up <= 1'b0;
                retrain_timer <= 16'd0;
            end
            
            S_TRAINING: begin
                tx_train_en <= 1'b1;
                user_tx_en <= 1'b0;
                user_rx_en <= 1'b0;
                link_all_up <= 1'b0;
                ctrl_send_timer <= 16'd0;
            end
            
            S_WAIT_PEER: begin
                tx_train_en <= 1'b0;
                user_tx_en <= 1'b0;
                user_rx_en <= 1'b0;
                link_all_up <= 1'b0;
                
                ctrl_send_timer <= ctrl_send_timer + 1'b1;
                if(ctrl_send_timer >= CTRL_SEND_INTERVAL) begin
                    ctrl_send_timer <= 16'd0;
                    ctrl_frame_send <= 1'b1;
                    
                    if(IS_MASTER) begin
                        ctrl_frame_type_out <= TYPE_MASTER_ACK;
                        ctrl_frame_payload_out <= 8'h01;
                    end else begin
                        ctrl_frame_type_out <= TYPE_SLAVE_READY;
                        ctrl_frame_payload_out <= 8'h01;
                    end
                end
            end
            
            S_LINK_UP: begin
                tx_train_en <= 1'b0;
                user_tx_en <= 1'b1;
                user_rx_en <= 1'b1;
                link_all_up <= 1'b1;
                ctrl_send_timer <= 16'd0;
            end
            
            S_RETRAIN: begin
                tx_train_en <= 1'b1;
                user_tx_en <= 1'b0;
                user_rx_en <= 1'b0;
                link_all_up <= 1'b0;
                retrain_timer <= retrain_timer + 1'b1;
            end
            
            default: ;
        endcase
    end
end

endmodule