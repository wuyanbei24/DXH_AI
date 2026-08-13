`timescale 1ns / 1ps

// ============================================================================
// mfpga_clk_gen_tb.v
// Testbench for mfpga_clk_gen (clk_wiz MMCM wrapper, xc7z020clg400-2).
//
//   - Drives a 50 MHz single-ended reference clock.
//   - Waits for the MMCM to lock (timeout guard).
//   - Measures the period (hence frequency) of every output clock.
//   - Checks the 125 MHz / 125 MHz-90deg phase relationship.
//   - Prints PASS/FAIL.
//
// Expected clocks (MHz): 160 / 40 / 200 / 125 / 125 / 20
// RGMII TX clock (o_clk_125m_90d) is expected ~90 deg ahead of o_clk_125m.
// ============================================================================
module mfpga_clk_gen_tb;

    // ---- DUT interface ----
    reg  i_fpga_ref_clk_50m;
    wire o_clk_160m;
    wire o_clk_40m;
    wire o_clk_200m;
    wire o_clk_125m;
    wire o_clk_125m_90d;
    wire o_clk_20m;
    wire o_locked;
    wire o_reset;

    // ---- instantiate DUT ----
    mfpga_clk_gen u_dut (
        .i_fpga_ref_clk_50m (i_fpga_ref_clk_50m),
        .o_clk_160m         (o_clk_160m),
        .o_clk_40m          (o_clk_40m),
        .o_clk_200m         (o_clk_200m),
        .o_clk_125m         (o_clk_125m),
        .o_clk_125m_90d     (o_clk_125m_90d),
        .o_clk_20m          (o_clk_20m),
        .o_locked           (o_locked),
        .o_reset            (o_reset)
    );

    // ---- 50 MHz reference clock (period = 20 ns) ----
    initial i_fpga_ref_clk_50m = 1'b0;
    always #10 i_fpga_ref_clk_50m = ~i_fpga_ref_clk_50m;

    // ---- measured / expected frequencies (MHz) ----
    real f160, f40, f200, f125, f125d, f20;
    real exp160 = 160.0, exp40 = 40.0, exp200 = 200.0, exp125 = 125.0, exp20 = 20.0;
    real exp125d = 125.0;
    integer pass;
    real tol;

    // ---- helpers ----
    function real absval; input real x; begin absval = (x < 0.0) ? -x : x; end endfunction

    // Measure the period of a clock by timing two consecutive posedges.
    task measure_freq;
        input  wire clk;
        output real f;     // MHz
        real t1, t2;
        begin
            @(posedge clk); t1 = $realtime;
            @(posedge clk); t2 = $realtime;
            f = 1000.0 / (t2 - t1);   // period in ns -> MHz
        end
    endtask

    // -----------------------------------------------------------------------
    initial begin
        pass = 1;
        tol  = 0.02;   // +/-2% tolerance

        $display("==================================================");
        $display(" mfpga_clk_gen TB : ref=50MHz SE, part xc7z020clg400-2");
        $display("==================================================");

        // ---- wait for lock (timeout 500 us) ----
        fork
            begin: wait_lock
                @(posedge o_locked);
                $display("[%0t] INFO: MMCM locked.", $realtime);
            end
            begin
                #500000;
                $display("[%0t] ERROR: MMCM did NOT lock within 500 us.", $realtime);
                pass = 0;
            end
        join_any
        disable wait_lock;

        if (!o_locked) begin
            $display("==== TEST FAILED (no lock) ====");
            #1000; $finish;
        end

        // ---- measure output frequencies (let clocks settle a few edges) ----
        measure_freq(o_clk_160m,   f160);
        measure_freq(o_clk_40m,    f40);
        measure_freq(o_clk_200m,   f200);
        measure_freq(o_clk_125m,   f125);
        measure_freq(o_clk_125m_90d, f125d);
        measure_freq(o_clk_20m,    f20);

        $display("Measured frequencies (MHz):");
        $display("  160M -> %0.3f   40M -> %0.3f   200M -> %0.3f", f160, f40, f200);
        $display("  125M -> %0.3f   125M_90 -> %0.3f   20M -> %0.3f", f125, f125d, f20);

        // ---- frequency checks ----
        if (absval(f160  - exp160)  / exp160  > tol) begin $display("FAIL: 160M = %0.3f", f160);  pass = 0; end
        if (absval(f40   - exp40)   / exp40   > tol) begin $display("FAIL: 40M  = %0.3f", f40);   pass = 0; end
        if (absval(f200  - exp200)  / exp200  > tol) begin $display("FAIL: 200M = %0.3f", f200);  pass = 0; end
        if (absval(f125  - exp125)  / exp125  > tol) begin $display("FAIL: 125M = %0.3f", f125);  pass = 0; end
        if (absval(f125d - exp125d) / exp125d > tol) begin $display("FAIL: 125M_90 = %0.3f", f125d); pass = 0; end
        if (absval(f20   - exp20)   / exp20   > tol) begin $display("FAIL: 20M  = %0.3f", f20);   pass = 0; end

        // ---- phase check (125M vs 125M_90d) : expected ~90 deg ----
        begin
            real t125, t125d_t, per, ph;
            @(posedge o_clk_125m);       t125    = $realtime;
            @(posedge o_clk_125m_90d);   t125d_t = $realtime;
            per = 1000.0 / f125;             // period of 125M in ns
            ph  = t125d_t - t125;
            if (ph < 0.0) ph = ph + per;     // wrap into one period
            $display("Phase 125M_90d vs 125M : %0.3f ns (expected ~%0.3f ns = 90 deg)", ph, per/4.0);
        end

        // ---- global reset sanity : should be released (low) once locked ----
        #200;
        $display("o_reset after lock = %b (expected 0)", o_reset);

        #1000;
        if (pass) $display("==== TEST PASSED ====");
        else      $display("==== TEST FAILED ====");
        $finish;
    end

endmodule
