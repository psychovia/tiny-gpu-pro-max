# Lab 4 — a RISC-V toolchain, a FIFO, and a CPU you build

This lab has three pieces that build on each other, for **18-240 at CMU**:

1. A tiny **RV32I + `mul`** instruction set and a pure-Python **toolchain** — a
   C-subset compiler, an assembler, and a simulator. You write small C programs;
   the toolchain turns them into RISC-V machine code you can run in the simulator
   *and* load onto hardware you build yourself.
2. **Part A — the FIFO.** On the Digilent Boolean Board you implement a byte
   buffer (`fifo.sv`); a Raspberry Pi exercises it over a two-way I2C link.
3. **Part B — the CPU (the "ZPU").** You implement a CPU (`cpu.sv`) that runs the
   machine code from piece 1 and reaches the outside world *only* through the
   Part-A FIFO, via the **`ecall`** instruction (which blocks on empty/full).

> **GPU variant.** In this version your CPU is **one thread**, and you run **many
> of them** (SIMT — one program, many threads). Each thread gets a different id via
> the new `tid` builtin (`int x = tid;`), and all threads share one data memory
> through `setdata(i, v)` / `getdata(i)` — which you can view as a 32×32 image. The
> simulator runs all **32** threads for you (`--threads 32 --data-image out.ppm`);
> the **board** fits only a couple of full CPU cores, so it runs 2 (the rest is the
> normal GPU trade-off — the model has many threads, the silicon runs what fits).
> Read **`GPU_explained.md`** first, and see the example kernels
> `examples/gpu_inc.c` and `examples/gpu_draw.c`.

No third-party packages for the toolchain — `python3` on the ECE machines, the
Raspberry Pi, and the AMD servers all just work. (The one exception is the
Pi-side test scripts, which need the `smbus2` package installed on the Pi.)

```
.c  -->  compiler  -->  .asm  -->  assembler  -->  .mem
```

That one `.mem` runs in **two** places: the Python **simulator** (your reference)
and the **SystemVerilog CPU you build** (`$readmemb` loads it). It's one 32-bit
binary string per line — exactly what `$readmemb` consumes and what the simulator
reads — so a program assembled once runs in both. All of that compilation is
abstracted away into a couple of one-line `python3` commands.

---

## Part 1 — the toolchain

### Quick start

Run commands from the project root (the `Lab4/` directory that contains
`python_scripts/`, `examples/`, and `doc/`):

```bash
# hand it your C file: this compiles, assembles, and runs it in one step, and
# prints the value your C code returns (typically left in register a0):
python3 python_scripts/toolchain/cli.py examples/sum.c --dump a0
#   ...  a0 = 0x00000037  (55 u32, 55 s32)
```

New to this? Read **[compiling_and_simulating.md](compiling_and_simulating.md)**
— a from-scratch guide for someone who has barely used a terminal.

### The CLI

Normally you just hand it a `.c` file (as above) and it does everything. To run a
single stage by hand — say, to look at the generated assembly or to keep the
standalone `.mem` for your CPU — name the stage:

```bash
python3 python_scripts/toolchain/cli.py compile prog.c     # prog.c   -> prog.asm
python3 python_scripts/toolchain/cli.py asm     prog.asm   # prog.asm -> prog.mem + prog.lst
python3 python_scripts/toolchain/cli.py run     prog.mem   # simulate an already-built .mem
```

(`--help` lists everything, and a bare `.c` file is shorthand for `build` =
compile + assemble + run.) Useful flags (for the bare `.c` form and for `run`):
`--dump a0,a1,sp` (or `--dump-all`), `--trace` (print every instruction),
`--strict` (turn the first warning into an error), and `--max-cycles N` — the
infinite-loop cutoff for *this* Python simulator, separate from any Vivado
simulation you run on your SystemVerilog CPU later. Exit codes: `0` success, `1`
user/compile/assemble error, `2` runtime error, `3` a warning promoted by
`--strict`.

### The ISA at a glance

- **32 general-purpose 32-bit registers** `x0..x31`, with the standard RISC-V ABI
  names (`zero ra sp gp tp t0-t6 s0-s11 a0-a7`, and `fp` = `s0`). `x0` is
  hardwired to 0.
- A 32-bit program counter `pc` (4-byte aligned); byte-addressable,
  **little-endian** memory — a word's least-significant byte lives at its lowest
  address (64 KiB; `ISA_Explained.md` works through an example).
- The implemented subset: the RV32I base integer instructions plus `mul` from the
  M extension. **No hardware divide** — the compiler implements C `/` and `%` as a
  software routine.
- I/O is via `ecall`, dispatched on the service number in `a7` (the standard
  RISC-V convention): `a7=1` reads one byte into `a0`, any other value emits the
  low byte of `a0` as one character. The hardware only ever moves a single byte —
  the compiler builds `print` (int→decimal) and `scanf` (decimal→int) on top of
  these one-byte services.

The full instruction reference, encodings, the register table, and the simulator
diagnostics are in **[ISA_Explained.md](ISA_Explained.md)**.

### What C you can write

`int`-only, but a real language: arithmetic and bitwise operators, `/` and `%`,
`if/else`, `while`, `do-while`, `for`, `switch`, `break`, `continue`, functions
(any number of params — the first 8 in registers, the rest on the stack — plus
recursion), arrays (1-D *or* multi-dimensional, global *and* local), **pointers of
any depth** (`&`, `*`, pointer arithmetic, array↔pointer decay), and the built-ins
`print(x)` (prints a decimal + newline) and `scanf("%d", &x)` (reads decimals —
`%d`/`%u`, several per call, returns the count read or `-1` at EOF, just like C).
Anything outside the subset (floats, structs, casts, `sizeof`, …) is rejected with
a clear, line-pointing error rather than miscompiled. The precise list is the
docstring at the top of `python_scripts/toolchain/compiler.py`.

### The `.mem` file (what your CPU loads)

The toolchain emits machine code as a `.mem` file: **one 32-bit instruction per
line, written as 32 `0`/`1` characters** — exactly the format SystemVerilog's
`$readmemb` consumes (binary — `$readmemb`, **not** `$readmemh`) and the Python
simulator reads. A program assembled once runs in the simulator *and* loads onto
your CPU. How you store those words in memory — and how you pull a byte or
half-word out of one for `lb`/`lh`/`sb`/`sh` in little-endian order — is part of
the CPU *you* design; `ISA_Explained.md` defines the contract you must honor.

---

## What you have to do — Part A (the FIFO) [TODO: Decide marks]

**You edit exactly one file: `~/Lab4/SystemVerilog/part_a/fifo.sv`.**

A synchronous byte FIFO: hold up to `DEPTH` bytes and return them in the order
pushed (`push`/`pop`/`full`/`empty`/`count`), with first-word fall-through
`rdata`, a correctly handled same-cycle push+pop, a synchronous `rst` that clears
it back to empty, and a sticky `overflow` latched if a byte is pushed while full.
The full contract is in the header of `fifo.sv`. New to FIFOs? Read
**[FIFO_explained.md](FIFO_explained.md)** first.

```
Pi  <--I2C-->  i2c_target  -->  io_bridge  -->  rx_fifo + tx_fifo
```

Everything but the two FIFOs is **provided — do not edit it**: `fpga_io.sv`
(`i2c_target` = the two-way I2C link, `io_bridge` = register decode that
pushes/pops your two `fifo`s, plus `Synchronizer`/`Counter`), `io_top.sv` (the top
— **set this as the Vivado top**), and `top.xdc` (pins: `CLOCK_100=F14`,
`scl=A15`, `sda=A16` with pull-ups, LEDs, 7-seg). Runs on the raw 100 MHz
oscillator — no clock wizard. **No testbenches are provided — write your own** to
self-check in simulation before you flash.

Over I2C the Pi can push *and* pop each FIFO, so `fifo_test.py` fully exercises
yours — order, depth, full/empty, overflow. (In Part B the CPU takes over those
inner ends: it pops rx and pushes tx.)

**Build & program:** top = `io_top`; sources `fifo.sv` + `fpga_io.sv` +
`io_top.sv`, constraints `top.xdc`; Generate Bitstream → program.

**Test it on the Pi.** With the board programmed, run the validator on the Pi:

```bash
python3 ~/Lab4/python_scripts/part_a/fifo_test.py
```

**All checks PASS** when each FIFO returns bytes in order, occupancy tracks
pushes/pops, full/empty are correct, and overflow latches only when you overrun
it. The 7-seg shows the last byte that crossed a FIFO (e.g. `push rx 0xBE` → `bE`).

**Seeing failures on a re-run?** Each run leaves the FIFOs in whatever state it
finished in — leftover bytes, or a latched `overflow` — and that stale state can
trip the next run. Tap **BTN0** to clear both FIFOs back to empty, then run
`fifo_test.py` again from a clean start.

---

## What you have to do — Part B (the CPU / ZPU) [TODO: Decide marks, each test is 10% of this section]

**You edit `~/Lab4/SystemVerilog/part_b/cpu.sv`** (and reuse your Part-A `fifo.sv`, plus
any submodules you add). Build a CPU that runs the machine code in its program
memory and reaches the world *only* through the rx/tx FIFOs — and that I/O is one
instruction, **`ecall`**: it reads a byte from rx or writes one to tx, stalling
when it has to. Its exact convention (the `a7` service numbers and the blocking
rule) is in **[ISA_Explained.md](ISA_Explained.md)** §5. 

The rest of the contract
— where the program lives, the register/PC start values, how the PC moves, the
mailbox handshake — is in **[CPU_explained.md](CPU_explained.md)** and the
`cpu.sv` header.
The provided `fpga_io.sv` / `io_top.sv` wire `i2c_target ↔ io_bridge ↔ rx/tx FIFOs
↔ your cpu`, with **BTN0 as the reset**. Again: **no testbenches are provided —
write your own.**

**Pick a program to run.** Each program is baked into its own bitstream (there's
no way to load a new one over I2C), so you flash once per program — and you'll
work through all ten, `test0` through `test9`. The `.mem` files are in
`~/Lab4/SystemVerilog/part_b/mems/`. Point your CPU's `INIT_FILE` at the one
you're flashing and synthesize:

```systemverilog
parameter INIT_FILE = "mems/test0.mem"
```

The ten build up in coverage, each adding one piece on top of the last:

| # | lang | exercises |
|---|------|-----------|
| 0 | asm | fetch, `addi`, `ecall` putchar, `ebreak` — no memory/branch/jump |
| 1 | asm | the ALU: `add sub and or xor sll srl sra slt sltu`, immediates, `lui` |
| 2 | asm | branches and a loop, plus a subroutine call (`jal`/`ret`) |
| 3 | asm | loads/stores + little-endian, then echo input until a `0x00` byte |
| 4 | C | `scanf`/`print`, addition, a loop (running sum) |
| 5 | C | `mul` (products of pairs) |
| 6 | C | software `/` and `%` (quotient and remainder) |
| 7 | C | recursion / the stack (`fib`, `fact`) |
| 8 | C | arrays and memory addressing (sum, min, max) |
| 9 | C | **comprehensive** — all of the above in one program |

**Test it on the Pi.** The harness runs the program on the **simulator** to get
the golden output, feeds the **same input** to your CPU over I2C, and diffs byte
for byte — printing exactly what it **expected** vs. **got**, where they first
diverge, and timing out instead of hanging if your CPU stalls. Because the
simulator is the source of truth, **inputs are randomized** each run (the seed is
printed so any failure is reproducible).

```bash
# flash testN, then run its matching checker on the Pi (work through test0..test9):
python3 ~/Lab4/python_scripts/part_b/run_test0.py
```

**Operating order:** with the test flashed, **tap BTN0** — it resets your CPU
*and clears both FIFOs* — **then press Enter** on the Pi to start the run. Flags
on every runner: `--sim-only` (just print the expected output, no FPGA — handy
before your CPU works), `--seed N` (reproduce an exact input), `--timeout S`.

---



## Deliverables

For each checkpoint you submit **the SystemVerilog you wrote**, and you **show it
passing on the board** — the Pi-side test output is the proof. The provided files
(`fpga_io.sv`, `io_top.sv`, `top.xdc`) are *not* deliverables; they're given.

**Part A — the FIFO**
- **File:** `~/Lab4/SystemVerilog/part_a/fifo.sv`.
- **Proof:** with `io_top` programmed, `fifo_test.py` passes every check — the line
  that matters is **`0 failed`**:
  ```
  $ python3 ~/Lab4/python_scripts/part_a/fifo_test.py
    PASS  ...
    PASS  ...
  === 13 passed, 0 failed ===
  ```

**Part B — the CPU**
- **Files:** `~/Lab4/SystemVerilog/part_b/cpu.sv` and your `fifo.sv` (plus any
  submodules you added).
- **Proof:** flash and run **all ten** — for each `testN`, re-flash
  `mems/testN.mem`, tap BTN0, and run the matching `run_testN.py`. Every one must
  report PASS:
  ```
  $ python3 ~/Lab4/python_scripts/part_b/run_test0.py
  === test0.mem ===
    ...
    PASS  output matched the simulator (… bytes).
  ```
  The programs build up — fetch/`ecall`, the ALU, branches, loads/stores,
  `scanf`/`print`, `mul`, `/` and `%`, recursion, arrays, then the comprehensive
  `test9` — so passing all ten exercises every part of your CPU.

---

## Layout

```
Lab4/
  doc/             this guide + the ISA, FIFO, CPU, and compiling references
  python_scripts/
    toolchain/     the compiler / assembler / simulator / CLI (+ unit tests)
    part_a/        fifo_test.py        — Pi-side FIFO validator
    part_b/        zpu_test.py, run_test0..9.py, run_arbitrary.py, programs/
  examples/        sample .c programs (and a couple of hand-written .asm)
  SystemVerilog/
    part_a/        the FIFO checkpoint — you edit fifo.sv
    part_b/        the CPU checkpoint  — you edit cpu.sv (+ your fifo.sv); mems/ holds the test .mem files
```

**Bold** = the files you work with directly (edit, run, or read). The unbolded
toolchain files are internal plumbing that `cli.py` drives for you.

| File | Purpose |
|---|---|
| **`SystemVerilog/part_a/fifo.sv`** | **You edit this (Part A)** — the FIFO you implement. |
| **`SystemVerilog/part_b/cpu.sv`** | **You edit this (Part B)** — the CPU you implement (reuses your `fifo.sv`). |
| `python_scripts/toolchain/isa.py` | Registers, the instruction table, and `encode`/`decode`/`disassemble` |
| `python_scripts/toolchain/assembler.py` | `.asm` text → `.mem` (machine code) + `.lst` (listing) |
| `python_scripts/toolchain/simulator.py` | A Python interpreter for the ISA, with friendly runtime diagnostics |
| `python_scripts/toolchain/compiler.py` | The C-subset → `.asm` compiler |
| **`python_scripts/toolchain/cli.py`** | The `compile / asm / run / build` front-end — **the command you run**. |
| `python_scripts/toolchain/tests/` | Unit + end-to-end tests |
| **`python_scripts/part_a/fifo_test.py`** | Pi-side FIFO validator (smbus2) — **the Part A test**. |
| **`python_scripts/part_b/`** | The ZPU test suite (oracle + I2C diff) and the test programs — **the Part B tests**. |
| **`doc/ISA_Explained.md`** | The full ISA reference — *you will need this*. |
| **`doc/FIFO_explained.md`** | What a FIFO is and why the link needs one (Part A). |
| **`doc/CPU_explained.md`** | What a CPU is and the rules yours must obey (Part B). |
| **`doc/GPU_explained.md`** | The GPU variant: threads, `tid`, the shared data memory (`setdata`/`getdata`). |
| **`doc/custom_instructions.md`** | The three custom instructions: bit layouts, decode logic, and how each layer parses them. |
| **`doc/compiling_and_simulating.md`** | A beginner's guide to compiling and running. |
| **`SystemVerilog/part_b/datamem.sv`** | *Provided* — the shared data memory all threads read/write (GPU variant). |
| **`examples/gpu_inc.c`, `examples/gpu_draw.c`** | GPU example kernels: increment-in-parallel, and paint a 32×32 image. |

---

## Going further — run your own program

Nothing about your CPU is special-cased to the ten tests: once it works, it runs
**any** program the toolchain produces. That's the whole point — some of you may drop a small CPU like this into the capstone project for this class, and this is exactly
the loop you'll reuse. Here it is end to end, with a worked example.

### 1. Write a C program

Stick to the C subset (the **What C you can write** section above, and
[compiling_and_simulating.md](compiling_and_simulating.md)) — `int`s, the usual
control flow, `print(x)`, and `scanf("%d", &x)`. For example, `sumprod.c` reads
two numbers and prints their sum and their product:

```c
// sumprod.c -- read two integers, print their sum and their product.
int main() {
    int a;
    int b;
    scanf("%d", &a);          // read the first number
    scanf("%d", &b);          // read the second
    print(a + b);             // print the sum     (a newline is automatically added for you)
    print(a * b);             // print the product
    return 0;
}
```

### 2. Compile it and check it in the simulator first

`build` compiles, assembles, and runs it in the simulator in one shot — so you can
watch it behave *before* you ever touch the FPGA:

```bash
python3 ~/Lab4/python_scripts/toolchain/cli.py build sumprod.c
```

The simulator **pauses at each `scanf` and waits for you to type**. You'll see the
three `wrote …` lines, then it just sits there waiting; type a number and press
Enter for each `scanf`. The run looks like this (the digits you type appear on
screen as you type them):

```
wrote sumprod.asm
wrote sumprod.mem
wrote sumprod.lst
3                     <-- type 3, press Enter   (it was waiting here)
4                     <-- type 4, press Enter
7
12
=== program halted at PC=0x00000008 (cycles=1039) ===
halted=True  cycles=1039  PC=0x00000008  sp=0x00010000
  a0   = 0x00000000  (          0 u32,           0 s32)
  ... (a few more registers)
```

The `7` and `12` are your program's output (sum, then product); everything from
`=== program halted` on is the simulator's end-of-run report. If that looks right,
`sumprod.mem` is good to flash.

> **Have just assembly, no C?** Skip `compile` — hand your `.asm` to the `asm`
> stage, then `run` the `.mem`. Here's a tiny program that prints `Hi` with raw
> `ecall`s (recall `a7 != 1` ⇒ putchar, sending the low byte of `a0`):
>
> ```asm
> # hi.asm
>     li   a7, 0          # putchar service
>     li   a0, 72         # 'H'
>     ecall
>     li   a0, 105        # 'i'
>     ecall
>     li   a0, 10         # newline
>     ecall
>     ebreak              # stop
> ```
> ```bash
> $ python3 ~/Lab4/python_scripts/toolchain/cli.py asm hi.asm   # hi.asm -> hi.mem + hi.lst
> $ python3 ~/Lab4/python_scripts/toolchain/cli.py run hi.mem
> Hi
> === program halted at PC=0x0000001C (cycles=8) ===
> ```
>
> One thing the compiler normally does for you: on the real CPU **every register
> starts at 0**, `sp` included. If your assembly uses the stack (`call`/`ret`, or
> loads/stores off `sp`), set it yourself first — e.g. `li sp, 0x10000` (the top of
> the 64 KiB memory). `hi.asm` touches no memory, so it doesn't need to. (The
> simulator happens to start `sp` at the top for you; the hardware does not.)

### 3. Put it on the FPGA

Same as the tests — a program is baked into the bitstream. Copy the `.mem` in
beside the others and point your CPU's `INIT_FILE` at it:

```bash
cp sumprod.mem ~/Lab4/SystemVerilog/part_b/mems/sumprod.mem
```
```systemverilog
// in ~/Lab4/SystemVerilog/part_b/cpu.sv
parameter INIT_FILE = "mems/sumprod.mem"
```

Then synthesize and program in Vivado exactly as before (top = `io_top`).
Re-synthesize whenever you change the program — there's no way to load a new one
over I2C.

### 4. Which files live where

- **On your build machine (the one with Vivado) — everything.**
  `~/Lab4/SystemVerilog/` (your `cpu.sv` + the provided harness — you synthesize
  and flash from here) and `~/Lab4/python_scripts/toolchain/` (turns your C or asm
  into a `.mem`).
- **On the Pi — just the Python.** Keep the whole `~/Lab4/python_scripts/` folder
  there. The Pi never synthesizes; it only talks to the FPGA over I2C. Keep the
  folder intact rather than copying one file — the console script borrows a few
  constants from elsewhere in it.

### 5. Run it on the Pi — the live console

`run_arbitrary.py` is a plain byte pipe to whatever is flashed: every byte your
CPU prints lands on your screen, and every key you type is fed to its `getchar`.
With your `sumprod` bitstream programmed:

```bash
python3 ~/Lab4/python_scripts/part_b/run_arbitrary.py
```

It asks you to tap **BTN0** (reset) and press Enter, then opens the console. Now
type `3` and Enter, then `4` and Enter — the same two numbers, this time fed to
your CPU's `scanf` over I2C:

```
Press BTN0 on the FPGA to reset it, then press Enter to open the console...
--- live console (Ctrl-C to quit) ---
7
12
```

Notice you *don't* see the `3` and `4` you typed here — unlike the simulator's
terminal, this console doesn't echo your keystrokes, only what the CPU sends back
(here, `7` then `12`). A program that echoes its input (like the `test3` echo
program) *will* show your typing come back. Quit with **Ctrl-C**.

---

## Appendix: functions in SystemVerilog

You'll read (and may want to write) a SystemVerilog **function**. If you've only
seen `always` blocks so far, here's the idea.

A function takes inputs and **returns one value** computed from them — like a
function in math, Python, or C. In hardware it's **pure combinational logic**: no
clock, no memory, no state. Same inputs → same output, in the *same* cycle (no
`<=` and no clock edges inside it).

What one looks like:

```systemverilog
function automatic logic [31:0] add_one(input logic [31:0] x);
    add_one = x + 1;          // "return" by assigning the function's own name
endfunction
```

and you *use* it inline, anywhere an expression is allowed:

```systemverilog
y = add_one(count);           // y becomes count + 1
```

A few things that trip people up coming from software:

- **It's hardware, not a subroutine that runs over time.** A function elaborates
  into a block of gates, and **each call builds its own copy** of those gates.
  Calling `add_one` in three places makes three adders — it isn't "called" at run
  time, it's *inlined* at every call site.
- **`automatic`** gives each call its own fresh local variables. Use it — it's the
  safe default and avoids accidental shared state.
- **No timing or state inside.** No `@(posedge clk)`, no `<=`, no waiting. If you
  need a clock edge, or to remember something between cycles, that belongs in an
  `always_ff` — not a function.
- **The return value is the function's own name** (or you can write `return x;`).

Why bother? To **name and reuse a chunk of combinational logic**. An ALU — "given
two values and an op code, produce the result" — is a natural function: write the
`case` once and call it wherever you need the computation, instead of copying it.

(Its cousin the *task* can have multiple outputs, no return value, or timing —
reach for a **function** when you just want to compute one value.)
