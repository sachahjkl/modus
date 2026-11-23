#+build !freestanding
package plan_reader

import "core:strings"
import "core:testing"
import "modus:contract/blake3"
import "modus:contract/chosen_values"
import module "modus:contract/module"
import "modus:contract/module_file_writer"
import description "modus:contract/plan_value_description"
import pr "modus:contract/plans_recipes"
import "modus:contract/role_contract"
import "modus:contract/value_kinds"
import "modus:lex_evaluator"
import "modus:lex_parser"
import "modus:sentence"

// The boot image of the tests: a holder of Display, the browser, and the
// holder of Storage with its plan-only values; another holder of Display
// by its hash.
@(private = "file")
Fake_Image :: struct {
	display, other_display, browser, storage: []u8,
	other_hash:                               blake3.Hash,
}

@(private = "file")
fake_of_name :: proc "contextless" (user: rawptr, name: string) -> []u8 {
	image := (^Fake_Image)(user)
	switch name {
	case "compositor":
		return image.display
	case "browser":
		return image.browser
	case "storage":
		return image.storage
	}
	return nil
}

@(private = "file")
fake_of_hash :: proc "contextless" (user: rawptr, hash: blake3.Hash) -> []u8 {
	image := (^Fake_Image)(user)
	return hash == image.other_hash ? image.other_display : nil
}

@(private = "file")
file_of_parts :: proc(t: ^testing.T, exports: []module_file_writer.Export_Part, records: []module_file_writer.Record_Description = nil, enums: []module_file_writer.Enum_Description = nil, settings: []module.Parameter_Setting = nil) -> []u8 {
	code := [16]u8{0 = 0xC3}
	segments := [1]module_file_writer.Segment_Part{{memory_offset = 0, memory_size = module.PAGE_SIZE, flags = {.Read, .Execute}, data = code[:]}}
	parts := module_file_writer.Module_Parts{segments = segments[:], exports = exports, records = records, enums = enums, parameter_settings = settings}
	needed, size_refusal := module_file_writer.file_size_needed(parts)
	testing.expect_value(t, size_refusal.refusal, module_file_writer.Refusal.None)
	bytes := make([]u8, int(needed), context.temp_allocator)
	_, refusal := module_file_writer.write(parts, bytes)
	testing.expect_value(t, refusal.refusal, module_file_writer.Refusal.None)
	return bytes
}

@(private = "file")
fake_image_make :: proc(t: ^testing.T) -> ^Fake_Image {
	image := new(Fake_Image, context.temp_allocator)
	display_parts := new(role_contract.Display_Module_Parts, context.temp_allocator)
	role_contract.display_module_parts_write(display_parts)
	image.display = file_of_parts(t, display_parts.exports[:], display_parts.records[:], display_parts.enums[:], display_parts.set_ranges[:])
	// Another holder of Display whose setter has only bar_edge.
	other_types := [1]module.Type{.Enum}
	other_names := [1]string{"bar_edge"}
	other_needs := [1]module.Parameter_Need{.Optional}
	other_details := [1]u32{}
	other_details[0], _ = module.enum_detail_make(1, 0)
	other_exports := [1]module_file_writer.Export_Part{{name = "set", parameters = other_types[:], parameter_names = other_names[:], parameter_details = other_details[:], parameter_needs = other_needs[:], result = .Integer}}
	image.other_display = file_of_parts(t, other_exports[:], nil, display_parts.enums[:1], nil)
	image.other_hash[0] = 0xAB
	browser_types := [1]module.Type{.Text}
	browser_names := [1]string{"home"}
	browser_needs := [1]module.Parameter_Need{.Optional}
	browser_exports := [1]module_file_writer.Export_Part{{name = "set", parameters = browser_types[:], parameter_names = browser_names[:], parameter_needs = browser_needs[:], result = .Integer}}
	// A bound of 40 bytes: both of its ends fit a line of the console.
	browser_bound := [1]module.Parameter_Setting{{export_index = 1, parameter = 0, has_range = 1, least = 1, most = 40}}
	image.browser = file_of_parts(t, browser_exports[:], nil, nil, browser_bound[:])
	storage_types := [2]module.Type{.Integer, .Integer}
	storage_names := [2]string{"keep_all_minutes", "hours_end_hours"}
	storage_needs := [2]module.Parameter_Need{.Optional, .Optional}
	storage_exports := [1]module_file_writer.Export_Part{{name = "plan_only", parameters = storage_types[:], parameter_names = storage_names[:], parameter_needs = storage_needs[:], result = .Integer}}
	storage_ranges := [2]module.Parameter_Setting{{export_index = 1, parameter = 0, has_range = 1, least = 1, most = 1440}, {export_index = 1, parameter = 1, has_range = 1, least = 1, most = 720}}
	image.storage = file_of_parts(t, storage_exports[:], nil, nil, storage_ranges[:])
	return image
}

// The host of the tests: the names of the evaluation of a plan, as the
// console gives them, and nothing else.
@(private = "file")
host_command_find :: proc "contextless" (data: rawptr, name: string) -> (signature: lex_evaluator.Command_Signature, found: bool) {
	switch name {
	case "plan", "module", "store":
		signature = {parameter_count = 1, untyped = true}
		signature.names[0] = "value"
		return signature, true
	}
	return {}, false
}

@(private = "file")
host_call_run :: proc "contextless" (data: rawptr, name: string, arguments: []lex_evaluator.Host_Value) -> (value: lex_evaluator.Host_Value, ok: bool) {
	evaluation := (^lex_evaluator.Evaluation)(data)
	switch name {
	case "plan":
		made, problem := lex_evaluator.plan_value_make(evaluation, arguments[0])
		return made, problem == .None
	case "module":
		return {kind = .Module_Ref, detail = arguments[0].detail, vm_value = {kind = .Module_Ref, meta = arguments[0].vm_value.meta}}, len(arguments) == 1 && arguments[0].kind == .Hash
	case "store":
		made, problem := lex_evaluator.store_ref_make(evaluation, arguments)
		return made, problem == .None
	}
	return {}, false
}

@(private = "file")
host_none :: proc "contextless" (data: rawptr, name: string) -> (value: lex_evaluator.Host_Value, ok: bool) {
	return {}, false
}

@(private = "file")
host_memory :: proc "contextless" (data: rawptr, size: int) -> (bytes: []u8, ok: bool) {
	return nil, size == 0
}

@(private = "file")
Run :: struct {
	buffers:      lex_parser.Console_Tree_Buffers,
	eval_buffers: lex_evaluator.Console_Eval_Buffers,
	tree:         lex_parser.Syntax_Tree,
	evaluation:   lex_evaluator.Evaluation,
	rows:         [TEST_ROWS]pr.Plan_Entry_Row,
	count:        int,
	refusal:      Refusal,
	evaluated:    bool,
}

// The rows that a test gives a read when it names no count.
TEST_ROWS :: 32

// plan_with_room gives a plan of principal 0 with no entry, in memory of
// the test that holds count entries.
plan_with_room :: proc(count: int) -> pr.Plan_Spec {
	bytes, _ := pr.plan_bytes_for(count)
	return pr.plan_of_memory(0, make([]u8, bytes, context.temp_allocator))
}

// read_text evaluates a line and reads its plan with rows_given rows.
@(private = "file")
read_text :: proc(image: ^Fake_Image, text: string, rows_given := TEST_ROWS) -> ^Run {
	run := new(Run, context.temp_allocator)
	lex_parser.parse_console(text, {}, &run.buffers, &run.tree)
	host := lex_evaluator.Evaluation_Host{data = &run.evaluation, name_value = host_none, command_find = host_command_find, call_run = host_call_run, record_memory = host_memory}
	lex_evaluator.evaluation_start(&run.evaluation, &run.tree, .Console, host, &run.eval_buffers, lex_evaluator.EVALUATION_BUDGET_STEPS, 2 * 1024 * 1024)
	value, ok := lex_evaluator.line_force(&run.evaluation)
	run.evaluated = ok
	if !ok {
		return run
	}
	run.count, run.refusal = read(&run.evaluation, value, {user = image, module_of_name = fake_of_name, module_of_hash = fake_of_hash}, run.rows[:rows_given])
	return run
}

@(private = "file")
sentence_of :: proc(refusal: Refusal) -> string {
	buffer := make([]u8, 512, context.temp_allocator)
	writer := sentence.Writer{buffer = buffer}
	refusal_write(&writer, refusal)
	return strings.clone(sentence.written(&writer), context.temp_allocator)
}

// Each refusal at its border, with the sentence that names it: a value that
// is no plan, a field of no plan, a role of no contract or of no module,
// stores that are no list, no store, a right of no member, a right
// missing or twice, an owner of no module, a field that its owner does not
// describe, a value of another kind, a member of no enum, a number one
// past each end of its range, a text past each end of its bound or past
// the bound of a plan, a text that is not UTF-8 or holds a control byte, a
// field twice, a field of the core that the core does not have, and more
// rows than given.
@(test)
a_plan_is_refused_at_its_border :: proc(t: ^testing.T) {
	image := fake_image_make(t)
	Case :: struct {
		text:     string,
		problem:  Problem,
		sentence: string, // "": the problem alone is checked.
	}
	long_home := strings.concatenate({"plan { values = { browser = { home = \"", strings.repeat("a", 41, context.temp_allocator), "\" } } }"}, context.temp_allocator)
	cases := [?]Case {
		{"plan { value = { display = { bar_edge = .top } } }", .Plan_Field_Unknown, "the plan has no field value: its fields are roles, stores, values and locks"},
		{"plan { roles = { displays = module(blake3:HASH) } }", .Role_Unknown, "the plan names the role displays, which no role contract has"},
		{"plan { roles = { display = 4 } }", .Role_Not_A_Module, "the role display is given no module: write display = module(blake3:…)"},
		{"plan { roles = 4 }", .Not_A_Record, "roles is no record: write roles = { name = value }"},
		{"plan { stores = 4 }", .Stores_Not_A_List, ""},
		{"plan { stores = [4] }", .Store_Not_A_Store, ""},
		{"plan { stores = [store(\"notes\", .read, .execute)] }", .Store_Right_Unknown, "the store notes takes .read, or .read and .write, not .execute"},
		{"plan { stores = [store(\"notes\", .write)] }", .Store_Right_Missing, ""},
		{"plan { stores = [store(\"notes\", .read, .read)] }", .Store_Right_Missing, ""},
		{"plan { stores = [store(\"notes\")] }", .Store_Right_Missing, ""},
		{"plan { values = { nowhere = { x = 1 } } }", .Owner_Unknown, "the plan names the owner nowhere, which is no module of the image and no role with a holder"},
		{"plan { values = { assistive = { x = 1 } } }", .Owner_Unknown, ""},
		{"plan { values = { display = { bar_edg = .top } } }", .Field_Unknown, "the owner display has no value bar_edg: its values are bar_edge, do_not_disturb, notification_show_milliseconds, magnifier_eighths, consent_arm_milliseconds, store_blocks"},
		{"plan { values = { display = { bar_edge = 2 } } }", .Value_Kind, "display.bar_edge takes a member, as .name"},
		{"plan { values = { display = { bar_edge = .botom } } }", .Member_Unknown, "display.bar_edge has no member .botom: its members are .top, .bottom"},
		{"plan { values = { display = { notification_show_milliseconds = .on } } }", .Value_Kind, "display.notification_show_milliseconds takes a number"},
		{"plan { values = { display = { notification_show_milliseconds = 999 } } }", .Out_Of_Range, "display.notification_show_milliseconds is 999, outside its range 1000 to 60000"},
		{"plan { values = { display = { notification_show_milliseconds = 60001 } } }", .Out_Of_Range, ""},
		{"plan { values = { browser = { home = 1 } } }", .Value_Kind, "browser.home takes a text, in quotes"},
		{"plan { values = { browser = { home = \"\" } } }", .Text_Past_Bound, "browser.home has 0 bytes, outside its bound of 1 to 40 bytes"},
		{long_home, .Text_Past_Bound, "browser.home has 41 bytes, outside its bound of 1 to 40 bytes"},
		{"plan { values = { display = { bar_edge = .top } }, locks = { display = { bar_edge = .bottom } } }", .Default_And_Lock, "display.bar_edge is in the plan twice: a value is a default in values, or a lock in locks, once"},
		{"plan { values = { root = { budget_share = 0 } } }", .Out_Of_Range, "root.budget_share is 0, outside its range 1 to 64"},
		{"plan { values = { root = { budget_share = 65 } } }", .Out_Of_Range, ""},
		{"plan { values = { root = { quota = 2 } } }", .Field_Unknown, "the owner root has no value quota: its values are budget_share, memory_screen_start_width, memory_screen_start_height, memory_screen_most_width, memory_screen_most_height"},
		// The core has no store, and an owner that does not exist has none.
		{"plan { values = { root = { store_blocks = 4 } } }", .Field_Unknown, ""},
		{"plan { values = { nowhere = { store_blocks = 4 } } }", .Owner_Unknown, ""},
		// The module that holds Display is no owner: its values are those of
		// the role, which the core gives it.
		{"plan { values = { compositor = { bar_edge = .top } } }", .Owner_Is_A_Holder, "the module compositor holds the role display: name its values by the role, display = { … }"},
		{"plan { values = { storage = { keep_all_minutes = 0 } } }", .Out_Of_Range, "storage.keep_all_minutes is 0, outside its range 1 to 1440"},
		{"plan { values = { browser = { store_blocks = 0 } } }", .Out_Of_Range, ""},
		{"plan { values = { display = { Bar = .top } } }", .Name_Not_Valid, ""},
		// The other holder of Display that the plan names has no magnifier.
		{"plan { roles = { display = module(blake3:OTHER) }, values = { display = { magnifier_eighths = 16 } } }", .Field_Unknown, "the owner display has no value magnifier_eighths: its values are bar_edge, store_blocks"},
	}
	other_hex := strings.concatenate({"ab", strings.repeat("00", 31, context.temp_allocator)}, context.temp_allocator)
	for item in cases {
		text, _ := strings.replace_all(item.text, "OTHER", other_hex, context.temp_allocator)
		text, _ = strings.replace_all(text, "HASH", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", context.temp_allocator)
		run := read_text(image, text)
		if !testing.expectf(t, run.evaluated, "%q is not evaluated: %v", text, run.evaluation.refusal) {
			continue
		}
		testing.expectf(t, run.refusal.problem == item.problem, "%q gives %v, not %v", text, run.refusal.problem, item.problem)
		testing.expectf(t, run.count == 0, "%q gives %d rows", text, run.count)
		if item.sentence != "" {
			testing.expect_value(t, sentence_of(run.refusal), item.sentence)
		}
	}
	// No plan: a number.
	none := read_text(image, "4")
	testing.expect_value(t, none.refusal.problem, Problem.Not_A_Plan)
	// More rows than given: three values in two rows.
	short := read_text(image, "plan { values = { display = { bar_edge = .top, do_not_disturb = .on, magnifier_eighths = 16 } } }", 2)
	testing.expect(t, short.refusal.problem == .Too_Many_Rows && short.refusal.integer == 2)
}

// A plan becomes its rows: a role by its hash, a store with its rights,
// each value typed by its owner, at the ends of each range and bound, a
// lock apart from a default; the rows pass the border of plans.
@(test)
a_plan_becomes_its_rows :: proc(t: ^testing.T) {
	image := fake_image_make(t)
	// A plan of one line of the console: the roles, the stores and the values
	// of the core.
	run := read_text(image, "plan { roles = { display = module(blake3:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef) }, stores = [store(\"notes\", .read), store(\"documents\", .read, .write)] }")
	testing.expect(t, run.evaluated && run.refusal.problem == .None && run.count == 3)
	// The values of the owners, at the ends of their ranges, a lock apart.
	values := read_text(image, "plan { values = { display = { bar_edge = .bottom, notification_show_milliseconds = 1000 }, root = { budget_share = 64 } }, locks = { browser = { store_blocks = 1 } } }")
	testing.expect(t, values.evaluated && values.refusal.problem == .None && values.count == 4)
	core := read_text(image, "plan { values = { storage = { keep_all_minutes = 1440 } }, locks = { display = { consent_arm_milliseconds = 10000 } } }")
	testing.expect(t, core.evaluated && core.refusal.problem == .None && core.count == 2)
	// A home of 40 bytes, the end of the bound of the fixture: one row of
	// text; a home of 81 bytes takes three rows.
	home := strings.repeat("h", 40, context.temp_allocator)
	text_plan := read_text(image, strings.concatenate({"plan { values = { browser = { home = \"", home, "\" } } }"}, context.temp_allocator))
	testing.expect(t, text_plan.evaluated && text_plan.refusal.problem == .None && text_plan.count == 1)
	plan := plan_with_room(TEST_ROWS)
	all := make([dynamic]pr.Plan_Entry_Row, context.temp_allocator)
	append(&all, ..run.rows[:run.count])
	append(&all, ..values.rows[:values.count])
	append(&all, ..core.rows[:core.count])
	append(&all, ..text_plan.rows[:text_plan.count])
	refusal, bad := pr.plan_of_rows(0, all[:], &plan)
	testing.expectf(t, refusal == .None, "the rows are refused: %v at %d", refusal, bad)
	expect_value :: proc(t: ^testing.T, plan: ^pr.Plan_Spec, name: string, word: u64, layer: chosen_values.Layer, loc := #caller_location) {
		for &entry in plan.entries[:plan.entry_count] {
			if string(entry.name_bytes[:entry.name_length]) == name {
				testing.expectf(t, entry.value_word == word && entry.value_layer_word == u64(layer), "%s is %d at %d", name, entry.value_word, entry.value_layer_word, loc = loc)
				return
			}
		}
		testing.expectf(t, false, "%s has no row", name, loc = loc)
	}
	// .bottom is the word 2 of the enum of the holder.
	expect_value(t, &plan, "display.bar_edge", 2, .Plan_Default)
	expect_value(t, &plan, "display.notification_show_milliseconds", 1000, .Plan_Default)
	expect_value(t, &plan, "root.budget_share", 64, .Plan_Default)
	expect_value(t, &plan, "storage.keep_all_minutes", 1440, .Plan_Default)
	expect_value(t, &plan, "display.consent_arm_milliseconds", 10000, .Locked)
	expect_value(t, &plan, "browser.store_blocks", 1, .Locked)
	found_home, found_role, found_store := false, false, false
	for &entry in plan.entries[:plan.entry_count] {
		switch string(entry.name_bytes[:entry.name_length]) {
		case "browser.home":
			found_home = pr.plan_value_text(&entry) == home
		case "display":
			found_role = entry.kind_word == u64(pr.Plan_Entry_Kind.Role_Holder) && entry.role_word == u64(role_contract.Role.Display) && entry.module_hash[0] == 0x01
		case "documents":
			found_store = entry.store_rights_word == u64(pr.Plan_Store_Rights.Read_Write)
		}
	}
	testing.expect(t, found_home && found_role && found_store)
}

// The layout of the rows: a record that is Plan_Entry_Row is taken; one
// with a field moved, a field missing, a field of another name or another
// size is refused, so a plan becomes no rows of another export.
@(test)
the_layout_of_the_rows_is_checked :: proc(t: ^testing.T) {
	fields := make([dynamic]module_file_writer.Field_Description, context.temp_allocator)
	for item in ROW_FIELDS {
		type := module.Type.Integer
		detail := u32(0) // An Integer of 8 bytes.
		kind := value_kinds.Field_Kind.Plain
		switch item.name {
		case "module_hash", "interposed_over_hash", "recipe_hash":
			type, detail, kind = .Bytes, 32, .Hash
		case "name":
			type, detail = .Text, 64
		case "value_text":
			type, detail = .Text, 40
		}
		append(&fields, module_file_writer.Field_Description{name = item.name, offset = item.offset, type = type, detail = detail, kind = kind})
	}
	write :: proc(t: ^testing.T, fields: []module_file_writer.Field_Description, size: u32) -> []u8 {
		records := [1]module_file_writer.Record_Description{{name = "Plan_Entry_Row", size = size, fields = fields}}
		bytes := make([]u8, 8192, context.temp_allocator)
		written, refusal := module_file_writer.write({records = records[:]}, bytes)
		testing.expect_value(t, refusal.refusal, module_file_writer.Refusal.None)
		return bytes[:written]
	}
	testing.expect(t, rows_layout_matches(write(t, fields[:], size_of(pr.Plan_Entry_Row)), 1))
	testing.expect(t, !rows_layout_matches(write(t, fields[:len(fields) - 1], size_of(pr.Plan_Entry_Row)), 1))
	renamed := make([]module_file_writer.Field_Description, len(fields), context.temp_allocator)
	copy(renamed, fields[:])
	renamed[0].name = "kind"
	testing.expect(t, !rows_layout_matches(write(t, renamed, size_of(pr.Plan_Entry_Row)), 1))
	moved := make([]module_file_writer.Field_Description, len(fields), context.temp_allocator)
	copy(moved, fields[:])
	moved[len(moved) - 1].offset += 8
	moved[len(moved) - 1].detail -= 8
	testing.expect(t, !rows_layout_matches(write(t, moved, size_of(pr.Plan_Entry_Row)), 1))
	// A record of another size: the text of 32 bytes in a record of 248.
	short := make([]module_file_writer.Field_Description, len(fields), context.temp_allocator)
	copy(short, fields[:])
	short[len(short) - 1].detail = 32
	testing.expect(t, !rows_layout_matches(write(t, short, size_of(pr.Plan_Entry_Row) - 8), 1))
	testing.expect(t, !rows_layout_matches(write(t, fields[:], size_of(pr.Plan_Entry_Row)), 2))
}

// The border of the plans service: each value of the rows of a plan is
// typed by the description of its owner, as the console types it. A word
// one past each end of its range, a word of no member, a word of the
// largest value, a text for a number, a word for a text, a kind word of no
// kind, a text one byte past its bound, an owner of no module, the module
// that holds a role, and store_blocks of the core are refused, each with
// its entry; the rows of the console pass.
@(test)
the_rows_of_a_plan_are_typed_at_the_border_of_plans :: proc(t: ^testing.T) {
	image := fake_image_make(t)
	described_image := description.Image{user = image, module_of_name = fake_of_name, module_of_hash = fake_of_hash}
	good := read_text(image, "plan { values = { display = { bar_edge = .bottom, notification_show_milliseconds = 1000 }, browser = { home = \"modus://welcome\" } } }")
	testing.expect(t, good.evaluated && good.refusal.problem == .None && good.count == 3)
	plan := new(pr.Plan_Spec, context.temp_allocator)
	plan^ = plan_with_room(TEST_ROWS)
	refusal, _ := pr.plan_of_rows(0, good.rows[:good.count], plan)
	testing.expect_value(t, refusal, pr.Plan_Refusal.None)
	passed, _ := description.entries_check(described_image, plan)
	testing.expect_value(t, passed.problem, description.Problem.None)
	Case :: struct {
		owner, field: string,
		word:         u64,
		text:         string,
		kind:         u64,
		problem:      description.Problem,
	}
	WORD :: u64(chosen_values.Entry_Kind.Word)
	TEXT :: u64(chosen_values.Entry_Kind.Text)
	cases := [?]Case {
		{"display", "notification_show_milliseconds", 999, "", WORD, .Out_Of_Range},
		{"display", "notification_show_milliseconds", 60001, "", WORD, .Out_Of_Range},
		{"display", "notification_show_milliseconds", max(u64), "", WORD, .Out_Of_Range},
		{"display", "bar_edge", 7, "", WORD, .Member_Unknown},
		{"display", "bar_edge", max(u64), "", WORD, .Member_Unknown},
		{"display", "bar_edge", 0, "top", TEXT, .Value_Kind},
		{"browser", "home", 1, "", WORD, .Value_Kind},
		{"browser", "home", 0, strings.repeat("a", 41, context.temp_allocator), TEXT, .Text_Past_Bound},
		{"browser", "home", 0, "", TEXT, .Text_Past_Bound},
		{"display", "bar_edge", 0, "", 3, .Value_Kind},
		{"display", "bar_edge", 0, "", 0, .Value_Kind},
		{"nowhere", "x", 1, "", WORD, .Owner_Unknown},
		{"compositor", "bar_edge", 0, "", WORD, .Owner_Is_A_Holder},
		{"root", "store_blocks", 4, "", WORD, .Field_Unknown},
		{"display", "nothing", 1, "", WORD, .Field_Unknown},
	}
	for item in cases {
		// A copy in memory of its own: each case changes one entry of its
		// copy and leaves the plan that passed as it was.
		bad := plan_with_room(TEST_ROWS)
		pr.plan_copy(&bad, plan)
		entry := &bad.entries[1]
		made: bool
		if item.kind == TEXT {
			entry^, made = pr.plan_entry_make_text_value(item.owner, item.field, "x", .Plan_Default)
			copy(entry.value_text[:], item.text)
			entry.value_text_length = u16(len(item.text))
			for index in len(item.text) ..< len(entry.value_text) {
				entry.value_text[index] = 0
			}
		} else {
			entry^, made = pr.plan_entry_make_value(item.owner, item.field, item.word, .Plan_Default)
			entry.value_kind_word = item.kind
		}
		testing.expect(t, made)
		found, index := description.entries_check(described_image, &bad)
		testing.expectf(t, found.problem == item.problem && index == 1, "%s.%s gives %v at %d, not %v", item.owner, item.field, found.problem, index, item.problem)
	}
}
