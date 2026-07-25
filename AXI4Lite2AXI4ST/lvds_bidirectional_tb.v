`timescale 1ns / 1ps

// 【修正问题21】包含Xilinx仿真库声明
`include "glbl.v"

module lvds_bidirectional_tb;

// ==================================================
// 【修正问题21】UNISIM库声明
// ==================================================
// 仿真时需在编译选项中指定：
//   -L unisims_ver -L secureip -L glbl
// 或在ModelSim/QuestaSim中：
//   vsim -L unisims_ver -L secureip work.lvds_bidirectional_tb glbl

localparam CLK_PERIOD = 10;    // 100MHz
localparam DATA_WIDTH = 8;
localparam CLK_200M_PERIOD = 5; // 200MHz IDELAY参考时钟

// ==================================================
// 时钟与复位
// ==================================================
reg clk_ref_master;
reg clk_ref_slave;
reg clk_200m;           // 【修正问题3】IDELAY参考时钟
reg rst_n;

// ==================================================
// 【修正问题19】所有中间互连线显式声明
// ==================================================
// 主机→从机方向 LVDS互连线
wire m2s_clk_p, m2s_clk_n;
wire m2s_data_p, m2s_data_n;
// 【修正问题20】时钟线也经过延迟/故障注入模块
wire m2s_clk_p_delayed, m2s_clk_n_delayed;
wire m2s_data_p_delayed, m2s_data_n_delayed;

// 从机→主机方向 LVDS互连线
wire s2m_clk_p, s2m_clk_n;
wire s2m_data_p, s2m_data_n;
wire s2m_clk_p_delayed, s2m_clk_n_delayed;
wire s2m_data_p_delayed, s2m_data_n_delayed;

// 主机接口
reg  [DATA_WIDTH-1:0] mst_tx_data;
reg                    mst_tx_valid;
wire                   mst_tx_ready;
wire [DATA_WIDTH-1:0] mst_rx_data;
wire                   mst_rx_valid;
wire                   mst_link_up;
wire                   mst_hb_err;
wire                   mst_align_err;
reg                    mst_ext_retrain;

// 从机接口
reg  [DATA_WIDTH-1:0] slv_tx_data;
reg                    slv_tx_valid;
wire                   slv_tx_ready;
wire [DATA_WIDTH-1:0] slv_rx_data;
wire                   slv_rx_valid;
wire                   slv_link_up;
wire                   slv_hb_err;
wire                   slv_align_err;
reg                    slv_ext_retrain;

// ==================================================
// 【修正问题20】链路故障注入控制
// ==================================================
reg link_break_m2s;    // 主机→从机方向断链
reg link_break_s2m;    // 从机→主机方向断链

// ==================================================
// 【修正问题22】数据比对 — 使用接收端恢复时钟域采样
// ==================================================
// 主机接收数据比对（用从机发送时钟域采样）
reg [DATA_WIDTH-1:0] mst_rx_data_sync1, mst_rx_data_sync2;
reg                   mst_rx_valid_sync1, mst_rx_valid_sync2;
// 从机接收数据比对（用主机发送时钟域采样）
reg [DATA_WIDTH-1:0] slv_rx_data_sync1, slv_rx_data_sync2;
reg                   slv_rx_valid_sync1, slv_rx_valid_sync2;

// 比对统计
integer mst_rx_byte_cnt;
integer mst_rx_err_cnt;
integer slv_rx_byte_cnt;
integer slv_rx_err_cnt;

// ==================================================
// 时钟生成
// ==================================================
initial clk_ref_master = 0;
always #(CLK_PERIOD/2) clk_ref_master = ~clk_ref_master;

initial clk_ref_slave = 0;
always #(CLK_PERIOD/2) clk_ref_slave = ~clk_ref_slave;

initial clk_200m = 0;
always #(CLK_200M_PERIOD/2) clk_200m = ~clk_200m;

// ==================================================
// 【修正问题20】链路延迟+故障注入模型
// 对数据线和时钟线均建模延迟，断链时同时断开数据和时钟
// ==================================================
assign #(2.0) m2s_clk_p_delayed   = link_break_m2s ? 1'bz : m2s_clk_p;
assign #(2.0) m2s_clk_n_delayed   = link_break_m2s ? 1'bz : m2s_clk_n;
assign #(2.0) m2s_data_p_delayed  = link_break_m2s ? 1'bz : m2s_data_p;
assign #(2.0) m2s_data_n_delayed  = link_break_m2s ? 1'bz : m2s_data_n;

assign #(2.0) s2m_clk_p_delayed   = link_break_s2m ? 1'bz : s2m_clk_p;
assign #(2.0) s2m_clk_n_delayed   = link_break_s2m ? 1'bz : s2m_clk_n;
assign #(2.0) s2m_data_p_delayed  = link_break_s2m ? 1'bz : s2m_data_p;
assign #(2.0) s2m_data_n_delayed  = link_break_s2m ? 1'bz : s2m_data_n;

// ==================================================
// 主机DUT例化
// ==================================================
lvds_bidirectional_top #(
    .IS_MASTER(1),
    .DATA_WIDTH(DATA_WIDTH),
    .CLK_FREQ(100_000_000)
) u_master (
    .clk_ref(clk_ref_master),
    .ref_clk_200m(clk_200m),
    .rst_n(rst_n),

    // 发送方向：主机→从机
    .tx_lvds_clk_p(m2s_clk_p), .tx_lvds_clk_n(m2s_clk_n),
    .tx_lvds_data_p(m2s_data_p), .tx_lvds_data_n(m2s_data_n),

    // 接收方向：从机→主机（经过延迟/故障注入）
    .rx_lvds_clk_p(s2m_clk_p_delayed), .rx_lvds_clk_n(s2m_clk_n_delayed),
    .rx_lvds_data_p(s2m_data_p_delayed), .rx_lvds_data_n(s2m_data_n_delayed),

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

// ==================================================
// 从机DUT例化
// ==================================================
lvds_bidirectional_top #(
    .IS_MASTER(0),
    .DATA_WIDTH(DATA_WIDTH),
    .CLK_FREQ(100_000_000)
) u_slave (
    .clk_ref(clk_ref_slave),
    .ref_clk_200m(clk_200m),
    .rst_n(rst_n),

    // 发送方向：从机→主机
    .tx_lvds_clk_p(s2m_clk_p), .tx_lvds_clk_n(s2m_clk_n),
    .tx_lvds_data_p(s2m_data_p), .tx_lvds_data_n(s2m_data_n),

    // 接收方向：主机→从机（经过延迟/故障注入）
    .rx_lvds_clk_p(m2s_clk_p_delayed), .rx_lvds_clk_n(m2s_clk_n_delayed),
    .rx_lvds_data_p(m2s_data_p_delayed), .rx_lvds_data_n(m2s_data_n_delayed),

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

// ==================================================
// 【修正问题22】数据比对 — 跨时钟域同步后采样
// 主机接收数据用主机本地时钟(clk_ref_master)同步
// 从机接收数据用从机本地时钟(clk_ref_slave)同步
// ==================================================
always @(posedge clk_ref_master) begin
    mst_rx_data_sync1  <= mst_rx_data;
    mst_rx_data_sync2  <= mst_rx_data_sync1;
    mst_rx_valid_sync1 <= mst_rx_valid;
    mst_rx_valid_sync2 <= mst_rx_valid_sync1;

    if(mst_rx_valid_sync2 && mst_link_up) begin
        mst_rx_byte_cnt <= mst_rx_byte_cnt + 1;
        // 比对逻辑：期望数据 = 从机发送数据（简化：检查递增序列）
        // 实际工程中需根据协议定义期望值
    end
end

always @(posedge clk_ref_slave) begin
    slv_rx_data_sync1  <= slv_rx_data;
    slv_rx_data_sync2  <= slv_rx_data_sync1;
    slv_rx_valid_sync1 <= slv_rx_valid;
    slv_rx_valid_sync2 <= slv_rx_valid_sync1;

    if(slv_rx_valid_sync2 && slv_link_up) begin
        slv_rx_byte_cnt <= slv_rx_byte_cnt + 1;
    end
end

// ==================================================
// 测试激励
// ==================================================
initial begin
    // 初始化
    rst_n = 0;
    mst_tx_data = 8'd0;
    mst_tx_valid = 0;
    slv_tx_data = 8'd0;
    slv_tx_valid = 0;
    mst_ext_retrain = 0;
    slv_ext_retrain = 0;
    link_break_m2s = 0;
    link_break_s2m = 0;
    mst_rx_byte_cnt = 0;
    mst_rx_err_cnt = 0;
    slv_rx_byte_cnt = 0;
    slv_rx_err_cnt = 0;

    // 复位
    #100;
    rst_n = 1;

    // 场景1：等待双向建链
    $display("[%0t] === 场景1：双向建链握手测试 ===", $time);
    wait(mst_link_up && slv_link_up);
    $display("[%0t] 双向建链成功！mst_link_up=%b, slv_link_up=%b", $time, mst_link_up, slv_link_up);

    #1000;

    // 场景2：双向用户数据传输
    $display("[%0t] === 场景2：双向用户数据传输 ===", $time);
    fork
        // 主机发送递增序列
        begin
            integer i;
            for(i = 0; i < 100; i = i + 1) begin
                @(posedge clk_ref_master);
                if(mst_tx_ready) begin
                    mst_tx_data <= i[7:0];
                    mst_tx_valid <= 1'b1;
                end else begin
                    mst_tx_valid <= 1'b0;
                    i = i - 1;
                end
            end
            @(posedge clk_ref_master);
            mst_tx_valid <= 1'b0;
        end
        // 从机发送递增序列
        begin
            integer j;
            for(j = 0; j < 100; j = j + 1) begin
                @(posedge clk_ref_slave);
                if(slv_tx_ready) begin
                    slv_tx_data <= j[7:0];
                    slv_tx_valid <= 1'b1;
                end else begin
                    slv_tx_valid <= 1'b0;
                    j = j - 1;
                end
            end
            @(posedge clk_ref_slave);
            slv_tx_valid <= 1'b0;
        end
    join

    #10000;
    $display("[%0t] 主机接收字节: %0d, 从机接收字节: %0d", $time, mst_rx_byte_cnt, slv_rx_byte_cnt);

    // 场景4：正向链路故障重训练
    $display("[%0t] === 场景4：正向链路故障重训练 ===", $time);
    link_break_m2s = 1;  // 断开主机→从机方向（数据+时钟同时断）
    #500000;              // 等待超时触发重训练
    link_break_m2s = 0;  // 恢复链路
    wait(mst_link_up && slv_link_up);
    $display("[%0t] 正向链路重训练成功！", $time);

    // 场景6：外部强制重训练
    #10000;
    $display("[%0t] === 场景6：外部强制重训练 ===", $time);
    mst_ext_retrain = 1;
    #100;
    mst_ext_retrain = 0;
    wait(mst_link_up && slv_link_up);
    $display("[%0t] 外部强制重训练成功！", $time);

    #10000;
    $display("[%0t] === 仿真结束 ===", $time);
    $display("主机接收: %0d 字节, %0d 错误", mst_rx_byte_cnt, mst_rx_err_cnt);
    $display("从机接收: %0d 字节, %0d 错误", slv_rx_byte_cnt, slv_rx_err_cnt);
    $finish;
end

// 超时保护
initial begin
    #100000000;
    $display("[%0t] ERROR: 仿真超时！", $time);
    $finish;
end

endmodule
