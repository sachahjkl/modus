// The output ring: the compartments that carry the records of one record output
// to one reader (src/md/features/module_outputs.md, "The ring and its
// records").
//
// An output ring is a ring of compartments (`ring.compartment_open`): its command queue
// holds one compartment for each record, its completion queue the records of 64
// bytes of each ring. A compartment is the compartment word, then the record, rounded up
// to a multiple of 64 bytes (`compartment_size`). Each side computes the size of a
// compartment from the record description that it holds, never from the shared
// memory.
//
// The writer writes a joined record first, then the records of the record
// output with their serials, a gap record where it refused records for this
// reader, and an end record at its end. The reader copies each compartment once
// into private memory, then takes it through one border,
// `record_of_compartment`, which checks it against the record description and
// against the compartments before it. The root service writes the end words in
// the end page of the wiring when a side stops (`end_words_write`), and each side takes
// them through `end_of_words`.
//
// Who uses it: the library of each process that declares a record output or
// a record input, the console, and the root service for the end words. The
// parts:
//
// - `Compartment_Kind`, `Compartment_Word`, `compartment_size`: the form of a compartment.
// - `Read_State`, `Taken_Compartment`, `Compartment_Fault`, `record_of_compartment`: the
//   border of the reader.
// - `joined_compartment`, `gap_compartment`, `end_compartment`, `record_compartment`: the compartments
//   that a writer writes.
// - `End_Word`, `End_Words`, `end_words_write`, `end_words_read`,
//   `end_of_words`: the end words of the root service.
// - `Completion_Kind`, `refusal_completion`, `completion_of_record`: the
//   completion queue.
//
// See [output ring](term:output-ring) and [compartment word](term:compartment-word).
package output

import "base:intrinsics"
import "modus:contract/enum_word"
import "modus:contract/errors"
import "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:contract/text_encoding"

// The bytes of the compartment word, at the start of each compartment.
COMPARTMENT_WORD_SIZE :: 8

// The bytes that each compartment is a multiple of: one Record of a ring.
COMPARTMENT_ALIGNMENT :: size_of(ring.Record)

// The bytes of the largest compartment: the compartment word and the largest record of
// a record description, rounded up.
COMPARTMENT_SIZE_MOST :: (COMPARTMENT_WORD_SIZE + module.RECORD_SIZE_LIMIT + COMPARTMENT_ALIGNMENT - 1) / COMPARTMENT_ALIGNMENT * COMPARTMENT_ALIGNMENT
#assert(COMPARTMENT_SIZE_MOST <= ring.COMPARTMENT_SIZE_LIMIT)

// What a compartment holds. The values cross the border of the ring.
Compartment_Kind :: enum u32 {
	Record = 0, // One record of the record output, after the compartment word. A zero compartment is a record of serial 0.
	Gap    = 1, // The writer refused records for this reader: their count is GAP_COUNT_OFFSET, and the serial is the serial of the first one.
	End    = 2, // The end of the stream: an errors.Error_Record at END_ERROR_OFFSET, zero for a clean end.
	Joined = 3, // The first compartment of each ring: the serial is the serial of the next record, the count of the records written before this reader joined.
}

// The first 8 bytes of each compartment.
Compartment_Word :: struct {
	kind:   u32, // The word of a Compartment_Kind (compartment_kind_of_word).
	serial: u32, // The serial of the record in the record output, from 0: the same in each ring of the record output.
}
#assert(size_of(Compartment_Word) == COMPARTMENT_WORD_SIZE)

// Where a gap record holds its count, and an end record its error record.
GAP_COUNT_OFFSET :: COMPARTMENT_WORD_SIZE
END_ERROR_OFFSET :: COMPARTMENT_WORD_SIZE
#assert(END_ERROR_OFFSET + size_of(errors.Error_Record) <= COMPARTMENT_ALIGNMENT)

compartment_kind_of_word :: proc "contextless" (word: u32) -> (kind: Compartment_Kind, ok: bool) {
	return enum_word.member_of_word(Compartment_Kind, u64(word))
}

// compartment_size gives the bytes of a compartment for a record of record_size bytes:
// the compartment word and the record, rounded up to a multiple of 64. 0: no
// record description has this size.
//
// Example: a record of 56 bytes has a compartment of 64; of 72 bytes, 128; the
// log record of 256 bytes, 320.
compartment_size :: proc "contextless" (record_size: u32) -> u32 {
	if record_size > module.RECORD_SIZE_LIMIT {
		return 0
	}
	return (COMPARTMENT_WORD_SIZE + record_size + COMPARTMENT_ALIGNMENT - 1) / COMPARTMENT_ALIGNMENT * COMPARTMENT_ALIGNMENT
}

// What the reader of one ring knows of the compartments before: it lives in the
// private memory of the reader, one for each ring. Zero is a ring of which
// the reader took no compartment.
Read_State :: struct {
	joined:      bool, // It took the joined record.
	ended:       bool, // It took the end record: no compartment comes after it.
	next_serial: u32, // The serial of the next record.
	// The wiring has a condition (Reader_Filter.By_Writer): the writer
	// leaves out the records that fail it, so a serial moves forward by any
	// count below SERIAL_FORWARD_MOST.
	filtered:    bool,
}

// How far a serial of a ring with a condition moves forward at most: half
// of the 32 bits, so a serial behind the next one is never taken for one
// far ahead.
SERIAL_FORWARD_MOST :: u32(1) << 31

// serial_follows says if a serial is the one that the reader takes next:
// the next serial, or on a ring with a condition a serial at or past it by
// less than SERIAL_FORWARD_MOST.
serial_follows :: proc "contextless" (state: ^Read_State, serial: u32) -> bool {
	if !state.filtered {
		return serial == state.next_serial
	}
	return serial - state.next_serial < SERIAL_FORWARD_MOST
}

// One compartment that the border took.
Taken_Compartment :: struct {
	kind:      Compartment_Kind,
	serial:    u32, // A record: its serial. A joined record: the serial of the next record. A gap: the serial of the first refused record. An end: the count of the records.
	gap_count: u32, // A gap record: the records that the writer refused, at least 1.
	error:     errors.Error_Record, // An end record: zero for a clean end.
	record:    []u8, // A record: its bytes in the copy of the compartment, of the size of the description.
}

// Why the border refuses a compartment. The error record of the refusal says
// which value and which part: `found` is 0 for the compartment as a whole and its
// word, the number of a field from 1, or the count of the fields + 1 for
// the bytes after the last field.
Compartment_Fault :: enum u8 {
	None             = 0, // The compartment is taken.
	Wrong_Size       = 1, // The copy is not of the size of a compartment of the description.
	Unknown_Kind     = 2, // The kind of the compartment word names no Compartment_Kind.
	Not_Joined_First = 3, // The first compartment of the ring is not a joined record.
	Joined_Again     = 4, // A joined record after the first compartment.
	Wrong_Serial     = 5, // The serial is not the next serial.
	After_End        = 6, // A compartment after the end record.
	Empty_Gap        = 7, // A gap record of no record.
	Unnamed_Byte     = 8, // A byte that the kind of the compartment does not name is not 0.
	Bad_Text         = 9, // A Text field is not UTF-8 with no control character, then zero bytes.
	Bad_Status       = 10, // A Status field holds a word that names no member of its contract enum.
	Bad_Field        = 11, // The description has a field that the border cannot read, or a Handle.
	Gap_Past_Window  = 12, // On a ring with a condition, a gap of SERIAL_FORWARD_MOST records or more: past it the reader cannot tell a serial ahead from one behind (gap_count_most).
}

// record_of_compartment is the border of the reader of an output ring: it takes
// one compartment, a copy in private memory of the reader of compartment_size(size)
// bytes, against the description of the record from file (a description
// that module.record_stream_type gave) and the state of the ring. It
// refuses:
//
// - a copy of another size, and a kind that names no member;
// - a first compartment that is not a joined record, a second joined record, and
//   any compartment after the end record;
// - a serial that is not the next one: the joined record gives the first,
//   each record adds 1, a gap of N adds N, and the end record holds it; on
//   a ring with a condition (state.filtered), a serial behind the next
//   one or past it by SERIAL_FORWARD_MOST or more (serial_follows);
// - a gap of 0 records, and on a ring with a condition a gap of
//   SERIAL_FORWARD_MOST records or more (gap_count_most);
// - a byte that the kind does not name and that is not 0: past the count
//   of a gap, past the error record of an end, past the compartment word of a
//   joined record, past the record in its compartment;
// - a Text field that is not UTF-8 with no control character up to its
//   first zero byte, with zero bytes after it;
// - a Status field whose word names no member of its contract enum.
//
// On a refusal the state does not change, and refusal names the value and
// the part. On a compartment that it takes, the state moves past it.
record_of_compartment :: proc "contextless" (state: ^Read_State, compartment: []u8, file: []u8, description: module.Record) -> (taken: Taken_Compartment, fault: Compartment_Fault, refusal: errors.Error_Record) {
	size := compartment_size(description.size)
	if size == 0 || len(compartment) != int(size) {
		return {}, .Wrong_Size, errors.error_make(.Bad_Value, .Bytes, 0, i64(len(compartment)), i64(size), 0)
	}
	word: Compartment_Word
	intrinsics.mem_copy_non_overlapping(&word, raw_data(compartment), COMPARTMENT_WORD_SIZE)
	kind, known := compartment_kind_of_word(word.kind)
	if !known {
		return {}, .Unknown_Kind, errors.error_make(.Bad_Value, .None, 0, i64(word.kind), i64(max(Compartment_Kind)), 0)
	}
	if state.ended {
		return {}, .After_End, errors.error_make(.State, .None, 0, i64(word.kind), 0, 0)
	}
	if !state.joined && kind != .Joined {
		return {}, .Not_Joined_First, errors.error_make(.Bad_Value, .None, 0, i64(word.kind), i64(Compartment_Kind.Joined), 0)
	}
	if state.joined && kind == .Joined {
		return {}, .Joined_Again, errors.error_make(.Bad_Value, .None, 0, i64(word.kind), 0, 0)
	}
	if state.joined && !serial_follows(state, word.serial) {
		return {}, .Wrong_Serial, errors.error_make(.Bad_Value, .Records, 0, i64(word.serial), i64(state.next_serial), 0)
	}
	taken = {kind = kind, serial = word.serial}
	// The first byte that the kind names no more: past it, each byte of
	// the compartment is 0.
	named_end := COMPARTMENT_WORD_SIZE
	next := word.serial
	switch kind {
	case .Joined:
	case .Gap:
		count := u32(compartment[GAP_COUNT_OFFSET]) | u32(compartment[GAP_COUNT_OFFSET + 1]) << 8 | u32(compartment[GAP_COUNT_OFFSET + 2]) << 16 | u32(compartment[GAP_COUNT_OFFSET + 3]) << 24
		if count == 0 {
			return {}, .Empty_Gap, errors.error_make(.Bad_Value, .Records, 0, 0, 0, 0)
		}
		if count > gap_count_most(state.filtered) {
			return {}, .Gap_Past_Window, errors.error_make(.Out_Of_Range, .Records, 0, i64(count), i64(gap_count_most(state.filtered)), 0)
		}
		taken.gap_count = count
		named_end = GAP_COUNT_OFFSET + size_of(u32)
		next = word.serial + count
	case .End:
		intrinsics.mem_copy_non_overlapping(&taken.error, &compartment[END_ERROR_OFFSET], size_of(errors.Error_Record))
		named_end = END_ERROR_OFFSET + size_of(errors.Error_Record)
	case .Record:
		record := compartment[COMPARTMENT_WORD_SIZE:][:description.size]
		field_fault, field_refusal := record_fields_check(record, file, description)
		if field_fault != .None {
			return {}, field_fault, field_refusal
		}
		taken.record = record
		named_end = COMPARTMENT_WORD_SIZE + int(description.size)
		next = word.serial + 1
	}
	for index in named_end ..< len(compartment) {
		if compartment[index] != 0 {
			part := kind == .Record ? i64(description.field_count) + 1 : 0
			return {}, .Unnamed_Byte, errors.error_make(.Bad_Value, .Bytes, 0, i64(index), i64(named_end), part)
		}
	}
	state.joined = true
	state.ended = kind == .End
	state.next_serial = next
	return taken, .None, {}
}

// record_fields_check checks the Text and Status fields of a record.
@(private = "file")
record_fields_check :: proc "contextless" (record: []u8, file: []u8, description: module.Record) -> (fault: Compartment_Fault, refusal: errors.Error_Record) {
	for number in 0 ..< description.field_count {
		part := i64(number) + 1
		item, ok := module.field(file, description, number)
		if !ok {
			return .Bad_Field, errors.error_make(.Bad_Value, .None, 0, 0, 0, part)
		}
		type, type_ok := module.field_type(item)
		kind, kind_ok := module.field_kind(item)
		if !type_ok || !kind_ok {
			return .Bad_Field, errors.error_make(.Bad_Value, .None, 0, i64(item.type), 0, part)
		}
		switch type {
		case .Text:
			bytes := module.field_text(record, item)
			if at, found := text_encoding.invalid_sequence_find(transmute([]u8)bytes); found {
				return .Bad_Text, errors.error_make(.Bad_Byte, .None, 0, i64(at), i64(item.detail), part)
			}
			// Past the text, zero bytes to the end of the field.
			for index in u32(len(bytes)) ..< item.detail {
				if record[item.offset + index] != 0 {
					return .Bad_Text, errors.error_make(.Bad_Byte, .None, 0, i64(index), i64(item.detail), part)
				}
			}
		case .Integer:
			if kind == .Status {
				which, which_ok := module.field_contract_enum(item)
				word := u64(module.field_integer(record, item))
				if _, member := module.contract_enum_member_name(which, word); !which_ok || !member {
					return .Bad_Status, errors.error_make(.Bad_Value, .None, 0, i64(word), 0, part)
				}
			}
		case .Bytes:
		case .Handle, .None, .Record, .Table, .Enum:
			return .Bad_Field, errors.error_make(.Bad_Value, .None, 0, i64(item.type), 0, part)
		}
	}
	return .None, {}
}

// The compartments that a writer writes, in its private memory before its push:
// each is compartment_size bytes, zero past what its kind names.

// joined_compartment writes the joined record: the first compartment of each ring,
// with the serial of the next record.
joined_compartment :: proc "contextless" (compartment: []u8, next_serial: u32) -> bool {
	return compartment_word_write(compartment, .Joined, next_serial)
}

// gap_compartment writes a gap record: count records from first_serial were
// refused for this reader.
gap_compartment :: proc "contextless" (compartment: []u8, first_serial: u32, count: u32) -> bool {
	if count == 0 || len(compartment) < GAP_COUNT_OFFSET + size_of(u32) {
		return false
	}
	if !compartment_word_write(compartment, .Gap, first_serial) {
		return false
	}
	for index in 0 ..< size_of(u32) {
		compartment[GAP_COUNT_OFFSET + index] = u8(count >> (8 * uint(index)))
	}
	return true
}

// end_compartment writes the end record, after the record of serial - 1, with
// its error record, zero for a clean end.
end_compartment :: proc "contextless" (compartment: []u8, serial: u32, error: errors.Error_Record) -> bool {
	if len(compartment) < END_ERROR_OFFSET + size_of(errors.Error_Record) {
		return false
	}
	if !compartment_word_write(compartment, .End, serial) {
		return false
	}
	copy_error := error
	intrinsics.mem_copy_non_overlapping(&compartment[END_ERROR_OFFSET], &copy_error, size_of(errors.Error_Record))
	return true
}

// record_compartment writes one record of the record output with its serial.
// false: the record does not fit the compartment.
record_compartment :: proc "contextless" (compartment: []u8, serial: u32, record: []u8) -> bool {
	if len(compartment) < COMPARTMENT_WORD_SIZE || len(record) > len(compartment) - COMPARTMENT_WORD_SIZE {
		return false
	}
	if !compartment_word_write(compartment, .Record, serial) {
		return false
	}
	copy(compartment[COMPARTMENT_WORD_SIZE:], record)
	return true
}

// compartment_word_write clears a compartment and writes its compartment word.
@(private = "file")
compartment_word_write :: proc "contextless" (compartment: []u8, kind: Compartment_Kind, serial: u32) -> bool {
	if len(compartment) < COMPARTMENT_WORD_SIZE {
		return false
	}
	intrinsics.mem_zero(raw_data(compartment), len(compartment))
	word := Compartment_Word{kind = u32(kind), serial = serial}
	intrinsics.mem_copy_non_overlapping(raw_data(compartment), &word, COMPARTMENT_WORD_SIZE)
	return true
}

// Why a stream ended, in the end words of the end page. Only the root
// service writes them, and only after the side that they name stopped or
// closed its end, so each queue keeps one writer. The values cross the
// border of the ring.
End_Word :: enum u32 {
	None           = 0, // The stream did not end by a stop.
	Writer_Stopped = 1, // The writer stopped with no end record: the stop cause and the stop outcome follow.
	Reader_Stopped = 2, // The reader stopped.
	Asker_Stopped  = 3, // The asker of the wiring stopped: its budget paid the ring.
	Revoked        = 4, // The asker or the principal revoked the wiring.
	Refused        = 5, // A side refused its end in its wiring ring: the wiring ends before its first record.
	// The other side closed its end (output.Wiring_Answer.Closed); the side that reads the word did not.
	// A writer that ended its stream, or that gave up past its deadline; a reader after the end record or
	// after a compartment that it refused. It carries no stop: the process of that side runs.
	Side_Closed    = 6,
}

// The name of each end word, for a line and a sentence.
@(rodata)
end_word_names := [End_Word]string {
	.None           = "None",
	.Writer_Stopped = "Writer_Stopped",
	.Reader_Stopped = "Reader_Stopped",
	.Asker_Stopped  = "Asker_Stopped",
	.Revoked        = "Revoked",
	.Refused        = "Refused",
	.Side_Closed    = "Side_Closed",
}

// What a call of the library on a record output or a record input gives
// its caller (system.output_write, system.output_end, system.input_read).
// These are not kernel statuses: no kernel operation gives them. Each one
// names what the caller learns.
Stream_Status :: enum u32 {
	Ok         = 0, // The call did its work.
	No_Reader  = 1, // The record output has no ring: nothing was written, and the library counts the record.
	No_Writer  = 2, // The record input has no ring: no record comes.
	Full       = 3, // A ring that holds the writer has no room before the deadline: nothing was written.
	Ended      = 4, // The other side ended or stopped: the end record or the end word says how.
	Bad_Record = 5, // The reader refused a compartment, or the record to write has another size than its description.
	No_Record  = 6, // The deadline of a read passed, and no compartment came.
}

// The end words of a wiring: the first bytes of the end page, a memory
// object of END_WORDS_PAGES that the root service makes for each wiring,
// writes alone, and gives each side with the right Read only. In the head
// page of the ring, which both sides write, either side could forge the
// end of the other.
End_Words :: struct {
	end:          u32, // The word of an End_Word. The root service writes it last; a side waits on it with its queue.
	stop_cause:   u32, // Writer_Stopped: the word of the stop cause of the writer. 0 for each other end.
	stop_outcome: u32, // Writer_Stopped: the word of the stop outcome of the writer. 0 for each other end.
	reserved:     [13]u32, // 0.
}
#assert(size_of(End_Words) == 64)

// The pages of the end page of a wiring.
END_WORDS_PAGES :: 1

// end_words_write writes the end words in the end page of a wiring: the
// stop cause and the stop outcome first, then the end word, so that a side
// that sees the end word sees the two words with it. The root service
// calls it, then wakes each side that waits on the end word.
end_words_write :: proc "contextless" (words: ^End_Words, end: End_Word, stop_cause: op.Stop_Cause = .None, stop_outcome: op.Stop_Outcome = .None) {
	intrinsics.atomic_store_explicit(&words.stop_cause, u32(stop_cause), .Relaxed)
	intrinsics.atomic_store_explicit(&words.stop_outcome, u32(stop_outcome), .Relaxed)
	intrinsics.atomic_store_explicit(&words.end, u32(end), .Release)
}

// end_words_read copies the end words of an end page: the end word first,
// then the others. A reader takes the copy through end_of_words, and reads
// it only when its queue is empty: each record that the writer published
// before its stop comes first.
end_words_read :: proc "contextless" (words: ^End_Words) -> (copy_of_words: End_Words) {
	copy_of_words.end = intrinsics.atomic_load_explicit(&words.end, .Acquire)
	copy_of_words.stop_cause = intrinsics.atomic_load_explicit(&words.stop_cause, .Relaxed)
	copy_of_words.stop_outcome = intrinsics.atomic_load_explicit(&words.stop_outcome, .Relaxed)
	for index in 0 ..< len(words.reserved) {
		copy_of_words.reserved[index] = intrinsics.atomic_load_explicit(&words.reserved[index], .Relaxed)
	}
	return copy_of_words
}

// end_of_words is the border of the end words: the end, and for
// Writer_Stopped the words of the stop cause and of the stop outcome, which
// the reader takes through the border of the stop
// (src/md/api/process_stop.md). It refuses an end word that names no
// member, a stop word beside another end than Writer_Stopped, a
// Writer_Stopped whose two words are not a stop that the border of the stop
// takes, and a reserved word that is not 0.
end_of_words :: proc "contextless" (words: End_Words) -> (end: End_Word, stop_cause: op.Stop_Cause, stop_outcome: op.Stop_Outcome, ok: bool) {
	member, known := enum_word.member_of_word(End_Word, u64(words.end))
	if !known || (words.reserved != [13]u32{}) {
		return {}, {}, {}, false
	}
	if member != .Writer_Stopped {
		if words.stop_cause != 0 || words.stop_outcome != 0 {
			return {}, {}, {}, false
		}
		return member, .None, .None, true
	}
	_, cause, outcome, stop_known := op.stop_of_words(u64(op.Process_State.Stopped), u64(words.stop_cause), u64(words.stop_outcome))
	if !stop_known {
		return {}, {}, {}, false
	}
	return member, cause, outcome, true
}

// What a completion of an output ring says. The reader writes a completion
// for a compartment that it refuses and for the end record, never for a record
// that it takes: the counter `read` of the queue says that. The values
// cross the border of the ring.
Completion_Kind :: enum u32 {
	End_Taken  = 0, // The reader took the end record. The tag is the serial of the end.
	Bad_Record = 1, // The reader refused a compartment. The tag is its serial, the values its error record.
}

// refusal_completion gives the completion of a refused compartment.
refusal_completion :: proc "contextless" (serial: u32, refusal: errors.Error_Record) -> ring.Record {
	return {kind = u32(Completion_Kind.Bad_Record), tag = serial, values = errors.completion_values(refusal)}
}

// end_completion gives the completion of the end record.
end_completion :: proc "contextless" (serial: u32) -> ring.Record {
	return {kind = u32(Completion_Kind.End_Taken), tag = serial}
}

// completion_of_record is the border of the writer for a completion: its
// kind, the serial, and the error record of a refusal. It refuses a kind
// that names no member, and an End_Taken with values that are not 0.
completion_of_record :: proc "contextless" (record: ring.Record) -> (kind: Completion_Kind, serial: u32, refusal: errors.Error_Record, ok: bool) {
	member, known := enum_word.member_of_word(Completion_Kind, u64(record.kind))
	if !known {
		return {}, 0, {}, false
	}
	if member == .End_Taken && (record.values != [7]u64{}) {
		return {}, 0, {}, false
	}
	return member, record.tag, errors.completion_record(record.values), true
}
