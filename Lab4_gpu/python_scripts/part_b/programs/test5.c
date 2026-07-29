// test5.c -- read pairs (a b) until a is 0; print a*b for each pair.
// Exercises the mul instruction.
int main() {
    int a;
    int b;
    while (1) {
        scanf("%d", &a);
        if (a == 0) break;
        scanf("%d", &b);
        print(a * b);
    }
    return 0;
}
