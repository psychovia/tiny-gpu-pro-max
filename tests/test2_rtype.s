# test2_rtype.s -- R-type ALU coverage, including mul and shift-amount masking.
#
# Uses -1 as an operand throughout so the signed/unsigned distinction actually
# matters: slt vs sltu and srl vs sra give different answers for it, so a
# swapped pair cannot pass both checks.

addi x1, x0, 12
addi x2, x0, 5
addi x9, x0, -1         # 0xFFFFFFFF

add  x3,  x1, x2        # 12 + 5                -> 17
sub  x4,  x1, x2        # 12 - 5                -> 7
sub  x5,  x2, x1        # 5 - 12                -> -7
mul  x6,  x1, x2        # 12 * 5                -> 60

sll  x7,  x1, x2        # 12 << 5               -> 384
srl  x8,  x1, x2        # 12 >> 5               -> 0
srl  x10, x9, x2        # 0xFFFFFFFF >> 5       -> 0x07FFFFFF (logical)
sra  x11, x9, x2        # -1 >>> 5              -> -1        (arithmetic)

slt  x12, x9, x2        # -1 <s 5               -> 1
sltu x13, x9, x2        # 0xFFFFFFFF <u 5       -> 0
sltu x22, x2, x9        # 5 <u 0xFFFFFFFF       -> 1
slt  x23, x2, x9        # 5 <s -1               -> 0

xor  x14, x1, x2        # 12 ^ 5                -> 9
or   x15, x1, x2        # 12 | 5                -> 13
and  x16, x1, x2        # 12 & 5                -> 4

mul  x17, x9, x9        # (-1) * (-1)           -> 1
mul  x20, x9, x1        # (-1) * 12             -> -12
sub  x21, x0, x1        # 0 - 12                -> -12

sll  x18, x1, x9        # shift amount must be masked to rs2[4:0] = 31,
                        # so 12 << 31 overflows away -> 0
add  x19, x9, x1        # -1 + 12               -> 11

done
