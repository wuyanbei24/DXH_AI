`timescale 1ns / 1ps
`include "glbl.v"

//============================================================================
// Module: lvds_1lane_bidirectional_tb
// Description: LANE_CNT=1 验证 Testbench (隔离子目录, 编译 ../*.v 参数化RTL)
//   - 与 lvds_3lane_bidirectional_tb 同构, 仅 LANE_CNT=1
//   - 目的: 验证"LANE_CNT可参数化"补丁使单通道配置真正可用
//     (V13原设计在LANE_CNT=1下: SOF并行比较失效→永不建链; 帧头/校验和/心跳硬编码3路→错乱)
//   - force旁路: 仅单路 iserdes_q = mst_tx_data_delayed[7:0]
//   - 写循环: mst_tx_data <= i[7:0]; 统计按 *LANE_CNT(=1)
// Source: 基于 lvds_3lane_bidirectional_tb.v (V13) 改写
//============================================================================
module lvds_1lane_bidirectional_tb;

// 参数定义
localparam CLK_REF_50M    = 20;    // 100MHz
localparam CLK_REF_PERIOD = 10;    // 100MHz
localparam CLK_SER_PERIOD = 2.5;   // 400MHz
localparam CLK_200M_PERIOD = 5;   // 200MHz
localparam DATA_WIDTH = 8;
localparam LANE_CNT = 1;           // [LANE_CNT=1] 单通道验证

// 时钟与复位
wire clk_ref_master;
wire clk_ref_slave ;
reg clk_ser_master;
reg clk_ser_slave ;
reg clk_div_master;
reg clk_div_slave ;
reg clk_200m      ;
reg rst_n = 1'b0;

// LVDS互连线
wire m2s_clk_p, m2s_clk_n;
wire [LANE_CNT-1:0] m2s_data_p, m2s_data_n;
wire m2s_clk_p_del, m2s_clk_n_del;
wire [LANE_CNT-1:0] m2s_data_p_del, m2s_data_n_del;

wire s2m_clk_p, s2m_clk_n;
wire [LANE_CNT-1:0] s2m_data_p, s2m_data_n;
wire s2m_clk_p_del, s2m_clk_n_del;
wire [LANE_CNT-1:0] s2m_data_p_del, s2m_data_n_del;

// 主机接口
reg  [LANE_CNT*DATA_WIDTH-1:0] mst_tx_data;
reg                            mst_tx_valid;
wire                           mst_tx_ready;
wire [LANE_CNT*DATA_WIDTH-1:0] mst_rx_data;
wire                           mst_rx_valid;
wire                           mst_link_up;
wire                           mst_hb_err;
wire                           mst_align_err;
reg                            mst_ext_retrain;

// 从机接口
reg  [LANE_CNT*DATA_WIDTH-1:0] slv_tx_data;
reg                            slv_tx_valid;
wire                           slv_tx_ready;
wire [LANE_CNT*DATA_WIDTH-1:0] slv_rx_data;
wire                           slv_rx_valid;
wire                           slv_link_up;
wire                           slv_hb_err;
wire                           slv_align_err;
reg                            slv_ext_retrain;

// 故障注入控制
reg link_break_m2s;
reg link_break_s2m;

// 数据比对与统计
integer mst_rx_byte_cnt;
integer mst_rx_err_cnt;
integer slv_rx_byte_cnt;
integer slv_rx_err_cnt;
reg [LANE_CNT*DATA_WIDTH-1:0] mst_expect_data;
reg [LANE_CNT*DATA_WIDTH-1:0] slv_expect_data;

// ==========================
// 时钟生成
// ==========================
initial clk_ser_master = 0;
always #(CLK_SER_PERIOD/2) clk_ser_master = ~clk_ser_master;

initial clk_ser_slave = 0;
always #(CLK_SER_PERIOD/2) clk_ser_slave = ~clk_ser_slave;

initial clk_div_master = 0;
always #(CLK_REF_PERIOD/2) clk_div_master = ~clk_div_master;

initial clk_div_slave = 0;
always #(CLK_REF_PERIOD/2) clk_div_slave = ~clk_div_slave;

initial clk_200m = 0;
always #(CLK_200M_PERIOD/2) clk_200m = ~clk_200m;

reg fpga_ref_clk;
initial fpga_ref_clk = 0;
always #(CLK_REF_50M/2) fpga_ref_clk = ~fpga_ref_clk;

wire clk_out1_400   ;
wire clk_out2_125   ;
wire clk_out3_125   ;
wire clk_out4_100   ;
wire clk_out5_50    ;
wire clk_out6_200   ;
wire clk_out7_10    ;

assign  clk_ref_master = clk_out6_200;
assign  clk_ref_slave  = clk_out6_200;

mfpga_clk_ip mfpga_clk_ip
 (
  // Clock out ports
    .clk_out1(clk_out1_400   ),
    .clk_out2(clk_out2_125   ),
    .clk_out3(clk_out3_125   ),
    .clk_out4(clk_out4_100   ),
    .clk_out5(clk_out5_50    ),
    .clk_out6(clk_out6_200   ),
    .clk_out7(clk_out7_10    ),
  // Status and control signals
    .locked(),
 // Clock in ports
    .clk_in1(fpga_ref_clk)
 );

// ==========================
// 链路延迟与故障注入模型 ([LANE_CNT=1] 单路)
// ==========================
generate
    genvar lane;
    for(lane = 0; lane < LANE_CNT; lane = lane + 1) begin : gen_m2s_delay
        assign  m2s_data_p_del[lane] = link_break_m2s ? 1'bz : m2s_data_p[lane];
        assign  m2s_data_n_del[lane] = link_break_m2s ? 1'bz : m2s_data_n[lane];
    end
endgenerate

assign #(2.0) s2m_clk_p_del =  s2m_clk_p;
assign #(2.0) s2m_clk_n_del =  s2m_clk_n;

generate
    for(lane = 0; lane < LANE_CNT; lane = lane + 1) begin : gen_s2m_delay
        assign   s2m_data_p_del[lane] = link_break_s2m ? 1'bz : s2m_data_p[lane];
        assign   s2m_data_n_del[lane] = link_break_s2m ? 1'bz : s2m_data_n[lane];
    end
endgenerate

// ==========================
// 主机DUT例化 ([LANE_CNT=1])
// ==========================
lvds_bidirectional_top #(
    .IS_MASTER(1),
    .DATA_WIDTH(DATA_WIDTH),
    .LANE_CNT(LANE_CNT),
    .CLK_FREQ(100_000_000),
    .SIM_BYPASS(1)
) u_master (
    .clk_ref(clk_ref_master),
    .ref_clk_200m(clk_out6_200),
    .rst_n(rst_n),
    .clk_ser(clk_out1_400),
    .clk_div(clk_out4_100),
    .tx_lvds_clk_p(m2s_clk_p), .tx_lvds_clk_n(m2s_clk_n),
    .tx_lvds_data_p(m2s_data_p), .tx_lvds_data_n(m2s_data_n),
    .rx_lvds_clk_p(s2m_clk_p), .rx_lvds_clk_n(s2m_clk_n),
    .rx_lvds_data_p(s2m_data_p), .rx_lvds_data_n(s2m_data_n),
    .user_tx_data(mst_tx_data),
    .user_tx_valid(mst_tx_valid),
    .user_tx_ready(mst_tx_ready),
    .user_rx_data(mst_rx_data),
    .user_rx_valid(mst_rx_valid),
    .ext_retrain_req(mst_ext_retrain),
    .link_all_up(mst_link_up),
    .heartbeat_err(mst_hb_err),
    .align_err(mst_align_err)
);

// ==========================
// 从机DUT例化 ([LANE_CNT=1])
// ==========================
lvds_bidirectional_top #(
    .IS_MASTER(0),
    .DATA_WIDTH(DATA_WIDTH),
    .LANE_CNT(LANE_CNT),
    .CLK_FREQ(100_000_000),
    .SIM_BYPASS(1)
) u_slave (
    .clk_ref(clk_ref_slave),
    .ref_clk_200m(clk_out6_200),
    .rst_n(rst_n),
    .clk_ser(clk_out1_400),
    .clk_div(clk_out4_100),
    .tx_lvds_clk_p(s2m_clk_p),
    .tx_lvds_clk_n(s2m_clk_n),
    .tx_lvds_data_p(s2m_data_p),
    .tx_lvds_data_n(s2m_data_n),
    .rx_lvds_clk_p(m2s_clk_p), .rx_lvds_clk_n(m2s_clk_n),
    .rx_lvds_data_p(m2s_data_p), .rx_lvds_data_n(m2s_data_n),
    .user_tx_data(slv_tx_data),
    .user_tx_valid(slv_tx_valid),
    .user_tx_ready(slv_tx_ready),
    .user_rx_data(slv_rx_data),
    .user_rx_valid(slv_rx_valid),
    .ext_retrain_req(slv_ext_retrain),
    .link_all_up(slv_link_up),
    .heartbeat_err(slv_hb_err),
    .align_err(slv_align_err)
);

// ==========================
// SERDES旁路 (单路) — 直接注入TX并行数据到RX ISERDESE2输出
// [LANE_CNT=1] 仅force gen_rx_lanes[0]
// ==========================
reg [LANE_CNT*DATA_WIDTH-1:0] mst_tx_data_delayed;
reg [LANE_CNT*DATA_WIDTH-1:0] slv_tx_data_delayed;

always @(negedge clk_out4_100) begin
    mst_tx_data_delayed <= u_master.u_tx.tx_data_mux;
    slv_tx_data_delayed <= u_slave.u_tx.tx_data_mux;
end

initial begin
    #1;
    // Master TX -> Slave RX (单路)
    force u_slave.u_rx.u_phy.gen_rx_lanes[0].u_lane_phy.iserdes_q = mst_tx_data_delayed[7:0];
    // Slave TX -> Master RX (单路)
    force u_master.u_rx.u_phy.gen_rx_lanes[0].u_lane_phy.iserdes_q = slv_tx_data_delayed[7:0];
end

always @(posedge clk_out4_100 or negedge rst_n) begin
    if(!rst_n) begin
        slv_rx_byte_cnt <= 0;
        slv_rx_err_cnt <= 0;
        slv_expect_data <= {LANE_CNT*DATA_WIDTH{1'b0}};
    end else if(slv_rx_valid && slv_link_up) begin
        slv_rx_byte_cnt <= slv_rx_byte_cnt + 1;
        if(slv_rx_data != slv_expect_data) begin
            slv_rx_err_cnt <= slv_rx_err_cnt + 1;
            $display("[%0t] ERROR: Slave RX data mismatch! expected=%h, got=%h", $time, slv_expect_data, slv_rx_data);
        end
        slv_expect_data <= slv_expect_data + 1'b1;
    end
end

always @(posedge clk_out4_100 or negedge rst_n) begin
    if(!rst_n) begin
        mst_rx_byte_cnt <= 0;
        mst_rx_err_cnt <= 0;
        mst_expect_data <= {LANE_CNT*DATA_WIDTH{1'b0}};
    end else if(mst_rx_valid && mst_link_up) begin
        mst_rx_byte_cnt <= mst_rx_byte_cnt + 1;
        if(mst_rx_data != mst_expect_data) begin
            mst_rx_err_cnt <= mst_rx_err_cnt + 1;
            $display("[%0t] ERROR: Master RX data mismatch! expected=%h, got=%h", $time, mst_expect_data, mst_rx_data);
        end
        mst_expect_data <= mst_expect_data + 1'b1;
    end
end

// ==========================
// 测试激励 (同构V13, LANE_CNT=1)
// ==========================
initial begin
    rst_n = 0;
    mst_tx_data = {LANE_CNT*DATA_WIDTH{1'b0}};
    mst_tx_valid = 0;
    slv_tx_data = {LANE_CNT*DATA_WIDTH{1'b0}};
    slv_tx_valid = 0;
    mst_ext_retrain = 0;
    slv_ext_retrain = 0;
    link_break_m2s = 0;
    link_break_s2m = 0;
    mst_rx_byte_cnt = 0;
    mst_rx_err_cnt = 0;
    slv_rx_byte_cnt = 0;
    slv_rx_err_cnt = 0;

    #3020;
    rst_n = 1;

    // 场景1：双向建链握手测试
    $display("[%0t] === Scenario 1: Bidirectional link handshake test (LANE_CNT=1) ===", $time);
    wait(mst_link_up && slv_link_up);
    $display("[%0t] Bidirectional link established! mst_link_up=%b, slv_link_up=%b", $time, mst_link_up, slv_link_up);
    #2000;

    // 场景2：双向用户数据传输
    $display("[%0t] === Scenario 2: Bidirectional user data transfer (LANE_CNT=1) ===", $time);
    fork
        begin : master_tx
            integer i;
            for(i = 0; i < 200; i = i + 1) begin
                @(posedge clk_out4_100);
                if(mst_tx_ready) begin
                    mst_tx_data <= i[7:0];   // [LANE_CNT=1] 单字节
                    mst_tx_valid <= 1'b1;
                end else begin
                    mst_tx_valid <= 1'b0;
                    i = i - 1;
                end
            end
            @(posedge clk_out4_100);
            mst_tx_valid <= 1'b0;
        end
        begin : slave_tx
            integer j;
            for(j = 0; j < 200; j = j + 1) begin
                @(posedge clk_out4_100);
                if(slv_tx_ready) begin
                    slv_tx_data <= j[7:0];   // [LANE_CNT=1] 单字节
                    slv_tx_valid <= 1'b1;
                end else begin
                    slv_tx_valid <= 1'b0;
                    j = j - 1;
                end
            end
            @(posedge clk_out4_100);
            slv_tx_valid <= 1'b0;
        end
    join
    #20000;
    $display("[%0t] Master RX bytes: %0d, errors: %0d", $time, mst_rx_byte_cnt*LANE_CNT, mst_rx_err_cnt);
    $display("[%0t] Slave RX bytes: %0d, errors: %0d", $time, slv_rx_byte_cnt*LANE_CNT, slv_rx_err_cnt);

    // 场景3：通道偏移对齐测试 (单路无偏移, 仅验证重训练握手不卡死)
    $display("[%0t] === Scenario 3: retrain handshake (LANE_CNT=1) ===", $time);
    mst_ext_retrain = 1;
    slv_ext_retrain = 1;
    #50000;
    mst_ext_retrain = 0;
    slv_ext_retrain = 0;
    wait(mst_link_up && slv_link_up);
    $display("[%0t] Link re-established after retrain! (LANE_CNT=1)", $time);
    #10000;

    // 场景4：正向链路故障重训练 (force旁路下为no-op, 验证不卡死)
    $display("[%0t] === Scenario 4: Forward link fault retrain (LANE_CNT=1) ===", $time);
    link_break_m2s = 1;
    #500000;
    link_break_m2s = 0;
    wait(mst_link_up && slv_link_up);
    $display("[%0t] Forward link retrain recovery success! (LANE_CNT=1)", $time);
    #10000;

    // 场景5：外部强制重训练
    $display("[%0t] === Scenario 5: External force retrain (LANE_CNT=1) ===", $time);
    mst_ext_retrain = 1;
    slv_ext_retrain = 1;
    #50000;
    mst_ext_retrain = 0;
    slv_ext_retrain = 0;
    wait(mst_link_up && slv_link_up);
    $display("[%0t] External force retrain success! (LANE_CNT=1)", $time);
    #10000;

    // 仿真结束
    $display("[%0t] === All test scenarios completed (LANE_CNT=1) ===", $time);
    $display("Final statistics:");
    $display("Master RX: %0d bytes, %0d errors", mst_rx_byte_cnt*LANE_CNT, mst_rx_err_cnt);
    $display("Slave RX: %0d bytes, %0d errors", slv_rx_byte_cnt*LANE_CNT, slv_rx_err_cnt);
    if(mst_rx_err_cnt == 0 && slv_rx_err_cnt == 0) begin
        $display("Test result: PASS");
    end else begin
        $display("Test result: FAIL");
    end
    $finish;
end

// [DEBUG] 诊断: 每10us采样主/从PHY状态、deskew、link_up, 定位LANE_CNT=1建链卡点
integer mst_clk_edge_cnt;
initial mst_clk_edge_cnt = 0;
always @(posedge clk_out4_100) mst_clk_edge_cnt <= mst_clk_edge_cnt + 1;
initial begin : dbg_loop
    integer dbg_k;
    for(dbg_k = 0; dbg_k < 22; dbg_k = dbg_k + 1) begin
        #10000;
        $display("[%0t] DBG clk_edges=%0d c4=%b c6=%b ref=%b mst_phy=%0d slv_phy=%0d mst_desk=%b mst_rdy=%b mst_lu=%b mst_dout=%h",
            $time,
            mst_clk_edge_cnt,
            clk_out4_100, clk_out6_200, fpga_ref_clk,
            u_master.u_rx.u_phy.m_curr_state,
            u_slave.u_rx.u_phy.m_curr_state,
            u_master.u_rx.u_phy.u_lane_deskew.deskew_done,
            u_slave.u_rx.u_phy.u_lane_deskew.deskew_done,
            u_master.u_rx.u_phy.phy_ready,
            u_slave.u_rx.u_phy.phy_ready,
            mst_link_up, slv_link_up,
            u_master.u_rx.u_phy.u_lane_deskew.data_out,
            u_slave.u_rx.u_phy.u_lane_deskew.data_out);
    end
end

// 超时保护
initial begin
    #200000000;
    $display("[%0t] ERROR: Simulation timeout! (LANE_CNT=1)", $time);
    $finish;
end

endmodule
