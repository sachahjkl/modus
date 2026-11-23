#+build !freestanding
package recipes_core

import "base:runtime"
import "core:slice"
import "core:strings"
import "core:testing"
import "modus:contract/blake3"
import pr "modus:contract/plans_recipes"

// A private store in memory with each procedure of the port: objects of
// any size, a commit order for the listing, and the blocks of the store
// with its limit. A write that would pass the limit is refused, as the
// storage service refuses it.
Large_Store :: struct {
	objects:         map[string]Large_Object,
	generation:      i64,
	block_limit:     i64, // 0: no limit.
	removes:         int,
	context_of_test: runtime.Context, // The port is contextless: the maps take the allocator of the test.
}

Large_Object :: struct {
	bytes:      [dynamic]u8,
	generation: i64,
}

@(private = "file")
large_blocks_of :: proc "contextless" (length: int) -> i64 {
	return i64((length + 4095) / 4096) + 1
}

@(private = "file")
large_blocks :: proc(store: ^Large_Store) -> (blocks: i64) {
	for _, object in store.objects {
		blocks += large_blocks_of(len(object.bytes))
	}
	return blocks
}

large_store_port :: proc(store: ^Large_Store) -> pr.Private_Store_Port {
	store.objects = make(map[string]Large_Object, context.temp_allocator)
	store.context_of_test = context
	return {
		user = store,
		read = proc "contextless" (user: rawptr, name: string, into: []u8) -> (int, pr.Private_Store_Status) {
			store := (^Large_Store)(user)
			context = store.context_of_test
			object, found := store.objects[name]
			if !found {
				return 0, .Absent
			}
			if len(object.bytes) > len(into) {
				return 0, .Too_Large
			}
			return copy(into, object.bytes[:]), .Ok
		},
		write = proc "contextless" (user: rawptr, name: string, data: []u8) -> pr.Private_Store_Status {
			store := (^Large_Store)(user)
			context = store.context_of_test
			old, found := store.objects[name]
			blocks := large_blocks(store) + large_blocks_of(len(data)) - (found ? large_blocks_of(len(old.bytes)) : 0)
			if store.block_limit != 0 && blocks > store.block_limit {
				return .Failed
			}
			bytes := make([dynamic]u8, len(data), context.temp_allocator)
			copy(bytes[:], data)
			store.generation += 1
			// The name is memory of the caller: the map keeps its own copy.
			key := found ? name : strings.clone(name, context.temp_allocator)
			store.objects[key] = {bytes = bytes, generation = store.generation}
			return .Ok
		},
		read_range = proc "contextless" (user: rawptr, name: string, offset: u64, into: []u8) -> (int, pr.Private_Store_Status) {
			store := (^Large_Store)(user)
			context = store.context_of_test
			object, found := store.objects[name]
			if !found {
				return 0, .Absent
			}
			if offset >= u64(len(object.bytes)) {
				return 0, .Ok
			}
			return copy(into, object.bytes[offset:]), .Ok
		},
		remove = proc "contextless" (user: rawptr, name: string) -> pr.Private_Store_Status {
			store := (^Large_Store)(user)
			context = store.context_of_test
			if name not_in store.objects {
				return .Absent
			}
			delete_key(&store.objects, name)
			store.removes += 1
			return .Ok
		},
		list = proc "contextless" (user: rawptr, after: string, rows: []pr.Private_Store_Entry, names: []u8) -> (int, pr.Private_Store_Status) {
			store := (^Large_Store)(user)
			context = store.context_of_test
			keys := make([dynamic]string, context.temp_allocator)
			for key in store.objects {
				if key > after {
					append(&keys, key)
				}
			}
			slice.sort(keys[:])
			count, used := 0, 0
			for key in keys {
				if count == len(rows) || used + len(key) > len(names) {
					break
				}
				copy(names[used:], key)
				rows[count] = {name_offset = used, name_count = len(key), size = i64(len(store.objects[key].bytes)), generation = store.objects[key].generation}
				used += len(key)
				count += 1
			}
			return count, .Ok
		},
		usage = proc "contextless" (user: rawptr) -> (i64, i64, pr.Private_Store_Status) {
			store := (^Large_Store)(user)
			context = store.context_of_test
			// A store always has a limit: no limit of the test is the largest.
			return large_blocks(store), store.block_limit != 0 ? store.block_limit : 1 << 40, .Ok
		},
	}
}

// A builder that gives an output in memory of its own, of the size that
// the recipe names in its arguments, and counts its builds.
Large_Builder :: struct {
	output: []u8,
	builds: int,
}

@(private = "file")
large_builder_invoke :: proc "contextless" (sandbox: ^pr.Builder_Sandbox_Spec, staging: []u8, user_data: rawptr) -> ([]u8, bool) {
	builder := (^Large_Builder)(user_data)
	builder.builds += 1
	return builder.output, true
}

@(private = "file")
large_spec :: proc(tag: int) -> ^pr.Recipe_Spec {
	spec := new(pr.Recipe_Spec, context.temp_allocator)
	spec.builder_hash = blake3.hash(transmute([]u8)string("a large builder"))
	spec.output_kind = .Blob
	spec.input_count = 1
	tag_bytes := transmute([8]u8)i64(tag)
	spec.inputs[0], _ = pr.recipe_input_make("src", .Blob, blake3.hash(tag_bytes[:]))
	return spec
}

@(private = "file")
large_output :: proc(size: int, seed: u8) -> []u8 {
	bytes := make([]u8, size, context.temp_allocator)
	for &byte, index in bytes {
		byte = u8(index * 31) ~ seed
	}
	return bytes
}

// An output at each edge of the staging, past it, and at the bound of one
// object of a cache: built from memory of the builder, kept in the store,
// read back after a start with its hash checked, and read into a buffer of
// its size only. One byte past the bound is refused, and keeps nothing.
@(test)
an_output_of_any_size_reaches_the_store_and_comes_back :: proc(t: ^testing.T) {
	state := new(Recipes_State, context.temp_allocator)
	store: Large_Store
	state_init(state, large_store_port(&store))
	sizes := [?]int{1, STAGING_BYTES - 1, STAGING_BYTES, STAGING_BYTES + 1, 1024 * 1024 + 1, OUTPUT_BYTES_MOST}
	for size, index in sizes {
		builder := Large_Builder{output = large_output(size, u8(index))}
		spec := large_spec(index)
		built := build_recipe(state, spec, .Cache_First, {}, nil, large_builder_invoke, nil, nil, &builder)
		testing.expectf(t, built.outcome == .Built_Locally && built.output_hash == blake3.hash(builder.output), "%d bytes: %v %v", size, built.outcome, built.refusal)
		state_init(state, large_store_port_again(&store))
		again := build_recipe(state, spec, .Cache_First, {}, nil, large_builder_invoke, nil, nil, &builder)
		testing.expectf(t, again.outcome == .From_Cache && builder.builds == 1, "%d bytes after a start: %v, %d builds", size, again.outcome, builder.builds)
		length, found := output_length(state, again.output_hash)
		testing.expect(t, found && length == u64(size))
		into := make([]u8, size, context.temp_allocator)
		read, refusal := output_read(state, again.output_hash, into)
		testing.expectf(t, refusal == .None && string(read) == string(builder.output), "%d bytes: %v", size, refusal)
		_, short := output_read(state, again.output_hash, into[:size - 1])
		testing.expect_value(t, short, pr.Recipe_Refusal.Buffer_Too_Small)
	}
	objects := len(store.objects)
	past := Large_Builder{output = large_output(OUTPUT_BYTES_MOST + 1, 9)}
	refused := build_recipe(state, large_spec(100), .Cache_First, {}, nil, large_builder_invoke, nil, nil, &past)
	testing.expect_value(t, refused.refusal, pr.Recipe_Refusal.Malformed_Output)
	testing.expect_value(t, len(store.objects), objects)
	_, absent := output_read(state, blake3.hash(past.output), nil)
	testing.expect_value(t, absent, pr.Recipe_Refusal.Cache_Miss)
}

// large_store_port_again gives the port of a store that holds objects
// already: a service that starts again.
@(private = "file")
large_store_port_again :: proc(store: ^Large_Store) -> pr.Private_Store_Port {
	objects := store.objects
	port := large_store_port(store)
	store.objects = objects
	return port
}

// The retention rule keeps the outputs under their share of the store: the
// oldest realisations go, with their outputs, and the newest stay. An
// output larger than the whole share is refused and removes nothing.
@(test)
the_retention_rule_removes_the_oldest_realisations :: proc(t: ^testing.T) {
	state := new(Recipes_State, context.temp_allocator)
	store: Large_Store
	state_init(state, large_store_port(&store))
	store.block_limit = 400 // A share of 300 blocks: about 7 outputs of 40 blocks.
	OUTPUT :: 39 * 4096
	hashes: [12]blake3.Hash
	for index in 0 ..< len(hashes) {
		builder := Large_Builder{output = large_output(OUTPUT, u8(index))}
		built := build_recipe(state, large_spec(index), .Cache_First, {}, nil, large_builder_invoke, nil, nil, &builder)
		testing.expectf(t, built.outcome == .Built_Locally, "output %d: %v %v", index, built.outcome, built.refusal)
		hashes[index] = built.output_hash
		blocks, limit := large_usage(&store)
		testing.expectf(t, blocks <= limit / 100 * RETENTION_PERCENT, "output %d: %d blocks of %d", index, blocks, limit)
	}
	testing.expect(t, state.counters.retention_removals > 0)
	// No more than the outputs need: a share of 300 blocks holds 7 outputs
	// of 42 blocks with their heads, and the last build needed room for one.
	heads := 0
	for key in store.objects {
		if len(key) > len(pr.REALISATION_OBJECT_PREFIX) && key[:len(pr.REALISATION_OBJECT_PREFIX)] == pr.REALISATION_OBJECT_PREFIX {
			heads += 1
		}
	}
	testing.expect_value(t, heads, 7)
	testing.expect_value(t, state.counters.retention_removals, u64(len(hashes) - 7))
	// The newest are whole in the store; the oldest went.
	newest := pr.blob_object_name(hashes[len(hashes) - 1])
	_, newest_kept := store.objects[pr.private_object_name_text(&newest)]
	testing.expect(t, newest_kept)
	oldest := pr.blob_object_name(hashes[0])
	_, oldest_kept := store.objects[pr.private_object_name_text(&oldest)]
	testing.expect(t, !oldest_kept)
	// The oldest builds again, and is the newest then.
	builder := Large_Builder{output = large_output(OUTPUT, 0)}
	state_init(state, large_store_port_again(&store))
	store.block_limit = 400
	again := build_recipe(state, large_spec(0), .Cache_First, {}, nil, large_builder_invoke, nil, nil, &builder)
	testing.expect_value(t, again.outcome, pr.Recipe_Build_Outcome.Built_Locally)

	// Past the share: refused, and no remove.
	removes := store.removes
	huge := Large_Builder{output = large_output(310 * 4096, 7)}
	refused := build_recipe(state, large_spec(200), .Cache_First, {}, nil, large_builder_invoke, nil, nil, &huge)
	testing.expect_value(t, refused.refusal, pr.Recipe_Refusal.Store_Full)
	testing.expect_value(t, store.removes, removes)
}

@(private = "file")
large_usage :: proc(store: ^Large_Store) -> (blocks: i64, limit: i64) {
	return large_blocks(store), store.block_limit
}

// More realisations than the index holds: the index forgets the least
// recently used, and a build of it reads it back from the store.
@(test)
the_index_forgets_and_the_store_remembers :: proc(t: ^testing.T) {
	state := new(Recipes_State, context.temp_allocator)
	store: Large_Store
	state_init(state, large_store_port(&store))
	builder := Large_Builder{output = large_output(10, 1)}
	for index in 0 ..= REALISATION_INDEX_CAPACITY {
		builder.output = large_output(10, u8(index))
		builder.output[0] = u8(index >> 8)
		built := build_recipe(state, large_spec(index), .Cache_First, {}, nil, large_builder_invoke, nil, nil, &builder)
		if !testing.expectf(t, built.outcome == .Built_Locally, "%d: %v", index, built.refusal) {
			return
		}
	}
	builds := builder.builds
	first := build_recipe(state, large_spec(0), .Cache_First, {}, nil, large_builder_invoke, nil, nil, &builder)
	testing.expect_value(t, first.outcome, pr.Recipe_Build_Outcome.From_Cache)
	testing.expect_value(t, builder.builds, builds)
	testing.expect_value(t, state.counters.cache_hits_store, u64(1))
}

// Even the removal of each realisation that the rule may remove cannot make
// room: the rule refuses with Store_Full, and removes nothing. An output
// that a registered recipe, the build that runs, or a holder of the service
// names as an input is never removed, and the rule removes the others.
@(test)
the_retention_rule_keeps_inputs_and_removes_nothing_in_vain :: proc(t: ^testing.T) {
	state := new(Recipes_State, context.temp_allocator)
	registry := new(Recipe_Registry, context.temp_allocator)
	store: Large_Store
	state_init(state, large_store_port(&store))
	state.registry = registry
	store.block_limit = 400 // A share of 300 blocks.
	OUTPUT :: 39 * 4096 // 40 blocks, and 2 of its head.
	hashes: [7]blake3.Hash
	for index in 0 ..< len(hashes) {
		builder := Large_Builder{output = large_output(OUTPUT, u8(index))}
		built := build_recipe(state, large_spec(index), .Cache_First, {}, nil, large_builder_invoke, nil, nil, &builder)
		testing.expect_value(t, built.outcome, pr.Recipe_Build_Outcome.Built_Locally)
		hashes[index] = built.output_hash
	}
	// The first two outputs are inputs: of a registered recipe, and of a
	// holder of the service.
	consumer := new(pr.Recipe_Spec, context.temp_allocator)
	consumer.builder_hash = blake3.hash(transmute([]u8)string("a consumer"))
	consumer.output_kind = .Blob
	consumer.input_count = 1
	consumer.inputs[0], _ = pr.recipe_input_make("first", .Blob, hashes[0])
	_, registered := register_recipe(registry, consumer)
	testing.expect_value(t, registered, pr.Recipe_Refusal.None)
	Keep :: struct {
		hash: blake3.Hash,
	}
	keep := Keep{hash = hashes[1]}
	state.retention_keep = proc "contextless" (hash: blake3.Hash, user_data: rawptr) -> bool {
		return hash == (^Keep)(user_data).hash
	}
	state.retention_keep_user = &keep

	// 5 realisations may go, about 210 blocks; an output of 280 blocks needs
	// more than they free: refused, and nothing removed.
	removes := store.removes
	objects := len(store.objects)
	huge := Large_Builder{output = large_output(279 * 4096, 9)}
	refused := build_recipe(state, large_spec(100), .Cache_First, {}, nil, large_builder_invoke, nil, nil, &huge)
	testing.expect_value(t, refused.refusal, pr.Recipe_Refusal.Store_Full)
	testing.expect_value(t, store.removes, removes)
	testing.expect_value(t, len(store.objects), objects)

	// An output that fits once two realisations go: the protected ones stay.
	more := Large_Builder{output = large_output(OUTPUT, 20)}
	built := build_recipe(state, large_spec(20), .Cache_First, {}, nil, large_builder_invoke, nil, nil, &more)
	testing.expect_value(t, built.outcome, pr.Recipe_Build_Outcome.Built_Locally)
	testing.expect(t, state.counters.retention_removals >= 1)
	for kept in hashes[:2] {
		name := pr.blob_object_name(kept)
		_, held := store.objects[pr.private_object_name_text(&name)]
		testing.expect(t, held, "a protected input stays in the store")
	}
	third := pr.blob_object_name(hashes[2])
	_, third_held := store.objects[pr.private_object_name_text(&third)]
	testing.expect(t, !third_held, "the oldest output that no input names goes first")
}

// The index holds a realisation and forgot its output: the store answers,
// and the recipe does not build again.
@(test)
a_forgotten_output_of_a_known_realisation_comes_from_the_store :: proc(t: ^testing.T) {
	state := new(Recipes_State, context.temp_allocator)
	store: Large_Store
	state_init(state, large_store_port(&store))
	builder := Large_Builder{output = large_output(100, 1)}
	first := build_recipe(state, large_spec(1), .Cache_First, {}, nil, large_builder_invoke, nil, nil, &builder)
	testing.expect_value(t, first.outcome, pr.Recipe_Build_Outcome.Built_Locally)
	for &slot in state.objects {
		slot = {}
	}
	again := build_recipe(state, large_spec(1), .Cache_First, {}, nil, large_builder_invoke, nil, nil, &builder)
	testing.expect_value(t, again.outcome, pr.Recipe_Build_Outcome.From_Cache)
	testing.expect_value(t, builder.builds, 1)
}
