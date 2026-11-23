// The projects that a principal loaded, with their pins
// (src/md/features/declarations.md, "Declaration inputs, pins and release
// pointers").
//
// projects.load reads the evaluation of project.lex and the text of
// pins.lex once; projects.update then moves one input and gives the new
// pins.lex, which differs from the old one in the one line of that input,
// so a principal reviews each moved input as one line.
//
// Each loaded project is one object of the private store of the service
// (plans_recipes/private_store.odin): its name, the evaluation and the
// pins.lex text. A load and an update write that object whole before the
// memory changes, so a refusal of the store changes nothing, and a service
// that starts again reads each project back at its first use.
package projects_core

import "modus:contract/blake3"
import pr "modus:contract/plans_recipes"

// The projects that the service keeps loaded at once, across principals.
MAX_LOADED_PROJECTS :: 8

// The bytes of the evaluation of a project.lex that a load takes.
MAX_PROJECT_EVALUATION_BYTES :: 16384

// The most bytes of a project object: its head, the evaluation and pins.lex.
MAX_PROJECT_OBJECT_BYTES :: 20 + pr.MAX_ENTRY_NAME_BYTES + MAX_PROJECT_EVALUATION_BYTES + pr.MAX_PINS_LEX_BYTES

// One loaded project of one principal, with the evaluation that a later
// update writes again beside the new pins.
Loaded_Project :: struct {
	active:            bool,
	principal:         u64,
	declaration:       pr.Project_Declaration,
	pin_count:         int,
	pins:              [pr.MAX_PROJECT_PINS]pr.Pin_Entry,
	evaluation_length: int,
	evaluation:        [MAX_PROJECT_EVALUATION_BYTES]u8,
}

// The loaded projects, and the private store that keeps them.
Loaded_Projects :: struct {
	projects:     [MAX_LOADED_PROJECTS]Loaded_Project,
	loads:        u64,
	updates:      u64,
	store:        pr.Private_Store_Port,
	object_bytes: [MAX_PROJECT_OBJECT_BYTES]u8,
	pins_bytes:   [pr.MAX_PINS_LEX_BYTES]u8,
}

// loaded_projects_init empties table and binds the private store.
loaded_projects_init :: proc "contextless" (table: ^Loaded_Projects, store: pr.Private_Store_Port) {
	table^ = {}
	table.store = store
}

// project_persist writes the project object of name: its evaluation and its
// pins.lex text, in one write.
@(private = "file")
project_persist :: proc "contextless" (table: ^Loaded_Projects, principal: u64, name: []u8, evaluation: []u8, pins_lex: []u8) -> pr.Project_Refusal {
	written, ok := pr.encode_project_object(name, evaluation, pins_lex, table.object_bytes[:])
	if !ok {
		return .Buffer_Too_Small
	}
	object_name := pr.project_object_name(principal, name)
	if pr.private_store_write(&table.store, pr.private_object_name_text(&object_name), table.object_bytes[:written]) != .Ok {
		return .Store_Failed
	}
	return .None
}

// project_of gives the loaded project name of principal: from the memory,
// else from the private store, which it checks whole as a load does. A
// project that neither holds is Unknown_Project.
project_of :: proc "contextless" (table: ^Loaded_Projects, state: ^Projects_State, principal: u64, name: []u8) -> (project: ^Loaded_Project, refusal: pr.Project_Refusal) {
	if project = find_loaded(table, principal, name); project != nil {
		return project, .None
	}
	if len(name) == 0 || len(name) > pr.MAX_ENTRY_NAME_BYTES {
		return nil, .Unknown_Project
	}
	object_name := pr.project_object_name(principal, name)
	bytes, status := pr.private_store_read(&table.store, pr.private_object_name_text(&object_name), table.object_bytes[:])
	switch status {
	case .Ok:
	case .Absent:
		return nil, .Unknown_Project
	case .Too_Large:
		return nil, .Store_Damaged
	case .Failed:
		return nil, .Store_Failed
	}
	evaluation, pins_lex, decoded := pr.decode_project_object(bytes, name)
	if !decoded || len(evaluation) > MAX_PROJECT_EVALUATION_BYTES {
		return nil, .Store_Damaged
	}
	if _, load_refusal := project_take(table, state, principal, name, evaluation, pins_lex, false); load_refusal != .None {
		if load_refusal == .Project_Limit_Reached || load_refusal == .Too_Many_Modules || load_refusal == .Too_Many_Stores {
			return nil, load_refusal
		}
		return nil, .Store_Damaged
	}
	return find_loaded(table, principal, name), .None
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
	return project_take(table, state, principal, name, evaluation, pins_lex, true)
}

// project_take checks a project whole and takes it into the memory. With
// persist, it writes the project object first; a project read back from the
// store is not written again.
@(private = "file")
project_take :: proc "contextless" (
	table: ^Loaded_Projects,
	state: ^Projects_State,
	principal: u64,
	name: []u8,
	evaluation: []u8,
	pins_lex: []u8,
	persist: bool,
) -> (pin_count: int, refusal: pr.Project_Refusal) {
	if len(evaluation) > MAX_PROJECT_EVALUATION_BYTES {
		state.counters.total_refusals += 1
		return 0, .Bad_Evaluation
	}
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
	if refusal = register_project_check(state, &declaration); refusal != .None {
		state.counters.total_refusals += 1
		return 0, refusal
	}
	if persist {
		if refusal = project_persist(table, principal, name, evaluation, pins_lex); refusal != .None {
			state.counters.total_refusals += 1
			return 0, refusal
		}
	}
	if refusal = register_project(state, &declaration); refusal != .None {
		return 0, refusal
	}
	slot^ = {active = true, principal = principal, declaration = declaration, pin_count = pin_count, pins = pins, evaluation_length = len(evaluation)}
	copy(slot.evaluation[:], evaluation)
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
	project, project_refusal := project_of(table, state, principal, name)
	if project_refusal != .None {
		state.counters.total_refusals += 1
		return {}, project_refusal
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
	// The new pins.lex goes to the store first, in the one object of the
	// project: a refusal of the store leaves the pins as they were.
	if outcome.changed_lines > 0 {
		if refusal = project_persist(table, principal, name, project.evaluation[:project.evaluation_length], new_text[:new_length]); refusal != .None {
			state.counters.total_refusals += 1
			return {}, refusal
		}
	}
	project.pins = moved
	table.updates += 1
	state.counters.total_updates += 1
	return outcome, .None
}

// inputs_recipe gives the recipe of the inputs tree of the project name of
// principal: one input for each pin, a Tree by its tree hash under the name
// of the pin. The recipes service builds such a recipe itself, so a build of
// the inputs of a project needs no sandbox (src/md/features/recipes.md,
// "The inputs tree builder"). A project with no pin has no input to build.
// The recipe goes into spec, which the caller holds: a recipe of the
// largest bounds is too large for a value on a stack. On a refusal spec is
// zero.
inputs_recipe :: proc "contextless" (table: ^Loaded_Projects, state: ^Projects_State, principal: u64, name: []u8, spec: ^pr.Recipe_Spec) -> (refusal: pr.Project_Refusal) {
	spec^ = {}
	project, project_refusal := project_of(table, state, principal, name)
	if project_refusal != .None {
		state.counters.total_refusals += 1
		spec^ = {}
		return project_refusal
	}
	if project.pin_count == 0 {
		state.counters.total_refusals += 1
		spec^ = {}
		return .Pin_Not_Found
	}
	spec.builder_hash = pr.inputs_tree_builder_hash()
	spec.output_kind = .Tree
	for index in 0 ..< project.pin_count {
		pin := &project.pins[index]
		input, input_refusal := pr.recipe_input_make(string(pin.name_bytes[:pin.name_length]), .Tree, pin.tree_hash)
		if input_refusal != .None {
			state.counters.total_refusals += 1
			spec^ = {}
		return .Invalid_Pin_Name
		}
		spec.inputs[index] = input
	}
	spec.input_count = u32(project.pin_count)
	if recipe_refusal, _ := pr.recipe_validate(spec); recipe_refusal != .None {
		state.counters.total_refusals += 1
		spec^ = {}
		return .Invalid_Pin_Name
	}
	return .None
}
