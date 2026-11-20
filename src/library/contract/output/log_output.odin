package output

import "base:intrinsics"
import "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/text_encoding"
import "modus:contract/value_kinds"

// The record output `log` of each process (src/md/features/log_facts.md,
// "The record output `log`"; src/md/features/module_outputs.md, "The
// record output `log`"). No module declares it: the contract describes its
// record, and gives the description file that the root service compares
// with the record input of a reader. The library of the writer builds one
// record for each log record that the process gives the kernel, from the
// same bytes and by the same cut, so the reader reads what the kernel log
// held, and holds it whole.

// One log record of a process, as its record output `log` carries it: the
// head that the writer knows, and the body of a log record of the kernel
// (operation.Log_Record, from its runs): the value runs and the text of a
// text record, or one part of a log fact. The process slot, its serial, its
// own number and its name are not in it: the wiring names the writer, and
// the serial of the compartment numbers the record. A description has no
// union, so the body is one field of the kind Log_Body, which a reader takes
// through the border of the form, as each reader of the log does.
Log_Output_Record :: struct {
	time:       u64, // Microseconds since the start of the machine, from the time page of the writer: its claim.
	text_count: u32, // A text: the bytes of the text in the body. A fact: 0.
	level:      op.Log_Level,
	form:       op.Log_Record_Form,
	more:       u8, // 1: the text, or the fact of several records, goes on in the next record.
	run_count:  u8, // A text: the value runs at the start of the body. A fact: 0.
	body:       value_kinds.Log_Body_Field, // The bytes of operation.Log_Record from its runs.
}
#assert(size_of(Log_Output_Record) == 208)
#assert(offset_of(Log_Output_Record, body) == 16)
#assert(value_kinds.LOG_BODY_FIELD_BYTES == size_of(op.Log_Record) - offset_of(op.Log_Record, runs))

// The index of the record output `log` in the table of the ends of a
// process: past each index that a module declares, so no declared record
// output shares it.
LOG_OUTPUT_INDEX :: u32(module.RECORD_STREAM_INDEX_MOST + 1)

// log_output_record_of gives the record output form of one log record: its
// head fields and its body, the bytes from its runs. ok is false for a form
// byte that names no member: the library builds each record itself, so
// such a byte is a fault of its caller, never a record of the output.
log_output_record_of :: proc "contextless" (record: ^op.Log_Record) -> (written: Log_Output_Record, ok: bool) {
	form := op.log_record_form(record) or_return
	written = {
		time       = record.time,
		text_count = u32(record.text_count),
		level      = record.level,
		form       = form,
		more       = record.more,
		run_count  = record.run_count,
	}
	body := ([^]u8)(record)[offset_of(op.Log_Record, runs):size_of(op.Log_Record)]
	intrinsics.mem_copy_non_overlapping(&written.body[0], raw_data(body), len(body))
	return written, true
}

// The place of the text of a text record in the body: after the value runs.
LOG_OUTPUT_TEXT_OFFSET :: offset_of(op.Log_Record, text) - offset_of(op.Log_Record, runs)

// log_output_text gives the text of a record of the form Text, from its
// body: a reader of `log` reads it through this border, never by an offset
// of its own. ok is false for another form, for a count past the text that
// a log record holds, and for a byte past the count that is not 0.
log_output_text :: proc "contextless" (record: ^Log_Output_Record) -> (text: string, ok: bool) {
	if record.form != .Text || record.text_count > op.LOG_TEXT_CAPACITY {
		return "", false
	}
	bytes := record.body[LOG_OUTPUT_TEXT_OFFSET:]
	for value in bytes[record.text_count:] {
		if value != 0 {
			return "", false
		}
	}
	return string(bytes[:record.text_count]), true
}

// log_output_fact gives the part of a log fact that a record of the form
// Fact holds, from its body: the module hash, the key, the part, the count
// of the parts and the values of this part. ok is false for another form, a
// count of values past a part, a part past the parts or a count of parts
// past op.LOG_FACT_RECORDS_MOST.
log_output_fact :: proc "contextless" (record: ^Log_Output_Record) -> (fact: op.Log_Fact, ok: bool) {
	if record.form != .Fact || record.text_count != 0 || record.run_count != 0 {
		return {}, false
	}
	intrinsics.mem_copy_non_overlapping(&fact, &record.body[0], size_of(op.Log_Fact))
	if fact.value_count > op.LOG_FACT_VALUE_CAPACITY || fact.part_count == 0 || int(fact.part_count) > op.LOG_FACT_RECORDS_MOST || fact.part >= fact.part_count {
		return {}, false
	}
	return fact, true
}

// log_output_text_part builds the record of a text line from the byte
// start on, as the kernel cuts a line into log records: at most
// operation.LOG_TEXT_CAPACITY bytes, ended after a whole character, with
// the value runs that fall in it. The text is the copy of the writer, which
// it filters as the kernel filters a line (text_encoding.invalid_sequences_replace)
// before the call. It gives the start of the next part, len(text) after the
// last one. A start past the text gives an empty record and len(text).
log_output_text_part :: proc "contextless" (text: []u8, runs: []value_kinds.Value_Run_In_Call, start: int, level: op.Log_Level, time: u64) -> (written: Log_Output_Record, next: int) {
	if start < 0 || start > len(text) {
		return {}, len(text)
	}
	rest := text[start:]
	part := rest[:min(len(rest), op.LOG_TEXT_CAPACITY)]
	if len(part) < len(rest) {
		if whole := text_encoding.complete_characters(part); whole > 0 {
			part = part[:whole]
		}
	}
	record := op.Log_Record {
		time       = time,
		level      = level,
		more       = u8(len(part) < len(rest)),
		text_count = u16(len(part)),
	}
	copy(record.text[:], part)
	record.run_count = u8(value_kinds.value_runs_of_record(runs, start, len(part), record.runs[:]))
	written, _ = log_output_record_of(&record)
	return written, start + len(part)
}

// log_output_fact_part builds the record of one part of a log fact, as the
// kernel writes it: the head of the fact that the writer gave, the values of
// the part, their count, the part and the count of the parts. body is the
// fact as the writer gives it to Log: its head of operation.LOG_FACT_HEAD_BYTES
// then its values. A body shorter than the head, or a part past the parts,
// gives ok false.
log_output_fact_part :: proc "contextless" (body: []u8, part: int, level: op.Log_Level, time: u64) -> (written: Log_Output_Record, ok: bool) {
	if len(body) < op.LOG_FACT_HEAD_BYTES || len(body) > op.LOG_FACT_CALL_BYTES_MOST {
		return {}, false
	}
	values := body[op.LOG_FACT_HEAD_BYTES:]
	part_count := op.log_fact_part_count(len(values))
	if part < 0 || part >= part_count {
		return {}, false
	}
	record := op.Log_Record {
		time  = time,
		level = level,
		more  = u8(part + 1 < part_count),
		form  = u8(op.Log_Record_Form.Fact),
	}
	fact := op.log_record_fact(&record)
	start := min(part * op.LOG_FACT_VALUE_CAPACITY, len(values))
	end := min(start + op.LOG_FACT_VALUE_CAPACITY, len(values))
	copy(([^]u8)(fact)[:op.LOG_FACT_HEAD_BYTES], body[:op.LOG_FACT_HEAD_BYTES])
	fact.values = {}
	copy(fact.values[:], values[start:end])
	fact.value_count = u16(end - start)
	fact.part, fact.part_count = u8(part), u8(part_count)
	fact.reserved = {}
	return log_output_record_of(&record)
}

// One field of the description of Log_Output_Record.
@(private = "file")
Log_Output_Field :: struct {
	name:          string,
	offset:        u32,
	type:          module.Type,
	detail:        u32,
	unsigned:      bool,
	kind:          value_kinds.Field_Kind,
	contract_enum: value_kinds.Contract_Enum,
}

// The fields of Log_Output_Record, as the tool describes them from the
// type: the tool test of the description compares the two field by field.
@(private = "file", rodata)
log_output_fields := [?]Log_Output_Field {
	{"time", u32(offset_of(Log_Output_Record, time)), .Integer, 0, true, .Plain, .None},
	{"text_count", u32(offset_of(Log_Output_Record, text_count)), .Integer, 4, true, .Plain, .None},
	{"level", u32(offset_of(Log_Output_Record, level)), .Integer, u32(size_of(op.Log_Level)), true, .Status, .Log_Level},
	{"form", u32(offset_of(Log_Output_Record, form)), .Integer, u32(size_of(op.Log_Record_Form)), true, .Status, .Log_Record_Form},
	{"more", u32(offset_of(Log_Output_Record, more)), .Integer, 1, true, .Plain, .None},
	{"run_count", u32(offset_of(Log_Output_Record, run_count)), .Integer, 1, true, .Plain, .None},
	{"body", u32(offset_of(Log_Output_Record, body)), .Bytes, value_kinds.LOG_BODY_FIELD_BYTES, false, .Log_Body, .None},
}

// The name of the record in its description.
LOG_OUTPUT_RECORD_NAME :: "Log_Output_Record"

// log_output_file_write writes the description file of Log_Output_Record
// into into, as description_file_write writes the one of a record of a
// module file: the record at DESCRIPTION_RECORD_INDEX. The root service
// compares it with the record input of the reader of `log`, and gives it to
// the reader end, as the module file of the writer for each other wiring.
// It gives its size; false when it does not fit into.
log_output_file_write :: proc "contextless" (into: []u8) -> (size: int, ok: bool) {
	directory_end := size_of(module.Header) + module.TABLE_COUNT * size_of(module.Table_Entry)
	records_at := directory_end
	fields_at := records_at + 2 * size_of(module.Record)
	strings_at := fields_at + (len(log_output_fields) + 1) * size_of(module.Field)
	strings_count := 1 + len(LOG_OUTPUT_RECORD_NAME)
	for item in log_output_fields {
		strings_count += len(item.name)
	}
	size = strings_at + strings_count
	if size > len(into) {
		return 0, false
	}
	intrinsics.mem_zero(raw_data(into), size)
	cursor := u32(1)
	copy(into[strings_at + int(cursor):], LOG_OUTPUT_RECORD_NAME)
	record := module.Record{name_offset = cursor, name_count = u32(len(LOG_OUTPUT_RECORD_NAME)), size = size_of(Log_Output_Record), first_field = 1, field_count = u32(len(log_output_fields))}
	cursor += u32(len(LOG_OUTPUT_RECORD_NAME))
	intrinsics.mem_copy_non_overlapping(&into[records_at + size_of(module.Record)], &record, size_of(record))
	for item, number in log_output_fields {
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
	directory[module.Table_Kind.Fields] = {offset = u64(fields_at), count = u32(len(log_output_fields)) + 1, record_size = size_of(module.Field)}
	directory[module.Table_Kind.Strings] = {offset = u64(strings_at), count = u32(strings_count), record_size = 1}
	header := module.Header{magic = module.MAGIC, version = module.VERSION, header_size = size_of(module.Header), machine = .X86_64, table_count = module.TABLE_COUNT}
	intrinsics.mem_copy_non_overlapping(raw_data(into), &header, size_of(header))
	intrinsics.mem_copy_non_overlapping(&into[size_of(module.Header)], &directory, size_of(directory))
	return size, true
}

// gap_after_lost_records gives the gap of a ring after its writer lost
// count records before it wrote them, from the serial first: the records
// that the kernel log wrote over before log.follow read them. A gap that
// waits takes them after its own records, which come right before them; a
// ring with no gap that waits starts one at first. A count that would pass
// the largest count of the ring leaves the gap as it was, and the step
// says that the writer closes the end, as for a refused record. A count of
// 0 loses nothing, and changes nothing.
//
// On a ring with no condition, the lost records must start right after the
// gap that waits: the writer pushes a gap before any later record, so its
// records end at the next serial. Others give Not_Contiguous and leave the
// gap. On a ring with a condition, a record that the ring skipped moves the
// serial with no gap, and its reader takes a serial that moves forward by
// any count below its window: the count grows, as for a refused record
// (gap_after_refused_record).
gap_after_lost_records :: proc "contextless" (gap: Gap_State, first: u32, count: u32, filtered: bool) -> (after: Gap_State, step: Gap_Step) {
	if count == 0 {
		return gap, .Counted
	}
	if !filtered && gap.count != 0 && first != gap.first + gap.count {
		return gap, .Not_Contiguous
	}
	most := gap_count_most(filtered)
	if gap.count > most || count > most - gap.count {
		return gap, .Past_The_Count
	}
	after = gap
	if after.count == 0 {
		after.first = first
	}
	after.count += count
	return after, .Counted
}
