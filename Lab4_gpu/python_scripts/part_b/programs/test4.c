// test4.c -- read integers until a 0 sentinel, printing the running sum after
// each one. Exercises scanf, print, addition, and a loop. The 0 (not EOF) is
// what stops it, so it never blocks waiting for input that won't come.
int main() {
    int sum;
    int x;
    sum = 0;
    while (1) {
        scanf("%d", &x);
        if (x == 0) break;
        sum = sum + x;
        print(sum);
    }
    return sum;
}
