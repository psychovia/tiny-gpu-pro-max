// local_array.c -- arrays declared inside a function live on the stack.
// We fill an array with 1..5, reverse it in place, and return the new first
// element (which is 5).

int main() {
    int a[5];
    int i;
    int j;
    int t;

    for (i = 0; i < 5; i++)
        a[i] = i + 1;            // a = {1, 2, 3, 4, 5}

    // reverse in place
    i = 0;
    j = 4;
    while (i < j) {
        t = a[i];
        a[i] = a[j];
        a[j] = t;
        i = i + 1;
        j = j - 1;
    }

    return a[0];                 // 5
}
