/**
decoder
- decode fetched instruction into control signal for thread execution
**/

module decoder (
    input logic [31:0] instr,
    output logic [6:0] opcode,
    output logic [4:0] rd, rs1, rs2,
    output logic [2:0] funct3,
    output logic [6:0] funct7,
    output logic [31:0] imm
);

    // imm logic
    always_comb begin
        case(opcode)
            // i-type, jalr
            7'b0010011, 7'b0000011, 7'b1100111: imm = {{20{instr[31]}}, instr[31:20]};
            // s-type, b-type
            7'b0100011: imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};
            // b-type
            7'b1100011: imm = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
            // u-type: lui, auipc
            7'b0110111, 7'b0010111: imm = {instr[31:12], 12'd0};
            // j-type: jump, jal
            7'b1101111: imm = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};
            default: imm = 32'd0;
        endcase
    end

    assign opcode = instr[6:0];
    assign rd = instr[11:7];
    assign funct3 = instr[14:12];
    assign rs1 = instr[19:15];
    assign rs2 = instr[24:20];
    assign funct7 = instr[31:25];

endmodule