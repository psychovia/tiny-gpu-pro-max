// filter.c -- read the source image out of the shared data memory, apply a
// grayscale filter, and write it back in place.
//
// Built-ins (doc/GPU_explained.md, doc/custom_instructions.md):
//     tid              this thread's id            -> rdtid
//     getdata(i)       read shared data cell i     -> getdt
//     setdata(i, v)    write shared data cell i    -> setdt
//
// PIXEL FORMAT
//   One cell per pixel, 0x00BBGGRR -- red in the low byte, then green, then
//   blue. That is the layout img_tool.py writes and display_controller.sv
//   slices, so a cell read here is exactly what the monitor shows.
//
// THE FILTER
//   gray = (77*R + 150*G + 29*B) >> 8
//   8-bit fixed-point Rec.601 luma (0.299/0.587/0.114 scaled by 256). Integer
//   multiply and shift only: this core has `mul` but NO divide, so anything
//   written as `/ 256` would be lowered to a slow software division routine.
//
// STRIDE
//   Must equal the number of physical lanes, 8. Lane i takes cells i, i+8,
//   i+16, ... so the lanes together cover every pixel exactly once, each lane
//   only ever touches its own cells, and every lane lands on its own bank so
//   all 8 are serviced in the same cycle.

int TOTAL_DATA_SIZE = 4096;   // 64 * 64
int N_LANES = 8;              // physical lanes -- the loop stride

int main() {

    int my_id = tid;
    for (int i = my_id; i < TOTAL_DATA_SIZE; i += N_LANES) {
        int px = getdata(i);

        // Unpack. No byte addressing here -- a cell is a whole 32-bit value,
        // so the channels come out with shifts and masks.
        int r = px & 255;
        int g = (px >> 8) & 255;
        int b = (px >> 16) & 255;

        int y = (77 * r + 150 * g + 29 * b) >> 8;

        // Repack as a neutral grey. y is already 0..255 because the weights
        // sum to 256 and the inputs are bytes, so no clamping is needed.
        setdata(i, (y << 16) | (y << 8) | y);
    }

    return 0;

}
