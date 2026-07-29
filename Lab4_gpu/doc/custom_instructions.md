# The custom-0 instructions — encoding, decoding, and how to parse them

This is the technical reference for the three GPU instructions added on top of the
base RV32I + `mul` ISA. It is aimed at anyone who has to **decode** them — in your
SystemVerilog `cpu.sv`, or when reading the Python toolchain. For the *why* and
the C-level story, read [`GPU_explained.md`](GPU_explained.md); for the whole ISA,
[`ISA_Explained.md`](ISA_Explained.md).

---

## 1. The one new opcode

All three instructions share a single 7-bit major opcode — RISC-V's **`custom-0`**:

```
opcode = 0b0001011  = 0x0B
```

RISC-V reserves `custom-0` (and `custom-1 = 0x2B`) for exactly this: local, non-
standard instructions. The base ISA never uses `0x0B`, so there is **no decode
ambiguity** — if `instr[6:0] == 0001011`, it is one of ours. Its low two bits are
`11`, so it is still a normal 32-bit instruction (RISC-V requires `[1:0] == 11`).

The three instructions are told apart by **`funct3`** (`instr[14:12]`), exactly the
way standard RISC-V splits operations within an opcode:

| `funct3` | mnemonic | operation | C builtin |
|----------|----------|-----------|-----------|
| `000` | `rdtid rd`       | `rd = tid` (this thread's id) | `tid` |
| `001` | `setdt rs1, rs2` | `data[rs1] = rs2` (shared memory write) | `setdata(i, v)` |
| `010` | `getdt rd, rs1`  | `rd = data[rs1]` (shared memory read) | `getdata(i)` |

Any other `funct3` under `0x0B` is an **illegal instruction**.

---

## 2. Encoding (bit layout)

All three reuse the standard **R-type field layout** — the same field positions as
`add`/`mul` — so you decode their fields with the register extractions you already
wrote. Unused fields are zero. `funct7` (`instr[31:25]`) is always `0000000`.

```
 31        25 24    20 19    15 14  12 11     7 6         0
+------------+--------+--------+------+--------+-----------+
|  funct7=0  |  rs2   |  rs1   |funct3|   rd   | 0001011   |
+------------+--------+--------+------+--------+-----------+
   [31:25]     [24:20]  [19:15] [14:12] [11:7]    [6:0]
```

Which fields each instruction actually uses:

| instruction | uses `rd` | uses `rs1` | uses `rs2` | `funct3` |
|-------------|:---------:|:----------:|:----------:|:--------:|
| `rdtid rd`       | ✔ (dest) |          |          | `000` |
| `setdt rs1, rs2` |          | ✔ (index) | ✔ (value) | `001` |
| `getdt rd, rs1`  | ✔ (dest) | ✔ (index) |          | `010` |

`setdt` has **no destination register** (`rd = 0`), so it never writes the
register file — the value leaves the CPU into the shared data memory. `rdtid` has
**no source registers**.

### Worked examples (the golden words the tests assert)

```
rdtid a0          -> 0x0000050B
  funct7=0000000 rs2=00000 rs1=00000 funct3=000 rd=01010(a0) opcode=0001011

setdt a0, a1      -> 0x00B5100B
  funct7=0000000 rs2=01011(a1) rs1=01010(a0) funct3=001 rd=00000 opcode=0001011

getdt a0, a1      -> 0x0005A50B
  funct7=0000000 rs2=00000 rs1=01011(a1) funct3=010 rd=01010(a0) opcode=0001011
```

Build the word the same way as any R-type:
`word = (funct7<<25) | (rs2<<20) | (rs1<<15) | (funct3<<12) | (rd<<7) | opcode`.

---

## 3. How to decode them

Decoding is two steps: recognise the opcode, then switch on `funct3`. In pseudo-
code (this is exactly what the CPU and the simulator do):

```
opcode = instr[6:0]
if opcode == 0b0001011:                 // custom-0
    rd     = instr[11:7]
    funct3 = instr[14:12]
    rs1    = instr[19:15]
    rs2    = instr[24:20]
    switch (funct3):
        000: rdtid  -> registers[rd]      = tid
        001: setdt  -> data[ registers[rs1] ] = registers[rs2]   // no rd write
        010: getdt  -> registers[rd]      = data[ registers[rs1] ]
        else: illegal instruction
```

Notes that bite if you skip them:

- **`rd == x0`.** As with every RV32I instruction, a write to `x0` is discarded
  (`x0` is hardwired to 0). `rdtid x0` and `getdt x0, rs1` legally compute nothing.
  Guard your writeback with `if (rd != 0)`.
- **`setdt` writes no register.** Its `rd` field is 0; don't let it write the
  register file. It drives the data-memory write port instead.
- **Index width.** `data` has 1024 cells (a 32×32 grid), so only the low 10 bits of
  `registers[rs1]` address it. The hardware truncates to those bits; the Python
  simulator additionally *warns* and ignores an out-of-range index (it never wraps
  silently). Keep indices in `0..1023`.
- **Timing (hardware).** `getdt` reads the data memory combinationally, so — like
  an ALU op — it can write `rd` in the same cycle it executes; it needs no extra
  memory stage. `setdt` is a single-cycle, fire-and-forget write (no stall, unlike
  `putchar`/`ecall`).

---

## 4. How each layer parses them

The pipeline is `C  ->[compiler]->  assembly text  ->[assembler]->  32-bit word
->[simulator | your CPU]->  behaviour`. Each stage has one small, self-contained
place that handles the new instructions.

### 4.1 Compiler — `compiler.py` (C → assembly text)

- **`tid`** is a **keyword** (in `KEYWORDS`). `parse_primary` turns the `tid` token
  into a `VarRef("tid")`; `emit_expr` lowers that to `rdtid t0` and pushes it, just
  like an integer literal. The type system (`_vartype`) treats `tid` as `int`.
  Because it is a keyword, you cannot declare a variable named `tid`.
- **`setdata(i, v)` / `getdata(i)`** are recognised by name in `emit_call`
  (alongside `print`/`scanf`) and are in `RESERVED_NAMES` so a user can't redefine
  them. `setdata` evaluates both args, pops value→`t1` and index→`t0`, emits
  `setdt t0, t1`, and pushes a dummy (it's `void`). `getdata` evaluates its arg into
  `t0`, emits `getdt t0, t0`, and pushes the result.

### 4.2 Assembler — `assembler.py` (assembly text → operands)

Each mnemonic is a real instruction (in `isa.INSTRS`), so it flows through the
format switch. The three new `fmt` values give the operand shapes:

| `fmt` | mnemonic | operands parsed |
|-------|----------|-----------------|
| `CUST_RD`      | `rdtid` | one register → `rd` |
| `CUST_2SRC`    | `setdt` | two registers → `rs1, rs2` |
| `CUST_RD1SRC`  | `getdt` | two registers → `rd, rs1` |

`need(n)` enforces the operand count (so `rdtid a0, a1` or `setdt a0` are clean
errors), and register names accept both `xN` and ABI names.

### 4.3 ISA — `isa.py` (encode ↔ decode, the single source of truth)

- The opcode constant `OPC_CUSTOM0 = 0b0001011`.
- Three `InstrDef` entries with the new `fmt`s; `encode()` builds each word with
  `encode_R` (the R-type field packer), placing 0 in the unused fields.
- `decode()` has an `if opcode == OPC_CUSTOM0:` branch that switches on `funct3`
  and returns a `Decoded` record; an unknown `funct3` raises "illegal instruction".
- `disassemble()` prints `rdtid rd` / `setdt rs1, rs2` / `getdt rd, rs1` for the
  `.lst` listing and `--trace`.

Because `encode` and `decode` are both driven off the same table, they can't drift.

### 4.4 Simulator — `simulator.py` (execute, the reference model)

- The `CPU` gains `tid` and a shared `data` list (a flat array of 8-bit cells,
  `data_width * data_height`, default 32×32).
- Execution cases sit next to `mul`: `rdtid` → `setrd(cpu.tid)`; `getdt` →
  `setrd(data[idx])` (or 0 + a warning if out of range); `setdt` →
  `data[idx] = value & 0xFF` (or a warning if out of range). `setrd` gives the
  `x0` rule for free.
- `run_threads(...)` runs the program once per `tid = 0..N-1`, each thread with its
  own registers/memory but **one shared `data` list** — that sharing is the whole
  point. `--data-image` / `--data-text` render the result.

### 4.5 Hardware — `cpu.sv` + `datamem.sv` (what you build / is provided)

- `cpu.sv` adds `` `define OPCODE_CUSTOM 7'b0001011 ``, a `tid` input port, and the
  data-memory ports (`dt_we`/`dt_addr`/`dt_wdata` to write, `dt_raddr`/`dt_rdata`
  to read). Decode is one `case(funct3)` arm in the writeback (rdtid→`tid`,
  getdt→`{24'b0, dt_rdata}`, guarded by `if (rd != 0)`), plus a one-clock `dt_we`
  pulse for `setdt`.
- `datamem.sv` (provided) is the shared array: one write port and one combinational
  read port **per thread**, plus a scan port for a display. It is register-backed so
  all threads can read/write in the same cycle.
- `io_top.sv` (provided) instantiates the CPU once per thread in a `genvar` loop,
  wiring each copy's `tid` to its instance number and all copies to the one
  `datamem`. That per-instance `tid` wire is what makes identical CPUs do different
  work.

---

## 5. One instruction, end to end

```
C:        setdata(tid, 42);
compiler: rdtid t0            # t0 = tid
          push t0
          li   t0, 42
          push t0
          pop  t1             # value = 42
          pop  t0             # index = tid
          setdt t0, t1        # data[tid] = 42
assembler/isa:  setdt t0(x5), t1(x6)  ->  0x006282??   (funct3=001, rs1=x5, rs2=x6)
simulator:      cpu.data[ regs[x5] ] = regs[x6] & 0xFF
hardware:       dt_we=1, dt_addr=registers[x5], dt_wdata=registers[x6][7:0]
                -> datamem writes that cell on the next clock edge
```

Same word, same effect, in the simulator and on the board — which is exactly how
you test your CPU: match the simulator.
