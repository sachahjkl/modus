package system

import "base:intrinsics"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/text_encoding"
import "modus:contract/value_kinds"
import "modus:support/sentence"

// Text without an allocator: src/library/support/sentence. These names stay in this
// library, so a process writes system.Writer and system.format.
Hex :: sentence.Hex
Size :: sentence.Size
Duration :: sentence.Duration
Hash :: sentence.Hash
Module_Name :: sentence.Module_Name
Part :: sentence.Part
part_kind :: sentence.part_kind
Writer :: sentence.Writer
HEX_DIGITS :: sentence.HEX_DIGITS
write_bytes :: sentence.write_bytes
write_unsigned :: sentence.write_unsigned
write_hex :: sentence.write_hex
write_part :: sentence.write_part
written :: sentence.written
writer_reset :: sentence.writer_reset
format :: sentence.format
write_number :: sentence.write_number
write_rights :: sentence.write_rights
write_type :: sentence.write_type
write_type_word :: sentence.write_type_word
write_parameter_type :: sentence.write_parameter_type
write_parameter_type_word :: sentence.write_parameter_type_word
write_field_type :: sentence.write_field_type
direction_name :: sentence.direction_name
error_text :: sentence.error_text
kernel_error_text :: sentence.kernel_error_text
export_error_text :: sentence.export_error_text
ring_error_text :: sentence.ring_error_text
wrapper_error_text :: sentence.wrapper_error_text
error_detail_number_text :: sentence.error_detail_number_text
export_error_detail_text :: sentence.export_error_detail_text
error_details_rest_text :: sentence.error_details_rest_text

// The bytes of the buffer of `log`: the longest line that it gives to the
// kernel in one `Log` call.
LOG_PART_SIZE :: 512

// log writes one line on the log of the kernel, with a level. A process
// with no handle to the log writes nothing. Each part is a text or a value:
// a number, a `Hex`, a `Size`, a `Duration`, a `Hash`, a `Module_Name` or a
// status; a reader of the log shows each value in the color of its kind.
// The line names no group: a reader chooses its rows by process and by
// level (src/md/features/log_facts.md).
//
// The kernel sets the time, the process and the thread of the record. A text of any
// length goes whole: the parts are written in a buffer of LOG_PART_SIZE
// bytes, and each time the buffer is full it goes to the kernel as one line
// of the log, ended after a whole character; the text continues on the next
// line. Nothing is cut.
//
// Each part that is a value (part_kind) goes with its value run, so that the
// log record keeps its kind. A line with more than LOG_CALL_RUN_LIMIT values
// keeps the runs of its first values; the text is the same either way.
//
// The text is UTF-8: the kernel writes "?" in place of each byte of an invalid sequence
// of it, a control character included (src/library/contract/text_encoding). A
// line above the log records of each second of the budget is dropped and
// counted, and one record says the count before the next line (log_call):
// it never waits.
//
// ```odin
// system.log(.Warning, "storage: the block ", block, " has a wrong check")
// ```
log :: proc "contextless" (level: op.Log_Level, parts: ..Part) {
	handle := context_record().handles[op.CONTEXT_LOG]
	if handle == 0 {
		return
	}
	buffer: [LOG_PART_SIZE]u8
	count := 0
	runs: [op.LOG_CALL_RUN_LIMIT]value_kinds.Value_Run_In_Call
	run_count := 0
	for part in parts {
		// The widest value is a hash of 32 bytes: 64 digits.
		number: [96]u8
		bytes: []u8
		kind := part_kind(part)
		switch value in part {
		case string:
			bytes = transmute([]u8)value
		case Module_Name:
			bytes = transmute([]u8)value.name
		case u64, i64, Hex, Size, Duration, Hash, op.Status:
			bytes = transmute([]u8)format(number[:], part)
		}
		part_start := count
		for len(bytes) > 0 {
			taken := copy(buffer[count:], bytes)
			count += taken
			bytes = bytes[taken:]
			if count == len(buffer) && len(bytes) > 0 {
				// A full buffer and more to come: one line, ended after a
				// whole character; the bytes of a cut character go first on
				// the next line. The run of this part ends with the line,
				// and goes on in the next one.
				line := text_encoding.complete_characters(buffer[:count])
				if line == 0 {
					line = count
				}
				sent := runs
				sent_count := value_kinds.value_runs_cut(sent[:], run_count, line)
				if part_start < line {
					value_kinds.value_run_add(sent[:], &sent_count, part_start, line, kind)
				}
				log_send(handle, buffer[:line], sent[:sent_count], level)
				run_count = value_kinds.value_runs_after(runs[:], run_count, line)
				part_start = max(part_start - line, 0)
				count = copy(buffer[:], buffer[line:count])
			}
		}
		value_kinds.value_run_add(runs[:], &run_count, part_start, count, kind)
	}
	log_send(handle, buffer[:count], runs[:run_count], level)
}

// log_send gives one line to the kernel: its text, then its value runs right
// after it, as the operation Log takes them.
@(private = "file")
log_send :: proc "contextless" (handle: Handle, text: []u8, runs: []value_kinds.Value_Run_In_Call, level: op.Log_Level) {
	RUN_SIZE :: size_of(value_kinds.Value_Run_In_Call)
	area: [LOG_PART_SIZE + op.LOG_CALL_RUN_LIMIT * RUN_SIZE]u8
	count := copy(area[:], text)
	run_count := min(len(runs), op.LOG_CALL_RUN_LIMIT)
	if run_count > 0 {
		copy(area[count:], ([^]u8)(raw_data(runs))[:run_count * RUN_SIZE])
	}
	log_call(handle, &area[0], count, level, run_count, .Text)
}

// The own-hash place of the module that compiles this package in: each
// loader writes the hash of the module file there before the first
// instruction (module.own_hash_write), and the kernel writes it for the
// root service. log_fact copies it into each fact, so a reader finds the
// description of the fact in that file. The symbol is exported, so the
// compiler cannot take its bytes as the zeros of the file; the link keeps
// it local to the module (src/md/features/log_facts.md, "The record").
@(export, link_name = module.OWN_HASH_PLACE_SYMBOL)
own_hash: [module.HASH_SIZE]u8

// log_fact writes one log fact on the log of the kernel, with a level: the
// values of a record of a fact type, with no text. The record type has the
// attribute `log_fact` with its fact template, and the call names a
// composite literal of it: the tool reads the type there, and writes the
// fact table of the module (src/md/features/log_facts.md, "The fact type
// in the source"). The compiler refuses a record with padding, whose bytes
// would carry memory that no field names, and a record past the values of
// one log record. A process with no handle to the log writes nothing; a
// fact past the log records of each second of the budget is dropped and
// counted, as a line of `log` is.
//
// ```odin
// system.log_fact(.Warning, Bad_Block{block = number, check = found, expected = wanted})
// ```
log_fact :: proc "contextless" (level: op.Log_Level, value: $T) where intrinsics.type_is_struct(T) && !intrinsics.type_struct_has_implicit_padding(T) && size_of(T) <= op.LOG_FACT_VALUE_CAPACITY {
	handle := context_record().handles[op.CONTEXT_LOG]
	if handle == 0 {
		return
	}
	fact: op.Log_Fact
	fact.module_hash = own_hash
	// The typeid of a named type of the package scope is SipHash-2-4 of its
	// canonical name, an immediate in the code: the fact key, which the
	// tool computes from the source and finds in the code of the module.
	fact.key = transmute(u64)typeid_of(T)
	values := value
	intrinsics.mem_copy_non_overlapping(&fact.values[0], &values, size_of(T))
	log_call(handle, (^u8)(&fact), op.LOG_FACT_HEAD_BYTES + size_of(T), level, 0, .Fact)
}

// The lines of this process that the kernel refused for its log limit, and
// that no note has said yet: one count for all the threads of the process.
log_lines_refused: u64

// log_call gives one line to the kernel, and never waits: a thread with a
// deadline (a frame loop, a key path, a lock held) writes at once or
// counts. A line that the kernel refuses with No_Budget is dropped and
// counted. Before the next line, while lines are counted, one record says
// their count, inside the amount: no line is dropped in silence
// (src/md/features/log_side_channels.md). A line longer than the whole
// amount, and each line of a budget with 0 records, are counted the same
// way; the kernel counts each refused record in the budget too
// (`budget_used`), which the starter reads.
@(private = "file")
log_call :: proc "contextless" (handle: Handle, text: ^u8, count: int, level: op.Log_Level, run_count: int, form: op.Log_Record_Form) {
	if refused := intrinsics.atomic_load(&log_lines_refused); refused != 0 {
		note: [64]u8
		digits: [20]u8
		note_count := copy(note[:], format_decimal(digits[:], refused))
		note_count += copy(note[note_count:], " lines of this process were refused by its log limit")
		if _, status := call(.Log, u64(handle), u64(uintptr(&note[0])), u64(note_count), u64(op.Log_Level.Warning), 0); status == .Ok {
			intrinsics.atomic_sub(&log_lines_refused, refused)
		}
	}
	if _, status := call(.Log, u64(handle), u64(uintptr(text)), u64(count), u64(level), u64(run_count), u64(form)); status == .No_Budget {
		intrinsics.atomic_add(&log_lines_refused, 1)
	}
}

// format_decimal writes a number in decimal at the end of `digits`, and
// gives the digits that it wrote.
@(private = "file")
format_decimal :: proc "contextless" (digits: []u8, value: u64) -> []u8 {
	digit_count := 0
	rest := value
	for digit_count < len(digits) {
		digits[len(digits) - 1 - digit_count] = u8('0' + rest % 10)
		digit_count += 1
		rest /= 10
		if rest == 0 {
			break
		}
	}
	return digits[len(digits) - digit_count:]
}

// LOG_CALL_LIMIT is the bytes of text that the kernel takes in one Log call:
// it writes them as one line, in as many log records as they need.
LOG_CALL_LIMIT :: 4096

// log_text writes a text on the log as it is, with no format and no buffer
// of its own: a text of any length goes whole, as one line when it has at
// most LOG_CALL_LIMIT bytes, and as several lines of that size when it is
// longer. Nothing is cut.
log_text :: proc "contextless" (text: string) {
	handle := context_record().handles[op.CONTEXT_LOG]
	if handle == 0 {
		return
	}
	rest := text
	for {
		part := rest[:min(len(rest), LOG_CALL_LIMIT)]
		// A line of the log ends after a whole character.
		if len(part) < len(rest) {
			whole := text_encoding.complete_characters(transmute([]u8)part)
			part = part[:whole > 0 ? whole : len(part)]
		}
		rest = rest[len(part):]
		// A copy in a buffer of this thread: the call never names an empty
		// slice with no address.
		copied: [LOG_CALL_LIMIT]u8
		count := copy(copied[:], part)
		log_call(handle, &copied[0], count, .Info, 0)
		if len(rest) == 0 {
			break
		}
	}
}

// name_of gives the text of a fixed array of bytes that ends with zero bytes.
name_of :: proc "contextless" (bytes: []u8) -> string {
	count := 0
	for count < len(bytes) && bytes[count] != 0 {
		count += 1
	}
	return string(bytes[:count])
}
