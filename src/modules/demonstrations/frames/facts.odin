package frames

import op "modus:contract/operation"

// The log facts of the demonstration frames (src/md/features/log_facts.md,
// "The facts of the demonstrations"): its measures and its cases, as
// records of fields. Each fact template is the sentence that the line wrote
// before it was a fact, so a wait of a machine test on that sentence reads
// it as before. A Text field comes last, and holds its longest text and a
// zero byte.

// A twin did not start: the word of the status.
@(log_fact = "frames: cannot start a twin: status {status_word}")
Twin_Not_Started :: struct {
	status_word: op.Status_Word,
}

// The pages of 4 twins with a copy of the module each, and with the shared
// code.
@(log_fact = "frames: 4 twins: {own_copy_pages} pages with a copy of the module each, {shared_code_pages} pages with the shared code ({module_pages} pages of the module, once)")
Twins_Paid :: struct {
	own_copy_pages:    u64,
	shared_code_pages: u64,
	module_pages:      u64,
}

// The measure of a create and a map of 8192 pages.
@(log_fact = "frames: create and map 8192 pages: {frames_now} us with each frame now, {frames_on_first_use} us with pages on first use")
Create_And_Map_Measured :: struct {
	frames_now:          u64,
	frames_on_first_use: u64,
}

// The measure of the first use of a page, and of a write to a page with
// its frame.
@(log_fact = "frames: the first use of a page: {first_use} ns; a write to a page that has its frame: {write_present} ns")
First_Use_Measured :: struct {
	first_use:     u64,
	write_present: u64,
}

// The measure of the start of a twin.
@(log_fact = "frames: start a twin: {own_copy_start} us with its own copy of the module, {shared_code_start} us with the shared code")
Twin_Start_Measured :: struct {
	own_copy_start:    u64,
	shared_code_start: u64,
}

// A case whose answer is not what the rules give.
@(log_fact = "frames: wrong answer: {case_text}: {answer}")
Wrong_Answer :: struct {
	case_text: [48]u8,
	answer:    [56]u8,
}

// Each case gave its answer.
@(log_fact = "frames: ok, {cases} cases")
Frames_Held :: struct {
	cases: u64,
}

// The context has no random seed: the process gives the seed of each twin,
// and stops with Refused.
@(log_fact = "frames: no random seed in the context")
No_Random_Seed :: struct {}
