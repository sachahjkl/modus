#+build !freestanding
package lex_evaluator

import "core:fmt"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import module "modus:contract/module"
import "modus:contract/module_file_writer"
import "modus:lex_parser"

// The fake host of the tests. Each call is an effect: the host writes its
// name in the log, in the order of the runs, and gives the number of the
// run as its value. `fails` runs and fails, as an export that fails.
// `missing` names no command. `pure` has no effect. `x` is 7, `t` is
// "tee", and `rows_a`, `rows_b` and `rows_other` are Tables, the last of
// another record; `rect` is a Rectangle and `labelled` a Labelled; no other
// name is a variable.
//
// The commands with parameters: `area(rectangle: Rectangle)` gives width
// times height; `grow(rectangle: Rectangle, [by: Integer])` gives the count
// of its arguments; `label(labelled: Labelled)` gives its count;
// `pair(first: Integer, second: Integer)` gives first * 10 + second;
// `any(Value)` takes any value and has no names.
@(private = "file")
Fake :: struct {
	log:                   [32]string,
	log_count:             int,
	finds:                 int, // The commands that the evaluator asked for.
	join:                  [256]u8,
	join_count:            int,
	last_text:             string, // The Text that a call took last as its last argument.
	rectangle_description: [1024]u8,
	rectangle_file:        []u8, // Rectangle: x, y, width, height, Integers of 8 bytes.
	labelled_description:  [1024]u8,
	labelled_file:         []u8, // Labelled: name, a Text of 4 bytes, and count, an Integer of 1 byte.
	rect:                  [32]u8, // A Rectangle 1, 2, 30, 4.
	labelled:              [8]u8, // A Labelled "ab", 5.
	memory:                [512]u8, // The records that literals make.
	memory_used:           int,
	enum_memory:           [4096]u8,
	enum_file:             []u8, // A module file with two enums: 1 Keyboard_Layout {united_states, french}, 2 Font {vector, spleen}.
}

// fake_enums_make writes the module file of the two enums of the fake. The
// command `set(layout: Keyboard_Layout, font: Font)` takes both, each
// optional; it gives layout * 10 + font, with 9 for a setting left out.
@(private = "file")
fake_enums_make :: proc(fake: ^Fake) {
	layout := [2]module_file_writer.Member_Description{{"united_states", 0}, {"french", 1}}
	font := [2]module_file_writer.Member_Description{{"vector", 0}, {"spleen", 1}}
	enums := [2]module_file_writer.Enum_Description{{"Keyboard_Layout", 4, true, layout[:]}, {"Font", 4, true, font[:]}}
	size, refusal := module_file_writer.write({enums = enums[:]}, fake.enum_memory[:])
	assert(refusal.refusal == .None)
	fake.enum_file = fake.enum_memory[:size]
}

@(private = "file")
fake_name_value :: proc "contextless" (data: rawptr, name: string) -> (value: Host_Value, ok: bool) {
	fake := (^Fake)(data)
	switch name {
	case "x":
		return {kind = .Integer, integer = 7}, true
	case "t":
		return {kind = .Text, text = "tee"}, true
	case "rows_a":
		return {kind = .Table, record = transmute([]u8)string("ab"), detail = 1}, true
	case "rows_b":
		return {kind = .Table, record = transmute([]u8)string("cd"), detail = 1}, true
	case "rows_other":
		return {kind = .Table, record = transmute([]u8)string("ef"), detail = 2}, true
	case "rect":
		return {kind = .Record, record = fake.rect[:], file = fake.rectangle_file, detail = 1}, true
	case "labelled":
		return {kind = .Record, record = fake.labelled[:], file = fake.labelled_file, detail = 1}, true
	}
	return {}, false
}

@(private = "file")
fake_command_find :: proc "contextless" (data: rawptr, name: string) -> (signature: Command_Signature, found: bool) {
	fake := (^Fake)(data)
	fake.finds += 1
	switch name {
	case "missing":
		return {}, false
	case "area":
		signature.parameter_count = 1
		signature.names[0], signature.kinds[0], signature.files[0], signature.details[0] = "rectangle", .Record, fake.rectangle_file, 1
	case "grow":
		signature.parameter_count, signature.optional_last = 2, true
		signature.names[0], signature.kinds[0], signature.files[0], signature.details[0] = "rectangle", .Record, fake.rectangle_file, 1
		signature.names[1], signature.kinds[1] = "by", .Integer
	case "label":
		signature.parameter_count = 1
		signature.names[0], signature.kinds[0], signature.files[0], signature.details[0] = "labelled", .Record, fake.labelled_file, 1
	case "pair":
		signature.parameter_count = 2
		signature.names[0], signature.kinds[0] = "first", .Integer
		signature.names[1], signature.kinds[1] = "second", .Integer
	case "any":
		signature.parameter_count = 1
		signature.kinds[0] = .None
	case "set":
		signature.parameter_count = 2
		signature.names[0], signature.kinds[0], signature.files[0], signature.details[0], signature.optional[0] = "layout", .Enum, fake.enum_file, 1, true
		signature.names[1], signature.kinds[1], signature.files[1], signature.details[1], signature.optional[1] = "font", .Enum, fake.enum_file, 2, true
	}
	signature.has_effect = name != "pure"
	return signature, true
}

@(private = "file")
fake_call_run :: proc "contextless" (data: rawptr, name: string, arguments: []Host_Value) -> (value: Host_Value, ok: bool) {
	fake := (^Fake)(data)
	// A line of many calls counts each one; the log keeps the first.
	if fake.log_count < len(fake.log) {
		fake.log[fake.log_count] = name
	}
	fake.log_count += 1
	if len(arguments) > 0 && arguments[len(arguments) - 1].kind == .Text {
		fake.last_text = arguments[len(arguments) - 1].text
	}
	switch name {
	case "fails":
		return {}, false
	case "area":
		width, _ := record_field_value(arguments[0], "width")
		height, _ := record_field_value(arguments[0], "height")
		return {kind = .Integer, integer = width.integer * height.integer}, true
	case "grow":
		return {kind = .Integer, integer = i64(len(arguments))}, true
	case "label":
		count, _ := record_field_value(arguments[0], "count")
		return count, true
	case "pair":
		return {kind = .Integer, integer = arguments[0].integer * 10 + arguments[1].integer}, true
	case "set":
		// Each value is an Enum of the enum of its parameter, or no value.
		given :: proc "contextless" (value: Host_Value, enum_index: u32) -> i64 {
			if value.kind != .Enum || value.detail != enum_index {
				return 9
			}
			return value.integer
		}
		layout, font := Host_Value{}, Host_Value{}
		if len(arguments) > 0 {
			layout = arguments[0]
		}
		if len(arguments) > 1 {
			font = arguments[1]
		}
		return {kind = .Integer, integer = given(layout, 1) * 10 + given(font, 2)}, true
	}
	return {kind = .Integer, integer = i64(fake.log_count)}, true
}

@(private = "file")
fake_record_memory :: proc "contextless" (data: rawptr, size: int) -> (bytes: []u8, ok: bool) {
	fake := (^Fake)(data)
	start := (fake.memory_used + 7) &~ 7
	if size > len(fake.memory) - start {
		return nil, false
	}
	fake.memory_used = start + size
	return fake.memory[start:fake.memory_used], true
}

// fake_records_make writes the descriptions of the records of the fake,
// and its two record values.
@(private = "file")
fake_records_make :: proc(fake: ^Fake) {
	rectangle_fields := [4]module_file_writer.Field_Description {
		{name = "x", offset = 0, type = .Integer, detail = 8},
		{name = "y", offset = 8, type = .Integer, detail = 8},
		{name = "width", offset = 16, type = .Integer, detail = 8},
		{name = "height", offset = 24, type = .Integer, detail = 8},
	}
	rectangle_records := [1]module_file_writer.Record_Description{{name = "Rectangle", size = 32, fields = rectangle_fields[:]}}
	rect_size, rect_refusal := module_file_writer.write({records = rectangle_records[:]}, fake.rectangle_description[:])
	assert(rect_refusal.refusal == .None)
	fake.rectangle_file = fake.rectangle_description[:rect_size]

	labelled_fields := [2]module_file_writer.Field_Description {
		{name = "name", offset = 0, type = .Text, detail = 4},
		{name = "count", offset = 4, type = .Integer, detail = 1},
	}
	labelled_records := [1]module_file_writer.Record_Description{{name = "Labelled", size = 8, fields = labelled_fields[:]}}
	labelled_size, labelled_refusal := module_file_writer.write({records = labelled_records[:]}, fake.labelled_description[:])
	assert(labelled_refusal.refusal == .None)
	fake.labelled_file = fake.labelled_description[:labelled_size]

	for value, index in ([4]i64{1, 2, 30, 4}) {
		module.field_integer_set(fake.rect[:], {offset = u32(index * 8), type = u8(module.Type.Integer), detail = 8}, value)
	}
	copy(fake.labelled[0:], "ab")
	module.field_integer_set(fake.labelled[:], {offset = 4, type = u8(module.Type.Integer), detail = 1}, 5)
}

// The condition of the fake forces its value, as the console does for a
// field that is no status.
@(private = "file")
fake_condition_value :: proc "contextless" (data: rawptr, evaluation: ^Evaluation, command_name: string, before: []Host_Value, node: lex_parser.Node_Index) -> (value: Host_Value, ok: bool) {
	return force(evaluation, lex_parser.node_child(evaluation.tree, node))
}

@(private = "file")
fake_fact_name_value :: proc "contextless" (data: rawptr, evaluation: ^Evaluation, command_name: string, node: lex_parser.Node_Index) -> (value: Host_Value, ok: bool) {
	return {kind = .Text, text = lex_parser.node_text(evaluation.tree, node)}, true
}

// "+" of the fake: two Texts join; two Tables join their rows when their
// records are one, as the console's table sum, and are refused else.
@(private = "file")
fake_values_add :: proc "contextless" (data: rawptr, left, right: Host_Value) -> (sum: Host_Value, ok: bool) {
	fake := (^Fake)(data)
	if left.kind == .Table && left.detail != right.detail {
		return {}, false
	}
	first, second := left.text, right.text
	if left.kind == .Table {
		first, second = string(left.record), string(right.record)
	}
	start := fake.join_count
	fake.join_count += copy(fake.join[fake.join_count:], first)
	fake.join_count += copy(fake.join[fake.join_count:], second)
	joined := fake.join[start:fake.join_count]
	if left.kind == .Table {
		return {kind = .Table, record = joined, detail = left.detail}, true
	}
	return {kind = .Text, text = string(joined)}, true
}

@(private = "file")
test_form_of :: proc "contextless" (data: rawptr, command_name: string, index: int) -> lex_parser.Parameter_Form {
	switch {
	case command_name == "where" && index == 1:
		return .Condition
	case command_name == "facts" && index == 1:
		return .Fact_Name
	case command_name == "columns" && index == 1:
		return .Field_Names
	}
	return .Expression
}

// One evaluation of a text, with its tree, its host and its result.
@(private = "file")
Run :: struct {
	buffers:      lex_parser.Console_Tree_Buffers,
	eval_buffers: Console_Eval_Buffers,
	tree:         lex_parser.Syntax_Tree,
	evaluation:   Evaluation,
	fake:         Fake,
	value:        Host_Value,
	ok:           bool,
}

// The stack bound of the evaluations of the tests: a host test builds with
// no optimisation, whose frames are three to five times those of a module;
// the deepest line of 200 bytes takes 1.2 MiB of them. The thread of a test
// has the stack limit of the process, which a test checks to hold twice
// this bound.
@(private = "file")
TEST_STACK_BYTES :: 2 * 1024 * 1024

// The thread of a test holds the stack bound of the tests twice: the
// runner makes each thread with the stack limit of the process.
@(test)
the_thread_of_a_test_holds_the_stack_bound :: proc(t: ^testing.T) {
	limit: posix.rlimit
	testing.expect(t, posix.getrlimit(.STACK, &limit) == .OK)
	testing.expectf(t, limit.rlim_cur == posix.RLIM_INFINITY || u64(limit.rlim_cur) >= 2 * TEST_STACK_BYTES, "the stack limit %d holds less than twice %d bytes", limit.rlim_cur, TEST_STACK_BYTES)
}

@(private = "file")
run_of :: proc(text: string, mode := Evaluation_Mode.Console, budget: u32 = EVALUATION_BUDGET_STEPS, stack_bytes: uint = TEST_STACK_BYTES, depth_limit: int = EVALUATION_DEPTH_LIMIT) -> ^Run {
	run := new(Run, context.temp_allocator)
	fake_records_make(&run.fake)
	fake_enums_make(&run.fake)
	lex_parser.parse_console(text, {form_of = test_form_of}, &run.buffers, &run.tree)
	host := Evaluation_Host {
		data            = &run.fake,
		name_value      = fake_name_value,
		command_find    = fake_command_find,
		call_run        = fake_call_run,
		condition_value = fake_condition_value,
		fact_name_value = fake_fact_name_value,
		values_add      = fake_values_add,
		record_memory   = fake_record_memory,
	}
	evaluation_start(&run.evaluation, &run.tree, mode, host, &run.eval_buffers, budget, stack_bytes, depth_limit)
	run.value, run.ok = line_force(&run.evaluation)
	return run
}

@(private = "file")
log_of :: proc(run: ^Run) -> []string {
	return run.fake.log[:min(run.fake.log_count, len(run.fake.log))]
}

@(private = "file")
expect_log :: proc(t: ^testing.T, run: ^Run, expected: []string, text: string, loc := #caller_location) {
	got := log_of(run)
	same := len(got) == len(expected)
	for index in 0 ..< min(len(got), len(expected)) {
		same = same && got[index] == expected[index]
	}
	testing.expectf(t, same, "%q: the effects ran as %v, not %v", text, got, expected, loc = loc)
}

// The budget: 0, one less than the steps of the line, the steps of the
// line. A refusal at the budget names the node that needed the step, and
// the effects before it ran, none after.
@(test)
evaluation_budget_at_its_bound :: proc(t: ^testing.T) {
	text := "f(g(), h())"
	run := run_of(text, budget = 0)
	testing.expect(t, !run.ok)
	testing.expect_value(t, run.evaluation.refusal.refusal, Refusal.Budget_Exceeded)
	testing.expect_value(t, run.evaluation.refusal.steps, u32(0))
	expect_log(t, run, {}, text)

	full := run_of(text)
	testing.expect(t, full.ok)
	expect_log(t, full, {"g", "h", "f"}, text)
	exact := full.evaluation.steps
	testing.expect(t, exact >= 3)

	run = run_of(text, budget = exact - 2)
	testing.expect(t, !run.ok)
	testing.expect_value(t, run.evaluation.refusal.refusal, Refusal.Budget_Exceeded)
	testing.expect(t, run.fake.log_count < 3)

	run = run_of(text, budget = exact - 1)
	testing.expect(t, !run.ok)
	testing.expect_value(t, run.evaluation.refusal.refusal, Refusal.Budget_Exceeded)

	run = run_of(text, budget = exact)
	testing.expect(t, run.ok)
	testing.expect_value(t, run.evaluation.steps, exact)
	expect_log(t, run, {"g", "h", "f"}, text)

	// The densest line of the console stays far below the constant.
	densest := strings.concatenate({strings.repeat("1+", 99, context.temp_allocator), "1"}, context.temp_allocator)
	run = run_of(densest)
	testing.expect_value(t, run.evaluation.refusal.refusal, Refusal.None)
	testing.expect(t, run.ok)
	testing.expect_value(t, run.value.integer, i64(100))
	testing.expect(t, run.evaluation.steps < EVALUATION_BUDGET_STEPS)
}

// Mode declaration refuses a call of a command with an effect at its
// border: nothing of the call is forced, and nothing runs. A command with
// no effect runs, and a name that no command has is the refusal of the
// host first.
@(test)
evaluation_declaration_refuses_an_effect :: proc(t: ^testing.T) {
	run := run_of("f(g())", .Declaration)
	testing.expect(t, !run.ok)
	testing.expect_value(t, run.evaluation.refusal.refusal, Refusal.Effect_Refused)
	testing.expect_value(t, run.evaluation.refusal.command, "f")
	testing.expect_value(t, run.evaluation.refusal.place.column, u32(1))
	testing.expect_value(t, run.evaluation.steps, u32(1))
	expect_log(t, run, {}, "f(g())")

	run = run_of("pure(1, f())", .Declaration)
	testing.expect_value(t, run.evaluation.refusal.refusal, Refusal.Effect_Refused)
	testing.expect_value(t, run.evaluation.refusal.command, "f")
	testing.expect_value(t, run.evaluation.refusal.place.column, u32(9))
	expect_log(t, run, {}, "pure(1, f())")

	run = run_of("missing(f())", .Declaration)
	testing.expect_value(t, run.evaluation.refusal.refusal, Refusal.Host_Refused)
	expect_log(t, run, {}, "missing(f())")

	run = run_of("pure(1 + 2)", .Declaration)
	testing.expect(t, run.ok)
	expect_log(t, run, {"pure"}, "pure(1 + 2)")
}

// Each refusal of the evaluator: its record, its place, and the effects
// before it, none after.
@(test)
evaluation_refusals :: proc(t: ^testing.T) {
	LEAST :: "(0 - 9223372036854775807 - 1)"
	Case :: struct {
		text:       string,
		refusal:    Refusal,
		column:     u32,
		operator:   lex_parser.Operator,
		left_kind:  Kind,
		right_kind: Kind,
		effects:    []string,
	}
	cases := [?]Case {
		// Kinds that the operator does not take.
		{"\"a\" - 1", .Operator_Kinds, 5, .Subtract, .Text, .Integer, nil},
		{"1 + \"a\"", .Operator_Kinds, 3, .Add, .Integer, .Text, nil},
		{"\"a\" * \"b\"", .Operator_Kinds, 5, .Multiply, .Text, .Text, nil},
		{"\"a\" % 2", .Operator_Kinds, 5, .Remainder, .Text, .Integer, nil},
		{"f() + \"a\"", .Operator_Kinds, 5, .Add, .Integer, .Text, {"f"}},
		{"-\"a\"", .Negate_Kind, 1, .None, .Text, .None, nil},
		{"rows_a + 1", .Operator_Kinds, 8, .Add, .Table, .Integer, nil},
		{"rows_a - rows_b", .Operator_Kinds, 8, .Subtract, .Table, .Table, nil},
		{"\"a\" + rows_a", .Operator_Kinds, 5, .Add, .Text, .Table, nil},
		// Two Tables of two records: the host refuses their sum.
		{"rows_a + rows_other", .Host_Refused, 8, .None, .None, .None, nil},
		// Field names with a name missing, after the table ran.
		{"columns(f(), )", .Text, 14, .None, .None, .None, {"f"}},
		// Results that do not fit, and a division by zero.
		{"9223372036854775807 + 1", .Overflow, 21, .Add, .Integer, .Integer, nil},
		{"-9223372036854775807 - 2", .Overflow, 22, .Subtract, .Integer, .Integer, nil},
		{"3 * 4611686018427387904", .Overflow, 3, .Multiply, .Integer, .Integer, nil},
		{LEAST + " / -1", .Overflow, 31, .Divide, .Integer, .Integer, nil},
		{"-" + LEAST, .Overflow, 1, .Subtract, .None, .None, nil},
		{"1 / 0", .Division_By_Zero, 3, .Divide, .Integer, .Integer, nil},
		{"f() % 0", .Division_By_Zero, 5, .Remainder, .Integer, .Integer, {"f"}},
		// The host refuses: a name, a command, a call that fails mid-line.
		{"nosuch", .Host_Refused, 1, .None, .None, .None, nil},
		{"f(nosuch, g())", .Host_Refused, 3, .None, .None, .None, nil},
		{"missing(g())", .Host_Refused, 1, .None, .None, .None, nil},
		{"f(g(), fails(), h())", .Host_Refused, 8, .None, .None, .None, {"g", "fails"}},
		// A refusal of the text after effects.
		{"f(g(), 1 +", .Text, 11, .None, .None, .None, {"g"}},
		{"f(g()) 2", .Text, 8, .None, .None, .None, {"g", "f"}},
		{"(g() + 1", .Text, 9, .None, .None, .None, {"g"}},
	}
	for item in cases {
		run := run_of(item.text)
		record := run.evaluation.refusal
		testing.expectf(t, !run.ok && record.refusal == item.refusal && record.place.column == item.column, "%q: %v at column %d, not %v at column %d", item.text, record.refusal, record.place.column, item.refusal, item.column)
		if item.refusal == .Operator_Kinds || item.refusal == .Overflow || item.refusal == .Division_By_Zero {
			testing.expectf(t, record.operator == item.operator, "%q: the operator %v, not %v", item.text, record.operator, item.operator)
		}
		if item.refusal == .Operator_Kinds || item.refusal == .Negate_Kind {
			testing.expectf(t, record.left_kind == item.left_kind && (item.refusal == .Negate_Kind || record.right_kind == item.right_kind), "%q: the kinds %v and %v", item.text, record.left_kind, record.right_kind)
		}
		expect_log(t, run, item.effects, item.text)
	}

	run := run_of("9223372036854775807 + 1")
	testing.expect_value(t, run.evaluation.refusal.left, max(i64))
	testing.expect_value(t, run.evaluation.refusal.right, i64(1))
	run = run_of("-" + LEAST)
	testing.expect_value(t, run.evaluation.refusal.left, i64(0))
	testing.expect_value(t, run.evaluation.refusal.right, min(i64))
	run = run_of("f(g(), 1 +")
	testing.expect_value(t, run.evaluation.refusal.text_refusal, lex_parser.Refusal.Line_Ends_Too_Soon)
	run = run_of("columns(f(), )")
	testing.expect_value(t, run.evaluation.refusal.text_refusal, lex_parser.Refusal.Field_Name_Missing)
	testing.expect_value(t, run.evaluation.refusal.command, "columns")
	run = run_of("9223372036854775808")
	testing.expect_value(t, run.evaluation.refusal.text_refusal, lex_parser.Refusal.Number_Too_Large)
	testing.expect_value(t, lex_parser.node_text(&run.tree, run.evaluation.refusal.node), "9223372036854775808")
}

// A text past the bound of the parser forces nothing.
@(test)
evaluation_refuses_a_text_past_the_bound :: proc(t: ^testing.T) {
	long: [lex_parser.TEXT_BYTES_MOST + 1]u8
	count := 0
	for count + 4 <= len(long) {
		count += copy(long[count:], "f()+")
	}
	for count < len(long) {
		long[count] = '1'
		count += 1
	}
	run := run_of(string(long[:]))
	testing.expect(t, !run.ok)
	testing.expect_value(t, run.evaluation.refusal.refusal, Refusal.Text)
	testing.expect_value(t, run.evaluation.refusal.text_refusal, lex_parser.Refusal.Text_Too_Long)
	testing.expect_value(t, run.evaluation.steps, u32(0))
	testing.expect_value(t, run.fake.finds, 0)
	expect_log(t, run, {}, "a text past the bound")
}

// After the first refusal, a force gives nothing and runs nothing.
@(test)
evaluation_ends_at_its_first_refusal :: proc(t: ^testing.T) {
	run := run_of("f(g(), fails(), h())")
	steps := run.evaluation.steps
	_, ok := force(&run.evaluation, run.tree.root)
	testing.expect(t, !ok)
	_, ok = line_force(&run.evaluation)
	testing.expect(t, !ok)
	testing.expect_value(t, run.evaluation.refusal.refusal, Refusal.Host_Refused)
	testing.expect_value(t, run.evaluation.steps, steps)
	expect_log(t, run, {"g", "fails"}, "a force after a refusal")
}

// An effect runs once: a second force of a forced line gives the kept
// value, takes no step and calls no host.
@(test)
evaluation_forces_a_thunk_once :: proc(t: ^testing.T) {
	run := run_of("f(g())")
	testing.expect(t, run.ok)
	expect_log(t, run, {"g", "f"}, "f(g())")
	steps, finds := run.evaluation.steps, run.fake.finds
	for _ in 0 ..< 3 {
		value, ok := line_force(&run.evaluation)
		testing.expect(t, ok)
		testing.expect_value(t, value.integer, i64(2))
	}
	testing.expect_value(t, run.evaluation.steps, steps)
	testing.expect_value(t, run.fake.finds, finds)
	expect_log(t, run, {"g", "f"}, "f(g()) forced again")

	// A start forgets the thunks of the evaluation before.
	evaluation_start(&run.evaluation, &run.tree, .Console, run.evaluation.host, &run.eval_buffers)
	_, ok := line_force(&run.evaluation)
	testing.expect(t, ok)
	expect_log(t, run, {"g", "f", "g", "f"}, "f(g()) evaluated again")
}

// The order of the effects: the order of the data, in a nested call, with
// "|>", with an assignment, through a condition.
@(test)
evaluation_runs_the_effects_in_the_order_of_the_data :: proc(t: ^testing.T) {
	run := run_of("f(g(h()), k())")
	testing.expect(t, run.ok)
	expect_log(t, run, {"h", "g", "k", "f"}, "f(g(h()), k())")
	testing.expect_value(t, run.value.integer, i64(4))

	piped := "h() |> g() |> f(k())"
	run = run_of(piped)
	testing.expect(t, run.ok)
	expect_log(t, run, {"h", "g", "k", "f"}, piped)

	run = run_of("t = f(g(), h())")
	testing.expect(t, run.ok)
	testing.expect_value(t, run.tree.assigned_name, "t")
	expect_log(t, run, {"g", "h", "f"}, "t = f(g(), h())")

	run = run_of("where(f(), a = g())")
	testing.expect(t, run.ok)
	expect_log(t, run, {"f", "g", "where"}, "where(f(), a = g())")

	run = run_of("g() + h() * k()")
	testing.expect(t, run.ok)
	expect_log(t, run, {"g", "h", "k"}, "g() + h() * k()")
	testing.expect_value(t, run.value.integer, i64(1 + 2 * 3))
}

// The values of each form of a line.
@(test)
evaluation_values :: proc(t: ^testing.T) {
	Case :: struct {
		text:    string,
		integer: i64,
	}
	cases := [?]Case {
		{"42", 42},
		{"1 + 2 * 3", 7},
		{"(1 + 2) * 3", 9},
		{"1 - 2 - 3", -4},
		{"7 / 2", 3},
		{"-7 / 2", -3},
		{"7 % 3", 1},
		{"-7 % 3", -1},
		{"7 % -1", 0},
		{"(0 - 9223372036854775807 - 1) % -1", 0},
		{"(0 - 9223372036854775807 - 1) / 1", min(i64)},
		{"-x", -7},
		{"x * x", 49},
		{"9223372036854775807", max(i64)},
	}
	for item in cases {
		run := run_of(item.text)
		testing.expectf(t, run.ok && run.value.kind == .Integer && run.value.integer == item.integer, "%q: %v %v %d, not %d", item.text, run.ok, run.value.kind, run.value.integer, item.integer)
	}

	run := run_of("\"a\" + \"b\" + t")
	testing.expect(t, run.ok)
	testing.expect_value(t, run.value.kind, Kind.Text)
	testing.expect_value(t, run.value.text, "abtee")
	run = run_of("\"\"")
	testing.expect_value(t, run.value.text, "")
	run = run_of("facts(f(), storage.Bad_Block)")
	testing.expect(t, run.ok)
	expect_log(t, run, {"f", "facts"}, "facts(f(), storage.Bad_Block)")
	run = run_of("pure()")
	testing.expect(t, run.ok)
	testing.expect_value(t, run.value.integer, i64(1))

	// "+" of two Tables of one record: the rows of both, from the host.
	run = run_of("rows_a + rows_b")
	testing.expect(t, run.ok)
	testing.expect_value(t, run.value.kind, Kind.Table)
	testing.expect_value(t, string(run.value.record), "abcd")

	// Field names: one argument, a Text with the names as the line has
	// them, after the table ran.
	run = run_of("columns(f(), name, slot)")
	testing.expect(t, run.ok)
	expect_log(t, run, {"f", "columns"}, "columns(f(), name, slot)")
	testing.expect_value(t, run.fake.last_text, "name, slot")
}

// Each refusal of the forms of records, at its place, with its record, and
// the effects before it: the names of a literal and of the named arguments
// are checked when their call starts, before its arguments run; the kinds
// of the values when they are known, before the call runs.
@(test)
evaluation_refusals_of_the_forms :: proc(t: ^testing.T) {
	Case :: struct {
		text:       string,
		refusal:    Refusal,
		column:     u32,
		field:      string,
		left_kind:  Kind,
		right_kind: Kind,
		effects:    []string,
	}
	cases := [?]Case {
		// A literal against its record: an unknown field, a missing one,
		// before any argument runs.
		{"area({x = 1, y = 2, widht = 3, height = 4})", .Literal_Field_Unknown, 21, "widht", .None, .None, nil},
		{"area({x = g(), y = 0, widht = 1, height = 1})", .Literal_Field_Unknown, 23, "widht", .None, .None, nil},
		{"area({x = 1, y = 2, width = 3})", .Literal_Field_Missing, 6, "height", .None, .None, nil},
		{"area({})", .Literal_Field_Missing, 6, "x", .None, .None, nil},
		{"grow(rectangle = {x = 1}, by = g())", .Literal_Field_Missing, 18, "y", .None, .None, nil},
		// The kind and the range of a value, after the values ran.
		{"area({x = \"a\", y = 2, width = 3, height = 4})", .Literal_Field_Kind, 7, "x", .Text, .None, nil},
		{"area({x = g(), y = \"b\", width = 3, height = 4})", .Literal_Field_Kind, 16, "y", .Text, .None, {"g"}},
		{"area({x = {a = 1}, y = 0, width = 1, height = 1})", .Literal_Field_Kind, 7, "x", .Record_Literal, .None, nil},
		{"label({name = \"abcde\", count = 1})", .Literal_Field_Range, 8, "name", .Text, .None, nil},
		{"label({name = \"ab\", count = 128})", .Literal_Field_Range, 21, "count", .Integer, .None, nil},
		{"label({name = \"ab\", count = -129})", .Literal_Field_Range, 21, "count", .Integer, .None, nil},
		// A literal that nothing types.
		{"{a = 1}", .Literal_No_Type, 1, "", .None, .None, nil},
		{"r = {a = 1}", .Literal_No_Type, 5, "", .None, .None, nil},
		{"pair({a = 1}, g())", .Literal_No_Type, 6, "", .None, .Integer, nil},
		{"any({a = 1})", .Literal_No_Type, 5, "", .None, .None, nil},
		{"f({a = 1})", .Literal_No_Type, 3, "", .None, .None, nil},
		{"let s = {x = 1} in pair(s, 2)", .Literal_No_Type, 25, "", .None, .Integer, nil},
		{"{a = 1} + 1", .Operator_Kinds, 9, "", .Record_Literal, .Integer, nil},
		// Named arguments: an unknown name, a parameter twice, a missing
		// one, a command with no names; before any argument runs.
		{"pair(first = 1, third = 2)", .Argument_Unknown, 17, "third", .None, .None, nil},
		{"pair(g(), third = 2)", .Argument_Unknown, 11, "third", .None, .None, nil},
		{"pair(1, first = 2)", .Argument_Twice, 9, "first", .None, .None, nil},
		{"pair(second = g())", .Argument_Missing, 1, "first", .None, .None, nil},
		{"f(by = 1)", .Argument_Unknown, 3, "by", .None, .None, nil},
		// with: on two records only, of one description.
		{"1 with {a = 1}", .With_Kinds, 3, "", .Integer, .Record_Literal, nil},
		{"rect with 1", .With_Kinds, 6, "", .Record, .Integer, nil},
		{"{a = 1} with {a = 2}", .With_Kinds, 9, "", .Record_Literal, .Record_Literal, nil},
		{"rect with labelled", .With_Records_Differ, 6, "", .None, .None, nil},
		{"rect with {widht = 1}", .Literal_Field_Unknown, 12, "widht", .None, .None, nil},
		{"g() with {width = 1}", .With_Kinds, 5, "", .Integer, .Record_Literal, {"g"}},
		// let: a cycle at the name that closes it, a field that the value
		// does not have.
		{"let a = a + 1 in a", .Cycle, 9, "", .None, .None, nil},
		{"let a = b, b = a in a", .Cycle, 16, "", .None, .None, nil},
		{"let s = rect in s.z", .Field_Unknown, 17, "z", .Record, .None, nil},
		{"let s = {x = 1} in s.y", .Field_Unknown, 20, "y", .Record_Literal, .None, nil},
		{"let n = g() in n.x", .Field_Unknown, 16, "x", .Integer, .None, {"g"}},
	}
	for item in cases {
		run := run_of(item.text)
		record := run.evaluation.refusal
		testing.expectf(t, !run.ok && record.refusal == item.refusal && record.place.column == item.column && record.field == item.field, "%q: %v at column %d, field %q; not %v at column %d, field %q", item.text, record.refusal, record.place.column, record.field, item.refusal, item.column, item.field)
		if item.left_kind != .None || item.right_kind != .None {
			testing.expectf(t, record.left_kind == item.left_kind && record.right_kind == item.right_kind, "%q: the kinds %v and %v, not %v and %v", item.text, record.left_kind, record.right_kind, item.left_kind, item.right_kind)
		}
		expect_log(t, run, item.effects, item.text)
	}

	// The values of the records: the command, the parameter, the record.
	run := run_of("pair({a = 1}, 2)")
	testing.expect_value(t, run.evaluation.refusal.command, "pair")
	testing.expect_value(t, run.evaluation.refusal.parameter, 1)
	run = run_of("area({x = 1, y = 2, widht = 3, height = 4})")
	testing.expect(t, raw_data(run.evaluation.refusal.file) == raw_data(run.fake.rectangle_file))
	testing.expect_value(t, run.evaluation.refusal.detail, u32(1))
	run = run_of("label({name = \"ab\", count = 128})")
	testing.expect_value(t, run.evaluation.refusal.left, i64(128))
	run = run_of("label({name = \"abcde\", count = 1})")
	testing.expect_value(t, run.evaluation.refusal.right, i64(5))
	run = run_of("rect with labelled")
	testing.expect(t, raw_data(run.evaluation.refusal.other_file) == raw_data(run.fake.labelled_file))
	run = run_of("let a = a + 1 in a")
	testing.expect_value(t, run.evaluation.refusal.command, "a")
	run = run_of("pair(second = g())")
	testing.expect_value(t, run.evaluation.refusal.command, "pair")
	// A placeholder outside a pipe is a refusal of the text.
	run = run_of("pair(_, 1)")
	testing.expect_value(t, run.evaluation.refusal.refusal, Refusal.Text)
	testing.expect_value(t, run.evaluation.refusal.text_refusal, lex_parser.Refusal.Placeholder_Without_Pipe)
}

// A member is refused at its place before any argument of the call runs: a
// name that its enum does not have, a member of another enum, a parameter
// that is no Enum, a member that nothing types, a member in an operation,
// a parameter named twice. The successes come last: a member by its name or
// by its place, and an optional parameter left out.
@(test)
evaluation_of_members :: proc(t: ^testing.T) {
	Case :: struct {
		text:       string,
		refusal:    Refusal,
		column:     u32,
		field:      string,
		left_kind:  Kind,
		right_kind: Kind,
	}
	cases := [?]Case {
		{"set(layout = .germany)", .Member_Unknown, 14, "germany", .None, .None},
		{"set(font = g(), layout = .germany)", .Member_Unknown, 26, "germany", .None, .None},
		{"set(layout = .spleen)", .Member_Unknown, 14, "spleen", .None, .None},
		{"set(.french, .french)", .Member_Unknown, 14, "french", .None, .None},
		{"set(layout = .French)", .Member_Unknown, 14, "French", .None, .None},
		{"set(layout = .french_)", .Member_Unknown, 14, "french_", .None, .None},
		// A display text is no name of a member: "US" shows for
		// .united_states, and a line cannot type it.
		{"set(layout = .US)", .Member_Unknown, 14, "US", .None, .None},
		{"set(layout = .us)", .Member_Unknown, 14, "us", .None, .None},
		{"pair(.french, g())", .Member_No_Type, 6, "", .None, .Integer},
		{"any(.french)", .Member_No_Type, 5, "", .None, .None},
		{"f(.french)", .Member_No_Type, 3, "", .None, .None},
		{".french", .Member_No_Type, 1, "", .None, .None},
		{"v = .french", .Member_No_Type, 5, "", .None, .None},
		{".french + 1", .Operator_Kinds, 9, "", .Member, .Integer},
		{"set(layout = .french, layout = .french)", .Text, 23, "", .None, .None},
		{"set(.french, layout = .french)", .Argument_Twice, 14, "layout", .None, .None},
		{"set(layout = .)", .Text, 14, "", .None, .None},
	}
	for item in cases {
		run := run_of(item.text)
		record := run.evaluation.refusal
		testing.expectf(t, !run.ok && record.refusal == item.refusal && record.place.column == item.column && record.field == item.field, "%q: %v at column %d, field %q; not %v at column %d, field %q", item.text, record.refusal, record.place.column, record.field, item.refusal, item.column, item.field)
		if item.left_kind != .None || item.right_kind != .None {
			testing.expectf(t, record.left_kind == item.left_kind && record.right_kind == item.right_kind, "%q: the kinds %v and %v, not %v and %v", item.text, record.left_kind, record.right_kind, item.left_kind, item.right_kind)
		}
		// No argument runs before the check of a member, and no call.
		if item.refusal == .Member_Unknown || item.refusal == .Member_No_Type && item.text != ".french + 1" {
			expect_log(t, run, {}, item.text)
		}
	}
	run := run_of("set(layout = .germany)")
	testing.expect(t, run.evaluation.refusal.detail == 1 && raw_data(run.evaluation.refusal.file) == raw_data(run.fake.enum_file) && run.evaluation.refusal.command == "set" && run.evaluation.refusal.parameter == 1)

	Value_Case :: struct {
		text:    string,
		integer: i64,
	}
	values := [?]Value_Case {
		{"set(layout = .french)", 19},
		{"set(font = .spleen)", 91},
		{"set(font = .vector, layout = .united_states)", 0},
		{"set(.french)", 19},
		{"set(.united_states, .spleen)", 1},
		{"set()", 99},
		{"set(.french, font = .spleen)", 11},
		{"let l = .french in set(layout = l)", 19},
	}
	for item in values {
		value_run := run_of(item.text)
		testing.expectf(t, value_run.ok && value_run.value.integer == item.integer, "%q: %v %d, not %d (%v)", item.text, value_run.ok, value_run.value.integer, item.integer, value_run.evaluation.refusal.refusal)
	}
}

// The order of the effects with the forms of records: the bindings of a
// let from the left, in mode console, even when the body reads none of
// them; the values of named arguments in the order of the line; the
// placeholder, whose value runs where the call reads it.
@(test)
evaluation_order_of_the_forms :: proc(t: ^testing.T) {
	run := run_of("let a = g(), b = h() in pair(b, a)")
	testing.expect(t, run.ok)
	expect_log(t, run, {"g", "h", "pair"}, "let a = g(), b = h() in pair(b, a)")
	testing.expect_value(t, run.value.integer, i64(21))

	run = run_of("let a = g() in 1")
	testing.expect(t, run.ok)
	expect_log(t, run, {"g"}, "let a = g() in 1, mode console")
	run = run_of("let a = g() in 1", .Declaration)
	testing.expect(t, run.ok)
	testing.expect_value(t, run.value.integer, i64(1))
	expect_log(t, run, {}, "let a = g() in 1, mode declaration")

	// An effect runs once, though its value is read twice.
	run = run_of("let v = g() in pair(v, v)")
	testing.expect(t, run.ok)
	expect_log(t, run, {"g", "pair"}, "let v = g() in pair(v, v)")
	testing.expect_value(t, run.value.integer, i64(11))

	run = run_of("pair(second = h(), first = g())")
	testing.expect(t, run.ok)
	expect_log(t, run, {"h", "g", "pair"}, "pair(second = h(), first = g())")
	testing.expect_value(t, run.value.integer, i64(21))

	// `_` and the order of the effects: the value on the left runs where
	// the call reads it, after the arguments before the '_'.
	Piped :: struct {
		text:    string,
		effects: []string,
	}
	piped := [?]Piped {
		{"g() |> pair(h(), _)", {"h", "g", "pair"}},
		{"g() |> pair(_, h())", {"g", "h", "pair"}},
		{"g() |> pair(second = _, first = h())", {"g", "h", "pair"}},
	}
	for item in piped {
		run = run_of(item.text)
		testing.expectf(t, run.ok, "%q: %v", item.text, run.evaluation.refusal.refusal)
		expect_log(t, run, item.effects, item.text)
	}
}

// The values of the forms of records.
@(test)
evaluation_values_of_the_forms :: proc(t: ^testing.T) {
	Case :: struct {
		text:    string,
		integer: i64,
	}
	cases := [?]Case {
		// Literals typed by the parameter, in any order of their fields.
		{"area({x = 1, y = 2, width = 30, height = 4})", 120},
		{"area({height = 4, width = 30, y = 0, x = 0})", 120},
		{"label({name = \"abcd\", count = -128})", -128},
		{"label({name = \"\", count = 127})", 127},
		// with: some fields of a whole record, or a record of one
		// description.
		{"area(rect)", 120},
		{"area(rect with {width = 10})", 40},
		{"area(rect with {width = 10} with {height = 5})", 50},
		{"area(rect with rect)", 120},
		// Named arguments, and the last parameter that a call may leave out.
		{"pair(second = 2, first = 1)", 12},
		{"pair(1, second = 2)", 12},
		{"grow(rect)", 1},
		{"grow(rectangle = rect)", 1},
		{"grow(by = 2, rectangle = rect)", 2},
		{"grow(rectangle = {x = 0, y = 0, width = 1, height = 1}, by = 2)", 2},
		// let, a later binding, a literal that two receivers type, a field
		// of a binding.
		{"let a = 1, b = a + 1 in a * 10 + b", 12},
		{"let a = b + 1, b = 2 in a", 3},
		{"let s = {x = 0, y = 0, width = 6, height = 7} in area(s) + area(s)", 84},
		{"let s = rect in s.width", 30},
		{"let s = {x = 5} in s.x", 5},
		{"area(let w = 3 in {x = 0, y = 0, width = w, height = w})", 9},
		{"let a = 1 in let a = 2 in a", 2},
	}
	for item in cases {
		run := run_of(item.text)
		testing.expectf(t, run.ok && run.value.kind == .Integer && run.value.integer == item.integer, "%q: %v %v %d, not %d (%v)", item.text, run.ok, run.value.kind, run.value.integer, item.integer, run.evaluation.refusal.refusal)
	}

	// A record that `with` gives keeps the fields that it does not name,
	// and the record of the variable stays as it was.
	run := run_of("rect with {width = 10}")
	testing.expect(t, run.ok)
	testing.expect_value(t, run.value.kind, Kind.Record)
	width, _ := record_field_value(run.value, "width")
	x, _ := record_field_value(run.value, "x")
	testing.expect_value(t, width.integer, i64(10))
	testing.expect_value(t, x.integer, i64(1))
	original, _ := record_field_value({kind = .Record, record = run.fake.rect[:], file = run.fake.rectangle_file, detail = 1}, "width")
	testing.expect_value(t, original.integer, i64(30))
	// A text of a literal is written whole, with zero bytes after it.
	run = run_of("label({name = \"ab\", count = 1}) + 0")
	testing.expect(t, run.ok)
}

// items_of gives the Integers of a List value, or nil for another value.
@(private = "file")
items_of :: proc(run: ^Run, value: Host_Value) -> []i64 {
	if value.kind != .List {
		return nil
	}
	vm_val := value.vm_value.kind == .List ? value.vm_value : Value{kind = .List, data = u64(value.integer), meta = value.detail}
	items := make([dynamic]i64, context.temp_allocator)
	for item in list_items_of(&run.evaluation, vm_val) {
		append(&items, value_integer(item))
	}
	return items[:]
}

// Each refusal of the functions and the lists, at its place, with its
// record, and the effects that ran before it: the count of the arguments
// before any argument runs, a value that is no function, a function or a
// list at the border of the host, a literal that nothing types, the bounds.
@(test)
evaluation_refusals_of_functions :: proc(t: ^testing.T) {
	Case :: struct {
		text:      string,
		refusal:   Refusal,
		column:    u32,
		left_kind: Kind,
		effects:   []string,
	}
	cases := [?]Case {
		// A wrong count of arguments, before any argument runs.
		{"let f = (x) => x in f(1, 2)", .Function_Arguments, 21, .None, nil},
		{"let f = (x, y) => x in f(g())", .Function_Arguments, 24, .None, nil},
		{"let f = () => 1 in f(g())", .Function_Arguments, 20, .None, nil},
		{"let f = (x) => x in f()", .Function_Arguments, 21, .None, nil},
		{"map([1])", .Function_Arguments, 1, .None, nil},
		{"map([g()], (x, y) => x)", .Function_Arguments, 1, .None, {"g"}},
		{"map([g()], () => 1)", .Function_Arguments, 1, .None, {"g"}},
		// Named arguments of a function: an unknown name, a missing one.
		{"let f = (a, b) => a in f(c = g(), a = 1)", .Argument_Unknown, 26, .None, nil},
		{"let f = (a, b) => a in f(b = g())", .Argument_Missing, 24, .None, nil},
		// A call of a value that is no function.
		{"let f = 1 in f(2)", .Not_A_Function, 14, .Integer, nil},
		{"let f = g() in f(2)", .Not_A_Function, 16, .Integer, {"g"}},
		{"let f = {a = 1} in f(2)", .Not_A_Function, 20, .Record_Literal, nil},
		{"let a = (f) => f(1) in a(2)", .Not_A_Function, 16, .Integer, nil},
		{"let a = (f) => f(1) in a([1])", .Not_A_Function, 16, .List, nil},
		{"map([1], g())", .Not_A_Function, 1, .Integer, {"g"}},
		{"map(g(), (x) => x)", .Not_A_List, 1, .Integer, {"g"}},
		{"map((x) => x, [1])", .Not_A_List, 1, .Function, nil},
		// A function or a list given to a command of the host: refused
		// after the arguments before it ran, before the call runs.
		{"pair((x) => x, 1)", .Value_At_Border, 10, .Function, nil},
		{"pair(g(), [h()])", .Value_At_Border, 11, .List, {"g", "h"}},
		{"any([])", .Value_At_Border, 5, .List, nil},
		{"any(map([1], (x) => x))", .Value_At_Border, 5, .List, nil},
		{"let f = (x) => x in any(f)", .Value_At_Border, 25, .Function, nil},
		{"let f = (x) => pair(x, 1) in f((y) => y)", .Value_At_Border, 21, .Function, nil},
		// A field of a function or of a list, `with`, an operator.
		{"let f = (x) => x in f.a", .Field_Unknown, 21, .Function, nil},
		{"let l = [1] in l.a", .Field_Unknown, 16, .List, nil},
		{"rect with (x) => x", .With_Kinds, 6, .Record, nil},
		{"[1] + [2]", .Operator_Kinds, 5, .List, nil},
		{"-((x) => x)", .Negate_Kind, 1, .Function, nil},
		// A literal or a member that nothing types, as the value of the
		// line, also as an item of a list, also made in a call.
		{"[{a = 1}]", .Literal_No_Type, 2, .None, nil},
		{"[1, [.french]]", .Member_No_Type, 6, .None, nil},
		{"map([1], (x) => {a = x})", .Literal_No_Type, 17, .None, nil},
		// The refusals of the text in a function stop the line where the
		// function is reached, though its body never runs.
		{"(x, x) => 1", .Text, 5, .None, nil},
		{"let f = (in) => 1 in 2", .Text, 10, .None, nil},
		{"pair(g(), (x) => 1 +", .Text, 21, .None, {"g"}},
	}
	for item in cases {
		run := run_of(item.text)
		record := run.evaluation.refusal
		testing.expectf(t, !run.ok && record.refusal == item.refusal && record.place.column == item.column, "%q: %v at column %d; not %v at column %d", item.text, record.refusal, record.place.column, item.refusal, item.column)
		if item.left_kind != .None {
			testing.expectf(t, record.left_kind == item.left_kind, "%q: the kind %v, not %v", item.text, record.left_kind, item.left_kind)
		}
		expect_log(t, run, item.effects, item.text)
	}

	// The values of the records.
	run := run_of("let f = (x) => x in f(1, 2)")
	testing.expect_value(t, run.evaluation.refusal.command, "f")
	testing.expect_value(t, run.evaluation.refusal.left, i64(2))
	testing.expect_value(t, run.evaluation.refusal.right, i64(1))
	run = run_of("map([1], (x, y) => x)")
	testing.expect_value(t, run.evaluation.refusal.parameter, 2)
	testing.expect_value(t, run.evaluation.refusal.right, i64(2))
	run = run_of("pair(1, (x) => x)")
	testing.expect_value(t, run.evaluation.refusal.command, "pair")
	testing.expect_value(t, run.evaluation.refusal.parameter, 2)
	run = run_of("map([1], 2)")
	testing.expect_value(t, run.evaluation.refusal.parameter, 2)
	run = run_of("(x, x) => 1")
	testing.expect_value(t, run.evaluation.refusal.text_refusal, lex_parser.Refusal.Parameter_Twice)
	run = run_of("let f = (in) => 1 in 2")
	testing.expect_value(t, run.evaluation.refusal.text_refusal, lex_parser.Refusal.Word_As_Name)

	// The bounds of a recursion: tail recursion runs in O(1) stack until the
	// step budget; non-tail recursion hits the VM frame depth bound.
	recursion := "let f = (n) => f(n) in f(1)"
	run = run_of(recursion, budget = 40)
	testing.expect_value(t, run.evaluation.refusal.refusal, Refusal.Budget_Exceeded)
	testing.expect_value(t, run.evaluation.steps, u32(40))

	nontail := "let f = (n) => 1 + f(n) in f(1)"
	run = run_of(nontail, depth_limit = 24)
	testing.expect_value(t, run.evaluation.refusal.refusal, Refusal.Depth_Exceeded)

	// The effects of a recursion ran before its bound, once for each call.
	stack_recursion := "let f = (n) => f(g()) in f(1)"
	run = run_of(stack_recursion, budget = 80)
	testing.expect_value(t, run.evaluation.refusal.refusal, Refusal.Budget_Exceeded)
	testing.expect(t, run.fake.log_count > 2)

	// The items of all the lists of a line: 1000, then 1000 for each map;
	// the fourth map passes LIST_ITEM_CAPACITY before it calls the
	// function.
	ITEMS :: 1000
	#assert(4 * ITEMS <= LIST_ITEM_CAPACITY && 5 * ITEMS > LIST_ITEM_CAPACITY)
	items := strings.repeat("1,", ITEMS - 1, context.temp_allocator)
	lists := strings.concatenate({"let f = (x) => x, l = [", items, "1] in map(map(map(map(l, f), f), f), f)"}, context.temp_allocator)
	testing.expect(t, len(lists) <= lex_parser.TEXT_BYTES_MOST)
	run = run_of(lists)
	testing.expect_value(t, run.evaluation.refusal.refusal, Refusal.Lists_Full)
	testing.expect_value(t, run.evaluation.refusal.place.column, u32(strings.index(lists, "map(") + 1))
	testing.expect_value(t, run.evaluation.call_count, 3 * ITEMS)
	// The edges of the items: a quarter of the capacity, then as many for
	// each map, is the capacity and holds; one more item, a list around
	// them, passes it at the third map.
	QUARTER :: LIST_ITEM_CAPACITY / 4
	items = strings.repeat("1,", QUARTER - 1, context.temp_allocator)
	whole := strings.concatenate({"let f = (x) => x, l = [", items, "1] in map(map(map(l, f), f), f)"}, context.temp_allocator)
	run = run_of(whole)
	testing.expect(t, run.ok)
	testing.expect_value(t, run.evaluation.list_item_count, LIST_ITEM_CAPACITY)
	testing.expect_value(t, run.value.detail, u32(QUARTER))
	one_more := strings.concatenate({"let f = (x) => x, l = [", items, "1] in [map(map(map(l, f), f), f)]"}, context.temp_allocator)
	testing.expect(t, len(one_more) <= lex_parser.TEXT_BYTES_MOST)
	run = run_of(one_more)
	testing.expect_value(t, run.evaluation.refusal.refusal, Refusal.Lists_Full)
	testing.expect_value(t, run.evaluation.refusal.place.column, u32(strings.index(one_more, "[map(") + 1))
}

// A refusal of the text in the arguments of a call of a function or of map
// comes at its place, after the arguments before it ran, as for a command
// of the host: the count of the arguments is not known.
@(test)
evaluation_refused_argument_of_a_function :: proc(t: ^testing.T) {
	Case :: struct {
		text:         string,
		text_refusal: lex_parser.Refusal,
		column:       u32,
	}
	cases := [?]Case {
		{"pair(g(), ", .Line_Ends_Too_Soon, 11},
		{"let f = (a, b) => a in f(g(), ", .Line_Ends_Too_Soon, 31},
		{"let f = (a, b) => a in f(a = g(), ", .Positional_After_Named, 35},
		{"map([1], g(), ", .Line_Ends_Too_Soon, 15},
		{"map(g(), ", .Line_Ends_Too_Soon, 10},
	}
	for item in cases {
		run := run_of(item.text)
		record := run.evaluation.refusal
		testing.expectf(t, record.refusal == .Text && record.text_refusal == item.text_refusal && record.place.column == item.column, "%q: %v %v at column %d, not %v at column %d", item.text, record.refusal, record.text_refusal, record.place.column, item.text_refusal, item.column)
		expect_log(t, run, {"g"}, item.text)
	}
}

// The hostile values in the bodies and the literals: a cycle inside a body,
// a function or a list as a field of a literal, a value with no item in a
// list.
@(test)
evaluation_hostile_values_of_functions :: proc(t: ^testing.T) {
	Case :: struct {
		text:      string,
		refusal:   Refusal,
		column:    u32,
		left_kind: Kind,
	}
	cases := [?]Case {
		{"let f = (a) => let b = b in b in f(1)", .Cycle, 24, .None},
		{"area({x = (y) => y, y = 0, width = 1, height = 1})", .Literal_Field_Kind, 7, .Function},
		{"area({x = [1], y = 0, width = 1, height = 1})", .Literal_Field_Kind, 7, .List},
		{"let mk = (w) => {x = [w], y = 0, width = 1, height = 1} in area(mk(1))", .Literal_Field_Kind, 18, .List},
	}
	for item in cases {
		run := run_of(item.text)
		record := run.evaluation.refusal
		testing.expectf(t, !run.ok && record.refusal == item.refusal && record.place.column == item.column, "%q: %v at column %d; not %v at column %d", item.text, record.refusal, record.place.column, item.refusal, item.column)
		if item.left_kind != .None {
			testing.expectf(t, record.left_kind == item.left_kind, "%q: the kind %v, not %v", item.text, record.left_kind, item.left_kind)
		}
	}
	run := run_of("let f = (a) => let b = b in b in f(1)")
	testing.expect_value(t, run.evaluation.refusal.command, "b")
}

// The order of the effects with functions, in mode console: the arguments
// of a call from the left, then the body; the items of map from the first;
// a binding that a body reads, once; a function that no call reaches, no
// effect. In mode declaration a function reads a binding by reference: a
// binding that the body does not read is never forced.
@(test)
evaluation_order_of_functions :: proc(t: ^testing.T) {
	Case :: struct {
		text:    string,
		effects: []string,
		integer: i64,
	}
	cases := [?]Case {
		{"let f = (x) => pair(x, h()) in f(g())", {"g", "h", "pair"}, 12},
		{"let f = (a, b) => pair(b, a) in f(g(), h())", {"g", "h", "pair"}, 21},
		{"let f = (a, b) => pair(a, b) in f(b = g(), a = h())", {"g", "h", "pair"}, 21},
		{"let n = g(), f = (x) => n in pair(f(1), f(2))", {"g", "pair"}, 11},
		{"let f = (x) => g() in 1", {}, 1},
		{"let f = (x) => let y = pair(x, x) in y + y in f(1) + f(2)", {"pair", "pair"}, 66},
	}
	for item in cases {
		run := run_of(item.text)
		testing.expectf(t, run.ok && run.value.integer == item.integer, "%q: %v %d, not %d (%v)", item.text, run.ok, run.value.integer, item.integer, run.evaluation.refusal.refusal)
		expect_log(t, run, item.effects, item.text)
	}

	// map calls its function on each item from the first.
	run := run_of("map([g(), h()], (x) => pair(x, x))")
	testing.expect(t, run.ok)
	expect_log(t, run, {"g", "h", "pair", "pair"}, "map with effects")
	testing.expect_value(t, len(items_of(run, run.value)), 2)
	if values := items_of(run, run.value); len(values) == 2 {
		testing.expect_value(t, values[0], i64(11))
		testing.expect_value(t, values[1], i64(22))
	}
	run = run_of("let n = g() in map([1, 2], (x) => n + x)")
	expect_log(t, run, {"g"}, "a binding that a body reads")
	if values := items_of(run, run.value); testing.expect_value(t, len(values), 2) {
		testing.expect_value(t, values[0], i64(2))
		testing.expect_value(t, values[1], i64(3))
	}

	// Mode declaration: the binding that the body does not read is never
	// forced, and its effect is never refused; the one that it reads is.
	run = run_of("let n = g(), f = (x) => 1 in f(1)", .Declaration)
	testing.expect(t, run.ok)
	testing.expect_value(t, run.value.integer, i64(1))
	run = run_of("let n = g(), f = (x) => n in f(1)", .Declaration)
	testing.expect_value(t, run.evaluation.refusal.refusal, Refusal.Effect_Refused)
	testing.expect_value(t, run.evaluation.refusal.command, "g")
	run = run_of("map([1, 2], (x) => x * 2)", .Declaration)
	testing.expect(t, run.ok)
	run = run_of("map([1], (x) => g())", .Declaration)
	testing.expect_value(t, run.evaluation.refusal.refusal, Refusal.Effect_Refused)
	expect_log(t, run, {}, "an effect in a body, mode declaration")
}

// The values of functions and lists, last: the edges of the parameters,
// a literal made in a call and typed after it, a function that a call
// gives, a function as an argument, map on map.
@(test)
evaluation_values_of_functions :: proc(t: ^testing.T) {
	Case :: struct {
		text:    string,
		integer: i64,
	}
	cases := [?]Case {
		{"let f = () => 7 in f()", 7},
		{"let f = (a, b, c, d, e, o, p, q, i, j, k, l) => a + l in f(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12)", 13},
		{"let f = (x) => x * 2 in f(21)", 42},
		{"let f = (a, b) => a * 10 + b in f(b = 2, a = 1)", 12},
		{"let mk = (w) => {x = 0, y = 0, width = w, height = 2} in area(mk(5))", 10},
		{"let mk = (w) => {x = 0, y = 0, width = w, height = 2} in area(mk(5)) + area(mk(7))", 24},
		{"let grow = (r) => r with {width = 10} in area(grow(rect))", 40},
		{"let add = (a) => (b) => a + b, inc = add(1) in inc(2) + inc(5)", 9},
		{"let twice = (f, x) => f(f(x)) in twice((y) => y * 3, 2)", 18},
		{"let x = 1 in let f = (x) => x in f(5) + x", 6},
		{"let f = (x) => (x) => x in let g = f(1) in g(2)", 2},
		{"let f = (r) => area(r) in f({x = 0, y = 0, width = 3, height = 3})", 9},
		{"let f = (x) => x in set(f(.french))", 19},
	}
	for item in cases {
		run := run_of(item.text)
		testing.expectf(t, run.ok && run.value.kind == .Integer && run.value.integer == item.integer, "%q: %v %v %d, not %d (%v at column %d)", item.text, run.ok, run.value.kind, run.value.integer, item.integer, run.evaluation.refusal.refusal, run.evaluation.refusal.place.column)
	}

	// A function is a value: the value of a line, with its source span.
	run := run_of("(x) => x * 2")
	testing.expect(t, run.ok)
	testing.expect_value(t, run.value.kind, Kind.Function)
	fn_src, fn_open, _, fn_ok := function_source_offsets(&run.evaluation, run.value.vm_value)
	testing.expect(t, fn_ok && fn_src == "(x) => x * 2" && fn_open == 0)
	// A deep nesting of functions that the depth of a line holds.
	run = run_of(strings.concatenate({strings.repeat("()=>", lex_parser.LINE_PARSE_DEPTH_LIMIT / 2 - 1, context.temp_allocator), "1"}, context.temp_allocator))
	testing.expect(t, run.ok)
	testing.expect_value(t, run.value.kind, Kind.Function)

	// Lists: none, the items in order, map on map, a list of functions.
	run = run_of("[]")
	testing.expect(t, run.ok)
	testing.expect_value(t, run.value.kind, Kind.List)
	testing.expect_value(t, run.value.detail, u32(0))
	run = run_of("map(map([1, 2], (x) => x + 1), (y) => y * 10)")
	if values := items_of(run, run.value); testing.expect_value(t, len(values), 2) {
		testing.expect_value(t, values[0], i64(20))
		testing.expect_value(t, values[1], i64(30))
	}
	run = run_of("map([], (x) => g())")
	testing.expect(t, run.ok)
	testing.expect_value(t, run.value.detail, u32(0))
	expect_log(t, run, {}, "map on no item")
	run = run_of("[[1, 2], [3]]")
	testing.expect(t, run.ok)
	if outer := list_items_of(&run.evaluation, run.value.vm_value); testing.expect_value(t, len(outer), 2) {
		testing.expect_value(t, len(items_of(run, value_to_host(&run.evaluation, outer[0]))), 2)
		testing.expect_value(t, items_of(run, value_to_host(&run.evaluation, outer[1]))[0], i64(3))
	}
	run = run_of("map([1, 2], (x) => (y) => x + y)")
	testing.expect(t, run.ok)
	if functions := list_items_of(&run.evaluation, run.value.vm_value); testing.expect_value(t, len(functions), 2) {
		testing.expect_value(t, functions[0].kind, Kind.Function)
		testing.expect(t, functions[0].data != functions[1].data)
	}
}

// A line with "->" where a function is expected runs nothing: the names
// before it are parameters, never variables, and no call before it runs.
@(test)
evaluation_of_a_thin_arrow_runs_nothing :: proc(t: ^testing.T) {
	for text in ([]string{"map([1], n -> n * n)", "map([g()], n -> g())", "g() + (n -> n)", "n -> n"}) {
		run := run_of(text)
		testing.expectf(t, !run.ok && run.evaluation.refusal.refusal == .Text && run.evaluation.refusal.text_refusal == .Thin_Arrow, "%q: %v %v", text, run.evaluation.refusal.refusal, run.evaluation.refusal.text_refusal)
		expect_log(t, run, {}, text)
	}
}

// A host gives back the items of a list that it kept: they go after the
// items of the lists of the line, up to the capacity and never past it.
// The edges first: past the capacity at once, one past what is left, no
// item, then the last places.
@(test)
evaluation_takes_back_the_items_of_a_kept_list :: proc(t: ^testing.T) {
	kept := make([]Value, LIST_ITEM_CAPACITY + 1, context.temp_allocator)
	for &item, index in kept {
		item = value_int(i64(index) * 10)
	}
	run := run_of("[1, 2]")
	testing.expect(t, run.ok)
	testing.expect_value(t, run.evaluation.list_item_count, 2)
	first, ok := list_items_add(&run.evaluation, kept[:])
	testing.expect(t, !ok)
	testing.expect_value(t, run.evaluation.list_item_count, 2)
	first, ok = list_items_add(&run.evaluation, kept[:LIST_ITEM_CAPACITY - 1])
	testing.expect(t, !ok)
	testing.expect_value(t, run.evaluation.list_item_count, 2)
	first, ok = list_items_add(&run.evaluation, nil)
	testing.expect(t, ok)
	testing.expect_value(t, first, 2)
	testing.expect_value(t, run.evaluation.list_item_count, 2)
	// The items of the line stay; the added ones follow them.
	first, ok = list_items_add(&run.evaluation, kept[:3])
	testing.expect(t, ok)
	testing.expect_value(t, first, 2)
	if values := items_of(run, {kind = .List, integer = i64(first), detail = 3}); testing.expect_value(t, len(values), 3) {
		testing.expect_value(t, values[0], i64(0))
		testing.expect_value(t, values[2], i64(20))
	}
	testing.expect_value(t, items_of(run, run.value)[1], i64(2))
	// The last places: exactly what is left, then one item more.
	first, ok = list_items_add(&run.evaluation, kept[:LIST_ITEM_CAPACITY - 5])
	testing.expect(t, ok)
	testing.expect_value(t, first, 5)
	testing.expect_value(t, run.evaluation.list_item_count, LIST_ITEM_CAPACITY)
	_, ok = list_items_add(&run.evaluation, kept[:1])
	testing.expect(t, !ok)
	testing.expect_value(t, run.evaluation.list_item_count, LIST_ITEM_CAPACITY)
}

// The bytes of stack of the deepest lines of today, and of one level of a
// recursion, in this build: a measure, which no test reads.
@(test)
evaluation_stack_measure :: proc(t: ^testing.T) {
	lines := [?]string {
		strings.concatenate({strings.repeat("1+", 99, context.temp_allocator), "1"}, context.temp_allocator),
		strings.concatenate({strings.repeat("-", 199, context.temp_allocator), "1"}, context.temp_allocator),
		strings.concatenate({strings.repeat("f(", 66, context.temp_allocator), strings.repeat(")", 66, context.temp_allocator)}, context.temp_allocator),
	}
	for line in lines {
		run := run_of(line)
		testing.expectf(t, run.ok, "%s…: %v", line[:12], run.evaluation.refusal.refusal)
		fmt.printfln("lex_evaluator: measure: %d bytes of stack for %d steps of %s…", run.evaluation.stack_deepest, run.evaluation.steps, line[:12])
	}
	run := run_of("let f = (n) => f(n) in f(1)")
	fmt.printfln("lex_evaluator: measure: %d bytes of stack for %d calls of a recursion, to %v", run.evaluation.stack_deepest, run.evaluation.call_count, run.evaluation.refusal.refusal)
}
