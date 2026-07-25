OSERDESE2 #(
    .DATA_RATE_OQ("DDR"),   // OQ串行速率：DDR双边沿 / SDR单边沿
    .DATA_RATE_TQ("DDR"),   // TQ三态控制信号速率 DDR/BUF/SDR
    .DATA_WIDTH(4),         // 并行位宽：2~8,10,14
    .INIT_OQ(1'b0),
    .INIT_TQ(1'b0),
    .SERDES_MODE("MASTER"), // MASTER/SLAVE；>8bit并行需要主从级联
    .SRVAL_OQ(1'b0),        // 复位时OQ输出电平
    .SRVAL_TQ(1'b0),
    .TBYTE_CTL("FALSE"),    // 字节三态控制（IOB差分组相关，LVDS一般关闭）
    .TBYTE_SRC("FALSE"),
    .TRISTATE_WIDTH(4)      // T1~T4三态并行位宽(1/4)
)
OSERDESE2_inst (
    // Outputs
    .OFB(OFB),             // 内部反馈，用于ISERDESE2环回测试；直出IO时悬空
    .OQ(OQ),               // 串行输出 → 连接OBUF/OBUFDS
    .SHIFTOUT1(SHIFTOUT1),// MASTER→SLAVE级联输出（位宽>8使用）
    .SHIFTOUT2(SHIFTOUT2),
    .TBYTEOUT(TBYTEOUT),
    .TFB(TFB),
    .TQ(TQ),               // 串行三态控制输出
    // Inputs
    .CLK(CLK),             // 高速串行时钟
    .CLKDIV(CLKDIV),       // 并行域低速时钟
    .D1(D1),.D2(D2),.D3(D3),.D4(D4),.D5(D5),.D6(D6),.D7(D7),.D8(D8), //并行输入
    .OCE(OCE),             // 输出使能，高有效，建议常置1'b1
    .RST(RST),             // 异步高复位
    .SHIFTIN1(SHIFTIN1),   // SLAVE端接收MASTER移位数据
    .SHIFTIN2(SHIFTIN2),
    .T1(T1),.T2(T2),.T3(T3),.T4(T4), //三态并行控制
    .TBYTEIN(TBYTEIN),
    .TCE(TCE)              // 三态通路时钟使能
);