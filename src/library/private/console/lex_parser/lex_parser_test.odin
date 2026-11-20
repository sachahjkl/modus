#+build !freestanding
package lex_parser

import "core:fmt"
import "core:strings"
import "core:testing"
import "modus:private/console/console_condition"
import "modus:private/console/console_language"

// The forms of the commands of the tests: `where` takes a condition after
// its table and `facts` a fact name, as in the console; every other
// argument is an expression.
@(private = "file")
test_form_of :: proc "contextless" (data: rawptr, command_name: string, index: int) -> Parameter_Form {
	switch {
	case command_name == "where" && index == 1:
		return .Condition
	case command_name == "facts" && index == 1:
		return .Fact_Name
	}
	return .Expression
}

// parse_of parses a text with the forms of the tests.
@(private = "file")
parse_of :: proc(text: string) -> ^Syntax_Tree {
	return parse_with(text, {form_of = test_form_of})
}

@(private = "file")
parse_with :: proc(text: string, lookup: Form_Lookup) -> ^Syntax_Tree {
	tree := new(Syntax_Tree, context.temp_allocator)
	parse(text, lookup, tree)
	return tree
}

// tree_form writes a tree in a short form that a test compares: a binary
// node in parentheses, a condition in brackets, a fact name in angles, a
// refusal after "!" with the part before it in parentheses.
@(private = "file")
tree_form :: proc(tree: ^Syntax_Tree, index: Node_Index) -> string {
	builder := strings.builder_make(context.temp_allocator)
	node_form_write(&builder, tree, index)
	return strings.to_string(builder)
}

@(private = "file")
node_form_write :: proc(builder: ^strings.Builder, tree: ^Syntax_Tree, index: Node_Index) {
	node := node_at(tree, index)
	if node == nil {
		strings.write_string(builder, "?")
		return
	}
	switch node.kind {
	case .Integer, .Text, .Name:
		strings.write_string(builder, node_text(tree, index))
	case .Call:
		strings.write_string(builder, node_text(tree, index))
		strings.write_string(builder, "(")
		first := true
		for child := node.first_child; child != NO_NODE; child = next_of(tree, child) {
			if !first {
				strings.write_string(builder, ", ")
			}
			first = false
			node_form_write(builder, tree, child)
		}
		strings.write_string(builder, ")")
	case .Negate:
		strings.write_string(builder, "(-")
		node_form_write(builder, tree, node.first_child)
		strings.write_string(builder, ")")
	case .Binary:
		strings.write_string(builder, "(")
		node_form_write(builder, tree, node.first_child)
		fmt.sbprintf(builder, " %s ", OPERATOR_TEXTS[node.operator])
		node_form_write(builder, tree, next_of(tree, node.first_child))
		strings.write_string(builder, ")")
	case .Condition:
		if node.condition_refusal != .None {
			fmt.sbprintf(builder, "[!%v]", node.condition_refusal)
			return
		}
		fmt.sbprintf(builder, "[%s %s ", node.condition_head.field, console_condition.COMPARISON_TEXTS[node.condition_head.comparison])
		node_form_write(builder, tree, node.first_child)
		strings.write_string(builder, "]")
	case .Fact_Name:
		if node.refusal == .Fact_Name_Missing {
			strings.write_string(builder, "<!>")
			return
		}
		fmt.sbprintf(builder, "<%s>", node_text(tree, index))
	case .Refused:
		fmt.sbprintf(builder, "!%v", node.refusal)
		if node.first_child != NO_NODE {
			strings.write_string(builder, "(")
			node_form_write(builder, tree, node.first_child)
			strings.write_string(builder, ")")
		}
	}
}

// The text bounds: 0 bytes, spaces only, the longest line that the console
// runs, one byte past it, and far past it. A text past the bound gives one
// node and no other part.
@(test)
parse_refusals_at_the_text_bounds :: proc(t: ^testing.T) {
	tree := parse_of("")
	testing.expect_value(t, tree.refusal.refusal, Refusal.Line_Ends_Too_Soon)
	testing.expect_value(t, tree.refusal.place, Place{line = 1, column = 1, offset = 0})
	testing.expect_value(t, tree.node_count, 1)
	testing.expect_value(t, tree_form(tree, tree.root), "!Line_Ends_Too_Soon")

	tree = parse_of("   ")
	testing.expect_value(t, tree.refusal.refusal, Refusal.Line_Ends_Too_Soon)
	testing.expect_value(t, tree.refusal.place.column, u32(4))

	for length in ([]int{TEXT_BYTES_MOST + 1, TEXT_BYTES_MOST * 4}) {
		text := strings.repeat("1", length, context.temp_allocator)
		tree = parse_of(text)
		testing.expect_value(t, tree.refusal.refusal, Refusal.Text_Too_Long)
		testing.expect_value(t, tree.refusal.value, u64(length))
		testing.expect_value(t, tree.refusal.place, Place{line = 1, column = TEXT_BYTES_MOST + 1, offset = TEXT_BYTES_MOST})
		testing.expect_value(t, tree.node_count, 1)
		testing.expect_value(t, tree.assigned_name, "")
	}

	// The longest line that runs: "11" and 99 times "+1", 200 bytes.
	longest := strings.concatenate({"11", strings.repeat("+1", (TEXT_BYTES_MOST - 2) / 2, context.temp_allocator)}, context.temp_allocator)
	testing.expect_value(t, len(longest), TEXT_BYTES_MOST)
	tree = parse_of(longest)
	testing.expect_value(t, tree.refusal.refusal, Refusal.None)
	testing.expect_value(t, node_at(tree, tree.root).kind, Node_Kind.Binary)
}

// The memory of the nodes: the densest text of TEXT_BYTES_MOST bytes, one
// node for each byte and the refusal after them, fills it exactly, and is
// refused for its missing operand, not for its memory.
@(test)
parse_fills_the_node_memory_exactly :: proc(t: ^testing.T) {
	densest := strings.repeat("1+", TEXT_BYTES_MOST / 2, context.temp_allocator)
	testing.expect_value(t, len(densest), TEXT_BYTES_MOST)
	tree := parse_of(densest)
	testing.expect_value(t, tree.refusal.refusal, Refusal.Line_Ends_Too_Soon)
	testing.expect_value(t, tree.refusal.place.column, u32(TEXT_BYTES_MOST + 1))
	testing.expect_value(t, tree.node_count, NODE_CAPACITY)

	whole := strings.concatenate({strings.repeat("1+", TEXT_BYTES_MOST / 2 - 1, context.temp_allocator), "1"}, context.temp_allocator)
	tree = parse_of(whole)
	testing.expect_value(t, tree.refusal.refusal, Refusal.None)
	testing.expect_value(t, tree.node_count, len(whole))
}

// The depth: each level of a nesting takes one byte at least, so the bound
// of the text is the bound of the depth. The deepest nesting of each kind
// that fits, then one level more, which no longer fits.
@(test)
parse_nesting_at_the_bound_of_the_text :: proc(t: ^testing.T) {
	// "-": one byte for each level.
	deepest := strings.concatenate({strings.repeat("-", TEXT_BYTES_MOST - 1, context.temp_allocator), "1"}, context.temp_allocator)
	tree := parse_of(deepest)
	testing.expect_value(t, tree.refusal.refusal, Refusal.None)
	depth := 0
	for index := tree.root; node_at(tree, index).kind == .Negate; index = node_at(tree, index).first_child {
		depth += 1
	}
	testing.expect_value(t, depth, TEXT_BYTES_MOST - 1)
	tree = parse_of(strings.concatenate({strings.repeat("-", TEXT_BYTES_MOST, context.temp_allocator), "1"}, context.temp_allocator))
	testing.expect_value(t, tree.refusal.refusal, Refusal.Text_Too_Long)

	// Parentheses: two bytes for each level; a group is no node.
	levels := (TEXT_BYTES_MOST - 1) / 2
	grouped := strings.concatenate({strings.repeat("(", levels, context.temp_allocator), "1", strings.repeat(")", levels, context.temp_allocator)}, context.temp_allocator)
	tree = parse_of(grouped)
	testing.expect_value(t, tree.refusal.refusal, Refusal.None)
	testing.expect_value(t, tree.node_count, 1)
	tree = parse_of(strings.concatenate({strings.repeat("(", levels + 1, context.temp_allocator), "1", strings.repeat(")", levels + 1, context.temp_allocator)}, context.temp_allocator))
	testing.expect_value(t, tree.refusal.refusal, Refusal.Text_Too_Long)

	// Calls: three bytes for each level.
	calls := (TEXT_BYTES_MOST - 1) / 3
	nested := strings.concatenate({strings.repeat("f(", calls, context.temp_allocator), "1", strings.repeat(")", calls, context.temp_allocator)}, context.temp_allocator)
	tree = parse_of(nested)
	testing.expect_value(t, tree.refusal.refusal, Refusal.None)
	testing.expect_value(t, tree.node_count, calls + 1)
	tree = parse_of(strings.concatenate({strings.repeat("f(", calls + 1, context.temp_allocator), "1", strings.repeat(")", calls + 1, context.temp_allocator)}, context.temp_allocator))
	testing.expect_value(t, tree.refusal.refusal, Refusal.Text_Too_Long)

	// An unclosed group at the deepest place: the refusal is the innermost
	// one, after the last byte.
	open := strings.concatenate({strings.repeat("(", TEXT_BYTES_MOST - 1, context.temp_allocator), "1"}, context.temp_allocator)
	tree = parse_of(open)
	testing.expect_value(t, tree.refusal.refusal, Refusal.Close_Parenthesis_Missing)
	testing.expect_value(t, tree.refusal.place.column, u32(TEXT_BYTES_MOST + 1))
	testing.expect_value(t, tree_form(tree, tree.root), "!Close_Parenthesis_Missing(1)")
}

// Each refusal of the text, with its record, its place, and the tree that
// the parse made before it: the console evaluates that part, then fails.
@(test)
parse_refusals_with_their_places :: proc(t: ^testing.T) {
	Case :: struct {
		text:    string,
		refusal: Refusal,
		column:  u32,
		form:    string,
	}
	cases := [?]Case {
		// An unclosed call, and a missing argument.
		{"f(", .Line_Ends_Too_Soon, 3, "f(!Line_Ends_Too_Soon)"},
		{"f(1", .Comma_Or_Close_Missing, 4, "f(1, !Comma_Or_Close_Missing)"},
		{"f(1,", .Line_Ends_Too_Soon, 5, "f(1, !Line_Ends_Too_Soon)"},
		{"f(1,)", .Unexpected, 5, "f(1, !Unexpected)"},
		{"f(,1)", .Unexpected, 3, "f(!Unexpected)"},
		{"f(1 2)", .Comma_Or_Close_Missing, 5, "f(1, !Comma_Or_Close_Missing)"},
		{"f(g(1), h(2) 3)", .Comma_Or_Close_Missing, 14, "f(g(1), h(2), !Comma_Or_Close_Missing)"},
		{"f(1,1,1,1,1,1,1,1,1,1,1,1,1)", .Too_Many_Arguments, 27, "f(1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, !Too_Many_Arguments)"},
		// A byte that starts no value: unknown, a '|' alone, a "|>" that
		// the console did not nest, a line feed, a byte past ASCII.
		{"#", .Unexpected, 1, "!Unexpected"},
		{"1 # 2", .Unexpected, 3, "!Unexpected(1)"},
		{"1 | 2", .Unexpected, 3, "!Unexpected(1)"},
		{"|", .Unexpected, 1, "!Unexpected"},
		{"x |> f", .Unexpected, 3, "!Unexpected(x)"},
		{"1\n+ 2", .Unexpected, 2, "!Unexpected(1)"},
		{"\xc3\xa9", .Unexpected, 1, "!Unexpected"},
		{"= 3", .Unexpected, 1, "!Unexpected"},
		// More after the expression.
		{"1 2", .Unexpected, 3, "!Unexpected(1)"},
		{"f(1) g", .Unexpected, 6, "!Unexpected(f(1))"},
		// A missing operand.
		{"-", .Line_Ends_Too_Soon, 2, "(-!Line_Ends_Too_Soon)"},
		{"1 +", .Line_Ends_Too_Soon, 4, "(1 + !Line_Ends_Too_Soon)"},
		{"2 * ", .Line_Ends_Too_Soon, 5, "(2 * !Line_Ends_Too_Soon)"},
		{"x =", .Line_Ends_Too_Soon, 4, "!Line_Ends_Too_Soon"},
		// Parentheses, texts and numbers.
		{"(1 + 2", .Close_Parenthesis_Missing, 7, "!Close_Parenthesis_Missing((1 + 2))"},
		{"(", .Line_Ends_Too_Soon, 2, "!Line_Ends_Too_Soon"},
		{")", .Unexpected, 1, "!Unexpected"},
		{"\"abc", .Text_Without_End_Quote, 1, "!Text_Without_End_Quote"},
		{"1 + \"abc", .Text_Without_End_Quote, 5, "(1 + !Text_Without_End_Quote)"},
		{"9223372036854775808", .Number_Too_Large, 1, "!Number_Too_Large"},
		{"1 - 99999999999999999999", .Number_Too_Large, 5, "(1 - !Number_Too_Large)"},
		// A fact name: none, or a value in its place.
		{"facts(t, 3)", .Fact_Name_Missing, 10, "facts(t, <!>)"},
		{"facts(t, )", .Fact_Name_Missing, 10, "facts(t, <!>)"},
		{"facts(t,", .Fact_Name_Missing, 9, "facts(t, <!>)"},
		{"facts(t, a.B c)", .Comma_Or_Close_Missing, 14, "facts(t, <a.B>, !Comma_Or_Close_Missing)"},
		// The field and the operator of a condition.
		{"where(t, = 3)", .Condition_Head_Refused, 10, "where(t, [!No_Field])"},
		{"where(t,", .Condition_Head_Refused, 9, "where(t, [!No_Field])"},
		{"where(t, level)", .Condition_Head_Refused, 10, "where(t, [!No_Operator])"},
		{"where(t, a == 1)", .Condition_Head_Refused, 10, "where(t, [!Double_Equal])"},
		{"where(t, a ! 1)", .Condition_Head_Refused, 10, "where(t, [!Lone_Bang])"},
		{"where(t, a <)", .Condition_Head_Refused, 10, "where(t, [!No_Value])"},
		{"where(t, a < ", .Condition_Head_Refused, 10, "where(t, [!No_Value])"},
		// The value of a condition.
		{"where(t, a = 1", .Comma_Or_Close_Missing, 15, "where(t, [a = 1], !Comma_Or_Close_Missing)"},
		{"where(t, a = (1", .Close_Parenthesis_Missing, 16, "where(t, [a = !Close_Parenthesis_Missing(1)])"},
	}
	for item in cases {
		tree := parse_of(item.text)
		form := tree_form(tree, tree.root)
		testing.expectf(t, tree.refusal.refusal == item.refusal && tree.refusal.place.line == 1 && tree.refusal.place.column == item.column && form == item.form, "%q: %v at line %d, column %d, %q; not %v at column %d, %q", item.text, tree.refusal.refusal, tree.refusal.place.line, tree.refusal.place.column, form, item.refusal, item.column, item.form)
		testing.expectf(t, tree.refusal.place == place_of_offset(item.text, int(tree.refusal.place.offset)), "%q: the offset %d is not at its line and column", item.text, tree.refusal.place.offset)
	}
}

// The record of a refusal holds what its member says: the bytes of a text
// too long, the refusal of the head of a condition.
@(test)
parse_refusal_values :: proc(t: ^testing.T) {
	tree := parse_of("where(t, a == 1)")
	testing.expect_value(t, tree.refusal.value, u64(console_condition.Refusal.Double_Equal))
	tree = parse_of("where(t, level)")
	testing.expect_value(t, tree.refusal.value, u64(console_condition.Refusal.No_Operator))
	tree = parse_of("1 + 2")
	testing.expect_value(t, tree.refusal, Refusal_Record{})
}

// The form of an argument comes from the lookup: with no lookup, `where`
// takes expressions, so `=` after a name ends the argument.
@(test)
parse_reads_the_form_of_the_lookup :: proc(t: ^testing.T) {
	tree := parse_with("where(t, level = 1)", {})
	testing.expect_value(t, tree.refusal.refusal, Refusal.Comma_Or_Close_Missing)
	testing.expect_value(t, tree.refusal.place.column, u32(16))
	testing.expect_value(t, tree_form(tree, tree.root), "where(t, level, !Comma_Or_Close_Missing)")
	tree = parse_with("facts(t, a.B)", {})
	testing.expect_value(t, tree_form(tree, tree.root), "facts(t, a.B)")
	testing.expect_value(t, node_at(tree, next_of(tree, node_at(tree, tree.root).first_child)).kind, Node_Kind.Name)
}

// place_of_offset: a negative offset, the first byte, a line feed, the
// byte after it, the end, and past the end.
@(test)
place_of_each_offset :: proc(t: ^testing.T) {
	text := "a\nbc"
	testing.expect_value(t, place_of_offset(text, -1), Place{line = 1, column = 1, offset = 0})
	testing.expect_value(t, place_of_offset(text, 0), Place{line = 1, column = 1, offset = 0})
	testing.expect_value(t, place_of_offset(text, 1), Place{line = 1, column = 2, offset = 1})
	testing.expect_value(t, place_of_offset(text, 2), Place{line = 2, column = 1, offset = 2})
	testing.expect_value(t, place_of_offset(text, 4), Place{line = 2, column = 3, offset = 4})
	testing.expect_value(t, place_of_offset(text, 5), Place{line = 2, column = 3, offset = 4})
	testing.expect_value(t, place_of_offset("", 0), Place{line = 1, column = 1, offset = 0})
}

// node_at and next_of refuse an index that names no node.
@(test)
node_indexes_out_of_the_tree :: proc(t: ^testing.T) {
	tree := parse_of("f(1)")
	testing.expect(t, node_at(tree, NO_NODE) == nil)
	testing.expect(t, node_at(tree, Node_Index(tree.node_count)) == nil)
	testing.expect(t, node_at(tree, Node_Index(max(i32))) == nil)
	testing.expect(t, node_at(tree, Node_Index(min(i32))) == nil)
	testing.expect_value(t, next_of(tree, NO_NODE), NO_NODE)
	testing.expect_value(t, node_text(tree, NO_NODE), "")
	testing.expect(t, node_at(tree, Node_Index(tree.node_count - 1)) != nil)
}

// The tree of each form of a line of the console.
@(test)
parse_trees_of_each_form :: proc(t: ^testing.T) {
	Case :: struct {
		text: string,
		form: string,
	}
	cases := [?]Case {
		// Literals, names and variables.
		{"42", "42"},
		{"0", "0"},
		{"9223372036854775807", "9223372036854775807"},
		{"\"a b\"", "\"a b\""},
		{"\"\"", "\"\""},
		{"x", "x"},
		{"monitor.count", "monitor.count"},
		{"r.value", "r.value"},
		// Calls and nested calls.
		{"f()", "f()"},
		{"f( )", "f()"},
		{"f(1, \"x\", y)", "f(1, \"x\", y)"},
		{"f(g(1), h(k(2)))", "f(g(1), h(k(2)))"},
		{"monitor.count(\"notes\")", "monitor.count(\"notes\")"},
		{"f(1,1,1,1,1,1,1,1,1,1,1,1)", "f(1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1)"},
		// Operators: their priority and their order.
		{"1 + 2 * 3", "(1 + (2 * 3))"},
		{"1 - 2 - 3", "((1 - 2) - 3)"},
		{"(1 + 2) * 3", "((1 + 2) * 3)"},
		{"7 % 4 / 2", "((7 % 4) / 2)"},
		{"-x", "(-x)"},
		{"--1", "(-(-1))"},
		{"2 * -3", "(2 * (-3))"},
		{"\"a\" + \"b\"", "(\"a\" + \"b\")"},
		{"rows(t) - rows(u)", "(rows(t) - rows(u))"},
		// Conditions, fact names and tables.
		{"where(t, level = Warning)", "where(t, [level = Warning])"},
		{"where(t, block >= 12 + 1)", "where(t, [block >= (12 + 1)])"},
		{"where(t, name != \"x\")", "where(t, [name != \"x\"])"},
		{"where(t, key > -1)", "where(t, [key > (-1)])"},
		{"where(t, a < b)", "where(t, [a < b])"},
		{"facts(log.records(), storage.Bad_Block)", "facts(log.records(), <storage.Bad_Block>)"},
		{"columns(where(t, a = 1), \"x y\")", "columns(where(t, [a = 1]), \"x y\")"},
		{"join(columns(a(), \"h\"), columns(b(), \"h n\"), \"h\")", "join(columns(a(), \"h\"), columns(b(), \"h n\"), \"h\")"},
	}
	for item in cases {
		tree := parse_of(item.text)
		form := tree_form(tree, tree.root)
		testing.expectf(t, tree.refusal.refusal == .None && form == item.form && tree.assigned_name == "", "%q: %v %q, not %q", item.text, tree.refusal.refusal, form, item.form)
	}
	tree := parse_of("9223372036854775807")
	testing.expect_value(t, node_at(tree, tree.root).integer, max(i64))
}

// A variable that keeps the value of a line, and the lines that are no
// assignment.
@(test)
parse_assignments :: proc(t: ^testing.T) {
	tree := parse_of("t = rows(x)")
	testing.expect_value(t, tree.refusal.refusal, Refusal.None)
	testing.expect_value(t, tree.assigned_name, "t")
	testing.expect_value(t, tree_form(tree, tree.root), "rows(x)")
	testing.expect_value(t, node_at(tree, tree.root).place, Place{line = 1, column = 5, offset = 4})

	tree = parse_of("x")
	testing.expect_value(t, tree.assigned_name, "")
	testing.expect_value(t, tree_form(tree, tree.root), "x")
	tree = parse_of("a.b = 1")
	testing.expect_value(t, tree.assigned_name, "a.b")
}

// The place of each node, and what a condition keeps for the member of a
// status: its value, and whether the first token is the whole value.
@(test)
parse_places_and_conditions :: proc(t: ^testing.T) {
	tree := parse_of("f(1,  x)")
	call := node_at(tree, tree.root)
	testing.expect_value(t, call.place, Place{line = 1, column = 1, offset = 0})
	testing.expect_value(t, node_text(tree, tree.root), "f")
	first := call.first_child
	testing.expect_value(t, node_at(tree, first).place.column, u32(3))
	testing.expect_value(t, node_at(tree, next_of(tree, first)).place.column, u32(7))
	testing.expect_value(t, next_of(tree, next_of(tree, first)), NO_NODE)

	Case :: struct {
		text:         string,
		member_alone: bool,
	}
	cases := [?]Case {
		{"where(t, level = Warning)", true},
		{"where(t, level = Warning )", true},
		{"where(t, level = Warning, 1)", true},
		{"where(t, level = Warning + 1)", false},
		{"where(t, level = Warning(1))", false},
		{"where(t, level = \"Warning\")", true},
	}
	for item in cases {
		tree = parse_of(item.text)
		condition := node_at(tree, next_of(tree, node_at(tree, tree.root).first_child))
		testing.expectf(t, condition != nil && condition.kind == .Condition && condition.member_alone == item.member_alone, "%q: member_alone is not %v", item.text, item.member_alone)
		if condition != nil {
			testing.expect_value(t, condition.condition_head.field, "level")
			testing.expect_value(t, condition.condition_head.comparison, console_condition.Comparison.Equal)
			testing.expect_value(t, condition.place.column, u32(10))
			testing.expect_value(t, node_text(tree, next_of(tree, node_at(tree, tree.root).first_child)), "level =")
		}
	}
}

// The parser reads the nested form of a line with "|>": its tree is the
// tree of the same line with calls in calls.
@(test)
parse_nested_forms_of_the_pipe :: proc(t: ^testing.T) {
	memory: [TEXT_BYTES_MOST]u8
	stages: [console_language.PIPE_STAGE_CAPACITY]console_language.Pipe_Stage
	Case :: struct {
		piped:  string,
		nested: string,
	}
	cases := [?]Case {
		{"processes() |> where(name = \"server\")", "where(processes(), name = \"server\")"},
		{"x |> h |> g(1) |> f", "f(g(h(x), 1))"},
		{"1 + 2 |> text", "text(1 + 2)"},
		{"t = processes() |> rows", "t = rows(processes())"},
		{"where(x |> f, a = 1)", "where(f(x), a = 1)"},
		{"log.records() |> facts(storage.Bad_Block) |> where(block = 12)", "where(facts(log.records(), storage.Bad_Block), block = 12)"},
	}
	for item in cases {
		form := console_language.pipe_nested_form(item.piped, console_language.expression_start(item.piped), memory[:], stages[:])
		if !testing.expectf(t, form.refusal == .None, "%q: %v", item.piped, form.refusal) {
			continue
		}
		piped := parse_of(form.nested)
		nested := parse_of(item.nested)
		testing.expectf(t, piped.refusal.refusal == .None && nested.refusal.refusal == .None, "%q: %v, %v", item.piped, piped.refusal.refusal, nested.refusal.refusal)
		testing.expect_value(t, tree_form(piped, piped.root), tree_form(nested, nested.root))
		testing.expect_value(t, piped.assigned_name, nested.assigned_name)
	}
}
