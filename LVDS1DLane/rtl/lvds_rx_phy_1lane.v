`timescale 1ns / 1ps
//============================================================================
// Module: lvds_rx_phy_1lane
// Description: 单路(1-lane) 接收物理层顶层  —  专用 1-lane 设计(不兼容参数化)
//   - 1路时钟缓冲 + 1路数据通道(lvds_rx_lane_phy)
//   - 1-lane无需deskew(无通道间相位差), 全局状态机: M_IDLE->M_CALIB->M_LOCK_CHECK->M_NORMAL
//   - M_CALIB等待单通道校准完成(lane_align_done)
//   - M_LOCK_CHECK验证训练码0xB5连续匹配
//   - SIM_BYPASS: 仿真旁路BUFIO/BUFR, 使用TX同源时钟
// Source: 基于 lvds_rx_phy.v(V13, 3-lane) 移植, 去掉deskew与多路打包
//============================================================================
module lvds_rx_phy_1lane #(
    parameter DATA_WIDTH    = 8,
    parameter DELAY_STEPS   = 32,
    parameter SAMPLE_CNT    = 16,
    parameter MIN_WIN_SIZE  = 4,
    parameter SIM_BYPASS    = 0  // V8: 仿真旁路BUFIO/BUFR
)(
    input  wire rst_n,
    // LVDS差分输入：1路时钟 + 1路数据
    input  wire lvds_clk_p,
    input  wire lvds_clk_n,
    input  wire lvds_data_p,
    input  wire lvds_data_n,
    // IDELAY参考时钟
    input  wire ref_clk_200m,
    // 控制接口
    input  wire retrain_req,
    input  wire heartbeat_err,
    // V8: 仿真旁路时钟输入
    input  wire clk_ser_ext,
    input  wire clk_div_ext,
    // 并行数据输出 (8bit)
    output wire [DATA_WIDTH-1:0] rx_data,
    output wire                  rx_data_valid,
    // 状态输出
    output reg  phy_ready,
    output reg  align_err,
    output wire clk_div
);

// 全局主状态机定义
localparam M_IDLE       = 3'd0,
           M_CALIB      = 3'd1,
           M_LOCK_CHECK = 3'd3,
           M_NORMAL     = 3'd4,
           M_FAULT      = 3'd5;
reg [2:0] m_curr_state;
reg [2:0] m_next_state;

wire clk_bufio;

wire [DATA_WIDTH-1:0] lane_data;
wire lane_align_done;
wire lane_calib_err;
wire [4:0] lane_best_delay;

// 训练模式标志: M_NORMAL之外均为训练阶段
wire training_mode = (m_curr_state != M_NORMAL);

reg [15:0] lock_timer;
reg [15:0] lock_match_cnt;
reg [3:0]  fault_retry_cnt;
reg [15:0] fault_wait_timer;

reg        internal_retrain;
reg        internal_retrain_prev;

localparam LOCK_CHECK_CYCLES = 16'd5000;
localparam [15:0] LOCK_VOTE_THRESHOLD = 16'd4000;
localparam FAULT_RECOVERY_CYCLES = 16'd50000;
localparam MAX_FAULT_RETRY = 4'd5;

// V8: 时钟缓冲通路
generate
    if(SIM_BYPASS) begin : gen_sim_clk
        assign clk_bufio = clk_ser_ext;
        assign clk_div   = clk_div_ext;
    end else begin : gen_real_clk
        wire clk_ibuf;
        IBUFDS #(.DIFF_TERM("TRUE"), .IOSTANDARD("DEFAULT"))
        u_ibufds_clk ( .I(lvds_clk_p), .IB(lvds_clk_n), .O(clk_ibuf) );
        BUFIO u_bufio_clk ( .I(clk_ibuf), .O(clk_bufio) );
        BUFR #(.BUFR_DIVIDE("4"), .SIM_DEVICE("7SERIES"))
        u_bufr_div ( .I(clk_ibuf), .O(clk_div), .CE(1'b1), .CLR(~rst_n) );
    end
endgenerate

// BUFR稳定等待(仿真旁路跳过)
reg [3:0] bufr_settle_cnt;
reg clk_div_ready;
always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n) begin
        bufr_settle_cnt <= 4'd0;
        clk_div_ready <= 1'b0;
    end else if(SIM_BYPASS) begin
        bufr_settle_cnt <= 4'd15;
        clk_div_ready <= 1'b1;
    end else begin
        if(bufr_settle_cnt < 4'd15) begin
            bufr_settle_cnt <= bufr_settle_cnt + 1'b1;
            clk_div_ready <= 1'b0;
        end else begin
            clk_div_ready <= 1'b1;
        end
    end
end

// 共用IDELAYCTRL
IDELAYCTRL u_idelayctrl ( .REFCLK (ref_clk_200m), .RST (~rst_n), .RDY () );

// 单通道物理层
lvds_rx_lane_phy #(
    .DATA_WIDTH(DATA_WIDTH),
    .DELAY_STEPS(DELAY_STEPS),
    .SAMPLE_CNT(SAMPLE_CNT),
    .MIN_WIN_SIZE(MIN_WIN_SIZE)
) u_lane_phy (
    .rst_n(clk_div_ready),
    .lvds_data_p(lvds_data_p),
    .lvds_data_n(lvds_data_n),
    .clk_bufio(clk_bufio),
    .clk_div(clk_div),
    .ref_clk_200m(ref_clk_200m),
    .retrain_req(retrain_req | internal_retrain),
    .training_mode(training_mode),
    .rx_data(lane_data),
    .lane_align_done(lane_align_done),
    .lane_calib_err(lane_calib_err),
    .best_delay_val(lane_best_delay)
);

assign rx_data = lane_data;
assign rx_data_valid = phy_ready;

// 全局主状态机 - 第一段
always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n) m_curr_state <= M_IDLE;
    else m_curr_state <= m_next_state;
end

// 第二段：次态跳转
always @(*) begin
    m_next_state = m_curr_state;
    case(m_curr_state)
        M_IDLE:        m_next_state = M_CALIB;
        M_CALIB: begin
            if(lane_calib_err)
                m_next_state = M_FAULT;
            else if(lane_align_done)
                m_next_state = M_LOCK_CHECK;
        end
        M_LOCK_CHECK:  if(lock_timer >= LOCK_CHECK_CYCLES)
                           m_next_state = (lock_match_cnt >= LOCK_VOTE_THRESHOLD) ? M_NORMAL : M_FAULT;
        M_NORMAL:      if(retrain_req | heartbeat_err) m_next_state = M_IDLE;
        M_FAULT:       if(fault_wait_timer >= FAULT_RECOVERY_CYCLES) m_next_state = M_IDLE;
        default:       m_next_state = M_IDLE;
    endcase
end

// 第三段：输出
always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n) begin
        phy_ready <= 1'b0;
        align_err <= 1'b0;
        lock_timer <= 16'd0;
        lock_match_cnt <= 16'd0;
    end else begin
        case(m_curr_state)
            M_IDLE: begin
                phy_ready <= 1'b0;
                align_err <= 1'b0;
                lock_timer <= 16'd0;
                lock_match_cnt <= 16'd0;
            end
            M_CALIB: begin
                phy_ready <= 1'b0;
            end
            M_LOCK_CHECK: begin
                lock_timer <= lock_timer + 1'b1;
                if(lane_data == 8'hB5)
                    lock_match_cnt <= lock_match_cnt + 1'b1;
            end
            M_NORMAL: begin
                phy_ready <= 1'b1;
                align_err <= 1'b0;
            end
            M_FAULT: begin
                phy_ready <= 1'b0;
                align_err <= 1'b1;
            end
            default: ;
        endcase
    end
end

// 故障重试计数器
always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n)
        fault_retry_cnt <= 4'd0;
    else if(m_curr_state == M_NORMAL)
        fault_retry_cnt <= 4'd0;
    else if(m_curr_state == M_FAULT && m_next_state == M_IDLE)
        fault_retry_cnt <= fault_retry_cnt + 1'b1;
end

// 内部retrain脉冲: M_FAULT->M_IDLE时产生
always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n) begin
        internal_retrain <= 1'b0;
        internal_retrain_prev <= 1'b0;
    end else begin
        internal_retrain_prev <= internal_retrain;
        if(m_curr_state == M_FAULT && m_next_state == M_IDLE)
            internal_retrain <= 1'b1;
        else
            internal_retrain <= 1'b0;
    end
end

// M_FAULT恢复等待
always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n)
        fault_wait_timer <= 16'd0;
    else if(m_curr_state == M_FAULT)
        fault_wait_timer <= fault_wait_timer + 1'b1;
    else
        fault_wait_timer <= 16'd0;
end

// 调试打印
reg [2:0] dbg_state_prev;
reg [8:0] dbg_normal_cnt;
always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n) begin
        dbg_state_prev <= 3'd0;
        dbg_normal_cnt <= 9'd0;
    end else begin
        dbg_state_prev <= m_curr_state;
        if(m_curr_state != dbg_state_prev) begin
            $display("[%0t] RX_PHY STATE: %0d->%0d lane0=%h align_done=%b",
                $time, dbg_state_prev, m_curr_state, lane_data, lane_align_done);
        end
        if(m_curr_state == M_NORMAL) begin
            if(dbg_normal_cnt < 9'd600) begin
                $display("[%0t] RX_PHY CYCLE%0d: lane0=%h", $time, dbg_normal_cnt, lane_data);
                dbg_normal_cnt <= dbg_normal_cnt + 1'b1;
            end
            if(lane_data != 8'hB5 && lane_data != 8'h00) begin
                $display("[%0t] RX_PHY NORMAL: non-training data lane0=%h", $time, lane_data);
            end
        end else begin
            dbg_normal_cnt <= 9'd0;
        end
    end
end

endmodule
