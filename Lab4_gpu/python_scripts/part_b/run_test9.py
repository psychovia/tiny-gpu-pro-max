#!/usr/bin/env python3
# test9 -- the comprehensive one. Four 0-terminated sections feed the program
# that exercises sum/count, mul, /, %, recursion, and arrays in a single flash.
import sys
from zpu_test import run_case, setup, nz, encode_nums

sim_only, timeout_s, rng = setup(sys.argv)

sec1 = [nz(rng, -50, 50) for _ in range(rng.randint(2, 6))] + [0]       # sum + count
sec2 = []
for _ in range(rng.randint(2, 4)):
    sec2 += [nz(rng, -30, 30), rng.randint(1, 20)]                      # a*b, a/b, a%b
sec2 += [0]
sec3 = [rng.randint(1, 10) for _ in range(rng.randint(1, 3))] + [0]     # fib(n)
sec4 = [nz(rng, -50, 50) for _ in range(rng.randint(2, 6))] + [0]       # array, reversed

inp = encode_nums(sec1 + sec2 + sec3 + sec4) + b"\n"
ok = run_case("test9.mem", inp, sim_only=sim_only, timeout_s=timeout_s)
sys.exit(0 if ok else 1)
