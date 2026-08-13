`timescale 1ns/1ps
//==============================================================================
// bram_model.v — 行为级 True Dual Port BRAM 模型（仿真用）
//
// 本文件为 pl_bram_comm_top 中例化的 tx_bram_ip / rx_bram_ip 提供行为级模型。
// 这两个 IP 在 Vivado 中以 Block Memory Generator 生成（真双口，PortA 32bit、
// PortB 16bit，异步时钟，共享 512 字节存储）。本模型用单一 512 字节内存数组
// 统一两口的字节编址，保证 PS(32bit) 写入的数据能被 PL(16bit) 正确读出，反之亦然。
//
// 字节编址约定（little-endian）：
//   PortA 字地址 a（7bit, 0..127） -> 字节基址 a*4，写 4 字节，读 4 字节
//   PortB 字地址 b（8bit, 0..255） -> 字节基址 b*2，写 2 字节，读 2 字节
//
// 注意：本设计在 top 中把 tx_bram_ip 的 web 恒接 0（PortB 只读）、
//       rx_bram_ip 的 wea 恒接 0（PortA 只读），因此不存在双口同时写的冲突。
//==============================================================================

//------------------------- TX BRAM：PS写 / PL读 -------------------------
module tx_bram_ip (
    input              clka,
    input              wea,
    input      [6:0]   addra,
    input      [31:0]  dina,
    output     [31:0]  douta,
    input              clkb,
    input              web,
    input      [7:0]   addrb,
    input      [15:0]  dinb,
    output     [15:0]  doutb
);
    reg [7:0] mem [0:511];
    integer i;
    initial for (i = 0; i < 512; i = i + 1) mem[i] = 8'd0;

    // PortA 写（PS 侧，32bit）
    always @(posedge clka) begin
        if (wea) begin
            mem[addra*4 + 0] <= dina[7:0];
            mem[addra*4 + 1] <= dina[15:8];
            mem[addra*4 + 2] <= dina[23:16];
            mem[addra*4 + 3] <= dina[31:24];
        end
    end
    assign douta = {mem[addra*4 + 3], mem[addra*4 + 2],
                    mem[addra*4 + 1], mem[addra*4 + 0]};

    // PortB 读（PL 侧，16bit，组合读，模型无延迟；FSM 自身含 TX_WAIT 等待拍）
    assign doutb = {mem[addrb*2 + 1], mem[addrb*2 + 0]};
endmodule

//------------------------- RX BRAM：PL写 / PS读 -------------------------
module rx_bram_ip (
    input              clka,
    input              wea,
    input      [6:0]   addra,
    input      [31:0]  dina,
    output     [31:0]  douta,
    input              clkb,
    input              web,
    input      [7:0]   addrb,
    input      [15:0]  dinb,
    output     [15:0]  doutb
);
    reg [7:0] mem [0:511];
    integer i;
    initial for (i = 0; i < 512; i = i + 1) mem[i] = 8'd0;

    // PortA 读（PS 侧，32bit，组合读）
    assign douta = {mem[addra*4 + 3], mem[addra*4 + 2],
                    mem[addra*4 + 1], mem[addra*4 + 0]};

    // PortB 写（PL 侧，16bit）
    always @(posedge clkb) begin
        if (web) begin
            mem[addrb*2 + 0] <= dinb[7:0];
            mem[addrb*2 + 1] <= dinb[15:8];
        end
    end
    assign doutb = {mem[addrb*2 + 1], mem[addrb*2 + 0]};
endmodule
