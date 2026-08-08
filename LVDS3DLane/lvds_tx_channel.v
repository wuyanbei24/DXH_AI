`timescale 1ns / 1ps
//============================================================================
// Module: lvds_tx_channel
// Description: 3通道扩展版LVDS发送通道
//   - 24bit并行数据处理，训练序列生成，帧调度，心跳插入，XPM FIFO缓存
//   - 例化3路OSERDESE2串行化 + OBUFDS差分输出
//   - 串行/并行时钟由顶层外部输入
//   - [V4修复] LT-01: 增加tx_retrain_req输入, 重训练时重置train_phase_cnt
//   - [V4修复] LT-05: 同步重训练重启, 确保TX/RX同时从阶段0开始
// Source: Xilinx 7系列FPGA双向3路数据LVDS通信设计文档_V1.0  §4.1
//============================================================================
module lvds_tx_channel #(
    parameter DATA_WIDTH     = 8,
    parameter LANE_CNT       = 3,
    parameter SERIAL_FACTOR  = 8,
    parameter CLK_FREQ       = 100_000_000,
    parameter HEARTBEAT_MS   = 1,
    parameter MAX_PAYLOAD    = 255,
    parameter USER_FIFO_DEPTH= 512
)(
    input  wire clk_ser,
    input  wire clk_div,
    input  wire rst_n,
    // 链路管理器控制接口
    input  wire train_en,
    input  wire ctrl_frame_send,
    input  wire [7:0] ctrl_frame_type,
    input  wire [7:0] ctrl_frame_payload,
    // [V4修复 LT-01/LT-05] TX重训练请求, 同步重启训练阶段计数
    input  wire tx_retrain_req,
    // 用户数据接口 (24bit = 3*8bit)
    input  wire [LANE_CNT*DATA_WIDTH-1:0] tx_data_in,
    input  wire                            tx_data_valid,
    output wire                            tx_ready,
    // LVDS差分输出 (1路时钟 + 3路数据)
    output wire lvds_clk_p,
    output wire lvds_clk_n,
    output wire [LANE_CNT-1:0] lvds_data_p,
    output wire [LANE_CNT-1:0] lvds_data_n
);

localparam TX_IDLE=0, TX_SOF_TYPE=1, TX_LEN=2, TX_PAYLOAD=3, TX_CHECKSUM=4;
reg [2:0] tx_curr_state, tx_next_state;
reg [LANE_CNT*DATA_WIDTH-1:0] tx_data_mux;
reg [31:0] heartbeat_timer;
reg [15:0] heartbeat_cnt;
reg heartbeat_pending;
reg [7:0] payload_len, payload_cnt, checksum_reg, tx_type_sel;
reg fifo_rd_en;
wire [LANE_CNT*DATA_WIDTH-1:0] fifo_dout;
wire        fifo_empty;
wire        fifo_full;
wire [8:0]  fifo_data_cnt;
wire [LANE_CNT-1:0] s_data_out;
wire s_clk_out;

localparam FRAME_SOF1=8'hAA, FRAME_SOF2=8'h55;
localparam TYPE_HB=8'h10, TYPE_USR=8'h20;
localparam HEARTBEAT_CNT_MAX = (CLK_FREQ / 1000) * HEARTBEAT_MS;
localparam HEARTBEAT_PAYLOAD_LEN = 8'd2;

// 两阶段训练：阶段0发0x55做延迟校准，阶段1发0xB5做字对齐
// [V4修复 LT-01] 增加阶段切换裕量, 确保RX有足够时间完成延迟校准
localparam TRAIN_CALIB_DURATION = 16'd4000; // 延迟校准约需576周期，4000提供充足余量
localparam TRAIN_ALIGN_DURATION = 16'd8000; // V4: 字对齐阶段持续时间
reg [15:0] train_phase_cnt;
wire       train_phase; // 0=延迟校准阶段(0x55), 1=字对齐阶段(0xB5)
assign train_phase = (train_phase_cnt >= TRAIN_CALIB_DURATION);

// [V4修复 LT-05] tx_retrain_req上升沿检测
reg tx_retrain_req_d;
wire tx_retrain_pulse;
assign tx_retrain_pulse = tx_retrain_req & ~tx_retrain_req_d;

// tx_ready 门控
assign tx_ready = ~fifo_full && ~train_en;

// XPM_FIFO_SYNC 同步FIFO（24bit位宽）
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
    .READ_DATA_WIDTH     (LANE_CNT*DATA_WIDTH),
    .READ_MODE           ("fwft"),
    // .SIM_ASSERT_CHK      (0),
    .USE_ADV_FEATURES    ("0000"),
    .WAKEUP_TIME         (0),
    .WRITE_DATA_WIDTH    (LANE_CNT*DATA_WIDTH),
    .WR_DATA_COUNT_WIDTH (9)
) u_user_fifo (
    .wr_clk         (clk_div),
    .rst            (~rst_n),
    .sleep          (1'b0),
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

// 心跳生成逻辑
// [V4修复 LT-05] tx_retrain_req到达时重置train_phase_cnt, 确保TX/RX同步重启
always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n) begin
        heartbeat_timer <= 32'd0;
        heartbeat_cnt   <= 16'd0;
        heartbeat_pending <= 1'b0;
        train_phase_cnt <= 16'd0;
        tx_retrain_req_d <= 1'b0;
    end else begin
        tx_retrain_req_d <= tx_retrain_req;

        // [V4修复 LT-05] 重训练脉冲到达时, 强制重置训练阶段计数
        if(tx_retrain_pulse) begin
            train_phase_cnt <= 16'd0;
            heartbeat_timer <= 32'd0;
            heartbeat_cnt   <= 16'd0;
            heartbeat_pending <= 1'b0;
        end else if(train_en) begin
            // 训练阶段计数：阶段0(0x55)持续TRAIN_CALIB_DURATION后切换到阶段1(0xB5)
            if(train_phase_cnt < (TRAIN_CALIB_DURATION + TRAIN_ALIGN_DURATION))
                train_phase_cnt <= train_phase_cnt + 1'b1;
            // 训练期间不产生心跳
            heartbeat_timer <= 32'd0;
            heartbeat_cnt   <= 16'd0;
            heartbeat_pending <= 1'b0;
        end else begin
            train_phase_cnt <= 16'd0; // 退出训练时重置，下次训练重新从阶段0开始
            heartbeat_timer <= heartbeat_timer + 1'b1;
            if(heartbeat_timer >= HEARTBEAT_CNT_MAX) begin
                heartbeat_timer   <= 32'd0;
                heartbeat_pending <= 1'b1;
                heartbeat_cnt     <= heartbeat_cnt + 1'b1;
            end
            if(tx_curr_state == TX_CHECKSUM && tx_next_state == TX_IDLE && tx_type_sel == TYPE_HB) begin
                heartbeat_pending <= 1'b0;
            end
        end
    end
end

// 帧调度三段式状态机 - 第一段
always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n) tx_curr_state <= TX_IDLE;
    else tx_curr_state <= tx_next_state;
end

// 第二段：次态跳转
always @(*) begin
    tx_next_state = tx_curr_state;
    if(train_en) begin
        tx_next_state = TX_IDLE;
    end else begin
        case(tx_curr_state)
            TX_IDLE: begin
                if(ctrl_frame_send)          tx_next_state = TX_SOF_TYPE;
                else if(~fifo_empty)         tx_next_state = TX_SOF_TYPE;
                else if(heartbeat_pending)   tx_next_state = TX_SOF_TYPE;
            end
            TX_SOF_TYPE: tx_next_state = TX_LEN;
            TX_LEN:      tx_next_state = (payload_len == 8'd0) ? TX_CHECKSUM : TX_PAYLOAD;
            TX_PAYLOAD:  tx_next_state = (payload_cnt + LANE_CNT >= payload_len) ? TX_CHECKSUM : TX_PAYLOAD;
            TX_CHECKSUM: tx_next_state = TX_IDLE;
            default:     tx_next_state = TX_IDLE;
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
                    payload_len <= (fifo_data_cnt*LANE_CNT > MAX_PAYLOAD) 
                       ? (MAX_PAYLOAD / LANE_CNT) * LANE_CNT  // 向下取整
                       : fifo_data_cnt[7:0] * LANE_CNT;
                end else if(heartbeat_pending) begin
                    tx_type_sel <= TYPE_HB;
                    payload_len <= HEARTBEAT_PAYLOAD_LEN;
                end
            end
            TX_SOF_TYPE: begin
                checksum_reg <= FRAME_SOF1 + FRAME_SOF2 + tx_type_sel;
            end
            TX_LEN: begin
                checksum_reg <= checksum_reg + payload_len;
                if(payload_len != 8'd0 && tx_type_sel == TYPE_USR) begin
                    fifo_rd_en <= 1'b1;
                end
            end
            TX_PAYLOAD: begin
                payload_cnt <= payload_cnt + LANE_CNT;
                case(tx_type_sel)
                    TYPE_USR: begin
                        checksum_reg <= checksum_reg + fifo_dout[7:0] + fifo_dout[15:8] + fifo_dout[23:16];
                        fifo_rd_en <= (payload_cnt + LANE_CNT < payload_len);
                    end
                    TYPE_HB: begin
                        checksum_reg <= checksum_reg + heartbeat_cnt[15:8] + heartbeat_cnt[7:0];
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

// 发送数据多路选择
always @(*) begin
    if(train_en) begin
        // 两阶段训练：阶段0发0x55(延迟校准)，阶段1发0xB5(字对齐+锁定检查)
        tx_data_mux = train_phase ? {LANE_CNT{8'hB5}} : {LANE_CNT{8'h55}};
    end else begin
        case(tx_curr_state)
            TX_SOF_TYPE: tx_data_mux = {tx_type_sel, FRAME_SOF2, FRAME_SOF1};
            TX_LEN:      tx_data_mux = {16'd0, payload_len};
            TX_PAYLOAD: begin
                case(tx_type_sel)
                    TYPE_USR: tx_data_mux = fifo_dout;
                    TYPE_HB:  tx_data_mux = {8'd0, heartbeat_cnt[7:0], heartbeat_cnt[15:8]};
                    default:  tx_data_mux = {16'd0, ctrl_frame_payload};
                endcase
            end
            TX_CHECKSUM: tx_data_mux = {16'd0, checksum_reg};
            default:     tx_data_mux = {LANE_CNT{8'h55}};
        endcase
    end
end

// 生成3路OSERDESE2数据通道
genvar lane_idx;
generate
    for(lane_idx = 0; lane_idx < LANE_CNT; lane_idx = lane_idx + 1) begin : gen_data_lane
        OSERDESE2 #(
            .DATA_RATE_OQ   ("DDR"),
            .DATA_RATE_TQ   ("DDR"),
            .DATA_WIDTH     (DATA_WIDTH),
            .INIT_OQ        (1'b0),
            .INIT_TQ        (1'b0),
            .SERDES_MODE    ("MASTER"),
            .SRVAL_OQ       (1'b0),
            .TBYTE_CTL      ("FALSE"),
            .TBYTE_SRC      ("FALSE"),
            .TRISTATE_WIDTH (1)
        ) u_oserdes_data (
            .OQ         (s_data_out[lane_idx]),
            .OFB        (),
            .SHIFTOUT1  (), 
            .SHIFTOUT2  (),
            .TBYTEOUT   (), 
            .TFB         (),
            .TQ         (),
            .CLK        (clk_ser),
            .CLKDIV     (clk_div),
            .D1         (tx_data_mux[lane_idx*8 + 0]),
            .D2         (tx_data_mux[lane_idx*8 + 1]),
            .D3         (tx_data_mux[lane_idx*8 + 2]),
            .D4         (tx_data_mux[lane_idx*8 + 3]),
            .D5         (tx_data_mux[lane_idx*8 + 4]),
            .D6         (tx_data_mux[lane_idx*8 + 5]),
            .D7         (tx_data_mux[lane_idx*8 + 6]),
            .D8         (tx_data_mux[lane_idx*8 + 7]),
            .OCE        (1'b1),
            .RST        (~rst_n),
            .SHIFTIN1   (1'b0), 
            .SHIFTIN2(1'b0),
            .T1(1'b0), 
            .T2(1'b0),
            .T3(1'b0), 
            .T4(1'b0),
            .TBYTEIN    (1'b0), 
            .TCE(1'b0)
        );

        OBUFDS #(
            .IOSTANDARD("DEFAULT"), 
            .SLEW("FAST")) 
        u_obufds_data 
        (
            .O(lvds_data_p[lane_idx]), 
            .OB(lvds_data_n[lane_idx]), 
            .I(s_data_out[lane_idx])
        );
    end
endgenerate

// 时钟通道OSERDESE2
OSERDESE2 #(
    .DATA_RATE_OQ   ("DDR"),
    .DATA_RATE_TQ   ("DDR"),
    .DATA_WIDTH     (DATA_WIDTH),
    .INIT_OQ        (1'b0),
    .INIT_TQ        (1'b0),
    .SERDES_MODE    ("MASTER"),
    .SRVAL_OQ       (1'b0),
    .TBYTE_CTL      ("FALSE"),
    .TBYTE_SRC      ("FALSE"),
    .TRISTATE_WIDTH (1)
) u_oserdes_clk (
    .OQ         (s_clk_out),
    .OFB        (),
    .SHIFTOUT1  (), 
    .SHIFTOUT2  (),
    .TBYTEOUT   (), 
    .TFB        (),
    .TQ         (),
    .CLK        (clk_ser),
    .CLKDIV     (clk_div),
    .D1(1'b1), 
    .D2(1'b0), 
    .D3(1'b1), 
    .D4(1'b0),
    .D5(1'b1), 
    .D6(1'b0), 
    .D7(1'b1), 
    .D8(1'b0),
    .OCE        (1'b1),
    .RST        (~rst_n),
    .SHIFTIN1   (1'b0), 
    .SHIFTIN2   (1'b0),
    .T1         (1'b0), 
    .T2(1'b0), 
    .T3(1'b0), 
    .T4(1'b0),
    .TBYTEIN    (1'b0), 
    .TCE(1'b0)
);

OBUFDS #(
    .IOSTANDARD("DEFAULT"), 
    .SLEW("FAST")) 
u_obufds_clk (
    .O(lvds_clk_p), 
    .OB(lvds_clk_n), 
    .I(s_clk_out)
);

endmodule
