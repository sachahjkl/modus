package storage_service

import "base:intrinsics"
import "modus:contract/block"
import "modus:contract/date"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:contract/ring"
import format "modus:contract/store"
import "internal:storage/storage_mount"
import block_tree "internal:storage/storage_object"
import "internal:storage/storage_retention"
import tree "internal:storage/storage_tree"
import "modus:system"

// The format of the disk, and the one rule that keeps it whole (copy on
// write), are in src/library/modus/contract/store. The model of objects, trees and stores:
// docs/STORAGE.md. The versions: docs/ARCHITECTURE.md, "Versions".

BLOCK_SIZE :: format.BLOCK_SIZE
ROOT_MAGIC :: format.ROOT_MAGIC
STORE_CAPACITY :: format.STORE_CAPACITY
NAME_CAPACITY :: format.NAME_CAPACITY
DISK_BLOCKS_LIMIT :: format.DISK_BLOCKS_LIMIT
OBJECT_LEVEL_LIMIT :: format.OBJECT_LEVEL_LIMIT
REGION_BLOCKS :: 64 // The data region that the block service reads and writes.
RETENTION_INTERVAL :: 60 * 1000 // The retention rule runs on an object at most one time in this many milliseconds.

Pointer :: format.Pointer
Store_Entry :: format.Store_Entry
Root :: format.Root
Store_Block :: format.Store_Block
Entry :: format.Entry
Entry_Name :: format.Entry_Name
Object_Node :: format.Object_Node
Object_Child :: format.Object_Child
Version_Entry :: format.Version_Entry
Version_Leaf :: format.Version_Leaf
Version_Index :: format.Version_Index
Block :: [BLOCK_SIZE]u8

#assert(BLOCK_SIZE == block.BLOCK_SIZE)

// What the service knows of the disk. The store block of each store stays
// in memory; nodes, object nodes, versions and data are read when a caller asks. The blocks
// in use and the reference count of each one are in `opened`, the state of
// the open (src/library/internal/storage/storage_mount), which the service keeps up to date.
root: Root
root_place: u64 // 0 or 1: the place of the root on the disk.
store_blocks: [STORE_CAPACITY]Store_Block
next_free: u64
time_at_start: u64 // The time since the format at the start of the service (the time of its root).
service_started: u64 // system.time() at the start of the service.

// The counts that stores() gives.
commits: u64
blocks_written: u64
commits_refused: u64 // The commits that their read back refused: the disk did not keep a write.
commits_undecided: u64 // The commits whose root write, or its read back, failed on the device: not taken, and the open of the next start decides.
roots_refused_in_a_row: u64 // The roots that their read back found with other bytes since the last root that read back whole.
blocks_read_back: u64 // The blocks, the roots and the zeros that a read back read.
read_back_nanoseconds: u64 // The time of those reads: a measure of the cost of the read back.

// The block service.
blocks: ring.Ring
region: [^]u8
disk_tag: u32
disk_errors: u64
disk_size: u64 // The blocks of the disk that the service uses.
broken: bool // The write of a root or its read back failed, or a place of the root dropped ROOT_REFUSAL_LIMIT roots in a row: the service makes no change until its next start.

// The block service, with the right Read: its stop is an event of this
// process, which ends each wait for a completion (block.GRANT_SERVICE).
block_service: system.Handle
// The event word of this thread when the service last read the state of
// the block service. The state is read again only after an event, so a
// wait for a completion costs no kernel call while the block service runs.
// Until the first read, the state is not known.
block_service_events: u32
block_service_state_read: bool

// Why the disk is silent (disk_silence_note).
Disk_Silence :: enum {
	No_Answer, // The block service gave a request the record No_Answer: the device did not answer it by its deadline.
	Block_Service_Stopped, // The block service stopped while a request waited for its completion, or before it mapped the block ring.
	No_Completion, // No completion came for system.ANSWER_BOUND_MILLISECONDS while a request waited.
}

// The disk does not answer: the service never reads the block ring again,
// so a late completion is never taken for the answer of a later request,
// and each call that needs a block is refused at once with Device. It makes
// no change until its next start (src/md/features/missing_hardware.md).
disk_silent: bool

// The open of the disk is done: the service knows its stores. A disk that
// went silent before it leaves this false, and each call is refused.
disk_opened: bool

// disk_unopened_refusal refuses a call while the disk went silent before
// the open was done: the service knows no store, so it can answer no
// call with a fact of the disk. It gives Device, as a read of a silent disk
// does after the open.
disk_unopened_refusal :: proc "contextless" (error: ^errors.Error_Record) -> (refused: bool, result: call_outcome.Call_Outcome) {
	if disk_opened {
		return false, .Succeeded
	}
	return true, refuse(error, .Callee_Unavailable, .Device, .None, 0, 0, 0, 1)
}

// disk_silence_note makes the disk silent, with its line, once. It closes
// the handle of the block service: no wait reads it after the silence, and
// its stopped process then frees its slot of the kernel.
disk_silence_note :: proc "contextless" (cause: Disk_Silence) {
	if disk_silent {
		return
	}
	disk_silent = true
	broken = true
	disk_errors += 1
	system.close(block_service)
	block_service = 0
	// The sentence of the cause lives in this buffer until the fact is
	// written.
	words_buffer: [DISK_SILENT_CAUSE_BYTES]u8
	words: string
	switch cause {
	case .No_Answer:
		words = "the block service says that the device did not answer a request"
	case .Block_Service_Stopped:
		words = "the block service stopped before it answered"
	case .No_Completion:
		words = system.format(words_buffer[:], "no completion came in ", u64(system.ANSWER_BOUND_MILLISECONDS), " ms")
	}
	system.log_fact(.Error, Disk_Silent{cause = cause_field(words)})
}

// disk_answer_absent says if a completion of the block service says that
// the device did not answer (the border block.device_did_not_answer).
disk_answer_absent :: proc "contextless" (completion: ring.Record) -> bool {
	return block.device_did_not_answer(completion.kind, completion.values)
}

// disk_wait_goes_on decides a wait for a completion of the block service
// that came to no completion in its pass: false when the block service
// stopped or the deadline passed, with the disk then silent.
disk_wait_goes_on :: proc "contextless" (deadline: u64) -> bool {
	state := op.Process_State.Ready
	// The word is read before the state: a stop after the read changes
	// the word again, and the next pass reads the state.
	if events := intrinsics.volatile_load(system.events()); !block_service_state_read || events != block_service_events {
		block_service_events = events
		block_service_state_read = true
		state, _, _ = system.process_state(block_service)
	}
	switch system.answer_wait_of(system.time(), deadline, state) {
	case .Waits:
		return true
	case .Stopped:
		disk_silence_note(.Block_Service_Stopped)
	case .Silent:
		disk_silence_note(.No_Completion)
	}
	return false
}

check_of :: format.check
root_check :: format.root_check

// Damage: a block that a valid root names has a wrong check. The service
// does not use the block. An object with such an object node or such data is
// damaged: a read of it gives the answer Damaged, and a write or a remove
// replaces it; the open and each read keep the wrong blocks in
// `opened.wrong_blocks`. A store with such a store block or node is
// damaged: the service does not know its entries, and refuses each call
// for it. The other objects and the other stores are served.
store_damaged: [STORE_CAPACITY]bool
// A store whose counts are not trusted: the open found a fault of the engine
// in it, or a commit would take a count below 0. The service gives its
// objects and makes no change in it.
store_faulty: [STORE_CAPACITY]bool

// time_now gives the time since the format of the disk, in milliseconds:
// the time of the root at the start, and the time that the service ran
// since. The time while no machine ran is not counted: the date counts it.
time_now :: proc "contextless" () -> u64 {
	return time_at_start + (system.time() - service_started)
}

// date_now gives the date in seconds since 1970 (UTC), or 0 when the
// system has no date.
date_now :: proc "contextless" () -> u64 {
	milliseconds, known := date.milliseconds_now(date_page, system.time())
	return known && milliseconds > 0 ? u64(milliseconds / 1000) : 0 // milliseconds_now gives no date before 1970.
}

date_page: ^date.Page // src/library/modus/contract/date: the date page of this process.

slot :: #force_inline proc "contextless" (index: u64) -> []u8 {
	return region[index * BLOCK_SIZE:][:BLOCK_SIZE]
}

used :: proc "contextless" (number: u64) -> bool {
	return storage_mount.used(&opened, number)
}

mark :: proc "contextless" (number: u64, value: bool) {
	storage_mount.mark(&opened, number, value)
}

// allocate gives a free block and marks it, or 0 when the disk is full.
allocate :: proc "contextless" () -> u64 {
	for _ in 0 ..< root.disk_blocks {
		if next_free < 2 || next_free >= root.disk_blocks {
			next_free = 2
		}
		number := next_free
		next_free += 1
		if !used(number) {
			mark(number, true)
			return number
		}
	}
	return 0
}

// A request to the block service: one block, to or from one slot of the region.
Request :: struct {
	number: u64,
	slot:   u64,
}

// transfer reads or writes blocks: all are in flight at the same time. A
// silent disk refuses at once. A wait for a completion ends when the block
// service stops, or after a stall of system.ANSWER_BOUND_MILLISECONDS: the
// disk is then silent, and the transfer fails.
transfer :: proc "contextless" (command: block.Command, requests: []Request) -> bool {
	if disk_silent {
		disk_errors += 1
		return false
	}
	first := disk_tag
	defer disk_tag = first + u32(len(requests))
	sent := 0
	done := 0
	good := true
	// A stall bound: each completion is progress, and moves the deadline.
	deadline := system.answer_deadline(system.time())
	for done < len(requests) {
		wait := system.wait_begin() // The stop of the block service is an event.
		for sent < len(requests) {
			request := requests[sent]
			record := ring.Record{kind = u32(command), tag = first + u32(sent), values = {0 = request.number, 1 = 1, 2 = request.slot * BLOCK_SIZE}}
			if !ring.push(&blocks.commands, record) {
				break
			}
			sent += 1
		}
		system.wake_reader(&blocks.commands)
		completed := false
		for {
			completion, ok := system.receive(&blocks.completions)
			if !ok {
				break
			}
			done += 1
			completed = true
			if disk_answer_absent(completion) {
				disk_silence_note(.No_Answer)
				return false
			}
			if block.Status(completion.kind) != .Ok {
				if good {
					// The first refusal of this batch goes on the log, with the
					// values of its error record.
					error := errors.completion_record(completion.values)
					system.log_fact(.Error, Block_Request_Refused(errors.error_record_fact_fields(error)))
				}
				good = false
			}
		}
		if done < len(requests) {
			if completed {
				deadline = system.answer_deadline(system.time())
			} else if !disk_wait_goes_on(deadline) {
				return false
			}
			system.wait_records(&wait, &blocks.completions)
			if sent < len(requests) {
				system.wait_room(&wait, &blocks.commands)
			}
			if !system.wait_spin(&wait) {
				system.wait_end(&wait, deadline)
			}
		}
	}
	if !good {
		disk_errors += 1
	}
	return good
}

// command sends one command with no data and waits for its completion. On
// a silent disk, and when the wait for the block service ends with no
// completion (disk_wait_goes_on), it gives a completion Device_Error with
// the record No_Answer of the device, as the block service gives one.
command :: proc "contextless" (kind: block.Command, values: [7]u64 = {}) -> ring.Record {
	silent := ring.Record{kind = u32(block.Status.Device_Error), values = block.no_answer_values(kind)}
	if disk_silent {
		return silent
	}
	disk_tag += 1
	tag := disk_tag
	deadline := system.answer_deadline(system.time())
	for {
		wait := system.wait_begin() // The stop of the block service is an event.
		if system.send(&blocks.commands, ring.Record{kind = u32(kind), tag = tag, values = values}) {
			break
		}
		if !disk_wait_goes_on(deadline) {
			return silent
		}
		system.wait_room(&wait, &blocks.commands)
		system.wait_end(&wait, deadline)
	}
	for {
		wait := system.wait_begin()
		for {
			completion, ok := system.receive(&blocks.completions)
			if !ok {
				break
			}
			if completion.tag == tag {
				if disk_answer_absent(completion) {
					disk_silence_note(.No_Answer)
				}
				return completion
			}
		}
		if !disk_wait_goes_on(deadline) {
			return silent
		}
		system.wait_records(&wait, &blocks.completions)
		if !system.wait_spin(&wait) {
			system.wait_end(&wait, deadline)
		}
	}
}

flush :: proc "contextless" () -> bool {
	return block.Status(command(.Flush).kind) == .Ok
}

Read :: enum {
	Good,
	Wrong, // A block does not have the check of its Pointer, or a Pointer names no block of the disk.
	Device, // The block service reported an error: the service knows nothing of the blocks.
}

// read_checked reads blocks to the region, from `first_slot` on, and
// compares each one with the check of its Pointer. It gives the count of
// wrong blocks.
read_checked :: proc "contextless" (pointers: []Pointer, first_slot: u64) -> (wrong: u64, state: Read) {
	requests: [REGION_BLOCKS]Request
	for pointer, index in pointers {
		if pointer.block < 2 || pointer.block >= disk_size {
			return u64(len(pointers)), .Wrong
		}
		requests[index] = {number = pointer.block, slot = first_slot + u64(index)}
	}
	if !transfer(.Read, requests[:len(pointers)]) {
		return 0, .Device
	}
	for pointer, index in pointers {
		if check_of(slot(first_slot + u64(index))) != pointer.check {
			wrong += 1
		}
	}
	return wrong, wrong == 0 ? .Good : .Wrong
}

// The blocks that one name holds (a version index, a leaf) that the service
// wrote or read last: a commit that adds a version to an object reads
// nothing. An entry is found by its number and its check, so a block that
// was freed and written again is never taken for the old one.
Cached_Block :: struct {
	number: u64,
	check:  u64,
	used:   u64, // The count of reads at its last use.
	bytes:  Block,
}
block_cache: [64]Cached_Block // The nodes near the roots of the trees that the last calls used.
cache_reads: u64

cache_put :: proc "contextless" (pointer: Pointer, bytes: ^Block) {
	oldest := 0
	for &entry, index in block_cache {
		if entry.number == pointer.block {
			oldest = index
			break
		}
		if entry.used < block_cache[oldest].used {
			oldest = index
		}
	}
	cache_reads += 1
	block_cache[oldest] = {number = pointer.block, check = pointer.check, used = cache_reads}
	block_cache[oldest].bytes = bytes^
}

// cache_forget drops a block from the cache: the erase of versions writes
// zeros over it, and the memory of the service keeps no copy of it.
cache_forget :: proc "contextless" (number: u64) {
	for &entry in block_cache {
		if entry.number == number {
			entry = {}
		}
	}
}

// read_single reads one block, checked, through the cache.
read_single :: proc "contextless" (pointer: Pointer, into: ^Block) -> Read {
	cache_reads += 1
	for &entry in block_cache {
		if entry.number == pointer.block && entry.check == pointer.check && pointer.block != 0 {
			entry.used = cache_reads
			into^ = entry.bytes
			return .Good
		}
	}
	_, state := read_checked({pointer}, 0)
	if state == .Good {
		intrinsics.mem_copy_non_overlapping(into, raw_data(slot(0)), BLOCK_SIZE)
		cache_put(pointer, into)
	}
	return state
}

// read_raw reads one block with no check.
read_raw :: proc "contextless" (number: u64, into: ^Block) -> Read {
	if number < 2 || number >= disk_size {
		return .Wrong
	}
	if !transfer(.Read, {{number = number, slot = 0}}) {
		return .Device
	}
	intrinsics.mem_copy_non_overlapping(into, raw_data(slot(0)), BLOCK_SIZE)
	return .Good
}

// The block trees of the objects (src/library/internal/storage/storage_object) read their
// object nodes through the cache, checked, and their blocks of data with
// no check: the tree checks each one by its value at its place.
object_source := block_tree.Source {
	read_node  = object_read_node,
	read_block = object_read_block,
}

object_read_node :: proc "contextless" (_: ^block_tree.Source, pointer: Pointer, into: ^block_tree.Block) -> block_tree.Read {
	if pointer.block < 2 || pointer.block >= disk_size {
		return .Wrong
	}
	switch read_single(pointer, into) {
	case .Good:
		return .Good
	case .Wrong:
		storage_mount.wrong_block_set(&opened, pointer.block)
		return .Wrong
	case .Device:
	}
	return .Device
}

object_read_block :: proc "contextless" (_: ^block_tree.Source, number: u64, into: ^block_tree.Block) -> block_tree.Read {
	switch read_raw(number, into) {
	case .Good:
		return .Good
	case .Wrong:
		return .Wrong
	case .Device:
	}
	return .Device
}

Mount :: storage_mount.Mount

// The open of the disk: the same code as the check of the modus tool on
// the host (src/library/internal/storage/storage_mount). The service keeps the blocks in use and
// their reference counts there.
opened: storage_mount.State

// read_through_block_service reads blocks for the open: through the data
// region, REGION_BLOCKS at a time.
read_through_block_service :: proc "contextless" (reader: ^storage_mount.Block_Reader, numbers: []u64, into: []u8) -> bool {
	for first := 0; first < len(numbers); first += REGION_BLOCKS {
		part := numbers[first:min(first + REGION_BLOCKS, len(numbers))]
		requests: [REGION_BLOCKS]Request
		for number, index in part {
			requests[index] = {number = number, slot = u64(index)}
		}
		if !transfer(.Read, requests[:len(part)]) {
			return false
		}
		intrinsics.mem_copy_non_overlapping(raw_data(into[first * BLOCK_SIZE:]), region, len(part) * BLOCK_SIZE)
	}
	return true
}

// The reader of the open: the state of the open keeps its address while it
// walks, so it is not on the stack.
mount_reader: storage_mount.Block_Reader

// mount opens the disk (storage_mount.mount), and formats a disk that has
// never had a commit: the first root goes to block 1.
mount :: proc "contextless" (disk_blocks: u64) -> (result: Mount) {
	mount_reader = {read = read_through_block_service}
	result = storage_mount.mount(&opened, &mount_reader, disk_blocks)
	disk_size = opened.disk_size
	service_started = system.time()
	if result.failed {
		return result
	}
	if result.needs_format {
		root = {magic = ROOT_MAGIC, generation = 1, disk_blocks = disk_size, date = date_now()}
		root.check = root_check(&root)
		intrinsics.mem_copy_non_overlapping(raw_data(slot(0)), &root, BLOCK_SIZE)
		root_place = 1
		if !transfer(.Write, {{number = 1, slot = 0}}) || !flush() {
			result.failed = true
			return result
		}
		opened.in_use = {}
		opened.in_use_count = 0
		opened.references = {}
		opened.owner = {}
		opened.store_versions = {}
		storage_mount.hash_index_reset(&opened)
		mark(0, true)
		mark(1, true)
		result.generation = 1
		return result
	}
	root = opened.root
	root_place = opened.root_place
	store_blocks = opened.store_blocks
	store_damaged = opened.store_damaged
	store_faulty = opened.store_faulty
	time_at_start = root.time
	// The count of each store is the recount of the open: the next commit
	// writes it in the root.
	for &entry, index in root.stores {
		if entry.name[0] != 0 && !store_damaged[index] {
			entry.used = opened.store_recount[index]
		}
	}
	return result
}

store_find :: proc "contextless" (name: string) -> int {
	for &store, index in root.stores {
		if store.name[0] != 0 && system.name_of(store.name[:]) == name {
			return index
		}
	}
	return -1
}

blocks_of :: format.object_blocks

// ---------------------------------------------------------------------
// The plan of one commit. A commit is planned in memory: the blocks to
// write, the blocks it takes, the change of the reference count of each
// block that it names or stops naming, and the version work of each
// object. Nothing of the state of the service changes before the root is
// on the disk; a refusal or a failure drops the plan.

// The capacities of one commit. A commit that needs more is refused with
// Full and the unit Commit_Blocks, not with a full disk. Half of
// DELTA_CAPACITY is the count of the blocks whose names one commit changes:
// 262144, each block of a disk, so the remove of an object as large as the
// disk is one commit. The writes: the blocks of data that one commit
// changes (the pending changes of an object, PENDING_BLOCK_CAPACITY), the
// object nodes above them (block_tree.NODE_SLOT_CAPACITY), the leaves of a
// whole version index (a compaction or the retention rule), and the leaves
// and indexes that thinning at the limit rewrites in other objects.
DELTA_CAPACITY :: 1 << 19 // Power of 2.
WRITE_CAPACITY :: 4096
LEAF_WORK_CAPACITY :: 300 // More than the leaves of one index.
REFERENCE_LIMIT :: storage_mount.REFERENCE_LIMIT

Write :: struct {
	number: u64,
	bytes:  ^Block,
}

Index_Work :: struct {
	loaded:   bool,
	touched:  bool,
	original: Pointer,
	index:    Version_Index,
}

Leaf_Work :: struct {
	entry:    int, // The plan entry of the object.
	position: int, // In the leaves of the index as the commit found them; a new leaf after them.
	original: Pointer, // No block: a new leaf.
	changed:  bool,
	leaf:     Version_Leaf,
}

Plan :: struct {
	store_index: int,
	next:        Root,
	store_block: Store_Block,
	writes:      [WRITE_CAPACITY]Write,
	write_count: int,
	taken:       [WRITE_CAPACITY]u64, // Blocks that the plan allocated.
	taken_count: int,
	// The change of the reference counts: an open table of blocks.
	delta_blocks: [DELTA_CAPACITY]u64,
	delta_values: [DELTA_CAPACITY]i32,
	delta_places: [DELTA_CAPACITY]u32, // The places in use, for the walk and the reset.
	delta_count:  int,
	used_change:  i64, // The change of the distinct blocks of the store.
	full:         bool, // The disk has no free block: the commit is refused.
	device:       bool, // A read of the plan failed on the device.
	capacity_reached: bool, // A table of the plan had no room: the commit is refused.
	capacity_limit:   int, // The capacity that it reached.
	count_fault:      bool, // A count would go below 0: a fault of the engine.
	count_overflow:   bool, // A count would pass REFERENCE_LIMIT.
	dropped_versions: u64, // Version indexes and leaves with a wrong check that the plan drops.
	release_damaged:  u64, // States of versions that the plan releases with a wrong block under their root, one count for each state: the blocks under it stay in use until the next start.
	tree_damaged:     bool, // A node of a tree has a wrong check or breaks a rule: the store is damaged.
	// The trees that the commit opened, and the entries whose versions it
	// changes (trees.odin).
	pool:         tree.Pool,
	trees:        [PLAN_TREE_CAPACITY]Tree_Open,
	tree_count:   int,
	entries:      [PLAN_ENTRY_CAPACITY]Plan_Entry,
	entry_count:  int,
	index_work:   [PLAN_ENTRY_CAPACITY]Index_Work,
	leaf_work:    [LEAF_WORK_CAPACITY]Leaf_Work,
	leaf_count:   int,
	versions_change: i64,
	thinned:      u64, // Versions that the plan removes.
	// Staging of the blocks that the plan writes, other than leaves and
	// the blocks of the trees of objects.
	store_block_bytes: Block,
	index_blocks: [PLAN_ENTRY_CAPACITY]Block,
	// The object nodes of the releases, one for each level: a release walks
	// down the nodes that lose their last name.
	release_nodes: [OBJECT_LEVEL_LIMIT + 1]Object_Node,
}

plan: Plan

plan_reset :: proc "contextless" (store_index: int) {
	for place in plan.delta_places[:plan.delta_count] {
		plan.delta_blocks[place] = 0
		plan.delta_values[place] = 0
	}
	for &work in plan.index_work[:plan.entry_count] {
		work.loaded, work.touched = false, false
	}
	plan.delta_count = 0
	plan.write_count = 0
	plan.taken_count = 0
	plan.used_change = 0
	plan.full, plan.device = false, false
	plan.capacity_reached, plan.capacity_limit = false, 0
	plan.count_fault, plan.count_overflow = false, false
	plan.dropped_versions = 0
	plan.release_damaged = 0
	plan.tree_damaged = false
	plan.leaf_count = 0
	plan.versions_change = 0
	plan.thinned = 0
	plan.store_index = store_index
	later_count = 0
	plan.next = root
	plan.store_block = store_index >= 0 ? store_blocks[store_index] : {}
	plan.entry_count = 0
	plan_trees_reset()
}

// plan_drop frees the blocks that the plan allocated.
plan_drop :: proc "contextless" () {
	for number in plan.taken[:plan.taken_count] {
		mark(number, false)
	}
	plan.taken_count = 0
}

delta_place :: proc "contextless" (number: u64) -> (place: u32, found: bool) {
	mask := u64(DELTA_CAPACITY - 1)
	at := (number * 0x9E3779B97F4A7C15 >> 40) & mask
	for _ in 0 ..< DELTA_CAPACITY {
		if plan.delta_blocks[at] == number {
			return u32(at), true
		}
		if plan.delta_blocks[at] == 0 {
			return u32(at), false
		}
		at = (at + 1) & mask
	}
	return 0, false
}

delta_of :: proc "contextless" (number: u64) -> i64 {
	place, found := delta_place(number)
	return found ? i64(plan.delta_values[place]) : 0
}

// count_after gives the reference count of a block after the plan.
count_after :: proc "contextless" (number: u64) -> i64 {
	return i64(opened.references[number]) + delta_of(number)
}

// delta_add changes the reference count of a block in the plan, and the
// count of the distinct blocks of the store.
delta_add :: proc "contextless" (number: u64, change: i64) {
	if number < 2 || number >= DISK_BLOCKS_LIMIT {
		return
	}
	place, found := delta_place(number)
	if !found {
		if plan.delta_count >= DELTA_CAPACITY / 2 || plan.delta_blocks[place] != 0 {
			capacity_reached(DELTA_CAPACITY / 2)
			return
		}
		plan.delta_blocks[place] = number
		plan.delta_places[plan.delta_count] = place
		plan.delta_count += 1
	}
	before := i64(opened.references[number]) + i64(plan.delta_values[place])
	plan.delta_values[place] += i32(change)
	after := before + change
	plan.used_change += i64(after > 0) - i64(before > 0)
	// A count below 0: the engine releases a name that it never counted.
	// The commit is refused, and the store stops taking changes: its counts
	// are not trusted.
	if after < 0 {
		plan.count_fault = true
	}
	if after > i64(REFERENCE_LIMIT) {
		plan.count_overflow = true
	}
}

// plan_refused says if the plan cannot commit: plan_commit refuses it with
// the error of its cause.
plan_refused :: proc "contextless" () -> bool {
	plan_trees_failure_take()
	return plan.full || plan.device || plan.capacity_reached || plan.count_fault || plan.count_overflow || plan.tree_damaged
}

capacity_reached :: proc "contextless" (capacity: int) {
	plan.capacity_reached = true
	plan.capacity_limit = capacity
}

plan_allocate :: proc "contextless" () -> u64 {
	if plan.taken_count >= WRITE_CAPACITY {
		capacity_reached(WRITE_CAPACITY)
		return 0
	}
	number := allocate()
	if number == 0 {
		plan.full = true
		return 0
	}
	plan.taken[plan.taken_count] = number
	plan.taken_count += 1
	delta_add(number, 1)
	return number
}

// plan_write writes a block of the plan to a new block, and gives its Pointer.
plan_write :: proc "contextless" (bytes: ^Block) -> Pointer {
	return plan_write_checked(bytes, 0, false)
}

// plan_write_checked writes a block of the plan with a check that the
// caller gives (a block of data: the check of its value), or with the hash
// of its bytes.
plan_write_checked :: proc "contextless" (bytes: ^Block, given_check: u64, given: bool) -> Pointer {
	if plan.write_count >= WRITE_CAPACITY {
		capacity_reached(WRITE_CAPACITY)
		return {}
	}
	number := plan_allocate()
	if number == 0 {
		return {}
	}
	plan.writes[plan.write_count] = {number = number, bytes = bytes}
	plan.write_count += 1
	return {block = number, check = given ? given_check : check_of(bytes[:])}
}

// state_name counts one more name of the root of a state of an object (a
// current version, a version, a clone).
state_name :: proc "contextless" (root: Pointer) {
	if root.block != 0 {
		delta_add(root.block, 1)
	}
}

// state_damaged says if a state of an object has a wrong block that the
// service knows: under its root, the open or a read found one.
state_damaged :: proc "contextless" (root: Pointer) -> bool {
	return root.block != 0 && (storage_mount.wrong_block(&opened, root.block) || storage_mount.damaged_under(&opened, root.block))
}

// state_release counts one name less of the root of a state of `size`
// bytes; a block that loses its last name frees what it names
// (child_release).
state_release :: proc "contextless" (root: Pointer, size: u64) {
	if root.block == 0 {
		return
	}
	if size > format.OBJECT_SIZE_LIMIT {
		return // The open found it wrong, and did not count under it.
	}
	child_release({block = root.block, check = root.check}, format.object_levels(size))
}

// child_release counts one name less of an object node of `level`, or of a
// block of data at level 0. When an object node has no name left, each of
// its children loses one name: the node is read for that. A node that is
// wrong, or under which a block is wrong, gives its children no change: the
// open did not count under a wrong block, and a block that went wrong
// since keeps the blocks under it in use until the next start, which
// counts again (the safe direction: a block in use is never given to
// another name).
child_release :: proc "contextless" (child: Object_Child, level: int) {
	delta_add(child.block, -1)
	if level == 0 || count_after(child.block) != 0 || level > OBJECT_LEVEL_LIMIT {
		return
	}
	if storage_mount.wrong_block(&opened, child.block) || storage_mount.damaged_under(&opened, child.block) {
		return
	}
	node := &plan.release_nodes[level]
	switch read_single({block = child.block, check = child.check}, (^Block)(node)) {
	case .Device:
		plan.device = true
	case .Wrong:
		storage_mount.wrong_block_set(&opened, child.block)
		plan.release_damaged += 1
	case .Good:
		if node.header.magic != format.OBJECT_NODE_MAGIC || int(node.header.level) != level {
			storage_mount.wrong_block_set(&opened, child.block)
			plan.release_damaged += 1
			return
		}
		for item in node.children {
			if item.block != 0 {
				child_release(item, level - 1)
			}
		}
	}
}

// The names and the writes of the work of a commit on an object
// (src/library/internal/storage/storage_object): through the plan.
object_counter := block_tree.Counter {
	name       = counter_name,
	release    = counter_release,
	write_node = counter_write_node,
	write_data = counter_write_data,
}

counter_name :: proc "contextless" (_: ^block_tree.Counter, block: u64) {
	delta_add(block, 1)
}

counter_release :: proc "contextless" (_: ^block_tree.Counter, child: Object_Child, level: int) {
	child_release(child, level)
}

counter_write_node :: proc "contextless" (_: ^block_tree.Counter, bytes: ^block_tree.Block) -> Pointer {
	return plan_write(bytes)
}

counter_write_data :: proc "contextless" (_: ^block_tree.Counter, bytes: ^block_tree.Block, check: u64) -> Pointer {
	return plan_write_checked(bytes, check, true)
}

// index_load gives the version work of an object of the plan.
index_load :: proc "contextless" (entry_index: int) -> ^Index_Work {
	work := &plan.index_work[entry_index]
	if work.loaded {
		return work
	}
	work.loaded = true
	work.touched = false
	work.original = plan.entries[entry_index].entry.versions
	work.index = {}
	if work.original.block != 0 {
		switch read_single(work.original, (^Block)(&work.index)) {
		case .Device:
			plan.device = true
		case .Wrong:
			index_drop(work)
		case .Good:
			if work.index.leaf_count > format.VERSION_INDEX_CAPACITY {
				index_drop(work)
			}
		}
	}
	return work
}

// index_drop drops the versions of an object whose index has a wrong check
// or a count that the format does not permit: they are not known. The
// object keeps its current version, and a write or a remove of it works.
// The leaves and the states under the index are not released: the open did
// not count them when it found the index wrong.
index_drop :: proc "contextless" (work: ^Index_Work) {
	work.index = {}
	work.touched = true
	plan.dropped_versions += 1
}

// leaf_load gives a leaf of the version work of an object.
leaf_load :: proc "contextless" (entry_index: int, position: int) -> ^Leaf_Work {
	for &work in plan.leaf_work[:plan.leaf_count] {
		if work.entry == entry_index && work.position == position {
			return &work
		}
	}
	if plan.leaf_count >= LEAF_WORK_CAPACITY || position < 0 || position >= format.VERSION_INDEX_CAPACITY {
		capacity_reached(LEAF_WORK_CAPACITY)
		return nil
	}
	index := index_load(entry_index)
	work := &plan.leaf_work[plan.leaf_count]
	plan.leaf_count += 1
	work^ = {entry = entry_index, position = position}
	if position < int(index.index.leaf_count) && index.index.leaves[position].block != 0 {
		work.original = index.index.leaves[position]
		switch read_single(work.original, (^Block)(&work.leaf)) {
		case .Device:
			plan.device = true
		case .Wrong:
			leaf_drop(work)
		case .Good:
			if work.leaf.count == 0 || work.leaf.count > format.VERSION_LEAF_CAPACITY {
				leaf_drop(work)
			}
		}
	}
	return work
}

// leaf_drop drops the versions of a leaf with a wrong check or a count that
// the format does not permit, as index_drop does for an index: the plan
// writes no leaf in its place, and its states are not released.
leaf_drop :: proc "contextless" (work: ^Leaf_Work) {
	work.leaf = {}
	work.changed = true
	plan.dropped_versions += 1
}

// version_add adds a version at the end of the versions of an object.
version_add :: proc "contextless" (entry_index: int, entry: Version_Entry) {
	index := index_load(entry_index)
	if index.index.version_count >= format.VERSIONS_LIMIT {
		version_remove_first(entry_index)
	}
	index.touched = true
	position := int(index.index.leaf_count) - 1
	leaf: ^Leaf_Work
	if position >= 0 {
		leaf = leaf_load(entry_index, position)
	}
	// A full index whose last leaf is full: the retention rule left a few
	// entries in each leaf, so the entries move to the first leaves.
	if leaf != nil && storage_mount.version_leaves_full(int(index.index.leaf_count), leaf.leaf.count) {
		leaves_compact(entry_index)
	}
	if leaf == nil || leaf.leaf.count >= format.VERSION_LEAF_CAPACITY {
		if index.index.leaf_count >= format.VERSION_INDEX_CAPACITY {
			capacity_reached(format.VERSION_INDEX_CAPACITY)
			return
		}
		position = int(index.index.leaf_count)
		index.index.leaves[position] = {}
		index.index.leaf_count += 1
		leaf = leaf_load(entry_index, position)
		if leaf == nil {
			return
		}
	}
	leaf.leaf.entries[leaf.leaf.count] = entry
	leaf.leaf.count += 1
	leaf.changed = true
	index.index.version_count += 1
	plan.versions_change += 1
}

// The leaves of one object during a compaction.
compaction: [format.VERSION_INDEX_CAPACITY]Version_Leaf

// leaves_compact moves the versions of an object to its first leaves, in
// their order (storage_mount.version_leaves_compact). Each leaf is written
// again; a leaf left with no entry is dropped by plan_finish. The last leaf
// of the index is then empty, and version_add puts the new version there:
// plan_finish keeps the order of the positions.
leaves_compact :: proc "contextless" (entry_index: int) {
	index := index_load(entry_index)
	count := int(index.index.leaf_count)
	for position in 0 ..< count {
		work := leaf_load(entry_index, position)
		if work == nil {
			return
		}
		compaction[position] = work.leaf
	}
	storage_mount.version_leaves_compact(compaction[:count])
	for position in 0 ..< count {
		work := leaf_load(entry_index, position)
		work.leaf = compaction[position]
		work.changed = true
	}
}

// version_first gives the oldest version of an object in the plan.
version_first :: proc "contextless" (entry_index: int) -> (leaf: ^Leaf_Work, found: bool) {
	index := index_load(entry_index)
	for position in 0 ..< int(index.index.leaf_count) {
		work := leaf_load(entry_index, position)
		if work == nil {
			return nil, false
		}
		if work.leaf.count != 0 {
			return work, true
		}
	}
	return nil, false
}

// version_remove_first thins the oldest version of an object.
version_remove_first :: proc "contextless" (entry_index: int) {
	leaf, found := version_first(entry_index)
	if !found {
		return
	}
	entry := leaf.leaf.entries[0]
	copy(leaf.leaf.entries[:leaf.leaf.count - 1], leaf.leaf.entries[1:leaf.leaf.count])
	leaf.leaf.count -= 1
	leaf.leaf.entries[leaf.leaf.count] = {}
	leaf.changed = true
	index := index_load(entry_index)
	index.touched = true
	index.index.version_count -= 1
	plan.versions_change -= 1
	plan.thinned += 1
	state_release(entry.root, entry.size)
}

// versions_release removes all the versions of an object (its remove).
versions_release :: proc "contextless" (entry_index: int) {
	index := index_load(entry_index)
	for position in 0 ..< int(index.index.leaf_count) {
		leaf := leaf_load(entry_index, position)
		if leaf == nil {
			return
		}
		for entry in leaf.leaf.entries[:leaf.leaf.count] {
			// A state with a wrong block, known before or found by its
			// release, keeps the blocks under it in use until the next start:
			// the erase of versions reports it, one count for each state.
			counted := plan.release_damaged
			known := state_damaged(entry.root) || entry.size > format.OBJECT_SIZE_LIMIT
			state_release(entry.root, entry.size)
			plan.release_damaged = counted + ((known || plan.release_damaged != counted) ? u64(1) : u64(0))
		}
		plan.versions_change -= i64(leaf.leaf.count)
		leaf.leaf.count = 0
		leaf.changed = true
	}
	index.index.version_count = 0
	index.touched = true
}

// The times of the versions of one object, and what the rule keeps.
times: [format.VERSIONS_LIMIT]u64
keep: [format.VERSIONS_LIMIT]bool

// retention applies the retention rule to the versions of an object, when
// it did not run in the last minute.
retention :: proc "contextless" (entry_index: int, now: u64) {
	index := index_load(entry_index)
	if index.original.block == 0 || now < index.index.retention_time + RETENTION_INTERVAL {
		return
	}
	index.touched = true
	index.index.retention_time = now
	// The age of each version: the smaller of its age by the date and its
	// age by the time that machines ran (storage_retention.age).
	date_seconds := date_now()
	rule_now := storage_retention.rule_now(now, date_seconds)
	count := 0
	for position in 0 ..< int(index.index.leaf_count) {
		leaf := leaf_load(entry_index, position)
		if leaf == nil {
			return
		}
		for entry in leaf.leaf.entries[:leaf.leaf.count] {
			times[count] = rule_now - min(storage_retention.age(now, entry.time, date_seconds, entry.date), rule_now)
			count += 1
		}
	}
	if storage_retention.keeps(times[:count], rule_now, keep[:count]) == 0 {
		return
	}
	at := 0
	for position in 0 ..< int(index.index.leaf_count) {
		leaf := leaf_load(entry_index, position)
		kept: u64
		for entry in leaf.leaf.entries[:leaf.leaf.count] {
			if keep[at] {
				leaf.leaf.entries[kept] = entry
				kept += 1
			} else {
				state_release(entry.root, entry.size)
				plan.thinned += 1
				plan.versions_change -= 1
				index.index.version_count -= 1
			}
			at += 1
		}
		if kept != leaf.leaf.count {
			for place in kept ..< leaf.leaf.count {
				leaf.leaf.entries[place] = {}
			}
			leaf.leaf.count = kept
			leaf.changed = true
		}
	}
}

// projected gives the distinct blocks of the store after the plan, with the
// leaves and the indexes that the plan still has to write.
projected :: proc "contextless" () -> i64 {
	change := plan.used_change
	for &index, entry_index in plan.index_work[:plan.entry_count] {
		if !index.loaded || !index.touched {
			continue
		}
		left := 0
		for position in 0 ..< int(index.index.leaf_count) {
			leaf: ^Leaf_Work
			for &work in plan.leaf_work[:plan.leaf_count] {
				if work.entry == entry_index && work.position == position {
					leaf = &work
				}
			}
			original := position < len(index.index.leaves) ? index.index.leaves[position] : Pointer{}
			count := leaf != nil ? leaf.leaf.count : 1
			if count != 0 {
				left += 1
			}
			if original.block == 0 && count != 0 {
				change += 1
			} else if original.block != 0 && count == 0 {
				change -= 1
			}
		}
		if index.original.block == 0 && left != 0 {
			change += 1
		} else if index.original.block != 0 && left == 0 {
			change -= 1
		}
	}
	// The nodes that the trees write, less those that they stop naming; a
	// tree inside a tree also changes the path of its entry in the tree
	// above it, which is not dirty yet: one node for each level of it.
	change += plan_trees_node_change()
	return i64(plan.next.stores[plan.store_index].used) + change
}

// plan_finish writes the leaves and the indexes that changed, and puts
// each entry of the plan in its tree; then the trees, from the deepest up,
// and the store block (trees.odin). The plan names the new blocks and
// stops naming the blocks they replace.
plan_finish :: proc "contextless" () {
	for &index, entry_index in plan.index_work[:plan.entry_count] {
		item := &plan.entries[entry_index]
		if !index.loaded || !index.touched {
			continue
		}
		next := index.index
		next.leaf_count = 0
		for position in 0 ..< int(index.index.leaf_count) {
			leaf: ^Leaf_Work
			for &work in plan.leaf_work[:plan.leaf_count] {
				if work.entry == entry_index && work.position == position {
					leaf = &work
				}
			}
			original := index.index.leaves[position]
			pointer := original
			if leaf != nil && leaf.changed {
				if original.block != 0 {
					delta_add(original.block, -1)
				}
				if leaf.leaf.count == 0 {
					continue
				}
				pointer = plan_write((^Block)(&leaf.leaf))
				if pointer.block != 0 {
					cache_later(pointer, (^Block)(&leaf.leaf))
				}
			}
			next.leaves[next.leaf_count] = pointer
			next.leaf_count += 1
		}
		for place in next.leaf_count ..< format.VERSION_INDEX_CAPACITY {
			next.leaves[place] = {}
		}
		if index.original.block != 0 {
			delta_add(index.original.block, -1)
		}
		if next.leaf_count == 0 || item.gone {
			item.entry.versions = {}
			continue
		}
		block_bytes := &plan.index_blocks[entry_index]
		intrinsics.mem_copy_non_overlapping(block_bytes, &next, BLOCK_SIZE)
		item.entry.versions = plan_write(block_bytes)
		if item.entry.versions.block != 0 {
			cache_later(item.entry.versions, block_bytes)
		}
	}
	plan_entries_put()
	plan_trees_finish()
	entry := &plan.next.stores[plan.store_index]
	if entry.store.block != 0 {
		delta_add(entry.store.block, -1)
	}
	intrinsics.mem_copy_non_overlapping(&plan.store_block_bytes, &plan.store_block, BLOCK_SIZE)
	entry.store = plan_write(&plan.store_block_bytes)
}

// The leaves and indexes that the commit writes go to the cache after it.
later: [256]struct {
	pointer: Pointer,
	bytes:   ^Block,
}
later_count: int

cache_later :: proc "contextless" (pointer: Pointer, bytes: ^Block) {
	if later_count < len(later) {
		later[later_count] = {pointer, bytes}
		later_count += 1
	}
}

// plan_commit writes the blocks of the plan, then the root, and gives the
// new state to the service. It gives the generation and Succeeded, or 0 and
// the call outcome with the error record.
plan_commit :: proc "contextless" (error: ^errors.Error_Record) -> (value: i64, outcome: call_outcome.Call_Outcome) {
	plan_trees_failure_take()
	if plan.tree_damaged {
		plan_drop()
		store_damaged[plan.store_index] = true
		system.log_fact(.Warning, Tree_Node_Damaged{store = store_field(system.name_of(plan.next.stores[plan.store_index].name[:]))})
		return call_outcome.fail_with_value_first(error, .Data_Damaged, .Damaged, .Stores)
	}
	if plan.device {
		plan_drop()
		return call_outcome.fail_with_value_first(error, .Callee_Unavailable, .Device)
	}
	if plan.count_fault {
		plan_drop()
		store_faulty[plan.store_index] = true
		system.log_fact(.Error, Commit_Count_Below_Zero{store = store_field(system.name_of(plan.next.stores[plan.store_index].name[:]))})
		return call_outcome.fail_with_value_first(error, .Data_Damaged, .Damaged, .Counts)
	}
	if plan.capacity_reached {
		plan_drop()
		return call_outcome.fail_with_value_first(error, .Budget_Or_Capacity_Exhausted, .Full, .Commit_Blocks, 0, 0, i64(plan.capacity_limit))
	}
	if plan.count_overflow {
		plan_drop()
		return call_outcome.fail_with_value_first(error, .Budget_Or_Capacity_Exhausted, .Over_Limit, .References, 0, i64(REFERENCE_LIMIT) + 1, i64(REFERENCE_LIMIT))
	}
	if plan.full {
		plan_drop()
		return call_outcome.fail_with_value_first(error, .Budget_Or_Capacity_Exhausted, .Full) // The disk: no number, because the free blocks are a fact of all the stores.
	}
	entry := &plan.next.stores[plan.store_index]
	entry.used = u64(i64(entry.used) + plan.used_change)
	// The blocks, REGION_BLOCKS at a time, then the root. Each one is on the
	// disk before the next step.
	for first := 0; first < plan.write_count; first += REGION_BLOCKS {
		part := plan.writes[first:min(first + REGION_BLOCKS, plan.write_count)]
		requests: [REGION_BLOCKS]Request
		for write, index in part {
			intrinsics.mem_copy_non_overlapping(raw_data(slot(u64(index))), write.bytes, BLOCK_SIZE)
			requests[index] = {number = write.number, slot = u64(index)}
		}
		if !transfer(.Write, requests[:len(part)]) {
			plan_drop()
			return call_outcome.fail_with_value_first(error, .Callee_Unavailable, .Device)
		}
		blocks_written += u64(len(part))
	}
	if !flush() {
		plan_drop()
		return call_outcome.fail_with_value_first(error, .Callee_Unavailable, .Device)
	}
	plan.next.generation = root.generation + 1
	// The device answered Ok to each write; a disk that did not keep one
	// gives other bytes at the read. The blocks are read back before the
	// root: a commit with a dropped block then never has a root on the
	// disk, and no later write can make that root whole
	// (src/md/features/dropped_write.md).
	differ, blocks_state := commit_blocks_read_back()
	switch blocks_state {
	case .Good:
	case .Wrong:
		// Nothing on the disk names the blocks of the commit, and the state
		// in memory is still the state of the root before: the service goes
		// on from it.
		plan_drop()
		commits_refused += 1
		if differ == 1 {
			system.log_fact(.Error, Commit_Block_Dropped{generation = plan.next.generation, generation_before = root.generation})
		} else {
			system.log_fact(.Error, Commit_Blocks_Dropped{generation = plan.next.generation, blocks = differ, generation_before = root.generation})
		}
		return call_outcome.fail_with_value_first(error, .Callee_Unavailable, .Device, .Dropped_Writes, 0, 0, 0, i64(differ))
	case .Device:
		// No root names the blocks: the disk holds the state before.
		plan_drop()
		commits_refused += 1
		system.log_fact(.Error, Commit_Read_Back_Failed{generation = plan.next.generation})
		return call_outcome.fail_with_value_first(error, .Callee_Unavailable, .Device)
	}
	plan.next.time = time_now()
	plan.next.date = date_now()
	plan.next.check = root_check(&plan.next)
	intrinsics.mem_copy_non_overlapping(raw_data(slot(0)), &plan.next, BLOCK_SIZE)
	place := 1 - root_place
	if !transfer(.Write, {{number = place, slot = 0}}) || !flush() {
		// The root on the disk is the old one, or the new one: the service
		// cannot know. It stops serving changes.
		plan_drop()
		root_undecided(plan.next.generation, .Write)
		return call_outcome.fail_with_value_first(error, .Callee_Unavailable, .Device)
	}
	blocks_written += 1
	// The root too: if the disk did not keep it, the root before is still
	// the newest on the disk, and a commit that took this state would write
	// over the blocks that the root before names.
	switch root_read_back(place, &plan.next) {
	case .Good:
	case .Wrong:
		// The place holds an older root or other bytes, and the root before
		// stays the newest: the service goes on from it, and the next commit
		// writes its root in that place.
		plan_drop()
		commits_refused += 1
		system.log_fact(.Error, Commit_Root_Dropped{generation = plan.next.generation, generation_before = root.generation})
		root_refused_in_a_row()
		return call_outcome.fail_with_value_first(error, .Callee_Unavailable, .Device, .Dropped_Writes, 0, 0, 0, 1)
	case .Device:
		// The root can be on the disk: as for a failed write of a root.
		plan_drop()
		root_undecided(plan.next.generation, .Read_Back)
		return call_outcome.fail_with_value_first(error, .Callee_Unavailable, .Device)
	}
	roots_refused_in_a_row = 0
	// The commit is on the disk: the service takes its state.
	root = plan.next
	root_place = place
	store_blocks[plan.store_index] = plan.store_block
	commits += 1
	opened.store_versions[plan.store_index] = u64(i64(opened.store_versions[plan.store_index]) + plan.versions_change)
	if plan.dropped_versions != 0 {
		system.log_fact(.Warning, Versions_Dropped_At_Commit{generation = root.generation, dropped = plan.dropped_versions, store = store_field(system.name_of(root.stores[plan.store_index].name[:]))})
	}
	owner := u8(plan.store_index + 1)
	for place in plan.delta_places[:plan.delta_count] {
		number := plan.delta_blocks[place]
		before := i64(opened.references[number])
		after := before + i64(plan.delta_values[place]) // From 0 to REFERENCE_LIMIT: delta_add refused the commit else.
		opened.references[number] = u32(after)
		if before < 2 && after >= 2 {
			opened.store_shared[plan.store_index] += 1
		} else if before >= 2 && after < 2 {
			opened.store_shared[plan.store_index] -= 1
		}
		if after == 0 {
			mark(number, false)
			opened.owner[number] = 0
		} else {
			opened.owner[number] = owner
		}
	}
	// The hash index follows the entries that the commit changed, after the
	// owners: a root of the index is a block of its store. While the store
	// has a writable share of a tree open, a new root is hidden: never a
	// candidate, so the holder cannot plant bytes that a later write of the
	// maker would find (docs/STORAGE.md, "4.7 The same object one time").
	hidden := writable_tree_share_open(system.name_of(root.stores[plan.store_index].name[:]))
	for &item in plan.entries[:plan.entry_count] {
		storage_mount.hash_index_entry_change(&opened, item.before, item.entry, item.gone, hidden)
	}
	for item in later[:later_count] {
		cache_put(item.pointer, item.bytes)
	}
	later_count = 0
	plan.taken_count = 0
	return i64(root.generation), .Succeeded
}

// root_again writes the root of the last commit again, with the next
// generation, in the other place of the root, then a Flush. Until then the
// root before the last commit is on the disk, whole, and names each block
// that the last commit freed; after it, neither root names one, so the
// erase of versions can write zeros over them
// (src/md/features/version_erase.md). It reads the root back: the zeros go
// only over blocks that no root on the disk names, and a second root that
// the disk did not keep leaves the root before the last commit there.
//   .Good:   the second root is on the disk; the service takes it.
//   .Wrong:  the disk did not keep it; the service keeps the last commit,
//            whose next commit writes its root over the root before.
//   .Device: a write, the Flush or the read failed; the service cannot know
//            which root the disk has, and stops serving changes.
root_again :: proc "contextless" () -> Read {
	if broken {
		return .Device
	}
	next := root
	next.generation = root.generation + 1
	next.time = time_now()
	next.date = date_now()
	next.check = root_check(&next)
	intrinsics.mem_copy_non_overlapping(raw_data(slot(0)), &next, BLOCK_SIZE)
	place := 1 - root_place
	// The caller writes the line of a failure: it names the object.
	if !transfer(.Write, {{number = place, slot = 0}}) || !flush() {
		commits_undecided += 1
		broken = true
		return .Device
	}
	blocks_written += 1
	switch root_read_back(place, &next) {
	case .Good:
	case .Wrong:
		commits_refused += 1
		root_refused_in_a_row()
		return .Wrong
	case .Device:
		commits_undecided += 1
		broken = true
		return .Device
	}
	roots_refused_in_a_row = 0
	root = next
	root_place = place
	commits += 1
	return .Good
}

// freed_blocks_zero writes zero bytes over each block that the last commit
// freed: each block of the change of the reference counts of the plan
// whose count is 0 now. Nothing names them, and no commit took one since:
// the service runs one call at a time. Then it reads them back, because a
// write of zeros that the disk drops leaves the old bytes, the bytes that
// the erase exists to remove. It gives the blocks that read back as zeros
// and the blocks that read back with other bytes, on every path: a block
// that no read reached counts in neither. ok is false when a write, the
// Flush or a read failed.
freed_blocks_zero :: proc "contextless" () -> (zeroed: u64, not_zeroed: u64, ok: bool) {
	intrinsics.mem_zero(region, REGION_BLOCKS * BLOCK_SIZE)
	requests: [REGION_BLOCKS]Request
	count := 0
	for place in plan.delta_places[:plan.delta_count] {
		number := plan.delta_blocks[place]
		if !freed_block(number) {
			continue
		}
		cache_forget(number)
		requests[count] = {number = number, slot = u64(count)}
		count += 1
		if count < REGION_BLOCKS {
			continue
		}
		if !transfer(.Write, requests[:count]) {
			return 0, 0, false
		}
		blocks_written += u64(count)
		count = 0
	}
	if count > 0 {
		if !transfer(.Write, requests[:count]) {
			return 0, 0, false
		}
		blocks_written += u64(count)
	}
	if !flush() {
		return 0, 0, false
	}
	// The read back: the region now receives the bytes of the disk.
	count = 0
	for place in plan.delta_places[:plan.delta_count] {
		number := plan.delta_blocks[place]
		if !freed_block(number) {
			continue
		}
		requests[count] = {number = number, slot = u64(count)}
		count += 1
		if count < REGION_BLOCKS {
			continue
		}
		if !zeros_read_back(requests[:count], &zeroed, &not_zeroed) {
			return zeroed, not_zeroed, false
		}
		count = 0
	}
	if count > 0 && !zeros_read_back(requests[:count], &zeroed, &not_zeroed) {
		return zeroed, not_zeroed, false
	}
	return zeroed, not_zeroed, true
}

// freed_block says if a block of the change of the reference counts of the
// plan is free now: the erase writes zeros over it.
freed_block :: proc "contextless" (number: u64) -> bool {
	return number >= 2 && number < disk_size && opened.references[number] == 0
}

// zeros_read_back reads blocks that the erase wrote with zeros, and counts
// each one in `zeroed` when it holds zeros, in `not_zeroed` when it holds
// other bytes. A failed read counts none.
zeros_read_back :: proc "contextless" (requests: []Request, zeroed: ^u64, not_zeroed: ^u64) -> bool {
	started := system.nanoseconds()
	defer read_back_nanoseconds += system.nanoseconds() - started
	if !transfer(.Read, requests) {
		return false
	}
	blocks_read_back += u64(len(requests))
	for index in 0 ..< len(requests) {
		if block_tree.is_zero(slot(u64(index))) {
			zeroed^ += 1
		} else {
			not_zeroed^ += 1
		}
	}
	return true
}

// released_blocks_kept counts the blocks that the last commit took a name
// from and that another state still names: the erase of versions leaves
// their bytes, as a state that stays holds them. A node whose children are
// shared too counts one: the release stops at it.
released_blocks_kept :: proc "contextless" () -> (kept: u64) {
	for place in plan.delta_places[:plan.delta_count] {
		number := plan.delta_blocks[place]
		if plan.delta_values[place] < 0 && number < DISK_BLOCKS_LIMIT && opened.references[number] != 0 {
			kept += 1
		}
	}
	return kept
}

// commit_blocks_read_back reads each block that the commit of the plan
// wrote from the device, past the cache of the service, and compares it
// with the bytes that the commit wrote. A disk that answers a read from the
// same cache that lost the write still passes: the read back proves only
// what the device gives (src/md/features/dropped_write.md). The blocks and
// the time count in the measure that stores() gives.
commit_blocks_read_back :: proc "contextless" () -> (differ: u64, state: Read) {
	started := system.nanoseconds()
	defer read_back_nanoseconds += system.nanoseconds() - started
	for first := 0; first < plan.write_count; first += REGION_BLOCKS {
		part := plan.writes[first:min(first + REGION_BLOCKS, plan.write_count)]
		requests: [REGION_BLOCKS]Request
		for write, index in part {
			requests[index] = {number = write.number, slot = u64(index)}
		}
		if !transfer(.Read, requests[:len(part)]) {
			return differ, .Device
		}
		blocks_read_back += u64(len(part))
		for write, index in part {
			if string(slot(u64(index))) != string(write.bytes^[:]) {
				differ += 1
			}
		}
	}
	return differ, differ == 0 ? .Good : .Wrong
}

// After this many roots in a row that the disk did not keep, the service
// stops its changes. The two places of the root are fixed: a commit cannot
// move its root to another block, as it moves its other blocks. So a place
// that drops each write refuses each commit, and each one costs its writes
// and a line for nothing. Three in a row tells such a place from one lost
// write; the reads go on, and the next start opens the disk again.
ROOT_REFUSAL_LIMIT :: 3

// root_refused_in_a_row counts a root that the disk did not keep, and stops
// the changes of the service at ROOT_REFUSAL_LIMIT in a row.
root_refused_in_a_row :: proc "contextless" () {
	roots_refused_in_a_row += 1
	if roots_refused_in_a_row == ROOT_REFUSAL_LIMIT {
		broken = true
		system.log_fact(.Error, Root_Place_Drops_Writes{commits = u64(ROOT_REFUSAL_LIMIT)})
	}
}

// The step of a root that failed on the device.
Root_Failure :: enum {
	Write, // The write of the root, or its Flush.
	Read_Back, // The read back of the root.
}

// root_undecided ends a commit whose root can be on the disk or not: the
// service does not take it, makes no change until its next start, and the
// open of that start decides.
root_undecided :: proc "contextless" (generation: u64, failed_step: Root_Failure) {
	commits_undecided += 1
	broken = true
	switch failed_step {
	case .Write:
		system.log_fact(.Error, Root_Write_Failed{generation = generation})
	case .Read_Back:
		system.log_fact(.Error, Root_Read_Back_Failed{generation = generation})
	}
}

// root_read_back reads the root in `place` from the device and compares it
// with the root that the service wrote there.
root_read_back :: proc "contextless" (place: u64, written: ^Root) -> Read {
	started := system.nanoseconds()
	defer read_back_nanoseconds += system.nanoseconds() - started
	if !transfer(.Read, {{number = place, slot = 0}}) {
		return .Device
	}
	blocks_read_back += 1
	return string(slot(0)) == string(([^]u8)(written)[:BLOCK_SIZE]) ? .Good : .Wrong
}

