module tx_data_path(
    input               clk_1m,
    input               rst_n,
    // BRAM B口
    output reg [7:0]    bram_addr,
    input      [15:0]   bram_rdata,
    // 控制信号
    input               tx_start,      // 单拍脉冲
    input      [7:0]    tx_len,
    output reg          tx_done,       // 单拍脉冲
    // PL业务接口
    input               pl_tx_req,
    output reg          pl_tx_valid,
    output reg [15:0]   pl_tx_data
);

//===================== 状态定义（独热） =====================
localparam IDLE     = 2'b00;
localparam TX_ADDR  = 2'b01;   // 发地址
localparam TX_WAIT  = 2'b10;   // 等 BRAM 读延迟
localparam TX_OUT   = 2'b11;   // 输出数据

reg [1:0] curr_state;
reg [1:0] next_state;

reg [7:0] data_cnt;
reg [7:0] tx_len_latch;

// 组合逻辑次态变量
reg [7:0]  nxt_bram_addr;
reg        nxt_pl_tx_valid;
reg [15:0] nxt_pl_tx_data;
reg [7:0]  nxt_data_cnt;
reg [7:0]  nxt_tx_len_latch;
reg        nxt_tx_done;

// tx_start 上升沿检测
reg tx_start_d;
wire tx_start_pulse = tx_start & ~tx_start_d;

//===================== 第一段：时序逻辑 - 寄存器打拍 =====================
always @(posedge clk_1m or negedge rst_n) begin
    if(!rst_n) begin
        curr_state     <= IDLE;
        bram_addr      <= 8'd0;
        pl_tx_valid    <= 1'b0;
        pl_tx_data     <= 16'd0;
        data_cnt       <= 8'd0;
        tx_len_latch   <= 8'd0;
        tx_done        <= 1'b0;
        tx_start_d     <= 1'b0;
    end else begin
        curr_state     <= next_state;
        bram_addr      <= nxt_bram_addr;
        pl_tx_valid    <= nxt_pl_tx_valid;
        pl_tx_data     <= nxt_pl_tx_data;
        data_cnt       <= nxt_data_cnt;
        tx_len_latch   <= nxt_tx_len_latch;
        tx_done        <= nxt_tx_done;
        tx_start_d     <= tx_start;
    end
end

//===================== 第二段：组合逻辑 - 次态跳转 =====================
always @(*) begin
    next_state = curr_state;
    case(curr_state)
        IDLE: begin
            if(tx_start_pulse && pl_tx_req && tx_len > 8'd0)
                next_state = TX_ADDR;
        end
        TX_ADDR:  next_state = TX_WAIT;
        TX_WAIT:  next_state = TX_OUT;
        TX_OUT: begin
            if(data_cnt == tx_len_latch - 1'b1)
                next_state = IDLE;
            else
                next_state = TX_ADDR;
        end
        default: next_state = IDLE;
    endcase
end

//===================== 第三段：组合逻辑 - 输出逻辑 =====================
always @(*) begin
    nxt_bram_addr    = 8'd0;
    nxt_pl_tx_valid  = 1'b0;
    nxt_pl_tx_data   = 16'd0;
    nxt_data_cnt     = data_cnt;
    nxt_tx_len_latch = tx_len_latch;
    nxt_tx_done      = 1'b0;

    case(curr_state)
        IDLE: begin
            nxt_data_cnt = 8'd0;
            if(next_state == TX_ADDR)
                nxt_tx_len_latch = tx_len;   // 锁存长度
        end
        TX_ADDR: begin
            nxt_bram_addr = data_cnt;        // 发读地址
        end
        TX_WAIT: begin
            nxt_bram_addr = data_cnt;        // 保持地址稳定
        end
        TX_OUT: begin
            nxt_pl_tx_data  = bram_rdata;    // BRAM 数据已有效
            nxt_pl_tx_valid = 1'b1;
            if(data_cnt < tx_len_latch - 1'b1)
                nxt_data_cnt = data_cnt + 1'b1;
            else
                nxt_tx_done = 1'b1;          // 单拍脉冲
        end
        default: nxt_data_cnt = 8'd0;
    endcase
end

endmodule
