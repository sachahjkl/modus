#+build !freestanding
package recipes_core

import "base:runtime"
import "core:testing"
import "modus:contract/blake3"
import "modus:contract/builder"
import "modus:contract/errors"
import pr "modus:contract/plans_recipes"
import "modus:contract/tree_hash"

// A place of the objects in memory: trees by hash, and the hashes of the
// objects that it holds.
@(private = "file")
Memory_Objects :: struct {
	tree_hashes: [dynamic]blake3.Hash,
	tree_bytes:  [dynamic][]u8,
	objects:     [dynamic]blake3.Hash,
	taken:       [2 * builder.MAX_INPUT_OBJECTS]blake3.Hash,
	taken_count: int,
	wrong_bytes: bool, // Each read gives the bytes of another tree.
	// The places of the trees, and the hashes of objects and trees that the
	// place holds: a walk of thousands of objects asks for each one.
	tree_index:  map[blake3.Hash]int,
	known:       map[blake3.Hash]bool,
	known_count: int, // The objects that known holds.
}

@(private = "file")
memory_objects_make :: proc() -> ^Memory_Objects {
	objects := new(Memory_Objects, context.temp_allocator)
	objects.tree_hashes = make([dynamic]blake3.Hash, context.temp_allocator)
	objects.tree_bytes = make([dynamic][]u8, context.temp_allocator)
	objects.objects = make([dynamic]blake3.Hash, context.temp_allocator)
	objects.tree_index = make(map[blake3.Hash]int, context.temp_allocator)
	objects.known = make(map[blake3.Hash]bool, context.temp_allocator)
	return objects
}

@(private = "file")
object_hash :: proc(tag: int) -> blake3.Hash {
	data := [2]u8{'o', u8(tag)}
	if tag > 255 {
		wide := [3]u8{'o', u8(tag >> 8), u8(tag)}
		return blake3.hash(wide[:])
	}
	return blake3.hash(data[:])
}

// tree_add encodes a tree of the given entries, keeps it, and gives its hash.
@(private = "file")
tree_add :: proc(objects: ^Memory_Objects, entries: []tree_hash.Tree_Entry) -> blake3.Hash {
	bytes := make([]u8, tree_hash.tree_encoded_size(entries[:]), context.temp_allocator)
	written, refusal := tree_hash.tree_encode(entries, bytes)
	assert(refusal == .None)
	hash, _ := tree_hash.tree_hash(bytes[:written])
	append(&objects.tree_hashes, hash)
	append(&objects.tree_bytes, bytes[:written])
	objects.tree_index[hash] = len(objects.tree_hashes) - 1
	objects.known[hash] = true
	return hash
}

@(private = "file")
entry_of :: proc(kind: tree_hash.Tree_Entry_Kind, name: string, hash: blake3.Hash) -> tree_hash.Tree_Entry {
	entry, refusal := tree_hash.tree_entry_make(kind, name, hash)
	assert(refusal == .None)
	return entry
}

@(private = "file")
memory_read_tree :: proc "contextless" (hash: blake3.Hash, into: []u8, data: rawptr) -> (bytes: []u8, refusal: pr.Recipe_Refusal) {
	context = runtime.default_context()
	objects := (^Memory_Objects)(data)
	if index, found := objects.tree_index[hash]; found {
		source := objects.tree_bytes[index]
		if objects.wrong_bytes {
			source = objects.tree_bytes[(index + 1) % len(objects.tree_bytes)]
		}
		copy(into, source)
		return into[:len(source)], .None
	}
	return nil, .Input_Absent
}

@(private = "file")
memory_take :: proc "contextless" (hash: blake3.Hash, data: rawptr) -> pr.Recipe_Refusal {
	context = runtime.default_context()
	objects := (^Memory_Objects)(data)
	for objects.known_count < len(objects.objects) {
		objects.known[objects.objects[objects.known_count]] = true
		objects.known_count += 1
	}
	if !objects.known[hash] {
		return .Input_Absent
	}
	if objects.taken_count < len(objects.taken) {
		objects.taken[objects.taken_count] = hash
	}
	objects.taken_count += 1
	return .None
}

@(private = "file")
input_of :: proc(name: string, kind: tree_hash.Tree_Entry_Kind, hash: blake3.Hash) -> pr.Recipe_Input {
	input, refusal := pr.recipe_input_make(name, kind == .Tree ? .Tree : .Blob, hash)
	assert(refusal == .None)
	return input
}

// A chain of trees, each with one entry "next" to the next: count trees.
@(private = "file")
chain_add :: proc(objects: ^Memory_Objects, count: int) -> blake3.Hash {
	append(&objects.objects, object_hash(1))
	entries := [1]tree_hash.Tree_Entry{entry_of(.Object, "leaf", object_hash(1))}
	hash := tree_add(objects, entries[:])
	for _ in 1 ..< count {
		entries[0] = entry_of(.Tree, "next", hash)
		hash = tree_add(objects, entries[:])
	}
	return hash
}

// The refusals of the walk over the objects of the inputs: an input tree
// that the place does not hold, an object under a tree that it does not
// hold, a blob input that it does not hold, the bytes of another tree under
// a hash, a missing procedure, one object past MAX_INPUT_OBJECTS, and one
// tree past MAX_INPUT_TREE_DEPTH. The edges are taken: exactly
// MAX_INPUT_OBJECTS objects, and a chain exactly MAX_INPUT_TREE_DEPTH deep.
@(test)
the_walk_over_the_inputs_refuses_what_is_absent_damaged_or_too_large :: proc(t: ^testing.T) {
	walk := new(Input_Closure, context.temp_allocator)
	objects := memory_objects_make()

	absent := [1]pr.Recipe_Input{input_of("source", .Tree, object_hash(9))}
	testing.expect_value(t, input_closure_take(walk, absent[:], memory_read_tree, memory_take, objects), pr.Recipe_Refusal.Input_Absent)

	entries := [1]tree_hash.Tree_Entry{entry_of(.Object, "file", object_hash(2))}
	missing_object := tree_add(objects, entries[:])
	inputs := [1]pr.Recipe_Input{input_of("source", .Tree, missing_object)}
	testing.expect_value(t, input_closure_take(walk, inputs[:], memory_read_tree, memory_take, objects), pr.Recipe_Refusal.Input_Absent)

	blob := [1]pr.Recipe_Input{input_of("data", .Object, object_hash(3))}
	testing.expect_value(t, input_closure_take(walk, blob[:], memory_read_tree, memory_take, objects), pr.Recipe_Refusal.Input_Absent)

	append(&objects.objects, object_hash(2))
	other := [1]tree_hash.Tree_Entry{entry_of(.Object, "other", object_hash(2))}
	tree_add(objects, other[:])
	objects.wrong_bytes = true
	testing.expect_value(t, input_closure_take(walk, inputs[:], memory_read_tree, memory_take, objects), pr.Recipe_Refusal.Store_Damaged)
	objects.wrong_bytes = false

	testing.expect_value(t, input_closure_take(nil, inputs[:], memory_read_tree, memory_take, objects), pr.Recipe_Refusal.Buffer_Too_Small)
	testing.expect_value(t, input_closure_take(walk, inputs[:], nil, memory_take, objects), pr.Recipe_Refusal.Buffer_Too_Small)
	testing.expect_value(t, input_closure_take(walk, inputs[:], memory_read_tree, nil, objects), pr.Recipe_Refusal.Buffer_Too_Small)

	// A root tree of subtrees of objects that holds total objects, the
	// trees with them: a tree holds at most tree_hash.MAX_TREE_ENTRIES
	// entries, so a whole of more objects is a tree of trees.
	wide :: proc(objects: ^Memory_Objects, total: int) -> blake3.Hash {
		subtree_count := 1
		for total - 1 - subtree_count > 500 * subtree_count {
			subtree_count += 1
		}
		object_count := total - 1 - subtree_count
		subtrees := make([]tree_hash.Tree_Entry, subtree_count, context.temp_allocator)
		next := 0
		for subtree in 0 ..< subtree_count {
			size := object_count / subtree_count + (subtree < object_count % subtree_count ? 1 : 0)
			names := make([]tree_hash.Tree_Entry, size, context.temp_allocator)
			for index in 0 ..< size {
				name := [4]u8{'f', 'a' + u8(index / 676), 'a' + u8(index / 26 % 26), 'a' + u8(index % 26)}
				append(&objects.objects, object_hash(1000 + next))
				names[index] = entry_of(.Object, string(name[:]), object_hash(1000 + next))
				next += 1
			}
			subtree_name := [3]u8{'d', 'a' + u8(subtree / 26), 'a' + u8(subtree % 26)}
			subtrees[subtree] = entry_of(.Tree, string(subtree_name[:]), tree_add(objects, names))
		}
		return tree_add(objects, subtrees)
	}
	most := [1]pr.Recipe_Input{input_of("source", .Tree, wide(objects, builder.MAX_INPUT_OBJECTS))}
	testing.expect_value(t, input_closure_take(walk, most[:], memory_read_tree, memory_take, objects), pr.Recipe_Refusal.None)
	testing.expect_value(t, walk.taken_count, builder.MAX_INPUT_OBJECTS)
	past := [1]pr.Recipe_Input{input_of("source", .Tree, wide(objects, builder.MAX_INPUT_OBJECTS + 1))}
	testing.expect_value(t, input_closure_take(walk, past[:], memory_read_tree, memory_take, objects), pr.Recipe_Refusal.Input_Too_Large)

	deepest := [1]pr.Recipe_Input{input_of("source", .Tree, chain_add(objects, MAX_INPUT_TREE_DEPTH))}
	testing.expect_value(t, input_closure_take(walk, deepest[:], memory_read_tree, memory_take, objects), pr.Recipe_Refusal.None)
	too_deep := [1]pr.Recipe_Input{input_of("source", .Tree, chain_add(objects, MAX_INPUT_TREE_DEPTH + 1))}
	testing.expect_value(t, input_closure_take(walk, too_deep[:], memory_read_tree, memory_take, objects), pr.Recipe_Refusal.Input_Too_Large)
}

// A chain of LEVELS trees, each of whose MAX_TREE_ENTRIES entries names the
// next tree, holds LEVELS + 2 objects: those trees, the tree of the leaf and
// the leaf object. The
// names pass MAX_INPUT_OBJECTS, and each tree waits once, so the walk does
// not count a name against MAX_INPUT_OBJECTS.
@(test)
a_subtree_that_many_entries_name_is_taken_once :: proc(t: ^testing.T) {
	walk := new(Input_Closure, context.temp_allocator)
	objects := memory_objects_make()
	append(&objects.objects, object_hash(1))
	leaf := [1]tree_hash.Tree_Entry{entry_of(.Object, "leaf", object_hash(1))}
	below := tree_add(objects, leaf[:])
	COUNT :: tree_hash.MAX_TREE_ENTRIES
	LEVELS :: builder.MAX_INPUT_OBJECTS / COUNT + 1
	#assert(LEVELS * COUNT > builder.MAX_INPUT_OBJECTS && LEVELS < MAX_INPUT_TREE_DEPTH)
	entries := make([]tree_hash.Tree_Entry, COUNT, context.temp_allocator)
	for _ in 0 ..< LEVELS {
		for index in 0 ..< COUNT {
			name := [3]u8{'a' + u8(index / 676), 'a' + u8(index / 26 % 26), 'a' + u8(index % 26)}
			entries[index] = entry_of(.Tree, string(name[:]), below)
		}
		below = tree_add(objects, entries)
	}
	inputs := [1]pr.Recipe_Input{input_of("source", .Tree, below)}
	testing.expect_value(t, input_closure_take(walk, inputs[:], memory_read_tree, memory_take, objects), pr.Recipe_Refusal.None)
	testing.expect_value(t, walk.taken_count, LEVELS + 2)
	testing.expect_value(t, objects.taken_count, LEVELS + 2)
}

// The success case of the walk: two inputs that share an object and a
// tree give each object once, and a blob input is taken.
@(test)
the_walk_gives_each_object_of_the_inputs_once :: proc(t: ^testing.T) {
	walk := new(Input_Closure, context.temp_allocator)
	objects := memory_objects_make()
	append(&objects.objects, object_hash(1), object_hash(2), object_hash(3))
	shared_entries := [1]tree_hash.Tree_Entry{entry_of(.Object, "shared", object_hash(1))}
	shared := tree_add(objects, shared_entries[:])
	first_entries := [2]tree_hash.Tree_Entry{entry_of(.Object, "a", object_hash(2)), entry_of(.Tree, "lib", shared)}
	second_entries := [2]tree_hash.Tree_Entry{entry_of(.Object, "b", object_hash(1)), entry_of(.Tree, "lib", shared)}
	inputs := [3]pr.Recipe_Input {
		input_of("data", .Object, object_hash(3)),
		input_of("first", .Tree, tree_add(objects, first_entries[:])),
		input_of("second", .Tree, tree_add(objects, second_entries[:])),
	}
	testing.expect_value(t, input_closure_take(walk, inputs[:], memory_read_tree, memory_take, objects), pr.Recipe_Refusal.None)
	// The blob, three trees, and the objects 1 and 2: six, each once.
	testing.expect_value(t, walk.taken_count, 6)
	testing.expect_value(t, objects.taken_count, 6)
}

// A refused freeze names the cause that the builder gave: a tree past the
// bounds is a malformed output, a full store is Store_Full. Each other kind,
// a negative word and a word past the last kind are a fault of the stores.
@(test)
a_refused_freeze_names_its_cause :: proc(t: ^testing.T) {
	testing.expect_value(t, freeze_refusal(i64(errors.Kind.Too_Long)), pr.Recipe_Refusal.Malformed_Output)
	testing.expect_value(t, freeze_refusal(i64(errors.Kind.Over_Limit)), pr.Recipe_Refusal.Store_Full)
	testing.expect_value(t, freeze_refusal(i64(errors.Kind.Full)), pr.Recipe_Refusal.Store_Full)
	for word in ([?]i64{i64(errors.Kind.None), i64(errors.Kind.No_Grant), i64(errors.Kind.Device), i64(errors.Kind.Bad_Value), -1, i64(max(errors.Kind)) + 1, max(i64)}) {
		testing.expectf(t, freeze_refusal(word) == .Store_Failed, "the kind word %d", word)
	}
}

// A start in memory: the cause that the start writes, and the output that
// it gives.
@(private = "file")
Memory_Start :: struct {
	refusal: pr.Recipe_Refusal,
	output:  []u8,
	calls:   int,
}

@(private = "file")
memory_invoke :: proc "contextless" (sandbox: ^pr.Builder_Sandbox_Spec, staging: []u8, user_data: rawptr) -> (payload: []u8, ok: bool) {
	start := (^Builder_Start)(user_data)
	memory := (^Memory_Start)(start.data)
	memory.calls += 1
	if memory.refusal != .None {
		start.refusal = memory.refusal
		return nil, false
	}
	// The output of a builder in a process of its own is memory of the
	// service, not the staging.
	return memory.output, true
}

@(private = "file")
builder_recipe :: proc(registry: ^Recipe_Registry, tag: u8) -> blake3.Hash {
	spec := new(pr.Recipe_Spec, context.temp_allocator)
	spec.builder_hash = object_hash(200 + int(tag))
	spec.output_kind = .Tree
	hash, refusal := register_recipe(registry, spec)
	assert(refusal == .None)
	return hash
}

// The refusals of a builder that the service starts, each with its cause
// and nothing kept: a time out, a builder that the image does not hold, a
// sandbox that the check refuses, and a failure with no cause, which stays
// Builder_Failed. With no start, the builder needs the sandbox.
@(test)
a_refused_build_names_its_cause_and_keeps_nothing :: proc(t: ^testing.T) {
	state := new(Recipes_State, context.temp_allocator)
	store := recipes_test_state_init(state)
	defer free(store)
	registry := new(Recipe_Registry, context.temp_allocator)
	memory := new(Memory_Start, context.temp_allocator)
	start := Builder_Start{invoke = memory_invoke, data = memory}
	for cause, index in ([?]pr.Recipe_Refusal{.Builder_Timed_Out, .Builder_Absent, .Input_Absent, .Sandbox_Violation, .Builder_Failed}) {
		memory.refusal = cause
		recipe := builder_recipe(registry, u8(index))
		result := build_registered(state, registry, recipe, .Build_Only, &start)
		testing.expect_value(t, result.refusal, cause)
		testing.expect_value(t, realisation_rows(state, nil), 0)
	}
	recipe := builder_recipe(registry, 50)
	result := build_registered(state, registry, recipe, .Build_Only, nil)
	testing.expect_value(t, result.refusal, pr.Recipe_Refusal.Builder_Needs_Sandbox)
	testing.expect_value(t, memory.calls, 5)
}

// The success case: the output of the start is the canonical root tree of
// the output; its tree hash is the output hash and the realisation is kept,
// so a second build in a mode that takes the cache starts nothing.
@(test)
a_started_builder_gives_a_realisation :: proc(t: ^testing.T) {
	state := new(Recipes_State, context.temp_allocator)
	store := recipes_test_state_init(state)
	defer free(store)
	registry := new(Recipe_Registry, context.temp_allocator)
	objects := memory_objects_make()
	entries := [1]tree_hash.Tree_Entry{entry_of(.Object, "made", object_hash(7))}
	output := tree_add(objects, entries[:])
	memory := new(Memory_Start, context.temp_allocator)
	memory.output = objects.tree_bytes[0]
	start := Builder_Start{invoke = memory_invoke, data = memory}
	recipe := builder_recipe(registry, 60)
	result := build_registered(state, registry, recipe, .Cache_First, &start)
	testing.expect_value(t, result.refusal, pr.Recipe_Refusal.None)
	testing.expect(t, result.output_hash == output, "the output hash is the tree hash of the output")
	testing.expect_value(t, realisation_rows(state, nil), 1)
	again := build_registered(state, registry, recipe, .Cache_First, &start)
	testing.expect(t, again.refusal == .None && again.output_hash == output, "the second build takes the realisation")
	testing.expect_value(t, memory.calls, 1)
}
