`timescale 1ns / 1ps

module lvds_bidirectional_tb;

localparam CLK_PERIOD = 10;
localparam DATA_WIDTH = 8;

reg clk_ref_master;
reg clk_ref_slave;
reg rst_n;

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

// LVDS互连信号
wire m2s_clk_p, m2s_clk_n, m2s_data_p, m2s_data_n;
wire s2m_clk_p, s2m_clk_n, s2m_data_p, s2m_data_n;

// 故障注入信号
reg link_m2s_disable;
reg link_s2m_disable;

// 比对队列
reg [7:0] mst_send_queue [$];
reg [7:0] slv_send_queue [$];
integer mst_err_cnt, slv_err_cnt;
integer test_pass, test_fail;

// 时钟与复位
initial begin
    clk_ref_master = 1'b0;
    clk_ref_slave  = 1'b0;
    fork
        forever #(CLK_PERIOD/2) clk_ref_master = ~clk_ref_master;
        forever #(CLK_PERIOD/2) clk_ref_slave  = ~clk_ref_slave;
    join
end

initial begin
    rst_n = 1'b0;
    #200;
    rst_n = 1'b1;
end

// 链路延迟与故障注入
wire m2s_data_p_dly, m2s_data_n_dly;
wire s2m_data_p_dly, s2m_data_n_dly;

assign #2.5 m2s_data_p_dly = m2s_data_p;
assign #2.5 m2s_data_n_dly = m2s_data_n;
assign #2.5 s2m_data_p_dly = s2m_data_p;
assign #2.5 s2m_data_n_dly = s2m_data_n;

assign m2s_data_p_final = link_m2s_disable ? 1'b0 : m2s_data_p_dly;
assign m2s_data_n_final = link_m2s_disable ? 1'b1 : m2s_data_n_dly;
assign s2m_data_p_final = link_s2m_disable ? 1'b0 : s2m_data_p_dly;
assign s2m_data_n_final = link_s2m_disable ? 1'b1 : s2m_data_n_dly;

// 主机DUT
lvds_bidirectional_top #(
    .IS_MASTER(1), .DATA_WIDTH(DATA_WIDTH)
) u_master (
    .clk_ref(clk_ref_master), .rst_n(rst_n),
    .tx_lvds_clk_p(m2s_clk_p), .tx_lvds_clk_n(m2s_clk_n),
    .tx_lvds_data_p(m2s_data_p), .tx_lvds_data_n(m2s_data_n),
    .rx_lvds_clk_p(s2m_clk_p), .rx_lvds_clk_n(s2m_clk_n),
    .rx_lvds_data_p(s2m_data_p_final), .rx_lvds_data_n(s2m_data_n_final),
    .user_tx_data(mst_tx_data), .user_tx_valid(mst_tx_valid), .user_tx_ready(mst_tx_ready),
    .user_rx_data(mst_rx_data), .user_rx_valid(mst_rx_valid),
    .ext_retrain_req(mst_ext_retrain),
    .link_all_up(mst_link_up), .heartbeat_err(mst_hb_err), .align_err(mst_align_err)
);

// 从机DUT
lvds_bidirectional_top #(
    .IS_MASTER(0), .DATA_WIDTH(DATA_WIDTH)
) u_slave (
    .clk_ref(clk_ref_slave), .rst_n(rst_n),
    .tx_lvds_clk_p(s2m_clk_p), .tx_lvds_clk_n(s2m_clk_n),
    .tx_lvds_data_p(s2m_data_p), .tx_lvds_data_n(s2m_data_n),
    .rx_lvds_clk_p(m2s_clk_p), .rx_lvds_clk_n(m2s_clk_n),
    .rx_lvds_data_p(m2s_data_p_final), .rx_lvds_data_n(m2s_data_n_final),
    .user_tx_data(slv_tx_data), .user_tx_valid(slv_tx_valid), .user_tx_ready(slv_tx_ready),
    .user_rx_data(slv_rx_data), .user_rx_valid(slv_rx_valid),
    .ext_retrain_req(1'b0),
    .link_all_up(slv_link_up), .heartbeat_err(slv_hb_err), .align_err(slv_align_err)
);

// 自动比对逻辑
always @(posedge clk_ref_slave) begin
    if(slv_rx_valid && slv_link_up) begin
        if(mst_send_queue.size() == 0) mst_err_cnt = mst_err_cnt + 1;
        else if(slv_rx_data !== mst_send_queue.pop_front()) mst_err_cnt = mst_err_cnt + 1;
    end
end

always @(posedge clk_ref_master) begin
    if(mst_rx_valid && mst_link_up) begin
        if(slv_send_queue.size() == 0) slv_err_cnt = slv_err_cnt + 1;
        else if(mst_rx_data !== slv_send_queue.pop_front()) slv_err_cnt = slv_err_cnt + 1;
    end
end

// 测试任务
task wait_both_link_up;
    begin
        $display("\n[%0t] 等待双向链路建链...", $time);
        wait(mst_link_up && slv_link_up);
        repeat(200) @(posedge clk_ref_master);
        $display("[%0t] 双向链路建链成功", $time);
    end
endtask

task send_master_data;
    input integer len;
    integer i;
    begin
        wait(mst_tx_ready);
        for(i = 0; i < len; i = i + 1) begin
            @(posedge clk_ref_master);
            mst_tx_valid = 1'b1;
            mst_tx_data = i[7:0];
            mst_send_queue.push_back(i[7:0]);
        end
        @(posedge clk_ref_master);
        mst_tx_valid = 1'b0;
    end
endtask

task send_slave_data;
    input integer len;
    integer i;
    begin
        wait(slv_tx_ready);
        for(i = 0; i < len; i = i + 1) begin
            @(posedge clk_ref_slave);
            slv_tx_valid = 1'b1;
            slv_tx_data = i[7:0];
            slv_send_queue.push_back(i[7:0]);
        end
        @(posedge clk_ref_slave);
        slv_tx_valid = 1'b0;
    end
endtask

// 主测试流程
initial begin
    mst_tx_data = 0; mst_tx_valid = 0;
    slv_tx_data = 0; slv_tx_valid = 0;
    link_m2s_disable = 0; link_s2m_disable = 0;
    mst_ext_retrain = 0;
    mst_err_cnt = 0; slv_err_cnt = 0;
    test_pass = 0; test_fail = 0;
    
    $display("==================================================");
    $display("  双向4路LVDS通信仿真测试开始");
    $display("==================================================");
    wait(rst_n);
    
    // 场景1：建链握手测试
    $display("\n--- 场景1：双向建链握手 ---");
    wait_both_link_up();
    if(mst_link_up && slv_link_up) begin
        $display("✓ 场景1通过");
        test_pass = test_pass + 1;
    end else begin
        $display("✗ 场景1失败");
        test_fail = test_fail + 1;
    end
    
    // 场景2：双向数据传输
    $display("\n--- 场景2：双向数据传输 ---");
    fork
        send_master_data(256);
        send_slave_data(256);
    join
    wait(mst_send_queue.size() == 0 && slv_send_queue.size() == 0);
    if(mst_err_cnt == 0 && slv_err_cnt == 0) begin
        $display("✓ 场景2通过：双向数据零错误");
        test_pass = test_pass + 1;
    end else begin
        $display("✗ 场景2失败");
        test_fail = test_fail + 1;
    end
    
    // 场景3：心跳混合传输
    $display("\n--- 场景3：心跳与数据混合 ---");
    #2000000;
    if(mst_hb_err == 0 && slv_hb_err == 0) begin
        $display("✓ 场景3通过：双向心跳正常");
        test_pass = test_pass + 1;
    end else begin
        $display("✗ 场景3失败");
        test_fail = test_fail + 1;
    end
    
    // 场景4：正向链路故障重训练
    $display("\n--- 场景4：正向链路故障重训练 ---");
    mst_err_cnt = 0;
    link_m2s_disable = 1'b1;
    wait(~slv_link_up);
    #10000;
    link_m2s_disable = 1'b0;
    wait_both_link_up();
    send_master_data(128);
    wait(mst_send_queue.size() == 0);
    if(mst_err_cnt == 0) begin
        $display("✓ 场景4通过：正向重训练恢复正常");
        test_pass = test_pass + 1;
    end else begin
        $display("✗ 场景4失败");
        test_fail = test_fail + 1;
    end
    
    // 场景5：反向链路故障重训练
    $display("\n--- 场景5：反向链路故障重训练 ---");
    slv_err_cnt = 0;
    link_s2m_disable = 1'b1;
    wait(~mst_link_up);
    #10000;
    link_s2m_disable = 1'b0;
    wait_both_link_up();
    send_slave_data(128);
    wait(slv_send_queue.size() == 0);
    if(slv_err_cnt == 0) begin
        $display("✓ 场景5通过：反向重训练恢复正常");
        test_pass = test_pass + 1;
    end else begin
        $display("✗ 场景5失败");
        test_fail = test_fail + 1;
    end
    
    // 场景6：外部强制重训练
    $display("\n--- 场景6：外部强制重训练 ---");
    mst_err_cnt = 0;
    @(posedge clk_ref_master);
    mst_ext_retrain = 1'b1;
    repeat(10) @(posedge clk_ref_master);
    mst_ext_retrain = 1'b0;
    wait_both_link_up();
    send_master_data(128);
    wait(mst_send_queue.size() == 0);
    if(mst_err_cnt == 0 && slv_err_cnt == 0) begin
        $display("✓ 场景6通过：外部重训练恢复正常");
        test_pass = test_pass + 1;
    end else begin
        $display("✗ 场景6失败");
        test_fail = test_fail + 1;
    end
    
    // 最终总结
    #10000;
    $display("\n\n==================================================");
    $display("  仿真测试结束");
    $display("  总用例：6 | 通过：%0d | 失败：%0d", test_pass, test_fail);
    if(test_fail == 0)