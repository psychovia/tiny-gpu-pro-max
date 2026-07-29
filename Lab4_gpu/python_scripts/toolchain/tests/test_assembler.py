"""Assembler tests: operand parsing, pseudo-op expansion, label resolution
(byte offsets), the .mem format invariant, and a few end-to-end assemble->run
checks through the simulator."""

import os
import re
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import assembler
from assembler import assemble, AsmError
from isa import decode, from_bin_line, reg_num, MASK_32
from simulator import CPU, run

R = reg_num
BINLINE = re.compile(r"^[01]{32}$")


def run_asm(src, mem_size=1 << 12):
    words = assemble(src)
    cpu = CPU(mem_size=mem_size)
    for i, w in enumerate(words):
        cpu.mem[i * 4:i * 4 + 4] = w.to_bytes(4, "little")
    n = len(words) * 4
    cpu.code_end_addr = n
    cpu.initialised[0:n] = b"\x01" * n
    run(cpu)
    return cpu


class TestRealInstructions(unittest.TestCase):
    def test_r_type(self):
        w = assemble("add a0, a1, a2")[0]
        d = decode(w)
        self.assertEqual(d.mnemonic, "add")
        self.assertEqual((d.rd, d.rs1, d.rs2), (R("a0"), R("a1"), R("a2")))

    def test_load_store_syntax(self):
        lw = decode(assemble("lw a0, 8(sp)")[0])
        self.assertEqual(lw.mnemonic, "lw")
        self.assertEqual((lw.rd, lw.rs1, lw.imm), (R("a0"), R("sp"), 8))
        sw = decode(assemble("sw a0, -4(sp)")[0])
        self.assertEqual(sw.mnemonic, "sw")
        self.assertEqual((sw.rs2, sw.rs1, sw.imm), (R("a0"), R("sp"), -4))

    def test_shift_immediate(self):
        d = decode(assemble("slli a0, a1, 3")[0])
        self.assertEqual((d.mnemonic, d.imm), ("slli", 3))

    def test_jalr_both_syntaxes(self):
        a = decode(assemble("jalr a0, a1, 4")[0])
        b = decode(assemble("jalr a0, 4(a1)")[0])
        self.assertEqual((a.rd, a.rs1, a.imm), (R("a0"), R("a1"), 4))
        self.assertEqual((b.rd, b.rs1, b.imm), (R("a0"), R("a1"), 4))


class TestLabels(unittest.TestCase):
    def test_backward_and_forward_branch_offsets(self):
        src = (
            "start: addi a0, zero, 0\n"   # 0
            "loop:  addi a0, a0, 1\n"     # 4
            "       bne  a0, a1, loop\n"  # 8  -> back to 4  => imm -4
            "       beq  zero, zero, done\n"  # 12 -> forward to 16 => imm 4
            "done:  ebreak\n"             # 16
        )
        words = assemble(src)
        bne = decode(words[2]); beq = decode(words[3])
        self.assertEqual((bne.mnemonic, bne.imm), ("bne", -4))
        self.assertEqual((beq.mnemonic, beq.imm), ("beq", 4))

    def test_jal_label_offset(self):
        src = "jal ra, func\nebreak\nfunc: ret\n"   # jal@0, func@8 => imm 8
        d = decode(assemble(src)[0])
        self.assertEqual((d.mnemonic, d.rd, d.imm), ("jal", R("ra"), 8))

    def test_word_with_label(self):
        words = assemble(".word 42\n.word -1\ntarget: .word target\n")
        self.assertEqual(words[0], 42)
        self.assertEqual(words[1], 0xFFFFFFFF)
        self.assertEqual(words[2], 8)   # 'target' is at byte 8


class TestPseudoOps(unittest.TestCase):
    def test_nop_mv_not_neg(self):
        self.assertEqual(decode(assemble("nop")[0]).mnemonic, "addi")
        mv = decode(assemble("mv a0, a1")[0])
        self.assertEqual((mv.mnemonic, mv.rd, mv.rs1, mv.imm), ("addi", R("a0"), R("a1"), 0))
        nt = decode(assemble("not a0, a1")[0])
        self.assertEqual((nt.mnemonic, nt.imm), ("xori", -1))
        ng = decode(assemble("neg a0, a1")[0])
        self.assertEqual((ng.mnemonic, ng.rs1, ng.rs2), ("sub", 0, R("a1")))

    def test_seqz_snez(self):
        self.assertEqual(decode(assemble("seqz a0, a1")[0]).mnemonic, "sltiu")
        self.assertEqual(decode(assemble("snez a0, a1")[0]).mnemonic, "sltu")

    def test_j_ret_call(self):
        j = decode(assemble("j done\ndone: ebreak\n")[0])
        self.assertEqual((j.mnemonic, j.rd), ("jal", 0))
        ret = decode(assemble("ret")[0])
        self.assertEqual((ret.mnemonic, ret.rd, ret.rs1, ret.imm), ("jalr", 0, R("ra"), 0))
        call = decode(assemble("call f\nf: ret\n")[0])
        self.assertEqual((call.mnemonic, call.rd), ("jal", R("ra")))

    def test_beqz_bnez(self):
        beqz = decode(assemble("beqz a0, end\nend: ebreak\n")[0])
        self.assertEqual((beqz.mnemonic, beqz.rs1, beqz.rs2), ("beq", R("a0"), 0))

    def test_push_pop_two_words_each(self):
        push = assemble("push a0")
        self.assertEqual(len(push), 2)
        self.assertEqual(decode(push[0]).mnemonic, "addi")   # addi sp,sp,-4
        self.assertEqual(decode(push[1]).mnemonic, "sw")
        pop = assemble("pop a0")
        self.assertEqual([decode(w).mnemonic for w in pop], ["lw", "addi"])

    def test_putchar_and_halt(self):
        pc = assemble("putchar a0")
        self.assertEqual([decode(w).mnemonic for w in pc], ["addi", "ecall"])
        self.assertEqual(decode(assemble("halt")[0]).mnemonic, "ebreak")

    def test_li_small_and_large(self):
        small = assemble("li a0, 5")
        self.assertEqual(len(small), 1)
        self.assertEqual(decode(small[0]).mnemonic, "addi")
        large = assemble("li a0, 0x12345678")
        self.assertEqual([decode(w).mnemonic for w in large], ["lui", "addi"])


class TestEndToEnd(unittest.TestCase):
    def test_li_reconstructs_constant(self):
        for val in (0xDEADBEEF, 0x12345678, 0x7FF, 0x800, 2047, 0xFFFFF800, 0x1, 0xFFFFF000):
            cpu = run_asm("li a0, 0x%X\nebreak\n" % (val & MASK_32))
            self.assertEqual(cpu.regs[R("a0")], val & MASK_32, hex(val))

    def test_sum_loop(self):
        src = (
            "       li   a0, 0\n"
            "       li   t0, 1\n"
            "       li   t1, 6\n"
            "loop:  bge  t0, t1, done\n"
            "       add  a0, a0, t0\n"
            "       addi t0, t0, 1\n"
            "       j    loop\n"
            "done:  ebreak\n"
        )
        cpu = run_asm(src)
        self.assertEqual(cpu.regs[R("a0")], 15)
        self.assertEqual(cpu.warnings, [])

    def test_la_loads_address(self):
        src = (
            "       la   a0, data\n"
            "       lw   a1, 0(a0)\n"
            "       ebreak\n"
            "data:  .word 0xCAFE\n"
        )
        cpu = run_asm(src)
        data_addr = (len(assemble(src)) - 1) * 4   # last word is `data`
        self.assertEqual(cpu.regs[R("a0")], data_addr)
        self.assertEqual(cpu.regs[R("a1")], 0xCAFE)

    def test_putchar_outputs(self):
        import io
        words = assemble("li a0, 72\nputchar a0\nebreak\n")
        cpu = CPU(mem_size=1 << 12)
        out = io.StringIO(); cpu.output = out
        for i, w in enumerate(words):
            cpu.mem[i * 4:i * 4 + 4] = w.to_bytes(4, "little")
        cpu.code_end_addr = len(words) * 4
        cpu.initialised[0:len(words) * 4] = b"\x01" * (len(words) * 4)
        run(cpu)
        self.assertEqual(out.getvalue(), "H")


class TestMemFormat(unittest.TestCase):
    def test_lines_are_32_bit(self):
        with tempfile.TemporaryDirectory() as td:
            src = os.path.join(td, "x.asm")
            with open(src, "w") as f:
                f.write("add a0, a1, a2\nebreak\n")
            mem, lst = assembler.assemble_file(src, os.path.join(td, "x"))
            with open(mem) as f:
                for line in f:
                    line = line.strip()
                    if line:
                        self.assertRegex(line, BINLINE)
                        from_bin_line(line)


class TestErrors(unittest.TestCase):
    def test_unknown_instruction(self):
        with self.assertRaises(AsmError) as c:
            assemble("frobnicate a0, a1, a2\n")
        self.assertIn("unknown instruction", c.exception.msg)

    def test_unknown_register(self):
        with self.assertRaises(AsmError) as c:
            assemble("add a0, x99, a2\n")
        self.assertIn("unknown register", c.exception.msg)

    def test_undefined_label(self):
        with self.assertRaises(AsmError) as c:
            assemble("j nowhere\n")
        self.assertIn("undefined label", c.exception.msg)

    def test_operand_count(self):
        with self.assertRaises(AsmError) as c:
            assemble("add a0, a1\n")
        self.assertIn("operand", c.exception.msg)

    def test_addi_immediate_out_of_range(self):
        with self.assertRaises(AsmError):
            assemble("addi a0, a1, 4096\n")

    def test_branch_out_of_range(self):
        with self.assertRaises(AsmError):
            assemble("beq a0, a1, 8192\n")

    def test_label_shadows_register(self):
        with self.assertRaises(AsmError) as c:
            assemble("a0: ebreak\n")
        self.assertIn("shadow", c.exception.msg)

    def test_bad_directive(self):
        with self.assertRaises(AsmError) as c:
            assemble(".frobnicate 1\n")
        self.assertIn("not recognised", c.exception.msg)

    def test_caret_format(self):
        try:
            assemble("add a0, x99, a2\n")
        except AsmError as e:
            rendered = e.render()
            self.assertRegex(rendered.splitlines()[0], r":\d+:\d+: error:")


if __name__ == "__main__":
    unittest.main()
