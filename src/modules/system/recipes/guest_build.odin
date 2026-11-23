// The guest builder of the recipes service (src/md/features/recipes.md,
// "The guest builder"): the disks of a guest build in memory of this
// process, the objects of the private store by their hashes, and the run of
// the guest on Guest_Run through modus:guest_regions. recipes_core decides
// each step; this file gives it the memory and the store.
package recipes_service

import "internal:recipes/recipes_core"
import "modus:contract/blake3"
import gb "modus:contract/guest_builder"
import "modus:contract/guest_os"
import "modus:contract/object_cache"
import op "modus:contract/operation"
import pr "modus:contract/plans_recipes"
import "modus:contract/value_kinds"
import "modus:guest_regions"
import "modus:storage_port"
import "modus:system"

// The memory of one guest build, which the stated budget of the service
// pays: the guest of a build gets at most GUEST_MEMORY_PAGES_MOST pages,
// and its disks and the objects that it reads fit these buffers. A spec or
// an input past them is refused with no run.
GUEST_MEMORY_PAGES_MOST :: u64(32_768) // 128 MiB, the memory that a kernel of a distribution needs.
GUEST_NESTED_TABLE_PAGES :: u64(1_024)

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

guest_workspace: recipes_core.Guest_Builder_Workspace
guest_machine: guest_os.Linux_Machine
guest_buffers: [Guest_Buffer]guest_regions.Owned_Memory
guest_ready: bool

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
	guest_ready = true
	return &guest_workspace
}

// guest_object_read reads the object of a hash from the private store,
// whole, into into.
@(private = "file")
guest_object_read :: proc "contextless" (hash: blake3.Hash, into: []u8) -> (bytes: []u8, status: pr.Private_Store_Status) {
	name := pr.blob_object_name(hash)
	count: int
	count, status = storage_port.read_large(&service_state.store, pr.private_object_name_text(&name), into)
	if status != .Ok {
		return nil, status
	}
	return into[:count], .Ok
}

@(private = "file")
guest_resolve :: proc "contextless" (input: ^pr.Recipe_Input, out_bytes: []u8, user_data: rawptr) -> (written: int, ok: bool) {
	bytes, status := guest_object_read(input.hash, out_bytes)
	if status != .Ok {
		system.log_fact(.Info, Guest_Object_Missing{hash = value_kinds.Hash_Field(input.hash), status = u64(status)})
		return 0, false
	}
	return len(bytes), true
}

@(private = "file")
guest_keep :: proc "contextless" (kind: object_cache.Cache_Object_Kind, hash: blake3.Hash, bytes: []u8, user_data: rawptr) -> bool {
	name := pr.blob_object_name(hash)
	return pr.private_store_write(&service_state.store, pr.private_object_name_text(&name), bytes) == .Ok
}

// guest_execute reads the kernel and the initial archive of the spec from
// the private store, and runs the guest. A kernel or an archive that the
// store lacks ends the build before its run.
@(private = "file")
guest_execute :: proc "contextless" (runner: ^gb.Guest_Sandbox_Runner, spec: ^gb.Guest_Build_Spec, input_disk: []u8, output_disk: []u8, user_data: rawptr) -> bool {
	if spec.memory_pages > GUEST_MEMORY_PAGES_MOST {
		runner.state = .Refused
		runner.refusal = .Memory_Past_Bound
		system.log_fact(.Info, Guest_Memory_Past_Bound{pages = spec.memory_pages, most = GUEST_MEMORY_PAGES_MOST})
		return true
	}
	kernel, kernel_status := guest_object_read(spec.kernel_hash, guest_buffers[.Kernel].bytes)
	if kernel_status != .Ok {
		system.log_fact(.Info, Guest_Object_Missing{hash = value_kinds.Hash_Field(spec.kernel_hash), status = u64(kernel_status)})
		return false
	}
	archive: []u8
	if !gb.hash_is_zero(spec.initial_archive_hash) {
		archive_status: pr.Private_Store_Status
		archive, archive_status = guest_object_read(spec.initial_archive_hash, guest_buffers[.Initial_Archive].bytes)
		if archive_status != .Ok {
			system.log_fact(.Info, Guest_Object_Missing{hash = value_kinds.Hash_Field(spec.initial_archive_hash), status = u64(archive_status)})
			return false
		}
	}
	guest_machine = {}
	outcome := guest_regions.guest_build_run(runner, &guest_machine, spec, kernel, archive, input_disk, output_disk)
	switch outcome.end {
	case .Ran:
		system.log_fact(.Info, Guest_Build_Ended{exits = runner.guest_exits_handled, exit_code = u64(runner.guest_exit_code), state = u64(runner.state)})
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

// stored_recipe_register registers the recipe object of recipe_hash that the
// private store holds, when the registry does not hold it yet: a writer of
// the store keeps a recipe there, and its first build reads it. false when
// the store holds none, or one that does not decode to that hash.
stored_recipe_register :: proc "contextless" (recipe_hash: blake3.Hash) -> bool {
	if recipes_core.registered_recipe(&service_registry, recipe_hash) != nil {
		return true
	}
	name := pr.recipe_object_name(recipe_hash)
	bytes, status := pr.private_store_read(&service_state.store, pr.private_object_name_text(&name), stored_recipe_bytes[:])
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
