"""
compiler.py -- A tiny C-subset compiler that targets our RV32I+M(mul) ISA.

USAGE
    python compiler.py program.c                # writes program.asm
    python compiler.py program.c -o other.asm

WHAT C YOU CAN WRITE
    - Only the `int` type (a 32-bit signed integer). Nothing else.
        int x;
        int x = 5;
        int *p; int **pp;     // pointers, to any depth
        int arr[10];          // 1-D array (global or local)
        int grid[2][3];       // multi-dimensional arrays too (row-major)
    - Functions:
        int add(int a, int b) { return a + b; }
      Any number of parameters: the first 8 in a0..a7, the rest passed on the
      stack (standard RISC-V). Return value in a0.
    - Statements: blocks, if/else, while, do-while, for, switch/case/default,
      break, continue, return, and expression statements.
    - Expressions:
        literals (decimal, 0x..., 0b...)
        identifiers (locals, params, globals, arrays)
        function calls
        unary  -x  !x  ~x  ++x  --x  (also postfix x++  x--)
        address-of &x and dereference *p  (pointers of any depth; pointer
                                           arithmetic and array/pointer decay)
        binary + - * / % & | ^ << >> && || == != < <= > >=
        assignment = (also += -= *= /= %= &= |= ^= <<= >>=)
        array index  a[i]  and  a[i][j]...  (read and write; fully indexed)
    - Built-ins:
        print(x)            prints x as a signed decimal followed by a newline.
        scanf("%d", &x)     reads one decimal integer from input into *(&x).
                            Supports %d and %u and several conversions per call,
                            e.g. scanf("%d %d", &a, &b); returns the number of
                            values read (0..n), or -1 at end-of-input -- exactly
                            like C, so `while (scanf("%d", &x) == 1) ...` works.
      String literals ("...") are accepted ONLY as the scanf format string.

    `/` and `%` ARE supported: there is no hardware divide instruction, so the
    compiler lowers them to a software routine (__divmod) built from add/sub/
    shift/compare. Signed semantics follow C99 (quotient truncates toward zero;
    the remainder takes the sign of the dividend).

WHAT YOU CANNOT WRITE  (the compiler emits a clear error)
    - float, double, char, short, long, structs, unions, enums, typedef
    - casts, sizeof, function pointers, void*, varargs
    - any preprocessor directive (#include, #define, ...)

HOW IT WORKS
    1. Lex   -- regex tokenizer producing tokens with file positions.
    2. Parse -- recursive-descent parser building an AST.
    3. Check -- semantic pass enforcing language rules.
    4. Emit  -- recursive walk writing RV32I assembly text.

    Register usage (RISC-V ABI):
        a0..a7   args / return value (a0). Caller-saved.
        t0, t1   expression-stack scratch. Caller-saved.
        s0       frame pointer (callee-saved). Saved in every prologue.
        ra       return address (saved in every prologue).

    Expression evaluation is a textbook stack machine: every sub-expression
    leaves its value on the runtime stack (via push/pop). Operators pop their
    operands into t0/t1. Slow, but easy to read and inherently call-safe.

    Each emitted .asm is self-contained: a `_start` prologue (sets sp, calls
    main, then ebreak) plus the runtime helpers __udivmod/__divmod/__print_int
    when the program needs them.
"""

import argparse
import io
import os
import re
import sys
from typing import Optional


# ====================================================================
# Errors
# ====================================================================

class CompileError(Exception):
    def __init__(self, msg, filename, line, col, source_line, span=1):
        self.msg = msg
        self.filename = filename
        self.line = line
        self.col = col
        self.source_line = source_line.rstrip("\n")
        self.span = max(span, 1)
        super().__init__(self.render())

    def render(self):
        caret = " " * self.col + "^" * self.span
        return ("%s:%d:%d: error: %s\n    %s\n    %s"
                % (self.filename, self.line, self.col + 1, self.msg,
                   self.source_line, caret))


# ====================================================================
# Lexer
# ====================================================================

KEYWORDS = {
    "int", "if", "else", "while", "do", "for", "switch", "case", "default",
    "return", "break", "continue",
    "void", "float", "double", "char", "short", "long", "signed", "unsigned",
    "struct", "union", "enum", "typedef", "sizeof", "static", "extern", "const",
    "tid",   # GPU builtin: this thread's id (read-only; can't be used as a name)
}

_TOKEN_SPEC = [
    ("WS",        r"[ \t]+"),
    ("NEWLINE",   r"\n"),
    ("COMMENT_L", r"//[^\n]*"),
    ("COMMENT_B", r"/\*.*?\*/"),
    ("STRING",    r'"(?:\\.|[^"\\\n])*"'),
    ("HEX",       r"0[xX][0-9a-fA-F]+"),
    ("BIN",       r"0[bB][01]+"),
    ("INT",       r"\d+"),
    ("ID",        r"[A-Za-z_][A-Za-z0-9_]*"),
    ("PUNCT",     r"<<=|>>=|<=|>=|==|!=|&&|\|\||<<|>>|\+\+|--|"
                  r"\+=|-=|\*=|/=|%=|&=|\|=|\^=|"
                  r"[+\-*/%&|^~!=<>(){}\[\];,:]"),
]
_TOKEN_RE = re.compile("|".join("(?P<%s>%s)" % (n, p) for n, p in _TOKEN_SPEC), re.DOTALL)


class Token(object):
    __slots__ = ("kind", "text", "line", "col", "source_line")

    def __init__(self, kind, text, line, col, source_line):
        self.kind = kind
        self.text = text
        self.line = line
        self.col = col
        self.source_line = source_line


def tokenize(source, filename):
    lines = source.split("\n")
    tokens = []
    pos = 0
    line = 1
    line_start = 0
    while pos < len(source):
        m = _TOKEN_RE.match(source, pos)
        if not m:
            col = pos - line_start
            raise CompileError("unexpected character %r" % source[pos],
                               filename, line, col, lines[line - 1])
        kind = m.lastgroup
        text = m.group()
        col = pos - line_start
        if kind == "NEWLINE":
            line += 1
            line_start = m.end()
        elif kind in ("WS", "COMMENT_L"):
            pass
        elif kind == "COMMENT_B":
            n = text.count("\n")
            if n:
                line += n
                line_start = m.end() - (len(text) - text.rfind("\n") - 1)
        elif kind == "STRING":
            tokens.append(Token("STRING", text, line, col, lines[line - 1]))
        elif kind in ("HEX", "BIN", "INT"):
            tokens.append(Token("INT", text, line, col, lines[line - 1]))
        elif kind == "ID":
            kk = "KW" if text in KEYWORDS else "ID"
            tokens.append(Token(kk, text, line, col, lines[line - 1]))
        elif kind == "PUNCT":
            tokens.append(Token(text, text, line, col, lines[line - 1]))
        else:
            raise AssertionError(kind)
        pos = m.end()
    tokens.append(Token("EOF", "", line, 0, lines[-1] if lines else ""))
    return tokens


# ====================================================================
# AST (plain classes -- no dataclasses, for Python 3.6)
# ====================================================================

class Node(object):
    def __init__(self, line=0, col=0, source_line=""):
        self.line = line
        self.col = col
        self.source_line = source_line


class IntLit(Node):
    def __init__(self, line=0, col=0, source_line="", value=0):
        Node.__init__(self, line, col, source_line)
        self.value = value


class VarRef(Node):
    def __init__(self, line=0, col=0, source_line="", name=""):
        Node.__init__(self, line, col, source_line)
        self.name = name


class Index(Node):
    def __init__(self, line=0, col=0, source_line="", array=None, idx=None):
        Node.__init__(self, line, col, source_line)
        self.array = array
        self.idx = idx


class Call(Node):
    def __init__(self, line=0, col=0, source_line="", name="", args=None):
        Node.__init__(self, line, col, source_line)
        self.name = name
        self.args = args if args is not None else []


class Unary(Node):
    def __init__(self, line=0, col=0, source_line="", op="", operand=None):
        Node.__init__(self, line, col, source_line)
        self.op = op
        self.operand = operand


class StrLit(Node):
    """A "..." string literal. Only legal as the scanf format argument; the
    format is consumed at compile time, so no string ever exists at runtime."""
    def __init__(self, line=0, col=0, source_line="", value="", raw=""):
        Node.__init__(self, line, col, source_line)
        self.value = value          # decoded characters
        self.raw = raw              # source text including quotes


class Binary(Node):
    def __init__(self, line=0, col=0, source_line="", op="", lhs=None, rhs=None):
        Node.__init__(self, line, col, source_line)
        self.op = op
        self.lhs = lhs
        self.rhs = rhs


class Assign(Node):
    def __init__(self, line=0, col=0, source_line="", op="", target=None, value=None):
        Node.__init__(self, line, col, source_line)
        self.op = op
        self.target = target
        self.value = value


class PostIncDec(Node):
    # x++ / x-- : applies the side effect but the expression's VALUE is the
    # operand's ORIGINAL value (unlike prefix ++x/--x, which yields the new one).
    def __init__(self, line=0, col=0, source_line="", op="++", target=None):
        Node.__init__(self, line, col, source_line)
        self.op = op
        self.target = target


class Block(Node):
    def __init__(self, line=0, col=0, source_line="", stmts=None):
        Node.__init__(self, line, col, source_line)
        self.stmts = stmts if stmts is not None else []


class VarDecl(Node):
    def __init__(self, line=0, col=0, source_line="", name="", init=None,
                 is_array=False, dims=None, ctype=None):
        Node.__init__(self, line, col, source_line)
        self.name = name
        self.init = init
        self.is_array = is_array
        self.dims = dims if dims is not None else []   # e.g. [10] or [2][3] -> [2,3]
        self.ctype = ctype if ctype is not None else CType.int_()


class If(Node):
    def __init__(self, line=0, col=0, source_line="", cond=None, then=None, else_=None):
        Node.__init__(self, line, col, source_line)
        self.cond = cond
        self.then = then
        self.else_ = else_


class While(Node):
    def __init__(self, line=0, col=0, source_line="", cond=None, body=None):
        Node.__init__(self, line, col, source_line)
        self.cond = cond
        self.body = body


class DoWhile(Node):
    def __init__(self, line=0, col=0, source_line="", cond=None, body=None):
        Node.__init__(self, line, col, source_line)
        self.cond = cond
        self.body = body


class Switch(Node):
    def __init__(self, line=0, col=0, source_line="", expr=None, items=None):
        Node.__init__(self, line, col, source_line)
        self.expr = expr
        self.items = items if items is not None else []


class Case(Node):
    def __init__(self, line=0, col=0, source_line="", value=0):
        Node.__init__(self, line, col, source_line)
        self.value = value


class Default(Node):
    pass


class For(Node):
    def __init__(self, line=0, col=0, source_line="", init=None, cond=None,
                 update=None, body=None):
        Node.__init__(self, line, col, source_line)
        self.init = init
        self.cond = cond
        self.update = update
        self.body = body


class Return(Node):
    def __init__(self, line=0, col=0, source_line="", value=None):
        Node.__init__(self, line, col, source_line)
        self.value = value


class Break(Node):
    pass


class Continue(Node):
    pass


class ExprStmt(Node):
    def __init__(self, line=0, col=0, source_line="", expr=None):
        Node.__init__(self, line, col, source_line)
        self.expr = expr


class Func(Node):
    def __init__(self, line=0, col=0, source_line="", name="", params=None, body=None):
        Node.__init__(self, line, col, source_line)
        self.name = name
        self.params = params if params is not None else []   # (name, CType, tok)
        self.body = body
        self.ret_type = CType.int_()


class Program(Node):
    def __init__(self, line=0, col=0, source_line="", globals=None, funcs=None):
        Node.__init__(self, line, col, source_line)
        self.globals = globals if globals is not None else []
        self.funcs = funcs if funcs is not None else []


# ====================================================================
# Types  (int, pointers of any depth, and arrays -- nested for multi-dim)
# ====================================================================

class CType(object):
    """A C type: an int, a pointer to another CType, or an array of them.
    A scalar (int) and any pointer are 4 bytes. An array's size is its element
    size times its length. Multi-dimensional arrays nest (int[2][3] is an
    array(2) of array(3) of int)."""

    def __init__(self, kind, pointee=None, count=None):
        self.kind = kind            # 'int' | 'ptr' | 'array'
        self.pointee = pointee      # the pointee type (ptr) or element type (array)
        self.count = count          # array length

    @staticmethod
    def int_():
        return CType("int")

    @staticmethod
    def ptr(t):
        return CType("ptr", pointee=t)

    @staticmethod
    def array(elem, n):
        return CType("array", pointee=elem, count=n)

    def is_int(self):
        return self.kind == "int"

    def is_ptr(self):
        return self.kind == "ptr"

    def is_array(self):
        return self.kind == "array"

    def size(self):
        if self.kind == "array":
            return self.count * self.pointee.size()
        return 4

    def decay(self):
        """Array-to-pointer decay: an array used as a value becomes a pointer to
        its first element. Everything else is its own value type."""
        if self.kind == "array":
            return CType.ptr(self.pointee)
        return self

    def __repr__(self):
        if self.kind == "int":
            return "int"
        if self.kind == "ptr":
            return "%s*" % repr(self.pointee)
        return "%s[%d]" % (repr(self.pointee), self.count)


def build_type(nstars, dims):
    """Build the declared type for `int <nstars '*'> name <dims>`.  Per C
    declarator rules, [] binds tighter than *, so `int *a[5]` is an array of
    pointers: array(5, ptr(int))."""
    t = CType.int_()
    for _ in range(nstars):
        t = CType.ptr(t)
    for d in reversed(dims):
        t = CType.array(t, d)
    return t


# ====================================================================
# Parser
# ====================================================================

class Parser(object):
    def __init__(self, tokens, filename):
        self.toks = tokens
        self.pos = 0
        self.filename = filename

    def peek(self, off=0):
        return self.toks[self.pos + off]

    def at(self, *kinds):
        t = self.peek()
        return any(t.kind == k or t.text == k for k in kinds)

    def eat(self, kind):
        t = self.peek()
        if t.kind != kind and t.text != kind:
            self.err("expected %r, got %r" % (kind, t.text), t)
        self.pos += 1
        return t

    def err(self, msg, tok, span=None):
        raise CompileError(msg, self.filename, tok.line, tok.col, tok.source_line,
                           span if span is not None else max(len(tok.text), 1))

    _BAD_TYPES = {"float", "double", "char", "short", "long", "signed", "unsigned",
                  "struct", "union", "enum", "void"}

    def consume_type(self):
        t = self.peek()
        if t.kind == "KW" and t.text == "int":
            self.pos += 1
            return t
        if t.kind == "KW" and t.text in self._BAD_TYPES:
            self.err("only 'int' (and pointers/arrays of int) is supported in this ISA "
                     "(got %r)" % t.text, t)
        self.err("expected type 'int', got %r" % t.text, t)

    def parse_stars(self):
        """Count the leading '*'s of a declarator (pointer depth)."""
        n = 0
        while self.peek().text == "*":
            self.pos += 1
            n += 1
        return n

    def parse_program(self):
        p = Program()
        while not self.at("EOF"):
            t = self.peek()
            if t.text == "#":
                self.err("preprocessor directives are not supported", t)
            if t.kind == "KW" and t.text in ("struct", "union", "enum", "typedef"):
                self.err("%r is not supported in this ISA" % t.text, t)
            self.consume_type()
            nstars = self.parse_stars()
            name = self.eat("ID")
            if self.at("("):
                p.funcs.append(self.parse_function_after_header(name, nstars))
            elif self.at("[") or self.at(";") or self.at("="):
                p.globals.append(self.parse_global_after_header(name, nstars))
            else:
                self.err("expected '(' for function or one of ';', '=', '[' for global",
                         self.peek())
        return p

    def _parse_array_dims(self):
        """Parse one or more `[CONST]` dimensions, e.g. [10] or [2][3]."""
        dims = []
        while self.at("["):
            self.eat("[")
            sz = self.eat("INT")
            d = int_literal_value(sz)
            if d <= 0:
                self.err("array size must be positive", sz)
            dims.append(d)
            self.eat("]")
        return dims

    def parse_global_after_header(self, name_tok, nstars):
        decl = VarDecl(line=name_tok.line, col=name_tok.col,
                       source_line=name_tok.source_line, name=name_tok.text)
        dims = []
        if self.at("["):
            dims = self._parse_array_dims()
            if self.at("="):
                self.err("array initializers are not supported (use a loop)", self.peek())
            self.eat(";")
        elif self.at("="):
            self.eat("=")
            decl.init = self.parse_expr()
            if not isinstance(decl.init, IntLit):
                self.err("global initializer must be a constant integer literal", self.peek())
            self.eat(";")
        else:
            self.eat(";")
        decl.ctype = build_type(nstars, dims)
        decl.is_array = decl.ctype.is_array()
        return decl

    def parse_function_after_header(self, name_tok, nstars):
        func = Func(line=name_tok.line, col=name_tok.col,
                    source_line=name_tok.source_line, name=name_tok.text)
        func.ret_type = build_type(nstars, [])
        self.eat("(")
        if not self.at(")"):
            while True:
                self.consume_type()
                pstars = self.parse_stars()
                p = self.eat("ID")
                pdims = self._parse_array_dims() if self.at("[") else []
                # an array parameter decays to a pointer (C semantics)
                ptype = build_type(pstars, pdims).decay()
                func.params.append((p.text, ptype, p))
                if not self.at(","):
                    break
                self.eat(",")
        self.eat(")")
        if self.at(";"):
            self.err("forward declarations are not supported; define the function in place",
                     self.peek())
        func.body = self.parse_block()
        return func

    def parse_block(self):
        opening = self.eat("{")
        b = Block(line=opening.line, col=opening.col, source_line=opening.source_line)
        while not self.at("}"):
            if self.at("EOF"):
                self.err("unexpected end of file inside block", self.peek())
            b.stmts.append(self.parse_stmt())
        self.eat("}")
        return b

    def parse_stmt(self):
        t = self.peek()
        if self.at(";"):                       # empty statement, e.g. `while(c);`
            self.eat(";")
            return Block(line=t.line, col=t.col, source_line=t.source_line, stmts=[])
        if t.kind == "KW" and t.text == "int":
            return self.parse_local_decl()
        if t.kind == "KW":
            if t.text == "if":
                return self.parse_if()
            if t.text == "while":
                return self.parse_while()
            if t.text == "do":
                return self.parse_do_while()
            if t.text == "for":
                return self.parse_for()
            if t.text == "switch":
                return self.parse_switch()
            if t.text in ("case", "default"):
                self.err("'%s' may only appear inside a switch" % t.text, t)
            if t.text == "return":
                return self.parse_return()
            if t.text == "break":
                self.pos += 1; self.eat(";")
                return Break(line=t.line, col=t.col, source_line=t.source_line)
            if t.text == "continue":
                self.pos += 1; self.eat(";")
                return Continue(line=t.line, col=t.col, source_line=t.source_line)
            self.err("unsupported keyword %r" % t.text, t)
        if self.at("{"):
            return self.parse_block()
        e = self.parse_expr()
        self.eat(";")
        return ExprStmt(line=t.line, col=t.col, source_line=t.source_line, expr=e)

    def parse_local_decl(self):
        self.consume_type()
        nstars = self.parse_stars()
        name = self.eat("ID")
        decl = VarDecl(line=name.line, col=name.col, source_line=name.source_line,
                       name=name.text)
        dims = []
        if self.at("["):
            dims = self._parse_array_dims()
            if self.at("="):
                self.err("local array initializers are not supported (use a loop)", self.peek())
            self.eat(";")
            decl.ctype = build_type(nstars, dims)
            decl.is_array = decl.ctype.is_array()
            return decl
        if self.at("="):
            self.eat("=")
            decl.init = self.parse_expr()
        self.eat(";")
        decl.ctype = build_type(nstars, dims)
        decl.is_array = decl.ctype.is_array()
        return decl

    def parse_if(self):
        kw = self.eat("if"); self.eat("(")
        cond = self.parse_expr(); self.eat(")")
        then = self.parse_stmt()
        else_ = None
        if self.at("else"):
            self.eat("else"); else_ = self.parse_stmt()
        return If(line=kw.line, col=kw.col, source_line=kw.source_line,
                  cond=cond, then=then, else_=else_)

    def parse_while(self):
        kw = self.eat("while"); self.eat("(")
        cond = self.parse_expr(); self.eat(")")
        body = self.parse_stmt()
        return While(line=kw.line, col=kw.col, source_line=kw.source_line, cond=cond, body=body)

    def parse_do_while(self):
        kw = self.eat("do")
        body = self.parse_stmt()
        self.eat("while"); self.eat("(")
        cond = self.parse_expr()
        self.eat(")"); self.eat(";")
        return DoWhile(line=kw.line, col=kw.col, source_line=kw.source_line,
                       cond=cond, body=body)

    def parse_switch(self):
        kw = self.eat("switch"); self.eat("(")
        expr = self.parse_expr(); self.eat(")")
        self.eat("{")
        items = []
        seen = set()
        have_default = False
        while not self.at("}"):
            if self.at("EOF"):
                self.err("unexpected end of file inside switch", self.peek())
            if self.at("case"):
                ct = self.eat("case")
                ce = self.parse_expr()
                if not isinstance(ce, IntLit):
                    self.err("case label must be a constant integer literal", ct)
                if ce.value in seen:
                    self.err("duplicate case label %d" % ce.value, ct)
                seen.add(ce.value)
                self.eat(":")
                items.append(Case(line=ct.line, col=ct.col,
                                  source_line=ct.source_line, value=ce.value))
            elif self.at("default"):
                dt = self.eat("default")
                if have_default:
                    self.err("a switch may have at most one default label", dt)
                have_default = True
                self.eat(":")
                items.append(Default(line=dt.line, col=dt.col, source_line=dt.source_line))
            else:
                items.append(self.parse_stmt())
        self.eat("}")
        return Switch(line=kw.line, col=kw.col, source_line=kw.source_line,
                      expr=expr, items=items)

    def parse_for(self):
        kw = self.eat("for"); self.eat("(")
        init = None
        if not self.at(";"):
            if self.peek().kind == "KW" and self.peek().text == "int":
                init = self.parse_local_decl()
            else:
                e = self.parse_expr(); self.eat(";")
                init = ExprStmt(line=e.line, col=e.col, source_line=e.source_line, expr=e)
        else:
            self.eat(";")
        cond = None
        if not self.at(";"):
            cond = self.parse_expr()
        self.eat(";")
        update = None
        if not self.at(")"):
            update = self.parse_expr()
        self.eat(")")
        body = self.parse_stmt()
        return For(line=kw.line, col=kw.col, source_line=kw.source_line,
                   init=init, cond=cond, update=update, body=body)

    def parse_return(self):
        kw = self.eat("return")
        v = None
        if not self.at(";"):
            v = self.parse_expr()
        self.eat(";")
        return Return(line=kw.line, col=kw.col, source_line=kw.source_line, value=v)

    _ASSIGN_OPS = {"=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>="}

    def parse_expr(self):
        return self.parse_assign()

    @staticmethod
    def _is_lvalue(n):
        return isinstance(n, (VarRef, Index)) or (isinstance(n, Unary) and n.op == "*")

    def parse_assign(self):
        lhs = self.parse_logor()
        if self.peek().text in self._ASSIGN_OPS:
            opt = self.peek(); self.pos += 1
            rhs = self.parse_assign()
            if not self._is_lvalue(lhs):
                self.err("left side of assignment must be a variable, array element, "
                         "or pointer dereference", opt)
            return Assign(line=opt.line, col=opt.col, source_line=opt.source_line,
                          op=opt.text, target=lhs, value=rhs)
        return lhs

    def _left_assoc(self, sub, ops):
        n = sub()
        while self.peek().text in ops:
            t = self.peek(); self.pos += 1
            n = Binary(line=t.line, col=t.col, source_line=t.source_line,
                       op=t.text, lhs=n, rhs=sub())
        return n

    def parse_logor(self):  return self._left_assoc(self.parse_logand, {"||"})
    def parse_logand(self): return self._left_assoc(self.parse_bitor,  {"&&"})
    def parse_bitor(self):  return self._left_assoc(self.parse_bitxor, {"|"})
    def parse_bitxor(self): return self._left_assoc(self.parse_bitand, {"^"})
    def parse_bitand(self): return self._left_assoc(self.parse_eq,     {"&"})
    def parse_eq(self):     return self._left_assoc(self.parse_rel,    {"==", "!="})
    def parse_rel(self):    return self._left_assoc(self.parse_shift,  {"<", "<=", ">", ">="})
    def parse_shift(self):  return self._left_assoc(self.parse_add,    {"<<", ">>"})
    def parse_add(self):    return self._left_assoc(self.parse_mul,    {"+", "-"})
    def parse_mul(self):    return self._left_assoc(self.parse_unary,  {"*", "/", "%"})

    def parse_unary(self):
        t = self.peek()
        if t.text in ("-", "!", "~", "+"):
            self.pos += 1
            operand = self.parse_unary()
            if t.text == "+":
                return operand
            if t.text == "-" and isinstance(operand, IntLit):
                return IntLit(line=t.line, col=t.col, source_line=t.source_line,
                              value=-operand.value)
            return Unary(line=t.line, col=t.col, source_line=t.source_line,
                         op=t.text, operand=operand)
        if t.text in ("++", "--"):
            self.pos += 1
            operand = self.parse_unary()
            if not self._is_lvalue(operand):
                self.err("'%s' must apply to a variable, array element, or *pointer" % t.text, t)
            op = "+=" if t.text == "++" else "-="
            return Assign(line=t.line, col=t.col, source_line=t.source_line,
                          op=op, target=operand,
                          value=IntLit(line=t.line, col=t.col, source_line=t.source_line, value=1))
        if t.text == "*":          # pointer dereference
            self.pos += 1
            return Unary(line=t.line, col=t.col, source_line=t.source_line,
                         op="*", operand=self.parse_unary())
        if t.text == "&":          # address-of
            self.pos += 1
            return Unary(line=t.line, col=t.col, source_line=t.source_line,
                         op="&", operand=self.parse_unary())
        return self.parse_postfix()

    def parse_postfix(self):
        n = self.parse_primary()
        while True:
            if self.at("["):
                lb = self.eat("[")
                idx = self.parse_expr()
                self.eat("]")
                n = Index(line=lb.line, col=lb.col, source_line=lb.source_line, array=n, idx=idx)
            elif self.peek().text in ("++", "--"):
                t = self.peek(); self.pos += 1
                if not self._is_lvalue(n):
                    self.err("'%s' must apply to a variable, array element, or *pointer" % t.text, t)
                n = PostIncDec(line=t.line, col=t.col, source_line=t.source_line,
                               op=t.text, target=n)
            else:
                return n

    def parse_primary(self):
        t = self.peek()
        if t.kind == "INT":
            self.pos += 1
            return IntLit(line=t.line, col=t.col, source_line=t.source_line,
                          value=int_literal_value(t))
        if t.kind == "STRING":
            self.pos += 1
            return StrLit(line=t.line, col=t.col, source_line=t.source_line,
                          value=decode_str_literal(t, self.filename), raw=t.text)
        if t.kind == "KW" and t.text == "tid":
            self.pos += 1                            # GPU builtin: this thread's id
            return VarRef(line=t.line, col=t.col, source_line=t.source_line, name="tid")
        if t.kind == "ID":
            self.pos += 1
            if self.at("("):
                self.eat("(")
                args = []
                if not self.at(")"):
                    while True:
                        args.append(self.parse_expr())
                        if not self.at(","):
                            break
                        self.eat(",")
                self.eat(")")
                return Call(line=t.line, col=t.col, source_line=t.source_line,
                            name=t.text, args=args)
            return VarRef(line=t.line, col=t.col, source_line=t.source_line, name=t.text)
        if self.at("("):
            self.eat("("); e = self.parse_expr(); self.eat(")")
            return e
        self.err("unexpected token %r in expression" % t.text, t)


def int_literal_value(tok):
    s = tok.text.lower()
    if s.startswith("0x"):
        return int(s, 16)
    if s.startswith("0b"):
        return int(s, 2)
    return int(s, 10)


_STR_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "0": "\0",
                "\\": "\\", '"': '"', "'": "'"}


def decode_str_literal(tok, filename):
    """Turn the raw "..." source text into its character value, resolving the
    handful of escapes a scanf format might use."""
    raw = tok.text[1:-1]            # strip the surrounding quotes
    out = []
    i = 0
    while i < len(raw):
        c = raw[i]
        if c == "\\":
            i += 1
            esc = raw[i] if i < len(raw) else ""
            if esc not in _STR_ESCAPES:
                raise CompileError("unsupported escape %r in string literal" % ("\\" + esc),
                                   filename, tok.line, tok.col, tok.source_line)
            out.append(_STR_ESCAPES[esc])
        else:
            out.append(c)
        i += 1
    return "".join(out)


def _prod(xs):
    p = 1
    for x in xs:
        p *= x
    return p


# ====================================================================
# Semantic check + symbol table
# ====================================================================

class GlobalSym(object):
    def __init__(self, name, ctype, init, label):
        self.name = name
        self.ctype = ctype
        self.is_array = ctype.is_array()
        self.init = init
        self.label = label


class FuncSym(object):
    def __init__(self, name, nparams, ret_type):
        self.name = name
        self.nparams = nparams
        self.ret_type = ret_type


class SymTable(object):
    def __init__(self):
        self.globals = {}
        self.funcs = {}


RESERVED_NAMES = {"print", "scanf", "setdata", "getdata"}


def check_program(prog, filename):
    syms = SymTable()
    for g in prog.globals:
        if g.name in RESERVED_NAMES:
            raise CompileError("%r is a reserved built-in name; pick a different identifier"
                               % g.name, filename, g.line, g.col, g.source_line, len(g.name))
        if g.name in syms.globals:
            raise CompileError("duplicate global %r" % g.name,
                               filename, g.line, g.col, g.source_line, len(g.name))
        init = (g.init.value & 0xFFFFFFFF) if g.init is not None else 0
        syms.globals[g.name] = GlobalSym(g.name, g.ctype, init,
                                         label="__g_%s" % g.name)
    for f in prog.funcs:
        if f.name in RESERVED_NAMES:
            raise CompileError("%r is a reserved built-in name; pick a different identifier"
                               % f.name, filename, f.line, f.col, f.source_line, len(f.name))
        if f.name in syms.funcs:
            raise CompileError("duplicate function %r" % f.name,
                               filename, f.line, f.col, f.source_line, len(f.name))
        syms.funcs[f.name] = FuncSym(f.name, len(f.params), f.ret_type)
    if "main" not in syms.funcs:
        raise CompileError("program must define a `main` function", filename, 1, 0, "", 1)
    return syms


# ====================================================================
# Code generator
# ====================================================================

ARG_REGS = ["a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7"]


class CodeGen(object):
    def __init__(self, prog, syms, filename, mem_top=65536):
        self.prog = prog
        self.syms = syms
        self.filename = filename
        self.mem_top = mem_top
        self.out = io.StringIO()
        self.label_counter = 0
        self.cur_func = None
        self.locals = {}          # name -> byte offset from s0 (negative)
        self.localtypes = {}      # name -> CType (locals and params)
        self.frame_size = 0
        self.break_stack = []      # innermost break target (loop OR switch)
        self.continue_stack = []   # innermost continue target (loops only)
        self.needs_divmod = False
        self.needs_print = False
        self.needs_scan = False

    def w(self, s=""):
        self.out.write(s + "\n")

    def label(self, prefix):
        self.label_counter += 1
        return "__L_%s_%d" % (prefix, self.label_counter)

    def _flabel(self, name):
        # Mangle user function names so a function named like a register
        # (e.g. `s8`, `a0`, `t3`) can't collide with a register in the asm.
        return "fn_" + name

    # ---- entry point ----

    def emit_program(self):
        self.w("# ---- generated by compiler.py (RV32I + M mul) ----")
        self.w("# entry: set up sp, call main, then halt with main's result in a0.")
        self.w("_start:")
        self.w("    li   sp, %d" % self.mem_top)
        self.w("    call fn_main")
        self.w("    ebreak")
        self.w("")

        for f in self.prog.funcs:
            self.emit_function(f)

        # runtime helpers (only what the program actually uses)
        if self.needs_divmod or self.needs_print:
            self.w(_UDIVMOD_ASM)
        if self.needs_divmod:
            self.w(_DIVMOD_ASM)
        if self.needs_print:
            self.w(_PRINT_INT_ASM)
        if self.needs_scan:
            self.w(_GETC_ASM)
            self.w(_READ_INT_ASM)

        if self.prog.globals or self.needs_scan:
            self.w("# ---- globals ----")
            if self.needs_scan:
                self.w("__inq:")
                self.w("    .word -2        # scanf one-char pushback (-2 = empty)")
            for g in self.prog.globals:
                sym = self.syms.globals[g.name]
                self.w("%s:" % sym.label)
                if sym.is_array:
                    self.w("    .word " + ", ".join("0" for _ in range(sym.ctype.size() // 4)))
                else:
                    self.w("    .word %d" % to_s32_literal(sym.init))
            self.w("")
        return self.out.getvalue()

    # ---- per-function emission ----

    def emit_function(self, f):
        self.cur_func = f
        self.locals = {}
        self.localtypes = {}

        # Collect params then locals, as (name, CType).
        decls = [(name, ctype) for (name, ctype, _tok) in f.params]
        seen = set()
        for (n, _) in decls:
            if n in seen:
                raise CompileError("duplicate parameter %r" % n,
                                   self.filename, f.line, f.col, f.source_line, len(n))
            seen.add(n)
        self._collect_locals(f.body, decls)

        # Frame layout (high to low addresses), s0 = caller's sp:
        #   s0 - 4   saved ra
        #   s0 - 8   saved s0 (caller's frame pointer)
        #   s0 - 12  first named value, then downward toward sp.
        # Element 0 of an array/aggregate sits at the lowest address of its
        # block, so a[i] = &a[0] + i*elem_size.
        off = -12
        total_bytes = 0
        for (name, ctype) in decls:
            sz = ctype.size()
            base = off - (sz - 4)
            self.locals[name] = base
            self.localtypes[name] = ctype
            off = base - 4
            total_bytes += sz
        self.frame_size = 8 + total_bytes
        FRAME = self.frame_size

        self.w("# ---- function %s(%s) ----"
               % (f.name, ", ".join(n for (n, _, _) in f.params)))
        self.w("%s:" % self._flabel(f.name))
        # Set up the frame. Done so it works for any frame size (a big local
        # array can make FRAME exceed the 12-bit immediate range); ra and the
        # saved frame pointer always live at the small fixed offsets -4(s0)/-8(s0).
        self._addsp(-FRAME)
        self.w("    mv   t0, s0              # hold caller's frame pointer")
        self._addr("s0", "sp", FRAME, "s0 = frame pointer (caller's sp)")
        self.w("    sw   ra, -4(s0)")
        self.w("    sw   t0, -8(s0)          # saved caller's frame pointer")
        for i, (pname, _ptype, _tok) in enumerate(f.params):
            if i < 8:
                self._st(ARG_REGS[i], self.locals[pname], "s0",
                         "spill param %s (in %s)" % (pname, ARG_REGS[i]))
            else:
                # 9th+ args arrive on the stack the caller set up: at s0+0, s0+4, ...
                self._ld("t0", (i - 8) * 4, "s0", "incoming stack arg %s" % pname)
                self._st("t0", self.locals[pname], "s0", "spill param %s" % pname)
        self.w("")

        self.emit_block(f.body)

        self.w("__end_%s:" % f.name)
        self.w("    li   a0, 0               # default return value")
        self._emit_epilogue()

    def _collect_locals(self, node, decls):
        """Append every declared local as (name, is_array, size) to `decls`,
        checking for duplicates (locals are function-scoped: no block scoping)."""
        if node is None:
            return
        if isinstance(node, Block):
            for s in node.stmts:
                self._collect_locals(s, decls)
        elif isinstance(node, VarDecl):
            if any(n == node.name for (n, _) in decls):
                raise CompileError("variable %r already declared in this function" % node.name,
                                   self.filename, node.line, node.col, node.source_line, len(node.name))
            decls.append((node.name, node.ctype))
        elif isinstance(node, If):
            self._collect_locals(node.then, decls)
            if node.else_ is not None:
                self._collect_locals(node.else_, decls)
        elif isinstance(node, (While, DoWhile)):
            self._collect_locals(node.body, decls)
        elif isinstance(node, For):
            if node.init is not None:
                self._collect_locals(node.init, decls)
            self._collect_locals(node.body, decls)
        elif isinstance(node, Switch):
            for it in node.items:
                if not isinstance(it, (Case, Default)):
                    self._collect_locals(it, decls)

    def _emit_epilogue(self):
        # At every epilogue the stack machine is balanced, so sp is at the
        # frame base and s0 = caller's sp.
        self.w("    lw   ra, -4(s0)")
        self.w("    mv   sp, s0              # free the frame")
        self.w("    lw   s0, -8(s0)          # restore caller's frame pointer")
        self.w("    ret")
        self.w("")

    # ---- statements ----

    def emit_block(self, b):
        for s in b.stmts:
            self.emit_stmt(s)

    def emit_stmt(self, s):
        if isinstance(s, Block):
            self.emit_block(s); return
        if isinstance(s, VarDecl):
            if s.ctype.is_array():
                return   # frame space reserved; C local arrays start uninitialised
            offset = self.locals[s.name]
            if s.init is not None:
                self.emit_expr(s.init); self._pop("t0")
                self._st("t0", offset, "s0", "init %s" % s.name)
            else:
                self._st("zero", offset, "s0", "init %s = 0" % s.name)
            return
        if isinstance(s, If):
            self.emit_expr(s.cond); self._pop("t0")
            else_l = self.label("else"); end_l = self.label("endif")
            self.w("    beqz t0, %s" % else_l)
            self.emit_stmt(s.then)
            self.w("    j    %s" % end_l)
            self.w("%s:" % else_l)
            if s.else_ is not None:
                self.emit_stmt(s.else_)
            self.w("%s:" % end_l)
            return
        if isinstance(s, While):
            top = self.label("while_top"); end = self.label("while_end")
            self.w("%s:" % top)
            self.emit_expr(s.cond); self._pop("t0")
            self.w("    beqz t0, %s" % end)
            self.break_stack.append(end); self.continue_stack.append(top)
            self.emit_stmt(s.body)
            self.break_stack.pop(); self.continue_stack.pop()
            self.w("    j    %s" % top)
            self.w("%s:" % end)
            return
        if isinstance(s, DoWhile):
            top = self.label("do_top"); cont = self.label("do_cont"); end = self.label("do_end")
            self.w("%s:" % top)
            self.break_stack.append(end); self.continue_stack.append(cont)
            self.emit_stmt(s.body)
            self.break_stack.pop(); self.continue_stack.pop()
            self.w("%s:" % cont)
            self.emit_expr(s.cond); self._pop("t0")
            self.w("    bnez t0, %s" % top)
            self.w("%s:" % end)
            return
        if isinstance(s, For):
            if s.init is not None:
                self.emit_stmt(s.init)
            top = self.label("for_top"); cont = self.label("for_cont"); end = self.label("for_end")
            self.w("%s:" % top)
            if s.cond is not None:
                self.emit_expr(s.cond); self._pop("t0")
                self.w("    beqz t0, %s" % end)
            self.break_stack.append(end); self.continue_stack.append(cont)
            self.emit_stmt(s.body)
            self.break_stack.pop(); self.continue_stack.pop()
            self.w("%s:" % cont)
            if s.update is not None:
                self.emit_expr(s.update); self._pop("t0")
            self.w("    j    %s" % top)
            self.w("%s:" % end)
            return
        if isinstance(s, Switch):
            self.emit_switch(s)
            return
        if isinstance(s, Return):
            if s.value is not None:
                self.emit_expr(s.value); self._pop("t0")
                self.w("    mv   a0, t0")
            else:
                self.w("    li   a0, 0")
            self._emit_epilogue()
            return
        if isinstance(s, Break):
            if not self.break_stack:
                raise CompileError("`break` outside of a loop or switch",
                                   self.filename, s.line, s.col, s.source_line, 5)
            self.w("    j    %s" % self.break_stack[-1])
            return
        if isinstance(s, Continue):
            if not self.continue_stack:
                raise CompileError("`continue` outside of a loop",
                                   self.filename, s.line, s.col, s.source_line, 8)
            self.w("    j    %s" % self.continue_stack[-1])
            return
        if isinstance(s, ExprStmt):
            self.emit_expr(s.expr); self._pop("t0")
            return
        raise CompileError("unhandled statement %s" % type(s).__name__,
                           self.filename, s.line, s.col, s.source_line)

    def emit_switch(self, s):
        # Evaluate the controlling expression into t0 (it survives the whole
        # comparison ladder: only t1 is clobbered by each `li`).  Then compare
        # against every case constant and jump to the matching label; fall
        # through to default (or the end) if nothing matches.  `break` exits
        # the switch; `continue` is NOT caught here, so it reaches the
        # enclosing loop (standard C behaviour).
        end = self.label("switch_end")
        labels = []
        default_label = None
        for it in s.items:
            if isinstance(it, Case):
                labels.append(self.label("case"))
            elif isinstance(it, Default):
                default_label = self.label("default")
                labels.append(default_label)
            else:
                labels.append(None)

        self.emit_expr(s.expr); self._pop("t0")
        for it, lab in zip(s.items, labels):
            if isinstance(it, Case):
                self.w("    li   t1, %d" % to_s32_literal(it.value))
                self.w("    beq  t0, t1, %s" % lab)
        self.w("    j    %s" % (default_label if default_label else end))

        self.break_stack.append(end)
        for it, lab in zip(s.items, labels):
            if isinstance(it, (Case, Default)):
                self.w("%s:" % lab)
            else:
                self.emit_stmt(it)
        self.break_stack.pop()
        self.w("%s:" % end)

    # ---- type queries (static analysis; emit no code) ----

    def _vartype(self, name):
        if name in self.localtypes:
            return self.localtypes[name]
        if name in self.syms.globals:
            return self.syms.globals[name].ctype
        if name == "tid":
            return CType.int_()          # GPU builtin: this thread's id (read-only)
        return None

    def obj_type(self, e):
        """The OBJECT (lvalue) type of e -- not decayed. e must be an lvalue."""
        if isinstance(e, VarRef):
            t = self._vartype(e.name)
            if t is None:
                raise CompileError("unknown name %r" % e.name,
                                   self.filename, e.line, e.col, e.source_line, len(e.name))
            return t
        if isinstance(e, Index):
            base = self.typeof(e.array)
            if not base.is_ptr():
                raise CompileError("cannot index a value that is not an array or pointer",
                                   self.filename, e.line, e.col, e.source_line)
            return base.pointee
        if isinstance(e, Unary) and e.op == "*":
            base = self.typeof(e.operand)
            if not base.is_ptr():
                raise CompileError("cannot dereference a value that is not a pointer",
                                   self.filename, e.line, e.col, e.source_line)
            return base.pointee
        raise CompileError("expression is not an lvalue (it has no address)",
                           self.filename, e.line, e.col, e.source_line)

    def typeof(self, e):
        """The VALUE (rvalue) type of e, with array-to-pointer decay applied."""
        if isinstance(e, IntLit):
            return CType.int_()
        if isinstance(e, (VarRef, Index)) or (isinstance(e, Unary) and e.op == "*"):
            return self.obj_type(e).decay()
        if isinstance(e, Unary):
            if e.op == "&":
                return CType.ptr(self.obj_type(e.operand))
            return CType.int_()                       # - ~ !
        if isinstance(e, Binary):
            if e.op in ("+", "-"):
                lt = self.typeof(e.lhs); rt = self.typeof(e.rhs)
                if lt.is_ptr() and rt.is_ptr():
                    return CType.int_()               # ptr - ptr -> int
                if lt.is_ptr():
                    return lt
                if rt.is_ptr():
                    return rt
            return CType.int_()
        if isinstance(e, Assign):
            return self.typeof(e.target)
        if isinstance(e, PostIncDec):
            return self.typeof(e.target)
        if isinstance(e, Call):
            if e.name in ("print", "scanf", "setdata", "getdata"):
                return CType.int_()
            fn = self.syms.funcs.get(e.name)
            return fn.ret_type if fn is not None else CType.int_()
        return CType.int_()

    def _array_count(self, e):
        """First-dimension length if e is an array lvalue, else None (for bounds checks)."""
        if isinstance(e, (VarRef, Index)) or (isinstance(e, Unary) and e.op == "*"):
            try:
                ot = self.obj_type(e)
            except CompileError:
                return None
            if ot.is_array():
                return ot.count
        return None

    def _scale_reg(self, reg, size):
        """reg = reg * size  (size is a compile-time constant)."""
        if size == 1:
            return
        if (size & (size - 1)) == 0:
            self.w("    slli %s, %s, %d          # * %d" % (reg, reg, size.bit_length() - 1, size))
        else:
            self.w("    li   t2, %d" % size)
            self.w("    mul  %s, %s, t2          # * %d" % (reg, reg, size))

    def _div_by_size(self, reg, size):
        """reg = reg / size, exact signed division (for pointer differences)."""
        if size == 1:
            return
        if (size & (size - 1)) == 0:
            self.w("    srai %s, %s, %d          # / %d" % (reg, reg, size.bit_length() - 1, size))
        else:
            self.needs_divmod = True
            self.w("    mv   a0, %s" % reg)
            self.w("    li   a1, %d" % size)
            self.w("    call __divmod            # / %d (pointer difference)" % size)
            self.w("    mv   %s, a0" % reg)

    # ---- expressions (stack machine; the rvalue is left on the runtime stack) ----

    def emit_expr(self, e):
        if isinstance(e, IntLit):
            self.w("    li   t0, %d" % to_s32_literal(e.value)); self._push("t0"); return
        if isinstance(e, StrLit):
            raise CompileError('a string literal is only allowed as the scanf format, '
                               'e.g. scanf("%d", &x)',
                               self.filename, e.line, e.col, e.source_line, len(e.raw))
        if isinstance(e, VarRef):
            if e.name == "tid":
                # GPU builtin (a keyword, so it can't be shadowed): emit rdtid
                # into t0 and push it, exactly like an integer literal.
                self.w("    rdtid t0                 # builtin: this thread's id")
                self._push("t0"); return
            if self.obj_type(e).is_array():
                self.emit_lvalue_addr(e); return          # array decays to its address
            if e.name in self.localtypes:
                self._ld("t0", self.locals[e.name], "s0", "read %s" % e.name)
            else:
                sym = self.syms.globals[e.name]
                self.w("    la   t1, %s" % sym.label)
                self.w("    lw   t0, 0(t1)           # load global %s" % e.name)
            self._push("t0"); return
        if isinstance(e, Index):
            elem_is_array = self.obj_type(e).is_array()
            self.emit_lvalue_addr(e)                      # &element -> stack
            if elem_is_array:
                return                                    # element is itself an array -> decays
            self._pop("t1"); self.w("    lw   t0, 0(t1)           # load element"); self._push("t0")
            return
        if isinstance(e, Unary):
            if e.op == "&":
                self.emit_lvalue_addr(e.operand); return
            if e.op == "*":
                pointee_is_array = self.obj_type(e).is_array()
                self.emit_expr(e.operand)                 # pointer value = the address
                if pointee_is_array:
                    return                                # *p is an array -> decays
                self._pop("t1"); self.w("    lw   t0, 0(t1)           # deref *"); self._push("t0")
                return
            self.emit_expr(e.operand); self._pop("t0")
            if e.op == "-":   self.w("    neg  t0, t0")
            elif e.op == "~": self.w("    not  t0, t0")
            elif e.op == "!": self.w("    seqz t0, t0")
            else:
                raise CompileError("unsupported unary %r" % e.op,
                                   self.filename, e.line, e.col, e.source_line)
            self._push("t0"); return
        if isinstance(e, Binary): self.emit_binop(e); return
        if isinstance(e, Call): self.emit_call(e); return
        if isinstance(e, Assign): self.emit_assign(e); return
        if isinstance(e, PostIncDec): self.emit_postincdec(e); return
        raise CompileError("unhandled expression %s" % type(e).__name__,
                           self.filename, e.line, e.col, e.source_line)

    def emit_lvalue_addr(self, e):
        """Leave the ADDRESS of lvalue e on the runtime stack."""
        if isinstance(e, VarRef):
            if e.name in self.localtypes:
                self._addr("t0", "s0", self.locals[e.name], "&%s" % e.name)
                self._push("t0"); return
            if e.name in self.syms.globals:
                self.w("    la   t0, %s          # &%s"
                       % (self.syms.globals[e.name].label, e.name))
                self._push("t0"); return
            raise CompileError("unknown name %r" % e.name,
                               self.filename, e.line, e.col, e.source_line, len(e.name))
        if isinstance(e, Unary) and e.op == "*":
            self.emit_expr(e.operand); return             # &*p == p (the pointer value is the address)
        if isinstance(e, Index):
            base_t = self.typeof(e.array)                 # decayed -> must be a pointer
            if not base_t.is_ptr():
                raise CompileError("cannot index a value that is not an array or pointer",
                                   self.filename, e.line, e.col, e.source_line)
            elem_size = base_t.pointee.size()
            n = self._array_count(e.array)                # constant-index bounds check
            if n is not None and isinstance(e.idx, IntLit) and not (0 <= e.idx.value < n):
                raise CompileError(
                    "index %d is out of bounds (array size %d; valid 0..%d)"
                    % (e.idx.value, n, n - 1),
                    self.filename, e.line, e.col, e.source_line)
            self.emit_expr(e.array)                       # base address (array decays / pointer value)
            self.emit_expr(e.idx)                         # index
            self._pop("t1"); self._pop("t0")
            self._scale_reg("t1", elem_size)
            self.w("    add  t0, t0, t1           # &element = base + index*%d" % elem_size)
            self._push("t0"); return
        raise CompileError("expression is not assignable (it has no address)",
                           self.filename, e.line, e.col, e.source_line)

    def emit_postincdec(self, e):
        """x++ / x-- : leave the OLD value as the result, then store the stepped
        value back. Works for any lvalue (variable, a[i], *p). For a pointer the
        step is the pointee size (C pointer arithmetic); for an int it is 1.
        Prefix ++/-- is handled via the compound-assignment path, which is also
        pointer-aware, and yields the NEW value."""
        vt = self.typeof(e.target)
        if vt.is_array():
            raise CompileError("cannot apply ++/-- to an array",
                               self.filename, e.line, e.col, e.source_line)
        step = vt.pointee.size() if vt.is_ptr() else 1
        if e.op == "--":
            step = -step
        self.emit_lvalue_addr(e.target); self._pop("t1")   # address of the target
        self.w("    lw   t0, 0(t1)           # postfix %s: load old value" % e.op)
        self._push("t0")                                   # result = the OLD value
        if -2048 <= step <= 2047:
            self.w("    addi t0, t0, %d" % step)
        else:
            self.w("    li   t2, %d" % step); self.w("    add  t0, t0, t2")
        self.w("    sw   t0, 0(t1)           # store stepped value")

    def emit_binop(self, e):
        if e.op == "&&":
            self.emit_expr(e.lhs); self._pop("t0")
            false_l = self.label("and_false"); end = self.label("and_end")
            self.w("    beqz t0, %s" % false_l)
            self.emit_expr(e.rhs); self._pop("t0")
            self.w("    snez t0, t0")
            self.w("    j    %s" % end)
            self.w("%s:" % false_l)
            self.w("    li   t0, 0")
            self.w("%s:" % end)
            self._push("t0"); return
        if e.op == "||":
            self.emit_expr(e.lhs); self._pop("t0")
            true_l = self.label("or_true"); end = self.label("or_end")
            self.w("    bnez t0, %s" % true_l)
            self.emit_expr(e.rhs); self._pop("t0")
            self.w("    snez t0, t0")
            self.w("    j    %s" % end)
            self.w("%s:" % true_l)
            self.w("    li   t0, 1")
            self.w("%s:" % end)
            self._push("t0"); return

        # pointer arithmetic: scale the integer side by the pointee size, and
        # reduce a pointer difference back to an element count.
        if e.op in ("+", "-"):
            lt = self.typeof(e.lhs); rt = self.typeof(e.rhs)
            if lt.is_ptr() or rt.is_ptr():
                self.emit_expr(e.lhs); self.emit_expr(e.rhs)
                self._pop("t1"); self._pop("t0")          # t1 = rhs, t0 = lhs
                if e.op == "+":
                    if lt.is_ptr() and rt.is_ptr():
                        raise CompileError("cannot add two pointers",
                                           self.filename, e.line, e.col, e.source_line)
                    if lt.is_ptr():
                        self._scale_reg("t1", lt.pointee.size())
                    else:
                        self._scale_reg("t0", rt.pointee.size())
                    self.w("    add  t0, t0, t1")
                else:  # '-'
                    if lt.is_ptr() and rt.is_ptr():
                        self.w("    sub  t0, t0, t1           # pointer difference (bytes)")
                        self._div_by_size("t0", lt.pointee.size())
                    elif lt.is_ptr():
                        self._scale_reg("t1", lt.pointee.size())
                        self.w("    sub  t0, t0, t1")
                    else:
                        raise CompileError("cannot subtract a pointer from an integer",
                                           self.filename, e.line, e.col, e.source_line)
                self._push("t0"); return

        self.emit_expr(e.lhs)
        self.emit_expr(e.rhs)
        self._pop("t1")        # rhs
        self._pop("t0")        # lhs
        simple = {"+": "add", "-": "sub", "&": "and", "|": "or", "^": "xor",
                  "<<": "sll", ">>": "sra", "*": "mul"}
        if e.op in simple:
            self.w("    %-4s t0, t0, t1" % simple[e.op])
        elif e.op == "/":
            self.needs_divmod = True
            self.w("    mv   a0, t0"); self.w("    mv   a1, t1")
            self.w("    call __divmod            # t0 = lhs / rhs")
            self.w("    mv   t0, a0")
        elif e.op == "%":
            self.needs_divmod = True
            self.w("    mv   a0, t0"); self.w("    mv   a1, t1")
            self.w("    call __divmod            # t0 = lhs %% rhs")
            self.w("    mv   t0, a1")
        elif e.op == "==":
            self.w("    sub  t0, t0, t1"); self.w("    seqz t0, t0")
        elif e.op == "!=":
            self.w("    sub  t0, t0, t1"); self.w("    snez t0, t0")
        elif e.op == "<":
            self.w("    slt  t0, t0, t1")
        elif e.op == ">":
            self.w("    slt  t0, t1, t0")
        elif e.op == "<=":
            self.w("    slt  t0, t1, t0"); self.w("    xori t0, t0, 1")
        elif e.op == ">=":
            self.w("    slt  t0, t0, t1"); self.w("    xori t0, t0, 1")
        else:
            raise CompileError("unsupported operator %r" % e.op,
                               self.filename, e.line, e.col, e.source_line)
        self._push("t0")

    def _parse_scanf_format(self, fmt, node):
        """Turn a scanf format string into a list of directives, resolved at
        compile time:  ('conv', 'd'|'u') | ('ws',) | ('lit', char).
        Consecutive whitespace collapses into one ('ws',) (matches zero+ input
        whitespace, exactly like C)."""
        ops = []
        i = 0
        while i < len(fmt):
            c = fmt[i]
            if c == "%":
                i += 1
                if i >= len(fmt):
                    raise CompileError("scanf format ends with a lone '%'",
                                       self.filename, node.line, node.col, node.source_line)
                spec = fmt[i]
                if spec == "%":
                    ops.append(("lit", "%"))
                elif spec in ("d", "u"):
                    ops.append(("conv", spec))
                else:
                    raise CompileError("unsupported scanf conversion '%%%s' "
                                       "(only %%d and %%u are supported)" % spec,
                                       self.filename, node.line, node.col, node.source_line)
            elif c.isspace():
                if not ops or ops[-1][0] != "ws":
                    ops.append(("ws",))
            else:
                ops.append(("lit", c))
            i += 1
        return ops

    def emit_scanf(self, e):
        """scanf("...fmt...", &a, &b, ...) -> reads decimals from input.

        The format is a compile-time literal, so we UNROLL it into a sequence
        of calls to the one-byte runtime helpers (__read_int / __skip_ws /
        __getc / __ungetc) -- there is no runtime format interpreter and no
        string ever exists at runtime. Returns, in the expression value, the
        number of items successfully read (0..n), or -1 (EOF) if end-of-input
        is hit before the first conversion -- matching C's scanf."""
        if not e.args or not isinstance(e.args[0], StrLit):
            raise CompileError('scanf\'s first argument must be a string-literal '
                               'format, e.g. scanf("%d", &x)',
                               self.filename, e.line, e.col, e.source_line, len(e.name))
        ops = self._parse_scanf_format(e.args[0].value, e.args[0])
        nconv = sum(1 for o in ops if o[0] == "conv")
        ptr_args = e.args[1:]
        if len(ptr_args) != nconv:
            raise CompileError("scanf format has %d conversion(s) but %d argument(s) "
                               "were given" % (nconv, len(ptr_args)),
                               self.filename, e.line, e.col, e.source_line, len(e.name))
        for a in ptr_args:
            if not self.typeof(a).is_ptr():
                raise CompileError("scanf needs a pointer to store into (e.g. &x); "
                                   "this argument is not a pointer",
                                   self.filename, a.line, a.col, a.source_line)
        self.needs_scan = True
        base = self.label("scan")
        fail, done = base + "_fail", base + "_done"
        self.w("    addi sp, sp, -4          # scanf: matched-count slot")
        self.w("    sw   zero, 0(sp)")
        ci = 0
        for k, op in enumerate(ops):
            if op[0] == "conv":
                self.w("    call __read_int          # %%%s" % op[1])
                self.w("    blez a1, %s" % fail)     # status <= 0 -> stop
                self._push("a0")                      # save the read value
                self.emit_expr(ptr_args[ci])          # destination address
                self._pop("t1")                       # addr
                self._pop("t0")                       # value
                self.w("    sw   t0, 0(t1)           # *arg = value")
                self.w("    lw   t0, 0(sp)")
                self.w("    addi t0, t0, 1")
                self.w("    sw   t0, 0(sp)          # matched++")
                ci += 1
            elif op[0] == "ws":
                self.w("    call __skip_ws           # match optional whitespace")
            else:  # ('lit', ch) -- match a literal input character
                ch = op[1]
                ok = "%s_lit%d" % (base, k)
                self.w("    call __getc")
                self.w("    li   t0, %d" % ord(ch))
                self.w("    beq  a0, t0, %s" % ok)
                self.w("    call __ungetc           # push the mismatch back")
                self.w("    li   a1, 0")
                self.w("    li   t0, -1")
                self.w("    bne  a0, t0, %s" % fail) # not EOF -> match failure (a1=0)
                self.w("    li   a1, -1             # EOF before the literal matched")
                self.w("    j    %s" % fail)
                self.w("%s:" % ok)
        self.w("    lw   t0, 0(sp)          # all directives matched -> count")
        self.w("    j    %s" % done)
        self.w("%s:" % fail)
        self.w("    lw   t0, 0(sp)")
        self.w("    bnez t0, %s" % done)     # something matched -> return the count
        self.w("    mv   t0, a1             # nothing matched -> 0 (bad char) or -1 (EOF)")
        self.w("%s:" % done)
        self.w("    addi sp, sp, 4          # drop the count slot")
        self._push("t0")

    def emit_call(self, e):
        if e.name == "print":
            if len(e.args) != 1:
                raise CompileError("print() takes exactly 1 argument, got %d" % len(e.args),
                                   self.filename, e.line, e.col, e.source_line, len(e.name))
            self.needs_print = True
            self.emit_expr(e.args[0]); self._pop("t0")
            self.w("    mv   a0, t0")
            self.w("    call __print_int        # magic print: a0 as decimal + newline")
            self.w("    li   t0, 0")            # print() is void; push a dummy value
            self._push("t0")
            return
        if e.name == "scanf":
            self.emit_scanf(e)
            return
        if e.name == "setdata":
            # setdata(index, value): write one cell of the shared data memory.
            if len(e.args) != 2:
                raise CompileError("setdata() takes exactly 2 arguments "
                                   "(index, value), got %d" % len(e.args),
                                   self.filename, e.line, e.col, e.source_line, len(e.name))
            self.emit_expr(e.args[0])          # index -> stack
            self.emit_expr(e.args[1])          # value -> stack (on top)
            self._pop("t1")                    # value  (setdt rs2)
            self._pop("t0")                    # index  (setdt rs1)
            self.w("    setdt t0, t1             # data[index] = value")
            self.w("    li   t0, 0")            # setdata is void; push a dummy value
            self._push("t0")
            return
        if e.name == "getdata":
            # getdata(index): read one cell of the shared data memory.
            if len(e.args) != 1:
                raise CompileError("getdata() takes exactly 1 argument "
                                   "(index), got %d" % len(e.args),
                                   self.filename, e.line, e.col, e.source_line, len(e.name))
            self.emit_expr(e.args[0])          # index -> stack
            self._pop("t0")
            self.w("    getdt t0, t0             # t0 = data[index]")
            self._push("t0")
            return
        if e.name not in self.syms.funcs:
            raise CompileError("unknown function %r" % e.name,
                               self.filename, e.line, e.col, e.source_line, len(e.name))
        fn = self.syms.funcs[e.name]
        if len(e.args) != fn.nparams:
            raise CompileError("function %r expects %d arg(s), got %d"
                               % (e.name, fn.nparams, len(e.args)),
                               self.filename, e.line, e.col, e.source_line, len(e.name))
        nargs = len(e.args)
        nreg = min(nargs, 8)
        nstk = nargs - nreg
        # Args 9.. are passed on the stack. Push them in REVERSE index order so
        # arg #8 lands at the lowest address (0(sp) at the call) -- the callee
        # reads them as 0(s0), 4(s0), ...  These stay on the stack across the call.
        for i in range(nargs - 1, 7, -1):
            self.emit_expr(e.args[i])
        # Args 0..7 go in a0..a7. Evaluate them now (after the stack args, which may
        # contain nested calls) and load the registers in the pop loop right before
        # the call, so nothing clobbers a0..a7 between here and the jump.
        for i in range(nreg):
            self.emit_expr(e.args[i])
        for i in reversed(range(nreg)):
            self._pop(ARG_REGS[i])
        self.w("    call %s" % self._flabel(e.name))
        if nstk:
            self._addsp(4 * nstk, "reclaim %d stack-passed arg(s)" % nstk)
        self._push("a0")

    def emit_assign(self, e):
        if self.obj_type(e.target).is_array():
            raise CompileError("cannot assign to an array",
                               self.filename, e.line, e.col, e.source_line)
        # Compute the value to store. Compound assignment reuses the binop, which
        # is pointer-aware, so `p += n` scales n by the pointee size.
        if e.op == "=":
            self.emit_expr(e.value)
        else:
            self.emit_expr(Binary(line=e.line, col=e.col, source_line=e.source_line,
                                  op=e.op[:-1], lhs=e.target, rhs=e.value))
        tgt = e.target
        # fast path: a scalar/pointer variable
        if isinstance(tgt, VarRef):
            self._pop("t0")
            if tgt.name in self.localtypes:
                self._st("t0", self.locals[tgt.name], "s0", "assign %s" % tgt.name)
            elif tgt.name in self.syms.globals:
                self.w("    la   t1, %s" % self.syms.globals[tgt.name].label)
                self.w("    sw   t0, 0(t1)           # store global %s" % tgt.name)
            else:
                raise CompileError("unknown name %r" % tgt.name,
                                   self.filename, e.line, e.col, e.source_line, len(tgt.name))
            self._push("t0"); return
        # general lvalue: an array element a[i]...  or a dereference *p
        self.emit_lvalue_addr(tgt)                # address pushed above the value
        self._pop("t1"); self._pop("t0")          # t1 = address, t0 = value
        self.w("    sw   t0, 0(t1)           # store")
        self._push("t0")

    # ---- frame access, safe for offsets beyond the 12-bit immediate range ----
    # A large local frame (e.g. a big local array) can push a frame-pointer
    # offset outside [-2048, 2047]. addi/lw/sw can't encode that, so we
    # materialize the offset in a register and use a 0-offset access instead.

    @staticmethod
    def _fits12(off):
        return -2048 <= off <= 2047

    def _ld(self, dest, off, base="s0", comment=""):
        """dest = MEM[base + off]  (dest doubles as scratch for a large offset)."""
        c = ("          # " + comment) if comment else ""
        if self._fits12(off):
            self.w("    lw   %s, %d(%s)%s" % (dest, off, base, c))
        else:
            self.w("    li   %s, %d" % (dest, off))
            self.w("    add  %s, %s, %s" % (dest, dest, base))
            self.w("    lw   %s, 0(%s)%s" % (dest, dest, c))

    def _st(self, src, off, base="s0", comment=""):
        """MEM[base + off] = src  (uses t3 to hold the address for a large offset)."""
        c = ("          # " + comment) if comment else ""
        if self._fits12(off):
            self.w("    sw   %s, %d(%s)%s" % (src, off, base, c))
        else:
            self.w("    li   t3, %d" % off)
            self.w("    add  t3, t3, %s" % base)
            self.w("    sw   %s, 0(t3)%s" % (src, c))

    def _addr(self, dest, base, off, comment=""):
        """dest = base + off  (dest must differ from base; safe for large off)."""
        c = ("          # " + comment) if comment else ""
        if self._fits12(off):
            self.w("    addi %s, %s, %d%s" % (dest, base, off, c))
        else:
            self.w("    li   %s, %d" % (dest, off))
            self.w("    add  %s, %s, %s%s" % (dest, dest, base, c))

    def _addsp(self, delta, comment=""):
        """sp += delta  (uses t0 as scratch for a large delta)."""
        c = ("          # " + comment) if comment else ""
        if self._fits12(delta):
            self.w("    addi sp, sp, %d%s" % (delta, c))
        else:
            self.w("    li   t0, %d" % delta)
            self.w("    add  sp, sp, t0%s" % c)

    # ---- stack-machine helpers ----

    def _push(self, reg):
        self.w("    push %s" % reg)

    def _pop(self, reg):
        self.w("    pop  %s" % reg)


def to_s32_literal(value):
    v = value & 0xFFFFFFFF
    return v - (1 << 32) if v & (1 << 31) else v


# ====================================================================
# Runtime helper routines (emitted only when used)
# ====================================================================

# Unsigned 32-bit divide/modulo by shift-subtract long division.
#   in:  a0 = dividend, a1 = divisor      out: a0 = quotient, a1 = remainder
#   leaf (calls nothing); clobbers t0..t5, a0..a1; preserves s-registers.
#   Divide-by-zero returns quotient = 0xFFFFFFFF, remainder = dividend
#   (matching the RISC-V M-extension convention, done here in software).
_UDIVMOD_ASM = """\
# ---- runtime: unsigned divmod ----
__udivmod:
    mv   t0, a0              # t0 = dividend
    mv   t1, a1              # t1 = divisor
    bne  t1, zero, __udm_nz
    li   a0, -1
    mv   a1, t0
    ret
__udm_nz:
    li   t2, 0               # quotient
    li   t3, 0               # remainder
    li   t4, 31              # bit index
__udm_loop:
    slli t3, t3, 1
    srl  t5, t0, t4
    andi t5, t5, 1
    or   t3, t3, t5          # r = (r<<1) | bit i of dividend
    bltu t3, t1, __udm_skip
    sub  t3, t3, t1          # r -= divisor
    li   t5, 1
    sll  t5, t5, t4
    or   t2, t2, t5          # set bit i of quotient
__udm_skip:
    addi t4, t4, -1
    bgez t4, __udm_loop
    mv   a0, t2
    mv   a1, t3
    ret
"""

# Signed divmod with C99 semantics (quotient truncates toward zero; remainder
# takes the dividend's sign). Built on __udivmod.
#   in:  a0 = dividend, a1 = divisor      out: a0 = quotient, a1 = remainder
_DIVMOD_ASM = """\
# ---- runtime: signed divmod (C truncate-toward-zero) ----
__divmod:
    addi sp, sp, -12
    sw   ra, 8(sp)
    sw   s0, 4(sp)
    srai t0, a0, 31          # n sign mask (-1 if dividend < 0)
    srai t1, a1, 31          # d sign mask
    xor  s0, t0, t1          # quotient sign mask (survives the call)
    sw   t0, 0(sp)           # save dividend's sign mask (for the remainder)
    xor  a0, a0, t0
    sub  a0, a0, t0          # |dividend|
    xor  a1, a1, t1
    sub  a1, a1, t1          # |divisor|
    call __udivmod
    lw   t0, 0(sp)
    xor  a0, a0, s0
    sub  a0, a0, s0          # apply quotient sign
    xor  a1, a1, t0
    sub  a1, a1, t0          # apply remainder sign (= dividend's)
    lw   s0, 4(sp)
    lw   ra, 8(sp)
    addi sp, sp, 12
    ret
"""

# print(x): emit x as a signed decimal followed by a newline, one character at
# a time via ecall. Uses unsigned divmod on the magnitude so INT_MIN prints
# correctly. Persistent loop state lives in callee-saved s0/s1 (preserved
# across the __udivmod call).
_PRINT_INT_ASM = """\
# ---- runtime: print signed decimal + newline ----
__print_int:
    addi sp, sp, -12
    sw   ra, 8(sp)
    sw   s0, 4(sp)
    sw   s1, 0(sp)
    li   a7, 0              # ecall service 0 = putchar (scanf may have left a7=1)
    mv   s0, a0              # value
    bgez s0, __pi_pos
    li   a0, 45             # '-'
    ecall
    sub  s0, zero, s0       # magnitude (INT_MIN stays 0x80000000 -> unsigned 2^31)
__pi_pos:
    li   s1, 0              # digit count
__pi_div:
    mv   a0, s0
    li   a1, 10
    call __udivmod          # a0 = value/10, a1 = value%10
    addi a1, a1, 48         # remainder digit -> ASCII
    addi sp, sp, -4
    sw   a1, 0(sp)          # push digit char
    addi s1, s1, 1
    mv   s0, a0
    bnez s0, __pi_div
__pi_out:
    beqz s1, __pi_done
    lw   a0, 0(sp)
    addi sp, sp, 4
    ecall                   # putchar digit
    addi s1, s1, -1
    j    __pi_out
__pi_done:
    li   a0, 10             # '\\n'
    ecall
    lw   s1, 0(sp)
    lw   s0, 4(sp)
    lw   ra, 8(sp)
    addi sp, sp, 12
    ret
"""

# One-byte input with a single-character pushback buffer (__inq). getchar is
# ecall service 1; __ungetc lets a reader peek one char past what it consumes
# (e.g. the non-digit that ends a number) without losing it.
_GETC_ASM = """\
# ---- runtime: buffered one-byte input ----
__getc:
    la   t0, __inq
    lw   a0, 0(t0)
    li   t1, -2
    beq  a0, t1, __getc_fresh   # buffer empty -> read a fresh byte
    sw   t1, 0(t0)              # consume the pushed-back char (mark empty)
    ret
__getc_fresh:
    li   a7, 1                  # ecall service 1 = getchar
    ecall                       # a0 <- next input byte, or -1 at EOF
    ret
__ungetc:
    la   t0, __inq
    sw   a0, 0(t0)             # next __getc returns this char
    ret
__skip_ws:
    addi sp, sp, -4
    sw   ra, 0(sp)
__sw_loop:
    call __getc
    li   t0, -1
    beq  a0, t0, __sw_done      # EOF -> stop (push it back, stays sticky)
    li   t0, 32                 # ' '
    beq  a0, t0, __sw_loop
    addi t0, a0, -9             # tab/nl/vt/ff/cr are 9..13
    li   t1, 4
    bgeu t1, t0, __sw_loop
__sw_done:
    call __ungetc              # restore the first non-whitespace char
    lw   ra, 0(sp)
    addi sp, sp, 4
    ret
"""

# Read one decimal integer: skip whitespace, optional +/- sign, accumulate
# digits mod 2^32 (so %d and %u store the same 32 bits), and push back the
# first non-digit. Returns value in a0 and a status in a1:
#   1 = ok,  0 = no digits (a non-digit char),  -1 = EOF before any digit.
_READ_INT_ASM = """\
# ---- runtime: read a signed/unsigned decimal integer ----
__read_int:
    addi sp, sp, -16
    sw   ra, 12(sp)
    sw   s0, 8(sp)
    sw   s1, 4(sp)
    sw   s2, 0(sp)
    li   s0, 0              # accumulator
    li   s1, 0              # sign flag (1 = negative)
    li   s2, 0              # digit count
__ri_ws:
    call __getc
    li   t0, -1
    beq  a0, t0, __ri_eof
    li   t0, 32
    beq  a0, t0, __ri_ws
    addi t0, a0, -9
    li   t1, 4
    bgeu t1, t0, __ri_ws    # 9..13 are whitespace
    li   t0, 43             # '+'
    beq  a0, t0, __ri_next
    li   t0, 45             # '-'
    bne  a0, t0, __ri_loop
    li   s1, 1
__ri_next:
    call __getc            # first char after the sign
__ri_loop:
    li   t0, 48            # '0'
    blt  a0, t0, __ri_end
    li   t0, 57            # '9'
    bgt  a0, t0, __ri_end
    slli t0, s0, 3         # accumulator * 10 = *8 + *2
    slli t1, s0, 1
    add  s0, t0, t1
    addi t0, a0, -48       # + this digit
    add  s0, s0, t0
    addi s2, s2, 1
    call __getc
    j    __ri_loop
__ri_end:
    call __ungetc          # push back the non-digit terminator
    beqz s2, __ri_nodig
    beqz s1, __ri_pos
    sub  s0, zero, s0      # apply the sign (mod 2^32)
__ri_pos:
    mv   a0, s0
    li   a1, 1
    j    __ri_ret
__ri_nodig:
    li   a0, 0
    li   a1, 0
    j    __ri_ret
__ri_eof:
    call __ungetc          # push EOF back (a0 == -1) so it stays sticky
    li   a0, 0
    li   a1, -1
__ri_ret:
    lw   s2, 0(sp)
    lw   s1, 4(sp)
    lw   s0, 8(sp)
    lw   ra, 12(sp)
    addi sp, sp, 16
    ret
"""


# ====================================================================
# Driver
# ====================================================================

def compile_source(source, filename, mem_top=65536):
    toks = tokenize(source, filename)
    prog = Parser(toks, filename).parse_program()
    syms = check_program(prog, filename)
    return CodeGen(prog, syms, filename, mem_top=mem_top).emit_program()


def main(argv=None):
    ap = argparse.ArgumentParser(description="Compile a tiny C subset to RV32I+M assembly.")
    ap.add_argument("input", help="input .c file")
    ap.add_argument("-o", "--output", default=None, help="output .asm (default: input with .asm)")
    ap.add_argument("--mem-size", type=int, default=65536,
                    help="memory size; _start sets sp to this (default 65536)")
    args = ap.parse_args(argv)
    with open(args.input) as f:
        source = f.read()
    try:
        asm = compile_source(source, filename=args.input, mem_top=args.mem_size)
    except CompileError as e:
        print(e.render(), file=sys.stderr)
        sys.exit(1)
    out_path = args.output or os.path.splitext(args.input)[0] + ".asm"
    with open(out_path, "w") as f:
        f.write(asm)
    print("wrote %s" % out_path)


if __name__ == "__main__":
    main()
