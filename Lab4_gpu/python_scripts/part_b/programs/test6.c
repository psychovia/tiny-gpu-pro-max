// test6.c -- read pairs (a b) until a is 0; print a/b then a%b for each pair.
// There is no hardware divide, so the compiler turns / and % into a software
// routine -- this exercises that whole path. (b is always non-zero here.)
int main() {
    int a;
    int b;
    while (1) {
        scanf("%d", &a);
        if (a == 0) break;
        scanf("%d", &b);
        print(a / b);
        print(a % b);
    }
    return 0;
}
