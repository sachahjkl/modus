// The output ring: the places that carry the records of one record output
// to one reader (src/md/features/module_outputs.md, "The ring and its
// records").
//
// An output ring is a ring of places (`ring.place_open`): its command queue
// holds one place for each record, its completion queue the records of 64
// bytes of each ring. A place is the place word, then the record, rounded up
// to a multiple of 64 bytes (`place_size`). Each side computes the size of a
// place from the record description that it holds, never from the shared
// memory.
//
// The writer writes a joined record first, then the records of the record
// output with their serials, a gap record where it refused records for this
// reader, and an end record at its end. The reader copies each place once
// into private memory, then takes it through one border,
// `record_of_place`, which checks it against the record description and
// against the places before it. The root service writes the end words in
// the head page when a side stops (`end_words_write`), and the reader takes
// them through `end_of_words`.
//
// Who uses it: the library of each process that declares a record output or
// a record input, the console, and the root service for the end words. The
// parts:
//
// - `Place_Kind`, `Place_Word`, `place_size`: the form of a place.
// - `Read_State`, `Taken_Place`, `Place_Fault`, `record_of_place`: the
//   border of the reader.
// - `joined_place`, `gap_place`, `end_place`, `record_place`: the places
//   that a writer writes.
// - `End_Word`, `End_Words`, `end_words_write`, `end_words_read`,
//   `end_of_words`: the end words of the root service.
// - `Completion_Kind`, `refusal_completion`, `completion_of_record`: the
//   completion queue.
//
// See [output ring](term:output-ring) and [place word](term:place-word).
package output

import "base:intrinsics"
import "modus:contract/enum_word"
import "modus:contract/errors"
import "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:contract/text_encoding"

// The bytes of the place word, at the start of each place.
PLACE_WORD_SIZE :: 8

// The bytes that each place is a multiple of: one Record of a ring.
PLACE_ALIGNMENT :: size_of(ring.Record)

// The bytes of the largest place: the place word and the largest record of
// a record description, rounded up.
PLACE_SIZE_MOST :: (PLACE_WORD_SIZE + module.RECORD_SIZE_LIMIT + PLACE_ALIGNMENT - 1) / PLACE_ALIGNMENT * PLACE_ALIGNMENT
#assert(PLACE_SIZE_MOST <= ring.PLACE_SIZE_LIMIT)

// What a place holds. The values cross the border of the ring.
Place_Kind :: enum u32 {
	Record = 0, // One record of the record output, after the place word. A zero place is a record of serial 0.
	Gap    = 1, // The writer refused records for this reader: their count is GAP_COUNT_OFFSET, and the serial is the serial of the first one.
	End    = 2, // The end of the stream: an errors.Error_Record at END_ERROR_OFFSET, zero for a clean end.
	Joined = 3, // The first place of each ring: the serial is the serial of the next record, the count of the records written before this reader joined.
}

// The first 8 bytes of each place.
Place_Word :: struct {
	kind:   u32, // The word of a Place_Kind (place_kind_of_word).
	serial: u32, // The serial of the record in the record output, from 0: the same in each ring of the record output.
}
#assert(size_of(Place_Word) == PLACE_WORD_SIZE)

// Where a gap record holds its count, and an end record its error record.
GAP_COUNT_OFFSET :: PLACE_WORD_SIZE
END_ERROR_OFFSET :: PLACE_WORD_SIZE
#assert(END_ERROR_OFFSET + size_of(errors.Error_Record) <= PLACE_ALIGNMENT)

place_kind_of_word :: proc "contextless" (word: u32) -> (kind: Place_Kind, ok: bool) {
	return enum_word.member_of_word(Place_Kind, u64(word))
}

// place_size gives the bytes of a place for a record of record_size bytes:
// the place word and the record, rounded up to a multiple of 64. 0: no
// record description has this size.
//
// Example: a record of 56 bytes has a place of 64; of 72 bytes, 128; the
// log record of 256 bytes, 320.
place_size :: proc "contextless" (record_size: u32) -> u32 {
	if record_size > module.RECORD_SIZE_LIMIT {
		return 0
	}
	return (PLACE_WORD_SIZE + record_size + PLACE_ALIGNMENT - 1) / PLACE_ALIGNMENT * PLACE_ALIGNMENT
}

// What the reader of one ring knows of the places before: it lives in the
// private memory of the reader, one for each ring. Zero is a ring of which
// the reader took no place.
Read_State :: struct {
	joined:      bool, // It took the joined record.
	ended:       bool, // It took the end record: no place comes after it.
	next_serial: u32, // The serial of the next record.
}

// One place that the border took.
Taken_Place :: struct {
	kind:      Place_Kind,
	serial:    u32, // A record: its serial. A joined record: the serial of the next record. A gap: the serial of the first refused record. An end: the count of the records.
	gap_count: u32, // A gap record: the records that the writer refused, at least 1.
	error:     errors.Error_Record, // An end record: zero for a clean end.
	record:    []u8, // A record: its bytes in the copy of the place, of the size of the description.
}

// Why the border refuses a place. The error record of the refusal says
// which value and which part: `found` is 0 for the place as a whole and its
// word, the number of a field from 1, or the count of the fields + 1 for
// the bytes after the last field.
Place_Fault :: enum u8 {
	None             = 0, // The place is taken.
	Wrong_Size       = 1, // The copy is not of the size of a place of the description.
	Unknown_Kind     = 2, // The kind of the place word names no Place_Kind.
	Not_Joined_First = 3, // The first place of the ring is not a joined record.
	Joined_Again     = 4, // A joined record after the first place.
	Wrong_Serial     = 5, // The serial is not the next serial.
	After_End        = 6, // A place after the end record.
	Empty_Gap        = 7, // A gap record of no record.
	Unnamed_Byte     = 8, // A byte that the kind of the place does not name is not 0.
	Bad_Text         = 9, // A Text field is not UTF-8 with no control character, then zero bytes.
	Bad_Status       = 10, // A Status field holds a word that names no member of its contract enum.
	Bad_Field        = 11, // The description has a field that the border cannot read, or a Handle.
}

// record_of_place is the border of the reader of an output ring: it takes
// one place, a copy in private memory of the reader of place_size(size)
// bytes, against the description of the record from file (a description
// that module.record_stream_type gave) and the state of the ring. It
// refuses:
//
// - a copy of another size, and a kind that names no member;
// - a first place that is not a joined record, a second joined record, and
//   any place after the end record;
// - a serial that is not the next one: the joined record gives the first,
//   each record adds 1, a gap of N adds N, and the end record holds it;
// - a gap of 0 records;
// - a byte that the kind does not name and that is not 0: past the count
//   of a gap, past the error record of an end, past the place word of a
//   joined record, past the record in its place;
// - a Text field that is not UTF-8 with no control character up to its
//   first zero byte, with zero bytes after it;
// - a Status field whose word names no member of its contract enum.
//
// On a refusal the state does not change, and refusal names the value and
// the part. On a place that it takes, the state moves past it.
record_of_place :: proc "contextless" (state: ^Read_State, place: []u8, file: []u8, description: module.Record) -> (taken: Taken_Place, fault: Place_Fault, refusal: errors.Error_Record) {
	size := place_size(description.size)
	if size == 0 || len(place) != int(size) {
		return {}, .Wrong_Size, errors.error_make(.Bad_Value, .Bytes, 0, i64(len(place)), i64(size), 0)
	}
	word: Place_Word
	intrinsics.mem_copy_non_overlapping(&word, raw_data(place), PLACE_WORD_SIZE)
	kind, known := place_kind_of_word(word.kind)
	if !known {
		return {}, .Unknown_Kind, errors.error_make(.Bad_Value, .None, 0, i64(word.kind), i64(max(Place_Kind)), 0)
	}
	if state.ended {
		return {}, .After_End, errors.error_make(.State, .None, 0, i64(word.kind), 0, 0)
	}
	if !state.joined && kind != .Joined {
		return {}, .Not_Joined_First, errors.error_make(.Bad_Value, .None, 0, i64(word.kind), i64(Place_Kind.Joined), 0)
	}
	if state.joined && kind == .Joined {
		return {}, .Joined_Again, errors.error_make(.Bad_Value, .None, 0, i64(word.kind), 0, 0)
	}
	if state.joined && word.serial != state.next_serial {
		return {}, .Wrong_Serial, errors.error_make(.Bad_Value, .Records, 0, i64(word.serial), i64(state.next_serial), 0)
	}
	taken = {kind = kind, serial = word.serial}
	// The first byte that the kind names no more: past it, each byte of
	// the place is 0.
	named_end := PLACE_WORD_SIZE
	next := word.serial
	switch kind {
	case .Joined:
	case .Gap:
		count := u32(place[GAP_COUNT_OFFSET]) | u32(place[GAP_COUNT_OFFSET + 1]) << 8 | u32(place[GAP_COUNT_OFFSET + 2]) << 16 | u32(place[GAP_COUNT_OFFSET + 3]) << 24
		if count == 0 {
			return {}, .Empty_Gap, errors.error_make(.Bad_Value, .Records, 0, 0, 0, 0)
		}
		taken.gap_count = count
		named_end = GAP_COUNT_OFFSET + size_of(u32)
		next = word.serial + count
	case .End:
		intrinsics.mem_copy_non_overlapping(&taken.error, &place[END_ERROR_OFFSET], size_of(errors.Error_Record))
		named_end = END_ERROR_OFFSET + size_of(errors.Error_Record)
	case .Record:
		record := place[PLACE_WORD_SIZE:][:description.size]
		field_fault, field_refusal := record_fields_check(record, file, description)
		if field_fault != .None {
			return {}, field_fault, field_refusal
		}
		taken.record = record
		named_end = PLACE_WORD_SIZE + int(description.size)
		next = word.serial + 1
	}
	for index in named_end ..< len(place) {
		if place[index] != 0 {
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
record_fields_check :: proc "contextless" (record: []u8, file: []u8, description: module.Record) -> (fault: Place_Fault, refusal: errors.Error_Record) {
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
				if _, member := op.contract_enum_member_name(which, word); !which_ok || !member {
					return .Bad_Status, errors.error_make(.Bad_Value, .None, 0, i64(word), 0, part)
				}
			}
		case .Bytes:
		case .Handle, .None, .Record, .Table:
			return .Bad_Field, errors.error_make(.Bad_Value, .None, 0, i64(item.type), 0, part)
		}
	}
	return .None, {}
}

// The places that a writer writes, in its private memory before its push:
// each is place_size bytes, zero past what its kind names.

// joined_place writes the joined record: the first place of each ring,
// with the serial of the next record.
joined_place :: proc "contextless" (place: []u8, next_serial: u32) -> bool {
	return place_word_write(place, .Joined, next_serial)
}

// gap_place writes a gap record: count records from first_serial were
// refused for this reader.
gap_place :: proc "contextless" (place: []u8, first_serial: u32, count: u32) -> bool {
	if count == 0 || len(place) < GAP_COUNT_OFFSET + size_of(u32) {
		return false
	}
	if !place_word_write(place, .Gap, first_serial) {
		return false
	}
	for index in 0 ..< size_of(u32) {
		place[GAP_COUNT_OFFSET + index] = u8(count >> (8 * uint(index)))
	}
	return true
}

// end_place writes the end record, after the record of serial - 1, with
// its error record, zero for a clean end.
end_place :: proc "contextless" (place: []u8, serial: u32, error: errors.Error_Record) -> bool {
	if len(place) < END_ERROR_OFFSET + size_of(errors.Error_Record) {
		return false
	}
	if !place_word_write(place, .End, serial) {
		return false
	}
	copy_error := error
	intrinsics.mem_copy_non_overlapping(&place[END_ERROR_OFFSET], &copy_error, size_of(errors.Error_Record))
	return true
}

// record_place writes one record of the record output with its serial.
// false: the record does not fit the place.
record_place :: proc "contextless" (place: []u8, serial: u32, record: []u8) -> bool {
	if len(place) < PLACE_WORD_SIZE || len(record) > len(place) - PLACE_WORD_SIZE {
		return false
	}
	if !place_word_write(place, .Record, serial) {
		return false
	}
	copy(place[PLACE_WORD_SIZE:], record)
	return true
}

// place_word_write clears a place and writes its place word.
@(private = "file")
place_word_write :: proc "contextless" (place: []u8, kind: Place_Kind, serial: u32) -> bool {
	if len(place) < PLACE_WORD_SIZE {
		return false
	}
	intrinsics.mem_zero(raw_data(place), len(place))
	word := Place_Word{kind = u32(kind), serial = serial}
	intrinsics.mem_copy_non_overlapping(raw_data(place), &word, PLACE_WORD_SIZE)
	return true
}

// Why a stream ended, in the end words of the head page. Only the root
// service writes them, and only after the side that they name stopped, so
// each queue keeps one writer. The values cross the border of the ring.
End_Word :: enum u32 {
	None           = 0, // The stream did not end by a stop.
	Writer_Stopped = 1, // The writer stopped with no end record: the stop cause and the stop outcome follow.
	Reader_Stopped = 2, // The reader stopped, or closed its end.
	Asker_Stopped  = 3, // The asker of the wiring stopped: its budget paid the ring.
	Revoked        = 4, // The asker or the principal revoked the wiring.
}

// The end words: one line of the cache in the head page, in the half of
// the command queue, past its counters. Neither side writes them.
End_Words :: struct {
	end:          u32, // The word of an End_Word. The root service writes it last.
	stop_cause:   u32, // Writer_Stopped: the word of the stop cause of the writer. 0 for each other end.
	stop_outcome: u32, // Writer_Stopped: the word of the stop outcome of the writer. 0 for each other end.
	reserved:     [13]u32, // 0.
}
#assert(size_of(End_Words) == 64)

// The place of the end words in the head page.
END_WORDS_OFFSET :: 1024
#assert(END_WORDS_OFFSET >= size_of(ring.Counters) && END_WORDS_OFFSET + size_of(End_Words) <= offset_of(ring.Head, completions))

// end_words_write writes the end words in the head page of a ring: the stop
// cause and the stop outcome first, then the end word, so that a reader
// that sees the end word sees the two words with it. The root service
// calls it, then wakes the side that remains.
end_words_write :: proc "contextless" (head: ^ring.Head, end: End_Word, stop_cause: u32 = 0, stop_outcome: u32 = 0) {
	words := (^End_Words)(uintptr(head) + END_WORDS_OFFSET)
	intrinsics.atomic_store_explicit(&words.stop_cause, stop_cause, .Relaxed)
	intrinsics.atomic_store_explicit(&words.stop_outcome, stop_outcome, .Relaxed)
	intrinsics.atomic_store_explicit(&words.end, u32(end), .Release)
}

// end_words_read copies the end words of the head page: the end word
// first, then the others. A reader takes the copy through end_of_words, and
// reads it only when its queue is empty: each record that the writer
// published before its stop comes first.
end_words_read :: proc "contextless" (head: ^ring.Head) -> (copy_of_words: End_Words) {
	words := (^End_Words)(uintptr(head) + END_WORDS_OFFSET)
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
// member, a stop word beside another end than Writer_Stopped, and a
// reserved word that is not 0.
end_of_words :: proc "contextless" (words: End_Words) -> (end: End_Word, stop_cause: u32, stop_outcome: u32, ok: bool) {
	member, known := enum_word.member_of_word(End_Word, u64(words.end))
	if !known || words.reserved != [13]u32{} {
		return {}, 0, 0, false
	}
	if member != .Writer_Stopped && (words.stop_cause != 0 || words.stop_outcome != 0) {
		return {}, 0, 0, false
	}
	return member, words.stop_cause, words.stop_outcome, true
}

// What a completion of an output ring says. The reader writes a completion
// for a place that it refuses and for the end record, never for a record
// that it takes: the counter `read` of the queue says that. The values
// cross the border of the ring.
Completion_Kind :: enum u32 {
	End_Taken  = 0, // The reader took the end record. The tag is the serial of the end.
	Bad_Record = 1, // The reader refused a place. The tag is its serial, the values its error record.
}

// refusal_completion gives the completion of a refused place.
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
	if member == .End_Taken && record.values != [7]u64{} {
		return {}, 0, {}, false
	}
	return member, record.tag, errors.completion_record(record.values), true
}
