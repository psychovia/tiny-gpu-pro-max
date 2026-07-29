// gpu_inc.c -- the GPU way to increment an array: read, +1, write back.
//
// The 32 threads share ONE data memory. Each thread handles exactly one cell:
// it reads its own cell (getdata), adds one, and writes it back (setdata). No
// loop over the array -- the 32 lanes cover all 32 cells at once. That is data
// parallelism: one program, many threads, different data per thread (via tid).
//
// The data memory starts all zero, so after every thread runs, cells 0..31
// hold 1. In the 32x32 grid view that is the top row lit.
//
// Try it (32 threads, show the data as text and as an image):
//   python3 python_scripts/toolchain/cli.py build examples/gpu_inc.c \
//       --threads 32 --data-text --data-image gpu_inc.ppm

int main() {
    int i = tid;                        // this thread's lane number, 0..31
    setdata(i, getdata(i) + 1);         // data[i] = data[i] + 1
    return 0;
}
