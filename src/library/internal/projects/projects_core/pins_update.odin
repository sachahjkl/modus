// Deterministic single-line pins.lex updates and scoped projects.enter
// validation (src/md/features/declarations.md, "Where the pins live" and
// "The console of a project").
//
// `pins_lex_update_entry` rewrites exactly one named input pin in canonical
// sorted Lex form so a review sees one changed line per moved input while all
// untouched pin lines stay byte-for-byte identical.
//
// `Project_Enter_Scope` validates the modules and stores of `projects.enter`
// before constructing a `Project_Console_Spec`, explicitly refusing ambient
// host paths, duplicate modules or stores, unknown store rights, and any store
// grant escalation past what the caller already holds.
//
// This file imports base and contract packages only and allocates no memory.
package projects_core

import "modus:contract/blake3"
import "modus:contract/enum_word"
import pr "modus:contract/plans_recipes"
import "modus:contract/text_encoding"

// Closed set of refusals returned by Project_Enter_Scope validation.
Enter_Scope_Refusal :: enum u8 {
	None                  = 0,
	Bad_Scope             = 1,
	Zero_Project_Hash     = 2,
	Empty_Scope           = 3,
	Too_Many_Modules      = 4,
	Too_Many_Stores       = 5,
	Ambient_Path_Refused  = 6,
	Invalid_Module_Name   = 7,
	Zero_Module_Hash      = 8,
	Duplicate_Module      = 9,
	Invalid_Store_Name    = 10,
	Duplicate_Store       = 11,
	Unknown_Store_Rights  = 12,
	Undeclared_Store      = 13,
	Store_Rights_Exceeded = 14,
}

// Result of rewriting one named input pin in canonical pins.lex format.
Pin_Line_Update :: struct {
	refusal:             pr.Project_Refusal,
	changed:             bool,
	inserted:            bool,
	changed_line_number: u32, // 1-based line number of the rewritten pin line inside pins.lex.
	old_tree_hash:       blake3.Hash,
	new_tree_hash:       blake3.Hash,
	written:             int,
}

// Scoped console plan validated prior to projects.enter(project).
Project_Enter_Scope :: struct {
	project_tree_hash: blake3.Hash,
	principal:         u64,
	parent_console_id: u64,
	module_count:      u32,
	modules:           [pr.MAX_CONSOLE_MODULES]pr.Project_Console_Module,
	store_count:       u32,
	stores:            [pr.MAX_CONSOLE_STORES]pr.Project_Console_Store,
}

// enter_scope_refusal_of_word is the single border converting a raw word into
// an Enter_Scope_Refusal member. Unknown values are refused.
enter_scope_refusal_of_word :: proc "contextless" (word: u64) -> (refusal: Enter_Scope_Refusal, ok: bool) {
	return enum_word.member_of_word(Enter_Scope_Refusal, word)
}

@(private = "file")
hash_is_all_zero :: proc "contextless" (value: blake3.Hash) -> bool {
	accum: u8 = 0
	for item in value {
		accum |= item
	}
	return accum == 0
}

@(private = "file")
compare_utf8_bytes :: proc "contextless" (left, right: []u8) -> int {
	limit := min(len(left), len(right))
	for index in 0 ..< limit {
		if left[index] < right[index] {
			return -1
		}
		if left[index] > right[index] {
			return 1
		}
	}
	if len(left) < len(right) {
		return -1
	}
	if len(left) > len(right) {
		return 1
	}
	return 0
}

// has_ambient_path_syntax reports whether raw bytes contain path traversal,
// absolute host path prefixes, home-directory expansion, drive letters, or
// path separators forbidden in modus store and module names.
@(private = "file")
has_ambient_path_syntax :: proc "contextless" (raw: []u8) -> bool {
	if len(raw) == 0 {
		return false
	}
	if raw[0] == '/' || raw[0] == '\\' || raw[0] == '~' || raw[0] == '.' {
		return true
	}
	for index in 0 ..< len(raw) {
		ch := raw[index]
		if ch == '/' || ch == '\\' || ch == ':' || ch == 0 {
			return true
		}
		if ch == '.' && index + 1 < len(raw) && raw[index + 1] == '.' {
			return true
		}
	}
	return false
}

// store_name_is_clean validates a modus store name (non-empty UTF-8 without
// control characters or path separators, zero-padded past length).
@(private = "file")
store_name_is_clean :: proc "contextless" (name_bytes: []u8, length: u8) -> (clean: bool, ambient: bool) {
	if int(length) == 0 || int(length) > len(name_bytes) || int(length) > pr.MAX_ENTRY_NAME_BYTES {
		return false, false
	}
	for pad in name_bytes[length:] {
		if pad != 0 {
			return false, false
		}
	}
	slice := name_bytes[:length]
	if has_ambient_path_syntax(slice) {
		return false, true
	}
	if !text_encoding.text_valid(slice) {
		return false, false
	}
	return true, false
}

@(private = "file")
rights_cover_request :: proc "contextless" (held, requested: pr.Plan_Store_Rights) -> bool {
	switch held {
	case .None:
		return false
	case .Read_Only:
		return requested == .Read_Only
	case .Read_Write:
		return requested == .Read_Only || requested == .Read_Write
	}
	return false
}

// pins_lex_update_entry parses current_pins_lex, updates (or inserts when
// allow_insert is true) one named input pin, and writes canonical sorted
// pins.lex bytes into output so a review shows at most one changed line.
// Any refusal leaves output completely untouched.
pins_lex_update_entry :: proc "contextless" (
	current_pins_lex: []u8,
	input_name: string,
	new_source_module_hash: blake3.Hash,
	new_tree_hash: blake3.Hash,
	new_upstream_ref: string,
	allow_insert: bool,
	output: []u8,
) -> (result: Pin_Line_Update) {
	updated_pin, pin_ref := pr.pin_entry_make(input_name, new_source_module_hash, new_tree_hash, new_upstream_ref)
	if pin_ref != .None {
		result.refusal = pin_ref
		return result
	}

	pins: [pr.MAX_PROJECT_PINS]pr.Pin_Entry
	pin_count := 0
	if len(current_pins_lex) > 0 {
		parsed_count, parse_ref := pr.pins_lex_parse(current_pins_lex, pins[:])
		if parse_ref != .None {
			result.refusal = parse_ref
			return result
		}
		pin_count = parsed_count
	}

	target_name := updated_pin.name_bytes[:updated_pin.name_length]
	found_index := -1
	for index in 0 ..< pin_count {
		existing := &pins[index]
		if bytes_equal(existing.name_bytes[:existing.name_length], target_name) {
			found_index = index
			break
		}
	}

	if found_index < 0 {
		if !allow_insert {
			result.refusal = .Pin_Not_Found
			return result
		}
		if pin_count >= pr.MAX_PROJECT_PINS {
			result.refusal = .Too_Many_Pins
			return result
		}
		pins[pin_count] = updated_pin
		pin_count += 1
		result.inserted = true
		result.changed = true
		result.new_tree_hash = updated_pin.tree_hash
	} else {
		old_pin := pins[found_index]
		old_ref := old_pin.upstream_ref_bytes[:old_pin.upstream_ref_length]
		new_ref := updated_pin.upstream_ref_bytes[:updated_pin.upstream_ref_length]
		moved := old_pin.tree_hash != updated_pin.tree_hash ||
		         old_pin.source_module_hash != updated_pin.source_module_hash ||
		         !bytes_equal(old_ref, new_ref)
		pins[found_index] = updated_pin
		result.changed = moved
		result.old_tree_hash = old_pin.tree_hash
		result.new_tree_hash = updated_pin.tree_hash
	}

	written, format_ref := pr.pins_lex_format(pins[:pin_count], output)
	if format_ref != .None {
		result = Pin_Line_Update{refusal = format_ref}
		return result
	}

	// Determine the exact 1-based line number of target_name inside the
	// canonical "{\n  <sorted pin>\n}\n" layout (line 1 is "{", pins start on line 2).
	rank := u32(0)
	for index in 0 ..< pin_count {
		candidate := &pins[index]
		if compare_utf8_bytes(candidate.name_bytes[:candidate.name_length], target_name) < 0 {
			rank += 1
		}
	}
	result.changed_line_number = 2 + rank
	result.written = written
	result.refusal = .None
	return result
}

// project_enter_scope_validate checks every module and store of scope before
// projects.enter creates a child console. Strictly refuses ambient host paths,
// duplicate modules or stores, unknown store rights words, and any store or
// right not already held by caller_stores.
project_enter_scope_validate :: proc "contextless" (
	scope: ^Project_Enter_Scope,
	caller_stores: []pr.Project_Console_Store,
) -> (refusal: Enter_Scope_Refusal, bad_index: u32) {
	if scope == nil {
		return .Bad_Scope, 0
	}
	if hash_is_all_zero(scope.project_tree_hash) {
		return .Zero_Project_Hash, 0
	}
	if scope.module_count > pr.MAX_CONSOLE_MODULES {
		return .Too_Many_Modules, 0
	}
	if scope.store_count > pr.MAX_CONSOLE_STORES {
		return .Too_Many_Stores, 0
	}
	if scope.module_count == 0 && scope.store_count == 0 {
		return .Empty_Scope, 0
	}

	for index in u32(0) ..< scope.module_count {
		mod := &scope.modules[index]
		if int(mod.name_length) == 0 || int(mod.name_length) > pr.MAX_ENTRY_NAME_BYTES {
			return .Invalid_Module_Name, index
		}
		for pad in mod.name_bytes[mod.name_length:] {
			if pad != 0 {
				return .Invalid_Module_Name, index
			}
		}
		mod_name := mod.name_bytes[:mod.name_length]
		if has_ambient_path_syntax(mod_name) {
			return .Ambient_Path_Refused, index
		}
		if !pr.lex_field_name_valid(mod_name) {
			return .Invalid_Module_Name, index
		}
		if hash_is_all_zero(mod.module_hash) {
			return .Zero_Module_Hash, index
		}
		for earlier in u32(0) ..< index {
			prev := &scope.modules[earlier]
			if bytes_equal(prev.name_bytes[:prev.name_length], mod_name) {
				return .Duplicate_Module, index
			}
		}
	}

	for index in u32(0) ..< scope.store_count {
		req_store := &scope.stores[index]
		clean, ambient := store_name_is_clean(req_store.name_bytes[:], req_store.name_length)
		if ambient {
			return .Ambient_Path_Refused, index
		}
		if !clean {
			return .Invalid_Store_Name, index
		}
		req_rights, rights_ok := pr.plan_store_rights_of_word(req_store.rights_word)
		if !rights_ok {
			return .Unknown_Store_Rights, index
		}
		req_name := req_store.name_bytes[:req_store.name_length]
		for earlier in u32(0) ..< index {
			prev := &scope.stores[earlier]
			if bytes_equal(prev.name_bytes[:prev.name_length], req_name) {
				return .Duplicate_Store, index
			}
		}

		matched_store := false
		rights_covered := false
		for &held in caller_stores {
			if int(held.name_length) > pr.MAX_ENTRY_NAME_BYTES {
				continue
			}
			if !bytes_equal(held.name_bytes[:held.name_length], req_name) {
				continue
			}
			matched_store = true
			held_rights, held_ok := pr.plan_store_rights_of_word(held.rights_word)
			if held_ok && rights_cover_request(held_rights, req_rights) {
				rights_covered = true
			}
			break
		}
		if !matched_store {
			return .Undeclared_Store, index
		}
		if !rights_covered {
			return .Store_Rights_Exceeded, index
		}
	}

	return .None, 0
}

// project_enter_scope_to_console_spec validates scope against caller_stores
// and returns the canonical Project_Console_Spec ready for enter_project.
// Any refusal returns a zero spec.
project_enter_scope_to_console_spec :: proc "contextless" (
	scope: ^Project_Enter_Scope,
	caller_stores: []pr.Project_Console_Store,
) -> (spec: pr.Project_Console_Spec, refusal: Enter_Scope_Refusal) {
	refusal, _ = project_enter_scope_validate(scope, caller_stores)
	if refusal != .None {
		return {}, refusal
	}
	spec = {
		project_tree_hash = scope.project_tree_hash,
		principal         = scope.principal,
		parent_console_id = scope.parent_console_id,
		module_count      = scope.module_count,
		modules           = scope.modules,
		store_count       = scope.store_count,
		stores            = scope.stores,
	}
	if border_ref, _ := pr.project_console_spec_validate(&spec, caller_stores); border_ref != .None {
		return {}, .Bad_Scope
	}
	return spec, .None
}
