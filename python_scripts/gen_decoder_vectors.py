#!/usr/bin/env python3
"""
gen_decoder_vectors.py -- emit testbenches/decoder_vectors.svh.

Each vector is an encode/decode round-trip: rvasm.py encodes an instruction
from source text, and the expected decoder outputs listed here come from that
same SOURCE TEXT (the register numbers and the immediate as written), not from
re-slicing the encoded word. So decoder.sv has to recover the operands the
programmer actually wrote.

The immediate columns are the interesting ones -- S, B and J formats scatter
the immediate across non-contiguous instruction bits, and those three shuffles
are the single most error-prone part of a RISC-V decoder. Negative offsets are
included for every one of them so a missing sign-extension cannot pass.

Caveat worth knowing: rvasm.py's encoder and decoder.sv were written
independently, but a *shared* misreading of the spec would still round-trip
cleanly. The behavioural branch/jump tests (test4, test5) are what pin the
immediates to real control flow.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rvasm import assemble, AsmError  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(REPO, "testbenches", "decoder_vectors.svh")

R, I, LD, ST = 0b0110011, 0b0010011, 0b0000011, 0b0100011
B, JAL, JALR = 0b1100011, 0b1101111, 0b1100111
LUI, AUIPC = 0b0110111, 0b0010111

# (name, asm, opcode, rd, rs1, rs2, funct3, funct7, imm)
#
# rd/rs1/rs2 are listed as 0 where the format does not define that field --
# decoder.sv slices them unconditionally, so those columns are "whatever the
# bits happen to be" and are not checked (see USE_MASK below).
VECTORS = [
    # ---- R-type: funct7 is the discriminator ----
    ("add  x1,x2,x3",     "add x1, x2, x3",     R, 1, 2, 3, 0b000, 0b0000000, 0),
    ("sub  x1,x2,x3",     "sub x1, x2, x3",     R, 1, 2, 3, 0b000, 0b0100000, 0),
    ("mul  x1,x2,x3",     "mul x1, x2, x3",     R, 1, 2, 3, 0b000, 0b0000001, 0),
    ("srl  x5,x6,x7",     "srl x5, x6, x7",     R, 5, 6, 7, 0b101, 0b0000000, 0),
    ("sra  x5,x6,x7",     "sra x5, x6, x7",     R, 5, 6, 7, 0b101, 0b0100000, 0),
    ("and  x31,x30,x29",  "and x31, x30, x29",  R, 31, 30, 29, 0b111, 0b0000000, 0),

    # ---- I-type: sign extension of imm[11:0] ----
    ("addi x1,x2,-1",     "addi x1, x2, -1",    I, 1, 2, 0, 0b000, 0, 0xFFFFFFFF),
    ("addi x1,x2,2047",   "addi x1, x2, 2047",  I, 1, 2, 0, 0b000, 0, 2047),
    ("addi x1,x2,-2048",  "addi x1, x2, -2048", I, 1, 2, 0, 0b000, 0, 0xFFFFF800),
    ("andi x3,x4,-16",    "andi x3, x4, -16",   I, 3, 4, 0, 0b111, 0, 0xFFFFFFF0),
    ("slli x1,x2,31",     "slli x1, x2, 31",    I, 1, 2, 0, 0b001, 0b0000000, 31),
    ("srai x1,x2,7",      "srai x1, x2, 7",     I, 1, 2, 0, 0b101, 0b0100000, 0x407),

    # ---- loads (I-type) ----
    ("lw   x9,-4(x10)",   "lw x9, -4(x10)",     LD, 9, 10, 0, 0b010, 0, 0xFFFFFFFC),
    ("lbu  x9,7(x10)",    "lbu x9, 7(x10)",     LD, 9, 10, 0, 0b100, 0, 7),

    # ---- stores (S-type): imm split across [31:25] and [11:7] ----
    ("sw   x5,-4(x6)",    "sw x5, -4(x6)",      ST, 0, 6, 5, 0b010, 0, 0xFFFFFFFC),
    ("sb   x5,1(x6)",     "sb x5, 1(x6)",       ST, 0, 6, 5, 0b000, 0, 1),
    ("sh   x5,2047(x6)",  "sh x5, 2047(x6)",    ST, 0, 6, 5, 0b001, 0, 2047),
    ("sw   x5,-2048(x6)", "sw x5, -2048(x6)",   ST, 0, 6, 5, 0b010, 0, 0xFFFFF800),

    # ---- branches (B-type): imm[12|10:5|4:1|11], always even ----
    ("beq  x1,x2,-8",     "beq x1, x2, -8",     B, 0, 1, 2, 0b000, 0, 0xFFFFFFF8),
    ("bne  x1,x2,+8",     "bne x1, x2, 8",      B, 0, 1, 2, 0b001, 0, 8),
    ("blt  x1,x2,-4096",  "blt x1, x2, -4096",  B, 0, 1, 2, 0b100, 0, 0xFFFFF000),
    ("bgeu x1,x2,+4094",  "bgeu x1, x2, 4094",  B, 0, 1, 2, 0b111, 0, 4094),

    # ---- jal (J-type): imm[20|10:1|11|19:12] ----
    ("jal  x1,-16",       "jal x1, -16",        JAL, 1, 0, 0, 0, 0, 0xFFFFFFF0),
    ("jal  x0,+2048",     "jal x0, 2048",       JAL, 0, 0, 0, 0, 0, 2048),
    ("jal  x1,-1048576",  "jal x1, -1048576",   JAL, 1, 0, 0, 0, 0, 0xFFF00000),

    # ---- jalr (I-type) ----
    ("jalr x1,x2,-1",     "jalr x1, x2, -1",    JALR, 1, 2, 0, 0b000, 0, 0xFFFFFFFF),

    # ---- U-type: imm[31:12], low 12 bits zeroed ----
    ("lui   x3,0xABCDE000",   "lui x3, 0xABCDE000",   LUI,   3, 0, 0, 0, 0, 0xABCDE000),
    ("auipc x4,0x00001000",   "auipc x4, 0x1000",     AUIPC, 4, 0, 0, 0, 0, 0x00001000),
    ("lui   x3,0xFFFFF000",   "lui x3, 0xFFFFF000",   LUI,   3, 0, 0, 0, 0, 0xFFFFF000),
]

# Which columns are meaningful per format. decoder.sv slices rd/rs1/rs2/funct3/
# funct7 out of fixed bit positions regardless of opcode, so for formats that
# do not define a field those bits carry immediate data and must not be checked.
FIELD_RD, FIELD_RS1, FIELD_RS2, FIELD_F3, FIELD_F7 = 1, 2, 4, 8, 16
USE_MASK = {
    R:     FIELD_RD | FIELD_RS1 | FIELD_RS2 | FIELD_F3 | FIELD_F7,
    I:     FIELD_RD | FIELD_RS1 | FIELD_F3,
    LD:    FIELD_RD | FIELD_RS1 | FIELD_F3,
    ST:    FIELD_RS1 | FIELD_RS2 | FIELD_F3,
    B:     FIELD_RS1 | FIELD_RS2 | FIELD_F3,
    JAL:   FIELD_RD,
    JALR:  FIELD_RD | FIELD_RS1 | FIELD_F3,
    LUI:   FIELD_RD,
    AUIPC: FIELD_RD,
}
# slli/srai encode funct7 inside the immediate; check it for those two.
SHIFT_IMM_NAMES = {"slli x1,x2,31", "srai x1,x2,7"}


def main():
    rows = []
    for name, asm, opcode, rd, rs1, rs2, f3, f7, imm in VECTORS:
        try:
            words, _ = assemble(asm)
        except AsmError as exc:
            print(f"gen_decoder_vectors: {exc}", file=sys.stderr)
            return 1
        if len(words) != 1:
            print(f"gen_decoder_vectors: '{asm}' assembled to {len(words)} words",
                  file=sys.stderr)
            return 1
        mask = USE_MASK[opcode]
        if name in SHIFT_IMM_NAMES:
            mask |= FIELD_F7
        rows.append((name, words[0], opcode, rd, rs1, rs2, f3, f7, imm, mask))

    def col(decl, values, comment_from=None):
        out = [f"{decl} = '{{"]
        for i, v in enumerate(values):
            comma = "," if i < len(values) - 1 else ""
            note = f"  // {rows[i][0]}" if comment_from else ""
            out.append(f"    {v}{comma}{note}")
        out.append("};")
        out.append("")
        return out

    lines = [
        "// decoder_vectors.svh -- GENERATED by python_scripts/gen_decoder_vectors.py",
        "// Do not edit by hand; edit the VECTORS table in that script and re-run it.",
        "//",
        "// Each row is an encode/decode round-trip: the instruction word was",
        "// produced by rvasm.py from the source text in DVEC_NAME, and the expected",
        "// fields come from that same source text rather than from re-slicing the",
        "// word. DVEC_MASK marks which fields the format actually defines --",
        "// decoder.sv slices rd/rs1/rs2 unconditionally, so for e.g. a store the",
        "// `rd` bits hold immediate data and are not checked.",
        "//",
        "// These are parallel unpacked arrays rather than one array of packed",
        "// structs on purpose: xsim 2025.2 miscompiles",
        "//     localparam some_packed_struct_t ARR [0:N-1] = \'{ ... };",
        "// giving every element the same garbage value instead of the listed one,",
        "// which makes an entire vector table silently collapse to one bogus row.",
        "// Plain vector arrays are handled correctly.",
        "",
        "`ifndef DECODER_VECTORS_SVH",
        "`define DECODER_VECTORS_SVH",
        "",
        "localparam int F_RD = 1, F_RS1 = 2, F_RS2 = 4, F_F3 = 8, F_F7 = 16;",
        f"localparam int N_DVEC = {len(rows)};",
        "",
    ]

    lines += col("logic [31:0] DVEC_INSTR  [0:N_DVEC-1]",
                 [f"32'h{r[1]:08x}" for r in rows], True)
    lines += col("logic [6:0]  DVEC_OPCODE [0:N_DVEC-1]",
                 [f"7'h{r[2]:02x}" for r in rows])
    lines += col("logic [4:0]  DVEC_RD     [0:N_DVEC-1]",
                 [f"5'd{r[3]}" for r in rows])
    lines += col("logic [4:0]  DVEC_RS1    [0:N_DVEC-1]",
                 [f"5'd{r[4]}" for r in rows])
    lines += col("logic [4:0]  DVEC_RS2    [0:N_DVEC-1]",
                 [f"5'd{r[5]}" for r in rows])
    lines += col("logic [2:0]  DVEC_F3     [0:N_DVEC-1]",
                 [f"3'd{r[6]}" for r in rows])
    lines += col("logic [6:0]  DVEC_F7     [0:N_DVEC-1]",
                 [f"7'h{r[7]:02x}" for r in rows])
    lines += col("logic [31:0] DVEC_IMM    [0:N_DVEC-1]",
                 [f"32'h{r[8]:08x}" for r in rows])
    lines += col("logic [5:0]  DVEC_MASK   [0:N_DVEC-1]",
                 [f"6'd{r[9]}" for r in rows])
    lines += col("string       DVEC_NAME   [0:N_DVEC-1]",
                 [f'"{r[0]}"' for r in rows])

    lines += ["`endif", ""]

    with open(OUT, "w") as fh:
        fh.write("\n".join(lines))
    print(f"gen_decoder_vectors: {OUT} ({len(rows)} vectors)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
