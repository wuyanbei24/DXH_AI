`timescale 1ns / 1ps
//============================================================================
// Module: lvds_rx_lane_phy
// Description: 单路LVDS接收物理层子模块
//   - 封装单路LVDS接收的完整物理层校准逻辑
//   - 每通道独立执行延迟扫描与字对齐
//   - IDELAYE2延迟校准 + ISERDESE2解串 + BITSLIP字对齐
//   - [V4修复] LT-06: 增加W_DONE状态, bitslip_cnt在scan_done上升沿清零
//   - [V4修复] LT-08: lane_align_done在信号恶化时自动清零
//   - [V4修复] LT-11: 增加D_SETTLE等待IDELAY稳定, 修正采样次数, 容错改为统计总错误数
// Source: Xilinx 7系列FPGA双向3路数据LVDS通信设计文档_V1.0  §4.2
//============================================================================
module lvds_rx_lane_phy #(
    parameter DATA_WIDTH    = 8,
    parameter DELAY_STEPS   = 32,
    parameter SAMPLE_CNT    = 16,
    parameter MIN_WIN_SIZE  = 4
)(
    input  wire rst_n,
    // LVDS差分输入
    input  wire lvds_data_p,
    input  wire lvds_data_n,
    // 时钟域
    input  wire clk_bufio,
    input  wire clk_div,
    // IDELAY参考时钟
    input  wire ref_clk_200m,
    // 控制接口
    input  wire retrain_req,
    input  wire training_mode,  // 高=训练中, 低=数据模式(禁用码型监测)
    // 并行数据输出
    output wire [DATA_WIDTH-1:0] rx_data,
    // 状态输出
    output reg  lane_align_done,
    output reg  lane_calib_err,
    output reg  [4:0] best_delay_val
);

// 内部信号定义
wire data_ibuf;
wire data_delay;
wire [DATA_WIDTH-1:0] iserdes_q;

// 延迟校准状态机
// [V4修复 LT-11] 增加D_SETTLE状态等待IDELAY输出稳定
localparam D_IDLE      = 3'd0,
           D_SET_DELAY = 3'd1,
           D_SETTLE    = 3'd2,  // V4: 等待IDELAY输出稳定
           D_WAIT      = 3'd3,
           D_SAMPLE    = 3'd4,
           D_CALC_WIN  = 3'd5,
           D_DONE      = 3'd6;
reg [2:0] d_curr_state;
reg [2:0] d_next_state;

// 字对齐状态机
// [V4修复 LT-06/LT-08] 增加W_DONE状态, 对齐成功后保持
// [V6修复 Bug B] 增加W_WAIT_PHASE状态, 等待TX从0x55切换到0xB5再启动BITSLIP
localparam W_IDLE     = 3'd0,
           W_BITSLIP  = 3'd1,
           W_WAIT     = 3'd2,
           W_CHECK    = 3'd3,
           W_DONE     = 3'd4,  // V4: 对齐成功后保持状态
           W_WAIT_PHASE = 3'd5; // V6: 等待TX切换到0xB5码型
reg [2:0] w_curr_state;
reg [2:0] w_next_state;

// IDELAY控制信号
reg  delay_ce;
reg  delay_inc;
reg  delay_ld;
reg  [4:0] delay_cnt_val;
wire [4:0] delay_cur_val;

// 延迟扫描计数器
reg  [4:0] scan_step;
reg  [4:0] sample_cnt;
reg        sample_valid;
reg  [3:0] sample_err_cnt;  // 采样错误计数
localparam SAMPLE_ERR_TOLERANCE = 4'd2; // 允许2次错误
reg  [31:0] valid_window;
reg         scan_done;
reg         delay_win_valid;   // 延迟窗口查找组合结果
reg  [4:0]  best_delay_comb;   // 最佳延迟值组合结果

// [V4修复 LT-11] IDELAY稳定等待计数器
reg [2:0] settle_cnt;
localparam SETTLE_CYCLES = 3'd3; // 等待3个周期确保IDELAY输出稳定

// 字对齐信号
reg        bitslip_req;
reg  [3:0] bitslip_wait;       // V4: 扩展为4位以容纳BITSLIP_WAIT_CYCLES
reg  [7:0] align_check_cnt;
reg  [3:0] bitslip_cnt;
localparam MAX_BITSLIP = 4'd8;
localparam BITSLIP_WAIT_CYCLES = 4'd5; // BITSLIP后等待ISERDESE2稳定

// [V4修复 LT-08] 信号质量监测——连续非0xB5计数
reg [7:0] bad_word_cnt;
localparam BAD_WORD_THRESHOLD = 8'd32; // 连续32拍非0xB5则判定信号恶化

// [V4修复 LT-06] scan_done上升沿检测
reg scan_done_prev;

// [V6修复 Bug A] 延迟扫描完成标志, 阻止D_DONE后立即重启扫描
reg d_scan_complete;

// [V6修复 Bug B] 字对齐等待TX切换到0xB5的计数器
reg [15:0] align_wait_cnt;
localparam ALIGN_WAIT_CYCLES = 16'd4000; // 与TX的TRAIN_CALIB_DURATION匹配



// IDELAY控制单元，每个IO Bank例化一个
// wire idelayctrl_rdy;
// IDELAYCTRL u_idelayctrl (
    // .RDY    (idelayctrl_rdy),  // 校准就绪标志
    // .REFCLK (ref_clk_200m),    // 200MHz参考时钟
    // .RST    (~rst_n)           // 高有效复位
// );



// 差分输入缓冲
IBUFDS #(
      .DIFF_TERM("FALSE"),       // Differential Termination
      .IBUF_LOW_PWR("FALSE"),     // Low power="TRUE", Highest performance="FALSE" 
      .IOSTANDARD("DEFAULT")     // Specify the input I/O standard
) u_ibufds_data (
    .I(lvds_data_p), 
    .IB(lvds_data_n), 
    .O(data_ibuf)
);

// 输入延迟单元
IDELAYE2 #(
    .CINVCTRL_SEL("FALSE"),          // Enable dynamic clock inversion (FALSE, TRUE)
    .DELAY_SRC("IDATAIN"),           // Delay input (IDATAIN, DATAIN)
    .HIGH_PERFORMANCE_MODE("FALSE"), // Reduced jitter ("TRUE"), Reduced power ("FALSE")
    .IDELAY_TYPE("VAR_LOAD"),           // FIXED, VARIABLE, VAR_LOAD, VAR_LOAD_PIPE
    .IDELAY_VALUE(0),                // Input delay tap setting (0-31)
    .PIPE_SEL("FALSE"),              // Select pipelined mode, FALSE, TRUE
    .REFCLK_FREQUENCY(200.0),        // IDELAYCTRL clock input frequency in MHz (190.0-210.0, 290.0-310.0).
    .SIGNAL_PATTERN("DATA")          // DATA, CLOCK input signal
) u_idelay_data (
    .IDATAIN    (data_ibuf),
    .DATAOUT    (data_delay),
    .C          (clk_div),
    .CE         (delay_ce),
    .CINVCTRL   (1'b0 ), // 1-bit input: Dynamic clock inversion input
    .INC        (delay_inc),
    .LD         (delay_ld ),
    // .LD         (1'b1),
    .LDPIPEEN   (1'b0),
    .CNTVALUEIN (delay_cnt_val),
    .CNTVALUEOUT(delay_cur_val),
    .DATAIN     (1'b0),
    .REGRST     (~rst_n)
);


// 解串器
ISERDESE2 #(
    .DATA_RATE          ("DDR"),
    .DATA_WIDTH         (DATA_WIDTH),
    .DYN_CLKDIV_INV_EN  ("FALSE"),
    .DYN_CLK_INV_EN     ("FALSE"),
    .INIT_Q1            (1'b0), 
    .INIT_Q2            (1'b0), 
    .INIT_Q3            (1'b0), 
    .INIT_Q4            (1'b0),
    .INTERFACE_TYPE     ("NETWORKING"),
    .IOBDELAY           ("IFD"),
    //.IOBDELAY           ("IBUF"),
    .NUM_CE             (2),
    .OFB_USED           ("FALSE"),
    .SERDES_MODE        ("MASTER"),
    .SRVAL_Q1           (1'b0), 
    .SRVAL_Q2           (1'b0), 
    .SRVAL_Q3           (1'b0), 
    .SRVAL_Q4           (1'b0)
) u_iserdes_data (
    .O(O),                       // 1-bit output: Combinatorial output
      // Q1 - Q8: 1-bit (each) output: Registered data outputs
    .Q1(iserdes_q[0]), 
    .Q2(iserdes_q[1]), 
    .Q3(iserdes_q[2]), 
    .Q4(iserdes_q[3]),
    .Q5(iserdes_q[4]), 
    .Q6(iserdes_q[5]), 
    .Q7(iserdes_q[6]), 
    .Q8(iserdes_q[7]),
    .SHIFTOUT1 (), 
    .SHIFTOUT2 (),
    .BITSLIP  (bitslip_req),
    // .BITSLIP  (1'b0),
    .CE1      (1'b1), 
    .CE2      (1'b1),
    .CLKDIVP  (1'b0),
    .CLK      (clk_bufio),
    .CLKB     (~clk_bufio),
    .CLKDIV   (clk_div),
    .OCLK     (1'b0), 
    .OCLKB    (1'b0),
    .D        (data_ibuf),
    .DDLY     (data_delay),
    .OFB      (1'b0),
    .RST      (~rst_n),
    .SHIFTIN1 (1'b0), 
    .SHIFTIN2(1'b0),
    .DYNCLKDIVSEL(1'b0),
    .DYNCLKSEL   (1'b0)
);

assign rx_data = iserdes_q;

// 延迟窗口查找组合逻辑（供D_CALC_WIN状态和lane_calib_err独立块共用）
always @(*) begin : calc_delay_window
    reg [4:0] curr_start, curr_len, max_start, max_len;
    integer i;
    curr_start = 5'd0; curr_len = 5'd0;
    max_start  = 5'd0; max_len  = 5'd0;
    for(i = 0; i < 32; i = i + 1) begin
        if(valid_window[i]) begin
            if(curr_len == 0) curr_start = i[4:0];
            curr_len = curr_len + 1'b1;
            if(curr_len > max_len) begin
                max_len = curr_len;
                max_start = curr_start;
            end
        end else begin
            curr_len = 5'd0;
        end
    end
    delay_win_valid = (max_len >= MIN_WIN_SIZE);
    best_delay_comb = max_start + (max_len >> 1);
end

// 延迟校准状态机（三段式）
always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n) d_curr_state <= D_IDLE;
    else d_curr_state <= d_next_state;
end

always @(*) begin
    d_next_state = d_curr_state;
    case(d_curr_state)
        D_IDLE:      if(~lane_align_done & ~retrain_req & ~d_scan_complete) d_next_state = D_SET_DELAY;
        D_SET_DELAY: d_next_state = D_SETTLE;
        D_SETTLE:    if(settle_cnt >= SETTLE_CYCLES) d_next_state = D_WAIT;  // V4: 等待IDELAY稳定
        D_WAIT:      if(sample_cnt >= SAMPLE_CNT) d_next_state = D_SAMPLE;  // V4: 修正为>=SAMPLE_CNT, 采样16次
        D_SAMPLE:    d_next_state = (scan_step >= DELAY_STEPS - 1) ? D_CALC_WIN : D_SET_DELAY;
        D_CALC_WIN:  d_next_state = D_DONE;
        D_DONE:      d_next_state = D_IDLE;
        default:     d_next_state = D_IDLE;
    endcase
    if(retrain_req) d_next_state = D_IDLE;
end

always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n) begin
        delay_ce <= 1'b0;
        delay_inc <= 1'b0;
        delay_ld <= 1'b0;
        delay_cnt_val <= 5'd0;
        scan_step <= 5'd0;
        sample_cnt <= 5'd0;
        sample_valid <= 1'b1;
        sample_err_cnt <= 4'd0;
        valid_window <= 32'd0;
        scan_done <= 1'b0;
        best_delay_val <= 5'd0;
        settle_cnt <= 3'd0;
        d_scan_complete <= 1'b0;  // [V6修复 Bug A]
    end else begin
        delay_ce <= 1'b0;
        delay_ld <= 1'b0;
        scan_done <= 1'b0;
        case(d_curr_state)
            D_IDLE: begin
                scan_step <= 5'd0;
                sample_cnt <= 5'd0;
                valid_window <= 32'd0;
                settle_cnt <= 3'd0;
            end
            D_SET_DELAY: begin
                delay_cnt_val <= scan_step;
                delay_ld <= 1'b1;
                sample_cnt <= 5'd0;
                sample_valid <= 1'b1;
                sample_err_cnt <= 4'd0;
                settle_cnt <= 3'd0;
            end
            // [V4修复 LT-11] D_SETTLE: 等待IDELAY输出稳定后再采样
            D_SETTLE: begin
                settle_cnt <= settle_cnt + 1'b1;
            end
            // [V4修复 LT-11] D_WAIT: 采样SAMPLE_CNT次, 容错改为统计总错误数
            D_WAIT: begin
                sample_cnt <= sample_cnt + 1'b1;
                if(iserdes_q != 8'h55) begin
                    sample_err_cnt <= sample_err_cnt + 1'b1;
                end
            end
            // [V4修复 LT-11] D_SAMPLE: 统计总错误数判定, 而非先错即弃
            D_SAMPLE: begin
                valid_window[scan_step] <= (sample_err_cnt <= SAMPLE_ERR_TOLERANCE);
                // [V5-DEBUG] 跟踪每个tap的采样结果
                $display("[%0t] LANE_PHY D_SAMPLE: scan_step=%0d iserdes_q=%h sample_err_cnt=%0d valid=%b", $time, scan_step, iserdes_q, sample_err_cnt, (sample_err_cnt <= SAMPLE_ERR_TOLERANCE));
                scan_step <= scan_step + 1'b1;
            end
            D_CALC_WIN: begin
                best_delay_val <= delay_win_valid ? best_delay_comb : 5'd0;
                // [V5-DEBUG] 打印校准结果
                $display("[%0t] LANE_PHY D_CALC_WIN: win_valid=%b best_delay=%0d valid_window=%h", $time, delay_win_valid, best_delay_comb, valid_window);
            end
            D_DONE: begin
                scan_done <= 1'b1;
                delay_cnt_val <= best_delay_val;
                delay_ld <= 1'b1;
                d_scan_complete <= 1'b1;  // [V6修复 Bug A] 标记扫描完成, 阻止重启
                // [V5-DEBUG] 打印最终延迟值
                $display("[%0t] LANE_PHY D_DONE: best_delay_val=%0d", $time, best_delay_val);
            end
            default: ;
        endcase

        if(retrain_req) begin
            scan_done <= 1'b0;
            d_scan_complete <= 1'b0;  // [V6修复 Bug A] retrain时清除, 允许重新扫描
        end
    end
end

// 字对齐状态机（三段式）
always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n) w_curr_state <= W_IDLE;
    else w_curr_state <= w_next_state;
end

always @(*) begin
    w_next_state = w_curr_state;
    case(w_curr_state)
        W_IDLE:    if(scan_done & ~lane_calib_err) w_next_state = W_WAIT_PHASE;  // V6: 先等待TX切换码型
        // [V6修复 Bug B] W_WAIT_PHASE: 等待TX从0x55切换到0xB5后再开始BITSLIP
        // 否则BITSLIP会在TX仍发0x55时启动, 8次尝试全部失败
        W_WAIT_PHASE: if(align_wait_cnt >= ALIGN_WAIT_CYCLES) w_next_state = W_BITSLIP;
        W_BITSLIP: w_next_state = W_WAIT;
        W_WAIT:    if(bitslip_wait >= BITSLIP_WAIT_CYCLES) w_next_state = W_CHECK;
        W_CHECK: begin
            if(align_check_cnt >= 8'd16)
                w_next_state = W_DONE;  // V4: 对齐成功进W_DONE而非W_IDLE
            else if(iserdes_q != 8'hB5) begin
                if(bitslip_cnt >= MAX_BITSLIP)
                    w_next_state = W_IDLE;  // 溢出，放弃对齐
                else
                    w_next_state = W_BITSLIP;
            end
        end
        // [V4修复 LT-08] W_DONE: 对齐成功后保持, 仅retrain/err/信号恶化时退出
        W_DONE: begin
            if(training_mode && bad_word_cnt >= BAD_WORD_THRESHOLD)
                w_next_state = W_IDLE;  // 训练期间信号恶化, 重新对齐
        end
        default: w_next_state = W_IDLE;
    endcase
    if(retrain_req | lane_calib_err) w_next_state = W_IDLE;
end

always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n) begin
        bitslip_req <= 1'b0;
        bitslip_wait <= 4'd0;
        align_check_cnt <= 8'd0;
        bitslip_cnt <= 4'd0;
        lane_align_done <= 1'b0;
        bad_word_cnt <= 8'd0;
        align_wait_cnt <= 16'd0;  // V6: 复位等待计数器
    end else begin
        bitslip_req <= 1'b0;

        case(w_curr_state)
            W_IDLE: begin
                align_check_cnt <= 8'd0;
                bitslip_wait <= 4'd0;
                bad_word_cnt <= 8'd0;
                align_wait_cnt <= 16'd0;  // V6: 复位等待计数器
                // [V4修复 LT-06] bitslip_cnt在scan_done上升沿清零
                if(scan_done & ~scan_done_prev)
                    bitslip_cnt <= 4'd0;
            end
            // [V6修复 Bug B] W_WAIT_PHASE: 计数等待TX切换到0xB5码型
            W_WAIT_PHASE: begin
                align_wait_cnt <= align_wait_cnt + 1'b1;
            end
            W_BITSLIP: begin
                bitslip_req <= 1'b1;
                bitslip_cnt <= bitslip_cnt + 1'b1;
                lane_align_done <= 1'b0;  // 重新对齐时清除已对齐标志
                bad_word_cnt <= 8'd0;
            end
            W_WAIT: begin
                bitslip_wait <= bitslip_wait + 1'b1;
            end
            W_CHECK: begin
                bitslip_wait <= 4'd0;
                if(iserdes_q == 8'hB5) begin
                    align_check_cnt <= align_check_cnt + 1'b1;
                end else begin
                    align_check_cnt <= 8'd0;
                end
            end
            // [V4修复 LT-08] W_DONE: 仅训练期间监测信号质量
            W_DONE: begin
                if(training_mode) begin
                    if(iserdes_q == 8'hB5) begin
                        bad_word_cnt <= 8'd0;
                    end else begin
                        bad_word_cnt <= bad_word_cnt + 1'b1;
                    end
                    if(bad_word_cnt >= BAD_WORD_THRESHOLD) begin
                        lane_align_done <= 1'b0;
                    end
                end else begin
                    bad_word_cnt <= 8'd0;
                end
            end
            default: ;
        endcase

        if(align_check_cnt >= 8'd16) begin
            lane_align_done <= 1'b1;
            // [V6-DEBUG] 打印字对齐完成信息: BITSLIP次数和最佳延迟值
            if(!lane_align_done)
                $display("[%0t] LANE_PHY W_DONE: bitslip_cnt=%0d best_delay=%0d iserdes_q=%h", $time, bitslip_cnt, best_delay_val, iserdes_q);
        end

        if(retrain_req) begin
            lane_align_done <= 1'b0;
            bitslip_cnt <= 4'd0;
            bad_word_cnt <= 8'd0;
            align_wait_cnt <= 16'd0;  // V6: 重训练时复位等待计数器
        end
    end
end

// [V4修复 LT-06] scan_done上升沿检测, 用于在W_IDLE中清零bitslip_cnt
always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n)
        scan_done_prev <= 1'b0;
    else
        scan_done_prev <= scan_done;
end

// lane_calib_err 集中管理（独立always块）
// 清零：复位 / retrain_req / D_IDLE(新一轮扫描)
// 置位：D_CALC_WIN窗口不足 / W_CHECK bitslip溢出
always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n)
        lane_calib_err <= 1'b0;
    else if(retrain_req)
        lane_calib_err <= 1'b0;
    else if(d_curr_state == D_IDLE)
        lane_calib_err <= 1'b0;
    else if(d_curr_state == D_CALC_WIN)
        lane_calib_err <= ~delay_win_valid;
    else if(w_curr_state == W_CHECK && iserdes_q != 8'hB5 && bitslip_cnt >= MAX_BITSLIP)
        lane_calib_err <= 1'b1;
end

endmodule
