#!/usr/bin/env python3
# test4 -- running sum of random integers, terminated by a 0.
import sys
from zpu_test import run_case, setup, nz, encode_nums

sim_only, timeout_s, rng = setup(sys.argv)
vals = [nz(rng, -50, 50) for _ in range(rng.randint(3, 10))]
inp = encode_nums(vals + [0]) + b"\n"
ok = run_case("test4.mem", inp, sim_only=sim_only, timeout_s=timeout_s)
sys.exit(0 if ok else 1)
