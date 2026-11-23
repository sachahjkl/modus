// The open of a data disk (src/library/modus/contract/store): which root to use, the check of
// each block that it names, and the blocks in use. The storage service runs
// it at its start; the modus tool runs the same code on the host, on each
// image of a disk that a loss of power can leave (tools/modustool,
// power_loss.odin). Pure code: no kernel operation, no allocation. The
// blocks come from a Block_Reader that the caller gives.
package storage_mount

import "base:intrinsics"
import format "modus:contract/store"
import block_tree "internal:storage/storage_object"
import tree "internal:storage/storage_tree"

BLOCK_SIZE :: format.BLOCK_SIZE // The bytes of one block of the disk.
SCRATCH_BLOCKS :: format.OBJECT_FANOUT + 2 // The blocks of data of one object node, read in one request.

// The source of the blocks of a disk: the storage service reads them
// through its block service, the tool from an image in memory.
Block_Reader :: struct {
	// read reads the blocks of `numbers` into `into`, one after the other
	// (len(numbers) * BLOCK_SIZE bytes). false: the device reported an error.
	read: proc "contextless" (reader: ^Block_Reader, numbers: []u64, into: []u8) -> bool,
	// check gives the check of the bytes of a block that read gave. nil:
	// format.check. The modus tool gives the check that it computed for
	// the same bytes before: its images differ in a few blocks.
	check: proc "contextless" (reader: ^Block_Reader, number: u64, bytes: []u8) -> u64,
	// value gives the value of the bytes of a block of data at the block
	// `index` of its object. nil: storage_object.block_value. The kernel
	// tool gives the value that it computed before, as for check.
	value: proc "contextless" (reader: ^Block_Reader, number: u64, index: u64, bytes: ^block_tree.Block) -> format.Block_Value,
	data: rawptr, // The state of the caller.
}

// check_of_block gives the check of the bytes of a block: from the reader
// when it has its own, else the first 8 bytes of their BLAKE3 hash.
check_of_block :: proc "contextless" (reader: ^Block_Reader, number: u64, bytes: []u8) -> u64 {
	return reader.check != nil ? reader.check(reader, number, bytes) : format.check(bytes)
}

// value_of_block gives the value of a block of data at the block `index` of
// its object: from the reader when it has its own, else computed.
value_of_block :: proc "contextless" (reader: ^Block_Reader, number: u64, index: u64, bytes: ^block_tree.Block) -> format.Block_Value {
	return reader.value != nil ? reader.value(reader, number, index, bytes) : block_tree.block_value(bytes, index)
}

// Reader_Source reads the nodes of the trees through a Block_Reader, for
// src/library/internal/storage/storage_tree.
Reader_Source :: struct {
	using source: tree.Source,
	reader:       ^Block_Reader, // Where the blocks come from.
	disk_size:    u64, // The blocks of the disk: a Pointer at or past it is Wrong.
}

// reader_source makes the source of the nodes of a disk.
reader_source :: proc "contextless" (reader: ^Block_Reader, disk_size: u64) -> Reader_Source {
	return {source = {read = reader_source_read}, reader = reader, disk_size = disk_size}
}

// reader_source_read reads one node and compares it with the check of its
// Pointer. The blocks 0 and 1 (the roots) and a block past the disk are
// Wrong: no Pointer names them.
reader_source_read :: proc "contextless" (source: ^tree.Source, pointer: format.Pointer, into: ^tree.Block) -> tree.Read {
	from := (^Reader_Source)(source)
	if pointer.block < 2 || pointer.block >= from.disk_size {
		return .Wrong
	}
	numbers := [1]u64{pointer.block}
	if !from.reader.read(from.reader, numbers[:], into[:]) {
		return .Device
	}
	return check_of_block(from.reader, pointer.block, into[:]) == pointer.check ? .Good : .Wrong
}

// Object_Source reads the block trees of objects through a Block_Reader,
// for src/library/internal/storage/storage_object: the modus tool reads the objects of an image
// with it.
Object_Source :: struct {
	using source: block_tree.Source,
	reader:       ^Block_Reader, // Where the blocks come from.
	disk_size:    u64, // The blocks of the disk.
}

// object_source makes the source of the block trees of a disk.
object_source :: proc "contextless" (reader: ^Block_Reader, disk_size: u64) -> Object_Source {
	return {source = {read_node = object_source_read_node, read_block = object_source_read_block, value = object_source_value}, reader = reader, disk_size = disk_size}
}

// object_source_value is the `value` of an object source.
object_source_value :: proc "contextless" (source: ^block_tree.Source, number: u64, index: u64, bytes: ^block_tree.Block) -> format.Block_Value {
	return value_of_block((^Object_Source)(source).reader, number, index, bytes)
}

// object_source_read_node reads one object node and compares it with the
// check of its Pointer.
object_source_read_node :: proc "contextless" (source: ^block_tree.Source, pointer: format.Pointer, into: ^block_tree.Block) -> block_tree.Read {
	from := (^Object_Source)(source)
	if pointer.block < 2 || pointer.block >= from.disk_size {
		return .Wrong
	}
	numbers := [1]u64{pointer.block}
	if !from.reader.read(from.reader, numbers[:], into[:]) {
		return .Device
	}
	return check_of_block(from.reader, pointer.block, into[:]) == pointer.check ? .Good : .Wrong
}

// object_source_read_block reads one block of data with no check: its
// check is its value, which the caller compares.
object_source_read_block :: proc "contextless" (source: ^block_tree.Source, number: u64, into: ^block_tree.Block) -> block_tree.Read {
	from := (^Object_Source)(source)
	if number < 2 || number >= from.disk_size {
		return .Wrong
	}
	numbers := [1]u64{number}
	return from.reader.read(from.reader, numbers[:], into[:]) ? .Good : .Device
}

// The counts of one store, as its store block keeps them and as the walk
// finds them.
Store_Counts :: struct {
	objects:        u64, // `format.Store_Block.objects`.
	trees:          u64, // `format.Store_Block.trees`.
	current_blocks: u64, // `format.Store_Block.current_blocks`.
	node_blocks:    u64, // `format.Store_Block.node_blocks`.
	removing:       u64, // `format.Store_Block.removing`.
}

// store_counts_of gives the counts that a store block keeps.
store_counts_of :: proc "contextless" (block: ^format.Store_Block) -> Store_Counts {
	return {objects = block.objects, trees = block.trees, current_blocks = block.current_blocks, node_blocks = block.node_blocks, removing = block.removing}
}

// The head of a store block: its fields with no padding. The open and the
// service keep one for each store; a whole block of 4096 bytes for each of
// the thousands of stores of the table would cost 64 MiB.
Store_Head :: struct {
	tree:           format.Pointer,
	removals:       format.Pointer,
	next_removal:   u64,
	objects:        u64,
	trees:          u64,
	current_blocks: u64,
	node_blocks:    u64,
	removing:       u64,
}

// store_head_of gives the head of a store block.
store_head_of :: proc "contextless" (block: ^format.Store_Block) -> Store_Head {
	return {tree = block.tree, removals = block.removals, next_removal = block.next_removal, objects = block.objects, trees = block.trees, current_blocks = block.current_blocks, node_blocks = block.node_blocks, removing = block.removing}
}

// store_block_of gives the store block of a head, with zero bytes in its
// reserved fields and its padding.
store_block_of :: proc "contextless" (head: Store_Head) -> (block: format.Store_Block) {
	block.tree, block.removals, block.next_removal = head.tree, head.removals, head.next_removal
	block.objects, block.trees, block.current_blocks = head.objects, head.trees, head.current_blocks
	block.node_blocks, block.removing = head.node_blocks, head.removing
	return block
}

// The owner of a page of the store table: no store, and no free block.
STORE_TABLE_OWNER :: max(u16)
#assert(format.STORE_CAPACITY < int(STORE_TABLE_OWNER))

// What the open knows of a disk. The storage service keeps it while it
// runs; the tool makes one for each image.
//
// The tables of the blocks have the size of the disk, so they are memory
// that the caller gives (state_bind): the storage service takes it from its
// budget, a test from its allocator. Each block costs BLOCK_STATE_BYTES and
// three bits; the hash index costs per root that it can hold, not per block.
State :: struct {
	root:          format.Root, // The root that the open uses.
	root_place:    u64, // 0 or 1: the place of the root on the disk.
	disk_size:     u64, // The blocks of the disk that the service uses: at most capacity.
	capacity:      u64, // The blocks that the tables of the blocks hold (state_bind).
	// The pages of the store table, as the open read them; the service
	// keeps them up to date, and changes the counts of the cells.
	store_pages:   [format.STORE_PAGE_CAPACITY]format.Store_Table_Page,
	// A page with a wrong check: the open and the service serve no store of
	// it, and make no new store in it.
	store_page_damaged: [format.STORE_PAGE_CAPACITY]bool,
	// The head of each store, with the counts that the walk found in place
	// of the counts on the disk: the service starts from them.
	store_heads:   [format.STORE_CAPACITY]Store_Head,
	in_use:        []u64, // Bit n: block n is named by the root.
	in_use_count:  u64, // The blocks in use.
	// The reference count of each block that the root names: for an object
	// node or a block of data, the object nodes, the entries and the
	// versions that name it; 1 for a store block, a node, an index, a leaf
	// and a page of the store table.
	references:    []u32,
	owner:         []u16, // The store that names the block, plus 1; STORE_TABLE_OWNER for a page of the store table.
	wrong_blocks:  []u64, // Bit n: block n was read and has a wrong check, or breaks a rule of the format.
	// Bit n: the block tree under the object node or the block n (n
	// included) has a wrong block. A state whose root has this bit is
	// damaged: a read of it gives Damaged, and its release does not walk
	// under it (its blocks stay in use until the next open counts again).
	damaged_under: []u64,
	store_versions: [format.STORE_CAPACITY]u64, // The versions of the objects of each store.
	store_shared:  [format.STORE_CAPACITY]u64, // The blocks of each store with a reference count of 2 or more.
	// The distinct blocks of each store that the walk counted: the count that
	// the store has in memory. The blocks under a block with a wrong check
	// are not counted, and they are free in memory too.
	store_recount: [format.STORE_CAPACITY]u64,
	// The walk found a fault of the engine in the store (a block of one name
	// named two times, a block named from two stores, a count that does not
	// fit its type): its counts are not trusted, and the service makes no
	// change in it.
	store_faulty:  [format.STORE_CAPACITY]bool,
	store_damaged: [format.STORE_CAPACITY]bool, // Its store block or a node of one of its trees is wrong.
	store_damaged_objects: [format.STORE_CAPACITY]u64, // Objects with a wrong object node or a wrong block of data.
	scratch:       [SCRATCH_BLOCKS * BLOCK_SIZE]u8, // The blocks of one read.
	// One object node for each level of the block tree that the walk is
	// in: a level reads its children into the node of the level below.
	object_nodes:  [format.OBJECT_LEVEL_LIMIT]format.Object_Node,
	// One walk for each level of trees inside trees: a walk holds the nodes
	// of its path, and a tree inside a tree is walked while its entry is read.
	walks:         [format.NESTING_LIMIT + 1]tree.Walk,
	// The walk of the store that the open reads now: the walks of its trees
	// name it, so it lives in the state, not on the stack.
	store_walk:    Store_Walk,
	// The roots of the current objects by their hash (hash_index.odin): the
	// walk makes it, and the service keeps it up to date.
	hash_index:    Hash_Index,
}

// What the open of a disk found: the counts, the damage, which root it
// used, and the faults of the engine. The service writes it on the log at
// its start; the tests of a loss of power check it.
Mount :: struct {
	generation:      u64, // The generation of the root that the open uses.
	stores:          u64, // The stores of the root.
	objects:         u64, // The objects of all the stores.
	trees:           u64, // The trees inside the trees of the stores.
	removing:        u64, // The trees in the removal queues.
	checked:         u64, // Blocks read and compared with their check.
	wrong:           u64, // Blocks with a wrong check, or that break a rule of the format.
	damaged_objects: u64, // Objects with a wrong object node or a wrong block of data.
	damaged_stores:  u64, // Stores whose store block or a node of a tree is wrong.
	needs_format:    bool, // No commit followed the first root: the disk holds no object, the caller formats it.
	first_cut:       bool, // The disk had only a first root with a wrong check: a format that a stop cut.
	older:           bool, // The newest root named a wrong block and the root before it names none: the root before it is used.
	cut:             u64, // Not 0: the generation that a root with a wrong check gives; the open does not use it.
	failed:          bool, // No root is usable, or the device reported an error.
	versions:        u64, // The versions of all the objects.
	damaged_versions: u64, // Versions with a wrong object node or a wrong block of data, or in a wrong leaf.
	shared:          u64, // Blocks with a reference count of 2 or more.
	// Faults of the engine itself, that no stop of the machine can make: a
	// block of one name that the root names two times, a block named from
	// two stores, and a store whose counts are not the counts of what it
	// names (its blocks, its objects, its trees, the entries of a tree).
	named_twice:          u64, // Blocks of one name that the root names two times.
	named_by_two_stores:  u64, // Blocks named from two stores.
	stores_with_wrong_count: u64, // Stores walked whole whose count of blocks, or a count of the store block or of an entry, is wrong.
	reference_overflow:   u64, // Blocks with more names than a count holds.
	stores_recounted:     u64, // Stores whose count in the root differs from the recount: the open takes the recount.
	damaged_store_pages:  u64, // Pages of the store table with a wrong check: their stores are not served.
	larger_than_capacity: bool, // The root names more blocks than the tables hold: no root is usable with this memory.
	// Roots of current objects whose store has another root with the same
	// first 8 bytes of hash and the same size: two copies of one object,
	// that the hash index did not find at their commit (docs/STORAGE.md,
	// "4.7 The same object one time").
	repeated_hashes:      u64,
}

// REFERENCE_LIMIT is the most names of one block that a count holds: the
// open and a commit refuse a count past it.
REFERENCE_LIMIT :: u64(max(u32))

// The bytes of the tables of one block, besides its three bits: its count
// of names and its owner.
BLOCK_STATE_BYTES :: size_of(u32) + size_of(u16)

// The places of the tables of a State in the memory that state_bind takes.
State_Layout :: struct {
	bitmap_words:   u64, // The words of each of the three bitmaps.
	references:     u64, // The byte of the counts of names.
	owner:          u64, // The byte of the owners.
	hash_records:   u64, // The byte of the records of the hash index.
	hash_slots:     u64, // The byte of the slots of the hash index.
	hash_capacity:  u64, // The records, and the slots, of the hash index: a power of two.
	bytes:          u64, // The bytes of the whole memory.
}

// state_layout gives the memory of the tables for a disk of `blocks`
// blocks and a hash index of `hash_roots` roots. ok is false for a count
// of blocks that no disk has, for no root, or for a size that a u64 does
// not hold.
state_layout :: proc "contextless" (blocks: u64, hash_roots: u64) -> (layout: State_Layout, ok: bool) {
	words := format.bitmap_words_for_blocks(blocks) or_return
	// With at most 2^52 blocks and 2^40 roots, no size below wraps a u64.
	if hash_roots == 0 || hash_roots > u64(1) << 40 {
		return {}, false
	}
	#assert(format.DISK_BLOCKS_MAX < u64(1) << 52)
	// The hash index fills at most half of its slots.
	layout.hash_capacity = 2
	for layout.hash_capacity < 2 * hash_roots {
		layout.hash_capacity *= 2
	}
	layout.bitmap_words = words
	cursor := 3 * words * 8
	layout.references = cursor
	cursor += blocks * size_of(u32)
	layout.owner = cursor
	cursor += blocks * size_of(u16)
	cursor = (cursor + 7) &~ u64(7)
	layout.hash_records = cursor
	cursor += layout.hash_capacity * size_of(Root_Record)
	layout.hash_slots = cursor
	cursor += layout.hash_capacity * size_of(u64)
	layout.bytes = cursor
	return layout, true
}

// state_bind gives a State the memory of its tables, for a disk of up to
// `blocks` blocks. The memory is aligned on 8 bytes and has at least the
// bytes of state_layout; its contents do not matter: the open clears what
// it uses. ok is false when the memory is too small or not aligned.
state_bind :: proc "contextless" (state: ^State, memory: []u8, blocks: u64, hash_roots: u64) -> bool {
	layout, ok := state_layout(blocks, hash_roots)
	if !ok || u64(len(memory)) < layout.bytes || uintptr(raw_data(memory)) & 7 != 0 {
		return false
	}
	base := raw_data(memory)
	words := int(layout.bitmap_words)
	state.in_use = ([^]u64)(base)[:words]
	state.wrong_blocks = ([^]u64)(base)[words:2 * words]
	state.damaged_under = ([^]u64)(base)[2 * words:3 * words]
	state.references = ([^]u32)(&base[layout.references])[:blocks]
	state.owner = ([^]u16)(&base[layout.owner])[:blocks]
	state.hash_index.records = ([^]Root_Record)(&base[layout.hash_records])[:layout.hash_capacity]
	state.hash_index.slots = ([^]u64)(&base[layout.hash_slots])[:layout.hash_capacity]
	state.hash_index.slot_bits = 0
	for u64(1) << state.hash_index.slot_bits < layout.hash_capacity {
		state.hash_index.slot_bits += 1
	}
	state.capacity = blocks
	state_tables_clear(state)
	return true
}

// state_tables_clear sets each table of the blocks and the hash index to
// zero.
state_tables_clear :: proc "contextless" (state: ^State) {
	zero_words :: proc "contextless" (words: []u64) {
		if len(words) > 0 {
			intrinsics.mem_zero(raw_data(words), len(words) * size_of(u64))
		}
	}
	zero_words(state.in_use)
	zero_words(state.wrong_blocks)
	zero_words(state.damaged_under)
	if len(state.references) > 0 {
		intrinsics.mem_zero(raw_data(state.references), len(state.references) * size_of(u32))
	}
	if len(state.owner) > 0 {
		intrinsics.mem_zero(raw_data(state.owner), len(state.owner) * size_of(u16))
	}
	state.in_use_count = 0
	hash_index_reset(state)
}

// store_cell gives the cell of the store of a number in the pages of the
// open.
store_cell :: #force_inline proc "contextless" (state: ^State, number: int) -> ^format.Store_Entry {
	page, cell := format.store_place(number)
	return &state.store_pages[page].cells[cell]
}

// store_numbers gives the count of the numbers of stores that the pages of
// the root hold: each cell of each page, free or not.
store_numbers :: #force_inline proc "contextless" (state: ^State) -> int {
	return int(min(state.root.store_page_count, format.STORE_PAGE_CAPACITY)) * format.STORES_OF_A_PAGE
}

// reference counts one more name of a block, from a store. It gives true
// for the first name: the caller reads and checks the block one time.
reference :: proc "contextless" (state: ^State, number: u64, store_index: int, result: ^Mount) -> (first: bool) {
	if number >= state.capacity {
		return false
	}
	if state.references[number] == 0 {
		state.references[number] = 1
		state.owner[number] = u16(store_index + 1)
		mark(state, number, true)
		return true
	}
	if int(state.owner[number]) != store_index + 1 {
		result.named_by_two_stores += 1
		state.store_faulty[store_index] = true
		if state.owner[number] != 0 && state.owner[number] != STORE_TABLE_OWNER {
			state.store_faulty[int(state.owner[number]) - 1] = true
		}
	}
	if u64(state.references[number]) >= REFERENCE_LIMIT {
		result.reference_overflow += 1
		state.store_faulty[store_index] = true
		return false
	}
	state.references[number] += 1
	if state.references[number] == 2 {
		state.store_shared[store_index] += 1
		result.shared += 1
	}
	return false
}

// wrong_block says if a block was read and found wrong.
wrong_block :: proc "contextless" (state: ^State, number: u64) -> bool {
	return number < state.capacity && state.wrong_blocks[number / 64] >> (number % 64) & 1 != 0
}

// wrong_block_set records that a block is wrong.
wrong_block_set :: proc "contextless" (state: ^State, number: u64) {
	if number < state.capacity {
		state.wrong_blocks[number / 64] |= 1 << (number % 64)
	}
}

// damaged_under says if the block tree under a block has a wrong block.
damaged_under :: proc "contextless" (state: ^State, number: u64) -> bool {
	return number < state.capacity && state.damaged_under[number / 64] >> (number % 64) & 1 != 0
}

// damaged_under_set records that the block tree under a block has a wrong
// block.
damaged_under_set :: proc "contextless" (state: ^State, number: u64) {
	if number < state.capacity {
		state.damaged_under[number / 64] |= 1 << (number % 64)
	}
}

// reference_state counts one name of the root of a state of an object (its
// current state or a version) of `size` bytes. At the first name of each
// block under it, the block is read and checked: an object node by its
// check and the rules of its format, a block of data by its value at its
// place. A block that an earlier state named is not read again. It gives
// Wrong when a block under the root is wrong (then, or at its first name),
// and the blocks that the state holds. `named` counts the blocks of the
// store that this name counted first.
reference_state :: proc "contextless" (state: ^State, reader: ^Block_Reader, root: format.Pointer, size: u64, store_index: int, result: ^Mount, named: ^u64) -> (outcome: Read, held: u64) {
	if root.block == 0 {
		return .Good, 0
	}
	if size > format.OBJECT_SIZE_LIMIT {
		// A size that no object has: the engine never walks under it.
		result.wrong += 1
		wrong_block_set(state, root.block)
		damaged_under_set(state, root.block)
		return .Wrong, 0
	}
	levels := format.object_levels(size)
	first: bool
	outcome, first, held, _ = reference_object_child(state, reader, {block = root.block, check = root.check}, levels, 0, size, false, store_index, result, named)
	if first || outcome != .Good || levels == 0 {
		return outcome, levels == 0 ? 1 : held
	}
	// A root that an earlier state named: its blocks are in its node.
	numbers := [1]u64{root.block}
	node := &state.object_nodes[levels - 1]
	if !reader.read(reader, numbers[:], ([^]u8)(node)[:BLOCK_SIZE]) {
		return .Device, 0
	}
	held = 1
	for &child in node.children {
		held += child.blocks
	}
	return .Good, held
}

// reference_object_child counts one name of an object node of `level`, or
// of a block of data at level 0, that covers the blocks from `base`, and
// walks under it at its first name. value_known: the parent holds the
// value of the child, and the walk compares it. It gives the blocks of the
// child and its value.
reference_object_child :: proc "contextless" (state: ^State, reader: ^Block_Reader, child: format.Object_Child, level: int, base: u64, size: u64, value_known: bool, store_index: int, result: ^Mount, named: ^u64) -> (outcome: Read, first: bool, blocks: u64, value: format.Block_Value) {
	if child.block < 2 || child.block >= state.disk_size {
		result.wrong += 1
		return .Wrong, false, child.blocks, child.value
	}
	if !reference(state, child.block, store_index, result) {
		bad := wrong_block(state, child.block) || damaged_under(state, child.block)
		return bad ? .Wrong : .Good, false, child.blocks, child.value
	}
	named^ += 1
	numbers := [1]u64{child.block}
	if level == 0 {
		// The block of a state of one block.
		bytes := (^block_tree.Block)(raw_data(scratch_block(state, 0)))
		if !reader.read(reader, numbers[:], bytes[:]) {
			return .Device, true, 1, {}
		}
		result.checked += 1
		value = value_of_block(reader, child.block, base, bytes)
		if format.value_check(value) != child.check || (value_known && value != child.value) || block_tree.is_zero(bytes[:]) {
			result.wrong += 1
			wrong_block_set(state, child.block)
			damaged_under_set(state, child.block)
			return .Wrong, true, 1, value
		}
		return .Good, true, 1, value
	}
	node := &state.object_nodes[level - 1]
	if !reader.read(reader, numbers[:], ([^]u8)(node)[:BLOCK_SIZE]) {
		return .Device, true, child.blocks, child.value
	}
	result.checked += 1
	if check_of_block(reader, child.block, ([^]u8)(node)[:BLOCK_SIZE]) != child.check || !block_tree.node_valid(node, level, base, size) {
		result.wrong += 1
		wrong_block_set(state, child.block)
		damaged_under_set(state, child.block)
		return .Wrong, true, child.blocks, child.value
	}
	span := format.object_span(level - 1)
	blocks = 1
	damaged := false
	if level == 1 {
		// The blocks of data that no state named before, read in one request;
		// each one is checked by its value at its place.
		unread_numbers: [format.OBJECT_FANOUT]u64
		unread_places: [format.OBJECT_FANOUT]int
		unread_count := 0
		for &item, place in node.children {
			if item.block == 0 {
				continue
			}
			blocks += 1
			if item.block >= state.disk_size {
				result.wrong += 1
				damaged = true
				continue
			}
			if reference(state, item.block, store_index, result) {
				named^ += 1
				unread_numbers[unread_count] = item.block
				unread_places[unread_count] = place
				unread_count += 1
			} else if wrong_block(state, item.block) {
				damaged = true
			}
		}
		if unread_count != 0 {
			if !reader.read(reader, unread_numbers[:unread_count], state.scratch[:unread_count * BLOCK_SIZE]) {
				return .Device, true, blocks, {}
			}
			result.checked += u64(unread_count)
			for number in 0 ..< unread_count {
				item := &node.children[unread_places[number]]
				bytes := (^block_tree.Block)(raw_data(scratch_block(state, number)))
				if value_of_block(reader, item.block, base + u64(unread_places[number]), bytes) != item.value || block_tree.is_zero(bytes[:]) {
					result.wrong += 1
					wrong_block_set(state, item.block)
					damaged_under_set(state, item.block)
					damaged = true
				}
			}
		}
	} else {
		for place in 0 ..< format.OBJECT_FANOUT {
			// A copy: the level below reads into its own node, not this one.
			item := node.children[place]
			if item.block == 0 {
				continue
			}
			child_outcome, child_first, child_blocks, child_value := reference_object_child(state, reader, item, level - 1, base + u64(place) * span, size, true, store_index, result, named)
			if child_outcome == .Device {
				return .Device, true, blocks, {}
			}
			if child_outcome == .Wrong {
				damaged = true
			} else if child_first && (child_blocks != item.blocks || child_value != item.value) {
				// A node that gives another count or another value than what
				// it names: a rule of the format.
				result.wrong += 1
				wrong_block_set(state, item.block)
				damaged_under_set(state, item.block)
				damaged = true
			}
			blocks += item.blocks
		}
	}
	value = block_tree.node_value(node)
	if damaged {
		damaged_under_set(state, child.block)
		return .Wrong, true, blocks, value
	}
	return .Good, true, blocks, value
}

used :: proc "contextless" (state: ^State, number: u64) -> bool {
	return number < state.capacity && state.in_use[number / 64] >> (number % 64) & 1 != 0
}

// mark sets or clears the bit of a block. It gives false when the bit had
// the value already.
mark :: proc "contextless" (state: ^State, number: u64, value: bool) -> bool {
	if number >= state.capacity || used(state, number) == value {
		return false
	}
	if value {
		state.in_use[number / 64] |= 1 << (number % 64)
		state.in_use_count += 1
	} else {
		state.in_use[number / 64] &~= 1 << (number % 64)
		state.in_use_count -= 1
	}
	return true
}

// What a read of blocks gave.
Read :: enum {
	Good, // Each block has its check.
	Wrong, // A block does not have the check of its Pointer, or a Pointer names no block of the disk.
	Device, // The device reported an error.
}

// read_checked reads blocks into the scratch of the state, from `first_slot`
// on, and compares each one with the check of its Pointer. It gives the
// count of wrong blocks.
read_checked :: proc "contextless" (state: ^State, reader: ^Block_Reader, pointers: []format.Pointer, first_slot: int) -> (wrong: u64, result: Read) {
	numbers: [SCRATCH_BLOCKS]u64
	if first_slot + len(pointers) > SCRATCH_BLOCKS {
		return u64(len(pointers)), .Wrong
	}
	for pointer, index in pointers {
		if pointer.block < 2 || pointer.block >= state.disk_size {
			return u64(len(pointers)), .Wrong
		}
		numbers[index] = pointer.block
	}
	into := state.scratch[first_slot * BLOCK_SIZE:][:len(pointers) * BLOCK_SIZE]
	if !reader.read(reader, numbers[:len(pointers)], into) {
		return 0, .Device
	}
	for pointer, index in pointers {
		if check_of_block(reader, pointer.block, into[index * BLOCK_SIZE:][:BLOCK_SIZE]) != pointer.check {
			wrong += 1
		}
	}
	return wrong, wrong == 0 ? .Good : .Wrong
}

// scratch_block gives one block of the scratch.
scratch_block :: proc "contextless" (state: ^State, index: int) -> []u8 {
	return state.scratch[index * BLOCK_SIZE:][:BLOCK_SIZE]
}

// single counts the one name of a block that only one name can have: a
// store block, a version index, a version leaf. It reads and checks it into
// the scratch block 0.
single :: proc "contextless" (state: ^State, reader: ^Block_Reader, pointer: format.Pointer, store_index: int, result: ^Mount, named: ^u64) -> Read {
	if !reference(state, pointer.block, store_index, result) {
		result.named_twice += 1
		state.store_faulty[store_index] = true
	} else {
		named^ += 1
	}
	wrong, outcome := read_checked(state, reader, {pointer}, 0)
	result.checked += 1
	if outcome == .Wrong {
		result.wrong += wrong
		wrong_block_set(state, pointer.block)
	}
	return outcome
}

// The walk of one store, for the visits of the walks of its trees.
Store_Walk :: struct {
	state:       ^State, // The state of the open.
	reader:      ^Block_Reader, // Where the blocks come from.
	source:      Reader_Source, // The source of the nodes of its trees.
	result:      ^Mount, // The result of the open.
	store_index: int, // The cell of the store in the root.
	named:       u64, // The distinct blocks of the store.
	counts:      Store_Counts, // What the walk counted.
	nesting:     int, // The level of the tree that is walked: 0 for the tree of the store.
	in_removals: bool, // The walk is in the removal queue: its entries are trees to free.
	complete:    bool, // Each block of the store was read: its counts are known.
	device:      bool, // The device reported an error.
	broken:      bool, // A node or an entry breaks a rule: the store is damaged.
	entry_count_wrong: bool, // An entry of a tree gives another count of entries than its tree has.
}

// walk reads each block that a root names, checks it, and counts its
// references: the store blocks, the nodes of each tree, the objects, their
// versions, and each block one time. A wrong object node or a wrong block of data
// does not end the walk: its object, or its version, is damaged. A wrong
// store block or node damages its store: the walk of that store stops. The
// blocks under a wrong block are not known, so they are free. It gives
// false when the device reported an error.
walk :: proc "contextless" (state: ^State, reader: ^Block_Reader, candidate: ^format.Root, result: ^Mount) -> bool {
	state_tables_clear(state)
	state.store_pages = {}
	state.store_page_damaged = {}
	state.store_versions = {}
	state.store_shared = {}
	state.store_recount = {}
	state.store_faulty = {}
	state.store_damaged = {}
	state.store_damaged_objects = {}
	state.store_heads = {}
	mark(state, 0, true)
	mark(state, 1, true)
	result.stores, result.objects, result.trees, result.removing = 0, 0, 0, 0
	result.checked, result.wrong = 0, 0
	result.damaged_objects, result.damaged_stores, result.named_twice, result.stores_with_wrong_count = 0, 0, 0, 0
	result.versions, result.damaged_versions, result.shared, result.named_by_two_stores = 0, 0, 0, 0
	result.reference_overflow, result.stores_recounted, result.repeated_hashes = 0, 0, 0
	result.damaged_store_pages = 0
	pages := int(min(candidate.store_page_count, format.STORE_PAGE_CAPACITY))
	for page in 0 ..< pages {
		if !store_page_read(state, reader, candidate.store_pages[page], page, result) {
			return false
		}
	}
	for page in 0 ..< pages {
		if state.store_page_damaged[page] {
			continue
		}
		for &store, cell in state.store_pages[page].cells {
			if store.name[0] == 0 {
				continue
			}
			result.stores += 1
			ok := walk_store(state, reader, &store, page * format.STORES_OF_A_PAGE + cell, result)
			// The walk of a store names the reader and the result of this call
			// only while it runs.
			state.store_walk = {}
			if !ok {
				return false
			}
		}
	}
	return true
}

// store_page_read counts the one name of a page of the store table, reads
// it and checks it: its check, its magic, and a name of each cell that is
// zero bytes after its first zero byte. A wrong page damages its stores,
// and the walk goes on. It gives false when the device reported an error.
store_page_read :: proc "contextless" (state: ^State, reader: ^Block_Reader, pointer: format.Pointer, page: int, result: ^Mount) -> bool {
	if pointer.block < 2 || pointer.block >= state.disk_size {
		result.wrong += 1
		result.damaged_store_pages += 1
		state.store_page_damaged[page] = true
		return true
	}
	if state.references[pointer.block] != 0 {
		// A block of one name named two times: a fault of the engine.
		result.named_twice += 1
		result.damaged_store_pages += 1
		state.store_page_damaged[page] = true
		return true
	}
	state.references[pointer.block] = 1
	state.owner[pointer.block] = STORE_TABLE_OWNER
	mark(state, pointer.block, true)
	wrong, outcome := read_checked(state, reader, {pointer}, 0)
	result.checked += 1
	switch outcome {
	case .Device:
		return false
	case .Wrong:
		result.wrong += wrong
		wrong_block_set(state, pointer.block)
		result.damaged_store_pages += 1
		state.store_page_damaged[page] = true
		return true
	case .Good:
	}
	read := (^format.Store_Table_Page)(raw_data(scratch_block(state, 0)))
	valid := read.magic == format.STORE_TABLE_MAGIC && read.reserved == 0 && read.unused == 0
	for &cell in read.cells {
		ended := false
		for byte in cell.name {
			if ended && byte != 0 {
				valid = false
			}
			ended ||= byte == 0
		}
		// A store name has at most NAME_CAPACITY - 1 bytes: the last byte is
		// zero.
		valid &&= cell.name[format.NAME_CAPACITY - 1] == 0
	}
	if !valid {
		result.wrong += 1
		wrong_block_set(state, pointer.block)
		result.damaged_store_pages += 1
		state.store_page_damaged[page] = true
		return true
	}
	state.store_pages[page] = read^
	return true
}

// walk_store walks the store of a cell of the root: its store block, its
// tree, its removal queue, the block trees and the versions of its objects.
// It counts each block, and compares the counts with the store block. false:
// the device failed.
walk_store :: proc "contextless" (state: ^State, reader: ^Block_Reader, store: ^format.Store_Entry, index: int, result: ^Mount) -> bool {
	named: u64
	switch single(state, reader, store.store, index, result, &named) {
	case .Device:
		return false
	case .Wrong:
		result.damaged_stores += 1
		state.store_damaged[index] = true
		state.store_recount[index] = named
		return true
	case .Good:
	}
	block_bytes := (^format.Store_Block)(raw_data(scratch_block(state, 0)))
	head := &state.store_heads[index]
	head^ = store_head_of(block_bytes)
	on_disk := store_counts_of(block_bytes)
	block := head
	walking := &state.store_walk
	walking^ = {
		state       = state,
		reader      = reader,
		source      = reader_source(reader, state.disk_size),
		result      = result,
		store_index = index,
		named       = named,
		complete    = true,
	}
	roots := [2]format.Pointer{block.tree, block.removals}
	for root, which in roots {
		walking.in_removals = which == 1
		walk_one_tree(walking, root, 0)
		if walking.device {
			return false
		}
		if walking.broken {
			break
		}
	}
	if walking.broken {
		result.damaged_stores += 1
		state.store_damaged[index] = true
		walking.complete = false
	}
	state.store_recount[index] = walking.named
	wrong_count := walking.named != store.used || walking.counts != on_disk || walking.entry_count_wrong
	if walking.named != store.used {
		result.stores_recounted += 1
	}
	if wrong_count && walking.complete {
		result.stores_with_wrong_count += 1
	}
	result.objects += walking.counts.objects
	result.trees += walking.counts.trees
	result.removing += walking.counts.removing
	// The service starts from the counts of the walk: the next commit
	// writes them.
	if !walking.broken {
		block.objects = walking.counts.objects
		block.trees = walking.counts.trees
		block.current_blocks = walking.counts.current_blocks
		block.node_blocks = walking.counts.node_blocks
		block.removing = walking.counts.removing
	}
	return true
}

// walk_one_tree walks one tree of a store, and each tree inside it while
// its entry is read. It gives the count of its entries.
walk_one_tree :: proc "contextless" (walking: ^Store_Walk, root: format.Pointer, nesting: int) -> (entries: u64) {
	if nesting > format.NESTING_LIMIT {
		walking.broken = true
		return 0
	}
	state := walking.state
	one := &state.walks[nesting]
	one.source = &walking.source.source
	one.shape = tree.TREE_SHAPE
	one.visit_node = visit_node_of_store
	one.visit_record = visit_entry_of_store
	one.data = walking
	one.nodes, one.records = 0, 0
	before := walking.nesting
	walking.nesting = nesting
	failure := tree.walk_tree(one, root)
	walking.nesting = before
	switch failure {
	case .Device:
		walking.device = true
	case .Wrong, .Damaged, .Full, .Write:
		if one.failed_block != 0 && !wrong_block(state, one.failed_block) {
			wrong_block_set(state, one.failed_block)
			walking.result.wrong += 1
		}
		walking.broken = true
	case .None:
	}
	return one.records
}

visit_node_of_store :: proc "contextless" (one: ^tree.Walk, pointer: format.Pointer) -> bool {
	walking := (^Store_Walk)(one.data)
	if pointer.block < 2 || pointer.block >= walking.state.disk_size {
		return true // The read says that it is wrong.
	}
	if !reference(walking.state, pointer.block, walking.store_index, walking.result) {
		// A node named two times: the walk does not read it again, so a loop
		// of nodes ends.
		walking.result.named_twice += 1
		walking.state.store_faulty[walking.store_index] = true
		return false
	}
	walking.named += 1
	walking.counts.node_blocks += 1
	walking.result.checked += 1
	return true
}

visit_entry_of_store :: proc "contextless" (one: ^tree.Walk, _: []u8, value: []u8) {
	walking := (^Store_Walk)(one.data)
	state := walking.state
	result := walking.result
	index := walking.store_index
	entry := (^format.Entry)(raw_data(value))^
	queued := walking.in_removals && walking.nesting == 0
	if queued {
		if entry.kind != u64(format.Entry_Kind.Tree) {
			walking.broken = true
			one.failure = .Damaged
			return
		}
		walking.counts.removing += 1
	}
	kind, kind_ok := format.entry_kind_of_word(entry.kind)
	if !kind_ok {
		walking.broken = true
		one.failure = .Damaged
		return
	}
	switch kind {
	case .Object:
		walking.counts.objects += 1
		outcome, held := reference_state(state, walking.reader, entry.pointer, entry.size, index, result, &walking.named)
		walking.counts.current_blocks += held
		switch outcome {
		case .Device:
			walking.device = true
			one.failure = .Device
			return
		case .Wrong:
			result.damaged_objects += 1
			state.store_damaged_objects[index] += 1
			walking.complete = false
		case .Good:
		}
		// Each entry is counted, a damaged one too, so that a commit that
		// replaces it takes its count back; a lookup skips a damaged root.
		if hash_index_name(state, entry.hash, entry.pointer, entry.size) {
			result.repeated_hashes += 1
		}
		if entry.versions.block != 0 && !walk_versions(walking, entry.versions) {
			walking.device = true
			one.failure = .Device
			return
		}
	case .Tree:
		walking.counts.trees += 1
		// A root with no block is an empty tree only with the check 0: the
		// commits of the service refuse any other check as damage.
		if entry.versions.block != 0 || entry.hash != {} || entry.pointer.block == 0 && (entry.size != 0 || entry.pointer.check != 0) {
			walking.broken = true
			one.failure = .Damaged
			return
		}
		if entry.pointer.block != 0 {
			entries := walk_one_tree(walking, entry.pointer, walking.nesting + 1)
			if walking.device {
				one.failure = .Device
				return
			}
			if walking.broken {
				one.failure = .Damaged
				return
			}
			if entries != entry.size {
				walking.entry_count_wrong = true
			}
		}
	case .None:
		// A leaf holds no entry of the kind None.
		walking.broken = true
		one.failure = .Damaged
	}
}

// walk_versions counts the version index of an object, its leaves and the
// block tree of each version. It gives false when the device reported an error.
walk_versions :: proc "contextless" (walking: ^Store_Walk, versions: format.Pointer) -> bool {
	state := walking.state
	reader := walking.reader
	result := walking.result
	index := walking.store_index
	switch single(state, reader, versions, index, result, &walking.named) {
	case .Device:
		return false
	case .Wrong:
		result.damaged_versions += 1 // The versions of the object are not known.
		walking.complete = false
		return true
	case .Good:
	}
	version_index := (^format.Version_Index)(raw_data(scratch_block(state, 0)))^
	// A count that the format does not permit is damage, as a wrong check:
	// the engine then never reads past the leaves of an index.
	if version_index.leaf_count > format.VERSION_INDEX_CAPACITY {
		result.wrong += 1
		wrong_block_set(state, versions.block)
		result.damaged_versions += 1
		walking.complete = false
		return true
	}
	for leaf_pointer in version_index.leaves[:version_index.leaf_count] {
		switch single(state, reader, leaf_pointer, index, result, &walking.named) {
		case .Device:
			return false
		case .Wrong:
			result.damaged_versions += 1
			walking.complete = false
			continue
		case .Good:
		}
		leaf := (^format.Version_Leaf)(raw_data(scratch_block(state, 0)))^
		// The engine writes no empty leaf, and no leaf of more entries than
		// it holds.
		if leaf.count == 0 || leaf.count > format.VERSION_LEAF_CAPACITY {
			result.wrong += 1
			wrong_block_set(state, leaf_pointer.block)
			result.damaged_versions += 1
			walking.complete = false
			continue
		}
		for &entry in leaf.entries[:leaf.count] {
			result.versions += 1
			state.store_versions[index] += 1
			outcome, _ := reference_state(state, reader, entry.root, entry.size, index, result, &walking.named)
			switch outcome {
			case .Device:
				return false
			case .Wrong:
				result.damaged_versions += 1
				walking.complete = false
			case .Good:
			}
		}
	}
	return true
}

// mount finds the root and walks it.
//
// Which root: the valid root with the highest generation, when it names no
// wrong block. If it names one, and the valid root before it names none,
// the root before it: the last commit was not whole on the disk (a device
// that did not keep what a Flush promised). If each valid root names a
// wrong block, the newest one, with its damage: a block that both name was
// changed after its commit, and no root is better.
//
// A disk with no commit (block 0 is zero bytes) needs a format: the caller
// writes the first root (the open writes nothing).
mount :: proc "contextless" (state: ^State, reader: ^Block_Reader, disk_blocks: u64) -> (result: Mount) {
	state.disk_size = min(disk_blocks, state.capacity)
	if state.disk_size < format.DISK_BLOCKS_MIN {
		// No memory was bound (state_bind), or the disk has no room for its
		// two roots.
		result.failed = true
		return result
	}
	numbers := [2]u64{0, 1}
	if !reader.read(reader, numbers[:], state.scratch[:2 * BLOCK_SIZE]) {
		result.failed = true
		return result
	}
	candidates: [2]format.Root
	zero := [2]bool{true, true}
	for index in 0 ..< 2 {
		bytes := scratch_block(state, index)
		for byte in bytes {
			if byte != 0 {
				zero[index] = false
			}
		}
		intrinsics.mem_copy_non_overlapping(&candidates[index], raw_data(bytes), BLOCK_SIZE)
	}
	// The first root goes to block 1, and the first commit to block 0. So
	// block 0 of zero bytes says that no commit followed the first root:
	// the disk holds no object. A first root with a wrong check is then a
	// format that a stop cut.
	if zero[0] && (zero[1] || !format.root_valid(&candidates[1], state.disk_size)) {
		result.needs_format = true
		result.first_cut = !zero[1]
		return result
	}
	// The valid roots, the newest first.
	order := [2]int{0, 1}
	if candidates[1].generation > candidates[0].generation {
		order = {1, 0}
	}
	first, walked := -1, -1
	for index in order {
		if !format.root_valid(&candidates[index], state.disk_size) {
			if format.root_valid(&candidates[index], disk_blocks) {
				// A whole root of a disk that the tables cannot hold: the open
				// refuses it rather than lose the blocks past them.
				result.larger_than_capacity = true
			} else if candidates[index].magic == format.ROOT_MAGIC {
				result.cut = candidates[index].generation
			}
			continue
		}
		if first < 0 {
			first = index
		}
		if !walk(state, reader, &candidates[index], &result) {
			result.failed = true
			return result
		}
		walked = index
		if result.wrong == 0 {
			break
		}
	}
	if first < 0 {
		result.failed = true
		return result
	}
	if result.wrong != 0 && walked != first {
		if !walk(state, reader, &candidates[first], &result) {
			result.failed = true
			return result
		}
		walked = first
	}
	result.older = walked != first
	state.root = candidates[walked]
	state.root_place = u64(walked)
	result.generation = state.root.generation
	return result
}

// versions_read reads the version entries of an object, the oldest first,
// checked, into `into`. ok is false when the index or a leaf is wrong.
versions_read :: proc "contextless" (state: ^State, reader: ^Block_Reader, versions: format.Pointer, into: []format.Version_Entry) -> (count: int, ok: bool) {
	if versions.block == 0 {
		return 0, true
	}
	if _, outcome := read_checked(state, reader, {versions}, 0); outcome != .Good {
		return 0, false
	}
	version_index := (^format.Version_Index)(raw_data(scratch_block(state, 0)))^
	for leaf_pointer in version_index.leaves[:min(version_index.leaf_count, format.VERSION_INDEX_CAPACITY)] {
		if _, outcome := read_checked(state, reader, {leaf_pointer}, 0); outcome != .Good {
			return count, false
		}
		leaf := (^format.Version_Leaf)(raw_data(scratch_block(state, 0)))
		for entry in leaf.entries[:min(leaf.count, format.VERSION_LEAF_CAPACITY)] {
			if count < len(into) {
				into[count] = entry
			}
			count += 1
		}
	}
	return count, true
}

// version_leaves_full says if an object can take no more version with no
// compaction: its index has its last leaf, and that leaf is full.
version_leaves_full :: proc "contextless" (leaf_count: int, last_leaf_count: u64) -> bool {
	return leaf_count >= format.VERSION_INDEX_CAPACITY && last_leaf_count >= format.VERSION_LEAF_CAPACITY
}

// version_leaves_compact moves the entries of leaves to the first leaves,
// each one full but the last, in their order (the oldest first). The
// retention rule leaves a few entries in each leaf, so with no compaction
// the index fills with nearly empty leaves. It gives the count of the
// leaves that hold an entry; the leaves after them have no entry.
version_leaves_compact :: proc "contextless" (leaves: []format.Version_Leaf) -> (used: int) {
	to_leaf, to_place: int
	for from_leaf in 0 ..< len(leaves) {
		count := int(min(leaves[from_leaf].count, format.VERSION_LEAF_CAPACITY))
		for from_place in 0 ..< count {
			entry := leaves[from_leaf].entries[from_place]
			leaves[to_leaf].entries[to_place] = entry
			to_place += 1
			if to_place == format.VERSION_LEAF_CAPACITY {
				leaves[to_leaf].count = format.VERSION_LEAF_CAPACITY
				to_leaf += 1
				to_place = 0
			}
		}
	}
	// The writes above never pass the place that they read: to_leaf and
	// to_place stay at or before from_leaf and from_place.
	used = to_leaf
	if to_place != 0 {
		leaves[to_leaf].count = u64(to_place)
		for place in to_place ..< format.VERSION_LEAF_CAPACITY {
			leaves[to_leaf].entries[place] = {}
		}
		used += 1
	}
	for index in used ..< len(leaves) {
		leaves[index].count = 0
		leaves[index].entries = {}
	}
	return used
}
