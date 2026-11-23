// The count of steps of the Collatz sequence from n to 1: the first
// program of the system described as a Lex project
// (src/md/features/application_projects.md). A start of 0 or below has no
// sequence, and gives -1.
long steps(long n) {
	if (n <= 0) {
		return -1;
	}
	long count = 0;
	while (n != 1) {
		if (n % 2 == 0) {
			n = n / 2;
		} else {
			n = 3 * n + 1;
		}
		count = count + 1;
	}
	return count;
}
