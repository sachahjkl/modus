// The guest builder of the recipes service (src/md/features/recipes.md,
// "The guest builder in the service"): the disks of a guest build in memory
// of this process, the objects of the private store by their hashes, and
// the run of the guest on Guest_Run through modus:guest_regions, on a
// thread of its own. recipes_core decides each step; this file gives it the
// memory, the store and the thread.
//
// One lock, service_lock, guards the state of the service and its store
// client. The service thread holds it while it answers a call or a ring
// command. The build thread holds it during a build, and leaves it only
// while the guest runs: the service then answers each other call.
package recipes_service

import "base:intrinsics"
import "internal:recipes/recipes_core"
import "modus:contract/blake3"
import gb "modus:contract/guest_builder"
import "modus:contract/guest_os"
import "modus:contract/object_cache"
import op "modus:contract/operation"
import pr "modus:contract/plans_recipes"
import "modus:contract/ring"
import "modus:contract/value_kinds"
import "modus:guest_regions"
import "modus:system"

// The buffers of a guest build, made at the first build of the guest builder.
Guest_Buffer :: enum u8 {
	Input_Disk      = 0, // The read-only MODGBD1 disk of the inputs.
	Input_Staging   = 1, // The inputs read from the store before they are packed.
	Output_Disk     = 2, // The blank writable disk of the output.
	Kernel          = 3, // The kernel that the spec names, read from the store.
	Initial_Archive = 4, // The initial archive that the spec names, read from the store.
}

GUEST_BUFFER_BYTES :: [Guest_Buffer]u64 {
	.Input_Disk      = 16 * 1024 * 1024,
	.Input_Staging   = 16 * 1024 * 1024,
	.Output_Disk     = 32 * 1024 * 1024,
	.Kernel          = 16 * 1024 * 1024,
	.Initial_Archive = 16 * 1024 * 1024,
}
GUEST_BUFFER_PAGES :: (16 + 16 + 32 + 16 + 16) * 1024 * 1024 / system.PAGE_SIZE

// The stack of the build thread: the walk of the inputs, the build of a
// recipe and the run of the guest, with room for a fault.
GUEST_THREAD_STACK_PAGES :: 64

// guest_table_pages gives the pages of the nested page table of a guest of
// memory_pages: one page of entries for each 2 MiB of the guest, and 64
// pages for the levels above them and the pages that a guest maps past its
// memory (main.odin, TYPICAL_GUEST_TABLE_PAGES, is the same sum).
guest_table_pages :: proc "contextless" (memory_pages: u64) -> u64 {
	return memory_pages / 512 + 64
}

// The one build of the guest builder that the build thread runs.
Guest_Job :: struct {
	recipe_hash:   blake3.Hash,
	mode:          pr.Build_Mode,
	from_ring:     bool, // A command of the delegated ring: its spec, its tag and its result place.
	spec:          pr.Recipe_Spec,
	ring_tag:      u32,
	result_offset: u64,
}

service_lock: system.Lock
guest_job: Guest_Job
guest_job_result: pr.Recipe_Build_Result
guest_thread: system.Thread
guest_running: bool // Under service_lock: a build thread runs or has not been waited for.
guest_finished: u32 // The build thread sets it at its end; the service thread then waits for it.

guest_workspace: recipes_core.Guest_Builder_Workspace
guest_machine: guest_os.Linux_Machine
guest_buffers: [Guest_Buffer]guest_regions.Owned_Memory
guest_kernel: []u8
guest_archive: []u8
guest_ready: bool

put_ledger: recipes_core.Put_Ledger
retention_workspace: recipes_core.Retention_Workspace

// guest_workspace_for gives the workspace of a guest build for a recipe
// whose builder is the guest builder, and nil for each other builder: a
// build of the inputs tree builder pays for no disk. nil too when the
// budget cannot pay the buffers; the build is then refused.
guest_workspace_for :: proc "contextless" (builder_hash: blake3.Hash) -> ^recipes_core.Guest_Builder_Workspace {
	if builder_hash != pr.guest_builder_hash() {
		return nil
	}
	if guest_ready {
		return &guest_workspace
	}
	sizes := GUEST_BUFFER_BYTES
	for buffer in Guest_Buffer {
		memory, status := guest_regions.owned_memory_make(sizes[buffer])
		if status != .Ok {
			for &made in guest_buffers {
				guest_regions.owned_memory_end(&made)
				made = {}
			}
			system.log_fact(.Warning, Guest_Buffers_Refused{status_word = op.Status_Word(status), pages = sizes[buffer] / system.PAGE_SIZE})
			return nil
		}
		guest_buffers[buffer] = memory
	}
	guest_workspace.input_disk = guest_buffers[.Input_Disk].bytes
	guest_workspace.input_staging = guest_buffers[.Input_Staging].bytes
	guest_workspace.output_disk = guest_buffers[.Output_Disk].bytes
	guest_workspace.resolve_input = guest_resolve
	guest_workspace.execute_guest = guest_execute
	guest_workspace.keep_object = guest_keep
	guest_workspace.drop_object = guest_drop
	guest_workspace.prepare_guest = guest_prepare
	guest_ready = true
	return &guest_workspace
}

@(private = "file")
guest_resolve :: proc "contextless" (input: ^pr.Recipe_Input, out_bytes: []u8, user_data: rawptr) -> (written: int, ok: bool) {
	name := pr.blob_object_name(input.hash)
	bytes, status := pr.private_store_read_large(&service_state.store, pr.private_object_name_text(&name), out_bytes)
	if status != .Ok {
		system.log_fact(.Info, Guest_Object_Missing{hash = value_kinds.Hash_Field(input.hash), status = u64(status)})
		return 0, false
	}
	return len(bytes), true
}

// guest_prepare reads the kernel and the initial archive of the spec, and
// checks the memory of its guest against the pages that the budget of this
// process has left, before any input is read: an object that the store
// lacks is a miss, and a guest larger than the budget never starts.
@(private = "file")
guest_prepare :: proc "contextless" (spec: ^gb.Guest_Build_Spec, user_data: rawptr) -> pr.Recipe_Refusal {
	own, _ := system.budget_read()
	needed := spec.memory_pages + guest_table_pages(spec.memory_pages)
	if needed > own.pages {
		system.log_fact(.Info, Guest_Memory_Past_Bound{pages = needed, left = own.pages})
		return .Memory_Past_Bound
	}
	read :: proc "contextless" (hash: blake3.Hash, into: []u8) -> (bytes: []u8, refusal: pr.Recipe_Refusal) {
		name := pr.blob_object_name(hash)
		found, status := pr.private_store_read_large(&service_state.store, pr.private_object_name_text(&name), into)
		switch status {
		case .Ok:
			return found, .None
		case .Absent:
			system.log_fact(.Info, Guest_Object_Missing{hash = value_kinds.Hash_Field(hash), status = u64(status)})
			return nil, .Cache_Miss
		case .Too_Large:
			system.log_fact(.Info, Guest_Object_Missing{hash = value_kinds.Hash_Field(hash), status = u64(status)})
			return nil, .Buffer_Too_Small
		case .Failed:
			return nil, .Store_Failed
		}
		return nil, .Store_Failed
	}
	refusal: pr.Recipe_Refusal
	if guest_kernel, refusal = read(spec.kernel_hash, guest_buffers[.Kernel].bytes); refusal != .None {
		return refusal
	}
	guest_archive = nil
	if !gb.hash_is_zero(spec.initial_archive_hash) {
		if guest_archive, refusal = read(spec.initial_archive_hash, guest_buffers[.Initial_Archive].bytes); refusal != .None {
			return refusal
		}
	}
	return .None
}

// guest_keep writes an object of the output by its hash. written says if
// the store did not hold it before: only such an object is dropped again
// when the build fails.
@(private = "file")
guest_keep :: proc "contextless" (kind: object_cache.Cache_Object_Kind, hash: blake3.Hash, bytes: []u8, user_data: rawptr) -> (ok: bool, written: bool) {
	name := pr.blob_object_name(hash)
	text := pr.private_object_name_text(&name)
	if _, status := pr.private_store_size(&service_state.store, text); status == .Ok {
		return true, false
	}
	return pr.private_store_write_large(&service_state.store, text, bytes) == .Ok, true
}

@(private = "file")
guest_drop :: proc "contextless" (hash: blake3.Hash, user_data: rawptr) {
	name := pr.blob_object_name(hash)
	_ = pr.private_store_remove(&service_state.store, pr.private_object_name_text(&name))
}

// guest_execute runs the guest with the kernel and the archive that
// guest_prepare read. The lock of the service is free while the guest
// runs: the guest reaches no state of the service, only its disks.
@(private = "file")
guest_execute :: proc "contextless" (runner: ^gb.Guest_Sandbox_Runner, spec: ^gb.Guest_Build_Spec, input_disk: []u8, output_disk: []u8, user_data: rawptr) -> bool {
	guest_machine = {}
	system.unlock(&service_lock)
	outcome := guest_regions.guest_build_run(runner, &guest_machine, spec, guest_kernel, guest_archive, input_disk, output_disk)
	system.lock(&service_lock)
	switch outcome.end {
	case .Ran:
		system.log_fact(.Info, Guest_Build_Ended{exits = runner.guest_exits_handled, runs = runner.guest_runs, exit_code = u64(runner.guest_exit_code), state = u64(runner.state)})
	case .Refused:
		system.log_fact(.Info, Guest_Build_Refused_Before_Run{refusal = u64(runner.refusal), boot_refusal = u64(outcome.boot_refusal)})
	case .Unsupported:
		system.log_fact(.Info, Guests_Unsupported{})
	case .Kernel_Failed:
		system.log_fact(.Error, Guest_Step_Failed{status_word = op.Status_Word(outcome.status), step = value_kinds.text_field(outcome.step, 40)})
		return false
	}
	return true
}

// guest_build_start starts the build of job on the build thread, under
// service_lock. Builder_Busy while a build runs: the service runs one guest
// at a time.
guest_build_start :: proc "contextless" (job: Guest_Job) -> pr.Recipe_Refusal {
	if guest_running {
		return .Builder_Busy
	}
	if guest_workspace_for(pr.guest_builder_hash()) == nil {
		return .Memory_Past_Bound
	}
	guest_job = job
	intrinsics.atomic_store(&guest_finished, 0)
	thread, status := system.thread_start(guest_build_thread, nil, GUEST_THREAD_STACK_PAGES)
	if status != .Ok {
		system.log_fact(.Warning, Guest_Thread_Refused{status_word = op.Status_Word(status)})
		return .Builder_Failed
	}
	guest_thread = thread
	guest_running = true
	system.log_fact(.Info, Guest_Build_Started{recipe = value_kinds.Hash_Field(job.recipe_hash)})
	return .None
}

// guest_build_end waits for a build thread that ended, under
// service_lock: the service thread calls it when guest_finished is set.
guest_build_end :: proc "contextless" () {
	if !guest_running || intrinsics.atomic_load(&guest_finished) == 0 {
		return
	}
	system.thread_wait(guest_thread)
	guest_thread = {}
	guest_running = false
}

// guest_build_thread runs one build: the build of the recipe, its log
// facts, the answer of a ring command, and a pass of the retention of the
// store, all under service_lock but the run of the guest.
@(private = "file")
guest_build_thread :: proc "c" (parameter: rawptr) -> ! {
	system.lock(&service_lock)
	if guest_job.from_ring {
		guest_job_result = recipes_core.build_with_builders(&service_state, &guest_job.spec, guest_job.mode, &guest_workspace)
	} else {
		guest_job_result = recipes_core.build_registered_with_guest(&service_state, &service_registry, guest_job.recipe_hash, guest_job.mode, &guest_workspace)
	}
	system.log_fact(.Info, Recipe_Build_Completed{outcome = u64(guest_job_result.outcome), refusal_code = u64(guest_job_result.refusal)})
	if guest_job_result.outcome != .Refused {
		system.log_fact(.Info, Guest_Recipe_Realised{recipe = value_kinds.Hash_Field(guest_job_result.recipe_hash), output = value_kinds.Hash_Field(guest_job_result.output_hash)})
	}
	if guest_job.from_ring {
		ring_build_answer(guest_job.ring_tag, guest_job.result_offset, &guest_job_result)
	}
	retention_pass()
	system.unlock(&service_lock)
	intrinsics.atomic_store(&guest_finished, 1)
	system.thread_stop()
}

// retention_pass removes the objects that nothing names, under
// service_lock (src/md/features/recipes.md, "The retention of the store").
retention_pass :: proc "contextless" () {
	result := recipes_core.retention_collect(&service_state, &service_registry, recipes_core.put_hashes(&put_ledger), &retention_workspace)
	system.log_fact(.Info, Retention_Passed{marked = u64(result.marked), kept = u64(result.kept), removed = u64(result.removed), refusal = u64(result.refusal)})
}

// stored_recipe_register registers the recipe object of recipe_hash that the
// private store holds, when the registry does not hold it yet: a writer of
// the store keeps a recipe there, and its first build reads it. false when
// the store holds none, or one that does not decode to that hash.
stored_recipe_register :: proc "contextless" (recipe_hash: blake3.Hash) -> bool {
	if recipes_core.registered_recipe(&service_registry, recipe_hash) != nil {
		return true
	}
	name := pr.recipe_object_name(recipe_hash)
	bytes, status := pr.private_store_read_large(&service_state.store, pr.private_object_name_text(&name), stored_recipe_bytes[:])
	if status != .Ok {
		return false
	}
	if pr.decode_recipe_object(bytes, &export_spec) != .None {
		system.log_fact(.Warning, Stored_Recipe_Damaged{recipe = value_kinds.Hash_Field(recipe_hash)})
		return false
	}
	registered, refusal := recipes_core.register_recipe(&service_registry, &export_spec)
	if refusal != .None || registered != recipe_hash {
		system.log_fact(.Warning, Stored_Recipe_Damaged{recipe = value_kinds.Hash_Field(recipe_hash)})
		return false
	}
	return true
}

stored_recipe_bytes: [pr.RECIPE_OBJECT_WIRE_MOST]u8

// ring_build_answer writes the result of a build of the delegated ring to
// its place and completes its command.
ring_build_answer :: proc "contextless" (tag: u32, result_offset: u64, result: ^pr.Recipe_Build_Result) {
	intrinsics.mem_copy_non_overlapping(rawptr(&service_region_base[result_offset]), result, size_of(pr.Recipe_Build_Result))
	status_word := result.refusal == .None ? u32(pr.Service_Ring_Status.Ok) : u32(pr.Service_Ring_Status.Refused)
	ring.push(
		&service_ring.completions,
		ring.Record{kind = status_word, tag = tag, values = {u64(result.outcome), u64(result.refusal), result.verified_reproducible ? 1 : 0, 0, 0, 0, 0}},
	)
	system.wake_reader(&service_ring.completions)
}
