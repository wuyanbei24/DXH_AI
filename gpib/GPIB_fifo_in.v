`timescale 1ns / 1ps

//=============================================================================
// GPIB_fifo_in : 接收 FIFO（GPIB -> M1 / APB）
//-----------------------------------------------------------------------------
//   写侧时钟 : sys_clk    （GPIB 数据到达，sys_clk 域，由受方握手 AH 产生）
//   读侧时钟 : APB_PCLK   （软件通过 APB 读取，APB_PCLK 域）
//   实现     : Xilinx XPM 异步 FIFO (xpm_fifo_async)，FWFT 模式
//   作用     : 该模块同时隔离 sys_clk 与 APB_PCLK 两个时钟域，
//              消除原为单时钟 FIFO 直接跨域带来的 CDC 风险（原 P0 问题）。
//=============================================================================
module GPIB_fifo_in #
(
    parameter   DATA_WIDTH  = 8,
    parameter   FIFO_DEPTH  = 16
)(
    input   wire                        WrClk   ,   // sys_clk
    input   wire                        RdClk   ,   // APB_PCLK
    input   wire    [DATA_WIDTH-1:0]    Data    ,   // GPIB_Data_FPGA_r
    input   wire                        WrEn    ,   // GPIB_infifo_w 上升沿脉冲 (sys_clk 域)
    input   wire                        RdEn    ,   // GPIB_infifo_r (APB_PCLK 域)
    input   wire                        Reset   ,   // ~GPIB_dvire_rstn (高有效)
    output  wire    [DATA_WIDTH-1:0]    Q       ,   // GPIB_Data_M1_r (APB_PCLK 域)
    output  wire                        Empty   ,   // GPIB_infifo_empty (APB_PCLK 域)
    output  wire                        Full        // GPIB_infifo_full  (sys_clk 域)
);

    xpm_fifo_async #(
        // .CASCADE_HEIGHT      (0),
        .CDC_SYNC_STAGES    (2),                // 跨时钟域同步级数
        .DOUT_RESET_VALUE   ("0"),
        .ECC_MODE           ("no_ecc"),
        .FIFO_MEMORY_TYPE   ("auto"),           // 由工具自动选择 block/distributed
        .FIFO_READ_LATENCY  (0),                // FWFT 模式必须为 0
        .FIFO_WRITE_DEPTH   (FIFO_DEPTH),       // 必须为 2 的幂 (>=16)
        .FULL_RESET_VALUE   (1),
        .PROG_EMPTY_THRESH  (10),
        .PROG_FULL_THRESH   (10),
        .RD_DATA_COUNT_WIDTH(5),
        .READ_DATA_WIDTH    (DATA_WIDTH),
        .READ_MODE          ("fwft"),           // 首字直通，便于 APB 直接读当前头
        .RELATED_CLOCKS     (0),                // 异步时钟（若两时钟同源可设 1）
        .USE_ADV_FEATURES   ("0707"),           // 使能 wr/rd data count
        .WAKEUP_TIME        (0),
        .WR_DATA_COUNT_WIDTH(5),
        .WRITE_DATA_WIDTH   (DATA_WIDTH)
    ) u_xpm_fifo_async (
        .rst            (Reset),
        .wr_clk         (WrClk),
        .wr_en          (WrEn),
        .din            (Data),
        .full           (Full),
        .wr_data_count  (),
        .wr_ack         (),
        .overflow       (),
        .rd_clk         (RdClk),
        .rd_en          (RdEn),
        .dout           (Q),
        .empty          (Empty),
        .rd_data_count  (),
        // .rd_ack         (),
        .underflow      (),
        .sleep          (1'b0),
        .injectsbiterr  (1'b0),
        .injectdbiterr  (1'b0),
        .sbiterr        (),
        .dbiterr        ()
    );

endmodule
