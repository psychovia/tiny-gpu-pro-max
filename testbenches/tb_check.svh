// tb_check.svh
// Shared self-checking scaffolding for the tiny-gpu testbenches.
//
// Include this inside a testbench module. It declares two module-scope
// counters (tb_checks / tb_fails) and macros that accumulate into them, so a
// test can make hundreds of assertions and still produce one PASS/FAIL line
// plus a nonzero exit status on failure.
//
// Why macros and not tasks: every interesting value in these tests lives
// behind a hierarchical path into a generate block (h.u_core.lane[i].u_cpu.
// regs[r]). A task would have to take it as an argument, which loses the
// name in the failure message; a macro pastes the expression in and can
// stringify it for free.

// ---------------------------------------------------------------------------
// Per-testbench counters.
//
// These are deliberately OUTSIDE the include guard below. xvlog compiles every
// file on its command line in one shared macro scope, so the guard is already
// defined by the time the second testbench includes this file -- guarding the
// declarations too would silently skip them and every testbench after the
// first would fail to compile with "'tb_checks' is not declared". The macros
// DO need guarding (redefining them is an error), the variables do not: each
// testbench is a separate module, so each gets its own copy.
// ---------------------------------------------------------------------------
int tb_checks = 0;
int tb_fails  = 0;
int tb_cycles = 0;

`ifndef TB_CHECK_SVH
`define TB_CHECK_SVH

// Compare two 32-bit values. Uses !== so an X/Z result counts as a failure
// rather than silently comparing unequal-but-unknown.
//
// The operands are pasted in twice rather than latched into temporaries: they
// are always hierarchical signal reads with no side effects, and avoiding
// block-scope declarations keeps the macro usable anywhere a statement is.
`define CHECK_EQ(NAME, ACTUAL, EXPECTED)                                      \
    begin                                                                     \
        tb_checks++;                                                          \
        if (32'(ACTUAL) !== 32'(EXPECTED)) begin                              \
            tb_fails++;                                                       \
            $display("  FAIL %-34s got 0x%08h (%0d)  expected 0x%08h (%0d)",  \
                     NAME, 32'(ACTUAL), $signed(32'(ACTUAL)),                 \
                     32'(EXPECTED), $signed(32'(EXPECTED)));                  \
        end                                                                   \
    end

// Same, but for single-bit / small control signals.
`define CHECK_BIT(NAME, ACTUAL, EXPECTED)                                     \
    begin                                                                     \
        tb_checks++;                                                          \
        if ((ACTUAL) !== (EXPECTED)) begin                                    \
            tb_fails++;                                                       \
            $display("  FAIL %-34s got %b  expected %b",                      \
                     NAME, (ACTUAL), (EXPECTED));                             \
        end                                                                   \
    end

// Assert a plain condition with a caller-supplied message.
`define CHECK_TRUE(NAME, COND)                                                \
    begin                                                                     \
        tb_checks++;                                                          \
        if (!(COND)) begin                                                    \
            tb_fails++;                                                       \
            $display("  FAIL %-34s condition false", NAME);                   \
        end                                                                   \
    end

// Hold reset for a few cycles then release. Expects `clk` and `rst` in scope.
`define TB_RESET                                                              \
    begin                                                                     \
        rst = 1'b1;                                                           \
        repeat (3) @(posedge clk);                                            \
        @(negedge clk);                                                       \
        rst = 1'b0;                                                           \
    end

// Run until the kernel reports done, or fail the test on timeout. Expects
// `clk` and a `kernel_done` expression in scope.
`define RUN_KERNEL(DONE_EXPR, MAX_CYCLES)                                     \
    begin                                                                     \
        tb_cycles = 0;                                                        \
        while (!(DONE_EXPR) && tb_cycles < (MAX_CYCLES)) begin                \
            @(posedge clk);                                                   \
            tb_cycles++;                                                      \
        end                                                                   \
        tb_checks++;                                                          \
        if (!(DONE_EXPR)) begin                                               \
            tb_fails++;                                                       \
            $display("  FAIL kernel_done never asserted (timeout after %0d cycles)", \
                     tb_cycles);                                              \
        end else begin                                                        \
            $display("  kernel completed in %0d cycles", tb_cycles);          \
        end                                                                   \
        /* let the final writeback settle before sampling registers */         \
        repeat (2) @(posedge clk);                                            \
    end

// One-line verdict plus a nonzero exit status on failure, so a shell runner
// can rely on the exit code instead of grepping stdout.
`define TB_SUMMARY(TESTNAME)                                                  \
    begin                                                                     \
        $display("=========================================================="); \
        if (tb_fails == 0)                                                    \
            $display("PASS: %s (%0d/%0d checks)", TESTNAME, tb_checks, tb_checks); \
        else                                                                  \
            $display("FAIL: %s (%0d of %0d checks failed)", TESTNAME,         \
                     tb_fails, tb_checks);                                    \
        $display("=========================================================="); \
        if (tb_fails != 0) $fatal(1, "%s failed", TESTNAME);                   \
        $finish;                                                              \
    end

`endif
