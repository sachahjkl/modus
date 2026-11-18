package similarity

import "core:fmt"
import "core:hash/xxhash"
import "core:mem"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:strconv"
import "core:strings"

// The syntax of the similarity finder (src/md/infrastructure/similarity_finder.md):
// the tree of the parser, copied into one flat table of nodes in the
// normal form, with the two hashes of each node. The parser keeps no
// memory of a file after its copy.

// The kind of a node of the table: one for each kind of node of the
// parser that a source of the repository holds, and the name of an
// imported package that the normal form makes.
Similarity_Kind :: enum u8 {
	Bad,
	Ident,
	Implicit,
	Undef,
	Basic_Lit,
	Basic_Directive,
	Ellipsis,
	Proc_Lit,
	Comp_Lit,
	Tag_Expr,
	Unary_Expr,
	Binary_Expr,
	Selector_Expr,
	Implicit_Selector_Expr,
	Selector_Call_Expr,
	Index_Expr,
	Deref_Expr,
	Slice_Expr,
	Matrix_Index_Expr,
	Call_Expr,
	Field_Value,
	Ternary_If_Expr,
	Ternary_When_Expr,
	Or_Else_Expr,
	Or_Return_Expr,
	Or_Branch_Expr,
	Type_Assertion,
	Type_Cast,
	Auto_Cast,
	Proc_Group,
	Typeid_Type,
	Helper_Type,
	Distinct_Type,
	Poly_Type,
	Proc_Type,
	Pointer_Type,
	Multi_Pointer_Type,
	Array_Type,
	Dynamic_Array_Type,
	Fixed_Capacity_Dynamic_Array_Type,
	Struct_Type,
	Union_Type,
	Enum_Type,
	Bit_Set_Type,
	Map_Type,
	Relative_Type,
	Matrix_Type,
	Bit_Field_Type,
	Bit_Field_Field,
	Expr_Stmt,
	Tag_Stmt,
	Assign_Stmt,
	Block_Stmt,
	If_Stmt,
	When_Stmt,
	Return_Stmt,
	Defer_Stmt,
	For_Stmt,
	Range_Stmt,
	Unroll_Range_Stmt,
	Case_Clause,
	Switch_Stmt,
	Type_Switch_Stmt,
	Branch_Stmt,
	Using_Stmt,
	Value_Decl,
	Attribute,
	Field,
	Field_List,
	Asm_Template,
	Asm_Spec,
	Asm_Register,
	Asm_Clobber,
	Asm_Label,
	Asm_Label_Decl,
	Asm_Instruction,
	Asm_Memory_Operand,
	Asm_Register_Group,
	Asm_Directive,
	Qualified_Name, // A name of an imported package: the import path, a period and the name.
}

// The place of a node in its parent: it decides how a blank at that place
// is passed to a factored procedure.
Similarity_Role :: enum u8 {
	Value, // An expression that is read.
	Place, // An expression that is assigned or addressed.
	Type, // A type expression, a conversion to a type.
	Called, // The name of a called procedure.
	Field, // The name of a field.
	Declared, // A name that a declaration gives.
	Label, // The label of a statement.
	Statement, // A statement.
	Structure, // A part of the syntax that is none of these: a field list, an attribute.
}

Similarity_Literal :: enum u8 {
	None,
	Integer,
	Float,
	Imaginary,
	Rune,
	String,
}

// The rules of the normal form (src/md/infrastructure/similarity_finder.md,
// "3. The normal form").
Similarity_Rule :: enum u8 {
	Parentheses,
	Comparison_Direction,
	Negated_Equality,
	Double_Negation,
	Operator_Assignment,
	Operand_Order,
	Counted_Loop,
	Negated_Condition,
	Boolean_Return,
	Integer_Arithmetic,
}
Similarity_Rules :: bit_set[Similarity_Rule;u16]

Similarity_Flag :: enum u8 {
	Impure, // The subtree holds a call that is not a pure built-in or a conversion, or an assignment.
	Holds_Using, // The subtree holds a `using`: a name in it can be a field.
}
Similarity_Flags :: bit_set[Similarity_Flag;u8]

// One node of the flat table. The subtree of a node is the interval
// [index, index + size) of the table.
Similarity_Node :: struct {
	exact_hash:   u64, // A local is its binding number, a literal its value, a type its name.
	shape_hash:   u64, // A local is "a local", a literal its kind, the name of a type "a type".
	label:        string, // The operator, the name, the text of the literal, or the forms that the node holds.
	parent:       i32,
	first_child:  i32,
	next_sibling: i32,
	size:         i32, // The nodes of the subtree, this node too.
	child_count:  i32,
	procedure:    i32, // The procedure literal that holds the node, or -1.
	file:         i32,
	start:        i32, // The byte offset of the first byte in the file.
	end:          i32, // The byte offset after the last byte.
	first_line:   i32,
	last_line:    i32,
	local:        i32, // The binding number of a local in its procedure, or -1.
	kind:         Similarity_Kind,
	role:         Similarity_Role,
	literal:      Similarity_Literal,
	flags:        Similarity_Flags,
	rules:        Similarity_Rules, // The rules of the normal form that made this node.
}

@(private = "file")
Similarity_Open_Node :: struct {
	node:       i32,
	last_child: i32,
}

// The state of the copy of the trees of the parser into the table.
Similarity_Builder :: struct {
	nodes:         [dynamic]Similarity_Node,
	file:          i32,
	imports:       map[string]string, // The import name of the file being copied, and its import path.
	package_types: map[string]bool, // The names of the types that the package of the file declares at its top level.
	scopes:        [dynamic]map[string]i32, // The names of the locals of each scope of the procedure being copied.
	binding_count: i32,
	procedure:     i32,
	case_role:     Similarity_Role, // The role of the expressions of a case: a type in a type switch.
	open:          [dynamic]Similarity_Open_Node,
	hash_bytes:    [dynamic]u8,
	allocator:     mem.Allocator, // The allocator of the table and of the labels that the normal form writes.
}

similarity_builder_make :: proc(allocator: mem.Allocator) -> Similarity_Builder {
	return Similarity_Builder {
		nodes = make([dynamic]Similarity_Node, allocator),
		open = make([dynamic]Similarity_Open_Node, allocator),
		hash_bytes = make([dynamic]u8, allocator),
		procedure = -1,
		allocator = allocator,
	}
}

similarity_kind_is_statement :: proc(kind: Similarity_Kind) -> bool {
	#partial switch kind {
	case .Expr_Stmt, .Tag_Stmt, .Assign_Stmt, .Block_Stmt, .If_Stmt, .When_Stmt, .Return_Stmt, .Defer_Stmt, .For_Stmt, .Range_Stmt, .Unroll_Range_Stmt, .Case_Clause, .Switch_Stmt, .Type_Switch_Stmt, .Branch_Stmt, .Using_Stmt, .Value_Decl, .Asm_Spec, .Asm_Clobber, .Asm_Label_Decl, .Asm_Instruction, .Asm_Directive:
		return true
	}
	return false
}

similarity_kind_is_type :: proc(kind: Similarity_Kind) -> bool {
	#partial switch kind {
	case .Typeid_Type, .Helper_Type, .Distinct_Type, .Poly_Type, .Proc_Type, .Pointer_Type, .Multi_Pointer_Type, .Array_Type, .Dynamic_Array_Type, .Fixed_Capacity_Dynamic_Array_Type, .Struct_Type, .Union_Type, .Enum_Type, .Bit_Set_Type, .Map_Type, .Relative_Type, .Matrix_Type, .Bit_Field_Type:
		return true
	}
	return false
}

// A node whose children are a list of any length: the anti-unification
// aligns two such lists before it compares their children.
similarity_kind_has_list :: proc(kind: Similarity_Kind) -> bool {
	#partial switch kind {
	case .Block_Stmt, .Case_Clause, .Comp_Lit, .Field_List, .Enum_Type, .Union_Type, .Bit_Field_Type, .Proc_Group, .Attribute:
		return true
	}
	return false
}

similarity_rule_name :: proc(rule: Similarity_Rule) -> string {
	switch rule {
	case .Parentheses:
		return "parentheses"
	case .Comparison_Direction:
		return "direction of a comparison"
	case .Negated_Equality:
		return "negated equality"
	case .Double_Negation:
		return "double negation"
	case .Operator_Assignment:
		return "assignment with an operator"
	case .Operand_Order:
		return "order of the operands"
	case .Counted_Loop:
		return "counted loop"
	case .Negated_Condition:
		return "negated condition"
	case .Boolean_Return:
		return "boolean return"
	case .Integer_Arithmetic:
		return "arithmetic of integer literals"
	}
	return ""
}

@(private = "file")
similarity_begin :: proc(b: ^Similarity_Builder, kind: Similarity_Kind, role: Similarity_Role, label: string, start, end: tokenizer.Pos) -> i32 {
	index := i32(len(b.nodes))
	parent: i32 = -1
	if len(b.open) > 0 {
		top := &b.open[len(b.open) - 1]
		parent = top.node
		if top.last_child < 0 {
			b.nodes[parent].first_child = index
		} else {
			b.nodes[top.last_child].next_sibling = index
		}
		top.last_child = index
		b.nodes[parent].child_count += 1
	}
	last := end.offset > start.offset ? end : start
	append(&b.nodes, Similarity_Node{label = label, parent = parent, first_child = -1, next_sibling = -1, procedure = b.procedure, file = b.file, start = i32(start.offset), end = i32(last.offset), first_line = i32(start.line), last_line = i32(max(last.line, start.line)), local = -1, kind = kind, role = role})
	append(&b.open, Similarity_Open_Node{node = index, last_child = -1})
	return index
}

// similarity_end closes the open node: its size, what its children hold,
// the order of the operands of a commutative operator, and its two hashes.
// Its children are closed, so the hashes go from the leaves up.
@(private = "file")
similarity_end :: proc(b: ^Similarity_Builder) {
	open := pop(&b.open)
	index := open.node
	b.nodes[index].size = i32(len(b.nodes)) - index
	child := b.nodes[index].first_child
	for child >= 0 {
		b.nodes[index].flags += b.nodes[child].flags & {.Impure, .Holds_Using}
		child = b.nodes[child].next_sibling
	}
	similarity_order_operands(b, index)
	similarity_node_hashes(b, index)
}

// The five operators that are commutative for each type that Odin gives
// them. `+` and `*` are not among them: a matrix, a quaternion and two
// constant strings.
@(private = "file")
similarity_operator_is_commutative :: proc(operator: string) -> bool {
	switch operator {
	case "==", "!=", "&", "|", "~":
		return true
	}
	return false
}

@(private = "file")
similarity_order_operands :: proc(b: ^Similarity_Builder, index: i32) {
	node := &b.nodes[index]
	if node.kind != .Binary_Expr || node.child_count != 2 || !similarity_operator_is_commutative(node.label) {
		return
	}
	left := node.first_child
	right := b.nodes[left].next_sibling
	if .Impure in b.nodes[left].flags || .Impure in b.nodes[right].flags {
		return
	}
	left_node := b.nodes[left]
	right_node := b.nodes[right]
	if left_node.shape_hash < right_node.shape_hash || (left_node.shape_hash == right_node.shape_hash && left_node.exact_hash <= right_node.exact_hash) {
		return
	}
	node.first_child = right
	b.nodes[right].next_sibling = left
	b.nodes[left].next_sibling = -1
	node.rules += {.Operand_Order}
}

@(private = "file")
similarity_hash_write_u64 :: proc(bytes: ^[dynamic]u8, value: u64) {
	parts := transmute([8]u8)value
	append(bytes, ..parts[:])
}

// The label of a node in the shape hash: a local, a literal and the name
// of a type lose their value.
similarity_shape_label :: proc(node: Similarity_Node) -> string {
	switch {
	case node.local >= 0:
		return "local"
	case node.literal != .None:
		return ""
	case node.role == .Type && (node.kind == .Ident || node.kind == .Qualified_Name):
		return "type"
	}
	return node.label
}

@(private = "file")
similarity_node_hashes :: proc(b: ^Similarity_Builder, index: i32) {
	b.nodes[index].exact_hash = similarity_node_hash(b, index, true)
	b.nodes[index].shape_hash = similarity_node_hash(b, index, false)
}

@(private = "file")
similarity_node_hash :: proc(b: ^Similarity_Builder, index: i32, exact: bool) -> u64 {
	node := b.nodes[index]
	clear(&b.hash_bytes)
	append(&b.hash_bytes, u8(node.kind), u8(node.role), u8(node.literal))
	if exact {
		if node.local >= 0 {
			similarity_hash_write_u64(&b.hash_bytes, u64(node.local))
		} else {
			append(&b.hash_bytes, node.label)
		}
	} else {
		append(&b.hash_bytes, similarity_shape_label(node))
	}
	append(&b.hash_bytes, 0)
	child := node.first_child
	for child >= 0 {
		similarity_hash_write_u64(&b.hash_bytes, exact ? b.nodes[child].exact_hash : b.nodes[child].shape_hash)
		child = b.nodes[child].next_sibling
	}
	return xxhash.XXH3_64_default(b.hash_bytes[:])
}

@(private = "file")
similarity_leaf :: proc(b: ^Similarity_Builder, kind: Similarity_Kind, role: Similarity_Role, label: string, node: ^ast.Node) {
	similarity_begin(b, kind, role, label, node.pos, node.end)
	similarity_end(b)
}

@(private = "file")
similarity_scope_push :: proc(b: ^Similarity_Builder) {
	if b.procedure >= 0 {
		append(&b.scopes, make(map[string]i32))
	}
}

@(private = "file")
similarity_scope_pop :: proc(b: ^Similarity_Builder) {
	if b.procedure >= 0 && len(b.scopes) > 0 {
		pop(&b.scopes)
	}
}

similarity_local_lookup :: proc(b: ^Similarity_Builder, name: string) -> (number: i32, found: bool) {
	if b.procedure < 0 {
		return -1, false
	}
	for scope_index := len(b.scopes) - 1; scope_index >= 0; scope_index -= 1 {
		if value, present := b.scopes[scope_index][name]; present {
			return value, true
		}
	}
	return -1, false
}

similarity_is_builtin_type_name :: proc(name: string) -> bool {
	switch name {
	case "bool", "b8", "b16", "b32", "b64", "int", "i8", "i16", "i32", "i64", "i128", "uint", "u8", "u16", "u32", "u64", "u128", "uintptr", "i16le", "i32le", "i64le", "i128le", "u16le", "u32le", "u64le", "u128le", "i16be", "i32be", "i64be", "i128be", "u16be", "u32be", "u64be", "u128be", "f16", "f32", "f64", "f16le", "f32le", "f64le", "f16be", "f32be", "f64be", "complex32", "complex64", "complex128", "quaternion64", "quaternion128", "quaternion256", "rune", "string", "cstring", "string16", "cstring16", "rawptr", "typeid", "any":
		return true
	}
	return false
}

// The built-in procedures that only read: a call of one is pure.
@(private = "file")
similarity_is_pure_builtin :: proc(name: string) -> bool {
	switch name {
	case "len", "cap", "size_of", "align_of", "offset_of", "min", "max", "abs":
		return true
	}
	return false
}

// similarity_expression_is_type says when the syntax shows that an
// expression is a type: a built-in type, a type that the package declares
// at its top level, or a type expression. A type of another package reads
// as a name of that package.
@(private = "file")
similarity_expression_is_type :: proc(b: ^Similarity_Builder, expression: ^ast.Expr) -> bool {
	if expression == nil {
		return false
	}
	#partial switch e in expression.derived {
	case ^ast.Ident:
		if _, is_local := similarity_local_lookup(b, e.name); is_local {
			return false
		}
		return similarity_is_builtin_type_name(e.name) || e.name in b.package_types
	case ^ast.Paren_Expr:
		return similarity_expression_is_type(b, e.expr)
	case ^ast.Pointer_Type, ^ast.Multi_Pointer_Type, ^ast.Array_Type, ^ast.Dynamic_Array_Type, ^ast.Map_Type, ^ast.Distinct_Type, ^ast.Proc_Type, ^ast.Struct_Type, ^ast.Union_Type, ^ast.Enum_Type, ^ast.Typeid_Type, ^ast.Bit_Set_Type, ^ast.Matrix_Type, ^ast.Helper_Type, ^ast.Bit_Field_Type:
		return true
	}
	return false
}

// similarity_expression_is_pure says that an expression holds no call
// other than a pure built-in or a conversion, so the order of its
// evaluation does not change what it gives.
similarity_expression_is_pure :: proc(b: ^Similarity_Builder, expression: ^ast.Expr) -> bool {
	if expression == nil {
		return true
	}
	#partial switch e in expression.derived {
	case ^ast.Ident, ^ast.Basic_Lit, ^ast.Implicit_Selector_Expr, ^ast.Basic_Directive:
		return true
	case ^ast.Paren_Expr:
		return similarity_expression_is_pure(b, e.expr)
	case ^ast.Unary_Expr:
		return similarity_expression_is_pure(b, e.expr)
	case ^ast.Binary_Expr:
		return similarity_expression_is_pure(b, e.left) && similarity_expression_is_pure(b, e.right)
	case ^ast.Selector_Expr:
		return similarity_expression_is_pure(b, e.expr)
	case ^ast.Index_Expr:
		return similarity_expression_is_pure(b, e.expr) && similarity_expression_is_pure(b, e.index)
	case ^ast.Deref_Expr:
		return similarity_expression_is_pure(b, e.expr)
	case ^ast.Call_Expr:
		if !similarity_expression_is_type(b, e.expr) {
			callee, is_name := e.expr.derived.(^ast.Ident)
			if !is_name || !similarity_is_pure_builtin(callee.name) {
				return false
			}
			if _, is_local := similarity_local_lookup(b, callee.name); is_local {
				return false
			}
		}
		for argument in e.args {
			if !similarity_expression_is_pure(b, argument) {
				return false
			}
		}
		return true
	}
	return false
}

// A pure place: a local, or a field, an index or a dereference of a pure
// place, with a pure index.
@(private = "file")
similarity_expression_is_pure_place :: proc(b: ^Similarity_Builder, expression: ^ast.Expr) -> bool {
	if expression == nil {
		return false
	}
	#partial switch e in expression.derived {
	case ^ast.Ident:
		_, is_local := similarity_local_lookup(b, e.name)
		return is_local
	case ^ast.Paren_Expr:
		return similarity_expression_is_pure_place(b, e.expr)
	case ^ast.Selector_Expr:
		return similarity_expression_is_pure_place(b, e.expr)
	case ^ast.Index_Expr:
		return similarity_expression_is_pure_place(b, e.expr) && similarity_expression_is_pure(b, e.index)
	case ^ast.Deref_Expr:
		return similarity_expression_is_pure_place(b, e.expr)
	}
	return false
}

// similarity_integer_value gives the value of an expression of integer
// literals with + - * << and parentheses. Odin computes such a constant
// with no overflow; a shift of 120 bits or more is not computed here.
@(private = "file")
similarity_integer_value :: proc(expression: ^ast.Expr) -> (value: i128, ok: bool) {
	if expression == nil {
		return 0, false
	}
	#partial switch e in expression.derived {
	case ^ast.Basic_Lit:
		if e.tok.kind != .Integer {
			return 0, false
		}
		return strconv.parse_i128_maybe_prefixed(e.tok.text)
	case ^ast.Paren_Expr:
		return similarity_integer_value(e.expr)
	case ^ast.Unary_Expr:
		if e.op.kind != .Sub {
			return 0, false
		}
		inner := similarity_integer_value(e.expr) or_return
		return -inner, true
	case ^ast.Binary_Expr:
		left := similarity_integer_value(e.left) or_return
		right := similarity_integer_value(e.right) or_return
		#partial switch e.op.kind {
		case .Add:
			return left + right, true
		case .Sub:
			return left - right, true
		case .Mul:
			return left * right, true
		case .Shl:
			if right < 0 || right >= 120 {
				return 0, false
			}
			return left << u128(right), true
		}
	}
	return 0, false
}

@(private = "file")
similarity_literal_kind :: proc(kind: tokenizer.Token_Kind) -> Similarity_Literal {
	#partial switch kind {
	case .Integer:
		return .Integer
	case .Float:
		return .Float
	case .Imag:
		return .Imaginary
	case .Rune:
		return .Rune
	case .String:
		return .String
	}
	return .None
}

// The text of a number with no `_`: 4_096 and 4096 are one value.
@(private = "file")
similarity_literal_label :: proc(b: ^Similarity_Builder, token: tokenizer.Token) -> string {
	if (token.kind == .Integer || token.kind == .Float || token.kind == .Imag) && strings.contains_rune(token.text, '_') {
		text, _ := strings.remove_all(token.text, "_", b.allocator)
		return text
	}
	return token.text
}

@(private = "file")
similarity_presence :: proc(b: ^Similarity_Builder, parts: ..string) -> string {
	return strings.concatenate(parts, b.allocator)
}

@(private = "file")
similarity_inlining_label :: proc(inlining: ast.Proc_Inlining) -> string {
	switch inlining {
	case .None:
		return ""
	case .Inline:
		return "#force_inline "
	case .No_Inline:
		return "#force_no_inline "
	}
	return ""
}

@(private = "file")
similarity_field_flags_label :: proc(b: ^Similarity_Builder, flags: ast.Field_Flags) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	for flag in ast.Field_Flag {
		if flag in flags {
			append(&parts, ast.field_flag_strings[flag])
		}
	}
	return strings.join(parts[:], " ", b.allocator)
}

// similarity_flatten_identifier writes one name. A name that a
// declaration gives in a procedure becomes a new local; a name that is
// read becomes the local that it names, else it stays a global by its name.
@(private = "file")
similarity_flatten_identifier :: proc(b: ^Similarity_Builder, identifier: ^ast.Ident, role: Similarity_Role, declares: bool) {
	index := similarity_begin(b, .Ident, role, identifier.name, identifier.pos, identifier.end)
	switch {
	case role == .Field:
	case declares:
		if b.procedure >= 0 && identifier.name != "_" && len(b.scopes) > 0 {
			number := b.binding_count
			b.binding_count += 1
			b.scopes[len(b.scopes) - 1][identifier.name] = number
			b.nodes[index].local = number
			b.nodes[index].label = ""
		}
	case:
		if number, found := similarity_local_lookup(b, identifier.name); found {
			b.nodes[index].local = number
			b.nodes[index].label = ""
		}
	}
	similarity_end(b)
}

// A name that a declaration gives: an identifier, `&x` of a loop, or a
// polymorphic name.
@(private = "file")
similarity_flatten_declared :: proc(b: ^Similarity_Builder, expression: ^ast.Expr, role: Similarity_Role) {
	if expression == nil {
		return
	}
	#partial switch e in expression.derived {
	case ^ast.Ident:
		similarity_flatten_identifier(b, e, role, true)
	case ^ast.Unary_Expr:
		similarity_begin(b, .Unary_Expr, role, e.op.text, e.pos, e.end)
		similarity_flatten_declared(b, e.expr, role)
		similarity_end(b)
	case ^ast.Poly_Type:
		similarity_begin(b, .Poly_Type, .Type, "$", e.pos, e.end)
		if e.type != nil {
			similarity_flatten_identifier(b, e.type, .Declared, true)
		}
		similarity_flatten(b, e.specialization, .Type)
		similarity_end(b)
	case:
		similarity_flatten(b, expression, role)
	}
}

@(private = "file")
similarity_flatten_list :: proc(b: ^Similarity_Builder, list: []^ast.Expr, role: Similarity_Role) {
	for item in list {
		similarity_flatten(b, item, role)
	}
}

// similarity_flatten_procedure writes a procedure literal: its locals are
// counted from its start, in a scope of their own.
@(private = "file")
similarity_flatten_procedure :: proc(b: ^Similarity_Builder, literal: ^ast.Proc_Lit, role: Similarity_Role) {
	saved_procedure := b.procedure
	saved_scopes := b.scopes
	saved_binding_count := b.binding_count
	index := similarity_begin(b, .Proc_Lit, role, similarity_presence(b, similarity_inlining_label(literal.inlining), literal.body == nil ? "foreign" : ""), literal.pos, literal.end)
	b.procedure = index
	b.scopes = make([dynamic]map[string]i32)
	append(&b.scopes, make(map[string]i32))
	b.binding_count = 0
	if literal.type != nil {
		similarity_flatten_procedure_type(b, literal.type, .Type, true)
	}
	similarity_flatten(b, literal.body, .Statement)
	similarity_flatten_list(b, literal.where_clauses, .Value)
	b.procedure = saved_procedure
	b.scopes = saved_scopes
	b.binding_count = saved_binding_count
	similarity_end(b)
}

@(private = "file")
similarity_flatten_procedure_type :: proc(b: ^Similarity_Builder, type: ^ast.Proc_Type, role: Similarity_Role, declares: bool) {
	convention := ""
	if name, is_name := type.calling_convention.(string); is_name {
		convention = name
	}
	similarity_begin(b, .Proc_Type, role, similarity_presence(b, convention, type.diverging ? " -> !" : "", type.results != nil ? " results" : ""), type.pos, type.end)
	similarity_flatten_field_list(b, type.params, declares)
	similarity_flatten_field_list(b, type.results, declares)
	similarity_end(b)
}

@(private = "file")
similarity_flatten_field_list :: proc(b: ^Similarity_Builder, list: ^ast.Field_List, declares: bool) {
	if list == nil {
		return
	}
	similarity_begin(b, .Field_List, .Structure, "", list.pos, list.end)
	for field in list.list {
		similarity_begin(b, .Field, .Structure, similarity_presence(b, similarity_field_flags_label(b, field.flags), field.type != nil ? " typed" : "", field.default_value != nil ? " default" : ""), field.pos, field.end)
		for name in field.names {
			if declares {
				similarity_flatten_declared(b, name, .Declared)
			} else if identifier, is_name := name.derived.(^ast.Ident); is_name {
				similarity_flatten_identifier(b, identifier, .Field, false)
			} else {
				similarity_flatten(b, name, .Field)
			}
		}
		similarity_flatten(b, field.type, .Type)
		similarity_flatten(b, field.default_value, .Value)
		similarity_end(b)
	}
	similarity_end(b)
}

// A condition that the syntax shows to be a boolean: a comparison, a
// negation, a logical operator.
@(private = "file")
similarity_expression_is_boolean :: proc(expression: ^ast.Expr) -> bool {
	inner := ast.unparen_expr(expression)
	if inner == nil {
		return false
	}
	#partial switch e in inner.derived {
	case ^ast.Binary_Expr:
		#partial switch e.op.kind {
		case .Cmp_Eq, .Not_Eq, .Lt, .Gt, .Lt_Eq, .Gt_Eq, .Cmp_And, .Cmp_Or, .In, .Not_In:
			return true
		}
	case ^ast.Unary_Expr:
		return e.op.kind == .Not
	}
	return false
}

// A block or a statement that is only `return <word>`.
@(private = "file")
similarity_returns_word :: proc(statement: ^ast.Stmt, word: string) -> bool {
	if statement == nil {
		return false
	}
	target := statement
	if block, is_block := statement.derived.(^ast.Block_Stmt); is_block {
		if len(block.stmts) != 1 || block.label != nil {
			return false
		}
		target = block.stmts[0]
	}
	result, is_return := target.derived.(^ast.Return_Stmt)
	if !is_return || len(result.results) != 1 {
		return false
	}
	name, is_name := ast.unparen_expr(result.results[0]).derived.(^ast.Ident)
	return is_name && name.name == word
}

// `if c { return true }` with no init, no label and no else, where c is
// a boolean.
@(private = "file")
similarity_boolean_return_if :: proc(statement: ^ast.Stmt) -> (if_statement: ^ast.If_Stmt, ok: bool) {
	if statement == nil {
		return nil, false
	}
	if_statement, ok = statement.derived.(^ast.If_Stmt)
	if !ok || if_statement.init != nil || if_statement.label != nil || !similarity_expression_is_boolean(if_statement.cond) {
		return nil, false
	}
	if !similarity_returns_word(if_statement.body, "true") {
		return nil, false
	}
	return if_statement, true
}

@(private = "file")
similarity_flatten_boolean_return :: proc(b: ^Similarity_Builder, condition: ^ast.Expr, start, end: tokenizer.Pos) {
	index := similarity_begin(b, .Return_Stmt, .Statement, "return", start, end)
	b.nodes[index].rules += {.Boolean_Return}
	similarity_flatten(b, condition, .Value)
	similarity_end(b)
}

@(private = "file")
similarity_flatten_statements :: proc(b: ^Similarity_Builder, statements: []^ast.Stmt) {
	for index := 0; index < len(statements); index += 1 {
		statement := statements[index]
		if index + 1 < len(statements) {
			if if_statement, is_boolean_return := similarity_boolean_return_if(statement); is_boolean_return && if_statement.else_stmt == nil && similarity_returns_word(statements[index + 1], "false") {
				similarity_flatten_boolean_return(b, if_statement.cond, if_statement.pos, statements[index + 1].end)
				index += 1
				continue
			}
		}
		similarity_flatten(b, statement, .Statement)
	}
}

@(private = "file")
Similarity_Assignment_Search :: struct {
	name:  string,
	found: bool,
}

// similarity_body_assigns says when a body assigns a value to a name or
// takes its address.
@(private = "file")
similarity_body_assigns :: proc(body: ^ast.Stmt, name: string) -> bool {
	search := Similarity_Assignment_Search{name = name}
	visitor := ast.Visitor {
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil {
				return nil
			}
			state := (^Similarity_Assignment_Search)(visitor.data)
			#partial switch n in node.derived {
			case ^ast.Assign_Stmt:
				for target in n.lhs {
					if identifier, is_name := ast.unparen_expr(target).derived.(^ast.Ident); is_name && identifier.name == state.name {
						state.found = true
					}
				}
			case ^ast.Unary_Expr:
				if n.op.kind == .And && n.expr != nil {
					if identifier, is_name := ast.unparen_expr(n.expr).derived.(^ast.Ident); is_name && identifier.name == state.name {
						state.found = true
					}
				}
			}
			return visitor
		},
		data = &search,
	}
	ast.walk(&visitor, body)
	return search.found
}

// `for i := a; i < b; i += 1 { body }` with a body that assigns no value
// to i.
@(private = "file")
similarity_counted_loop :: proc(loop: ^ast.For_Stmt) -> (name: ^ast.Ident, low, high: ^ast.Expr, ok: bool) {
	if loop.init == nil || loop.cond == nil || loop.post == nil || loop.body == nil {
		return
	}
	declaration, is_declaration := loop.init.derived.(^ast.Value_Decl)
	if !is_declaration || !declaration.is_mutable || declaration.type != nil || len(declaration.names) != 1 || len(declaration.values) != 1 {
		return
	}
	variable, is_name := declaration.names[0].derived.(^ast.Ident)
	if !is_name {
		return
	}
	condition, is_binary := ast.unparen_expr(loop.cond).derived.(^ast.Binary_Expr)
	if !is_binary || condition.op.kind != .Lt {
		return
	}
	compared, compares_name := ast.unparen_expr(condition.left).derived.(^ast.Ident)
	if !compares_name || compared.name != variable.name {
		return
	}
	step, is_assignment := loop.post.derived.(^ast.Assign_Stmt)
	if !is_assignment || step.op.kind != .Add_Eq || len(step.lhs) != 1 || len(step.rhs) != 1 {
		return
	}
	stepped, steps_name := ast.unparen_expr(step.lhs[0]).derived.(^ast.Ident)
	one, is_literal := ast.unparen_expr(step.rhs[0]).derived.(^ast.Basic_Lit)
	if !steps_name || stepped.name != variable.name || !is_literal || one.tok.kind != .Integer || one.tok.text != "1" {
		return
	}
	if similarity_body_assigns(loop.body, variable.name) {
		return
	}
	return variable, declaration.values[0], condition.right, true
}

// similarity_flatten writes one node of the parser and its subtree into
// the table, in the normal form.
similarity_flatten :: proc(b: ^Similarity_Builder, node: ^ast.Node, role: Similarity_Role) {
	if node == nil {
		return
	}
	#partial switch n in node.derived {
	case ^ast.Comment_Group, ^ast.Package_Decl, ^ast.Import_Decl, ^ast.Foreign_Import_Decl, ^ast.Foreign_Block_Decl, ^ast.Empty_Stmt, ^ast.Package, ^ast.File:
		return
	case ^ast.Ident:
		similarity_flatten_identifier(b, n, role, false)
	case ^ast.Implicit:
		similarity_leaf(b, .Implicit, role, n.tok.text, node)
	case ^ast.Undef:
		similarity_leaf(b, .Undef, role, "---", node)
	case ^ast.Basic_Lit:
		index := similarity_begin(b, .Basic_Lit, role, similarity_literal_label(b, n.tok), n.pos, n.end)
		b.nodes[index].literal = similarity_literal_kind(n.tok.kind)
		similarity_end(b)
	case ^ast.Basic_Directive:
		similarity_leaf(b, .Basic_Directive, role, similarity_presence(b, "#", n.name), node)
	case ^ast.Ellipsis:
		similarity_begin(b, .Ellipsis, role, "..", n.pos, n.end)
		similarity_flatten(b, n.expr, .Value)
		similarity_end(b)
	case ^ast.Proc_Lit:
		similarity_flatten_procedure(b, n, role)
	case ^ast.Comp_Lit:
		similarity_begin(b, .Comp_Lit, role, n.type != nil ? "typed" : "", n.pos, n.end)
		similarity_flatten(b, n.type, .Type)
		similarity_flatten_list(b, n.elems, .Value)
		similarity_end(b)
	case ^ast.Tag_Expr:
		similarity_begin(b, .Tag_Expr, role, similarity_presence(b, "#", n.name), n.pos, n.end)
		similarity_flatten(b, n.expr, .Value)
		similarity_end(b)
	case ^ast.Unary_Expr:
		similarity_flatten_unary(b, n, role)
	case ^ast.Binary_Expr:
		similarity_flatten_binary(b, n, role)
	case ^ast.Paren_Expr:
		before := len(b.nodes)
		similarity_flatten(b, n.expr, role)
		if len(b.nodes) > before {
			b.nodes[before].rules += {.Parentheses}
		}
	case ^ast.Selector_Expr:
		similarity_flatten_selector(b, n, role)
	case ^ast.Implicit_Selector_Expr:
		similarity_leaf(b, .Implicit_Selector_Expr, role, similarity_presence(b, ".", n.field.name), node)
	case ^ast.Selector_Call_Expr:
		index := similarity_begin(b, .Selector_Call_Expr, role, "->", n.pos, n.end)
		b.nodes[index].flags += {.Impure}
		similarity_flatten(b, n.expr, .Value)
		similarity_flatten(b, n.call, .Value)
		similarity_end(b)
	case ^ast.Index_Expr:
		similarity_begin(b, .Index_Expr, role, "[]", n.pos, n.end)
		similarity_flatten(b, n.expr, role == .Place ? .Place : .Value)
		similarity_flatten(b, n.index, .Value)
		similarity_end(b)
	case ^ast.Deref_Expr:
		similarity_begin(b, .Deref_Expr, role, "^", n.pos, n.end)
		similarity_flatten(b, n.expr, .Value)
		similarity_end(b)
	case ^ast.Slice_Expr:
		similarity_begin(b, .Slice_Expr, role, similarity_presence(b, "[", n.low != nil ? "low" : "", ":", n.high != nil ? "high" : "", "]"), n.pos, n.end)
		similarity_flatten(b, n.expr, role == .Place ? .Place : .Value)
		similarity_flatten(b, n.low, .Value)
		similarity_flatten(b, n.high, .Value)
		similarity_end(b)
	case ^ast.Matrix_Index_Expr:
		similarity_begin(b, .Matrix_Index_Expr, role, "[,]", n.pos, n.end)
		similarity_flatten(b, n.expr, role == .Place ? .Place : .Value)
		similarity_flatten(b, n.row_index, .Value)
		similarity_flatten(b, n.column_index, .Value)
		similarity_end(b)
	case ^ast.Call_Expr:
		similarity_flatten_call(b, n, role)
	case ^ast.Field_Value:
		similarity_begin(b, .Field_Value, role, "=", n.pos, n.end)
		if identifier, is_name := n.field.derived.(^ast.Ident); is_name {
			similarity_flatten_identifier(b, identifier, .Field, false)
		} else {
			similarity_flatten(b, n.field, .Value)
		}
		similarity_flatten(b, n.value, role == .Place ? .Place : .Value)
		similarity_end(b)
	case ^ast.Ternary_If_Expr:
		similarity_begin(b, .Ternary_If_Expr, role, "if else", n.pos, n.end)
		similarity_flatten(b, n.x, .Value)
		similarity_flatten(b, n.cond, .Value)
		similarity_flatten(b, n.y, .Value)
		similarity_end(b)
	case ^ast.Ternary_When_Expr:
		similarity_begin(b, .Ternary_When_Expr, role, "when else", n.pos, n.end)
		similarity_flatten(b, n.x, .Value)
		similarity_flatten(b, n.cond, .Value)
		similarity_flatten(b, n.y, .Value)
		similarity_end(b)
	case ^ast.Or_Else_Expr:
		similarity_begin(b, .Or_Else_Expr, role, "or_else", n.pos, n.end)
		similarity_flatten(b, n.x, .Value)
		similarity_flatten(b, n.y, .Value)
		similarity_end(b)
	case ^ast.Or_Return_Expr:
		similarity_begin(b, .Or_Return_Expr, role, "or_return", n.pos, n.end)
		similarity_flatten(b, n.expr, .Value)
		similarity_end(b)
	case ^ast.Or_Branch_Expr:
		similarity_begin(b, .Or_Branch_Expr, role, similarity_presence(b, n.token.text, n.label != nil ? " label" : ""), n.pos, n.end)
		similarity_flatten(b, n.expr, .Value)
		similarity_flatten(b, n.label, .Label)
		similarity_end(b)
	case ^ast.Type_Assertion:
		similarity_begin(b, .Type_Assertion, role, n.type == nil ? ".?" : ".()", n.pos, n.end)
		similarity_flatten(b, n.expr, .Value)
		similarity_flatten(b, n.type, .Type)
		similarity_end(b)
	case ^ast.Type_Cast:
		similarity_begin(b, .Type_Cast, role, n.tok.text, n.pos, n.end)
		similarity_flatten(b, n.type, .Type)
		similarity_flatten(b, n.expr, .Value)
		similarity_end(b)
	case ^ast.Auto_Cast:
		similarity_begin(b, .Auto_Cast, role, "auto_cast", n.pos, n.end)
		similarity_flatten(b, n.expr, .Value)
		similarity_end(b)
	case ^ast.Proc_Group:
		similarity_begin(b, .Proc_Group, role, "proc group", n.pos, n.end)
		similarity_flatten_list(b, n.args, .Called)
		similarity_end(b)
	case ^ast.Typeid_Type:
		similarity_begin(b, .Typeid_Type, .Type, "typeid", n.pos, n.end)
		similarity_flatten(b, n.specialization, .Type)
		similarity_end(b)
	case ^ast.Helper_Type:
		similarity_begin(b, .Helper_Type, .Type, "#type", n.pos, n.end)
		similarity_flatten(b, n.type, .Type)
		similarity_end(b)
	case ^ast.Distinct_Type:
		similarity_begin(b, .Distinct_Type, .Type, "distinct", n.pos, n.end)
		similarity_flatten(b, n.type, .Type)
		similarity_end(b)
	case ^ast.Poly_Type:
		similarity_flatten_declared(b, n, .Type)
	case ^ast.Proc_Type:
		similarity_flatten_procedure_type(b, n, .Type, false)
	case ^ast.Pointer_Type:
		similarity_begin(b, .Pointer_Type, .Type, "^", n.pos, n.end)
		similarity_flatten(b, n.tag, .Value)
		similarity_flatten(b, n.elem, .Type)
		similarity_end(b)
	case ^ast.Multi_Pointer_Type:
		similarity_begin(b, .Multi_Pointer_Type, .Type, "[^]", n.pos, n.end)
		similarity_flatten(b, n.elem, .Type)
		similarity_end(b)
	case ^ast.Array_Type:
		similarity_begin(b, .Array_Type, .Type, n.len == nil ? "[]" : "[n]", n.pos, n.end)
		similarity_flatten(b, n.tag, .Value)
		similarity_flatten(b, n.len, .Value)
		similarity_flatten(b, n.elem, .Type)
		similarity_end(b)
	case ^ast.Dynamic_Array_Type:
		similarity_begin(b, .Dynamic_Array_Type, .Type, "[dynamic]", n.pos, n.end)
		similarity_flatten(b, n.tag, .Value)
		similarity_flatten(b, n.elem, .Type)
		similarity_end(b)
	case ^ast.Fixed_Capacity_Dynamic_Array_Type:
		similarity_begin(b, .Fixed_Capacity_Dynamic_Array_Type, .Type, "[dynamic; n]", n.pos, n.end)
		similarity_flatten(b, n.tag, .Value)
		similarity_flatten(b, n.capacity, .Value)
		similarity_flatten(b, n.elem, .Type)
		similarity_end(b)
	case ^ast.Struct_Type:
		similarity_begin(b, .Struct_Type, .Type, similarity_presence(b, "struct", n.is_packed ? " #packed" : "", n.is_raw_union ? " #raw_union" : "", n.is_no_copy ? " #no_copy" : "", n.align != nil ? " #align" : "", n.poly_params != nil ? " polymorphic" : ""), n.pos, n.end)
		similarity_flatten_field_list(b, n.poly_params, false)
		similarity_flatten(b, n.align, .Value)
		similarity_flatten(b, n.min_field_align, .Value)
		similarity_flatten(b, n.max_field_align, .Value)
		similarity_flatten_list(b, n.where_clauses, .Value)
		similarity_flatten_field_list(b, n.fields, false)
		similarity_end(b)
	case ^ast.Union_Type:
		similarity_begin(b, .Union_Type, .Type, similarity_presence(b, "union", n.kind == .no_nil ? " #no_nil" : "", n.kind == .shared_nil ? " #shared_nil" : "", n.poly_params != nil ? " polymorphic" : ""), n.pos, n.end)
		similarity_flatten_field_list(b, n.poly_params, false)
		similarity_flatten(b, n.align, .Value)
		similarity_flatten_list(b, n.where_clauses, .Value)
		similarity_flatten_list(b, n.variants, .Type)
		similarity_end(b)
	case ^ast.Enum_Type:
		similarity_begin(b, .Enum_Type, .Type, n.base_type != nil ? "enum typed" : "enum", n.pos, n.end)
		similarity_flatten(b, n.base_type, .Type)
		for field in n.fields {
			if identifier, is_name := field.derived.(^ast.Ident); is_name {
				similarity_flatten_identifier(b, identifier, .Field, false)
			} else {
				similarity_flatten(b, field, .Value)
			}
		}
		similarity_end(b)
	case ^ast.Bit_Set_Type:
		similarity_begin(b, .Bit_Set_Type, .Type, n.underlying != nil ? "bit_set typed" : "bit_set", n.pos, n.end)
		similarity_flatten(b, n.elem, .Type)
		similarity_flatten(b, n.underlying, .Type)
		similarity_end(b)
	case ^ast.Map_Type:
		similarity_begin(b, .Map_Type, .Type, "map", n.pos, n.end)
		similarity_flatten(b, n.key, .Type)
		similarity_flatten(b, n.value, .Type)
		similarity_end(b)
	case ^ast.Relative_Type:
		similarity_begin(b, .Relative_Type, .Type, "#relative", n.pos, n.end)
		similarity_flatten(b, n.tag, .Value)
		similarity_flatten(b, n.type, .Type)
		similarity_end(b)
	case ^ast.Matrix_Type:
		similarity_begin(b, .Matrix_Type, .Type, "matrix", n.pos, n.end)
		similarity_flatten(b, n.row_count, .Value)
		similarity_flatten(b, n.column_count, .Value)
		similarity_flatten(b, n.elem, .Type)
		similarity_end(b)
	case ^ast.Bit_Field_Type:
		similarity_begin(b, .Bit_Field_Type, .Type, "bit_field", n.pos, n.end)
		similarity_flatten(b, n.backing_type, .Type)
		for field in n.fields {
			similarity_begin(b, .Bit_Field_Field, .Structure, "|", field.pos, field.end)
			if identifier, is_name := field.name.derived.(^ast.Ident); is_name {
				similarity_flatten_identifier(b, identifier, .Field, false)
			}
			similarity_flatten(b, field.type, .Type)
			similarity_flatten(b, field.bit_size, .Value)
			similarity_end(b)
		}
		similarity_end(b)
	case ^ast.Bad_Expr, ^ast.Bad_Stmt, ^ast.Bad_Decl:
		similarity_leaf(b, .Bad, role, "", node)
	case ^ast.Expr_Stmt:
		similarity_begin(b, .Expr_Stmt, .Statement, "", n.pos, n.end)
		similarity_flatten(b, n.expr, .Value)
		similarity_end(b)
	case ^ast.Tag_Stmt:
		similarity_begin(b, .Tag_Stmt, .Statement, similarity_presence(b, "#", n.name), n.pos, n.end)
		similarity_flatten(b, n.stmt, .Statement)
		similarity_end(b)
	case ^ast.Assign_Stmt:
		similarity_flatten_assignment(b, n)
	case ^ast.Block_Stmt:
		similarity_begin(b, .Block_Stmt, .Statement, similarity_presence(b, n.label != nil ? "label " : "", n.uses_do ? "do" : ""), n.pos, n.end)
		similarity_scope_push(b)
		similarity_flatten_declared(b, n.label, .Label)
		similarity_flatten_statements(b, n.stmts)
		similarity_scope_pop(b)
		similarity_end(b)
	case ^ast.If_Stmt:
		similarity_flatten_if(b, n)
	case ^ast.When_Stmt:
		similarity_begin(b, .When_Stmt, .Statement, n.else_stmt != nil ? "when else" : "when", n.pos, n.end)
		similarity_flatten(b, n.cond, .Value)
		similarity_flatten(b, n.body, .Statement)
		similarity_flatten(b, n.else_stmt, .Statement)
		similarity_end(b)
	case ^ast.Return_Stmt:
		similarity_begin(b, .Return_Stmt, .Statement, "return", n.pos, n.end)
		similarity_flatten_list(b, n.results, .Value)
		similarity_end(b)
	case ^ast.Defer_Stmt:
		similarity_begin(b, .Defer_Stmt, .Statement, "defer", n.pos, n.end)
		similarity_flatten(b, n.stmt, .Statement)
		similarity_end(b)
	case ^ast.For_Stmt:
		similarity_flatten_for(b, n)
	case ^ast.Range_Stmt:
		similarity_begin(b, .Range_Stmt, .Statement, similarity_presence(b, n.label != nil ? "label " : "", n.reverse ? "#reverse" : ""), n.pos, n.end)
		similarity_scope_push(b)
		similarity_flatten_declared(b, n.label, .Label)
		for value in n.vals {
			similarity_flatten_declared(b, value, .Declared)
		}
		similarity_flatten(b, n.expr, .Value)
		similarity_flatten(b, n.body, .Statement)
		similarity_scope_pop(b)
		similarity_end(b)
	case ^ast.Unroll_Range_Stmt:
		similarity_begin(b, .Unroll_Range_Stmt, .Statement, similarity_presence(b, "#unroll", n.label != nil ? " label" : "", n.val1 != nil ? " two" : ""), n.pos, n.end)
		similarity_scope_push(b)
		similarity_flatten_declared(b, n.label, .Label)
		similarity_flatten_declared(b, n.val0, .Declared)
		similarity_flatten_declared(b, n.val1, .Declared)
		similarity_flatten(b, n.expr, .Value)
		similarity_flatten(b, n.body, .Statement)
		similarity_scope_pop(b)
		similarity_end(b)
	case ^ast.Case_Clause:
		similarity_begin(b, .Case_Clause, .Statement, len(n.list) == 0 ? "case default" : "case", n.pos, n.end)
		similarity_scope_push(b)
		similarity_flatten_list(b, n.list, b.case_role)
		similarity_flatten_statements(b, n.body)
		similarity_scope_pop(b)
		similarity_end(b)
	case ^ast.Switch_Stmt:
		similarity_begin(b, .Switch_Stmt, .Statement, similarity_presence(b, "switch", n.label != nil ? " label" : "", n.init != nil ? " init" : "", n.cond != nil ? " condition" : "", n.partial ? " #partial" : ""), n.pos, n.end)
		similarity_scope_push(b)
		similarity_flatten_declared(b, n.label, .Label)
		similarity_flatten(b, n.init, .Statement)
		similarity_flatten(b, n.cond, .Value)
		saved_case_role := b.case_role
		b.case_role = .Value
		similarity_flatten(b, n.body, .Statement)
		b.case_role = saved_case_role
		similarity_scope_pop(b)
		similarity_end(b)
	case ^ast.Type_Switch_Stmt:
		similarity_begin(b, .Type_Switch_Stmt, .Statement, similarity_presence(b, "switch in", n.label != nil ? " label" : "", n.partial ? " #partial" : ""), n.pos, n.end)
		similarity_scope_push(b)
		similarity_flatten_declared(b, n.label, .Label)
		similarity_flatten(b, n.tag, .Statement)
		similarity_flatten(b, n.expr, .Value)
		saved_case_role := b.case_role
		b.case_role = .Type
		similarity_flatten(b, n.body, .Statement)
		b.case_role = saved_case_role
		similarity_scope_pop(b)
		similarity_end(b)
	case ^ast.Branch_Stmt:
		similarity_begin(b, .Branch_Stmt, .Statement, similarity_presence(b, n.tok.text, n.label != nil ? " label" : ""), n.pos, n.end)
		if n.label != nil {
			similarity_flatten_identifier(b, n.label, .Label, false)
		}
		similarity_end(b)
	case ^ast.Using_Stmt:
		index := similarity_begin(b, .Using_Stmt, .Statement, "using", n.pos, n.end)
		b.nodes[index].flags += {.Holds_Using}
		similarity_flatten_list(b, n.list, .Value)
		similarity_end(b)
	case ^ast.Value_Decl:
		similarity_flatten_value_declaration(b, n)
	case ^ast.Attribute:
		similarity_begin(b, .Attribute, .Structure, "@", n.pos, n.end)
		similarity_flatten_list(b, n.elems, .Value)
		similarity_end(b)
	case ^ast.Field_List:
		similarity_flatten_field_list(b, n, false)
	case ^ast.Asm_Template:
		similarity_begin(b, .Asm_Template, role, "asm", n.pos, n.end)
		if n.type != nil {
			similarity_flatten_procedure_type(b, n.type, .Type, false)
		}
		for spec in n.specs {
			similarity_flatten(b, spec, .Statement)
		}
		for clobber in n.clobbers {
			similarity_flatten(b, clobber, .Statement)
		}
		similarity_flatten_statements(b, n.instructions)
		similarity_end(b)
	case ^ast.Asm_Spec:
		similarity_begin(b, .Asm_Spec, .Statement, n.name != nil ? n.name.name : "", n.pos, n.end)
		similarity_flatten(b, n.type, .Type)
		similarity_flatten(b, n.value, .Value)
		similarity_flatten_list(b, n.directives, .Value)
		similarity_end(b)
	case ^ast.Asm_Register:
		similarity_leaf(b, .Asm_Register, role, similarity_presence(b, n.name, n.flag), node)
	case ^ast.Asm_Clobber:
		similarity_begin(b, .Asm_Clobber, .Statement, n.name, n.pos, n.end)
		similarity_flatten(b, n.value, .Value)
		similarity_end(b)
	case ^ast.Asm_Label:
		similarity_leaf(b, .Asm_Label, role, n.name, node)
	case ^ast.Asm_Label_Decl:
		similarity_begin(b, .Asm_Label_Decl, .Statement, "label", n.pos, n.end)
		similarity_flatten(b, n.label, .Label)
		similarity_end(b)
	case ^ast.Asm_Instruction:
		similarity_begin(b, .Asm_Instruction, .Statement, n.name != nil ? n.name.name : "", n.pos, n.end)
		similarity_flatten_list(b, n.operands, .Value)
		similarity_end(b)
	case ^ast.Asm_Memory_Operand:
		similarity_begin(b, .Asm_Memory_Operand, role, similarity_presence(b, "[", n.segment_override != nil ? "s" : "", n.base != nil ? "b" : "", n.index != nil ? "i" : "", n.scale != nil ? "x" : "", n.disp != nil ? "d" : "", n.type != nil ? "t" : "", "]"), n.pos, n.end)
		similarity_flatten(b, n.segment_override, .Value)
		similarity_flatten(b, n.base, .Value)
		similarity_flatten(b, n.index, .Value)
		similarity_flatten(b, n.scale, .Value)
		similarity_flatten(b, n.disp, .Value)
		similarity_flatten(b, n.type, .Type)
		similarity_end(b)
	case ^ast.Asm_Register_Group:
		similarity_begin(b, .Asm_Register_Group, role, n.type != nil ? "{} typed" : "{}", n.pos, n.end)
		similarity_flatten_list(b, n.registers, .Value)
		similarity_flatten(b, n.type, .Type)
		similarity_end(b)
	case ^ast.Asm_Directive:
		similarity_begin(b, .Asm_Directive, .Statement, n.name, n.pos, n.end)
		similarity_flatten_list(b, n.operands, .Value)
		similarity_end(b)
	case:
		similarity_leaf(b, .Bad, role, "", node)
	}
}

@(private = "file")
similarity_flatten_unary :: proc(b: ^Similarity_Builder, n: ^ast.Unary_Expr, role: Similarity_Role) {
	inner := ast.unparen_expr(n.expr)
	if inner != nil && (n.op.kind == .Not || n.op.kind == .Sub) {
		if binary, is_binary := inner.derived.(^ast.Binary_Expr); is_binary && n.op.kind == .Not && (binary.op.kind == .Cmp_Eq || binary.op.kind == .Not_Eq) {
			index := similarity_begin(b, .Binary_Expr, role, binary.op.kind == .Cmp_Eq ? "!=" : "==", n.pos, n.end)
			b.nodes[index].rules += {.Negated_Equality}
			similarity_flatten(b, binary.left, .Value)
			similarity_flatten(b, binary.right, .Value)
			similarity_end(b)
			return
		}
		if unary, is_unary := inner.derived.(^ast.Unary_Expr); is_unary && unary.op.kind == n.op.kind {
			before := len(b.nodes)
			similarity_flatten(b, unary.expr, role)
			if len(b.nodes) > before {
				b.nodes[before].rules += {.Double_Negation}
			}
			return
		}
	}
	if value, constant := similarity_integer_value(n); constant && n.op.kind == .Sub {
		if _, is_literal := inner.derived.(^ast.Basic_Lit); !is_literal {
			similarity_integer_literal(b, value, n.pos, n.end, role)
			return
		}
	}
	similarity_begin(b, .Unary_Expr, role, n.op.text, n.pos, n.end)
	if n.expr != nil {
		similarity_flatten(b, n.expr, n.op.kind == .And ? .Place : .Value)
	}
	similarity_end(b)
}

@(private = "file")
similarity_integer_literal :: proc(b: ^Similarity_Builder, value: i128, start, end: tokenizer.Pos, role: Similarity_Role) {
	text := fmt.aprintf("%d", value, allocator = b.allocator)
	index := similarity_begin(b, .Basic_Lit, role, text, start, end)
	b.nodes[index].literal = .Integer
	b.nodes[index].rules += {.Integer_Arithmetic}
	similarity_end(b)
}

@(private = "file")
similarity_flatten_binary :: proc(b: ^Similarity_Builder, n: ^ast.Binary_Expr, role: Similarity_Role) {
	if value, constant := similarity_integer_value(n); constant {
		similarity_integer_literal(b, value, n.pos, n.end, role)
		return
	}
	label := n.op.text
	left := n.left
	right := n.right
	rules: Similarity_Rules
	#partial switch n.op.kind {
	case .Gt:
		label = "<"
		left, right = right, left
		rules += {.Comparison_Direction}
	case .Gt_Eq:
		label = "<="
		left, right = right, left
		rules += {.Comparison_Direction}
	}
	index := similarity_begin(b, .Binary_Expr, role, label, n.pos, n.end)
	b.nodes[index].rules += rules
	similarity_flatten(b, left, .Value)
	similarity_flatten(b, right, .Value)
	similarity_end(b)
}

@(private = "file")
similarity_flatten_selector :: proc(b: ^Similarity_Builder, n: ^ast.Selector_Expr, role: Similarity_Role) {
	if base, is_name := n.expr.derived.(^ast.Ident); is_name && n.field != nil {
		if _, is_local := similarity_local_lookup(b, base.name); !is_local {
			if path, imported := b.imports[base.name]; imported {
				similarity_begin(b, .Qualified_Name, role, strings.concatenate({path, ".", n.field.name}, b.allocator), n.pos, n.end)
				similarity_end(b)
				return
			}
		}
	}
	similarity_begin(b, .Selector_Expr, role, n.op.text, n.pos, n.end)
	similarity_flatten(b, n.expr, role == .Place ? .Place : .Value)
	if n.field != nil {
		similarity_flatten_identifier(b, n.field, .Field, false)
	}
	similarity_end(b)
}

@(private = "file")
similarity_flatten_call :: proc(b: ^Similarity_Builder, n: ^ast.Call_Expr, role: Similarity_Role) {
	is_conversion := similarity_expression_is_type(b, n.expr)
	pure := is_conversion
	if !is_conversion {
		if callee, is_name := n.expr.derived.(^ast.Ident); is_name && similarity_is_pure_builtin(callee.name) {
			_, is_local := similarity_local_lookup(b, callee.name)
			pure = !is_local
		}
	}
	index := similarity_begin(b, .Call_Expr, role, similarity_presence(b, similarity_inlining_label(n.inlining), "()", n.ellipsis.kind != .Invalid ? " .." : ""), n.pos, n.end)
	if !pure {
		b.nodes[index].flags += {.Impure}
	}
	similarity_flatten(b, n.expr, is_conversion ? .Type : .Called)
	similarity_flatten_list(b, n.args, .Value)
	similarity_end(b)
}

// `x op= y` becomes `x = x op y` when x is a pure place, so the two forms
// of one assignment are equal.
@(private = "file")
similarity_flatten_assignment :: proc(b: ^Similarity_Builder, n: ^ast.Assign_Stmt) {
	if n.op.kind == .In {
		index := similarity_begin(b, .Assign_Stmt, .Statement, "in", n.pos, n.end)
		b.nodes[index].flags += {.Impure}
		for target in n.lhs {
			similarity_flatten_declared(b, target, .Declared)
		}
		similarity_flatten_list(b, n.rhs, .Value)
		similarity_end(b)
		return
	}
	is_operator := n.op.kind > .B_Assign_Op_Begin && n.op.kind < .B_Assign_Op_End && len(n.op.text) >= 2
	if is_operator && len(n.lhs) == 1 && len(n.rhs) == 1 && similarity_expression_is_pure_place(b, n.lhs[0]) {
		index := similarity_begin(b, .Assign_Stmt, .Statement, "=", n.pos, n.end)
		b.nodes[index].rules += {.Operator_Assignment}
		b.nodes[index].flags += {.Impure}
		similarity_flatten(b, n.lhs[0], .Place)
		similarity_begin(b, .Binary_Expr, .Value, n.op.text[:len(n.op.text) - 1], n.rhs[0].pos, n.rhs[0].end)
		similarity_flatten(b, n.lhs[0], .Value)
		similarity_flatten(b, n.rhs[0], .Value)
		similarity_end(b)
		similarity_end(b)
		return
	}
	index := similarity_begin(b, .Assign_Stmt, .Statement, n.op.text, n.pos, n.end)
	b.nodes[index].flags += {.Impure}
	similarity_flatten_list(b, n.lhs, .Place)
	similarity_flatten_list(b, n.rhs, .Value)
	similarity_end(b)
}

@(private = "file")
similarity_flatten_if :: proc(b: ^Similarity_Builder, n: ^ast.If_Stmt) {
	if if_statement, is_boolean_return := similarity_boolean_return_if(n); is_boolean_return && n.else_stmt != nil && similarity_returns_word(n.else_stmt, "false") {
		similarity_flatten_boolean_return(b, if_statement.cond, n.pos, n.end)
		return
	}
	condition := n.cond
	body := n.body
	otherwise := n.else_stmt
	rules: Similarity_Rules
	if otherwise != nil {
		_, else_is_block := otherwise.derived.(^ast.Block_Stmt)
		if negation, is_unary := ast.unparen_expr(condition).derived.(^ast.Unary_Expr); is_unary && negation.op.kind == .Not && else_is_block && negation.expr != nil {
			condition = negation.expr
			body, otherwise = otherwise, body
			rules += {.Negated_Condition}
		}
	}
	index := similarity_begin(b, .If_Stmt, .Statement, similarity_presence(b, "if", n.label != nil ? " label" : "", n.init != nil ? " init" : "", otherwise != nil ? " else" : ""), n.pos, n.end)
	b.nodes[index].rules += rules
	similarity_scope_push(b)
	similarity_flatten_declared(b, n.label, .Label)
	similarity_flatten(b, n.init, .Statement)
	similarity_flatten(b, condition, .Value)
	similarity_flatten(b, body, .Statement)
	similarity_flatten(b, otherwise, .Statement)
	similarity_scope_pop(b)
	similarity_end(b)
}

@(private = "file")
similarity_flatten_for :: proc(b: ^Similarity_Builder, n: ^ast.For_Stmt) {
	if variable, low, high, counted := similarity_counted_loop(n); counted {
		index := similarity_begin(b, .Range_Stmt, .Statement, n.label != nil ? "label " : "", n.pos, n.end)
		b.nodes[index].rules += {.Counted_Loop}
		similarity_scope_push(b)
		similarity_flatten_declared(b, n.label, .Label)
		similarity_flatten_identifier(b, variable, .Declared, true)
		similarity_begin(b, .Binary_Expr, .Value, "..<", low.pos, high.end)
		similarity_flatten(b, low, .Value)
		similarity_flatten(b, high, .Value)
		similarity_end(b)
		similarity_flatten(b, n.body, .Statement)
		similarity_scope_pop(b)
		similarity_end(b)
		return
	}
	similarity_begin(b, .For_Stmt, .Statement, similarity_presence(b, "for", n.label != nil ? " label" : "", n.init != nil ? " init" : "", n.cond != nil ? " condition" : "", n.post != nil ? " post" : ""), n.pos, n.end)
	similarity_scope_push(b)
	similarity_flatten_declared(b, n.label, .Label)
	similarity_flatten(b, n.init, .Statement)
	similarity_flatten(b, n.cond, .Value)
	similarity_flatten(b, n.post, .Statement)
	similarity_flatten(b, n.body, .Statement)
	similarity_scope_pop(b)
	similarity_end(b)
}

@(private = "file")
similarity_flatten_value_declaration :: proc(b: ^Similarity_Builder, n: ^ast.Value_Decl) {
	index := similarity_begin(b, .Value_Decl, .Statement, similarity_presence(b, n.is_mutable ? ":=" : "::", n.type != nil ? " typed" : "", n.is_using ? " using" : ""), n.pos, n.end)
	if n.is_using {
		b.nodes[index].flags += {.Holds_Using}
	}
	if n.is_mutable && len(n.values) > 0 {
		b.nodes[index].flags += {.Impure}
	}
	for attribute in n.attributes {
		similarity_flatten(b, attribute, .Structure)
	}
	for name in n.names {
		similarity_flatten_declared(b, name, .Declared)
	}
	similarity_flatten(b, n.type, .Type)
	similarity_flatten_list(b, n.values, .Value)
	similarity_end(b)
}

// similarity_import_name gives the name under which a file reads an
// import: its own name, or the last part of its path.
similarity_import_name :: proc(declaration: ^ast.Import_Decl) -> (name: string, path: string) {
	path = strings.trim(declaration.relpath.text, "\"`")
	name = declaration.name.text
	if name == "" {
		name = path
		if at := strings.last_index_any(name, ":/"); at >= 0 {
			name = name[at + 1:]
		}
	}
	return name, path
}

// similarity_type_declaration says that the value of a top-level constant
// declaration is a type.
similarity_type_declaration :: proc(value: ^ast.Expr) -> bool {
	if value == nil {
		return false
	}
	#partial switch e in value.derived {
	case ^ast.Struct_Type, ^ast.Union_Type, ^ast.Enum_Type, ^ast.Distinct_Type, ^ast.Bit_Set_Type, ^ast.Pointer_Type, ^ast.Multi_Pointer_Type, ^ast.Array_Type, ^ast.Dynamic_Array_Type, ^ast.Map_Type, ^ast.Proc_Type, ^ast.Matrix_Type, ^ast.Bit_Field_Type, ^ast.Helper_Type, ^ast.Typeid_Type:
		return true
	case ^ast.Ident:
		return similarity_is_builtin_type_name(e.name)
	}
	return false
}
