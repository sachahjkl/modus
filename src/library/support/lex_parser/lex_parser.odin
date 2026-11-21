// The parser of Lex: a text becomes a syntax tree, a typed node for each
// part with its line and its column (src/md/features/declarations.md, "The
// parser package"). The console evaluates the tree; this package reads
// text and evaluates nothing.
//
//   line       = name "=" expression | expression
//   expression = sum { "with" sum }
//   sum        = term { ("+" | "-") term }
//   term       = factor { ("*" | "/" | "%") factor }
//   factor     = "-" factor | integer | "text" | name | "." name | name "(" arguments ")" | "(" expression ")"
//              | "{" [ name "=" expression { "," name "=" expression } ] "}"
//              | "let" name "=" expression { "," name "=" expression } "in" expression
//              | "(" [ name { "," name } ] ")" "=>" expression
//              | "[" [ expression { "," expression } ] "]"
//   arguments  = argument { "," argument }
//   argument   = [ name "=" ] expression | condition | fact name | field names
//   condition  = name ("=" | "!=" | "<" | "<=" | ">" | ">=") expression
//   field names = name { "," name }       (the last argument of its call)
//
// `_`, `let`, `in` and `with` are words of Lex, never names. After a whole
// `let`, each name that its values and its body read is bound to its
// binding: a Name node keeps the Let_Binding in `binding`. After a whole
// function, each name of its body is bound to its Parameter in the same
// way, and a call whose name a let or a parameter binds keeps it too. A
// '(' starts a function when its group closes and "=>" follows
// (console_language.function_head); each node keeps the innermost
// function that holds it in `function`.
//
// The parser reads no "|>": the console gives it the nested form of the
// line, with calls in calls (console_language, pipe.odin). The form of
// each argument of a call (Parameter_Form) comes from the command table of
// the caller, through a Form_Lookup: inside `where`, `=` is the operator
// of a condition.
//
// A refusal does not end the tree: it is a node at the place of the fault,
// and the parse stops there. The console evaluates the tree from the left
// and meets the refusal where its one pass met it before, so the calls of
// the line before the fault still run, and the line fails with the same
// sentence. The sentences stay in the console: a refusal is a record.
//
// The package has no state, calls no allocator and makes no kernel call:
// the caller gives the memory of the tree, and host tests give each input.
package lex_parser

import module "modus:contract/module"
import "modus:support/console_condition"
import "modus:support/console_language"
import "modus:support/line_editor"

// The bytes of the longest text: the longest line that the console runs.
// The nested form of a line is never longer than its line. Each level of a
// nesting takes one byte at least, so this bound is also the bound of the
// depth of the parser.
TEXT_BYTES_MOST :: line_editor.LINE_CAPACITY

// The bytes and nesting depth of a multi-line declaration file (.lex).
DECLARATION_TEXT_BYTES_MOST :: 64 * 1024
DECLARATION_PARSE_DEPTH_LIMIT :: 256

// The nodes of the longest text: each node but the one refusal reads one
// byte or more of its own, so a text of TEXT_BYTES_MOST bytes fills the
// memory at most.
NODE_CAPACITY :: TEXT_BYTES_MOST + 1

// The arguments of a call: those of an export at most.
ARGUMENT_CAPACITY :: module.PARAMETER_CAPACITY

// The place of a node in the memory of its tree.
Node_Index :: distinct i32

// No node: the end of a list of arguments, or a node with no child.
NO_NODE :: Node_Index(-1)

// What the parser reads for a parameter of a command. Most parameters take
// an expression; a few take a name that the console checks against a
// description, never a variable (src/md/features/log_facts.md, "Filters
// of a reader: one form").
Parameter_Form :: enum u8 {
	Expression  = 0, // An expression, whose value has the kind of the parameter.
	Fact_Name   = 1, // The name of a fact type, "package.Type".
	Condition   = 2, // A field of the table of the first argument, an operator and a value.
	Field_Names = 3, // The last parameter: one name of a field of the table of the first argument or more, separated by commas.
}

// The caller gives the form of each parameter of a command. The package
// keeps no table of commands: the console changes its own with each module
// that it loads.
Form_Lookup :: struct {
	data:    rawptr, // The state of the caller.
	form_of: proc "contextless" (data: rawptr, command_name: string, index: int) -> Parameter_Form, // The form of the parameter index of a command; Expression for a name that no command has.
}

// form_of gives the form of a parameter through a lookup. A lookup with no
// procedure knows no command: each argument is an expression.
form_of :: proc "contextless" (lookup: Form_Lookup, command_name: string, index: int) -> Parameter_Form {
	return lookup.form_of == nil ? .Expression : lookup.form_of(lookup.data, command_name, index)
}

// The kinds of nodes.
Node_Kind :: enum u8 {
	Integer     = 0, // An integer literal: its value is in `integer`.
	Text        = 1, // A text literal: its bytes, with the two quotes.
	Name        = 2, // A name alone: a variable, `variable.field`, or a command named with no parentheses.
	Call        = 3, // A name and its arguments: the bytes are the name, the children the arguments.
	Negate      = 4, // "-" before a factor: the child is the factor.
	Binary      = 5, // Two operands and an operator: the bytes are the operator, the children the left then the right.
	Condition   = 6, // A field, an operator and a value: the bytes are the field and the operator, the child the value.
	Fact_Name   = 7, // The name of a fact type; with the refusal Fact_Name_Missing, no name.
	Refused     = 8, // The fault where the parse stopped: the child is the part that was read before it, or none.
	Field_Names = 9, // The names of fields, with their commas and the spaces after the last; with the refusal Field_Name_Missing, a name is missing.
	Record_Literal = 10, // "{ … }": the bytes are "{", the children its fields.
	Literal_Field  = 11, // A field of a record literal: the bytes are its name, the child its value.
	Named_Argument = 12, // An argument `name = value`: the bytes are the name, the child the value.
	Let            = 13, // "let … in …": the bytes are "let", the children its bindings, then its body.
	Let_Binding    = 14, // A binding of a let: the bytes are its name, the child its value.
	Member         = 15, // A member of an enum, `.french`: the bytes are the '.' and the name. The parameter that receives it gives its enum.
	Function       = 16, // "(…) => …": the bytes are "=>", `integer` the offset of its '(', the children its parameters, then its body.
	Parameter      = 17, // A parameter of a function: the bytes are its name.
	List_Literal   = 18, // "[ … ]": the bytes are "[", the children its items.
	Hash           = 19, // A BLAKE3 hash literal: "blake3:" and 64 lowercase hexadecimal digits.
	Boolean        = 20, // `true` (integer = 1) or `false` (integer = 0).
	If             = 21, // `if cond then a else b`: children are cond, then branch, else branch.
	Field_Select   = 22, // Postfix `.field` on an expression: bytes are the field name, child is the base expression.
}

// The operators of a Binary node.
Operator :: enum u8 {
	None             = 0, // Each node but a Binary.
	Add              = 1, // "+": two Integers, or two Texts that it joins.
	Subtract         = 2, // "-"
	Multiply         = 3, // "*"
	Divide           = 4, // "/"
	Remainder        = 5, // "%"
	With             = 6, // `with`: a record, with the fields of the record on its right.
	Equal            = 7, // "="
	Not_Equal        = 8, // "!="
	Less             = 9, // "<"
	Less_Or_Equal    = 10, // "<="
	Greater          = 11, // ">"
	Greater_Or_Equal = 12, // ">="
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
}

// The words of Lex: no name has one of them.
@(rodata)
WORDS_OF_LEX := [?]string{"_", "let", "in", "with", "if", "then", "else", "true", "false"}

// name_valid says if a text is one name of Lex, with no '.': a letter or
// '_', then letters, digits and '_', and no word of Lex. The console builds
// a line from the name of an export and of its parameters, which another
// party wrote in its module file: a name that is no name of Lex could add a
// call of its own to that line.
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

// word_of_lex says if a name is a word of Lex: `_` is the placeholder of
// `|>`, and `let`, `in` and `with` are words of its forms.
word_of_lex :: proc "contextless" (name: string) -> bool {
	for word in WORDS_OF_LEX {
		if name == word {
			return true
		}
	}
	return false
}


// Why a text has no whole tree. The values are fixed: a test names the
// member, and a record keeps it.
Refusal :: enum u8 {
	None                      = 0, // The tree is whole.
	Text_Too_Long             = 1, // More than TEXT_BYTES_MOST bytes. value: the bytes of the text.
	Nodes_Full                = 2, // The memory of the tree is full; the count of NODE_CAPACITY says that no text reaches it.
	Line_Ends_Too_Soon        = 3, // A value is missing at the end of the text: "", "1 +", "f(".
	Unexpected                = 4, // A byte that starts no value here, or more after the expression: the bytes from it to the end.
	Number_Too_Large          = 5, // The digits are past the largest Integer: the bytes are the digits.
	Text_Without_End_Quote    = 6, // A quote with no end quote: the bytes run to the end.
	Close_Parenthesis_Missing = 7, // "(" and an expression, then no ")".
	Comma_Or_Close_Missing    = 8, // An argument, then neither "," nor ")".
	Too_Many_Arguments        = 9, // A "," after ARGUMENT_CAPACITY arguments.
	Fact_Name_Missing         = 10, // The argument of a fact name holds no name.
	Condition_Head_Refused    = 11, // The field or the operator of a condition. value: the console_condition.Refusal.
	Field_Name_Missing        = 12, // An argument of field names with no name at the start or after a ",": the place is where the name is missing.
	Literal_Close_Missing     = 13, // A field of a record literal, then neither "," nor "}".
	Literal_Name_Missing      = 14, // In "{ }", no name of a field where one starts: "{= 1}", "{1}", "{a = 1,}".
	Literal_Equal_Missing     = 15, // A name of a field with no single "=" after it: "{a 1}", "{a == 1}".
	Literal_Field_Twice       = 16, // A field given twice in one literal: the place is the second.
	Named_Argument_Twice      = 17, // A name given twice in one call: the place is the second.
	Positional_After_Named    = 18, // An argument with no name after a named one.
	Let_Name_Missing          = 19, // "let" or a "," of its bindings, then no name.
	Let_Equal_Missing         = 20, // A name of a binding with no single "=" after it.
	Let_In_Missing            = 21, // A binding, then neither "," nor "in".
	Let_Name_Twice            = 22, // A name bound twice in one let: the place is the second.
	Word_As_Name              = 23, // "_", "let", "in" or "with" where a name is read: the bytes are the word.
	Parameter_Name_Missing    = 24, // In the parentheses of a function, no name where a parameter starts, or a name with a '.': "(1) =>", "(x,) =>", "(a.b) =>".
	Parameter_Twice           = 25, // A parameter named twice in one function: the place is the second.
	Too_Many_Parameters       = 26, // A parameter after ARGUMENT_CAPACITY parameters: a call takes no more arguments.
	List_Close_Missing        = 27, // An item of a list, then neither "," nor "]".
	Hash_Not_Valid            = 28, // A `blake3:` literal that does not have exactly 64 lowercase hexadecimal digits.
	If_Then_Missing           = 29, // `if <condition>` with no `then` after it.
	If_Else_Missing           = 30, // `if <condition> then <value>` with no `else` after it.
	Nesting_Too_Deep          = 31, // An expression nested deeper than the parser bound.
}

// Where a node is in its text: its first byte.
Place :: struct {
	line:   u32, // From 1.
	column: u32, // From 1, in bytes.
	offset: u32, // From 0, in bytes from the start of the text.
}

// The first refusal of a text, and where it is.
Refusal_Record :: struct {
	refusal: Refusal,
	place:   Place,
	value:   u64, // What the member of Refusal says.
}

// One part of a text.
Node :: struct {
	kind:              Node_Kind,
	operator:          Operator, // Binary: its operator.
	refusal:           Refusal, // Refused: why. Fact_Name and Condition: their refusal, or None.
	place:             Place, // The first byte of the node.
	end:               u32, // The byte after the bytes of the node itself (its children have their own).
	integer:           i64, // Integer: its value. Function: the offset of its '('.
	first_child:       Node_Index, // The first argument, the left operand, the factor of Negate, the value of a condition, the part before a refusal.
	next_sibling:      Node_Index, // The next argument of a call, or the right operand after the left one.
	condition_head:    console_condition.Head, // Condition: the field, the operator and the place of the value, as head_read gives them.
	condition_refusal: console_condition.Refusal, // Condition: the refusal of head_read; the parse stops at it.
	member_alone:      bool, // Condition: the first token of the value is followed by "," or ")": a name of a member of a status is the whole value.
	binding:           Node_Index, // Name: the Let_Binding or the Parameter whose name it reads, before its first '.'. Call: the one whose name it calls. Or NO_NODE: a name of the host.
	function:          Node_Index, // The innermost Function whose parameters or body hold this node, or NO_NODE: the top of the text.
}

// The tree of one text, in the memory of the caller. Each string is a part
// of the text, so the text must live as long as the tree. When external_nodes
// is non-empty (declaration parsing), nodes are stored there instead of the
// inline console buffer.
Syntax_Tree :: struct {
	text:           string,
	nodes:          [NODE_CAPACITY]Node,
	external_nodes: []Node,
	node_count:     int,
	root:           Node_Index, // The expression of the line, or the refusal that holds it.
	assigned_name:  string, // The variable that the line names before "=", or "".
	refusal:        Refusal_Record, // The refusal where the parse stopped, or None.
}

// The state of one parse.
@(private)
Parser :: struct {
	tree:            ^Syntax_Tree,
	lookup:          Form_Lookup,
	position:        int,
	counted:         int, // The places before this byte are counted in line and line_start.
	line:            u32,
	line_start:      int,
	function:        Node_Index, // The function whose parameters or body the parser reads, or NO_NODE.
	multiline:       bool,
	trailing_commas: bool,
	depth:           int,
	depth_limit:     int, // 0: no separate depth bound (bounded by TEXT_BYTES_MOST).
}

// tree_nodes gives the active node buffer of tree: external_nodes when
// provided, else the inline console buffer.
tree_nodes :: proc "contextless" (tree: ^Syntax_Tree) -> []Node {
	return len(tree.external_nodes) > 0 ? tree.external_nodes : tree.nodes[:]
}

// parse reads a console line into tree. The tree is whole when
// tree.refusal.refusal is None; else the parse stopped at the refusal, which
// is a node in its place, and each node before it is in the tree.
parse :: proc "contextless" (text: string, lookup: Form_Lookup, tree: ^Syntax_Tree) {
	tree.external_nodes = nil
	parse_with_limits(text, lookup, tree, TEXT_BYTES_MOST, false, false, true, 0)
}

// parse_declaration reads a multi-line .lex declaration file into tree,
// storing its nodes in external_nodes (or tree.nodes when nil). Tabs, line
// ends, multi-line comments and trailing commas are accepted, top-level
// console variable assignments are not, and recursion depth is bounded by
// depth_limit.
parse_declaration :: proc "contextless" (text: string, external_nodes: []Node, tree: ^Syntax_Tree, text_bytes_most: int = DECLARATION_TEXT_BYTES_MOST, depth_limit: int = DECLARATION_PARSE_DEPTH_LIMIT) {
	tree.external_nodes = external_nodes
	parse_with_limits(text, {}, tree, text_bytes_most, true, true, false, depth_limit)
}

@(private)
parse_with_limits :: proc "contextless" (text: string, lookup: Form_Lookup, tree: ^Syntax_Tree, text_bytes_most: int, multiline, trailing_commas, allow_assignment: bool, depth_limit: int) {
	tree.text, tree.node_count, tree.root, tree.assigned_name = text, 0, NO_NODE, ""
	tree.refusal = {}
	parser := Parser {
		tree            = tree,
		lookup          = lookup,
		line            = 1,
		function        = NO_NODE,
		multiline       = multiline,
		trailing_commas = trailing_commas,
		depth_limit     = depth_limit,
	}
	if len(text) > text_bytes_most {
		tree.root = refuse(&parser, .Text_Too_Long, text_bytes_most, len(text), NO_NODE, u64(len(text)))
		return
	}
	// An assignment starts with a name and a single "=". A word of Lex is
	// no name of a variable. Only console lines accept assignments.
	if allow_assignment {
		name := read_name(&parser)
		name_start := parser.position - len(name)
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
	expression := expression_read(&parser)
	if refused(&parser) {
		tree.root = expression
		return
	}
	if peek(&parser) != 0 {
		tree.root = refuse(&parser, .Unexpected, parser.position, len(text), expression)
		return
	}
	tree.root = expression
}

// node_at gives a node of a tree, or nil for NO_NODE and for an index past
// the nodes of the tree.
node_at :: proc "contextless" (tree: ^Syntax_Tree, index: Node_Index) -> ^Node {
	nodes := tree_nodes(tree)
	if index < 0 || int(index) >= tree.node_count || int(index) >= len(nodes) {
		return nil
	}
	return &nodes[int(index)]
}

// node_text gives the bytes of a node itself: the digits, the text with its
// quotes, the name, the operator, the field and the operator of a
// condition, the bytes that a refusal names.
node_text :: proc "contextless" (tree: ^Syntax_Tree, index: Node_Index) -> string {
	node := node_at(tree, index)
	if node == nil {
		return ""
	}
	start := min(int(node.place.offset), len(tree.text))
	return tree.text[start:clamp(int(node.end), start, len(tree.text))]
}

// next_of gives the node after a node in the list of its parent, or
// NO_NODE.
next_of :: proc "contextless" (tree: ^Syntax_Tree, index: Node_Index) -> Node_Index {
	node := node_at(tree, index)
	return node == nil ? NO_NODE : node.next_sibling
}

// place_of_offset gives the line and the column of a byte of a text. An
// offset before the text is its first byte, and one past it its end.
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

// ---- The memory of the tree.

// place_at gives the place of a byte. The parser makes its nodes from the
// left, so it counts each line once; a place before the counted bytes
// counts again from the start.
@(private)
place_at :: proc "contextless" (parser: ^Parser, offset: int) -> Place {
	text := parser.tree.text
	if offset < parser.counted {
		parser.counted, parser.line, parser.line_start = 0, 1, 0
	}
	for parser.counted < min(offset, len(text)) {
		if text[parser.counted] == '\n' {
			parser.line += 1
			parser.line_start = parser.counted + 1
		}
		parser.counted += 1
	}
	return {line = parser.line, column = u32(offset - parser.line_start + 1), offset = u32(offset)}
}

// refused says if the parse stopped.
@(private)
refused :: proc "contextless" (parser: ^Parser) -> bool {
	return parser.tree.refusal.refusal != .None
}

// refusal_keep keeps the first refusal of the parse: a later one changes
// nothing.
@(private)
refusal_keep :: proc "contextless" (parser: ^Parser, refusal: Refusal, offset: int, value: u64 = 0) {
	if parser.tree.refusal.refusal == .None {
		parser.tree.refusal = {refusal = refusal, place = place_at(parser, offset), value = value}
	}
}

// node_add adds a node with the bytes start:end, or gives NO_NODE and
// stops the parse with Nodes_Full.
@(private)
node_add :: proc "contextless" (parser: ^Parser, kind: Node_Kind, start, end: int) -> Node_Index {
	tree := parser.tree
	nodes := tree_nodes(tree)
	if tree.node_count >= len(nodes) {
		refusal_keep(parser, .Nodes_Full, start)
		return NO_NODE
	}
	index := Node_Index(tree.node_count)
	nodes[tree.node_count] = {
		kind         = kind,
		place        = place_at(parser, start),
		end          = u32(end),
		first_child  = NO_NODE,
		next_sibling = NO_NODE,
		binding      = NO_NODE,
		function     = parser.function,
	}
	tree.node_count += 1
	return index
}

// child_append puts child after the last child of parent.
@(private)
child_append :: proc "contextless" (tree: ^Syntax_Tree, parent, child: Node_Index) {
	parent_node := node_at(tree, parent)
	if parent_node == nil || child == NO_NODE {
		return
	}
	if parent_node.first_child == NO_NODE {
		parent_node.first_child = child
		return
	}
	last := parent_node.first_child
	for next_of(tree, last) != NO_NODE {
		last = next_of(tree, last)
	}
	node_at(tree, last).next_sibling = child
}

// refuse adds the Refused node of the fault where the parse stops, with the
// part that was read before it as its child, and keeps the refusal.
@(private)
refuse :: proc "contextless" (parser: ^Parser, refusal: Refusal, start, end: int, before: Node_Index, value: u64 = 0) -> Node_Index {
	refusal_keep(parser, refusal, start, value)
	node := node_add(parser, .Refused, start, end)
	if node_kept := node_at(parser.tree, node); node_kept != nil {
		node_kept.refusal = refusal
		node_kept.first_child = before
	}
	return node
}

// ---- The tokens. The parser reads them with the scanner of
// console_language, the one that colors the lines: the two agree on each
// token.

@(private)
skip_spaces :: proc "contextless" (parser: ^Parser) {
	parser.position = console_language.space_end(parser.tree.text, parser.position, parser.multiline)
}

// peek gives the byte after the spaces, or 0 at the end of the text.
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

// equal_accept takes a single "=": the "=" of an assignment, a named
// argument, a field or a binding, never the first byte of "==" or "=>".
@(private)
equal_accept :: proc "contextless" (parser: ^Parser) -> bool {
	text := parser.tree.text
	if peek(parser) != '=' || parser.position + 1 < len(text) && (text[parser.position + 1] == '=' || text[parser.position + 1] == '>') {
		return false
	}
	parser.position += 1
	return true
}

// word_ahead says if the next token is a word of Lex, and gives the byte
// after it.
@(private)
word_ahead :: proc "contextless" (parser: ^Parser, word: string) -> (end: int, found: bool) {
	token := console_language.token_next(parser.tree.text, parser.position, parser.multiline)
	if console_language.word_is(parser.tree.text, token, word) {
		return token.end, true
	}
	return parser.position, false
}

// named_ahead says if the next tokens are a name and a single "=": a named
// argument, a field of a literal, a binding.
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

// ---- The grammar.

// expression_read reads a comparison over `with` expressions:
//   expression = with_expr [ ("=" | "!=" | "<" | "<=" | ">" | ">=") with_expr ]
// "==" and "=>" are never comparison operators.
@(private)
expression_read :: proc "contextless" (parser: ^Parser) -> Node_Index {
	if parser.depth_limit > 0 && parser.depth >= parser.depth_limit {
		skip_spaces(parser)
		return refuse(parser, .Nesting_Too_Deep, parser.position, parser.position, NO_NODE)
	}
	parser.depth += 1
	defer parser.depth -= 1
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
	binary := node_add(parser, .Binary, op_start, op_start + op_len)
	parser.position = op_start + op_len
	if binary == NO_NODE {
		return left
	}
	node_at(parser.tree, binary).operator = operator
	child_append(parser.tree, binary, left)
	child_append(parser.tree, binary, with_read(parser))
	return binary
}

// with_read reads `with`, whose priority is below "+" and "-".
@(private)
with_read :: proc "contextless" (parser: ^Parser) -> Node_Index {
	left := sum_read(parser)
	for !refused(parser) {
		end, found := word_ahead(parser, "with")
		if !found {
			return left
		}
		skip_spaces(parser)
		binary := node_add(parser, .Binary, parser.position, end)
		parser.position = end
		if binary == NO_NODE {
			return left
		}
		node_at(parser.tree, binary).operator = .With
		child_append(parser.tree, binary, left)
		child_append(parser.tree, binary, sum_read(parser))
		left = binary
	}
	return left
}

@(private)
sum_read :: proc "contextless" (parser: ^Parser) -> Node_Index {
	left := term_read(parser)
	for !refused(parser) {
		operator: Operator
		switch peek(parser) {
		case '+':
			operator = .Add
		case '-':
			operator = .Subtract
		case:
			return left
		}
		left = binary_read(parser, operator, left, term_read)
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

// binary_read reads the operator at the place of the parser and the
// operand on its right.
@(private)
binary_read :: proc "contextless" (parser: ^Parser, operator: Operator, left: Node_Index, right_read: proc "contextless" (parser: ^Parser) -> Node_Index) -> Node_Index {
	binary := node_add(parser, .Binary, parser.position, parser.position + 1)
	parser.position += 1
	if binary == NO_NODE {
		return left
	}
	node_at(parser.tree, binary).operator = operator
	child_append(parser.tree, binary, left)
	child_append(parser.tree, binary, right_read(parser))
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
		negate := node_add(parser, .Negate, start, start + 1)
		parser.position += 1
		if negate == NO_NODE {
			return NO_NODE
		}
		child_append(parser.tree, negate, factor_read(parser))
		return negate
	case character == '(':
		if close, arrow_end, found := console_language.function_head(text, start, parser.multiline); found {
			return function_read(parser, start, close, arrow_end)
		}
		parser.position += 1
		inner := expression_read(parser)
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
		integer := node_add(parser, .Integer, start, end)
		if int_node := node_at(parser.tree, integer); int_node != nil {
			int_node.integer = value
		}
		return integer
	case character == '"':
		end, finished := console_language.text_end(text, start)
		parser.position = end
		if !finished {
			return refuse(parser, .Text_Without_End_Quote, start, end, NO_NODE)
		}
		return node_add(parser, .Text, start, end)
	case character == '{':
		parser.position += 1
		node, allows_postfix = literal_read(parser, start), true
	case character == '[':
		parser.position += 1
		return list_read(parser, start)
	case character == '.':
		// A member names no variable: its enum comes from the parameter
		// that receives it, as the type of a record literal does.
		token := console_language.token_next(text, start, parser.multiline)
		if token.kind != .Member {
			return refuse(parser, .Unexpected, start, len(text), NO_NODE)
		}
		parser.position = token.end
		return node_add(parser, .Member, start, token.end)
	case console_language.hash_starts(text, start):
		end := console_language.hash_end(text, start)
		parser.position = end
		if _, valid := console_language.hash_value(text, start, end); !valid {
			return refuse(parser, .Hash_Not_Valid, start, end, NO_NODE)
		}
		return node_add(parser, .Hash, start, end)
	case console_language.name_first(character):
		name := read_name(parser)
		if name == "let" {
			return let_read(parser, start)
		}
		if name == "if" {
			return if_read(parser, start)
		}
		if name == "true" || name == "false" {
			boolean := node_add(parser, .Boolean, start, start + len(name))
			if bool_node := node_at(parser.tree, boolean); bool_node != nil {
				bool_node.integer = name == "true" ? 1 : 0
			}
			return boolean
		}
		if word_of_lex(name) {
			return refuse(parser, .Word_As_Name, start, start + len(name), NO_NODE)
		}
		if accept(parser, '(') {
			node, allows_postfix = call_read(parser, name, start), true
		} else if peek(parser) == '{' {
			// Call on a record literal: `plan { ... }` is `plan({ ... })`.
			brace_start := parser.position
			parser.position += 1
			call := node_add(parser, .Call, start, start + len(name))
			if call != NO_NODE {
				child_append(parser.tree, call, literal_read(parser, brace_start))
			}
			node, allows_postfix = call, true
		} else {
			return node_add(parser, .Name, start, start + len(name))
		}
	case character == 0:
		return refuse(parser, .Line_Ends_Too_Soon, start, start, NO_NODE)
	case:
		return refuse(parser, .Unexpected, start, len(text), NO_NODE)
	}
	if !allows_postfix || refused(parser) {
		return node
	}
	return postfix_read(parser, node)
}

// postfix_read reads `.field` selections chained after a parenthesized
// expression, a record literal or a call: `({a = 1}).a`, `import("x.lex").y.z`.
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
		selected := node_add(parser, .Field_Select, token.start + 1, token.end)
		if selected == NO_NODE {
			return current
		}
		child_append(parser.tree, selected, current)
		current = selected
	}
	return current
}

// if_read reads `if <condition> then <then_expr> else <else_expr>`.
@(private)
if_read :: proc "contextless" (parser: ^Parser, start: int) -> Node_Index {
	node := node_add(parser, .If, start, start + len("if"))
	if node == NO_NODE {
		return NO_NODE
	}
	condition := expression_read(parser)
	child_append(parser.tree, node, condition)
	if refused(parser) {
		return node
	}
	then_end, has_then := word_ahead(parser, "then")
	if !has_then {
		skip_spaces(parser)
		child_append(parser.tree, node, refuse(parser, .If_Then_Missing, parser.position, parser.position, NO_NODE))
		return node
	}
	parser.position = then_end
	then_branch := expression_read(parser)
	child_append(parser.tree, node, then_branch)
	if refused(parser) {
		return node
	}
	else_end, has_else := word_ahead(parser, "else")
	if !has_else {
		skip_spaces(parser)
		child_append(parser.tree, node, refuse(parser, .If_Else_Missing, parser.position, parser.position, NO_NODE))
		return node
	}
	parser.position = else_end
	else_branch := expression_read(parser)
	child_append(parser.tree, node, else_branch)
	return node
}

// call_read reads the arguments of a call, after its "(". The form of each
// argument comes from the lookup of the caller.
@(private)
call_read :: proc "contextless" (parser: ^Parser, name: string, start: int) -> Node_Index {
	call := node_add(parser, .Call, start, start + len(name))
	if call == NO_NODE || accept(parser, ')') {
		return call
	}
	count := 0
	named_seen := false
	for {
		if count == ARGUMENT_CAPACITY {
			child_append(parser.tree, call, refuse(parser, .Too_Many_Arguments, parser.position, parser.position, NO_NODE))
			return call
		}
		argument: Node_Index
		switch form_of(parser.lookup, name, count) {
		case .Expression:
			// `name = value` names its parameter; after one, each argument
			// is named.
			if named_ahead(parser) {
				named_seen = true
				argument = named_argument_read(parser, call)
			} else if named_seen {
				skip_spaces(parser)
				argument = refuse(parser, .Positional_After_Named, parser.position, parser.position, NO_NODE)
			} else {
				argument = expression_read(parser)
			}
		case .Fact_Name:
			argument = fact_name_read(parser)
		case .Condition:
			argument = condition_read(parser)
		case .Field_Names:
			argument = field_names_read(parser)
		}
		child_append(parser.tree, call, argument)
		if refused(parser) {
			return call
		}
		count += 1
		if accept(parser, ')') {
			return call
		}
		if !accept(parser, ',') {
			child_append(parser.tree, call, refuse(parser, .Comma_Or_Close_Missing, parser.position, parser.position, NO_NODE))
			return call
		}
	}
}

// child_named gives the child of a parent of a kind whose bytes are a name,
// or NO_NODE: a field of a literal, a binding, a named argument given before.
@(private)
child_named :: proc "contextless" (tree: ^Syntax_Tree, parent: Node_Index, kind: Node_Kind, name: string) -> Node_Index {
	parent_node := node_at(tree, parent)
	if parent_node == nil {
		return NO_NODE
	}
	for child := parent_node.first_child; child != NO_NODE; child = next_of(tree, child) {
		if node_at(tree, child).kind == kind && node_text(tree, child) == name {
			return child
		}
	}
	return NO_NODE
}

// named_argument_read reads `name = value`, an argument of call, after
// named_ahead saw its name and its "=".
@(private)
named_argument_read :: proc "contextless" (parser: ^Parser, call: Node_Index) -> Node_Index {
	skip_spaces(parser)
	start := parser.position
	name := read_name(parser)
	if word_of_lex(name) {
		return refuse(parser, .Word_As_Name, start, start + len(name), NO_NODE)
	}
	if child_named(parser.tree, call, .Named_Argument, name) != NO_NODE {
		return refuse(parser, .Named_Argument_Twice, start, start + len(name), NO_NODE)
	}
	equal_accept(parser)
	named := node_add(parser, .Named_Argument, start, start + len(name))
	if named == NO_NODE {
		return NO_NODE
	}
	child_append(parser.tree, named, expression_read(parser))
	return named
}

// literal_read reads a record literal, after its "{": `name = value`, each
// name once, separated by ",", then "}". A fault is a child in its place,
// after the fields before it.
@(private)
literal_read :: proc "contextless" (parser: ^Parser, start: int) -> Node_Index {
	text := parser.tree.text
	literal := node_add(parser, .Record_Literal, start, start + 1)
	if literal == NO_NODE || accept(parser, '}') {
		return literal
	}
	for {
		skip_spaces(parser)
		field_start := parser.position
		if console_language.token_next(text, field_start, parser.multiline).kind != .Name {
			child_append(parser.tree, literal, refuse(parser, .Literal_Name_Missing, field_start, field_start, NO_NODE))
			return literal
		}
		name := read_name(parser)
		if word_of_lex(name) {
			child_append(parser.tree, literal, refuse(parser, .Word_As_Name, field_start, field_start + len(name), NO_NODE))
			return literal
		}
		if child_named(parser.tree, literal, .Literal_Field, name) != NO_NODE {
			child_append(parser.tree, literal, refuse(parser, .Literal_Field_Twice, field_start, field_start + len(name), NO_NODE))
			return literal
		}
		if !equal_accept(parser) {
			child_append(parser.tree, literal, refuse(parser, .Literal_Equal_Missing, parser.position, parser.position, NO_NODE))
			return literal
		}
		field := node_add(parser, .Literal_Field, field_start, field_start + len(name))
		child_append(parser.tree, literal, field)
		child_append(parser.tree, field, expression_read(parser))
		if refused(parser) || accept(parser, '}') {
			return literal
		}
		if !accept(parser, ',') {
			child_append(parser.tree, literal, refuse(parser, .Literal_Close_Missing, parser.position, parser.position, NO_NODE))
			return literal
		}
		if parser.trailing_commas && accept(parser, '}') {
			return literal
		}
	}
}

// let_read reads a let, after its word: its bindings `name = value`, each
// name once, separated by ",", then `in` and the body. Then it binds the
// names that its values and its body read.
@(private)
let_read :: proc "contextless" (parser: ^Parser, start: int) -> Node_Index {
	text := parser.tree.text
	let := node_add(parser, .Let, start, start + len("let"))
	if let == NO_NODE {
		return NO_NODE
	}
	for {
		skip_spaces(parser)
		name_start := parser.position
		if console_language.token_next(text, name_start, parser.multiline).kind != .Name {
			child_append(parser.tree, let, refuse(parser, .Let_Name_Missing, name_start, name_start, NO_NODE))
			return let
		}
		name := read_name(parser)
		if word_of_lex(name) {
			child_append(parser.tree, let, refuse(parser, .Word_As_Name, name_start, name_start + len(name), NO_NODE))
			return let
		}
		if child_named(parser.tree, let, .Let_Binding, name) != NO_NODE {
			child_append(parser.tree, let, refuse(parser, .Let_Name_Twice, name_start, name_start + len(name), NO_NODE))
			return let
		}
		if !equal_accept(parser) {
			child_append(parser.tree, let, refuse(parser, .Let_Equal_Missing, parser.position, parser.position, NO_NODE))
			return let
		}
		binding := node_add(parser, .Let_Binding, name_start, name_start + len(name))
		child_append(parser.tree, let, binding)
		child_append(parser.tree, binding, expression_read(parser))
		if refused(parser) {
			return let
		}
		if accept(parser, ',') {
			if parser.trailing_commas {
				if in_end, has_in := word_ahead(parser, "in"); has_in {
					parser.position = in_end
					child_append(parser.tree, let, expression_read(parser))
					for child := node_at(parser.tree, let).first_child; child != NO_NODE; child = next_of(parser.tree, child) {
						child_node := node_at(parser.tree, child)
						names_bind(parser.tree, let, .Let_Binding, child_node.kind == .Let_Binding ? child_node.first_child : child)
					}
					return let
				}
			}
			continue
		}
		end, found := word_ahead(parser, "in")
		if !found {
			child_append(parser.tree, let, refuse(parser, .Let_In_Missing, parser.position, parser.position, NO_NODE))
			return let
		}
		parser.position = end
		child_append(parser.tree, let, expression_read(parser))
		// After the whole let: a value can name a later binding, and an
		// inner let or function has bound its own names already.
		for child := node_at(parser.tree, let).first_child; child != NO_NODE; child = next_of(parser.tree, child) {
			child_node := node_at(parser.tree, child)
			names_bind(parser.tree, let, .Let_Binding, child_node.kind == .Let_Binding ? child_node.first_child : child)
		}
		return let
	}
}

// function_read reads a function, whose '(' is at open, its ')' at close
// and the byte after its "=>" at arrow_end (console_language.function_head):
// its parameters, each name once, then its body. Then it binds the names
// of its body to its parameters.
@(private)
function_read :: proc "contextless" (parser: ^Parser, open, close, arrow_end: int) -> Node_Index {
	tree := parser.tree
	text := tree.text
	function := node_add(parser, .Function, arrow_end - len("=>"), arrow_end)
	if function == NO_NODE {
		return NO_NODE
	}
	node_at(tree, function).integer = i64(open)
	outer := parser.function
	parser.function = function
	defer parser.function = outer
	parser.position = open + 1
	if !accept(parser, ')') {
		count := 0
		for {
			skip_spaces(parser)
			name_start := parser.position
			if count == ARGUMENT_CAPACITY {
				child_append(tree, function, refuse(parser, .Too_Many_Parameters, name_start, name_start, NO_NODE))
				return function
			}
			token := console_language.token_next(text, name_start, parser.multiline)
			if token.kind != .Name {
				child_append(tree, function, refuse(parser, .Parameter_Name_Missing, name_start, name_start, NO_NODE))
				return function
			}
			name := read_name(parser)
			if word_of_lex(name) {
				child_append(tree, function, refuse(parser, .Word_As_Name, name_start, name_start + len(name), NO_NODE))
				return function
			}
			// A name with a '.' reads a field: no parameter has one.
			for character in name {
				if character == '.' {
					child_append(tree, function, refuse(parser, .Parameter_Name_Missing, name_start, name_start + len(name), NO_NODE))
					return function
				}
			}
			if child_named(tree, function, .Parameter, name) != NO_NODE {
				child_append(tree, function, refuse(parser, .Parameter_Twice, name_start, name_start + len(name), NO_NODE))
				return function
			}
			child_append(tree, function, node_add(parser, .Parameter, name_start, name_start + len(name)))
			if refused(parser) {
				return function
			}
			count += 1
			if accept(parser, ')') {
				break
			}
			if !accept(parser, ',') {
				child_append(tree, function, refuse(parser, .Comma_Or_Close_Missing, parser.position, parser.position, NO_NODE))
				return function
			}
		}
	}
	// The ')' of the parameters is the one that function_head found.
	if parser.position != close + 1 {
		child_append(tree, function, refuse(parser, .Unexpected, parser.position, len(text), NO_NODE))
		return function
	}
	parser.position = arrow_end
	body := expression_read(parser)
	child_append(tree, function, body)
	names_bind(tree, function, .Parameter, body)
	return function
}

// list_read reads a list, after its "[": its items separated by ",", then
// "]". A fault is a child in its place, after the items before it.
@(private)
list_read :: proc "contextless" (parser: ^Parser, start: int) -> Node_Index {
	list := node_add(parser, .List_Literal, start, start + 1)
	if list == NO_NODE || accept(parser, ']') {
		return list
	}
	for {
		child_append(parser.tree, list, expression_read(parser))
		if refused(parser) || accept(parser, ']') {
			return list
		}
		if !accept(parser, ',') {
			child_append(parser.tree, list, refuse(parser, .List_Close_Missing, parser.position, parser.position, NO_NODE))
			return list
		}
		if parser.trailing_commas && accept(parser, ']') {
			return list
		}
	}
}

// names_bind gives each Name or Call of a subtree that nothing inner bound
// the child of owner of the kind binding_kind with its name before its first
// '.': a Let_Binding of a let, a Parameter of a function. A Call `gt.fn(...)`
// binds to `gt` when `gt` is in scope, so record fields holding functions
// can be called directly.
@(private)
names_bind :: proc "contextless" (tree: ^Syntax_Tree, owner: Node_Index, binding_kind: Node_Kind, index: Node_Index) {
	node := node_at(tree, index)
	if node == nil {
		return
	}
	if (node.kind == .Name || node.kind == .Call) && node.binding == NO_NODE {
		name := node_text(tree, index)
		head := name
		for character, place in name {
			if character == '.' {
				head = name[:place]
				break
			}
		}
		if head != "" {
			node.binding = child_named(tree, owner, binding_kind, head)
		}
	}
	for child := node.first_child; child != NO_NODE; child = next_of(tree, child) {
		names_bind(tree, owner, binding_kind, child)
	}
}

// fact_name_read reads the argument of a parameter of the form Fact_Name:
// a name, which the console checks against the fact names of its image.
@(private)
fact_name_read :: proc "contextless" (parser: ^Parser) -> Node_Index {
	skip_spaces(parser)
	start := parser.position
	name := read_name(parser)
	fact_name := node_add(parser, .Fact_Name, start, start + len(name))
	if len(name) == 0 {
		refusal_keep(parser, .Fact_Name_Missing, start)
		if node := node_at(parser.tree, fact_name); node != nil {
			node.refusal = .Fact_Name_Missing
		}
	}
	return fact_name
}

// field_names_read reads the argument of a parameter of the form
// Field_Names: one name or more, separated by commas, so it takes the
// commas that would end the argument. Each is a name of a field, never a
// variable: the console checks it against the record of its table. The
// bytes of the node run from the first name to the byte after the spaces
// that follow the last.
@(private)
field_names_read :: proc "contextless" (parser: ^Parser) -> Node_Index {
	skip_spaces(parser)
	start := parser.position
	field_names := node_add(parser, .Field_Names, start, start)
	node := node_at(parser.tree, field_names)
	if node == nil {
		return NO_NODE
	}
	for {
		name := read_name(parser)
		if len(name) == 0 {
			node.refusal = .Field_Name_Missing
			node.end = u32(parser.position)
			refusal_keep(parser, .Field_Name_Missing, parser.position)
			return field_names
		}
		if peek(parser) != ',' {
			break
		}
		parser.position += 1
	}
	node.end = u32(parser.position)
	return field_names
}

// condition_read reads the argument of a parameter of the form Condition:
// a field, an operator, and a value. The value is an expression; for a
// field that holds a status, the console reads its first token as the name
// of a member, and member_alone says if that token is the whole value.
@(private)
condition_read :: proc "contextless" (parser: ^Parser) -> Node_Index {
	text := parser.tree.text
	start := console_language.space_end(text, parser.position)
	head, head_refusal := console_condition.head_read(text, parser.position)
	condition := node_add(parser, .Condition, start, head_refusal == .None ? head.value_start : start)
	node := node_at(parser.tree, condition)
	if node == nil {
		return NO_NODE
	}
	node.condition_head, node.condition_refusal = head, head_refusal
	if head_refusal != .None {
		node.refusal = .Condition_Head_Refused
		refusal_keep(parser, .Condition_Head_Refused, start, u64(head_refusal))
		return condition
	}
	parser.position = head.value_start
	first := console_language.token_next(text, head.value_start)
	after := console_language.token_next(text, first.end)
	node.member_alone = after.kind == .Operator && (text[after.start] == ')' || text[after.start] == ',')
	child_append(parser.tree, condition, expression_read(parser))
	return condition
}
