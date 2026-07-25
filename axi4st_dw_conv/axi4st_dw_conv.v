`timescale 1ns / 1ps
// #############################################################################
// Module   : axi4st_dw_conv
// Function : 单时钟域 AXI4-Stream 位宽转换器
//            支持比率：4:1 / 2:1 / 1:2 / 1:4
//            三段式 FSM + XPM FIFO 弹性缓冲
// #############################################################################

module axi4st_dw_conv #(
    parameter IN_DATA_WIDTH  = 32,
    parameter OUT_DATA_WIDTH = 8,
    parameter TUSER_WIDTH    = 1,
    parameter FIFO_DEPTH     = 16
)(
    input  wire                          aclk,
    input  wire                          aresetn,

    // AXI4-Stream 输入（Slave）
    input  wire [IN_DATA_WIDTH-1:0]      s_axis_tdata,
    input  wire [IN_DATA_WIDTH/8-1:0]    s_axis_tkeep,
    input  wire                          s_axis_tlast,
    input  wire [TUSER_WIDTH-1:0]        s_axis_tuser,
    input  wire                          s_axis_tvalid,
    output wire                          s_axis_tready,

    // AXI4-Stream 输出（Master）
    output wire [OUT_DATA_WIDTH-1:0]     m_axis_tdata,
    output wire [OUT_DATA_WIDTH/8-1:0]   m_axis_tkeep,
    output wire                          m_axis_tlast,
    output wire [TUSER_WIDTH-1:0]        m_axis_tuser,
    output wire                          m_axis_tvalid,
    input  wire                          m_axis_tready
);

// ==================================================
// 内部常量
// ==================================================
localparam IN_BYTES    = IN_DATA_WIDTH / 8;
localparam OUT_BYTES   = OUT_DATA_WIDTH / 8;
localparam IS_DOWNSIZE = (IN_DATA_WIDTH > OUT_DATA_WIDTH);
localparam RATIO       = (IN_DATA_WIDTH > OUT_DATA_WIDTH) ?
                         (IN_DATA_WIDTH / OUT_DATA_WIDTH) :
                         (OUT_DATA_WIDTH / IN_DATA_WIDTH);
localparam COMPOSITE_W = OUT_DATA_WIDTH + OUT_BYTES + 1 + TUSER_WIDTH;

// 比率合法性检查
initial begin
    if (IN_DATA_WIDTH % 8 != 0 || OUT_DATA_WIDTH % 8 != 0) begin
        $error("axi4st_dw_conv: IN_DATA_WIDTH and OUT_DATA_WIDTH must be multiples of 8");
    end
    if (RATIO != 2 && RATIO != 4) begin
        $error("axi4st_dw_conv: RATIO must be 2 or 4, current = %0d", RATIO);
    end
end

// ==================================================
// FIFO 信号与例化
// ==================================================
wire fifo_rst = ~aresetn;
wire [COMPOSITE_W-1:0] fifo_din;
wire [COMPOSITE_W-1:0] fifo_dout;
wire fifo_full;
wire fifo_empty;
wire fifo_wr_en;
wire fifo_rd_en;

xpm_fifo_sync #(
    .FIFO_MEMORY_TYPE    ("distributed"),
    .ECC_MODE            ("no_ecc"),
    .FIFO_WRITE_DEPTH    (FIFO_DEPTH),
    .WRITE_DATA_WIDTH    (COMPOSITE_W),
    .READ_DATA_WIDTH     (COMPOSITE_W),
    .READ_MODE           ("fwft"),
    .USE_ADV_FEATURES    ("0000"),
    .WR_DATA_COUNT_WIDTH (1),
    .FULL_RESET_VALUE    (0),
    .CASCADE_HEIGHT      (0),
    .SIM_ASSERT_ON       (1)
) u_fifo (
    .rst              (fifo_rst),
    .wr_clk           (aclk),
    .din              (fifo_din),
    .wr_en            (fifo_wr_en),
    .full             (fifo_full),
    .overflow         (),
    .prog_full        (),
    .wr_data_count    (),
    .almost_full      (),
    .wr_rst_busy      (),
    .rd_en            (fifo_rd_en),
    .dout             (fifo_dout),
    .empty            (fifo_empty),
    .underflow        (),
    .prog_empty       (),
    .rd_data_count    (),
    .almost_empty     (),
    .rd_rst_busy      (),
    .injectsbiterr    (1'b0),
    .injectdbiterr    (1'b0),
    .sbiterr          (),
    .dbiterr          ()
);

// 输出端口（FIFO 读侧）
assign m_axis_tvalid = ~fifo_empty;
assign fifo_rd_en    = m_axis_tvalid & m_axis_tready;
assign m_axis_tdata  = fifo_dout[OUT_DATA_WIDTH-1:0];
assign m_axis_tkeep  = fifo_dout[OUT_DATA_WIDTH +: OUT_BYTES];
assign m_axis_tlast  = fifo_dout[OUT_DATA_WIDTH + OUT_BYTES];
assign m_axis_tuser  = fifo_dout[OUT_DATA_WIDTH + OUT_BYTES + 1 +: TUSER_WIDTH];

// ==================================================
// 复合字打包：{tuser, tlast, tkeep, tdata}（tdata 在低位）
// ==================================================
wire [OUT_DATA_WIDTH-1:0]  wr_tdata;
wire [OUT_BYTES-1:0]       wr_tkeep;
wire                       wr_tlast;
wire [TUSER_WIDTH-1:0]     wr_tuser;
assign fifo_din = {wr_tuser, wr_tlast, wr_tkeep, wr_tdata};

// ==================================================
// 输入握手信号
// ==================================================
wire s_handshake = s_axis_tvalid & s_axis_tready;

// ==================================================
// 降位宽核心（IN > OUT）
// ==================================================
generate if (IS_DOWNSIZE) begin : gen_downsize

    // ---------- 状态定义 ----------
    localparam DS_IDLE  = 1'b0;
    localparam DS_SHIFT = 1'b1;

    // ---------- 状态寄存器 ----------
    reg ds_curr_state;
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn)
            ds_curr_state <= DS_IDLE;
        else
            ds_curr_state <= ds_next_state;
    end

    // ---------- 次态组合逻辑 ----------
    reg ds_next_state;
    always @(*) begin
        ds_next_state = ds_curr_state;
        case (ds_curr_state)
            DS_IDLE:
                if (s_handshake)
                    ds_next_state = DS_SHIFT;
            DS_SHIFT:
                if (shift_cnt == RATIO - 1 && ~fifo_full)
                    ds_next_state = DS_IDLE;
            default:
                ds_next_state = DS_IDLE;
        endcase
    end

    // ---------- 寄存器 ----------
    reg [IN_DATA_WIDTH-1:0] shift_data;
    reg [IN_BYTES-1:0]      shift_keep;
    reg                     shift_last;
    reg [TUSER_WIDTH-1:0]   shift_user;
    reg [$clog2(RATIO):0]   shift_cnt;

    // ---------- 输出逻辑（时序） ----------
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            shift_data <= {IN_DATA_WIDTH{1'b0}};
            shift_keep <= {IN_BYTES{1'b0}};
            shift_last <= 1'b0;
            shift_user <= {TUSER_WIDTH{1'b0}};
            shift_cnt  <= 0;
        end else begin
            case (ds_curr_state)
                DS_IDLE: begin
                    if (s_handshake) begin
                        shift_data <= s_axis_tdata;
                        shift_keep <= s_axis_tkeep;
                        shift_last <= s_axis_tlast;
                        shift_user <= s_axis_tuser;
                        shift_cnt  <= 0;
                    end
                end

                DS_SHIFT: begin
                    if (~fifo_full) begin
                        // 右移一个 OUT 位宽
                        shift_data <= shift_data >> OUT_DATA_WIDTH;
                        shift_keep <= shift_keep >> OUT_BYTES;
                        if (shift_cnt == RATIO - 1) begin
                            // 最后一拍，回到 IDLE 时重新加载
                            shift_cnt <= 0;
                        end else begin
                            shift_cnt <= shift_cnt + 1;
                        end
                    end
                end
            endcase
        end
    end

    // ---------- FIFO 写侧（组合） ----------
    assign fifo_wr_en = (ds_curr_state == DS_SHIFT) & ~fifo_full;
    assign wr_tdata   = shift_data[OUT_DATA_WIDTH-1:0];
    assign wr_tkeep   = shift_keep[OUT_BYTES-1:0];
    assign wr_tlast   = (shift_cnt == RATIO - 1) ? shift_last : 1'b0;
    assign wr_tuser   = (shift_cnt == 0) ? shift_user : {TUSER_WIDTH{1'b0}};

    // ---------- 输入 tready ----------
    // DS_IDLE 且 FIFO 未满时接受新输入
    assign s_axis_tready = (ds_curr_state == DS_IDLE) & ~fifo_full;

end
// ==================================================
// 升位宽核心（IN < OUT）
// ==================================================
else begin : gen_upsize

    // ---------- 状态定义 ----------
    localparam US_IDLE  = 1'b0;
    localparam US_ACCUM = 1'b1;

    // ---------- 状态寄存器 ----------
    reg us_curr_state;
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn)
            us_curr_state <= US_IDLE;
        else
            us_curr_state <= us_next_state;
    end

    // ---------- 次态组合逻辑 ----------
    reg us_next_state;
    always @(*) begin
        us_next_state = us_curr_state;
        case (us_curr_state)
            US_IDLE:
                if (s_handshake) begin
                    // 一拍即满（RATIO=1，不应发生）或 tlast → 产出并回 IDLE
                    if (s_axis_tlast || RATIO == 1)
                        us_next_state = US_IDLE;
                    else
                        us_next_state = US_ACCUM;
                end
            US_ACCUM:
                if (s_handshake) begin
                    // 最后一拍 或 tlast → 产出并回 IDLE
                    if (accum_cnt == RATIO - 1 || s_axis_tlast)
                        us_next_state = US_IDLE;
                end
            default:
                us_next_state = US_IDLE;
        endcase
    end

    // ---------- 寄存器 ----------
    reg [OUT_DATA_WIDTH-1:0] accum_data;
    reg [OUT_BYTES-1:0]      accum_keep;
    reg [$clog2(RATIO):0]    accum_cnt;  // 已接收的输入拍数

    // ---------- 输出逻辑（时序） ----------
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            accum_data <= {OUT_DATA_WIDTH{1'b0}};
            accum_keep <= {OUT_BYTES{1'b0}};
            accum_cnt  <= 0;
        end else begin
            case (us_curr_state)
                US_IDLE: begin
                    if (s_handshake) begin
                        // 第一拍写入累加器低位
                        accum_data[IN_DATA_WIDTH-1:0] <= s_axis_tdata;
                        accum_keep[IN_BYTES-1:0]     <= s_axis_tkeep;
                        // 未使用的高位清零
                        accum_data[OUT_DATA_WIDTH-1:IN_DATA_WIDTH] <= {OUT_DATA_WIDTH - IN_DATA_WIDTH{1'b0}};
                        accum_keep[OUT_BYTES-1:IN_BYTES]            <= {OUT_BYTES - IN_BYTES{1'b0}};
                        accum_cnt <= 1;
                        // 若 tlast：本拍即产出，下一拍回到 IDLE（accum_cnt 重置在 IDLE 状态进入时）
                    end else begin
                        // 空闲时清零
                        accum_cnt <= 0;
                    end
                end

                US_ACCUM: begin
                    if (s_handshake) begin
                        // 写入累加器对应位置
                        accum_data[accum_cnt*IN_DATA_WIDTH +: IN_DATA_WIDTH] <= s_axis_tdata;
                        accum_keep[accum_cnt*IN_BYTES   +: IN_BYTES]         <= s_axis_tkeep;

                        if (accum_cnt == RATIO - 1 || s_axis_tlast) begin
                            // 产出后回到 IDLE，accum_cnt 将在 IDLE 清零
                            accum_cnt <= 0;
                        end else begin
                            accum_cnt <= accum_cnt + 1;
                        end
                    end
                end
            endcase
        end
    end

    // ---------- FIFO 写侧 ----------
    // 产出条件：在 s_handshake 时，满足（最后一拍 或 tlast）
    // - US_IDLE 下 s_handshake：若 tlast 或 RATIO=1，立即产出
    // - US_ACCUM 下 s_handshake：若 accum_cnt==RATIO-1 或 tlast，立即产出
    // 产出的数据 = 当前累加器（之前的字节） + 当前输入拼入对应位置
    // 为避免时序问题，用组合逻辑拼出最终输出字

    reg [OUT_DATA_WIDTH-1:0] out_data_comb;
    reg [OUT_BYTES-1:0]      out_keep_comb;

    always @(*) begin
        out_data_comb = accum_data;
        out_keep_comb = accum_keep;
        if (s_handshake) begin
            if (us_curr_state == US_IDLE) begin
                // 第一拍：写入低位
                out_data_comb[IN_DATA_WIDTH-1:0] = s_axis_tdata;
                out_keep_comb[IN_BYTES-1:0]      = s_axis_tkeep;
                // 高位保持0（accum 在 IDLE 时已清零）
            end else if (us_curr_state == US_ACCUM) begin
                // 写入累加器对应位置
                out_data_comb[accum_cnt*IN_DATA_WIDTH +: IN_DATA_WIDTH] = s_axis_tdata;
                out_keep_comb[accum_cnt*IN_BYTES   +: IN_BYTES]         = s_axis_tkeep;
            end
        end
    end

    // 产出触发：当 s_handshake 且（第一拍时 tlast 或 RATIO=1，或累加时最后一拍或 tlast）
    wire produce_out = s_handshake & (
        (us_curr_state == US_IDLE  & (s_axis_tlast | (RATIO == 1))) |
        (us_curr_state == US_ACCUM & (accum_cnt == RATIO - 1 | s_axis_tlast))
    );

    assign fifo_wr_en = produce_out & ~fifo_full;
    assign wr_tdata   = out_data_comb;
    assign wr_tkeep   = out_keep_comb;
    assign wr_tlast   = s_axis_tlast;
    assign wr_tuser   = s_axis_tuser;

    // ---------- 输入 tready ----------
    // 只要不产出，就可以接受（累加）；
    // 若产出，需 FIFO 未满才能接受（因为产出和接收同步发生）。
    // 简化：s_axis_tready = ~fifo_full（当要产出时受 FIFO 满限制；不产出时 FIFO 满也不影响累加，但 FIFO 满最终会在产出时阻塞）
    // 更严格：IDLE 时 tready=~fifo_full（因为可能 tlast 立即产出）；
    //          ACCUM 且不产出时 tready=1（累加不需要 FIFO 空间）；
    //          ACCUM 且要产出时 tready=~fifo_full。
    wire will_produce = (us_curr_state == US_ACCUM) &
                        (accum_cnt == RATIO - 1 | s_axis_tlast);
    assign s_axis_tready = (us_curr_state == US_ACCUM & ~will_produce) ? 1'b1 : ~fifo_full;

end
endgenerate

endmodule
