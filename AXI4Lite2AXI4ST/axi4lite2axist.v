//============================================================================
// axi4lite2axist.v
// ----------------------------------------------------------------------------
// AXI4-Lite Slave <-> AXI4-Stream Master/Slave 桥接（命令组包 + 响应解包）
//
// V3 版（2026-07-25）：采用 Xilinx XPM 宏 (xpm_fifo_sync) 替换全部手写 FIFO
//   - 6 组 FIFO（AW/W/WRQ/RDQ/BRSP/RRSP）全部替换为 xpm_fifo_sync 实例
//   - 使用 FWFT 模式，保持原"组合预读 + 按需弹出"行为
//   - 多字段打包为单宽 FIFO 字，消除手动指针/计数管理
//   - 利用 Xilinx 原语自动推断 BRAM/分布式 RAM，提升综合质量与时序
//
// V2 修正保留：
//   D-01/D-02: 响应通道死锁 -> RX 状态机无条件接收，按帧类型路由
//   D-03:      inside 操作符 -> 显式比较链（Verilog-2001 兼容）
//   D-04:      AW/W 同拍要求 -> AW/W 独立 FIFO 解耦
//   D-05:      写优先饥饿 -> 轮询仲裁
//   D-06/D-12: 地址低4位丢失 -> 地址独立成拍
//   D-07:      时序竞争 -> FIFO + 仲裁器架构
//
// 帧格式（V2/V3）：
//   写命令帧（5拍）: HEAD | AWADDR | WDATA | {WSTRB} | TAIL
//   读命令帧（3拍）: HEAD | ARADDR | TAIL
//   写响应帧（3拍）: HEAD | {BRESP} | TAIL
//   读响应帧（4拍）: HEAD | RDATA | {RRESP} | TAIL
//============================================================================
module axi4lite2axist #(
    parameter C_S_AXI_DATA_WIDTH = 32,
    parameter C_S_AXI_ADDR_WIDTH = 32,
    parameter C_AXIS_DATA_WIDTH  = 32,
    parameter C_FIFO_DEPTH       = 16  // AW/W/WRQ/RDQ/BRSP/RRSP FIFO 深度（须为 2 的幂，最小 16）
)(
    input  wire                                 aclk,
    input  wire                                 aresetn,

    // ========== AXI4-Lite Slave 写通道 ==========
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]        s_axi_awaddr,
    input  wire [2:0]                           s_axi_awprot,
    input  wire                                 s_axi_awvalid,
    output wire                                 s_axi_awready,

    input  wire [C_S_AXI_DATA_WIDTH-1:0]        s_axi_wdata,
    input  wire [C_S_AXI_DATA_WIDTH/8-1:0]      s_axi_wstrb,
    input  wire                                 s_axi_wvalid,
    output wire                                 s_axi_wready,

    output reg  [1:0]                           s_axi_bresp,
    output reg                                  s_axi_bvalid,
    input  wire                                 s_axi_bready,

    // ========== AXI4-Lite Slave 读通道 ==========
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]        s_axi_araddr,
    input  wire [2:0]                           s_axi_arprot,
    input  wire                                 s_axi_arvalid,
    output wire                                 s_axi_arready,

    output reg  [C_S_AXI_DATA_WIDTH-1:0]        s_axi_rdata,
    output reg  [1:0]                           s_axi_rresp,
    output reg                                  s_axi_rvalid,
    input  wire                                 s_axi_rready,

    // ========== AXI4-Stream 命令通道（Master 发） ==========
    output reg  [C_AXIS_DATA_WIDTH-1:0]         m_axis_cmd_tdata,
    output reg                                  m_axis_cmd_tvalid,
    output reg                                  m_axis_cmd_tlast,
    input  wire                                 m_axis_cmd_tready,

    // ========== AXI4-Stream 响应通道（Slave 收） ==========
    input  wire [C_AXIS_DATA_WIDTH-1:0]         s_axis_rsp_tdata,
    input  wire                                 s_axis_rsp_tvalid,
    input  wire                                 s_axis_rsp_tlast,
    output wire                                 s_axis_rsp_tready
);

    // ========== 帧格式常量 ==========
    localparam [7:0] FRAME_MAGIC_HEAD  = 8'hAA;
    localparam [7:0] FRAME_MAGIC_TAIL  = 8'h55;
    localparam [7:0] FRAME_TYPE_WR_CMD = 8'h01;
    localparam [7:0] FRAME_TYPE_RD_CMD = 8'h02;
    localparam [7:0] FRAME_TYPE_WR_RSP = 8'h11;
    localparam [7:0] FRAME_TYPE_RD_RSP = 8'h12;

    // ========== FIFO 数据位宽常量 ==========
    // AW FIFO:  {awaddr[31:0], awprot[2:0]} = 35 bit
    // W  FIFO:  {wdata[31:0], wstrb[3:0]}   = 36 bit
    // WRQ FIFO: {addr[31:0], data[31:0], strb[3:0]} = 68 bit
    // RDQ FIFO: {addr[31:0]}                = 32 bit
    // BRSP FIFO:{bresp[1:0]}                      = 2 bit
    // RRSP FIFO:{rdata[31:0], rresp[1:0]}          = 34 bit
    localparam AW_FIFO_W   = C_S_AXI_ADDR_WIDTH + 3;                          // 35
    localparam W_FIFO_W    = C_S_AXI_DATA_WIDTH + C_S_AXI_DATA_WIDTH/8;       // 36
    localparam WRQ_FIFO_W  = C_S_AXI_ADDR_WIDTH + C_S_AXI_DATA_WIDTH + C_S_AXI_DATA_WIDTH/8; // 68
    localparam RDQ_FIFO_W  = C_S_AXI_ADDR_WIDTH;                              // 32
    localparam BRSP_FIFO_W = 2;                                               // 2
    localparam RRSP_FIFO_W = C_S_AXI_DATA_WIDTH + 2;                          // 34

    // XPM FIFO 复位（active-high）
    wire fifo_rst = ~aresetn;

    //=====================================================================
    // AW FIFO：缓存写地址通道（xpm_fifo_sync, FWFT）
    //=====================================================================
    wire [AW_FIFO_W-1:0]   aw_din, aw_dout;
    wire                   aw_full, aw_empty;
    wire                   aw_wr_en, aw_rd_en;

    assign aw_din       = {s_axi_awaddr, s_axi_awprot};
    assign aw_wr_en     = s_axi_awvalid && !aw_full;
    assign s_axi_awready = !aw_full;
    assign aw_rd_en     = make_wrq;  // AW+W 配对时弹出

    xpm_fifo_sync #(
        .FIFO_MEMORY_TYPE    ("distributed"),
        .ECC_MODE            ("no_ecc"),
        .FIFO_WRITE_DEPTH    (C_FIFO_DEPTH),
        .WRITE_DATA_WIDTH    (AW_FIFO_W),
        .READ_DATA_WIDTH     (AW_FIFO_W),
        .READ_MODE           ("fwft"),
        .USE_ADV_FEATURES    ("0000"),
        .WR_DATA_COUNT_WIDTH (1),
        .FULL_RESET_VALUE    (0)
    ) u_aw_fifo (
        .rst              (fifo_rst),
        .wr_clk           (aclk),
        .din              (aw_din),
        .wr_en            (aw_wr_en),
        .full             (aw_full),
        .overflow         (),
        .prog_full        (),
        .wr_data_count    (),
        .almost_full      (),
        .wr_rst_busy      (),
        .rd_en            (aw_rd_en),
        .dout             (aw_dout),
        .empty            (aw_empty),
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

    //=====================================================================
    // W FIFO：缓存写数据通道（xpm_fifo_sync, FWFT）
    //=====================================================================
    wire [W_FIFO_W-1:0]    w_din, w_dout;
    wire                   w_full, w_empty;
    wire                   w_wr_en, w_rd_en;

    assign w_din       = {s_axi_wdata, s_axi_wstrb};
    assign w_wr_en     = s_axi_wvalid && !w_full;
    assign s_axi_wready = !w_full;
    assign w_rd_en     = make_wrq;

    xpm_fifo_sync #(
        .FIFO_MEMORY_TYPE    ("distributed"),
        .ECC_MODE            ("no_ecc"),
        .FIFO_WRITE_DEPTH    (C_FIFO_DEPTH),
        .WRITE_DATA_WIDTH    (W_FIFO_W),
        .READ_DATA_WIDTH     (W_FIFO_W),
        .READ_MODE           ("fwft"),
        .USE_ADV_FEATURES    ("0000"),
        .WR_DATA_COUNT_WIDTH (1),
        .FULL_RESET_VALUE    (0)
    ) u_w_fifo (
        .rst              (fifo_rst),
        .wr_clk           (aclk),
        .din              (w_din),
        .wr_en            (w_wr_en),
        .full             (w_full),
        .overflow         (),
        .prog_full        (),
        .wr_data_count    (),
        .almost_full      (),
        .wr_rst_busy      (),
        .rd_en            (w_rd_en),
        .dout             (w_dout),
        .empty            (w_empty),
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

    //=====================================================================
    // WRQ FIFO：组装后的写命令请求（AW+W 配对）（xpm_fifo_sync, FWFT）
    //=====================================================================
    wire [WRQ_FIFO_W-1:0]  wrq_din, wrq_dout;
    wire                   wrq_full, wrq_empty;
    wire                   wrq_wr_en, wrq_rd_en;

    // 从 AW/W FIFO 的 FWFT 输出中组合 WRQ 写入数据
    assign wrq_din   = {aw_dout[AW_FIFO_W-1:3],   // awaddr
                        w_dout[W_FIFO_W-1:4],      // wdata
                        w_dout[3:0]};               // wstrb
    assign wrq_wr_en = make_wrq;
    assign wrq_rd_en = tx_pop_wrq;

    xpm_fifo_sync #(
        .FIFO_MEMORY_TYPE    ("distributed"),
        .ECC_MODE            ("no_ecc"),
        .FIFO_WRITE_DEPTH    (C_FIFO_DEPTH),
        .WRITE_DATA_WIDTH    (WRQ_FIFO_W),
        .READ_DATA_WIDTH     (WRQ_FIFO_W),
        .READ_MODE           ("fwft"),
        .USE_ADV_FEATURES    ("0000"),
        .WR_DATA_COUNT_WIDTH (1),
        .FULL_RESET_VALUE    (0)
    ) u_wrq_fifo (
        .rst              (fifo_rst),
        .wr_clk           (aclk),
        .din              (wrq_din),
        .wr_en            (wrq_wr_en),
        .full             (wrq_full),
        .overflow         (),
        .prog_full        (),
        .wr_data_count    (),
        .almost_full      (),
        .wr_rst_busy      (),
        .rd_en            (wrq_rd_en),
        .dout             (wrq_dout),
        .empty            (wrq_empty),
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

    //=====================================================================
    // RDQ FIFO：读命令请求（xpm_fifo_sync, FWFT）
    //=====================================================================
    wire [RDQ_FIFO_W-1:0]  rdq_din, rdq_dout;
    wire                   rdq_full, rdq_empty;
    wire                   rdq_wr_en, rdq_rd_en;

    assign rdq_din    = s_axi_araddr;
    assign rdq_wr_en  = s_axi_arvalid && !rdq_full;
    assign s_axi_arready = !rdq_full;
    assign rdq_rd_en  = tx_pop_rdq;

    xpm_fifo_sync #(
        .FIFO_MEMORY_TYPE    ("distributed"),
        .ECC_MODE            ("no_ecc"),
        .FIFO_WRITE_DEPTH    (C_FIFO_DEPTH),
        .WRITE_DATA_WIDTH    (RDQ_FIFO_W),
        .READ_DATA_WIDTH     (RDQ_FIFO_W),
        .READ_MODE           ("fwft"),
        .USE_ADV_FEATURES    ("0000"),
        .WR_DATA_COUNT_WIDTH (1),
        .FULL_RESET_VALUE    (0)
    ) u_rdq_fifo (
        .rst              (fifo_rst),
        .wr_clk           (aclk),
        .din              (rdq_din),
        .wr_en            (rdq_wr_en),
        .full             (rdq_full),
        .overflow         (),
        .prog_full        (),
        .wr_data_count    (),
        .almost_full      (),
        .wr_rst_busy      (),
        .rd_en            (rdq_rd_en),
        .dout             (rdq_dout),
        .empty            (rdq_empty),
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

    //=====================================================================
    // BRSP FIFO：写响应缓存（xpm_fifo_sync, FWFT）
    //=====================================================================
    wire [BRSP_FIFO_W-1:0] brsp_din, brsp_dout;
    wire                   brsp_full, brsp_empty;
    wire                   brsp_wr_en, brsp_rd_en;

    assign brsp_wr_en = rx_push_b && !brsp_full;
    assign brsp_din   = rx_push_bresp;
    assign brsp_rd_en = (!s_axi_bvalid || (s_axi_bvalid && s_axi_bready)) && !brsp_empty;

    xpm_fifo_sync #(
        .FIFO_MEMORY_TYPE    ("distributed"),
        .ECC_MODE            ("no_ecc"),
        .FIFO_WRITE_DEPTH    (C_FIFO_DEPTH),
        .WRITE_DATA_WIDTH    (BRSP_FIFO_W),
        .READ_DATA_WIDTH     (BRSP_FIFO_W),
        .READ_MODE           ("fwft"),
        .USE_ADV_FEATURES    ("0000"),
        .WR_DATA_COUNT_WIDTH (1),
        .FULL_RESET_VALUE    (0)
    ) u_brsp_fifo (
        .rst              (fifo_rst),
        .wr_clk           (aclk),
        .din              (brsp_din),
        .wr_en            (brsp_wr_en),
        .full             (brsp_full),
        .overflow         (),
        .prog_full        (),
        .wr_data_count    (),
        .almost_full      (),
        .wr_rst_busy      (),
        .rd_en            (brsp_rd_en),
        .dout             (brsp_dout),
        .empty            (brsp_empty),
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

    //=====================================================================
    // RRSP FIFO：读响应缓存（xpm_fifo_sync, FWFT）
    //=====================================================================
    wire [RRSP_FIFO_W-1:0] rrsp_din, rrsp_dout;
    wire                   rrsp_full, rrsp_empty;
    wire                   rrsp_wr_en, rrsp_rd_en;

    assign rrsp_wr_en = rx_push_r && !rrsp_full;
    assign rrsp_din   = {rx_push_rdata, rx_push_rresp};
    assign rrsp_rd_en = (!s_axi_rvalid || (s_axi_rvalid && s_axi_rready)) && !rrsp_empty;

    xpm_fifo_sync #(
        .FIFO_MEMORY_TYPE    ("distributed"),
        .ECC_MODE            ("no_ecc"),
        .FIFO_WRITE_DEPTH    (C_FIFO_DEPTH),
        .WRITE_DATA_WIDTH    (RRSP_FIFO_W),
        .READ_DATA_WIDTH     (RRSP_FIFO_W),
        .READ_MODE           ("fwft"),
        .USE_ADV_FEATURES    ("0000"),
        .WR_DATA_COUNT_WIDTH (1),
        .FULL_RESET_VALUE    (0)
    ) u_rrsp_fifo (
        .rst              (fifo_rst),
        .wr_clk           (aclk),
        .din              (rrsp_din),
        .wr_en            (rrsp_wr_en),
        .full             (rrsp_full),
        .overflow         (),
        .prog_full        (),
        .wr_data_count    (),
        .almost_full      (),
        .wr_rst_busy      (),
        .rd_en            (rrsp_rd_en),
        .dout             (rrsp_dout),
        .empty            (rrsp_empty),
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

    //=====================================================================
    // WRQ 组装逻辑：AW+W 配对时写入 WRQ FIFO
    //=====================================================================
    wire make_wrq = (!aw_empty) && (!w_empty) && (!wrq_full);

    //=====================================================================
    // TX 状态机：轮询 WRQ/RDQ，按帧格式组包发送
    //=====================================================================
    localparam [1:0] TX_IDLE = 2'd0,
                     TX_SEND = 2'd1;

    localparam [1:0] TX_KIND_NONE = 2'd0,
                     TX_KIND_WR   = 2'd1,
                     TX_KIND_RD   = 2'd2;

    reg [1:0]  tx_state, tx_next_state;
    reg [1:0]  tx_kind;
    reg [2:0]  tx_idx;       // 当前发送拍索引
    reg [2:0]  tx_total;     // 总拍数
    reg [7:0]  tx_type;      // 帧类型
    reg [31:0] tx_p0, tx_p1, tx_p2; // 净荷缓存
    reg        rr_sel;       // 轮询选择：0=优先WR, 1=优先RD

    reg tx_pop_wrq, tx_pop_rdq;

    wire tx_hs      = m_axis_cmd_tvalid && m_axis_cmd_tready;
    wire tx_last_hs = (tx_state == TX_SEND) && tx_hs && (tx_idx == (tx_total - 3'd1));

    // 第一段：状态寄存器
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) tx_state <= TX_IDLE;
        else          tx_state <= tx_next_state;
    end

    // 第二段：次态逻辑
    always @(*) begin
        tx_next_state = tx_state;
        case (tx_state)
            TX_IDLE: begin
                if (!wrq_empty || !rdq_empty)
                    tx_next_state = TX_SEND;
            end
            TX_SEND: begin
                if (tx_last_hs)
                    tx_next_state = TX_IDLE;
            end
            default: tx_next_state = TX_IDLE;
        endcase
    end

    // 第三段-A：组合输出（命令通道 tdata/tvalid/tlast）
    always @(*) begin
        m_axis_cmd_tdata  = {C_AXIS_DATA_WIDTH{1'b0}};
        m_axis_cmd_tvalid = 1'b0;
        m_axis_cmd_tlast  = 1'b0;

        if (tx_state == TX_SEND) begin
            m_axis_cmd_tvalid = 1'b1;
            if (tx_idx == 3'd0) begin
                // 包头
                m_axis_cmd_tdata = {FRAME_MAGIC_HEAD, tx_type, tx_total - 3'd2, 8'h00};
            end else if (tx_idx == (tx_total - 3'd1)) begin
                // 包尾
                m_axis_cmd_tdata = {FRAME_MAGIC_TAIL, 16'h0000, 8'h00};
                m_axis_cmd_tlast = 1'b1;
            end else begin
                // 净荷
                case (tx_idx)
                    3'd1:   m_axis_cmd_tdata = tx_p0;
                    3'd2:   m_axis_cmd_tdata = tx_p1;
                    3'd3:   m_axis_cmd_tdata = tx_p2;
                    default: m_axis_cmd_tdata = {C_AXIS_DATA_WIDTH{1'b0}};
                endcase
            end
        end
    end

    // 第三段-B：TX 内部寄存器更新
    // V3: 从 XPM FIFO 的 FWFT dout 直接读取数据，无需手动指针管理
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            tx_kind     <= TX_KIND_NONE;
            tx_idx      <= 3'd0;
            tx_total    <= 3'd0;
            tx_type     <= 8'd0;
            tx_p0       <= 32'd0;
            tx_p1       <= 32'd0;
            tx_p2       <= 32'd0;
            rr_sel      <= 1'b0;
            tx_pop_wrq  <= 1'b0;
            tx_pop_rdq  <= 1'b0;
        end else begin
            tx_pop_wrq <= 1'b0;
            tx_pop_rdq <= 1'b0;

            case (tx_state)
                TX_IDLE: begin
                    tx_idx <= 3'd0;
                    if (tx_next_state == TX_SEND) begin
                        // 轮询仲裁：根据 rr_sel 和两个 FIFO 的状态选择
                        if (!wrq_empty && !rdq_empty) begin
                            // 两者都有，按 rr_sel 轮询
                            if (!rr_sel) begin
                                tx_kind  <= TX_KIND_WR;
                                tx_type  <= FRAME_TYPE_WR_CMD;
                                tx_total <= 3'd5; // HEAD+ADDR+DATA+STRB+TAIL
                                // V3: 从 WRQ FIFO FWFT dout 直接读取
                                tx_p0    <= wrq_dout[WRQ_FIFO_W-1 -: C_S_AXI_ADDR_WIDTH]; // addr
                                tx_p1    <= wrq_dout[C_S_AXI_DATA_WIDTH+C_S_AXI_DATA_WIDTH/8-1 -: C_S_AXI_DATA_WIDTH]; // data
                                tx_p2    <= {{(C_AXIS_DATA_WIDTH-4){1'b0}}, wrq_dout[C_S_AXI_DATA_WIDTH/8-1:0]}; // strb
                            end else begin
                                tx_kind  <= TX_KIND_RD;
                                tx_type  <= FRAME_TYPE_RD_CMD;
                                tx_total <= 3'd3; // HEAD+ADDR+TAIL
                                // V3: 从 RDQ FIFO FWFT dout 直接读取
                                tx_p0    <= rdq_dout[RDQ_FIFO_W-1:0]; // addr
                                tx_p1    <= 32'd0;
                                tx_p2    <= 32'd0;
                            end
                        end else if (!wrq_empty) begin
                            tx_kind  <= TX_KIND_WR;
                            tx_type  <= FRAME_TYPE_WR_CMD;
                            tx_total <= 3'd5;
                            tx_p0    <= wrq_dout[WRQ_FIFO_W-1 -: C_S_AXI_ADDR_WIDTH];
                            tx_p1    <= wrq_dout[C_S_AXI_DATA_WIDTH+C_S_AXI_DATA_WIDTH/8-1 -: C_S_AXI_DATA_WIDTH];
                            tx_p2    <= {{(C_AXIS_DATA_WIDTH-4){1'b0}}, wrq_dout[C_S_AXI_DATA_WIDTH/8-1:0]};
                        end else begin
                            // !rdq_empty
                            tx_kind  <= TX_KIND_RD;
                            tx_type  <= FRAME_TYPE_RD_CMD;
                            tx_total <= 3'd3;
                            tx_p0    <= rdq_dout[RDQ_FIFO_W-1:0];
                            tx_p1    <= 32'd0;
                            tx_p2    <= 32'd0;
                        end
                    end
                end

                TX_SEND: begin
                    if (tx_hs) begin
                        if (tx_idx == (tx_total - 3'd1)) begin
                            // 最后一拍握手完成，弹出 FIFO，翻转轮询
                            tx_idx <= 3'd0;
                            if (tx_kind == TX_KIND_WR) tx_pop_wrq <= 1'b1;
                            if (tx_kind == TX_KIND_RD) tx_pop_rdq <= 1'b1;
                            rr_sel <= ~rr_sel;
                        end else begin
                            tx_idx <= tx_idx + 3'd1;
                        end
                    end
                end

                default: ;
            endcase
        end
    end

    //=====================================================================
    // RX 状态机：接收响应帧，按帧类型分发到 BRSP/RRSP FIFO
    //   修正 C-02：合并 RX_WAIT_HEAD + RX_WAIT_TYPE，同拍校验魔数并锁存类型
    //   修正 D-01/D-02：等待响应期间无条件 tready=1
    //=====================================================================
    localparam [1:0] RX_WAIT_HEAD = 2'd0,
                     RX_PAYLOAD   = 2'd1,
                     RX_WAIT_TAIL = 2'd2;

    reg [1:0]  rx_state, rx_next_state;
    reg [7:0]  rx_type;
    reg [1:0]  rx_need;  // 净荷拍数
    reg [1:0]  rx_cnt;
    reg [1:0]  rx_bresp_tmp;
    reg [31:0] rx_rdata_tmp;
    reg [1:0]  rx_rresp_tmp;   // 修正 M-04：读响应 RRESP 缓存

    reg        rx_push_b;
    reg [1:0]  rx_push_bresp;
    reg        rx_push_r;
    reg [31:0] rx_push_rdata;
    reg [1:0]  rx_push_rresp;  // 修正 M-04：读响应 RRESP 推送

    // 修正 D-01：仅在 RX_WAIT_TAIL 且目标 FIFO 满时才反压
    wire rx_tail_block = (rx_state == RX_WAIT_TAIL) &&
                         ( ((rx_type == FRAME_TYPE_WR_RSP) && brsp_full) ||
                           ((rx_type == FRAME_TYPE_RD_RSP) && rrsp_full) );

    assign s_axis_rsp_tready = !rx_tail_block;
    wire s_hs = s_axis_rsp_tvalid && s_axis_rsp_tready;

    // 第一段：状态寄存器
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) rx_state <= RX_WAIT_HEAD;
        else          rx_state <= rx_next_state;
    end

    // 第二段：次态逻辑（修正 C-02：合并状态，同拍校验魔数+类型）
    always @(*) begin
        rx_next_state = rx_state;
        case (rx_state)
            RX_WAIT_HEAD: begin
                if (s_hs && (s_axis_rsp_tdata[31:24] == FRAME_MAGIC_HEAD)) begin
                    if ((s_axis_rsp_tdata[23:16] == FRAME_TYPE_WR_RSP) ||
                        (s_axis_rsp_tdata[23:16] == FRAME_TYPE_RD_RSP))
                        rx_next_state = RX_PAYLOAD;
                    // 有效魔数但未知类型，丢弃此拍
                end
            end
            RX_PAYLOAD: begin
                if (s_hs && (rx_cnt + 2'd1 >= rx_need))
                    rx_next_state = RX_WAIT_TAIL;
            end
            RX_WAIT_TAIL: begin
                if (s_hs) rx_next_state = RX_WAIT_HEAD;
            end
            default: rx_next_state = RX_WAIT_HEAD;
        endcase
    end

    // 第三段：数据锁存与 FIFO 推入
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            rx_type       <= 8'd0;
            rx_need       <= 2'd0;
            rx_cnt        <= 2'd0;
            rx_bresp_tmp  <= 2'b00;
            rx_rdata_tmp  <= 32'd0;
            rx_rresp_tmp  <= 2'b00;
            rx_push_b     <= 1'b0;
            rx_push_bresp <= 2'b00;
            rx_push_r     <= 1'b0;
            rx_push_rdata <= 32'd0;
            rx_push_rresp <= 2'b00;
        end else begin
            rx_push_b <= 1'b0;
            rx_push_r <= 1'b0;

            if (s_hs) begin
                case (rx_state)
                    // 修正 C-02：同拍锁存帧类型和净荷长度
                    RX_WAIT_HEAD: begin
                        if (s_axis_rsp_tdata[31:24] == FRAME_MAGIC_HEAD) begin
                            rx_type <= s_axis_rsp_tdata[23:16];
                            rx_cnt  <= 2'd0;
                            if (s_axis_rsp_tdata[23:16] == FRAME_TYPE_WR_RSP)
                                rx_need <= 2'd1;  // 写响应 1 拍净荷
                            else if (s_axis_rsp_tdata[23:16] == FRAME_TYPE_RD_RSP)
                                rx_need <= 2'd2;  // 修正 M-04：读响应 2 拍净荷（RDATA + RRESP）
                            else
                                rx_need <= 2'd0;
                        end
                    end

                    RX_PAYLOAD: begin
                        if (rx_type == FRAME_TYPE_WR_RSP) begin
                            rx_bresp_tmp <= s_axis_rsp_tdata[1:0];
                        end else if (rx_type == FRAME_TYPE_RD_RSP) begin
                            // 修正 M-04：读响应分拍接收 RDATA 和 RRESP
                            case (rx_cnt)
                                2'd0: rx_rdata_tmp <= s_axis_rsp_tdata;       // 拍1: RDATA
                                2'd1: rx_rresp_tmp <= s_axis_rsp_tdata[1:0];  // 拍2: RRESP
                                default: ;
                            endcase
                        end
                        rx_cnt <= rx_cnt + 2'd1;
                    end

                    RX_WAIT_TAIL: begin
                        if ((s_axis_rsp_tdata[31:24] == FRAME_MAGIC_TAIL) && s_axis_rsp_tlast) begin
                            if (rx_type == FRAME_TYPE_WR_RSP) begin
                                rx_push_b     <= 1'b1;
                                rx_push_bresp <= rx_bresp_tmp;
                            end
                            if (rx_type == FRAME_TYPE_RD_RSP) begin
                                rx_push_r     <= 1'b1;
                                rx_push_rdata <= rx_rdata_tmp;
                                rx_push_rresp <= rx_rresp_tmp;
                            end
                        end
                    end

                    default: ;
                endcase
            end
        end
    end

    //=====================================================================
    // B 通道输出：从 BRSP FIFO 读取，驱动 AXI4-Lite B 通道
    // V3: brsp_rd_en 由 FIFO 实例直接处理，无需手动指针管理
    //=====================================================================
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            s_axi_bvalid <= 1'b0;
            s_axi_bresp  <= 2'b00;
        end else begin
            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;

            if (brsp_rd_en) begin
                // V3: 从 BRSP FIFO FWFT dout 直接读取
                s_axi_bresp  <= brsp_dout[BRSP_FIFO_W-1:0];
                s_axi_bvalid <= 1'b1;
            end
        end
    end

    //=====================================================================
    // R 通道输出：从 RRSP FIFO 读取，驱动 AXI4-Lite R 通道
    // V3: rrsp_rd_en 由 FIFO 实例直接处理，无需手动指针管理
    //=====================================================================
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            s_axi_rvalid <= 1'b0;
            s_axi_rdata  <= {C_S_AXI_DATA_WIDTH{1'b0}};
            s_axi_rresp  <= 2'b00;
        end else begin
            if (s_axi_rvalid && s_axi_rready)
                s_axi_rvalid <= 1'b0;

            if (rrsp_rd_en) begin
                // 修正 M-04：从 RRSP FIFO 提取 rdata 和 rresp
                s_axi_rdata  <= rrsp_dout[RRSP_FIFO_W-1:2];
                s_axi_rresp  <= rrsp_dout[1:0];
                s_axi_rvalid <= 1'b1;
            end
        end
    end

endmodule
