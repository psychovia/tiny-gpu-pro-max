// io_top.sv -- PROVIDED top (set as the Vivado top; reuses top.xdc). You only
// edit cpu.sv. This is the GPU variant: it instantiates THREADS copies of your
// cpu -- one per thread -- each with a different `tid`, all sharing ONE data
// memory (datamem.sv). Every thread runs the SAME program (INIT_FILE); only
// `tid` differs, so they cover different data. BTN0 resets all threads.
//
// The shared data memory is a 32x32 grid you can view as an image. On the board
// we stream its cells across the 7-seg (and light an LED once any cell is
// nonzero) as a "it ran" indicator; the full picture is the simulator's
// --data-image PPM. See ../../doc/GPU_explained.md.
//
// HOW MANY THREADS FIT: each CPU core is LUT-heavy (~7.5k LUTs on the xc7s50, mostly
// the register file), so the *board* runs only a few. Measured on xc7s50csga324-1
// (Vivado 2025.2 synth): THREADS=1 -> 23% LUTs, 2 -> 61%, 4 -> 168% (over), 32 ->
// 1605% (way over). So the default here is 2 -- the most that fits comfortably.
// The FULL 32-thread result is what the Python simulator gives you (--threads 32);
// raise THREADS below only for simulation. Per-thread memory is kept tiny
// (MEM_SIZE_BYTES) so BRAM is never the limit -- the logic is.
module io_top #(
    parameter int THREADS = 2,            // one CPU per thread; 2 is the most that fits (see note)
    parameter int GRID_W  = 32,
    parameter int GRID_H  = 32,
    parameter int DATA_AW = 10            // $clog2(GRID_W*GRID_H) = 10 for 32x32
) (
    input  logic        CLOCK_100,
    input  logic        scl,
    inout  logic        sda,
    input  logic        BTN0,
    output logic [15:0] LD,
    output logic [3:0]  D1_AN,
    output logic [7:0]  D1_SEG,
    output logic [3:0]  D2_AN,
    output logic [7:0]  D2_SEG
);
    logic rst_s;
    Synchronizer u_sync_rst (.async(BTN0), .clock(CLOCK_100), .sync(rst_s));
    assign sda = 1'bz;                    // I2C unused in the GPU demo (open-drain idle)

    // Per-thread wires into the shared data memory.
    logic               th_we    [THREADS];
    logic [DATA_AW-1:0] th_waddr [THREADS];
    logic [7:0]         th_wdata [THREADS];
    logic [DATA_AW-1:0] th_raddr [THREADS];
    logic [7:0]         th_rdata [THREADS];

    genvar i;
    generate
        for (i = 0; i < THREADS; i++) begin : g_thread
            cpu #(.MEM_SIZE_BYTES(4096), .DATA_AW(DATA_AW),
                  .INIT_FILE("mems/gpu_draw.mem")) u_cpu (
                .clk(CLOCK_100), .rst(rst_s),
                .tid(i[31:0]),
                // GPU kernels use setdt/getdt, not ecall -- tie the mailbox off.
                .rx_empty(1'b1), .rx_data(8'h00), .rx_pop(),
                .tx_full(1'b1), .tx_data(), .tx_push(),
                .dt_we(th_we[i]), .dt_addr(th_waddr[i]), .dt_wdata(th_wdata[i]),
                .dt_raddr(th_raddr[i]), .dt_rdata(th_rdata[i])
            );
        end
    endgenerate

    logic [DATA_AW-1:0] scan_addr;
    logic [7:0]         scan_data;

    datamem #(.WIDTH(GRID_W), .HEIGHT(GRID_H), .THREADS(THREADS), .ADDR_W(DATA_AW)) u_data (
        .clk(CLOCK_100), .rst(rst_s),
        .we(th_we), .waddr(th_waddr), .wdata(th_wdata),
        .raddr(th_raddr), .rdata(th_rdata),
        .scan_addr(scan_addr), .scan_data(scan_data)
    );

    // Slowly sweep the whole grid so the 7-seg streams the image's cells, and
    // latch "some cell is nonzero" once we've seen it (a simple did-it-run LED).
    logic [25:0] sweep = '0;
    always_ff @(posedge CLOCK_100) sweep <= sweep + 1'b1;
    assign scan_addr = sweep[25:26-DATA_AW];   // top DATA_AW bits: cycles 0..1023

    logic any_nonzero = 1'b0;
    always_ff @(posedge CLOCK_100)
        if (rst_s)                any_nonzero <= 1'b0;
        else if (scan_data != '0) any_nonzero <= 1'b1;

    logic [26:0] hb = '0;
    always_ff @(posedge CLOCK_100) hb <= hb + 1'b1;
    assign LD[0]    = any_nonzero;
    assign LD[14:1] = '0;
    assign LD[15]   = hb[26];

    function automatic logic [6:0] hex7(input logic [3:0] n);
        case (n)
            4'h0: hex7 = 7'h3F; 4'h1: hex7 = 7'h06; 4'h2: hex7 = 7'h5B; 4'h3: hex7 = 7'h4F;
            4'h4: hex7 = 7'h66; 4'h5: hex7 = 7'h6D; 4'h6: hex7 = 7'h7D; 4'h7: hex7 = 7'h07;
            4'h8: hex7 = 7'h7F; 4'h9: hex7 = 7'h6F; 4'hA: hex7 = 7'h77; 4'hB: hex7 = 7'h7C;
            4'hC: hex7 = 7'h39; 4'hD: hex7 = 7'h5E; 4'hE: hex7 = 7'h79; 4'hF: hex7 = 7'h71;
        endcase
    endfunction

    // 7-seg shows the current swept cell's value (two hex digits).
    logic [16:0] refresh = '0;
    always_ff @(posedge CLOCK_100) refresh <= refresh + 1'b1;
    wire       sel = refresh[16];
    wire [3:0] nib = sel ? scan_data[7:4] : scan_data[3:0];
    assign D1_SEG = {1'b1, ~hex7(nib)};
    assign D1_AN  = sel ? 4'b1101 : 4'b1110;
    assign D2_AN  = 4'b1111;
    assign D2_SEG = 8'hFF;

endmodule : io_top
