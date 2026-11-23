package recipes_core

import "modus:contract/blake3"
import "modus:contract/builder"
import "modus:contract/errors"
import pr "modus:contract/plans_recipes"
import "modus:contract/tree_hash"

// The objects of the inputs of one build (src/md/features/recipes.md, "The
// builder"): the input store of a builder holds each object of each input,
// and nothing else. The walk reads each tree of an input from the place of
// the objects, checks it, and gives each object once to the place of the
// build. It reads no store itself: the module gives the two procedures, and
// a host test gives a store in memory.

// freeze_refusal names the cause of a refused freeze of the store "out",
// from the word of the kind of its error record: what the builder left
// there breaks a bound of an immutable tree (Too_Long: more than 512
// entries in a tree, a tree nested past 32), or fills the store (Over_Limit,
// Full). Each other kind, and a word that names no kind, is a fault of the
// stores of the service.
freeze_refusal :: proc "contextless" (kind_word: i64) -> pr.Recipe_Refusal {
	kind, known := errors.kind_of_word(kind_word)
	if !known {
		return .Store_Failed
	}
	if kind == .Too_Long {
		return .Malformed_Output
	}
	if kind == .Over_Limit || kind == .Full {
		return .Store_Full
	}
	return .Store_Failed
}

// The deepest tree of an input, from the root of the input: the nesting of
// the trees of the storage service.
MAX_INPUT_TREE_DEPTH :: 32

// read_tree gives the canonical bytes of the tree of hash, from the place
// of the objects, in into. A tree that is not there is Input_Absent.
Input_Tree_Read_Proc :: #type proc "contextless" (hash: blake3.Hash, into: []u8, data: rawptr) -> (bytes: []u8, refusal: pr.Recipe_Refusal)

// take_object puts the object or the tree of hash in the input store. An
// object that is not in the place of the objects is Input_Absent.
Input_Object_Take_Proc :: #type proc "contextless" (hash: blake3.Hash, data: rawptr) -> pr.Recipe_Refusal

// The hashes that a walk has seen: each taken object, and each tree that
// waits. Each tree that waits is taken when it leaves the stack, or the
// walk ends, so a walk sees at most the objects that it takes and the trees
// that wait at once.
CLOSURE_SEEN_CAPACITY :: 2 * builder.MAX_INPUT_OBJECTS
// The slots of the set of the seen hashes: a power of two, at most half
// full, so a probe ends after a few slots.
CLOSURE_SLOT_COUNT :: 2 * CLOSURE_SEEN_CAPACITY
#assert(CLOSURE_SLOT_COUNT & (CLOSURE_SLOT_COUNT - 1) == 0)

// One hash that the walk has seen, and whether its object is taken.
Seen_Hash :: struct {
	hash:  blake3.Hash,
	taken: bool,
}

// The state of one walk: in the memory of the caller, as it holds a tree of
// the largest size and the set of the seen hashes.
Input_Closure :: struct {
	taken:         [builder.MAX_INPUT_OBJECTS]blake3.Hash,
	taken_count:   int,
	pending:       [builder.MAX_INPUT_OBJECTS]Pending_Tree,
	pending_count: int,
	tree:          [tree_hash.MAX_ENCODED_TREE_BYTES]u8,
	// A hash names a slot by its first 8 bytes: the hashes are BLAKE3 hashes
	// that the walk checked, and a hash that a caller chose to collide only
	// makes its own build slower, up to the bound of the walk.
	seen:          [CLOSURE_SEEN_CAPACITY]Seen_Hash,
	seen_count:    int,
	slots:         [CLOSURE_SLOT_COUNT]u32, // 1 + the index in seen; 0: an empty slot.
}

// A tree that the walk reads next, and how deep it is under its input.
Pending_Tree :: struct {
	hash:  blake3.Hash,
	depth: int,
}

// input_closure_take gives each object of each input to take_object, once:
// a blob of an input, each tree of an input and each tree and object under
// it. A tree whose bytes are not canonical, or whose hash is not the hash
// that names it, is Store_Damaged; more objects than MAX_INPUT_OBJECTS, or
// a tree deeper than MAX_INPUT_TREE_DEPTH, is Input_Too_Large.
input_closure_take :: proc "contextless" (walk: ^Input_Closure, inputs: []pr.Recipe_Input, read_tree: Input_Tree_Read_Proc, take_object: Input_Object_Take_Proc, data: rawptr) -> pr.Recipe_Refusal {
	if walk == nil || read_tree == nil || take_object == nil {
		return .Buffer_Too_Small
	}
	walk.taken_count = 0
	walk.pending_count = 0
	walk.seen_count = 0
	walk.slots = {}
	for &input in inputs {
		switch input.kind {
		case .Blob:
			if refusal := closure_take_once(walk, input.hash, take_object, data); refusal != .None {
				return refusal
			}
		case .Tree:
			if refusal := closure_tree_add(walk, input.hash, 0); refusal != .None {
				return refusal
			}
		}
	}
	for walk.pending_count > 0 {
		walk.pending_count -= 1
		next := walk.pending[walk.pending_count]
		if closure_taken(walk, next.hash) {
			continue
		}
		bytes, read_refusal := read_tree(next.hash, walk.tree[:], data)
		if read_refusal != .None {
			return read_refusal
		}
		hash, tree_refusal := tree_hash.tree_hash(bytes)
		if tree_refusal != .None || hash != next.hash {
			return .Store_Damaged
		}
		if refusal := closure_take_once(walk, next.hash, take_object, data); refusal != .None {
			return refusal
		}
		count, _ := tree_hash.tree_validate(bytes)
		for index in 0 ..< count {
			entry, ok := tree_hash.tree_entry_at(bytes, index)
			if !ok {
				return .Store_Damaged
			}
			switch entry.kind {
			case .Object:
				if refusal := closure_take_once(walk, entry.hash, take_object, data); refusal != .None {
					return refusal
				}
			case .Tree, .Part: // A part is a node of the same tree, walked as a tree.
				if refusal := closure_tree_add(walk, entry.hash, next.depth + 1); refusal != .None {
					return refusal
				}
			}
		}
	}
	return .None
}

// seen_find gives the seen hash, or nil, and the slot where it is or where
// it goes.
@(private = "file")
seen_find :: proc "contextless" (walk: ^Input_Closure, hash: blake3.Hash) -> (seen: ^Seen_Hash, slot: int) {
	key := u64(hash[0]) | u64(hash[1]) << 8 | u64(hash[2]) << 16 | u64(hash[3]) << 24 | u64(hash[4]) << 32 | u64(hash[5]) << 40 | u64(hash[6]) << 48 | u64(hash[7]) << 56
	slot = int(key & (CLOSURE_SLOT_COUNT - 1))
	for walk.slots[slot] != 0 {
		item := &walk.seen[walk.slots[slot] - 1]
		if item.hash == hash {
			return item, slot
		}
		slot = (slot + 1) & (CLOSURE_SLOT_COUNT - 1)
	}
	return nil, slot
}

// seen_add notes a hash that is not seen, or gives nil when the walk has
// seen CLOSURE_SEEN_CAPACITY hashes, which the bounds of the walk prevent.
@(private = "file")
seen_add :: proc "contextless" (walk: ^Input_Closure, hash: blake3.Hash) -> ^Seen_Hash {
	existing, slot := seen_find(walk, hash)
	if existing != nil {
		return existing
	}
	if walk.seen_count == CLOSURE_SEEN_CAPACITY {
		return nil
	}
	walk.seen[walk.seen_count] = {hash = hash}
	walk.seen_count += 1
	walk.slots[slot] = u32(walk.seen_count)
	return &walk.seen[walk.seen_count - 1]
}

@(private = "file")
closure_taken :: proc "contextless" (walk: ^Input_Closure, hash: blake3.Hash) -> bool {
	seen, _ := seen_find(walk, hash)
	return seen != nil && seen.taken
}

@(private = "file")
closure_take_once :: proc "contextless" (walk: ^Input_Closure, hash: blake3.Hash, take_object: Input_Object_Take_Proc, data: rawptr) -> pr.Recipe_Refusal {
	if closure_taken(walk, hash) {
		return .None
	}
	if walk.taken_count == builder.MAX_INPUT_OBJECTS {
		return .Input_Too_Large
	}
	seen := seen_add(walk, hash)
	if seen == nil {
		return .Input_Too_Large
	}
	if refusal := take_object(hash, data); refusal != .None {
		return refusal
	}
	seen.taken = true
	walk.taken[walk.taken_count] = hash
	walk.taken_count += 1
	return .None
}

@(private = "file")
closure_tree_add :: proc "contextless" (walk: ^Input_Closure, hash: blake3.Hash, depth: int) -> pr.Recipe_Refusal {
	if depth >= MAX_INPUT_TREE_DEPTH {
		return .Input_Too_Large
	}
	// A tree that many entries name is one object: it waits once, and is
	// read once. A seen hash is taken, or waits.
	if seen, _ := seen_find(walk, hash); seen != nil {
		return .None
	}
	if walk.pending_count == builder.MAX_INPUT_OBJECTS || seen_add(walk, hash) == nil {
		return .Input_Too_Large
	}
	walk.pending[walk.pending_count] = {hash = hash, depth = depth}
	walk.pending_count += 1
	return .None
}
