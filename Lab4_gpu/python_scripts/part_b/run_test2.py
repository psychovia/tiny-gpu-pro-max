#!/usr/bin/env python3
# test2 -- control-flow bring-up (branches, jal/ret). No input; prints "0..9\n".
import sys
from zpu_test import run_case, setup

sim_only, timeout_s, rng = setup(sys.argv)
ok = run_case("test2.mem", b"", sim_only=sim_only, timeout_s=timeout_s)
sys.exit(0 if ok else 1)
