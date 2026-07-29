# test0.s -- the simplest possible program: print "Hi\n" and stop.
# Exercises ONLY: instruction fetch, addi (li), ecall putchar, ebreak.
# No memory, no branches, no jumps. If this works your fetch/execute loop runs.
_start:
    li   a7, 0          # ecall service 0 = putchar
    li   a0, 72         # 'H'
    ecall
    li   a0, 105        # 'i'
    ecall
    li   a0, 10         # '\n'
    ecall
    halt
