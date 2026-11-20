package counters

import op "modus:contract/operation"

// The log facts of the demonstration counters (src/md/features/log_facts.md,
// "The facts of the demonstrations"): its cases, its failures and its
// measures, as records of fields. Each fact template is the sentence that
// the line wrote before it was a fact, so a wait of a machine test on that
// sentence, and the check of the tool after the run, read it as before. A
// Text field comes last, and holds its longest text and a zero byte.
//
// The status of a failure is the number of its word, as the line wrote it:
// `status_word` is a plain Integer. The status that a case expected is the
// name of its member, as the line wrote it: a field of the contract enum.

// A step gave a status that stops the demonstration.
@(log_fact = "counters: failed: {step} gave {status_word}")
Step_Failed :: struct {
	status_word: u64,
	step:        [56]u8,
}

// A step that the kernel must refuse gave another status than the
// refusal.
@(log_fact = "counters: failed: {refused_step} gave {status_word}, not {expected}")
Step_Not_Refused :: struct {
	status_word:  u64,
	expected:     op.Status,
	refused_step: [68]u8,
}

// The loop of known length retired fewer instructions than its stores.
@(log_fact = "counters: failed: a loop of {turns} turns retired {instructions} instructions, fewer than {least_instructions}; {cycles} cycles, {cache_misses} cache misses, {branch_misses} branch misses")
Loop_Too_Short :: struct {
	turns:              u64,
	instructions:       u64,
	least_instructions: u64,
	cycles:             u64,
	cache_misses:       u64,
	branch_misses:      u64,
}

// The two orders of the reads read other words.
@(log_fact = "counters: failed: the two orders read other words: {sum_in_order} and {sum_by_page}")
Orders_Read_Other_Words :: struct {
	sum_in_order: u64,
	sum_by_page:  u64,
}

// The loop of known length retired at least its stores.
@(log_fact = "counters: a loop of {turns} turns retired at least {least_instructions} instructions: as it must")
Loop_Retired :: struct {
	turns:              u64,
	least_instructions: u64,
}

// The two orders of the reads read the same words.
@(log_fact = "counters: {reads} reads of {word_bytes} bytes in {region_pages} pages, in order and by page, read the same words: as it must")
Orders_Read_Same_Words :: struct {
	reads:        u64,
	word_bytes:   u64,
	region_pages: u64,
}

// The four counts of one measure: the loop, the reads in order, the reads
// by page.
@(log_fact = "counters: {measure} (a measure): {instructions} instructions retired, {cycles} cycles, {cache_misses} cache misses, {branch_misses} branch misses")
Counts_Measured :: struct {
	instructions:  u64,
	cycles:        u64,
	cache_misses:  u64,
	branch_misses: u64,
	measure:       [24]u8,
}
