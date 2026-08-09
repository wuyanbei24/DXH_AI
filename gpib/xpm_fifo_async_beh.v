`timescale 1ns / 1ps
//=============================================================================
// xpm_fifo_async (行为级仿真模型)  ——  仅用于仿真，禁止综合
//-----------------------------------------------------------------------------
// 本文件提供与 Xilinx 原语 xpm_fifo_async 相同接口/端口的 FWFT 异步 FIFO 模型，
// 用于在未安装 Vivado 的环境下（如 ModelSim）对 GPIB_fifo_in/out 进行功能仿真。
// 综合时由 Vivado 自动解析真实的 xpm_fifo_async 原语，本文件不参与综合。
// 实现要点：格雷码指针 + 2 级同步器，保证 full/empty 判定在异步时钟下安全。
//=============================================================================
module xpm_fifo_async #
(
    parameter integer FIFO_WRITE_DEPTH      = 16,
    parameter integer WRITE_DATA_WIDTH      = 8,
    parameter integer READ_DATA_WIDTH       = 8,
    parameter integer RD_DATA_COUNT_WIDTH   = 11,
    parameter integer WR_DATA_COUNT_WIDTH   = 11,
    parameter         READ_MODE             = "fwft",
    parameter integer FIFO_READ_LATENCY     = 0,
    parameter integer CDC_SYNC_STAGES       = 2,
    parameter         FIFO_MEMORY_TYPE      = "auto",
    parameter         ECC_MODE              = "no_ecc",
    parameter integer RELATED_CLOCKS        = 0,
    parameter         USE_ADV_FEATURES      = "0707",
    parameter integer PROG_EMPTY_THRESH     = 10,
    parameter integer PROG_FULL_THRESH      = 10,
    parameter integer CASCADE_HEIGHT        = 0,
    parameter         DOUT_RESET_VALUE      = "0",
    parameter integer FULL_RESET_VALUE      = 1,
    parameter integer WAKEUP_TIME           = 0
)(
    input  wire                            rst,
    input  wire                            wr_clk,
    input  wire                            rd_clk,
    input  wire                            wr_en,
    input  wire                            rd_en,
    input  wire [WRITE_DATA_WIDTH-1:0]     din,
    output wire  [READ_DATA_WIDTH-1:0]     dout,
    output wire                            full,
    output wire                            empty,
    output wire  [WR_DATA_COUNT_WIDTH-1:0] wr_data_count,
    output wire  [RD_DATA_COUNT_WIDTH-1:0] rd_data_count,
    output wire                            wr_ack,
    output wire                            rd_ack,
    output wire                            overflow,
    output wire                            underflow,
    input  wire                            sleep,
    input  wire                            injectsbiterr,
    input  wire                            injectdbiterr,
    output wire                            sbiterr,
    output wire                            dbiterr
);

    // 深度固定参数化：depth=16 -> 地址位宽 4（扩展指针 5 位）
    localparam AW = (FIFO_WRITE_DEPTH <= 16) ? 4 :
                    (FIFO_WRITE_DEPTH <= 32) ? 5 : 6;

    reg [WRITE_DATA_WIDTH-1:0] mem [0:(1<<AW)-1];
    reg [AW:0] wbin, rbin;          // 扩展二进制指针
    reg [AW:0] wptr_g, rptr_g;      // 格雷码指针
    reg [AW:0] rptr_g_ws1, rptr_g_ws2;  // rptr_g 同步到 wr_clk
    reg [AW:0] wptr_g_rs1, wptr_g_rs2;  // wptr_g 同步到 rd_clk
    reg [AW:0] rbin_ws1, rbin_ws2;      // rbin 同步到 wr_clk (仅计数)
    reg [AW:0] wbin_rs1, wbin_rs2;      // wbin 同步到 rd_clk (仅计数)

    function [AW:0] togray; input [AW:0] b; begin togray = (b >> 1) ^ b; end endfunction

    //-------------------- 写侧 (wr_clk) --------------------
    always @(posedge wr_clk or posedge rst) begin
        if (rst) begin
            wbin <= {AW+1{1'b0}}; wptr_g <= {AW+1{1'b0}};
        end else if (!sleep) begin
            if (wr_en && !full) begin
                mem[wbin[AW-1:0]] <= din;
                wbin               <= wbin + 1'b1;
                wptr_g             <= togray(wbin + 1'b1);
            end
        end
    end

    //-------------------- 读侧 (rd_clk) --------------------
    reg [READ_DATA_WIDTH-1:0] dout_r;
    always @(posedge rd_clk or posedge rst) begin
        if (rst) begin
            rbin <= {AW+1{1'b0}}; rptr_g <= {AW+1{1'b0}};
        end else if (!sleep) begin
            if (rd_en && !empty) begin
                rbin               <= rbin + 1'b1;
                rptr_g             <= togray(rbin + 1'b1);
            end
        end
    end

    // FWFT：dout 始终显示当前读指针处的字
    integer ri;
    always @(*) begin
        ri = rbin[AW-1:0];
        dout_r = mem[ri];
    end
    assign dout = dout_r;

    //-------------------- 格雷码指针跨时钟同步 --------------------
    always @(posedge wr_clk or posedge rst) begin
        if (rst) begin rptr_g_ws1 <= 0; rptr_g_ws2 <= 0; rbin_ws1 <= 0; rbin_ws2 <= 0; end
        else begin rptr_g_ws1 <= rptr_g; rptr_g_ws2 <= rptr_g_ws1; rbin_ws1 <= rbin; rbin_ws2 <= rbin_ws1; end
    end
    always @(posedge rd_clk or posedge rst) begin
        if (rst) begin wptr_g_rs1 <= 0; wptr_g_rs2 <= 0; wbin_rs1 <= 0; wbin_rs2 <= 0; end
        else begin wptr_g_rs1 <= wptr_g; wptr_g_rs2 <= wptr_g_rs1; wbin_rs1 <= wbin; wbin_rs2 <= wbin_rs1; end
    end

    //-------------------- full / empty (格雷码安全比较) --------------------
    assign full  = (wptr_g[AW] != rptr_g_ws2[AW]) &&
                   (wptr_g[AW-1:0] == rptr_g_ws2[AW-1:0]);
    assign empty = (rptr_g == wptr_g_rs2);

    //-------------------- 计数（仅用于调试，不参与流控） --------------------
    assign wr_data_count = wbin - rbin_ws2;
    assign rd_data_count = wbin_rs2 - rbin;

    assign wr_ack    = wr_en && !full;
    assign rd_ack    = rd_en && !empty;
    assign overflow  = wr_en && full;
    assign underflow = rd_en && empty;
    assign sbiterr   = 1'b0;
    assign dbiterr   = 1'b0;

endmodule
