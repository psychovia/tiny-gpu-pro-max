#!/usr/bin/env python3
"""
gpu_link.py -- adapt assembly from the Lab4_gpu C compiler to run on this GPU.

The compiler in Lab4_gpu/python_scripts/toolchain targets the model described in
its GPU_explained.md: every thread has its OWN private program/stack memory, and
a program stops with `ebreak`. This GPU is built differently in exactly two ways,
so its output needs two mechanical edits -- neither of which is a change to the
C, and neither of which belongs in the instructor's compiler.

    1. HALT.  This core has no ecall/ebreak opcode at all (see rvasm.py's
       exclusion list). An `ebreak` here decodes as illegal: no writeback, the pc
       just advances, and the core runs off the end of the program into zeros
       with kernel_done never asserting -- it hangs rather than stopping. The
       convention here is writing 1 to x31, which scheduler.sv reduces across
       the lanes into kernel_done.

    2. STACK.  The lanes do NOT have private memory -- all N_LANES of them run
       this one binary out of one shared_mem. So they cannot all use the same sp.
       If they did, every lane would push its frame to identical addresses; one
       lane wins each arbitrated write, and then every lane reads that lane's
       locals back. For a kernel whose per-lane state is its loop index, all the
       lanes end up computing the SAME element. Nothing crashes and no test of
       the instructions themselves fails -- the output is just wrong, in a way
       that looks like a compiler bug. This gives lane i its own slice:

           sp = MEM_TOP - tid * STACK_PER_LANE

Usage:
    gpu_link.py in.asm out.asm [--mem-top N] [--stack-per-lane N]

Then assemble with the SAME toolchain that compiled it, so the custom-0 encodings
match: Lab4_gpu/python_scripts/toolchain/cli.py asm out.asm -o out
"""

import argparse
import re
import sys

# Defaults for this GPU: gpu_pkg.sv's MEM_SIZE_BYTES is PROG_SIZE + IMG_SIZE =
# 4096 + 12288 = 16384, and N_LANES is 8. 1 KiB per lane is far more than this C
# subset needs (a frame is tens of bytes plus the expression stack) and 8 x 1 KiB
# lands in the top half, clear of the program at address 0.
MEM_TOP_DEFAULT = 16384
STACK_PER_LANE_DEFAULT = 1024
LANES_DEFAULT = 8


def link(text, mem_top, stack_per_lane, lanes):
    # --- 1. per-lane stack ------------------------------------------------
    # Rewrite the single `li sp, N` the entry stub emits. Anchored to the
    # instruction, not to a line number, so it survives the compiler changing
    # the rest of the prologue.
    sp_re = re.compile(r"^([ \t]*)li[ \t]+sp[ \t]*,[ \t]*(\d+)[ \t]*$", re.M)
    hits = sp_re.findall(text)
    if len(hits) != 1:
        raise SystemExit("gpu_link: expected exactly one `li sp, N` in the entry "
                         "stub, found %d -- has the compiler's prologue changed?"
                         % len(hits))

    def sp_repl(m):
        ind = m.group(1)
        return (
            "{i}# --- gpu_link: per-lane stack (this GPU shares one memory) ---\n"
            "{i}rdtid t0                 # this lane's id\n"
            "{i}li   t1, {per}\n"
            "{i}mul  t0, t0, t1          # tid * bytes per lane\n"
            "{i}li   sp, {top}\n"
            "{i}sub  sp, sp, t0          # lanes 0..{last} each get their own slice"
        ).format(i=ind, per=stack_per_lane, top=mem_top, last=lanes - 1)

    text = sp_re.sub(sp_repl, text, count=1)

    # --- 2. halt ----------------------------------------------------------
    if re.search(r"^\s*ecall\s*$", text, re.M):
        raise SystemExit("gpu_link: this program uses `ecall` (print/scanf), which "
                         "this GPU has no opcode for -- it has no I/O path. Remove "
                         "the print/scanf calls from the C.")
    eb_re = re.compile(r"^([ \t]*)ebreak[ \t]*(#.*)?$", re.M)
    n = len(eb_re.findall(text))
    if n != 1:
        raise SystemExit("gpu_link: expected exactly one `ebreak`, found %d" % n)
    text = eb_re.sub(lambda m: "%saddi x31, x0, 1          "
                               "# gpu_link: x31 = 1 -> this lane is done"
                               % m.group(1), text, count=1)
    return text


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input")
    ap.add_argument("output")
    ap.add_argument("--mem-top", type=int, default=MEM_TOP_DEFAULT)
    ap.add_argument("--stack-per-lane", type=int, default=STACK_PER_LANE_DEFAULT)
    ap.add_argument("--lanes", type=int, default=LANES_DEFAULT)
    a = ap.parse_args()

    if a.lanes * a.stack_per_lane > a.mem_top:
        sys.exit("gpu_link: %d lanes x %d bytes of stack = %d, more than the "
                 "%d-byte memory" % (a.lanes, a.stack_per_lane,
                                     a.lanes * a.stack_per_lane, a.mem_top))

    with open(a.input) as f:
        out = link(f.read(), a.mem_top, a.stack_per_lane, a.lanes)
    with open(a.output, "w") as f:
        f.write(out)
    print("gpu_link: %s -> %s (sp = %d - tid*%d, ebreak -> x31=1)"
          % (a.input, a.output, a.mem_top, a.stack_per_lane))


if __name__ == "__main__":
    main()
