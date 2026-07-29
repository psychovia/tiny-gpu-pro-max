"""Tests for the GPU variant: the custom-0 opcode (rdtid / setdt / getdt), the
tid C builtin, the setdata/getdata C builtins, and the shared-data SIMT runner.

Layered like the other suites: golden words + round-trips (isa), parse (asm),
per-instruction execution + run_threads (simulator), and C end-to-end (compiler).
"""

import io
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import compiler
import assembler
import simulator
import isa
from isa import encode, decode, reg_num, to_bin_line
from assembler import assemble, AsmError
from simulator import CPU, step, run, run_threads

R = reg_num


def load(*words):
    cpu = CPU(mem_size=1 << 12)
    for i, w in enumerate(words):
        cpu.mem[i * 4:i * 4 + 4] = (w & 0xFFFFFFFF).to_bytes(4, "little")
    n = len(words) * 4
    cpu.code_end_addr = n
    cpu.initialised[0:n] = b"\x01" * n
    return cpu


def build_cpu(src, tid=0, data_width=32, data_height=32):
    """Compile+assemble+run one thread; return the CPU so .data is observable."""
    words = assembler.assemble(compiler.compile_source(src, "<test>"))
    cpu = CPU(output=io.StringIO(), input=io.StringIO(""),
              tid=tid, data_width=data_width, data_height=data_height)
    for i, w in enumerate(words):
        cpu.mem[i * 4:i * 4 + 4] = w.to_bytes(4, "little")
    n = len(words) * 4
    cpu.code_end_addr = n
    cpu.initialised[0:n] = b"\x01" * n
    run(cpu)
    return cpu


class TestEncoding(unittest.TestCase):
    def test_golden_words(self):
        self.assertEqual(encode("rdtid", rd=R("a0")), 0x0000050B)
        self.assertEqual(encode("setdt", rs1=R("a0"), rs2=R("a1")), 0x00B5100B)
        self.assertEqual(encode("getdt", rd=R("a0"), rs1=R("a1")), 0x0005A50B)

    def test_roundtrip(self):
        d = decode(encode("rdtid", rd=7))
        self.assertEqual((d.mnemonic, d.fmt, d.rd), ("rdtid", "CUST_RD", 7))
        d = decode(encode("setdt", rs1=5, rs2=6))
        self.assertEqual((d.mnemonic, d.fmt, d.rs1, d.rs2), ("setdt", "CUST_2SRC", 5, 6))
        d = decode(encode("getdt", rd=7, rs1=5))
        self.assertEqual((d.mnemonic, d.fmt, d.rd, d.rs1), ("getdt", "CUST_RD1SRC", 7, 5))

    def test_disassemble(self):
        self.assertEqual(isa.disassemble(encode("rdtid", rd=10)), "rdtid a0")
        self.assertEqual(isa.disassemble(encode("setdt", rs1=10, rs2=11)), "setdt a0, a1")
        self.assertEqual(isa.disassemble(encode("getdt", rd=10, rs1=11)), "getdt a0, a1")

    def test_illegal_funct3(self):
        # custom-0 opcode with an undefined funct3 (011) is illegal
        self.assertRaises(ValueError, decode, 0x0000_350B)


class TestAssembler(unittest.TestCase):
    def test_parse(self):
        d = decode(assemble("rdtid a0")[0])
        self.assertEqual((d.mnemonic, d.rd), ("rdtid", R("a0")))
        d = decode(assemble("setdt a0, a1")[0])
        self.assertEqual((d.mnemonic, d.rs1, d.rs2), ("setdt", R("a0"), R("a1")))
        d = decode(assemble("getdt t0, a1")[0])
        self.assertEqual((d.mnemonic, d.rd, d.rs1), ("getdt", R("t0"), R("a1")))

    def test_arity_errors(self):
        self.assertRaises(AsmError, assemble, "rdtid a0, a1")
        self.assertRaises(AsmError, assemble, "setdt a0")
        self.assertRaises(AsmError, assemble, "getdt a0")


class TestExecution(unittest.TestCase):
    def test_rdtid(self):
        cpu = load(encode("rdtid", rd=R("a0")))
        cpu.tid = 7
        step(cpu)
        self.assertEqual(cpu.regs[R("a0")], 7)

    def test_rdtid_x0_discarded_and_warned(self):
        cpu = load(encode("rdtid", rd=0), encode("ebreak"))
        cpu.tid = 5
        run(cpu)
        self.assertEqual(cpu.regs[0], 0)
        self.assertTrue(any("x0" in m for _, m in cpu.warnings))

    def test_setdt_and_getdt(self):
        cpu = load(encode("setdt", rs1=R("a0"), rs2=R("a1")),
                   encode("getdt", rd=R("a2"), rs1=R("a0")))
        cpu.regs[R("a0")] = 3
        cpu.regs[R("a1")] = 0xAA
        step(cpu)                         # setdt data[3] = 0xAA
        self.assertEqual(cpu.data[3], 0xAA)
        step(cpu)                         # getdt a2 = data[3]
        self.assertEqual(cpu.regs[R("a2")], 0xAA)

    def test_pixel_value_masked_to_8_bits(self):
        cpu = load(encode("setdt", rs1=R("a0"), rs2=R("a1")))
        cpu.regs[R("a0")] = 0
        cpu.regs[R("a1")] = 0x1FF        # > 255
        step(cpu)
        self.assertEqual(cpu.data[0], 0xFF)

    def test_out_of_range_warns(self):
        cpu = load(encode("setdt", rs1=R("a0"), rs2=R("a1")),
                   encode("getdt", rd=R("a2"), rs1=R("a0")),
                   encode("ebreak"))
        cpu.regs[R("a0")] = 10 ** 9      # huge index (also covers "negative")
        cpu.regs[R("a1")] = 1
        run(cpu)
        msgs = " ".join(m for _, m in cpu.warnings)
        self.assertIn("setdt index", msgs)
        self.assertIn("getdt index", msgs)
        self.assertEqual(cpu.regs[R("a2")], 0)   # out-of-range getdt returns 0

    def test_run_threads_shared_data(self):
        prog = [encode("rdtid", rd=R("a0")),
                encode("setdt", rs1=R("a0"), rs2=R("a0")),
                encode("ebreak")]
        with tempfile.NamedTemporaryFile("w", suffix=".mem", delete=False) as f:
            for w in prog:
                f.write(to_bin_line(w) + "\n")
            path = f.name
        try:
            cpu0, shared = run_threads(path, n_threads=32)
            self.assertEqual(cpu0.tid, 0)
            for tid in range(32):
                self.assertEqual(shared[tid], tid)   # each thread wrote data[tid]=tid
        finally:
            os.remove(path)


class TestCompiler(unittest.TestCase):
    def test_tid_rvalue(self):
        self.assertEqual(build_cpu("int main(){ int x = tid; return x + 1; }", tid=4)
                         .regs[R("a0")], 5)

    def test_tid_default_zero(self):
        self.assertEqual(build_cpu("int main(){ return tid; }").regs[R("a0")], 0)

    def test_tid_in_index(self):
        # arr[tid] uses the builtin as an index (tid=3 -> arr[3])
        cpu = build_cpu("int arr[8]; int main(){ arr[tid] = 42; return arr[3]; }", tid=3)
        self.assertEqual(cpu.regs[R("a0")], 42)

    def test_setdata_getdata(self):
        cpu = build_cpu("int main(){ setdata(2, 100); return 0; }")
        self.assertEqual(cpu.data[2], 100)

    def test_increment_kernel(self):
        # the required kernel: read a cell, +1, write back
        cpu = build_cpu("int main(){ int i = tid; setdata(i, getdata(i) + 1); return 0; }",
                        tid=5)
        self.assertEqual(cpu.data[5], 1)

    def test_getdata_returns_value(self):
        cpu = build_cpu("int main(){ setdata(0, 77); return getdata(0); }")
        self.assertEqual(cpu.regs[R("a0")], 77)


class TestCompilerNegative(unittest.TestCase):
    def assertRejects(self, src, sub):
        with self.assertRaises(compiler.CompileError) as ctx:
            compiler.compile_source(src, "<test>")
        self.assertIn(sub, ctx.exception.msg)

    def test_setdata_arity(self):
        self.assertRejects("int main(){ setdata(1); return 0; }", "exactly 2 arguments")

    def test_getdata_arity(self):
        self.assertRejects("int main(){ return getdata(1, 2); }", "exactly 1 argument")

    def test_cant_define_setdata(self):
        self.assertRejects("int setdata(int a){ return a; } int main(){ return 0; }",
                           "reserved built-in name")

    def test_cant_define_getdata(self):
        self.assertRejects("int getdata(int a){ return a; } int main(){ return 0; }",
                           "reserved built-in name")

    def test_tid_is_keyword_cant_be_a_name(self):
        # tid is a keyword now, so declaring a variable/param called tid fails.
        with self.assertRaises(compiler.CompileError):
            compiler.compile_source("int main(){ int tid = 5; return tid; }", "<test>")


if __name__ == "__main__":
    unittest.main()
