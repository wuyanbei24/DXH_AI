`timescale 1ns / 1ps
//============================================================================
// axis32_to_lvds8.v
// ----------------------------------------------------------------------------
// 32-bit AXI4-Stream -> 8-bit 字节序列化器
//
// 功能：
//   将 32-bit AXI4-Stream 接口（tdata/tvalid/tlast/tready）序列化为 8-bit
//   字节流，适配 LVDS TX 通道的用户接口。每个 32-bit AXI4-Stream beat
//   序列化为 5 个字节（1 控制字节 + 4 数据字节）。
//
// 字节级序列化协议：
//   Byte 0 (CTRL)   : {7'b0, tlast}     ← 控制字节，bit0 = tlast
//   Byte 1 (DATA[0]): tdata[7:0]         ← LSB
//   Byte 2 (DATA[1]): tdata[15:8]
//   Byte 3 (DATA[2]): tdata[23:16]
//   Byte 4 (DATA[3]): tdata[31:24]       ← MSB
//
// 状态机：三段式，6 个状态
//   S_IDLE -> S_CTRL -> S_B0 -> S_B1 -> S_B2 -> S_B3 -> S_IDLE
//
// 反压传播：
//   tx_ready=0 时暂停字节输出，s_axis_tready=0 反压上游 AXI4-Stream
//
// 设计文档：doc/axis32_to_lvds8_详细设计文档.md
//============================================================================
module axis32_to_lvds8 (
    input  wire        aclk,           // 时钟（100MHz，与 LVDS clk_div 同源）
    input  wire        aresetn,        // 低有效异步复位

    // AXI4-Stream Slave 接口（32-bit 输入）
    input  wire [31:0] s_axis_tdata,   // 数据
    input  wire        s_axis_tvalid,  // 有效
    input  wire        s_axis_tlast,   // 帧尾
    output wire        s_axis_tready,  // 准备好接收

    // 8-bit 输出接口（连接 LVDS TX 用户接口）
    output wire [7:0]  tx_data,        // 字节数据
    output wire        tx_valid,       // 字节有效
    input  wire        tx_ready        // 下游准备好（LVDS TX FIFO 未满且非训练态）
);

    // ========== 状态定义（三段式）==========
    localparam [2:0] S_IDLE = 3'd0;    // 空闲，等待 AXI4-Stream 握手
    localparam [2:0] S_CTRL = 3'd1;    // 发送控制字节 {7'b0, tlast_hold}
    localparam [2:0] S_B0   = 3'd2;    // 发送 tdata[7:0]
    localparam [2:0] S_B1   = 3'd3;    // 发送 tdata[15:8]
    localparam [2:0] S_B2   = 3'd4;    // 发送 tdata[23:16]
    localparam [2:0] S_B3   = 3'd5;    // 发送 tdata[31:24]，完成后回 S_IDLE

    reg [2:0] curr_state;
    reg [2:0] next_state;

    // ========== 内部寄存器 ==========
    reg [31:0] tdata_hold;             // 锁存 AXI4-Stream 握手时的 tdata
    reg        tlast_hold;             // 锁存 AXI4-Stream 握手时的 tlast

    // ========== 握手信号 ==========
    // AXI4-Stream 输入握手
    wire axis_hs = s_axis_tvalid && s_axis_tready;
    // 字节输出握手
    wire byte_hs = tx_valid && tx_ready;

    //=====================================================================
    // 三段式状态机 —— 第一段：状态寄存器（时序逻辑）
    //=====================================================================
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            curr_state <= S_IDLE;
        end else begin
            curr_state <= next_state;
        end
    end

    //=====================================================================
    // 三段式状态机 —— 第二段：下一状态逻辑（组合逻辑）
    //=====================================================================
    always @(*) begin
        case (curr_state)
            S_IDLE: begin
                // AXI4-Stream 握手成立时进入 S_CTRL
                if (axis_hs) begin
                    next_state = S_CTRL;
                end else begin
                    next_state = S_IDLE;
                end
            end

            S_CTRL: begin
                // 控制字节发送完成（字节握手成功）
                if (byte_hs) begin
                    next_state = S_B0;
                end else begin
                    next_state = S_CTRL;
                end
            end

            S_B0: begin
                if (byte_hs) begin
                    next_state = S_B1;
                end else begin
                    next_state = S_B0;
                end
            end

            S_B1: begin
                if (byte_hs) begin
                    next_state = S_B2;
                end else begin
                    next_state = S_B1;
                end
            end

            S_B2: begin
                if (byte_hs) begin
                    next_state = S_B3;
                end else begin
                    next_state = S_B2;
                end
            end

            S_B3: begin
                // 最后一个字节发送完成，回到 S_IDLE
                if (byte_hs) begin
                    next_state = S_IDLE;
                end else begin
                    next_state = S_B3;
                end
            end

            default: begin
                next_state = S_IDLE;
            end
        endcase
    end

    //=====================================================================
    // 三段式状态机 —— 第三段：输出逻辑 & 数据锁存
    //=====================================================================

    // 数据锁存：在 AXI4-Stream 握手时锁存 tdata 和 tlast
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            tdata_hold <= 32'd0;
            tlast_hold <= 1'b0;
        end else if (axis_hs) begin
            tdata_hold <= s_axis_tdata;
            tlast_hold <= s_axis_tlast;
        end
    end

    // s_axis_tready：仅在 S_IDLE 且 tx_ready=1 时为高
    assign s_axis_tready = (curr_state == S_IDLE) && tx_ready;

    // tx_valid：在 S_CTRL ~ S_B3 状态下为高
    assign tx_valid = (curr_state == S_CTRL) ||
                      (curr_state == S_B0)   ||
                      (curr_state == S_B1)   ||
                      (curr_state == S_B2)   ||
                      (curr_state == S_B3);

    // tx_data：按当前状态选择控制字节或对应数据字节
    assign tx_data = (curr_state == S_CTRL) ? {7'b0, tlast_hold} :
                     (curr_state == S_B0)   ? tdata_hold[7:0]    :
                     (curr_state == S_B1)   ? tdata_hold[15:8]   :
                     (curr_state == S_B2)   ? tdata_hold[23:16]  :
                     (curr_state == S_B3)   ? tdata_hold[31:24]  :
                                              8'h00;

endmodule
