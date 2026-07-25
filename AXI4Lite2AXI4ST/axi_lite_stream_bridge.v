//============================================================================
// axi_lite_stream_bridge.v
// ----------------------------------------------------------------------------
// 顶层封装：axi4lite2axist + axist2native
// 修正版 V2（2026-07-25）
//============================================================================
module axi_lite_stream_bridge #(
    parameter C_S_AXI_DATA_WIDTH = 32,
    parameter C_S_AXI_ADDR_WIDTH = 32,
    parameter C_AXIS_DATA_WIDTH  = 32,
    parameter C_REG_NUM          = 4,
    parameter C_FIFO_DEPTH       = 4
)(
    input  wire                                 aclk,
    input  wire                                 aresetn,

    // AXI4-Lite Slave 接口
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]        s_axi_awaddr,
    input  wire [2:0]                           s_axi_awprot,
    input  wire                                 s_axi_awvalid,
    output wire                                 s_axi_awready,
    input  wire [C_S_AXI_DATA_WIDTH-1:0]        s_axi_wdata,
    input  wire [C_S_AXI_DATA_WIDTH/8-1:0]      s_axi_wstrb,
    input  wire                                 s_axi_wvalid,
    output wire                                 s_axi_wready,
    output wire [1:0]                           s_axi_bresp,
    output wire                                 s_axi_bvalid,
    input  wire                                 s_axi_bready,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]        s_axi_araddr,
    input  wire [2:0]                           s_axi_arprot,
    input  wire                                 s_axi_arvalid,
    output wire                                 s_axi_arready,
    output wire [C_S_AXI_DATA_WIDTH-1:0]        s_axi_rdata,
    output wire [1:0]                           s_axi_rresp,
    output wire                                 s_axi_rvalid,
    input  wire                                 s_axi_rready
);

    // 内部 Stream 互联
    wire [C_AXIS_DATA_WIDTH-1:0] axis_cmd_tdata;
    wire                         axis_cmd_tvalid;
    wire                         axis_cmd_tready;
    wire                         axis_cmd_tlast;

    wire [C_AXIS_DATA_WIDTH-1:0] axis_rsp_tdata;
    wire                         axis_rsp_tvalid;
    wire                         axis_rsp_tready;
    wire                         axis_rsp_tlast;

    axi4lite2axist #(
        .C_S_AXI_DATA_WIDTH (C_S_AXI_DATA_WIDTH),
        .C_S_AXI_ADDR_WIDTH (C_S_AXI_ADDR_WIDTH),
        .C_AXIS_DATA_WIDTH  (C_AXIS_DATA_WIDTH),
        .C_FIFO_DEPTH       (C_FIFO_DEPTH)
    ) u_axi4lite2axist (
        .aclk               (aclk),
        .aresetn            (aresetn),
        .s_axi_awaddr       (s_axi_awaddr),
        .s_axi_awprot       (s_axi_awprot),
        .s_axi_awvalid      (s_axi_awvalid),
        .s_axi_awready      (s_axi_awready),
        .s_axi_wdata        (s_axi_wdata),
        .s_axi_wstrb        (s_axi_wstrb),
        .s_axi_wvalid       (s_axi_wvalid),
        .s_axi_wready       (s_axi_wready),
        .s_axi_bresp        (s_axi_bresp),
        .s_axi_bvalid       (s_axi_bvalid),
        .s_axi_bready       (s_axi_bready),
        .s_axi_araddr       (s_axi_araddr),
        .s_axi_arprot       (s_axi_arprot),
        .s_axi_arvalid      (s_axi_arvalid),
        .s_axi_arready      (s_axi_arready),
        .s_axi_rdata        (s_axi_rdata),
        .s_axi_rresp        (s_axi_rresp),
        .s_axi_rvalid       (s_axi_rvalid),
        .s_axi_rready       (s_axi_rready),
        .m_axis_cmd_tdata   (axis_cmd_tdata),
        .m_axis_cmd_tvalid  (axis_cmd_tvalid),
        .m_axis_cmd_tlast   (axis_cmd_tlast),
        .m_axis_cmd_tready  (axis_cmd_tready),
        .s_axis_rsp_tdata   (axis_rsp_tdata),
        .s_axis_rsp_tvalid  (axis_rsp_tvalid),
        .s_axis_rsp_tlast   (axis_rsp_tlast),
        .s_axis_rsp_tready  (axis_rsp_tready)
    );

    axist2native #(
        .C_AXIS_DATA_WIDTH  (C_AXIS_DATA_WIDTH),
        .C_REG_NUM          (C_REG_NUM)
    ) u_axist2native (
        .aclk               (aclk),
        .aresetn            (aresetn),
        .s_axis_cmd_tdata   (axis_cmd_tdata),
        .s_axis_cmd_tvalid  (axis_cmd_tvalid),
        .s_axis_cmd_tlast   (axis_cmd_tlast),
        .s_axis_cmd_tready  (axis_cmd_tready),
        .m_axis_rsp_tdata   (axis_rsp_tdata),
        .m_axis_rsp_tvalid  (axis_rsp_tvalid),
        .m_axis_rsp_tlast   (axis_rsp_tlast),
        .m_axis_rsp_tready  (axis_rsp_tready)
    );

endmodule
