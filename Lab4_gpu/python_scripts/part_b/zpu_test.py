"""
zpu_test.py -- shared test harness for the FPGA CPU (the ZPU).

How it works: it runs your test program on the Python *simulator* to get the
golden output, then feeds the SAME input to your CPU on the FPGA over I2C and
reads back what your CPU produces. The two must match byte-for-byte.

  - The simulator is the source of truth, so inputs can be randomized: there is
    no golden file to keep up to date.
  - Programs end on an in-band sentinel (a 0 byte for the byte/echo test, the
    value 0 for the number tests), never on EOF -- your getchar just stalls when
    rx is empty, so "until EOF" would hang forever. The harness sends a trailing
    newline so the last scanf finishes.
  - Reset is the on-board button 0: the harness asks you to press it (which
    restarts your CPU) before each run.

The per-test scripts (run_test0.py ... run_test9.py) just describe their program
and how to build its input, then call run_case().
"""

import io
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
# simulator.py / isa.py live in ../toolchain (true on the Pi and in the repo).
sys.path.insert(0, os.path.join(HERE, "..", "toolchain"))
import simulator  # noqa: E402

PROGRAMS = os.path.join(HERE, "programs")

# ---- I2C register map (matches part_b/fpga_io.sv io_bridge) -----------------
ADDR, BUS = 0x50, 1
REG_STATUS, REG_RX, REG_TX, REG_RXCOUNT, REG_TXCOUNT = 0x00, 0x01, 0x02, 0x03, 0x04
RX_EMPTY, RX_FULL, TX_EMPTY, TX_FULL, OVERFLOW = 1, 2, 4, 8, 16
FIFO_DEPTH = 16          # the rx/tx FIFOs hold 16 bytes (fifo.sv DEPTH)
SMBUS_MAX  = 32          # SMBus block transfer limit


# ---- simulator oracle -------------------------------------------------------
def simulate(program, input_bytes, max_cycles=20_000_000):
    """Run `program` (.mem) on the simulator with input_bytes; return its output
    bytes. Bytes <-> the simulator's text streams via latin-1 (1 char == 1 byte)."""
    out = io.StringIO()
    cpu = simulator.CPU(mem_size=65536,
                        input=io.StringIO(input_bytes.decode("latin-1")),
                        output=out)
    simulator.load_mem_file(cpu, os.path.join(PROGRAMS, program))
    simulator.run(cpu, max_cycles=max_cycles)
    return out.getvalue().encode("latin-1")


# ---- pretty-printing for the diff -------------------------------------------
def vis(bs):
    """Render bytes readably: printable ASCII as-is, everything else escaped."""
    parts = []
    for b in bs:
        if b == 0x0A:           parts.append("\\n")
        elif b == 0x09:         parts.append("\\t")
        elif 0x20 <= b < 0x7F:  parts.append(chr(b))
        else:                   parts.append("\\x%02x" % b)
    return "".join(parts)


def report(golden, got, note=""):
    """Print PASS, or a comprehensive 'expected X, got Y' diff. Returns bool."""
    if got == golden:
        print("  PASS  output matched the simulator (%d bytes)." % len(golden))
        return True

    print("  FAIL  output did NOT match the simulator." + (("  (%s)" % note) if note else ""))
    print("    expected (%d bytes): %s" % (len(golden), vis(golden)))
    print("    received (%d bytes): %s" % (len(got),    vis(got)))

    # first point of divergence
    i = 0
    while i < len(golden) and i < len(got) and golden[i] == got[i]:
        i += 1
    print("    first difference at byte %d:" % i)
    if i < len(golden):
        print("      expected to see 0x%02x (%s) here" % (golden[i], vis(golden[i:i + 1])))
    else:
        print("      expected nothing more here (the CPU sent extra bytes)")
    if i < len(got):
        print("      but the CPU sent 0x%02x (%s)" % (got[i], vis(got[i:i + 1])))
    else:
        print("      but the CPU sent nothing more "
              "(it stopped %d byte(s) short -- likely stalled)" % (len(golden) - len(got)))
    return False


# ---- driving the FPGA over I2C ----------------------------------------------
def _drive(bus, input_bytes, golden, timeout_s):
    """Feed input_bytes into rx and drain tx, interleaved, until we've collected
    as many output bytes as the simulator produced (or we time out with no
    progress). Returns (got_bytes, note)."""
    # BTN0 (the reset you just tapped) clears both FIFOs, so there's nothing stale
    # to drain -- whatever lands in tx now is THIS run's output. We must NOT drain
    # it: a program that finished before you pressed Enter would otherwise lose it.
    got = bytearray()
    in_pos = 0
    last_progress = time.monotonic()
    while len(got) < len(golden):
        progressed = False

        # feed: push as many input bytes as rx has room for
        if in_pos < len(input_bytes):
            space = FIFO_DEPTH - bus.read_byte_data(ADDR, REG_RXCOUNT)
            if space > 0:
                chunk = input_bytes[in_pos:in_pos + min(space, SMBUS_MAX)]
                bus.write_i2c_block_data(ADDR, REG_RX, list(chunk))
                in_pos += len(chunk); progressed = True

        # drain: pop whatever output is waiting
        txc = bus.read_byte_data(ADDR, REG_TXCOUNT)
        if txc:
            n = min(txc, len(golden) - len(got), SMBUS_MAX)
            got.extend(bus.read_i2c_block_data(ADDR, REG_TX, n)); progressed = True

        if progressed:
            last_progress = time.monotonic()
        elif time.monotonic() - last_progress > timeout_s:
            return bytes(got), "timed out after %.1fs with no progress" % timeout_s
        else:
            time.sleep(0.002)

    return bytes(got), ""


# ---- the entry point the run_testN.py scripts call --------------------------
def run_case(program, input_bytes, *, sim_only=False, timeout_s=2.5):
    """Run one test. `program` is a .mem filename in programs/; `input_bytes` is
    the exact byte stream to feed (already including any sentinel and trailing
    delimiter). Returns True on PASS."""
    print("=== %s ===" % program)
    print("  input  (%d bytes): %s" % (len(input_bytes), vis(input_bytes)))
    golden = simulate(program, input_bytes)
    print("  simulator output (%d bytes): %s" % (len(golden), vis(golden)))

    if sim_only:
        print("  (--sim-only: skipping the FPGA; this is the expected output.)")
        return True

    try:
        from smbus2 import SMBus
    except ImportError:
        print("  ERROR: smbus2 not installed; run with --sim-only, or `pip install smbus2`.")
        return False

    input("  Tap BTN0 on the FPGA to reset it (this clears the FIFOs and starts your\n"
          "  CPU), THEN press Enter here to read the result...")
    with SMBus(BUS) as bus:
        got, note = _drive(bus, input_bytes, golden, timeout_s)
    return report(golden, got, note)


import random


def setup(argv, default_timeout=2.5):
    """Shared CLI for the run_testN.py scripts. Flags: --sim-only, --timeout S,
    --seed N. Prints the seed used so any failure is reproducible. Returns
    (sim_only, timeout_s, rng)."""
    sim_only = "--sim-only" in argv
    timeout_s, seed = default_timeout, None
    for i, a in enumerate(argv):
        if a == "--timeout" and i + 1 < len(argv): timeout_s = float(argv[i + 1])
        if a == "--seed"    and i + 1 < len(argv): seed = int(argv[i + 1])
    if seed is None:
        seed = random.randrange(1 << 30)
    print("seed: %d   (re-run with --seed %d to reproduce this exact input)" % (seed, seed))
    return sim_only, timeout_s, random.Random(seed)


def nz(rng, lo, hi):
    """A random integer in [lo, hi] that is never 0 (0 is the number-sentinel)."""
    v = 0
    while v == 0:
        v = rng.randint(lo, hi)
    return v


def encode_nums(nums):
    """[1, -2, 0] -> b'1 -2 0' (space-separated decimal, for the scanf tests)."""
    return " ".join(str(n) for n in nums).encode("ascii")
