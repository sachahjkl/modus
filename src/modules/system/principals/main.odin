// Delegated principals service implementing Role.Principals
// (src/md/api/root_service_split.md).
//
// Owns principal registration, session lifecycle, principal disk grant tables
// strictly bounded to Store, principal-0 Start_Policy, and Client_Key classes,
// live remote/remote_display client keys, and principal-0 start policy choice
// validation using only its attenuated service ring and shared transfer region.
package principals_service

import "base:intrinsics"
import pc "internal:principals/principals_core"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/ring"
import rd "modus:contract/root_delegation"
import "modus:contract/value_kinds"
import "modus:principals"
import "modus:system"

// Working memory budget for the freestanding principals service process and
// its fixed-capacity principal, disk grant, and client key staging buffers.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 512, processes = 1, threads = 1}

// Status record returned by the status() export.
Principals_Status :: struct {
	principal_count:      i64,
	active_sessions:      i64,
	disk_rows_applied:    i64,
	active_client_keys:   i64,
	start_policy_updates: i64,
	total_refusals:       i64,
}

// Package-level BSS state so shared-memory staging never lives on the stack.
service_state: pc.Principals_State
service_ring: ring.Ring
service_ring_memory: system.Handle
service_region_base: [^]u8
service_region_bytes: u64

// Private BSS buffers for copy-then-check reading of shared transfer memory.
copied_register_input: rd.Register_Principal_Input
copied_session_input: rd.Session_Transition_Input
copied_disk_rows_request: rd.Disk_Rows_Set_Request
copied_client_key_input: rd.Client_Key_Input
copied_start_policy_input: rd.Start_Policy_Input

@(private = "file")
fail :: proc "contextless" (text: string) -> ! {
	system.log_fact(.Error, Service_Failed{failure = value_kinds.text_field(text, FAILURE_FIELD_BYTES)})
	system.stop(.Failed)
}

region_range_valid :: proc "contextless" (offset: u64, length: u64) -> bool {
	if service_region_base == nil || length == 0 || length > service_region_bytes {
		return false
	}
	return offset <= service_region_bytes - length
}

// status writes aggregate principals service counters into out.
@(export)
status :: proc "c" (out: ^Principals_Status, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if out == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, 1)
	}
	if !service_state.initialized {
		return call_outcome.fail(error, .Wrong_State, .State, .Requests)
	}
	out^ = {
		principal_count      = i64(service_state.counters.principal_count),
		active_sessions      = i64(service_state.counters.active_sessions),
		disk_rows_applied    = i64(service_state.counters.disk_rows_applied),
		active_client_keys   = i64(service_state.counters.active_client_keys),
		start_policy_updates = i64(service_state.counters.start_policy_updates),
		total_refusals       = i64(service_state.counters.total_refusals),
	}
	return .Succeeded, 0
}

@(private = "file")
reply_bad_command :: proc "contextless" (command: ring.Record, kind: errors.Kind, arg: i64, value: i64, limit: i64 = 0) {
	ring.push(
		&service_ring.completions,
		ring.Record{
			kind   = u32(rd.Principals_Ring_Status.Bad_Command),
			tag    = command.tag,
			values = errors.ring_fail(command.kind, kind, .Bytes, arg, value, limit),
		},
	)
}

@(private = "file")
handle_command :: proc "contextless" (command: ^ring.Record) {
	parsed, ok := rd.principals_ring_command_from_word(command.kind)
	if !ok {
		reply_bad_command(command^, .Unsupported, 0, i64(command.kind))
		return
	}

	switch parsed {
	case .None:
		reply_bad_command(command^, .Unsupported, 0, i64(command.kind))

	case .Table_Key, .Table_Read, .Table_Write:
		answer: Table_Answer
		switch parsed {
		case .Table_Key:
			answer = table_key_take(command)
		case .Table_Read, .Table_Write:
			answer = table_call(command^, parsed == .Table_Write)
		case .None, .Register_Principal, .Session_Transition, .Replace_Disk_Rows, .Client_Key_Command, .Start_Policy_Command:
		}
		if answer.status != .Ok {
			system.log_fact(.Warning, Command_Refused{command_kind = u64(command.kind), refusal_code = answer.values[0]})
		}
		ring.push(&service_ring.completions, ring.Record{kind = u32(answer.status), tag = command.tag, values = answer.values})

	case .Register_Principal:
		input_offset := command.values[0]
		if !region_range_valid(input_offset, size_of(rd.Register_Principal_Input)) {
			reply_bad_command(command^, .Out_Of_Range, 1, i64(input_offset), i64(service_region_bytes))
			return
		}
		intrinsics.mem_copy_non_overlapping(&copied_register_input, rawptr(&service_region_base[input_offset]), size_of(rd.Register_Principal_Input))
		refusal := pc.register_principal(&service_state, &copied_register_input)
		if refusal != .None {
			system.log_fact(.Warning, Command_Refused{command_kind = u64(command.kind), refusal_code = u64(refusal)})
			ring.push(
				&service_ring.completions,
				ring.Record{
					kind   = u32(rd.Principals_Ring_Status.Refused),
					tag    = command.tag,
					values = {u64(refusal), 0, 0, 0, 0, 0, 0},
				},
			)
			return
		}
		system.log_fact(.Info, Principal_Registered{principal = copied_register_input.principal_id, principals = service_state.counters.principal_count})
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = u32(rd.Principals_Ring_Status.Ok),
				tag    = command.tag,
				values = {copied_register_input.principal_id, service_state.counters.principal_count, 0, 0, 0, 0, 0},
			},
		)

	case .Session_Transition:
		input_offset := command.values[0]
		if !region_range_valid(input_offset, size_of(rd.Session_Transition_Input)) {
			reply_bad_command(command^, .Out_Of_Range, 1, i64(input_offset), i64(service_region_bytes))
			return
		}
		intrinsics.mem_copy_non_overlapping(&copied_session_input, rawptr(&service_region_base[input_offset]), size_of(rd.Session_Transition_Input))
		refusal := pc.session_transition(&service_state, &copied_session_input)
		if refusal != .None {
			system.log_fact(.Warning, Command_Refused{command_kind = u64(command.kind), refusal_code = u64(refusal)})
			ring.push(
				&service_ring.completions,
				ring.Record{
					kind   = u32(rd.Principals_Ring_Status.Refused),
					tag    = command.tag,
					values = {u64(refusal), 0, 0, 0, 0, 0, 0},
				},
			)
			return
		}
		system.log_fact(.Info, Session_Changed{
			principal       = copied_session_input.principal_id,
			action          = u64(copied_session_input.action_word),
			active_sessions = service_state.counters.active_sessions,
		})
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = u32(rd.Principals_Ring_Status.Ok),
				tag    = command.tag,
				values = {principals.principal_in_front(service_state.seat), service_state.counters.active_sessions, 0, 0, 0, 0, 0},
			},
		)

	case .Replace_Disk_Rows:
		req_offset := command.values[0]
		if !region_range_valid(req_offset, size_of(rd.Disk_Rows_Set_Request)) {
			reply_bad_command(command^, .Out_Of_Range, 1, i64(req_offset), i64(service_region_bytes))
			return
		}
		intrinsics.mem_copy_non_overlapping(&copied_disk_rows_request, rawptr(&service_region_base[req_offset]), size_of(rd.Disk_Rows_Set_Request))
		refusal, border_refusal := pc.apply_disk_rows_set(&service_state, &copied_disk_rows_request)
		if refusal != .None {
			system.log_fact(.Warning, Command_Refused{command_kind = u64(command.kind), refusal_code = u64(refusal)})
			ring.push(
				&service_ring.completions,
				ring.Record{
					kind   = u32(rd.Principals_Ring_Status.Refused),
					tag    = command.tag,
					values = {u64(refusal), u64(border_refusal), 0, 0, 0, 0, 0},
				},
			)
			return
		}
		system.log_fact(.Info, Disk_Rows_Applied{
			principal  = copied_disk_rows_request.principal,
			generation = copied_disk_rows_request.generation,
			rows       = u64(copied_disk_rows_request.row_count),
		})
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = u32(rd.Principals_Ring_Status.Ok),
				tag    = command.tag,
				values = {copied_disk_rows_request.generation, u64(copied_disk_rows_request.row_count), service_state.counters.active_client_keys, 0, 0, 0, 0},
			},
		)

	case .Client_Key_Command:
		input_offset := command.values[0]
		if !region_range_valid(input_offset, size_of(rd.Client_Key_Input)) {
			reply_bad_command(command^, .Out_Of_Range, 1, i64(input_offset), i64(service_region_bytes))
			return
		}
		intrinsics.mem_copy_non_overlapping(&copied_client_key_input, rawptr(&service_region_base[input_offset]), size_of(rd.Client_Key_Input))
		serial, refusal := pc.client_key_command(&service_state, &copied_client_key_input)
		if refusal != .None {
			system.log_fact(.Warning, Command_Refused{command_kind = u64(command.kind), refusal_code = u64(refusal)})
			ring.push(
				&service_ring.completions,
				ring.Record{
					kind   = u32(rd.Principals_Ring_Status.Refused),
					tag    = command.tag,
					values = {u64(refusal), 0, 0, 0, 0, 0, 0},
				},
			)
			return
		}
		system.log_fact(.Info, Client_Key_Updated{
			principal   = copied_client_key_input.principal_id,
			action      = u64(copied_client_key_input.action_word),
			active_keys = service_state.counters.active_client_keys,
		})
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = u32(rd.Principals_Ring_Status.Ok),
				tag    = command.tag,
				values = {serial, service_state.counters.active_client_keys, 0, 0, 0, 0, 0},
			},
		)

	case .Start_Policy_Command:
		input_offset := command.values[0]
		if !region_range_valid(input_offset, size_of(rd.Start_Policy_Input)) {
			reply_bad_command(command^, .Out_Of_Range, 1, i64(input_offset), i64(service_region_bytes))
			return
		}
		intrinsics.mem_copy_non_overlapping(&copied_start_policy_input, rawptr(&service_region_base[input_offset]), size_of(rd.Start_Policy_Input))
		refusal := pc.start_policy_command(&service_state, &copied_start_policy_input)
		if refusal != .None {
			system.log_fact(.Warning, Command_Refused{command_kind = u64(command.kind), refusal_code = u64(refusal)})
			ring.push(
				&service_ring.completions,
				ring.Record{
					kind   = u32(rd.Principals_Ring_Status.Refused),
					tag    = command.tag,
					values = {u64(refusal), 0, 0, 0, 0, 0, 0},
				},
			)
			return
		}
		system.log_fact(.Info, Start_Policy_Updated{
			principal = copied_start_policy_input.principal_id,
			action    = u64(copied_start_policy_input.action_word),
			updates   = service_state.counters.start_policy_updates,
		})
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = u32(rd.Principals_Ring_Status.Ok),
				tag    = command.tag,
				values = {service_state.counters.start_policy_updates, u64(service_state.start_policy.active), 0, 0, 0, 0, 0},
			},
		)
	}
}

// entry initializes the delegated principals service ring and serves principal
// registration, session lifecycle, disk grant table updates, client keys, and
// start policy choice validation until stopped.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	open_status: system.Status
	// The ring takes handles: the core gives the connection of each call of
	// a table through it.
	service_ring_memory = ctx.handles[rd.PRINCIPALS_RING_SLOT]
	if service_ring, open_status = system.ring_open(service_ring_memory, receive_handles = true); open_status != .Ok {
		fail("no principals service ring")
	}
	image_memory := ctx.handles[rd.PRINCIPALS_IMAGE_SLOT]
	image_size := ctx.values[rd.PRINCIPALS_VALUE_IMAGE_SIZE]
	image_kind, image_rights, _ := system.handle_state(image_memory)
	if image_kind != .Memory || .Write in image_rights || image_size == 0 {
		fail("no boot image that reads only")
	}
	image_address, image_status := system.memory_map(image_memory, {})
	if image_status != .Ok {
		fail("the boot image does not map")
	}
	image = ([^]u8)(image_address)[:image_size]
	region_handle := ctx.handles[rd.PRINCIPALS_REGION_SLOT]
	if region_handle != 0 {
		pages, size_status := system.memory_size(region_handle)
		if size_status != .Ok || pages == 0 {
			fail("the principals data region has no pages")
		}
		address, map_status := system.memory_map(region_handle, {.Write})
		if map_status != .Ok {
			fail("cannot map the principals data region")
		}
		service_region_base = ([^]u8)(address)
		service_region_bytes = pages * system.PAGE_SIZE
	}

	pc.state_init(&service_state)
	system.log_fact(.Info, Service_Ready{principals = service_state.counters.principal_count})

	for {
		wait := system.wait_begin()
		answered := false
		for ring.count(&service_ring.completions) < ring.capacity(&service_ring.completions) {
			command := system.receive(&service_ring.commands) or_break
			handle_command(&command)
			// A Table_Key carries a key in its values: no copy stays here.
			intrinsics.mem_zero_volatile(&command, size_of(command))
			answered = true
		}
		if answered {
			system.wake_reader(&service_ring.completions)
		}
		system.wait_records(&wait, &service_ring.commands)
		system.wait_end(&wait)
	}
}
