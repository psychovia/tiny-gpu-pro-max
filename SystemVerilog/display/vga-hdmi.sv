/**
copied from lab3 lol

display_controller => vga-hdmi IP (thia file) => pins on FPGA

**/

module vga
    (input logic clock_40MHz, reset,
    output logic HS, VS, blank,
    output logic [9:0] row, col,
    output logic frame_complete);

    logic [10:0] col_count;
    logic [9:0] row_count;
    logic line_done, frame_done;

    logic hen, hcl, ven, vcl; 

    logic hsync, hdisp, vsync, vdisp;

    logic [10:0] actual_col;
    logic [9:0] actual_row; 

    Counter #(.WIDTH(11)) col_counter (.en(hen), .clear(hcl), 
                .clk(clock_40MHz), .load(1'b0), .up(1'b1), .D(11'd0), 
                .Q(col_count));
    Counter #(.WIDTH(10)) row_counter (.en(ven), .clear(vcl), 
                .clk(clock_40MHz), .load(1'b0), .up(1'b1), .D(10'd0), 
                .Q(row_count));
    
    Comparator #(.WIDTH(11)) col_comp (.A(col_count), 
                .B(11'd1055), .AeqB(line_done));
    Comparator #(.WIDTH(10)) row_comp (.A(row_count), 
                .B(10'd627), .AeqB(frame_done));
    
    // Make frame_complete pulse when we're at the last counts
    assign frame_complete = (row_count == 10'd627 && col_count == 1055); 
    
    RangeCheck #(.WIDTH(11)) hsync_check (.high(11'd127), .low(11'd0), 
                .val(col_count), .is_between(hsync));
    RangeCheck #(.WIDTH(11)) hdisp_check (.high(11'd1015), .low(11'd216), 
                .val(col_count), .is_between(hdisp));
    RangeCheck #(.WIDTH(10)) vsync_check (.high(10'd3), .low(10'd0), 
                .val(row_count), .is_between(vsync));
    RangeCheck #(.WIDTH(10)) vdisp_check (.high(10'd626), .low(10'd27), 
                .val(row_count), .is_between(vdisp));

    Subtracter #(.WIDTH(11)) col_sub (.A(col_count), .B(11'd216), 
                .bin(1'b0), .bout(), .diff(actual_col));
    Subtracter #(.WIDTH(10)) row_sub (.A(row_count), .B(10'd27), 
                .bin(1'b0), .bout(), .diff(actual_row));

    Mux2to1 #(.WIDTH(10)) col_mux (.I0(10'd0), .I1(actual_col[9:0]), 
                .S(hdisp), .Y(col));
    Mux2to1 #(.WIDTH(10)) row_mux (.I0(10'd0), .I1(actual_row), 
                .S(vdisp), .Y(row));

    assign HS = ~hsync;
    assign VS = ~vsync;
    assign blank = ~(hdisp && vdisp);

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

    always_comb begin 
        // Default values
        hen = 1'b0;
        ven = 1'b0;
        hcl = 1'b0;
        vcl = 1'b0;
        
        unique case(currState)
            idle: begin
                if (!reset) begin
                    hen = 1'b0;
                    ven = 1'b0;
                    hcl = 1'b1;
                    vcl = 1'b1;
                end
            end
            run: begin
            
               if (reset) begin
                    hen = 1'b0;
                    ven = 1'b0;
                    hcl = 1'b1;
                    vcl = 1'b1;
               end
               else if (frame_done && line_done) begin
                    hen = 1'b0;
                    ven = 1'b0;
                    hcl = 1'b1;
                    vcl = 1'b1;
                end
                else if (line_done) begin
                    hen = 1'b0;
                    ven = 1'b1;
                    hcl = 1'b1;
                    vcl = 1'b0;
                end
           
                else begin
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