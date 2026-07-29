# test4_branch.s -- all six branch conditions, both directions, plus a
# backward-branch loop.
#
# x10 is an error accumulator: every "this instruction must be skipped" slot
# adds a distinct power of two, so a failure tells you exactly which branch
# misbehaved instead of just "something is wrong". x10 must end at 0.
#
# Control flow is uniform across lanes (nothing here reads x30), which is a
# hard requirement of this design: core.sv wires only lane 0's rs1_val/rs2_val
# into pc.sv, so lane 0 alone resolves every branch for all 8 lanes.

addi x1,  x0, 5
addi x2,  x0, 5
addi x3,  x0, 7
addi x4,  x0, -3
addi x5,  x0, 2
addi x10, x0, 0         # error accumulator

# ---- beq, taken ----
beq  x1, x2, beq_t
addi x10, x10, 1
beq_t:

# ---- beq, not taken ----
beq  x1, x3, beq_n_bad
j    beq_n
beq_n_bad:
addi x10, x10, 2
beq_n:

# ---- bne, taken ----
bne  x1, x3, bne_t
addi x10, x10, 4
bne_t:

# ---- bne, not taken ----
bne  x1, x2, bne_n_bad
j    bne_n
bne_n_bad:
addi x10, x10, 8
bne_n:

# ---- blt, signed: -3 < 2 is TRUE ----
blt  x4, x5, blt_t
addi x10, x10, 16
blt_t:

# ---- bltu, unsigned: 0xFFFFFFFD < 2 is FALSE ----
bltu x4, x5, bltu_bad
j    bltu_n
bltu_bad:
addi x10, x10, 32
bltu_n:

# ---- bge, signed: 2 >= -3 is TRUE ----
bge  x5, x4, bge_t
addi x10, x10, 64
bge_t:

# ---- bge, not taken: -3 >= 2 is FALSE ----
bge  x4, x5, bge_bad
j    bge_n
bge_bad:
addi x10, x10, 128
bge_n:

# ---- bgeu, unsigned: 0xFFFFFFFD >= 2 is TRUE ----
bgeu x4, x5, bgeu_t
addi x10, x10, 256
bgeu_t:

# ---- bge with equal operands must be taken ----
bge  x1, x2, bge_eq
addi x10, x10, 512
bge_eq:

# ---- backward branch: sum 5+4+3+2+1 = 15 ----
addi x20, x0, 0
addi x21, x0, 5
loop:
add  x20, x20, x21
addi x21, x21, -1
bne  x21, x0, loop      # backward offset

done
