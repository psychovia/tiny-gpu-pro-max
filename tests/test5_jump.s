# test5_jump.s -- jal / jalr / auipc.
#
# Covers the three things that are easy to get wrong: that jal's link register
# gets pc+4 (not the jump target), that jalr computes rs1+imm rather than
# pc+imm, and that jalr clears bit 0 of the target.
#
# Byte addresses are fixed and load-bearing -- the testbench checks x1 and x2
# against literal addresses. Nothing here expands to more than one instruction
# (no `li`), so the layout in the comments below is exact. If you edit this
# file, re-check the expected values in test5_jump_tb.sv against the address
# comments in the generated mems/test5_jump.mem.

# 0x00
addi x20, x0, 0

# 0x04 -- link register must get 0x08 (pc+4), NOT the target 0x10
jal  x1, func

# 0x08 -- returned here from func
addi x20, x20, 10

# 0x0c
j    after

# 0x10
func:
addi x20, x20, 1
# 0x14
ret                     # jalr x0, x1, 0 -> back to 0x08

# 0x18 -- x2 = pc of this instruction = 0x18
after:
auipc x2, 0

# 0x1c -- target = x2 + 13 = 0x25, and jalr must clear bit 0 -> 0x24
jalr x0, x2, 13

# 0x20 -- must be skipped
addi x21, x0, 999

# 0x24 -- jalr lands here
addi x21, x0, 42

# 0x28
done
