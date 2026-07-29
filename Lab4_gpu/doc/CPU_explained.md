# What a CPU is, and what yours has to do

This is the *why* behind `cpu.sv`. It explains what a CPU does and the **rules
your CPU must obey** — the handful of facts a program counts on being true. It
deliberately says nothing about *how* to build one (how to decode instructions,
lay out a datapath, run one cycle or many) — that part is the lab.

It assumes you've read **`ISA_Explained.md`** (the instruction set your CPU runs)
and built the **`fifo.sv`** mailbox from Part A. This page ties those together.

## 1. From plumbing to a processor

In Part A you built the **mailbox**: two FIFOs and the I2C link that move bytes
between the Raspberry Pi and the FPGA. Useful — but nothing on the FPGA was
*deciding* anything. It just shuttled bytes.

A **CPU** is the thing that decides. It runs a *program*: a list of tiny
instructions ("add these two numbers," "if this is zero, jump over there," "send
this byte out"). Give it a program and it will, entirely on its own, work through
it step by step.

Underneath, a CPU does the same three things over and over, forever:

1. **Fetch** — read the instruction the program counter is pointing at.
2. **Execute** — do what that instruction says (add, compare, load, store, send…).
3. **Advance** — figure out which instruction comes next, and repeat.

That loop is the whole idea. Everything a program does — loops, decisions,
function calls, arithmetic, talking to the Pi — is built out of millions of trips
around it. Your job is to build the machine that runs that loop correctly.

## 2. The program, and where it lives

A program is just a list of **32-bit instructions** sitting in memory. They are
loaded for you, before the CPU starts, from `program.mem` — the exact `.mem` file
the toolchain produces and the simulator runs (see `compiling_and_simulating.md`).

A few fixed facts about that memory:

- The first instruction is at **address 0**. The next is at 4, then 8, and so on —
  one instruction every **4 bytes**, because each instruction is 4 bytes wide.
- Memory is **byte-addressable** (every byte has its own address) and **64 KiB**
  in all. The same memory holds the program *and* the data it works on.
- It is **little-endian** — the detail only matters for byte and half-word
  accesses, and `ISA_Explained.md` spells it out.

So "run the program" starts as: look at address 0, do that instruction, move on.

**A timing fact that shapes the whole design.** That memory is built from the
FPGA's **Block RAM (BRAM)** — a dedicated on-chip memory resource, and there's
plenty of it. The catch is that Block RAM reads are **synchronous**: you put an
address on it at one clock edge, and the value you asked for arrives on the
**next** edge — *not* the same cycle. So a fetch is really "present the program
counter this cycle, and the instruction shows up the cycle after"; every data
load behaves the same way. That one-cycle read delay isn't something you can wish
away — a same-cycle ("combinational") read of a memory this large won't fit on the
chip — so part of designing the CPU is arranging your timing so you only *use* an
instruction, or a loaded value, the cycle **after** you ask for it. How you do
that (wait a cycle, pipeline, a small state machine…) is up to you.

## 3. The registers, and what they start as

Right next to the datapath sit the **registers**: **32 of them** (`x0`–`x31`),
each 32 bits, the CPU's fast scratchpad. Instructions read their inputs from
registers and write their results back to registers. Two things never change:

- **`x0` is always 0.** Reading it gives 0; writing to it does nothing. (It's
  wired that way on purpose — a constant zero turns out to be enormously useful.)
- **At reset, every register holds 0.** That's the clean starting point.

You may have read that the **stack pointer** (`sp`, which is `x2`) "lives at the
top of memory." It does — but the programs the toolchain produces set that up
*themselves*, as their very first instruction. So you don't have to special-case
any register: bringing them all up as 0 is enough, and the program takes it from
there. (The full list of register names and their conventional jobs is in
`ISA_Explained.md`; the hardware doesn't care what they're "for.")

## 4. The program counter, and how it moves

The **program counter** (`pc`) is the CPU's bookmark: the address of the
instruction it's working on right now. Because instructions are 4 bytes,
the `pc` is always a multiple of 4, and at reset it is **0** — the first
instruction.

How it moves after each instruction is the other half of the fetch loop:

- **Normally it just advances by 4** — on to the very next instruction.
- **Branches and jumps** instead point it somewhere *else*. That redirection is
  how every loop, every `if`/`else`, and every function call works: the program
  changes its own bookmark to keep running somewhere new.

*Which* instructions redirect the `pc`, and exactly what address they compute, is
laid out in `ISA_Explained.md` (branches, `jal`, `jalr`). The rule to hold onto
here: after an instruction, the `pc` either steps to the next one or is sent to a
target the instruction chose.

## 5. Memory and the stack

Loads and stores reach back into that same 64 KiB of memory: a **load** reads a
value out of it, a **store** writes one in. Programs keep their variables, arrays,
and saved state there.

By convention the **stack** grows downward from the *top* of memory while the
program runs — that's why `sp` starts high. Function calls use it to save return
addresses and local variables. You don't have to arrange any of this; the
compiled program does it. You just have to make loads and stores land on the right
bytes (and respect little-endian order for the byte/half-word ones).

## 6. Talking to the world — the mailbox you already built

A processor that can't do input or output is a closed box. Your CPU's *only* link
to the outside is the **mailbox from Part A**: the **rx** FIFO (bytes in) and the
**tx** FIFO (bytes out). There is no other I/O.

A program reaches the mailbox through one special instruction, **`ecall`**, and
the value in register `a7` picks which service it wants:

- **`getchar`** (`a7 == 1`) — take **one byte from rx** and deliver it in `a0`.
  This is how a program does input (`scanf`, reading a character).
- **`putchar`** (anything else) — **send the low byte of `a0` out through tx**.
  This is how a program does output (`print`, sending a character).

And here is the rule that makes it *work* — the same `empty`/`full` you built into
the FIFO:

- `getchar` must **wait** while rx is **empty**. There's no byte yet; the whole
  processor should stall until the Pi sends one, then continue.
- `putchar` must **wait** while tx is **full**. There's no room yet; stall until
  the Pi has read a byte out and made space, then continue.

That "wait" is the point of having a FIFO at all (it's why Part A came first). A
program that reads input it hasn't received yet simply pauses, exactly as a real
program blocking on `stdin` would. One last instruction, **`ebreak`**, means
*stop* — the program is done.

## 6b. Many threads, one screen — the GPU variant

In the GPU variant your CPU is **one thread**, and the board builds many copies of
it. Two things make those copies a *team* instead of clones:

- **`tid` — a per-copy constant input.** Each `cpu` instance is wired to a
  different `tid`, so `rdtid rd` reads a different number in each thread. That one
  wire is what makes 32 identical CPUs do 32 different things — it's the reason the
  hardware, not the program, decides what `int x = tid;` sees.
- **A shared data memory.** `setdt`/`getdt` write and read *one* array that **all**
  threads share (contrast the rx/tx mailbox and your private memory, which are
  each thread's alone). It's the threads' common workspace — think "global memory"
  — and you can view it as a 32×32 image. `setdt` is fire-and-forget: unlike
  `putchar` it never has to wait.

The full story — the three instructions, the C builtins, running all 32 threads in
the simulator, and how many actually fit on the board (a couple: one CPU core is
~7,500 LUTs, so the FPGA holds ~2) — is in **`GPU_explained.md`**.

## 7. How you'll know it's right

You already have a perfect reference: the **simulator**. It runs the same
`program.mem`, follows the same rules above, and produces some sequence of output
bytes for a given input. **Your CPU is correct when it produces the *same* output
bytes for the *same* program and input.** That's literally what the Pi test suite
checks — it runs the program on the simulator, feeds your CPU the same input over
I2C, and compares what comes back out of tx. Match the simulator and you're done.

## 8. What this page does *not* tell you (that's the lab)

Everything above is the *contract* — the rules your CPU has to honor. How you make
them true is yours to design and there may be multiple correct designs:

- how to pull an instruction apart into its fields and decide what it is,
- how to build the register file, the ALU, and the memory ports,
- whether each instruction takes one clock cycle or several,
- Does the CPU need an FSM? What are its states?
- how to drive the mailbox handshake (`rx_pop`, `tx_push`) at the right moments,
- and how `ecall` to actually *stall* your processor on empty/full.

There's no single right structure, and the ports of `cpu.sv` don't impose one —
they only fix how the outside world reaches you. Where to look as you build:
**`ISA_Explained.md`** for every instruction (its fields, encoding, and exact
effect, plus the register ABI), **`FIFO_explained.md`** for the mailbox, and
**`compiling_and_simulating.md`** for building a `.mem` and running the simulator
as your reference model. The rest is the lab.
