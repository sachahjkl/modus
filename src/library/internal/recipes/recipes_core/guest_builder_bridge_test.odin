#+build !freestanding
package recipes_core

import "core:testing"
import "modus:contract/blake3"
import "modus:contract/errors"
import "modus:contract/object_cache"
import gb "modus:contract/guest_builder"
import op "modus:contract/operation"
import pr "modus:contract/plans_recipes"
import "modus:contract/tree_hash"

// A guest that the tests script: what it does with its disks and how it
// ends, in place of a Linux kernel on Guest_Run.
@(private = "file")
Fake_Guest_Mode :: enum {
	Success,
	Nonzero_Exit,
	Damaged_Output,
	Write_Past_Bound,
	Hang,
	Interrupts_Only,
	Write_Input,
}

@(private = "file")
Fake_Object :: struct {
	key:   pr.Recipe_Input, // The kind and the hash that name the object.
	bytes: []u8,
}

@(private = "file")
Fake_Guest :: struct {
	mode:         Fake_Guest_Mode,
	output_image: []u8,
	objects:      [64]Fake_Object,
	resolves:     int,
	lie:          bool, // The backend gives the bytes of the first object for each hash.
	object_count: int,
	tamper:       bool, // The backend gives one wrong byte for each object.
	runs:         int,
	input_paths:  [8]string,
	input_count:  int,
	kept_blobs:   int,
	kept_trees:   int,
	last_tree:    blake3.Hash,
	keep_refuses: bool, // The store refuses each object of the output.
	keep_fails_after: int, // The store refuses each object past this count; 0: no bound.
	keep_known:   bool, // The store holds each object already: no keep writes.
	dropped:      int,
	prepared:     int,
	prepare_refusal: pr.Recipe_Refusal,
}

@(private = "file")
fake_drop :: proc "contextless" (hash: blake3.Hash, user_data: rawptr) {
	(^Fake_Guest)(user_data).dropped += 1
}

@(private = "file")
fake_prepare :: proc "contextless" (spec: ^gb.Guest_Build_Spec, user_data: rawptr) -> pr.Recipe_Refusal {
	fake := (^Fake_Guest)(user_data)
	fake.prepared += 1
	return fake.prepare_refusal
}

@(private = "file")
fake_keep :: proc "contextless" (kind: object_cache.Cache_Object_Kind, hash: blake3.Hash, bytes: []u8, user_data: rawptr) -> (ok: bool, written: bool) {
	fake := (^Fake_Guest)(user_data)
	if fake.keep_refuses || (fake.keep_fails_after > 0 && fake.kept_blobs + fake.kept_trees >= fake.keep_fails_after) {
		return false, false
	}
	actual, refusal := pr.recipe_hash_output(kind, bytes)
	if refusal != .None || actual != hash {
		return false, false
	}
	switch kind {
	case .Blob:
		fake.kept_blobs += 1
	case .Tree:
		fake.kept_trees += 1
		fake.last_tree = hash
	}
	return true, !fake.keep_known
}

@(private = "file")
fake_resolve :: proc "contextless" (input: ^pr.Recipe_Input, out_bytes: []u8, user_data: rawptr) -> (written: int, ok: bool) {
	fake := (^Fake_Guest)(user_data)
	fake.resolves += 1
	if fake.lie && fake.object_count > 0 {
		return copy(out_bytes, fake.objects[0].bytes), len(fake.objects[0].bytes) <= len(out_bytes)
	}
	for object in fake.objects[:fake.object_count] {
		if object.key.hash == input.hash && object.key.kind == input.kind {
			if len(object.bytes) > len(out_bytes) {
				return 0, false
			}
			count := copy(out_bytes, object.bytes)
			if fake.tamper {
				out_bytes[0] ~= 1
			}
			return count, true
		}
	}
	return 0, false
}

@(private = "file")
fake_exit :: proc "contextless" (runner: ^gb.Guest_Sandbox_Runner, status: u64) {
	registers := op.Guest_Registers{rip = 0x1000}
	gb.runner_answer_exit(runner, &registers, .Port_Write, u64(gb.Guest_Io_Port.Build_Exit_Status), 4, status, 0x1004)
}

@(private = "file")
fake_execute :: proc "contextless" (runner: ^gb.Guest_Sandbox_Runner, spec: ^gb.Guest_Build_Spec, input_disk: []u8, output_disk: []u8, user_data: rawptr) -> bool {
	fake := (^Fake_Guest)(user_data)
	fake.runs += 1
	header, refusal := gb.validate_disk_image(input_disk, .Inputs_Read_Only, 0)
	if refusal == .None {
		fake.input_count = int(header.entry_count)
		for index in 0 ..< min(int(header.entry_count), len(fake.input_paths)) {
			entry, _ := gb.disk_image_entry_at(input_disk, index)
			fake.input_paths[index] = entry.path
		}
	}
	switch fake.mode {
	case .Success:
		copy(output_disk, fake.output_image)
		fake_exit(runner, 0)
	case .Nonzero_Exit:
		copy(output_disk, fake.output_image)
		fake_exit(runner, 3)
	case .Damaged_Output:
		for &value, index in output_disk[:64] {
			value = u8(index * 7 + 1)
		}
		fake_exit(runner, 0)
	case .Write_Past_Bound:
		gb.runner_report_violation(runner, .Output_Size_Exceeded)
	case .Hang:
		for gb.runner_exit_counted(runner, .Cpuid) {
		}
	case .Interrupts_Only:
		// The clock of the system moves; the guest never exits by itself.
		now := runner.clock_nanoseconds
		for gb.runner_exit_counted(runner, .Interrupted) {
			now += 1_000_000_000
			gb.runner_clock_advance(runner, now)
		}
	case .Write_Input:
		input_disk[DISK_FIRST_PAYLOAD_PROBE] ~= 1
		copy(output_disk, fake.output_image)
		fake_exit(runner, 0)
	}
	return true
}

// A byte of the input disk past its header, which a guest can only change
// through a write that the read-only device refuses.
@(private = "file")
DISK_FIRST_PAYLOAD_PROBE :: gb.DISK_HEADER_SIZE + 8

@(private = "file")
GUEST_TEST_EPOCH :: u64(1_700_000_000)
@(private = "file")
GUEST_TEST_OUTPUT_BOUND :: u64(8192)
@(private = "file")
GUEST_TEST_DISK_BYTES :: 64 * 1024

@(private = "file")
Guest_Test :: struct {
	state:     ^Recipes_State,
	store:     ^pr.Memory_Private_Store,
	workspace: ^Guest_Builder_Workspace,
	fake:      ^Fake_Guest,
	spec:      pr.Recipe_Spec,
	guest:     gb.Guest_Build_Spec,
	blobs:     [3][16]u8,
	trees:     [2][512]u8,
	output:    [GUEST_TEST_OUTPUT_BOUND]u8,
	expected:  blake3.Hash,
}

@(private = "file")
fake_object_add :: proc(fake: ^Fake_Guest, key: pr.Recipe_Input, bytes: []u8) {
	fake.objects[fake.object_count] = {key = key, bytes = bytes}
	fake.object_count += 1
}

// guest_test_make gives a recipe of the guest builder with three inputs:
// the tree src (a.txt and sub/b.txt), the blob src-notes, whose path sorts
// before src/a.txt on the disk, and the scripted guest that runs it.
@(private = "file")
guest_test_make :: proc(mode: Fake_Guest_Mode) -> ^Guest_Test {
	test := new(Guest_Test)
	test.state = new(Recipes_State)
	test.store = recipes_test_state_init(test.state)
	test.fake = new(Fake_Guest)
	test.fake.mode = mode
	test.workspace = new(Guest_Builder_Workspace)
	test.workspace.input_disk = make([]u8, GUEST_TEST_DISK_BYTES)
	test.workspace.output_disk = make([]u8, GUEST_TEST_DISK_BYTES)
	test.workspace.input_staging = make([]u8, GUEST_TEST_DISK_BYTES)
	test.workspace.resolve_input = fake_resolve
	test.workspace.execute_guest = fake_execute
	test.workspace.keep_object = fake_keep
	test.workspace.drop_object = fake_drop
	test.workspace.prepare_guest = fake_prepare
	test.workspace.user_data = test.fake

	copy(test.blobs[0][:], "first file\n")
	copy(test.blobs[1][:], "second file\n")
	copy(test.blobs[2][:], "notes\n")
	blob_hashes: [3]blake3.Hash
	for index in 0 ..< 3 {
		blob_hashes[index] = blake3.hash(test.blobs[index][:])
		fake_object_add(test.fake, {kind = .Blob, hash = blob_hashes[index]}, test.blobs[index][:])
	}
	sub_entry, _ := tree_hash.tree_entry_make(.Object, "b.txt", blob_hashes[1])
	sub_entries := [1]tree_hash.Tree_Entry{sub_entry}
	sub_written, _ := tree_hash.tree_encode(sub_entries[:], test.trees[1][:])
	sub_hash, _ := tree_hash.tree_hash(test.trees[1][:sub_written])
	fake_object_add(test.fake, {kind = .Tree, hash = sub_hash}, test.trees[1][:sub_written])
	a_entry, _ := tree_hash.tree_entry_make(.Object, "a.txt", blob_hashes[0])
	dir_entry, _ := tree_hash.tree_entry_make(.Tree, "sub", sub_hash)
	src_entries := [2]tree_hash.Tree_Entry{a_entry, dir_entry}
	src_written, _ := tree_hash.tree_encode(src_entries[:], test.trees[0][:])
	src_hash, _ := tree_hash.tree_hash(test.trees[0][:src_written])
	fake_object_add(test.fake, {kind = .Tree, hash = src_hash}, test.trees[0][:src_written])

	test.guest.kernel_hash = blake3.hash([]u8{1})
	test.guest.root_image_hash = blake3.hash([]u8{2})
	test.guest.memory_pages = 16_384
	test.guest.output_size_bound = GUEST_TEST_OUTPUT_BOUND
	test.guest.frozen_epoch_seconds = GUEST_TEST_EPOCH
	test.guest.max_guest_exits = 8
	gb.build_spec_set_command(&test.guest, "make install DESTDIR=/outputs")
	guest_spec_set(test)

	test.spec.builder_hash = pr.guest_builder_hash()
	test.spec.output_kind = .Tree
	test.spec.source_date_unix = GUEST_TEST_EPOCH
	test.spec.output_block_limit = GUEST_TEST_OUTPUT_BOUND / gb.GUEST_PAGE_BYTES
	test.spec.input_count = 2
	test.spec.inputs[0], _ = pr.recipe_input_make("src", .Tree, src_hash)
	test.spec.inputs[1], _ = pr.recipe_input_make("src-notes", .Blob, blob_hashes[2])

	files := [2]gb.Disk_File_Input{{path = "bin/hello", content = transmute([]u8)string("#!/bin/sh\necho built\n")}, {path = "share/doc.txt", content = transmute([]u8)string("built in a guest\n")}}
	_, pack_refusal := gb.pack_disk_image(.Output_Writable, files[:], 0, test.output[:])
	assert(pack_refusal == .None)
	test.fake.output_image = test.output[:]
	workspace := new(gb.Disk_Unpack_Workspace)
	defer free(workspace)
	tree: [gb.UNPACK_NODE_BUFFER_BYTES]u8
	_, test.expected, _ = gb.unpack_output_disk(test.output[:], GUEST_TEST_OUTPUT_BOUND, workspace, tree[:])
	return test
}

// guest_spec_set writes the guest spec into the argument bytes of the recipe.
@(private = "file")
guest_spec_set :: proc(test: ^Guest_Test) {
	test.spec.arguments = {}
	written, refusal := gb.encode_build_spec(&test.guest, test.spec.arguments[:])
	assert(refusal == .None)
	test.spec.arguments_length = u32(written)
}

@(private = "file")
guest_test_end :: proc(test: ^Guest_Test) {
	delete(test.workspace.input_disk)
	delete(test.workspace.output_disk)
	delete(test.workspace.input_staging)
	free(test.workspace)
	free(test.fake)
	free(test.store)
	free(test.state)
	free(test)
}

// The refusal of a build, with nothing kept: no realisation, no output.
@(private = "file")
expect_refused :: proc(t: ^testing.T, test: ^Guest_Test, refusal: pr.Recipe_Refusal, location := #caller_location) {
	result := build_with_builders(test.state, &test.spec, .Build_Only, test.workspace)
	testing.expect_value(t, result.outcome, pr.Recipe_Build_Outcome.Refused, location)
	testing.expect_value(t, result.refusal, refusal, location)
	_, found := query_provenance(test.state, result.recipe_hash)
	testing.expect(t, !found, "a refused build keeps no realisation", loc = location)
	testing.expect_value(t, test.state.counters.local_builds, u64(0), location)
}

// Each way the guest can end a build without a clean exit status 0 refuses
// it: a status that is not 0, an output disk that is no MODGBD1 disk, a
// write past the bound of the output disk, the hang bound of the exits,
// and a write to the read-only input disk.
@(test)
guest_builder_bridge_refuses_each_bad_end_of_the_guest :: proc(t: ^testing.T) {
	cases := [?]struct {
		mode:    Fake_Guest_Mode,
		refusal: pr.Recipe_Refusal,
	}{
		{.Nonzero_Exit, .Builder_Failed},
		{.Damaged_Output, .Malformed_Output},
		{.Write_Past_Bound, .Output_Too_Large},
		{.Hang, .Build_Timed_Out},
		{.Interrupts_Only, .Build_Timed_Out},
		{.Write_Input, .Sandbox_Violation},
	}
	for each in cases {
		test := guest_test_make(each.mode)
		defer guest_test_end(test)
		expect_refused(t, test, each.refusal)
		testing.expectf(t, test.fake.runs == 1, "%v: the guest ran once", each.mode)
	}
}
// The checks before the guest runs refuse the build, and the guest never
// runs: a spec that names mounts of its own, a frozen time that is not the
// date of the recipe, an input that no store holds, an input whose bytes do
// not have its hash, an output bound past the room of the service or past
// the blocks of the recipe, and no backend for the guest.
@(test)
guest_builder_bridge_refuses_before_the_guest_runs :: proc(t: ^testing.T) {
	{
		test := guest_test_make(.Success)
		defer guest_test_end(test)
		gb.build_spec_add_input(&test.guest, "mounted", blake3.hash([]u8{9}))
		guest_spec_set(test)
		expect_refused(t, test, .Damaged_Recipe)
		testing.expect_value(t, test.fake.runs, 0)
	}
	{
		test := guest_test_make(.Success)
		defer guest_test_end(test)
		test.guest.frozen_epoch_seconds = GUEST_TEST_EPOCH + 1
		guest_spec_set(test)
		expect_refused(t, test, .Sandbox_Violation)
		testing.expect_value(t, test.fake.runs, 0)
	}
	{
		test := guest_test_make(.Success)
		defer guest_test_end(test)
		test.fake.object_count = 0
		expect_refused(t, test, .Cache_Miss)
		testing.expect_value(t, test.fake.runs, 0)
	}
	{
		test := guest_test_make(.Success)
		defer guest_test_end(test)
		test.fake.tamper = true
		expect_refused(t, test, .Hash_Mismatch)
		testing.expect_value(t, test.fake.runs, 0)
	}
	{
		test := guest_test_make(.Success)
		defer guest_test_end(test)
		whole := test.workspace.output_disk
		test.workspace.output_disk = whole[:GUEST_TEST_OUTPUT_BOUND - 1]
		expect_refused(t, test, .Output_Too_Large)
		test.workspace.output_disk = whole
		testing.expect_value(t, test.fake.runs, 0)
	}
	{
		test := guest_test_make(.Success)
		defer guest_test_end(test)
		test.spec.output_block_limit = GUEST_TEST_OUTPUT_BOUND / gb.GUEST_PAGE_BYTES - 1
		expect_refused(t, test, .Output_Too_Large)
		testing.expect_value(t, test.fake.runs, 0)
	}
	{
		test := guest_test_make(.Success)
		defer guest_test_end(test)
		result := build_with_builders(test.state, &test.spec, .Build_Only, nil)
		testing.expect_value(t, result.refusal, pr.Recipe_Refusal.Builder_Needs_Sandbox)
		testing.expect_value(t, test.fake.runs, 0)
	}
	{
		// A store that refuses the objects of the output: no realisation
		// names a tree that the store lacks.
		test := guest_test_make(.Success)
		defer guest_test_end(test)
		test.fake.keep_refuses = true
		expect_refused(t, test, .Store_Failed)
		testing.expect_value(t, test.fake.runs, 1)
	}
	// The error records of the two refusals of a guest build.
	record := recipe_refusal_record(.Output_Too_Large, 1)
	testing.expect_value(t, record.kind, i64(errors.Kind.Over_Limit))
	record = recipe_refusal_record(.Build_Timed_Out, 1)
	testing.expect_value(t, record.kind, i64(errors.Kind.No_Answer))
}

// The successful case last: the inputs reach the guest as one sorted
// read-only disk (the blob src-notes, then each file of the tree src under
// its path), the guest writes its output disk and exits with 0, the
// realisation names the tree hash of that disk, and the next build of the
// recipe takes it from the cache with no guest.
@(test)
guest_builder_bridge_builds_and_keeps_the_realisation :: proc(t: ^testing.T) {
	test := guest_test_make(.Success)
	defer guest_test_end(test)
	result := build_with_builders(test.state, &test.spec, .Build_Only, test.workspace)
	testing.expect_value(t, result.refusal, pr.Recipe_Refusal.None)
	testing.expect_value(t, result.outcome, pr.Recipe_Build_Outcome.Built_Locally)
	testing.expect_value(t, result.output_hash, test.expected)
	testing.expect_value(t, test.fake.input_count, 3)
	testing.expect_value(t, test.fake.input_paths[0], "src-notes")
	testing.expect_value(t, test.fake.input_paths[1], "src/a.txt")
	testing.expect_value(t, test.fake.input_paths[2], "src/sub/b.txt")
	testing.expect_value(t, test.workspace.last_guest_state, gb.Guest_Build_State.Succeeded)
	// Each file and each directory of the output is kept by its hash, the
	// root last: two files, the directories bin and share, and the root.
	testing.expect_value(t, test.fake.kept_blobs, 2)
	testing.expect_value(t, test.fake.kept_trees, 3)
	testing.expect_value(t, test.fake.last_tree, test.expected)
	slot, found := query_provenance(test.state, result.recipe_hash)
	testing.expect(t, found && slot.origin == .Local_Build && slot.record.output_hash == test.expected)
	again := build_with_builders(test.state, &test.spec, .Cache_First, test.workspace)
	testing.expect_value(t, again.outcome, pr.Recipe_Build_Outcome.From_Cache)
	testing.expect_value(t, again.output_hash, test.expected)
	testing.expect_value(t, test.fake.runs, 1)
}
// A failed keep of the output removes each object that this build wrote,
// and none that the store held before: a failed build keeps nothing, and
// takes nothing from another realisation.
@(test)
guest_builder_bridge_failed_keep_keeps_nothing :: proc(t: ^testing.T) {
	{
		test := guest_test_make(.Success)
		defer guest_test_end(test)
		test.fake.keep_fails_after = 2
		expect_refused(t, test, .Store_Failed)
		testing.expect_value(t, test.fake.dropped, 2)
	}
	{
		test := guest_test_make(.Success)
		defer guest_test_end(test)
		test.fake.keep_fails_after = 2
		test.fake.keep_known = true
		expect_refused(t, test, .Store_Failed)
		testing.expect_value(t, test.fake.dropped, 0)
	}
}

// The backend prepares the guest before any input is read: a kernel or an
// initial archive that the store lacks gives Cache_Miss, and a guest that
// asks for more memory than the service has gives Memory_Past_Bound, with
// no input read, nothing packed and no run.
@(test)
guest_builder_bridge_prepares_the_guest_before_the_inputs :: proc(t: ^testing.T) {
	for refusal in ([?]pr.Recipe_Refusal{.Cache_Miss, .Memory_Past_Bound}) {
		test := guest_test_make(.Success)
		defer guest_test_end(test)
		test.fake.prepare_refusal = refusal
		expect_refused(t, test, refusal)
		testing.expect_value(t, test.fake.prepared, 1)
		testing.expect_value(t, test.fake.resolves, 0)
		testing.expect_value(t, test.fake.runs, 0)
	}
	record := recipe_refusal_record(.Memory_Past_Bound, 1)
	testing.expect_value(t, record.kind, i64(errors.Kind.Over_Limit))
	record = recipe_refusal_record(.Builder_Busy, 1)
	testing.expect_value(t, record.kind, i64(errors.Kind.Busy))
}

// Edge_Test holds the heap buffers of the trees that one edge test makes.
@(private = "file")
Edge_Test :: struct {
	test:    ^Guest_Test,
	buffers: [dynamic][]u8,
}

@(private = "file")
edge_make :: proc(staging_bytes: int = GUEST_TEST_DISK_BYTES, disk_bytes: int = GUEST_TEST_DISK_BYTES) -> ^Edge_Test {
	edge := new(Edge_Test)
	edge.test = guest_test_make(.Success)
	delete(edge.test.workspace.input_staging)
	delete(edge.test.workspace.input_disk)
	edge.test.workspace.input_staging = make([]u8, staging_bytes)
	edge.test.workspace.input_disk = make([]u8, disk_bytes)
	return edge
}

@(private = "file")
edge_end :: proc(edge: ^Edge_Test) {
	for buffer in edge.buffers {
		delete(buffer)
	}
	delete(edge.buffers)
	guest_test_end(edge.test)
	free(edge)
}

// edge_tree encodes a tree of entries, adds it to the objects of the fake
// guest, and gives its hash.
@(private = "file")
edge_tree :: proc(edge: ^Edge_Test, entries: []tree_hash.Tree_Entry) -> blake3.Hash {
	bytes := make([]u8, tree_hash.HEADER_SIZE + len(entries) * tree_hash.ENTRY_SIZE)
	append(&edge.buffers, bytes)
	written, refusal := tree_hash.tree_encode(entries, bytes)
	assert(refusal == .None)
	hash, _ := tree_hash.tree_hash(bytes[:written])
	fake_object_add(edge.test.fake, {kind = .Tree, hash = hash}, bytes[:written])
	return hash
}

@(private = "file")
edge_blob :: proc(edge: ^Edge_Test, text: string) -> blake3.Hash {
	bytes := make([]u8, len(text))
	append(&edge.buffers, bytes)
	copy(bytes, text)
	hash := blake3.hash(bytes)
	fake_object_add(edge.test.fake, {kind = .Blob, hash = hash}, bytes)
	return hash
}

// edge_name gives a name of length bytes that sorts by index.
@(private = "file")
edge_name :: proc(prefix: string, index: int, length: int) -> string {
	name := make([]u8, length, context.temp_allocator)
	for &value in name {
		value = 'n'
	}
	copy(name, prefix)
	digits := "0123456789"
	place := length - 1
	for rest := index; place >= len(prefix); place -= 1 {
		name[place] = digits[rest % 10]
		rest /= 10
	}
	return string(name)
}

// edge_inputs makes the recipe take only the inputs given.
@(private = "file")
edge_inputs :: proc(edge: ^Edge_Test, inputs: ..pr.Recipe_Input) {
	spec := &edge.test.spec
	spec.inputs = {}
	spec.input_count = u32(len(inputs))
	for input, index in inputs {
		spec.inputs[index] = input
	}
}

// The depth of the trees of an input: a file in the seventh tree under the
// input has a path of 8 segments, the most of a disk, and builds; one tree
// more is refused before the guest runs.
@(test)
guest_builder_bridge_input_tree_depth :: proc(t: ^testing.T) {
	for levels in ([?]int{7, 8}) {
		edge := edge_make()
		defer edge_end(edge)
		blob := edge_blob(edge, "deep\n")
		file_entry, _ := tree_hash.tree_entry_make(.Object, "f", blob)
		entries := [1]tree_hash.Tree_Entry{file_entry}
		hash := edge_tree(edge, entries[:])
		for _ in 1 ..< levels {
			dir_entry, _ := tree_hash.tree_entry_make(.Tree, "d", hash)
			dirs := [1]tree_hash.Tree_Entry{dir_entry}
			hash = edge_tree(edge, dirs[:])
		}
		input, _ := pr.recipe_input_make("s", .Tree, hash)
		edge_inputs(edge, input)
		if levels == 7 {
			result := build_with_builders(edge.test.state, &edge.test.spec, .Build_Only, edge.test.workspace)
			testing.expect_value(t, result.refusal, pr.Recipe_Refusal.None)
			testing.expect_value(t, edge.test.fake.input_paths[0], "s/d/d/d/d/d/d/f")
		} else {
			expect_refused(t, edge.test, .Invalid_Input_Name)
			testing.expect_value(t, edge.test.fake.runs, 0)
		}
	}
}

// A tree whose bytes name its own hash cannot exist: its bytes would need
// that hash. A store that gives such bytes anyway gives bytes that do not
// have their hash, and the walk ends with Hash_Mismatch at once, with no
// loop.
@(test)
guest_builder_bridge_input_cycle_ends :: proc(t: ^testing.T) {
	edge := edge_make()
	defer edge_end(edge)
	claimed := blake3.hash([]u8{'c', 'y', 'c', 'l', 'e'})
	self_entry, _ := tree_hash.tree_entry_make(.Tree, "again", claimed)
	entries := [1]tree_hash.Tree_Entry{self_entry}
	edge.test.fake.object_count = 0
	_ = edge_tree(edge, entries[:])
	edge.test.fake.lie = true
	input, _ := pr.recipe_input_make("s", .Tree, claimed)
	edge_inputs(edge, input)
	expect_refused(t, edge.test, .Hash_Mismatch)
	testing.expect_value(t, edge.test.fake.resolves, 1)
	testing.expect_value(t, edge.test.fake.runs, 0)
}

// The files of one input disk: 4096 build, 4097 are refused. The 4096 are
// 8 directories that name one tree of 512 files of one blob.
@(test)
guest_builder_bridge_input_file_count :: proc(t: ^testing.T) {
	for extra in ([?]bool{false, true}) {
		edge := edge_make(4 * 1024 * 1024, 4 * 1024 * 1024)
		defer edge_end(edge)
		blob := edge_blob(edge, "x")
		files: [tree_hash.MAX_TREE_ENTRIES]tree_hash.Tree_Entry
		for &entry, index in files {
			entry, _ = tree_hash.tree_entry_make(.Object, edge_name("f", index, 4), blob)
		}
		leaf := edge_tree(edge, files[:])
		dirs: [8]tree_hash.Tree_Entry
		for &entry, index in dirs {
			entry, _ = tree_hash.tree_entry_make(.Tree, edge_name("d", index, 2), leaf)
		}
		root := edge_tree(edge, dirs[:])
		tree_input, _ := pr.recipe_input_make("s", .Tree, root)
		if extra {
			one_more, _ := pr.recipe_input_make("t", .Blob, blob)
			edge_inputs(edge, tree_input, one_more)
			expect_refused(t, edge.test, .Too_Many_Inputs)
			testing.expect_value(t, edge.test.fake.runs, 0)
		} else {
			edge_inputs(edge, tree_input)
			result := build_with_builders(edge.test.state, &edge.test.spec, .Build_Only, edge.test.workspace)
			testing.expect_value(t, result.refusal, pr.Recipe_Refusal.None)
			testing.expect_value(t, edge.test.fake.input_count, gb.MAX_DISK_ENTRIES)
		}
	}
}

// The arena of the paths fills before the count of the files does: 512
// directories that each name a tree of 512 empty directories with long
// names make more path bytes than the arena holds, and the walk stops
// with Too_Many_Inputs, with no file and no run.
@(test)
guest_builder_bridge_input_path_arena_full :: proc(t: ^testing.T) {
	edge := edge_make(4 * 1024 * 1024)
	defer edge_end(edge)
	empty := edge_tree(edge, nil)
	inner: [tree_hash.MAX_TREE_ENTRIES]tree_hash.Tree_Entry
	for &entry, index in inner {
		entry, _ = tree_hash.tree_entry_make(.Tree, edge_name("i", index, 60), empty)
	}
	middle := edge_tree(edge, inner[:])
	outer: [tree_hash.MAX_TREE_ENTRIES]tree_hash.Tree_Entry
	for &entry, index in outer {
		entry, _ = tree_hash.tree_entry_make(.Tree, edge_name("o", index, 60), middle)
	}
	root := edge_tree(edge, outer[:])
	input, _ := pr.recipe_input_make("s", .Tree, root)
	edge_inputs(edge, input)
	expect_refused(t, edge.test, .Too_Many_Inputs)
	testing.expect_value(t, edge.test.fake.runs, 0)
	// The arena holds fewer paths than the 262 656 directories of the input.
	testing.expect(t, edge.test.fake.resolves < INPUT_PATH_ARENA_BYTES / 64, "the walk stops when the arena is full")
}

// A path of 124 bytes, the most of a disk, builds; 125 bytes are refused.
@(test)
guest_builder_bridge_input_path_length :: proc(t: ^testing.T) {
	for last in ([?]int{57, 58}) {
		edge := edge_make()
		defer edge_end(edge)
		blob := edge_blob(edge, "long\n")
		file_entry, _ := tree_hash.tree_entry_make(.Object, edge_name("f", 0, last), blob)
		files := [1]tree_hash.Tree_Entry{file_entry}
		inner := edge_tree(edge, files[:])
		dir_entry, _ := tree_hash.tree_entry_make(.Tree, edge_name("d", 0, 64), inner)
		dirs := [1]tree_hash.Tree_Entry{dir_entry}
		root := edge_tree(edge, dirs[:])
		input, _ := pr.recipe_input_make("s", .Tree, root)
		edge_inputs(edge, input)
		if last == 57 {
			result := build_with_builders(edge.test.state, &edge.test.spec, .Build_Only, edge.test.workspace)
			testing.expect_value(t, result.refusal, pr.Recipe_Refusal.None)
			testing.expect_value(t, len(edge.test.fake.input_paths[0]), gb.MAX_MOUNT_PATH_BYTES)
		} else {
			expect_refused(t, edge.test, .Invalid_Input_Name)
			testing.expect_value(t, edge.test.fake.runs, 0)
		}
	}
}

// Two inputs that would give one path are two inputs with one name: the
// recipe is refused before any input is read. A staging too small for an
// input refuses it as a miss, with no run.
@(test)
guest_builder_bridge_input_duplicate_and_full_staging :: proc(t: ^testing.T) {
	{
		edge := edge_make()
		defer edge_end(edge)
		blob := edge_blob(edge, "same\n")
		first, _ := pr.recipe_input_make("a", .Blob, blob)
		other := edge_blob(edge, "other\n")
		second, _ := pr.recipe_input_make("a", .Blob, other)
		edge_inputs(edge, first, second)
		result := build_with_builders(edge.test.state, &edge.test.spec, .Build_Only, edge.test.workspace)
		testing.expect_value(t, result.refusal, pr.Recipe_Refusal.Duplicate_Input)
		testing.expect_value(t, edge.test.fake.resolves, 0)
		testing.expect_value(t, edge.test.fake.runs, 0)
	}
	{
		edge := edge_make(4)
		defer edge_end(edge)
		blob := edge_blob(edge, "five!")
		input, _ := pr.recipe_input_make("a", .Blob, blob)
		edge_inputs(edge, input)
		expect_refused(t, edge.test, .Cache_Miss)
		testing.expect_value(t, edge.test.fake.runs, 0)
	}
}
