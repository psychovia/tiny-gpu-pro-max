# The GPU variant: threads, `tid`, and a shared data memory

This lab is the same RISC-V toolchain and CPU as the base Lab 4, with one twist:
your hardware runs **many copies of the CPU at once**. Each copy is a **thread**.
Every thread runs the *same* program; the only thing that differs between them is
a number called the **thread id** (`tid`). That is the whole idea behind a GPU:
*one program, many threads, each working on different data.*

There are always **32 threads**, numbered `tid = 0, 1, 2, … 31`.

---

## 1. What's new (three instructions, three C features)

The base CPU can already do arithmetic, branches, loads/stores, `mul`, and
`print`/`scanf`. The GPU variant adds **one new opcode** (`custom-0`, machine
opcode `0001011`) holding **three instructions**, and the C compiler exposes them
as three easy features:

| In C | Assembly it compiles to | What it does |
|------|-------------------------|--------------|
| `tid` (a read-only value) | `rdtid rd` | `rd = ` this thread's id (0..31) |
| `setdata(i, v);` | `setdt rs1, rs2` | shared `data[i] = v` |
| `getdata(i)` | `getdt rd, rs1` | returns shared `data[i]` |

So you can write, in ordinary C:

```c
int x = tid;              // which thread am I?
setdata(x, 100);          // write 100 into shared cell x
int v = getdata(x);       // read it back
```

`tid` is read-only, and it is a **keyword** — you can use it in an expression, but
you can't assign to it or name a variable `tid`.

> Building the CPU (or curious how these are encoded and decoded)? The bit
> layouts, the decode logic, and how every layer handles them are in
> [`custom_instructions.md`](custom_instructions.md).

---

## 2. Private memory vs. the shared data memory

Every thread has its **own private memory** — its program, its stack, its local
variables. Thread 5 changing a local does **not** affect thread 6. This is just
the ordinary memory the base CPU already has.

What makes the threads a *team* is the **shared data memory**: one array that
**all 32 threads read and write**, through `getdata`/`setdata`. Think of it as the
GPU's "global memory." Thread 5's `setdata(0, 9)` is visible to thread 6's
`getdata(0)`.

The shared data memory is a **32 × 32 grid** of 8-bit values (1024 cells, values
0..255). You address it with a single index `0..1023`; cell `(row, col)` is at
index `row*32 + col`. Because it's a grid, you can also **look at it as a picture**
(see §4) — but nothing forces that; it's just an array of numbers you can use
however you like.

> **Collisions.** If two threads write the *same* cell in the same moment, the
> result is one of the two values (don't rely on which). The example kernels avoid
> this by giving each thread its own cells — e.g. thread `tid` only ever writes
> row `tid`.

---

## 3. Running many threads in the simulator

The Python simulator can run all 32 threads for you and show you the shared result:

```
python3 python_scripts/toolchain/cli.py build examples/gpu_inc.c \
    --threads 32 --data-text
```

- `--threads 32` runs your program once for each `tid = 0..31`, all sharing **one**
  data memory. (Each thread still gets its own private memory, reloaded fresh.)
- `--data-text` prints the shared grid as ASCII (`#` = nonzero, `.` = zero).
- `--data-image out.ppm` writes the grid as a grayscale image you can open.
- `--data-width` / `--data-height` change the grid shape (default 32×32).

To run a **single** thread with a chosen id (handy for debugging one lane):

```
python3 python_scripts/toolchain/cli.py build examples/gpu_draw.c --tid 5 --data-image row5.ppm
```

Here `rdtid` returns whatever you pass to `--tid` (default 0).

---

## 4. The two example kernels

**`examples/gpu_inc.c` — read, add one, write back (the required kernel).**
Each thread bumps *its own* cell of the shared data memory:

```c
int i = tid;
setdata(i, getdata(i) + 1);
```

The memory starts all-zero, so after all 32 threads run, cells 0..31 hold `1`
(the top row of the grid). No loop over the array — the 32 threads cover the 32
cells simultaneously. That is data parallelism.

**`examples/gpu_draw.c` — paint an image.** Thread `tid` fills row `tid`:

```c
int y = tid;
for (int x = 0; x < 32; x = x + 1)
    setdata(y*32 + x, (y + x) * 4);   // brightness = (row + col) * 4
```

`--data-image gpu_draw.ppm` shows a smooth diagonal gradient (dark top-left →
bright bottom-right).

---

## 5. How the hardware supplies `tid` (the SystemVerilog side)

Your `cpu.sv` is **one thread**. The provided `io_top.sv` instantiates many
copies of it in a loop, and hands each copy a different `tid`:

```systemverilog
for (i = 0; i < THREADS; i++) begin : g_thread
    cpu u_cpu ( .clk(...), .rst(...), .tid(i), ...,   // <-- each copy gets its own id
                .dt_we(...), .dt_addr(...), .dt_wdata(...),
                .dt_raddr(...), .dt_rdata(...) );
end
```

So *your* SystemVerilog is what decides the value `int x = tid;` sees: it is just
the `tid` input wire, tied to the instance number. Inside `cpu.sv` the three new
instructions are a few lines:

- `rdtid rd` → `registers[rd] <= tid;`
- `setdt rs1,rs2` → pulse `dt_we` for one clock with `dt_addr = registers[rs1]`,
  `dt_wdata = registers[rs2]`. It's a fire-and-forget write — unlike `putchar`,
  it never has to wait.
- `getdt rd,rs1` → drive `dt_raddr = registers[rs1]`; `dt_rdata` is the value; write
  it into `rd`. The read is combinational, so it finishes in the same cycle.

The shared data memory itself is the provided `datamem.sv`; a display (or the Pi,
over I2C) can scan it out to show the picture.

---

## 6. How many threads fit on the board (32 is a *simulator* number)

The programming model has 32 threads, but the **board runs far fewer** — and
that's the normal GPU story in miniature: the model has many threads; the silicon
runs as many as it has room for.

One CPU core is a lot of logic — about **7,500 LUTs** on the Boolean Board's FPGA
(`xc7s50`), most of it the 32-entry register file. Thirty-two of them would be
~240,000 LUTs, and the chip has only **32,600**. Measured (Vivado 2025.2 synthesis
of `io_top`):

| threads | LUTs used | % of the xc7s50 | fits? |
|--------:|----------:|----------------:|:-----:|
| 1  | 7,508   | 23%   | ✅ |
| 2  | 19,806  | 61%   | ✅ |
| 4  | 54,670  | 168%  | ❌ |
| 32 | 523,317 | 1605% | ❌ |

(Keeping each thread's memory small means BRAM is *not* the limit — 32 threads use
only 32 of 75 block-RAM tiles. It's the logic that runs out.)

So:

- **On the board**, `io_top.sv` sets `THREADS = 2` — the most that fits
  comfortably. You'll see the first two rows of the image painted.
- **In the simulator**, `--threads 32` runs all 32 threads and shows the whole
  picture. That is the real GPU result.

Same program, same per-thread behavior; the simulator just isn't limited by how
much logic fits on one small FPGA. (Raising `THREADS` in `io_top.sv` above 2 is a
simulation/utilization experiment — it won't place-and-route on this device.)
