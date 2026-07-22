// gpu.sv
// Top-level: wires core.sv (compute) -> shared_mem.sv (memory, arbitrated
// across lanes) -> display_controller.sv (scans out the image over VGA).

import gpu_pkg::*;

module gpu (
    input  logic clk, rst,
    output logic kernel_done,

    // to vga-hdmi IP
    output logic       hsync, vsync,
    output logic       video_active,
    output logic [7:0] vga_r, vga_g, vga_b
);

    // ------------------------------------------------------------------
    // core <-> shared_mem: one memory port per lane
    // ------------------------------------------------------------------
    logic [31:0] mem_addr  [0:31];
    logic [31:0] mem_rdata [0:31];
    logic        mem_read  [0:31];
    logic        mem_write [0:31];
    logic [31:0] mem_wdata [0:31];
    logic [3:0]  byte_en   [0:31];
    logic        mem_valid [0:31]; // now consumed by core.sv's scheduler to drive stall; cpu.sv/pc.sv themselves still don't read it directly

    // shared_mem <-> display_controller
    logic [31:0] disp_addr;
    logic [31:0] disp_rdata;

    core u_core (.*);

    shared_mem u_shared_mem (.*);

    display_controller u_display_controller (.*);

endmodule : gpu
