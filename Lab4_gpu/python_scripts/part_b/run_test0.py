#!/usr/bin/env python3
# test0 -- prints "Hi\n". No input. Brings up fetch / putchar / halt.
import sys
from zpu_test import run_case, setup

sim_only, timeout_s, rng = setup(sys.argv)
ok = run_case("test0.mem", b"", sim_only=sim_only, timeout_s=timeout_s)
sys.exit(0 if ok else 1)
