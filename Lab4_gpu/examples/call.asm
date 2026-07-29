# call.asm -- hand-written RISC-V: call a leaf function, then halt.
# f(x) = 2*x + 1.  We compute f(5) = 11 and leave it in a0.
#
# Assemble + run:
#   python cli.py asm examples/call.asm
#   python cli.py run examples/call.mem --dump a0

_start:
    li   sp, 65536          # set up the stack pointer (top of memory)
    li   a0, 5              # argument x = 5
    call f                  # a0 = f(5)   (call == jal ra, f)
    ebreak                  # halt; a0 holds 11

# f is a "leaf" function: it calls nothing, so it need not save ra.
f:
    slli a0, a0, 1          # a0 = x << 1  = 2*x
    addi a0, a0, 1          # a0 = 2*x + 1
    ret                     # return (ret == jalr x0, ra, 0)
