#!/usr/bin/env python3
"""
fifo_test.py -- validate the FIFO checkpoint from the Raspberry Pi (smbus2).

The FPGA (io_top) gives you a working two-way I2C link at 0x50 with two FIFO
buffers behind it; you implement the FIFO (fifo.sv). This script PUSHES and POPS
each FIFO directly over I2C and checks real FIFO behavior: order, occupancy,
full/empty, and overflow. With a correct fifo.sv, every check PASSes.

Register map (addr 0x50):
    0x00 STATUS  (read)  bit0 RX_EMPTY  bit1 RX_FULL  bit2 TX_EMPTY  bit3 TX_FULL  bit4 OVERFLOW
    0x01 RX      write = push rx_fifo,  read = pop rx_fifo
    0x02 TX      write = push tx_fifo,  read = pop tx_fifo
    0x03 RXCOUNT (read)  rx occupancy
    0x04 TXCOUNT (read)  tx occupancy

  no args            run the full self-test (PASS/FAIL per check)
  status             print the decoded STATUS byte + counts
  push rx|tx b...    push one or more bytes into a FIFO
  pop  rx|tx [n]     pop n bytes from a FIFO (default 1)
"""
import sys
from smbus2 import SMBus

ADDR, BUS = 0x50, 1
REG_STATUS, REG_RX, REG_TX, REG_RXCOUNT, REG_TXCOUNT = 0x00, 0x01, 0x02, 0x03, 0x04
RX_EMPTY, RX_FULL, TX_EMPTY, TX_FULL, OVERFLOW = 1, 2, 4, 8, 16
DEPTH = 16
REG = {"rx": REG_RX, "tx": REG_TX}
CNT = {"rx": REG_RXCOUNT, "tx": REG_TXCOUNT}


def push(bus, which, vals):
    bus.write_i2c_block_data(ADDR, REG[which], list(vals))

def pop(bus, which, n):
    return bus.read_i2c_block_data(ADDR, REG[which], n)

def count(bus, which):
    return bus.read_byte_data(ADDR, CNT[which])

def status(bus):
    return bus.read_byte_data(ADDR, REG_STATUS)


class T:
    def __init__(self): self.p = self.f = 0
    def eq(self, name, got, exp):
        if got == exp: self.p += 1; print(f"  PASS  {name:<30} {got}")
        else:          self.f += 1; print(f"  FAIL  {name:<30} {got}  (exp {exp})")


def self_test(bus):
    t = T()
    print(f"=== FIFO checkpoint self-test against 0x{ADDR:02X} on i2c-{BUS} ===")

    # 1) order + occupancy, each FIFO independently
    for w in ("rx", "tx"):
        seq = list(range(1, 9))
        push(bus, w, seq)
        t.eq(f"{w}: count after push", count(bus, w), len(seq))
        got = pop(bus, w, len(seq))
        t.eq(f"{w}: FIFO order", got, seq)
        t.eq(f"{w}: empty after drain", count(bus, w), 0)

    # 2) empty pop is a safe no-op
    t.eq("rx: empty pop count stays 0", (pop(bus, "rx", 1), count(bus, "rx"))[1], 0)

    # 3) overflow runs last (the flag is sticky)
    t.eq("overflow clear so far", status(bus) & OVERFLOW, 0)
    over = list(range(DEPTH + 3))               # push 3 more than it can hold
    push(bus, "rx", over)
    t.eq("rx: count caps at DEPTH", count(bus, "rx"), DEPTH)
    t.eq("rx: RX_FULL set", bool(status(bus) & RX_FULL), True)
    t.eq("rx: OVERFLOW set", bool(status(bus) & OVERFLOW), True)
    got = pop(bus, "rx", DEPTH)
    t.eq("rx: first DEPTH in order", got, over[:DEPTH])    # the extras were dropped
    t.eq("rx: empty again", count(bus, "rx"), 0)

    print(f"=== {t.p} passed, {t.f} failed ===")
    return t.f == 0


def decode_status(s):
    names = [("RX_EMPTY", RX_EMPTY), ("RX_FULL", RX_FULL), ("TX_EMPTY", TX_EMPTY),
             ("TX_FULL", TX_FULL), ("OVERFLOW", OVERFLOW)]
    return f"0x{s:02X}  " + " ".join(n for n, m in names if s & m)


def main():
    a = sys.argv[1:]
    try:
        with SMBus(BUS) as bus:
            if not a:
                sys.exit(0 if self_test(bus) else 1)
            elif a[0] == "status":
                print(decode_status(status(bus)),
                      f"| rxcount={count(bus,'rx')} txcount={count(bus,'tx')}")
            elif a[0] == "push":
                push(bus, a[1], [int(x, 0) & 0xFF for x in a[2:]])
                print(f"pushed {len(a)-2} byte(s) into {a[1]}")
            elif a[0] == "pop":
                n = int(a[2], 0) if len(a) > 2 else 1
                print(pop(bus, a[1], n))
            else:
                print(__doc__); sys.exit(2)
    except FileNotFoundError:
        sys.exit(f"/dev/i2c-{BUS} not found -- enable I2C and reboot.")
    except OSError as e:
        sys.exit(f"I2C error (errno {e.errno}): FPGA programmed/wired? (SDA<->A16, SCL<->A15, GND)")


if __name__ == "__main__":
    main()
