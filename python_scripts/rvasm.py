#!/usr/bin/env python3
"""
rvasm.py -- minimal RV32IM assembler for the tiny-gpu-pro-max testbenches.

Emits one 32-character binary line per instruction, which is exactly what
shared_mem.sv's `$readmemb(PROG_INIT_FILE, ...)` expects. Instruction i lands
in mem[PROG_BASE/4 + i], i.e. at byte address 4*i, matching pc reset = 0.

Only the subset of RV32IM that cpu.sv/pc.sv/decoder.sv actually implement is
supported -- if you write an instruction the hardware can't execute, this
assembler rejects it rather than emitting something the design will silently
mis-decode. Notable exclusions: no ecall/ebreak/fence/csr (no opcode support),
no div/rem (cpu.sv's funct7=0000001 case only wires up mul).

Usage:
    rvasm.py input.s output.mem

Syntax:
    label:                  # definition
    addi x1, x0, 5          # instructions; # or // starts a comment
    beq  x1, x2, label      # branches/jumps take labels or raw offsets
    lw   x3, 8(x4)          # load/store offset(base) form

Data-buffer instructions (the image store -- see SystemVerilog/data_buffer.sv):
    rdtid  x5               # x5 = this lane's id (0 .. N_LANES-1)
    getdt  x6, x5           # x6 = dbuf[x5]        -- indexed by ELEMENT, not byte
    setdt  x5, x6           # dbuf[x5] = x6        -- index first, then value

    These reach a separate banked buffer, not main memory: no offset(base)
    form, no alignment rule, and all N_LANES lanes are serviced in one cycle
    when they stride by N_LANES (the `i = tid; i += N_LANES` pattern).

Pseudo-instructions:
    nop             -> addi x0, x0, 0
    mv   rd, rs     -> addi rd, rs, 0
    li   rd, imm    -> addi rd, x0, imm         (12-bit signed only)
                    -> lui + addi                (32-bit, exact)
    not  rd, rs     -> xori rd, rs, -1
    neg  rd, rs     -> sub rd, x0, rs
    j    label      -> jal x0, label
    ret             -> jalr x0, x1, 0
    done            -> addi x31, x0, 1          (the "thread complete" convention)

Register names: x0-x31, plus `tid` for x30 (lane_id, preloaded on reset) and
`flag` for x31 (the done register).
"""

import re
import sys

# ---------------------------------------------------------------------------
# instruction tables -- only what the RTL implements
# ---------------------------------------------------------------------------

# name -> (funct7, funct3)
R_TYPE = {
    "add":  (0b0000000, 0b000),
    "sub":  (0b0100000, 0b000),
    "mul":  (0b0000001, 0b000),
    "sll":  (0b0000000, 0b001),
    "slt":  (0b0000000, 0b010),
    "sltu": (0b0000000, 0b011),
    "xor":  (0b0000000, 0b100),
    "srl":  (0b0000000, 0b101),
    "sra":  (0b0100000, 0b101),
    "or":   (0b0000000, 0b110),
    "and":  (0b0000000, 0b111),
}

# name -> funct3
I_TYPE = {
    "addi":  0b000,
    "slti":  0b010,
    "sltiu": 0b011,
    "xori":  0b100,
    "ori":   0b110,
    "andi":  0b111,
}

# name -> (funct7, funct3) -- immediate shifts encode funct7 in imm[11:5]
I_SHIFT = {
    "slli": (0b0000000, 0b001),
    "srli": (0b0000000, 0b101),
    "srai": (0b0100000, 0b101),
}

LOAD = {"lb": 0b000, "lh": 0b001, "lw": 0b010, "lbu": 0b100, "lhu": 0b101}
STORE = {"sb": 0b000, "sh": 0b001, "sw": 0b010}
BRANCH = {
    "beq":  0b000,
    "bne":  0b001,
    "blt":  0b100,
    "bge":  0b101,
    "bltu": 0b110,
    "bgeu": 0b111,
}
U_TYPE = {"lui": 0b0110111, "auipc": 0b0010111}

OP_R, OP_I, OP_LOAD, OP_STORE = 0b0110011, 0b0010011, 0b0000011, 0b0100011
OP_BRANCH, OP_JAL, OP_JALR = 0b1100011, 0b1101111, 0b1100111

# Data-buffer extension. These share RISC-V's "custom-0" major opcode (0x0B),
# reserved by the spec for exactly this, and are told apart by funct3. Keep in
# lockstep with OPC_GPU / F3_* in SystemVerilog/gpu_pkg.sv.
#
# All three use the R-type field layout, so the register fields land where
# cpu.sv's existing rd/rs1/rs2 wiring already reads them; fields an
# instruction doesn't use are encoded as x0.
#
#   name -> (funct3, operand shape)
# Mnemonics and funct3 values come from Lab4_gpu/doc/custom_instructions.md --
# that toolchain is the authority, so do not "tidy" them here.
OP_GPU = 0b0001011
GPU_TYPE = {
    "rdtid": (0b000, "rd"),       # rdtid rd       -> rd = lane_id
    "setdt": (0b001, "rs1,rs2"),  # setdt rs1, rs2 -> dbuf[rs1] = rs2
    "getdt": (0b010, "rd,rs1"),   # getdt rd, rs1  -> rd = dbuf[rs1]
}

REG_ALIASES = {"tid": 30, "flag": 31}


class AsmError(Exception):
    pass


def parse_reg(tok, lineno):
    tok = tok.strip().lower()
    if tok in REG_ALIASES:
        return REG_ALIASES[tok]
    m = re.fullmatch(r"x(\d+)", tok)
    if not m:
        raise AsmError(f"line {lineno}: '{tok}' is not a register")
    n = int(m.group(1))
    if not 0 <= n <= 31:
        raise AsmError(f"line {lineno}: register x{n} out of range")
    return n


def parse_imm(tok, lineno, labels=None, pc=None, relative=False):
    """Resolve an immediate: decimal, 0x hex, or a label."""
    tok = tok.strip()
    if labels is not None and tok in labels:
        target = labels[tok]
        return target - pc if relative else target
    try:
        return int(tok, 0)
    except ValueError:
        raise AsmError(f"line {lineno}: cannot resolve immediate/label '{tok}'")


def check_range(val, bits, lineno, what, signed=True):
    if signed:
        lo, hi = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    else:
        lo, hi = 0, (1 << bits) - 1
    if not lo <= val <= hi:
        raise AsmError(
            f"line {lineno}: {what} {val} does not fit in {bits} signed bits "
            f"[{lo}, {hi}]"
        )


def bits(val, hi, lo):
    """Extract val[hi:lo] as an int, treating val as two's complement 32-bit."""
    return (val >> lo) & ((1 << (hi - lo + 1)) - 1)


def enc_r(funct7, rs2, rs1, funct3, rd, opcode):
    return (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode


def enc_i(imm, rs1, funct3, rd, opcode):
    return (bits(imm, 11, 0) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode


def enc_s(imm, rs2, rs1, funct3, opcode):
    return (
        (bits(imm, 11, 5) << 25)
        | (rs2 << 20)
        | (rs1 << 15)
        | (funct3 << 12)
        | (bits(imm, 4, 0) << 7)
        | opcode
    )


def enc_b(imm, rs2, rs1, funct3, opcode):
    return (
        (bits(imm, 12, 12) << 31)
        | (bits(imm, 10, 5) << 25)
        | (rs2 << 20)
        | (rs1 << 15)
        | (funct3 << 12)
        | (bits(imm, 4, 1) << 8)
        | (bits(imm, 11, 11) << 7)
        | opcode
    )


def enc_u(imm, rd, opcode):
    # imm is the full 32-bit value; the encoding carries only imm[31:12]
    return (bits(imm, 31, 12) << 12) | (rd << 7) | opcode


def enc_j(imm, rd, opcode):
    return (
        (bits(imm, 20, 20) << 31)
        | (bits(imm, 10, 1) << 21)
        | (bits(imm, 11, 11) << 20)
        | (bits(imm, 19, 12) << 12)
        | (rd << 7)
        | opcode
    )


def strip_comment(line):
    for marker in ("#", "//"):
        idx = line.find(marker)
        if idx != -1:
            line = line[:idx]
    return line.strip()


def split_operands(rest):
    return [t.strip() for t in rest.split(",") if t.strip()]


MEM_OPERAND = re.compile(r"^(-?\w+)\s*\(\s*(\w+)\s*\)$")


def expand_pseudo(mnem, ops, lineno):
    """Return a list of (mnem, ops) real instructions, or None if not pseudo."""
    if mnem == "nop":
        return [("addi", ["x0", "x0", "0"])]
    if mnem == "done":
        return [("addi", ["x31", "x0", "1"])]
    if mnem == "ret":
        return [("jalr", ["x0", "x1", "0"])]
    if mnem == "mv":
        if len(ops) != 2:
            raise AsmError(f"line {lineno}: mv needs 2 operands")
        return [("addi", [ops[0], ops[1], "0"])]
    if mnem == "not":
        return [("xori", [ops[0], ops[1], "-1"])]
    if mnem == "neg":
        return [("sub", [ops[0], "x0", ops[1]])]
    if mnem == "j":
        if len(ops) != 1:
            raise AsmError(f"line {lineno}: j needs 1 operand")
        return [("jal", ["x0", ops[0]])]
    return None


def li_expansion(ops, lineno):
    """li rd, imm -> 1 instruction if it fits in 12 signed bits, else lui+addi."""
    rd = ops[0]
    val = parse_imm(ops[1], lineno) & 0xFFFFFFFF
    signed = val - (1 << 32) if val & 0x80000000 else val
    if -2048 <= signed <= 2047:
        return [("addi", [rd, "x0", str(signed)])]
    # lui takes imm[31:12]; addi's imm is sign-extended, so pre-compensate by
    # rounding the upper half up when bit 11 of the low half is set.
    lo = val & 0xFFF
    lo_signed = lo - 4096 if lo & 0x800 else lo
    hi = (val - lo_signed) & 0xFFFFFFFF
    return [("lui", [rd, hex(hi)]), ("addi", [rd, rd, str(lo_signed)])]


def assemble(text):
    """Two-pass assemble. Returns (words, listing) where listing[i] is source text."""
    # ---- pass 0: tokenize into (lineno, mnem, ops) plus label positions ----
    raw = []
    for lineno, line in enumerate(text.splitlines(), 1):
        line = strip_comment(line)
        while line:
            m = re.match(r"^([A-Za-z_.$][\w.$]*)\s*:", line)
            if not m:
                break
            raw.append((lineno, "__label__", [m.group(1)]))
            line = line[m.end():].strip()
        if not line:
            continue
        parts = line.split(None, 1)
        mnem = parts[0].lower()
        ops = split_operands(parts[1]) if len(parts) > 1 else []
        raw.append((lineno, mnem, ops))

    # ---- pass 1: expand pseudo-instructions, assign addresses ----
    labels = {}
    flat = []  # (lineno, mnem, ops, addr, source_text)
    addr = 0
    for lineno, mnem, ops in raw:
        if mnem == "__label__":
            name = ops[0]
            if name in labels:
                raise AsmError(f"line {lineno}: duplicate label '{name}'")
            labels[name] = addr
            continue
        src = f"{mnem} {', '.join(ops)}".strip()
        if mnem == "li":
            expanded = li_expansion(ops, lineno)
        else:
            expanded = expand_pseudo(mnem, ops, lineno) or [(mnem, ops)]
        for real_mnem, real_ops in expanded:
            flat.append((lineno, real_mnem, real_ops, addr, src))
            addr += 4

    # ---- pass 2: encode ----
    words, listing = [], []
    for lineno, mnem, ops, addr, src in flat:
        words.append(encode(mnem, ops, addr, labels, lineno))
        listing.append((addr, src))
    return words, listing


def encode(mnem, ops, pc, labels, lineno):
    def need(n):
        if len(ops) != n:
            raise AsmError(
                f"line {lineno}: '{mnem}' needs {n} operands, got {len(ops)}"
            )

    if mnem in R_TYPE:
        need(3)
        f7, f3 = R_TYPE[mnem]
        return enc_r(f7, parse_reg(ops[2], lineno), parse_reg(ops[1], lineno),
                     f3, parse_reg(ops[0], lineno), OP_R)

    if mnem in I_TYPE:
        need(3)
        imm = parse_imm(ops[2], lineno)
        check_range(imm, 12, lineno, "immediate")
        return enc_i(imm, parse_reg(ops[1], lineno), I_TYPE[mnem],
                     parse_reg(ops[0], lineno), OP_I)

    if mnem in I_SHIFT:
        need(3)
        f7, f3 = I_SHIFT[mnem]
        shamt = parse_imm(ops[2], lineno)
        if not 0 <= shamt <= 31:
            raise AsmError(f"line {lineno}: shift amount {shamt} out of range 0-31")
        return enc_i((f7 << 5) | shamt, parse_reg(ops[1], lineno), f3,
                     parse_reg(ops[0], lineno), OP_I)

    if mnem in LOAD:
        need(2)
        m = MEM_OPERAND.match(ops[1])
        if not m:
            raise AsmError(f"line {lineno}: expected offset(base), got '{ops[1]}'")
        off = parse_imm(m.group(1), lineno)
        check_range(off, 12, lineno, "load offset")
        return enc_i(off, parse_reg(m.group(2), lineno), LOAD[mnem],
                     parse_reg(ops[0], lineno), OP_LOAD)

    if mnem in STORE:
        need(2)
        m = MEM_OPERAND.match(ops[1])
        if not m:
            raise AsmError(f"line {lineno}: expected offset(base), got '{ops[1]}'")
        off = parse_imm(m.group(1), lineno)
        check_range(off, 12, lineno, "store offset")
        return enc_s(off, parse_reg(ops[0], lineno), parse_reg(m.group(2), lineno),
                     STORE[mnem], OP_STORE)

    if mnem in BRANCH:
        need(3)
        off = parse_imm(ops[2], lineno, labels, pc, relative=True)
        check_range(off, 13, lineno, "branch offset")
        if off % 2:
            raise AsmError(f"line {lineno}: branch offset {off} is not even")
        return enc_b(off, parse_reg(ops[1], lineno), parse_reg(ops[0], lineno),
                     BRANCH[mnem], OP_BRANCH)

    if mnem == "jal":
        need(2)
        off = parse_imm(ops[1], lineno, labels, pc, relative=True)
        check_range(off, 21, lineno, "jal offset")
        return enc_j(off, parse_reg(ops[0], lineno), OP_JAL)

    if mnem == "jalr":
        need(3)
        off = parse_imm(ops[2], lineno)
        check_range(off, 12, lineno, "jalr offset")
        return enc_i(off, parse_reg(ops[1], lineno), 0b000,
                     parse_reg(ops[0], lineno), OP_JALR)

    if mnem in GPU_TYPE:
        f3, shape = GPU_TYPE[mnem]
        if shape == "rd,rs1":       # getdt rd, rs1
            need(2)
            return enc_r(0, 0, parse_reg(ops[1], lineno), f3,
                         parse_reg(ops[0], lineno), OP_GPU)
        if shape == "rs1,rs2":      # setdt rs1, rs2  (index first, then value)
            need(2)
            return enc_r(0, parse_reg(ops[1], lineno), parse_reg(ops[0], lineno),
                         f3, 0, OP_GPU)
        need(1)                     # rdtid rd
        return enc_r(0, 0, 0, f3, parse_reg(ops[0], lineno), OP_GPU)

    if mnem in U_TYPE:
        need(2)
        imm = parse_imm(ops[1], lineno) & 0xFFFFFFFF
        if imm & 0xFFF:
            raise AsmError(
                f"line {lineno}: {mnem} immediate 0x{imm:08x} has nonzero low 12 "
                f"bits; only imm[31:12] is encodable"
            )
        return enc_u(imm, parse_reg(ops[0], lineno), U_TYPE[mnem])

    raise AsmError(
        f"line {lineno}: unsupported instruction '{mnem}' -- either a typo or "
        f"an instruction this design does not implement (see rvasm.py docstring)"
    )


def write_mem(path, words, listing, source_path):
    lines = [
        f"// generated by rvasm.py from {source_path} -- do not edit by hand",
        f"// {len(words)} instructions, loaded at PROG_BASE (byte address 0)",
    ]
    for word, (addr, src) in zip(words, listing):
        lines.append(f"{word:032b} // 0x{addr:04x}: {src}")
    with open(path, "w") as fh:
        fh.write("\n".join(lines) + "\n")


def main(argv):
    if len(argv) != 3:
        print(__doc__)
        return 2
    src_path, out_path = argv[1], argv[2]
    with open(src_path) as fh:
        text = fh.read()
    try:
        words, listing = assemble(text)
    except AsmError as exc:
        print(f"rvasm: {src_path}: {exc}", file=sys.stderr)
        return 1
    if not words:
        print(f"rvasm: {src_path}: no instructions", file=sys.stderr)
        return 1
    write_mem(out_path, words, listing, src_path)
    print(f"rvasm: {src_path} -> {out_path} ({len(words)} instructions, "
          f"{len(words) * 4} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
