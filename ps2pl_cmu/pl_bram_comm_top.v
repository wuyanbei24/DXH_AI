module pl_bram_comm_top(
    // AXI4-Lite 从机接口（PS 时钟域）
    input               s_axi_aclk,
    input               s_axi_aresetn,
    input      [31:0]   s_axi_awaddr,
    input               s_axi_awvalid,
    output              s_axi_awready,
    input      [31:0]   s_axi_wdata,
    input      [3:0]    s_axi_wstrb,
    input               s_axi_wvalid,
    output              s_axi_wready,
    output     [1:0]    s_axi_bresp,
    output              s_axi_bvalid,
    input               s_axi_bready,
    input      [31:0]   s_axi_araddr,
    input               s_axi_arvalid,
    output              s_axi_arready,
    output     [31:0]   s_axi_rdata,
    output     [1:0]    s_axi_rresp,
    output              s_axi_rvalid,
    input               s_axi_rready,
    // PL 业务接口（1MHz 时钟域）
    input               clk_1m,
    input               rst_n_1m,
    input               pl_tx_req,      // PL 请求读取下发数据
    output              pl_tx_valid,    // 下发数据有效
    output     [15:0]   pl_tx_data,     // 下发数据输出
    input               pl_rx_valid,    // 上传数据有效
    input      [15:0]   pl_rx_data,     // 上传数据输入
    output              pl_rx_done,     // 一帧上传完成脉冲
    output              pl_rx_irq       // PL→PS 中断请求
);

//===================== 内部互联信号 =====================
// 寄存器总线
wire [31:0] reg_wr_data;
wire [31:0] reg_rd_data;
wire [7:0]  reg_addr;
wire        reg_wr_en;
wire        reg_rd_en;
wire [3:0]  reg_wr_strb;   // WSTRB 透传（修订新增）

// TX BRAM A口（PS侧）
wire [6:0]  tx_bram_a_addr;
wire [31:0] tx_bram_a_wdata;
wire        tx_bram_a_wr_en;
wire [31:0] tx_bram_a_rdata;

// RX BRAM A口（PS侧）
wire [6:0]  rx_bram_a_addr;
wire [31:0] rx_bram_a_rdata;

// 控制信号（跨时钟同步后）
wire        tx_start_pl;    // PS→PL 同步后（单拍脉冲）
wire [7:0]  tx_len_pl;      // PS→PL 同步后
wire        tx_done_pl;     // PL→PS 同步前（PL域脉冲）
wire        rx_ready_pl;    // PL→PS 同步前（PL域脉冲）
wire [7:0]  rx_len_pl;      // PL→PS 同步前（PL域）
wire        rx_irq_en_pl;   // PS→PL 同步后

// TX BRAM B口（PL侧）
wire [7:0]  tx_bram_b_addr;
wire [15:0] tx_bram_b_rdata;

// RX BRAM B口（PL侧）
wire [7:0]  rx_bram_b_addr;
wire        rx_bram_b_wr_en;
wire [15:0] rx_bram_b_wdata;

//===================== 子模块例化 =====================
// 1. AXI4-Lite 从机协议层
axi_lite_slave u_axi_lite_slave(
    .s_axi_aclk     (s_axi_aclk),
    .s_axi_aresetn  (s_axi_aresetn),
    // AXI4-Lite 接口
    .s_axi_awaddr   (s_axi_awaddr),
    .s_axi_awvalid  (s_axi_awvalid),
    .s_axi_awready  (s_axi_awready),
    .s_axi_wdata    (s_axi_wdata),
    .s_axi_wstrb    (s_axi_wstrb),
    .s_axi_wvalid   (s_axi_wvalid),
    .s_axi_wready   (s_axi_wready),
    .s_axi_bresp    (s_axi_bresp),
    .s_axi_bvalid   (s_axi_bvalid),
    .s_axi_bready   (s_axi_bready),
    .s_axi_araddr   (s_axi_araddr),
    .s_axi_arvalid  (s_axi_arvalid),
    .s_axi_arready  (s_axi_arready),
    .s_axi_rdata    (s_axi_rdata),
    .s_axi_rresp    (s_axi_rresp),
    .s_axi_rvalid   (s_axi_rvalid),
    .s_axi_rready   (s_axi_rready),
    // 寄存器总线
    .reg_addr       (reg_addr),
    .reg_wr_en      (reg_wr_en),
    .reg_wr_data    (reg_wr_data),
    .reg_wr_strb    (reg_wr_strb),
    .reg_rd_en      (reg_rd_en),
    .reg_rd_data    (reg_rd_data),
    // TX BRAM A口
    .tx_bram_addr   (tx_bram_a_addr),
    .tx_bram_wr_en  (tx_bram_a_wr_en),
    .tx_bram_wdata  (tx_bram_a_wdata),
    .tx_bram_rdata  (tx_bram_a_rdata),
    // RX BRAM A口
    .rx_bram_addr   (rx_bram_a_addr),
    .rx_bram_rdata  (rx_bram_a_rdata)
);

// 2. 控制寄存器组 + 跨时钟同步
ctrl_reg_bank u_ctrl_reg_bank(
    .s_axi_aclk     (s_axi_aclk),
    .s_axi_aresetn  (s_axi_aresetn),
    .clk_1m         (clk_1m),
    .rst_n_1m       (rst_n_1m),
    // 寄存器总线（AXI域）
    .reg_addr       (reg_addr),
    .reg_wr_en      (reg_wr_en),
    .reg_wr_data    (reg_wr_data),
    .reg_wr_strb    (reg_wr_strb),
    .reg_rd_en      (reg_rd_en),
    .reg_rd_data    (reg_rd_data),
    // PS→PL 同步输出
    .tx_start_pl    (tx_start_pl),
    .tx_len_pl      (tx_len_pl),
    .rx_irq_en_pl   (rx_irq_en_pl),
    // PL→PS 同步输入
    .tx_done_pl     (tx_done_pl),
    .rx_ready_pl    (rx_ready_pl),
    .rx_len_pl      (rx_len_pl)
);

// 3. TX 数据通路（PL读，三段式状态机）
tx_data_path u_tx_data_path(
    .clk_1m         (clk_1m),
    .rst_n          (rst_n_1m),
    // BRAM B口
    .bram_addr      (tx_bram_b_addr),
    .bram_rdata     (tx_bram_b_rdata),
    // 控制信号
    .tx_start       (tx_start_pl),
    .tx_len         (tx_len_pl),
    .tx_done        (tx_done_pl),
    // PL业务接口
    .pl_tx_req      (pl_tx_req),
    .pl_tx_valid    (pl_tx_valid),
    .pl_tx_data     (pl_tx_data)
);

// 4. RX 数据通路（PL写，三段式状态机）
rx_data_path u_rx_data_path(
    .clk_1m         (clk_1m),
    .rst_n          (rst_n_1m),
    // BRAM B口
    .bram_addr      (rx_bram_b_addr),
    .bram_wr_en     (rx_bram_b_wr_en),
    .bram_wdata     (rx_bram_b_wdata),
    // 控制信号
    .rx_irq_en      (rx_irq_en_pl),
    .rx_ready       (rx_ready_pl),
    .rx_len         (rx_len_pl),
    // PL业务接口
    .pl_rx_valid    (pl_rx_valid),
    .pl_rx_data     (pl_rx_data),
    .pl_rx_done     (pl_rx_done),
    .pl_rx_irq      (pl_rx_irq)
);

// 5. TX 真双口BRAM IP（用户在Vivado中例化，此处为接口示意）
// 配置：True Dual Port, PortA: 32bit x 128, PortB: 16bit x 256, 异步时钟
tx_bram_ip u_tx_bram_ip(
    .clka   (s_axi_aclk),
    .wea    (tx_bram_a_wr_en),
    .addra  (tx_bram_a_addr),
    .dina   (tx_bram_a_wdata),
    .douta  (tx_bram_a_rdata),
    .clkb   (clk_1m),
    .web    (1'b0),
    .addrb  (tx_bram_b_addr),
    .dinb   (16'd0),
    .doutb  (tx_bram_b_rdata)
);

// 6. RX 真双口BRAM IP
rx_bram_ip u_rx_bram_ip(
    .clka   (s_axi_aclk),
    .wea    (1'b0),
    .addra  (rx_bram_a_addr),
    .dina   (32'd0),
    .douta  (rx_bram_a_rdata),
    .clkb   (clk_1m),
    .web    (rx_bram_b_wr_en),
    .addrb  (rx_bram_b_addr),
    .dinb   (rx_bram_b_wdata),
    .doutb  ()
);

endmodule
