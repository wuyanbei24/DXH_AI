module rx_data_path(
    input               clk_1m,
    input               rst_n,
    // BRAM B口
    output reg [7:0]    bram_addr,
    output reg          bram_wr_en,
    output reg [15:0]   bram_wdata,
    // 控制信号
    input               rx_irq_en,
    output reg          rx_ready,      // 单拍脉冲
    output reg [7:0]    rx_len,
    // PL业务接口
    input               pl_rx_valid,
    input      [15:0]   pl_rx_data,
    output reg          pl_rx_done,    // 单拍脉冲
    output reg          pl_rx_irq      // 单拍脉冲
);

//===================== 状态定义 =====================
localparam IDLE      = 2'b00;
localparam RX_WRITE  = 2'b01;
localparam RX_FINISH = 2'b10;

reg [1:0] curr_state;
reg [1:0] next_state;

reg [7:0] data_cnt;

// 组合逻辑次态变量
reg [7:0]  nxt_bram_addr;
reg        nxt_bram_wr_en;
reg [15:0] nxt_bram_wdata;
reg [7:0]  nxt_data_cnt;
reg [7:0]  nxt_rx_len;
reg        nxt_rx_ready;
reg        nxt_pl_rx_done;
reg        nxt_pl_rx_irq;

//===================== 第一段：时序逻辑 - 寄存器打拍 =====================
always @(posedge clk_1m or negedge rst_n) begin
    if(!rst_n) begin
        curr_state   <= IDLE;
        bram_addr    <= 8'd0;
        bram_wr_en   <= 1'b0;
        bram_wdata   <= 16'd0;
        data_cnt     <= 8'd0;
        rx_ready     <= 1'b0;
        rx_len       <= 8'd0;
        pl_rx_done   <= 1'b0;
        pl_rx_irq    <= 1'b0;
    end else begin
        curr_state   <= next_state;
        bram_addr    <= nxt_bram_addr;
        bram_wr_en   <= nxt_bram_wr_en;
        bram_wdata   <= nxt_bram_wdata;
        data_cnt     <= nxt_data_cnt;
        rx_len       <= nxt_rx_len;
        rx_ready     <= nxt_rx_ready;
        pl_rx_done   <= nxt_pl_rx_done;
        pl_rx_irq    <= nxt_pl_rx_irq;
    end
end

//===================== 第二段：组合逻辑 - 次态跳转 =====================
always @(*) begin
    next_state = curr_state;
    case(curr_state)
        IDLE: begin
            if(pl_rx_valid)
                next_state = RX_WRITE;
        end
        RX_WRITE: begin
            if(!pl_rx_valid || data_cnt == 8'd255)
                next_state = RX_FINISH;   // 先完成最后一拍写，再产生脉冲
            else
                next_state = RX_WRITE;
        end
        RX_FINISH:
            next_state = IDLE;
        default: next_state = IDLE;
    endcase
end

//===================== 第三段：组合逻辑 - 输出逻辑 =====================
always @(*) begin
    nxt_bram_addr  = 8'd0;
    nxt_bram_wr_en = 1'b0;
    nxt_bram_wdata = 16'd0;
    nxt_data_cnt   = data_cnt;
    nxt_rx_len     = rx_len;
    nxt_rx_ready   = 1'b0;
    nxt_pl_rx_done = 1'b0;
    nxt_pl_rx_irq  = 1'b0;

    case(curr_state)
        IDLE: begin
            nxt_data_cnt = 8'd0;
            // P-03修复：IDLE→RX_WRITE转换时立即写入首拍数据
            if(next_state == RX_WRITE) begin
                nxt_bram_addr  = 8'd0;
                nxt_bram_wr_en = 1'b1;
                nxt_bram_wdata = pl_rx_data;
                nxt_data_cnt   = 8'd1;    // 首拍已写，计数从1开始
            end
        end
        RX_WRITE: begin
            nxt_bram_addr  = data_cnt;
            nxt_bram_wr_en = 1'b1;
            nxt_bram_wdata = pl_rx_data;
            if(pl_rx_valid && data_cnt < 8'd255)
                nxt_data_cnt = data_cnt + 1'b1;
        end
        RX_FINISH: begin
            // 帧结束：锁存长度，产生单拍脉冲
            // P-08修复：data_cnt=255时防止溢出为0
            nxt_rx_len     = (data_cnt == 8'd0) ? 8'd1 : data_cnt;
            nxt_rx_ready   = 1'b1;
            nxt_pl_rx_done = 1'b1;
            if(rx_irq_en)
                nxt_pl_rx_irq = 1'b1;
        end
        default: nxt_data_cnt = 8'd0;
    endcase
end

endmodule
