package hierarchy

import op "modus:contract/operation"
import "modus:contract/storage_status"
import "modus:contract/value_kinds"
import "modus:system"

// The log facts of the test of the hierarchy of a store
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
// as the other test modules do. A status of the storage service is the
// word of its contract enum, written by the name of its member. A Text
// field is the last field, and is [N]u8 with N written out, as the
// tool reads it.

// The bytes of the Text field of a verdict: "as it must" has 10 bytes,
// and a zero byte; the record ends on 8 bytes.
VERDICT_FIELD_BYTES :: 16
// The bytes of the Text field of a name that a share refuses: the longest,
// "part_000/../..", has 14 bytes, and a zero byte.
NAME_FIELD_BYTES :: 16

// The verdict of a case: the level of its fact and the words of its field.
Case_Verdict :: struct {
	level: op.Log_Level,
	words: [VERDICT_FIELD_BYTES]u8,
}

// The objects made so far in the first run, each ten trees.
@(log_fact = "hierarchy: {objects} objects made in {commits} commits, in {elapsed}")
Objects_Made :: struct {
	objects: i64,
	commits: u64,
	elapsed: value_kinds.Time_In_Milliseconds,
}

// The store holds no object: the first run.
@(log_fact = "hierarchy: a new store: the first run")
First_Run :: struct {}

// The store holds objects: the run after the remount.
@(log_fact = "hierarchy: a store with {objects} objects: the run after the remount")
Store_Remounted :: struct {
	objects: i64,
}

// The context holds no store.
@(log_fact = "hierarchy: WRONG: no store")
Wrong_No_Store :: struct {}

// The store gave no usage.
@(log_fact = "hierarchy: WRONG: no usage")
Wrong_No_Usage :: struct {}

// The end of the run, with the count of the cases that were wrong.
@(log_fact = "hierarchy: done, {wrong_cases} wrong")
Run_Done :: struct {
	wrong_cases: u64,
}

// The add of the top trees failed.
@(log_fact = "hierarchy: the top trees: status {status}: {verdict}")
Top_Trees_Refused :: struct {
	status: storage_status.Status_Word,
	verdict:        [16]u8,
}

// The open of a top tree failed.
@(log_fact = "hierarchy: open a top tree: status {status}: {verdict}")
Top_Tree_Open_Refused :: struct {
	status: storage_status.Status_Word,
	verdict:        [16]u8,
}

// The open of a part failed.
@(log_fact = "hierarchy: open a part: status {status}: {verdict}")
Part_Open_Refused :: struct {
	status: storage_status.Status_Word,
	verdict:        [16]u8,
}

// The add of the objects of a part failed.
@(log_fact = "hierarchy: add the objects of a part: status {status}: {verdict}")
Part_Objects_Refused :: struct {
	status: storage_status.Status_Word,
	verdict:        [16]u8,
}

// The trees and objects of the first run, made.
@(log_fact = "hierarchy: made {objects} objects and {trees} trees in {commits} commits, in {elapsed}, {blocks} blocks: {verdict}")
Trees_Made :: struct {
	objects: i64,
	trees:   i64,
	commits: u64,
	elapsed: value_kinds.Time_In_Milliseconds,
	blocks:  i64,
	verdict: [16]u8,
}

// The root, listed in pages.
@(log_fact = "hierarchy: the root in pages of 16: {trees} trees, in order: {verdict}")
Root_Listed :: struct {
	trees:   i64,
	verdict: [16]u8,
}

// Every part, listed in pages.
@(log_fact = "hierarchy: listed {objects} objects in {trees} trees in pages of 16, each page after the one before, in {elapsed}: {verdict}")
Parts_Listed :: struct {
	objects: i64,
	trees:   i64,
	elapsed: value_kinds.Time_In_Milliseconds,
	verdict: [16]u8,
}

// An object renamed to the root.
@(log_fact = "hierarchy: rename of an object to the root: the part has {objects} objects: {verdict}")
Object_Renamed :: struct {
	objects: i64,
	verdict: [16]u8,
}

// A tree renamed, in one commit.
@(log_fact = "hierarchy: rename of a tree of {trees} trees and {objects} objects: one commit: {verdict}")
Tree_Renamed :: struct {
	trees:   i64,
	objects: i64,
	verdict: [16]u8,
}

// A move of a tree inside itself, refused.
@(log_fact = "hierarchy: a tree cannot move inside itself: {verdict}")
Move_Inside_Refused :: struct {
	verdict: [16]u8,
}

// A rename onto a name that exists, refused.
@(log_fact = "hierarchy: a rename onto a name that exists is refused: {verdict}")
Rename_Onto_Name_Refused :: struct {
	verdict: [16]u8,
}

// A tree removed: its name is gone at its commit.
@(log_fact = "hierarchy: remove of a tree: the name is gone at its commit; {removing} trees wait to be freed: {verdict}")
Tree_Removed :: struct {
	removing: i64,
	verdict:  [16]u8,
}

// The removal of a tree freed its objects, its trees and its blocks.
@(log_fact = "hierarchy: the removal freed {objects} objects, {trees} trees and {blocks} blocks, in {elapsed}: {verdict}")
Removal_Freed :: struct {
	objects: i64,
	trees:   i64,
	blocks:  i64,
	elapsed: value_kinds.Time_In_Milliseconds,
	verdict: [16]u8,
}

// What the first run leaves.
@(log_fact = "hierarchy: the first run leaves {objects} objects and {trees} trees: {verdict}")
First_Run_Left :: struct {
	objects: i64,
	trees:   i64,
	verdict: [16]u8,
}

// The add or the open of the tree of the scrambled names failed.
@(log_fact = "hierarchy: the tree scrambled: status {status} {open_status}: {verdict}")
Scrambled_Tree_Refused :: struct {
	status:      storage_status.Status_Word,
	open_status: storage_status.Status_Word,
	verdict:             [16]u8,
}

// An add of the scrambled names failed.
@(log_fact = "hierarchy: the scrambled adds: status {status}: {verdict}")
Scrambled_Adds_Refused :: struct {
	status: storage_status.Status_Word,
	verdict:        [16]u8,
}

// The scrambled names: added, listed in order, read back, half removed.
@(log_fact = "hierarchy: added {added} names in a scrambled order in {commits} commits, listed in order, each read back; removed {removed} in another order, {left} left in order, in {elapsed}: {verdict}")
Scrambled_Names_Checked :: struct {
	added:   i64,
	commits: u64,
	removed: i64,
	left:    i64,
	elapsed: value_kinds.Time_In_Milliseconds,
	verdict: [16]u8,
}

// A writable share counts the blocks of its own tree only.
@(log_fact = "hierarchy: while a writable share of a tree is open, its write took {share_took} blocks of the count of its tree; the same bytes written by the maker outside the tree took {maker_took} blocks of the store and {share_saw} of the count of the share; the removal through the share freed {freed}: the share sees the count of its own tree only: {verdict}")
Share_Count_Checked :: struct {
	share_took: i64,
	maker_took: i64,
	share_saw:  i64,
	freed:      i64,
	verdict:    [16]u8,
}

// After unshare, the guess of the holder stays out of the hash index.
@(log_fact = "hierarchy: after unshare, the guess of the holder stays hidden: the same bytes written by the maker took {maker_took} blocks: {verdict}")
Guess_Hidden :: struct {
	maker_took: i64,
	verdict:    [16]u8,
}

// A read-only share of a tree, made.
@(log_fact = "hierarchy: a read-only share of tree_003: {verdict}")
Read_Only_Share_Made :: struct {
	verdict: [16]u8,
}

// The share lists the trees of its tree only.
@(log_fact = "hierarchy: the share lists the {trees} trees of tree_003 only: {verdict}")
Share_Listed :: struct {
	trees:   i64,
	verdict: [16]u8,
}

// A name that leaves the tree of the share, refused.
@(log_fact = "hierarchy: the name \"{name}\" is refused: {verdict}")
Name_Refused :: struct {
	name:    [16]u8,
	verdict: [16]u8,
}

// A place of another connection names nothing on the share.
@(log_fact = "hierarchy: a place of another connection names nothing on the share: {verdict}")
Foreign_Place_Refused :: struct {
	verdict: [16]u8,
}

// A name of another store, refused.
@(log_fact = "hierarchy: a name of another store is refused: {verdict}")
Foreign_Store_Refused :: struct {
	verdict: [16]u8,
}

// A write through the read-only share, refused.
@(log_fact = "hierarchy: the read-only share cannot write: {verdict}")
Read_Only_Write_Refused :: struct {
	verdict: [16]u8,
}

// A remove through the read-only share, refused.
@(log_fact = "hierarchy: the read-only share cannot remove: {verdict}")
Read_Only_Remove_Refused :: struct {
	verdict: [16]u8,
}

// After unshare, a call through the share gives Gone.
@(log_fact = "hierarchy: after unshare, the handles of the share are revoked: a call gives Gone: {verdict}")
Share_Handles_Revoked :: struct {
	verdict: [16]u8,
}

// A writable share writes, and the maker reads the write.
@(log_fact = "hierarchy: a writable share writes in tree_005, and the maker reads it: {verdict}")
Writable_Share_Written :: struct {
	verdict: [16]u8,
}

// A share of a tree cannot open the root of its own store.
@(log_fact = "hierarchy: a share of a tree cannot open the root of its own store: {verdict}")
Share_Root_Refused :: struct {
	verdict: [16]u8,
}

// After the remount: the counts of the store.
@(log_fact = "hierarchy: after the remount: {objects} objects and {trees} trees: {verdict}")
Remount_Counted :: struct {
	objects: i64,
	trees:   i64,
	verdict: [16]u8,
}

// After the remount: the scrambled names left, in order.
@(log_fact = "hierarchy: after the remount: {left} scrambled names left, in order: {verdict}")
Remount_Scrambled_Left :: struct {
	left:    i64,
	verdict: [16]u8,
}

// After the remount: the parts listed, the contents read back.
@(log_fact = "hierarchy: after the remount: {objects} objects listed in the parts, {contents} contents byte for byte, the renamed tree and object in their places, in {elapsed}: {verdict}")
Remount_Parts_Listed :: struct {
	objects:  i64,
	contents: i64,
	elapsed:  value_kinds.Time_In_Milliseconds,
	verdict:  [16]u8,
}

#assert(size_of(Read_Only_Share_Made) == VERDICT_FIELD_BYTES)
#assert(size_of(Name_Refused) == NAME_FIELD_BYTES + VERDICT_FIELD_BYTES)

// outcome gives the verdict of a case, and counts a case that failed: the
// level Info and "as it must", or the level Error and "WRONG".
outcome :: proc "contextless" (good: bool) -> Case_Verdict {
	if !good {
		wrong_cases += 1
		return {level = .Error, words = value_kinds.text_field("WRONG", VERDICT_FIELD_BYTES)}
	}
	return {level = .Info, words = value_kinds.text_field("as it must", VERDICT_FIELD_BYTES)}
}

// name_field gives the Text field of a name that a share refuses.
name_field :: proc "contextless" (name: string) -> [NAME_FIELD_BYTES]u8 {
	return value_kinds.text_field(name, NAME_FIELD_BYTES)
}

// elapsed_since gives the milliseconds since a time of the system clock,
// as a field of a time.
elapsed_since :: proc "contextless" (start: u64) -> value_kinds.Time_In_Milliseconds {
	return value_kinds.Time_In_Milliseconds(system.time() - start)
}
