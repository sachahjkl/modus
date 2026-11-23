// Bridge connecting recipes_core to the sandboxed guest builder contract
// (src/md/features/recipes.md, "The three kinds of builder").
//
// When a recipe names plans_recipes.guest_builder_hash() as its builder, this
// pure freestanding bridge:
//   - validates the sandbox invariants and decodes the canonical
//     guest_builder.Guest_Build_Spec from sandbox.arguments;
//   - verifies frozen epoch time matches sandbox.frozen_date_unix, and
//     refuses an output size bound past the blocks of the recipe;
//   - asks the backend to prepare the guest (its kernel and its initial
//     archive in memory, its memory against the budget) before any input
//     is read;
//   - resolves and hash-verifies every read-only recipe input, a Blob as one
//     file under its name and a Tree as each of its files under its path,
//     and packs them, sorted, into a sector-aligned read-only MODGBD1 disk;
//   - zeroes a blank writable output disk and prepares Guest_Sandbox_Runner;
//   - invokes the caller's guest execution backend (real Guest_Run on modus,
//     software_machine or scripted exits in host tests);
//   - verifies input disk immutability, exit code 0, hang bound, and zero
//     sandbox violations, then unpacks the output disk into canonical MODTREE1
//     bytes and verifies its exact recursive tree_hash.
package recipes_core

import "modus:contract/blake3"
import gb "modus:contract/guest_builder"
import "modus:contract/object_cache"
import pr "modus:contract/plans_recipes"
import "modus:contract/tree_hash"

// The bytes of the paths of the files of one input disk, and of the
// directories that lead to them.
INPUT_PATH_ARENA_BYTES :: 2 * gb.MAX_DISK_ENTRIES * gb.MAX_MOUNT_PATH_BYTES

// Callback that resolves one recipe input payload by hash into out_bytes.
// The bridge re-hashes the returned bytes against input.hash before packing.
Guest_Input_Resolve_Proc :: #type proc "contextless" (
	input: ^pr.Recipe_Input,
	out_bytes: []u8,
	user_data: rawptr,
) -> (written: int, ok: bool)

// Callback that boots and runs the guest on a prepared Guest_Sandbox_Runner
// with the verified read-only MODGBD1 input disk and blank writable output
// disk, driving exits until the runner ends.
Guest_Execute_Proc :: #type proc "contextless" (
	runner: ^gb.Guest_Sandbox_Runner,
	spec: ^gb.Guest_Build_Spec,
	input_disk: []u8,
	output_disk: []u8,
	user_data: rawptr,
) -> bool

// Callback that keeps one object of the output of a guest build by its
// hash: a file of the output disk, or a directory node of its tree. A
// backend that keeps them lets a later build take the output as an input.
// written is true when the object was not in the store before: only such
// an object is dropped again when the build fails.
Guest_Object_Keep_Proc :: #type proc "contextless" (
	kind: object_cache.Cache_Object_Kind,
	hash: blake3.Hash,
	bytes: []u8,
	user_data: rawptr,
) -> (ok: bool, written: bool)

// Callback that removes an object that this build wrote, when the build
// fails after it: a failed build keeps nothing.
Guest_Object_Drop_Proc :: #type proc "contextless" (hash: blake3.Hash, user_data: rawptr)

// Callback that prepares the guest of a decoded spec before any input is
// read: the backend reads the kernel and the initial archive that the spec
// names, and checks the memory of the guest against what it can pay. Its
// refusal ends the build with nothing packed and nothing run.
Guest_Prepare_Proc :: #type proc "contextless" (spec: ^gb.Guest_Build_Spec, user_data: rawptr) -> pr.Recipe_Refusal

// The objects that one guest build may write: each file of its output disk
// and each directory node of its tree, the root included.
GUEST_KEPT_OBJECTS_MOST :: 2 * gb.MAX_DISK_ENTRIES + 1

// Caller-supplied zero-allocation workspace and backend for guest builds.
Guest_Builder_Workspace :: struct {
	runner:                gb.Guest_Sandbox_Runner,
	unpack_workspace:      gb.Disk_Unpack_Workspace,
	input_files:           [gb.MAX_DISK_ENTRIES]gb.Disk_File_Input,
	input_paths:           [INPUT_PATH_ARENA_BYTES]u8,
	input_disk:            []u8, // Backing buffer for the packed read-only MODGBD1 input disk.
	output_disk:           []u8, // Backing buffer for the blank writable output disk.
	input_staging:         []u8, // Scratch buffer for resolved input payloads not in state.objects.
	resolve_input:         Guest_Input_Resolve_Proc,
	execute_guest:         Guest_Execute_Proc,
	keep_object:           Guest_Object_Keep_Proc, // nil: the objects of the output are not kept.
	drop_object:           Guest_Object_Drop_Proc, // With keep_object: removes an object that a failed build wrote.
	prepare_guest:         Guest_Prepare_Proc, // nil: the backend reads the kernel at its run.
	user_data:             rawptr,
	kept:                  [GUEST_KEPT_OBJECTS_MOST]blake3.Hash, // The objects that this build wrote, in order.
	kept_count:            int,
	last_refusal:          pr.Recipe_Refusal,
	last_guest_refusal:    gb.Guest_Builder_Refusal,
	last_guest_state:      gb.Guest_Build_State,
	last_guest_exit:       u32,
	last_output_disk_hash: blake3.Hash,
}

// What the walk of the inputs has written so far.
@(private = "file")
Input_Collector :: struct {
	state:        ^Recipes_State,
	workspace:    ^Guest_Builder_Workspace,
	file_count:   int,
	path_used:    int,
	staging_used: int,
}

// input_resolve gives the bytes of one object by its kind and hash: from the
// memory of the service, else from the backend into the staging, and checks
// them against the hash before any use.
@(private = "file")
input_resolve :: proc "contextless" (collector: ^Input_Collector, request: ^pr.Recipe_Input) -> (bytes: []u8, refusal: pr.Recipe_Refusal) {
	workspace := collector.workspace
	found := false
	if collector.state != nil {
		if slot := find_local_object(collector.state, request.hash); slot != nil && slot.kind == request.kind {
			bytes = slot.payload[:slot.length]
			found = true
		}
	}
	if !found {
		if workspace.resolve_input == nil {
			return nil, .Cache_Miss
		}
		room := workspace.input_staging[collector.staging_used:]
		count, resolved := workspace.resolve_input(request, room, workspace.user_data)
		if !resolved || count < 0 || count > len(room) {
			return nil, .Cache_Miss
		}
		bytes = room[:count]
		collector.staging_used += count
	}
	actual, hash_refusal := pr.recipe_hash_output(request.kind, bytes)
	if hash_refusal != .None || actual != request.hash {
		return nil, .Hash_Mismatch
	}
	return bytes, .None
}

// input_path_join writes prefix, then "/" when prefix is not empty, then
// name, in the arena of the paths.
@(private = "file")
input_path_join :: proc "contextless" (collector: ^Input_Collector, prefix: []u8, name: []u8) -> (path: []u8, refusal: pr.Recipe_Refusal) {
	length := len(prefix) + len(name) + (len(prefix) > 0 ? 1 : 0)
	if length > gb.MAX_MOUNT_PATH_BYTES {
		return nil, .Invalid_Input_Name
	}
	arena := collector.workspace.input_paths[:]
	if length > len(arena) - collector.path_used {
		return nil, .Too_Many_Inputs
	}
	start := collector.path_used
	place := start + copy(arena[start:], prefix)
	if len(prefix) > 0 {
		arena[place] = '/'
		place += 1
	}
	place += copy(arena[place:], name)
	collector.path_used = place
	return arena[start:place], .None
}

@(private = "file")
input_file_add :: proc "contextless" (collector: ^Input_Collector, path: []u8, content: []u8) -> pr.Recipe_Refusal {
	if collector.file_count >= gb.MAX_DISK_ENTRIES {
		return .Too_Many_Inputs
	}
	collector.workspace.input_files[collector.file_count] = {path = string(path), content = content}
	collector.file_count += 1
	return .None
}

// input_tree_collect adds each file of a tree under prefix. A tree deeper
// than the paths of a disk allow is refused, so a cycle of hashes ends too.
@(private = "file")
input_tree_collect :: proc "contextless" (collector: ^Input_Collector, prefix: []u8, tree_bytes: []u8, depth: int) -> pr.Recipe_Refusal {
	if depth >= gb.MAX_PATH_DEPTH {
		return .Invalid_Input_Name
	}
	count, tree_refusal := tree_hash.tree_validate(tree_bytes)
	if tree_refusal != .None {
		return .Malformed_Output
	}
	for index in 0 ..< count {
		entry, ok := tree_hash.tree_entry_at(tree_bytes, index)
		if !ok {
			return .Malformed_Output
		}
		path, path_refusal := input_path_join(collector, prefix, entry.name[:entry.name_length])
		if path_refusal != .None {
			return path_refusal
		}
		switch entry.kind {
		case .Object:
			request := pr.Recipe_Input{kind = .Blob, hash = entry.hash}
			bytes, refusal := input_resolve(collector, &request)
			if refusal != .None {
				return refusal
			}
			if added := input_file_add(collector, path, bytes); added != .None {
				return added
			}
		case .Tree:
			request := pr.Recipe_Input{kind = .Tree, hash = entry.hash}
			bytes, refusal := input_resolve(collector, &request)
			if refusal != .None {
				return refusal
			}
			if nested := input_tree_collect(collector, path, bytes, depth + 1); nested != .None {
				return nested
			}
		}
	}
	return .None
}

// input_files_sort sorts the files by the bytes of their whole paths, the
// order of a MODGBD1 disk, which is not the order of the names of a tree:
// "a-b" sorts before "a/c". A heap sort keeps the work at n log n with no
// memory.
@(private = "file")
input_files_sort :: proc "contextless" (files: []gb.Disk_File_Input) {
	less :: proc "contextless" (left, right: gb.Disk_File_Input) -> bool {
		return gb.compare_path_bytes(transmute([]u8)left.path, transmute([]u8)right.path) < 0
	}
	sift :: proc "contextless" (files: []gb.Disk_File_Input, start, end: int) {
		root := start
		for {
			child := 2 * root + 1
			if child >= end {
				return
			}
			if child + 1 < end && less(files[child], files[child + 1]) {
				child += 1
			}
			if !less(files[root], files[child]) {
				return
			}
			files[root], files[child] = files[child], files[root]
			root = child
		}
	}
	for start := len(files) / 2 - 1; start >= 0; start -= 1 {
		sift(files, start, len(files))
	}
	for end := len(files) - 1; end > 0; end -= 1 {
		files[0], files[end] = files[end], files[0]
		sift(files, 0, end)
	}
}

@(private = "file")
Output_Keep :: struct {
	workspace: ^Guest_Builder_Workspace,
}

@(private = "file")
output_object_keep :: proc "contextless" (kind: tree_hash.Tree_Entry_Kind, hash: blake3.Hash, bytes: []u8, user_data: rawptr) -> bool {
	keep := (^Output_Keep)(user_data)
	workspace := keep.workspace
	object_kind := object_cache.Cache_Object_Kind.Blob
	switch kind {
	case .Object:
		object_kind = .Blob
	case .Tree:
		object_kind = .Tree
	}
	if workspace.kept_count >= len(workspace.kept) {
		return false
	}
	ok, written := workspace.keep_object(object_kind, hash, bytes, workspace.user_data)
	if written {
		// Recorded even when the keep failed: a write that failed part way
		// may have left the object.
		workspace.kept[workspace.kept_count] = hash
		workspace.kept_count += 1
	}
	return ok
}

// kept_objects_drop removes each object that this build wrote, last first,
// so a failed build leaves the store as it found it.
@(private = "file")
kept_objects_drop :: proc "contextless" (workspace: ^Guest_Builder_Workspace) {
	if workspace.drop_object != nil {
		for index := workspace.kept_count - 1; index >= 0; index -= 1 {
			workspace.drop_object(workspace.kept[index], workspace.user_data)
		}
	}
	workspace.kept_count = 0
}

@(private = "file")
Dispatch_Call :: struct {
	state:   ^Recipes_State,
	guest:   ^Guest_Builder_Workspace,
	refusal: pr.Recipe_Refusal,
}

// recipe_refusal_of_guest_refusal maps a guest builder refusal, sandbox
// violation, or timeout into the closed Recipe_Refusal enum.
recipe_refusal_of_guest_refusal :: proc "contextless" (
	refusal: gb.Guest_Builder_Refusal,
	violation: gb.Sandbox_Violation_Kind = .None,
	timed_out: bool = false,
) -> pr.Recipe_Refusal {
	if timed_out {
		return .Builder_Timed_Out
	}
	switch violation {
	case .None:
	case .Read_Only_Disk_Write, .Network_Access_Attempt:
		return .Sandbox_Violation
	case .Output_Size_Exceeded:
		return .Output_Too_Large
	}
	switch refusal {
	case .None:
		return .None
	case .Network_Forbidden, .Real_Clock_Forbidden, .Writable_Input_Forbidden:
		return .Sandbox_Violation
	case .Output_Too_Large:
		return .Output_Too_Large
	case .Malformed_Disk_Image, .Output_Extraction_Failed:
		return .Malformed_Output
	case .Nonzero_Guest_Exit:
		return .Builder_Failed
	case .Memory_Past_Bound:
		return .Memory_Past_Bound
	case .Cancelled:
		return .Build_Cancelled
	case .Zero_Kernel_Hash, .Zero_Root_Image_Hash, .Empty_Command, .Command_Too_Long, .Invalid_Command_Text, .Too_Many_Inputs, .Duplicate_Input_Mount, .Invalid_Mount_Path, .Memory_Too_Small, .Initial_Archive_Too_Large, .Initial_Archive_Size_Invalid, .Initial_Archive_Mismatch, .Time_Bound_Past_Most:
		return .Damaged_Recipe
	}
	return .Builder_Failed
}

// guest_builder_build executes one guest builder recipe end to end inside the
// validated sandbox, and gives the canonical MODTREE1 bytes of the output in
// out_payload on a clean exit code 0 with zero sandbox violations and each
// object of the output kept. A refusal gives written 0: out_payload may hold
// the bytes of an unpack that a later step refused, which the caller never
// reads.
guest_builder_build :: proc "contextless" (
	state: ^Recipes_State,
	workspace: ^Guest_Builder_Workspace,
	sandbox: ^pr.Builder_Sandbox_Spec,
	out_payload: []u8,
) -> (written: int, refusal: pr.Recipe_Refusal) {
	if sandbox == nil {
		return 0, .Builder_Failed
	}
	if sandbox.builder_hash != pr.guest_builder_hash() {
		return 0, .Builder_Needs_Sandbox
	}
	if workspace == nil || workspace.execute_guest == nil {
		return 0, .Builder_Needs_Sandbox
	}
	workspace.last_refusal = .None
	workspace.last_guest_refusal = .None
	workspace.last_guest_state = {}
	workspace.last_guest_exit = 0
	workspace.last_output_disk_hash = {}
	workspace.kept_count = 0

	fail :: proc "contextless" (workspace: ^Guest_Builder_Workspace, recipe_refusal: pr.Recipe_Refusal, guest_refusal: gb.Guest_Builder_Refusal = .None) -> (int, pr.Recipe_Refusal) {
		workspace.last_refusal = recipe_refusal
		workspace.last_guest_refusal = guest_refusal
		return 0, recipe_refusal
	}

	if sandbox.allow_network || sandbox.allow_root_ring || !sandbox.inputs_read_only || !sandbox.output_store_empty || sandbox.random_seed != sandbox.recipe_hash {
		return fail(workspace, .Sandbox_Violation)
	}
	if sandbox.output_kind != .Tree {
		return fail(workspace, .Bad_Output_Kind)
	}
	if sandbox.input_count > pr.MAX_RECIPE_INPUTS {
		return fail(workspace, .Too_Many_Inputs)
	}

	guest_spec, spec_refusal := gb.decode_build_spec(sandbox.arguments[:sandbox.arguments_length])
	if spec_refusal != .None {
		return fail(workspace, recipe_refusal_of_guest_refusal(spec_refusal), spec_refusal)
	}
	if guest_spec.frozen_epoch_seconds != sandbox.frozen_date_unix {
		return fail(workspace, .Sandbox_Violation, .Real_Clock_Forbidden)
	}
	// The blocks of the recipe bound its output: a spec whose output disk
	// passes them is refused, never cut. A block limit of 0 sets no bound
	// of the recipe, and the bound of the spec holds alone. A limit whose
	// bytes pass the range of a u64 holds any spec.
	if sandbox.output_block_limit > 0 && sandbox.output_block_limit <= max(u64) / gb.GUEST_PAGE_BYTES {
		if guest_spec.output_size_bound > sandbox.output_block_limit * gb.GUEST_PAGE_BYTES {
			return fail(workspace, .Output_Too_Large, .Output_Too_Large)
		}
	}
	// The inputs of the recipe are the mounts of the guest: a spec that names
	// its own would give the guest two sources of one disk.
	if guest_spec.input_count != 0 {
		return fail(workspace, .Damaged_Recipe, .Too_Many_Inputs)
	}

	// The kernel, the initial archive and the memory of the guest, before
	// any input is read or packed: a build that cannot run costs no disk.
	// The backend sizes the buffers of the build here, from the spec and
	// its budget: the output disk is checked after it.
	if workspace.prepare_guest != nil {
		if prepared := workspace.prepare_guest(&guest_spec, workspace.user_data); prepared != .None {
			return fail(workspace, prepared)
		}
	}
	if u64(len(workspace.output_disk)) < guest_spec.output_size_bound {
		return fail(workspace, .Output_Too_Large, .Output_Too_Large)
	}

	// Resolve and hash-verify every input before packing the read-only input disk.
	collector := Input_Collector{state = state, workspace = workspace}
	for index in u32(0) ..< sandbox.input_count {
		item := &sandbox.inputs[index]
		bytes, resolve_refusal := input_resolve(&collector, item)
		if resolve_refusal != .None {
			return fail(workspace, resolve_refusal)
		}
		name := item.name_bytes[:item.name_length]
		switch item.kind {
		case .Blob:
			path, path_refusal := input_path_join(&collector, nil, name)
			if path_refusal == .None {
				path_refusal = input_file_add(&collector, path, bytes)
			}
			if path_refusal != .None {
				return fail(workspace, path_refusal)
			}
		case .Tree:
			if tree_refusal := input_tree_collect(&collector, name, bytes, 1); tree_refusal != .None {
				return fail(workspace, tree_refusal)
			}
		}
	}
	files := workspace.input_files[:collector.file_count]
	input_files_sort(files)

	// Pack read-only inputs into a sector-aligned MODGBD1 input disk.
	required, size_ok := gb.disk_image_required_size(files)
	if !size_ok {
		return fail(workspace, .Buffer_Too_Small)
	}
	sector_mask := u64(gb.DISK_SECTOR_SIZE - 1)
	if required > max(u64) - sector_mask {
		return fail(workspace, .Buffer_Too_Small)
	}
	disk_bytes := max(u64(gb.DISK_SECTOR_SIZE), (required + sector_mask) &~ sector_mask)
	if disk_bytes > u64(len(workspace.input_disk)) {
		return fail(workspace, .Buffer_Too_Small)
	}
	input_slice := workspace.input_disk[:disk_bytes]
	for &value in input_slice {
		value = 0
	}
	_, pack_refusal := gb.pack_input_disk(files, guest_spec.frozen_epoch_seconds, input_slice)
	if pack_refusal != .None {
		return fail(workspace, recipe_refusal_of_guest_refusal(pack_refusal), pack_refusal)
	}
	input_hash_before := blake3.hash(input_slice)

	// Prepare blank output disk and sandbox runner.
	output_slice := workspace.output_disk[:guest_spec.output_size_bound]
	prep_refusal := gb.runner_prepare(&workspace.runner, &guest_spec, nil, input_slice, output_slice)
	if prep_refusal != .None {
		return fail(workspace, recipe_refusal_of_guest_refusal(prep_refusal), prep_refusal)
	}
	start_refusal := gb.runner_start(&workspace.runner)
	if start_refusal != .None {
		return fail(workspace, recipe_refusal_of_guest_refusal(start_refusal), start_refusal)
	}

	exec_ok := workspace.execute_guest(&workspace.runner, &guest_spec, input_slice, output_slice, workspace.user_data)
	workspace.last_guest_state = workspace.runner.state
	workspace.last_guest_exit = workspace.runner.guest_exit_code
	workspace.last_output_disk_hash = blake3.hash(output_slice)

	// Verify the read-only input disk remained bit-for-bit identical.
	if blake3.hash(input_slice) != input_hash_before {
		gb.runner_report_violation(&workspace.runner, .Read_Only_Disk_Write)
		workspace.last_guest_state = workspace.runner.state
		return fail(workspace, .Sandbox_Violation, .Writable_Input_Forbidden)
	}
	if !exec_ok && workspace.runner.state == .Running {
		workspace.runner.state = .Failed
		workspace.last_guest_state = .Failed
		return fail(workspace, .Builder_Failed, .Nonzero_Guest_Exit)
	}

	if workspace.runner.state == .Timed_Out {
		return fail(workspace, .Builder_Timed_Out, .Nonzero_Guest_Exit)
	}

	tree_digest, tree_written, finish_refusal := gb.runner_finish(&workspace.runner, &workspace.unpack_workspace, out_payload)
	workspace.last_guest_state = workspace.runner.state
	if finish_refusal != .None || workspace.runner.state != .Succeeded {
		mapped := recipe_refusal_of_guest_refusal(finish_refusal, workspace.runner.last_violation, workspace.runner.state == .Timed_Out)
		return fail(workspace, mapped, finish_refusal)
	}

	recomputed, tree_refusal := tree_hash.tree_hash(out_payload[:tree_written])
	if tree_refusal != .None || recomputed != tree_digest {
		return fail(workspace, .Hash_Mismatch, .Output_Extraction_Failed)
	}
	// The files and the directory nodes of the output, each by its hash,
	// before the realisation names them: a realisation never names an
	// object that the store lacks.
	if workspace.keep_object != nil {
		keep := Output_Keep{workspace = workspace}
		_, kept_digest, keep_refusal := gb.unpack_output_disk_visit(output_slice, guest_spec.output_size_bound, &workspace.unpack_workspace, out_payload, {visit = output_object_keep, user_data = &keep})
		if keep_refusal != .None || kept_digest != tree_digest {
			kept_objects_drop(workspace)
			return fail(workspace, .Store_Failed, keep_refusal)
		}
	}
	return tree_written, .None
}

// build_with_builders builds spec in mode, dispatching inputs_tree_builder_hash
// to the in-service inputs tree builder and guest_builder_hash to guest_workspace
// when supplied. Any other builder returns Builder_Needs_Sandbox.
build_with_builders :: proc "contextless" (
	state: ^Recipes_State,
	spec: ^pr.Recipe_Spec,
	mode: pr.Build_Mode,
	guest_workspace: ^Guest_Builder_Workspace,
	policy: object_cache.Substitution_Policy = {},
	cache_lookup: Cache_Lookup_Proc = nil,
	verify_signature: object_cache.Signature_Verify_Proc = nil,
	sign_realisation: Sign_Realisation_Proc = nil,
) -> (result: pr.Recipe_Build_Result) {
	call := Dispatch_Call{state = state, guest = guest_workspace}
	result = build_recipe(state, spec, mode, policy, cache_lookup, builders_dispatch_invoke, verify_signature, sign_realisation, &call)
	if result.refusal == .Builder_Failed && call.refusal != .None {
		result.refusal = call.refusal
	}
	return result
}

// build_registered_with_guest builds the registered recipe of recipe_hash in
// mode using the inputs tree builder and guest_workspace, recording the result
// in the build history.
build_registered_with_guest :: proc "contextless" (
	state: ^Recipes_State,
	registry: ^Recipe_Registry,
	recipe_hash: blake3.Hash,
	mode: pr.Build_Mode,
	guest_workspace: ^Guest_Builder_Workspace,
) -> (result: pr.Recipe_Build_Result) {
	spec := registered_recipe(registry, recipe_hash)
	if spec == nil {
		state.counters.total_refusals += 1
		result = {outcome = .Refused, refusal = .Unknown_Recipe, recipe_hash = recipe_hash}
		history_add(registry, &result, mode)
		return result
	}
	result = build_with_builders(state, spec, mode, guest_workspace)
	history_add(registry, &result, mode)
	return result
}

@(private = "file")
builders_dispatch_invoke :: proc "contextless" (sandbox: ^pr.Builder_Sandbox_Spec, out_payload: []u8, user_data: rawptr) -> (payload_length: int, ok: bool) {
	call := (^Dispatch_Call)(user_data)
	if sandbox == nil || call == nil {
		return 0, false
	}
	if sandbox.builder_hash == pr.inputs_tree_builder_hash() {
		written, refusal := pr.inputs_tree_build(sandbox, out_payload)
		if refusal != .None {
			call.refusal = refusal
			return 0, false
		}
		return written, true
	}
	if sandbox.builder_hash == pr.guest_builder_hash() {
		written, refusal := guest_builder_build(call.state, call.guest, sandbox, out_payload)
		if refusal != .None {
			call.refusal = refusal
			return 0, false
		}
		return written, true
	}
	call.refusal = .Builder_Needs_Sandbox
	return 0, false
}
