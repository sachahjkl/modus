// Flat 32-bit register bytecode ISA, compiled chunks, prototypes, and call-site
// descriptors for the Lex v2 VM (src/md/features/declarations.md, "Lex v2 engine").
package lex_evaluator

import "modus:contract/blake3"
import "modus:lex_parser"

// Fixed-width 32-bit VM instruction:
//   ABC:  [ op:8 | A:8 | B:8 | C:8 ]
//   ABx:  [ op:8 | A:8 | Bx:16 ]
//   AsBx: [ op:8 | A:8 | sBx:16 (signed) ]
//   Ax:   [ op:8 | Ax:24 ] (used by Extra_Arg prefix for >16-bit indices)
Instruction :: distinct u32
#assert(size_of(Instruction) == 4)

Opcode :: enum u8 {
	Nop = 0,
	// Moves & constants
	Move,             // R[A] = R[B]
	Load_None,        // R[A] = None
	Load_Bool,        // R[A] = Bool(B != 0)
	Load_Int_Imm,     // R[A] = i64(sBx)
	Load_Const,       // R[A] = consts[Bx]
	// Lexical environment & thunks
	Get_Upval,        // R[A] = force(frame.env[Bx])
	Get_Let,          // R[A] = force(frame.let_slots[Bx])
	Let_Enter,        // allocate N thunks from let_descs[Bx]; Console mode forces left-to-right
	// Arithmetic, boolean & comparisons
	Neg,               // R[A] = -R[B]
	Not,               // R[A] = !R[B] (strict Boolean)
	Add,               // R[A] = R[B] + R[C]
	Sub,               // R[A] = R[B] - R[C]
	Mul,               // R[A] = R[B] * R[C]
	Div,               // R[A] = R[B] / R[C]
	Rem,               // R[A] = R[B] % R[C]
	List_Concat,       // R[A] = R[B] ++ R[C] (List ++ List)
	Eq,                // R[A] = (R[B] == R[C])
	Neq,               // R[A] = (R[B] != R[C])
	Lt,                // R[A] = (R[B] <  R[C])
	Le,                // R[A] = (R[B] <= R[C])
	Gt,                // R[A] = (R[B] >  R[C])
	Ge,                // R[A] = (R[B] >= R[C])
	// Control flow & short-circuit booleans
	Jmp,               // ip += sBx
	Jmp_If_False,      // if !bool(R[A]) -> ip += sBx (refuses non-Bool with Condition_Not_Boolean)
	Jmp_If_False_Keep, // short-circuit &&: refuses non-Bool with Operator_Kinds(.Logical_And)
	Jmp_If_True_Keep,  // short-circuit || / assert: if bool(R[A]) -> ip += sBx (refuses non-Bool)
	Check_Bool,        // validate R[A] is Boolean (B = u8(Operator) for Operator_Kinds)
	// Functions & calls
	Closure,           // R[A] = Closure(protos[Bx], captured upvals)
	Check_Call,        // validate R[A] is Function with B params before evaluating args
	Call,              // R[A] = call R[A](R[A+1 .. A+B]) (fast positional)
	Tail_Call,         // tail-call R[A](R[A+1 .. A+B]) (O(1) frame reuse)
	Call_Builtin,      // R[A] = builtin B on args R[A+1 .. A+C]
	Call_Site,         // R[A] = execute call_sites[Bx] (host commands, named args, console forms)
	Ret,               // return R[A]
	// Records, destructuring, lists & string interpolation
	Make_Record,       // R[A] = Lazy_Record(record_descs[Bx]); Console forces fields in source order
	Get_Field,         // R[A] = R[B].field_syms[C] (or Extra_Arg if C == 255)
	With,              // R[A] = R[B] with R[C] (strictly override-only)
	Destructure,       // destructure R[A] using pattern_descs[Bx] into frame.let_slots
	List_Begin,        // push list scratch mark
	List_Push,         // push R[A] onto list scratch (validates Console item kind)
	List_End,          // R[A] = finalized List from scratch mark
	Str_Begin,         // push interpolation scratch mark
	Str_Push,          // validate & push formatted interpolation piece R[A]
	Str_End,           // R[A] = concatenated interpolated Text in text_arena
	// Diagnostics & tracing
	Assert_Fail,       // refuse with Assertion_Failed carrying Text R[A]
	Trace,             // append Text R[A] to caller Trace_Log and mark eval.traced = true
	// Host & console special forms
	Load_Global,       // R[A] = host.name_value(consts[Bx])
	Refuse_Parse,      // emit Refusal.Text for partial-parse Refused AST node (node_idx = Bx)
	// Wide 24-bit prefix operand for the immediately following instruction.
	Extra_Arg,
}

// Fast built-in function identifiers for OP_CALL_BUILTIN.
Builtin_Id :: enum u8 {
	None       = 0,
	Map        = 1,
	Filter     = 2,
	Fold       = 3,
	Zip        = 4,
	Fields     = 5,
	Values     = 6,
	Has        = 7,
	Extend     = 8,
	Merge_Deep = 9,
}

// Instruction encode/decode helpers.
inst_abc :: #force_inline proc "contextless" (op: Opcode, a, b, c: u8) -> Instruction {
	return Instruction(u32(op) | (u32(a) << 8) | (u32(b) << 16) | (u32(c) << 24))
}

inst_abx :: #force_inline proc "contextless" (op: Opcode, a: u8, bx: u16) -> Instruction {
	return Instruction(u32(op) | (u32(a) << 8) | (u32(bx) << 16))
}

inst_asbx :: #force_inline proc "contextless" (op: Opcode, a: u8, sbx: i16) -> Instruction {
	return Instruction(u32(op) | (u32(a) << 8) | (u32(u16(sbx)) << 16))
}

inst_ax :: #force_inline proc "contextless" (op: Opcode, ax: u32) -> Instruction {
	return Instruction(u32(op) | ((ax & 0x00FF_FFFF) << 8))
}

@(rodata)
OPCODES_IN_ORDER := [len(Opcode)]Opcode {
	.Nop,
	.Move,
	.Load_None,
	.Load_Bool,
	.Load_Int_Imm,
	.Load_Const,
	.Get_Upval,
	.Get_Let,
	.Let_Enter,
	.Neg,
	.Not,
	.Add,
	.Sub,
	.Mul,
	.Div,
	.Rem,
	.List_Concat,
	.Eq,
	.Neq,
	.Lt,
	.Le,
	.Gt,
	.Ge,
	.Jmp,
	.Jmp_If_False,
	.Jmp_If_False_Keep,
	.Jmp_If_True_Keep,
	.Check_Bool,
	.Closure,
	.Check_Call,
	.Call,
	.Tail_Call,
	.Call_Builtin,
	.Call_Site,
	.Ret,
	.Make_Record,
	.Get_Field,
	.With,
	.Destructure,
	.List_Begin,
	.List_Push,
	.List_End,
	.Str_Begin,
	.Str_Push,
	.Str_End,
	.Assert_Fail,
	.Trace,
	.Load_Global,
	.Refuse_Parse,
	.Extra_Arg,
}

@(rodata)
BUILTINS_IN_ORDER := [len(Builtin_Id)]Builtin_Id {
	.None,
	.Map,
	.Filter,
	.Fold,
	.Zip,
	.Fields,
	.Values,
	.Has,
	.Extend,
	.Merge_Deep,
}

inst_op :: #force_inline proc "contextless" (inst: Instruction) -> (Opcode, bool) {
	b := u32(inst) & 0xFF
	if b >= u32(len(OPCODES_IN_ORDER)) {
		return .Nop, false
	}
	return OPCODES_IN_ORDER[b], true
}

builtin_of_byte :: #force_inline proc "contextless" (b: u8) -> (Builtin_Id, bool) {
	if int(b) >= len(BUILTINS_IN_ORDER) {
		return .None, false
	}
	return BUILTINS_IN_ORDER[b], true
}

inst_a :: #force_inline proc "contextless" (inst: Instruction) -> u8 {
	return u8((u32(inst) >> 8) & 0xFF)
}

inst_b :: #force_inline proc "contextless" (inst: Instruction) -> u8 {
	return u8((u32(inst) >> 16) & 0xFF)
}

inst_c :: #force_inline proc "contextless" (inst: Instruction) -> u8 {
	return u8((u32(inst) >> 24) & 0xFF)
}

inst_bx :: #force_inline proc "contextless" (inst: Instruction) -> u16 {
	return u16((u32(inst) >> 16) & 0xFFFF)
}

inst_sbx :: #force_inline proc "contextless" (inst: Instruction) -> i16 {
	return i16(u16((u32(inst) >> 16) & 0xFFFF))
}

inst_ax_val :: #force_inline proc "contextless" (inst: Instruction) -> u32 {
	return (u32(inst) >> 8) & 0x00FF_FFFF
}

// Constant pool entry inside a compiled Chunk.
Const_Kind :: enum u8 {
	Integer    = 0,
	Text       = 1, // source[offset : offset + length]
	Sym        = 2, // Interned Sym_Id
	Hash       = 3, // Decoded 32-byte BLAKE3 hash
	Member     = 4, // Interned member name Sym_Id + node_idx
	Arena_Text = 5, // text_arena[offset : offset + length] (decoded escaped literal)
}

Const_Entry :: struct {
	kind:     Const_Kind,
	pad:      [3]u8,
	offset:   u32, // For Text: source byte offset. For Sym/Member: u32(Sym_Id).
	length:   u32, // For Text: byte length. For Member: u32(node_idx).
	integer:  i64,
	hash:     blake3.Hash,
}

// How a child Proto captures one lexical variable from its enclosing Proto.
Upval_Source :: enum u8 {
	Parent_Let         = 0, // Thunk_Ref at parent_frame.let_slots[index]
	Parent_Boxed_Param = 1, // Thunk_Ref at parent_frame.boxed_params[index]
	Parent_Upval       = 2, // Thunk_Ref at parent_frame.env[index]
}

Upval_Desc :: struct {
	source: Upval_Source,
	pad:    u8,
	index:  u16,
}

// One compiled bytecode prototype (root expression, function body, let RHS
// thunk, record field thunk, or call-site argument thunk).
Proto :: struct {
	code_start:       u32,
	code_len:         u32,
	max_regs:         u16,
	param_count:      u16,
	let_slot_count:   u16,
	boxed_param_mask: u16, // Bit i set => parameter i is captured by an inner closure/thunk.
	upval_start:      u32,
	upval_count:      u16,
	flags:            u16,
	// Parameter names (for named calls to Lex functions) and source spans.
	param_syms:       [lex_parser.ARGUMENT_CAPACITY]lex_parser.Sym_Id,
	node_idx:         lex_parser.Node_Index,
	fn_open_off:      u32,
	fn_arrow_end:     u32,
}

// Compiled `let` block descriptor: allocates `binding_count` thunks in
// `frame.let_slots[slot_start : slot_start + binding_count]`.
Let_Desc :: struct {
	slot_start:    u16,
	binding_count: u16,
	protos_start:  u32, // Slice into chunk's let_protos[protos_start : protos_start + binding_count].
	syms_start:    u32, // Binding name Sym_Ids (for cycle diagnostics).
	nodes_start:   u32, // Binding AST Node_Index (for cycle diagnostics).
}

// Compiled record literal descriptor referencing a canonical UTF-8 sorted
// Record_Shape.
Record_Desc :: struct {
	shape_id:         u32,
	field_count:      u32,
	protos_start:     u32, // Field RHS proto_ids in canonical shape order.
	nodes_start:      u32, // Field AST Node_Index in canonical shape order.
	source_order_off: u32, // Permutation 0..F-1 mapping source index -> canonical field index.
	literal_node:     lex_parser.Node_Index,
}

// How a Call_Site resolves its callee.
Call_Site_Callee :: enum u8 {
	Host_Or_Builtin = 0, // Lookup in builtins (map/filter) then host.command_find.
	Reg             = 1, // Callee value already evaluated in reg `callee_reg`.
}

// Kind of one argument inside a Call_Site_Desc.
Call_Arg_Kind :: enum u8 {
	Expr        = 0, // Evaluate arg.proto_id in current frame's env.
	Condition   = 1, // Host condition_value(arg.node_idx).
	Fact_Name   = 2, // Host fact_name_value(arg.node_idx).
	Field_Names = 3, // Static text or Field_Name_Missing refusal.
	Refused     = 4, // Partial-parse Refused AST node.
}

Call_Site_Arg :: struct {
	kind:        Call_Arg_Kind,
	is_named:    bool,
	is_literal:  bool, // Direct unparenthesized Record_Literal (for pre-validation against Record param).
	is_member:   bool, // Direct .Member (for pre-validation against Enum param).
	name_sym:    lex_parser.Sym_Id, // Parameter name for named args.
	member_sym:  lex_parser.Sym_Id, // Member name for direct .Member args.
	proto_id:    u32,  // Compiled expression proto for .Expr.
	record_desc: u32,  // Record_Desc index when is_literal == true.
	node_idx:    lex_parser.Node_Index, // Argument node (or Named_Argument node).
	val_node:    lex_parser.Node_Index, // Inner value node (for Named_Argument / Literal / Member).
}

// Descriptor for calls that need signature lookup, named arguments, record
// literal typing, member typing, or console special forms (Condition/Fact_Name).
Call_Site_Desc :: struct {
	callee_kind:     Call_Site_Callee,
	callee_reg:      u8,
	has_named:       bool,
	has_refused_arg: bool,
	name_sym:        lex_parser.Sym_Id,
	node_idx:        lex_parser.Node_Index,
	args_start:      u32,
	arg_count:       u16,
	pad:             u16,
}

// Compiled record destructuring pattern (`{ a, b = 10, ... }` or `r @ { a, b }`).
Pattern_Field_Desc :: struct {
	sym:           lex_parser.Sym_Id,
	let_slot:      u16,
	has_default:   bool,
	pad:           u8,
	default_proto: u32, // Relative proto_id in chunk when has_default == true.
	node_idx:      lex_parser.Node_Index,
}

Pattern_Desc :: struct {
	has_rest:     bool,
	has_as:       bool,
	as_let_slot:  u16,
	fields_start: u32, // Slice into eval.pattern_fields[fields_start : fields_start + field_count].
	field_count:  u16,
	pad:          u16,
	node_idx:     lex_parser.Node_Index,
}

// Compiled bytecode chunk for one source file / console line.
Chunk :: struct {
	source:          string,
	tree:            ^lex_parser.Syntax_Tree, // Retained for console Condition/Fact_Name/place lookup.
	root_proto:      u32,
	proto_start:     u32,
	proto_count:     u32,
	const_start:     u32,
	const_count:     u32,
	let_desc_start:  u32,
	let_desc_count:  u32,
	rec_desc_start:  u32,
	rec_desc_count:  u32,
	site_start:      u32,
	site_count:      u32,
	field_sym_start: u32,
	field_sym_count: u32,
	pat_desc_start:  u32,
	pat_desc_count:  u32,
}
