// Immutable content-addressed tree operations over the storage service's B+
// trees and object store (src/md/features/declarations.md;
// src/md/features/recipes.md).
//
// Pure, zero-allocation private part of the storage service:
// - `freeze_tree`: walks a mutable B+ tree bottom-up iteratively (bounded by
//   max_depth), persists leaf objects by their hash, encodes every tree node
//   canonically via modus:contract/tree_hash, computes its domain-separated
//   tree hash, and writes each new tree object under its 64-byte lowercase hex
//   hash (skipping already-present identical subtrees). A tree of more than
//   tree_hash.MAX_TREE_ENTRIES entries is refused with Too_Many_Entries.
// - `tree_read`, `tree_entry`, `tree_walk_path`: read and traverse immutable
//   trees strictly through the tree_hash contract border, verifying canonical
//   validity and exact domain-separated hash match on every node.
package immutable_tree

import "modus:contract/blake3"
import format "modus:contract/store"
import "modus:contract/tree_hash"
import "internal:storage/storage_tree"

// Length in bytes of a canonical lowercase hexadecimal BLAKE3 hash name.
HASH_HEX_LENGTH :: 2 * blake3.HASH_SIZE
#assert(HASH_HEX_LENGTH <= format.ENTRY_NAME_CAPACITY)

// Maximum total pending Tree_Entry slots held simultaneously across all active
// frames during a bottom-up freeze_tree walk: a whole tree of the largest
// size, and as many more for the trees above it on the path.
FREEZE_ENTRY_POOL_CAPACITY :: 2 * tree_hash.MAX_TREE_ENTRIES

// Closed set of outcomes returned by a Store_Backend callback.
Backend_Status :: enum u8 {
	Ok               = 0,
	Absent           = 1,
	Buffer_Too_Small = 2,
	Full             = 3,
	Device_Error     = 4,
	Damaged          = 5,
}

// Closed set of outcomes returned by immutable tree store operations.
Tree_Store_Status :: enum u8 {
	Ok                = 0,
	Absent            = 1,
	Corrupt_Tree      = 2,
	Invalid_Name      = 3,
	Not_A_Tree        = 4,
	Depth_Exceeded    = 5,
	Too_Many_Entries  = 6,
	Capacity_Exceeded = 7,
	Buffer_Too_Small  = 8,
	Full              = 9,
	Damaged           = 10,
	Device_Error      = 11,
}

// Abstract immutable object backend implemented by the storage service or host tests.
Store_Backend :: struct {
	read_object:          proc "contextless" (backend: ^Store_Backend, name: [HASH_HEX_LENGTH]u8, buffer: []u8) -> (length: int, status: Backend_Status),
	has_object:           proc "contextless" (backend: ^Store_Backend, name: [HASH_HEX_LENGTH]u8) -> (exists: bool, status: Backend_Status),
	write_object:         proc "contextless" (backend: ^Store_Backend, name: [HASH_HEX_LENGTH]u8, data: []u8) -> Backend_Status,
	persist_entry_object: proc "contextless" (backend: ^Store_Backend, entry: format.Entry, name: [HASH_HEX_LENGTH]u8) -> Backend_Status,
	data:                 rawptr,
}

// Counters recorded by one freeze_tree run.
Freeze_Stats :: struct {
	trees_written:   int, // Canonical tree objects newly written to the backend.
	trees_reused:    int, // Identical canonical tree objects already present in the backend.
	objects_written: int, // Leaf objects newly persisted by hash in the backend.
	objects_reused:  int, // Identical leaf objects already present in the backend.
}

// One active directory level of an iterative freeze_tree walk.
@(private)
Freeze_Frame :: struct {
	root:         format.Pointer,
	cursor:       format.Entry_Name,
	has_cursor:   bool,
	entry_start:  int,
	entry_count:  int,
	pending_name: format.Entry_Name,
}

// Caller-owned fixed workspace for freeze_tree (zero dynamic allocation).
Freeze_Work :: struct {
	frames:        [format.NESTING_LIMIT + 1]Freeze_Frame,
	entries:       [FREEZE_ENTRY_POOL_CAPACITY]tree_hash.Tree_Entry,
	entry_top:     int,
	encode_buffer: [tree_hash.MAX_ENCODED_TREE_BYTES]u8,
	stats:         Freeze_Stats,
}

// hash_to_hex formats a 32-byte hash as 64 canonical lowercase hex bytes.
hash_to_hex :: proc "contextless" (hash: blake3.Hash) -> (out: [HASH_HEX_LENGTH]u8) {
	digits := "0123456789abcdef"
	for value, index in hash {
		out[2 * index] = digits[value >> 4]
		out[2 * index + 1] = digits[value & 0x0F]
	}
	return out
}

// hex_to_hash parses 64 canonical lowercase hex bytes into a 32-byte hash.
// Uppercase letters, wrong lengths, and non-hex bytes are refused so each
// hash has one canonical store name.
hex_to_hash :: proc "contextless" (text: []u8) -> (hash: blake3.Hash, ok: bool) {
	if len(text) != HASH_HEX_LENGTH {
		return {}, false
	}
	for index in 0 ..< blake3.HASH_SIZE {
		high, high_ok := lowercase_hex_nibble(text[2 * index])
		low, low_ok := lowercase_hex_nibble(text[2 * index + 1])
		if !high_ok || !low_ok {
			return {}, false
		}
		hash[index] = high << 4 | low
	}
	return hash, true
}

@(private)
lowercase_hex_nibble :: proc "contextless" (value: u8) -> (nibble: u8, ok: bool) {
	switch value {
	case '0' ..= '9':
		return value - '0', true
	case 'a' ..= 'f':
		return value - 'a' + 10, true
	}
	return 0, false
}

@(private)
backend_status_to_tree_status :: proc "contextless" (status: Backend_Status) -> Tree_Store_Status {
	switch status {
	case .Ok:
		return .Ok
	case .Absent:
		return .Absent
	case .Buffer_Too_Small:
		return .Buffer_Too_Small
	case .Full:
		return .Full
	case .Device_Error:
		return .Device_Error
	case .Damaged:
		return .Damaged
	}
	return .Damaged
}

@(private)
tree_failure_to_status :: proc "contextless" (failure: storage_tree.Failure) -> Tree_Store_Status {
	switch failure {
	case .None:
		return .Ok
	case .Device:
		return .Device_Error
	case .Wrong, .Damaged:
		return .Damaged
	case .Full:
		return .Capacity_Exceeded
	case .Write:
		return .Full
	}
	return .Damaged
}

// freeze_tree hashes a mutable B+ tree subtree bottom-up into canonical
// immutable tree objects stored in backend, deduplicating identical subtrees
// and leaf objects by hash, and returns the root tree hash.
freeze_tree :: proc "contextless" (
	work: ^Freeze_Work,
	tree_source: ^storage_tree.Source,
	tree_pool: ^storage_tree.Pool,
	root_pointer: format.Pointer,
	backend: ^Store_Backend,
	max_depth: int = format.NESTING_LIMIT,
) -> (root_hash: blake3.Hash, status: Tree_Store_Status) {
	if work == nil || tree_source == nil || tree_pool == nil || backend == nil || backend.has_object == nil || backend.write_object == nil {
		return {}, .Damaged
	}
	if max_depth < 0 || max_depth > format.NESTING_LIMIT {
		return {}, .Depth_Exceeded
	}
	work.entry_top = 0
	work.stats = {}
	work.frames[0] = {root = root_pointer, entry_start = 0}
	frame_depth := 0

	for frame_depth >= 0 {
		frame := &work.frames[frame_depth]
		storage_tree.pool_reset(tree_pool)
		tree_work := storage_tree.Work {
			pool   = tree_pool,
			source = tree_source,
			shape  = storage_tree.TREE_SHAPE,
			root   = frame.root,
		}
		key: format.Entry_Name
		entry: format.Entry
		found := storage_tree.first_from(
			&tree_work,
			frame.cursor[:],
			frame.has_cursor,
			key[:],
			([^]u8)(&entry)[:size_of(format.Entry)],
		)
		if tree_pool.failure != .None {
			return {}, tree_failure_to_status(tree_pool.failure)
		}
		if !found {
			// All entries of this tree have been collected in sorted order.
			collected := work.entries[frame.entry_start:frame.entry_start + frame.entry_count]
			written, enc_refusal := tree_hash.tree_encode(collected, work.encode_buffer[:])
			if enc_refusal != .None {
				return {}, enc_refusal == .Too_Many_Entries ? .Too_Many_Entries : .Invalid_Name
			}
			encoded := work.encode_buffer[:written]
			node_hash, hash_refusal := tree_hash.tree_hash(encoded)
			if hash_refusal != .None {
				return {}, .Corrupt_Tree
			}
			node_hex := hash_to_hex(node_hash)
			exists, has_status := backend.has_object(backend, node_hex)
			if has_status != .Ok {
				return {}, backend_status_to_tree_status(has_status)
			}
			if exists {
				work.stats.trees_reused += 1
			} else {
				if write_status := backend.write_object(backend, node_hex, encoded); write_status != .Ok {
					return {}, backend_status_to_tree_status(write_status)
				}
				work.stats.trees_written += 1
			}
			// Rewind the flat entry pool before returning to the parent frame.
			work.entry_top = frame.entry_start
			frame_depth -= 1
			if frame_depth < 0 {
				return node_hash, .Ok
			}
			parent := &work.frames[frame_depth]
			if parent.entry_count >= tree_hash.MAX_TREE_ENTRIES {
				return {}, .Too_Many_Entries
			}
			if work.entry_top >= FREEZE_ENTRY_POOL_CAPACITY {
				return {}, .Capacity_Exceeded
			}
			parent_name := format.name_of(&parent.pending_name)
			tree_entry, make_refusal := tree_hash.tree_entry_make(.Tree, parent_name, node_hash)
			if make_refusal != .None {
				return {}, .Invalid_Name
			}
			work.entries[work.entry_top] = tree_entry
			work.entry_top += 1
			parent.entry_count += 1
			continue
		}

		frame.cursor = key
		frame.has_cursor = true
		entry_kind, kind_ok := format.entry_kind_of_word(entry.kind)
		if !kind_ok {
			return {}, .Damaged
		}
		switch entry_kind {
		case .None:
			return {}, .Damaged
		case .Object:
			if frame.entry_count >= tree_hash.MAX_TREE_ENTRIES {
				return {}, .Too_Many_Entries
			}
			if work.entry_top >= FREEZE_ENTRY_POOL_CAPACITY {
				return {}, .Capacity_Exceeded
			}
			object_hash := entry.hash
			if entry.size == 0 && entry.pointer.block == 0 {
				// Empty objects always carry the BLAKE3 hash of empty bytes.
				object_hash = blake3.hash(nil)
			}
			if backend.persist_entry_object != nil {
				object_hex := hash_to_hex(object_hash)
				exists, has_status := backend.has_object(backend, object_hex)
				if has_status != .Ok {
					return {}, backend_status_to_tree_status(has_status)
				}
				if exists {
					work.stats.objects_reused += 1
				} else {
					if persist_status := backend.persist_entry_object(backend, entry, object_hex); persist_status != .Ok {
						return {}, backend_status_to_tree_status(persist_status)
					}
					work.stats.objects_written += 1
				}
			}
			name_text := format.name_of(&key)
			obj_entry, make_refusal := tree_hash.tree_entry_make(.Object, name_text, object_hash)
			if make_refusal != .None {
				return {}, .Invalid_Name
			}
			work.entries[work.entry_top] = obj_entry
			work.entry_top += 1
			frame.entry_count += 1
		case .Tree:
			if frame_depth >= max_depth {
				return {}, .Depth_Exceeded
			}
			frame.pending_name = key
			frame_depth += 1
			work.frames[frame_depth] = {
				root        = entry.pointer,
				entry_start = work.entry_top,
			}
		}
	}
	return {}, .Damaged
}

// tree_read loads an immutable tree object by its hash, validates its canonical
// encoding through tree_hash.tree_validate, and verifies that its
// domain-separated tree hash equals hash.
tree_read :: proc "contextless" (backend: ^Store_Backend, hash: blake3.Hash, buffer: []u8) -> (canonical_bytes: []u8, status: Tree_Store_Status) {
	if backend == nil || backend.read_object == nil {
		return nil, .Damaged
	}
	name := hash_to_hex(hash)
	length, read_status := backend.read_object(backend, name, buffer)
	if read_status != .Ok {
		return nil, backend_status_to_tree_status(read_status)
	}
	if length < 0 || length > len(buffer) {
		return nil, .Corrupt_Tree
	}
	slice := buffer[:length]
	computed_hash, refusal := tree_hash.tree_hash(slice)
	if refusal != .None || computed_hash != hash {
		return nil, .Corrupt_Tree
	}
	return slice, .Ok
}

// tree_entry looks up a single entry by name inside the immutable tree root_hash.
tree_entry :: proc "contextless" (backend: ^Store_Backend, root_hash: blake3.Hash, name: string, scratch: []u8) -> (entry: tree_hash.Tree_Entry, status: Tree_Store_Status) {
	if name_refusal := tree_hash.tree_name_validate(transmute([]u8)name); name_refusal != .None {
		return {}, .Invalid_Name
	}
	canonical, read_status := tree_read(backend, root_hash, scratch)
	if read_status != .Ok {
		return {}, read_status
	}
	found_entry, found, lookup_refusal := tree_hash.tree_lookup(canonical, name)
	if lookup_refusal != .None {
		return {}, .Corrupt_Tree
	}
	if !found {
		return {}, .Absent
	}
	return found_entry, .Ok
}

// tree_walk_path resolves a multi-step path of entry names from root_hash,
// verifying each intermediate immutable tree hash along the way.
tree_walk_path :: proc "contextless" (
	backend: ^Store_Backend,
	root_hash: blake3.Hash,
	path: []string,
	scratch: []u8,
	max_depth: int = format.NESTING_LIMIT,
) -> (entry: tree_hash.Tree_Entry, status: Tree_Store_Status) {
	if len(path) == 0 {
		return {}, .Invalid_Name
	}
	if max_depth < 0 || len(path) > max_depth + 1 {
		return {}, .Depth_Exceeded
	}
	current := root_hash
	for component, step in path {
		found_entry, step_status := tree_entry(backend, current, component, scratch)
		if step_status != .Ok {
			return {}, step_status
		}
		if step + 1 == len(path) {
			return found_entry, .Ok
		}
		if found_entry.kind != .Tree {
			return {}, .Not_A_Tree
		}
		current = found_entry.hash
	}
	return {}, .Absent
}
