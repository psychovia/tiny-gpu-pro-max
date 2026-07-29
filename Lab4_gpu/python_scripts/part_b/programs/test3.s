# test3.s -- memory + input bring-up.
# Part 1: a little-endian store/load check (sw, sb, lbu, lhu, lw, srli).
# Part 2: echo every input byte back out until a 0x00 sentinel arrives.
# Exercises stores, loads, byte ordering, getchar, putchar, a branch, and that
# getchar must WAIT for the controller (the blocking input you'll build).
_start:
    li   a7, 0
    li   t0, 8192            # scratch data address (0x2000), clear of code and stack
    li   t1, 0x44332211
    sw   t1, 0(t0)           # store one word
    lbu  a0, 0(t0)
    ecall                    # 0x11  (lowest address holds the least-significant byte)
    lbu  a0, 1(t0)
    ecall                    # 0x22
    lbu  a0, 2(t0)
    ecall                    # 0x33
    lbu  a0, 3(t0)
    ecall                    # 0x44
    li   t1, 170             # 0xAA
    sb   t1, 1(t0)           # overwrite just byte 1
    lw   t2, 0(t0)           # word is now 0x4433AA11
    srli a0, t2, 8
    ecall                    # 0xAA
    lhu  a0, 2(t0)           # half-word at offset 2 = 0x4433
    ecall                    # low byte 0x33

echo:
    li   a7, 1
    ecall                    # a0 = getchar (waits if nothing has arrived yet)
    beqz a0, done            # 0x00 = "that's all" -> stop
    li   a7, 0
    ecall                    # putchar the byte we just read (still in a0)
    j    echo
done:
    halt
