// sum_array.c -- sum the first N elements of a global array.

int data[5];

int fill() {
    data[0] = 10;
    data[1] = 20;
    data[2] = 30;
    data[3] = 40;
    data[4] = 50;
    return 0;
}

int sum_first(int n) {
    int s = 0;
    int i = 0;
    while (i < n) {
        s = s + data[i];
        i = i + 1;
    }
    return s;
}

int main() {
    fill();
    return sum_first(5);    // expect 150
}
