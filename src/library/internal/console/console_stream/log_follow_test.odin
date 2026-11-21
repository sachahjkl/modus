#+build !freestanding
package console_stream

import "core:testing"
import "modus:console_condition"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/output"
import "modus:contract/wide_grants"

@(private = "file")
lf_make_row :: proc(number: i64, slot: i64, proc_name: string, level: op.Log_Level, text: string) -> [FOLLOW_ROW_SIZE]u8 {
	wire := Follow_Row_Wire {
		number     = number,
		time       = number * 1000,
		slot       = slot,
		level      = level,
		form       = .Text,
		text_count = u32(min(len(text), op.LOG_TEXT_CAPACITY)),
	}
	copy(wire.process[:len(wire.process) - 1], proc_name)
	copy(wire.text[:], text)
	return transmute([FOLLOW_ROW_SIZE]u8)wire
}

@(private = "file")
LF_Test_File :: struct {
	records: [dynamic]module.Record,
	fields:  [dynamic]module.Field,
	strings: [dynamic]u8,
	outputs: [dynamic]module.Record_Output,
	inputs:  [dynamic]module.Record_Input,
}

@(private = "file")
lf_str_add :: proc(table: ^[dynamic]u8, text: string) -> (offset, count: u32) {
	offset = u32(len(table))
	append(table, text)
	return offset, u32(len(text))
}

@(private = "file")
lf_bytes_of :: proc(items: []$T) -> []u8 {
	return ([^]u8)(raw_data(items))[:len(items) * size_of(T)]
}

@(private = "file")
lf_base_parts :: proc() -> (parts: LF_Test_File) {
	parts.records = make([dynamic]module.Record, context.temp_allocator)
	parts.fields = make([dynamic]module.Field, context.temp_allocator)
	parts.strings = make([dynamic]u8, context.temp_allocator)
	parts.outputs = make([dynamic]module.Record_Output, context.temp_allocator)
	parts.inputs = make([dynamic]module.Record_Input, context.temp_allocator)
	append(&parts.strings, 0)
	append(&parts.records, module.Record{})
	append(&parts.fields, module.Field{})
	append(&parts.outputs, module.Record_Output{})
	append(&parts.inputs, module.Record_Input{})

	// Record 1: Counted (16 bytes: serial, status)
	n_off, n_cnt := lf_str_add(&parts.strings, "Counted")
	f1_off, f1_cnt := lf_str_add(&parts.strings, "serial")
	f2_off, f2_cnt := lf_str_add(&parts.strings, "status")
	first_f := u32(len(parts.fields))
	append(&parts.fields, module.Field{name_offset = f1_off, name_count = f1_cnt, offset = 0, type = u8(module.Type.Integer), unsigned = true})
	append(&parts.fields, module.Field{name_offset = f2_off, name_count = f2_cnt, offset = 8, type = u8(module.Type.Integer), unsigned = true})
	append(&parts.records, module.Record{name_offset = n_off, name_count = n_cnt, size = 16, first_field = first_f, field_count = 2})

	about_off, about_cnt := lf_str_add(&parts.strings, "Help line.")
	ord_off, ord_cnt := lf_str_add(&parts.strings, "orders")
	src_off, src_cnt := lf_str_add(&parts.strings, "sources")
	append(&parts.inputs, module.Record_Input{name_offset = ord_off, name_count = ord_cnt, about_offset = about_off, about_count = about_cnt, text_offset = about_off, text_count = about_cnt, record = 1, wirings = u8(module.Wiring_Count.One)})
	append(&parts.inputs, module.Record_Input{name_offset = src_off, name_count = src_cnt, about_offset = about_off, about_count = about_cnt, text_offset = about_off, text_count = about_cnt, record = 0, wirings = u8(module.Wiring_Count.Many_Types)})
	return parts
}

@(private = "file")
lf_build_file :: proc(parts: LF_Test_File) -> []u8 {
	file := make([dynamic]u8, size_of(module.Header) + module.TABLE_COUNT * size_of(module.Table_Entry), context.temp_allocator)
	directory: [module.TABLE_COUNT]module.Table_Entry
	add :: proc(file: ^[dynamic]u8, directory: ^[module.TABLE_COUNT]module.Table_Entry, kind: module.Table_Kind, bytes: []u8, count, record_size: u32) {
		for len(file) % 8 != 0 {
			append(file, 0)
		}
		directory[kind] = {offset = u64(len(file)), count = count, record_size = record_size}
		append(file, ..bytes)
	}
	add(&file, &directory, .Records, lf_bytes_of(parts.records[:]), u32(len(parts.records)), size_of(module.Record))
	add(&file, &directory, .Fields, lf_bytes_of(parts.fields[:]), u32(len(parts.fields)), size_of(module.Field))
	add(&file, &directory, .Strings, parts.strings[:], u32(len(parts.strings)), 1)
	add(&file, &directory, .Record_Outputs, lf_bytes_of(parts.outputs[:]), u32(len(parts.outputs)), size_of(module.Record_Output))
	add(&file, &directory, .Record_Inputs, lf_bytes_of(parts.inputs[:]), u32(len(parts.inputs)), size_of(module.Record_Input))
	(^module.Header)(&file[0])^ = {magic = module.MAGIC, version = module.VERSION, header_size = size_of(module.Header), machine = .X86_64, table_count = module.TABLE_COUNT}
	(^[module.TABLE_COUNT]module.Table_Entry)(&file[size_of(module.Header)])^ = directory
	return file[:]
}

@(private = "file")
lf_build_collector_file :: proc() -> []u8 {
	return lf_build_file(lf_base_parts())
}

@(private = "file")
lf_build_typed_log_reader_file :: proc() -> []u8 {
	desc_buf: [LOG_OUTPUT_DESCRIPTION_CAPACITY]u8
	desc_size, ok := output.log_output_file_write(desc_buf[:])
	assert(ok)
	desc_file := desc_buf[:desc_size]
	log_rec, rec_ok := module.record_type(desc_file, output.DESCRIPTION_RECORD_INDEX)
	assert(rec_ok)

	parts := lf_base_parts()
	rec_name := module.string_at(desc_file, log_rec.name_offset, log_rec.name_count)
	rec_name_off, rec_name_cnt := lf_str_add(&parts.strings, rec_name)
	first_field := u32(len(parts.fields))
	for fi in u32(0) ..< log_rec.field_count {
		f, f_ok := module.field(desc_file, log_rec, fi)
		assert(f_ok)
		fn := module.string_at(desc_file, f.name_offset, f.name_count)
		fn_off, fn_cnt := lf_str_add(&parts.strings, fn)
		f.name_offset = fn_off
		f.name_count = fn_cnt
		append(&parts.fields, f)
	}
	log_rec_idx := u32(len(parts.records))
	append(&parts.records, module.Record {
		name_offset = rec_name_off,
		name_count  = rec_name_cnt,
		size        = log_rec.size,
		first_field = first_field,
		field_count = log_rec.field_count,
	})

	about_off, about_cnt := lf_str_add(&parts.strings, "Audit log input.")
	in_off, in_cnt := lf_str_add(&parts.strings, "audit_in")
	append(&parts.inputs, module.Record_Input {
		name_offset  = in_off,
		name_count   = in_cnt,
		about_offset = about_off,
		about_count  = about_cnt,
		text_offset  = about_off,
		text_count   = about_cnt,
		record       = log_rec_idx,
		wirings      = u8(module.Wiring_Count.One),
	})
	return lf_build_file(parts)
}

@(test)
wire_server_log_and_malformed_wire_refusals :: proc(t: ^testing.T) {
	collector_file := lf_build_collector_file()
	log_reader_file := lf_build_typed_log_reader_file()

	// Malformed wire(...) expressions are refused cleanly.
	bad_exprs := [?]string {
		"",
		"wire()",
		"wire(server.log)",
		"wire(server.log, )",
		"wire(, collector.sources)",
		"wire(server, collector.sources)",
		"wire(server.log, collector)",
		"wire(server.log, collector.sources, extra)",
		"wire(server.log, collector.sources) trailing",
		"wire(server.log, collector.sources",
		"notwire(server.log, collector.sources)",
		"wire(1server.log, collector.sources)",
		"wire(server..log, collector.sources)",
		"wire(server.log, collector..sources)",
		"wire(\"server.log\", collector.sources)",
	}
	for expr in bad_exprs {
		row, ref := wire_expression_lower(expr, nil, collector_file)
		testing.expectf(t, ref == .Invalid_Target && row.source_owner == "", "expr %q gave %v", expr, ref)
	}

	// Self-wiring refused cleanly.
	_, self_ref := wire_expression_lower("wire(server.log, server.orders)")
	testing.expect_value(t, self_ref, Short_Form_Refusal.Cyclic_Self_Wiring)

	// Condition on log output refused cleanly.
	cond := output.Condition_Terms{field = 1, comparison = u32(output.Condition_Comparison.Equal), value_kind = u32(output.Condition_Value_Kind.Integer), integer = 1}
	_, cond_ref := wire_descriptor_lower("server.log", "collector.sources", nil, collector_file, true, cond)
	testing.expect_value(t, cond_ref, Short_Form_Refusal.Log_Not_Allowed)

	// Wiring server.log to a typed input with a mismatched record type (Counted) is refused.
	_, mismatch_ref := wire_expression_lower("wire(server.log, auditor.orders)", nil, log_reader_file)
	testing.expect_value(t, mismatch_ref, Short_Form_Refusal.Record_Type_Mismatch)

	// Wiring server.log to a typed Log_Output_Record input succeeds cleanly.
	typed_row, typed_ref := wire_expression_lower("wire(server.log, auditor.audit_in)", nil, log_reader_file)
	testing.expect_value(t, typed_ref, Short_Form_Refusal.None)
	testing.expect_value(t, typed_row.source_owner, "server")
	testing.expect_value(t, typed_row.source_stream, "log")
	testing.expect_value(t, typed_row.writer_stream, output.Writer_Stream.Log)
	testing.expect_value(t, typed_row.writer_index, u32(0))
	testing.expect_value(t, typed_row.target_owner, "auditor")
	testing.expect_value(t, typed_row.target_input, "audit_in")
	testing.expect_value(t, typed_row.pace, output.Wiring_Pace.Writer_Chooses)
	testing.expect_value(t, short_form_row_validate(typed_row), Short_Form_Refusal.None)

	// wire(server.log, collector.sources) lowers cleanly to the exact Audit Log wiring descriptor.
	row, ok_ref := wire_expression_lower("wire(server.log, collector.sources)", nil, collector_file)
	testing.expect_value(t, ok_ref, Short_Form_Refusal.None)
	testing.expect_value(t, row.source_owner, "server")
	testing.expect_value(t, row.source_stream, "log")
	testing.expect_value(t, row.writer_stream, output.Writer_Stream.Log)
	testing.expect_value(t, row.writer_index, u32(0))
	testing.expect_value(t, row.target_owner, "collector")
	testing.expect_value(t, row.target_input, "sources")
	testing.expect_value(t, row.pace, output.Wiring_Pace.Always_Holds_Writer)
	testing.expect_value(t, row.space_kind, wide_grants.Collector_Space_Kind.Audit)
	testing.expect_value(t, row.space_block_limit, u64(AUDIT_BLOCK_LIMIT_DEFAULT))
	testing.expect_value(t, short_form_row_validate(row), Short_Form_Refusal.None)
}

@(test)
log_follow_pipe_lowering_and_refusals :: proc(t: ^testing.T) {
	// Negative own_process_slot refused.
	for bad_slot in ([?]i64{min(i64), -1}) {
		_, ref := log_follow_lower("log.follow", bad_slot)
		testing.expect_value(t, ref, Log_Follow_Refusal.Bad_Own_Slot)
	}

	// Adversarial malformed / invalid field / unknown level / bad operator refusals.
	Refusal_Case :: struct {
		expr:    string,
		refusal: Log_Follow_Refusal,
	}
	bad_cases := [?]Refusal_Case {
		{"", .Not_Log_Follow},
		{"server.requests", .Not_Log_Follow},
		{"server.requests |> where(level = Warning)", .Not_Log_Follow},
		{"log.records(0) |> where(level = Warning)", .Unsupported_Stage},
		{"log.follow |> sort(number)", .Unsupported_Stage},
		{"log.follow | where(level = Warning)", .Malformed_Pipe},
		{"log.follow |>", .Malformed_Pipe},
		{"log.follow |> where(bogus_field = 1)", .Unknown_Field},
		{"log.follow |> where(severity = Warning)", .Unknown_Field},
		{"log.follow |> where(level = Critical)", .Unknown_Member},
		{"log.follow |> where(level = Fatal)", .Unknown_Member},
		{"log.follow |> where(level = warning)", .Unknown_Member},
		{"log.follow |> where(form = Binary)", .Unknown_Member},
		{"log.follow |> where(level = 2)", .Member_Is_A_Name},
		{"log.follow |> where(level = \"Warning\")", .Member_Is_A_Name},
		{"log.follow |> where(level >= Warning)", .No_Order},
		{"log.follow |> where(level < Error)", .No_Order},
		{"log.follow |> where(process >= \"a\")", .No_Order},
		{"log.follow |> where(slot = \"storage\")", .Wrong_Kind},
		{"log.follow |> where(process = 42)", .Wrong_Kind},
		{"log.follow |> where(continues = -1)", .Out_Of_Range},
		{"log.follow |> where(continues = 256)", .Out_Of_Range},
		{"log.follow |> where(level == Warning)", .Bad_Condition_Syntax},
		{"log.follow |> where(level)", .Bad_Condition_Syntax},
		{"log.follow |> where(= Warning)", .Bad_Condition_Syntax},
		{"log.follow |> where(level = Warning extra)", .Trailing_Tokens},
		{"log.follow extra", .Trailing_Tokens},
		{"log.follow |> where(slot = 1) |> where(slot = 2) |> where(slot = 3) |> where(slot = 4) |> where(slot = 5)", .Too_Many_Conditions},
	}
	for item in bad_cases {
		_, ref := log_follow_lower(item.expr, 7)
		testing.expectf(t, ref == item.refusal, "%q: got %v, expected %v", item.expr, ref, item.refusal)
	}

	// Bare log.follow lowers with echo_suppressed and self-slot wiring filter.
	bare_plan, bare_ref := log_follow_lower("log.follow", 7)
	testing.expect_value(t, bare_ref, Log_Follow_Refusal.None)
	testing.expect_value(t, bare_plan.source_owner, "log")
	testing.expect_value(t, bare_plan.source_stream, "follow")
	testing.expect_value(t, bare_plan.own_process_slot, i64(7))
	testing.expect(t, !bare_plan.include_self, "include_self must default to false")
	testing.expect(t, bare_plan.echo_suppressed, "echo_suppressed must be true")
	testing.expect(t, bare_plan.has_self_slot_filter, "self-slot filter must be attached")
	testing.expect(t, bare_plan.has_wiring_condition, "self-slot filter must be pushed to wiring when no user condition exists")
	testing.expect_value(t, bare_plan.wiring_terms.comparison, u32(output.Condition_Comparison.Not_Equal))
	testing.expect_value(t, bare_plan.wiring_terms.integer, i64(7))

	// log.follow |> where(level = Warning) parses and lowers cleanly.
	warn_plan, warn_ref := log_follow_lower("log.follow |> where(level = Warning)", 7)
	testing.expect_value(t, warn_ref, Log_Follow_Refusal.None)
	testing.expect_value(t, warn_plan.condition_count, 1)
	testing.expect_value(t, warn_plan.conditions[0].field, "level")
	testing.expect_value(t, warn_plan.conditions[0].comparison, console_condition.Comparison.Equal)
	testing.expect_value(t, warn_plan.conditions[0].compared, i64(op.Log_Level.Warning))
	testing.expect(t, warn_plan.echo_suppressed, "echo_suppressed must be true")
	testing.expect(t, warn_plan.has_self_slot_filter, "self-slot filter stays active alongside user filter")

	// Chained pipeline preserves pipeline order (process first, then level).
	chain_plan, chain_ref := log_follow_lower("log.follow |> where(process = \"storage\") |> where(level = Warning)", 7)
	testing.expect_value(t, chain_ref, Log_Follow_Refusal.None)
	testing.expect_value(t, chain_plan.condition_count, 2)
	testing.expect_value(t, chain_plan.conditions[0].field, "process")
	testing.expect_value(t, string(chain_plan.conditions[0].text_bytes[:chain_plan.conditions[0].text_length]), "storage")
	testing.expect_value(t, chain_plan.conditions[1].field, "level")
	testing.expect_value(t, chain_plan.conditions[1].compared, i64(op.Log_Level.Warning))

	// Nested form where(log.follow, level = Error) lowers identically.
	nested_plan, nested_ref := log_follow_lower("where(log.follow, level = Error)", 7)
	testing.expect_value(t, nested_ref, Log_Follow_Refusal.None)
	testing.expect_value(t, nested_plan.condition_count, 1)
	testing.expect_value(t, nested_plan.conditions[0].compared, i64(op.Log_Level.Error))

	// Bound: 4 chained conditions succeed.
	four_plan, four_ref := log_follow_lower("log.follow |> where(slot >= 1) |> where(level != Debug) |> where(number > 0) |> where(process != \"noise\")", 7)
	testing.expect_value(t, four_ref, Log_Follow_Refusal.None)
	testing.expect_value(t, four_plan.condition_count, MAX_FOLLOW_CONDITIONS)
}

@(test)
log_follow_self_feedback_loop_breaker_zero_amplification :: proc(t: ^testing.T) {
	CONSOLE_SLOT :: i64(7)
	plan, ref := log_follow_lower("log.follow |> where(level = Warning)", CONSOLE_SLOT)
	testing.expect_value(t, ref, Log_Follow_Refusal.None)

	breaker := follow_loop_breaker_init(&plan, "console")
	output_logged := true

	// Bad record sizes refused cleanly without passing.
	short_buf: [16]u8
	testing.expect_value(t, follow_filter_record(&breaker, short_buf[:], 3, "storage"), Follow_Record_Decision.Bad_Record)
	testing.expect_value(t, follow_filter_record(nil, short_buf[:], 3, "storage"), Follow_Record_Decision.Bad_Record)

	// Simulate closed-loop feedback queue: external warnings + external info +
	// internal console Warning diagnostics + render-time echoes.
	Queue_Item :: struct {
		row:                   [FOLLOW_ROW_SIZE]u8,
		slot:                  i64,
		proc_name:             string,
		emitted_during_render: bool,
	}
	queue: [64]Queue_Item
	q_head := 0
	q_tail := 0

	// Enqueue 5 external Warning records and 2 external Info records.
	for i in i64(1) ..= 5 {
		queue[q_tail] = {row = lf_make_row(i, 3, "storage", .Warning, "block check warning"), slot = 3, proc_name = "storage"}
		q_tail += 1
	}
	for i in i64(6) ..= 7 {
		queue[q_tail] = {row = lf_make_row(i, 4, "network", .Info, "link up"), slot = 4, proc_name = "network"}
		q_tail += 1
	}
	// Enqueue 3 console-slot Warning diagnostics directly (e.g. Escape/key warnings).
	for i in i64(8) ..= 10 {
		queue[q_tail] = {row = lf_make_row(i, CONSOLE_SLOT, "console", .Warning, "console diagnostic"), slot = CONSOLE_SLOT, proc_name = "console"}
		q_tail += 1
	}

	rendered_count := 0
	feedback_emitted := 0
	iterations := 0
	for q_head < q_tail && iterations < 64 {
		iterations += 1
		item := queue[q_head]
		q_head += 1

		decision := follow_filter_record(&breaker, item.row[:], item.slot, item.proc_name, item.emitted_during_render)
		if decision != .Pass {
			continue
		}

		// Render this external Warning inside Follow_Render_Guard.
		guard := follow_render_begin(&breaker, &output_logged)
		testing.expect(t, !output_logged, "output_logged must be suppressed during log.follow render")
		testing.expect(t, breaker.echo_suppressed, "echo_suppressed must be active during render")

		// Attempt to echo the drawn line back into the kernel log (MUST be blocked!).
		if follow_should_emit_to_log(&breaker) && output_logged {
			if q_tail < len(queue) {
				queue[q_tail] = {row = lf_make_row(100 + i64(rendered_count), CONSOLE_SLOT, "console", .Warning, "echoed draw line"), slot = CONSOLE_SLOT, proc_name = "console", emitted_during_render = true}
				q_tail += 1
				feedback_emitted += 1
			}
		}

		// Even if an internal console diagnostic bypassed output_logged during render
		// and landed in the queue, the loop breaker must drop it cleanly at 0 amplification.
		if q_tail < len(queue) {
			queue[q_tail] = {row = lf_make_row(200 + i64(rendered_count), CONSOLE_SLOT, "console", .Warning, "internal diagnostic during render"), slot = CONSOLE_SLOT, proc_name = "console"}
			q_tail += 1
		}

		follow_render_end(&breaker, guard, &output_logged)
		testing.expect(t, output_logged, "output_logged must be restored after render")
		testing.expect(t, !breaker.echo_suppressed, "echo_suppressed must clear after render")
		rendered_count += 1
	}

	// Proof of zero feedback amplification and intact external delivery:
	testing.expect_value(t, rendered_count, 5)
	testing.expect_value(t, feedback_emitted, 0)
	testing.expect_value(t, breaker.records_passed, u64(5))
	testing.expect_value(t, breaker.filtered_out, u64(2))
	testing.expect_value(t, breaker.self_slot_suppressed, u64(8)) // 3 initial + 5 injected during renders
	testing.expect_value(t, breaker.echo_writes_blocked, u64(5))
	testing.expect_value(t, q_head, q_tail) // Queue drained cleanly, zero runaway loop!

	// Direct emitted_during_render record is suppressed as Suppressed_Self_Echo.
	echo_row := lf_make_row(300, 3, "storage", .Warning, "late echo")
	testing.expect_value(t, follow_filter_record(&breaker, echo_row[:], 3, "storage", true), Follow_Record_Decision.Suppressed_Self_Echo)
	testing.expect_value(t, breaker.self_echo_suppressed, u64(1))

	// Fallback defense when own_process_slot == 0: own_process_name ("console") is still suppressed.
	slot0_plan, slot0_ref := log_follow_lower("log.follow", 0)
	testing.expect_value(t, slot0_ref, Log_Follow_Refusal.None)
	slot0_breaker := follow_loop_breaker_init(&slot0_plan, "console")
	self_named := lf_make_row(1, 9, "console", .Info, "self by name")
	other_named := lf_make_row(2, 3, "storage", .Info, "other process")
	testing.expect_value(t, follow_filter_record(&slot0_breaker, self_named[:], 9, "console"), Follow_Record_Decision.Suppressed_Self_Slot)
	testing.expect_value(t, follow_filter_record(&slot0_breaker, other_named[:], 3, "storage"), Follow_Record_Decision.Pass)

	// Explicit include_self = true allows own-slot records while still blocking render echoes.
	inc_plan, inc_ref := log_follow_lower("log.follow |> where(level = Warning)", CONSOLE_SLOT, true)
	testing.expect_value(t, inc_ref, Log_Follow_Refusal.None)
	testing.expect(t, inc_plan.include_self && !inc_plan.has_self_slot_filter && inc_plan.echo_suppressed)
	inc_breaker := follow_loop_breaker_init(&inc_plan, "console")
	self_warn := lf_make_row(1, CONSOLE_SLOT, "console", .Warning, "explicit self warning")
	testing.expect_value(t, follow_filter_record(&inc_breaker, self_warn[:], CONSOLE_SLOT, "console"), Follow_Record_Decision.Pass)
	guard := follow_render_begin(&inc_breaker, &output_logged)
	testing.expect(t, !follow_should_emit_to_log(&inc_breaker), "render echo still suppressed even with include_self = true")
	follow_render_end(&inc_breaker, guard, &output_logged)
}
