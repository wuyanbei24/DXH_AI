`timescale 1ns / 1ps

//============================================================================
// tb_axis32_to_lvds8.v
// ----------------------------------------------------------------------------
// axis32_to_lvds8 模块仿真测试平台
//
// 测试用例：
//   TC-01: 基础单 beat 序列化
//   TC-02: 写命令帧（5 beats = 25 bytes）
//   TC-03: 读命令帧（3 beats = 15 bytes）
//   TC-04: tlast 传播验证
//   TC-05: 下游反压（tx_ready 周期性拉低）
//   TC-06: 上游反压（s_axis_tready 行为验证）
//   TC-07: 连续背靠背多 beat
//   TC-08: 复位恢复
//
// 自检机制：
//   - 输出字节采集器：在 tx_valid && tx_ready 时采集字节到数组
//   - 参考模型：根据输入 AXI4-Stream beat 计算期望字节序列
//   - 逐字节比较，不匹配则报错
//============================================================================
module tb_axis32_to_lvds8;

    // ========== 参数 ==========
    localparam CLK_PERIOD = 10;         // 100MHz -> 10ns

    // ========== 信号 ==========
    reg         aclk;
    reg         aresetn;

    reg  [31:0] s_axis_tdata;
    reg         s_axis_tvalid;
    reg         s_axis_tlast;
    wire        s_axis_tready;

    wire [7:0]  tx_data;
    wire        tx_valid;
    reg         tx_ready;

    // ========== 输出字节采集 ==========
    reg [7:0]   rx_byte_queue [0:1023];  // 采集到的字节队列
    integer     rx_byte_count;            // 已采集字节数
    integer     rx_check_idx;             // 检查索引

    // ========== 期望字节数组（模块级共享，避免 Verilog-2001 数组传参限制） ==========
    reg [7:0]   g_expected [0:1023];     // 期望字节数组

    // ========== 测试统计 ==========
    integer     test_pass_count;
    integer     test_fail_count;
    integer     total_errors;

    // ========== DUT 实例化 ==========
    axis32_to_lvds8 DUT (
        .aclk           (aclk),
        .aresetn        (aresetn),
        .s_axis_tdata   (s_axis_tdata),
        .s_axis_tvalid  (s_axis_tvalid),
        .s_axis_tlast   (s_axis_tlast),
        .s_axis_tready  (s_axis_tready),
        .tx_data        (tx_data),
        .tx_valid       (tx_valid),
        .tx_ready       (tx_ready)
    );

    // ========== 时钟生成 ==========
    initial begin
        aclk = 1'b0;
        forever #(CLK_PERIOD/2) aclk = ~aclk;
    end

    // ========== 输出字节采集器 ==========
    // 在 tx_valid && tx_ready 时采集字节
    always @(posedge aclk) begin
        if (!aresetn) begin
            rx_byte_count <= 0;
        end else if (tx_valid && tx_ready) begin
            rx_byte_queue[rx_byte_count] <= tx_data;
            rx_byte_count <= rx_byte_count + 1;
        end
    end

    //=====================================================================
    // 任务：发送单个 AXI4-Stream beat
    // 修正时序：先等一拍让 tvalid NBA 生效，再检查 tready 握手
    //=====================================================================
    task send_axis_beat;
        input [31:0] tdata;
        input        tlast;
        begin
            @(posedge aclk);
            s_axis_tdata  <= tdata;
            s_axis_tvalid <= 1'b1;
            s_axis_tlast  <= tlast;
            // 等一拍让 NBA 生效，tvalid 此时已为 1
            @(posedge aclk);
            // 等待握手完成（tvalid=1 时 s_axis_tready 才有意义）
            while (!s_axis_tready) @(posedge aclk);
            // 握手成功，撤销 tvalid
            s_axis_tvalid <= 1'b0;
            s_axis_tlast  <= 1'b0;
        end
    endtask

    //=====================================================================
    // 任务：等待 N 个时钟周期
    //=====================================================================
    task wait_cycles;
        input integer n;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) @(posedge aclk);
        end
    endtask

    //=====================================================================
    // 任务：等待所有字节输出完成
    // 修正时序：先等一拍让状态转移 NBA 生效，再检查 tx_valid
    //=====================================================================
    task wait_tx_idle;
        begin
            // 先等一拍，确保握手后的状态转移已生效
            @(posedge aclk);
            // 等待 tx_valid 变低（回到 S_IDLE）
            while (tx_valid) @(posedge aclk);
        end
    endtask

    //=====================================================================
    // 任务：验证采集到的字节（使用模块级 g_expected 数组）
    //=====================================================================
    task check_bytes;
        input integer expected_count;
        input [255:0] test_name;
        integer i;
        integer errors;
        begin
            errors = 0;
            for (i = 0; i < expected_count; i = i + 1) begin
                if (rx_byte_queue[rx_check_idx + i] !== g_expected[i]) begin
                    $display("  [FAIL] %0s: byte[%0d] expected=0x%02h, got=0x%02h",
                             test_name, i, g_expected[i], rx_byte_queue[rx_check_idx + i]);
                    errors = errors + 1;
                end
            end
            if (errors == 0) begin
                $display("  [PASS] %0s: %0d bytes verified OK", test_name, expected_count);
                test_pass_count = test_pass_count + 1;
            end else begin
                $display("  [FAIL] %0s: %0d/%0d bytes mismatch", test_name, errors, expected_count);
                test_fail_count = test_fail_count + 1;
                total_errors = total_errors + errors;
            end
            rx_check_idx = rx_check_idx + expected_count;
        end
    endtask

    //=====================================================================
    // 任务：打印采集到的字节（调试用）
    //=====================================================================
    task print_collected;
        input integer start_idx;
        input integer count;
        integer i;
        begin
            $write("    Bytes: ");
            for (i = 0; i < count; i = i + 1) begin
                $write("%02h ", rx_byte_queue[start_idx + i]);
            end
            $display("");
        end
    endtask

    //=====================================================================
    // 主测试流程
    //=====================================================================
    integer start_idx;

    initial begin
        // ========== 初始化 ==========
        $display("==============================================================");
        $display(" axis32_to_lvds8 Testbench Simulation Start");
        $display("==============================================================");

        aclk            = 1'b0;
        aresetn         = 1'b0;
        tx_ready        = 1'b1;
        s_axis_tdata    = 32'd0;
        s_axis_tvalid   = 1'b0;
        s_axis_tlast    = 1'b0;
        rx_byte_count   = 0;
        rx_check_idx    = 0;
        test_pass_count = 0;
        test_fail_count = 0;
        total_errors    = 0;

        // ========== 复位 ==========
        #(CLK_PERIOD * 5);
        @(posedge aclk);
        aresetn = 1'b1;
        #(CLK_PERIOD * 2);

        $display("\n--- Reset released, starting tests ---\n");

        //==============================================================
        // TC-01: 基础单 beat 序列化
        //==============================================================
        $display("[TC-01] Basic single beat serialization");
        begin : tc01
            // tdata = 0xDEADBEEF, tlast = 0
            // Expected: 0x00, 0xEF, 0xBE, 0xAD, 0xDE
            g_expected[0] = 8'h00;  // CTRL (tlast=0)
            g_expected[1] = 8'hEF;  // tdata[7:0]
            g_expected[2] = 8'hBE;  // tdata[15:8]
            g_expected[3] = 8'hAD;  // tdata[23:16]
            g_expected[4] = 8'hDE;  // tdata[31:24]

            start_idx = rx_byte_count;
            send_axis_beat(32'hDEADBEEF, 1'b0);
            wait_tx_idle;
            wait_cycles(2);
            print_collected(start_idx, 5);
            check_bytes(5, "TC-01 basic beat");
        end

        //==============================================================
        // TC-02: 写命令帧（5 beats = 25 bytes）
        //==============================================================
        $display("\n[TC-02] Write command frame (5 beats)");
        begin : tc02
            reg [31:0] awaddr, wdata;
            reg [3:0]  wstrb;

            awaddr = 32'h0000_1000;
            wdata  = 32'h1234_5678;
            wstrb  = 4'hF;

            // Beat 1: HEAD = {0xAA, 0x01, 0x03, 0x00}, tlast=0
            g_expected[0]  = 8'h00; g_expected[1]  = 8'h00; g_expected[2]  = 8'h03; g_expected[3]  = 8'h01; g_expected[4]  = 8'hAA;
            // Beat 2: ADDR = 0x00001000, tlast=0
            g_expected[5]  = 8'h00; g_expected[6]  = awaddr[7:0];  g_expected[7]  = awaddr[15:8]; g_expected[8]  = awaddr[23:16]; g_expected[9]  = awaddr[31:24];
            // Beat 3: WDATA = 0x12345678, tlast=0
            g_expected[10] = 8'h00; g_expected[11] = wdata[7:0];   g_expected[12] = wdata[15:8];  g_expected[13] = wdata[23:16];  g_expected[14] = wdata[31:24];
            // Beat 4: WSTRB = {28'h0, 4'hF}, tlast=0
            g_expected[15] = 8'h00; g_expected[16] = {4'h0, wstrb}; g_expected[17] = 8'h00;      g_expected[18] = 8'h00;        g_expected[19] = 8'h00;
            // Beat 5: TAIL = {0x55, 0x00, 0x00, 0x00}, tlast=1
            g_expected[20] = 8'h01; g_expected[21] = 8'h00;        g_expected[22] = 8'h00;      g_expected[23] = 8'h00;        g_expected[24] = 8'h55;

            start_idx = rx_byte_count;
            send_axis_beat({8'hAA, 8'h01, 8'h03, 8'h00}, 1'b0);
            send_axis_beat(awaddr,                         1'b0);
            send_axis_beat(wdata,                          1'b0);
            send_axis_beat({28'h0, wstrb},                 1'b0);
            send_axis_beat({8'h55, 8'h00, 8'h00, 8'h00},  1'b1);
            wait_tx_idle;
            wait_cycles(2);
            print_collected(start_idx, 25);
            check_bytes(25, "TC-02 write cmd frame");
        end

        //==============================================================
        // TC-03: 读命令帧（3 beats = 15 bytes）
        //==============================================================
        $display("\n[TC-03] Read command frame (3 beats)");
        begin : tc03
            reg [31:0] araddr;

            araddr = 32'h0000_2004;

            // Beat 1: HEAD = {0xAA, 0x02, 0x01, 0x00}, tlast=0
            g_expected[0]  = 8'h00; g_expected[1]  = 8'h00; g_expected[2]  = 8'h01; g_expected[3]  = 8'h02; g_expected[4]  = 8'hAA;
            // Beat 2: ADDR = 0x00002004, tlast=0
            g_expected[5]  = 8'h00; g_expected[6]  = araddr[7:0];  g_expected[7]  = araddr[15:8]; g_expected[8]  = araddr[23:16]; g_expected[9]  = araddr[31:24];
            // Beat 3: TAIL = {0x55, 0x00, 0x00, 0x00}, tlast=1
            g_expected[10] = 8'h01; g_expected[11] = 8'h00;        g_expected[12] = 8'h00;      g_expected[13] = 8'h00;        g_expected[14] = 8'h55;

            start_idx = rx_byte_count;
            send_axis_beat({8'hAA, 8'h02, 8'h01, 8'h00}, 1'b0);
            send_axis_beat(araddr,                         1'b0);
            send_axis_beat({8'h55, 8'h00, 8'h00, 8'h00},  1'b1);
            wait_tx_idle;
            wait_cycles(2);
            print_collected(start_idx, 15);
            check_bytes(15, "TC-03 read cmd frame");
        end

        //==============================================================
        // TC-04: tlast 传播验证
        //==============================================================
        $display("\n[TC-04] tlast propagation");
        begin : tc04
            // 3 beats: beat0 tlast=0, beat1 tlast=0, beat2 tlast=1
            g_expected[0]  = 8'h00; g_expected[1]  = 8'h01; g_expected[2]  = 8'h00; g_expected[3]  = 8'h00; g_expected[4]  = 8'h00;
            g_expected[5]  = 8'h00; g_expected[6]  = 8'h02; g_expected[7]  = 8'h00; g_expected[8]  = 8'h00; g_expected[9]  = 8'h00;
            g_expected[10] = 8'h01; g_expected[11] = 8'h03; g_expected[12] = 8'h00; g_expected[13] = 8'h00; g_expected[14] = 8'h00;

            start_idx = rx_byte_count;
            send_axis_beat(32'h0000_0001, 1'b0);
            send_axis_beat(32'h0000_0002, 1'b0);
            send_axis_beat(32'h0000_0003, 1'b1);
            wait_tx_idle;
            wait_cycles(2);
            print_collected(start_idx, 15);
            check_bytes(15, "TC-04 tlast propagation");
        end

        //==============================================================
        // TC-05: 下游反压（tx_ready 周期性拉低）
        //==============================================================
        $display("\n[TC-05] Downstream backpressure (tx_ready toggling)");
        begin : tc05
            // 发送 2 个 beat，期间 tx_ready 周期性拉低
            // Beat 0: tdata=0xAABBCCDD, tlast=0
            g_expected[0] = 8'h00; g_expected[1] = 8'hDD; g_expected[2] = 8'hCC; g_expected[3] = 8'hBB; g_expected[4] = 8'hAA;
            // Beat 1: tdata=0x11223344, tlast=1
            g_expected[5] = 8'h01; g_expected[6] = 8'h44; g_expected[7] = 8'h33; g_expected[8] = 8'h22; g_expected[9] = 8'h11;

            start_idx = rx_byte_count;

            // 在后台用单独的进程模拟 tx_ready 周期性变化
            fork
                begin : tx_ready_toggle
                    integer j;
                    for (j = 0; j < 50; j = j + 1) begin
                        tx_ready = 1'b1;
                        wait_cycles(1);
                        tx_ready = 1'b0;
                        wait_cycles(2);
                    end
                    tx_ready = 1'b1;
                end
                begin : send_data
                    wait_cycles(1);
                    send_axis_beat(32'hAABBCCDD, 1'b0);
                    send_axis_beat(32'h11223344, 1'b1);
                    wait_tx_idle;
                end
            join

            wait_cycles(2);
            print_collected(start_idx, 10);
            check_bytes(10, "TC-05 backpressure");
        end

        //==============================================================
        // TC-06: 上游反压（s_axis_tready 行为验证）
        //==============================================================
        $display("\n[TC-06] Upstream backpressure (s_axis_tready behavior)");
        begin : tc06
            // 当 DUT 正在序列化时，s_axis_tready 应该为 0
            g_expected[0] = 8'h00; g_expected[1] = 8'h78; g_expected[2] = 8'h56; g_expected[3] = 8'h34; g_expected[4] = 8'h12;

            start_idx = rx_byte_count;

            // 发送数据
            @(posedge aclk);
            s_axis_tdata  <= 32'h12345678;
            s_axis_tvalid <= 1'b1;
            s_axis_tlast  <= 1'b0;

            // 等一拍让 tvalid 生效
            @(posedge aclk);
            // 等待握手
            while (!s_axis_tready) @(posedge aclk);
            // 握手发生在这一拍，下一拍 DUT 进入 S_CTRL
            @(posedge aclk);
            // 此时 DUT 应在 S_CTRL，s_axis_tready 应该为 0
            if (s_axis_tready === 1'b0) begin
                $display("  [PASS] TC-06: s_axis_tready=0 during serialization");
                test_pass_count = test_pass_count + 1;
            end else begin
                $display("  [FAIL] TC-06: s_axis_tready=1 during serialization (expected 0)");
                test_fail_count = test_fail_count + 1;
                total_errors = total_errors + 1;
            end

            s_axis_tvalid <= 1'b0;
            wait_tx_idle;
            wait_cycles(2);
            print_collected(start_idx, 5);
            check_bytes(5, "TC-06 upstream backpressure data");
        end

        //==============================================================
        // TC-07: 连续背靠背多 beat
        //==============================================================
        $display("\n[TC-07] Continuous back-to-back beats");
        begin : tc07
            // 4 beats 连续发送，无间隙
            g_expected[0]  = 8'h00; g_expected[1]  = 8'hAA; g_expected[2]  = 8'h00; g_expected[3]  = 8'h00; g_expected[4]  = 8'h00;
            g_expected[5]  = 8'h00; g_expected[6]  = 8'hBB; g_expected[7]  = 8'h00; g_expected[8]  = 8'h00; g_expected[9]  = 8'h00;
            g_expected[10] = 8'h00; g_expected[11] = 8'hCC; g_expected[12] = 8'h00; g_expected[13] = 8'h00; g_expected[14] = 8'h00;
            g_expected[15] = 8'h01; g_expected[16] = 8'hDD; g_expected[17] = 8'h00; g_expected[18] = 8'h00; g_expected[19] = 8'h00;

            start_idx = rx_byte_count;

            // 背靠背发送
            @(posedge aclk);
            s_axis_tdata  <= 32'h000000AA;
            s_axis_tvalid <= 1'b1;
            s_axis_tlast  <= 1'b0;
            // 等一拍让 tvalid 生效
            @(posedge aclk);
            // 等待 beat0 握手
            while (!s_axis_tready) @(posedge aclk);

            // beat1: 在 beat0 握手后立即更新数据
            @(posedge aclk);
            s_axis_tdata  <= 32'h000000BB;
            s_axis_tlast  <= 1'b0;
            while (!s_axis_tready) @(posedge aclk);

            // beat2
            @(posedge aclk);
            s_axis_tdata  <= 32'h000000CC;
            s_axis_tlast  <= 1'b0;
            while (!s_axis_tready) @(posedge aclk);

            // beat3
            @(posedge aclk);
            s_axis_tdata  <= 32'h000000DD;
            s_axis_tlast  <= 1'b1;
            while (!s_axis_tready) @(posedge aclk);
            @(posedge aclk);
            s_axis_tvalid <= 1'b0;
            s_axis_tlast  <= 1'b0;

            wait_tx_idle;
            wait_cycles(2);
            print_collected(start_idx, 20);
            check_bytes(20, "TC-07 back-to-back");
        end

        //==============================================================
        // TC-08: 复位恢复
        //==============================================================
        $display("\n[TC-08] Reset recovery");
        begin : tc08
            // 先发送一个 beat，在序列化中途复位
            @(posedge aclk);
            s_axis_tdata  <= 32'hCAFE_BABE;
            s_axis_tvalid <= 1'b1;
            s_axis_tlast  <= 1'b0;
            // 等一拍让 tvalid 生效
            @(posedge aclk);
            // 等待握手
            while (!s_axis_tready) @(posedge aclk);
            // 握手成功，DUT 进入序列化
            @(posedge aclk);
            s_axis_tvalid <= 1'b0;

            // 等待进入序列化中间状态
            wait_cycles(2);

            // 突然复位
            aresetn = 1'b0;
            wait_cycles(3);

            // 检查复位后状态：tx_valid 应为 0
            // 注意：复位后 S_IDLE + tx_ready=1 时 s_axis_tready=1 是正确行为
            if (tx_valid === 1'b0) begin
                $display("  [PASS] TC-08: tx_valid=0 after reset (outputs cleared)");
                test_pass_count = test_pass_count + 1;
            end else begin
                $display("  [FAIL] TC-08: tx_valid=1 after reset (expected 0)");
                test_fail_count = test_fail_count + 1;
                total_errors = total_errors + 1;
            end

            // 清除采集计数（复位后的字节不计入验证）
            rx_byte_count  = 0;
            rx_check_idx   = 0;

            // 释放复位
            aresetn = 1'b1;
            wait_cycles(3);

            // 复位后正常发送一个 beat
            g_expected[0] = 8'h00; g_expected[1] = 8'h99; g_expected[2] = 8'h88; g_expected[3] = 8'h77; g_expected[4] = 8'h66;

            start_idx = rx_byte_count;
            send_axis_beat(32'h66778899, 1'b0);
            wait_tx_idle;
            wait_cycles(2);
            print_collected(start_idx, 5);
            check_bytes(5, "TC-08 post-reset beat");
        end

        // ========== 测试结束 ==========
        $display("\n==============================================================");
        $display(" Simulation Summary");
        $display("--------------------------------------------------------------");
        $display("  Total bytes collected : %0d", rx_byte_count);
        $display("  Tests passed          : %0d", test_pass_count);
        $display("  Tests failed          : %0d", test_fail_count);
        $display("  Total byte errors     : %0d", total_errors);
        $display("==============================================================");

        if (test_fail_count == 0 && total_errors == 0) begin
            $display("\nTEST PASSED");
        end else begin
            $display("\nTEST FAILED");
        end

        $finish;
    end

    // ========== 波形 dump（可选，调试用） ==========
    initial begin
        $dumpfile("axis32_to_lvds8.vcd");
        $dumpvars(0, tb_axis32_to_lvds8);
    end

endmodule
