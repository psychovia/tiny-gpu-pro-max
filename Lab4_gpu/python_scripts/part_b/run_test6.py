#!/usr/bin/env python3
# test6 -- quotient and remainder of random pairs (software / and %), 0-terminated.
# Divisor is always >= 1 so there is never a divide-by-zero.
import sys
from zpu_test import run_case, setup, nz, encode_nums

sim_only, timeout_s, rng = setup(sys.argv)
seq = []
for _ in range(rng.randint(2, 6)):
    seq += [nz(rng, -100, 100), rng.randint(1, 20)]
inp = encode_nums(seq + [0]) + b"\n"
ok = run_case("test6.mem", inp, sim_only=sim_only, timeout_s=timeout_s)
sys.exit(0 if ok else 1)
