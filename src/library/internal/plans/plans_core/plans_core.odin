// Pure state machine for the delegated plans service
// (src/md/features/declarations.md, "Apply, the difference and the rollback").
//
// Keeps the applied plans of each principal in fixed-capacity tables with
// zero dynamic allocation, and each generation in the private store of the
// service (plans_recipes/private_store.odin):
// - computes the difference against the service's own copy of the current
//   applied plan of the principal;
// - an apply is two steps: apply_request shows the difference on the
//   trusted display and keeps the plan as the pending apply of the
//   principal; apply_poll reads the decision of the principal and commits
//   only an accepted difference whose current plan did not change since;
// - a commit writes the generation object, then the current object, then
//   the tables: a refusal of the store changes no table;
// - a rollback writes the current object only, so a later apply never
//   overwrites a generation that a rollback can still select.
package plans_core

import "modus:contract/blake3"
import pr "modus:contract/plans_recipes"
import "modus:contract/powerbox"

// Maximum distinct principals tracked simultaneously.
MAX_PRINCIPALS :: 8

// Maximum historical applied plans retained per principal.
MAX_HISTORY_PER_PRINCIPAL :: 32

// The apply of a principal that waits for the decision of the trusted
// display: the plan that the principal sees, and the current plan that its
// difference read.
Pending_Apply :: struct {
	active:             bool,
	display_serial:     u64,
	expected_plan_hash: blake3.Hash,
	proposed_plan_hash: blake3.Hash,
	plan:               pr.Plan_Spec,
}

// Per-principal authoritative applied plan table.
Principal_Plans_State :: struct {
	active:             bool,
	principal:          u64,
	current_generation: u64,
	highest_generation: u64,
	history_count:      u32,
	history:            [MAX_HISTORY_PER_PRINCIPAL]pr.Applied_Plan_Record,
	plans:              [MAX_HISTORY_PER_PRINCIPAL]pr.Plan_Spec,
	pending:            Pending_Apply,
}

// Aggregate counters for status inspection.
Plans_Counters :: struct {
	total_diffs:     u64,
	total_applies:   u64,
	total_rollbacks: u64,
	total_refusals:  u64,
}

// Complete fixed-capacity state of the plans service engine.
Plans_State :: struct {
	initialized:          bool,
	trusted_display_slot: u32,
	store:                pr.Private_Store_Port,
	principals:           [MAX_PRINCIPALS]Principal_Plans_State,
	counters:             Plans_Counters,
	// The bytes of one object of the store: a generation object is too
	// large for the stack of a service.
	object_bytes:         [pr.PLAN_GENERATION_WIRE_MOST]u8,
}

// The port of the trusted display: it shows the difference of a plan and
// gives the decision of the principal, by the serial of its dialog. The
// service binds it to the exports plan_diff_ask and plan_diff_poll of the
// holder of the Display role.
Trusted_Display_Port :: struct {
	user: rawptr,
	ask:  proc "contextless" (user: rawptr, plan_name: string, added: string, removed: string) -> (serial: u64, ok: bool),
	poll: proc "contextless" (user: rawptr, serial: u64) -> (decision: pr.Plan_Display_Decision, ok: bool),
}

// The two lists of a difference that the trusted display shows: the items
// that add or widen a grant, and the items that remove or narrow one, each
// a list of items that commas separate.
Plan_Display_Lists :: struct {
	added:          [pr.PLAN_DISPLAY_ITEM_CAPACITY * (pr.PLAN_DISPLAY_ITEM_BYTES + 2)]u8,
	added_length:   int,
	added_count:    int,
	removed:        [pr.PLAN_DISPLAY_ITEM_CAPACITY * (pr.PLAN_DISPLAY_ITEM_BYTES + 2)]u8,
	removed_length: int,
	removed_count:  int,
}

// state_init resets state, binds the trusted Display role holder slot used
// to verify Show_Plan_Difference consent answers, and binds the private
// store that keeps the generations.
state_init :: proc "contextless" (state: ^Plans_State, trusted_display_slot: u32, store: pr.Private_Store_Port) {
	state^ = {}
	state.initialized = true
	state.trusted_display_slot = trusted_display_slot
	state.store = store
}

@(private = "file")
find_principal :: proc "contextless" (state: ^Plans_State, principal: u64) -> ^Principal_Plans_State {
	for &entry in state.principals {
		if entry.active && entry.principal == principal {
			return &entry
		}
	}
	return nil
}

// principal_entry gives the table of principal, and reads it from the
// private store at its first use: its current object, then each generation
// object up to the highest one. A principal with no current object has no
// applied plan. A store that fails or holds a damaged object leaves no
// table, so no later step acts on a part of a history.
principal_entry :: proc "contextless" (state: ^Plans_State, principal: u64) -> (entry: ^Principal_Plans_State, refusal: pr.Plan_Refusal) {
	if existing := find_principal(state, principal); existing != nil {
		return existing, .None
	}
	for &candidate in state.principals {
		if !candidate.active {
			entry = &candidate
			break
		}
	}
	if entry == nil {
		return nil, .History_Full
	}
	current_name := pr.plan_object_name(principal, 0, true)
	bytes, status := pr.private_store_read(&state.store, pr.private_object_name_text(&current_name), state.object_bytes[:])
	switch status {
	case .Ok:
	case .Absent:
		entry^ = {active = true, principal = principal}
		return entry, .None
	case .Too_Large:
		return nil, .Store_Damaged
	case .Failed:
		return nil, .Store_Failed
	}
	current, current_refusal := pr.decode_plan_current(bytes, principal)
	if current_refusal != .None {
		return nil, .Store_Damaged
	}
	if current.highest_generation > MAX_HISTORY_PER_PRINCIPAL {
		return nil, .Store_Damaged
	}
	entry^ = {principal = principal}
	for generation in u64(1) ..= current.highest_generation {
		name := pr.plan_object_name(principal, generation, false)
		generation_bytes, generation_status := pr.private_store_read(&state.store, pr.private_object_name_text(&name), state.object_bytes[:])
		if generation_status != .Ok {
			entry^ = {}
			return nil, generation_status == .Failed ? .Store_Failed : .Store_Damaged
		}
		index := entry.history_count
		record, decode_refusal := pr.decode_plan_generation(generation_bytes, principal, generation, &entry.plans[index])
		if decode_refusal != .None {
			entry^ = {}
			return nil, .Store_Damaged
		}
		entry.history[index] = record
		entry.history_count += 1
	}
	current_record := entry.history[current.current_generation - 1]
	if current_record.plan_hash != current.current_plan_hash {
		entry^ = {}
		return nil, .Store_Damaged
	}
	entry.current_generation = current.current_generation
	entry.highest_generation = current.highest_generation
	entry.active = true
	return entry, .None
}

@(private = "file")
find_generation_index :: proc "contextless" (entry: ^Principal_Plans_State, generation: u64) -> int {
	if entry == nil || generation == 0 {
		return -1
	}
	for index in u32(0) ..< entry.history_count {
		if entry.history[index].generation == generation {
			return int(index)
		}
	}
	return -1
}

@(private = "file")
entry_current_plan :: proc "contextless" (entry: ^Principal_Plans_State) -> (plan: ^pr.Plan_Spec, record: pr.Applied_Plan_Record, found: bool) {
	if entry == nil || entry.current_generation == 0 {
		return nil, {}, false
	}
	idx := find_generation_index(entry, entry.current_generation)
	if idx < 0 {
		return nil, {}, false
	}
	return &entry.plans[idx], entry.history[idx], true
}

// current_plan returns the authoritative current Plan_Spec and its
// Applied_Plan_Record for principal, or found = false when no plan is
// applied or the store of the principal cannot be read.
current_plan :: proc "contextless" (state: ^Plans_State, principal: u64) -> (plan: ^pr.Plan_Spec, record: pr.Applied_Plan_Record, found: bool) {
	entry, refusal := principal_entry(state, principal)
	if refusal != .None {
		return nil, {}, false
	}
	return entry_current_plan(entry)
}

// compute_difference validates proposed and writes its Plan_Difference into
// caller-supplied out_diff against the service's authoritative current applied
// plan for proposed.principal. Applies nothing.
compute_difference :: proc "contextless" (state: ^Plans_State, proposed: ^pr.Plan_Spec, out_diff: ^pr.Plan_Difference) -> pr.Plan_Refusal {
	if out_diff == nil {
		state.counters.total_refusals += 1
		return .Buffer_Too_Small
	}
	if proposed == nil {
		out_diff^ = {}
		state.counters.total_refusals += 1
		return .Empty_Plan
	}
	entry, entry_refusal := principal_entry(state, proposed.principal)
	if entry_refusal != .None {
		out_diff^ = {}
		state.counters.total_refusals += 1
		return entry_refusal
	}
	cur_plan, _, _ := entry_current_plan(entry)
	refusal := pr.plan_diff_compute(cur_plan, proposed, out_diff)
	if refusal != .None {
		state.counters.total_refusals += 1
		return refusal
	}
	state.counters.total_diffs += 1
	return .None
}

// commit_generation writes plan as the generation after the highest one of
// entry: the generation object, then the current object, which is the
// commit, then the tables. A refusal of the store changes no table.
@(private = "file")
commit_generation :: proc "contextless" (state: ^Plans_State, entry: ^Principal_Plans_State, plan: ^pr.Plan_Spec, difference: ^pr.Plan_Difference, now_ms: u64) -> (record: pr.Applied_Plan_Record, refusal: pr.Plan_Refusal) {
	if entry.history_count >= MAX_HISTORY_PER_PRINCIPAL {
		return {}, .History_Full
	}
	next_generation := entry.highest_generation + 1
	record = pr.Applied_Plan_Record {
		plan_hash          = difference.proposed_plan_hash,
		previous_plan_hash = difference.current_plan_hash,
		generation         = next_generation,
		timestamp_ms       = now_ms,
		principal          = plan.principal,
	}
	written, encode_refusal := pr.encode_plan_generation(&record, plan, state.object_bytes[:])
	if encode_refusal != .None {
		return {}, encode_refusal
	}
	generation_name := pr.plan_object_name(plan.principal, next_generation, false)
	if pr.private_store_write(&state.store, pr.private_object_name_text(&generation_name), state.object_bytes[:written]) != .Ok {
		return {}, .Store_Failed
	}
	current := pr.Plan_Current_Record {
		principal          = plan.principal,
		current_generation = next_generation,
		highest_generation = next_generation,
		current_plan_hash  = record.plan_hash,
	}
	current_written, current_refusal := pr.encode_plan_current(&current, state.object_bytes[:])
	if current_refusal != .None {
		return {}, current_refusal
	}
	current_name := pr.plan_object_name(plan.principal, 0, true)
	if pr.private_store_write(&state.store, pr.private_object_name_text(&current_name), state.object_bytes[:current_written]) != .Ok {
		return {}, .Store_Failed
	}
	slot_index := entry.history_count
	entry.plans[slot_index] = plan^
	entry.history[slot_index] = record
	entry.history_count += 1
	entry.highest_generation = next_generation
	entry.current_generation = next_generation
	state.counters.total_applies += 1
	return record, .None
}

// apply_plan validates proposed, writes its Plan_Difference into caller-supplied
// out_diff, verifies that the current applied plan hash still matches
// expected_current_hash, enforces trusted Show_Plan_Difference consent whenever
// any grant is added or widened, and commits the new generation. On any
// refusal, zero state changes occur.
apply_plan :: proc "contextless" (
	state: ^Plans_State,
	proposed: ^pr.Plan_Spec,
	expected_current_hash: blake3.Hash,
	consent_dialog: ^powerbox.Dialog_Record,
	consent_answer: ^powerbox.Grant_Answer,
	now_ms: u64,
	out_diff: ^pr.Plan_Difference,
) -> (record: pr.Applied_Plan_Record, refusal: pr.Plan_Refusal) {
	if out_diff == nil {
		state.counters.total_refusals += 1
		return {}, .Buffer_Too_Small
	}
	if proposed == nil {
		out_diff^ = {}
		state.counters.total_refusals += 1
		return {}, .Empty_Plan
	}
	entry, entry_refusal := principal_entry(state, proposed.principal)
	if entry_refusal != .None {
		out_diff^ = {}
		state.counters.total_refusals += 1
		return {}, entry_refusal
	}
	cur_plan, _, _ := entry_current_plan(entry)
	refusal = pr.plan_diff_compute(cur_plan, proposed, out_diff)
	if refusal != .None {
		state.counters.total_refusals += 1
		return {}, refusal
	}

	// Refuse stale apply when the principal's current plan changed since the
	// difference was reviewed.
	if expected_current_hash != out_diff.current_plan_hash {
		state.counters.total_refusals += 1
		return {}, .Stale_Current_Plan
	}

	// Require verified trusted Display Show_Plan_Difference consent whenever
	// any grant is added or widened.
	if out_diff.any_grant_added {
		if consent_dialog == nil || consent_answer == nil {
			state.counters.total_refusals += 1
			return {}, .Consent_Required
		}
		if consent_dialog.action_word != u64(powerbox.Dialog_Action.Show_Plan_Difference) {
			state.counters.total_refusals += 1
			return {}, .Untrusted_Consent
		}
		if consent_dialog.session_principal != proposed.principal {
			state.counters.total_refusals += 1
			return {}, .Untrusted_Consent
		}
		if consent_dialog.item_count != 1 || consent_dialog.items[0].plan_hash != out_diff.proposed_plan_hash {
			state.counters.total_refusals += 1
			return {}, .Untrusted_Consent
		}
		if pb_refusal, _ := powerbox.answer_record_validate(consent_dialog, consent_answer, state.trusted_display_slot); pb_refusal != .None {
			state.counters.total_refusals += 1
			return {}, .Untrusted_Consent
		}
		if !consent_answer.whole_plan_accepted {
			state.counters.total_refusals += 1
			return {}, .Untrusted_Consent
		}
	}

	record, refusal = commit_generation(state, entry, proposed, out_diff, now_ms)
	if refusal != .None {
		state.counters.total_refusals += 1
		return {}, refusal
	}
	return record, .None
}

// display_lists_of_difference writes the two lists that the trusted display
// shows for difference. An item names the kind and the name of its entry;
// an added entry, and a changed one that adds or widens a grant or changes a
// module, is on the side of the additions; a removed entry, and a changed
// one that only narrows, is on the side of the removals. A difference that
// the dialog cannot show whole is refused with Display_Refused: the
// principal never accepts a line that it did not see.
display_lists_of_difference :: proc "contextless" (difference: ^pr.Plan_Difference, lists: ^Plan_Display_Lists) -> pr.Plan_Refusal {
	lists^ = {}
	for index in 0 ..< int(difference.change_count) {
		item := &difference.changes[index]
		text: [pr.PLAN_DISPLAY_ITEM_BYTES + 1]u8 // One more byte: an item past the bound is refused, not cut.
		length := 0
		kind_text := ""
		switch item.entry_kind {
		case .None:
			return .Bad_Entry_Kind
		case .Role_Holder:
			kind_text = "role "
		case .Start_Module:
			kind_text = "start "
		case .Disk_Module:
			kind_text = "disk "
		case .Store_Grant:
			kind_text = "store "
		}
		length = text_put(text[:], length, kind_text)
		length = text_put(text[:], length, string(item.name_bytes[:item.name_length]))
		addition := true
		switch item.change {
		case .None:
			return .Bad_Entry_Kind
		case .Added:
			if item.entry_kind == .Store_Grant {
				length = text_put(text[:], length, item.new_store_rights == .Read_Write ? " read write" : " read")
			}
		case .Removed:
			addition = false
		case .Changed:
			widens := item.added_grants_mask != 0 || item.old_module_hash != item.new_module_hash || (item.old_store_rights == .Read_Only && item.new_store_rights == .Read_Write)
			if item.entry_kind == .Store_Grant {
				length = text_put(text[:], length, item.new_store_rights == .Read_Write ? " read write" : " read")
			} else {
				length = text_put(text[:], length, widens ? " changed" : " narrowed")
			}
			addition = widens
		}
		if length > pr.PLAN_DISPLAY_ITEM_BYTES {
			return .Display_Refused
		}
		if addition {
			if lists.added_count >= pr.PLAN_DISPLAY_ITEM_CAPACITY {
				return .Display_Refused
			}
			if lists.added_count > 0 {
				lists.added_length = text_put(lists.added[:], lists.added_length, ", ")
			}
			lists.added_length = text_put(lists.added[:], lists.added_length, string(text[:length]))
			lists.added_count += 1
		} else {
			if lists.removed_count >= pr.PLAN_DISPLAY_ITEM_CAPACITY {
				return .Display_Refused
			}
			if lists.removed_count > 0 {
				lists.removed_length = text_put(lists.removed[:], lists.removed_length, ", ")
			}
			lists.removed_length = text_put(lists.removed[:], lists.removed_length, string(text[:length]))
			lists.removed_count += 1
		}
	}
	return .None
}

// text_put writes text at offset as far as it fits, and gives the offset
// after the whole text: a caller compares it with the bound.
@(private = "file")
text_put :: proc "contextless" (buffer: []u8, offset: int, text: string) -> int {
	for index in 0 ..< len(text) {
		if offset + index < len(buffer) {
			buffer[offset + index] = text[index]
		}
	}
	return offset + len(text)
}

// apply_request shows the difference between proposed and the current plan
// of its principal on the trusted display, and keeps proposed as the pending
// apply of the principal under the serial of the dialog, which it gives as
// the ticket of apply_poll. It commits nothing.
//
// It refuses: a stale expected_current_hash; a plan with no change; a
// difference that the dialog cannot show whole; a full history; a display
// that does not show it; and a second apply while the dialog of the first
// still shows. A pending apply whose dialog closed or was replaced is
// dropped first, uncommitted: only apply_poll commits.
apply_request :: proc "contextless" (
	state: ^Plans_State,
	display: ^Trusted_Display_Port,
	plan_name: string,
	proposed: ^pr.Plan_Spec,
	expected_current_hash: blake3.Hash,
	out_diff: ^pr.Plan_Difference,
	lists: ^Plan_Display_Lists,
) -> (ticket: u64, refusal: pr.Plan_Refusal) {
	defer if refusal != .None {
		state.counters.total_refusals += 1
	}
	if out_diff == nil || lists == nil {
		return 0, .Buffer_Too_Small
	}
	out_diff^ = {}
	lists^ = {}
	if proposed == nil {
		return 0, .Empty_Plan
	}
	if len(plan_name) == 0 || len(plan_name) > pr.PLAN_DISPLAY_NAME_BYTES {
		return 0, .Invalid_Name
	}
	entry, entry_refusal := principal_entry(state, proposed.principal)
	if entry_refusal != .None {
		return 0, entry_refusal
	}
	if entry.pending.active {
		decision, polled := display_poll(display, entry.pending.display_serial)
		if polled && decision == .Pending {
			return 0, .Apply_Pending
		}
		entry.pending = {}
	}
	cur_plan, _, _ := entry_current_plan(entry)
	if refusal = pr.plan_diff_compute(cur_plan, proposed, out_diff); refusal != .None {
		return 0, refusal
	}
	if expected_current_hash != out_diff.current_plan_hash {
		return 0, .Stale_Current_Plan
	}
	if !out_diff.has_changes || out_diff.change_count == 0 {
		return 0, .No_Change
	}
	if out_diff.change_count > pr.MAX_PLAN_DIFF_CHANGES {
		return 0, .Display_Refused
	}
	if entry.history_count >= MAX_HISTORY_PER_PRINCIPAL {
		return 0, .History_Full
	}
	if refusal = display_lists_of_difference(out_diff, lists); refusal != .None {
		return 0, refusal
	}
	if display == nil || display.ask == nil {
		return 0, .Consent_Required
	}
	serial, shown := display.ask(display.user, plan_name, string(lists.added[:lists.added_length]), string(lists.removed[:lists.removed_length]))
	if !shown || serial == 0 {
		return 0, .Display_Refused
	}
	state.counters.total_diffs += 1
	entry.pending = {
		active             = true,
		display_serial     = serial,
		expected_plan_hash = out_diff.current_plan_hash,
		proposed_plan_hash = out_diff.proposed_plan_hash,
		plan               = proposed^,
	}
	return serial, .None
}

@(private = "file")
display_poll :: proc "contextless" (display: ^Trusted_Display_Port, serial: u64) -> (decision: pr.Plan_Display_Decision, ok: bool) {
	if display == nil || display.poll == nil {
		return .Unknown, false
	}
	return display.poll(display.user, serial)
}

// apply_poll reads the decision of the principal on the pending apply of
// ticket. While the dialog shows, finished is false and nothing changes.
// When the principal accepted, it commits the plan that the principal saw,
// unless the current plan changed since its difference (Stale_Current_Plan).
// A refusal of the principal, a dialog that the display no longer knows and
// a display that does not answer drop the pending apply and change nothing
// else. Each finished poll ends the pending apply.
apply_poll :: proc "contextless" (
	state: ^Plans_State,
	display: ^Trusted_Display_Port,
	principal: u64,
	ticket: u64,
	now_ms: u64,
	out_diff: ^pr.Plan_Difference,
) -> (record: pr.Applied_Plan_Record, finished: bool, refusal: pr.Plan_Refusal) {
	defer if refusal != .None {
		state.counters.total_refusals += 1
	}
	if out_diff == nil {
		return {}, true, .Buffer_Too_Small
	}
	entry, entry_refusal := principal_entry(state, principal)
	if entry_refusal != .None {
		return {}, true, entry_refusal
	}
	if ticket == 0 || !entry.pending.active || entry.pending.display_serial != ticket {
		return {}, true, .No_Pending_Apply
	}
	decision, polled := display_poll(display, ticket)
	if !polled {
		entry.pending = {}
		return {}, true, .Display_Refused
	}
	switch decision {
	case .Pending:
		return {}, false, .None
	case .Refused:
		entry.pending = {}
		return {}, true, .Refused_By_Principal
	case .Unknown:
		entry.pending = {}
		return {}, true, .Display_Refused
	case .Accepted:
	}
	defer entry.pending = {}
	cur_plan, _, _ := entry_current_plan(entry)
	if refusal = pr.plan_diff_compute(cur_plan, &entry.pending.plan, out_diff); refusal != .None {
		return {}, true, refusal
	}
	if out_diff.current_plan_hash != entry.pending.expected_plan_hash {
		return {}, true, .Stale_Current_Plan
	}
	if out_diff.proposed_plan_hash != entry.pending.proposed_plan_hash {
		return {}, true, .Untrusted_Consent
	}
	record, refusal = commit_generation(state, entry, &entry.pending.plan, out_diff, now_ms)
	return record, true, refusal
}

// pending_ticket gives the ticket of the pending apply of principal, or 0.
pending_ticket :: proc "contextless" (state: ^Plans_State, principal: u64) -> u64 {
	entry := find_principal(state, principal)
	if entry == nil || !entry.pending.active {
		return 0
	}
	return entry.pending.display_serial
}

// rollback moves current_generation of principal to the immediately preceding
// generation (when has_target is false) or to target_generation (when true).
// It writes the current object of the store, which is the commit, then the
// tables, and writes no plan: a subsequent apply writes highest_generation + 1.
rollback :: proc "contextless" (
	state: ^Plans_State,
	principal: u64,
	target_generation: u64 = 0,
	has_target: bool = false,
) -> (selected: pr.Applied_Plan_Record, refusal: pr.Plan_Refusal) {
	defer if refusal != .None {
		state.counters.total_refusals += 1
	}
	entry, entry_refusal := principal_entry(state, principal)
	if entry_refusal != .None {
		return {}, entry_refusal
	}
	if entry.history_count == 0 || entry.current_generation == 0 {
		return {}, .Empty_History
	}
	selected, refusal = pr.plan_rollback_check(entry.history[:entry.history_count], entry.current_generation, target_generation, has_target)
	if refusal != .None {
		return {}, refusal
	}
	current := pr.Plan_Current_Record {
		principal          = principal,
		current_generation = selected.generation,
		highest_generation = entry.highest_generation,
		current_plan_hash  = selected.plan_hash,
	}
	written, encode_refusal := pr.encode_plan_current(&current, state.object_bytes[:])
	if encode_refusal != .None {
		return {}, encode_refusal
	}
	current_name := pr.plan_object_name(principal, 0, true)
	if pr.private_store_write(&state.store, pr.private_object_name_text(&current_name), state.object_bytes[:written]) != .Ok {
		return {}, .Store_Failed
	}
	entry.current_generation = selected.generation
	state.counters.total_rollbacks += 1
	return selected, .None
}

// highest_generation returns the newest generation that an apply committed for
// principal, or 0 when no apply committed one. A rollback lowers the current
// generation and leaves this one: the next apply writes the generation after it,
// so no apply overwrites a generation that a rollback can still select.
highest_generation :: proc "contextless" (state: ^Plans_State, principal: u64) -> u64 {
	entry, refusal := principal_entry(state, principal)
	if refusal != .None {
		return 0
	}
	return entry.highest_generation
}

// rollback_target returns the record that a rollback with no target selects for
// principal, with the refusal that such a rollback gives, and changes no state
// and no counter: a reader sees the generation before it asks for the rollback.
rollback_target :: proc "contextless" (state: ^Plans_State, principal: u64) -> (selected: pr.Applied_Plan_Record, refusal: pr.Plan_Refusal) {
	entry, entry_refusal := principal_entry(state, principal)
	if entry_refusal != .None {
		return {}, entry_refusal
	}
	if entry.history_count == 0 || entry.current_generation == 0 {
		return {}, .Empty_History
	}
	return pr.plan_rollback_check(entry.history[:entry.history_count], entry.current_generation)
}

// history_snapshot copies the applied_plans history of principal into out and
// reports the count copied and the active current_generation. A store that
// cannot be read gives its refusal and no row.
history_snapshot :: proc "contextless" (
	state: ^Plans_State,
	principal: u64,
	out: []pr.Applied_Plan_Record,
) -> (count: int, current_generation: u64, refusal: pr.Plan_Refusal) {
	entry, entry_refusal := principal_entry(state, principal)
	if entry_refusal != .None {
		return 0, 0, entry_refusal
	}
	limit := min(int(entry.history_count), len(out))
	for index in 0 ..< limit {
		out[index] = entry.history[index]
	}
	return limit, entry.current_generation, .None
}

// forget drops the tables of each principal and keeps the store: the next
// use of a principal reads its history from the store again, as a service
// that starts again does.
forget :: proc "contextless" (state: ^Plans_State) {
	for &entry in state.principals {
		entry = {}
	}
}
