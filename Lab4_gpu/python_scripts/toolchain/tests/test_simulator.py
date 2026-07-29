"""Per-instruction simulator tests for the RV32I + M(mul) subset.

Programs are built as lists of words via isa.encode() and loaded the same way
load_mem_file would (setting the code high-water mark + initialised flags), so
the warning machinery sees realistic state.
"""

import io
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from isa import encode, reg_num, MASK_32
from simulator import CPU, step, run, SimError

R = reg_num


def load(*words, **kw):
    mem_size = kw.get("mem_size", 1 << 12)
    cpu = CPU(mem_size=mem_size)
    for i, w in enumerate(words):
        cpu.mem[i * 4:i * 4 + 4] = (w & MASK_32).to_bytes(4, "little")
    n = len(words) * 4
    cpu.code_end_addr = n
    cpu.initialised[0:n] = b"\x01" * n
    return cpu


class TestArithmetic(unittest.TestCase):
    def test_add(self):
        cpu = load(encode("add", rd=R("a2"), rs1=R("a0"), rs2=R("a1")))
        cpu.regs[R("a0")] = 10; cpu.regs[R("a1")] = 32
        step(cpu)
        self.assertEqual(cpu.regs[R("a2")], 42)

    def test_sub_wraps(self):
        cpu = load(encode("sub", rd=R("a0"), rs1=R("a1"), rs2=R("a2")))
        cpu.regs[R("a1")] = 0; cpu.regs[R("a2")] = 1
        step(cpu)
        self.assertEqual(cpu.regs[R("a0")], 0xFFFFFFFF)   # -1 as u32

    def test_addi_negative(self):
        cpu = load(encode("addi", rd=R("a0"), rs1=R("a1"), imm=-5))
        cpu.regs[R("a1")] = 100
        step(cpu)
        self.assertEqual(cpu.regs[R("a0")], 95)

    def test_mul(self):
        cpu = load(encode("mul", rd=R("a0"), rs1=R("a1"), rs2=R("a2")))
        cpu.regs[R("a1")] = 0x10000; cpu.regs[R("a2")] = 0x10000   # overflows 32b
        step(cpu)
        self.assertEqual(cpu.regs[R("a0")], 0)   # low 32 bits of 2**32


class TestLogicalAndShifts(unittest.TestCase):
    def test_and_or_xor(self):
        for mn, exp in (("and", 0xF0F0F0F0 & 0x0FF0F00F),
                        ("or", 0xF0F0F0F0 | 0x0FF0F00F),
                        ("xor", 0xF0F0F0F0 ^ 0x0FF0F00F)):
            cpu = load(encode(mn, rd=R("a0"), rs1=R("a1"), rs2=R("a2")))
            cpu.regs[R("a1")] = 0xF0F0F0F0; cpu.regs[R("a2")] = 0x0FF0F00F
            step(cpu)
            self.assertEqual(cpu.regs[R("a0")], exp, mn)

    def test_sll_srl_sra(self):
        cpu = load(encode("sll", rd=R("a0"), rs1=R("a1"), rs2=R("a2")))
        cpu.regs[R("a1")] = 1; cpu.regs[R("a2")] = 4
        step(cpu); self.assertEqual(cpu.regs[R("a0")], 0x10)

        cpu = load(encode("srl", rd=R("a0"), rs1=R("a1"), rs2=R("a2")))
        cpu.regs[R("a1")] = 0x80000000; cpu.regs[R("a2")] = 4
        step(cpu); self.assertEqual(cpu.regs[R("a0")], 0x08000000)

        cpu = load(encode("sra", rd=R("a0"), rs1=R("a1"), rs2=R("a2")))
        cpu.regs[R("a1")] = 0x80000000; cpu.regs[R("a2")] = 4
        step(cpu); self.assertEqual(cpu.regs[R("a0")], 0xF8000000)

    def test_shift_immediate(self):
        cpu = load(encode("slli", rd=R("a0"), rs1=R("a1"), imm=4))
        cpu.regs[R("a1")] = 1
        step(cpu); self.assertEqual(cpu.regs[R("a0")], 0x10)


class TestSetLessThan(unittest.TestCase):
    def test_slt_signed(self):
        cpu = load(encode("slt", rd=R("a0"), rs1=R("a1"), rs2=R("a2")))
        cpu.regs[R("a1")] = 0xFFFFFFFF   # -1
        cpu.regs[R("a2")] = 1
        step(cpu); self.assertEqual(cpu.regs[R("a0")], 1)

    def test_sltu_unsigned(self):
        cpu = load(encode("sltu", rd=R("a0"), rs1=R("a1"), rs2=R("a2")))
        cpu.regs[R("a1")] = 0xFFFFFFFF   # huge unsigned
        cpu.regs[R("a2")] = 1
        step(cpu); self.assertEqual(cpu.regs[R("a0")], 0)

    def test_sltiu_with_neg_imm(self):
        # sltiu compares against the sign-extended imm as unsigned.
        cpu = load(encode("sltiu", rd=R("a0"), rs1=R("a1"), imm=-1))  # imm -> 0xFFFFFFFF
        cpu.regs[R("a1")] = 5
        step(cpu); self.assertEqual(cpu.regs[R("a0")], 1)   # 5 < 0xFFFFFFFF


class TestMemory(unittest.TestCase):
    def test_sw_lw_round_trip(self):
        cpu = load(encode("sw", rs1=R("sp"), rs2=R("a0"), imm=-8),
                   encode("lw", rd=R("a1"), rs1=R("sp"), imm=-8))
        cpu.regs[R("a0")] = 0xCAFEF00D
        step(cpu); step(cpu)
        self.assertEqual(cpu.regs[R("a1")], 0xCAFEF00D)

    def test_lb_sign_extends_lbu_zero(self):
        cpu = load(encode("lb", rd=R("a0"), rs1=R("a1"), imm=0),
                   encode("lbu", rd=R("a2"), rs1=R("a1"), imm=0))
        cpu.regs[R("a1")] = 0x40
        cpu.mem[0x40] = 0x80
        cpu.initialised[0x40] = 1
        step(cpu); step(cpu)
        self.assertEqual(cpu.regs[R("a0")], 0xFFFFFF80)
        self.assertEqual(cpu.regs[R("a2")], 0x80)

    def test_halfword(self):
        cpu = load(encode("sh", rs1=R("a1"), rs2=R("a0"), imm=0),
                   encode("lhu", rd=R("a2"), rs1=R("a1"), imm=0),
                   encode("lh", rd=R("a3"), rs1=R("a1"), imm=0))
        cpu.regs[R("a1")] = 0x40
        cpu.regs[R("a0")] = 0x8001
        step(cpu); step(cpu); step(cpu)
        self.assertEqual(cpu.regs[R("a2")], 0x8001)        # zero-extended
        self.assertEqual(cpu.regs[R("a3")], 0xFFFF8001)    # sign-extended

    def test_misaligned_word_is_error(self):
        cpu = load(encode("lw", rd=R("a0"), rs1=R("a1"), imm=1))
        cpu.regs[R("a1")] = 0
        with self.assertRaises(SimError) as ctx:
            step(cpu)
        self.assertIn("PC=", str(ctx.exception))

    def test_out_of_range_is_error(self):
        cpu = load(encode("sw", rs1=R("a1"), rs2=R("a0"), imm=0))
        cpu.regs[R("a1")] = 1 << 20
        self.assertRaises(SimError, step, cpu)


class TestUpperImmediate(unittest.TestCase):
    def test_lui(self):
        cpu = load(encode("lui", rd=R("a0"), imm=0xDEADC))
        step(cpu); self.assertEqual(cpu.regs[R("a0")], 0xDEADC000)

    def test_auipc(self):
        cpu = load(encode("auipc", rd=R("a0"), imm=1))   # at pc=0
        step(cpu); self.assertEqual(cpu.regs[R("a0")], 0x1000)


class TestControlFlow(unittest.TestCase):
    def test_sum_loop(self):
        # sum 1..5 into a0 with a bge-guarded loop and a `j` back-edge.
        prog = [
            encode("addi", rd=R("a0"), rs1=0, imm=0),       # 0:  a0 = 0
            encode("addi", rd=R("t0"), rs1=0, imm=1),       # 4:  t0 = 1
            encode("addi", rd=R("t1"), rs1=0, imm=6),       # 8:  t1 = 6
            encode("bge", rs1=R("t0"), rs2=R("t1"), imm=16),  # 12: if t0>=6 -> 28
            encode("add", rd=R("a0"), rs1=R("a0"), rs2=R("t0")),  # 16
            encode("addi", rd=R("t0"), rs1=R("t0"), imm=1),       # 20
            encode("jal", rd=0, imm=-12),                   # 24: j 12
            encode("ebreak"),                               # 28
        ]
        cpu = load(*prog)
        run(cpu)
        self.assertEqual(cpu.regs[R("a0")], 15)
        self.assertEqual(cpu.warnings, [])

    def test_call_and_return(self):
        prog = [
            encode("jal", rd=R("ra"), imm=8),     # 0:  call func@8; ra=4
            encode("ebreak"),                     # 4:  return here
            encode("addi", rd=R("a0"), rs1=0, imm=7),  # 8:  func: a0 = 7
            encode("jalr", rd=0, rs1=R("ra"), imm=0),  # 12: ret
        ]
        cpu = load(*prog)
        run(cpu)
        self.assertTrue(cpu.halted)
        self.assertEqual(cpu.regs[R("a0")], 7)
        self.assertEqual(cpu.pc, 4)

    def test_each_branch(self):
        # rs1=5, rs2=5 then rs1=5,rs2=7 etc, verifying taken/not-taken per op.
        def taken(mn, a, b):
            cpu = load(encode(mn, rs1=R("a0"), rs2=R("a1"), imm=8), encode("ebreak"))
            cpu.regs[R("a0")] = a & MASK_32; cpu.regs[R("a1")] = b & MASK_32
            step(cpu)
            return cpu.pc == 8
        self.assertTrue(taken("beq", 5, 5));   self.assertFalse(taken("beq", 5, 6))
        self.assertTrue(taken("bne", 5, 6));   self.assertFalse(taken("bne", 5, 5))
        self.assertTrue(taken("blt", -1, 1));  self.assertFalse(taken("blt", 1, -1))
        self.assertTrue(taken("bge", 1, -1));  self.assertFalse(taken("bge", -1, 1))
        self.assertTrue(taken("bltu", 1, 0xFFFFFFFF))
        self.assertFalse(taken("bgeu", 1, 0xFFFFFFFF))


class TestSyscallAndHalt(unittest.TestCase):
    def test_ecall_putchar(self):
        out = io.StringIO()
        prog = [
            encode("addi", rd=R("a0"), rs1=0, imm=72),   # 'H'
            encode("ecall"),
            encode("addi", rd=R("a0"), rs1=0, imm=105),  # 'i'
            encode("ecall"),
            encode("ebreak"),
        ]
        cpu = load(*prog); cpu.output = out
        run(cpu)
        self.assertEqual(out.getvalue(), "Hi")

    def test_ebreak_halts(self):
        cpu = load(encode("addi", rd=R("a0"), rs1=0, imm=1), encode("ebreak"))
        run(cpu)
        self.assertTrue(cpu.halted)
        self.assertEqual(cpu.regs[R("a0")], 1)


class TestX0Hardwired(unittest.TestCase):
    def test_write_to_x0_discarded_and_warned(self):
        cpu = load(encode("addi", rd=0, rs1=R("a1"), imm=5), encode("ebreak"))
        cpu.regs[R("a1")] = 0
        run(cpu)
        self.assertEqual(cpu.regs[0], 0)
        self.assertTrue(any("x0" in m for _, m in cpu.warnings))

    def test_nop_does_not_warn(self):
        # nop == addi x0, x0, 0 -> computed value 0 -> silent
        cpu = load(encode("addi", rd=0, rs1=0, imm=0), encode("ebreak"))
        run(cpu)
        self.assertEqual(cpu.warnings, [])


class TestWarnings(unittest.TestCase):
    def test_ret_with_ra_zero(self):
        cpu = load(encode("jalr", rd=0, rs1=R("ra"), imm=0))   # ret, ra=0
        step(cpu)
        self.assertTrue(any("ra=0x00000000" in m for _, m in cpu.warnings))

    def test_uninitialised_load(self):
        cpu = load(encode("lw", rd=R("a0"), rs1=R("a1"), imm=0), encode("ebreak"))
        cpu.regs[R("a1")] = 0x200          # never written, past the program
        run(cpu)
        self.assertTrue(any("uninitialised" in m for _, m in cpu.warnings))

    def test_strict_promotes_first_warning(self):
        cpu = load(encode("addi", rd=0, rs1=R("a1"), imm=5), encode("ebreak"))
        cpu.strict = True
        cpu.regs[R("a1")] = 0
        self.assertRaises(SimError, run, cpu)


class TestErrorPaths(unittest.TestCase):
    def test_zero_word_reports_pc_and_value(self):
        cpu = load(0)
        with self.assertRaises(SimError) as ctx:
            step(cpu)
        msg = str(ctx.exception)
        self.assertIn("PC=", msg)
        self.assertIn("0x00000000", msg)

    def test_pc_out_of_range(self):
        cpu = load(encode("ebreak"))
        cpu.pc = cpu.mem_size            # off the end
        self.assertRaises(SimError, step, cpu)

    def test_max_cycles(self):
        cpu = load(encode("jal", rd=0, imm=0))   # j . -- tight infinite loop
        self.assertRaises(SimError, run, cpu, 1000)


if __name__ == "__main__":
    unittest.main()
