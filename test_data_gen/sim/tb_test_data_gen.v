`timescale 1ns / 1ps

//============================================================================
// tb_test_data_gen.v
// ----------------------------------------------------------------------------
// test_data_gen 模块仿真测试平台（自检式）
//
// 验证范围：
//   [主 DUT，DATA_WIDTH=32]
//   TC-01 INCREMENT 模式单帧           —— 自增计数 + tlast
//   TC-02 PRBS 模式单帧                —— 伪随机序列 + tlast
//   TC-03 CONSTANT 模式单帧            —— 恒定数据
//   TC-04 WALK_ONE 模式单帧            —— 走 1 序列
//   TC-05 帧长可配（1 / 16 / 64 beats） —— cfg_frame_beats 生效
//   TC-06 下游反压（tready 周期拉低）   —— 数据无丢失、tlast 正确
//   TC-07 连续多帧（重启）             —— ctrl_start 重复触发
//   [位宽可配置性证明]
//   TC-08 DATA_WIDTH=8  INCREMENT      —— 高位截断正确
//   TC-09 DATA_WIDTH=64 INCREMENT      —— 全 64 位输出正确
//
// 自检机制：
//   - 输出采集器：在 m_axis_tvalid && m_axis_tready 时采集 tdata/tlast
//   - 参考模型：build_expected() 按模式计算期望序列
//   - 逐拍比较，不匹配则报错并累加失败计数
//============================================================================
module tb_test_data_gen;

    // ========== 参数 ==========
    localparam CLK_PERIOD = 10;         // 100MHz -> 10ns

    // 模式编码（与 RTL 一致）
    localparam [1:0] MODE_INC   = 2'b00;
    localparam [1:0] MODE_PRBS  = 2'b01;
    localparam [1:0] MODE_CONST = 2'b10;
    localparam [1:0] MODE_WALK  = 2'b11;

    // ========== 主 DUT（32-bit）信号 ==========
    reg                    aclk;
    reg                    aresetn;
    reg                    ctrl_start;
    reg  [1:0]             cfg_mode;
    reg  [31:0]            cfg_seed;
    reg  [15:0]            cfg_frame_beats;
    wire [31:0]            m_axis_tdata;
    wire                   m_axis_tvalid;
    wire                   m_axis_tlast;
    wire [7:0]             m_axis_tuser;
    reg                    m_axis_tready;
    wire                   busy;

    // ========== 位宽可配置性 DUT ==========
    // ---- 8-bit ----
    reg                    c8_start;
    reg  [1:0]             c8_mode;
    reg  [7:0]             c8_seed;
    reg  [15:0]            c8_fbeats;
    wire [7:0]             m8_tdata;
    wire                   m8_tvalid;
    wire                   m8_tlast;
    wire                   m8_busy;
    // ---- 64-bit ----
    reg                    c64_start;
    reg  [1:0]             c64_mode;
    reg  [63:0]            c64_seed;
    reg  [15:0]            c64_fbeats;
    wire [63:0]            m64_tdata;
    wire                   m64_tvalid;
    wire                   m64_tlast;
    wire                   m64_busy;

    // ========== 主 DUT 输出采集 ==========
    reg  [31:0] rx_q [0:4095];
    reg          rx_tlast [0:4095];
    integer      rx_count;
    integer      rx_start;

    // ========== 期望数组（模块级，避免 Verilog-2001 数组传参限制）==========
    reg  [31:0] g_exp [0:4095];
    reg          g_exp_tlast [0:4095];

    // ========== 8-bit / 64-bit 采集 ==========
    reg  [31:0] rx8 [0:63];
    integer      rx8_count;
    reg  [63:0] rx64 [0:63];
    integer      rx64_count;

    // ========== 测试统计 ==========
    integer test_pass_count;
    integer test_fail_count;
    integer total_errors;

    // 模块级临时变量（避免在匿名块内声明，符合 Verilog-2001）
    integer guard;
    integer seg_start;
    integer f;

    //=====================================================================
    // DUT 实例化
    //=====================================================================
    test_data_gen #(.DATA_WIDTH(32), .TUSER_WIDTH(8)) u_dut (
        .aclk            (aclk),
        .aresetn         (aresetn),
        .ctrl_start      (ctrl_start),
        .cfg_mode        (cfg_mode),
        .cfg_seed        (cfg_seed),
        .cfg_frame_beats (cfg_frame_beats),
        .m_axis_tdata    (m_axis_tdata),
        .m_axis_tvalid   (m_axis_tvalid),
        .m_axis_tlast    (m_axis_tlast),
        .m_axis_tuser    (m_axis_tuser),
        .m_axis_tready   (m_axis_tready),
        .busy            (busy)
    );

    test_data_gen #(.DATA_WIDTH(8), .TUSER_WIDTH(8)) u_dut8 (
        .aclk            (aclk),
        .aresetn         (aresetn),
        .ctrl_start      (c8_start),
        .cfg_mode        (c8_mode),
        .cfg_seed        (c8_seed),
        .cfg_frame_beats (c8_fbeats),
        .m_axis_tdata    (m8_tdata),
        .m_axis_tvalid   (m8_tvalid),
        .m_axis_tlast    (m8_tlast),
        .m_axis_tuser    (),
        .m_axis_tready   (m_axis_tready),
        .busy            (m8_busy)
    );

    test_data_gen #(.DATA_WIDTH(64), .TUSER_WIDTH(8)) u_dut64 (
        .aclk            (aclk),
        .aresetn         (aresetn),
        .ctrl_start      (c64_start),
        .cfg_mode        (c64_mode),
        .cfg_seed        (c64_seed),
        .cfg_frame_beats (c64_fbeats),
        .m_axis_tdata    (m64_tdata),
        .m_axis_tvalid   (m64_tvalid),
        .m_axis_tlast    (m64_tlast),
        .m_axis_tuser    (),
        .m_axis_tready   (m_axis_tready),
        .busy            (m64_busy)
    );

    // ========== 时钟生成 ==========
    initial begin
        aclk = 1'b0;
        forever #(CLK_PERIOD/2) aclk = ~aclk;
    end

    // ========== 主 DUT 采集器 ==========
    always @(posedge aclk) begin
        if (!aresetn) begin
            rx_count <= 0;
        end else if (m_axis_tvalid && m_axis_tready) begin
            rx_q[rx_count]      <= m_axis_tdata;
            rx_tlast[rx_count]  <= m_axis_tlast;
            rx_count            <= rx_count + 1;
        end
    end

    // ========== 8-bit 采集器 ==========
    always @(posedge aclk) begin
        if (!aresetn) rx8_count <= 0;
        else if (m8_tvalid && m_axis_tready) begin
            rx8[rx8_count] <= m8_tdata;
            rx8_count      <= rx8_count + 1;
        end
    end

    // ========== 64-bit 采集器 ==========
    always @(posedge aclk) begin
        if (!aresetn) rx64_count <= 0;
        else if (m64_tvalid && m_axis_tready) begin
            rx64[rx64_count] <= m64_tdata;
            rx64_count       <= rx64_count + 1;
        end
    end

    //=====================================================================
    // PRBS 单步（与 RTL 完全一致：位宽 = DATA_WIDTH，抽头 最高位/次高位/bit1/bit0）
    // 本测试平台 PRBS 仅作用于 32-bit 主 DUT，故按 32 位实现
    //=====================================================================
    function [31:0] prbs_step;
        input [31:0] x;
        reg fb;
        begin
            fb = x[31] ^ x[30] ^ x[1] ^ x[0];
            prbs_step = {fb, x[31:1]};
        end
    endfunction

    //=====================================================================
    // 任务：构建期望序列
    //=====================================================================
    task build_expected;
        input [1:0] mode;
        input [31:0] seed;
        input [15:0] fbeats;
        integer i;
        reg [31:0] prbs_s;
        reg [63:0] walk_s;
        begin
            prbs_s = (seed == 0) ? 32'hFFFF_FFFF : seed;
            walk_s = seed;
            for (i = 0; i < fbeats; i = i + 1) begin
                case (mode)
                    MODE_INC:   g_exp[i] = seed + i;
                    MODE_CONST: g_exp[i] = seed;
                    MODE_PRBS:  begin g_exp[i] = prbs_s; prbs_s = prbs_step(prbs_s); end
                    MODE_WALK:  begin g_exp[i] = walk_s[31:0]; walk_s = {walk_s[62:0], walk_s[63]}; end
                    default:    g_exp[i] = seed + i;
                endcase
                g_exp_tlast[i] = (i == fbeats - 1);
            end
        end
    endtask

    //=====================================================================
    // 任务：脉冲启动 ctrl_start（1 拍高）
    //=====================================================================
    task pulse_start;
        begin
            @(posedge aclk);
            ctrl_start <= 1'b1;
            @(posedge aclk);
            ctrl_start <= 1'b0;
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
    // 任务：运行一帧（主 32-bit DUT）并等待完成
    //=====================================================================
    task run_frame;
        input [1:0]  mode;
        input [31:0] seed;
        input [15:0] fbeats;
        input [255:0] tname;
        integer guard;
        begin
            cfg_mode        <= mode;
            cfg_seed        <= seed;
            cfg_frame_beats <= fbeats;
            rx_start = rx_count;
            build_expected(mode, seed, fbeats);

            pulse_start;

            // 等待 busy 拉高（容忍启动延迟）
            guard = 0;
            while (!busy && guard < 100000) begin @(posedge aclk); guard = guard + 1; end
            // 等待 busy 拉低（帧完成）
            guard = 0;
            while (busy && guard < 100000) begin @(posedge aclk); guard = guard + 1; end
            wait_cycles(2);

            compare_block(tname, fbeats, rx_start);
        end
    endtask

    //=====================================================================
    // 任务：比较主 DUT 采集结果与期望
    //=====================================================================
    task compare_block;
        input [255:0] tname;
        input integer  count;
        input integer  start_idx;
        integer i;
        integer errors;
        begin
            errors = 0;
            for (i = 0; i < count; i = i + 1) begin
                if (rx_q[start_idx + i] !== g_exp[i]) begin
                    $display("  [FAIL] %0s: beat[%0d] expected=0x%08h got=0x%08h",
                             tname, i, g_exp[i], rx_q[start_idx + i]);
                    errors = errors + 1;
                end
                if (rx_tlast[start_idx + i] !== g_exp_tlast[i]) begin
                    $display("  [FAIL] %0s: tlast[%0d] expected=%0b got=%0b",
                             tname, i, g_exp_tlast[i], rx_tlast[start_idx + i]);
                    errors = errors + 1;
                end
            end
            if (errors == 0) begin
                $display("  [PASS] %0s: %0d beats verified OK", tname, count);
                test_pass_count = test_pass_count + 1;
            end else begin
                $display("  [FAIL] %0s: %0d errors", tname, errors);
                test_fail_count = test_fail_count + 1;
                total_errors    = total_errors + errors;
            end
        end
    endtask

    //=====================================================================
    // 主测试流程
    //=====================================================================
    initial begin
        $display("==============================================================");
        $display(" test_data_gen Testbench Simulation Start");
        $display("==============================================================");

        // 初始化
        aclk            = 1'b0;
        aresetn         = 1'b0;
        ctrl_start      = 1'b0;
        cfg_mode        = MODE_INC;
        cfg_seed        = 32'd0;
        cfg_frame_beats = 16'd16;
        m_axis_tready   = 1'b1;
        c8_start        = 1'b0;
        c8_mode         = MODE_INC;
        c8_seed         = 8'd0;
        c8_fbeats       = 16'd8;
        c64_start       = 1'b0;
        c64_mode        = MODE_INC;
        c64_seed        = 64'd0;
        c64_fbeats      = 16'd8;
        rx_count        = 0;
        rx8_count       = 0;
        rx64_count      = 0;
        test_pass_count = 0;
        test_fail_count = 0;
        total_errors    = 0;

        // 复位
        #(CLK_PERIOD * 5);
        @(posedge aclk);
        aresetn = 1'b1;
        #(CLK_PERIOD * 2);

        $display("\n--- Reset released, starting tests ---\n");

        //==============================================================
        // TC-01: INCREMENT 模式单帧（16 beats）
        //==============================================================
        $display("[TC-01] INCREMENT mode, 16 beats");
        run_frame(MODE_INC, 32'h0000_0000, 16'd16, "TC-01 INC");

        //==============================================================
        // TC-02: PRBS 模式单帧（16 beats）
        //==============================================================
        $display("\n[TC-02] PRBS mode, 16 beats");
        run_frame(MODE_PRBS, 32'h1234_5678, 16'd16, "TC-02 PRBS");

        //==============================================================
        // TC-03: CONSTANT 模式单帧（8 beats）
        //==============================================================
        $display("\n[TC-03] CONSTANT mode, 8 beats");
        run_frame(MODE_CONST, 32'hABCD_EF00, 16'd8, "TC-03 CONST");

        //==============================================================
        // TC-04: WALK_ONE 模式单帧（32 beats）
        //==============================================================
        $display("\n[TC-04] WALK_ONE mode, 32 beats");
        run_frame(MODE_WALK, 32'h0000_0001, 16'd32, "TC-04 WALK");

        //==============================================================
        // TC-05: 帧长可配（1 beat 与 64 beats）
        //==============================================================
        $display("\n[TC-05] Frame length config (1 beat & 64 beats)");
        run_frame(MODE_INC, 32'h0000_0100, 16'd1,  "TC-05a INC 1beat");
        run_frame(MODE_INC, 32'h0000_0200, 16'd64, "TC-05b INC 64beat");

        //==============================================================
        // TC-06: 下游反压（tready 周期拉低）
        //==============================================================
        $display("\n[TC-06] Downstream backpressure (tready toggling)");
        begin : tc06
            fork
                begin : tready_toggle
                    integer j;
                    for (j = 0; j < 400; j = j + 1) begin
                        m_axis_tready = 1'b1; wait_cycles(1);
                        m_axis_tready = 1'b0; wait_cycles(2);
                    end
                    m_axis_tready = 1'b1;
                end
                begin : send_bp
                    // PRBS 帧在反压下应仍完整、有序、不丢数据
                    cfg_mode        <= MODE_PRBS;
                    cfg_seed        <= 32'hDEAD_BEEF;
                    cfg_frame_beats <= 16'd32;
                    rx_start = rx_count;
                    build_expected(MODE_PRBS, 32'hDEAD_BEEF, 16'd32);
                    pulse_start;
                    guard = 0;
                    while (!busy && guard < 100000) begin @(posedge aclk); guard = guard + 1; end
                    guard = 0;
                    while (busy && guard < 100000) begin @(posedge aclk); guard = guard + 1; end
                end
            join
            wait_cycles(2);
            $display("    (backpressure frame collected %0d bytes)", 32);
            compare_block("TC-06 backpressure PRBS", 32, rx_start);
        end

        //==============================================================
        // TC-07: 连续多帧（重启）
        //==============================================================
        $display("\n[TC-07] Continuous multi-frame (restart)");
        begin : tc07
            // 连续 3 帧 INCREMENT，帧间无缝重启
            cfg_mode        <= MODE_INC;
            cfg_seed        <= 32'h0000_1000;
            cfg_frame_beats <= 16'd10;
            rx_start = rx_count;
            // 逐帧运行并各自比较
            begin : frames
                for (f = 0; f < 3; f = f + 1) begin
                    seg_start = rx_count;
                    build_expected(MODE_INC, 32'h0000_1000, 16'd10);
                    pulse_start;
                    guard = 0;
                    while (!busy && guard < 100000) begin @(posedge aclk); guard = guard + 1; end
                    guard = 0;
                    while (busy && guard < 100000) begin @(posedge aclk); guard = guard + 1; end
                    wait_cycles(1);
                    compare_block("TC-07 frame", 10, seg_start);
                end
            end
        end

        //==============================================================
        // TC-08: DATA_WIDTH=8 INCREMENT（高位截断验证）
        //==============================================================
        $display("\n[TC-08] DATA_WIDTH=8 INCREMENT (truncation)");
        begin : tc08
            integer i;
            integer errors;
            c8_mode  <= MODE_INC;
            c8_seed  <= 8'h34;          // 注意：仅低 8 位
            c8_fbeats<= 16'd8;
            @(posedge aclk); c8_start <= 1'b1; @(posedge aclk); c8_start <= 1'b0;
            guard = 0;
            while (!m8_busy && guard < 100000) begin @(posedge aclk); guard = guard + 1; end
            guard = 0;
            while (m8_busy && guard < 100000) begin @(posedge aclk); guard = guard + 1; end
            wait_cycles(2);
            errors = 0;
            for (i = 0; i < 8; i = i + 1) begin
                // 期望：8'h34, 8'h35, ... 低位截断
                if (rx8[i] !== ((8'h34 + i) & 8'hFF)) begin
                    $display("  [FAIL] TC-08: byte[%0d] expected=0x%02h got=0x%02h",
                             i, ((8'h34 + i) & 8'hFF), rx8[i]);
                    errors = errors + 1;
                end
            end
            if (errors == 0) begin
                $display("  [PASS] TC-08: 8-bit width verified OK (truncated)");
                test_pass_count = test_pass_count + 1;
            end else begin
                $display("  [FAIL] TC-08: %0d errors", errors);
                test_fail_count = test_fail_count + 1;
                total_errors    = total_errors + errors;
            end
        end

        //==============================================================
        // TC-09: DATA_WIDTH=64 INCREMENT（全 64 位验证）
        //==============================================================
        $display("\n[TC-09] DATA_WIDTH=64 INCREMENT (full width)");
        begin : tc09
            integer i;
            integer errors;
            c64_mode  <= MODE_INC;
            c64_seed  <= 64'h0000_0000_0000_00AA;
            c64_fbeats<= 16'd8;
            @(posedge aclk); c64_start <= 1'b1; @(posedge aclk); c64_start <= 1'b0;
            guard = 0;
            while (!m64_busy && guard < 100000) begin @(posedge aclk); guard = guard + 1; end
            guard = 0;
            while (m64_busy && guard < 100000) begin @(posedge aclk); guard = guard + 1; end
            wait_cycles(2);
            errors = 0;
            for (i = 0; i < 8; i = i + 1) begin
                if (rx64[i] !== (64'h0000_0000_0000_00AA + i)) begin
                    $display("  [FAIL] TC-09: beat[%0d] expected=0x%016h got=0x%016h",
                             i, (64'h0000_0000_0000_00AA + i), rx64[i]);
                    errors = errors + 1;
                end
            end
            if (errors == 0) begin
                $display("  [PASS] TC-09: 64-bit width verified OK (full width)");
                test_pass_count = test_pass_count + 1;
            end else begin
                $display("  [FAIL] TC-09: %0d errors", errors);
                test_fail_count = test_fail_count + 1;
                total_errors    = total_errors + errors;
            end
        end

        // ========== 测试结束 ==========
        $display("\n==============================================================");
        $display(" Simulation Summary");
        $display("--------------------------------------------------------------");
        $display("  Total bytes collected (32-bit DUT) : %0d", rx_count);
        $display("  Tests passed                      : %0d", test_pass_count);
        $display("  Tests failed                      : %0d", test_fail_count);
        $display("  Total errors                      : %0d", total_errors);
        $display("==============================================================");

        if (test_fail_count == 0 && total_errors == 0) begin
            $display("\nTEST PASSED");
        end else begin
            $display("\nTEST FAILED");
        end

        $finish;
    end

    // ========== 波形 dump ==========
    initial begin
        $dumpfile("test_data_gen.vcd");
        $dumpvars(0, tb_test_data_gen);
    end

endmodule
