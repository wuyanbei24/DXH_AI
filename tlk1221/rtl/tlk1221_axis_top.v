`timescale 1ns / 1ps

module tlk1221_axis_top
#(
    // AXI4-Stream 参数
    parameter C_AXIS_DATA_WIDTH = 8,    // 用户侧数据位宽，默认8bit
    parameter C_AXIS_USER_WIDTH = 1,    // TUSER位宽，bit0标记K字符
    // FIFO 参数
    parameter FIFO_DEPTH         = 512,
    parameter FIFO_DATA_WIDTH    = 10,   // PHY侧固定10bit
    // TLK1221 默认控制参数
    parameter DEFAULT_SYNCEN     = 1'b1,
    parameter DEFAULT_PRBSEN     = 1'b0,
    parameter DEFAULT_TX_DIS     = 1'b0
)(
    // ====================== 用户侧 AXI4-Stream 接口 ======================
    input  wire                         clk_user,
    input  wire                         rst_user_n,
    
    // AXI4-Stream TX Slave (FPGA → TLK1221)
    input  wire [C_AXIS_DATA_WIDTH-1:0] s_axis_tdata,
    input  wire [C_AXIS_USER_WIDTH-1:0] s_axis_tuser,
    input  wire                         s_axis_tvalid,
    output wire                         s_axis_tready,
    
    // AXI4-Stream RX Master (TLK1221 → FPGA)
    output wire [C_AXIS_DATA_WIDTH-1:0] m_axis_tdata,
    output wire [C_AXIS_USER_WIDTH-1:0] m_axis_tuser,
    output wire                         m_axis_tvalid,
    input  wire                         m_axis_tready,
    output wire                         m_axis_tlast,   // 预留帧结束标记
    output wire                         code_err,      // 8B10B 码组错误
    output wire                         disp_err,      // 8B10B 偏差错误
    output wire                         link_sync,     // 链路同步状态

    // ====================== TLK1221 硬件接口 ======================
    // 发送数据 10bit
    output wire                         PL_SFP_TD0,
    output wire                         PL_SFP_TD1,
    output wire                         PL_SFP_TD2,
    output wire                         PL_SFP_TD3,
    output wire                         PL_SFP_TD4,
    output wire                         PL_SFP_TD5,
    output wire                         PL_SFP_TD6,
    output wire                         PL_SFP_TD7,
    output wire                         PL_SFP_TD8,
    output wire                         PL_SFP_TD9,
    
    // 接收数据 10bit
    input  wire                         PL_SFP_RD0,
    input  wire                         PL_SFP_RD1,
    input  wire                         PL_SFP_RD2,
    input  wire                         PL_SFP_RD3,
    input  wire                         PL_SFP_RD4,
    input  wire                         PL_SFP_RD5,
    input  wire                         PL_SFP_RD6,
    input  wire                         PL_SFP_RD7,
    input  wire                         PL_SFP_RD8,
    input  wire                         PL_SFP_RD9,
    
    // 时钟与状态
    input  wire                         PL_SFP_RBC0,
    input  wire                         PL_SFP_RBC1,
    input  wire                         PL_SFP_SYNC,
    input  wire                         PL_SFP_CLK,
    
    // 控制输出
    output wire                         PL_SFP_SYNCEN,
    output wire                         PL_SFP_PRBSEN,
    output wire                         PL_TX_DIS
);

// ====================== 内部信号定义 ======================
// 时钟缓冲后信号
wire                        clk_phy_tx;
wire                        clk_phy_rx;

// PHY 侧复位
reg  [2:0]                  rst_phy_tx_sync;
reg  [2:0]                  rst_phy_rx_sync;
wire                        rst_phy_tx_n;
wire                        rst_phy_rx_n;

// SYNC 信号跨时钟域同步
reg  [2:0]                  sync_sync_reg;

// TX 路径信号
wire [FIFO_DATA_WIDTH-1:0]  tx_fifo_wr_data;
wire                        tx_fifo_wr_en;
wire                        tx_fifo_full;
wire [FIFO_DATA_WIDTH-1:0]  tx_fifo_rd_data;
wire                        tx_fifo_rd_en;
wire                        tx_fifo_empty;
wire [$clog2(FIFO_DEPTH)+1-1:0] tx_fifo_rd_count;

// RX 路径信号
wire [FIFO_DATA_WIDTH-1:0]  rx_fifo_wr_data;
wire                        rx_fifo_wr_en;
wire                        rx_fifo_full;
wire [FIFO_DATA_WIDTH-1:0]  rx_fifo_rd_data;
wire                        rx_fifo_rd_en;
wire                        rx_fifo_empty;

// PHY 侧数据总线
wire [9:0]                  tlk_tx_data_bus;
wire [9:0]                  tlk_rx_data_bus;

// ====================== 时钟缓冲 ======================
// 发送参考时钟单端全局缓冲
// IBUFG u_ibufg_tx_clk (
    // .I(PL_SFP_CLK),
    // .O(clk_phy_tx)
// );
assign clk_phy_tx = clk_user;

// 接收恢复时钟差分全局缓冲 (CDC-2 修复: 恢复时钟必须走全局缓冲)
// IBUFGDS u_ibufgds_rx_clk (
    // .I(PL_SFP_RBC0),
    // .IB(PL_SFP_RBC1),
    // .O(clk_phy_rx)
// );


   BUFG u_ibufgds_rx_clk (
      .O(clk_phy_rx), // 1-bit output: Clock output
      .I(PL_SFP_RBC0)  // 1-bit input: Clock input
   );


// ====================== PHY 侧复位同步（异步复位同步释放） ======================
always @(posedge clk_phy_tx or negedge rst_user_n) begin
    if(!rst_user_n)
        rst_phy_tx_sync <= 3'b000;
    else
        rst_phy_tx_sync <= {rst_phy_tx_sync[1:0], 1'b1};
end
assign rst_phy_tx_n = rst_phy_tx_sync[2];

always @(posedge clk_phy_rx or negedge rst_user_n) begin
    if(!rst_user_n)
        rst_phy_rx_sync <= 3'b000;
    else
        rst_phy_rx_sync <= {rst_phy_rx_sync[1:0], 1'b1};
end
assign rst_phy_rx_n = rst_phy_rx_sync[2];

// ====================== SYNC 信号跨时钟同步到用户域 ======================
always @(posedge clk_user or negedge rst_user_n) begin
    if(!rst_user_n)
        sync_sync_reg <= 3'b000;
    else
        sync_sync_reg <= {sync_sync_reg[1:0], PL_SFP_SYNC};
end
assign link_sync = sync_sync_reg[2];

// ====================== 硬件引脚位宽映射 ======================
// 发送数据：总线拆分为单bit引脚
assign {PL_SFP_TD9, PL_SFP_TD8, PL_SFP_TD7, PL_SFP_TD6, PL_SFP_TD5,
        PL_SFP_TD4, PL_SFP_TD3, PL_SFP_TD2, PL_SFP_TD1, PL_SFP_TD0} = tlk_tx_data_bus;

// 接收数据：单bit引脚合并为总线
assign tlk_rx_data_bus = {PL_SFP_RD9, PL_SFP_RD8, PL_SFP_RD7, PL_SFP_RD6, PL_SFP_RD5,
                          PL_SFP_RD4, PL_SFP_RD3, PL_SFP_RD2, PL_SFP_RD1, PL_SFP_RD0};

// ====================== 控制引脚赋值 ======================
assign PL_SFP_SYNCEN = DEFAULT_SYNCEN;
assign PL_SFP_PRBSEN = DEFAULT_PRBSEN;
assign PL_TX_DIS     = DEFAULT_TX_DIS;

// ====================== 1. AXI4-Stream 用户层 + 8B10B 编解码 ======================
tlk1221_axis_user
#(
    .C_AXIS_DATA_WIDTH(C_AXIS_DATA_WIDTH),
    .C_AXIS_USER_WIDTH(C_AXIS_USER_WIDTH),
    .FIFO_DATA_WIDTH(FIFO_DATA_WIDTH)
)
u_axis_user(
    .clk_user(clk_user),
    .rst_user_n(rst_user_n),
    .link_sync(link_sync),
    
    .s_axis_tdata(s_axis_tdata),
    .s_axis_tuser(s_axis_tuser),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready),
    
    .m_axis_tdata(m_axis_tdata),
    .m_axis_tuser(m_axis_tuser),
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tready(m_axis_tready),
    .m_axis_tlast(m_axis_tlast),

    .tx_fifo_wr_data(tx_fifo_wr_data),
    .tx_fifo_wr_en(tx_fifo_wr_en),
    .tx_fifo_full(tx_fifo_full),

    .rx_fifo_rd_data(rx_fifo_rd_data),
    .rx_fifo_rd_en(rx_fifo_rd_en),
    .rx_fifo_empty(rx_fifo_empty)
);

// ====================== 2. TLK1221 PHY 物理层接口 ======================
tlk1221_phy_if
#(
    .FIFO_DATA_WIDTH(FIFO_DATA_WIDTH),
    .RD_DATA_COUNT_WIDTH($clog2(FIFO_DEPTH)+1),
    .FIFO_DEPTH(FIFO_DEPTH)
)
u_phy_if(
    .clk_phy_tx(clk_phy_tx),
    .rst_phy_tx_n(rst_phy_tx_n),
    .clk_phy_rx(clk_phy_rx),
    .rst_phy_rx_n(rst_phy_rx_n),
    
    .tlk_tx_data(tlk_tx_data_bus),
    .tlk_rx_data(tlk_rx_data_bus),
    .tlk_rx_sync(PL_SFP_SYNC),
    
    .tx_fifo_rd_data(tx_fifo_rd_data),
    .tx_fifo_rd_en(tx_fifo_rd_en),
    .tx_fifo_empty(tx_fifo_empty),
    .tx_fifo_rd_count(tx_fifo_rd_count),
    
    .rx_fifo_wr_data(rx_fifo_wr_data),
    .rx_fifo_wr_en(rx_fifo_wr_en),
    .rx_fifo_full(rx_fifo_full),
    .phy_code_err(phy_code_err),
    .phy_disp_err(phy_disp_err)
);

// ====================== 8B10B 解码错误标志跨时钟同步 ======================
// code_err / disp_err 由 tlk1221_phy_if 在 clk_phy_rx 域产生，需同步到 clk_user
// 后送顶层输出；2-FF 同步器消除跨域亚稳，供后级错误监测使用。
wire phy_code_err;
wire phy_disp_err;
reg  code_err_s1, code_err_s2, disp_err_s1, disp_err_s2;
always @(posedge clk_user or negedge rst_user_n) begin
    if(!rst_user_n) begin
        code_err_s1 <= 1'b0; code_err_s2 <= 1'b0;
        disp_err_s1 <= 1'b0; disp_err_s2 <= 1'b0;
    end else begin
        code_err_s1 <= phy_code_err; code_err_s2 <= code_err_s1;
        disp_err_s1 <= phy_disp_err; disp_err_s2 <= disp_err_s1;
    end
end
assign code_err = code_err_s2;
assign disp_err = disp_err_s2;

// ====================== 3. TX 异步 FIFO（User → PHY_TX） ======================
xpm_fifo_async
#(
    .FIFO_MEMORY_TYPE    ("block"),
    .ECC_MODE            ("no_ecc"),
    .FIFO_WRITE_DEPTH    (FIFO_DEPTH),
    .WRITE_DATA_WIDTH    (FIFO_DATA_WIDTH),
    .READ_DATA_WIDTH     (FIFO_DATA_WIDTH),
    .FIFO_READ_LATENCY   (1),
    .READ_MODE           ("std"),      // UG974: std 模式, dout 在 rd_en 后 1 拍有效
    .CDC_SYNC_STAGES     (4),          // UG974: 异步 CDC 建议 4 级同步, 提升 MTBF
    // .USE_AXI_PROTOCOL    (0),
    .WR_DATA_COUNT_WIDTH ($clog2(FIFO_DEPTH)+1),
    .RD_DATA_COUNT_WIDTH ($clog2(FIFO_DEPTH)+1),
    .PROG_FULL_THRESH    (FIFO_DEPTH/2),
    .PROG_EMPTY_THRESH   (16)
    // .FIFO_VALID_FLAGS    (0)
)
u_tx_async_fifo(
    .wr_clk(clk_user),
    .rd_clk(clk_phy_tx),
    .rst(!rst_user_n),
    
    .din(tx_fifo_wr_data),
    .wr_en(tx_fifo_wr_en),
    .rd_en(tx_fifo_rd_en),
    
    .dout(tx_fifo_rd_data),
    .full(tx_fifo_full),
    .empty(tx_fifo_empty),
    
    .sbiterr(),
    .dbiterr(),
    .wr_data_count(),
    .rd_data_count(tx_fifo_rd_count),
    .prog_full(),
    .prog_empty(),
    .overflow(),
    .underflow(),
    .wr_rst_busy(),
    .rd_rst_busy()
);









// ====================== 4. RX 异步 FIFO（PHY_RX → User） ======================
xpm_fifo_async
#(
    .FIFO_MEMORY_TYPE    ("block"),
    .ECC_MODE            ("no_ecc"),
    .FIFO_WRITE_DEPTH    (FIFO_DEPTH),
    .WRITE_DATA_WIDTH    (FIFO_DATA_WIDTH),
    .READ_DATA_WIDTH     (FIFO_DATA_WIDTH),
    .FIFO_READ_LATENCY   (1),
    .READ_MODE           ("std"),      // UG974: std 模式, dout 在 rd_en 后 1 拍有效
    .CDC_SYNC_STAGES     (4),          // UG974: 异步 CDC 建议 4 级同步, 提升 MTBF
    // .USE_AXI_PROTOCOL    (0),
    .WR_DATA_COUNT_WIDTH ($clog2(FIFO_DEPTH)+1),
    .RD_DATA_COUNT_WIDTH ($clog2(FIFO_DEPTH)+1),
    .PROG_FULL_THRESH    (FIFO_DEPTH/2),
    .PROG_EMPTY_THRESH   (16)
    // .FIFO_VALID_FLAGS    (0)
)
u_rx_async_fifo(
    .wr_clk(clk_phy_rx),
    .rd_clk(clk_user),
    .rst(!rst_phy_rx_n),
    
    .din(rx_fifo_wr_data),
    .wr_en(rx_fifo_wr_en),
    .rd_en(rx_fifo_rd_en),
    
    .dout(rx_fifo_rd_data),
    .full(rx_fifo_full),
    .empty(rx_fifo_empty),
    
    .sbiterr(),
    .dbiterr(),
    .wr_data_count(),
    .rd_data_count(),
    .prog_full(),
    .prog_empty(),
    .overflow(),
    .underflow(),
    .wr_rst_busy(),
    .rd_rst_busy()
);

endmodule