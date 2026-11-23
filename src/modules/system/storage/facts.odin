package storage_service

import "modus:contract/errors"
import op "modus:contract/operation"
import format "modus:contract/store"
import "modus:contract/value_kinds"

// The log facts of the storage service (src/md/features/log_facts.md, "The
// facts of the storage service and of the disk"): the lines of the disk,
// the commits, the open and the stores that a reader groups or filters, as
// records of fields. Each fact template is the sentence that the line
// wrote before it was a fact, so a wait of a machine test on that sentence
// reads it as before. A line whose sentence differs by its case (one
// block or several, a share that reads only) is one fact type for each
// case: the template has no condition. No field has the name of a column
// of the head of facts(): number, time, process, level.
//
// A store name is a Text field after the fields of numbers: the serial
// line of a fact stops at its last byte that is not zero, so the zeros
// after a short name cost no byte. A store name has at most NAME_CAPACITY
// bytes: its field holds the longest one and a zero byte. An object name
// has up to format.ENTRY_NAME_CAPACITY bytes, more than one record of a
// fact holds with its numbers: it is a text view, the last field, whose
// text a long name carries in the out-of-line area of its fact.

// The bytes of the Text field of a store name.
STORE_FIELD_BYTES :: 40
// The bytes of the Text field of the cause of a silent disk: its longest
// cause, and a zero byte.
DISK_SILENT_CAUSE_BYTES :: 72

// The disk does not answer: the service reads and changes nothing on the
// disk until its next start. The cause is a Text field: Disk_Silence is an
// enum of this module, whose members a reader cannot name, and one of its
// sentences holds the bound of the wait. One fact type keeps the one event:
// facts(storage_service.Disk_Silent) gives each silence.
@(log_fact = "storage: the disk does not answer: {cause}; the service reads and changes nothing on the disk until its next start, and refuses each call that needs the disk")
Disk_Silent :: struct {
	cause: [72]u8,
}

// A node of a tree of a store has a wrong check or breaks a rule of the
// format: the store is damaged.
@(log_fact = "storage: a node of a tree of the store {store} has a wrong check or breaks a rule of the format: the service changes nothing more in the store")
Tree_Node_Damaged :: struct {
	store: [40]u8,
}

// A commit would take a count of names of a block below 0: a fault of the
// engine, and the store changes no more until the next start.
@(log_fact = "storage: a fault of the engine: a commit would take a count of names of a block below 0; the service makes no change in the store {store} until its next start, which counts again")
Commit_Count_Below_Zero :: struct {
	store: [40]u8,
}

// The read back of the blocks of a commit found one block that the disk did
// not keep: the commit is refused before its root.
@(log_fact = "storage: the read back of the commit of generation {generation} found 1 block with other bytes: the disk did not keep it; the commit is refused before its root, and the service goes on from generation {generation_before}")
Commit_Block_Dropped :: struct {
	generation:        u64,
	generation_before: u64,
}

// The read back of the blocks of a commit found several blocks that the
// disk did not keep.
@(log_fact = "storage: the read back of the commit of generation {generation} found {blocks} blocks with other bytes: the disk did not keep them; the commit is refused before its root, and the service goes on from generation {generation_before}")
Commit_Blocks_Dropped :: struct {
	generation:        u64,
	blocks:            u64,
	generation_before: u64,
}

// The read back of the blocks of a commit failed on the device.
@(log_fact = "storage: the read back of the commit of generation {generation} failed on the device: the commit is refused before its root")
Commit_Read_Back_Failed :: struct {
	generation: u64,
}

// The read back of the root of a commit found other bytes: the root before
// stays the newest on the disk.
@(log_fact = "storage: the read back of the root of the commit of generation {generation} found other bytes: the disk did not keep it; the commit is refused, and the service goes on from generation {generation_before}")
Commit_Root_Dropped :: struct {
	generation:        u64,
	generation_before: u64,
}

// The write of the root of a commit failed on the device: the root can be
// on the disk or not.
@(log_fact = "storage: the root of the commit of generation {generation}: its write failed on the device; the commit is not taken, the open of the next start decides, and the service makes no change until then")
Root_Write_Failed :: struct {
	generation: u64,
}

// The read back of the root of a commit failed on the device: the root can
// be on the disk or not.
@(log_fact = "storage: the root of the commit of generation {generation}: its read back failed on the device; the commit is not taken, the open of the next start decides, and the service makes no change until then")
Root_Read_Back_Failed :: struct {
	generation: u64,
}

// The disk did not keep the root of ROOT_REFUSAL_LIMIT commits in a row: a
// place of the root drops its writes.
@(log_fact = "storage: the disk did not keep the root of {commits} commits in a row: a place of the root drops its writes; the service makes no change until its next start, and its objects can still be read")
Root_Place_Drops_Writes :: struct {
	commits: u64,
}

// A commit dropped version indexes or leaves with a wrong check.
@(log_fact = "storage: the commit of generation {generation} dropped {dropped} version indexes or leaves with a wrong check in the store {store}: those versions are lost, the objects stay")
Versions_Dropped_At_Commit :: struct {
	generation: u64,
	dropped:    u64,
	store:      [40]u8,
}

// A connection made a share of its store, or of a tree of it.
@(log_fact = "storage: a share of the store {store}, the share {share}")
Share_Made :: struct {
	share: u64,
	store: [40]u8,
}

// A connection made a share that reads only.
@(log_fact = "storage: a share of the store {store}, read only, the share {share}")
Read_Only_Share_Made :: struct {
	share: u64,
	store: [40]u8,
}

// The connection that made a share ended it.
@(log_fact = "storage: the share {share} ended")
Share_Ended :: struct {
	share: u64,
}

// The open found a disk with no commit, and formatted it.
@(log_fact = "storage: ok, a new disk: generation 1, {blocks}")
New_Disk_Formatted :: struct {
	blocks: value_kinds.Size_In_Blocks,
}

// The open found a root with a wrong check, a write that a stop cut, and
// uses the root before it.
@(log_fact = "storage: the root of generation {generation} has a wrong check: a write that a stop cut; the service uses the root before it")
Cut_Root_Skipped :: struct {
	generation: u64,
}

// The open found blocks with a wrong check: the counts of the blocks, and of
// the objects and the stores that they damage.
@(log_fact = "storage: {blocks} blocks have a wrong check: {objects} objects and {stores} stores are damaged; the service serves the others, and a write or a remove replaces a damaged object")
Blocks_Damaged :: struct {
	blocks:  u64,
	objects: u64,
	stores:  u64,
}

// The open found versions with a wrong block.
@(log_fact = "storage: {versions} versions have a wrong block: a read of them gives Damaged")
Versions_Damaged :: struct {
	versions: u64,
}

// The open counted the blocks of stores again, and the root gives other
// counts.
@(log_fact = "storage: the disk gives {stores_recounted} stores another count of blocks than the open counted; the service takes the counts of the open ({stores_with_wrong_count} stores with no damage have a wrong count: a fault of the engine that wrote it)")
Store_Counts_Differ :: struct {
	stores_recounted:        u64,
	stores_with_wrong_count: u64,
}

// The open of a disk with data is done: what it found, and its time.
@(log_fact = "storage: ok, generation {generation}: {stores} stores, {objects} objects, {trees} trees, {versions} versions, {in_use} in use, {shared} shared, {checked} blocks checked, {wrong} wrong, in {elapsed}")
Disk_Opened :: struct {
	generation: u64,
	stores:     u64,
	objects:    u64,
	trees:      u64,
	versions:   u64,
	in_use:     value_kinds.Size_In_Blocks,
	shared:     u64,
	checked:    u64,
	wrong:      u64,
	elapsed:    value_kinds.Time_In_Milliseconds,
}

// The open found trees in the removal queues: the removal goes on.
@(log_fact = "storage: {trees} trees wait to be freed: the removal continues")
Trees_Wait_To_Be_Freed :: struct {
	trees: u64,
}

// The first commit of a store at its limit since the start of the service
// thinned one version.
@(log_fact = "storage: the store {store} is at its limit of {limit}: the commit of generation {generation} thinned 1 version, the oldest of the store first")
Store_At_Limit_Thinned_One_Version :: struct {
	limit:      value_kinds.Size_In_Blocks,
	generation: u64,
	store:      [40]u8,
}

// The first commit of a store at its limit since the start of the service
// thinned several versions.
@(log_fact = "storage: the store {store} is at its limit of {limit}: the commit of generation {generation} thinned {thinned} versions, the oldest of the store first")
Store_At_Limit_Thinned_Versions :: struct {
	limit:      value_kinds.Size_In_Blocks,
	generation: u64,
	thinned:    u64,
	store:      [40]u8,
}

// The erase of the versions of an object ended its one version.
@(log_fact = "storage: the versions of {object} in the store {store} are erased: 1 version ended, {zeroed} blocks written with zeros, {kept} blocks kept that another state names, generation {generation}")
Versions_Erased_One_Version :: struct {
	zeroed:     u64,
	kept:       u64,
	generation: u64,
	store:      [40]u8,
	object:     value_kinds.Text_View,
}

// The erase of the versions of an object ended several versions.
@(log_fact = "storage: the versions of {object} in the store {store} are erased: {ended} versions ended, {zeroed} blocks written with zeros, {kept} blocks kept that another state names, generation {generation}")
Versions_Erased :: struct {
	ended:      u64,
	zeroed:     u64,
	kept:       u64,
	generation: u64,
	store:      [40]u8,
	object:     value_kinds.Text_View,
}

// The erase left damaged parts of versions with no zeros over them.
@(log_fact = "storage: the erase of the versions of {object} in the store {store} ended {damaged} damaged version indexes, leaves or states with no zeros over them: their blocks keep their bytes, in use until the next start of the service and free after it")
Erase_Damaged_Left :: struct {
	damaged: u64,
	store:   [40]u8,
	object:  value_kinds.Text_View,
}

// The removal of a tree stops: the removal queue gives no first tree.
@(log_fact = "storage: the removal of a tree of the store {store} stops: the removal queue gives no first tree; the next change of the store tries again")
Tree_Removal_No_First_Tree :: struct {
	store: [40]u8,
}

// The removal of a tree stops: a step of its plan was refused.
@(log_fact = "storage: the removal of a tree of the store {store} stops: a step was refused; the next change of the store tries again")
Tree_Removal_Step_Refused :: struct {
	store: [40]u8,
}

// The removal of a tree stops: its commit failed.
@(log_fact = "storage: the removal of a tree of the store {store} stops: its commit failed; the next change of the store tries again")
Tree_Removal_Commit_Failed :: struct {
	store: [40]u8,
}

// The commit of the range writes of an object: what it changed, hashed and
// wrote, and its time.
@(log_fact = "storage: the commit of generation {generation} of {object}: {changed} blocks changed of {object_blocks}, {hashed_blocks} blocks and {hashed_nodes} object nodes hashed, {written} blocks written; the object holds {held}; in {elapsed}")
Ranges_Committed :: struct {
	generation:    u64,
	changed:       u64,
	object_blocks: u64,
	hashed_blocks: u64,
	hashed_nodes:  u64,
	written:       u64,
	held:          value_kinds.Size_In_Blocks,
	elapsed:       value_kinds.Time_In_Milliseconds,
	object:        value_kinds.Text_View,
}

// The block service refused a request: the values of its error record,
// whose kind and unit a reader writes by the names of their members.
@(log_fact = "storage: the block service refused a request: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Block_Request_Refused :: distinct errors.Error_Record_Fact_Fields

// The facts of the start of the service with no value: their sentence is
// their template.

// The context has no seed.
@(log_fact = "storage: no seed in the context of the process")
No_Seed :: struct {}

// The context has no service ring.
@(log_fact = "storage: no service ring")
No_Service_Ring :: struct {}

// The ring of the block service does not open.
@(log_fact = "storage: no block ring")
No_Block_Ring :: struct {}

// The handle of the block service lacks the right Read.
@(log_fact = "storage: no handle of the block service with the right Read: a wait for the disk would have no end")
No_Block_Service_Handle :: struct {}

// The data region does not exist or does not map.
@(log_fact = "storage: no data region")
No_Data_Region :: struct {}

// The block service refused the data region.
@(log_fact = "storage: the block service refused the data region")
Data_Region_Refused :: struct {}

// The budget of the service pays no tables of the blocks, even for the
// least disk.
@(log_fact = "storage: the memory of the service holds no tables of the blocks of the disk of {disk_blocks}: the service serves nothing")
No_Table_Memory :: struct {
	disk_blocks: value_kinds.Size_In_Blocks,
}

// The budget of the service pays the tables of the first blocks of the
// disk only: the service reads the counts of the blocks from the count tree
// of the disk.
@(log_fact = "storage: the disk has {disk_blocks}, and the memory of the service holds the tables of {used_blocks}: the service reads the counts of the blocks from the count tree of the disk")
Disk_Larger_Than_Tables :: struct {
	disk_blocks: value_kinds.Size_In_Blocks,
	used_blocks: value_kinds.Size_In_Blocks,
}

// A whole root names more blocks than the tables hold, and no count tree
// that holds each count: the open uses no root rather than lose the blocks
// past them.
@(log_fact = "storage: the root of the disk names more blocks than the {used_blocks} whose tables the memory of the service holds, and no count tree that holds each count: the service keeps the disk as it is, and serves nothing; a larger budget of the service opens it")
Root_Larger_Than_Tables :: struct {
	used_blocks: value_kinds.Size_In_Blocks,
}

// The count tree of the disk does not hold the counts that the walk of the
// open found: the commits after the open write the leaves that differ.
@(log_fact = "storage: {leaves} leaves of the count tree do not hold the counts of names that the open found: the next commits write them")
Count_Leaves_Differ :: struct {
	leaves: u64,
}

// The repair of wrong leaves of the count tree ended: a commit wrote them.
@(log_fact = "storage: the leaves of the count tree that had a wrong check are counted again and written: the service takes changes again")
Count_Leaves_Repaired :: struct {}

// Leaves of the count tree have a wrong check: the service enters the
// repair state.
@(log_fact = "storage: the count tree has a wrong check in {leaves} of its leaves: the service makes no change until it has counted the names of their blocks again, and serves the reads")
Count_Repair_Started :: struct {
	leaves: u64,
}

// A read or a write of the device failed during the repair of the count
// tree: the walk starts again after the next call. Written once.
@(log_fact = "storage: a read or a write of the disk failed during the repair of the count tree: the repair starts again after the next call")
Count_Repair_Device :: struct {}

// The disk has no free block for the scratch of the repair: the service
// takes changes again. Written once.
@(log_fact = "storage: the disk has no free block for the scratch of the repair of the count tree: the service takes changes again, and the repair starts again after the next commit")
Count_Repair_No_Room :: struct {}

// The commit of the repaired leaves failed on the device. Written once.
@(log_fact = "storage: the commit of the repaired leaves of the count tree did not reach the disk: the service makes it again after the next call")
Count_Repair_Commit_Failed :: struct {}

// The repair found a wrong node of a tree of a store: the blocks under it
// are not counted, as at an open.
@(log_fact = "storage: the repair of the count tree found a wrong node of a tree in the store {store}: the store takes no change, and the repair goes on with the other stores")
Count_Repair_Store_Damaged :: struct {
	store: [40]u8,
}

// A set of the damage of the form Count_Tree is full: the service makes no
// change until its next start.
@(log_fact = "storage: the service found more than {wrong_blocks} wrong blocks with no table of each block: it makes no change until its next start")
Damage_Set_Full :: struct {
	wrong_blocks: u64,
}

// The count tree of the disk has a wrong page: the open counts by its
// walk, and the commits after it write a new count tree.
@(log_fact = "storage: the count tree of the disk has a wrong page: the service takes the counts of names that the open found, and the next commits write a new count tree")
Count_Tree_Damaged :: struct {}

// Pages of the store table have a wrong check: their stores are not
// served, and no new store goes in them.
@(log_fact = "storage: {pages} pages of the store table have a wrong check or break a rule of the format: the service serves none of their stores, and makes no new store in them")
Store_Pages_Damaged :: struct {
	pages: u64,
}

// The open found no valid root.
@(log_fact = "storage: no valid root on the disk: the service keeps the disk as it is, and serves nothing")
No_Valid_Root :: struct {}

// The first root of the disk was cut by a stop: the service formats again.
@(log_fact = "storage: the first root of the disk has a wrong check and no commit followed it: a format that a stop cut; the service formats again")
First_Root_Cut :: struct {}

// The newest root names a damaged block: the root before it is used.
@(log_fact = "storage: the newest root names a block with a wrong check, and the root before it names none: the root before it is used")
Newest_Root_Refused :: struct {}

// The open found blocks that the engine names wrongly, in one store.
@(log_fact = "storage: a fault of the engine: {named_twice} blocks of one name named two times, {named_by_two_stores} blocks named from two stores, {reference_overflow} counts of names that pass their limit; the service makes no change in the {faulty_stores} store with such a block, and gives their objects")
Engine_Fault_In_One_Store :: struct {
	named_twice:         u64,
	named_by_two_stores: u64,
	reference_overflow:  u64,
	faulty_stores:       u64,
}

// The open found blocks that the engine names wrongly, in several stores
// or in none.
@(log_fact = "storage: a fault of the engine: {named_twice} blocks of one name named two times, {named_by_two_stores} blocks named from two stores, {reference_overflow} counts of names that pass their limit; the service makes no change in the {faulty_stores} stores with such a block, and gives their objects")
Engine_Fault :: struct {
	named_twice:         u64,
	named_by_two_stores: u64,
	reference_overflow:  u64,
	faulty_stores:       u64,
}

// The erase of versions: the disk did not keep the second root.
@(log_fact = "storage: the versions of {object} in the store {store} are ended at the generation {generation}, and the read back of the second root found other bytes: the disk did not keep it; no block is written with zeros, and the old bytes stay in free blocks until a commit takes them")
Versions_Ended_Second_Root_Dropped :: struct {
	generation: u64,
	store:      [40]u8,
	object:     value_kinds.Text_View,
}

// The erase of versions: the write or the read back of the second root
// failed on the device.
@(log_fact = "storage: the versions of {object} in the store {store} are ended at the generation {generation}, and the write or the read back of the second root failed on the device: it is not taken, the open of the next start decides, and the service makes no change until then; no block is written with zeros, and the old bytes stay in free blocks until a commit takes them")
Versions_Ended_Second_Root_Failed :: struct {
	generation: u64,
	store:      [40]u8,
	object:     value_kinds.Text_View,
}

// The erase of versions: a write, the Flush or the read back of the zeros
// failed.
@(log_fact = "storage: the versions of {object} in the store {store} are ended at the generation {generation}, and a write, the Flush or the read back of the zeros failed: {zeroed} blocks read back as zeros and {not_zeroed} with other bytes; the others were not read back, and can keep their old bytes until a commit takes them")
Versions_Ended_Zeros_Failed :: struct {
	generation: u64,
	zeroed:     u64,
	not_zeroed: u64,
	store:      [40]u8,
	object:     value_kinds.Text_View,
}

// The erase of versions: the disk did not keep some writes of zeros.
@(log_fact = "storage: the versions of {object} in the store {store} are ended at the generation {generation}, and the read back of the zeros found {not_zeroed} blocks with other bytes: the disk did not keep those writes, and their old bytes stay in free blocks until a commit takes them")
Versions_Ended_Zeros_Dropped :: struct {
	generation: u64,
	not_zeroed: u64,
	store:      [40]u8,
	object:     value_kinds.Text_View,
}

// The tool reads the length of a Text field as a literal: the constants
// name the same bytes, and each holds its longest name and a zero byte.
#assert(size_of(Versions_Ended_Zeros_Failed) == 24 + STORE_FIELD_BYTES + value_kinds.TEXT_VIEW_BYTES)
#assert(size_of(Tree_Node_Damaged) == STORE_FIELD_BYTES && STORE_FIELD_BYTES > NAME_CAPACITY)
#assert(size_of(Erase_Damaged_Left) == 8 + STORE_FIELD_BYTES + value_kinds.TEXT_VIEW_BYTES)
#assert(format.ENTRY_NAME_CAPACITY <= op.LOG_FACT_TEXT_AREA_BYTES_MOST)
#assert(size_of(Disk_Silent) == DISK_SILENT_CAUSE_BYTES)

// store_field gives the Text field of a store name.
store_field :: proc "contextless" (name: string) -> [STORE_FIELD_BYTES]u8 {
	return value_kinds.text_field(name, STORE_FIELD_BYTES)
}

// cause_field gives the Text field of the cause of a silent disk.
cause_field :: proc "contextless" (words: string) -> [DISK_SILENT_CAUSE_BYTES]u8 {
	return value_kinds.text_field(words, DISK_SILENT_CAUSE_BYTES)
}


// blocks_field gives a count of blocks as a field with its unit. A count of
// the service is far below the largest i64.
blocks_field :: proc "contextless" (count: u64) -> value_kinds.Size_In_Blocks {
	return value_kinds.Size_In_Blocks(count)
}

// milliseconds_field gives a time in milliseconds as a field with its unit.
milliseconds_field :: proc "contextless" (milliseconds: u64) -> value_kinds.Time_In_Milliseconds {
	return value_kinds.Time_In_Milliseconds(milliseconds)
}
