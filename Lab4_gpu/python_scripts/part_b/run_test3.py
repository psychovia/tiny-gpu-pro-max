#!/usr/bin/env python3
# test3 -- memory + input. Echoes a random byte string back until a 0x00 byte.
import sys
from zpu_test import run_case, setup

sim_only, timeout_s, rng = setup(sys.argv)
n = rng.randint(1, 30)
payload = bytes(rng.randint(1, 255) for _ in range(n))   # any byte except 0x00
inp = payload + b"\x00"                                   # 0x00 = "that's all"
ok = run_case("test3.mem", inp, sim_only=sim_only, timeout_s=timeout_s)
sys.exit(0 if ok else 1)
