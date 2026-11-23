// Pure lazy .lex declaration evaluator built on the Lex v2 register bytecode VM
// (src/md/features/declarations.md, "Lex v2 engine").
//
// Evaluates multi-line .lex files lazily with zero side effects and zero I/O.
// Every pool is carved from caller-supplied memory (no static 16-tree, 1024-field,
// or 2048-list caps). Serialization and structural equality charge
// EVALUATION_BUDGET_STEPS to defeat exponential DAG expansion.
package lex_evaluator

import "modus:contract/blake3"
import "modus:contract/declaration_eval"
import "modus:contract/plans_recipes"
import "modus:hash_table"
import "modus:lex_parser"

// ---- Plan value constructors shared by both modes.

Plan_Make_Problem :: enum u8 {
	None         = 0,
	Not_A_Record = 1,
	Pool_Full    = 2,
}

// plan_value_make tags a lazy record as a plan.
plan_value_make :: proc "contextless" (eval: ^Evaluation, record: Host_Value) -> (value: Host_Value, problem: Plan_Make_Problem) {
	vm_rec := record.vm_value
	if !is_lazy_record(vm_rec.kind) {
		return {}, .Not_A_Record
	}
	if eval.tagged_record_count >= len(eval.tagged_records) {
		return {}, .Pool_Full
	}
	idx := eval.tagged_record_count
	eval.tagged_records[idx] = vm_rec
	eval.tagged_record_count += 1
	v := Value{kind = .Plan_Value, data = u64(idx)}
	return value_to_host(eval, v), .None
}

// store_ref_make constructs `store(name, rights...)`: a Text followed by Members.
store_ref_make :: proc "contextless" (eval: ^Evaluation, arguments: []Host_Value) -> (value: Host_Value, problem: Plan_Make_Problem) {
	if len(arguments) < 1 || arguments[0].kind != .Text {
		return {}, .Not_A_Record
	}
	right_count := len(arguments) - 1
	if eval.store_count >= len(eval.stores) || right_count > len(eval.list_items) - eval.list_item_count {
		return {}, .Pool_Full
	}
	first := eval.list_item_count
	for i in 0 ..< right_count {
		if arguments[i + 1].kind != .Member {
			return {}, .Not_A_Record
		}
		v, ok := host_to_value(eval, arguments[i + 1])
		if !ok {
			return {}, .Pool_Full
		}
		eval.list_items[first + i] = v
	}
	eval.list_item_count += right_count
	name_vm, nok := host_to_value(eval, arguments[0])
	if !nok {
		return {}, .Pool_Full
	}
	sidx := eval.store_count
	eval.stores[sidx] = {
		name       = name_vm,
		rights_off = u32(first),
		rights_len = u32(right_count),
	}
	eval.store_count += 1
	v := Value{kind = .Store_Ref, data = u64(sidx), meta = u32(right_count)}
	return value_to_host(eval, v), .None
}

// ---- Scale sizing for caller-carved Declaration_Workspace pools.

// Base scale-0 pool units; each scale doubles nodes and text arena.
DECLARATION_NODE_POOL :: 8192
DECLARATION_TEXT_ARENA :: 64 * 1024
DECLARATION_UNIT_TEXT_BYTES :: 64 * 1024
DECLARATION_SCALE_MOST :: 8
#assert(DECLARATION_UNIT_TEXT_BYTES << DECLARATION_SCALE_MOST == lex_parser.DECLARATION_TEXT_BYTES_MOST)
DECLARATION_BINDING_CAPACITY :: 32
// Inline capacity for plan_reader stack field buffers.
DECLARATION_RECORD_FIELDS_LIMIT :: 1024

// Caller-supplied pure loader for `import(path)` and `declaration(hash)`.
Declaration_Loader :: struct {
	data:      rawptr,
	load_path: proc "contextless" (data: rawptr, path: string) -> (source: string, found: bool),
	load_hash: proc "contextless" (data: rawptr, hash: blake3.Hash) -> (source: string, found: bool),
}

// One pre-bound top-level name for a declaration evaluation.
Declaration_Binding :: struct {
	name:    string,
	kind:    Declaration_Binding_Kind,
	integer: i64,
	boolean: bool,
	text:    string,
	hash:    blake3.Hash,
	source:  string,
}

Declaration_Binding_Kind :: enum u8 {
	Integer    = 0,
	Boolean    = 1,
	Text       = 2,
	Hash       = 3,
	Module_Ref = 4,
	Lex_Source = 5,
}

// Configuration for one declaration evaluation. Zero values pick defaults.
Declaration_Config :: struct {
	loader:          Declaration_Loader,
	bindings:        []Declaration_Binding,
	has_here:        bool,
	here_hash:       blake3.Hash,
	hash_seed:       u64, // Caller-supplied seed for zero-handle declaration_eval.
	budget:          u32, // 0 -> EVALUATION_BUDGET_STEPS
	depth_limit:     int, // 0 -> EVALUATION_DEPTH_LIMIT
	stack_bytes:     uint, // 0 -> EVALUATION_STACK_BYTES
	text_bytes_most: int, // 0 -> lex_parser.DECLARATION_TEXT_BYTES_MOST
	node_limit:      int, // 0 -> full carved node pool
	profile:         ^Evaluation_Profile,
}

// Result of evaluating a .lex declaration (and optionally forcing a field path).
Declaration_Result :: struct {
	ok:           bool,
	value:        Value,
	failure_kind: declaration_eval.Failure_Kind,
	line:         u32,
	column:       u32,
	offset:       u32,
	detail:       string,
	steps_taken:  u32,
}

// Cached state for one imported .lex file or declaration hash.
@(private)
Import_Entry :: struct {
	by_hash:    bool,
	path:       string,
	hash:       blake3.Hash,
	loading:    bool,
	loaded:     bool,
	chunk_id:   u16,
	root_value: Value,
}

Declaration_Pools :: struct {
	nodes:      int,
	text_bytes: int,
}

Declaration_Pool :: enum u8 {
	None,
	Nodes,
	Text,
}

// Compact caller-owned workspace handle (~10 KiB; zero static multi-MiB BSS
// arrays). All AST, bytecode, VM, and import pools are carved from caller
// memory via declaration_workspace_carve.
Declaration_Workspace :: struct {
	trees:               []lex_parser.Syntax_Tree,
	tree_count:          int,
	nodes:               []lex_parser.Ast_Node,
	extra_children:      []lex_parser.Node_Index,
	scratch_children:    []lex_parser.Node_Index,
	int_consts:          []i64,
	dup_controls:        []u8,
	dup_refs:            []u32,
	dup_keys:            []u64,
	dup_nodes:           []lex_parser.Node_Index,
	imports:             []Import_Entry,
	import_count:        int,
	exhausted:           Declaration_Pool,
	nodes_used:          int,
	extra_used:          int,
	int_consts_used:     int,
	node_limit:          int,
	vm_pools:            Eval_Pools,
	bindings:            [DECLARATION_BINDING_CAPACITY]Declaration_Binding,
	binding_values:      [DECLARATION_BINDING_CAPACITY]Value,
	binding_evaluated:   [DECLARATION_BINDING_CAPACITY]bool,
	binding_evaluating:  [DECLARATION_BINDING_CAPACITY]bool,
	binding_count:       int,
	loader:              Declaration_Loader,
	has_here:            bool,
	here_hash:           blake3.Hash,
	text_bytes_most:     int,
	parse_depth_limit:   int,
	host_failure_kind:   declaration_eval.Failure_Kind,
	host_failure_detail: string,
	host_failure_place:  lex_parser.Place,
	recipe_arguments:    [plans_recipes.MAX_RECIPE_ARGUMENT_VALUE_BYTES]u8,
	recipe_spec:         plans_recipes.Recipe_Spec,
	evaluation:          Evaluation,
}

declaration_pools_of_scale :: proc "contextless" (scale: uint) -> Declaration_Pools {
	return {nodes = DECLARATION_NODE_POOL << scale, text_bytes = DECLARATION_TEXT_ARENA << scale}
}

declaration_scale_of_text :: proc "contextless" (text_bytes: u64) -> uint {
	scale: uint = 0
	for scale < DECLARATION_SCALE_MOST && u64(DECLARATION_UNIT_TEXT_BYTES) << scale < text_bytes {
		scale += 1
	}
	return scale
}

declaration_scale_after :: proc "contextless" (ws: ^Declaration_Workspace, scale: uint) -> (next: uint, ok: bool) {
	switch ws.exhausted {
	case .None:
		return scale, false
	case .Nodes, .Text:
	}
	return scale + 1, scale < DECLARATION_SCALE_MOST
}

@(private = "file")
POOLS_ALIGNMENT :: 64

@(private = "file")
align_up :: #force_inline proc "contextless" (offset: int, size: int) -> int {
	return (offset + size + POOLS_ALIGNMENT - 1) &~ (POOLS_ALIGNMENT - 1)
}

@(private = "file")
Decl_Layout :: struct {
	nodes:            int,
	int_consts:       int,
	sym_cap:          int,
	sym_slots:        int,
	sym_bytes:        int,
	max_chunks:       int,
	max_code:         int,
	max_protos:       int,
	max_consts:       int,
	max_upvals:       int,
	max_let_descs:    int,
	max_let_protos:   int,
	max_rec_descs:    int,
	max_rec_fields:   int,
	max_sites:        int,
	max_site_args:    int,
	max_field_syms:   int,
	max_shapes:       int,
	max_shape_fields: int,
	max_regs:         int,
	max_frames:       int,
	max_thunks:       int,
	max_env_slots:    int,
	max_let_slots:    int,
	max_closures:     int,
	max_records:      int,
	max_rec_refs:     int,
	max_overlays:     int,
	max_list_items:   int,
	max_hashes:       int,
	max_recipes:      int,
	max_follows:      int,
	max_stores:       int,
	max_tagged:       int,
	max_host_objs:    int,
	text_bytes:       int,
}

@(private = "file")
compute_layout :: proc "contextless" (pools: Declaration_Pools) -> Decl_Layout {
	n := max(pools.nodes, 256)
	sym_cap := max(256, n / 2)
	sym_groups := hash_table.slice_index_groups_for_entries(sym_cap)
	return {
		nodes            = n,
		int_consts       = max(64, n / 8),
		sym_cap          = sym_cap,
		sym_slots        = sym_groups * hash_table.GROUP_WIDTH,
		sym_bytes        = max(8192, sym_cap * 16),
		max_chunks       = max(64, n / 128),
		max_code         = n * 4,
		max_protos       = max(512, n),
		max_consts       = max(512, n / 2),
		max_upvals       = max(1024, n),
		max_let_descs    = max(256, n / 16),
		max_let_protos   = max(512, n / 4),
		max_rec_descs    = max(256, n / 4),
		max_rec_fields   = max(1024, n),
		max_sites        = max(256, n / 8),
		max_site_args    = max(1024, n / 2),
		max_field_syms   = max(512, n / 2),
		max_shapes       = max(256, n / 4),
		max_shape_fields = max(1024, n),
		max_regs         = max(4096, EVALUATION_DEPTH_LIMIT * 4),
		max_frames       = EVALUATION_DEPTH_LIMIT + 16,
		max_thunks       = n * 2,
		max_env_slots    = n * 2,
		max_let_slots    = max(2048, n / 2),
		max_closures     = max(512, n / 4),
		max_records      = max(512, n / 4),
		max_rec_refs     = n * 2,
		max_overlays     = max(512, n / 8),
		max_list_items   = max(4096, n),
		max_hashes       = max(512, n / 16),
		max_recipes      = max(256, n / 32),
		max_follows      = max(128, n / 64),
		max_stores       = max(128, n / 64),
		max_tagged       = max(128, n / 64),
		max_host_objs    = max(256, n / 32),
		text_bytes       = max(pools.text_bytes, 4096),
	}
}

declaration_workspace_bytes :: proc "contextless" (pools: Declaration_Pools) -> int {
	l := compute_layout(pools)
	at := 0
	// Parser pools
	at = align_up(at, l.max_chunks * size_of(lex_parser.Syntax_Tree))
	at = align_up(at, l.nodes * size_of(lex_parser.Ast_Node))
	at = align_up(at, l.nodes * size_of(lex_parser.Node_Index)) // extra_children
	at = align_up(at, l.nodes * size_of(lex_parser.Node_Index)) // scratch_children
	at = align_up(at, l.int_consts * size_of(i64))
	at = align_up(at, l.sym_slots * size_of(u8))
	at = align_up(at, l.sym_slots * size_of(u32))
	at = align_up(at, l.sym_cap * size_of(u64))
	at = align_up(at, l.sym_cap * size_of(lex_parser.Node_Index))
	at = align_up(at, l.max_chunks * size_of(Import_Entry))
	// Interner
	at = align_up(at, l.sym_slots * size_of(u8))
	at = align_up(at, l.sym_slots * size_of(u32))
	at = align_up(at, (l.sym_cap + 1) * size_of(lex_parser.Sym_Span))
	at = align_up(at, l.sym_bytes)
	// Compiled bytecode pools
	at = align_up(at, l.max_chunks * size_of(Chunk))
	at = align_up(at, l.max_code * size_of(Instruction))
	at = align_up(at, l.max_code * size_of(lex_parser.Node_Index))
	at = align_up(at, l.max_protos * size_of(Proto))
	at = align_up(at, l.max_consts * size_of(Const_Entry))
	at = align_up(at, l.max_upvals * size_of(Upval_Desc))
	at = align_up(at, l.max_let_descs * size_of(Let_Desc))
	at = align_up(at, l.max_let_protos * size_of(u32))
	at = align_up(at, l.max_let_protos * size_of(lex_parser.Sym_Id))
	at = align_up(at, l.max_let_protos * size_of(lex_parser.Node_Index))
	at = align_up(at, l.max_rec_descs * size_of(Record_Desc))
	at = align_up(at, l.max_rec_fields * size_of(u32))
	at = align_up(at, l.max_rec_fields * size_of(lex_parser.Node_Index))
	at = align_up(at, l.max_rec_fields * size_of(u32))
	at = align_up(at, l.max_sites * size_of(Call_Site_Desc))
	at = align_up(at, l.max_site_args * size_of(Call_Site_Arg))
	at = align_up(at, l.max_field_syms * size_of(lex_parser.Sym_Id))
	at = align_up(at, l.max_shapes * size_of(Record_Shape))
	at = align_up(at, l.max_shape_fields * size_of(lex_parser.Sym_Id))
	// Compile scratch
	at = align_up(at, l.max_let_protos * size_of(Compile_Local))
	at = align_up(at, l.max_let_descs * size_of(Compile_Let_Scope))
	at = align_up(at, l.max_protos * size_of(Pending_Proto))
	at = align_up(at, l.max_upvals * size_of(Upval_Desc))
	at = align_up(at, l.max_rec_fields * size_of(Rec_Sort_Entry))
	// VM runtime pools
	at = align_up(at, l.max_regs * size_of(Value))
	at = align_up(at, l.max_frames * size_of(VM_Frame))
	at = align_up(at, l.max_thunks * size_of(Thunk))
	at = align_up(at, l.max_env_slots * size_of(Thunk_Ref))
	at = align_up(at, l.max_let_slots * size_of(Thunk_Ref))
	at = align_up(at, l.max_closures * size_of(Closure))
	at = align_up(at, l.max_records * size_of(Lazy_Record))
	at = align_up(at, l.max_rec_refs * size_of(Thunk_Ref))
	at = align_up(at, l.max_overlays * size_of(Record_Overlay))
	at = align_up(at, l.max_list_items * size_of(Value))
	at = align_up(at, l.max_list_items * size_of(Value))
	at = align_up(at, 256 * size_of(u32))
	at = align_up(at, l.max_hashes * size_of(blake3.Hash))
	at = align_up(at, l.max_recipes * size_of(Recipe_Value))
	at = align_up(at, l.max_follows * size_of(Follow_Value))
	at = align_up(at, l.max_stores * size_of(Store_Value))
	at = align_up(at, l.max_tagged * size_of(Value))
	at = align_up(at, l.max_host_objs * size_of(Host_Obj))
	at = align_up(at, l.text_bytes)
	return at
}

@(private = "file")
carve_slice :: proc "contextless" ($T: typeid, base: [^]u8, at: ^int, count: int) -> []T {
	out := ([^]T)(&base[at^])[:count]
	at^ = align_up(at^, count * size_of(T))
	return out
}

declaration_workspace_carve :: proc "contextless" (ws: ^Declaration_Workspace, memory: []u8, pools: Declaration_Pools) -> bool {
	if len(memory) < declaration_workspace_bytes(pools) || uintptr(raw_data(memory)) & (POOLS_ALIGNMENT - 1) != 0 {
		return false
	}
	l := compute_layout(pools)
	base := raw_data(memory)
	at := 0

	ws.trees = carve_slice(lex_parser.Syntax_Tree, base, &at, l.max_chunks)
	ws.nodes = carve_slice(lex_parser.Ast_Node, base, &at, l.nodes)
	ws.extra_children = carve_slice(lex_parser.Node_Index, base, &at, l.nodes)
	ws.scratch_children = carve_slice(lex_parser.Node_Index, base, &at, l.nodes)
	ws.int_consts = carve_slice(i64, base, &at, l.int_consts)
	ws.dup_controls = carve_slice(u8, base, &at, l.sym_slots)
	ws.dup_refs = carve_slice(u32, base, &at, l.sym_slots)
	ws.dup_keys = carve_slice(u64, base, &at, l.sym_cap)
	ws.dup_nodes = carve_slice(lex_parser.Node_Index, base, &at, l.sym_cap)
	ws.imports = carve_slice(Import_Entry, base, &at, l.max_chunks)

	ictrl := carve_slice(u8, base, &at, l.sym_slots)
	irefs := carve_slice(u32, base, &at, l.sym_slots)
	ispans := carve_slice(lex_parser.Sym_Span, base, &at, l.sym_cap + 1)
	ibytes := carve_slice(u8, base, &at, l.sym_bytes)
	interner, _ := lex_parser.interner_init(ictrl, irefs, ispans, ibytes, 0)

	ws.vm_pools = {
		chunks            = carve_slice(Chunk, base, &at, l.max_chunks),
		code              = carve_slice(Instruction, base, &at, l.max_code),
		code_nodes        = carve_slice(lex_parser.Node_Index, base, &at, l.max_code),
		protos            = carve_slice(Proto, base, &at, l.max_protos),
		consts            = carve_slice(Const_Entry, base, &at, l.max_consts),
		upvals            = carve_slice(Upval_Desc, base, &at, l.max_upvals),
		let_descs         = carve_slice(Let_Desc, base, &at, l.max_let_descs),
		let_protos        = carve_slice(u32, base, &at, l.max_let_protos),
		let_syms          = carve_slice(lex_parser.Sym_Id, base, &at, l.max_let_protos),
		let_nodes         = carve_slice(lex_parser.Node_Index, base, &at, l.max_let_protos),
		rec_descs         = carve_slice(Record_Desc, base, &at, l.max_rec_descs),
		rec_field_protos  = carve_slice(u32, base, &at, l.max_rec_fields),
		rec_field_nodes   = carve_slice(lex_parser.Node_Index, base, &at, l.max_rec_fields),
		rec_source_orders = carve_slice(u32, base, &at, l.max_rec_fields),
		call_sites        = carve_slice(Call_Site_Desc, base, &at, l.max_sites),
		site_args         = carve_slice(Call_Site_Arg, base, &at, l.max_site_args),
		field_syms        = carve_slice(lex_parser.Sym_Id, base, &at, l.max_field_syms),
		shapes            = carve_slice(Record_Shape, base, &at, l.max_shapes),
		shape_fields      = carve_slice(lex_parser.Sym_Id, base, &at, l.max_shape_fields),
		interner          = interner,
		compile_scratch   = {
			locals     = carve_slice(Compile_Local, base, &at, l.max_let_protos),
			let_scopes = carve_slice(Compile_Let_Scope, base, &at, l.max_let_descs),
			pending    = carve_slice(Pending_Proto, base, &at, l.max_protos),
			upval_work = carve_slice(Upval_Desc, base, &at, l.max_upvals),
			rec_sort   = carve_slice(Rec_Sort_Entry, base, &at, l.max_rec_fields),
		},
		reg_stack         = carve_slice(Value, base, &at, l.max_regs),
		frames            = carve_slice(VM_Frame, base, &at, l.max_frames),
		thunks            = carve_slice(Thunk, base, &at, l.max_thunks),
		env_slots         = carve_slice(Thunk_Ref, base, &at, l.max_env_slots),
		let_slots         = carve_slice(Thunk_Ref, base, &at, l.max_let_slots),
		closures          = carve_slice(Closure, base, &at, l.max_closures),
		records           = carve_slice(Lazy_Record, base, &at, l.max_records),
		record_thunk_refs = carve_slice(Thunk_Ref, base, &at, l.max_rec_refs),
		overlays          = carve_slice(Record_Overlay, base, &at, l.max_overlays),
		list_items        = carve_slice(Value, base, &at, l.max_list_items),
		list_scratch      = carve_slice(Value, base, &at, l.max_list_items),
		list_marks        = carve_slice(u32, base, &at, 256),
		hashes            = carve_slice(blake3.Hash, base, &at, l.max_hashes),
		recipes           = carve_slice(Recipe_Value, base, &at, l.max_recipes),
		follows           = carve_slice(Follow_Value, base, &at, l.max_follows),
		stores            = carve_slice(Store_Value, base, &at, l.max_stores),
		tagged_records    = carve_slice(Value, base, &at, l.max_tagged),
		host_objs         = carve_slice(Host_Obj, base, &at, l.max_host_objs),
		text_arena        = carve_slice(u8, base, &at, l.text_bytes),
	}
	return true
}

@(private)
decl_tree_storage :: proc "contextless" (ws: ^Declaration_Workspace) -> lex_parser.Tree_Storage {
	return {
		nodes            = ws.nodes[ws.nodes_used:ws.node_limit],
		extra_children   = ws.extra_children[ws.extra_used:],
		scratch_children = ws.scratch_children,
		int_consts       = ws.int_consts[ws.int_consts_used:],
		interner         = &ws.evaluation.interner,
		dup_controls     = ws.dup_controls,
		dup_refs         = ws.dup_refs,
		dup_keys         = ws.dup_keys,
		dup_nodes        = ws.dup_nodes,
	}
}

// bundle_loader returns a pure Declaration_Loader backed by a validated bundle.
bundle_loader :: proc "contextless" (bundle: ^[]u8) -> Declaration_Loader {
	return {
		data = bundle,
		load_path = proc "contextless" (data: rawptr, path: string) -> (string, bool) {
			b := (^[]u8)(data)^
			return declaration_eval.bundle_lookup_path(b, path)
		},
		load_hash = proc "contextless" (data: rawptr, hash: blake3.Hash) -> (string, bool) {
			b := (^[]u8)(data)^
			return declaration_eval.bundle_lookup_hash(b, hash)
		},
	}
}

// declaration_evaluate parses, compiles, and lazily evaluates `source` in mode
// `.Declaration`. When `field_path` is non-empty, only that dotted path and its
// transitive dependencies are forced.
declaration_evaluate :: proc "contextless" (ws: ^Declaration_Workspace, source: string, field_path: string = "", config: Declaration_Config = {}) -> (result: Declaration_Result) {
	ws.tree_count = 0
	ws.nodes_used = 0
	ws.extra_used = 0
	ws.int_consts_used = 0
	ws.node_limit = config.node_limit > 0 ? min(config.node_limit, len(ws.nodes)) : len(ws.nodes)
	ws.exhausted = .None
	ws.import_count = 0
	ws.loader = config.loader
	ws.has_here = config.has_here
	ws.here_hash = config.here_hash
	ws.text_bytes_most = config.text_bytes_most > 0 ? config.text_bytes_most : lex_parser.DECLARATION_TEXT_BYTES_MOST
	ws.parse_depth_limit = lex_parser.DECLARATION_PARSE_DEPTH_LIMIT
	ws.host_failure_kind = .None
	ws.host_failure_detail = ""
	ws.host_failure_place = {}
	ws.binding_count = min(len(config.bindings), DECLARATION_BINDING_CAPACITY)
	for i in 0 ..< ws.binding_count {
		ws.bindings[i] = config.bindings[i]
		ws.binding_values[i] = {}
		ws.binding_evaluated[i] = false
		ws.binding_evaluating[i] = false
	}

	lex_parser.interner_clear(&ws.vm_pools.interner)
	hash_table.slice_index_seed_set(&ws.vm_pools.interner.index, config.hash_seed)

	budget := config.budget > 0 ? config.budget : EVALUATION_BUDGET_STEPS
	depth_limit := config.depth_limit > 0 ? config.depth_limit : EVALUATION_DEPTH_LIMIT
	stack_bytes := config.stack_bytes > 0 ? config.stack_bytes : EVALUATION_STACK_BYTES

	if len(ws.trees) == 0 {
		return {failure_kind = .Pool_Exhausted, detail = "trees"}
	}

	host := Evaluation_Host {
		data            = ws,
		name_value      = decl_host_name_value,
		command_find    = decl_host_command_find,
		record_memory   = decl_host_record_memory,
		call_run        = decl_host_call_run,
		condition_value = decl_host_condition_value,
		fact_name_value = decl_host_fact_name_value,
		values_add      = decl_host_values_add,
	}
	evaluation_start_with_pools(&ws.evaluation, &ws.trees[0], .Declaration, host, ws.vm_pools, budget, stack_bytes, depth_limit)
	ws.evaluation.profile = config.profile

	// Parse root source into tree 0.
	lex_parser.parse_declaration(source, decl_tree_storage(ws), &ws.trees[0], ws.text_bytes_most, ws.parse_depth_limit)
	if ws.trees[0].refusal.refusal != .None {
		r := ws.trees[0].refusal
		if r.refusal == .Nodes_Full {
			ws.exhausted = .Nodes
		}
		return {
			ok           = false,
			failure_kind = parse_refusal_to_failure_kind(r.refusal),
			line         = r.place.line,
			column       = r.place.column,
			offset       = r.place.offset,
			detail       = lex_parser.node_text(&ws.trees[0], ws.trees[0].root),
		}
	}
	ws.tree_count = 1
	ws.nodes_used += ws.trees[0].node_count
	ws.extra_used += ws.trees[0].extra_count
	ws.int_consts_used += ws.trees[0].int_const_count

	root_val, root_ok := line_force_value(&ws.evaluation)
	if !root_ok {
		return decl_result_from_refusal(ws)
	}

	if len(field_path) == 0 {
		return {ok = true, value = root_val, steps_taken = ws.evaluation.steps}
	}

	selected, sel_ok := declaration_force_path(ws, root_val, field_path)
	if !sel_ok {
		return decl_result_from_refusal(ws)
	}
	return {ok = true, value = selected, steps_taken = ws.evaluation.steps}
}

// declaration_force_path lazily forces a dotted field path ("outputs.tools")
// on an already-evaluated declaration value without touching sibling fields.
declaration_force_path :: proc "contextless" (ws: ^Declaration_Workspace, root: Value, field_path: string) -> (value: Value, ok: bool) {
	current := root
	rest := field_path
	for len(rest) > 0 {
		dot := index_byte(rest, '.')
		segment := dot < 0 ? rest : rest[:dot]
		if len(segment) == 0 {
			decl_host_fail(ws, .Field_Unknown, field_path, {})
			return {}, false
		}
		current = field_force(&ws.evaluation, current, segment, 0, lex_parser.NO_NODE) or_return
		if dot < 0 {
			break
		}
		rest = rest[dot + 1:]
	}
	return current, true
}

// declaration_evaluate_to_buffer evaluates `source` (and optional `field_path`)
// and writes the canonical serialized output or typed refusal into `output`.
declaration_evaluate_to_buffer :: proc "contextless" (
	ws: ^Declaration_Workspace,
	source: string,
	field_path: string,
	config: Declaration_Config,
	output: []u8,
) -> (written: int, ok: bool) {
	res := declaration_evaluate(ws, source, field_path, config)
	if !res.ok {
		return declaration_eval.output_write_refusal(output, res.failure_kind, res.steps_taken, res.line, res.column, res.detail)
	}
	// Stage payload bytes after the 24-byte header, then patch header with final
	// steps_taken (including serialization step charges!).
	writer := declaration_eval.output_writer_start(output, {
		status       = .Ok,
		failure_kind = .None,
		steps_taken  = ws.evaluation.steps,
	})
	ser_err := serialize_value_into(ws, &writer, res.value, 0)
	if ser_err != .None {
		if ws.host_failure_kind != .None || refused(&ws.evaluation) {
			err_res := decl_result_from_refusal(ws)
			return declaration_eval.output_write_refusal(output, err_res.failure_kind, err_res.steps_taken, err_res.line, err_res.column, err_res.detail)
		}
		return declaration_eval.output_write_refusal(output, ser_err, ws.evaluation.steps, 0, 0, "")
	}
	if writer.overflow {
		return 0, false
	}
	// Update header steps_taken to include serialization steps.
	hdr := declaration_eval.output_writer_start(output[:declaration_eval.OUTPUT_HEADER_BYTES], {
		status       = .Ok,
		failure_kind = .None,
		steps_taken  = ws.evaluation.steps,
	})
	_ = hdr
	return writer.written, true
}

// declaration_serialize_value writes one canonical value into `output` without
// the output header.
declaration_serialize_value :: proc "contextless" (ws: ^Declaration_Workspace, value: Value, output: []u8) -> (written: int, failure: declaration_eval.Failure_Kind) {
	writer := declaration_eval.Output_Writer{buffer = output}
	failure = serialize_value_into(ws, &writer, value, 0)
	if failure != .None {
		return 0, failure
	}
	if writer.overflow {
		return 0, .Pool_Exhausted
	}
	return writer.written, .None
}

// ---- Step-charged canonical serialization (defeats exponential DAG DoS).

@(private)
serialize_value_into :: proc "contextless" (ws: ^Declaration_Workspace, writer: ^declaration_eval.Output_Writer, value: Value, depth: int) -> declaration_eval.Failure_Kind {
	if depth >= declaration_eval.OUTPUT_DEPTH_LIMIT {
		return .Depth_Bound_Reached
	}
	if !charge_steps(&ws.evaluation, 1, 0, lex_parser.NO_NODE) {
		return .Step_Bound_Reached
	}
	switch value.kind {
	case .Integer:
		declaration_eval.output_write_integer(writer, value_integer(value))
		return .None
	case .Boolean:
		declaration_eval.output_write_boolean(writer, value_boolean(value))
		return .None
	case .Text:
		txt := value_text(&ws.evaluation, value)
		if !charge_steps(&ws.evaluation, u32(len(txt) / 64), 0, lex_parser.NO_NODE) {
			return .Step_Bound_Reached
		}
		declaration_eval.output_write_text(writer, txt)
		return .None
	case .Hash:
		h, hok := hash_of(&ws.evaluation, value)
		if !hok {
			return .Unserializable_Value
		}
		declaration_eval.output_write_hash(writer, h)
		return .None
	case .Member:
		declaration_eval.output_write_member(writer, member_name_of(&ws.evaluation, value))
		return .None
	case .Module_Ref:
		h, hok := hash_of(&ws.evaluation, value)
		if !hok {
			return .Unserializable_Value
		}
		declaration_eval.output_write_module_ref(writer, h)
		return .None
	case .Tree_Ref:
		h, hok := hash_of(&ws.evaluation, value)
		if !hok {
			return .Unserializable_Value
		}
		declaration_eval.output_write_tree(writer, h)
		return .None
	case .Follow_Ref:
		h, hok := hash_of(&ws.evaluation, value)
		if !hok {
			return .Unserializable_Value
		}
		fname := value_follow_name(&ws.evaluation, value)
		if !charge_steps(&ws.evaluation, u32(len(fname) / 64), 0, lex_parser.NO_NODE) {
			return .Step_Bound_Reached
		}
		declaration_eval.output_write_follow_ref(writer, h, fname)
		return .None
	case .Store_Ref:
		sname := value_store_name(&ws.evaluation, value)
		rights := list_items_of(&ws.evaluation, value)
		declaration_eval.output_write_u8(writer, u8(declaration_eval.Value_Tag.Store_Ref))
		declaration_eval.output_write_string(writer, sname)
		declaration_eval.output_write_u32(writer, u32(len(rights)))
		for right in rights {
			if !charge_steps(&ws.evaluation, 1, 0, lex_parser.NO_NODE) {
				return .Step_Bound_Reached
			}
			declaration_eval.output_write_string(writer, member_name_of(&ws.evaluation, right))
		}
		return .None
	case .Recipe_Ref:
		idx := int(value.data)
		if idx < 0 || idx >= ws.evaluation.recipe_count {
			return .Unserializable_Value
		}
		rec := ws.evaluation.recipes[idx]
		declaration_eval.output_write_u8(writer, u8(declaration_eval.Value_Tag.Recipe_Ref))
		rh := rec.recipe_hash
		bh := rec.builder_hash
		declaration_eval.output_write_bytes(writer, rh[:])
		declaration_eval.output_write_bytes(writer, bh[:])
		return serialize_value_into(ws, writer, rec.arguments, depth + 1)
	case .List:
		items := list_items_of(&ws.evaluation, value)
		declaration_eval.output_write_u8(writer, u8(declaration_eval.Value_Tag.List))
		declaration_eval.output_write_u32(writer, u32(len(items)))
		for item in items {
			if err := serialize_value_into(ws, writer, item, depth + 1); err != .None {
				return err
			}
		}
		return .None
	case .Record_Literal, .Record_With:
		// Record_Shape fields are ALREADY sorted in strict ascending UTF-8 byte
		// order: zero runtime sorting, zero static field-count cap!
		shape_id, shape_ok := lazy_record_base_shape(&ws.evaluation, value)
		if !shape_ok {
			return .Unserializable_Value
		}
		shape := &ws.evaluation.shapes[shape_id]
		fcount := int(shape.field_count)
		declaration_eval.output_write_u8(writer, u8(declaration_eval.Value_Tag.Record))
		declaration_eval.output_write_u32(writer, u32(fcount))
		for i in 0 ..< fcount {
			sym := ws.evaluation.shape_fields[int(shape.fields_off) + i]
			fname := lex_parser.sym_text(&ws.evaluation.interner, sym)
			declaration_eval.output_write_string(writer, fname)
			tref, found := lazy_record_lookup_thunk(&ws.evaluation, value, sym)
			if !found {
				return .Field_Unknown
			}
			fval, fok := vm_force_thunk(&ws.evaluation, tref, 0, lex_parser.NO_NODE)
			if !fok {
				return decl_result_from_refusal(ws).failure_kind
			}
			if err := serialize_value_into(ws, writer, fval, depth + 1); err != .None {
				return err
			}
		}
		return .None
	case .Plan_Value:
		idx := int(value.data)
		if idx < 0 || idx >= ws.evaluation.tagged_record_count {
			return .Unserializable_Value
		}
		declaration_eval.output_write_u8(writer, u8(declaration_eval.Value_Tag.Plan))
		return serialize_value_into(ws, writer, ws.evaluation.tagged_records[idx], depth + 1)
	case .Project_Value:
		idx := int(value.data)
		if idx < 0 || idx >= ws.evaluation.tagged_record_count {
			return .Unserializable_Value
		}
		declaration_eval.output_write_u8(writer, u8(declaration_eval.Value_Tag.Project))
		return serialize_value_into(ws, writer, ws.evaluation.tagged_records[idx], depth + 1)
	case .None, .Record, .Handle, .Table, .Bytes, .Stream, .Record_Input, .Enum, .Function:
		return .Unserializable_Value
	}
	return .Unserializable_Value
}

// ---- Refusal classification helpers.

@(private)
parse_refusal_to_failure_kind :: proc "contextless" (r: lex_parser.Refusal) -> declaration_eval.Failure_Kind {
	switch r {
	case .None:
		return .None
	case .Nesting_Too_Deep:
		return .Depth_Bound_Reached
	case .Nodes_Full:
		return .Pool_Exhausted
	case .Text_Too_Long, .Line_Ends_Too_Soon, .Unexpected, .Number_Too_Large, .Text_Without_End_Quote, .Close_Parenthesis_Missing, .Comma_Or_Close_Missing, .Too_Many_Arguments, .Fact_Name_Missing, .Condition_Head_Refused, .Field_Name_Missing, .Literal_Close_Missing, .Literal_Name_Missing, .Literal_Equal_Missing, .Literal_Field_Twice, .Named_Argument_Twice, .Positional_After_Named, .Let_Name_Missing, .Let_Equal_Missing, .Let_In_Missing, .Let_Name_Twice, .Word_As_Name, .Parameter_Name_Missing, .Parameter_Twice, .Too_Many_Parameters, .List_Close_Missing, .Hash_Not_Valid, .If_Then_Missing, .If_Else_Missing, .Thin_Arrow, .Pipe_No_Left, .Pipe_Line_End, .Pipe_Not_A_Call, .Lone_Bar, .Placeholder_Not_Whole, .Placeholder_Twice, .Placeholder_Nested, .Placeholder_Without_Pipe:
		return .Parse_Error
	}
	return .Parse_Error
}

@(private)
decl_host_fail :: proc "contextless" (ws: ^Declaration_Workspace, kind: declaration_eval.Failure_Kind, detail: string, place: lex_parser.Place) {
	if ws.host_failure_kind == .None {
		ws.host_failure_kind = kind
		ws.host_failure_detail = detail
		ws.host_failure_place = place
	}
}

@(private)
decl_result_from_refusal :: proc "contextless" (ws: ^Declaration_Workspace) -> Declaration_Result {
	r := ws.evaluation.refusal
	if ws.host_failure_kind != .None {
		place := ws.host_failure_place.line != 0 ? ws.host_failure_place : r.place
		return {
			ok           = false,
			failure_kind = ws.host_failure_kind,
			line         = place.line,
			column       = place.column,
			offset       = place.offset,
			detail       = ws.host_failure_detail,
			steps_taken  = ws.evaluation.steps,
		}
	}
	kind := declaration_eval.Failure_Kind.Parse_Error
	detail := r.command
	switch r.refusal {
	case .None:
		kind = .None
	case .Text:
		kind = parse_refusal_to_failure_kind(r.text_refusal)
	case .Cycle:
		kind = .Cycle_Detected
	case .Budget_Exceeded:
		kind = .Step_Bound_Reached
	case .Depth_Exceeded:
		kind = .Depth_Bound_Reached
	case .Stack_Exceeded:
		kind = .Stack_Bound_Reached
	case .Effect_Refused:
		kind = .Effect_Refused
	case .Division_By_Zero:
		kind = .Division_By_Zero
	case .Overflow:
		kind = .Overflow
	case .Field_Unknown, .Literal_Field_Unknown:
		kind = .Field_Unknown
		detail = r.field
	case .Operator_Kinds, .Negate_Kind, .With_Kinds, .With_Records_Differ, .Not_A_Function, .Function_Arguments, .Not_A_List, .Condition_Not_Boolean, .Argument_Unknown, .Argument_Twice, .Argument_Missing, .Literal_No_Type, .Literal_Field_Missing, .Literal_Field_Kind, .Literal_Field_Range, .Member_No_Type, .Member_Unknown, .Value_At_Border, .List_Item_Kind:
		kind = .Type_Error
		if len(detail) == 0 {
			detail = r.field
		}
	case .Calls_Full, .Lists_Full, .With_Pairs_Full, .Imports_Full:
		kind = .Pool_Exhausted
		if ws.exhausted == .None {
			ws.exhausted = .Nodes
		}
	case .Host_Refused:
		kind = .Unknown_Name
	case .Assertion_Failed:
		kind = .Assertion_Failed
	}
	return {
		ok           = false,
		failure_kind = kind,
		line         = r.place.line,
		column       = r.place.column,
		offset       = r.place.offset,
		detail       = detail,
		steps_taken  = ws.evaluation.steps,
	}
}

// ---- Declaration host callbacks (pure, zero side effects).

@(private)
index_byte :: proc "contextless" (text: string, target: u8) -> int {
	for i in 0 ..< len(text) {
		if text[i] == target {
			return i
		}
	}
	return -1
}

@(private)
is_known_effect_command :: proc "contextless" (name: string) -> bool {
	switch name {
	case "shutdown", "reboot", "exit", "start", "stop", "load", "unload", "isolate", "replace", "connect", "grants", "revoke", "wire", "keep", "audit", "merge", "help", "describe":
		return true
	}
	if dot := index_byte(name, '.'); dot > 0 {
		switch name[:dot] {
		case "plans", "recipes", "projects", "collector", "storage", "log", "network", "manual", "settings", "compositor":
			return true
		}
	}
	return false
}

@(private)
decl_eval_binding :: proc "contextless" (ws: ^Declaration_Workspace, index: int) -> (Value, bool) {
	if ws.binding_evaluated[index] {
		return ws.binding_values[index], true
	}
	if ws.binding_evaluating[index] {
		decl_host_fail(ws, .Cycle_Detected, ws.bindings[index].name, {})
		return {}, false
	}
	ws.binding_evaluating[index] = true
	b := ws.bindings[index]
	val: Value
	ok := true
	switch b.kind {
	case .Integer:
		val = value_int(b.integer)
	case .Boolean:
		val = value_bool(b.boolean)
	case .Text:
		val, ok = text_arena_alloc(&ws.evaluation, b.text)
		if !ok {
			ws.exhausted = .Text
			decl_host_fail(ws, .Pool_Exhausted, b.name, {})
		}
	case .Hash:
		hidx, hok := hash_intern(&ws.evaluation, b.hash)
		if !hok {
			decl_host_fail(ws, .Pool_Exhausted, b.name, {})
			ok = false
		} else {
			val = {kind = .Hash, meta = hidx}
		}
	case .Module_Ref:
		hidx, hok := hash_intern(&ws.evaluation, b.hash)
		if !hok {
			decl_host_fail(ws, .Pool_Exhausted, b.name, {})
			ok = false
		} else {
			val = {kind = .Module_Ref, meta = hidx}
		}
	case .Lex_Source:
		val, ok = decl_load_source_into_chunk(ws, b.source)
	}
	ws.binding_evaluating[index] = false
	if !ok {
		return {}, false
	}
	ws.binding_values[index] = val
	ws.binding_evaluated[index] = true
	return val, true
}

@(private)
decl_host_name_value :: proc "contextless" (data: rawptr, name: string) -> (value: Host_Value, ok: bool) {
	ws := (^Declaration_Workspace)(data)
	for i in 0 ..< ws.binding_count {
		if ws.bindings[i].name == name {
			v := decl_eval_binding(ws, i) or_return
			return value_to_host(&ws.evaluation, v), true
		}
	}
	if dot := index_byte(name, '.'); dot > 0 {
		head := name[:dot]
		for i in 0 ..< ws.binding_count {
			if ws.bindings[i].name == head {
				base := decl_eval_binding(ws, i) or_return
				selected := declaration_force_path(ws, base, name[dot + 1:]) or_return
				return value_to_host(&ws.evaluation, selected), true
			}
		}
	}
	decl_host_fail(ws, .Unknown_Name, name, {})
	return {}, false
}

@(private)
decl_host_command_find :: proc "contextless" (data: rawptr, name: string) -> (signature: Command_Signature, found: bool) {
	ws := (^Declaration_Workspace)(data)
	switch name {
	case "module":
		signature = {parameter_count = 1, untyped = true}
		signature.names[0] = "hash"
		return signature, true
	case "here":
		signature = {parameter_count = 0, untyped = true}
		return signature, true
	case "follow":
		signature = {parameter_count = 2, untyped = true}
		signature.names[0], signature.names[1] = "publisher", "name"
		return signature, true
	case "store":
		signature = {parameter_count = 1, untyped = true}
		signature.names[0] = "name"
		return signature, true
	case "plan":
		signature = {parameter_count = 1, untyped = true}
		signature.names[0] = "record"
		return signature, true
	case "project":
		signature = {parameter_count = 1, untyped = true}
		signature.names[0] = "record"
		return signature, true
	case "recipe":
		signature = {parameter_count = 2, untyped = true}
		signature.names[0], signature.names[1] = "builder", "arguments"
		return signature, true
	case "import":
		signature = {parameter_count = 1, untyped = true}
		signature.names[0] = "path"
		return signature, true
	case "declaration":
		signature = {parameter_count = 1, untyped = true}
		signature.names[0] = "hash"
		return signature, true
	}
	// Dotted call into a pre-bound top-level binding (e.g. catalog.git.source).
	if dot := index_byte(name, '.'); dot > 0 {
		head := name[:dot]
		for i in 0 ..< ws.binding_count {
			if ws.bindings[i].name == head {
				hv, hok := decl_host_name_value(data, name)
				if !hok {
					return {}, false
				}
				fn_val := hv.vm_value
				if fn_val.kind != .Function {
					decl_host_fail(ws, .Type_Error, name, {})
					return {}, false
				}
				cl := ws.evaluation.closures[int(fn_val.data)]
				cchunk := &ws.evaluation.chunks[cl.chunk_id]
				cproto := &ws.evaluation.protos[int(cchunk.proto_start) + int(cl.proto_id)]
				signature = {parameter_count = int(cproto.param_count), untyped = true}
				for p in 0 ..< signature.parameter_count {
					signature.names[p] = lex_parser.sym_text(&ws.evaluation.interner, cproto.param_syms[p])
				}
				return signature, true
			}
		}
	}
	if is_known_effect_command(name) {
		return {has_effect = true}, true
	}
	decl_host_fail(ws, .Unknown_Command, name, {})
	return {}, false
}

@(private)
decl_host_record_memory :: proc "contextless" (data: rawptr, size: int) -> ([]u8, bool) {
	ws := (^Declaration_Workspace)(data)
	start := (ws.evaluation.text_used + 7) &~ 7
	if size > len(ws.evaluation.text_arena) - start {
		ws.exhausted = .Text
		decl_host_fail(ws, .Pool_Exhausted, "record memory", {})
		return nil, false
	}
	ws.evaluation.text_used = start + size
	out := ws.evaluation.text_arena[start:ws.evaluation.text_used]
	for &b in out {
		b = 0
	}
	return out, true
}

@(private)
decl_host_condition_value :: proc "contextless" (data: rawptr, evaluation: ^Evaluation, command_name: string, before: []Host_Value, node: lex_parser.Node_Index) -> (Host_Value, bool) {
	ws := (^Declaration_Workspace)(data)
	decl_host_fail(ws, .Effect_Refused, command_name, {})
	return {}, false
}

@(private)
decl_host_fact_name_value :: proc "contextless" (data: rawptr, evaluation: ^Evaluation, command_name: string, node: lex_parser.Node_Index) -> (Host_Value, bool) {
	ws := (^Declaration_Workspace)(data)
	decl_host_fail(ws, .Effect_Refused, command_name, {})
	return {}, false
}

@(private)
decl_host_values_add :: proc "contextless" (data: rawptr, left, right: Host_Value) -> (Host_Value, bool) {
	ws := (^Declaration_Workspace)(data)
	if left.kind != .Text || right.kind != .Text {
		decl_host_fail(ws, .Type_Error, "+", {})
		return {}, false
	}
	need := len(left.text) + len(right.text)
	if need > len(ws.evaluation.text_arena) - ws.evaluation.text_used {
		ws.exhausted = .Text
		decl_host_fail(ws, .Pool_Exhausted, "text arena", {})
		return {}, false
	}
	start := ws.evaluation.text_used
	copy(ws.evaluation.text_arena[start:], left.text)
	copy(ws.evaluation.text_arena[start + len(left.text):], right.text)
	ws.evaluation.text_used += need
	v := value_text_arena(u32(start), u32(need))
	return value_to_host(&ws.evaluation, v), true
}

@(private)
decl_host_call_run :: proc "contextless" (data: rawptr, name: string, arguments: []Host_Value) -> (value: Host_Value, ok: bool) {
	ws := (^Declaration_Workspace)(data)
	switch name {
	case "module":
		if len(arguments) != 1 || arguments[0].kind != .Hash {
			decl_host_fail(ws, .Type_Error, "module", {})
			return {}, false
		}
		v := Value{kind = .Module_Ref, meta = arguments[0].vm_value.meta}
		return value_to_host(&ws.evaluation, v), true

	case "here":
		if len(arguments) != 0 {
			decl_host_fail(ws, .Type_Error, "here", {})
			return {}, false
		}
		if !ws.has_here {
			decl_host_fail(ws, .Unknown_Name, "here", {})
			return {}, false
		}
		idx, iok := hash_intern(&ws.evaluation, ws.here_hash)
		if !iok {
			decl_host_fail(ws, .Pool_Exhausted, "here", {})
			return {}, false
		}
		return value_to_host(&ws.evaluation, {kind = .Tree_Ref, meta = idx}), true

	case "follow":
		if len(arguments) != 2 || arguments[0].kind != .Hash || arguments[1].kind != .Text {
			decl_host_fail(ws, .Type_Error, "follow", {})
			return {}, false
		}
		pub, pok := hash_of(&ws.evaluation, arguments[0].vm_value)
		if !pok || ws.evaluation.follow_count >= len(ws.evaluation.follows) {
			decl_host_fail(ws, .Pool_Exhausted, "follow", {})
			return {}, false
		}
		name_vm, nok := host_to_value(&ws.evaluation, arguments[1])
		if !nok {
			decl_host_fail(ws, .Pool_Exhausted, "follow", {})
			return {}, false
		}
		fidx := ws.evaluation.follow_count
		ws.evaluation.follows[fidx] = {publisher = pub, name = name_vm}
		ws.evaluation.follow_count += 1
		v := Value{kind = .Follow_Ref, data = u64(fidx), meta = arguments[0].vm_value.meta}
		return value_to_host(&ws.evaluation, v), true

	case "store":
		made, problem := store_ref_make(&ws.evaluation, arguments)
		switch problem {
		case .None:
			return made, true
		case .Not_A_Record:
			decl_host_fail(ws, .Type_Error, "store", {})
		case .Pool_Full:
			decl_host_fail(ws, .Pool_Exhausted, "store", {})
		}
		return {}, false

	case "plan":
		if len(arguments) != 1 {
			decl_host_fail(ws, .Type_Error, "plan", {})
			return {}, false
		}
		made, problem := plan_value_make(&ws.evaluation, arguments[0])
		switch problem {
		case .None:
			return made, true
		case .Not_A_Record:
			decl_host_fail(ws, .Type_Error, "plan", {})
		case .Pool_Full:
			decl_host_fail(ws, .Pool_Exhausted, "plan", {})
		}
		return {}, false

	case "project":
		if len(arguments) != 1 || !is_lazy_record(arguments[0].vm_value.kind) {
			decl_host_fail(ws, .Type_Error, "project", {})
			return {}, false
		}
		if ws.evaluation.tagged_record_count >= len(ws.evaluation.tagged_records) {
			decl_host_fail(ws, .Pool_Exhausted, "project", {})
			return {}, false
		}
		idx := ws.evaluation.tagged_record_count
		ws.evaluation.tagged_records[idx] = arguments[0].vm_value
		ws.evaluation.tagged_record_count += 1
		return value_to_host(&ws.evaluation, {kind = .Project_Value, data = u64(idx)}), true

	case "recipe":
		if len(arguments) != 2 {
			decl_host_fail(ws, .Type_Error, "recipe", {})
			return {}, false
		}
		builder_vm := arguments[0].vm_value
		builder_hash, builder_ok := hash_of(&ws.evaluation, builder_vm)
		if !builder_ok || builder_vm.kind != .Module_Ref {
			decl_host_fail(ws, .Type_Error, "recipe", {})
			return {}, false
		}
		if ws.evaluation.recipe_count >= len(ws.evaluation.recipes) {
			decl_host_fail(ws, .Pool_Exhausted, "recipe", {})
			return {}, false
		}
		args_vm, aok := host_to_value(&ws.evaluation, arguments[1])
		if !aok {
			decl_host_fail(ws, .Pool_Exhausted, "recipe", {})
			return {}, false
		}
		a_writer := declaration_eval.Output_Writer{buffer = ws.recipe_arguments[:]}
		ser_err := serialize_value_into(ws, &a_writer, args_vm, 0)
		if ser_err != .None {
			if !refused(&ws.evaluation) && ws.host_failure_kind == .None {
				decl_host_fail(ws, ser_err, "recipe", {})
			}
			return {}, false
		}
		if a_writer.overflow {
			decl_host_fail(ws, .Recipe_Refused, plans_recipes.recipe_refusal_words[.Arguments_Too_Large], {})
			return {}, false
		}
		if refusal := plans_recipes.recipe_spec_of_arguments(builder_hash, ws.recipe_arguments[:a_writer.written], &ws.recipe_spec); refusal != .None {
			decl_host_fail(ws, .Recipe_Refused, plans_recipes.recipe_refusal_words[refusal], {})
			return {}, false
		}
		recipe_hash, hash_refusal := plans_recipes.recipe_hash(&ws.recipe_spec)
		if hash_refusal != .None {
			decl_host_fail(ws, .Recipe_Refused, plans_recipes.recipe_refusal_words[hash_refusal], {})
			return {}, false
		}
		idx := ws.evaluation.recipe_count
		ws.evaluation.recipes[idx] = {
			recipe_hash  = recipe_hash,
			builder_hash = builder_hash,
			arguments    = args_vm,
		}
		ws.evaluation.recipe_count += 1
		return value_to_host(&ws.evaluation, {kind = .Recipe_Ref, data = u64(idx)}), true

	case "import":
		if len(arguments) != 1 || arguments[0].kind != .Text {
			decl_host_fail(ws, .Type_Error, "import", {})
			return {}, false
		}
		path := arguments[0].text
		if !declaration_eval.declaration_path_valid(path) {
			decl_host_fail(ws, .Import_Path_Refused, path, {})
			return {}, false
		}
		v := decl_import_path(ws, path) or_return
		return value_to_host(&ws.evaluation, v), true

	case "declaration":
		if len(arguments) != 1 || (arguments[0].kind != .Tree_Ref && arguments[0].kind != .Hash) {
			decl_host_fail(ws, .Type_Error, "declaration", {})
			return {}, false
		}
		target_hash, hash_ok := hash_of(&ws.evaluation, arguments[0].vm_value)
		if !hash_ok {
			decl_host_fail(ws, .Type_Error, "declaration", {})
			return {}, false
		}
		v := decl_import_hash(ws, target_hash) or_return
		return value_to_host(&ws.evaluation, v), true
	}

	// Dotted call into a pre-bound top-level binding (e.g. `catalog.odin.module("src")`).
	if dot := index_byte(name, '.'); dot > 0 {
		hv := decl_host_name_value(data, name) or_return
		fn_val := hv.vm_value
		if fn_val.kind != .Function {
			decl_host_fail(ws, .Type_Error, name, {})
			return {}, false
		}
		cl := ws.evaluation.closures[int(fn_val.data)]
		cchunk := &ws.evaluation.chunks[cl.chunk_id]
		cproto := &ws.evaluation.protos[int(cchunk.proto_start) + int(cl.proto_id)]
		if len(arguments) != int(cproto.param_count) {
			decl_host_fail(ws, .Type_Error, name, {})
			return {}, false
		}
		vm_args: [lex_parser.ARGUMENT_CAPACITY]Value
		for i in 0 ..< len(arguments) {
			v, vok := host_to_value(&ws.evaluation, arguments[i])
			if !vok {
				decl_host_fail(ws, .Pool_Exhausted, name, {})
				return {}, false
			}
			vm_args[i] = v
		}
		res := vm_exec_proto(&ws.evaluation, cl.chunk_id, cl.proto_id, cl.upval_off, cl.upval_len, vm_args[:len(arguments)], NO_THUNK, lex_parser.NO_NODE) or_return
		return value_to_host(&ws.evaluation, res), true
	}

	decl_host_fail(ws, .Unknown_Command, name, {})
	return {}, false
}

// ---- Lazy cross-file import / declaration loading with cycle detection.

@(private)
decl_import_path :: proc "contextless" (ws: ^Declaration_Workspace, path: string) -> (Value, bool) {
	for i in 0 ..< ws.import_count {
		entry := &ws.imports[i]
		if !entry.by_hash && entry.path == path {
			if entry.loading {
				decl_host_fail(ws, .Cycle_Detected, path, {})
				return {}, false
			}
			return entry.root_value, true
		}
	}
	if ws.loader.load_path == nil {
		decl_host_fail(ws, .Import_Not_Found, path, {})
		return {}, false
	}
	source, found := ws.loader.load_path(ws.loader.data, path)
	if !found {
		decl_host_fail(ws, .Import_Not_Found, path, {})
		return {}, false
	}
	if ws.import_count >= len(ws.imports) {
		ws.exhausted = .Nodes
		decl_host_fail(ws, .Pool_Exhausted, path, {})
		return {}, false
	}
	slot_idx := ws.import_count
	ws.import_count += 1
	ws.imports[slot_idx] = {by_hash = false, path = path, loading = true}
	val, eval_ok := decl_load_source_into_chunk(ws, source)
	ws.imports[slot_idx].loading = false
	if !eval_ok {
		return {}, false
	}
	ws.imports[slot_idx].loaded = true
	ws.imports[slot_idx].root_value = val
	return val, true
}

@(private)
decl_import_hash :: proc "contextless" (ws: ^Declaration_Workspace, hash: blake3.Hash) -> (Value, bool) {
	for i in 0 ..< ws.import_count {
		entry := &ws.imports[i]
		if entry.by_hash && entry.hash == hash {
			if entry.loading {
				decl_host_fail(ws, .Cycle_Detected, "declaration", {})
				return {}, false
			}
			return entry.root_value, true
		}
	}
	if ws.loader.load_hash == nil {
		decl_host_fail(ws, .Import_Not_Found, "declaration", {})
		return {}, false
	}
	source, found := ws.loader.load_hash(ws.loader.data, hash)
	if !found {
		decl_host_fail(ws, .Import_Not_Found, "declaration", {})
		return {}, false
	}
	if ws.import_count >= len(ws.imports) {
		ws.exhausted = .Nodes
		decl_host_fail(ws, .Pool_Exhausted, "declaration", {})
		return {}, false
	}
	slot_idx := ws.import_count
	ws.import_count += 1
	ws.imports[slot_idx] = {by_hash = true, hash = hash, loading = true}
	val, eval_ok := decl_load_source_into_chunk(ws, source)
	ws.imports[slot_idx].loading = false
	if !eval_ok {
		return {}, false
	}
	ws.imports[slot_idx].loaded = true
	ws.imports[slot_idx].root_value = val
	return val, true
}

@(private)
decl_load_source_into_chunk :: proc "contextless" (ws: ^Declaration_Workspace, source: string) -> (Value, bool) {
	if ws.tree_count >= len(ws.trees) {
		ws.exhausted = .Nodes
		decl_host_fail(ws, .Pool_Exhausted, "trees", {})
		return {}, false
	}
	tree_idx := ws.tree_count
	ws.tree_count += 1
	tree := &ws.trees[tree_idx]
	lex_parser.parse_declaration(source, decl_tree_storage(ws), tree, ws.text_bytes_most, ws.parse_depth_limit)
	if tree.refusal.refusal != .None {
		r := tree.refusal
		if r.refusal == .Nodes_Full {
			ws.exhausted = .Nodes
		}
		decl_host_fail(ws, parse_refusal_to_failure_kind(r.refusal), lex_parser.node_text(tree, tree.root), r.place)
		return {}, false
	}
	ws.nodes_used += tree.node_count
	ws.extra_used += tree.extra_count
	ws.int_consts_used += tree.int_const_count

	cid, comp_ok := compile_tree(&ws.evaluation, tree)
	if !comp_ok {
		ws.exhausted = .Nodes
		decl_host_fail(ws, .Pool_Exhausted, "bytecode", {})
		return {}, false
	}
	chunk := &ws.evaluation.chunks[cid]
	return vm_exec_proto(&ws.evaluation, cid, chunk.root_proto, 0, 0, nil, NO_THUNK, tree.root)
}
