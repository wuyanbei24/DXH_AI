`timescale 1ns / 1ps

module axi4st_cdc #(
    parameter DATA_WIDTH  = 32,
    parameter TUSER_WIDTH = 1,
    parameter FIFO_DEPTH  = 512
)(
    input  wire                        s_aclk,
    input  wire                        s_aresetn,
    input  wire [DATA_WIDTH-1:0]       s_axis_tdata,
    input  wire [DATA_WIDTH/8-1:0]     s_axis_tkeep,
    input  wire                        s_axis_tlast,
    input  wire [TUSER_WIDTH-1:0]      s_axis_tuser,
    input  wire                        s_axis_tvalid,
    output wire                        s_axis_tready,

    input  wire                        m_aclk,
    input  wire                        m_aresetn,
    output wire [DATA_WIDTH-1:0]       m_axis_tdata,
    output wire [DATA_WIDTH/8-1:0]     m_axis_tkeep,
    output wire                        m_axis_tlast,
    output wire [TUSER_WIDTH-1:0]      m_axis_tuser,
    output wire                        m_axis_tvalid,
    input  wire                        m_axis_tready
);

localparam BYTE_WIDTH  = DATA_WIDTH / 8;
localparam COMPOSITE_W = DATA_WIDTH + BYTE_WIDTH + 1 + TUSER_WIDTH;

initial begin
    if (DATA_WIDTH % 8 != 0) begin
        $error("DATA_WIDTH must be a multiple of 8");
    end
end

// ====================== 写侧 FSM 状态定义 ======================
localparam WR_IDLE   = 1'b0;
localparam WR_ACTIVE = 1'b1;

reg                         wr_curr_state;
reg                         wr_next_state;

// ====================== 读侧 FSM 状态定义 ======================
localparam RD_IDLE   = 1'b0;
localparam RD_ACTIVE = 1'b1;

reg                         rd_curr_state;
reg                         rd_next_state;

// ====================== FIFO 相关信号 ======================
wire [COMPOSITE_W-1:0]      fifo_din;
wire                        fifo_wr_en;
wire                        fifo_full;
wire                        wr_rst_busy;

wire [COMPOSITE_W-1:0]      fifo_dout;
wire                        fifo_rd_en;
wire                        fifo_empty;
wire                        rd_rst_busy;

// ====================== 写侧复合字打包 ======================
assign fifo_din = {s_axis_tuser, s_axis_tlast, s_axis_tkeep, s_axis_tdata};

// ============================================================================
// 写侧三段式 FSM
// ============================================================================

// 第一段：状态寄存器
always @(posedge s_aclk or negedge s_aresetn) begin
    if (!s_aresetn) begin
        wr_curr_state <= WR_IDLE;
    end else begin
        wr_curr_state <= wr_next_state;
    end
end

// 第二段：次态组合逻辑
always @(*) begin
    case (wr_curr_state)
        WR_IDLE: begin
            if (!wr_rst_busy) begin
                wr_next_state = WR_ACTIVE;
            end else begin
                wr_next_state = WR_IDLE;
            end
        end
        WR_ACTIVE: begin
            wr_next_state = WR_ACTIVE;
        end
        default: begin
            wr_next_state = WR_IDLE;
        end
    endcase
end

// 第三段：输出逻辑
assign fifo_wr_en    = s_axis_tvalid & s_axis_tready & (wr_curr_state == WR_ACTIVE);
assign s_axis_tready = (wr_curr_state == WR_ACTIVE) & ~fifo_full;

// ============================================================================
// 读侧三段式 FSM
// ============================================================================

// 第一段：状态寄存器
always @(posedge m_aclk or negedge m_aresetn) begin
    if (!m_aresetn) begin
        rd_curr_state <= RD_IDLE;
    end else begin
        rd_curr_state <= rd_next_state;
    end
end

// 第二段：次态组合逻辑
always @(*) begin
    case (rd_curr_state)
        RD_IDLE: begin
            if (!rd_rst_busy) begin
                rd_next_state = RD_ACTIVE;
            end else begin
                rd_next_state = RD_IDLE;
            end
        end
        RD_ACTIVE: begin
            rd_next_state = RD_ACTIVE;
        end
        default: begin
            rd_next_state = RD_IDLE;
        end
    endcase
end

// 第三段：输出逻辑
assign fifo_rd_en   = m_axis_tvalid & m_axis_tready & (rd_curr_state == RD_ACTIVE);
assign m_axis_tvalid = (rd_curr_state == RD_ACTIVE) & ~fifo_empty;

// 读侧复合字解包
assign {m_axis_tuser, m_axis_tlast, m_axis_tkeep, m_axis_tdata} = fifo_dout;

// ============================================================================
// XPM 异步 FIFO 实例化
// ============================================================================
xpm_fifo_async #(
    .FIFO_MEMORY_TYPE    ("block"),
    .ECC_MODE            ("no_ecc"),
    .FIFO_WRITE_DEPTH    (FIFO_DEPTH),
    .WRITE_DATA_WIDTH    (COMPOSITE_W),
    .READ_DATA_WIDTH     (COMPOSITE_W),
    .FIFO_READ_LATENCY   (1),
    .WR_DATA_COUNT_WIDTH ($clog2(FIFO_DEPTH)+1),
    .RD_DATA_COUNT_WIDTH ($clog2(FIFO_DEPTH)+1),
    .PROG_FULL_THRESH    (FIFO_DEPTH/2),
    .PROG_EMPTY_THRESH   (16)
) u_async_fifo (
    .wr_clk         (s_aclk),
    .rd_clk         (m_aclk),
    .rst            (~s_aresetn),

    .din            (fifo_din),
    .wr_en          (fifo_wr_en),
    .full           (fifo_full),
    .wr_rst_busy    (wr_rst_busy),
    .rd_en          (fifo_rd_en),
    .dout           (fifo_dout),
    .empty          (fifo_empty),
    .rd_rst_busy    (rd_rst_busy),

    .sbiterr        (),
    .dbiterr        (),
    .wr_data_count  (),
    .rd_data_count  (),
    .prog_full      (),
    .prog_empty     (),
    .overflow       (),
    .underflow      ()
);

endmodule
