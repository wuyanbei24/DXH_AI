`timescale 1ns / 1ps
//============================================================================
// Module: lane_deskew
// Description: 通道间相位对齐子模块（移位寄存器法）
//   - 以lane0为基准通道，对齐lane1与lane2
//   - 通过移位寄存器延迟对应周期数，使3路同步字在同一个clk_div周期同时出现
//   - 连续16个周期3路同步字均对齐，判定通道对齐完成
//   - [V4修复] LT-03: 首次匹配锁定(局部变量), deskew_en失效时清零lane_offset
//   - [V4修复] LT-13: deskew_done后周期性重校验, 适应运行时偏移变化
//   - [V4修复] LT-17: 未对齐时输出全零, 防止下游使用无效数据
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

// [V4修复 LT-13] 周期性重校验计数器
reg [19:0] recheck_timer;
localparam RECHECK_INTERVAL = 20'd1_000_000; // 每100万周期重校验一次(~10ms@100MHz)
reg recheck_req;
reg [3:0] recheck_fail_cnt;
localparam RECHECK_FAIL_THRESHOLD = 4'd3; // 连续3次重校验失败才重新对齐

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
// [V4修复 LT-03] 使用局部变量found_this_cycle防止同一周期内多次匹配覆盖
// [V4修复 LT-03] deskew_en失效时清零lane_offset和deskew_done
// [V4修复 LT-13] deskew_done后周期性重校验
reg [LANE_CNT-1:0] offset_found;  // 每路是否已找到偏移
reg found_this_cycle;  // V4: 局部匹配标志, 同一周期内锁定首次匹配

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        deskew_done <= 1'b0;
        check_cnt <= 4'd0;
        offset_found <= {LANE_CNT{1'b0}};
        recheck_timer <= 20'd0;
        recheck_req <= 1'b0;
        recheck_fail_cnt <= 4'd0;
        for(i = 0; i < LANE_CNT; i = i + 1)
            lane_offset[i] <= 3'd0;
    end else if(!deskew_en) begin
        // [V4修复 LT-03] deskew_en失效时彻底清零所有状态
        deskew_done <= 1'b0;
        check_cnt <= 4'd0;
        offset_found <= {LANE_CNT{1'b0}};
        recheck_timer <= 20'd0;
        recheck_req <= 1'b0;
        recheck_fail_cnt <= 4'd0;
        for(i = 0; i < LANE_CNT; i = i + 1)
            lane_offset[i] <= 3'd0;
    end else if(deskew_done) begin
        // [V4修复 LT-13] deskew_done后周期性重校验
        recheck_timer <= recheck_timer + 1'b1;
        if(recheck_timer >= RECHECK_INTERVAL) begin
            recheck_timer <= 20'd0;
            recheck_req <= 1'b1;
            // 验证当前偏移是否仍然有效
            if(shift_reg[0][0] == sync_word) begin
                if(shift_reg[1][lane_offset[1]] == sync_word &&
                   shift_reg[2][lane_offset[2]] == sync_word) begin
                    recheck_fail_cnt <= 4'd0;  // 校验通过
                end else begin
                    recheck_fail_cnt <= recheck_fail_cnt + 1'b1;
                end
            end
            if(recheck_fail_cnt >= RECHECK_FAIL_THRESHOLD) begin
                // 连续多次校验失败, 重新对齐
                deskew_done <= 1'b0;
                offset_found <= {LANE_CNT{1'b0}};
                recheck_fail_cnt <= 4'd0;
                for(i = 0; i < LANE_CNT; i = i + 1)
                    lane_offset[i] <= 3'd0;
            end
        end else begin
            recheck_req <= 1'b0;
        end
    end else begin
        // deskew_en && ~deskew_done: 正常对齐流程
        recheck_timer <= 20'd0;
        recheck_req <= 1'b0;
        recheck_fail_cnt <= 4'd0;
        // lane0为基准，检查lane0当前数据是否为sync_word
        if(shift_reg[0][0] == sync_word) begin
            // [V4修复 LT-03] 检测其他通道的sync_word位置（首次匹配锁定）
            for(i = 1; i < LANE_CNT; i = i + 1) begin
                if(!offset_found[i]) begin
                    found_this_cycle = 1'b0;  // V4: 局部标志, 同一周期内只锁第一次匹配
                    for(j = 0; j < DESKEW_DEPTH; j = j + 1) begin
                        if(shift_reg[i][j] == sync_word && !found_this_cycle) begin
                            lane_offset[i] <= j[2:0];
                            offset_found[i] <= 1'b1;
                            found_this_cycle = 1'b1;  // V4: 锁定, 后续j不再匹配
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
    end
end

// [V4修复 LT-17] 对齐输出: deskew_done=0时输出全零, 防止下游使用无效数据
always @(*) begin
    if(deskew_done) begin
        data_out[0*DATA_WIDTH +: DATA_WIDTH] = shift_reg[0][0];
        for(i = 1; i < LANE_CNT; i = i + 1) begin
            data_out[i*DATA_WIDTH +: DATA_WIDTH] = shift_reg[i][lane_offset[i]];
        end
    end else begin
        // V4: 未对齐时输出全零
        for(i = 0; i < LANE_CNT; i = i + 1) begin
            data_out[i*DATA_WIDTH +: DATA_WIDTH] = {DATA_WIDTH{1'b0}};
        end
    end
end

endmodule
