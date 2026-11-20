package ranges

import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "modus:support/system"

// The log facts of the test of the range writes of a store
// (src/md/features/log_facts.md): each line, as a record of fields. Each
// fact template is the sentence that the line wrote before it was a fact,
// so a wait of a machine test on that sentence reads it as before. No
// field has the name of a column of the head of facts(): number, time,
// process, level.
//
// Each case is one fact type, because a template has no condition: its
// values, then its verdict, a Text field that holds "as it must" or
// "WRONG" (outcome). `where(verdict = "WRONG")` keeps the cases that
// failed. A case that fails writes its verdict at the end of its sentence,
// as the other test modules do. A Text field is the last field, and is
// [N]u8 with N written out, as the tool reads it.

// The bytes of the Text field of a verdict: "as it must" has 10 bytes,
// and a zero byte; the record ends on 8 bytes.
VERDICT_FIELD_BYTES :: 16

// The verdict of a case: the level of its fact and the words of its field.
Case_Verdict :: struct {
	level: op.Log_Level,
	words: [VERDICT_FIELD_BYTES]u8,
}

// outcome gives the verdict of a case, and counts a case that failed: the
// level Info and "as it must", or the level Error and "WRONG".
outcome :: proc "contextless" (good: bool) -> Case_Verdict {
	if !good {
		wrong_cases += 1
		return {level = .Error, words = value_kinds.text_field("WRONG", VERDICT_FIELD_BYTES)}
	}
	return {level = .Info, words = value_kinds.text_field("as it must", VERDICT_FIELD_BYTES)}
}

// The store holds no object: the first run.
@(log_fact = "ranges: a new store: the first run")
First_Run :: struct {}

// The context holds no store.
@(log_fact = "ranges: WRONG: no store")
Wrong_No_Store :: struct {}

// The store gave no usage.
@(log_fact = "ranges: WRONG: no usage")
Wrong_No_Usage :: struct {}

// Three range writes are pending on the sparse object.
@(log_fact = "ranges: three range writes are pending, and the size of the object is {size} bytes: {verdict}")
Writes_Pending :: struct {
	size:    u64,
	verdict: [16]u8,
}

// The sparse object holds few blocks after its commit.
@(log_fact = "ranges: a sparse object of 8 GiB from 3 writes and one commit holds {held_blocks} blocks: {verdict}")
Sparse_Object_Held :: struct {
	held_blocks: u64,
	verdict:     [16]u8,
}

// The blocks of the sparse object, a hole and an edge, read back.
@(log_fact = "ranges: its three blocks read back, a hole reads as zero bytes, and a read across a block edge gives the end of a block and zero bytes: {verdict}")
Sparse_Object_Read :: struct {
	verdict: [16]u8,
}

// The commit of the scrambled writes hashed what they touched only.
@(log_fact = "ranges: the commit of 1000 scrambled writes hashed {hashed_blocks} blocks and {hashed_nodes} object nodes, bounded by the blocks changed, not by the {object_blocks} blocks of the object: {verdict}")
Scrambled_Commit_Bounded :: struct {
	hashed_blocks: u64,
	hashed_nodes:  u64,
	object_blocks: u64,
	verdict:       [16]u8,
}

// The scrambled writes and the blocks before them, read back.
@(log_fact = "ranges: the 1000 writes read back, each one byte for byte, and the three blocks before them: {verdict}")
Scrambled_Writes_Read :: struct {
	verdict: [16]u8,
}

// The version before the scrambled writes holds few blocks of its own.
@(log_fact = "ranges: the version before the 1000 writes holds {own_blocks} blocks of its own: the root and the path of the first block; its other blocks are shared with the new state: {verdict}")
Version_Blocks_Shared :: struct {
	own_blocks: i64,
	verdict:    [16]u8,
}

// An old version reads its old bytes, and compare gives the one range.
@(log_fact = "ranges: an old version reads its old bytes after a range write, and compare gives the one range written: {verdict}")
Old_Version_Read :: struct {
	verdict: [16]u8,
}

// A cut and an extension of an object.
@(log_fact = "ranges: a cut of an object of 70 blocks to 6000 bytes holds {cut_blocks} blocks; an extension to 1 GiB holds {extended_blocks} blocks, and reads zero bytes past the cut: {verdict}")
Cut_And_Extension :: struct {
	cut_blocks:      u64,
	extended_blocks: u64,
	verdict:         [16]u8,
}

// A read at the end, and a read past the end, refused.
@(log_fact = "ranges: a read at the end gives no byte, and a read past the end is refused: {verdict}")
End_Read :: struct {
	verdict: [16]u8,
}

// A place of another store, of no connection, and an empty commit, refused.
@(log_fact = "ranges: a place of another store, a place of no connection, and a commit with no pending change are refused: {verdict}")
Places_Refused :: struct {
	verdict: [16]u8,
}

// A commit after another change of the object, refused.
@(log_fact = "ranges: a commit after another change of the object is refused, and its pending changes are dropped: {verdict}")
Conflict_Refused :: struct {
	verdict: [16]u8,
}

// The same object under two names holds the blocks of one.
@(log_fact = "ranges: the same object of 1 MiB under two names holds {held_blocks} blocks of the store, one object's worth; the second commit wrote {written_blocks} blocks of its block tree: {verdict}")
Twin_Held :: struct {
	held_blocks:    u64,
	written_blocks: u64,
	verdict:        [16]u8,
}

// A change of one block of the second name.
@(log_fact = "ranges: a change of one block of the second name wrote {written_blocks} blocks of its block tree; the first name reads its bytes as before: {verdict}")
Twin_Changed :: struct {
	written_blocks: u64,
	verdict:        [16]u8,
}

// The removal of the second name.
@(log_fact = "ranges: the removal of the second name frees its own blocks only, the first name reads its 1 MiB, and the second name written again takes no block: {verdict}")
Twin_Removed :: struct {
	verdict: [16]u8,
}

// The loop of range commits.
@(log_fact = "ranges: the loop made {commits} commits of range writes: {verdict}")
Loop_Done :: struct {
	commits: u64,
	verdict: [16]u8,
}

// After the remount: the sparse object.
@(log_fact = "ranges: after the remount: the sparse object of {size} bytes reads its 3 blocks and its 1000 writes, byte for byte: {verdict}")
Remount_Sparse_Read :: struct {
	size:    u64,
	verdict: [16]u8,
}

// After the remount: the small object, the cut and the loop.
@(log_fact = "ranges: after the remount: the small object, the object of the cut and the object of the loop: {verdict}")
Remount_Objects_Read :: struct {
	verdict: [16]u8,
}

// After the remount: the same object under a third name takes no block.
@(log_fact = "ranges: after the remount: the same object of 1 MiB under a third name took no block: the open found it by its hash: {verdict}")
Remount_Twin_Found :: struct {
	verdict: [16]u8,
}

#assert(size_of(Sparse_Object_Read) == VERDICT_FIELD_BYTES)

// elapsed_since gives the milliseconds since a time of the system clock,
// as a field of a time.
elapsed_since :: proc "contextless" (start: u64) -> value_kinds.Time_In_Milliseconds {
	return value_kinds.Time_In_Milliseconds(system.time() - start)
}

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
