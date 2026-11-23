package recipes_core

import "modus:contract/blake3"
import "modus:contract/builder"
import pr "modus:contract/plans_recipes"
import "modus:contract/tree_hash"

// The objects of the inputs of one build (src/md/features/recipes.md, "The
// builder"): the input store of a builder holds each object of each input,
// and nothing else. The walk reads each tree of an input from the place of
// the objects, checks it, and gives each object once to the place of the
// build. It reads no store itself: the module gives the two procedures, and
// a host test gives a store in memory.

// The deepest tree of an input, from the root of the input: the nesting of
// the trees of the storage service.
MAX_INPUT_TREE_DEPTH :: 32

// read_tree gives the canonical bytes of the tree of hash, from the place
// of the objects, in into. A tree that is not there is Input_Absent.
Input_Tree_Read_Proc :: #type proc "contextless" (hash: blake3.Hash, into: []u8, data: rawptr) -> (bytes: []u8, refusal: pr.Recipe_Refusal)

// take_object puts the object or the tree of hash in the input store. An
// object that is not in the place of the objects is Input_Absent.
Input_Object_Take_Proc :: #type proc "contextless" (hash: blake3.Hash, data: rawptr) -> pr.Recipe_Refusal

// The state of one walk: in the memory of the caller, as it holds a tree of
// the largest size.
Input_Closure :: struct {
	taken:         [builder.MAX_INPUT_OBJECTS]blake3.Hash,
	taken_count:   int,
	pending:       [builder.MAX_INPUT_OBJECTS]Pending_Tree,
	pending_count: int,
	tree:          [tree_hash.MAX_ENCODED_TREE_BYTES]u8,
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
			case .Tree:
				if refusal := closure_tree_add(walk, entry.hash, next.depth + 1); refusal != .None {
					return refusal
				}
			}
		}
	}
	return .None
}

@(private = "file")
closure_taken :: proc "contextless" (walk: ^Input_Closure, hash: blake3.Hash) -> bool {
	for item in walk.taken[:walk.taken_count] {
		if item == hash {
			return true
		}
	}
	return false
}

@(private = "file")
closure_take_once :: proc "contextless" (walk: ^Input_Closure, hash: blake3.Hash, take_object: Input_Object_Take_Proc, data: rawptr) -> pr.Recipe_Refusal {
	if closure_taken(walk, hash) {
		return .None
	}
	if walk.taken_count == builder.MAX_INPUT_OBJECTS {
		return .Input_Too_Large
	}
	if refusal := take_object(hash, data); refusal != .None {
		return refusal
	}
	walk.taken[walk.taken_count] = hash
	walk.taken_count += 1
	return .None
}

@(private = "file")
closure_tree_add :: proc "contextless" (walk: ^Input_Closure, hash: blake3.Hash, depth: int) -> pr.Recipe_Refusal {
	if depth >= MAX_INPUT_TREE_DEPTH || walk.pending_count == builder.MAX_INPUT_OBJECTS {
		return .Input_Too_Large
	}
	walk.pending[walk.pending_count] = {hash = hash, depth = depth}
	walk.pending_count += 1
	return .None
}
