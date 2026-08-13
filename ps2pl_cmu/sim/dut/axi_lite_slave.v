module axi_lite_slave(
    input               s_axi_aclk,
    input               s_axi_aresetn,
    // AXI4-Lite 写地址通道
    input      [31:0]   s_axi_awaddr,
    input               s_axi_awvalid,
    output reg          s_axi_awready,
    // AXI4-Lite 写数据通道
    input      [31:0]   s_axi_wdata,
    input      [3:0]    s_axi_wstrb,
    input               s_axi_wvalid,
    output reg          s_axi_wready,
    // AXI4-Lite 写响应通道
    output reg [1:0]    s_axi_bresp,
    output reg          s_axi_bvalid,
    input               s_axi_bready,
    // AXI4-Lite 读地址通道
    input      [31:0]   s_axi_araddr,
    input               s_axi_arvalid,
    output reg          s_axi_arready,
    // AXI4-Lite 读数据通道
    output reg [31:0]   s_axi_rdata,
    output reg [1:0]    s_axi_rresp,
    output reg          s_axi_rvalid,
    input               s_axi_rready,
    // 内部寄存器总线
    output     [7:0]    reg_addr,       // P-02: 改为wire，组合逻辑复用
    output reg          reg_wr_en,
    output reg [31:0]   reg_wr_data,
    output reg [3:0]    reg_wr_strb,    // P-01: 新增WSTRB透传端口
    input      [31:0]   reg_rd_data,
    output reg          reg_rd_en,
    // TX BRAM A口
    output     [6:0]    tx_bram_addr,   // P-02: 改为wire，组合逻辑复用
    output reg          tx_bram_wr_en,
    output reg [31:0]   tx_bram_wdata,
    input      [31:0]   tx_bram_rdata,
    // RX BRAM A口
    output     [6:0]    rx_bram_addr,   // P-02: 改为wire，组合逻辑复用
    input      [31:0]   rx_bram_rdata
);

//===================== 地址空间译码参数（11位字节地址） =====================
localparam [10:0] REG_BASE     = 11'h000;
localparam [10:0] REG_END      = 11'h0FF;
localparam [10:0] TX_BRAM_BASE = 11'h100;
localparam [10:0] TX_BRAM_END  = 11'h2FF;
localparam [10:0] RX_BRAM_BASE = 11'h300;
localparam [10:0] RX_BRAM_END  = 11'h4FF;

// [FIX-P15] PS 侧 BRAM 地址相对化：AXI 字节地址 >>2 得到的是以 0x000 为基的字
// 地址，而 PL 侧（tx/rx_data_path）以区域 0 为基访问 PortB。两块 BRAM 真双口、
// PortA 32bit(addr*4) / PortB 16bit(addr*2)，必须保证 PS 写址与 PL 读址指向同一
// 字节。故 PS 侧字地址需减去区域基址字偏移：TX=0x100>>2=0x40，RX=0x300>>2=0xC0。
localparam [6:0] TX_AW_OFFSET = 7'h40;
localparam [6:0] RX_AW_OFFSET = 7'hC0;

//===================== 内部信号 =====================
reg [10:0] wr_addr_latch;
reg [10:0] rd_addr_latch;
reg        aw_captured;   // AW 已缓存
reg        w_captured;    // W  已缓存
reg [31:0] w_data_latch;
reg [3:0]  w_strb_latch;
reg        wr_pending;    // AW&W 均到齐，待执行
reg [1:0]  wr_resp_q;
reg        rd_addr_sent;  // 读地址已发往 BRAM，等待取数

// P-02: 读/写通道独立的地址寄存器（消除多驱动）
reg [7:0]  wr_reg_addr;
reg [6:0]  wr_tx_bram_addr;
reg [7:0]  rd_reg_addr;
reg [6:0]  rd_tx_bram_addr;
reg [6:0]  rd_rx_bram_addr;

// P-02: 组合逻辑复用输出（AXI4-Lite不支持同时读写，读优先）
assign reg_addr     = rd_addr_sent ? rd_reg_addr     : wr_reg_addr;
assign tx_bram_addr = rd_addr_sent ? rd_tx_bram_addr : wr_tx_bram_addr;
assign rx_bram_addr = rd_rx_bram_addr;

// 写地址区间命中（组合）
wire hit_reg  = (wr_addr_latch >= REG_BASE)  && (wr_addr_latch <= REG_END);
wire hit_tx   = (wr_addr_latch >= TX_BRAM_BASE) && (wr_addr_latch <= TX_BRAM_END);

// P-09: 读地址区间命中（使用已锁存的rd_addr_latch，与取数拍对齐）
wire rd_hit_reg = (rd_addr_latch >= REG_BASE)  && (rd_addr_latch <= REG_END);
wire rd_hit_tx  = (rd_addr_latch >= TX_BRAM_BASE) && (rd_addr_latch <= TX_BRAM_END);
wire rd_hit_rx  = (rd_addr_latch >= RX_BRAM_BASE) && (rd_addr_latch <= RX_BRAM_END);

//===================== 写通道控制（AW/W 独立缓存，成对执行） =====================
always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
    if(!s_axi_aresetn) begin
        s_axi_awready   <= 1'b0;
        s_axi_wready    <= 1'b0;
        s_axi_bvalid    <= 1'b0;
        s_axi_bresp     <= 2'b00;
        wr_addr_latch   <= 11'd0;
        w_data_latch    <= 32'd0;
        w_strb_latch    <= 4'd0;
        aw_captured     <= 1'b0;
        w_captured      <= 1'b0;
        wr_pending      <= 1'b0;
        reg_wr_en       <= 1'b0;
        reg_wr_data     <= 32'd0;
        reg_wr_strb     <= 4'd0;
        wr_reg_addr     <= 8'd0;
        tx_bram_wr_en   <= 1'b0;
        tx_bram_wdata   <= 32'd0;
        wr_tx_bram_addr <= 7'd0;
    end else begin
        // 默认撤销单拍脉冲
        reg_wr_en     <= 1'b0;
        tx_bram_wr_en <= 1'b0;

        // ---- AW 通道：未缓存时拉高 awready，握手时锁存地址 ----
        if(!aw_captured && !wr_pending) begin
            s_axi_awready <= 1'b1;
        end
        if(s_axi_awvalid && s_axi_awready) begin
            wr_addr_latch <= s_axi_awaddr[10:0];
            aw_captured   <= 1'b1;
            s_axi_awready <= 1'b0;
        end

        // ---- W 通道：未缓存时拉高 wready，握手时锁存数据 ----
        if(!w_captured && !wr_pending) begin
            s_axi_wready <= 1'b1;
        end
        if(s_axi_wvalid && s_axi_wready) begin
            w_data_latch <= s_axi_wdata;
            w_strb_latch <= s_axi_wstrb;
            w_captured   <= 1'b1;
            s_axi_wready <= 1'b0;
        end

        // ---- AW 与 W 均到齐：执行一次写 ----
        if(aw_captured && w_captured && !wr_pending && !s_axi_bvalid) begin
            wr_pending <= 1'b1;
            aw_captured <= 1'b0;
            w_captured  <= 1'b0;
            if(hit_reg) begin
                reg_wr_en       <= 1'b1;
                wr_reg_addr     <= wr_addr_latch[7:0];
                reg_wr_data     <= w_data_latch;
                reg_wr_strb     <= w_strb_latch;   // P-01: WSTRB 透传
                wr_resp_q       <= 2'b00;          // OKAY
            end else if(hit_tx) begin
                if(w_strb_latch == 4'b1111) begin
                    wr_tx_bram_addr <= wr_addr_latch[8:2] - TX_AW_OFFSET; // [FIX-P15] 区域相对字地址
                    tx_bram_wdata   <= w_data_latch;
                    tx_bram_wr_en   <= 1'b1;
                    wr_resp_q       <= 2'b00;
                end else begin
                    wr_resp_q <= 2'b10;        // SLVERR：BRAM 区不支持部分写
                end
            end else begin
                wr_resp_q <= 2'b11;            // DECERR：未命中
            end
        end

        // ---- B 通道：wr_pending 成立后给出 BRESP ----
        if(wr_pending && !s_axi_bvalid) begin
            s_axi_bvalid <= 1'b1;
            s_axi_bresp  <= wr_resp_q;
            wr_pending   <= 1'b0;
        end else if(s_axi_bvalid && s_axi_bready) begin
            s_axi_bvalid <= 1'b0;
        end
    end
end

//===================== 读通道控制（两段式：发地址 → 取数） =====================
// P-09: AR握手时用 s_axi_araddr 即时判断区域（而非旧 rd_addr_latch）
wire [10:0] ar_addr_imm    = s_axi_araddr[10:0];
wire        ar_hit_reg_imm = (ar_addr_imm >= REG_BASE)     && (ar_addr_imm <= REG_END);
wire        ar_hit_tx_imm  = (ar_addr_imm >= TX_BRAM_BASE) && (ar_addr_imm <= TX_BRAM_END);
wire        ar_hit_rx_imm  = (ar_addr_imm >= RX_BRAM_BASE) && (ar_addr_imm <= RX_BRAM_END);

always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
    if(!s_axi_aresetn) begin
        s_axi_arready   <= 1'b0;
        s_axi_rvalid    <= 1'b0;
        s_axi_rresp     <= 2'b00;
        s_axi_rdata     <= 32'd0;
        rd_addr_latch   <= 11'd0;
        reg_rd_en       <= 1'b0;
        rd_addr_sent    <= 1'b0;
        rd_reg_addr     <= 8'd0;
        rd_tx_bram_addr <= 7'd0;
        rd_rx_bram_addr <= 7'd0;
    end else begin
        reg_rd_en <= 1'b0;

        // ---- AR 通道：空闲时拉高 arready，握手时锁存地址 ----
        if(!s_axi_rvalid && !rd_addr_sent) begin
            s_axi_arready <= 1'b1;
        end
        if(s_axi_arvalid && s_axi_arready) begin
            rd_addr_latch <= s_axi_araddr[10:0];
            s_axi_arready <= 1'b0;
            rd_addr_sent  <= 1'b1;
            // P-09: 使用即时地址判断区域，而非旧 rd_addr_latch
            if(ar_hit_reg_imm) begin
                rd_reg_addr <= s_axi_araddr[7:0];
                reg_rd_en   <= 1'b1;
            end else if(ar_hit_tx_imm) begin
                rd_tx_bram_addr <= s_axi_araddr[8:2] - TX_AW_OFFSET; // [FIX-P15]
            end else if(ar_hit_rx_imm) begin
                rd_rx_bram_addr <= s_axi_araddr[8:2] - RX_AW_OFFSET; // [FIX-P15]
            end
        end

        // ---- 取数拍：rd_addr_sent 置位后下一拍组装 R 通道 ----
        if(rd_addr_sent) begin
            if(rd_hit_reg) begin
                s_axi_rdata <= reg_rd_data;
                s_axi_rresp <= 2'b00;          // OKAY
            end else if(rd_hit_tx) begin
                s_axi_rdata <= tx_bram_rdata;
                s_axi_rresp <= 2'b00;
            end else if(rd_hit_rx) begin
                s_axi_rdata <= rx_bram_rdata;
                s_axi_rresp <= 2'b00;
            end else begin
                s_axi_rdata <= 32'd0;
                s_axi_rresp <= 2'b11;          // P-12: DECERR 越界读
            end
            s_axi_rvalid <= 1'b1;
            rd_addr_sent <= 1'b0;
        end else if(s_axi_rvalid && s_axi_rready) begin
            s_axi_rvalid <= 1'b0;
        end
    end
end

endmodule
