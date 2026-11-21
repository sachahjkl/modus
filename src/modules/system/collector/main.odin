// Delegated collector and wide-grant audit service
// (src/md/features/module_outputs.md, src/md/features/wide_grants.md).
//
// Maintains the per-principal append-only BLAKE3 hash-chained act record store
// and enforces wide-grant proofs, window bounds, monotonic expiry, instant
// revocation, sensitive-action blocks, and fail-closed recording.
package collector_service

import "base:intrinsics"
import "internal:collector/collector_core"
import "modus:contract/errors"
import "modus:contract/ring"
import "modus:contract/value_kinds"
import "modus:contract/wide_grants"
import "modus:system"

// Working memory budget for the freestanding collector and wide-grant audit service.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 256, processes = 1, threads = 1}

// Maximum act records returned in one shared-region query response.
QUERY_STAGING_CAPACITY :: 64

// Aggregate status record returned by the status() export.
Collector_Status :: struct {
	active_grants:        i64,
	total_grants_created: i64,
	total_grants_revoked: i64,
	total_grants_expired: i64,
	total_acts_permitted: i64,
	total_acts_blocked:   i64,
	recorded_acts:        i64,
	refused_full_count:   i64,
}

// Verification result returned by the verify_chain() export.
Chain_Verification_Report :: struct {
	refusal_code:  i64,
	failing_index: i64,
	record_count:  i64,
	verify_calls:  i64,
}

// Package-level BSS state so large tables stay off the thread stack.
manager_state: collector_core.Wide_Grant_Manager
service_ring: ring.Ring
service_region_base: [^]u8
service_region_bytes: u64

// Staging buffers in BSS for copy-then-check shared memory access.
copied_create_request: wide_grants.Create_Grant_Request
copied_act_request: wide_grants.Authorize_Act_Request
copied_act_record: wide_grants.Act_Record
outbound_act_record: wide_grants.Act_Record
query_staging: [QUERY_STAGING_CAPACITY]wide_grants.Act_Record

@(private = "file")
fail :: proc "contextless" (text: string) -> ! {
	system.log_fact(.Error, Service_Failed{failure = value_kinds.text_field(text, FAILURE_FIELD_BYTES)})
	system.stop(.Failed)
}

// record_count returns the number of hash-chained act records stored in the collector.
@(export)
record_count :: proc "c" (error: ^errors.Error_Record) -> i64 {
	if !manager_state.initialized {
		return errors.fail(error, -1, .State, .Records)
	}
	return i64(manager_state.collector.count)
}

// active_grant_count returns the number of currently active wide grants.
@(export)
active_grant_count :: proc "c" (error: ^errors.Error_Record) -> i64 {
	if !manager_state.initialized {
		return errors.fail(error, -1, .State, .Grants)
	}
	return i64(manager_state.counters.active_grants)
}

// status writes aggregate collector and wide-grant counters into out.
@(export)
status :: proc "c" (out: ^Collector_Status, error: ^errors.Error_Record) -> i64 {
	if out == nil {
		return errors.fail(error, -1, .Bad_Address, .None, 1)
	}
	if !manager_state.initialized {
		return errors.fail(error, -2, .State, .Records)
	}
	out^ = {
		active_grants        = i64(manager_state.counters.active_grants),
		total_grants_created = i64(manager_state.counters.total_grants_created),
		total_grants_revoked = i64(manager_state.counters.total_grants_revoked),
		total_grants_expired = i64(manager_state.counters.total_grants_expired),
		total_acts_permitted = i64(manager_state.counters.total_acts_permitted),
		total_acts_blocked   = i64(manager_state.counters.total_acts_blocked),
		recorded_acts        = i64(manager_state.collector.count),
		refused_full_count   = i64(manager_state.collector.refused_full_count),
	}
	return 0
}

// verify_chain walks the full hash-chained act store and reports integrity.
@(export)
verify_chain :: proc "c" (out: ^Chain_Verification_Report, error: ^errors.Error_Record) -> i64 {
	if out == nil {
		return errors.fail(error, -1, .Bad_Address, .None, 1)
	}
	if !manager_state.initialized {
		return errors.fail(error, -2, .State, .Records)
	}
	refusal, failing_index := collector_core.manager_verify_chain(&manager_state)
	out^ = {
		refusal_code  = i64(refusal),
		failing_index = i64(failing_index),
		record_count  = i64(manager_state.collector.count),
		verify_calls  = i64(manager_state.collector.verify_calls),
	}
	if refusal != .None {
		system.log_fact(.Error, Chain_Verification_Failed{failing_index = failing_index, refusal_code = u64(refusal)})
		return errors.fail(error, -3, .Damaged, .Records, 0, i64(failing_index), i64(manager_state.collector.count), i64(refusal))
	}
	return 0
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

// handle_command parses and executes one command record from service_ring.
@(private = "file")
handle_command :: proc "contextless" (command: ring.Record, now_ms: u64) {
	parsed, ok := wide_grants.collector_ring_command_from_word(command.kind)
	if !ok {
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = u32(wide_grants.Collector_Ring_Status.Bad_Command),
				tag    = command.tag,
				values = errors.ring_fail(command.kind, .Unsupported, .None, 0, i64(command.kind)),
			},
		)
		return
	}

	switch parsed {
	case .None:
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = u32(wide_grants.Collector_Ring_Status.Bad_Command),
				tag    = command.tag,
				values = errors.ring_fail(command.kind, .Unsupported, .None, 0, i64(command.kind)),
			},
		)
	case .Create_Grant:
		request_offset := command.values[0]
		if !region_range_valid(request_offset, size_of(wide_grants.Create_Grant_Request)) {
			ring.push(
				&service_ring.completions,
				ring.Record{
					kind   = u32(wide_grants.Collector_Ring_Status.Bad_Command),
					tag    = command.tag,
					values = errors.ring_fail(command.kind, .Out_Of_Range, .Bytes, 1, i64(request_offset), i64(service_region_bytes)),
				},
			)
			return
		}
		// Copy once out of shared memory before validation so the caller cannot
		// mutate terms or proof fields after border checks.
		intrinsics.mem_copy_non_overlapping(&copied_create_request, rawptr(&service_region_base[request_offset]), size_of(wide_grants.Create_Grant_Request))
		grant_serial, refusal := collector_core.manager_create_grant(&manager_state, &copied_create_request.terms, &copied_create_request.proof, now_ms)
		if refusal != .None {
			system.log_fact(.Warning, Wide_Grant_Action_Refused{refusal_code = u64(refusal), grant_serial = 0})
			status_code := refusal == .Act_Log_Full ? u32(wide_grants.Collector_Ring_Status.Busy) : u32(wide_grants.Collector_Ring_Status.Refused)
			ring.push(
				&service_ring.completions,
				ring.Record{
					kind   = status_code,
					tag    = command.tag,
					values = {u64(refusal), 0, u64(manager_state.collector.count), 0, 0, 0, 0},
				},
			)
			return
		}
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = u32(wide_grants.Collector_Ring_Status.Ok),
				tag    = command.tag,
				values = {u64(wide_grants.Wide_Grant_Refusal.None), grant_serial, u64(manager_state.collector.count), manager_state.counters.active_grants, 0, 0, 0},
			},
		)
	case .Revoke_Grant:
		grant_serial := command.values[0]
		reason_word := command.values[1]
		refusal := collector_core.manager_revoke_grant(&manager_state, grant_serial, now_ms, reason_word)
		status_code := refusal == .None ? u32(wide_grants.Collector_Ring_Status.Ok) : u32(wide_grants.Collector_Ring_Status.Refused)
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = status_code,
				tag    = command.tag,
				values = {u64(refusal), grant_serial, manager_state.counters.active_grants, u64(manager_state.collector.count), 0, 0, 0},
			},
		)
	case .Authorize_And_Record_Act:
		request_offset := command.values[0]
		output_offset := command.values[1]
		if !region_range_valid(request_offset, size_of(wide_grants.Authorize_Act_Request)) {
			ring.push(
				&service_ring.completions,
				ring.Record{
					kind   = u32(wide_grants.Collector_Ring_Status.Bad_Command),
					tag    = command.tag,
					values = errors.ring_fail(command.kind, .Out_Of_Range, .Bytes, 1, i64(request_offset), i64(service_region_bytes)),
				},
			)
			return
		}
		intrinsics.mem_copy_non_overlapping(&copied_act_request, rawptr(&service_region_base[request_offset]), size_of(wide_grants.Authorize_Act_Request))
		act_kind, act_kind_ok := wide_grants.act_kind_from_word(copied_act_request.act_kind_word)
		if !act_kind_ok {
			act_kind = .None
		}
		sensitive_action, action_ok := wide_grants.sensitive_action_from_word(copied_act_request.sensitive_action_word)
		if !action_ok {
			// Unknown sensitive action fails closed as None (requires principal proof).
			sensitive_action = .None
		}
		rec, refusal := collector_core.manager_authorize_and_record_act(
			&manager_state,
			copied_act_request.grant_serial,
			now_ms,
			act_kind,
			copied_act_request.target_window_id,
			sensitive_action,
			copied_act_request.detail_word_0,
			copied_act_request.detail_word_1,
		)
		if output_offset != 0 && region_range_valid(output_offset, size_of(wide_grants.Act_Record)) {
			outbound_act_record = rec
			intrinsics.mem_copy_non_overlapping(rawptr(&service_region_base[output_offset]), &outbound_act_record, size_of(wide_grants.Act_Record))
		}
		status_code := u32(wide_grants.Collector_Ring_Status.Ok)
		if refusal == .Act_Log_Full {
			status_code = u32(wide_grants.Collector_Ring_Status.Busy)
		} else if refusal != .None {
			status_code = u32(wide_grants.Collector_Ring_Status.Refused)
		}
		if refusal != .None {
			system.log_fact(.Warning, Wide_Grant_Action_Refused{refusal_code = u64(refusal), grant_serial = copied_act_request.grant_serial})
		}
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = status_code,
				tag    = command.tag,
				values = {u64(refusal), rec.sequence_number, u64(manager_state.collector.count), manager_state.counters.total_acts_permitted, manager_state.counters.total_acts_blocked, 0, 0},
			},
		)
	case .Append_Act_Record:
		record_offset := command.values[0]
		if !region_range_valid(record_offset, size_of(wide_grants.Act_Record)) {
			ring.push(
				&service_ring.completions,
				ring.Record{
					kind   = u32(wide_grants.Collector_Ring_Status.Bad_Command),
					tag    = command.tag,
					values = errors.ring_fail(command.kind, .Out_Of_Range, .Bytes, 1, i64(record_offset), i64(service_region_bytes)),
				},
			)
			return
		}
		intrinsics.mem_copy_non_overlapping(&copied_act_record, rawptr(&service_region_base[record_offset]), size_of(wide_grants.Act_Record))
		refusal := collector_core.collector_append_prebuilt(&manager_state.collector, &copied_act_record)
		status_code := u32(wide_grants.Collector_Ring_Status.Ok)
		if refusal == .Act_Log_Full {
			status_code = u32(wide_grants.Collector_Ring_Status.Busy)
		} else if refusal != .None {
			status_code = u32(wide_grants.Collector_Ring_Status.Refused)
		}
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = status_code,
				tag    = command.tag,
				values = {u64(refusal), u64(manager_state.collector.count), manager_state.collector.next_sequence, 0, 0, 0, 0},
			},
		)
	case .Verify_Act_Chain:
		refusal, failing_index := collector_core.manager_verify_chain(&manager_state)
		status_code := refusal == .None ? u32(wide_grants.Collector_Ring_Status.Ok) : u32(wide_grants.Collector_Ring_Status.Refused)
		if refusal != .None {
			system.log_fact(.Error, Chain_Verification_Failed{failing_index = failing_index, refusal_code = u64(refusal)})
		}
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = status_code,
				tag    = command.tag,
				values = {u64(refusal), failing_index, u64(manager_state.collector.count), manager_state.collector.verify_calls, 0, 0, 0},
			},
		)
	case .Query_By_Grant:
		grant_serial := command.values[0]
		output_offset := command.values[1]
		max_entries := min(u32(command.values[2]), u32(QUERY_STAGING_CAPACITY))
		copied, total := collector_core.collector_query_by_grant(&manager_state.collector, grant_serial, query_staging[:max_entries])
		if copied > 0 {
			byte_count := u64(copied) * size_of(wide_grants.Act_Record)
			if !region_range_valid(output_offset, byte_count) {
				ring.push(
					&service_ring.completions,
					ring.Record{
						kind   = u32(wide_grants.Collector_Ring_Status.Bad_Command),
						tag    = command.tag,
						values = errors.ring_fail(command.kind, .Out_Of_Range, .Bytes, 2, i64(output_offset), i64(service_region_bytes)),
					},
				)
				return
			}
			intrinsics.mem_copy_non_overlapping(rawptr(&service_region_base[output_offset]), &query_staging[0], int(byte_count))
		}
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = u32(wide_grants.Collector_Ring_Status.Ok),
				tag    = command.tag,
				values = {u64(copied), u64(total), u64(manager_state.collector.count), 0, 0, 0, 0},
			},
		)
	case .Query_By_Window:
		window_id := command.values[0]
		output_offset := command.values[1]
		max_entries := min(u32(command.values[2]), u32(QUERY_STAGING_CAPACITY))
		copied, total := collector_core.collector_query_by_window(&manager_state.collector, window_id, query_staging[:max_entries])
		if copied > 0 {
			byte_count := u64(copied) * size_of(wide_grants.Act_Record)
			if !region_range_valid(output_offset, byte_count) {
				ring.push(
					&service_ring.completions,
					ring.Record{
						kind   = u32(wide_grants.Collector_Ring_Status.Bad_Command),
						tag    = command.tag,
						values = errors.ring_fail(command.kind, .Out_Of_Range, .Bytes, 2, i64(output_offset), i64(service_region_bytes)),
					},
				)
				return
			}
			intrinsics.mem_copy_non_overlapping(rawptr(&service_region_base[output_offset]), &query_staging[0], int(byte_count))
		}
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = u32(wide_grants.Collector_Ring_Status.Ok),
				tag    = command.tag,
				values = {u64(copied), u64(total), u64(manager_state.collector.count), 0, 0, 0, 0},
			},
		)
	case .Query_Status:
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = u32(wide_grants.Collector_Ring_Status.Ok),
				tag    = command.tag,
				values = {
					manager_state.counters.active_grants,
					manager_state.counters.total_grants_created,
					manager_state.counters.total_grants_revoked,
					manager_state.counters.total_grants_expired,
					manager_state.counters.total_acts_permitted,
					manager_state.counters.total_acts_blocked,
					u64(manager_state.collector.count),
				},
			},
		)
	}
}

// entry initializes the freestanding collector service ring, data region, and
// wide-grant manager, then loops over commands and monotonic expiry checks.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	status_open: system.Status
	if service_ring, status_open = system.ring_open(ctx.handles[wide_grants.SERVICE_RING_SLOT]); status_open != .Ok {
		fail("no collector service ring")
	}

	region_handle := ctx.handles[wide_grants.SERVICE_REGION_SLOT]
	if region_handle != 0 {
		pages, size_status := system.memory_size(region_handle)
		if size_status != .Ok || pages == 0 {
			fail("the collector data region has no pages")
		}
		address, map_status := system.memory_map(region_handle, {.Write})
		if map_status != .Ok {
			fail("cannot map the collector data region")
		}
		service_region_base = ([^]u8)(address)
		service_region_bytes = pages * system.PAGE_SIZE
	}

	principal_id := ctx.values[wide_grants.CONTEXT_VALUE_PRINCIPAL_SLOT]
	if !collector_core.manager_init(&manager_state, principal_id) {
		fail("cannot initialize collector state")
	}

	system.log_fact(.Info, Service_Ready{principal_id = principal_id, act_capacity = u64(manager_state.collector.capacity)})

	for {
		wait := system.wait_begin()
		now_ms := system.time()
		if expired := collector_core.manager_expire_grants(&manager_state, now_ms); expired > 0 {
			system.log_fact(.Info, Grants_Expired{expired_grants = u64(expired)})
		}

		answered := false
		drained := 0
		for drained < wide_grants.REQUESTS_PER_PASS && ring.count(&service_ring.completions) < ring.capacity(&service_ring.completions) {
			command := system.receive(&service_ring.commands) or_break
			handle_command(command, now_ms)
			answered = true
			drained += 1
		}

		if answered {
			system.wake_reader(&service_ring.completions)
		}
		if drained == wide_grants.REQUESTS_PER_PASS && ring.count(&service_ring.commands) > 0 {
			continue
		}
		system.wait_records(&wait, &service_ring.commands)
		if manager_state.counters.active_grants > 0 {
			system.wait_end(&wait, now_ms + 1000)
		} else {
			system.wait_end(&wait)
		}
	}
}
