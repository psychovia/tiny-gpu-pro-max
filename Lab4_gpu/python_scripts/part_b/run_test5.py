#!/usr/bin/env python3
# test5 -- products of random pairs (mul), terminated by a 0.
import sys
from zpu_test import run_case, setup, nz, encode_nums

sim_only, timeout_s, rng = setup(sys.argv)
seq = []
for _ in range(rng.randint(2, 6)):
    seq += [nz(rng, -30, 30), nz(rng, -30, 30)]
inp = encode_nums(seq + [0]) + b"\n"
ok = run_case("test5.mem", inp, sim_only=sim_only, timeout_s=timeout_s)
sys.exit(0 if ok else 1)
