// The parser of Lex: a text becomes a compact SoA syntax tree with 16-byte
// AST nodes, contiguous child slices, native `|>` pipe and `_` placeholder
// support, and on-demand line/column resolution (src/md/features/declarations.md,
// "Lex v2 engine: compact AST, register bytecode VM, sorted shapes, and
// incremental caching").
//
//   line       = name "=" pipeline | pipeline
//   pipeline   = expression { "|>" stage }
//   stage      = name | name "(" [ arguments ] ")"
//   expression = with_expr [ ("=" | "!=" | "<" | "<=" | ">" | ">=") with_expr ]
//   with_expr  = sum { "with" sum }
//   sum        = term { ("+" | "-") term }
//   term       = factor { ("*" | "/" | "%") factor }
//   factor     = "-" factor | postfix
//   postfix    = primary { "." field_name }
//   primary    = integer | "true" | "false" | "text" | hash | "." name
//              | name "(" [ arguments ] ")" | name record_lit | name
//              | "(" [ name { "," name } ] ")" "=>" pipeline
//              | "(" pipeline ")"
//              | record_lit | list_lit
//              | "let" binding { "," binding } "in" pipeline
//              | "if" pipeline "then" pipeline "else" pipeline
//
// The package has no state, calls no allocator and makes no kernel call:
// every buffer is supplied by the caller via Tree_Storage or Console_Tree_Buffers.
package lex_parser

import "modus:console_condition"
import "modus:console_language"
import module "modus:contract/module"
import "modus:contract/text_encoding"
import "modus:hash_table"
import "modus:line_editor"

// The bytes of the longest console line.
TEXT_BYTES_MOST :: line_editor.LINE_CAPACITY

// Nesting depth bound for console lines and declarations (Format/safety bound:
// keeps recursive-descent stack usage under 32 KiB).
LINE_PARSE_DEPTH_LIMIT :: 256
DECLARATION_PARSE_DEPTH_LIMIT :: 256

// Maximum declaration source file size in bytes (u32 span_off holds offsets).
DECLARATION_TEXT_BYTES_MOST :: 16 * 1024 * 1024

// Console line node capacity: each node consumes at least one byte, plus one
// optional Refused node.
NODE_CAPACITY :: TEXT_BYTES_MOST + 1

// Console side-buffer capacities (inline capacities for one console line).
CONSOLE_INT_CONST_CAPACITY :: 256
CONSOLE_CONDITION_CAPACITY :: 64

// Maximum arguments of a call / parameters of a function (Format property:
// matches module.PARAMETER_CAPACITY).
ARGUMENT_CAPACITY :: module.PARAMETER_CAPACITY

// Node index inside Syntax_Tree.nodes.
Node_Index :: distinct i32

// Sentinel for absent node.
NO_NODE :: Node_Index(-1)
NO_NODE_U32 :: ~u32(0)

// What the parser reads for a parameter of a command.
Parameter_Form :: enum u8 {
	Expression  = 0,
	Fact_Name   = 1,
	Condition   = 2,
	Field_Names = 3,
}

// Caller-supplied lookup for command parameter forms.
Form_Lookup :: struct {
	data:    rawptr,
	form_of: proc "contextless" (data: rawptr, command_name: string, index: int) -> Parameter_Form,
}

form_of :: proc "contextless" (lookup: Form_Lookup, command_name: string, index: int) -> Parameter_Form {
	return lookup.form_of == nil ? .Expression : lookup.form_of(lookup.data, command_name, index)
}

// Kinds of AST nodes (1 byte).
Node_Kind :: enum u8 {
	Integer        = 0,  // span_off..a, sub=0 -> inline i32(b); sub=1 -> int_consts[b]
	Text           = 1,  // span_off..a (includes quotes)
	Name           = 2,  // span_off..a
	Call           = 3,  // span_off..b (callee name), extra_children[a : a + aux], sub = Call_Flags
	Negate         = 4,  // span_off..b ("-"), child = a
	Binary         = 5,  // span_off..span_off+aux, sub = Operator, left = a, right = b
	Condition      = 6,  // span_off, sub = Refusal, value = a, conditions[b]
	Fact_Name      = 7,  // span_off..a, sub = Refusal
	Refused        = 8,  // span_off..b, sub = Refusal, before = a
	Field_Names    = 9,  // span_off..a, sub = Refusal
	Record_Literal = 10, // span_off ("{"), extra_children[a : a + b]
	Literal_Field  = 11, // span_off..b (field name), value = a
	Named_Argument = 12, // span_off..b (arg name), value = a
	Let            = 13, // span_off ("let"), extra_children[a : a + b] (bindings then body)
	Let_Binding    = 14, // span_off..b (binding name), value = a
	Member         = 15, // span_off..a (includes '.')
	Function       = 16, // span_off ('('), b = arrow_end, extra_children[a : a + aux] (params then body)
	Parameter      = 17, // span_off..a
	List_Literal   = 18, // span_off ("["), extra_children[a : a + b]
	Hash           = 19, // span_off..a
	Boolean        = 20, // span_off..a, sub = 1 (true) / 0 (false)
	If             = 21, // span_off ("if"), extra_children[a : a + aux] (cond, then, else)
	Field_Select   = 22, // span_off..b (field name), base = a
	Pipe           = 23, // span_off ("|>"), aux = 2, left = a, right_call = b
	Placeholder    = 24, // span_off..a ("_")
	Logical_Not    = 25, // span_off..b ("!"), child = a
	Text_Interp    = 26, // span_off ('"'), extra_children[a : a + b] (Text segments & exprs)
	Pattern_Record = 27, // span_off ('{' or as_name), sub = PAT_FLAG_*, extra_children[a : a + b]
	Pattern_Field  = 28, // span_off..b (field name), a = default expr or NO_NODE_U32
}

// Flags stored in Ast_Node.sub for .Call nodes.
CALL_FLAG_IN_PIPE :: u8(1 << 0)
CALL_FLAG_HAS_PLACEHOLDER :: u8(1 << 1)

// Flags stored in Ast_Node.sub for .Text nodes.
TEXT_FLAG_ESCAPED :: u8(1 << 0)
TEXT_FLAG_SEGMENT :: u8(1 << 1)

// Flags stored in Ast_Node.sub for .Pattern_Record nodes.
PAT_FLAG_REST :: u8(1 << 0)
PAT_FLAG_HAS_AS :: u8(1 << 1)

// Flag stored in Ast_Node.sub for .Let_Binding when LHS is a Pattern_Record
// (in which case a = rhs_expr, b = pattern_node).
LET_BINDING_PATTERN :: u8(1 << 0)

// Operators of a Binary node.
Operator :: enum u8 {
	None             = 0,
	Add              = 1,
	Subtract         = 2,
	Multiply         = 3,
	Divide           = 4,
	Remainder        = 5,
	With             = 6,
	Equal            = 7,
	Not_Equal        = 8,
	Less             = 9,
	Less_Or_Equal    = 10,
	Greater          = 11,
	Greater_Or_Equal = 12,
	Logical_And      = 13,
	Logical_Or       = 14,
	List_Concat      = 15,
}

@(rodata)
OPERATOR_TEXTS := [Operator]string {
	.None             = "",
	.Add              = "+",
	.Subtract         = "-",
	.Multiply         = "*",
	.Divide           = "/",
	.Remainder        = "%",
	.With             = "with",
	.Equal            = "=",
	.Not_Equal        = "!=",
	.Less             = "<",
	.Less_Or_Equal    = "<=",
	.Greater          = ">",
	.Greater_Or_Equal = ">=",
	.Logical_And      = "&&",
	.Logical_Or       = "||",
	.List_Concat      = "++",
}

@(rodata)
WORDS_OF_LEX := [?]string{"_", "let", "in", "with", "if", "then", "else", "true", "false"}

name_valid :: proc "contextless" (name: string) -> bool {
	if len(name) == 0 || word_of_lex(name) {
		return false
	}
	for index in 0 ..< len(name) {
		character := name[index]
		letter := character >= 'a' && character <= 'z' || character >= 'A' && character <= 'Z' || character == '_'
		if !letter && !(index > 0 && character >= '0' && character <= '9') {
			return false
		}
	}
	return true
}

word_of_lex :: proc "contextless" (name: string) -> bool {
	for word in WORDS_OF_LEX {
		if name == word {
			return true
		}
	}
	return false
}

// Parse refusal codes.
Refusal :: enum u8 {
	None                      = 0,
	Text_Too_Long             = 1,
	Nodes_Full                = 2,
	Line_Ends_Too_Soon        = 3,
	Unexpected                = 4,
	Number_Too_Large          = 5,
	Text_Without_End_Quote    = 6,
	Close_Parenthesis_Missing = 7,
	Comma_Or_Close_Missing    = 8,
	Too_Many_Arguments        = 9,
	Fact_Name_Missing         = 10,
	Condition_Head_Refused    = 11,
	Field_Name_Missing        = 12,
	Literal_Close_Missing     = 13,
	Literal_Name_Missing      = 14,
	Literal_Equal_Missing     = 15,
	Literal_Field_Twice       = 16,
	Named_Argument_Twice      = 17,
	Positional_After_Named    = 18,
	Let_Name_Missing          = 19,
	Let_Equal_Missing         = 20,
	Let_In_Missing            = 21,
	Let_Name_Twice            = 22,
	Word_As_Name              = 23,
	Parameter_Name_Missing    = 24,
	Parameter_Twice           = 25,
	Too_Many_Parameters       = 26,
	List_Close_Missing        = 27,
	Hash_Not_Valid            = 28,
	If_Then_Missing           = 29,
	If_Else_Missing           = 30,
	Nesting_Too_Deep          = 31,
	Thin_Arrow                = 32,
	Pipe_No_Left              = 33, // "|>" with no expression on its left.
	Pipe_Line_End             = 34, // Text ends after "|>".
	Pipe_Not_A_Call           = 35, // "|>" not followed by a call or command name.
	Lone_Bar                  = 36, // "|" with no ">" after it.
	Placeholder_Not_Whole       = 37, // "_" used inside an expression in a piped call argument.
	Placeholder_Twice           = 38, // Two "_" placeholders in one piped call.
	Placeholder_Nested          = 39, // "_" inside a call nested in a piped call.
	Placeholder_Without_Pipe    = 40, // "_" as a call argument with no preceding "|>".
	Escape_Not_Valid            = 41, // Unknown backslash escape or control/surrogate/out-of-range \u{...}.
	Interpolation_Close_Missing = 42, // Missing "}" closing a "${...}" string interpolation.
	Pattern_Field_Missing       = 43, // Missing field name inside a destructuring pattern "{ ... }".
	Pattern_Close_Missing       = 44, // Missing "}" closing a destructuring pattern.
	Pattern_Field_Twice         = 45, // Duplicate field name inside one destructuring pattern.
	Pattern_Rest_Not_Last       = 46, // Fields written after "..." in a destructuring pattern.
	Pattern_At_Missing_Brace    = 47, // "name @" not followed by "{ ... }".
}

// Source position computed on demand from byte offset.
Place :: struct {
	line:   u32, // From 1.
	column: u32, // From 1, in bytes.
	offset: u32, // From 0, in bytes from start of text.
}

// First refusal recorded during parse.
Refusal_Record :: struct {
	refusal: Refusal,
	place:   Place,
	value:   u64,
}

// Compact 16-byte AST node with direct inline (a, b) payloads for 0/1/2-child
// nodes and contiguous extra_children slices for variable-arity nodes.
Ast_Node :: struct {
	kind:     Node_Kind,
	sub:      u8,
	aux:      u16,
	span_off: u32,
	a:        u32,
	b:        u32,
}
#assert(size_of(Ast_Node) == 16)

// Cold side record for console `where` Condition nodes (not allocated in
// declaration mode).
Condition_Extra :: struct {
	head:         console_condition.Head,
	refusal:      console_condition.Refusal,
	end:          u32,
	member_alone: bool,
}

// Caller-supplied storage slices for parsing one Syntax_Tree.
Tree_Storage :: struct {
	nodes:            []Ast_Node,
	extra_children:   []Node_Index,
	scratch_children: []Node_Index,
	int_consts:       []i64,
	conditions:       []Condition_Extra,
	// L1 name-binding side slices (parallel to nodes; nil if unused).
	bindings:         []Node_Index,
	functions:        []Node_Index,
	// Optional compile-time interner + O(1) duplicate-name index for large
	// records and let blocks (> 16 entries).
	interner:         ^String_Interner,
	dup_controls:     []u8,
	dup_refs:         []u32,
	dup_keys:         []u64,
	dup_nodes:        []Node_Index,
}

// Pre-sized buffers for parsing a single console line (caller-owned, never
// embedded inside Syntax_Tree).
Console_Tree_Buffers :: struct {
	nodes:            [NODE_CAPACITY]Ast_Node,
	extra_children:   [NODE_CAPACITY]Node_Index,
	scratch_children: [NODE_CAPACITY]Node_Index,
	int_consts:       [CONSOLE_INT_CONST_CAPACITY]i64,
	conditions:       [CONSOLE_CONDITION_CAPACITY]Condition_Extra,
	bindings:         [NODE_CAPACITY]Node_Index,
	functions:        [NODE_CAPACITY]Node_Index,
}

console_tree_storage :: proc "contextless" (buf: ^Console_Tree_Buffers) -> Tree_Storage {
	return {
		nodes            = buf.nodes[:],
		extra_children   = buf.extra_children[:],
		scratch_children = buf.scratch_children[:],
		int_consts       = buf.int_consts[:],
		conditions       = buf.conditions[:],
		bindings         = buf.bindings[:],
		functions        = buf.functions[:],
	}
}

// Lightweight SoA syntax tree handle (~160 bytes; zero inline node arrays).
Syntax_Tree :: struct {
	text:            string,
	nodes:           []Ast_Node,
	node_count:      int,
	extra_children:  []Node_Index,
	extra_count:     int,
	int_consts:      []i64,
	int_const_count: int,
	conditions:      []Condition_Extra,
	condition_count: int,
	bindings:        []Node_Index,
	functions:       []Node_Index,
	root:            Node_Index,
	assigned_name:   string,
	refusal:         Refusal_Record,
}

// Duplicate-name lookup helper backed by Slice_Hash_Index over (parent<<32)|sym.
@(private)
Dup_Table :: struct {
	index: hash_table.Slice_Hash_Index(u32),
	keys:  []u64,
	nodes: []Node_Index,
	count: u32,
}

@(private)
dup_table_hash_of_ref :: proc "contextless" (owner: rawptr, reference: u64) -> u64 {
	dt := (^Dup_Table)(owner)
	idx := int(reference)
	if idx < 0 || idx >= len(dt.keys) {
		return 0
	}
	return hash_table.slice_index_hash_word(&dt.index, dt.keys[idx])
}

// Threshold above which a record literal or let switches from inline linear
// scan (1 cache line) to O(1) hash lookup in Dup_Table.
@(private)
DUP_HASH_THRESHOLD :: 16

@(private)
Parser :: struct {
	tree:               ^Syntax_Tree,
	lookup:             Form_Lookup,
	scratch:            []Node_Index,
	scratch_top:        int,
	interner:           ^String_Interner,
	dup:                Dup_Table,
	position:           int,
	function:           Node_Index,
	multiline:          bool,
	trailing_commas:    bool,
	depth:              int,
	depth_limit:        int,
	// Tracks pipe-RHS call context for native `_` placeholder validation.
	pipe_call_depth:    int,        // >0 when inside the argument list of a piped RHS call.
	in_nested_call:     bool,       // true when inside a call nested inside a piped RHS call.
	in_direct_pipe_arg: bool,       // true only at the start of a direct argument of a piped RHS call.
	pipe_call_node:     Node_Index, // The enclosing piped RHS Call node.
}

// parse_console reads one console line into `tree` backed by `buf`.
parse_console :: proc "contextless" (text: string, lookup: Form_Lookup, buf: ^Console_Tree_Buffers, tree: ^Syntax_Tree) {
	parse_with_storage(text, lookup, console_tree_storage(buf), tree, TEXT_BYTES_MOST, false, false, true, LINE_PARSE_DEPTH_LIMIT)
}

// parse_declaration reads a multi-line .lex declaration file into `tree`
// backed by caller-owned `storage`.
parse_declaration :: proc "contextless" (
	text: string,
	storage: Tree_Storage,
	tree: ^Syntax_Tree,
	text_bytes_most: int = DECLARATION_TEXT_BYTES_MOST,
	depth_limit: int = DECLARATION_PARSE_DEPTH_LIMIT,
) {
	parse_with_storage(text, {}, storage, tree, text_bytes_most, true, true, false, depth_limit)
}

// parse_with_storage is the single entry point for parsing into caller slices.
parse_with_storage :: proc "contextless" (
	text: string,
	lookup: Form_Lookup,
	storage: Tree_Storage,
	tree: ^Syntax_Tree,
	text_bytes_most: int,
	multiline, trailing_commas, allow_assignment: bool,
	depth_limit: int,
) {
	tree^ = {
		text           = text,
		nodes          = storage.nodes,
		extra_children = storage.extra_children,
		int_consts     = storage.int_consts,
		conditions     = storage.conditions,
		bindings       = storage.bindings,
		functions      = storage.functions,
		root           = NO_NODE,
	}
	parser := Parser {
		tree            = tree,
		lookup          = lookup,
		scratch         = storage.scratch_children,
		interner        = storage.interner,
		function        = NO_NODE,
		multiline       = multiline,
		trailing_commas = trailing_commas,
		depth_limit     = depth_limit,
		pipe_call_node  = NO_NODE,
	}
	if storage.interner != nil && len(storage.dup_controls) >= hash_table.GROUP_WIDTH && len(storage.dup_keys) > 0 && len(storage.dup_nodes) >= len(storage.dup_keys) {
		if idx, ok := hash_table.slice_index_init(u32, storage.dup_controls, storage.dup_refs, storage.interner.index.prepared_seed); ok {
			parser.dup = {
				index = idx,
				keys  = storage.dup_keys,
				nodes = storage.dup_nodes,
				count = 0,
			}
		}
	}
	if len(text) > text_bytes_most {
		tree.root = refuse(&parser, .Text_Too_Long, text_bytes_most, len(text), NO_NODE, u64(len(text)))
		return
	}
	if allow_assignment {
		name := read_name(&parser)
		name_start := parser.position - len(name)
		if name == "let" && let_assignment_read(&parser) {
			return
		}
		if len(name) > 0 && equal_accept(&parser) {
			if word_of_lex(name) {
				tree.root = refuse(&parser, .Word_As_Name, name_start, name_start + len(name), NO_NODE)
				return
			}
			tree.assigned_name = name
		} else {
			parser.position = 0
		}
	}
	expr := pipeline_read(&parser)
	if refused(&parser) {
		tree.root = expr
		return
	}
	if peek(&parser) != 0 {
		if peek(&parser) == '|' {
			tree.root = refuse(&parser, .Lone_Bar, parser.position, parser.position + 1, expr)
			return
		}
		tree.root = refuse(&parser, .Unexpected, parser.position, len(text), expr)
		return
	}
	tree.root = expr
}

@(private)
let_assignment_read :: proc "contextless" (parser: ^Parser) -> bool {
	tree := parser.tree
	let_end := parser.position
	name := read_name(parser)
	if len(name) > 0 && !word_of_lex(name) && equal_accept(parser) {
		value := pipeline_read(parser)
		if !refused(parser) && peek(parser) == 0 {
			tree.root, tree.assigned_name = value, name
			return true
		}
	}
	tree.node_count, tree.extra_count, tree.int_const_count, tree.condition_count = 0, 0, 0, 0
	tree.refusal, tree.assigned_name = {}, ""
	parser.position = let_end
	parser.scratch_top = 0
	parser.function = NO_NODE
	parser.depth = 0
	parser.pipe_call_depth = 0
	parser.in_nested_call = false
	parser.in_direct_pipe_arg = false
	parser.pipe_call_node = NO_NODE
	if parser.dup.index.group_count > 0 {
		hash_table.slice_index_clear(&parser.dup.index)
		parser.dup.count = 0
	}
	return false
}

// ---- Public SoA AST accessors.

node_at :: proc "contextless" (tree: ^Syntax_Tree, index: Node_Index) -> ^Ast_Node {
	if tree == nil || index < 0 || int(index) >= tree.node_count || int(index) >= len(tree.nodes) {
		return nil
	}
	return &tree.nodes[int(index)]
}

node_place :: proc "contextless" (tree: ^Syntax_Tree, index: Node_Index) -> Place {
	node := node_at(tree, index)
	if node == nil {
		return {}
	}
	if node.kind == .Function {
		// Place of a Function node is its "=>" arrow (matches v1 semantics).
		arrow_start := node.b >= 2 ? int(node.b) - 2 : int(node.span_off)
		return place_of_offset(tree.text, arrow_start)
	}
	return place_of_offset(tree.text, int(node.span_off))
}

node_span :: proc "contextless" (tree: ^Syntax_Tree, index: Node_Index) -> (start, end: int) {
	node := node_at(tree, index)
	if node == nil {
		return 0, 0
	}
	text_len := len(tree.text)
	switch node.kind {
	case .Integer, .Boolean, .Text, .Name, .Member, .Hash, .Parameter, .Placeholder, .Fact_Name, .Field_Names:
		start = min(int(node.span_off), text_len)
		end = clamp(int(node.a), start, text_len)
	case .Negate, .Logical_Not, .Field_Select, .Literal_Field, .Named_Argument, .Refused, .Call, .Pattern_Field:
		start = min(int(node.span_off), text_len)
		end = clamp(int(node.b), start, text_len)
	case .Let_Binding:
		start = min(int(node.span_off), text_len)
		if (node.sub & LET_BINDING_PATTERN) != 0 {
			end = clamp(start + 1, start, text_len)
		} else {
			end = clamp(int(node.b), start, text_len)
		}
	case .Binary, .Pipe:
		start = min(int(node.span_off), text_len)
		end = clamp(start + int(node.aux), start, text_len)
	case .Record_Literal, .List_Literal, .Text_Interp, .Pattern_Record:
		start = min(int(node.span_off), text_len)
		end = clamp(start + 1, start, text_len)
	case .Let:
		start = min(int(node.span_off), text_len)
		end = clamp(start + len("let"), start, text_len)
	case .If:
		start = min(int(node.span_off), text_len)
		end = clamp(start + len("if"), start, text_len)
	case .Function:
		end = clamp(int(node.b), 0, text_len)
		start = max(end - len("=>"), 0)
	case .Condition:
		start = min(int(node.span_off), text_len)
		if cond := node_condition(tree, index); cond != nil {
			end = clamp(int(cond.end), start, text_len)
		} else {
			end = start
		}
	}
	return start, end
}

node_text :: proc "contextless" (tree: ^Syntax_Tree, index: Node_Index) -> string {
	if tree == nil {
		return ""
	}
	start, end := node_span(tree, index)
	return tree.text[start:end]
}

node_integer :: proc "contextless" (tree: ^Syntax_Tree, index: Node_Index) -> i64 {
	node := node_at(tree, index)
	if node == nil {
		return 0
	}
	if node.kind == .Boolean {
		return node.sub != 0 ? 1 : 0
	}
	if node.kind != .Integer {
		return 0
	}
	if node.sub == 0 {
		return i64(i32(node.b))
	}
	if int(node.b) < tree.int_const_count && int(node.b) < len(tree.int_consts) {
		return tree.int_consts[node.b]
	}
	return 0
}

@(rodata)
OPERATORS_IN_ORDER := [len(Operator)]Operator {
	.None,
	.Add,
	.Subtract,
	.Multiply,
	.Divide,
	.Remainder,
	.With,
	.Equal,
	.Not_Equal,
	.Less,
	.Less_Or_Equal,
	.Greater,
	.Greater_Or_Equal,
	.Logical_And,
	.Logical_Or,
	.List_Concat,
}

@(rodata)
REFUSALS_IN_ORDER := [len(Refusal)]Refusal {
	.None,
	.Text_Too_Long,
	.Nodes_Full,
	.Line_Ends_Too_Soon,
	.Unexpected,
	.Number_Too_Large,
	.Text_Without_End_Quote,
	.Close_Parenthesis_Missing,
	.Comma_Or_Close_Missing,
	.Too_Many_Arguments,
	.Fact_Name_Missing,
	.Condition_Head_Refused,
	.Field_Name_Missing,
	.Literal_Close_Missing,
	.Literal_Name_Missing,
	.Literal_Equal_Missing,
	.Literal_Field_Twice,
	.Named_Argument_Twice,
	.Positional_After_Named,
	.Let_Name_Missing,
	.Let_Equal_Missing,
	.Let_In_Missing,
	.Let_Name_Twice,
	.Word_As_Name,
	.Parameter_Name_Missing,
	.Parameter_Twice,
	.Too_Many_Parameters,
	.List_Close_Missing,
	.Hash_Not_Valid,
	.If_Then_Missing,
	.If_Else_Missing,
	.Nesting_Too_Deep,
	.Thin_Arrow,
	.Pipe_No_Left,
	.Pipe_Line_End,
	.Pipe_Not_A_Call,
	.Lone_Bar,
	.Placeholder_Not_Whole,
	.Placeholder_Twice,
	.Placeholder_Nested,
	.Placeholder_Without_Pipe,
	.Escape_Not_Valid,
	.Interpolation_Close_Missing,
	.Pattern_Field_Missing,
	.Pattern_Close_Missing,
	.Pattern_Field_Twice,
	.Pattern_Rest_Not_Last,
	.Pattern_At_Missing_Brace,
}

operator_of_byte :: #force_inline proc "contextless" (b: u8) -> (Operator, bool) {
	if int(b) >= len(OPERATORS_IN_ORDER) {
		return .None, false
	}
	return OPERATORS_IN_ORDER[b], true
}

refusal_of_byte :: #force_inline proc "contextless" (b: u8) -> (Refusal, bool) {
	if int(b) >= len(REFUSALS_IN_ORDER) {
		return .None, false
	}
	return REFUSALS_IN_ORDER[b], true
}

node_operator :: proc "contextless" (tree: ^Syntax_Tree, index: Node_Index) -> Operator {
	node := node_at(tree, index)
	if node == nil || node.kind != .Binary {
		return .None
	}
	op, _ := operator_of_byte(node.sub)
	return op
}

node_refusal :: proc "contextless" (tree: ^Syntax_Tree, index: Node_Index) -> Refusal {
	node := node_at(tree, index)
	if node == nil {
		return .None
	}
	switch node.kind {
	case .Refused, .Fact_Name, .Field_Names, .Condition:
		r, _ := refusal_of_byte(node.sub)
		return r
	case .Integer, .Text, .Text_Interp, .Name, .Call, .Negate, .Logical_Not, .Binary, .Record_Literal, .Literal_Field, .Named_Argument, .Let, .Let_Binding, .Member, .Function, .Parameter, .List_Literal, .Hash, .Boolean, .If, .Field_Select, .Pipe, .Placeholder, .Pattern_Record, .Pattern_Field:
		return .None
	}
	return .None
}

// node_child returns the single child of a 1-child node (Negate, Logical_Not,
// Field_Select, Literal_Field, Let_Binding, Named_Argument, Refused, Condition,
// Pattern_Field).
node_child :: proc "contextless" (tree: ^Syntax_Tree, index: Node_Index) -> Node_Index {
	node := node_at(tree, index)
	if node == nil {
		return NO_NODE
	}
	switch node.kind {
	case .Negate, .Logical_Not, .Field_Select, .Literal_Field, .Let_Binding, .Named_Argument, .Refused, .Condition, .Pattern_Field:
		return Node_Index(i32(node.a))
	case .Integer, .Text, .Text_Interp, .Name, .Call, .Binary, .Fact_Name, .Field_Names, .Record_Literal, .Let, .Member, .Function, .Parameter, .List_Literal, .Hash, .Boolean, .If, .Pipe, .Placeholder, .Pattern_Record:
		return NO_NODE
	}
	return NO_NODE
}

// node_binary_children returns (left, right) for .Binary or .Pipe nodes.
node_binary_children :: proc "contextless" (tree: ^Syntax_Tree, index: Node_Index) -> (left, right: Node_Index) {
	node := node_at(tree, index)
	if node == nil || (node.kind != .Binary && node.kind != .Pipe) {
		return NO_NODE, NO_NODE
	}
	return Node_Index(i32(node.a)), Node_Index(i32(node.b))
}

// node_children returns the contiguous child slice for variable-arity nodes
// (.Call, .Record_Literal, .List_Literal, .Let, .Function, .If, .Text_Interp, .Pattern_Record).
node_children :: proc "contextless" (tree: ^Syntax_Tree, index: Node_Index) -> []Node_Index {
	node := node_at(tree, index)
	if node == nil {
		return nil
	}
	start, count: int
	switch node.kind {
	case .Call, .Function, .If:
		start, count = int(node.a), int(node.aux)
	case .Record_Literal, .List_Literal, .Let, .Text_Interp, .Pattern_Record:
		start, count = int(node.a), int(node.b)
	case .Integer, .Text, .Name, .Negate, .Logical_Not, .Binary, .Condition, .Fact_Name, .Refused, .Field_Names, .Literal_Field, .Let_Binding, .Named_Argument, .Member, .Parameter, .Hash, .Boolean, .Field_Select, .Pipe, .Placeholder, .Pattern_Field:
		return nil
	}
	if count <= 0 || start < 0 || start > tree.extra_count || count > tree.extra_count - start {
		return nil
	}
	return tree.extra_children[start:start + count]
}

node_condition :: proc "contextless" (tree: ^Syntax_Tree, index: Node_Index) -> ^Condition_Extra {
	node := node_at(tree, index)
	if node == nil || node.kind != .Condition {
		return nil
	}
	idx := int(node.b)
	if idx < 0 || idx >= tree.condition_count || idx >= len(tree.conditions) {
		return nil
	}
	return &tree.conditions[idx]
}

node_function_offsets :: proc "contextless" (tree: ^Syntax_Tree, index: Node_Index) -> (open, arrow_end: int) {
	node := node_at(tree, index)
	if node == nil || node.kind != .Function {
		return 0, 0
	}
	return int(node.span_off), int(node.b)
}

// let_binding_pattern returns the .Pattern_Record node for a destructuring
// `let { ... } = expr` binding, or (NO_NODE, false) for a plain `let x = expr`.
let_binding_pattern :: proc "contextless" (tree: ^Syntax_Tree, index: Node_Index) -> (pattern: Node_Index, ok: bool) {
	node := node_at(tree, index)
	if node == nil || node.kind != .Let_Binding || (node.sub & LET_BINDING_PATTERN) == 0 {
		return NO_NODE, false
	}
	return Node_Index(i32(node.b)), true
}

node_binding :: proc "contextless" (tree: ^Syntax_Tree, index: Node_Index) -> Node_Index {
	if tree == nil || index < 0 || int(index) >= len(tree.bindings) {
		return NO_NODE
	}
	return tree.bindings[int(index)]
}

node_function :: proc "contextless" (tree: ^Syntax_Tree, index: Node_Index) -> Node_Index {
	if tree == nil || index < 0 || int(index) >= len(tree.functions) {
		return NO_NODE
	}
	return tree.functions[int(index)]
}

// place_of_offset computes 1-based line and column on demand (cold path only).
place_of_offset :: proc "contextless" (text: string, offset: int) -> Place {
	place := clamp(offset, 0, len(text))
	line := u32(1)
	line_start := 0
	for index in 0 ..< place {
		if text[index] == '\n' {
			line += 1
			line_start = index + 1
		}
	}
	return {line = line, column = u32(place - line_start + 1), offset = u32(place)}
}

// ---- Internal node & child builders.

@(private)
refused :: proc "contextless" (parser: ^Parser) -> bool {
	return parser.tree.refusal.refusal != .None
}

@(private)
refusal_keep :: proc "contextless" (parser: ^Parser, refusal: Refusal, offset: int, value: u64 = 0) {
	if parser.tree.refusal.refusal == .None {
		parser.tree.refusal = {refusal = refusal, place = place_of_offset(parser.tree.text, offset), value = value}
	}
}

@(private)
node_add_raw :: proc "contextless" (parser: ^Parser, node: Ast_Node) -> Node_Index {
	tree := parser.tree
	if tree.node_count >= len(tree.nodes) {
		refusal_keep(parser, .Nodes_Full, int(node.span_off))
		return NO_NODE
	}
	index := Node_Index(tree.node_count)
	tree.nodes[tree.node_count] = node
	if tree.node_count < len(tree.bindings) {
		tree.bindings[tree.node_count] = NO_NODE
	}
	if tree.node_count < len(tree.functions) {
		tree.functions[tree.node_count] = parser.function
	}
	tree.node_count += 1
	return index
}

@(private)
scratch_push :: proc "contextless" (parser: ^Parser, child: Node_Index) -> bool {
	if child == NO_NODE {
		return true
	}
	if parser.scratch_top >= len(parser.scratch) {
		refusal_keep(parser, .Nodes_Full, parser.position)
		return false
	}
	parser.scratch[parser.scratch_top] = child
	parser.scratch_top += 1
	return true
}

@(private)
children_commit :: proc "contextless" (parser: ^Parser, mark: int) -> (start: u32, count: u32, ok: bool) {
	n := parser.scratch_top - mark
	parser.scratch_top = mark
	if n <= 0 {
		return 0, 0, true
	}
	tree := parser.tree
	if n > len(tree.extra_children) - tree.extra_count {
		refusal_keep(parser, .Nodes_Full, parser.position)
		return 0, 0, false
	}
	s := tree.extra_count
	copy(tree.extra_children[s:s + n], parser.scratch[mark:mark + n])
	tree.extra_count += n
	return u32(s), u32(n), true
}

@(private)
refuse :: proc "contextless" (parser: ^Parser, expected_refusal: Refusal, expected_start, end: int, before: Node_Index, value: u64 = 0) -> Node_Index {
	refusal, start := thin_arrow_instead(parser, expected_refusal, expected_start)
	refusal_keep(parser, refusal, start, value)
	return node_add_raw(parser, {
		kind     = .Refused,
		sub      = u8(refusal),
		span_off = u32(clamp(start, 0, len(parser.tree.text))),
		a        = u32(before),
		b        = u32(clamp(end, 0, len(parser.tree.text))),
	})
}

@(private)
thin_arrow_instead :: proc "contextless" (parser: ^Parser, refusal: Refusal, start: int) -> (Refusal, int) {
	expected_other := refusal == .Unexpected || refusal == .Close_Parenthesis_Missing || refusal == .Comma_Or_Close_Missing || refusal == .List_Close_Missing || refusal == .Literal_Close_Missing || refusal == .Let_In_Missing || refusal == .If_Then_Missing || refusal == .If_Else_Missing
	if !expected_other {
		return refusal, start
	}
	token := console_language.token_next(parser.tree.text, start, parser.multiline)
	if token.kind == .Arrow {
		return .Thin_Arrow, token.start
	}
	return refusal, start
}

// ---- O(1) duplicate / child name lookup helper.

@(private)
dup_key_of :: proc "contextless" (parent: Node_Index, sym: Sym_Id) -> u64 {
	return (u64(u32(parent)) << 32) | u64(u32(sym))
}

@(private)
dup_find :: proc "contextless" (parser: ^Parser, parent: Node_Index, name: string) -> (found_node: Node_Index, used_hash: bool) {
	if parser.interner == nil || parser.dup.index.group_count <= 0 {
		return NO_NODE, false
	}
	sym, sym_ok := intern_lookup(parser.interner, name)
	if !sym_ok {
		return NO_NODE, true
	}
	key := dup_key_of(parent, sym)
	h := hash_table.slice_index_hash_word(&parser.dup.index, key)
	search := hash_table.slice_index_search_begin(&parser.dup.index, h)
	for ref, _ in hash_table.slice_index_search_next(&parser.dup.index, &search) {
		if int(ref) < int(parser.dup.count) && parser.dup.keys[ref] == key {
			return parser.dup.nodes[ref], true
		}
	}
	return NO_NODE, true
}

@(private)
dup_insert :: proc "contextless" (parser: ^Parser, parent: Node_Index, name: string, child: Node_Index) -> bool {
	if parser.interner == nil || parser.dup.index.group_count <= 0 {
		return false
	}
	if int(parser.dup.count) >= len(parser.dup.keys) {
		return false
	}
	sym, sym_ok := intern(parser.interner, name)
	if !sym_ok {
		return false
	}
	key := dup_key_of(parent, sym)
	h := hash_table.slice_index_hash_word(&parser.dup.index, key)
	slot_id := parser.dup.count
	parser.dup.keys[slot_id] = key
	parser.dup.nodes[slot_id] = child
	if !hash_table.slice_index_insert(&parser.dup.index, h, slot_id, &parser.dup, dup_table_hash_of_ref) {
		return false
	}
	parser.dup.count += 1
	return true
}

// scratch_child_named searches children already pushed onto scratch[mark:top].
@(private)
scratch_child_named :: proc "contextless" (parser: ^Parser, parent: Node_Index, mark: int, kind: Node_Kind, name: string, hashed: ^bool) -> Node_Index {
	count := parser.scratch_top - mark
	if hashed^ {
		found, ok := dup_find(parser, parent, name)
		if ok {
			return found
		}
	}
	if !hashed^ && count >= DUP_HASH_THRESHOLD && parser.interner != nil && parser.dup.index.group_count > 0 {
		// Promote this parent to O(1) hash lookup by backfilling the first 16 children.
		all_ok := true
		for idx in mark ..< parser.scratch_top {
			c := parser.scratch[idx]
			if cn := node_at(parser.tree, c); cn != nil && cn.kind == kind {
				if !dup_insert(parser, parent, node_text(parser.tree, c), c) {
					all_ok = false
					break
				}
			}
		}
		if all_ok {
			hashed^ = true
			found, ok := dup_find(parser, parent, name)
			if ok {
				return found
			}
		}
	}
	for idx in mark ..< parser.scratch_top {
		c := parser.scratch[idx]
		if cn := node_at(parser.tree, c); cn != nil && cn.kind == kind && node_text(parser.tree, c) == name {
			return c
		}
	}
	return NO_NODE
}

// ---- Scanner helpers.

@(private)
skip_spaces :: proc "contextless" (parser: ^Parser) {
	parser.position = console_language.space_end(parser.tree.text, parser.position, parser.multiline)
}

@(private)
peek :: proc "contextless" (parser: ^Parser) -> u8 {
	skip_spaces(parser)
	text := parser.tree.text
	return parser.position < len(text) ? text[parser.position] : 0
}

@(private)
accept :: proc "contextless" (parser: ^Parser, character: u8) -> bool {
	if peek(parser) == character {
		parser.position += 1
		return true
	}
	return false
}

@(private)
read_name :: proc "contextless" (parser: ^Parser) -> string {
	skip_spaces(parser)
	start := parser.position
	parser.position = console_language.name_end(parser.tree.text, start)
	return parser.tree.text[start:parser.position]
}

@(private)
equal_accept :: proc "contextless" (parser: ^Parser) -> bool {
	text := parser.tree.text
	if peek(parser) != '=' || parser.position + 1 < len(text) && (text[parser.position + 1] == '=' || text[parser.position + 1] == '>') {
		return false
	}
	parser.position += 1
	return true
}

@(private)
word_ahead :: proc "contextless" (parser: ^Parser, word: string) -> (end: int, found: bool) {
	token := console_language.token_next(parser.tree.text, parser.position, parser.multiline)
	if console_language.word_is(parser.tree.text, token, word) {
		return token.end, true
	}
	return parser.position, false
}

@(private)
named_ahead :: proc "contextless" (parser: ^Parser) -> bool {
	text := parser.tree.text
	name := console_language.token_next(text, parser.position, parser.multiline)
	if name.kind != .Name {
		return false
	}
	equal := console_language.token_next(text, name.end, parser.multiline)
	return equal.kind == .Operator && text[equal.start] == '=' && !(equal.end < len(text) && text[equal.end] == '=')
}

// decode_text_escapes validates and decodes backslash escape sequences inside
// a raw string body (without surrounding quotes). Supported escapes:
//   \\  \"  \$  \u{XXXXXX} (1..6 hex digits; refuses control characters,
//   surrogates, and values above 0x10FFFF per src/md/data/text_encoding.md).
//   0xD800..0xDFFF and values > 0x10FFFF).
// When `out` is nil, validates and computes `written` without writing bytes.
decode_text_escapes :: proc "contextless" (raw: string, out: []u8) -> (written: int, bad_offset: int, ok: bool) {
	i := 0
	w := 0
	for i < len(raw) {
		ch := raw[i]
		if ch != '\\' {
			if out != nil {
				if w >= len(out) {
					return w, i, false
				}
				out[w] = ch
			}
			w += 1
			i += 1
			continue
		}
		esc_pos := i
		if i + 1 >= len(raw) {
			return w, esc_pos, false
		}
		next := raw[i + 1]
		switch next {
		case '\\', '"', '$':
			if out != nil {
				if w >= len(out) {
					return w, esc_pos, false
				}
				out[w] = next
			}
			w += 1
			i += 2
		case 'u':
			if i + 2 >= len(raw) || raw[i + 2] != '{' {
				return w, esc_pos, false
			}
			j := i + 3
			cp := u32(0)
			digits := 0
			for j < len(raw) && raw[j] != '}' {
				c := raw[j]
				v: u32
				switch c {
				case '0' ..= '9':
					v = u32(c - '0')
				case 'a' ..= 'f':
					v = u32(c - 'a' + 10)
				case 'A' ..= 'F':
					v = u32(c - 'A' + 10)
				case:
					return w, esc_pos, false
				}
				digits += 1
				if digits > 6 {
					return w, esc_pos, false
				}
				cp = (cp << 4) | v
				j += 1
			}
			if digits == 0 || j >= len(raw) || raw[j] != '}' {
				return w, esc_pos, false
			}
			if cp > 0x10FFFF || !text_encoding.character_in_text(rune(cp)) {
				return w, esc_pos, false
			}
			// Encode Unicode scalar value to UTF-8.
			utf8_buf: [4]u8
			ulen := 0
			switch {
			case cp <= 0x7F:
				utf8_buf[0] = u8(cp)
				ulen = 1
			case cp <= 0x7FF:
				utf8_buf[0] = 0xC0 | u8(cp >> 6)
				utf8_buf[1] = 0x80 | u8(cp & 0x3F)
				ulen = 2
			case cp <= 0xFFFF:
				utf8_buf[0] = 0xE0 | u8(cp >> 12)
				utf8_buf[1] = 0x80 | u8((cp >> 6) & 0x3F)
				utf8_buf[2] = 0x80 | u8(cp & 0x3F)
				ulen = 3
			case:
				utf8_buf[0] = 0xF0 | u8(cp >> 18)
				utf8_buf[1] = 0x80 | u8((cp >> 12) & 0x3F)
				utf8_buf[2] = 0x80 | u8((cp >> 6) & 0x3F)
				utf8_buf[3] = 0x80 | u8(cp & 0x3F)
				ulen = 4
			}
			if out != nil {
				if w + ulen > len(out) {
					return w, esc_pos, false
				}
				copy(out[w:w + ulen], utf8_buf[:ulen])
			}
			w += ulen
			i = j + 1
		case:
			return w, esc_pos, false
		}
	}
	return w, 0, true
}

// ---- Grammar (native |> at lowest precedence, left-associative).

@(private)
pipeline_read :: proc "contextless" (parser: ^Parser) -> Node_Index {
	if parser.depth_limit > 0 && parser.depth >= parser.depth_limit {
		skip_spaces(parser)
		return refuse(parser, .Nesting_Too_Deep, parser.position, parser.position, NO_NODE)
	}
	parser.depth += 1
	defer parser.depth -= 1

	// Check for leading "|>" or lone "|" with no left operand.
	skip_spaces(parser)
	text := parser.tree.text
	if parser.position < len(text) && text[parser.position] == '|' {
		if parser.position + 1 < len(text) && text[parser.position + 1] == '>' {
			return refuse(parser, .Pipe_No_Left, parser.position, parser.position + 2, NO_NODE)
		}
		if !(parser.position + 1 < len(text) && text[parser.position + 1] == '|') {
			return refuse(parser, .Lone_Bar, parser.position, parser.position + 1, NO_NODE)
		}
	}

	left := or_read(parser)
	for !refused(parser) {
		skip_spaces(parser)
		if parser.position >= len(text) || text[parser.position] != '|' {
			return left
		}
		pipe_start := parser.position
		if pipe_start + 1 >= len(text) || text[pipe_start + 1] != '>' {
			return refuse(parser, .Lone_Bar, pipe_start, pipe_start + 1, left)
		}
		parser.position = pipe_start + 2
		// Pipe operand clears direct-placeholder state for anything past the stage.
		saved_direct := parser.in_direct_pipe_arg
		parser.in_direct_pipe_arg = false
		stage := pipe_stage_read(parser)
		parser.in_direct_pipe_arg = saved_direct
		pipe_node := node_add_raw(parser, {
			kind     = .Pipe,
			aux      = 2,
			span_off = u32(pipe_start),
			a        = u32(left),
			b        = u32(stage),
		})
		if pipe_node == NO_NODE {
			return left
		}
		left = pipe_node
	}
	return left
}

@(private)
or_read :: proc "contextless" (parser: ^Parser) -> Node_Index {
	left := and_read(parser)
	text := parser.tree.text
	for !refused(parser) {
		if peek(parser) != '|' || parser.position + 1 >= len(text) || text[parser.position + 1] != '|' {
			return left
		}
		op_start := parser.position
		parser.position += 2
		saved_direct := parser.in_direct_pipe_arg
		parser.in_direct_pipe_arg = false
		right := and_read(parser)
		parser.in_direct_pipe_arg = saved_direct
		binary := node_add_raw(parser, {
			kind     = .Binary,
			sub      = u8(Operator.Logical_Or),
			aux      = 2,
			span_off = u32(op_start),
			a        = u32(left),
			b        = u32(right),
		})
		if binary == NO_NODE {
			return left
		}
		left = binary
	}
	return left
}

@(private)
and_read :: proc "contextless" (parser: ^Parser) -> Node_Index {
	left := comparison_read(parser)
	text := parser.tree.text
	for !refused(parser) {
		if peek(parser) != '&' || parser.position + 1 >= len(text) || text[parser.position + 1] != '&' {
			return left
		}
		op_start := parser.position
		parser.position += 2
		saved_direct := parser.in_direct_pipe_arg
		parser.in_direct_pipe_arg = false
		right := comparison_read(parser)
		parser.in_direct_pipe_arg = saved_direct
		binary := node_add_raw(parser, {
			kind     = .Binary,
			sub      = u8(Operator.Logical_And),
			aux      = 2,
			span_off = u32(op_start),
			a        = u32(left),
			b        = u32(right),
		})
		if binary == NO_NODE {
			return left
		}
		left = binary
	}
	return left
}

// pipe_stage_read reads the RHS call of `|>`: `name` or `name(arguments)`.
@(private)
pipe_stage_read :: proc "contextless" (parser: ^Parser) -> Node_Index {
	skip_spaces(parser)
	text := parser.tree.text
	start := parser.position
	if start >= len(text) {
		return refuse(parser, .Pipe_Line_End, start, start, NO_NODE)
	}
	tok := console_language.token_next(text, start, parser.multiline)
	if tok.kind == .None {
		return refuse(parser, .Pipe_Line_End, start, start, NO_NODE)
	}
	if tok.kind != .Name {
		return refuse(parser, .Pipe_Not_A_Call, tok.start, tok.end, NO_NODE)
	}
	name := text[tok.start:tok.end]
	if word_of_lex(name) {
		return refuse(parser, .Pipe_Not_A_Call, tok.start, tok.end, NO_NODE)
	}
	parser.position = tok.end
	if accept(parser, '(') {
		open_pos := parser.position - 1
		return call_read(parser, name, tok.start, true, open_pos)
	}
	// Bare `a |> f`: 0 explicit arguments, piped LHS fills slot 0.
	return node_add_raw(parser, {
		kind     = .Call,
		sub      = CALL_FLAG_IN_PIPE,
		aux      = 0,
		span_off = u32(tok.start),
		a        = 0,
		b        = u32(tok.end),
	})
}

@(private)
comparison_read :: proc "contextless" (parser: ^Parser) -> Node_Index {
	left := with_read(parser)
	if refused(parser) {
		return left
	}
	text := parser.tree.text
	character := peek(parser)
	op_start := parser.position
	operator := Operator.None
	op_len := 0
	second := op_start + 1 < len(text) ? text[op_start + 1] : 0
	switch character {
	case '=':
		if second != '=' && second != '>' {
			operator, op_len = .Equal, 1
		}
	case '!':
		if second == '=' {
			operator, op_len = .Not_Equal, 2
		}
	case '<':
		if second == '=' {
			operator, op_len = .Less_Or_Equal, 2
		} else {
			operator, op_len = .Less, 1
		}
	case '>':
		if second == '=' {
			operator, op_len = .Greater_Or_Equal, 2
		} else {
			operator, op_len = .Greater, 1
		}
	}
	if operator == .None {
		return left
	}
	parser.position = op_start + op_len
	saved_direct := parser.in_direct_pipe_arg
	parser.in_direct_pipe_arg = false
	right := with_read(parser)
	parser.in_direct_pipe_arg = saved_direct
	return node_add_raw(parser, {
		kind     = .Binary,
		sub      = u8(operator),
		aux      = u16(op_len),
		span_off = u32(op_start),
		a        = u32(left),
		b        = u32(right),
	})
}

@(private)
with_read :: proc "contextless" (parser: ^Parser) -> Node_Index {
	left := sum_read(parser)
	for !refused(parser) {
		end, found := word_ahead(parser, "with")
		if !found {
			return left
		}
		skip_spaces(parser)
		op_start := parser.position
		parser.position = end
		saved_direct := parser.in_direct_pipe_arg
		parser.in_direct_pipe_arg = false
		right := sum_read(parser)
		parser.in_direct_pipe_arg = saved_direct
		binary := node_add_raw(parser, {
			kind     = .Binary,
			sub      = u8(Operator.With),
			aux      = u16(end - op_start),
			span_off = u32(op_start),
			a        = u32(left),
			b        = u32(right),
		})
		if binary == NO_NODE {
			return left
		}
		left = binary
	}
	return left
}

@(private)
sum_read :: proc "contextless" (parser: ^Parser) -> Node_Index {
	left := term_read(parser)
	text := parser.tree.text
	for !refused(parser) {
		operator: Operator
		op_len := 1
		switch peek(parser) {
		case '+':
			if parser.position + 1 < len(text) && text[parser.position + 1] == '+' {
				operator = .List_Concat
				op_len = 2
			} else {
				operator = .Add
			}
		case '-':
			if console_language.token_next(text, parser.position, parser.multiline).kind == .Arrow {
				return left
			}
			operator = .Subtract
		case:
			return left
		}
		op_start := parser.position
		parser.position += op_len
		saved_direct := parser.in_direct_pipe_arg
		parser.in_direct_pipe_arg = false
		right := term_read(parser)
		parser.in_direct_pipe_arg = saved_direct
		binary := node_add_raw(parser, {
			kind     = .Binary,
			sub      = u8(operator),
			aux      = u16(op_len),
			span_off = u32(op_start),
			a        = u32(left),
			b        = u32(right),
		})
		if binary == NO_NODE {
			return left
		}
		left = binary
	}
	return left
}

@(private)
term_read :: proc "contextless" (parser: ^Parser) -> Node_Index {
	left := factor_read(parser)
	for !refused(parser) {
		operator: Operator
		switch peek(parser) {
		case '*':
			operator = .Multiply
		case '/':
			operator = .Divide
		case '%':
			operator = .Remainder
		case:
			return left
		}
		left = binary_read(parser, operator, left, factor_read)
	}
	return left
}

@(private)
binary_read :: proc "contextless" (parser: ^Parser, operator: Operator, left: Node_Index, right_read: proc "contextless" (parser: ^Parser) -> Node_Index) -> Node_Index {
	op_start := parser.position
	parser.position += 1
	saved_direct := parser.in_direct_pipe_arg
	parser.in_direct_pipe_arg = false
	right := right_read(parser)
	parser.in_direct_pipe_arg = saved_direct
	binary := node_add_raw(parser, {
		kind     = .Binary,
		sub      = u8(operator),
		aux      = 1,
		span_off = u32(op_start),
		a        = u32(left),
		b        = u32(right),
	})
	if binary == NO_NODE {
		return left
	}
	return binary
}

@(private)
factor_read :: proc "contextless" (parser: ^Parser) -> Node_Index {
	if parser.depth_limit > 0 && parser.depth >= parser.depth_limit {
		skip_spaces(parser)
		return refuse(parser, .Nesting_Too_Deep, parser.position, parser.position, NO_NODE)
	}
	parser.depth += 1
	defer parser.depth -= 1

	text := parser.tree.text
	character := peek(parser)
	start := parser.position
	node := NO_NODE
	allows_postfix := false
	switch {
	case character == '-':
		parser.position += 1
		saved_direct := parser.in_direct_pipe_arg
		parser.in_direct_pipe_arg = false
		child := factor_read(parser)
		parser.in_direct_pipe_arg = saved_direct
		return node_add_raw(parser, {
			kind     = .Negate,
			span_off = u32(start),
			a        = u32(child),
			b        = u32(start + 1),
		})
	case character == '!':
		parser.position += 1
		saved_direct := parser.in_direct_pipe_arg
		parser.in_direct_pipe_arg = false
		child := factor_read(parser)
		parser.in_direct_pipe_arg = saved_direct
		return node_add_raw(parser, {
			kind     = .Logical_Not,
			span_off = u32(start),
			a        = u32(child),
			b        = u32(start + 1),
		})
	case character == '(':
		if close, arrow_end, found := console_language.function_head(text, start, parser.multiline); found {
			return function_read(parser, start, close, arrow_end)
		}
		parser.position += 1
		saved_direct := parser.in_direct_pipe_arg
		parser.in_direct_pipe_arg = false
		inner := pipeline_read(parser)
		parser.in_direct_pipe_arg = saved_direct
		if refused(parser) {
			return inner
		}
		if !accept(parser, ')') {
			return refuse(parser, .Close_Parenthesis_Missing, parser.position, parser.position, inner)
		}
		node, allows_postfix = inner, true
	case console_language.digit(character):
		end := console_language.number_end(text, start)
		parser.position = end
		value, fits := console_language.number_value(text, start, end)
		if !fits {
			return refuse(parser, .Number_Too_Large, start, end, NO_NODE)
		}
		return integer_node_add(parser, start, end, value)
	case character == '"':
		return text_literal_read(parser, start)
	case character == '{':
		parser.position += 1
		saved_direct := parser.in_direct_pipe_arg
		parser.in_direct_pipe_arg = false
		node, allows_postfix = literal_read(parser, start), true
		parser.in_direct_pipe_arg = saved_direct
	case character == '[':
		parser.position += 1
		saved_direct := parser.in_direct_pipe_arg
		parser.in_direct_pipe_arg = false
		res := list_read(parser, start)
		parser.in_direct_pipe_arg = saved_direct
		return res
	case character == '.':
		token := console_language.token_next(text, start, parser.multiline)
		if token.kind != .Member {
			return refuse(parser, .Unexpected, start, len(text), NO_NODE)
		}
		parser.position = token.end
		return node_add_raw(parser, {kind = .Member, span_off = u32(start), a = u32(token.end)})
	case console_language.hash_starts(text, start):
		end := console_language.hash_end(text, start)
		parser.position = end
		if _, valid := console_language.hash_value(text, start, end); !valid {
			return refuse(parser, .Hash_Not_Valid, start, end, NO_NODE)
		}
		return node_add_raw(parser, {kind = .Hash, span_off = u32(start), a = u32(end)})
	case console_language.name_first(character):
		name := read_name(parser)
		if name == "let" {
			return let_read(parser, start)
		}
		if name == "if" {
			return if_read(parser, start)
		}
		if name == "true" || name == "false" {
			return node_add_raw(parser, {
				kind     = .Boolean,
				sub      = name == "true" ? 1 : 0,
				span_off = u32(start),
				a        = u32(start + len(name)),
			})
		}
		if name == "_" {
			// Context-aware placeholder refusal when `_` appears inside a
			// sub-expression or nested call of a piped RHS.
			if parser.pipe_call_depth > 0 {
				if parser.in_nested_call {
					return refuse(parser, .Placeholder_Nested, start, start + 1, NO_NODE)
				}
				return refuse(parser, .Placeholder_Not_Whole, start, start + 1, NO_NODE)
			}
			return refuse(parser, .Word_As_Name, start, start + 1, NO_NODE)
		}
		if word_of_lex(name) {
			return refuse(parser, .Word_As_Name, start, start + len(name), NO_NODE)
		}
		if accept(parser, '(') {
			open_pos := parser.position - 1
			node, allows_postfix = call_read(parser, name, start, false, open_pos), true
		} else if peek(parser) == '{' {
			brace_start := parser.position
			parser.position += 1
			call := node_add_raw(parser, {
				kind     = .Call,
				span_off = u32(start),
				b        = u32(start + len(name)),
			})
			if call != NO_NODE {
				mark := parser.scratch_top
				lit := literal_read(parser, brace_start)
				scratch_push(parser, lit)
				cstart, ccount, _ := children_commit(parser, mark)
				if cn := node_at(parser.tree, call); cn != nil {
					cn.a = cstart
					cn.aux = u16(ccount)
				}
			}
			node, allows_postfix = call, true
		} else {
			return node_add_raw(parser, {kind = .Name, span_off = u32(start), a = u32(start + len(name))})
		}
	case character == 0:
		return refuse(parser, .Line_Ends_Too_Soon, start, start, NO_NODE)
	case character == '|':
		if start + 1 < len(text) && text[start + 1] == '>' {
			return refuse(parser, .Pipe_No_Left, start, start + 2, NO_NODE)
		}
		if start + 1 < len(text) && text[start + 1] == '|' {
			return refuse(parser, .Unexpected, start, start + 2, NO_NODE)
		}
		return refuse(parser, .Lone_Bar, start, start + 1, NO_NODE)
	case:
		return refuse(parser, .Unexpected, start, len(text), NO_NODE)
	}
	if !allows_postfix || refused(parser) {
		return node
	}
	return postfix_read(parser, node)
}

@(private)
text_literal_read :: proc "contextless" (parser: ^Parser, start: int) -> Node_Index {
	text := parser.tree.text
	// Fast scan to check whether any `${` interpolation appears and find closing `"`.
	i := start + 1
	has_escape := false
	has_interp := false
	closed := false
	for i < len(text) {
		ch := text[i]
		if ch == '\\' {
			has_escape = true
			if i + 1 >= len(text) {
				parser.position = len(text)
				return refuse(parser, .Text_Without_End_Quote, start, len(text), NO_NODE)
			}
			i += 2
			continue
		}
		if ch == '$' && i + 1 < len(text) && text[i + 1] == '{' {
			has_interp = true
			break
		}
		if ch == '"' {
			closed = true
			i += 1
			break
		}
		i += 1
	}
	if !has_interp {
		if !closed {
			parser.position = len(text)
			return refuse(parser, .Text_Without_End_Quote, start, len(text), NO_NODE)
		}
		parser.position = i
		if has_escape {
			raw := text[start + 1:i - 1]
			if _, bad_off, ok := decode_text_escapes(raw, nil); !ok {
				return refuse(parser, .Escape_Not_Valid, start + 1 + bad_off, start + 1 + bad_off + 1, NO_NODE)
			}
			return node_add_raw(parser, {kind = .Text, sub = TEXT_FLAG_ESCAPED, span_off = u32(start), a = u32(i)})
		}
		return node_add_raw(parser, {kind = .Text, span_off = u32(start), a = u32(i)})
	}

	// Interpolated string `"prefix ${expr} suffix"`: emit `.Text_Interp` with
	// alternating literal `.Text` segments (TEXT_FLAG_SEGMENT) and expression children.
	interp := node_add_raw(parser, {kind = .Text_Interp, span_off = u32(start)})
	if interp == NO_NODE {
		return NO_NODE
	}
	mark := parser.scratch_top
	pos := start + 1
	for !refused(parser) {
		seg_start := pos
		seg_escaped := false
		for pos < len(text) {
			ch := text[pos]
			if ch == '\\' {
				seg_escaped = true
				if pos + 1 >= len(text) {
					parser.position = len(text)
					scratch_push(parser, refuse(parser, .Text_Without_End_Quote, start, len(text), NO_NODE))
					break
				}
				pos += 2
				continue
			}
			if ch == '"' || (ch == '$' && pos + 1 < len(text) && text[pos + 1] == '{') {
				break
			}
			pos += 1
		}
		if refused(parser) {
			break
		}
		if pos > seg_start {
			if seg_escaped {
				if _, bad_off, ok := decode_text_escapes(text[seg_start:pos], nil); !ok {
					parser.position = seg_start + bad_off
					scratch_push(parser, refuse(parser, .Escape_Not_Valid, seg_start + bad_off, seg_start + bad_off + 1, NO_NODE))
					break
				}
			}
			seg_flags := TEXT_FLAG_SEGMENT | (seg_escaped ? TEXT_FLAG_ESCAPED : 0)
			seg := node_add_raw(parser, {kind = .Text, sub = seg_flags, span_off = u32(seg_start), a = u32(pos)})
			scratch_push(parser, seg)
			if refused(parser) {
				break
			}
		}
		if pos >= len(text) {
			parser.position = len(text)
			scratch_push(parser, refuse(parser, .Text_Without_End_Quote, start, len(text), NO_NODE))
			break
		}
		if text[pos] == '"' {
			parser.position = pos + 1
			break
		}
		// Parse `${expr}`.
		parser.position = pos + 2
		saved_direct := parser.in_direct_pipe_arg
		parser.in_direct_pipe_arg = false
		expr := pipeline_read(parser)
		parser.in_direct_pipe_arg = saved_direct
		scratch_push(parser, expr)
		if refused(parser) {
			break
		}
		if !accept(parser, '}') {
			scratch_push(parser, refuse(parser, .Interpolation_Close_Missing, parser.position, parser.position, NO_NODE))
			break
		}
		pos = parser.position
	}
	cstart, ccount, _ := children_commit(parser, mark)
	if n := node_at(parser.tree, interp); n != nil {
		n.a = cstart
		n.b = ccount
	}
	return interp
}

@(private)
integer_node_add :: proc "contextless" (parser: ^Parser, start, end: int, value: i64) -> Node_Index {
	if value >= i64(min(i32)) && value <= i64(max(i32)) {
		return node_add_raw(parser, {
			kind     = .Integer,
			sub      = 0,
			span_off = u32(start),
			a        = u32(end),
			b        = u32(i32(value)),
		})
	}
	tree := parser.tree
	if tree.int_const_count >= len(tree.int_consts) {
		return refuse(parser, .Nodes_Full, start, end, NO_NODE)
	}
	const_idx := u32(tree.int_const_count)
	tree.int_consts[tree.int_const_count] = value
	tree.int_const_count += 1
	return node_add_raw(parser, {
		kind     = .Integer,
		sub      = 1,
		span_off = u32(start),
		a        = u32(end),
		b        = const_idx,
	})
}

@(private)
postfix_read :: proc "contextless" (parser: ^Parser, base: Node_Index) -> Node_Index {
	text := parser.tree.text
	current := base
	for !refused(parser) && peek(parser) == '.' {
		dot_start := parser.position
		token := console_language.token_next(text, dot_start, parser.multiline)
		if token.kind != .Member {
			break
		}
		parser.position = token.end
		selected := node_add_raw(parser, {
			kind     = .Field_Select,
			span_off = u32(token.start + 1),
			a        = u32(current),
			b        = u32(token.end),
		})
		if selected == NO_NODE {
			return current
		}
		current = selected
	}
	return current
}

@(private)
if_read :: proc "contextless" (parser: ^Parser, start: int) -> Node_Index {
	node := node_add_raw(parser, {kind = .If, span_off = u32(start)})
	if node == NO_NODE {
		return NO_NODE
	}
	mark := parser.scratch_top
	saved_direct := parser.in_direct_pipe_arg
	parser.in_direct_pipe_arg = false
	defer parser.in_direct_pipe_arg = saved_direct

	cond := pipeline_read(parser)
	scratch_push(parser, cond)
	if !refused(parser) {
		then_end, has_then := word_ahead(parser, "then")
		if !has_then {
			skip_spaces(parser)
			scratch_push(parser, refuse(parser, .If_Then_Missing, parser.position, parser.position, NO_NODE))
		} else {
			parser.position = then_end
			then_branch := pipeline_read(parser)
			scratch_push(parser, then_branch)
			if !refused(parser) {
				else_end, has_else := word_ahead(parser, "else")
				if !has_else {
					skip_spaces(parser)
					scratch_push(parser, refuse(parser, .If_Else_Missing, parser.position, parser.position, NO_NODE))
				} else {
					parser.position = else_end
					else_branch := pipeline_read(parser)
					scratch_push(parser, else_branch)
				}
			}
		}
	}
	cstart, ccount, _ := children_commit(parser, mark)
	if n := node_at(parser.tree, node); n != nil {
		n.a = cstart
		n.aux = u16(ccount)
	}
	return node
}

// placeholder_whole_ahead checks if the next token is `_` followed directly by
// `,` or `)` (a whole-argument placeholder).
@(private)
placeholder_whole_ahead :: proc "contextless" (parser: ^Parser) -> (start, end: int, whole: bool) {
	text := parser.tree.text
	tok := console_language.token_next(text, parser.position, parser.multiline)
	if !console_language.word_is(text, tok, "_") {
		return 0, 0, false
	}
	next := console_language.token_next(text, tok.end, parser.multiline)
	if next.kind == .Operator && (text[next.start] == ',' || text[next.start] == ')') {
		return tok.start, tok.end, true
	}
	return tok.start, tok.end, false
}

// call_read reads the arguments of a call after `(`. When `in_pipe_rhs` is true,
// `_` is accepted once as a whole direct argument (or `name = _`), and
// `Form_Lookup.form_of` receives `arg_offset` (1 when no `_` appears, 0 when
// `_` appears) so `where` and `columns` parse identically in piped form.
@(private)
call_read :: proc "contextless" (parser: ^Parser, name: string, start: int, in_pipe_rhs: bool, open_pos: int) -> Node_Index {
	call := node_add_raw(parser, {
		kind     = .Call,
		sub      = in_pipe_rhs ? CALL_FLAG_IN_PIPE : 0,
		span_off = u32(start),
		b        = u32(start + len(name)),
	})
	if call == NO_NODE || accept(parser, ')') {
		return call
	}

	// Preserve Form_Lookup parameter indices when parsing a piped RHS call.
	has_placeholder_ahead := in_pipe_rhs && parser.lookup.form_of != nil && console_language.call_has_placeholder(parser.tree.text, open_pos, parser.multiline)
	arg_offset := (in_pipe_rhs && !has_placeholder_ahead) ? 1 : 0

	saved_depth := parser.pipe_call_depth
	saved_nested := parser.in_nested_call
	saved_direct := parser.in_direct_pipe_arg
	saved_call := parser.pipe_call_node
	if in_pipe_rhs {
		parser.pipe_call_depth += 1
		parser.in_nested_call = false
		parser.pipe_call_node = call
	} else if parser.pipe_call_depth > 0 {
		parser.in_nested_call = true
	}
	defer {
		parser.pipe_call_depth = saved_depth
		parser.in_nested_call = saved_nested
		parser.in_direct_pipe_arg = saved_direct
		parser.pipe_call_node = saved_call
	}

	mark := parser.scratch_top
	count := 0
	named_seen := false
	placeholder_seen := false
	hashed := false

	for {
		if count + arg_offset >= ARGUMENT_CAPACITY {
			scratch_push(parser, refuse(parser, .Too_Many_Arguments, parser.position, parser.position, NO_NODE))
			break
		}
		argument: Node_Index
		switch form_of(parser.lookup, name, count + arg_offset) {
		case .Expression:
			if named_ahead(parser) {
				named_seen = true
				argument = named_argument_read(parser, call, mark, &hashed, in_pipe_rhs, &placeholder_seen)
			} else if named_seen {
				skip_spaces(parser)
				argument = refuse(parser, .Positional_After_Named, parser.position, parser.position, NO_NODE)
			} else if pstart, pend, is_whole := placeholder_whole_ahead(parser); is_whole {
				parser.position = pend
				if !in_pipe_rhs {
					if parser.pipe_call_depth > 0 {
						argument = refuse(parser, .Placeholder_Nested, pstart, pend, NO_NODE)
					} else {
						argument = refuse(parser, .Placeholder_Without_Pipe, pstart, pend, NO_NODE)
					}
				} else if placeholder_seen {
					argument = refuse(parser, .Placeholder_Twice, pstart, pend, NO_NODE)
				} else {
					placeholder_seen = true
					argument = node_add_raw(parser, {kind = .Placeholder, span_off = u32(pstart), a = u32(pend)})
				}
			} else {
				parser.in_direct_pipe_arg = in_pipe_rhs
				argument = pipeline_read(parser)
				parser.in_direct_pipe_arg = false
			}
		case .Fact_Name:
			argument = fact_name_read(parser)
		case .Condition:
			argument = condition_read(parser)
		case .Field_Names:
			argument = field_names_read(parser)
		}
		scratch_push(parser, argument)
		if refused(parser) {
			break
		}
		count += 1
		if accept(parser, ')') {
			break
		}
		if !accept(parser, ',') {
			scratch_push(parser, refuse(parser, .Comma_Or_Close_Missing, parser.position, parser.position, NO_NODE))
			break
		}
	}

	cstart, ccount, _ := children_commit(parser, mark)
	if cn := node_at(parser.tree, call); cn != nil {
		cn.a = cstart
		cn.aux = u16(ccount)
		if placeholder_seen {
			cn.sub |= CALL_FLAG_HAS_PLACEHOLDER
		}
	}
	return call
}

@(private)
named_argument_read :: proc "contextless" (parser: ^Parser, call: Node_Index, mark: int, hashed: ^bool, in_pipe_rhs: bool, placeholder_seen: ^bool) -> Node_Index {
	skip_spaces(parser)
	start := parser.position
	name := read_name(parser)
	if word_of_lex(name) {
		return refuse(parser, .Word_As_Name, start, start + len(name), NO_NODE)
	}
	if scratch_child_named(parser, call, mark, .Named_Argument, name, hashed) != NO_NODE {
		return refuse(parser, .Named_Argument_Twice, start, start + len(name), NO_NODE)
	}
	equal_accept(parser)
	val: Node_Index
	if pstart, pend, is_whole := placeholder_whole_ahead(parser); is_whole {
		parser.position = pend
		if !in_pipe_rhs {
			if parser.pipe_call_depth > 0 {
				val = refuse(parser, .Placeholder_Nested, pstart, pend, NO_NODE)
			} else {
				val = refuse(parser, .Placeholder_Without_Pipe, pstart, pend, NO_NODE)
			}
		} else if placeholder_seen^ {
			val = refuse(parser, .Placeholder_Twice, pstart, pend, NO_NODE)
		} else {
			placeholder_seen^ = true
			val = node_add_raw(parser, {kind = .Placeholder, span_off = u32(pstart), a = u32(pend)})
		}
	} else {
		parser.in_direct_pipe_arg = in_pipe_rhs
		val = pipeline_read(parser)
		parser.in_direct_pipe_arg = false
	}
	named := node_add_raw(parser, {
		kind     = .Named_Argument,
		span_off = u32(start),
		a        = u32(val),
		b        = u32(start + len(name)),
	})
	if hashed^ && named != NO_NODE {
		dup_insert(parser, call, name, named)
	}
	return named
}

@(private)
literal_read :: proc "contextless" (parser: ^Parser, start: int) -> Node_Index {
	text := parser.tree.text
	literal := node_add_raw(parser, {kind = .Record_Literal, span_off = u32(start)})
	if literal == NO_NODE || accept(parser, '}') {
		return literal
	}
	mark := parser.scratch_top
	hashed := false
	for {
		skip_spaces(parser)
		field_start := parser.position
		if console_language.token_next(text, field_start, parser.multiline).kind != .Name {
			scratch_push(parser, refuse(parser, .Literal_Name_Missing, field_start, field_start, NO_NODE))
			break
		}
		name := read_name(parser)
		if word_of_lex(name) {
			scratch_push(parser, refuse(parser, .Word_As_Name, field_start, field_start + len(name), NO_NODE))
			break
		}
		if scratch_child_named(parser, literal, mark, .Literal_Field, name, &hashed) != NO_NODE {
			scratch_push(parser, refuse(parser, .Literal_Field_Twice, field_start, field_start + len(name), NO_NODE))
			break
		}
		if !equal_accept(parser) {
			scratch_push(parser, refuse(parser, .Literal_Equal_Missing, parser.position, parser.position, NO_NODE))
			break
		}
		field := node_add_raw(parser, {
			kind     = .Literal_Field,
			span_off = u32(field_start),
			a        = NO_NODE_U32,
			b        = u32(field_start + len(name)),
		})
		if field == NO_NODE {
			break
		}
		if hashed {
			dup_insert(parser, literal, name, field)
		}
		val := pipeline_read(parser)
		if fn := node_at(parser.tree, field); fn != nil {
			fn.a = u32(val)
		}
		scratch_push(parser, field)
		if refused(parser) || accept(parser, '}') {
			break
		}
		if !accept(parser, ',') {
			scratch_push(parser, refuse(parser, .Literal_Close_Missing, parser.position, parser.position, NO_NODE))
			break
		}
		if parser.trailing_commas && accept(parser, '}') {
			break
		}
	}
	cstart, ccount, _ := children_commit(parser, mark)
	if ln := node_at(parser.tree, literal); ln != nil {
		ln.a = cstart
		ln.b = ccount
	}
	return literal
}

// pattern_record_read reads `{ a, b = 10, ... }` (optionally prefixed with
// `as_name @` already consumed by the caller).
@(private)
pattern_record_read :: proc "contextless" (parser: ^Parser, start: int, has_as: bool, as_start, as_end: int) -> Node_Index {
	text := parser.tree.text
	pat := node_add_raw(parser, {
		kind     = .Pattern_Record,
		sub      = has_as ? PAT_FLAG_HAS_AS : 0,
		span_off = u32(start),
	})
	if pat == NO_NODE {
		return NO_NODE
	}
	mark := parser.scratch_top
	if has_as {
		as_node := node_add_raw(parser, {kind = .Parameter, span_off = u32(as_start), a = u32(as_end)})
		scratch_push(parser, as_node)
	}
	hashed := false
	has_rest := false
	if !accept(parser, '}') {
		for {
			skip_spaces(parser)
			fstart := parser.position
			// Check for `...` open-rest marker.
			if fstart + 2 < len(text) && text[fstart] == '.' && text[fstart + 1] == '.' && text[fstart + 2] == '.' {
				parser.position = fstart + 3
				has_rest = true
				if accept(parser, ',') {
					if parser.trailing_commas && accept(parser, '}') {
						break
					}
					skip_spaces(parser)
					if accept(parser, '}') {
						break
					}
					scratch_push(parser, refuse(parser, .Pattern_Rest_Not_Last, parser.position, parser.position, NO_NODE))
					break
				}
				if !accept(parser, '}') {
					scratch_push(parser, refuse(parser, .Pattern_Close_Missing, parser.position, parser.position, NO_NODE))
				}
				break
			}
			tok := console_language.token_next(text, fstart, parser.multiline)
			if tok.kind != .Name {
				scratch_push(parser, refuse(parser, .Pattern_Field_Missing, fstart, fstart, NO_NODE))
				break
			}
			fname := read_name(parser)
			if word_of_lex(fname) {
				scratch_push(parser, refuse(parser, .Word_As_Name, fstart, fstart + len(fname), NO_NODE))
				break
			}
			dotted := false
			for ch in fname {
				if ch == '.' {
					dotted = true
					break
				}
			}
			if dotted {
				scratch_push(parser, refuse(parser, .Pattern_Field_Missing, fstart, fstart + len(fname), NO_NODE))
				break
			}
			if scratch_child_named(parser, pat, mark, .Pattern_Field, fname, &hashed) != NO_NODE {
				scratch_push(parser, refuse(parser, .Pattern_Field_Twice, fstart, fstart + len(fname), NO_NODE))
				break
			}
			def_node := NO_NODE
			if equal_accept(parser) {
				saved_direct := parser.in_direct_pipe_arg
				parser.in_direct_pipe_arg = false
				def_node = pipeline_read(parser)
				parser.in_direct_pipe_arg = saved_direct
			}
			fnode := node_add_raw(parser, {
				kind     = .Pattern_Field,
				span_off = u32(fstart),
				a        = u32(def_node),
				b        = u32(fstart + len(fname)),
			})
			if hashed && fnode != NO_NODE {
				dup_insert(parser, pat, fname, fnode)
			}
			scratch_push(parser, fnode)
			if refused(parser) {
				break
			}
			if accept(parser, '}') {
				break
			}
			if !accept(parser, ',') {
				scratch_push(parser, refuse(parser, .Pattern_Close_Missing, parser.position, parser.position, NO_NODE))
				break
			}
			if accept(parser, '}') {
				break
			}
		}
	}
	cstart, ccount, _ := children_commit(parser, mark)
	if pn := node_at(parser.tree, pat); pn != nil {
		if has_rest {
			pn.sub |= PAT_FLAG_REST
		}
		pn.a = cstart
		pn.b = ccount
	}
	return pat
}

@(private)
let_read :: proc "contextless" (parser: ^Parser, start: int) -> Node_Index {
	text := parser.tree.text
	let_node := node_add_raw(parser, {kind = .Let, span_off = u32(start)})
	if let_node == NO_NODE {
		return NO_NODE
	}
	mark := parser.scratch_top
	hashed := false
	has_body := false
	for {
		skip_spaces(parser)
		name_start := parser.position
		if peek(parser) == '{' {
			// Record destructuring `let { a, b = 1, ... } = expr`.
			parser.position += 1
			pat := pattern_record_read(parser, name_start, false, 0, 0)
			if refused(parser) {
				scratch_push(parser, pat)
				break
			}
			if !equal_accept(parser) {
				scratch_push(parser, refuse(parser, .Let_Equal_Missing, parser.position, parser.position, NO_NODE))
				break
			}
			binding := node_add_raw(parser, {
				kind     = .Let_Binding,
				sub      = LET_BINDING_PATTERN,
				span_off = u32(name_start),
				a        = NO_NODE_U32,
				b        = u32(pat),
			})
			if binding == NO_NODE {
				break
			}
			val := pipeline_read(parser)
			if bn := node_at(parser.tree, binding); bn != nil {
				bn.a = u32(val)
			}
			scratch_push(parser, binding)
		} else {
			if console_language.token_next(text, name_start, parser.multiline).kind != .Name {
				scratch_push(parser, refuse(parser, .Let_Name_Missing, name_start, name_start, NO_NODE))
				break
			}
			name := read_name(parser)
			if word_of_lex(name) {
				scratch_push(parser, refuse(parser, .Word_As_Name, name_start, name_start + len(name), NO_NODE))
				break
			}
			if accept(parser, '@') {
				// As-pattern destructuring `let r @ { a, b } = expr`.
				if !accept(parser, '{') {
					scratch_push(parser, refuse(parser, .Pattern_At_Missing_Brace, parser.position, parser.position, NO_NODE))
					break
				}
				pat := pattern_record_read(parser, name_start, true, name_start, name_start + len(name))
				if refused(parser) {
					scratch_push(parser, pat)
					break
				}
				if !equal_accept(parser) {
					scratch_push(parser, refuse(parser, .Let_Equal_Missing, parser.position, parser.position, NO_NODE))
					break
				}
				binding := node_add_raw(parser, {
					kind     = .Let_Binding,
					sub      = LET_BINDING_PATTERN,
					span_off = u32(name_start),
					a        = NO_NODE_U32,
					b        = u32(pat),
				})
				if binding == NO_NODE {
					break
				}
				val := pipeline_read(parser)
				if bn := node_at(parser.tree, binding); bn != nil {
					bn.a = u32(val)
				}
				scratch_push(parser, binding)
			} else {
				if scratch_child_named(parser, let_node, mark, .Let_Binding, name, &hashed) != NO_NODE {
					scratch_push(parser, refuse(parser, .Let_Name_Twice, name_start, name_start + len(name), NO_NODE))
					break
				}
				if !equal_accept(parser) {
					scratch_push(parser, refuse(parser, .Let_Equal_Missing, parser.position, parser.position, NO_NODE))
					break
				}
				binding := node_add_raw(parser, {
					kind     = .Let_Binding,
					span_off = u32(name_start),
					a        = NO_NODE_U32,
					b        = u32(name_start + len(name)),
				})
				if binding == NO_NODE {
					break
				}
				if hashed {
					dup_insert(parser, let_node, name, binding)
				}
				val := pipeline_read(parser)
				if bn := node_at(parser.tree, binding); bn != nil {
					bn.a = u32(val)
				}
				scratch_push(parser, binding)
			}
		}
		if refused(parser) {
			break
		}
		if accept(parser, ',') {
			if parser.trailing_commas {
				if in_end, has_in := word_ahead(parser, "in"); has_in {
					parser.position = in_end
					body := pipeline_read(parser)
					scratch_push(parser, body)
					has_body = true
					break
				}
			}
			continue
		}
		end, found := word_ahead(parser, "in")
		if !found {
			scratch_push(parser, refuse(parser, .Let_In_Missing, parser.position, parser.position, NO_NODE))
			break
		}
		parser.position = end
		body := pipeline_read(parser)
		scratch_push(parser, body)
		has_body = true
		break
	}
	cstart, ccount, _ := children_commit(parser, mark)
	if ln := node_at(parser.tree, let_node); ln != nil {
		ln.a = cstart
		ln.b = ccount
	}
	if has_body && len(parser.tree.bindings) > 0 {
		for child in node_children(parser.tree, let_node) {
			cn := node_at(parser.tree, child)
			target := cn != nil && cn.kind == .Let_Binding ? node_child(parser.tree, child) : child
			names_bind(parser, let_node, .Let_Binding, target, hashed)
		}
	}
	return let_node
}

@(private)
function_read :: proc "contextless" (parser: ^Parser, open, close, arrow_end: int) -> Node_Index {
	tree := parser.tree
	text := tree.text
	function := node_add_raw(parser, {
		kind     = .Function,
		span_off = u32(open),
		b        = u32(arrow_end),
	})
	if function == NO_NODE {
		return NO_NODE
	}
	outer := parser.function
	parser.function = function
	defer parser.function = outer

	mark := parser.scratch_top
	hashed := false
	parser.position = open + 1
	ok_head := true
	if !accept(parser, ')') {
		count := 0
		for {
			skip_spaces(parser)
			name_start := parser.position
			if count == ARGUMENT_CAPACITY {
				scratch_push(parser, refuse(parser, .Too_Many_Parameters, name_start, name_start, NO_NODE))
				ok_head = false
				break
			}
			if peek(parser) == '{' {
				parser.position += 1
				pat := pattern_record_read(parser, name_start, false, 0, 0)
				scratch_push(parser, pat)
				if refused(parser) {
					ok_head = false
					break
				}
			} else {
				token := console_language.token_next(text, name_start, parser.multiline)
				if token.kind != .Name {
					scratch_push(parser, refuse(parser, .Parameter_Name_Missing, name_start, name_start, NO_NODE))
					ok_head = false
					break
				}
				name := read_name(parser)
				if word_of_lex(name) {
					scratch_push(parser, refuse(parser, .Word_As_Name, name_start, name_start + len(name), NO_NODE))
					ok_head = false
					break
				}
				dotted := false
				for character in name {
					if character == '.' {
						dotted = true
						break
					}
				}
				if dotted {
					scratch_push(parser, refuse(parser, .Parameter_Name_Missing, name_start, name_start + len(name), NO_NODE))
					ok_head = false
					break
				}
				if accept(parser, '@') {
					if !accept(parser, '{') {
						scratch_push(parser, refuse(parser, .Pattern_At_Missing_Brace, parser.position, parser.position, NO_NODE))
						ok_head = false
						break
					}
					pat := pattern_record_read(parser, name_start, true, name_start, name_start + len(name))
					scratch_push(parser, pat)
					if refused(parser) {
						ok_head = false
						break
					}
				} else {
					if scratch_child_named(parser, function, mark, .Parameter, name, &hashed) != NO_NODE {
						scratch_push(parser, refuse(parser, .Parameter_Twice, name_start, name_start + len(name), NO_NODE))
						ok_head = false
						break
					}
					param := node_add_raw(parser, {kind = .Parameter, span_off = u32(name_start), a = u32(name_start + len(name))})
					scratch_push(parser, param)
					if refused(parser) {
						ok_head = false
						break
					}
				}
			}
			count += 1
			if accept(parser, ')') {
				break
			}
			if !accept(parser, ',') {
				scratch_push(parser, refuse(parser, .Comma_Or_Close_Missing, parser.position, parser.position, NO_NODE))
				ok_head = false
				break
			}
		}
	}
	body := NO_NODE
	if ok_head {
		if parser.position != close + 1 {
			scratch_push(parser, refuse(parser, .Unexpected, parser.position, len(text), NO_NODE))
		} else {
			parser.position = arrow_end
			body = pipeline_read(parser)
			scratch_push(parser, body)
		}
	}
	cstart, ccount, _ := children_commit(parser, mark)
	if fn := node_at(tree, function); fn != nil {
		fn.a = cstart
		fn.aux = u16(ccount)
	}
	if body != NO_NODE && len(tree.bindings) > 0 {
		names_bind(parser, function, .Parameter, body, false)
	}
	return function
}

@(private)
list_read :: proc "contextless" (parser: ^Parser, start: int) -> Node_Index {
	list := node_add_raw(parser, {kind = .List_Literal, span_off = u32(start)})
	if list == NO_NODE || accept(parser, ']') {
		return list
	}
	mark := parser.scratch_top
	for {
		scratch_push(parser, pipeline_read(parser))
		if refused(parser) || accept(parser, ']') {
			break
		}
		if !accept(parser, ',') {
			scratch_push(parser, refuse(parser, .List_Close_Missing, parser.position, parser.position, NO_NODE))
			break
		}
		if parser.trailing_commas && accept(parser, ']') {
			break
		}
	}
	cstart, ccount, _ := children_commit(parser, mark)
	if ln := node_at(parser.tree, list); ln != nil {
		ln.a = cstart
		ln.b = ccount
	}
	return list
}

@(private)
committed_child_named :: proc "contextless" (parser: ^Parser, owner: Node_Index, kind: Node_Kind, name: string, hashed: bool) -> Node_Index {
	if hashed {
		if found, ok := dup_find(parser, owner, name); ok {
			return found
		}
	}
	for child in node_children(parser.tree, owner) {
		if cn := node_at(parser.tree, child); cn != nil && cn.kind == kind && node_text(parser.tree, child) == name {
			return child
		}
	}
	return NO_NODE
}

// names_bind links each unbound Name/Call in a subtree to its enclosing
// Let_Binding or Parameter (L1 bridge; replaced by De Bruijn compiler in L2).
@(private)
names_bind :: proc "contextless" (parser: ^Parser, owner: Node_Index, binding_kind: Node_Kind, index: Node_Index, hashed: bool) {
	tree := parser.tree
	node := node_at(tree, index)
	if node == nil {
		return
	}
	if (node.kind == .Name || node.kind == .Call) && int(index) < len(tree.bindings) && tree.bindings[int(index)] == NO_NODE {
		name := node_text(tree, index)
		head := name
		for character, place in name {
			if character == '.' {
				head = name[:place]
				break
			}
		}
		if head != "" {
			tree.bindings[int(index)] = committed_child_named(parser, owner, binding_kind, head, hashed)
		}
	}
	switch node.kind {
	case .Negate, .Logical_Not, .Field_Select, .Literal_Field, .Let_Binding, .Named_Argument, .Refused, .Condition, .Pattern_Field:
		names_bind(parser, owner, binding_kind, node_child(tree, index), hashed)
	case .Binary, .Pipe:
		left, right := node_binary_children(tree, index)
		names_bind(parser, owner, binding_kind, left, hashed)
		names_bind(parser, owner, binding_kind, right, hashed)
	case .Call, .Record_Literal, .List_Literal, .Let, .Function, .If, .Text_Interp, .Pattern_Record:
		for child in node_children(tree, index) {
			names_bind(parser, owner, binding_kind, child, hashed)
		}
	case .Integer, .Text, .Name, .Fact_Name, .Field_Names, .Member, .Parameter, .Hash, .Boolean, .Placeholder:
	}
}

@(private)
fact_name_read :: proc "contextless" (parser: ^Parser) -> Node_Index {
	skip_spaces(parser)
	start := parser.position
	name := read_name(parser)
	ref := Refusal.None
	if len(name) == 0 {
		ref = .Fact_Name_Missing
		refusal_keep(parser, .Fact_Name_Missing, start)
	}
	return node_add_raw(parser, {
		kind     = .Fact_Name,
		sub      = u8(ref),
		span_off = u32(start),
		a        = u32(start + len(name)),
	})
}

@(private)
field_names_read :: proc "contextless" (parser: ^Parser) -> Node_Index {
	skip_spaces(parser)
	start := parser.position
	ref := Refusal.None
	for {
		name := read_name(parser)
		if len(name) == 0 {
			ref = .Field_Name_Missing
			refusal_keep(parser, .Field_Name_Missing, parser.position)
			break
		}
		if peek(parser) != ',' {
			break
		}
		parser.position += 1
	}
	return node_add_raw(parser, {
		kind     = .Field_Names,
		sub      = u8(ref),
		span_off = u32(start),
		a        = u32(parser.position),
	})
}

@(private)
condition_read :: proc "contextless" (parser: ^Parser) -> Node_Index {
	tree := parser.tree
	text := tree.text
	start := console_language.space_end(text, parser.position)
	head, head_refusal := console_condition.head_read(text, parser.position)
	if tree.condition_count >= len(tree.conditions) {
		return refuse(parser, .Nodes_Full, start, start, NO_NODE)
	}
	cond_idx := u32(tree.condition_count)
	tree.condition_count += 1
	end_off := head_refusal == .None ? u32(head.value_start) : u32(start)
	tree.conditions[cond_idx] = {
		head    = head,
		refusal = head_refusal,
		end     = end_off,
	}
	if head_refusal != .None {
		refusal_keep(parser, .Condition_Head_Refused, start, u64(head_refusal))
		return node_add_raw(parser, {
			kind     = .Condition,
			sub      = u8(Refusal.Condition_Head_Refused),
			span_off = u32(start),
			a        = NO_NODE_U32,
			b        = cond_idx,
		})
	}
	parser.position = head.value_start
	first := console_language.token_next(text, head.value_start)
	after := console_language.token_next(text, first.end)
	tree.conditions[cond_idx].member_alone = after.kind == .Operator && (text[after.start] == ')' || text[after.start] == ',')
	val := pipeline_read(parser)
	return node_add_raw(parser, {
		kind     = .Condition,
		sub      = u8(Refusal.None),
		span_off = u32(start),
		a        = u32(val),
		b        = cond_idx,
	})
}
