// sum.c -- returns 1 + 2 + ... + 10 == 55

int sum(int n) {
    int s = 0;
    int i = 1;
    while (i <= n) {
        s = s + i;
        i = i + 1;
    }
    return s;
}

int main() {
    return sum(10);
}
