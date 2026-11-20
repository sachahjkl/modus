package ranges

import "modus:contract/value_kinds"

// The log facts of the test of the range writes of a store
// (src/md/features/log_facts.md): the lines with a value that the helper
// outcome does not write, as records of fields. Each fact template is the
// sentence that the line wrote before it was a fact, so a wait of a
// machine test on that sentence reads it as before. A line of outcome
// stays text: its case is a free sentence. No field has the name of a
// column of the head of facts(): number, time, process, level.

// The commits whose measure the test writes: a closed set, one fact type
// for each, because a template has no condition.
Measured_Commit :: enum {
	Sparse_Object, // The commit of the three writes of the sparse object.
	Scrambled_Writes, // The commit of the 1000 writes at scrambled offsets.
}

// The measure of the commit of the sparse object.
@(log_fact = "ranges: the commit of the sparse object: {changed} blocks changed of {object_blocks}, {hashed_blocks} blocks and {hashed_nodes} object nodes hashed, {written} blocks written, in {elapsed}")
Sparse_Object_Committed :: struct {
	changed:       u64,
	object_blocks: u64,
	hashed_blocks: u64,
	hashed_nodes:  u64,
	written:       u64,
	elapsed:       value_kinds.Time_In_Milliseconds,
}

// The measure of the commit of the 1000 writes at scrambled offsets.
@(log_fact = "ranges: 1000 writes at scrambled offsets, then one commit: {changed} blocks changed of {object_blocks}, {hashed_blocks} blocks and {hashed_nodes} object nodes hashed, {written} blocks written, in {elapsed}")
Scrambled_Writes_Committed :: struct {
	changed:       u64,
	object_blocks: u64,
	hashed_blocks: u64,
	hashed_nodes:  u64,
	written:       u64,
	elapsed:       value_kinds.Time_In_Milliseconds,
}

// The 1000 range writes at scrambled offsets are pending.
@(log_fact = "ranges: 1000 range writes at scrambled offsets are pending, in {elapsed}")
Range_Writes_Pending :: struct {
	elapsed: value_kinds.Time_In_Milliseconds,
}

// The cases of the first run are done.
@(log_fact = "ranges: the cases took {elapsed}")
Cases_Done :: struct {
	elapsed: value_kinds.Time_In_Milliseconds,
}

// The commits of the loop so far, each fifty commits.
@(log_fact = "ranges: loop, {commits} commits of 4 range writes, in {elapsed}")
Loop_Commits_Made :: struct {
	commits: u64,
	elapsed: value_kinds.Time_In_Milliseconds,
}

// The store holds objects: the run after the remount.
@(log_fact = "ranges: a store with {objects} objects: the run after the remount")
Store_Remounted :: struct {
	objects: i64,
}

// The end of the run, with the count of the cases that were wrong.
@(log_fact = "ranges: done, {wrong_cases} wrong")
Run_Done :: struct {
	wrong_cases: u64,
}
