#+build !freestanding
package projects_core

import "core:testing"
import "modus:contract/blake3"
import "modus:contract/declaration_eval"
import "modus:contract/object_cache"
import pr "modus:contract/plans_recipes"

// projects_test_tables_init empties table with a memory store that the test
// frees.
projects_test_tables_init :: proc(table: ^Loaded_Projects) -> ^pr.Memory_Private_Store {
	store := new(pr.Memory_Private_Store)
	loaded_projects_init(table, pr.memory_private_store_port(store))
	return store
}

@(private = "file")
store_hash :: proc(tag: u8) -> blake3.Hash {
	data := [3]u8{'p', 's', tag}
	return blake3.hash(data[:])
}

@(private = "file")
store_evaluation :: proc(buffer: []u8) -> int {
	writer := declaration_eval.output_writer_start(buffer, {status = .Ok})
	declaration_eval.output_write_u8(&writer, u8(declaration_eval.Value_Tag.Project))
	declaration_eval.output_write_u8(&writer, u8(declaration_eval.Value_Tag.Record))
	declaration_eval.output_write_u32(&writer, 1)
	declaration_eval.output_write_string(&writer, "source")
	declaration_eval.output_write_hash(&writer, store_hash(7))
	return writer.written
}

@(private = "file")
store_pins :: proc(buffer: []u8) -> int {
	pins: [2]pr.Pin_Entry
	pins[0], _ = pr.pin_entry_make("kernel", store_hash(1), store_hash(2))
	pins[1], _ = pr.pin_entry_make("odin", store_hash(3), store_hash(4))
	written, _ := pr.pins_lex_format(pins[:], buffer)
	return written
}

// Store_Fixture holds a loaded project "kernel" of principal 1 with two pins.
@(private = "file")
Store_Fixture :: struct {
	state:      ^Projects_State,
	table:      ^Loaded_Projects,
	store:      ^pr.Memory_Private_Store,
	evaluation: [512]u8,
	evaluation_length: int,
	pins:       [1024]u8,
	pins_length: int,
}

@(private = "file")
fixture_make :: proc(t: ^testing.T) -> ^Store_Fixture {
	fixture := new(Store_Fixture)
	fixture.state = new(Projects_State)
	fixture.table = new(Loaded_Projects)
	state_init(fixture.state)
	fixture.store = projects_test_tables_init(fixture.table)
	fixture.evaluation_length = store_evaluation(fixture.evaluation[:])
	fixture.pins_length = store_pins(fixture.pins[:])
	count, refusal := load_project(fixture.table, fixture.state, 1, transmute([]u8)string("kernel"), fixture.evaluation[:fixture.evaluation_length], fixture.pins[:fixture.pins_length])
	testing.expect_value(t, refusal, pr.Project_Refusal.None)
	testing.expect_value(t, count, 2)
	return fixture
}

@(private = "file")
fixture_free :: proc(fixture: ^Store_Fixture) {
	free(fixture.store)
	free(fixture.table)
	free(fixture.state)
	free(fixture)
}

// fixture_restart drops the memory of the service and keeps its store, as a
// service that starts again.
@(private = "file")
fixture_restart :: proc(fixture: ^Store_Fixture) {
	fixture.table^ = {}
	fixture.table.store = pr.memory_private_store_port(fixture.store)
	state_init(fixture.state)
}

@(private = "file")
fixture_object :: proc(fixture: ^Store_Fixture) -> ^pr.Memory_Private_Object {
	name := pr.project_object_name(1, transmute([]u8)string("kernel"))
	return pr.memory_private_store_find(fixture.store, pr.private_object_name_text(&name))
}

@(test)
an_update_writes_pins_lex_to_the_store_and_a_restart_reads_it :: proc(t: ^testing.T) {
	fixture := fixture_make(t)
	defer fixture_free(fixture)
	kernel := transmute([]u8)string("kernel")
	testing.expect(t, fixture_object(fixture) != nil, "the load wrote the project object")

	old_text, new_text: [pr.MAX_PINS_LEX_BYTES]u8
	outcome, refusal := update_pin(fixture.table, fixture.state, 1, kernel, transmute([]u8)string("odin"), store_hash(9), old_text[:], new_text[:])
	testing.expect_value(t, refusal, pr.Project_Refusal.None)
	testing.expect_value(t, outcome.changed_lines, 1)
	testing.expect(t, outcome.old_tree_hash == store_hash(4) && outcome.new_tree_hash == store_hash(9))
	new_pins := string(new_text[:outcome.new_length])

	// The object holds the new pins.lex whole; the line that changed is the
	// only difference with the old one.
	object := fixture_object(fixture)
	evaluation, pins_lex, decoded := pr.decode_project_object(object.bytes[:object.length], kernel)
	testing.expect(t, decoded)
	testing.expect_value(t, string(pins_lex), new_pins)
	testing.expect_value(t, string(evaluation), string(fixture.evaluation[:fixture.evaluation_length]))

	// A restart reads the project from the store, with the moved pin.
	fixture_restart(fixture)
	testing.expect(t, find_loaded(fixture.table, 1, kernel) == nil, "the memory is empty after a restart")
	project, read_refusal := project_of(fixture.table, fixture.state, 1, kernel)
	testing.expect_value(t, read_refusal, pr.Project_Refusal.None)
	testing.expect_value(t, project.pin_count, 2)
	testing.expect(t, project.pins[1].tree_hash == store_hash(9), "the store keeps the moved pin")
	_, registered := lookup_project(fixture.state, "kernel")
	testing.expect(t, registered, "a project read back is registered for enter")
	// Another principal never reads the project of principal 1.
	_, other := project_of(fixture.table, fixture.state, 2, kernel)
	testing.expect_value(t, other, pr.Project_Refusal.Unknown_Project)
}

@(test)
an_update_that_the_store_refuses_leaves_the_pins_and_the_object :: proc(t: ^testing.T) {
	fixture := fixture_make(t)
	defer fixture_free(fixture)
	kernel := transmute([]u8)string("kernel")
	object := fixture_object(fixture)
	before := string(object.bytes[:object.length])
	pins_before := find_loaded(fixture.table, 1, kernel).pins
	fixture.store.writes_allowed = fixture.store.writes
	old_text, new_text: [pr.MAX_PINS_LEX_BYTES]u8
	_, refusal := update_pin(fixture.table, fixture.state, 1, kernel, transmute([]u8)string("odin"), store_hash(9), old_text[:], new_text[:])
	testing.expect_value(t, refusal, pr.Project_Refusal.Store_Failed)
	testing.expect(t, find_loaded(fixture.table, 1, kernel).pins == pins_before, "a refused update moves no pin")
	testing.expect_value(t, string(object.bytes[:object.length]), before)
	// The same hash again changes no line, so it needs no write.
	same, same_refusal := update_pin(fixture.table, fixture.state, 1, kernel, transmute([]u8)string("odin"), store_hash(4), old_text[:], new_text[:])
	testing.expect_value(t, same_refusal, pr.Project_Refusal.None)
	testing.expect_value(t, same.changed_lines, 0)
	// A load that the store refuses keeps no project.
	_, load_refusal := load_project(fixture.table, fixture.state, 1, transmute([]u8)string("other"), fixture.evaluation[:fixture.evaluation_length], nil)
	testing.expect_value(t, load_refusal, pr.Project_Refusal.Store_Failed)
	testing.expect(t, find_loaded(fixture.table, 1, transmute([]u8)string("other")) == nil)
	_, other_registered := lookup_project(fixture.state, "other")
	testing.expect(t, !other_registered, "a refused load registers nothing")
}

@(test)
a_damaged_project_object_is_refused_whole :: proc(t: ^testing.T) {
	fixture := fixture_make(t)
	defer fixture_free(fixture)
	kernel := transmute([]u8)string("kernel")
	object := fixture_object(fixture)
	saved := new_clone(object^)
	defer free(saved)
	head := 20 + pr.MAX_ENTRY_NAME_BYTES
	damages := [?]struct {
		offset: int,
		length: int,
	} {
		{0, -1}, // The magic.
		{8, -1}, // The length of the name.
		{12, -1}, // The length of the evaluation.
		{16, -1}, // The length of pins.lex.
		{20, -1}, // A byte of the name: another project.
		{20 + 10, -1}, // A byte after the name.
		{head + 1, -1}, // A byte of the evaluation.
		{-1, head - 1}, // Shorter than its head.
		{-1, saved.length - 1}, // One byte of pins.lex missing.
		{-1, saved.length + 1}, // One byte more.
	}
	for damage, index in damages {
		object^ = saved^
		if damage.offset >= 0 {
			object.bytes[damage.offset] ~= 0x5a
		} else {
			object.length = damage.length
		}
		fixture_restart(fixture)
		_, refusal := project_of(fixture.table, fixture.state, 1, kernel)
		testing.expectf(t, refusal == .Store_Damaged, "damage %d: %v", index, refusal)
		testing.expect(t, find_loaded(fixture.table, 1, kernel) == nil)
	}
	// A pins.lex in the object that is no pins.lex.
	object^ = saved^
	bad_pins := "{ kernel = nonsense }"
	written, encoded := pr.encode_project_object(kernel, fixture.evaluation[:fixture.evaluation_length], transmute([]u8)bad_pins, object.bytes[:])
	testing.expect(t, encoded)
	object.length = written
	fixture_restart(fixture)
	_, bad := project_of(fixture.table, fixture.state, 1, kernel)
	testing.expect_value(t, bad, pr.Project_Refusal.Store_Damaged)
	// The object whole again: the project reads.
	object^ = saved^
	fixture_restart(fixture)
	_, whole := project_of(fixture.table, fixture.state, 1, kernel)
	testing.expect_value(t, whole, pr.Project_Refusal.None)
}

@(test)
the_recipe_of_a_project_names_each_pin :: proc(t: ^testing.T) {
	fixture := fixture_make(t)
	defer fixture_free(fixture)
	kernel := transmute([]u8)string("kernel")
	spec, refusal := inputs_recipe(fixture.table, fixture.state, 1, kernel)
	testing.expect_value(t, refusal, pr.Project_Refusal.None)
	testing.expect(t, spec.builder_hash == pr.inputs_tree_builder_hash())
	testing.expect_value(t, spec.output_kind_word, u64(object_cache.Cache_Object_Kind.Tree))
	testing.expect_value(t, spec.input_count, u32(2))
	testing.expect_value(t, string(spec.inputs[1].name_bytes[:spec.inputs[1].name_length]), "odin")
	testing.expect(t, spec.inputs[1].hash == store_hash(4), "an input is the tree hash of its pin")
	first, _ := pr.recipe_hash(&spec)

	// A moved pin gives another recipe; moving it back gives the first one.
	old_text, new_text: [pr.MAX_PINS_LEX_BYTES]u8
	update_pin(fixture.table, fixture.state, 1, kernel, transmute([]u8)string("odin"), store_hash(9), old_text[:], new_text[:])
	moved_spec, _ := inputs_recipe(fixture.table, fixture.state, 1, kernel)
	moved, _ := pr.recipe_hash(&moved_spec)
	testing.expect(t, moved != first, "a moved pin changes the recipe")
	update_pin(fixture.table, fixture.state, 1, kernel, transmute([]u8)string("odin"), store_hash(4), old_text[:], new_text[:])
	back_spec, _ := inputs_recipe(fixture.table, fixture.state, 1, kernel)
	back, _ := pr.recipe_hash(&back_spec)
	testing.expect(t, back == first, "the recipe of the same pins has the same hash")

	// A project with no pin has no input to build, and an unknown project
	// has no recipe.
	_, empty := load_project(fixture.table, fixture.state, 1, transmute([]u8)string("empty"), fixture.evaluation[:fixture.evaluation_length], nil)
	testing.expect_value(t, empty, pr.Project_Refusal.None)
	_, no_pin := inputs_recipe(fixture.table, fixture.state, 1, transmute([]u8)string("empty"))
	testing.expect_value(t, no_pin, pr.Project_Refusal.Pin_Not_Found)
	_, unknown := inputs_recipe(fixture.table, fixture.state, 1, transmute([]u8)string("absent"))
	testing.expect_value(t, unknown, pr.Project_Refusal.Unknown_Project)
}

@(test)
an_invalid_project_or_pins_lex_writes_nothing :: proc(t: ^testing.T) {
	fixture := fixture_make(t)
	defer fixture_free(fixture)
	writes := fixture.store.writes
	other := transmute([]u8)string("other")
	_, bad_evaluation := load_project(fixture.table, fixture.state, 1, other, fixture.evaluation[:10], nil)
	testing.expect_value(t, bad_evaluation, pr.Project_Refusal.Bad_Evaluation)
	bad_pins := [?]string{
		"{ kernel = nonsense }",
		"{ kernel = { source = blake3:00, tree = blake3:00 } }",
		"{",
	}
	for text in bad_pins {
		_, refusal := load_project(fixture.table, fixture.state, 1, other, fixture.evaluation[:fixture.evaluation_length], transmute([]u8)text)
		testing.expectf(t, refusal != .None, "%q is refused", text)
	}
	long_evaluation := make([]u8, MAX_PROJECT_EVALUATION_BYTES + 1)
	defer delete(long_evaluation)
	_, too_long := load_project(fixture.table, fixture.state, 1, other, long_evaluation, nil)
	testing.expect_value(t, too_long, pr.Project_Refusal.Bad_Evaluation)
	testing.expect_value(t, fixture.store.writes, writes)
	testing.expect(t, find_loaded(fixture.table, 1, other) == nil)
}
