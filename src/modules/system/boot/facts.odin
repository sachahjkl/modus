package boot

// The log facts of the window of the boot (src/md/features/log_facts.md):
// the stages, the memory ranges and the processes that it shows, as a
// record of fields. The fact template is the sentence that the line wrote
// before it was a fact, so a wait of a machine test on that sentence reads
// it as before. No field has the name of a column of the head of facts():
// number, time, process, level.

// The window of the boot drew its first picture of the boot.
@(log_fact = "boot: ok, {stages} stages, {memory_ranges} memory ranges, {processes} processes")
Boot_Shown :: struct {
	stages:        u64,
	memory_ranges: u64,
	processes:     u64,
}
