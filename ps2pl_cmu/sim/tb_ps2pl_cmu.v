`timescale 1ns/1ps
//==============================================================================
// tb_ps2pl_cmu.v — ps2pl_cmu 设计仿真测试平台（增强版，纯 Verilog-2001 兼容）
//
// 说明：原 tb_bram_comm.v 将 memory 数组作为 task 的 output/input 端口传递，
//       这在 Verilog-2001 中非法（仅 SystemVerilog 允许），导致 ModelSim 编译
//       失败。本版本改为使用模块级数组（rx_cap_buf / tx_send_buf）作为帧缓存，
//       任务内部直接读写模块级数组，避免 memory 端口，纯 Verilog 即可编译。
//
// 内容：
//   - 明确的 "TEST PASSED" / "TEST FAILED" 标记，便于自动化脚本判定；
//   - 新增 T11：连续两次独立 TX_START（帧间等待完成），验证 P-06 异或边沿
//     检测修复后每次 toggle 都能触发一次发送；
//   - 保留原 10 项测试（乱序写、地址边界、WSTRB、首帧、len=1/255、重复start、
//     RX 接收、CDC 长度一致性、复位恢复）。
//
// DUT: pl_bram_comm_top（顶层，内部例化 tx_bram_ip/rx_bram_ip 行为级模型）
//==============================================================================

module tb_ps2pl_cmu;

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
reg  [15:0] pl_rx_data;   // [P-20] 见下方 pl_send_frame：负半周更新，posedge 采样稳定
wire        pl_rx_done;
wire        pl_rx_irq;

// 测试统计
integer     pass_cnt = 0;
integer     fail_cnt = 0;
integer     test_id  = 0;

// 模块级帧缓存（避免 memory 作为 task 端口）
reg [15:0] tx_buf    [0:255];   // PS 期望下发数据
reg [15:0] rx_cap_buf[0:255];   // PL 侧接收捕获
reg [15:0] exp_buf   [0:255];   // PL 侧待上传数据

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

reg [1:0] last_bresp;
task axi_write;
    input [31:0] addr;
    input [31:0] data;
    input [3:0]  strb;
    input integer w_before_aw;  // 1: W 先到, 0: AW 先到
    begin
        s_axi_bready = 1'b1;
        if (w_before_aw) begin
            s_axi_wdata  = data;
            s_axi_wstrb  = strb;
            s_axi_wvalid = 1'b1;
            while (!(s_axi_wvalid && s_axi_wready)) @(posedge s_axi_aclk);
            @(posedge s_axi_aclk);
            s_axi_wvalid = 1'b0;
            s_axi_awaddr  = addr;
            s_axi_awvalid = 1'b1;
            while (!(s_axi_awvalid && s_axi_awready)) @(posedge s_axi_aclk);
            @(posedge s_axi_aclk);
            s_axi_awvalid = 1'b0;
        end else begin
            s_axi_awaddr  = addr;
            s_axi_awvalid = 1'b1;
            while (!(s_axi_awvalid && s_axi_awready)) @(posedge s_axi_aclk);
            @(posedge s_axi_aclk);
            s_axi_awvalid = 1'b0;
            s_axi_wdata  = data;
            s_axi_wstrb  = strb;
            s_axi_wvalid = 1'b1;
            while (!(s_axi_wvalid && s_axi_wready)) @(posedge s_axi_aclk);
            @(posedge s_axi_aclk);
            s_axi_wvalid = 1'b0;
        end
        while (!s_axi_bvalid) @(posedge s_axi_aclk);
        last_bresp = s_axi_bresp;
        @(posedge s_axi_aclk);
    end
endtask

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

//===================== 辅助任务（使用模块级数组，避免 memory 端口） =====================

// PL 侧接收一帧：驱动 pl_tx_req，把 pl_tx_data 捕获进 rx_cap_buf[0:exp_len-1]
// 收满后等待 tx_data_path 回到 IDLE，确保下一帧 TX_START 不被忙状态吞掉（设计仅在
// IDLE 采样 tx_start_pulse）。curr_state 经 vopt +acc=rb 可读。
task pl_receive_frame;
    input  [7:0] exp_len;
    output       ok;
    integer i, wdog;
    begin
        ok = 1'b1;
        pl_tx_req = 1'b1;
        i = 0;
        wdog = 0;
        while (i < exp_len) begin
            @(posedge clk_1m);
            if (pl_tx_valid) begin
                rx_cap_buf[i] = pl_tx_data;
                i = i + 1;
            end
            wdog = wdog + 1;
            if (wdog > (exp_len * 8 + 200)) begin
                $display("[DBG] pl_receive_frame(exp=%0d) WATCHDOG: captured only %0d beats", exp_len, i);
                ok = 1'b0;
                disable pl_receive_frame;
            end
        end
        pl_tx_req = 1'b0;
        // 等待 TX 数据通路彻底回到 IDLE（curr_state==2'b00），避免后续帧 start 丢失
        while (u_dut.u_tx_data_path.curr_state != 2'b00) @(posedge clk_1m);
    end
endtask

// PL 侧发送一帧：在每个 PL 周期内，先把 pl_rx_data 在“负半周”准备好，再用
// posedge 采样（与设计 RX 数据通路对齐）。关键点：pl_rx_data 用阻塞赋值后在
// 负半周（#(PL_CLK_PERIOD/2)）稳定，避免 ModelSim 在同一 posedge 时间步内把
// 数据提前一拍导致“首拍丢失 / 整体错位”的竞争（见报告 P-20）。
task pl_send_frame;
    input [7:0] len;
    integer i;
    begin
        pl_rx_valid = 1'b1;
        for (i = 0; i < len; i = i + 1) begin
            pl_rx_data = exp_buf[i];          // 本拍数据
            #(PL_CLK_PERIOD/2);               // 等到负半周，数据稳定
            @(posedge clk_1m);                // 设计在该 posedge 采样 exp_buf[i]
        end
        pl_rx_valid = 1'b0;
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
integer i;          // 模块级循环变量（Verilog-2001 不允许在匿名 begin 内声明）
reg [31:0] tmp_rdata;
reg [1:0]  tmp_rresp;
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
    check("T3: WSTRB 部分写 SLVERR", last_bresp == 2'b10);

    //======================================================
    // 测试 4：首帧发送（不阻塞）
    //======================================================
    for (j = 0; j < 4; j = j + 1)
        tx_buf[j] = 16'hB000 + j;
    axi_write(REG_LEN, 4, 4'b1111, 0);
    for (j = 0; j < 2; j = j + 1)
        axi_write(TX_BASE + j*4, {tx_buf[2*j+1], tx_buf[2*j]}, 4'b1111, 0);
    axi_write(REG_CTRL, 32'h1, 4'b1111, 0);     // TX_START
    pl_receive_frame(4, tmp_ok);
    tmp_ok = 1'b1;
    for (j = 0; j < 4; j = j + 1)
        if (rx_cap_buf[j] !== tx_buf[j]) tmp_ok = 1'b0;
    check("T4: 首帧发送数据正确", tmp_ok);

    //======================================================
    // 测试 5：长度边界 len=1
    //======================================================
    tx_buf[0] = 16'hC001;
    axi_write(REG_LEN, 1, 4'b1111, 0);
    axi_write(TX_BASE, {16'h0000, tx_buf[0]}, 4'b1111, 0);
    axi_write(REG_CTRL, 32'h1, 4'b1111, 0);
    pl_receive_frame(1, tmp_ok);
    check("T5: len=1 数据正确", rx_cap_buf[0] === tx_buf[0]);

    //======================================================
    // 测试 6：长度边界 len=255
    //======================================================
    for (j = 0; j < 255; j = j + 1)
        tx_buf[j] = 16'hD000 + j[7:0];
    axi_write(REG_LEN, 255, 4'b1111, 0);
    for (j = 0; j < 128; j = j + 1)
        axi_write(TX_BASE + j*4, {tx_buf[2*j+1], tx_buf[2*j]}, 4'b1111, 0);
    // 注：j<128 已写满 128 个 32bit 字（覆盖 tx_buf[0..255] 共 256 个 16bit 值），
    // 第 255 个值(tx_buf[254])已在字 127 低 16bit，无需额外“奇数”写；
    // 原 tb 的 TX_BASE+128*4=0x300 实际落入 RX 区域，属测试缺陷，已移除。
    axi_write(REG_CTRL, 32'h1, 4'b1111, 0);
    pl_receive_frame(255, tmp_ok);
    tmp_ok = 1'b1;
    for (j = 0; j < 255; j = j + 1)
        if (rx_cap_buf[j] !== tx_buf[j]) tmp_ok = 1'b0;
    check("T6: len=255 数据正确", tmp_ok);

    //======================================================
    // 测试 7：TX_START 重复写（帧进行中第二次 start 应被忽略）
    //   注意：toggle-CDC 要求两次写间隔 > 1 个 PL 周期(1us)，否则会被合并为
    //   无效（见报告 P16）。这里在帧进行中发出第二次写，验证被忽略（不触发
    //   第二帧），且 PL 需先置 pl_tx_req（设计仅在 IDLE 采样 tx_start_pulse）。
    //======================================================
    pl_tx_req = 1'b1;                              // PL 先置 ready
    axi_write(REG_LEN, 2, 4'b1111, 0);
    axi_write(TX_BASE, 32'hE001_E000, 4'b1111, 0);
    axi_write(REG_CTRL, 32'h1, 4'b1111, 0);      // 第一次 TX_START -> 启动帧
    #(PL_CLK_PERIOD * 5);                         // 帧进行中（len=2 约 6 拍）
    axi_write(REG_CTRL, 32'h1, 4'b1111, 0);      // 第二次（帧忙，应忽略）
    begin                                         // 仅捕获第一帧的 2 拍
        i = 0;
        while (i < 2) begin
            @(posedge clk_1m);
            if (pl_tx_valid) begin rx_cap_buf[i] = pl_tx_data; i = i + 1; end
        end
    end
    pl_tx_req = 1'b0;
    while (u_dut.u_tx_data_path.curr_state != 2'b00) @(posedge clk_1m); // 等帧结束
    #(PL_CLK_PERIOD * 20);
    check("T7: TX_START 帧忙时重复写不触发第二帧", !pl_tx_valid);

    //======================================================
    // 测试 8：RX_READY 低频脉冲 + PS 接收
    //======================================================
    for (j = 0; j < 8; j = j + 1)
        exp_buf[j] = 16'hF000 + j;
    pl_send_frame(8);
    // RX 帧(8拍≈8us) + CDC(≈3us) 需 >10us；AXI_CLK 等价的短时间不够，改用 PL 时钟
    #(PL_CLK_PERIOD * 40);
    axi_read(REG_CTRL, tmp_rdata, tmp_rresp);
    check("T8a: RX_READY 置位", tmp_rdata[2] == 1'b1);
    axi_read(REG_LEN, tmp_rdata, tmp_rresp);
    check("T8b: RX_LEN=8", tmp_rdata[23:16] == 8);
    for (j = 0; j < 4; j = j + 1) begin
        axi_read(RX_BASE + j*4, tmp_rdata, tmp_rresp);
        rx_cap_buf[2*j]   = tmp_rdata[15:0];
        rx_cap_buf[2*j+1] = tmp_rdata[31:16];
    end
    tmp_ok = 1'b1;
    for (j = 0; j < 8; j = j + 1)
        if (rx_cap_buf[j] !== exp_buf[j]) tmp_ok = 1'b0;
    check("T8c: RX 数据正确", tmp_ok);
    axi_write(REG_CTRL, 32'h4, 4'b1111, 0);     // W1C 清除 RX_READY
    #(AXI_CLK_PERIOD * 10);
    axi_read(REG_CTRL, tmp_rdata, tmp_rresp);
    check("T8d: W1C 清除 RX_READY", tmp_rdata[2] == 1'b0);

    //======================================================
    // 测试 9：CDC 长度一致性（len=16）
    //======================================================
    for (j = 0; j < 16; j = j + 1)
        tx_buf[j] = 16'hAA00 + j[7:0];
    axi_write(REG_LEN, 16, 4'b1111, 0);
    for (j = 0; j < 8; j = j + 1)
        axi_write(TX_BASE + j*4, {tx_buf[2*j+1], tx_buf[2*j]}, 4'b1111, 0);
    axi_write(REG_CTRL, 32'h1, 4'b1111, 0);
    pl_receive_frame(16, tmp_ok);
    tmp_ok = 1'b1;
    for (j = 0; j < 16; j = j + 1)
        if (rx_cap_buf[j] !== tx_buf[j]) tmp_ok = 1'b0;
    check("T9: CDC 长度一致性（len=16）", tmp_ok);

    //======================================================
    // 测试 10：复位恢复
    //======================================================
    rst_n_1m = 1'b0;
    #(PL_CLK_PERIOD * 5);
    rst_n_1m = 1'b1;
    #(PL_CLK_PERIOD * 5);
    check("T10a: 复位后 pl_tx_valid=0", !pl_tx_valid);
    check("T10b: 复位后 pl_rx_done=0", !pl_rx_done);

    //======================================================
    // 测试 11：连续两次独立 TX_START（验证 P-06 异或边沿修复）
    //   每次写 CTRL=1 都会 toggle tx_start_toggle_q；修复后每次 toggle
    //   的边沿（上升或下降）都应触发一次发送。两次独立发送都应成功。
    //======================================================
    // 第 1 帧
    for (j = 0; j < 2; j = j + 1)
        tx_buf[j] = 16'h1100 + j;
    axi_write(REG_LEN, 2, 4'b1111, 0);
    axi_write(TX_BASE, {tx_buf[1], tx_buf[0]}, 4'b1111, 0);
    #(PL_CLK_PERIOD * 5);    // P-18: 等待 TX_LEN 在 PL 域锁存稳定后再发起 TX_START（避免 tx_start_pulse 先于 tx_len 到达导致帧被丢弃）
    axi_write(REG_CTRL, 32'h1, 4'b1111, 0);
    pl_receive_frame(2, tmp_ok);
    tmp_ok = 1'b1;
    for (j = 0; j < 2; j = j + 1)
        if (rx_cap_buf[j] !== tx_buf[j]) tmp_ok = 1'b0;
    check("T11a: 第1次 TX_START 发送成功", tmp_ok);

    // 等待 tx_done 同步回 PS（确认第1帧已消费）
    #(AXI_CLK_PERIOD * 30);

    // 第 2 帧（toggle 反向，验证下降沿也能触发）
    for (j = 0; j < 2; j = j + 1)
        tx_buf[j] = 16'h2200 + j;
    axi_write(REG_LEN, 2, 4'b1111, 0);
    axi_write(TX_BASE, {tx_buf[1], tx_buf[0]}, 4'b1111, 0);
    #(PL_CLK_PERIOD * 5);    // P-18: 等待 TX_LEN 在 PL 域锁存稳定后再发起 TX_START（避免 tx_start_pulse 先于 tx_len 到达导致帧被丢弃）
    axi_write(REG_CTRL, 32'h1, 4'b1111, 0);
    pl_receive_frame(2, tmp_ok);
    tmp_ok = 1'b1;
    for (j = 0; j < 2; j = j + 1)
        if (rx_cap_buf[j] !== tx_buf[j]) tmp_ok = 1'b0;
    check("T11b: 第2次 TX_START（反向toggle）发送成功", tmp_ok);

    //======================================================
    // 汇总
    //======================================================
    #(AXI_CLK_PERIOD * 20);
    $display("=========================================");
    $display("  Test Summary: PASS=%0d  FAIL=%0d", pass_cnt, fail_cnt);
    $display("=========================================");
    if (fail_cnt == 0) begin
        $display("  *** ALL TESTS PASSED ***");
        $display("TEST PASSED");
    end else begin
        $display("  *** SOME TESTS FAILED ***");
        $display("TEST FAILED");
    end
    $display("=========================================");
    $finish;
end

// 超时保护
initial begin
    #(AXI_CLK_PERIOD * 200000);   // 2ms 超时
    $display("[ERROR] Simulation timeout!");
    $display("TEST FAILED");
    $finish;
end

endmodule
