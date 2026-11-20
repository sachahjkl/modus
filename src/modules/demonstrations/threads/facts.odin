package threads

// The log facts of threads (src/md/features/log_facts.md): each fact
// template is the line that the process wrote before it was a fact, so a
// wait of a machine test on that sentence reads it as before.

// The kernel refused a thread of the process.
@(log_fact = "threads: cannot start a thread")
Thread_Not_Started :: struct {}

// A thread added the numbers up to 1000 and gave the sum to the first
// thread.
@(log_fact = "threads: a thread added the numbers to 1000: {result}")
Sum_Added :: struct {
	result: u64,
}

// A key ended a thread that draws.
@(log_fact = "threads: thread {thread} stopped at frame {frame}")
Thread_Stopped :: struct {
	thread: u64,
	frame:  u64,
}

// A key started a thread that draws again.
@(log_fact = "threads: thread {thread} started")
Thread_Started :: struct {
	thread: u64,
}

// The threads draw in one surface.
@(log_fact = "threads: ok, {threads} threads draw in one surface")
Threads_Drawing :: struct {
	threads: u64,
}
