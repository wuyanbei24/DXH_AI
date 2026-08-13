# ============================================================================
# gen_clk_ip.tcl
# Generate Xilinx Clocking Wizard (clk_wiz / MMCM) IP for mfpga_clk_gen
# Target part : xc7z020clg400-2  (Zynq-7000)
# Input       : 50 MHz, single-ended
# Outputs     : 160M / 40M / 200M / 125M / 125M(90deg) / 20M   (6 clocks)
# No IP reset port (USE_RESET=false); reset is derived from locked in wrapper.
# ============================================================================

set part            "xc7z020clg400-2"
set ip_name         "mfpga_clk_gen_ip"
set ip_dir          "F:/wc.prj/pulse_mfpga/src/DXH_AI/mfpga_clk_gen/ip"
set tmp_proj_dir    "F:/wc.prj/pulse_mfpga/src/DXH_AI/mfpga_clk_gen/_vivado_tmp"

# ---------------------------------------------------------------------------
# 1) Create a temporary managed project (required for create_ip / generate)
# ---------------------------------------------------------------------------
file delete -force $tmp_proj_dir
create_project -force -part $part mfpga_clk_gen_tmp $tmp_proj_dir

# ---------------------------------------------------------------------------
# 2) Create the Clocking Wizard IP
# ---------------------------------------------------------------------------
create_ip -name clk_wiz -vendor xilinx.com -library ip \
          -module_name $ip_name -dir $ip_dir

set ip [get_ips $ip_name]

# ---- Basic primitive / input configuration ----
set_property CONFIG.AUTO_PRIMITIVE             {MMCM}                       $ip
set_property CONFIG.PRIM_IN_FREQ               {50}                         $ip
set_property CONFIG.PRIM_SOURCE                {Single_ended_clock_capable_pin} $ip
set_property CONFIG.CLKIN1_JITTER_PS           {200.0}                      $ip
set_property CONFIG.MMCM_COMPENSATION          {ZHOLD}                      $ip
set_property CONFIG.FEEDBACK_SOURCE            {FDBK_AUTO}                  $ip
set_property CONFIG.CLOCK_MGR_TYPE             {auto}                       $ip
set_property CONFIG.USE_MIN_POWER              {false}                      $ip

# ---- Control ports (mirror legacy design: no IP reset, expose locked) ----
set_property CONFIG.USE_RESET                  {false}                      $ip
set_property CONFIG.RESET_TYPE                 {ACTIVE_HIGH}                $ip
set_property CONFIG.USE_LOCKED                 {true}                       $ip
set_property CONFIG.USE_DYN_PHASE_SHIFT        {false}                      $ip
set_property CONFIG.USE_PHASE_ALIGNMENT        {true}                       $ip

# ---- Number of output clocks ----
set_property CONFIG.NUM_OUT_CLKS               {6}                          $ip

# ---------------------------------------------------------------------------
# 3) Configure the six output clocks
#    clk_out1 = 160 MHz  (LVDS DDR fast clock, fractional divide)
#    clk_out2 =  40 MHz  (LVDS DDR slow clock = 160/4)
#    clk_out3 = 200 MHz  (LVDS SelectIO reference)
#    clk_out4 = 125 MHz  (RGMII)
#    clk_out5 = 125 MHz, 90 deg phase (RGMII TX timing align)
#    clk_out6 =  20 MHz  (GPIB)
# ---------------------------------------------------------------------------
proc cfg_out {ip idx freq phase} {
    set_property CONFIG.CLKOUT${idx}_USED                {true}            $ip
    set_property CONFIG.CLKOUT${idx}_REQUESTED_OUT_FREQ  $freq             $ip
    set_property CONFIG.CLKOUT${idx}_REQUESTED_PHASE     $phase            $ip
    set_property CONFIG.CLKOUT${idx}_REQUESTED_DUTY_CYCLE {50}             $ip
    set_property CONFIG.CLKOUT${idx}_DRIVES              {BUFG}            $ip
}

cfg_out $ip 1 160 0
cfg_out $ip 2  40 0
cfg_out $ip 3 200 0
cfg_out $ip 4 125 0
cfg_out $ip 5 125 90
cfg_out $ip 6  20 0

# clk_out7 unused
set_property CONFIG.CLKOUT7_USED {false} $ip

# ---------------------------------------------------------------------------
# 4) Generate synthesis + simulation targets and write the .xci
# ---------------------------------------------------------------------------
generate_target all $ip
write_ip $ip

# ---------------------------------------------------------------------------
# 5) Report the resulting configuration for log verification
# ---------------------------------------------------------------------------
puts "=========================================================="
puts "Generated IP: $ip_name  (part $part)"
puts "Input : 50 MHz single-ended"
foreach {i f p} {1 160 0  2 40 0  3 200 0  4 125 0  5 125 90  6 20 0} {
    puts "  clk_out${i} : requested ${f} MHz, phase ${p} deg"
}
puts "=========================================================="

close_project
