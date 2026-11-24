package storage_service

import "base:intrinsics"
import "modus:contract/block"
import "modus:contract/date"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:contract/ring"
import format "modus:contract/store"
import "internal:storage/block_counts"
import "internal:storage/storage_mount"
import "internal:storage/storage_release"
import block_tree "internal:storage/storage_object"
import "internal:storage/storage_retention"
import tree "internal:storage/storage_tree"
import "internal:storage/store_encryption"
import "modus:system"

// The format of the disk, and the one rule that keeps it whole (copy on
// write), are in src/library/modus/contract/store. The model of objects, trees and stores:
// docs/STORAGE.md. The versions: docs/ARCHITECTURE.md, "Versions".

BLOCK_SIZE :: format.BLOCK_SIZE
ROOT_MAGIC :: format.ROOT_MAGIC
STORE_CAPACITY :: format.STORE_CAPACITY
NAME_CAPACITY :: format.NAME_CAPACITY
OBJECT_LEVEL_LIMIT :: format.OBJECT_LEVEL_LIMIT
REGION_BLOCKS :: 64 // The data region that the block service reads and writes.
RETENTION_INTERVAL :: 60 * 1000 // The retention rule runs on an object at most one time in this many milliseconds.

Pointer :: format.Pointer
Store_Entry :: format.Store_Entry
Root :: format.Root
Store_Block :: format.Store_Block
Store_Head :: storage_mount.Store_Head
Store_Table_Page :: format.Store_Table_Page
Entry :: format.Entry
Entry_Name :: format.Entry_Name
Object_Node :: format.Object_Node
Object_Child :: format.Object_Child
Version_Entry :: format.Version_Entry
Version_Leaf :: format.Version_Leaf
Version_Index :: format.Version_Index
Block :: [BLOCK_SIZE]u8

#assert(BLOCK_SIZE == block.BLOCK_SIZE)

// What the service knows of the disk. The head of the store block of each
// store stays in memory, and the pages of the store table in `opened`;
// nodes, object nodes, versions and data are read when a caller asks. The
// blocks in use and the reference count of each one are in `opened`, the
// state of the open (src/library/internal/storage/storage_mount), which the
// service keeps up to date. A store is named by its number in the store
// table: its page and its cell (format.store_place).
root: Root
root_place: u64 // 0 or 1: the place of the root on the disk.
store_blocks: [STORE_CAPACITY]Store_Head
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

// blocks_in_use gives the blocks in use, in either form of the counts.
blocks_in_use :: proc "contextless" () -> u64 {
	return storage_mount.blocks_in_use(&opened)
}

// allocate gives a free block and marks it, or 0 when the disk is full.
// In the form Count_Tree, a free block has the count 0 in the count tree
// and no name in the plan: a block that the last commit freed is free, a
// block that the plan stops naming is not (its root still names it).
allocate :: proc "contextless" () -> u64 {
	if opened.form == .Count_Tree {
		// A page of the tally of a recount whose write runs is not free: the
		// leaves after the commit still read it.
		in_plan :: proc "contextless" (data: rawptr, number: u64) -> bool {
			return delta_of(number) > 0 || storage_mount.recount_holds_block(&opened, number)
		}
		number := block_counts.free_search(&opened.counts, next_free, in_plan, nil)
		if number != 0 {
			next_free = number + 1
		}
		return number
	}
	searched: u64
	for searched < root.disk_blocks {
		if next_free < 2 || next_free >= root.disk_blocks {
			next_free = 2
		}
		number := next_free
		// A word of the bitmap with each block in use is passed whole: the
		// search of a disk of millions of blocks reads one word for 64.
		if number % 64 == 0 && number + 64 <= root.disk_blocks && opened.in_use[number / 64] == max(u64) {
			next_free += 64
			searched += 64
			continue
		}
		next_free += 1
		searched += 1
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
			if completion.kind != u32(call_outcome.Call_Outcome.Succeeded) {
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
// completion (disk_wait_goes_on), it gives the completion of a failed
// device with the record No_Answer of the device, as the block service
// gives one.
command :: proc "contextless" (kind: block.Command, values: [7]u64 = {}) -> ring.Record {
	silent := ring.Record{kind = u32(block.device_failure_outcome(kind)), values = block.no_answer_values(kind)}
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
	return command(.Flush).kind == u32(call_outcome.Call_Outcome.Succeeded)
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
	number:      u64,
	check:       u64,
	used:        u64, // The count of reads at its last use.
	store_index: i32, // Owning store cell index, or -1 for non-store blocks.
	owner_slot:  u8,  // Principal slot + 1 for owned stores; 0 for principal 0 or untagged.
	bytes:       Block,
}
block_cache: [64]Cached_Block // The nodes near the roots of the trees that the last calls used (always on-disk bytes).
cache_reads: u64

cache_put :: proc "contextless" (pointer: Pointer, bytes: ^Block, store_index := active_store_index, owner_slot := active_store_owner_slot) {
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
	block_cache[oldest] = {number = pointer.block, check = pointer.check, used = cache_reads, store_index = i32(store_index), owner_slot = owner_slot}
	block_cache[oldest].bytes = bytes^
}

// cache_tag binds an already cached block to its verified store and principal slot.
cache_tag :: proc "contextless" (pointer: Pointer, store_index: int, owner_slot: u8) {
	if pointer.block == 0 {
		return
	}
	for &entry in block_cache {
		if entry.number == pointer.block && entry.check == pointer.check {
			entry.store_index = i32(store_index)
			entry.owner_slot = owner_slot
			return
		}
	}
}

// cache_forget drops a block from the cache: the erase of versions writes
// zeros over it, and the memory of the service keeps no copy of it.
cache_forget :: proc "contextless" (number: u64) {
	for &entry in block_cache {
		if entry.number == number {
			intrinsics.mem_zero_volatile(&entry, size_of(Cached_Block))
		}
	}
}

// read_single_tagged reads one block, checked, through the cache (on-disk
// bytes), tagging any cache fill or untagged cache hit with store_index and
// owner_slot so lock eviction always removes every block of that principal.
read_single_tagged :: proc "contextless" (pointer: Pointer, into: ^Block, store_index: int, owner_slot: u8) -> Read {
	cache_reads += 1
	for &entry in block_cache {
		if entry.number == pointer.block && entry.check == pointer.check && pointer.block != 0 {
			entry.used = cache_reads
			if store_index >= 0 && entry.store_index < 0 {
				entry.store_index = i32(store_index)
			}
			if owner_slot != 0 && entry.owner_slot == 0 {
				entry.owner_slot = owner_slot
			}
			into^ = entry.bytes
			return .Good
		}
	}
	_, state := read_checked({pointer}, 0)
	if state == .Good {
		intrinsics.mem_copy_non_overlapping(into, raw_data(slot(0)), BLOCK_SIZE)
		cache_put(pointer, into, store_index, owner_slot)
	}
	return state
}

// read_single reads one block, checked, through the cache (on-disk bytes).
read_single :: proc "contextless" (pointer: Pointer, into: ^Block) -> Read {
	return read_single_tagged(pointer, into, active_store_index, active_store_owner_slot)
}

// read_tree_node reads a B+ tree node and opens/authenticates it when an
// encrypted store scope is active.
read_tree_node :: proc "contextless" (pointer: Pointer, into: ^Block) -> Read {
	outcome := read_single(pointer, into)
	if outcome == .Good && active_store_keys != nil {
		if !store_encryption.tree_node_open(active_store_keys, pointer.block, pointer.check, into) {
			return .Wrong
		}
	}
	return outcome
}

// read_object_node reads an Object_Node and opens/authenticates it when an
// encrypted store scope is active.
read_object_node :: proc "contextless" (pointer: Pointer, into: ^Object_Node) -> Read {
	outcome := read_single(pointer, (^Block)(into))
	if outcome == .Good && active_store_keys != nil {
		if !store_encryption.object_node_open(active_store_keys, pointer.block, pointer.check, into) {
			return .Wrong
		}
	}
	return outcome
}

// read_version_index reads a Version_Index and opens/authenticates it when
// an encrypted store scope is active.
read_version_index :: proc "contextless" (pointer: Pointer, into: ^Version_Index) -> Read {
	outcome := read_single(pointer, (^Block)(into))
	if outcome == .Good && active_store_keys != nil {
		if !store_encryption.version_index_open(active_store_keys, pointer.block, pointer.check, into) {
			return .Wrong
		}
	}
	return outcome
}

// read_version_leaf reads a Version_Leaf and opens/authenticates it when an
// encrypted store scope is active.
read_version_leaf :: proc "contextless" (pointer: Pointer, into: ^Version_Leaf) -> Read {
	outcome := read_single(pointer, (^Block)(into))
	if outcome == .Good && active_store_keys != nil {
		if !store_encryption.version_leaf_open(active_store_keys, pointer.block, pointer.check, into) {
			return .Wrong
		}
	}
	return outcome
}

// read_release_list reads a Release_List and verifies its MAC when an
// encrypted store scope is active.
read_release_list :: proc "contextless" (pointer: Pointer, into: ^format.Release_List) -> Read {
	outcome := read_single(pointer, (^Block)(into))
	if outcome == .Good && active_store_keys != nil {
		if !store_encryption.release_list_open(active_store_keys, pointer.block, pointer.check, into) {
			return .Wrong
		}
	}
	return outcome
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
// no check (clear) or ciphertext check plus decryption (encrypted).
object_source := block_tree.Source {
	read_node            = object_read_node,
	read_block           = object_read_block,
	read_encrypted_block = object_read_encrypted_block,
}

object_read_node :: proc "contextless" (_: ^block_tree.Source, pointer: Pointer, into: ^block_tree.Block) -> block_tree.Read {
	if pointer.block < 2 || pointer.block >= disk_size {
		return .Wrong
	}
	switch read_object_node(pointer, (^Object_Node)(into)) {
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

object_read_encrypted_block :: proc "contextless" (_: ^block_tree.Source, pointer: Pointer, data_check: u64, into: ^block_tree.Block) -> block_tree.Read {
	if active_store_keys == nil || pointer.block < 2 || pointer.block >= disk_size {
		return .Wrong
	}
	switch read_raw(pointer.block, into) {
	case .Good:
		if !store_encryption.data_block_decrypt(active_store_keys, pointer.block, pointer.check, data_check, into) {
			storage_mount.wrong_block_set(&opened, pointer.block)
			return .Wrong
		}
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

// The roots that the hash index holds at most: 2^17 objects of a disk find
// the same bytes one time. Its records and slots take 6 MiB; a root past
// them only loses the lookup (docs/STORAGE.md, "4.7 The same object one
// time").
HASH_ROOTS_MOST :: u64(1) << 17

// The memory of the state that the service holds now. A new binding is
// made and bound before the one before ends: a refusal keeps the binding
// before whole.
state_memory: system.Handle
state_memory_address: rawptr

// The blocks that the tables of the open held: the fact of a root that
// neither form opens names them.
table_blocks_held: u64

// state_memory_bind makes the memory of a form of the state from the
// budget of the service, binds it, then ends the memory before it.
state_memory_bind :: proc "contextless" (binder: ^storage_mount.Memory_Binder, blocks: u64, form: storage_mount.Count_Form, cache_pages: u64) -> bool {
	layout, ok := storage_mount.state_layout(blocks, min(blocks, HASH_ROOTS_MOST), form, cache_pages)
	pages := (layout.bytes + BLOCK_SIZE - 1) / BLOCK_SIZE
	if !ok || pages > op.MEMORY_PAGE_LIMIT {
		return false
	}
	memory, status := system.memory_create(pages)
	if status != .Succeeded {
		return false
	}
	address, map_status := system.memory_map(memory, {.Write})
	if map_status != .Succeeded {
		system.close(memory)
		return false
	}
	// state_bind checks the size before it changes the state: a refusal
	// leaves the binding before as it was.
	slot_key := opened.hash_index.slot_key
	if !storage_mount.state_bind(&opened, ([^]u8)(address)[:layout.bytes], blocks, min(blocks, HASH_ROOTS_MOST), form, cache_pages) {
		system.memory_unmap(address, 0)
		system.close(memory)
		return false
	}
	opened.hash_index.slot_key = slot_key
	state_memory_release(binder)
	state_memory, state_memory_address = memory, address
	// The staging of the count tree in the memory of the state: the one
	// that each commit takes again after a large one.
	plan_fixed.count_staging = opened.count_staging
	plan_fixed.count_staged_slots = opened.count_staged_slots
	return true
}

// state_memory_release ends the memory of the state.
state_memory_release :: proc "contextless" (binder: ^storage_mount.Memory_Binder) {
	if state_memory != 0 {
		system.memory_unmap(state_memory_address, 0)
		system.close(state_memory)
		state_memory, state_memory_address = 0, nil
	}
}

state_binder := storage_mount.Memory_Binder {
	bind    = state_memory_bind,
	release = state_memory_release,
}

// mount opens the disk (storage_mount.open_with_forms), and formats a disk
// that has never had a commit: the first root goes to block 1.
mount :: proc "contextless" (disk_blocks: u64) -> (result: Mount) {
	mount_reader = {read = read_through_block_service}
	open := storage_mount.open_with_forms(&opened, &mount_reader, disk_blocks, &state_binder)
	result = open.result
	table_blocks_held = open.table_blocks
	if open.no_memory {
		system.log_fact(.Error, No_Table_Memory{disk_blocks = blocks_field(disk_blocks)})
		return result
	}
	if open.from_tree && !result.failed {
		system.log_fact(.Info, Disk_Larger_Than_Tables{disk_blocks = blocks_field(disk_blocks), used_blocks = blocks_field(open.table_blocks)})
	}
	disk_size = opened.disk_size
	service_started = system.time()
	if result.failed {
		return result
	}
	if result.needs_format {
		// A new disk: each count is 0, so no count tree holds them all.
		root = {magic = ROOT_MAGIC, generation = 1, disk_blocks = disk_size, date = date_now(), counts_complete = 1}
		root.check = root_check(&root)
		intrinsics.mem_copy_non_overlapping(raw_data(slot(0)), &root, BLOCK_SIZE)
		root_place = 1
		if !transfer(.Write, {{number = 1, slot = 0}}) || !flush() {
			result.failed = true
			return result
		}
		storage_mount.state_tables_clear(&opened)
		opened.store_versions = {}
		opened.store_pages = {}
		opened.store_page_damaged = {}
		mark(0, true)
		mark(1, true)
		storage_mount.count_tree_bind(&opened, &mount_reader, &root)
		result.generation = 1
		return result
	}
	root = opened.root
	root_place = opened.root_place
	store_blocks = opened.store_heads
	store_damaged = opened.store_damaged
	store_faulty = opened.store_faulty
	time_at_start = root.time
	// The count of each store is the recount of the open: the next commit
	// of the store writes it in its page.
	for index in 0 ..< store_numbers() {
		entry := store_cell(index)
		if entry.name[0] != 0 && !store_damaged[index] {
			entry.used = opened.store_recount[index]
		}
	}
	return result
}

// store_numbers gives the count of the numbers of stores that the pages of
// the root hold.
store_numbers :: proc "contextless" () -> int {
	return int(min(root.store_page_count, format.STORE_PAGE_CAPACITY)) * format.STORES_OF_A_PAGE
}

// store_cell gives the cell of the store of a number, as the last commit
// left it.
store_cell :: proc "contextless" (index: int) -> ^Store_Entry {
	return storage_mount.store_cell(&opened, index)
}

// store_name_of gives the name of the store of a number. A store of a
// named principal keeps a name tag only: it is said as such, and its name
// comes from the caller (plan_store_name) or its keys (owned_name_into).
store_name_of :: proc "contextless" (index: int) -> string {
	if store_cell(index).name[0] == format.OWNED_CELL_MARK {
		return "(a store of a named principal)"
	}
	if store_cell(index).name[0] == format.RECLAIMING_CELL_MARK {
		return "(a reclaiming store)"
	}
	return system.name_of(store_cell(index).name[:])
}

// The name of the store of the plan, as the caller named it.
plan_store_name_bytes: system.Name

plan_store_name :: proc "contextless" () -> string {
	return system.name_of(plan_store_name_bytes[:])
}

// store_listed says if a number names a store that the service serves: a
// named cell of a page with no damage.
store_listed :: proc "contextless" (index: int) -> bool {
	page, _ := format.store_place(index)
	return !opened.store_page_damaged[page] && store_cell(index).name[0] != 0
}

// store_find gives the store of a name: a store of a named principal by
// its name tag, with the keys of that principal (owned_stores.odin), a
// store of principal 0 by its name.
store_find :: proc "contextless" (name: string) -> int {
	if slot := owned_slot(name); slot != 0 {
		return owned_find(slot, name)
	}
	for index in 0 ..< store_numbers() {
		if store_listed(index) && !owned_cell(index) && !reclaiming_cell(index) && store_name_of(index) == name {
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

// The fixed capacities of one commit: a commit of one call region, of the
// trees, of the versions. A commit that needs more is refused with Full
// and the unit Commit_Blocks, not with a full disk. Half of DELTA_CAPACITY
// is the count of the blocks whose names one commit changes. The writes:
// the blocks of data of one call region, the object nodes above them, the
// leaves of a whole version index (a compaction or the retention rule),
// and the leaves and indexes that thinning at the limit rewrites in other
// objects. A commit of pending changes adds, in the memory of the pool of
// its connection, the room of its own changes (plan_tables_bind); a state
// too large to release in the room of a commit is released in steps
// (src/md/data/storage_capacity.md, "A large state is released in steps").
DELTA_CAPACITY :: 1 << 19 // Power of 2.
WRITE_CAPACITY :: 4096
COMMIT_SLOT_PAGES :: 24 // 1536 object nodes: one call region spread over a large object.
LEAF_WORK_CAPACITY :: 300 // More than the leaves of one index.
REFERENCE_LIMIT :: storage_mount.REFERENCE_LIMIT

Write :: struct {
	number:         u64,
	bytes:          ^Block,
	encrypted_data: bool, // True for encrypted data blocks: encrypt on the fly into transfer region without mutating bytes^.
	data_check:     u64, // Plaintext value_check used to derive the data block nonce when encrypted_data is true.
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
	// The page of the store table of the store, as the commit changes it,
	// and the block that the commit writes it to (plan_page_write).
	page:         Store_Table_Page,
	page_index:   int,
	page_written: Pointer,
	store_block: Store_Block,
	// The tables of the plan: the fixed ones (plan_fixed), or larger ones
	// in the memory of a pending pool for the commit of its changes.
	writes:      []Write,
	write_count: int,
	taken:       []u64, // Blocks that the plan allocated.
	taken_count: int,
	// The change of the reference counts: an open table of blocks, whose
	// length is a power of 2.
	delta_blocks: []u64,
	delta_values: []i32,
	delta_places: []u32, // The places in use, for the walk and the reset.
	delta_count:  int,
	slot_pages:   []^block_tree.Slot_Page, // The slots of the work on an object.
	owner_count:  int, // The blocks of the table of the blocks outside the stores.
	leaves_touched: int, // The distinct leaves of the count tree that the changes of the plan touch.
	release_count:  int, // The states in plan_fixed.release_lists: the commit gives them to the removal queue.
	// The table of the blocks outside the stores: the fixed one, or one of
	// the room of a large commit. A power of 2 of places.
	outside_blocks: []u64,
	outside_owners: []u16,
	outside_places: []u32,
	used_change:  i64, // The change of the distinct blocks of the store.
	full:         bool, // The disk has no free block: the commit is refused.
	device:       bool, // A read of the plan failed on the device.
	capacity_reached: bool, // A table of the plan had no room: the commit is refused.
	capacity_limit:   int, // The capacity that it reached.
	count_fault:      bool, // A count would go below 0: a fault of the engine.
	count_overflow:   bool, // A count would pass REFERENCE_LIMIT.
	dropped_versions: u64, // Version indexes and leaves with a wrong check that the plan drops.
	release_damaged:  u64, // States that the plan releases with a wrong block under their root or in their list, one count for each: the blocks under it keep dead names until a recount (recount_record), or the next open of the form Tables.
	dead_blocks:      u64, // The blocks that the plan leaves with dead names, as the parents of the wrong nodes count them: at least, as a wrong list or a dropped index gives no count.
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
	// Store encryption state for this plan (volatile-zeroed on drop/commit).
	encrypted:     bool,
	reclaiming:    bool, // True for keyless reclamation mark/step commits: writes clear blocks and skips hash index updates.
	cell_freed:    bool, // True on the final reclamation commit that zeroes the Store_Entry cell for reuse.
	owner_slot:    u64,
	store_keys:    store_encryption.Store_Keys,
	prev_crypto:   Store_Crypto_Scope,
	crypto_active: bool,
}

plan: Plan

// The fixed tables of the plan.
plan_fixed: struct {
	writes:       [WRITE_CAPACITY]Write,
	taken:        [WRITE_CAPACITY]u64,
	delta_blocks: [DELTA_CAPACITY]u64,
	delta_values: [DELTA_CAPACITY]i32,
	delta_places: [DELTA_CAPACITY]u32,
	slot_memory:  [COMMIT_SLOT_PAGES]block_tree.Slot_Page,
	slot_pages:   [COMMIT_SLOT_PAGES]^block_tree.Slot_Page,
	// The blocks that the plan counts outside the stores, with their owner
	// after the commit: the pages of the store table and of the count tree
	// that it takes (their owner) or releases (0). An open table of blocks.
	outside_blocks: [OUTSIDE_SLOTS]u64,
	outside_owners: [OUTSIDE_SLOTS]u16,
	outside_places: [OUTSIDE_SLOTS / 2]u32,
	// The staging of the count tree that the state binds: a large commit
	// takes one of its room from its pool, and gives it back.
	count_staging:      []block_counts.Frame,
	count_staged_slots: []i32,
	// The leaves of the count tree that the changes of the plan touch: an
	// open table of 1 + the leaf, with the places in use.
	leaf_slots:  [LEAF_SLOTS]u64,
	leaf_places: [LEAF_SLOTS / 2]u32,
	// The lists of the states that the commit gives to the removal queue,
	// filled in their order.
	release_lists:  [RELEASE_LISTS_MOST]format.Release_List,
	// The list of a step of the queue, as it reads it and writes it again.
	step_list:      format.Release_List,
}

// The leaves that the table of a plan holds: past half, each new change
// counts as one more leaf.
LEAF_SLOTS :: 8192

// The lists of the states that one commit gives to the removal queue, one
// block each, chained under one entry of the queue. A commit releases the
// versions of the leaves that it holds and the current states of its
// entries, so no commit passes this many lists: a count of large states
// never refuses a commit.
RELEASE_STATES_MOST :: LEAF_WORK_CAPACITY * format.VERSION_LEAF_CAPACITY + PLAN_ENTRY_CAPACITY
RELEASE_LISTS_MOST :: (RELEASE_STATES_MOST + format.RELEASES_OF_A_LIST - 1) / format.RELEASES_OF_A_LIST

// leaf_note counts a leaf of the count tree that a change of the plan
// touches.
leaf_note :: proc "contextless" (number: u64) {
	key := number / format.COUNTS_OF_A_PAGE + 1
	if plan.leaves_touched >= len(plan_fixed.leaf_places) {
		plan.leaves_touched += 1
		return
	}
	mask := u64(LEAF_SLOTS - 1)
	at := (key * 0x9E37_79B9_7F4A_7C15 >> 20) & mask
	for plan_fixed.leaf_slots[at] != 0 {
		if plan_fixed.leaf_slots[at] == key {
			return
		}
		at = (at + 1) & mask
	}
	plan_fixed.leaf_slots[at] = key
	plan_fixed.leaf_places[plan.leaves_touched] = u32(at)
	plan.leaves_touched += 1
}

// The places of the table of the blocks outside the stores: a power of 2,
// twice the pages of the count tree that a commit takes and releases, and
// the two pages of the store table.
OUTSIDE_SLOTS :: 8192
#assert(OUTSIDE_SLOTS / 2 >= 2 * storage_mount.COUNT_STAGING_PAGES + 2)

// outside_find gives the place of a block in the table of the blocks
// outside the stores.
outside_find :: proc "contextless" (number: u64) -> (place: int, found: bool) {
	if len(plan.outside_blocks) == 0 {
		return -1, false
	}
	mask := u64(len(plan.outside_blocks) - 1)
	at := (number * 0x9E37_79B9_7F4A_7C15 >> 20) & mask
	for _ in 0 ..< len(plan.outside_blocks) {
		if plan.outside_blocks[at] == number {
			return int(at), true
		}
		if plan.outside_blocks[at] == 0 {
			return int(at), false
		}
		at = (at + 1) & mask
	}
	return -1, false
}

// plan_tables_fixed clears the places of the counts that the plan used, and
// gives the plan its fixed tables again: the memory of a pending pool can
// end after it.
plan_tables_fixed :: proc "contextless" () {
	for place in plan.delta_places[:plan.delta_count] {
		plan.delta_blocks[place] = 0
		plan.delta_values[place] = 0
	}
	plan.delta_count = 0
	plan.write_count = 0
	plan.taken_count = 0
	for place in plan.outside_places[:plan.owner_count] {
		plan.outside_blocks[place] = 0
	}
	plan.owner_count = 0
	for place in plan_fixed.leaf_places[:min(plan.leaves_touched, len(plan_fixed.leaf_places))] {
		plan_fixed.leaf_slots[place] = 0
	}
	plan.leaves_touched = 0
	plan.release_count = 0
	plan.outside_blocks = plan_fixed.outside_blocks[:]
	plan.outside_owners = plan_fixed.outside_owners[:]
	plan.outside_places = plan_fixed.outside_places[:]
	opened.count_staging = plan_fixed.count_staging
	opened.count_staged_slots = plan_fixed.count_staged_slots
	plan.writes = plan_fixed.writes[:]
	plan.taken = plan_fixed.taken[:]
	plan.delta_blocks = plan_fixed.delta_blocks[:]
	plan.delta_values = plan_fixed.delta_values[:]
	plan.delta_places = plan_fixed.delta_places[:]
	if plan_fixed.slot_pages[0] == nil {
		for &page, index in plan_fixed.slot_pages {
			page = &plan_fixed.slot_memory[index]
		}
	}
	plan.slot_pages = plan_fixed.slot_pages[:]
}

// Plan_Room is the room of the tables of a commit.
Plan_Room :: struct {
	writes:      int, // Blocks that the commit writes or takes.
	delta:       int, // Places of the table of the counts: a power of 2, twice the blocks whose names change.
	slot_pages:  int, // Pages of slots of the work on the object.
	count_pages: int, // Pages of the count tree that the commit writes.
	outside:     int, // Places of the table of the blocks outside the stores: a power of 2.
}

// plan_room_of_changes gives the room of a commit of `changes` changed
// blocks of data on an object of at most `blocks` blocks: the fixed room
// of a commit, and the blocks, nodes and releases of those changes.
plan_room_of_changes :: proc "contextless" (changes: u64, blocks: u64) -> Plan_Room {
	slots := block_tree.slots_needed(changes, blocks)
	// Each changed block and node is written once, and the block or the
	// node that it replaces loses one name.
	written := changes + slots
	entries := u64(DELTA_CAPACITY / 2) + 2 * written
	delta := u64(DELTA_CAPACITY)
	for delta < 2 * entries {
		delta *= 2
	}
	// The new blocks of a commit are near each other (the search of a free
	// block goes on from the last one), so a leaf holds many of them; a
	// commit whose blocks spread past this room is refused, and its caller
	// commits in parts.
	count_pages := storage_mount.COUNT_STAGING_PAGES + 4 * (written / format.COUNTS_OF_A_PAGE + format.COUNT_LEVEL_LIMIT)
	outside := u64(OUTSIDE_SLOTS)
	for outside < 4 * count_pages + 8 {
		outside *= 2
	}
	return {writes = WRITE_CAPACITY + int(written + count_pages), delta = int(delta), slot_pages = int(block_tree.slot_pages_needed(changes, blocks)), count_pages = int(count_pages), outside = int(outside)}
}

// plan_room_fits says if the fixed tables hold a room.
plan_room_fits :: proc "contextless" (room: Plan_Room) -> bool {
	return room.writes <= WRITE_CAPACITY && room.delta <= DELTA_CAPACITY && room.slot_pages <= COMMIT_SLOT_PAGES && room.count_pages <= storage_mount.COUNT_STAGING_PAGES && room.outside <= OUTSIDE_SLOTS
}

// plan_tables_bind gives the plan larger tables, right after its reset:
// the memory of the caller, zero where the counts are.
plan_tables_bind :: proc "contextless" (writes: []Write, taken: []u64, delta_blocks: []u64, delta_values: []i32, delta_places: []u32, slot_pages: []^block_tree.Slot_Page, count_staging: []block_counts.Frame, count_staged_slots: []i32, outside_blocks: []u64, outside_owners: []u16, outside_places: []u32) {
	plan.writes = writes
	plan.taken = taken
	plan.delta_blocks = delta_blocks
	plan.delta_values = delta_values
	plan.delta_places = delta_places
	plan.slot_pages = slot_pages
	opened.count_staging = count_staging
	opened.count_staged_slots = count_staged_slots
	plan.outside_blocks = outside_blocks
	plan.outside_owners = outside_owners
	plan.outside_places = outside_places
}

plan_crypto_end :: proc "contextless" () {
	if plan.crypto_active {
		store_crypto_leave(&plan.prev_crypto)
		plan.crypto_active = false
	}
	intrinsics.mem_zero_volatile(&plan.store_keys, size_of(plan.store_keys))
	plan.encrypted = false
	plan.owner_slot = 0
}

plan_reset :: proc "contextless" (store_index: int) {
	plan_crypto_end()
	plan_tables_fixed()
	block_counts.counts_failure_clear(&opened.counts)
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
	plan.dead_blocks = 0
	plan.tree_damaged = false
	plan.leaf_count = 0
	plan.versions_change = 0
	plan.thinned = 0
	plan.reclaiming = false
	plan.cell_freed = false
	plan.store_index = store_index
	later_count = 0
	plan.next = root
	plan.store_block = store_index >= 0 ? storage_mount.store_block_of(store_blocks[store_index]) : {}
	// Always switch away from any outer crypto scope before inspecting the
	// target store, so a failure never leaks outer keys and plan_drop restores
	// the outer scope cleanly.
	plan.prev_crypto = store_crypto_enter_keys(store_index, 0, nil)
	plan.crypto_active = true
	// The head keeps no owner fields: the commit of a store of a principal
	// keeps those of its verified store block and activates its Store_Keys.
	if store_index >= 0 && store_index < store_numbers() && owned_cell(store_index) {
		keys, keys_read := owned_store_keys_get(store_index)
		defer intrinsics.mem_zero_volatile(&keys, size_of(keys))
		switch keys_read {
		case .Good:
			owner, fields_read := owned_fields_read(store_index)
			switch fields_read {
			case .Good:
				format.store_owner_set(&plan.store_block, owner)
				plan.encrypted = true
				plan.owner_slot = u64(owned_checked[store_index] - 1)
				plan.store_keys = keys
				store_crypto_set_active(store_index, owned_checked[store_index], &plan.store_keys)
			case .Device:
				plan.device = true
			case .Wrong:
				plan.tree_damaged = true
			}
		case .Device:
			plan.device = true
		case .Wrong:
			plan.tree_damaged = true
		}
	}
	plan.page_written = {}
	if store_index >= 0 {
		page, _ := format.store_place(store_index)
		plan.page_index = page
		plan.page = page < int(root.store_page_count) ? opened.store_pages[page] : Store_Table_Page{magic = format.STORE_TABLE_MAGIC}
	}
	plan.entry_count = 0
	plan_trees_reset()
}

// plan_reset_reclaim prepares a clear keyless plan for marking or reclaiming
// an orphaned store cell without loading principal encryption keys.
plan_reset_reclaim :: proc "contextless" (store_index: int, sb: Store_Block) {
	plan_crypto_end()
	plan_tables_fixed()
	block_counts.counts_failure_clear(&opened.counts)
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
	plan.dead_blocks = 0
	plan.tree_damaged = false
	plan.leaf_count = 0
	plan.versions_change = 0
	plan.thinned = 0
	plan.reclaiming = true
	plan.cell_freed = false
	plan.store_index = store_index
	later_count = 0
	plan.next = root
	plan.store_block = sb
	plan.prev_crypto = store_crypto_enter_keys(store_index, 0, nil)
	plan.crypto_active = true
	plan.page_written = {}
	page, _ := format.store_place(store_index)
	plan.page_index = page
	plan.page = page < int(root.store_page_count) ? opened.store_pages[page] : Store_Table_Page{magic = format.STORE_TABLE_MAGIC}
	plan.entry_count = 0
	plan_trees_reset()
}

// plan_drop frees the blocks that the plan allocated and erases plan keys.
plan_drop :: proc "contextless" () {
	for number in plan.taken[:plan.taken_count] {
		mark(number, false)
	}
	plan.taken_count = 0
	block_counts.commit_drop(&opened.count_commit)
	plan_crypto_end()
}

delta_place :: proc "contextless" (number: u64) -> (place: u32, found: bool) {
	mask := u64(len(plan.delta_blocks) - 1)
	// The bits under the top 20 of the product: a table of a large commit
	// has up to 2^30 places, and each of them is a start.
	at := (number * 0x9E3779B97F4A7C15 >> 20) & mask
	for _ in 0 ..< len(plan.delta_blocks) {
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
	return i64(storage_mount.block_count(&opened, number)) + delta_of(number)
}

// delta_add changes the reference count of a block in the plan, and the
// count of the distinct blocks of the store.
// delta_add_outside changes the count of a block that no store counts (a
// page of the store table, a page of the count tree): the blocks used by
// the store do not change, and the block takes the owner given when its
// count is not 0 after the commit.
delta_add_outside :: proc "contextless" (number: u64, change: i64, owner: u16) {
	used_before := plan.used_change
	delta_add(number, change)
	plan.used_change = used_before
	// A block is taken or released outside the stores at most once in a
	// commit: a page that the commit replaces keeps its name until the
	// root, so no new page takes its block.
	place, found := outside_find(number)
	if !found {
		if place < 0 || plan.owner_count >= len(plan.outside_places) {
			capacity_reached(len(plan.outside_places))
			return
		}
		plan.outside_blocks[place] = number
		plan.outside_places[plan.owner_count] = u32(place)
		plan.owner_count += 1
	}
	plan.outside_owners[place] = change > 0 ? owner : 0
}

// outside_block says if the plan counts a block outside the stores: the
// erase of versions writes no zeros over it, as it holds counts and names,
// no byte of an object.
outside_block :: proc "contextless" (number: u64) -> bool {
	_, found := outside_find(number)
	return found
}

// owner_after gives the owner of a block that the plan counts, after the
// commit: the owner that delta_add_outside gave it, or the store of the
// plan.
owner_after :: proc "contextless" (number: u64) -> u16 {
	if place, found := outside_find(number); found {
		return plan.outside_owners[place]
	}
	return u16(plan.store_index + 1)
}

delta_add :: proc "contextless" (number: u64, change: i64) {
	if number < 2 || number >= opened.capacity {
		return
	}
	place, found := delta_place(number)
	if !found {
		if plan.delta_count >= len(plan.delta_blocks) / 2 || plan.delta_blocks[place] != 0 {
			capacity_reached(len(plan.delta_blocks) / 2)
			return
		}
		plan.delta_blocks[place] = number
		plan.delta_places[plan.delta_count] = place
		plan.delta_count += 1
		leaf_note(number)
	}
	before := i64(storage_mount.block_count(&opened, number)) + i64(plan.delta_values[place])
	plan.delta_values[place] += i32(change)
	after := before + change
	plan.used_change += i64(after > 0) - i64(before > 0)
	// A count below 0: the engine releases a name that it never counted.
	// The commit is refused, and the store stops taking changes: its counts
	// are not trusted.
	// A count that could not be read gives 0: its commit is refused for the
	// read, and the store stays trusted.
	if after < 0 && opened.counts.failure == .Good {
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
	if plan.taken_count >= len(plan.taken) {
		capacity_reached(len(plan.taken))
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
	if plan.write_count >= len(plan.writes) {
		capacity_reached(len(plan.writes))
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

plan_write_tree_node :: proc "contextless" (bytes: ^Block) -> Pointer {
	if !plan.encrypted {
		return plan_write(bytes)
	}
	if plan.write_count >= len(plan.writes) {
		capacity_reached(len(plan.writes))
		return {}
	}
	number := plan_allocate()
	if number == 0 {
		return {}
	}
	check, ok := store_encryption.tree_node_seal(&plan.store_keys, number, bytes)
	if !ok {
		plan.tree_damaged = true
		return {}
	}
	plan.writes[plan.write_count] = {number = number, bytes = bytes}
	plan.write_count += 1
	return {block = number, check = check}
}

plan_write_object_node :: proc "contextless" (bytes: ^Block) -> Pointer {
	if !plan.encrypted {
		return plan_write(bytes)
	}
	if plan.write_count >= len(plan.writes) {
		capacity_reached(len(plan.writes))
		return {}
	}
	number := plan_allocate()
	if number == 0 {
		return {}
	}
	check, ok := store_encryption.object_node_seal(&plan.store_keys, number, (^Object_Node)(bytes))
	if !ok {
		plan.tree_damaged = true
		return {}
	}
	plan.writes[plan.write_count] = {number = number, bytes = bytes}
	plan.write_count += 1
	return {block = number, check = check}
}

plan_write_data_block :: proc "contextless" (bytes: ^Block, data_check: u64) -> Pointer {
	if !plan.encrypted {
		return plan_write_checked(bytes, data_check, true)
	}
	if plan.write_count >= len(plan.writes) {
		capacity_reached(len(plan.writes))
		return {}
	}
	number := plan_allocate()
	if number == 0 {
		return {}
	}
	// Encrypt into a volatile-zeroed scratch block to compute cipher_check
	// without mutating Pending_Block.bytes or whole_blocks in place.
	scratch: Block = bytes^
	cipher_check := store_encryption.data_block_encrypt(&plan.store_keys, number, data_check, &scratch)
	intrinsics.mem_zero_volatile(&scratch, size_of(scratch))
	plan.writes[plan.write_count] = {number = number, bytes = bytes, encrypted_data = true, data_check = data_check}
	plan.write_count += 1
	return {block = number, check = cipher_check}
}

plan_write_version_leaf :: proc "contextless" (leaf: ^Version_Leaf) -> Pointer {
	if !plan.encrypted {
		return plan_write((^Block)(leaf))
	}
	if plan.write_count >= len(plan.writes) {
		capacity_reached(len(plan.writes))
		return {}
	}
	number := plan_allocate()
	if number == 0 {
		return {}
	}
	check, ok := store_encryption.version_leaf_seal(&plan.store_keys, number, leaf)
	if !ok {
		plan.tree_damaged = true
		return {}
	}
	plan.writes[plan.write_count] = {number = number, bytes = (^Block)(leaf)}
	plan.write_count += 1
	return {block = number, check = check}
}

plan_write_version_index :: proc "contextless" (bytes: ^Block) -> Pointer {
	if !plan.encrypted {
		return plan_write(bytes)
	}
	if plan.write_count >= len(plan.writes) {
		capacity_reached(len(plan.writes))
		return {}
	}
	number := plan_allocate()
	if number == 0 {
		return {}
	}
	check, ok := store_encryption.version_index_seal(&plan.store_keys, number, (^Version_Index)(bytes))
	if !ok {
		plan.tree_damaged = true
		return {}
	}
	plan.writes[plan.write_count] = {number = number, bytes = bytes}
	plan.write_count += 1
	return {block = number, check = check}
}

plan_write_release_list :: proc "contextless" (list: ^format.Release_List) -> Pointer {
	if !plan.encrypted {
		return plan_write((^Block)(list))
	}
	if plan.write_count >= len(plan.writes) {
		capacity_reached(len(plan.writes))
		return {}
	}
	number := plan_allocate()
	if number == 0 {
		return {}
	}
	check, ok := store_encryption.release_list_seal(&plan.store_keys, number, list)
	if !ok {
		plan.tree_damaged = true
		return {}
	}
	plan.writes[plan.write_count] = {number = number, bytes = (^Block)(list)}
	plan.write_count += 1
	return {block = number, check = check}
}

plan_write_store_block :: proc "contextless" (bytes: ^Block) -> Pointer {
	if !plan.encrypted {
		return plan_write(bytes)
	}
	if plan.write_count >= len(plan.writes) {
		capacity_reached(len(plan.writes))
		return {}
	}
	number := plan_allocate()
	if number == 0 {
		return {}
	}
	sb := (^Store_Block)(bytes)
	sb.store_generation = root.generation + 1
	plan.store_block.store_generation = sb.store_generation
	check, ok := store_encryption.store_block_seal(&plan.store_keys, number, sb)
	if !ok {
		plan.tree_damaged = true
		return {}
	}
	plan.writes[plan.write_count] = {number = number, bytes = bytes}
	plan.write_count += 1
	return {block = number, check = check}
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
	// The last name of a large state: its blocks could pass the room of the
	// counts of this commit, so the removal queue takes the name and frees
	// the blocks in steps. A shared root only loses one name.
	// Its blocks can be in as many leaves of the count tree as blocks: the
	// leaves of the commit, its changes so far at most, and those, pass half
	// of its staging, or its blocks pass the room of the counts.
	if count_after(root.block) == 1 && !state_damaged(root) {
		// The names that the release changes, counted with no change: a
		// version that shares most of its nodes with the state that stays
		// changes a few names, whatever its size.
		room := len(plan.delta_blocks) / 2 - plan.delta_count - RELEASE_ROOM_RESERVE
		leaf_room := len(opened.count_staging) / 2 - plan.leaves_touched
		limit := max(min(room, leaf_room), 0)
		_, within := storage_release.release_names(&releaser, root, size, limit)
		if releaser.device {
			releaser.device = false
			plan.device = true
			return
		}
		if !within {
			release_queue(root, size)
			return
		}
	}
	child_release({block = root.block, check = root.check}, format.object_levels(size))
}

// The places of the counts that a commit keeps for its other changes when
// it releases states: the nodes of its trees, its versions and its writes.
RELEASE_ROOM_RESERVE :: 16384

// release_queue puts a state that lost its last name in the removal queue
// of the store of the plan: the entry of the queue holds that name until
// the last step.
release_queue :: proc "contextless" (root: Pointer, size: u64) {
	if plan.release_count >= RELEASE_STATES_MOST {
		capacity_reached(RELEASE_STATES_MOST)
		return
	}
	list := &plan_fixed.release_lists[plan.release_count / format.RELEASES_OF_A_LIST]
	place := plan.release_count % format.RELEASES_OF_A_LIST
	if place == 0 {
		list^ = {magic = format.RELEASE_LIST_MAGIC}
	}
	list.states[place] = {root = root, size = size}
	list.count = u32(place + 1)
	plan.release_count += 1
}

// release_lists_write writes the lists of the states that the commit gives
// to the removal queue, the last first, so that each one names the next by
// its check, and puts one entry of the queue that names the first.
release_lists_write :: proc "contextless" () {
	if plan.release_count == 0 {
		return
	}
	lists := (plan.release_count + format.RELEASES_OF_A_LIST - 1) / format.RELEASES_OF_A_LIST
	plan.release_count = 0
	next: Pointer
	for index := lists - 1; index >= 0; index -= 1 {
		list := &plan_fixed.release_lists[index]
		list.next = next
		next = plan_write_release_list(list)
		if next.block == 0 {
			return // plan_write gave the cause.
		}
	}
	number := plan.store_block.next_removal + 1
	plan.store_block.next_removal = number
	key := format.removal_name(number)
	queued := Entry{kind = u64(format.Entry_Kind.Release), pointer = next}
	tree.put(&plan.trees[1].work, key[:], entry_bytes(&queued), false)
	plan.trees[1].changed = true
	plan.store_block.removing += 1
}

// release_step frees the next parts of the states of a release list of the
// removal queue (storage_release.step_state), several states in one step,
// up to its bound of names, and of leaves of the count tree, a quarter of
// the staging of the commit, the rest for the other pages of the commit.
// It leaves in the list the states that are not free, each with its cursor,
// and gives true when the list is empty: the entry of the queue then names
// the next list, or the queue drops it.
release_step :: proc "contextless" (list: ^format.Release_List) -> bool {
	storage_release.step_begin(&releaser, len(opened.count_staging) / 4)
	// The states in their order: each free one leaves the list, and the
	// step goes on with the next while its bounds hold.
	freed := 0
	for freed < int(list.count) {
		state := &list.states[freed]
		if !storage_release.step_state(&releaser, state.root, state.size, &state.cursor) {
			break
		}
		freed += 1
	}
	plan.release_damaged += releaser.damaged
	plan.dead_blocks += releaser.damaged_blocks
	releaser.damaged = 0
	releaser.damaged_blocks = 0
	if releaser.device {
		plan.device = true
		return false
	}
	left := int(list.count) - freed
	copy(list.states[:left], list.states[freed:list.count])
	for &state in list.states[left:list.count] {
		state = {}
	}
	list.count = u32(left)
	return left == 0
}

// The names of the plan, for the steps of a release.
releaser := storage_release.Releaser {
	count_after = proc "contextless" (_: ^storage_release.Releaser, number: u64) -> i64 {
		return count_after(number)
	},
	drop = proc "contextless" (_: ^storage_release.Releaser, number: u64) {
		delta_add(number, -1)
	},
	drop_whole = proc "contextless" (releaser: ^storage_release.Releaser, child: Object_Child, level: int) {
		child_release(child, level)
		releaser.device ||= plan.device
	},
	read_node = release_node_read,
}

// release_node_read reads a node of a release with the checks of
// child_release: a block that the service knows wrong, a wrong check, a
// node of another kind or level are Wrong, and the service keeps them.
release_node_read :: proc "contextless" (_: ^storage_release.Releaser, child: Object_Child, level: int, into: ^Object_Node) -> storage_release.Read {
	if storage_mount.wrong_block(&opened, child.block) || storage_mount.damaged_under(&opened, child.block) {
		return .Wrong
	}
	switch read_object_node({block = child.block, check = child.check}, into) {
	case .Device:
		return .Device
	case .Wrong:
		storage_mount.wrong_block_set(&opened, child.block)
		return .Wrong
	case .Good:
	}
	if into.header.magic != format.OBJECT_NODE_MAGIC || int(into.header.level) != level {
		storage_mount.wrong_block_set(&opened, child.block)
		return .Wrong
	}
	return .Good
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
	switch read_object_node({block = child.block, check = child.check}, node) {
	case .Device:
		plan.device = true
	case .Wrong:
		storage_mount.wrong_block_set(&opened, child.block)
		plan.release_damaged += 1
		plan.dead_blocks += max(child.blocks, 1) - 1
	case .Good:
		if node.header.magic != format.OBJECT_NODE_MAGIC || int(node.header.level) != level {
			storage_mount.wrong_block_set(&opened, child.block)
			plan.release_damaged += 1
			plan.dead_blocks += max(child.blocks, 1) - 1
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
	return plan_write_object_node(bytes)
}

counter_write_data :: proc "contextless" (_: ^block_tree.Counter, bytes: ^block_tree.Block, check: u64) -> Pointer {
	return plan_write_data_block(bytes, check)
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
		switch read_version_index(work.original, &work.index) {
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
		switch read_version_leaf(work.original, &work.leaf) {
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

// The retention rule in force: the plan values of the owner `storage`, read
// at the start of this service (storage_retention.rule_of).
retention_rule: storage_retention.Rule = storage_retention.DEFAULT_RULE

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
	if storage_retention.keeps(times[:count], rule_now, keep[:count], retention_rule) == 0 {
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
	return i64(plan_cell().used) + change
}

// plan_cell gives the cell of the store of the plan, in the page that the
// commit writes.
plan_cell :: proc "contextless" () -> ^Store_Entry {
	_, cell := format.store_place(plan.store_index)
	return &plan.page.cells[cell]
}

// plan_page_write writes the page of the store table of the plan to a free
// block, after the last change of its cell. The page is named by the root
// only, not by the store: its block and the block of the page before change
// the counts outside the count of the store (delta_add_outside), with the
// owner of the store table. false: no free block, or no room for one more
// write.
plan_page_write :: proc "contextless" () -> bool {
	if plan.write_count >= len(plan.writes) || plan.taken_count >= len(plan.taken) {
		capacity_reached(len(plan.writes))
		return false
	}
	number := allocate()
	if number == 0 {
		plan.full = true
		return false
	}
	plan.taken[plan.taken_count] = number
	plan.taken_count += 1
	delta_add_outside(number, 1, storage_mount.STORE_TABLE_OWNER)
	if before := root.store_pages[plan.page_index].block; before != 0 && int(plan.page_index) < int(root.store_page_count) {
		delta_add_outside(before, -1, 0)
	}
	bytes := (^Block)(&plan.page)
	plan.writes[plan.write_count] = {number = number, bytes = bytes}
	plan.write_count += 1
	plan.page_written = {block = number, check = check_of(bytes[:])}
	plan.next.store_pages[plan.page_index] = plan.page_written
	plan.next.store_page_count = max(plan.next.store_page_count, u64(plan.page_index + 1))
	return true
}

// count_pages_make makes the pages of the count tree of the plan: each leaf
// whose counts the plan changes, the leaves that the tree does not hold yet
// (the form Tables, while half of the staging is free), their directories,
// and the leaves of their own blocks. Their writes join the writes of the
// plan, and the new root names the new tree. It gives the refusal of a
// commit that cannot make them.
count_pages_make :: proc "contextless" (error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, refused: bool) {
	switch opened.counts.failure {
	case .Good:
	case .Device:
		return refuse(error, .Callee_Unavailable, .Device), true
	case .Wrong:
		return refuse(error, .Data_Damaged, .Damaged, .Counts), true
	}
	commit := &opened.count_commit
	if !block_counts.commit_begin(commit, &opened.counts, opened.count_staging, opened.count_staged_slots) {
		return refuse(error, .Budget_Or_Capacity_Exhausted, .Full, .Commit_Blocks), true
	}
	commit.after = count_after_commit
	commit.take = count_page_take
	commit.release = count_page_release
	for place in plan.delta_places[:plan.delta_count] {
		block_counts.commit_leaf_add(commit, plan.delta_blocks[place])
	}
	// The leaves that a repair counted again: this commit writes them.
	for &leaf in opened.counts.repaired {
		block_counts.commit_leaf_add(commit, leaf.first)
	}
	recount_record(commit)
	if opened.form == .Tables && opened.leaves_to_write_count > 0 {
		leaves: for word, index in opened.leaves_to_write {
			for bit in u64(0) ..< 64 {
				if word >> bit & 1 == 0 {
					continue
				}
				if commit.staged >= len(commit.staging) / 2 {
					break leaves
				}
				block_counts.commit_leaf_add(commit, (u64(index) * 64 + bit) * format.COUNTS_OF_A_PAGE)
			}
		}
	}
	counts_root, made := block_counts.commit_finish(commit)
	if !made {
		switch commit.failure {
		case .None, .Full:
			return refuse(error, .Budget_Or_Capacity_Exhausted, .Full, .Commit_Blocks, 0, 0, storage_mount.COUNT_STAGING_PAGES), true
		case .No_Block:
			// A search of a free block that could not read a leaf finds none:
			// the read is the cause, not a full disk.
			switch opened.counts.failure {
			case .Good:
				return refuse(error, .Budget_Or_Capacity_Exhausted, .Full), true
			case .Device:
				return refuse(error, .Callee_Unavailable, .Device), true
			case .Wrong:
				return refuse(error, .Data_Damaged, .Damaged, .Counts), true
			}
		case .Wrong:
			return refuse(error, .Data_Damaged, .Damaged, .Counts), true
		case .Device:
			return refuse(error, .Callee_Unavailable, .Device), true
		}
	}
	// The counts of the pages themselves passed through delta_add: a count
	// out of its range, or a table of the plan that is full, refuses here.
	if plan.capacity_reached {
		return refuse(error, .Budget_Or_Capacity_Exhausted, .Full, .Commit_Blocks, 0, 0, i64(plan.capacity_limit)), true
	}
	if plan.count_fault || plan.count_overflow {
		return refuse(error, .Data_Damaged, .Damaged, .Counts), true
	}
	if plan.full {
		return refuse(error, .Budget_Or_Capacity_Exhausted, .Full), true
	}
	if plan.device {
		return refuse(error, .Callee_Unavailable, .Device), true
	}
	if plan.write_count + commit.staged > len(plan.writes) {
		return refuse(error, .Budget_Or_Capacity_Exhausted, .Full, .Commit_Blocks, 0, 0, i64(len(plan.writes))), true
	}
	remaining := opened.leaves_to_write_count
	for &page in commit.staging[:commit.staged] {
		plan.writes[plan.write_count] = {number = page.block, bytes = &page.bytes}
		plan.write_count += 1
		if page.level == 0 && leaf_is_to_write(page.first / format.COUNTS_OF_A_PAGE) {
			remaining -= 1
		}
	}
	plan.next.counts = counts_root
	plan.next.counts_complete = remaining == 0 ? 1 : 0
	return .Succeeded, false
}

// The record of the leaves to recount that the commit in progress writes,
// for count_pages_install.
plan_recount: struct {
	dead:   bool,
	leaves: u64,
	set:    bool,
}

// plan_dead_names says if the plan leaves names that no state holds: a
// release that met a wrong block, or a version index or leaf dropped with
// the states under it.
plan_dead_names :: proc "contextless" () -> bool {
	return plan.release_damaged > 0 || plan.dropped_versions > 0
}

// recount_record gives the new top directory of the commit its leaves to
// recount (src/md/data/storage_capacity.md, "A recount frees the blocks
// that a release could not read"), as storage_mount.recount_record_decide
// gives them.
recount_record :: proc "contextless" (commit: ^block_counts.Commit) {
	dead := plan_dead_names()
	leaves, set := storage_mount.recount_record_decide(&opened, dead)
	plan_recount = {dead = dead, leaves = leaves, set = set}
	if set {
		block_counts.commit_recount_set(commit, leaves)
	}
}

// recount_ask asks for a recount, and gives the leaves that wait for it.
recount_ask :: proc "contextless" () -> u64 {
	if broken {
		return 0
	}
	return storage_mount.recount_request(&opened)
}

// recount_waits_say writes the leaves that wait for a recount at the open,
// with the free blocks and the bound under which the recount starts.
recount_waits_say :: proc "contextless" () {
	if opened.form != .Count_Tree || opened.counts.leaves_to_recount == 0 {
		return
	}
	free, _ := block_counts.free_blocks(&opened.counts)
	system.log_fact(.Info, Count_Recount_Waits{leaves = opened.counts.leaves_to_recount, free = blocks_field(free), start_below = blocks_field(storage_mount.recount_free_bound(&opened))})
}

// leaf_is_to_write says if the tree does not hold a leaf yet (the form
// Tables).
leaf_is_to_write :: proc "contextless" (leaf: u64) -> bool {
	word := leaf / 64
	return word < u64(len(opened.leaves_to_write)) && opened.leaves_to_write[word] >> (leaf % 64) & 1 != 0
}

// count_pages_install makes the pages of the commit the count tree of the
// root, after the root is on the disk.
count_pages_install :: proc "contextless" () {
	commit := &opened.count_commit
	for &page in commit.staging[:commit.staged] {
		if page.level == 0 {
			storage_mount.leaf_written(&opened, page.first / format.COUNTS_OF_A_PAGE)
		}
	}
	repaired := storage_mount.repair_commit_waits(&opened)
	wrong_before := opened.counts.wrong_leaf_count
	block_counts.commit_install(commit, root.counts)
	storage_mount.recount_record_written(&opened, plan_recount.dead, plan_recount.leaves, plan_recount.set)
	if plan_recount.dead {
		free, _ := block_counts.free_blocks(&opened.counts)
		system.log_fact(.Warning, Dead_Names_Kept{blocks = blocks_field(plan.dead_blocks), free = blocks_field(free), start_below = blocks_field(storage_mount.recount_free_bound(&opened))})
	}
	plan_recount = {}
	if repaired {
		storage_mount.repair_written(&opened)
		if opened.counts.wrong_leaf_count < wrong_before {
			system.log_fact(.Info, Count_Leaves_Repaired{})
		}
	}
	// The pages that a commit of the write of a recount takes and frees
	// change the tally of the leaves after its directory. After the install
	// and the end of the repaired leaves: a new page of the tally takes a
	// block that the tree gives free, never a block of this commit.
	for at in plan.delta_places[:plan.delta_count] {
		number := plan.delta_blocks[at]
		change := i64(plan.delta_values[at])
		storage_mount.recount_delta(&opened, &mount_reader, &repair_disk, number, change, change > 0 ? owner_after(number) : 0)
	}
	recount_ended_say()
}

// recount_ended_say writes the end of a recount once, with the blocks that
// it freed.
recount_ended_say :: proc "contextless" () {
	if ended, freed := storage_mount.recount_ended_take(&opened); ended {
		recount_start_said = false
		system.log_fact(.Info, Count_Recount_Ended{freed = blocks_field(freed)})
		// The slower tier of the sort of the names: visible when it ran.
		if sorts := opened.repair.recount_sorts_full; sorts != 0 {
			system.log_fact(.Info, Count_Recount_Sorts_Full{sorts = sorts, names = opened.repair.recount_names})
		}
	}
}

// The service in the repair state (src/md/data/storage_capacity.md, "The
// repair state"): the walk gives the roots of the last commit, and the
// writes of its scratch go through the block service.
repair_disk := storage_mount.Repair_Disk {
	write = proc "contextless" (_: ^storage_mount.Repair_Disk, number: u64, bytes: ^[BLOCK_SIZE]u8) -> bool {
		intrinsics.mem_copy_non_overlapping(raw_data(slot(0)), bytes, BLOCK_SIZE)
		if !transfer(.Write, {{number = number, slot = 0}}) {
			return false
		}
		blocks_written += 1
		return true
	},
	store_damaged = proc "contextless" (_: ^storage_mount.Repair_Disk, store_index: int) {
		// Its counts are not whole either: the blocks under the wrong node
		// have no name of it.
		store_damaged[store_index] = true
		store_faulty[store_index] = true
		system.log_fact(.Error, Count_Repair_Store_Damaged{store = store_field(store_name_of(store_index))})
	},
}

// The lines of the repair that the service writes once for each repair:
// a device that fails at each try writes one line, not one for each call.
repair_start_said: bool
repair_device_said: bool
repair_room_said: bool
repair_commit_said: bool
recount_start_said: bool
// The commit of the repaired leaves failed: it is made again after the
// next call.
repair_commit_waits_call: bool

// repair_waits says if a step of the repair of the count tree waits: a
// walk, or the commit of the leaves that it counted.
repair_waits :: proc "contextless" () -> bool {
	if broken {
		return false
	}
	if storage_mount.repair_commit_waits(&opened) {
		return !repair_commit_waits_call
	}
	return storage_mount.repair_waits(&opened)
}

// recount_waits says if a run of a recount of the count tree can start:
// the service starts it when no call waits and no removal waits.
recount_waits :: proc "contextless" () -> bool {
	return !broken && !opened.damage_set_full && storage_mount.recount_waits(&opened)
}

// repair_call_came says that a call came: a repair or its commit that
// failed on the device tries again.
repair_call_came :: proc "contextless" () {
	storage_mount.repair_call_came(&opened)
	repair_commit_waits_call = false
}

// repair_refusal refuses a change while the service repairs its count
// tree: Busy, with the stores that the walk ended and the stores in all.
// The caller can make the call again after the repair.
repair_refusal :: proc "contextless" (error: ^errors.Error_Record) -> (refused: bool, outcome: call_outcome.Call_Outcome) {
	if broken || !storage_mount.repair_active(&opened) {
		return false, .Succeeded
	}
	walked, total := storage_mount.repair_progress(&opened)
	// The repair or the recount ends by itself, with no act of the caller.
	unit := storage_mount.recount_running(&opened) ? errors.Unit.Count_Recount : errors.Unit.Count_Repair
	return true, refuse(error, .Callee_Busy, .Busy, unit, 0, i64(walked), i64(total))
}

// repair_step runs one step of the repair of the count tree, or the commit
// of the leaves that it counted.
repair_step :: proc "contextless" () {
	if !storage_mount.repair_commit_waits(&opened) {
		if opened.counts.wrong_leaf_count > 0 && !repair_start_said {
			repair_start_said = true
			system.log_fact(.Warning, Count_Repair_Started{leaves = u64(opened.counts.wrong_leaf_count)})
		}
		leaves := opened.counts.leaves_to_recount
		repair_disk.root = &root
		repair_disk.heads = store_blocks[:]
		outcome := storage_mount.repair_step(&opened, &mount_reader, &repair_disk)
		if storage_mount.recount_running(&opened) && !recount_start_said {
			recount_start_said = true
			free, _ := block_counts.free_blocks(&opened.counts)
			system.log_fact(.Info, Count_Recount_Started{leaves = leaves, free = blocks_field(free)})
		}
		recount_ended_say()
		recount_room_say()
		switch outcome {
		case .Running:
			return
		case .Done:
			// A run that ended with no leaf to write makes no commit.
			if !storage_mount.repair_commit_waits(&opened) {
				return
			}
		case .Device:
			if !repair_device_said {
				repair_device_said = true
				system.log_fact(.Warning, Count_Repair_Device{})
			}
			return
		case .No_Room:
			// A recount says its own line (recount_room_say).
			if !storage_mount.recount_running(&opened) && opened.repair.no_room && !repair_room_said {
				repair_room_said = true
				system.log_fact(.Warning, Count_Repair_No_Room{})
			}
			return
		case .Damage_Full:
			recount_start_said = false
			system.log_fact(.Warning, Count_Recount_Damage_Full{wrong_blocks = u64(len(opened.wrong_set) / 2)})
			return
		}
	}
	recounting := storage_mount.recount_running(&opened)
	committed, full := repair_commit()
	if committed {
		return
	}
	// A commit of the write of a recount that finds no block: the recount
	// stops, its record on the disk stays right, and the changes come back.
	if recounting && full {
		storage_mount.recount_stop_for_room(&opened)
		recount_start_said = false
		recount_room_say()
		return
	}
	repair_commit_waits_call = true
	if !repair_commit_said {
		repair_commit_said = true
		system.log_fact(.Warning, Count_Repair_Commit_Failed{})
	}
}

// recount_room_say writes once that a recount found no room for its tally
// or its commit no block, with the free blocks then.
recount_room_say :: proc "contextless" () {
	said, free, need := storage_mount.recount_blocked_take(&opened)
	if !said {
		return
	}
	recount_start_said = false
	if need == 0 {
		system.log_fact(.Warning, Count_Recount_Stopped_For_Room{free = blocks_field(free)})
	} else {
		system.log_fact(.Warning, Count_Recount_No_Room{free = blocks_field(free), need = blocks_field(need)})
	}
}

// repair_commit writes the leaves that the repair counted in one commit
// that changes no store; the service then leaves the repair state.
repair_commit :: proc "contextless" () -> (committed: bool, full: bool) {
	plan_reset(-1)
	error: errors.Error_Record
	if outcome, refused := count_pages_make(&error); refused {
		block_counts.commit_drop(&opened.count_commit)
		plan_drop()
		return false, outcome == .Budget_Or_Capacity_Exhausted
	}
	place, written := plan_write_with_root(&error)
	if written != .Succeeded {
		return false, written == .Budget_Or_Capacity_Exhausted
	}
	root = plan.next
	root_place = place
	commits += 1
	// The commit changes the counts of the pages of the count tree only;
	// the form Count_Tree has no table to change.
	for at in plan.delta_places[:plan.delta_count] {
		if opened.form != .Tables {
			break
		}
		number := plan.delta_blocks[at]
		after := i64(storage_mount.block_count(&opened, number)) + i64(plan.delta_values[at])
		storage_mount.block_set(&opened, number, u32(max(after, 0)), after <= 0 ? 0 : owner_after(number))
	}
	count_pages_install()
	plan.taken_count = 0
	plan_crypto_end()
	storage_mount.repair_commit_came(&opened)
	repair_start_said, repair_device_said, repair_room_said, repair_commit_said = false, false, false, false
	return true, false
}

// count_after_commit gives the count and the owner of a block after the
// commit, for a leaf of the commit.
count_after_commit :: proc "contextless" (commit: ^block_counts.Commit, number: u64) -> (count: u32, owner: u16) {
	after := count_after(number)
	if after <= 0 {
		return 0, 0
	}
	if _, counted := delta_place(number); counted {
		return u32(min(after, i64(REFERENCE_LIMIT))), owner_after(number)
	}
	return u32(min(after, i64(REFERENCE_LIMIT))), storage_mount.block_owner(&opened, number)
}

// count_page_take gives a free block to a new page of the count tree, and
// counts it with the owner of the tree.
count_page_take :: proc "contextless" (commit: ^block_counts.Commit) -> u64 {
	if plan.taken_count >= len(plan.taken) {
		capacity_reached(len(plan.taken))
		return 0
	}
	number := allocate()
	if number == 0 {
		plan.full = true
		return 0
	}
	plan.taken[plan.taken_count] = number
	plan.taken_count += 1
	delta_add_outside(number, 1, storage_mount.COUNT_TREE_OWNER)
	block_counts.commit_leaf_add(commit, number)
	return number
}

// count_page_release drops the name of a page of the count tree that a new
// page replaces.
count_page_release :: proc "contextless" (commit: ^block_counts.Commit, number: u64) {
	delta_add_outside(number, -1, 0)
	block_counts.commit_leaf_add(commit, number)
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
				pointer = plan_write_version_leaf(&leaf.leaf)
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
		item.entry.versions = plan_write_version_index(block_bytes)
		if item.entry.versions.block != 0 {
			cache_later(item.entry.versions, block_bytes)
		}
	}
	plan_entries_put()
	release_lists_write()
	plan_trees_finish()
	entry := plan_cell()
	if entry.store.block != 0 {
		delta_add(entry.store.block, -1)
	}
	intrinsics.mem_copy_non_overlapping(&plan.store_block_bytes, &plan.store_block, BLOCK_SIZE)
	entry.store = plan_write_store_block(&plan.store_block_bytes)
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

// plan_write_with_root writes the blocks of the plan, REGION_BLOCKS at a
// time, reads them back, then writes the root of the plan in the other
// place and reads it back. The outcome is Succeeded, or the call outcome of
// the refusal with its error record; the plan is then dropped.
plan_write_with_root :: proc "contextless" (error: ^errors.Error_Record) -> (place: u64, outcome: call_outcome.Call_Outcome) {
	// The blocks, REGION_BLOCKS at a time, then the root. Each one is on the
	// disk before the next step.
	for first := 0; first < plan.write_count; first += REGION_BLOCKS {
		part := plan.writes[first:min(first + REGION_BLOCKS, plan.write_count)]
		requests: [REGION_BLOCKS]Request
		for write, index in part {
			intrinsics.mem_copy_non_overlapping(raw_data(slot(u64(index))), write.bytes, BLOCK_SIZE)
			if write.encrypted_data {
				_ = store_encryption.data_block_encrypt(&plan.store_keys, write.number, write.data_check, (^Block)(raw_data(slot(u64(index)))))
			}
			requests[index] = {number = write.number, slot = u64(index)}
		}
		if !transfer(.Write, requests[:len(part)]) {
			plan_drop()
			return 0, refuse(error, .Callee_Unavailable, .Device)
		}
		blocks_written += u64(len(part))
	}
	if !flush() {
		plan_drop()
		return 0, refuse(error, .Callee_Unavailable, .Device)
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
		return 0, refuse(error, .Callee_Unavailable, .Device, .Dropped_Writes, 0, 0, 0, i64(differ))
	case .Device:
		// No root names the blocks: the disk holds the state before.
		plan_drop()
		commits_refused += 1
		system.log_fact(.Error, Commit_Read_Back_Failed{generation = plan.next.generation})
		return 0, refuse(error, .Callee_Unavailable, .Device)
	}
	plan.next.time = time_now()
	plan.next.date = date_now()
	plan.next.check = root_check(&plan.next)
	intrinsics.mem_copy_non_overlapping(raw_data(slot(0)), &plan.next, BLOCK_SIZE)
	place = 1 - root_place
	if !transfer(.Write, {{number = place, slot = 0}}) || !flush() {
		// The root on the disk is the old one, or the new one: the service
		// cannot know. It stops serving changes.
		plan_drop()
		root_undecided(plan.next.generation, .Write)
		return 0, refuse(error, .Callee_Unavailable, .Device)
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
		return 0, refuse(error, .Callee_Unavailable, .Device, .Dropped_Writes, 0, 0, 0, 1)
	case .Device:
		// The root can be on the disk: as for a failed write of a root.
		plan_drop()
		root_undecided(plan.next.generation, .Read_Back)
		return 0, refuse(error, .Callee_Unavailable, .Device)
	}
	roots_refused_in_a_row = 0
	return place, .Succeeded
}

// plan_commit writes the blocks of the plan, then the root, and gives the
// new state to the service. It gives the generation and Succeeded, or 0 and
// the call outcome with the error record.
plan_commit :: proc "contextless" (error: ^errors.Error_Record) -> (value: i64, outcome: call_outcome.Call_Outcome) {
	plan_trees_failure_take()
	if plan.tree_damaged {
		plan_drop()
		store_damaged[plan.store_index] = true
		system.log_fact(.Warning, Tree_Node_Damaged{store = store_field(system.name_of(plan_cell().name[:]))})
		return call_outcome.fail_with_value_first(error, .Data_Damaged, .Damaged, .Stores)
	}
	if plan.device {
		plan_drop()
		return call_outcome.fail_with_value_first(error, .Callee_Unavailable, .Device)
	}
	// No commit runs while the service repairs its count tree: its walk
	// counts the trees of the last commit.
	if refused, result := repair_refusal(error); refused {
		plan_drop()
		return 0, result
	}
	// A read of the count tree that failed comes first: the counts that it
	// gave are not the counts of the disk, so they are no fault of the
	// engine, and the store stays trusted.
	switch opened.counts.failure {
	case .Good:
	case .Device:
		plan_drop()
		return call_outcome.fail_with_value_first(error, .Callee_Unavailable, .Device)
	case .Wrong:
		plan_drop()
		return call_outcome.fail_with_value_first(error, .Data_Damaged, .Damaged, .Counts)
	}
	if plan.count_fault {
		plan_drop()
		store_faulty[plan.store_index] = true
		system.log_fact(.Error, Commit_Count_Below_Zero{store = store_field(system.name_of(plan_cell().name[:]))})
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
	entry := plan_cell()
	if plan.cell_freed {
		entry^ = {}
	} else {
		entry.used = u64(i64(entry.used) + plan.used_change)
	}
	// The page of the store table, with the count of its cell final.
	if !plan_page_write() {
		plan_drop()
		if plan.full {
			return call_outcome.fail_with_value_first(error, .Budget_Or_Capacity_Exhausted, .Full)
		}
		return call_outcome.fail_with_value_first(error, .Budget_Or_Capacity_Exhausted, .Full, .Commit_Blocks, 0, 0, i64(plan.capacity_limit))
	}
	// The pages of the count tree, after the last count of the plan: each
	// leaf whose counts change, its directories, and the leaves of their own
	// blocks (src/md/data/storage_capacity.md, "The counts of names live on
	// the disk").
	if refusal, refused := count_pages_make(error); refused {
		block_counts.commit_drop(&opened.count_commit)
		plan_drop()
		// A leaf that this commit found wrong starts the repair state: the
		// call can be made again after the repair, as each change after it.
		if busy, result := repair_refusal(error); busy {
			return 0, result
		}
		return 0, refusal
	}
	// The shared blocks of the store after the commit, from the counts
	// before it, read now: after the root, a read of a leaf that the commit
	// replaced would read the tree before, and a wrong page there would
	// start a repair of a leaf that the commit wrote.
	shared_change: i64
	for at in plan.delta_places[:plan.delta_count] {
		number := plan.delta_blocks[at]
		before := i64(storage_mount.block_count(&opened, number))
		after := before + i64(plan.delta_values[at])
		if owner_after(number) <= u16(format.STORE_CAPACITY) {
			if before < 2 && after >= 2 {
				shared_change += 1
			} else if before >= 2 && after < 2 {
				shared_change -= 1
			}
		}
	}
	switch opened.counts.failure {
	case .Good:
	case .Device:
		block_counts.commit_drop(&opened.count_commit)
		plan_drop()
		return call_outcome.fail_with_value_first(error, .Callee_Unavailable, .Device)
	case .Wrong:
		block_counts.commit_drop(&opened.count_commit)
		plan_drop()
		if busy, result := repair_refusal(error); busy {
			return 0, result
		}
		return call_outcome.fail_with_value_first(error, .Data_Damaged, .Damaged, .Counts)
	}
	place, written := plan_write_with_root(error)
	if written != .Succeeded {
		return 0, written
	}
	// The commit is on the disk: the service takes its state.
	page_before := root.store_pages[plan.page_index]
	root = plan.next
	root_place = place
	if plan.cell_freed {
		store_blocks[plan.store_index] = {}
	} else {
		store_blocks[plan.store_index] = storage_mount.store_head_of(&plan.store_block)
	}
	// The page of the store table: the root names the new block; the counts
	// of the new block and of the page before are in the plan.
	opened.store_pages[plan.page_index] = plan.page
	_ = page_before
	commits += 1
	if plan.cell_freed {
		opened.store_versions[plan.store_index] = 0
		opened.store_shared[plan.store_index] = 0
		opened.store_recount[plan.store_index] = 0
		opened.store_damaged_objects[plan.store_index] = 0
		store_damaged[plan.store_index] = false
		store_faulty[plan.store_index] = false
		removal_stalled[plan.store_index] = false
		reclaim_stalled[plan.store_index] = false
	} else {
		opened.store_versions[plan.store_index] = u64(max(i64(opened.store_versions[plan.store_index]) + plan.versions_change, 0))
		if plan.dropped_versions != 0 {
			system.log_fact(.Warning, Versions_Dropped_At_Commit{generation = root.generation, dropped = plan.dropped_versions, store = store_field(store_name_of(plan.store_index))})
		}
		opened.store_shared[plan.store_index] = u64(max(i64(opened.store_shared[plan.store_index]) + shared_change, 0))
	}
	// The tables of the form Tables; in the form Count_Tree the leaves of
	// the commit hold the counts, and no page is read here.
	if opened.form == .Tables {
		for at in plan.delta_places[:plan.delta_count] {
			number := plan.delta_blocks[at]
			after := i64(storage_mount.block_count(&opened, number)) + i64(plan.delta_values[at]) // From 0 to REFERENCE_LIMIT: delta_add refused the commit else.
			storage_mount.block_set(&opened, number, u32(after), after == 0 ? 0 : owner_after(number))
		}
	}
	// The leaves and the directories of the count tree: the new tree of the
	// root. In the form Count_Tree the counts come from them from now on.
	count_pages_install()
	// The hash index follows the entries that the commit changed, after the
	// owners: a root of the index is a block of its store. While the store
	// has a writable share of a tree open, a new root is hidden: never a
	// candidate, so the holder cannot plant bytes that a later write of the
	// maker would find (docs/STORAGE.md, "4.7 The same object one time").
	if !plan.reclaiming {
		hidden := writable_tree_share_open(plan_store_name())
		for &item in plan.entries[:plan.entry_count] {
			storage_mount.hash_index_entry_change(&opened, item.before, item.entry, item.gone, hidden)
		}
	}
	for item in later[:later_count] {
		cache_put(item.pointer, item.bytes)
	}
	later_count = 0
	plan.taken_count = 0
	if plan.encrypted {
		owned_checked[plan.store_index] = u8(plan.owner_slot + 1)
		if plan.store_block.store_generation > owned_min_generation[plan.store_index] {
			owned_min_generation[plan.store_index] = plan.store_block.store_generation
		}
		owned_store_keys_put(plan.store_index, plan.owner_slot, &plan.store_keys)
	}
	if !plan.reclaiming || plan.used_change < 0 {
		reclaim_stalled_clear(plan.reclaiming ? plan.store_index : -1)
	}
	plan_crypto_end()
	// A commit can free the blocks that a repair found no room for.
	storage_mount.repair_commit_came(&opened)
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
	return number >= 2 && number < disk_size && storage_mount.block_count(&opened, number) == 0 && !outside_block(number)
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
		if plan.delta_values[place] < 0 && number < opened.capacity && storage_mount.block_count(&opened, number) != 0 && !outside_block(number) {
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
			if write.encrypted_data {
				expected: Block = write.bytes^
				_ = store_encryption.data_block_encrypt(&plan.store_keys, write.number, write.data_check, &expected)
				if string(slot(u64(index))) != string(expected[:]) {
					differ += 1
				}
				intrinsics.mem_zero_volatile(&expected, size_of(expected))
			} else if string(slot(u64(index))) != string(write.bytes^[:]) {
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
