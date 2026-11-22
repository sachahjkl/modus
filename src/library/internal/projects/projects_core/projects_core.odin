// Pure state machine for the delegated projects service
// (src/md/features/declarations.md, "The console of a project").
//
// Provides zero-allocation project input inspection, deterministic pins.lex
// updates through the unified source resolver contract, and ephemeral child
// console contexts for projects.enter and exit with zero installed state.
package projects_core

import "modus:contract/blake3"
import pr "modus:contract/plans_recipes"
import "modus:contract/powerbox"

// Maximum simultaneously open project child consoles tracked by the service.
MAX_ACTIVE_CONSOLES :: 16

// Maximum named project declarations registered for lookup by projects.enter.
MAX_REGISTERED_PROJECTS :: 32

// Callback invoking a source module under the unified resolver-plus-fetch contract.
Source_Resolver_Proc :: #type proc "contextless" (
	request: ^pr.Source_Resolver_Request,
	user_data: rawptr,
) -> (response: pr.Source_Resolver_Response, ok: bool)

// One input change reported by projects.update.
Pin_Update_Change :: struct {
	name_bytes:    [pr.MAX_ENTRY_NAME_BYTES]u8,
	name_length:   u8,
	old_tree_hash: blake3.Hash,
	new_tree_hash: blake3.Hash,
	added:         bool,
	moved:         bool,
}

// Result of projects.update: exact moved-input diff and the complete canonical
// pins.lex file bytes to write (writing ONLY pins.lex and nothing else).
Pin_Update_Result :: struct {
	refusal:         pr.Project_Refusal,
	change_count:    u32,
	moved_count:     u32,
	added_count:     u32,
	unchanged_count: u32,
	changes:         [pr.MAX_PROJECT_PINS]Pin_Update_Change,
	pins_lex_length: int,
	pins_lex_bytes:  [pr.MAX_PINS_LEX_BYTES]u8,
}

// Registered project declaration held in fixed-capacity service memory.
Registered_Project :: struct {
	active:      bool,
	declaration: pr.Project_Declaration,
}

// Ephemeral child console context created by projects.enter(project) and
// destroyed completely on exit(). Nothing is installed globally and the
// principal's applied plan is never modified.
Child_Console_Context :: struct {
	active:                     bool,
	console_id:                 u64,
	parent_console_id:          u64,
	depth:                      u32,
	principal:                  u64,
	project_tree_hash:          blake3.Hash,
	spec_hash:                  blake3.Hash,
	applied_plan_hash_snapshot: blake3.Hash,
	consent_verified:           bool,
	module_count:               u32,
	modules:                    [pr.MAX_CONSOLE_MODULES]pr.Project_Console_Module,
	store_count:                u32,
	stores:                     [pr.MAX_CONSOLE_STORES]pr.Project_Console_Store,
}

// Teardown report returned by exit(): lists every temporary module connection
// and store share revoked and identifies the parent console restored.
Exit_Teardown_Report :: struct {
	exited_console_id:          u64,
	restored_parent_id:         u64,
	restored_depth:             u32,
	principal:                  u64,
	applied_plan_hash_snapshot: blake3.Hash,
	revoked_module_count:       u32,
	revoked_modules:            [pr.MAX_CONSOLE_MODULES]pr.Project_Console_Module,
	revoked_store_count:        u32,
	revoked_stores:             [pr.MAX_CONSOLE_STORES]pr.Project_Console_Store,
}

// Aggregate counters for status inspection.
Projects_Counters :: struct {
	total_inputs_queries:  u64,
	total_updates:         u64,
	total_enters:          u64,
	total_exits:           u64,
	active_consoles:       u64,
	total_refusals:        u64,
	max_depth_reached:     u64,
	total_revoked_modules: u64,
	total_revoked_stores:  u64,
	last_pin_count:        u64, // The pins of the last pins.lex that list_inputs accepted.
}

// Complete fixed-capacity state of the projects service engine.
Projects_State :: struct {
	initialized:          bool,
	trusted_display_slot: u32,
	next_console_id:      u64,
	consoles:             [MAX_ACTIVE_CONSOLES]Child_Console_Context,
	projects:             [MAX_REGISTERED_PROJECTS]Registered_Project,
	counters:             Projects_Counters,
}

// state_init resets state, binds the trusted Display role holder slot used to
// verify consent answers, and initializes console serial numbering.
state_init :: proc "contextless" (state: ^Projects_State, trusted_display_slot: u32 = 0) {
	state^ = {}
	state.initialized = true
	state.trusted_display_slot = trusted_display_slot
	state.next_console_id = 1
}

@(private = "file")
bytes_equal :: proc "contextless" (first, second: []u8) -> bool {
	if len(first) != len(second) {
		return false
	}
	for index in 0 ..< len(first) {
		if first[index] != second[index] {
			return false
		}
	}
	return true
}

// list_inputs parses pins.lex strictly into sorted Pin_Entry rows for
// projects.inputs(project). A refused pins.lex keeps the last pin count, so a
// damaged file never hides the inputs of the last good one.
list_inputs :: proc "contextless" (
	state: ^Projects_State,
	pins_lex_bytes: []u8,
	out_pins: []pr.Pin_Entry,
) -> (count: int, refusal: pr.Project_Refusal) {
	count, refusal = pr.pins_lex_parse(pins_lex_bytes, out_pins)
	if refusal != .None {
		state.counters.total_refusals += 1
		return 0, refusal
	}
	state.counters.total_inputs_queries += 1
	state.counters.last_pin_count = u64(count)
	return count, .None
}

// update_pins resolves each declared input (or only filter_input_name when
// non-empty) through resolver, validates every request and response against
// the unified Source_Resolver contract, and emits ONLY the updated canonical
// pins.lex bytes together with the exact moved-input diff.
//
// On any refusal, no updated pins.lex bytes are returned.
update_pins :: proc "contextless" (
	state: ^Projects_State,
	current_pins_lex: []u8,
	requests: []pr.Source_Resolver_Request,
	resolver: Source_Resolver_Proc,
	user_data: rawptr = nil,
	filter_input_name: string = "",
) -> (result: Pin_Update_Result) {
	pins: [pr.MAX_PROJECT_PINS]pr.Pin_Entry
	pin_count := 0
	if len(current_pins_lex) > 0 {
		parsed_count, parse_refusal := pr.pins_lex_parse(current_pins_lex, pins[:])
		if parse_refusal != .None {
			state.counters.total_refusals += 1
			result.refusal = parse_refusal
			return result
		}
		pin_count = parsed_count
	}

	if resolver == nil {
		state.counters.total_refusals += 1
		result.refusal = .Bad_Resolver_Status
		return result
	}

	filter_bytes := transmute([]u8)filter_input_name
	matched_filter := len(filter_bytes) == 0

	for index in 0 ..< len(requests) {
		req := requests[index]
		if req_refusal := pr.source_resolver_request_validate(&req); req_refusal != .None {
			state.counters.total_refusals += 1
			result.refusal = req_refusal
			return result
		}
		req_name := req.input_name_bytes[:req.input_name_length]
		if len(filter_bytes) > 0 && !bytes_equal(req_name, filter_bytes) {
			continue
		}
		matched_filter = true

		resp, call_ok := resolver(&req, user_data)
		if !call_ok {
			state.counters.total_refusals += 1
			result.refusal = .Bad_Resolver_Status
			return result
		}
		if resp_refusal := pr.source_resolver_response_validate(&req, &resp); resp_refusal != .None {
			state.counters.total_refusals += 1
			result.refusal = resp_refusal
			return result
		}
		status, _ := pr.source_resolver_status_of_word(resp.status_word)
		if status != .Ok {
			state.counters.total_refusals += 1
			result.refusal = .Bad_Resolver_Status
			return result
		}

		updated_pin := pr.Pin_Entry {
			name_bytes          = req.input_name_bytes,
			name_length         = req.input_name_length,
			source_module_hash  = resp.source_module_hash,
			tree_hash           = resp.resolved_tree_hash,
			upstream_ref_bytes  = resp.resolved_ref_bytes,
			upstream_ref_length = resp.resolved_ref_length,
		}
		if pin_ref := pr.pin_entry_validate(&updated_pin); pin_ref != .None {
			state.counters.total_refusals += 1
			result.refusal = pin_ref
			return result
		}

		existing_idx := -1
		for p_idx in 0 ..< pin_count {
			existing := &pins[p_idx]
			if bytes_equal(existing.name_bytes[:existing.name_length], req_name) {
				existing_idx = p_idx
				break
			}
		}

		if existing_idx < 0 {
			if pin_count >= pr.MAX_PROJECT_PINS {
				state.counters.total_refusals += 1
				result.refusal = .Too_Many_Pins
				return result
			}
			pins[pin_count] = updated_pin
			pin_count += 1
			if result.change_count < pr.MAX_PROJECT_PINS {
				result.changes[result.change_count] = {
					name_bytes    = updated_pin.name_bytes,
					name_length   = updated_pin.name_length,
					new_tree_hash = updated_pin.tree_hash,
					added         = true,
					moved         = false,
				}
				result.change_count += 1
			}
			result.added_count += 1
		} else {
			old_pin := pins[existing_idx]
			pins[existing_idx] = updated_pin
			if old_pin.tree_hash != updated_pin.tree_hash || old_pin.source_module_hash != updated_pin.source_module_hash {
				if result.change_count < pr.MAX_PROJECT_PINS {
					result.changes[result.change_count] = {
						name_bytes    = updated_pin.name_bytes,
						name_length   = updated_pin.name_length,
						old_tree_hash = old_pin.tree_hash,
						new_tree_hash = updated_pin.tree_hash,
						added         = false,
						moved         = true,
					}
					result.change_count += 1
				}
				result.moved_count += 1
			} else {
				result.unchanged_count += 1
			}
		}
	}

	if !matched_filter {
		state.counters.total_refusals += 1
		result.refusal = .Pin_Not_Found
		return result
	}

	written, format_refusal := pr.pins_lex_format(pins[:pin_count], result.pins_lex_bytes[:])
	if format_refusal != .None {
		state.counters.total_refusals += 1
		result.refusal = format_refusal
		return result
	}
	result.pins_lex_length = written
	result.refusal = .None
	state.counters.total_updates += 1
	return result
}

// register_project stores a project declaration by name for lookup during
// projects.enter(project). The console field itself is validated lazily when
// entering so declarations with empty or invalid console fields are refused
// at enter time.
register_project :: proc "contextless" (state: ^Projects_State, decl: ^pr.Project_Declaration) -> pr.Project_Refusal {
	if decl == nil || int(decl.name_length) == 0 || int(decl.name_length) > pr.MAX_ENTRY_NAME_BYTES {
		state.counters.total_refusals += 1
		return .Unknown_Project
	}
	if !pr.lex_field_name_valid(decl.name_bytes[:decl.name_length]) {
		state.counters.total_refusals += 1
		return .Unknown_Project
	}
	all_zero := true
	for b in decl.project_tree_hash {
		if b != 0 {
			all_zero = false
			break
		}
	}
	if all_zero {
		state.counters.total_refusals += 1
		return .Zero_Hash
	}
	name_slice := decl.name_bytes[:decl.name_length]
	free_idx := -1
	for &slot, idx in state.projects {
		if slot.active {
			if bytes_equal(slot.declaration.name_bytes[:slot.declaration.name_length], name_slice) {
				slot.declaration = decl^
				return .None
			}
		} else if free_idx < 0 {
			free_idx = idx
		}
	}
	if free_idx < 0 {
		state.counters.total_refusals += 1
		return .Project_Limit_Reached
	}
	state.projects[free_idx] = {active = true, declaration = decl^}
	return .None
}

// lookup_project finds a registered Project_Declaration by exact name.
lookup_project :: proc "contextless" (state: ^Projects_State, name: string) -> (decl: pr.Project_Declaration, found: bool) {
	raw := transmute([]u8)name
	if len(raw) == 0 || len(raw) > pr.MAX_ENTRY_NAME_BYTES {
		return {}, false
	}
	for &slot in state.projects {
		if slot.active && bytes_equal(slot.declaration.name_bytes[:slot.declaration.name_length], raw) {
			return slot.declaration, true
		}
	}
	return {}, false
}

@(private = "file")
find_console_slot :: proc "contextless" (state: ^Projects_State, console_id: u64) -> int {
	if console_id == 0 {
		return -1
	}
	for &slot, idx in state.consoles {
		if slot.active && slot.console_id == console_id {
			return idx
		}
	}
	return -1
}

@(private = "file")
verify_console_consent :: proc "contextless" (
	trusted_display_slot: u32,
	principal: u64,
	spec_hash: blake3.Hash,
	consent_dialog: ^powerbox.Dialog_Record,
	consent_answer: ^powerbox.Grant_Answer,
) -> pr.Project_Refusal {
	if consent_dialog == nil || consent_answer == nil {
		return .Consent_Required
	}
	if consent_dialog.action_word != u64(powerbox.Dialog_Action.Show_Plan_Difference) {
		return .Untrusted_Consent
	}
	if consent_dialog.session_principal != principal {
		return .Untrusted_Consent
	}
	if consent_dialog.item_count != 1 || consent_dialog.items[0].plan_hash != spec_hash {
		return .Untrusted_Consent
	}
	if pb_refusal, _ := powerbox.answer_record_validate(consent_dialog, consent_answer, trusted_display_slot); pb_refusal != .None {
		return .Untrusted_Consent
	}
	if !consent_answer.whole_plan_accepted {
		return .Untrusted_Consent
	}
	return .None
}

// enter_project validates spec strictly against caller_stores (pure
// attenuation, no grant escalation) and allocates an ephemeral
// Child_Console_Context with bounded nesting depth. Nothing is installed
// globally and the principal's applied plan is untouched.
enter_project :: proc "contextless" (
	state: ^Projects_State,
	spec: ^pr.Project_Console_Spec,
	caller_stores: []pr.Project_Console_Store,
) -> (ctx: Child_Console_Context, refusal: pr.Project_Refusal) {
	if spec == nil {
		state.counters.total_refusals += 1
		return {}, .Zero_Hash
	}

	depth := u32(1)
	effective_stores := caller_stores
	if spec.parent_console_id != 0 {
		parent_idx := find_console_slot(state, spec.parent_console_id)
		if parent_idx < 0 || state.consoles[parent_idx].principal != spec.principal {
			state.counters.total_refusals += 1
			return {}, .Unknown_Console
		}
		parent := &state.consoles[parent_idx]
		if parent.depth >= pr.MAX_PROJECT_CONSOLE_DEPTH {
			state.counters.total_refusals += 1
			return {}, .Nesting_Depth_Exceeded
		}
		depth = parent.depth + 1
		effective_stores = parent.stores[:parent.store_count]
	}

	border_refusal, _ := pr.project_console_spec_validate(spec, effective_stores)
	if border_refusal != .None {
		state.counters.total_refusals += 1
		return {}, border_refusal
	}
	spec_hash, hash_ref := pr.project_console_spec_hash(spec)
	if hash_ref != .None {
		state.counters.total_refusals += 1
		return {}, hash_ref
	}

	slot_index := -1
	for &slot, idx in state.consoles {
		if !slot.active {
			slot_index = idx
			break
		}
	}
	if slot_index < 0 {
		state.counters.total_refusals += 1
		return {}, .Console_Limit_Reached
	}

	id := state.next_console_id
	state.next_console_id += 1
	ctx = {
		active            = true,
		console_id        = id,
		parent_console_id = spec.parent_console_id,
		depth             = depth,
		principal         = spec.principal,
		project_tree_hash = spec.project_tree_hash,
		spec_hash         = spec_hash,
		module_count      = spec.module_count,
		modules           = spec.modules,
		store_count       = spec.store_count,
		stores            = spec.stores,
	}
	state.consoles[slot_index] = ctx
	state.counters.total_enters += 1
	state.counters.active_consoles += 1
	if u64(depth) > state.counters.max_depth_reached {
		state.counters.max_depth_reached = u64(depth)
	}
	return ctx, .None
}

// enter_project_session opens a bounded, isolated child project console from
// spec. If spec requests any module connection or store grant outside the
// caller's active session grants (or parent child console grants when nested),
// verified trusted Display consent bound to diff.spec_hash is mandatory.
// On any refusal, zero state changes occur.
enter_project_session :: proc "contextless" (
	state: ^Projects_State,
	spec: ^pr.Project_Console_Spec,
	session_stores: []pr.Project_Console_Store,
	session_modules: []pr.Project_Console_Module,
	consent_dialog: ^powerbox.Dialog_Record = nil,
	consent_answer: ^powerbox.Grant_Answer = nil,
	applied_plan_hash: blake3.Hash = {},
) -> (ctx: Child_Console_Context, diff: pr.Project_Console_Grant_Diff, refusal: pr.Project_Refusal) {
	if spec == nil {
		state.counters.total_refusals += 1
		return {}, {}, .Zero_Hash
	}

	depth := u32(1)
	effective_stores := session_stores
	effective_modules := session_modules
	if spec.parent_console_id != 0 {
		parent_idx := find_console_slot(state, spec.parent_console_id)
		if parent_idx < 0 || state.consoles[parent_idx].principal != spec.principal {
			state.counters.total_refusals += 1
			return {}, {}, .Unknown_Console
		}
		parent := &state.consoles[parent_idx]
		if parent.depth >= pr.MAX_PROJECT_CONSOLE_DEPTH {
			state.counters.total_refusals += 1
			return {}, {}, .Nesting_Depth_Exceeded
		}
		depth = parent.depth + 1
		effective_stores = parent.stores[:parent.store_count]
		effective_modules = parent.modules[:parent.module_count]
	}

	diff, refusal = pr.project_console_grant_diff(spec, effective_stores, effective_modules)
	if refusal != .None {
		state.counters.total_refusals += 1
		return {}, {}, refusal
	}

	if diff.needs_consent {
		consent_ref := verify_console_consent(state.trusted_display_slot, spec.principal, diff.spec_hash, consent_dialog, consent_answer)
		if consent_ref != .None {
			state.counters.total_refusals += 1
			return {}, diff, consent_ref
		}
	}

	slot_index := -1
	for &slot, idx in state.consoles {
		if !slot.active {
			slot_index = idx
			break
		}
	}
	if slot_index < 0 {
		state.counters.total_refusals += 1
		return {}, diff, .Console_Limit_Reached
	}

	id := state.next_console_id
	state.next_console_id += 1
	ctx = {
		active                     = true,
		console_id                 = id,
		parent_console_id          = spec.parent_console_id,
		depth                      = depth,
		principal                  = spec.principal,
		project_tree_hash          = spec.project_tree_hash,
		spec_hash                  = diff.spec_hash,
		applied_plan_hash_snapshot = applied_plan_hash,
		consent_verified           = diff.needs_consent,
		module_count               = spec.module_count,
		modules                    = spec.modules,
		store_count                = spec.store_count,
		stores                     = spec.stores,
	}
	state.consoles[slot_index] = ctx
	state.counters.total_enters += 1
	state.counters.active_consoles += 1
	if u64(depth) > state.counters.max_depth_reached {
		state.counters.max_depth_reached = u64(depth)
	}
	return ctx, diff, .None
}

// enter_named_project resolves project_name from the service's registered
// project declarations, derives its isolated Project_Console_Spec, and enters
// the child console session. Refuses unknown projects with Unknown_Project.
enter_named_project :: proc "contextless" (
	state: ^Projects_State,
	principal: u64,
	project_name: string,
	parent_console_id: u64,
	session_stores: []pr.Project_Console_Store,
	session_modules: []pr.Project_Console_Module,
	consent_dialog: ^powerbox.Dialog_Record = nil,
	consent_answer: ^powerbox.Grant_Answer = nil,
	applied_plan_hash: blake3.Hash = {},
) -> (ctx: Child_Console_Context, diff: pr.Project_Console_Grant_Diff, refusal: pr.Project_Refusal) {
	decl, found := lookup_project(state, project_name)
	if !found {
		state.counters.total_refusals += 1
		return {}, {}, .Unknown_Project
	}
	spec, spec_ref := pr.project_console_spec_from_declaration(&decl, principal, parent_console_id)
	if spec_ref != .None {
		state.counters.total_refusals += 1
		return {}, {}, spec_ref
	}
	return enter_project_session(state, &spec, session_stores, session_modules, consent_dialog, consent_answer, applied_plan_hash)
}

// exit_project_with_report tears down child console console_id owned by
// principal, refuses if any nested child console still references it as a
// parent, revokes all temporary module connections and store shares, wipes its
// slot completely, and returns the teardown report naming the restored parent.
exit_project_with_report :: proc "contextless" (
	state: ^Projects_State,
	console_id: u64,
	principal: u64,
) -> (report: Exit_Teardown_Report, refusal: pr.Project_Refusal) {
	idx := find_console_slot(state, console_id)
	if idx < 0 || state.consoles[idx].principal != principal {
		state.counters.total_refusals += 1
		return {}, .Unknown_Console
	}
	for &other in state.consoles {
		if other.active && other.parent_console_id == console_id {
			state.counters.total_refusals += 1
			return {}, .Child_Console_Active
		}
	}

	slot := &state.consoles[idx]
	report = {
		exited_console_id          = slot.console_id,
		restored_parent_id         = slot.parent_console_id,
		restored_depth             = slot.depth > 0 ? slot.depth - 1 : 0,
		principal                  = slot.principal,
		applied_plan_hash_snapshot = slot.applied_plan_hash_snapshot,
		revoked_module_count       = slot.module_count,
		revoked_modules            = slot.modules,
		revoked_store_count        = slot.store_count,
		revoked_stores             = slot.stores,
	}
	slot^ = {}
	if state.counters.active_consoles > 0 {
		state.counters.active_consoles -= 1
	}
	state.counters.total_exits += 1
	state.counters.total_revoked_modules += u64(report.revoked_module_count)
	state.counters.total_revoked_stores += u64(report.revoked_store_count)
	return report, .None
}

// exit_project closes the ephemeral child console console_id owned by
// principal and wipes its slot completely, leaving zero installed state.
exit_project :: proc "contextless" (state: ^Projects_State, console_id: u64, principal: u64) -> pr.Project_Refusal {
	_, refusal := exit_project_with_report(state, console_id, principal)
	return refusal
}

// exit_current_project implements exit(): pops the innermost active child
// project console for principal, revoking its temporary module connections and
// store shares and restoring the parent console. Refuses with No_Active_Console
// when principal is not inside any project console.
exit_current_project :: proc "contextless" (
	state: ^Projects_State,
	principal: u64,
) -> (report: Exit_Teardown_Report, refusal: pr.Project_Refusal) {
	best_id := u64(0)
	best_depth := u32(0)
	for &slot in state.consoles {
		if !slot.active || slot.principal != principal {
			continue
		}
		if slot.depth > best_depth || (slot.depth == best_depth && slot.console_id > best_id) {
			best_depth = slot.depth
			best_id = slot.console_id
		}
	}
	if best_id == 0 {
		state.counters.total_refusals += 1
		return {}, .No_Active_Console
	}
	return exit_project_with_report(state, best_id, principal)
}

// active_console_for_principal returns the innermost active child console of
// principal, or found = false when principal is at the root console.
active_console_for_principal :: proc "contextless" (state: ^Projects_State, principal: u64) -> (ctx: Child_Console_Context, found: bool) {
	best_idx := -1
	best_depth := u32(0)
	best_id := u64(0)
	for &slot, idx in state.consoles {
		if !slot.active || slot.principal != principal {
			continue
		}
		if slot.depth > best_depth || (slot.depth == best_depth && slot.console_id > best_id) {
			best_depth = slot.depth
			best_id = slot.console_id
			best_idx = idx
		}
	}
	if best_idx < 0 {
		return {}, false
	}
	return state.consoles[best_idx], true
}

// active_console_count_for_principal returns the number of active child
// consoles currently open for principal.
active_console_count_for_principal :: proc "contextless" (state: ^Projects_State, principal: u64) -> u32 {
	count := u32(0)
	for &slot in state.consoles {
		if slot.active && slot.principal == principal {
			count += 1
		}
	}
	return count
}

// lookup_console returns the active Child_Console_Context for console_id.
lookup_console :: proc "contextless" (state: ^Projects_State, console_id: u64) -> (ctx: Child_Console_Context, found: bool) {
	idx := find_console_slot(state, console_id)
	if idx < 0 {
		return {}, false
	}
	return state.consoles[idx], true
}
