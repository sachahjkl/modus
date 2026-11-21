package foundation

import "core:strings"
import "core:testing"

// The reader of the table of the start grant sets reads the tree of the parser: each
// form that a page cannot show as values stops it, with the line. The
// forms that it accepts come last: a row on several lines, a comment above
// a row and after it, a row with no grant and no terms.
@(test)
start_grant_set_table_refuses_another_form :: proc(t: ^testing.T) {
	head :: "package root\n\nGrant :: enum {A, B}\nRow :: struct {name: string, grants: bit_set[Grant], terms: struct {a: int}}\n\n"
	forms := [?]string {
		// A row from a constant: the page cannot name its parts.
		head + "ROW :: Row{name = \"one\"}\nstart_grant_sets := [?]Row {\n\tROW,\n}\n",
		// A row with its type.
		head + "start_grant_sets := [?]Row {\n\tRow{name = \"one\"},\n}\n",
		// A row with no name, and a row with an empty name.
		head + "start_grant_sets := [?]Row {\n\t{grants = {.A}},\n}\n",
		head + "start_grant_sets := [?]Row {\n\t{name = \"\"},\n}\n",
		// A set of grants from a constant, with its type, or a union.
		head + "SET :: bit_set[Grant]{.A}\nstart_grant_sets := [?]Row {\n\t{name = \"one\", grants = SET},\n}\n",
		head + "start_grant_sets := [?]Row {\n\t{name = \"one\", grants = bit_set[Grant]{.A}},\n}\n",
		head + "start_grant_sets := [?]Row {\n\t{name = \"one\", grants = {.A} + {.B}},\n}\n",
		// A field that a row does not have, and a field written twice.
		head + "start_grant_sets := [?]Row {\n\t{name = \"one\", budget = 3},\n}\n",
		head + "start_grant_sets := [?]Row {\n\t{name = \"one\", name = \"two\"},\n}\n",
		// A value in place of a field.
		head + "start_grant_sets := [?]Row {\n\t{\"one\"},\n}\n",
		// A comment inside the terms.
		head + "start_grant_sets := [?]Row {\n\t{name = \"one\", terms = {\n\t\ta = 1, // The reason.\n\t}},\n}\n",
		// A table with no row.
		head + "start_grant_sets := [?]Row {\n}\n",
	}
	for form, index in forms {
		_, refused := start_grant_set_table_read(form, "file.odin", "start_grant_sets")
		testing.expectf(t, strings.has_prefix(refused, "file.odin, line "), "form %d: the reader accepts it, or gives no line: %q", index, refused)
	}
	_, absent := start_grant_set_table_read(head, "file.odin", "start_grant_sets")
	testing.expect(t, strings.contains(absent, "no table"), absent)
	_, broken := start_grant_set_table_read(head + "start_grant_sets := [?]Row {\n", "file.odin", "start_grant_sets")
	testing.expect(t, strings.contains(broken, "the parser of Odin refuses the file"), broken)
	good := head + "start_grant_sets := [?]Row {\n\t// The first line,\n\t// and the second.\n\t{name = \"one\", grants = {\n\t\t.A,\n\t\t.B,\n\t}, terms = {a = 1}}, // Its own.\n\t{name = \"two\"},\n}\n"
	rows, problem := start_grant_set_table_read(good, "file.odin", "start_grant_sets")
	testing.expect_value(t, problem, "")
	testing.expect_value(t, len(rows), 2)
	if len(rows) == 2 {
		testing.expect_value(t, rows[0].name, "one")
		testing.expect_value(t, len(rows[0].grants), 2)
		testing.expect_value(t, rows[0].terms, "a = 1")
		testing.expect_value(t, rows[0].line, 9)
		testing.expect_value(t, rows[0].comment, "The first line,\nand the second.\nIts own.")
		testing.expect_value(t, rows[1].name, "two")
		testing.expect_value(t, len(rows[1].grants), 0)
		testing.expect_value(t, rows[1].terms, "")
		testing.expect_value(t, rows[1].comment, "")
	}
}

@(test)
source_readers_refuse_a_damaged_file :: proc(t: ^testing.T) {
	_, no_end := enumeration_read("Thing :: enum u8 {\n\tA = 0,\n", "file.odin", "Thing")
	testing.expect(t, strings.contains(no_end, "no line \"}\""), no_end)
	_, hexadecimal := enumeration_read("Thing :: enum u8 {\n\tA = 0x10,\n}\n", "file.odin", "Thing")
	testing.expect(t, strings.has_prefix(hexadecimal, "file.odin, line 2:"), hexadecimal)
	_, absent := enumeration_read("Other :: enum u8 {\n\tA,\n}\n", "file.odin", "Thing")
	testing.expect(t, absent != "")
	_, constant := constants_read("ROLE_A :: 1\nROLE_B :: 1 << 3\n", "file.odin", "", {"ROLE_"})
	testing.expect(t, strings.has_prefix(constant, "file.odin, line 2:"), constant)
	_, name := names_table_read("NAMES := [Thing]string {\n\t.A = 7,\n}\n", "file.odin", "NAMES")
	testing.expect(t, strings.has_prefix(name, "file.odin, line 2:"), name)
	_, command := console_commands_read("\tcommand(\"help\", {}, .None, help)\n", "file.odin")
	testing.expect(t, strings.has_prefix(command, "file.odin, line 1:"), command)
	// The arguments after the help: a named argument that command does not
	// take, each malformed one, one named twice, the units by their place
	// after a named argument, a form that names nothing, and optional_last
	// on a command with no parameter. Each names its line.
	wrong_tails := [?]string{
		"\tcommand(\"a\", {.Text}, .None, \"help\", run, speed = 3)\n",
		"\tcommand(\"a\", {.Text}, .None, \"help\", run, forms = .Condition)\n",
		"\tcommand(\"a\", {.Text}, .None, \"help\", run, forms = {Condition})\n",
		"\tcommand(\"a\", {.Text}, .None, \"help\", run, forms = {.Condition)\n",
		"\tcommand(\"a\", {.Text}, .None, \"help\", run, optional_last = yes)\n",
		"\tcommand(\"a\", {.Text}, .None, \"help\", run, optional_last = true, optional_last = true)\n",
		"\tcommand(\"a\", {.Text}, .None, \"help\", run, forms = {.Expression}, {value_kinds.size_in(.Pages)})\n",
		"\tcommand(\"a\", {.Text}, .None, \"help\", run, forms = {.Field_Name})\n",
		"\tcommand(\"a\", {}, .None, \"help\", run, optional_last = true)\n",
		"\tcommand(\"a\", {.Text}, .None, \"help\", 3)\n",
	}
	for text in wrong_tails {
		_, tail_problem := console_commands_read(text, "file.odin")
		testing.expectf(t, strings.has_prefix(tail_problem, "file.odin, line 1:"), "the line %q gave %q", text, tail_problem)
	}
	// The row on line 3 has no name: the reader names its line.
	_, no_name := start_grant_set_table_read("package root\nstart_grant_sets := [?]Row {\n\t{grants = {}},\n}\n", "file.odin", "start_grant_sets")
	testing.expect(t, strings.has_prefix(no_name, "file.odin, line 3:"), no_name)
}

@(test)
source_readers_of_small_files :: proc(t: ^testing.T) {
	members, problem := enumeration_read("Thing :: enum u8 {\n\tA = 4, // The first\n\t// and its second line.\n\tB, // \"//\" in a comment.\n}\n", "file.odin", "Thing")
	testing.expect_value(t, problem, "")
	testing.expect_value(t, len(members), 2)
	if len(members) == 2 {
		testing.expect_value(t, members[0].comment, "The first\nand its second line.")
		testing.expect_value(t, members[1].number, 1)
		testing.expect_value(t, members[1].line, 4)
	}
	constants, constants_problem := constants_read("// Above,\n// two lines.\nROLE_A :: 3 // Its own.\nOTHER :: 0x10\n", "file.odin", "", {"ROLE_"})
	testing.expect_value(t, constants_problem, "")
	testing.expect(t, len(constants) == 1 && constants[0].comment == "Above,\ntwo lines.\nIts own." && constants[0].value == 3)
	commands, commands_problem := console_commands_read("\tcommand(\"say\", {.Text, .None}, .Text, \"a \\\"quoted\\\" help\", say)\n\n\t// Its first line.\n\t//\n\t// - `item`: a list.\n\tcommand(\"hear\", {}, .None, \"help\", hear)\n", "file.odin")
	testing.expect_value(t, commands_problem, "")
	testing.expect_value(t, len(commands), 2)
	if len(commands) == 2 {
		testing.expect_value(t, commands[0].about, "a \"quoted\" help")
		testing.expect_value(t, console_signature(commands[0]), "say(Text, Value) -> Text")
		testing.expect_value(t, commands[0].documentation, "")
		testing.expect_value(t, commands[1].documentation, "Its first line.\n\n- `item`: a list.")
	}
	// The named arguments that command takes: the forms, Field_Names among
	// them, and optional_last, after the units by their place.
	named, named_problem := console_commands_read("\tcommand(\"columns\", {.Table, .None}, .Table, \"help\", table_columns, forms = {.Expression, .Field_Names})\n\tcommand(\"start\", {.Text, .Table}, .None, \"help\", start_process, optional_last = true)\n\tcommand(\"wait\", {.Text, .Integer}, .Table, \"help\", wait_run, {{}, value_kinds.time_in(.Milliseconds)}, forms = {.Condition, .Expression}, optional_last = false)\n", "file.odin")
	testing.expect_value(t, named_problem, "")
	testing.expect_value(t, len(named), 3)
	if len(named) == 3 {
		testing.expect_value(t, console_signature(named[0]), "columns(Table, Field...) -> Table")
		testing.expect_value(t, console_signature(named[1]), "start(Text, [Table])")
		testing.expect_value(t, console_signature(named[2]), "wait(Condition, Integer) -> Table")
		testing.expect(t, named[1].optional_last && !named[0].optional_last && !named[2].optional_last)
	}
	operation := operation_comment_split(Enumeration_Member{name = "Do", comment = "(a, b (or 0)) -> the count. More text."})
	testing.expect_value(t, operation.parameters, "a, b (or 0)")
	testing.expect_value(t, operation.result, "the count")
	testing.expect_value(t, operation.text, "More text.")
	no_result := operation_comment_split(Enumeration_Member{name = "Go", comment = "(process, entry): the first thread."})
	testing.expect_value(t, no_result.result, "")
	testing.expect_value(t, no_result.text, "the first thread.")
}

// The form of an operation can run over two lines of its comment, and its
// text is Markdown after it.
@(test)
comment_markdown_operation_over_lines :: proc(t: ^testing.T) {
	operation := operation_comment_split(Enumeration_Member{name = "Do", comment = "(a,\nb) -> the\ncount.\n**More** text.\n\n- an item"})
	testing.expect_value(t, operation.parameters, "a, b")
	testing.expect_value(t, operation.result, "the count")
	testing.expect_value(t, operation.text, "**More** text.\n\n- an item")
	members, problem := enumeration_read("Thing :: enum u8 {\n\tA = 4, // The first.\n\t//\n\t// - an item\n\t//   that continues\n}\n", "file.odin", "Thing")
	testing.expect_value(t, problem, "")
	if len(members) == 1 {
		testing.expect_value(t, members[0].comment, "The first.\n\n- an item\n  that continues")
	}
}
