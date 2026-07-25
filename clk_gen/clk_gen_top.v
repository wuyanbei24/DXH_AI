`timescale 1ns / 1ps

module clk_gen_top(
    input i_fpga_ref_clk_50m,
    
    // output clock
    output o_clk_200m,      // 200MHz
    output o_clk_125m,      // 125MHz
    output o_clk_125m_90d,  // 125MHz (90°相移)
    output o_clk_100m,      // 100MHz
    output o_clk_50m,       // 50MHz
    output o_clk_400m,      // 400MHz
    output o_clk_10m,       // 10MHz
    output o_reset          // 全局复位信号（高有效，10MHz同步后，BUFG驱动）
);

//===================== 内部信号声明 =====================
wire mmcm_locked;          // MMCM原始锁定信号
wire reset_internal;       // BUFG输入的复位信号

//----------------------------------------------------------------------------
// User entered comments
//----------------------------------------------------------------------------
// None
//
//----------------------------------------------------------------------------
//  Output     Output      Phase    Duty Cycle   Pk-to-Pk     Phase
//   Clock     Freq (MHz)  (degrees)    (%)     Jitter (ps)  Error (ps)
//----------------------------------------------------------------------------
// clk_out1___400.000______0.000______50.0______126.902____164.985
// clk_out2___125.000______0.000______50.0______154.207____164.985
// clk_out3___125.000_____90.000______50.0______154.207____164.985
// clk_out4___100.000______0.000______50.0______162.035____164.985
// clk_out5____50.000______0.000______50.0______192.113____164.985
// clk_out6___200.000______0.000______50.0______142.107____164.985
// clk_out7____10.000______0.000______50.0______285.743____164.985
//
//----------------------------------------------------------------------------
// Input Clock   Freq (MHz)    Input Jitter (UI)
//----------------------------------------------------------------------------
// __primary__________50.000____________0.010

//----------- Begin Cut here for INSTANTIATION Template ---// INST_TAG

mfpga_clk_ip inst_mfpga_clk_ip
(
    // Clock out ports
    .clk_out1(o_clk_400m),       // 400MHz
    .clk_out2(o_clk_125m),       // 125MHz
    .clk_out3(o_clk_125m_90d),   // 125MHz (90°相移)
    .clk_out4(o_clk_100m),       // 100MHz
    .clk_out5(o_clk_50m),        // 50MHz
    .clk_out6(o_clk_200m),       // 200MHz
    .clk_out7(o_clk_10m),        // 10MHz
    // Status and control signals
    .locked(mmcm_locked),        // MMCM原始锁定信号
    // Clock in ports
    .clk_in1(i_fpga_ref_clk_50m) // 50MHz参考时钟
);
// INST_TAG_END ------ End INSTANTIATION Template ---------

//===================== 全局复位同步 =====================
// 将MMCM locked信号通过10MHz时钟同步，作为全局复位信号
// 采用3级同步器，高电平复位，异步复位同步释放
// reset = 1: 复位有效（MMCM未锁定）
// reset = 0: 复位释放（MMCM已锁定）
reg [2:0] locked_sync;

always @(posedge o_clk_10m or negedge mmcm_locked) begin
    if(!mmcm_locked)
        locked_sync <= 3'b111;      // MMCM未锁定，复位有效（高电平）
    else
        locked_sync <= {locked_sync[1:0], 1'b0};  // MMCM锁定，复位释放（移入0）
end

assign reset_internal = locked_sync[2];

//===================== BUFG驱动全局复位 =====================
// 使用BUFG驱动复位信号，实现低偏斜全局分布
BUFG u_bufg_reset(
    .I(reset_internal),
    .O(o_reset)
);

endmodule