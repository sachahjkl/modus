// Delegated disk_processes service implementing Role.Disk_Processes
// (src/md/api/root_service_split.md).
//
// Maintains the read-only module_files catalog, validates transitive import
// graphs with iterative 3-color DFS, answers debug-object lookups, and
// prepares verified Start_From_Bytes_Request payloads for the root core.
package disk_processes_service

import "base:intrinsics"
import dpc "internal:disk_processes/disk_processes_core"
import "modus:contract/blake3"
import "modus:contract/errors"
import "modus:contract/ring"
import rd "modus:contract/root_delegation"
import "modus:contract/value_kinds"
import "modus:system"

// Working memory budget for the freestanding disk_processes service process
// and its fixed-capacity catalog and staging buffers.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 512, processes = 1, threads = 1}

// Status record returned by the status() export.
Disk_Processes_Status :: struct {
	catalog_entries:    i64,
	import_validations: i64,
	debug_lookups:      i64,
	starts_prepared:    i64,
	total_refusals:     i64,
}

// Package-level BSS state so staging buffers never live on the stack.
service_state: dpc.Disk_Processes_State
service_ring: ring.Ring
service_region_base: [^]u8
service_region_bytes: u64

// Private BSS buffers for copy-then-check reading of shared memory.
copied_entry: dpc.Catalog_Entry
copied_prepare_input: dpc.Prepare_Start_Input
staged_import_result: dpc.Import_Validation_Result
staged_debug_info: dpc.Debug_Object_Info
staged_start_request: rd.Start_From_Bytes_Request
copied_module_bytes: [65536]u8

@(private = "file")
fail :: proc "contextless" (text: string) -> ! {
	system.log_fact(.Error, Service_Failed{failure = value_kinds.text_field(text, FAILURE_FIELD_BYTES)})
	system.stop(.Failed)
}

@(private = "file")
region_range_valid :: proc "contextless" (offset: u64, length: u64) -> bool {
	if service_region_base == nil || length == 0 || length > service_region_bytes {
		return false
	}
	return offset <= service_region_bytes - length
}

// status writes aggregate disk_processes service counters into out.
@(export)
status :: proc "c" (out: ^Disk_Processes_Status, error: ^errors.Error_Record) -> i64 {
	if out == nil {
		return errors.fail(error, -1, .Bad_Address, .None, 1)
	}
	if !service_state.initialized {
		return errors.fail(error, -2, .State, .Requests)
	}
	out^ = {
		catalog_entries    = i64(service_state.counters.catalog_entries),
		import_validations = i64(service_state.counters.import_validations),
		debug_lookups      = i64(service_state.counters.debug_lookups),
		starts_prepared    = i64(service_state.counters.starts_prepared),
		total_refusals     = i64(service_state.counters.total_refusals),
	}
	return 0
}

@(private = "file")
reply_bad_command :: proc "contextless" (command: ring.Record, kind: errors.Kind, arg: i64, value: i64, limit: i64 = 0) {
	ring.push(
		&service_ring.completions,
		ring.Record{
			kind   = u32(rd.Disk_Processes_Ring_Status.Bad_Command),
			tag    = command.tag,
			values = errors.ring_fail(command.kind, kind, .Bytes, arg, value, limit),
		},
	)
}

@(private = "file")
handle_command :: proc "contextless" (command: ring.Record) {
	parsed, ok := rd.disk_processes_ring_command_from_word(command.kind)
	if !ok {
		reply_bad_command(command, .Unsupported, 0, i64(command.kind))
		return
	}

	switch parsed {
	case .None:
		reply_bad_command(command, .Unsupported, 0, i64(command.kind))

	case .Register_Catalog_Entry:
		entry_offset := command.values[0]
		if !region_range_valid(entry_offset, size_of(dpc.Catalog_Entry)) {
			reply_bad_command(command, .Out_Of_Range, 1, i64(entry_offset), i64(service_region_bytes))
			return
		}
		intrinsics.mem_copy_non_overlapping(&copied_entry, rawptr(&service_region_base[entry_offset]), size_of(dpc.Catalog_Entry))
		refusal := dpc.catalog_register(&service_state, copied_entry)
		if refusal != .None {
			system.log_fact(.Warning, Command_Refused{command_kind = u64(command.kind), refusal_code = u64(refusal)})
			ring.push(
				&service_ring.completions,
				ring.Record{
					kind   = u32(rd.Disk_Processes_Ring_Status.Refused),
					tag    = command.tag,
					values = {u64(refusal), 0, 0, 0, 0, 0, 0},
				},
			)
			return
		}
		system.log_fact(.Info, Catalog_Entry_Registered{catalog_entries = service_state.counters.catalog_entries})
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = u32(rd.Disk_Processes_Ring_Status.Ok),
				tag    = command.tag,
				values = {service_state.counters.catalog_entries, 0, 0, 0, 0, 0, 0},
			},
		)

	case .Validate_Imports:
		hash_offset := command.values[0]
		out_offset := command.values[1]
		if !region_range_valid(hash_offset, size_of(blake3.Hash)) || !region_range_valid(out_offset, size_of(dpc.Import_Validation_Result)) {
			reply_bad_command(command, .Out_Of_Range, 1, i64(hash_offset), i64(service_region_bytes))
			return
		}
		root_hash: blake3.Hash
		intrinsics.mem_copy_non_overlapping(&root_hash, rawptr(&service_region_base[hash_offset]), size_of(blake3.Hash))
		staged_import_result = dpc.validate_imports(&service_state, root_hash)
		intrinsics.mem_copy_non_overlapping(rawptr(&service_region_base[out_offset]), &staged_import_result, size_of(dpc.Import_Validation_Result))
		if staged_import_result.refusal != .None {
			system.log_fact(.Warning, Command_Refused{command_kind = u64(command.kind), refusal_code = u64(staged_import_result.refusal)})
			ring.push(
				&service_ring.completions,
				ring.Record{
					kind   = u32(rd.Disk_Processes_Ring_Status.Refused),
					tag    = command.tag,
					values = {u64(staged_import_result.refusal), 0, 0, 0, 0, 0, 0},
				},
			)
			return
		}
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = u32(rd.Disk_Processes_Ring_Status.Ok),
				tag    = command.tag,
				values = {u64(staged_import_result.resolved_count), u64(staged_import_result.max_depth_seen), 0, 0, 0, 0, 0},
			},
		)

	case .Lookup_Debug_Object:
		hash_offset := command.values[0]
		out_offset := command.values[1]
		if !region_range_valid(hash_offset, size_of(blake3.Hash)) || !region_range_valid(out_offset, size_of(dpc.Debug_Object_Info)) {
			reply_bad_command(command, .Out_Of_Range, 1, i64(hash_offset), i64(service_region_bytes))
			return
		}
		module_hash: blake3.Hash
		intrinsics.mem_copy_non_overlapping(&module_hash, rawptr(&service_region_base[hash_offset]), size_of(blake3.Hash))
		info, found := dpc.lookup_debug_object(&service_state, module_hash)
		if !found {
			ring.push(
				&service_ring.completions,
				ring.Record{
					kind   = u32(rd.Disk_Processes_Ring_Status.Refused),
					tag    = command.tag,
					values = {0, 0, 0, 0, 0, 0, 0},
				},
			)
			return
		}
		staged_debug_info = info
		intrinsics.mem_copy_non_overlapping(rawptr(&service_region_base[out_offset]), &staged_debug_info, size_of(dpc.Debug_Object_Info))
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = u32(rd.Disk_Processes_Ring_Status.Ok),
				tag    = command.tag,
				values = {info.debug_object_size, 0, 0, 0, 0, 0, 0},
			},
		)

	case .Prepare_Start:
		input_offset := command.values[0]
		bytes_offset := command.values[1]
		bytes_length := command.values[2]
		out_offset := command.values[3]
		if bytes_length == 0 || bytes_length > len(copied_module_bytes) ||
			!region_range_valid(input_offset, size_of(dpc.Prepare_Start_Input)) ||
			!region_range_valid(bytes_offset, bytes_length) ||
			!region_range_valid(out_offset, size_of(rd.Start_From_Bytes_Request)) {
			reply_bad_command(command, .Out_Of_Range, 1, i64(bytes_length), len(copied_module_bytes))
			return
		}
		intrinsics.mem_copy_non_overlapping(&copied_prepare_input, rawptr(&service_region_base[input_offset]), size_of(dpc.Prepare_Start_Input))
		intrinsics.mem_copy_non_overlapping(&copied_module_bytes[0], rawptr(&service_region_base[bytes_offset]), int(bytes_length))

		req, prep_ref, imp_ref, border_ref := dpc.prepare_start_from_bytes(&service_state, &copied_prepare_input, copied_module_bytes[:bytes_length])
		if prep_ref != .None {
			system.log_fact(.Warning, Command_Refused{command_kind = u64(command.kind), refusal_code = u64(prep_ref)})
			ring.push(
				&service_ring.completions,
				ring.Record{
					kind   = u32(rd.Disk_Processes_Ring_Status.Refused),
					tag    = command.tag,
					values = {u64(prep_ref), u64(imp_ref), u64(border_ref), 0, 0, 0, 0},
				},
			)
			return
		}
		staged_start_request = req
		intrinsics.mem_copy_non_overlapping(rawptr(&service_region_base[out_offset]), &staged_start_request, size_of(rd.Start_From_Bytes_Request))
		system.log_fact(.Info, Start_Prepared{principal = req.principal, import_count = u64(req.import_count)})
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = u32(rd.Disk_Processes_Ring_Status.Ok),
				tag    = command.tag,
				values = {u64(req.import_count), req.module_byte_count, 0, 0, 0, 0, 0},
			},
		)
	}
}

// entry initializes the delegated disk_processes ring and serves catalog,
// import validation, debug-object lookup, and Start_From_Bytes preparation.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	open_status: system.Status
	if service_ring, open_status = system.ring_open(ctx.handles[rd.DISK_PROCESSES_RING_SLOT]); open_status != .Ok {
		fail("no disk_processes service ring")
	}
	region_handle := ctx.handles[rd.DISK_PROCESSES_REGION_SLOT]
	if region_handle != 0 {
		pages, size_status := system.memory_size(region_handle)
		if size_status != .Ok || pages == 0 {
			fail("the disk_processes data region has no pages")
		}
		address, map_status := system.memory_map(region_handle, {.Write})
		if map_status != .Ok {
			fail("cannot map the disk_processes data region")
		}
		service_region_base = ([^]u8)(address)
		service_region_bytes = pages * system.PAGE_SIZE
	}

	dpc.state_init(&service_state)
	system.log_fact(.Info, Service_Ready{})

	for {
		wait := system.wait_begin()
		answered := false
		for ring.count(&service_ring.completions) < ring.capacity(&service_ring.completions) {
			command := system.receive(&service_ring.commands) or_break
			handle_command(command)
			answered = true
		}
		if answered {
			system.wake_reader(&service_ring.completions)
		}
		system.wait_records(&wait, &service_ring.commands)
		system.wait_end(&wait)
	}
}
