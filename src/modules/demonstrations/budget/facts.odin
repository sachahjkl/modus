package budget

// The log facts of the demonstration budget (src/md/features/log_facts.md,
// "The facts of the demonstrations"). Each fact template is the sentence
// that the line wrote before it was a fact, so a wait of a machine test on
// that sentence reads it as before. A Text field comes last, and holds its
// longest text and a zero byte.

// A step whose answer or whose pages are not what the rules give: what it
// asked, the answer of the kernel, and the pages that the budget holds
// after it.
@(log_fact = "budget: wrong answer: {step}: {answer}, {pages} pages")
Wrong_Answer :: struct {
	pages:  u64,
	step:   [48]u8,
	answer: [48]u8,
}

// Each step gave its answer: the objects and the threads that the budget
// paid for before it refused.
@(log_fact = "budget: ok, {memory_objects} memory objects then no budget, {threads} threads then no budget, each page returned")
Budget_Held :: struct {
	memory_objects: u64,
	threads:        u64,
}
