// print_demo.c -- shows off the magic print() built-in.

int square(int x) {
    return x * x;
}

int main() {
    print(42);
    print(-7);
    for (int i = 1; i <= 5; i++) {
        print(square(i));         // 1, 4, 9, 16, 25
    }
    return 0;
}
