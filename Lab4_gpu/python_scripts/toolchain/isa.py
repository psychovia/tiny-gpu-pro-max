"""
isa.py -- Single source of truth for the teaching RISC-V ISA (RV32I + the
M-extension MUL).

Everything else (assembler, simulator, compiler) imports from this file.
If you want to know what an instruction does or how it is encoded, this is
the place to look.

This toolchain targets a deliberately small subset of RV32I + M: enough to
compile and run the C subset the teaching compiler accepts, and small enough
that a freshman can implement every instruction as a simple CPU on an FPGA.

We implement the M-extension MUL but DELIBERATELY OMIT the hardware divide
instructions (div/divu/rem/rem u). C `/` and `%` are lowered by the compiler
to a software routine built from the instructions below -- so the hardware
the students build never needs a divider.

----------------------------------------------------------------------
ARCHITECTURE QUICK REFERENCE
----------------------------------------------------------------------
  Registers
    x0 .. x31   -- 32 general-purpose 32-bit registers (5-bit index)
    x0          -- hardwired to 0; writes are discarded
    pc          -- 32-bit program counter (implicit); always 4-byte aligned
    ABI names accepted by the assembler: zero ra sp gp tp t0-t6 s0-s11
                a0-a7, plus `fp` as an alias for s0 (x8).

  Memory
    Byte-addressable, little-endian.
    Word accesses must be 4-byte aligned; halfword accesses 2-byte aligned.

  Instruction width
    Every instruction is exactly 32 bits. No compressed instructions.

----------------------------------------------------------------------
INSTRUCTION FORMATS (all 32 bits; field bit-positions are fixed)
----------------------------------------------------------------------
  opcode -> [6:0]      rd  -> [11:7]    funct3 -> [14:12]
  rs1    -> [19:15]    rs2 -> [24:20]   funct7 -> [31:25]

  R-type:  funct7[31:25] rs2[24:20] rs1[19:15] funct3[14:12] rd[11:7] opcode
  I-type:  imm[11:0][31:20]         rs1[19:15] funct3[14:12] rd[11:7] opcode
  S-type:  imm[11:5][31:25] rs2[24:20] rs1[19:15] funct3 imm[4:0][11:7] opcode
  B-type:  imm[12|10:5][31:25] rs2 rs1 funct3 imm[4:1|11][11:7] opcode
  U-type:  imm[31:12][31:12]                            rd[11:7] opcode
  J-type:  imm[20|10:1|11|19:12][31:12]                 rd[11:7] opcode

  The scrambled B-type and J-type immediates are the single biggest source
  of encoder bugs -- the encode_B/encode_J/decode functions below are written
  and tested against known-good machine words.
"""


XLEN = 32
MASK_32 = 0xFFFFFFFF


# --------------------------------------------------------------------
# Registers
# --------------------------------------------------------------------

# Index == x-number; the string is the canonical ABI name.
REG_NAMES = [
    "zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
    "s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5",
    "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7",
    "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6",
]

# Extra spellings the assembler accepts (besides the canonical ABI names
# above and the raw xN forms).
REG_ALIASES = {"fp": 8}

_ABI_TO_NUM = {name: i for i, name in enumerate(REG_NAMES)}


def reg_num(name):
    """Convert a register name to its 0..31 index. Accepts xN, ABI names,
    and `fp`. Case-insensitive. Raises ValueError on anything else."""
    n = name.strip().lower()
    if n in _ABI_TO_NUM:
        return _ABI_TO_NUM[n]
    if n in REG_ALIASES:
        return REG_ALIASES[n]
    if len(n) >= 2 and n[0] == "x" and n[1:].isdigit():
        i = int(n[1:])
        if 0 <= i <= 31:
            return i
    raise ValueError(
        "unknown register %r; expected x0..x31 or an ABI name "
        "(zero, ra, sp, gp, tp, t0-t6, s0-s11, a0-a7, fp)" % name
    )


def reg_name(i):
    """Convert a 0..31 index back to its canonical ABI name (e.g. 'a0')."""
    if not 0 <= i < 32:
        raise ValueError("register index %d out of range (must be 0..31)" % i)
    return REG_NAMES[i]


# --------------------------------------------------------------------
# Bit-field helpers (carried over verbatim from the original toolchain)
# --------------------------------------------------------------------

def _check_unsigned(value, bits, field):
    if value < 0 or value >= (1 << bits):
        raise ValueError(
            "%s value %d doesn't fit in %d unsigned bits" % (field, value, bits)
        )
    return value


def _check_signed(value, bits, field):
    """Range-check a signed value and return its two's-complement bit pattern."""
    lo = -(1 << (bits - 1))
    hi = (1 << (bits - 1)) - 1
    if value < lo or value > hi:
        raise ValueError(
            "%s value %d out of range for %d-bit signed immediate [%d, %d]"
            % (field, value, bits, lo, hi)
        )
    return value & ((1 << bits) - 1)


def _sign_extend(value, bits):
    """Sign-extend a `bits`-wide unsigned value to a Python int."""
    sign = 1 << (bits - 1)
    return (value ^ sign) - sign


# --------------------------------------------------------------------
# Opcodes (the 7-bit major opcodes we use)
# --------------------------------------------------------------------

OPC_OP     = 0b0110011   # 0x33  register-register (R-type) incl. mul
OPC_OP_IMM = 0b0010011   # 0x13  register-immediate (I-type) incl. shifts
OPC_LOAD   = 0b0000011   # 0x03  loads (I-type)
OPC_STORE  = 0b0100011   # 0x23  stores (S-type)
OPC_BRANCH = 0b1100011   # 0x63  conditional branches (B-type)
OPC_LUI    = 0b0110111   # 0x37  load upper immediate (U-type)
OPC_AUIPC  = 0b0010111   # 0x17  add upper immediate to pc (U-type)
OPC_JAL    = 0b1101111   # 0x6F  jump and link (J-type)
OPC_JALR   = 0b1100111   # 0x67  jump and link register (I-type)
OPC_SYSTEM = 0b1110011   # 0x73  ecall / ebreak (SYS)
OPC_CUSTOM0 = 0b0001011  # 0x0B  custom-0: GPU teaching extensions (rdtid/setdt/getdt)

# Exact 32-bit words for the two system instructions.
WORD_ECALL  = 0x00000073
WORD_EBREAK = 0x00100073


# --------------------------------------------------------------------
# Instruction table
# --------------------------------------------------------------------

class InstrDef(object):
    """One static entry per mnemonic: describes its encoding shape.
    funct3/funct7 are None for formats that don't use them."""
    __slots__ = ("mnemonic", "fmt", "opcode", "funct3", "funct7")

    def __init__(self, mnemonic, fmt, opcode, funct3=None, funct7=None):
        self.mnemonic = mnemonic
        self.fmt = fmt          # 'R','I','I_SHIFT','S','B','U','J','SYS'
        self.opcode = opcode
        self.funct3 = funct3
        self.funct7 = funct7

    def __repr__(self):
        return "InstrDef(%r, %r, 0x%02X)" % (self.mnemonic, self.fmt, self.opcode)


def _instrs():
    out = {}

    def add(mnemonic, fmt, opcode, funct3=None, funct7=None):
        out[mnemonic] = InstrDef(mnemonic, fmt, opcode, funct3, funct7)

    # R-type register-register (opcode 0x33)
    add("add",  "R", OPC_OP, 0b000, 0b0000000)
    add("sub",  "R", OPC_OP, 0b000, 0b0100000)
    add("sll",  "R", OPC_OP, 0b001, 0b0000000)
    add("slt",  "R", OPC_OP, 0b010, 0b0000000)
    add("sltu", "R", OPC_OP, 0b011, 0b0000000)
    add("xor",  "R", OPC_OP, 0b100, 0b0000000)
    add("srl",  "R", OPC_OP, 0b101, 0b0000000)
    add("sra",  "R", OPC_OP, 0b101, 0b0100000)
    add("or",   "R", OPC_OP, 0b110, 0b0000000)
    add("and",  "R", OPC_OP, 0b111, 0b0000000)
    add("mul",  "R", OPC_OP, 0b000, 0b0000001)   # M-extension (MUL only)

    # I-type register-immediate arithmetic (opcode 0x13)
    add("addi",  "I", OPC_OP_IMM, 0b000)
    add("slti",  "I", OPC_OP_IMM, 0b010)
    add("sltiu", "I", OPC_OP_IMM, 0b011)
    add("xori",  "I", OPC_OP_IMM, 0b100)
    add("ori",   "I", OPC_OP_IMM, 0b110)
    add("andi",  "I", OPC_OP_IMM, 0b111)

    # I-type shift-immediate (opcode 0x13; funct7 guards logical vs arithmetic)
    add("slli", "I_SHIFT", OPC_OP_IMM, 0b001, 0b0000000)
    add("srli", "I_SHIFT", OPC_OP_IMM, 0b101, 0b0000000)
    add("srai", "I_SHIFT", OPC_OP_IMM, 0b101, 0b0100000)

    # Loads (I-type, opcode 0x03)
    add("lb",  "I", OPC_LOAD, 0b000)
    add("lh",  "I", OPC_LOAD, 0b001)
    add("lw",  "I", OPC_LOAD, 0b010)
    add("lbu", "I", OPC_LOAD, 0b100)
    add("lhu", "I", OPC_LOAD, 0b101)

    # Stores (S-type, opcode 0x23)
    add("sb", "S", OPC_STORE, 0b000)
    add("sh", "S", OPC_STORE, 0b001)
    add("sw", "S", OPC_STORE, 0b010)

    # Branches (B-type, opcode 0x63)
    add("beq",  "B", OPC_BRANCH, 0b000)
    add("bne",  "B", OPC_BRANCH, 0b001)
    add("blt",  "B", OPC_BRANCH, 0b100)
    add("bge",  "B", OPC_BRANCH, 0b101)
    add("bltu", "B", OPC_BRANCH, 0b110)
    add("bgeu", "B", OPC_BRANCH, 0b111)

    # Upper-immediate (U-type)
    add("lui",   "U", OPC_LUI)
    add("auipc", "U", OPC_AUIPC)

    # Jumps
    add("jal",  "J", OPC_JAL)
    add("jalr", "I", OPC_JALR, 0b000)

    # System
    add("ecall",  "SYS", OPC_SYSTEM, 0b000)
    add("ebreak", "SYS", OPC_SYSTEM, 0b000)

    # Custom-0 (opcode 0x0B): GPU teaching extensions, chosen by funct3.
    #   rdtid rd        (funct3=000)  rd <- this thread's id       (no sources)
    #   setdt rs1, rs2  (funct3=001)  data[rs1] <- rs2             (no dest)
    #   getdt rd, rs1   (funct3=010)  rd <- data[rs1]
    # All three reuse the R-type field layout (funct7 held at 0).
    add("rdtid", "CUST_RD",     OPC_CUSTOM0, 0b000, 0b0000000)
    add("setdt", "CUST_2SRC",   OPC_CUSTOM0, 0b001, 0b0000000)
    add("getdt", "CUST_RD1SRC", OPC_CUSTOM0, 0b010, 0b0000000)

    return out


INSTRS = _instrs()

# Reverse lookups used by decode(). Built once from INSTRS so encode and
# decode can never drift on opcode/funct values.
_BY_OP_F3_F7 = {}    # for R and I_SHIFT
_BY_OP_F3 = {}       # for I (arith/load/jalr), S, B
for _d in INSTRS.values():
    if _d.fmt in ("R", "I_SHIFT"):
        _BY_OP_F3_F7[(_d.opcode, _d.funct3, _d.funct7)] = _d.mnemonic
    elif _d.fmt in ("I", "S", "B"):
        _BY_OP_F3[(_d.opcode, _d.funct3)] = _d.mnemonic
del _d


# --------------------------------------------------------------------
# Field-level encoders (one per format)
# --------------------------------------------------------------------

def encode_R(opcode, rd, funct3, rs1, rs2, funct7):
    _check_unsigned(opcode, 7, "opcode")
    _check_unsigned(funct3, 3, "funct3")
    _check_unsigned(funct7, 7, "funct7")
    _check_unsigned(rd, 5, "rd")
    _check_unsigned(rs1, 5, "rs1")
    _check_unsigned(rs2, 5, "rs2")
    return ((funct7 << 25) | (rs2 << 20) | (rs1 << 15)
            | (funct3 << 12) | (rd << 7) | opcode) & MASK_32


def encode_I(opcode, rd, funct3, rs1, imm):
    _check_unsigned(rd, 5, "rd")
    _check_unsigned(rs1, 5, "rs1")
    immf = _check_signed(imm, 12, "imm")
    return ((immf << 20) | (rs1 << 15) | (funct3 << 12)
            | (rd << 7) | opcode) & MASK_32


def encode_I_shift(opcode, rd, funct3, rs1, shamt, funct7):
    _check_unsigned(rd, 5, "rd")
    _check_unsigned(rs1, 5, "rs1")
    if shamt < 0 or shamt > 31:
        raise ValueError("shift amount %d out of range (0..31)" % shamt)
    return ((funct7 << 25) | (shamt << 20) | (rs1 << 15) | (funct3 << 12)
            | (rd << 7) | opcode) & MASK_32


def encode_S(opcode, funct3, rs1, rs2, imm):
    _check_unsigned(rs1, 5, "rs1")
    _check_unsigned(rs2, 5, "rs2")
    immf = _check_signed(imm, 12, "imm")
    imm_hi = (immf >> 5) & 0x7F     # imm[11:5]
    imm_lo = immf & 0x1F            # imm[4:0]
    return ((imm_hi << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12)
            | (imm_lo << 7) | opcode) & MASK_32


def encode_B(opcode, funct3, rs1, rs2, imm):
    _check_unsigned(rs1, 5, "rs1")
    _check_unsigned(rs2, 5, "rs2")
    if imm & 1:
        raise ValueError("branch offset %d is not 2-byte aligned" % imm)
    immf = _check_signed(imm, 13, "imm")
    b12   = (immf >> 12) & 0x1
    b10_5 = (immf >> 5) & 0x3F
    b4_1  = (immf >> 1) & 0xF
    b11   = (immf >> 11) & 0x1
    return ((b12 << 31) | (b10_5 << 25) | (rs2 << 20) | (rs1 << 15)
            | (funct3 << 12) | (b4_1 << 8) | (b11 << 7) | opcode) & MASK_32


def encode_U(opcode, rd, imm):
    # `imm` is the 20-bit pre-shift value (GNU `as` semantics), placed in
    # bits [31:12]. Values >= 2^20 are an out-of-range error.
    _check_unsigned(rd, 5, "rd")
    immf = _check_unsigned(imm, 20, "imm")
    return ((immf << 12) | (rd << 7) | opcode) & MASK_32


def encode_J(opcode, rd, imm):
    _check_unsigned(rd, 5, "rd")
    if imm & 1:
        raise ValueError("jump offset %d is not 2-byte aligned" % imm)
    immf = _check_signed(imm, 21, "imm")
    b20    = (immf >> 20) & 0x1
    b10_1  = (immf >> 1) & 0x3FF
    b11    = (immf >> 11) & 0x1
    b19_12 = (immf >> 12) & 0xFF
    return ((b20 << 31) | (b10_1 << 21) | (b11 << 20) | (b19_12 << 12)
            | (rd << 7) | opcode) & MASK_32


def encode(mnemonic, rd=0, rs1=0, rs2=0, imm=0):
    """High-level encoder: look the mnemonic up in INSTRS and dispatch to the
    right field encoder. For shifts, `imm` is the shift amount."""
    if mnemonic not in INSTRS:
        raise ValueError("unknown instruction %r" % mnemonic)
    d = INSTRS[mnemonic]
    fmt = d.fmt
    if fmt == "R":
        return encode_R(d.opcode, rd, d.funct3, rs1, rs2, d.funct7)
    if fmt == "I_SHIFT":
        return encode_I_shift(d.opcode, rd, d.funct3, rs1, imm, d.funct7)
    if fmt == "I":
        return encode_I(d.opcode, rd, d.funct3, rs1, imm)
    if fmt == "S":
        return encode_S(d.opcode, d.funct3, rs1, rs2, imm)
    if fmt == "B":
        return encode_B(d.opcode, d.funct3, rs1, rs2, imm)
    if fmt == "U":
        return encode_U(d.opcode, rd, imm)
    if fmt == "J":
        return encode_J(d.opcode, rd, imm)
    if fmt == "SYS":
        return WORD_ECALL if mnemonic == "ecall" else WORD_EBREAK
    # Custom-0 GPU ops: all R-type field layout, funct7 held at 0.
    if fmt == "CUST_RD":                    # rdtid rd
        return encode_R(d.opcode, rd, d.funct3, 0, 0, d.funct7)
    if fmt == "CUST_2SRC":                  # setdt rs1, rs2
        return encode_R(d.opcode, 0, d.funct3, rs1, rs2, d.funct7)
    if fmt == "CUST_RD1SRC":                # getdt rd, rs1
        return encode_R(d.opcode, rd, d.funct3, rs1, 0, d.funct7)
    raise AssertionError(fmt)


# --------------------------------------------------------------------
# Decoded-instruction record
# --------------------------------------------------------------------

class Decoded(object):
    """One dynamic instance per decoded word. `imm` is the sign-extended
    Python int the instruction uses (the byte offset for B/J; the shift
    amount for shifts; the 20-bit operand value for U-type)."""
    __slots__ = ("mnemonic", "fmt", "rd", "rs1", "rs2", "imm", "raw")

    def __init__(self, mnemonic, fmt, rd, rs1, rs2, imm, raw):
        self.mnemonic = mnemonic
        self.fmt = fmt
        self.rd = rd
        self.rs1 = rs1
        self.rs2 = rs2
        self.imm = imm
        self.raw = raw

    def _key(self):
        return (self.mnemonic, self.fmt, self.rd, self.rs1, self.rs2, self.imm)

    def __eq__(self, other):
        return isinstance(other, Decoded) and self._key() == other._key()

    def __ne__(self, other):
        return not self.__eq__(other)

    def __hash__(self):
        return hash(self._key())

    def __repr__(self):
        return ("Decoded(%s fmt=%s rd=%d rs1=%d rs2=%d imm=%d)"
                % (self.mnemonic, self.fmt, self.rd, self.rs1, self.rs2, self.imm))


# --------------------------------------------------------------------
# Decode
# --------------------------------------------------------------------

def decode(word):
    """Pull a Decoded out of a 32-bit word. Raises ValueError on an illegal
    instruction. The all-zero word is reported specially."""
    word &= MASK_32
    if word == 0:
        raise ValueError(
            "instruction word is 0x00000000 (illegal in RV32I); "
            "did execution fall off the end of the program?"
        )

    opcode = word & 0x7F
    rd     = (word >> 7) & 0x1F
    funct3 = (word >> 12) & 0x7
    rs1    = (word >> 15) & 0x1F
    rs2    = (word >> 20) & 0x1F
    funct7 = (word >> 25) & 0x7F

    def i_imm():
        return _sign_extend((word >> 20) & 0xFFF, 12)

    if opcode == OPC_OP:
        mn = _BY_OP_F3_F7.get((opcode, funct3, funct7))
        if mn is None:
            raise ValueError(_illegal(word))
        return Decoded(mn, "R", rd, rs1, rs2, 0, word)

    if opcode == OPC_OP_IMM:
        if funct3 in (0b001, 0b101):          # shift-immediate
            mn = _BY_OP_F3_F7.get((opcode, funct3, funct7))
            if mn is None:
                raise ValueError(_illegal(word))
            shamt = (word >> 20) & 0x1F
            return Decoded(mn, "I_SHIFT", rd, rs1, 0, shamt, word)
        mn = _BY_OP_F3.get((opcode, funct3))
        if mn is None:
            raise ValueError(_illegal(word))
        return Decoded(mn, "I", rd, rs1, 0, i_imm(), word)

    if opcode == OPC_LOAD:
        mn = _BY_OP_F3.get((opcode, funct3))
        if mn is None:
            raise ValueError(_illegal(word))
        return Decoded(mn, "I", rd, rs1, 0, i_imm(), word)

    if opcode == OPC_JALR:
        if funct3 != 0:
            raise ValueError(_illegal(word))
        return Decoded("jalr", "I", rd, rs1, 0, i_imm(), word)

    if opcode == OPC_STORE:
        mn = _BY_OP_F3.get((opcode, funct3))
        if mn is None:
            raise ValueError(_illegal(word))
        imm = _sign_extend(((funct7 << 5) | rd), 12)   # imm[11:5]|imm[4:0]
        return Decoded(mn, "S", 0, rs1, rs2, imm, word)

    if opcode == OPC_BRANCH:
        mn = _BY_OP_F3.get((opcode, funct3))
        if mn is None:
            raise ValueError(_illegal(word))
        b12   = (word >> 31) & 0x1
        b11   = (word >> 7) & 0x1
        b10_5 = (word >> 25) & 0x3F
        b4_1  = (word >> 8) & 0xF
        immu = (b12 << 12) | (b11 << 11) | (b10_5 << 5) | (b4_1 << 1)
        return Decoded(mn, "B", 0, rs1, rs2, _sign_extend(immu, 13), word)

    if opcode in (OPC_LUI, OPC_AUIPC):
        mn = "lui" if opcode == OPC_LUI else "auipc"
        imm = (word >> 12) & 0xFFFFF        # 20-bit operand value (unsigned)
        return Decoded(mn, "U", rd, 0, 0, imm, word)

    if opcode == OPC_JAL:
        b20    = (word >> 31) & 0x1
        b19_12 = (word >> 12) & 0xFF
        b11    = (word >> 20) & 0x1
        b10_1  = (word >> 21) & 0x3FF
        immu = (b20 << 20) | (b19_12 << 12) | (b11 << 11) | (b10_1 << 1)
        return Decoded("jal", "J", rd, 0, 0, _sign_extend(immu, 21), word)

    if opcode == OPC_CUSTOM0:
        if funct3 == 0b000:
            return Decoded("rdtid", "CUST_RD",     rd, 0,   0, 0, word)
        if funct3 == 0b001:
            return Decoded("setdt", "CUST_2SRC",   0,  rs1, rs2, 0, word)
        if funct3 == 0b010:
            return Decoded("getdt", "CUST_RD1SRC", rd, rs1, 0, 0, word)
        raise ValueError(_illegal(word))

    if opcode == OPC_SYSTEM:
        if funct3 != 0:
            raise ValueError(_illegal(word))   # csr* not implemented
        imm12 = (word >> 20) & 0xFFF
        if imm12 == 0:
            return Decoded("ecall", "SYS", 0, 0, 0, 0, word)
        if imm12 == 1:
            return Decoded("ebreak", "SYS", 0, 0, 0, 1, word)
        raise ValueError(_illegal(word))

    raise ValueError(_illegal(word))


def _illegal(word):
    return "illegal instruction 0x%08X (opcode 0x%02X)" % (word & MASK_32,
                                                           word & 0x7F)


# --------------------------------------------------------------------
# .mem (de)serialisation -- the SystemVerilog $readmemb contract.
# Carried over verbatim; the .mem format is a migration invariant.
# --------------------------------------------------------------------

def to_bin_line(word):
    """Return the 32-character '0'/'1' string that SystemVerilog $readmemb wants."""
    return format(word & MASK_32, "032b")


def from_bin_line(line):
    """Parse one line of a .mem file back into a 32-bit integer."""
    s = line.strip().replace("_", "")
    if len(s) != 32 or any(c not in "01" for c in s):
        raise ValueError("bad .mem line %r: expected 32 binary digits" % line)
    return int(s, 2)


# --------------------------------------------------------------------
# Disassembly (for .lst listings and --trace)
# --------------------------------------------------------------------

def disassemble(word):
    """Return a human-readable mnemonic+operands string for a 32-bit word."""
    ins = decode(word)
    mn, fmt = ins.mnemonic, ins.fmt
    rd, rs1, rs2, imm = ins.rd, ins.rs1, ins.rs2, ins.imm
    if fmt == "R":
        return "%s %s, %s, %s" % (mn, reg_name(rd), reg_name(rs1), reg_name(rs2))
    if fmt == "I_SHIFT":
        return "%s %s, %s, %d" % (mn, reg_name(rd), reg_name(rs1), imm)
    if fmt == "I":
        if ins.raw & 0x7F == OPC_LOAD:
            return "%s %s, %d(%s)" % (mn, reg_name(rd), imm, reg_name(rs1))
        # addi-family and jalr
        return "%s %s, %s, %d" % (mn, reg_name(rd), reg_name(rs1), imm)
    if fmt == "S":
        return "%s %s, %d(%s)" % (mn, reg_name(rs2), imm, reg_name(rs1))
    if fmt == "B":
        return "%s %s, %s, %d" % (mn, reg_name(rs1), reg_name(rs2), imm)
    if fmt == "U":
        return "%s %s, 0x%X" % (mn, reg_name(rd), imm)
    if fmt == "J":
        return "%s %s, %d" % (mn, reg_name(rd), imm)
    if fmt == "SYS":
        return mn
    if fmt == "CUST_RD":                     # rdtid rd
        return "%s %s" % (mn, reg_name(rd))
    if fmt == "CUST_2SRC":                   # setdt rs1, rs2
        return "%s %s, %s" % (mn, reg_name(rs1), reg_name(rs2))
    if fmt == "CUST_RD1SRC":                 # getdt rd, rs1
        return "%s %s, %s" % (mn, reg_name(rd), reg_name(rs1))
    raise AssertionError(fmt)
