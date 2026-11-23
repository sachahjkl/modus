#+build !freestanding
package immutable_tree

import "base:runtime"
import "core:fmt"
import "core:testing"
import "modus:contract/blake3"
import format "modus:contract/store"
import "modus:contract/tree_hash"
import "internal:storage/storage_tree"

// A disk and an object store that grow: a folder of 262 145 entries takes
// about 30 000 blocks of its B+ tree.
@(private = "file")
Large_Env :: struct {
	blocks:  [dynamic]storage_tree.Block,
	objects: map[[HASH_HEX_LENGTH]u8][]u8,
	source:  storage_tree.Source,
	writer:  storage_tree.Writer,
	backend: Store_Backend,
	pool:    storage_tree.Pool,
	work:    Freeze_Work,
	root:    format.Pointer,
	count:   int,
}

@(private = "file")
large_env_make :: proc() -> ^Large_Env {
	env := new(Large_Env)
	append(&env.blocks, storage_tree.Block{}, storage_tree.Block{})
	env.source = {
		read = proc "contextless" (source: ^storage_tree.Source, pointer: format.Pointer, into: ^storage_tree.Block) -> storage_tree.Read {
			e := (^Large_Env)(source.data)
			if pointer.block < 2 || pointer.block >= u64(len(e.blocks)) || format.check(e.blocks[pointer.block][:]) != pointer.check {
				return .Wrong
			}
			into^ = e.blocks[pointer.block]
			return .Good
		},
		data = env,
	}
	env.writer = {
		write = proc "contextless" (writer: ^storage_tree.Writer, bytes: ^storage_tree.Block) -> format.Pointer {
			e := (^Large_Env)(writer.data)
			context = runtime.default_context()
			append(&e.blocks, bytes^)
			return {block = u64(len(e.blocks) - 1), check = format.check(bytes[:])}
		},
		data = env,
	}
	env.backend = {
		read_object = proc "contextless" (backend: ^Store_Backend, name: [HASH_HEX_LENGTH]u8, buffer: []u8) -> (int, Backend_Status) {
			e := (^Large_Env)(backend.data)
			context = runtime.default_context()
			bytes, found := e.objects[name]
			if !found {
				return 0, .Absent
			}
			if len(bytes) > len(buffer) {
				return len(bytes), .Buffer_Too_Small
			}
			return copy(buffer, bytes), .Ok
		},
		has_object = proc "contextless" (backend: ^Store_Backend, name: [HASH_HEX_LENGTH]u8) -> (bool, Backend_Status) {
			e := (^Large_Env)(backend.data)
			context = runtime.default_context()
			return name in e.objects, .Ok
		},
		write_object = proc "contextless" (backend: ^Store_Backend, name: [HASH_HEX_LENGTH]u8, data: []u8) -> Backend_Status {
			e := (^Large_Env)(backend.data)
			context = runtime.default_context()
			copied := make([]u8, len(data))
			copy(copied, data)
			e.objects[name] = copied
			return .Ok
		},
		data = env,
	}
	return env
}

@(private = "file")
large_env_free :: proc(env: ^Large_Env) {
	for _, bytes in env.objects {
		delete(bytes)
	}
	delete(env.objects)
	delete(env.blocks)
	free(env)
}

// The name of the entry `number`: their order is the order of the numbers.
@(private = "file")
large_name :: proc(number: int) -> string {
	return fmt.tprintf("entry-%07d", number)
}

// large_grow adds empty objects to the folder up to `count` entries, in
// commits of 200 names.
@(private = "file")
large_grow :: proc(env: ^Large_Env, count: int) {
	empty := format.Entry{kind = u64(format.Entry_Kind.Object), hash = blake3.hash(nil)}
	for env.count < count {
		storage_tree.pool_reset(&env.pool)
		work := storage_tree.Work{pool = &env.pool, source = &env.source, shape = storage_tree.TREE_SHAPE, root = env.root}
		for _ in 0 ..< 200 {
			if env.count == count {
				break
			}
			key := format.entry_name(large_name(env.count))
			storage_tree.put(&work, key[:], ([^]u8)(&empty)[:size_of(format.Entry)], true)
			env.count += 1
		}
		env.root = storage_tree.finish(&work, &env.writer)
		free_all(context.temp_allocator)
	}
}

// large_node gives the canonical bytes of a node of the store.
@(private = "file")
large_node :: proc(env: ^Large_Env, hash: blake3.Hash) -> []u8 {
	return env.objects[hash_to_hex(hash)]
}

// The shape of a frozen folder: the counts of its root, and of each child
// of the root.
@(private = "file")
expect_parts :: proc(t: ^testing.T, env: ^Large_Env, root: blake3.Hash, children: []int, child_holds_parts: bool, label: string) {
	bytes := large_node(env, root)
	testing.expectf(t, tree_hash.tree_holds_parts(bytes), "%s: the root holds parts", label)
	testing.expectf(t, tree_hash.tree_entry_count(bytes) == len(children), "%s: the root holds %d parts, not %d", label, tree_hash.tree_entry_count(bytes), len(children))
	offset := tree_hash.HEADER_SIZE
	for expected, place in children {
		part, next, ok := tree_hash.tree_entry_next(bytes, offset)
		offset = next
		testing.expectf(t, ok && part.kind == .Part, "%s: part %d", label, place)
		child := large_node(env, part.hash)
		testing.expectf(t, tree_hash.tree_holds_parts(child) == child_holds_parts, "%s: the child %d holds parts: %v", label, place, child_holds_parts)
		testing.expectf(t, tree_hash.tree_entry_count(child) == expected, "%s: the child %d holds %d, not %d", label, place, tree_hash.tree_entry_count(child), expected)
	}
}

@(private = "file")
large_freeze :: proc(t: ^testing.T, env: ^Large_Env, shape: Folder_Shape) -> blake3.Hash {
	hash, status := freeze_tree(&env.work, &env.source, &env.pool, env.root, &env.backend, shape = shape)
	testing.expect_value(t, status, Tree_Store_Status.Ok)
	return hash
}

// Each lookup finds its name, and a name between two parts, before the
// first, or after the last is absent.
@(private = "file")
large_lookups :: proc(t: ^testing.T, env: ^Large_Env, root: blake3.Hash, scratch: []u8, shape: Folder_Shape, label: string) {
	for number in ([?]int{0, 1, shape.node_entries - 1, shape.node_entries, env.count / 2, env.count - 1}) {
		if number >= env.count {
			continue
		}
		entry, status := tree_entry(&env.backend, root, large_name(number), scratch, shape)
		testing.expectf(t, status == .Ok && entry.kind == .Object && tree_hash.tree_entry_name(&entry) == large_name(number), "%s: the entry %d is found", label, number)
	}
	for absent in ([?]string{"a", "entry-0000000x", "entry-9999999", "z"}) {
		_, status := tree_entry(&env.backend, root, absent, scratch, shape)
		testing.expectf(t, status == .Absent, "%s: %s is absent, not %v", label, absent, status)
	}
}

// The cut of a folder at the edges of a shape: a whole node is one node of
// entries; one entry more is two nodes under a root of two parts; a whole
// level of parts is one root; one entry more makes a level of parts more.
@(private = "file")
folder_edges :: proc(t: ^testing.T, shape: Folder_Shape, label: string) {
	env := large_env_make()
	defer large_env_free(env)
	scratch := make([]u8, tree_hash.MAX_ENCODED_TREE_BYTES)
	defer delete(scratch)
	whole := shape.node_entries

	large_grow(env, whole)
	one_node := large_freeze(t, env, shape)
	bytes := large_node(env, one_node)
	testing.expectf(t, !tree_hash.tree_holds_parts(bytes) && tree_hash.tree_entry_count(bytes) == whole, "%s: a whole node is one node of entries", label)
	large_lookups(t, env, one_node, scratch, shape, label)

	large_grow(env, whole + 1)
	two_nodes := large_freeze(t, env, shape)
	expect_parts(t, env, two_nodes, {whole, 1}, false, label)
	large_lookups(t, env, two_nodes, scratch, shape, label)
	// The same folder has the same form: no other hash.
	testing.expect_value(t, large_freeze(t, env, shape), two_nodes)

	full := whole * shape.part_fanout
	large_grow(env, full)
	level_one := large_freeze(t, env, shape)
	children := make([]int, shape.part_fanout, context.temp_allocator)
	for &count in children {
		count = whole
	}
	expect_parts(t, env, level_one, children, false, label)
	large_lookups(t, env, level_one, scratch, shape, label)

	large_grow(env, full + 1)
	level_two := large_freeze(t, env, shape)
	expect_parts(t, env, level_two, {shape.part_fanout, 1}, true, label)
	large_lookups(t, env, level_two, scratch, shape, label)
	testing.expect_value(t, env.work.part_top, 0)
	testing.expect_value(t, env.work.entry_top, 0)
	// A lookup with another shape than the freeze sees a form that is not
	// canonical for it.
	if shape != FOLDER_SHAPE {
		_, status := tree_entry(&env.backend, two_nodes, large_name(0), scratch)
		testing.expect_value(t, status, Tree_Store_Status.Corrupt_Tree)
	}
}

// The paths of the cut with nodes of 8 entries and of 8 parts: the same
// code as nodes of 4096 and 64, on folders of at most 65 entries.
@(test)
a_folder_of_more_than_one_node_freezes_in_parts :: proc(t: ^testing.T) {
	folder_edges(t, {node_entries = 8, part_fanout = 8}, "nodes of 8")
}

// The bound of the levels of parts: with nodes of 8 entries and of 2 parts,
// 8 * 2^PART_LEVEL_LIMIT entries freeze, and one more is refused.
@(test)
the_levels_of_parts_have_a_bound :: proc(t: ^testing.T) {
	shape := Folder_Shape{node_entries = 8, part_fanout = 2}
	most := 8
	for _ in 0 ..< tree_hash.PART_LEVEL_LIMIT {
		most *= 2
	}
	env := large_env_make()
	defer large_env_free(env)
	large_grow(env, most)
	_ = large_freeze(t, env, shape)
	large_grow(env, most + 1)
	_, status := freeze_tree(&env.work, &env.source, &env.pool, env.root, &env.backend, shape = shape)
	testing.expect_value(t, status, Tree_Store_Status.Too_Many_Entries)
}

// A shape out of the bounds of the format is refused, at the freeze and
// at the lookup.
@(test)
a_shape_out_of_the_format_is_refused :: proc(t: ^testing.T) {
	env := large_env_make()
	defer large_env_free(env)
	scratch := make([]u8, 1024)
	defer delete(scratch)
	refused := [?]Folder_Shape{{0, 8}, {1, 8}, {8, 1}, {8, 0}, {tree_hash.MAX_TREE_ENTRIES + 1, 8}, {8, tree_hash.PART_FANOUT + 1}, {-1, -1}}
	for shape in refused {
		_, status := freeze_tree(&env.work, &env.source, &env.pool, env.root, &env.backend, shape = shape)
		testing.expectf(t, status == .Damaged, "the shape %v is refused at the freeze", shape)
		_, lookup := tree_entry(&env.backend, {}, "a", scratch, shape)
		testing.expectf(t, lookup == .Damaged, "the shape %v is refused at the lookup", shape)
	}
}

// The same edges at the size of the format (4096 entries, 64 parts:
// 262 145 entries), opt-in: a B+ tree of that size takes minutes to build.
// It runs with -define:FULL_SIZE_FOLDERS=true.
FULL_SIZE_FOLDERS :: #config(FULL_SIZE_FOLDERS, false)

@(test)
opt_in_a_folder_of_the_format_size_freezes_in_parts :: proc(t: ^testing.T) {
	when FULL_SIZE_FOLDERS {
		folder_edges(t, FOLDER_SHAPE, "nodes of 4096")
	}
}

// A node of parts that is not the canonical form is refused at a lookup: a
// root of one part, a part whose node is not whole before the last, and a
// part whose node starts with another name.
@(test)
a_node_of_parts_out_of_form_is_refused :: proc(t: ^testing.T) {
	env := large_env_make()
	defer large_env_free(env)
	scratch := make([]u8, tree_hash.MAX_ENCODED_TREE_BYTES)
	defer delete(scratch)
	node_put :: proc(env: ^Large_Env, entries: []tree_hash.Tree_Entry) -> blake3.Hash {
		bytes := make([]u8, tree_hash.MAX_ENCODED_TREE_BYTES, context.temp_allocator)
		written, _ := tree_hash.tree_encode(entries, bytes)
		hash, _ := tree_hash.tree_hash(bytes[:written])
		env.backend.write_object(&env.backend, hash_to_hex(hash), bytes[:written])
		return hash
	}
	object :: proc(name: string) -> tree_hash.Tree_Entry {
		entry, _ := tree_hash.tree_entry_make(.Object, name, blake3.hash(nil))
		return entry
	}
	part :: proc(name: string, hash: blake3.Hash) -> tree_hash.Tree_Entry {
		entry, _ := tree_hash.tree_entry_make(.Part, name, hash)
		return entry
	}
	short := node_put(env, {object("a"), object("b")})
	last := node_put(env, {object("m")})
	// A root of one part.
	lonely := node_put(env, {part("a", short)})
	_, lonely_status := tree_entry(&env.backend, lonely, "a", scratch)
	testing.expect_value(t, lonely_status, Tree_Store_Status.Corrupt_Tree)
	// A first node of two entries: not whole.
	not_whole := node_put(env, {part("a", short), part("m", last)})
	_, not_whole_status := tree_entry(&env.backend, not_whole, "a", scratch)
	testing.expect_value(t, not_whole_status, Tree_Store_Status.Corrupt_Tree)
	// The last node may hold one entry: its lookup goes on.
	_, last_status := tree_entry(&env.backend, not_whole, "m", scratch)
	testing.expect_value(t, last_status, Tree_Store_Status.Ok)
	// A part named "c" over a node that starts with "m".
	renamed := node_put(env, {part("a", short), part("c", last)})
	_, renamed_status := tree_entry(&env.backend, renamed, "m", scratch)
	testing.expect_value(t, renamed_status, Tree_Store_Status.Corrupt_Tree)
	// A node that mixes parts and entries has no hash.
	mixed := [2]tree_hash.Tree_Entry{part("a", short), object("b")}
	bytes: [1024]u8
	_, mixed_refusal := tree_hash.tree_encode(mixed[:], bytes[:])
	testing.expect_value(t, mixed_refusal, tree_hash.Tree_Refusal.Mixed_Parts)
}
