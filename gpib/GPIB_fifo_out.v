`timescale 1ns / 1ps

//=============================================================================
// GPIB_fifo_out : 发送 FIFO（M1 / APB -> GPIB）
//-----------------------------------------------------------------------------
//   写侧时钟 : APB_PCLK   （软件写入待发送数据，APB_PCLK 域）
//   读侧时钟 : sys_clk    （GPIB 发送状态机 SH 取数，sys_clk 域）
//   实现     : Xilinx XPM 异步 FIFO (xpm_fifo_async)，FWFT 模式
//   作用     : 该模块同时隔离 APB_PCLK 与 sys_clk 两个时钟域，
//              消除原为单时钟 FIFO 直接跨域带来的 CDC 风险（原 P0 问题）。
//=============================================================================
module GPIB_fifo_out #
(
    parameter   DATA_WIDTH  = 8,
    parameter   FIFO_DEPTH  = 16
)(
    input   wire                        WrClk   ,   // APB_PCLK
    input   wire                        RdClk   ,   // sys_clk
    input   wire    [DATA_WIDTH-1:0]    Data    ,   // GPIB_Data_M1_w (APB_PCLK 域)
    input   wire                        WrEn    ,   // GPIB_outfifo_w (APB_PCLK 域)
    input   wire                        RdEn    ,   // GPIB_outfifo_r (sys_clk 域)
    input   wire                        Reset   ,   // ~GPIB_dvire_rstn (高有效)
    output  wire    [10:0]              Wnum    ,   // 写侧数据计数 (APB_PCLK 域)
    output  wire    [DATA_WIDTH-1:0]    Q       ,   // GPIB_Data_FPGA_w (sys_clk 域)
    output  wire                        Empty   ,   // GPIB_outfifo_empty (sys_clk 域)
    output  wire                        Full        // GPIB_outfifo_full  (APB_PCLK 域)
);

    xpm_fifo_async #(
        // .CASCADE_HEIGHT      (0),
        .CDC_SYNC_STAGES    (2),                // 跨时钟域同步级数
        .DOUT_RESET_VALUE   ("0"),
        .ECC_MODE           ("no_ecc"),
        .FIFO_MEMORY_TYPE   ("auto"),
        .FIFO_READ_LATENCY  (0),                // FWFT 模式必须为 0
        .FIFO_WRITE_DEPTH   (FIFO_DEPTH),       // 必须为 2 的幂 (>=16)
        .FULL_RESET_VALUE   (1),
        .PROG_EMPTY_THRESH  (10),
        .PROG_FULL_THRESH   (10),
        .RD_DATA_COUNT_WIDTH(5),
        .READ_DATA_WIDTH    (DATA_WIDTH),
        .READ_MODE          ("fwft"),           // 首字直通，SH 状态机每次脉冲读一字
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
        .wr_data_count  (Wnum),
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
