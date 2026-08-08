
//  OSERDESE2  : In order to incorporate this function into the design,
//   Verilog   : the following instance declaration needs to be placed
//  instance   : in the body of the design code.  The instance name
// declaration : (OSERDESE2_inst) and/or the port declarations within the
//    code     : parenthesis may be changed to properly reference and
//             : connect this function to the design.  All inputs
//             : and outputs must be connected.

//  <-----Cut code below this line---->

   // OSERDESE2: Output SERial/DESerializer with bitslip
   //            Artix-7
   // Xilinx HDL Language Template, version 2018.2

   OSERDESE2 #(
      .DATA_RATE_OQ("DDR"),   // DDR, SDR
      .DATA_RATE_TQ("DDR"),   // DDR, BUF, SDR
      .DATA_WIDTH(4),         // Parallel data width (2-8,10,14)
      .INIT_OQ(1'b0),         // Initial value of OQ output (1'b0,1'b1)
      .INIT_TQ(1'b0),         // Initial value of TQ output (1'b0,1'b1)
      .SERDES_MODE("MASTER"), // MASTER, SLAVE
      .SRVAL_OQ(1'b0),        // OQ output value when SR is used (1'b0,1'b1)
      .SRVAL_TQ(1'b0),        // TQ output value when SR is used (1'b0,1'b1)
      .TBYTE_CTL("FALSE"),    // Enable tristate byte operation (FALSE, TRUE)
      .TBYTE_SRC("FALSE"),    // Tristate byte source (FALSE, TRUE)
      .TRISTATE_WIDTH(4)      // 3-state converter width (1,4)
   )
   OSERDESE2_inst (
      .OFB(OFB),             // 1-bit output: Feedback path for data
      .OQ(OQ),               // 1-bit output: Data path output
      // SHIFTOUT1 / SHIFTOUT2: 1-bit (each) output: Data output expansion (1-bit each)
      .SHIFTOUT1(SHIFTOUT1),
      .SHIFTOUT2(SHIFTOUT2),
      .TBYTEOUT(TBYTEOUT),   // 1-bit output: Byte group tristate
      .TFB(TFB),             // 1-bit output: 3-state control
      .TQ(TQ),               // 1-bit output: 3-state control
      .CLK(CLK),             // 1-bit input: High speed clock
      .CLKDIV(CLKDIV),       // 1-bit input: Divided clock
      // D1 - D8: 1-bit (each) input: Parallel data inputs (1-bit each)
      .D1(D1),
      .D2(D2),
      .D3(D3),
      .D4(D4),
      .D5(D5),
      .D6(D6),
      .D7(D7),
      .D8(D8),
      .OCE(OCE),             // 1-bit input: Output data clock enable
      .RST(RST),             // 1-bit input: Reset
      // SHIFTIN1 / SHIFTIN2: 1-bit (each) input: Data input expansion (1-bit each)
      .SHIFTIN1(SHIFTIN1),
      .SHIFTIN2(SHIFTIN2),
      // T1 - T4: 1-bit (each) input: Parallel 3-state inputs
      .T1(T1),
      .T2(T2),
      .T3(T3),
      .T4(T4),
      .TBYTEIN(TBYTEIN),     // 1-bit input: Byte group tristate
      .TCE(TCE)              // 1-bit input: 3-state clock enable
   );

   // End of OSERDESE2_inst instantiation
					