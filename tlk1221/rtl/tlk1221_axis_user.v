`timescale 1ns / 1ps

module tlk1221_axis_user
#(
    parameter C_AXIS_DATA_WIDTH = 8,
    parameter C_AXIS_USER_WIDTH = 1,
    parameter FIFO_DATA_WIDTH   = 10
)(
    input  wire                         clk_user,
    input  wire                         rst_user_n,
    input  wire                         link_sync,

    // AXI4-Stream TX Slave
    input  wire [C_AXIS_DATA_WIDTH-1:0] s_axis_tdata,
    input  wire [C_AXIS_USER_WIDTH-1:0] s_axis_tuser,
    input  wire                         s_axis_tvalid,
    output reg                          s_axis_tready,

    // AXI4-Stream RX Master
    output reg [C_AXIS_DATA_WIDTH-1:0]  m_axis_tdata,
    output reg [C_AXIS_USER_WIDTH-1:0]  m_axis_tuser,
    output reg                          m_axis_tvalid,
    input  wire                         m_axis_tready,
    output reg                          m_axis_tlast,

    // TX FIFO 写接口
    output wire [FIFO_DATA_WIDTH-1:0]   tx_fifo_wr_data,
    output reg                          tx_fifo_wr_en,
    input  wire                         tx_fifo_full,

    // RX FIFO 读接口
    input  wire [FIFO_DATA_WIDTH-1:0]   rx_fifo_rd_data,
    output reg                          rx_fifo_rd_en,
    input  wire                         rx_fifo_empty
);

// ====================== 内部信号 ======================
wire [7:0]  enc_din;
wire        enc_kin;
wire [9:0]  enc_dout;
wire        enc_code_err;

assign enc_din = s_axis_tdata[7:0];
assign enc_kin = s_axis_tuser[0];
assign tx_fifo_wr_data = enc_dout;

// ==================================================
// **************** TX 三段式状态机 ****************
// ==================================================
localparam TX_IDLE = 2'b01;
localparam TX_XFER = 2'b10;

reg [1:0] tx_curr_state;
reg [1:0] tx_next_state;

// 第一段：时序逻辑，状态寄存
always @(posedge clk_user or negedge rst_user_n) begin
    if(!rst_user_n)
        tx_curr_state <= TX_IDLE;
    else
        tx_curr_state <= tx_next_state;
end

// 第二段：组合逻辑，状态跳转
always @(*) begin
    tx_next_state = tx_curr_state;
    case(tx_curr_state)
        TX_IDLE: begin
            if(s_axis_tvalid && !tx_fifo_full && link_sync)
                tx_next_state = TX_XFER;
        end
        TX_XFER: begin
            tx_next_state = TX_IDLE;
        end
        default: tx_next_state = TX_IDLE;
    endcase
end

// 第三段：时序逻辑，输出控制
always @(posedge clk_user or negedge rst_user_n) begin
    if(!rst_user_n) begin
        s_axis_tready <= 1'b0;
        tx_fifo_wr_en <= 1'b0;
    end
    else begin
        s_axis_tready <= 1'b0;
        tx_fifo_wr_en <= 1'b0;
        case(tx_curr_state)
            TX_XFER: begin
                s_axis_tready <= 1'b1;
                tx_fifo_wr_en <= 1'b1;
            end
        endcase
    end
end

// ==================================================
// **************** RX 数据流（满吞吐流水线，修复 USER-RX-1 / FIFO 溢出）****************
// ==================================================
// 8B10B 解码已在 tlk1221_phy_if 的 clk_phy_rx 域完成，且仅把“非逗号”的数据字
// 写入 RX FIFO，因此本模块看到的 RX FIFO 中 *仅含数据字*（无 K28.5 逗号）。
//
// 数据路径延迟仅有 FIFO_READ_LATENCY=1（发出 rx_fifo_rd_en 后 1 拍
// rx_fifo_rd_data 更新），因此 read@M -> 数据有效@M+1。用 2 级移位寄存器
// (rx_v0/rx_v1, rx_s0/rx_s1) 把“有效”拍对齐到 beat 输出，实现 1/周期吞吐，
// 与写侧（线速率）严格匹配 —— 不再因“读慢于写”导致 512 深 FIFO 被空闲逗号
// 占满而溢出丢字（旧实现每 2 拍才读一次，写 1/拍，持续流量下必溢）。
//
// 背压：m_axis_tready 无效时冻结读（rx_out_stall）并保持当前 beat 重试。由于
// RX FIFO 仅存数据字（最多 600），背压期间读侧停止、写侧仅以 1/16ns（突发）
// 速率写入，FIFO 只会排空、不会溢出；背压解除后继续 1/周期读出。
reg [C_AXIS_DATA_WIDTH-1:0] rx_s0, rx_s1;
reg                         rx_v0, rx_v1;

wire rx_out_stall = m_axis_tvalid && !m_axis_tready;
wire rx_do_rd     = !rx_fifo_empty && link_sync && !rx_out_stall;

always @(posedge clk_user or negedge rst_user_n) begin
    if(!rst_user_n) begin
        rx_fifo_rd_en <= 1'b0;
        rx_s0 <= {C_AXIS_DATA_WIDTH{1'b0}};
        rx_s1 <= {C_AXIS_DATA_WIDTH{1'b0}};
        rx_v0 <= 1'b0;
        rx_v1 <= 1'b0;
        m_axis_tdata  <= {C_AXIS_DATA_WIDTH{1'b0}};
        m_axis_tuser  <= {C_AXIS_USER_WIDTH{1'b0}};
        m_axis_tvalid <= 1'b0;
        m_axis_tlast  <= 1'b0;
    end
    else begin
        rx_fifo_rd_en <= rx_do_rd;
        rx_v0 <= rx_do_rd;
        rx_v1 <= rx_v0;
        rx_s0 <= rx_fifo_rd_data[C_AXIS_DATA_WIDTH-1:0];
        rx_s1 <= rx_s0;
        // 输出：rx_v1 有效时 rx_s1 即对齐的数据字；背压时保持（重试）
        if(!rx_out_stall) begin
            m_axis_tvalid <= rx_v1;
            m_axis_tdata  <= rx_s1;
            m_axis_tuser  <= {{(C_AXIS_USER_WIDTH-1){1'b0}}, 1'b0}; // 仅数据字
            m_axis_tlast  <= 1'b0;
        end
        // rx_out_stall：保持 m_axis_tvalid / tdata 不变，直至 tready 返回
    end
end

// ====================== 8B10B 编码模块实例化 ======================
encode_8b10b
#(
    .REG_OUTPUT(1)
)
u_encode_8b10b(
    .clk(clk_user),
    .rst_n(rst_user_n),
    .din(enc_din),
    .kin(enc_kin),
    .dout(enc_dout),
    .code_err(enc_code_err)
);

endmodule
