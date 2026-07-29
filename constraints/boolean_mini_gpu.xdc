# ============================================================================
# boolean_mini_gpu.xdc -- pin/timing constraints for top.sv on the Boolean
# board (xc7s50csga324-1).
#
# Pin assignments taken from Lab2/Boolean240.xdc, which targets this same
# board and happens to use the identical port names as top.sv. Trimmed to
# only the ports top.sv actually declares -- the full board file also
# constrains LEDs, switches, 7-seg, UART, audio and servos, and referencing
# ports that don't exist in this design would throw no-objects-matched
# errors during implementation.
#
# Also deliberately omitted: the board file's
#   set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets BTN_IBUF[3]]
# That exists because Lab2 clocked logic off BTN[3]. This design doesn't --
# BTN[0] is only used as a reset, synchronized in top.sv -- so the override
# would apply to a net that isn't a clock here.
# ============================================================================

# ---- configuration bank voltage ----
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

# ---- 100MHz board oscillator ----
# clk_wiz_0 derives 40MHz (pixel) and 200MHz (TMDS serializer) from this;
# those two are auto-derived by the tool off the MMCM, so they don't need
# their own create_clock here.
# NO create_clock here on purpose. clk_wiz_0's own in-context XDC already
# constrains this port (`create_clock -period 10.000 [get_ports clk_in1]`, which
# propagates up to CLOCK_100), and top.sv cannot work without that IP, so the
# constraint is always present. Adding a second one raised
#   CRITICAL WARNING: [Constraints 18-1056] Clock 'sys_clk' completely
#                     overrides clock 'CLOCK_100'
# which is harmless in effect (both are 10 ns) but also stops Vivado caching the
# synthesis result -- "Synthesis results are not added to the cache due to
# CRITICAL_WARNING" -- so every build re-synthesised from scratch.
#
# Guarding it with `if {[llength [get_clocks ...]] == 0}` does NOT work: XDC is a
# restricted Tcl dialect and synthesis rejects the conditional outright with
# CRITICAL WARNING [Designutils 20-1307] "Command 'if' is not supported in the
# xdc constraint file". A .tcl constraints file would allow it; not worth it for
# a constraint the IP already owns.
#
# The clock is therefore named CLOCK_100 (auto-named from the port), not
# sys_clk. Nothing in this file referenced sys_clk by name.
set_property -dict {PACKAGE_PIN F14 IOSTANDARD LVCMOS33} [get_ports {CLOCK_100}]

# ---- push-buttons ----
# BTN[0] doubles as reset (see top.sv). BTN[1..3] are unused by the design
# but are still ports, so they need pin assignments.
set_property -dict {PACKAGE_PIN J2 IOSTANDARD LVCMOS33} [get_ports {BTN[0]}]
set_property -dict {PACKAGE_PIN J5 IOSTANDARD LVCMOS33} [get_ports {BTN[1]}]
set_property -dict {PACKAGE_PIN H2 IOSTANDARD LVCMOS33} [get_ports {BTN[2]}]
set_property -dict {PACKAGE_PIN J1 IOSTANDARD LVCMOS33} [get_ports {BTN[3]}]

# ---- HDMI TMDS differential pairs ----
# TMDS_33 is the differential I/O standard the HDMI connector needs; these
# drive OBUFDS primitives inside serializer.sv.
set_property -dict {PACKAGE_PIN T14 IOSTANDARD TMDS_33} [get_ports {hdmi_clk_n}]
set_property -dict {PACKAGE_PIN R14 IOSTANDARD TMDS_33} [get_ports {hdmi_clk_p}]

# data lane 0 = blue, 1 = green, 2 = red (see hdmiTx.sv's serializer wiring)
set_property -dict {PACKAGE_PIN T15 IOSTANDARD TMDS_33} [get_ports {hdmi_tx_n[0]}]
set_property -dict {PACKAGE_PIN R17 IOSTANDARD TMDS_33} [get_ports {hdmi_tx_n[1]}]
set_property -dict {PACKAGE_PIN P16 IOSTANDARD TMDS_33} [get_ports {hdmi_tx_n[2]}]

set_property -dict {PACKAGE_PIN R15 IOSTANDARD TMDS_33} [get_ports {hdmi_tx_p[0]}]
set_property -dict {PACKAGE_PIN R16 IOSTANDARD TMDS_33} [get_ports {hdmi_tx_p[1]}]
set_property -dict {PACKAGE_PIN N15 IOSTANDARD TMDS_33} [get_ports {hdmi_tx_p[2]}]

# ---- status LEDs (see top.sv) ----
# Four diagnostics so a blank screen can be bisected on the board itself:
# heartbeat, MMCM locked, kernel_done, video_active.
set_property -dict {PACKAGE_PIN G1 IOSTANDARD LVCMOS33} [get_ports {LD[0]}]
set_property -dict {PACKAGE_PIN G2 IOSTANDARD LVCMOS33} [get_ports {LD[1]}]
set_property -dict {PACKAGE_PIN F1 IOSTANDARD LVCMOS33} [get_ports {LD[2]}]
set_property -dict {PACKAGE_PIN F2 IOSTANDARD LVCMOS33} [get_ports {LD[3]}]
