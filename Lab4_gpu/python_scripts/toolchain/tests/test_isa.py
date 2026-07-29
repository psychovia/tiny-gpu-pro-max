"""Tests for isa.py (RV32I + M MUL).

Two kinds of checks:
  1. Golden machine words -- exact 32-bit encodings cross-checked against an
     authoritative RISC-V reference. These catch a *shared* mistake that a
     round-trip alone would miss (encode and decode agreeing on a wrong bit
     layout). The scrambled B/J immediates especially live or die here.
  2. Encode -> decode round-trips across every format, including signed and
     negative immediates.
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import isa
from isa import reg_num, encode, decode, to_bin_line, from_bin_line


class TestRegisters(unittest.TestCase):
    def test_abi_and_x_names(self):
        self.assertEqual(reg_num("zero"), 0)
        self.assertEqual(reg_num("x0"), 0)
        self.assertEqual(reg_num("ra"), 1)
        self.assertEqual(reg_num("sp"), 2)
        self.assertEqual(reg_num("a0"), 10)
        self.assertEqual(reg_num("a7"), 17)
        self.assertEqual(reg_num("s0"), 8)
        self.assertEqual(reg_num("fp"), 8)       # alias for s0
        self.assertEqual(reg_num("t6"), 31)
        self.assertEqual(reg_num("x31"), 31)

    def test_case_insensitive(self):
        self.assertEqual(reg_num("A0"), 10)
        self.assertEqual(reg_num("SP"), 2)

    def test_reg_name_returns_abi(self):
        self.assertEqual(isa.reg_name(10), "a0")
        self.assertEqual(isa.reg_name(8), "s0")
        self.assertEqual(isa.reg_name(0), "zero")

    def test_bad_register(self):
        self.assertRaises(ValueError, reg_num, "x32")
        self.assertRaises(ValueError, reg_num, "t9")
        self.assertRaises(ValueError, reg_num, "banana")


class TestGoldenWords(unittest.TestCase):
    """Exact words verified against the RISC-V spec / migration plan."""

    def test_addi_x1_x0_0(self):
        # addi x1, x0, 0  ==  0x00000093  (plan section 3.8 listing example)
        w = encode("addi", rd=reg_num("ra"), rs1=reg_num("zero"), imm=0)
        self.assertEqual(w, 0x00000093)

    def test_addi_sp_sp_neg16(self):
        # addi sp, sp, -16  ==  0xff010113  (plan section 3.8 listing example)
        w = encode("addi", rd=reg_num("sp"), rs1=reg_num("sp"), imm=-16)
        self.assertEqual(w, 0xFF010113)

    def test_ecall_ebreak(self):
        self.assertEqual(encode("ecall"), 0x00000073)
        self.assertEqual(encode("ebreak"), 0x00100073)

    def test_beq_x0_x0_16(self):
        # beq x0, x0, 16  ==  0x00000863
        w = encode("beq", rs1=0, rs2=0, imm=16)
        self.assertEqual(w, 0x00000863)

    def test_jal_x0_256(self):
        # jal x0, 256  ==  0x1000006f
        w = encode("jal", rd=0, imm=256)
        self.assertEqual(w, 0x1000006F)

    def test_lui_a0(self):
        # lui a0, 0xDEADC  ->  bits[31:12]=0xDEADC, rd=a0(10), opcode 0x37
        w = encode("lui", rd=reg_num("a0"), imm=0xDEADC)
        self.assertEqual(w, (0xDEADC << 12) | (10 << 7) | 0x37)

    def test_sw_a0_8_sp(self):
        # sw a0, 8(sp): rs2=a0(10), rs1=sp(2), imm=8, funct3=010, opcode 0x23
        w = encode("sw", rs1=reg_num("sp"), rs2=reg_num("a0"), imm=8)
        expected = (10 << 20) | (2 << 15) | (0b010 << 12) | (8 << 7) | 0x23
        self.assertEqual(w, expected)


class TestRoundTrip(unittest.TestCase):
    def _rt(self, mnemonic, **fields):
        w = encode(mnemonic, **fields)
        d = decode(w)
        self.assertEqual(d.mnemonic, mnemonic)
        return d

    def test_r_type(self):
        for mn in ("add", "sub", "sll", "slt", "sltu", "xor",
                   "srl", "sra", "or", "and", "mul"):
            d = self._rt(mn, rd=5, rs1=6, rs2=7)
            self.assertEqual((d.rd, d.rs1, d.rs2), (5, 6, 7))

    def test_i_arith(self):
        for mn in ("addi", "slti", "sltiu", "xori", "ori", "andi"):
            for imm in (0, 1, -1, 2047, -2048, -273):
                d = self._rt(mn, rd=10, rs1=11, imm=imm)
                self.assertEqual(d.rd, 10)
                self.assertEqual(d.rs1, 11)
                self.assertEqual(d.imm, imm)

    def test_i_shift(self):
        for mn in ("slli", "srli", "srai"):
            for shamt in (0, 1, 31):
                d = self._rt(mn, rd=3, rs1=4, imm=shamt)
                self.assertEqual(d.imm, shamt)

    def test_shift_out_of_range(self):
        self.assertRaises(ValueError, encode, "slli", rd=1, rs1=1, imm=32)

    def test_loads(self):
        for mn in ("lb", "lh", "lw", "lbu", "lhu"):
            d = self._rt(mn, rd=10, rs1=2, imm=-4)
            self.assertEqual(d.imm, -4)

    def test_stores(self):
        for mn in ("sb", "sh", "sw"):
            d = self._rt(mn, rs1=2, rs2=10, imm=-8)
            self.assertEqual((d.rs1, d.rs2, d.imm), (2, 10, -8))

    def test_branches(self):
        for mn in ("beq", "bne", "blt", "bge", "bltu", "bgeu"):
            for imm in (0, 4, -4, 2046, -2048, 4094, -4096):
                d = self._rt(mn, rs1=1, rs2=2, imm=imm)
                self.assertEqual(d.imm, imm)

    def test_branch_must_be_even(self):
        self.assertRaises(ValueError, encode, "beq", rs1=0, rs2=0, imm=3)

    def test_branch_out_of_range(self):
        self.assertRaises(ValueError, encode, "beq", rs1=0, rs2=0, imm=8192)

    def test_u_type(self):
        for mn in ("lui", "auipc"):
            for imm in (0, 1, 0xFFFFF, 0xDEADC):
                d = self._rt(mn, rd=10, imm=imm)
                self.assertEqual(d.imm, imm)

    def test_u_out_of_range(self):
        self.assertRaises(ValueError, encode, "lui", rd=1, imm=1 << 20)

    def test_jal(self):
        for imm in (0, 4, -4, 256, -256, 1048574, -1048576):
            d = self._rt("jal", rd=1, imm=imm)
            self.assertEqual(d.imm, imm)

    def test_jalr(self):
        d = self._rt("jalr", rd=1, rs1=1, imm=0)
        self.assertEqual((d.rd, d.rs1, d.imm), (1, 1, 0))

    def test_system(self):
        self.assertEqual(decode(encode("ecall")).mnemonic, "ecall")
        self.assertEqual(decode(encode("ebreak")).mnemonic, "ebreak")


class TestDecodeErrors(unittest.TestCase):
    def test_all_zero_word(self):
        self.assertRaises(ValueError, decode, 0x00000000)

    def test_unknown_opcode(self):
        self.assertRaises(ValueError, decode, 0xFFFFFFFF)

    def test_unknown_instruction_mnemonic(self):
        self.assertRaises(ValueError, encode, "frobnicate")


class TestMemLineFormat(unittest.TestCase):
    def test_round_trip(self):
        for w in (0x00000000, 0xFFFFFFFF, 0x00000093, 0xDEADBEEF, 0x1000006F):
            line = to_bin_line(w)
            self.assertEqual(len(line), 32)
            self.assertTrue(all(c in "01" for c in line))
            self.assertEqual(from_bin_line(line), w)

    def test_underscores_and_whitespace_tolerated(self):
        self.assertEqual(from_bin_line("  00000000000000000000000010010011 \n"),
                         0x00000093)

    def test_bad_line(self):
        self.assertRaises(ValueError, from_bin_line, "1010")
        self.assertRaises(ValueError, from_bin_line, "x" * 32)


if __name__ == "__main__":
    unittest.main()
