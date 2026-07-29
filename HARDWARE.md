# Rendering an image to an HDMI monitor

End-to-end: a 64x64 RGB image is baked into the FPGA's memory, the 8-lane GPU
converts it to grayscale, and the display controller scans the result out over
HDMI at 800x600@60Hz.

## TL;DR

```sh
# 1. pick your input image (any size; resized to 64x64)
python3 python_scripts/img_tool.py to-mem my_photo.png mems/img_source.mem

# 2. prove it works in simulation first -- takes about a minute
./run_tests.sh test8      # the filter kernel, all 4096 pixels checked
./run_tests.sh test9      # the whole render path, one full video frame
#    then look at .sim/scanout.png -- that is what the monitor will show

# 3. build the bitstream (~5 min)
vivado -mode batch -source vivado/build_bitstream.tcl

# 4. plug the board in over USB, connect HDMI to a monitor, then
vivado -mode batch -source vivado/program_board.tcl
```

Press **BTN[0]** to reset and re-run the kernel.

## What you should see

A 512x512 grayscale image centred on a black background. It stays black for the
first ~1.8 ms after reset — `display_controller` holds `video_active` low until
`kernel_done`, so nothing is shown until the filter has finished. At 40 MHz the
kernel takes 70,707 cycles, so you will not see the black period.

The monitor should report **800x600 @ 60 Hz**. The image occupies 512x512 in the
middle with a 144-pixel black border left/right and 44 top/bottom.

## The filter

[tests/filter_gray.s](tests/filter_gray.s) — Rec.601 luma in 8-bit fixed point:

```
gray = (77*R + 150*G + 29*B) >> 8
```

Multiply-and-shift only, because this core has `mul` but no divide. Each of the
8 lanes owns 512 of the 4096 pixels, interleaved (lane *i* takes pixels *i*,
*i+8*, *i+16*, …). Interleaving is required, not stylistic: all 8 lanes share
one FSM and `scheduler.sv` will not leave `S_MEM_ADDR` until every lane has been
serviced, so all lanes must issue their memory ops on the same instruction.

Pixels are 3 bytes, so adjacent lanes' pixels share 32-bit words. That is safe:
`shared_mem` grants one lane per cycle and applies `byte_en` per byte, so two
lanes never touch the same byte.

To write a different filter, edit the `.s` file and re-run — `rvasm.py` only
accepts instructions this design actually implements, so it rejects anything
unsupported instead of silently mis-encoding it. Swap which program gets baked
in via `gpu.sv`'s `PROG_INIT_FILE` parameter.

## Build results (measured, not estimated)

| | |
|---|---|
| Device | xc7s50csga324-1 (Boolean board) |
| Slice LUTs | 23755 / 32600 (**72.9%**) |
| — LUT as logic | 15563 (47.7%) |
| — LUT as distributed RAM | 8192 / 9600 (**85.3%**) |
| Slice registers | 9265 / 65200 (14.2%) |
| Worst setup slack (WNS) | **+3.100 ns** |
| Worst hold slack (WHS) | **+0.057 ns** |
| Timing | **met** |

`shared_mem` infers **distributed RAM, not BRAM**, and that is the tightest
resource at 85.3%. The cause: the display port reads two words combinationally
(`disp_word_lo` / `disp_word_hi`, needed because 3-byte pixels straddle word
boundaries) on top of the compute port's read/write — three ports, where a
block RAM has two. It fits, but a larger image will not. Registering the display
read and dropping to one word per cycle would move this into BRAM and free
~8000 LUTs.

## Clocking

`top.sv` uses the Clocking Wizard core `clk_wiz_0` (100 MHz in → 40 MHz pixel +
200 MHz TMDS 5x). The build script takes it from
`/home/mini_gpu/mini_gpu.srcs/sources_1/ip/clk_wiz_0/clk_wiz_0.xci`. If yours is
elsewhere:

```sh
vivado -mode batch -source vivado/build_bitstream.tcl -tclargs /path/to/clk_wiz_0.xci
```

Pin assignments come from [constraints/boolean_mini_gpu.xdc](constraints/boolean_mini_gpu.xdc).
HDMI data lane 0 = blue, 1 = green, 2 = red.

## Image tooling

[python_scripts/img_tool.py](python_scripts/img_tool.py) — stdlib only (PIL is
not installed, so PNG read/write is implemented on `zlib`).

| Command | Purpose |
|---|---|
| `testpattern <out.png>` | synthetic 64x64 colour test image |
| `to-mem <in.png> <out.mem>` | resize to 64x64 and pack for `$readmemb` |
| `from-mem <in.mem> <out.png>` | unpack a `.mem` back to a viewable PNG |
| `from-frame <in.txt> <out.png>` | convert a testbench frame dump to a PNG |
| `filter <in.png> <out.png>` | reference grayscale, for comparison |

Accepts 8-bit non-interlaced PNG (grayscale/RGB/RGBA) and binary PPM.

## Verified in simulation

`test9_scanout` runs the real `gpu` module — core, memory, display controller
and VGA timing generator — through a complete video frame and checks:

- line = 1056 cycles, frame = 663,168 cycles → **60 Hz** at 40 MHz
- hsync 128 cycles wide, vsync 4 lines deep
- **262,144 active pixels per frame** (exactly 512x512)
- **zero** undefined (X) pixels while `video_active` is high
- every visible pixel matches the filtered image at the right screen position
- all 4096 source pixels appear on screen

The scanned-out frame is dumped to `.sim/scanout.png` and is **pixel-identical**
to the Python reference implementation.

## If the monitor shows nothing

1. **No signal at all** — check `locked` from the clock wizard. `hdmi_tx_0.sv`
   holds the transmitter in reset until the MMCM locks, so an unlocked MMCM
   means no TMDS output at all.
2. **Black screen, monitor reports 800x600@60** — the sync timing is reaching
   the monitor but pixels are not. `kernel_done` may never be asserting; check
   that `mems/*.mem` were found at synthesis time (the log should say
   `$readmem data file ... is read successfully` — if it does not, the memory
   is all zeros, no lane ever writes 1 to x31, and `video_active` stays low
   forever).
3. **Wrong colours** — HDMI lane order. Lane 0 is blue, 2 is red; swapping them
   in the XDC inverts red and blue.
4. **Image but scrambled** — re-run `./run_tests.sh test9`, which checks every
   visible pixel's position and value against the source.

## Known limitations

- **One kernel run per reset.** `scheduler.sv` freezes on `kernel_done`, so the
  filter runs once. Press BTN[0] to re-run. It re-filters the *original* image
  because the BRAM contents are re-initialized only on FPGA configuration — after
  a reset the kernel grayscales the already-grey image, which is idempotent here
  but would not be for a non-idempotent filter.
- **64x64 fixed.** `IMG_WIDTH`/`IMG_HEIGHT` in `gpu_pkg.sv` set the image size,
  but the distributed-RAM ceiling above (85.3%) is the real constraint on
  growing it.
- **No divergent control flow.** Only lane 0 resolves branches, so every lane
  must take the same path. Per-lane *data* is fine.
