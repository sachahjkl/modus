// Single-pass AST -> 32-bit register bytecode compiler for Lex v2
// (src/md/features/declarations.md, "Lex v2 engine").
//
// Compiles a lex_parser.Syntax_Tree directly into contiguous bytecode Protos,
// canonical UTF-8 byte-order sorted Record_Shapes, and Call_Site_Descs inside
// caller-owned evaluation pools. Zero heap allocation, zero global state.
package lex_evaluator

import "modus:console_language"
import "modus:lex_parser"

// Maximum nesting of lexical function/thunk scopes during compilation.
// Matches parser depth bound plus headroom for synthetic thunks.
@(private)
MAX_COMPILE_SCOPES :: 280

@(private)
Compile_Local :: struct {
	sym:  lex_parser.Sym_Id,
	slot: u16,
}

@(private)
Compile_Let_Scope :: struct {
	parent:       i32, // -1 if none.
	locals_start: u32,
	locals_count: u32,
}

@(private)
Pending_Kind :: enum u8 {
	Expr_Proto     = 0,
	Function_Body  = 1,
}

@(private)
Pending_Proto :: struct {
	kind:             Pending_Kind,
	proto_idx:        u32, // Absolute index in eval.protos.
	ast_node:         lex_parser.Node_Index,
	parent_let_scope: i32,
	param_count:      u16,
	param_syms:       [lex_parser.ARGUMENT_CAPACITY]lex_parser.Sym_Id,
	param_patterns:   [lex_parser.ARGUMENT_CAPACITY]lex_parser.Node_Index,
	fn_node:          lex_parser.Node_Index,
	fn_open_off:      u32,
	fn_arrow_end:     u32,
}

@(private)
Fn_Scope :: struct {
	proto_idx:         u32,
	param_count:       u16,
	param_syms:        [lex_parser.ARGUMENT_CAPACITY]lex_parser.Sym_Id,
	boxed_param_mask:  u16,
	current_let_scope: i32,
	next_let_slot:     u16,
	upval_start:       int,
	upval_count:       int,
	reg_top:           u8,
	max_regs:          u8,
	pending_start:     int,
}

@(private)
Resolve_Kind :: enum u8 {
	Global      = 0,
	Local_Param = 1,
	Local_Let   = 2,
	Upval       = 3,
}

@(private)
Resolve_Result :: struct {
	kind:  Resolve_Kind,
	index: u16,
}

@(private)
Rec_Sort_Entry :: struct {
	sym:     lex_parser.Sym_Id,
	proto:   u32,
	node:    lex_parser.Node_Index,
	src_idx: u32,
}

// Temporary compile-time scratch state, stored inside Evaluation / workspace
// pools so the C stack frame stays tiny.
Compile_Scratch :: struct {
	locals:      []Compile_Local,
	let_scopes:  []Compile_Let_Scope,
	pending:     []Pending_Proto,
	upval_work:  []Upval_Desc,
	rec_sort:    []Rec_Sort_Entry,
}

@(private)
Compiler :: struct {
	eval:            ^Evaluation,
	tree:            ^lex_parser.Syntax_Tree,
	chunk_id:        u16,
	chunk:           ^Chunk,
	scratch:         ^Compile_Scratch,
	local_count:     int,
	let_scope_count: int,
	pending_count:   int,
	upval_work_used: int,
	scopes:          [MAX_COMPILE_SCOPES]Fn_Scope,
	scope_count:     int,
	failed:          bool,
	fail_pool:       bool,
}

// compile_tree compiles `tree` into a new Chunk inside `eval`. Returns the
// chunk index and true on success; returns false on pool exhaustion.
compile_tree :: proc "contextless" (eval: ^Evaluation, tree: ^lex_parser.Syntax_Tree) -> (chunk_id: u16, ok: bool) {
	if eval.chunk_count >= len(eval.chunks) {
		return 0, false
	}
	cid := u16(eval.chunk_count)
	eval.chunk_count += 1
	chunk := &eval.chunks[cid]
	chunk^ = {
		source          = tree.text,
		tree            = tree,
		proto_start     = u32(eval.proto_count),
		const_start     = u32(eval.const_count),
		let_desc_start  = u32(eval.let_desc_count),
		rec_desc_start  = u32(eval.rec_desc_count),
		site_start      = u32(eval.site_count),
		field_sym_start = u32(eval.field_sym_count),
		pat_desc_start  = u32(eval.pat_desc_count),
	}

	c := Compiler {
		eval     = eval,
		tree     = tree,
		chunk_id = cid,
		chunk    = chunk,
		scratch  = &eval.compile_scratch,
	}

	root_proto, alloc_ok := alloc_proto(&c, tree.root)
	if !alloc_ok {
		return 0, false
	}
	chunk.root_proto = root_proto - chunk.proto_start

	compile_proto_body(&c, Pending_Proto{
		kind             = .Expr_Proto,
		proto_idx        = root_proto,
		ast_node         = tree.root,
		parent_let_scope = -1,
	})
	if c.failed {
		return 0, false
	}

	chunk.proto_count = u32(eval.proto_count) - chunk.proto_start
	chunk.const_count = u32(eval.const_count) - chunk.const_start
	chunk.let_desc_count = u32(eval.let_desc_count) - chunk.let_desc_start
	chunk.rec_desc_count = u32(eval.rec_desc_count) - chunk.rec_desc_start
	chunk.site_count = u32(eval.site_count) - chunk.site_start
	chunk.field_sym_count = u32(eval.field_sym_count) - chunk.field_sym_start
	chunk.pat_desc_count = u32(eval.pat_desc_count) - chunk.pat_desc_start
	return cid, true
}

@(private)
compiler_fail_pool :: proc "contextless" (c: ^Compiler) {
	c.failed = true
	c.fail_pool = true
}

@(private)
alloc_proto :: proc "contextless" (c: ^Compiler, node_idx: lex_parser.Node_Index) -> (proto_idx: u32, ok: bool) {
	if c.eval.proto_count >= len(c.eval.protos) {
		compiler_fail_pool(c)
		return 0, false
	}
	idx := u32(c.eval.proto_count)
	c.eval.proto_count += 1
	c.eval.protos[idx] = {node_idx = node_idx}
	return idx, true
}

@(private)
cur_scope :: #force_inline proc "contextless" (c: ^Compiler) -> ^Fn_Scope {
	return &c.scopes[c.scope_count - 1]
}

@(private)
emit :: proc "contextless" (c: ^Compiler, inst: Instruction, node_idx: lex_parser.Node_Index) -> u32 {
	if c.failed {
		return 0
	}
	if c.eval.code_count >= len(c.eval.code) || c.eval.code_count >= len(c.eval.code_nodes) {
		compiler_fail_pool(c)
		return 0
	}
	pos := u32(c.eval.code_count)
	c.eval.code[pos] = inst
	c.eval.code_nodes[pos] = node_idx
	c.eval.code_count += 1
	return pos
}

// emit_abx_wide emits OP_EXTRA_ARG when idx > max(u16), then OP(a, u16(idx)).
@(private)
emit_abx_wide :: proc "contextless" (c: ^Compiler, op: Opcode, a: u8, idx: u32, node_idx: lex_parser.Node_Index) {
	if idx > u32(max(u16)) {
		emit(c, inst_ax(.Extra_Arg, idx), node_idx)
		emit(c, inst_abx(op, a, 0), node_idx)
		return
	}
	emit(c, inst_abx(op, a, u16(idx)), node_idx)
}

@(private)
emit_jmp :: proc "contextless" (c: ^Compiler, op: Opcode, a: u8, node_idx: lex_parser.Node_Index) -> u32 {
	return emit(c, inst_asbx(op, a, 0), node_idx)
}

@(private)
patch_jmp :: proc "contextless" (c: ^Compiler, jmp_pos: u32, node_idx: lex_parser.Node_Index) {
	_ = node_idx
	if c.failed {
		return
	}
	target := u32(c.eval.code_count)
	delta := i64(target) - i64(jmp_pos) - 1
	if delta < i64(min(i16)) || delta > i64(max(i16)) {
		// Never relocate already-emitted code (would invalidate earlier jump
		// offsets); refuse jumps exceeding the 16-bit signed displacement cleanly.
		compiler_fail_pool(c)
		return
	}
	old := c.eval.code[jmp_pos]
	op, _ := inst_op(old)
	c.eval.code[jmp_pos] = inst_asbx(op, inst_a(old), i16(delta))
}

@(private)
reserve_reg :: proc "contextless" (c: ^Compiler, reg: u8) {
	sc := cur_scope(c)
	if reg + 1 > sc.max_regs {
		sc.max_regs = reg + 1
	}
}

@(private)
intern_str :: proc "contextless" (c: ^Compiler, text: string) -> lex_parser.Sym_Id {
	sym, ok := lex_parser.intern(&c.eval.interner, text)
	if !ok {
		compiler_fail_pool(c)
		return lex_parser.NO_SYM
	}
	return sym
}

@(private)
add_const :: proc "contextless" (c: ^Compiler, entry: Const_Entry) -> u32 {
	if c.eval.const_count >= len(c.eval.consts) {
		compiler_fail_pool(c)
		return 0
	}
	idx := u32(c.eval.const_count) - c.chunk.const_start
	c.eval.consts[c.eval.const_count] = entry
	c.eval.const_count += 1
	return idx
}

@(private)
add_field_sym :: proc "contextless" (c: ^Compiler, sym: lex_parser.Sym_Id) -> u32 {
	// Reuse existing entry in current chunk when small for compact bytecode.
	start := int(c.chunk.field_sym_start)
	limit := min(c.eval.field_sym_count, start + 64)
	for i in start ..< limit {
		if c.eval.field_syms[i] == sym {
			return u32(i - start)
		}
	}
	if c.eval.field_sym_count >= len(c.eval.field_syms) {
		compiler_fail_pool(c)
		return 0
	}
	idx := u32(c.eval.field_sym_count) - c.chunk.field_sym_start
	c.eval.field_syms[c.eval.field_sym_count] = sym
	c.eval.field_sym_count += 1
	return idx
}

@(private)
emit_get_field :: proc "contextless" (c: ^Compiler, dst, base: u8, field_name: string, node_idx: lex_parser.Node_Index) {
	sym := intern_str(c, field_name)
	sym_idx := add_field_sym(c, sym)
	if sym_idx < 255 {
		emit(c, inst_abc(.Get_Field, dst, base, u8(sym_idx)), node_idx)
	} else {
		emit(c, inst_ax(.Extra_Arg, sym_idx), node_idx)
		emit(c, inst_abc(.Get_Field, dst, base, 255), node_idx)
	}
}

// Upvalue / lexical name resolution walking up the active Fn_Scope stack.
@(private)
add_upval :: proc "contextless" (c: ^Compiler, scope_idx: int, desc: Upval_Desc) -> u16 {
	sc := &c.scopes[scope_idx]
	// Deduplicate existing upvalues of this scope.
	for i in 0 ..< sc.upval_count {
		if c.scratch.upval_work[sc.upval_start + i] == desc {
			return u16(i)
		}
	}
	// Note: upval_work is stacked per Fn_Scope; since parent scopes may gain
	// transitive upvalues while a child compiles, each scope reserves its own
	// upval slice OR we scan/store in a compact per-proto list.
	// Wait: if parent scope_idx < c.scope_count - 1, its upval_start is BELOW
	// child's upval_start! To allow arbitrary transitive upvalue additions to
	// ANY ancestor scope without collision, store upvalues directly in
	// c.eval.upvals using a small linked or shifted array? No: max upvalues per
	// scope is small, OR shift upval_work right by 1 (typical upval_work_used < 64)!
	if c.upval_work_used >= len(c.scratch.upval_work) {
		compiler_fail_pool(c)
		return 0
	}
	insert_at := sc.upval_start + sc.upval_count
	for j := c.upval_work_used; j > insert_at; j -= 1 {
		c.scratch.upval_work[j] = c.scratch.upval_work[j - 1]
	}
	c.scratch.upval_work[insert_at] = desc
	c.upval_work_used += 1
	sc.upval_count += 1
	// Shift upval_start of deeper scopes by +1.
	for k := scope_idx + 1; k < c.scope_count; k += 1 {
		c.scopes[k].upval_start += 1
	}
	return u16(sc.upval_count - 1)
}

@(private)
resolve_sym_in_scope :: proc "contextless" (c: ^Compiler, scope_idx: int, sym: lex_parser.Sym_Id) -> Resolve_Result {
	sc := &c.scopes[scope_idx]
	// 1. Search active let scopes from innermost to outermost.
	ls := sc.current_let_scope
	for ls >= 0 {
		lscope := c.scratch.let_scopes[ls]
		start := int(lscope.locals_start)
		for i := int(lscope.locals_count) - 1; i >= 0; i -= 1 {
			if c.scratch.locals[start + i].sym == sym {
				return {kind = .Local_Let, index = c.scratch.locals[start + i].slot}
			}
		}
		ls = lscope.parent
	}
	// 2. Search function parameters of this scope.
	for p in 0 ..< int(sc.param_count) {
		if sc.param_syms[p] == sym {
			return {kind = .Local_Param, index = u16(p)}
		}
	}
	// 3. Recurse into enclosing scope and capture as upvalue.
	if scope_idx > 0 {
		parent_res := resolve_sym_in_scope(c, scope_idx - 1, sym)
		switch parent_res.kind {
		case .Global:
			return {kind = .Global}
		case .Local_Let:
			uv := add_upval(c, scope_idx, {source = .Parent_Let, index = parent_res.index})
			return {kind = .Upval, index = uv}
		case .Local_Param:
			c.scopes[scope_idx - 1].boxed_param_mask |= (u16(1) << parent_res.index)
			uv := add_upval(c, scope_idx, {source = .Parent_Boxed_Param, index = parent_res.index})
			return {kind = .Upval, index = uv}
		case .Upval:
			uv := add_upval(c, scope_idx, {source = .Parent_Upval, index = parent_res.index})
			return {kind = .Upval, index = uv}
		}
	}
	return {kind = .Global}
}

@(private)
enqueue_pending :: proc "contextless" (c: ^Compiler, item: Pending_Proto) -> bool {
	if c.pending_count >= len(c.scratch.pending) {
		compiler_fail_pool(c)
		return false
	}
	c.scratch.pending[c.pending_count] = item
	c.pending_count += 1
	return true
}

@(private)
compile_proto_body :: proc "contextless" (c: ^Compiler, item: Pending_Proto) {
	if c.failed {
		return
	}
	if c.scope_count >= MAX_COMPILE_SCOPES {
		compiler_fail_pool(c)
		return
	}
	// Set parent scope's active let_scope while this child compiles so upvalue
	// resolution sees the exact lexical let bindings visible at the child's site.
	saved_parent_let: i32 = -1
	if c.scope_count > 0 {
		saved_parent_let = c.scopes[c.scope_count - 1].current_let_scope
		c.scopes[c.scope_count - 1].current_let_scope = item.parent_let_scope
	}

	sc_idx := c.scope_count
	c.scope_count += 1
	sc := &c.scopes[sc_idx]
	sc^ = {
		proto_idx         = item.proto_idx,
		param_count       = item.param_count,
		param_syms        = item.param_syms,
		current_let_scope = -1,
		upval_start       = c.upval_work_used,
		reg_top           = u8(item.param_count),
		max_regs          = u8(max(int(item.param_count), 1)),
		pending_start     = c.pending_count,
	}

	code_start := u32(c.eval.code_count)
	// Lower any destructuring function parameters (`({ a, b = 10, ... }) => ...`)
	// into OP_DESTRUCTURE instructions before compiling the function body.
	if item.kind == .Function_Body {
		for pi in 0 ..< int(item.param_count) {
			pat_node := item.param_patterns[pi]
			if pat_node != lex_parser.NO_NODE && pat_node != 0 {
				// Note: check node kind because NO_NODE is -1 while zero-init is 0.
				if pn := lex_parser.node_at(c.tree, pat_node); pn != nil && pn.kind == .Pattern_Record {
					compile_pattern_destructure(c, pat_node, u8(pi))
				}
			}
		}
	}
	dst := u8(item.param_count)
	reserve_reg(c, dst)
	compile_expr(c, item.ast_node, dst, true)
	emit(c, inst_abc(.Ret, dst, 0, 0), item.ast_node)
	code_len := u32(c.eval.code_count) - code_start

	// Compile all child Protos (functions, let RHS thunks, record field thunks,
	// call-site expr args) while this Fn_Scope is still live on the scope stack!
	pending_end := c.pending_count
	for p := sc.pending_start; p < pending_end && !c.failed; p += 1 {
		child := c.scratch.pending[p]
		compile_proto_body(c, child)
	}
	c.pending_count = sc.pending_start

	// Commit finalized upvalues and metadata into eval.protos[item.proto_idx].
	if !c.failed {
		if c.eval.upval_count + sc.upval_count > len(c.eval.upvals) {
			compiler_fail_pool(c)
		} else {
			uv_off := u32(c.eval.upval_count)
			for i in 0 ..< sc.upval_count {
				c.eval.upvals[c.eval.upval_count] = c.scratch.upval_work[sc.upval_start + i]
				c.eval.upval_count += 1
			}
			c.eval.protos[item.proto_idx] = {
				code_start       = code_start,
				code_len         = code_len,
				max_regs         = u16(sc.max_regs),
				param_count      = sc.param_count,
				let_slot_count   = sc.next_let_slot,
				boxed_param_mask = sc.boxed_param_mask,
				upval_start      = uv_off,
				upval_count      = u16(sc.upval_count),
				param_syms       = item.param_syms,
				node_idx         = item.kind == .Function_Body ? item.fn_node : item.ast_node,
				fn_open_off      = item.fn_open_off,
				fn_arrow_end     = item.fn_arrow_end,
			}
		}
	}

	c.upval_work_used = sc.upval_start
	c.scope_count -= 1
	if c.scope_count > 0 {
		c.scopes[c.scope_count - 1].current_let_scope = saved_parent_let
	}
}

@(private)
compile_name_load :: proc "contextless" (c: ^Compiler, full_name: string, dst: u8, node_idx: lex_parser.Node_Index) -> (is_lexical: bool) {
	reserve_reg(c, dst)
	sym := intern_str(c, full_name)
	res := resolve_sym_in_scope(c, c.scope_count - 1, sym)
	if res.kind != .Global {
		emit_resolve_load(c, res, dst, node_idx)
		return true
	}
	// Check dotted prefix (e.g. `s.width`, `lib.scale`, `r.score`).
	dot := -1
	for i in 0 ..< len(full_name) {
		if full_name[i] == '.' {
			dot = i
			break
		}
	}
	if dot > 0 && dot + 1 < len(full_name) {
		prefix_sym := intern_str(c, full_name[:dot])
		pres := resolve_sym_in_scope(c, c.scope_count - 1, prefix_sym)
		if pres.kind != .Global {
			emit_resolve_load(c, pres, dst, node_idx)
			rest := full_name[dot + 1:]
			for len(rest) > 0 {
				next_dot := -1
				for i in 0 ..< len(rest) {
					if rest[i] == '.' {
						next_dot = i
						break
					}
				}
				seg := next_dot < 0 ? rest : rest[:next_dot]
				if len(seg) > 0 {
					emit_get_field(c, dst, dst, seg, node_idx)
				}
				if next_dot < 0 {
					break
				}
				rest = rest[next_dot + 1:]
			}
			return true
		}
	}
	return false
}

@(private)
emit_resolve_load :: proc "contextless" (c: ^Compiler, res: Resolve_Result, dst: u8, node_idx: lex_parser.Node_Index) {
	switch res.kind {
	case .Global:
	case .Local_Param:
		if dst != u8(res.index) {
			emit(c, inst_abc(.Move, dst, u8(res.index), 0), node_idx)
		}
	case .Local_Let:
		emit(c, inst_abx(.Get_Let, dst, res.index), node_idx)
	case .Upval:
		emit(c, inst_abx(.Get_Upval, dst, res.index), node_idx)
	}
}

@(private)
compile_expr :: proc "contextless" (c: ^Compiler, node_idx: lex_parser.Node_Index, dst: u8, in_tail: bool) {
	if c.failed {
		return
	}
	reserve_reg(c, dst)
	node := lex_parser.node_at(c.tree, node_idx)
	if node == nil {
		emit(c, inst_abx(.Refuse_Parse, dst, u16(max(u16))), node_idx)
		return
	}

	switch node.kind {
	case .Integer:
		v := lex_parser.node_integer(c.tree, node_idx)
		if v >= i64(min(i16)) && v <= i64(max(i16)) {
			emit(c, inst_asbx(.Load_Int_Imm, dst, i16(v)), node_idx)
		} else {
			ci := add_const(c, {kind = .Integer, integer = v})
			emit_abx_wide(c, .Load_Const, dst, ci, node_idx)
		}

	case .Boolean:
		v := lex_parser.node_integer(c.tree, node_idx)
		emit(c, inst_abc(.Load_Bool, dst, v != 0 ? 1 : 0, 0), node_idx)

	case .Text:
		start, end := lex_parser.node_span(c.tree, node_idx)
		is_segment := (node.sub & lex_parser.TEXT_FLAG_SEGMENT) != 0
		inner_start := is_segment ? start : min(start + 1, end)
		inner_end := is_segment ? end : max(end - 1, inner_start)
		if (node.sub & lex_parser.TEXT_FLAG_ESCAPED) != 0 {
			raw := c.tree.text[inner_start:inner_end]
			need, _, dec_ok := lex_parser.decode_text_escapes(raw, nil)
			if !dec_ok {
				emit_abx_wide(c, .Refuse_Parse, dst, u32(node_idx), node_idx)
				return
			}
			if need == 0 {
				ci := add_const(c, {kind = .Text, offset = 0, length = 0})
				emit_abx_wide(c, .Load_Const, dst, ci, node_idx)
			} else if need > len(c.eval.text_arena) - c.eval.text_used {
				compiler_fail_pool(c)
				return
			} else {
				aoff := c.eval.text_used
				written, _, _ := lex_parser.decode_text_escapes(raw, c.eval.text_arena[aoff:aoff + need])
				c.eval.text_used += written
				ci := add_const(c, {kind = .Arena_Text, offset = u32(aoff), length = u32(written)})
				emit_abx_wide(c, .Load_Const, dst, ci, node_idx)
			}
		} else {
			ci := add_const(c, {kind = .Text, offset = u32(inner_start), length = u32(inner_end - inner_start)})
			emit_abx_wide(c, .Load_Const, dst, ci, node_idx)
		}

	case .Text_Interp:
		children := lex_parser.node_children(c.tree, node_idx)
		emit(c, inst_abc(.Str_Begin, 0, 0, 0), node_idx)
		for child in children {
			compile_expr(c, child, dst, false)
			emit(c, inst_abc(.Str_Push, dst, 0, 0), child)
		}
		emit(c, inst_abc(.Str_End, dst, 0, 0), node_idx)

	case .Hash:
		start, end := lex_parser.node_span(c.tree, node_idx)
		decoded, valid := console_language.hash_value(c.tree.text, start, end)
		if !valid {
			emit_abx_wide(c, .Refuse_Parse, dst, u32(node_idx), node_idx)
			return
		}
		ci := add_const(c, {kind = .Hash, hash = decoded})
		emit_abx_wide(c, .Load_Const, dst, ci, node_idx)

	case .Member:
		raw := lex_parser.node_text(c.tree, node_idx)
		name := len(raw) > 0 && raw[0] == '.' ? raw[1:] : raw
		sym := intern_str(c, name)
		ci := add_const(c, {kind = .Member, offset = u32(sym), length = u32(node_idx)})
		emit_abx_wide(c, .Load_Const, dst, ci, node_idx)

	case .Name:
		name := lex_parser.node_text(c.tree, node_idx)
		if !compile_name_load(c, name, dst, node_idx) {
			sym := intern_str(c, name)
			ci := add_const(c, {kind = .Sym, offset = u32(sym)})
			emit_abx_wide(c, .Load_Global, dst, ci, node_idx)
		}

	case .Field_Select:
		base := lex_parser.node_child(c.tree, node_idx)
		compile_expr(c, base, dst, false)
		emit_get_field(c, dst, dst, lex_parser.node_text(c.tree, node_idx), node_idx)

	case .Negate:
		child := lex_parser.node_child(c.tree, node_idx)
		compile_expr(c, child, dst, false)
		emit(c, inst_abc(.Neg, dst, dst, 0), node_idx)

	case .Logical_Not:
		child := lex_parser.node_child(c.tree, node_idx)
		compile_expr(c, child, dst, false)
		emit(c, inst_abc(.Not, dst, dst, 0), node_idx)

	case .Binary:
		left, right := lex_parser.node_binary_children(c.tree, node_idx)
		op := lex_parser.node_operator(c.tree, node_idx)
		if op == .Logical_And {
			compile_expr(c, left, dst, false)
			jmp_end := emit_jmp(c, .Jmp_If_False_Keep, dst, node_idx)
			compile_expr(c, right, dst, false)
			emit(c, inst_abc(.Check_Bool, dst, u8(lex_parser.Operator.Logical_And), 0), node_idx)
			patch_jmp(c, jmp_end, node_idx)
			return
		}
		if op == .Logical_Or {
			compile_expr(c, left, dst, false)
			jmp_end := emit_jmp(c, .Jmp_If_True_Keep, dst, node_idx)
			compile_expr(c, right, dst, false)
			emit(c, inst_abc(.Check_Bool, dst, u8(lex_parser.Operator.Logical_Or), 0), node_idx)
			patch_jmp(c, jmp_end, node_idx)
			return
		}
		compile_expr(c, left, dst, false)
		if dst == 255 {
			compiler_fail_pool(c)
			return
		}
		tmp := dst + 1
		reserve_reg(c, tmp)
		compile_expr(c, right, tmp, false)
		vm_op: Opcode
		switch op {
		case .Add:              vm_op = .Add
		case .Subtract:         vm_op = .Sub
		case .Multiply:         vm_op = .Mul
		case .Divide:           vm_op = .Div
		case .Remainder:        vm_op = .Rem
		case .List_Concat:      vm_op = .List_Concat
		case .Equal:            vm_op = .Eq
		case .Not_Equal:        vm_op = .Neq
		case .Less:             vm_op = .Lt
		case .Less_Or_Equal:    vm_op = .Le
		case .Greater:          vm_op = .Gt
		case .Greater_Or_Equal: vm_op = .Ge
		case .With:             vm_op = .With
		case .Logical_And, .Logical_Or, .None:
			emit_abx_wide(c, .Refuse_Parse, dst, u32(node_idx), node_idx)
			return
		}
		emit(c, inst_abc(vm_op, dst, dst, tmp), node_idx)

	case .If:
		children := lex_parser.node_children(c.tree, node_idx)
		cond_node := len(children) > 0 ? children[0] : lex_parser.NO_NODE
		then_node := len(children) > 1 ? children[1] : lex_parser.NO_NODE
		else_node := len(children) > 2 ? children[2] : lex_parser.NO_NODE
		compile_expr(c, cond_node, dst, false)
		if then_node == lex_parser.NO_NODE {
			emit_abx_wide(c, .Refuse_Parse, dst, u32(node_idx), node_idx)
			return
		}
		if tn := lex_parser.node_at(c.tree, then_node); tn != nil && tn.kind == .Refused {
			compile_expr(c, then_node, dst, false)
			return
		}
		if else_node == lex_parser.NO_NODE {
			emit_abx_wide(c, .Refuse_Parse, dst, u32(node_idx), node_idx)
			return
		}
		if en := lex_parser.node_at(c.tree, else_node); en != nil && en.kind == .Refused {
			compile_expr(c, else_node, dst, false)
			return
		}
		jmp_else := emit_jmp(c, .Jmp_If_False, dst, cond_node)
		compile_expr(c, then_node, dst, in_tail)
		if in_tail {
			emit(c, inst_abc(.Ret, dst, 0, 0), then_node)
			patch_jmp(c, jmp_else, cond_node)
			compile_expr(c, else_node, dst, true)
		} else {
			jmp_end := emit_jmp(c, .Jmp, 0, node_idx)
			patch_jmp(c, jmp_else, cond_node)
			compile_expr(c, else_node, dst, false)
			patch_jmp(c, jmp_end, node_idx)
		}

	case .Let:
		compile_let(c, node_idx, dst, in_tail)

	case .Function:
		if refused_node := refusal_inside_ast(c.tree, node_idx); refused_node != lex_parser.NO_NODE {
			emit_abx_wide(c, .Refuse_Parse, dst, u32(refused_node), refused_node)
			return
		}
		compile_function(c, node_idx, dst)

	case .Record_Literal:
		compile_record_literal(c, node_idx, dst)

	case .List_Literal:
		children := lex_parser.node_children(c.tree, node_idx)
		emit(c, inst_abc(.List_Begin, 0, 0, 0), node_idx)
		for child in children {
			compile_expr(c, child, dst, false)
			emit(c, inst_abc(.List_Push, dst, 0, 0), child)
		}
		emit(c, inst_abc(.List_End, dst, 0, 0), node_idx)

	case .Pipe:
		lhs, rhs := lex_parser.node_binary_children(c.tree, node_idx)
		rn := lex_parser.node_at(c.tree, rhs)
		if rn == nil || rn.kind != .Call {
			emit_abx_wide(c, .Refuse_Parse, dst, u32(rhs != lex_parser.NO_NODE ? rhs : node_idx), node_idx)
			return
		}
		compile_call(c, rhs, lhs, dst, in_tail)

	case .Call:
		compile_call(c, node_idx, lex_parser.NO_NODE, dst, in_tail)

	case .Refused:
		if before := lex_parser.node_child(c.tree, node_idx); before != lex_parser.NO_NODE {
			compile_expr(c, before, dst, false)
		}
		emit_abx_wide(c, .Refuse_Parse, dst, u32(node_idx), node_idx)

	case .Condition, .Fact_Name, .Field_Names, .Literal_Field, .Named_Argument, .Let_Binding, .Parameter, .Placeholder, .Pattern_Record, .Pattern_Field:
		emit_abx_wide(c, .Refuse_Parse, dst, u32(node_idx), node_idx)
	}
}

// compile_pattern_destructure allocates let-slots and a Pattern_Desc for a
// `.Pattern_Record` node, registers its bound names in a new Compile_Let_Scope,
// and emits `OP_DESTRUCTURE(src_reg, pat_desc_rel)`.
@(private)
compile_pattern_destructure :: proc "contextless" (c: ^Compiler, pat_node: lex_parser.Node_Index, src_reg: u8) {
	pn := lex_parser.node_at(c.tree, pat_node)
	if pn == nil || pn.kind != .Pattern_Record {
		return
	}
	has_rest := (pn.sub & lex_parser.PAT_FLAG_REST) != 0
	has_as := (pn.sub & lex_parser.PAT_FLAG_HAS_AS) != 0
	children := lex_parser.node_children(c.tree, pat_node)
	field_count := 0
	for ch in children {
		if cn := lex_parser.node_at(c.tree, ch); cn != nil && cn.kind == .Pattern_Field {
			field_count += 1
		}
	}
	total_slots := field_count + (has_as ? 1 : 0)
	sc := cur_scope(c)
	if c.local_count + total_slots > len(c.scratch.locals) ||
	   c.let_scope_count >= len(c.scratch.let_scopes) ||
	   c.eval.pat_desc_count >= len(c.eval.pat_descs) ||
	   c.eval.pat_field_count + field_count > len(c.eval.pat_fields) ||
	   int(sc.next_let_slot) + total_slots > int(max(u16)) {
		compiler_fail_pool(c)
		return
	}

	// Default expressions evaluate in the enclosing scope (before the pattern's
	// own bindings enter scope, so earlier params/lets are visible).
	enclosing_ls := sc.current_let_scope

	locals_start := u32(c.local_count)
	fields_start := u32(c.eval.pat_field_count)
	as_slot := u16(0)

	for ch in children {
		cn := lex_parser.node_at(c.tree, ch)
		if cn == nil {
			continue
		}
		if cn.kind == .Parameter && has_as {
			as_sym := intern_str(c, lex_parser.node_text(c.tree, ch))
			as_slot = sc.next_let_slot
			sc.next_let_slot += 1
			c.scratch.locals[c.local_count] = {sym = as_sym, slot = as_slot}
			c.local_count += 1
		} else if cn.kind == .Pattern_Field {
			fsym := intern_str(c, lex_parser.node_text(c.tree, ch))
			fslot := sc.next_let_slot
			sc.next_let_slot += 1
			c.scratch.locals[c.local_count] = {sym = fsym, slot = fslot}
			c.local_count += 1

			def_node := lex_parser.node_child(c.tree, ch)
			has_def := def_node != lex_parser.NO_NODE
			def_proto_rel := u32(0)
			if has_def {
				p_idx, p_ok := alloc_proto(c, def_node)
				if !p_ok {
					return
				}
				def_proto_rel = p_idx - c.chunk.proto_start
				enqueue_pending(c, {
					kind             = .Expr_Proto,
					proto_idx        = p_idx,
					ast_node         = def_node,
					parent_let_scope = enclosing_ls,
				})
			}
			c.eval.pat_fields[c.eval.pat_field_count] = {
				sym           = fsym,
				let_slot      = fslot,
				has_default   = has_def,
				default_proto = def_proto_rel,
				node_idx      = ch,
			}
			c.eval.pat_field_count += 1
		}
	}

	pat_desc_rel := u32(c.eval.pat_desc_count) - c.chunk.pat_desc_start
	c.eval.pat_descs[c.eval.pat_desc_count] = {
		has_rest     = has_rest,
		has_as       = has_as,
		as_let_slot  = as_slot,
		fields_start = fields_start,
		field_count  = u16(field_count),
		node_idx     = pat_node,
	}
	c.eval.pat_desc_count += 1

	// Emit OP_DESTRUCTURE before activating the new scope (already runs at runtime
	// before body uses the new slots).
	emit_abx_wide(c, .Destructure, src_reg, pat_desc_rel, pat_node)

	if total_slots > 0 {
		new_scope_id := i32(c.let_scope_count)
		c.scratch.let_scopes[c.let_scope_count] = {
			parent       = enclosing_ls,
			locals_start = locals_start,
			locals_count = u32(total_slots),
		}
		c.let_scope_count += 1
		sc.current_let_scope = new_scope_id
	}
}

@(private)
compile_let :: proc "contextless" (c: ^Compiler, node_idx: lex_parser.Node_Index, dst: u8, in_tail: bool) {
	children := lex_parser.node_children(c.tree, node_idx)
	body := lex_parser.NO_NODE
	binding_count := 0
	has_pattern := false
	for child in children {
		cn := lex_parser.node_at(c.tree, child)
		if cn != nil && cn.kind == .Let_Binding {
			binding_count += 1
			if _, is_pat := lex_parser.let_binding_pattern(c.tree, child); is_pat {
				has_pattern = true
			}
		} else {
			body = child
		}
	}

	sc := cur_scope(c)
	prev_let_scope := sc.current_let_scope

	if binding_count > 0 {
		if c.local_count + binding_count > len(c.scratch.locals) ||
		   c.let_scope_count >= len(c.scratch.let_scopes) ||
		   c.eval.let_desc_count >= len(c.eval.let_descs) ||
		   c.eval.let_proto_count + binding_count > len(c.eval.let_protos) ||
		   int(sc.next_let_slot) + binding_count > int(max(u16)) {
			compiler_fail_pool(c)
			return
		}
		slot_start := sc.next_let_slot
		sc.next_let_slot += u16(binding_count)
		locals_start := u32(c.local_count)
		protos_start := u32(c.eval.let_proto_count)

		// Register all plain binding names FIRST so mutual recursion resolves cleanly.
		// Pattern bindings receive a hidden RHS slot (NO_SYM) destructured right after Let_Enter.
		b_idx := 0
		plain_registered := 0
		for child in children {
			cn := lex_parser.node_at(c.tree, child)
			if cn == nil || cn.kind != .Let_Binding {
				continue
			}
			if _, is_pat := lex_parser.let_binding_pattern(c.tree, child); is_pat {
				c.eval.let_syms[int(protos_start) + b_idx] = lex_parser.NO_SYM
				c.eval.let_nodes[int(protos_start) + b_idx] = child
			} else {
				b_sym := intern_str(c, lex_parser.node_text(c.tree, child))
				c.scratch.locals[c.local_count] = {sym = b_sym, slot = slot_start + u16(b_idx)}
				c.local_count += 1
				plain_registered += 1
				c.eval.let_syms[int(protos_start) + b_idx] = b_sym
				c.eval.let_nodes[int(protos_start) + b_idx] = child
			}
			b_idx += 1
		}

		new_scope_id := prev_let_scope
		if plain_registered > 0 {
			new_scope_id = i32(c.let_scope_count)
			c.scratch.let_scopes[c.let_scope_count] = {
				parent       = prev_let_scope,
				locals_start = locals_start,
				locals_count = u32(plain_registered),
			}
			c.let_scope_count += 1
			sc.current_let_scope = new_scope_id
		}

		// Allocate child Proto for each binding RHS (with visibility = new_scope_id).
		b_idx = 0
		for child in children {
			cn := lex_parser.node_at(c.tree, child)
			if cn == nil || cn.kind != .Let_Binding {
				continue
			}
			rhs := lex_parser.node_child(c.tree, child)
			p_idx, p_ok := alloc_proto(c, rhs)
			if !p_ok {
				return
			}
			c.eval.let_protos[int(protos_start) + b_idx] = p_idx - c.chunk.proto_start
			enqueue_pending(c, {
				kind             = .Expr_Proto,
				proto_idx        = p_idx,
				ast_node         = rhs,
				parent_let_scope = new_scope_id,
			})
			b_idx += 1
		}
		c.eval.let_proto_count += binding_count

		desc_rel := u32(c.eval.let_desc_count) - c.chunk.let_desc_start
		c.eval.let_descs[c.eval.let_desc_count] = {
			slot_start    = slot_start,
			binding_count = u16(binding_count),
			protos_start  = protos_start,
			syms_start    = protos_start,
			nodes_start   = protos_start,
		}
		c.eval.let_desc_count += 1
		emit_abx_wide(c, .Let_Enter, 0, desc_rel, node_idx)

		// Lower each pattern binding: force RHS to WHNF and destructure into let-slots.
		if has_pattern {
			b_idx = 0
			for child in children {
				cn := lex_parser.node_at(c.tree, child)
				if cn == nil || cn.kind != .Let_Binding {
					continue
				}
				if pat_node, is_pat := lex_parser.let_binding_pattern(c.tree, child); is_pat {
					emit(c, inst_abx(.Get_Let, dst, slot_start + u16(b_idx)), child)
					compile_pattern_destructure(c, pat_node, dst)
				}
				b_idx += 1
			}
		}
	}

	if body == lex_parser.NO_NODE {
		emit_abx_wide(c, .Refuse_Parse, dst, u32(node_idx), node_idx)
	} else {
		compile_expr(c, body, dst, in_tail)
	}
	sc.current_let_scope = prev_let_scope
}

@(private)
compile_function :: proc "contextless" (c: ^Compiler, node_idx: lex_parser.Node_Index, dst: u8) {
	children := lex_parser.node_children(c.tree, node_idx)
	param_syms: [lex_parser.ARGUMENT_CAPACITY]lex_parser.Sym_Id
	param_patterns: [lex_parser.ARGUMENT_CAPACITY]lex_parser.Node_Index
	for i in 0 ..< lex_parser.ARGUMENT_CAPACITY {
		param_patterns[i] = lex_parser.NO_NODE
	}
	param_count := u16(0)
	body := lex_parser.NO_NODE
	for child in children {
		cn := lex_parser.node_at(c.tree, child)
		if cn != nil && cn.kind == .Parameter {
			if int(param_count) < lex_parser.ARGUMENT_CAPACITY {
				param_syms[param_count] = intern_str(c, lex_parser.node_text(c.tree, child))
				param_count += 1
			}
		} else if cn != nil && cn.kind == .Pattern_Record {
			if int(param_count) < lex_parser.ARGUMENT_CAPACITY {
				param_syms[param_count] = lex_parser.NO_SYM
				param_patterns[param_count] = child
				param_count += 1
			}
		} else {
			body = child
		}
	}
	p_idx, p_ok := alloc_proto(c, node_idx)
	if !p_ok {
		return
	}
	open_off, arrow_end := lex_parser.node_function_offsets(c.tree, node_idx)
	enqueue_pending(c, {
		kind             = .Function_Body,
		proto_idx        = p_idx,
		ast_node         = body,
		parent_let_scope = cur_scope(c).current_let_scope,
		param_count      = param_count,
		param_syms       = param_syms,
		param_patterns   = param_patterns,
		fn_node          = node_idx,
		fn_open_off      = u32(open_off),
		fn_arrow_end     = u32(arrow_end),
	})
	emit_abx_wide(c, .Closure, dst, p_idx - c.chunk.proto_start, node_idx)
}

@(private)
str_cmp :: proc "contextless" (a, b: string) -> int {
	n := min(len(a), len(b))
	for i in 0 ..< n {
		if a[i] < b[i] {
			return -1
		}
		if a[i] > b[i] {
			return 1
		}
	}
	if len(a) < len(b) {
		return -1
	}
	if len(a) > len(b) {
		return 1
	}
	return 0
}

// In-place heapsort of Rec_Sort_Entry by canonical ascending UTF-8 byte order
// of interned symbol text (never by Sym_Id!).
@(private)
sort_record_entries_utf8 :: proc "contextless" (interner: ^lex_parser.String_Interner, items: []Rec_Sort_Entry) {
	less :: proc "contextless" (interner: ^lex_parser.String_Interner, a, b: Rec_Sort_Entry) -> bool {
		return str_cmp(lex_parser.sym_text(interner, a.sym), lex_parser.sym_text(interner, b.sym)) < 0
	}
	sift_down :: proc "contextless" (interner: ^lex_parser.String_Interner, items: []Rec_Sort_Entry, start, end: int) {
		root := start
		for root * 2 + 1 < end {
			child := root * 2 + 1
			swap_idx := root
			if less(interner, items[swap_idx], items[child]) {
				swap_idx = child
			}
			if child + 1 < end && less(interner, items[swap_idx], items[child + 1]) {
				swap_idx = child + 1
			}
			if swap_idx == root {
				return
			}
			items[root], items[swap_idx] = items[swap_idx], items[root]
			root = swap_idx
		}
	}
	n := len(items)
	for start := n / 2 - 1; start >= 0; start -= 1 {
		sift_down(interner, items, start, n)
	}
	for end := n - 1; end > 0; end -= 1 {
		items[0], items[end] = items[end], items[0]
		sift_down(interner, items, 0, end)
	}
}

// build_record_desc compiles a Record_Literal into a canonical UTF-8 sorted
// Record_Shape and Record_Desc. Returns the Record_Desc index relative to
// chunk.rec_desc_start (or refused_node != NO_NODE if a parse refusal exists).
@(private)
build_record_desc :: proc "contextless" (c: ^Compiler, node_idx: lex_parser.Node_Index) -> (desc_rel: u32, refused_node: lex_parser.Node_Index, ok: bool) {
	children := lex_parser.node_children(c.tree, node_idx)
	for child in children {
		if cn := lex_parser.node_at(c.tree, child); cn != nil && cn.kind == .Refused {
			return 0, child, false
		}
	}
	field_count := len(children)
	if field_count > len(c.scratch.rec_sort) ||
	   c.eval.shape_count >= len(c.eval.shapes) ||
	   c.eval.shape_field_count + field_count > len(c.eval.shape_fields) ||
	   c.eval.rec_desc_count >= len(c.eval.rec_descs) ||
	   c.eval.rec_field_proto_count + field_count > len(c.eval.rec_field_protos) {
		compiler_fail_pool(c)
		return 0, lex_parser.NO_NODE, false
	}

	parent_ls := cur_scope(c).current_let_scope
	entries := c.scratch.rec_sort[:field_count]
	for child, i in children {
		sym := intern_str(c, lex_parser.node_text(c.tree, child))
		val_node := lex_parser.node_child(c.tree, child)
		p_idx, p_ok := alloc_proto(c, val_node)
		if !p_ok {
			return 0, lex_parser.NO_NODE, false
		}
		enqueue_pending(c, {
			kind             = .Expr_Proto,
			proto_idx        = p_idx,
			ast_node         = val_node,
			parent_let_scope = parent_ls,
		})
		entries[i] = {
			sym     = sym,
			proto   = p_idx - c.chunk.proto_start,
			node    = child,
			src_idx = u32(i),
		}
	}

	if field_count > 1 {
		sort_record_entries_utf8(&c.eval.interner, entries)
	}

	// Store canonical shape fields + deterministic shape hash.
	fields_off := u32(c.eval.shape_field_count)
	protos_off := u32(c.eval.rec_field_proto_count)
	shape_h := u64(0xcbf29ce484222325)
	for e, ci in entries {
		c.eval.shape_fields[int(fields_off) + ci] = e.sym
		c.eval.rec_field_protos[int(protos_off) + ci] = e.proto
		c.eval.rec_field_nodes[int(protos_off) + ci] = e.node
		c.eval.rec_source_orders[int(protos_off) + int(e.src_idx)] = u32(ci)
		txt := lex_parser.sym_text(&c.eval.interner, e.sym)
		for b in transmute([]u8)txt {
			shape_h = (shape_h ~ u64(b)) * 0x100000001b3
		}
		shape_h = (shape_h ~ 0xff) * 0x100000001b3
	}
	c.eval.shape_field_count += field_count
	c.eval.rec_field_proto_count += field_count

	shape_id := u32(c.eval.shape_count)
	c.eval.shapes[shape_id] = {
		fields_off  = fields_off,
		field_count = u32(field_count),
		shape_hash  = shape_h,
	}
	c.eval.shape_count += 1
	build_shape_hash_index(c.eval, shape_id)

	desc_rel = u32(c.eval.rec_desc_count) - c.chunk.rec_desc_start
	c.eval.rec_descs[c.eval.rec_desc_count] = {
		shape_id         = shape_id,
		field_count      = u32(field_count),
		protos_start     = protos_off,
		nodes_start      = protos_off,
		source_order_off = protos_off,
		literal_node     = node_idx,
	}
	c.eval.rec_desc_count += 1
	return desc_rel, lex_parser.NO_NODE, true
}

@(private)
compile_record_literal :: proc "contextless" (c: ^Compiler, node_idx: lex_parser.Node_Index, dst: u8) {
	desc_rel, refused_node, ok := build_record_desc(c, node_idx)
	if !ok {
		if refused_node != lex_parser.NO_NODE {
			// In Console mode, force earlier field expressions before refusing.
			if c.eval.mode == .Console {
				for child in lex_parser.node_children(c.tree, node_idx) {
					if child == refused_node {
						break
					}
					if cn := lex_parser.node_at(c.tree, child); cn != nil && cn.kind == .Literal_Field {
						compile_expr(c, lex_parser.node_child(c.tree, child), dst, false)
					}
				}
			}
			emit_abx_wide(c, .Refuse_Parse, dst, u32(refused_node), refused_node)
		}
		return
	}
	emit_abx_wide(c, .Make_Record, dst, desc_rel, node_idx)
}

@(private)
compile_call :: proc "contextless" (c: ^Compiler, call_idx: lex_parser.Node_Index, piped_lhs: lex_parser.Node_Index, dst: u8, in_tail: bool) {
	call_node := lex_parser.node_at(c.tree, call_idx)
	name := lex_parser.node_text(c.tree, call_idx)
	raw_children := lex_parser.node_children(c.tree, call_idx)
	has_placeholder := piped_lhs != lex_parser.NO_NODE && (call_node.sub & lex_parser.CALL_FLAG_HAS_PLACEHOLDER) != 0

	// Assemble effective arguments in evaluation order (substituting piped_lhs).
	arg_nodes: [lex_parser.ARGUMENT_CAPACITY + 2]lex_parser.Node_Index
	arg_named_placeholder: [lex_parser.ARGUMENT_CAPACITY + 2]bool
	arg_count := 0
	if piped_lhs != lex_parser.NO_NODE && !has_placeholder {
		arg_nodes[arg_count] = piped_lhs
		arg_count += 1
	}
	for child in raw_children {
		if arg_count >= len(arg_nodes) {
			break
		}
		cn := lex_parser.node_at(c.tree, child)
		if piped_lhs != lex_parser.NO_NODE && cn != nil && cn.kind == .Placeholder {
			arg_nodes[arg_count] = piped_lhs
			arg_count += 1
		} else if piped_lhs != lex_parser.NO_NODE && cn != nil && cn.kind == .Named_Argument {
			vn := lex_parser.node_at(c.tree, lex_parser.node_child(c.tree, child))
			arg_nodes[arg_count] = child
			if vn != nil && vn.kind == .Placeholder {
				arg_named_placeholder[arg_count] = true
			}
			arg_count += 1
		} else {
			arg_nodes[arg_count] = child
			arg_count += 1
		}
	}

	has_named := false
	has_special := false
	has_refused := false
	for i in 0 ..< arg_count {
		an := lex_parser.node_at(c.tree, arg_nodes[i])
		if an == nil {
			has_refused = true
			continue
		}
		switch an.kind {
		case .Named_Argument:
			has_named = true
		case .Condition, .Fact_Name, .Field_Names:
			has_special = true
		case .Refused:
			has_refused = true
		case .Integer, .Text, .Name, .Call, .Negate, .Binary, .Record_Literal, .Literal_Field,
		     .Let, .Let_Binding, .Member, .Function, .Parameter, .List_Literal, .Hash, .Boolean,
		     .If, .Field_Select, .Pipe, .Placeholder, .Logical_Not, .Text_Interp, .Pattern_Record, .Pattern_Field:
		}
	}

	// Check if callee is lexically bound (direct name or dotted prefix like `lib.scale`).
	name_sym := intern_str(c, name)
	is_lexical := resolve_sym_in_scope(c, c.scope_count - 1, name_sym).kind != .Global
	if !is_lexical {
		dot := -1
		for i in 0 ..< len(name) {
			if name[i] == '.' {
				dot = i
				break
			}
		}
		if dot > 0 && dot + 1 < len(name) {
			prefix_sym := intern_str(c, name[:dot])
			if resolve_sym_in_scope(c, c.scope_count - 1, prefix_sym).kind != .Global {
				is_lexical = true
			}
		}
	}

	// Fast path 1: pure positional call to a lexically-bound Lex function (supports TCO!).
	if is_lexical && !has_named && !has_special && !has_refused && arg_count <= lex_parser.ARGUMENT_CAPACITY && int(dst) + arg_count < 255 {
		compile_name_load(c, name, dst, call_idx)
		emit(c, inst_abc(.Check_Call, dst, u8(arg_count), 0), call_idx)
		for i in 0 ..< arg_count {
			reg := dst + u8(i + 1)
			reserve_reg(c, reg)
			compile_expr(c, arg_nodes[i], reg, false)
		}
		op: Opcode = in_tail ? .Tail_Call : .Call
		emit(c, inst_abc(op, dst, u8(arg_count), 0), call_idx)
		return
	}

	// Fast path 2a: compiler special forms `assert(cond, msg, value)` and `trace(msg, value)`.
	if !is_lexical && !has_named && !has_special && !has_refused && name == ASSERT_NAME && arg_count == 3 {
		compile_expr(c, arg_nodes[0], dst, false)
		jmp_ok := emit_jmp(c, .Jmp_If_True_Keep, dst, arg_nodes[0])
		// Condition was false: force msg and fail with Assertion_Failed.
		compile_expr(c, arg_nodes[1], dst, false)
		emit(c, inst_abc(.Assert_Fail, dst, 0, 0), call_idx)
		patch_jmp(c, jmp_ok, call_idx)
		// Condition was true: never force msg; evaluate value in tail position!
		compile_expr(c, arg_nodes[2], dst, in_tail)
		return
	}
	if !is_lexical && !has_named && !has_special && !has_refused && name == TRACE_NAME && arg_count == 2 {
		compile_expr(c, arg_nodes[0], dst, false)
		emit(c, inst_abc(.Trace, dst, 0, 0), call_idx)
		compile_expr(c, arg_nodes[1], dst, in_tail)
		return
	}

	// Fast path 2b: pure built-in stdlib calls.
	if !is_lexical && !has_named && !has_special && !has_refused && int(dst) + arg_count < 255 {
		bid := Builtin_Id.None
		expected_argc := -1
		switch name {
		case MAP_NAME:        bid, expected_argc = .Map, 2
		case FILTER_NAME:     bid, expected_argc = .Filter, 2
		case FOLD_NAME:       bid, expected_argc = .Fold, 3
		case ZIP_NAME:        bid, expected_argc = .Zip, 2
		case FIELDS_NAME:     bid, expected_argc = .Fields, 1
		case VALUES_NAME:     bid, expected_argc = .Values, 1
		case HAS_NAME:        bid, expected_argc = .Has, 2
		case EXTEND_NAME:     bid, expected_argc = .Extend, 2
		case MERGE_DEEP_NAME: bid, expected_argc = .Merge_Deep, 2
		}
		if bid != .None && arg_count == expected_argc {
			for i in 0 ..< arg_count {
				reg := dst + u8(i + 1)
				reserve_reg(c, reg)
				compile_expr(c, arg_nodes[i], reg, false)
			}
			emit(c, inst_abc(.Call_Builtin, dst, u8(bid), u8(arg_count)), call_idx)
			return
		}
	}

	// General Call_Site path (host commands, named args, console special forms,
	// record literal / enum member pre-validation, arity mismatches, partial parse).
	if c.eval.site_count >= len(c.eval.call_sites) || c.eval.site_arg_count + arg_count > len(c.eval.site_args) {
		compiler_fail_pool(c)
		return
	}

	callee_kind := Call_Site_Callee.Host_Or_Builtin
	if is_lexical {
		callee_kind = .Reg
		compile_name_load(c, name, dst, call_idx)
	}

	args_start := u32(c.eval.site_arg_count)
	parent_ls := cur_scope(c).current_let_scope
	for i in 0 ..< arg_count {
		an_idx := arg_nodes[i]
		an := lex_parser.node_at(c.tree, an_idx)
		sarg := Call_Site_Arg{node_idx = an_idx, val_node = an_idx}
		if an == nil || an.kind == .Refused {
			sarg.kind = .Refused
		} else {
			switch an.kind {
			case .Condition:
				sarg.kind = .Condition
			case .Fact_Name:
				sarg.kind = .Fact_Name
			case .Field_Names:
				sarg.kind = .Field_Names
			case .Named_Argument:
				sarg.is_named = true
				sarg.name_sym = intern_str(c, lex_parser.node_text(c.tree, an_idx))
				val_idx := arg_named_placeholder[i] ? piped_lhs : lex_parser.node_child(c.tree, an_idx)
				sarg.val_node = val_idx
				compile_call_arg_expr(c, &sarg, val_idx, parent_ls)
			case .Refused:
				sarg.kind = .Refused
			case .Integer, .Text, .Name, .Call, .Negate, .Binary, .Record_Literal, .Literal_Field,
			     .Let, .Let_Binding, .Member, .Function, .Parameter, .List_Literal, .Hash, .Boolean,
			     .If, .Field_Select, .Pipe, .Placeholder, .Logical_Not, .Text_Interp, .Pattern_Record, .Pattern_Field:
				compile_call_arg_expr(c, &sarg, an_idx, parent_ls)
			}
		}
		c.eval.site_args[c.eval.site_arg_count] = sarg
		c.eval.site_arg_count += 1
	}

	site_rel := u32(c.eval.site_count) - c.chunk.site_start
	c.eval.call_sites[c.eval.site_count] = {
		callee_kind     = callee_kind,
		callee_reg      = dst,
		has_named       = has_named,
		has_refused_arg = has_refused,
		name_sym        = name_sym,
		node_idx        = call_idx,
		args_start      = args_start,
		arg_count       = u16(arg_count),
	}
	c.eval.site_count += 1
	emit_abx_wide(c, .Call_Site, dst, site_rel, call_idx)
}

@(private)
compile_call_arg_expr :: proc "contextless" (c: ^Compiler, sarg: ^Call_Site_Arg, val_idx: lex_parser.Node_Index, parent_ls: i32) {
	vn := lex_parser.node_at(c.tree, val_idx)
	if vn != nil && vn.kind == .Record_Literal {
		desc_rel, refused_node, ok := build_record_desc(c, val_idx)
		if ok {
			sarg.is_literal = true
			sarg.record_desc = desc_rel
		} else if refused_node != lex_parser.NO_NODE {
			// Fall through to regular expr proto which emits console-order refusal.
		}
	} else if vn != nil && vn.kind == .Member {
		raw := lex_parser.node_text(c.tree, val_idx)
		mname := len(raw) > 0 && raw[0] == '.' ? raw[1:] : raw
		sarg.is_member = true
		sarg.member_sym = intern_str(c, mname)
	}
	p_idx, p_ok := alloc_proto(c, val_idx)
	if !p_ok {
		return
	}
	sarg.kind = .Expr
	sarg.proto_id = p_idx - c.chunk.proto_start
	enqueue_pending(c, {
		kind             = .Expr_Proto,
		proto_idx        = p_idx,
		ast_node         = val_idx,
		parent_let_scope = parent_ls,
	})
}

// refusal_inside_ast scans a Function subtree for any .Refused node so a
// function with a syntax error inside its body stops the line when reached.
@(private)
refusal_inside_ast :: proc "contextless" (tree: ^lex_parser.Syntax_Tree, root: lex_parser.Node_Index) -> lex_parser.Node_Index {
	// Iterative bounded DFS using a small local stack (max AST depth <= 256).
	stack: [lex_parser.DECLARATION_PARSE_DEPTH_LIMIT + 64]lex_parser.Node_Index
	top := 0
	stack[top] = root
	top += 1
	for top > 0 {
		top -= 1
		idx := stack[top]
		n := lex_parser.node_at(tree, idx)
		if n == nil {
			continue
		}
		if n.kind == .Refused {
			return idx
		}
		switch n.kind {
		case .Negate, .Logical_Not, .Field_Select, .Literal_Field, .Let_Binding, .Named_Argument, .Condition, .Pattern_Field:
			if ch := lex_parser.node_child(tree, idx); ch != lex_parser.NO_NODE && top < len(stack) {
				stack[top] = ch
				top += 1
			}
		case .Binary, .Pipe:
			l, r := lex_parser.node_binary_children(tree, idx)
			if r != lex_parser.NO_NODE && top < len(stack) {
				stack[top] = r
				top += 1
			}
			if l != lex_parser.NO_NODE && top < len(stack) {
				stack[top] = l
				top += 1
			}
		case .Call, .Record_Literal, .List_Literal, .Let, .Function, .If, .Text_Interp, .Pattern_Record:
			children := lex_parser.node_children(tree, idx)
			for i := len(children) - 1; i >= 0; i -= 1 {
				if top < len(stack) {
					stack[top] = children[i]
					top += 1
				}
			}
		case .Integer, .Text, .Name, .Fact_Name, .Field_Names, .Member, .Parameter, .Hash, .Boolean, .Placeholder, .Refused:
		}
	}
	return lex_parser.NO_NODE
}
