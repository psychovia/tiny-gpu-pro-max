# test1.s -- ALU bring-up. Exercises R-type, I-type, and U-type instructions.
# Each result's low byte is sent out with putchar; the simulator says what's
# correct. No input, no branches, no memory.
_start:
    li   a7, 0               # putchar service
    li   t0, 100
    li   t1, 7

    add  a0, t0, t1          # 107
    ecall
    sub  a0, t0, t1          # 93
    ecall
    and  a0, t0, t1          # 4
    ecall
    or   a0, t0, t1          # 103
    ecall
    xor  a0, t0, t1          # 99
    ecall
    sll  a0, t1, t1          # 7 << 7 = 896  -> low byte 0x80
    ecall
    srl  a0, t0, t1          # 100 >> 7 = 0
    ecall
    sra  a0, t0, t1          # 100 >>> 7 = 0
    ecall
    slt  a0, t1, t0          # 7 < 100 -> 1
    ecall
    sltu a0, t0, t1          # 100 <u 7 -> 0
    ecall
    addi a0, t0, 5           # 105
    ecall
    andi a0, t0, 12          # 100 & 12 = 4
    ecall
    ori  a0, t0, 3           # 103
    ecall
    xori a0, t0, 15          # 107
    ecall
    slli a0, t1, 2           # 28
    ecall
    srli a0, t0, 1           # 50
    ecall
    lui  a0, 1               # 0x1000 -> low byte 0
    ecall
    halt
