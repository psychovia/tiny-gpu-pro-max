// invert.c -- read the source image out of the shared data memory, invert every
// colour channel, and write it back in place. A photographic negative.
//
// Built-ins (doc/GPU_explained.md, doc/custom_instructions.md):
//     tid              this thread's id            -> rdtid
//     getdata(i)       read shared data cell i     -> getdt
//     setdata(i, v)    write shared data cell i    -> setdt
//
// PIXEL FORMAT
//   One cell per pixel, 0x00BBGGRR -- red in the low byte, then green, then
//   blue, top byte unused. That is what img_tool.py writes and what
//   display_controller.sv slices, so a cell here is exactly what the monitor
//   shows.
//
// THE FILTER
//   out = 255 - in, per channel.
//
//   Done per channel with masks rather than as a single `~px`, because the top
//   byte of a cell is unused: `~px` would set it to 0xFF, and while the display
//   only reads bits [23:0] today, leaving junk in a field the format calls
//   reserved is the kind of thing that bites later. Masking each channel keeps
//   the output in the documented 0x00BBGGRR form.
//
// STRIDE
//   Must equal the number of physical lanes, 8. Lane i takes cells i, i+8,
//   i+16, ... so the lanes together cover every pixel exactly once, each lane
//   only touches its own cells, and every lane lands on its own bank -- so all
//   8 are serviced in the same cycle instead of queueing through an arbiter.
//
// NO PER-PIXEL BRANCHES
//   All 8 lanes share one program counter, so an `if` whose condition differs
//   between lanes paints lane 0's answer onto all 8 pixels. Inversion is
//   branch-free arithmetic, so there is nothing to work around here -- but keep
//   it that way if you extend this.

int TOTAL_DATA_SIZE = 4096;   // 64 * 64
int N_LANES = 8;              // physical lanes -- the loop stride

int main() {

    int my_id = tid;
    for (int i = my_id; i < TOTAL_DATA_SIZE; i += N_LANES) {
        int px = getdata(i);

        int r = px & 255;
        int g = (px >> 8) & 255;
        int b = (px >> 16) & 255;

        int ir = 255 - r;
        int ig = 255 - g;
        int ib = 255 - b;

        setdata(i, (ib << 16) | (ig << 8) | ir);
    }

    return 0;

}
