// gpu.c -- draw a filled circle into the shared data memory, one lane per slice.
//
// Built-ins (see doc/GPU_explained.md and doc/custom_instructions.md):
//     tid              this thread's id            -> rdtid
//     getdata(i)       read shared data cell i     -> getdt
//     setdata(i, v)    write shared data cell i    -> setdt
//
// TARGET GEOMETRY
//   GPU_explained.md describes a 32x32 grid of 0..255 values. This runs on
//   hardware whose buffer is 64x64 of 32-bit cells and whose display reads each
//   cell as a packed pixel (0x00BBGGRR), so the indices and colours below are
//   sized for that. Every index used here is still a plain 0..N-1 cell index.
//
// STRIDE
//   Must equal the number of physical lanes, 8. Lane i takes cells
//   i, i+8, i+16, ... so between them the lanes cover every cell exactly once,
//   and each lane writes only its own cells -- so there are no collisions in
//   the sense GPU_explained.md warns about. It is also the stride the buffer is
//   banked for, so all 8 lanes are serviced in one cycle instead of queueing.
//   (32 here, the thread count from the doc, would leave 24 of every 32 cells
//   never written on 8-lane hardware.)

int TOTAL_DATA_SIZE = 4096;   // 64 * 64
int N_LANES = 8;              // physical lanes -- see STRIDE above

int main() {

    int x_circle_center = 32;
    int y_circle_center = 32;
    int radius = 12;
    int X_DIM_MAX = 64;       // KEEP AS A POWER OF TWO

    int my_id = tid;
    for (int i = my_id; i < TOTAL_DATA_SIZE; i += N_LANES) {
        int curr_x = i & 63;  // equivalent to i % 64
        int curr_y = i >> 6;  // equivalent to i / 64
        int x_dist = (curr_x - x_circle_center);
        int x_dist_squared = x_dist * x_dist;
        int y_dist = (curr_y - y_circle_center);
        int y_dist_squared = y_dist * y_dist;
        int allowed = radius * radius;

        // BRANCH-FREE ON PURPOSE -- do not turn this back into if/else.
        //
        // All 8 lanes share one program counter: pc.sv resolves every branch
        // from lane 0's registers only, so all 8 go whichever way lane 0 went.
        // A per-cell `if` therefore paints lane 0's answer onto all 8 cells --
        // not a stall, a wrong image, and only along the circle's edge where
        // the lanes disagree, which is the easiest kind of bug to look past.
        //
        // `inside` is 0 or 1, so `inside - 1` is 0 when inside and ~0 when
        // outside: the same two values an if/else would write, no control flow.
        // The comparison uses the SQUARED distances, which is what makes it a
        // circle rather than a diamond.
        int inside = (x_dist_squared + y_dist_squared) < allowed;
        setdata(i, inside - 1);

    }

    return 0;

}
