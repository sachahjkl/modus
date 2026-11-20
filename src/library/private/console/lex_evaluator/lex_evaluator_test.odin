#+build !freestanding
package lex_evaluator

import "core:strings"
import "core:testing"
import "modus:private/console/console_language"
import "modus:private/console/lex_parser"

// The fake host of the tests. Each call is an effect: the host writes its
// name in the log, in the order of the runs, and gives the number of the
// run as its value. `fails` runs and fails, as an export that fails.
// `missing` names no command. `pure` has no effect. `x` is 7, `t` is
// "tee", and `rows_a`, `rows_b` and `rows_other` are Tables, the last of
// another record; no other name is a variable.
@(private = "file")
Fake :: struct {
	log:        [32]string,
	log_count:  int,
	finds:      int, // The commands that the evaluator asked for.
	join:       [256]u8,
	join_count: int,
	last_text:  string, // The Text that a call took last as its last argument.
}

@(private = "file")
fake_name_value :: proc "contextless" (data: rawptr, name: string) -> (value: Value, ok: bool) {
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
	}
	return {}, false
}

@(private = "file")
fake_command_find :: proc "contextless" (data: rawptr, name: string) -> (has_effect: bool, found: bool) {
	fake := (^Fake)(data)
	fake.finds += 1
	if name == "missing" {
		return false, false
	}
	return name != "pure", true
}

@(private = "file")
fake_call_run :: proc "contextless" (data: rawptr, name: string, arguments: []Value) -> (value: Value, ok: bool) {
	fake := (^Fake)(data)
	fake.log[fake.log_count] = name
	fake.log_count += 1
	if len(arguments) > 0 && arguments[len(arguments) - 1].kind == .Text {
		fake.last_text = arguments[len(arguments) - 1].text
	}
	if name == "fails" {
		return {}, false
	}
	return {kind = .Integer, integer = i64(fake.log_count)}, true
}

// The condition of the fake forces its value, as the console does for a
// field that is no status.
@(private = "file")
fake_condition_value :: proc "contextless" (data: rawptr, evaluation: ^Evaluation, command_name: string, before: []Value, node: lex_parser.Node_Index) -> (value: Value, ok: bool) {
	return force(evaluation, lex_parser.node_at(evaluation.tree, node).first_child)
}

@(private = "file")
fake_fact_name_value :: proc "contextless" (data: rawptr, evaluation: ^Evaluation, command_name: string, node: lex_parser.Node_Index) -> (value: Value, ok: bool) {
	return {kind = .Text, text = lex_parser.node_text(evaluation.tree, node)}, true
}

// "+" of the fake: two Texts join; two Tables join their rows when their
// records are one, as the console's table sum, and are refused else.
@(private = "file")
fake_values_add :: proc "contextless" (data: rawptr, left, right: Value) -> (sum: Value, ok: bool) {
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
	tree:       lex_parser.Syntax_Tree,
	evaluation: Evaluation,
	fake:       Fake,
	value:      Value,
	ok:         bool,
}

@(private = "file")
run_of :: proc(text: string, mode := Evaluation_Mode.Console, budget: u32 = EVALUATION_BUDGET_STEPS) -> ^Run {
	run := new(Run, context.temp_allocator)
	lex_parser.parse(text, {form_of = test_form_of}, &run.tree)
	host := Evaluation_Host {
		data            = &run.fake,
		name_value      = fake_name_value,
		command_find    = fake_command_find,
		call_run        = fake_call_run,
		condition_value = fake_condition_value,
		fact_name_value = fake_fact_name_value,
		values_add      = fake_values_add,
	}
	evaluation_start(&run.evaluation, &run.tree, mode, host, budget)
	run.value, run.ok = line_force(&run.evaluation)
	return run
}

@(private = "file")
log_of :: proc(run: ^Run) -> []string {
	return run.fake.log[:run.fake.log_count]
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
	text := "f(g(), h())" // Three nodes: f, g, h, in the order of their force.
	run := run_of(text, budget = 0)
	testing.expect(t, !run.ok)
	testing.expect_value(t, run.evaluation.refusal.refusal, Refusal.Budget_Exceeded)
	testing.expect_value(t, run.evaluation.refusal.place.column, u32(1))
	testing.expect_value(t, run.evaluation.refusal.steps, u32(0))
	expect_log(t, run, {}, text)

	run = run_of(text, budget = 2)
	testing.expect_value(t, run.evaluation.refusal.refusal, Refusal.Budget_Exceeded)
	testing.expect_value(t, run.evaluation.refusal.place.column, u32(8)) // h
	testing.expect_value(t, run.evaluation.steps, u32(2))
	expect_log(t, run, {"g"}, text)

	run = run_of(text, budget = 3)
	testing.expect(t, run.ok)
	testing.expect_value(t, run.evaluation.steps, u32(3))
	expect_log(t, run, {"g", "h", "f"}, text)

	// The densest line of the console stays far below the constant.
	densest := strings.concatenate({strings.repeat("1+", 99, context.temp_allocator), "1"}, context.temp_allocator)
	run = run_of(densest)
	testing.expect(t, run.ok)
	testing.expect_value(t, run.value.integer, i64(100))
	testing.expect_value(t, run.evaluation.steps, u32(199))
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

// An effect runs once: a second force of a forced thunk gives the kept
// value, takes no step and calls no host.
@(test)
evaluation_forces_a_thunk_once :: proc(t: ^testing.T) {
	run := run_of("f(g())")
	testing.expect(t, run.ok)
	expect_log(t, run, {"g", "f"}, "f(g())")
	steps, finds := run.evaluation.steps, run.fake.finds
	for _ in 0 ..< 3 {
		value, ok := force(&run.evaluation, run.tree.root)
		testing.expect(t, ok)
		testing.expect_value(t, value.integer, i64(2))
		value, ok = force(&run.evaluation, lex_parser.node_at(&run.tree, run.tree.root).first_child)
		testing.expect(t, ok)
		testing.expect_value(t, value.integer, i64(1))
	}
	testing.expect_value(t, run.evaluation.steps, steps)
	testing.expect_value(t, run.fake.finds, finds)
	expect_log(t, run, {"g", "f"}, "f(g()) forced again")

	// A start forgets the thunks of the evaluation before.
	evaluation_start(&run.evaluation, &run.tree, .Console, run.evaluation.host)
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

	memory: [lex_parser.TEXT_BYTES_MOST]u8
	stages: [console_language.PIPE_STAGE_CAPACITY]console_language.Pipe_Stage
	piped := "h() |> g() |> f(k())"
	form := console_language.pipe_nested_form(piped, console_language.expression_start(piped), memory[:], stages[:])
	testing.expect_value(t, form.refusal, console_language.Pipe_Refusal.None)
	run = run_of(form.nested)
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
