#+build !freestanding
#+build !modus
package console_language

import "core:fmt"
import "core:testing"
import "core:time"
import "modus:contract/blake3"
import terminal "modus:terminal"

// The names of a console of the tests.
test_name_role :: proc "contextless" (data: rawptr, name: string) -> Name_Role {
	switch name {
	case "monitor.count", "length", "help":
		return .Function
	case "Rectangle":
		return .Record
	case "monitor", "storage":
		return .Module
	case "x", "r":
		return .Variable
	case "server.requests":
		return .Stream
	case "server":
		return .Module
	}
	return .Unknown
}

// A typed name is its owner, the dot and its record output; a record
// output that the owner does not declare is unknown after the dot, and a
// typed name being typed has no run after the dot yet.
@(test)
a_typed_name_has_the_colors_of_its_parts :: proc(t: ^testing.T) {
	runs: [16]terminal.Code_Run
	text := "first(server.requests, 3)"
	count := line_runs(text, 0, NO_CARET, test_names, runs[:])
	expect_runs(t, text, runs[:count], []Expected_Run{{"first", .Unknown}, {"(", .Operator}, {"server", .Module}, {".", .Operator}, {"requests", .Variable}, {",", .Operator}, {"3", .Number}, {")", .Operator}})
	text = "server.reqests "
	count = line_runs(text, 0, NO_CARET, test_names, runs[:])
	expect_runs(t, text, runs[:count], []Expected_Run{{"server", .Module}, {".", .Operator}, {"reqests", .Unknown}})
	text = "server.req"
	count = line_runs(text, 0, len(text), test_names, runs[:])
	expect_runs(t, text, runs[:count], []Expected_Run{{"server", .Module}, {".", .Operator}})
}

// The commands of the tests whose arguments are names of fields: columns,
// from its second argument.
test_field_names_from :: proc "contextless" (data: rawptr, command: string) -> int {
	return command == "columns" ? 1 : -1
}

test_names := Name_Lookup {
	role_of          = test_name_role,
	field_names_from = test_field_names_from,
}

// The names after the table of columns are fields, with a call inside its
// first argument and after "|>"; a name in the first argument keeps its
// role, and so does a name after the call closes.
@(test)
the_names_of_fields_of_a_call_have_the_color_of_a_parameter :: proc(t: ^testing.T) {
	runs: [32]terminal.Code_Run
	text := "columns(length(x), slot, name) "
	count := line_runs(text, 0, NO_CARET, test_names, runs[:])
	expect_runs(t, text, runs[:count], []Expected_Run{{"columns", .Unknown}, {"(", .Operator}, {"length", .Function}, {"(", .Operator}, {"x", .Variable}, {")", .Operator}, {",", .Operator}, {"slot", .Parameter}, {",", .Operator}, {"name", .Parameter}, {")", .Operator}})
	text = "x |> columns(slot) |> length "
	count = line_runs(text, 0, NO_CARET, test_names, runs[:])
	expect_runs(t, text, runs[:count], []Expected_Run{{"x", .Variable}, {"|>", .Operator}, {"columns", .Unknown}, {"(", .Operator}, {"slot", .Parameter}, {")", .Operator}, {"|>", .Operator}, {"length", .Function}})
}

Expected_Run :: struct {
	text: string,
	kind: terminal.Code_Kind,
}

// expect_runs compares the runs of a text with the parts expected, in order.
expect_runs :: proc(t: ^testing.T, text: string, runs: []terminal.Code_Run, expected: []Expected_Run, loc := #caller_location) {
	testing.expectf(t, len(runs) == len(expected), "%q: %d runs, not %d", text, len(runs), len(expected), loc = loc)
	for index in 0 ..< min(len(runs), len(expected)) {
		run := runs[index]
		part := text[int(run.start):][:int(run.length)]
		kind, kind_ok := terminal.code_kind_of(run.kind)
		testing.expectf(t, part == expected[index].text && kind_ok && kind == expected[index].kind, "%q: run %d is %q %d, not %q %v", text, index, part, run.kind, expected[index].text, expected[index].kind, loc = loc)
	}
}

// expect_cover checks that the runs are inside the text, in order, with no
// overlap, and that each byte between two runs is a space: no part of a
// finished line is left with no kind, unless the runs are full.
expect_cover :: proc(t: ^testing.T, text: string, runs: []terminal.Code_Run, loc := #caller_location) {
	end := 0
	for run, index in runs {
		start := int(run.start)
		kind, kind_ok := terminal.code_kind_of(run.kind)
		testing.expectf(t, run.length > 0 && start >= end && start + int(run.length) <= len(text) && kind_ok && kind != .None, "run %d (%d, %d, %d) of a text of %d bytes, after %d", index, start, run.length, run.kind, len(text), end, loc = loc)
		for place in end ..< min(start, len(text)) {
			testing.expectf(t, text[place] == ' ', "the byte %d (%d) is in no run and is not a space", place, text[place], loc = loc)
		}
		end = start + int(run.length)
	}
	if len(runs) < terminal.CODE_RUN_LIMIT {
		for place in end ..< len(text) {
			testing.expectf(t, text[place] == ' ', "the byte %d (%d) after the last run is not a space", place, text[place], loc = loc)
		}
	}
}

// The scanner that the parser reads: where a name, a number and a text end.
@(test)
scanner_of_the_parser :: proc(t: ^testing.T) {
	testing.expect_value(t, name_end("9abc", 0), 0) // A name does not start with a digit.
	testing.expect_value(t, name_end("monitor.count9 + 1", 0), 14)
	testing.expect_value(t, name_end("_a", 0), 2)
	testing.expect_value(t, name_end("", 0), 0)
	testing.expect_value(t, number_end("123abc", 0), 3)
	end, finished := text_end("\"ab\"c", 0)
	testing.expect(t, end == 4 && finished)
	end, finished = text_end("\"ab", 0)
	testing.expect(t, end == 3 && !finished)
	testing.expect_value(t, space_end("   x", 0), 3)
	testing.expect_value(t, space_end("x", 9), 1) // A place past the end is the end.
	token := token_next("  -> x", 0)
	testing.expect(t, token.kind == .Arrow && token.start == 2 && token.end == 4)
	token = token_next("  ", 0)
	testing.expect(t, token.kind == .None && token.start == 2)
	token = token_next("#", 0)
	testing.expect(t, token.kind == .Unknown && token.end == 1)
}

// Each kind of a line, in a finished line.
@(test)
line_runs_of_each_kind :: proc(t: ^testing.T) {
	text := "x = monitor.count(\"processors\") + 12 * length(\"ab\") % Rectangle(1, 2) # r.y"
	runs: [terminal.CODE_RUN_LIMIT]terminal.Code_Run
	count := line_runs(text, 0, NO_CARET, test_names, runs[:])
	expect_runs(t, text, runs[:count], []Expected_Run{
		{"x", .Variable}, {"=", .Operator},
		{"monitor", .Module}, {".", .Operator}, {"count", .Function}, {"(", .Operator}, {"\"processors\"", .Text}, {")", .Operator},
		{"+", .Operator}, {"12", .Number}, {"*", .Operator},
		{"length", .Function}, {"(", .Operator}, {"\"ab\"", .Text}, {")", .Operator},
		{"%", .Operator}, {"Rectangle", .Type}, {"(", .Operator}, {"1", .Number}, {",", .Operator}, {"2", .Number}, {")", .Operator},
		{"#", .Unknown}, {"r.y", .Variable},
	})
	expect_cover(t, text, runs[:count])
}

// A name that the console does not know is marked only after a byte is
// typed after it; a name that it knows has its kind at once.
@(test)
line_runs_of_a_name_being_typed :: proc(t: ^testing.T) {
	runs: [terminal.CODE_RUN_LIMIT]terminal.Code_Run
	Case :: struct {
		text:     string,
		caret:    int,
		expected: []Expected_Run,
	}
	cases := [?]Case {
		{"> foo", 5, {}}, // Still typed: no mark.
		{"> foo ", 6, {{"foo", .Unknown}}}, // A space after it.
		{"> foo(", 6, {{"foo", .Unknown}, {"(", .Operator}}},
		{"> foo bar", 5, {}}, // foo ends at the caret; bar ends at the end of the line.
		{"> length", 8, {{"length", .Function}}}, // Known while typed.
		{"> monitor.", 10, {{"monitor", .Module}, {".", .Operator}}},
		{"> monitor.cou", 13, {{"monitor", .Module}, {".", .Operator}}},
		{"> monitor.cou ", 14, {{"monitor", .Module}, {".", .Operator}, {"cou", .Unknown}}},
		{"> monitor.count", 15, {{"monitor", .Module}, {".", .Operator}, {"count", .Function}}},
		{"> y = 1", 7, {{"y", .Variable}, {"=", .Operator}, {"1", .Number}}}, // A new variable.
	}
	for item in cases {
		count := line_runs(item.text, 2, item.caret, test_names, runs[:])
		expect_runs(t, item.text, runs[:count], item.expected)
	}
	// In a line that is finished, an unknown name is marked at its end too.
	count := line_runs("foo", 0, NO_CARET, test_names, runs[:])
	expect_runs(t, "foo", runs[:count], []Expected_Run{{"foo", .Unknown}})
}

// A condition: a name that the console does not know before an operator
// is a field, and after an operator a member, both in the color of a
// parameter; each byte of an operator of two bytes is an operator. A name
// that the console knows keeps its own kind, a variable on the right too.
// The '=' after the name of a variable at the start of the line is no
// condition: the name after it is unknown. A '!' with no '=' after it is
// an operator, and the name before it is no field.
@(test)
line_runs_of_a_condition :: proc(t: ^testing.T) {
	runs: [terminal.CODE_RUN_LIMIT]terminal.Code_Run
	Case :: struct {
		text:     string,
		expected: []Expected_Run,
	}
	cases := [?]Case {
		{"where(x, level = Warning)", {{"where", .Unknown}, {"(", .Operator}, {"x", .Variable}, {",", .Operator}, {"level", .Parameter}, {"=", .Operator}, {"Warning", .Parameter}, {")", .Operator}}},
		{"f(block >= 12)", {{"f", .Unknown}, {"(", .Operator}, {"block", .Parameter}, {">", .Operator}, {"=", .Operator}, {"12", .Number}, {")", .Operator}}},
		{"f(name != r)", {{"f", .Unknown}, {"(", .Operator}, {"name", .Parameter}, {"!", .Operator}, {"=", .Operator}, {"r", .Variable}, {")", .Operator}}},
		{"f(a < b)", {{"f", .Unknown}, {"(", .Operator}, {"a", .Parameter}, {"<", .Operator}, {"b", .Parameter}, {")", .Operator}}},
		{"y = z", {{"y", .Variable}, {"=", .Operator}, {"z", .Unknown}}},
		{"f(a ! b)", {{"f", .Unknown}, {"(", .Operator}, {"a", .Unknown}, {"!", .Operator}, {"b", .Unknown}, {")", .Operator}}},
	}
	for item in cases {
		count := line_runs(item.text, 0, NO_CARET, test_names, runs[:])
		expect_runs(t, item.text, runs[:count], item.expected)
		expect_cover(t, item.text, runs[:count])
	}
	// A field that the input still types has no run yet.
	count := line_runs("> f(lev", 2, 7, test_names, runs[:])
	expect_runs(t, "> f(lev", runs[:count], []Expected_Run{{"f", .Unknown}, {"(", .Operator}})
}

// A text with no end quote is a text that is still being typed: its own
// kind, which the terminal draws as a text.
@(test)
line_runs_of_an_unfinished_text :: proc(t: ^testing.T) {
	runs: [terminal.CODE_RUN_LIMIT]terminal.Code_Run
	text := "> length(\"abc"
	count := line_runs(text, 2, len(text), test_names, runs[:])
	expect_runs(t, text, runs[:count], []Expected_Run{{"length", .Function}, {"(", .Operator}, {"\"abc", .Text_Unfinished}})
	text = "> length(\"abc\")"
	count = line_runs(text, 2, len(text), test_names, runs[:])
	expect_runs(t, text, runs[:count], []Expected_Run{{"length", .Function}, {"(", .Operator}, {"\"abc\"", .Text}, {")", .Operator}})
	testing.expect_value(t, terminal.code_kind_classes[.Text_Unfinished], terminal.code_kind_classes[.Text])
}

// The rows of the completion list: words, the module, the parameters, the
// types with what their parentheses hold, the arrow.
@(test)
signature_runs_of_the_rows :: proc(t: ^testing.T) {
	runs: [terminal.CODE_RUN_LIMIT]terminal.Code_Run
	Case :: struct {
		text:     string,
		expected: []Expected_Run,
	}
	cases := [?]Case {
		{"export of monitor (name: Text) -> Integer", {{"export", .Words}, {"of", .Words}, {"monitor", .Module}, {"(", .Operator}, {"name", .Parameter}, {":", .Operator}, {"Text", .Type}, {")", .Operator}, {"->", .Arrow}, {"Integer", .Type}}},
		{"export of monitor () -> Table(Count)", {{"export", .Words}, {"of", .Words}, {"monitor", .Module}, {"(", .Operator}, {")", .Operator}, {"->", .Arrow}, {"Table", .Type}, {"(", .Operator}, {"Count", .Type}, {")", .Operator}}},
		{
			"export of monitor (names: Table(Count_Name, Read)) -> Table(Count)",
			{{"export", .Words}, {"of", .Words}, {"monitor", .Module}, {"(", .Operator}, {"names", .Parameter}, {":", .Operator}, {"Table", .Type}, {"(", .Operator}, {"Count_Name", .Type}, {",", .Operator}, {"Read", .Type}, {")", .Operator}, {")", .Operator}, {"->", .Arrow}, {"Table", .Type}, {"(", .Operator}, {"Count", .Type}, {")", .Operator}},
		},
		{"command (a: Integer, b: Value) -> Integer", {{"command", .Words}, {"(", .Operator}, {"a", .Parameter}, {":", .Operator}, {"Integer", .Type}, {",", .Operator}, {"b", .Parameter}, {":", .Operator}, {"Value", .Type}, {")", .Operator}, {"->", .Arrow}, {"Integer", .Type}}},
		{"record (Integer)", {{"record", .Words}, {"(", .Operator}, {"Integer", .Type}, {")", .Operator}}}, // A parameter with no name.
		{"variable: Integer", {{"variable", .Words}, {":", .Operator}, {"Integer", .Type}}},
		{"3 lines ago", {{"3", .Words}, {"lines", .Words}, {"ago", .Words}}},
		{"process that runs", {{"process", .Words}, {"that", .Words}, {"runs", .Words}}},
	}
	for item in cases {
		count := signature_runs(item.text, 0, runs[:])
		expect_runs(t, item.text, runs[:count], item.expected)
		expect_cover(t, item.text, runs[:count])
	}
	// From the end of the name: the runs are places in the whole row.
	row := "countexport of monitor (name: Text) -> Integer"
	count := signature_runs(row, 5, runs[:])
	testing.expect(t, count == 10 && runs[0].start == 5 && runs[0].length == 6)
}

// A line of 200 bytes: the runs stop at CODE_RUN_LIMIT, in order, inside
// the line; the text past them has no run.
@(test)
line_runs_of_a_long_line :: proc(t: ^testing.T) {
	bytes: [202]u8
	piece := "length(x)+1-" // 7 runs in 12 bytes: about 116 runs in the line.
	count := copy(bytes[:], "> ")
	for count < len(bytes) {
		count += copy(bytes[count:], piece)
	}
	text := string(bytes[:])
	runs: [terminal.CODE_RUN_LIMIT]terminal.Code_Run
	run_count := line_runs(text, 2, len(text), test_names, runs[:])
	testing.expect_value(t, run_count, terminal.CODE_RUN_LIMIT)
	// The prompt has no run, and the text past the limit has none: the
	// cover of a whole line is checked on the shorter lines above.
	testing.expect(t, run_count > 0 && int(runs[0].start) >= 2)
	// Each run fits the row of the terminal.
	row := terminal.Code_Runs{runs = runs, count = run_count}
	testing.expect(t, terminal.code_runs_check(&row, len(text)))
}

// Any byte, in any order: the runs stay inside the text and in order, each
// byte that is not a space is in a run, and the scanner does not stop.
@(test)
line_runs_of_hostile_bytes :: proc(t: ^testing.T) {
	bytes: [256]u8
	for &b, index in bytes {
		b = u8(255 - index) // The quote comes late: most bytes are tokens of their own.
	}
	runs: [terminal.CODE_RUN_LIMIT]terminal.Code_Run
	text := string(bytes[:60])
	count := line_runs(text, 0, NO_CARET, test_names, runs[:])
	expect_cover(t, text, runs[:count])
	text = string(bytes[:])
	count = line_runs(text, 0, NO_CARET, test_names, runs[:])
	testing.expect_value(t, count, terminal.CODE_RUN_LIMIT)
	expect_cover(t, text, runs[:count])
	count = signature_runs(text, 0, runs[:])
	expect_cover(t, text, runs[:count])
	// A name of 300 bytes: two runs, none starts past the byte 255.
	long: [300]u8
	for &b in long {
		b = 'a'
	}
	count = line_runs(string(long[:]), 0, NO_CARET, test_names, runs[:])
	testing.expect_value(t, count, 2)
	testing.expect(t, runs[0].start == 0 && runs[0].length == 255 && runs[1].start == 255)
	// A caret past the text and a first byte past the text.
	testing.expect_value(t, line_runs("ab", 9, 40, test_names, runs[:]), 0)
	testing.expect_value(t, line_runs("ab", 0, 40, {}, runs[:0]), 0)
}

// An operation whose result does not fit says so: no result wraps.
@(test)
integers_do_not_wrap :: proc(t: ^testing.T) {
	value, ok := number_value("9223372036854775807", 0, 19)
	testing.expect(t, ok && value == INTEGER_MOST, "the largest literal fits")
	_, ok = number_value("9223372036854775808", 0, 19)
	testing.expect(t, !ok, "a literal one past the largest does not fit")
	_, ok = number_value("99999999999999999999999", 0, 23)
	testing.expect(t, !ok, "a long literal does not fit")
	value, ok = number_value("x12y", 1, 3)
	testing.expect(t, ok && value == 12, "the digits of a part of a text")

	sum, sum_ok := integer_add(INTEGER_MOST, 0)
	testing.expect(t, sum_ok && sum == INTEGER_MOST)
	_, sum_ok = integer_add(INTEGER_MOST, 1)
	testing.expect(t, !sum_ok, "the largest and 1")
	_, sum_ok = integer_add(INTEGER_LEAST, -1)
	testing.expect(t, !sum_ok, "the least and -1")
	sum, sum_ok = integer_add(INTEGER_LEAST, INTEGER_MOST)
	testing.expect(t, sum_ok && sum == -1)

	difference, difference_ok := integer_subtract(INTEGER_LEAST, 0)
	testing.expect(t, difference_ok && difference == INTEGER_LEAST)
	_, difference_ok = integer_subtract(INTEGER_LEAST, 1)
	testing.expect(t, !difference_ok, "the least less 1")
	_, difference_ok = integer_subtract(0, INTEGER_LEAST)
	testing.expect(t, !difference_ok, "0 less the least")
	difference, difference_ok = integer_subtract(-1, INTEGER_MOST)
	testing.expect(t, difference_ok && difference == INTEGER_LEAST)

	product, product_ok := integer_multiply(3037000499, 3037000499)
	testing.expect(t, product_ok && product == 9223372030926249001)
	_, product_ok = integer_multiply(3037000500, 3037000500)
	testing.expect(t, !product_ok, "a square past the largest")
	_, product_ok = integer_multiply(INTEGER_LEAST, -1)
	testing.expect(t, !product_ok, "the least times -1")
	_, product_ok = integer_multiply(-1, INTEGER_LEAST)
	testing.expect(t, !product_ok, "-1 times the least")
	product, product_ok = integer_multiply(INTEGER_LEAST, 1)
	testing.expect(t, product_ok && product == INTEGER_LEAST)
	product, product_ok = integer_multiply(-4611686018427387904, 2)
	testing.expect(t, product_ok && product == INTEGER_LEAST)
	_, product_ok = integer_multiply(-4611686018427387905, 2)
	testing.expect(t, !product_ok, "a negative product past the least")
	_, product_ok = integer_multiply(-3037000500, -3037000500)
	testing.expect(t, !product_ok, "two negative numbers past the largest")
	product, product_ok = integer_multiply(0, INTEGER_LEAST)
	testing.expect(t, product_ok && product == 0)

	_, negate_ok := integer_negate(INTEGER_LEAST)
	testing.expect(t, !negate_ok, "the opposite of the least")
	quotient, rest, divide_ok := integer_divide(7, -2)
	testing.expect(t, divide_ok && quotient == -3 && rest == 1)
	_, _, divide_ok = integer_divide(INTEGER_LEAST, -1)
	testing.expect(t, !divide_ok, "the least divided by -1")
	_, _, divide_ok = integer_divide(1, 0)
	testing.expect(t, !divide_ok, "a division by zero")
	quotient, rest, divide_ok = integer_divide(INTEGER_MOST, -1)
	testing.expect(t, divide_ok && quotient == -INTEGER_MOST && rest == 0)
}

// The words of Lex have the color of an operator; the names of the
// bindings of a let the color of a variable, where they are bound and where
// they are read; a field of a literal and a named argument before their
// "=" the color of a parameter.
@(test)
line_runs_of_the_forms_of_records :: proc(t: ^testing.T) {
	runs: [32]terminal.Code_Run
	text := "let a = 1 in a with r "
	count := line_runs(text, 0, NO_CARET, test_names, runs[:])
	expect_runs(t, text, runs[:count], []Expected_Run{{"let", .Operator}, {"a", .Variable}, {"=", .Operator}, {"1", .Number}, {"in", .Operator}, {"a", .Variable}, {"with", .Operator}, {"r", .Variable}})
	expect_cover(t, text, runs[:count])
	text = "length({width = 2}, by = 3) "
	count = line_runs(text, 0, NO_CARET, test_names, runs[:])
	expect_runs(t, text, runs[:count], []Expected_Run{{"length", .Function}, {"(", .Operator}, {"{", .Operator}, {"width", .Parameter}, {"=", .Operator}, {"2", .Number}, {"}", .Operator}, {",", .Operator}, {"by", .Parameter}, {"=", .Operator}, {"3", .Number}, {")", .Operator}})
	text = "x |> length(_) "
	count = line_runs(text, 0, NO_CARET, test_names, runs[:])
	expect_runs(t, text, runs[:count], []Expected_Run{{"x", .Variable}, {"|>", .Operator}, {"length", .Function}, {"(", .Operator}, {"_", .Operator}, {")", .Operator}})
	// A word being typed has no run yet: "in" can start "index".
	text = "let a = 1 in"
	count = line_runs(text, 0, len(text), test_names, runs[:])
	expect_runs(t, text, runs[:count], []Expected_Run{{"let", .Operator}, {"a", .Variable}, {"=", .Operator}, {"1", .Number}})
	// A name after "," in the arguments of a call inside a let is no
	// binding: only the bindings at the depth of the let are.
	testing.expect(t, !bound_by_let("let a = f(1, b = 2) in b", token_next("let a = f(1, b = 2) in b", 23)))
	testing.expect(t, bound_by_let("let a = 1, b = 2 in b", token_next("let a = 1, b = 2 in b", 20)))
}

// The scanner of a function and a list: "=>" is one token, apart from "="
// and ">"; a '(' starts a function only when "=>" follows its group.
@(test)
scanner_of_functions :: proc(t: ^testing.T) {
	token := token_next("x => 1", 1)
	testing.expect(t, token.kind == .Function_Arrow && token.start == 2 && token.end == 4)
	token = token_next(">=", 0)
	testing.expect(t, token.kind == .Operator && token.end == 1)
	token = token_next("==>", 0)
	testing.expect(t, token.kind == .Operator && token.end == 1)
	token = token_next("[", 0)
	testing.expect(t, token.kind == .Operator && token.end == 1)
	Head :: struct {
		text:      string,
		found:     bool,
		close:     int,
		arrow_end: int,
	}
	heads := [?]Head {
		{"(x) => x", true, 2, 6},
		{"() => 1", true, 1, 5},
		{"(a, b)=>a", true, 5, 8},
		{"((x) => x)", false, 0, 0},
		{"(x)", false, 0, 0},
		{"(x) + 1", false, 0, 0},
		{"(x", false, 0, 0},
		{"(f(1), [2]) => 3", true, 10, 14},
		{"x => 1", false, 0, 0},
		{"", false, 0, 0},
	}
	for item in heads {
		close, arrow_end, found := function_head(item.text, 0)
		testing.expectf(t, found == item.found && close == item.close && arrow_end == item.arrow_end, "%q: %v %d %d, not %v %d %d", item.text, found, close, arrow_end, item.found, item.close, item.arrow_end)
	}
	// The body ends at the ',' or the close around the function, or at the
	// `in` of a let around it; a let inside the body keeps its own `in`.
	testing.expect_value(t, function_body_end("f((x) => x + 1, 2)", 8), 14)
	testing.expect_value(t, function_body_end("[(x) => x]", 7), 9)
	testing.expect_value(t, function_body_end("let f = (x) => x in f(1)", 14), 17)
	testing.expect_value(t, function_body_end("(x) => let y = x in y", 6), 21)
	testing.expect_value(t, function_body_end("(x) => g(x, 1)", 6), 14)
}

// The colors of a function and a list: "=>", "[" and "]" are operators, a
// parameter is a variable where it is bound and where its body reads it,
// and the same name outside the body is not one.
@(test)
line_runs_of_functions :: proc(t: ^testing.T) {
	runs: [32]terminal.Code_Run
	text := "(p, q) => p + q "
	count := line_runs(text, 0, NO_CARET, test_names, runs[:])
	expect_runs(t, text, runs[:count], []Expected_Run{{"(", .Operator}, {"p", .Variable}, {",", .Operator}, {"q", .Variable}, {")", .Operator}, {"=>", .Operator}, {"p", .Variable}, {"+", .Operator}, {"q", .Variable}})
	expect_cover(t, text, runs[:count])
	text = "length([1], (p) => p, p) "
	count = line_runs(text, 0, NO_CARET, test_names, runs[:])
	expect_runs(t, text, runs[:count], []Expected_Run{{"length", .Function}, {"(", .Operator}, {"[", .Operator}, {"1", .Number}, {"]", .Operator}, {",", .Operator}, {"(", .Operator}, {"p", .Variable}, {")", .Operator}, {"=>", .Operator}, {"p", .Variable}, {",", .Operator}, {"p", .Unknown}, {")", .Operator}})
	// A parameter read with a field, and an inner function that hides
	// nothing of the outer one.
	text = "(p) => (s) => p.a + s "
	count = line_runs(text, 0, NO_CARET, test_names, runs[:])
	expect_runs(t, text, runs[:count], []Expected_Run{{"(", .Operator}, {"p", .Variable}, {")", .Operator}, {"=>", .Operator}, {"(", .Operator}, {"s", .Variable}, {")", .Operator}, {"=>", .Operator}, {"p.a", .Variable}, {"+", .Operator}, {"s", .Variable}})
	// The parameters that a name at a place can read: the outer ones
	// first, none outside the body.
	tokens: [4]Token
	line := "(a) => (b) => a + b"
	testing.expect_value(t, parameters_at(line, 18, tokens[:]), 2)
	testing.expect_value(t, line[tokens[0].start:tokens[0].end], "a")
	testing.expect_value(t, line[tokens[1].start:tokens[1].end], "b")
	testing.expect_value(t, parameters_at(line, 7, tokens[:]), 1)
	testing.expect_value(t, parameters_at("f((a) => a, 1)", 12, tokens[:]), 0)
	testing.expect_value(t, parameters_at("(a, b, c, d, e) => a", 19, tokens[:2]), 2)

	// Only a name alone between the '(' or a ',' and a ',' or the ')' is a
	// parameter, as the parser reads it: no name of a call, of a group or
	// of a dotted name in a head that the parser refuses.
	head := "(f(1), [g], h.i, j) => f + g + h + j"
	testing.expect_value(t, head_parameters(head, 1, 18, tokens[:]), 1)
	testing.expect_value(t, head[tokens[0].start:tokens[0].end], "j")
	for name in ([]string{"f", "g", "h"}) {
		place := 23
		for head[place:place + 1] != name {
			place += 1
		}
		testing.expectf(t, !bound_by_function(head, token_next(head, place)), "%s in the body is no parameter", name)
	}
	testing.expect(t, bound_by_function(head, token_next(head, 35)))
	testing.expect(t, !bound_by_function(head, token_next(head, 1)))
	testing.expect_value(t, parameters_at(head, 30, tokens[:]), 1)
}

// The time of the colors of the longest line of functions: the colors read
// the line again for each name. A measure, which no test reads.
@(test)
line_runs_of_functions_measure :: proc(t: ^testing.T) {
	builder: [TEST_LINE_BYTES]u8
	count := 0
	part := "(a) => (b) => a + b, "
	for count + len(part) <= len(builder) {
		count += copy(builder[count:], part)
	}
	text := string(builder[:count])
	runs: [256]terminal.Code_Run
	started := time.tick_now()
	written := 0
	for _ in 0 ..< 100 {
		written = line_runs(text, 0, NO_CARET, test_names, runs[:])
	}
	fmt.printfln("console_language: measure: the colors of a line of %d bytes and %d runs take %v", len(text), written, time.tick_since(started) / 100)
}

@(private = "file")
TEST_LINE_BYTES :: 200

// A comment: "//" outside a text, to the end of its line. It gives no
// token, and the colors draw it in the color of the words. "//" in a text
// is a part of the text, and "/ /" is two operators.
@(test)
comments_of_a_line :: proc(t: ^testing.T) {
	token := token_next("1 // two", 1)
	testing.expect(t, token.kind == .None && token.start == 8)
	token = token_next("// a\nb", 0)
	testing.expect(t, token.kind == .Unknown && token.start == 4)
	token = token_next("\"a // b\"", 0)
	testing.expect(t, token.kind == .Text && token.end == 8)
	token = token_next("/ / 2", 0)
	testing.expect(t, token.kind == .Operator && token.end == 1)
	testing.expect_value(t, token_next("/ / 2", 1).start, 2)
	token = token_next("/", 0)
	testing.expect(t, token.kind == .Operator && token.end == 1)
	testing.expect_value(t, space_end("  // c", 0), 6)
	testing.expect_value(t, space_end("//", 0), 2)

	runs: [16]terminal.Code_Run
	text := "1 + 2 // three |> f(\"x\")"
	count := line_runs(text, 0, NO_CARET, test_names, runs[:])
	expect_runs(t, text, runs[:count], []Expected_Run{{"1", .Number}, {"+", .Operator}, {"2", .Number}, {"// three |> f(\"x\")", .Words}})
	text = "// only a comment"
	count = line_runs(text, 0, NO_CARET, test_names, runs[:])
	expect_runs(t, text, runs[:count], []Expected_Run{{"// only a comment", .Words}})
	text = "length(\"a // b\") "
	count = line_runs(text, 0, NO_CARET, test_names, runs[:])
	expect_runs(t, text, runs[:count], []Expected_Run{{"length", .Function}, {"(", .Operator}, {"\"a // b\"", .Text}, {")", .Operator}})
	text = "1 / / 2"
	count = line_runs(text, 0, NO_CARET, test_names, runs[:])
	expect_runs(t, text, runs[:count], []Expected_Run{{"1", .Number}, {"/", .Operator}, {"/", .Operator}, {"2", .Number}})
}

// The places of the caret that the completion reads with the scanner: in a
// comment it offers nothing, so a key there, Enter too, stays a key of the
// comment. A '(' in a comment or in a text opens no group.
@(test)
the_completion_reads_comments_with_the_scanner :: proc(t: ^testing.T) {
	// The comment of the fault of the machine test, and each place in it.
	text := "(x) => x + 1 // a comment ends the line"
	start := 13
	testing.expect(t, comment_starts(text, start))
	testing.expect(t, !in_comment(text, start), "the '/' itself: a name before it ends there")
	testing.expect(t, in_comment(text, start + 1), "between the two '/'")
	testing.expect(t, in_comment(text, start + 2), "right after \"//\"")
	testing.expect(t, in_comment(text, start + 12), "in its middle")
	testing.expect(t, in_comment(text, len(text)), "at its end, the end of the line: \"line\" typed there")
	testing.expect(t, !in_comment(text, 8), "in the code before it")
	// A name that ends at the "//" is code: the completion offers names
	// for it as before.
	testing.expect(t, !in_comment("are// c", 3))
	testing.expect(t, in_comment("are// c", 4))
	// "//" in a text is a part of the text: no comment, finished or not.
	testing.expect(t, !in_comment("f(\"a // b\") + x", 7))
	testing.expect(t, !in_comment("f(\"a // b\") + x", 15))
	testing.expect(t, !in_comment("x = \"a // b", 11))
	// "/ /" is two operators, and a line with no comment has none.
	testing.expect(t, !in_comment("1 / / 2", 4))
	testing.expect(t, !in_comment("", 0))
	// A comment ends at the end of its line: a place on the next line is
	// code. A line of the console holds no line end, so this place happens
	// only in a text of more lines, as a declaration.
	testing.expect(t, !in_comment("a // c\nb", 8))
	testing.expect(t, in_comment("a // c\nb", 6))

	// A '(' or a ',' in a comment or in a text opens no group and moves no
	// argument: the groups at a place are those of the code.
	groups: [GROUP_DEPTH_MOST]Open_Group
	line := "f(1, g(2) // h(3, 4"
	depth, found := groups_at(line, len(line), &groups)
	testing.expect(t, found)
	testing.expect_value(t, depth, 1)
	testing.expect_value(t, groups[0].commas, 1)
	testing.expect_value(t, groups[0].start, 1)
	line = "f(\"(,(\", "
	depth, found = groups_at(line, len(line), &groups)
	testing.expect_value(t, depth, 1)
	testing.expect_value(t, groups[0].commas, 1)
	// The openers: a call, a record literal, a list.
	line = "f({a = [1, "
	depth, found = groups_at(line, len(line), &groups)
	testing.expect_value(t, depth, 3)
	testing.expect_value(t, groups[0].opener, Group_Opener.Parenthesis)
	testing.expect_value(t, groups[1].opener, Group_Opener.Brace)
	testing.expect_value(t, groups[2].opener, Group_Opener.Bracket)
	testing.expect_value(t, groups[2].commas, 1)
	// Past GROUP_DEPTH_MOST groups the place is not known.
	deep: [64]u8
	for &b in deep {
		b = '('
	}
	_, found = groups_at(string(deep[:GROUP_DEPTH_MOST + 1]), GROUP_DEPTH_MOST + 1, &groups)
	testing.expect(t, !found)
	_, found = groups_at(string(deep[:GROUP_DEPTH_MOST]), GROUP_DEPTH_MOST, &groups)
	testing.expect(t, found)
}

// Hash literals: exact 64 lowercase hexadecimal digits after "blake3:".
// Refusals first: empty, 1 byte, 63 bytes, 65 bytes, uppercase hex, non-hex,
// wrong prefix; then round-trip of valid hashes and bare "blake3" as Name.
@(test)
hash_literals_and_refusals :: proc(t: ^testing.T) {
	refused := [?]string {
		"blake3:",
		"blake3:0",
		"blake3:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcde", // 63 hex chars
		"blake3:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0", // 65 hex chars
		"blake3:0123456789ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef", // uppercase A-F
		"blake3:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdeg", // invalid 'g'
		"blake3:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcde_", // underscore
		"blake3:zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz",
		"sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
		"",
	}
	for item in refused {
		_, ok := hash_value(item, 0, len(item))
		testing.expectf(t, !ok, "%q must be refused as a hash literal", item)
	}

	// Tokenization keeps malformed blake3:... as a single Hash token so the
	// parser refuses the whole token at its place.
	short_tok := token_next("module(blake3:abcd)", 7)
	testing.expect(t, short_tok.kind == .Hash && short_tok.start == 7 && short_tok.end == 18)
	empty_tok := token_next("blake3:)", 0)
	testing.expect(t, empty_tok.kind == .Hash && empty_tok.start == 0 && empty_tok.end == 7)
	// Bare "blake3" with no ':' stays a Name.
	name_tok := token_next("blake3 + 1", 0)
	testing.expect(t, name_tok.kind == .Name && name_tok.start == 0 && name_tok.end == 6)

	// Valid 64-hex lowercase literal decodes and formats identically.
	valid := "blake3:0123456789abcdef00112233445566778899aabbccddeeffdeadbeefcafebabe"
	tok := token_next(valid, 0)
	testing.expect(t, tok.kind == .Hash && tok.start == 0 && tok.end == HASH_LITERAL_BYTES)
	decoded, ok := hash_value(valid, tok.start, tok.end)
	testing.expect(t, ok)
	testing.expect_value(t, decoded[0], u8(0x01))
	testing.expect_value(t, decoded[1], u8(0x23))
	testing.expect_value(t, decoded[7], u8(0xef))
	testing.expect_value(t, decoded[28], u8(0xca))
	testing.expect_value(t, decoded[31], u8(0xbe))
	formatted_buf: [HASH_LITERAL_BYTES]u8
	testing.expect_value(t, hash_format(decoded, &formatted_buf), valid)

	// Zero hash and all-ff hash edges.
	zeros_buf: [HASH_LITERAL_BYTES]u8
	zeros_text := hash_format(blake3.Hash{}, &zeros_buf)
	zeros_out, zeros_ok := hash_value(zeros_text, 0, len(zeros_text))
	testing.expect(t, zeros_ok && zeros_out == blake3.Hash{})
	ones: blake3.Hash
	for &b in ones {
		b = 0xff
	}
	ones_buf: [HASH_LITERAL_BYTES]u8
	ones_text := hash_format(ones, &ones_buf)
	ones_out, ones_ok := hash_value(ones_text, 0, len(ones_text))
	testing.expect(t, ones_ok && ones_out == ones)

	// Colors: valid hash is Number (literal), malformed finished hash is Unknown.
	runs: [16]terminal.Code_Run
	count := line_runs(valid, 0, NO_CARET, test_names, runs[:])
	expect_runs(t, valid, runs[:count], []Expected_Run{{valid, .Number}})
	bad := "blake3:abcd"
	count = line_runs(bad, 0, NO_CARET, test_names, runs[:])
	expect_runs(t, bad, runs[:count], []Expected_Run{{bad, .Unknown}})
	count = line_runs(bad, 0, len(bad), test_names, runs[:])
	expect_runs(t, bad, runs[:count], []Expected_Run{{bad, .Number}})
}

// Multi-line Lex scanning: tabs, CR/LF, comments across lines, multi-line
// function heads, and multi-line pipes. Single-line mode remains unchanged.
@(test)
multiline_scanning_and_pipes :: proc(t: ^testing.T) {
	source := "// header comment\n\t{\n\t\ta = 1, // inline comment\r\n\t\tb = 2,\n\t}\n"
	tok := token_next(source, 0, true)
	testing.expect(t, tok.kind == .Operator && source[tok.start:tok.end] == "{")
	tok = token_next(source, tok.end, true)
	testing.expect(t, tok.kind == .Name && source[tok.start:tok.end] == "a")
	tok = token_next(source, tok.end, true)
	testing.expect(t, tok.kind == .Operator && source[tok.start:tok.end] == "=")
	tok = token_next(source, tok.end, true)
	testing.expect(t, tok.kind == .Number && source[tok.start:tok.end] == "1")
	tok = token_next(source, tok.end, true)
	testing.expect(t, tok.kind == .Operator && source[tok.start:tok.end] == ",")
	tok = token_next(source, tok.end, true)
	testing.expect(t, tok.kind == .Name && source[tok.start:tok.end] == "b")

	// Multi-line function head.
	fn_text := "(\n  a,\n  b\n)\n=>\n  a + b"
	close, arrow_end, found := function_head(fn_text, 0, true)
	testing.expect(t, found && fn_text[close] == ')' && arrow_end > close)

	// function_head lookahead is bounded by FUNCTION_HEAD_TOKEN_LIMIT so long
	// parenthesised expressions never cause O(N^2) scanning.
	long_expr: [512]u8
	pos := 0
	long_expr[pos] = '('
	pos += 1
	for i in 0 ..< 80 {
		if i > 0 {
			long_expr[pos] = '+'
			pos += 1
		}
		long_expr[pos] = '1'
		pos += 1
	}
	long_expr[pos] = ')'
	pos += 1
	long_expr[pos] = '='
	pos += 1
	long_expr[pos] = '>'
	pos += 1
	long_expr[pos] = '1'
	pos += 1
	_, _, long_found := function_head(string(long_expr[:pos]), 0, true)
	testing.expect(t, !long_found, "function_head must stop past FUNCTION_HEAD_TOKEN_LIMIT")

	// call_has_placeholder and call_parameter_at_caret with native |>.
	testing.expect(t, pipe_before("a |> where(x = 1)", 5))
	testing.expect(t, !pipe_before("where(t, x = 1)", 0))
	testing.expect(t, call_has_placeholder("a |> f(1, _)", 6))
	testing.expect(t, !call_has_placeholder("a |> f(1, g(_))", 6))
	cname, cparam, cfound := call_parameter_at_caret("a |> where(status = 1)", 15)
	testing.expect(t, cfound && cname == "where" && cparam == 1)
	cname, cparam, cfound = call_parameter_at_caret("a |> where(_, status = 1)", 17)
	testing.expect(t, cfound && cname == "where" && cparam == 1)
}
