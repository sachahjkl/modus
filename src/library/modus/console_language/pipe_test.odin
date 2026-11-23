#+build !freestanding
package console_language

import "core:testing"
import terminal "modus:terminal"

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
		{"log.follow |> where(level = Warning)", "where(log.follow, level = Warning)"},
		{"log.follow |> where(process = \"storage\") |> where(level = Warning)", "where(where(log.follow, process = \"storage\"), level = Warning)"},
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
	// "let name =" with no "in" keeps a value as "name =" does; with "in",
	// or with no name, or with "==", the whole line is the expression.
	testing.expect_value(t, expression_start("let"), 0)
	testing.expect_value(t, expression_start("let ="), 0)
	testing.expect_value(t, expression_start("let x"), 0)
	testing.expect_value(t, expression_start("let x == 1"), 0)
	testing.expect_value(t, expression_start("let x = 1 in x |> f"), 0)
	testing.expect_value(t, expression_start("let x = f(\"in\") |> g"), 7)
	testing.expect_value(t, expression_start("let x = [1, 2] |> map((n) => n)"), 7)
	testing.expect_value(t, expression_start("letter = 1"), 8)
	// An "in" inside brackets, or of an inner let, is no "in" of the first.
	testing.expect_value(t, expression_start("let x = f(let a = 1 in a) |> g"), 7)
	testing.expect_value(t, expression_start("let x = [let a = 1 in a] |> g"), 7)
	testing.expect_value(t, expression_start("let x = let a = 1 in a |> g"), 7)
	testing.expect_value(t, expression_start("let x = let a = 1 in a in x"), 0)
	testing.expect_value(t, expression_start("let x = (1 in"), 7)
	testing.expect_value(t, expression_start("let x = 1) in x"), 0)
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

// The placeholder: each '_' out of its place is refused before any call,
// with the call that it names; a '_' in its place gives its argument, and
// the value on the left takes its place in the nested form.
@(test)
pipe_placeholders :: proc(t: ^testing.T) {
	memory: [256]u8
	stages: [PIPE_STAGE_CAPACITY]Pipe_Stage
	Case :: struct {
		text:    string,
		refusal: Pipe_Refusal,
		call:    string,
		inner:   string,
	}
	cases := [?]Case {
		// No "|>" before the call of the '_': with no "|>" in the line, on
		// the left of "|>", in a call that is not on the right of "|>".
		{"_", .Placeholder_Without_Pipe, "", ""},
		{"f(_)", .Placeholder_Without_Pipe, "", ""},
		{"f(1, g(_))", .Placeholder_Without_Pipe, "", ""},
		{"_ |> f", .Placeholder_Without_Pipe, "", ""},
		{"f(_) |> g", .Placeholder_Without_Pipe, "", ""},
		{"x = _ + 1", .Placeholder_Without_Pipe, "", ""},
		// No whole argument: in an expression, in a group, in a literal,
		// twice in one piece, before "=".
		{"x |> f(_ + 1)", .Placeholder_Not_Whole, "f", ""},
		{"x |> f(1 + _)", .Placeholder_Not_Whole, "f", ""},
		{"x |> f((_))", .Placeholder_Not_Whole, "f", ""},
		{"x |> f({a = _})", .Placeholder_Not_Whole, "f", ""},
		{"x |> f(_ _)", .Placeholder_Not_Whole, "f", ""},
		{"x |> f(_ = 1)", .Placeholder_Not_Whole, "f", ""},
		{"x |> f(n = _ + 1)", .Placeholder_Not_Whole, "f", ""},
		// Two in one call.
		{"x |> f(_, _)", .Placeholder_Twice, "f", ""},
		{"x |> f(_, n = _)", .Placeholder_Twice, "f", ""},
		// In a call nested in the call on the right.
		{"x |> f(g(_))", .Placeholder_Nested, "f", "g"},
		{"x |> f(1, g(h(_)))", .Placeholder_Nested, "f", "h"},
	}
	for item in cases {
		form := nested_of(item.text, memory[:], stages[:])
		found := item.text[form.found_start:form.found_end]
		call := item.text[form.call_start:form.call_end]
		inner := item.text[form.inner_start:form.inner_end]
		testing.expectf(t, form.refusal == item.refusal && found == "_" && call == item.call && inner == item.inner && form.nested == "", "%q: %v %q %q %q, not %v %q %q", item.text, form.refusal, found, call, inner, item.refusal, item.call, item.inner)
	}

	Place :: struct {
		text:     string,
		nested:   string,
		argument: int,
		named:    bool,
	}
	places := [?]Place {
		{"x |> f(_)", "f(x)", 0, false},
		{"x |> f(b, _)", "f(b, x)", 1, false},
		{"x |> f(b, _, c)", "f(b, x, c)", 1, false},
		{"x |> f(n = _)", "f(n = x)", 0, true},
		{"x |> f(a, n = _)", "f(a, n = x)", 1, true},
		{"f(x |> g(_), y)", "f(g(x), y)", 0, false},
		{"f(x |> g(1, _)) |> h(_)", "h(f(g(1, x)))", 0, false},
	}
	for item in places {
		form := nested_of(item.text, memory[:], stages[:])
		testing.expectf(t, form.refusal == .None && form.nested == item.nested, "%q: %v %q, not %q", item.text, form.refusal, form.nested, item.nested)
		testing.expectf(t, form.stage_count >= 1 && stages[0].placeholder_argument == item.argument && stages[0].placeholder_named == item.named && item.text[stages[0].placeholder_start:][:1] == "_", "%q: the first stage has its '_' at %d, argument %d, named %v", item.text, stages[0].placeholder_start, stages[0].placeholder_argument, stages[0].placeholder_named)
	}

	// With no '_', the value on the left is the first argument; a name '_'
	// in the place of the call is left to the parser, which refuses it.
	form := nested_of("x |> f(b)", memory[:], stages[:])
	testing.expect(t, form.refusal == .None && stages[0].placeholder_start == -1 && stages[0].placeholder_argument == -1)
	form = nested_of("x |> _", memory[:], stages[:])
	testing.expect_value(t, form.refusal, Pipe_Refusal.None)
	testing.expect_value(t, form.nested, "_(x)")
	// A name that holds '_' is a name.
	form = nested_of("sum_values(x_y) |> f", memory[:], stages[:])
	testing.expect_value(t, form.nested, "f(sum_values(x_y))")
}

// The pieces of a call and of a literal end at the ',' outside braces and
// outside the bindings of a let; a named piece nests its value only.
@(test)
pipe_pieces_of_the_forms_of_records :: proc(t: ^testing.T) {
	memory: [256]u8
	stages: [PIPE_STAGE_CAPACITY]Pipe_Stage
	cases := [?][2]string {
		{"x |> f({a = 1, b = 2})", "f(x, {a = 1, b = 2})"},
		{"f(n = x |> g)", "f(n = g(x))"},
		{"{a = x |> g, b = 2}", "{a = g(x), b = 2}"},
		{"let a = x |> g in a |> h", "let a = g(x) in h(a)"},
		{"let a = 1, b = x |> g in a", "let a = 1, b = g(x) in a"},
		{"x |> f(let a = 1, b = 2 in a)", "f(x, let a = 1, b = 2 in a)"},
		{"r with {a = 1} |> f", "f(r with {a = 1})"},
	}
	for item in cases {
		form := nested_of(item[0], memory[:], stages[:])
		testing.expectf(t, form.refusal == .None && form.nested == item[1], "%q: %v %q, not %q", item[0], form.refusal, form.nested, item[1])
	}
	form := nested_of("x |> f({a = 1, b = 2}, 3)", memory[:], stages[:])
	testing.expect_value(t, stages[0].argument_count, 2)
	form = nested_of("x |> f(let a = 1, b = 2 in a, 3)", memory[:], stages[:])
	testing.expect_value(t, stages[0].argument_count, 2)
	// A '}' that nothing opened, in a line with "|>".
	form = nested_of("x} |> f", memory[:], stages[:])
	testing.expect_value(t, form.refusal, Pipe_Refusal.Unmatched_Close)
}

// The nested form of a function and a list: the body of a function is a
// segment of its own, after its head; the items of a list are pieces. A
// '_' in the body of a function on the right of "|>" is refused.
@(test)
pipe_pieces_of_functions_and_lists :: proc(t: ^testing.T) {
	memory: [256]u8
	stages: [PIPE_STAGE_CAPACITY]Pipe_Stage
	cases := [?][2]string {
		{"map(l, (x) => x |> g)", "map(l, (x) => g(x))"},
		{"l |> map((x) => x * 2)", "map(l, (x) => x * 2)"},
		{"(x) => x |> g", "(x) => g(x)"},
		{"() => 1 |> g", "() => g(1)"},
		{"[a |> f, b]", "[f(a), b]"},
		{"x |> f([1, 2], 3)", "f(x, [1, 2], 3)"},
		{"let f = (x) => x |> g in f(1)", "let f = (x) => g(x) in f(1)"},
		{"[1, 2] |> map((x) => x) |> map((y) => y |> g)", "map(map([1, 2], (x) => x), (y) => g(y))"},
		{"x |> f((y) => y, _)", "f((y) => y, x)"},
		// A comment is no part of the nested form, and its bytes hide no
		// "|>" and no '|'.
		{"x |> f // a note", "f(x)"},
		{"x |> f(1) // a | b |> c", "f(x, 1)"},
	}
	for item in cases {
		form := nested_of(item[0], memory[:], stages[:])
		testing.expectf(t, form.refusal == .None && form.nested == item[1], "%q: %v %q, not %q", item[0], form.refusal, form.nested, item[1])
	}
	form := nested_of("x |> f([1, 2], 3)", memory[:], stages[:])
	testing.expect_value(t, stages[0].argument_count, 2)
	refusals := [?]struct {
		text:    string,
		refusal: Pipe_Refusal,
	} {
		{"x |> map((y) => _)", .Placeholder_Not_Whole},
		{"x |> map((y) => f(_))", .Placeholder_Nested},
		{"x |> f([_])", .Placeholder_Not_Whole},
		{"x] |> f", .Unmatched_Close},
		{"(_) => 1", .Placeholder_Without_Pipe},
	}
	for item in refusals {
		form = nested_of(item.text, memory[:], stages[:])
		testing.expectf(t, form.refusal == item.refusal, "%q: %v, not %v", item.text, form.refusal, item.refusal)
	}
}

// The hint line parameter index at the caret: a call on the right of "|>"
// receives the value on the left as parameter 0, so arguments inside its
// parentheses start at parameter 1 unless a top-level "_" takes the piped
// value. Refused and non-call edges come first.
@(test)
call_parameter_at_caret_after_pipe :: proc(t: ^testing.T) {
	// Edges and non-calls: empty line, caret bounds, closed calls, comments,
	// unnamed parentheses, bare braces, and depth past GROUP_DEPTH_MOST.
	not_found_cases := [?]struct {
		text:  string,
		caret: int,
	} {
		{"", 0},
		{"", -1},
		{"", 1},
		{"f(1)", 0},
		{"f(1)", -5},
		{"f(1)", 4},
		{"f(1)", 99},
		{"a |> f()", 8},
		{"a |> f", 6},
		{"x = 1 + (2", 10},
		{"a |> (1 + 2", 11},
		{"{a = 1, ", 8},
		{"a |> f(1, // comment", 20},
	}
	for item in not_found_cases {
		name, parameter, found := call_parameter_at_caret(item.text, item.caret)
		testing.expectf(t, !found && name == "" && parameter == 0, "%q at %d: found %v (%q, %d)", item.text, item.caret, found, name, parameter)
	}

	// Nesting deeper than GROUP_DEPTH_MOST is refused.
	deep: [GROUP_DEPTH_MOST + 4]u8
	deep[0] = 'f'
	for index in 1 ..< len(deep) {
		deep[index] = '('
	}
	_, _, deep_found := call_parameter_at_caret(string(deep[:]), len(deep))
	testing.expect(t, !deep_found)

	// Found cases: non-pipe calls, single pipes, chained pipes, nested calls,
	// strings containing commas or "|>", record/list literals, and "_".
	Found_Case :: struct {
		text:      string,
		caret:     int,
		name:      string,
		parameter: int,
	}
	cases := [?]Found_Case {
		// Non-pipe calls.
		{"f()", 2, "f", 0},
		{"f(", 2, "f", 0},
		{"f(x, ", 5, "f", 1},
		{"f(x, y, )", 8, "f", 2},
		{"storage.write(", 14, "storage.write", 0},
		{"write(\"a, b\", ", 14, "write", 1},
		{"\"|>\" f(", 7, "f", 0},
		{"a | f(", 6, "f", 0},
		// Single pipe: parameter 0 comes from the left of "|>".
		{"a |> f()", 7, "f", 1},
		{"a |> f(", 7, "f", 1},
		{"a|>f(", 5, "f", 1},
		{"a |> f(b, )", 10, "f", 2},
		{"a |> f(b, ", 10, "f", 2},
		{"a |> f(b, c)", 8, "f", 1},
		{"a |> f(b, c)", 11, "f", 2},
		{"a |> storage.write(", 19, "storage.write", 1},
		{"a |> f(\"x, y\", ", 15, "f", 2},
		// Chained pipes.
		{"a |> f() |> g()", 14, "g", 1},
		{"a |> f() |> g(x, )", 17, "g", 2},
		{"a |> f() |> g(x, ", 17, "g", 2},
		{"a |> f(1) |> g(2, 3, ", 21, "g", 3},
		// Nested call inside a piped call is not itself piped.
		{"a |> f(g())", 9, "g", 0},
		{"a |> f(g(x, ))", 12, "g", 1},
		{"a |> f(g(1, 2), )", 16, "f", 2},
		// Record and list literals inside a piped call keep the enclosing call's parameter.
		{"a |> f({k = 1, ", 15, "f", 1},
		{"a |> f(b, [1, ", 14, "f", 2},
		// Placeholder "_" claims the piped value explicitly, so no extra shift applies.
		{"a |> f(_, )", 10, "f", 1},
		{"a |> f(b, _, )", 13, "f", 2},
		{"a |> f(, _)", 7, "f", 0},
		// Placeholder inside a nested call does not cancel the outer pipe shift.
		{"a |> f(g(_), )", 13, "f", 2},
	}
	for item in cases {
		name, parameter, found := call_parameter_at_caret(item.text, item.caret)
		testing.expectf(t, found && name == item.name && parameter == item.parameter, "%q at %d: got (%q, %d, %v), want (%q, %d, true)", item.text, item.caret, name, parameter, found, item.name, item.parameter)
	}
}

// The lines of log.follow nest as the console runs them: each "|>" gives
// its left value as the first argument of its call, so the evaluator sees
// where(log.follow, ...) and first(..., 5), and a bad pipe runs nothing.
@(test)
pipe_of_log_follow_lines :: proc(t: ^testing.T) {
	memory: [256]u8
	stages: [PIPE_STAGE_CAPACITY]Pipe_Stage
	Case :: struct {
		text:   string,
		nested: string,
	}
	cases := [?]Case {
		{"log.follow", "log.follow"},
		{"log.follow |> where(level = Warning)", "where(log.follow, level = Warning)"},
		{"log.follow |> where(level = Warning) |> first(5)", "first(where(log.follow, level = Warning), 5)"},
		{"log.follow |> where(level = Warning) |> columns(\"process\", \"text\")", "columns(where(log.follow, level = Warning), \"process\", \"text\")"},
		{"start(\"server\", wire(server.log, collector.sources))", "start(\"server\", wire(server.log, collector.sources))"},
	}
	for item in cases {
		form := nested_of(item.text, memory[:], stages[:])
		testing.expectf(t, form.refusal == .None && form.nested == item.nested, "%q: %v %q, not %q", item.text, form.refusal, form.nested, item.nested)
	}
	Refused :: struct {
		text:    string,
		refusal: Pipe_Refusal,
	}
	refused := [?]Refused {
		{"log.follow |>", .Line_End},
		{"log.follow | where(level = Warning)", .Lone_Bar},
		{"log.follow |> 5", .Not_A_Call},
		{"|> log.follow", .No_Left_Value},
		{"log.follow) |> first(5)", .Unmatched_Close},
	}
	for item in refused {
		form := nested_of(item.text, memory[:], stages[:])
		testing.expectf(t, form.refusal == item.refusal && form.nested == "", "%q: %v %q, not %v", item.text, form.refusal, form.nested, item.refusal)
	}
}

// A typed name is one token: the evaluator reads server.log and
// collector.sources whole, and a leading dot or a leading digit is no name.
@(test)
tokens_of_a_wiring_of_the_log :: proc(t: ^testing.T) {
	text := "start(\"server\", wire(server.log, collector.sources))"
	Expected :: struct {
		kind:  Token_Kind,
		bytes: string,
	}
	expected := [?]Expected {
		{.Name, "start"},
		{.Operator, "("},
		{.Text, "\"server\""},
		{.Operator, ","},
		{.Name, "wire"},
		{.Operator, "("},
		{.Name, "server.log"},
		{.Operator, ","},
		{.Name, "collector.sources"},
		{.Operator, ")"},
		{.Operator, ")"},
		{.None, ""},
	}
	place := 0
	for item in expected {
		token := token_next(text, place)
		testing.expectf(t, token.kind == item.kind && text[token.start:token.end] == item.bytes, "at %d: %v %q, not %v %q", place, token.kind, text[token.start:token.end], item.kind, item.bytes)
		place = token.end
	}
	member := token_next(".log", 0)
	testing.expect_value(t, member.kind, Token_Kind.Member)
	digit_first := token_next("1server.log", 0)
	testing.expect_value(t, digit_first.kind, Token_Kind.Number)
}
