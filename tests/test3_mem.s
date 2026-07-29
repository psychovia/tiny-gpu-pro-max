# test3_mem.s -- load/store width and byte-lane coverage.
#
# Every lane issues the SAME address here, which is intentional: it isolates
# byte_en / byte_shift correctness from arbitration. All 8 lanes write
# identical data to identical addresses, so the result is the same no matter
# what order shared_mem grants them. test6 is the one that gives each lane a
# distinct address.
#
# Scratch addresses start at 0x1000 (IMG_BASE) -- the only region above the
# 4 KB program area, and the tests that use it write before they read.

li   x1, 0x1000
li   x2, 0xDEADBEEF
sw   x2, 0(x1)

lw   x3,  0(x1)         # whole word            -> 0xDEADBEEF
lb   x4,  0(x1)         # byte 0 = 0xEF, signed -> 0xFFFFFFEF
lbu  x5,  0(x1)         # byte 0, zero-extended -> 0x000000EF
lb   x6,  1(x1)         # byte 1 = 0xBE, signed -> 0xFFFFFFBE
lbu  x7,  3(x1)         # byte 3 = 0xDE         -> 0x000000DE
lh   x8,  0(x1)         # half 0 = 0xBEEF, signed -> 0xFFFFBEEF
lhu  x9,  0(x1)         # half 0, zero-extended -> 0x0000BEEF
lh   x10, 2(x1)         # half 1 = 0xDEAD, signed -> 0xFFFFDEAD
lhu  x11, 2(x1)         # half 1, zero-extended -> 0x0000DEAD

# ---- sb into a zeroed word: byte_en must select exactly one lane ----
li   x12, 0x1010
sw   x0,  0(x12)        # clear
li   x13, 0xAA
sb   x13, 0(x12)
li   x14, 0xBB
sb   x14, 2(x12)
lw   x15, 0(x12)        #                       -> 0x00BB00AA

# ---- sh into a zeroed word ----
li   x16, 0x1020
sw   x0,  0(x16)
li   x17, 0x1234
sh   x17, 0(x16)
li   x18, 0x5678
sh   x18, 2(x16)
lw   x19, 0(x16)        #                       -> 0x56781234

# ---- partial overwrite: sb must leave the other three bytes alone ----
li   x20, 0x1030
li   x21, 0xFFFFFFFF
sw   x21, 0(x20)
sb   x0,  1(x20)        # clear byte 1 only
lw   x22, 0(x20)        #                       -> 0xFFFF00FF

# ---- negative offset ----
li   x23, 0x1040
li   x24, 0x11223344
sw   x24, -4(x23)       # writes 0x103C
lw   x25, -4(x23)       #                       -> 0x11223344

done
