// gpu.sv
// Top-level: wires core.sv (compute) -> shared_mem.sv (memory, arbitrated
// across lanes) -> display_controller.sv (scans out the image over VGA).

import gpu_pkg::*;

module gpu #(
    // Which program and which source image get baked into shared_mem's BRAM
    // initialisation. Defaults are the grayscale-filter demo, because gpu.sv is
    // what top.sv puts on the board -- so the defaults are what you get on the
    // monitor if you build a bitstream without overriding anything.
    // Simulation testbenches that want a different program override these.
    parameter string PROG_INIT_FILE = "mems/invert_c.mem",
    parameter string IMG_INIT_FILE  = "mems/img_source.mem",

    // Source image for the data buffer. A PREFIX, not a filename: bank b
    // reads "<prefix>b.mem". `img_tool.py to-dbuf` writes the whole set.
    // Separate from IMG_INIT_FILE, which is the old 3-packed-bytes layout.
    parameter string DBUF_INIT_PREFIX = "mems/dbuf_photo_bank",

    // Which store the monitor scans out. The data buffer is where a kernel
    // written with setdt/getdt puts its output; shared_mem is where the older
    // lw/sw kernels (filter_gray.s) put theirs. Both paths are live at once --
    // this only picks which one reaches the screen.
    //
    // 1 = the data buffer, which is where a getdata/setdata kernel puts its
    // output. The current demo (invert_c.mem over dbuf_source) is one of those.
    // Set to 0 only for the older lw/sw kernels like filter_gray.s, which write
    // their image into shared_mem instead -- and pair that with IMG_INIT_FILE.
    parameter bit DISPLAY_FROM_DBUF = 1'b1
) (
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
    // Sized off gpu_pkg::N_LANES to match core.sv's and shared_mem's ports
    // (shared_mem is instantiated below with .N_THREADS(N_LANES)). These were
    // hardcoded [0:31]; with N_LANES != 32 the `.*` wiring would connect
    // mismatched widths.
    logic [31:0] mem_addr  [0:gpu_pkg::N_LANES-1];
    logic [31:0] mem_rdata [0:gpu_pkg::N_LANES-1];
    logic        mem_read  [0:gpu_pkg::N_LANES-1];
    logic        mem_write [0:gpu_pkg::N_LANES-1];
    logic [31:0] mem_wdata [0:gpu_pkg::N_LANES-1];
    logic [3:0]  byte_en   [0:gpu_pkg::N_LANES-1];
    logic        mem_valid [0:gpu_pkg::N_LANES-1]; // now consumed by core.sv's scheduler to drive stall; cpu.sv/pc.sv themselves still don't read it directly

    // ------------------------------------------------------------------
    // core <-> data_buffer: one element port per lane, banked (not arbitrated
    // down to one winner per cycle the way the shared_mem ports above are)
    // ------------------------------------------------------------------
    logic [31:0] dt_idx   [0:gpu_pkg::N_LANES-1];
    logic        dt_read  [0:gpu_pkg::N_LANES-1];
    logic        dt_write [0:gpu_pkg::N_LANES-1];
    logic [31:0] dt_wdata [0:gpu_pkg::N_LANES-1];
    logic [31:0] dt_rdata [0:gpu_pkg::N_LANES-1];
    logic        dt_valid [0:gpu_pkg::N_LANES-1];

    // display_controller <-> the two image stores. It emits both forms of the
    // same request -- disp_addr (byte address, for shared_mem's packed-byte
    // layout) and disp_pixel (element index, for the buffer's one-word-per-
    // pixel layout) -- and the mux below decides whose answer it gets back.
    logic [31:0] disp_addr;
    logic [31:0] disp_rdata;
    logic [31:0] disp_pixel;
    logic [31:0] disp_mem_rdata;
    logic [31:0] disp_dt_rdata;

    core u_core (.*);

    shared_mem #(
        .N_THREADS      (gpu_pkg::N_LANES),
        .PROG_INIT_FILE (PROG_INIT_FILE),
        .IMG_INIT_FILE  (IMG_INIT_FILE)
    ) u_shared_mem (.*, .disp_rdata(disp_mem_rdata));

    data_buffer #(
        .N_THREADS (gpu_pkg::N_LANES),
        .WORDS     (gpu_pkg::DBUF_WORDS),
        .INIT_PREFIX (DBUF_INIT_PREFIX)
    ) u_data_buffer (.*);

    // Both stores read every cycle regardless; this only selects which result
    // the controller sees, so switching sources costs a mux, not a rebuild of
    // the addressing logic.
    assign disp_rdata = DISPLAY_FROM_DBUF ? disp_dt_rdata : disp_mem_rdata;

    display_controller u_display_controller (.*);

endmodule : gpu
