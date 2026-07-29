// read_sum.c -- read integers from input until end-of-input, printing the
// running total after each one, and return the final sum in a0.
//
// Try it:   echo "10 20 30 40" | python3 python_scripts/toolchain/cli.py build examples/read_sum.c --dump a0
// scanf returns 1 each time it reads a number, and -1 at end-of-input, so the
// loop stops when the input runs out.

int main() {
    int sum;
    int x;
    sum = 0;
    while (scanf("%d", &x) == 1) {
        sum = sum + x;
        print(sum);
    }
    return sum;
}
