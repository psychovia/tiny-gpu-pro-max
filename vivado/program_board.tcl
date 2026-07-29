# program_board.tcl -- load build/tiny_gpu.bit onto the Boolean board over JTAG.
#
#   vivado -mode batch -source vivado/program_board.tcl
#
# The board must be plugged in over USB and powered before running this.
# Volatile: the bitstream lives in SRAM and is lost on power cycle. Re-run this
# after unplugging, or write to flash separately if you want it to persist.

set repo [file normalize [file dirname [info script]]/..]
set bit  $repo/build/tiny_gpu.bit
if {$argc > 0} { set bit [lindex $argv 0] }

if {![file exists $bit]} {
    puts "ERROR: no bitstream at $bit"
    puts "       run: vivado -mode batch -source vivado/build_bitstream.tcl"
    exit 1
}

open_hw_manager
connect_hw_server
if {[llength [get_hw_targets]] == 0} {
    puts "ERROR: no JTAG target found. Is the board plugged in over USB and powered on?"
    exit 1
}
open_hw_target
set dev [lindex [get_hw_devices] 0]
puts "### programming [get_property PART $dev] with $bit"
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
refresh_hw_device $dev
puts "### done -- the filtered image should be on the HDMI monitor now"
close_hw_manager
