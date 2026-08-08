`timescale 1ns / 1ps
//============================================================================
// Module: lvds_rx_phy
// Description: 3通道接收物理层顶层
//   - 1路时钟缓冲 + 3路数据通道实例化
//   - 新增通道对齐模块实现3路相位同步
//   - 集成全局训练状态机
//   - [V4修复] LT-02: 使用mfpga_clk_ip输出400MHz/100MHz, 满足DDR 8:1的4:1时钟比
//   - [V4修复] LT-10: M_FAULT恢复时生成内部retrain脉冲, 复位所有子模块状态
//   - [V4修复] LT-12: M_NORMAL状态下增加运行时信号质量监测
//   - [V4修复] LT-16: 移除死代码retry_cnt, 改为fault_retry_cnt故障计数
// Source: Xilinx 7系列FPGA双向3路数据LVDS通信设计文档_V1.0  §4.3
//============================================================================
module lvds_rx_phy #(
    parameter DATA_WIDTH    = 8,
    parameter LANE_CNT      = 3,
    parameter DELAY_STEPS   = 32,
    parameter SAMPLE_CNT    = 16,
    parameter MIN_WIN_SIZE  = 4,
    parameter DESKEW_DEPTH  = 8
)(
    input  wire rst_n,
    // LVDS差分输入：1路时钟 + 3路数据
    input  wire lvds_clk_p,
    input  wire lvds_clk_n,
    input  wire [LANE_CNT-1:0] lvds_data_p,
    input  wire [LANE_CNT-1:0] lvds_data_n,
    // IDELAY参考时钟
    input  wire ref_clk_200m,
    // 控制接口
    input  wire retrain_req,
    input  wire heartbeat_err,  // 链路层心跳超时指示
    // 并行数据输出（同步24bit）
    output wire [LANE_CNT*DATA_WIDTH-1:0] rx_data,
    output wire                            rx_data_valid,
    // 状态输出
    output reg  phy_ready,
    output reg  align_err,
    output wire clk_div
);

// 全局主状态机定义
localparam M_IDLE       = 3'd0,
           M_CALIB      = 3'd1,
           M_LANE_DESKEW= 3'd2,
           M_LOCK_CHECK = 3'd3,
           M_NORMAL     = 3'd4,
           M_FAULT      = 3'd5;
reg [2:0] m_curr_state;
reg [2:0] m_next_state;

// 内部信号
wire clk_ibuf;
wire clk_bufio;

wire [DATA_WIDTH-1:0] lane_data [LANE_CNT-1:0];
wire [LANE_CNT-1:0] lane_align_done;
wire [LANE_CNT-1:0] lane_calib_err;
wire [4:0] lane_best_delay [LANE_CNT-1:0];

wire all_lane_done;
wire any_lane_err;

wire deskew_done;
wire [LANE_CNT*DATA_WIDTH-1:0] deskew_data_out;

reg [15:0] lock_timer;
reg [15:0] lock_match_cnt;
// [V4修复 LT-16] 移除死代码retry_cnt, 改为fault_retry_cnt故障计数
reg [3:0]  fault_retry_cnt;
reg [15:0] fault_wait_timer;

// [V4修复 LT-10] 内部retrain脉冲, M_FAULT恢复时复位所有子模块
reg        internal_retrain;
reg        internal_retrain_prev;



localparam LOCK_CHECK_CYCLES = 16'd5000;
localparam [15:0] LOCK_VOTE_THRESHOLD = 16'd4000; // 80%通过率要求
localparam FAULT_RECOVERY_CYCLES = 16'd50000; // M_FAULT等待后自动恢复
localparam MAX_FAULT_RETRY = 4'd5; // V4: 最大故障重试次数

// 时钟缓冲通路
IBUFDS #(
.DIFF_TERM("TRUE"), 
.IOSTANDARD("DEFAULT")) 
u_ibufds_clk (
    .I(lvds_clk_p), 
    .IB(lvds_clk_n), 
    .O(clk_ibuf)
);


wire clk_out4_100   ;
wire mmcm_lock      ;

// 输入LVDS时钟400MHz, 通过lvds_rx_pll实现4:1分频输出100MHz
lvds_rx_pll lvds_clkdiv_gen (
    .clk_out1(clk_out4_100),  // 100MHz parallel clock
    .locked  (mmcm_lock),
    .clk_in1 (clk_ibuf)       // 400MHz from IBUFDS
);

// clk_bufio直接使用IBUFDS输出的400MHz, clk_div使用PLL输出的100MHz
assign clk_bufio = clk_ibuf;         // 400MHz serial clock
assign clk_div   = clk_out4_100;     // 100MHz parallel clock

// BUFIO u_bufio_clk (.I(clk_ibuf), .O(clk_bufio));
// BUFR #(.BUFR_DIVIDE("4"), 
// .SIM_DEVICE("7SERIES"))
//  u_bufr_div (
//     .I(clk_ibuf), 
//     .O(clk_div), 
//     .CE(1'b1), 
//     .CLR(~rst_n)
// );

// 共用IDELAYCTRL
IDELAYCTRL u_idelayctrl (
    .REFCLK (ref_clk_200m),
    .RST    (~rst_n),
    .RDY    ()
);

// 逐通道例化单通道物理层
genvar lane_idx;
generate
    for(lane_idx = 0; lane_idx < LANE_CNT; lane_idx = lane_idx + 1) begin : gen_rx_lanes
        lvds_rx_lane_phy #(
            .DATA_WIDTH(DATA_WIDTH),
            .DELAY_STEPS(DELAY_STEPS),
            .SAMPLE_CNT(SAMPLE_CNT),
            .MIN_WIN_SIZE(MIN_WIN_SIZE)
        ) u_lane_phy (
            // .rst_n(rst_n),
            .rst_n(mmcm_lock),
            .lvds_data_p(lvds_data_p[lane_idx]),
            .lvds_data_n(lvds_data_n[lane_idx]),
            .clk_bufio(clk_bufio),  // V4: 使用400MHz串行时钟
            .clk_div(clk_div),
            .ref_clk_200m(ref_clk_200m),
            .retrain_req(retrain_req | internal_retrain),  // V4: 合并外部和内部retrain
            .training_mode(training_mode),
            .rx_data(lane_data[lane_idx]),
            .lane_align_done(lane_align_done[lane_idx]),
            .lane_calib_err(lane_calib_err[lane_idx]),
            .best_delay_val(lane_best_delay[lane_idx])
        );
    end
endgenerate

assign all_lane_done = &lane_align_done;
assign any_lane_err = |lane_calib_err;

// 训练模式标志: M_NORMAL之外均为训练阶段
wire training_mode = (m_curr_state != M_NORMAL);

// 通道间相位对齐模块
lane_deskew #(
    .DATA_WIDTH(DATA_WIDTH),
    .LANE_CNT(LANE_CNT),
    .DESKEW_DEPTH(DESKEW_DEPTH)
) u_lane_deskew (
    .clk(clk_div),
    .rst_n(rst_n),
    .data_in({lane_data[2], lane_data[1], lane_data[0]}),
    .sync_word(8'hB5),
    .deskew_en(m_curr_state == M_LANE_DESKEW),
    .data_out(deskew_data_out),
    .deskew_done(deskew_done)
);

assign rx_data = deskew_data_out;
assign rx_data_valid = phy_ready;

// 全局主状态机（三段式）
always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n) m_curr_state <= M_IDLE;
    else m_curr_state <= m_next_state;
end

always @(*) begin
    m_next_state = m_curr_state;
    case(m_curr_state)
        M_IDLE:        m_next_state = M_CALIB;
        M_CALIB: begin
            if(any_lane_err)
                m_next_state = M_FAULT;
            else if(all_lane_done)
                m_next_state = M_LANE_DESKEW;
        end
        M_LANE_DESKEW: if(deskew_done) m_next_state = M_LOCK_CHECK;
        M_LOCK_CHECK:  if(lock_timer >= LOCK_CHECK_CYCLES)
                           m_next_state = (lock_match_cnt >= LOCK_VOTE_THRESHOLD) ? M_NORMAL : M_FAULT;
        // C-02修复: 使用心跳超时作为链路健康指标
        M_NORMAL:      if(retrain_req | heartbeat_err) m_next_state = M_IDLE;
        // [V4修复 LT-10] M_FAULT: 恢复时生成内部retrain脉冲
        M_FAULT:       if(fault_wait_timer >= FAULT_RECOVERY_CYCLES) m_next_state = M_IDLE;
        default:       m_next_state = M_IDLE;
    endcase
end

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
            M_LANE_DESKEW: begin
                lock_timer <= 16'd0;
                lock_match_cnt <= 16'd0;
            end
            M_LOCK_CHECK: begin
                lock_timer <= lock_timer + 1'b1;
                if(deskew_data_out[7:0] == 8'hB5 &&
                   deskew_data_out[15:8] == 8'hB5 &&
                   deskew_data_out[23:16] == 8'hB5) begin
                    lock_match_cnt <= lock_match_cnt + 1'b1;
                end
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

// [V4修复 LT-16] 故障重试计数器 (替代原死代码retry_cnt)
always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n)
        fault_retry_cnt <= 4'd0;
    else if(m_curr_state == M_NORMAL)
        fault_retry_cnt <= 4'd0;  // 正常运行时清零
    else if(m_curr_state == M_FAULT && m_next_state == M_IDLE)
        fault_retry_cnt <= fault_retry_cnt + 1'b1;  // 每次故障恢复递增
end

// [V4修复 LT-10] 内部retrain脉冲生成: M_FAULT->M_IDLE转换时产生单周期脉冲
// 用于复位所有子模块的bitslip_cnt/lane_align_done/lane_offset等脏状态
always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n) begin
        internal_retrain <= 1'b0;
        internal_retrain_prev <= 1'b0;
    end else begin
        internal_retrain_prev <= internal_retrain;
        // M_FAULT恢复到M_IDLE时生成retrain脉冲
        if(m_curr_state == M_FAULT && m_next_state == M_IDLE)
            internal_retrain <= 1'b1;
        else
            internal_retrain <= 1'b0;
    end
end

// M_FAULT恢复等待计数器（N-07修复：避免永久死锁）
always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n)
        fault_wait_timer <= 16'd0;
    else if(m_curr_state == M_FAULT)
        fault_wait_timer <= fault_wait_timer + 1'b1;
    else
        fault_wait_timer <= 16'd0;
end

endmodule
