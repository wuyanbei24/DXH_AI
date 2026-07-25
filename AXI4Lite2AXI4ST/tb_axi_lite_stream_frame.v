`timescale 1ns / 1ps

//============================================================================
// tb_axi_lite_stream_frame.v
// 修正版 V2 testbench（2026-07-25）
// 覆盖：基础读写、AW/W 分离握手、读写并发、字节选通、连续事务
//============================================================================
module tb_axi_lite_stream_frame;

    parameter C_S_AXI_DATA_WIDTH = 32;
    parameter C_S_AXI_ADDR_WIDTH = 32;
    parameter C_AXIS_DATA_WIDTH  = 32;
    parameter C_REG_NUM          = 4;
    parameter C_FIFO_DEPTH       = 4;

    reg                                 aclk;
    reg                                 aresetn;

    // AXI4-Lite 接口信号
    reg  [C_S_AXI_ADDR_WIDTH-1:0]      s_axi_awaddr;
    reg  [2:0]                         s_axi_awprot;
    reg                                s_axi_awvalid;
    wire                               s_axi_awready;
    reg  [C_S_AXI_DATA_WIDTH-1:0]      s_axi_wdata;
    reg  [C_S_AXI_DATA_WIDTH/8-1:0]    s_axi_wstrb;
    reg                                s_axi_wvalid;
    wire                               s_axi_wready;
    wire [1:0]                         s_axi_bresp;
    wire                               s_axi_bvalid;
    reg                                s_axi_bready;
    reg  [C_S_AXI_ADDR_WIDTH-1:0]      s_axi_araddr;
    reg  [2:0]                         s_axi_arprot;
    reg                                s_axi_arvalid;
    wire                               s_axi_arready;
    wire [C_S_AXI_DATA_WIDTH-1:0]      s_axi_rdata;
    wire [1:0]                         s_axi_rresp;
    wire                               s_axi_rvalid;
    reg                                s_axi_rready;

    // 实例化顶层
    axi_lite_stream_bridge #(
        .C_S_AXI_DATA_WIDTH (C_S_AXI_DATA_WIDTH),
        .C_S_AXI_ADDR_WIDTH (C_S_AXI_ADDR_WIDTH),
        .C_AXIS_DATA_WIDTH  (C_AXIS_DATA_WIDTH),
        .C_REG_NUM          (C_REG_NUM),
        .C_FIFO_DEPTH       (C_FIFO_DEPTH)
    ) DUT (
        .aclk           (aclk),
        .aresetn        (aresetn),
        .s_axi_awaddr   (s_axi_awaddr),
        .s_axi_awprot   (s_axi_awprot),
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
        .s_axi_arprot   (s_axi_arprot),
        .s_axi_arvalid  (s_axi_arvalid),
        .s_axi_arready  (s_axi_arready),
        .s_axi_rdata    (s_axi_rdata),
        .s_axi_rresp    (s_axi_rresp),
        .s_axi_rvalid   (s_axi_rvalid),
        .s_axi_rready   (s_axi_rready)
    );

    // 100MHz 时钟
    initial begin
        aclk = 0;
        forever #5 aclk = ~aclk;
    end

    // AXI4-Lite 写任务（修正 D-04：AW/W 独立握手）
    task axi_lite_write;
        input [31:0] addr;
        input [31:0] data;
        input [3:0]  strb;
        begin
            @(posedge aclk);
            // AW 通道
            s_axi_awaddr  = addr;
            s_axi_awprot  = 3'b000;
            s_axi_awvalid = 1'b1;
            // W 通道（可与 AW 同拍或不同拍）
            s_axi_wdata   = data;
            s_axi_wstrb   = strb;
            s_axi_wvalid  = 1'b1;
            s_axi_bready  = 1'b1;

            // 等待 AW 握手
            wait(s_axi_awready);
            @(posedge aclk);
            s_axi_awvalid = 1'b0;

            // 等待 W 握手（独立于 AW）
            wait(s_axi_wready);
            @(posedge aclk);
            s_axi_wvalid = 1'b0;

            // 等待 B 响应
            wait(s_axi_bvalid);
            @(posedge aclk);
            s_axi_bready = 1'b0;
            $display("[%0t] WRITE: Addr=0x%08x Data=0x%08x Strb=4'b%b Resp=2'b%b",
                     $time, addr, data, strb, s_axi_bresp);
        end
    endtask

    // AXI4-Lite 写任务（AW/W 分离发送，验证 D-04 修正）
    task axi_lite_write_split;
        input [31:0] addr;
        input [31:0] data;
        input [3:0]  strb;
        begin
            @(posedge aclk);
            // 先发 AW，延迟 3 拍再发 W
            s_axi_awaddr  = addr;
            s_axi_awprot  = 3'b000;
            s_axi_awvalid = 1'b1;
            s_axi_bready  = 1'b1;

            wait(s_axi_awready);
            @(posedge aclk);
            s_axi_awvalid = 1'b0;

            // 延迟 3 拍后发 W
            repeat(3) @(posedge aclk);
            s_axi_wdata   = data;
            s_axi_wstrb   = strb;
            s_axi_wvalid  = 1'b1;

            wait(s_axi_wready);
            @(posedge aclk);
            s_axi_wvalid = 1'b0;

            wait(s_axi_bvalid);
            @(posedge aclk);
            s_axi_bready = 1'b0;
            $display("[%0t] WRITE_SPLIT: Addr=0x%08x Data=0x%08x Strb=4'b%b Resp=2'b%b",
                     $time, addr, data, strb, s_axi_bresp);
        end
    endtask

    // AXI4-Lite 读任务
    task axi_lite_read;
        input [31:0] addr;
        output [31:0] data;
        begin
            @(posedge aclk);
            s_axi_araddr  = addr;
            s_axi_arprot  = 3'b000;
            s_axi_arvalid = 1'b1;
            s_axi_rready  = 1'b1;

            wait(s_axi_arready);
            @(posedge aclk);
            s_axi_arvalid = 1'b0;

            wait(s_axi_rvalid);
            @(posedge aclk);
            data = s_axi_rdata;
            s_axi_rready = 1'b0;
            $display("[%0t] READ:  Addr=0x%08x Data=0x%08x Resp=2'b%b",
                     $time, addr, s_axi_rdata, s_axi_rresp);
        end
    endtask

    // 主测试序列
    integer errors;
    reg [31:0] rd;

    initial begin
        errors = 0;
        // 初始化
        aresetn = 0;
        s_axi_awaddr  = 0;
        s_axi_awprot  = 0;
        s_axi_awvalid = 0;
        s_axi_wdata   = 0;
        s_axi_wstrb   = 0;
        s_axi_wvalid  = 0;
        s_axi_bready  = 0;
        s_axi_araddr  = 0;
        s_axi_arprot  = 0;
        s_axi_arvalid = 0;
        s_axi_rready  = 0;

        #20;
        aresetn = 1;
        #20;

        $display("===== 测试1：基础单写单读 =====");
        axi_lite_write(32'h0000_0000, 32'h1234_5678, 4'b1111);
        #10;
        axi_lite_read(32'h0000_0000, rd);
        if (rd !== 32'h12345678) begin
            $error("寄存器0读回错误: 预期 0x12345678, 实际 0x%08x", rd);
            errors = errors + 1;
        end

        #30;
        $display("\n===== 测试2：AW/W 分离握手（验证 D-04 修正）=====");
        axi_lite_write_split(32'h0000_0004, 32'hCAFE_BABE, 4'b1111);
        #10;
        axi_lite_read(32'h0000_0004, rd);
        if (rd !== 32'hCAFEBABE) begin
            $error("分离握手写读回错误: 预期 0xCAFEBABE, 实际 0x%08x", rd);
            errors = errors + 1;
        end

        #30;
        $display("\n===== 测试3：读写并发验证 =====");
        // 预写数据
        axi_lite_write(32'h0000_0008, 32'hDEAD_BEEF, 4'b1111);
        #10;

        // 同时发起写和读
        fork
            begin
                axi_lite_write(32'h0000_000C, 32'hAAAA_5555, 4'b1111);
            end
            begin
                axi_lite_read(32'h0000_0008, rd);
                if (rd !== 32'hDEADBEEF) begin
                    $error("并发读错误: 预期 0xDEADBEEF, 实际 0x%08x", rd);
                    errors = errors + 1;
                end
            end
        join

        #30;
        $display("\n===== 测试4：字节选通写验证 =====");
        axi_lite_write(32'h0000_000C, 32'hFFFF_FFFF, 4'b1111);
        #10;
        axi_lite_write(32'h0000_000C, 32'h0000_1122, 4'b0011);
        #10;
        axi_lite_read(32'h0000_000C, rd);
        if (rd !== 32'hFFFF_1122) begin
            $error("字节选通错误: 预期 0xFFFF1122, 实际 0x%08x", rd);
            errors = errors + 1;
        end

        #30;
        $display("\n===== 测试5：连续多笔事务 =====");
        begin
            integer k;
            for (k = 0; k < C_REG_NUM; k = k + 1) begin
                axi_lite_write(k * 4, 32'hA000_0000 + k, 4'b1111);
            end
            for (k = 0; k < C_REG_NUM; k = k + 1) begin
                axi_lite_read(k * 4, rd);
                if (rd !== (32'hA000_0000 + k)) begin
                    $error("连续事务读错误[%0d]: 预期 0x%08x, 实际 0x%08x", k, 32'hA000_0000 + k, rd);
                    errors = errors + 1;
                end
            end
        end

        #50;
        if (errors == 0)
            $display("\n===== 全部测试通过 =====");
        else
            $display("\n===== 测试失败，共 %0d 个错误 =====", errors);
        $finish;
    end

    // 超时保护
    initial begin
        #50000;
        $error("仿真超时！");
        $finish;
    end

endmodule
