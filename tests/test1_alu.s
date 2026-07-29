# test1_alu.s -- I-type / U-type ALU coverage.
#
# Every lane runs this identically (no x30 use), so this isolates the ALU and
# immediate decoding from anything lane-specific. auipc is the FIRST
# instruction so its pc is known to be 0 and the expected result is just the
# immediate -- no need to count instruction addresses in the testbench.

auipc x16, 0x1000       # pc(0) + 0x1000         -> 0x00001000

addi  x1,  x0, 100      #                        -> 100
addi  x2,  x0, -5       # sign-extended negative -> 0xFFFFFFFB
addi  x3,  x1, -30      # 100 - 30               -> 70

xori  x4,  x1, 0x0F     # 0x64 ^ 0x0F            -> 0x6B (107)
ori   x5,  x1, 0x0F     # 0x64 | 0x0F            -> 0x6F (111)
andi  x6,  x1, 0x0F     # 0x64 & 0x0F            -> 0x04 (4)

slti  x7,  x2, 0        # -5 <s 0                -> 1
slti  x8,  x1, 0        # 100 <s 0               -> 0
sltiu x9,  x2, 0        # 0xFFFFFFFB <u 0        -> 0  (NOT a signed compare)
sltiu x10, x1, 200      # 100 <u 200             -> 1

slli  x11, x1, 4        # 100 << 4               -> 1600
srli  x12, x1, 2        # 100 >> 2               -> 25
srai  x13, x2, 1        # -5 >>> 1               -> -3
srli  x14, x2, 28       # 0xFFFFFFFB >> 28       -> 0xF (15), logical not arithmetic

andi  x15, x2, -1       # 0xFFFFFFFB & 0xFFFFFFFF -> 0xFFFFFFFB (andi imm sign-extends)

lui   x17, 0xABCDE000   # imm[31:12] placed      -> 0xABCDE000
addi  x18, x0, 2047     # largest positive imm   -> 2047
addi  x19, x0, -2048    # most negative imm      -> -2048
xori  x20, x0, -1       # ~0                     -> 0xFFFFFFFF

addi  x0,  x0, 5        # writes to x0 must be discarded -> x0 stays 0

done
