#+build !freestanding
package console_language

import "core:testing"
import terminal "modus:support/terminal"

// nested_of gives the nested form of a line, or its refusal.
nested_of :: proc(text: string, memory: []u8, stages: []Pipe_Stage) -> Pipe_Form {
	return pipe_nested_form(text, expression_start(text), memory, stages)
}

// Each fault of the form of the operator: its refusal, the bytes that it
// names, and no nested form, so the console runs nothing of the line.
@(test)
pipe_refusals_of_the_form :: proc(t: ^testing.T) {
	memory: [256]u8
	stages: [PIPE_STAGE_CAPACITY]Pipe_Stage
	Case :: struct {
		text:    string,
		refusal: Pipe_Refusal,
		found:   string,
	}
	cases := [?]Case {
		// No value on the left: the start of the line, of a variable, of
		// parentheses and of an argument.
		{"|> where(\"name\", \"x\")", .No_Left_Value, "|>"},
		{"   |> f", .No_Left_Value, "|>"},
		{"x = |> f", .No_Left_Value, "|>"},
		{"f(|> g)", .No_Left_Value, "|>"},
		{"f(1, |> g)", .No_Left_Value, "|>"},
		// Nothing on the right, at the end of the line.
		{"processes() |>", .Line_End, "|>"},
		{"processes() |>   ", .Line_End, "|>"},
		{"f(processes() |>", .Line_End, "|>"},
		{"x |> f |>", .Line_End, "|>"},
		// No call on the right: an integer, a text, '(', another "|>", the
		// end of the parentheses, an operator, more after the call.
		{"x |> 12", .Not_A_Call, "12"},
		{"x |> \"name\"", .Not_A_Call, "\"name\""},
		{"x |> (f)", .Not_A_Call, "(f)"},
		{"x |> |> f", .Not_A_Call, "|>"},
		{"f(x |>)", .Not_A_Call, ")"},
		{"f(x |>, 1)", .Not_A_Call, ","},
		{"x |> -f", .Not_A_Call, "-f"},
		{"x |> f(1) + 2", .Not_A_Call, "f(1) + 2"},
		{"x |> f g", .Not_A_Call, "f g"},
		{"x |> f |> 3", .Not_A_Call, "3"},
		// A '|' alone is no operator, with or without a "|>" in the line.
		{"x | f", .Lone_Bar, "|"},
		{"length(\"a\") | length", .Lone_Bar, "|"},
		{"x || f", .Lone_Bar, "|"},
		{"x | > f", .Lone_Bar, "|"},
		{"x |> f |", .Lone_Bar, "|"},
		{"|", .Lone_Bar, "|"},
		// A ')' that no '(' opened leaves the parts of the operator with no border.
		{"x) |> f", .Unmatched_Close, ") |> f"},
		{"x |> f)", .Unmatched_Close, ")"},
	}
	for item in cases {
		form := nested_of(item.text, memory[:], stages[:])
		found := form.refusal == .None ? "" : item.text[form.found_start:form.found_end]
		testing.expectf(t, form.refusal == item.refusal && found == item.found && form.nested == "", "%q: %v %q %q, not %v %q", item.text, form.refusal, found, form.nested, item.refusal, item.found)
	}
}

// The bounds of the memory of the caller: 0, one less than the need, the
// need; the stages: 0, one less than the "|>" of the line, as many.
@(test)
pipe_refusals_at_the_bounds :: proc(t: ^testing.T) {
	stages: [3]Pipe_Stage
	text := "x |> f |> g(1) |> h"
	nested := "h(g(f(x), 1))"
	memory: [64]u8

	form := nested_of(text, memory[:0], stages[:])
	testing.expect_value(t, form.refusal, Pipe_Refusal.Too_Long)
	testing.expect_value(t, form.nested, "")
	form = nested_of(text, memory[:len(nested) - 1], stages[:])
	testing.expect_value(t, form.refusal, Pipe_Refusal.Too_Long)
	form = nested_of(text, memory[:len(nested)], stages[:])
	testing.expect_value(t, form.refusal, Pipe_Refusal.None)
	testing.expect_value(t, form.nested, nested)

	form = nested_of(text, memory[:], stages[:0])
	testing.expect_value(t, form.refusal, Pipe_Refusal.Too_Many_Stages)
	testing.expect_value(t, text[form.found_start:form.found_end], "|>")
	form = nested_of(text, memory[:], stages[:2])
	testing.expect_value(t, form.refusal, Pipe_Refusal.Too_Many_Stages)
	testing.expect_value(t, form.found_start, 15) // The third "|>".
	testing.expect_value(t, form.nested, "")
	form = nested_of(text, memory[:], stages[:3])
	testing.expect_value(t, form.refusal, Pipe_Refusal.None)
	testing.expect_value(t, form.stage_count, 3)

	// A line with no "|>" needs no memory and no stage: it is its own
	// nested form.
	form = nested_of("6 * 7", memory[:0], stages[:0])
	testing.expect(t, form.refusal == .None && form.nested == "6 * 7" && form.stage_count == 0)

	// The most "|>" that a line of 200 bytes holds: 66, inside the
	// capacity of the stages.
	long: [200]u8
	count := copy(long[:], "x")
	for count + 3 <= len(long) {
		count += copy(long[count:], "|>a")
	}
	long_stages: [PIPE_STAGE_CAPACITY]Pipe_Stage
	long_memory: [512]u8
	form = nested_of(string(long[:count]), long_memory[:], long_stages[:])
	testing.expect_value(t, form.refusal, Pipe_Refusal.None)
	testing.expect_value(t, form.stage_count, 66)
	testing.expect(t, len(form.nested) <= count, "the nested form is never longer than the line")
}

// The equivalence: each line with "|>" and the line with calls in calls
// that the parser reads in its place.
@(test)
pipe_nested_forms :: proc(t: ^testing.T) {
	memory: [256]u8
	stages: [PIPE_STAGE_CAPACITY]Pipe_Stage
	cases := [?][2]string {
		{"processes() |> where(\"name\", \"server\")", "where(processes(), \"name\", \"server\")"},
		{"processes() |> where(\"name\", \"server\") |> columns(\"name slot\")", "columns(where(processes(), \"name\", \"server\"), \"name slot\")"},
		{"x |> h |> g(1) |> f", "f(g(h(x), 1))"},
		{"x |> f", "f(x)"},
		{"x |> f()", "f(x)"},
		{"x|>f", "f(x)"},
		{"x |> monitor.count", "monitor.count(x)"},
		// The lowest priority: the whole expression on the left.
		{"1 + 2 |> f", "f(1 + 2)"},
		{"-x * 3 |> f(1)", "f(-x * 3, 1)"},
		// A variable keeps the value of the whole line.
		{"t = processes() |> rows", "t = rows(processes())"},
		// Inside parentheses and arguments: the ',' and the ')' end it.
		{"where(x |> f, \"a\", 1)", "where(f(x), \"a\", 1)"},
		{"(x |> f) + 1", "(f(x)) + 1"},
		{"x |> f(y |> g)", "f(x, g(y))"},
		{"x |> f( 1, 2)", "f(x,  1, 2)"},
		{"rows(help() |> first(3)) |> text", "text(rows(first(help(), 3)))"},
		// A "|>" in a text is a text.
		{"x |> f(\"a |> b\")", "f(x, \"a |> b\")"},
		// A call with no ')' keeps none: the parser says that it misses.
		{"x |> f(1", "f(x, 1"},
		// No "|>": the line itself.
		{"length(\"a|b\")", "length(\"a|b\")"},
		{"6 * 7", "6 * 7"},
		{"", ""},
	}
	for item in cases {
		form := nested_of(item[0], memory[:], stages[:])
		testing.expectf(t, form.refusal == .None && form.nested == item[1], "%q: %v %q, not %q", item[0], form.refusal, form.nested, item[1])
	}
}

// What each stage says: the name on the right, its written arguments, and
// what is known of the value on its left before the run.
@(test)
pipe_stages_of_a_line :: proc(t: ^testing.T) {
	memory: [256]u8
	stages: [PIPE_STAGE_CAPACITY]Pipe_Stage
	text := "processes() |> where(\"name\", \"server\") |> columns(\"name slot\") |> rows"
	form := nested_of(text, memory[:], stages[:])
	testing.expect_value(t, form.stage_count, 3)
	testing.expect_value(t, text[stages[0].name_start:stages[0].name_end], "where")
	testing.expect_value(t, stages[0].argument_count, 2)
	testing.expect_value(t, stages[0].left, Pipe_Left_Form.Call)
	testing.expect_value(t, text[stages[0].left_start:stages[0].left_end], "processes")
	testing.expect_value(t, text[stages[1].name_start:stages[1].name_end], "columns")
	testing.expect_value(t, stages[1].argument_count, 1)
	testing.expect(t, stages[1].left == .Stage && stages[1].stage_before == 0)
	testing.expect_value(t, stages[2].argument_count, 0)
	testing.expect(t, stages[2].left == .Stage && stages[2].stage_before == 1)

	Case :: struct {
		text: string,
		left: Pipe_Left_Form,
		name: string,
	}
	cases := [?]Case {
		{"12 |> f", .Integer, ""},
		{"9223372036854775807 |> f", .Integer, ""},
		{"9223372036854775808 |> f", .Other, ""}, // One past the largest: the run says that it does not fit.
		{"\"a\" |> f", .Text, ""},
		{"r |> f", .Name, "r"},
		{"r.x |> f", .Name, "r.x"},
		{"g(h(1), 2) |> f", .Call, "g"},
		{"g() |> f", .Call, "g"},
		{"g(1) + 1 |> f", .Other, ""},
		{"\"a\" + \"b\" |> f", .Other, ""},
		{"-1 |> f", .Other, ""},
		{"(g(1)) |> f", .Other, ""},
	}
	for item in cases {
		form = nested_of(item.text, memory[:], stages[:])
		name := item.name == "" ? "" : item.text[stages[0].left_start:stages[0].left_end]
		testing.expectf(t, form.refusal == .None && form.stage_count == 1 && stages[0].left == item.left && name == item.name, "%q: %v %q, not %v %q", item.text, stages[0].left, name, item.left, item.name)
	}
	// A stage inside an argument has its own first left value.
	form = nested_of("f(x |> g, y |> h(1) |> k)", memory[:], stages[:])
	testing.expect_value(t, form.stage_count, 3)
	testing.expect(t, stages[0].left == .Name && stages[1].left == .Name && stages[2].left == .Stage && stages[2].stage_before == 1)
}

// The start of an expression, and the name after a "|>" for the completion.
@(test)
pipe_places_of_a_line :: proc(t: ^testing.T) {
	testing.expect_value(t, expression_start("t = x |> f"), 3)
	testing.expect_value(t, expression_start("x |> f"), 0)
	testing.expect_value(t, expression_start("12 = 3"), 0)
	testing.expect_value(t, expression_start(""), 0)
	testing.expect(t, pipe_before("x |> wh", 5))
	testing.expect(t, pipe_before("x |> ", 5))
	testing.expect(t, pipe_before("x|>wh", 3))
	testing.expect(t, !pipe_before("where(x, wh", 9))
	testing.expect(t, !pipe_before("\"|>\" wh", 5)) // A "|>" in a text is a text.
	testing.expect(t, !pipe_before("x | wh", 4))
	testing.expect(t, !pipe_before("", 0))
	testing.expect(t, !pipe_before("x |> f", 99)) // A place past the end is the end: the token before it is f.
	testing.expect(t, pipe_before("x |>", 99))
}

// The scanner and the colors: "|>" is one token, an operator; '|' alone is
// unknown.
@(test)
pipe_tokens_and_runs :: proc(t: ^testing.T) {
	token := token_next("  |>x", 0)
	testing.expect(t, token.kind == .Pipe && token.start == 2 && token.end == 4)
	token = token_next("|x", 0)
	testing.expect(t, token.kind == .Unknown && token.end == 1)
	token = token_next("|", 0)
	testing.expect(t, token.kind == .Unknown && token.end == 1)
	runs: [terminal.CODE_RUN_LIMIT]terminal.Code_Run
	text := "x |> length | length"
	count := line_runs(text, 0, NO_CARET, test_names, runs[:])
	expect_runs(t, text, runs[:count], []Expected_Run{{"x", .Variable}, {"|>", .Operator}, {"length", .Function}, {"|", .Unknown}, {"length", .Function}})
	expect_cover(t, text, runs[:count])
}
