// test7.c -- read n until a 0; print fib(n) and fact(n) for each.
// Recursion exercises function calls, the stack, and the calling convention
// (jal/jalr, saving/restoring ra). n is kept small so the results fit in 32 bits.
int fib(int n) {
    if (n < 2) return n;
    return fib(n - 1) + fib(n - 2);
}
int fact(int n) {
    if (n < 2) return 1;
    return n * fact(n - 1);
}
int main() {
    int n;
    while (1) {
        scanf("%d", &n);
        if (n == 0) break;
        print(fib(n));
        print(fact(n));
    }
    return 0;
}
