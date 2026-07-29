// test9.c -- the comprehensive one. A single program (one bitstream) that
// exercises everything the earlier tests do, so grading is one flash + one run.
// Four sections, each ended by a 0 sentinel:
//   1) ints -> print sum and count
//   2) pairs (a b) -> print a*b, a/b, a%b
//   3) n -> print fib(n)                 (recursion / the stack)
//   4) ints -> store in an array, print them back in reverse
int fib(int n) {
    if (n < 2) return n;
    return fib(n - 1) + fib(n - 2);
}
int main() {
    int arr[64];
    int x;
    int a;
    int b;
    int sum;
    int count;
    int m;
    int i;

    // 1) sum + count
    sum = 0;
    count = 0;
    while (1) {
        scanf("%d", &x);
        if (x == 0) break;
        sum = sum + x;
        count = count + 1;
    }
    print(sum);
    print(count);

    // 2) products, quotients, remainders
    while (1) {
        scanf("%d", &a);
        if (a == 0) break;
        scanf("%d", &b);
        print(a * b);
        print(a / b);
        print(a % b);
    }

    // 3) fibonacci (recursion)
    while (1) {
        scanf("%d", &x);
        if (x == 0) break;
        print(fib(x));
    }

    // 4) array stored then printed in reverse
    m = 0;
    while (1) {
        scanf("%d", &x);
        if (x == 0) break;
        arr[m] = x;
        m = m + 1;
    }
    i = m - 1;
    while (i >= 0) {
        print(arr[i]);
        i = i - 1;
    }
    return 0;
}
