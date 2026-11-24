// The start of a builder (src/md/features/recipes.md, "The builder"): this
// service starts the module of the builder as a call host, gives it an
// input store that reads only and an empty store "out", both shares of
// places of its private store, and calls its export build with a bound.
// The output hash is the tree hash of the store "out", frozen into the
// place of the objects after the call host and the shares ended.
package recipes_service

import "internal:recipes/recipes_core"
import "modus:contract/blake3"
import "modus:contract/builder"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/isolated"
import module "modus:contract/module"
import op "modus:contract/operation"
import pr "modus:contract/plans_recipes"
import "modus:contract/storage_status"
import "modus:contract/tree_hash"
import "modus:contract/value_kinds"
import "modus:storage"
import "modus:storage_port"
import "modus:system"

// What the start of a builder takes from the context of this service.
builder_image: []u8
builder_image_memory: system.Handle
builder_log: system.Handle
// The file of the storage service in the boot image: the call host of a
// builder maps it, as its exports describe the calls of its stores.
storage_file_entry_first: u64
storage_file_entry_pages: u64
storage_file_size: u64

// The state of one build, in this memory: it holds a tree of the largest size.
builder_walk: recipes_core.Input_Closure
builder_start: recipes_core.Builder_Start
builder_rows: [pr.MAX_RECIPE_INPUTS]pr.Recipe_Input_Row
builder_load_error: module.Load_Error

// The places of one build, on the connection to the private store.
@(private = "file")
Build_Places :: struct {
	client:  ^storage.Client,
	objects: storage.Place,
	build:   storage.Place,
	input:   storage.Place,
	output:  storage.Place,
}

// builder_start_init keeps what a start of a builder needs: the boot image,
// the log, and the place of the file of the storage service in the image,
// found by its bytes. With none of them, each build of a builder is
// refused, and the inputs tree builder still runs.
builder_start_init :: proc "contextless" (ctx: ^system.Context) {
	builder_image_memory = ctx.handles[system.GRANT_IMAGE]
	builder_log = ctx.handles[op.CONTEXT_LOG]
	if builder_image_memory == 0 {
		return
	}
	address, status := system.memory_map(builder_image_memory, {})
	if status != .Succeeded {
		return
	}
	builder_image = ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	size := ctx.values[storage.VALUE_FILE_SIZE]
	if size == 0 {
		return
	}
	file_address := uintptr(storage.FILE_ADDRESS)
	mapped := ([^]u8)(file_address)[:size]
	mapped_hash := blake3.hash(mapped)
	for &entry in system.image_entries(builder_image) {
		if entry.size == size && entry.hash == mapped_hash && entry.offset % system.PAGE_SIZE == 0 {
			storage_file_entry_first = entry.offset / system.PAGE_SIZE
			storage_file_entry_pages = (size + system.PAGE_SIZE - 1) / system.PAGE_SIZE
			storage_file_size = size
		}
	}
	builder_start = {invoke = builder_invoke}
}

// builder_invoke is the start of recipes_core for each builder that is not
// the inputs tree builder: it gives the canonical bytes of the root tree of
// the output, or writes the cause of its refusal.
@(private = "file")
builder_invoke :: proc "contextless" (sandbox: ^pr.Builder_Sandbox_Spec, staging: []u8, user_data: rawptr) -> (payload: []u8, ok: bool) {
	start := (^recipes_core.Builder_Start)(user_data)
	length, refusal := build_run(sandbox, staging)
	if refusal != .None {
		start.refusal = refusal
		return nil, false
	}
	return staging[:length], true
}

// builder_file gives the module of the boot image whose hash is the hash of
// the builder, and the number of its export build.
@(private = "file")
builder_file :: proc "contextless" (hash: blake3.Hash) -> (file: []u8, export: u32, found: bool) {
	for &entry in system.image_entries(builder_image) {
		if entry.hash != hash || entry.offset > u64(len(builder_image)) || entry.size > u64(len(builder_image)) - entry.offset {
			continue
		}
		file = builder_image[entry.offset:][:entry.size]
		if blake3.hash(file) != hash || module.validate(file) != .None {
			return nil, 0, false
		}
		export = module.export_find(file, builder.BUILD_EXPORT)
		return file, export, export != 0
	}
	return nil, 0, false
}

@(private = "file")
build_run :: proc "contextless" (sandbox: ^pr.Builder_Sandbox_Spec, out_payload: []u8) -> (length: int, refusal: pr.Recipe_Refusal) {
	if builder_image == nil || storage_file_size == 0 || builder_log == 0 {
		return 0, .Builder_Needs_Sandbox
	}
	file, export, found := builder_file(sandbox.builder_hash)
	if !found {
		return 0, .Builder_Absent
	}
	places := Build_Places{client = &storage_port.store_client}
	if !storage.connected(places.client) {
		return 0, .Store_Failed
	}
	if refusal = build_places_open(&places); refusal != .None {
		build_places_end(&places)
		return 0, refusal
	}
	defer build_places_end(&places)
	if refusal = recipes_core.input_closure_take(&builder_walk, sandbox.inputs[:sandbox.input_count], objects_tree_read, objects_take, &places); refusal != .None {
		return 0, refusal
	}
	result, call_refusal := builder_call(sandbox, file, export, &places)
	if call_refusal != .None {
		return 0, call_refusal
	}
	if result != 1 {
		return 0, .Builder_Failed
	}
	return output_freeze(&places, out_payload)
}

// build_places_open makes a new place of the build: whatever a build before
// left there is removed first, so the store "out" is empty. Content-addressed
// objects live at storage.ROOT under their exact 64 lowercase hexadecimal
// digits, matching storage.freeze_tree, put, put_memory, guest_build, and
// remote cache fetches.
@(private = "file")
build_places_open :: proc "contextless" (places: ^Build_Places) -> pr.Recipe_Refusal {
	client := places.client
	error: errors.Error_Record
	status: storage_status.Status
	places.objects = storage.ROOT
	_, _ = storage.remove(client, storage.ROOT, builder.BUILD_PLACE, &error)
	if !tree_add(client, storage.ROOT, builder.BUILD_PLACE) {
		return .Store_Failed
	}
	if places.build, status = storage.open_tree(client, storage.ROOT, builder.BUILD_PLACE, &error); status != .Ok {
		return .Store_Failed
	}
	if !tree_add(client, places.build, builder.INPUT_PLACE) || !tree_add(client, places.build, builder.OUTPUT_PLACE) {
		return .Store_Failed
	}
	if places.input, status = storage.open_tree(client, places.build, builder.INPUT_PLACE, &error); status != .Ok {
		return .Store_Failed
	}
	if places.output, status = storage.open_tree(client, places.build, builder.OUTPUT_PLACE, &error); status != .Ok {
		return .Store_Failed
	}
	return .None
}

// build_places_end closes the places, and removes the place of the build:
// its objects are clones, and the output is in the place of the objects.
@(private = "file")
build_places_end :: proc "contextless" (places: ^Build_Places) {
	error: errors.Error_Record
	for place in ([?]storage.Place{places.input, places.output, places.build, places.objects}) {
		if place != storage.ROOT {
			_ = storage.close_tree(places.client, place, &error)
		}
	}
	_, _ = storage.remove(places.client, storage.ROOT, builder.BUILD_PLACE, &error)
	// The check that the build left nothing: an open of the place of the
	// build gives Absent, and the log says the kind, for the machine test.
	left_error: errors.Error_Record
	if left, status := storage.open_tree(places.client, storage.ROOT, builder.BUILD_PLACE, &left_error); status == .Ok {
		_ = storage.close_tree(places.client, left, &error)
	}
	system.log_fact(.Info, Build_Place_Ended{kind = left_error.kind})
}

@(private = "file")
tree_add :: proc "contextless" (client: ^storage.Client, place: storage.Place, name: string) -> bool {
	rows := [1]storage.Add_Row{{0, i64(len(name)), i64(storage.Entry_Kind.Tree)}}
	error: errors.Error_Record
	_, status := storage.add(client, place, rows[:], transmute([]u8)name, &error)
	return status == .Ok
}

@(private = "file")
HEX_DIGITS := "0123456789abcdef"

// hash_hex gives the name of an object of the place of the objects: the
// 64 lowercase hexadecimal digits of its hash.
@(private = "file")
hash_hex :: proc "contextless" (hash: blake3.Hash) -> (text: [2 * blake3.HASH_SIZE]u8) {
	for byte_value, index in hash {
		text[2 * index] = HEX_DIGITS[byte_value >> 4]
		text[2 * index + 1] = HEX_DIGITS[byte_value & 0x0f]
	}
	return text
}

@(private = "file")
objects_tree_read :: proc "contextless" (hash: blake3.Hash, into: []u8, data: rawptr) -> (bytes: []u8, refusal: pr.Recipe_Refusal) {
	places := (^Build_Places)(data)
	name := hash_hex(hash)
	arguments := [2]isolated.Argument{{integer = u64(places.objects)}, {text = name[:]}}
	error: errors.Error_Record
	value, text, status, outcome := storage.call(places.client, "tree_read", arguments[:], &error)
	if outcome == .Nothing_Has_That_Name {
		return nil, .Input_Absent
	}
	if status != .Ok || value < 0 || int(value) != len(text) || len(text) > len(into) {
		return nil, .Store_Failed
	}
	copy(into, text)
	return into[:len(text)], .None
}

// boot_image_module_of_hash returns the verified bytes of a boot-image module
// whose BLAKE3 hash equals hash, or (nil, false) when absent or damaged.
@(private = "file")
boot_image_module_of_hash :: proc "contextless" (hash: blake3.Hash) -> (bytes: []u8, found: bool) {
	if builder_image == nil {
		return nil, false
	}
	for &entry in system.image_entries(builder_image) {
		if entry.hash != hash || entry.offset > u64(len(builder_image)) || entry.size > u64(len(builder_image)) - entry.offset {
			continue
		}
		candidate := builder_image[entry.offset:][:entry.size]
		if blake3.hash(candidate) == hash {
			return candidate, true
		}
		return nil, false
	}
	return nil, false
}

// write_place_large writes data into target_place under name in 32 KiB chunks,
// committing every 1 MiB. Drops pending changes on any failure.
@(private = "file")
write_place_large :: proc "contextless" (client: ^storage.Client, target_place: storage.Place, name: string, data: []u8) -> bool {
	error: errors.Error_Record
	if len(data) <= storage_port.WRITE_PIECE_BYTES {
		gen, status := storage.write(client, target_place, name, data, &error)
		return status == .Ok && gen >= 0
	}
	committed := 0
	for written := 0; written < len(data); {
		part := data[written:min(written + storage_port.WRITE_PIECE_BYTES, len(data))]
		if _, status := storage.write_range(client, target_place, name, u64(written), part, &error); status != .Ok {
			_ = storage.drop_pending(client, target_place, name, &error)
			return false
		}
		written += len(part)
		if written - committed >= storage_port.COMMIT_STEP_BYTES {
			if _, status := storage.commit(client, target_place, name, &error); status != .Ok {
				_ = storage.drop_pending(client, target_place, name, &error)
				return false
			}
			committed = written
		}
	}
	if storage.set_size(client, target_place, name, u64(len(data)), &error) != .Ok {
		_ = storage.drop_pending(client, target_place, name, &error)
		return false
	}
	_, status := storage.commit(client, target_place, name, &error)
	if status != .Ok {
		_ = storage.drop_pending(client, target_place, name, &error)
		return false
	}
	return true
}

// objects_take puts a clone of an object of the private store in the place of
// the inputs, under the same 64-hex name: a clone shares its blocks, and the
// rename moves it with no byte copied. When an input is a module of the boot
// image (such as c_compiler, assemble, or host for catalog.c.module) not yet
// in the store, it writes the verified boot-image bytes into places.input.
@(private = "file")
objects_take :: proc "contextless" (hash: blake3.Hash, data: rawptr) -> pr.Recipe_Refusal {
	places := (^Build_Places)(data)
	name := hash_hex(hash)
	TAKING :: "taking"
	error: errors.Error_Record
	arguments := [3]isolated.Argument{{integer = u64(places.objects)}, {text = name[:]}, {text = transmute([]u8)string(TAKING)}}
	value, _, status, outcome := storage.call(places.client, "clone", arguments[:], &error)
	if outcome == .Nothing_Has_That_Name {
		if image_bytes, has_image_module := boot_image_module_of_hash(hash); has_image_module {
			if !write_place_large(places.client, places.input, string(name[:]), image_bytes) {
				return .Store_Failed
			}
			return .None
		}
		return .Input_Absent
	}
	if status != .Ok || value < 0 {
		return .Store_Failed
	}
	if _, moved := storage.rename(places.client, places.objects, TAKING, places.input, string(name[:]), &error); moved != .Ok {
		return .Store_Failed
	}
	return .None
}

// builder_call makes the two shares, runs the builder with them, and ends
// the shares, whatever the outcome. The writable output share gets a block
// quota of its own computed from the recipe's output_block_limit and the
// store's free headroom so a runaway builder never fills or evicts versions
// in recipes's own store. A share that does not end leaves the builder a way
// to change the store "out", so the build is refused and nothing is frozen.
@(private = "file")
builder_call :: proc "contextless" (sandbox: ^pr.Builder_Sandbox_Spec, file: []u8, export: u32, places: ^Build_Places) -> (result: i64, refusal: pr.Recipe_Refusal) {
	counts, usage_status := storage.usage(places.client)
	if usage_status != .Ok || counts.blocks < 0 || counts.limit <= 0 {
		return 0, .Store_Failed
	}
	output_block_limit := recipes_core.builder_output_block_limit(sandbox.output_block_limit, u64(counts.limit), u64(counts.blocks))
	if output_block_limit == 0 {
		return 0, .Store_Full
	}
	error: errors.Error_Record
	input_share, input_number, input_status := storage.share(places.client, places.input, true, &error, 0)
	if input_status != .Ok {
		return 0, .Store_Failed
	}
	output_share, output_number, output_status := storage.share(places.client, places.output, false, &error, output_block_limit)
	if output_status != .Ok {
		_ = share_end(places.client, &input_share, input_number)
		return 0, .Store_Failed
	}
	result, refusal = builder_run(sandbox, file, export, places, &input_share, &output_share)
	input_ended := share_end(places.client, &input_share, input_number)
	output_ended := share_end(places.client, &output_share, output_number)
	if !input_ended || !output_ended {
		return 0, .Store_Failed
	}
	return result, refusal
}

// builder_run starts the call host with the context of a builder, calls
// build with the bound, and ends the call host, whatever the outcome.
@(private = "file")
builder_run :: proc "contextless" (sandbox: ^pr.Builder_Sandbox_Spec, file: []u8, export: u32, places: ^Build_Places, input_share, output_share: ^storage.Client) -> (result: i64, refusal: pr.Recipe_Refusal) {
	error: errors.Error_Record

	added := system.Call_Host_Context{
		pages     = c_builder_host_pages(),
		processes = 2,
		no_clock  = true,
	}
	added.grants[builder.GRANT_INPUT_RING] = {input_share.ring_memory, {.Read, .Write}}
	added.grants[builder.GRANT_INPUT_REGION] = {input_share.region_memory, {.Read, .Write}}
	added.grants[builder.GRANT_OUTPUT_RING] = {output_share.ring_memory, {.Read, .Write}}
	added.grants[builder.GRANT_OUTPUT_REGION] = {output_share.region_memory, {.Read, .Write}}
	added.grants[builder.GRANT_STORAGE_SERVICE] = {places.client.service, {.Read}}
	added.grants[builder.GRANT_LOG] = {builder_log, {.Write}}
	mappings := [1]system.Mapping{{memory = builder_image_memory, address = storage.FILE_ADDRESS, first = storage_file_entry_first, page_count = storage_file_entry_pages}}
	added.mappings = mappings[:]
	values: [op.CONTEXT_VALUES]u64
	seed := builder.seed_values(sandbox.recipe_hash)
	for index in 0 ..< op.CONTEXT_VALUE_SEED_COUNT {
		values[op.CONTEXT_VALUE_SEED + index] = seed[index]
	}
	values[op.CONTEXT_VALUE_SEED_STRENGTH] = u64(op.Seed_Strength.None)
	values[builder.VALUE_STORAGE_FILE_SIZE] = storage_file_size

	// The check of the contract, on the context that the start gives: the
	// call host takes the call ring and the call region.
	holds: [op.CONTEXT_HANDLES]bool
	for grant, index in added.grants {
		holds[index] = grant.handle != 0
	}
	holds[builder.GRANT_CALL_RING] = true
	holds[builder.GRANT_CALL_REGION] = true
	if context_refusal, _ := builder.context_check(holds, values, sandbox.recipe_hash); context_refusal != .None {
		return 0, .Sandbox_Violation
	}

	connection, start_status := system.call_host_start(builder_image, builder_image_memory, file, "builder", values, &builder_load_error, added = &added)
	if start_status != .Succeeded {
		system.log_fact(.Warning, Builder_Not_Started{status = u64(start_status), stage = u64(builder_load_error.stage)})
		return 0, .Builder_Failed
	}
	// Closing each handle of the call host stops it: no handle names it then.
	defer system.call_connection_end(&connection)

	for index in 0 ..< int(sandbox.input_count) {
		input := &sandbox.inputs[index]
		builder_rows[index] = {kind_word = i64(input.kind), hash = value_kinds.Hash_Field(input.hash)}
		copy(builder_rows[index].name[:], input.name_bytes[:input.name_length])
	}
	arguments := [2]isolated.Argument {
		{table = {records = ([^]u8)(&builder_rows[0])[:int(sandbox.input_count) * size_of(pr.Recipe_Input_Row)], count = u64(sandbox.input_count)}},
		{table = {records = sandbox.arguments[:sandbox.arguments_length], count = u64(sandbox.arguments_length)}},
	}
	deadline := system.time() + builder.BUILD_TIME_BOUND_MILLISECONDS
	call_result, outcome := system.call_isolated(&connection, file, export, arguments[:], &error, deadline = deadline)
	if outcome != .Succeeded || call_result != 1 {
		system.log_fact(.Info, Builder_Call_Ended{outcome = call_outcome.Call_Outcome_Word(outcome), result = call_result, kind = error.kind})
	}
	switch {
	case outcome == .Succeeded:
		return call_result, .None
	case outcome == .Deadline_Passed_During_The_Call:
		return 0, .Builder_Timed_Out
	}
	// The builder failed, stopped, or its call did not reach it: no output
	// is kept.
	return 0, .Builder_Failed
}

// share_end ends a share: this service closes its own handles of it, and
// the storage service ends the connection, so the call host can change
// nothing after it. ended is false when the storage service did not end it.
@(private = "file")
share_end :: proc "contextless" (client: ^storage.Client, shared: ^storage.Client, number: i64) -> (ended: bool) {
	error: errors.Error_Record
	ended = storage.unshare(client, number, &error) == .Ok
	if shared.calls.head != nil {
		system.ring_close(&shared.calls)
	}
	if shared.region != nil {
		system.memory_unmap(raw_data(shared.region))
	}
	system.close(shared.ring_memory)
	system.close(shared.region_memory)
	shared^ = {}
	return ended
}

// output_freeze freezes the store "out" into the place of the objects, and
// gives the canonical bytes of its root tree. The storage service computes
// the hash; the builder gives none.
@(private = "file")
output_freeze :: proc "contextless" (places: ^Build_Places, out_payload: []u8) -> (length: int, refusal: pr.Recipe_Refusal) {
	error: errors.Error_Record
	arguments := [2]isolated.Argument{{integer = u64(places.output)}, {integer = u64(places.objects)}}
	value, hash_bytes, status, _ := storage.call(places.client, "freeze_tree", arguments[:], &error)
	if status == .Failed || value < 0 {
		return 0, recipes_core.freeze_refusal(error.kind)
	}
	if status != .Ok || len(hash_bytes) != blake3.HASH_SIZE {
		return 0, .Store_Failed
	}
	hash: blake3.Hash
	copy(hash[:], hash_bytes)
	bytes, read_refusal := objects_tree_read(hash, out_payload, places)
	if read_refusal != .None {
		return 0, .Store_Failed
	}
	if checked, tree_refusal := tree_hash.tree_hash(bytes); tree_refusal != .None || checked != hash {
		return 0, .Store_Damaged
	}
	return len(bytes), .None
}
