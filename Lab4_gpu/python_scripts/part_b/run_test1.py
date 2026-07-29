#!/usr/bin/env python3
# test1 -- ALU bring-up (R/I/U-type). No input; output is a fixed byte sequence.
import sys
from zpu_test import run_case, setup

sim_only, timeout_s, rng = setup(sys.argv)
ok = run_case("test1.mem", b"", sim_only=sim_only, timeout_s=timeout_s)
sys.exit(0 if ok else 1)
