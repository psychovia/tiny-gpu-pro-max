// divmod.c -- '/' and '%' work, even though the CPU has no divide instruction.
// The compiler turns them into a call to a small software routine (__divmod)
// built out of shifts, subtracts and compares.
//
// Signed division follows C: the quotient truncates toward zero, and the
// remainder takes the sign of the left-hand side.

int main() {
    print(100 / 7);      // 14
    print(100 % 7);      // 2
    print(-100 / 7);     // -14   (truncates toward zero)
    print(-100 % 7);     // -2    (sign of the dividend)
    return 100 / 7;      // returns 14
}
