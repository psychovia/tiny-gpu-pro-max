

int sum_till_x(int x) {
    int sum = 0;
    for(int i = 0; i < x; i++) {
        if(sum > 120)
            break;
        sum += i;
    }
    print(sum);
    return sum;
}


int main() {
    return sum_till_x(100);
}