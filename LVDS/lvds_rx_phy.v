`timescale 1ns / 1ps

module lvds_rx_phy #(
    parameter DATA_WIDTH    = 8,
    parameter DELAY_STEPS   = 32,
    parameter SAMPLE_CNT    = 16,
    parameter MIN_WIN_SIZE  = 4
)(
    input  wire rst_n,

    // LVDS差分输入
    input  wire lvds_clk_p,
    input  wire lvds_clk_n,
    input  wire lvds_data_p,
    input  wire lvds_data_n,

    // 【修正问题3】IDELAY参考时钟（200MHz）
    input  wire ref_clk_200m,

    // 控制接口
    input  wire retrain_req,

    // 并行数据输出
    output wire [DATA_WIDTH-1:0] rx_data,
    output wire                    rx_data_valid,

    // 状态输出
    output reg  phy_ready,
    output reg  align_err,
    output reg  [4:0] best_delay_val,
    output wire clk_div
);

// ==================================================
// 主训练状态机定义
// ==================================================
localparam M_IDLE       = 3'd0,
           M_DELAY_SCAN = 3'd1,
           M_BIT_ALIGN  = 3'd2,
           M_WORD_ALIGN = 3'd3,
           M_LOCK_CHECK = 3'd4,
           M_NORMAL     = 3'd5,
           M_FAULT      = 3'd6;

reg [2:0] m_curr_state;
reg [2:0] m_next_state;

// 延迟校准状态机定义
localparam D_IDLE     = 3'd0,
           D_SET_DELAY= 3'd1,
           D_WAIT     = 3'd2,
           D_SAMPLE   = 3'd3,
           D_CALC_WIN = 3'd4,
           D_DONE     = 3'd5;

reg [2:0] d_curr_state;
reg [2:0] d_next_state;

// 内部信号
wire clk_bufio;
wire clk_ibuf;
wire data_ibuf;
wire data_delay;
wire [DATA_WIDTH-1:0] iserdes_q;

reg  delay_ce;
reg  delay_inc;
reg  delay_ld;
reg  [4:0] delay_cnt_val;
wire [4:0] delay_cur_val;

// 【修正问题4】sample_cnt 改为5位，可表示0~31
reg  [4:0] sample_cnt;
reg        sample_valid;
reg  [31:0] valid_window;
reg  [4:0]  scan_step;
reg         scan_start;
reg         scan_done;

// 【修正问题13】BITSLIP单周期脉冲控制
reg  [3:0] bitslip_cnt;
reg         bitslip_req;
reg         bitslip_wait;       // BITSLIP后稳定等待计数器
reg  [7:0] align_check_cnt;
reg  [15:0] lock_timer;
// 重试计数器（单一驱动源，见下方专用always块）
reg  [1:0]  retry_cnt;
localparam MAX_RETRY = 2'd3;

// 【修正问题14】锁定检查多次采样投票
reg [7:0] lock_match_cnt;
localparam LOCK_CHECK_CYCLES = 16'd5000;
localparam LOCK_VOTE_THRESHOLD = 8'd200;  // 5000次中至少200次匹配

// 差分输入缓冲
IBUFDS #(.DIFF_TERM("TRUE"), .IOSTANDARD("LVDS_25")) u_ibufds_data (
    .I(lvds_data_p), .IB(lvds_data_n), .O(data_ibuf)
);
IBUFDS #(.DIFF_TERM("TRUE"), .IOSTANDARD("LVDS_25")) u_ibufds_clk (
    .I(lvds_clk_p), .IB(lvds_clk_n), .O(clk_ibuf)
);

// ==================================================
// IDELAYCTRL 原语 — IDELAYE2正常工作必须
// ==================================================
wire idelay_rdy;
IDELAYCTRL u_idelayctrl (
    .REFCLK (ref_clk_200m),
    .RST    (~rst_n),
    .RDY    (idelay_rdy)
);

// IDELAYE2 输入延迟单元
IDELAYE2 #(
    .IDELAY_TYPE    ("VARIABLE"),
    .DELAY_SRC      ("IDATAIN"),
    .IDELAY_VALUE   (0),
    .REFCLK_FREQUENCY(200.0),
    .HIGH_PERFORMANCE_MODE("TRUE")
) u_idelay_data (
    .IDATAIN    (data_ibuf),
    .DATAOUT    (data_delay),
    .C          (clk_div),
    .CE         (delay_ce),
    .INC        (delay_inc),
    .LD         (delay_ld),
    .LDPIPEEN   (1'b0),
    .CNTVALUEIN (delay_cnt_val),
    .CNTVALUEOUT(delay_cur_val),
    .DATAIN     (1'b0),
    .CINVCTRL   (1'b0),
    .REGRST     (~rst_n)
);

// ==================================================
// 时钟缓冲
// 【修正问题2】BUFR_DIVIDE 从"8"改为"4"
// DDR + DATA_WIDTH=8 要求 CLKDIV = CLK/4
// ==================================================
BUFIO u_bufio_clk (.I(clk_ibuf), .O(clk_bufio));
BUFR #(.BUFR_DIVIDE("4"), .SIM_DEVICE("7SERIES")) u_bufr_div (
    .I(clk_ibuf), .O(clk_div), .CE(1'b1), .CLR(~rst_n)
);

// ISERDESE2 解串器
// 【修正】IOBDELAY="IFD"时，IDELAYE2输出必须接DDLY端口，D端口接IBUF直通
ISERDESE2 #(
    .DATA_RATE          ("DDR"),
    .DATA_WIDTH         (DATA_WIDTH),
    .DYN_CLKDIV_INV_EN  ("FALSE"),
    .DYN_CLK_INV_EN     ("FALSE"),
    .INIT_Q1            (1'b0), .INIT_Q2(1'b0), .INIT_Q3(1'b0), .INIT_Q4(1'b0),
    .INTERFACE_TYPE     ("NETWORKING"),
    .IOBDELAY           ("IFD"),      // 使用IDELAYE2延迟路径，数据从DDLY进入
    .NUM_CE             (1),
    .OFB_USED           ("FALSE"),
    .SERDES_MODE        ("MASTER"),
    .SRVAL_Q1           (1'b0), .SRVAL_Q2(1'b0), .SRVAL_Q3(1'b0), .SRVAL_Q4(1'b0)
) u_iserdes_data (
    .Q1(iserdes_q[0]), .Q2(iserdes_q[1]), .Q3(iserdes_q[2]), .Q4(iserdes_q[3]),
    .Q5(iserdes_q[4]), .Q6(iserdes_q[5]), .Q7(iserdes_q[6]), .Q8(iserdes_q[7]),
    .SHIFTOUT1 (), .SHIFTOUT2 (),
    .BITSLIP  (bitslip_req),
    .CE1      (1'b1), .CE2(1'b1),
    .CLKDIVP  (1'b0),
    .CLK      (clk_bufio),
    .CLKB     (~clk_bufio),
    .CLKDIV   (clk_div),
    .OCLK     (1'b0), .OCLKB(1'b0),
    .D        (data_ibuf),     // 【修正】IBUF直通数据接D端口
    .DDLY     (data_delay),    // 【修正】IDELAYE2输出接DDLY端口（IFD模式数据从此进入）
    .OFB      (1'b0),
    .RST      (~rst_n),
    .SHIFTIN1 (1'b0), .SHIFTIN2(1'b0),
    .DYNCLKDIVSEL(1'b0),
    .DYNCLKSEL   (1'b0)
);

assign rx_data = iserdes_q;
assign rx_data_valid = phy_ready;

// ==================================================
// 主训练状态机 - 三段式
// ==================================================
always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n) m_curr_state <= M_IDLE;
    else m_curr_state <= m_next_state;
end

always @(*) begin
    m_next_state = m_curr_state;
    case(m_curr_state)
        M_IDLE:       if(idelay_rdy) m_next_state = M_DELAY_SCAN;  // 等待IDELAYCTRL就绪
        M_DELAY_SCAN: if(scan_done) m_next_state = (|best_delay_val) ? M_BIT_ALIGN : M_FAULT;
        M_BIT_ALIGN:  m_next_state = M_WORD_ALIGN;
        M_WORD_ALIGN: if(align_check_cnt >= 8'd16) m_next_state = M_LOCK_CHECK;
        // 【修正问题14】锁定检查：多次采样投票，匹配次数超阈值才进入NORMAL
        M_LOCK_CHECK: if(lock_timer >= LOCK_CHECK_CYCLES)
                          m_next_state = (lock_match_cnt >= LOCK_VOTE_THRESHOLD) ? M_NORMAL : M_FAULT;
        M_NORMAL:     if(retrain_req) m_next_state = M_IDLE;
        M_FAULT:      if(retry_cnt < MAX_RETRY) m_next_state = M_IDLE;
        default:      m_next_state = M_IDLE;
    endcase
end

always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n) begin
        phy_ready <= 1'b0;
        align_err <= 1'b0;
        scan_start <= 1'b0;
        lock_timer <= 16'd0;
        align_check_cnt <= 8'd0;
        bitslip_req <= 1'b0;
        bitslip_cnt <= 4'd0;
        bitslip_wait <= 1'b0;
        lock_match_cnt <= 8'd0;
    end else begin
        // 【修正问题13】BITSLIP单周期脉冲：默认拉低
        bitslip_req <= 1'b0;

        case(m_curr_state)
            M_IDLE: begin
                phy_ready <= 1'b0;
                align_err <= 1'b0;
                scan_start <= 1'b1;
                lock_timer <= 16'd0;
                align_check_cnt <= 8'd0;
                bitslip_cnt <= 4'd0;
                bitslip_wait <= 1'b0;
                lock_match_cnt <= 8'd0;
            end
            M_DELAY_SCAN: begin
                scan_start <= 1'b0;
            end
            M_BIT_ALIGN: begin
                bitslip_cnt <= 4'd0;
                align_check_cnt <= 8'd0;
                bitslip_wait <= 1'b0;
            end
            // 【修正问题13】BITSLIP单周期脉冲 + 稳定等待
            M_WORD_ALIGN: begin
                if(bitslip_wait) begin
                    // 等待ISERDESE2稳定（2拍）
                    bitslip_wait <= bitslip_wait + 1'b1;
                    if(bitslip_wait == 1'b1) begin
                        bitslip_wait <= 1'b0;
                        // 稳定后采样判断
                        if(iserdes_q == 8'hB5) begin
                            align_check_cnt <= align_check_cnt + 1'b1;
                        end else begin
                            align_check_cnt <= 8'd0;
                            bitslip_cnt <= bitslip_cnt + 1'b1;
                        end
                    end
                end else begin
                    if(iserdes_q == 8'hB5) begin
                        align_check_cnt <= align_check_cnt + 1'b1;
                    end else begin
                        align_check_cnt <= 8'd0;
                        bitslip_cnt <= bitslip_cnt + 1'b1;
                        // 产生单周期BITSLIP脉冲
                        bitslip_req <= 1'b1;
                        bitslip_wait <= 1'b1;
                    end
                end
            end
            // 【修正问题14】锁定检查：统计匹配次数，投票判定
            M_LOCK_CHECK: begin
                lock_timer <= lock_timer + 1'b1;
                if(iserdes_q == 8'hB5) begin
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

// ==================================================
// 重试计数器（单一驱动源）
// 在M_IDLE→M_DELAY_SCAN跳转时递增，复位或成功链接时清零
// ==================================================
always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n)
        retry_cnt <= 2'd0;
    else if(m_curr_state == M_NORMAL)
        retry_cnt <= 2'd0;
    else if(m_curr_state == M_IDLE && m_next_state == M_DELAY_SCAN)
        retry_cnt <= retry_cnt + 1'b1;
end

// ==================================================
// 延迟校准状态机 - 三段式
// ==================================================
always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n) d_curr_state <= D_IDLE;
    else d_curr_state <= d_next_state;
end

always @(*) begin
    d_next_state = d_curr_state;
    case(d_curr_state)
        D_IDLE:     if(scan_start) d_next_state = D_SET_DELAY;
        D_SET_DELAY:d_next_state = D_WAIT;
        // 【修正问题4】比较改为 >= SAMPLE_CNT-1（5位计数器可正确表示16）
        D_WAIT:     if(sample_cnt >= SAMPLE_CNT-1) d_next_state = D_SAMPLE;
        D_SAMPLE:   d_next_state = (scan_step >= DELAY_STEPS - 1) ? D_CALC_WIN : D_SET_DELAY;
        D_CALC_WIN: d_next_state = D_DONE;
        D_DONE:     if(!scan_start) d_next_state = D_IDLE;
        default:    d_next_state = D_IDLE;
    endcase
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

        case(d_curr_state)
            D_IDLE: begin
                scan_step <= 5'd0;
                sample_cnt <= 5'd0;
                valid_window <= 32'd0;
                scan_done <= 1'b0;
                best_delay_val <= 5'd0;
            end
            D_SET_DELAY: begin
                delay_cnt_val <= scan_step;
                delay_ld <= 1'b1;
                sample_cnt <= 5'd0;
                sample_valid <= 1'b1;
            end
            // 【修正问题4】sample_cnt为5位，可正确计数到16
            D_WAIT: begin
                sample_cnt <= sample_cnt + 1'b1;
                if(iserdes_q != 8'h55) sample_valid <= 1'b0;
            end
            D_SAMPLE: begin
                valid_window[scan_step] <= sample_valid;
                scan_step <= scan_step + 1'b1;
            end
            D_CALC_WIN: begin
                begin : find_max_window
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

                    if(max_len >= MIN_WIN_SIZE)
                        best_delay_val <= max_start + (max_len >> 1);
                    else
                        best_delay_val <= 5'd0;
                end
            end
            D_DONE: begin
                scan_done <= 1'b1;
                delay_cnt_val <= best_delay_val;
                delay_ld <= 1'b1;
            end
            default: ;
        endcase
    end
end

endmodule
