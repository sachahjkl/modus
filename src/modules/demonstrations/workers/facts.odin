package workers

// The log facts of workers (src/md/features/log_facts.md): each fact
// template is the line that the process wrote before it was a fact, so a
// wait of a machine test on that sentence reads it as before.

// The lock lost no addition: the number is the count of additions.
@(log_fact = "workers: the lock lost no addition")
No_Addition_Lost :: struct {}

// The kernel refused a thread of the process.
@(log_fact = "workers: cannot start a thread")
Thread_Not_Started :: struct {}

// Four threads added under the lock: the additions, the number, and the
// waits for the lock.
@(log_fact = "workers: with the lock, 4 threads made {additions} additions: the number is {sum}, {waits} waits")
Locked_Additions :: struct {
	additions: u64,
	sum:       u64,
	waits:     u64,
}

// Four threads added with no lock: the number loses additions.
@(log_fact = "workers: with no lock, 4 threads made {additions} additions: the number is {sum}")
Free_Additions :: struct {
	additions: u64,
	sum:       u64,
}

// The four threads computed the tiles of the first picture: the tiles of
// each thread.
@(log_fact = "workers: ok, 4 threads computed {tiles} tiles: {first_thread} {second_thread} {third_thread} {fourth_thread}")
Tiles_Computed :: struct {
	tiles:         u64,
	first_thread:  u64,
	second_thread: u64,
	third_thread:  u64,
	fourth_thread: u64,
}
