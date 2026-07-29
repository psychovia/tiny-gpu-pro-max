# The ISA, Explained — Teaching RV32I + `mul`

## 0. What's an ISA? (start here if you've only ever written Python)

If you've written some Python but never really thought about what's *underneath*
it, start here. Already comfortable with "registers, memory, machine code"? Jump
to §1.

**A CPU is the chip that actually runs programs** — and it does almost laughably
simple things, billions of times a second. It can add two numbers, compare two
numbers, copy a number to or from memory, or jump to a different spot in the
program. That's basically it. Everything a computer does is built out of
mountains of those tiny steps.

When you run Python you never see this: the Python *interpreter* (itself a
program) reads your `.py` and does the work. The CPU underneath has no idea what
a `for` loop or a list is — it only understands **machine code**: long sequences
of plain numbers, where each number encodes one tiny operation like "add
register 5 to register 6, put the result in register 7."

The numbers a program works on live in two places:

- **Registers** — a *tiny* set of slots built into the CPU itself (this one has
  **32**, each holding a 32-bit integer). They're the only things the CPU can do
  arithmetic on directly: blazing fast, but there are only a handful.
- **Memory** — a big array of bytes for everything that doesn't
  fit in registers: arrays, the call stack, large data. The CPU moves values
  between memory and registers with *load* and *store* instructions.

An **instruction** is one of those tiny operations, written as a 32-bit number.
A whole program is just a list of these numbers sitting in memory; the CPU reads
them one after another — tracking "where am I?" in a special register called the
**program counter** — does what each says, and moves on.

So what's an **ISA** (Instruction Set Architecture)? It's the **contract** that
pins down exactly what those numbers mean: the full list of instructions the CPU
understands, what each one does, how each is spelled out in bits, how many
registers exist, how memory behaves, and how the machine starts and stops. It's
the agreed boundary between **software** (the compiler, which *produces* the
instructions) and **hardware** (the CPU, which *obeys* them). 

**Why this matters for the lab:** the compiler turns your C program into exactly
these instructions (the `.mem` file). Then *you* build a CPU — in SystemVerilog,
on the FPGA — that reads those instruction-numbers and does precisely what this
ISA says each one means. Get the ISA right and *any* program the compiler emits
just runs on your CPU. This particular ISA is a small, honest slice of
**RISC-V** (a real, modern, open instruction set used in everything from tiny
microcontrollers to servers) — small enough to build in a few days, real enough
that what you learn transfers directly to the genuine article.

The rest of this document is the precise reference for that contract.

---

This is the authoritative reference for the instruction set the toolchain
targets and that you will implement as a CPU. It is a deliberately small subset
of **RV32I** (the 32-bit RISC-V base integer ISA) plus the **`mul`** instruction
from the M extension. Everything here matches `isa.py` (encoding) and
`simulator.py` (behaviour) exactly; if in doubt, those files are the ground
truth.

This subset is faithful RISC-V wherever it overlaps with the real thing, so the
simulator is a reliable reference to check your own CPU against. The few
intentional simplifications are listed at the end under **Differences from
standard RISC-V**.

---

## 1. Architectural state

- **32 general-purpose registers**, `x0`–`x31`, each 32 bits.
  - **`x0` is hardwired to 0.** Reads give 0; writes are discarded.
- A 32-bit **program counter** `pc`. Instructions are 4 bytes, so `pc` is always
  a multiple of 4.
- **Memory**: byte-addressable, little-endian, 64 KiB by default
  (`--mem-size`). Word accesses must be 4-byte aligned; half-word accesses
  2-byte aligned. The stack pointer starts at the top of memory and grows down.

### Endianness (little-endian)

Memory is addressed one byte at a time, but values are 32 bits, so a word spans
four consecutive byte addresses. **Endianness** is just the convention for which
byte goes where. RISC-V (like x86) is **little-endian**: the *least*-significant
byte is stored at the *lowest* address. (Big-endian, used by some other
machines, is the reverse — most-significant byte first.)

Concretely, storing the word `0xDEADBEEF` at address `0x100`:

```
address:  0x100  0x101  0x102  0x103
byte:     0xEF   0xBE   0xAD   0xDE      <- little-endian (low byte first)
```

So `lw` from `0x100` reads back `0xDEADBEEF`, while `lb` from `0x100` reads the
single byte `0xEF`. This is the same ordering the `.mem` file uses (§7). Whole-
word `lw`/`sw` never have to think about it — it only matters for byte and
half-word accesses.

### Register names

Each register can be referred to by its number (`x0`–`x31`) or by a short,
friendlier name. Apart from `x0`, which is **always 0** (the hardware wires it
that way), these names just describe the *usual job* a register tends to do —
holding a return address, the stack pointer, a function's arguments, or scratch
values. **You don't have to worry about most of this:** when you write C, the
compiler decides which register holds what. Treat the table below as a lookup
you can come back to, not something to memorize. Might come in handy for an interview someday, x86 has similar roles and conventions.

| Reg | ABI | Role | Saved by |
|-----|-----|------|----------|
| x0 | `zero` | constant 0 | — |
| x1 | `ra` | return address | caller |
| x2 | `sp` | stack pointer | callee |
| x3 | `gp` | global pointer (unused) | — |
| x4 | `tp` | thread pointer (unused) | — |
| x5–x7 | `t0`–`t2` | temporaries | caller |
| x8 | `s0`/`fp` | saved / frame pointer | callee |
| x9 | `s1` | saved | callee |
| x10–x11 | `a0`–`a1` | args / return value | caller |
| x12–x17 | `a2`–`a7` | args | caller |
| x18–x27 | `s2`–`s11` | saved | callee |
| x28–x31 | `t3`–`t6` | temporaries | caller |

---

## 2. Instruction formats

Every instruction is 32 bits. Field bit-positions are fixed across formats:

```
opcode -> [6:0]      rd  -> [11:7]    funct3 -> [14:12]
rs1    -> [19:15]    rs2 -> [24:20]   funct7 -> [31:25]
```

What each field means (these names show up everywhere):

- **`opcode`** — the broad *category* of instruction (arithmetic, load, store,
  branch, jump, …). The CPU reads this first to know what kind of instruction
  it's looking at.
- **`rd`** — the **destination register**: where the result is written.
- **`rs1`, `rs2`** — the **source registers**: which registers hold the input
  value(s) the instruction works on.
- **`funct3`, `funct7`** — extra *function-select* bits. Together with the
  opcode they pin down the *exact* operation — e.g. one opcode covers all
  register-to-register math, and `funct3`/`funct7` choose add vs. subtract vs.
  XOR vs. shift.
- **`imm`** — an **immediate**: a constant baked right into the instruction
  itself, like the `5` in `x + 5`, how far a branch jumps, or part of a memory address.

Not every field appears in every instruction — that's what the *formats* below
are. Each format is simply a different way of packing these fields into the 32
bits, depending on what the instruction needs (two registers and a result; a
register and a constant; a jump target; …).

| Format | Layout (high → low) | Used by |
|--------|---------------------|---------|
| **R** | funct7 · rs2 · rs1 · funct3 · rd · opcode | register-register ops |
| **I** | imm[11:0] · rs1 · funct3 · rd · opcode | immediates, loads, `jalr` |
| **S** | imm[11:5] · rs2 · rs1 · funct3 · imm[4:0] · opcode | stores |
| **B** | imm[12\|10:5] · rs2 · rs1 · funct3 · imm[4:1\|11] · opcode | branches |
| **U** | imm[31:12] · rd · opcode | `lui`, `auipc` |
| **J** | imm[20\|10:1\|11\|19:12] · rd · opcode | `jal` |

The **B-type and J-type immediates are scrambled** (the bits are not
contiguous) — see §4. 

---

## 3. Instruction set

A few shorthands used in the tables below:

- `rd` is the destination register; `rs1`, `rs2` are the source register
  **values** (unsigned 32-bit). "signed" means interpret those bits as two's
  complement; all results are kept to 32 bits (taken mod 2³²).
- **`sext(x)`** — *sign-extend* `x` to 32 bits: copy its top (sign) bit leftward
  so that a negative value stays negative. It's just "sign-extend," abbreviated.
- **`shamt`** — *shift amount*: how many bit positions to shift (0–31).
- **`ea`** — the *effective address* a load or store computes (`rs1 + sext(imm)`).
- **`MEM8`/`MEM16`/`MEM32[a]`** — the 1-, 2-, or 4-byte value in memory at
  address `a`.

### R-type — register/register (`opcode = 0110011`)

| Mnemonic | funct3 | funct7 | Operation |
|----------|--------|--------|-----------|
| `add`  | 000 | 0000000 | rd = rs1 + rs2 |
| `sub`  | 000 | 0100000 | rd = rs1 − rs2 |
| `sll`  | 001 | 0000000 | rd = rs1 << (rs2 & 31) |
| `slt`  | 010 | 0000000 | rd = (signed rs1 < signed rs2) ? 1 : 0 |
| `sltu` | 011 | 0000000 | rd = (unsigned rs1 < unsigned rs2) ? 1 : 0 |
| `xor`  | 100 | 0000000 | rd = rs1 ^ rs2 |
| `srl`  | 101 | 0000000 | rd = rs1 >> (rs2 & 31)  (logical, zero-fill) |
| `sra`  | 101 | 0100000 | rd = rs1 >> (rs2 & 31)  (arithmetic, sign-fill) |
| `or`   | 110 | 0000000 | rd = rs1 \| rs2 |
| `and`  | 111 | 0000000 | rd = rs1 & rs2 |
| `mul`  | 000 | 0000001 | rd = low 32 bits of rs1 × rs2 (M extension) |

### I-type arithmetic (`opcode = 0010011`)

The 12-bit immediate is sign-extended to 32 bits.

| Mnemonic | funct3 | Operation |
|----------|--------|-----------|
| `addi`  | 000 | rd = rs1 + sext(imm) |
| `slti`  | 010 | rd = (signed rs1 < sext(imm)) ? 1 : 0 |
| `sltiu` | 011 | rd = (unsigned rs1 < unsigned sext(imm)) ? 1 : 0 |
| `xori`  | 100 | rd = rs1 ^ sext(imm) |
| `ori`   | 110 | rd = rs1 \| sext(imm) |
| `andi`  | 111 | rd = rs1 & sext(imm) |

### Shift-immediate (`opcode = 0010011`)

The shift amount is the low 5 bits (`shamt`, 0–31); `funct7` selects logical
vs arithmetic.

| Mnemonic | funct3 | funct7 | Operation |
|----------|--------|--------|-----------|
| `slli` | 001 | 0000000 | rd = rs1 << shamt |
| `srli` | 101 | 0000000 | rd = rs1 >> shamt  (logical) |
| `srai` | 101 | 0100000 | rd = rs1 >> shamt  (arithmetic) |

### Loads (I-type, `opcode = 0000011`)  — effective address = rs1 + sext(imm)

A load **reads a value from memory**: it computes the *effective address*
`ea = rs1 + sext(imm)`, fetches the byte / half-word / word stored there, and
writes it into `rd`. The signed forms (`lb`, `lh`) sign-extend the fetched value
to 32 bits; the unsigned forms (`lbu`, `lhu`) zero-extend it; `lw` reads a full
32-bit word.

| Mnemonic | funct3 | Operation |
|----------|--------|-----------|
| `lb`  | 000 | rd = sign-extend( MEM8 [ea] ) |
| `lh`  | 001 | rd = sign-extend( MEM16[ea] )  (2-byte aligned) |
| `lw`  | 010 | rd = MEM32[ea]                 (4-byte aligned) |
| `lbu` | 100 | rd = zero-extend( MEM8 [ea] ) |
| `lhu` | 101 | rd = zero-extend( MEM16[ea] )  (2-byte aligned) |

### Stores (S-type, `opcode = 0100011`) — effective address = rs1 + sext(imm)

`rs2` holds the value being stored.

| Mnemonic | funct3 | Operation |
|----------|--------|-----------|
| `sb` | 000 | MEM8 [ea] = rs2[7:0] |
| `sh` | 001 | MEM16[ea] = rs2[15:0]  (2-byte aligned) |
| `sw` | 010 | MEM32[ea] = rs2        (4-byte aligned) |

### Branches (B-type, `opcode = 1100011`) — if taken, `pc = pc + sext(imm)`

A branch **reads `rs1` and `rs2`**, compares them, and writes *no* register
(there is no `rd`). If the condition below holds, the next `pc` becomes
`pc + sext(imm)`; otherwise execution simply falls through to the following
instruction (`pc + 4`). The immediate is a signed byte offset relative to the
branch instruction (range about ±4 KiB; always even).

| Mnemonic | funct3 | Taken when |
|----------|--------|------------|
| `beq`  | 000 | rs1 == rs2 |
| `bne`  | 001 | rs1 != rs2 |
| `blt`  | 100 | signed rs1 < signed rs2 |
| `bge`  | 101 | signed rs1 ≥ signed rs2 |
| `bltu` | 110 | unsigned rs1 < unsigned rs2 |
| `bgeu` | 111 | unsigned rs1 ≥ unsigned rs2 |

### Upper-immediate (U-type)

The operand is the 20-bit value placed in bits [31:12].

| Mnemonic | opcode | Operation |
|----------|--------|-----------|
| `lui`   | 0110111 | rd = imm << 12 |
| `auipc` | 0010111 | rd = pc + (imm << 12) |

### Jumps

| Mnemonic | format / opcode | Operation |
|----------|-----------------|-----------|
| `jal rd, imm`        | J, 1101111 | rd = pc + 4; pc = pc + sext(imm) |
| `jalr rd, rs1, imm`  | I, 1100111 (funct3 000) | rd = pc + 4; pc = (rs1 + sext(imm)) & ~1 |

### System (`opcode = 1110011`, funct3 000)

Distinguished by the 12-bit immediate: `0` → `ecall`, `1` → `ebreak`.

| Mnemonic | exact word | Behaviour |
|----------|-----------|-----------|
| `ecall`  | `0x00000073` | **I/O**, selected by the service number in `a7` (see §5): `a7=1` reads one byte into `a0`, otherwise emits the low byte of `a0` as one character. On the FPGA each blocks until the rx/tx FIFO is ready. |
| `ebreak` | `0x00100073` | **Halt** the machine; `pc` stays at the `ebreak`. |

Any other instruction word (e.g. `fence`, `csr*`, all-zeros, an unknown
funct combination) is an **illegal instruction** and halts the simulator with
an error.

### Custom-0 — GPU extension (`opcode = 0001011`)

The GPU variant of this lab adds one nonstandard opcode, holding three
instructions chosen by `funct3`. Standard RISC-V reserves `custom-0` for exactly
this kind of local extension. These use the R-type field layout. The plain
(non-GPU) CPU never sees them. The *why* is in `GPU_explained.md`; the exact bit
layouts and decode logic are in `custom_instructions.md`.

| Mnemonic | funct3 | Operation |
|----------|--------|-----------|
| `rdtid rd`       | `000` | `rd = tid` — this thread's id (0..THREADS-1); no source registers |
| `setdt rs1, rs2` | `001` | shared `data[rs1] = rs2` — write one cell; **no** `rd`; never blocks |
| `getdt rd, rs1`  | `010` | `rd = data[rs1]` — read one cell of the shared data memory |

`setdt` is the *other* way a value leaves the CPU, but unlike `ecall` it is
fire-and-forget: it writes one cell of the shared data memory and never stalls
(there is no "data memory full").

---

## 4. Immediate encoding (the scrambled fields)

I/S immediates are straightforward 12-bit signed values (S splits them into
`[11:5]` and `[4:0]`). B and J scatter their bits:

**B-type** (13-bit signed byte offset, bit 0 always 0):

| instruction bit | imm bit |
|---|---|
| inst[31] | imm[12] |
| inst[30:25] | imm[10:5] |
| inst[11:8] | imm[4:1] |
| inst[7] | imm[11] |

**J-type** (21-bit signed byte offset, bit 0 always 0):

| instruction bit | imm bit |
|---|---|
| inst[31] | imm[20] |
| inst[30:21] | imm[10:1] |
| inst[20] | imm[11] |
| inst[19:12] | imm[19:12] |

`U`-type places imm in bits [31:12] directly.

---

## 5. The I/O convention (`ecall`) and `ebreak`

All I/O is `ecall`, dispatched on a **service number in `a7`** (the standard
RISC-V convention). Just two services, each moving **one byte**:

| `a7` | service | behaviour |
|------|---------|-----------|
| `1`  | **getchar** | read one input byte into `a0` |
| anything else (e.g. `0`) | **putchar** | send the low byte of `a0` to the output |

Input/output is stdin/stdout in the simulator, and the **rx/tx FIFOs** (Part A) on
the FPGA. On the FPGA the two services **block** — and getting this right is the
heart of your `cpu.sv`:

- **getchar waits while rx is empty** — stall the CPU until a byte arrives.
- **putchar waits while tx is full** — stall until there's room.

The compiler builds `print` and `scanf` out of these one-byte services, so your
CPU only ever moves a single byte — it never formats anything.

`ebreak` stops the machine.

---

## 6. No hardware divide — `/` and `%` are software

The ISA includes `mul` but **no `div`/`rem`**. The compiler implements C `/`
and `%` by calling a software routine (`__divmod`) built from shifts,
subtracts, and compares (a 32-iteration restoring division). Signed division
follows C99: the quotient truncates toward zero and the remainder takes the
sign of the dividend. This keeps the CPU you build simple — you never need a
divider.

---

## 7. The `.mem` and `.lst` files

**`.mem`** — what `$readmemb` and the simulator load:
- One line per 32-bit word; each line is exactly 32 `0`/`1` characters.
- Line *N* (0-indexed) is the word at byte address `4*N`. Bytes within a word
  are little-endian.
- `//` comments and blank lines are ignored; `_` separators are allowed.

**`.lst`** — a human-readable listing: one row per emitted word showing the
byte address, the 8-hex-digit machine word, and the (expanded) source line.

---

## 8. Simulator diagnostics

The simulator catches the bugs a beginner actually hits.

**Errors (halt the program):** misaligned word/half-word access; load/store
out of memory range; `pc` misaligned or out of range; illegal instruction
word; the all-zero word (a common "ran off the end of the program" symptom);
and exceeding `--max-cycles` (the infinite-loop cutoff).

**Warnings (print and continue; `--strict` turns the first one into an error,
`--no-warnings` silences them):** writing a non-zero value to `x0`; an `sp`
that becomes mis-aligned, climbs above its start, or descends into the program;
excessive stack depth; reading never-initialised memory; `ret` with `ra == 0`;
`ebreak` while still inside a function call; a branch/jump to an address with no
instruction; and a "no progress for many cycles" infinite-loop heuristic.

---

## 9. Differences from standard RISC-V

This subset is real RISC-V where it overlaps, with a few intentional teaching
simplifications:

- **No hardware divide/remainder.** `mul` is included; `div`/`divu`/`rem`/`remu`
  are not. C `/` and `%` are software (§6).
- **`ecall` is a tiny two-service I/O interface** (`a7=1` reads one byte into
  `a0`, otherwise `a0`'s low byte is printed — see §5), not the full Linux/SBI
  syscall ABI. `ebreak` simply halts.
- **Stack alignment is 4-byte**, not the 16-byte boundary the RISC-V psABI
  mandates at calls. Stack-frame alignment is a pure software convention the
  hardware never inspects; 4-byte is what actually matters (it keeps `sw/lw
  off(sp)` aligned) and is simpler to teach.
- **`la` is absolute** — it materialises a label's absolute address with
  `lui`+`addi`. Standard `la` is `auipc`-relative.
- **Not implemented** (treated as illegal instructions): the compressed (`C`)
  extension, `fence`/`fence.i`, CSR instructions, atomics (`A`), and all
  floating point. Instructions are always exactly 32 bits.
- **A `custom-0` opcode (`0001011`) in the GPU variant.** Three instructions,
  `rdtid`, `setdt`, and `getdt`, for the 32-thread graphics demo (§3, and
  `GPU_explained.md`). The plain CPU subset does not include them.

---

## Appendix — Pseudo-instructions (assembler shorthand)

You can skip this unless you're reading a generated `.asm`/`.lst` listing. These
are **not** extra instructions: the assembler rewrites each one into the real
instructions from §3 before producing the `.mem`, so the CPU you build never
sees them — it only ever executes the real instructions.

| Pseudo | Expansion |
|--------|-----------|
| `nop` | `addi x0, x0, 0` |
| `mv rd, rs` | `addi rd, rs, 0` |
| `not rd, rs` | `xori rd, rs, -1` |
| `neg rd, rs` | `sub rd, x0, rs` |
| `seqz rd, rs` | `sltiu rd, rs, 1` |
| `snez rd, rs` | `sltu rd, x0, rs` |
| `j label` | `jal x0, label` |
| `jr rs` | `jalr x0, rs, 0` |
| `ret` | `jalr x0, ra, 0` |
| `call label` | `jal ra, label` (short range) |
| `beqz / bnez rs, label` | `beq / bne rs, x0, label` |
| `bltz/bgez/blez/bgtz rs, label` | `blt/bge` against `x0` (operands swapped as needed) |
| `bgt/ble/bgtu/bleu rs, rt, label` | `blt/bge/bltu/bgeu` with operands swapped |
| `li rd, imm` | `addi` if it fits in 12 bits signed, else `lui` + `addi` (with the sign-correction trick) |
| `la rd, label` | `lui` + `addi` of the label's **absolute** address |
| `push rd` | `addi sp, sp, -4` ; `sw rd, 0(sp)` *(teaching extension)* |
| `pop rd` | `lw rd, 0(sp)` ; `addi sp, sp, 4` *(teaching extension)* |
| `putchar rs` | `addi a0, rs, 0` ; `ecall` *(teaching extension)* |
| `halt` | `ebreak` |

Comments use `#` (RISC-V convention); `;` is also accepted. Directives: `.word`
(one or a comma-separated list of literals/labels).
