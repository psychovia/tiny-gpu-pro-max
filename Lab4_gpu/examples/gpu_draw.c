// gpu_draw.c -- 32 threads paint a 32x32 image together, one row per thread.
//
// Thread tid draws row tid: it loops across the 32 columns and writes each
// pixel's brightness with setdata. Brightness = (row + col) * 4, so the picture
// is a smooth diagonal gradient -- dark at the top-left, bright at the
// bottom-right. Nothing here is special to "pixels": setdata just writes the
// shared data memory; viewing it as an image is one way to look at the data.
//
// Try it (32 threads -> a 32x32 grayscale PPM you can open):
//   python3 python_scripts/toolchain/cli.py build examples/gpu_draw.c \
//       --threads 32 --data-image gpu_draw.ppm

int main() {
    int y = tid;                        // this thread's row, 0..31
    int x;
    for (x = 0; x < 32; x = x + 1) {
        setdata(y * 32 + x, (y + x) * 4);   // data[row*32 + col] = brightness
    }
    return 0;
}
