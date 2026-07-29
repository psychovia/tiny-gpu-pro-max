# test2.s -- control flow bring-up. A counted loop (branch back-edge) prints
# the digits '0'..'9', then a subroutine call (jal/ret) prints a newline.
# Exercises: blt, jal (call), jalr (ret), mv, addi.
_start:
    li   sp, 65536           # stack pointer (not strictly needed for a leaf call)
    li   a7, 0               # putchar service
    li   s0, 48              # '0'
    li   s1, 58              # one past '9'
loop:
    mv   a0, s0
    ecall                    # putchar the current digit
    addi s0, s0, 1
    blt  s0, s1, loop        # repeat while s0 < 58
    call newline             # a0 = '\n'
    ecall                    # putchar '\n'
    halt

# leaf subroutine: return '\n' in a0
newline:
    li   a0, 10
    ret
