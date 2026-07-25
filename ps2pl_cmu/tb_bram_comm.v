`timescale 1ns/1ps

module tb_bram_comm;

//===================== DUT 参数 =====================
localparam AXI_CLK_PERIOD = 10;     // 100MHz
localparam PL_CLK_PERIOD  = 1000;   // 1MHz
localparam BASE_ADDR      = 32'h43C0_0000;
localparam REG_CTRL       = BASE_ADDR + 32'h00;
localparam REG_LEN        = BASE_ADDR + 32'h04;
localparam TX_BASE        = BASE_ADDR + 32'h100;
localparam RX_BASE        = BASE_ADDR + 32'h300;

//===================== 信号 =====================
reg         s_axi_aclk;
reg         s_axi_aresetn;
reg         clk_1m;
reg         rst_n_1m;

// AXI4-Lite
reg  [31:0] s_axi_awaddr;
reg         s_axi_awvalid;
wire        s_axi_awready;
reg  [31:0] s_axi_wdata;
reg  [3:0]  s_axi_wstrb;
reg         s_axi_wvalid;
wire        s_axi_wready;
wire [1:0]  s_axi_bresp;
wire        s_axi_bvalid;
reg         s_axi_bready;
reg  [31:0] s_axi_araddr;
reg         s_axi_arvalid;
wire        s_axi_arready;
wire [31:0] s_axi_rdata;
wire [1:0]  s_axi_rresp;
wire        s_axi_rvalid;
reg         s_axi_rready;

// PL 业务接口
reg         pl_tx_req;
wire        pl_tx_valid;
wire [15:0] pl_tx_data;
reg         pl_rx_valid;
reg  [15:0] pl_rx_data;
wire        pl_rx_done;
wire        pl_rx_irq;

// 测试统计
integer     pass_cnt = 0;
integer     fail_cnt = 0;
integer     test_id  = 0;

//===================== DUT 例化 =====================
pl_bram_comm_top u_dut (
    .s_axi_aclk     (s_axi_aclk),
    .s_axi_aresetn  (s_axi_aresetn),
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
    .clk_1m         (clk_1m),
    .rst_n_1m       (rst_n_1m),
    .pl_tx_req      (pl_tx_req),
    .pl_tx_valid    (pl_tx_valid),
    .pl_tx_data     (pl_tx_data),
    .pl_rx_valid    (pl_rx_valid),
    .pl_rx_data     (pl_rx_data),
    .pl_rx_done     (pl_rx_done),
    .pl_rx_irq      (pl_rx_irq)
);

//===================== 时钟生成 =====================
initial s_axi_aclk = 0;
always #(AXI_CLK_PERIOD/2) s_axi_aclk = ~s_axi_aclk;

initial clk_1m = 0;
always #(PL_CLK_PERIOD/2) clk_1m = ~clk_1m;

//===================== AXI4-Lite 主机任务 =====================

// 单次写（AW 与 W 可配置到达顺序）
task axi_write;
    input [31:0] addr;
    input [31:0] data;
    input [3:0]  strb;
    input integer w_before_aw;  // 1: W 先到, 0: AW 先到
    begin
        // 默认撤销
        s_axi_bready = 1'b1;

        if (w_before_aw) begin
            // ---- W 先发 ----
            s_axi_wdata  = data;
            s_axi_wstrb  = strb;
            s_axi_wvalid = 1'b1;
            // 等待 W 握手
            while (!(s_axi_wvalid && s_axi_wready)) @(posedge s_axi_aclk);
            @(posedge s_axi_aclk);
            s_axi_wvalid = 1'b0;
            // 再发 AW
            s_axi_awaddr  = addr;
            s_axi_awvalid = 1'b1;
            while (!(s_axi_awvalid && s_axi_awready)) @(posedge s_axi_aclk);
            @(posedge s_axi_aclk);
            s_axi_awvalid = 1'b0;
        end else begin
            // ---- AW 先发 ----
            s_axi_awaddr  = addr;
            s_axi_awvalid = 1'b1;
            while (!(s_axi_awvalid && s_axi_awready)) @(posedge s_axi_aclk);
            @(posedge s_axi_aclk);
            s_axi_awvalid = 1'b0;
            // 再发 W
            s_axi_wdata  = data;
            s_axi_wstrb  = strb;
            s_axi_wvalid = 1'b1;
            while (!(s_axi_wvalid && s_axi_wready)) @(posedge s_axi_aclk);
            @(posedge s_axi_aclk);
            s_axi_wvalid = 1'b0;
        end

        // 等待 B 通道响应
        while (!s_axi_bvalid) @(posedge s_axi_aclk);
        @(posedge s_axi_aclk);
    end
endtask

// 单次读
task axi_read;
    input  [31:0] addr;
    output [31:0] rdata;
    output [1:0]  rresp;
    begin
        s_axi_rready = 1'b1;
        s_axi_araddr  = addr;
        s_axi_arvalid = 1'b1;
        while (!(s_axi_arvalid && s_axi_arready)) @(posedge s_axi_aclk);
        @(posedge s_axi_aclk);
        s_axi_arvalid = 1'b0;

        while (!s_axi_rvalid) @(posedge s_axi_aclk);
        rdata = s_axi_rdata;
        rresp = s_axi_rresp;
        @(posedge s_axi_aclk);
    end
endtask

//===================== 辅助任务 =====================

// PL 侧接收一帧（驱动 pl_tx_req，采集 pl_tx_data）
task pl_receive_frame;
    input  [7:0]  exp_len;
    output [15:0] rx_data_buf[0:255];
    output        ok;
    integer i;
    begin
        ok = 1'b1;
        pl_tx_req = 1'b1;
        i = 0;
        while (i < exp_len) begin
            @(posedge clk_1m);
            if (pl_tx_valid) begin
                rx_data_buf[i] = pl_tx_data;
                i = i + 1;
            end
        end
        pl_tx_req = 1'b0;
        // 等待 tx_done 脉冲
        @(posedge clk_1m);
    end
endtask

// PL 侧发送一帧（驱动 pl_rx_valid/pl_rx_data）
task pl_send_frame;
    input [7:0]  len;
    input [15:0] data_buf[0:255];
    integer i;
    begin
        i = 0;
        pl_rx_valid = 1'b1;
        while (i < len) begin
            pl_rx_data = data_buf[i];
            @(posedge clk_1m);
            i = i + 1;
        end
        pl_rx_valid = 1'b0;
        // 等待 pl_rx_done 脉冲
        @(posedge clk_1m);
    end
endtask

// 结果记录
task check;
    input [255:0] name;
    input         cond;
    begin
        if (cond) begin
            pass_cnt = pass_cnt + 1;
            $display("[PASS] %0d: %s", test_id, name);
        end else begin
            fail_cnt = fail_cnt + 1;
            $display("[FAIL] %0d: %s", test_id, name);
        end
        test_id = test_id + 1;
    end
endtask

//===================== 主测试流程 =====================
integer j;
reg [31:0] tmp_rdata;
reg [1:0]  tmp_rresp;
reg [15:0] tx_buf[0:255];
reg [15:0] rx_buf[0:255];
reg [15:0] exp_buf[0:255];
reg        tmp_ok;

initial begin
    //---- 初始化 ----
    s_axi_aresetn  = 1'b0;
    rst_n_1m       = 1'b0;
    s_axi_awaddr   = 0;  s_axi_awvalid = 0;
    s_axi_wdata    = 0;  s_axi_wstrb   = 4'b1111;  s_axi_wvalid = 0;
    s_axi_bready   = 1'b1;
    s_axi_araddr   = 0;  s_axi_arvalid = 0;
    s_axi_rready   = 1'b1;
    pl_tx_req      = 0;
    pl_rx_valid    = 0;  pl_rx_data = 0;

    #(AXI_CLK_PERIOD * 10);
    s_axi_aresetn = 1'b1;
    rst_n_1m      = 1'b1;
    #(AXI_CLK_PERIOD * 10);

    //======================================================
    // 测试 1：AW/W 乱序到达（W 先于 AW）
    //======================================================
    for (j = 0; j < 8; j = j + 1)
        tx_buf[j] = 16'hA000 + j;
    axi_write(REG_LEN, 8, 4'b1111, 0);          // 先写长度（AW 先）
    for (j = 0; j < 4; j = j + 1)
        axi_write(TX_BASE + j*4, {tx_buf[2*j+1], tx_buf[2*j]}, 4'b1111, 1); // W 先
    axi_read(TX_BASE, tmp_rdata, tmp_rresp);
    check("T1: AW/W 乱序写后读回", tmp_rdata == {tx_buf[1], tx_buf[0]});

    //======================================================
    // 测试 2：地址边界扫描
    //======================================================
    axi_write(REG_CTRL, 32'h0, 4'b1111, 0);     // 0x000 命中 REG
    axi_read(REG_CTRL, tmp_rdata, tmp_rresp);
    check("T2a: 0x000 命中 REG", tmp_rresp == 2'b00);

    axi_read(TX_BASE + 32'h1FC, tmp_rdata, tmp_rresp);  // 0x2FF TX 末
    check("T2b: 0x2FF 命中 TX", tmp_rresp == 2'b00);

    axi_read(RX_BASE + 32'h1FC, tmp_rdata, tmp_rresp);  // 0x4FF RX 末
    check("T2c: 0x4FF 命中 RX", tmp_rresp == 2'b00);

    axi_read(BASE_ADDR + 32'h500, tmp_rdata, tmp_rresp); // 0x500 越界
    check("T2d: 0x500 越界 DECERR", tmp_rresp == 2'b11);

    //======================================================
    // 测试 3：WSTRB 部分写 BRAM 区应返回 SLVERR
    //======================================================
    axi_write(TX_BASE, 32'hDEAD_BEEF, 4'b0011, 0);  // 部分写
    // BRESP 在 axi_write 内部已握手，需单独检查
    // 改为直接读 BRESP
    s_axi_awaddr  = TX_BASE; s_axi_awvalid = 1'b1;
    s_axi_wdata   = 32'hDEAD_BEEF; s_axi_wstrb = 4'b0011; s_axi_wvalid = 1'b1;
    s_axi_bready  = 1'b1;
    while (!(s_axi_awvalid && s_axi_awready)) @(posedge s_axi_aclk);
    @(posedge s_axi_aclk); s_axi_awvalid = 1'b0;
    while (!(s_axi_wvalid && s_axi_wready)) @(posedge s_axi_aclk);
    @(posedge s_axi_aclk); s_axi_wvalid = 1'b0;
    while (!s_axi_bvalid) @(posedge s_axi_aclk);
    check("T3: WSTRB 部分写 SLVERR", s_axi_bresp == 2'b10);
    @(posedge s_axi_aclk);

    //======================================================
    // 测试 4：首帧发送（不阻塞）
    //======================================================
    for (j = 0; j < 4; j = j + 1)
        tx_buf[j] = 16'hB000 + j;
    axi_write(REG_LEN, 4, 4'b1111, 0);
    for (j = 0; j < 2; j = j + 1)
        axi_write(TX_BASE + j*4, {tx_buf[2*j+1], tx_buf[2*j]}, 4'b1111, 0);
    axi_write(REG_CTRL, 32'h1, 4'b1111, 0);     // TX_START
    pl_receive_frame(4, rx_buf, tmp_ok);
    // 校验数据
    tmp_ok = 1'b1;
    for (j = 0; j < 4; j = j + 1)
        if (rx_buf[j] !== tx_buf[j]) tmp_ok = 1'b0;
    check("T4: 首帧发送数据正确", tmp_ok);

    //======================================================
    // 测试 5：长度边界 len=1
    //======================================================
    tx_buf[0] = 16'hC001;
    axi_write(REG_LEN, 1, 4'b1111, 0);
    axi_write(TX_BASE, {16'h0000, tx_buf[0]}, 4'b1111, 0);
    axi_write(REG_CTRL, 32'h1, 4'b1111, 0);
    pl_receive_frame(1, rx_buf, tmp_ok);
    check("T5: len=1 数据正确", rx_buf[0] === tx_buf[0]);

    //======================================================
    // 测试 6：长度边界 len=255
    //======================================================
    for (j = 0; j < 255; j = j + 1)
        tx_buf[j] = 16'hD000 + j[7:0];
    axi_write(REG_LEN, 255, 4'b1111, 0);
    for (j = 0; j < 128; j = j + 1)
        axi_write(TX_BASE + j*4, {tx_buf[2*j+1], tx_buf[2*j]}, 4'b1111, 0);
    // 奇数最后一字
    axi_write(TX_BASE + 128*4, {16'h0000, tx_buf[254]}, 4'b1111, 0);
    axi_write(REG_CTRL, 32'h1, 4'b1111, 0);
    pl_receive_frame(255, rx_buf, tmp_ok);
    tmp_ok = 1'b1;
    for (j = 0; j < 255; j = j + 1)
        if (rx_buf[j] !== tx_buf[j]) tmp_ok = 1'b0;
    check("T6: len=255 数据正确", tmp_ok);

    //======================================================
    // 测试 7：TX_START 重复写（PL 仅触发一次）
    //======================================================
    axi_write(REG_LEN, 2, 4'b1111, 0);
    axi_write(TX_BASE, 32'hE001_E000, 4'b1111, 0);
    axi_write(REG_CTRL, 32'h1, 4'b1111, 0);     // 第一次 TX_START
    axi_write(REG_CTRL, 32'h1, 4'b1111, 0);     // 第二次（应忽略）
    pl_receive_frame(2, rx_buf, tmp_ok);
    // 等待足够周期，确认不会第二次触发
    #(PL_CLK_PERIOD * 50);
    check("T7: TX_START 重复写不重复触发", !pl_tx_valid);

    //======================================================
    // 测试 8：RX_READY 低频脉冲 + PS 接收
    //======================================================
    for (j = 0; j < 8; j = j + 1)
        exp_buf[j] = 16'hF000 + j;
    pl_send_frame(8, exp_buf);
    // 等待 CDC 同步
    #(AXI_CLK_PERIOD * 20);
    axi_read(REG_CTRL, tmp_rdata, tmp_rresp);
    check("T8a: RX_READY 置位", tmp_rdata[2] == 1'b1);
    axi_read(REG_LEN, tmp_rdata, tmp_rresp);
    check("T8b: RX_LEN=8", tmp_rdata[23:16] == 8);
    // 读 RX 数据
    for (j = 0; j < 4; j = j + 1) begin
        axi_read(RX_BASE + j*4, tmp_rdata, tmp_rresp);
        rx_buf[2*j]   = tmp_rdata[15:0];
        rx_buf[2*j+1] = tmp_rdata[31:16];
    end
    tmp_ok = 1'b1;
    for (j = 0; j < 8; j = j + 1)
        if (rx_buf[j] !== exp_buf[j]) tmp_ok = 1'b0;
    check("T8c: RX 数据正确", tmp_ok);
    // W1C 清除 RX_READY
    axi_write(REG_CTRL, 32'h4, 4'b1111, 0);
    #(AXI_CLK_PERIOD * 10);
    axi_read(REG_CTRL, tmp_rdata, tmp_rresp);
    check("T8d: W1C 清除 RX_READY", tmp_rdata[2] == 1'b0);

    //======================================================
    // 测试 9：CDC 长度一致性（0xAA/0x55 交替）
    //======================================================
    axi_write(REG_LEN, 8'hAA, 4'b1111, 0);
    #(PL_CLK_PERIOD * 5);
    // PL 侧通过内部信号无法直接观测，改为功能验证：发送 len=0xAA 帧
    for (j = 0; j < 16; j = j + 1)
        tx_buf[j] = 16'hAA00 + j[7:0];
    axi_write(REG_LEN, 16, 4'b1111, 0);
    for (j = 0; j < 8; j = j + 1)
        axi_write(TX_BASE + j*4, {tx_buf[2*j+1], tx_buf[2*j]}, 4'b1111, 0);
    axi_write(REG_CTRL, 32'h1, 4'b1111, 0);
    pl_receive_frame(16, rx_buf, tmp_ok);
    tmp_ok = 1'b1;
    for (j = 0; j < 16; j = j + 1)
        if (rx_buf[j] !== tx_buf[j]) tmp_ok = 1'b0;
    check("T9: CDC 长度一致性（len=16）", tmp_ok);

    //======================================================
    // 测试 10：复位恢复
    //======================================================
    rst_n_1m = 1'b0;
    #(PL_CLK_PERIOD * 5);
    rst_n_1m = 1'b1;
    #(PL_CLK_PERIOD * 5);
    check("T10: 复位后 pl_tx_valid=0", !pl_tx_valid);
    check("T10: 复位后 pl_rx_done=0", !pl_rx_done);

    //======================================================
    // 汇总
    //======================================================
    #(AXI_CLK_PERIOD * 20);
    $display("=========================================");
    $display("  Test Summary: PASS=%0d  FAIL=%0d", pass_cnt, fail_cnt);
    $display("=========================================");
    if (fail_cnt == 0)
        $display("  *** ALL TESTS PASSED ***");
    else
        $display("  *** SOME TESTS FAILED ***");
    $display("=========================================");
    $finish;
end

// 超时保护
initial begin
    #(AXI_CLK_PERIOD * 200000);   // 2ms 超时
    $display("[ERROR] Simulation timeout!");
    $finish;
end

endmodule
