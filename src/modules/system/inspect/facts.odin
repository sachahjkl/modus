package inspect

import "modus:contract/value_kinds"
import "modus:system"

// The log facts of inspect (src/md/features/log_facts.md, "The
// migration"): each line, as a record of fields. Each fact
// template is the sentence that the line wrote before it was a fact, so a
// wait of a machine test on that sentence reads it as before. The name of a
// process is a Module_Name_Field, the last field: the serial line of a fact
// stops at its last byte that is not zero.

// A module record of the chosen process whose writer word names no
// writer: the row of modules() leaves its writer empty.
@(log_fact = "inspect: the module record at {base} has the writer word {writer_word}, which names no writer")
Module_Writer_Refused :: struct {
	base:        u64,
	writer_word: u64,
}

// A new process took the slot between two reports: the sample mixes two
// processes, and the window keeps the sample before.
@(log_fact = "inspect: a sample mixed two processes of slot {slot}: dropped, {dropped} in all")
Sample_Mixed :: struct {
	slot:    u64,
	dropped: u64,
}

// The counts of the chosen process, from its reports, beside the counts
// that the kernel gives: the test compares them with the reports of
// monitor.
@(log_fact = "inspect: {sampled_process}: {mappings} mappings, {mapped_pages} mapped pages, {present_pages} with a frame, {threads} threads, {modules} modules; the kernel says {kernel_mapped_pages} mapped pages and {kernel_threads} threads")
Process_Counts :: struct {
	mappings:            u64,
	mapped_pages:        u64,
	present_pages:       u64,
	threads:             u64,
	modules:             u64,
	kernel_mapped_pages: u64,
	kernel_threads:      u64,
	sampled_process:     value_kinds.Module_Name_Field,
}

// The cost of one sample of the chosen process.
@(log_fact = "inspect: one sample of {sampled_process} took {elapsed} and {kernel_entries} kernel entries")
Sample_Cost :: struct {
	elapsed:         value_kinds.Time_In_Microseconds,
	kernel_entries:  u64,
	sampled_process: value_kinds.Module_Name_Field,
}

// The space key froze the sample, or made it live again.
@(log_fact = "inspect: the sample is {sample_state}")
Sample_State_Changed :: struct {
	sample_state: [8]u8,
}

// The filter is empty again: the list shows each process.
@(log_fact = "inspect: the list shows all {processes} processes")
Filter_Emptied :: struct {
	processes: u64,
}

// The window is open: the processes of the list, and its keys.
@(log_fact = "inspect: ok, {processes} processes; up, down, letters: choose; space: freeze; tab: the bytes of its own memory")
Window_Ready :: struct {
	processes: u64,
}

// The twentieth frame of the window in a measure run: the records of the
// interface, the damage rectangles of the twenty frames, and the times of
// the last frame.
@(log_fact = "inspect: the interface: {records} records; 20 frames with {damage_rectangles} damage rectangles in all; the last frame: build {build_time}, difference {difference_time}, draw {draw_time}")
Interface_Measured :: struct {
	records:           u64,
	damage_rectangles: u64,
	build_time:        value_kinds.Time_In_Microseconds,
	difference_time:   value_kinds.Time_In_Microseconds,
	draw_time:         value_kinds.Time_In_Microseconds,
}

// The chosen process stopped on a page fault: the address that the
// instruction used.
@(log_fact = "inspect: {sampled_process} stopped: page fault at {address}")
Stopped_On_Page_Fault :: struct {
	address:         value_kinds.Hexadecimal_No_Leading_Zero,
	sampled_process: value_kinds.Module_Name_Field,
}

// The chosen process stopped on another fault.
@(log_fact = "inspect: {sampled_process} stopped: fault {address}")
Stopped_On_Fault :: struct {
	address:         value_kinds.Hexadecimal_No_Leading_Zero,
	sampled_process: value_kinds.Module_Name_Field,
}

// One frame of the stack of a stop, from frame 0, the instruction: its
// place as the window names it, a text view.
@(log_fact = "inspect: {sampled_process}, the frame {frame} of the stack: {place}")
Stack_Frame :: struct {
	frame:           u64,
	sampled_process: value_kinds.Module_Name_Field,
	place:           value_kinds.Text_View,
}

// The kernel hid values of the stop report.
@(log_fact = "inspect: {sampled_process}: values hidden by the kernel: {hidden_values}")
Values_Hidden :: struct {
	hidden_values:   u64,
	sampled_process: value_kinds.Module_Name_Field,
}

// The tab key shows the bytes of the memory of inspect itself.
@(log_fact = "inspect: the bytes of the memory of inspect")
Own_Memory_Shown :: struct {}

// The tab key shows the reports of the chosen process again.
@(log_fact = "inspect: the reports of {sampled_process}")
Reports_Shown :: struct {
	sampled_process: value_kinds.Module_Name_Field,
}

// The Text field of the words of the state of the sample: "frozen" or
// "live", and a zero byte.
SAMPLE_STATE_FIELD_BYTES :: 8

// process_field gives the field of the name of the chosen process: its
// text before the first zero byte.
process_field :: proc "contextless" (name: []u8) -> value_kinds.Module_Name_Field {
	return value_kinds.module_name_field(system.name_of(name))
}
