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

// 主训练状态机定义
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

reg  [3:0] sample_cnt;
reg        sample_valid;
reg  [31:0] valid_window;
reg  [4:0]  scan_step;
reg         scan_start;
reg         scan_done;

reg  [3:0] bitslip_cnt;
reg         bitslip_req;
reg  [7:0] align_check_cnt;
reg  [15:0] lock_timer;
reg  [1:0]  retry_cnt;
localparam MAX_RETRY = 2'd3;

// 差分输入缓冲
IBUFDS #(.DIFF_TERM("TRUE"), .IOSTANDARD("LVDS_25")) u_ibufds_data (
    .I(lvds_data_p), .IB(lvds_data_n), .O(data_ibuf)
);
IBUFDS #(.DIFF_TERM("TRUE"), .IOSTANDARD("LVDS_25")) u_ibufds_clk (
    .I(lvds_clk_p), .IB(lvds_clk_n), .O(clk_ibuf)
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

// 时钟缓冲
BUFIO u_bufio_clk (.I(clk_ibuf), .O(clk_bufio));
BUFR #(.BUFR_DIVIDE("8"), .SIM_DEVICE("7SERIES")) u_bufr_div (
    .I(clk_ibuf), .O(clk_div), .CE(1'b1), .CLR(~rst_n)
);

// ISERDESE2 解串器
ISERDESE2 #(
    .DATA_RATE     ("DDR"),
    .DATA_WIDTH    (DATA_WIDTH),
    .SERDES_MODE   ("MASTER"),
    .INTERFACE_TYPE("NETWORKING"),
    .NUM_CE        (1),
    .IOBDELAY      ("IFD")
) u_iserdes_data (
    .Q1(iserdes_q[0]), .Q2(iserdes_q[1]), .Q3(iserdes_q[2]), .Q4(iserdes_q[3]),
    .Q5(iserdes_q[4]), .Q6(iserdes_q[5]), .Q7(iserdes_q[6]), .Q8(iserdes_q[7]),
    .BITSLIP  (bitslip_req),
    .CE1      (1'b1), .CE2(1'b1),
    .CLK      (clk_bufio),
    .CLKB     (~clk_bufio),
    .CLKDIV   (clk_div),
    .D        (data_delay),
    .RST      (~rst_n),
    .SHIFTIN1 (1'b0), .SHIFTIN2(1'b0),
    .OCLK     (1'b0), .OCLKB(1'b0), .OFB(1'b0)
);

assign rx_data = iserdes_q;
assign rx_data_valid = phy_ready;

// 主训练状态机 - 三段式
always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n) m_curr_state <= M_IDLE;
    else m_curr_state <= m_next_state;
end

always @(*) begin
    m_next_state = m_curr_state;
    case(m_curr_state)
        M_IDLE:       m_next_state = M_DELAY_SCAN;
        M_DELAY_SCAN: if(scan_done) m_next_state = (|best_delay_val) ? M_BIT_ALIGN : M_FAULT;
        M_BIT_ALIGN:  m_next_state = M_WORD_ALIGN;
        M_WORD_ALIGN: if(align_check_cnt >= 8'd16) m_next_state = M_LOCK_CHECK;
        M_LOCK_CHECK: if(lock_timer >= 16'd5000) m_next_state = (iserdes_q == 8'hB5) ? M_NORMAL : M_FAULT;
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
        retry_cnt <= 2'd0;
        align_check_cnt <= 8'd0;
        bitslip_req <= 1'b0;
        bitslip_cnt <= 4'd0;
    end else begin
        case(m_curr_state)
            M_IDLE: begin
                phy_ready <= 1'b0;
                align_err <= 1'b0;
                scan_start <= 1'b1;
                lock_timer <= 16'd0;
                align_check_cnt <= 8'd0;
                bitslip_cnt <= 4'd0;
            end
            M_DELAY_SCAN: begin
                scan_start <= 1'b0;
                retry_cnt <= retry_cnt + 1'b1;
            end
            M_BIT_ALIGN: begin
                bitslip_cnt <= 4'd0;
                align_check_cnt <= 8'd0;
            end
            M_WORD_ALIGN: begin
                bitslip_req <= 1'b0;
                if(iserdes_q == 8'hB5) begin
                    align_check_cnt <= align_check_cnt + 1'b1;
                end else begin
                    align_check_cnt <= 8'd0;
                    bitslip_req <= 1'b1;
                    bitslip_cnt <= bitslip_cnt + 1'b1;
                end
            end
            M_LOCK_CHECK: lock_timer <= lock_timer + 1'b1;
            M_NORMAL: begin
                phy_ready <= 1'b1;
                align_err <= 1'b0;
                retry_cnt <= 2'd0;
            end
            M_FAULT: begin
                phy_ready <= 1'b0;
                align_err <= 1'b1;
            end
            default: ;
        endcase
    end
end

// 延迟校准状态机 - 三段式
always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n) d_curr_state <= D_IDLE;
    else d_curr_state <= d_next_state;
end

always @(*) begin
    d_next_state = d_curr_state;
    case(d_curr_state)
        D_IDLE:     if(scan_start) d_next_state = D_SET_DELAY;
        D_SET_DELAY:d_next_state = D_WAIT;
        D_WAIT:     if(sample_cnt >= SAMPLE_CNT[3:0]) d_next_state = D_SAMPLE;
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
        sample_cnt <= 4'd0;
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
                sample_cnt <= 4'd0;
                valid_window <= 32'd0;
                scan_done <= 1'b0;
                best_delay_val <= 5'd0;
            end
            D_SET_DELAY: begin
                delay_cnt_val <= scan_step;
                delay_ld <= 1'b1;
                sample_cnt <= 4'd0;
                sample_valid <= 1'b1;
            end
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