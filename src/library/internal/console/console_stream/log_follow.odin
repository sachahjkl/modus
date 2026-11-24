// Pure freestanding support for naming a module's implicit log record output
// in wire(server.log, collector.sources), parsing and lowering log.follow
// pipelines (log.follow |> where(level = Warning)), and breaking the
// self-feedback loop when the console draws log.follow
// (src/md/features/log_facts.md, "The frequent tasks").
//
// Self-feedback loop breaker:
// 1. Drawing any line of log.follow runs inside a Follow_Render_Guard that
//    suppresses echoing console output back into the kernel log
//    (echo_suppressed = true, output_logged = false).
// 2. log.follow defaults to include_self = false, excluding records
//    emitted by the following console's own process slot (both via a compiled
//    slot != own_process_slot wiring/reader filter and via direct slot check)
//    so even internal console diagnostics logged during a follow never enter a
//    runaway feedback loop.
//
// No allocator, no global state, no kernel calls.
package console_stream

import "base:intrinsics"
import "modus:console_condition"
import "modus:console_language"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/output"
import "modus:contract/text_encoding"
import "modus:contract/value_kinds"
import "modus:lex_parser"

// Typed names of the log service's live follow stream.
LOG_SERVICE_NAME :: "log"
LOG_FOLLOW_OUTPUT_NAME :: "follow"

// Maximum chained where(...) conditions lowered on one log.follow pipeline.
MAX_FOLLOW_CONDITIONS :: 4

// Exact byte size of log.Follow_Row (src/modules/system/log/follow.odin).
FOLLOW_ROW_SIZE :: 232

// Fixed stack buffer capacities for Follow_Row / Log_Output descriptions.
FOLLOW_ROW_DESCRIPTION_CAPACITY :: 2048
LOG_OUTPUT_DESCRIPTION_CAPACITY :: 2048
FOLLOW_PARSE_NODE_CAPACITY :: 128

// Wire layout matching log.Follow_Row byte-for-byte so host tests and the
// console share one canonical description without importing the log module.
Follow_Row_Wire :: struct {
	number:     i64,
	time:       i64,
	slot:       i64,
	process:    [32]u8,
	level:      op.Log_Level,
	form:       op.Log_Record_Form,
	continues:  u8,
	runs:       u8,
	text_count: u32,
	text:       [op.LOG_TEXT_CAPACITY]u8,
}
#assert(size_of(Follow_Row_Wire) == FOLLOW_ROW_SIZE)

// Closed set of refusals returned when parsing or lowering a log.follow line.
Log_Follow_Refusal :: enum u8 {
	None                 = 0,
	Malformed_Pipe       = 1,
	Not_Log_Follow       = 2,
	Unsupported_Stage    = 3,
	Too_Many_Conditions  = 4,
	Bad_Condition_Syntax = 5,
	Unknown_Field        = 6,
	No_Order             = 7,
	Member_Is_A_Name     = 8,
	Unknown_Member       = 9,
	Wrong_Kind           = 10,
	Out_Of_Range         = 11,
	Bad_Own_Slot         = 12,
	Trailing_Tokens      = 13,
}

// Self-contained lowered where(...) condition with no stack-buffer slice.
Log_Follow_Condition :: struct {
	field:       string, // Canonical Follow_Row field name from rodata.
	comparison:  console_condition.Comparison,
	compared:    i64,
	text_bytes:  [output.CONDITION_TEXT_BYTES_MOST]u8,
	text_length: u32,
}

// Lowered plan for following log.follow with validated where(...) conditions
// and structural self-feedback loop-breaker configuration.
Log_Follow_Plan :: struct {
	source_owner:         string,
	source_stream:        string,
	own_process_slot:     i64,
	include_self:         bool,
	echo_suppressed:      bool,
	has_self_slot_filter: bool,
	self_slot_terms:      output.Condition_Terms,
	self_slot_check:      output.Checked_Condition,
	condition_count:      int,
	conditions:           [MAX_FOLLOW_CONDITIONS]Log_Follow_Condition,
	terms:                [MAX_FOLLOW_CONDITIONS]output.Condition_Terms,
	checks:               [MAX_FOLLOW_CONDITIONS]output.Checked_Condition,
	has_wiring_condition: bool,
	wiring_terms:         output.Condition_Terms,
}

// Guard token paired with follow_render_begin / follow_render_end to suppress
// echoing log.follow drawn lines back into the console's own kernel log.
Follow_Render_Guard :: struct {
	active:              bool,
	saved_output_logged: bool,
}

// Closed set of decisions returned by follow_filter_record for each record.
Follow_Record_Decision :: enum u8 {
	Pass                 = 0,
	Suppressed_Self_Slot = 1,
	Suppressed_Self_Echo = 2,
	Filtered_Out         = 3,
	Bad_Record           = 4,
}

// Runtime self-feedback loop breaker for an active log.follow stream.
Follow_Loop_Breaker :: struct {
	own_process_slot:     i64,
	own_process_name:     string,
	include_self:         bool,
	echo_suppressed:      bool,
	render_depth:         u32,
	user_condition_count: int,
	user_checks:          [MAX_FOLLOW_CONDITIONS]output.Checked_Condition,
	has_self_slot_check:  bool,
	self_slot_check:      output.Checked_Condition,
	records_seen:         u64,
	records_passed:       u64,
	self_slot_suppressed: u64,
	self_echo_suppressed: u64,
	filtered_out:         u64,
	echo_writes_blocked:  u64,
}

// is_log_output_name reports whether owner.stream names the implicit log
// record output of a valid module/process owner.
is_log_output_name :: proc "contextless" (owner, stream: string) -> bool {
	return short_form_owner_valid(owner) && stream == LOG_STREAM_NAME
}

// is_log_follow_name reports whether owner.stream names log.follow.
is_log_follow_name :: proc "contextless" (owner, stream: string) -> bool {
	return owner == LOG_SERVICE_NAME && stream == LOG_FOLLOW_OUTPUT_NAME
}

// ---- Follow_Row canonical description file.

@(private = "file")
Follow_Row_Field :: struct {
	name:          string,
	offset:        u32,
	type:          module.Type,
	detail:        u32,
	unsigned:      bool,
	kind:          value_kinds.Field_Kind,
	contract_enum: value_kinds.Contract_Enum,
}

@(private = "file", rodata)
follow_row_fields := [?]Follow_Row_Field {
	{"number", u32(offset_of(Follow_Row_Wire, number)), .Integer, 0, false, .Plain, .None},
	{"time", u32(offset_of(Follow_Row_Wire, time)), .Integer, 0, false, .Plain, .None},
	{"slot", u32(offset_of(Follow_Row_Wire, slot)), .Integer, 0, false, .Plain, .None},
	{"process", u32(offset_of(Follow_Row_Wire, process)), .Text, 32, false, .Plain, .None},
	{"level", u32(offset_of(Follow_Row_Wire, level)), .Integer, u32(size_of(op.Log_Level)), true, .Status, .Log_Level},
	{"form", u32(offset_of(Follow_Row_Wire, form)), .Integer, u32(size_of(op.Log_Record_Form)), true, .Status, .Log_Record_Form},
	{"continues", u32(offset_of(Follow_Row_Wire, continues)), .Integer, 1, true, .Plain, .None},
	{"runs", u32(offset_of(Follow_Row_Wire, runs)), .Integer, 1, true, .Plain, .None},
	{"text_count", u32(offset_of(Follow_Row_Wire, text_count)), .Integer, 4, true, .Plain, .None},
	{"text", u32(offset_of(Follow_Row_Wire, text)), .Text, op.LOG_TEXT_CAPACITY, false, .Plain, .None},
}

FOLLOW_ROW_RECORD_NAME :: "Follow_Row"

// follow_row_description_write writes a canonical module description file for
// log.Follow_Row into into at output.DESCRIPTION_RECORD_INDEX (1).
follow_row_description_write :: proc "contextless" (into: []u8) -> (size: int, ok: bool) {
	directory_end := size_of(module.Header) + module.TABLE_COUNT * size_of(module.Table_Entry)
	records_at := directory_end
	fields_at := records_at + 2 * size_of(module.Record)
	strings_at := fields_at + (len(follow_row_fields) + 1) * size_of(module.Field)
	strings_count := 1 + len(FOLLOW_ROW_RECORD_NAME)
	for item in follow_row_fields {
		strings_count += len(item.name)
	}
	size = strings_at + strings_count
	if size > len(into) {
		return 0, false
	}
	intrinsics.mem_zero(raw_data(into), size)
	cursor := u32(1)
	copy(into[strings_at + int(cursor):], FOLLOW_ROW_RECORD_NAME)
	record := module.Record {
		name_offset = cursor,
		name_count  = u32(len(FOLLOW_ROW_RECORD_NAME)),
		size        = size_of(Follow_Row_Wire),
		first_field = 1,
		field_count = u32(len(follow_row_fields)),
	}
	cursor += u32(len(FOLLOW_ROW_RECORD_NAME))
	intrinsics.mem_copy_non_overlapping(&into[records_at + size_of(module.Record)], &record, size_of(record))
	for item, number in follow_row_fields {
		copy(into[strings_at + int(cursor):], item.name)
		field := module.Field {
			name_offset   = cursor,
			name_count    = u32(len(item.name)),
			offset        = item.offset,
			type          = u8(item.type),
			unsigned      = item.unsigned,
			detail        = item.detail,
			kind          = u8(item.kind),
			contract_enum = u8(item.contract_enum),
		}
		cursor += u32(len(item.name))
		intrinsics.mem_copy_non_overlapping(&into[fields_at + (number + 1) * size_of(module.Field)], &field, size_of(field))
	}
	directory: [module.TABLE_COUNT]module.Table_Entry
	directory[module.Table_Kind.Records] = {offset = u64(records_at), count = 2, record_size = size_of(module.Record)}
	directory[module.Table_Kind.Fields] = {offset = u64(fields_at), count = u32(len(follow_row_fields)) + 1, record_size = size_of(module.Field)}
	directory[module.Table_Kind.Strings] = {offset = u64(strings_at), count = u32(strings_count), record_size = 1}
	header := module.Header {
		magic       = module.MAGIC,
		version     = module.VERSION,
		header_size = size_of(module.Header),
		machine     = .X86_64,
		table_count = module.TABLE_COUNT,
	}
	intrinsics.mem_copy_non_overlapping(raw_data(into), &header, size_of(header))
	intrinsics.mem_copy_non_overlapping(&into[size_of(module.Header)], &directory, size_of(directory))
	return size, true
}

// ---- Direct wire(...) lowering supporting <module>.log.

// wire_descriptor_lower lowers typed endpoints from_name and to_name into
// a validated Short_Form_Wiring_Row. Directly supports naming a module's log
// output (e.g. wire(server.log, collector.sources)) with Writer_Stream.Log,
// writer_index = 0, and Audit/Always_Holds_Writer when wired to collector.
wire_descriptor_lower :: proc "contextless" (
	from_name: string,
	to_name: string,
	from_file: []u8 = nil,
	to_file: []u8 = nil,
	has_condition: bool = false,
	condition: output.Condition_Terms = {},
) -> (row: Short_Form_Wiring_Row, refusal: Short_Form_Refusal) {
	from_owner, from_stream, from_ok := typed_name_split(from_name)
	to_owner, to_input, to_ok := typed_name_split(to_name)
	if !from_ok || !to_ok ||
	   !short_form_owner_valid(from_owner) || !short_form_name_valid(from_stream) ||
	   !short_form_owner_valid(to_owner) || !short_form_name_valid(to_input) {
		return {}, .Invalid_Target
	}
	if from_owner == to_owner {
		return {}, .Cyclic_Self_Wiring
	}

	// Resolve source end: either implicit log or a declared record output.
	is_log := from_stream == LOG_STREAM_NAME
	writer_stream := output.Writer_Stream.Record_Output
	writer_index := u32(0)
	source_desc_file: []u8
	source_desc_detail := u32(0)
	log_desc_buf: [LOG_OUTPUT_DESCRIPTION_CAPACITY]u8

	if is_log {
		if has_condition {
			return {}, .Log_Not_Allowed
		}
		writer_stream = .Log
		writer_index = 0
		if desc_size, desc_ok := output.log_output_file_write(log_desc_buf[:]); desc_ok {
			source_desc_file = log_desc_buf[:desc_size]
			source_desc_detail = output.DESCRIPTION_RECORD_INDEX
		}
	} else {
		if len(from_file) > 0 {
			found_idx, found_rec, how := record_output_find(from_file, from_stream)
			switch how {
			case .Found:
				writer_index = found_idx
				source_desc_file = from_file
				source_desc_detail = found_rec
			case .Generic:
				return {}, .Generic_Output_Refused
			case .Damaged:
				return {}, .Damaged_Module
			case .Absent:
				return {}, .Invalid_Target
			}
		} else {
			writer_index = 1
		}
	}

	// Validate reader input against to_file when provided.
	if len(to_file) > 0 {
		_, input_rec, input_how := record_input_find(to_file, to_input)
		switch input_how {
		case .Found:
			if len(source_desc_file) > 0 && source_desc_detail != 0 {
				diff, _ := output.record_descriptions_compare(source_desc_file, source_desc_detail, to_file, input_rec)
				if diff != .Equal {
					return {}, .Record_Type_Mismatch
				}
			}
		case .Generic:
			// Generic record inputs (e.g. collector.sources) accept any record type.
		case .Damaged:
			return {}, .Damaged_Module
		case .Absent:
			return {}, .Invalid_Target
		}
	}

	built := Short_Form_Wiring_Row {
		source_owner  = from_owner,
		source_stream = from_stream,
		writer_stream = writer_stream,
		writer_index  = writer_index,
		target_owner  = to_owner,
		target_input  = to_input,
		pace          = .Writer_Chooses,
		has_condition = has_condition,
		condition     = condition,
	}
	if to_owner == COLLECTOR_MODULE_NAME {
		built.pace = .Always_Holds_Writer
		built.space_kind = .Audit
		built.space_block_limit = u64(AUDIT_BLOCK_LIMIT_DEFAULT)
	}
	if row_ref := short_form_row_validate(built); row_ref != .None {
		return {}, row_ref
	}
	return built, .None
}

// wire_expression_lower parses a wire(from.stream, to.input) console
// expression using console_language.token_next and lowers it into a validated
// Short_Form_Wiring_Row, refusing any malformed syntax or invalid endpoint.
wire_expression_lower :: proc "contextless" (
	text: string,
	from_file: []u8 = nil,
	to_file: []u8 = nil,
) -> (row: Short_Form_Wiring_Row, refusal: Short_Form_Refusal) {
	fn_tok := console_language.token_next(text, 0)
	if fn_tok.kind != .Name || text[fn_tok.start:fn_tok.end] != "wire" {
		return {}, .Invalid_Target
	}
	open_tok := console_language.token_next(text, fn_tok.end)
	if open_tok.kind != .Operator || text[open_tok.start] != '(' {
		return {}, .Invalid_Target
	}
	from_tok := console_language.token_next(text, open_tok.end)
	if from_tok.kind != .Name {
		return {}, .Invalid_Target
	}
	comma_tok := console_language.token_next(text, from_tok.end)
	if comma_tok.kind != .Operator || text[comma_tok.start] != ',' {
		return {}, .Invalid_Target
	}
	to_tok := console_language.token_next(text, comma_tok.end)
	if to_tok.kind != .Name {
		return {}, .Invalid_Target
	}
	close_tok := console_language.token_next(text, to_tok.end)
	if close_tok.kind != .Operator || text[close_tok.start] != ')' {
		return {}, .Invalid_Target
	}
	after_tok := console_language.token_next(text, close_tok.end)
	if after_tok.kind != .None {
		return {}, .Invalid_Target
	}
	return wire_descriptor_lower(
		text[from_tok.start:from_tok.end],
		text[to_tok.start:to_tok.end],
		from_file,
		to_file,
	)
}

// ---- log.follow parsing, condition lowering, and loop-breaker compilation.

@(private = "file")
canonical_follow_field_name :: proc "contextless" (name: string) -> (canonical: string, found: bool) {
	for item in follow_row_fields {
		if item.name == name {
			return item.name, true
		}
	}
	return "", false
}

@(private = "file")
follow_condition_compile :: proc "contextless" (
	desc_file: []u8,
	described: module.Record,
	text: string,
	cond_start: int,
	cond_end: int,
) -> (
	cond: Log_Follow_Condition,
	terms: output.Condition_Terms,
	checked: output.Checked_Condition,
	refusal: Log_Follow_Refusal,
) {
	slice := text[cond_start:cond_end]
	head, head_ref := console_condition.head_read(slice, 0)
	if head_ref != .None {
		return {}, {}, {}, .Bad_Condition_Syntax
	}

	item, field_found := console_condition.field_find(desc_file, described, head.field)
	if !field_found {
		return {}, {}, {}, .Unknown_Field
	}
	canonical_field, canonical_ok := canonical_follow_field_name(head.field)
	if !canonical_ok {
		return {}, {}, {}, .Unknown_Field
	}

	cond.field = canonical_field
	cond.comparison = head.comparison

	val_tok := console_language.token_next(slice, head.value_start)
	if val_tok.kind == .None {
		return {}, {}, {}, .Bad_Condition_Syntax
	}

	is_text := false
	raw_text_arg := ""
	which_enum, is_status := console_condition.field_is_status(item)
	switch {
	case item.type == u8(module.Type.Text):
		if head.comparison != .Equal && head.comparison != .Not_Equal {
			return {}, {}, {}, .No_Order
		}
		if val_tok.kind != .Text {
			return {}, {}, {}, .Wrong_Kind
		}
		trailing := console_language.token_next(slice, val_tok.end)
		if trailing.kind != .None {
			return {}, {}, {}, .Trailing_Tokens
		}
		raw_text := slice[val_tok.start + 1:val_tok.end - 1]
		if len(raw_text) > output.CONDITION_TEXT_BYTES_MOST || !text_encoding.text_valid(transmute([]u8)raw_text) {
			return {}, {}, {}, .Out_Of_Range
		}
		cond.text_length = u32(copy(cond.text_bytes[:], raw_text))
		raw_text_arg = raw_text
		is_text = true

	case is_status:
		if head.comparison != .Equal && head.comparison != .Not_Equal {
			return {}, {}, {}, .No_Order
		}
		member_word, _, member_end, member_ref := console_condition.member_read(slice, head.value_start, which_enum)
		switch member_ref {
		case .None:
		case .Member_Is_A_Name:
			return {}, {}, {}, .Member_Is_A_Name
		case .Unknown_Member:
			return {}, {}, {}, .Unknown_Member
		case .No_Field, .No_Operator, .Lone_Bang, .Double_Equal, .No_Value, .Unknown_Field, .Not_Comparable, .No_Order, .Wrong_Kind, .Negative_For_Unsigned, .Out_Of_Field, .Too_Many:
			return {}, {}, {}, .Bad_Condition_Syntax
		}
		trailing := console_language.token_next(slice, member_end)
		if trailing.kind != .None {
			return {}, {}, {}, .Trailing_Tokens
		}
		cond.compared = i64(member_word)

	case item.type == u8(module.Type.Integer):
		negative := false
		num_tok := val_tok
		if val_tok.kind == .Operator && slice[val_tok.start] == '-' {
			negative = true
			num_tok = console_language.token_next(slice, val_tok.end)
		}
		if num_tok.kind != .Number {
			return {}, {}, {}, .Wrong_Kind
		}
		trailing := console_language.token_next(slice, num_tok.end)
		if trailing.kind != .None {
			return {}, {}, {}, .Trailing_Tokens
		}
		parsed_val, fits := console_language.number_value(slice, num_tok.start, num_tok.end)
		if !fits {
			return {}, {}, {}, .Out_Of_Range
		}
		if negative {
			if item.unsigned {
				return {}, {}, {}, .Out_Of_Range
			}
			parsed_val = -parsed_val
		}
		if console_condition.value_check(item, .Integer, parsed_val) != .None {
			return {}, {}, {}, .Out_Of_Range
		}
		cond.compared = parsed_val

	case:
		return {}, {}, {}, .Wrong_Kind
	}

	terms_ok: bool
	terms, terms_ok = output.condition_terms_of_field(
		desc_file,
		described,
		cond.field,
		comparison_of(cond.comparison),
		cond.compared,
		raw_text_arg,
		is_text,
	)
	if !terms_ok {
		return {}, {}, {}, .Bad_Condition_Syntax
	}
	terms_bytes := transmute([size_of(output.Condition_Terms)]u8)terms
	resolved, _, resolved_ok := output.writer_condition_of_terms(terms_bytes[:], desc_file, described)
	if !resolved_ok {
		return {}, {}, {}, .Out_Of_Range
	}
	resolved_bytes := transmute([size_of(output.Writer_Condition)]u8)resolved
	checked_ok: bool
	checked, checked_ok = output.writer_condition_check(resolved_bytes[:], u32(described.size))
	if !checked_ok {
		return {}, {}, {}, .Out_Of_Range
	}
	return cond, terms, checked, .None
}

// build_self_slot_filter compiles slot != own_process_slot against
// Follow_Row using the contract condition pipeline.
@(private = "file")
build_self_slot_filter :: proc "contextless" (
	desc_file: []u8,
	described: module.Record,
	own_process_slot: i64,
) -> (terms: output.Condition_Terms, checked: output.Checked_Condition, ok: bool) {
	terms = output.condition_terms_of_field(desc_file, described, "slot", .Not_Equal, own_process_slot, "", false) or_return
	terms_bytes := transmute([size_of(output.Condition_Terms)]u8)terms
	resolved, _, resolved_ok := output.writer_condition_of_terms(terms_bytes[:], desc_file, described)
	if !resolved_ok {
		return {}, {}, false
	}
	resolved_bytes := transmute([size_of(output.Writer_Condition)]u8)resolved
	checked = output.writer_condition_check(resolved_bytes[:], u32(described.size)) or_return
	return terms, checked, true
}

@(private = "file")
follow_form_of :: proc "contextless" (data: rawptr, command_name: string, index: int) -> lex_parser.Parameter_Form {
	if command_name == "where" && index == 1 {
		return .Condition
	}
	return .Expression
}

// follow_call_cond_span locates the raw byte span of the condition argument
// inside a `where(...)` call starting at call_name_end, supporting both piped
// `where(cond)` (expected_commas = 0) and nested `where(inner, cond)` (1).
@(private = "file")
follow_call_cond_span :: proc "contextless" (text: string, call_name_end: int, nested: bool) -> (start, end: int, ok: bool) {
	open_tok := console_language.token_next(text, call_name_end)
	if open_tok.kind != .Operator || text[open_tok.start] != '(' {
		return 0, 0, false
	}
	depth := 1
	comma_pos := -1
	close_pos := -1
	for scan := console_language.token_next(text, open_tok.end); scan.kind != .None; scan = console_language.token_next(text, scan.end) {
		if scan.kind == .Operator {
			ch := text[scan.start]
			if ch == '(' || ch == '{' || ch == '[' {
				depth += 1
			} else if ch == ')' || ch == '}' || ch == ']' {
				depth -= 1
				if depth == 0 {
					close_pos = scan.start
					break
				}
			} else if ch == ',' && depth == 1 {
				if !nested || comma_pos >= 0 {
					return 0, 0, false
				}
				comma_pos = scan.start
			}
		}
	}
	if close_pos < 0 {
		return 0, 0, false
	}
	if nested {
		if comma_pos < 0 {
			return 0, 0, false
		}
		return comma_pos + 1, close_pos, true
	}
	return open_tok.end, close_pos, true
}

// log_follow_lower parses log.follow or log.follow |> where(...) ...
// (and its nested form where(log.follow, ...)), validates every condition
// against log.Follow_Row, and attaches the structural self-feedback loop
// breaker (echo suppression + default exclusion of own_process_slot).
log_follow_lower :: proc "contextless" (
	text: string,
	own_process_slot: i64,
	include_self: bool = false,
) -> (plan: Log_Follow_Plan, refusal: Log_Follow_Refusal) {
	if own_process_slot < 0 {
		return {}, .Bad_Own_Slot
	}
	if console_language.token_next(text, 0).kind == .None {
		return {}, .Not_Log_Follow
	}

	nodes: [FOLLOW_PARSE_NODE_CAPACITY]lex_parser.Ast_Node
	extra: [FOLLOW_PARSE_NODE_CAPACITY]lex_parser.Node_Index
	scratch: [FOLLOW_PARSE_NODE_CAPACITY]lex_parser.Node_Index
	int_consts: [16]i64
	conditions: [MAX_FOLLOW_CONDITIONS + 4]lex_parser.Condition_Extra
	storage := lex_parser.Tree_Storage {
		nodes            = nodes[:],
		extra_children   = extra[:],
		scratch_children = scratch[:],
		int_consts       = int_consts[:],
		conditions       = conditions[:],
	}
	tree: lex_parser.Syntax_Tree
	lex_parser.parse_with_storage(text, {form_of = follow_form_of}, storage, &tree, lex_parser.TEXT_BYTES_MOST, false, false, false, lex_parser.LINE_PARSE_DEPTH_LIMIT)

	switch tree.refusal.refusal {
	case .Pipe_No_Left, .Pipe_Line_End, .Pipe_Not_A_Call, .Lone_Bar,
	     .Placeholder_Not_Whole, .Placeholder_Twice, .Placeholder_Nested, .Placeholder_Without_Pipe:
		return {}, .Malformed_Pipe
	case .None, .Text_Too_Long, .Nodes_Full, .Line_Ends_Too_Soon, .Unexpected,
	     .Number_Too_Large, .Text_Without_End_Quote, .Close_Parenthesis_Missing,
	     .Comma_Or_Close_Missing, .Too_Many_Arguments, .Fact_Name_Missing,
	     .Condition_Head_Refused, .Field_Name_Missing, .Literal_Close_Missing,
	     .Literal_Name_Missing, .Literal_Equal_Missing, .Literal_Field_Twice,
	     .Named_Argument_Twice, .Positional_After_Named, .Let_Name_Missing,
	     .Let_Equal_Missing, .Let_In_Missing, .Let_Name_Twice, .Word_As_Name,
	     .Parameter_Name_Missing, .Parameter_Twice, .Too_Many_Parameters,
	     .List_Close_Missing, .Hash_Not_Valid, .If_Then_Missing, .If_Else_Missing,
	     .Nesting_Too_Deep, .Thin_Arrow,
	     .Escape_Not_Valid, .Interpolation_Close_Missing,
	     .Pattern_Field_Missing, .Pattern_Close_Missing,
	     .Pattern_Field_Twice, .Pattern_Rest_Not_Last, .Pattern_At_Missing_Brace:
	}

	desc_buf: [FOLLOW_ROW_DESCRIPTION_CAPACITY]u8
	desc_size, desc_ok := follow_row_description_write(desc_buf[:])
	if !desc_ok {
		return {}, .Bad_Condition_Syntax
	}
	desc_file := desc_buf[:desc_size]
	described, rec_ok := module.record_type(desc_file, output.DESCRIPTION_RECORD_INDEX)
	if !rec_ok {
		return {}, .Bad_Condition_Syntax
	}

	Cond_Span :: struct {
		start: int,
		end:   int,
	}
	spans: [MAX_FOLLOW_CONDITIONS]Cond_Span
	span_count := 0

	cur := tree.root
	has_top_trailing := false
	if rn := lex_parser.node_at(&tree, cur); rn != nil && rn.kind == .Refused {
		if lex_parser.node_refusal(&tree, cur) == .Unexpected && lex_parser.node_child(&tree, cur) != lex_parser.NO_NODE {
			has_top_trailing = true
			cur = lex_parser.node_child(&tree, cur)
		} else {
			return {}, .Not_Log_Follow
		}
	}

	// Peel chained `|> where(...)` and nested `where(inner, ...)` calls from
	// outermost to innermost, then compile conditions in pipeline order.
	for {
		n := lex_parser.node_at(&tree, cur)
		if n == nil {
			return {}, .Not_Log_Follow
		}
		#partial switch n.kind {
		case .Name:
			tok_name := lex_parser.node_text(&tree, cur)
			owner, stream, split_ok := typed_name_split(tok_name)
			if !split_ok || !is_log_follow_name(owner, stream) {
				return {}, .Not_Log_Follow
			}
			if has_top_trailing {
				return {}, .Trailing_Tokens
			}
			break
		case .Pipe:
			left, right := lex_parser.node_binary_children(&tree, cur)
			rn := lex_parser.node_at(&tree, right)
			if rn == nil || rn.kind != .Call {
				return {}, .Unsupported_Stage
			}
			call_name := lex_parser.node_text(&tree, right)
			if call_name != "where" {
				return {}, .Unsupported_Stage
			}
			if span_count >= MAX_FOLLOW_CONDITIONS {
				return {}, .Too_Many_Conditions
			}
			cstart, cend, span_ok := follow_call_cond_span(text, int(rn.b), false)
			if !span_ok {
				return {}, .Bad_Condition_Syntax
			}
			spans[span_count] = {start = cstart, end = cend}
			span_count += 1
			cur = left
			continue
		case .Call:
			call_name := lex_parser.node_text(&tree, cur)
			if call_name != "where" {
				return {}, .Unsupported_Stage
			}
			if span_count >= MAX_FOLLOW_CONDITIONS {
				return {}, .Too_Many_Conditions
			}
			args := lex_parser.node_children(&tree, cur)
			if len(args) < 1 {
				return {}, .Bad_Condition_Syntax
			}
			cstart, cend, span_ok := follow_call_cond_span(text, int(n.b), true)
			if !span_ok {
				return {}, .Bad_Condition_Syntax
			}
			spans[span_count] = {start = cstart, end = cend}
			span_count += 1
			cur = args[0]
			continue
		case:
			return {}, .Not_Log_Follow
		}
		break
	}

	plan = {
		source_owner     = LOG_SERVICE_NAME,
		source_stream    = LOG_FOLLOW_OUTPUT_NAME,
		own_process_slot = own_process_slot,
		include_self     = include_self,
		echo_suppressed  = true,
	}

	// Compile conditions in pipeline order (innermost first -> plan.conditions[0]).
	for idx := span_count - 1; idx >= 0; idx -= 1 {
		cond, terms, checked, cond_ref := follow_condition_compile(desc_file, described, text, spans[idx].start, spans[idx].end)
		if cond_ref != .None {
			return {}, cond_ref
		}
		out_idx := plan.condition_count
		plan.conditions[out_idx] = cond
		plan.terms[out_idx] = terms
		plan.checks[out_idx] = checked
		plan.condition_count += 1
	}

	// Attach source-process self-exclusion filter unless explicitly opted out.
	if !include_self && own_process_slot > 0 {
		self_terms, self_check, self_ok := build_self_slot_filter(desc_file, described, own_process_slot)
		if !self_ok {
			return {}, .Bad_Own_Slot
		}
		plan.has_self_slot_filter = true
		plan.self_slot_terms = self_terms
		plan.self_slot_check = self_check
	}

	// Wiring condition: first user where(...) condition if present, otherwise
	// push the self-slot exclusion directly into the log.follow writer ring.
	if plan.condition_count > 0 {
		plan.has_wiring_condition = true
		plan.wiring_terms = plan.terms[0]
	} else if plan.has_self_slot_filter {
		plan.has_wiring_condition = true
		plan.wiring_terms = plan.self_slot_terms
	}

	return plan, .None
}

// ---- Runtime self-feedback loop breaker.

// follow_loop_breaker_init builds a Follow_Loop_Breaker from a lowered
// Log_Follow_Plan.
follow_loop_breaker_init :: proc "contextless" (
	plan: ^Log_Follow_Plan,
	own_process_name: string = "console",
) -> (breaker: Follow_Loop_Breaker) {
	if plan == nil {
		return {}
	}
	breaker = {
		own_process_slot     = plan.own_process_slot,
		own_process_name     = own_process_name,
		include_self         = plan.include_self,
		user_condition_count = min(plan.condition_count, MAX_FOLLOW_CONDITIONS),
		user_checks          = plan.checks,
		has_self_slot_check  = plan.has_self_slot_filter,
		self_slot_check      = plan.self_slot_check,
	}
	return breaker
}

// follow_loop_breaker_make constructs a Follow_Loop_Breaker directly for the
// console when wiring log.follow through the console evaluator.
follow_loop_breaker_make :: proc "contextless" (
	own_process_slot: i64,
	include_self: bool = false,
	own_process_name: string = "console",
) -> (breaker: Follow_Loop_Breaker) {
	breaker = {
		own_process_slot = own_process_slot,
		own_process_name = own_process_name,
		include_self     = include_self,
	}
	if !include_self && own_process_slot > 0 {
		desc_buf: [FOLLOW_ROW_DESCRIPTION_CAPACITY]u8
		if desc_size, desc_ok := follow_row_description_write(desc_buf[:]); desc_ok {
			if described, rec_ok := module.record_type(desc_buf[:desc_size], output.DESCRIPTION_RECORD_INDEX); rec_ok {
				if _, self_check, self_ok := build_self_slot_filter(desc_buf[:desc_size], described, own_process_slot); self_ok {
					breaker.has_self_slot_check = true
					breaker.self_slot_check = self_check
				}
			}
		}
	}
	return breaker
}

// follow_render_begin enters a render guard for drawing a log.follow line
// (or head/note): suppresses echoing console output to the kernel log so no
// rendered line feeds back into log.follow.
follow_render_begin :: proc "contextless" (
	breaker: ^Follow_Loop_Breaker,
	output_logged: ^bool,
) -> (guard: Follow_Render_Guard) {
	if breaker == nil {
		return {}
	}
	guard.active = true
	if output_logged != nil {
		guard.saved_output_logged = output_logged^
		output_logged^ = false
	}
	breaker.render_depth += 1
	breaker.echo_suppressed = true
	return guard
}

// follow_render_end exits a render guard and restores output_logged once all
// nested follow render scopes close.
follow_render_end :: proc "contextless" (
	breaker: ^Follow_Loop_Breaker,
	guard: Follow_Render_Guard,
	output_logged: ^bool,
) {
	if breaker == nil || !guard.active {
		return
	}
	if breaker.render_depth > 0 {
		breaker.render_depth -= 1
	}
	if breaker.render_depth == 0 {
		breaker.echo_suppressed = false
	}
	if output_logged != nil {
		output_logged^ = guard.saved_output_logged
	}
}

// follow_should_emit_to_log reports whether a console output line may be
// echoed to the kernel log; returns false and increments echo_writes_blocked
// whenever a Follow_Render_Guard is active.
follow_should_emit_to_log :: proc "contextless" (breaker: ^Follow_Loop_Breaker) -> bool {
	if breaker != nil && (breaker.echo_suppressed || breaker.render_depth > 0) {
		breaker.echo_writes_blocked += 1
		return false
	}
	return true
}

// follow_filter_record decides whether a received log.follow record passes to
// the console renderer or is dropped by the self-feedback loop breaker or user
// where(...) conditions.
follow_filter_record :: proc "contextless" (
	breaker: ^Follow_Loop_Breaker,
	record: []u8,
	record_slot: i64,
	record_process: string = "",
	emitted_during_render: bool = false,
) -> Follow_Record_Decision {
	if breaker == nil {
		return .Bad_Record
	}
	breaker.records_seen += 1

	if emitted_during_render {
		breaker.self_echo_suppressed += 1
		return .Suppressed_Self_Echo
	}
	if len(record) > 0 && len(record) != FOLLOW_ROW_SIZE {
		return .Bad_Record
	}

	if !breaker.include_self {
		if breaker.own_process_slot > 0 {
			if record_slot == breaker.own_process_slot {
				breaker.self_slot_suppressed += 1
				return .Suppressed_Self_Slot
			}
			if breaker.has_self_slot_check && len(record) == FOLLOW_ROW_SIZE {
				if !output.writer_condition_holds(breaker.self_slot_check, record) {
					breaker.self_slot_suppressed += 1
					return .Suppressed_Self_Slot
				}
			}
		} else if len(breaker.own_process_name) > 0 && record_process == breaker.own_process_name {
			breaker.self_slot_suppressed += 1
			return .Suppressed_Self_Slot
		}
	}

	if len(record) == FOLLOW_ROW_SIZE {
		for idx in 0 ..< breaker.user_condition_count {
			if !output.writer_condition_holds(breaker.user_checks[idx], record) {
				breaker.filtered_out += 1
				return .Filtered_Out
			}
		}
	}

	breaker.records_passed += 1
	return .Pass
}
