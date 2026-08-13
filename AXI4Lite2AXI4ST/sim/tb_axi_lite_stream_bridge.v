`timescale 1ns / 1ps

//============================================================================
// tb_axi_lite_stream_bridge.v
// 自检测试平台（仿真测试脚本，置于 sim/ 目录）
// 待测设计：axi_lite_stream_bridge（axi4lite2axist + axist2native 内部回环）
//
// 覆盖：
//   T1 基础单写单读
//   T2 AW/W 分离握手（验证缺陷 D-04：AW/W 独立握手）
//   T3 字节选通写入（WSTRB 分字节生效）
//   T4 读写并发（验证 TX 轮询仲裁：WRQ/RDQ 同时非空）
//   T5 连续多笔背靠背事务（全部寄存器读写）
//   T6 地址越界：写/读越界返回 DECERR(2'b11)，越界读回填 0xDEAD_BEEF
//   T7 读响应 RRESP 端到端正确性（OKAY=2'b00）
//============================================================================
module tb_axi_lite_stream_bridge;

    parameter C_S_AXI_DATA_WIDTH = 32;
    parameter C_S_AXI_ADDR_WIDTH = 32;
    parameter C_AXIS_DATA_WIDTH  = 32;
    parameter C_REG_NUM          = 4;
    parameter C_FIFO_DEPTH       = 16;

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

    // 波形输出（VCD），便于后续查看
    initial begin
        $dumpfile("tb_axi_lite_stream_bridge.vcd");
        $dumpvars(0, tb_axi_lite_stream_bridge);
    end

    //--------------------------------------------------------------------------
    // AXI4-Lite 写任务（AW/W 同拍，返回 BRESP）
    //--------------------------------------------------------------------------
    task axi_lite_write;
        input  [31:0] addr;
        input  [31:0] data;
        input  [3:0]  strb;
        output [1:0]  bresp;
        begin
            @(posedge aclk);
            s_axi_awaddr  = addr;
            s_axi_awprot  = 3'b000;
            s_axi_awvalid = 1'b1;
            s_axi_wdata   = data;
            s_axi_wstrb   = strb;
            s_axi_wvalid  = 1'b1;
            s_axi_bready  = 1'b1;

            while (!s_axi_awready) @(posedge aclk);
            @(posedge aclk);
            s_axi_awvalid = 1'b0;

            while (!s_axi_wready) @(posedge aclk);
            @(posedge aclk);
            s_axi_wvalid = 1'b0;

            while (!s_axi_bvalid) @(posedge aclk);
            bresp = s_axi_bresp;
            @(posedge aclk);
            s_axi_bready = 1'b0;
        end
    endtask

    //--------------------------------------------------------------------------
    // AXI4-Lite 写任务（AW/W 分离发送，验证 D-04 修正）
    //--------------------------------------------------------------------------
    task axi_lite_write_split;
        input  [31:0] addr;
        input  [31:0] data;
        input  [3:0]  strb;
        output [1:0]  bresp;
        begin
            @(posedge aclk);
            s_axi_awaddr  = addr;
            s_axi_awprot  = 3'b000;
            s_axi_awvalid = 1'b1;
            s_axi_bready  = 1'b1;

            while (!s_axi_awready) @(posedge aclk);
            @(posedge aclk);
            s_axi_awvalid = 1'b0;

            // 延迟 3 拍再发 W
            repeat(3) @(posedge aclk);
            s_axi_wdata   = data;
            s_axi_wstrb   = strb;
            s_axi_wvalid  = 1'b1;

            while (!s_axi_wready) @(posedge aclk);
            @(posedge aclk);
            s_axi_wvalid = 1'b0;

            while (!s_axi_bvalid) @(posedge aclk);
            bresp = s_axi_bresp;
            @(posedge aclk);
            s_axi_bready = 1'b0;
        end
    endtask

    //--------------------------------------------------------------------------
    // AXI4-Lite 读任务（返回 RDATA 与 RRESP）
    //--------------------------------------------------------------------------
    task axi_lite_read;
        input  [31:0] addr;
        output [31:0] data;
        output [1:0]  rresp;
        begin
            @(posedge aclk);
            s_axi_araddr  = addr;
            s_axi_arprot  = 3'b000;
            s_axi_arvalid = 1'b1;
            s_axi_rready  = 1'b1;

            while (!s_axi_arready) @(posedge aclk);
            @(posedge aclk);
            s_axi_arvalid = 1'b0;

            while (!s_axi_rvalid) @(posedge aclk);
            data  = s_axi_rdata;
            rresp = s_axi_rresp;
            @(posedge aclk);
            s_axi_rready = 1'b0;
        end
    endtask

    //--------------------------------------------------------------------------
    // 并发测试辅助任务（供 fork 调用，避免无名块内声明限制）
    //--------------------------------------------------------------------------
    task t4_write;
        output [1:0] bresp_w;
        begin
            axi_lite_write(32'h0000_0008, 32'hA5A5_A5A5, 4'b1111, bresp_w);
        end
    endtask

    task t4_read;
        output [31:0] rd_r;
        output [1:0]  rresp_r;
        begin
            axi_lite_read(32'h0000_0000, rd_r, rresp_r);
        end
    endtask

    //--------------------------------------------------------------------------
    // 主测试序列
    //--------------------------------------------------------------------------
    integer errors;
    reg [31:0] rd;
    reg [1:0]  bresp, rresp;
    reg [1:0]  bresp_t4;
    reg [31:0] rd_t4;
    reg [1:0]  rresp_t4;

    initial begin
        errors = 0;
        // 初始化
        aresetn = 0;
        s_axi_awaddr  = 0; s_axi_awprot = 0; s_axi_awvalid = 0;
        s_axi_wdata   = 0; s_axi_wstrb  = 0; s_axi_wvalid  = 0;
        s_axi_bready  = 0;
        s_axi_araddr  = 0; s_axi_arprot = 0; s_axi_arvalid = 0;
        s_axi_rready  = 0;

        #20;
        aresetn = 1;
        #40;

        $display("\n==================== 测试1：基础单写单读 ====================");
        axi_lite_write(32'h0000_0000, 32'h1234_5678, 4'b1111, bresp);
        if (bresp !== 2'b00) begin $display("  [FAIL] 写 BRESP 应为 OKAY，实际 2'b%b", bresp); errors = errors + 1; end
        axi_lite_read(32'h0000_0000, rd, rresp);
        if (rd !== 32'h1234_5678) begin $display("  [FAIL] 寄存器0读回错误: 预期 0x12345678, 实际 0x%08x", rd); errors = errors + 1; end
        else $display("  [PASS] 寄存器0 读回 0x%08x", rd);
        if (rresp !== 2'b00) begin $display("  [FAIL] 读 RRESP 应为 OKAY，实际 2'b%b", rresp); errors = errors + 1; end

        #30;
        $display("\n==================== 测试2：AW/W 分离握手 (D-04) ====================");
        axi_lite_write_split(32'h0000_0004, 32'hCAFE_BABE, 4'b1111, bresp);
        if (bresp !== 2'b00) begin $display("  [FAIL] 分离写 BRESP 应为 OKAY，实际 2'b%b", bresp); errors = errors + 1; end
        axi_lite_read(32'h0000_0004, rd, rresp);
        if (rd !== 32'hCAFE_BABE) begin $display("  [FAIL] 寄存器1读回错误: 预期 0xCAFEBABE, 实际 0x%08x", rd); errors = errors + 1; end
        else $display("  [PASS] 寄存器1 读回 0x%08x", rd);

        #30;
        $display("\n==================== 测试3：字节选通写 ====================");
        axi_lite_write(32'h0000_000C, 32'hFFFF_FFFF, 4'b1111, bresp);
        axi_lite_write(32'h0000_000C, 32'h0000_1122, 4'b0011, bresp); // 仅低2字节
        axi_lite_read(32'h0000_000C, rd, rresp);
        if (rd !== 32'hFFFF_1122) begin $display("  [FAIL] 字节选通错误: 预期 0xFFFF1122, 实际 0x%08x", rd); errors = errors + 1; end
        else $display("  [PASS] 寄存器3 读回 0x%08x (低2字节被覆盖)", rd);

        #30;
        $display("\n==================== 测试4：读写并发 (轮询仲裁) ====================");
        // 预写 reg2，然后同时发起 写(reg2) 与 读(reg0)，验证 TX 轮询不堵塞
        axi_lite_write(32'h0000_0008, 32'hDEAD_BEEF, 4'b1111, bresp);
        fork
            t4_write(bresp_t4);
            t4_read(rd_t4, rresp_t4);
        join
        if (bresp_t4 !== 2'b00) begin $display("  [FAIL] 并发写 BRESP 应为 OKAY，实际 2'b%b", bresp_t4); errors = errors + 1; end
        if (rd_t4 !== 32'h1234_5678) begin $display("  [FAIL] 并发读错误: 预期 0x12345678, 实际 0x%08x", rd_t4); errors = errors + 1; end
        else $display("  [PASS] 并发读 寄存器0 = 0x%08x", rd_t4);
        if (rresp_t4 !== 2'b00) begin $display("  [FAIL] 并发读 RRESP 应为 OKAY，实际 2'b%b", rresp_t4); errors = errors + 1; end
        // 校验并发写结果
        axi_lite_read(32'h0000_0008, rd, rresp);
        if (rd !== 32'hA5A5_A5A5) begin $display("  [FAIL] 并发写结果错误: 预期 0xA5A5A5A5, 实际 0x%08x", rd); errors = errors + 1; end
        else $display("  [PASS] 并发写 寄存器2 = 0x%08x", rd);

        #30;
        $display("\n==================== 测试5：连续多笔背靠背 ====================");
        begin : t5_loop
            integer k;
            for (k = 0; k < C_REG_NUM; k = k + 1)
                axi_lite_write(k * 4, 32'hA000_0000 + k, 4'b1111, bresp);
            for (k = 0; k < C_REG_NUM; k = k + 1) begin
                axi_lite_read(k * 4, rd, rresp);
                if (rd !== (32'hA000_0000 + k)) begin $display("  [FAIL] 连续事务读错误[%0d]: 预期 0x%08x, 实际 0x%08x", k, 32'hA000_0000 + k, rd); errors = errors + 1; end
                else $display("  [PASS] 寄存器%0d = 0x%08x", k, rd);
            end
        end

        #30;
        $display("\n==================== 测试6：地址越界 DECERR ====================");
        // C_REG_NUM=4 -> 合法地址 0x0/0x4/0x8/0xC；0x10 越界
        axi_lite_write(32'h0000_0010, 32'hBAD0_0000, 4'b1111, bresp);
        if (bresp !== 2'b11) begin $display("  [FAIL] 越界写 BRESP 应为 DECERR(2'b11), 实际 2'b%b", bresp); errors = errors + 1; end
        else $display("  [PASS] 越界写 返回 DECERR");
        // 再次读合法寄存器，确认未受影响
        // 注意：T5 已对 reg0 写入 0xA000_0000 并通过校验，故此处 reg0 当前值应为
        // 0xA000_0000。越界写（addr=0x10）不应改写任何合法寄存器，因此 reg0 应保持
        // T5 写入的值不变。原测试期望 0x12345678 为陈旧（T1 写入、但已被 T5 覆盖）。
        axi_lite_read(32'h0000_0000, rd, rresp);
        if (rd !== 32'hA000_0000) begin $display("  [FAIL] 越界写不应改写合法寄存器 reg0: 预期 0xA0000000, 实际 0x%08x", rd); errors = errors + 1; end
        else $display("  [PASS] 越界写未改写合法寄存器 reg0 = 0x%08x", rd);
        // 越界读
        axi_lite_read(32'h0000_0010, rd, rresp);
        if (rd !== 32'hDEAD_BEEF) begin $display("  [FAIL] 越界读 RDATA 应为 0xDEADBEEF, 实际 0x%08x", rd); errors = errors + 1; end
        else $display("  [PASS] 越界读 返回 0xDEADBEEF");
        if (rresp !== 2'b11) begin $display("  [FAIL] 越界读 RRESP 应为 DECERR(2'b11), 实际 2'b%b", rresp); errors = errors + 1; end
        else $display("  [PASS] 越界读 返回 DECERR");

        #30;
        $display("\n==================== 测试7：读响应 RRESP=OKAY 端到端校验 ====================");
        axi_lite_read(32'h0000_0004, rd, rresp);
        if (rresp !== 2'b00) begin $display("  [FAIL] 合法读 RRESP 应为 OKAY, 实际 2'b%b", rresp); errors = errors + 1; end
        else $display("  [PASS] 合法读 RRESP=OKAY, RDATA=0x%08x", rd);

        #50;
        if (errors == 0) begin
            $display("\n********************************************************");
            $display("  所有测试通过 (TOTAL PASS), 错误数 = 0");
            $display("********************************************************");
        end else begin
            $display("\n********************************************************");
            $display("  测试失败, 共 %0d 个错误", errors);
            $display("********************************************************");
        end
        $finish;
    end

    // 超时保护
    initial begin
        #200000;
        $display("\n[ERROR] 仿真超时！");
        $finish;
    end

    //==========================================================================
    // DEBUG 追踪（仅 +define+DEBUG 编译时启用）：定位 B 响应死锁
    //==========================================================================
`ifdef DEBUG
    initial begin
        $display("==== DEBUG TRACE (cmd channel / native fsm / rx path) ====");
        repeat (860) begin
            @(posedge aclk);
            $display("[DBG] T=%0t nat=%0d cmd_v=%b cmd_r=%b cmd_l=%b cmd_d=%h pcnt=%0d plen=%h ftyp=%h | tx=%0d popwr=%b hold=%b wrqe=%b wrqrd=%b mcmd_v=%b mcmd_r=%b mcmd_l=%b mcmd_d=%h | rx=%0d rsp_v=%b rdy=%b d=%h l=%b | brsp_e=%b bout=%b rden=%b | bval=%b",
                $time,
                DUT.u_axist2native.curr_state,
                DUT.u_axist2native.s_axis_cmd_tvalid,
                DUT.u_axist2native.s_axis_cmd_tready,
                DUT.u_axist2native.s_axis_cmd_tlast,
                DUT.u_axist2native.s_axis_cmd_tdata,
                DUT.u_axist2native.payload_cnt,
                DUT.u_axist2native.payload_len_reg,
                DUT.u_axist2native.frame_type_reg,
                DUT.u_axi4lite2axist.tx_state,
                DUT.u_axi4lite2axist.tx_pop_wrq,
                DUT.u_axi4lite2axist.tx_pop_hold,
                DUT.u_axi4lite2axist.wrq_empty,
                DUT.u_axi4lite2axist.wrq_rd_en,
                DUT.u_axi4lite2axist.m_axis_cmd_tvalid,
                DUT.u_axi4lite2axist.m_axis_cmd_tready,
                DUT.u_axi4lite2axist.m_axis_cmd_tlast,
                DUT.u_axi4lite2axist.m_axis_cmd_tdata,
                DUT.u_axi4lite2axist.rx_state,
                DUT.u_axi4lite2axist.s_axis_rsp_tvalid,
                DUT.u_axi4lite2axist.s_axis_rsp_tready,
                DUT.u_axi4lite2axist.s_axis_rsp_tdata,
                DUT.u_axi4lite2axist.s_axis_rsp_tlast,
                DUT.u_axi4lite2axist.brsp_empty,
                DUT.u_axi4lite2axist.brsp_dout,
                DUT.u_axi4lite2axist.brsp_rd_en,
                DUT.u_axi4lite2axist.s_axi_bvalid);

            $display("[WP] T=%0t mk=%b aw_rd=%b w_rd=%b aw_e=%b w_e=%b awf=%b wf=%b awwe=%b wwe=%b awv=%b wv=%b awd=%h wd=%h awh=%h wdh=%h wrqwe=%b wrqdin=%h wrqdout=%h",
                $time,
                DUT.u_axi4lite2axist.make_wrq,
                DUT.u_axi4lite2axist.aw_rd_en,
                DUT.u_axi4lite2axist.w_rd_en,
                DUT.u_axi4lite2axist.aw_empty,
                DUT.u_axi4lite2axist.w_empty,
                DUT.u_axi4lite2axist.aw_full,
                DUT.u_axi4lite2axist.w_full,
                DUT.u_axi4lite2axist.aw_wr_en,
                DUT.u_axi4lite2axist.w_wr_en,
                DUT.u_axi4lite2axist.s_axi_awvalid,
                DUT.u_axi4lite2axist.s_axi_wvalid,
                DUT.u_axi4lite2axist.aw_dout,
                DUT.u_axi4lite2axist.w_dout,
                DUT.u_axi4lite2axist.aw_hold,
                DUT.u_axi4lite2axist.wdata_hold,
                DUT.u_axi4lite2axist.wrq_wr_en,
                DUT.u_axi4lite2axist.wrq_din,
                DUT.u_axi4lite2axist.wrq_dout);

            if (DUT.u_axist2native.curr_state == 3'd4) begin
                $display("[EXEC] T=%0t wr=%b addr=%h idx=%0d inrange=%b wdata=%h strb=%h addr_err=%b | rf0=%h rf1=%h rf2=%h rf3=%h",
                    $time, DUT.u_axist2native.is_write_cmd, DUT.u_axist2native.addr_reg,
                    DUT.u_axist2native.reg_index, DUT.u_axist2native.addr_in_range,
                    DUT.u_axist2native.wdata_reg, DUT.u_axist2native.wstrb_reg, DUT.u_axist2native.addr_err,
                    DUT.u_axist2native.reg_file[0], DUT.u_axist2native.reg_file[1],
                    DUT.u_axist2native.reg_file[2], DUT.u_axist2native.reg_file[3]);
            end

            if (DUT.u_axist2native.curr_state == 3'd6) begin
                $display("[RSP] T=%0t wr=%b txcnt=%0d tdata=%h addr_err=%b rdata=%h",
                    $time, DUT.u_axist2native.is_write_cmd, DUT.u_axist2native.tx_payload_cnt,
                    DUT.u_axist2native.m_axis_rsp_tdata, DUT.u_axist2native.addr_err,
                    DUT.u_axist2native.rdata_reg);
            end

            if (DUT.u_axi4lite2axist.s_axi_bvalid)
                $display("[BVAL] T=%0t bresp=%b bready=%b",
                    $time, DUT.u_axi4lite2axist.s_axi_bresp, DUT.u_axi4lite2axist.s_axi_bready);

            if (DUT.u_axi4lite2axist.rx_push_b)
                $display("[RXB] T=%0t push_bresp=%b",
                    $time, DUT.u_axi4lite2axist.rx_push_bresp);

            if (DUT.u_axi4lite2axist.brsp_rd_en)
                $display("[BRD] T=%0t din=%b bvalid=%b",
                    $time, DUT.u_axi4lite2axist.brsp_dout, DUT.u_axi4lite2axist.s_axi_bvalid);

            if (DUT.u_axi4lite2axist.m_axis_cmd_tvalid)
                $display("[CMD] T=%0t v=%b r=%b l=%b d=%h",
                    $time, DUT.u_axi4lite2axist.m_axis_cmd_tvalid,
                    DUT.u_axi4lite2axist.m_axis_cmd_tready,
                    DUT.u_axi4lite2axist.m_axis_cmd_tlast,
                    DUT.u_axi4lite2axist.m_axis_cmd_tdata);

            if (DUT.u_axi4lite2axist.make_wrq) begin
                $display("[PAIR] T=%0t aw_dout=%h(%0d) w_dout=%h aw_e=%b w_e=%b aw_rd=%b w_rd=%b pop=%b wrq_e=%b",
                    $time, DUT.u_axi4lite2axist.aw_dout, DUT.u_axi4lite2axist.aw_dout[34:3],
                    DUT.u_axi4lite2axist.w_dout, DUT.u_axi4lite2axist.aw_empty,
                    DUT.u_axi4lite2axist.w_empty, DUT.u_axi4lite2axist.aw_rd_en,
                    DUT.u_axi4lite2axist.w_rd_en, DUT.u_axi4lite2axist.pair_pop,
                    DUT.u_axi4lite2axist.wrq_empty);
            end
        end
        $display("==== DEBUG TRACE END ====");
    end
`endif

endmodule
