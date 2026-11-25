package storage_service

import "base:intrinsics"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/isolated"
import op "modus:contract/operation"
import "modus:contract/storage_status"
import format "modus:contract/store"
import "modus:contract/value_kinds"
import "internal:storage/block_counts"
import "internal:storage/share_quota"
import block_tree "internal:storage/storage_object"
import "modus:system"

// Ranges (docs/STORAGE.md, "Ranges"): a connection writes ranges of an
// object and changes its size as pending changes, then commits them in one
// commit. A pending change is a copy of a block of data in the service: it
// is not on the disk, and no hash is computed for it. The commit puts the
// pending blocks in the block tree of the object (src/library/internal/storage/storage_object),
// computes the values of those blocks and of the nodes above them, and the
// hash on the path of the last block: never at each write, and never over
// the whole object. A loss of power before the commit loses the pending
// changes, and nothing else: the disk has the last commit.

// The pending changes of one connection are its pending pool: memory of
// the service that it takes at its first change, sized to what the
// connection changes and never past the limit of blocks of its store, and
// that it gives back at its commit, its drop or its end. A connection that
// writes a large range takes no room of another connection: each pool has
// its own memory and its own bound (src/md/data/storage_capacity.md,
// "Pending changes").

// The pools of the service: one for each connection that has pending
// changes. A pool holds no memory while it has none.
PENDING_POOL_CAPACITY :: isolated.SERVICE_CONNECTION_CAPACITY + SHARE_CAPACITY

// The first slots of the index of the blocks of a pool: it doubles when
// half of them are in use.
PENDING_SLOTS_FIRST :: 64

// The arenas of one pool: the first reserves POOL_ARENA_FIRST_PAGES
// (one page of its frame list), each next one twice the one before up to
// one memory object, so 40 arenas hold more than any budget.
POOL_ARENA_CAPACITY :: 40
POOL_ARENA_FIRST_PAGES :: 512

// A point of the memory of a pool: pool_rewind gives back what came after.
Pool_Mark :: struct {
	arena_count: int,
	used_bytes:  u64,
}

// The pending changes of one object on one connection.
Pending_Object :: struct {
	pool:            ^Pending_Pool, // The pool of the connection.
	next:            ^Pending_Object, // The next object of the pool, or of its free list.
	first_block:     ^Pending_Block, // The pending blocks of the object.
	store:           system.Name,
	depth:           int,
	path:            [NESTING_LIMIT]Entry_Name,
	name:            Entry_Name,
	base_generation: u64, // The generation of the entry at the first change; 0: no entry.
	size:            u64, // The size with the pending changes.
	cut:             u64, // The least size since the first change: each byte of the state before at or past it reads as zero.
	blocks:          int, // Its pending blocks.
}

// A pending block: the 4096 bytes of the block `index` of an object after
// the pending changes.
Pending_Block :: struct {
	bytes:  Block,
	index:  u64,
	object: ^Pending_Object, // nil: the block is on the free list of its pool.
	next:   ^Pending_Block, // The next block of its object, or of the free list.
}

// The pending changes of one connection.
Pending_Pool :: struct {
	holder:       system.Handle, // The call ring of the connection. 0: the pool is free.
	// Its memory: objects, blocks, the index, the tables of a commit. Each
	// arena reserves twice the one before, up to one memory object: a
	// pool past 1 GiB takes several.
	arenas:       [POOL_ARENA_CAPACITY]system.Arena,
	arena_count:  int,
	limit:        u64, // The most pending blocks: the limit of blocks of its store at the first change.
	blocks:       int, // The pending blocks in use.
	objects:      ^Pending_Object, // The pending objects.
	free_objects: ^Pending_Object,
	free_blocks:  ^Pending_Block,
	slots:        []^Pending_Block, // The index of the blocks by their object and their place: linear probing.
	slots_used:   int,
}
pending_pools: [PENDING_POOL_CAPACITY]Pending_Pool

// What one commit did on its object: the row of the export commit. The
// service writes it on the log too.
Commit_Measure :: struct {
	generation:     i64,
	object_blocks:  i64, // The blocks of the object after the commit, holes included: N.
	held_blocks:    i64, // The blocks that the object holds after the commit: its object nodes and its blocks of data.
	changed:        i64, // The blocks of data that the commit changed: K.
	hashed_blocks:  i64, // The blocks of data whose bytes the commit hashed: the changed blocks and the last block of the hash.
	hashed_nodes:   i64, // The object nodes whose value the commit computed.
	object_written: i64, // The blocks of the block tree that the commit wrote: data and object nodes.
	written:        i64, // Each block that the commit wrote: with the nodes of the trees, the versions, the store block and the root.
	milliseconds:   i64,
}

// pool_of gives the pool of a connection, or nil.
pool_of :: proc "contextless" (holder: system.Handle) -> ^Pending_Pool {
	if holder == 0 {
		return nil
	}
	for &pool in pending_pools {
		if pool.holder == holder {
			return &pool
		}
	}
	return nil
}

// pool_end gives back the memory of a pool: its objects and blocks are gone.
pool_end :: proc "contextless" (pool: ^Pending_Pool) {
	if pool.holder == 0 {
		return
	}
	for &arena in pool.arenas[:pool.arena_count] {
		system.arena_end(&arena)
	}
	pool^ = {}
}

// pool_take gives the pool of a connection, and makes it at its first
// change, with no memory yet: its first push makes its first arena. nil
// with the error record when the service has no free pool.
pool_take :: proc "contextless" (holder: system.Handle, limit: u64, error: ^errors.Error_Record) -> (pool: ^Pending_Pool, outcome: call_outcome.Call_Outcome) {
	if pool = pool_of(holder); pool != nil {
		return pool, .Succeeded
	}
	for attempt in 0 ..< 2 {
		for &free in pending_pools {
			if free.holder != 0 {
				continue
			}
			free = {holder = holder, limit = limit}
			return &free, .Succeeded
		}
		if attempt == 0 {
			pending_sweep()
		}
	}
	// The pools are shared by the connections, and one frees when its
	// connection commits or ends.
	return nil, refuse(error, .Callee_Busy, .Full, .Pending, 0, 0, PENDING_POOL_CAPACITY)
}

// pool_push gives `size` bytes of the arena of a pool, or nil with the
// error record that the arena or the kernel wrote: the memory of the
// service holds no more.
pool_push :: proc "contextless" (pool: ^Pending_Pool, size: int, alignment: int, error: ^errors.Error_Record) -> rawptr {
	if pool.arena_count > 0 {
		last := &pool.arenas[pool.arena_count - 1]
		// A push larger than the whole reservation of the last arena gets
		// Argument_Refused (Too_Long) from arena_push, not Full: open a
		// larger arena below instead of failing the push.
		if u64(size) <= last.reserved_pages * system.PAGE_SIZE {
			push_error: errors.Error_Record
			address, status := system.arena_push(last, u64(size), u64(alignment), &push_error)
			if status == .Succeeded {
				return address
			}
			if status != .Budget_Or_Capacity_Exhausted || push_error.kind != i64(errors.Kind.Full) {
				if error != nil {
					error^ = push_error
				}
				return nil // The budget refused the pages.
			}
		}
	}
	// The reservation of the last arena is full: one more, twice as large,
	// and large enough for the push.
	if pool.arena_count == POOL_ARENA_CAPACITY {
		_ = refuse(error, .Budget_Or_Capacity_Exhausted, .Full, .Pending, 0, 0, POOL_ARENA_CAPACITY)
		return nil
	}
	pages := u64(POOL_ARENA_FIRST_PAGES)
	if pool.arena_count > 0 {
		pages = min(2 * pool.arenas[pool.arena_count - 1].reserved_pages, op.MEMORY_PAGE_LIMIT)
	}
	wanted := (u64(size) + u64(alignment) + system.PAGE_SIZE - 1) / system.PAGE_SIZE
	if wanted > op.MEMORY_PAGE_LIMIT {
		_ = refuse(error, .Argument_Refused, .Too_Long, .Bytes, 0, i64(size), i64(op.MEMORY_PAGE_LIMIT * system.PAGE_SIZE))
		return nil
	}
	pages = system.arena_reservation_pages(max(pages, wanted))
	// A refused reservation: the kernel wrote its record (Budget, unit
	// Pages).
	arena, status := system.arena_create(pages, 0, error)
	if status != .Succeeded {
		return nil
	}
	pool.arenas[pool.arena_count] = arena
	pool.arena_count += 1
	address, pushed := system.arena_push(&pool.arenas[pool.arena_count - 1], u64(size), u64(alignment), error)
	if pushed != .Succeeded {
		return nil
	}
	return address
}

// pool_mark gives the point of the memory of a pool now.
pool_mark :: proc "contextless" (pool: ^Pending_Pool) -> Pool_Mark {
	if pool.arena_count == 0 {
		return {}
	}
	return {arena_count = pool.arena_count, used_bytes = pool.arenas[pool.arena_count - 1].used_bytes}
}

// pool_rewind gives back the memory of a pool after a mark: the arenas
// made after it end, and the last one keeps its pages for the next pushes.
pool_rewind :: proc "contextless" (pool: ^Pending_Pool, mark: Pool_Mark) {
	for pool.arena_count > max(mark.arena_count, 1) {
		pool.arena_count -= 1
		system.arena_end(&pool.arenas[pool.arena_count])
	}
	if pool.arena_count == 0 {
		return
	}
	if mark.arena_count == 0 {
		pool.arenas[0].used_bytes = 0
	} else {
		pool.arenas[pool.arena_count - 1].used_bytes = mark.used_bytes
	}
}

// pool_commit_tables gives the plan of the commit of a pending object
// tables of the room of its changes, in the memory of its pool, when the
// fixed tables are too small. The plan was reset just before. false with
// the error record when the memory refuses.
pool_commit_tables :: proc "contextless" (pending: ^Pending_Object, size_before: u64, error: ^errors.Error_Record) -> bool {
	blocks := max(blocks_of(pending.size), blocks_of(size_before))
	room := plan_room_of_changes(u64(pending.blocks), blocks)
	if plan_room_fits(room) {
		return true
	}
	pool := pending.pool
	writes := pool_push(pool, room.writes * size_of(Write), align_of(Write), error)
	taken := pool_push(pool, room.writes * size_of(u64), align_of(u64), error) if writes != nil else nil
	delta_blocks := pool_push(pool, room.delta * size_of(u64), align_of(u64), error) if taken != nil else nil
	delta_values := pool_push(pool, room.delta * size_of(i32), align_of(i32), error) if delta_blocks != nil else nil
	delta_places := pool_push(pool, room.delta * size_of(u32), align_of(u32), error) if delta_values != nil else nil
	page_list := pool_push(pool, room.slot_pages * size_of(^block_tree.Slot_Page), align_of(^block_tree.Slot_Page), error) if delta_places != nil else nil
	// The pages of the count tree of the commit, their index, and the table
	// of the blocks outside the stores.
	staged_slot_count := 2
	for staged_slot_count < 2 * room.count_pages {
		staged_slot_count *= 2
	}
	staging := pool_push(pool, room.count_pages * size_of(block_counts.Frame), align_of(block_counts.Frame), error) if page_list != nil else nil
	staged_slots := pool_push(pool, staged_slot_count * size_of(i32), align_of(i32), error) if staging != nil else nil
	outside_blocks := pool_push(pool, room.outside * size_of(u64), align_of(u64), error) if staged_slots != nil else nil
	outside_owners := pool_push(pool, room.outside * size_of(u16), align_of(u16), error) if outside_blocks != nil else nil
	outside_places := pool_push(pool, room.outside / 2 * size_of(u32), align_of(u32), error) if outside_owners != nil else nil
	if outside_places == nil {
		return false
	}
	// The pages of the slots one at a time: no push of them all in one
	// piece.
	pages := ([^]^block_tree.Slot_Page)(page_list)[:room.slot_pages]
	for &page in pages {
		page = (^block_tree.Slot_Page)(pool_push(pool, size_of(block_tree.Slot_Page), align_of(block_tree.Slot_Page), error))
		if page == nil {
			return false
		}
	}
	// A rewind gives back pages that hold the bytes of an earlier commit:
	// the counts start from zero.
	intrinsics.mem_zero(delta_blocks, room.delta * size_of(u64))
	intrinsics.mem_zero(delta_values, room.delta * size_of(i32))
	intrinsics.mem_zero(outside_blocks, room.outside * size_of(u64))
	plan_tables_bind(([^]Write)(writes)[:room.writes], ([^]u64)(taken)[:room.writes], ([^]u64)(delta_blocks)[:room.delta], ([^]i32)(delta_values)[:room.delta], ([^]u32)(delta_places)[:room.delta], pages, ([^]block_counts.Frame)(staging)[:room.count_pages], ([^]i32)(staged_slots)[:staged_slot_count], ([^]u64)(outside_blocks)[:room.outside], ([^]u16)(outside_owners)[:room.outside], ([^]u32)(outside_places)[:room.outside / 2])
	return true
}

// slot_home gives the first slot of a block of an object in the index.
@(private = "file")
slot_home :: #force_inline proc "contextless" (pool: ^Pending_Pool, object: ^Pending_Object, index: u64) -> int {
	key := u64(uintptr(object)) ~ (index * 0x9E37_79B9_7F4A_7C15)
	key ~= key >> 29
	return int(key & u64(len(pool.slots) - 1))
}

// pending_block_find gives the pending block `index` of a pending object,
// or nil.
pending_block_find :: proc "contextless" (pending: ^Pending_Object, index: u64) -> ^Pending_Block {
	pool := pending.pool
	if pending.blocks == 0 || len(pool.slots) == 0 {
		return nil
	}
	at := slot_home(pool, pending, index)
	for _ in 0 ..< len(pool.slots) {
		block := pool.slots[at]
		if block == nil {
			return nil
		}
		if block.object == pending && block.index == index {
			return block
		}
		at = (at + 1) & (len(pool.slots) - 1)
	}
	return nil
}

// slots_insert puts a block in the index, which has a free slot.
@(private = "file")
slots_insert :: proc "contextless" (pool: ^Pending_Pool, block: ^Pending_Block) {
	at := slot_home(pool, block.object, block.index)
	for pool.slots[at] != nil {
		at = (at + 1) & (len(pool.slots) - 1)
	}
	pool.slots[at] = block
	pool.slots_used += 1
}

// slots_remove takes a block out of the index: each later block of its run
// whose first slot is not after the hole moves into it.
@(private = "file")
slots_remove :: proc "contextless" (pool: ^Pending_Pool, block: ^Pending_Block) {
	mask := len(pool.slots) - 1
	hole := slot_home(pool, block.object, block.index)
	for pool.slots[hole] != block {
		hole = (hole + 1) & mask
	}
	pool.slots[hole] = nil
	pool.slots_used -= 1
	next := hole
	for {
		next = (next + 1) & mask
		moved := pool.slots[next]
		if moved == nil {
			return
		}
		home := slot_home(pool, moved.object, moved.index)
		if (hole - home) & mask < (next - home) & mask {
			pool.slots[hole] = moved
			pool.slots[next] = nil
			hole = next
		}
	}
}

// slots_grow doubles the index when half of it is in use. The old slots
// stay in the arena until the pool ends.
@(private = "file")
slots_grow :: proc "contextless" (pool: ^Pending_Pool, error: ^errors.Error_Record) -> bool {
	if len(pool.slots) != 0 && 2 * (pool.slots_used + 1) <= len(pool.slots) {
		return true
	}
	count := max(PENDING_SLOTS_FIRST, 2 * len(pool.slots))
	address := pool_push(pool, count * size_of(^Pending_Block), align_of(^Pending_Block), error)
	if address == nil {
		return false
	}
	old := pool.slots
	pool.slots = ([^]^Pending_Block)(address)[:count]
	intrinsics.mem_zero(address, count * size_of(^Pending_Block))
	pool.slots_used = 0
	for block in old {
		if block != nil {
			slots_insert(pool, block)
		}
	}
	return true
}

// pending_find gives the pending object of a connection for an object
// under a path, or nil.
pending_find :: proc "contextless" (holder: system.Handle, path: ^Path, name: Entry_Name) -> ^Pending_Object {
	pool := pool_of(holder)
	if pool == nil {
		return nil
	}
	for pending := pool.objects; pending != nil; pending = pending.next {
		if pending.name != name || pending.depth != path.depth || system.name_of(pending.store[:]) != path.store.name {
			continue
		}
		same := true
		for step, depth in path.names[:path.depth] {
			same &&= pending.path[depth] == step
		}
		if same {
			return pending
		}
	}
	return nil
}

// pending_block_free gives a block back to the free list of its pool.
@(private = "file")
pending_block_free :: proc "contextless" (block: ^Pending_Block) {
	pending := block.object
	pool := pending.pool
	slots_remove(pool, block)
	block.object = nil
	block.next = pool.free_blocks
	pool.free_blocks = block
	pending.blocks -= 1
	pool.blocks -= 1
}

// pending_drop frees a pending object and its blocks. The pool ends with
// its last object: its memory goes back to the budget of the service.
pending_drop :: proc "contextless" (pending: ^Pending_Object) {
	pool := pending.pool
	for block := pending.first_block; block != nil; {
		next := block.next
		pending_block_free(block)
		block = next
	}
	pending.first_block = nil
	link := &pool.objects
	for link^ != nil && link^ != pending {
		link = &link^.next
	}
	if link^ == pending {
		link^ = pending.next
	}
	pending.next = pool.free_objects
	pool.free_objects = pending
	if pool.objects == nil {
		pool_end(pool)
	}
}

// pending_sweep drops the pending changes of connections that ended.
pending_sweep :: proc "contextless" () {
	for &pool in pending_pools {
		if pool.holder == 0 {
			continue
		}
		if _, _, found := connection_store(pool.holder, 0); !found {
			pool_end(&pool)
		}
	}
}

// pending_drop_of drops the pending changes of one connection.
pending_drop_of :: proc "contextless" (holder: system.Handle) {
	if pool := pool_of(holder); pool != nil {
		pool_end(pool)
	}
}

// pending_drop_slot volatile-zeroes all committed arena pages and drops every
// pending pool belonging to principal `slot` (covering live objects, free
// object lists, free block lists, and rewound arena bytes).
pending_drop_slot :: proc "contextless" (slot: u64) {
	for &pool in pending_pools {
		if pool.holder == 0 {
			continue
		}
		owns := false
		if store_of, _, found := connection_store(pool.holder, 0); found && owned_slot(store_of.name) == slot {
			owns = true
		}
		if !owns {
			for pending := pool.objects; pending != nil; pending = pending.next {
				if owned_slot(system.name_of(pending.store[:])) == slot {
					owns = true
					break
				}
			}
		}
		if !owns {
			for pending := pool.free_objects; pending != nil; pending = pending.next {
				if owned_slot(system.name_of(pending.store[:])) == slot {
					owns = true
					break
				}
			}
		}
		if !owns {
			continue
		}
		for &arena in pool.arenas[:pool.arena_count] {
			if arena.base != nil && arena.committed_pages > 0 {
				intrinsics.mem_zero_volatile(arena.base, int(arena.committed_pages * system.PAGE_SIZE))
			}
		}
		pool_end(&pool)
	}
}

// pending_take gives a new pending object of a connection.
pending_take :: proc "contextless" (holder: system.Handle, limit: u64, path: ^Path, name: Entry_Name, base_generation: u64, size: u64, error: ^errors.Error_Record) -> (pending: ^Pending_Object, outcome: call_outcome.Call_Outcome) {
	pool, taken := pool_take(holder, limit, error)
	if pool == nil {
		return nil, taken
	}
	if pool.free_objects != nil {
		pending = pool.free_objects
		pool.free_objects = pending.next
	} else {
		address := pool_push(pool, size_of(Pending_Object), align_of(Pending_Object), error)
		if address == nil {
			if pool.objects == nil {
				pool_end(pool)
			}
			// pool_push wrote the record of the memory that it did not get.
			return nil, .Budget_Or_Capacity_Exhausted
		}
		pending = (^Pending_Object)(address)
	}
	pending^ = {pool = pool, depth = path.depth, name = name, base_generation = base_generation, size = size, cut = size}
	pending.store = system.name_unpack(system.name_pack(path.store.name))
	copy(pending.path[:], path.names[:path.depth])
	pending.next = pool.objects
	pool.objects = pending
	return pending, .Succeeded
}

// pending_changes gives the pending blocks of a pending object as the
// changes of a commit, in the order of their places, in the arena of its
// pool. nil with the error record when the budget refuses.
pending_changes :: proc "contextless" (pending: ^Pending_Object, error: ^errors.Error_Record) -> (changes: []block_tree.Change, ok: bool) {
	if pending.blocks == 0 {
		return nil, true
	}
	address := pool_push(pending.pool, pending.blocks * size_of(block_tree.Change), align_of(block_tree.Change), error)
	if address == nil {
		return nil, false
	}
	changes = ([^]block_tree.Change)(address)[:pending.blocks]
	count := 0
	for block := pending.first_block; block != nil; block = block.next {
		changes[count] = {index = block.index, bytes = &block.bytes}
		count += 1
	}
	changes_sort(changes[:count])
	return changes[:count], true
}

// changes_sort puts changes in the order of their places, with no memory
// more: a heap sort, whose time does not depend on the order of the writes.
changes_sort :: proc "contextless" (changes: []block_tree.Change) {
	sift :: proc "contextless" (changes: []block_tree.Change, start: int, end: int) {
		at := start
		for {
			child := 2 * at + 1
			if child >= end {
				return
			}
			if child + 1 < end && changes[child + 1].index > changes[child].index {
				child += 1
			}
			if changes[at].index >= changes[child].index {
				return
			}
			changes[at], changes[child] = changes[child], changes[at]
			at = child
		}
	}
	count := len(changes)
	for start := count / 2 - 1; start >= 0; start -= 1 {
		sift(changes, start, count)
	}
	for end := count - 1; end > 0; end -= 1 {
		changes[0], changes[end] = changes[end], changes[0]
		sift(changes, 0, end)
	}
}

// The object of a call on ranges: its entry as the last commit gives it,
// and the pending changes of the caller.
Ranged :: struct {
	named:       Named,
	store_index: int, // -1 when the store does not exist yet.
	state:       State_Of_Object, // The state of the last commit: no root and size 0 for a name with no entry.
	exists:      bool,
	pending:     ^Pending_Object,
}

// ranged_of finds the object of a call on ranges and writes it into ranged.
// A name with no entry is an object of no byte, when the caller has pending
// changes for it or makes a change. Written through a pointer so Ranged
// (over 17 KiB) is never copied or scalarized by value.
ranged_of :: proc "contextless" (place: i64, name: string, ranged: ^Ranged, error: ^errors.Error_Record, change: bool) -> call_outcome.Call_Outcome {
	ranged.store_index = -1
	ranged.state = {}
	ranged.exists = false
	ranged.pending = nil
	if result := named_of(place, name, &ranged.named, error, 1, change); result != .Succeeded {
		return result
	}
	if ranged.named.caller.connection != nil {
		ranged.pending = pending_find(ranged.named.caller.connection.ring_memory, &ranged.named.path, ranged.named.name.key)
	}
	store_index, value, located := object_locate(ranged.named.path.store.name, path_names(&ranged.named.path), ranged.named.name, error, 2)
	if located == .Succeeded {
		ranged.store_index = store_index
		ranged.state = current_state(&value)
		ranged.exists = true
		return .Succeeded
	}
	if located == .Nothing_Has_That_Name && (change || ranged.pending != nil) {
		// A name that is a tree is refused: the lookup of the name as an
		// object gives Absent for it too, so look at its entry.
		if found_store := store_find(ranged.named.path.store.name); found_store >= 0 {
			ranged.store_index = found_store
			if entry, outcome := entry_of(found_store, path_names(&ranged.named.path), ranged.named.name.key); outcome == .Found && entry.kind != u64(format.Entry_Kind.Object) {
				return refuse(error, .Nothing_Has_That_Name, .Absent, .Objects, 2)
			} else if outcome == .Wrong || outcome == .Device {
				return lookup_refusal(outcome, error, 2)
			} else if outcome == .Absent && len(path_names(&ranged.named.path)) != 0 {
				// The tree of the place: it must exist for a new object.
				if _, tree_outcome := tree_of(found_store, path_names(&ranged.named.path)); tree_outcome == .Absent {
					return refuse(error, .Nothing_Has_That_Name, .Absent, .Places, 1)
				} else if tree_outcome != .Found {
					return lookup_refusal(tree_outcome, error, 1)
				}
			}
		}
		return .Succeeded
	}
	return located
}

// ranged_size gives the size of the object as the caller sees it.
ranged_size :: proc "contextless" (ranged: ^Ranged) -> u64 {
	return ranged.pending != nil ? ranged.pending.size : ranged.state.size
}

// ranged_read reads bytes from `offset` as the caller sees them: its
// pending blocks, the bytes of the last commit before the cut, and zero
// bytes. It gives the count of bytes, or the outcome of a refused read.
ranged_read :: proc "contextless" (ranged: ^Ranged, offset: u64, result: []u8, error: ^errors.Error_Record) -> (value: i64, outcome: call_outcome.Call_Outcome) {
	size := ranged_size(ranged)
	if offset >= size {
		return 0, .Succeeded
	}
	count := min(u64(len(result)), size - offset)
	pending := ranged.pending
	if pending == nil {
		return state_read(ranged.store_index, ranged.state, offset, result[:count], error, 2)
	}
	for at := offset; at < offset + count; {
		index := at / BLOCK_SIZE
		inside := at % BLOCK_SIZE
		part := min(BLOCK_SIZE - inside, offset + count - at)
		into := result[at - offset:][:part]
		if block := pending_block_find(pending, index); block != nil {
			copy(into, block.bytes[inside:][:part])
		} else {
			if _, read := base_read(ranged, at, into, error); read != .Succeeded {
				return 0, read
			}
		}
		at += part
	}
	return i64(count), .Succeeded
}

// base_read reads bytes of the last commit as the pending changes leave
// them: zero bytes at and past the cut.
base_read :: proc "contextless" (ranged: ^Ranged, at: u64, into: []u8, error: ^errors.Error_Record) -> (value: i64, outcome: call_outcome.Call_Outcome) {
	cut := ranged.pending != nil ? ranged.pending.cut : ranged.state.size
	intrinsics.mem_zero(raw_data(into), len(into))
	if at >= cut || !ranged.exists {
		return 0, .Succeeded
	}
	kept := min(u64(len(into)), cut - at)
	return state_read(ranged.store_index, ranged.state, at, into[:kept], error, 2)
}

// pending_block_take gives the pending block `index` of a pending object:
// at its first change, a copy of the block as the caller sees it. A pool
// holds at most the limit of blocks of its store: a change that passes it
// could never commit.
pending_block_take :: proc "contextless" (ranged: ^Ranged, index: u64, error: ^errors.Error_Record) -> (block: ^Pending_Block, result: call_outcome.Call_Outcome) {
	pending := ranged.pending
	if block = pending_block_find(pending, index); block != nil {
		return block, .Succeeded
	}
	pool := pending.pool
	if u64(pool.blocks) >= pool.limit {
		return nil, refuse(error, .Budget_Or_Capacity_Exhausted, .Over_Limit, .Pending, 0, i64(pool.blocks) + 1, i64(pool.limit))
	}
	if !slots_grow(pool, error) {
		return nil, .Budget_Or_Capacity_Exhausted
	}
	if pool.free_blocks != nil {
		block = pool.free_blocks
		pool.free_blocks = block.next
	} else {
		address := pool_push(pool, size_of(Pending_Block), align_of(Pending_Block), error)
		if address == nil {
			// pool_push wrote the record of the memory that it did not get.
			return nil, .Budget_Or_Capacity_Exhausted
		}
		block = (^Pending_Block)(address)
	}
	if _, read := base_read(ranged, index * BLOCK_SIZE, block.bytes[:], error); read != .Succeeded {
		block.object = nil
		block.next = pool.free_blocks
		pool.free_blocks = block
		return nil, read
	}
	block.index = index
	block.object = pending
	block.next = pending.first_block
	pending.first_block = block
	slots_insert(pool, block)
	pending.blocks += 1
	pool.blocks += 1
	return block, .Succeeded
}

// pending_blocks_cut frees the pending blocks of an object at or past the
// block `keep`.
pending_blocks_cut :: proc "contextless" (pending: ^Pending_Object, keep: u64) {
	link := &pending.first_block
	for link^ != nil {
		block := link^
		if block.index >= keep {
			link^ = block.next
			pending_block_free(block)
		} else {
			link = &block.next
		}
	}
}

// ranged_pending gives the pending object of the caller, and makes it at
// the first change.
ranged_pending :: proc "contextless" (ranged: ^Ranged, error: ^errors.Error_Record) -> (value: i64, outcome: call_outcome.Call_Outcome) {
	if ranged.pending != nil {
		return 0, .Succeeded
	}
	base: u64
	if ranged.exists {
		base = ranged.state.generation
	}
	pending_limit := share_quota.effective_pending_limit(ranged.named.caller.store.share_limit, ranged.named.caller.store.limit)
	pending, result := pending_take(ranged.named.caller.connection.ring_memory, pending_limit, &ranged.named.path, ranged.named.name.key, base, ranged.state.size, error)
	if pending == nil {
		return 0, result
	}
	ranged.pending = pending
	return 0, .Succeeded
}

// read_range copies the bytes of the object `name` under a place from `offset` into result, up to its end: as this connection sees it, with its pending changes. A hole reads as zero bytes. The result is the count of bytes (0 at the end), or a failure with its call outcome and an error record.
//
// The error kinds: those of read; Out_Of_Range (offset is past the end: limit the size).
@(export, link_name = "read_range")
read_range :: proc "c" (place: i64, name: ^string, offset: i64, result: ^[]u8, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	ranged: Ranged
	if refused := ranged_of(place, name^, &ranged, error, false); refused != .Succeeded {
		return refused, 0
	}
	size := ranged_size(&ranged)
	if offset < 0 || u64(offset) > size {
		return call_outcome.fail(error, .Argument_Refused, .Out_Of_Range, .Bytes, 3, offset, i64(size))
	}
	value, outcome = ranged_read(&ranged, u64(offset), result^, error)
	return
}

// write_range writes the bytes of data at `offset` of the object `name` under a place, as a pending change of this connection: no commit, and no hash. A read of this connection sees it at once; another connection sees the object as its last commit gives it. The object grows when the range passes its end; a new name is a new object at the commit. A loss of power before commit loses the pending changes. The result is the size of the object with the pending changes, or a failure with its call outcome and an error record.
//
// The error kinds: No_Grant (Grant_Or_Right_Missing; Grant_Or_Right_Missing, unit Changes: the connection reads only); Absent (Nothing_Has_That_Name: the place; Nothing_Has_That_Name, unit Objects: the name is a tree); the errors of a name (Argument_Refused); Bad_Value (Argument_Refused: offset is negative); Too_Long (Argument_Refused: the object would pass 4 TiB); Over_Limit (Budget_Or_Capacity_Exhausted, unit Pending: the pending blocks of the connection would pass the limit of blocks of its store: commit first); Full (Budget_Or_Capacity_Exhausted, kind Budget, unit Pages: the memory of the service holds no more pending blocks: commit first); Damaged (Data_Damaged: a block that the range changes in part has a wrong check); Device (Callee_Unavailable).
@(export, link_name = "write_range")
write_range :: proc "c" (place: i64, name: ^string, offset: i64, data: ^string, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	ranged: Ranged
	if refused := ranged_of(place, name^, &ranged, error, true); refused != .Succeeded {
		return refused, 0
	}
	count := u64(len(data^))
	if offset < 0 {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .Bytes, 3, offset)
	}
	if u64(offset) > format.OBJECT_SIZE_LIMIT || count > format.OBJECT_SIZE_LIMIT - u64(offset) {
		return call_outcome.fail(error, .Argument_Refused, .Too_Long, .Bytes, 3, offset + i64(count), i64(format.OBJECT_SIZE_LIMIT))
	}
	if _, pending_outcome := ranged_pending(&ranged, error); pending_outcome != .Succeeded {
		return pending_outcome, 0
	}
	pending := ranged.pending
	bytes := transmute([]u8)data^
	end := u64(offset) + count
	for at := u64(offset); at < end; {
		index := at / BLOCK_SIZE
		inside := at % BLOCK_SIZE
		part := min(BLOCK_SIZE - inside, end - at)
		block, taken := pending_block_take(&ranged, index, error)
		if taken != .Succeeded {
			// The blocks of the range before it stay pending: a change
			// that this connection sees at its next read.
			return call_outcome.outcome_passed_on(taken, at > u64(offset)), 0
		}
		copy(block.bytes[inside:][:part], bytes[at - u64(offset):][:part])
		at += part
		pending.size = max(pending.size, at)
	}
	return .Succeeded, i64(pending.size)
}

// set_size makes the size of the object `name` under a place `size` bytes, as a pending change of this connection: a cut drops the bytes past it, an extension adds zero bytes, which hold no block. The result is the size, or a failure with its call outcome and an error record.
//
// The error kinds: those of write_range.
@(export, link_name = "set_size")
set_size :: proc "c" (place: i64, name: ^string, size: value_kinds.Size_In_Bytes, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	ranged: Ranged
	if refused := ranged_of(place, name^, &ranged, error, true); refused != .Succeeded {
		return refused, 0
	}
	if size < 0 {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .Bytes, 3, i64(size))
	}
	if u64(size) > format.OBJECT_SIZE_LIMIT {
		return call_outcome.fail(error, .Argument_Refused, .Too_Long, .Bytes, 3, i64(size), i64(format.OBJECT_SIZE_LIMIT))
	}
	if _, pending_outcome := ranged_pending(&ranged, error); pending_outcome != .Succeeded {
		return pending_outcome, 0
	}
	pending := ranged.pending
	new_size := u64(size)
	if new_size < pending.size {
		// The block that holds the new end keeps its bytes before it, and
		// zero bytes after it; the blocks after it are dropped.
		blocks_before := pending.blocks
		pending_blocks_cut(pending, blocks_of(new_size))
		dropped_blocks := pending.blocks != blocks_before
		if inside := new_size % BLOCK_SIZE; inside != 0 {
			block, taken := pending_block_take(&ranged, new_size / BLOCK_SIZE, error)
			if taken != .Succeeded {
				// Only a partial change when the cut above dropped pending blocks.
				return call_outcome.outcome_passed_on(taken, dropped_blocks), 0
			}
			intrinsics.mem_zero(&block.bytes[inside], BLOCK_SIZE - int(inside))
		}
		pending.cut = min(pending.cut, new_size)
	}
	pending.size = new_size
	return .Succeeded, i64(size)
}

// commit puts the pending changes of this connection on the object `name` under a place in one commit, on the disk when the call returns. The state before becomes a version. The commit hashes the blocks that changed and the object nodes above them, and the path of the last block: never the whole object. The result is one row: the generation, and the measure of the commit (the blocks of the object, the blocks changed, hashed and written); or a failure with its call outcome and an error record.
//
// The error kinds: those of write; Absent (unit Pending: the object has no pending change on this connection; found 1: another change of the object came first since the first pending change, and the pending changes are dropped); Damaged (Data_Damaged: the state before is damaged; the pending changes stay on the connection).
@(export, link_name = "commit")
commit :: proc "c" (place: i64, name: ^string, result: ^[]Commit_Measure, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	ranged: Ranged
	if refused := ranged_of(place, name^, &ranged, error, true); refused != .Succeeded && refused != .Nothing_Has_That_Name {
		return refused, 0
	}
	pending := ranged.pending
	if pending == nil {
		return call_outcome.fail(error, .Nothing_Has_That_Name, .Absent, .Pending, 2)
	}
	start := system.time()
	written_before := blocks_written
	measure: Commit_Measure
	// The tables of the commit live in the pool until the commit ends: the
	// plan takes its fixed tables again before the pool gives them back.
	pool := pending.pool
	mark := pool_mark(pool)
	generation, changed := object_change(ranged.named.caller.store, path_names(&ranged.named.path), ranged.named.name, .Ranges, nil, {}, reaches_whole_store(&ranged.named.caller), error, 2, pending, &measure)
	plan_tables_fixed()
	pool_rewind(pool, mark)
	if changed != .Succeeded {
		if storage_status.commit_refusal_drops_pending(changed) {
			pending_drop(pending)
		}
		return changed, 0
	}
	pending_drop(pending)
	measure.generation = generation
	measure.written = i64(blocks_written - written_before)
	measure.milliseconds = i64(system.time() - start)
	system.log_fact(.Info, Ranges_Committed{generation = u64(generation), changed = u64(measure.changed), object_blocks = u64(measure.object_blocks), hashed_blocks = u64(measure.hashed_blocks), hashed_nodes = u64(measure.hashed_nodes), written = u64(measure.written), held = blocks_field(u64(measure.held_blocks)), elapsed = milliseconds_field(u64(measure.milliseconds))}, kept_text(&ranged.named.name))
	if len(result) > 0 {
		result[0] = measure
	}
	return .Succeeded, 1
}

// drop_pending drops the pending changes of this connection on the object `name` under a place: its next read sees the object as its last commit gives it, and its memory goes back to the service. The other pending objects of the connection stay. The result is 0, or a failure with its call outcome and an error record. The end of a connection drops all of its pending changes.
//
// The error kinds: those of a name (Argument_Refused); Absent (Argument_Refused, Nothing_Has_That_Name: the place); Absent (Nothing_Has_That_Name, unit Pending: the object has no pending change on this connection).
@(export, link_name = "drop_pending")
drop_pending :: proc "c" (place: i64, name: ^string, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	ranged: Ranged
	// An object that has no commit yet can still have pending changes.
	if refused := ranged_of(place, name^, &ranged, error, false); refused != .Succeeded && refused != .Nothing_Has_That_Name {
		return refused, 0
	}
	if ranged.pending == nil {
		return call_outcome.fail(error, .Nothing_Has_That_Name, .Absent, .Pending, 2)
	}
	pending_drop(ranged.pending)
	return .Succeeded, 0
}
