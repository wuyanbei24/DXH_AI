`timescale 1ns / 1ps

module tlk1221_phy_if
#(
    parameter FIFO_DATA_WIDTH     = 10,
    parameter RD_DATA_COUNT_WIDTH = 10,
    parameter FIFO_DEPTH          = 512
)(
    input  wire                        clk_phy_tx,
    input  wire                        rst_phy_tx_n,
    input  wire                        clk_phy_rx,
    input  wire                        rst_phy_rx_n,

    // TLK1221 并行接口
    output reg [9:0]                   tlk_tx_data,
    input  wire [9:0]                  tlk_rx_data,
    input  wire                        tlk_rx_sync,

    // TX FIFO 读接口
    input  wire [FIFO_DATA_WIDTH-1:0]  tx_fifo_rd_data,
    output reg                         tx_fifo_rd_en,
    input  wire                        tx_fifo_empty,
    input  wire [RD_DATA_COUNT_WIDTH-1:0] tx_fifo_rd_count,

    // RX FIFO 写接口
    output reg [FIFO_DATA_WIDTH-1:0]   rx_fifo_wr_data,
    output reg                         rx_fifo_wr_en,
    input  wire                        rx_fifo_full,

    // 8B10B 解码错误标志 (clk_phy_rx 域; 由顶层同步到 clk_user 后输出)
    output wire                        phy_code_err,
    output wire                        phy_disp_err
);

localparam IDLE_WORD = 10'h0FA; // K28.5 comma (RD-): 001111.1010, 含标准逗号序列 0011111

// ==================================================
// ************ CDC: tlk_rx_sync 同步到 clk_phy_tx 域 (CDC-1 修复) ************
// ==================================================
// PL_SFP_SYNC 来自 TLK1221（恢复时钟 clk_phy_rx 域），在 clk_phy_tx 域使用前必须经同步器。
reg [2:0] rx_sync_tx_meta;
always @(posedge clk_phy_tx or negedge rst_phy_tx_n) begin
    if(!rst_phy_tx_n)
        rx_sync_tx_meta <= 3'b000;
    else
        rx_sync_tx_meta <= {rx_sync_tx_meta[1:0], tlk_rx_sync};
end
wire tlk_rx_sync_tx = rx_sync_tx_meta[2];   // 3-FF 同步后的 SYNC（clk_phy_tx 域）

// ==================================================
// ************ PHY TX 三段式状态机 ************
// ==================================================
localparam PHY_TX_IDLE = 2'b01;
localparam PHY_TX_RUN  = 2'b10;

reg [1:0] phy_tx_curr;
reg [1:0] phy_tx_next;

always @(posedge clk_phy_tx or negedge rst_phy_tx_n) begin
    if(!rst_phy_tx_n)
        phy_tx_curr <= PHY_TX_IDLE;
    else
        phy_tx_curr <= phy_tx_next;
end

always @(*) begin
    phy_tx_next = phy_tx_curr;
    case(phy_tx_curr)
        PHY_TX_IDLE: begin
            if(tlk_rx_sync_tx)        // CDC-1: 使用同步后的 SYNC
                phy_tx_next = PHY_TX_RUN;
        end
        PHY_TX_RUN: begin
            if(!tlk_rx_sync_tx)       // CDC-1: 使用同步后的 SYNC
                phy_tx_next = PHY_TX_IDLE;
        end
        default: phy_tx_next = PHY_TX_IDLE;
    endcase
end

// 空闲 K28.5 必须在 RD-/RD+ 间交替（0x0FA/0x305）以维持直流平衡；恒定发送会导致 RD 漂移与 disp_err。
reg idle_toggle;
wire [9:0] idle_word = idle_toggle ? 10'h305 : 10'h0FA;   // K28.5 RD+ / RD- comma
always @(posedge clk_phy_tx or negedge rst_phy_tx_n) begin
    if(!rst_phy_tx_n) idle_toggle <= 1'b0;
    else              idle_toggle <= ~idle_toggle;          // 每拍翻转，保证交替
end

// ============================================================================
// TX 异步 FIFO 读协议修复（关键）
// ----------------------------------------------------------------------------
// 旧实现：`tlk_tx_data <= tx_fifo_rd_data` 与 `tx_fifo_rd_en` 同拍锁存，但 std
// 模式 FIFO（FIFO_READ_LATENCY=1）的 dout 在 rd_en 后 1 拍才有效 -> td 滞后且
// 边界错位；同时依赖 `tx_fifo_empty`（读域同步，存在 ~CDC 级延迟），FIFO 排空后
// empty 仍延后数拍为 0，FSM 继续读 -> 读指针越过写指针读未初始化的存储 -> 线上出现
// 重复符号与 X（实测 TD = 000,000,0cc,0cc,0cc... 且 rdcnt 出现 1020/1023 负回绕）。
//
// 修复：
//   (a) 用读域 *保守下界* `tx_fifo_rd_count >= 1` 作为读门控。rd_data_count =
//       wr_ptr_rd - rd_ptr，因 wr_ptr_rd 同步滞后必有 wr_ptr_rd <= wr_ptr，故
//       count>=1 时写域必有 >=1 个字 -> 绝不会读空 FIFO（消除越过/负回绕）。
//   (b) std 模式 dout 在 rd_en 后 1 拍有效，故用 tx_emit_valid 把 dout 延迟 1 拍
//       再送到 tlk_tx_data，首字之前发 idle，末字发完即回 idle（不重复、不丢失）。
// ============================================================================
// 读域 rd_data_count = wr_ptr_rd - rd_ptr（无符号）。可用字数真实范围为 [1, FIFO_DEPTH]；
// 读指针越过写指针（越过/负回绕）时该值会落在 (FIFO_DEPTH, 2^W-1] 区间，必须排除，
// 否则会把“假性非空”误判为可读而读越界（真实 XPM FIFO 的 count 永远 <= DEPTH，
// 此条件对硬件为恒真，仅用于让仿真模型 count 可用并杜绝越过读）。
wire tx_fifo_has_data = (tx_fifo_rd_count >= 1) &&
                        (tx_fifo_rd_count <= FIFO_DEPTH) &&
                        (phy_tx_curr == PHY_TX_RUN);
// tx_fresh：本拍发出的读请求会在下一拍使 dout 成为“新字”，置位后下一拍用 dout 发送、
// 随后清零。这样每个 FIFO 字恰好发送一次（首字前/末字后各一个 idle），既不重复也不丢失。
reg  tx_fresh;

always @(posedge clk_phy_tx or negedge rst_phy_tx_n) begin
    if(!rst_phy_tx_n) begin
        tlk_tx_data   <= IDLE_WORD;
        tx_fifo_rd_en <= 1'b0;
        tx_fresh      <= 1'b0;
    end
    else begin
        if(phy_tx_curr == PHY_TX_RUN) begin
            tx_fifo_rd_en <= tx_fifo_has_data;          // 有数据才请求读
            if(tx_fifo_has_data) begin
                tx_fresh      <= 1'b1;                  // dout 下拍成为新字
                // 用上一拍置位的 tx_fresh 判定：本拍 dout 是刚请求到的新字才发送，否则 idle
                tlk_tx_data   <= tx_fresh ? tx_fifo_rd_data : idle_word;
            end
            else begin
                tx_fresh      <= 1'b0;
                tlk_tx_data   <= idle_word;
            end
        end
        else begin
            tlk_tx_data   <= idle_word;                 // 未同步：发 K28.5 训练逗号
            tx_fifo_rd_en <= 1'b0;
            tx_fresh      <= 1'b0;
        end
    end
end

// ==================================================
// ************ PHY RX 三段式状态机 ************
// ==================================================
localparam PHY_RX_IDLE = 2'b01;
localparam PHY_RX_RUN  = 2'b10;

// ---- RX 8B10B 解码内部信号 (clk_phy_rx 域) ----
wire [7:0]  rx_dec_data;
wire        rx_dec_kout;
wire        rx_dec_code_err;
wire        rx_dec_disp_err;

reg [1:0] phy_rx_curr;
reg [1:0] phy_rx_next;

always @(posedge clk_phy_rx or negedge rst_phy_rx_n) begin
    if(!rst_phy_rx_n)
        phy_rx_curr <= PHY_RX_IDLE;
    else
        phy_rx_curr <= phy_rx_next;
end

always @(*) begin
    phy_rx_next = phy_rx_curr;
    case(phy_rx_curr)
        PHY_RX_IDLE: begin
            if(tlk_rx_sync)
                phy_rx_next = PHY_RX_RUN;
        end
        PHY_RX_RUN: begin
            if(!tlk_rx_sync)
                phy_rx_next = PHY_RX_IDLE;
        end
        default: phy_rx_next = PHY_RX_IDLE;
    endcase
end

// ============================================================================
// RX 8B10B 解码 + 逗号过滤写 FIFO（clk_phy_rx 域）
// ----------------------------------------------------------------------------
// 解码在恢复时钟域对 *每一个* 收到的 10bit 字（数据字 + 逗号）进行，以维持
// Running-Disparity 连续跟踪（逗号也参与 RD 翻转，不能跳过）。但仅把非逗号
// 数据字写入 RX FIFO —— 否则空闲逗号流会以线速率占满 512 深 FIFO，在持续流量
// /背压下溢出丢数据。过滤逗号后 RX FIFO 只保存数据字（本测试最多 600 个），
// 线速率写与用户侧读（1/周期）之间不会溢出，背压可安全吸收。
//
// din_valid = (PHY_RX_RUN && tlk_rx_sync)：SYNC 直接门控，消除 SYNC 毛刺窗口
// 内 phy_rx_curr 滞后 1 拍把 RD=0 当数据写进 FIFO 的 0x000 垃圾字。
// ============================================================================
wire rx_sym_valid = (phy_rx_curr == PHY_RX_RUN) && tlk_rx_sync;

decode_8b10b #(.REG_OUTPUT(1)) u_rx_decode (
    .clk       (clk_phy_rx),
    .rst_n     (rst_phy_rx_n),
    .din       (tlk_rx_data),
    .din_valid (rx_sym_valid),
    .dout      (rx_dec_data),
    .kout      (rx_dec_kout),
    .code_err  (rx_dec_code_err),
    .disp_err  (rx_dec_disp_err)
);

// REG_OUTPUT=1：dec_dout / dec_kout 在 din_valid 后 1 拍有效
reg rx_dec_valid_r;
always @(posedge clk_phy_rx or negedge rst_phy_rx_n) begin
    if(!rst_phy_rx_n) rx_dec_valid_r <= 1'b0;
    else              rx_dec_valid_r <= rx_sym_valid;
end

// 错误标志（clk_phy_rx 域，电平保持；由顶层同步到 clk_user 后输出）
assign phy_code_err = rx_dec_code_err;
assign phy_disp_err = rx_dec_disp_err;

always @(posedge clk_phy_rx or negedge rst_phy_rx_n) begin
    if(!rst_phy_rx_n) begin
        rx_fifo_wr_data <= {FIFO_DATA_WIDTH{1'b0}};
        rx_fifo_wr_en   <= 1'b0;
    end
    else begin
        rx_fifo_wr_en <= 1'b0;
        // 仅在解码出“有效数据字”（非 K/comma）且 FIFO 未满时写入
        if(rx_dec_valid_r && !rx_dec_kout && !rx_fifo_full) begin
            rx_fifo_wr_data <= rx_dec_data;   // 8bit 数据零扩展到 10bit FIFO
            rx_fifo_wr_en   <= 1'b1;
        end
    end
end

endmodule