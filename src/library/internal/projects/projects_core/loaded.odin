// The projects that a principal loaded, with their pins
// (src/md/features/declarations.md, "Declaration inputs, pins and release
// pointers").
//
// projects.load reads the evaluation of project.lex and the text of
// pins.lex once; projects.update then moves one input and gives the new
// pins.lex, which differs from the old one in the one line of that input,
// so a principal reviews each moved input as one line.
package projects_core

import "modus:contract/blake3"
import pr "modus:contract/plans_recipes"

// The projects that the service keeps loaded at once, across principals.
MAX_LOADED_PROJECTS :: 8

// One loaded project of one principal.
Loaded_Project :: struct {
	active:      bool,
	principal:   u64,
	declaration: pr.Project_Declaration,
	pin_count:   int,
	pins:        [pr.MAX_PROJECT_PINS]pr.Pin_Entry,
}

// The loaded projects.
Loaded_Projects :: struct {
	projects: [MAX_LOADED_PROJECTS]Loaded_Project,
	loads:    u64,
	updates:  u64,
}

// The outcome of one update of a pin: the line of pins.lex that changed.
// old_line and new_line are ranges in the two texts that the caller gave.
Pin_Update_Outcome :: struct {
	changed_lines: int,
	line_number:   int,
	old_tree_hash: blake3.Hash,
	new_tree_hash: blake3.Hash,
	new_length:    int,
	old_line:      []u8,
	new_line:      []u8,
}

// find_loaded gives the project name loaded for principal, or nil.
find_loaded :: proc "contextless" (table: ^Loaded_Projects, principal: u64, name: []u8) -> ^Loaded_Project {
	for &slot in table.projects {
		if slot.active && slot.principal == principal && bytes_equal(slot.declaration.name_bytes[:slot.declaration.name_length], name) {
			return &slot
		}
	}
	return nil
}

// load_project reads the evaluation of project.lex and the text of pins.lex
// of the project name, for principal. It registers the project for
// projects.enter. A load of a name that principal already loaded replaces
// it. On a refusal, nothing changes.
load_project :: proc "contextless" (
	table: ^Loaded_Projects,
	state: ^Projects_State,
	principal: u64,
	name: []u8,
	evaluation: []u8,
	pins_lex: []u8,
) -> (pin_count: int, refusal: pr.Project_Refusal) {
	declaration: pr.Project_Declaration
	if refusal = pr.project_declaration_of_evaluation(name, evaluation, &declaration); refusal != .None {
		state.counters.total_refusals += 1
		return 0, refusal
	}
	pins: [pr.MAX_PROJECT_PINS]pr.Pin_Entry
	if len(pins_lex) > 0 {
		pin_count, refusal = pr.pins_lex_parse(pins_lex, pins[:])
		if refusal != .None {
			state.counters.total_refusals += 1
			return 0, refusal
		}
	}
	slot := find_loaded(table, principal, name)
	if slot == nil {
		for &candidate in table.projects {
			if !candidate.active {
				slot = &candidate
				break
			}
		}
	}
	if slot == nil {
		state.counters.total_refusals += 1
		return 0, .Project_Limit_Reached
	}
	if refusal = register_project(state, &declaration); refusal != .None {
		return 0, refusal
	}
	slot^ = {active = true, principal = principal, declaration = declaration, pin_count = pin_count, pins = pins}
	table.loads += 1
	return pin_count, .None
}

// update_pin moves the input input_name of the loaded project name of
// principal to new_tree_hash. It writes the old pins.lex into old_text and
// the new one into new_text, and gives the one line that changed: none when
// the input already had that hash. On a refusal, the pins do not change.
update_pin :: proc "contextless" (
	table: ^Loaded_Projects,
	state: ^Projects_State,
	principal: u64,
	name: []u8,
	input_name: []u8,
	new_tree_hash: blake3.Hash,
	old_text: []u8,
	new_text: []u8,
) -> (outcome: Pin_Update_Outcome, refusal: pr.Project_Refusal) {
	project := find_loaded(table, principal, name)
	if project == nil {
		state.counters.total_refusals += 1
		return {}, .Unknown_Project
	}
	if !pr.lex_field_name_valid(input_name) {
		state.counters.total_refusals += 1
		return {}, .Invalid_Pin_Name
	}
	if new_tree_hash == {} {
		state.counters.total_refusals += 1
		return {}, .Zero_Hash
	}
	found := -1
	for index in 0 ..< project.pin_count {
		pin := &project.pins[index]
		if bytes_equal(pin.name_bytes[:pin.name_length], input_name) {
			found = index
			break
		}
	}
	if found < 0 {
		state.counters.total_refusals += 1
		return {}, .Pin_Not_Found
	}
	old_length, old_refusal := pr.pins_lex_format(project.pins[:project.pin_count], old_text)
	if old_refusal != .None {
		state.counters.total_refusals += 1
		return {}, old_refusal
	}
	moved := project.pins
	outcome.old_tree_hash = moved[found].tree_hash
	moved[found].tree_hash = new_tree_hash
	outcome.new_tree_hash = new_tree_hash
	new_length, new_refusal := pr.pins_lex_format(moved[:project.pin_count], new_text)
	if new_refusal != .None {
		state.counters.total_refusals += 1
		return {}, new_refusal
	}
	outcome.new_length = new_length
	outcome.changed_lines, outcome.line_number, outcome.old_line, outcome.new_line = pr.pins_lex_line_difference(old_text[:old_length], new_text[:new_length])
	project.pins = moved
	table.updates += 1
	state.counters.total_updates += 1
	return outcome, .None
}
