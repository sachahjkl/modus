// The exports of the plans service that act for the principal of the caller
// (src/md/features/declarations.md, "Apply, the difference and the
// rollback"). The root service writes the principal of each connection, so
// a caller names no principal: it can see and change only its own plans.
package plans_service

import "base:intrinsics"
import "internal:plans/plans_core"
import "modus:contract/blake3"
import "modus:contract/errors"
import "modus:contract/isolated"
import pr "modus:contract/plans_recipes"
import "modus:system"

// The failures of the exports of this file, each with its error record.
ERROR_NO_CALLER :: i64(-1) // No_Grant, Connection: the call came through no connection.
ERROR_ACTS_FOR_PRINCIPAL :: i64(-2) // No_Grant, Acts_For_Principal: the caller does not act for its principal.
ERROR_NOT_READY :: i64(-3) // State, Requests: the service has not started its tables.
ERROR_PLAN :: i64(-4) // The plan of the caller is refused: the value found is the Plan_Refusal.
ERROR_HISTORY :: i64(-5) // The history refuses the step: the value found is the Plan_Refusal.

// The rows of the plan of the call, copied once out of the call region.
copied_rows: [pr.MAX_PLAN_ENTRIES]pr.Plan_Entry_Row
copied_expected: pr.Plan_Expected
copied_plan_name: [pr.PLAN_DISPLAY_NAME_BYTES]u8
export_lists: plans_core.Plan_Display_Lists
export_plan: pr.Plan_Spec
export_difference: pr.Plan_Difference
export_history: [plans_core.MAX_HISTORY_PER_PRINCIPAL]pr.Applied_Plan_Record

// caller_principal gives the principal of the caller of the export that
// runs, and refuses a caller that does not act for it: a plan gives the
// grants of a principal, so only a process that acts for it changes it.
@(private = "file")
caller_principal :: proc "contextless" (error: ^errors.Error_Record) -> (principal: u64, failure: i64, ok: bool) {
	connection := system.service_caller()
	if connection == nil {
		return 0, errors.fail(error, ERROR_NO_CALLER, .No_Grant, .Connection), false
	}
	if connection.grant & isolated.CALLER_ACTS_FOR_PRINCIPAL == 0 {
		return 0, errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal), false
	}
	if !service_state.initialized {
		return 0, errors.fail(error, ERROR_NOT_READY, .State, .Requests), false
	}
	return isolated.caller_principal(connection.grant), 0, true
}

// plan_refusal_fail writes the error record of a refusal of the plans
// contract: its kind says what a caller changes, and the value found is the
// refusal itself.
@(private = "file")
plan_refusal_fail :: proc "contextless" (error: ^errors.Error_Record, result: i64, refusal: pr.Plan_Refusal, bad_index: u32 = 0) -> i64 {
	found := i64(refusal)
	switch refusal {
	case .None:
		return errors.fail(error, result, .Refused, .None, 0, 0, 0, found)
	case .Empty_Plan:
		return errors.fail(error, result, .Empty, .Records, 1, 0, pr.MAX_PLAN_ENTRIES, found)
	case .Too_Many_Entries:
		return errors.fail(error, result, .Over_Limit, .Records, 1, 0, pr.MAX_PLAN_ENTRIES, found)
	case .Bad_Entry_Kind, .Bad_Role, .Zero_Module_Hash, .Bad_Start_Grant, .Bad_Store_Rights, .Invalid_Name, .Duplicate_Entry, .Cyclic_Role_Chain, .Trusted_Path_Forbidden, .Principal_Mismatch:
		return errors.fail(error, result, .Bad_Value, .Records, 1, i64(bad_index), 0, found)
	case .Buffer_Too_Small, .Truncated, .Trailing_Bytes, .Bad_Header, .Zero_Plan_Hash:
		return errors.fail(error, result, .Damaged, .Versions, 0, 0, 0, found)
	case .Empty_History, .Unknown_Generation, .Already_At_Generation:
		return errors.fail(error, result, .Absent, .Versions, 0, 0, 0, found)
	case .Stale_Current_Plan:
		return errors.fail(error, result, .State, .Versions, 2, 0, 0, found)
	case .Consent_Required, .Untrusted_Consent:
		return errors.fail(error, result, .No_Grant, .Display, 0, 0, 0, found)
	case .History_Full:
		return errors.fail(error, result, .Full, .Versions, 0, plans_core.MAX_HISTORY_PER_PRINCIPAL, plans_core.MAX_HISTORY_PER_PRINCIPAL, found)
	case .No_Change:
		return errors.fail(error, result, .Empty, .Records, 1, 0, 0, found)
	case .Apply_Pending:
		return errors.fail(error, result, .Busy, .Display, 0, 0, 0, found)
	case .No_Pending_Apply:
		return errors.fail(error, result, .Absent, .Requests, 1, 0, 0, found)
	case .Refused_By_Principal:
		return errors.fail(error, result, .Refused, .Display, 0, 0, 0, found)
	case .Display_Refused:
		return errors.fail(error, result, .No_Answer, .Display, 0, 0, 0, found)
	case .Store_Failed:
		return errors.fail(error, result, .Device, .Store, 0, 0, 0, found)
	case .Store_Damaged:
		return errors.fail(error, result, .Damaged, .Store, 0, 0, 0, found)
	case .Roles_Refused:
		return errors.fail(error, result, .Refused, .Grants, 1, 0, 0, found)
	}
	return errors.fail(error, result, .Refused, .None, 0, 0, 0, found)
}

// plan_of_table copies the rows of a table out of the call region once, and
// gives the plan of principal that they name.
@(private = "file")
plan_of_table :: proc "contextless" (rows: ^system.Table_To_Read(pr.Plan_Entry_Row), principal: u64, error: ^errors.Error_Record) -> (failure: i64, ok: bool) {
	if rows == nil {
		return errors.fail(error, ERROR_PLAN, .Bad_Address, .None, 1), false
	}
	count := intrinsics.volatile_load(&rows.count)
	if count == 0 {
		return plan_refusal_fail(error, ERROR_PLAN, .Empty_Plan), false
	}
	if count > pr.MAX_PLAN_ENTRIES {
		return errors.fail(error, ERROR_PLAN, .Over_Limit, .Records, 1, i64(min(count, u64(max(i64)))), pr.MAX_PLAN_ENTRIES, i64(pr.Plan_Refusal.Too_Many_Entries)), false
	}
	for index in 0 ..< count {
		copied_rows[index] = intrinsics.volatile_load(&rows.records[index])
	}
	refusal, bad_index := pr.plan_of_rows(principal, copied_rows[:count], &export_plan)
	if refusal != .None {
		system.log_fact(.Warning, Plan_Command_Refused{principal = principal, refusal_code = u64(refusal)})
		return plan_refusal_fail(error, ERROR_PLAN, refusal, bad_index), false
	}
	return 0, true
}

// difference computes the difference between the current plan of the
// principal of the caller and the plan of rows, and applies nothing.
//
// - **rows**: the entries of the proposed plan, 1 to 32.
// - **summary**: one row: the counts, whether an apply needs the consent of
//   the principal, and the hash of the current plan that apply expects.
// - **result**: one row for each change, in the order of the difference.
//
// The result is the count of changes, or a negative number with an error
// record: ERROR_NO_CALLER, ERROR_ACTS_FOR_PRINCIPAL, ERROR_NOT_READY, or
// ERROR_PLAN with the refusal as the value found.
@(export, link_name = "difference")
difference :: proc "c" (rows: ^system.Table_To_Read(pr.Plan_Entry_Row), summary: ^system.Table_To_Append(pr.Plan_Difference_Summary), result: ^[]pr.Plan_Diff_Row, error: ^errors.Error_Record) -> i64 {
	principal, failure, allowed := caller_principal(error)
	if !allowed {
		return failure
	}
	if plan_failure, ok := plan_of_table(rows, principal, error); !ok {
		return plan_failure
	}
	if refusal := plans_core.compute_difference(&service_state, &export_plan, &export_difference); refusal != .None {
		system.log_fact(.Warning, Plan_Command_Refused{principal = principal, refusal_code = u64(refusal)})
		return plan_refusal_fail(error, ERROR_PLAN, refusal)
	}
	if summary != nil {
		system.table_append(summary, pr.plan_difference_summary_of(&export_difference))
	}
	count := int(export_difference.change_count)
	for index in 0 ..< count {
		if index < len(result^) {
			result[index] = pr.plan_diff_row_of_item(&export_difference.changes[index])
		}
	}
	return i64(count)
}

// apply shows the difference between the plan of rows and the current plan
// of the principal of the caller on the trusted display, and keeps the plan
// until the principal decides. It commits nothing: apply_poll reads the
// decision and commits an accepted plan.
//
// - **plan_name**: the name that the dialog shows, 1 to 48 bytes.
// - **rows**: the entries of the plan, 1 to 32.
// - **expected**: the hash of the current plan that a difference gave; zero
//   when the principal has no applied plan. An apply whose current plan
//   changed since is refused, so a principal never accepts a difference that
//   it did not see.
//
// The result is the ticket of the apply, the serial of the dialog, or a
// negative number with an error record: ERROR_NO_CALLER,
// ERROR_ACTS_FOR_PRINCIPAL, ERROR_NOT_READY, or ERROR_PLAN with the refusal
// as the value found: No_Change, Apply_Pending (the dialog of an earlier
// apply still shows), Display_Refused (the dialog cannot show the whole
// difference), Consent_Required (the service has no trusted display).
@(export, link_name = "apply")
apply :: proc "c" (plan_name: ^string, rows: ^system.Table_To_Read(pr.Plan_Entry_Row), expected: ^pr.Plan_Expected, error: ^errors.Error_Record) -> i64 {
	principal, failure, allowed := caller_principal(error)
	if !allowed {
		return failure
	}
	if plan_name == nil {
		return errors.fail(error, ERROR_PLAN, .Bad_Address, .None, 1)
	}
	name := intrinsics.volatile_load(plan_name)
	if len(name) == 0 || len(name) > pr.PLAN_DISPLAY_NAME_BYTES {
		return errors.fail(error, ERROR_PLAN, len(name) == 0 ? .Empty : .Too_Long, .Bytes, 1, i64(len(name)), pr.PLAN_DISPLAY_NAME_BYTES, i64(pr.Plan_Refusal.Invalid_Name))
	}
	intrinsics.mem_copy_non_overlapping(&copied_plan_name[0], raw_data(name), len(name))
	if expected == nil {
		return errors.fail(error, ERROR_PLAN, .Bad_Address, .None, 3)
	}
	copied_expected = intrinsics.volatile_load(expected)
	if plan_failure, ok := plan_of_table(rows, principal, error); !ok {
		return plan_failure
	}
	ticket, refusal := plans_core.apply_request(&service_state, &service_display, string(copied_plan_name[:len(name)]), &export_plan, blake3.Hash(copied_expected.current_plan_hash), &export_difference, &export_lists)
	if refusal != .None {
		system.log_fact(.Warning, Plan_Command_Refused{principal = principal, refusal_code = u64(refusal)})
		return plan_refusal_fail(error, ERROR_PLAN, refusal)
	}
	system.log_fact(.Info, Plan_Difference_Asked{ticket = ticket, principal = principal})
	return i64(min(ticket, u64(max(i64))))
}

// apply_poll reads the decision of the principal on the apply of a ticket.
// While the dialog shows, it gives 0 and changes nothing. When the
// principal accepted, it writes the plan as the generation after the
// highest one in the private store of the service, then makes it current,
// and gives the generation, with its row in result. A refused difference
// changes nothing.
//
// The result is 0, the new generation, or a negative number with an error
// record: ERROR_NO_CALLER, ERROR_ACTS_FOR_PRINCIPAL, ERROR_NOT_READY, or
// ERROR_PLAN with the refusal as the value found: Refused_By_Principal,
// No_Pending_Apply, Display_Refused, Stale_Current_Plan (another apply or a
// rollback came first), Store_Failed (nothing committed).
@(export, link_name = "apply_poll")
apply_poll :: proc "c" (ticket: i64, result: ^[]pr.Plan_Generation_Row, error: ^errors.Error_Record) -> i64 {
	principal, failure, allowed := caller_principal(error)
	if !allowed {
		return failure
	}
	if ticket < 1 {
		return errors.fail(error, ERROR_PLAN, .Bad_Value, .Requests, 1, ticket, max(i64), i64(pr.Plan_Refusal.No_Pending_Apply))
	}
	record, finished, refusal := plans_core.apply_poll(&service_state, &service_display, principal, u64(ticket), system.time(), &export_difference)
	if refusal != .None {
		system.log_fact(.Warning, Plan_Command_Refused{principal = principal, refusal_code = u64(refusal)})
		return plan_refusal_fail(error, ERROR_PLAN, refusal)
	}
	if !finished {
		return 0
	}
	system.log_fact(.Info, Plan_Applied{generation = record.generation, principal = principal})
	if len(result^) > 0 {
		result[0] = pr.plan_generation_row_of(&record, record.generation)
	}
	return i64(min(record.generation, u64(max(i64))))
}

// rollback makes the generation before the current one the current
// generation of the principal of the caller. It writes no plan: the next
// apply still writes the generation after the highest one.
//
// The rollback writes the current object of the private store, which is its
// commit, then the tables: a store that refuses the write changes nothing.
//
// The result is the new current generation, or a negative number with an
// error record: ERROR_NO_CALLER, ERROR_ACTS_FOR_PRINCIPAL, ERROR_NOT_READY,
// or ERROR_HISTORY with the refusal as the value found: the kind Absent and
// the unit Versions when no generation comes before the current one,
// Store_Failed and Store_Damaged for the private store.
@(export, link_name = "rollback")
rollback :: proc "c" (error: ^errors.Error_Record) -> i64 {
	principal, failure, allowed := caller_principal(error)
	if !allowed {
		return failure
	}
	selected, refusal := plans_core.rollback(&service_state, principal)
	if refusal != .None {
		system.log_fact(.Warning, Plan_Command_Refused{principal = principal, refusal_code = u64(refusal)})
		return plan_refusal_fail(error, ERROR_HISTORY, refusal)
	}
	system.log_fact(.Info, Plan_Rolled_Back{generation = selected.generation, principal = principal})
	return i64(min(selected.generation, u64(max(i64))))
}

// generations gives the applied generations of the principal of the caller,
// oldest first, each with where it stands against the current one.
//
// The result is the count of generations, or a negative number with an
// error record: ERROR_NO_CALLER, ERROR_ACTS_FOR_PRINCIPAL, ERROR_NOT_READY,
// or ERROR_HISTORY when the private store cannot be read.
@(export, link_name = "generations")
generations :: proc "c" (result: ^[]pr.Plan_Generation_Row, error: ^errors.Error_Record) -> i64 {
	principal, failure, allowed := caller_principal(error)
	if !allowed {
		return failure
	}
	count, current, refusal := plans_core.history_snapshot(&service_state, principal, export_history[:])
	if refusal != .None {
		return plan_refusal_fail(error, ERROR_HISTORY, refusal)
	}
	for index in 0 ..< count {
		if index < len(result^) {
			result[index] = pr.plan_generation_row_of(&export_history[index], current)
		}
	}
	return i64(count)
}
