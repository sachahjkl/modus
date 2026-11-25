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
import "modus:contract/enum_word"
import module "modus:contract/module"
import "modus:contract/value_kinds"
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
CONSOLE_COMP_DESC_CAPACITY :: 64
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
	Any               = 6,
	All               = 7,
	Flat_Map          = 8,
	Sort_By           = 9,
	Rec_Comp          = 10,
	Call_Site         = 11,
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
	cont_phase:    u8,
	cont_flags:    u8,
	return_thunk:  Thunk_Ref,
	boxed_params:  [lex_parser.ARGUMENT_CAPACITY]Thunk_Ref,
	// Continuation state for iterative Map / Filter / Fold / Any / All / Flat_Map / Sort_By / Rec_Comp:
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
	comp_descs:         []Comp_Desc,
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
	comp_descs:         [CONSOLE_COMP_DESC_CAPACITY]Comp_Desc,
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
		comp_descs         = buf.comp_descs[:],
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
	stack_base:            uintptr,
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
	comp_descs:            []Comp_Desc,
	comp_desc_count:       int,
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
		comp_descs         = pools.comp_descs,
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

// Compact refusal input without the diagnostic frame trace or suggestion arrays
// so cold refusal call sites do not inflate VM stack frames under -o:none.
@(private)
Refusal_Input :: struct {
	refusal:        Refusal,
	place:          lex_parser.Place,
	span_start:     u32,
	span_end:       u32,
	node:           lex_parser.Node_Index,
	chunk_id:       u16,
	operator:       lex_parser.Operator,
	left_kind:      Kind,
	right_kind:     Kind,
	left_unit:      value_kinds.Integer_Unit,
	right_unit:     value_kinds.Integer_Unit,
	expected_annot: lex_parser.Param_Kind_Annot,
	left:           i64,
	right:          i64,
	text_refusal:   lex_parser.Refusal,
	command:        string,
	steps:          u32,
	parameter:      int,
	field:          string,
	field_item:     module.Field,
	file:           []u8,
	detail:         u32,
	other_file:     []u8,
	other_detail:   u32,
}

@(private)
refuse :: #force_no_inline proc "contextless" (eval: ^Evaluation, record: Refusal_Input) -> (Value, bool) {
	if !refused(eval) {
		r := &eval.refusal
		r^ = {
			refusal        = record.refusal,
			place          = record.place,
			span_start     = record.span_start,
			span_end       = record.span_end,
			node           = record.node,
			chunk_id       = record.chunk_id,
			operator       = record.operator,
			left_kind      = record.left_kind,
			right_kind     = record.right_kind,
			left_unit      = record.left_unit,
			right_unit     = record.right_unit,
			expected_annot = record.expected_annot,
			left           = record.left,
			right          = record.right,
			text_refusal   = record.text_refusal,
			command        = record.command,
			steps          = record.steps,
			parameter      = record.parameter,
			field          = record.field,
			field_item     = record.field_item,
			file           = record.file,
			detail         = record.detail,
			other_file     = record.other_file,
			other_detail   = record.other_detail,
		}
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
	}
	return {}, false
}

@(private)
refuse_field_unknown_with_suggestions :: #force_no_inline proc "contextless" (eval: ^Evaluation, shape_id: u32, chunk_id: u16, node: lex_parser.Node_Index, field: string, left_kind: Kind) -> (Value, bool) {
	if !refused(eval) {
		refuse(eval, {refusal = .Field_Unknown, chunk_id = chunk_id, node = node, field = field, left_kind = left_kind})
		suggest_shape_fields(eval, shape_id, field, &eval.refusal)
	}
	return {}, false
}

@(private)
refuse_budget :: #force_no_inline proc "contextless" (eval: ^Evaluation, chunk_id: u16, node_idx: lex_parser.Node_Index) -> bool {
	refuse(eval, {refusal = .Budget_Exceeded, chunk_id = chunk_id, node = node_idx, steps = eval.budget})
	return false
}

@(private)
charge_steps :: #force_inline proc "contextless" (eval: ^Evaluation, count: u32, chunk_id: u16, node_idx: lex_parser.Node_Index) -> bool {
	if u64(eval.steps) + u64(count) > u64(eval.budget) {
		return refuse_budget(eval, chunk_id, node_idx)
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
		if v.flags == 1 {
			idx := int(v.data)
			if idx >= 0 && idx < eval.host_obj_count {
				return {kind = .None, condition = eval.host_objs[idx].condition, vm_value = v}
			}
		}
		return {}
	case .Integer:
		return {kind = .Integer, integer = value_integer(v), integer_unit = value_unit(v), vm_value = v}
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
		return value_int_unit(hv.integer, hv.integer_unit), true
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
		switch cur.kind {
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
		case .None, .Integer, .Text, .Record, .Handle, .Table, .Bytes, .Stream, .Record_Input,
		     .Enum, .Member, .Function, .List, .Hash, .Boolean, .Module_Ref, .Recipe_Ref,
		     .Follow_Ref, .Store_Ref, .Tree_Ref:
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
		switch cur.kind {
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
		case .None, .Integer, .Text, .Record, .Handle, .Table, .Bytes, .Stream, .Record_Input,
		     .Enum, .Member, .Function, .List, .Hash, .Boolean, .Module_Ref, .Recipe_Ref,
		     .Follow_Ref, .Store_Ref, .Tree_Ref:
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
		switch cur.kind {
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
		case .None, .Integer, .Text, .Record, .Handle, .Table, .Bytes, .Stream, .Record_Input,
		     .Enum, .Member, .Function, .List, .Hash, .Boolean, .Module_Ref, .Recipe_Ref,
		     .Follow_Ref, .Store_Ref, .Tree_Ref:
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
	case .None, .Line_Ends_Too_Soon, .Unexpected, .Number_Too_Large, .Text_Without_End_Quote, .Close_Parenthesis_Missing, .Comma_Or_Close_Missing, .Too_Many_Arguments, .Fact_Name_Missing, .Condition_Head_Refused, .Field_Name_Missing, .Literal_Close_Missing, .Literal_Name_Missing, .Literal_Equal_Missing, .Literal_Field_Twice, .Named_Argument_Twice, .Positional_After_Named, .Let_Name_Missing, .Let_Equal_Missing, .Let_In_Missing, .Let_Name_Twice, .Word_As_Name, .Parameter_Name_Missing, .Parameter_Twice, .Too_Many_Parameters, .List_Close_Missing, .Hash_Not_Valid, .If_Then_Missing, .If_Else_Missing, .Escape_Not_Valid, .Interpolation_Close_Missing, .Pattern_Field_Missing, .Pattern_Close_Missing, .Pattern_Field_Twice, .Pattern_Rest_Not_Last, .Pattern_At_Missing_Brace, .Literal_Path_Conflict, .Comp_Bind_Missing, .Comp_In_Missing, .Comp_Colon_Missing, .Comp_Equal_Missing, .Match_Open_Missing, .Match_Empty, .Match_Arrow_Missing, .Match_Close_Missing, .Match_Pattern_Expected, .Match_Duplicate_Bind, .Param_Kind_Unknown, .Param_Unit_Not_Valid:
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
		if untyped.kind == .Record_With {
			ov := eval.overlays[int(untyped.data)]
			rec := eval.records[ov.patch_rec]
			return refuse(eval, {refusal = .Literal_No_Type, chunk_id = rec.chunk_id, node = tree.root})
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
	// When called from a host .Condition callback, execute the pre-compiled
	// condition-value proto in the current chunk with its captured lexical scope
	// so chained or nested conditions never consume extra Chunk slots.
	if eval.frame_count > 0 {
		top := &eval.frames[eval.frame_count - 1]
		if top.kind == .Call_Site && int(top.chunk_id) < eval.chunk_count {
			chunk := &eval.chunks[top.chunk_id]
			site := eval.call_sites[int(chunk.site_start) + int(top.proto_id)]
			if int(top.cont_index) < int(site.arg_count) {
				sarg := eval.site_args[int(site.args_start) + int(top.cont_index)]
				if sarg.kind == .Condition && sarg.val_node == node_idx && sarg.val_node != sarg.node_idx && sarg.proto_id > 0 {
					parent_frame := &eval.frames[top.ip]
					eoff, elen, eok := capture_upvals(eval, parent_frame, top.chunk_id, sarg.proto_id, node_idx)
					if !eok {
						return {}, false
					}
					val := vm_exec_proto(eval, top.chunk_id, sarg.proto_id, eoff, elen, nil, NO_THUNK, node_idx) or_return
					return value_to_host(eval, val), true
				}
			}
		}
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
	if value.kind == .Record_Literal || value.kind == .Record_With || value.kind == .Member {
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
	stack_marker: u8
	sp := uintptr(&stack_marker)
	if eval.stack_base == 0 {
		eval.stack_base = sp
	} else {
		real_stack := eval.stack_base > sp ? uint(eval.stack_base - sp) : uint(sp - eval.stack_base)
		if real_stack > eval.stack_bytes {
			return refuse(eval, {refusal = .Stack_Exceeded, chunk_id = chunk_id, node = call_node, left = i64(real_stack), right = i64(eval.stack_bytes)})
		}
	}
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
		if (code.flags & THUNK_FLAG_ONE_ARG) != 0 && code.env_len > 0 {
			arg_tref := eval.env_slots[int(code.env_off) + int(code.env_len) - 1]
			arg_val := eval.thunks[arg_tref].payload.value
			one_arg := [1]Value{arg_val}
			return vm_exec_proto(eval, code.chunk_id, code.proto_id, code.env_off, u16(code.env_len - 1), one_arg[:], tref, ref_node)
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
				eval.reg_stack[reg_base + a] = value_int_unit(ce.integer, ce.unit)
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
			eval.reg_stack[reg_base + a] = value_int_unit(opp, value_unit(v))

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
				lu, ru := value_unit(lv), value_unit(rv)
				li, ri, out_u, astatus := align_integer_units(value_integer(lv), value_integer(rv), lu, ru)
				switch astatus {
				case .Ok:
				case .Incompatible, .Non_Exact:
					refuse(eval, {refusal = .Unit_Mismatch, chunk_id = frame.chunk_id, node = node_idx, operator = .Add, left_kind = .Integer, right_kind = .Integer, left_unit = lu, right_unit = ru})
					return false
				case .Overflow:
					refuse(eval, {refusal = .Overflow, chunk_id = frame.chunk_id, node = node_idx, operator = .Add, left_kind = .Integer, right_kind = .Integer, left = value_integer(lv), right = value_integer(rv)})
					return false
				}
				res, fits := console_language.integer_add(li, ri)
				if !fits {
					refuse(eval, {refusal = .Overflow, chunk_id = frame.chunk_id, node = node_idx, operator = .Add, left_kind = .Integer, right_kind = .Integer, left = li, right = ri})
					return false
				}
				eval.reg_stack[reg_base + a] = value_int_unit(res, out_u)
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
			lu, ru := value_unit(lv), value_unit(rv)
			li, ri, out_u, astatus := align_integer_units(value_integer(lv), value_integer(rv), lu, ru)
			switch astatus {
			case .Ok:
			case .Incompatible, .Non_Exact:
				refuse(eval, {refusal = .Unit_Mismatch, chunk_id = frame.chunk_id, node = node_idx, operator = .Subtract, left_kind = .Integer, right_kind = .Integer, left_unit = lu, right_unit = ru})
				return false
			case .Overflow:
				refuse(eval, {refusal = .Overflow, chunk_id = frame.chunk_id, node = node_idx, operator = .Subtract, left_kind = .Integer, right_kind = .Integer, left = value_integer(lv), right = value_integer(rv)})
				return false
			}
			res, fits := console_language.integer_subtract(li, ri)
			if !fits {
				refuse(eval, {refusal = .Overflow, chunk_id = frame.chunk_id, node = node_idx, operator = .Subtract, left_kind = .Integer, right_kind = .Integer, left = li, right = ri})
				return false
			}
			eval.reg_stack[reg_base + a] = value_int_unit(res, out_u)

		case .Mul:
			lv := eval.reg_stack[reg_base + int(inst_b(inst))]
			rv := eval.reg_stack[reg_base + int(inst_c(inst))]
			if lv.kind != .Integer || rv.kind != .Integer {
				refuse(eval, {refusal = .Operator_Kinds, chunk_id = frame.chunk_id, node = node_idx, operator = .Multiply, left_kind = lv.kind, right_kind = rv.kind})
				return false
			}
			lu, ru := value_unit(lv), value_unit(rv)
			if lu.kind != .None && ru.kind != .None {
				refuse(eval, {refusal = .Unit_Mismatch, chunk_id = frame.chunk_id, node = node_idx, operator = .Multiply, left_kind = .Integer, right_kind = .Integer, left_unit = lu, right_unit = ru})
				return false
			}
			out_u := lu.kind != .None ? lu : ru
			li, ri := value_integer(lv), value_integer(rv)
			res, fits := console_language.integer_multiply(li, ri)
			if !fits {
				refuse(eval, {refusal = .Overflow, chunk_id = frame.chunk_id, node = node_idx, operator = .Multiply, left_kind = .Integer, right_kind = .Integer, left = li, right = ri})
				return false
			}
			eval.reg_stack[reg_base + a] = value_int_unit(res, out_u)

		case .Div, .Rem:
			lv := eval.reg_stack[reg_base + int(inst_b(inst))]
			rv := eval.reg_stack[reg_base + int(inst_c(inst))]
			op_kind: lex_parser.Operator = op == .Div ? .Divide : .Remainder
			if lv.kind != .Integer || rv.kind != .Integer {
				refuse(eval, {refusal = .Operator_Kinds, chunk_id = frame.chunk_id, node = node_idx, operator = op_kind, left_kind = lv.kind, right_kind = rv.kind})
				return false
			}
			lu, ru := value_unit(lv), value_unit(rv)
			li, ri := value_integer(lv), value_integer(rv)
			out_u := value_kinds.Integer_Unit{}
			if lu.kind == .None && ru.kind == .None {
				out_u = {}
			} else if lu.kind != .None && ru.kind == .None {
				out_u = lu
			} else if lu.kind == .None && ru.kind != .None {
				refuse(eval, {refusal = .Unit_Mismatch, chunk_id = frame.chunk_id, node = node_idx, operator = op_kind, left_kind = .Integer, right_kind = .Integer, left_unit = lu, right_unit = ru})
				return false
			} else {
				ali, ari, common_u, astatus := align_integer_units(li, ri, lu, ru)
				switch astatus {
				case .Ok:
					li, ri = ali, ari
					out_u = op == .Div ? value_kinds.Integer_Unit{} : common_u
				case .Incompatible, .Non_Exact:
					refuse(eval, {refusal = .Unit_Mismatch, chunk_id = frame.chunk_id, node = node_idx, operator = op_kind, left_kind = .Integer, right_kind = .Integer, left_unit = lu, right_unit = ru})
					return false
				case .Overflow:
					refuse(eval, {refusal = .Overflow, chunk_id = frame.chunk_id, node = node_idx, operator = op_kind, left_kind = .Integer, right_kind = .Integer, left = li, right = ri})
					return false
				}
			}
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
				eval.reg_stack[reg_base + a] = value_int_unit(q, out_u)
			} else {
				eval.reg_stack[reg_base + a] = value_int_unit(ri == -1 ? 0 : rem, out_u)
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
			if !fn_arity_accepts_positional(cproto, argc) {
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
			if !fn_arity_accepts_positional(cproto, argc) {
				refuse(eval, {refusal = .Function_Arguments, chunk_id = frame.chunk_id, node = node_idx, command = node_text_in_chunk(eval, frame.chunk_id, node_idx), left = i64(argc), right = i64(cproto.param_count)})
				return false
			}
			prepared: [lex_parser.ARGUMENT_CAPACITY]Value
			raw_args := eval.reg_stack[reg_base + a + 1 : reg_base + a + 1 + argc]
			if !vm_prepare_fn_args(eval, cl, cproto, raw_args, nil, prepared[:int(cproto.param_count)], frame.chunk_id, node_idx, node_text_in_chunk(eval, frame.chunk_id, node_idx)) {
				return false
			}
			pcount := int(cproto.param_count)
			eval.call_count += 1
			if eval.profile != nil {
				eval.profile.calls_total += 1
			}
			if op == .Tail_Call {
				// O(1) Tail-Call Optimization: reuse active Bytecode frame!
				if eval.profile != nil {
					eval.profile.tail_calls_total += 1
				}
				need_regs := u32(max(int(cproto.max_regs), pcount))
				if int(frame.reg_base) + int(need_regs) > len(eval.reg_stack) ||
				   int(frame.let_base) + int(cproto.let_slot_count) > len(eval.let_slots) {
					refuse(eval, {refusal = .Calls_Full, chunk_id = frame.chunk_id, node = node_idx})
					return false
				}
				for i in 0 ..< pcount {
					eval.reg_stack[reg_base + i] = prepared[i]
				}
				eval.reg_top = frame.reg_base + need_regs
				eval.let_slot_top = frame.let_base + u32(cproto.let_slot_count)
				frame.chunk_id = cl.chunk_id
				frame.proto_id = cl.proto_id
				frame.ip = cproto.code_start
				frame.env_off = cl.upval_off
				frame.env_len = cl.upval_len
				if cproto.boxed_param_mask != 0 {
					for i in 0 ..< pcount {
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
				if !push_bytecode_frame(eval, cl.chunk_id, cl.proto_id, cl.upval_off, cl.upval_len, prepared[:pcount], u8(a), NO_THUNK, node_idx) {
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
			if is_lazy_record(base.kind) {
				if sid, sok := lazy_record_base_shape(eval, base); sok {
					refuse_field_unknown_with_suggestions(eval, sid, frame.chunk_id, node_idx, fname, base.kind)
					return false
				}
			}
			refuse(eval, {refusal = .Field_Unknown, chunk_id = frame.chunk_id, node = node_idx, field = fname, left_kind = base.kind})
			return false

		case .Try_Get_Field:
			b := int(inst_b(inst))
			c_op := int(inst_c(inst))
			sym_rel := has_extra && c_op == 255 ? extra : u32(c_op)
			chunk := &eval.chunks[frame.chunk_id]
			sym := eval.field_syms[int(chunk.field_sym_start) + int(sym_rel)]
			base := eval.reg_stack[reg_base + b]
			if is_lazy_record(base.kind) {
				if sid, sok := lazy_record_base_shape(eval, base); sok {
					record_shape_dep(eval, base, sid)
				}
				if tref, found := lazy_record_lookup_thunk(eval, base, sym); found {
					eval.reg_stack[reg_base + a + 1] = value_bool(true)
					if !vm_push_or_load_thunk(eval, frame, tref, u8(a), node_idx) {
						return false
					}
					continue
				}
				eval.reg_stack[reg_base + a + 1] = value_bool(false)
				continue
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
					eval.reg_stack[reg_base + a + 1] = value_bool(true)
					continue
				}
				eval.reg_stack[reg_base + a + 1] = value_bool(false)
				continue
			}
			// Non-record base or intermediate value: refuse rather than mask type error!
			fname := lex_parser.sym_text(&eval.interner, sym)
			refuse(eval, {refusal = .Field_Unknown, chunk_id = frame.chunk_id, node = node_idx, field = fname, left_kind = base.kind})
			return false

		case .With:
			lv := eval.reg_stack[reg_base + int(inst_b(inst))]
			rv := eval.reg_stack[reg_base + int(inst_c(inst))]
			res, wok := vm_with(eval, lv, rv, frame.chunk_id, node_idx)
			if !wok {
				return false
			}
			eval.reg_stack[reg_base + a] = res

		case .Make_Rec_Comp:
			comp_rel := has_extra ? extra : u32(inst_bx(inst))
			iter_val := eval.reg_stack[reg_base + a]
			if !vm_start_rec_comp(eval, frame, u8(a), iter_val, comp_rel, node_idx) {
				return false
			}

		case .Destructure:
			pat_rel := has_extra ? extra : u32(inst_bx(inst))
			src_val := eval.reg_stack[reg_base + a]
			if !vm_destructure(eval, frame, src_val, pat_rel, node_idx) {
				return false
			}

		case .Set_Let_Val:
			slot := int(inst_bx(inst))
			tref, tok := alloc_forced_thunk(eval, eval.reg_stack[reg_base + a], frame.chunk_id, node_idx)
			if !tok {
				return false
			}
			eval.let_slots[int(frame.let_base) + slot] = tref

		case .Match_Eq:
			lv := eval.reg_stack[reg_base + int(inst_b(inst))]
			rv := eval.reg_stack[reg_base + int(inst_c(inst))]
			eq, ok := vm_match_eq(eval, lv, rv, frame.chunk_id, node_idx)
			if !ok {
				return false
			}
			eval.reg_stack[reg_base + a] = value_bool(eq)

		case .Check_Rec_Shape:
			pat_rel := has_extra ? extra : u32(inst_bx(inst))
			src_val := eval.reg_stack[reg_base + a]
			matched, ok := vm_check_rec_shape(eval, frame, src_val, pat_rel, node_idx)
			if !ok {
				return false
			}
			eval.reg_stack[reg_base + a + 1] = value_bool(matched)

		case .Match_Bind_Field:
			pf_abs := int(has_extra ? extra : u32(inst_bx(inst)))
			pf := eval.pat_fields[pf_abs]
			src_val := eval.reg_stack[reg_base + a]
			if is_lazy_record(src_val.kind) {
				if tref, found := lazy_record_lookup_thunk(eval, src_val, pf.sym); found {
					eval.let_slots[int(frame.let_base) + int(pf.let_slot)] = tref
				} else {
					refuse(eval, {refusal = .Field_Unknown, chunk_id = frame.chunk_id, node = pf.node_idx, field = lex_parser.sym_text(&eval.interner, pf.sym), left_kind = src_val.kind})
					return false
				}
			} else if src_val.kind == .Record {
				hv := value_to_host(eval, src_val)
				fname := lex_parser.sym_text(&eval.interner, pf.sym)
				if fhv, found := record_field_value(hv, fname); found {
					fv, vok := host_to_value(eval, fhv)
					if !vok {
						refuse(eval, {refusal = .Calls_Full, chunk_id = frame.chunk_id, node = pf.node_idx})
						return false
					}
					tref, tok := alloc_forced_thunk(eval, fv, frame.chunk_id, pf.node_idx)
					if !tok {
						return false
					}
					eval.let_slots[int(frame.let_base) + int(pf.let_slot)] = tref
				} else {
					refuse(eval, {refusal = .Field_Unknown, chunk_id = frame.chunk_id, node = pf.node_idx, field = fname, left_kind = .Record, file = hv.file, detail = hv.detail})
					return false
				}
			}

		case .Match_Fail:
			refuse(eval, {refusal = .No_Matching_Arm, chunk_id = frame.chunk_id, node = node_idx})
			return false

		case .Refuse_Eval:
			r_code, r_ok := enum_word.member_of_word(Refusal, u64(inst_b(inst)))
			if !r_ok {
				r_code = .Host_Refused
			}
			refuse(eval, {refusal = r_code, chunk_id = frame.chunk_id, node = node_idx})
			return false

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
						switch n.kind {
						case .Hash: tref = .Hash_Not_Valid
						case .Let:  tref = .Let_In_Missing
						case .If:   tref = .If_Then_Missing
						case .Integer, .Text, .Name, .Call, .Negate, .Binary, .Condition, .Fact_Name,
						     .Refused, .Field_Names, .Record_Literal, .Literal_Field, .Named_Argument,
						     .Let_Binding, .Member, .Function, .Parameter, .List_Literal, .Boolean,
						     .Field_Select, .Pipe, .Placeholder, .Logical_Not, .Text_Interp,
						     .Pattern_Record, .Pattern_Field, .Record_Comp, .Match, .Match_Arm,
						     .Match_Pat_Field, .Match_Pat_Wild, .Match_Pat_Bind:
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
		if (code.flags & THUNK_FLAG_ONE_ARG) != 0 && code.env_len > 0 {
			arg_tref := eval.env_slots[int(code.env_off) + int(code.env_len) - 1]
			arg_val := eval.thunks[arg_tref].payload.value
			one_arg := [1]Value{arg_val}
			return push_bytecode_frame(eval, code.chunk_id, code.proto_id, code.env_off, u16(code.env_len - 1), one_arg[:], dst_reg, tref, node_idx)
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
		cchunk := &eval.chunks[cl.chunk_id]
		cproto := &eval.protos[int(cchunk.proto_start) + int(cl.proto_id)]
		eval.call_count += 1
		if eval.profile != nil {
			eval.profile.calls_total += 1
		}
		raw_args := [1]Value{arg}
		prepared: [lex_parser.ARGUMENT_CAPACITY]Value
		pcount := int(cproto.param_count)
		if !vm_prepare_fn_args(eval, cl, cproto, raw_args[:], nil, prepared[:pcount], frame.chunk_id, frame.cont_node, MAP_NAME) {
			return false
		}
		return push_bytecode_frame(eval, cl.chunk_id, cl.proto_id, cl.upval_off, cl.upval_len, prepared[:pcount], 0, NO_THUNK, frame.cont_node)

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
		cchunk := &eval.chunks[cl.chunk_id]
		cproto := &eval.protos[int(cchunk.proto_start) + int(cl.proto_id)]
		eval.call_count += 1
		if eval.profile != nil {
			eval.profile.calls_total += 1
		}
		raw_args := [1]Value{arg}
		prepared: [lex_parser.ARGUMENT_CAPACITY]Value
		pcount := int(cproto.param_count)
		if !vm_prepare_fn_args(eval, cl, cproto, raw_args[:], nil, prepared[:pcount], frame.chunk_id, frame.cont_node, FILTER_NAME) {
			return false
		}
		return push_bytecode_frame(eval, cl.chunk_id, cl.proto_id, cl.upval_off, cl.upval_len, prepared[:pcount], 0, NO_THUNK, frame.cont_node)

	case .Fold:
		acc := eval.reg_stack[frame.reg_base]
		if frame.cont_index >= frame.cont_count {
			vm_return_to_caller(eval, target_depth, acc)
			return true
		}
		item := eval.list_items[frame.cont_list_off + frame.cont_index]
		frame.cont_index += 1
		cl := eval.closures[int(frame.cont_fn.data)]
		cchunk := &eval.chunks[cl.chunk_id]
		cproto := &eval.protos[int(cchunk.proto_start) + int(cl.proto_id)]
		eval.call_count += 1
		if eval.profile != nil {
			eval.profile.calls_total += 1
		}
		raw_args := [2]Value{acc, item}
		prepared: [lex_parser.ARGUMENT_CAPACITY]Value
		pcount := int(cproto.param_count)
		if !vm_prepare_fn_args(eval, cl, cproto, raw_args[:], nil, prepared[:pcount], frame.chunk_id, frame.cont_node, FOLD_NAME) {
			return false
		}
		return push_bytecode_frame(eval, cl.chunk_id, cl.proto_id, cl.upval_off, cl.upval_len, prepared[:pcount], 0, NO_THUNK, frame.cont_node)

	case .Any, .All:
		if frame.cont_index > 0 {
			pred := eval.reg_stack[frame.reg_base]
			if pred.kind != .Boolean {
				refuse(eval, {refusal = .Condition_Not_Boolean, chunk_id = frame.chunk_id, node = frame.cont_node, left_kind = pred.kind})
				return false
			}
			b := value_boolean(pred)
			if frame.kind == .Any && b {
				vm_return_to_caller(eval, target_depth, value_bool(true))
				return true
			}
			if frame.kind == .All && !b {
				vm_return_to_caller(eval, target_depth, value_bool(false))
				return true
			}
		}
		if frame.cont_index >= frame.cont_count {
			vm_return_to_caller(eval, target_depth, value_bool(frame.kind == .All))
			return true
		}
		arg := eval.list_items[frame.cont_list_off + frame.cont_index]
		frame.cont_index += 1
		cl := eval.closures[int(frame.cont_fn.data)]
		cchunk := &eval.chunks[cl.chunk_id]
		cproto := &eval.protos[int(cchunk.proto_start) + int(cl.proto_id)]
		eval.call_count += 1
		if eval.profile != nil {
			eval.profile.calls_total += 1
		}
		raw_args := [1]Value{arg}
		prepared: [lex_parser.ARGUMENT_CAPACITY]Value
		pcount := int(cproto.param_count)
		cmd := frame.kind == .Any ? ANY_NAME : ALL_NAME
		if !vm_prepare_fn_args(eval, cl, cproto, raw_args[:], nil, prepared[:pcount], frame.chunk_id, frame.cont_node, cmd) {
			return false
		}
		return push_bytecode_frame(eval, cl.chunk_id, cl.proto_id, cl.upval_off, cl.upval_len, prepared[:pcount], 0, NO_THUNK, frame.cont_node)

	case .Flat_Map:
		if frame.cont_index > 0 {
			sub := eval.reg_stack[frame.reg_base]
			if sub.kind != .List {
				refuse(eval, {refusal = .Not_A_List, chunk_id = frame.chunk_id, node = frame.cont_node, command = FLAT_MAP_NAME, parameter = 2, left_kind = sub.kind})
				return false
			}
			sub_items := list_items_of(eval, sub)
			if !charge_steps(eval, u32(1 + len(sub_items) / 8), frame.chunk_id, frame.cont_node) {
				return false
			}
			if len(sub_items) > len(eval.list_scratch) - int(eval.list_scratch_top) {
				refuse(eval, {refusal = .Lists_Full, chunk_id = frame.chunk_id, node = frame.cont_node})
				return false
			}
			for item in sub_items {
				if eval.mode == .Console && (item.kind == .None || item.kind == .Stream || item.kind == .Record_Input) {
					refuse(eval, {refusal = .List_Item_Kind, chunk_id = frame.chunk_id, node = frame.cont_node, left_kind = item.kind})
					return false
				}
				eval.list_scratch[eval.list_scratch_top] = item
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
		cchunk := &eval.chunks[cl.chunk_id]
		cproto := &eval.protos[int(cchunk.proto_start) + int(cl.proto_id)]
		eval.call_count += 1
		if eval.profile != nil {
			eval.profile.calls_total += 1
		}
		raw_args := [1]Value{arg}
		prepared: [lex_parser.ARGUMENT_CAPACITY]Value
		pcount := int(cproto.param_count)
		if !vm_prepare_fn_args(eval, cl, cproto, raw_args[:], nil, prepared[:pcount], frame.chunk_id, frame.cont_node, FLAT_MAP_NAME) {
			return false
		}
		return push_bytecode_frame(eval, cl.chunk_id, cl.proto_id, cl.upval_off, cl.upval_len, prepared[:pcount], 0, NO_THUNK, frame.cont_node)

	case .Sort_By:
		if frame.cont_index > 0 {
			key := eval.reg_stack[frame.reg_base]
			if int(eval.list_scratch_top) >= len(eval.list_scratch) {
				refuse(eval, {refusal = .Lists_Full, chunk_id = frame.chunk_id, node = frame.cont_node})
				return false
			}
			eval.list_scratch[eval.list_scratch_top] = key
			eval.list_scratch_top += 1
		}
		if frame.cont_index >= frame.cont_count {
			return vm_finish_sort_by(eval, frame, target_depth)
		}
		arg := eval.list_items[frame.cont_list_off + frame.cont_index]
		frame.cont_index += 1
		cl := eval.closures[int(frame.cont_fn.data)]
		cchunk := &eval.chunks[cl.chunk_id]
		cproto := &eval.protos[int(cchunk.proto_start) + int(cl.proto_id)]
		eval.call_count += 1
		if eval.profile != nil {
			eval.profile.calls_total += 1
		}
		raw_args := [1]Value{arg}
		prepared: [lex_parser.ARGUMENT_CAPACITY]Value
		pcount := int(cproto.param_count)
		if !vm_prepare_fn_args(eval, cl, cproto, raw_args[:], nil, prepared[:pcount], frame.chunk_id, frame.cont_node, SORT_BY_NAME) {
			return false
		}
		return push_bytecode_frame(eval, cl.chunk_id, cl.proto_id, cl.upval_off, cl.upval_len, prepared[:pcount], 0, NO_THUNK, frame.cont_node)

	case .Rec_Comp:
		for {
			switch frame.cont_phase {
			case 1:
				// Condition returned in reg_base + 0.
				cond_v := eval.reg_stack[frame.reg_base]
				if cond_v.kind != .Boolean {
					refuse(eval, {refusal = .Condition_Not_Boolean, chunk_id = frame.chunk_id, node = frame.cont_node, left_kind = cond_v.kind})
					return false
				}
				if !value_boolean(cond_v) {
					frame.cont_index += 1
					frame.cont_phase = 0
					continue
				}
				item := eval.list_items[frame.cont_list_off + frame.cont_index]
				kcl := eval.closures[int(eval.reg_stack[frame.reg_base + 2].data)]
				frame.cont_phase = 2
				one_arg := [1]Value{item}
				return push_bytecode_frame(eval, kcl.chunk_id, kcl.proto_id, kcl.upval_off, kcl.upval_len, one_arg[:], 0, NO_THUNK, frame.cont_node)

			case 2:
				// Key returned in reg_base + 0.
				key_v := eval.reg_stack[frame.reg_base]
				if key_v.kind != .Text {
					refuse(eval, {refusal = .Field_Name_Invalid, chunk_id = frame.chunk_id, node = frame.cont_node, left_kind = key_v.kind})
					return false
				}
				ktxt := value_text(eval, key_v)
				if !lex_parser.name_valid(ktxt) {
					refuse(eval, {refusal = .Field_Name_Invalid, chunk_id = frame.chunk_id, node = frame.cont_node, field = ktxt, left_kind = .Text})
					return false
				}
				if int(eval.list_scratch_top) + 2 > len(eval.list_scratch) {
					refuse(eval, {refusal = .Lists_Full, chunk_id = frame.chunk_id, node = frame.cont_node})
					return false
				}
				eval.list_scratch[eval.list_scratch_top] = key_v
				eval.list_scratch_top += 1
				item := eval.list_items[frame.cont_list_off + frame.cont_index]
				vcl := eval.closures[int(eval.reg_stack[frame.reg_base + 3].data)]
				if eval.mode == .Console {
					frame.cont_phase = 3
					one_arg := [1]Value{item}
					return push_bytecode_frame(eval, vcl.chunk_id, vcl.proto_id, vcl.upval_off, vcl.upval_len, one_arg[:], 0, NO_THUNK, frame.cont_node)
				}
				// Declaration mode: build lazy 1-arg thunk carrying [vcl.upvals..., forced(item)].
				item_tref, it_ok := alloc_forced_thunk(eval, item, frame.chunk_id, frame.cont_node)
				if !it_ok {
					return false
				}
				need_env := int(vcl.upval_len) + 1
				if eval.env_slot_count + need_env > len(eval.env_slots) || eval.thunk_count >= len(eval.thunks) {
					refuse(eval, {refusal = .Calls_Full, chunk_id = frame.chunk_id, node = frame.cont_node})
					return false
				}
				eoff := u32(eval.env_slot_count)
				for ui in 0 ..< int(vcl.upval_len) {
					eval.env_slots[eval.env_slot_count] = eval.env_slots[int(vcl.upval_off) + ui]
					eval.env_slot_count += 1
				}
				eval.env_slots[eval.env_slot_count] = item_tref
				eval.env_slot_count += 1
				vtref := Thunk_Ref(eval.thunk_count)
				eval.thunk_count += 1
				eval.thunks[vtref] = {
					state   = .Unforced,
					site_id = u32(frame.cont_node),
					payload = {code = {
						chunk_id = vcl.chunk_id,
						flags    = THUNK_FLAG_ONE_ARG,
						proto_id = vcl.proto_id,
						env_off  = eoff,
						env_len  = u32(need_env),
					}},
				}
				if eval.profile != nil {
					eval.profile.thunks_created += 1
				}
				eval.list_scratch[eval.list_scratch_top] = Value{kind = .None, data = u64(vtref)}
				eval.list_scratch_top += 1
				frame.cont_index += 1
				frame.cont_phase = 0
				continue

			case 3:
				// Console mode: value returned in reg_base + 0.
				val_v := eval.reg_stack[frame.reg_base]
				vtref, tok := alloc_forced_thunk(eval, val_v, frame.chunk_id, frame.cont_node)
				if !tok {
					return false
				}
				eval.list_scratch[eval.list_scratch_top] = Value{kind = .None, data = u64(vtref)}
				eval.list_scratch_top += 1
				frame.cont_index += 1
				frame.cont_phase = 0
				continue

			case:
				// Phase 0: start next element or finalize record.
				if frame.cont_index >= frame.cont_count {
					mark := frame.cont_out_off
					pairs := eval.list_scratch[mark:eval.list_scratch_top]
					eval.list_scratch_top = mark
					rec_val, rok := build_dynamic_record_from_pairs(eval, pairs, frame.chunk_id, frame.cont_node)
					if !rok {
						return false
					}
					vm_return_to_caller(eval, target_depth, rec_val)
					return true
				}
				item := eval.list_items[frame.cont_list_off + frame.cont_index]
				one_arg := [1]Value{item}
				if (frame.cont_flags & 1) != 0 {
					ccl := eval.closures[int(eval.reg_stack[frame.reg_base + 1].data)]
					frame.cont_phase = 1
					return push_bytecode_frame(eval, ccl.chunk_id, ccl.proto_id, ccl.upval_off, ccl.upval_len, one_arg[:], 0, NO_THUNK, frame.cont_node)
				}
				kcl := eval.closures[int(eval.reg_stack[frame.reg_base + 2].data)]
				frame.cont_phase = 2
				return push_bytecode_frame(eval, kcl.chunk_id, kcl.proto_id, kcl.upval_off, kcl.upval_len, one_arg[:], 0, NO_THUNK, frame.cont_node)
			}
		}

	case .Call_Site:
		return vm_step_call_site(eval, frame, target_depth)
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
	if !fn_arity_accepts_positional(cproto, 1) {
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
	return {kind = .Record_Literal, flags = desc.has_paths ? REC_VAL_FLAG_HAS_PATH : 0, data = u64(rec_idx), meta = desc.shape_id}, true
}

// ---- Comparison (step-charged).

@(private)
vm_compare :: proc "contextless" (eval: ^Evaluation, op: Opcode, left, right: Value, chunk_id: u16, node_idx: lex_parser.Node_Index) -> (bool, bool) {
	Compare_Op :: enum u8 {
		Eq,
		Neq,
		Lt,
		Le,
		Gt,
		Ge,
	}
	cmp_op: Compare_Op
	parser_op: lex_parser.Operator
	switch op {
	case .Eq:  cmp_op, parser_op = .Eq,  .Equal
	case .Neq: cmp_op, parser_op = .Neq, .Not_Equal
	case .Lt:  cmp_op, parser_op = .Lt,  .Less
	case .Le:  cmp_op, parser_op = .Le,  .Less_Or_Equal
	case .Gt:  cmp_op, parser_op = .Gt,  .Greater
	case .Ge:  cmp_op, parser_op = .Ge,  .Greater_Or_Equal
	case .Nop, .Move, .Load_None, .Load_Bool, .Load_Int_Imm, .Load_Const,
	     .Get_Upval, .Get_Let, .Let_Enter, .Neg, .Not, .Add, .Sub, .Mul, .Div, .Rem,
	     .List_Concat, .Jmp, .Jmp_If_False, .Jmp_If_False_Keep, .Jmp_If_True_Keep,
	     .Check_Bool, .Closure, .Check_Call, .Call, .Tail_Call, .Call_Builtin,
	     .Call_Site, .Ret, .Make_Record, .Get_Field, .Try_Get_Field, .With,
	     .Make_Rec_Comp, .Destructure, .Set_Let_Val, .Match_Eq,
	     .Check_Rec_Shape, .Match_Bind_Field, .Match_Fail, .Refuse_Eval,
	     .List_Begin, .List_Push, .List_End, .Str_Begin, .Str_Push, .Str_End,
	     .Assert_Fail, .Trace, .Load_Global, .Refuse_Parse, .Extra_Arg:
		refuse(eval, {refusal = .Host_Refused, chunk_id = chunk_id, node = node_idx})
		return false, false
	}
	if left.kind != right.kind {
		refuse(eval, {refusal = .Operator_Kinds, chunk_id = chunk_id, node = node_idx, operator = parser_op, left_kind = left.kind, right_kind = right.kind})
		return false, false
	}
	is_order := cmp_op != .Eq && cmp_op != .Neq
	switch left.kind {
	case .Integer:
		lu, ru := value_unit(left), value_unit(right)
		li, ri, _, ustatus := align_integer_units(value_integer(left), value_integer(right), lu, ru)
		switch ustatus {
		case .Ok:
		case .Overflow:
			refuse(eval, {refusal = .Overflow, chunk_id = chunk_id, node = node_idx, operator = parser_op, left = value_integer(left), right = value_integer(right)})
			return false, false
		case .Incompatible, .Non_Exact:
			refuse(eval, {refusal = .Unit_Mismatch, chunk_id = chunk_id, node = node_idx, operator = parser_op, left_kind = .Integer, right_kind = .Integer, left_unit = lu, right_unit = ru})
			return false, false
		}
		switch cmp_op {
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
		return cmp_op == .Eq ? same : !same, true
	case .Text:
		lt := value_text(eval, left)
		rt := value_text(eval, right)
		if !charge_steps(eval, u32(min(len(lt), len(rt)) / 64), chunk_id, node_idx) {
			return false, false
		}
		if is_order {
			c := str_cmp(lt, rt)
			switch cmp_op {
			case .Lt:  return c < 0, true
			case .Le:  return c <= 0, true
			case .Gt:  return c > 0, true
			case .Ge:  return c >= 0, true
			case .Eq, .Neq:
			}
		}
		same := lt == rt
		return cmp_op == .Eq ? same : !same, true
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
REC_VAL_FLAG_HAS_PATH :: u8(1)

@(private)
vm_with :: proc "contextless" (eval: ^Evaluation, left, right: Value, chunk_id: u16, node_idx: lex_parser.Node_Index) -> (result: Value, ok: bool) {
	if right.kind == .Record_Literal && (right.flags & REC_VAL_FLAG_HAS_PATH) != 0 {
		return vm_with_nested(eval, left, right, chunk_id, node_idx)
	}
	// Lazy record composition in both modes (including Plan_Value and Project_Value).
	if is_lazy_record(left.kind) && is_lazy_record(right.kind) {
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
				return refuse_field_unknown_with_suggestions(eval, left_shape_id, chunk_id, node_idx, fname, left.kind)
			}
		}
		patch_rec := lazy_record_compact(eval, right, chunk_id, node_idx) or_return
		inner_left := left
		preserve_tag := left.kind == .Plan_Value || left.kind == .Project_Value
		if preserve_tag {
			inner_left = eval.tagged_records[int(left.data)]
		}
		base_depth: u16 = 0
		if inner_left.kind == .Record_With {
			base_depth = eval.overlays[int(inner_left.data)].depth
		}
		if eval.overlay_count >= len(eval.overlays) {
			return refuse(eval, {refusal = .With_Pairs_Full, chunk_id = chunk_id, node = node_idx})
		}
		ov_idx := u32(eval.overlay_count)
		eval.overlays[ov_idx] = {
			base          = inner_left,
			base_shape_id = left_shape_id,
			patch_rec     = patch_rec,
			depth         = base_depth + 1,
		}
		eval.overlay_count += 1
		out_val := Value{kind = .Record_With, data = u64(ov_idx), meta = u32(base_depth + 1)}
		if base_depth + 1 > OVERLAY_COMPACT_THRESHOLD {
			flat_idx := lazy_record_compact(eval, out_val, chunk_id, node_idx) or_return
			out_val = {kind = .Record_Literal, data = u64(flat_idx), meta = left_shape_id}
		}
		if preserve_tag {
			if eval.tagged_record_count >= len(eval.tagged_records) {
				return refuse(eval, {refusal = .With_Pairs_Full, chunk_id = chunk_id, node = node_idx})
			}
			tidx := eval.tagged_record_count
			eval.tagged_records[tidx] = out_val
			eval.tagged_record_count += 1
			return {kind = left.kind, data = u64(tidx)}, true
		}
		return out_val, true
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

// ---- Lex v3 VM helpers: nested with, parameter annotations/defaults, match, comprehensions.

@(private)
fn_arity_accepts_positional :: proc "contextless" (proto: ^Proto, argc: int) -> bool {
	if argc > int(proto.param_count) {
		return false
	}
	for i in argc ..< int(proto.param_count) {
		if !proto.params[i].has_default {
			return false
		}
	}
	return true
}

@(private)
vm_check_param_annot :: proc "contextless" (
	eval: ^Evaluation,
	val: Value,
	annot: lex_parser.Param_Kind_Annot,
	unit: value_kinds.Integer_Unit,
	chunk_id: u16,
	node_idx: lex_parser.Node_Index,
	command: string,
	parameter: int,
	field: string,
) -> (Value, bool) {
	switch annot {
	case .None:
		return val, true
	case .Integer:
		if val.kind != .Integer {
			return refuse(eval, {refusal = .Parameter_Kind, chunk_id = chunk_id, node = node_idx, command = command, parameter = parameter, field = field, left_kind = val.kind, expected_annot = .Integer, right_unit = unit})
		}
		if unit.kind != .None {
			vu := value_unit(val)
			converted, status := convert_integer_unit(value_integer(val), vu, unit, false)
			switch status {
			case .Ok:
				return value_int_unit(converted, unit), true
			case .Overflow:
				return refuse(eval, {refusal = .Overflow, chunk_id = chunk_id, node = node_idx, left = value_integer(val)})
			case .Incompatible, .Non_Exact:
				return refuse(eval, {refusal = .Unit_Mismatch, chunk_id = chunk_id, node = node_idx, command = command, parameter = parameter, field = field, left_kind = .Integer, right_kind = .Integer, left_unit = vu, right_unit = unit})
			}
		}
		return val, true
	case .Boolean:
		if val.kind == .Boolean {
			return val, true
		}
	case .Text:
		if val.kind == .Text {
			return val, true
		}
	case .Hash:
		if val.kind == .Hash {
			return val, true
		}
	case .List:
		if val.kind == .List {
			return val, true
		}
	case .Record:
		if is_lazy_record(val.kind) || val.kind == .Record {
			return val, true
		}
	case .Function:
		if val.kind == .Function {
			return val, true
		}
	case .Enum:
		if val.kind == .Member || val.kind == .Enum {
			return val, true
		}
	case .Module_Ref:
		if val.kind == .Module_Ref {
			return val, true
		}
	case .Tree_Ref:
		if val.kind == .Tree_Ref {
			return val, true
		}
	case .Recipe_Ref:
		if val.kind == .Recipe_Ref {
			return val, true
		}
	case .Follow_Ref:
		if val.kind == .Follow_Ref {
			return val, true
		}
	case .Store_Ref:
		if val.kind == .Store_Ref {
			return val, true
		}
	case .Plan:
		if val.kind == .Plan_Value {
			return val, true
		}
	case .Project:
		if val.kind == .Project_Value {
			return val, true
		}
	case .Handle:
		if val.kind == .Handle {
			return val, true
		}
	case .Table:
		if val.kind == .Table {
			return val, true
		}
	case .Bytes:
		if val.kind == .Bytes {
			return val, true
		}
	}
	return refuse(eval, {refusal = .Parameter_Kind, chunk_id = chunk_id, node = node_idx, command = command, parameter = parameter, field = field, left_kind = val.kind, expected_annot = annot, right_unit = unit})
}

@(private)
vm_prepare_fn_args :: proc "contextless" (
	eval: ^Evaluation,
	cl: Closure,
	cproto: ^Proto,
	raw_args: []Value,
	given_mask: []bool,
	out_args: []Value,
	call_chunk_id: u16,
	call_node: lex_parser.Node_Index,
	command: string,
) -> bool {
	cchunk := &eval.chunks[cl.chunk_id]
	pcount := int(cproto.param_count)
	for i in 0 ..< pcount {
		pm := cproto.params[i]
		supplied := given_mask != nil ? (i < len(given_mask) && given_mask[i]) : (i < len(raw_args))
		val: Value
		err_chunk := call_chunk_id
		err_node := call_node
		if supplied {
			val = raw_args[i]
		} else if pm.has_default {
			// Map default_proto's Parent_Upval descriptors from cl.upval_off.
			dp := &eval.protos[int(cchunk.proto_start) + int(pm.default_proto)]
			deoff := u32(0)
			delen := dp.upval_count
			if delen > 0 {
				if eval.env_slot_count + int(delen) > len(eval.env_slots) {
					refuse(eval, {refusal = .Calls_Full, chunk_id = cl.chunk_id, node = pm.node_idx})
					return false
				}
				deoff = u32(eval.env_slot_count)
				for ui in 0 ..< int(delen) {
					uv := eval.upvals[int(dp.upval_start) + ui]
					if int(uv.index) >= int(cl.upval_len) {
						refuse(eval, {refusal = .Host_Refused, chunk_id = cl.chunk_id, node = pm.node_idx})
						return false
					}
					eval.env_slots[eval.env_slot_count] = eval.env_slots[int(cl.upval_off) + int(uv.index)]
					eval.env_slot_count += 1
				}
			}
			dv, dok := vm_exec_proto(eval, cl.chunk_id, pm.default_proto, deoff, delen, nil, NO_THUNK, pm.node_idx)
			if !dok {
				return false
			}
			val = dv
			err_chunk = cl.chunk_id
			err_node = pm.node_idx
		} else {
			refuse(eval, {refusal = .Function_Arguments, chunk_id = call_chunk_id, node = call_node, command = command, left = i64(len(raw_args)), right = i64(pcount)})
			return false
		}
		if pm.kind_annot != .None {
			pname := pm.name_sym != lex_parser.NO_SYM ? lex_parser.sym_text(&eval.interner, pm.name_sym) : ""
			checked, cok := vm_check_param_annot(eval, val, pm.kind_annot, pm.unit, err_chunk, err_node, command, i + 1, pname)
			if !cok {
				return false
			}
			val = checked
		}
		out_args[i] = val
	}
	return true
}

@(private)
vm_with_nested :: proc "contextless" (eval: ^Evaluation, left, right: Value, chunk_id: u16, node_idx: lex_parser.Node_Index) -> (Value, bool) {
	if !is_lazy_record(left.kind) {
		return refuse(eval, {refusal = .With_Kinds, chunk_id = chunk_id, node = node_idx, left_kind = left.kind, right_kind = .Record_Literal})
	}
	rec := eval.records[int(right.data)]
	shape := &eval.shapes[rec.shape_id]
	chunk := &eval.chunks[rec.chunk_id]
	desc := eval.rec_descs[int(chunk.rec_desc_start) + int(rec.desc_id)]
	fcount := int(shape.field_count)
	patch_syms := eval.shape_fields[int(shape.fields_off):int(shape.fields_off) + fcount]
	patch_thunks := eval.record_thunk_refs[int(rec.refs_off):int(rec.refs_off) + fcount]
	patch_nodes := eval.rec_field_nodes[int(desc.nodes_start):int(desc.nodes_start) + fcount]
	return vm_with_nested_group(eval, left, patch_syms, patch_thunks, patch_nodes, 0, 0, chunk_id, node_idx)
}

@(private)
vm_with_nested_group :: proc "contextless" (
	eval: ^Evaluation,
	base: Value,
	patch_syms: []lex_parser.Sym_Id,
	patch_thunks: []Thunk_Ref,
	patch_nodes: []lex_parser.Node_Index,
	prefix_len: int,
	depth: int,
	chunk_id: u16,
	node_idx: lex_parser.Node_Index,
) -> (Value, bool) {
	if !is_lazy_record(base.kind) {
		return refuse(eval, {refusal = .With_Kinds, chunk_id = chunk_id, node = node_idx, left_kind = base.kind, right_kind = .Record_Literal})
	}
	if depth >= lex_parser.DECLARATION_PARSE_DEPTH_LIMIT {
		return refuse(eval, {refusal = .Depth_Exceeded, chunk_id = chunk_id, node = node_idx})
	}
	if len(patch_syms) == 0 {
		return base, true
	}
	if !charge_steps(eval, u32(1 + len(patch_syms)), chunk_id, node_idx) {
		return {}, false
	}
	base_shape_id, bs_ok := lazy_record_base_shape(eval, base)
	if !bs_ok {
		return refuse(eval, {refusal = .With_Kinds, chunk_id = chunk_id, node = node_idx, left_kind = base.kind, right_kind = .Record_Literal})
	}
	record_shape_dep(eval, base, base_shape_id)

	// Pass 1: count distinct direct leaves and nested segment groups at this level.
	// Because patch_syms is UTF-8 sorted and '.' (46) precedes every identifier byte,
	// paths sharing a prefix are contiguous and distinct segments stay UTF-8 sorted.
	level_count := 0
	for i := 0; i < len(patch_syms); {
		rem := lex_parser.sym_text(&eval.interner, patch_syms[i])[prefix_len:]
		dot := index_byte(rem, '.')
		if dot < 0 {
			level_count += 1
			i += 1
		} else {
			seg := rem[:dot]
			j := i + 1
			for j < len(patch_syms) {
				jrem := lex_parser.sym_text(&eval.interner, patch_syms[j])[prefix_len:]
				if len(jrem) > len(seg) && jrem[:len(seg)] == seg && jrem[len(seg)] == '.' {
					j += 1
				} else {
					break
				}
			}
			level_count += 1
			i = j
		}
	}

	// Reserve this level's contiguous slices before recursing so child allocations
	// append strictly after this level's slots.
	if eval.shape_field_count + level_count > len(eval.shape_fields) ||
	   eval.record_thunk_ref_count + level_count > len(eval.record_thunk_refs) {
		return refuse(eval, {refusal = .With_Pairs_Full, chunk_id = chunk_id, node = node_idx})
	}
	foff := eval.shape_field_count
	eval.shape_field_count += level_count
	roff := eval.record_thunk_ref_count
	eval.record_thunk_ref_count += level_count

	// Pass 2: validate and fill each direct leaf (unforced) and nested segment.
	li := 0
	for i := 0; i < len(patch_syms); {
		full := lex_parser.sym_text(&eval.interner, patch_syms[i])
		rem := full[prefix_len:]
		dot := index_byte(rem, '.')
		if dot < 0 {
			sym := patch_syms[i]
			if prefix_len > 0 {
				s, sok := lex_parser.intern(&eval.interner, rem)
				if !sok {
					return refuse(eval, {refusal = .With_Pairs_Full, chunk_id = chunk_id, node = patch_nodes[i]})
				}
				sym = s
			}
			if _, exists := shape_lookup_sym(eval, base_shape_id, sym); !exists {
				return refuse_field_unknown_with_suggestions(eval, base_shape_id, chunk_id, patch_nodes[i], rem, base.kind)
			}
			eval.shape_fields[foff + li] = sym
			eval.record_thunk_refs[roff + li] = patch_thunks[i]
			li += 1
			i += 1
		} else {
			seg := rem[:dot]
			j := i + 1
			for j < len(patch_syms) {
				jrem := lex_parser.sym_text(&eval.interner, patch_syms[j])[prefix_len:]
				if len(jrem) > len(seg) && jrem[:len(seg)] == seg && jrem[len(seg)] == '.' {
					j += 1
				} else {
					break
				}
			}
			seg_sym, sok := lex_parser.intern(&eval.interner, seg)
			if !sok {
				return refuse(eval, {refusal = .With_Pairs_Full, chunk_id = chunk_id, node = patch_nodes[i]})
			}
			sub_tref, found := lazy_record_lookup_thunk(eval, base, seg_sym)
			if !found {
				return refuse_field_unknown_with_suggestions(eval, base_shape_id, chunk_id, patch_nodes[i], seg, base.kind)
			}
			sub_val, fok := vm_force_thunk(eval, sub_tref, chunk_id, patch_nodes[i])
			if !fok {
				return {}, false
			}
			updated_sub, uok := vm_with_nested_group(
				eval,
				sub_val,
				patch_syms[i:j],
				patch_thunks[i:j],
				patch_nodes[i:j],
				prefix_len + dot + 1,
				depth + 1,
				chunk_id,
				node_idx,
			)
			if !uok {
				return {}, false
			}
			new_tref, tok := alloc_forced_thunk(eval, updated_sub, chunk_id, patch_nodes[i])
			if !tok {
				return {}, false
			}
			eval.shape_fields[foff + li] = seg_sym
			eval.record_thunk_refs[roff + li] = new_tref
			li += 1
			i = j
		}
	}

	if eval.shape_count >= len(eval.shapes) || eval.record_count >= len(eval.records) {
		return refuse(eval, {refusal = .With_Pairs_Full, chunk_id = chunk_id, node = node_idx})
	}
	sid := u32(eval.shape_count)
	eval.shapes[sid] = {
		fields_off  = u32(foff),
		field_count = u32(level_count),
		shape_hash  = shape_hash_of_fields(&eval.interner, eval.shape_fields[foff:foff + level_count]),
	}
	eval.shape_count += 1
	build_shape_hash_index(eval, sid)
	ridx := u32(eval.record_count)
	eval.records[ridx] = {shape_id = sid, refs_off = u32(roff), chunk_id = chunk_id, node_idx = node_idx}
	eval.record_count += 1
	level_patch := Value{kind = .Record_Literal, data = u64(ridx), meta = sid}
	return vm_with(eval, base, level_patch, chunk_id, node_idx)
}

@(private)
vm_match_eq :: proc "contextless" (eval: ^Evaluation, left, right: Value, chunk_id: u16, node_idx: lex_parser.Node_Index) -> (bool, bool) {
	if left.kind != right.kind {
		return false, true
	}
	switch left.kind {
	case .Integer:
		li, ri, _, ustatus := align_integer_units(value_integer(left), value_integer(right), value_unit(left), value_unit(right))
		if ustatus != .Ok {
			return false, true
		}
		return li == ri, true
	case .Boolean:
		return value_boolean(left) == value_boolean(right), true
	case .Text:
		lt := value_text(eval, left)
		rt := value_text(eval, right)
		if !charge_steps(eval, u32(min(len(lt), len(rt)) / 64), chunk_id, node_idx) {
			return false, false
		}
		return lt == rt, true
	case .Hash, .Module_Ref, .Tree_Ref:
		lh, lok := hash_of(eval, left)
		rh, rok := hash_of(eval, right)
		return lok && rok && lh == rh, true
	case .Member:
		return left.meta == right.meta, true
	case .None, .Record, .Handle, .Table, .Bytes, .Stream, .Record_Input, .Record_Literal,
	     .Enum, .Function, .List, .Record_With, .Recipe_Ref, .Follow_Ref, .Store_Ref,
	     .Plan_Value, .Project_Value:
		return false, true
	}
	return false, true
}

@(private)
vm_check_rec_shape :: proc "contextless" (eval: ^Evaluation, frame: ^VM_Frame, src_val: Value, pat_desc_rel: u32, node_idx: lex_parser.Node_Index) -> (bool, bool) {
	chunk := &eval.chunks[frame.chunk_id]
	desc := eval.pat_descs[int(chunk.pat_desc_start) + int(pat_desc_rel)]
	pfields := eval.pat_fields[int(desc.fields_start):int(desc.fields_start) + int(desc.field_count)]
	if !charge_steps(eval, u32(1 + len(pfields)), frame.chunk_id, node_idx) {
		return false, false
	}
	if is_lazy_record(src_val.kind) {
		shape_id, sok := lazy_record_base_shape(eval, src_val)
		if !sok {
			return false, true
		}
		record_shape_dep(eval, src_val, shape_id)
		shape := &eval.shapes[shape_id]
		if !desc.has_rest && int(shape.field_count) != len(pfields) {
			return false, true
		}
		for pf in pfields {
			if _, found := shape_lookup_sym(eval, shape_id, pf.sym); !found {
				return false, true
			}
		}
		return true, true
	}
	if src_val.kind == .Record {
		hv := value_to_host(eval, src_val)
		described, dok := module.record_type(hv.file, hv.detail)
		if !dok {
			return false, true
		}
		if !desc.has_rest && int(described.field_count) != len(pfields) {
			return false, true
		}
		for pf in pfields {
			fname := lex_parser.sym_text(&eval.interner, pf.sym)
			if _, _, found := record_field_find(hv.file, described, fname); !found {
				return false, true
			}
		}
		return true, true
	}
	return false, true
}

@(private)
vm_start_rec_comp :: proc "contextless" (eval: ^Evaluation, frame: ^VM_Frame, dst_reg: u8, iter_val: Value, comp_rel: u32, node_idx: lex_parser.Node_Index) -> bool {
	if iter_val.kind != .List {
		refuse(eval, {refusal = .Not_A_List, chunk_id = frame.chunk_id, node = node_idx, left_kind = iter_val.kind})
		return false
	}
	cnt := iter_val.meta
	if cnt == 0 {
		rec_val, rok := build_dynamic_record_from_pairs(eval, nil, frame.chunk_id, node_idx)
		if !rok {
			return false
		}
		eval.reg_stack[int(frame.reg_base) + int(dst_reg)] = rec_val
		return true
	}
	chunk := &eval.chunks[frame.chunk_id]
	cdesc := eval.comp_descs[int(chunk.comp_desc_start) + int(comp_rel)]

	// Capture enclosing upvalues once for cond (if any), key, and val protos.
	cond_cl_val: Value
	if cdesc.has_cond {
		eoff, elen, eok := capture_upvals(eval, frame, frame.chunk_id, cdesc.cond_proto, node_idx)
		if !eok {
			return false
		}
		if eval.closure_count >= len(eval.closures) {
			refuse(eval, {refusal = .Calls_Full, chunk_id = frame.chunk_id, node = node_idx})
			return false
		}
		cidx := u32(eval.closure_count)
		eval.closures[cidx] = {chunk_id = frame.chunk_id, upval_len = elen, proto_id = cdesc.cond_proto, upval_off = eoff}
		eval.closure_count += 1
		cond_cl_val = {kind = .Function, data = u64(cidx)}
	}
	keoff, kelen, keok := capture_upvals(eval, frame, frame.chunk_id, cdesc.key_proto, node_idx)
	if !keok {
		return false
	}
	if eval.closure_count >= len(eval.closures) {
		refuse(eval, {refusal = .Calls_Full, chunk_id = frame.chunk_id, node = node_idx})
		return false
	}
	kidx := u32(eval.closure_count)
	eval.closures[kidx] = {chunk_id = frame.chunk_id, upval_len = kelen, proto_id = cdesc.key_proto, upval_off = keoff}
	eval.closure_count += 1
	key_cl_val := Value{kind = .Function, data = u64(kidx)}

	veoff, velen, veok := capture_upvals(eval, frame, frame.chunk_id, cdesc.val_proto, node_idx)
	if !veok {
		return false
	}
	if eval.closure_count >= len(eval.closures) {
		refuse(eval, {refusal = .Calls_Full, chunk_id = frame.chunk_id, node = node_idx})
		return false
	}
	vidx := u32(eval.closure_count)
	eval.closures[vidx] = {chunk_id = frame.chunk_id, upval_len = velen, proto_id = cdesc.val_proto, upval_off = veoff}
	eval.closure_count += 1
	val_cl_val := Value{kind = .Function, data = u64(vidx)}

	if eval.frame_count >= len(eval.frames) || int(eval.reg_top) + 4 > len(eval.reg_stack) {
		refuse(eval, {refusal = .Calls_Full, chunk_id = frame.chunk_id, node = node_idx})
		return false
	}
	reg_base := eval.reg_top
	eval.reg_top += 4
	eval.reg_stack[reg_base] = {}
	eval.reg_stack[reg_base + 1] = cond_cl_val
	eval.reg_stack[reg_base + 2] = key_cl_val
	eval.reg_stack[reg_base + 3] = val_cl_val

	cframe := &eval.frames[eval.frame_count]
	cframe^ = {
		kind          = .Rec_Comp,
		dst_reg       = dst_reg,
		chunk_id      = frame.chunk_id,
		reg_base      = reg_base,
		let_base      = eval.let_slot_top,
		cont_phase    = 0,
		cont_flags    = cdesc.has_cond ? 1 : 0,
		return_thunk  = NO_THUNK,
		cont_list_off = u32(iter_val.data),
		cont_count    = cnt,
		cont_index    = 0,
		cont_out_off  = eval.list_scratch_top,
		cont_node     = node_idx,
	}
	eval.frame_count += 1
	return true
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
Call_Site_Callee_Kind :: enum u8 {
	Host     = 0,
	Function = 1,
	Builtin  = 2,
}

@(private)
call_site_callee_of_byte :: proc "contextless" (b: u8) -> (Call_Site_Callee_Kind, bool) {
	switch b {
	case u8(Call_Site_Callee_Kind.Host):
		return .Host, true
	case u8(Call_Site_Callee_Kind.Function):
		return .Function, true
	case u8(Call_Site_Callee_Kind.Builtin):
		return .Builtin, true
	}
	return .Host, false
}

@(private)
call_site_resolve_callee :: #force_no_inline proc "contextless" (
	eval: ^Evaluation,
	chunk_id: u16,
	site: Call_Site_Desc,
	name: string,
	fn_val: Value,
) -> (callee: Call_Site_Callee_Kind, builtin_id: Builtin_Id, sig: Command_Signature, ok: bool) {
	callee = .Host
	if site.callee_kind == .Reg {
		if fn_val.kind != .Function {
			refuse(eval, {refusal = .Not_A_Function, chunk_id = chunk_id, node = site.node_idx, command = name, left_kind = fn_val.kind})
			return {}, {}, {}, false
		}
		callee = .Function
		cl := eval.closures[int(fn_val.data)]
		cchunk := &eval.chunks[cl.chunk_id]
		cproto := &eval.protos[int(cchunk.proto_start) + int(cl.proto_id)]
		sig = {parameter_count = int(cproto.param_count), untyped = true}
		for i in 0 ..< sig.parameter_count {
			sig.names[i] = lex_parser.sym_text(&eval.interner, cproto.params[i].name_sym)
			sig.optional[i] = cproto.params[i].has_default
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
	} else if name == FROM_ENTRIES_NAME {
		callee, builtin_id = .Builtin, .From_Entries
		sig = {parameter_count = 1, untyped = true}
		sig.names[0] = "entries"
	} else if name == LEN_NAME {
		callee, builtin_id = .Builtin, .Len
		sig = {parameter_count = 1, untyped = true}
		sig.names[0] = "value"
	} else if name == AT_NAME {
		callee, builtin_id = .Builtin, .At
		sig = {parameter_count = 2, untyped = true}
		sig.names[0], sig.names[1] = "list", "index"
	} else if name == SLICE_NAME {
		callee, builtin_id = .Builtin, .Slice
		sig = {parameter_count = 3, untyped = true}
		sig.names[0], sig.names[1], sig.names[2] = "list", "start", "end"
	} else if name == ANY_NAME {
		callee, builtin_id = .Builtin, .Any
		sig = {parameter_count = 2, untyped = true}
		sig.names[0], sig.names[1] = "list", "function"
	} else if name == ALL_NAME {
		callee, builtin_id = .Builtin, .All
		sig = {parameter_count = 2, untyped = true}
		sig.names[0], sig.names[1] = "list", "function"
	} else if name == FLAT_MAP_NAME {
		callee, builtin_id = .Builtin, .Flat_Map
		sig = {parameter_count = 2, untyped = true}
		sig.names[0], sig.names[1] = "list", "function"
	} else if name == UNIQUE_NAME {
		callee, builtin_id = .Builtin, .Unique
		sig = {parameter_count = 1, untyped = true}
		sig.names[0] = "list"
	} else if name == SORT_BY_NAME {
		callee, builtin_id = .Builtin, .Sort_By
		sig = {parameter_count = 2, untyped = true}
		sig.names[0], sig.names[1] = "list", "function"
	} else if name == SPLIT_NAME {
		callee, builtin_id = .Builtin, .Split
		sig = {parameter_count = 2, untyped = true}
		sig.names[0], sig.names[1] = "text", "separator"
	} else if name == JOIN_TEXT_NAME {
		callee, builtin_id = .Builtin, .Join_Text
		sig = {parameter_count = 2, untyped = true}
		sig.names[0], sig.names[1] = "list", "separator"
	} else if name == STARTS_WITH_NAME {
		callee, builtin_id = .Builtin, .Starts_With
		sig = {parameter_count = 2, untyped = true}
		sig.names[0], sig.names[1] = "text", "prefix"
	} else if name == ENDS_WITH_NAME {
		callee, builtin_id = .Builtin, .Ends_With
		sig = {parameter_count = 2, untyped = true}
		sig.names[0], sig.names[1] = "text", "suffix"
	} else if name == CONTAINS_NAME {
		callee, builtin_id = .Builtin, .Contains
		sig = {parameter_count = 2, untyped = true}
		sig.names[0], sig.names[1] = "text", "needle"
	} else if name == REPLACE_TEXT_NAME {
		callee, builtin_id = .Builtin, .Replace_Text
		sig = {parameter_count = 3, untyped = true}
		sig.names[0], sig.names[1], sig.names[2] = "text", "old", "new"
	} else {
		if eval.host.command_find == nil {
			refuse(eval, {refusal = .Host_Refused, chunk_id = chunk_id, node = site.node_idx})
			return {}, {}, {}, false
		}
		found: bool
		sig, found = eval.host.command_find(eval.host.data, name)
		if refused(eval) {
			return {}, {}, {}, false
		}
		if !found {
			refuse(eval, {refusal = .Host_Refused, chunk_id = chunk_id, node = site.node_idx})
			return {}, {}, {}, false
		}
		if eval.mode == .Declaration && sig.has_effect {
			refuse(eval, {refusal = .Effect_Refused, chunk_id = chunk_id, node = site.node_idx, command = name})
			return {}, {}, {}, false
		}
	}
	return callee, builtin_id, sig, true
}

@(private)
call_site_border_check :: #force_no_inline proc "contextless" (
	eval: ^Evaluation,
	chunk_id: u16,
	site: Call_Site_Desc,
	name: string,
	fn_val: Value,
	param_count: int,
	sarg: Call_Site_Arg,
	slot: int,
	val_vm: Value,
) -> (out_vm: Value, ok: bool) {
	if val_vm.kind == .Function || val_vm.kind == .List {
		refuse(eval, {refusal = .Value_At_Border, chunk_id = chunk_id, node = sarg.node_idx, command = name, parameter = slot + 1, left_kind = val_vm.kind})
		return {}, false
	}
	if val_vm.kind == .Record_Literal {
		_, _, sig, sok := call_site_resolve_callee(eval, chunk_id, site, name, fn_val)
		if !sok {
			return {}, false
		}
		if slot >= param_count || sig.kinds[slot] != .Record || sig.files[slot] == nil {
			rk := slot < param_count ? sig.kinds[slot] : Kind.None
			refuse(eval, {refusal = .Literal_No_Type, chunk_id = chunk_id, node = sarg.val_node, command = name, parameter = slot + 1, right_kind = rk})
			return {}, false
		}
		typed_hv, tok := literal_type_to_record(eval, val_vm, sig.files[slot], sig.details[slot], nil, sig.empty_record_zeroed[slot])
		if !tok {
			return {}, false
		}
		converted, cok := host_to_value(eval, typed_hv)
		if !cok {
			refuse(eval, {refusal = .Calls_Full, chunk_id = chunk_id, node = sarg.val_node})
			return {}, false
		}
		return converted, true
	}
	if val_vm.kind == .Member {
		_, _, sig, sok := call_site_resolve_callee(eval, chunk_id, site, name, fn_val)
		if !sok {
			return {}, false
		}
		if slot >= param_count || sig.kinds[slot] != .Enum || sig.files[slot] == nil {
			rk := slot < param_count ? sig.kinds[slot] : Kind.None
			refuse(eval, {refusal = .Member_No_Type, chunk_id = chunk_id, node = sarg.val_node, command = name, parameter = slot + 1, right_kind = rk})
			return {}, false
		}
		mname := member_name_of(eval, val_vm)
		mval, mok := enum_member_value(sig.files[slot], sig.details[slot], mname)
		if !mok {
			refuse(eval, {refusal = .Member_Unknown, chunk_id = chunk_id, node = sarg.val_node, command = name, parameter = slot + 1, field = mname, file = sig.files[slot], detail = sig.details[slot]})
			return {}, false
		}
		typed_hv := Host_Value{kind = .Enum, integer = mval, file = sig.files[slot], detail = sig.details[slot]}
		converted, cok := host_to_value(eval, typed_hv)
		if !cok {
			refuse(eval, {refusal = .Calls_Full, chunk_id = chunk_id, node = sarg.val_node})
			return {}, false
		}
		return converted, true
	}
	return val_vm, true
}

// vm_exec_call_site validates a call site and pushes a flat .Call_Site
// continuation frame so argument evaluation uses zero C-stack recursion.
@(private)
vm_exec_call_site :: #force_no_inline proc "contextless" (eval: ^Evaluation, frame: ^VM_Frame, site_rel: u32, dst_reg: u8) -> bool {
	chunk := &eval.chunks[frame.chunk_id]
	site := eval.call_sites[int(chunk.site_start) + int(site_rel)]
	name := lex_parser.sym_text(&eval.interner, site.name_sym)

	fn_val: Value
	if site.callee_kind == .Reg {
		fn_val = eval.reg_stack[int(frame.reg_base) + int(site.callee_reg)]
	}
	callee, builtin_id, sig, rok := call_site_resolve_callee(eval, frame.chunk_id, site, name, fn_val)
	if !rok {
		return false
	}

	param_count := clamp(sig.parameter_count, 0, lex_parser.ARGUMENT_CAPACITY)
	args := eval.site_args[int(site.args_start):int(site.args_start) + int(site.arg_count)]

	// Step 1: Map each argument to its parameter slot (before evaluating any arg).
	arg_slots: [lex_parser.ARGUMENT_CAPACITY + 2]int
	given: [lex_parser.ARGUMENT_CAPACITY]bool
	given_mask: u16 = 0
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
			given_mask |= u16(1) << uint(slot)
		}
		arg_slots[i] = slot
		given_count += 1
	}

	// Step 2: Check missing named parameters & Lex function arity BEFORE any arg runs.
	missing_required := false
	for p in 0 ..< param_count {
		optional := sig.optional[p] || (sig.optional_last && p == param_count - 1)
		if !given[p] && !optional {
			if site.has_named && !site.has_refused_arg {
				refuse(eval, {refusal = .Argument_Missing, chunk_id = frame.chunk_id, node = site.node_idx, command = name, field = sig.names[p]})
				return false
			}
			missing_required = true
		}
	}
	if !site.has_refused_arg {
		if callee == .Builtin && given_count != param_count {
			refuse(eval, {refusal = .Function_Arguments, chunk_id = frame.chunk_id, node = site.node_idx, command = name, left = i64(given_count), right = i64(param_count)})
			return false
		}
		if callee == .Function {
			cl := eval.closures[int(fn_val.data)]
			cchunk := &eval.chunks[cl.chunk_id]
			cproto := &eval.protos[int(cchunk.proto_start) + int(cl.proto_id)]
			if site.has_named {
				if given_count > param_count {
					refuse(eval, {refusal = .Function_Arguments, chunk_id = frame.chunk_id, node = site.node_idx, command = name, left = i64(given_count), right = i64(param_count)})
					return false
				}
			} else if !fn_arity_accepts_positional(cproto, given_count) {
				refuse(eval, {refusal = .Function_Arguments, chunk_id = frame.chunk_id, node = site.node_idx, command = name, left = i64(given_count), right = i64(param_count)})
				return false
			}
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
				if !literal_desc_check_names(eval, frame.chunk_id, sarg.record_desc, sig.files[slot], sig.details[slot], sig.empty_record_zeroed[slot]) {
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

	// Step 4: Push a flat .Call_Site continuation frame on eval.frames.
	if eval.frame_count >= eval.depth_limit {
		refuse(eval, {refusal = .Depth_Exceeded, chunk_id = frame.chunk_id, node = site.node_idx, left = i64(eval.frame_count), right = i64(eval.depth_limit)})
		return false
	}
	if eval.frame_count >= len(eval.frames) {
		refuse(eval, {refusal = .Calls_Full, chunk_id = frame.chunk_id, node = site.node_idx})
		return false
	}
	used_bytes := uint(eval.frame_count + 1) * uint(size_of(VM_Frame) + 64)
	if used_bytes > eval.stack_bytes {
		refuse(eval, {refusal = .Stack_Exceeded, chunk_id = frame.chunk_id, node = site.node_idx, left = i64(used_bytes), right = i64(eval.stack_bytes)})
		return false
	}
	if used_bytes > eval.stack_deepest {
		eval.stack_deepest = used_bytes
	}
	cs_reg_base := eval.reg_top
	need_regs := u32(lex_parser.ARGUMENT_CAPACITY + 1)
	if int(cs_reg_base) + int(need_regs) > len(eval.reg_stack) {
		refuse(eval, {refusal = .Calls_Full, chunk_id = frame.chunk_id, node = site.node_idx})
		return false
	}
	for k in 0 ..< int(need_regs) {
		eval.reg_stack[int(cs_reg_base) + k] = {}
	}
	cs_flags := u8(callee)
	if missing_required {
		cs_flags |= 0x80
	}
	if sig.untyped {
		cs_flags |= 0x40
	}
	if sig.optional_last {
		cs_flags |= 0x20
	}
	cs_frame := VM_Frame{
		kind          = .Call_Site,
		dst_reg       = dst_reg,
		chunk_id      = frame.chunk_id,
		proto_id      = site_rel,
		ip            = u32(eval.frame_count - 1),
		reg_base      = cs_reg_base,
		let_base      = eval.let_slot_top,
		env_off       = u32(builtin_id),
		env_len       = given_mask,
		cont_phase    = 0,
		cont_flags    = cs_flags,
		return_thunk  = NO_THUNK,
		cont_list_off = u32(param_count),
		cont_count    = u32(site.arg_count),
		cont_index    = 0,
		cont_out_off  = 0,
		cont_fn       = fn_val,
		cont_node     = site.node_idx,
	}
	for i in 0 ..< min(len(args), lex_parser.ARGUMENT_CAPACITY) {
		cs_frame.boxed_params[i] = Thunk_Ref(u32(i32(arg_slots[i])))
	}
	eval.frames[eval.frame_count] = cs_frame
	eval.frame_count += 1
	eval.reg_top = cs_reg_base + need_regs
	return true
}

@(private)
vm_step_call_site :: #force_no_inline proc "contextless" (eval: ^Evaluation, frame: ^VM_Frame, target_depth: int) -> bool {
	_ = target_depth
	chunk := &eval.chunks[frame.chunk_id]
	site := eval.call_sites[int(chunk.site_start) + int(frame.proto_id)]
	name := lex_parser.sym_text(&eval.interner, site.name_sym)
	args := eval.site_args[int(site.args_start):int(site.args_start) + int(site.arg_count)]
	callee, callee_ok := call_site_callee_of_byte(frame.cont_flags & 0x03)
	if !callee_ok {
		refuse(eval, {refusal = .Host_Refused, chunk_id = frame.chunk_id, node = site.node_idx})
		return false
	}
	missing_required := (frame.cont_flags & 0x80) != 0
	untyped := (frame.cont_flags & 0x40) != 0
	optional_last := (frame.cont_flags & 0x20) != 0
	param_count := int(frame.cont_list_off)

	// Returning from an evaluated .Expr argument sub-proto.
	if frame.cont_phase == 1 {
		i := int(frame.cont_index)
		sarg := args[i]
		slot := int(i32(u32(frame.boxed_params[i])))
		val_vm := eval.reg_stack[int(frame.reg_base) + lex_parser.ARGUMENT_CAPACITY]
		if !untyped {
			checked_vm, cok := call_site_border_check(eval, frame.chunk_id, site, name, frame.cont_fn, param_count, sarg, slot, val_vm)
			if !cok {
				return false
			}
			val_vm = checked_vm
		}
		eval.reg_stack[int(frame.reg_base) + slot] = val_vm
		if u32(slot + 1) > frame.cont_out_off {
			frame.cont_out_off = u32(slot + 1)
		}
		frame.cont_index += 1
		frame.cont_phase = 0
	}

	// Evaluate remaining arguments in exact source order.
	for frame.cont_index < frame.cont_count {
		i := int(frame.cont_index)
		sarg := args[i]
		if sarg.kind == .Refused {
			tref := chunk.tree != nil ? lex_parser.node_refusal(chunk.tree, sarg.node_idx) : .Unexpected
			refuse(eval, {refusal = .Text, text_refusal = tref, chunk_id = frame.chunk_id, node = sarg.node_idx})
			return false
		}
		slot := i < lex_parser.ARGUMENT_CAPACITY ? int(i32(u32(frame.boxed_params[i]))) : -1
		if slot < 0 || slot >= lex_parser.ARGUMENT_CAPACITY {
			refuse(eval, {refusal = .Text, text_refusal = .Too_Many_Arguments, chunk_id = frame.chunk_id, node = sarg.node_idx})
			return false
		}
		val_vm: Value
		switch sarg.kind {
		case .Refused:
		case .Expr:
			parent_frame := &eval.frames[frame.ip]
			eoff, elen, eok := capture_upvals(eval, parent_frame, frame.chunk_id, sarg.proto_id, sarg.val_node)
			if !eok {
				return false
			}
			frame.cont_phase = 1
			return push_bytecode_frame(eval, frame.chunk_id, sarg.proto_id, eoff, elen, nil, u8(lex_parser.ARGUMENT_CAPACITY), NO_THUNK, sarg.val_node)
		case .Condition:
			if eval.host.condition_value == nil {
				refuse(eval, {refusal = .Host_Refused, chunk_id = frame.chunk_id, node = sarg.node_idx})
				return false
			}
			prev_count := int(frame.cont_out_off)
			prev_args: [lex_parser.ARGUMENT_CAPACITY]Host_Value
			for p in 0 ..< prev_count {
				prev_args[p] = value_to_host(eval, eval.reg_stack[int(frame.reg_base) + p])
			}
			chv, cok := eval.host.condition_value(eval.host.data, eval, name, prev_args[:prev_count], sarg.node_idx)
			if refused(eval) {
				return false
			}
			if !cok {
				refuse(eval, {refusal = .Host_Refused, chunk_id = frame.chunk_id, node = sarg.node_idx})
				return false
			}
			v, vok := host_to_value(eval, chv)
			if !vok {
				refuse(eval, {refusal = .Calls_Full, chunk_id = frame.chunk_id, node = sarg.node_idx})
				return false
			}
			val_vm = v
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
			v, vok := host_to_value(eval, fhv)
			if !vok {
				refuse(eval, {refusal = .Calls_Full, chunk_id = frame.chunk_id, node = sarg.node_idx})
				return false
			}
			val_vm = v
		case .Field_Names:
			if chunk.tree != nil && lex_parser.node_refusal(chunk.tree, sarg.node_idx) == .Field_Name_Missing {
				refuse(eval, {refusal = .Text, text_refusal = .Field_Name_Missing, chunk_id = frame.chunk_id, node = sarg.node_idx, command = name})
				return false
			}
			ft := node_text_in_chunk(eval, frame.chunk_id, sarg.node_idx)
			v, vok := host_to_value(eval, {kind = .Text, text = ft})
			if !vok {
				refuse(eval, {refusal = .Calls_Full, chunk_id = frame.chunk_id, node = sarg.node_idx})
				return false
			}
			val_vm = v
		}
		if !untyped {
			checked_vm, cok := call_site_border_check(eval, frame.chunk_id, site, name, frame.cont_fn, param_count, sarg, slot, val_vm)
			if !cok {
				return false
			}
			val_vm = checked_vm
		}
		eval.reg_stack[int(frame.reg_base) + slot] = val_vm
		if u32(slot + 1) > frame.cont_out_off {
			frame.cont_out_off = u32(slot + 1)
		}
		frame.cont_index += 1
	}

	// Step 5: All arguments evaluated. Copy out, pop the .Call_Site frame, and invoke callee.
	dst_reg := frame.dst_reg
	chunk_id := frame.chunk_id
	builtin_id, bid_ok := builtin_of_byte(u8(frame.env_off))
	if callee == .Builtin && !bid_ok {
		refuse(eval, {refusal = .Host_Refused, chunk_id = chunk_id, node = site.node_idx})
		return false
	}
	given_mask := frame.env_len
	arg_total := int(frame.cont_out_off)
	fn_val := frame.cont_fn
	cs_reg_base := frame.reg_base
	cs_let_base := frame.let_base
	vm_args: [lex_parser.ARGUMENT_CAPACITY]Value
	copy_count := max(param_count, arg_total)
	for p in 0 ..< copy_count {
		vm_args[p] = eval.reg_stack[int(cs_reg_base) + p]
	}

	eval.frame_count -= 1
	eval.reg_top = cs_reg_base
	eval.let_slot_top = cs_let_base
	caller := &eval.frames[eval.frame_count - 1]

	switch callee {
	case .Builtin:
		return vm_exec_builtin(eval, caller, builtin_id, vm_args[:param_count], dst_reg, site.node_idx)
	case .Function:
		cl := eval.closures[int(fn_val.data)]
		cchunk := &eval.chunks[cl.chunk_id]
		cproto := &eval.protos[int(cchunk.proto_start) + int(cl.proto_id)]
		given: [lex_parser.ARGUMENT_CAPACITY]bool
		for p in 0 ..< param_count {
			given[p] = (given_mask & (u16(1) << uint(p))) != 0
		}
		prepared: [lex_parser.ARGUMENT_CAPACITY]Value
		if !vm_prepare_fn_args(eval, cl, cproto, vm_args[:param_count], given[:param_count], prepared[:param_count], chunk_id, site.node_idx, name) {
			return false
		}
		eval.call_count += 1
		if eval.profile != nil {
			eval.profile.calls_total += 1
		}
		return push_bytecode_frame(eval, cl.chunk_id, cl.proto_id, cl.upval_off, cl.upval_len, prepared[:param_count], dst_reg, NO_THUNK, site.node_idx)
	case .Host:
		if eval.host.call_run == nil {
			refuse(eval, {refusal = .Host_Refused, chunk_id = chunk_id, node = site.node_idx})
			return false
		}
		// Pass the full parameter count (less an omitted optional_last slot)
		// when all required parameters are present so trailing optional
		// parameters reach the host as .None (Presence.Absent).
		passed := arg_total
		if site.has_named || !missing_required {
			last_given := param_count > 0 && (given_mask & (u16(1) << uint(param_count - 1))) != 0
			optional_tail := optional_last && param_count > 0 && !last_given ? 1 : 0
			passed = max(passed, param_count - optional_tail)
		}
		host_args: [lex_parser.ARGUMENT_CAPACITY]Host_Value
		for p in 0 ..< passed {
			host_args[p] = value_to_host(eval, vm_args[p])
		}
		res_hv, rok := eval.host.call_run(eval.host.data, name, host_args[:passed])
		if refused(eval) {
			return false
		}
		if !rok {
			refuse(eval, {refusal = .Host_Refused, chunk_id = chunk_id, node = site.node_idx})
			return false
		}
		res_vm, vok := host_to_value(eval, res_hv)
		if !vok {
			refuse(eval, {refusal = .Calls_Full, chunk_id = chunk_id, node = site.node_idx})
			return false
		}
		eval.reg_stack[int(caller.reg_base) + int(dst_reg)] = res_vm
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
literal_desc_check_names :: proc "contextless" (eval: ^Evaluation, chunk_id: u16, desc_rel: u32, file: []u8, detail: u32, allow_empty := false) -> bool {
	described, ok := module.record_type(file, detail)
	if !ok {
		return false
	}
	chunk := &eval.chunks[chunk_id]
	desc := eval.rec_descs[int(chunk.rec_desc_start) + int(desc_rel)]
	if desc.field_count == 0 && allow_empty {
		return true
	}
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
literal_type_to_record :: proc "contextless" (eval: ^Evaluation, lit_val: Value, file: []u8, detail: u32, base_bytes: []u8, allow_empty := false) -> (Host_Value, bool) {
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
	if base_bytes == nil && !(desc.field_count == 0 && allow_empty) {
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
	} else if desc.field_count == 0 && allow_empty {
		for &b in bytes {
			b = 0
		}
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
			if fu := value_unit(fval); fu.kind != .None {
				refuse(eval, {refusal = .Unit_Mismatch, chunk_id = rec.chunk_id, node = fnode, field = fname, field_item = item, left_kind = .Integer, right_kind = .Integer, left_unit = fu, file = file, detail = detail})
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
		case .Bytes:
			if item.detail != 32 || fval.kind != .Hash || int(item.offset) + 32 > len(bytes) {
				refuse(eval, {refusal = .Literal_Field_Kind, chunk_id = rec.chunk_id, node = fnode, field = fname, field_item = item, left_kind = fval.kind, file = file, detail = detail})
				return {}, false
			}
			hash_bytes, hok := hash_of(eval, fval)
			if !hok {
				refuse(eval, {refusal = .Literal_Field_Kind, chunk_id = rec.chunk_id, node = fnode, field = fname, field_item = item, left_kind = fval.kind, file = file, detail = detail})
				return {}, false
			}
			copy(bytes[int(item.offset):int(item.offset) + 32], hash_bytes[:])
		case .None, .Record, .Table, .Enum:
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
