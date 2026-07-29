// ============================================================================
// tmdsEncoder.sv - DVI TMDS 8b/10b Encoder
//
// Per DVI 1.0 spec: transition-minimized encoding with disparity tracking.
// During blanking, outputs control words. During active video, encodes data.
// ============================================================================

module tmdsEncoder (
    input  logic       pixClk,
    input  logic       rst,
    input  logic [7:0] dataIn,
    input  logic       ctrl0,
    input  logic       ctrl1,
    input  logic       dataEn,
    output logic [9:0] tmdsOut
);

    // Count number of 1s in input
    function automatic [3:0] countOnes8(input [7:0] d);
        countOnes8 = 0;
        for (int i = 0; i < 8; i++)
            countOnes8 = countOnes8 + d[i];
    endfunction

    function automatic [3:0] countOnes10(input [9:0] d);
        countOnes10 = 0;
        for (int i = 0; i < 10; i++)
            countOnes10 = countOnes10 + d[i];
    endfunction

    // Stage 1: Minimize transitions (XOR or XNOR chain)
    logic [8:0] qm;
    logic [3:0] nOnes;

    assign nOnes = countOnes8(dataIn);

    always_comb begin
        qm[0] = dataIn[0];
        if (nOnes > 4 || (nOnes == 4 && !dataIn[0])) begin
            // Use XNOR
            for (int i = 1; i < 8; i++)
                qm[i] = qm[i-1] ~^ dataIn[i];
            qm[8] = 1'b0;
        end else begin
            // Use XOR
            for (int i = 1; i < 8; i++)
                qm[i] = qm[i-1] ^ dataIn[i];
            qm[8] = 1'b1;
        end
    end

    // Stage 2: Disparity control
    logic signed [4:0] disparity;
    logic [3:0] nOnesQm, nZerosQm;

    assign nOnesQm  = countOnes8(qm[7:0]);
    assign nZerosQm = 4'd8 - nOnesQm;

    always_ff @(posedge pixClk or posedge rst) begin
        if (rst) begin
            tmdsOut   <= 10'b1101010100; // ctrl 00
            disparity <= '0;
        end else if (!dataEn) begin
            // Control period: output control words, reset disparity
            disparity <= '0;
            case ({ctrl1, ctrl0})
                2'b00: tmdsOut <= 10'b1101010100;
                2'b01: tmdsOut <= 10'b0010101011;
                2'b10: tmdsOut <= 10'b0101010100;
                2'b11: tmdsOut <= 10'b1010101011;
            endcase
        end else begin
            if (disparity == 0 || nOnesQm == nZerosQm) begin
                // No disparity or balanced word
                tmdsOut[9] <= ~qm[8];
                tmdsOut[8] <= qm[8];
                tmdsOut[7:0] <= qm[8] ? qm[7:0] : ~qm[7:0];
                if (!qm[8])
                    disparity <= disparity + signed'({1'b0, nZerosQm}) - signed'({1'b0, nOnesQm});
                else
                    disparity <= disparity + signed'({1'b0, nOnesQm}) - signed'({1'b0, nZerosQm});
            end else begin
                if ((disparity > 0 && nOnesQm > nZerosQm) ||
                    (disparity < 0 && nZerosQm > nOnesQm)) begin
                    // Invert to reduce disparity
                    tmdsOut[9]   <= 1'b1;
                    tmdsOut[8]   <= qm[8];
                    tmdsOut[7:0] <= ~qm[7:0];
                    disparity <= disparity + signed'({1'b0, qm[8], 1'b0})
                                 + signed'({1'b0, nZerosQm})
                                 - signed'({1'b0, nOnesQm});
                end else begin
                    // Don't invert
                    tmdsOut[9]   <= 1'b0;
                    tmdsOut[8]   <= qm[8];
                    tmdsOut[7:0] <= qm[7:0];
                    disparity <= disparity - signed'({1'b0, ~qm[8], 1'b0})
                                 + signed'({1'b0, nOnesQm})
                                 - signed'({1'b0, nZerosQm});
                end
            end
        end
    end

endmodule
