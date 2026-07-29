# fix_mini_gpu.tcl -- bring the mini_gpu Vivado project back in sync with the RTL.
#
# WHY THIS EXISTS
#   mini_gpu.xpr keeps its own explicit list of source files, pointing at
#   ../tiny-gpu-pro-max-main/SystemVerilog/. That list does not update itself, so
#   any file ADDED to the RTL is invisible to this project and synthesis dies at
#   elaboration:
#       ERROR: [Synth 8-439] module 'data_buffer' not found  (gpu.sv:88)
#   The RTL is fine -- the project's file list is stale. (The script-built
#   project in vivado/build_bitstream.tcl never hits this: it rebuilds its file
#   list from scratch every run, which is exactly why it kept succeeding while
#   this project failed.)
#
#   Memory images matter too. $readmemb resolves its relative "mems/..." path
#   against the tool's working directory, and adding the .mem files to the
#   project is what puts their directory on the search path. A .mem that cannot
#   be found does NOT error -- the memory just initialises to all zeros, so a
#   missing program image looks like a blank screen, not a build failure.
#
# USAGE
#   In an already-open Vivado (GUI Tcl console or batch):
#       source /home/tiny-gpu-pro-max-main/vivado/fix_mini_gpu.tcl
#   Or standalone:
#       vivado -mode batch -source vivado/fix_mini_gpu.tcl
#
#   Add -tclargs synth to also reset and re-run synthesis afterwards.

set proj /home/mini_gpu/mini_gpu.xpr
set rtl  /home/tiny-gpu-pro-max-main/SystemVerilog
set mems /home/tiny-gpu-pro-max-main/mems

# Track whether WE opened it. If this is being sourced into a session that
# already has the project open, closing it afterwards would yank the project out
# from under the GUI -- and, worse, that session's stale in-memory file list is
# exactly what clobbers the fix when it later saves. Sourcing here updates that
# live copy instead, so there is nothing stale left to overwrite it.
set we_opened 0
if {[catch {current_project} _]} {
    open_project $proj
    set we_opened 1
}

# ---- 1. source files the project is missing -------------------------------
# Listed explicitly rather than globbed: a glob would also pull in
# block_logic.sv, which is archive-only and declares no module at all.
set want [list \
    $rtl/gpu_pkg.sv $rtl/library.sv $rtl/decoder.sv $rtl/fetcher.sv $rtl/pc.sv \
    $rtl/cpu.sv $rtl/scheduler.sv $rtl/core.sv $rtl/shared_mem.sv \
    $rtl/data_buffer.sv \
    "$rtl/display/display_ controller.sv" $rtl/display/vga-hdmi.sv \
    $rtl/display/tmdsEncoder.sv $rtl/display/serializer.sv \
    $rtl/display/hdmiTx.sv $rtl/display/hdmi_tx_0.sv \
    $rtl/gpu.sv $rtl/top.sv \
]

# Every path goes through [list ...]. One of these files is literally named
# "display_ controller.sv" -- with a space -- and both get_files and add_files
# word-split a bare string argument, so unbraced it becomes two nonexistent
# paths ("display_" and "controller.sv"): the lookup misses, the script decides
# the file is absent, and add_files then dies on the truncated name.
# NOTE the -of_objects scoping on every lookup below. A bare `get_files name`
# searches EVERY fileset, including each synthesis run's own file list. A run
# that already compiled the file once keeps a reference to it, so an unscoped
# check reports "already present" while sources_1 is still missing it -- and the
# project then keeps failing in the GUI even though a batch synthesis passed.
set added {}
foreach f $want {
    if {[llength [get_files -quiet -of_objects [get_filesets sources_1] \
                            [list [file tail $f]]]] == 0} {
        add_files -norecurse -fileset sources_1 [list $f]
        lappend added [file tail $f]
    }
}
if {[llength $added]} {
    set_property file_type SystemVerilog \
        [get_files -of_objects [get_filesets sources_1] *.sv]
    puts "### added source files: $added"
} else {
    puts "### source files already complete"
}

# ---- 2. memory images ------------------------------------------------------
set added_mem {}
foreach f [glob -nocomplain $mems/*.mem] {
    if {[llength [get_files -quiet -of_objects [get_filesets sources_1] \
                            [list [file tail $f]]]] == 0} {
        add_files -norecurse -fileset sources_1 [list $f]
        lappend added_mem [file tail $f]
    }
}
if {[llength $added_mem]} {
    set_property file_type {Memory Initialization Files} [get_files *.mem]
    puts "### added memory images: $added_mem"
} else {
    puts "### memory images already complete"
}

# TOP MODULE. Vivado re-runs its auto-top heuristic whenever the file list
# changes, and it picks `gpu` -- the internal module that wires core +
# shared_mem + data_buffer + display_controller together. `gpu` is NOT the board
# top: it has no CLOCK_100/BTN/hdmi_*/LD ports, so every pin constraint in the
# XDC matches nothing ("set_property expects at least one object"), all 30 of
# its ports come out unconstrained, and write_bitstream dies on
#   ERROR: [DRC NSTD-1] Unspecified I/O Standard
#   ERROR: [DRC UCIO-1] Unconstrained Logical Port
# Synthesis and implementation both PASS in that state -- only bitstream
# generation fails -- which makes it look like a bitstream problem rather than
# a top-module problem. `top` is the board wrapper: clocking wizard, reset sync,
# HDMI serializer, status LEDs.
# ORDER MATTERS HERE. update_compile_order re-runs Vivado's auto-top heuristic
# and overwrites whatever top was set -- verified: setting it first reads back
# as "top", then reads back as "gpu" the moment update_compile_order runs. So
# the compile order is refreshed FIRST and the top is pinned LAST.
#
# Why it matters: Vivado's heuristic picks `gpu`, the internal module that wires
# core + shared_mem + data_buffer + display_controller together. `gpu` is not the
# board top -- it has no CLOCK_100/BTN/hdmi_*/LD ports -- so every pin constraint
# in the XDC matches nothing ("set_property expects at least one object"), all 30
# of its ports come out unconstrained, and write_bitstream dies on
#   ERROR: [DRC NSTD-1] Unspecified I/O Standard
#   ERROR: [DRC UCIO-1] Unconstrained Logical Port
# Synthesis and implementation both PASS in that state -- only bitstream
# generation fails -- so it presents as a bitstream problem, not a top-module
# one. `top` is the board wrapper: clocking wizard, reset sync, HDMI serializer,
# status LEDs.
update_compile_order -fileset sources_1
set_property source_mgmt_mode DisplayOnly [current_project]
set_property top top [get_filesets sources_1]
set actual [get_property top [get_filesets sources_1]]
puts "### top module = $actual"
if {$actual ne "top"} {
    puts "### ERROR: top is '$actual', expected 'top'"
    exit 1
}


# $readmemb resolves against the RUN directory, so stage the images there too --
# belt and braces alongside the search path the project gives us.
foreach run {synth_1 impl_1} {
    set d /home/mini_gpu/mini_gpu.runs/$run
    if {[file isdirectory $d]} {
        file mkdir $d/mems
        foreach f [glob -nocomplain $mems/*.mem] { file copy -force $f $d/mems/ }
    }
}
puts "### staged memory images into the run directories"

# ---- 3. optionally re-run synthesis ---------------------------------------
if {$argc > 0 && [lindex $argv 0] eq "synth"} {
    reset_run synth_1
    launch_runs synth_1 -jobs 8
    wait_on_run synth_1
    if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
        puts "### SYNTHESIS STILL FAILING -- see mini_gpu.runs/synth_1/runme.log"
        exit 1
    }
    puts "### synthesis OK"
}
# Verify against sources_1 specifically, then close -- closing is what flushes
# the file list to mini_gpu.xpr on disk. Skipping it can leave the additions in
# this session only, so the next GUI open is stale again, which is exactly how a
# passing batch synthesis coexists with a failing GUI one.
if {[llength [get_files -quiet -of_objects [get_filesets sources_1] \
                        [list data_buffer.sv]]] == 0} {
    puts "### ERROR: data_buffer.sv still not in sources_1"
    exit 1
}
if {$we_opened} {
    close_project
    puts "### fix_mini_gpu: done (project saved and closed)"
} else {
    puts "### fix_mini_gpu: done -- applied to the OPEN project."
    puts "### This session's file list is now correct, so it can no longer"
    puts "### overwrite the fix on save/exit. Re-run synthesis when ready."
}
