# Testing the compute path

```sh
./run_tests.sh              # everything
./run_tests.sh test6        # only tests matching "test6"
```

Run it **from the repo root** — `shared_mem.sv`'s `$readmemb` paths (`mems/*.mem`)
are relative to the simulator's working directory. Exits nonzero if anything
fails, so CI can use the status code instead of grepping stdout. Logs and
per-test output land in `.sim/`.

Requires `xvlog` / `xelab` / `xsim` (Vivado 2025.2) and `python3` on `$PATH`.

## What is covered

Like `test0.sv`, everything here builds `core.sv` + `shared_mem.sv` and skips
`gpu.sv` / `display_controller.sv` — the display path pulls in `vga-hdmi.sv`
and the Counter/Comparator/RangeCheck/Subtracter/Mux2to1 helpers that live
outside this repo. `shared_mem`'s display port is still exercised directly by
`test_shared_mem_tb`.

| Test | What it pins down |
|---|---|
| `test0` | original smoke test: one instruction, `kernel_done` fires |
| `test1_alu_tb` | I-type + U-type ALU: every immediate op, sign-extension, `x0` stays zero |
| `test2_rtype_tb` | R-type ALU incl. `mul`, signed vs unsigned compares, shift-amount masking |
| `test3_mem_tb` | `lb/lh/lw/lbu/lhu`, `sb/sh/sw`, byte lanes, negative offsets — checks registers *and* memory |
| `test4_branch_tb` | all six branch conditions taken **and** not-taken, plus a backward-branch loop |
| `test5_jump_tb` | `jal` link = pc+4, `jalr` = rs1+imm with bit 0 cleared, `auipc` |
| `test6_lanes_tb` | 8 lanes at 8 **different** addresses — the real arbitration test |
| `test7_kernel_tb` | end-to-end strided kernel: 8 lanes × 4 iterations over 32 words, loads/stores inside a loop |
| `test_decoder_tb` | `decoder.sv` standalone: 29 directed vectors, every instruction format |
| `test_shared_mem_tb` | `shared_mem.sv` standalone: arbiter fairness across rounds, byte-masked writes, MMIO neutralization, display port |

Total: **801 assertions across 10 testbenches.**

## Layout

```
tests/*.s                       test programs in assembly
python_scripts/rvasm.py         RV32IM assembler -> $readmemb binary
python_scripts/gen_test_data.py generates the data images in mems/
python_scripts/gen_decoder_vectors.py  generates testbenches/decoder_vectors.svh
testbenches/tb_harness.sv       core+shared_mem wrapper with register/memory probes
testbenches/tb_check.svh        CHECK_EQ / RUN_KERNEL / TB_SUMMARY macros
testbenches/*_tb.sv             one testbench per test program
mems/*.mem                      GENERATED — rebuilt on every run_tests.sh
```

`run_tests.sh` regenerates every `.mem` and the decoder vectors before
compiling, so a stale generated file can never make a test look green.

## Writing a new test

1. Write `tests/testN_thing.s`. `rvasm.py` only accepts instructions this
   design actually implements, so it rejects (rather than silently
   mis-encoding) anything unsupported. `done` is the pseudo-instruction for
   `addi x31, x0, 1`, the "thread complete" convention. `x30` is preloaded with
   the lane id; `tid` and `flag` are accepted as aliases for `x30`/`x31`.
2. Copy an existing `*_tb.sv`, point `PROG_INIT_FILE` at `mems/testN_thing.mem`,
   and write `CHECK_EQ` assertions against `h.regs[lane][reg]` and
   `h.mem_word(byte_addr)`.
3. Add `testN_thing_tb:testbenches/testN_thing_tb.sv` to the `TESTS` array in
   `run_tests.sh`.

**Control flow must be uniform across lanes.** `core.sv` wires only lane 0's
`rs1_val`/`rs2_val` into `pc.sv`, so lane 0 resolves every branch for all 8
lanes. A program that branches on `x30` would diverge, and this design has no
divergence support — see the note in `scheduler.sv`. Per-lane *data* is fine
and is exactly what `test6`/`test7` do.

## Is the suite actually able to fail?

It was validated by mutation testing — nine deliberate bugs injected into the
RTL one at a time, all nine caught:

| Injected bug | Caught by |
|---|---|
| `decoder.sv`: S-type immediate uses the B-type field split | `test3_mem`, `test_decoder` |
| `cpu.sv`: `srai` becomes a logical shift | `test1_alu` |
| `cpu.sv`: `sltu` becomes a signed compare | `test2_rtype` |
| `cpu.sv`: `lb` zero-extends instead of sign-extending | `test3_mem` |
| `pc.sv`: `bge` implemented as strictly-greater | `test4_branch` |
| `shared_mem.sv`: round-robin exclusion disabled (lane 0 starves the rest) | 8 of 10 tests |
| `scheduler.sv`: `S_MEM_ADDR` waits for lane 0 only | `test3_mem`, `test6_lanes`, `test7_kernel` |
| `cpu.sv`: `x30` not preloaded with `lane_id` | `test1_alu`, `test6_lanes`, `test7_kernel` |
| `cpu.sv`: `sb`'s `byte_en` ignores the byte offset | `test3_mem` |

`test0` caught **none of the nine** — it passed under every mutation,
including the broken arbiter that fails 8 of the other tests. One instruction
at one address cannot distinguish a working memory system from a broken one.
That gap is the reason for the rest of the suite.

## Known gaps

These are untested, not known-broken:

- **The display path.** `display_controller.sv`, `vga-hdmi.sv` and the rest of
  `SystemVerilog/display/` need helper modules that aren't in this repo, so
  nothing here elaborates them. Only `shared_mem`'s display *port* is tested.
- **Synthesis/timing.** This is all functional simulation. It says nothing
  about whether the design meets timing or fits the xc7s50.
- **Addresses at or above 0x4000.** `shared_mem` slices `mem_addr[15:2]` into a
  14-bit word index but only has `MEM_SIZE_BYTES/4 = 4096` words, so a byte
  address ≥ 0x4000 indexes past the end of the array. In simulation that reads
  X and drops writes; on hardware it would alias. No test drives an address
  there, and no current program can generate one.
- **Divergent control flow.** Not supported by the design (see above), so not
  tested.
- **Multi-block dispatch.** Removed from `scheduler.sv` and archived in
  `block_logic.sv`; `kernel_done` fires after one batch of `N_LANES` threads
  regardless of `TOTAL_THREADS`.
