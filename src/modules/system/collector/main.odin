// Delegated collector and wide-grant audit service
// (src/md/features/module_outputs.md; src/md/features/wide_grants.md).
//
// Maintains the per-principal append-only BLAKE3 hash-chained act record store
// and enforces wide-grant proofs, window bounds, monotonic expiry, instant
// revocation, sensitive-action blocks, and fail-closed recording.
package collector_service

import "base:intrinsics"
import "internal:collector/collector_core"
import "modus:contract/call_outcome"
import "modus:contract/date"
import "modus:contract/errors"
import "modus:contract/output"
import "modus:contract/ring"
import "modus:contract/start_list"
import "modus:contract/value_kinds"
import "modus:contract/wide_grants"
import "modus:storage_port"
import "modus:system"

// The pages of the tables of the collector, its code and its fixed state.
COLLECTOR_TABLE_PAGES :: 160

// The working memory of the collector: its tables, and the window, the
// place and the row of the index of each of the three act spaces of a wide
// grant, which it commits as each space opens (space_window_memory.odin).
// The root service widens the budget by wide_grants.SPACE_AUDIT_PAGES for
// each audit that its start list declares (src/md/features/wide_grants.md,
// "The starter pays for the audits").
// Its wiring pages are the rings of the act records of a wide grant, which
// the root service asks in its name: the pages of an asker, and for each act
// ring its compartments, its end page and its description file. The root
// service carves its wiring budget to that measure.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 181, processes = 1, threads = 1, wiring_pages = 28}
#assert(181 == COLLECTOR_TABLE_PAGES + wide_grants.ACT_SPACES_RESERVED * wide_grants.SPACE_AUDIT_PAGES)
#assert(28 == COLLECTOR_ACT_WIRING_PAGES)

// The compartment of an act record in its ring, and the pages of one act
// ring with its end page and its description file, as
// start_list.wiring_pages_of_row counts them (a host test checks the two).
COLLECTOR_ACT_COMPARTMENT :: (output.COMPARTMENT_WORD_SIZE + size_of(wide_grants.Act_Stream_Record) + output.COMPARTMENT_ALIGNMENT - 1) / output.COMPARTMENT_ALIGNMENT * output.COMPARTMENT_ALIGNMENT
COLLECTOR_ACT_RING_PAGES :: 1 + (u64(wide_grants.ACT_RING_CAPACITY) * (COLLECTOR_ACT_COMPARTMENT + size_of(ring.Record)) + ring.PAGE_SIZE - 1) / ring.PAGE_SIZE + 1 + output.DESCRIPTION_FILE_BYTES_MOST / ring.PAGE_SIZE
COLLECTOR_ACT_WIRING_PAGES :: start_list.WIRING_PAGES_OF_THE_ASKER + u64(wide_grants.ACT_SPACES_RESERVED) * COLLECTOR_ACT_RING_PAGES

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
grant_act_router: wide_grants.Grant_Act_Router
service_ring: ring.Ring
service_region_base: [^]u8
service_region_bytes: u64

// Staging buffers in BSS for copy-then-check shared memory access.
copied_create_request: wide_grants.Create_Grant_Request
copied_act_request: wide_grants.Authorize_Act_Request
copied_act_record: wide_grants.Act_Record
outbound_act_record: wide_grants.Act_Record
query_staging: [QUERY_STAGING_CAPACITY]wide_grants.Act_Record

// A Grant_Ended that the ring of the root service had no room for: it
// leaves at the next pass.
grant_ended_pending: struct {
	grant_serial: u64,
	reason:       wide_grants.Revocation_Reason,
}

// grant_ended_tell tells the root service that the collector ended a grant
// itself: its end time, or an audit ring that closed. The root service then
// ends the flow of the grant, clears its row and its mark, and ends its
// wirings (src/md/features/wide_grants.md, "The path of a grant, end to
// end").
grant_ended_tell :: proc "contextless" (grant_serial: u64, reason: wide_grants.Revocation_Reason) {
	if service_ring.head == nil || grant_serial == 0 {
		return
	}
	if !ring.push(&service_ring.completions, ring.Record{kind = u32(wide_grants.Collector_Ring_Status.Grant_Ended), tag = 0, values = {0 = grant_serial, 1 = u64(reason)}}) {
		grant_ended_pending = {grant_serial, reason}
		return
	}
	grant_ended_pending = {}
	system.wake_reader(&service_ring.completions)
}

// act_ring_closed ends the grant that holds when a ring of its act records
// ended or was closed: no act of that writer would have a reader, and a
// writer that finds no reader refuses its act, so the grant would hold with
// nothing that it can do. The ring of a grant that ended already changes
// nothing.
act_ring_closed :: proc "contextless" (now_ms: u64) {
	if grant_act_router.state != .Wired {
		return
	}
	grant_serial := grant_act_router.grant_serial
	if refusal := collector_core.manager_revoke_grant(&manager_state, grant_serial, now_ms, .Audit_Ring_Closed); refusal != .None {
		system.log_fact(.Warning, Wide_Grant_Action_Refused{refusal_code = u64(refusal), grant_serial = grant_serial})
	}
	act_end_log(wide_grants.act_wiring_revoke(&grant_act_router, &space_service.store, grant_serial, .Audit_Ring_Closed, now_ms))
	grant_ended_tell(grant_serial, .Audit_Ring_Closed)
}

// act_end_log logs an end of the act spaces of a grant that the router
// refused, and an end whose record found no room.
act_end_log :: proc "contextless" (refusal: wide_grants.Act_Wiring_Refusal) {
	if refusal != .None {
		system.log_fact(.Warning, Act_Wiring_End_Refused{refusal_code = u64(refusal), grant_serial = grant_act_router.grant_serial})
		return
	}
	if !grant_act_router.revocation_recorded {
		system.log_fact(.Warning, Act_Wiring_End_Not_Recorded{grant_serial = grant_act_router.grant_serial})
	}
}

@(private = "file")
fail :: proc "contextless" (text: string) -> ! {
	system.log_fact(.Error, Service_Failed{failure = value_kinds.text_field(text, FAILURE_FIELD_BYTES)})
	system.stop(.Failed)
}

// act_reader_check refuses a caller of the act exports that does not act
// for the principal of the collector: the act records of a wide grant are
// the audit of its holder, which the holder never reads.
@(private = "file")
act_reader_check :: proc "contextless" (error: ^errors.Error_Record) -> (failure: call_outcome.Call_Outcome, ok: bool) {
	_, failure, ok = principal_reader_of(space_service.store.principal, system.service_caller(), error)
	return failure, ok
}

// act_record_count returns the number of hash-chained act records of wide
// grants stored in the collector.
@(export)
act_record_count :: proc "c" (error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if failure, ok := act_reader_check(error); !ok {
		return failure, 0
	}
	if !manager_state.collector.initialized {
		return call_outcome.fail(error, .Wrong_State, .State, .Records)
	}
	return .Succeeded, i64(manager_state.collector.count)
}

// active_grant_count returns the number of currently active wide grants.
@(export)
active_grant_count :: proc "c" (error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if failure, ok := act_reader_check(error); !ok {
		return failure, 0
	}
	if !manager_state.collector.initialized {
		return call_outcome.fail(error, .Wrong_State, .State, .Grants)
	}
	return .Succeeded, i64(manager_state.counters.active_grants)
}

// status writes aggregate collector and wide-grant counters into out.
@(export)
status :: proc "c" (out: ^Collector_Status, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if failure, ok := act_reader_check(error); !ok {
		return failure, 0
	}
	if out == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, 1)
	}
	if !manager_state.collector.initialized {
		return call_outcome.fail(error, .Wrong_State, .State, .Records)
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
	return .Succeeded, 0
}

// verify_chain walks the full hash-chained act store and reports integrity.
@(export)
verify_chain :: proc "c" (out: ^Chain_Verification_Report, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if failure, ok := act_reader_check(error); !ok {
		return failure, 0
	}
	if out == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, 1)
	}
	if !manager_state.collector.initialized {
		return call_outcome.fail(error, .Wrong_State, .State, .Records)
	}
	refusal, failing_index := collector_core.collector_verify(&manager_state.collector)
	out^ = {
		refusal_code  = i64(refusal),
		failing_index = i64(failing_index),
		record_count  = i64(manager_state.collector.count),
		verify_calls  = i64(manager_state.collector.verify_calls),
	}
	if refusal != .None {
		system.log_fact(.Error, Chain_Verification_Failed{failing_index = failing_index, refusal_code = u64(refusal)})
		return call_outcome.fail(error, .Data_Damaged, .Damaged, .Records, 0, i64(failing_index), i64(manager_state.collector.count), i64(refusal))
	}
	return .Succeeded, 0
}

// act_records_read_for gives the act records of grant (0 for each grant)
// whose sequence is in first ..= last, oldest first, through staging. It
// serves only a caller that acts for principal.
act_records_read_for :: proc "contextless" (
	manager: ^collector_core.Wide_Grant_Manager,
	principal: u64,
	connection: ^system.Connection,
	grant: i64,
	first: i64,
	last: i64,
	result: ^system.Table_To_Append(wide_grants.Act_Record),
	staging: []wide_grants.Act_Record,
	error: ^errors.Error_Record,
) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if _, failure, ok := principal_reader_of(principal, connection, error); !ok {
		return failure, 0
	}
	if !manager.collector.initialized {
		return call_outcome.fail(error, .Wrong_State, .State, .Records)
	}
	if grant < 0 {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 1, grant, 0)
	}
	if first < 0 {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 2, first, 0)
	}
	if last < first {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 3, last, first)
	}
	if result == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, 4)
	}
	room := result.count < result.capacity ? result.capacity - result.count : 0
	copied, total, ok := collector_core.collector_query_acts(&manager.collector, u64(grant), u64(first), u64(last), staging[:min(room, u64(len(staging)))])
	if !ok {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 3, last, first)
	}
	for index in 0 ..< copied {
		system.table_append(result, staging[index])
	}
	return .Succeeded, i64(total)
}

// act_records_read gives the act records of the wide grants that this
// collector keeps, oldest first: those of grant (0 for each grant) whose
// sequence is in first ..= last. A table holds at most QUERY_STAGING_CAPACITY
// records of one call; a reader that wants more asks again after the last
// sequence that it received.
//
// The result is the count of such records, or an outcome with an error
// record: Grant_Or_Right_Missing (no connection, or a caller that does not
// act for the principal), Wrong_State (no act store yet), Argument_Refused
// (a grant, a first or a last out of its range).
@(export, link_name = "act_records_read")
act_records_read :: proc "c" (grant: i64, first: i64, last: i64, result: ^system.Table_To_Append(wide_grants.Act_Record), error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	return act_records_read_for(&manager_state, space_service.store.principal, system.service_caller(), grant, first, last, result, query_staging[:], error)
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
		// values[1]: the one end time of the grant, which the root service
		// fixed when the proof was given.
		grant_serial, refusal := collector_core.manager_create_grant(&manager_state, &copied_create_request.terms, &copied_create_request.proof, now_ms, command.values[1])
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
		// Wire the four wide-grant act audit spaces at grant creation. No wide
		// grant exists before its act records have a reader: a collector with
		// no store, or a store that cannot hold the audit spaces, refuses it.
		{
			// A grant that this one replaces ends its wiring first, with its record.
			if grant_act_router.state == .Wired && grant_act_router.grant_serial != grant_serial {
				act_end_log(wide_grants.act_wiring_revoke(&grant_act_router, &space_service.store, grant_act_router.grant_serial, .Replaced_By_Newer_Grant, now_ms))
			}
			// The rings of the grant before close now, not at the next
			// pass: once this grant holds, a record of the other grant on an
			// old ring would close a ring of this one.
			act_sources_of_replaced_grant_close() // sources.odin
			authorities, _ := wide_grants.wide_authorities_from_word(copied_create_request.terms.authorities_word)
			attach_refusal := wide_grants.Act_Wiring_Refusal.Store_Refused
			if space_service.store.store_port.write != nil {
				attach_refusal = wide_grants.act_wiring_attach(&grant_act_router, &space_service.store, grant_serial, manager_state.principal_id, authorities, copied_create_request.terms.duration_ms, now_ms)
			}
			if attach_refusal != .None {
				_ = collector_core.manager_revoke_grant(&manager_state, grant_serial, now_ms, .Principal_Revoked)
				system.log_fact(.Warning, Wide_Grant_Action_Refused{refusal_code = u64(wide_grants.Wide_Grant_Refusal.Act_Log_Full), grant_serial = grant_serial})
				status_code := attach_refusal == .Audit_Space_Full ? u32(wide_grants.Collector_Ring_Status.Busy) : u32(wide_grants.Collector_Ring_Status.Refused)
				ring.push(
					&service_ring.completions,
					ring.Record{
						kind   = status_code,
						tag    = command.tag,
						values = {u64(wide_grants.Wide_Grant_Refusal.Act_Log_Full), 0, u64(manager_state.collector.count), 0, 0, 0, 0},
					},
				)
				return
			}
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
		reason, reason_ok := wide_grants.revocation_reason_from_word(command.values[1])
		if !reason_ok {
			ring.push(
				&service_ring.completions,
				ring.Record{
					kind   = u32(wide_grants.Collector_Ring_Status.Bad_Command),
					tag    = command.tag,
					values = errors.ring_fail(command.kind, .Bad_Value, .None, 2, i64(command.values[1])),
				},
			)
			return
		}
		refusal := collector_core.manager_revoke_grant(&manager_state, grant_serial, now_ms, reason)
		if refusal == .None && grant_act_router.state == .Wired && grant_act_router.grant_serial == grant_serial {
			act_end_log(wide_grants.act_wiring_revoke(&grant_act_router, &space_service.store, grant_serial, reason, now_ms))
		}
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
		// An unknown word is refused here: it never becomes a known member.
		act_kind, act_kind_ok := wide_grants.act_kind_from_word(copied_act_request.act_kind_word)
		if !act_kind_ok {
			ring.push(
				&service_ring.completions,
				ring.Record{
					kind   = u32(wide_grants.Collector_Ring_Status.Bad_Command),
					tag    = command.tag,
					values = errors.ring_fail(command.kind, .Bad_Value, .None, 2, i64(copied_act_request.act_kind_word)),
				},
			)
			return
		}
		sensitive_action, action_ok := wide_grants.sensitive_action_from_word(copied_act_request.sensitive_action_word)
		if !action_ok {
			ring.push(
				&service_ring.completions,
				ring.Record{
					kind   = u32(wide_grants.Collector_Ring_Status.Bad_Command),
					tag    = command.tag,
					values = errors.ring_fail(command.kind, .Bad_Value, .None, 4, i64(copied_act_request.sensitive_action_word)),
				},
			)
			return
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
		refusal, failing_index := collector_core.collector_verify(&manager_state.collector)
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
	export_service, export_ok := system.service_open(ctx)
	has_delegated := false
	if ctx.handles[wide_grants.SERVICE_RING_SLOT] != 0 {
		status_open: call_outcome.Call_Outcome
		if service_ring, status_open = system.ring_open(ctx.handles[wide_grants.SERVICE_RING_SLOT]); status_open == .Succeeded {
			has_delegated = true
		}
	}
	if !export_ok && !has_delegated {
		fail("no collector service ring")
	}
	// Map the wiring ring with Receive_Handles before loading the store so wirings deliver at once.
	system.wiring_ring_open()

	region_handle := ctx.handles[wide_grants.SERVICE_REGION_SLOT]
	if region_handle != 0 {
		pages, size_status := system.memory_size(region_handle)
		if size_status != .Succeeded || pages == 0 {
			fail("the collector data region has no pages")
		}
		address, map_status := system.memory_map(region_handle, {.Write})
		if map_status != .Succeeded {
			fail("cannot map the collector data region")
		}
		service_region_base = ([^]u8)(address)
		service_region_bytes = pages * system.PAGE_SIZE
	}

	principal_id := ctx.values[wide_grants.CONTEXT_VALUE_PRINCIPAL_SLOT]
	first_key_slot :: wide_grants.CONTEXT_VALUE_AUTHORITY_KEY_FIRST_SLOT
	authority_key := wide_grants.authority_key_from_words(
		{ctx.values[first_key_slot], ctx.values[first_key_slot + 1], ctx.values[first_key_slot + 2], ctx.values[first_key_slot + 3]},
	)
	// Erase the authority key words from the context page immediately after reading.
	intrinsics.mem_zero_volatile(&ctx.values[first_key_slot], wide_grants.CONTEXT_VALUE_AUTHORITY_KEY_SLOT_COUNT * size_of(u64))
	if !collector_core.manager_init(&manager_state, principal_id, authority_key) {
		// Without the key of the unlock authority, no proof can be checked: the
		// act store still serves its reader, and each wide grant is refused.
		if !collector_core.collector_init(&manager_state.collector) {
			fail("cannot initialize collector state")
		}
		system.log_fact(.Warning, Wide_Grants_Refused_Without_Authority_Key{principal_id = principal_id})
	}
	// A process with no grant Store gets a port with no procedure: each step
	// of the spaces is then refused, so no audit space lives in memory alone.
	store_port, store_open := storage_port.bind(ctx)
	memory_port, windows := space_memory_reserve() // space_window_memory.odin
	source_links.port = link_tables_port() // link_tables.odin
	// The principal identifier, which the root service wrote in the region
	// before the start: the name of the principal in each object of the
	// store. Copied before the first request writes over it.
	identifier: [wide_grants.COLLECTOR_IDENTIFIER_SIZE]u8
	if service_region_base != nil && service_region_bytes >= wide_grants.COLLECTOR_REGION_IDENTIFIER_AT + wide_grants.COLLECTOR_IDENTIFIER_SIZE {
		copy(identifier[:], service_region_base[wide_grants.COLLECTOR_REGION_IDENTIFIER_AT:][:wide_grants.COLLECTOR_IDENTIFIER_SIZE])
	}
	if !wide_grants.space_store_init(&space_service.store, principal_id, identifier, store_port, memory_port) {
		store_open = false
		system.log_fact(.Error, Spaces_Refused_No_Identifier{principal_id = principal_id})
	}
	system.log_fact(.Info, Space_Windows_Paid{windows = u64(windows)})
	closed_date_page = date.page_of(ctx)

	system.log_fact(.Info, Service_Ready{principal_id = principal_id, act_capacity = u64(manager_state.collector.capacity), store = store_open ? 1 : 0})
	if store_open {
		// A read that fails is tried again at the first step that needs it.
		loaded := wide_grants.space_store_ready(&space_service.store)
		if loaded == .None {
			system.log_fact(.Info, Spaces_Loaded{spaces = u64(wide_grants.space_count(&space_service.store)), records = wide_grants.kept_record_count(&space_service.store), objects = u64(space_service.store.load_reads)})
		} else if loaded == .Store_Damaged {
			system.log_fact(.Error, Spaces_Store_Damaged{space = u64(space_service.store.damaged_space)})
		} else if loaded == .Older_Format {
			system.log_fact(.Error, Spaces_Older_Format{})
		}
	}

	for {
		wait := system.wait_begin(&collector_wait.set)
		now_ms := system.time()
		if expired := collector_core.manager_expire_grants(&manager_state, now_ms); expired > 0 {
			if grant_act_router.state == .Wired {
				if grant_state, expires_ms, found := collector_core.manager_grant_state(&manager_state, grant_act_router.grant_serial); found && grant_state == .Expired {
					act_end_log(wide_grants.act_wiring_expire(&grant_act_router, &space_service.store, grant_act_router.grant_serial, expires_ms, now_ms))
					grant_ended_tell(grant_act_router.grant_serial, .Time_Bound)
				}
			}
			system.log_fact(.Info, Grants_Expired{expired_grants = u64(expired)})
		}

		if export_ok {
			system.service_run(&export_service)
			system.service_wait(&wait, &export_service)
		}
		if has_delegated {
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
		}
		if grant_ended_pending.grant_serial != 0 {
			grant_ended_tell(grant_ended_pending.grant_serial, grant_ended_pending.reason)
		}
		// The sources and the pairs: after the words above, so the rings
		// that the wait holds are the rings that this pass read.
		pending := sources_pass()
		not_waited := sources_wait(&wait)
		closed_deadline := store_open ? closed_spaces_pass(now_ms) : system.WAIT_FOREVER // spaces.odin
		if manager_state.counters.active_grants > 0 || pending || not_waited || grant_ended_pending.grant_serial != 0 {
			retry := min(now_ms + PENDING_RETRY_MILLISECONDS, closed_deadline)
			system.wait_end(&wait, retry)
		} else if closed_deadline != system.WAIT_FOREVER {
			system.wait_end(&wait, closed_deadline)
		} else {
			system.wait_end(&wait)
		}
	}
}
