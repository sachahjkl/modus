package processors

import "modus:contract/value_kinds"

// The log facts of processors (src/md/features/log_facts.md): each fact
// template is the line that the process wrote before it was a fact, so a
// wait of a machine test on that sentence reads it as before.

// The kernel refused a thread of the process.
@(log_fact = "processors: cannot start a thread")
Thread_Not_Started :: struct {}

// The process has no grant to inspect the machine.
@(log_fact = "processors: no grant to inspect the machine")
No_Inspect_Grant :: struct {}

// Each processor that the process can use ran it at one time.
@(log_fact = "processors: ok, {together} processors ran the process at the same time")
Processors_Together :: struct {
	together: u64,
}

// Fewer processors than the process can use ran it at one time.
@(log_fact = "processors: at most {together} of {processors} processors ran the process at the same time")
Processors_Together_At_Most :: struct {
	together:   u64,
	processors: u64,
}

// The time of one picture computed by 1, 2 and 4 threads.
@(log_fact = "processors: the picture took {one_thread} with 1 thread, {two_threads} with 2 threads, {four_threads} with 4 threads")
Picture_Timed :: struct {
	one_thread:   value_kinds.Time_In_Milliseconds,
	two_threads:  value_kinds.Time_In_Milliseconds,
	four_threads: value_kinds.Time_In_Milliseconds,
}
