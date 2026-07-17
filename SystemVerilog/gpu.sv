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
    logic        mem_valid [0:31]; // unused by core today -- see stall/latency issue

    logic        block_done;
    logic [gpu_pkg::BLOCK_ID_WIDTH-1:0] block_id;

    // shared_mem <-> display_controller
    logic [31:0] disp_addr;
    logic [31:0] disp_rdata;

    core u_core (
        .clk(clk),
        .rst(rst),
        .mem_rdata (mem_rdata),
        .mem_addr  (mem_addr),
        .mem_read  (mem_read),
        .mem_write (mem_write),
        .mem_wdata (mem_wdata),
        .byte_en   (byte_en),
        .block_done  (block_done),
        .kernel_done (kernel_done),
        .block_id    (block_id)
    );

    shared_mem u_shared_mem (
        .clk (clk),
        .rst (rst),
        .addr      (mem_addr),
        .mem_read  (mem_read),
        .mem_write (mem_write),
        .mem_wdata (mem_wdata),
        .byte_en   (byte_en),
        .mem_rdata (mem_rdata),
        .mem_valid (mem_valid),
        .disp_addr (disp_addr),
        .disp_rdata(disp_rdata)
    );

    display_controller u_display_controller (
        .clk(clk),
        .rst(rst),
        .ready(kernel_done),
        .disp_rdata(disp_rdata),
        .disp_addr (disp_addr),
        .hsync(hsync),
        .vsync(vsync),
        .video_active(video_active),
        .vga_r(vga_r),
        .vga_g(vga_g),
        .vga_b(vga_b)
    );

endmodule : gpu
