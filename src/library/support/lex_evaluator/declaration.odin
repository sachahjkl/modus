// Pure lazy .lex declaration evaluator (src/md/features/declarations.md,
// "Mode `declaration` and the evaluation process").
//
// Evaluates multi-line .lex files lazily with zero side effects and zero I/O:
// referenced files (`import("path.lex")`) and declarations
// (`declaration(blake3:...)`) are supplied through a pure caller callback.
// The evaluator enforces strict step, recursion-depth, stack, and pool bounds
// across all imported files, detects direct, mutual, record-field and
// cross-file import cycles, and serializes forced results into the canonical
// contract format of modus:contract/declaration_eval.
package lex_evaluator

import "modus:contract/blake3"
import "modus:contract/declaration_eval"
import "modus:support/console_language"
import "modus:support/lex_parser"

DECLARATION_TREE_CAPACITY :: 16
DECLARATION_NODE_POOL :: 8192
DECLARATION_CALL_CAPACITY :: 1024
DECLARATION_CALL_THUNK_CAPACITY :: 4096
DECLARATION_LIST_ITEM_CAPACITY :: 2048
DECLARATION_HASH_CAPACITY :: 512
DECLARATION_WITH_PAIR_CAPACITY :: 512
DECLARATION_RECIPE_CAPACITY :: 256
DECLARATION_TAGGED_RECORD_CAPACITY :: 128
DECLARATION_TEXT_ARENA :: 64 * 1024
DECLARATION_BINDING_CAPACITY :: 32
DECLARATION_RECORD_FIELDS_LIMIT :: 128

// Caller-supplied pure loader for `import(path)` and `declaration(hash)`.
// Neither callback performs I/O inside the evaluator; in the sandboxed
// evaluation module they look up entries in the caller's read-only bundle.
Declaration_Loader :: struct {
	data:      rawptr,
	load_path: proc "contextless" (data: rawptr, path: string) -> (source: string, found: bool),
	load_hash: proc "contextless" (data: rawptr, hash: blake3.Hash) -> (source: string, found: bool),
}

// One pre-bound top-level name for a declaration evaluation (such as a
// catalog, keys table, or inputs record).
Declaration_Binding :: struct {
	name:     string,
	kind:     Declaration_Binding_Kind,
	integer:  i64,
	boolean:  bool,
	text:     string,
	hash:     blake3.Hash,
	source:   string, // For .Lex_Source: parsed and evaluated lazily on demand.
}

Declaration_Binding_Kind :: enum u8 {
	Integer    = 0,
	Boolean    = 1,
	Text       = 2,
	Hash       = 3,
	Module_Ref = 4,
	Lex_Source = 5,
}

// Configuration for one declaration evaluation. Zero values pick the defaults.
Declaration_Config :: struct {
	loader:          Declaration_Loader,
	bindings:        []Declaration_Binding,
	has_here:        bool,
	here_hash:       blake3.Hash,
	budget:          u32, // 0 -> EVALUATION_BUDGET_STEPS
	depth_limit:     int, // 0 -> EVALUATION_DEPTH_LIMIT
	stack_bytes:     uint, // 0 -> EVALUATION_STACK_BYTES
	text_bytes_most: int, // 0 -> lex_parser.DECLARATION_TEXT_BYTES_MOST
	node_limit:      int, // 0 -> DECLARATION_NODE_POOL
}

// Result of evaluating a .lex declaration (and optionally forcing one field path).
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
	tree_index: u16,
	root_value: Value,
}

// Caller-owned memory for one declaration evaluation. Holds no heap
// allocations and no global state.
Declaration_Workspace :: struct {
	trees:               [DECLARATION_TREE_CAPACITY]lex_parser.Syntax_Tree,
	tree_slots:          [DECLARATION_TREE_CAPACITY]Tree_Slot,
	nodes:               [DECLARATION_NODE_POOL]lex_parser.Node,
	thunks:              [DECLARATION_NODE_POOL]Thunk,
	slots:               [DECLARATION_NODE_POOL]i16,
	slot_counts:         [DECLARATION_NODE_POOL]u16,
	nodes_used:          int,
	node_limit:          int,
	calls:               [DECLARATION_CALL_CAPACITY + 1]Function_Call,
	call_thunks:         [DECLARATION_CALL_THUNK_CAPACITY]Thunk,
	list_items:          [DECLARATION_LIST_ITEM_CAPACITY]Value,
	hashes:              [DECLARATION_HASH_CAPACITY]blake3.Hash,
	with_pairs:          [DECLARATION_WITH_PAIR_CAPACITY]With_Pair,
	recipes:             [DECLARATION_RECIPE_CAPACITY]Recipe_Value,
	tagged_records:      [DECLARATION_TAGGED_RECORD_CAPACITY]Value,
	text_arena:          [DECLARATION_TEXT_ARENA]u8,
	text_used:           int,
	pipe_stages:         [console_language.PIPE_STAGE_CAPACITY]console_language.Pipe_Stage,
	imports:             [DECLARATION_TREE_CAPACITY]Import_Entry,
	import_count:        int,
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
	evaluation:          Evaluation,
}

// bundle_loader returns a pure Declaration_Loader backed by a validated
// read-only declaration_eval bundle slice. The slice pointer must stay valid
// for the duration of the evaluation.
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

// declaration_evaluate parses and lazily evaluates a .lex source in mode
// `declaration`. When field_path is non-empty (e.g. "outputs.tools"), only
// that dotted field path and its transitive dependencies are forced.
declaration_evaluate :: proc "contextless" (ws: ^Declaration_Workspace, source: string, field_path: string = "", config: Declaration_Config = {}) -> (result: Declaration_Result) {
	ws.nodes_used = 0
	ws.node_limit = config.node_limit > 0 ? min(config.node_limit, DECLARATION_NODE_POOL) : DECLARATION_NODE_POOL
	ws.text_used = 0
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
	for index in 0 ..< ws.binding_count {
		ws.bindings[index] = config.bindings[index]
		ws.binding_values[index] = {}
		ws.binding_evaluated[index] = false
		ws.binding_evaluating[index] = false
	}

	budget := config.budget > 0 ? config.budget : EVALUATION_BUDGET_STEPS
	depth_limit := config.depth_limit > 0 ? config.depth_limit : EVALUATION_DEPTH_LIMIT
	stack_bytes := config.stack_bytes > 0 ? config.stack_bytes : EVALUATION_STACK_BYTES

	// Desugar any |> in the root source.
	nested, pipe_ok := declaration_pipe_desugar(ws, source)
	if !pipe_ok {
		return {
			ok           = false,
			failure_kind = ws.host_failure_kind,
			line         = ws.host_failure_place.line,
			column       = ws.host_failure_place.column,
			offset       = ws.host_failure_place.offset,
			detail       = ws.host_failure_detail,
		}
	}

	// Parse root source into tree 0 using the workspace node pool.
	root_nodes := ws.nodes[ws.nodes_used:ws.node_limit]
	lex_parser.parse_declaration(nested, root_nodes, &ws.trees[0], ws.text_bytes_most, ws.parse_depth_limit)
	if ws.trees[0].refusal.refusal != .None {
		r := ws.trees[0].refusal
		return {
			ok           = false,
			failure_kind = parse_refusal_to_failure_kind(r.refusal),
			line         = r.place.line,
			column       = r.place.column,
			offset       = r.place.offset,
			detail       = lex_parser.node_text(&ws.trees[0], ws.trees[0].root),
		}
	}
	root_count := ws.trees[0].node_count
	ws.tree_slots[0] = {
		tree        = &ws.trees[0],
		thunks      = ws.thunks[ws.nodes_used:ws.nodes_used + root_count],
		slots       = ws.slots[ws.nodes_used:ws.nodes_used + root_count],
		slot_counts = ws.slot_counts[ws.nodes_used:ws.nodes_used + root_count],
	}
	ws.nodes_used += root_count

	pools := Evaluation_Pools {
		trees          = ws.tree_slots[:],
		calls          = ws.calls[:],
		call_thunks    = ws.call_thunks[:],
		list_items     = ws.list_items[:],
		hashes         = ws.hashes[:],
		with_pairs     = ws.with_pairs[:],
		recipes        = ws.recipes[:],
		tagged_records = ws.tagged_records[:],
		depth_limit    = depth_limit,
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
	evaluation_start_with_pools(&ws.evaluation, &ws.trees[0], .Declaration, host, pools, budget, stack_bytes)

	root_value, ok := line_force(&ws.evaluation)
	if !ok {
		return declaration_failure_result(ws)
	}
	current := root_value
	if len(field_path) > 0 {
		current, ok = declaration_force_path(ws, current, field_path)
		if !ok {
			return declaration_failure_result(ws)
		}
	}
	return {
		ok          = true,
		value       = current,
		steps_taken = ws.evaluation.steps,
	}
}

// declaration_force_path forces a dotted field path ("outputs.tools") on a
// lazy value, evaluating only the selected fields.
declaration_force_path :: proc "contextless" (ws: ^Declaration_Workspace, base: Value, field_path: string) -> (value: Value, ok: bool) {
	current := base
	rest := field_path
	for len(rest) > 0 {
		dot := -1
		for ch, i in rest {
			if ch == '.' {
				dot = i
				break
			}
		}
		segment := dot < 0 ? rest : rest[:dot]
		if len(segment) == 0 {
			decl_host_fail(ws, .Field_Unknown, field_path, {})
			return {}, false
		}
		current = field_force(&ws.evaluation, current, segment, {}, lex_parser.NO_NODE) or_return
		if dot < 0 {
			break
		}
		rest = rest[dot + 1:]
	}
	return current, true
}

// declaration_evaluate_to_buffer evaluates a .lex source, forces field_path,
// and writes either the canonical serialized value or a typed refusal into
// destination. Returns written byte count and ok = true when the output
// message fit in destination.
declaration_evaluate_to_buffer :: proc "contextless" (ws: ^Declaration_Workspace, source: string, field_path: string, config: Declaration_Config, destination: []u8) -> (written: int, ok: bool) {
	eval_result := declaration_evaluate(ws, source, field_path, config)
	if !eval_result.ok {
		return declaration_eval.output_write_refusal(destination, eval_result.failure_kind, eval_result.steps_taken, eval_result.line, eval_result.column, eval_result.detail)
	}
	ser_written, ser_fail := declaration_serialize_value(ws, eval_result.value, destination)
	if ser_fail != .None {
		if refused(&ws.evaluation) || ws.host_failure_kind != .None {
			failed_res := declaration_failure_result(ws)
			return declaration_eval.output_write_refusal(destination, failed_res.failure_kind, failed_res.steps_taken, failed_res.line, failed_res.column, failed_res.detail)
		}
		return declaration_eval.output_write_refusal(destination, ser_fail, ws.evaluation.steps, 0, 0, "")
	}
	return ser_written, true
}

// ---- Pipe desugaring and text arena.

@(private)
declaration_pipe_desugar :: proc "contextless" (ws: ^Declaration_Workspace, source: string) -> (nested: string, ok: bool) {
	room := ws.text_arena[ws.text_used:]
	form := console_language.pipe_nested_form(source, 0, room, ws.pipe_stages[:], true)
	if form.refusal != .None {
		place := lex_parser.place_of_offset(source, form.found_start)
		kind := declaration_eval.Failure_Kind.Parse_Error
		if form.refusal == .Too_Long && len(source) <= len(room) {
			// Output buffer had room, so placeholders_find hit its group nesting bound.
			kind = .Depth_Bound_Reached
		} else if form.refusal == .Too_Long || form.refusal == .Too_Many_Stages {
			kind = .Pool_Exhausted
		}
		decl_host_fail(ws, kind, "|>", place)
		return "", false
	}
	// If pipe_nested_form wrote into room, advance text_used.
	if len(form.nested) > 0 && len(room) > 0 && raw_data(form.nested) == raw_data(room) {
		ws.text_used += len(form.nested)
	}
	return form.nested, true
}

@(private)
decl_arena_append :: proc "contextless" (ws: ^Declaration_Workspace, a, b: string) -> (joined: string, ok: bool) {
	need := len(a) + len(b)
	if need > len(ws.text_arena) - ws.text_used {
		decl_host_fail(ws, .Pool_Exhausted, "text arena", {})
		return "", false
	}
	start := ws.text_used
	copy(ws.text_arena[start:], a)
	copy(ws.text_arena[start + len(a):], b)
	ws.text_used += need
	return string(ws.text_arena[start:ws.text_used]), true
}

// ---- Failure translation.

@(private)
decl_host_fail :: proc "contextless" (ws: ^Declaration_Workspace, kind: declaration_eval.Failure_Kind, detail: string, place: lex_parser.Place) {
	if ws.host_failure_kind == .None {
		ws.host_failure_kind = kind
		ws.host_failure_detail = detail
		ws.host_failure_place = place
	}
}

@(private)
parse_refusal_to_failure_kind :: proc "contextless" (r: lex_parser.Refusal) -> declaration_eval.Failure_Kind {
	switch r {
	case .None:
		return .None
	case .Nodes_Full:
		return .Pool_Exhausted
	case .Nesting_Too_Deep:
		return .Depth_Bound_Reached
	case .Text_Too_Long, .Line_Ends_Too_Soon, .Unexpected, .Number_Too_Large, .Text_Without_End_Quote, .Close_Parenthesis_Missing, .Comma_Or_Close_Missing, .Too_Many_Arguments, .Fact_Name_Missing, .Condition_Head_Refused, .Field_Name_Missing, .Literal_Close_Missing, .Literal_Name_Missing, .Literal_Equal_Missing, .Literal_Field_Twice, .Named_Argument_Twice, .Positional_After_Named, .Let_Name_Missing, .Let_Equal_Missing, .Let_In_Missing, .Let_Name_Twice, .Word_As_Name, .Parameter_Name_Missing, .Parameter_Twice, .Too_Many_Parameters, .List_Close_Missing, .Hash_Not_Valid, .If_Then_Missing, .If_Else_Missing:
		return .Parse_Error
	}
	return .Parse_Error
}

@(private)
declaration_failure_result :: proc "contextless" (ws: ^Declaration_Workspace) -> Declaration_Result {
	rec := ws.evaluation.refusal
	if rec.refusal == .Host_Refused && ws.host_failure_kind != .None {
		place := ws.host_failure_place.line != 0 ? ws.host_failure_place : rec.place
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
	kind := declaration_eval.Failure_Kind.Type_Error
	detail := rec.command != "" ? rec.command : rec.field
	switch rec.refusal {
	case .None:
		kind = ws.host_failure_kind
		detail = ws.host_failure_detail
	case .Text:
		kind = parse_refusal_to_failure_kind(rec.text_refusal)
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
	case .Field_Unknown:
		kind = .Field_Unknown
	case .Calls_Full, .Lists_Full, .With_Pairs_Full, .Imports_Full:
		kind = .Pool_Exhausted
	case .Host_Refused:
		kind = ws.host_failure_kind != .None ? ws.host_failure_kind : .Unknown_Name
		detail = ws.host_failure_detail
	case .Operator_Kinds, .Negate_Kind, .Literal_No_Type, .Literal_Field_Unknown, .Literal_Field_Missing, .Literal_Field_Kind, .Literal_Field_Range, .Argument_Unknown, .Argument_Twice, .Argument_Missing, .With_Kinds, .With_Records_Differ, .Member_No_Type, .Member_Unknown, .Not_A_Function, .Function_Arguments, .Value_At_Border, .Not_A_List, .List_Item_Kind, .Condition_Not_Boolean:
		kind = .Type_Error
	}
	return {
		ok           = false,
		failure_kind = kind,
		line         = rec.place.line,
		column       = rec.place.column,
		offset       = rec.place.offset,
		detail       = detail,
		steps_taken  = ws.evaluation.steps,
	}
}

// ---- Pure Declaration Evaluation Host.

// Known console/service commands that have side effects and must be refused
// with Effect_Refused at the border in mode `declaration`.
@(private)
is_known_effect_command :: proc "contextless" (name: string) -> bool {
	switch name {
	case "start", "stop", "shutdown", "connect", "load", "isolate", "isolate_memory", "allow", "revoke", "replace", "exit", "clear", "edit", "plans.apply", "plans.rollback", "plans.difference", "projects.update", "projects.enter", "projects.inputs", "recipes.build", "recipes.provenance", "settings.set":
		return true
	}
	return false
}

@(private)
decl_host_name_value :: proc "contextless" (data: rawptr, name: string) -> (value: Value, ok: bool) {
	ws := (^Declaration_Workspace)(data)
	// Split on first '.' so `catalog.odin` or `keys.gui_toolkit` resolves
	// top-level binding then lazily forces dotted fields!
	head := name
	tail := ""
	for ch, i in name {
		if ch == '.' {
			head = name[:i]
			tail = name[i + 1:]
			break
		}
	}
	found_idx := -1
	for i in 0 ..< ws.binding_count {
		if ws.bindings[i].name == head {
			found_idx = i
			break
		}
	}
	if found_idx < 0 {
		decl_host_fail(ws, .Unknown_Name, name, {})
		return {}, false
	}
	base, base_ok := decl_binding_force(ws, found_idx)
	if !base_ok {
		return {}, false
	}
	if len(tail) == 0 {
		return base, true
	}
	return declaration_force_path(ws, base, tail)
}

@(private)
decl_binding_force :: proc "contextless" (ws: ^Declaration_Workspace, index: int) -> (value: Value, ok: bool) {
	if ws.binding_evaluated[index] {
		return ws.binding_values[index], true
	}
	if ws.binding_evaluating[index] {
		decl_host_fail(ws, .Cycle_Detected, ws.bindings[index].name, {})
		return {}, false
	}
	ws.binding_evaluating[index] = true
	b := ws.bindings[index]
	result: Value
	switch b.kind {
	case .Integer:
		result = {kind = .Integer, integer = b.integer}
	case .Boolean:
		result = {kind = .Boolean, integer = b.boolean ? 1 : 0}
	case .Text:
		result = {kind = .Text, text = b.text}
	case .Hash:
		idx, intern_ok := hash_intern(&ws.evaluation, b.hash)
		if !intern_ok {
			ws.binding_evaluating[index] = false
			decl_host_fail(ws, .Pool_Exhausted, b.name, {})
			return {}, false
		}
		result = {kind = .Hash, detail = idx}
	case .Module_Ref:
		idx, intern_ok := hash_intern(&ws.evaluation, b.hash)
		if !intern_ok {
			ws.binding_evaluating[index] = false
			decl_host_fail(ws, .Pool_Exhausted, b.name, {})
			return {}, false
		}
		result = {kind = .Module_Ref, detail = idx}
	case .Lex_Source:
		loaded_val, loaded_ok := decl_load_source_into_tree(ws, b.source)
		if !loaded_ok {
			ws.binding_evaluating[index] = false
			return {}, false
		}
		result = loaded_val
	}
	ws.binding_evaluating[index] = false
	ws.binding_evaluated[index] = true
	ws.binding_values[index] = result
	return result, true
}

@(private)
decl_host_command_find :: proc "contextless" (data: rawptr, name: string) -> (signature: Command_Signature, found: bool) {
	ws := (^Declaration_Workspace)(data)
	switch name {
	case "module":
		signature = {has_effect = false, parameter_count = 1, untyped = true}
		signature.names[0] = "hash"
		return signature, true
	case "declaration":
		signature = {has_effect = false, parameter_count = 1, untyped = true}
		signature.names[0] = "hash"
		return signature, true
	case "import":
		signature = {has_effect = false, parameter_count = 1, untyped = true}
		signature.names[0] = "path"
		return signature, true
	case "recipe":
		signature = {has_effect = false, parameter_count = 2, untyped = true}
		signature.names[0], signature.names[1] = "builder", "arguments"
		return signature, true
	case "plan":
		signature = {has_effect = false, parameter_count = 1, untyped = true}
		signature.names[0] = "record"
		return signature, true
	case "project":
		signature = {has_effect = false, parameter_count = 1, untyped = true}
		signature.names[0] = "record"
		return signature, true
	case "follow":
		signature = {has_effect = false, parameter_count = 2, untyped = true}
		signature.names[0], signature.names[1] = "publisher", "name"
		return signature, true
	case "here":
		signature = {has_effect = false, parameter_count = 0, untyped = true}
		return signature, true
	case "store":
		// store(name, .Read, .Write, ...): up to 12 arguments.
		signature = {has_effect = false, parameter_count = 1, untyped = true}
		signature.names[0] = "name"
		return signature, true
	}
	// Dotted call on a pre-bound top-level binding (e.g. `catalog.odin.module(...)`
	// or `catalog.git.source(address = ..., branch = ...)`): resolve the target
	// function so its real parameter names and count apply to named arguments.
	if dot := index_byte(name, '.'); dot > 0 {
		head := name[:dot]
		for i in 0 ..< ws.binding_count {
			if ws.bindings[i].name == head {
				fn_val, fn_ok := decl_host_name_value(data, name)
				if !fn_ok {
					return {}, false
				}
				if fn_val.kind != .Function {
					decl_host_fail(ws, .Type_Error, name, {})
					return {}, false
				}
				fn_slot := active_slot(&ws.evaluation, fn_val.tree)
				fn_tree := fn_slot != nil ? fn_slot.tree : ws.evaluation.tree
				return function_signature(fn_tree, lex_parser.Node_Index(fn_val.integer)), true
			}
		}
	}
	if is_known_effect_command(name) {
		signature = {has_effect = true}
		return signature, true
	}
	decl_host_fail(ws, .Unknown_Command, name, {})
	return {}, false
}

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
decl_host_record_memory :: proc "contextless" (data: rawptr, size: int) -> (bytes: []u8, ok: bool) {
	ws := (^Declaration_Workspace)(data)
	start := (ws.text_used + 7) &~ 7
	if size > len(ws.text_arena) - start {
		decl_host_fail(ws, .Pool_Exhausted, "record memory", {})
		return nil, false
	}
	ws.text_used = start + size
	out := ws.text_arena[start:ws.text_used]
	for &b in out {
		b = 0
	}
	return out, true
}

@(private)
decl_host_condition_value :: proc "contextless" (data: rawptr, evaluation: ^Evaluation, command_name: string, before: []Value, node: lex_parser.Node_Index) -> (value: Value, ok: bool) {
	ws := (^Declaration_Workspace)(data)
	decl_host_fail(ws, .Effect_Refused, command_name, {})
	return {}, false
}

@(private)
decl_host_fact_name_value :: proc "contextless" (data: rawptr, evaluation: ^Evaluation, command_name: string, node: lex_parser.Node_Index) -> (value: Value, ok: bool) {
	ws := (^Declaration_Workspace)(data)
	decl_host_fail(ws, .Effect_Refused, command_name, {})
	return {}, false
}

@(private)
decl_host_values_add :: proc "contextless" (data: rawptr, left, right: Value) -> (sum: Value, ok: bool) {
	ws := (^Declaration_Workspace)(data)
	if left.kind != .Text || right.kind != .Text {
		decl_host_fail(ws, .Type_Error, "+", {})
		return {}, false
	}
	joined := decl_arena_append(ws, left.text, right.text) or_return
	return {kind = .Text, text = joined}, true
}

@(private)
decl_host_call_run :: proc "contextless" (data: rawptr, name: string, arguments: []Value) -> (value: Value, ok: bool) {
	ws := (^Declaration_Workspace)(data)
	switch name {
	case "module":
		if len(arguments) != 1 || arguments[0].kind != .Hash {
			decl_host_fail(ws, .Type_Error, "module", {})
			return {}, false
		}
		return {kind = .Module_Ref, detail = arguments[0].detail}, true

	case "here":
		if len(arguments) != 0 {
			decl_host_fail(ws, .Type_Error, "here", {})
			return {}, false
		}
		if !ws.has_here {
			decl_host_fail(ws, .Unknown_Name, "here", {})
			return {}, false
		}
		idx, intern_ok := hash_intern(&ws.evaluation, ws.here_hash)
		if !intern_ok {
			decl_host_fail(ws, .Pool_Exhausted, "here", {})
			return {}, false
		}
		return {kind = .Hash, detail = idx}, true

	case "follow":
		if len(arguments) != 2 || arguments[0].kind != .Hash || arguments[1].kind != .Text {
			decl_host_fail(ws, .Type_Error, "follow", {})
			return {}, false
		}
		return {kind = .Follow_Ref, detail = arguments[0].detail, text = arguments[1].text}, true

	case "store":
		if len(arguments) < 1 || arguments[0].kind != .Text {
			decl_host_fail(ws, .Type_Error, "store", {})
			return {}, false
		}
		right_count := len(arguments) - 1
		if right_count > len(ws.evaluation.active_list_items) - ws.evaluation.list_item_count {
			decl_host_fail(ws, .Pool_Exhausted, "store", {})
			return {}, false
		}
		first := ws.evaluation.list_item_count
		for i in 0 ..< right_count {
			right_arg := arguments[i + 1]
			if right_arg.kind != .Member {
				decl_host_fail(ws, .Type_Error, "store", {})
				return {}, false
			}
			ws.evaluation.active_list_items[first + i] = right_arg
		}
		ws.evaluation.list_item_count += right_count
		return {kind = .Store_Ref, text = arguments[0].text, integer = i64(first), detail = u32(right_count)}, true

	case "plan":
		if len(arguments) != 1 || !is_lazy_record(arguments[0].kind) {
			decl_host_fail(ws, .Type_Error, "plan", {})
			return {}, false
		}
		if ws.evaluation.tagged_record_count >= len(ws.evaluation.tagged_records) {
			decl_host_fail(ws, .Pool_Exhausted, "plan", {})
			return {}, false
		}
		idx := ws.evaluation.tagged_record_count
		ws.evaluation.tagged_records[idx] = arguments[0]
		ws.evaluation.tagged_record_count += 1
		return {kind = .Plan_Value, integer = i64(idx)}, true

	case "project":
		if len(arguments) != 1 || !is_lazy_record(arguments[0].kind) {
			decl_host_fail(ws, .Type_Error, "project", {})
			return {}, false
		}
		if ws.evaluation.tagged_record_count >= len(ws.evaluation.tagged_records) {
			decl_host_fail(ws, .Pool_Exhausted, "project", {})
			return {}, false
		}
		idx := ws.evaluation.tagged_record_count
		ws.evaluation.tagged_records[idx] = arguments[0]
		ws.evaluation.tagged_record_count += 1
		return {kind = .Project_Value, integer = i64(idx)}, true

	case "recipe":
		if len(arguments) != 2 {
			decl_host_fail(ws, .Type_Error, "recipe", {})
			return {}, false
		}
		builder_hash, builder_ok := hash_of(&ws.evaluation, arguments[0])
		if !builder_ok || (arguments[0].kind != .Hash && arguments[0].kind != .Module_Ref) {
			decl_host_fail(ws, .Type_Error, "recipe", {})
			return {}, false
		}
		if ws.evaluation.recipe_count >= len(ws.evaluation.recipes) {
			decl_host_fail(ws, .Pool_Exhausted, "recipe", {})
			return {}, false
		}
		// Compute a deterministic recipe hash over domain tag + builder hash +
		// canonical serialized arguments (forging nothing, running no build).
		hash_buf: [4096]u8
		h_writer := declaration_eval.Output_Writer{buffer = hash_buf[:]}
		declaration_eval.output_write_bytes(&h_writer, transmute([]u8)string("modus-recipe-v1:"))
		bh := builder_hash
		declaration_eval.output_write_bytes(&h_writer, bh[:])
		if ser_err := serialize_value_into(ws, &h_writer, arguments[1], 0); ser_err != .None || h_writer.overflow {
			if !refused(&ws.evaluation) && ws.host_failure_kind == .None {
				decl_host_fail(ws, ser_err != .None ? ser_err : .Pool_Exhausted, "recipe", {})
			}
			return {}, false
		}
		recipe_hash := blake3.hash(hash_buf[:h_writer.written])
		idx := ws.evaluation.recipe_count
		ws.evaluation.recipes[idx] = {
			recipe_hash  = recipe_hash,
			builder_hash = builder_hash,
			arguments    = arguments[1],
		}
		ws.evaluation.recipe_count += 1
		return {kind = .Recipe_Ref, integer = i64(idx)}, true

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
		return decl_import_path(ws, path)

	case "declaration":
		if len(arguments) != 1 || arguments[0].kind != .Hash {
			decl_host_fail(ws, .Type_Error, "declaration", {})
			return {}, false
		}
		target_hash, hash_ok := hash_of(&ws.evaluation, arguments[0])
		if !hash_ok {
			decl_host_fail(ws, .Type_Error, "declaration", {})
			return {}, false
		}
		return decl_import_hash(ws, target_hash)
	}

	// Dotted call into a top-level binding (e.g. `catalog.odin.module("src")`).
	if dot := index_byte(name, '.'); dot > 0 {
		fn_val, fn_ok := decl_host_name_value(data, name)
		if !fn_ok {
			return {}, false
		}
		if fn_val.kind != .Function {
			decl_host_fail(ws, .Type_Error, name, {})
			return {}, false
		}
		// Check arity of target function.
		fn_slot := active_slot(&ws.evaluation, fn_val.tree)
		fn_tree := fn_slot != nil ? fn_slot.tree : ws.evaluation.tree
		sig := function_signature(fn_tree, lex_parser.Node_Index(fn_val.integer))
		if len(arguments) != sig.parameter_count {
			decl_host_fail(ws, .Type_Error, name, {})
			return {}, false
		}
		dummy := lex_parser.Node{}
		return function_call(&ws.evaluation, lex_parser.NO_NODE, &dummy, fn_val, arguments)
	}

	decl_host_fail(ws, .Unknown_Command, name, {})
	return {}, false
}

// ---- Lazy cross-file import / declaration loading with cycle detection.

@(private)
decl_import_path :: proc "contextless" (ws: ^Declaration_Workspace, path: string) -> (value: Value, ok: bool) {
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
		decl_host_fail(ws, .Pool_Exhausted, path, {})
		return {}, false
	}
	slot_idx := ws.import_count
	ws.import_count += 1
	ws.imports[slot_idx] = {by_hash = false, path = path, loading = true}
	val, eval_ok := decl_load_source_into_tree(ws, source)
	ws.imports[slot_idx].loading = false
	if !eval_ok {
		return {}, false
	}
	ws.imports[slot_idx].loaded = true
	ws.imports[slot_idx].root_value = val
	return val, true
}

@(private)
decl_import_hash :: proc "contextless" (ws: ^Declaration_Workspace, hash: blake3.Hash) -> (value: Value, ok: bool) {
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
		decl_host_fail(ws, .Pool_Exhausted, "declaration", {})
		return {}, false
	}
	slot_idx := ws.import_count
	ws.import_count += 1
	ws.imports[slot_idx] = {by_hash = true, hash = hash, loading = true}
	val, eval_ok := decl_load_source_into_tree(ws, source)
	ws.imports[slot_idx].loading = false
	if !eval_ok {
		return {}, false
	}
	ws.imports[slot_idx].loaded = true
	ws.imports[slot_idx].root_value = val
	return val, true
}

@(private)
decl_load_source_into_tree :: proc "contextless" (ws: ^Declaration_Workspace, source: string) -> (value: Value, ok: bool) {
	if ws.evaluation.active_tree_count >= DECLARATION_TREE_CAPACITY {
		decl_host_fail(ws, .Pool_Exhausted, "imports", {})
		return {}, false
	}
	nested := declaration_pipe_desugar(ws, source) or_return
	tree_idx := ws.evaluation.active_tree_count
	available := ws.nodes[ws.nodes_used:ws.node_limit]
	lex_parser.parse_declaration(nested, available, &ws.trees[tree_idx], ws.text_bytes_most, ws.parse_depth_limit)
	if ws.trees[tree_idx].refusal.refusal != .None {
		r := ws.trees[tree_idx].refusal
		decl_host_fail(ws, parse_refusal_to_failure_kind(r.refusal), lex_parser.node_text(&ws.trees[tree_idx], ws.trees[tree_idx].root), r.place)
		return {}, false
	}
	count := ws.trees[tree_idx].node_count
	slot := Tree_Slot {
		tree        = &ws.trees[tree_idx],
		thunks      = ws.thunks[ws.nodes_used:ws.nodes_used + count],
		slots       = ws.slots[ws.nodes_used:ws.nodes_used + count],
		slot_counts = ws.slot_counts[ws.nodes_used:ws.nodes_used + count],
	}
	ws.nodes_used += count
	registered, reg_ok := evaluation_register_tree(&ws.evaluation, slot)
	if !reg_ok {
		decl_host_fail(ws, .Pool_Exhausted, "imports", {})
		return {}, false
	}
	return force_in_tree(&ws.evaluation, registered, ws.trees[tree_idx].root, NO_CALL)
}

// ---- Deterministic canonical serialization into modus:contract/declaration_eval.

// declaration_serialize_value serializes a forced declaration value into
// destination with deterministic sorted record keys.
declaration_serialize_value :: proc "contextless" (ws: ^Declaration_Workspace, value: Value, destination: []u8) -> (written: int, failure: declaration_eval.Failure_Kind) {
	writer := declaration_eval.output_writer_start(destination, {
		status       = .Ok,
		failure_kind = .None,
		steps_taken  = ws.evaluation.steps,
	})
	if err := serialize_value_into(ws, &writer, value, 0); err != .None {
		return 0, err
	}
	if writer.overflow {
		return 0, .Pool_Exhausted
	}
	// Update steps_taken in header after lazy sub-fields were forced during serialization.
	_ = declaration_eval.output_writer_start(destination[:declaration_eval.OUTPUT_HEADER_BYTES], {
		status       = .Ok,
		failure_kind = .None,
		steps_taken  = ws.evaluation.steps,
	})
	return writer.written, .None
}

// collect_lazy_record_fields collects all unique field names of a lazy record
// (Record_Literal or Record_With), then sorts them in strict ascending byte
// order for deterministic canonical encoding.
@(private)
collect_lazy_record_fields :: proc "contextless" (evaluation: ^Evaluation, value: Value, names: ^[DECLARATION_RECORD_FIELDS_LIMIT]string, count: ^int, depth: int) -> bool {
	if depth >= declaration_eval.OUTPUT_DEPTH_LIMIT {
		return false
	}
	switch value.kind {
	case .Record_Literal:
		slot := active_slot(evaluation, value.tree)
		if slot == nil || slot.tree == nil {
			return false
		}
		lit := lex_parser.node_at(slot.tree, lex_parser.Node_Index(value.integer))
		if lit == nil {
			return false
		}
		for field := lit.first_child; field != lex_parser.NO_NODE; field = lex_parser.next_of(slot.tree, field) {
			fn := lex_parser.node_at(slot.tree, field)
			if fn.kind != .Literal_Field {
				continue
			}
			fname := lex_parser.node_text(slot.tree, field)
			exists := false
			for existing in names[:count^] {
				if existing == fname {
					exists = true
					break
				}
			}
			if !exists {
				if count^ >= DECLARATION_RECORD_FIELDS_LIMIT {
					return false
				}
				names[count^] = fname
				count^ += 1
			}
		}
		return true
	case .Record_With:
		idx := int(value.integer)
		if idx < 0 || idx >= evaluation.with_pair_count {
			return false
		}
		pair := evaluation.with_pairs[idx]
		if !collect_lazy_record_fields(evaluation, pair.left, names, count, depth + 1) {
			return false
		}
		return collect_lazy_record_fields(evaluation, pair.right, names, count, depth + 1)
	case .Plan_Value, .Project_Value:
		idx := int(value.integer)
		if idx < 0 || idx >= evaluation.tagged_record_count {
			return false
		}
		return collect_lazy_record_fields(evaluation, evaluation.tagged_records[idx], names, count, depth + 1)
	case .None, .Integer, .Text, .Record, .Handle, .Table, .Bytes, .Stream, .Record_Input, .Enum, .Member, .Function, .List, .Hash, .Boolean, .Module_Ref, .Recipe_Ref, .Follow_Ref, .Store_Ref:
		return false
	}
	return false
}

// insertion_sort_names sorts field names in ascending lexicographical order.
@(private)
insertion_sort_names :: proc "contextless" (names: []string) {
	for i in 1 ..< len(names) {
		key := names[i]
		j := i - 1
		for j >= 0 && names[j] > key {
			names[j + 1] = names[j]
			j -= 1
		}
		names[j + 1] = key
	}
}

@(private)
serialize_value_into :: proc "contextless" (ws: ^Declaration_Workspace, writer: ^declaration_eval.Output_Writer, value: Value, depth: int) -> declaration_eval.Failure_Kind {
	if depth >= declaration_eval.OUTPUT_DEPTH_LIMIT {
		return .Depth_Bound_Reached
	}
	switch value.kind {
	case .Integer:
		declaration_eval.output_write_integer(writer, value.integer)
		return .None
	case .Boolean:
		declaration_eval.output_write_boolean(writer, value.integer != 0)
		return .None
	case .Text:
		declaration_eval.output_write_text(writer, value.text)
		return .None
	case .Hash:
		h, ok := hash_of(&ws.evaluation, value)
		if !ok {
			return .Unserializable_Value
		}
		declaration_eval.output_write_hash(writer, h)
		return .None
	case .Member:
		declaration_eval.output_write_member(writer, member_name_of(&ws.evaluation, value))
		return .None
	case .Module_Ref:
		h, ok := hash_of(&ws.evaluation, value)
		if !ok {
			return .Unserializable_Value
		}
		declaration_eval.output_write_module_ref(writer, h)
		return .None
	case .Recipe_Ref:
		idx := int(value.integer)
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
	case .Follow_Ref:
		pub, ok := hash_of(&ws.evaluation, value)
		if !ok {
			return .Unserializable_Value
		}
		declaration_eval.output_write_follow_ref(writer, pub, value.text)
		return .None
	case .Store_Ref:
		declaration_eval.output_write_u8(writer, u8(declaration_eval.Value_Tag.Store_Ref))
		declaration_eval.output_write_string(writer, value.text)
		rights := list_items_of(&ws.evaluation, value)
		declaration_eval.output_write_u32(writer, u32(len(rights)))
		for right in rights {
			declaration_eval.output_write_string(writer, member_name_of(&ws.evaluation, right))
		}
		return .None
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
		names: [DECLARATION_RECORD_FIELDS_LIMIT]string
		field_count := 0
		if !collect_lazy_record_fields(&ws.evaluation, value, &names, &field_count, 0) {
			return .Pool_Exhausted
		}
		insertion_sort_names(names[:field_count])
		declaration_eval.output_write_u8(writer, u8(declaration_eval.Value_Tag.Record))
		declaration_eval.output_write_u32(writer, u32(field_count))
		for fname in names[:field_count] {
			declaration_eval.output_write_string(writer, fname)
			field_val, ok := field_force(&ws.evaluation, value, fname, {}, lex_parser.NO_NODE)
			if !ok {
				return declaration_failure_result(ws).failure_kind
			}
			if err := serialize_value_into(ws, writer, field_val, depth + 1); err != .None {
				return err
			}
		}
		return .None
	case .Plan_Value:
		idx := int(value.integer)
		if idx < 0 || idx >= ws.evaluation.tagged_record_count {
			return .Unserializable_Value
		}
		declaration_eval.output_write_u8(writer, u8(declaration_eval.Value_Tag.Plan))
		return serialize_value_into(ws, writer, ws.evaluation.tagged_records[idx], depth + 1)
	case .Project_Value:
		idx := int(value.integer)
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
