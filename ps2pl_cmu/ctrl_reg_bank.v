module ctrl_reg_bank(
    input               s_axi_aclk,
    input               s_axi_aresetn,
    input               clk_1m,
    input               rst_n_1m,
    // 寄存器总线（AXI时钟域）
    input      [7:0]    reg_addr,
    input               reg_wr_en,
    input      [31:0]   reg_wr_data,
    input      [3:0]    reg_wr_strb,   // WSTRB（由 axi_lite_slave 透传）
    input               reg_rd_en,
    output reg [31:0]   reg_rd_data,
    // PS→PL 同步输出（1MHz域）
    output              tx_start_pl,   // 单拍脉冲
    output     [7:0]    tx_len_pl,
    output              rx_irq_en_pl,
    // PL→PS 同步输入（1MHz域）
    input               tx_done_pl,    // 单拍脉冲
    input               rx_ready_pl,   // 单拍脉冲
    input      [7:0]    rx_len_pl
);

//===================== 寄存器定义 =====================
localparam CTRL_REG_ADDR = 8'h00;
localparam LEN_REG_ADDR  = 8'h04;

reg tx_start_ps;     // PS 域 TX_START 电平（W1S 语义：写1 置位，PL消费后回清）
reg tx_irq_en;       // PS 域 RX_IRQ_EN
reg [7:0] tx_len_ps; // PS 域 TX_LEN
reg tx_done_st;      // PS 域 TX_DONE 状态（PL置位/W1C）
reg rx_ready_st;     // PS 域 RX_READY 状态（PL置位/W1C）
reg [7:0] rx_len_ps; // PS 域 RX_LEN

//---- TX_START 边沿同步（toggle + 边沿检测） ----
reg        tx_start_toggle_q;   // PS 域 toggle 寄存器
reg        tgl_sync1, tgl_sync2, tgl_sync2_d;
assign tx_start_pl = tgl_sync2 ^ tgl_sync2_d;  // P-06: 异或检测任意翻转边沿

//---- TX_LEN 握手同步（PS→PL） ----
reg        tx_len_req;          // PS 域请求
reg        tx_len_ack_sync1, tx_len_ack_sync2;  // PL→PS ack
reg        tx_len_ack_pl;       // PL 域 ack
reg [7:0]  tx_len_hold;         // PL 域稳定保持
reg        tx_len_req_sync1, tx_len_req_sync2;  // PS→PL req

//---- RX_IRQ_EN 电平同步 ----
reg        irq_en_s1, irq_en_s2;
assign rx_irq_en_pl = irq_en_s2;

//---- TX_DONE 脉冲同步（PL→PS） ----
reg        txd_tgl_q;           // PL 域 toggle
reg        txd_s1, txd_s2, txd_s2_d;
wire       tx_done_edge = txd_s2 ^ txd_s2_d;    // P-06同类: 异或检测

//---- RX_READY 脉冲同步（PL→PS） ----
reg        rxr_tgl_q;           // PL 域 toggle
reg        rxr_s1, rxr_s2, rxr_s2_d;
wire       rx_ready_edge = rxr_s2 ^ rxr_s2_d;    // P-06同类: 异或检测

//---- RX_LEN 握手同步（PL→PS） ----
reg        rx_len_req;          // PL 域请求
reg [7:0]  rx_len_hold_pl;      // P-05/P-07: PL域保持数据的寄存器（仅PL域驱动）
reg [7:0]  rx_len_hold_ps;      // PS域锁存的数据（仅PS域驱动）
reg        rx_len_ack_ps;       // P-07: PS域产生的ack
reg        rx_len_ack_to_pl_s1, rx_len_ack_to_pl_s2; // P-07: ack 同步到PL域
reg        rx_len_req_s1, rx_len_req_s2;

//===================== 寄存器读写（AXI域） =====================
always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
    if(!s_axi_aresetn) begin
        tx_start_ps     <= 1'b0;
        tx_irq_en       <= 1'b0;
        tx_len_ps       <= 8'd0;
        tx_done_st      <= 1'b0;
        rx_ready_st     <= 1'b0;
        rx_len_ps       <= 8'd0;
        tx_start_toggle_q <= 1'b0;
        tx_len_req      <= 1'b0;
        reg_rd_data     <= 32'd0;
    end else begin
        // ---- PL→PS 脉冲边沿置位状态 ----
        if(tx_done_edge)  tx_done_st  <= 1'b1;
        if(rx_ready_edge) rx_ready_st <= 1'b1;

        // ---- RX_LEN 握手采样 ----
        // P-04修复: 使用 rx_len_ack_ps（RX方向）而非 tx_len_ack_sync2（TX方向）
        if(rx_len_req_s2 && !rx_len_ack_ps) begin
            rx_len_ps <= rx_len_hold_ps;
        end

        // ---- PS 写操作（支持 WSTRB） ----
        if(reg_wr_en) begin
            case(reg_addr)
                CTRL_REG_ADDR: begin
                    // Bit0 TX_START：W1S，写1 置位并 toggle
                    if(reg_wr_strb[0] && reg_wr_data[0]) begin
                        tx_start_ps       <= 1'b1;
                        tx_start_toggle_q <= ~tx_start_toggle_q;
                    end
                    // Bit1 TX_DONE：W1C，写1 清除
                    if(reg_wr_strb[0] && reg_wr_data[1])
                        tx_done_st <= 1'b0;
                    // Bit2 RX_READY：W1C，写1 清除
                    if(reg_wr_strb[0] && reg_wr_data[2])
                        rx_ready_st <= 1'b0;
                    // Bit3 RX_IRQ_EN：RW
                    if(reg_wr_strb[0])
                        tx_irq_en <= reg_wr_data[3];
                end
                LEN_REG_ADDR: begin
                    if(reg_wr_strb[0]) begin
                        tx_len_ps  <= reg_wr_data[7:0];
                        tx_len_req <= 1'b1;   // 触发握手
                    end
                end
            endcase
        end

        // ---- TX_LEN 握手：收到 PL ack 后撤销 req ----
        if(tx_len_ack_sync2) begin
            tx_len_req  <= 1'b0;
            tx_start_ps <= 1'b0;   // P-13: PL消费后自动回清tx_start_ps
        end

        // ---- PS 读操作 ----
        if(reg_rd_en) begin
            case(reg_addr)
                CTRL_REG_ADDR: reg_rd_data <= {29'd0, tx_irq_en, rx_ready_st, tx_done_st, tx_start_ps};
                LEN_REG_ADDR:  reg_rd_data <= {8'd0, rx_len_ps, 8'd0, tx_len_ps};
                default:       reg_rd_data <= 32'd0;
            endcase
        end
    end
end

//===================== PS→PL：TX_START toggle 同步 + 上升沿检测 =====================
always @(posedge clk_1m or negedge rst_n_1m) begin
    if(!rst_n_1m) begin
        tgl_sync1 <= 1'b0;
        tgl_sync2 <= 1'b0;
        tgl_sync2_d <= 1'b0;
    end else begin
        tgl_sync1   <= tx_start_toggle_q;
        tgl_sync2   <= tgl_sync1;
        tgl_sync2_d <= tgl_sync2;
    end
end

//===================== PS→PL：TX_LEN 握手同步 =====================
always @(posedge clk_1m or negedge rst_n_1m) begin
    if(!rst_n_1m) begin
        tx_len_req_sync1 <= 1'b0;
        tx_len_req_sync2 <= 1'b0;
        tx_len_hold      <= 8'd0;
        tx_len_ack_pl    <= 1'b0;
    end else begin
        tx_len_req_sync1 <= tx_len_req;
        tx_len_req_sync2 <= tx_len_req_sync1;
        // 检测到 req 上升：锁存数据并回 ack
        if(tx_len_req_sync2 && !tx_len_ack_pl) begin
            tx_len_hold   <= tx_len_ps;  // 数据在 req 期间保持稳定
            tx_len_ack_pl <= 1'b1;
        end else if(!tx_len_req_sync2) begin
            tx_len_ack_pl <= 1'b0;
        end
    end
end
assign tx_len_pl = tx_len_hold;

// ack 回传到 PS 域（2FF）
always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
    if(!s_axi_aresetn) begin
        tx_len_ack_sync1 <= 1'b0;
        tx_len_ack_sync2 <= 1'b0;
    end else begin
        tx_len_ack_sync1 <= tx_len_ack_pl;
        tx_len_ack_sync2 <= tx_len_ack_sync1;
    end
end

//===================== PS→PL：RX_IRQ_EN 电平同步 =====================
always @(posedge clk_1m or negedge rst_n_1m) begin
    if(!rst_n_1m) begin
        irq_en_s1 <= 1'b0;
        irq_en_s2 <= 1'b0;
    end else begin
        irq_en_s1 <= tx_irq_en;
        irq_en_s2 <= irq_en_s1;
    end
end

//===================== PL→PS：TX_DONE 脉冲同步（toggle + 边沿） =====================
always @(posedge clk_1m or negedge rst_n_1m) begin
    if(!rst_n_1m)
        txd_tgl_q <= 1'b0;
    else if(tx_done_pl)
        txd_tgl_q <= ~txd_tgl_q;
end
always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
    if(!s_axi_aresetn) begin
        txd_s1 <= 1'b0; txd_s2 <= 1'b0; txd_s2_d <= 1'b0;
    end else begin
        txd_s1   <= txd_tgl_q;
        txd_s2   <= txd_s1;
        txd_s2_d <= txd_s2;
    end
end

//===================== PL→PS：RX_READY 脉冲同步（toggle + 边沿） =====================
always @(posedge clk_1m or negedge rst_n_1m) begin
    if(!rst_n_1m)
        rxr_tgl_q <= 1'b0;
    else if(rx_ready_pl)
        rxr_tgl_q <= ~rxr_tgl_q;
end
always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
    if(!s_axi_aresetn) begin
        rxr_s1 <= 1'b0; rxr_s2 <= 1'b0; rxr_s2_d <= 1'b0;
    end else begin
        rxr_s1   <= rxr_tgl_q;
        rxr_s2   <= rxr_s1;
        rxr_s2_d <= rxr_s2;
    end
end

//===================== PL→PS：RX_LEN 握手同步（P-05/P-07重写） =====================
// PL域：产生req + 保持数据稳定
always @(posedge clk_1m or negedge rst_n_1m) begin
    if(!rst_n_1m) begin
        rx_len_req      <= 1'b0;
        rx_len_hold_pl  <= 8'd0;
        rx_len_ack_to_pl_s1 <= 1'b0;
        rx_len_ack_to_pl_s2 <= 1'b0;
    end else begin
        // P-07: ack从PS域同步到PL域（2FF）
        rx_len_ack_to_pl_s1 <= rx_len_ack_ps;
        rx_len_ack_to_pl_s2 <= rx_len_ack_to_pl_s1;

        if(rx_ready_pl) begin
            rx_len_req     <= 1'b1;
            rx_len_hold_pl <= rx_len_pl;   // 锁存数据，req期间保持稳定
        end else if(rx_len_ack_to_pl_s2) begin
            rx_len_req <= 1'b0;            // 收到同步后的ack，撤销req
        end
    end
end

// PS域：同步req + 锁存数据 + 产生ack
always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
    if(!s_axi_aresetn) begin
        rx_len_req_s1  <= 1'b0;
        rx_len_req_s2  <= 1'b0;
        rx_len_hold_ps <= 8'd0;
        rx_len_ack_ps  <= 1'b0;
    end else begin
        rx_len_req_s1 <= rx_len_req;
        rx_len_req_s2 <= rx_len_req_s1;
        if(rx_len_req_s2 && !rx_len_ack_ps) begin
            rx_len_hold_ps <= rx_len_hold_pl;  // 数据在req期间稳定
            rx_len_ack_ps  <= 1'b1;
        end else if(!rx_len_req_s2) begin
            rx_len_ack_ps  <= 1'b0;
        end
    end
end

endmodule
