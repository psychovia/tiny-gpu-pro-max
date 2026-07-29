# Compiling and Simulating a Program

This guide walks you from a `.c` source file to a running program on the
teaching RISC-V toolchain — assuming you have **never compiled anything
before** and are **new to the terminal**. 

> **TL;DR for the whole guide:** open a terminal in the project folder (`Lab4/`)
> and run `python3 python_scripts/toolchain/cli.py build yourprogram.c --dump a0`. That
> compiles your C, turns it into machine code, runs it, and prints the result.
> That's the whole job.

You can skip to the end for a short list of commands you might need.

---

## 1. Before you start

**What's a terminal?** It's a text window where you type commands instead of
clicking. On the lab machines, open the app called **Terminal**. You'll see a
*prompt* (often ending in `$`) waiting for you to type.

**Three commands are all the "bash" you need here:**

| Command | What it does |
|---|---|
| `ls` | **l**i**s**t the files in the current folder |
| `cd somefolder` | **c**hange **d**irectory (go into a folder) |
| `cd ..` | go up one folder |

**Get into the project folder.** Wherever you unzipped the lab, there is a
folder named `Lab4/`. Move into it:

```bash
cd path/to/Lab4     # Probably do: cd ~/Lab4
ls                  # you should see doc/, python_scripts/, examples/, SystemVerilog/
```

Everything below assumes your terminal is **inside `Lab4/`** (the project root).
The toolchain itself lives in `python_scripts/`, which is why the commands
below start with `python3 python_scripts/toolchain/cli.py`.

**Check Python.** This toolchain is plain Python — nothing to install.

```bash
python3 --version   # should say Python 3.6 or newer
```

If that prints a version number, you're ready.

---

## 2. The one command you need: `build`


Say you have a file `prog.c`. One command does everything:

```bash
python3 python_scripts/toolchain/cli.py build prog.c --dump a0
```

- **`build`** = do the whole pipeline (compile → assemble → run).
- **`prog.c`** = your C source file.
- **`--dump a0`** = after the program finishes, print the register `a0`. In C,
  whatever `main` **returns** ends up in `a0`, so this shows your answer.

Here is a real run using one of the example programs (`examples/sum.c`, which
adds `1 + 2 + … + 10`):

```
$ python3 python_scripts/toolchain/cli.py build examples/sum.c --dump a0
wrote examples/sum.asm
wrote examples/sum.mem
wrote examples/sum.lst
=== program halted at PC=0x00000008 (cycles=648) ===
halted=True  cycles=648  PC=0x00000008  sp=0x00010000
  a0   = 0x00000037  (         55 u32,          55 s32)
```

The last line is the answer: `a0 = 55`. (We explain how to read this in
section 4.)

If your program uses `print(...)`, that text shows up too:

```
$ python3 python_scripts/toolchain/cli.py build examples/divmod.c --dump a0
wrote examples/divmod.asm
wrote examples/divmod.mem
wrote examples/divmod.lst
14
2
-14
-2
=== program halted at PC=0x00000008 (cycles=3027) ===
halted=True  cycles=3027  PC=0x00000008  sp=0x00010000
  a0   = 0x0000000E  (         14 u32,          14 s32)
```

The `14 / 2 / -14 / -2` lines are what the program printed; `a0 = 14` is what
it returned.

---

## 3. What just happened? (the pipeline)

> **TL;DR:** Your `.c` becomes assembly (`.asm`), then machine code (`.mem`),
> then it runs. `build` does all three; you can also do them one at a time with
> `compile`, `asm`, and `run`.

`build` is really three smaller steps stitched together:

```
  prog.c  ──compile──▶  prog.asm  ──assemble──▶  prog.mem   ──run──▶  result
 (your C)             (assembly,             (machine code,        (the
                       human-readable)        1s and 0s)            simulator)
```

You can run each step yourself, which is handy when you want to *look* at the
in-between files:

**Step 1 — compile (C → assembly).**
```bash
python3 python_scripts/toolchain/cli.py compile prog.c       # writes prog.asm
```
`prog.asm` is **assembly**: the same program written as a list of simple RISC-V
instructions (one operation per line). It's human-readable — open it and look.

**Step 2 — assemble (assembly → machine code).**
```bash
python3 python_scripts/toolchain/cli.py asm prog.asm         # writes prog.mem and prog.lst
```
- `prog.mem` is the **machine code**: one 32-bit instruction per line, written
  as 32 `0`/`1` characters. **This is the file your CPU loads** (and what the
  SystemVerilog `$readmemb` reads).
- `prog.lst` is a **listing**: a side-by-side view of the address, the machine
  code word, and the assembly it came from. It's for *you* to read, not the
  machine.

**Step 3 — run (machine code → result).**
```bash
python3 python_scripts/toolchain/cli.py run prog.mem --dump a0
```
This is the **simulator** — a Python program that pretends to be the CPU and
executes your machine code one instruction at a time.

> The point of separating these: the `.mem` from step 2 is exactly what you'll
> eventually load onto the CPU **you build** in this lab. The simulator just
> lets you check what a *correct* CPU should do with it.

---

## 4. Reading the simulator's output

> **TL;DR:** `a0` is `main`'s return value. `print(...)` text appears as plain
> lines. `cycles` is how many instructions ran. Use `--dump a0,a1,sp` to see
> chosen registers, or `--dump-all` for everything.

A finished run prints a small report:

```
=== program halted at PC=0x00000008 (cycles=648) ===
halted=True  cycles=648  PC=0x00000008  sp=0x00010000
  a0   = 0x00000037  (         55 u32,          55 s32)
```

- **`halted=True`** — the program ended normally (it hit the `ebreak` "stop"
  instruction). Good.
- **`cycles=648`** — it executed 648 instructions before stopping.
- **`PC`** — the program counter (which instruction it stopped on).
- **`sp`** — the stack pointer (where the call stack is).
- **`a0 = 0x00000037 ( 55 u32, 55 s32)`** — register `a0`, shown three ways:
  in hex (`0x37`), as an **u**nsigned 32-bit number (`55`), and as a **s**igned
  32-bit number (`55`). For a value like `-7` you'd see
  `0xFFFFFFF9 ( 4294967289 u32, -7 s32)` — the signed column is usually the one
  you want.

**Choosing what to print:**
```bash
python3 python_scripts/toolchain/cli.py run prog.mem --dump a0,a1,sp   # just these (names or x10,x11,x2)
python3 python_scripts/toolchain/cli.py run prog.mem --dump-all        # all 32 registers
```

**Where does `print(x)` go?** Straight to your terminal, as decimal text, one
value per line — exactly where you see `14 / 2 / -14 / -2` above.

**Where does `scanf(...)` read from?** From whatever you type. When the program
reaches a `scanf`, it **waits** — type the number, press Enter, and it continues:

```bash
python3 python_scripts/toolchain/cli.py build prog.c --dump a0
```

Numbers can be separated by spaces or by pressing Enter between them — `scanf`
skips the whitespace, just like real C. (If a program keeps reading until the
input runs out, press **Ctrl-D** to signal "that's the end.")

*Already comfortable with the shell?* You can skip the typing and feed the input
straight in — `echo "1 2 3" | …` or `… < input.txt` — which is handy for testing
lots of cases quickly.

---

## 5. A full worked example

> **TL;DR:** Write C, run `build`, read `a0`.

Create a file `mysum.c`:

```c
int main() {
    int total = 0;
    for (int i = 1; i <= 100; i = i + 1) {
        total = total + i;
    }
    return total;          // 1 + 2 + ... + 100 = 5050
}
```

Build and run it:

```bash
python3 python_scripts/toolchain/cli.py build mysum.c --dump a0
```

The bottom line will read `a0 = 0x000013BA ( 5050 u32, 5050 s32)`. That's
`5050` — your answer.

---

## 6. The C you can write

> **TL;DR:** Plain `int` math, `if/else`, `while`, `do-while`, `for`,
> `switch`, functions (any number of args, recursion OK), arrays (1-D *or*
> multi-dimensional), pointers (any depth, with `&` and `*`), `/`, `%`,
> `print(x)`, and `scanf("%d", &x)`. Anything fancier is politely refused with
> an error.

**You can use:**

- **`int` only** — every variable and value is a 32-bit signed integer.
  Numbers can be decimal (`42`), hex (`0x2A`), or binary (`0b101010`).
- **Math & logic:** `+ - * / % & | ^ ~ << >>`, comparisons
  `== != < <= > >=`, and `&& || !`. Yes — `/` and `%` work (the compiler builds
  them out of simpler instructions for you).
- **Assignment:** `=`, and the shorthands `+= -= *= /= %= &= |= ^= <<= >>=`,
  plus `++` and `--`.
- **Control flow:** `if/else`, `while`, `do { } while`, `for`, `switch`
  (`case`/`default`, with C fall-through), `break`, `continue`, `return`.
- **Functions:** any number of parameters (the first 8 arrive in registers, the
  rest on the stack), one `int` return value, and **recursion**.
- **Arrays:** `int` arrays, 1-D or multi-dimensional (`int a[10];`,
  `int m[3][4];`), global or local. Index with `a[i]` / `a[i][j]` for reading
  and writing.
- **Pointers:** of any depth (`int *p;`, `int **pp;`). Take an address with
  `&x`, follow one with `*p`, do pointer arithmetic (`p + n`, `p - q`, `p[i]`),
  and pass them to functions. Arrays decay to pointers, just like in real C.
- **`print(x)`** — prints one integer as decimal, followed by a newline.
- **`scanf("%d", &x)`** — reads one integer from the input into `x`. Use `%d`
  for signed or `%u` for unsigned, and you can read several at once
  (`scanf("%d %d", &a, &b)`). Each thing you read needs a `&` (an address) to
  store into. It returns how many numbers it actually read, or `-1` at the end
  of the input — so the classic loop `while (scanf("%d", &x) == 1) { ... }`
  reads until the input runs out. See §4 for how to feed it input.

**GPU variant only** (see `GPU_explained.md`):

- **`tid`** — a read-only value: this thread's id (0..31). Use it in expressions,
  e.g. `int x = tid;`. You can't assign to it.
- **`setdata(i, v)`** — write value `v` into cell `i` of the shared data memory.
- **`getdata(i)`** — read and return cell `i` of the shared data memory.

Run all 32 threads and see the shared result with `--threads 32`, and view the
data as an image or text grid:

```
python3 python_scripts/toolchain/cli.py build examples/gpu_draw.c \
    --threads 32 --data-image gpu_draw.ppm --data-text
```

(`--tid N` runs a single thread with a chosen id.)

**The toolchain will refuse (with a clear, line-pointing error):** `float`,
`char`, `double`, structs, unions, enums, casts, `sizeof`, function pointers,
the ternary `?:`, `#include`/`#define`, and so on. It tells you *exactly* what's
wrong rather than producing a broken program.

One quirk to know: variables are **function-scoped** (there's no block
scoping). So you can't declare `int i` twice in the same function — declare your
loop variable once and reuse it.

---

## 7. Watching it run, and when things go wrong

> **TL;DR:** Read the error — it points at the exact line. `--trace` shows every
> instruction. Warnings flag likely bugs; `--strict` turns the first one into a
> hard stop. `--max-cycles` catches infinite loops.

**Compile errors** point right at the problem with a caret (`^`):

```
$ python3 python_scripts/toolchain/cli.py build broken.c
broken.c:3:5: error: expected ';', got 'return'
        return x;
        ^^^^^^
```
Here line 2 was missing its semicolon, so the compiler tripped on line 3. Fix
the line shown and rebuild.

**Watch it execute** instruction-by-instruction:
```bash
python3 python_scripts/toolchain/cli.py run prog.mem --trace
```
Each line shows the cycle number, the address, and the instruction that ran.
Great for understanding *exactly* what your program does — and later, for
checking your CPU against it.

**Warnings** are friendly nudges about things that are *usually* bugs (reading
memory you never wrote, a stack pointer that wandered into your code, returning
without a return address, a loop that makes no progress, …). They print at the
end but the program keeps running. To make the **first** warning stop the
program (useful when hunting a bug):
```bash
python3 python_scripts/toolchain/cli.py run prog.mem --strict
```

**Infinite loop?** The simulator gives up after a budget of instructions and
tells you. Raise or lower the budget with:
```bash
python3 python_scripts/toolchain/cli.py run prog.mem --max-cycles 1000000
```

---

## 8. How compilers work (optional)

> **TL;DR: You do not need this section for the lab.** Knowing how a compiler
> works is *not* required to design a CPU — the CPU only ever sees the finished
> machine code. This is here purely because it's interesting.

A **compiler** is a translator. It reads your C — which is written for humans —
and rewrites it as **assembly**, a list of tiny steps the hardware can actually
do (add two registers, load from memory, jump to a label, …). The assembler
then turns each assembly line into a 32-bit number; that's the machine code.

You can think of it as translating *intent* into *mechanical steps*. A few
examples of the kind of rewriting it does (these are simplified — the real
output is more verbose; peek at any `examples/*.lst` to see the genuine
article):

**A `for` loop becomes a test, a body, and a jump back.** There's no "for" in
hardware — only "compare" and "jump." So:

```c
for (i = 0; i < n; i = i + 1) {
    body;
}
```
turns into something shaped like:

```asm
        ...                 # i = 0
loop:   bge   i, n, done    # if i >= n, leave the loop
        body                # ... the loop body ...
        addi  i, i, 1       # i = i + 1
        j     loop          # go back and test again
done:   ...
```
A `while` loop is the same idea without the `i = i + 1`; `break` is just
`j done`, and `continue` is a jump back to the test.

**A function call becomes "jump and remember where to come back."**

```c
int y = square(5);
```
becomes roughly:

```asm
        li    a0, 5         # put the argument 5 in a0
        call  square        # jump to square, remembering the return address
        # square leaves its answer in a0; copy it into y's slot
        sw    a0, y_slot(s0)
```
Inside, `square` does its work and runs `ret`, which jumps back to the
instruction right after the `call`. Arguments go in registers `a0..a7`; the
answer comes back in `a0`. That convention — who puts what where — is the only
reason a caller and a callee can understand each other.

**An `if` becomes a conditional jump.**

```c
if (x > 0) { a; } else { b; }
```
becomes:

```asm
        ble   x, 0, else_   # if NOT (x > 0), jump to the else part
        a                   # the "then" part
        j     end_
else_:  b                   # the "else" part
end_:   ...
```

That's the whole trick, repeated: every high-level construct becomes some
combination of **compute**, **load/store**, **compare**, and **jump**. The
compiler's job is to choose those steps; **your CPU's job is just to execute
them** — which is why you don't need any of this section to build one.

---

## 9. Command cheat-sheet

```bash
# one-shot: compile + assemble + run, show the return value
python3 python_scripts/toolchain/cli.py build prog.c --dump a0

# the three steps on their own
python3 python_scripts/toolchain/cli.py compile prog.c          # -> prog.asm   (assembly)
python3 python_scripts/toolchain/cli.py asm     prog.asm        # -> prog.mem + prog.lst (machine code + listing)
python3 python_scripts/toolchain/cli.py run     prog.mem --dump a0

# useful run/build options
--dump a0,a1,sp     show specific registers (ABI names or x0..x31)
--dump-all          show all 32 registers
--trace             print every instruction as it executes
--strict            stop on the first warning
--max-cycles N      change the infinite-loop cutoff (default 10,000,000)
```

That's everything you need to compile, run, and inspect a program. When you're
ready, the `.mem` file you produce is exactly what your CPU will run.
