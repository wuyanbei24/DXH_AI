//=========================================================
// 模块名称：dio_reg_map
// 功能：AXI4-Lite动态配置16位DIO任意比特映射
// 1. 支持PS通过AXI4-Lite实时配置每一路输出对应的输入比特
// 2. 所有映射通路寄存器打拍输出，无组合逻辑毛刺
// 3. 标准AXI4-Lite Slave接口，适配Zynq7020 PS-PL交互
// 平台：Zynq7020  Vivado2018.3
// 作者：RTL自动生成
// 日期：2026
//=========================================================
module dio_reg_map
(
    // 全局时钟、复位（AXI总线与逻辑共用时钟）
    input  wire         clk,
    input  wire         rst_n,

    // 16位DIO输入输出端口
    input  wire [15:0]  i_dio,
    output wire [15:0]  o_dio,

    //==================== 标准AXI4-Lite Slave 接口 ====================
    // 写地址通道
    input  wire [31:0]  s_axi_awaddr,
    input  wire         s_axi_awvalid,
    output wire         s_axi_awready,

    // 写数据通道
    input  wire [31:0]  s_axi_wdata,
    input  wire [3:0]   s_axi_wstrb,
    input  wire         s_axi_wvalid,
    output wire         s_axi_wready,

    // 写响应通道
    output wire [1:0]   s_axi_bresp,
    output wire         s_axi_bvalid,
    input  wire         s_axi_bready,

    // 读地址通道
    input  wire [31:0]  s_axi_araddr,
    input  wire         s_axi_arvalid,
    output wire         s_axi_arready,

    // 读数据通道
    output wire [31:0]  s_axi_rdata,
    output wire [1:0]   s_axi_rresp,
    output wire         s_axi_rvalid,
    input  wire         s_axi_rready
);

//==================== 寄存器地址定义（32位对齐） ====================
// 每4bit配置1路输出映射，16路输出共8个32位寄存器
// ADDR0~ADDR7：依次配置o_dio[0]~o_dio[15]输入比特映射
localparam REG_MAP_BASE  = 32'h00000000;
localparam REG_MAP0_ADDR = REG_MAP_BASE + 32'h00;  // o[0-3]
localparam REG_MAP1_ADDR = REG_MAP_BASE + 32'h04;  // o[4-7]
localparam REG_MAP2_ADDR = REG_MAP_BASE + 32'h08;  // o[8-11]
localparam REG_MAP3_ADDR = REG_MAP_BASE + 32'h0C;  // o[12-15]

//==================== 映射配置寄存器 ====================
// 每路输出4bit配置值(0~15)，对应i_dio比特位
reg [3:0] map_cfg [15:0];

// 输出数据寄存器
reg [15:0] dio_out_reg;

//==================== AXI4-Lite 内部信号 ====================
reg [31:0] axi_waddr_reg;
reg [31:0] axi_rdata_reg;
reg        axi_awready_reg;
reg        axi_wready_reg;
reg        axi_bvalid_reg;
reg        axi_arready_reg;
reg        axi_rvalid_reg;

assign s_axi_awready = axi_awready_reg;
assign s_axi_wready  = axi_wready_reg;
assign s_axi_bvalid  = axi_bvalid_reg;
assign s_axi_bresp   = 2'b00;  // 始终返回OK
assign s_axi_arready = axi_arready_reg;
assign s_axi_rvalid  = axi_rvalid_reg;
assign s_axi_rdata   = axi_rdata_reg;
assign s_axi_rresp   = 2'b00;  // 始终返回OK

//==================== AXI写地址捕获 ====================
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        axi_awready_reg <= 1'b0;
        axi_waddr_reg   <= 32'd0;
    end
    else begin
        axi_awready_reg <= s_axi_awvalid && (!axi_awready_reg);
        if(s_axi_awvalid && s_axi_awready)
            axi_waddr_reg <= s_axi_awaddr;
    end
end

//==================== AXI写数据与寄存器配置更新 ====================
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        axi_wready_reg  <= 1'b0;
        axi_bvalid_reg  <= 1'b0;
        map_cfg[0]  <= 4'd0; map_cfg[1]  <= 4'd1;
        map_cfg[2]  <= 4'd2; map_cfg[3]  <= 4'd3;
        map_cfg[4]  <= 4'd4; map_cfg[5]  <= 4'd5;
        map_cfg[6]  <= 4'd6; map_cfg[7]  <= 4'd7;
        map_cfg[8]  <= 4'd8; map_cfg[9]  <= 4'd9;
        map_cfg[10] <= 4'd10; map_cfg[11] <= 4'd11;
        map_cfg[12] <= 4'd12; map_cfg[13] <= 4'd13;
        map_cfg[14] <= 4'd14; map_cfg[15] <= 4'd15;
    end
    else begin
        axi_wready_reg <= s_axi_wvalid && (!axi_wready_reg);
        axi_bvalid_reg <= (axi_wready_reg && s_axi_wvalid) ? 1'b1 : (s_axi_bready ? 1'b0 : axi_bvalid_reg);
        
        // 根据写地址更新对应映射配置寄存器
        if(s_axi_wvalid && s_axi_wready) begin
            case(axi_waddr_reg)
                REG_MAP0_ADDR: begin
                    map_cfg[0] <= s_axi_wdata[3:0];
                    map_cfg[1] <= s_axi_wdata[7:4];
                    map_cfg[2] <= s_axi_wdata[11:8];
                    map_cfg[3] <= s_axi_wdata[15:12];
                end
                REG_MAP1_ADDR: begin
                    map_cfg[4] <= s_axi_wdata[3:0];
                    map_cfg[5] <= s_axi_wdata[7:4];
                    map_cfg[6] <= s_axi_wdata[11:8];
                    map_cfg[7] <= s_axi_wdata[15:12];
                end
                REG_MAP2_ADDR: begin
                    map_cfg[8]  <= s_axi_wdata[3:0];
                    map_cfg[9]  <= s_axi_wdata[7:4];
                    map_cfg[10] <= s_axi_wdata[11:8];
                    map_cfg[11] <= s_axi_wdata[15:12];
                end
                REG_MAP3_ADDR: begin
                    map_cfg[12] <= s_axi_wdata[3:0];
                    map_cfg[13] <= s_axi_wdata[7:4];
                    map_cfg[14] <= s_axi_wdata[11:8];
                    map_cfg[15] <= s_axi_wdata[15:12];
                end
            endcase
        end
    end
end

//==================== AXI读数据逻辑 ====================
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        axi_arready_reg <= 1'b0;
        axi_rvalid_reg  <= 1'b0;
        axi_rdata_reg   <= 32'd0;
    end
    else begin
        axi_arready_reg <= s_axi_arvalid && (!axi_arready_reg);
        axi_rvalid_reg  <= axi_arready_reg ? 1'b1 : (s_axi_rready ? 1'b0 : axi_rvalid_reg);
        
        if(s_axi_arvalid && s_axi_arready) begin
            case(s_axi_araddr)
                REG_MAP0_ADDR: axi_rdata_reg <= {16'd0,map_cfg[3],map_cfg[2],map_cfg[1],map_cfg[0]};
                REG_MAP1_ADDR: axi_rdata_reg <= {16'd0,map_cfg[7],map_cfg[6],map_cfg[5],map_cfg[4]};
                REG_MAP2_ADDR: axi_rdata_reg <= {16'd0,map_cfg[11],map_cfg[10],map_cfg[9],map_cfg[8]};
                REG_MAP3_ADDR: axi_rdata_reg <= {16'd0,map_cfg[15],map_cfg[14],map_cfg[13],map_cfg[12]};
                default:       axi_rdata_reg <= 32'd0;
            endcase
        end
    end
end

//==================== 动态比特映射+寄存器时序锁存 ====================
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        dio_out_reg <= 16'd0;
    end
    else begin
        dio_out_reg[0]  <= i_dio[map_cfg[0]];
        dio_out_reg[1]  <= i_dio[map_cfg[1]];
        dio_out_reg[2]  <= i_dio[map_cfg[2]];
        dio_out_reg[3]  <= i_dio[map_cfg[3]];
        dio_out_reg[4]  <= i_dio[map_cfg[4]];
        dio_out_reg[5]  <= i_dio[map_cfg[5]];
        dio_out_reg[6]  <= i_dio[map_cfg[6]];
        dio_out_reg[7]  <= i_dio[map_cfg[7]];
        dio_out_reg[8]  <= i_dio[map_cfg[8]];
        dio_out_reg[9]  <= i_dio[map_cfg[9]];
        dio_out_reg[10] <= i_dio[map_cfg[10]];
        dio_out_reg[11] <= i_dio[map_cfg[11]];
        dio_out_reg[12] <= i_dio[map_cfg[12]];
        dio_out_reg[13] <= i_dio[map_cfg[13]];
        dio_out_reg[14] <= i_dio[map_cfg[14]];
        dio_out_reg[15] <= i_dio[map_cfg[15]];
    end
end

// 最终输出
assign o_dio = dio_out_reg;

endmodule