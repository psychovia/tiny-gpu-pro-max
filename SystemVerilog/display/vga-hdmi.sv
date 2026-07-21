/**
copied from lab3 lol

display_controller => vga-hdmi IP (thia file) => pins on FPGA

VESA 800x600 @60Hz timing on a 40MHz pixel clock: 1056 columns/row (800
visible + sync/porches), 628 rows/frame (600 visible + sync/porches).
NOTE: display_controller.sv currently assumes SCREEN_WIDTH=640,
SCREEN_HEIGHT=480 -- that doesn't match what this module actually
generates (row/col range up to 599/799, not 479/639). The fix belongs in
display_controller.sv's parameters, not here -- these constants are an
internally-consistent, tuned timing spec, not something to edit casually.
**/

module vga
    (input logic clock_40MHz, reset,
    output logic HS, VS, blank,          // sync pulses + "don't draw" signal, sent out to the HDMI IP
    output logic [9:0] row, col,         // current pixel position within the 800x600 visible area (0 outside it)
    output logic frame_complete);        // pulses for one cycle on the very last pixel of a frame

    logic [10:0] col_count;   // raw column counter, 0..1055 (whole scan line incl. sync/porches)
    logic [9:0] row_count;    // raw row counter, 0..627 (whole frame incl. sync/porches)
    logic line_done, frame_done;  // line_done: at last column this row. frame_done: at last row (only means "whole frame over" once line_done is ALSO true)

    logic hen, hcl, ven, vcl;   // counter control: h/v-"enable" (count up) and h/v-"clear" (reset to 0)

    logic hsync, hdisp, vsync, vdisp;  // hsync/vsync: currently inside the sync pulse window. hdisp/vdisp: currently inside the visible (displayable) window

    logic [10:0] actual_col;   // col_count re-based to 0 at the start of the visible window
    logic [9:0] actual_row;    // row_count re-based to 0 at the start of the visible window

    // free-running counters: col_counter ticks every cycle (once enabled),
    // wrapping back to 0 whenever hcl/vcl pulses
    Counter #(.WIDTH(11)) col_counter (.en(hen), .clear(hcl),
                .clk(clock_40MHz), .load(1'b0), .up(1'b1), .D(11'd0),
                .Q(col_count));
    Counter #(.WIDTH(10)) row_counter (.en(ven), .clear(vcl),
                .clk(clock_40MHz), .load(1'b0), .up(1'b1), .D(10'd0),
                .Q(row_count));

    // "have we reached the last column/row of the total (1056/628) count"
    Comparator #(.WIDTH(11)) col_comp (.A(col_count),
                .B(11'd1055), .AeqB(line_done));
    Comparator #(.WIDTH(10)) row_comp (.A(row_count),
                .B(10'd627), .AeqB(frame_done));

    // Make frame_complete pulse when we're at the last counts
    assign frame_complete = (row_count == 10'd627 && col_count == 1055);

    // is col_count currently inside the horizontal sync pulse (cols 0-127)?
    RangeCheck #(.WIDTH(11)) hsync_check (.high(11'd127), .low(11'd0),
                .val(col_count), .is_between(hsync));
    // is col_count currently inside the visible 800-wide window (cols 216-1015)?
    RangeCheck #(.WIDTH(11)) hdisp_check (.high(11'd1015), .low(11'd216),
                .val(col_count), .is_between(hdisp));
    // is row_count currently inside the vertical sync pulse (rows 0-3)?
    RangeCheck #(.WIDTH(10)) vsync_check (.high(10'd3), .low(10'd0),
                .val(row_count), .is_between(vsync));
    // is row_count currently inside the visible 600-tall window (rows 27-626)?
    RangeCheck #(.WIDTH(10)) vdisp_check (.high(10'd626), .low(10'd27),
                .val(row_count), .is_between(vdisp));

    // convert the raw counter position into a 0-based coordinate within
    // the visible window (e.g. col_count=216 -> actual_col=0)
    Subtracter #(.WIDTH(11)) col_sub (.A(col_count), .B(11'd216),
                .bin(1'b0), .bout(), .diff(actual_col));
    Subtracter #(.WIDTH(10)) row_sub (.A(row_count), .B(10'd27),
                .bin(1'b0), .bout(), .diff(actual_row));

    // only output the real coordinate while inside the visible window;
    // report 0 the rest of the time (sync/porch periods -- not real pixels)
    Mux2to1 #(.WIDTH(10)) col_mux (.I0(10'd0), .I1(actual_col[9:0]),
                .S(hdisp), .Y(col));
    Mux2to1 #(.WIDTH(10)) row_mux (.I0(10'd0), .I1(actual_row),
                .S(vdisp), .Y(row));

    // active-low sync pulses out to the HDMI IP; blank whenever we're
    // outside EITHER the horizontal or vertical visible window
    assign HS = ~hsync;
    assign VS = ~vsync;
    assign blank = ~(hdisp && vdisp);

    // simple 2-state FSM purely to gate reset: idle while held in reset,
    // run once reset releases (counters only ever count in the run state)
    enum logic {idle, run} currState, nextState;

    always_comb begin
        unique case(currState)
            idle: begin
                if (!reset)
                    nextState = run;
                else
                    nextState = idle;
            end
            run: begin
                if (reset)
                    nextState = idle;
                else
                    nextState = run;
            end
        endcase
    end

    // counter control logic: decides every cycle whether to count up or
    // reset each counter, based on state + line_done/frame_done
    always_comb begin
        // Default values
        hen = 1'b0;
        ven = 1'b0;
        hcl = 1'b0;
        vcl = 1'b0;

        unique case(currState)
            idle: begin
                // held in reset -- keep both counters cleared, don't count
                if (~reset) begin
                    hen = 1'b0;
                    ven = 1'b0;
                    hcl = 1'b1;
                    vcl = 1'b1;
                end
            end
            run: begin

               if (reset) begin
                    // reset asserted mid-run -- clear both counters
                    hen = 1'b0;
                    ven = 1'b0;
                    hcl = 1'b1;
                    vcl = 1'b1;
               end
                else if (frame_done & line_done) begin
                    // last column of the last row -- whole frame just
                    // finished, wrap both counters back to 0 for the next frame
                    hen = 1'b0;
                    ven = 1'b0;
                    hcl = 1'b1;
                    vcl = 1'b1;
                end
                else if (line_done) begin
                    // last column of this row (but not the last row) --
                    // reset column count to 0, bump row count by 1
                    hen = 1'b0;
                    ven = 1'b1;
                    hcl = 1'b1;
                    vcl = 1'b0;
                end

                else begin
                    // normal case: just keep counting across the current row
                    hen = 1'b1;
                    ven = 1'b0;
                    hcl = 1'b0;
                    vcl = 1'b0;
                end
            end
        endcase
    end

    always_ff @(posedge clock_40MHz) begin
        if (reset)
            currState <= idle;
        else
            currState <= nextState;
    end

endmodule : vga