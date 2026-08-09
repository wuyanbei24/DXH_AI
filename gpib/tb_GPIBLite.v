`timescale 1ns / 1ps
//=============================================================================
// 测试平台：GPIBLite (GPIB Talker/Listener 控制器) —— CDC 修复验证
//-----------------------------------------------------------------------------
// 验证目标：
//   1) APB 寄存器默认值与标识字
//   2) 监听模式：控者发送 UNL/MLA + 数据 -> 设备接收进 in-FIFO -> APB 读回
//   3) 讲者模式：APB 写 out-FIFO -> 设备(GPIB)发送 -> 控者(监听)接收
//   4) 跨时钟域(CDC)：sys_clk 与 APB_PCLK 异步、非整数倍，反复收发验证数据完整
//   5) 器件清除(IFC) 复位 in-FIFO
// 说明：
//   - 实例化 INFO_RDY_DLY=0 以跳过上电就绪长延时（仅测试用）
//   - sys_clk=40MHz(25ns)，apb_clk≈27.8MHz(36ns)，非整数倍 + 相位差 => 异步
//=============================================================================
module tb_GPIBLite;

    //--------------------------------------------------------------- 时钟
    reg sys_clk = 1'b0;     // 40 MHz
    reg apb_clk = 1'b0;     // ~27.8 MHz (非整数倍)
    always #12.5 sys_clk = ~sys_clk;
    always #18.0 apb_clk = ~apb_clk;

    reg sys_rstn  = 1'b0;
    reg apb_preset= 1'b0;

    //--------------------------------------------------------------- APB
    reg  [31:0] APB_PADDR;
    reg         APB_PENABLE;
    reg         APB_PWRITE;
    reg  [31:0] APB_PWDATA;
    reg         APB_PSEL;
    wire [31:0] APB_PRDATA;
    wire        APB_PREADY;
    wire        APB_PSLVERR;

    //--------------------------------------------------------------- GPIB
    wire [7:0] data;
    reg        ifc_tb = 1'b1;
    reg        atn_tb = 1'b1;
    reg        ren_tb = 1'b1;
    wire       srq;
    wire       eoi;
    wire       nrfd;
    wire       ndac;
    wire       dav;
    wire       te_a, te_b, sc, dc;
    wire       GPIB_infifo_empty;

    // TB 方向控制
    reg        host_src;        // TB 驱动 data & dav（控者发送）
    reg        host_lis;        // TB 驱动 nrfd & ndac（TB 监听）
    reg [7:0]  data_tb;
    reg        dav_tb;
    reg        nrfd_tb;         // 默认就绪
    reg        ndac_tb;         // 默认未接收

    assign data = host_src ? data_tb : 8'bz;
    assign dav  = host_src ? dav_tb  : 1'bz;
    assign nrfd = host_lis ? nrfd_tb : 1'bz;
    assign ndac = host_lis ? ndac_tb : 1'bz;
    assign ifc  = ifc_tb;
    assign atn  = atn_tb;
    assign ren  = ren_tb;

    // 开漏总线带上拉电阻：空闲(高阻)时解析为 1，避免 Z 经同步器产生 X 污染 DUT 状态机
    pullup pu_dav (dav);
    pullup pu_nrfd(nrfd);
    pullup pu_ndac(ndac);
    pullup pu_eoi (eoi);
    pullup pu_d0(data[0]); pullup pu_d1(data[1]); pullup pu_d2(data[2]); pullup pu_d3(data[3]);
    pullup pu_d4(data[4]); pullup pu_d5(data[5]); pullup pu_d6(data[6]); pullup pu_d7(data[7]);

    //--------------------------------------------------------------- 报告
    integer err_cnt  = 0;
    integer pass_cnt = 0;

    //--------------------------------------------------------------- 任务级共享变量
    integer i;
    integer k;
    reg [7:0]  exp_byte;
    reg [7:0]  got;
    reg [31:0] rd;
    integer    lerr;
    reg [7:0]  exp_buf [0:255];

    task report;
        input [256*8-1:0] msg;
        input            ok;
    begin
        if (ok) begin $display("[PASS] %0s", msg); pass_cnt = pass_cnt + 1; end
        else    begin $display("[FAIL] %0s", msg); err_cnt  = err_cnt  + 1; end
    end
    endtask

    //--------------------------------------------------------------- APB 任务
    task apb_write;
        input [15:0] a;
        input [31:0] d;
    begin
        @(posedge apb_clk);
        APB_PSEL=1; APB_PENABLE=0; APB_PWRITE=1; APB_PADDR=a; APB_PWDATA=d;
        @(posedge apb_clk);
        APB_PENABLE=1;
        @(posedge apb_clk);
        APB_PENABLE=0; APB_PSEL=0;
        @(posedge apb_clk);
    end
    endtask

    task apb_read;
        input  [15:0] a;
        output [31:0] d;
    begin
        @(posedge apb_clk);
        APB_PSEL=1; APB_PENABLE=0; APB_PWRITE=0; APB_PADDR=a;
        @(posedge apb_clk);
        APB_PENABLE=1;
        @(posedge apb_clk);                  // 访问边沿：PRDATA <= read_data (NBA 晚一拍生效)
        APB_PENABLE=0; APB_PSEL=0;
        @(posedge apb_clk);                  // NBA 已结算，PRDATA 稳定
        d = APB_PRDATA;
        @(posedge apb_clk);
    end
    endtask

    //--------------------------------------------------------------- GPIB 控者发送单字节
    // 假设 ATN 已由调用方设置；本任务仅完成三线握手
    task send_byte;
        input [7:0] b;
        integer tcnt;
    begin
        tcnt = 0;
        while (!(nrfd === 1'b1)) begin @(posedge sys_clk); tcnt=tcnt+1;
            if (tcnt>200000) begin $display("SEND_TIMEOUT wait nrfd=1 nrfd=%b ndac=%b dav=%b GPIB_State=%b AH=%b LACS=%b TACS=%b nrfdOut=%b ndacOut=%b",
                nrfd,ndac,dav,u_dut.GPIB_State,u_dut.GPIB_AH_State,u_dut.LACS,u_dut.TACS,u_dut.nrfdOut,u_dut.ndacOut); $finish; end
        end
        data_tb = ~b;                                  // DUT 采样 ~data
        @(posedge sys_clk);
        dav_tb  = 1'b0;                                // 断言 DAV(低有效)
        tcnt = 0;
        // 标准三线握手：保持 DAV 有效，直到受者真正锁存字节(AWNS, NDAC=1)
        while (!(ndac === 1'b1)) begin @(posedge sys_clk); tcnt=tcnt+1;
            if (tcnt>200000) begin $display("SEND_TIMEOUT wait ndac=1 nrfd=%b ndac=%b dav=%b AH=%b LADS=%b LState=%b infifo_w=%b",
                nrfd,ndac,dav,u_dut.GPIB_AH_State,u_dut.LADS,u_dut.GPIB_L_State,u_dut.GPIB_infifo_w); $finish; end
        end
        @(posedge sys_clk);
        dav_tb  = 1'b1;                                // 释放 DAV(高)
        tcnt = 0;
        // 等待受者 relinquish NDAC，回到就绪态(ACRS, NDAC=0)以便下一字节
        while (!(ndac === 1'b0)) begin @(posedge sys_clk); tcnt=tcnt+1;
            if (tcnt>200000) begin $display("SEND_TIMEOUT wait ndac=0 nrfd=%b ndac=%b dav=%b AH=%b nrfdOut=%b ndacOut=%b",
                nrfd,ndac,dav,u_dut.GPIB_AH_State,u_dut.nrfdOut,u_dut.ndacOut); $finish; end
        end
        data_tb = 8'bz;
    end
    endtask

    //--------------------------------------------------------------- GPIB 控者(监听) 接收单字节
    task recv_byte;
        output [7:0] b;
        integer tcnt;
    begin
        nrfd_tb = 1'b1; ndac_tb = 1'b0;                // 就绪(NRFD=1); NDAC 断言(=0)表未接收, 与 DUT ACRS 约定一致
        tcnt = 0;
        while (!(dav === 1'b0)) begin @(posedge sys_clk); tcnt=tcnt+1;
            if (tcnt>200000) begin $display("RECV_TIMEOUT wait dav=0 nrfd=%b ndac=%b dav=%b GPIB_State=%b SH=%b SGNS=%b SDYS=%b STRS=%b SWNS=%b davOut=%b",
                nrfd,ndac,dav,u_dut.GPIB_State,u_dut.GPIB_SH_State,u_dut.SGNS,u_dut.SDYS,u_dut.STRS,u_dut.SWNS,u_dut.davOut); $finish; end
        end
        b = ~data;                                     // DUT 发送 ~w
        nrfd_tb = 1'b0;                                // 不再就绪(忙)
        ndac_tb = 1'b1;                                // 释放 NDAC(=1)表已接收, 向讲者确认
        tcnt = 0;
        while (!(dav === 1'b1)) begin @(posedge sys_clk); tcnt=tcnt+1;
            if (tcnt>200000) begin $display("RECV_TIMEOUT wait dav=1 nrfd=%b ndac=%b dav=%b SH=%b SGNS=%b SDYS=%b STRS=%b SWNS=%b davOut=%b",
                nrfd,ndac,dav,u_dut.GPIB_SH_State,u_dut.SGNS,u_dut.SDYS,u_dut.STRS,u_dut.SWNS,u_dut.davOut); $finish; end
        end
        nrfd_tb = 1'b1; ndac_tb = 1'b0;                // 回到就绪/未接收, 准备下一字节
    end
    endtask

    task cleanup_host;
    begin
        host_src = 1'b0; host_lis = 1'b0;
        data_tb = 8'bz; dav_tb = 1'b1; nrfd_tb = 1'b1; ndac_tb = 1'b1;
        atn_tb = 1'b1; ren_tb = 1'b1;
    end
    endtask

    //--------------------------------------------------------------- 监听测试
    task test_listen;
        input integer N;
    begin
        lerr = 0;
        host_lis = 1'b0; ren_tb = 1'b0;
        atn_tb = 1'b0;                                  // 断言 ATN -> 控者寻址阶段
        // 等 DUT 经 32 级 atn_dly 同步后由讲者切回听者(GPIB_State=0),
        // 避免 TB 驱动 dav 与仍为讲者的 DUT 驱动 dav 发生总线竞争产生 X
        while (!(u_dut.GPIB_State === 1'b0)) @(posedge sys_clk);
        host_src = 1'b1;                                // 此刻 DUT 已为听者, 不再驱动 dav
        send_byte(8'h3F);   // UNL
        send_byte(8'h5F);   // UNT
        send_byte(8'h21);   // MLA (addr=1)
        atn_tb = 1'b1;      // 释放 ATN -> 数据阶段
        // ATN 经 32 级同步(atn_dly), 须等 DUT 真正进入 LACS 后再发数据, 否则前若干字节会因 LACS 未置位而未被写入 in-FIFO
        while (!(u_dut.LACS === 1'b1)) @(posedge sys_clk);
        for (i=0;i<N;i=i+1) begin exp_buf[i] = i[7:0]; send_byte(exp_buf[i]); end
        host_src = 1'b0; data_tb = 8'bz; dav_tb = 1'b1;
        #300;
        for (i=0;i<N;i=i+1) begin
            apb_read(16'h0018, rd);
            while (rd[2] === 1'b0) begin @(posedge sys_clk); apb_read(16'h0018, rd); end  // 轮询等待 in-FIFO 非空
            apb_read(16'h0010, rd);
            got = rd[7:0];
            if (got !== exp_buf[i]) begin $display("  listen mismatch idx=%0d exp=%02h got=%02h", i, exp_buf[i], got); lerr = lerr+1; end
        end
        cleanup_host;
        report("listen: N bytes received correctly", (lerr==0));
    end
    endtask

    //--------------------------------------------------------------- 讲者测试
    task test_talk;
        input integer N;
    begin
        lerr = 0;
        host_src = 1'b1; host_lis = 1'b0; ren_tb = 1'b0;
        atn_tb = 1'b0;
        send_byte(8'h3F);   // UNL
        send_byte(8'h5F);   // UNT
        send_byte(8'h41);   // MTA (addr=1)
        atn_tb = 1'b1;      // 释放 ATN -> 设备变为讲者
        host_src = 1'b0; data_tb = 8'bz; dav_tb = 1'b1;
        // 等 DUT 经 atn_dly 同步后成为讲者(TACS=1), 此时 DUT 不再驱动 nrfd/ndac,
        // 之后 TB 才以监听者身份驱动 nrfd/ndac, 避免总线竞争产生 X
        while (!(u_dut.TACS === 1'b1)) @(posedge sys_clk);
        // 先成为监听者但保持"未就绪"(NRFD=0), 使讲者在 SDYS 停等, 避免 APB 写 FIFO 期间数据已被发到总线却无人接收而造成字节错位
        host_lis = 1'b1; nrfd_tb = 1'b0; ndac_tb = 1'b0;
        for (i=0;i<N;i=i+1) begin exp_buf[i] = (i+100); apb_write(16'h0010, {24'd0, exp_buf[i]}); end
        for (i=0;i<N;i=i+1) begin recv_byte(got); if (got !== exp_buf[i]) begin $display("  talk mismatch idx=%0d exp=%02h got=%02h", i, exp_buf[i], got); lerr = lerr+1; end end
        cleanup_host;
        report("talk: N bytes sent correctly", (lerr==0));
    end
    endtask

    //--------------------------------------------------------------- 器件清除测试
    task test_clear;
    begin
        lerr = 0;
        host_lis = 1'b0; ren_tb = 1'b0;
        atn_tb = 1'b0;                                  // 断言 ATN
        // 等 DUT 切回听者(GPIB_State=0)后再驱动 dav, 避免与仍为讲者的 DUT 竞争
        while (!(u_dut.GPIB_State === 1'b0)) @(posedge sys_clk);
        host_src = 1'b1;
        // 注意：前一轮为讲者，TAD(讲地址锁存)仍为 1。须先发 UNL(3F)/UNT(5F) 清除讲/听地址，
        // 再发 MLA(21) 重新寻址为听者；否则 ATN 释放后 TAD&atn_dly 使设备重回讲者(TACS)、
        // 驱动 dav 而非进行听者握手，send_byte 会因 AH 停滞在 AIDS 而 SEND_TIMEOUT。
        send_byte(8'h3F); send_byte(8'h5F); send_byte(8'h21); atn_tb = 1'b1;
        while (!(u_dut.LACS === 1'b1)) @(posedge sys_clk);   // 等待 ATN 同步并进入 LACS
        send_byte(8'hAA); send_byte(8'hBB);
        host_src = 1'b0; data_tb = 8'bz; dav_tb = 1'b1;
        #300;
        apb_read(16'h0018, rd);
        if (rd[2] !== 1'b1) begin $display("  clear: infifo should be non-empty before IFC"); lerr = lerr+1; end
        ifc_tb = 1'b0; #300; ifc_tb = 1'b1; #300;   // 断言 IFC(低有效) 再释放
        apb_read(16'h0018, rd);
        if (rd[2] !== 1'b0) begin $display("  clear: infifo should be empty after IFC"); lerr = lerr+1; end
        cleanup_host;
        report("device clear: in-FIFO cleared by IFC", (lerr==0));
    end
    endtask

    //--------------------------------------------------------------- 主测试序列
    reg [31:0] rd_id;
    reg [31:0] rd_ctrl;
    initial begin
        sys_rstn = 1'b0; apb_preset = 1'b0;
        host_src = 1'b0; host_lis = 1'b0;
        data_tb = 8'bz; dav_tb = 1'b1; nrfd_tb = 1'b1; ndac_tb = 1'b1;
        atn_tb = 1'b1; ren_tb = 1'b1;
        #200;
        sys_rstn = 1'b1; apb_preset = 1'b1;
        #300;

        // 1) 寄存器默认/标识
        apb_read(16'h001C, rd_id); report("ID register == 0x21101312", (rd_id == 32'h21101312));
        apb_read(16'h0014, rd_ctrl); report("Ctrl default En==1, Addr==1", (rd_ctrl[0]==1'b1 && rd_ctrl[12:8]==5'd1));

        // 2) 监听
        test_listen(16);
        // 3) 讲者
        test_talk(16);
        // 4) CDC 压力：异步时钟下反复收发
        for (k=0;k<4;k=k+1) begin test_listen(8); test_talk(8); end
        // 5) 器件清除
        test_clear();

        #500;
        $display("\n==== SUMMARY: PASS=%0d  FAIL=%0d ====", pass_cnt, err_cnt);
        if (err_cnt == 0) $display("RESULT: ALL TESTS PASSED");
        else               $display("RESULT: SOME TESTS FAILED");
        $finish;
    end

    // 看门狗
    initial begin
        #20_000_000;
        $display("TIMEOUT: 仿真超时 (可能存在握手死锁)");
        $finish;
    end

    //--------------------------------------------------------------- DUT
    GPIBLite #(.INFO_RDY_DLY(8'd0)) u_dut (
        .sys_clk           (sys_clk),
        .sys_rstn          (sys_rstn),
        .APB_PCLK          (apb_clk),
        .APB_PRESET        (apb_preset),
        .APB_PADDR         (APB_PADDR),
        .APB_PENABLE       (APB_PENABLE),
        .APB_PWRITE        (APB_PWRITE),
        .APB_PSTRB         (4'b0),
        .APB_PPROT         (3'b0),
        .APB_PWDATA        (APB_PWDATA),
        .APB_PSEL          (APB_PSEL),
        .APB_PRDATA        (APB_PRDATA),
        .APB_PREADY        (APB_PREADY),
        .APB_PSLVERR       (APB_PSLVERR),
        .te_a              (te_a),
        .te_b              (te_b),
        .sc                (sc),
        .dc                (dc),
        .data              (data),
        .ifc               (ifc),
        .atn               (atn),
        .ren               (ren),
        .srq               (srq),
        .eoi               (eoi),
        .nrfd              (nrfd),
        .ndac              (ndac),
        .dav               (dav),
        .GPIB_infifo_empty (GPIB_infifo_empty)
    );

endmodule
