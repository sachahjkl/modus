// Freestanding read-only multi-line Lex step engine for agent code mode
// (src/md/features/agent_code_mode.md, layer 2).
//
// Executes 1 to AGENT_STEP_LINE_CAPACITY (16) lines of Lex per step using
// modus:console_language (|> pipe desugaring), modus:lex_parser, and
// modus:lex_evaluator in Evaluation_Mode.Console.
//
// Security and resource invariants:
// - Persistent variable bindings (`name = expr`) survive across lines within
//   a step and across steps of one request; session_reset_bindings clears
//   them on a new request or reach change.
// - Every export call — top-level, nested in arguments, or inside map/filter
//   lambdas — passes through the read-only call border. Any mutating built-in
//   (start, stop, load, isolate, revoke, lock, unlock) or export outside
//   agent_bridge.READ_ONLY_EXPORTS is refused immediately with No_Grant and
//   zero dialog.
// - Fail-closed BLAKE3 hash-chained wide_grants.Act_Record entries are written
//   for the step, each line, and each export call BEFORE execution. If the
//   audit log is full or unavailable, execution stops before any call runs.
// - Bounds enforced per step: 16 lines, 4096 bytes per line, 64 export calls,
//   60s monotonic clock bound, 64 rows x 24 columns per table result, and 16 KiB
//   text summary budget across the step.
//
// Pure freestanding package: imports base and modus packages only, allocates
// no memory, and makes no host or kernel calls.
package agent_step

import "base:intrinsics"
import "modus:console_language"
import "modus:contract/agent_bridge"
import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/text_encoding"
import "modus:contract/wide_grants"
import "modus:lex_evaluator"
import "modus:lex_parser"

// Plan value: maximum Lex lines in one agent step (agent_code_mode.md).
STEP_LINE_CAPACITY :: agent_bridge.AGENT_STEP_LINE_CAPACITY

// Plan value: maximum read-only export calls executed in one step.
STEP_CALL_CAPACITY :: agent_bridge.AGENT_STEP_CALL_CAPACITY

// Plan value: maximum wall-clock duration of one step in milliseconds.
STEP_TIME_BOUND_MS :: agent_bridge.AGENT_STEP_TIME_BOUND_MS

// Format property: maximum bytes of one Lex line (line_editor.LINE_CAPACITY).
STEP_LINE_BYTES :: agent_bridge.MAX_LEX_LINE_BYTES

// Computed: pipe-desugared line buffer size (matches console NESTED_LINE_SIZE).
NESTED_LINE_BYTES :: 2 * STEP_LINE_BYTES

// Plan value: variables persisted across lines and steps of one request.
VARIABLE_CAPACITY :: 32

// Format property: maximum bytes of one variable identifier (matches console).
VARIABLE_NAME_BYTES :: 64

// Plan value: bounded table shape carried per line result (agent_code_mode.md).
RESULT_ROW_CAPACITY :: 64
RESULT_COLUMN_CAPACITY :: 24
RESULT_NAME_BYTES :: 32
RESULT_CELL_BYTES :: 64

// Plan value: text summary budget across all lines of one step (16 KiB).
STEP_RESULT_TEXT_BYTES :: 16 * 1024

// Computed: scratch pool for line texts and persistent variable strings.
STRING_POOL_BYTES :: 64 * 1024

// Computed: table slots available across variables and step results.
TABLE_POOL_CAPACITY :: 24

// Computed: parsed condition slots per step.
CONDITION_CAPACITY :: 32

// Computed: inline list items kept across variables.
VAR_LIST_ITEM_CAPACITY :: 512

// Computed: default audit log ring capacity (holds 1 step + 16 lines + 64 calls
// = 81 records per step, enough for 3 full worst-case steps per session).
ACT_LOG_CAPACITY :: 256

// Closed set of step execution refusal causes.
Step_Refusal :: enum u8 {
	None                 = 0,
	Empty_Step           = 1,
	Too_Many_Lines       = 2,
	Invalid_Line         = 3,
	Line_Too_Long        = 4,
	Pipe_Refused         = 5,
	Parse_Refused        = 6,
	No_Grant             = 7,
	Call_Limit_Exceeded  = 8,
	Time_Bound_Exceeded  = 9,
	Act_Log_Full         = 10,
	Evaluation_Refused   = 11,
	Variables_Full       = 12,
	Tables_Full          = 13,
	Strings_Full         = 14,
	Transport_Failed     = 15,
	Invalid_Argument     = 16,
}

@(rodata)
STEP_REFUSAL_NAMES := [Step_Refusal]string {
	.None                = "None",
	.Empty_Step          = "Empty_Step",
	.Too_Many_Lines      = "Too_Many_Lines",
	.Invalid_Line        = "Invalid_Line",
	.Line_Too_Long       = "Line_Too_Long",
	.Pipe_Refused        = "Pipe_Refused",
	.Parse_Refused       = "Parse_Refused",
	.No_Grant            = "No_Grant",
	.Call_Limit_Exceeded = "Call_Limit_Exceeded",
	.Time_Bound_Exceeded = "Time_Bound_Exceeded",
	.Act_Log_Full        = "Act_Log_Full",
	.Evaluation_Refused  = "Evaluation_Refused",
	.Variables_Full      = "Variables_Full",
	.Tables_Full         = "Tables_Full",
	.Strings_Full        = "Strings_Full",
	.Transport_Failed    = "Transport_Failed",
	.Invalid_Argument    = "Invalid_Argument",
}

// One cell of a typed table or record carried inside a step session.
Step_Cell :: struct {
	text:        [RESULT_CELL_BYTES]u8,
	text_count:  u8,
	integer:     i64,
	has_integer: bool,
}

// One typed table or record produced by a read-only export or table helper.
Step_Table :: struct {
	used:         bool,
	is_record:    bool,
	pinned:       bool, // Referenced by a persistent variable across steps.
	name:         [RESULT_NAME_BYTES]u8,
	name_count:   u8,
	total_rows:   int,
	column_count: int,
	row_count:    int,
	columns:      [RESULT_COLUMN_CAPACITY][RESULT_NAME_BYTES]u8,
	column_lens:  [RESULT_COLUMN_CAPACITY]u8,
	column_kinds: [RESULT_COLUMN_CAPACITY]agent_bridge.Lex_Column_Kind,
	column_units: [RESULT_COLUMN_CAPACITY]i64,
	cells:        [RESULT_ROW_CAPACITY * RESULT_COLUMN_CAPACITY]Step_Cell,
}

// Scalar argument forwarded from a read-only export call in a step to the
// transport adapter.
Step_Arg_Kind :: enum u8 {
	Integer = 1,
	Text    = 2,
	Boolean = 3,
	Member  = 4,
}

Step_Arg :: struct {
	kind:    Step_Arg_Kind,
	integer: i64,
	text:    string,
}

// Result returned by Step_Transport.call_export for one read-only export call.
Step_Call_Result :: struct {
	kind:       agent_bridge.Lex_Value_Kind,
	integer:    i64,
	boolean:    bool,
	text:       [1024]u8,
	text_count: int,
	has_table:  bool,
	table:      ^Step_Table, // Caller populates this pre-allocated table slot when has_table is true.
}

// Transport callbacks supplied by the host bridge or machine console.
Step_Transport :: struct {
	user_data:   rawptr,
	call_export: proc "contextless" (user_data: rawptr, service, export: string, args: []Step_Arg, out_result: ^Step_Call_Result) -> bool,
	now_ms:      proc "contextless" (user_data: rawptr) -> u64,
}

// Comparison operator parsed in `where(table, field op value)`.
Compare_Op :: enum u8 {
	Equal         = 1,
	Not_Equal     = 2,
	Less          = 3,
	Less_Equal    = 4,
	Greater       = 5,
	Greater_Equal = 6,
}

Step_Condition :: struct {
	field:       [RESULT_NAME_BYTES]u8,
	field_len:   u8,
	op:          Compare_Op,
	is_integer:  bool,
	integer_val: i64,
	text_val:    [RESULT_CELL_BYTES]u8,
	text_len:    u8,
}

// One persistent variable stored across lines and steps of a single request.
Step_Variable :: struct {
	used:            bool,
	name:            [VARIABLE_NAME_BYTES]u8,
	name_count:      u8,
	kind:            lex_evaluator.Kind,
	integer:         i64, // Integer, Boolean, or table index (when Table/Record).
	text_offset:     int,
	text_len:        int,
	list_first:      int,
	list_count:      int,
}

// Summary of one executed line in a step.
Line_Outcome :: struct {
	line_index:   int, // 1-based line number within the step.
	assigned:     bool,
	assigned_buf: [VARIABLE_NAME_BYTES]u8,
	assigned_len: u8,
	kind:         lex_evaluator.Kind,
	integer:      i64,
	table_index:  int, // >= 0 when kind is .Table or .Record.
	total_rows:   int,
	summary:      [512]u8,
	summary_len:  int,
}

// Result of executing one multi-line Lex step.
Step_Outcome :: struct {
	ok:                   bool,
	refusal:              Step_Refusal,
	failed_line:          int, // 1-based line number on failure, 0 if step-level.
	line_count:           int,
	calls_made:           int,
	act_records_written:  int,
	refused_command:      [128]u8,
	refused_command_len:  int,
	lines:                [STEP_LINE_CAPACITY]Line_Outcome,
	text_budget_exceeded: bool,
}

// Persistent session state for one request of an agent. Allocate on heap or in
// static module memory — never on the stack.
Step_Session :: struct {
	grant_serial:        u64,
	step_serial:         u64,
	time_bound_ms:       u64,
	act_log_capacity:    int,
	act_log:             [ACT_LOG_CAPACITY]wide_grants.Act_Record,
	act_log_count:       int,
	last_act_hash:       blake3.Hash,

	variables:           [VARIABLE_CAPACITY]Step_Variable,
	var_list_items:      [VAR_LIST_ITEM_CAPACITY]lex_evaluator.Value,
	var_list_item_count: int,

	strings:             [STRING_POOL_BYTES]u8,
	string_used:         int,

	tables:              [TABLE_POOL_CAPACITY]Step_Table,
	conditions:          [CONDITION_CAPACITY]Step_Condition,
	condition_count:     int,

	// Per-line parser and evaluator working storage (kept in session, never on stack).
	nested_line:         [NESTED_LINE_BYTES]u8,
	pipe_stages:         [console_language.PIPE_STAGE_CAPACITY]console_language.Pipe_Stage,
	tree:                lex_parser.Syntax_Tree,
	evaluation:          lex_evaluator.Evaluation,
	call_result:         Step_Call_Result,

	// Active step transient fields accessed by evaluation host callbacks.
	transport:           Step_Transport,
	step_start_ms:       u64,
	step_calls_made:     int,
	step_records_added:  int,
	active_refusal:      Step_Refusal,
	refused_command:     [128]u8,
	refused_command_len: int,
}

// session_init initializes a fresh Step_Session with its audit log capacity
// and step time bound.
session_init :: proc "contextless" (session: ^Step_Session, grant_serial: u64 = 0, act_log_capacity := ACT_LOG_CAPACITY, time_bound_ms := STEP_TIME_BOUND_MS) {
	intrinsics.mem_zero(session, size_of(Step_Session))
	session.grant_serial = grant_serial
	session.act_log_capacity = clamp(act_log_capacity, 0, ACT_LOG_CAPACITY)
	session.time_bound_ms = time_bound_ms > 0 ? time_bound_ms : STEP_TIME_BOUND_MS
	session.last_act_hash = wide_grants.GENESIS_PREVIOUS_HASH
}

// session_reset_bindings clears all persistent variable bindings, string pool,
// and table slots (called on a new request or reach change) while preserving
// the monotonic BLAKE3 act record chain.
session_reset_bindings :: proc "contextless" (session: ^Step_Session) {
	for &v in session.variables {
		v = {}
	}
	session.var_list_item_count = 0
	session.string_used = 0
	for &tbl in session.tables {
		tbl.used = false
		tbl.pinned = false
	}
}

// session_act_records returns the slice of BLAKE3 hash-chained act records
// written in this session.
session_act_records :: proc "contextless" (session: ^Step_Session) -> []wide_grants.Act_Record {
	if session == nil {
		return nil
	}
	return session.act_log[:session.act_log_count]
}

// session_table returns the Step_Table at table_index, or nil if out of range.
session_table :: proc "contextless" (session: ^Step_Session, table_index: int) -> ^Step_Table {
	if session == nil || table_index < 0 || table_index >= len(session.tables) || !session.tables[table_index].used {
		return nil
	}
	return &session.tables[table_index]
}

// table_cell_text returns the text slice of cell (row, col) in tbl.
table_cell_text :: proc "contextless" (tbl: ^Step_Table, row, col: int) -> string {
	if tbl == nil || row < 0 || row >= tbl.row_count || col < 0 || col >= tbl.column_count {
		return ""
	}
	cell := &tbl.cells[row * tbl.column_count + col]
	return string(cell.text[:cell.text_count])
}

// table_column_name returns the name of column col in tbl.
table_column_name :: proc "contextless" (tbl: ^Step_Table, col: int) -> string {
	if tbl == nil || col < 0 || col >= tbl.column_count {
		return ""
	}
	return string(tbl.columns[col][:tbl.column_lens[col]])
}

// table_name returns the record name of tbl.
table_name :: proc "contextless" (tbl: ^Step_Table) -> string {
	if tbl == nil {
		return ""
	}
	return string(tbl.name[:tbl.name_count])
}

// append_act_record writes one fail-closed BLAKE3 hash-chained Act_Record.
// Returns false when the audit log is full.
@(private = "file")
append_act_record :: proc "contextless" (session: ^Step_Session, now_ms: u64, kind: wide_grants.Act_Kind, detail0, detail1: u64) -> bool {
	if session.act_log_count >= session.act_log_capacity || session.act_log_count >= ACT_LOG_CAPACITY {
		return false
	}
	rec := wide_grants.Act_Record {
		sequence_number  = u64(session.act_log_count),
		grant_serial     = session.grant_serial,
		timestamp_ms     = now_ms,
		act_kind_word    = u64(kind),
		target_window_id = 0,
		detail_word_0    = detail0,
		detail_word_1    = detail1,
		previous_hash    = session.last_act_hash,
	}
	digest, hash_refusal := wide_grants.act_record_compute_hash(&rec)
	if hash_refusal != .None {
		return false
	}
	rec.record_hash = digest
	session.act_log[session.act_log_count] = rec
	session.act_log_count += 1
	session.last_act_hash = digest
	session.step_records_added += 1
	return true
}

@(private = "file")
hash_head_u64 :: proc "contextless" (data: []u8) -> u64 {
	digest := blake3.hash(data)
	return byte_order.read_u64_little_endian(digest[:], 0)
}

@(private = "file")
validate_line_text :: proc "contextless" (line: string) -> Step_Refusal {
	if len(line) == 0 {
		return .Invalid_Line
	}
	if len(line) > STEP_LINE_BYTES {
		return .Line_Too_Long
	}
	if agent_bridge.validate_lex_line(transmute([]u8)line) != .None {
		return .Invalid_Line
	}
	return .None
}

@(private = "file")
clock_now :: proc "contextless" (session: ^Step_Session) -> u64 {
	if session.transport.now_ms != nil {
		return session.transport.now_ms(session.transport.user_data)
	}
	return 0
}

@(private = "file")
time_expired :: proc "contextless" (session: ^Step_Session) -> bool {
	now := clock_now(session)
	if now < session.step_start_ms {
		return true
	}
	return (now - session.step_start_ms) >= session.time_bound_ms
}

@(private = "file")
intern_string :: proc "contextless" (session: ^Step_Session, s: string) -> (offset: int, length: int, ok: bool) {
	if len(s) == 0 {
		return 0, 0, true
	}
	if session.string_used + len(s) > len(session.strings) {
		return 0, 0, false
	}
	off := session.string_used
	copy(session.strings[off:off + len(s)], s)
	session.string_used += len(s)
	return off, len(s), true
}

@(private = "file")
alloc_table_slot :: proc "contextless" (session: ^Step_Session) -> (index: int, ok: bool) {
	// Prefer a free slot first.
	for i in 0 ..< len(session.tables) {
		if !session.tables[i].used {
			intrinsics.mem_zero(&session.tables[i], size_of(Step_Table))
			session.tables[i].used = true
			return i, true
		}
	}
	// Reclaim an unpinned slot from an earlier completed step if needed.
	for i in 0 ..< len(session.tables) {
		if !session.tables[i].pinned {
			intrinsics.mem_zero(&session.tables[i], size_of(Step_Table))
			session.tables[i].used = true
			return i, true
		}
	}
	return -1, false
}

@(private = "file")
recompute_pinned_tables :: proc "contextless" (session: ^Step_Session) {
	for &tbl in session.tables {
		tbl.pinned = false
	}
	for &v in session.variables {
		if !v.used {
			continue
		}
		if v.kind == .Table || v.kind == .Record {
			if v.integer >= 0 && int(v.integer) < len(session.tables) {
				session.tables[int(v.integer)].pinned = true
			}
		} else if v.kind == .List {
			for item in session.var_list_items[v.list_first:v.list_first + v.list_count] {
				if (item.kind == .Table || item.kind == .Record) && item.integer >= 0 && int(item.integer) < len(session.tables) {
					session.tables[int(item.integer)].pinned = true
				}
			}
		}
	}
}

@(private = "file")
set_refusal :: proc "contextless" (session: ^Step_Session, refusal: Step_Refusal, command: string = "") {
	if session.active_refusal != .None {
		return
	}
	session.active_refusal = refusal
	if len(command) > 0 {
		n := copy(session.refused_command[:], command)
		session.refused_command_len = n
	}
}

@(private = "file")
is_ident_char :: proc "contextless" (c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_'
}

@(private = "file")
is_ident :: proc "contextless" (s: string) -> bool {
	if len(s) == 0 || s[0] < 'a' || s[0] > 'z' {
		return false
	}
	for c in transmute([]u8)s {
		if !is_ident_char(c) {
			return false
		}
	}
	return true
}

@(private = "file")
split_service_export :: proc "contextless" (name: string) -> (service, export: string, ok: bool) {
	dot := -1
	for i in 0 ..< len(name) {
		if name[i] == '.' {
			if dot >= 0 {
				return "", "", false
			}
			dot = i
		}
	}
	if dot <= 0 || dot + 1 >= len(name) {
		return "", "", false
	}
	service = name[:dot]
	export = name[dot + 1:]
	if !is_ident(service) || !is_ident(export) {
		return "", "", false
	}
	return service, export, true
}

@(private = "file")
parameter_form_of :: proc "contextless" (data: rawptr, command_name: string, index: int) -> lex_parser.Parameter_Form {
	_ = data
	if command_name == "where" && index == 1 {
		return .Condition
	}
	return .Expression
}

@(private = "file")
variable_find :: proc "contextless" (session: ^Step_Session, name: string) -> ^Step_Variable {
	for &v in session.variables {
		if v.used && string(v.name[:v.name_count]) == name {
			return &v
		}
	}
	return nil
}

@(private = "file")
host_name_value :: proc "contextless" (data: rawptr, name: string) -> (value: lex_evaluator.Value, ok: bool) {
	session := (^Step_Session)(data)
	v := variable_find(session, name)
	if v == nil {
		set_refusal(session, .Evaluation_Refused, name)
		return {}, false
	}
	switch v.kind {
	case .Integer:
		return {kind = .Integer, integer = v.integer}, true
	case .Boolean:
		return {kind = .Boolean, integer = v.integer}, true
	case .Text:
		return {kind = .Text, text = string(session.strings[v.text_offset:v.text_offset + v.text_len])}, true
	case .Table, .Record:
		return {kind = v.kind, integer = v.integer}, true
	case .List:
		items := session.var_list_items[v.list_first:v.list_first + v.list_count]
		first, added := lex_evaluator.list_items_add(&session.evaluation, items)
		if !added {
			set_refusal(session, .Evaluation_Refused, name)
			return {}, false
		}
		return {kind = .List, integer = i64(first), detail = u32(v.list_count)}, true
	case .None, .Handle, .Bytes, .Stream, .Record_Input, .Record_Literal, .Enum, .Member, .Function, .Hash, .Record_With, .Module_Ref, .Recipe_Ref, .Follow_Ref, .Store_Ref, .Plan_Value, .Project_Value, .Tree_Ref:
		set_refusal(session, .Evaluation_Refused, name)
		return {}, false
	}
	return {}, false
}

@(private = "file")
host_command_find :: proc "contextless" (data: rawptr, name: string) -> (sig: lex_evaluator.Command_Signature, found: bool) {
	session := (^Step_Session)(data)
	// Pure read-only table helpers (zero machine side effects).
	switch name {
	case "count", "rows":
		return {has_effect = false, parameter_count = 1, kinds = {0 = .None}, untyped = true}, true
	case "first", "skip":
		return {has_effect = false, parameter_count = 2, kinds = {0 = .Table, 1 = .Integer}, untyped = true}, true
	case "where":
		return {has_effect = false, parameter_count = 2, kinds = {0 = .Table, 1 = .None}, untyped = true}, true
	case "sort", "column":
		return {has_effect = false, parameter_count = 2, kinds = {0 = .Table, 1 = .Text}, untyped = true}, true
	}

	// Read-only export call border: any bare command (start, stop, load,
	// isolate, revoke, lock, unlock) or any export outside READ_ONLY_EXPORTS
	// is refused immediately with No_Grant and zero dialog.
	service, export, valid_pair := split_service_export(name)
	if !valid_pair || !agent_bridge.lex_export_is_read_only(transmute([]u8)service, transmute([]u8)export) {
		set_refusal(session, .No_Grant, name)
		return {}, false
	}
	sig = {
		has_effect      = true,
		parameter_count = lex_parser.ARGUMENT_CAPACITY,
		untyped         = true,
	}
	for i in 0 ..< lex_parser.ARGUMENT_CAPACITY {
		sig.optional[i] = true
		sig.kinds[i] = .None
	}
	return sig, true
}

@(private)
parse_int64 :: proc "contextless" (s: string) -> (val: i64, ok: bool) {
	if len(s) == 0 {
		return 0, false
	}
	idx := 0
	neg := false
	if s[0] == '-' {
		neg = true
		idx = 1
	}
	if idx >= len(s) {
		return 0, false
	}
	limit := neg ? u64(max(i64)) + 1 : u64(max(i64))
	acc: u64 = 0
	for ; idx < len(s); idx += 1 {
		c := s[idx]
		if c < '0' || c > '9' {
			return 0, false
		}
		digit := u64(c - '0')
		if acc > (limit - digit) / 10 {
			return 0, false
		}
		acc = acc * 10 + digit
	}
	if neg {
		if acc == u64(max(i64)) + 1 {
			return min(i64), true
		}
		return -i64(acc), true
	}
	return i64(acc), true
}

@(private = "file")
host_condition_value :: proc "contextless" (data: rawptr, evaluation: ^lex_evaluator.Evaluation, command_name: string, before: []lex_evaluator.Value, node: lex_parser.Node_Index) -> (value: lex_evaluator.Value, ok: bool) {
	_ = command_name
	_ = before
	session := (^Step_Session)(data)
	if session.condition_count >= len(session.conditions) {
		set_refusal(session, .Evaluation_Refused, "where")
		return {}, false
	}
	cond_node := lex_parser.node_at(evaluation.tree, node)
	if cond_node == nil || cond_node.condition_refusal != .None {
		set_refusal(session, .Invalid_Argument, "where")
		return {}, false
	}
	head := cond_node.condition_head
	if len(head.field) == 0 || len(head.field) > RESULT_NAME_BYTES {
		set_refusal(session, .Invalid_Argument, "where")
		return {}, false
	}
	op: Compare_Op
	switch head.comparison {
	case .Equal:
		op = .Equal
	case .Not_Equal:
		op = .Not_Equal
	case .Less:
		op = .Less
	case .Less_Or_Equal:
		op = .Less_Equal
	case .Greater:
		op = .Greater
	case .Greater_Or_Equal:
		op = .Greater_Equal
	}

	cond := &session.conditions[session.condition_count]
	cond^ = {}
	cond.field_len = u8(copy(cond.field[:], head.field))
	cond.op = op

	// Evaluate the RHS expression directly via lex_evaluator (supports literals,
	// variables, arithmetic, and read-only calls; forbids unauthorized calls!).
	rhs_val, rhs_ok := lex_evaluator.force(evaluation, cond_node.first_child)
	if !rhs_ok {
		if session.active_refusal == .None {
			// Fallback for bare status/member name like `level = Warning`.
			child_node := lex_parser.node_at(evaluation.tree, cond_node.first_child)
			if child_node != nil && child_node.kind == .Name && cond_node.member_alone {
				member := lex_parser.node_text(evaluation.tree, cond_node.first_child)
				if len(member) > 0 && len(member) <= RESULT_CELL_BYTES {
					cond.is_integer = false
					cond.text_len = u8(copy(cond.text_val[:], member))
					idx := session.condition_count
					session.condition_count += 1
					return {kind = .Integer, integer = i64(idx)}, true
				}
			}
			set_refusal(session, .Invalid_Argument, "where")
		}
		return {}, false
	}
	switch rhs_val.kind {
	case .Integer:
		cond.is_integer = true
		cond.integer_val = rhs_val.integer
	case .Text:
		if len(rhs_val.text) > RESULT_CELL_BYTES {
			set_refusal(session, .Invalid_Argument, "where")
			return {}, false
		}
		cond.is_integer = false
		cond.text_len = u8(copy(cond.text_val[:], rhs_val.text))
	case .Boolean:
		cond.is_integer = false
		b := rhs_val.integer != 0 ? "true" : "false"
		cond.text_len = u8(copy(cond.text_val[:], b))
	case .None, .Record, .Handle, .Table, .Bytes, .Stream, .Record_Input, .Record_Literal, .Enum, .Member, .Function, .List, .Hash, .Record_With, .Module_Ref, .Recipe_Ref, .Follow_Ref, .Store_Ref, .Plan_Value, .Project_Value, .Tree_Ref:
		set_refusal(session, .Invalid_Argument, "where")
		return {}, false
	}
	idx := session.condition_count
	session.condition_count += 1
	return {kind = .Integer, integer = i64(idx)}, true
}

@(private = "file")
host_values_add :: proc "contextless" (data: rawptr, left, right: lex_evaluator.Value) -> (sum: lex_evaluator.Value, ok: bool) {
	session := (^Step_Session)(data)
	if left.kind == .Text && right.kind == .Text {
		total := len(left.text) + len(right.text)
		if session.string_used + total > len(session.strings) {
			set_refusal(session, .Strings_Full)
			return {}, false
		}
		start := session.string_used
		copy(session.strings[start:start + len(left.text)], left.text)
		copy(session.strings[start + len(left.text):start + total], right.text)
		session.string_used += total
		return {kind = .Text, text = string(session.strings[start:start + total])}, true
	}
	set_refusal(session, .Evaluation_Refused)
	return {}, false
}

@(private = "file")
compare_strings :: proc "contextless" (a, b: string) -> int {
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

@(private = "file")
cell_matches :: proc "contextless" (cell: ^Step_Cell, cond: ^Step_Condition) -> bool {
	if cond.is_integer {
		val := cell.integer
		if !cell.has_integer {
			parsed, ok := parse_int64(string(cell.text[:cell.text_count]))
			if !ok {
				return false
			}
			val = parsed
		}
		switch cond.op {
		case .Equal:
			return val == cond.integer_val
		case .Not_Equal:
			return val != cond.integer_val
		case .Less:
			return val < cond.integer_val
		case .Less_Equal:
			return val <= cond.integer_val
		case .Greater:
			return val > cond.integer_val
		case .Greater_Equal:
			return val >= cond.integer_val
		}
		return false
	}
	cmp := compare_strings(string(cell.text[:cell.text_count]), string(cond.text_val[:cond.text_len]))
	switch cond.op {
	case .Equal:
		return cmp == 0
	case .Not_Equal:
		return cmp != 0
	case .Less:
		return cmp < 0
	case .Less_Equal:
		return cmp <= 0
	case .Greater:
		return cmp > 0
	case .Greater_Equal:
		return cmp >= 0
	}
	return false
}

@(private = "file")
table_find_column :: proc "contextless" (tbl: ^Step_Table, name: string) -> int {
	for c in 0 ..< tbl.column_count {
		if string(tbl.columns[c][:tbl.column_lens[c]]) == name {
			return c
		}
	}
	return -1
}

@(private = "file")
table_copy_schema :: proc "contextless" (dst, src: ^Step_Table) {
	dst.is_record = false
	dst.name = src.name
	dst.name_count = src.name_count
	dst.column_count = src.column_count
	dst.columns = src.columns
	dst.column_lens = src.column_lens
	dst.column_kinds = src.column_kinds
	dst.column_units = src.column_units
}

@(private = "file")
table_copy_row :: proc "contextless" (dst: ^Step_Table, dst_row: int, src: ^Step_Table, src_row: int) {
	cols := src.column_count
	for c in 0 ..< cols {
		dst.cells[dst_row * cols + c] = src.cells[src_row * cols + c]
	}
}

@(private = "file")
run_builtin_helper :: proc "contextless" (session: ^Step_Session, name: string, args: []lex_evaluator.Value) -> (value: lex_evaluator.Value, ok: bool) {
	switch name {
	case "count":
		if len(args) < 1 {
			set_refusal(session, .Invalid_Argument, name)
			return {}, false
		}
		if args[0].kind == .Table || args[0].kind == .Record {
			tbl := session_table(session, int(args[0].integer))
			if tbl == nil {
				set_refusal(session, .Invalid_Argument, name)
				return {}, false
			}
			return {kind = .Integer, integer = i64(tbl.row_count)}, true
		}
		if args[0].kind == .List {
			return {kind = .Integer, integer = i64(args[0].detail)}, true
		}
		set_refusal(session, .Invalid_Argument, name)
		return {}, false

	case "rows":
		if len(args) < 1 || (args[0].kind != .Table && args[0].kind != .Record) {
			set_refusal(session, .Invalid_Argument, name)
			return {}, false
		}
		tbl := session_table(session, int(args[0].integer))
		if tbl == nil {
			set_refusal(session, .Invalid_Argument, name)
			return {}, false
		}
		return {kind = .Integer, integer = i64(tbl.total_rows)}, true

	case "first", "skip":
		if len(args) < 2 || args[0].kind != .Table || args[1].kind != .Integer || args[1].integer < 0 {
			set_refusal(session, .Invalid_Argument, name)
			return {}, false
		}
		src := session_table(session, int(args[0].integer))
		if src == nil {
			set_refusal(session, .Invalid_Argument, name)
			return {}, false
		}
		dst_idx, slot_ok := alloc_table_slot(session)
		if !slot_ok {
			set_refusal(session, .Tables_Full, name)
			return {}, false
		}
		dst := &session.tables[dst_idx]
		table_copy_schema(dst, src)
		n := int(min(args[1].integer, i64(src.row_count)))
		if name == "first" {
			for r in 0 ..< n {
				table_copy_row(dst, r, src, r)
			}
			dst.row_count = n
			dst.total_rows = n
		} else {
			out_r := 0
			for r in n ..< src.row_count {
				table_copy_row(dst, out_r, src, r)
				out_r += 1
			}
			dst.row_count = out_r
			dst.total_rows = out_r
		}
		return {kind = .Table, integer = i64(dst_idx)}, true

	case "where":
		if len(args) < 2 || args[0].kind != .Table || args[1].kind != .Integer {
			set_refusal(session, .Invalid_Argument, name)
			return {}, false
		}
		src := session_table(session, int(args[0].integer))
		cond_idx := int(args[1].integer)
		if src == nil || cond_idx < 0 || cond_idx >= session.condition_count {
			set_refusal(session, .Invalid_Argument, name)
			return {}, false
		}
		cond := &session.conditions[cond_idx]
		col := table_find_column(src, string(cond.field[:cond.field_len]))
		if col < 0 {
			set_refusal(session, .Invalid_Argument, name)
			return {}, false
		}
		dst_idx, slot_ok := alloc_table_slot(session)
		if !slot_ok {
			set_refusal(session, .Tables_Full, name)
			return {}, false
		}
		dst := &session.tables[dst_idx]
		table_copy_schema(dst, src)
		out_r := 0
		for r in 0 ..< src.row_count {
			if cell_matches(&src.cells[r * src.column_count + col], cond) {
				table_copy_row(dst, out_r, src, r)
				out_r += 1
			}
		}
		dst.row_count = out_r
		dst.total_rows = out_r
		return {kind = .Table, integer = i64(dst_idx)}, true

	case "sort":
		if len(args) < 2 || args[0].kind != .Table || args[1].kind != .Text {
			set_refusal(session, .Invalid_Argument, name)
			return {}, false
		}
		src := session_table(session, int(args[0].integer))
		if src == nil {
			set_refusal(session, .Invalid_Argument, name)
			return {}, false
		}
		col := table_find_column(src, args[1].text)
		if col < 0 {
			set_refusal(session, .Invalid_Argument, name)
			return {}, false
		}
		dst_idx, slot_ok := alloc_table_slot(session)
		if !slot_ok {
			set_refusal(session, .Tables_Full, name)
			return {}, false
		}
		dst := &session.tables[dst_idx]
		table_copy_schema(dst, src)
		order: [RESULT_ROW_CAPACITY]int
		for r in 0 ..< src.row_count {
			order[r] = r
		}
		// Insertion sort (stable, bounded by RESULT_ROW_CAPACITY = 64).
		for i in 1 ..< src.row_count {
			key_row := order[i]
			key_cell := &src.cells[key_row * src.column_count + col]
			j := i - 1
			for j >= 0 {
				cur_cell := &src.cells[order[j] * src.column_count + col]
				greater := false
				if cur_cell.has_integer && key_cell.has_integer {
					greater = cur_cell.integer > key_cell.integer
				} else {
					greater = compare_strings(string(cur_cell.text[:cur_cell.text_count]), string(key_cell.text[:key_cell.text_count])) > 0
				}
				if !greater {
					break
				}
				order[j + 1] = order[j]
				j -= 1
			}
			order[j + 1] = key_row
		}
		for r in 0 ..< src.row_count {
			table_copy_row(dst, r, src, order[r])
		}
		dst.row_count = src.row_count
		dst.total_rows = src.row_count
		return {kind = .Table, integer = i64(dst_idx)}, true

	case "column":
		if len(args) < 2 || args[0].kind != .Table || args[1].kind != .Text {
			set_refusal(session, .Invalid_Argument, name)
			return {}, false
		}
		src := session_table(session, int(args[0].integer))
		if src == nil {
			set_refusal(session, .Invalid_Argument, name)
			return {}, false
		}
		col := table_find_column(src, args[1].text)
		if col < 0 {
			set_refusal(session, .Invalid_Argument, name)
			return {}, false
		}
		items: [RESULT_ROW_CAPACITY]lex_evaluator.Value
		for r in 0 ..< src.row_count {
			cell := &src.cells[r * src.column_count + col]
			if cell.has_integer {
				items[r] = {kind = .Integer, integer = cell.integer}
			} else {
				off, ln, iok := intern_string(session, string(cell.text[:cell.text_count]))
				if !iok {
					set_refusal(session, .Strings_Full, name)
					return {}, false
				}
				items[r] = {kind = .Text, text = string(session.strings[off:off + ln])}
			}
		}
		first, added := lex_evaluator.list_items_add(&session.evaluation, items[:src.row_count])
		if !added {
			set_refusal(session, .Evaluation_Refused, name)
			return {}, false
		}
		return {kind = .List, integer = i64(first), detail = u32(src.row_count)}, true
	}
	return {}, false
}

@(private = "file")
host_call_run :: proc "contextless" (data: rawptr, name: string, arguments: []lex_evaluator.Value) -> (value: lex_evaluator.Value, ok: bool) {
	session := (^Step_Session)(data)
	switch name {
	case "count", "rows", "first", "skip", "where", "sort", "column":
		return run_builtin_helper(session, name, arguments)
	}

	// Defense in depth: re-verify read-only allowlist at execution border.
	service, export, valid_pair := split_service_export(name)
	if !valid_pair || !agent_bridge.lex_export_is_read_only(transmute([]u8)service, transmute([]u8)export) {
		set_refusal(session, .No_Grant, name)
		return {}, false
	}

	// Enforce monotonic step time bound and call count bound.
	if time_expired(session) {
		set_refusal(session, .Time_Bound_Exceeded, name)
		return {}, false
	}
	if session.step_calls_made >= STEP_CALL_CAPACITY {
		set_refusal(session, .Call_Limit_Exceeded, name)
		return {}, false
	}

	// Strip trailing omitted optional arguments (.None).
	effective := len(arguments)
	for effective > 0 && arguments[effective - 1].kind == .None {
		effective -= 1
	}
	args_buf: [lex_parser.ARGUMENT_CAPACITY]Step_Arg
	for i in 0 ..< effective {
		arg := arguments[i]
		switch arg.kind {
		case .Integer:
			args_buf[i] = {kind = .Integer, integer = arg.integer}
		case .Text:
			args_buf[i] = {kind = .Text, text = arg.text}
		case .Boolean:
			args_buf[i] = {kind = .Boolean, integer = arg.integer}
		case .Member:
			member_node := lex_parser.node_at(session.evaluation.tree, lex_parser.Node_Index(arg.integer))
			if member_node == nil {
				set_refusal(session, .Invalid_Argument, name)
				return {}, false
			}
			args_buf[i] = {kind = .Member, text = lex_parser.node_text(session.evaluation.tree, lex_parser.Node_Index(arg.integer))}
		case .None, .Record, .Handle, .Table, .Bytes, .Stream, .Record_Input, .Record_Literal, .Enum, .Function, .List, .Hash, .Record_With, .Module_Ref, .Recipe_Ref, .Follow_Ref, .Store_Ref, .Plan_Value, .Project_Value, .Tree_Ref:
			set_refusal(session, .Invalid_Argument, name)
			return {}, false
		}
	}

	// Fail-closed: record the export call in the BLAKE3 act chain BEFORE executing it.
	call_detail_0 := hash_head_u64(transmute([]u8)name)
	call_detail_1 := (session.step_serial << 16) | u64(session.step_calls_made + 1)
	if !append_act_record(session, clock_now(session), .Call_Made, call_detail_0, call_detail_1) {
		set_refusal(session, .Act_Log_Full, name)
		return {}, false
	}
	session.step_calls_made += 1

	if session.transport.call_export == nil {
		set_refusal(session, .Transport_Failed, name)
		return {}, false
	}

	tbl_idx, tbl_ok := alloc_table_slot(session)
	if !tbl_ok {
		set_refusal(session, .Tables_Full, name)
		return {}, false
	}
	session.call_result = {table = &session.tables[tbl_idx]}
	if !session.transport.call_export(session.transport.user_data, service, export, args_buf[:effective], &session.call_result) {
		session.tables[tbl_idx].used = false
		set_refusal(session, .Transport_Failed, name)
		return {}, false
	}

	res := &session.call_result
	switch res.kind {
	case .Table, .Record:
		if !res.has_table {
			session.tables[tbl_idx].used = false
			set_refusal(session, .Transport_Failed, name)
			return {}, false
		}
		tbl := &session.tables[tbl_idx]
		tbl.is_record = res.kind == .Record
		tbl.row_count = clamp(tbl.row_count, 0, RESULT_ROW_CAPACITY)
		tbl.column_count = clamp(tbl.column_count, 0, RESULT_COLUMN_CAPACITY)
		return {kind = res.kind == .Record ? .Record : .Table, integer = i64(tbl_idx)}, true
	case .Integer:
		session.tables[tbl_idx].used = false
		return {kind = .Integer, integer = res.integer}, true
	case .Boolean:
		session.tables[tbl_idx].used = false
		return {kind = .Boolean, integer = res.boolean ? 1 : 0}, true
	case .Text, .Enum_Member:
		session.tables[tbl_idx].used = false
		s := string(res.text[:clamp(res.text_count, 0, len(res.text))])
		off, ln, iok := intern_string(session, s)
		if !iok {
			set_refusal(session, .Strings_Full, name)
			return {}, false
		}
		return {kind = .Text, text = string(session.strings[off:off + ln])}, true
	case .None:
		session.tables[tbl_idx].used = false
		return {kind = .None}, true
	}
	session.tables[tbl_idx].used = false
	return {kind = .None}, true
}

@(private = "file")
bind_variable :: proc "contextless" (session: ^Step_Session, name: string, value: lex_evaluator.Value) -> Step_Refusal {
	if len(name) == 0 || len(name) > VARIABLE_NAME_BYTES {
		return .Invalid_Argument
	}
	slot := variable_find(session, name)
	if slot == nil {
		for &v in session.variables {
			if !v.used {
				slot = &v
				break
			}
		}
	}
	if slot == nil {
		return .Variables_Full
	}

	switch value.kind {
	case .Integer, .Boolean, .Table, .Record:
		slot^ = {
			used    = true,
			kind    = value.kind,
			integer = value.integer,
		}
		slot.name_count = u8(copy(slot.name[:], name))
	case .Text:
		off, ln, ok := intern_string(session, value.text)
		if !ok {
			return .Strings_Full
		}
		slot^ = {
			used        = true,
			kind        = .Text,
			text_offset = off,
			text_len    = ln,
		}
		slot.name_count = u8(copy(slot.name[:], name))
	case .List:
		items := lex_evaluator.list_items_of(&session.evaluation, value)
		if session.var_list_item_count + len(items) > len(session.var_list_items) {
			return .Variables_Full
		}
		first := session.var_list_item_count
		saved_string_used := session.string_used
		for item, idx in items {
			stored := item
			if item.kind == .Text {
				off, ln, ok := intern_string(session, item.text)
				if !ok {
					session.string_used = saved_string_used
					return .Strings_Full
				}
				stored.text = string(session.strings[off:off + ln])
			}
			session.var_list_items[first + idx] = stored
		}
		session.var_list_item_count += len(items)
		slot^ = {
			used       = true,
			kind       = .List,
			list_first = first,
			list_count = len(items),
		}
		slot.name_count = u8(copy(slot.name[:], name))
	case .None, .Handle, .Bytes, .Stream, .Record_Input, .Record_Literal, .Enum, .Member, .Function, .Hash, .Record_With, .Module_Ref, .Recipe_Ref, .Follow_Ref, .Store_Ref, .Plan_Value, .Project_Value, .Tree_Ref:
		return .Invalid_Argument
	}
	recompute_pinned_tables(session)
	return .None
}

@(private = "file")
write_i64 :: proc "contextless" (dst: []u8, pos: ^int, value: i64) {
	if pos^ >= len(dst) {
		return
	}
	v := value
	if v < 0 {
		dst[pos^] = '-'
		pos^ += 1
		if v == min(i64) {
			write_str(dst, pos, "9223372036854775808")
			return
		}
		v = -v
	}
	digits: [20]u8
	count := 0
	if v == 0 {
		digits[0] = '0'
		count = 1
	} else {
		for v > 0 {
			digits[count] = u8('0' + (v % 10))
			v /= 10
			count += 1
		}
	}
	for i := count - 1; i >= 0 && pos^ < len(dst); i -= 1 {
		dst[pos^] = digits[i]
		pos^ += 1
	}
}

@(private)
write_str :: proc "contextless" (dst: []u8, pos: ^int, s: string) {
	if pos^ >= len(dst) || len(s) == 0 {
		return
	}
	room := len(dst) - pos^
	take := len(s)
	if take > room {
		take = text_encoding.complete_characters(transmute([]u8)s[:room])
	}
	if take > 0 {
		copy(dst[pos^:pos^ + take], s[:take])
		pos^ += take
	}
}

@(private = "file")
summarize_value :: proc "contextless" (session: ^Step_Session, value: lex_evaluator.Value, out: ^Line_Outcome) {
	out.kind = value.kind
	out.integer = value.integer
	out.table_index = -1
	pos := 0
	switch value.kind {
	case .Integer:
		write_i64(out.summary[:], &pos, value.integer)
	case .Boolean:
		write_str(out.summary[:], &pos, value.integer != 0 ? "true" : "false")
	case .Text:
		write_str(out.summary[:], &pos, value.text)
	case .Table, .Record:
		out.table_index = int(value.integer)
		if tbl := session_table(session, out.table_index); tbl != nil {
			out.total_rows = tbl.total_rows
			write_str(out.summary[:], &pos, table_name(tbl))
			write_str(out.summary[:], &pos, ": ")
			write_i64(out.summary[:], &pos, i64(tbl.row_count))
			write_str(out.summary[:], &pos, " of ")
			write_i64(out.summary[:], &pos, i64(tbl.total_rows))
			write_str(out.summary[:], &pos, " rows")
		}
	case .List:
		items := lex_evaluator.list_items_of(&session.evaluation, value)
		write_str(out.summary[:], &pos, "[")
		for item, idx in items {
			if idx > 0 {
				write_str(out.summary[:], &pos, ", ")
			}
			if pos >= len(out.summary) - 8 {
				write_str(out.summary[:], &pos, "...")
				break
			}
			switch item.kind {
			case .Integer:
				write_i64(out.summary[:], &pos, item.integer)
			case .Boolean:
				write_str(out.summary[:], &pos, item.integer != 0 ? "true" : "false")
			case .Text:
				write_str(out.summary[:], &pos, item.text)
			case .None, .Record, .Handle, .Table, .Bytes, .Stream, .Record_Input, .Record_Literal, .Enum, .Member, .Function, .List, .Hash, .Record_With, .Module_Ref, .Recipe_Ref, .Follow_Ref, .Store_Ref, .Plan_Value, .Project_Value, .Tree_Ref:
				write_str(out.summary[:], &pos, "?")
			}
		}
		write_str(out.summary[:], &pos, "]")
	case .None, .Handle, .Bytes, .Stream, .Record_Input, .Record_Literal, .Enum, .Member, .Function, .Hash, .Record_With, .Module_Ref, .Recipe_Ref, .Follow_Ref, .Store_Ref, .Plan_Value, .Project_Value, .Tree_Ref:
		write_str(out.summary[:], &pos, "ok")
	}
	out.summary_len = pos
}

// step_run executes 1..STEP_LINE_CAPACITY lines of Lex sequentially in
// session. Variable bindings persist across lines and across steps until
// session_reset_bindings is called. Every step, line, and read-only export
// call appends a BLAKE3 hash-chained wide_grants.Act_Record before running.
step_run :: proc "contextless" (session: ^Step_Session, lines: []string, transport: Step_Transport, eval_budget: u32 = lex_evaluator.EVALUATION_BUDGET_STEPS) -> (outcome: Step_Outcome) {
	if session == nil || len(lines) == 0 {
		outcome.refusal = .Empty_Step
		return outcome
	}
	if len(lines) > STEP_LINE_CAPACITY {
		outcome.refusal = .Too_Many_Lines
		return outcome
	}
	for line, idx in lines {
		if r := validate_line_text(line); r != .None {
			outcome.refusal = r
			outcome.failed_line = idx + 1
			return outcome
		}
	}

	session.transport = transport
	session.step_serial += 1
	session.step_start_ms = clock_now(session)
	session.step_calls_made = 0
	session.step_records_added = 0
	session.condition_count = 0

	// Fail-closed: record the step start before executing line 1.
	step_hash_word := u64(len(lines)) | (session.step_serial << 16)
	if !append_act_record(session, session.step_start_ms, .Call_Made, step_hash_word, u64(len(lines))) {
		outcome.refusal = .Act_Log_Full
		return outcome
	}

	host := lex_evaluator.Evaluation_Host {
		data            = session,
		name_value      = host_name_value,
		command_find    = host_command_find,
		call_run        = host_call_run,
		condition_value = host_condition_value,
		values_add      = host_values_add,
	}

	summary_bytes_used := 0
	for line, idx in lines {
		line_num := idx + 1
		if time_expired(session) {
			outcome.refusal = .Time_Bound_Exceeded
			outcome.failed_line = line_num
			outcome.calls_made = session.step_calls_made
			outcome.act_records_written = session.step_records_added
			return outcome
		}

		// Fail-closed: record each line in the BLAKE3 act chain before parsing/evaluating it.
		line_detail_0 := hash_head_u64(transmute([]u8)line)
		line_detail_1 := (session.step_serial << 16) | u64(line_num)
		if !append_act_record(session, clock_now(session), .Call_Made, line_detail_0, line_detail_1) {
			outcome.refusal = .Act_Log_Full
			outcome.failed_line = line_num
			outcome.calls_made = session.step_calls_made
			outcome.act_records_written = session.step_records_added
			return outcome
		}

		session.active_refusal = .None
		session.refused_command_len = 0

		// Desugar `|>` pipes before parsing (identical to console).
		expr_start := console_language.expression_start(line)
		pipe_form := console_language.pipe_nested_form(line, expr_start, session.nested_line[:], session.pipe_stages[:])
		if pipe_form.refusal != .None {
			outcome.refusal = .Pipe_Refused
			outcome.failed_line = line_num
			outcome.calls_made = session.step_calls_made
			outcome.act_records_written = session.step_records_added
			return outcome
		}
		nested := pipe_form.nested

		lex_parser.parse(nested, {form_of = parameter_form_of}, &session.tree)
		if session.tree.refusal.refusal != .None {
			outcome.refusal = .Parse_Refused
			outcome.failed_line = line_num
			outcome.calls_made = session.step_calls_made
			outcome.act_records_written = session.step_records_added
			return outcome
		}

		lex_evaluator.evaluation_start(&session.evaluation, &session.tree, .Console, host, eval_budget)
		val, ok := lex_evaluator.line_force(&session.evaluation)
		if !ok {
			outcome.refusal = session.active_refusal != .None ? session.active_refusal : .Evaluation_Refused
			outcome.failed_line = line_num
			outcome.calls_made = session.step_calls_made
			outcome.act_records_written = session.step_records_added
			outcome.refused_command = session.refused_command
			outcome.refused_command_len = session.refused_command_len
			return outcome
		}

		line_out := &outcome.lines[outcome.line_count]
		line_out^ = {line_index = line_num, table_index = -1}
		if len(session.tree.assigned_name) > 0 {
			if bind_err := bind_variable(session, session.tree.assigned_name, val); bind_err != .None {
				outcome.refusal = bind_err
				outcome.failed_line = line_num
				outcome.calls_made = session.step_calls_made
				outcome.act_records_written = session.step_records_added
				return outcome
			}
			line_out.assigned = true
			line_out.assigned_len = u8(copy(line_out.assigned_buf[:], session.tree.assigned_name))
		}
		summarize_value(session, val, line_out)
		if summary_bytes_used + line_out.summary_len > STEP_RESULT_TEXT_BYTES {
			room := max(STEP_RESULT_TEXT_BYTES - summary_bytes_used, 0)
			if line_out.summary_len > room {
				line_out.summary_len = text_encoding.complete_characters(line_out.summary[:room])
			}
			outcome.text_budget_exceeded = true
		}
		summary_bytes_used += line_out.summary_len
		outcome.line_count += 1
	}

	outcome.ok = true
	outcome.calls_made = session.step_calls_made
	outcome.act_records_written = session.step_records_added
	return outcome
}
