package hierarchy

import "modus:contract/value_kinds"

// The log facts of the test of the hierarchy of a store
// (src/md/features/log_facts.md): the lines with a value that the helper
// outcome does not write, as records of fields. Each fact template is the
// sentence that the line wrote before it was a fact, so a wait of a
// machine test on that sentence reads it as before. A line of outcome
// stays text: its case is a free sentence. No field has the name of a
// column of the head of facts(): number, time, process, level.

// The objects made so far in the first run, each ten trees.
@(log_fact = "hierarchy: {objects} objects made in {commits} commits, in {elapsed}")
Objects_Made :: struct {
	objects: i64,
	commits: u64,
	elapsed: value_kinds.Time_In_Milliseconds,
}

// The store holds objects: the run after the remount.
@(log_fact = "hierarchy: a store with {objects} objects: the run after the remount")
Store_Remounted :: struct {
	objects: i64,
}

// The end of the run, with the count of the cases that were wrong.
@(log_fact = "hierarchy: done, {wrong_cases} wrong")
Run_Done :: struct {
	wrong_cases: u64,
}
