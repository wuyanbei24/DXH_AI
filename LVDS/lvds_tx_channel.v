`timescale 1ns / 1ps

module lvds_tx_channel #(
    parameter DATA_WIDTH     = 8,
    parameter SERIAL_FACTOR  = 8,
    parameter CLK_FREQ       = 100_000_000,  // 并行时钟频率
    parameter HEARTBEAT_MS   = 1,
    parameter MAX_PAYLOAD    = 255,
    parameter USER_FIFO_DEPTH= 512
)(
    input  wire clk_ser,       // 串行时钟（从顶层输入）
    input  wire clk_div,       // 并行时钟（从顶层输入）
    input  wire rst_n,

    // 链路管理器控制接口
    input  wire train_en,
    input  wire ctrl_frame_send,
    input  wire [7:0] ctrl_frame_type,
    input  wire [7:0] ctrl_frame_payload,

    // 用户数据接口
    input  wire [DATA_WIDTH-1:0] tx_data_in,
    input  wire                    tx_data_valid,
    output wire                    tx_ready,

    // LVDS差分输出
    output wire lvds_clk_p,
    output wire lvds_clk_n,
    output wire lvds_data_p,
    output wire lvds_data_n
);

// ==================================================
// 内部信号定义
// ==================================================
localparam TX_IDLE=0, TX_SOF1=1, TX_SOF2=2, TX_TYPE=3,
           TX_LEN=4, TX_PAYLOAD=5, TX_CHECKSUM=6;
reg [2:0] tx_curr_state, tx_next_state;
reg [7:0] tx_data_mux;
reg [31:0] heartbeat_timer;
reg [15:0] heartbeat_cnt;
reg heartbeat_pending;
reg [7:0] payload_len, payload_cnt, checksum_reg, tx_type_sel;
reg fifo_rd_en;

wire [7:0]  fifo_dout;
wire        fifo_empty;
wire        fifo_full;
wire [8:0]  fifo_data_cnt;

wire s_data_out, s_clk_out;

localparam FRAME_SOF1=8'hAA, FRAME_SOF2=8'h55;
localparam TYPE_HB=8'h10, TYPE_USR=8'h20;
localparam HEARTBEAT_CNT_MAX = (CLK_FREQ / 1000) * HEARTBEAT_MS;
localparam HEARTBEAT_PAYLOAD_LEN = 8'd2;

// ==================================================
// clk_ser / clk_div 由顶层 MMCM 生成并输入
// DDR + DATA_WIDTH=8 要求 CLK(串行) = 4 × CLKDIV(并行)
// 100MHz 并行 → 400MHz 串行 → 800Mbps 数据率
// ==================================================

// ==================================================
// 【修正问题16】tx_ready 门控优化
// 非训练态且FIFO未满即可写入，发送状态机自行从FIFO读取
// 带宽利用率从 <1/8 提升至接近 100%
// ==================================================
assign tx_ready = ~fifo_full && ~train_en;

// ==================================================
// XPM_FIFO_SYNC 同步FIFO（首字直通模式）
// ==================================================
xpm_fifo_sync #(
    .DOUT_RESET_VALUE    ("0"),
    .ECC_MODE            ("no_ecc"),
    .FIFO_MEMORY_TYPE    ("auto"),
    .FIFO_READ_LATENCY   (0),
    .FIFO_WRITE_DEPTH    (USER_FIFO_DEPTH),
    .FULL_RESET_VALUE    (0),
    .PROG_EMPTY_THRESH   (10),
    .PROG_FULL_THRESH    (10),
    .RD_DATA_COUNT_WIDTH (9),
    .READ_DATA_WIDTH     (DATA_WIDTH),
    .READ_MODE           ("fwft"),
    // .SIM_ASSERT_CHK      (0),
    .USE_ADV_FEATURES    ("0000"),
    .WAKEUP_TIME         (0),
    .WRITE_DATA_WIDTH    (DATA_WIDTH),
    .WR_DATA_COUNT_WIDTH (9)
) u_user_fifo (
    .wr_clk         (clk_div),
    .rst            (~rst_n),
    .wr_en          (tx_data_valid),
    .din            (tx_data_in),
    .full           (fifo_full),
    .wr_data_count  (fifo_data_cnt),

    .rd_en          (fifo_rd_en),
    .dout           (fifo_dout),
    .empty          (fifo_empty),
    .rd_data_count  (),

    .prog_empty     (),
    .prog_full      (),
    .data_valid     (),
    .overflow       (),
    .underflow      (),
    .wr_rst_busy    (),
    .rd_rst_busy    (),
    .injectsbiterr  (1'b0),
    .injectdbiterr  (1'b0),
    .sbiterr        (),
    .dbiterr        ()
);

// ==================================================
// 心跳生成逻辑
// ==================================================
always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n) begin
        heartbeat_timer <= 32'd0;
        heartbeat_cnt   <= 16'd0;
        heartbeat_pending <= 1'b0;
    end else if(~train_en) begin
        heartbeat_timer <= heartbeat_timer + 1'b1;
        if(heartbeat_timer >= HEARTBEAT_CNT_MAX) begin
            heartbeat_timer   <= 32'd0;
            heartbeat_pending <= 1'b1;
            heartbeat_cnt     <= heartbeat_cnt + 1'b1;
        end
        if(tx_curr_state == TX_CHECKSUM && tx_next_state == TX_IDLE && tx_type_sel == TYPE_HB) begin
            heartbeat_pending <= 1'b0;
        end
    end else begin
        heartbeat_timer   <= 32'd0;
        heartbeat_cnt     <= 16'd0;
        heartbeat_pending <= 1'b0;
    end
end

// ==================================================
// 帧调度三段式状态机 - 第一段：状态寄存器
// ==================================================
always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n) tx_curr_state <= TX_IDLE;
    else tx_curr_state <= tx_next_state;
end

// 第二段：次态跳转逻辑
always @(*) begin
    tx_next_state = tx_curr_state;
    if(train_en) begin
        tx_next_state = TX_IDLE;
    end else begin
        case(tx_curr_state)
            TX_IDLE: begin
                if(ctrl_frame_send)          tx_next_state = TX_SOF1;
                else if(~fifo_empty)         tx_next_state = TX_SOF1;
                else if(heartbeat_pending)   tx_next_state = TX_SOF1;
            end
            TX_SOF1:    tx_next_state = TX_SOF2;
            TX_SOF2:    tx_next_state = TX_TYPE;
            TX_TYPE:    tx_next_state = TX_LEN;
            TX_LEN:     tx_next_state = (payload_len == 8'd0) ? TX_CHECKSUM : TX_PAYLOAD;
            TX_PAYLOAD: tx_next_state = (payload_cnt >= payload_len - 1'b1) ? TX_CHECKSUM : TX_PAYLOAD;
            TX_CHECKSUM:tx_next_state = TX_IDLE;
            default:    tx_next_state = TX_IDLE;
        endcase
    end
end

// 第三段：输出与数据控制
always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n) begin
        payload_cnt <= 8'd0;
        payload_len <= 8'd0;
        checksum_reg <= 8'd0;
        tx_type_sel <= 8'd0;
        fifo_rd_en  <= 1'b0;
    end else begin
        fifo_rd_en <= 1'b0;
        case(tx_curr_state)
            TX_IDLE: begin
                payload_cnt <= 8'd0;
                checksum_reg <= 8'd0;
                if(train_en) begin
                    tx_type_sel <= 8'd0;
                    payload_len <= 8'd0;
                end else if(ctrl_frame_send) begin
                    tx_type_sel <= ctrl_frame_type;
                    payload_len <= 8'd1;
                end else if(~fifo_empty) begin
                    tx_type_sel <= TYPE_USR;
                    payload_len <= (fifo_data_cnt > MAX_PAYLOAD) ? MAX_PAYLOAD : fifo_data_cnt[7:0];
                end else if(heartbeat_pending) begin
                    tx_type_sel <= TYPE_HB;
                    payload_len <= HEARTBEAT_PAYLOAD_LEN;
                end
            end

            TX_SOF1: checksum_reg <= FRAME_SOF1;
            TX_SOF2: checksum_reg <= checksum_reg + FRAME_SOF2;
            TX_TYPE: checksum_reg <= checksum_reg + tx_type_sel;

            TX_LEN: begin
                checksum_reg <= checksum_reg + payload_len;
                if(payload_len != 8'd0 && tx_type_sel == TYPE_USR) begin
                    fifo_rd_en <= 1'b1;
                end
            end

            TX_PAYLOAD: begin
                payload_cnt <= payload_cnt + 1'b1;
                case(tx_type_sel)
                    TYPE_USR: begin
                        checksum_reg <= checksum_reg + fifo_dout;
                        fifo_rd_en <= (payload_cnt < payload_len - 1'b1);
                    end
                    TYPE_HB: begin
                        checksum_reg <= checksum_reg + (payload_cnt == 8'd0 ? heartbeat_cnt[15:8] : heartbeat_cnt[7:0]);
                    end
                    default: begin
                        checksum_reg <= checksum_reg + ctrl_frame_payload;
                    end
                endcase
            end

            default: ;
        endcase
    end
end

// ==================================================
// 发送数据多路选择
// ==================================================
always @(*) begin
    if(train_en) begin
        tx_data_mux = 8'h55;
    end else begin
        case(tx_curr_state)
            TX_SOF1:     tx_data_mux = FRAME_SOF1;
            TX_SOF2:     tx_data_mux = FRAME_SOF2;
            TX_TYPE:     tx_data_mux = tx_type_sel;
            TX_LEN:      tx_data_mux = payload_len;
            TX_PAYLOAD: begin
                case(tx_type_sel)
                    TYPE_USR: tx_data_mux = fifo_dout;
                    TYPE_HB:  tx_data_mux = (payload_cnt == 8'd0) ? heartbeat_cnt[15:8] : heartbeat_cnt[7:0];
                    default:  tx_data_mux = ctrl_frame_payload;
                endcase
            end
            TX_CHECKSUM: tx_data_mux = checksum_reg;
            default:     tx_data_mux = 8'h55;
        endcase
    end
end

// ==================================================
// OSERDESE2 数据通道串行化
// ==================================================
OSERDESE2 #(
    .DATA_RATE_OQ   ("DDR"),
    .DATA_RATE_TQ   ("DDR"),       // DDR模式TQ速率
    .DATA_WIDTH     (DATA_WIDTH),
    .INIT_OQ        (1'b0),
    .INIT_TQ        (1'b0),
    .SERDES_MODE    ("MASTER"),
    .SRVAL_OQ       (1'b0),
    .SRVAL_TQ       (1'b0),
    .TBYTE_CTL      ("FALSE"),
    .TBYTE_SRC      ("FALSE"),
    // .TRISTATE_WIDTH (4)            // 【修正】DDR模式UG471强制要求TRISTATE_WIDTH=4
    .TRISTATE_WIDTH (1)            // 【修正】DDR模式UG471强制要求TRISTATE_WIDTH=4
) u_oserdes_data (
    .OQ         (s_data_out),
    .OFB        (),                // 内部反馈，直出IO时悬空
    .SHIFTOUT1  (), .SHIFTOUT2  (),// 无SLAVE级联，悬空
    .TBYTEOUT   (), .TFB         (),
    .TQ         (),                // 三态输出未使用
    .CLK        (clk_ser),
    .CLKDIV     (clk_div),
    .D1         (tx_data_mux[0]), .D2(tx_data_mux[1]), .D3(tx_data_mux[2]), .D4(tx_data_mux[3]),
    .D5         (tx_data_mux[4]), .D6(tx_data_mux[5]), .D7(tx_data_mux[6]), .D8(tx_data_mux[7]),
    .OCE        (1'b1),
    .RST        (~rst_n),
    .SHIFTIN1   (1'b0), .SHIFTIN2(1'b0),
    .T1         (1'b0), .T2(1'b0), .T3(1'b0), .T4(1'b0),
    .TBYTEIN    (1'b0), .TCE(1'b0)
);

// OSERDESE2 时钟通道串行化（输出 10101010 模式）
OSERDESE2 #(
    .DATA_RATE_OQ   ("DDR"),
    .DATA_RATE_TQ   ("DDR"),       // DDR模式TQ速率
    .DATA_WIDTH     (DATA_WIDTH),
    .INIT_OQ        (1'b0),
    .INIT_TQ        (1'b0),
    .SERDES_MODE    ("MASTER"),
    .SRVAL_OQ       (1'b0),
    .SRVAL_TQ       (1'b0),
    .TBYTE_CTL      ("FALSE"),
    .TBYTE_SRC      ("FALSE"),
    // .TRISTATE_WIDTH (4)            // 【修正】DDR模式UG471强制要求TRISTATE_WIDTH=4
    .TRISTATE_WIDTH (1)            // 【修正】DDR模式UG471强制要求TRISTATE_WIDTH=4
) u_oserdes_clk (
    .OQ         (s_clk_out),
    .OFB        (),
    .SHIFTOUT1  (), .SHIFTOUT2  (),
    .TBYTEOUT   (), .TFB         (),
    .TQ         (),
    .CLK        (clk_ser),
    .CLKDIV     (clk_div),
    .D1(1'b1), .D2(1'b0), .D3(1'b1), .D4(1'b0), .D5(1'b1), .D6(1'b0), .D7(1'b1), .D8(1'b0),
    .OCE        (1'b1),
    .RST        (~rst_n),
    .SHIFTIN1   (1'b0), .SHIFTIN2(1'b0),
    .T1         (1'b0), .T2(1'b0), .T3(1'b0), .T4(1'b0),
    .TBYTEIN    (1'b0), .TCE(1'b0)
);

// OBUFDS 差分输出
OBUFDS #(.IOSTANDARD("LVDS_25"), .SLEW("FAST")) u_obufds_data (
    .O(lvds_data_p), .OB(lvds_data_n), .I(s_data_out)
);
OBUFDS #(.IOSTANDARD("LVDS_25"), .SLEW("FAST")) u_obufds_clk (
    .O(lvds_clk_p), .OB(lvds_clk_n), .I(s_clk_out)
);

endmodule
