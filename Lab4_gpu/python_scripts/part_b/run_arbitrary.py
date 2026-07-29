#!/usr/bin/env python3
"""
run_arbitrary.py -- a live console to whatever program is flashed on the FPGA.

Everything your CPU sends out (putchar / print) is shown on your screen; every
key you type is sent in to your CPU (getchar / scanf). It's a plain byte pipe --
like a serial monitor -- not tied to any one program. Great for poking at the
echo test by hand, or just watching a program run.

  python3 run_arbitrary.py

Enter is sent as newline. Quit with Ctrl-C. (Typed keys are not echoed locally;
if the program echoes them, you'll see them come back.)
"""
import os
import select
import sys
import termios
import time
import tty

from zpu_test import (ADDR, BUS, REG_RX, REG_TX, REG_RXCOUNT, REG_TXCOUNT,
                      FIFO_DEPTH, SMBUS_MAX)


def main():
    try:
        from smbus2 import SMBus
    except ImportError:
        print("smbus2 not installed (pip install smbus2)"); return 1

    input("Press BTN0 on the FPGA to reset it, then press Enter to open the console...")
    print("--- live console (Ctrl-C to quit) ---")
    pending = bytearray()
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    try:
        tty.setcbreak(fd)            # keystrokes arrive immediately, no line buffering
        with SMBus(BUS) as bus:
            while True:
                idle = True
                # CPU -> screen
                txc = bus.read_byte_data(ADDR, REG_TXCOUNT)
                if txc:
                    data = bus.read_i2c_block_data(ADDR, REG_TX, min(txc, SMBUS_MAX))
                    sys.stdout.write(bytes(data).decode("latin-1"))
                    sys.stdout.flush(); idle = False
                # keyboard -> buffer
                if select.select([fd], [], [], 0)[0]:
                    ch = os.read(fd, 64)
                    if ch:
                        pending.extend(ch.replace(b"\r", b"\n"))  # Enter -> newline
                        idle = False
                # buffer -> CPU (respect rx capacity so we never overflow it)
                if pending:
                    space = FIFO_DEPTH - bus.read_byte_data(ADDR, REG_RXCOUNT)
                    if space > 0:
                        chunk = pending[:min(space, SMBUS_MAX)]
                        bus.write_i2c_block_data(ADDR, REG_RX, list(chunk))
                        del pending[:len(chunk)]; idle = False
                if idle:
                    time.sleep(0.002)
    except KeyboardInterrupt:
        pass
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
    print("\n--- console closed ---")
    return 0


if __name__ == "__main__":
    sys.exit(main())
