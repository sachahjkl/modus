package output

import "modus:contract/enum_word"
import "modus:contract/errors"
import "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/ring"

// The wiring ring: the ring from the root service to a process whose
// module declares a record output or a record input
// (src/md/features/module_outputs.md, "The wiring and its rights"). It is
// the handle op.CONTEXT_WIRING_RING of the context, a ring of `ring.open`
// with records of 64 bytes. The root service writes one command for each
// end of a wiring of the process; the process reads it through
// given_end_of_record, proves its handles, and answers with one completion
// (wiring_completion), then with the word Closed when it closes the end
// (wiring_closed_completion). No command ends an end: the end of a wiring
// is in the end words of its output ring.
//
// The root service gives each handle of a command with `Handle_Give` and
// the memory of the wiring ring as its target, so the process proves with
// `Handle_State` that the handle came through the wiring ring.
//
// See [wiring ring](term:wiring-ring) and [wiring](term:wiring).

// The records of each queue of the smallest wiring ring, and its pages.
// The root service makes a larger one, of the next power of two, for a
// start whose wiring list names more ends of the child.
WIRING_RING_CAPACITY :: ring.CAPACITY
WIRING_RING_PAGES :: ring.PAGE_COUNT
#assert(WIRING_RING_PAGES == 1 + WIRING_RING_CAPACITY / ring.CAPACITY)

// How a wiring holds its writer when the output ring is full. The asker
// chooses it; the writer receives it with its end, and its library applies
// it at each write. The values cross the border of the wiring ring.
Wiring_Pace :: enum u32 {
	Writer_Chooses      = 0, // The writer waits or refuses by its own call.
	Never_Holds_Writer  = 1, // A full ring refuses the record for this reader alone, which gets a gap record; the writer never waits for it.
	Always_Holds_Writer = 2, // The writer waits for room in this ring whatever its call says, up to its deadline: the pace of an audit.
}

// What one command of the wiring ring gives the process. 0 names nothing.
// The values cross the border of the wiring ring.
Wiring_Command :: enum u32 {
	None       = 0, // Refused, as a word that names no command.
	Writer_End = 1, // The process writes the output ring: values[WIRING_VALUE_INDEX] is its record output.
	Reader_End = 2, // The process reads the output ring: values[WIRING_VALUE_INDEX] is its record input.
	Asker_End  = 3, // The process reads the output ring as the asker of the wiring, with no record input: values[WIRING_VALUE_INDEX] is 0, and the tag is the number of the wiring that the completion of its command gave.
}

// The index of each word in the values of a command of the wiring ring.
// The error record of a refused word has the argument index + 1; the
// argument 0 is the kind.
WIRING_VALUE_RING :: 0 // The handle of the output ring, with Read and Write, given through the wiring ring.
WIRING_VALUE_INDEX :: 1 // The index of the record output or the record input in the tables of the module, from 1.
WIRING_VALUE_PACE :: 2 // A writer end: the word of its Wiring_Pace. A reader end: 0.
WIRING_VALUE_TERMS :: 3 // A reader end: the handle of a memory object with its wiring terms at offset 0, with Read only, given through the wiring ring; or 0. A writer end: the handle of the page of its Writer_Condition, with Read only; or 0. An asker end: 0.
WIRING_VALUE_DESCRIPTION :: 4 // A reader end: the handle of its description file (description_file_write), with Read only, given through the wiring ring; never 0. A writer end: 0.
WIRING_VALUE_END_WORDS :: 5 // Each end: the handle of the end page of the wiring (End_Words), with Read only, given through the wiring ring; never 0.
WIRING_VALUE_FILTER :: 6 // A reader end: the word of its Reader_Filter. A writer end: 0.

// Whether the writer leaves out records of a ring: the wiring has a
// condition. 0 names no condition. The values cross the border of the
// wiring ring.
Reader_Filter :: enum u64 {
	None      = 0, // Each record of the record output comes, and the serials follow one another.
	By_Writer = 1, // The writer writes only the records that pass the condition of the wiring: the serials move forward by any count.
}

// One end that the process took from the wiring ring. It lives in the
// private memory of the process. The handles are numbers that the root
// service wrote: the library proves each one with `Handle_State` and the
// memory of the wiring ring before it maps it.
Given_End :: struct {
	command: Wiring_Command, // Writer_End or Reader_End.
	tag:     u32, // The number of the wiring, which the completion carries back.
	ring:    op.Handle, // The output ring.
	index:   u32, // The record output or the record input, from 1 to module.RECORD_STREAM_INDEX_MOST.
	pace:    Wiring_Pace, // A writer end: its pace. A reader end: Writer_Chooses, which it does not read.
	terms:   op.Handle, // A reader end: the memory of its wiring terms, or 0.
	description: op.Handle, // A reader end: the memory of its description file. A writer end: 0.
	end_words: op.Handle, // Each end: the end page of the wiring, which the root service alone writes.
	condition: op.Handle, // A writer end: the page of its Writer_Condition, or 0. A reader end: 0.
	filter:    Reader_Filter, // A reader end: whether the writer leaves out records. A writer end: None.
}

// given_end_of_record is the border of a command of the wiring ring: the
// one place where its words become a Given_End. It refuses:
//
// - a kind that names no Wiring_Command, and None;
// - a ring handle of 0, or past 32 bits;
// - an index of 0, or past module.RECORD_STREAM_INDEX_MOST;
// - an end page of 0, or past 32 bits;
// - a description file beside a writer end, and none or one past 32 bits
//   beside a reader end;
// - for a writer end, a pace that names no Wiring_Pace, a condition page
//   past 32 bits, and a filter word that is not 0;
// - for a reader end, a pace word that is not 0, a terms handle past 32
//   bits, and a filter word that names no Reader_Filter;
// - for an asker end, a terms handle that is not 0.
//
// The refusal is Bad_Value: its argument is the index of the word + 1, or
// 0 for the kind, its value the word (at most 2^62), and its limit the
// largest word that the border takes there. It reads no state.
given_end_of_record :: proc "contextless" (record: ring.Record) -> (end: Given_End, refusal: errors.Error_Record, ok: bool) {
	command, known := enum_word.member_of_word(Wiring_Command, u64(record.kind))
	if !known || command == .None {
		return {}, word_refusal(0, u64(record.kind), u64(max(Wiring_Command))), false
	}
	values := record.values
	if values[WIRING_VALUE_RING] == 0 || values[WIRING_VALUE_RING] > u64(max(u32)) {
		return {}, word_refusal(WIRING_VALUE_RING + 1, values[WIRING_VALUE_RING], u64(max(u32))), false
	}
	// The asker reads with no declared record input: its end names none.
	if command == .Asker_End {
		if values[WIRING_VALUE_INDEX] != 0 {
			return {}, word_refusal(WIRING_VALUE_INDEX + 1, values[WIRING_VALUE_INDEX], 0), false
		}
	} else if values[WIRING_VALUE_INDEX] == 0 || values[WIRING_VALUE_INDEX] > module.RECORD_STREAM_INDEX_MOST {
		return {}, word_refusal(WIRING_VALUE_INDEX + 1, values[WIRING_VALUE_INDEX], module.RECORD_STREAM_INDEX_MOST), false
	}
	// Each end reads the end of its wiring in the end page: an end with
	// none would never learn it.
	if values[WIRING_VALUE_END_WORDS] == 0 || values[WIRING_VALUE_END_WORDS] > u64(max(u32)) {
		return {}, word_refusal(WIRING_VALUE_END_WORDS + 1, values[WIRING_VALUE_END_WORDS], u64(max(u32))), false
	}
	end = {command = command, tag = record.tag, ring = op.Handle(values[WIRING_VALUE_RING]), index = u32(values[WIRING_VALUE_INDEX]), end_words = op.Handle(values[WIRING_VALUE_END_WORDS])}
	switch command {
	case .Writer_End:
		pace, pace_known := enum_word.member_of_word(Wiring_Pace, values[WIRING_VALUE_PACE])
		if !pace_known {
			return {}, word_refusal(WIRING_VALUE_PACE + 1, values[WIRING_VALUE_PACE], u64(max(Wiring_Pace))), false
		}
		// The word of the terms is the page of the condition of the
		// wiring, or 0.
		if values[WIRING_VALUE_TERMS] > u64(max(u32)) {
			return {}, word_refusal(WIRING_VALUE_TERMS + 1, values[WIRING_VALUE_TERMS], u64(max(u32))), false
		}
		if values[WIRING_VALUE_DESCRIPTION] != 0 {
			return {}, word_refusal(WIRING_VALUE_DESCRIPTION + 1, values[WIRING_VALUE_DESCRIPTION], 0), false
		}
		if values[WIRING_VALUE_FILTER] != 0 {
			return {}, word_refusal(WIRING_VALUE_FILTER + 1, values[WIRING_VALUE_FILTER], 0), false
		}
		end.pace = pace
		end.condition = op.Handle(values[WIRING_VALUE_TERMS])
	case .Reader_End, .Asker_End:
		if values[WIRING_VALUE_PACE] != 0 {
			return {}, word_refusal(WIRING_VALUE_PACE + 1, values[WIRING_VALUE_PACE], 0), false
		}
		// The asker declares no record input, so it takes no terms.
		terms_most := command == .Asker_End ? u64(0) : u64(max(u32))
		if values[WIRING_VALUE_TERMS] > terms_most {
			return {}, word_refusal(WIRING_VALUE_TERMS + 1, values[WIRING_VALUE_TERMS], terms_most), false
		}
		end.terms = op.Handle(values[WIRING_VALUE_TERMS])
		// A reader checks each record against its description file: an
		// end with none cannot be read.
		if values[WIRING_VALUE_DESCRIPTION] == 0 || values[WIRING_VALUE_DESCRIPTION] > u64(max(u32)) {
			return {}, word_refusal(WIRING_VALUE_DESCRIPTION + 1, values[WIRING_VALUE_DESCRIPTION], u64(max(u32))), false
		}
		end.description = op.Handle(values[WIRING_VALUE_DESCRIPTION])
		filter, filter_known := enum_word.member_of_word(Reader_Filter, values[WIRING_VALUE_FILTER])
		if !filter_known {
			return {}, word_refusal(WIRING_VALUE_FILTER + 1, values[WIRING_VALUE_FILTER], u64(max(Reader_Filter))), false
		}
		end.filter = filter
	case .None:
		// The check of the kind above refused None: the case keeps the
		// switch whole.
		return {}, word_refusal(0, u64(record.kind), u64(max(Wiring_Command))), false
	}
	return end, {}, true
}

// word_refusal is the error record of a word of the wiring ring that the
// border refuses.
@(private = "file")
word_refusal :: proc "contextless" (argument: int, word: u64, largest: u64) -> errors.Error_Record {
	return errors.error_make(.Bad_Value, .None, i64(argument), i64(min(word, 1 << 62)), i64(min(largest, 1 << 62)))
}

// given_end_record gives the command of one end, as the root service
// writes it in the wiring ring. The words that the kind does not use are
// 0, so given_end_of_record takes the record back as it was.
given_end_record :: proc "contextless" (end: Given_End) -> ring.Record {
	record := ring.Record{kind = u32(end.command), tag = end.tag}
	record.values[WIRING_VALUE_RING] = u64(end.ring)
	record.values[WIRING_VALUE_INDEX] = u64(end.index)
	record.values[WIRING_VALUE_END_WORDS] = u64(end.end_words)
	switch end.command {
	case .Writer_End:
		record.values[WIRING_VALUE_PACE] = u64(end.pace)
		record.values[WIRING_VALUE_TERMS] = u64(end.condition)
	case .Reader_End, .Asker_End:
		record.values[WIRING_VALUE_TERMS] = u64(end.terms)
		record.values[WIRING_VALUE_DESCRIPTION] = u64(end.description)
		record.values[WIRING_VALUE_FILTER] = u64(end.filter)
	case .None:
	}
	return record
}

// What an Ok completion says of its end, in values[WIRING_ANSWER_VALUE].
// Each end has two words at most: its answer to the command, then the
// word Closed when the process closed the end. The values cross the
// border of the wiring ring.
Wiring_Answer :: enum u64 {
	Taken  = 0, // The process took the end: the answer to its command.
	Closed = 1, // The process closed the end that it took: after the end of the stream, or after a fault of the other side. The root service frees the count of that side; a wiring whose two sides closed ends.
}

WIRING_ANSWER_VALUE :: 0

// wiring_completion gives the answer of the process to one command: Ok
// when it took the end, else the status and the error record of its
// refusal. The tag is the tag of the command.
wiring_completion :: proc "contextless" (tag: u32, status: op.Status, refusal: errors.Error_Record = {}) -> ring.Record {
	if status == .Ok {
		return {kind = u32(op.Status.Ok), tag = tag}
	}
	return {kind = u32(status), tag = tag, values = errors.completion_values(refusal)}
}

// wiring_closed_completion gives the word Closed of an end that the
// process took and closed. The tag is the tag of its command.
wiring_closed_completion :: proc "contextless" (tag: u32) -> ring.Record {
	record := ring.Record{kind = u32(op.Status.Ok), tag = tag}
	record.values[WIRING_ANSWER_VALUE] = u64(Wiring_Answer.Closed)
	return record
}

// wiring_completion_of_record is the border of the root service for a
// completion of the wiring ring: the status, the tag of the command, the
// answer of an Ok, and the error record of a refusal. It refuses a status
// that names no member, an Ok whose answer word names no Wiring_Answer,
// and an Ok with another value that is not 0. The root service takes one
// answer and one Closed for each end it gave, and drops each later word.
wiring_completion_of_record :: proc "contextless" (record: ring.Record) -> (status: op.Status, tag: u32, answer: Wiring_Answer, refusal: errors.Error_Record, ok: bool) {
	member, known := op.status_of_word(u64(record.kind))
	if !known {
		return {}, 0, {}, {}, false
	}
	if member != .Ok {
		return member, record.tag, .Taken, errors.completion_record(record.values), true
	}
	answer_word, answer_known := enum_word.member_of_word(Wiring_Answer, record.values[WIRING_ANSWER_VALUE])
	if !answer_known {
		return {}, 0, {}, {}, false
	}
	for index in WIRING_ANSWER_VALUE + 1 ..< len(record.values) {
		if record.values[index] != 0 {
			return {}, 0, {}, {}, false
		}
	}
	return .Ok, record.tag, answer_word, {}, true
}

// wiring_ring_capacity gives the capacity of the wiring ring of a process
// whose start gives end_count ends: WIRING_RING_CAPACITY, or the next
// power of two that holds them. false: no ring holds them
// (ring.CAPACITY_LIMIT).
wiring_ring_capacity :: proc "contextless" (end_count: u64) -> (capacity: u32, ok: bool) {
	if end_count > ring.CAPACITY_LIMIT {
		return 0, false
	}
	capacity = WIRING_RING_CAPACITY
	for u64(capacity) < end_count {
		capacity *= 2
	}
	return capacity, true
}
