#+build !freestanding
package console_stream

import "core:testing"
import module "modus:contract/module"
import "modus:contract/output"
import "modus:contract/wide_grants"

@(private = "file")
SF_Test_File :: struct {
	records: [dynamic]module.Record,
	fields:  [dynamic]module.Field,
	strings: [dynamic]u8,
	outputs: [dynamic]module.Record_Output,
}

@(private = "file")
SF_COUNTED :: u32(1)
@(private = "file")
SF_OTHER :: u32(2)

@(private = "file")
sf_str_add :: proc(table: ^[dynamic]u8, text: string) -> (offset, count: u32) {
	offset = u32(len(table))
	append(table, text)
	return offset, u32(len(text))
}

@(private = "file")
sf_base_parts :: proc() -> (parts: SF_Test_File) {
	parts.records = make([dynamic]module.Record, context.temp_allocator)
	parts.fields = make([dynamic]module.Field, context.temp_allocator)
	parts.strings = make([dynamic]u8, context.temp_allocator)
	parts.outputs = make([dynamic]module.Record_Output, context.temp_allocator)
	append(&parts.strings, 0)
	append(&parts.records, module.Record{})
	append(&parts.fields, module.Field{})
	append(&parts.outputs, module.Record_Output{})

	// Record 1: Counted (16 bytes: serial, status)
	n1_off, n1_cnt := sf_str_add(&parts.strings, "Counted")
	f1_off, f1_cnt := sf_str_add(&parts.strings, "serial")
	f2_off, f2_cnt := sf_str_add(&parts.strings, "status")
	first_f := u32(len(parts.fields))
	append(&parts.fields, module.Field{name_offset = f1_off, name_count = f1_cnt, offset = 0, type = u8(module.Type.Integer), unsigned = true})
	append(&parts.fields, module.Field{name_offset = f2_off, name_count = f2_cnt, offset = 8, type = u8(module.Type.Integer), unsigned = true})
	append(&parts.records, module.Record{name_offset = n1_off, name_count = n1_cnt, size = 16, first_field = first_f, field_count = 2})

	// Record 2: Other (8 bytes: serial)
	n2_off, n2_cnt := sf_str_add(&parts.strings, "Other")
	first_f2 := u32(len(parts.fields))
	append(&parts.fields, module.Field{name_offset = f1_off, name_count = f1_cnt, offset = 0, type = u8(module.Type.Integer), unsigned = true})
	append(&parts.records, module.Record{name_offset = n2_off, name_count = n2_cnt, size = 8, first_field = first_f2, field_count = 1})
	return parts
}

@(private = "file")
sf_add_output :: proc(parts: ^SF_Test_File, name: string, record: u32, pairing: module.Record_Output_Pairing = .Unpaired) {
	about_off, about_cnt := sf_str_add(&parts.strings, "Help line.")
	name_off, name_cnt := sf_str_add(&parts.strings, name)
	append(&parts.outputs, module.Record_Output{
		name_offset  = name_off,
		name_count   = name_cnt,
		about_offset = about_off,
		about_count  = about_cnt,
		text_offset  = about_off,
		text_count   = about_cnt,
		record       = record,
		pairing      = u8(pairing),
	})
}

@(private = "file")
sf_bytes_of :: proc(items: []$T) -> []u8 {
	return ([^]u8)(raw_data(items))[:len(items) * size_of(T)]
}

@(private = "file")
sf_build_file :: proc(parts: SF_Test_File) -> []u8 {
	file := make([dynamic]u8, size_of(module.Header) + module.TABLE_COUNT * size_of(module.Table_Entry), context.temp_allocator)
	directory: [module.TABLE_COUNT]module.Table_Entry
	add :: proc(file: ^[dynamic]u8, directory: ^[module.TABLE_COUNT]module.Table_Entry, kind: module.Table_Kind, bytes: []u8, count, record_size: u32) {
		for len(file) % 8 != 0 {
			append(file, 0)
		}
		directory[kind] = {offset = u64(len(file)), count = count, record_size = record_size}
		append(file, ..bytes)
	}
	add(&file, &directory, .Records, sf_bytes_of(parts.records[:]), u32(len(parts.records)), size_of(module.Record))
	add(&file, &directory, .Fields, sf_bytes_of(parts.fields[:]), u32(len(parts.fields)), size_of(module.Field))
	add(&file, &directory, .Strings, parts.strings[:], u32(len(parts.strings)), 1)
	add(&file, &directory, .Record_Outputs, sf_bytes_of(parts.outputs[:]), u32(len(parts.outputs)), size_of(module.Record_Output))
	(^module.Header)(&file[0])^ = {magic = module.MAGIC, version = module.VERSION, header_size = size_of(module.Header), machine = .X86_64, table_count = module.TABLE_COUNT}
	(^[module.TABLE_COUNT]module.Table_Entry)(&file[size_of(module.Header)])^ = directory
	return file[:]
}

@(private = "file")
sf_server_file :: proc() -> []u8 {
	parts := sf_base_parts()
	sf_add_output(&parts, "metrics", SF_COUNTED)
	sf_add_output(&parts, "requests", SF_COUNTED)
	return sf_build_file(parts)
}

@(private = "file")
sf_other_file :: proc() -> []u8 {
	parts := sf_base_parts()
	sf_add_output(&parts, "events", SF_OTHER)
	return sf_build_file(parts)
}

// audit(target): refuses invalid targets, cyclic self-audit of collector,
// out-of-bounds limits, generic/paired outputs, damaged rows, and row overflow;
// expands a valid module into one Audit row per declared output plus log.
@(test)
short_form_audit_refusals_and_expansion :: proc(t: ^testing.T) {
	server_file := sf_server_file()

	// Invalid target names and empty file.
	for bad_name in ([?]string{"", "1server", "a.b", "a/b", "a-b", "name_that_exceeds_thirty_two_bytes"}) {
		list, refusal := short_form_audit(bad_name, server_file)
		testing.expectf(t, refusal == .Invalid_Target && list.row_count == 0, "name %q gave %v", bad_name, refusal)
	}
	_, refusal := short_form_audit("server", nil)
	testing.expect_value(t, refusal, Short_Form_Refusal.Invalid_Target)

	// Cyclic self-audit of collector.
	_, refusal = short_form_audit("collector", server_file)
	testing.expect_value(t, refusal, Short_Form_Refusal.Cyclic_Self_Wiring)

	// Out-of-bounds block limits.
	for bad_limit in ([?]i64{min(i64), -1, 0, KEEP_BLOCK_LIMIT_MOST + 1, max(i64)}) {
		_, refusal = short_form_audit("server", server_file, bad_limit)
		testing.expectf(t, refusal == .Limit_Out_Of_Bounds, "limit %d gave %v", bad_limit, refusal)
	}

	// Generic output refused.
	generic_parts := sf_base_parts()
	sf_add_output(&generic_parts, "mixed", 0)
	_, refusal = short_form_audit("server", sf_build_file(generic_parts))
	testing.expect_value(t, refusal, Short_Form_Refusal.Generic_Output_Refused)

	// Damaged output row refused.
	damaged_parts := sf_base_parts()
	sf_add_output(&damaged_parts, "requests", SF_COUNTED)
	damaged_parts.outputs[1].reserved[0] = 1
	_, refusal = short_form_audit("server", sf_build_file(damaged_parts))
	testing.expect_value(t, refusal, Short_Form_Refusal.Damaged_Module)

	// Too many outputs (32 declared + 1 log = 33 > WIRING_LIST_ROW_LIMIT).
	many_parts := sf_base_parts()
	for i in 0 ..< output.WIRING_LIST_ROW_LIMIT {
		name_buf := [4]u8{'o', '_', u8('a' + i / 26), u8('a' + i % 26)}
		sf_add_output(&many_parts, string(name_buf[:]), SF_COUNTED)
	}
	_, refusal = short_form_audit("server", sf_build_file(many_parts))
	testing.expect_value(t, refusal, Short_Form_Refusal.Too_Many_Rows)

	// Module with zero declared outputs still audits its `log` stream.
	empty_parts := sf_base_parts()
	empty_list, empty_ref := short_form_audit("quiet", sf_build_file(empty_parts))
	testing.expect_value(t, empty_ref, Short_Form_Refusal.None)
	testing.expect_value(t, empty_list.row_count, 1)
	testing.expect(t, empty_list.rows[0].writer_stream == .Log && empty_list.rows[0].source_stream == "log")
	testing.expect_value(t, short_form_row_validate(empty_list.rows[0]), Short_Form_Refusal.None)

	// Valid server with 2 outputs -> 3 rows (metrics, requests, log).
	list, ok_ref := short_form_audit("server", server_file, 2048)
	testing.expect_value(t, ok_ref, Short_Form_Refusal.None)
	testing.expect_value(t, list.form, Short_Form_Kind.Audit)
	testing.expect_value(t, list.row_count, 3)
	testing.expect(t, list.rows[0].source_owner == "server" && list.rows[0].source_stream == "metrics" && list.rows[0].writer_index == 1)
	testing.expect(t, list.rows[1].source_owner == "server" && list.rows[1].source_stream == "requests" && list.rows[1].writer_index == 2)
	testing.expect(t, list.rows[2].source_owner == "server" && list.rows[2].source_stream == "log" && list.rows[2].writer_stream == .Log && list.rows[2].writer_index == 0)
	for i in 0 ..< list.row_count {
		r := list.rows[i]
		testing.expect(t, r.target_owner == "collector" && r.target_input == "sources")
		testing.expect_value(t, r.pace, output.Wiring_Pace.Always_Holds_Writer)
		testing.expect_value(t, r.space_kind, wide_grants.Collector_Space_Kind.Audit)
		testing.expect_value(t, r.space_block_limit, u64(2048))
		testing.expect_value(t, short_form_row_validate(r), Short_Form_Refusal.None)
	}
}

// keep(stream, limit): refuses out-of-bounds limits, invalid targets, collector
// self-keep, log streams, and generic/absent outputs; accepts valid edges and
// preserves wiring conditions.
@(test)
short_form_keep_refusals_and_expansion :: proc(t: ^testing.T) {
	server_file := sf_server_file()
	valid_src := Stream_Source_Ref {
		owner         = "server",
		stream        = "requests",
		writer_stream = .Record_Output,
		writer_index  = 2,
		file          = server_file,
		record_detail = SF_COUNTED,
		has_condition = true,
		condition     = {field = 2, comparison = u32(output.Condition_Comparison.Greater_Or_Equal), value_kind = u32(output.Condition_Value_Kind.Integer), integer = 500},
	}

	// Out-of-bounds limits: negative, 0, one past max, max(i64).
	for bad_limit in ([?]i64{min(i64), -1, 0, KEEP_BLOCK_LIMIT_MOST + 1, max(i64)}) {
		list, refusal := short_form_keep(valid_src, bad_limit)
		testing.expectf(t, refusal == .Limit_Out_Of_Bounds && list.row_count == 0, "limit %d gave %v", bad_limit, refusal)
	}

	// Self-keep of collector.
	self_src := valid_src
	self_src.owner = "collector"
	self_src.file = nil
	_, refusal := short_form_keep(self_src, 64)
	testing.expect_value(t, refusal, Short_Form_Refusal.Cyclic_Self_Wiring)

	// Log stream refused in keep (Never_Holds_Writer is unsupported on log).
	log_src := valid_src
	log_src.stream = "log"
	log_src.writer_stream = .Log
	log_src.writer_index = 0
	log_src.file = nil
	_, refusal = short_form_keep(log_src, 64)
	testing.expect_value(t, refusal, Short_Form_Refusal.Log_Not_Allowed)

	// Invalid targets: empty owner/stream, index 0, index past max, mismatched file index.
	bad_idx := valid_src
	bad_idx.writer_index = 0
	_, refusal = short_form_keep(bad_idx, 64)
	testing.expect_value(t, refusal, Short_Form_Refusal.Invalid_Target)

	bad_idx.writer_index = module.RECORD_STREAM_INDEX_MOST + 1
	_, refusal = short_form_keep(bad_idx, 64)
	testing.expect_value(t, refusal, Short_Form_Refusal.Invalid_Target)

	wrong_idx := valid_src
	wrong_idx.writer_index = 1 // requests is index 2 in server_file
	_, refusal = short_form_keep(wrong_idx, 64)
	testing.expect_value(t, refusal, Short_Form_Refusal.Invalid_Target)

	missing_stream := valid_src
	missing_stream.stream = "absent"
	_, refusal = short_form_keep(missing_stream, 64)
	testing.expect_value(t, refusal, Short_Form_Refusal.Invalid_Target)

	// Valid edges: 1, default, and KEEP_BLOCK_LIMIT_MOST.
	for ok_limit in ([?]i64{KEEP_BLOCK_LIMIT_LEAST, KEEP_BLOCK_LIMIT_DEFAULT, KEEP_BLOCK_LIMIT_MOST}) {
		list, ok_ref := short_form_keep(valid_src, ok_limit)
		testing.expect_value(t, ok_ref, Short_Form_Refusal.None)
		testing.expect_value(t, list.form, Short_Form_Kind.Keep)
		testing.expect_value(t, list.row_count, 1)
		r := list.rows[0]
		testing.expect(t, r.source_owner == "server" && r.source_stream == "requests" && r.writer_index == 2)
		testing.expect(t, r.target_owner == "collector" && r.target_input == "sources")
		testing.expect_value(t, r.pace, output.Wiring_Pace.Never_Holds_Writer)
		testing.expect_value(t, r.space_kind, wide_grants.Collector_Space_Kind.Keep)
		testing.expect_value(t, r.space_block_limit, u64(ok_limit))
		testing.expect(t, r.has_condition && r.condition.integer == 500)
		testing.expect_value(t, short_form_row_validate(r), Short_Form_Refusal.None)
	}
}

// merge(a, b) and merge_many: refuses < 2 or > MERGE_SOURCE_MOST sources,
// cyclic self-merges, duplicate merges, log streams, and mismatched record
// types; expands valid distinct sources into merge.sources + merge.merged.
@(test)
short_form_merge_refusals_and_expansion :: proc(t: ^testing.T) {
	server_file := sf_server_file()
	other_file := sf_other_file()

	alpha := Stream_Source_Ref{owner = "alpha", stream = "requests", writer_stream = .Record_Output, writer_index = 2, file = server_file, record_detail = SF_COUNTED}
	beta := Stream_Source_Ref{owner = "beta", stream = "requests", writer_stream = .Record_Output, writer_index = 2, file = server_file, record_detail = SF_COUNTED}
	other := Stream_Source_Ref{owner = "gamma", stream = "events", writer_stream = .Record_Output, writer_index = 1, file = other_file, record_detail = SF_OTHER}

	// Fewer than 2 sources.
	_, refusal := short_form_merge_many(nil)
	testing.expect_value(t, refusal, Short_Form_Refusal.Too_Few_Sources)
	one := [1]Stream_Source_Ref{alpha}
	_, refusal = short_form_merge_many(one[:])
	testing.expect_value(t, refusal, Short_Form_Refusal.Too_Few_Sources)

	// Too many sources (MERGE_SOURCE_MOST + 1).
	too_many: [MERGE_SOURCE_MOST + 1]Stream_Source_Ref
	for i in 0 ..< len(too_many) {
		too_many[i] = alpha
	}
	_, refusal = short_form_merge_many(too_many[:])
	testing.expect_value(t, refusal, Short_Form_Refusal.Too_Many_Rows)

	// Cyclic self-merge: merge.merged as either argument.
	self_merge := Stream_Source_Ref{owner = "merge", stream = "merged", writer_stream = .Record_Output, writer_index = 1}
	_, refusal = short_form_merge(self_merge, beta)
	testing.expect_value(t, refusal, Short_Form_Refusal.Cyclic_Self_Merge)
	_, refusal = short_form_merge(alpha, self_merge)
	testing.expect_value(t, refusal, Short_Form_Refusal.Cyclic_Self_Merge)

	// Duplicate merge: exact duplicate stream.
	_, refusal = short_form_merge(alpha, alpha)
	testing.expect_value(t, refusal, Short_Form_Refusal.Duplicate_Source)

	// Duplicate merge: same owner and writer_index even with different name.
	dup_idx := Stream_Source_Ref{owner = "alpha", stream = "alias", writer_stream = .Record_Output, writer_index = 2}
	_, refusal = short_form_merge(alpha, dup_idx)
	testing.expect_value(t, refusal, Short_Form_Refusal.Duplicate_Source)

	// Log stream refused in merge.
	log_src := Stream_Source_Ref{owner = "alpha", stream = "log", writer_stream = .Log, writer_index = 0}
	_, refusal = short_form_merge(log_src, beta)
	testing.expect_value(t, refusal, Short_Form_Refusal.Log_Not_Allowed)

	// Record type mismatch between sources.
	_, refusal = short_form_merge(alpha, other)
	testing.expect_value(t, refusal, Short_Form_Refusal.Record_Type_Mismatch)

	// Valid two-source merge with asker end -> 3 rows.
	list, ok_ref := short_form_merge(alpha, beta, true)
	testing.expect_value(t, ok_ref, Short_Form_Refusal.None)
	testing.expect_value(t, list.form, Short_Form_Kind.Merge)
	testing.expect_value(t, list.row_count, 3)
	testing.expect(t, list.rows[0].source_owner == "alpha" && list.rows[0].target_owner == "merge" && list.rows[0].target_input == "sources")
	testing.expect(t, list.rows[1].source_owner == "beta" && list.rows[1].target_owner == "merge" && list.rows[1].target_input == "sources")
	testing.expect(t, list.rows[2].source_owner == "merge" && list.rows[2].source_stream == "merged" && list.rows[2].reader_is_asker)
	for i in 0 ..< list.row_count {
		testing.expect_value(t, short_form_row_validate(list.rows[i]), Short_Form_Refusal.None)
	}

	// Valid merge without asker end -> 2 rows.
	no_asker, no_asker_ref := short_form_merge(alpha, beta, false)
	testing.expect_value(t, no_asker_ref, Short_Form_Refusal.None)
	testing.expect_value(t, no_asker.row_count, 2)
}

// audited(row) and list_sum: composes `audit(server) + audited(wire(shop.orders, server.orders))`
// cleanly, refusing self-wiring, collector loops, and duplicate edges.
@(test)
short_form_audited_and_list_composition :: proc(t: ^testing.T) {
	server_file := sf_server_file()

	// Refusals on audited(row).
	bad_self := Short_Form_Wiring_Row{source_owner = "server", source_stream = "orders", writer_stream = .Record_Output, writer_index = 1, target_owner = "server", target_input = "orders"}
	_, ref := short_form_audited(bad_self)
	testing.expect_value(t, ref, Short_Form_Refusal.Cyclic_Self_Wiring)

	bad_collector := Short_Form_Wiring_Row{source_owner = "collector", source_stream = "forward", writer_stream = .Record_Output, writer_index = 1, target_owner = "server", target_input = "orders"}
	_, ref = short_form_audited(bad_collector)
	testing.expect_value(t, ref, Short_Form_Refusal.Cyclic_Self_Wiring)

	bad_asker := Short_Form_Wiring_Row{source_owner = "shop", source_stream = "orders", writer_stream = .Record_Output, writer_index = 1, reader_is_asker = true}
	_, ref = short_form_audited(bad_asker)
	testing.expect_value(t, ref, Short_Form_Refusal.Invalid_Target)

	// Valid audited(wire(shop.orders, server.orders)) composed with audit(server).
	wire_row := Short_Form_Wiring_Row{source_owner = "shop", source_stream = "orders", writer_stream = .Record_Output, writer_index = 1, target_owner = "server", target_input = "orders"}
	audited_list, audited_ref := short_form_audited(wire_row)
	testing.expect_value(t, audited_ref, Short_Form_Refusal.None)
	testing.expect_value(t, audited_list.row_count, 2)
	testing.expect(t, audited_list.rows[0].target_owner == "collector" && audited_list.rows[0].forward && audited_list.rows[0].space_kind == .Audit)
	testing.expect(t, audited_list.rows[1].source_owner == "collector" && audited_list.rows[1].source_stream == "forward" && audited_list.rows[1].target_owner == "server")
	testing.expect_value(t, audited_list.rows[0].paired_row, u32(0))
	testing.expect_value(t, audited_list.rows[1].paired_row, u32(1))

	audit_list, audit_ref := short_form_audit("server", server_file)
	testing.expect_value(t, audit_ref, Short_Form_Refusal.None)

	combined, sum_ref := short_form_list_sum(&audit_list, &audited_list)
	testing.expect_value(t, sum_ref, Short_Form_Refusal.None)
	testing.expect_value(t, combined.row_count, 5)
	// The pair moves with its source: row 4 of the sum, after the 3 rows
	// of audit(server).
	testing.expect_value(t, combined.rows[4].paired_row, u32(4))
	testing.expect(t, combined.rows[3].forward)

	// Duplicate wiring across sum is refused.
	_, dup_ref := short_form_list_sum(&audit_list, &audit_list)
	testing.expect_value(t, dup_ref, Short_Form_Refusal.Duplicate_Source)
}

// collector.verify(space): refuses malformed targets, self-audit of collector,
// missing/generic outputs, absent spaces, and Keep spaces; accepts Audit spaces
// including `log`.
@(test)
short_form_collector_verify_refusals_and_resolution :: proc(t: ^testing.T) {
	server_file := sf_server_file()
	spaces := [?]Collector_Space_Info{
		{space_id = 10, source_owner = "server", stream_name = "requests", kind = .Keep},
		{space_id = 11, source_owner = "server", stream_name = "log", kind = .Audit},
		{space_id = 12, source_owner = "server", stream_name = "metrics", kind = .Audit},
	}

	// Malformed names.
	for bad in ([?]string{"", "server", ".log", "server.", "a.b.c", "server.bad-name", "1bad.log"}) {
		_, refusal := short_form_collector_verify(bad, spaces[:])
		testing.expectf(t, refusal == .Invalid_Target, "space %q gave %v", bad, refusal)
	}

	// Collector self-verify refused.
	_, refusal := short_form_collector_verify("collector.log", spaces[:])
	testing.expect_value(t, refusal, Short_Form_Refusal.Cyclic_Self_Wiring)

	// Unknown declared output against owner_file.
	_, refusal = short_form_collector_verify("server.unknown", nil, server_file)
	testing.expect_value(t, refusal, Short_Form_Refusal.Invalid_Target)

	// Space not found in collector.spaces().
	_, refusal = short_form_collector_verify("other.log", spaces[:])
	testing.expect_value(t, refusal, Short_Form_Refusal.Space_Not_Found)

	// Keep space has no segment hash chain -> Not_Audit_Space.
	_, refusal = short_form_collector_verify("server.requests", spaces[:], server_file)
	testing.expect_value(t, refusal, Short_Form_Refusal.Not_Audit_Space)

	// Valid Audit spaces: server.log and server.metrics.
	log_plan, log_ref := short_form_collector_verify("server.log", spaces[:], server_file)
	testing.expect_value(t, log_ref, Short_Form_Refusal.None)
	testing.expect(t, log_plan.source_owner == "server" && log_plan.stream_name == "log" && log_plan.is_log)
	testing.expect_value(t, log_plan.space_id, u64(11))
	testing.expect_value(t, log_plan.space_kind, wide_grants.Collector_Space_Kind.Audit)

	metrics_plan, metrics_ref := short_form_collector_verify("server.metrics", spaces[:], server_file)
	testing.expect_value(t, metrics_ref, Short_Form_Refusal.None)
	testing.expect(t, metrics_plan.source_owner == "server" && metrics_plan.stream_name == "metrics" && !metrics_plan.is_log)
	testing.expect_value(t, metrics_plan.space_id, u64(12))
	testing.expect_value(t, metrics_plan.space_kind, wide_grants.Collector_Space_Kind.Audit)
}
