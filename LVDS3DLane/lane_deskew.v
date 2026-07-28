`timescale 1ns / 1ps
//============================================================================
// Module: lane_deskew
// Description: 通道间相位对齐子模块（移位寄存器法）
//   - 以lane0为基准通道，对齐lane1与lane2
//   - 通过移位寄存器延迟对应周期数，使3路同步字在同一个clk_div周期同时出现
//   - 连续16个周期3路同步字均对齐，判定通道对齐完成
// Source: Xilinx 7系列FPGA双向3路数据LVDS通信设计文档_V1.0  §4.3
//============================================================================
module lane_deskew #(
    parameter DATA_WIDTH = 8,
    parameter LANE_CNT   = 3,
    parameter DESKEW_DEPTH = 8
)(
    input  wire clk,
    input  wire rst_n,
    input  wire [LANE_CNT*DATA_WIDTH-1:0] data_in,
    input  wire [7:0] sync_word,
    input  wire deskew_en,
    output reg  [LANE_CNT*DATA_WIDTH-1:0] data_out,
    output reg  deskew_done
);

reg [DATA_WIDTH-1:0] shift_reg [LANE_CNT-1:0][DESKEW_DEPTH-1:0];
reg [2:0] lane_offset [LANE_CNT-1:0];
reg [3:0] check_cnt;
integer i, j;

// 移位寄存器链
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        for(i = 0; i < LANE_CNT; i = i + 1)
            for(j = 0; j < DESKEW_DEPTH; j = j + 1)
                shift_reg[i][j] <= 8'd0;
    end else begin
        for(i = 0; i < LANE_CNT; i = i + 1) begin
            shift_reg[i][0] <= data_in[i*DATA_WIDTH +: DATA_WIDTH];
            for(j = 1; j < DESKEW_DEPTH; j = j + 1)
                shift_reg[i][j] <= shift_reg[i][j-1];
        end
    end
end

// 偏移检测与锁定（以lane0为基准）
// R-05修复：使用offset_locked标志防止循环内覆盖
// N-06修复：deskew_done保持锁定，check_cnt需连续匹配
reg [LANE_CNT-1:0] offset_found;  // 每路是否已找到偏移

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        deskew_done <= 1'b0;
        check_cnt <= 4'd0;
        offset_found <= {LANE_CNT{1'b0}};
        for(i = 0; i < LANE_CNT; i = i + 1)
            lane_offset[i] <= 3'd0;
    end else if(deskew_en && ~deskew_done) begin
        // lane0为基准，检查lane0当前数据是否为sync_word
        if(shift_reg[0][0] == sync_word) begin
            // 检测其他通道的sync_word位置（仅首次匹配锁定）
            for(i = 1; i < LANE_CNT; i = i + 1) begin
                if(!offset_found[i]) begin
                    for(j = 0; j < DESKEW_DEPTH; j = j + 1) begin
                        if(shift_reg[i][j] == sync_word && !offset_found[i]) begin
                            lane_offset[i] <= j[2:0];
                            offset_found[i] <= 1'b1;
                        end
                    end
                end
            end
            // 所有通道偏移已找到后，开始连续匹配计数
            if(&offset_found || LANE_CNT == 1) begin
                // 验证：所有通道在当前偏移位置是否同时出现sync_word
                if(shift_reg[1][lane_offset[1]] == sync_word &&
                   shift_reg[2][lane_offset[2]] == sync_word) begin
                    check_cnt <= check_cnt + 1'b1;
                end else begin
                    check_cnt <= 4'd0;  // 非连续匹配，重新计数
                end
                if(check_cnt >= 4'd15) begin
                    deskew_done <= 1'b1;
                end
            end
        end else begin
            check_cnt <= 4'd0;  // lane0不是sync_word，重新计数
        end
    end else if(!deskew_en) begin
        // deskew_en失效时清零计数和查找状态，但保留deskew_done和lane_offset
        check_cnt <= 4'd0;
        offset_found <= {LANE_CNT{1'b0}};
    end
end

// 对齐输出
always @(*) begin
    data_out[0*DATA_WIDTH +: DATA_WIDTH] = shift_reg[0][0];
    for(i = 1; i < LANE_CNT; i = i + 1) begin
        data_out[i*DATA_WIDTH +: DATA_WIDTH] = shift_reg[i][lane_offset[i]];
    end
end

endmodule
