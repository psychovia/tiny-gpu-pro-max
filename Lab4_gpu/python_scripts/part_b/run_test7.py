#!/usr/bin/env python3
# test7 -- fib(n) and fact(n) for random small n (recursion / the stack), 0-terminated.
import sys
from zpu_test import run_case, setup, encode_nums

sim_only, timeout_s, rng = setup(sys.argv)
ns = [rng.randint(1, 10) for _ in range(rng.randint(2, 5))]
inp = encode_nums(ns + [0]) + b"\n"
ok = run_case("test7.mem", inp, sim_only=sim_only, timeout_s=timeout_s)
sys.exit(0 if ok else 1)
