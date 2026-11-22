#+build !freestanding
package projects_core

import "core:testing"
import "modus:contract/blake3"
import "modus:contract/declaration_eval"
import pr "modus:contract/plans_recipes"

@(private = "file")
loaded_hash :: proc(tag: u8) -> blake3.Hash {
	data := [3]u8{'l', 'd', tag}
	return blake3.hash(data[:])
}

@(private = "file")
project_evaluation_bytes :: proc(buffer: []u8) -> int {
	writer := declaration_eval.output_writer_start(buffer, {status = .Ok})
	declaration_eval.output_write_u8(&writer, u8(declaration_eval.Value_Tag.Project))
	declaration_eval.output_write_u8(&writer, u8(declaration_eval.Value_Tag.Record))
	declaration_eval.output_write_u32(&writer, 1)
	declaration_eval.output_write_string(&writer, "source")
	declaration_eval.output_write_hash(&writer, loaded_hash(7))
	return writer.written
}

@(private = "file")
pins_text :: proc(buffer: []u8) -> int {
	pins: [2]pr.Pin_Entry
	pins[0], _ = pr.pin_entry_make("kernel", loaded_hash(1), loaded_hash(2))
	pins[1], _ = pr.pin_entry_make("odin", loaded_hash(3), loaded_hash(4))
	written, _ := pr.pins_lex_format(pins[:], buffer)
	return written
}

@(test)
an_update_moves_one_input_as_one_line :: proc(t: ^testing.T) {
	state := new(Projects_State)
	defer free(state)
	table := new(Loaded_Projects)
	defer free(table)
	state_init(state)
	evaluation: [512]u8
	evaluation_length := project_evaluation_bytes(evaluation[:])
	pins: [pr.MAX_PINS_LEX_BYTES]u8
	pins_length := pins_text(pins[:])
	kernel := transmute([]u8)string("kernel")
	count, refusal := load_project(table, state, 1, kernel, evaluation[:evaluation_length], pins[:pins_length])
	testing.expect_value(t, refusal, pr.Project_Refusal.None)
	testing.expect_value(t, count, 2)
	_, registered := lookup_project(state, "kernel")
	testing.expect(t, registered, "a loaded project is registered for enter")

	old_text, new_text: [pr.MAX_PINS_LEX_BYTES]u8
	outcome: Pin_Update_Outcome
	outcome, refusal = update_pin(table, state, 1, kernel, transmute([]u8)string("odin"), loaded_hash(9), old_text[:], new_text[:])
	testing.expect_value(t, refusal, pr.Project_Refusal.None)
	testing.expect_value(t, outcome.changed_lines, 1)
	testing.expect_value(t, outcome.line_number, 3)
	testing.expect(t, outcome.old_tree_hash == loaded_hash(4), "the old tree of the input")
	testing.expect(t, outcome.new_tree_hash == loaded_hash(9), "the new tree of the input")
	project := find_loaded(table, 1, kernel)
	testing.expect(t, project.pins[1].tree_hash == loaded_hash(9), "the pin moved")
	testing.expect(t, project.pins[1].source_module_hash == loaded_hash(3), "the source module of the pin stays")

	outcome, refusal = update_pin(table, state, 1, kernel, transmute([]u8)string("odin"), loaded_hash(9), old_text[:], new_text[:])
	testing.expect_value(t, refusal, pr.Project_Refusal.None)
	testing.expect_value(t, outcome.changed_lines, 0)
}

@(test)
an_update_refuses_and_leaves_the_pins :: proc(t: ^testing.T) {
	state := new(Projects_State)
	defer free(state)
	table := new(Loaded_Projects)
	defer free(table)
	state_init(state)
	evaluation: [512]u8
	evaluation_length := project_evaluation_bytes(evaluation[:])
	pins: [pr.MAX_PINS_LEX_BYTES]u8
	pins_length := pins_text(pins[:])
	kernel := transmute([]u8)string("kernel")
	load_project(table, state, 1, kernel, evaluation[:evaluation_length], pins[:pins_length])
	before := find_loaded(table, 1, kernel).pins
	old_text, new_text: [pr.MAX_PINS_LEX_BYTES]u8

	cases := [?]struct {
		principal: u64,
		project:   string,
		input:     string,
		hash:      blake3.Hash,
		refusal:   pr.Project_Refusal,
	}{
		{2, "kernel", "odin", loaded_hash(9), .Unknown_Project},
		{1, "other", "odin", loaded_hash(9), .Unknown_Project},
		{1, "kernel", "nasm", loaded_hash(9), .Pin_Not_Found},
		{1, "kernel", "", loaded_hash(9), .Invalid_Pin_Name},
		{1, "kernel", "o-d", loaded_hash(9), .Invalid_Pin_Name},
		{1, "kernel", "odin", {}, .Zero_Hash},
	}
	for item in cases {
		_, refusal := update_pin(table, state, item.principal, transmute([]u8)item.project, transmute([]u8)item.input, item.hash, old_text[:], new_text[:])
		testing.expectf(t, refusal == item.refusal, "%v: %v, expected %v", item, refusal, item.refusal)
	}
	_, refusal := update_pin(table, state, 1, kernel, transmute([]u8)string("odin"), loaded_hash(9), old_text[:10], new_text[:])
	testing.expect_value(t, refusal, pr.Project_Refusal.Buffer_Too_Small)
	testing.expect(t, find_loaded(table, 1, kernel).pins == before, "a refused update moves no pin")
}

@(test)
a_refused_load_changes_no_project :: proc(t: ^testing.T) {
	state := new(Projects_State)
	defer free(state)
	table := new(Loaded_Projects)
	defer free(table)
	state_init(state)
	evaluation: [512]u8
	evaluation_length := project_evaluation_bytes(evaluation[:])
	kernel := transmute([]u8)string("kernel")
	bad_pins := "{ kernel = nonsense }"
	_, refusal := load_project(table, state, 1, kernel, evaluation[:evaluation_length], transmute([]u8)bad_pins)
	testing.expect(t, refusal != .None, "a damaged pins.lex is refused")
	testing.expect(t, find_loaded(table, 1, kernel) == nil, "a refused load keeps no project")
	_, refusal = load_project(table, state, 1, kernel, evaluation[:10], nil)
	testing.expect_value(t, refusal, pr.Project_Refusal.Bad_Evaluation)

	name: [2]u8 = {'p', 'a'}
	for index in 0 ..< MAX_LOADED_PROJECTS {
		name[1] = 'a' + u8(index)
		_, refusal = load_project(table, state, 1, name[:], evaluation[:evaluation_length], nil)
		testing.expect_value(t, refusal, pr.Project_Refusal.None)
	}
	_, refusal = load_project(table, state, 1, kernel, evaluation[:evaluation_length], nil)
	testing.expect_value(t, refusal, pr.Project_Refusal.Project_Limit_Reached)
	name[1] = 'a'
	_, refusal = load_project(table, state, 1, name[:], evaluation[:evaluation_length], nil)
	testing.expect_value(t, refusal, pr.Project_Refusal.None)
}
