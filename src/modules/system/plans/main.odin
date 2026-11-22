// Delegated plans service implementing Role.Plans
// (src/md/features/declarations.md, "The services of the declarations").
//
// Computes authoritative plan differences against each principal's current
// applied plan, requires verified trusted Display Show_Plan_Difference consent
// whenever any grant is added or widened, atomically commits new generations
// to applied_plans, and executes rollbacks without writing new plan records.
package plans_service

import "base:intrinsics"
import "internal:plans/plans_core"
import "modus:contract/blake3"
import "modus:contract/errors"
import pr "modus:contract/plans_recipes"
import "modus:contract/powerbox"
import "modus:contract/ring"
import "modus:contract/value_kinds"
import "modus:system"

// Working memory budget for the freestanding plans service process and its
// fixed-capacity per-principal applied_plans tables.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 512, processes = 1, threads = 1}

// Status record returned by the status() export.
Plans_Status :: struct {
	total_diffs:     i64,
	total_applies:   i64,
	total_rollbacks: i64,
	total_refusals:  i64,
}

// Package-level BSS state so large plan tables never live on the stack.
service_state: plans_core.Plans_State
service_ring: ring.Ring
service_region_base: [^]u8
service_region_bytes: u64

// Private BSS staging buffers for copy-then-check reading of shared memory.
copied_plan: pr.Plan_Spec
copied_dialog: powerbox.Dialog_Record
copied_answer: powerbox.Grant_Answer
staged_diff: pr.Plan_Difference
staged_history: [plans_core.MAX_HISTORY_PER_PRINCIPAL]pr.Applied_Plan_Record
staged_record_wire: [pr.APPLIED_PLAN_WIRE_SIZE]u8

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

// status writes aggregate plans service counters into out.
@(export)
status :: proc "c" (out: ^Plans_Status, error: ^errors.Error_Record) -> i64 {
	if out == nil {
		return errors.fail(error, -1, .Bad_Address, .None, 1)
	}
	if !service_state.initialized {
		return errors.fail(error, -2, .State, .Requests)
	}
	out^ = {
		total_diffs     = i64(service_state.counters.total_diffs),
		total_applies   = i64(service_state.counters.total_applies),
		total_rollbacks = i64(service_state.counters.total_rollbacks),
		total_refusals  = i64(service_state.counters.total_refusals),
	}
	return 0
}

// current_generation returns the active applied plan generation of principal.
@(export)
current_generation :: proc "c" (principal: i64, error: ^errors.Error_Record) -> i64 {
	if principal < 0 {
		return errors.fail(error, -1, .Bad_Value, .None, 1, 0, max(i64), principal)
	}
	if !service_state.initialized {
		return errors.fail(error, -1, .State, .Requests)
	}
	_, rec, found := plans_core.current_plan(&service_state, u64(principal))
	if !found {
		return 0
	}
	return i64(rec.generation)
}

// diff_count returns the plan differences that the service computed, as a
// command Compute_Diff or as the first part of an apply.
@(export)
diff_count :: proc "c" (error: ^errors.Error_Record) -> i64 {
	if !service_state.initialized {
		return errors.fail(error, -1, .State, .Requests)
	}
	return i64(service_state.counters.total_diffs)
}

// apply_generation returns the newest generation that an apply committed for
// principal, or 0 when none: the next apply commits the generation after it,
// even after a rollback.
@(export)
apply_generation :: proc "c" (principal: i64, error: ^errors.Error_Record) -> i64 {
	if principal < 0 {
		return errors.fail(error, -1, .Bad_Value, .None, 1, principal, max(i64))
	}
	if !service_state.initialized {
		return errors.fail(error, -2, .State, .Requests)
	}
	return i64(plans_core.highest_generation(&service_state, u64(principal)))
}

// rollback_generation returns the generation that a rollback of principal with
// no target selects, and rolls nothing back. With no earlier generation, it
// fails with the kind Absent and the unit Versions; found is the refusal.
@(export)
rollback_generation :: proc "c" (principal: i64, error: ^errors.Error_Record) -> i64 {
	if principal < 0 {
		return errors.fail(error, -1, .Bad_Value, .None, 1, principal, max(i64))
	}
	if !service_state.initialized {
		return errors.fail(error, -2, .State, .Requests)
	}
	selected, refusal := plans_core.rollback_target(&service_state, u64(principal))
	if refusal != .None {
		return errors.fail(error, -3, .Absent, .Versions, 1, principal, 0, i64(refusal))
	}
	return i64(selected.generation)
}

@(private = "file")
handle_command :: proc "contextless" (command: ring.Record, now_ms: u64) {
	parsed, ok := pr.plans_ring_command_of_word(command.kind)
	if !ok {
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = u32(pr.Service_Ring_Status.Bad_Command),
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
				kind   = u32(pr.Service_Ring_Status.Bad_Command),
				tag    = command.tag,
				values = errors.ring_fail(command.kind, .Unsupported, .None, 0, i64(command.kind)),
			},
		)
	case .Compute_Diff:
		plan_offset := command.values[0]
		diff_offset := command.values[1]
		if !region_range_valid(plan_offset, size_of(pr.Plan_Spec)) || !region_range_valid(diff_offset, size_of(pr.Plan_Difference)) {
			ring.push(
				&service_ring.completions,
				ring.Record{
					kind   = u32(pr.Service_Ring_Status.Bad_Command),
					tag    = command.tag,
					values = errors.ring_fail(command.kind, .Out_Of_Range, .Bytes, 1, i64(plan_offset), i64(service_region_bytes)),
				},
			)
			return
		}
		intrinsics.mem_copy_non_overlapping(&copied_plan, rawptr(&service_region_base[plan_offset]), size_of(pr.Plan_Spec))
		refusal := plans_core.compute_difference(&service_state, &copied_plan, &staged_diff)
		if refusal != .None {
			system.log_fact(.Warning, Plan_Command_Refused{principal = copied_plan.principal, refusal_code = u64(refusal)})
			ring.push(
				&service_ring.completions,
				ring.Record{
					kind   = u32(pr.Service_Ring_Status.Refused),
					tag    = command.tag,
					values = {u64(refusal), 0, 0, 0, 0, 0, 0},
				},
			)
			return
		}
		intrinsics.mem_copy_non_overlapping(rawptr(&service_region_base[diff_offset]), &staged_diff, size_of(pr.Plan_Difference))
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = u32(pr.Service_Ring_Status.Ok),
				tag    = command.tag,
				values = {
					staged_diff.any_grant_added ? 1 : 0,
					staged_diff.has_changes ? 1 : 0,
					u64(staged_diff.change_count),
					u64(staged_diff.added_grants_count),
					u64(staged_diff.removed_grants_count),
					0,
					0,
				},
			},
		)
	case .Apply_Plan:
		plan_offset := command.values[0]
		expected_hash_offset := command.values[1]
		dialog_offset := command.values[2]
		answer_offset := command.values[3]
		record_out_offset := command.values[4]
		has_consent := command.values[5] != 0

		if !region_range_valid(plan_offset, size_of(pr.Plan_Spec)) || !region_range_valid(expected_hash_offset, size_of(blake3.Hash)) {
			ring.push(
				&service_ring.completions,
				ring.Record{
					kind   = u32(pr.Service_Ring_Status.Bad_Command),
					tag    = command.tag,
					values = errors.ring_fail(command.kind, .Out_Of_Range, .Bytes, 1, i64(plan_offset), i64(service_region_bytes)),
				},
			)
			return
		}
		intrinsics.mem_copy_non_overlapping(&copied_plan, rawptr(&service_region_base[plan_offset]), size_of(pr.Plan_Spec))
		expected_hash: blake3.Hash
		intrinsics.mem_copy_non_overlapping(&expected_hash, rawptr(&service_region_base[expected_hash_offset]), size_of(blake3.Hash))

		dialog_ptr: ^powerbox.Dialog_Record = nil
		answer_ptr: ^powerbox.Grant_Answer = nil
		if has_consent {
			if !region_range_valid(dialog_offset, size_of(powerbox.Dialog_Record)) || !region_range_valid(answer_offset, size_of(powerbox.Grant_Answer)) {
				ring.push(
					&service_ring.completions,
					ring.Record{
						kind   = u32(pr.Service_Ring_Status.Bad_Command),
						tag    = command.tag,
						values = errors.ring_fail(command.kind, .Out_Of_Range, .Bytes, 3, i64(dialog_offset), i64(service_region_bytes)),
					},
				)
				return
			}
			intrinsics.mem_copy_non_overlapping(&copied_dialog, rawptr(&service_region_base[dialog_offset]), size_of(powerbox.Dialog_Record))
			intrinsics.mem_copy_non_overlapping(&copied_answer, rawptr(&service_region_base[answer_offset]), size_of(powerbox.Grant_Answer))
			dialog_ptr = &copied_dialog
			answer_ptr = &copied_answer
		}

		record, refusal := plans_core.apply_plan(&service_state, &copied_plan, expected_hash, dialog_ptr, answer_ptr, now_ms, &staged_diff)
		if refusal != .None {
			system.log_fact(.Warning, Plan_Command_Refused{principal = copied_plan.principal, refusal_code = u64(refusal)})
			ring.push(
				&service_ring.completions,
				ring.Record{
					kind   = u32(pr.Service_Ring_Status.Refused),
					tag    = command.tag,
					values = {u64(refusal), 0, 0, 0, 0, 0, 0},
				},
			)
			return
		}
		if region_range_valid(record_out_offset, pr.APPLIED_PLAN_WIRE_SIZE) {
			if written, enc_ref := pr.encode_applied_plan_record(&record, staged_record_wire[:]); enc_ref == .None && written == pr.APPLIED_PLAN_WIRE_SIZE {
				intrinsics.mem_copy_non_overlapping(rawptr(&service_region_base[record_out_offset]), &staged_record_wire[0], pr.APPLIED_PLAN_WIRE_SIZE)
			}
		}
		system.log_fact(.Info, Plan_Applied{generation = record.generation, principal = record.principal})
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = u32(pr.Service_Ring_Status.Ok),
				tag    = command.tag,
				values = {record.generation, record.timestamp_ms, 0, 0, 0, 0, 0},
			},
		)
	case .Rollback_Plan:
		principal := command.values[0]
		target_gen := command.values[1]
		has_target := command.values[2] != 0
		selected, refusal := plans_core.rollback(&service_state, principal, target_gen, has_target)
		if refusal != .None {
			system.log_fact(.Warning, Plan_Command_Refused{principal = principal, refusal_code = u64(refusal)})
			ring.push(
				&service_ring.completions,
				ring.Record{
					kind   = u32(pr.Service_Ring_Status.Refused),
					tag    = command.tag,
					values = {u64(refusal), 0, 0, 0, 0, 0, 0},
				},
			)
			return
		}
		system.log_fact(.Info, Plan_Rolled_Back{generation = selected.generation, principal = principal})
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = u32(pr.Service_Ring_Status.Ok),
				tag    = command.tag,
				values = {selected.generation, selected.timestamp_ms, 0, 0, 0, 0, 0},
			},
		)
	case .Query_History:
		principal := command.values[0]
		out_offset := command.values[1]
		count, cur_gen := plans_core.history_snapshot(&service_state, principal, staged_history[:])
		if count > 0 {
			byte_len := u64(count) * size_of(pr.Applied_Plan_Record)
			if region_range_valid(out_offset, byte_len) {
				intrinsics.mem_copy_non_overlapping(rawptr(&service_region_base[out_offset]), &staged_history[0], int(byte_len))
			}
		}
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = u32(pr.Service_Ring_Status.Ok),
				tag    = command.tag,
				values = {u64(count), cur_gen, 0, 0, 0, 0, 0},
			},
		)
	}
}

// entry initializes the delegated plans service ring and serves plan diff,
// apply, rollback, and history commands until stopped.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	open_status: system.Status
	if service_ring, open_status = system.ring_open(ctx.handles[pr.PLANS_SERVICE_RING_SLOT]); open_status != .Ok {
		fail("no plans service ring")
	}
	region_handle := ctx.handles[pr.PLANS_SERVICE_REGION_SLOT]
	if region_handle != 0 {
		pages, size_status := system.memory_size(region_handle)
		if size_status != .Ok || pages == 0 {
			fail("the plans data region has no pages")
		}
		address, map_status := system.memory_map(region_handle, {.Write})
		if map_status != .Ok {
			fail("cannot map the plans data region")
		}
		service_region_base = ([^]u8)(address)
		service_region_bytes = pages * system.PAGE_SIZE
	}

	display_slot := u32(ctx.values[pr.PLANS_CONTEXT_VALUE_DISPLAY_SLOT])
	plans_core.state_init(&service_state, display_slot)
	system.log_fact(.Info, Service_Ready{display_slot = u64(display_slot)})

	for {
		wait := system.wait_begin()
		now_ms := system.time()
		answered := false
		for ring.count(&service_ring.completions) < ring.capacity(&service_ring.completions) {
			command := system.receive(&service_ring.commands) or_break
			handle_command(command, now_ms)
			answered = true
		}
		if answered {
			system.wake_reader(&service_ring.completions)
		}
		system.wait_records(&wait, &service_ring.commands)
		system.wait_end(&wait)
	}
}
