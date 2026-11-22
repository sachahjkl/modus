#+build !freestanding
package plans_recipes

import "core:testing"
import "modus:contract/blake3"
import "modus:contract/declaration_eval"
import "modus:contract/object_cache"
import "modus:contract/tree_hash"
import "modus:contract/value_kinds"

@(private = "file")
row_hash :: proc(tag: u8) -> value_kinds.Hash_Field {
	data := [4]u8{'r', 'o', 'w', tag}
	return value_kinds.Hash_Field(blake3.hash(data[:]))
}

@(private = "file")
module_row :: proc(name: string, tag: u8) -> (row: Plan_Entry_Row) {
	copy(row.name[:], name)
	row.kind_word = i64(Plan_Entry_Kind.Start_Module)
	row.module_hash = row_hash(tag)
	return row
}

@(private = "file")
store_row :: proc(name: string, rights: Plan_Store_Rights) -> (row: Plan_Entry_Row) {
	copy(row.name[:], name)
	row.kind_word = i64(Plan_Entry_Kind.Store_Grant)
	row.store_rights_word = i64(rights)
	return row
}

@(private = "file")
plan_is_zero :: proc(plan: ^Plan_Spec) -> bool {
	return plan.entry_count == 0 && plan.principal == 0 && plan.entries[0].kind_word == 0
}

@(test)
plan_of_rows_refuses_empty_and_past_the_bound :: proc(t: ^testing.T) {
	plan: Plan_Spec
	refusal, _ := plan_of_rows(3, nil, &plan)
	testing.expect_value(t, refusal, Plan_Refusal.Empty_Plan)
	testing.expect(t, plan_is_zero(&plan))

	rows: [MAX_PLAN_ENTRIES + 1]Plan_Entry_Row
	for index in 0 ..< len(rows) {
		rows[index] = module_row("m", u8(index))
		rows[index].name[1] = 'a' + u8(index % 26)
		rows[index].name[2] = 'a' + u8(index / 26)
	}
	refusal, _ = plan_of_rows(3, rows[:], &plan)
	testing.expect_value(t, refusal, Plan_Refusal.Too_Many_Entries)
	testing.expect(t, plan_is_zero(&plan))

	refusal, _ = plan_of_rows(3, rows[:MAX_PLAN_ENTRIES], &plan)
	testing.expect_value(t, refusal, Plan_Refusal.None)
	testing.expect_value(t, plan.entry_count, u32(MAX_PLAN_ENTRIES))

	refusal, _ = plan_of_rows(3, rows[:1], nil)
	testing.expect_value(t, refusal, Plan_Refusal.Buffer_Too_Small)
}

@(test)
plan_of_rows_refuses_each_damaged_row_and_leaves_no_plan :: proc(t: ^testing.T) {
	plan: Plan_Spec
	good := module_row("server", 1)

	empty_name := good
	empty_name.name = {}
	hidden_tail := good
	hidden_tail.name[10] = 'x'
	unknown_kind := good
	unknown_kind.kind_word = 99
	negative_kind := good
	negative_kind.kind_word = -1
	zero_hash := good
	zero_hash.module_hash = {}
	widest_grants := good
	widest_grants.start_grants_mask = -1
	slash_name := module_row("a/b", 2)

	cases := [?]struct {
		row:     Plan_Entry_Row,
		refusal: Plan_Refusal,
	}{
		{empty_name, .Invalid_Name},
		{hidden_tail, .Invalid_Name},
		{unknown_kind, .Bad_Entry_Kind},
		{negative_kind, .Bad_Entry_Kind},
		{zero_hash, .Zero_Module_Hash},
		{widest_grants, .Bad_Start_Grant},
		{slash_name, .Invalid_Name},
	}
	for item in cases {
		rows := [2]Plan_Entry_Row{store_row("home", .Read_Write), item.row}
		refusal, bad_index := plan_of_rows(5, rows[:], &plan)
		testing.expect_value(t, refusal, item.refusal)
		testing.expect_value(t, bad_index, u32(1))
		testing.expect(t, plan_is_zero(&plan))
	}

	twice := [2]Plan_Entry_Row{good, good}
	refusal, bad_index := plan_of_rows(5, twice[:], &plan)
	testing.expect_value(t, refusal, Plan_Refusal.Duplicate_Entry)
	testing.expect_value(t, bad_index, u32(1))

	bad_rights := [1]Plan_Entry_Row{store_row("home", .Read_Only)}
	bad_rights[0].store_rights_word = 3
	refusal, _ = plan_of_rows(5, bad_rights[:], &plan)
	testing.expect_value(t, refusal, Plan_Refusal.Bad_Store_Rights)
}

@(test)
plan_of_rows_gives_the_plan_of_the_makers :: proc(t: ^testing.T) {
	rows := [2]Plan_Entry_Row{module_row("server", 1), store_row("home", .Read_Write)}
	from_rows: Plan_Spec
	refusal, _ := plan_of_rows(7, rows[:], &from_rows)
	testing.expect_value(t, refusal, Plan_Refusal.None)

	made: Plan_Spec
	made.principal = 7
	made.entry_count = 2
	made.entries[0], _ = plan_entry_make_module(.Start_Module, "server", blake3.Hash(row_hash(1)))
	made.entries[1], _ = plan_entry_make_store("home", .Read_Write)
	first, first_refusal := plan_hash(&from_rows)
	second, second_refusal := plan_hash(&made)
	testing.expect_value(t, first_refusal, Plan_Refusal.None)
	testing.expect_value(t, second_refusal, Plan_Refusal.None)
	testing.expect(t, first == second, "a plan from rows has the hash of the same plan from the makers")

	back := plan_entry_row_of_entry(&from_rows.entries[0])
	testing.expect(t, back == rows[0], "a row survives the round trip through an entry")
}

@(test)
difference_summary_and_rows_carry_the_consent :: proc(t: ^testing.T) {
	rows := [1]Plan_Entry_Row{store_row("home", .Read_Write)}
	proposed: Plan_Spec
	plan_of_rows(2, rows[:], &proposed)
	difference: Plan_Difference
	testing.expect_value(t, plan_diff_compute(nil, &proposed, &difference), Plan_Refusal.None)
	summary := plan_difference_summary_of(&difference)
	consent, consent_ok := plan_consent_of_word(u64(summary.consent_word))
	testing.expect(t, consent_ok)
	testing.expect_value(t, consent, Plan_Consent.Needed)
	testing.expect_value(t, summary.change_count, i64(1))
	testing.expect_value(t, summary.added_stores, i64(1))
	testing.expect(t, summary.current_plan_hash == {}, "a first plan has no current plan")

	row := plan_diff_row_of_item(&difference.changes[0])
	testing.expect_value(t, row.change_word, i64(Plan_Change_Kind.Added))
	testing.expect_value(t, row.new_store_rights_word, i64(Plan_Store_Rights.Read_Write))

	// Narrowing the store needs no consent.
	narrower := [1]Plan_Entry_Row{store_row("home", .Read_Only)}
	next: Plan_Spec
	plan_of_rows(2, narrower[:], &next)
	testing.expect_value(t, plan_diff_compute(&proposed, &next, &difference), Plan_Refusal.None)
	summary = plan_difference_summary_of(&difference)
	testing.expect_value(t, summary.consent_word, i64(Plan_Consent.Not_Needed))
	testing.expect_value(t, summary.removed_grants, i64(1))
}

@(test)
closed_sets_of_the_rows_refuse_unknown_words :: proc(t: ^testing.T) {
	for word in ([?]u64{0, 3, 4, max(u64)}) {
		_, ok := plan_consent_of_word(word)
		testing.expectf(t, !ok, "the consent word %d names no member", word)
	}
	for word in ([?]u64{0, 4, max(u64)}) {
		_, ok := generation_standing_of_word(word)
		testing.expectf(t, !ok, "the standing word %d names no member", word)
	}
	standing, ok := generation_standing_of_word(3)
	testing.expect(t, ok)
	testing.expect_value(t, standing, Generation_Standing.Later)
}

@(test)
generation_rows_stand_against_the_current_generation :: proc(t: ^testing.T) {
	record := Applied_Plan_Record{plan_hash = blake3.Hash(row_hash(1)), generation = 2, principal = 1}
	testing.expect_value(t, plan_generation_row_of(&record, 2).standing_word, i64(Generation_Standing.Current))
	testing.expect_value(t, plan_generation_row_of(&record, 3).standing_word, i64(Generation_Standing.Earlier))
	testing.expect_value(t, plan_generation_row_of(&record, 1).standing_word, i64(Generation_Standing.Later))
	record.generation = max(u64)
	testing.expect_value(t, plan_generation_row_of(&record, 1).generation, max(i64))
}

@(test)
rollback_of_one_generation_has_no_previous :: proc(t: ^testing.T) {
	history := [1]Applied_Plan_Record{{plan_hash = blake3.Hash(row_hash(1)), generation = 1, principal = 4}}
	_, refusal := plan_rollback_check(history[:], 1)
	testing.expect_value(t, refusal, Plan_Refusal.Empty_History)
	_, refusal = plan_rollback_check(nil, 0)
	testing.expect_value(t, refusal, Plan_Refusal.Empty_History)
	_, refusal = plan_rollback_check(history[:], 1, 1, true)
	testing.expect_value(t, refusal, Plan_Refusal.Already_At_Generation)
}

@(private = "file")
input_row :: proc(name: string, kind: object_cache.Cache_Object_Kind, tag: u8) -> (row: Recipe_Input_Row) {
	copy(row.name[:], name)
	row.kind_word = i64(kind)
	row.hash = row_hash(tag)
	return row
}

@(test)
recipe_spec_of_parts_refuses_each_damaged_part :: proc(t: ^testing.T) {
	spec: Recipe_Spec
	head := Recipe_Head{output_kind_word = i64(object_cache.Cache_Object_Kind.Tree), builder_hash = row_hash(9)}
	inputs := [2]Recipe_Input_Row{input_row("src", .Tree, 1), input_row("lib", .Blob, 2)}

	refusal, _ := recipe_spec_of_parts(nil, inputs[:], nil, &spec)
	testing.expect_value(t, refusal, Recipe_Refusal.Buffer_Too_Small)

	for field in 0 ..< 3 {
		bad := head
		switch field {
		case 0:
			bad.output_kind_word = -1
		case 1:
			bad.source_date_unix = -1
		case 2:
			bad.output_block_limit = min(i64)
		}
		refusal, _ = recipe_spec_of_parts(&bad, inputs[:], nil, &spec)
		testing.expect_value(t, refusal, Recipe_Refusal.Bad_Head_Value)
		testing.expect(t, spec.input_count == 0 && spec.builder_hash == {}, "a refused recipe leaves no spec")
	}

	unknown_output := head
	unknown_output.output_kind_word = 3
	refusal, _ = recipe_spec_of_parts(&unknown_output, inputs[:], nil, &spec)
	testing.expect_value(t, refusal, Recipe_Refusal.Bad_Output_Kind)

	zero_builder := head
	zero_builder.builder_hash = {}
	refusal, _ = recipe_spec_of_parts(&zero_builder, inputs[:], nil, &spec)
	testing.expect_value(t, refusal, Recipe_Refusal.Zero_Builder_Hash)

	many: [MAX_RECIPE_INPUTS + 1]Recipe_Input_Row
	refusal, _ = recipe_spec_of_parts(&head, many[:], nil, &spec)
	testing.expect_value(t, refusal, Recipe_Refusal.Too_Many_Inputs)

	large: [MAX_RECIPE_ARG_BYTES + 1]u8
	refusal, _ = recipe_spec_of_parts(&head, inputs[:], large[:], &spec)
	testing.expect_value(t, refusal, Recipe_Refusal.Arguments_Too_Large)
	refusal, _ = recipe_spec_of_parts(&head, inputs[:], large[:MAX_RECIPE_ARG_BYTES], &spec)
	testing.expect_value(t, refusal, Recipe_Refusal.None)

	damaged := inputs
	damaged[1].name = {}
	bad_index: u32
	refusal, bad_index = recipe_spec_of_parts(&head, damaged[:], nil, &spec)
	testing.expect_value(t, refusal, Recipe_Refusal.Invalid_Input_Name)
	testing.expect_value(t, bad_index, u32(1))

	damaged = inputs
	damaged[1].kind_word = -2
	refusal, bad_index = recipe_spec_of_parts(&head, damaged[:], nil, &spec)
	testing.expect_value(t, refusal, Recipe_Refusal.Bad_Input_Kind)
	testing.expect_value(t, bad_index, u32(1))

	damaged = inputs
	damaged[1].kind_word = 7
	refusal, _ = recipe_spec_of_parts(&head, damaged[:], nil, &spec)
	testing.expect_value(t, refusal, Recipe_Refusal.Bad_Input_Kind)

	damaged = inputs
	damaged[1].hash = {}
	refusal, _ = recipe_spec_of_parts(&head, damaged[:], nil, &spec)
	testing.expect_value(t, refusal, Recipe_Refusal.Zero_Input_Hash)

	damaged = inputs
	damaged[1].name = damaged[0].name
	refusal, _ = recipe_spec_of_parts(&head, damaged[:], nil, &spec)
	testing.expect_value(t, refusal, Recipe_Refusal.Duplicate_Input)

	damaged = inputs
	damaged[0].name[20] = 'x'
	refusal, _ = recipe_spec_of_parts(&head, damaged[:], nil, &spec)
	testing.expect_value(t, refusal, Recipe_Refusal.Invalid_Input_Name)
}

@(test)
recipe_from_parts_hashes_as_its_spec_whatever_the_order :: proc(t: ^testing.T) {
	head := Recipe_Head{output_kind_word = i64(object_cache.Cache_Object_Kind.Tree), builder_hash = row_hash(9)}
	inputs := [2]Recipe_Input_Row{input_row("src", .Tree, 1), input_row("lib", .Blob, 2)}
	swapped := [2]Recipe_Input_Row{inputs[1], inputs[0]}
	first, second: Recipe_Spec
	refusal, _ := recipe_spec_of_parts(&head, inputs[:], nil, &first)
	testing.expect_value(t, refusal, Recipe_Refusal.None)
	refusal, _ = recipe_spec_of_parts(&head, swapped[:], nil, &second)
	testing.expect_value(t, refusal, Recipe_Refusal.None)
	first_hash, _ := recipe_hash(&first)
	second_hash, _ := recipe_hash(&second)
	testing.expect(t, first_hash == second_hash, "the order of the input rows does not change the recipe hash")
}

@(private = "file")
inputs_tree_sandbox :: proc(inputs: []Recipe_Input_Row) -> (sandbox: Builder_Sandbox_Spec, refusal: Recipe_Refusal) {
	head := Recipe_Head{output_kind_word = i64(object_cache.Cache_Object_Kind.Tree), builder_hash = value_kinds.Hash_Field(inputs_tree_builder_hash())}
	spec: Recipe_Spec
	refusal, _ = recipe_spec_of_parts(&head, inputs, nil, &spec)
	if refusal != .None {
		return {}, refusal
	}
	return builder_sandbox_prepare(&spec)
}

@(test)
inputs_tree_builder_refuses_what_it_does_not_build :: proc(t: ^testing.T) {
	inputs := [2]Recipe_Input_Row{input_row("src", .Tree, 1), input_row("lib", .Blob, 2)}
	sandbox, refusal := inputs_tree_sandbox(inputs[:])
	testing.expect_value(t, refusal, Recipe_Refusal.None)
	output: [4096]u8

	_, refusal = inputs_tree_build(nil, output[:])
	testing.expect_value(t, refusal, Recipe_Refusal.Builder_Failed)

	other := sandbox
	other.builder_hash = blake3.Hash(row_hash(9))
	_, refusal = inputs_tree_build(&other, output[:])
	testing.expect_value(t, refusal, Recipe_Refusal.Builder_Needs_Sandbox)

	network := sandbox
	network.allow_network = true
	_, refusal = inputs_tree_build(&network, output[:])
	testing.expect_value(t, refusal, Recipe_Refusal.Sandbox_Violation)

	writable := sandbox
	writable.inputs_read_only = false
	_, refusal = inputs_tree_build(&writable, output[:])
	testing.expect_value(t, refusal, Recipe_Refusal.Sandbox_Violation)

	blob := sandbox
	blob.output_kind = .Blob
	_, refusal = inputs_tree_build(&blob, output[:])
	testing.expect_value(t, refusal, Recipe_Refusal.Sandbox_Violation)

	arguments := sandbox
	arguments.arguments_length = 1
	_, refusal = inputs_tree_build(&arguments, output[:])
	testing.expect_value(t, refusal, Recipe_Refusal.Sandbox_Violation)

	_, refusal = inputs_tree_build(&sandbox, output[:8])
	testing.expect_value(t, refusal, Recipe_Refusal.Malformed_Output)
}

@(test)
inputs_tree_builder_gives_one_tree_whatever_the_order :: proc(t: ^testing.T) {
	inputs := [2]Recipe_Input_Row{input_row("src", .Tree, 1), input_row("lib", .Blob, 2)}
	swapped := [2]Recipe_Input_Row{inputs[1], inputs[0]}
	first_sandbox, _ := inputs_tree_sandbox(inputs[:])
	second_sandbox, _ := inputs_tree_sandbox(swapped[:])
	first, second: [4096]u8
	first_length, first_refusal := inputs_tree_build(&first_sandbox, first[:])
	second_length, second_refusal := inputs_tree_build(&second_sandbox, second[:])
	testing.expect_value(t, first_refusal, Recipe_Refusal.None)
	testing.expect_value(t, second_refusal, Recipe_Refusal.None)
	first_hash, first_tree := tree_hash.tree_hash(first[:first_length])
	second_hash, second_tree := tree_hash.tree_hash(second[:second_length])
	testing.expect_value(t, first_tree, tree_hash.Tree_Refusal.None)
	testing.expect_value(t, second_tree, tree_hash.Tree_Refusal.None)
	testing.expect(t, first_hash == second_hash, "the tree of the inputs does not depend on their order")
	entry, found, _ := tree_hash.tree_lookup(first[:first_length], "src")
	testing.expect(t, found)
	testing.expect_value(t, entry.kind, tree_hash.Tree_Entry_Kind.Tree)
	entry, found, _ = tree_hash.tree_lookup(first[:first_length], "lib")
	testing.expect(t, found)
	testing.expect_value(t, entry.kind, tree_hash.Tree_Entry_Kind.Object)
}

@(test)
pins_lex_line_difference_counts_each_changed_line :: proc(t: ^testing.T) {
	same := "{\n  a = 1,\n}\n"
	changed, _, _, _ := pins_lex_line_difference(transmute([]u8)same, transmute([]u8)same)
	testing.expect_value(t, changed, 0)

	moved := "{\n  a = 2,\n}\n"
	line_number: int
	old_line, new_line: []u8
	changed, line_number, old_line, new_line = pins_lex_line_difference(transmute([]u8)same, transmute([]u8)moved)
	testing.expect_value(t, changed, 1)
	testing.expect_value(t, line_number, 2)
	testing.expect_value(t, string(old_line), "  a = 1,")
	testing.expect_value(t, string(new_line), "  a = 2,")

	two := "{\n  a = 2,\n]\n"
	changed, line_number, old_line, _ = pins_lex_line_difference(transmute([]u8)same, transmute([]u8)two)
	testing.expect_value(t, changed, 2)
	testing.expect_value(t, line_number, 0)
	testing.expect(t, old_line == nil, "two changed lines give no single line")

	longer := "{\n  a = 1,\n}\nextra\n"
	changed, line_number, _, new_line = pins_lex_line_difference(transmute([]u8)same, transmute([]u8)longer)
	testing.expect_value(t, changed, 1)
	testing.expect_value(t, line_number, 4)
	testing.expect_value(t, string(new_line), "extra")

	changed, _, _, _ = pins_lex_line_difference(nil, transmute([]u8)same)
	testing.expect_value(t, changed, 3)
}

@(test)
pins_lex_update_changes_one_line_of_the_canonical_form :: proc(t: ^testing.T) {
	pins: [2]Pin_Entry
	pins[0], _ = pin_entry_make("kernel", blake3.Hash(row_hash(1)), blake3.Hash(row_hash(2)))
	pins[1], _ = pin_entry_make("odin", blake3.Hash(row_hash(3)), blake3.Hash(row_hash(4)), "v1")
	old_text, new_text: [MAX_PINS_LEX_BYTES]u8
	old_length, _ := pins_lex_format(pins[:], old_text[:])
	pins[1].tree_hash = blake3.Hash(row_hash(5))
	new_length, _ := pins_lex_format(pins[:], new_text[:])
	changed, line_number, _, new_line := pins_lex_line_difference(old_text[:old_length], new_text[:new_length])
	testing.expect_value(t, changed, 1)
	testing.expect_value(t, line_number, 3)
	testing.expect(t, len(new_line) > 0 && new_line[2] == 'o', "the line of odin moved")
}

@(private = "file")
Project_Evaluation_Shape :: enum {
	Whole,
	No_Source,
	Zero_Source,
	Write_Only_Store,
	Unknown_Right,
	Right_Twice,
	Store_Twice,
	Module_Twice,
	Unknown_Console_Field,
	Text_Module,
	Not_A_Project,
	Trailing_Byte,
}

@(private = "file")
project_evaluation :: proc(buffer: []u8, shape: Project_Evaluation_Shape) -> int {
	writer := declaration_eval.output_writer_start(buffer, {status = .Ok})
	if shape == .Not_A_Project {
		declaration_eval.output_write_integer(&writer, 4)
		return writer.written
	}
	declaration_eval.output_write_u8(&writer, u8(declaration_eval.Value_Tag.Project))
	declaration_eval.output_write_u8(&writer, u8(declaration_eval.Value_Tag.Record))
	field_count: u32 = shape == .No_Source ? 2 : 3
	declaration_eval.output_write_u32(&writer, field_count)

	declaration_eval.output_write_string(&writer, "console")
	declaration_eval.output_write_u8(&writer, u8(declaration_eval.Value_Tag.Record))
	declaration_eval.output_write_u32(&writer, shape == .Unknown_Console_Field ? 3 : 2)
	declaration_eval.output_write_string(&writer, "modules")
	declaration_eval.output_write_u8(&writer, u8(declaration_eval.Value_Tag.List))
	declaration_eval.output_write_u32(&writer, 2)
	if shape == .Text_Module {
		declaration_eval.output_write_text(&writer, "odin")
	} else {
		declaration_eval.output_write_module_ref(&writer, blake3.Hash(row_hash(1)))
	}
	declaration_eval.output_write_module_ref(&writer, blake3.Hash(row_hash(shape == .Module_Twice ? 1 : 2)))
	if shape == .Unknown_Console_Field {
		declaration_eval.output_write_string(&writer, "network")
		declaration_eval.output_write_integer(&writer, 1)
	}
	declaration_eval.output_write_string(&writer, "stores")
	declaration_eval.output_write_u8(&writer, u8(declaration_eval.Value_Tag.List))
	declaration_eval.output_write_u32(&writer, 2)
	declaration_eval.output_write_u8(&writer, u8(declaration_eval.Value_Tag.Store_Ref))
	declaration_eval.output_write_string(&writer, "kernel")
	switch shape {
	case .Write_Only_Store:
		declaration_eval.output_write_u32(&writer, 1)
		declaration_eval.output_write_string(&writer, "Write")
	case .Unknown_Right:
		declaration_eval.output_write_u32(&writer, 1)
		declaration_eval.output_write_string(&writer, "Execute")
	case .Right_Twice:
		declaration_eval.output_write_u32(&writer, 2)
		declaration_eval.output_write_string(&writer, "Read")
		declaration_eval.output_write_string(&writer, "Read")
	case .Whole, .No_Source, .Zero_Source, .Store_Twice, .Module_Twice, .Unknown_Console_Field, .Text_Module, .Not_A_Project, .Trailing_Byte:
		declaration_eval.output_write_u32(&writer, 2)
		declaration_eval.output_write_string(&writer, "Read")
		declaration_eval.output_write_string(&writer, "Write")
	}
	declaration_eval.output_write_u8(&writer, u8(declaration_eval.Value_Tag.Store_Ref))
	declaration_eval.output_write_string(&writer, shape == .Store_Twice ? "kernel" : "notes")
	declaration_eval.output_write_u32(&writer, 1)
	declaration_eval.output_write_string(&writer, "Read")

	declaration_eval.output_write_string(&writer, "outputs")
	declaration_eval.output_write_u8(&writer, u8(declaration_eval.Value_Tag.Record))
	declaration_eval.output_write_u32(&writer, 0)

	if shape != .No_Source {
		declaration_eval.output_write_string(&writer, "source")
		declaration_eval.output_write_hash(&writer, shape == .Zero_Source ? blake3.Hash{} : blake3.Hash(row_hash(7)))
	}
	if shape == .Trailing_Byte {
		declaration_eval.output_write_u8(&writer, 0)
	}
	return writer.written
}

@(test)
project_of_evaluation_reads_source_and_console :: proc(t: ^testing.T) {
	buffer: [2048]u8
	length := project_evaluation(buffer[:], .Whole)
	declaration: Project_Declaration
	refusal := project_declaration_of_evaluation(transmute([]u8)string("kernel"), buffer[:length], &declaration)
	testing.expect_value(t, refusal, Project_Refusal.None)
	testing.expect(t, declaration.project_tree_hash == blake3.Hash(row_hash(7)), "the tree of the project is its field source")
	testing.expect_value(t, string(declaration.name_bytes[:declaration.name_length]), "kernel")
	testing.expect(t, declaration.has_console_field)
	testing.expect_value(t, declaration.console_module_count, u32(2))
	testing.expect_value(t, declaration.console_store_count, u32(2))
	testing.expect_value(t, declaration.console_stores[0].rights_word, u64(Plan_Store_Rights.Read_Write))
	testing.expect_value(t, declaration.console_stores[1].rights_word, u64(Plan_Store_Rights.Read_Only))
	name := console_module_name(blake3.Hash(row_hash(1)))
	testing.expect_value(t, string(declaration.console_modules[0].name_bytes[:declaration.console_modules[0].name_length]), string(name[:]))
	testing.expect(t, lex_field_name_valid(name[:]), "the name of a console module is a Lex name")
}

@(test)
project_of_evaluation_refuses_each_damaged_evaluation :: proc(t: ^testing.T) {
	buffer: [2048]u8
	declaration: Project_Declaration
	kernel := transmute([]u8)string("kernel")

	testing.expect_value(t, project_declaration_of_evaluation(kernel, nil, &declaration), Project_Refusal.Bad_Evaluation)
	testing.expect_value(t, project_declaration_of_evaluation(kernel, buffer[:10], &declaration), Project_Refusal.Bad_Evaluation)

	refused, _ := declaration_eval.output_write_refusal(buffer[:], .Parse_Error, 1, 2, 3, "no")
	testing.expect_value(t, project_declaration_of_evaluation(kernel, buffer[:refused], &declaration), Project_Refusal.Evaluation_Refused)

	cases := [?]struct {
		shape:   Project_Evaluation_Shape,
		refusal: Project_Refusal,
	}{
		{.Not_A_Project, .Not_A_Project},
		{.No_Source, .Missing_Field},
		{.Zero_Source, .Zero_Hash},
		{.Write_Only_Store, .Bad_Store_Rights},
		{.Unknown_Right, .Bad_Store_Rights},
		{.Right_Twice, .Bad_Store_Rights},
		{.Store_Twice, .Duplicate_Store},
		{.Module_Twice, .Duplicate_Module},
		{.Unknown_Console_Field, .Unknown_Field},
		{.Text_Module, .Invalid_Module_Name},
		{.Trailing_Byte, .Bad_Evaluation},
	}
	for item in cases {
		length := project_evaluation(buffer[:], item.shape)
		refusal := project_declaration_of_evaluation(kernel, buffer[:length], &declaration)
		testing.expectf(t, refusal == item.refusal, "%v: %v, expected %v", item.shape, refusal, item.refusal)
		testing.expect(t, declaration.name_length == 0 && declaration.project_tree_hash == {}, "a refused evaluation leaves no declaration")
	}

	length := project_evaluation(buffer[:], .Whole)
	for name in ([?]string{"", "1kernel", "a-b", "if"}) {
		refusal := project_declaration_of_evaluation(transmute([]u8)name, buffer[:length], &declaration)
		testing.expectf(t, refusal == .Unknown_Project, "the name %q is no Lex name", name)
	}
	testing.expect_value(t, project_declaration_of_evaluation(kernel, buffer[:length], nil), Project_Refusal.Buffer_Too_Small)

	damaged := buffer
	damaged[length - 1] ~= 0xFF
	testing.expect(t, project_declaration_of_evaluation(kernel, damaged[:length], &declaration) == .None, "a changed hash byte is still a hash")
	damaged = buffer
	damaged[declaration_eval.OUTPUT_HEADER_BYTES] = 200
	testing.expect_value(t, project_declaration_of_evaluation(kernel, damaged[:length], &declaration), Project_Refusal.Bad_Evaluation)
}

@(test)
text_field_length_refuses_a_hidden_tail :: proc(t: ^testing.T) {
	field: [8]u8
	length, ok := text_field_length(field[:])
	testing.expect(t, ok)
	testing.expect_value(t, length, 0)
	field = {'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'}
	length, ok = text_field_length(field[:])
	testing.expect(t, ok)
	testing.expect_value(t, length, 8)
	field = {'a', 0, 'c', 0, 0, 0, 0, 0}
	_, ok = text_field_length(field[:])
	testing.expect(t, !ok)
}
