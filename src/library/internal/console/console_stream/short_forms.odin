// Pure expansion of the record stream short forms into validated typed wiring
// lists (src/md/features/module_outputs.md, "The frequent tasks"):
//
// - `audit(target)`: one row for each declared record output of target plus
//   its `log`, to `collector.sources` with Audit terms and Always_Holds_Writer.
// - `audited(row)`: two rows interposing `collector` (`sources` with Audit +
//   forward, and `collector.forward` to the original reader input).
// - `keep(stream, limit)`: one row to `collector.sources` with Keep terms, a
//   validated block bound, optional condition, and Never_Holds_Writer.
// - `merge(a, b)` (and multi-source `merge`): rows from each distinct source
//   to `merge.sources`, plus `merge.merged` to the asker.
// - `collector.verify(space)`: validates a typed space target and confirms it
//   names an Audit space eligible for hash-chain verification.
//
// No state, no allocator, no kernel calls.
package console_stream

import module "modus:contract/module"
import "modus:contract/output"
import "modus:contract/wide_grants"

// Module and stream names referenced by short-form expansions.
COLLECTOR_MODULE_NAME :: "collector"
COLLECTOR_SOURCES_INPUT :: "sources"
COLLECTOR_FORWARD_OUTPUT :: "forward"
MERGE_MODULE_NAME :: "merge"
MERGE_SOURCES_INPUT :: "sources"
MERGE_MERGED_OUTPUT :: "merged"
LOG_STREAM_NAME :: "log"

// Name and capacity bounds enforced at expansion borders.
SHORT_FORM_NAME_LIMIT :: 32
KEEP_BLOCK_LIMIT_LEAST :: i64(1)
KEEP_BLOCK_LIMIT_DEFAULT :: i64(1024)
KEEP_BLOCK_LIMIT_MOST :: i64(1 << 20)
AUDIT_BLOCK_LIMIT_DEFAULT :: i64(4096)
MERGE_SOURCE_LEAST :: 2
MERGE_SOURCE_MOST :: output.WIRINGS_OF_AN_ASKER_MOST - 1

// Closed set of short-form operations.
Short_Form_Kind :: enum u8 {
	None             = 0,
	Audit            = 1,
	Audited          = 2,
	Keep             = 3,
	Merge            = 4,
	Collector_Verify = 5,
}

// Closed set of refusals returned by short-form expansion and validation.
Short_Form_Refusal :: enum u8 {
	None                   = 0,
	Invalid_Target         = 1,
	Damaged_Module         = 2,
	Generic_Output_Refused = 3,
	Cyclic_Self_Wiring     = 4,
	Cyclic_Self_Merge      = 5,
	Duplicate_Source       = 6,
	Record_Type_Mismatch   = 7,
	Limit_Out_Of_Bounds    = 8,
	Log_Not_Allowed        = 9,
	Too_Few_Sources        = 10,
	Too_Many_Rows          = 11,
	Not_Audit_Space        = 12,
	Space_Not_Found        = 13,
}

// One typed stream source passed to keep or merge.
Stream_Source_Ref :: struct {
	owner:         string,
	stream:        string,
	writer_stream: output.Writer_Stream,
	writer_index:  u32,
	file:          []u8, // Optional module file of owner for metadata and type checks.
	record_detail: u32, // Optional record description index in file.
	has_condition: bool,
	condition:     output.Condition_Terms,
}

// One validated wiring row produced by a short-form expansion.
Short_Form_Wiring_Row :: struct {
	source_owner:      string,
	source_stream:     string,
	writer_stream:     output.Writer_Stream,
	writer_index:      u32,
	target_owner:      string,
	target_input:      string,
	reader_is_asker:   bool,
	pace:              output.Wiring_Pace,
	space_kind:        wide_grants.Collector_Space_Kind,
	space_block_limit: u64,
	forward:           bool,
	has_condition:     bool,
	condition:         output.Condition_Terms,
}

// Fixed-capacity wiring list produced by a short-form expansion.
Short_Form_Wiring_List :: struct {
	form:      Short_Form_Kind,
	row_count: int,
	rows:      [output.WIRING_LIST_ROW_LIMIT]Short_Form_Wiring_Row,
}

// One known space reported by collector.spaces() for resolving collector.verify.
Collector_Space_Info :: struct {
	space_id:     u64,
	source_owner: string,
	stream_name:  string,
	kind:         wide_grants.Collector_Space_Kind,
}

// Validated request produced by collector.verify(space).
Collector_Verify_Plan :: struct {
	source_owner: string,
	stream_name:  string,
	is_log:       bool,
	space_id:     u64,
	space_kind:   wide_grants.Collector_Space_Kind,
}

// short_form_name_valid reports whether name is a non-empty ASCII identifier
// within SHORT_FORM_NAME_LIMIT with no dot or path separator.
short_form_name_valid :: proc "contextless" (name: string) -> bool {
	if len(name) == 0 || len(name) > SHORT_FORM_NAME_LIMIT {
		return false
	}
	for idx in 0 ..< len(name) {
		ch := name[idx]
		letter := (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch == '_'
		digit := ch >= '0' && ch <= '9'
		if idx == 0 {
			if !letter {
				return false
			}
		} else if !letter && !digit {
			return false
		}
	}
	return true
}

// block_limit_valid checks that a space block limit is within the closed range
// KEEP_BLOCK_LIMIT_LEAST ..= KEEP_BLOCK_LIMIT_MOST.
@(private = "file")
block_limit_valid :: proc "contextless" (limit: i64) -> bool {
	return limit >= KEEP_BLOCK_LIMIT_LEAST && limit <= KEEP_BLOCK_LIMIT_MOST
}

// validate_source_against_file verifies a Stream_Source_Ref when a module file
// is attached, returning its resolved record index.
@(private = "file")
validate_source_against_file :: proc "contextless" (source: Stream_Source_Ref) -> (record_index: u32, refusal: Short_Form_Refusal) {
	if len(source.file) == 0 {
		return source.record_detail, .None
	}
	found_index, found_record, how := record_output_find(source.file, source.stream)
	switch how {
	case .Found:
		if found_index != source.writer_index {
			return 0, .Invalid_Target
		}
		if source.record_detail != 0 && source.record_detail != found_record {
			return 0, .Invalid_Target
		}
		return found_record, .None
	case .Generic:
		return 0, .Generic_Output_Refused
	case .Damaged:
		return 0, .Damaged_Module
	case .Absent:
		return 0, .Invalid_Target
	}
	return 0, .Invalid_Target
}

// short_form_row_validate checks all structural invariants of one expanded row.
short_form_row_validate :: proc "contextless" (row: Short_Form_Wiring_Row) -> Short_Form_Refusal {
	if !short_form_name_valid(row.source_owner) || !short_form_name_valid(row.source_stream) {
		return .Invalid_Target
	}
	if !row.reader_is_asker {
		if !short_form_name_valid(row.target_owner) || !short_form_name_valid(row.target_input) {
			return .Invalid_Target
		}
		if row.source_owner == row.target_owner {
			return .Cyclic_Self_Wiring
		}
	}
	switch row.writer_stream {
	case .None:
		return .Invalid_Target
	case .Record_Output:
		if row.writer_index == 0 || row.writer_index > module.RECORD_STREAM_INDEX_MOST {
			return .Invalid_Target
		}
	case .Log:
		if row.writer_index != 0 || row.source_stream != LOG_STREAM_NAME {
			return .Invalid_Target
		}
		if row.pace == .Never_Holds_Writer || row.has_condition {
			return .Log_Not_Allowed
		}
	}
	if !row.reader_is_asker && row.target_owner == COLLECTOR_MODULE_NAME {
		if row.space_kind == .None || !block_limit_valid(i64(row.space_block_limit)) {
			return .Limit_Out_Of_Bounds
		}
	}
	return .None
}

// short_form_audit expands `audit(target)` into one Audit wiring row for each
// declared record output of target plus one row for target.log, all wired to
// `collector.sources` with pace Always_Holds_Writer.
short_form_audit :: proc "contextless" (
	target_name: string,
	target_file: []u8,
	block_limit: i64 = AUDIT_BLOCK_LIMIT_DEFAULT,
) -> (list: Short_Form_Wiring_List, refusal: Short_Form_Refusal) {
	if !short_form_name_valid(target_name) || len(target_file) == 0 {
		return {}, .Invalid_Target
	}
	if target_name == COLLECTOR_MODULE_NAME {
		return {}, .Cyclic_Self_Wiring
	}
	if !block_limit_valid(block_limit) {
		return {}, .Limit_Out_Of_Bounds
	}
	// Check raw table count before capping so an oversized table is refused.
	raw_rows := module.count(target_file, .Record_Outputs)
	declared_count: u32 = raw_rows > 1 ? raw_rows - 1 : 0
	if declared_count > module.RECORD_STREAM_INDEX_MOST {
		return {}, .Damaged_Module
	}
	if int(declared_count) + 1 > output.WIRING_LIST_ROW_LIMIT {
		return {}, .Too_Many_Rows
	}

	built: Short_Form_Wiring_List
	built.form = .Audit
	for row_index in u32(1) ..= declared_count {
		out_rec, pairing, _, ok := module.record_output(target_file, row_index)
		if !ok {
			return {}, .Damaged_Module
		}
		if out_rec.record == 0 || pairing == .Paired {
			return {}, .Generic_Output_Refused
		}
		out_name := module.string_at(target_file, out_rec.name_offset, out_rec.name_count)
		if !short_form_name_valid(out_name) || out_name == LOG_STREAM_NAME {
			return {}, .Damaged_Module
		}
		built.rows[built.row_count] = {
			source_owner      = target_name,
			source_stream     = out_name,
			writer_stream     = .Record_Output,
			writer_index      = row_index,
			target_owner      = COLLECTOR_MODULE_NAME,
			target_input      = COLLECTOR_SOURCES_INPUT,
			pace              = .Always_Holds_Writer,
			space_kind        = .Audit,
			space_block_limit = u64(block_limit),
		}
		built.row_count += 1
	}

	// Always include the process record output `log`.
	built.rows[built.row_count] = {
		source_owner      = target_name,
		source_stream     = LOG_STREAM_NAME,
		writer_stream     = .Log,
		writer_index      = 0,
		target_owner      = COLLECTOR_MODULE_NAME,
		target_input      = COLLECTOR_SOURCES_INPUT,
		pace              = .Always_Holds_Writer,
		space_kind        = .Audit,
		space_block_limit = u64(block_limit),
	}
	built.row_count += 1
	return built, .None
}

// short_form_audited expands `audited(wire(src, dst))` into two rows:
//   1. src -> collector.sources (Audit, forward = true, Always_Holds_Writer)
//   2. collector.forward -> dst (Always_Holds_Writer)
short_form_audited :: proc "contextless" (
	row: Short_Form_Wiring_Row,
	block_limit: i64 = AUDIT_BLOCK_LIMIT_DEFAULT,
) -> (list: Short_Form_Wiring_List, refusal: Short_Form_Refusal) {
	if row.reader_is_asker {
		return {}, .Invalid_Target
	}
	if !short_form_name_valid(row.source_owner) || !short_form_name_valid(row.source_stream) ||
	   !short_form_name_valid(row.target_owner) || !short_form_name_valid(row.target_input) {
		return {}, .Invalid_Target
	}
	if row.source_owner == row.target_owner ||
	   row.source_owner == COLLECTOR_MODULE_NAME ||
	   row.target_owner == COLLECTOR_MODULE_NAME {
		return {}, .Cyclic_Self_Wiring
	}
	if row.writer_stream == .Log || row.source_stream == LOG_STREAM_NAME {
		return {}, .Log_Not_Allowed
	}
	if row.writer_stream != .Record_Output || row.writer_index == 0 || row.writer_index > module.RECORD_STREAM_INDEX_MOST {
		return {}, .Invalid_Target
	}
	if !block_limit_valid(block_limit) {
		return {}, .Limit_Out_Of_Bounds
	}

	built: Short_Form_Wiring_List
	built.form = .Audited
	built.row_count = 2
	built.rows[0] = {
		source_owner      = row.source_owner,
		source_stream     = row.source_stream,
		writer_stream     = .Record_Output,
		writer_index      = row.writer_index,
		target_owner      = COLLECTOR_MODULE_NAME,
		target_input      = COLLECTOR_SOURCES_INPUT,
		pace              = .Always_Holds_Writer,
		space_kind        = .Audit,
		space_block_limit = u64(block_limit),
		forward           = true,
		has_condition     = row.has_condition,
		condition         = row.condition,
	}
	built.rows[1] = {
		source_owner  = COLLECTOR_MODULE_NAME,
		source_stream = COLLECTOR_FORWARD_OUTPUT,
		writer_stream = .Record_Output,
		writer_index  = 1,
		target_owner  = row.target_owner,
		target_input  = row.target_input,
		pace          = .Always_Holds_Writer,
		space_kind    = .None,
		forward       = false,
	}
	return built, .None
}

// short_form_keep expands `keep(stream, limit)` into one Keep wiring row to
// `collector.sources` with pace Never_Holds_Writer and the validated block limit.
short_form_keep :: proc "contextless" (
	source: Stream_Source_Ref,
	block_limit: i64 = KEEP_BLOCK_LIMIT_DEFAULT,
) -> (list: Short_Form_Wiring_List, refusal: Short_Form_Refusal) {
	if !block_limit_valid(block_limit) {
		return {}, .Limit_Out_Of_Bounds
	}
	if !short_form_name_valid(source.owner) || !short_form_name_valid(source.stream) {
		return {}, .Invalid_Target
	}
	if source.owner == COLLECTOR_MODULE_NAME {
		return {}, .Cyclic_Self_Wiring
	}
	if source.writer_stream == .Log || source.stream == LOG_STREAM_NAME {
		return {}, .Log_Not_Allowed
	}
	if source.writer_stream != .Record_Output || source.writer_index == 0 || source.writer_index > module.RECORD_STREAM_INDEX_MOST {
		return {}, .Invalid_Target
	}
	if _, file_refusal := validate_source_against_file(source); file_refusal != .None {
		return {}, file_refusal
	}

	built: Short_Form_Wiring_List
	built.form = .Keep
	built.row_count = 1
	built.rows[0] = {
		source_owner      = source.owner,
		source_stream     = source.stream,
		writer_stream     = .Record_Output,
		writer_index      = source.writer_index,
		target_owner      = COLLECTOR_MODULE_NAME,
		target_input      = COLLECTOR_SOURCES_INPUT,
		pace              = .Never_Holds_Writer,
		space_kind        = .Keep,
		space_block_limit = u64(block_limit),
		has_condition     = source.has_condition,
		condition         = source.condition,
	}
	return built, .None
}

// short_form_merge expands `merge(a, b)` into validated wiring rows into
// `merge.sources` plus (when wire_to_asker is true) `merge.merged` to asker.
short_form_merge :: proc "contextless" (
	a, b: Stream_Source_Ref,
	wire_to_asker: bool = true,
) -> (list: Short_Form_Wiring_List, refusal: Short_Form_Refusal) {
	pair := [2]Stream_Source_Ref{a, b}
	return short_form_merge_many(pair[:], wire_to_asker)
}

// short_form_merge_many expands a multi-source merge into validated wiring
// rows, refusing fewer than 2 sources, too many sources, cyclic self-merges
// (`merge` as a source), duplicate sources, `log` streams, invalid targets,
// and mismatched record descriptions.
short_form_merge_many :: proc "contextless" (
	sources: []Stream_Source_Ref,
	wire_to_asker: bool = true,
) -> (list: Short_Form_Wiring_List, refusal: Short_Form_Refusal) {
	if len(sources) < MERGE_SOURCE_LEAST {
		return {}, .Too_Few_Sources
	}
	if len(sources) > MERGE_SOURCE_MOST {
		return {}, .Too_Many_Rows
	}

	first_file: []u8
	first_record: u32
	built: Short_Form_Wiring_List
	built.form = .Merge

	for source, idx in sources {
		if !short_form_name_valid(source.owner) || !short_form_name_valid(source.stream) {
			return {}, .Invalid_Target
		}
		if source.owner == MERGE_MODULE_NAME {
			return {}, .Cyclic_Self_Merge
		}
		if source.writer_stream == .Log || source.stream == LOG_STREAM_NAME {
			return {}, .Log_Not_Allowed
		}
		if source.writer_stream != .Record_Output || source.writer_index == 0 || source.writer_index > module.RECORD_STREAM_INDEX_MOST {
			return {}, .Invalid_Target
		}
		rec_detail, file_refusal := validate_source_against_file(source)
		if file_refusal != .None {
			return {}, file_refusal
		}
		for earlier_idx in 0 ..< idx {
			earlier := sources[earlier_idx]
			if earlier.owner == source.owner && (earlier.stream == source.stream || earlier.writer_index == source.writer_index) {
				return {}, .Duplicate_Source
			}
		}
		if len(source.file) > 0 && rec_detail != 0 {
			if len(first_file) == 0 {
				first_file = source.file
				first_record = rec_detail
			} else {
				diff, _ := output.record_descriptions_compare(first_file, first_record, source.file, rec_detail)
				if diff != .Equal {
					return {}, .Record_Type_Mismatch
				}
			}
		}

		built.rows[built.row_count] = {
			source_owner  = source.owner,
			source_stream = source.stream,
			writer_stream = .Record_Output,
			writer_index  = source.writer_index,
			target_owner  = MERGE_MODULE_NAME,
			target_input  = MERGE_SOURCES_INPUT,
			pace          = .Writer_Chooses,
			has_condition = source.has_condition,
			condition     = source.condition,
		}
		built.row_count += 1
	}

	if wire_to_asker {
		built.rows[built.row_count] = {
			source_owner    = MERGE_MODULE_NAME,
			source_stream   = MERGE_MERGED_OUTPUT,
			writer_stream   = .Record_Output,
			writer_index    = 1,
			reader_is_asker = true,
			pace            = .Writer_Chooses,
		}
		built.row_count += 1
	}
	return built, .None
}

// short_form_rows_same_edge reports whether two wiring rows connect the exact
// same source stream and target endpoint.
@(private = "file")
short_form_rows_same_edge :: proc "contextless" (a, b: Short_Form_Wiring_Row) -> bool {
	if a.source_owner != b.source_owner || a.source_stream != b.source_stream {
		return false
	}
	if a.reader_is_asker != b.reader_is_asker {
		return false
	}
	if a.reader_is_asker {
		return true
	}
	return a.target_owner == b.target_owner && a.target_input == b.target_input
}

// short_form_list_sum combines two validated wiring lists (corresponding to
// `a + b` in Lex), refusing invalid counts, overflow past WIRING_LIST_ROW_LIMIT,
// invalid rows, or duplicate identical edges.
short_form_list_sum :: proc "contextless" (left, right: ^Short_Form_Wiring_List) -> (combined: Short_Form_Wiring_List, refusal: Short_Form_Refusal) {
	if left == nil || right == nil || left.row_count < 0 || right.row_count < 0 {
		return {}, .Invalid_Target
	}
	if left.row_count > output.WIRING_LIST_ROW_LIMIT || right.row_count > output.WIRING_LIST_ROW_LIMIT {
		return {}, .Too_Many_Rows
	}
	if left.row_count + right.row_count > output.WIRING_LIST_ROW_LIMIT {
		return {}, .Too_Many_Rows
	}
	built: Short_Form_Wiring_List
	for i in 0 ..< left.row_count {
		if r := short_form_row_validate(left.rows[i]); r != .None {
			return {}, r
		}
		for j in 0 ..< built.row_count {
			if short_form_rows_same_edge(built.rows[j], left.rows[i]) {
				return {}, .Duplicate_Source
			}
		}
		built.rows[built.row_count] = left.rows[i]
		built.row_count += 1
	}
	for i in 0 ..< right.row_count {
		if r := short_form_row_validate(right.rows[i]); r != .None {
			return {}, r
		}
		for j in 0 ..< built.row_count {
			if short_form_rows_same_edge(built.rows[j], right.rows[i]) {
				return {}, .Duplicate_Source
			}
		}
		built.rows[built.row_count] = right.rows[i]
		built.row_count += 1
	}
	return built, .None
}

// short_form_collector_verify validates `collector.verify(space)` from a typed
// name ("server.requests" or "server.log"). Refuses malformed names, self-audit
// of collector, missing/damaged declared outputs when owner_file is supplied,
// absent spaces when known_spaces is supplied, and Keep spaces (only Audit
// spaces carry a BLAKE3 segment hash chain).
short_form_collector_verify :: proc "contextless" (
	space_name: string,
	known_spaces: []Collector_Space_Info = nil,
	owner_file: []u8 = nil,
) -> (plan: Collector_Verify_Plan, refusal: Short_Form_Refusal) {
	owner, stream, split_ok := typed_name_split(space_name)
	if !split_ok || !short_form_name_valid(owner) || !short_form_name_valid(stream) {
		return {}, .Invalid_Target
	}
	if owner == COLLECTOR_MODULE_NAME {
		return {}, .Cyclic_Self_Wiring
	}

	is_log := stream == LOG_STREAM_NAME
	if !is_log && len(owner_file) > 0 {
		_, _, how := record_output_find(owner_file, stream)
		switch how {
		case .Found:
		case .Generic:
			return {}, .Generic_Output_Refused
		case .Damaged:
			return {}, .Damaged_Module
		case .Absent:
			return {}, .Invalid_Target
		}
	}

	if len(known_spaces) > 0 {
		found := false
		matched: Collector_Space_Info
		for space in known_spaces {
			if space.source_owner == owner && space.stream_name == stream {
				found = true
				matched = space
				break
			}
		}
		if !found {
			return {}, .Space_Not_Found
		}
		if matched.kind != .Audit {
			return {}, .Not_Audit_Space
		}
		return {
			source_owner = owner,
			stream_name  = stream,
			is_log       = is_log,
			space_id     = matched.space_id,
			space_kind   = .Audit,
		}, .None
	}

	return {
		source_owner = owner,
		stream_name  = stream,
		is_log       = is_log,
		space_kind   = .Audit,
	}, .None
}
