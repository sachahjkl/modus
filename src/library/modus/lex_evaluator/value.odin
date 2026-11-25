// Compact 16-byte VM values, 24-byte tagged-union thunks, sorted UTF-8 record
// shapes, console host-border values, and deterministic evaluation profiling
// (src/md/features/declarations.md, "Lex v2 engine").
package lex_evaluator

import "modus:console_condition"
import "modus:console_language"
import "modus:contract/blake3"
import module "modus:contract/module"
import "modus:contract/value_kinds"
import "modus:hash_table"
import "modus:lex_parser"

// Evaluation step budget shared by both modes. Every VM instruction, thunk
// force, bulk string/list op, overlay compaction, structural comparison, and
// canonical serialization node/element/64-byte chunk charges against it.
EVALUATION_BUDGET_STEPS :: 1 << 25

// Default maximum VM frame depth (calls + thunk forces). Arena-backed, zero
// C-stack growth per call/force.
EVALUATION_DEPTH_LIMIT :: 4096

// Console thread stack budget constant retained for console module page budget
// calculation (the VM itself uses flat arena-backed frames, not C recursion).
EVALUATION_STACK_BYTES :: 512 * 1024

// Inline capacities for one console line (Console_Eval_Buffers).
LIST_ITEM_CAPACITY :: 4096
HASH_CAPACITY :: 64 + lex_parser.TEXT_BYTES_MOST / 71
TAGGED_RECORD_CAPACITY :: 4
LITERAL_FIELD_CAPACITY :: module.RECORD_SIZE_LIMIT / 4

// Built-in pure function names handled directly by the evaluator (collision-free
// with all console commands).
MAP_NAME :: "map"
FILTER_NAME :: "filter"
FOLD_NAME :: "fold"
ZIP_NAME :: "zip"
FIELDS_NAME :: "fields"
VALUES_NAME :: "values"
HAS_NAME :: "has"
EXTEND_NAME :: "extend"
MERGE_DEEP_NAME :: "merge_deep"
ASSERT_NAME :: "assert"
TRACE_NAME :: "trace"
FROM_ENTRIES_NAME :: "from_entries"
LEN_NAME :: "len"
AT_NAME :: "at"
SLICE_NAME :: "slice"
ANY_NAME :: "any"
ALL_NAME :: "all"
FLAT_MAP_NAME :: "flat_map"
UNIQUE_NAME :: "unique"
SORT_BY_NAME :: "sort_by"
SPLIT_NAME :: "split"
JOIN_TEXT_NAME :: "join_text"
STARTS_WITH_NAME :: "starts_with"
ENDS_WITH_NAME :: "ends_with"
CONTAINS_NAME :: "contains"
REPLACE_TEXT_NAME :: "replace_text"

// Recursive depth bound for `merge_deep(a, b)` (Plan value: 64 nested record
// levels exceeds real declarations while preventing unbounded nesting).
MERGE_DEEP_DEPTH_LIMIT :: 64

// Maximum force/call frames captured in a diagnostic stack trace.
DIAGNOSTIC_FRAME_LIMIT :: 32

// Bounded trace entry ring for `trace(msg, value)` (Plan value: zero I/O,
// drops excess entries with a counter when full).
TRACE_LOG_CAPACITY :: 64

Trace_Entry :: struct {
	place:   lex_parser.Place,
	message: string,
}

Trace_Log :: struct {
	entries: [TRACE_LOG_CAPACITY]Trace_Entry,
	count:   int,
	dropped: u32,
}

// One frame in a diagnostic force/call stack captured on refusal.
Diagnostic_Frame :: struct {
	chunk_id: u16,
	node:     lex_parser.Node_Index,
	place:    lex_parser.Place,
}

// Evaluation mode: console forces lines eagerly and permits host effects;
// declaration evaluates lazily and refuses all effects.
Evaluation_Mode :: enum u8 {
	Console     = 0,
	Declaration = 1,
}

// Kinds of values in Lex. Values 0..6 and 10 match module.Type for console
// host borders.
Kind :: enum u8 {
	None           = 0,
	Integer        = 1,
	Text           = 2,
	Record         = 3,
	Handle         = 4,
	Table          = 5,
	Bytes          = 6,
	Stream         = 7,
	Record_Input   = 8,
	Record_Literal = 9,
	Enum           = 10,
	Member         = 11,
	Function       = 12,
	List           = 13,
	Hash           = 14,
	Boolean        = 15,
	Record_With    = 16,
	Module_Ref     = 17,
	Recipe_Ref     = 18,
	Follow_Ref     = 19,
	Store_Ref      = 20,
	Plan_Value     = 21,
	Project_Value  = 22,
	Tree_Ref       = 23,
}

// Backing storage tag in Value.flags for .Text values.
Text_Storage :: enum u8 {
	Empty  = 0,
	Source = 1, // aux = chunk_id, data = span_off, meta = span_len
	Arena  = 2, // data = arena_off, meta = byte_len
	Sym    = 3, // meta = u32(Sym_Id)
	Host   = 4, // data = host_obj_idx
}

// Compact 16-byte VM value. Unboxed integers, booleans, source/arena strings,
// lists, closures, lazy records, overlays, hashes, and handles fit with zero
// per-value heap allocation. Console-only host payloads (module records,
// tables, bytes, streams, conditions) live in the cold Host_Obj pool.
Value :: struct {
	kind:  Kind,
	flags: u8,
	aux:   u16,
	meta:  u32,
	data:  u64,
}
#assert(size_of(Value) == 16)

// Index into the VM's flat Thunk pool.
Thunk_Ref :: distinct u32
NO_THUNK :: Thunk_Ref(~u32(0))

// Thunk lifecycle state.
Thunk_State :: enum u8 {
	Unforced = 0,
	Forced   = 1,
	Forcing  = 2,
}

// Flag in Thunk_Code.flags when the last captured env slot holds the single
// forced argument for a lazy 1-parameter comprehension thunk.
THUNK_FLAG_ONE_ARG :: u16(1 << 0)

// Unforced thunk payload: compiled thunk proto + captured lexical environment.
Thunk_Code :: struct {
	chunk_id: u16,
	flags:    u16,
	proto_id: u32,
	env_off:  u32,
	env_len:  u32,
}
#assert(size_of(Thunk_Code) == 16)

// Overlapping 16-byte union: holds Thunk_Code while Unforced/Forcing, then
// overwritten in place by the forced 16-byte Value when Forced.
Thunk_Payload :: struct #raw_union {
	code:  Thunk_Code,
	value: Value,
}
#assert(size_of(Thunk_Payload) == 16)

// Compact 24-byte tagged-union thunk.
Thunk :: struct {
	state:   Thunk_State,
	flags:   u8,
	pad:     u16,
	site_id: u32, // AST node index in chunk (for cycle/error diagnostics).
	payload: Thunk_Payload,
}
#assert(size_of(Thunk) == 24)

// Closure value allocated in VM.closures.
Closure :: struct {
	chunk_id:  u16,
	upval_len: u16,
	proto_id:  u32,
	upval_off: u32,
}

// Canonical UTF-8 byte-order sorted record shape. Every record literal compiles
// its field names in ascending UTF-8 byte order into a Record_Shape so lookups
// are O(log F) binary search (<=16 fields) or O(1) Slice_Hash_Index (>16 fields)
// and canonical serialization needs zero runtime sorting.
Record_Shape :: struct {
	fields_off:  u32, // Slice into shape_fields[fields_off : fields_off + field_count].
	field_count: u32,
	hash_index:  hash_table.Slice_Hash_Index(u32),
	has_index:   bool,
	shape_hash:  u64,
}

// Instantiated lazy record holding per-field Thunk_Refs in canonical shape order.
Lazy_Record :: struct {
	shape_id:   u32,
	refs_off:   u32, // Slice into record_thunk_refs[refs_off : refs_off + shape.field_count].
	chunk_id:   u16,
	flags:      u16,
	node_idx:   lex_parser.Node_Index, // Originating Record_Literal AST node (for console diagnostics).
	desc_id:    u32, // Originating Record_Desc (for source-order field traversal in console mode).
}

// Lazy `base with patch` overlay. Strictly override-only: every field in
// patch_rec exists in base_shape_id, so the resulting field set equals
// base_shape_id without walking overlays.
Record_Overlay :: struct {
	base:          Value,
	base_shape_id: u32,
	patch_rec:     u32, // Index into VM.records.
	depth:         u16,
	flags:         u16,
}

// Lazy `recipe(builder, arguments)` value.
Recipe_Value :: struct {
	recipe_hash:  blake3.Hash,
	builder_hash: blake3.Hash,
	arguments:    Value,
}

// `follow(publisher, name)` value.
Follow_Value :: struct {
	publisher: blake3.Hash,
	name:      Value, // .Text VM value.
}

// `store(name, rights...)` value.
Store_Value :: struct {
	name:       Value, // .Text VM value.
	rights_off: u32,
	rights_len: u32,
}

// Cold host-only payload for console values (Record, Table, Bytes, Stream,
// Record_Input, Enum, Condition, host Text). Never allocated in pure
// declaration evaluation.
Host_Obj :: struct {
	record:    []u8,
	file:      []u8,
	text:      string,
	condition: ^console_condition.Condition,
	detail:    u32,
	integer:   i64,
}

// Wide border value exchanged with Evaluation_Host callbacks (console commands,
// variables, tables, conditions). Inside the VM itself, every register, thunk,
// list item, and record field is the 16-byte Value.
Host_Value :: struct {
	kind:         Kind,
	integer:      i64,
	integer_unit: value_kinds.Integer_Unit,
	text:         string,
	record:       []u8,
	file:         []u8,
	detail:       u32,
	condition:    ^console_condition.Condition,
	vm_value:     Value,
}

// Why an evaluation stopped.
Refusal :: enum u8 {
	None                      = 0,
	Text                      = 1,
	Operator_Kinds            = 2,
	Negate_Kind               = 3,
	Overflow                  = 4,
	Division_By_Zero          = 5,
	Budget_Exceeded           = 6,
	Effect_Refused            = 7,
	Host_Refused              = 8,
	Literal_No_Type           = 9,
	Literal_Field_Unknown     = 10,
	Literal_Field_Missing     = 11,
	Literal_Field_Kind        = 12,
	Literal_Field_Range       = 13,
	Argument_Unknown          = 14,
	Argument_Twice            = 15,
	Argument_Missing          = 16,
	With_Kinds                = 17,
	With_Records_Differ       = 18,
	Field_Unknown             = 19,
	Cycle                     = 20,
	Member_No_Type            = 21,
	Member_Unknown            = 22,
	Not_A_Function            = 23,
	Function_Arguments        = 24,
	Value_At_Border           = 25,
	Stack_Exceeded            = 26,
	Calls_Full                = 27,
	Lists_Full                = 28,
	Not_A_List                = 29,
	List_Item_Kind            = 30,
	Condition_Not_Boolean     = 31,
	Depth_Exceeded            = 32,
	With_Pairs_Full           = 33,
	Imports_Full              = 34,
	Assertion_Failed          = 35,
	Interpolation_Kind        = 36,
	Pattern_Not_A_Record      = 37,
	Pattern_Extra_Field       = 38,
	Unit_Mismatch             = 39,
	Literal_Path_Outside_With = 40,
	Duplicate_Field           = 41,
	Field_Name_Invalid        = 42,
	No_Matching_Arm           = 43,
	Coalesce_Not_Field_Access = 44,
	Index_Out_Of_Bounds       = 45,
	Parameter_Kind            = 46,
	Empty_Separator           = 47,
}

// First refusal of an evaluation, with exact diagnostic fields, byte span,
// force/call frame stack, and OSA nearest-name suggestions.
Refusal_Record :: struct {
	refusal:          Refusal,
	place:            lex_parser.Place,
	span_start:       u32,
	span_end:         u32,
	node:             lex_parser.Node_Index,
	chunk_id:         u16,
	operator:         lex_parser.Operator,
	left_kind:        Kind,
	right_kind:       Kind,
	left_unit:        value_kinds.Integer_Unit,
	right_unit:       value_kinds.Integer_Unit,
	expected_annot:   lex_parser.Param_Kind_Annot,
	left:             i64,
	right:            i64,
	text_refusal:     lex_parser.Refusal,
	command:          string,
	steps:            u32,
	parameter:        int,
	field:            string,
	field_item:       module.Field,
	file:             []u8,
	detail:           u32,
	other_file:       []u8,
	other_detail:     u32,
	frames:           [DIAGNOSTIC_FRAME_LIMIT]Diagnostic_Frame,
	frame_count:      int,
	suggestions:      [console_language.NEAREST_NAME_CAPACITY]string,
	suggestion_count: int,
}

// Command signature reported by the host before arguments run.
Command_Signature :: struct {
	has_effect:          bool,
	parameter_count:     int,
	optional_last:       bool,
	optional:            [lex_parser.ARGUMENT_CAPACITY]bool,
	empty_record_zeroed: [lex_parser.ARGUMENT_CAPACITY]bool,
	names:               [lex_parser.ARGUMENT_CAPACITY]string,
	kinds:               [lex_parser.ARGUMENT_CAPACITY]Kind,
	files:               [lex_parser.ARGUMENT_CAPACITY][]u8,
	details:             [lex_parser.ARGUMENT_CAPACITY]u32,
	untyped:             bool,
}

// Host callbacks for console mode and declaration loader hooks.
Evaluation_Host :: struct {
	data:            rawptr,
	name_value:      proc "contextless" (data: rawptr, name: string) -> (value: Host_Value, ok: bool),
	command_find:    proc "contextless" (data: rawptr, name: string) -> (signature: Command_Signature, found: bool),
	record_memory:   proc "contextless" (data: rawptr, size: int) -> (bytes: []u8, ok: bool),
	call_run:        proc "contextless" (data: rawptr, name: string, arguments: []Host_Value) -> (value: Host_Value, ok: bool),
	condition_value: proc "contextless" (data: rawptr, evaluation: ^Evaluation, command_name: string, before: []Host_Value, node: lex_parser.Node_Index) -> (value: Host_Value, ok: bool),
	fact_name_value: proc "contextless" (data: rawptr, evaluation: ^Evaluation, command_name: string, node: lex_parser.Node_Index) -> (value: Host_Value, ok: bool),
	values_add:      proc "contextless" (data: rawptr, left, right: Host_Value) -> (sum: Host_Value, ok: bool),
}

// Deterministic VM profiling counters (zero wall-clock reads; nil = off).
Evaluation_Profile :: struct {
	opcode_counts:         [len(Opcode)]u64,
	steps_total:           u64,
	thunks_created:        u64,
	thunks_forced:         u64,
	thunks_reused:         u64,
	calls_total:           u64,
	tail_calls_total:      u64,
	max_frame_depth:       u32,
	max_reg_depth:         u32,
	overlay_compacts:      u64,
	shape_indices_built:   u64,
	shape_index_fallbacks: u64,
	shape_hash_lookups:    u64,
	cache_l1_hits:         u64,
	cache_l1_misses:       u64,
	cache_l2_hits:         u64,
	cache_l2_misses:       u64,
}

// ---- Value constructors and fast accessors.

value_none :: #force_inline proc "contextless" () -> Value {
	return {}
}

value_int :: #force_inline proc "contextless" (v: i64) -> Value {
	return {kind = .Integer, data = u64(v)}
}

value_int_unit :: #force_inline proc "contextless" (v: i64, unit: value_kinds.Integer_Unit) -> Value {
	if unit.kind == .None || !value_kinds.integer_unit_valid(unit) {
		return {kind = .Integer, data = u64(v)}
	}
	return {kind = .Integer, flags = u8(unit.kind), aux = u16(unit.unit), data = u64(v)}
}

value_unit :: proc "contextless" (v: Value) -> value_kinds.Integer_Unit {
	if v.kind != .Integer || v.flags == 0 {
		return {}
	}
	kind, ok := value_kinds.value_kind_of(v.flags)
	if !ok {
		return {}
	}
	u := value_kinds.Integer_Unit{kind = kind, unit = u8(v.aux)}
	if !value_kinds.integer_unit_valid(u) {
		return {}
	}
	return u
}

value_bool :: #force_inline proc "contextless" (v: bool) -> Value {
	return {kind = .Boolean, data = v ? 1 : 0}
}

value_integer :: #force_inline proc "contextless" (v: Value) -> i64 {
	return i64(v.data)
}

value_boolean :: #force_inline proc "contextless" (v: Value) -> bool {
	return v.data != 0
}

value_text_source :: #force_inline proc "contextless" (chunk_id: u16, offset, length: u32) -> Value {
	if length == 0 {
		return {kind = .Text, flags = u8(Text_Storage.Empty)}
	}
	return {kind = .Text, flags = u8(Text_Storage.Source), aux = chunk_id, meta = length, data = u64(offset)}
}

value_text_arena :: #force_inline proc "contextless" (offset, length: u32) -> Value {
	if length == 0 {
		return {kind = .Text, flags = u8(Text_Storage.Empty)}
	}
	return {kind = .Text, flags = u8(Text_Storage.Arena), meta = length, data = u64(offset)}
}

value_text_sym :: #force_inline proc "contextless" (sym: lex_parser.Sym_Id) -> Value {
	if sym == lex_parser.NO_SYM {
		return {kind = .Text, flags = u8(Text_Storage.Empty)}
	}
	return {kind = .Text, flags = u8(Text_Storage.Sym), meta = u32(sym)}
}

value_member :: #force_inline proc "contextless" (sym: lex_parser.Sym_Id, chunk_id: u16, node_idx: lex_parser.Node_Index) -> Value {
	return {kind = .Member, aux = chunk_id, meta = u32(sym), data = u64(u32(node_idx))}
}

@(rodata, private = "file")
TEXT_STORAGES_IN_ORDER := [len(Text_Storage)]Text_Storage {
	.Empty,
	.Source,
	.Arena,
	.Sym,
	.Host,
}

// value_text resolves any .Text VM value to its UTF-8 byte slice.
value_text :: proc "contextless" (eval: ^Evaluation, v: Value) -> string {
	if eval == nil || v.kind != .Text || int(v.flags) >= len(TEXT_STORAGES_IN_ORDER) {
		return ""
	}
	switch TEXT_STORAGES_IN_ORDER[v.flags] {
	case .Empty:
		return ""
	case .Source:
		cid := int(v.aux)
		if cid < 0 || cid >= eval.chunk_count {
			return ""
		}
		src := eval.chunks[cid].source
		off := int(v.data)
		end := off + int(v.meta)
		if off < 0 || end > len(src) || off > end {
			return ""
		}
		return src[off:end]
	case .Arena:
		off := int(v.data)
		end := off + int(v.meta)
		if off < 0 || end > eval.text_used || off > end {
			return ""
		}
		return string(eval.text_arena[off:end])
	case .Sym:
		return lex_parser.sym_text(&eval.interner, lex_parser.Sym_Id(v.meta))
	case .Host:
		idx := int(v.data)
		if idx < 0 || idx >= eval.host_obj_count {
			return ""
		}
		return eval.host_objs[idx].text
	}
	return ""
}

// value_follow_name returns the release name of a .Follow_Ref value.
value_follow_name :: proc "contextless" (eval: ^Evaluation, v: Value) -> string {
	if eval == nil || v.kind != .Follow_Ref {
		return ""
	}
	idx := int(v.data)
	if idx < 0 || idx >= eval.follow_count {
		return ""
	}
	return value_text(eval, eval.follows[idx].name)
}

// value_store_name returns the store name of a .Store_Ref value.
value_store_name :: proc "contextless" (eval: ^Evaluation, v: Value) -> string {
	if eval == nil || v.kind != .Store_Ref {
		return ""
	}
	idx := int(v.data)
	if idx < 0 || idx >= eval.store_count {
		return ""
	}
	return value_text(eval, eval.stores[idx].name)
}

// member_name_of returns the identifier of a .Member value (without leading '.').
member_name_of :: proc "contextless" (eval: ^Evaluation, v: Value) -> string {
	if eval == nil || v.kind != .Member {
		return ""
	}
	return lex_parser.sym_text(&eval.interner, lex_parser.Sym_Id(v.meta))
}

// hash_of resolves a .Hash, .Module_Ref, .Tree_Ref, or .Follow_Ref to its 32-byte BLAKE3 hash.
hash_of :: proc "contextless" (eval: ^Evaluation, v: Value) -> (hash: blake3.Hash, ok: bool) {
	if eval == nil {
		return {}, false
	}
	if v.kind == .Follow_Ref {
		idx := int(v.data)
		if idx < 0 || idx >= eval.follow_count {
			return {}, false
		}
		return eval.follows[idx].publisher, true
	}
	if v.kind != .Hash && v.kind != .Module_Ref && v.kind != .Tree_Ref {
		return {}, false
	}
	idx := int(v.meta)
	if idx < 0 || idx >= eval.hash_count {
		return {}, false
	}
	return eval.hashes[idx], true
}

// list_items_of returns the items slice of a .List or the rights slice of a .Store_Ref.
list_items_of :: proc "contextless" (eval: ^Evaluation, v: Value) -> []Value {
	if eval == nil {
		return nil
	}
	if v.kind == .Store_Ref {
		idx := int(v.data)
		if idx < 0 || idx >= eval.store_count {
			return nil
		}
		st := eval.stores[idx]
		first := int(st.rights_off)
		count := int(st.rights_len)
		if first < 0 || first > eval.list_item_count || count > eval.list_item_count - first {
			return nil
		}
		return eval.list_items[first:first + count]
	}
	if v.kind != .List {
		return nil
	}
	first := int(v.data)
	count := int(v.meta)
	if first < 0 || first > eval.list_item_count || count > eval.list_item_count - first {
		return nil
	}
	return eval.list_items[first:first + count]
}

// function_source_offsets returns the source byte offsets (open_paren, arrow_end)
// for a .Function VM value so the console can print its source text.
function_source_offsets :: proc "contextless" (eval: ^Evaluation, v: Value) -> (source: string, open_off, arrow_end: int, ok: bool) {
	if eval == nil || v.kind != .Function {
		return "", 0, 0, false
	}
	cidx := int(v.data)
	if cidx < 0 || cidx >= eval.closure_count {
		return "", 0, 0, false
	}
	cl := eval.closures[cidx]
	if int(cl.chunk_id) >= eval.chunk_count {
		return "", 0, 0, false
	}
	chunk := &eval.chunks[cl.chunk_id]
	if int(cl.proto_id) >= int(chunk.proto_count) {
		return "", 0, 0, false
	}
	proto := eval.protos[int(chunk.proto_start) + int(cl.proto_id)]
	return chunk.source, int(proto.fn_open_off), int(proto.fn_arrow_end), true
}

// Public parameter metadata for inspecting Lex functions (manual, palette, callers).
Function_Param_Info :: struct {
	name:        string,
	kind_annot:  lex_parser.Param_Kind_Annot,
	unit:        value_kinds.Integer_Unit,
	has_default: bool,
	is_pattern:  bool,
}

// function_param_meta writes parameter names, optional kind/unit annotations,
// and default presence for a .Function value into `out`, returning the count.
function_param_meta :: proc "contextless" (eval: ^Evaluation, fn_val: Value, out: []Function_Param_Info) -> (count: int, ok: bool) {
	if eval == nil || fn_val.kind != .Function {
		return 0, false
	}
	cidx := int(fn_val.data)
	if cidx < 0 || cidx >= eval.closure_count {
		return 0, false
	}
	cl := eval.closures[cidx]
	if int(cl.chunk_id) >= eval.chunk_count {
		return 0, false
	}
	chunk := &eval.chunks[cl.chunk_id]
	if int(cl.proto_id) >= int(chunk.proto_count) {
		return 0, false
	}
	proto := eval.protos[int(chunk.proto_start) + int(cl.proto_id)]
	n := min(int(proto.param_count), len(out))
	for i in 0 ..< n {
		pm := proto.params[i]
		out[i] = {
			name        = lex_parser.sym_text(&eval.interner, pm.name_sym),
			kind_annot  = pm.kind_annot,
			unit        = pm.unit,
			has_default = pm.has_default,
			is_pattern  = pm.is_pattern,
		}
	}
	return int(proto.param_count), true
}

// is_lazy_record reports whether kind is a lazy record (literal, overlay, plan, or project).
is_lazy_record :: #force_inline proc "contextless" (kind: Kind) -> bool {
	return kind == .Record_Literal || kind == .Record_With || kind == .Plan_Value || kind == .Project_Value
}
