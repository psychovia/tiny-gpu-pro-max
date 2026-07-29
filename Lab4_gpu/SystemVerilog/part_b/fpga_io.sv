// fpga_io.sv -- PROVIDED. Synchronizer, the two-way I2C target, and io_bridge
// (register decode over two `fifo` buffers). You implement `fifo` in fifo.sv.

module Synchronizer
    (input  logic async, clock,
     output logic sync);

    logic temp;
    always_ff @(posedge clock) begin
        temp <= async;
        sync <= temp;
    end
endmodule : Synchronizer


// Two-way I2C target at 0x50. Captures write bytes (data, ready) and, on a read
// transaction, shifts out rd_data (rd_load strobes each byte consumed). addr_match
// pulses when an address byte addressed to us completes; is_read is its R/W bit.
module i2c_target (
    input  logic       clk,
    input  logic       scl,
    input  logic       sda,
    output logic       drive_sda,
    output logic [7:0] data,
    output logic       ready,
    output logic       addr_match,
    output logic       is_read,
    input  logic [7:0] rd_data,
    output logic       rd_load
);
    localparam logic [6:0] I2C_ADDR = 7'h50;

    logic scl_prev, sda_prev;
    logic scl_rising, scl_falling;
    logic sda_rising, sda_falling;

    always_comb begin : scl_edge_detector
        scl_rising = 0;
        scl_falling = 0;
        if(scl_prev == 1'b0 && scl == 1'b1) scl_rising = 1;
        else if(scl_prev == 1'b1 && scl == 1'b0) scl_falling = 1;
    end

    always_ff @( posedge clk ) begin : scl_follower
        scl_prev <= scl;
    end

    always_comb begin : sda_edge_detector
        sda_rising = 0;
        sda_falling = 0;
        if(sda_prev == 1'b0 && sda == 1'b1) sda_rising = 1;
        else if(sda_prev == 1'b1 && sda == 1'b0) sda_falling = 1;
    end

    always_ff @( posedge clk ) begin : sda_follower
        sda_prev <= sda;
    end

    logic start, stop, full_byte;
    logic [3:0] data_counter = 4'b0000;
    logic [7:0] data_shift_register;
    logic       addr_done = 1'b0;
    logic       selected  = 1'b0;
    logic       rw        = 1'b0;   // latched R/W bit of the address (is_read is combinational)

    always_comb begin : start_stop_fullbyte_detector
        start = sda_falling & scl;
        stop  = sda_rising & scl;
        full_byte = (data_counter == 4'b1000);
    end

    logic address_detected;

    always_comb begin : address_detector
        address_detected = (data_shift_register[7:1] == I2C_ADDR);
        is_read = data_shift_register[0];
    end

    logic store_data;
    assign store_data = selected & full_byte & addr_done & ~rw;

    always_ff @(posedge clk) begin : data_capture
        if(start) begin
            data_counter <= 4'b0000;
            addr_done    <= 1'b0;
            selected     <= 1'b0;   // drop any prior selection; re-asserted only on a 0x50 match
        end
        if(scl_rising) begin
            data_counter <= data_counter + 1;
            if(full_byte) begin
                if(store_data) data <= data_shift_register;
                data_counter <= 4'b0000;
                addr_done    <= 1'b1;
                if(selected & addr_done & rw & sda) selected <= 1'b0;   // controller NAK
            end
            else if(~addr_done | (selected & ~rw))
                data_shift_register <= (data_shift_register << 1) | sda;
        end
        if(full_byte & address_detected & ~addr_done) begin
            selected <= 1'b1;
            rw       <= data_shift_register[0];
        end
        else if(stop) selected <= 1'b0;
        if(stop) addr_done <= 1'b0;

        ready      <= scl_rising & store_data;
        addr_match <= scl_rising & full_byte & ~addr_done & address_detected;
    end

    // Drive SDA on the falling edge: ACK address/write bytes, shift out read bytes.
    logic       ack = 1'b0;
    logic [7:0] tx_shift_register;
    always_ff @(posedge clk) begin : sda_driver
        rd_load <= 1'b0;
        if(scl_falling) begin
            if(selected & addr_done & rw) begin
                if(full_byte) ack <= 1'b0;                       // release for controller ACK
                else if(data_counter == 4'b0000) begin
                    tx_shift_register <= rd_data;
                    ack               <= ~rd_data[7];
                    rd_load           <= 1'b1;
                end
                else begin
                    ack               <= ~tx_shift_register[6];
                    tx_shift_register <= (tx_shift_register << 1);
                end
            end
            else ack <= (full_byte & selected);
        end
    end
    assign drive_sda = ack;

endmodule : i2c_target


// Register decode over two `fifo`s, sitting between the I2C target and the CPU.
// The Pi drives only the OUTER ends over I2C; the CPU drives the INNER ends:
//   0x00 STATUS  bit0 rx_empty bit1 rx_full bit2 tx_empty bit3 tx_full bit4 overflow
//   0x01 RX  Pi write = push (feed the CPU's getchar)
//   0x02 TX  Pi read  = pop  (read the CPU's putchar)
//   0x03 RXCOUNT          0x04 TXCOUNT
// CPU side: it pops rx (getchar) and pushes tx (putchar) -- wired up in io_top.
module io_bridge (
    input  logic       clk,
    input  logic       rst,
    input  logic [7:0] data,
    input  logic       ready,
    input  logic       addr_match,
    input  logic       is_read,
    output logic [7:0] rd_data,
    input  logic       rd_load,
    // CPU mailbox: the CPU consumes rx (pop) and produces tx (push).
    output logic       rx_empty,
    output logic [7:0] rx_data,
    input  logic       rx_pop,
    output logic       tx_full,
    input  logic [7:0] tx_data,
    input  logic       tx_push,
    // board debug
    output logic [7:0] dbg_last,
    output logic [7:0] dbg_rx_count,
    output logic [7:0] dbg_tx_count,
    output logic       dbg_overflow
);
    localparam logic [7:0] REG_STATUS  = 8'h00;
    localparam logic [7:0] REG_RX      = 8'h01;
    localparam logic [7:0] REG_TX      = 8'h02;
    localparam logic [7:0] REG_RXCOUNT = 8'h03;
    localparam logic [7:0] REG_TXCOUNT = 8'h04;

    logic       expect_ptr = 1'b1;
    logic [7:0] reg_ptr    = REG_STATUS;

    always_ff @(posedge clk) begin : pointer_tracker
        if(addr_match & ~is_read) expect_ptr <= 1'b1;
        else if(ready & expect_ptr) begin
            reg_ptr    <= data;
            expect_ptr <= 1'b0;
        end
    end

    // Pi drives the outer ends only: write RX = push rx, read TX = pop tx.
    logic pi_rx_push, pi_tx_pop;
    assign pi_rx_push = ready   & ~expect_ptr & (reg_ptr == REG_RX);
    assign pi_tx_pop  = rd_load & (reg_ptr == REG_TX);

    logic       rx_full, rx_overflow;
    logic [7:0] rx_rdata, rx_count;
    logic       tx_empty, tx_overflow;
    logic [7:0] tx_rdata, tx_count;

    // rx: Pi pushes (input), CPU pops (getchar).
    fifo rx_fifo (.clk, .rst, .push(pi_rx_push), .wdata(data), .full(rx_full),
                  .pop(rx_pop), .rdata(rx_rdata), .empty(rx_empty),
                  .count(rx_count), .overflow(rx_overflow));
    assign rx_data = rx_rdata;

    // tx: CPU pushes (putchar), Pi pops (output).
    fifo tx_fifo (.clk, .rst, .push(tx_push), .wdata(tx_data), .full(tx_full),
                  .pop(pi_tx_pop), .rdata(tx_rdata), .empty(tx_empty),
                  .count(tx_count), .overflow(tx_overflow));

    logic [7:0] status;
    always_comb begin : status_byte
        status = 8'b0;
        status[0] = rx_empty;
        status[1] = rx_full;
        status[2] = tx_empty;
        status[3] = tx_full;
        status[4] = rx_overflow | tx_overflow;
    end

    always_comb begin : read_mux
        case(reg_ptr)
            REG_RX:      rd_data = rx_empty ? 8'h00 : rx_rdata;
            REG_TX:      rd_data = tx_empty ? 8'h00 : tx_rdata;
            REG_STATUS:  rd_data = status;
            REG_RXCOUNT: rd_data = rx_count;
            REG_TXCOUNT: rd_data = tx_count;
            default:     rd_data = 8'hFF;
        endcase
    end

    logic [7:0] last_byte = 8'h00;
    always_ff @(posedge clk) begin : last_byte_tracker
        if(pi_rx_push)   last_byte <= data;      // last byte the Pi fed in
        else if(tx_push) last_byte <= tx_data;   // last byte the CPU sent out
    end

    assign dbg_last     = last_byte;
    assign dbg_rx_count = rx_count;
    assign dbg_tx_count = tx_count;
    assign dbg_overflow = rx_overflow | tx_overflow;

endmodule : io_bridge
