// Delegated powerbox service implementing Role.Powerbox
// (src/md/features/powerbox.md).
//
// Mediates grouped consent requests from windowed processes, forwards sealed
// Dialog_Record payloads (with principal-scoped Store_Share picker candidates)
// to the trusted Display role holder, verifies trusted local answers with
// anti-clickjacking arm delay and expiry bounds, and tracks issued grants.
package powerbox_service

import "base:intrinsics"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/powerbox"
import "modus:contract/ring"
import "modus:contract/role_contract"
import "modus:contract/value_kinds"
import "internal:powerbox/powerbox_core"
import "modus:system"

// Working memory budget for the freestanding powerbox service process.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 256, processes = 1, threads = 1}

// Status record returned by the status() export required by Role.Powerbox.
Powerbox_Status :: struct {
	pending_dialogs:        i64,
	total_requests:         i64,
	total_dialogs_shown:    i64,
	total_items_granted:    i64,
	total_items_refused:    i64,
	total_refused_requests: i64,
	total_expired_dialogs:  i64,
}

// Package-level BSS state so the service never places large tables on the stack.
service_state: powerbox_core.Powerbox_State
service_ring: ring.Ring
display_ring: ring.Ring
service_region_base: [^]u8
service_region_bytes: u64

// Buffers in BSS for copy-then-check reading of shared-memory records.
copied_batch: powerbox.Request_Batch
copied_answer: powerbox.Grant_Answer
outbound_dialog: powerbox.Dialog_Record

fail :: proc "contextless" (text: string) -> ! {
	system.log_fact(.Error, Service_Failed{failure = value_kinds.text_field(text, FAILURE_FIELD_BYTES)})
	system.stop(.Failed)
}

// declared_contract_hash returns the BLAKE3 hash of Role.Powerbox filled by
// this service.
declared_contract_hash :: proc "contextless" () -> role_contract.Contract_Hash {
	return role_contract.powerbox_contract_hash()
}

// pending_count returns the number of active pending consent dialogs across
// all sessions.
@(export)
pending_count :: proc "c" (error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if service_state.next_dialog_serial == 0 {
		return call_outcome.fail(error, .Wrong_State, .State, .Requests)
	}
	return .Succeeded, i64(service_state.counters.pending_dialogs)
}

// status writes the aggregate powerbox counters into out.
@(export)
status :: proc "c" (out: ^Powerbox_Status, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if out == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, 1)
	}
	if service_state.next_dialog_serial == 0 {
		return call_outcome.fail(error, .Wrong_State, .State, .Requests)
	}
	out^ = {
		pending_dialogs        = i64(service_state.counters.pending_dialogs),
		total_requests         = i64(service_state.counters.total_requests),
		total_dialogs_shown    = i64(service_state.counters.total_dialogs_shown),
		total_items_granted    = i64(service_state.counters.total_items_granted),
		total_items_refused    = i64(service_state.counters.total_items_refused),
		total_refused_requests = i64(service_state.counters.total_refused_requests),
		total_expired_dialogs  = i64(service_state.counters.total_expired_dialogs),
	}
	return .Succeeded, 0
}

// region_range_valid checks that [offset, offset + length) lies wholly within
// the mapped shared region without u64 addition overflow.
@(private = "file")
region_range_valid :: proc "contextless" (offset: u64, length: u64) -> bool {
	if service_region_base == nil || length == 0 || length > service_region_bytes {
		return false
	}
	return offset <= service_region_bytes - length
}

// handle_command validates and executes one command record from service_ring.
@(private = "file")
handle_command :: proc "contextless" (command: ring.Record, now_ms: u64) -> (display_notified: bool) {
	parsed, ok := powerbox.service_ring_command_from_word(command.kind)
	if !ok {
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = u32(powerbox.Service_Ring_Status.Bad_Command),
				tag    = command.tag,
				values = errors.ring_fail(command.kind, .Unsupported, .None, 0, i64(command.kind)),
			},
		)
		return false
	}

	switch parsed {
	case .None:
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = u32(powerbox.Service_Ring_Status.Bad_Command),
				tag    = command.tag,
				values = errors.ring_fail(command.kind, .Unsupported, .None, 0, i64(command.kind)),
			},
		)
		return false
	case .Submit_Batch:
		batch_offset := command.values[0]
		dialog_offset := command.values[1]
		if !region_range_valid(batch_offset, size_of(powerbox.Request_Batch)) {
			ring.push(
				&service_ring.completions,
				ring.Record{
					kind   = u32(powerbox.Service_Ring_Status.Bad_Command),
					tag    = command.tag,
					values = errors.ring_fail(command.kind, .Out_Of_Range, .Bytes, 1, i64(batch_offset), i64(service_region_bytes)),
				},
			)
			return false
		}
		// Copy once out of shared memory before validating so the caller cannot
		// mutate fields after the border check.
		intrinsics.mem_copy_non_overlapping(&copied_batch, rawptr(&service_region_base[batch_offset]), size_of(powerbox.Request_Batch))
		resolution, dialog_record, has_dialog := powerbox_core.submit_batch(&service_state, &copied_batch, now_ms)
		if resolution.refusal != .None {
			system.log_fact(.Warning, Request_Refused{request_serial = resolution.request_serial, refusal_code = u64(resolution.refusal)})
			ring.push(
				&service_ring.completions,
				ring.Record{
					kind   = u32(powerbox.Service_Ring_Status.Refused),
					tag    = command.tag,
					values = {u64(resolution.refusal), resolution.request_serial, 0, 0, 0, 0, 0},
				},
			)
			return false
		}
		if has_dialog {
			outbound_dialog = dialog_record
			if region_range_valid(dialog_offset, size_of(powerbox.Dialog_Record)) {
				intrinsics.mem_copy_non_overlapping(rawptr(&service_region_base[dialog_offset]), &outbound_dialog, size_of(powerbox.Dialog_Record))
			}
			if ring.count(&display_ring.commands) < ring.capacity(&display_ring.commands) {
				ring.push(
					&display_ring.commands,
					ring.Record{
						kind   = u32(outbound_dialog.action_word),
						tag    = command.tag,
						values = {outbound_dialog.dialog_serial, outbound_dialog.request_serial, dialog_offset, u64(outbound_dialog.item_count), u64(outbound_dialog.picker_candidate_count), 0, 0},
					},
				)
				display_notified = true
			}
		}
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = u32(powerbox.Service_Ring_Status.Ok),
				tag    = command.tag,
				values = {
					u64(resolution.refusal),
					resolution.dialog_serial,
					resolution.dialog_queued ? 1 : 0,
					resolution.all_held ? 1 : 0,
					u64(resolution.item_count),
					0,
					0,
				},
			},
		)
		return display_notified
	case .Display_Shown:
		dialog_serial := command.values[0]
		display_slot := u32(command.values[1])
		refusal := powerbox_core.mark_dialog_shown(&service_state, dialog_serial, display_slot, now_ms)
		status_word := refusal == .None ? u32(powerbox.Service_Ring_Status.Ok) : u32(powerbox.Service_Ring_Status.Refused)
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = status_word,
				tag    = command.tag,
				values = {u64(refusal), dialog_serial, now_ms, 0, 0, 0, 0},
			},
		)
		return false
	case .Display_Answer:
		answer_offset := command.values[0]
		if !region_range_valid(answer_offset, size_of(powerbox.Grant_Answer)) {
			ring.push(
				&service_ring.completions,
				ring.Record{
					kind   = u32(powerbox.Service_Ring_Status.Bad_Command),
					tag    = command.tag,
					values = errors.ring_fail(command.kind, .Out_Of_Range, .Bytes, 1, i64(answer_offset), i64(service_region_bytes)),
				},
			)
			return false
		}
		intrinsics.mem_copy_non_overlapping(&copied_answer, rawptr(&service_region_base[answer_offset]), size_of(powerbox.Grant_Answer))
		resolution := powerbox_core.resolve_answer(&service_state, &copied_answer, now_ms)
		status_word := resolution.refusal == .None ? u32(powerbox.Service_Ring_Status.Ok) : u32(powerbox.Service_Ring_Status.Refused)
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = status_word,
				tag    = command.tag,
				values = {u64(resolution.refusal), resolution.dialog_serial, resolution.request_serial, u64(resolution.item_count), 0, 0, 0},
			},
		)
		return false
	case .Withdraw_Dialog:
		process_slot := u32(command.values[0])
		withdrawn, revoked := powerbox_core.withdraw_for_process(&service_state, process_slot)
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = u32(powerbox.Service_Ring_Status.Ok),
				tag    = command.tag,
				values = {u64(withdrawn), u64(revoked), 0, 0, 0, 0, 0},
			},
		)
		return false
	case .Query_Counts:
		counters := service_state.counters
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = u32(powerbox.Service_Ring_Status.Ok),
				tag    = command.tag,
				values = {
					counters.pending_dialogs,
					counters.total_requests,
					counters.total_dialogs_shown,
					counters.total_items_granted,
					counters.total_items_refused,
					counters.total_refused_requests,
					counters.total_expired_dialogs,
				},
			},
		)
		return false
	}
	return false
}

// entry initializes the delegated powerbox service rings and loops over
// consent commands and expiry ticks until stopped.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	export_service, export_ok := system.service_open(ctx)
	has_delegated := false
	if ctx.handles[powerbox.SERVICE_RING_SLOT] != 0 && ctx.handles[powerbox.TRUSTED_DISPLAY_RING_SLOT] != 0 {
		status_open: system.Status
		if service_ring, status_open = system.ring_open(ctx.handles[powerbox.SERVICE_RING_SLOT]); status_open == .Ok {
			if display_ring, status_open = system.ring_open(ctx.handles[powerbox.TRUSTED_DISPLAY_RING_SLOT]); status_open == .Ok {
				has_delegated = true
			}
		}
	}
	if !export_ok && !has_delegated {
		fail("no powerbox service ring")
	}

	region_handle := ctx.handles[powerbox.SERVICE_REGION_SLOT]
	if region_handle != 0 {
		pages, size_status := system.memory_size(region_handle)
		if size_status != .Ok || pages == 0 {
			fail("the powerbox data region has no pages")
		}
		address, map_status := system.memory_map(region_handle, {.Write})
		if map_status != .Ok {
			fail("cannot map the powerbox data region")
		}
		service_region_base = ([^]u8)(address)
		service_region_bytes = pages * system.PAGE_SIZE
	}

	display_slot := u32(ctx.values[powerbox.CONTEXT_VALUE_DISPLAY_SLOT])
	powerbox_core.state_init(&service_state, display_slot)

	contract_digest := declared_contract_hash()
	_ = contract_digest
	system.log_fact(.Info, Service_Ready{display_slot = u64(display_slot), contract_version = u64(role_contract.POWERBOX_CONTRACT_VERSION)})

	for {
		wait := system.wait_begin()
		now_ms := system.time()
		if expired := powerbox_core.expire_dialogs(&service_state, now_ms); expired > 0 {
			system.log_fact(.Info, Dialogs_Expired{expired_dialogs = u64(expired)})
		}

		if export_ok {
			system.service_run(&export_service)
			system.service_wait(&wait, &export_service)
		}
		if has_delegated {
			answered := false
			display_notified := false
			drained := 0
			for drained < powerbox.REQUESTS_PER_PASS && ring.count(&service_ring.completions) < ring.capacity(&service_ring.completions) {
				command := system.receive(&service_ring.commands) or_break
				if handle_command(command, now_ms) {
					display_notified = true
				}
				answered = true
				drained += 1
			}

			if answered {
				system.wake_reader(&service_ring.completions)
			}
			if display_notified {
				system.wake_reader(&display_ring.commands)
			}
			if drained == powerbox.REQUESTS_PER_PASS && ring.count(&service_ring.commands) > 0 {
				continue
			}
			system.wait_records(&wait, &service_ring.commands)
		}
		if service_state.counters.pending_dialogs > 0 {
			system.wait_end(&wait, now_ms + 1000)
		} else {
			system.wait_end(&wait)
		}
	}
}
