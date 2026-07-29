# one_local.asm -- hand-written RISC-V: a function with a stack frame and one
# local variable.  sq_plus_1(7) = 7*7 + 1 = 50.
#
# Shows the standard prologue/epilogue shape the C compiler also emits:
#   - move sp down to make room for the frame,
#   - save ra and the frame pointer s0,
#   - point s0 at the top of the frame,
#   - undo all of that on the way out.

_start:
    li   sp, 65536
    li   a0, 7
    call sq_plus_1
    ebreak                  # halt; a0 holds 50

sq_plus_1:
    addi sp, sp, -16        # allocate a 16-byte frame
    sw   ra, 12(sp)         # save return address
    sw   s0, 8(sp)          # save caller's frame pointer
    addi s0, sp, 16         # s0 = frame pointer (caller's sp)
    mul  a0, a0, a0         # a0 = x*x
    sw   a0, -12(s0)        # store the square in our local slot
    lw   a0, -12(s0)        # read it back (just to show a load)
    addi a0, a0, 1          # + 1
    lw   ra, 12(sp)         # restore return address
    lw   s0, 8(sp)          # restore frame pointer
    addi sp, sp, 16         # free the frame
    ret
