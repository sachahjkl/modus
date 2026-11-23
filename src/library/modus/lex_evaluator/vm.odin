// Flat 32-bit register bytecode VM for Lex v2
// (src/md/features/declarations.md, "Lex v2 engine").
//
// Executes compiled Chunks on a flat arena-backed register stack and unified
// frame stack (zero C-stack recursion for calls, tail calls, thunk forces,
// map, and filter). Both `.Console` and `.Declaration` modes share this single
// VM; every operation charges EVALUATION_BUDGET_STEPS.
package lex_evaluator

import "modus:console_condition"
import "modus:console_language"
import "modus:contract/blake3"
import module "modus:contract/module"
import "modus:hash_table"
import "modus:lex_parser"

// Compaction threshold for chained lazy `with` overlays (inline capacity:
// above 16 chained overlays, compact Thunk_Refs into a flat Lazy_Record
// without forcing any field).
OVERLAY_COMPACT_THRESHOLD :: 16

// Per-shape hash-index threshold (inline capacity: records up to 16 fields fit
// 16 Sym_Ids in one 64-byte cache line for direct u32 scan; records past 16
// fields build a per-shape Slice_Hash_Index for O(1) lookup, falling back to
// binary search if the carved index pool is full).
SHAPE_HASH_INDEX_THRESHOLD :: 16

// Console-line inline capacities for Console_Eval_Buffers.
CONSOLE_CODE_CAPACITY :: 8192
CONSOLE_PROTO_CAPACITY :: 512
CONSOLE_CONST_CAPACITY :: 1024
CONSOLE_UPVAL_CAPACITY :: 1024
CONSOLE_LET_DESC_CAPACITY :: 256
CONSOLE_LET_PROTO_CAPACITY :: 512
CONSOLE_REC_DESC_CAPACITY :: 256
CONSOLE_REC_FIELD_CAPACITY :: 1024
CONSOLE_SITE_CAPACITY :: 256
CONSOLE_SITE_ARG_CAPACITY :: 1024
CONSOLE_FIELD_SYM_CAPACITY :: 512
CONSOLE_SHAPE_CAPACITY :: 256
CONSOLE_SHAPE_FIELD_CAPACITY :: 1024
CONSOLE_SHAPE_IDX_SLOTS :: 2048
CONSOLE_PAT_DESC_CAPACITY :: 64
CONSOLE_PAT_FIELD_CAPACITY :: 256
CONSOLE_INTERN_SYMS :: 1024
CONSOLE_INTERN_GROUPS :: 74 // ceil(1024 / 14)
CONSOLE_INTERN_BYTES :: 16 * 1024
CONSOLE_REG_CAPACITY :: 4096
CONSOLE_FRAME_CAPACITY :: 512
CONSOLE_THUNK_CAPACITY :: 8192
CONSOLE_ENV_CAPACITY :: 8192
CONSOLE_LET_SLOT_CAPACITY :: 4096
CONSOLE_CLOSURE_CAPACITY :: 1024
CONSOLE_RECORD_CAPACITY :: 512
CONSOLE_OVERLAY_CAPACITY :: 256
CONSOLE_HOST_OBJ_CAPACITY :: 1024
CONSOLE_TEXT_ARENA :: 64 * 1024
CONSOLE_SCRATCH_LOCALS :: 1024
CONSOLE_SCRATCH_SCOPES :: 256
CONSOLE_SCRATCH_PENDING :: 512
CONSOLE_SCRATCH_REC_SORT :: 512

// Kind of frame on the VM's flat frame stack.
Frame_Kind :: enum u8 {
	Bytecode          = 0,
	Map               = 1,
	Filter            = 2,
	Console_Let_Force = 3,
	Console_Rec_Force = 4,
	Fold              = 5,
}

// One frame on the arena-backed VM frame stack.
VM_Frame :: struct {
	kind:          Frame_Kind,
	dst_reg:       u8,
	chunk_id:      u16,
	proto_id:      u32,
	ip:            u32,
	reg_base:      u32,
	let_base:      u32,
	env_off:       u32,
	env_len:       u16,
	pad:           u16,
	return_thunk:  Thunk_Ref,
	boxed_params:  [lex_parser.ARGUMENT_CAPACITY]Thunk_Ref,
	// Continuation state for iterative Map / Filter / Console eager forcing:
	cont_list_off: u32,
	cont_count:    u32,
	cont_index:    u32,
	cont_out_off:  u32,
	cont_fn:       Value,
	cont_node:     lex_parser.Node_Index,
}

// Caller-owned memory slices backing one VM evaluation.
Eval_Pools :: struct {
	chunks:            []Chunk,
	code:              []Instruction,
	code_nodes:        []lex_parser.Node_Index,
	protos:            []Proto,
	consts:            []Const_Entry,
	upvals:            []Upval_Desc,
	let_descs:         []Let_Desc,
	let_protos:        []u32,
	let_syms:          []lex_parser.Sym_Id,
	let_nodes:         []lex_parser.Node_Index,
	rec_descs:         []Record_Desc,
	rec_field_protos:  []u32,
	rec_field_nodes:   []lex_parser.Node_Index,
	rec_source_orders: []u32,
	call_sites:        []Call_Site_Desc,
	site_args:         []Call_Site_Arg,
	field_syms:        []lex_parser.Sym_Id,
	shapes:             []Record_Shape,
	shape_fields:       []lex_parser.Sym_Id,
	shape_idx_controls: []u8,
	shape_idx_refs:     []u32,
	pat_descs:          []Pattern_Desc,
	pat_fields:         []Pattern_Field_Desc,
	interner:           lex_parser.String_Interner,
	compile_scratch:   Compile_Scratch,
	// Runtime pools
	reg_stack:         []Value,
	frames:            []VM_Frame,
	thunks:            []Thunk,
	env_slots:         []Thunk_Ref,
	let_slots:         []Thunk_Ref,
	closures:          []Closure,
	records:           []Lazy_Record,
	record_thunk_refs: []Thunk_Ref,
	overlays:          []Record_Overlay,
	list_items:        []Value,
	list_scratch:      []Value,
	list_marks:        []u32,
	hashes:            []blake3.Hash,
	recipes:           []Recipe_Value,
	follows:           []Follow_Value,
	stores:            []Store_Value,
	tagged_records:    []Value,
	host_objs:         []Host_Obj,
	text_arena:        []u8,
}

// Caller-owned static buffers for evaluating one console line (zero inline
// arrays inside Evaluation itself).
Console_Eval_Buffers :: struct {
	chunks:            [2]Chunk,
	code:              [CONSOLE_CODE_CAPACITY]Instruction,
	code_nodes:        [CONSOLE_CODE_CAPACITY]lex_parser.Node_Index,
	protos:            [CONSOLE_PROTO_CAPACITY]Proto,
	consts:            [CONSOLE_CONST_CAPACITY]Const_Entry,
	upvals:            [CONSOLE_UPVAL_CAPACITY]Upval_Desc,
	let_descs:         [CONSOLE_LET_DESC_CAPACITY]Let_Desc,
	let_protos:        [CONSOLE_LET_PROTO_CAPACITY]u32,
	let_syms:          [CONSOLE_LET_PROTO_CAPACITY]lex_parser.Sym_Id,
	let_nodes:         [CONSOLE_LET_PROTO_CAPACITY]lex_parser.Node_Index,
	rec_descs:         [CONSOLE_REC_DESC_CAPACITY]Record_Desc,
	rec_field_protos:  [CONSOLE_REC_FIELD_CAPACITY]u32,
	rec_field_nodes:   [CONSOLE_REC_FIELD_CAPACITY]lex_parser.Node_Index,
	rec_source_orders: [CONSOLE_REC_FIELD_CAPACITY]u32,
	call_sites:        [CONSOLE_SITE_CAPACITY]Call_Site_Desc,
	site_args:         [CONSOLE_SITE_ARG_CAPACITY]Call_Site_Arg,
	field_syms:        [CONSOLE_FIELD_SYM_CAPACITY]lex_parser.Sym_Id,
	shapes:             [CONSOLE_SHAPE_CAPACITY]Record_Shape,
	shape_fields:       [CONSOLE_SHAPE_FIELD_CAPACITY]lex_parser.Sym_Id,
	shape_idx_controls: [CONSOLE_SHAPE_IDX_SLOTS]u8,
	shape_idx_refs:     [CONSOLE_SHAPE_IDX_SLOTS]u32,
	pat_descs:          [CONSOLE_PAT_DESC_CAPACITY]Pattern_Desc,
	pat_fields:         [CONSOLE_PAT_FIELD_CAPACITY]Pattern_Field_Desc,
	intern_controls:    [CONSOLE_INTERN_GROUPS * hash_table.GROUP_WIDTH]u8,
	intern_refs:       [CONSOLE_INTERN_GROUPS * hash_table.GROUP_WIDTH]u32,
	intern_spans:      [CONSOLE_INTERN_SYMS + 1]lex_parser.Sym_Span,
	intern_bytes:      [CONSOLE_INTERN_BYTES]u8,
	scratch_locals:    [CONSOLE_SCRATCH_LOCALS]Compile_Local,
	scratch_scopes:    [CONSOLE_SCRATCH_SCOPES]Compile_Let_Scope,
	scratch_pending:   [CONSOLE_SCRATCH_PENDING]Pending_Proto,
	scratch_upvals:    [CONSOLE_UPVAL_CAPACITY]Upval_Desc,
	scratch_rec_sort:  [CONSOLE_SCRATCH_REC_SORT]Rec_Sort_Entry,
	// Runtime pools
	reg_stack:         [CONSOLE_REG_CAPACITY]Value,
	frames:            [CONSOLE_FRAME_CAPACITY]VM_Frame,
	thunks:            [CONSOLE_THUNK_CAPACITY]Thunk,
	env_slots:         [CONSOLE_ENV_CAPACITY]Thunk_Ref,
	let_slots:         [CONSOLE_LET_SLOT_CAPACITY]Thunk_Ref,
	closures:          [CONSOLE_CLOSURE_CAPACITY]Closure,
	records:           [CONSOLE_RECORD_CAPACITY]Lazy_Record,
	record_thunk_refs: [CONSOLE_THUNK_CAPACITY]Thunk_Ref,
	overlays:          [CONSOLE_OVERLAY_CAPACITY]Record_Overlay,
	list_items:        [LIST_ITEM_CAPACITY]Value,
	list_scratch:      [LIST_ITEM_CAPACITY]Value,
	list_marks:        [256]u32,
	hashes:            [HASH_CAPACITY]blake3.Hash,
	recipes:           [16]Recipe_Value,
	follows:           [16]Follow_Value,
	stores:            [32]Store_Value,
	tagged_records:    [TAGGED_RECORD_CAPACITY]Value,
	host_objs:         [CONSOLE_HOST_OBJ_CAPACITY]Host_Obj,
	text_arena:        [CONSOLE_TEXT_ARENA]u8,
}

console_eval_pools :: proc "contextless" (buf: ^Console_Eval_Buffers, seed: u64 = 0) -> Eval_Pools {
	interner, _ := lex_parser.interner_init(
		buf.intern_controls[:],
		buf.intern_refs[:],
		buf.intern_spans[:],
		buf.intern_bytes[:],
		seed,
	)
	return {
		chunks            = buf.chunks[:],
		code              = buf.code[:],
		code_nodes        = buf.code_nodes[:],
		protos            = buf.protos[:],
		consts            = buf.consts[:],
		upvals            = buf.upvals[:],
		let_descs         = buf.let_descs[:],
		let_protos        = buf.let_protos[:],
		let_syms          = buf.let_syms[:],
		let_nodes         = buf.let_nodes[:],
		rec_descs         = buf.rec_descs[:],
		rec_field_protos  = buf.rec_field_protos[:],
		rec_field_nodes   = buf.rec_field_nodes[:],
		rec_source_orders = buf.rec_source_orders[:],
		call_sites        = buf.call_sites[:],
		site_args         = buf.site_args[:],
		field_syms        = buf.field_syms[:],
		shapes             = buf.shapes[:],
		shape_fields       = buf.shape_fields[:],
		shape_idx_controls = buf.shape_idx_controls[:],
		shape_idx_refs     = buf.shape_idx_refs[:],
		pat_descs          = buf.pat_descs[:],
		pat_fields         = buf.pat_fields[:],
		interner           = interner,
		compile_scratch   = {
			locals     = buf.scratch_locals[:],
			let_scopes = buf.scratch_scopes[:],
			pending    = buf.scratch_pending[:],
			upval_work = buf.scratch_upvals[:],
			rec_sort   = buf.scratch_rec_sort[:],
		},
		reg_stack         = buf.reg_stack[:],
		frames            = buf.frames[:],
		thunks            = buf.thunks[:],
		env_slots         = buf.env_slots[:],
		let_slots         = buf.let_slots[:],
		closures          = buf.closures[:],
		records           = buf.records[:],
		record_thunk_refs = buf.record_thunk_refs[:],
		overlays          = buf.overlays[:],
		list_items        = buf.list_items[:],
		list_scratch      = buf.list_scratch[:],
		list_marks        = buf.list_marks[:],
		hashes            = buf.hashes[:],
		recipes           = buf.recipes[:],
		follows           = buf.follows[:],
		stores            = buf.stores[:],
		tagged_records    = buf.tagged_records[:],
		host_objs         = buf.host_objs[:],
		text_arena        = buf.text_arena[:],
	}
}

// Lightweight VM evaluation handle (no inline [4097] arrays; all storage lives
// in caller-owned Eval_Pools).
Evaluation :: struct {
	tree:                  ^lex_parser.Syntax_Tree,
	mode:                  Evaluation_Mode,
	host:                  Evaluation_Host,
	budget:                u32,
	steps:                 u32,
	depth_limit:           int,
	stack_bytes:           uint,
	stack_deepest:         uint,
	refusal:               Refusal_Record,
	profile:               ^Evaluation_Profile,
	trace_log:             ^Trace_Log,
	traced:                bool,
	zip_shape_id:          u32,
	has_zip_shape:         bool,
	dep_data:              rawptr,
	on_shape_dep:          proc "contextless" (data: rawptr, import_owner: int, shape_hash: u64),
	on_record_field:       proc "contextless" (data: rawptr, import_owner: int, sym: lex_parser.Sym_Id),
	on_record_whole:       proc "contextless" (data: rawptr, import_owner: int),
	root_chunk_id:         u16,
	root_forced:           bool,
	root_value:            Value,
	last_result:           Value,
	call_count:            int,
	extra_arg:             u32,
	has_extra_arg:         bool,
	// Compiled pools
	chunks:                []Chunk,
	chunk_count:           int,
	code:                  []Instruction,
	code_nodes:            []lex_parser.Node_Index,
	code_count:            int,
	protos:                []Proto,
	proto_count:           int,
	consts:                []Const_Entry,
	const_count:           int,
	upvals:                []Upval_Desc,
	upval_count:           int,
	let_descs:             []Let_Desc,
	let_desc_count:        int,
	let_protos:            []u32,
	let_syms:              []lex_parser.Sym_Id,
	let_nodes:             []lex_parser.Node_Index,
	let_proto_count:       int,
	rec_descs:             []Record_Desc,
	rec_desc_count:        int,
	rec_field_protos:      []u32,
	rec_field_nodes:       []lex_parser.Node_Index,
	rec_source_orders:     []u32,
	rec_field_proto_count: int,
	call_sites:            []Call_Site_Desc,
	site_count:            int,
	site_args:             []Call_Site_Arg,
	site_arg_count:        int,
	field_syms:            []lex_parser.Sym_Id,
	field_sym_count:       int,
	shapes:                []Record_Shape,
	shape_count:           int,
	shape_fields:          []lex_parser.Sym_Id,
	shape_field_count:     int,
	shape_idx_controls:    []u8,
	shape_idx_refs:        []u32,
	shape_idx_used:        int,
	pat_descs:             []Pattern_Desc,
	pat_desc_count:        int,
	pat_fields:            []Pattern_Field_Desc,
	pat_field_count:       int,
	interner:              lex_parser.String_Interner,
	compile_scratch:       Compile_Scratch,
	// Runtime pools
	reg_stack:             []Value,
	reg_top:               u32,
	frames:                []VM_Frame,
	frame_count:           int,
	thunks:                []Thunk,
	thunk_count:           int,
	env_slots:             []Thunk_Ref,
	env_slot_count:        int,
	let_slots:             []Thunk_Ref,
	let_slot_top:          u32,
	closures:              []Closure,
	closure_count:         int,
	records:               []Lazy_Record,
	record_count:          int,
	record_thunk_refs:     []Thunk_Ref,
	record_thunk_ref_count: int,
	overlays:              []Record_Overlay,
	overlay_count:         int,
	list_items:            []Value,
	list_item_count:       int,
	list_scratch:          []Value,
	list_scratch_top:      u32,
	list_marks:            []u32,
	list_mark_count:       int,
	hashes:                []blake3.Hash,
	hash_count:            int,
	recipes:               []Recipe_Value,
	recipe_count:          int,
	follows:               []Follow_Value,
	follow_count:          int,
	stores:                []Store_Value,
	store_count:           int,
	tagged_records:        []Value,
	tagged_record_count:   int,
	host_objs:             []Host_Obj,
	host_obj_count:        int,
	text_arena:            []u8,
	text_used:             int,
}

// evaluation_start initializes a console evaluation backed by `buf`.
evaluation_start :: proc "contextless" (
	eval: ^Evaluation,
	tree: ^lex_parser.Syntax_Tree,
	mode: Evaluation_Mode,
	host: Evaluation_Host,
	buf: ^Console_Eval_Buffers,
	budget: u32 = EVALUATION_BUDGET_STEPS,
	stack_bytes: uint = EVALUATION_STACK_BYTES,
	depth_limit: int = EVALUATION_DEPTH_LIMIT,
) {
	pools := console_eval_pools(buf)
	evaluation_start_with_pools(eval, tree, mode, host, pools, budget, stack_bytes, depth_limit)
}

// evaluation_start_with_pools initializes an evaluation backed by caller-carved
// Eval_Pools.
evaluation_start_with_pools :: proc "contextless" (
	eval: ^Evaluation,
	tree: ^lex_parser.Syntax_Tree,
	mode: Evaluation_Mode,
	host: Evaluation_Host,
	pools: Eval_Pools,
	budget: u32 = EVALUATION_BUDGET_STEPS,
	stack_bytes: uint = EVALUATION_STACK_BYTES,
	depth_limit: int = EVALUATION_DEPTH_LIMIT,
) {
	eval^ = {
		tree              = tree,
		mode              = mode,
		host              = host,
		budget            = budget,
		depth_limit       = depth_limit > 0 ? depth_limit : EVALUATION_DEPTH_LIMIT,
		stack_bytes       = stack_bytes > 0 ? stack_bytes : EVALUATION_STACK_BYTES,
		chunks            = pools.chunks,
		code              = pools.code,
		code_nodes        = pools.code_nodes,
		protos            = pools.protos,
		consts            = pools.consts,
		upvals            = pools.upvals,
		let_descs         = pools.let_descs,
		let_protos        = pools.let_protos,
		let_syms          = pools.let_syms,
		let_nodes         = pools.let_nodes,
		rec_descs         = pools.rec_descs,
		rec_field_protos  = pools.rec_field_protos,
		rec_field_nodes   = pools.rec_field_nodes,
		rec_source_orders = pools.rec_source_orders,
		call_sites        = pools.call_sites,
		site_args         = pools.site_args,
		field_syms        = pools.field_syms,
		shapes             = pools.shapes,
		shape_fields       = pools.shape_fields,
		shape_idx_controls = pools.shape_idx_controls,
		shape_idx_refs     = pools.shape_idx_refs,
		pat_descs          = pools.pat_descs,
		pat_fields         = pools.pat_fields,
		interner           = pools.interner,
		compile_scratch   = pools.compile_scratch,
		reg_stack         = pools.reg_stack,
		frames            = pools.frames,
		thunks            = pools.thunks,
		env_slots         = pools.env_slots,
		let_slots         = pools.let_slots,
		closures          = pools.closures,
		records           = pools.records,
		record_thunk_refs = pools.record_thunk_refs,
		overlays          = pools.overlays,
		list_items        = pools.list_items,
		list_scratch      = pools.list_scratch,
		list_marks        = pools.list_marks,
		hashes            = pools.hashes,
		recipes           = pools.recipes,
		follows           = pools.follows,
		stores            = pools.stores,
		tagged_records    = pools.tagged_records,
		host_objs         = pools.host_objs,
		text_arena        = pools.text_arena,
	}
}

refused :: #force_inline proc "contextless" (eval: ^Evaluation) -> bool {
	return eval.refusal.refusal != .None
}

@(private)
refuse :: proc "contextless" (eval: ^Evaluation, record: Refusal_Record) -> (Value, bool) {
	if !refused(eval) {
		r := record
		if r.node != lex_parser.NO_NODE {
			tree: ^lex_parser.Syntax_Tree
			if int(r.chunk_id) < eval.chunk_count && eval.chunks[r.chunk_id].tree != nil {
				tree = eval.chunks[r.chunk_id].tree
			} else {
				tree = eval.tree
			}
			if tree != nil {
				if r.place.line == 0 {
					r.place = lex_parser.node_place(tree, r.node)
				}
				ss, se := lex_parser.node_span(tree, r.node)
				r.span_start = u32(ss)
				r.span_end = u32(se)
			}
		}
		// Capture force/call frame stack (most recent first, up to DIAGNOSTIC_FRAME_LIMIT).
		fc := 0
		for i := eval.frame_count - 1; i >= 0 && fc < DIAGNOSTIC_FRAME_LIMIT; i -= 1 {
			fr := &eval.frames[i]
			fnode := lex_parser.NO_NODE
			if fr.kind == .Bytecode && int(fr.chunk_id) < eval.chunk_count {
				if fr.ip > 0 && int(fr.ip - 1) < len(eval.code_nodes) {
					fnode = eval.code_nodes[fr.ip - 1]
				}
			} else {
				fnode = fr.cont_node
			}
			fplace: lex_parser.Place
			if fnode != lex_parser.NO_NODE && int(fr.chunk_id) < eval.chunk_count && eval.chunks[fr.chunk_id].tree != nil {
				fplace = lex_parser.node_place(eval.chunks[fr.chunk_id].tree, fnode)
			}
			r.frames[fc] = {chunk_id = fr.chunk_id, node = fnode, place = fplace}
			fc += 1
		}
		r.frame_count = fc
		eval.refusal = r
	}
	return {}, false
}

@(private)
charge_steps :: #force_inline proc "contextless" (eval: ^Evaluation, count: u32, chunk_id: u16, node_idx: lex_parser.Node_Index) -> bool {
	if u64(eval.steps) + u64(count) > u64(eval.budget) {
		refuse(eval, {refusal = .Budget_Exceeded, chunk_id = chunk_id, node = node_idx, steps = eval.budget})
		return false
	}
	eval.steps += count
	if eval.profile != nil {
		eval.profile.steps_total += u64(count)
	}
	return true
}

// ---- Pool allocation helpers.

hash_intern :: proc "contextless" (eval: ^Evaluation, hash: blake3.Hash) -> (idx: u32, ok: bool) {
	if eval.hash_count >= len(eval.hashes) {
		return 0, false
	}
	idx = u32(eval.hash_count)
	eval.hashes[idx] = hash
	eval.hash_count += 1
	return idx, true
}

text_arena_alloc :: proc "contextless" (eval: ^Evaluation, text: string) -> (val: Value, ok: bool) {
	if len(text) == 0 {
		return {kind = .Text, flags = u8(Text_Storage.Empty)}, true
	}
	if len(text) > len(eval.text_arena) - eval.text_used {
		return {}, false
	}
	start := eval.text_used
	copy(eval.text_arena[start:], text)
	eval.text_used += len(text)
	return value_text_arena(u32(start), u32(len(text))), true
}

list_items_add :: proc "contextless" (eval: ^Evaluation, values: []Value) -> (first: int, ok: bool) {
	if len(values) > len(eval.list_items) - eval.list_item_count {
		return 0, false
	}
	first = eval.list_item_count
	copy(eval.list_items[first:], values)
	eval.list_item_count += len(values)
	return first, true
}

list_items_add_host :: proc "contextless" (eval: ^Evaluation, values: []Host_Value) -> (first: int, ok: bool) {
	if len(values) > len(eval.list_items) - eval.list_item_count {
		return 0, false
	}
	first = eval.list_item_count
	for hv, i in values {
		v, vok := host_to_value(eval, hv)
		if !vok {
			return 0, false
		}
		eval.list_items[first + i] = v
	}
	eval.list_item_count += len(values)
	return first, true
}

// ---- Value <-> Host_Value border conversion (console FFI).

value_to_host :: proc "contextless" (eval: ^Evaluation, v: Value) -> Host_Value {
	switch v.kind {
	case .None:
		return {}
	case .Integer:
		return {kind = .Integer, integer = value_integer(v), vm_value = v}
	case .Boolean:
		return {kind = .Boolean, integer = v.data != 0 ? 1 : 0, vm_value = v}
	case .Handle:
		return {kind = .Handle, integer = value_integer(v), vm_value = v}
	case .Text:
		return {kind = .Text, text = value_text(eval, v), vm_value = v}
	case .List:
		return {kind = .List, integer = i64(v.data), detail = v.meta, vm_value = v}
	case .Hash, .Module_Ref, .Tree_Ref:
		return {kind = v.kind, detail = v.meta, vm_value = v}
	case .Follow_Ref:
		return {kind = .Follow_Ref, text = value_follow_name(eval, v), detail = v.meta, vm_value = v}
	case .Store_Ref:
		idx := int(v.data)
		if idx >= 0 && idx < eval.store_count {
			st := eval.stores[idx]
			return {kind = .Store_Ref, text = value_text(eval, st.name), integer = i64(st.rights_off), detail = st.rights_len, vm_value = v}
		}
		return {kind = .Store_Ref, vm_value = v}
	case .Record, .Table, .Bytes, .Stream, .Record_Input, .Enum:
		idx := int(v.data)
		if idx >= 0 && idx < eval.host_obj_count {
			obj := eval.host_objs[idx]
			return {
				kind      = v.kind,
				integer   = obj.integer,
				text      = obj.text,
				record    = obj.record,
				file      = obj.file,
				detail    = obj.detail,
				condition = obj.condition,
				vm_value  = v,
			}
		}
		return {kind = v.kind, detail = v.meta, vm_value = v}
	case .Record_Literal, .Record_With, .Member, .Function, .Recipe_Ref, .Plan_Value, .Project_Value:
		return {kind = v.kind, integer = i64(v.data), detail = v.meta, vm_value = v}
	}
	return {}
}

host_to_value :: proc "contextless" (eval: ^Evaluation, hv: Host_Value) -> (v: Value, ok: bool) {
	// Condition values have kind == .None and condition != nil.
	if hv.condition != nil {
		if eval.host_obj_count >= len(eval.host_objs) {
			return {}, false
		}
		idx := eval.host_obj_count
		eval.host_objs[idx] = {condition = hv.condition}
		eval.host_obj_count += 1
		return {kind = .None, flags = 1, data = u64(idx)}, true
	}
	switch hv.kind {
	case .None:
		return {}, true
	case .Integer:
		return value_int(hv.integer), true
	case .Boolean:
		return value_bool(hv.integer != 0), true
	case .Handle:
		return {kind = .Handle, data = u64(hv.integer)}, true
	case .Text:
		if len(hv.text) == 0 {
			return {kind = .Text, flags = u8(Text_Storage.Empty)}, true
		}
		if eval.host_obj_count >= len(eval.host_objs) {
			return {}, false
		}
		idx := eval.host_obj_count
		eval.host_objs[idx] = {text = hv.text}
		eval.host_obj_count += 1
		return {kind = .Text, flags = u8(Text_Storage.Host), meta = u32(len(hv.text)), data = u64(idx)}, true
	case .Record, .Table, .Bytes, .Stream, .Record_Input, .Enum:
		if eval.host_obj_count >= len(eval.host_objs) {
			return {}, false
		}
		idx := eval.host_obj_count
		eval.host_objs[idx] = {
			record    = hv.record,
			file      = hv.file,
			text      = hv.text,
			condition = hv.condition,
			detail    = hv.detail,
			integer   = hv.integer,
		}
		eval.host_obj_count += 1
		return {kind = hv.kind, meta = hv.detail, data = u64(idx)}, true
	case .List:
		if hv.vm_value.kind == .List {
			return hv.vm_value, true
		}
		return {kind = .List, data = u64(hv.integer), meta = hv.detail}, true
	case .Hash, .Module_Ref, .Tree_Ref:
		if hv.vm_value.kind == hv.kind {
			return hv.vm_value, true
		}
		return {kind = hv.kind, meta = hv.detail}, true
	case .Record_Literal, .Record_With, .Member, .Function, .Recipe_Ref, .Follow_Ref, .Store_Ref, .Plan_Value, .Project_Value:
		if hv.vm_value.kind == hv.kind {
			return hv.vm_value, true
		}
		return {kind = hv.kind, data = u64(hv.integer), meta = hv.detail}, true
	}
	return {}, true
}

// ---- Record_Shape lookups and lazy record / overlay operations.

// build_shape_hash_index attaches a per-shape Slice_Hash_Index to shapes with
// more than SHAPE_HASH_INDEX_THRESHOLD fields. If the carved index pool is full
// it records a fallback and leaves has_index = false (inline capacity never refuses).
@(private)
build_shape_hash_index :: proc "contextless" (eval: ^Evaluation, shape_id: u32) {
	if int(shape_id) >= eval.shape_count {
		return
	}
	shape := &eval.shapes[shape_id]
	count := int(shape.field_count)
	if count <= SHAPE_HASH_INDEX_THRESHOLD {
		return
	}
	groups := hash_table.slice_index_groups_for_entries(count)
	slots := groups * hash_table.GROUP_WIDTH
	if slots <= 0 || eval.shape_idx_used + slots > len(eval.shape_idx_controls) || eval.shape_idx_used + slots > len(eval.shape_idx_refs) {
		if eval.profile != nil {
			eval.profile.shape_index_fallbacks += 1
		}
		return
	}
	start := eval.shape_idx_used
	ctrls := eval.shape_idx_controls[start:start + slots]
	refs := eval.shape_idx_refs[start:start + slots]
	idx, ok := hash_table.slice_index_init(u32, ctrls, refs, eval.interner.index.prepared_seed)
	if !ok {
		if eval.profile != nil {
			eval.profile.shape_index_fallbacks += 1
		}
		return
	}
	Shape_Hash_Owner :: struct {
		idx:    ^hash_table.Slice_Hash_Index(u32),
		fields: []lex_parser.Sym_Id,
	}
	shape_hash_of_ref :: proc "contextless" (owner: rawptr, reference: u64) -> u64 {
		o := (^Shape_Hash_Owner)(owner)
		i := int(reference)
		if i < 0 || i >= len(o.fields) {
			return 0
		}
		return hash_table.slice_index_hash_word(o.idx, u64(o.fields[i]))
	}
	fields := eval.shape_fields[int(shape.fields_off):int(shape.fields_off) + count]
	owner := Shape_Hash_Owner{idx = &idx, fields = fields}
	for sym, ci in fields {
		h := hash_table.slice_index_hash_word(&idx, u64(sym))
		if !hash_table.slice_index_insert(&idx, h, u32(ci), &owner, shape_hash_of_ref) {
			if eval.profile != nil {
				eval.profile.shape_index_fallbacks += 1
			}
			return
		}
	}
	eval.shape_idx_used = start + slots
	shape.hash_index = idx
	shape.has_index = true
	if eval.profile != nil {
		eval.profile.shape_indices_built += 1
	}
}

// shape_lookup_sym looks up `sym` in a UTF-8 sorted Record_Shape.
// <= 16 fields: single-cache-line u32 Sym_Id scan (zero string dereferences).
// > 16 fields: O(1) Slice_Hash_Index lookup (or UTF-8 binary search fallback).
shape_lookup_sym :: proc "contextless" (eval: ^Evaluation, shape_id: u32, sym: lex_parser.Sym_Id) -> (field_idx: int, found: bool) {
	if int(shape_id) >= eval.shape_count || sym == lex_parser.NO_SYM {
		return -1, false
	}
	shape := &eval.shapes[shape_id]
	count := int(shape.field_count)
	if count == 0 {
		return -1, false
	}
	fields := eval.shape_fields[int(shape.fields_off):int(shape.fields_off) + count]
	if count <= SHAPE_HASH_INDEX_THRESHOLD {
		for i in 0 ..< count {
			if fields[i] == sym {
				return i, true
			}
		}
		return -1, false
	}
	if shape.has_index {
		if eval.profile != nil {
			eval.profile.shape_hash_lookups += 1
		}
		h := hash_table.slice_index_hash_word(&shape.hash_index, u64(sym))
		probe := hash_table.slice_index_search_begin(&shape.hash_index, h)
		for {
			ref, _, ok := hash_table.slice_index_search_next(&shape.hash_index, &probe)
			if !ok {
				return -1, false
			}
			if int(ref) < count && fields[ref] == sym {
				return int(ref), true
			}
		}
	}
	target := lex_parser.sym_text(&eval.interner, sym)
	lo, hi := 0, count
	for lo < hi {
		mid := lo + (hi - lo) / 2
		mid_sym := fields[mid]
		if mid_sym == sym {
			return mid, true
		}
		cmp := str_cmp(lex_parser.sym_text(&eval.interner, mid_sym), target)
		if cmp < 0 {
			lo = mid + 1
		} else if cmp > 0 {
			hi = mid
		} else {
			return mid, true
		}
	}
	return -1, false
}

// lazy_record_base_shape returns the canonical Record_Shape index of any lazy
// record (unwrapping Plan_Value/Project_Value and Record_With in O(1)).
lazy_record_base_shape :: proc "contextless" (eval: ^Evaluation, v: Value) -> (shape_id: u32, ok: bool) {
	cur := v
	for _ in 0 ..< 8 {
		#partial switch cur.kind {
		case .Record_Literal:
			idx := int(cur.data)
			if idx < 0 || idx >= eval.record_count {
				return 0, false
			}
			return eval.records[idx].shape_id, true
		case .Record_With:
			idx := int(cur.data)
			if idx < 0 || idx >= eval.overlay_count {
				return 0, false
			}
			return eval.overlays[idx].base_shape_id, true
		case .Plan_Value, .Project_Value:
			idx := int(cur.data)
			if idx < 0 || idx >= eval.tagged_record_count {
				return 0, false
			}
			cur = eval.tagged_records[idx]
		case:
			return 0, false
		}
	}
	return 0, false
}

// lazy_record_import_owner returns the originating import slot index (>= 0)
// when `v` is or wraps an imported module's root record, or -1 otherwise.
lazy_record_import_owner :: proc "contextless" (eval: ^Evaluation, v: Value) -> int {
	cur := v
	for _ in 0 ..< 64 {
		#partial switch cur.kind {
		case .Record_Literal:
			idx := int(cur.data)
			if idx < 0 || idx >= eval.record_count {
				return -1
			}
			f := eval.records[idx].flags
			return f == 0 ? -1 : int(f) - 1
		case .Record_With:
			idx := int(cur.data)
			if idx < 0 || idx >= eval.overlay_count {
				return -1
			}
			cur = eval.overlays[idx].base
		case .Plan_Value, .Project_Value:
			idx := int(cur.data)
			if idx < 0 || idx >= eval.tagged_record_count {
				return -1
			}
			cur = eval.tagged_records[idx]
		case:
			return -1
		}
	}
	return -1
}

// lazy_record_lookup_thunk resolves the Thunk_Ref of `sym` in a lazy record or
// overlay chain without forcing any field.
lazy_record_lookup_thunk :: proc "contextless" (eval: ^Evaluation, v: Value, sym: lex_parser.Sym_Id) -> (ref: Thunk_Ref, found: bool) {
	cur := v
	for _ in 0 ..< 64 {
		#partial switch cur.kind {
		case .Record_Literal:
			idx := int(cur.data)
			if idx < 0 || idx >= eval.record_count {
				return NO_THUNK, false
			}
			rec := eval.records[idx]
			fi, ok := shape_lookup_sym(eval, rec.shape_id, sym)
			if !ok {
				return NO_THUNK, false
			}
			if rec.flags != 0 && eval.on_record_field != nil {
				eval.on_record_field(eval.dep_data, int(rec.flags) - 1, sym)
			}
			return eval.record_thunk_refs[int(rec.refs_off) + fi], true
		case .Record_With:
			idx := int(cur.data)
			if idx < 0 || idx >= eval.overlay_count {
				return NO_THUNK, false
			}
			ov := eval.overlays[idx]
			if int(ov.patch_rec) < eval.record_count {
				patch := eval.records[ov.patch_rec]
				if fi, ok := shape_lookup_sym(eval, patch.shape_id, sym); ok {
					return eval.record_thunk_refs[int(patch.refs_off) + fi], true
				}
			}
			cur = ov.base
		case .Plan_Value, .Project_Value:
			idx := int(cur.data)
			if idx < 0 || idx >= eval.tagged_record_count {
				return NO_THUNK, false
			}
			cur = eval.tagged_records[idx]
		case:
			return NO_THUNK, false
		}
	}
	return NO_THUNK, false
}

// lazy_record_compact flattens a Record_With chain into a single flat
// Lazy_Record by copying Thunk_Refs without forcing any field thunk, charging
// EVALUATION_BUDGET_STEPS per field.
lazy_record_compact :: proc "contextless" (eval: ^Evaluation, v: Value, chunk_id: u16, node_idx: lex_parser.Node_Index) -> (rec_idx: u32, ok: bool) {
	cur := v
	for cur.kind == .Plan_Value || cur.kind == .Project_Value {
		idx := int(cur.data)
		if idx < 0 || idx >= eval.tagged_record_count {
			return 0, false
		}
		cur = eval.tagged_records[idx]
	}
	if cur.kind == .Record_Literal {
		return u32(cur.data), true
	}
	if cur.kind != .Record_With {
		return 0, false
	}
	shape_id, shape_ok := lazy_record_base_shape(eval, cur)
	if !shape_ok {
		return 0, false
	}
	shape := &eval.shapes[shape_id]
	fcount := int(shape.field_count)
	if !charge_steps(eval, u32(max(fcount, 1)), chunk_id, node_idx) {
		return 0, false
	}
	if eval.record_count >= len(eval.records) || eval.record_thunk_ref_count + fcount > len(eval.record_thunk_refs) {
		refuse(eval, {refusal = .With_Pairs_Full, chunk_id = chunk_id, node = node_idx})
		return 0, false
	}
	refs_off := u32(eval.record_thunk_ref_count)
	eval.record_thunk_ref_count += fcount

	// Collect overlay chain bottom-up: find base Lazy_Record, copy its refs,
	// then apply patches from oldest overlay to newest overlay.
	ov_chain: [OVERLAY_COMPACT_THRESHOLD + 8]u32
	ov_len := 0
	walk := cur
	for walk.kind == .Record_With && ov_len < len(ov_chain) {
		ov_idx := u32(walk.data)
		ov_chain[ov_len] = ov_idx
		ov_len += 1
		walk = eval.overlays[ov_idx].base
	}
	if walk.kind != .Record_Literal {
		// Deep nested chain: compact base recursively first (bounded by depth).
		base_flat := lazy_record_compact(eval, walk, chunk_id, node_idx) or_return
		base_rec := eval.records[base_flat]
		copy(eval.record_thunk_refs[int(refs_off):int(refs_off) + fcount], eval.record_thunk_refs[int(base_rec.refs_off):int(base_rec.refs_off) + fcount])
	} else {
		base_rec := eval.records[int(walk.data)]
		copy(eval.record_thunk_refs[int(refs_off):int(refs_off) + fcount], eval.record_thunk_refs[int(base_rec.refs_off):int(base_rec.refs_off) + fcount])
	}
	for i := ov_len - 1; i >= 0; i -= 1 {
		ov := eval.overlays[ov_chain[i]]
		patch := eval.records[ov.patch_rec]
		pshape := &eval.shapes[patch.shape_id]
		pfields := eval.shape_fields[int(pshape.fields_off):int(pshape.fields_off) + int(pshape.field_count)]
		for psym, pi in pfields {
			if bi, found := shape_lookup_sym(eval, shape_id, psym); found {
				eval.record_thunk_refs[int(refs_off) + bi] = eval.record_thunk_refs[int(patch.refs_off) + pi]
			}
		}
	}

	owner := lazy_record_import_owner(eval, cur)
	if owner >= 0 && eval.on_record_whole != nil {
		eval.on_record_whole(eval.dep_data, owner)
	}
	rec_idx = u32(eval.record_count)
	eval.records[rec_idx] = {
		shape_id = shape_id,
		refs_off = refs_off,
		chunk_id = chunk_id,
		flags    = owner >= 0 ? u16(owner + 1) : 0,
		node_idx = node_idx,
	}
	eval.record_count += 1
	if eval.profile != nil {
		eval.profile.overlay_compacts += 1
	}
	return rec_idx, true
}

// record_field_names writes the canonical sorted field names of any lazy record
// into `names`, returning their count.
record_field_names :: proc "contextless" (eval: ^Evaluation, value: Value, names: []string) -> (count: int, ok: bool) {
	shape_id, shape_ok := lazy_record_base_shape(eval, value)
	if !shape_ok {
		return 0, false
	}
	shape := &eval.shapes[shape_id]
	fcount := int(shape.field_count)
	if fcount > len(names) {
		return 0, false
	}
	fields := eval.shape_fields[int(shape.fields_off):int(shape.fields_off) + fcount]
	for sym, i in fields {
		names[i] = lex_parser.sym_text(&eval.interner, sym)
	}
	return fcount, true
}

// ---- Public entry points.

// line_force compiles (if needed) and evaluates the root tree of `eval`,
// returning a Host_Value for the console border.
line_force :: proc "contextless" (eval: ^Evaluation) -> (value: Host_Value, ok: bool) {
	v := line_force_value(eval) or_return
	return value_to_host(eval, v), true
}

// line_force_value compiles and evaluates the root tree of `eval`, returning
// the 16-byte VM Value directly.
line_force_value :: proc "contextless" (eval: ^Evaluation) -> (value: Value, ok: bool) {
	if refused(eval) {
		return {}, false
	}
	if eval.root_forced {
		return eval.root_value, true
	}
	tree := eval.tree
	if tree == nil {
		return refuse(eval, {refusal = .Text, text_refusal = .Unexpected})
	}
	// Hard parse bounds stop before any effect runs.
	switch tree.refusal.refusal {
	case .Text_Too_Long, .Nodes_Full, .Nesting_Too_Deep, .Thin_Arrow, .Pipe_No_Left, .Pipe_Line_End, .Pipe_Not_A_Call, .Lone_Bar, .Placeholder_Not_Whole, .Placeholder_Twice, .Placeholder_Nested, .Placeholder_Without_Pipe:
		return refuse(eval, {refusal = .Text, text_refusal = tree.refusal.refusal, place = tree.refusal.place, node = tree.root})
	case .None, .Line_Ends_Too_Soon, .Unexpected, .Number_Too_Large, .Text_Without_End_Quote, .Close_Parenthesis_Missing, .Comma_Or_Close_Missing, .Too_Many_Arguments, .Fact_Name_Missing, .Condition_Head_Refused, .Field_Name_Missing, .Literal_Close_Missing, .Literal_Name_Missing, .Literal_Equal_Missing, .Literal_Field_Twice, .Named_Argument_Twice, .Positional_After_Named, .Let_Name_Missing, .Let_Equal_Missing, .Let_In_Missing, .Let_Name_Twice, .Word_As_Name, .Parameter_Name_Missing, .Parameter_Twice, .Too_Many_Parameters, .List_Close_Missing, .Hash_Not_Valid, .If_Then_Missing, .If_Else_Missing, .Escape_Not_Valid, .Interpolation_Close_Missing, .Pattern_Field_Missing, .Pattern_Close_Missing, .Pattern_Field_Twice, .Pattern_Rest_Not_Last, .Pattern_At_Missing_Brace:
	}

	cid, comp_ok := compile_tree(eval, tree)
	if !comp_ok {
		return refuse(eval, {refusal = .Calls_Full, node = tree.root})
	}
	eval.root_chunk_id = cid
	chunk := &eval.chunks[cid]

	val := vm_exec_proto(eval, cid, chunk.root_proto, 0, 0, nil, NO_THUNK, tree.root) or_return
	if eval.mode == .Console {
		untyped := untyped_find(eval, val, 0)
		if untyped.kind == .Record_Literal {
			rec := eval.records[int(untyped.data)]
			return refuse(eval, {refusal = .Literal_No_Type, chunk_id = rec.chunk_id, node = rec.node_idx})
		}
		if untyped.kind == .Member {
			return refuse(eval, {refusal = .Member_No_Type, chunk_id = untyped.aux, node = lex_parser.Node_Index(i32(u32(untyped.data)))})
		}
	}
	eval.root_forced = true
	eval.root_value = val
	return val, true
}

// force evaluates a single AST node (used by console Condition host callbacks
// and for idempotent re-force of the root).
force :: proc "contextless" (eval: ^Evaluation, node_idx: lex_parser.Node_Index) -> (value: Host_Value, ok: bool) {
	if refused(eval) {
		return {}, false
	}
	if eval.tree != nil && node_idx == eval.tree.root && eval.root_forced {
		return value_to_host(eval, eval.root_value), true
	}
	// Compile and run a one-off expression proto in the current root/frame chunk.
	if eval.tree == nil {
		return {}, false
	}
	// Create a tiny temporary chunk referencing the same tree, rooted at node_idx.
	saved_root := eval.tree.root
	eval.tree.root = node_idx
	cid, comp_ok := compile_tree(eval, eval.tree)
	eval.tree.root = saved_root
	if !comp_ok {
		refuse(eval, {refusal = .Calls_Full, node = node_idx})
		return {}, false
	}
	chunk := &eval.chunks[cid]
	val := vm_exec_proto(eval, cid, chunk.root_proto, 0, 0, nil, NO_THUNK, node_idx) or_return
	return value_to_host(eval, val), true
}

// field_force forces one field of a lazy record (or console host Record) by name.
field_force :: proc "contextless" (eval: ^Evaluation, base: Value, field_name: string, chunk_id: u16 = 0, node_idx: lex_parser.Node_Index = lex_parser.NO_NODE) -> (val: Value, ok: bool) {
	if refused(eval) {
		return {}, false
	}
	if base.kind == .Record {
		hv := value_to_host(eval, base)
		if res, found := record_field_value(hv, field_name); found {
			return host_to_value(eval, res)
		}
		return refuse(eval, {refusal = .Field_Unknown, chunk_id = chunk_id, node = node_idx, field = field_name, left_kind = .Record, file = hv.file, detail = hv.detail})
	}
	if is_lazy_record(base.kind) {
		sym, found_sym := lex_parser.intern_lookup(&eval.interner, field_name)
		if found_sym {
			if tref, found := lazy_record_lookup_thunk(eval, base, sym); found {
				return vm_force_thunk(eval, tref, chunk_id, node_idx)
			}
		}
	}
	return refuse(eval, {refusal = .Field_Unknown, chunk_id = chunk_id, node = node_idx, field = field_name, left_kind = base.kind})
}

// untyped_find finds the first untyped Record_Literal or Member inside a
// console result (or nested List).
@(private)
untyped_find :: proc "contextless" (eval: ^Evaluation, value: Value, depth: int) -> Value {
	if value.kind == .Record_Literal || value.kind == .Member {
		return value
	}
	if value.kind != .List || depth > 64 {
		return {}
	}
	for item in list_items_of(eval, value) {
		if found := untyped_find(eval, item, depth + 1); found.kind != .None {
			return found
		}
	}
	return {}
}

// ---- Core VM execution engine (zero C-stack recursion).

@(private)
push_bytecode_frame :: proc "contextless" (
	eval: ^Evaluation,
	chunk_id: u16,
	proto_id: u32,
	env_off: u32,
	env_len: u16,
	args: []Value,
	dst_reg: u8,
	return_thunk: Thunk_Ref,
	call_node: lex_parser.Node_Index,
) -> bool {
	if eval.frame_count >= eval.depth_limit {
		refuse(eval, {refusal = .Depth_Exceeded, chunk_id = chunk_id, node = call_node, left = i64(eval.frame_count), right = i64(eval.depth_limit)})
		return false
	}
	if eval.frame_count >= len(eval.frames) {
		refuse(eval, {refusal = .Calls_Full, chunk_id = chunk_id, node = call_node})
		return false
	}
	// Stack-byte bound check (synthetic equivalent for tight caller stack_bytes).
	used_bytes := uint(eval.frame_count + 1) * uint(size_of(VM_Frame) + 64)
	if used_bytes > eval.stack_bytes {
		refuse(eval, {refusal = .Stack_Exceeded, chunk_id = chunk_id, node = call_node, left = i64(used_bytes), right = i64(eval.stack_bytes)})
		return false
	}
	if used_bytes > eval.stack_deepest {
		eval.stack_deepest = used_bytes
	}

	chunk := &eval.chunks[chunk_id]
	proto := &eval.protos[int(chunk.proto_start) + int(proto_id)]
	need_regs := u32(max(int(proto.max_regs), len(args)))
	if int(eval.reg_top) + int(need_regs) > len(eval.reg_stack) {
		refuse(eval, {refusal = .Calls_Full, chunk_id = chunk_id, node = call_node})
		return false
	}
	if int(eval.let_slot_top) + int(proto.let_slot_count) > len(eval.let_slots) {
		refuse(eval, {refusal = .Calls_Full, chunk_id = chunk_id, node = call_node})
		return false
	}

	reg_base := eval.reg_top
	eval.reg_top += need_regs
	let_base := eval.let_slot_top
	eval.let_slot_top += u32(proto.let_slot_count)

	for i in 0 ..< len(args) {
		eval.reg_stack[int(reg_base) + i] = args[i]
	}

	frame := &eval.frames[eval.frame_count]
	frame^ = {
		kind         = .Bytecode,
		dst_reg      = dst_reg,
		chunk_id     = chunk_id,
		proto_id     = proto_id,
		ip           = proto.code_start,
		reg_base     = reg_base,
		let_base     = let_base,
		env_off      = env_off,
		env_len      = env_len,
		return_thunk = return_thunk,
	}

	// Box any captured parameters into pre-forced Thunks once on entry.
	if proto.boxed_param_mask != 0 {
		for i in 0 ..< int(proto.param_count) {
			if (proto.boxed_param_mask & (u16(1) << u16(i))) != 0 {
				if eval.thunk_count >= len(eval.thunks) {
					refuse(eval, {refusal = .Calls_Full, chunk_id = chunk_id, node = call_node})
					return false
				}
				tref := Thunk_Ref(eval.thunk_count)
				eval.thunk_count += 1
				eval.thunks[tref] = {
					state   = .Forced,
					site_id = u32(proto.node_idx),
					payload = {value = eval.reg_stack[int(reg_base) + i]},
				}
				frame.boxed_params[i] = tref
				if eval.profile != nil {
					eval.profile.thunks_created += 1
				}
			}
		}
	}

	eval.frame_count += 1
	if eval.profile != nil {
		if u32(eval.frame_count) > eval.profile.max_frame_depth {
			eval.profile.max_frame_depth = u32(eval.frame_count)
		}
		if eval.reg_top > eval.profile.max_reg_depth {
			eval.profile.max_reg_depth = eval.reg_top
		}
	}
	return true
}

@(private)
capture_upvals :: proc "contextless" (eval: ^Evaluation, parent: ^VM_Frame, chunk_id: u16, child_proto_id: u32, node_idx: lex_parser.Node_Index) -> (env_off: u32, env_len: u16, ok: bool) {
	chunk := &eval.chunks[chunk_id]
	proto := &eval.protos[int(chunk.proto_start) + int(child_proto_id)]
	cnt := int(proto.upval_count)
	if cnt == 0 {
		return 0, 0, true
	}
	if eval.env_slot_count + cnt > len(eval.env_slots) {
		refuse(eval, {refusal = .Calls_Full, chunk_id = chunk_id, node = node_idx})
		return 0, 0, false
	}
	env_off = u32(eval.env_slot_count)
	for i in 0 ..< cnt {
		desc := eval.upvals[int(proto.upval_start) + i]
		tref: Thunk_Ref
		switch desc.source {
		case .Parent_Let:
			tref = eval.let_slots[int(parent.let_base) + int(desc.index)]
		case .Parent_Boxed_Param:
			tref = parent.boxed_params[desc.index]
		case .Parent_Upval:
			tref = eval.env_slots[int(parent.env_off) + int(desc.index)]
		}
		eval.env_slots[int(env_off) + i] = tref
	}
	eval.env_slot_count += cnt
	return env_off, u16(cnt), true
}

// vm_exec_proto pushes a frame for (chunk_id, proto_id) and runs until it returns.
@(private)
vm_exec_proto :: proc "contextless" (
	eval: ^Evaluation,
	chunk_id: u16,
	proto_id: u32,
	env_off: u32,
	env_len: u16,
	args: []Value,
	return_thunk: Thunk_Ref,
	call_node: lex_parser.Node_Index,
) -> (Value, bool) {
	target_depth := eval.frame_count
	if !push_bytecode_frame(eval, chunk_id, proto_id, env_off, env_len, args, 0, return_thunk, call_node) {
		return {}, false
	}
	if !vm_run(eval, target_depth) {
		return {}, false
	}
	return eval.last_result, true
}

// vm_force_thunk forces `tref` (memoizing its result in-place in the 24B Thunk).
@(private)
vm_force_thunk :: proc "contextless" (eval: ^Evaluation, tref: Thunk_Ref, caller_chunk: u16, ref_node: lex_parser.Node_Index) -> (Value, bool) {
	if int(tref) >= eval.thunk_count {
		return refuse(eval, {refusal = .Text, text_refusal = .Unexpected, chunk_id = caller_chunk, node = ref_node})
	}
	th := &eval.thunks[tref]
	switch th.state {
	case .Forced:
		if eval.profile != nil {
			eval.profile.thunks_reused += 1
		}
		return th.payload.value, true
	case .Forcing:
		return refuse(eval, {refusal = .Cycle, chunk_id = caller_chunk, node = ref_node, command = thunk_cycle_name(eval, th)})
	case .Unforced:
		if !charge_steps(eval, 1, caller_chunk, ref_node) {
			return {}, false
		}
		code := th.payload.code
		th.state = .Forcing
		if eval.profile != nil {
			eval.profile.thunks_forced += 1
		}
		return vm_exec_proto(eval, code.chunk_id, code.proto_id, code.env_off, u16(code.env_len), nil, tref, ref_node)
	}
	return {}, false
}

@(private)
thunk_cycle_name :: proc "contextless" (eval: ^Evaluation, th: ^Thunk) -> string {
	cid := int(th.payload.code.chunk_id)
	if cid < eval.chunk_count && eval.chunks[cid].tree != nil {
		nidx := lex_parser.Node_Index(i32(th.site_id))
		if nidx != lex_parser.NO_NODE {
			return lex_parser.node_text(eval.chunks[cid].tree, nidx)
		}
	}
	return ""
}

// vm_return_to_caller pops the top frame, stores `result` into its return_thunk
// (if any) and into caller's dst_reg (or eval.last_result at target_depth).
@(private)
vm_return_to_caller :: proc "contextless" (eval: ^Evaluation, target_depth: int, result: Value) {
	eval.frame_count -= 1
	popped := &eval.frames[eval.frame_count]
	eval.reg_top = popped.reg_base
	eval.let_slot_top = popped.let_base
	if popped.return_thunk != NO_THUNK {
		th := &eval.thunks[popped.return_thunk]
		th.state = .Forced
		th.payload.value = result
	}
	if eval.frame_count <= target_depth {
		eval.last_result = result
	} else {
		caller := &eval.frames[eval.frame_count - 1]
		eval.reg_stack[int(caller.reg_base) + int(popped.dst_reg)] = result
	}
}

// vm_run is the single flat execution loop of Lex v2. Zero C-stack recursion.
@(private)
vm_run :: proc "contextless" (eval: ^Evaluation, target_depth: int) -> bool {
	for eval.frame_count > target_depth {
		if refused(eval) {
			return false
		}
		frame := &eval.frames[eval.frame_count - 1]

		// Handle non-bytecode continuation frames (Map, Filter, Console eager force).
		if frame.kind != .Bytecode {
			if !vm_step_continuation(eval, frame, target_depth) {
				return false
			}
			continue
		}

		ip := frame.ip
		inst := eval.code[ip]
		node_idx := eval.code_nodes[ip]
		frame.ip = ip + 1
		op, op_ok := inst_op(inst)
		if !op_ok {
			refuse(eval, {refusal = .Host_Refused, chunk_id = frame.chunk_id, node = node_idx})
			return false
		}

		if op == .Extra_Arg {
			eval.extra_arg = inst_ax_val(inst)
			eval.has_extra_arg = true
			continue
		}

		if eval.profile != nil {
			eval.profile.opcode_counts[op] += 1
		}
		if eval.steps >= eval.budget {
			refuse(eval, {refusal = .Budget_Exceeded, chunk_id = frame.chunk_id, node = node_idx, steps = eval.budget})
			return false
		}
		eval.steps += 1
		if eval.profile != nil {
			eval.profile.steps_total += 1
		}

		extra := eval.extra_arg
		has_extra := eval.has_extra_arg
		eval.has_extra_arg = false
		eval.extra_arg = 0

		reg_base := int(frame.reg_base)
		a := int(inst_a(inst))

		switch op {
		case .Nop, .Extra_Arg:

		case .Move:
			b := int(inst_b(inst))
			eval.reg_stack[reg_base + a] = eval.reg_stack[reg_base + b]

		case .Load_None:
			eval.reg_stack[reg_base + a] = {}

		case .Load_Bool:
			eval.reg_stack[reg_base + a] = value_bool(inst_b(inst) != 0)

		case .Load_Int_Imm:
			eval.reg_stack[reg_base + a] = value_int(i64(inst_sbx(inst)))

		case .Load_Const:
			ci := has_extra ? extra : u32(inst_bx(inst))
			chunk := &eval.chunks[frame.chunk_id]
			ce := eval.consts[int(chunk.const_start) + int(ci)]
			switch ce.kind {
			case .Integer:
				eval.reg_stack[reg_base + a] = value_int(ce.integer)
			case .Text:
				eval.reg_stack[reg_base + a] = value_text_source(frame.chunk_id, ce.offset, ce.length)
			case .Arena_Text:
				eval.reg_stack[reg_base + a] = value_text_arena(ce.offset, ce.length)
			case .Sym:
				eval.reg_stack[reg_base + a] = value_text_sym(lex_parser.Sym_Id(ce.offset))
			case .Hash:
				hidx, hok := hash_intern(eval, ce.hash)
				if !hok {
					refuse(eval, {refusal = .Imports_Full, chunk_id = frame.chunk_id, node = node_idx})
					return false
				}
				eval.reg_stack[reg_base + a] = {kind = .Hash, meta = hidx}
			case .Member:
				eval.reg_stack[reg_base + a] = value_member(lex_parser.Sym_Id(ce.offset), frame.chunk_id, lex_parser.Node_Index(i32(ce.length)))
			}

		case .Get_Upval:
			uv_idx := int(inst_bx(inst))
			tref := eval.env_slots[int(frame.env_off) + uv_idx]
			if !vm_push_or_load_thunk(eval, frame, tref, u8(a), node_idx) {
				return false
			}

		case .Get_Let:
			slot_idx := int(inst_bx(inst))
			tref := eval.let_slots[int(frame.let_base) + slot_idx]
			if !vm_push_or_load_thunk(eval, frame, tref, u8(a), node_idx) {
				return false
			}

		case .Let_Enter:
			desc_rel := has_extra ? extra : u32(inst_bx(inst))
			chunk := &eval.chunks[frame.chunk_id]
			desc := eval.let_descs[int(chunk.let_desc_start) + int(desc_rel)]
			bc := int(desc.binding_count)
			if eval.thunk_count + bc > len(eval.thunks) {
				refuse(eval, {refusal = .Calls_Full, chunk_id = frame.chunk_id, node = node_idx})
				return false
			}
			// 1. Allocate all N Thunk_Refs FIRST so mutual recursion resolves!
			first_thunk := eval.thunk_count
			for i in 0 ..< bc {
				tref := Thunk_Ref(first_thunk + i)
				eval.let_slots[int(frame.let_base) + int(desc.slot_start) + i] = tref
			}
			eval.thunk_count += bc
			// 2. Wire each thunk's captured upvalues (including sibling let slots).
			for i in 0 ..< bc {
				p_rel := eval.let_protos[int(desc.protos_start) + i]
				b_node := eval.let_nodes[int(desc.nodes_start) + i]
				eoff, elen, eok := capture_upvals(eval, frame, frame.chunk_id, p_rel, b_node)
				if !eok {
					return false
				}
				eval.thunks[first_thunk + i] = {
					state   = .Unforced,
					site_id = u32(b_node),
					payload = {code = {chunk_id = frame.chunk_id, proto_id = p_rel, env_off = eoff, env_len = u32(elen)}},
				}
				if eval.profile != nil {
					eval.profile.thunks_created += 1
				}
			}
			// 3. In Console mode, force bindings eagerly from left to right.
			if eval.mode == .Console && bc > 0 {
				if eval.frame_count >= len(eval.frames) {
					refuse(eval, {refusal = .Calls_Full, chunk_id = frame.chunk_id, node = node_idx})
					return false
				}
				cframe := &eval.frames[eval.frame_count]
				cframe^ = {
					kind          = .Console_Let_Force,
					chunk_id      = frame.chunk_id,
					reg_base      = eval.reg_top,
					let_base      = eval.let_slot_top,
					return_thunk  = NO_THUNK,
					cont_list_off = u32(first_thunk),
					cont_count    = u32(bc),
					cont_index    = 0,
					cont_node     = node_idx,
				}
				eval.frame_count += 1
			}

		case .Neg:
			b := int(inst_b(inst))
			v := eval.reg_stack[reg_base + b]
			if v.kind != .Integer {
				refuse(eval, {refusal = .Negate_Kind, chunk_id = frame.chunk_id, node = node_idx, left_kind = v.kind})
				return false
			}
			iv := value_integer(v)
			opp, fits := console_language.integer_negate(iv)
			if !fits {
				refuse(eval, {refusal = .Overflow, chunk_id = frame.chunk_id, node = node_idx, operator = .Subtract, left = 0, right = iv})
				return false
			}
			eval.reg_stack[reg_base + a] = value_int(opp)

		case .Not:
			v := eval.reg_stack[reg_base + int(inst_b(inst))]
			if v.kind != .Boolean {
				refuse(eval, {refusal = .Operator_Kinds, chunk_id = frame.chunk_id, node = node_idx, left_kind = v.kind})
				return false
			}
			eval.reg_stack[reg_base + a] = value_bool(!value_boolean(v))

		case .List_Concat:
			lv := eval.reg_stack[reg_base + int(inst_b(inst))]
			rv := eval.reg_stack[reg_base + int(inst_c(inst))]
			res, lok := vm_list_concat(eval, lv, rv, frame.chunk_id, node_idx)
			if !lok {
				return false
			}
			eval.reg_stack[reg_base + a] = res

		case .Add:
			lv := eval.reg_stack[reg_base + int(inst_b(inst))]
			rv := eval.reg_stack[reg_base + int(inst_c(inst))]
			if lv.kind == .Integer && rv.kind == .Integer {
				li, ri := value_integer(lv), value_integer(rv)
				res, fits := console_language.integer_add(li, ri)
				if !fits {
					refuse(eval, {refusal = .Overflow, chunk_id = frame.chunk_id, node = node_idx, operator = .Add, left_kind = .Integer, right_kind = .Integer, left = li, right = ri})
					return false
				}
				eval.reg_stack[reg_base + a] = value_int(res)
			} else if lv.kind == .Text && rv.kind == .Text {
				lt := value_text(eval, lv)
				rt := value_text(eval, rv)
				need := len(lt) + len(rt)
				if !charge_steps(eval, u32(need / 64), frame.chunk_id, node_idx) {
					return false
				}
				if eval.mode == .Console && eval.host.values_add != nil {
					sum, sok := eval.host.values_add(eval.host.data, value_to_host(eval, lv), value_to_host(eval, rv))
					if !sok {
						refuse(eval, {refusal = .Host_Refused, chunk_id = frame.chunk_id, node = node_idx})
						return false
					}
					sv, cvok := host_to_value(eval, sum)
					if !cvok {
						refuse(eval, {refusal = .Calls_Full, chunk_id = frame.chunk_id, node = node_idx})
						return false
					}
					eval.reg_stack[reg_base + a] = sv
				} else {
					if need == 0 {
						eval.reg_stack[reg_base + a] = {kind = .Text}
					} else if need > len(eval.text_arena) - eval.text_used {
						refuse(eval, {refusal = .Imports_Full, chunk_id = frame.chunk_id, node = node_idx})
						return false
					} else {
						start := eval.text_used
						copy(eval.text_arena[start:], lt)
						copy(eval.text_arena[start + len(lt):], rt)
						eval.text_used += need
						eval.reg_stack[reg_base + a] = value_text_arena(u32(start), u32(need))
					}
				}
			} else if lv.kind == .Table && rv.kind == .Table && eval.host.values_add != nil {
				sum, sok := eval.host.values_add(eval.host.data, value_to_host(eval, lv), value_to_host(eval, rv))
				if !sok {
					refuse(eval, {refusal = .Host_Refused, chunk_id = frame.chunk_id, node = node_idx})
					return false
				}
				sv, cvok := host_to_value(eval, sum)
				if !cvok {
					refuse(eval, {refusal = .Calls_Full, chunk_id = frame.chunk_id, node = node_idx})
					return false
				}
				eval.reg_stack[reg_base + a] = sv
			} else {
				refuse(eval, {refusal = .Operator_Kinds, chunk_id = frame.chunk_id, node = node_idx, operator = .Add, left_kind = lv.kind, right_kind = rv.kind})
				return false
			}

		case .Sub:
			lv := eval.reg_stack[reg_base + int(inst_b(inst))]
			rv := eval.reg_stack[reg_base + int(inst_c(inst))]
			if lv.kind != .Integer || rv.kind != .Integer {
				refuse(eval, {refusal = .Operator_Kinds, chunk_id = frame.chunk_id, node = node_idx, operator = .Subtract, left_kind = lv.kind, right_kind = rv.kind})
				return false
			}
			li, ri := value_integer(lv), value_integer(rv)
			res, fits := console_language.integer_subtract(li, ri)
			if !fits {
				refuse(eval, {refusal = .Overflow, chunk_id = frame.chunk_id, node = node_idx, operator = .Subtract, left_kind = .Integer, right_kind = .Integer, left = li, right = ri})
				return false
			}
			eval.reg_stack[reg_base + a] = value_int(res)

		case .Mul:
			lv := eval.reg_stack[reg_base + int(inst_b(inst))]
			rv := eval.reg_stack[reg_base + int(inst_c(inst))]
			if lv.kind != .Integer || rv.kind != .Integer {
				refuse(eval, {refusal = .Operator_Kinds, chunk_id = frame.chunk_id, node = node_idx, operator = .Multiply, left_kind = lv.kind, right_kind = rv.kind})
				return false
			}
			li, ri := value_integer(lv), value_integer(rv)
			res, fits := console_language.integer_multiply(li, ri)
			if !fits {
				refuse(eval, {refusal = .Overflow, chunk_id = frame.chunk_id, node = node_idx, operator = .Multiply, left_kind = .Integer, right_kind = .Integer, left = li, right = ri})
				return false
			}
			eval.reg_stack[reg_base + a] = value_int(res)

		case .Div, .Rem:
			lv := eval.reg_stack[reg_base + int(inst_b(inst))]
			rv := eval.reg_stack[reg_base + int(inst_c(inst))]
			op_kind: lex_parser.Operator = op == .Div ? .Divide : .Remainder
			if lv.kind != .Integer || rv.kind != .Integer {
				refuse(eval, {refusal = .Operator_Kinds, chunk_id = frame.chunk_id, node = node_idx, operator = op_kind, left_kind = lv.kind, right_kind = rv.kind})
				return false
			}
			li, ri := value_integer(lv), value_integer(rv)
			if ri == 0 {
				refuse(eval, {refusal = .Division_By_Zero, chunk_id = frame.chunk_id, node = node_idx, operator = op_kind, left_kind = .Integer, right_kind = .Integer, left = li, right = ri})
				return false
			}
			q, rem, fits := console_language.integer_divide(li, ri)
			if op == .Div {
				if !fits {
					refuse(eval, {refusal = .Overflow, chunk_id = frame.chunk_id, node = node_idx, operator = .Divide, left_kind = .Integer, right_kind = .Integer, left = li, right = ri})
					return false
				}
				eval.reg_stack[reg_base + a] = value_int(q)
			} else {
				eval.reg_stack[reg_base + a] = value_int(ri == -1 ? 0 : rem)
			}

		case .Eq, .Neq, .Lt, .Le, .Gt, .Ge:
			lv := eval.reg_stack[reg_base + int(inst_b(inst))]
			rv := eval.reg_stack[reg_base + int(inst_c(inst))]
			res, cmp_ok := vm_compare(eval, op, lv, rv, frame.chunk_id, node_idx)
			if !cmp_ok {
				return false
			}
			eval.reg_stack[reg_base + a] = value_bool(res)

		case .Jmp:
			if has_extra {
				frame.ip = extra
			} else {
				frame.ip = u32(i64(frame.ip) + i64(inst_sbx(inst)))
			}

		case .Jmp_If_False:
			cond := eval.reg_stack[reg_base + a]
			if cond.kind != .Boolean {
				refuse(eval, {refusal = .Condition_Not_Boolean, chunk_id = frame.chunk_id, node = node_idx, left_kind = cond.kind})
				return false
			}
			if !value_boolean(cond) {
				if has_extra {
					frame.ip = extra
				} else {
					frame.ip = u32(i64(frame.ip) + i64(inst_sbx(inst)))
				}
			}

		case .Jmp_If_False_Keep:
			cond := eval.reg_stack[reg_base + a]
			if cond.kind != .Boolean {
				refuse(eval, {refusal = .Operator_Kinds, chunk_id = frame.chunk_id, node = node_idx, operator = .Logical_And, left_kind = cond.kind})
				return false
			}
			if !value_boolean(cond) {
				if has_extra {
					frame.ip = extra
				} else {
					frame.ip = u32(i64(frame.ip) + i64(inst_sbx(inst)))
				}
			}

		case .Jmp_If_True_Keep:
			cond := eval.reg_stack[reg_base + a]
			if cond.kind != .Boolean {
				refuse(eval, {refusal = .Condition_Not_Boolean, chunk_id = frame.chunk_id, node = node_idx, operator = .Logical_Or, left_kind = cond.kind})
				return false
			}
			if value_boolean(cond) {
				if has_extra {
					frame.ip = extra
				} else {
					frame.ip = u32(i64(frame.ip) + i64(inst_sbx(inst)))
				}
			}

		case .Check_Bool:
			val := eval.reg_stack[reg_base + a]
			if val.kind != .Boolean {
				op_kind, _ := lex_parser.operator_of_byte(inst_b(inst))
				refuse(eval, {refusal = .Operator_Kinds, chunk_id = frame.chunk_id, node = node_idx, operator = op_kind, left_kind = .Boolean, right_kind = val.kind})
				return false
			}

		case .Closure:
			p_rel := has_extra ? extra : u32(inst_bx(inst))
			eoff, elen, eok := capture_upvals(eval, frame, frame.chunk_id, p_rel, node_idx)
			if !eok {
				return false
			}
			if eval.closure_count >= len(eval.closures) {
				refuse(eval, {refusal = .Calls_Full, chunk_id = frame.chunk_id, node = node_idx})
				return false
			}
			cidx := u32(eval.closure_count)
			eval.closures[cidx] = {
				chunk_id  = frame.chunk_id,
				upval_len = elen,
				proto_id  = p_rel,
				upval_off = eoff,
			}
			eval.closure_count += 1
			eval.reg_stack[reg_base + a] = {kind = .Function, data = u64(cidx)}

		case .Check_Call:
			argc := int(inst_b(inst))
			callee := eval.reg_stack[reg_base + a]
			if callee.kind != .Function {
				refuse(eval, {refusal = .Not_A_Function, chunk_id = frame.chunk_id, node = node_idx, command = node_text_in_chunk(eval, frame.chunk_id, node_idx), left_kind = callee.kind})
				return false
			}
			cl := eval.closures[int(callee.data)]
			cchunk := &eval.chunks[cl.chunk_id]
			cproto := &eval.protos[int(cchunk.proto_start) + int(cl.proto_id)]
			if argc != int(cproto.param_count) {
				refuse(eval, {refusal = .Function_Arguments, chunk_id = frame.chunk_id, node = node_idx, command = node_text_in_chunk(eval, frame.chunk_id, node_idx), left = i64(argc), right = i64(cproto.param_count)})
				return false
			}

		case .Call, .Tail_Call:
			argc := int(inst_b(inst))
			callee := eval.reg_stack[reg_base + a]
			if callee.kind != .Function {
				refuse(eval, {refusal = .Not_A_Function, chunk_id = frame.chunk_id, node = node_idx, command = node_text_in_chunk(eval, frame.chunk_id, node_idx), left_kind = callee.kind})
				return false
			}
			cl := eval.closures[int(callee.data)]
			cchunk := &eval.chunks[cl.chunk_id]
			cproto := &eval.protos[int(cchunk.proto_start) + int(cl.proto_id)]
			if argc != int(cproto.param_count) {
				refuse(eval, {refusal = .Function_Arguments, chunk_id = frame.chunk_id, node = node_idx, command = node_text_in_chunk(eval, frame.chunk_id, node_idx), left = i64(argc), right = i64(cproto.param_count)})
				return false
			}
			eval.call_count += 1
			if eval.profile != nil {
				eval.profile.calls_total += 1
			}
			if op == .Tail_Call {
				// O(1) Tail-Call Optimization: reuse active Bytecode frame!
				if eval.profile != nil {
					eval.profile.tail_calls_total += 1
				}
				need_regs := u32(max(int(cproto.max_regs), argc))
				if int(frame.reg_base) + int(need_regs) > len(eval.reg_stack) ||
				   int(frame.let_base) + int(cproto.let_slot_count) > len(eval.let_slots) {
					refuse(eval, {refusal = .Calls_Full, chunk_id = frame.chunk_id, node = node_idx})
					return false
				}
				// Move args from reg_base + a + 1 .. reg_base + a + argc to reg_base + 0 .. argc - 1.
				for i in 0 ..< argc {
					eval.reg_stack[reg_base + i] = eval.reg_stack[reg_base + a + 1 + i]
				}
				eval.reg_top = frame.reg_base + need_regs
				eval.let_slot_top = frame.let_base + u32(cproto.let_slot_count)
				frame.chunk_id = cl.chunk_id
				frame.proto_id = cl.proto_id
				frame.ip = cproto.code_start
				frame.env_off = cl.upval_off
				frame.env_len = cl.upval_len
				if cproto.boxed_param_mask != 0 {
					for i in 0 ..< argc {
						if (cproto.boxed_param_mask & (u16(1) << u16(i))) != 0 {
							if eval.thunk_count >= len(eval.thunks) {
								refuse(eval, {refusal = .Calls_Full, chunk_id = cl.chunk_id, node = node_idx})
								return false
							}
							tref := Thunk_Ref(eval.thunk_count)
							eval.thunk_count += 1
							eval.thunks[tref] = {state = .Forced, site_id = u32(cproto.node_idx), payload = {value = eval.reg_stack[reg_base + i]}}
							frame.boxed_params[i] = tref
						}
					}
				}
			} else {
				args := eval.reg_stack[reg_base + a + 1 : reg_base + a + 1 + argc]
				if !push_bytecode_frame(eval, cl.chunk_id, cl.proto_id, cl.upval_off, cl.upval_len, args, u8(a), NO_THUNK, node_idx) {
					return false
				}
			}

		case .Call_Builtin:
			bid, bid_ok := builtin_of_byte(inst_b(inst))
			if !bid_ok {
				refuse(eval, {refusal = .Host_Refused, chunk_id = frame.chunk_id, node = node_idx})
				return false
			}
			argc := int(inst_c(inst))
			args := eval.reg_stack[reg_base + a + 1 : reg_base + a + 1 + argc]
			if !vm_exec_builtin(eval, frame, bid, args, u8(a), node_idx) {
				return false
			}

		case .Call_Site:
			site_rel := has_extra ? extra : u32(inst_bx(inst))
			if !vm_exec_call_site(eval, frame, site_rel, u8(a)) {
				return false
			}

		case .Ret:
			res := eval.reg_stack[reg_base + a]
			vm_return_to_caller(eval, target_depth, res)

		case .Make_Record:
			desc_rel := has_extra ? extra : u32(inst_bx(inst))
			rec_val, rok := vm_instantiate_record(eval, frame, desc_rel, node_idx)
			if !rok {
				return false
			}
			eval.reg_stack[reg_base + a] = rec_val
			// In Console mode, eagerly force all fields in source order.
			if eval.mode == .Console {
				rec := eval.records[int(rec_val.data)]
				shape := &eval.shapes[rec.shape_id]
				if shape.field_count > 0 {
					if eval.frame_count >= len(eval.frames) {
						refuse(eval, {refusal = .Calls_Full, chunk_id = frame.chunk_id, node = node_idx})
						return false
					}
					cframe := &eval.frames[eval.frame_count]
					cframe^ = {
						kind          = .Console_Rec_Force,
						dst_reg       = u8(a),
						chunk_id      = frame.chunk_id,
						reg_base      = eval.reg_top,
						let_base      = eval.let_slot_top,
						return_thunk  = NO_THUNK,
						cont_list_off = u32(rec_val.data),
						cont_count    = shape.field_count,
						cont_index    = 0,
						cont_fn       = rec_val,
						cont_node     = node_idx,
					}
					eval.frame_count += 1
				}
			}

		case .Get_Field:
			b := int(inst_b(inst))
			c_op := int(inst_c(inst))
			sym_rel := has_extra && c_op == 255 ? extra : u32(c_op)
			chunk := &eval.chunks[frame.chunk_id]
			sym := eval.field_syms[int(chunk.field_sym_start) + int(sym_rel)]
			base := eval.reg_stack[reg_base + b]
			if is_lazy_record(base.kind) {
				if tref, found := lazy_record_lookup_thunk(eval, base, sym); found {
					if !vm_push_or_load_thunk(eval, frame, tref, u8(a), node_idx) {
						return false
					}
					continue
				}
			} else if base.kind == .Record {
				hv := value_to_host(eval, base)
				fname := lex_parser.sym_text(&eval.interner, sym)
				if res, found := record_field_value(hv, fname); found {
					vv, vok := host_to_value(eval, res)
					if !vok {
						refuse(eval, {refusal = .Calls_Full, chunk_id = frame.chunk_id, node = node_idx})
						return false
					}
					eval.reg_stack[reg_base + a] = vv
					continue
				}
				refuse(eval, {refusal = .Field_Unknown, chunk_id = frame.chunk_id, node = node_idx, field = fname, left_kind = .Record, file = hv.file, detail = hv.detail})
				return false
			}
			fname := lex_parser.sym_text(&eval.interner, sym)
			rec := Refusal_Record{refusal = .Field_Unknown, chunk_id = frame.chunk_id, node = node_idx, field = fname, left_kind = base.kind}
			if is_lazy_record(base.kind) {
				if sid, sok := lazy_record_base_shape(eval, base); sok {
					suggest_shape_fields(eval, sid, fname, &rec)
				}
			}
			refuse(eval, rec)
			return false

		case .With:
			lv := eval.reg_stack[reg_base + int(inst_b(inst))]
			rv := eval.reg_stack[reg_base + int(inst_c(inst))]
			res, wok := vm_with(eval, lv, rv, frame.chunk_id, node_idx)
			if !wok {
				return false
			}
			eval.reg_stack[reg_base + a] = res

		case .Destructure:
			pat_rel := has_extra ? extra : u32(inst_bx(inst))
			src_val := eval.reg_stack[reg_base + a]
			if !vm_destructure(eval, frame, src_val, pat_rel, node_idx) {
				return false
			}

		case .List_Begin, .Str_Begin:
			if eval.list_mark_count >= len(eval.list_marks) {
				refuse(eval, {refusal = .Lists_Full, chunk_id = frame.chunk_id, node = node_idx})
				return false
			}
			eval.list_marks[eval.list_mark_count] = eval.list_scratch_top
			eval.list_mark_count += 1

		case .List_Push:
			item := eval.reg_stack[reg_base + a]
			if eval.mode == .Console && (item.kind == .None || item.kind == .Stream || item.kind == .Record_Input) {
				refuse(eval, {refusal = .List_Item_Kind, chunk_id = frame.chunk_id, node = node_idx, left_kind = item.kind})
				return false
			}
			if int(eval.list_scratch_top) >= len(eval.list_scratch) {
				refuse(eval, {refusal = .Lists_Full, chunk_id = frame.chunk_id, node = node_idx})
				return false
			}
			eval.list_scratch[eval.list_scratch_top] = item
			eval.list_scratch_top += 1

		case .List_End:
			eval.list_mark_count -= 1
			mark := eval.list_marks[eval.list_mark_count]
			cnt := int(eval.list_scratch_top - mark)
			eval.list_scratch_top = mark
			if cnt > len(eval.list_items) - eval.list_item_count {
				refuse(eval, {refusal = .Lists_Full, chunk_id = frame.chunk_id, node = node_idx})
				return false
			}
			first := eval.list_item_count
			copy(eval.list_items[first:], eval.list_scratch[mark:mark + u32(cnt)])
			eval.list_item_count += cnt
			eval.reg_stack[reg_base + a] = {kind = .List, data = u64(first), meta = u32(cnt)}

		case .Str_Push:
			if !vm_str_interp_push(eval, eval.reg_stack[reg_base + a], frame.chunk_id, node_idx) {
				return false
			}

		case .Str_End:
			res, sok := vm_str_interp_end(eval, frame.chunk_id, node_idx)
			if !sok {
				return false
			}
			eval.reg_stack[reg_base + a] = res

		case .Assert_Fail:
			mv := eval.reg_stack[reg_base + a]
			if mv.kind != .Text {
				refuse(eval, {refusal = .Operator_Kinds, chunk_id = frame.chunk_id, node = node_idx, command = ASSERT_NAME, left_kind = mv.kind})
				return false
			}
			refuse(eval, {refusal = .Assertion_Failed, chunk_id = frame.chunk_id, node = node_idx, command = value_text(eval, mv)})
			return false

		case .Trace:
			mv := eval.reg_stack[reg_base + a]
			if mv.kind != .Text {
				refuse(eval, {refusal = .Operator_Kinds, chunk_id = frame.chunk_id, node = node_idx, command = TRACE_NAME, left_kind = mv.kind})
				return false
			}
			eval.traced = true
			if eval.trace_log != nil {
				if eval.trace_log.count < TRACE_LOG_CAPACITY {
					place: lex_parser.Place
					if int(frame.chunk_id) < eval.chunk_count && eval.chunks[frame.chunk_id].tree != nil && node_idx != lex_parser.NO_NODE {
						place = lex_parser.node_place(eval.chunks[frame.chunk_id].tree, node_idx)
					}
					eval.trace_log.entries[eval.trace_log.count] = {place = place, message = value_text(eval, mv)}
					eval.trace_log.count += 1
				} else {
					eval.trace_log.dropped += 1
				}
			}

		case .Load_Global:
			ci := has_extra ? extra : u32(inst_bx(inst))
			chunk := &eval.chunks[frame.chunk_id]
			ce := eval.consts[int(chunk.const_start) + int(ci)]
			name := lex_parser.sym_text(&eval.interner, lex_parser.Sym_Id(ce.offset))
			if eval.host.name_value == nil {
				refuse(eval, {refusal = .Host_Refused, chunk_id = frame.chunk_id, node = node_idx})
				return false
			}
			hv, hok := eval.host.name_value(eval.host.data, name)
			if refused(eval) {
				return false
			}
			if !hok {
				refuse(eval, {refusal = .Host_Refused, chunk_id = frame.chunk_id, node = node_idx})
				return false
			}
			vv, vok := host_to_value(eval, hv)
			if !vok {
				refuse(eval, {refusal = .Calls_Full, chunk_id = frame.chunk_id, node = node_idx})
				return false
			}
			eval.reg_stack[reg_base + a] = vv

		case .Refuse_Parse:
			rn := lex_parser.Node_Index(i32(has_extra ? extra : u32(inst_bx(inst))))
			chunk := &eval.chunks[frame.chunk_id]
			tref := lex_parser.Refusal.Unexpected
			if chunk.tree != nil && rn != lex_parser.NO_NODE {
				tref = lex_parser.node_refusal(chunk.tree, rn)
				if tref == .None {
					n := lex_parser.node_at(chunk.tree, rn)
					if n != nil {
						#partial switch n.kind {
						case .Hash: tref = .Hash_Not_Valid
						case .Let:  tref = .Let_In_Missing
						case .If:   tref = .If_Then_Missing
						}
					}
				}
			}
			refuse(eval, {refusal = .Text, text_refusal = tref, chunk_id = frame.chunk_id, node = rn})
			return false
		}
	}
	return true
}

@(private)
vm_push_or_load_thunk :: proc "contextless" (eval: ^Evaluation, frame: ^VM_Frame, tref: Thunk_Ref, dst_reg: u8, node_idx: lex_parser.Node_Index) -> bool {
	th := &eval.thunks[tref]
	switch th.state {
	case .Forced:
		if eval.profile != nil {
			eval.profile.thunks_reused += 1
		}
		eval.reg_stack[int(frame.reg_base) + int(dst_reg)] = th.payload.value
		return true
	case .Forcing:
		refuse(eval, {refusal = .Cycle, chunk_id = frame.chunk_id, node = node_idx, command = thunk_cycle_name(eval, th)})
		return false
	case .Unforced:
		code := th.payload.code
		th.state = .Forcing
		if eval.profile != nil {
			eval.profile.thunks_forced += 1
		}
		return push_bytecode_frame(eval, code.chunk_id, code.proto_id, code.env_off, u16(code.env_len), nil, dst_reg, tref, node_idx)
	}
	return false
}

@(private)
vm_step_continuation :: proc "contextless" (eval: ^Evaluation, frame: ^VM_Frame, target_depth: int) -> bool {
	switch frame.kind {
	case .Bytecode:
		return true

	case .Console_Let_Force:
		if frame.cont_index >= frame.cont_count {
			eval.frame_count -= 1
			return true
		}
		tref := Thunk_Ref(frame.cont_list_off + frame.cont_index)
		frame.cont_index += 1
		th := &eval.thunks[tref]
		if th.state == .Unforced {
			code := th.payload.code
			th.state = .Forcing
			if eval.profile != nil {
				eval.profile.thunks_forced += 1
			}
			// Reserve 1 dummy reg for discarded result.
			if int(eval.reg_top) >= len(eval.reg_stack) {
				refuse(eval, {refusal = .Calls_Full, chunk_id = frame.chunk_id, node = frame.cont_node})
				return false
			}
			return push_bytecode_frame(eval, code.chunk_id, code.proto_id, code.env_off, u16(code.env_len), nil, 0, tref, frame.cont_node)
		}
		return true

	case .Console_Rec_Force:
		if frame.cont_index >= frame.cont_count {
			res := frame.cont_fn
			vm_return_to_caller(eval, target_depth, res)
			return true
		}
		rec := eval.records[frame.cont_list_off]
		chunk := &eval.chunks[rec.chunk_id]
		desc := eval.rec_descs[int(chunk.rec_desc_start) + int(rec.desc_id)]
		canon_idx := eval.rec_source_orders[int(desc.source_order_off) + int(frame.cont_index)]
		frame.cont_index += 1
		tref := eval.record_thunk_refs[int(rec.refs_off) + int(canon_idx)]
		th := &eval.thunks[tref]
		if th.state == .Unforced {
			code := th.payload.code
			th.state = .Forcing
			if eval.profile != nil {
				eval.profile.thunks_forced += 1
			}
			return push_bytecode_frame(eval, code.chunk_id, code.proto_id, code.env_off, u16(code.env_len), nil, 0, tref, frame.cont_node)
		}
		return true

	case .Map:
		if frame.cont_index > 0 {
			// Consume item produced by previous callback invocation.
			item := eval.reg_stack[frame.reg_base]
			if eval.mode == .Console && (item.kind == .None || item.kind == .Stream || item.kind == .Record_Input) {
				refuse(eval, {refusal = .List_Item_Kind, chunk_id = frame.chunk_id, node = frame.cont_node, left_kind = item.kind})
				return false
			}
			if int(eval.list_scratch_top) >= len(eval.list_scratch) {
				refuse(eval, {refusal = .Lists_Full, chunk_id = frame.chunk_id, node = frame.cont_node})
				return false
			}
			eval.list_scratch[eval.list_scratch_top] = item
			eval.list_scratch_top += 1
		}
		if frame.cont_index >= frame.cont_count {
			mark := frame.cont_out_off
			cnt := int(eval.list_scratch_top - mark)
			eval.list_scratch_top = mark
			if cnt > len(eval.list_items) - eval.list_item_count {
				refuse(eval, {refusal = .Lists_Full, chunk_id = frame.chunk_id, node = frame.cont_node})
				return false
			}
			first := eval.list_item_count
			copy(eval.list_items[first:], eval.list_scratch[mark:mark + u32(cnt)])
			eval.list_item_count += cnt
			vm_return_to_caller(eval, target_depth, {kind = .List, data = u64(first), meta = u32(cnt)})
			return true
		}
		arg := eval.list_items[frame.cont_list_off + frame.cont_index]
		frame.cont_index += 1
		cl := eval.closures[int(frame.cont_fn.data)]
		eval.call_count += 1
		if eval.profile != nil {
			eval.profile.calls_total += 1
		}
		args := [1]Value{arg}
		return push_bytecode_frame(eval, cl.chunk_id, cl.proto_id, cl.upval_off, cl.upval_len, args[:], 0, NO_THUNK, frame.cont_node)

	case .Filter:
		if frame.cont_index > 0 {
			pred := eval.reg_stack[frame.reg_base]
			if pred.kind != .Boolean {
				refuse(eval, {refusal = .Condition_Not_Boolean, chunk_id = frame.chunk_id, node = frame.cont_node, left_kind = pred.kind})
				return false
			}
			if value_boolean(pred) {
				if int(eval.list_scratch_top) >= len(eval.list_scratch) {
					refuse(eval, {refusal = .Lists_Full, chunk_id = frame.chunk_id, node = frame.cont_node})
					return false
				}
				eval.list_scratch[eval.list_scratch_top] = eval.list_items[frame.cont_list_off + frame.cont_index - 1]
				eval.list_scratch_top += 1
			}
		}
		if frame.cont_index >= frame.cont_count {
			mark := frame.cont_out_off
			cnt := int(eval.list_scratch_top - mark)
			eval.list_scratch_top = mark
			if cnt > len(eval.list_items) - eval.list_item_count {
				refuse(eval, {refusal = .Lists_Full, chunk_id = frame.chunk_id, node = frame.cont_node})
				return false
			}
			first := eval.list_item_count
			copy(eval.list_items[first:], eval.list_scratch[mark:mark + u32(cnt)])
			eval.list_item_count += cnt
			vm_return_to_caller(eval, target_depth, {kind = .List, data = u64(first), meta = u32(cnt)})
			return true
		}
		arg := eval.list_items[frame.cont_list_off + frame.cont_index]
		frame.cont_index += 1
		cl := eval.closures[int(frame.cont_fn.data)]
		eval.call_count += 1
		if eval.profile != nil {
			eval.profile.calls_total += 1
		}
		args := [1]Value{arg}
		return push_bytecode_frame(eval, cl.chunk_id, cl.proto_id, cl.upval_off, cl.upval_len, args[:], 0, NO_THUNK, frame.cont_node)

	case .Fold:
		acc := eval.reg_stack[frame.reg_base]
		if frame.cont_index >= frame.cont_count {
			vm_return_to_caller(eval, target_depth, acc)
			return true
		}
		item := eval.list_items[frame.cont_list_off + frame.cont_index]
		frame.cont_index += 1
		cl := eval.closures[int(frame.cont_fn.data)]
		eval.call_count += 1
		if eval.profile != nil {
			eval.profile.calls_total += 1
		}
		args := [2]Value{acc, item}
		return push_bytecode_frame(eval, cl.chunk_id, cl.proto_id, cl.upval_off, cl.upval_len, args[:], 0, NO_THUNK, frame.cont_node)
	}
	return true
}

@(private)
vm_start_map_filter :: proc "contextless" (eval: ^Evaluation, frame: ^VM_Frame, bid: Builtin_Id, list_val, fn_val: Value, dst_reg: u8, node_idx: lex_parser.Node_Index) -> bool {
	cmd := bid == .Map ? MAP_NAME : FILTER_NAME
	if list_val.kind != .List {
		refuse(eval, {refusal = .Not_A_List, chunk_id = frame.chunk_id, node = node_idx, command = cmd, parameter = 1, left_kind = list_val.kind})
		return false
	}
	if fn_val.kind != .Function {
		refuse(eval, {refusal = .Not_A_Function, chunk_id = frame.chunk_id, node = node_idx, command = cmd, parameter = 2, left_kind = fn_val.kind})
		return false
	}
	cl := eval.closures[int(fn_val.data)]
	cchunk := &eval.chunks[cl.chunk_id]
	cproto := &eval.protos[int(cchunk.proto_start) + int(cl.proto_id)]
	if cproto.param_count != 1 {
		refuse(eval, {refusal = .Function_Arguments, chunk_id = frame.chunk_id, node = node_idx, command = cmd, parameter = 2, left = 1, right = i64(cproto.param_count)})
		return false
	}
	cnt := list_val.meta
	if cnt == 0 {
		eval.reg_stack[int(frame.reg_base) + int(dst_reg)] = {kind = .List, data = u64(eval.list_item_count), meta = 0}
		return true
	}
	// Pre-check list capacity for Map (matches v1 semantics: refuse before calling fn).
	if bid == .Map && int(cnt) > len(eval.list_items) - eval.list_item_count {
		refuse(eval, {refusal = .Lists_Full, chunk_id = frame.chunk_id, node = node_idx})
		return false
	}
	if eval.frame_count >= len(eval.frames) || int(eval.reg_top) + 1 > len(eval.reg_stack) {
		refuse(eval, {refusal = .Calls_Full, chunk_id = frame.chunk_id, node = node_idx})
		return false
	}
	reg_base := eval.reg_top
	eval.reg_top += 1
	cframe := &eval.frames[eval.frame_count]
	cframe^ = {
		kind          = bid == .Map ? .Map : .Filter,
		dst_reg       = dst_reg,
		chunk_id      = frame.chunk_id,
		reg_base      = reg_base,
		let_base      = eval.let_slot_top,
		return_thunk  = NO_THUNK,
		cont_list_off = u32(list_val.data),
		cont_count    = cnt,
		cont_index    = 0,
		cont_out_off  = eval.list_scratch_top,
		cont_fn       = fn_val,
		cont_node     = node_idx,
	}
	eval.frame_count += 1
	return true
}

@(private)
vm_instantiate_record :: proc "contextless" (eval: ^Evaluation, frame: ^VM_Frame, desc_rel: u32, node_idx: lex_parser.Node_Index) -> (Value, bool) {
	chunk := &eval.chunks[frame.chunk_id]
	desc := eval.rec_descs[int(chunk.rec_desc_start) + int(desc_rel)]
	fcount := int(desc.field_count)
	if eval.record_count >= len(eval.records) ||
	   eval.thunk_count + fcount > len(eval.thunks) ||
	   eval.record_thunk_ref_count + fcount > len(eval.record_thunk_refs) {
		return refuse(eval, {refusal = .Calls_Full, chunk_id = frame.chunk_id, node = node_idx})
	}
	refs_off := u32(eval.record_thunk_ref_count)
	for i in 0 ..< fcount {
		p_rel := eval.rec_field_protos[int(desc.protos_start) + i]
		f_node := eval.rec_field_nodes[int(desc.nodes_start) + i]
		eoff, elen, eok := capture_upvals(eval, frame, frame.chunk_id, p_rel, f_node)
		if !eok {
			return {}, false
		}
		tref := Thunk_Ref(eval.thunk_count)
		eval.thunk_count += 1
		eval.thunks[tref] = {
			state   = .Unforced,
			site_id = u32(f_node),
			payload = {code = {chunk_id = frame.chunk_id, proto_id = p_rel, env_off = eoff, env_len = u32(elen)}},
		}
		eval.record_thunk_refs[int(refs_off) + i] = tref
		if eval.profile != nil {
			eval.profile.thunks_created += 1
		}
	}
	eval.record_thunk_ref_count += fcount

	rec_idx := u32(eval.record_count)
	eval.records[rec_idx] = {
		shape_id = desc.shape_id,
		refs_off = refs_off,
		chunk_id = frame.chunk_id,
		node_idx = desc.literal_node,
		desc_id  = desc_rel,
	}
	eval.record_count += 1
	return {kind = .Record_Literal, data = u64(rec_idx), meta = desc.shape_id}, true
}

// ---- Comparison (step-charged).

@(private)
vm_compare :: proc "contextless" (eval: ^Evaluation, op: Opcode, left, right: Value, chunk_id: u16, node_idx: lex_parser.Node_Index) -> (bool, bool) {
	parser_op: lex_parser.Operator
	#partial switch op {
	case .Eq:  parser_op = .Equal
	case .Neq: parser_op = .Not_Equal
	case .Lt:  parser_op = .Less
	case .Le:  parser_op = .Less_Or_Equal
	case .Gt:  parser_op = .Greater
	case .Ge:  parser_op = .Greater_Or_Equal
	}
	if left.kind != right.kind {
		refuse(eval, {refusal = .Operator_Kinds, chunk_id = chunk_id, node = node_idx, operator = parser_op, left_kind = left.kind, right_kind = right.kind})
		return false, false
	}
	is_order := op != .Eq && op != .Neq
	switch left.kind {
	case .Integer:
		li, ri := value_integer(left), value_integer(right)
		#partial switch op {
		case .Eq:  return li == ri, true
		case .Neq: return li != ri, true
		case .Lt:  return li < ri, true
		case .Le:  return li <= ri, true
		case .Gt:  return li > ri, true
		case .Ge:  return li >= ri, true
		}
	case .Boolean:
		if is_order {
			refuse(eval, {refusal = .Operator_Kinds, chunk_id = chunk_id, node = node_idx, operator = parser_op, left_kind = left.kind, right_kind = right.kind})
			return false, false
		}
		same := value_boolean(left) == value_boolean(right)
		return op == .Eq ? same : !same, true
	case .Text:
		lt := value_text(eval, left)
		rt := value_text(eval, right)
		if !charge_steps(eval, u32(min(len(lt), len(rt)) / 64), chunk_id, node_idx) {
			return false, false
		}
		if is_order {
			c := str_cmp(lt, rt)
			#partial switch op {
			case .Lt: return c < 0, true
			case .Le: return c <= 0, true
			case .Gt: return c > 0, true
			case .Ge: return c >= 0, true
			}
		}
		same := lt == rt
		return op == .Eq ? same : !same, true
	case .Hash, .Module_Ref, .Tree_Ref:
		if is_order {
			refuse(eval, {refusal = .Operator_Kinds, chunk_id = chunk_id, node = node_idx, operator = parser_op, left_kind = left.kind, right_kind = right.kind})
			return false, false
		}
		lh, lok := hash_of(eval, left)
		rh, rok := hash_of(eval, right)
		same := lok && rok && lh == rh
		return op == .Eq ? same : !same, true
	case .Member:
		if is_order {
			refuse(eval, {refusal = .Operator_Kinds, chunk_id = chunk_id, node = node_idx, operator = parser_op, left_kind = left.kind, right_kind = right.kind})
			return false, false
		}
		same := left.meta == right.meta
		return op == .Eq ? same : !same, true
	case .None, .Record, .Handle, .Table, .Bytes, .Stream, .Record_Input, .Record_Literal, .Enum, .Function, .List, .Record_With, .Recipe_Ref, .Follow_Ref, .Store_Ref, .Plan_Value, .Project_Value:
	}
	refuse(eval, {refusal = .Operator_Kinds, chunk_id = chunk_id, node = node_idx, operator = parser_op, left_kind = left.kind, right_kind = right.kind})
	return false, false
}

// ---- `with` operator (strictly override-only in both modes).

@(private)
vm_with :: proc "contextless" (eval: ^Evaluation, left, right: Value, chunk_id: u16, node_idx: lex_parser.Node_Index) -> (result: Value, ok: bool) {
	// Lazy record composition in declaration mode (and on Plan/Project values).
	if (eval.mode == .Declaration || left.kind == .Plan_Value || left.kind == .Project_Value) && is_lazy_record(left.kind) && is_lazy_record(right.kind) {
		left_shape_id, ls_ok := lazy_record_base_shape(eval, left)
		right_shape_id, rs_ok := lazy_record_base_shape(eval, right)
		if !ls_ok || !rs_ok {
			return refuse(eval, {refusal = .With_Kinds, chunk_id = chunk_id, node = node_idx, left_kind = left.kind, right_kind = right.kind})
		}
		record_shape_dep(eval, left, left_shape_id)
		record_shape_dep(eval, right, right_shape_id)
		// Strictly override-only: eagerly verify every field of right exists in
		// left's shape without forcing any field value!
		rshape := &eval.shapes[right_shape_id]
		rfields := eval.shape_fields[int(rshape.fields_off):int(rshape.fields_off) + int(rshape.field_count)]
		for sym in rfields {
			if _, exists := shape_lookup_sym(eval, left_shape_id, sym); !exists {
				fname := lex_parser.sym_text(&eval.interner, sym)
				rec := Refusal_Record{refusal = .Field_Unknown, chunk_id = chunk_id, node = node_idx, field = fname, left_kind = left.kind}
				suggest_shape_fields(eval, left_shape_id, fname, &rec)
				return refuse(eval, rec)
			}
		}
		patch_rec := lazy_record_compact(eval, right, chunk_id, node_idx) or_return
		base_depth: u16 = 0
		if left.kind == .Record_With {
			base_depth = eval.overlays[int(left.data)].depth
		}
		if eval.overlay_count >= len(eval.overlays) {
			return refuse(eval, {refusal = .With_Pairs_Full, chunk_id = chunk_id, node = node_idx})
		}
		ov_idx := u32(eval.overlay_count)
		eval.overlays[ov_idx] = {
			base          = left,
			base_shape_id = left_shape_id,
			patch_rec     = patch_rec,
			depth         = base_depth + 1,
		}
		eval.overlay_count += 1
		ov_val := Value{kind = .Record_With, data = u64(ov_idx), meta = u32(base_depth + 1)}
		if base_depth + 1 > OVERLAY_COMPACT_THRESHOLD {
			flat_idx := lazy_record_compact(eval, ov_val, chunk_id, node_idx) or_return
			return {kind = .Record_Literal, data = u64(flat_idx), meta = left_shape_id}, true
		}
		return ov_val, true
	}

	// Console host Record `with` Record / Record_Literal.
	if left.kind != .Record {
		return refuse(eval, {refusal = .With_Kinds, chunk_id = chunk_id, node = node_idx, left_kind = left.kind, right_kind = right.kind})
	}
	lhv := value_to_host(eval, left)
	if right.kind == .Record {
		rhv := value_to_host(eval, right)
		if !module.records_equal(lhv.file, lhv.detail, rhv.file, rhv.detail) {
			return refuse(eval, {refusal = .With_Records_Differ, chunk_id = chunk_id, node = node_idx, file = lhv.file, detail = lhv.detail, other_file = rhv.file, other_detail = rhv.detail})
		}
		return right, true
	}
	if right.kind != .Record_Literal {
		return refuse(eval, {refusal = .With_Kinds, chunk_id = chunk_id, node = node_idx, left_kind = left.kind, right_kind = right.kind})
	}
	res_hv := literal_type_to_record(eval, right, lhv.file, lhv.detail, lhv.record) or_return
	return host_to_value(eval, res_hv)
}

// ---- Call_Site execution (host commands, named args, console special forms).

@(private)
node_text_in_chunk :: proc "contextless" (eval: ^Evaluation, chunk_id: u16, node_idx: lex_parser.Node_Index) -> string {
	if int(chunk_id) < eval.chunk_count && eval.chunks[chunk_id].tree != nil {
		return lex_parser.node_text(eval.chunks[chunk_id].tree, node_idx)
	}
	return ""
}

@(private)
vm_exec_call_site :: proc "contextless" (eval: ^Evaluation, frame: ^VM_Frame, site_rel: u32, dst_reg: u8) -> bool {
	chunk := &eval.chunks[frame.chunk_id]
	site := eval.call_sites[int(chunk.site_start) + int(site_rel)]
	name := lex_parser.sym_text(&eval.interner, site.name_sym)

	Callee_Kind :: enum u8 {
		Host     = 0,
		Function = 1,
		Builtin  = 2,
	}
	callee := Callee_Kind.Host
	builtin_id := Builtin_Id.None
	fn_val: Value
	sig: Command_Signature

	if site.callee_kind == .Reg {
		fn_val = eval.reg_stack[int(frame.reg_base) + int(site.callee_reg)]
		if fn_val.kind != .Function {
			refuse(eval, {refusal = .Not_A_Function, chunk_id = frame.chunk_id, node = site.node_idx, command = name, left_kind = fn_val.kind})
			return false
		}
		callee = .Function
		cl := eval.closures[int(fn_val.data)]
		cchunk := &eval.chunks[cl.chunk_id]
		cproto := &eval.protos[int(cchunk.proto_start) + int(cl.proto_id)]
		sig = {parameter_count = int(cproto.param_count), untyped = true}
		for i in 0 ..< sig.parameter_count {
			sig.names[i] = lex_parser.sym_text(&eval.interner, cproto.param_syms[i])
		}
	} else if name == MAP_NAME {
		callee, builtin_id = .Builtin, .Map
		sig = {parameter_count = 2, untyped = true}
		sig.names[0], sig.names[1] = "list", "function"
	} else if name == FILTER_NAME {
		callee, builtin_id = .Builtin, .Filter
		sig = {parameter_count = 2, untyped = true}
		sig.names[0], sig.names[1] = "list", "function"
	} else if name == FOLD_NAME {
		callee, builtin_id = .Builtin, .Fold
		sig = {parameter_count = 3, untyped = true}
		sig.names[0], sig.names[1], sig.names[2] = "list", "init", "function"
	} else if name == ZIP_NAME {
		callee, builtin_id = .Builtin, .Zip
		sig = {parameter_count = 2, untyped = true}
		sig.names[0], sig.names[1] = "left", "right"
	} else if name == FIELDS_NAME {
		callee, builtin_id = .Builtin, .Fields
		sig = {parameter_count = 1, untyped = true}
		sig.names[0] = "record"
	} else if name == VALUES_NAME {
		callee, builtin_id = .Builtin, .Values
		sig = {parameter_count = 1, untyped = true}
		sig.names[0] = "record"
	} else if name == HAS_NAME {
		callee, builtin_id = .Builtin, .Has
		sig = {parameter_count = 2, untyped = true}
		sig.names[0], sig.names[1] = "record", "name"
	} else if name == EXTEND_NAME {
		callee, builtin_id = .Builtin, .Extend
		sig = {parameter_count = 2, untyped = true}
		sig.names[0], sig.names[1] = "left", "right"
	} else if name == MERGE_DEEP_NAME {
		callee, builtin_id = .Builtin, .Merge_Deep
		sig = {parameter_count = 2, untyped = true}
		sig.names[0], sig.names[1] = "left", "right"
	} else {
		if eval.host.command_find == nil {
			refuse(eval, {refusal = .Host_Refused, chunk_id = frame.chunk_id, node = site.node_idx})
			return false
		}
		found: bool
		sig, found = eval.host.command_find(eval.host.data, name)
		if refused(eval) {
			return false
		}
		if !found {
			refuse(eval, {refusal = .Host_Refused, chunk_id = frame.chunk_id, node = site.node_idx})
			return false
		}
		if eval.mode == .Declaration && sig.has_effect {
			refuse(eval, {refusal = .Effect_Refused, chunk_id = frame.chunk_id, node = site.node_idx, command = name})
			return false
		}
	}

	param_count := clamp(sig.parameter_count, 0, lex_parser.ARGUMENT_CAPACITY)
	args := eval.site_args[int(site.args_start):int(site.args_start) + int(site.arg_count)]

	// Step 1: Map each argument to its parameter slot (before evaluating any arg).
	arg_slots: [lex_parser.ARGUMENT_CAPACITY + 2]int
	given: [lex_parser.ARGUMENT_CAPACITY]bool
	given_count := 0
	for sarg, i in args {
		arg_slots[i] = -1
		if sarg.kind == .Refused {
			continue
		}
		slot := i
		if sarg.is_named {
			aname := lex_parser.sym_text(&eval.interner, sarg.name_sym)
			slot = -1
			for p in 0 ..< param_count {
				if sig.names[p] != "" && sig.names[p] == aname {
					slot = p
					break
				}
			}
			if slot < 0 {
				refuse(eval, {refusal = .Argument_Unknown, chunk_id = frame.chunk_id, node = sarg.node_idx, command = name, field = aname})
				return false
			}
			if given[slot] {
				refuse(eval, {refusal = .Argument_Twice, chunk_id = frame.chunk_id, node = sarg.node_idx, command = name, field = aname})
				return false
			}
		} else if slot >= param_count && site.has_named {
			continue
		}
		if slot >= 0 && slot < param_count {
			given[slot] = true
		}
		arg_slots[i] = slot
		given_count += 1
	}

	// Step 2: Check missing named parameters & Lex function arity BEFORE any arg runs.
	if !site.has_refused_arg {
		if site.has_named {
			for p in 0 ..< param_count {
				optional := sig.optional[p] || (sig.optional_last && p == param_count - 1)
				if !given[p] && !optional {
					refuse(eval, {refusal = .Argument_Missing, chunk_id = frame.chunk_id, node = site.node_idx, command = name, field = sig.names[p]})
					return false
				}
			}
		}
		if callee != .Host && given_count != param_count {
			refuse(eval, {refusal = .Function_Arguments, chunk_id = frame.chunk_id, node = site.node_idx, command = name, left = i64(given_count), right = i64(param_count)})
			return false
		}
	}

	// Step 3: Pre-validate direct Record_Literal field names and Enum members BEFORE any arg runs.
	if !sig.untyped {
		for sarg, i in args {
			slot := arg_slots[i]
			if slot < 0 || sarg.kind != .Expr {
				continue
			}
			if sarg.is_literal {
				if slot >= param_count || sig.kinds[slot] != .Record || sig.files[slot] == nil {
					rk := slot < param_count ? sig.kinds[slot] : Kind.None
					refuse(eval, {refusal = .Literal_No_Type, chunk_id = frame.chunk_id, node = sarg.val_node, command = name, parameter = slot + 1, right_kind = rk})
					return false
				}
				if !literal_desc_check_names(eval, frame.chunk_id, sarg.record_desc, sig.files[slot], sig.details[slot]) {
					return false
				}
			} else if sarg.is_member {
				if slot >= param_count || sig.kinds[slot] != .Enum || sig.files[slot] == nil {
					rk := slot < param_count ? sig.kinds[slot] : Kind.None
					refuse(eval, {refusal = .Member_No_Type, chunk_id = frame.chunk_id, node = sarg.val_node, command = name, parameter = slot + 1, right_kind = rk})
					return false
				}
				mname := lex_parser.sym_text(&eval.interner, sarg.member_sym)
				if _, mok := enum_member_value(sig.files[slot], sig.details[slot], mname); !mok {
					refuse(eval, {refusal = .Member_Unknown, chunk_id = frame.chunk_id, node = sarg.val_node, command = name, parameter = slot + 1, field = mname, file = sig.files[slot], detail = sig.details[slot]})
					return false
				}
			}
		}
	}

	// Step 4: Evaluate each argument in exact source order!
	host_args: [lex_parser.ARGUMENT_CAPACITY]Host_Value
	vm_args: [lex_parser.ARGUMENT_CAPACITY]Value
	arg_total := 0
	for sarg, i in args {
		if sarg.kind == .Refused {
			tref := chunk.tree != nil ? lex_parser.node_refusal(chunk.tree, sarg.node_idx) : .Unexpected
			refuse(eval, {refusal = .Text, text_refusal = tref, chunk_id = frame.chunk_id, node = sarg.node_idx})
			return false
		}
		slot := arg_slots[i]
		if slot < 0 || slot >= lex_parser.ARGUMENT_CAPACITY {
			refuse(eval, {refusal = .Text, text_refusal = .Too_Many_Arguments, chunk_id = frame.chunk_id, node = sarg.node_idx})
			return false
		}

		val_vm: Value
		val_hv: Host_Value
		switch sarg.kind {
		case .Refused:
		case .Condition:
			if eval.host.condition_value == nil {
				refuse(eval, {refusal = .Host_Refused, chunk_id = frame.chunk_id, node = sarg.node_idx})
				return false
			}
			chv, cok := eval.host.condition_value(eval.host.data, eval, name, host_args[:arg_total], sarg.node_idx)
			if refused(eval) {
				return false
			}
			if !cok {
				refuse(eval, {refusal = .Host_Refused, chunk_id = frame.chunk_id, node = sarg.node_idx})
				return false
			}
			val_hv = chv
			val_vm, _ = host_to_value(eval, chv)
		case .Fact_Name:
			if eval.host.fact_name_value == nil {
				refuse(eval, {refusal = .Host_Refused, chunk_id = frame.chunk_id, node = sarg.node_idx})
				return false
			}
			fhv, fok := eval.host.fact_name_value(eval.host.data, eval, name, sarg.node_idx)
			if refused(eval) {
				return false
			}
			if !fok {
				refuse(eval, {refusal = .Host_Refused, chunk_id = frame.chunk_id, node = sarg.node_idx})
				return false
			}
			val_hv = fhv
			val_vm, _ = host_to_value(eval, fhv)
		case .Field_Names:
			if chunk.tree != nil && lex_parser.node_refusal(chunk.tree, sarg.node_idx) == .Field_Name_Missing {
				refuse(eval, {refusal = .Text, text_refusal = .Field_Name_Missing, chunk_id = frame.chunk_id, node = sarg.node_idx, command = name})
				return false
			}
			ft := node_text_in_chunk(eval, frame.chunk_id, sarg.node_idx)
			val_hv = {kind = .Text, text = ft}
			val_vm, _ = host_to_value(eval, val_hv)
		case .Expr:
			eoff, elen, eok := capture_upvals(eval, frame, frame.chunk_id, sarg.proto_id, sarg.val_node)
			if !eok {
				return false
			}
			v, vok := vm_exec_proto(eval, frame.chunk_id, sarg.proto_id, eoff, elen, nil, NO_THUNK, sarg.val_node)
			if !vok {
				return false
			}
			val_vm = v
			val_hv = value_to_host(eval, v)
		}

		// Type-check host border arguments.
		if !sig.untyped {
			if val_vm.kind == .Function || val_vm.kind == .List {
				refuse(eval, {refusal = .Value_At_Border, chunk_id = frame.chunk_id, node = sarg.node_idx, command = name, parameter = slot + 1, left_kind = val_vm.kind})
				return false
			}
			if val_vm.kind == .Record_Literal {
				if slot >= param_count || sig.kinds[slot] != .Record || sig.files[slot] == nil {
					rk := slot < param_count ? sig.kinds[slot] : Kind.None
					refuse(eval, {refusal = .Literal_No_Type, chunk_id = frame.chunk_id, node = sarg.val_node, command = name, parameter = slot + 1, right_kind = rk})
					return false
				}
				typed_hv, tok := literal_type_to_record(eval, val_vm, sig.files[slot], sig.details[slot], nil)
				if !tok {
					return false
				}
				val_hv = typed_hv
				val_vm, _ = host_to_value(eval, typed_hv)
			} else if val_vm.kind == .Member {
				if slot >= param_count || sig.kinds[slot] != .Enum || sig.files[slot] == nil {
					rk := slot < param_count ? sig.kinds[slot] : Kind.None
					refuse(eval, {refusal = .Member_No_Type, chunk_id = frame.chunk_id, node = sarg.val_node, command = name, parameter = slot + 1, right_kind = rk})
					return false
				}
				mname := member_name_of(eval, val_vm)
				mval, mok := enum_member_value(sig.files[slot], sig.details[slot], mname)
				if !mok {
					refuse(eval, {refusal = .Member_Unknown, chunk_id = frame.chunk_id, node = sarg.val_node, command = name, parameter = slot + 1, field = mname, file = sig.files[slot], detail = sig.details[slot]})
					return false
				}
				val_hv = {kind = .Enum, integer = mval, file = sig.files[slot], detail = sig.details[slot]}
				val_vm, _ = host_to_value(eval, val_hv)
			}
		}

		host_args[slot] = val_hv
		vm_args[slot] = val_vm
		if slot + 1 > arg_total {
			arg_total = slot + 1
		}
	}

	// Step 5: Invoke callee.
	switch callee {
	case .Builtin:
		return vm_exec_builtin(eval, frame, builtin_id, vm_args[:param_count], dst_reg, site.node_idx)
	case .Function:
		cl := eval.closures[int(fn_val.data)]
		eval.call_count += 1
		if eval.profile != nil {
			eval.profile.calls_total += 1
		}
		return push_bytecode_frame(eval, cl.chunk_id, cl.proto_id, cl.upval_off, cl.upval_len, vm_args[:param_count], dst_reg, NO_THUNK, site.node_idx)
	case .Host:
		if eval.host.call_run == nil {
			refuse(eval, {refusal = .Host_Refused, chunk_id = frame.chunk_id, node = site.node_idx})
			return false
		}
		res_hv, rok := eval.host.call_run(eval.host.data, name, host_args[:arg_total])
		if refused(eval) {
			return false
		}
		if !rok {
			refuse(eval, {refusal = .Host_Refused, chunk_id = frame.chunk_id, node = site.node_idx})
			return false
		}
		res_vm, vok := host_to_value(eval, res_hv)
		if !vok {
			refuse(eval, {refusal = .Calls_Full, chunk_id = frame.chunk_id, node = site.node_idx})
			return false
		}
		eval.reg_stack[int(frame.reg_base) + int(dst_reg)] = res_vm
		return true
	}
	return false
}

// ---- Console module Record & Enum helpers.

@(private)
enum_member_value :: proc "contextless" (file: []u8, enum_index: u32, name: string) -> (i64, bool) {
	described, problem := module.enum_type(file, enum_index)
	if problem != .None {
		return 0, false
	}
	for i in u32(0) ..< described.member_count {
		m, ok := module.enum_member(file, described, i)
		if ok && module.string_at(file, m.name_offset, m.name_count) == name {
			return m.value, true
		}
	}
	return 0, false
}

@(private)
record_field_find :: proc "contextless" (file: []u8, described: module.Record, name: string) -> (item: module.Field, number: u32, found: bool) {
	for candidate in u32(0) ..< described.field_count {
		candidate_item := module.field(file, described, candidate) or_continue
		if module.string_at(file, candidate_item.name_offset, candidate_item.name_count) == name {
			return candidate_item, candidate, true
		}
	}
	return {}, 0, false
}

@(private)
literal_desc_check_names :: proc "contextless" (eval: ^Evaluation, chunk_id: u16, desc_rel: u32, file: []u8, detail: u32) -> bool {
	described, ok := module.record_type(file, detail)
	if !ok {
		return false
	}
	chunk := &eval.chunks[chunk_id]
	desc := eval.rec_descs[int(chunk.rec_desc_start) + int(desc_rel)]
	shape := &eval.shapes[desc.shape_id]
	fields := eval.shape_fields[int(shape.fields_off):int(shape.fields_off) + int(shape.field_count)]
	// Check each literal field in source order.
	for si in 0 ..< int(desc.field_count) {
		ci := int(eval.rec_source_orders[int(desc.source_order_off) + si])
		fname := lex_parser.sym_text(&eval.interner, fields[ci])
		if _, _, found := record_field_find(file, described, fname); !found {
			refuse(eval, {refusal = .Literal_Field_Unknown, chunk_id = chunk_id, node = eval.rec_field_nodes[int(desc.nodes_start) + ci], field = fname, file = file, detail = detail})
			return false
		}
	}
	// Check every field of the module record is present.
	for i in u32(0) ..< described.field_count {
		item := module.field(file, described, i) or_continue
		fname := module.string_at(file, item.name_offset, item.name_count)
		sym, has_sym := lex_parser.intern_lookup(&eval.interner, fname)
		if !has_sym {
			refuse(eval, {refusal = .Literal_Field_Missing, chunk_id = chunk_id, node = desc.literal_node, field = fname, file = file, detail = detail})
			return false
		}
		if _, found := shape_lookup_sym(eval, desc.shape_id, sym); !found {
			refuse(eval, {refusal = .Literal_Field_Missing, chunk_id = chunk_id, node = desc.literal_node, field = fname, file = file, detail = detail})
			return false
		}
	}
	return true
}

@(private)
literal_type_to_record :: proc "contextless" (eval: ^Evaluation, lit_val: Value, file: []u8, detail: u32, base_bytes: []u8) -> (Host_Value, bool) {
	described, ok := module.record_type(file, detail)
	if !ok {
		return {}, false
	}
	rec := eval.records[int(lit_val.data)]
	chunk := &eval.chunks[rec.chunk_id]
	desc := eval.rec_descs[int(chunk.rec_desc_start) + int(rec.desc_id)]
	shape := &eval.shapes[rec.shape_id]
	fields := eval.shape_fields[int(shape.fields_off):int(shape.fields_off) + int(shape.field_count)]

	// Check field names first.
	for si in 0 ..< int(desc.field_count) {
		ci := int(eval.rec_source_orders[int(desc.source_order_off) + si])
		fname := lex_parser.sym_text(&eval.interner, fields[ci])
		if _, _, found := record_field_find(file, described, fname); !found {
			refuse(eval, {refusal = .Literal_Field_Unknown, chunk_id = rec.chunk_id, node = eval.rec_field_nodes[int(desc.nodes_start) + ci], field = fname, file = file, detail = detail})
			return {}, false
		}
	}
	if base_bytes == nil {
		for i in u32(0) ..< described.field_count {
			item := module.field(file, described, i) or_continue
			fname := module.string_at(file, item.name_offset, item.name_count)
			sym, has_sym := lex_parser.intern_lookup(&eval.interner, fname)
			if !has_sym {
				refuse(eval, {refusal = .Literal_Field_Missing, chunk_id = rec.chunk_id, node = rec.node_idx, field = fname, file = file, detail = detail})
				return {}, false
			}
			if _, found := shape_lookup_sym(eval, rec.shape_id, sym); !found {
				refuse(eval, {refusal = .Literal_Field_Missing, chunk_id = rec.chunk_id, node = rec.node_idx, field = fname, file = file, detail = detail})
				return {}, false
			}
		}
	}

	if eval.host.record_memory == nil {
		refuse(eval, {refusal = .Host_Refused, chunk_id = rec.chunk_id, node = rec.node_idx})
		return {}, false
	}
	bytes, mem_ok := eval.host.record_memory(eval.host.data, int(described.size))
	if !mem_ok {
		refuse(eval, {refusal = .Host_Refused, chunk_id = rec.chunk_id, node = rec.node_idx})
		return {}, false
	}
	if base_bytes != nil {
		copy(bytes, base_bytes)
	}

	// Write each field in source order, checking kind and range.
	for si in 0 ..< int(desc.field_count) {
		ci := int(eval.rec_source_orders[int(desc.source_order_off) + si])
		fname := lex_parser.sym_text(&eval.interner, fields[ci])
		fnode := eval.rec_field_nodes[int(desc.nodes_start) + ci]
		item, _, _ := record_field_find(file, described, fname)
		tref := eval.record_thunk_refs[int(rec.refs_off) + ci]
		fval, fok := vm_force_thunk(eval, tref, rec.chunk_id, fnode)
		if !fok {
			return {}, false
		}
		ftype, ft_ok := module.field_type(item)
		if !ft_ok {
			refuse(eval, {refusal = .Literal_Field_Kind, chunk_id = rec.chunk_id, node = fnode, field = fname, field_item = item, left_kind = fval.kind, file = file, detail = detail})
			return {}, false
		}
		switch ftype {
		case .Integer:
			if fval.kind != .Integer {
				refuse(eval, {refusal = .Literal_Field_Kind, chunk_id = rec.chunk_id, node = fnode, field = fname, field_item = item, left_kind = fval.kind, file = file, detail = detail})
				return {}, false
			}
			iv := value_integer(fval)
			if console_condition.value_check(item, .Integer, iv) != .None {
				refuse(eval, {refusal = .Literal_Field_Range, chunk_id = rec.chunk_id, node = fnode, field = fname, field_item = item, left_kind = .Integer, left = iv, file = file, detail = detail})
				return {}, false
			}
			module.field_integer_set(bytes, item, iv)
		case .Text:
			if fval.kind != .Text {
				refuse(eval, {refusal = .Literal_Field_Kind, chunk_id = rec.chunk_id, node = fnode, field = fname, field_item = item, left_kind = fval.kind, file = file, detail = detail})
				return {}, false
			}
			txt := value_text(eval, fval)
			if len(txt) > int(item.detail) {
				refuse(eval, {refusal = .Literal_Field_Range, chunk_id = rec.chunk_id, node = fnode, field = fname, field_item = item, left_kind = .Text, right = i64(len(txt)), file = file, detail = detail})
				return {}, false
			}
			dest := bytes[int(item.offset):int(item.offset) + int(item.detail)]
			for &b in dest {
				b = 0
			}
			copy(dest, txt)
		case .Handle:
			if fval.kind != .Handle {
				refuse(eval, {refusal = .Literal_Field_Kind, chunk_id = rec.chunk_id, node = fnode, field = fname, field_item = item, left_kind = fval.kind, file = file, detail = detail})
				return {}, false
			}
			h := u32(value_integer(fval))
			for bi in u32(0) ..< 4 {
				bytes[item.offset + bi] = u8(h >> (8 * bi))
			}
		case .None, .Record, .Table, .Bytes, .Enum:
			refuse(eval, {refusal = .Literal_Field_Kind, chunk_id = rec.chunk_id, node = fnode, field = fname, field_item = item, left_kind = fval.kind, file = file, detail = detail})
			return {}, false
		}
	}
	return {kind = .Record, record = bytes, file = file, detail = detail}, true
}

// record_field_value reads one field of a binary console Host_Value .Record.
record_field_value :: proc "contextless" (value: Host_Value, name: string) -> (result: Host_Value, ok: bool) {
	described := module.record_type(value.file, value.detail) or_return
	for number in u32(0) ..< described.field_count {
		item := module.field(value.file, described, number) or_return
		if module.string_at(value.file, item.name_offset, item.name_count) != name {
			continue
		}
		type := module.field_type(item) or_return
		switch type {
		case .Integer:
			return {kind = .Integer, integer = module.field_integer(value.record, item)}, true
		case .Handle:
			return {kind = .Handle, integer = i64(handle_of(value.record, item))}, true
		case .Text:
			return {kind = .Text, text = module.field_text(value.record, item)}, true
		case .Bytes:
			return {kind = .Bytes, record = module.field_bytes(value.record, item)}, true
		case .None, .Record, .Table, .Enum:
			return {}, false
		}
	}
	return {}, false
}

@(private)
handle_of :: proc "contextless" (record: []u8, item: module.Field) -> u32 {
	if u64(item.offset) > u64(len(record)) || u64(len(record)) - u64(item.offset) < 4 {
		return 0
	}
	handle: u32
	for index in u32(0) ..< 4 {
		handle |= u32(record[item.offset + index]) << (8 * index)
	}
	return handle
}
