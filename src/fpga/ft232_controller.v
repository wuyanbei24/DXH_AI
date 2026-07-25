/**
 * @file ft232_controller.v
 * @brief FT232 Sync FIFO控制器 - FPGA端实现
 * @author DXH_AI
 * @date 2026-05-31
 * 
 * 功能描述:
 * - FT232 Sync FIFO接口控制
 * - 报文解析与构建
 * - AXI4-Lite主接口用于寄存器访问
 * - DDR波形数据缓存接口
 */

`timescale 1ns / 1ps

module ft232_controller #(
    parameter AXI_DATA_WIDTH = 32,
    parameter AXI_ADDR_WIDTH = 32
)(
    // 系统时钟与复位
    input  wire                         sys_clk,        // 系统时钟 (100MHz)
    input  wire                         sys_rst_n,      // 系统复位 (低有效)
    
    // FT232 Sync FIFO接口 (60MHz时钟域)
    input  wire                         ft_clk,         // FT232时钟 (60MHz)
    inout  wire [7:0]                   ft_data,        // 双向数据总线
    input  wire                         ft_rxf_n,       // RX FIFO非空 (低有效)
    input  wire                         ft_txe_n,       // TX FIFO非满 (低有效)
    output reg                          ft_rd_n,        // 读使能 (低有效)
    output reg                          ft_wr_n,        // 写使能 (低有效)
    output wire                         ft_oe_n,        // 输出使能 (低有效)
    output wire                         ft_siwu_n,      // 发送立即唤醒
    
    // AXI4-Lite主接口 (寄存器访问)
    output wire [AXI_ADDR_WIDTH-1:0]    m_axi_awaddr,
    output wire                         m_axi_awvalid,
    input  wire                         m_axi_awready,
    output wire [AXI_DATA_WIDTH-1:0]    m_axi_wdata,
    output wire [3:0]                   m_axi_wstrb,
    output wire                         m_axi_wvalid,
    input  wire                         m_axi_wready,
    input  wire [1:0]                   m_axi_bresp,
    input  wire                         m_axi_bvalid,
    output wire                         m_axi_bready,
    output wire [AXI_ADDR_WIDTH-1:0]    m_axi_araddr,
    output wire                         m_axi_arvalid,
    input  wire                         m_axi_arready,
    input  wire [AXI_DATA_WIDTH-1:0]    m_axi_rdata,
    input  wire [1:0]                   m_axi_rresp,
    input  wire                         m_axi_rvalid,
    output wire                         m_axi_rready,
    
    // DDR波形缓存接口 (AXI4 Stream)
    output wire [31:0]                  wave_tdata,
    output wire                         wave_tvalid,
    input  wire                         wave_tready,
    output wire                         wave_tlast,
    output wire [15:0]                  wave_tuser,     // 波形索引
    
    // ADC数据输入接口 (AXI4 Stream)
    input  wire [31:0]                  adc_tdata,
    input  wire                         adc_tvalid,
    output wire                         adc_tready,
    input  wire                         adc_tlast,
    input  wire [31:0]                  adc_timestamp,
    
    // 状态输出
    output wire                         link_active,
    output wire [15:0]                  error_code
);

/*============================================================================
 * 参数定义
 *===========================================================================*/

// 同步字
localparam SYNC_DOWNLINK = 16'h55AA;
localparam SYNC_UPLINK   = 16'hAA55;

// 报文类型 - 下行
localparam CMD_REG_WRITE   = 8'h01;
localparam CMD_REG_READ    = 8'h02;
localparam CMD_WAVE_CONFIG = 8'h03;
localparam CMD_WAVE_BATCH  = 8'h04;
localparam CMD_SYS_CTRL    = 8'h05;
localparam CMD_STATUS_REQ  = 8'h06;
localparam CMD_ACK         = 8'h0F;

// 报文类型 - 上行
localparam RSP_REG_DATA  = 8'h81;
localparam RSP_STATUS    = 8'h82;
localparam RSP_ADC_DATA  = 8'h83;
localparam RSP_ADC_BATCH = 8'h84;
localparam RSP_ERROR     = 8'h85;
localparam RSP_ACK       = 8'h8F;

// 帧结构参数
localparam FRAME_HEADER_SIZE = 7;
localparam MAX_PAYLOAD_SIZE  = 1012;
localparam FRAME_END_BYTE    = 8'h0D;

// 接收状态机
localparam RX_IDLE       = 4'd0;
localparam RX_SYNC_H     = 4'd1;
localparam RX_SYNC_L     = 4'd2;
localparam RX_TYPE       = 4'd3;
localparam RX_INDEX_H    = 4'd4;
localparam RX_INDEX_L    = 4'd5;
localparam RX_LENGTH_H   = 4'd6;
localparam RX_LENGTH_L   = 4'd7;
localparam RX_PAYLOAD    = 4'd8;
localparam RX_CRC_H      = 4'd9;
localparam RX_CRC_L      = 4'd10;
localparam RX_END        = 4'd11;
localparam RX_PROCESS    = 4'd12;
localparam RX_ERROR      = 4'd13;

// 发送状态机
localparam TX_IDLE       = 4'd0;
localparam TX_SYNC_H     = 4'd1;
localparam TX_SYNC_L     = 4'd2;
localparam TX_TYPE       = 4'd3;
localparam TX_INDEX_H    = 4'd4;
localparam TX_INDEX_L    = 4'd5;
localparam TX_LENGTH_H   = 4'd6;
localparam TX_LENGTH_L   = 4'd7;
localparam TX_PAYLOAD    = 4'd8;
localparam TX_CRC_H      = 4'd9;
localparam TX_CRC_L      = 4'd10;
localparam TX_END        = 4'd11;
localparam TX_DONE       = 4'd12;

/*============================================================================
 * 信号定义
 *===========================================================================*/

// 时钟域同步
reg  [2:0] rxf_sync;
reg  [2:0] txe_sync;
wire       rxf_n_s;
wire       txe_n_s;

// FT232数据总线控制
reg        ft_data_oe;
reg  [7:0] ft_data_out;
wire [7:0] ft_data_in;

// 接收状态机
reg  [3:0]  rx_state;
reg  [15:0] rx_sync;
reg  [7:0]  rx_type;
reg  [15:0] rx_index;
reg  [15:0] rx_length;
reg  [15:0] rx_count;
reg  [15:0] rx_crc_recv;
reg  [15:0] rx_crc_calc;

// 接收缓冲
reg  [7:0]  rx_buffer [0:1023];
reg  [9:0]  rx_buf_ptr;

// 发送状态机
reg  [3:0]  tx_state;
reg  [7:0]  tx_type;
reg  [15:0] tx_index;
reg  [15:0] tx_length;
reg  [15:0] tx_count;
reg  [15:0] tx_crc_calc;

// 发送缓冲
reg  [7:0]  tx_buffer [0:1023];
reg  [9:0]  tx_buf_ptr;
reg         tx_pending;

// 报文序号计数器
reg  [15:0] packet_index;

// 命令处理
reg         cmd_valid;
reg  [7:0]  cmd_type;
reg  [15:0] cmd_index;

// AXI接口控制
reg                          axi_wr_req;
reg                          axi_rd_req;
reg  [AXI_ADDR_WIDTH-1:0]    axi_addr;
reg  [AXI_DATA_WIDTH-1:0]    axi_wdata;
wire [AXI_DATA_WIDTH-1:0]    axi_rdata;
wire                         axi_done;

// 错误状态
reg  [15:0] error_reg;

/*============================================================================
 * FT232接口控制
 *===========================================================================*/

// 双向数据总线
assign ft_data    = ft_data_oe ? ft_data_out : 8'hZZ;
assign ft_data_in = ft_data;
assign ft_oe_n    = ~ft_data_oe;
assign ft_siwu_n  = 1'b1;

// 同步接收 (跨时钟域)
always @(posedge ft_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        rxf_sync <= 3'b111;
        txe_sync <= 3'b111;
    end else begin
        rxf_sync <= {rxf_sync[1:0], ft_rxf_n};
        txe_sync <= {txe_sync[1:0], ft_txe_n};
    end
end

assign rxf_n_s = rxf_sync[2];
assign txe_n_s = txe_sync[2];

/*============================================================================
 * CRC16-CCITT计算模块
 *===========================================================================*/

function [15:0] crc16_update;
    input [15:0] crc;
    input [7:0]  data;
    reg   [15:0] crc_next;
    integer      i;
begin
    crc_next = crc ^ ({data, 8'h00});
    for (i = 0; i < 8; i = i + 1) begin
        if (crc_next[15])
            crc_next = (crc_next << 1) ^ 16'h1021;
        else
            crc_next = crc_next << 1;
    end
    crc16_update = crc_next;
end
endfunction

/*============================================================================
 * 接收状态机 (FT232时钟域)
 *===========================================================================*/

always @(posedge ft_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        rx_state   <= RX_IDLE;
        ft_rd_n    <= 1'b1;
        ft_data_oe <= 1'b0;
        rx_crc_calc <= 16'hFFFF;
        rx_buf_ptr  <= 10'd0;
        cmd_valid   <= 1'b0;
    end else begin
        cmd_valid <= 1'b0;
        
        case (rx_state)
            RX_IDLE: begin
                ft_data_oe <= 1'b0;
                if (!rxf_n_s) begin
                    ft_rd_n    <= 1'b0;
                    rx_state   <= RX_SYNC_H;
                    rx_crc_calc <= 16'hFFFF;
                end
            end
            
            RX_SYNC_H: begin
                if (!rxf_n_s) begin
                    rx_sync[15:8] <= ft_data_in;
                    rx_crc_calc   <= crc16_update(rx_crc_calc, ft_data_in);
                    rx_state      <= RX_SYNC_L;
                end else begin
                    ft_rd_n  <= 1'b1;
                    rx_state <= RX_IDLE;
                end
            end
            
            RX_SYNC_L: begin
                rx_sync[7:0] <= ft_data_in;
                rx_crc_calc  <= crc16_update(rx_crc_calc, ft_data_in);
                if ({rx_sync[15:8], ft_data_in} == SYNC_DOWNLINK) begin
                    rx_state <= RX_TYPE;
                end else begin
                    ft_rd_n  <= 1'b1;
                    rx_state <= RX_ERROR;
                end
            end
            
            RX_TYPE: begin
                rx_type     <= ft_data_in;
                rx_crc_calc <= crc16_update(rx_crc_calc, ft_data_in);
                rx_state    <= RX_INDEX_H;
            end
            
            RX_INDEX_H: begin
                rx_index[15:8] <= ft_data_in;
                rx_crc_calc    <= crc16_update(rx_crc_calc, ft_data_in);
                rx_state       <= RX_INDEX_L;
            end
            
            RX_INDEX_L: begin
                rx_index[7:0] <= ft_data_in;
                rx_crc_calc   <= crc16_update(rx_crc_calc, ft_data_in);
                rx_state      <= RX_LENGTH_H;
            end
            
            RX_LENGTH_H: begin
                rx_length[15:8] <= ft_data_in;
                rx_crc_calc     <= crc16_update(rx_crc_calc, ft_data_in);
                rx_state        <= RX_LENGTH_L;
            end
            
            RX_LENGTH_L: begin
                rx_length[7:0] <= ft_data_in;
                rx_crc_calc    <= crc16_update(rx_crc_calc, ft_data_in);
                rx_count       <= 16'd0;
                rx_buf_ptr     <= 10'd0;
                if ({rx_length[15:8], ft_data_in} > 0) begin
                    rx_state <= RX_PAYLOAD;
                end else begin
                    rx_state <= RX_CRC_H;
                end
            end
            
            RX_PAYLOAD: begin
                rx_buffer[rx_buf_ptr] <= ft_data_in;
                rx_buf_ptr  <= rx_buf_ptr + 1'b1;
                rx_count    <= rx_count + 1'b1;
                rx_crc_calc <= crc16_update(rx_crc_calc, ft_data_in);
                if (rx_count + 1 >= rx_length) begin
                    rx_state <= RX_CRC_H;
                end
            end
            
            RX_CRC_H: begin
                rx_crc_recv[15:8] <= ft_data_in;
                rx_state          <= RX_CRC_L;
            end
            
            RX_CRC_L: begin
                rx_crc_recv[7:0] <= ft_data_in;
                rx_state         <= RX_END;
            end
            
            RX_END: begin
                ft_rd_n <= 1'b1;
                if (ft_data_in == FRAME_END_BYTE) begin
                    // 校验CRC
                    if (rx_crc_calc == rx_crc_recv) begin
                        rx_state  <= RX_PROCESS;
                        cmd_valid <= 1'b1;
                        cmd_type  <= rx_type;
                        cmd_index <= rx_index;
                    end else begin
                        rx_state  <= RX_ERROR;
                        error_reg <= 16'h0001;  // CRC错误
                    end
                end else begin
                    rx_state  <= RX_ERROR;
                    error_reg <= 16'h0002;  // 帧格式错误
                end
            end
            
            RX_PROCESS: begin
                // 命令处理完成后返回IDLE
                rx_state <= RX_IDLE;
            end
            
            RX_ERROR: begin
                // 错误恢复
                rx_state <= RX_IDLE;
            end
            
            default: rx_state <= RX_IDLE;
        endcase
    end
end

/*============================================================================
 * 发送状态机 (FT232时钟域)
 *===========================================================================*/

always @(posedge ft_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        tx_state    <= TX_IDLE;
        ft_wr_n     <= 1'b1;
        tx_crc_calc <= 16'hFFFF;
        tx_buf_ptr  <= 10'd0;
        packet_index <= 16'd0;
    end else begin
        case (tx_state)
            TX_IDLE: begin
                ft_wr_n <= 1'b1;
                if (tx_pending && !txe_n_s) begin
                    ft_data_oe  <= 1'b1;
                    tx_crc_calc <= 16'hFFFF;
                    tx_state    <= TX_SYNC_H;
                end
            end
            
            TX_SYNC_H: begin
                if (!txe_n_s) begin
                    ft_data_out <= SYNC_UPLINK[15:8];
                    ft_wr_n     <= 1'b0;
                    tx_crc_calc <= crc16_update(tx_crc_calc, SYNC_UPLINK[15:8]);
                    tx_state    <= TX_SYNC_L;
                end
            end
            
            TX_SYNC_L: begin
                ft_data_out <= SYNC_UPLINK[7:0];
                tx_crc_calc <= crc16_update(tx_crc_calc, SYNC_UPLINK[7:0]);
                tx_state    <= TX_TYPE;
            end
            
            TX_TYPE: begin
                ft_data_out <= tx_type;
                tx_crc_calc <= crc16_update(tx_crc_calc, tx_type);
                tx_state    <= TX_INDEX_H;
            end
            
            TX_INDEX_H: begin
                ft_data_out <= tx_index[15:8];
                tx_crc_calc <= crc16_update(tx_crc_calc, tx_index[15:8]);
                tx_state    <= TX_INDEX_L;
            end
            
            TX_INDEX_L: begin
                ft_data_out <= tx_index[7:0];
                tx_crc_calc <= crc16_update(tx_crc_calc, tx_index[7:0]);
                tx_state    <= TX_LENGTH_H;
            end
            
            TX_LENGTH_H: begin
                ft_data_out <= tx_length[15:8];
                tx_crc_calc <= crc16_update(tx_crc_calc, tx_length[15:8]);
                tx_state    <= TX_LENGTH_L;
            end
            
            TX_LENGTH_L: begin
                ft_data_out <= tx_length[7:0];
                tx_crc_calc <= crc16_update(tx_crc_calc, tx_length[7:0]);
                tx_count    <= 16'd0;
                tx_buf_ptr  <= 10'd0;
                if (tx_length > 0) begin
                    tx_state <= TX_PAYLOAD;
                end else begin
                    tx_state <= TX_CRC_H;
                end
            end
            
            TX_PAYLOAD: begin
                ft_data_out <= tx_buffer[tx_buf_ptr];
                tx_crc_calc <= crc16_update(tx_crc_calc, tx_buffer[tx_buf_ptr]);
                tx_buf_ptr  <= tx_buf_ptr + 1'b1;
                tx_count    <= tx_count + 1'b1;
                if (tx_count + 1 >= tx_length) begin
                    tx_state <= TX_CRC_H;
                end
            end
            
            TX_CRC_H: begin
                ft_data_out <= tx_crc_calc[15:8];
                tx_state    <= TX_CRC_L;
            end
            
            TX_CRC_L: begin
                ft_data_out <= tx_crc_calc[7:0];
                tx_state    <= TX_END;
            end
            
            TX_END: begin
                ft_data_out  <= FRAME_END_BYTE;
                tx_state     <= TX_DONE;
            end
            
            TX_DONE: begin
                ft_wr_n      <= 1'b1;
                ft_data_oe   <= 1'b0;
                tx_pending   <= 1'b0;
                packet_index <= packet_index + 1'b1;
                tx_state     <= TX_IDLE;
            end
            
            default: tx_state <= TX_IDLE;
        endcase
    end
end

/*============================================================================
 * 命令处理逻辑
 *===========================================================================*/

// 这里添加命令解析和处理逻辑
// 包括寄存器读写、波形配置、系统控制等

/*============================================================================
 * 状态输出
 *===========================================================================*/

assign link_active = (rx_state != RX_IDLE) || (tx_state != TX_IDLE);
assign error_code  = error_reg;

endmodule
