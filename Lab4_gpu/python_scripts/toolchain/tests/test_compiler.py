"""End-to-end compiler tests: compile a C program, assemble, simulate, and
assert on main's return value (a0) and/or printed output. Plus the negative
path: programs that must be rejected with a specific message."""

import io
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import compiler
import assembler
import simulator
from simulator import to_s32


def build_and_run(c_source, mem_size=1 << 16, max_cycles=5_000_000,
                  return_output=False, stdin=""):
    """Compile -> assemble -> simulate. Returns a0 (u32) at halt, or
    (a0_u32, captured output) when return_output=True. `stdin` feeds the
    getchar service (scanf)."""
    asm = compiler.compile_source(c_source, "<test>", mem_top=mem_size)
    words = assembler.assemble(asm)
    cpu = simulator.CPU(mem_size=mem_size, output=io.StringIO(),
                        input=io.StringIO(stdin))
    for i, w in enumerate(words):
        cpu.mem[i * 4:i * 4 + 4] = w.to_bytes(4, "little")
    n = len(words) * 4
    cpu.code_end_addr = n
    cpu.initialised[0:n] = b"\x01" * n
    simulator.run(cpu, max_cycles=max_cycles)
    a0 = cpu.regs[10]
    if return_output:
        return a0, cpu.output.getvalue()
    return a0


class TestPositive(unittest.TestCase):
    def test_constant_return(self):
        self.assertEqual(build_and_run("int main(){ return 42; }"), 42)

    def test_arithmetic_precedence(self):
        self.assertEqual(build_and_run("int main(){ return 3 + 4 * 5; }"), 23)

    def test_signed_negative(self):
        self.assertEqual(build_and_run("int main(){ return -7; }"), 0xFFFFFFF9)

    def test_if_else(self):
        self.assertEqual(build_and_run(
            "int main(){ int x=10; if(x>5) return 1; else return 0; }"), 1)

    def test_while_sum(self):
        self.assertEqual(build_and_run(
            "int main(){ int s=0; int i=1; while(i<=10){ s=s+i; i=i+1; } return s; }"), 55)

    def test_for_loop(self):
        self.assertEqual(build_and_run(
            "int main(){ int s=0; for(int i=0;i<5;i++) s=s+i; return s; }"), 10)

    def test_function_call(self):
        self.assertEqual(build_and_run(
            "int add(int a,int b){ return a+b; } int main(){ return add(20,22); }"), 42)

    def test_recursion_fib(self):
        self.assertEqual(build_and_run(
            "int fib(int n){ if(n<2) return n; return fib(n-1)+fib(n-2); } "
            "int main(){ return fib(10); }"), 55)

    def test_recursion_factorial(self):
        self.assertEqual(build_and_run(
            "int fact(int n){ if(n<=1) return 1; return n*fact(n-1); } "
            "int main(){ return fact(5); }"), 120)

    def test_global_array(self):
        # Note: locals are function-scoped (no block scoping yet), so we
        # declare the loop variable once and reuse it across both loops.
        self.assertEqual(build_and_run(
            "int data[5]; int main(){ int i; int s; "
            "for(i=0;i<5;i++) data[i]=(i+1)*10; "
            "s=0; for(i=0;i<5;i++) s=s+data[i]; return s; }"), 150)

    def test_global_scalar(self):
        self.assertEqual(build_and_run(
            "int counter=0; int bump(){ counter=counter+1; return counter; } "
            "int main(){ bump(); bump(); bump(); return counter; }"), 3)

    def test_multiplication(self):
        self.assertEqual(build_and_run("int main(){ int a=6; int b=7; return a*b; }"), 42)

    def test_eight_params(self):
        self.assertEqual(build_and_run(
            "int s8(int a,int b,int c,int d,int e,int f,int g,int h){ "
            "return a+b+c+d+e+f+g+h; } "
            "int main(){ return s8(1,2,3,4,5,6,7,8); }"), 36)

    # ---- Change B: / and % are SUPPORTED via the software routine ----
    def test_division_positive(self):
        self.assertEqual(build_and_run("int main(){ return 17/5; }"), 3)
        self.assertEqual(build_and_run("int main(){ return 100/7; }"), 14)

    def test_modulo_positive(self):
        self.assertEqual(build_and_run("int main(){ return 17%5; }"), 2)
        self.assertEqual(build_and_run("int main(){ return 100%7; }"), 2)

    def test_signed_division_truncates_toward_zero(self):
        self.assertEqual(to_s32(build_and_run("int main(){ return (0-17)/5; }")), -3)
        self.assertEqual(to_s32(build_and_run("int main(){ return 17/(0-5); }")), -3)
        self.assertEqual(to_s32(build_and_run("int main(){ return (0-17)/(0-5); }")), 3)

    def test_signed_modulo_sign_of_dividend(self):
        self.assertEqual(to_s32(build_and_run("int main(){ return (0-17)%5; }")), -2)
        self.assertEqual(to_s32(build_and_run("int main(){ return 17%(0-5); }")), 2)

    def test_div_assign(self):
        self.assertEqual(build_and_run("int main(){ int x=100; x/=7; return x; }"), 14)
        self.assertEqual(build_and_run("int main(){ int x=100; x%=7; return x; }"), 2)

    def test_signed_lt_no_overflow(self):
        self.assertEqual(build_and_run(
            "int main(){ int n=0x80000000; int p=0x7FFFFFFF; if(n<p) return 1; return 0; }"), 1)

    def test_signed_le_ge_no_overflow(self):
        self.assertEqual(build_and_run(
            "int main(){ int a=0x80000000; int b=0x7FFFFFFF; int s=0; "
            "if(a<=b) s=s+1; if(b>=a) s=s+1; if(a>=b) s=s+0; return s; }"), 2)

    def test_array_store_with_comparison_index(self):
        self.assertEqual(build_and_run(
            "int arr[3]; int main(){ int i=1; int j=5; arr[i<j]=99; arr[i>=j]=11; "
            "return arr[0]+arr[1]; }"), 110)

    # ---- local arrays (newly supported on real RISC-V) ----
    def test_local_array(self):
        self.assertEqual(build_and_run(
            "int main(){ int a[5]; int i; int s; "
            "for(i=0;i<5;i++) a[i]=i*i; "
            "s=0; for(i=0;i<5;i++) s=s+a[i]; return s; }"), 30)  # 0+1+4+9+16

    def test_local_array_among_scalars(self):
        # Scalars on both sides of the array must keep their own slots.
        self.assertEqual(build_and_run(
            "int main(){ int x=100; int a[3]; int y=7; "
            "a[0]=1; a[1]=2; a[2]=3; return x + a[0]+a[1]+a[2] + y; }"), 113)

    def test_local_array_in_function(self):
        self.assertEqual(build_and_run(
            "int work(){ int b[4]; int i; for(i=0;i<4;i++) b[i]=i+1; "
            "return b[0]+b[1]+b[2]+b[3]; } int main(){ return work(); }"), 10)

    # ---- Change A: print ----
    def test_print_basic(self):
        a0, out = build_and_run("int main(){ print(7); print(-3); return 0; }", return_output=True)
        self.assertEqual(a0, 0)
        self.assertEqual(out, "7\n-3\n")

    def test_print_in_loop(self):
        _, out = build_and_run(
            "int main(){ for(int i=1;i<=3;i++) print(i*i); return 0; }", return_output=True)
        self.assertEqual(out, "1\n4\n9\n")

    def test_print_zero_and_div(self):
        _, out = build_and_run(
            "int main(){ print(0); print(100/7); print(100%7); return 0; }", return_output=True)
        self.assertEqual(out, "0\n14\n2\n")


class TestControlFlow(unittest.TestCase):
    def test_while_and_for(self):
        self.assertEqual(build_and_run(
            "int main(){ int s=0; int i=0; while(i<5){ s=s+i; i++; } return s; }"), 10)
        self.assertEqual(build_and_run(
            "int main(){ int s=0; int i; for(i=0;i<5;i++) s=s+i; return s; }"), 10)

    def test_do_while_runs_body_once(self):
        # condition false on entry, but the body still runs once
        self.assertEqual(build_and_run(
            "int main(){ int n=0; int c=0; do { c=c+1; } while(n>0); return c; }"), 1)

    def test_do_while_counts(self):
        self.assertEqual(build_and_run(
            "int main(){ int i=0; int s=0; do { s=s+i; i=i+1; } while(i<5); return s; }"), 10)

    def test_break_in_loop(self):
        self.assertEqual(build_and_run(
            "int main(){ int i=0; while(1){ if(i==3) break; i=i+1; } return i; }"), 3)

    def test_continue_in_loop(self):
        # sum the even numbers in 0..9
        self.assertEqual(build_and_run(
            "int main(){ int s=0; int i; for(i=0;i<10;i++){ if(i%2==1) continue; s=s+i; } return s; }"), 20)

    def test_switch_dispatch(self):
        self.assertEqual(build_and_run(
            "int classify(int x){ switch(x){ case 1: return 100; case 2: return 200; "
            "default: return 999; } return -1; } int main(){ return classify(2); }"), 200)

    def test_switch_default(self):
        self.assertEqual(build_and_run(
            "int f(int x){ switch(x){ case 1: return 1; default: return 42; } return 0; } "
            "int main(){ return f(7); }"), 42)

    def test_switch_fallthrough(self):
        # case 1 has no break, so it falls into case 2; case 2 breaks.
        self.assertEqual(build_and_run(
            "int main(){ int r=0; int x=1; switch(x){ case 1: r=r+1; case 2: r=r+10; break; "
            "case 3: r=r+100; } return r; }"), 11)

    def test_switch_break_exits_only_switch(self):
        # break leaves the switch; the enclosing for loop keeps going.
        self.assertEqual(build_and_run(
            "int main(){ int s=0; int i; for(i=0;i<4;i++){ switch(i){ case 2: break; "
            "default: s=s+i; } s=s+100; } return s; }"), 404)

    def test_continue_in_switch_continues_loop(self):
        # continue inside a switch continues the enclosing loop (skips s+=100).
        self.assertEqual(build_and_run(
            "int main(){ int s=0; int i; for(i=0;i<4;i++){ switch(i){ case 2: continue; "
            "default: s=s+1; } s=s+100; } return s; }"), 303)


class TestIncDecAndEmpty(unittest.TestCase):
    # Regressions for two bugs the gcc-differential stress test surfaced.
    def test_postfix_returns_old_value(self):
        self.assertEqual(build_and_run(
            "int main(){ int x=5; int y; y=x++; return y*100 + x; }"), 506)   # y=5, x=6

    def test_postfix_decrement(self):
        self.assertEqual(build_and_run(
            "int main(){ int x=5; int y; y=x--; return y*100 + x; }"), 504)   # y=5, x=4

    def test_postfix_in_expression(self):
        self.assertEqual(build_and_run(
            "int main(){ int x=3; int y; y = x++ + 10; return y*100 + x; }"), 1304)  # y=13, x=4

    def test_prefix_returns_new_value(self):
        self.assertEqual(build_and_run(
            "int main(){ int x=5; int y; y=++x; return y*100 + x; }"), 606)   # y=6, x=6

    def test_postfix_array_element(self):
        self.assertEqual(build_and_run(
            "int main(){ int a[2]; int x; a[0]=9; a[1]=0; x=a[0]++; return x*100 + a[0]; }"), 910)

    def test_postfix_in_index(self):
        self.assertEqual(build_and_run(
            "int main(){ int a[3]; int i; int v; a[0]=10;a[1]=20;a[2]=30; i=0; v=a[i++]; "
            "return v*100 + i; }"), 1001)  # v=a[0]=10, i=1

    def test_while_postdecrement_condition(self):
        self.assertEqual(build_and_run(
            "int main(){ int n=3; int c=0; while(n--) c++; return c*100 + (n+1); }"), 300)  # c=3, n=-1

    def test_empty_statement(self):
        self.assertEqual(build_and_run("int main(){ int i; i=5; ; return i; }"), 5)

    def test_empty_for_body(self):
        self.assertEqual(build_and_run(
            "int main(){ int i; for(i=0;i<10;i++) ; return i; }"), 10)

    def test_empty_while_body_with_sideeffect_cond(self):
        # while(i++ < 50);  -> i ends at 51
        self.assertEqual(build_and_run(
            "int main(){ int i; i=0; while(i++ < 50) ; return i; }"), 51)

    def test_switch_empty_default(self):
        self.assertEqual(build_and_run(
            "int main(){ int x=3; int r=0; switch(x){ case 1: r=1; break; default: ; } return r+x; }"), 3)

    def test_empty_then_branch_with_else(self):
        # `if(c) ; else ...` -- an empty then-branch is legal
        self.assertEqual(build_and_run(
            "int main(){ int a; a=3; if(a>0) ; else a=-1; return a; }"), 3)
        self.assertEqual(build_and_run(
            "int main(){ int a; a=-5; if(a>0) ; else a=-1; return a; }"), 0xFFFFFFFF)


class TestMultiDimAndManyParams(unittest.TestCase):
    def test_local_2d_array(self):
        self.assertEqual(build_and_run(
            "int main(){ int m[2][3]; int i; int j; "
            "for(i=0;i<2;i++) for(j=0;j<3;j++) m[i][j]=i*3+j; "
            "return m[1][2]; }"), 5)

    def test_global_2d_array_sum(self):
        # sum of (i+j) over a 3x3 grid = 18
        self.assertEqual(build_and_run(
            "int g[3][3]; int main(){ int i; int j; int s; s=0; "
            "for(i=0;i<3;i++) for(j=0;j<3;j++) g[i][j]=i+j; "
            "for(i=0;i<3;i++) for(j=0;j<3;j++) s=s+g[i][j]; return s; }"), 18)

    def test_3d_array(self):
        self.assertEqual(build_and_run(
            "int main(){ int c[2][2][2]; int i; int j; int k; int v; v=0; "
            "for(i=0;i<2;i++) for(j=0;j<2;j++) for(k=0;k<2;k++){ c[i][j][k]=v; v=v+1; } "
            "return c[1][1][1]; }"), 7)

    def test_ten_params(self):
        self.assertEqual(build_and_run(
            "int f(int a,int b,int c,int d,int e,int g,int h,int i,int j,int k){ "
            "return a+b+c+d+e+g+h+i+j+k; } "
            "int main(){ return f(1,2,3,4,5,6,7,8,9,10); }"), 55)

    def test_twelve_params_with_recursion(self):
        # 12-param function that recurses -- stresses stack-args + frame interplay
        self.assertEqual(build_and_run(
            "int f(int n,int a,int b,int c,int d,int e,int g,int h,int i,int j,int k,int l){ "
            "if(n==0) return a+b+c+d+e+g+h+i+j+k+l; "
            "return f(n-1,a,b,c,d,e,g,h,i,j,k,l); } "
            "int main(){ return f(3,1,1,1,1,1,1,1,1,1,1,1); }"), 11)

    def test_stack_arg_from_nested_call(self):
        # the 9th argument (first stack-passed) is itself a function call
        self.assertEqual(build_and_run(
            "int id(int x){ return x; } "
            "int f(int a,int b,int c,int d,int e,int g,int h,int i,int j){ return j; } "
            "int main(){ return f(1,2,3,4,5,6,7,8, id(99)); }"), 99)


class TestPointers(unittest.TestCase):
    def test_basic_deref(self):
        self.assertEqual(build_and_run(
            "int main(){ int x; int *p; x=41; p=&x; *p = *p + 1; return *p; }"), 42)

    def test_swap_by_reference(self):
        self.assertEqual(build_and_run(
            "int swap(int *a,int *b){ int t; t=*a; *a=*b; *b=t; return 0; } "
            "int main(){ int x; int y; x=3; y=7; swap(&x,&y); return x*10+y; }"), 73)

    def test_pointer_to_pointer(self):
        self.assertEqual(build_and_run(
            "int main(){ int x; int *p; int **pp; x=5; p=&x; pp=&p; **pp=99; return x; }"), 99)

    def test_triple_pointer(self):
        self.assertEqual(build_and_run(
            "int main(){ int x; int *p; int **q; int ***r; x=1; p=&x; q=&p; r=&q; "
            "***r=123; return x; }"), 123)

    def test_pointer_arithmetic(self):
        self.assertEqual(build_and_run(
            "int main(){ int a[5]; int *p; int i; for(i=0;i<5;i++) a[i]=i*i; p=a; "
            "return *(p+3); }"), 9)

    def test_pointer_difference(self):
        self.assertEqual(build_and_run(
            "int main(){ int a[10]; int *p; int *q; p=&a[2]; q=&a[7]; return q-p; }"), 5)

    def test_array_decays_to_param(self):
        self.assertEqual(build_and_run(
            "int sum(int *a,int n){ int s; int i; s=0; for(i=0;i<n;i++) s=s+a[i]; return s; } "
            "int main(){ int v[5]; int i; for(i=0;i<5;i++) v[i]=i+1; return sum(v,5); }"), 15)

    def test_ptr_walk_postincrement(self):
        self.assertEqual(build_and_run(
            "int main(){ int a[5]; int *p; int s; int i; for(i=0;i<5;i++) a[i]=i+1; "
            "p=a; s=0; for(i=0;i<5;i++){ s=s+*p; p++; } return s; }"), 15)

    def test_array_of_pointers(self):
        self.assertEqual(build_and_run(
            "int main(){ int x; int y; int z; int *arr[3]; x=1;y=2;z=3; "
            "arr[0]=&x; arr[1]=&y; arr[2]=&z; return *arr[0] + *arr[1]*10 + *arr[2]*100; }"), 321)

    def test_global_pointer(self):
        self.assertEqual(build_and_run(
            "int g; int *gp; int main(){ g=55; gp=&g; *gp = *gp + 1; return g; }"), 56)

    def test_ptr_to_2d_row(self):
        self.assertEqual(build_and_run(
            "int main(){ int m[3][3]; int i; int j; int *row; "
            "for(i=0;i<3;i++) for(j=0;j<3;j++) m[i][j]=i*3+j; row=m[1]; return row[2]; }"), 5)


class TestScanf(unittest.TestCase):
    def test_single_int(self):
        self.assertEqual(build_and_run(
            "int main(){ int x; scanf(\"%d\", &x); return x; }", stdin="42\n"), 42)

    def test_negative_int(self):
        self.assertEqual(build_and_run(
            "int main(){ int x; scanf(\"%d\", &x); return x; }", stdin="-9\n"),
            0xFFFFFFF7)

    def test_leading_whitespace_skipped(self):
        self.assertEqual(build_and_run(
            "int main(){ int x; scanf(\"%d\", &x); return x; }", stdin="   \t  7"), 7)

    def test_return_count_and_values(self):
        a0, out = build_and_run(
            "int main(){ int a; int b; int n; n=scanf(\"%d %d\",&a,&b);"
            " print(n); print(a); print(b); return 0; }",
            stdin="-7   12", return_output=True)
        self.assertEqual(out, "2\n-7\n12\n")

    def test_eof_returns_minus_one(self):
        # EOF before the first conversion -> scanf returns -1, like C.
        self.assertEqual(build_and_run(
            "int main(){ int x; return scanf(\"%d\", &x); }", stdin=""), 0xFFFFFFFF)

    def test_sum_until_eof(self):
        src = ("int main(){ int s; int x; s=0;"
               " while (scanf(\"%d\", &x) == 1) s = s + x;"
               " return s; }")
        self.assertEqual(build_and_run(src, stdin="1 2 3 4 5 6 7 8 9 10"), 55)

    def test_unsigned_wraps(self):
        # %u of -5 stores the same 32 bits as -5.
        self.assertEqual(build_and_run(
            "int main(){ int u; scanf(\"%u\", &u); return u; }", stdin="-5"),
            0xFFFFFFFB)

    def test_literal_char_in_format(self):
        a0, out = build_and_run(
            "int main(){ int a; int b; int n; n=scanf(\"%d,%d\",&a,&b);"
            " print(n); return a*b; }", stdin="12,34", return_output=True)
        self.assertEqual(out, "2\n")
        self.assertEqual(a0, 12 * 34)

    def test_partial_match_returns_count(self):
        # second conversion fails (non-numeric) -> count is 1, a keeps its value
        self.assertEqual(build_and_run(
            "int main(){ int a; int b; a=0; b=0;"
            " return scanf(\"%d %d\", &a, &b); }", stdin="5 x"), 1)

    def test_array_element_destination(self):
        src = ("int main(){ int arr[3]; int i; i=0;"
               " while (i<3){ scanf(\"%d\", &arr[i]); i=i+1; }"
               " return arr[0]+arr[1]+arr[2]; }")
        self.assertEqual(build_and_run(src, stdin="100 200 300"), 600)

    def test_pointer_variable_destination(self):
        src = ("int main(){ int x; int *p; p=&x; scanf(\"%d\", p); return x; }")
        self.assertEqual(build_and_run(src, stdin="123"), 123)

    def test_print_works_after_scanf(self):
        # __print_int must reset a7 to 0 so output still works after a read.
        a0, out = build_and_run(
            "int main(){ int x; scanf(\"%d\", &x); print(x); return 0; }",
            stdin="88", return_output=True)
        self.assertEqual(out, "88\n")


class TestNegative(unittest.TestCase):
    def assertRejects(self, src, msg_substring):
        with self.assertRaises(compiler.CompileError) as ctx:
            compiler.compile_source(src, "<test>")
        self.assertIn(msg_substring, ctx.exception.msg)

    def test_float_type(self):
        self.assertRejects("float main(){ return 0; }", "only 'int'")

    def test_struct_keyword(self):
        self.assertRejects("struct S { int x; }; int main(){ return 0; }", "'struct'")

    def test_deref_non_pointer(self):
        self.assertRejects("int main(){ int x; x=5; return *x; }", "not a pointer")

    def test_local_array_bounds(self):
        self.assertRejects("int main(){ int a[3]; return a[5]; }", "out of bounds")

    def test_overindex_reaches_scalar(self):
        # a[1] is an int; indexing it again has nothing to index
        self.assertRejects("int a[6]; int main(){ return a[1][2]; }", "not an array or pointer")

    def test_no_main(self):
        self.assertRejects("int foo(){ return 0; }", "main")

    def test_print_wrong_arity(self):
        self.assertRejects("int main(){ print(1,2); return 0; }", "exactly 1 argument")

    def test_array_bounds_constant_index(self):
        self.assertRejects("int arr[5]; int main(){ return arr[10]; }", "out of bounds")
        self.assertRejects("int arr[5]; int main(){ return arr[-1]; }", "out of bounds")

    def test_cant_define_print(self):
        self.assertRejects("int print(int x){ return x; } int main(){ return 0; }",
                           "reserved built-in name")

    def test_scanf_needs_pointer(self):
        self.assertRejects("int main(){ int x; scanf(\"%d\", x); return 0; }",
                           "needs a pointer")

    def test_scanf_unknown_conversion(self):
        self.assertRejects("int main(){ int x; scanf(\"%f\", &x); return 0; }",
                           "unsupported scanf conversion")

    def test_scanf_format_must_be_literal(self):
        self.assertRejects("int main(){ int x; int f; scanf(f, &x); return 0; }",
                           "must be a string-literal format")

    def test_scanf_arity_mismatch(self):
        self.assertRejects("int main(){ int x; int y; scanf(\"%d\", &x, &y); return 0; }",
                           "1 conversion(s) but 2 argument(s)")

    def test_string_literal_outside_scanf(self):
        self.assertRejects("int main(){ int x; x = \"hi\"; return 0; }",
                           "only allowed as the scanf format")

    def test_cant_define_scanf(self):
        self.assertRejects("int scanf(int x){ return x; } int main(){ return 0; }",
                           "reserved built-in name")


if __name__ == "__main__":
    unittest.main()
