package pages

import "modus:contract/value_kinds"

// The log facts of the window of the page tables
// (src/md/features/log_facts.md): the mappings of the kernel half and of
// this process, as records of fields. Each fact template is the sentence
// that the line wrote before it was a fact, so a wait of a machine test on
// that sentence reads it as before. No field has the name of a column of
// the head of facts(): number, time, process, level.
//
// A count of pages that the line writes as "N pages" is a Size in pages;
// the guard pages and the pages that can be written and executed are
// plain counts, because the line writes other words after their number.

// The mappings of the kernel half.
@(log_fact = "pages: the kernel half: {mapped} in {runs} runs, {write_execute_pages} write and execute, {guard_pages} guard pages of {guards_expected}")
Kernel_Half_Read :: struct {
	mapped:              value_kinds.Size_In_Pages,
	runs:                u64,
	write_execute_pages: u64,
	guard_pages:         u64,
	guards_expected:     u64,
}

// The page tables keep the rules.
@(log_fact = "pages: ok, the page tables keep the rules")
Rules_Kept :: struct {}

// The page tables do not keep the rules.
@(log_fact = "pages: failed, the page tables do not keep the rules")
Rules_Not_Kept :: struct {}

// The processor refuses the memory of processes to the kernel.
@(log_fact = "pages: the processor refuses the memory of processes to the kernel")
Kernel_Guard_Present :: struct {}

// The processor has no guard for the memory of processes.
@(log_fact = "pages: the processor has no guard for the memory of processes")
Kernel_Guard_Absent :: struct {}

// The mappings of the half of this process.
@(log_fact = "pages: this process: {mapped} in {runs} runs, {write_execute_pages} write and execute")
Process_Half_Read :: struct {
	mapped:              value_kinds.Size_In_Pages,
	runs:                u64,
	write_execute_pages: u64,
}
