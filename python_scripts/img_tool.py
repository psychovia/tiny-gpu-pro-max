#!/usr/bin/env python3
"""
img_tool.py -- move images in and out of the GPU's framebuffer format.

shared_mem.sv loads its image region with $readmemb from IMG_INIT_FILE: one
32-bit binary word per line, starting at IMG_BASE. Pixels are 3 tightly-packed
bytes (R,G,B) in little-endian byte order within each word, so pixel 0's red
byte is bits [7:0] of word 0 and pixels straddle word boundaries -- which is
the whole reason shared_mem's display port reads two words and slices.

Everything here is stdlib only (zlib + struct): PIL is not installed, so PNG
read/write is implemented directly. Non-interlaced 8-bit RGB/RGBA/grayscale PNGs
are supported, which covers anything you would export from a normal image editor.

Commands
    testpattern <out.png> [N]        write an NxN synthetic colour test image
    to-mem      <in.png|ppm> <out.mem>
                                     resize to 64x64 (nearest) and pack to .mem
    from-mem    <in.mem> <out.png>   unpack a .mem image region back to a PNG
    to-dbuf     <in.png|ppm> <out.mem>
                                     same, but in data_buffer.sv's layout: one
                                     32-bit element per pixel (0x00BBGGRR), no
                                     packing and no straddle
    from-dbuf   <in.mem> <out.png>   unpack a data-buffer image back to a PNG
    zeros-dbuf  <out.mem> [N]        a blank buffer, for kernels that render
                                     from scratch instead of filtering
    from-frame  <in.txt> <out.png>   convert a testbench frame dump to a PNG
    filter      <in.png> <out.png>   apply the same grayscale filter the GPU
                                     kernel applies, as a reference

Example
    python3 python_scripts/img_tool.py testpattern mems/source.png
    python3 python_scripts/img_tool.py to-mem mems/source.png mems/img.mem
"""

import struct
import sys
import zlib

WIDTH = HEIGHT = 64
BYTES_PER_PIXEL = 3

# Grayscale weights. Must stay in lockstep with tests/filter_gray.s and with
# test8_filter_tb.sv -- all three implement gray = (77R + 150G + 29B) >> 8,
# an 8-bit fixed-point approximation of the Rec.601 luma coefficients
# (0.299, 0.587, 0.114). Integer-only and shift-only, because the GPU has
# mul but no divide.
W_R, W_G, W_B = 77, 150, 29


def gray(r, g, b):
    return (W_R * r + W_G * g + W_B * b) >> 8


# ---------------------------------------------------------------------------
# PNG
# ---------------------------------------------------------------------------

def png_write(path, pixels, w, h):
    """pixels: flat list of (r,g,b) tuples, row-major."""
    raw = bytearray()
    for y in range(h):
        raw.append(0)  # filter type 0 (None) for every scanline
        for x in range(w):
            raw.extend(pixels[y * w + x])

    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    with open(path, "wb") as fh:
        fh.write(b"\x89PNG\r\n\x1a\n")
        fh.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)))
        fh.write(chunk(b"IDAT", zlib.compress(bytes(raw), 9)))
        fh.write(chunk(b"IEND", b""))


def png_read(path):
    """Return (pixels, w, h). Handles 8-bit non-interlaced RGB/RGBA/gray."""
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path}: not a PNG")
    pos, idat, w = 8, bytearray(), None
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        tag = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        if tag == b"IHDR":
            w, h, depth, ctype, comp, filt, interlace = struct.unpack(">IIBBBBB", body)
            if depth != 8:
                raise ValueError(f"{path}: only 8-bit PNGs supported (got {depth})")
            if interlace:
                raise ValueError(f"{path}: interlaced PNGs not supported")
            if ctype not in (0, 2, 6):
                raise ValueError(f"{path}: unsupported colour type {ctype} "
                                 "(need grayscale, RGB or RGBA)")
        elif tag == b"IDAT":
            idat += body
        elif tag == b"IEND":
            break
        pos += 12 + length
    if w is None:
        raise ValueError(f"{path}: no IHDR chunk")

    nch = {0: 1, 2: 3, 6: 4}[ctype]
    raw = zlib.decompress(bytes(idat))
    stride = w * nch
    out, prev = [], bytearray(stride)
    p = 0
    for _ in range(h):
        ftype = raw[p]; p += 1
        line = bytearray(raw[p:p + stride]); p += stride
        # undo the per-scanline PNG filters
        for i in range(stride):
            a = line[i - nch] if i >= nch else 0
            b = prev[i]
            c = prev[i - nch] if i >= nch else 0
            if ftype == 1:   line[i] = (line[i] + a) & 0xFF
            elif ftype == 2: line[i] = (line[i] + b) & 0xFF
            elif ftype == 3: line[i] = (line[i] + ((a + b) >> 1)) & 0xFF
            elif ftype == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pred) & 0xFF
            elif ftype != 0:
                raise ValueError(f"{path}: bad filter type {ftype}")
        for x in range(w):
            px = line[x * nch:x * nch + nch]
            out.append((px[0], px[0], px[0]) if nch == 1 else (px[0], px[1], px[2]))
        prev = line
    return out, w, h


# ---------------------------------------------------------------------------
# PPM (P6) -- trivial, and handy if you would rather not deal with PNG
# ---------------------------------------------------------------------------

def ppm_read(path):
    data = open(path, "rb").read()
    if data[:2] != b"P6":
        raise ValueError(f"{path}: not a binary (P6) PPM")
    fields, pos = [], 2
    while len(fields) < 3:
        while pos < len(data) and data[pos:pos + 1].isspace():
            pos += 1
        if data[pos:pos + 1] == b"#":
            while data[pos:pos + 1] != b"\n":
                pos += 1
            continue
        start = pos
        while not data[pos:pos + 1].isspace():
            pos += 1
        fields.append(int(data[start:pos]))
    pos += 1
    w, h, maxval = fields
    if maxval != 255:
        raise ValueError(f"{path}: only 8-bit PPMs supported")
    body = data[pos:pos + w * h * 3]
    return [tuple(body[i:i + 3]) for i in range(0, len(body), 3)], w, h


def _jpeg_to_png(path):
    """PNG/PPM are decoded here in pure stdlib, but JPEG needs a real decoder.
    ImageMagick is on the ECE machines, so shell out to it rather than vendoring
    a baseline JPEG decoder for one conversion."""
    import subprocess, tempfile, os as _os
    tmp = tempfile.NamedTemporaryFile(suffix=".png", delete=False)
    tmp.close()
    r = subprocess.run(["convert", path, "-strip", tmp.name],
                       capture_output=True, text=True)
    if r.returncode != 0 or _os.path.getsize(tmp.name) == 0:
        raise SystemExit(f"img_tool: could not convert {path} to PNG.\n"
                         f"  ImageMagick said: {r.stderr.strip()}\n"
                         f"  Convert it yourself first:  convert in.jpg out.png")
    return tmp.name


def image_read(path):
    if path.lower().endswith((".jpg", ".jpeg")):
        print(f"img_tool: decoding {path} via ImageMagick")
        path = _jpeg_to_png(path)
    if path.lower().endswith(".ppm"):
        return ppm_read(path)
    return png_read(path)


def resize_nearest(pixels, w, h, nw, nh):
    if (w, h) == (nw, nh):
        return pixels
    return [pixels[(y * h // nh) * w + (x * w // nw)]
            for y in range(nh) for x in range(nw)]


# ---------------------------------------------------------------------------
# .mem  <->  pixels
# ---------------------------------------------------------------------------

def mem_write(path, pixels, w, h, note):
    """Pack RGB bytes little-endian into 32-bit words, zero-padding the tail."""
    raw = bytearray()
    for px in pixels:
        raw.extend(px[:3])
    while len(raw) % 4:
        raw.append(0)
    words = [int.from_bytes(raw[i:i + 4], "little") for i in range(0, len(raw), 4)]
    with open(path, "w") as fh:
        fh.write(f"// generated by img_tool.py -- {note}\n")
        fh.write(f"// {w}x{h} RGB, {BYTES_PER_PIXEL} bytes/pixel, "
                 f"{len(words)} words, loaded at IMG_BASE\n")
        for word in words:
            fh.write(f"{word:032b}\n")
    return len(words)


def dbuf_write(path, pixels, w, h, note):
    """One 32-bit word per pixel, 0x00_BB_GG_RR -- the data_buffer.sv layout.

    Unlike mem_write's 3-tightly-packed-bytes format, a pixel here IS an
    element, so nothing straddles a word: no padding, no byte lanes, and the
    display port reads one word instead of two-and-a-slice. The channel order
    is the same one display_controller.sv slices out (R low, then G, then B),
    so both image stores feed it identically."""
    with open(path, "w") as fh:
        fh.write(f"// generated by img_tool.py -- {note}\n")
        fh.write(f"// {w}x{h} RGB, one 32-bit element per pixel "
                 f"(0x00BBGGRR), {w * h} elements, loaded into data_buffer.sv\n")
        for r, g, b in (px[:3] for px in pixels):
            fh.write(f"{(b << 16) | (g << 8) | r:032b}\n")
    return w * h


def dbuf_read(path, w=WIDTH, h=HEIGHT):
    words = []
    for line in open(path):
        line = line.split("//")[0].strip()
        if line:
            words.append(int(line, 2))
    words.extend([0] * max(0, w * h - len(words)))
    return [(v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF) for v in words[:w * h]]


def mem_read(path, w=WIDTH, h=HEIGHT):
    words = []
    for line in open(path):
        line = line.split("//")[0].strip()
        if line:
            words.append(int(line, 2))
    raw = bytearray()
    for word in words:
        raw.extend(word.to_bytes(4, "little"))
    need = w * h * 3
    raw.extend(bytes(max(0, need - len(raw))))
    return [tuple(raw[i * 3:i * 3 + 3]) for i in range(w * h)]


# ---------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------

def cmd_testpattern(out, n=WIDTH):
    """Colour bars + gradients + a couple of shapes. Chosen so a grayscale
    filter is unmistakable (saturated hues collapse to distinct grey levels)
    and so any x/y transposition or off-by-one in the address math is visible."""
    n = int(n)
    px = []
    bars = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0),
            (255, 0, 255), (0, 255, 255), (255, 255, 255), (0, 0, 0)]
    for y in range(n):
        for x in range(n):
            if y < n // 4:                       # colour bars across the top
                px.append(bars[x * len(bars) // n])
            elif y < n // 2:                     # horizontal grey ramp
                v = x * 255 // (n - 1)
                px.append((v, v, v))
            elif y < 3 * n // 4:                 # two-axis red/blue gradient
                px.append((x * 255 // (n - 1), 40, y * 255 // (n - 1)))
            else:                                # green field, white diagonal,
                cx, cy = x - 3 * n // 4, y - 7 * n // 8   # magenta disc
                if abs(x - y) < 2:
                    px.append((255, 255, 255))
                elif cx * cx + cy * cy < (n // 10) ** 2:
                    px.append((255, 0, 255))
                else:
                    px.append((20, 160, 60))
    png_write(out, px, n, n)
    print(f"img_tool: wrote {out} ({n}x{n} test pattern)")


def cmd_to_mem(src, out):
    px, w, h = image_read(src)
    if (w, h) != (WIDTH, HEIGHT):
        print(f"img_tool: resizing {w}x{h} -> {WIDTH}x{HEIGHT} (nearest neighbour)")
        px = resize_nearest(px, w, h, WIDTH, HEIGHT)
    nwords = mem_write(out, px, WIDTH, HEIGHT, f"packed from {src}")
    print(f"img_tool: wrote {out} ({nwords} words) from {src}")


def cmd_from_mem(src, out):
    px = mem_read(src)
    png_write(out, px, WIDTH, HEIGHT)
    print(f"img_tool: wrote {out} ({WIDTH}x{HEIGHT}) from {src}")


BANKS = 8   # must match gpu_pkg::N_LANES / data_buffer.sv's BANKS


def dbuf_write_banks(prefix, pixels, note, banks=BANKS):
    """Write one file per bank: <prefix>0.mem .. <prefix>{banks-1}.mem.

    data_buffer.sv splits an element index as bank = index % BANKS, row =
    index / BANKS, and each bank $readmemb's its own file directly -- that is
    the only form Vivado turns into real BRAM init contents. (Reading one flat
    file into an array and scattering it is dropped at synthesis with
    "[Synth 8-311] ignoring non-constant assignment in initial block", which
    loads correctly in simulation and gives all zeros on the board.) So the
    stride has to be applied HERE, at generation time."""
    words = [(b << 16) | (g << 8) | r for r, g, b in (p[:3] for p in pixels)]
    for bank in range(banks):
        path = f"{prefix}{bank}.mem"
        with open(path, "w") as fh:
            fh.write(f"// generated by img_tool.py -- {note}\n")
            fh.write(f"// bank {bank} of {banks}: elements {bank}, {bank+banks}, "
                     f"{bank+2*banks}, ... one 32-bit pixel each (0x00BBGGRR)\n")
            for i in range(bank, len(words), banks):
                fh.write(f"{words[i]:032b}\n")
    return banks


def cmd_to_dbuf(src, out):
    px, w, h = image_read(src)
    if (w, h) != (WIDTH, HEIGHT):
        print(f"img_tool: resizing {w}x{h} -> {WIDTH}x{HEIGHT} (nearest neighbour)")
        px = resize_nearest(px, w, h, WIDTH, HEIGHT)
    n = dbuf_write(out, px, WIDTH, HEIGHT, f"packed from {src}")
    # Also emit the per-bank set the hardware actually loads. `out` keeps the
    # flat file (handy for from-dbuf and for eyeballing); the prefix drops the
    # ".mem" so bank files sit beside it as <name>_bank0.mem etc.
    prefix = out[:-4] + "_bank" if out.endswith(".mem") else out + "_bank"
    nb = dbuf_write_banks(prefix, px, f"packed from {src}")
    print(f"img_tool: wrote {out} ({n} elements) and {nb} bank files "
          f"{prefix}0.mem..{prefix}{nb-1}.mem from {src}")


def cmd_from_dbuf(src, out):
    png_write(out, dbuf_read(src), WIDTH, HEIGHT)
    print(f"img_tool: wrote {out} ({WIDTH}x{HEIGHT}) from {src}")


def cmd_zeros_dbuf(out, n=None):
    """A blank data buffer -- what a kernel that renders from scratch (rather
    than filtering a source image) starts from."""
    n = int(n) if n is not None else WIDTH * HEIGHT
    with open(out, "w") as fh:
        fh.write("// generated by img_tool.py -- blank data buffer\n")
        fh.write(f"// {n} elements, all zero\n")
        for _ in range(n):
            fh.write("0" * 32 + "\n")
    prefix = out[:-4] + "_bank" if out.endswith(".mem") else out + "_bank"
    nb = dbuf_write_banks(prefix, [(0, 0, 0)] * n, "blank data buffer")
    print(f"img_tool: wrote {out} ({n} zero elements) and {nb} bank files")


def cmd_from_frame(src, out):
    """Frame dumps are one '<x> <y> <rr><gg><bb>' record per line, written by
    the scanout testbench straight from what it saw on vga_r/g/b."""
    px = [(0, 0, 0)] * (WIDTH * HEIGHT)
    seen = 0
    for line in open(src):
        line = line.split("//")[0].split("#")[0].strip()
        if not line:
            continue
        xs, ys, hexval = line.split()
        x, y, v = int(xs), int(ys), int(hexval, 16)
        px[y * WIDTH + x] = ((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
        seen += 1
    png_write(out, px, WIDTH, HEIGHT)
    print(f"img_tool: wrote {out} from {src} ({seen} pixels)")


def cmd_filter(src, out):
    px, w, h = image_read(src)
    png_write(out, [(lambda g: (g, g, g))(gray(*p)) for p in px], w, h)
    print(f"img_tool: wrote {out} (reference grayscale of {src})")


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    cmds = {
        "testpattern": cmd_testpattern,
        "to-mem": cmd_to_mem,
        "from-mem": cmd_from_mem,
        "to-dbuf": cmd_to_dbuf,
        "from-dbuf": cmd_from_dbuf,
        "zeros-dbuf": cmd_zeros_dbuf,
        "from-frame": cmd_from_frame,
        "filter": cmd_filter,
    }
    cmd = argv[1]
    if cmd not in cmds:
        print(f"img_tool: unknown command '{cmd}'\n")
        print(__doc__)
        return 2
    try:
        cmds[cmd](*argv[2:])
    except (ValueError, OSError) as exc:
        print(f"img_tool: {exc}", file=sys.stderr)
        return 1
    except TypeError:
        print(f"img_tool: wrong number of arguments for '{cmd}'", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
