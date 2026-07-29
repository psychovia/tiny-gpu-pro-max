# build_bitstream.tcl -- synthesize, implement and write a bitstream for top.sv
# on the Boolean board (xc7s50csga324-1).
#
#   vivado -mode batch -source vivado/build_bitstream.tcl
#
# Run from the repo root. Produces build/vivado/tiny_gpu.runs/impl_1/top.bit
# plus utilization and timing reports in build/reports/.
#
# block_logic.sv is deliberately NOT added: it is archive-only, a fragment of
# the old block-dispatch bookkeeping meant to be spliced into scheduler.sv's
# scope, not a compilable module (it declares no module at all).

set repo    [file normalize [file dirname [info script]]/..]
set proj    $repo/build/vivado
set part    xc7s50csga324-1
set top_mod top

# The Clocking Wizard core: 100MHz in -> 40MHz (pixel) + 200MHz (TMDS 5x).
# top.sv instantiates it as clk_wiz_0. Already generated in the mini_gpu
# project; override with -tclargs if it lives somewhere else.
set clk_wiz_xci /home/mini_gpu/mini_gpu.srcs/sources_1/ip/clk_wiz_0/clk_wiz_0.xci
if {$argc > 0} { set clk_wiz_xci [lindex $argv 0] }

file mkdir $repo/build/reports
if {[file exists $proj]} { file delete -force $proj }
create_project tiny_gpu $proj -part $part -force

# ---------------------------------------------------------------------------
# sources
# ---------------------------------------------------------------------------
set rtl [list \
    $repo/SystemVerilog/gpu_pkg.sv \
    $repo/SystemVerilog/library.sv \
    $repo/SystemVerilog/decoder.sv \
    $repo/SystemVerilog/fetcher.sv \
    $repo/SystemVerilog/pc.sv \
    $repo/SystemVerilog/cpu.sv \
    $repo/SystemVerilog/scheduler.sv \
    $repo/SystemVerilog/core.sv \
    $repo/SystemVerilog/shared_mem.sv \
    $repo/SystemVerilog/data_buffer.sv \
    "$repo/SystemVerilog/display/display_ controller.sv" \
    $repo/SystemVerilog/display/vga-hdmi.sv \
    $repo/SystemVerilog/display/tmdsEncoder.sv \
    $repo/SystemVerilog/display/serializer.sv \
    $repo/SystemVerilog/display/hdmiTx.sv \
    $repo/SystemVerilog/display/hdmi_tx_0.sv \
    $repo/SystemVerilog/gpu.sv \
    $repo/SystemVerilog/top.sv \
]
add_files -norecurse -fileset sources_1 $rtl
set_property file_type SystemVerilog [get_files -of_objects [get_filesets sources_1] *.sv]

# gpu_pkg is a package -- it has to be analyzed before anything that imports it.
set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} -value {-verilog_define SYNTHESIS} \
    -objects [get_runs synth_1]

# Memory initialisation images. shared_mem.sv's $readmemb takes a RELATIVE
# path ("mems/..."), and synthesis runs in <proj>.runs/synth_1/, so the files
# are added to the project (which puts their directory on the search path) AND
# copied into the run directory below as a belt-and-braces fallback.
set mems [glob -nocomplain $repo/mems/*.mem]
if {[llength $mems]} {
    add_files -norecurse -fileset sources_1 $mems
    set_property file_type {Memory Initialization Files} [get_files *.mem]
}

add_files -fileset constrs_1 -norecurse $repo/constraints/boolean_mini_gpu.xdc

# ---------------------------------------------------------------------------
# clocking wizard IP
# ---------------------------------------------------------------------------
if {![file exists $clk_wiz_xci]} {
    puts "ERROR: clk_wiz_0 IP not found at $clk_wiz_xci"
    puts "       top.sv needs it to derive 40MHz + 200MHz from the 100MHz board clock."
    puts "       Pass the path as: vivado -mode batch -source ... -tclargs /path/to/clk_wiz_0.xci"
    exit 1
}
import_ip $clk_wiz_xci
set_property top $top_mod [current_fileset]
update_compile_order -fileset sources_1

# Make the .mem files reachable from the synthesis run directory, since
# $readmemb resolves its relative path against the tool's cwd.
proc stage_mems {repo runpath} {
    file mkdir $runpath/mems
    foreach f [glob -nocomplain $repo/mems/*.mem] {
        file copy -force $f $runpath/mems/
    }
}
file mkdir $proj/tiny_gpu.runs/synth_1
stage_mems $repo $proj/tiny_gpu.runs/synth_1

# ---------------------------------------------------------------------------
# synthesis
# ---------------------------------------------------------------------------
puts "### synthesis"
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "ERROR: synthesis failed -- see $proj/tiny_gpu.runs/synth_1/runme.log"
    exit 1
}

open_run synth_1 -name synth_1
report_utilization -file $repo/build/reports/post_synth_utilization.rpt
report_timing_summary -file $repo/build/reports/post_synth_timing.rpt

# ---------------------------------------------------------------------------
# implementation + bitstream
# ---------------------------------------------------------------------------
puts "### implementation + bitstream"
file mkdir $proj/tiny_gpu.runs/impl_1
stage_mems $repo $proj/tiny_gpu.runs/impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "ERROR: implementation failed -- see $proj/tiny_gpu.runs/impl_1/runme.log"
    exit 1
}

open_run impl_1
report_utilization        -file $repo/build/reports/post_impl_utilization.rpt
report_timing_summary     -file $repo/build/reports/post_impl_timing.rpt

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "### worst setup slack (WNS) = $wns ns"
puts "### worst hold  slack (WHS) = $whs ns"

set bit $proj/tiny_gpu.runs/impl_1/top.bit
if {[file exists $bit]} {
    file copy -force $bit $repo/build/tiny_gpu.bit
    puts "### BITSTREAM: build/tiny_gpu.bit"
} else {
    puts "ERROR: no bitstream produced"
    exit 1
}
if {$wns < 0 || $whs < 0} {
    puts "### WARNING: TIMING NOT MET -- the bitstream exists but may not work on hardware"
    exit 2
}
puts "### TIMING MET"
