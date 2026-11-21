// Pure state machine for the delegated projects service
// (src/md/features/declarations.md, "The console of a project").
//
// Provides zero-allocation project input inspection, deterministic pins.lex
// updates through the unified source resolver contract, and ephemeral child
// console contexts for projects.enter and exit with zero installed state.
package projects_core

import "modus:contract/blake3"
import pr "modus:contract/plans_recipes"

// Maximum simultaneously open project child consoles tracked by the service.
MAX_ACTIVE_CONSOLES :: 16

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

// Ephemeral child console context created by projects.enter(project) and
// destroyed completely on exit(). Nothing is installed globally.
Child_Console_Context :: struct {
	active:            bool,
	console_id:        u64,
	principal:         u64,
	project_tree_hash: blake3.Hash,
	module_count:      u32,
	modules:           [pr.MAX_CONSOLE_MODULES]pr.Project_Console_Module,
	store_count:       u32,
	stores:            [pr.MAX_CONSOLE_STORES]pr.Project_Console_Store,
}

// Aggregate counters for status inspection.
Projects_Counters :: struct {
	total_inputs_queries: u64,
	total_updates:        u64,
	total_enters:         u64,
	total_exits:          u64,
	active_consoles:      u64,
	total_refusals:       u64,
}

// Complete fixed-capacity state of the projects service engine.
Projects_State :: struct {
	initialized:     bool,
	next_console_id: u64,
	consoles:        [MAX_ACTIVE_CONSOLES]Child_Console_Context,
	counters:        Projects_Counters,
}

// state_init resets state and initializes console serial numbering.
state_init :: proc "contextless" (state: ^Projects_State) {
	state^ = {}
	state.initialized = true
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
// projects.inputs(project).
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

// enter_project validates spec against caller_stores and allocates an ephemeral
// Child_Console_Context containing ONLY the declared module hashes and
// attenuated store grants. Nothing is installed globally.
enter_project :: proc "contextless" (
	state: ^Projects_State,
	spec: ^pr.Project_Console_Spec,
	caller_stores: []pr.Project_Console_Store,
) -> (ctx: Child_Console_Context, refusal: pr.Project_Refusal) {
	border_refusal, _ := pr.project_console_spec_validate(spec, caller_stores)
	if border_refusal != .None {
		state.counters.total_refusals += 1
		return {}, border_refusal
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
		principal         = spec.principal,
		project_tree_hash = spec.project_tree_hash,
		module_count      = spec.module_count,
		modules           = spec.modules,
		store_count       = spec.store_count,
		stores            = spec.stores,
	}
	state.consoles[slot_index] = ctx
	state.counters.total_enters += 1
	state.counters.active_consoles += 1
	return ctx, .None
}

// exit_project closes the ephemeral child console console_id owned by
// principal and wipes its slot completely, leaving zero installed state.
exit_project :: proc "contextless" (state: ^Projects_State, console_id: u64, principal: u64) -> pr.Project_Refusal {
	if console_id == 0 {
		state.counters.total_refusals += 1
		return .Unknown_Console
	}
	for &slot in state.consoles {
		if slot.active && slot.console_id == console_id {
			if slot.principal != principal {
				state.counters.total_refusals += 1
				return .Unknown_Console
			}
			slot = {}
			if state.counters.active_consoles > 0 {
				state.counters.active_consoles -= 1
			}
			state.counters.total_exits += 1
			return .None
		}
	}
	state.counters.total_refusals += 1
	return .Unknown_Console
}

// lookup_console returns the active Child_Console_Context for console_id.
lookup_console :: proc "contextless" (state: ^Projects_State, console_id: u64) -> (ctx: Child_Console_Context, found: bool) {
	if console_id == 0 {
		return {}, false
	}
	for &slot in state.consoles {
		if slot.active && slot.console_id == console_id {
			return slot, true
		}
	}
	return {}, false
}
