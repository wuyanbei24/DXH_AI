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


/*

//  ISERDESE2  : In order to incorporate this function into the design,
//   Verilog   : the following instance declaration needs to be placed
//  instance   : in the body of the design code.  The instance name
// declaration : (ISERDESE2_inst) and/or the port declarations within the
//    code     : parenthesis may be changed to properly reference and
//             : connect this function to the design.  All inputs
//             : and outputs must be connected.

//  <-----Cut code below this line---->

   // ISERDESE2: Input SERial/DESerializer with Bitslip
   //            Artix-7
   // Xilinx HDL Language Template, version 2018.2

   ISERDESE2 #(
      .DATA_RATE("DDR"),           // DDR, SDR
      .DATA_WIDTH(4),              // Parallel data width (2-8,10,14)
      .DYN_CLKDIV_INV_EN("FALSE"), // Enable DYNCLKDIVINVSEL inversion (FALSE, TRUE)
      .DYN_CLK_INV_EN("FALSE"),    // Enable DYNCLKINVSEL inversion (FALSE, TRUE)
      // INIT_Q1 - INIT_Q4: Initial value on the Q outputs (0/1)
      .INIT_Q1(1'b0),
      .INIT_Q2(1'b0),
      .INIT_Q3(1'b0),
      .INIT_Q4(1'b0),
      .INTERFACE_TYPE("MEMORY"),   // MEMORY, MEMORY_DDR3, MEMORY_QDR, NETWORKING, OVERSAMPLE
      .IOBDELAY("NONE"),           // NONE, BOTH, IBUF, IFD
      .NUM_CE(2),                  // Number of clock enables (1,2)
      .OFB_USED("FALSE"),          // Select OFB path (FALSE, TRUE)
      .SERDES_MODE("MASTER"),      // MASTER, SLAVE
      // SRVAL_Q1 - SRVAL_Q4: Q output values when SR is used (0/1)
      .SRVAL_Q1(1'b0),
      .SRVAL_Q2(1'b0),
      .SRVAL_Q3(1'b0),
      .SRVAL_Q4(1'b0)
   )
   ISERDESE2_inst (
      .O(O),                       // 1-bit output: Combinatorial output
      // Q1 - Q8: 1-bit (each) output: Registered data outputs
      .Q1(Q1),
      .Q2(Q2),
      .Q3(Q3),
      .Q4(Q4),
      .Q5(Q5),
      .Q6(Q6),
      .Q7(Q7),
      .Q8(Q8),
      // SHIFTOUT1, SHIFTOUT2: 1-bit (each) output: Data width expansion output ports
      .SHIFTOUT1(SHIFTOUT1),
      .SHIFTOUT2(SHIFTOUT2),
      .BITSLIP(BITSLIP),           // 1-bit input: The BITSLIP pin performs a Bitslip operation synchronous to
                                   // CLKDIV when asserted (active High). Subsequently, the data seen on the Q1
                                   // to Q8 output ports will shift, as in a barrel-shifter operation, one
                                   // position every time Bitslip is invoked (DDR operation is different from
                                   // SDR).

      // CE1, CE2: 1-bit (each) input: Data register clock enable inputs
      .CE1(CE1),
      .CE2(CE2),
      .CLKDIVP(CLKDIVP),           // 1-bit input: TBD
      // Clocks: 1-bit (each) input: ISERDESE2 clock input ports
      .CLK(CLK),                   // 1-bit input: High-speed clock
      .CLKB(CLKB),                 // 1-bit input: High-speed secondary clock
      .CLKDIV(CLKDIV),             // 1-bit input: Divided clock
      .OCLK(OCLK),                 // 1-bit input: High speed output clock used when INTERFACE_TYPE="MEMORY" 
      // Dynamic Clock Inversions: 1-bit (each) input: Dynamic clock inversion pins to switch clock polarity
      .DYNCLKDIVSEL(DYNCLKDIVSEL), // 1-bit input: Dynamic CLKDIV inversion
      .DYNCLKSEL(DYNCLKSEL),       // 1-bit input: Dynamic CLK/CLKB inversion
      // Input Data: 1-bit (each) input: ISERDESE2 data input ports
      .D(D),                       // 1-bit input: Data input
      .DDLY(DDLY),                 // 1-bit input: Serial data from IDELAYE2
      .OFB(OFB),                   // 1-bit input: Data feedback from OSERDESE2
      .OCLKB(OCLKB),               // 1-bit input: High speed negative edge output clock
      .RST(RST),                   // 1-bit input: Active high asynchronous reset
      // SHIFTIN1, SHIFTIN2: 1-bit (each) input: Data width expansion input ports
      .SHIFTIN1(SHIFTIN1),
      .SHIFTIN2(SHIFTIN2)
   );

   // End of ISERDESE2_inst instantiation
					

*/