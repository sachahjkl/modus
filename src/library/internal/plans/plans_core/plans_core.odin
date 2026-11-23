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
	// Apply: the plan that the principal saw, in plan_memory, a block of
	// the memory of the core.
	plan:               pr.Plan_Spec,
	plan_memory:        []u8,
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
	// The plan of each generation, each in its block of the memory of the
	// core: a plan has any count of entries.
	plans:              [MAX_HISTORY_PER_PRINCIPAL]pr.Plan_Spec,
	plan_memory:        [MAX_HISTORY_PER_PRINCIPAL][]u8,
	pending:            Pending_Apply,
}

// The memory of the core: a block of bytes for each plan that it keeps,
// and for the bytes of an object of the store, a difference and its lists
// for the time of one step. The service binds it to memory of its budget;
// a host test to the heap. take gives a block of at least bytes bytes
// that starts at a multiple of 8, or nil when the budget pays no more;
// give takes back a block that take gave, whole.
Memory_Port :: struct {
	user: rawptr,
	take: proc "contextless" (user: rawptr, bytes: int) -> []u8,
	give: proc "contextless" (user: rawptr, memory: []u8),
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
	memory:               Memory_Port,
	// The bytes of a current object. A generation object has the size of
	// its plan, in a block of the memory.
	current_bytes:        [pr.PLAN_CURRENT_WIRE_SIZE]u8,
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
// a list of items that commas separate. Both lie in memory, a block of the
// core of the size of the difference, which the next lists use again.
Plan_Display_Lists :: struct {
	added:          []u8,
	added_length:   int,
	added_count:    int,
	removed:        []u8,
	removed_length: int,
	removed_count:  int,
	memory:         []u8,
}

// The bytes of one item of a list, with the comma and the space before it.
@(private = "file")
DISPLAY_LIST_ITEM_MOST :: pr.PLAN_DISPLAY_ITEM_BYTES + 2

// state_init resets state, binds the trusted Display role holder slot used
// to verify Show_Plan_Difference consent answers, binds the private store
// that keeps the generations, and the memory of the plans.
state_init :: proc "contextless" (state: ^Plans_State, trusted_display_slot: u32, store: pr.Private_Store_Port, memory: Memory_Port) {
	state^ = {}
	state.initialized = true
	state.trusted_display_slot = trusted_display_slot
	state.store = store
	state.memory = memory
}

@(private = "file")
memory_take :: proc "contextless" (state: ^Plans_State, bytes: int) -> []u8 {
	if bytes <= 0 || state.memory.take == nil {
		return nil
	}
	memory := state.memory.take(state.memory.user, bytes)
	if len(memory) < bytes || uintptr(raw_data(memory)) % 8 != 0 {
		if memory != nil && state.memory.give != nil {
			state.memory.give(state.memory.user, memory)
		}
		return nil
	}
	return memory
}

@(private = "file")
memory_give :: proc "contextless" (state: ^Plans_State, memory: []u8) {
	if memory != nil && state.memory.give != nil {
		state.memory.give(state.memory.user, memory)
	}
}

// plan_take gives an empty plan of principal with room for count entries,
// in a block of the memory, or ok false.
@(private = "file")
plan_take :: proc "contextless" (state: ^Plans_State, principal: u64, count: u32) -> (plan: pr.Plan_Spec, memory: []u8, ok: bool) {
	bytes, bytes_ok := pr.plan_bytes_for(int(count))
	if !bytes_ok || count == 0 {
		return {}, nil, false
	}
	memory = memory_take(state, bytes)
	if memory == nil {
		return {}, nil, false
	}
	return pr.plan_of_memory(principal, memory), memory, true
}

// plan_keep copies plan into a block of the memory: the copy that the core
// keeps, which no caller can change.
@(private = "file")
plan_keep :: proc "contextless" (state: ^Plans_State, plan: ^pr.Plan_Spec) -> (kept: pr.Plan_Spec, memory: []u8, ok: bool) {
	kept, memory = plan_take(state, plan.principal, plan.entry_count) or_return
	if !pr.plan_copy(&kept, plan) {
		memory_give(state, memory)
		return {}, nil, false
	}
	return kept, memory, true
}

// difference_room makes room in difference for the items of a difference
// of current and proposed: its own changes when they hold them, else a
// block of the memory, which replaces the block that it held.
@(private = "file")
difference_room :: proc "contextless" (state: ^Plans_State, difference: ^pr.Plan_Difference, current, proposed: ^pr.Plan_Spec) -> bool {
	// A count past the memory of its plan takes no memory: plan_diff_compute
	// refuses that plan.
	if (current != nil && int(current.entry_count) > len(current.entries)) || (proposed != nil && int(proposed.entry_count) > len(proposed.entries)) {
		return true
	}
	most := pr.plan_difference_changes_most(current, proposed)
	if len(difference.changes) >= most {
		return true
	}
	memory := memory_take(state, most * size_of(pr.Plan_Diff_Item))
	if memory == nil {
		return false
	}
	memory_give(state, difference.changes_memory)
	difference.changes_memory = memory
	difference.changes = ([^]pr.Plan_Diff_Item)(raw_data(memory))[:most]
	return true
}

// difference_release gives back the block of the items of a difference
// that the core took, and leaves the difference empty.
difference_release :: proc "contextless" (state: ^Plans_State, difference: ^pr.Plan_Difference) {
	memory_give(state, difference.changes_memory)
	difference^ = {}
}

// lists_release gives back the block of two lists, and leaves them empty.
lists_release :: proc "contextless" (state: ^Plans_State, lists: ^Plan_Display_Lists) {
	memory_give(state, lists.memory)
	lists^ = {}
}

// difference_clear makes a difference empty and keeps its block.
@(private = "file")
difference_clear :: proc "contextless" (difference: ^pr.Plan_Difference) {
	difference^ = {changes = difference.changes, changes_memory = difference.changes_memory}
}

// lists_clear makes two lists empty and keeps their block.
@(private = "file")
lists_clear :: proc "contextless" (lists: ^Plan_Display_Lists) {
	lists^ = {memory = lists.memory}
}

// entry_release gives back the blocks of the plans of a principal and of
// its pending step, and leaves its table empty.
@(private = "file")
entry_release :: proc "contextless" (state: ^Plans_State, entry: ^Principal_Plans_State) {
	for memory in entry.plan_memory {
		memory_give(state, memory)
	}
	memory_give(state, entry.pending.plan_memory)
	entry^ = {}
}

// pending_clear ends the pending step of a principal and gives back the
// block of its plan.
@(private = "file")
pending_clear :: proc "contextless" (state: ^Plans_State, entry: ^Principal_Plans_State) {
	memory_give(state, entry.pending.plan_memory)
	entry.pending = {}
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
	// The script font set travels with the roles: the core takes the set
	// whole or refuses it whole, so a plan never holds in part.
	if named, found := pr.plan_script_fonts(plan); found {
		set.script_fonts = named
	}
	count := plan.entry_count
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
@(private = "file")
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
	bytes, status := pr.private_store_read(&state.store, pr.private_object_name_text(&current_name), state.current_bytes[:])
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
		index := entry.history_count
		record, load_refusal := generation_load(state, principal, generation, &entry.plans[index], &entry.plan_memory[index])
		if load_refusal != .None {
			entry_release(state, entry)
			return nil, load_refusal
		}
		entry.history[index] = record
		entry.history_count += 1
	}
	current_record := entry.history[current.current_generation - 1]
	if current_record.plan_hash != current.current_plan_hash {
		entry_release(state, entry)
		return nil, .Store_Damaged
	}
	entry.current_generation = current.current_generation
	entry.highest_generation = current.highest_generation
	entry.active = true
	return entry, .None
}

// generation_load reads the generation object of principal and generation
// into a block of the memory of the size of its plan: the size first,
// then the bytes, then the plan. A refusal keeps no block.
@(private = "file")
generation_load :: proc "contextless" (state: ^Plans_State, principal, generation: u64, plan: ^pr.Plan_Spec, plan_memory: ^[]u8) -> (record: pr.Applied_Plan_Record, refusal: pr.Plan_Refusal) {
	name := pr.plan_object_name(principal, generation, false)
	size, size_status := pr.private_store_size(&state.store, pr.private_object_name_text(&name))
	switch size_status {
	case .Ok:
	case .Absent, .Too_Large:
		return {}, .Store_Damaged
	case .Failed:
		return {}, .Store_Failed
	}
	if size > u64(max(int)) {
		return {}, .Store_Damaged
	}
	object := memory_take(state, int(size))
	if object == nil {
		return {}, size == 0 ? .Store_Damaged : .No_Memory
	}
	defer memory_give(state, object)
	bytes, status := pr.private_store_read(&state.store, pr.private_object_name_text(&name), object[:size])
	switch status {
	case .Ok:
	case .Absent, .Too_Large:
		return {}, .Store_Damaged
	case .Failed:
		return {}, .Store_Failed
	}
	count, count_ok := pr.plan_generation_entry_count(bytes)
	if !count_ok {
		return {}, .Store_Damaged
	}
	taken, memory, taken_ok := plan_take(state, principal, count)
	if !taken_ok {
		return {}, .No_Memory
	}
	record, refusal = pr.decode_plan_generation(bytes, principal, generation, &taken)
	if refusal != .None {
		memory_give(state, memory)
		return {}, .Store_Damaged
	}
	plan^ = taken
	plan_memory^ = memory
	return record, .None
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
		difference_clear(out_diff)
		state.counters.total_refusals += 1
		return .Empty_Plan
	}
	entry, entry_refusal := principal_entry(state, proposed.principal)
	if entry_refusal != .None {
		difference_clear(out_diff)
		state.counters.total_refusals += 1
		return entry_refusal
	}
	cur_plan, _, _ := entry_current_plan(entry)
	if !difference_room(state, out_diff, cur_plan, proposed) {
		state.counters.total_refusals += 1
		return .No_Memory
	}
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
	// The copy that the history keeps, and the bytes of its object: taken
	// before any write, so a budget that pays no more changes nothing.
	kept, kept_memory, kept_ok := plan_keep(state, plan)
	if !kept_ok {
		return {}, .No_Memory
	}
	kept_by_history := false
	defer if !kept_by_history {
		memory_give(state, kept_memory)
	}
	object := memory_take(state, pr.plan_generation_size(plan.entry_count))
	if object == nil {
		return {}, .No_Memory
	}
	defer memory_give(state, object)
	written, encode_refusal := pr.encode_plan_generation(&record, &kept, object)
	if encode_refusal != .None {
		return {}, encode_refusal
	}
	generation_name := pr.plan_object_name(plan.principal, next_generation, false)
	if pr.private_store_write(&state.store, pr.private_object_name_text(&generation_name), object[:written]) != .Ok {
		return {}, .Store_Failed
	}
	current := pr.Plan_Current_Record {
		principal          = plan.principal,
		current_generation = next_generation,
		highest_generation = next_generation,
		current_plan_hash  = record.plan_hash,
	}
	current_written, current_refusal := pr.encode_plan_current(&current, state.current_bytes[:])
	if current_refusal != .None {
		return {}, current_refusal
	}
	// The roles go to the core before the commit: a set that the core
	// refuses commits nothing.
	if refusal = roles_give(state, plan.principal, &kept, next_generation, .Apply); refusal != .None {
		return {}, refusal
	}
	current_name := pr.plan_object_name(plan.principal, 0, true)
	if pr.private_store_write(&state.store, pr.private_object_name_text(&current_name), state.current_bytes[:current_written]) != .Ok {
		// The core took the roles of a generation that the store did not
		// commit: it gets the roles of the generation in force again.
		roles_compensate(state, plan.principal, entry)
		return {}, .Store_Failed
	}
	slot_index := entry.history_count
	entry.plans[slot_index] = kept
	entry.plan_memory[slot_index] = kept_memory
	kept_by_history = true
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
		difference_clear(out_diff)
		state.counters.total_refusals += 1
		return {}, .Empty_Plan
	}
	entry, entry_refusal := principal_entry(state, proposed.principal)
	if entry_refusal != .None {
		difference_clear(out_diff)
		state.counters.total_refusals += 1
		return {}, entry_refusal
	}
	cur_plan, _, _ := entry_current_plan(entry)
	if !difference_room(state, out_diff, cur_plan, proposed) {
		state.counters.total_refusals += 1
		return {}, .No_Memory
	}
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
// one that only narrows, is on the side of the removals. The lists have
// any count of items; an item past PLAN_DISPLAY_ITEM_BYTES, which the
// dialog cannot show whole, is refused with Display_Refused: the principal
// never accepts a line that it did not see.
display_lists_of_difference :: proc "contextless" (state: ^Plans_State, difference: ^pr.Plan_Difference, lists: ^Plan_Display_Lists) -> pr.Plan_Refusal {
	// Each side has room for each item: an item goes to one side, and the
	// side is not known before its item.
	side_bytes := int(difference.change_count) * DISPLAY_LIST_ITEM_MOST
	memory := lists.memory
	if len(memory) < 2 * side_bytes {
		taken := memory_take(state, 2 * side_bytes)
		if taken == nil && side_bytes > 0 {
			lists_release(state, lists)
			return .No_Memory
		}
		memory_give(state, memory)
		memory = taken
	}
	lists^ = {memory = memory}
	if side_bytes > 0 {
		lists.added = memory[:side_bytes]
		lists.removed = memory[side_bytes:][:side_bytes]
	}
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
		case .Script_Fonts:
		// Its one name, script_fonts, says what it is: a kind before it
		// would say it twice.
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
			if lists.added_count > 0 {
				lists.added_length = text_put(lists.added[:], lists.added_length, ", ")
			}
			lists.added_length = text_put(lists.added[:], lists.added_length, string(text[:length]))
			lists.added_count += 1
		} else {
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
	difference_clear(out_diff)
	lists_clear(lists)
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
	if refusal = pending_dialog_clear(state, entry, display); refusal != .None {
		return 0, refusal
	}
	cur_plan, _, _ := entry_current_plan(entry)
	if !difference_room(state, out_diff, cur_plan, proposed) {
		return 0, .No_Memory
	}
	if refusal = pr.plan_diff_compute(cur_plan, proposed, out_diff); refusal != .None {
		return 0, refusal
	}
	if expected_current_hash != out_diff.current_plan_hash {
		return 0, .Stale_Current_Plan
	}
	if !out_diff.has_changes || out_diff.change_count == 0 {
		return 0, .No_Change
	}
	if entry.history_count >= MAX_HISTORY_PER_PRINCIPAL {
		return 0, .History_Full
	}
	if refusal = display_lists_of_difference(state, out_diff, lists); refusal != .None {
		return 0, refusal
	}
	// The plan that the principal sees is the copy that the core keeps: a
	// caller that changes its plan after the dialog changes nothing here.
	if display == nil || display.ask == nil {
		return 0, .Consent_Required
	}
	kept, kept_memory, kept_ok := plan_keep(state, proposed)
	if !kept_ok {
		return 0, .No_Memory
	}
	serial, shown := display.ask(display.user, plan_name, string(lists.added[:lists.added_length]), string(lists.removed[:lists.removed_length]))
	if !shown || serial == 0 {
		memory_give(state, kept_memory)
		return 0, .Display_Refused
	}
	state.counters.total_diffs += 1
	entry.pending = {
		active             = true,
		step               = .Apply,
		display_serial     = serial,
		expected_plan_hash = out_diff.current_plan_hash,
		proposed_plan_hash = out_diff.proposed_plan_hash,
		plan               = kept,
		plan_memory        = kept_memory,
	}
	return serial, .None
}

// pending_dialog_clear refuses a second dialog while the dialog of an
// earlier apply or rollback of the principal still shows, and drops a
// pending step whose dialog closed or was replaced, uncommitted.
@(private = "file")
pending_dialog_clear :: proc "contextless" (state: ^Plans_State, entry: ^Principal_Plans_State, display: ^Trusted_Display_Port) -> pr.Plan_Refusal {
	if !entry.pending.active {
		return .None
	}
	decision, polled := display_poll(display, entry.pending.display_serial)
	if polled && decision == .Pending {
		return .Apply_Pending
	}
	pending_clear(state, entry)
	return .None
}

// pending_decision reads the decision of the principal on the pending
// step of ticket. finished is false while the dialog shows. A refusal of
// the principal, a dialog that the display no longer knows and a display
// that does not answer drop the pending step; accepted is true only for an
// accepted dialog of the step.
@(private = "file")
pending_decision :: proc "contextless" (state: ^Plans_State, entry: ^Principal_Plans_State, display: ^Trusted_Display_Port, ticket: u64, step: Pending_Step) -> (accepted: bool, finished: bool, refusal: pr.Plan_Refusal) {
	if ticket == 0 || !entry.pending.active || entry.pending.step != step || entry.pending.display_serial != ticket {
		return false, true, .No_Pending_Apply
	}
	decision, polled := display_poll(display, ticket)
	if !polled {
		pending_clear(state, entry)
		return false, true, .Display_Refused
	}
	switch decision {
	case .Pending:
		return false, false, .None
	case .Refused:
		pending_clear(state, entry)
		return false, true, .Refused_By_Principal
	case .Unknown:
		pending_clear(state, entry)
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
	accepted, finished, refusal = pending_decision(state, entry, display, ticket, .Apply)
	if !accepted {
		return {}, finished, refusal
	}
	defer pending_clear(state, entry)
	cur_plan, _, _ := entry_current_plan(entry)
	if !difference_room(state, out_diff, cur_plan, &entry.pending.plan) {
		return {}, true, .No_Memory
	}
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
	difference_clear(out_diff)
	lists_clear(lists)
	entry, entry_refusal := principal_entry(state, principal)
	if entry_refusal != .None {
		return 0, entry_refusal
	}
	if refusal = pending_dialog_clear(state, entry, display); refusal != .None {
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
	if !difference_room(state, out_diff, cur_plan, &entry.plans[selected_index]) {
		return 0, .No_Memory
	}
	if refusal = pr.plan_diff_compute(cur_plan, &entry.plans[selected_index], out_diff); refusal != .None {
		return 0, refusal
	}
	if out_diff.proposed_plan_hash != selected.plan_hash {
		return 0, .Store_Damaged
	}
	if !out_diff.has_changes || out_diff.change_count == 0 {
		return 0, .No_Change
	}
	if refusal = display_lists_of_difference(state, out_diff, lists); refusal != .None {
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
	accepted, finished, refusal = pending_decision(state, entry, display, ticket, .Rollback)
	if !accepted {
		return {}, finished, refusal
	}
	pending := entry.pending
	pending_clear(state, entry)
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
	written, encode_refusal := pr.encode_plan_current(&current, state.current_bytes[:])
	if encode_refusal != .None {
		return {}, encode_refusal
	}
	// The core takes the roles of the selected generation before the
	// commit: a set that it refuses rolls nothing back.
	selected_index := find_generation_index(entry, selected.generation)
	if selected_index < 0 {
		return {}, .Unknown_Generation
	}
	if refusal = roles_give(state, principal, &entry.plans[selected_index], selected.generation, .Rollback); refusal != .None {
		return {}, refusal
	}
	current_name := pr.plan_object_name(principal, 0, true)
	if pr.private_store_write(&state.store, pr.private_object_name_text(&current_name), state.current_bytes[:written]) != .Ok {
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
		entry_release(state, &entry)
	}
}
