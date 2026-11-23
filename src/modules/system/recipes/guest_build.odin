// The guest builder of the recipes service (src/md/features/recipes.md,
// "The guest builder in the service"): the queue of the guest builds, the
// buffers of each build sized from its spec and from the budget, the
// objects of the private store by their hashes, and the run of the guest
// on Guest_Run through modus:guest_regions, on a thread of its own.
// recipes_core decides each step; this file gives it the memory, the store
// and the thread.
//
// One lock, service_lock, guards the state of the service, the queue and
// the store client. The service thread holds it while it answers a call or
// a ring command. The build thread holds it during a build, and leaves it
// only while the guest runs: the service then answers each other call.
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

// The buffers of one guest build, made at its start from its plan and given
// back at its end.
Guest_Buffer :: enum u8 {
	Input_Disk      = 0, // The read-only MODGBD1 disk of the inputs.
	Input_Staging   = 1, // The inputs read from the store before they are packed.
	Output_Disk     = 2, // The blank writable disk of the output.
	Kernel          = 3, // The kernel that the spec names, read from the store.
	Initial_Archive = 4, // The initial archive that the spec names, read from the store.
}

// The stack of the build thread: the walk of the inputs, the build of a
// recipe and the run of the guest, with room for a fault.
GUEST_THREAD_STACK_PAGES :: 64

// The pages that a guest build leaves to the service: a builder that the
// service thread starts as a call host while the guest runs, and the
// memory objects of a native C build.
SERVICE_RESERVE_PAGES :: u64(3072)

service_lock: system.Lock
guest_queue: recipes_core.Guest_Queue
guest_job: recipes_core.Guest_Queue_Job // The copy of the running build that the build thread reads.
guest_job_result: pr.Recipe_Build_Result
guest_thread: system.Thread
guest_thread_live: bool // Under service_lock: a build thread runs or has not been waited for.
guest_finished: u32 // The build thread sets it before it leaves the lock; the service thread then waits for it.

guest_workspace: recipes_core.Guest_Builder_Workspace
guest_machine: guest_os.Linux_Machine
guest_buffers: [Guest_Buffer]guest_regions.Owned_Memory
guest_kernel: []u8
guest_archive: []u8

put_ledger: recipes_core.Put_Ledger
put_hashes_now: [2 * recipes_core.PUT_PRINCIPALS_MOST * recipes_core.PUT_OBJECTS_PER_PRINCIPAL_MOST]blake3.Hash
retention_workspace: recipes_core.Retention_Workspace

// guest_buffers_end gives back the buffers of the last build.
@(private = "file")
guest_buffers_end :: proc "contextless" () {
	for &made in guest_buffers {
		guest_regions.owned_memory_end(&made)
		made = {}
	}
	guest_workspace.input_disk = nil
	guest_workspace.input_staging = nil
	guest_workspace.output_disk = nil
	guest_kernel = nil
	guest_archive = nil
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

// guest_object_size gives the bytes of an object of the store by its hash:
// a miss when the store lacks it.
@(private = "file")
guest_object_size :: proc "contextless" (hash: blake3.Hash) -> (bytes: u64, refusal: pr.Recipe_Refusal) {
	name := pr.blob_object_name(hash)
	size, status := pr.private_store_size(&service_state.store, pr.private_object_name_text(&name))
	switch status {
	case .Ok:
		return size, .None
	case .Absent, .Too_Large:
		system.log_fact(.Info, Guest_Object_Missing{hash = value_kinds.Hash_Field(hash), status = u64(status)})
		return 0, .Cache_Miss
	case .Failed:
		return 0, .Store_Failed
	}
	return 0, .Store_Failed
}

// guest_prepare plans the build from its spec, the sizes of its kernel and
// its archive and the pages that the budget of this process has left
// (recipes_core.guest_build_plan), makes its buffers, and reads its kernel
// and its archive, before any input is read: an object that the store
// lacks is a miss, and a build whose needs do not fit is Memory_Past_Bound.
@(private = "file")
guest_prepare :: proc "contextless" (spec: ^gb.Guest_Build_Spec, user_data: rawptr) -> pr.Recipe_Refusal {
	guest_buffers_end()
	kernel_bytes, kernel_refusal := guest_object_size(spec.kernel_hash)
	if kernel_refusal != .None {
		return kernel_refusal
	}
	archive_bytes: u64
	if !gb.hash_is_zero(spec.initial_archive_hash) {
		archive_refusal: pr.Recipe_Refusal
		if archive_bytes, archive_refusal = guest_object_size(spec.initial_archive_hash); archive_refusal != .None {
			return archive_refusal
		}
	}
	own, _ := system.budget_read()
	plan, plan_refusal := recipes_core.guest_build_plan(own.pages, SERVICE_RESERVE_PAGES, spec, kernel_bytes, archive_bytes)
	if plan_refusal != .None {
		system.log_fact(.Info, Guest_Memory_Past_Bound{pages = spec.memory_pages, left = own.pages})
		return plan_refusal
	}
	sizes := [Guest_Buffer]u64 {
		.Input_Disk      = plan.input_disk_bytes,
		.Input_Staging   = plan.input_staging_bytes,
		.Output_Disk     = plan.output_bytes,
		.Kernel          = plan.kernel_bytes,
		.Initial_Archive = plan.archive_bytes,
	}
	for buffer in Guest_Buffer {
		if sizes[buffer] == 0 {
			continue
		}
		memory, status := guest_regions.owned_memory_make(sizes[buffer])
		if status != .Ok {
			guest_buffers_end()
			system.log_fact(.Warning, Guest_Buffers_Refused{status_word = op.Status_Word(status), pages = sizes[buffer] / system.PAGE_SIZE})
			return .Memory_Past_Bound
		}
		guest_buffers[buffer] = memory
	}
	guest_workspace.input_disk = guest_buffers[.Input_Disk].bytes
	guest_workspace.input_staging = guest_buffers[.Input_Staging].bytes
	guest_workspace.output_disk = guest_buffers[.Output_Disk].bytes
	read :: proc "contextless" (hash: blake3.Hash, into: []u8) -> (bytes: []u8, refusal: pr.Recipe_Refusal) {
		name := pr.blob_object_name(hash)
		found, status := pr.private_store_read_large(&service_state.store, pr.private_object_name_text(&name), into)
		switch status {
		case .Ok:
			return found, .None
		case .Absent, .Too_Large:
			return nil, .Cache_Miss // The object changed since its size was read.
		case .Failed:
			return nil, .Store_Failed
		}
		return nil, .Store_Failed
	}
	refusal: pr.Recipe_Refusal
	if guest_kernel, refusal = read(spec.kernel_hash, guest_buffers[.Kernel].bytes); refusal != .None {
		guest_buffers_end()
		return refusal
	}
	if !gb.hash_is_zero(spec.initial_archive_hash) {
		if guest_archive, refusal = read(spec.initial_archive_hash, guest_buffers[.Initial_Archive].bytes); refusal != .None {
			guest_buffers_end()
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
// runs: the guest reaches no state of the service, only its disks and its
// buffers, which no call touches while a build runs.
@(private = "file")
guest_execute :: proc "contextless" (runner: ^gb.Guest_Sandbox_Runner, spec: ^gb.Guest_Build_Spec, input_disk: []u8, output_disk: []u8, user_data: rawptr) -> bool {
	guest_machine = {}
	// A cancel that came while the build prepared reaches the runner here.
	if running := recipes_core.guest_queue_running(&guest_queue); running != nil && running.cancel_requested {
		gb.runner_cancel(runner)
	}
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

// guest_build_queue adds a build to the queue, under service_lock, and
// starts it when no build runs. Builder_Busy when the queue is full or its
// principal holds its share.
guest_build_queue :: proc "contextless" (job: recipes_core.Guest_Queue_Job) -> pr.Recipe_Refusal {
	if refusal := recipes_core.guest_queue_push(&guest_queue, job); refusal != .None {
		return refusal
	}
	system.log_fact(.Info, Guest_Build_Queued{recipe = value_kinds.Hash_Field(job.recipe_hash)})
	guest_build_next()
	return .None
}

// guest_build_next starts the next build of the queue on the build thread,
// under service_lock, when no build thread lives.
@(private = "file")
guest_build_next :: proc "contextless" () {
	for !guest_thread_live {
		next := recipes_core.guest_queue_start(&guest_queue)
		if next == nil {
			return
		}
		guest_job = next^
		guest_workspace.resolve_input = guest_resolve
		guest_workspace.execute_guest = guest_execute
		guest_workspace.keep_object = guest_keep
		guest_workspace.drop_object = guest_drop
		guest_workspace.prepare_guest = guest_prepare
		intrinsics.atomic_store(&guest_finished, 0)
		thread, status := system.thread_start(guest_build_thread, nil, GUEST_THREAD_STACK_PAGES)
		if status != .Ok {
			// The build ends refused: the next one may find the room.
			system.log_fact(.Warning, Guest_Thread_Refused{status_word = op.Status_Word(status)})
			guest_job_result = {outcome = .Refused, refusal = .Builder_Failed, recipe_hash = guest_job.recipe_hash}
			service_state.counters.total_refusals += 1
			if guest_job.from_ring {
				ring_build_answer(guest_job.ring_tag, guest_job.result_offset, &guest_job_result)
			} else {
				// The caller got Building: the history gives it the end.
				recipes_core.history_add(&service_registry, &guest_job_result, guest_job.mode)
			}
			recipes_core.guest_queue_end(&guest_queue)
			continue
		}
		guest_thread = thread
		guest_thread_live = true
		system.log_fact(.Info, Guest_Build_Started{recipe = value_kinds.Hash_Field(guest_job.recipe_hash)})
	}
}

// guest_build_end waits for a build thread that ended, under service_lock,
// frees its place in the queue and starts the next build: the service
// thread calls it at each turn of its loop.
guest_build_end :: proc "contextless" () {
	if !guest_thread_live || intrinsics.atomic_load(&guest_finished) == 0 {
		return
	}
	system.thread_wait(guest_thread)
	guest_thread = {}
	guest_thread_live = false
	recipes_core.guest_queue_end(&guest_queue)
	guest_build_next()
}

// guest_build_cancel cancels the build of recipe_hash that principal
// queued, under service_lock. A running build ends at the next exit of its
// guest, from the thread of the guest.
guest_build_cancel :: proc "contextless" (principal: u64, recipe_hash: blake3.Hash) -> recipes_core.Guest_Cancel {
	result := recipes_core.guest_queue_cancel(&guest_queue, principal, recipe_hash)
	if result == .Requested {
		gb.runner_cancel(&guest_workspace.runner)
	}
	return result
}

// guest_build_thread runs one build: the build of the recipe, its log
// facts, the answer of a ring command, and a pass of the retention of the
// store, all under service_lock but the run of the guest. It says that it
// ended before it leaves the lock: a call that the lock waited for then
// never takes the ended build for a running one.
@(private = "file")
guest_build_thread :: proc "c" (parameter: rawptr) -> ! {
	system.lock(&service_lock)
	if guest_job.from_ring {
		guest_job_result = recipes_core.build_with_builders(&service_state, &guest_job.spec, guest_job.mode, &guest_workspace)
	} else {
		guest_job_result = recipes_core.build_registered_with_guest(&service_state, &service_registry, guest_job.recipe_hash, guest_job.mode, &guest_workspace)
	}
	guest_buffers_end()
	system.log_fact(.Info, Recipe_Build_Completed{outcome = u64(guest_job_result.outcome), refusal_code = u64(guest_job_result.refusal)})
	if guest_job_result.outcome != .Refused {
		system.log_fact(.Info, Guest_Recipe_Realised{recipe = value_kinds.Hash_Field(guest_job_result.recipe_hash), output = value_kinds.Hash_Field(guest_job_result.output_hash)})
	}
	if guest_job.from_ring {
		ring_build_answer(guest_job.ring_tag, guest_job.result_offset, &guest_job_result)
	}
	retention_pass()
	intrinsics.atomic_store(&guest_finished, 1)
	system.unlock(&service_lock)
	system.thread_stop()
}

// retention_pass removes the objects that nothing names, under
// service_lock (src/md/features/recipes.md, "The retention of the store").
retention_pass :: proc "contextless" () {
	recipes_core.put_ledger_age(&put_ledger, system.time() / 1000)
	result := recipes_core.retention_collect(&service_state, &service_registry, recipes_core.put_hashes(&put_ledger, &put_hashes_now), &retention_workspace, &guest_queue)
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
	if digest, decode_refusal := pr.recipe_object_decode(bytes, &export_spec); decode_refusal != .None || digest != recipe_hash {
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

stored_recipe_bytes: [pr.MAX_RECIPE_OBJECT_BYTES]u8

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
