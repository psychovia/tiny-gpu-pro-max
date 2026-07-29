// test8.c -- read integers until a 0 into an array, then print their sum, the
// smallest, and the largest. Exercises array indexing and memory loads/stores.
// (The harness always sends at least one value, so a[0] is valid.)
int main() {
    int a[64];
    int n;
    int i;
    int x;
    int sum;
    int mn;
    int mx;
    n = 0;
    while (1) {
        scanf("%d", &x);
        if (x == 0) break;
        a[n] = x;
        n = n + 1;
    }
    sum = 0;
    mn = a[0];
    mx = a[0];
    i = 0;
    while (i < n) {
        sum = sum + a[i];
        if (a[i] < mn) mn = a[i];
        if (a[i] > mx) mx = a[i];
        i = i + 1;
    }
    print(sum);
    print(mn);
    print(mx);
    return 0;
}
