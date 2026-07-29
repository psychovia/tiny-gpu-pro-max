"""
assembler.py -- Turns RV32I+M .asm text into a flat sequence of 32-bit words.

USAGE
    python assembler.py program.asm                 # writes program.mem + program.lst
    python assembler.py program.asm -o build/foo    # writes build/foo.mem + build/foo.lst

SYNTAX
    # line comment  (';' is also accepted, for backward compatibility)
    label:                          # a label may sit on its own line or precede an instr
        add   a0, a1, a2            # R-type: dest, src1, src2
        addi  a0, a1, -5            # I-type, signed 12-bit immediate
        slli  a0, a1, 3            # shift-immediate (shamt 0..31)
        lw    a0, 8(sp)            # load:  a0 <- MEM32[sp + 8]
        sw    a0, 8(sp)            # store: MEM32[sp + 8] <- a0   (a0 is the source)
        lui   a0, 0x12345          # upper immediate (20-bit value placed in [31:12])
        beq   a0, a1, label        # branch; label resolves to a PC-relative byte offset
        jal   ra, func             # jump-and-link
        jalr  a0, a1, 0            # also: jalr a0, 0(a1)
        ecall                      # system service; a7 selects it:
                                   #   a7==1 read one byte into a0 (-1 at EOF)
                                   #   else  emit a0's low byte as one character
        ebreak                     # halt

    PSEUDO-OPS (rewritten into real instructions for you)
        nop                  mv rd, rs        not rd, rs       neg rd, rs
        seqz rd, rs          snez rd, rs      li rd, imm32     la rd, label
        j label              jr rs            ret              call label
        beqz/bnez rs, label  bltz/bgez/blez/bgtz rs, label
        bgt/ble/bgtu/bleu rs, rt, label
        push rd              pop rd           halt             putchar rs

    DATA
        .word 42                    # emit a literal 32-bit word
        .word -1, 0xCAFE, my_label  # comma-separated list (labels resolve to addresses)

OUTPUTS
    *.mem  -- one 32-character binary string per line (SystemVerilog $readmemb format)
    *.lst  -- listing: address, encoded word, and the (expanded) source line

ERRORS
    file:line:col: error: message   plus the source line and a caret.
"""

import argparse
import os
import re
import sys

from isa import INSTRS, encode, reg_num, to_bin_line, MASK_32


# --------------------------------------------------------------------
# Errors
# --------------------------------------------------------------------

class AsmError(Exception):
    """Any assembly error. Renders as file:line:col: error: msg + caret."""

    def __init__(self, msg, filename, lineno, line, col=0, span=1):
        self.msg = msg
        self.filename = filename
        self.lineno = lineno
        self.line = line.rstrip("\n")
        self.col = col
        self.span = max(span, 1)
        super().__init__(self.render())

    def render(self):
        caret = " " * self.col + "^" * self.span
        return ("%s:%d:%d: error: %s\n    %s\n    %s"
                % (self.filename, self.lineno, self.col + 1, self.msg, self.line, caret))


# --------------------------------------------------------------------
# Tokenizer
# --------------------------------------------------------------------

_TOKEN_RE = re.compile(r"""
      (?P<comment> [;\#].* )
    | (?P<paren>   [()] )
    | (?P<comma>   , )
    | (?P<colon>   : )
    | (?P<word>    [A-Za-z_.][A-Za-z0-9_.]* )
    | (?P<num>     -?0[xX][0-9A-Fa-f]+ | -?0[bB][01]+ | -?\d+ )
    | (?P<ws>      \s+ )
""", re.VERBOSE)


class Tok(object):
    __slots__ = ("kind", "text", "col")

    def __init__(self, kind, text, col):
        self.kind = kind
        self.text = text
        self.col = col


def tokenize(line, filename, lineno):
    toks = []
    pos = 0
    while pos < len(line):
        m = _TOKEN_RE.match(line, pos)
        if not m:
            raise AsmError("unexpected character %r" % line[pos], filename, lineno, line, pos)
        kind = m.lastgroup
        if kind not in ("ws", "comment"):
            toks.append(Tok(kind, m.group(), m.start()))
        pos = m.end()
    return toks


# --------------------------------------------------------------------
# Small parsing helpers
# --------------------------------------------------------------------

def parse_int(tok, filename, lineno, line):
    s = tok.text.lower()
    try:
        if s.startswith("-"):
            return -parse_int(Tok("num", s[1:], tok.col + 1), filename, lineno, line)
        if s.startswith("0x"):
            return int(s, 16)
        if s.startswith("0b"):
            return int(s, 2)
        return int(s, 10)
    except ValueError:
        raise AsmError("can't parse %r as a number" % tok.text,
                       filename, lineno, line, tok.col, len(tok.text))


def parse_reg(tok, filename, lineno, line):
    if tok.kind != "word":
        raise AsmError("expected a register name, got %r" % tok.text,
                       filename, lineno, line, tok.col, len(tok.text))
    try:
        return reg_num(tok.text)
    except ValueError as e:
        raise AsmError(str(e), filename, lineno, line, tok.col, len(tok.text))


def split_commas(toks, filename, lineno, line):
    if not toks:
        return []
    groups = [[]]
    for t in toks:
        if t.kind == "comma":
            if not groups[-1]:
                raise AsmError("empty operand before ','", filename, lineno, line, t.col)
            groups.append([])
        else:
            groups[-1].append(t)
    if not groups[-1]:
        raise AsmError("trailing ','", filename, lineno, line, toks[-1].col)
    return groups


def parse_mem_operand(group, filename, lineno, line):
    """Parse `imm(rs1)` (or `(rs1)` for imm=0); return (imm, rs1_index)."""
    i = 0
    if group and group[0].kind == "num":
        imm = parse_int(group[0], filename, lineno, line)
        i = 1
    else:
        imm = 0
    if i >= len(group) or group[i].kind != "paren" or group[i].text != "(":
        col = group[i].col if i < len(group) else group[-1].col
        raise AsmError("expected '(' in memory operand", filename, lineno, line, col)
    i += 1
    if i >= len(group) or group[i].kind != "word":
        col = group[i].col if i < len(group) else group[-1].col
        raise AsmError("expected register name inside parentheses", filename, lineno, line, col)
    rs1 = parse_reg(group[i], filename, lineno, line)
    i += 1
    if i >= len(group) or group[i].kind != "paren" or group[i].text != ")":
        col = group[i].col if i < len(group) else group[-1].col
        raise AsmError("expected ')' to close memory operand", filename, lineno, line, col)
    i += 1
    if i != len(group):
        raise AsmError("unexpected tokens after memory operand", filename, lineno, line, group[i].col)
    return imm, rs1


def split_hi_lo(value):
    """Split a 32-bit value into (hi20, lo12-signed) so that
    (hi << 12) + sext12(lo) == value, accounting for addi's sign extension."""
    value &= MASK_32
    lo = value & 0xFFF
    if lo & 0x800:
        lo -= 0x1000                      # sign-extend the low 12 bits
    hi = ((value - lo) >> 12) & 0xFFFFF
    return hi, lo


# --------------------------------------------------------------------
# Program representation
# --------------------------------------------------------------------

class Item(object):
    """One 32-bit output slot. `word` is filled eagerly when known; otherwise
    `resolve(prog)` computes it in pass 2 (after labels are known)."""
    __slots__ = ("addr", "lineno", "source", "word", "resolve")

    def __init__(self, addr, lineno, source, word=None, resolve=None):
        self.addr = addr
        self.lineno = lineno
        self.source = source
        self.word = word
        self.resolve = resolve


class Program(object):
    def __init__(self, filename=""):
        self.items = []
        self.labels = {}        # name -> byte address
        self.filename = filename


# --------------------------------------------------------------------
# Pass 1: parse, expand pseudo-ops, lay out addresses, collect labels
# --------------------------------------------------------------------

# Instruction syntactic categories (by mnemonic). fmt comes from isa.INSTRS;
# these refine the *syntax* within a format.
_LOADS = {"lb", "lh", "lw", "lbu", "lhu"}
_PSEUDO = {
    "nop", "mv", "not", "neg", "seqz", "snez", "li", "la",
    "j", "jr", "ret", "call", "beqz", "bnez",
    "bgt", "ble", "bgtu", "bleu", "bltz", "bgez", "blez", "bgtz",
    "push", "pop", "halt", "putchar",
}


def parse_source(source, filename):
    prog = Program(filename=filename)
    addr = [0]   # boxed so nested helper can mutate

    def out(source_str, word=None, resolve=None):
        prog.items.append(Item(addr[0], lineno, source_str, word=word, resolve=resolve))
        addr[0] += 4

    def emit_real(mn, rd=0, rs1=0, rs2=0, imm=0, src=None, col=0, span=1):
        """Eagerly encode a real instruction whose fields are all known."""
        try:
            w = encode(mn, rd=rd, rs1=rs1, rs2=rs2, imm=imm)
        except ValueError as e:
            raise AsmError(str(e), filename, lineno, raw_line, col, span)
        out(src if src is not None else mn, word=w)

    def emit_branch(real_mn, rs1, rs2, group, col, span):
        """Branch with a label or numeric byte-offset target (B-type)."""
        here = addr[0]
        if len(group) == 1 and group[0].kind == "num":
            off = parse_int(group[0], filename, lineno, raw_line)
            try:
                w = encode(real_mn, rs1=rs1, rs2=rs2, imm=off)
            except ValueError as e:
                raise AsmError(str(e), filename, lineno, raw_line, group[0].col, len(group[0].text))
            out("%s x%d, x%d, %d" % (real_mn, rs1, rs2, off), word=w)
        elif len(group) == 1 and group[0].kind == "word":
            label = group[0].text
            src = "%s %s, %s, %s" % (real_mn, reg_num_name(rs1), reg_num_name(rs2), label)

            def resolve(prog, here=here, label=label, real_mn=real_mn, rs1=rs1, rs2=rs2,
                        lineno=lineno, raw_line=raw_line, col=col, span=span):
                if label not in prog.labels:
                    raise AsmError("undefined label %r" % label, filename, lineno, raw_line, col, span)
                off = prog.labels[label] - here
                try:
                    return encode(real_mn, rs1=rs1, rs2=rs2, imm=off)
                except ValueError:
                    raise AsmError("branch target %r is %d bytes away (B-type range is +/-4096)"
                                   % (label, off), filename, lineno, raw_line, col, span)
            out(src, resolve=resolve)
        else:
            raise AsmError("expected a label or numeric offset",
                           filename, lineno, raw_line, group[0].col, len(group[0].text))

    def emit_jal(rd, group, col, span):
        """jal with a label or numeric byte-offset target (J-type)."""
        here = addr[0]
        if len(group) == 1 and group[0].kind == "num":
            off = parse_int(group[0], filename, lineno, raw_line)
            try:
                w = encode("jal", rd=rd, imm=off)
            except ValueError as e:
                raise AsmError(str(e), filename, lineno, raw_line, group[0].col, len(group[0].text))
            out("jal %s, %d" % (reg_num_name(rd), off), word=w)
        elif len(group) == 1 and group[0].kind == "word":
            label = group[0].text
            src = "jal %s, %s" % (reg_num_name(rd), label)

            def resolve(prog, here=here, label=label, rd=rd,
                        lineno=lineno, raw_line=raw_line, col=col, span=span):
                if label not in prog.labels:
                    raise AsmError("undefined label %r" % label, filename, lineno, raw_line, col, span)
                off = prog.labels[label] - here
                try:
                    return encode("jal", rd=rd, imm=off)
                except ValueError:
                    raise AsmError("jump target %r is %d bytes away (J-type range is +/-1 MiB)"
                                   % (label, off), filename, lineno, raw_line, col, span)
            out(src, resolve=resolve)
        else:
            raise AsmError("expected a label or numeric offset",
                           filename, lineno, raw_line, group[0].col, len(group[0].text))

    def emit_la(rd, group, col, span):
        """la rd, label -> lui + addi of the label's absolute address (always 2 words)."""
        if len(group) != 1 or group[0].kind != "word":
            raise AsmError("la expects a label", filename, lineno, raw_line, group[0].col)
        label = group[0].text
        here = addr[0]

        def resolve_lui(prog, label=label, rd=rd, col=col, span=span,
                        lineno=lineno, raw_line=raw_line):
            if label not in prog.labels:
                raise AsmError("undefined label %r" % label, filename, lineno, raw_line, col, span)
            hi, _ = split_hi_lo(prog.labels[label])
            return encode("lui", rd=rd, imm=hi)

        def resolve_addi(prog, label=label, rd=rd, col=col, span=span,
                         lineno=lineno, raw_line=raw_line):
            _, lo = split_hi_lo(prog.labels[label])
            return encode("addi", rd=rd, rs1=rd, imm=lo)

        out("lui %s, %%hi(%s)   ; from la" % (reg_num_name(rd), label), resolve=resolve_lui)
        out("addi %s, %s, %%lo(%s)   ; from la" % (reg_num_name(rd), reg_num_name(rd), label),
            resolve=resolve_addi)

    for lineno, raw_line in enumerate(source.splitlines(), start=1):
        toks = tokenize(raw_line, filename, lineno)
        if not toks:
            continue

        # leading label(s)
        while len(toks) >= 2 and toks[0].kind == "word" and toks[1].kind == "colon":
            name = toks[0].text
            if name in prog.labels:
                raise AsmError("label %r already defined" % name,
                               filename, lineno, raw_line, toks[0].col, len(name))
            if _is_reg_name(name):
                raise AsmError("label %r would shadow a register name" % name,
                               filename, lineno, raw_line, toks[0].col, len(name))
            prog.labels[name] = addr[0]
            toks = toks[2:]
        if not toks:
            continue

        if toks[0].kind != "word":
            raise AsmError("expected a mnemonic, label, or directive; got %r" % toks[0].text,
                           filename, lineno, raw_line, toks[0].col, len(toks[0].text))

        head = toks[0].text
        rest = toks[1:]
        col, span = toks[0].col, len(head)

        # ---- directives ----
        if head.startswith("."):
            if head == ".word":
                for g in split_commas(rest, filename, lineno, raw_line):
                    if len(g) != 1:
                        raise AsmError("each .word operand must be a single literal or label",
                                       filename, lineno, raw_line, g[0].col)
                    t = g[0]
                    if t.kind == "num":
                        v = parse_int(t, filename, lineno, raw_line) & MASK_32
                        out(".word %s" % t.text, word=v)
                    elif t.kind == "word":
                        label = t.text
                        lcol, lspan = t.col, len(label)

                        def resolve(prog, label=label, lcol=lcol, lspan=lspan,
                                    lineno=lineno, raw_line=raw_line):
                            if label not in prog.labels:
                                raise AsmError("undefined label %r" % label,
                                               filename, lineno, raw_line, lcol, lspan)
                            return prog.labels[label] & MASK_32
                        out(".word %s" % label, resolve=resolve)
                    else:
                        raise AsmError("unexpected %r in .word" % t.text,
                                       filename, lineno, raw_line, t.col, len(t.text))
            else:
                raise AsmError("directive %r not recognised" % head,
                               filename, lineno, raw_line, col, span)
            continue

        mn = head.lower()
        operands = split_commas(rest, filename, lineno, raw_line)

        def need(n):
            if len(operands) != n:
                raise AsmError("%s expects %d operand(s); got %d" % (mn, n, len(operands)),
                               filename, lineno, raw_line, col, span)

        def reg(i):
            return parse_reg(operands[i][0], filename, lineno, raw_line)

        def imm(i):
            g = operands[i]
            if len(g) != 1 or g[0].kind != "num":
                raise AsmError("%s expects a numeric immediate here" % mn,
                               filename, lineno, raw_line, g[0].col, len(g[0].text))
            return parse_int(g[0], filename, lineno, raw_line)

        # ---- pseudo-ops ----
        if mn in _PSEUDO:
            if mn == "nop":
                need(0); emit_real("addi", rd=0, rs1=0, imm=0, src="addi zero, zero, 0   ; nop", col=col, span=span)
            elif mn == "mv":
                need(2); rd, rs = reg(0), reg(1)
                emit_real("addi", rd=rd, rs1=rs, imm=0,
                          src="addi %s, %s, 0   ; mv" % (reg_num_name(rd), reg_num_name(rs)), col=col, span=span)
            elif mn == "not":
                need(2); rd, rs = reg(0), reg(1)
                emit_real("xori", rd=rd, rs1=rs, imm=-1,
                          src="xori %s, %s, -1   ; not" % (reg_num_name(rd), reg_num_name(rs)), col=col, span=span)
            elif mn == "neg":
                need(2); rd, rs = reg(0), reg(1)
                emit_real("sub", rd=rd, rs1=0, rs2=rs,
                          src="sub %s, zero, %s   ; neg" % (reg_num_name(rd), reg_num_name(rs)), col=col, span=span)
            elif mn == "seqz":
                need(2); rd, rs = reg(0), reg(1)
                emit_real("sltiu", rd=rd, rs1=rs, imm=1,
                          src="sltiu %s, %s, 1   ; seqz" % (reg_num_name(rd), reg_num_name(rs)), col=col, span=span)
            elif mn == "snez":
                need(2); rd, rs = reg(0), reg(1)
                emit_real("sltu", rd=rd, rs1=0, rs2=rs,
                          src="sltu %s, zero, %s   ; snez" % (reg_num_name(rd), reg_num_name(rs)), col=col, span=span)
            elif mn == "li":
                need(2); rd = reg(0); value = imm(1)
                if not (-(1 << 31) <= value < (1 << 32)):
                    g = operands[1]
                    raise AsmError("li immediate %d does not fit in 32 bits" % value,
                                   filename, lineno, raw_line, g[0].col, len(g[0].text))
                for real_mn, kw, src in expand_li(rd, value):
                    emit_real(real_mn, src=src, col=col, span=span, **kw)
            elif mn == "la":
                need(2); rd = reg(0); emit_la(rd, operands[1], col, span)
            elif mn == "j":
                need(1); emit_jal(0, operands[0], col, span)
            elif mn == "jr":
                need(1); rs = reg(0)
                emit_real("jalr", rd=0, rs1=rs, imm=0,
                          src="jalr zero, %s, 0   ; jr" % reg_num_name(rs), col=col, span=span)
            elif mn == "ret":
                need(0); emit_real("jalr", rd=0, rs1=1, imm=0, src="jalr zero, ra, 0   ; ret", col=col, span=span)
            elif mn == "call":
                need(1); emit_jal(1, operands[0], col, span)
            elif mn in ("beqz", "bnez"):
                need(2); rs = reg(0)
                emit_branch("beq" if mn == "beqz" else "bne", rs, 0, operands[1], col, span)
            elif mn == "bltz":
                need(2); emit_branch("blt", reg(0), 0, operands[1], col, span)
            elif mn == "bgez":
                need(2); emit_branch("bge", reg(0), 0, operands[1], col, span)
            elif mn == "blez":
                need(2); emit_branch("bge", 0, reg(0), operands[1], col, span)
            elif mn == "bgtz":
                need(2); emit_branch("blt", 0, reg(0), operands[1], col, span)
            elif mn in ("bgt", "ble", "bgtu", "bleu"):
                need(3); a, b = reg(0), reg(1)
                real = {"bgt": "blt", "ble": "bge", "bgtu": "bltu", "bleu": "bgeu"}[mn]
                emit_branch(real, b, a, operands[2], col, span)   # swapped operands
            elif mn == "push":
                need(1); rd = reg(0)
                emit_real("addi", rd=2, rs1=2, imm=-4, src="addi sp, sp, -4   ; push", col=col, span=span)
                emit_real("sw", rs1=2, rs2=rd, imm=0,
                          src="sw %s, 0(sp)   ; push" % reg_num_name(rd), col=col, span=span)
            elif mn == "pop":
                need(1); rd = reg(0)
                emit_real("lw", rd=rd, rs1=2, imm=0,
                          src="lw %s, 0(sp)   ; pop" % reg_num_name(rd), col=col, span=span)
                emit_real("addi", rd=2, rs1=2, imm=4, src="addi sp, sp, 4   ; pop", col=col, span=span)
            elif mn == "halt":
                need(0); emit_real("ebreak", src="ebreak   ; halt", col=col, span=span)
            elif mn == "putchar":
                need(1); rs = reg(0)
                emit_real("addi", rd=10, rs1=rs, imm=0,
                          src="addi a0, %s, 0   ; putchar" % reg_num_name(rs), col=col, span=span)
                emit_real("ecall", src="ecall   ; putchar", col=col, span=span)
            continue

        # ---- real instructions ----
        if mn not in INSTRS:
            raise AsmError("unknown instruction %r" % head, filename, lineno, raw_line, col, span)
        fmt = INSTRS[mn].fmt

        if fmt == "R":
            need(3); rd, rs1, rs2 = reg(0), reg(1), reg(2)
            emit_real(mn, rd=rd, rs1=rs1, rs2=rs2,
                      src="%s %s, %s, %s" % (mn, reg_num_name(rd), reg_num_name(rs1), reg_num_name(rs2)),
                      col=col, span=span)
        elif fmt == "I_SHIFT":
            need(3); rd, rs1, sh = reg(0), reg(1), imm(2)
            emit_real(mn, rd=rd, rs1=rs1, imm=sh,
                      src="%s %s, %s, %d" % (mn, reg_num_name(rd), reg_num_name(rs1), sh),
                      col=col, span=span)
        elif fmt == "I":
            if mn in _LOADS:
                need(2); rd = reg(0)
                ioff, rs1 = parse_mem_operand(operands[1], filename, lineno, raw_line)
                emit_real(mn, rd=rd, rs1=rs1, imm=ioff,
                          src="%s %s, %d(%s)" % (mn, reg_num_name(rd), ioff, reg_num_name(rs1)),
                          col=col, span=span)
            elif mn == "jalr":
                # jalr rd, rs1, imm   OR   jalr rd, imm(rs1)
                if len(operands) == 3:
                    rd, rs1, off = reg(0), reg(1), imm(2)
                elif len(operands) == 2:
                    rd = reg(0)
                    off, rs1 = parse_mem_operand(operands[1], filename, lineno, raw_line)
                else:
                    raise AsmError("jalr expects 'rd, rs1, imm' or 'rd, imm(rs1)'",
                                   filename, lineno, raw_line, col, span)
                emit_real(mn, rd=rd, rs1=rs1, imm=off,
                          src="jalr %s, %s, %d" % (reg_num_name(rd), reg_num_name(rs1), off),
                          col=col, span=span)
            else:
                need(3); rd, rs1, iv = reg(0), reg(1), imm(2)
                emit_real(mn, rd=rd, rs1=rs1, imm=iv,
                          src="%s %s, %s, %d" % (mn, reg_num_name(rd), reg_num_name(rs1), iv),
                          col=col, span=span)
        elif fmt == "S":
            need(2); rs2 = reg(0)
            soff, rs1 = parse_mem_operand(operands[1], filename, lineno, raw_line)
            emit_real(mn, rs1=rs1, rs2=rs2, imm=soff,
                      src="%s %s, %d(%s)" % (mn, reg_num_name(rs2), soff, reg_num_name(rs1)),
                      col=col, span=span)
        elif fmt == "B":
            need(3); rs1, rs2 = reg(0), reg(1)
            emit_branch(mn, rs1, rs2, operands[2], col, span)
        elif fmt == "U":
            need(2); rd, iv = reg(0), imm(1)
            emit_real(mn, rd=rd, imm=iv,
                      src="%s %s, 0x%X" % (mn, reg_num_name(rd), iv & 0xFFFFF), col=col, span=span)
        elif fmt == "J":
            need(2); rd = reg(0); emit_jal(rd, operands[1], col, span)
        elif fmt == "SYS":
            need(0); emit_real(mn, src=mn, col=col, span=span)
        elif fmt == "CUST_RD":                 # rdtid rd
            need(1); rd = reg(0)
            emit_real(mn, rd=rd,
                      src="%s %s" % (mn, reg_num_name(rd)), col=col, span=span)
        elif fmt == "CUST_2SRC":               # setdt rs1, rs2
            need(2); rs1, rs2 = reg(0), reg(1)
            emit_real(mn, rs1=rs1, rs2=rs2,
                      src="%s %s, %s" % (mn, reg_num_name(rs1), reg_num_name(rs2)),
                      col=col, span=span)
        elif fmt == "CUST_RD1SRC":             # getdt rd, rs1
            need(2); rd, rs1 = reg(0), reg(1)
            emit_real(mn, rd=rd, rs1=rs1,
                      src="%s %s, %s" % (mn, reg_num_name(rd), reg_num_name(rs1)),
                      col=col, span=span)
        else:
            raise AssertionError(fmt)

    return prog


def expand_li(rd, value):
    """Return a list of (real_mnemonic, kwargs, source_str) for `li rd, value`."""
    v = value & MASK_32
    s = v - (1 << 32) if v & 0x80000000 else v
    if -2048 <= s <= 2047:
        return [("addi", dict(rd=rd, rs1=0, imm=s),
                 "addi %s, zero, %d   ; li" % (reg_num_name(rd), s))]
    hi, lo = split_hi_lo(v)
    if lo == 0:
        return [("lui", dict(rd=rd, imm=hi),
                 "lui %s, 0x%X   ; li" % (reg_num_name(rd), hi))]
    return [
        ("lui", dict(rd=rd, imm=hi), "lui %s, 0x%X   ; li 0x%X" % (reg_num_name(rd), hi, v)),
        ("addi", dict(rd=rd, rs1=rd, imm=lo), "addi %s, %s, %d   ; li 0x%X"
         % (reg_num_name(rd), reg_num_name(rd), lo, v)),
    ]


# --------------------------------------------------------------------
# Pass 2: resolve deferred encoders
# --------------------------------------------------------------------

def finalize(prog):
    for item in prog.items:
        if item.word is None:
            item.word = item.resolve(prog)
    return prog


# --------------------------------------------------------------------
# Output writers
# --------------------------------------------------------------------

def write_mem(prog, path):
    with open(path, "w") as f:
        for item in prog.items:
            f.write(to_bin_line(item.word) + "\n")


def write_listing(prog, path):
    with open(path, "w") as f:
        f.write("# addr      word      source\n")
        for item in prog.items:
            f.write("%08X  %08X  %s\n" % (item.addr, item.word, item.source))


# --------------------------------------------------------------------
# Convenience: assemble a string straight to a list of words (used by tests)
# --------------------------------------------------------------------

def assemble(source, filename="<asm>"):
    prog = finalize(parse_source(source, filename))
    return [item.word for item in prog.items]


def assemble_file(input_path, output_base=None):
    with open(input_path) as f:
        source = f.read()
    if output_base is None:
        output_base = os.path.splitext(input_path)[0]
    prog = finalize(parse_source(source, filename=input_path))
    mem_path = output_base + ".mem"
    lst_path = output_base + ".lst"
    out_dir = os.path.dirname(output_base)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    write_mem(prog, mem_path)
    write_listing(prog, lst_path)
    return mem_path, lst_path


# --------------------------------------------------------------------
# Helpers that need isa imports
# --------------------------------------------------------------------

from isa import reg_name as reg_num_name, REG_NAMES, REG_ALIASES   # noqa: E402


def _is_reg_name(name):
    n = name.lower()
    if n in REG_ALIASES:
        return True
    if n in REG_NAMES:
        return True
    if len(n) >= 2 and n[0] == "x" and n[1:].isdigit() and 0 <= int(n[1:]) <= 31:
        return True
    return False


# --------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(description="Assemble RV32I+M .asm into .mem and .lst")
    ap.add_argument("input", help=".asm source file")
    ap.add_argument("-o", "--output", default=None,
                    help="output base path (default: same as input, no extension)")
    args = ap.parse_args(argv)
    try:
        mem, lst = assemble_file(args.input, args.output)
        print("wrote %s" % mem)
        print("wrote %s" % lst)
    except AsmError as e:
        print(e.render(), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
