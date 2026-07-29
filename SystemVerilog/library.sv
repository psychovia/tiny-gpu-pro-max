//library.sv

module Counter 
    #(parameter WIDTH = 10)
    (input logic clk, en, clear, load, up, 
     input logic [WIDTH-1:0] D,
     output logic [WIDTH-1:0] Q);

    always_ff @(posedge clk) begin  
        if (clear)
            Q <= '0;
        else if (load)
            Q <= D;
        else if (en)
            if (up)
                Q <= Q + 1;
            else 
                Q <= Q - 1;
    end

endmodule : Counter

module Comparator
    #(parameter WIDTH = 4)
    (input logic [WIDTH-1:0] A, B,
     output logic AeqB);

    always_comb begin
        AeqB = (A == B); 
    end

endmodule : Comparator

// rangeCheck
module RangeCheck
    #(parameter WIDTH = 4)
    (input logic [WIDTH-1:0] high, low, val,
    output logic is_between);
    
    always_comb begin
        is_between = (val >= low) && (val <= high);  
    end
    
endmodule : RangeCheck

module Subtracter
    #(parameter WIDTH = 4)
    (input logic bin,
     input logic [WIDTH-1:0] A, B,
     output logic bout,
     output logic [WIDTH-1:0] diff);

    logic [WIDTH-1:0] B_twos;
    logic [WIDTH:0] temp_result;

    assign B_twos = ~B;
    assign temp_result = A + B_twos + ~bin;
    assign diff = temp_result[WIDTH-1:0];
    assign bout = ~temp_result[WIDTH];

endmodule : Subtracter

module Mux2to1
    #(parameter WIDTH = 8)
    (input logic [WIDTH-1:0] I0, I1, 
     input logic S,
     output logic [WIDTH-1:0] Y);

    always_comb begin
        Y = S ? I1 : I0;  
    end

endmodule : Mux2to1

module Counter_5
    #(parameter WIDTH = 10)
    (input logic clk, en, clear, load, up,
     input logic [WIDTH-1:0] D,
     output logic [WIDTH-1:0] Q);

    always_ff @(posedge clk) begin
        if (clear)
            Q <= '0;
        else if (load)
            Q <= D;
        else if (en)
            if (up)
                Q <= Q + 5;  
            else 
                Q <= Q - 5;
    end

endmodule : Counter_5

module Counter_2
    #(parameter WIDTH = 10)
    (input logic clk, en, clear, load, up,
     input logic [WIDTH-1:0] D,
     output logic [WIDTH-1:0] Q);

    always_ff @(posedge clk) begin
        if (clear)
            Q <= '0;
        else if (load)
            Q <= D;
        else if (en)
            if (up)
                Q <= Q + 2;  
            else 
                Q <= Q - 2;
    end

endmodule : Counter_2

module Synchronizer
    (input logic async, clock,
    output logic sync);

    logic temp; 

    always_ff @(posedge clock) begin
        temp <= async;
        sync <= temp;
    end

endmodule : Synchronizer

module areaCheck
   (input logic [9:0] x, y, length, height, row, col,
   output logic is_in);

   assign is_in = (col >= x) && (col < x + length) &&
                  (row >= y) && (row < y + height);

endmodule: areaCheck


module Counter_any
    #(parameter WIDTH = 10)
    (input logic clk, en, clear, load, up,
     input logic [WIDTH-1:0] D,
     input logic [3:0]   inc,
     output logic [WIDTH-1:0] Q);

    always_ff @(posedge clk) begin
        if (clear)
            Q <= '0;
        else if (load)
            Q <= D;
        else if (en)
            if (up)
                Q <= Q + inc; 
            else
                Q <= Q - inc;
    end

endmodule : Counter_any