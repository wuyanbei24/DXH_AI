ISERDESE2 #(
    .DATA_RATE("DDR"),           // DDR/SDR
    .DATA_WIDTH(4),              // 并行输出位宽 2~8,10,14
    .DYN_CLKDIV_INV_EN("FALSE"), // 动态反转CLKDIV，一般关闭
    .DYN_CLK_INV_EN("FALSE"),
    .INIT_Q1(1'b0),.INIT_Q2(1'b0),.INIT_Q3(1'b0),.INIT_Q4(1'b0),
    .INTERFACE_TYPE("NETWORKING"),// 【重点】LVDS通信选NETWORKING；MEMORY用于DDR内存
    .IOBDELAY("NONE"),           // NONE / IDELAYE2 延时控制
    .NUM_CE(2),                  // CE数量，通常固定2
    .OFB_USED("FALSE"),          // 是否使用OSERDESE2反馈环回
    .SERDES_MODE("MASTER"),
    .SRVAL_Q1(1'b0),.SRVAL_Q2(1'b0),.SRVAL_Q3(1'b0),.SRVAL_Q4(1'b0)
)
iserdese2_inst (
    .O(O),
    .Q1(Q1),.Q2(Q2),.Q3(Q3),.Q4(Q4),.Q5(Q5),.Q6(Q6),.Q7(Q7),.Q8(Q8), //并行输出
    .SHIFTOUT1(SHIFTOUT1),
    .SHIFTOUT2(SHIFTOUT2),
    .BITSLIP(BITSLIP),           // 位滑动信号，同步CLKDIV，用于对齐数据
    .CE1(1'b1),
    .CE2(1'b1),
    .CLKDIVP(1'b0),
    .CLK(CLK),       // 高速串行时钟
    .CLKB(~CLK),     // DDR模式必须输入CLK反相时钟！SDR可接地
    .CLKDIV(CLKDIV), // 并行低速时钟
    .OCLK(1'b0),
    .D(D),           // 串行输入（IBUFDS输出）
    .DDLY(1'b0),     // 使用IDELAYE2时接IDELAY输出，否则悬空
    .OFB(1'b0),
    .OCLKB(1'b0),
    .RST(RST),
    .SHIFTIN1(SHIFTIN1),
    .SHIFTIN2(SHIFTIN2),
    .DYNCLKDIVSEL(1'b0),
    .DYNCLKSEL(1'b0)
);