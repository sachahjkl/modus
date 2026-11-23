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
//   overwrites a generation that a rollback can still select;
// - a rollback is two steps too: rollback_request shows the difference
//   back to the selected generation on the trusted display, and
//   rollback_poll commits it only when the principal accepted. A rollback
//   restores grants and role holders, so it never changes them in silence;
// - the roles of a plan of principal 0 go to the root service core through
//   the roles port, before the current object is written: a set that the
//   core refuses commits nothing, and a current object that the store
//   refuses after the core took the set gives the core the roles of the
//   generation in force again. The core and the store then name one
//   generation.
package plans_core

import "modus:contract/blake3"
import "modus:contract/chosen_values"
import "modus:contract/plan_values"
import pr "modus:contract/plans_recipes"
import "modus:contract/powerbox"
import "modus:contract/role_contract"
import rd "modus:contract/root_delegation"

// Maximum distinct principals tracked simultaneously.
MAX_PRINCIPALS :: 8

// Maximum historical applied plans retained per principal.
MAX_HISTORY_PER_PRINCIPAL :: 32

// What a pending dialog of the trusted display decides: an apply of a new
// plan, or a rollback to a generation of the history.
Pending_Step :: enum u8 {
	Apply,
	Rollback,
}

// The name that the trusted display shows for a rollback.
ROLLBACK_DISPLAY_NAME :: "rollback of the plan"

// The apply or the rollback of a principal that waits for the decision of
// the trusted display: the plan that the principal sees, and the current
// plan that its difference read. One dialog at a time for each principal.
Pending_Apply :: struct {
	active:             bool,
	step:               Pending_Step,
	display_serial:     u64,
	expected_plan_hash: blake3.Hash,
	proposed_plan_hash: blake3.Hash,
	// Apply: the plan that the principal saw.
	plan:               pr.Plan_Spec,
	// Rollback: the generation that the principal saw.
	target_generation:  u64,
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

// The port of the roles of the machine: the command Plan_Roles of the root
// ring, which gives the core the whole set of the role overrides of one
// generation of the plan of principal 0. The core refuses the set whole or
// takes it whole. A port with no procedure gives no role: an apply of a plan
// of principal 0 with a role is then refused with Roles_Refused.
Roles_Port :: struct {
	user:         rawptr,
	replace:      proc "contextless" (user: rawptr, set: ^rd.Plan_Roles_Set, step: rd.Plan_Roles_Step) -> (refusal: rd.Plan_Roles_Refusal),
	// read gives the serial and the generation of the set in force in the
	// core (the step Page). ok is false with no answer.
	read:         proc "contextless" (user: rawptr) -> (serial, generation: u64, ok: bool),
	// pause waits a short time before a set that a full service ring
	// refused (Grants_Busy) is sent again, so the services read their rings
	// meanwhile. nil: no wait, as in a host test.
	pause:        proc "contextless" (user: rawptr),
	// The serial and the generation of the set in force in the core, as
	// this service last knew them.
	serial:       u64,
	generation:   u64,
	// The core and the store name one generation. false: a set had no
	// answer, came late, or a compensation failed, or the service started:
	// the next set reads the core first and gives it the generation of the
	// store (roles_reconcile).
	synchronized: bool,
}

// The principal whose plan names the roles of the machine.
MACHINE_PRINCIPAL :: 0

// The sends again of one set that a full service ring refused
// (Grants_Busy). Past them the set is refused with Roles_Refused, and the
// service writes its own line: the rings of the services stayed full for
// each pause.
ROLES_BUSY_RESEND_BOUND :: 8

// The most commands Page with no answer whose tags the service keeps.
LATE_PAGE_TAG_CAPACITY :: 4

// The tags of the commands Page that had no answer, in a ring: the oldest
// tag leaves for a new one. A tag of 0 is no tag.
Late_Page_Tags :: struct {
	tags: [LATE_PAGE_TAG_CAPACITY]u32,
	next: int,
}

// late_page_remember keeps the tag of a command Page that had no answer.
late_page_remember :: proc "contextless" (late: ^Late_Page_Tags, tag: u32) {
	if tag == 0 {
		return
	}
	late.tags[late.next] = tag
	late.next = (late.next + 1) % LATE_PAGE_TAG_CAPACITY
}

// late_page_take says if a completion with tag answers a command Page that
// had no answer, and forgets the tag: a second completion with the same tag
// is no page. The caller closes the handle of a completion that is one.
late_page_take :: proc "contextless" (late: ^Late_Page_Tags, tag: u32) -> bool {
	if tag == 0 {
		return false
	}
	for &kept in late.tags {
		if kept == tag {
			kept = 0
			return true
		}
	}
	return false
}

// Complete fixed-capacity state of the plans service engine.
Plans_State :: struct {
	initialized:          bool,
	trusted_display_slot: u32,
	store:                pr.Private_Store_Port,
	roles:                Roles_Port,
	values:               Values_Port,
	// The refusal of the core for the last set of values that it refused.
	values_problem:       plan_values.Set_Problem,
	// The set that the values port sends: too large for the stack.
	values_set:           [plan_values.SET_SIZE]u8,
	// The refusal of the core for the last set that it refused: the log
	// names it.
	roles_refusal:        rd.Plan_Roles_Refusal,
	// A compensation of the core failed since the service last read this:
	// the log names it, and the next set reconciles first.
	roles_compensation_failed: bool,
	// The sends again of the last set that a full service ring refused:
	// ROLES_BUSY_RESEND_BOUND with the refusal Grants_Busy is a set that
	// the bound refused, which the service logs.
	roles_busy_resends:   u32,
	// The refusal of the core for the roles of the current generation of
	// principal 0 in the store, when it names their content: the boot image
	// cannot hold them, and the core holds the roles of the image. None
	// when the core holds the roles of the store.
	roles_stored_refusal:      rd.Plan_Roles_Refusal,
	// The tags of the commands Page that had no answer: a late completion
	// of one of them holds a handle of the roles page, which the service
	// closes.
	roles_late_pages:          Late_Page_Tags,
	// The set that the roles port sends: too large for the stack of a
	// service.
	roles_set:            rd.Plan_Roles_Set,
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
	added:          [pr.PLAN_DISPLAY_ITEM_CAPACITY * (pr.PLAN_DISPLAY_ITEM_BYTES + len(pr.PLAN_DISPLAY_ITEM_SEPARATOR))]u8,
	added_length:   int,
	added_count:    int,
	removed:        [pr.PLAN_DISPLAY_ITEM_CAPACITY * (pr.PLAN_DISPLAY_ITEM_BYTES + len(pr.PLAN_DISPLAY_ITEM_SEPARATOR))]u8,
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

// roles_port_bind gives the state the port of the roles of the machine,
// with the serial and the generation of the set in force in the core. The
// port starts unsynchronized: a service that stopped between the answer of
// the core and the commit of the store left them apart, and the first set
// reconciles them (roles_reconcile).
roles_port_bind :: proc "contextless" (state: ^Plans_State, port: Roles_Port) {
	state.roles = port
	state.roles.synchronized = false
}

// roles_reconcile reads the serial and the generation of the set in force in
// the core, and when the core does not hold the roles of the current
// generation of principal 0 in the store, gives it that generation with the
// step Rollback. The port is then synchronized. A refusal leaves it
// unsynchronized, and the next set tries again.
//
// A refusal of the content of that generation (a module that this boot
// image lacks, a contract that it does not fill) comes again on each try:
// it is a known difference, kept in roles_stored_refusal. The core then
// gets the roles of the image (generation 0) when it holds another set,
// and the port is synchronized, so the next apply or rollback is sent.
roles_reconcile :: proc "contextless" (state: ^Plans_State) -> pr.Plan_Refusal {
	if state.roles.replace == nil || state.roles.read == nil {
		return .None
	}
	serial, generation, read := state.roles.read(state.roles.user)
	if !read {
		state.roles_refusal = .Stale_Serial
		return .Roles_Refused
	}
	state.roles.serial, state.roles.generation = serial, generation
	entry, entry_refusal := principal_entry(state, MACHINE_PRINCIPAL)
	if entry_refusal != .None {
		return entry_refusal
	}
	current_plan, current_record, _ := entry_current_plan(entry)
	stored_refusal := rd.Plan_Roles_Refusal.None
	if generation != current_record.generation {
		if refusal := roles_send(state, current_plan, current_record.generation, .Rollback); refusal != .None {
			if !rd.plan_roles_refusal_of_content(state.roles_refusal) {
				return refusal
			}
			stored_refusal = state.roles_refusal
			if state.roles.generation != 0 {
				if defaults_refusal := roles_send(state, nil, 0, .Rollback); defaults_refusal != .None {
					return defaults_refusal
				}
			}
		}
	}
	state.roles_stored_refusal = stored_refusal
	state.roles.synchronized = true
	return .None
}

// roles_start reconciles the core with the store at the start of the
// service, and says what the start of the machine holds: the outcome that
// the service sends with the step Loaded.
roles_start :: proc "contextless" (state: ^Plans_State) -> rd.Plan_Roles_Load_Outcome {
	if state.roles.replace == nil || state.roles.read == nil {
		return .Core_Unread
	}
	refusal := roles_reconcile(state)
	if refusal == .None {
		// The core gets the values of the generation in force at each start
		// of this service: it keeps none across a start of the machine.
		if current, record, found := current_plan(state, MACHINE_PRINCIPAL); found {
			_ = values_give(state, MACHINE_PRINCIPAL, current, record.generation, .Rollback)
		}
		if state.roles_stored_refusal != .None {
			return .Plan_Refused
		}
		_, record, found := current_plan(state, MACHINE_PRINCIPAL)
		if !found || record.generation == 0 {
			return .No_Plan
		}
		return .Applied
	}
	if refusal == .Roles_Refused {
		// Only a refusal of the order of the sets, or no answer, comes
		// back from roles_reconcile: a refusal of the content is a known
		// difference.
		return .Core_Unread
	}
	return .Store_Unread
}

// roles_send writes the set of plan with the serial in force and sends it
// once. A set with no answer, or one that comes after another, leaves the
// port unsynchronized.
@(private = "file")
roles_send :: proc "contextless" (state: ^Plans_State, plan: ^pr.Plan_Spec, generation: u64, step: rd.Plan_Roles_Step) -> pr.Plan_Refusal {
	if !plan_roles_set_of(plan, generation, state.roles.serial, &state.roles_set) {
		state.roles_refusal = .Duplicate_Role
		return .Roles_Refused
	}
	// A full service ring refuses the set with nothing changed: the set is
	// sent again, after a pause, at most ROLES_BUSY_RESEND_BOUND times.
	refusal := state.roles.replace(state.roles.user, &state.roles_set, step)
	state.roles_busy_resends = 0
	for refusal == .Grants_Busy && state.roles_busy_resends < ROLES_BUSY_RESEND_BOUND {
		if state.roles.pause != nil {
			state.roles.pause(state.roles.user)
		}
		state.roles_busy_resends += 1
		refusal = state.roles.replace(state.roles.user, &state.roles_set, step)
	}
	state.roles_refusal = refusal
	if refusal != .None {
		if refusal == .Stale_Serial {
			state.roles.synchronized = false
		}
		return .Roles_Refused
	}
	state.roles.serial += 1
	state.roles.generation = generation
	// The core holds the roles of a generation of the store again; a
	// reconciliation that falls back to the image writes its refusal after.
	state.roles_stored_refusal = .None
	return .None
}

// roles_compensate gives the core the roles of the generation in force in
// the store again, after the store refused a commit that the core took. A
// failed compensation leaves the core and the store apart: the port is
// unsynchronized, the service logs it, and the next set reconciles first.
@(private = "file")
roles_compensate :: proc "contextless" (state: ^Plans_State, principal: u64, entry: ^Principal_Plans_State) {
	if principal != MACHINE_PRINCIPAL {
		return
	}
	previous_plan, previous_record, _ := entry_current_plan(entry)
	_ = values_give(state, principal, previous_plan, previous_record.generation, .Rollback)
	if roles_give(state, principal, previous_plan, previous_record.generation, .Rollback) != .None {
		state.roles.synchronized = false
		state.roles_compensation_failed = true
	}
}

// plan_roles_set_of writes the set of the role overrides of a plan: for each
// role, the module that callers reach, the outermost of its chain of
// interposition. A plan with no plan (nil) is the set of the defaults of
// the image. ok is false for a role with more than one outermost module,
// which one override cannot name.
plan_roles_set_of :: proc "contextless" (plan: ^pr.Plan_Spec, generation, serial: u64, set: ^rd.Plan_Roles_Set) -> (ok: bool) {
	set^ = {generation = generation, expected_serial = serial}
	if plan == nil {
		return true
	}
	count := min(plan.entry_count, pr.MAX_PLAN_ENTRIES)
	named: [role_contract.Role]bool
	for index in 0 ..< count {
		entry := &plan.entries[index]
		if entry.kind_word != u64(pr.Plan_Entry_Kind.Role_Holder) {
			continue
		}
		interposed := false
		for other_index in 0 ..< count {
			other := &plan.entries[other_index]
			if other_index != index && other.kind_word == entry.kind_word && other.role_word == entry.role_word && other.interposed_over_hash == entry.module_hash {
				interposed = true
				break
			}
		}
		if interposed {
			continue
		}
		role, role_known := role_contract.role_from_word(entry.role_word)
		if !role_known || named[role] || set.override_count >= rd.PLAN_ROLES_OVERRIDE_CAPACITY {
			return false
		}
		named[role] = true
		set.overrides[set.override_count] = {role_word = entry.role_word, module_hash = entry.module_hash}
		set.override_count += 1
	}
	return true
}

// roles_give sends the core the roles of plan as the set of a generation.
// Only the plan of principal 0 names the roles of the machine: the plan of
// another principal sends nothing.
@(private = "package")
roles_give :: proc "contextless" (state: ^Plans_State, principal: u64, plan: ^pr.Plan_Spec, generation: u64, step: rd.Plan_Roles_Step) -> pr.Plan_Refusal {
	if principal != MACHINE_PRINCIPAL {
		return .None
	}
	if state.roles.replace == nil {
		if !plan_roles_set_of(plan, generation, state.roles.serial, &state.roles_set) {
			state.roles_refusal = .Duplicate_Role
			return .Roles_Refused
		}
		if state.roles_set.override_count == 0 {
			return .None
		}
		state.roles_refusal = .Not_In_Image
		return .Roles_Refused
	}
	if !state.roles.synchronized {
		if refusal := roles_reconcile(state); refusal != .None {
			return refusal
		}
	}
	refusal := roles_send(state, plan, generation, step)
	if refusal == .None || state.roles.synchronized {
		return refusal
	}
	// The set had no answer or came after another: read the core, give it
	// the generation of the store, and send the set once more.
	if reconcile_refusal := roles_reconcile(state); reconcile_refusal != .None {
		return reconcile_refusal
	}
	return roles_send(state, plan, generation, step)
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
	// The roles go to the core before the commit: a set that the core
	// refuses commits nothing.
	previous_plan, previous_record, _ := entry_current_plan(entry)
	if refusal = plan_give(state, plan.principal, plan, next_generation, .Apply, previous_plan, previous_record.generation); refusal != .None {
		return {}, refusal
	}
	current_name := pr.plan_object_name(plan.principal, 0, true)
	if pr.private_store_write(&state.store, pr.private_object_name_text(&current_name), state.object_bytes[:current_written]) != .Ok {
		// The core took the roles of a generation that the store did not
		// commit: it gets the roles of the generation in force again.
		roles_compensate(state, plan.principal, entry)
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

// decimal_put writes a word in decimal after length, as text_put writes a
// text: the bytes that do not fit are not written, and the length still
// counts them, so the caller refuses a line past its bound.
@(private = "file")
decimal_put :: proc "contextless" (text: []u8, length: int, word: u64) -> int {
	digits: [20]u8
	place := len(digits)
	value := word
	for {
		place -= 1
		digits[place] = u8('0' + value % 10)
		value /= 10
		if value == 0 {
			break
		}
	}
	return text_put(text, length, string(digits[place:]))
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
		case .Value:
			// A lock and a default read apart: a lock holds over the choice
			// of the principal.
			layer_word := item.change == .Removed ? item.old_value_layer_word : item.new_value_layer_word
			kind_text = layer_word == u64(chosen_values.Layer.Locked) ? "lock " : "value "
		}
		length = text_put(text[:], length, kind_text)
		length = text_put(text[:], length, string(item.name_bytes[:item.name_length]))
		if item.entry_kind == .Value && item.change != .Removed {
			length = text_put(text[:], length, " = ")
			if item.new_value_kind_word == u64(chosen_values.Entry_Kind.Text) {
				// In quotes: the border of the plan took no control byte, so
				// the text is one item of the list, whole.
				length = text_put(text[:], length, "\"")
				length = text_put(text[:], length, string(item.new_value_text[:min(int(item.new_value_text_length), pr.PLAN_VALUE_TEXT_BYTES)]))
				length = text_put(text[:], length, "\"")
			} else {
				length = decimal_put(text[:], length, item.new_value_word)
			}
		}
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
			// A value of the plan can widen an access or spend a resource:
			// each change of one is on the side of the additions.
			widens := item.added_grants_mask != 0 || item.old_module_hash != item.new_module_hash || (item.old_store_rights == .Read_Only && item.new_store_rights == .Read_Write) || item.entry_kind == .Value
			if item.entry_kind == .Store_Grant {
				length = text_put(text[:], length, item.new_store_rights == .Read_Write ? " read write" : " read")
			} else if item.entry_kind != .Value {
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
				lists.added_length = text_put(lists.added[:], lists.added_length, pr.PLAN_DISPLAY_ITEM_SEPARATOR)
			}
			lists.added_length = text_put(lists.added[:], lists.added_length, string(text[:length]))
			lists.added_count += 1
		} else {
			if lists.removed_count >= pr.PLAN_DISPLAY_ITEM_CAPACITY {
				return .Display_Refused
			}
			if lists.removed_count > 0 {
				lists.removed_length = text_put(lists.removed[:], lists.removed_length, pr.PLAN_DISPLAY_ITEM_SEPARATOR)
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
	if refusal = pending_dialog_clear(entry, display); refusal != .None {
		return 0, refusal
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
		step               = .Apply,
		display_serial     = serial,
		expected_plan_hash = out_diff.current_plan_hash,
		proposed_plan_hash = out_diff.proposed_plan_hash,
		plan               = proposed^,
	}
	return serial, .None
}

// pending_dialog_clear refuses a second dialog while the dialog of an
// earlier apply or rollback of the principal still shows, and drops a
// pending step whose dialog closed or was replaced, uncommitted.
@(private = "file")
pending_dialog_clear :: proc "contextless" (entry: ^Principal_Plans_State, display: ^Trusted_Display_Port) -> pr.Plan_Refusal {
	if !entry.pending.active {
		return .None
	}
	decision, polled := display_poll(display, entry.pending.display_serial)
	if polled && decision == .Pending {
		return .Apply_Pending
	}
	entry.pending = {}
	return .None
}

// pending_decision reads the decision of the principal on the pending
// step of ticket. finished is false while the dialog shows. A refusal of
// the principal, a dialog that the display no longer knows and a display
// that does not answer drop the pending step; accepted is true only for an
// accepted dialog of the step.
@(private = "file")
pending_decision :: proc "contextless" (entry: ^Principal_Plans_State, display: ^Trusted_Display_Port, ticket: u64, step: Pending_Step) -> (accepted: bool, finished: bool, refusal: pr.Plan_Refusal) {
	if ticket == 0 || !entry.pending.active || entry.pending.step != step || entry.pending.display_serial != ticket {
		return false, true, .No_Pending_Apply
	}
	decision, polled := display_poll(display, ticket)
	if !polled {
		entry.pending = {}
		return false, true, .Display_Refused
	}
	switch decision {
	case .Pending:
		return false, false, .None
	case .Refused:
		entry.pending = {}
		return false, true, .Refused_By_Principal
	case .Unknown:
		entry.pending = {}
		return false, true, .Display_Refused
	case .Accepted:
	}
	return true, true, .None
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
	accepted: bool
	accepted, finished, refusal = pending_decision(entry, display, ticket, .Apply)
	if !accepted {
		return {}, finished, refusal
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

// pending_ticket gives the ticket of the pending apply or rollback of
// principal, or 0.
pending_ticket :: proc "contextless" (state: ^Plans_State, principal: u64) -> u64 {
	entry := find_principal(state, principal)
	if entry == nil || !entry.pending.active {
		return 0
	}
	return entry.pending.display_serial
}

// rollback_request shows on the trusted display the difference between the
// current plan of principal and the generation that a rollback selects: the
// immediately preceding one (when has_target is false) or target_generation
// (when true). It keeps the rollback as the pending step of the principal
// under the serial of the dialog, which it gives as the ticket of
// rollback_poll. It commits nothing and gives the core no role.
//
// It refuses: a history with no generation to select; a generation whose
// plan equals the current plan (No_Change); a difference that the dialog
// cannot show whole; a display that does not show it; and a second dialog
// while the dialog of an earlier apply or rollback still shows.
rollback_request :: proc "contextless" (
	state: ^Plans_State,
	display: ^Trusted_Display_Port,
	principal: u64,
	out_diff: ^pr.Plan_Difference,
	lists: ^Plan_Display_Lists,
	target_generation: u64 = 0,
	has_target: bool = false,
) -> (ticket: u64, refusal: pr.Plan_Refusal) {
	defer if refusal != .None {
		state.counters.total_refusals += 1
	}
	if out_diff == nil || lists == nil {
		return 0, .Buffer_Too_Small
	}
	out_diff^ = {}
	lists^ = {}
	entry, entry_refusal := principal_entry(state, principal)
	if entry_refusal != .None {
		return 0, entry_refusal
	}
	if refusal = pending_dialog_clear(entry, display); refusal != .None {
		return 0, refusal
	}
	if entry.history_count == 0 || entry.current_generation == 0 {
		return 0, .Empty_History
	}
	selected: pr.Applied_Plan_Record
	selected, refusal = pr.plan_rollback_check(entry.history[:entry.history_count], entry.current_generation, target_generation, has_target)
	if refusal != .None {
		return 0, refusal
	}
	selected_index := find_generation_index(entry, selected.generation)
	if selected_index < 0 {
		return 0, .Unknown_Generation
	}
	cur_plan, _, _ := entry_current_plan(entry)
	if refusal = pr.plan_diff_compute(cur_plan, &entry.plans[selected_index], out_diff); refusal != .None {
		return 0, refusal
	}
	if out_diff.proposed_plan_hash != selected.plan_hash {
		return 0, .Store_Damaged
	}
	if !out_diff.has_changes || out_diff.change_count == 0 {
		return 0, .No_Change
	}
	if out_diff.change_count > pr.MAX_PLAN_DIFF_CHANGES {
		return 0, .Display_Refused
	}
	if refusal = display_lists_of_difference(out_diff, lists); refusal != .None {
		return 0, refusal
	}
	if display == nil || display.ask == nil {
		return 0, .Consent_Required
	}
	serial, shown := display.ask(display.user, ROLLBACK_DISPLAY_NAME, string(lists.added[:lists.added_length]), string(lists.removed[:lists.removed_length]))
	if !shown || serial == 0 {
		return 0, .Display_Refused
	}
	state.counters.total_diffs += 1
	entry.pending = {
		active             = true,
		step               = .Rollback,
		display_serial     = serial,
		expected_plan_hash = out_diff.current_plan_hash,
		proposed_plan_hash = selected.plan_hash,
		target_generation  = selected.generation,
	}
	return serial, .None
}

// rollback_poll reads the decision of the principal on the pending rollback
// of ticket. While the dialog shows, finished is false and nothing changes.
// When the principal accepted, it rolls back to the generation that the
// principal saw, unless the current plan changed since its difference
// (Stale_Current_Plan). A refusal of the principal, a dialog that the
// display no longer knows and a display that does not answer drop the
// pending rollback and change nothing else. Each finished poll ends the
// pending rollback.
rollback_poll :: proc "contextless" (
	state: ^Plans_State,
	display: ^Trusted_Display_Port,
	principal: u64,
	ticket: u64,
) -> (selected: pr.Applied_Plan_Record, finished: bool, refusal: pr.Plan_Refusal) {
	defer if refusal != .None {
		state.counters.total_refusals += 1
	}
	entry, entry_refusal := principal_entry(state, principal)
	if entry_refusal != .None {
		return {}, true, entry_refusal
	}
	accepted: bool
	accepted, finished, refusal = pending_decision(entry, display, ticket, .Rollback)
	if !accepted {
		return {}, finished, refusal
	}
	pending := entry.pending
	entry.pending = {}
	_, current_record, current_found := entry_current_plan(entry)
	if !current_found || current_record.plan_hash != pending.expected_plan_hash {
		return {}, true, .Stale_Current_Plan
	}
	selected_index := find_generation_index(entry, pending.target_generation)
	if selected_index < 0 {
		return {}, true, .Unknown_Generation
	}
	if entry.history[selected_index].plan_hash != pending.proposed_plan_hash {
		return {}, true, .Untrusted_Consent
	}
	selected, refusal = rollback_commit(state, principal, pending.target_generation, true)
	return selected, true, refusal
}

// rollback_commit moves current_generation of principal to the immediately
// preceding generation (when has_target is false) or to target_generation
// (when true). It writes the current object of the store, which is the
// commit, then the tables, and writes no plan: a subsequent apply writes
// highest_generation + 1. Only rollback_poll calls it outside the tests of
// this package: a rollback needs the decision of the principal.
@(private)
rollback_commit :: proc "contextless" (
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
	// The core takes the roles of the selected generation before the
	// commit: a set that it refuses rolls nothing back.
	selected_index := find_generation_index(entry, selected.generation)
	if selected_index < 0 {
		return {}, .Unknown_Generation
	}
	previous_plan, previous_record, _ := entry_current_plan(entry)
	if refusal = plan_give(state, principal, &entry.plans[selected_index], selected.generation, .Rollback, previous_plan, previous_record.generation); refusal != .None {
		return {}, refusal
	}
	current_name := pr.plan_object_name(principal, 0, true)
	if pr.private_store_write(&state.store, pr.private_object_name_text(&current_name), state.object_bytes[:written]) != .Ok {
		// The core holds the roles of a generation that the store did not
		// make current: it gets the roles of the generation in force again.
		roles_compensate(state, principal, entry)
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
