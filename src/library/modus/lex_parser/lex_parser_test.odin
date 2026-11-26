#+build !freestanding
#+build !modus
package lex_parser

import "core:fmt"
import "core:strings"
import "core:testing"
import "modus:console_condition"
import "modus:contract/value_kinds"
import "modus:hash_table"

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

@(private = "file")
parse_of :: proc(text: string) -> ^Syntax_Tree {
	return parse_with(text, {form_of = test_form_of})
}

@(private = "file")
parse_with :: proc(text: string, lookup: Form_Lookup) -> ^Syntax_Tree {
	buf := new(Console_Tree_Buffers, context.temp_allocator)
	tree := new(Syntax_Tree, context.temp_allocator)
	parse_console(text, lookup, buf, tree)
	return tree
}

@(private = "file")
make_decl_storage :: proc(node_cap: int, allocator := context.temp_allocator) -> Tree_Storage {
	nodes := make([]Ast_Node, node_cap, allocator)
	extra := make([]Node_Index, node_cap, allocator)
	scratch := make([]Node_Index, node_cap, allocator)
	ints := make([]i64, max(64, node_cap / 8), allocator)
	bindings := make([]Node_Index, node_cap, allocator)
	functions := make([]Node_Index, node_cap, allocator)

	groups := hash_table.slice_index_groups_for_entries(max(64, node_cap))
	ctrl := make([]u8, groups * hash_table.GROUP_WIDTH, allocator)
	refs := make([]u32, groups * hash_table.GROUP_WIDTH, allocator)
	spans := make([]Sym_Span, max(64, node_cap) + 1, allocator)
	sbytes := make([]u8, max(4096, node_cap * 16), allocator)
	interner := new(String_Interner, allocator)
	init_ok: bool
	interner^, init_ok = interner_init(ctrl, refs, spans, sbytes, 0x1E7_0001)
	assert(init_ok)

	dctrl := make([]u8, groups * hash_table.GROUP_WIDTH, allocator)
	drefs := make([]u32, groups * hash_table.GROUP_WIDTH, allocator)
	dkeys := make([]u64, max(64, node_cap), allocator)
	dnodes := make([]Node_Index, max(64, node_cap), allocator)

	return {
		nodes            = nodes,
		extra_children   = extra,
		scratch_children = scratch,
		int_consts       = ints,
		bindings         = bindings,
		functions        = functions,
		interner         = interner,
		dup_controls     = dctrl,
		dup_refs         = drefs,
		dup_keys         = dkeys,
		dup_nodes        = dnodes,
	}
}

@(private = "file")
tree_form :: proc(tree: ^Syntax_Tree, index: Node_Index) -> string {
	builder := strings.builder_make(context.temp_allocator)
	node_form_write(&builder, tree, index)
	return strings.to_string(builder)
}

@(private = "file")
children_write :: proc(builder: ^strings.Builder, tree: ^Syntax_Tree, children: []Node_Index, separator: string) {
	for child, i in children {
		if i > 0 {
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
	case .Integer, .Text, .Member, .Parameter, .Hash, .Boolean, .Placeholder, .Match_Pat_Wild, .Match_Pat_Bind:
		strings.write_string(builder, node_text(tree, index))
	case .Record_Comp:
		strings.write_string(builder, "comp{")
		children_write(builder, tree, node_children(tree, index), "; ")
		strings.write_string(builder, "}")
	case .Match:
		strings.write_string(builder, "match(")
		children_write(builder, tree, node_children(tree, index), "; ")
		strings.write_string(builder, ")")
	case .Match_Arm:
		strings.write_string(builder, "arm(")
		children_write(builder, tree, node_children(tree, index), "; ")
		strings.write_string(builder, ")")
	case .Match_Pat_Field:
		strings.write_string(builder, node_text(tree, index))
		if sub := node_child(tree, index); sub != NO_NODE {
			strings.write_string(builder, " = ")
			node_form_write(builder, tree, sub)
		}
	case .Logical_Not:
		strings.write_string(builder, "!(")
		node_form_write(builder, tree, node_child(tree, index))
		strings.write_string(builder, ")")
	case .Text_Interp:
		strings.write_string(builder, "interp(")
		children_write(builder, tree, node_children(tree, index), "; ")
		strings.write_string(builder, ")")
	case .Pattern_Record:
		strings.write_string(builder, "pat{")
		children_write(builder, tree, node_children(tree, index), ", ")
		if (node.sub & PAT_FLAG_REST) != 0 {
			strings.write_string(builder, ", ...")
		}
		strings.write_string(builder, "}")
	case .Pattern_Field:
		strings.write_string(builder, node_text(tree, index))
		if def := node_child(tree, index); def != NO_NODE {
			strings.write_string(builder, " = ")
			node_form_write(builder, tree, def)
		}
	case .If:
		strings.write_string(builder, "if(")
		children_write(builder, tree, node_children(tree, index), "; ")
		strings.write_string(builder, ")")
	case .Field_Select:
		node_form_write(builder, tree, node_child(tree, index))
		fmt.sbprintf(builder, ".%s", node_text(tree, index))
	case .Name:
		if node_binding(tree, index) != NO_NODE {
			strings.write_string(builder, "@")
		}
		strings.write_string(builder, node_text(tree, index))
	case .Function:
		strings.write_string(builder, "fn(")
		_, arrow_end := node_function_offsets(tree, index)
		arrow_start := u32(max(arrow_end - 2, 0))
		first := true
		for child in node_children(tree, index) {
			child_node := node_at(tree, child)
			if child_node != nil && child_node.span_off > arrow_start {
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
		children_write(builder, tree, node_children(tree, index), ", ")
		strings.write_string(builder, "]")
	case .Record_Literal:
		strings.write_string(builder, "#{")
		children_write(builder, tree, node_children(tree, index), ", ")
		strings.write_string(builder, "}")
	case .Literal_Field, .Named_Argument, .Let_Binding:
		fmt.sbprintf(builder, "%s = ", node_text(tree, index))
		node_form_write(builder, tree, node_child(tree, index))
	case .Let:
		strings.write_string(builder, "let(")
		children_write(builder, tree, node_children(tree, index), "; ")
		strings.write_string(builder, ")")
	case .Call:
		if node_binding(tree, index) != NO_NODE {
			strings.write_string(builder, "@")
		}
		strings.write_string(builder, node_text(tree, index))
		strings.write_string(builder, "(")
		children_write(builder, tree, node_children(tree, index), ", ")
		strings.write_string(builder, ")")
	case .Negate:
		strings.write_string(builder, "(-")
		node_form_write(builder, tree, node_child(tree, index))
		strings.write_string(builder, ")")
	case .Binary:
		left, right := node_binary_children(tree, index)
		strings.write_string(builder, "(")
		node_form_write(builder, tree, left)
		fmt.sbprintf(builder, " %s ", OPERATOR_TEXTS[node_operator(tree, index)])
		node_form_write(builder, tree, right)
		strings.write_string(builder, ")")
	case .Pipe:
		left, right := node_binary_children(tree, index)
		strings.write_string(builder, "(")
		node_form_write(builder, tree, left)
		strings.write_string(builder, " |> ")
		node_form_write(builder, tree, right)
		strings.write_string(builder, ")")
	case .Condition:
		cond := node_condition(tree, index)
		if cond == nil {
			strings.write_string(builder, "[?]")
			return
		}
		if cond.refusal != .None {
			fmt.sbprintf(builder, "[!%v]", cond.refusal)
			return
		}
		fmt.sbprintf(builder, "[%s %s ", cond.head.field, console_condition.COMPARISON_TEXTS[cond.head.comparison])
		node_form_write(builder, tree, node_child(tree, index))
		strings.write_string(builder, "]")
	case .Fact_Name:
		if node_refusal(tree, index) == .Fact_Name_Missing {
			strings.write_string(builder, "<!>")
			return
		}
		fmt.sbprintf(builder, "<%s>", node_text(tree, index))
	case .Field_Names:
		if node_refusal(tree, index) == .Field_Name_Missing {
			fmt.sbprintf(builder, "{{%s!}}", node_text(tree, index))
			return
		}
		fmt.sbprintf(builder, "{{%s}}", node_text(tree, index))
	case .Refused:
		fmt.sbprintf(builder, "!%v", node_refusal(tree, index))
		before := node_child(tree, index)
		if before != NO_NODE {
			strings.write_string(builder, "(")
			node_form_write(builder, tree, before)
			strings.write_string(builder, ")")
		}
	}
}

@(test)
ast_node_is_16_bytes_and_tree_has_no_inline_bloat :: proc(t: ^testing.T) {
	testing.expect_value(t, size_of(Ast_Node), 16)
	testing.expect(t, size_of(Syntax_Tree) <= 256)
}

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

	longest := strings.concatenate({"11", strings.repeat("+1", (TEXT_BYTES_MOST - 2) / 2, context.temp_allocator)}, context.temp_allocator)
	testing.expect_value(t, len(longest), TEXT_BYTES_MOST)
	tree = parse_of(longest)
	testing.expect_value(t, tree.refusal.refusal, Refusal.None)
	testing.expect_value(t, node_at(tree, tree.root).kind, Node_Kind.Binary)
}

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

@(private = "file")
nesting_deepest :: proc(t: ^testing.T, opening, inner, closing: string) -> (levels: int) {
	text_of :: proc(opening, inner, closing: string, levels: int) -> string {
		return strings.concatenate({strings.repeat(opening, levels, context.temp_allocator), inner, strings.repeat(closing, levels, context.temp_allocator)}, context.temp_allocator)
	}
	for levels = 1; levels <= TEXT_BYTES_MOST; levels += 1 {
		if parse_of(text_of(opening, inner, closing, levels + 1)).refusal.refusal != .None {
			break
		}
	}
	more := text_of(opening, inner, closing, levels + 1)
	testing.expectf(t, len(more) <= TEXT_BYTES_MOST, "%q: %d levels fit the bytes of a line", opening, levels + 1)
	testing.expect_value(t, parse_of(more).refusal.refusal, Refusal.Nesting_Too_Deep)
	testing.expect_value(t, parse_of(text_of(opening, inner, closing, levels)).refusal.refusal, Refusal.None)
	testing.expectf(t, levels >= LINE_PARSE_DEPTH_LIMIT / 2 - 1 && levels <= LINE_PARSE_DEPTH_LIMIT, "%q: %d levels", opening, levels)
	return levels
}

@(test)
parse_nesting_at_the_bound_of_the_depth :: proc(t: ^testing.T) {
	levels := nesting_deepest(t, "-", "1", "")
	tree := parse_of(strings.concatenate({strings.repeat("-", levels, context.temp_allocator), "1"}, context.temp_allocator))
	depth := 0
	for index := tree.root; node_at(tree, index).kind == .Negate; index = node_child(tree, index) {
		depth += 1
	}
	testing.expect_value(t, depth, levels)
	tree = parse_of(strings.concatenate({strings.repeat("-", TEXT_BYTES_MOST, context.temp_allocator), "1"}, context.temp_allocator))
	testing.expect_value(t, tree.refusal.refusal, Refusal.Text_Too_Long)

	levels = nesting_deepest(t, "(", "1", ")")
	tree = parse_of(strings.concatenate({strings.repeat("(", levels, context.temp_allocator), "1", strings.repeat(")", levels, context.temp_allocator)}, context.temp_allocator))
	testing.expect_value(t, tree.node_count, 1)

	levels = nesting_deepest(t, "f(", "1", ")")
	tree = parse_of(strings.concatenate({strings.repeat("f(", levels, context.temp_allocator), "1", strings.repeat(")", levels, context.temp_allocator)}, context.temp_allocator))
	testing.expect_value(t, tree.node_count, levels + 1)

	open := strings.concatenate({strings.repeat("(", TEXT_BYTES_MOST - 1, context.temp_allocator), "1"}, context.temp_allocator)
	tree = parse_of(open)
	testing.expect_value(t, tree.refusal.refusal, Refusal.Nesting_Too_Deep)
	testing.expect(t, int(tree.refusal.place.column) <= LINE_PARSE_DEPTH_LIMIT + 1)
}

@(test)
parse_refusals_with_their_places :: proc(t: ^testing.T) {
	Case :: struct {
		text:    string,
		refusal: Refusal,
		column:  u32,
		form:    string,
	}
	cases := [?]Case {
		{"f(", .Line_Ends_Too_Soon, 3, "f(!Line_Ends_Too_Soon)"},
		{"f(1", .Comma_Or_Close_Missing, 4, "f(1, !Comma_Or_Close_Missing)"},
		{"f(1,", .Line_Ends_Too_Soon, 5, "f(1, !Line_Ends_Too_Soon)"},
		{"f(1,)", .Unexpected, 5, "f(1, !Unexpected)"},
		{"f(,1)", .Unexpected, 3, "f(!Unexpected)"},
		{"f(1 2)", .Comma_Or_Close_Missing, 5, "f(1, !Comma_Or_Close_Missing)"},
		{"f(g(1), h(2) 3)", .Comma_Or_Close_Missing, 14, "f(g(1), h(2), !Comma_Or_Close_Missing)"},
		{"f(1,1,1,1,1,1,1,1,1,1,1,1,1)", .Too_Many_Arguments, 27, "f(1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, !Too_Many_Arguments)"},
		{"#", .Unexpected, 1, "!Unexpected"},
		{"1 # 2", .Unexpected, 3, "!Unexpected(1)"},
		{"1 | 2", .Lone_Bar, 3, "!Lone_Bar(1)"},
		{"|", .Lone_Bar, 1, "!Lone_Bar"},
		{"1\n+ 2", .Unexpected, 2, "!Unexpected(1)"},
		{"\xc3\xa9", .Unexpected, 1, "!Unexpected"},
		{"= 3", .Unexpected, 1, "!Unexpected"},
		{"1 2", .Unexpected, 3, "!Unexpected(1)"},
		{"f(1) g", .Unexpected, 6, "!Unexpected(f(1))"},
		{"-", .Line_Ends_Too_Soon, 2, "(-!Line_Ends_Too_Soon)"},
		{"1 +", .Line_Ends_Too_Soon, 4, "(1 + !Line_Ends_Too_Soon)"},
		{"2 * ", .Line_Ends_Too_Soon, 5, "(2 * !Line_Ends_Too_Soon)"},
		{"x =", .Line_Ends_Too_Soon, 4, "!Line_Ends_Too_Soon"},
		{"(1 + 2", .Close_Parenthesis_Missing, 7, "!Close_Parenthesis_Missing((1 + 2))"},
		{"(", .Line_Ends_Too_Soon, 2, "!Line_Ends_Too_Soon"},
		{")", .Unexpected, 1, "!Unexpected"},
		{"\"abc", .Text_Without_End_Quote, 1, "!Text_Without_End_Quote"},
		{"1 + \"abc", .Text_Without_End_Quote, 5, "(1 + !Text_Without_End_Quote)"},
		{"9223372036854775808", .Number_Too_Large, 1, "!Number_Too_Large"},
		{"1 - 99999999999999999999", .Number_Too_Large, 5, "(1 - !Number_Too_Large)"},
		{"facts(t, 3)", .Fact_Name_Missing, 10, "facts(t, <!>)"},
		{"facts(t, )", .Fact_Name_Missing, 10, "facts(t, <!>)"},
		{"facts(t,", .Fact_Name_Missing, 9, "facts(t, <!>)"},
		{"facts(t, a.B c)", .Comma_Or_Close_Missing, 14, "facts(t, <a.B>, !Comma_Or_Close_Missing)"},
		{"columns(t,", .Field_Name_Missing, 11, "columns(t, {!})"},
		{"columns(t, )", .Field_Name_Missing, 12, "columns(t, {!})"},
		{"columns(t, a,)", .Field_Name_Missing, 14, "columns(t, {a,!})"},
		{"columns(t, \"a b\")", .Field_Name_Missing, 12, "columns(t, {!})"},
		{"columns(t, a b)", .Comma_Or_Close_Missing, 14, "columns(t, {a }, !Comma_Or_Close_Missing)"},
		{"where(t, = 3)", .Condition_Head_Refused, 10, "where(t, [!No_Field])"},
		{"where(t,", .Condition_Head_Refused, 9, "where(t, [!No_Field])"},
		{"where(t, level)", .Condition_Head_Refused, 10, "where(t, [!No_Operator])"},
		{"where(t, a == 1)", .Condition_Head_Refused, 10, "where(t, [!Double_Equal])"},
		{"where(t, a ! 1)", .Condition_Head_Refused, 10, "where(t, [!Lone_Bang])"},
		{"where(t, a <)", .Condition_Head_Refused, 10, "where(t, [!No_Value])"},
		{"where(t, a < ", .Condition_Head_Refused, 10, "where(t, [!No_Value])"},
		{"where(t, a = 1", .Comma_Or_Close_Missing, 15, "where(t, [a = 1], !Comma_Or_Close_Missing)"},
		{"where(t, a = (1", .Close_Parenthesis_Missing, 16, "where(t, [a = !Close_Parenthesis_Missing(1)])"},
	}
	for item in cases {
		tree := parse_of(item.text)
		form := tree_form(tree, tree.root)
		testing.expectf(t, tree.refusal.refusal == item.refusal && tree.refusal.place.line == 1 && tree.refusal.place.column == item.column && form == item.form, "%q: %v at line %d, column %d, %q; not %v at column %d, %q", item.text, tree.refusal.refusal, tree.refusal.place.line, tree.refusal.place.column, form, item.refusal, item.column, item.form)
		testing.expectf(t, tree.refusal.place == place_of_offset(item.text, int(tree.refusal.place.offset)), "%q: offset mismatch", item.text)
	}
}

@(test)
parse_refusal_values :: proc(t: ^testing.T) {
	tree := parse_of("where(t, a == 1)")
	testing.expect_value(t, tree.refusal.value, u64(console_condition.Refusal.Double_Equal))
	tree = parse_of("where(t, level)")
	testing.expect_value(t, tree.refusal.value, u64(console_condition.Refusal.No_Operator))
	tree = parse_of("1 + 2")
	testing.expect_value(t, tree.refusal, Refusal_Record{})
}

@(test)
parse_reads_the_form_of_the_lookup :: proc(t: ^testing.T) {
	tree := parse_with("where(t, level = 1)", {})
	testing.expect_value(t, tree.refusal.refusal, Refusal.None)
	testing.expect_value(t, tree_form(tree, tree.root), "where(t, level = 1)")
	testing.expect_value(t, node_at(tree, node_children(tree, tree.root)[1]).kind, Node_Kind.Named_Argument)
	tree = parse_of("where(t, level = 1)")
	testing.expect_value(t, tree_form(tree, tree.root), "where(t, [level = 1])")
	tree = parse_with("facts(t, a.B)", {})
	testing.expect_value(t, tree_form(tree, tree.root), "facts(t, a.B)")
	testing.expect_value(t, node_at(tree, node_children(tree, tree.root)[1]).kind, Node_Kind.Name)
}

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

@(test)
node_indexes_out_of_the_tree :: proc(t: ^testing.T) {
	tree := parse_of("f(1)")
	testing.expect(t, node_at(tree, NO_NODE) == nil)
	testing.expect(t, node_at(tree, Node_Index(tree.node_count)) == nil)
	testing.expect(t, node_at(tree, Node_Index(max(i32))) == nil)
	testing.expect(t, node_at(tree, Node_Index(min(i32))) == nil)
	testing.expect_value(t, node_text(tree, NO_NODE), "")
	testing.expect(t, node_at(tree, Node_Index(tree.node_count - 1)) != nil)
}

@(test)
parse_trees_of_each_form :: proc(t: ^testing.T) {
	Case :: struct {
		text: string,
		form: string,
	}
	cases := [?]Case {
		{"42", "42"},
		{"0", "0"},
		{"9223372036854775807", "9223372036854775807"},
		{"\"a b\"", "\"a b\""},
		{"\"\"", "\"\""},
		{"x", "x"},
		{"monitor.count", "monitor.count"},
		{"r.value", "r.value"},
		{"f()", "f()"},
		{"f( )", "f()"},
		{"f(1, \"x\", y)", "f(1, \"x\", y)"},
		{"f(g(1), h(k(2)))", "f(g(1), h(k(2)))"},
		{"monitor.count(\"notes\")", "monitor.count(\"notes\")"},
		{"f(1,1,1,1,1,1,1,1,1,1,1,1)", "f(1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1)"},
		{"1 + 2 * 3", "(1 + (2 * 3))"},
		{"1 - 2 - 3", "((1 - 2) - 3)"},
		{"(1 + 2) * 3", "((1 + 2) * 3)"},
		{"7 % 4 / 2", "((7 % 4) / 2)"},
		{"-x", "(-x)"},
		{"--1", "(-(-1))"},
		{"2 * -3", "(2 * (-3))"},
		{"\"a\" + \"b\"", "(\"a\" + \"b\")"},
		{"rows(t) - rows(u)", "(rows(t) - rows(u))"},
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
	testing.expect_value(t, node_integer(tree, tree.root), max(i64))
}

@(test)
parse_assignments :: proc(t: ^testing.T) {
	tree := parse_of("t = rows(x)")
	testing.expect_value(t, tree.refusal.refusal, Refusal.None)
	testing.expect_value(t, tree.assigned_name, "t")
	testing.expect_value(t, tree_form(tree, tree.root), "rows(x)")
	testing.expect_value(t, node_place(tree, tree.root), Place{line = 1, column = 5, offset = 4})

	tree = parse_of("x")
	testing.expect_value(t, tree.assigned_name, "")
	testing.expect_value(t, tree_form(tree, tree.root), "x")
	tree = parse_of("a.b = 1")
	testing.expect_value(t, tree.assigned_name, "a.b")
}

@(test)
parse_thin_arrow :: proc(t: ^testing.T) {
	Case :: struct {
		text:    string,
		refusal: Refusal,
		column:  u32,
	}
	cases := []Case {
		{"->", .Unexpected, 2},
		{"f(->)", .Unexpected, 4},
		{"n -> n * n", .Thin_Arrow, 3},
		{"map(x, n -> n * n)", .Thin_Arrow, 10},
		{"map(x, n->n*n)", .Thin_Arrow, 9},
		{"map(x, (n) -> n * n)", .Thin_Arrow, 12},
		{"[1, n -> n]", .Thin_Arrow, 7},
		{"{a = n -> n}", .Thin_Arrow, 8},
		{"let f = n -> n in f(1)", .Thin_Arrow, 11},
		{"x = n -> n", .Thin_Arrow, 7},
		{"g() + (n -> n)", .Thin_Arrow, 10},
		{"let x = n -> n", .Thin_Arrow, 11},
		{"map(x, n => n)", .Comma_Or_Close_Missing, 10},
		{"map(x, (n) => n * n)", .None, 0},
	}
	for item in cases {
		tree := parse_of(item.text)
		testing.expectf(t, tree.refusal.refusal == item.refusal && (item.refusal == .None || tree.refusal.place.column == item.column), "%q: %v at column %d, not %v at column %d; %q", item.text, tree.refusal.refusal, tree.refusal.place.column, item.refusal, item.column, tree_form(tree, tree.root))
	}
}

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
		{"let", "", .Let_Name_Missing, 4, "let(!Let_Name_Missing)"},
		{"let = 1", "", .Word_As_Name, 1, "!Word_As_Name"},
		{"let in = 1", "", .Word_As_Name, 5, "let(!Word_As_Name)"},
		{"let _ = 1", "", .Word_As_Name, 5, "let(!Word_As_Name)"},
		{"let x == 1", "", .Let_Equal_Missing, 7, "let(!Let_Equal_Missing)"},
		{"let x =", "", .Line_Ends_Too_Soon, 8, "let(x = !Line_Ends_Too_Soon)"},
		{"let x = [1, 2", "", .List_Close_Missing, 14, ""},
		{"let a = 1, b = 2", "", .Let_In_Missing, 17, "let(a = 1; b = 2; !Let_In_Missing)"},
		{"let a = 1 a", "", .Let_In_Missing, 11, "let(a = 1; !Let_In_Missing)"},
		{"let a = 1 in a", "", .None, 0, "let(a = 1; @a)"},
		{"letter = 1", "letter", .None, 0, "1"},
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
	tree := parse_of("let x = [1, 2, 3]")
	testing.expect_value(t, node_at(tree, tree.root).kind, Node_Kind.List_Literal)
	testing.expect_value(t, node_place(tree, tree.root), Place{line = 1, column = 9, offset = 8})
}

@(test)
parse_places_and_conditions :: proc(t: ^testing.T) {
	tree := parse_of("f(1,  x)")
	testing.expect_value(t, node_place(tree, tree.root), Place{line = 1, column = 1, offset = 0})
	testing.expect_value(t, node_text(tree, tree.root), "f")
	args := node_children(tree, tree.root)
	testing.expect_value(t, len(args), 2)
	testing.expect_value(t, node_place(tree, args[0]).column, u32(3))
	testing.expect_value(t, node_place(tree, args[1]).column, u32(7))

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
		cond_idx := node_children(tree, tree.root)[1]
		condition := node_at(tree, cond_idx)
		extra := node_condition(tree, cond_idx)
		testing.expectf(t, condition != nil && condition.kind == .Condition && extra != nil && extra.member_alone == item.member_alone, "%q: member_alone is not %v", item.text, item.member_alone)
		if extra != nil {
			testing.expect_value(t, extra.head.field, "level")
			testing.expect_value(t, extra.head.comparison, console_condition.Comparison.Equal)
			testing.expect_value(t, node_place(tree, cond_idx).column, u32(10))
			testing.expect_value(t, node_text(tree, cond_idx), "level =")
		}
	}
}

// Native |> parsing (no text-level pipe_nested_form) preserving Form_Lookup
// parameter offsets, placeholder validation, and exact source byte offsets.
@(test)
parse_native_pipe_and_placeholders :: proc(t: ^testing.T) {
	Case :: struct {
		text: string,
		form: string,
	}
	cases := [?]Case {
		{"processes() |> where(name = \"server\")", "(processes() |> where([name = \"server\"]))"},
		{"processes() |> where(_, name = \"server\")", "(processes() |> where(_, [name = \"server\"]))"},
		{"processes() |> columns(name, slot)", "(processes() |> columns({name, slot}))"},
		{"log.records() |> facts(storage.Bad_Block) |> where(block = 12)", "((log.records() |> facts(<storage.Bad_Block>)) |> where([block = 12]))"},
		{"x |> h |> g(1) |> f", "(((x |> h()) |> g(1)) |> f())"},
		{"1 + 2 |> text", "((1 + 2) |> text())"},
		{"r with {a = 1} |> f", "((r with #{a = 1}) |> f())"},
		{"x |> f(b, _)", "(x |> f(b, _))"},
		{"x |> f(n = _)", "(x |> f(n = _))"},
		{"x |> f(_, y) |> g(1, _)", "((x |> f(_, y)) |> g(1, _))"},
		{"f(x |> g(_), y)", "f((x |> g(_)), y)"},
		{"f(n = x |> g)", "f(n = (x |> g()))"},
		{"{a = x |> g, b = 2}", "#{a = (x |> g()), b = 2}"},
		{"let a = x |> g in a |> h", "let(a = (x |> g()); (@a |> h()))"},
	}
	for item in cases {
		tree := parse_of(item.text)
		form := tree_form(tree, tree.root)
		testing.expectf(t, tree.refusal.refusal == .None && form == item.form, "%q: %v %q, not %q", item.text, tree.refusal.refusal, form, item.form)
	}

	// Assignment with native pipe preserves exact offset of RHS.
	tree := parse_of("t = processes() |> rows")
	testing.expect_value(t, tree.refusal.refusal, Refusal.None)
	testing.expect_value(t, tree.assigned_name, "t")
	testing.expect_value(t, tree_form(tree, tree.root), "(processes() |> rows())")
	_, rhs := node_binary_children(tree, tree.root)
	testing.expect_value(t, node_place(tree, rhs).offset, u32(19))

	// Refusals for malformed |> and _ placement.
	Refusal_Case :: struct {
		text:    string,
		refusal: Refusal,
	}
	refusals := [?]Refusal_Case {
		{"|> f", .Pipe_No_Left},
		{"a |>", .Pipe_Line_End},
		{"a |> 12", .Pipe_Not_A_Call},
		{"a |> \"x\"", .Pipe_Not_A_Call},
		{"a |> (f)", .Pipe_Not_A_Call},
		{"a |> |> f", .Pipe_Not_A_Call},
		{"a | f", .Lone_Bar},
		{"a |> f(_ + 1)", .Placeholder_Not_Whole},
		{"a |> f((_))", .Placeholder_Not_Whole},
		{"a |> f({ x = _ })", .Placeholder_Not_Whole},
		{"a |> f([_])", .Placeholder_Not_Whole},
		{"a |> f(_, _)", .Placeholder_Twice},
		{"a |> f(g(_))", .Placeholder_Nested},
		{"f(_)", .Placeholder_Without_Pipe},
		{"a |> f(1,2,3,4,5,6,7,8,9,10,11,12)", .Too_Many_Arguments},
	}
	for item in refusals {
		rt := parse_of(item.text)
		testing.expectf(t, rt.refusal.refusal == item.refusal, "%q: got %v, expected %v", item.text, rt.refusal.refusal, item.refusal)
	}
}

@(test)
parse_refusals_of_the_forms :: proc(t: ^testing.T) {
	Case :: struct {
		text:    string,
		refusal: Refusal,
		column:  u32,
		form:    string,
	}
	cases := [?]Case {
		{"{", .Literal_Name_Missing, 2, "#{!Literal_Name_Missing}"},
		{"{= 1}", .Literal_Name_Missing, 2, "#{!Literal_Name_Missing}"},
		{"{1}", .Literal_Name_Missing, 2, "#{!Literal_Name_Missing}"},
		{"{a = 1,}", .Literal_Name_Missing, 8, "#{a = 1, !Literal_Name_Missing}"},
		{"{a.b}", .Literal_Equal_Missing, 5, "#{!Literal_Equal_Missing}"},
		{"{a 1}", .Literal_Equal_Missing, 4, "#{!Literal_Equal_Missing}"},
		{"{a == 1}", .Literal_Equal_Missing, 4, "#{!Literal_Equal_Missing}"},
		{"{a = 1", .Literal_Close_Missing, 7, "#{a = 1, !Literal_Close_Missing}"},
		{"{a = 1 b = 2}", .Literal_Close_Missing, 8, "#{a = 1, !Literal_Close_Missing}"},
		{"{a = }", .Unexpected, 6, "#{a = !Unexpected}"},
		{"{a = 1, a = 2}", .Literal_Field_Twice, 9, "#{a = 1, !Literal_Field_Twice}"},
		{"{_ = 1}", .Word_As_Name, 2, "#{!Word_As_Name}"},
		{"{in = 1}", .Word_As_Name, 2, "#{!Word_As_Name}"},
		{"f(a = 1, 2)", .Positional_After_Named, 10, "f(a = 1, !Positional_After_Named)"},
		{"f(a = 1, a = 2)", .Named_Argument_Twice, 10, "f(a = 1, !Named_Argument_Twice)"},
		{"f(_ = 1)", .Word_As_Name, 3, "f(!Word_As_Name)"},
		{"f(with = 1)", .Word_As_Name, 3, "f(!Word_As_Name)"},
		{"f(a == 1)", .Comma_Or_Close_Missing, 5, "f(a, !Comma_Or_Close_Missing)"},
		{"f(a = )", .Unexpected, 7, "f(a = !Unexpected)"},
		{"f(a = .)", .Unexpected, 7, "f(a = !Unexpected)"},
		{"f(.1)", .Unexpected, 3, "f(!Unexpected)"},
		{"f(. a)", .Unexpected, 3, "f(!Unexpected)"},
		{".", .Unexpected, 1, "!Unexpected"},
		{"f(.a.b)", .Comma_Or_Close_Missing, 5, "f(.a, !Comma_Or_Close_Missing)"},
		{"f(a = .french", .Comma_Or_Close_Missing, 14, "f(a = .french, !Comma_Or_Close_Missing)"},
		{"let", .Let_Name_Missing, 4, "let(!Let_Name_Missing)"},
		{"let 1 = 2 in 3", .Let_Name_Missing, 5, "let(!Let_Name_Missing)"},
		{"let a", .Let_Equal_Missing, 6, "let(!Let_Equal_Missing)"},
		{"let a = 1, b = 2", .Let_In_Missing, 17, "let(a = 1; b = 2; !Let_In_Missing)"},
		{"let a = 1 a", .Let_In_Missing, 11, "let(a = 1; !Let_In_Missing)"},
		{"let a = 1, a = 2 in a", .Let_Name_Twice, 12, "let(a = 1; !Let_Name_Twice)"},
		{"let in = 1 in 2", .Word_As_Name, 5, "let(!Word_As_Name)"},
		{"let a = 1 in", .Line_Ends_Too_Soon, 13, "let(a = 1; !Line_Ends_Too_Soon)"},
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
		testing.expectf(t, tree.refusal.place == place_of_offset(item.text, int(tree.refusal.place.offset)), "%q: offset mismatch", item.text)
	}
	tree := parse_of("{a = 1, a = 2}")
	testing.expect_value(t, node_text(tree, node_children(tree, tree.root)[1]), "a")
	tree = parse_of("let _ = 1 in 2")
	testing.expect_value(t, tree.refusal.refusal, Refusal.Word_As_Name)
	testing.expect_value(t, node_text(tree, node_children(tree, tree.root)[0]), "_")
}

@(test)
parse_literal_edges :: proc(t: ^testing.T) {
	tree := parse_of("{}")
	testing.expect_value(t, tree.refusal.refusal, Refusal.None)
	testing.expect_value(t, tree_form(tree, tree.root), "#{}")
	testing.expect_value(t, len(node_children(tree, tree.root)), 0)
	tree = parse_of("{ }")
	testing.expect_value(t, tree_form(tree, tree.root), "#{}")

	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, "{")
	most := min((TEXT_BYTES_MOST - 2) / 6, 26 * 26)
	for field in 0 ..< most {
		if field > 0 {
			strings.write_string(&builder, ",")
		}
		strings.write_byte(&builder, 'x')
		strings.write_byte(&builder, u8('a' + field / 26))
		strings.write_byte(&builder, u8('a' + field % 26))
		strings.write_string(&builder, "=1")
	}
	strings.write_string(&builder, "}")
	widest := strings.to_string(builder)
	testing.expect(t, len(widest) <= TEXT_BYTES_MOST)
	tree = parse_of(widest)
	testing.expect_value(t, tree.refusal.refusal, Refusal.None)
	testing.expect_value(t, len(node_children(tree, tree.root)), most)

	levels := nesting_deepest(t, "{a=", "1", "}")
	deepest := strings.concatenate({strings.repeat("{a=", levels, context.temp_allocator), "1", strings.repeat("}", levels, context.temp_allocator)}, context.temp_allocator)
	tree = parse_of(deepest)
	depth := 0
	for index := tree.root; node_at(tree, index).kind == .Record_Literal; {
		depth += 1
		index = node_child(tree, node_children(tree, index)[0])
	}
	testing.expect_value(t, depth, levels)

	// Duplicate detection past DUP_HASH_THRESHOLD (16) using String_Interner.
	storage := make_decl_storage(512, context.temp_allocator)
	db := strings.builder_make_len_cap(0, 1024, context.temp_allocator)
	strings.write_string(&db, "{\n")
	for i in 0 ..< 40 {
		fmt.sbprintf(&db, "  f_%02d = %d,\n", i, i)
	}
	strings.write_string(&db, "  f_05 = 999,\n}\n")
	dup_tree := new(Syntax_Tree, context.temp_allocator)
	parse_declaration(strings.to_string(db), storage, dup_tree)
	testing.expect_value(t, dup_tree.refusal.refusal, Refusal.Literal_Field_Twice)
}

@(test)
parse_trees_of_the_forms :: proc(t: ^testing.T) {
	Case :: struct {
		text: string,
		form: string,
	}
	cases := [?]Case {
		{"{a = 1}", "#{a = 1}"},
		{"{ a = 1 , b = 2 }", "#{a = 1, b = 2}"},
		{"{a = 1, b = \"x\", c = f(2)}", "#{a = 1, b = \"x\", c = f(2)}"},
		{"{a = {b = 1}}", "#{a = #{b = 1}}"},
		{"f({x = 1}, 2)", "f(#{x = 1}, 2)"},
		{"f(x, by = 2)", "f(x, by = 2)"},
		{"f(a = 1, b = {c = 2})", "f(a = 1, b = #{c = 2})"},
		{"sum_values(x_y)", "sum_values(x_y)"},
		{"r with {width = 10}", "(r with #{width = 10})"},
		{"r with {a = 1} with {b = 2}", "((r with #{a = 1}) with #{b = 2})"},
		{"r with s + t", "(r with (s + t))"},
		{"withdraw(x)", "withdraw(x)"},
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

	tree := parse_of("let a = 1 in let a = 2 in a")
	testing.expect_value(t, tree_form(tree, tree.root), "let(a = 1; let(a = 2; @a))")
	inner := node_children(tree, tree.root)[1]
	inner_children := node_children(tree, inner)
	inner_binding := inner_children[0]
	body := inner_children[1]
	testing.expect_value(t, node_binding(tree, body), inner_binding)

	tree = parse_of("x = let a = 1 in a")
	testing.expect_value(t, tree.assigned_name, "x")
	testing.expect_value(t, node_at(tree, tree.root).kind, Node_Kind.Let)
	testing.expect_value(t, node_place(tree, tree.root).column, u32(5))
	tree = parse_of("{width = 1}")
	field := node_children(tree, tree.root)[0]
	testing.expect_value(t, node_place(tree, field).column, u32(2))
	testing.expect_value(t, node_place(tree, node_child(tree, field)).column, u32(10))
}

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

@(test)
parse_refusals_of_functions_and_lists :: proc(t: ^testing.T) {
	Case :: struct {
		text:    string,
		refusal: Refusal,
		column:  u32,
		form:    string,
	}
	cases := [?]Case {
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
		{"(x) =>", .Line_Ends_Too_Soon, 7, "fn(x => !Line_Ends_Too_Soon)"},
		{"() =>", .Line_Ends_Too_Soon, 6, "fn( => !Line_Ends_Too_Soon)"},
		{"(x) => 1 +", .Line_Ends_Too_Soon, 11, "fn(x => (1 + !Line_Ends_Too_Soon))"},
		{"(x) => 1 => 2", .Unexpected, 10, "!Unexpected(fn(x => 1))"},
		{"x => 1", .Unexpected, 3, "!Unexpected(x)"},
		{"x=>1", .Unexpected, 2, "!Unexpected(x)"},
		{"f(a => 1)", .Comma_Or_Close_Missing, 5, "f(a, !Comma_Or_Close_Missing)"},
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
		testing.expectf(t, tree.refusal.place == place_of_offset(item.text, int(tree.refusal.place.offset)), "%q: offset mismatch", item.text)
	}
	tree := parse_of("(x, x) => 1")
	refused := node_children(tree, tree.root)[1]
	testing.expect_value(t, node_text(tree, refused), "x")
}

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

	tree := parse_of("(x) => (x) => x")
	testing.expect_value(t, tree_form(tree, tree.root), "fn(x => fn(x => @x))")
	inner := node_children(tree, tree.root)[1]
	inner_c := node_children(tree, inner)
	testing.expect_value(t, node_binding(tree, inner_c[1]), inner_c[0])

	tree = parse_of("let x = 1 in (x) => x")
	function := node_children(tree, tree.root)[1]
	fn_c := node_children(tree, function)
	testing.expect_value(t, node_binding(tree, fn_c[1]), fn_c[0])

	tree = parse_of("(x) => (y) => x")
	outer := tree.root
	testing.expect_value(t, node_function(tree, outer), NO_NODE)
	outer_c := node_children(tree, outer)
	testing.expect_value(t, node_function(tree, outer_c[0]), outer)
	inner = outer_c[1]
	testing.expect_value(t, node_function(tree, inner), outer)
	inner_c = node_children(tree, inner)
	testing.expect_value(t, node_function(tree, inner_c[0]), inner)
	testing.expect_value(t, node_function(tree, inner_c[1]), inner)

	tree = parse_of("1 + (a) => a")
	_, fn_rhs := node_binary_children(tree, tree.root)
	open, _ := node_function_offsets(tree, fn_rhs)
	testing.expect_value(t, open, 4)
	testing.expect_value(t, node_text(tree, fn_rhs), "=>")
}

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
	tree = parse_of("1 // 2 + 3")
	testing.expect_value(t, tree.node_count, 1)
}

@(test)
parse_function_edges :: proc(t: ^testing.T) {
	tree := parse_of("(a,b,c,d,e,f,g,h,i,j,k,l) => a")
	testing.expect_value(t, tree.refusal.refusal, Refusal.None)
	parameters := 0
	for child in node_children(tree, tree.root) {
		if node_at(tree, child).kind == .Parameter {
			parameters += 1
		}
	}
	testing.expect_value(t, parameters, ARGUMENT_CAPACITY)

	levels := nesting_deepest(t, "()=>", "1", "")
	deepest := strings.concatenate({strings.repeat("()=>", levels, context.temp_allocator), "1"}, context.temp_allocator)
	tree = parse_of(deepest)
	depth := 0
	for index := tree.root; node_at(tree, index).kind == .Function; index = node_children(tree, index)[0] {
		depth += 1
	}
	testing.expect_value(t, depth, levels)

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
	testing.expect_value(t, len(node_children(tree, tree.root)), items)
}

@(test)
parse_layer5_forms_and_refusals :: proc(t: ^testing.T) {
	VALID_HASH :: "blake3:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

	Refusal_Case :: struct {
		text:    string,
		refusal: Refusal,
		column:  u32,
	}
	refusals := [?]Refusal_Case {
		{"blake3:", .Hash_Not_Valid, 1},
		{"blake3:0", .Hash_Not_Valid, 1},
		{"blake3:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcde", .Hash_Not_Valid, 1},
		{"blake3:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0", .Hash_Not_Valid, 1},
		{"blake3:0123456789ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef", .Hash_Not_Valid, 1},
		{"module(blake3:zzzz)", .Hash_Not_Valid, 8},
		{"if true", .If_Then_Missing, 8},
		{"if true 1 else 2", .If_Then_Missing, 9},
		{"if true then 1", .If_Else_Missing, 15},
		{"if true then 1 2", .If_Else_Missing, 16},
		{"if true then 1 else", .Line_Ends_Too_Soon, 20},
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

@(test)
parse_multiline_declarations_and_bounds :: proc(t: ^testing.T) {
	storage := make_decl_storage(1024, context.temp_allocator)
	tree := new(Syntax_Tree, context.temp_allocator)

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
		] |> map((x) => x + 1),
	},
}
`
	parse_declaration(source, storage, tree)
	testing.expect_value(t, tree.refusal.refusal, Refusal.None)
	testing.expect(t, tree.node_count > 10)
	root := node_at(tree, tree.root)
	testing.expect(t, root != nil && root.kind == .Let && node_place(tree, tree.root).line == 2)

	parse_declaration("a = 1", storage, tree)
	testing.expect_value(t, tree.assigned_name, "")
	testing.expect_value(t, node_at(tree, tree.root).kind, Node_Kind.Binary)
	testing.expect_value(t, node_operator(tree, tree.root), Operator.Equal)

	deep := strings.concatenate({strings.repeat("(", 300, context.temp_allocator), "1", strings.repeat(")", 300, context.temp_allocator)}, context.temp_allocator)
	parse_declaration(deep, storage, tree, DECLARATION_TEXT_BYTES_MOST, 64)
	testing.expect_value(t, tree.refusal.refusal, Refusal.Nesting_Too_Deep)

	tiny_nodes: [4]Ast_Node
	tiny_extra: [4]Node_Index
	tiny_scratch: [4]Node_Index
	parse_declaration("{ a = 1, b = 2, c = 3 }", {nodes = tiny_nodes[:], extra_children = tiny_extra[:], scratch_children = tiny_scratch[:]}, tree)
	testing.expect_value(t, tree.refusal.refusal, Refusal.Nodes_Full)

	parse_declaration("1 + 2 + 3", storage, tree, text_bytes_most = 4)
	testing.expect_value(t, tree.refusal.refusal, Refusal.Text_Too_Long)
}

// L4 parser features and refusals: string escapes, ${...} interpolation,
// && / || / ! / ++ precedence, and record destructuring patterns.
@(test)
lex_v2_l4_parser_forms_and_refusals :: proc(t: ^testing.T) {
	// Escapes decoder edge cases (control characters refused per text_encoding).
	buf: [64]u8
	w, _, ok := decode_text_escapes(`a\\b\"c\$d\u{41}\u{1F600}`, buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, string(buf[:w]), "a\\b\"c$dA😀")

	bad_escapes := [?]string{
		`\q`,
		`\n`,
		`\r`,
		`\t`,
		`\`,
		`\u{}`,
		`\u{0}`,
		`\u{0A}`,
		`\u{1F}`,
		`\u{7F}`,
		`\u{80}`,
		`\u{9F}`,
		`\u{1234567}`,
		`\u{D800}`,
		`\u{DFFF}`,
		`\u{110000}`,
		`\u{41`,
		`\u41`,
	}
	for bad in bad_escapes {
		_, _, bok := decode_text_escapes(bad, buf[:])
		testing.expectf(t, !bok, "escape %q should be refused", bad)
	}

	// Refused forms in parser.
	Refusal_Case :: struct {
		text:    string,
		refusal: Refusal,
	}
	bad_cases := [?]Refusal_Case {
		{`"bad \q"`, .Escape_Not_Valid},
		{`"ctl \n"`, .Escape_Not_Valid},
		{`"ctl \r"`, .Escape_Not_Valid},
		{`"ctl \t"`, .Escape_Not_Valid},
		{`"ctl \u{0}"`, .Escape_Not_Valid},
		{`"ctl \u{7F}"`, .Escape_Not_Valid},
		{`"ctl \u{9F}"`, .Escape_Not_Valid},
		{`"surrogate \u{D800}"`, .Escape_Not_Valid},
		{`"too high \u{110000}"`, .Escape_Not_Valid},
		{`"interp ${1 + 2"`, .Interpolation_Close_Missing},
		{`let { a, a } = r in a`, .Pattern_Field_Twice},
		{`let { ..., a } = r in a`, .Pattern_Rest_Not_Last},
		{`let { 123 } = r in 1`, .Pattern_Field_Missing},
		{`let { a b } = r in a`, .Pattern_Close_Missing},
		{`let r @ x = 1 in r`, .Pattern_At_Missing_Brace},
		{`({ a, a }) => a`, .Pattern_Field_Twice},
		{`({ ..., a }) => a`, .Pattern_Rest_Not_Last},
		{`(r @ x) => r`, .Pattern_At_Missing_Brace},
	}
	bufs := new(Console_Tree_Buffers, context.temp_allocator)
	tree := new(Syntax_Tree, context.temp_allocator)
	for bc in bad_cases {
		parse_console(bc.text, {}, bufs, tree)
		testing.expectf(t, tree.refusal.refusal == bc.refusal, "%q: got %v, want %v", bc.text, tree.refusal.refusal, bc.refusal)
	}

	// Accepted forms & precedence.
	ok_cases := [?]string {
		`"hello \"world\" \\ \$1 \u{41}"`,
		`"a ${1 + 2} b ${"nested"} c"`,
		`!true && false || 1 = 1`,
		`[1, 2] ++ [3, 4] = [1, 2, 3, 4]`,
		`let { a, b = 10, ... } = r in a + b`,
		`let whole @ { a, b } = r in a`,
		`({ a, b = 2 }) => a + b`,
		`(r @ { a, ... }) => a`,
	}
	for src in ok_cases {
		parse_console(src, {}, bufs, tree)
		testing.expectf(t, tree.refusal.refusal == .None, "%q: unexpected refusal %v", src, tree.refusal.refusal)
	}
}

@(test)
lex_v3_grammar_parse_and_refusals :: proc(t: ^testing.T) {
	Bad_Case :: struct {
		text:    string,
		refusal: Refusal,
	}
	bad_cases := [?]Bad_Case {
		{`{ a.b = 1, a.b = 2 }`, .Literal_Field_Twice},
		{`{ a = { b = 1 }, a.b = 2 }`, .Literal_Path_Conflict},
		{`{ a.b = 1, a = { b = 2 } }`, .Literal_Path_Conflict},
		{`{ a.b.c = 1, a.b = 2 }`, .Literal_Path_Conflict},
		{`{ a..b = 1 }`, .Literal_Name_Missing},
		{`{ a. = 1 }`, .Literal_Name_Missing},
		{`{ a.let = 1 }`, .Word_As_Name},
		{`{ for 123 in xs: "a" = 1 }`, .Comp_Bind_Missing},
		{`{ for x xs: "a" = 1 }`, .Comp_In_Missing},
		{`{ for x in xs "a" = 1 }`, .Comp_Colon_Missing},
		{`{ for x in xs: "a" 1 }`, .Comp_Equal_Missing},
		{`match x 1 => 2`, .Match_Open_Missing},
		{`match x {}`, .Match_Empty},
		{`match x { 1 2 }`, .Match_Arrow_Missing},
		{`match x { 1 => 2 3 => 4 }`, .Match_Close_Missing},
		{`match x { [1] => 2 }`, .Match_Pattern_Expected},
		{`match x { { a = y, b = y } => y }`, .Match_Duplicate_Bind},
		{`match x { r @ { r } => r }`, .Match_Duplicate_Bind},
		{`(x: UnknownKind) => x`, .Param_Kind_Unknown},
		{`(x: Integer[bogus]) => x`, .Param_Unit_Not_Valid},
		{`(x: Text[MiB]) => x`, .Param_Unit_Not_Valid},
		{`(x: Integer[MiB 1]) => x`, .Param_Unit_Not_Valid},
		{`({ x: BadKind }) => x`, .Param_Kind_Unknown},
	}
	bufs := new(Console_Tree_Buffers, context.temp_allocator)
	tree := new(Syntax_Tree, context.temp_allocator)
	for bc in bad_cases {
		parse_console(bc.text, {}, bufs, tree)
		testing.expectf(t, tree.refusal.refusal == bc.refusal, "%q: got %v, want %v", bc.text, tree.refusal.refusal, bc.refusal)
	}

	ok_cases := [?]string {
		`{ host, port, src }`,
		`{ host, port = 8080 }`,
		`plan with { display.font = .spleen, net.port = 8080 }`,
		`64 MiB + 2048 pages`,
		`120 ms`,
		`{ for x in xs: x = x }`,
		`{ for { name, val } in xs if val > 0: name = val }`,
		`match x { -1 => "neg", 0 => "zero", .Verify => "v", { mode = .Verify, port = p, ... } if p > 0 => p, r @ { a } => a, _ => 0 }`,
		`cfg.port ?? 8080`,
		`cfg.net.port ?? fallback.port ?? 8080`,
		`(src: Tree_Ref, size: Integer[MiB], opt: Enum = .Speed) => size`,
		`({ src: Tree_Ref, opt: Enum = .Speed, ... }) => src`,
	}
	for src in ok_cases {
		parse_console(src, {}, bufs, tree)
		testing.expectf(t, tree.refusal.refusal == .None, "%q: unexpected refusal %v", src, tree.refusal.refusal)
	}

	// Verify unit literals parse exact Integer_Unit in Ast_Node.aux without crossing newlines.
	parse_declaration("1\ns", console_tree_storage(bufs), tree)
	testing.expect_value(t, tree.refusal.refusal, Refusal.Unexpected)

	parse_console("64 MiB", {}, bufs, tree)
	testing.expect_value(t, tree.refusal.refusal, Refusal.None)
	testing.expect_value(t, node_integer(tree, tree.root), i64(64))
	u := node_integer_unit(tree, tree.root)
	testing.expect_value(t, u.kind, value_kinds.Value_Kind.Size)
	testing.expect_value(t, u.unit, u8(value_kinds.Size_Unit.Mebibytes))

	// Match arm duplicate-binding detection works past 64 bindings both without
	// parser.dup (console tree-scan tier) and with parser.dup (declaration hash tier).
	ok_arm_b := strings.builder_make(context.temp_allocator)
	strings.write_string(&ok_arm_b, "match x { { ")
	for i in 0 ..< 70 {
		if i > 0 {
			strings.write_string(&ok_arm_b, ", ")
		}
		fmt.sbprintf(&ok_arm_b, "f%d = v%d", i, i)
	}
	strings.write_string(&ok_arm_b, " } => v69 }")
	ok_arm := strings.to_string(ok_arm_b)

	dup_arm_b := strings.builder_make(context.temp_allocator)
	strings.write_string(&dup_arm_b, "match x { { ")
	for i in 0 ..< 70 {
		if i > 0 {
			strings.write_string(&dup_arm_b, ", ")
		}
		fmt.sbprintf(&dup_arm_b, "f%d = v%d", i, i)
	}
	strings.write_string(&dup_arm_b, ", f70 = v68 } => v68 }")
	dup_arm := strings.to_string(dup_arm_b)

	// Console storage (no dup hash table -> promotes past 16 to exact tree scan).
	parse_console(ok_arm, {}, bufs, tree)
	testing.expect_value(t, tree.refusal.refusal, Refusal.None)
	parse_console(dup_arm, {}, bufs, tree)
	testing.expect_value(t, tree.refusal.refusal, Refusal.Match_Duplicate_Bind)

	// Declaration storage with String_Interner + dup table (promotes past 16 to O(1) hash).
	ibytes := make([]u8, 16 * 1024, context.temp_allocator)
	ispans := make([]Sym_Span, 512, context.temp_allocator)
	ictrls := make([]u8, 1024, context.temp_allocator)
	irefs := make([]u32, 1024, context.temp_allocator)
	interner, iok := interner_init(ictrls, irefs, ispans, ibytes, 11)
	testing.expect(t, iok)
	dup_ctrls := make([]u8, 1024, context.temp_allocator)
	dup_refs := make([]u32, 1024, context.temp_allocator)
	dup_keys := make([]u64, 512, context.temp_allocator)
	dup_nodes := make([]Node_Index, 512, context.temp_allocator)
	decl_storage := console_tree_storage(bufs)
	decl_storage.interner = &interner
	decl_storage.dup_controls = dup_ctrls
	decl_storage.dup_refs = dup_refs
	decl_storage.dup_keys = dup_keys
	decl_storage.dup_nodes = dup_nodes

	parse_declaration(ok_arm, decl_storage, tree)
	testing.expect_value(t, tree.refusal.refusal, Refusal.None)
	parse_declaration(dup_arm, decl_storage, tree)
	testing.expect_value(t, tree.refusal.refusal, Refusal.Match_Duplicate_Bind)
}
