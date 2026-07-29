// datamem.sv -- PROVIDED (do not edit). The shared DATA memory for the GPU
// variant: one small array that ALL threads read and write with getdt/setdt.
// A display (or the Pi, over I2C) can scan it out through the scan port, so the
// same array can be viewed as a WIDTH x HEIGHT image.
//
// It is register-backed (flip-flops, not BRAM) so every thread can read/write
// in the same cycle: THREADS combinational read ports + THREADS write ports.
// Writes use a fixed priority (the highest thread index wins if two threads
// hit the SAME vram in the same cycle). The shipped kernels never collide --
// each thread writes only its own row (data[tid*WIDTH + x]) -- so priority is
// moot there; it only keeps an arbitrary setdata(i,v) well-defined.
module datamem #(
    parameter int WIDTH   = 32,
    parameter int HEIGHT  = 32,
    parameter int THREADS = 32,
    parameter int ADDR_W  = 10          // = $clog2(WIDTH*HEIGHT)
) (
    input  logic              clk,
    input  logic              rst,
    input  logic              we    [THREADS],   // per-thread write strobe (setdt)
    input  logic [ADDR_W-1:0] waddr [THREADS],   // per-thread write index
    input  logic [7:0]        wdata [THREADS],   // per-thread write value
    input  logic [ADDR_W-1:0] raddr [THREADS],   // per-thread read index (getdt)
    output logic [7:0]        rdata [THREADS],   // per-thread read value (combinational)
    input  logic [ADDR_W-1:0] scan_addr,         // display / Pi read-back index
    output logic [7:0]        scan_data
);
    logic [7:0] vram [WIDTH*HEIGHT];

    // Combinational read ports: getdt sees the value the same cycle it asks.
    always_comb begin
        for (int t = 0; t < THREADS; t++)
            rdata[t] = vram[raddr[t]];
    end
    assign scan_data = vram[scan_addr];

    always_ff @(posedge clk) begin
        if (rst)
            for (int p = 0; p < WIDTH*HEIGHT; p++) vram[p] <= '0;
        else
            for (int t = 0; t < THREADS; t++)      // fixed priority: last writer wins a tie
                if (we[t]) vram[waddr[t]] <= wdata[t];
    end
endmodule : datamem
