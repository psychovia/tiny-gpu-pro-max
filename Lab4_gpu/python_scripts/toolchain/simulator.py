"""
simulator.py -- A teaching simulator for our RV32I + M(mul) subset.

USAGE
    python simulator.py program.mem
    python simulator.py program.mem --trace
    python simulator.py program.mem --mem-size 65536 --max-cycles 1000000
    python simulator.py program.mem --dump a0,a1,sp
    python simulator.py program.mem --strict        # first warning -> error

INPUTS
    A .mem file produced by assembler.py: one 32-bit binary string per line.
    The same file feeds SystemVerilog's $readmemb -- the simulator and the SV
    testbench see identical bytes.

WHAT THIS FILE IS
    A plain Python interpreter. Each cycle:
      1. fetch the 32-bit word at PC,
      2. decode it (isa.decode),
      3. execute the matching branch in step() below,
      4. advance PC (unless the instruction set it itself).

    The execute step is one big switch on the decoded mnemonic. Every branch
    is short and self-contained -- if you wonder what an instruction *does*,
    read its branch; this is the authoritative behavioural model.

INPUT / OUTPUT
    All I/O goes through `ecall`, dispatched on the service number in a7 (x17),
    the standard RISC-V convention:
        a7 == 1  -> getchar: read one byte from cpu.input into a0 (EOF -> -1)
        otherwise -> putchar: emit the low byte of a0 as one character to
                     cpu.output
    cpu.output defaults to stdout and cpu.input to stdin; tests pass io.StringIO
    for both. The hardware primitive only ever moves a single byte -- the C
    compiler builds formatted integer printing (print) and decimal parsing
    (scanf) on top of these one-byte services. `ebreak` halts the machine.
"""

import argparse
import io
import sys

from isa import (
    MASK_32, decode, disassemble, from_bin_line, reg_name, reg_num,
    _sign_extend,
)


# --------------------------------------------------------------------
# Runtime conditions
# --------------------------------------------------------------------

class SimError(RuntimeError):
    """A fatal runtime condition; halts simulation with a friendly message."""


class StrictWarning(SimError):
    """A warning promoted to an error because --strict is set."""


# --------------------------------------------------------------------
# int32 conversions. Registers are stored unsigned in [0, 2**32); sign only
# matters at the point of use (display, signed compares, arithmetic shifts).
# --------------------------------------------------------------------

def to_u32(x):
    return x & MASK_32


def to_s32(x):
    x &= MASK_32
    return x - (1 << 32) if x & (1 << 31) else x


# --------------------------------------------------------------------
# CPU state
# --------------------------------------------------------------------

DEFAULT_DUMP = ["a0", "a1", "ra", "sp", "s0", "t0", "t1"]

# GPU variant: the shared DATA memory that all threads read/write with the
# getdt/setdt instructions (C: getdata/setdata). It is a small 2D grid of
# 8-bit cells (matching the SystemVerilog data memory); the grid can also be
# VIEWED as an image. The default 32x32 grid is one row per thread when 32
# threads run.
DATA_WIDTH_DEFAULT = 32
DATA_HEIGHT_DEFAULT = 32
DATA_MASK = 0xFF


class CPU:
    def __init__(self, mem_size=1 << 16, output=None, input=None,
                 strict=False, no_warnings=False, warn_stream=False,
                 progress_check=True, progress_limit=10000,
                 stack_depth_warn=8192,
                 tid=0, data=None,
                 data_width=DATA_WIDTH_DEFAULT, data_height=DATA_HEIGHT_DEFAULT):
        # mem_size must be a multiple of 16 so the initial sp is 16-aligned-ish
        # and word accesses near the top stay aligned; round up if needed.
        mem_size = (mem_size + 15) & ~15
        self.mem_size = mem_size

        # 32 general-purpose registers, x0..x31, stored unsigned. x0 is wired
        # to 0 by write_reg(). sp is x2; it starts at the top of memory.
        self.regs = [0] * 32
        self.regs[2] = mem_size
        self.pc = 0
        self.mem = bytearray(mem_size)
        self.halted = False
        self.cycles = 0
        self.output = output if output is not None else sys.stdout
        # Input channel for the getchar service (ecall with a7 == 1). Tests pass
        # an io.StringIO; interactively this is the terminal's stdin.
        self.input = input if input is not None else sys.stdin

        # ---- GPU variant: thread id + shared data memory ----
        # tid is what the rdtid instruction returns (each hardware thread gets
        # a different one). `data` is the shared data memory; passing ONE list
        # to every thread (the `is not None` sentinel avoids the empty-list
        # falsy trap) is what makes it shared under --threads.
        self.tid = tid
        self.data_width = data_width
        self.data_height = data_height
        self.data = (data if data is not None
                     else [0] * (data_width * data_height))

        # ---- warning machinery ----
        self.strict = strict
        self.no_warnings = no_warnings
        self.warn_stream = warn_stream
        self.progress_check = progress_check
        self.progress_limit = progress_limit
        self.stack_depth_warn = stack_depth_warn
        self.warnings = []                 # list of (pc, msg)

        self.initial_sp = mem_size
        self.code_end_addr = 0             # high-water mark set by the loader
        self.initialised = bytearray(mem_size)   # 0/1 flag per byte
        self.call_depth = 0

        # transient per-cycle / one-shot bookkeeping
        self._wrote = False
        self._no_progress = 0
        self._no_progress_warned = False
        self._deep_stack_warned = False
        self._uninit_warned = set()

    # ---------------- warnings ----------------

    def warn(self, msg):
        if self.no_warnings:
            return
        if self.strict:
            raise StrictWarning("at PC=0x%08X: %s" % (self.pc, msg))
        self.warnings.append((self.pc, msg))
        if self.warn_stream:
            sys.stderr.write("warning [PC=0x%08X]: %s\n" % (self.pc, msg))

    # ---------------- register write (enforces x0=0 + sp checks) ----------

    def write_reg(self, i, v):
        if i == 0:
            return                          # x0 is hardwired to 0
        self.regs[i] = v & MASK_32
        self._wrote = True
        if i == 2:                          # sp was just written
            sp = self.regs[2]
            if sp & 3:
                self.warn("sp=0x%08X is not 4-byte aligned (set by this instruction)" % sp)
            elif sp > self.initial_sp:
                self.warn("stack underflow -- sp=0x%08X is above its initial value "
                          "(0x%08X)" % (sp, self.initial_sp))
            elif sp < self.code_end_addr:
                self.warn("stack pointer 0x%08X has descended into the code section "
                          "(program code ends at 0x%08X)" % (sp, self.code_end_addr))
            elif (self.stack_depth_warn and not self._deep_stack_warned
                  and (self.initial_sp - sp) > self.stack_depth_warn):
                self._deep_stack_warned = True
                self.warn("stack has grown to %d bytes from initial sp (threshold = %d)"
                          % (self.initial_sp - sp, self.stack_depth_warn))

    # ---------------- memory access (friendly errors + warnings) ----------

    def _check_addr(self, addr, width, action):
        if addr < 0 or addr + width > self.mem_size:
            raise SimError("at PC=0x%08X: %s address 0x%08X out of range "
                           "(memory is %d bytes)" % (self.pc, action, addr, self.mem_size))

    def _warn_uninit(self, addr, width):
        if self.no_warnings:
            return
        for a in range(addr, addr + width):
            if not self.initialised[a]:
                if a not in self._uninit_warned:
                    self._uninit_warned.add(a)
                    self.warn("load at 0x%08X reads uninitialised memory (returning 0x00)"
                              % addr)
                break

    def _mark_init(self, addr, width):
        for a in range(addr, addr + width):
            self.initialised[a] = 1

    def load_u32(self, addr):
        if addr & 3:
            raise SimError("at PC=0x%08X: misaligned word access at 0x%08X "
                           "(must be 4-byte aligned)" % (self.pc, addr))
        self._check_addr(addr, 4, "load")
        self._warn_uninit(addr, 4)
        return int.from_bytes(self.mem[addr:addr + 4], "little")

    def load_u16(self, addr):
        if addr & 1:
            raise SimError("at PC=0x%08X: misaligned halfword access at 0x%08X"
                           % (self.pc, addr))
        self._check_addr(addr, 2, "load")
        self._warn_uninit(addr, 2)
        return int.from_bytes(self.mem[addr:addr + 2], "little")

    def load_u8(self, addr):
        self._check_addr(addr, 1, "load")
        self._warn_uninit(addr, 1)
        return self.mem[addr]

    def store_u32(self, addr, value):
        if addr & 3:
            raise SimError("at PC=0x%08X: misaligned word access at 0x%08X "
                           "(must be 4-byte aligned)" % (self.pc, addr))
        self._check_addr(addr, 4, "store")
        self.mem[addr:addr + 4] = (value & MASK_32).to_bytes(4, "little")
        self._mark_init(addr, 4)
        self._wrote = True

    def store_u16(self, addr, value):
        if addr & 1:
            raise SimError("at PC=0x%08X: misaligned halfword access at 0x%08X"
                           % (self.pc, addr))
        self._check_addr(addr, 2, "store")
        self.mem[addr:addr + 2] = (value & 0xFFFF).to_bytes(2, "little")
        self._mark_init(addr, 2)
        self._wrote = True

    def store_u8(self, addr, value):
        self._check_addr(addr, 1, "store")
        self.mem[addr] = value & 0xFF
        self._mark_init(addr, 1)
        self._wrote = True


# --------------------------------------------------------------------
# Loader: read a .mem file into memory starting at address 0
# --------------------------------------------------------------------

def load_mem_file(cpu, path):
    """Read 32-bit binary lines from `path` into cpu.mem at 0, 4, 8, ...
    Returns the number of bytes loaded (the code-section high-water mark)."""
    addr = 0
    with open(path) as f:
        for lineno, raw in enumerate(f, start=1):
            line = raw.strip()
            if not line or line.startswith("#") or line.startswith("//"):
                continue
            try:
                word = from_bin_line(line)
            except ValueError as e:
                raise SimError("%s:%d: %s" % (path, lineno, e))
            if addr + 4 > cpu.mem_size:
                raise SimError("program does not fit in %d-byte memory" % cpu.mem_size)
            cpu.mem[addr:addr + 4] = word.to_bytes(4, "little")
            addr += 4
    cpu.code_end_addr = addr
    cpu.initialised[0:addr] = b"\x01" * addr
    return addr


# --------------------------------------------------------------------
# The execution switch -- ONE step of the CPU
# --------------------------------------------------------------------

def step(cpu):
    if cpu.halted:
        return
    cpu._wrote = False

    # ---- FETCH (with PC sanity) ----
    if cpu.pc & 3:
        raise SimError("at PC=0x%08X: PC misaligned; instructions must be "
                       "4-byte aligned" % cpu.pc)
    if cpu.pc < 0 or cpu.pc + 4 > cpu.mem_size:
        raise SimError("at PC=0x%08X: PC out of range (memory is %d bytes); "
                       "did your program forget to halt with ebreak?"
                       % (cpu.pc, cpu.mem_size))
    word = int.from_bytes(cpu.mem[cpu.pc:cpu.pc + 4], "little")
    try:
        ins = decode(word)
    except ValueError as e:
        raise SimError("at PC=0x%08X: %s" % (cpu.pc, e))

    mn = ins.mnemonic
    rs1_v = cpu.regs[ins.rs1]
    rs2_v = cpu.regs[ins.rs2]
    imm = ins.imm
    next_pc = cpu.pc + 4
    taken_target = None

    def setrd(value):
        # ALU / load destination write, with the "wrote nonzero to x0" lint.
        # (jal/jalr use write_reg directly -- x0 there is the no-link idiom.)
        if ins.rd == 0:
            if value & MASK_32:
                cpu.warn("write to x0 ignored (x0 is hardwired to 0); computed "
                         "value was 0x%08X" % (value & MASK_32))
            return
        cpu.write_reg(ins.rd, value)

    # ---- R-type ----
    if mn == "add":    setrd(rs1_v + rs2_v)
    elif mn == "sub":  setrd(rs1_v - rs2_v)
    elif mn == "sll":  setrd(rs1_v << (rs2_v & 31))
    elif mn == "srl":  setrd((rs1_v & MASK_32) >> (rs2_v & 31))
    elif mn == "sra":  setrd(to_s32(rs1_v) >> (rs2_v & 31))
    elif mn == "xor":  setrd(rs1_v ^ rs2_v)
    elif mn == "or":   setrd(rs1_v | rs2_v)
    elif mn == "and":  setrd(rs1_v & rs2_v)
    elif mn == "slt":  setrd(1 if to_s32(rs1_v) < to_s32(rs2_v) else 0)
    elif mn == "sltu": setrd(1 if (rs1_v & MASK_32) < (rs2_v & MASK_32) else 0)
    elif mn == "mul":  setrd(rs1_v * rs2_v)

    # ---- custom-0: GPU thread id + shared data memory ----
    elif mn == "rdtid":
        setrd(cpu.tid)                          # rd <- this thread's id
    elif mn == "getdt":
        idx = rs1_v & MASK_32                   # rd <- data[rs1]
        if idx < len(cpu.data):
            setrd(cpu.data[idx] & DATA_MASK)
        else:
            cpu.warn("getdt index %d is outside the shared data memory "
                     "(%d cells); reading 0" % (idx, len(cpu.data)))
            setrd(0)
    elif mn == "setdt":
        idx = rs1_v & MASK_32                   # data[rs1] <- rs2
        if idx < len(cpu.data):
            cpu.data[idx] = rs2_v & DATA_MASK
            cpu._wrote = True                   # counts as progress, like a store
        else:
            cpu.warn("setdt index %d is outside the shared data memory "
                     "(%d cells); write ignored" % (idx, len(cpu.data)))

    # ---- I-type arithmetic / logic immediate ----
    elif mn == "addi":  setrd(rs1_v + imm)
    elif mn == "xori":  setrd(rs1_v ^ (imm & MASK_32))
    elif mn == "ori":   setrd(rs1_v | (imm & MASK_32))
    elif mn == "andi":  setrd(rs1_v & (imm & MASK_32))
    elif mn == "slti":  setrd(1 if to_s32(rs1_v) < imm else 0)
    elif mn == "sltiu": setrd(1 if (rs1_v & MASK_32) < (imm & MASK_32) else 0)

    # ---- shift-immediate (imm is the shift amount) ----
    elif mn == "slli": setrd(rs1_v << imm)
    elif mn == "srli": setrd((rs1_v & MASK_32) >> imm)
    elif mn == "srai": setrd(to_s32(rs1_v) >> imm)

    # ---- loads ----
    elif mn == "lw":  setrd(cpu.load_u32(to_u32(rs1_v + imm)))
    elif mn == "lh":  setrd(_sign_extend(cpu.load_u16(to_u32(rs1_v + imm)), 16))
    elif mn == "lhu": setrd(cpu.load_u16(to_u32(rs1_v + imm)))
    elif mn == "lb":  setrd(_sign_extend(cpu.load_u8(to_u32(rs1_v + imm)), 8))
    elif mn == "lbu": setrd(cpu.load_u8(to_u32(rs1_v + imm)))

    # ---- stores (rs2 is the value stored) ----
    elif mn == "sw": cpu.store_u32(to_u32(rs1_v + imm), rs2_v)
    elif mn == "sh": cpu.store_u16(to_u32(rs1_v + imm), rs2_v)
    elif mn == "sb": cpu.store_u8(to_u32(rs1_v + imm), rs2_v)

    # ---- upper immediate ----
    elif mn == "lui":   setrd((imm & 0xFFFFF) << 12)
    elif mn == "auipc": setrd(to_u32(cpu.pc + ((imm & 0xFFFFF) << 12)))

    # ---- jumps ----
    elif mn == "jal":
        cpu.write_reg(ins.rd, to_u32(cpu.pc + 4))
        if ins.rd == 1:                     # jal ra, ... -> a call
            cpu.call_depth += 1
        next_pc = to_u32(cpu.pc + imm)
        taken_target = next_pc
    elif mn == "jalr":
        is_ret = (ins.rd == 0 and ins.rs1 == 1 and imm == 0)
        if is_ret and cpu.regs[1] == 0:
            cpu.warn("ret with ra=0x00000000; did you forget to save/restore ra, "
                     "or never call any function?")
        target = to_u32(rs1_v + imm) & 0xFFFFFFFE
        cpu.write_reg(ins.rd, to_u32(cpu.pc + 4))
        if is_ret and cpu.call_depth > 0:
            cpu.call_depth -= 1
        next_pc = target
        taken_target = next_pc

    # ---- branches ----
    elif mn == "beq":
        if rs1_v == rs2_v: next_pc = to_u32(cpu.pc + imm); taken_target = next_pc
    elif mn == "bne":
        if rs1_v != rs2_v: next_pc = to_u32(cpu.pc + imm); taken_target = next_pc
    elif mn == "blt":
        if to_s32(rs1_v) < to_s32(rs2_v): next_pc = to_u32(cpu.pc + imm); taken_target = next_pc
    elif mn == "bge":
        if to_s32(rs1_v) >= to_s32(rs2_v): next_pc = to_u32(cpu.pc + imm); taken_target = next_pc
    elif mn == "bltu":
        if (rs1_v & MASK_32) < (rs2_v & MASK_32): next_pc = to_u32(cpu.pc + imm); taken_target = next_pc
    elif mn == "bgeu":
        if (rs1_v & MASK_32) >= (rs2_v & MASK_32): next_pc = to_u32(cpu.pc + imm); taken_target = next_pc

    # ---- system ----
    elif mn == "ecall":
        # System services, selected by the service number in a7 (x17), the
        # standard RISC-V convention:
        #   a7 == 1  -> getchar: read one byte from input into a0 (EOF -> -1)
        #   otherwise -> putchar: emit the low byte of a0 as one character
        if cpu.regs[17] == 1:
            ch = cpu.input.read(1)
            if not ch:                       # "" or b"" -> end of input
                cpu.write_reg(10, MASK_32)   # -1, like C's getchar()
            else:
                c = ch[0]                    # str -> 1-char str; bytes -> int
                cpu.write_reg(10, (c if isinstance(c, int) else ord(c)) & 0xFF)
        else:
            cpu.output.write(chr(cpu.regs[10] & 0xFF))
            cpu._wrote = True
    elif mn == "ebreak":
        cpu.halted = True
        next_pc = cpu.pc          # leave PC at the ebreak (report halt there)
        if cpu.call_depth > 0:
            cpu.warn("program ended (ebreak) but inside a function call (depth=%d)"
                     % cpu.call_depth)

    else:
        raise SimError("at PC=0x%08X: instruction %r has no simulator "
                       "implementation (bug in simulator.py)" % (cpu.pc, mn))

    # control-transfer target sanity (warn, don't halt)
    if taken_target is not None and not cpu.halted:
        if (taken_target & 3) or taken_target >= cpu.code_end_addr:
            cpu.warn("branch/jump target 0x%08X has no instruction there "
                     "(loaded program is [0x0, 0x%08X))"
                     % (taken_target, cpu.code_end_addr))

    cpu.pc = next_pc
    cpu.cycles += 1

    # infinite-loop heuristic: no architectural write for N consecutive cycles
    if cpu._wrote:
        cpu._no_progress = 0
    else:
        cpu._no_progress += 1
        if (cpu.progress_check and not cpu._no_progress_warned
                and cpu._no_progress >= cpu.progress_limit):
            cpu._no_progress_warned = True
            cpu.warn("no register or memory write for %d cycles "
                     "(probable infinite loop)" % cpu.progress_limit)


# --------------------------------------------------------------------
# Whole-program runner
# --------------------------------------------------------------------

def run(cpu, max_cycles=None, trace=False):
    while not cpu.halted:
        if max_cycles is not None and cpu.cycles >= max_cycles:
            raise SimError("reached --max-cycles %d without ebreak (infinite loop?)"
                           % max_cycles)
        if trace:
            try:
                w = int.from_bytes(cpu.mem[cpu.pc:cpu.pc + 4], "little")
                dis = disassemble(w)
            except Exception:
                dis = "<bad fetch>"
            sys.stderr.write("[cyc=%04d  PC=0x%08X] %s\n" % (cpu.cycles, cpu.pc, dis))
        step(cpu)


# --------------------------------------------------------------------
# GPU variant: run the same program on many threads (SIMT)
# --------------------------------------------------------------------

def run_threads(mem_path, n_threads=32, mem_size=1 << 16, max_cycles=None,
                data_width=DATA_WIDTH_DEFAULT, data_height=DATA_HEIGHT_DEFAULT,
                trace=False, strict=False, no_warnings=False, warn_stream=False,
                progress_check=True, stack_depth_warn=8192,
                output=None, input=None):
    """Run the same .mem once per thread tid=0..n_threads-1. Each thread has
    PRIVATE registers + PRIVATE memory (reloaded from the .mem), but all threads
    share ONE data memory -- the whole point of the GPU variant. Returns
    (tid0_cpu, shared_data)."""
    shared = [0] * (data_width * data_height)
    cpu0 = None
    for tid in range(n_threads):
        # Only thread 0 talks to the real console; the other 31 identical
        # kernels send print/getchar to throwaway buffers so they don't spam
        # stdout (real GPUs don't have 32 terminals either).
        t_out = (output if output is not None else sys.stdout) if tid == 0 else io.StringIO()
        t_in = (input if input is not None else sys.stdin) if tid == 0 else io.StringIO("")
        cpu = CPU(mem_size=mem_size, tid=tid, data=shared,
                  data_width=data_width, data_height=data_height,
                  output=t_out, input=t_in, strict=strict, no_warnings=no_warnings,
                  warn_stream=warn_stream, progress_check=progress_check,
                  stack_depth_warn=stack_depth_warn)
        load_mem_file(cpu, mem_path)
        run(cpu, max_cycles=max_cycles, trace=trace)
        if tid == 0:
            cpu0 = cpu
    return cpu0, shared


def dump_ppm(data, width, height, path):
    """Write the shared data grid as a grayscale image (binary-safe P3 PPM).
    Each 8-bit cell value v becomes the gray pixel (v, v, v)."""
    with open(path, "w") as f:
        f.write("P3\n%d %d\n255\n" % (width, height))
        for y in range(height):
            row = []
            for x in range(width):
                v = data[y * width + x] & 0xFF
                row.append("%d %d %d" % (v, v, v))
            f.write(" ".join(row) + "\n")


def dump_text_grid(data, width, height):
    """Return an ASCII picture of the data grid ('.' = 0, '#' = nonzero)."""
    rows = []
    for y in range(height):
        rows.append("".join("#" if data[y * width + x] else "."
                            for x in range(width)))
    return "\n".join(rows)


# --------------------------------------------------------------------
# Pretty state dump
# --------------------------------------------------------------------

def format_state(cpu, regs_to_show=None, show_all=False):
    lines = ["halted=%s  cycles=%d  PC=0x%08X  sp=0x%08X"
             % (cpu.halted, cpu.cycles, cpu.pc, cpu.regs[2])]
    if show_all:
        names = [reg_name(i) for i in range(32)]
    elif regs_to_show:
        names = regs_to_show
    else:
        names = DEFAULT_DUMP
    for name in names:
        i = reg_num(name)
        u = cpu.regs[i]
        s = to_s32(u)
        lines.append("  %-4s = 0x%08X  (%11d u32, %11d s32)" % (reg_name(i), u, u, s))
    return "\n".join(lines)


def format_summary(cpu):
    out = ["=== program halted at PC=0x%08X (cycles=%d) ===" % (cpu.pc, cpu.cycles)]
    if cpu.warnings:
        out.append("warnings (%d):" % len(cpu.warnings))
        for pc, msg in cpu.warnings:
            out.append("  - [PC=0x%08X] %s" % (pc, msg))
    return "\n".join(out)


# --------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Run a .mem program on the RV32I+M teaching simulator")
    ap.add_argument("mem", help=".mem file produced by assembler.py")
    ap.add_argument("--mem-size", type=int, default=1 << 16,
                    help="total memory size in bytes (default 65536)")
    ap.add_argument("--max-cycles", type=int, default=10_000_000,
                    help="cycle budget before giving up (default 10M)")
    ap.add_argument("--trace", action="store_true",
                    help="print every instruction as it executes (to stderr)")
    ap.add_argument("--dump", default=None,
                    help="comma-separated registers to print at halt "
                         "(ABI or xN names; default: a useful subset)")
    ap.add_argument("--dump-all", action="store_true",
                    help="dump all 32 registers at halt")
    ap.add_argument("--strict", action="store_true",
                    help="promote the first warning to an error")
    ap.add_argument("--no-warnings", action="store_true",
                    help="suppress all warnings (errors still fire)")
    ap.add_argument("--warn-stream", action="store_true",
                    help="stream warnings to stderr as they fire (else batched at end)")
    ap.add_argument("--no-progress-check", action="store_true",
                    help="disable the infinite-loop (no-progress) heuristic")
    ap.add_argument("--stack-depth-warn", type=int, default=8192,
                    help="warn once when the stack grows past this many bytes")
    # ---- GPU variant ----
    ap.add_argument("--tid", type=int, default=0,
                    help="GPU: value the rdtid instruction returns (single-thread run)")
    ap.add_argument("--threads", type=int, default=1,
                    help="GPU: run the program once per thread tid=0..N-1, "
                         "sharing one data memory (typical: 32)")
    ap.add_argument("--data-image", default=None,
                    help="GPU: write the shared data memory as a grayscale PPM image")
    ap.add_argument("--data-text", action="store_true",
                    help="GPU: print the shared data memory as an ASCII grid")
    ap.add_argument("--data-width", type=int, default=DATA_WIDTH_DEFAULT,
                    help="GPU: data-grid width (default %d)" % DATA_WIDTH_DEFAULT)
    ap.add_argument("--data-height", type=int, default=DATA_HEIGHT_DEFAULT,
                    help="GPU: data-grid height (default %d)" % DATA_HEIGHT_DEFAULT)
    args = ap.parse_args(argv)

    regs = None
    if args.dump:
        regs = [r.strip() for r in args.dump.split(",")]

    if args.threads > 1:
        cpu = None
        try:
            cpu, shared = run_threads(
                args.mem, n_threads=args.threads, mem_size=args.mem_size,
                max_cycles=args.max_cycles, data_width=args.data_width,
                data_height=args.data_height, trace=args.trace, strict=args.strict,
                no_warnings=args.no_warnings, warn_stream=args.warn_stream,
                progress_check=not args.no_progress_check,
                stack_depth_warn=args.stack_depth_warn)
        except FileNotFoundError as e:
            sys.stderr.write("error: %s\n" % e); sys.exit(1)
        except SimError as e:
            sys.stderr.write("runtime error: %s\n" % e); sys.exit(2)
        if args.data_image:
            dump_ppm(shared, args.data_width, args.data_height, args.data_image)
            print("wrote %s (%dx%d)" % (args.data_image, args.data_width, args.data_height))
        if args.data_text:
            print(dump_text_grid(shared, args.data_width, args.data_height))
        print(format_summary(cpu))
        print(format_state(cpu, regs, show_all=args.dump_all))
        sys.exit(0)

    cpu = CPU(mem_size=args.mem_size, strict=args.strict,
              no_warnings=args.no_warnings, warn_stream=args.warn_stream,
              progress_check=not args.no_progress_check,
              stack_depth_warn=args.stack_depth_warn,
              tid=args.tid, data_width=args.data_width, data_height=args.data_height)

    try:
        load_mem_file(cpu, args.mem)
        run(cpu, max_cycles=args.max_cycles, trace=args.trace)
    except FileNotFoundError as e:
        sys.stderr.write("error: %s\n" % e)
        sys.exit(1)
    except StrictWarning as e:
        sys.stderr.write("error (--strict): %s\n" % e)
        sys.stderr.write(format_state(cpu, regs, show_all=args.dump_all) + "\n")
        sys.exit(3)
    except SimError as e:
        sys.stderr.write("runtime error: %s\n" % e)
        sys.stderr.write(format_state(cpu, regs, show_all=args.dump_all) + "\n")
        sys.exit(2)

    if args.data_image:
        dump_ppm(cpu.data, args.data_width, args.data_height, args.data_image)
        print("wrote %s (%dx%d)" % (args.data_image, args.data_width, args.data_height))
    if args.data_text:
        print(dump_text_grid(cpu.data, args.data_width, args.data_height))
    print(format_summary(cpu))
    print(format_state(cpu, regs, show_all=args.dump_all))
    sys.exit(0)


if __name__ == "__main__":
    main()
