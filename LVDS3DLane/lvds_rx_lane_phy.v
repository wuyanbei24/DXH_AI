`timescale 1ns / 1ps
//============================================================================
// Module: lvds_rx_lane_phy
// Description: 单路LVDS接收物理层子模块
//   - 封装单路LVDS接收的完整物理层校准逻辑
//   - 每通道独立执行延迟扫描与字对齐
//   - IDELAYE2延迟校准 + ISERDESE2解串 + BITSLIP字对齐
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
localparam D_IDLE     = 3'd0,
           D_SET_DELAY= 3'd1,
           D_WAIT     = 3'd2,
           D_SAMPLE   = 3'd3,
           D_CALC_WIN = 3'd4,
           D_DONE     = 3'd5;
reg [2:0] d_curr_state;
reg [2:0] d_next_state;

// 字对齐状态机
localparam W_IDLE     = 2'd0,
           W_BITSLIP  = 2'd1,
           W_WAIT     = 2'd2,
           W_CHECK    = 2'd3;
reg [1:0] w_curr_state;
reg [1:0] w_next_state;

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
reg  [3:0] sample_err_cnt;  // N-11: 采样错误计数
localparam SAMPLE_ERR_TOLERANCE = 4'd2; // 允许2次错误
reg  [31:0] valid_window;
reg         scan_done;
reg         delay_win_valid;   // 延迟窗口查找组合结果
reg  [4:0]  best_delay_comb;   // 最佳延迟值组合结果

// 字对齐信号
reg        bitslip_req;
reg        bitslip_wait;
reg  [7:0] align_check_cnt;
reg  [3:0] bitslip_cnt;
localparam MAX_BITSLIP = 4'd8;



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
        D_IDLE:     if(~lane_align_done & ~retrain_req) d_next_state = D_SET_DELAY;
        D_SET_DELAY:d_next_state = D_WAIT;
        D_WAIT:     if(sample_cnt >= SAMPLE_CNT-1) d_next_state = D_SAMPLE;
        D_SAMPLE:   d_next_state = (scan_step >= DELAY_STEPS - 1) ? D_CALC_WIN : D_SET_DELAY;
        D_CALC_WIN: d_next_state = D_DONE;
        D_DONE:     d_next_state = D_IDLE;
        default:    d_next_state = D_IDLE;
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
        valid_window <= 32'd0;
        scan_done <= 1'b0;
        best_delay_val <= 5'd0;
    end else begin
        delay_ce <= 1'b0;
        delay_ld <= 1'b0;
        scan_done <= 1'b0;
        case(d_curr_state)
            D_IDLE: begin
                scan_step <= 5'd0;
                sample_cnt <= 5'd0;
                valid_window <= 32'd0;
            end
            D_SET_DELAY: begin
                delay_cnt_val <= scan_step;
                delay_ld <= 1'b1;
                sample_cnt <= 5'd0;
                sample_valid <= 1'b1;
                sample_err_cnt <= 4'd0;
            end
            D_WAIT: begin
                sample_cnt <= sample_cnt + 1'b1;
                if(iserdes_q != 8'h55) begin
                    sample_err_cnt <= sample_err_cnt + 1'b1;
                    if(sample_err_cnt >= SAMPLE_ERR_TOLERANCE)
                        sample_valid <= 1'b0;
                end
            end
            D_SAMPLE: begin
                valid_window[scan_step] <= sample_valid;
                scan_step <= scan_step + 1'b1;
            end
            D_CALC_WIN: begin
                best_delay_val <= delay_win_valid ? best_delay_comb : 5'd0;
            end
            D_DONE: begin
                scan_done <= 1'b1;
                delay_cnt_val <= best_delay_val;
                delay_ld <= 1'b1;
            end
            default: ;
        endcase

        if(retrain_req) begin
            scan_done <= 1'b0;
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
        W_IDLE:    if(scan_done & ~lane_calib_err) w_next_state = W_BITSLIP;
        W_BITSLIP: w_next_state = W_WAIT;
        W_WAIT:    if(bitslip_wait) w_next_state = W_CHECK;
        W_CHECK: begin
            if(align_check_cnt >= 8'd16)
                w_next_state = W_IDLE;
            else if(iserdes_q != 8'hB5) begin
                if(bitslip_cnt >= MAX_BITSLIP)
                    w_next_state = W_IDLE;  // 溢出，放弃对齐
                else
                    w_next_state = W_BITSLIP;
            end
        end
        default: w_next_state = W_IDLE;
    endcase
    if(retrain_req | lane_calib_err) w_next_state = W_IDLE;
end

always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n) begin
        bitslip_req <= 1'b0;
        bitslip_wait <= 1'b0;
        align_check_cnt <= 8'd0;
        bitslip_cnt <= 4'd0;
        lane_align_done <= 1'b0;
    end else begin
        bitslip_req <= 1'b0;

        case(w_curr_state)
            W_IDLE: begin
                align_check_cnt <= 8'd0;
                bitslip_wait <= 1'b0;
                // bitslip_cnt不在此清零，保留用于溢出检测
            end
            W_BITSLIP: begin
                bitslip_req <= 1'b1;
                bitslip_cnt <= bitslip_cnt + 1'b1;
                lane_align_done <= 1'b0;  // R-03: 重新对齐时清除已对齐标志
            end
            W_WAIT: begin
                bitslip_wait <= bitslip_wait + 1'b1;
            end
            W_CHECK: begin
                bitslip_wait <= 1'b0;
                if(iserdes_q == 8'hB5) begin
                    align_check_cnt <= align_check_cnt + 1'b1;
                end else begin
                    align_check_cnt <= 8'd0;
                end
            end
            default: ;
        endcase

        if(align_check_cnt >= 8'd16) begin
            lane_align_done <= 1'b1;
        end

        if(retrain_req) begin
            lane_align_done <= 1'b0;
            bitslip_cnt <= 4'd0;
        end
    end
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
