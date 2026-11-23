#+build !freestanding
package lex_parser

import "core:fmt"
import "core:strings"
import "core:testing"
import "modus:console_condition"
import "modus:console_language"

// The forms of the commands of the tests: `where` takes a condition after
// its table, `facts` a fact name and `columns` field names, as in the
// console; every other argument is an expression.
@(private = "file")
test_form_of :: proc "contextless" (data: rawptr, command_name: string, index: int) -> Parameter_Form {
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

// children_write writes a list of nodes, separated.
@(private = "file")
children_write :: proc(builder: ^strings.Builder, tree: ^Syntax_Tree, first: Node_Index, separator: string) {
	for child := first; child != NO_NODE; child = next_of(tree, child) {
		if child != first {
			strings.write_string(builder, separator)
		}
		node_form_write(builder, tree, child)
	}
}

@(private = "file")
node_form_write :: proc(builder: ^strings.Builder, tree: ^Syntax_Tree, index: Node_Index) {
	node := node_at(tree, index)
	if node == nil {
		strings.write_string(builder, "?")
		return
	}
	switch node.kind {
	case .Integer, .Text, .Member, .Parameter, .Hash, .Boolean:
		strings.write_string(builder, node_text(tree, index))
	case .If:
		strings.write_string(builder, "if(")
		children_write(builder, tree, node.first_child, "; ")
		strings.write_string(builder, ")")
	case .Field_Select:
		node_form_write(builder, tree, node.first_child)
		fmt.sbprintf(builder, ".%s", node_text(tree, index))
	case .Name:
		// A name that a let or a function binds is marked with '@'.
		if node.binding != NO_NODE {
			strings.write_string(builder, "@")
		}
		strings.write_string(builder, node_text(tree, index))
	case .Function:
		// fn(x, y => body): the parameters, then the body.
		strings.write_string(builder, "fn(")
		first := true
		for child := node.first_child; child != NO_NODE; child = next_of(tree, child) {
			// The parameters and their refusals are before the "=>".
			child_node := node_at(tree, child)
			if child_node.place.offset > node.place.offset {
				strings.write_string(builder, " => ")
			} else if !first {
				strings.write_string(builder, ", ")
			}
			first = false
			node_form_write(builder, tree, child)
		}
		strings.write_string(builder, ")")
	case .List_Literal:
		strings.write_string(builder, "[")
		children_write(builder, tree, node.first_child, ", ")
		strings.write_string(builder, "]")
	case .Record_Literal:
		strings.write_string(builder, "#{")
		children_write(builder, tree, node.first_child, ", ")
		strings.write_string(builder, "}")
	case .Literal_Field, .Named_Argument, .Let_Binding:
		fmt.sbprintf(builder, "%s = ", node_text(tree, index))
		node_form_write(builder, tree, node.first_child)
	case .Let:
		strings.write_string(builder, "let(")
		children_write(builder, tree, node.first_child, "; ")
		strings.write_string(builder, ")")
	case .Call:
		// A call of a name that a let or a function binds is marked too.
		if node.binding != NO_NODE {
			strings.write_string(builder, "@")
		}
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
	case .Field_Names:
		if node.refusal == .Field_Name_Missing {
			fmt.sbprintf(builder, "{{%s!}}", node_text(tree, index))
			return
		}
		fmt.sbprintf(builder, "{{%s}}", node_text(tree, index))
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
		// Field names: none, none after a ",", a text in the old form, two
		// names with no ",".
		{"columns(t,", .Field_Name_Missing, 11, "columns(t, {!})"},
		{"columns(t, )", .Field_Name_Missing, 12, "columns(t, {!})"},
		{"columns(t, a,)", .Field_Name_Missing, 14, "columns(t, {a,!})"},
		{"columns(t, \"a b\")", .Field_Name_Missing, 12, "columns(t, {!})"},
		{"columns(t, a b)", .Comma_Or_Close_Missing, 14, "columns(t, {a }, !Comma_Or_Close_Missing)"},
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
// takes expressions, so `level = 1` is a named argument, not a condition.
@(test)
parse_reads_the_form_of_the_lookup :: proc(t: ^testing.T) {
	tree := parse_with("where(t, level = 1)", {})
	testing.expect_value(t, tree.refusal.refusal, Refusal.None)
	testing.expect_value(t, tree_form(tree, tree.root), "where(t, level = 1)")
	testing.expect_value(t, node_at(tree, next_of(tree, node_at(tree, tree.root).first_child)).kind, Node_Kind.Named_Argument)
	tree = parse_of("where(t, level = 1)")
	testing.expect_value(t, tree_form(tree, tree.root), "where(t, [level = 1])")
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
		{"columns(where(t, a = 1), x, y)", "columns(where(t, [a = 1]), {x, y})"},
		{"join(columns(a(), h), columns(b(), h, n), \"h\")", "join(columns(a(), {h}), columns(b(), {h, n}), \"h\")"},
		{"columns(t,name,slot)", "columns(t, {name,slot})"},
		{"columns(t, name , slot )", "columns(t, {name , slot })"},
		// Members of an enum, by place and by name.
		{".french", ".french"},
		{"settings.set(keyboard_layout = .french)", "settings.set(keyboard_layout = .french)"},
		{"f(.a_1, b = .c)", "f(.a_1, b = .c)"},
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

// `let x = value` with nothing after the value is the assignment
// `x = value`; each other form of `let` is the expression, with its own
// refusals in their places, as if the first reading had not happened.
@(test)
parse_let_assignments :: proc(t: ^testing.T) {
	Case :: struct {
		text:     string,
		assigned: string,
		refusal:  Refusal,
		column:   u32,
		form:     string,
	}
	cases := []Case {
		// The refusals first: no name, a word of Lex, "==", no value, an
		// open list, a second binding, a value then more text.
		{"let", "", .Let_Name_Missing, 4, "let(!Let_Name_Missing)"},
		{"let = 1", "", .Word_As_Name, 1, "!Word_As_Name"},
		{"let in = 1", "", .Word_As_Name, 5, "let(!Word_As_Name)"},
		{"let _ = 1", "", .Word_As_Name, 5, "let(!Word_As_Name)"},
		{"let x == 1", "", .Let_Equal_Missing, 7, "let(!Let_Equal_Missing)"},
		{"let x =", "", .Line_Ends_Too_Soon, 8, "let(x = !Line_Ends_Too_Soon)"},
		{"let x = [1, 2", "", .List_Close_Missing, 14, ""},
		{"let a = 1, b = 2", "", .Let_In_Missing, 17, "let(a = 1; b = 2; !Let_In_Missing)"},
		{"let a = 1 a", "", .Let_In_Missing, 11, "let(a = 1; !Let_In_Missing)"},
		// The expression let, which keeps its meaning.
		{"let a = 1 in a", "", .None, 0, "let(a = 1; @a)"},
		// A name that starts with let is a name.
		{"letter = 1", "letter", .None, 0, "1"},
		// The assignments.
		{"let a = 1", "a", .None, 0, "1"},
		{"let  x   =  2 * 3 ", "x", .None, 0, "(2 * 3)"},
		{"let x = [1, 2, 3]", "x", .None, 0, ""},
	}
	for item in cases {
		tree := parse_of(item.text)
		form := tree_form(tree, tree.root)
		testing.expectf(t, tree.refusal.refusal == item.refusal && tree.assigned_name == item.assigned, "%q: %v, assigned %q; not %v, %q", item.text, tree.refusal.refusal, tree.assigned_name, item.refusal, item.assigned)
		if item.refusal != .None {
			testing.expectf(t, tree.refusal.place.column == item.column, "%q: column %d, not %d", item.text, tree.refusal.place.column, item.column)
		}
		if item.form != "" {
			testing.expectf(t, form == item.form, "%q: %q, not %q", item.text, form, item.form)
		}
	}
	// The assigned value keeps its places in the line.
	tree := parse_of("let x = [1, 2, 3]")
	testing.expect_value(t, node_at(tree, tree.root).kind, Node_Kind.List_Literal)
	testing.expect_value(t, node_at(tree, tree.root).place, Place{line = 1, column = 9, offset = 8})
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
		// The placeholder, and the pieces of the forms of records.
		{"x |> f(b, _)", "f(b, x)"},
		{"x |> f(n = _)", "f(n = x)"},
		{"x |> f(_, y) |> g(1, _)", "g(1, f(x, y))"},
		{"f(x |> g(_), y)", "f(g(x), y)"},
		{"f(n = x |> g)", "f(n = g(x))"},
		{"{a = x |> g, b = 2}", "{a = g(x), b = 2}"},
		{"x |> f({a = 1, b = 2})", "f(x, {a = 1, b = 2})"},
		{"let a = x |> g in a |> h", "let a = g(x) in h(a)"},
		{"x |> f(let a = 1, b = 2 in a)", "f(x, let a = 1, b = 2 in a)"},
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

// Each refusal of the forms of records, at its place, with the tree before
// it: a literal, a named argument, a let, `with` and the words of Lex.
@(test)
parse_refusals_of_the_forms :: proc(t: ^testing.T) {
	Case :: struct {
		text:    string,
		refusal: Refusal,
		column:  u32,
		form:    string,
	}
	cases := [?]Case {
		// A record literal: no name, no "=", no end, a field twice.
		{"{", .Literal_Name_Missing, 2, "#{!Literal_Name_Missing}"},
		{"{= 1}", .Literal_Name_Missing, 2, "#{!Literal_Name_Missing}"},
		{"{1}", .Literal_Name_Missing, 2, "#{!Literal_Name_Missing}"},
		{"{a = 1,}", .Literal_Name_Missing, 8, "#{a = 1, !Literal_Name_Missing}"},
		{"{a}", .Literal_Equal_Missing, 3, "#{!Literal_Equal_Missing}"},
		{"{a 1}", .Literal_Equal_Missing, 4, "#{!Literal_Equal_Missing}"},
		{"{a == 1}", .Literal_Equal_Missing, 4, "#{!Literal_Equal_Missing}"},
		{"{a = 1", .Literal_Close_Missing, 7, "#{a = 1, !Literal_Close_Missing}"},
		{"{a = 1 b = 2}", .Literal_Close_Missing, 8, "#{a = 1, !Literal_Close_Missing}"},
		{"{a = }", .Unexpected, 6, "#{a = !Unexpected}"},
		{"{a = 1, a = 2}", .Literal_Field_Twice, 9, "#{a = 1, !Literal_Field_Twice}"},
		{"{_ = 1}", .Word_As_Name, 2, "#{!Word_As_Name}"},
		{"{in = 1}", .Word_As_Name, 2, "#{!Word_As_Name}"},
		// Named arguments: a name twice, an argument with no name after
		// one, a word of Lex as a name; "==" is no "=".
		{"f(a = 1, 2)", .Positional_After_Named, 10, "f(a = 1, !Positional_After_Named)"},
		{"f(a = 1, a = 2)", .Named_Argument_Twice, 10, "f(a = 1, !Named_Argument_Twice)"},
		{"f(_ = 1)", .Word_As_Name, 3, "f(!Word_As_Name)"},
		{"f(with = 1)", .Word_As_Name, 3, "f(!Word_As_Name)"},
		{"f(a == 1)", .Comma_Or_Close_Missing, 5, "f(a, !Comma_Or_Close_Missing)"},
		{"f(a = )", .Unexpected, 7, "f(a = !Unexpected)"},
		// A member: a "." with no name after it, a digit or a space after
		// the ".", and a second "." after the name.
		{"f(a = .)", .Unexpected, 7, "f(a = !Unexpected)"},
		{"f(.1)", .Unexpected, 3, "f(!Unexpected)"},
		{"f(. a)", .Unexpected, 3, "f(!Unexpected)"},
		{".", .Unexpected, 1, "!Unexpected"},
		{"f(.a.b)", .Comma_Or_Close_Missing, 5, "f(.a, !Comma_Or_Close_Missing)"},
		{"f(a = .french", .Comma_Or_Close_Missing, 14, "f(a = .french, !Comma_Or_Close_Missing)"},
		// A let: no name, no "=", no "in", a name twice, no body.
		{"let", .Let_Name_Missing, 4, "let(!Let_Name_Missing)"},
		{"let 1 = 2 in 3", .Let_Name_Missing, 5, "let(!Let_Name_Missing)"},
		{"let a", .Let_Equal_Missing, 6, "let(!Let_Equal_Missing)"},
		{"let a = 1, b = 2", .Let_In_Missing, 17, "let(a = 1; b = 2; !Let_In_Missing)"},
		{"let a = 1 a", .Let_In_Missing, 11, "let(a = 1; !Let_In_Missing)"},
		{"let a = 1, a = 2 in a", .Let_Name_Twice, 12, "let(a = 1; !Let_Name_Twice)"},
		{"let in = 1 in 2", .Word_As_Name, 5, "let(!Word_As_Name)"},
		{"let a = 1 in", .Line_Ends_Too_Soon, 13, "let(a = 1; !Line_Ends_Too_Soon)"},
		// `with` with no right side, and the words where a value or a
		// variable is read.
		{"r with", .Line_Ends_Too_Soon, 7, "(r with !Line_Ends_Too_Soon)"},
		{"with r", .Word_As_Name, 1, "!Word_As_Name"},
		{"_", .Word_As_Name, 1, "!Word_As_Name"},
		{"in", .Word_As_Name, 1, "!Word_As_Name"},
		{"1 + _", .Word_As_Name, 5, "(1 + !Word_As_Name)"},
		{"_ = 1", .Word_As_Name, 1, "!Word_As_Name"},
		{"let = 1", .Word_As_Name, 1, "!Word_As_Name"},
		{"with = 1", .Word_As_Name, 1, "!Word_As_Name"},
	}
	for item in cases {
		tree := parse_of(item.text)
		form := tree_form(tree, tree.root)
		testing.expectf(t, tree.refusal.refusal == item.refusal && tree.refusal.place.column == item.column && form == item.form, "%q: %v at column %d, %q; not %v at column %d, %q", item.text, tree.refusal.refusal, tree.refusal.place.column, form, item.refusal, item.column, item.form)
		testing.expectf(t, tree.refusal.place == place_of_offset(item.text, int(tree.refusal.place.offset)), "%q: the offset %d is not at its line and column", item.text, tree.refusal.place.offset)
	}
	// The record names the word or the name that it refuses.
	tree := parse_of("{a = 1, a = 2}")
	testing.expect_value(t, node_text(tree, next_of(tree, node_at(tree, tree.root).first_child)), "a")
	tree = parse_of("let _ = 1 in 2")
	testing.expect_value(t, tree.refusal.refusal, Refusal.Word_As_Name)
	testing.expect_value(t, node_text(tree, node_at(tree, tree.root).first_child), "_")
}

// The edges of a literal: none of its fields, the most fields that a line
// holds, and the deepest nesting of literals, then one more level.
@(test)
parse_literal_edges :: proc(t: ^testing.T) {
	tree := parse_of("{}")
	testing.expect_value(t, tree.refusal.refusal, Refusal.None)
	testing.expect_value(t, tree_form(tree, tree.root), "#{}")
	testing.expect_value(t, node_at(tree, tree.root).first_child, NO_NODE)
	tree = parse_of("{ }")
	testing.expect_value(t, tree_form(tree, tree.root), "#{}")

	// Fields of two letters, "xy=1," each: 39 in a line of 196 bytes.
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, "{")
	most := (TEXT_BYTES_MOST - 2) / 5
	for field in 0 ..< most {
		if field > 0 {
			strings.write_string(&builder, ",")
		}
		strings.write_byte(&builder, u8('a' + field / 26))
		strings.write_byte(&builder, u8('a' + field % 26))
		strings.write_string(&builder, "=1")
	}
	strings.write_string(&builder, "}")
	widest := strings.to_string(builder)
	testing.expect(t, len(widest) <= TEXT_BYTES_MOST)
	tree = parse_of(widest)
	testing.expect_value(t, tree.refusal.refusal, Refusal.None)
	fields := 0
	for field := node_at(tree, tree.root).first_child; field != NO_NODE; field = next_of(tree, field) {
		fields += 1
	}
	testing.expect_value(t, fields, most)

	// "{a=" and "}": four bytes for each level.
	levels := (TEXT_BYTES_MOST - 1) / 4
	deepest := strings.concatenate({strings.repeat("{a=", levels, context.temp_allocator), "1", strings.repeat("}", levels, context.temp_allocator)}, context.temp_allocator)
	tree = parse_of(deepest)
	testing.expect_value(t, tree.refusal.refusal, Refusal.None)
	depth := 0
	for index := tree.root; node_at(tree, index).kind == .Record_Literal; index = node_at(tree, node_at(tree, index).first_child).first_child {
		depth += 1
	}
	testing.expect_value(t, depth, levels)
	tree = parse_of(strings.concatenate({strings.repeat("{a=", levels + 1, context.temp_allocator), "1", strings.repeat("}", levels + 1, context.temp_allocator)}, context.temp_allocator))
	testing.expect_value(t, tree.refusal.refusal, Refusal.Text_Too_Long)
}

// The trees of the forms of records, and the binding of each name that a
// let reads.
@(test)
parse_trees_of_the_forms :: proc(t: ^testing.T) {
	Case :: struct {
		text: string,
		form: string,
	}
	cases := [?]Case {
		// Record literals.
		{"{a = 1}", "#{a = 1}"},
		{"{ a = 1 , b = 2 }", "#{a = 1, b = 2}"},
		{"{a = 1, b = \"x\", c = f(2)}", "#{a = 1, b = \"x\", c = f(2)}"},
		{"{a = {b = 1}}", "#{a = #{b = 1}}"},
		{"f({x = 1}, 2)", "f(#{x = 1}, 2)"},
		// Named arguments.
		{"f(x, by = 2)", "f(x, by = 2)"},
		{"f(a = 1, b = {c = 2})", "f(a = 1, b = #{c = 2})"},
		{"sum_values(x_y)", "sum_values(x_y)"},
		// `with`: the lowest priority, from the left.
		{"r with {width = 10}", "(r with #{width = 10})"},
		{"r with {a = 1} with {b = 2}", "((r with #{a = 1}) with #{b = 2})"},
		{"r with s + t", "(r with (s + t))"},
		{"withdraw(x)", "withdraw(x)"},
		// let: a name of a binding is bound, a later one too, and an inner
		// let hides an outer one.
		{"let a = 1 in a + 1", "let(a = 1; (@a + 1))"},
		{"let a = 1, b = a + 1 in {x = a, y = b}", "let(a = 1; b = (@a + 1); #{x = @a, y = @b})"},
		{"let a = b, b = 1 in a", "let(a = @b; b = 1; @a)"},
		{"let s = {x = 1} in s.x", "let(s = #{x = 1}; @s.x)"},
		{"f(let a = 1 in a, 2)", "f(let(a = 1; @a), 2)"},
		{"let a = 1 in f(a = a)", "let(a = 1; f(a = @a))"},
		{"let a = 1 in b", "let(a = 1; b)"},
		{"let a = a in a", "let(a = @a; @a)"},
	}
	for item in cases {
		tree := parse_of(item.text)
		form := tree_form(tree, tree.root)
		testing.expectf(t, tree.refusal.refusal == .None && form == item.form, "%q: %v %q, not %q", item.text, tree.refusal.refusal, form, item.form)
	}

	// An inner let hides an outer one: the name reads the inner binding.
	tree := parse_of("let a = 1 in let a = 2 in a")
	testing.expect_value(t, tree_form(tree, tree.root), "let(a = 1; let(a = 2; @a))")
	inner := next_of(tree, node_at(tree, tree.root).first_child)
	inner_binding := node_at(tree, inner).first_child
	body := next_of(tree, inner_binding)
	testing.expect_value(t, node_at(tree, body).binding, inner_binding)

	// An assignment of a let, and its places.
	tree = parse_of("x = let a = 1 in a")
	testing.expect_value(t, tree.assigned_name, "x")
	testing.expect_value(t, node_at(tree, tree.root).kind, Node_Kind.Let)
	testing.expect_value(t, node_at(tree, tree.root).place.column, u32(5))
	tree = parse_of("{width = 1}")
	field := node_at(tree, tree.root).first_child
	testing.expect_value(t, node_at(tree, field).place.column, u32(2))
	testing.expect_value(t, node_at(tree, node_at(tree, field).first_child).place.column, u32(10))
}

// The names of a module file that the palette puts in a line: each text
// that adds a call, an argument, a text or a member to the line is no name,
// and neither is a word of Lex, a dotted name or a name that starts with a
// digit. A module file with such a name gives no command.
@(test)
a_name_of_a_module_file_adds_nothing_to_a_line :: proc(t: ^testing.T) {
	injected := []string {
		"a=shutdown(),b", "a, b", "b)", "f(", "x = .y", "a\"", "\"", "a b", " a", "a ", "a.b", ".a", "a-b", "a+b",
		"a{", "a}", "a:b", "a|>b", "a<b", "a!", "1a", "9", "", "_", "let", "in", "with", "é", "a\x00", "a\n",
		"a[", "a]", "a=>b", "(a)=>b",
	}
	for name in injected {
		testing.expectf(t, !name_valid(name), "%q is refused as a name", name)
	}
	for name in ([]string{"a", "set", "keyboard_layout", "_hidden", "value_9", "A1", "letter", "inner", "within"}) {
		testing.expectf(t, name_valid(name), "%q is a name", name)
	}
}

// Each refusal of a function and of a list, at its place, with the tree
// before it.
@(test)
parse_refusals_of_functions_and_lists :: proc(t: ^testing.T) {
	Case :: struct {
		text:    string,
		refusal: Refusal,
		column:  u32,
		form:    string,
	}
	cases := [?]Case {
		// A parameter that is no name, a word of Lex, a name with a dot, a
		// name twice, no ',' between two names, 13 parameters.
		{"(1) => 2", .Parameter_Name_Missing, 2, "fn(!Parameter_Name_Missing)"},
		{"(x,) => 1", .Parameter_Name_Missing, 4, "fn(x, !Parameter_Name_Missing)"},
		{"(, x) => 1", .Parameter_Name_Missing, 2, "fn(!Parameter_Name_Missing)"},
		{"(a.b) => 1", .Parameter_Name_Missing, 2, "fn(!Parameter_Name_Missing)"},
		{"(\"x\") => 1", .Parameter_Name_Missing, 2, "fn(!Parameter_Name_Missing)"},
		{"(let) => 1", .Word_As_Name, 2, "fn(!Word_As_Name)"},
		{"(_) => 1", .Word_As_Name, 2, "fn(!Word_As_Name)"},
		{"(x, with) => 1", .Word_As_Name, 5, "fn(x, !Word_As_Name)"},
		{"(x, x) => 1", .Parameter_Twice, 5, "fn(x, !Parameter_Twice)"},
		{"(x, y, x) => 1", .Parameter_Twice, 8, "fn(x, y, !Parameter_Twice)"},
		{"(x y) => 1", .Comma_Or_Close_Missing, 4, "fn(x, !Comma_Or_Close_Missing)"},
		{"(a,b,c,d,e,f,g,h,i,j,k,l,m) => 1", .Too_Many_Parameters, 26, "fn(a, b, c, d, e, f, g, h, i, j, k, l, !Too_Many_Parameters)"},
		// A body that is missing or not whole.
		{"(x) =>", .Line_Ends_Too_Soon, 7, "fn(x => !Line_Ends_Too_Soon)"},
		{"() =>", .Line_Ends_Too_Soon, 6, "fn( => !Line_Ends_Too_Soon)"},
		{"(x) => 1 +", .Line_Ends_Too_Soon, 11, "fn(x => (1 + !Line_Ends_Too_Soon))"},
		{"(x) => 1 => 2", .Unexpected, 10, "!Unexpected(fn(x => 1))"},
		// "=>" is no "=": no assignment, no named argument.
		{"x => 1", .Unexpected, 3, "!Unexpected(x)"},
		{"x=>1", .Unexpected, 2, "!Unexpected(x)"},
		{"f(a => 1)", .Comma_Or_Close_Missing, 5, "f(a, !Comma_Or_Close_Missing)"},
		// A list: no "]", no "," between two items, an item missing.
		{"[", .Line_Ends_Too_Soon, 2, "[!Line_Ends_Too_Soon]"},
		{"[1, 2", .List_Close_Missing, 6, "[1, 2, !List_Close_Missing]"},
		{"[1 2]", .List_Close_Missing, 4, "[1, !List_Close_Missing]"},
		{"[1,]", .Unexpected, 4, "[1, !Unexpected]"},
		{"[,1]", .Unexpected, 2, "[!Unexpected]"},
		{"]", .Unexpected, 1, "!Unexpected"},
		{"[1})", .List_Close_Missing, 3, "[1, !List_Close_Missing]"},
	}
	for item in cases {
		tree := parse_of(item.text)
		form := tree_form(tree, tree.root)
		testing.expectf(t, tree.refusal.refusal == item.refusal && tree.refusal.place.column == item.column && form == item.form, "%q: %v at column %d, %q; not %v at column %d, %q", item.text, tree.refusal.refusal, tree.refusal.place.column, form, item.refusal, item.column, item.form)
		testing.expectf(t, tree.refusal.place == place_of_offset(item.text, int(tree.refusal.place.offset)), "%q: the offset %d is not at its line and column", item.text, tree.refusal.place.offset)
	}
	// The record names the parameter that it refuses.
	tree := parse_of("(x, x) => 1")
	refused := next_of(tree, node_at(tree, tree.root).first_child)
	testing.expect_value(t, node_text(tree, refused), "x")
}

// The trees of functions and lists, the binding of each name of a body,
// and the function that holds each node.
@(test)
parse_trees_of_functions_and_lists :: proc(t: ^testing.T) {
	Case :: struct {
		text: string,
		form: string,
	}
	cases := [?]Case {
		{"(x) => x + 1", "fn(x => (@x + 1))"},
		{"() => 1", "fn( => 1)"},
		{"( ) => 1", "fn( => 1)"},
		{"(x, y) => f(x, y)", "fn(x, y => f(@x, @y))"},
		{"(x) => x.a", "fn(x => @x.a)"},
		{"(x) => y", "fn(x => y)"},
		{"(x) => x with {a = 1}", "fn(x => (@x with #{a = 1}))"},
		{"(x) => (y) => x + y", "fn(x => fn(y => (@x + @y)))"},
		{"(x) => let y = x in y", "fn(x => let(y = @x; @y))"},
		{"(g, x) => g(x)", "fn(g, x => @g(@x))"},
		{"let f = (n) => f(n) in f(3)", "let(f = fn(n => @f(@n)); @f(3))"},
		{"let f = (x) => x in map([1], f)", "let(f = fn(x => @x); map([1], @f))"},
		{"map([1, 2], (x) => x * 2)", "map([1, 2], fn(x => (@x * 2)))"},
		{"f((x) => x, 1)", "f(fn(x => @x), 1)"},
		{"[1, (x) => x, [2]]", "[1, fn(x => @x), [2]]"},
		{"[]", "[]"},
		{"[ ]", "[]"},
		{"[[], [[]]]", "[[], [[]]]"},
		{"[1 + 2, \"a\", {b = 3}]", "[(1 + 2), \"a\", #{b = 3}]"},
		// A '(' with no "=>" after its group stays a group.
		{"(1)", "1"},
		{"(a) + 1", "(a + 1)"},
		{"(x)", "x"},
		{"f(x) + 1", "(f(x) + 1)"},
	}
	for item in cases {
		tree := parse_of(item.text)
		form := tree_form(tree, tree.root)
		testing.expectf(t, tree.refusal.refusal == .None && form == item.form, "%q: %v %q, not %q", item.text, tree.refusal.refusal, form, item.form)
	}

	// An inner parameter hides an outer one, and a parameter hides a
	// binding of a let around the function.
	tree := parse_of("(x) => (x) => x")
	testing.expect_value(t, tree_form(tree, tree.root), "fn(x => fn(x => @x))")
	inner := next_of(tree, node_at(tree, tree.root).first_child)
	inner_parameter := node_at(tree, inner).first_child
	testing.expect_value(t, node_at(tree, next_of(tree, inner_parameter)).binding, inner_parameter)
	tree = parse_of("let x = 1 in (x) => x")
	function := next_of(tree, node_at(tree, tree.root).first_child)
	parameter := node_at(tree, function).first_child
	testing.expect_value(t, node_at(tree, next_of(tree, parameter)).binding, parameter)

	// Each node knows the innermost function that holds it; the function
	// itself is held by the one around it.
	tree = parse_of("(x) => (y) => x")
	outer := tree.root
	testing.expect_value(t, node_at(tree, outer).function, NO_NODE)
	outer_parameter := node_at(tree, outer).first_child
	testing.expect_value(t, node_at(tree, outer_parameter).function, outer)
	inner = next_of(tree, outer_parameter)
	testing.expect_value(t, node_at(tree, inner).function, outer)
	inner_parameter = node_at(tree, inner).first_child
	testing.expect_value(t, node_at(tree, inner_parameter).function, inner)
	testing.expect_value(t, node_at(tree, next_of(tree, inner_parameter)).function, inner)
	// The function keeps the place of its '(' and its bytes are "=>".
	tree = parse_of("1 + (a) => a")
	function = next_of(tree, node_at(tree, tree.root).first_child)
	testing.expect_value(t, node_at(tree, function).integer, i64(4))
	testing.expect_value(t, node_text(tree, function), "=>")
}

// A comment gives no node: a line can end with one; a line of only a
// comment holds no expression; "//" in a text is a part of the text; a '/'
// alone and "/ /" stay faults.
@(test)
parse_comments :: proc(t: ^testing.T) {
	Case :: struct {
		text:    string,
		refusal: Refusal,
		column:  u32,
		form:    string,
	}
	cases := [?]Case {
		{"1 + 2 // three", .None, 0, "(1 + 2)"},
		{"f(1) // f(2", .None, 0, "f(1)"},
		{"x = 1 // a variable", .None, 0, "1"},
		{"\"a // b\"", .None, 0, "\"a // b\""},
		{"(x) => x // the body ends here", .None, 0, "fn(x => @x)"},
		{"1//2", .None, 0, "1"},
		{"// only a comment", .Line_Ends_Too_Soon, 18, "!Line_Ends_Too_Soon"},
		{"1 + // two", .Line_Ends_Too_Soon, 11, "(1 + !Line_Ends_Too_Soon)"},
		{"/", .Unexpected, 1, "!Unexpected"},
		{"1 / / 2", .Unexpected, 5, "(1 / !Unexpected)"},
		{"/ / 2", .Unexpected, 1, "!Unexpected"},
	}
	for item in cases {
		tree := parse_of(item.text)
		form := tree_form(tree, tree.root)
		testing.expectf(t, tree.refusal.refusal == item.refusal && (item.refusal == .None || tree.refusal.place.column == item.column) && form == item.form, "%q: %v at column %d, %q; not %v at column %d, %q", item.text, tree.refusal.refusal, tree.refusal.place.column, form, item.refusal, item.column, item.form)
	}
	tree := parse_of("x = 1 // a variable")
	testing.expect_value(t, tree.assigned_name, "x")
	// The nodes: the comment takes none.
	tree = parse_of("1 // 2 + 3")
	testing.expect_value(t, tree.node_count, 1)
}

// The edges of a function and of a list: no parameter, the most parameters
// that a call takes, the deepest nesting of functions that a line holds,
// then one more level; the most items that a line holds.
@(test)
parse_function_edges :: proc(t: ^testing.T) {
	tree := parse_of("(a,b,c,d,e,f,g,h,i,j,k,l) => a")
	testing.expect_value(t, tree.refusal.refusal, Refusal.None)
	parameters := 0
	for child := node_at(tree, tree.root).first_child; child != NO_NODE; child = next_of(tree, child) {
		if node_at(tree, child).kind == .Parameter {
			parameters += 1
		}
	}
	testing.expect_value(t, parameters, ARGUMENT_CAPACITY)

	// "()=>" for each level: four bytes.
	levels := (TEXT_BYTES_MOST - 1) / 4
	deepest := strings.concatenate({strings.repeat("()=>", levels, context.temp_allocator), "1"}, context.temp_allocator)
	tree = parse_of(deepest)
	testing.expect_value(t, tree.refusal.refusal, Refusal.None)
	depth := 0
	for index := tree.root; node_at(tree, index).kind == .Function; index = node_at(tree, index).first_child {
		depth += 1
	}
	testing.expect_value(t, depth, levels)
	tree = parse_of(strings.concatenate({strings.repeat("()=>", levels + 1, context.temp_allocator), "1"}, context.temp_allocator))
	testing.expect_value(t, tree.refusal.refusal, Refusal.Text_Too_Long)

	// "1," for each item: the nodes of the line hold them all.
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, "[")
	items := (TEXT_BYTES_MOST - 2 + 1) / 2
	for item in 0 ..< items {
		if item > 0 {
			strings.write_string(&builder, ",")
		}
		strings.write_string(&builder, "1")
	}
	strings.write_string(&builder, "]")
	widest := strings.to_string(builder)
	testing.expect(t, len(widest) <= TEXT_BYTES_MOST)
	tree = parse_of(widest)
	testing.expect_value(t, tree.refusal.refusal, Refusal.None)
	count := 0
	for child := node_at(tree, tree.root).first_child; child != NO_NODE; child = next_of(tree, child) {
		count += 1
	}
	testing.expect_value(t, count, items)
}

// Hash literals, call on a record literal, conditionals, comparisons, and
// postfix field selection: refusals first, then valid trees.
@(test)
parse_layer5_forms_and_refusals :: proc(t: ^testing.T) {
	VALID_HASH :: "blake3:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

	Refusal_Case :: struct {
		text:    string,
		refusal: Refusal,
		column:  u32,
	}
	refusals := [?]Refusal_Case {
		// Malformed hash literals: empty, short, 63 hex, 65 hex, uppercase, non-hex.
		{"blake3:", .Hash_Not_Valid, 1},
		{"blake3:0", .Hash_Not_Valid, 1},
		{"blake3:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcde", .Hash_Not_Valid, 1},
		{"blake3:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0", .Hash_Not_Valid, 1},
		{"blake3:0123456789ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef", .Hash_Not_Valid, 1},
		{"module(blake3:zzzz)", .Hash_Not_Valid, 8},
		// Conditionals missing `then`, `else`, or branch expressions.
		{"if true", .If_Then_Missing, 8},
		{"if true 1 else 2", .If_Then_Missing, 9},
		{"if true then 1", .If_Else_Missing, 15},
		{"if true then 1 2", .If_Else_Missing, 16},
		{"if true then 1 else", .Line_Ends_Too_Soon, 20},
		// New Lex words refused as names.
		{"then", .Word_As_Name, 1},
		{"else", .Word_As_Name, 1},
		{"if = 1", .Word_As_Name, 1},
		{"{then = 1}", .Word_As_Name, 2},
		{"let else = 1 in 2", .Word_As_Name, 5},
		{"(true) => 1", .Word_As_Name, 2},
	}
	for item in refusals {
		tree := parse_of(item.text)
		testing.expectf(t, tree.refusal.refusal == item.refusal && tree.refusal.place.column == item.column, "%q: %v at col %d, not %v at col %d", item.text, tree.refusal.refusal, tree.refusal.place.column, item.refusal, item.column)
	}

	Form_Case :: struct {
		text: string,
		form: string,
	}
	forms := [?]Form_Case {
		{VALID_HASH, VALID_HASH},
		{"module(" + VALID_HASH + ")", "module(" + VALID_HASH + ")"},
		{"declaration(" + VALID_HASH + ")", "declaration(" + VALID_HASH + ")"},
		{"plan { a = 1 }", "plan(#{a = 1})"},
		{"project { inputs = { m = catalog } }", "project(#{inputs = #{m = catalog}})"},
		{"let f = (r) => r.a in f { a = 42 }", "let(f = fn(r => @r.a); @f(#{a = 42}))"},
		{"let gt = { app = (x) => x } in gt.app(1)", "let(gt = #{app = fn(x => @x)}; @gt.app(1))"},
		{"if true then 1 else 2", "if(true; 1; 2)"},
		{"if x <= 10 then x + 1 else x - 1", "if((x <= 10); (x + 1); (x - 1))"},
		{"if a = b then 1 else 0", "if((a = b); 1; 0)"},
		{"if a != b then 1 else 0", "if((a != b); 1; 0)"},
		{"({good = 42, bad = 1 / 0}).good", "#{good = 42, bad = (1 / 0)}.good"},
		{"(r with {a = 1}).a", "(r with #{a = 1}).a"},
		{"import(\"pins.lex\").gt.tree", "import(\"pins.lex\").gt.tree"},
	}
	for item in forms {
		tree := parse_of(item.text)
		form := tree_form(tree, tree.root)
		testing.expectf(t, tree.refusal.refusal == .None && form == item.form, "%q: %v %q, not %q", item.text, tree.refusal.refusal, form, item.form)
	}
}

// Multi-line .lex declaration parsing: external node storage, newlines, tabs,
// comments, trailing commas, depth bound, and size bound.
@(test)
parse_multiline_declarations_and_bounds :: proc(t: ^testing.T) {
	nodes := make([]Node, 1024, context.temp_allocator)
	tree: Syntax_Tree

	source := `// A multi-line project declaration.
let
	h = blake3:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef,
	double = (x) =>
		x * 2,
in
project {
	// Inputs with trailing comma.
	inputs = {
		modus = catalog,
		wren  = declaration(h),
	},
	outputs = {
		nums = [
			1,
			2,
			double(3),
		],
	},
}
`
	parse_declaration(source, nodes, &tree)
	testing.expect_value(t, tree.refusal.refusal, Refusal.None)
	testing.expect(t, tree.node_count > 10)
	// Line numbers are tracked across newlines.
	root := node_at(&tree, tree.root)
	testing.expect(t, root != nil && root.kind == .Let && root.place.line == 2)

	// Top-level console assignment is refused in declaration mode (parsed as equality expression or unexpected).
	// Wait: "a = 1" is a comparison expression in declaration mode, not an assignment!
	parse_declaration("a = 1", nodes, &tree)
	testing.expect_value(t, tree.assigned_name, "")
	testing.expect_value(t, node_at(&tree, tree.root).kind, Node_Kind.Binary)
	testing.expect_value(t, node_at(&tree, tree.root).operator, Operator.Equal)

	// Depth bound prevents stack overflow on hostile deeply nested input.
	deep := strings.concatenate({strings.repeat("(", 300, context.temp_allocator), "1", strings.repeat(")", 300, context.temp_allocator)}, context.temp_allocator)
	parse_declaration(deep, nodes, &tree, DECLARATION_TEXT_BYTES_MOST, 64)
	testing.expect_value(t, tree.refusal.refusal, Refusal.Nesting_Too_Deep)

	// Node buffer exhaustion stops cleanly with Nodes_Full.
	tiny_nodes: [4]Node
	parse_declaration("{ a = 1, b = 2, c = 3 }", tiny_nodes[:], &tree)
	testing.expect_value(t, tree.refusal.refusal, Refusal.Nodes_Full)

	// Text past bound stops cleanly with Text_Too_Long.
	parse_declaration("1 + 2 + 3", nodes, &tree, text_bytes_most = 4)
	testing.expect_value(t, tree.refusal.refusal, Refusal.Text_Too_Long)
}
