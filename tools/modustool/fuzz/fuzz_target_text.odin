package fuzz

import "core:mem"
import "core:slice"
import "core:unicode/utf8"
import "modus:contract/cut_mark"
import "modus:contract/errors"
import module "modus:contract/module"
import "modus:contract/text_encoding"
import "modus:contract/value_kinds"
import "modus:support/sentence"
import "modustool:foundation"

// The fuzz targets of the text between processes
// (src/md/infrastructure/fuzzing.md, "The targets, in order of value"):
// the check of a text that each border calls, the value runs that a
// process gives with a line of the log and that the kernel cuts into its
// records, and the sentences that a process writes for an error record of
// another process.

// ---------------------------------------------------------------------
// The text encoding check.

// fuzz_invalid_sequence_of_library finds the first invalid sequence with
// the reader of UTF-8 of the Odin library and the rule of the control
// characters: a second reader of the same rule.
@(private = "file")
fuzz_invalid_sequence_of_library :: proc(bytes: []u8) -> (place: int, found: bool) {
	for place < len(bytes) {
		character, length := utf8.decode_rune_in_bytes(bytes[place:])
		control := character < 0x20 || character >= 0x7F && character <= 0x9F
		if character == utf8.RUNE_ERROR && length == 1 || control {
			return place, true
		}
		place += length
	}
	return 0, false
}

// fuzz_text_encoding_execute: the check agrees with the reader of the
// Odin library; each character that it decodes encodes to its own bytes; a
// text with its invalid sequences replaced passes the check and keeps each
// valid character; a cut of a valid text ends on a whole character; and an
// identifier is a valid text. No reader changes the bytes.
fuzz_text_encoding_execute :: proc(input: []u8) -> Fuzz_Verdict {
	before := slice.clone(input, context.temp_allocator)
	place, found := text_encoding.invalid_sequence_find(input)
	valid := text_encoding.text_valid(input)
	if valid == found || found && (place < 0 || place >= len(input)) || !found && place != 0 {
		return fuzz_broken(.Contract, "invalid_sequence_find gives %d, %v and text_valid %v", place, found, valid)
	}
	if other_place, other_found := fuzz_invalid_sequence_of_library(input); other_found != found || found && other_place != place {
		return fuzz_broken(.Two_Readers, "the first invalid sequence is at %d, %v; the library finds %d, %v", place, found, other_place, other_found)
	}
	// Each character, once: its places, then its encoding.
	boundaries := make([]bool, len(input) + 1, context.temp_allocator)
	valid_bytes := make([]bool, len(input), context.temp_allocator)
	count, at := 0, 0
	for at < len(input) {
		character, length, character_valid := text_encoding.character_decode(input, at)
		if length < 1 || length > text_encoding.CHARACTER_BYTES_LIMIT || length > len(input) - at {
			return fuzz_broken(.Contract, "character_decode at %d gives %d bytes of %d", at, length, len(input))
		}
		if !character_valid && character != text_encoding.REPLACEMENT_CHARACTER {
			return fuzz_broken(.Contract, "character_decode refuses the bytes at %d and gives %x", at, character)
		}
		if character_valid {
			buffer: [text_encoding.CHARACTER_BYTES_LIMIT]u8
			written := text_encoding.character_encode(character, buffer[:])
			if written != length || !slice.equal(buffer[:written], input[at:][:length]) {
				return fuzz_broken(.Round_Trip, "the character %x of %d bytes encodes to %d bytes", character, length, written)
			}
			if text_encoding.character_encode(character, buffer[:length - 1]) != 0 {
				return fuzz_broken(.Contract, "character_encode writes %x in a buffer one byte short", character)
			}
			for &item in valid_bytes[at:][:length] {
				item = true
			}
		}
		boundaries[at] = true
		at += length
		count += 1
	}
	boundaries[len(input)] = true
	if text_encoding.character_count(input) != count {
		return fuzz_broken(.Contract, "character_count gives %d of %d characters", text_encoding.character_count(input), count)
	}
	for outside in ([2]int{-1, len(input)}) {
		if _, length, character_valid := text_encoding.character_decode(input, outside); length != 0 || character_valid {
			return fuzz_broken(.Contract, "character_decode at the place %d outside the text gives %d bytes", outside, length)
		}
	}
	cleaned := slice.clone(input, context.temp_allocator)
	text_encoding.invalid_sequences_replace(cleaned)
	if !text_encoding.text_valid(cleaned) {
		return fuzz_broken(.Contract, "a text with its invalid sequences replaced has an invalid sequence")
	}
	for value, index in input {
		if valid_bytes[index] && cleaned[index] != value || !valid_bytes[index] && cleaned[index] != '?' {
			return fuzz_broken(.Contract, "invalid_sequences_replace changed the byte %d of a valid character, or kept a byte of an invalid sequence", index)
		}
	}
	if valid {
		// A cut at each length ends after a whole character, and keeps the
		// whole text up to a place between two characters.
		for length in 0 ..= len(input) {
			kept := text_encoding.complete_characters(input[:length])
			if kept > length || length - kept >= text_encoding.CHARACTER_BYTES_LIMIT || !boundaries[kept] || boundaries[length] != (kept == length) {
				return fuzz_broken(.Contract, "complete_characters of %d bytes keeps %d", length, kept)
			}
		}
	}
	identifier := text_encoding.identifier_valid(input)
	words := text_encoding.identifier_words_valid(input)
	if identifier && (!words || len(input) == 0) || words && !valid {
		return fuzz_broken(.Contract, "an identifier %v, words of identifiers %v, a valid text %v", identifier, words, valid)
	}
	if !slice.equal(before, input) {
		return fuzz_broken(.Contract, "a reader of the text changed its bytes")
	}
	return FUZZ_PASSED
}

fuzz_text_encoding_seeds :: proc(seeds: ^[dynamic][]u8) {
	// Each form of a character at its edges, the forms that the rule
	// refuses, and a text of each.
	texts := [?][]u8 {
		{'a', ' ', '~'},
		{0x7F},
		{0xC2, 0x80},
		{0xC2, 0xA0},
		{0xC0, 0xAF},
		{0xE0, 0x9F, 0xBF},
		{0xE0, 0xA0, 0x80},
		{0xED, 0x9F, 0xBF},
		{0xED, 0xA0, 0x80},
		{0xEF, 0xBF, 0xBD},
		{0xF0, 0x8F, 0xBF, 0xBF},
		{0xF0, 0x90, 0x80, 0x80},
		{0xF4, 0x8F, 0xBF, 0xBF},
		{0xF4, 0x90, 0x80, 0x80},
		{0xF5, 0x80, 0x80, 0x80},
		{0x80},
		{'x', 0xE2, 0x82},
		{'l', 0xC3, 0xA9, 't', 0xC3, 0xA9, ' ', 0xE2, 0x82, 0xAC, ' ', 0xF0, 0x9F, 0x98, 0x80, '\n'},
	}
	for text in texts {
		append(seeds, slice.clone(text))
	}
}

// ---------------------------------------------------------------------
// The value runs.

// The head of an input of the value runs: the length of the text, the
// places of a cut, the bytes of each record, and the detail of an integer
// unit. The runs of the text follow it.
Fuzz_Value_Runs_Head :: struct {
	text_length:   u16, // The bytes of the text of the runs.
	cut:           u16, // The length for value_runs_cut.
	from:          u16, // The first byte for value_runs_after.
	record_length: u8, // The bytes of the text of one record, from 1.
	reserved:      u8,
	detail:        u32, // A detail of an Integer parameter, for integer_unit_of_detail.
}
#assert(size_of(Fuzz_Value_Runs_Head) == 12)

FUZZ_VALUE_RUN_LIMIT :: 256
// The most records of a text that the model of the records walks.
FUZZ_VALUE_RECORD_LIMIT :: 64
FUZZ_VALUE_RUNS_INPUT_LIMIT :: size_of(Fuzz_Value_Runs_Head) + FUZZ_VALUE_RUN_LIMIT * size_of(value_kinds.Value_Run_In_Call)

// fuzz_value_runs_execute: runs that the check refuses stay as they were;
// runs that it accepts each fit the text in order, a writer that adds
// them again gives the same table, their parts in the records of the text
// are the runs cut at the bounds of the records, and a cut or a rest of
// the runs passes the check of its shorter text. Each word of a run, and
// each detail of an integer unit, names a member or is refused.
fuzz_value_runs_execute :: proc(input: []u8) -> Fuzz_Verdict {
	head: Fuzz_Value_Runs_Head
	copy(mem.ptr_to_bytes(&head), input)
	rest := input[min(len(input), size_of(head)):]
	count := min(len(rest) / size_of(value_kinds.Value_Run_In_Call), FUZZ_VALUE_RUN_LIMIT)
	runs := make([]value_kinds.Value_Run_In_Call, count, context.temp_allocator)
	copy(slice.to_bytes(runs), rest)
	before := slice.clone(runs, context.temp_allocator)
	length := int(head.text_length)
	if verdict := fuzz_value_run_words_check(runs, int(head.record_length)); verdict.oracle != .None {
		return verdict
	}
	if verdict := fuzz_integer_unit_check(head.detail); verdict.oracle != .None {
		return verdict
	}
	accepted := value_kinds.value_runs_check(runs, length)
	if !slice.equal(before, runs) {
		return fuzz_broken(.Contract, "value_runs_check changed the runs")
	}
	if !accepted {
		return FUZZ_PASSED
	}
	end := 0
	for run, index in runs {
		kind, kind_ok := value_kinds.value_kind_of(run.kind)
		if run.length == 0 || int(run.start) < end || int(run.start) + int(run.length) > length || !kind_ok || kind == .None || run.reserved != 0 {
			return fuzz_broken(.Contract, "value_runs_check accepts the run %d: %v", index, run)
		}
		end = int(run.start) + int(run.length)
	}
	// The writer adds each run again.
	written := make([]value_kinds.Value_Run_In_Call, count, context.temp_allocator)
	written_count := 0
	for run in runs {
		kind, _ := value_kinds.value_kind_of(run.kind)
		value_kinds.value_run_add(written, &written_count, int(run.start), int(run.start) + int(run.length), kind)
	}
	if written_count != count || !slice.equal(written, runs) {
		return fuzz_broken(.Round_Trip, "value_run_add gives %d runs of %d accepted runs, or other runs", written_count, count)
	}
	// A full table, a part of no kind, of no byte, and past the bytes that
	// a start names add nothing.
	full_count := written_count
	value_kinds.value_run_add(written, &full_count, 0, 1, .Number)
	value_kinds.value_run_add(written[:0], &full_count, 0, 1, .Number)
	empty: [1]value_kinds.Value_Run_In_Call
	empty_count := 0
	value_kinds.value_run_add(empty[:], &empty_count, 0, 1, .None)
	value_kinds.value_run_add(empty[:], &empty_count, 1, 1, .Number)
	value_kinds.value_run_add(empty[:], &empty_count, -1, 1, .Number)
	value_kinds.value_run_add(empty[:], &empty_count, 0, 0xFFFF + 1, .Number)
	if full_count != written_count || empty_count != 0 || empty[0] != (value_kinds.Value_Run_In_Call{}) || !slice.equal(written, runs) {
		return fuzz_broken(.Contract, "value_run_add adds a run that it must refuse")
	}
	// The model walks the first records of the text only: each record
	// reads each run, so a bound on the records keeps one execution short.
	record_length := max(int(head.record_length), 1)
	walked := min(length, FUZZ_VALUE_RECORD_LIMIT * record_length)
	if verdict := fuzz_value_runs_of_records_check(runs, length, record_length, walked); verdict.oracle != .None {
		return verdict
	}
	// The cut and the rest.
	cut := slice.clone(runs, context.temp_allocator)
	cut_count := value_kinds.value_runs_cut(cut, count, int(head.cut))
	if !value_kinds.value_runs_check(cut[:cut_count], int(head.cut)) {
		return fuzz_broken(.Contract, "the runs cut at %d fail the check of a text of %d bytes", head.cut, head.cut)
	}
	after := slice.clone(runs, context.temp_allocator)
	after_count := value_kinds.value_runs_after(after, count, int(head.from))
	if int(head.from) <= length && !value_kinds.value_runs_check(after[:after_count], length - int(head.from)) {
		return fuzz_broken(.Contract, "the runs after %d fail the check of the %d bytes after it", head.from, length - int(head.from))
	}
	return FUZZ_PASSED
}

// fuzz_value_runs_of_records_check: the parts of the runs in each record of
// the first `walked` bytes of the text are the runs cut at the bounds of
// the records, each inside its record with the kind of its run. `walked`
// is the length of the text, or a whole count of records.
@(private = "file")
fuzz_value_runs_of_records_check :: proc(runs: []value_kinds.Value_Run_In_Call, length: int, record_length: int, walked: int) -> Fuzz_Verdict {
	// A record of 255 bytes holds at most 255 parts: the table of the
	// parts never cuts them.
	into: [256]value_kinds.Value_Run
	given := make([dynamic][3]int, context.temp_allocator)
	for record_start := 0; record_start < walked; record_start += record_length {
		bytes := min(record_length, length - record_start)
		parts := value_kinds.value_runs_of_record(runs, record_start, bytes, into[:])
		for part in into[:parts] {
			start, end, kind, ok := value_kinds.value_run_in_text(part, bytes)
			if !ok || u8(kind) != part.kind {
				return fuzz_broken(.Contract, "a part of the record at %d does not fit its %d bytes: %v", record_start, bytes, part)
			}
			append(&given, [3]int{record_start + start, end - start, int(kind)})
		}
	}
	expected := make([dynamic][3]int, context.temp_allocator)
	for run in runs {
		start, end := int(run.start), min(int(run.start) + int(run.length), walked)
		for start < end {
			record_end := (start / record_length + 1) * record_length
			piece_end := min(end, record_end)
			append(&expected, [3]int{start, piece_end - start, int(run.kind)})
			start = piece_end
		}
	}
	if !slice.equal(given[:], expected[:]) {
		return fuzz_broken(.Model, "the records of %d bytes give %d parts of the runs; their cut at the bounds gives %d", record_length, len(given), len(expected))
	}
	return FUZZ_PASSED
}

// fuzz_value_run_words_check reads each run of the input as a run of a
// record: value_run_in_text gives a part inside the text with the member
// that its byte names, or nothing.
@(private = "file")
fuzz_value_run_words_check :: proc(runs: []value_kinds.Value_Run_In_Call, text_count: int) -> Fuzz_Verdict {
	for run in runs {
		part := value_kinds.Value_Run{start = u8(run.start), length = u8(run.length), kind = run.kind}
		start, end, kind, ok := value_kinds.value_run_in_text(part, text_count)
		if !ok {
			if start != 0 || end != 0 || kind != .None {
				return fuzz_broken(.Contract, "value_run_in_text refuses %v and gives %d to %d", part, start, end)
			}
			continue
		}
		if start != int(part.start) || end - start != int(part.length) || end > text_count || part.length == 0 || kind == .None || u8(kind) != part.kind {
			return fuzz_broken(.Contract, "value_run_in_text gives %d to %d, %v for %v in %d bytes", start, end, kind, part, text_count)
		}
	}
	return FUZZ_PASSED
}

// fuzz_integer_unit_check: a detail that names an integer unit is the
// detail that the unit writes; another one gives nothing.
@(private = "file")
fuzz_integer_unit_check :: proc(detail: u32) -> Fuzz_Verdict {
	integer_unit, ok := value_kinds.integer_unit_of_detail(detail)
	if !ok {
		if integer_unit != (value_kinds.Integer_Unit{}) {
			return fuzz_broken(.Contract, "integer_unit_of_detail refuses %x and gives %v", detail, integer_unit)
		}
		return FUZZ_PASSED
	}
	if !value_kinds.integer_unit_valid(integer_unit) || value_kinds.integer_unit_detail(integer_unit) != detail {
		return fuzz_broken(.Round_Trip, "the detail %x reads as %v, which writes %x", detail, integer_unit, value_kinds.integer_unit_detail(integer_unit))
	}
	if (value_kinds.integer_unit_text(integer_unit) == "") != (integer_unit.kind == .None) {
		return fuzz_broken(.Contract, "the unit %v has the text %q", integer_unit, value_kinds.integer_unit_text(integer_unit))
	}
	return FUZZ_PASSED
}

fuzz_value_runs_seeds :: proc(seeds: ^[dynamic][]u8) {
	// Runs that touch, cross the bound of a record and end at the end of
	// the text; then a run of each refusal: no byte, out of order, past
	// the text, a kind of None and one past the last, a reserved byte.
	good := [?]value_kinds.Value_Run_In_Call {
		{start = 0, length = 3, kind = u8(value_kinds.Value_Kind.Number)},
		{start = 3, length = 9, kind = u8(value_kinds.Value_Kind.Size)},
		{start = 20, length = 12, kind = u8(max(value_kinds.Value_Kind))},
	}
	refusals := [?]value_kinds.Value_Run_In_Call {
		{start = 0, length = 0, kind = u8(value_kinds.Value_Kind.Number)},
		{start = 1, length = 1, kind = u8(value_kinds.Value_Kind.Number)},
		{start = 30, length = 3, kind = u8(value_kinds.Value_Kind.Number)},
		{start = 30, length = 1, kind = u8(value_kinds.Value_Kind.None)},
		{start = 30, length = 1, kind = u8(max(value_kinds.Value_Kind)) + 1},
		{start = 30, length = 1, kind = u8(value_kinds.Value_Kind.Time), reserved = 1},
	}
	details := [?]u32{0, value_kinds.integer_unit_detail(value_kinds.size_in(.Pages)), value_kinds.integer_unit_detail(value_kinds.time_in(max(value_kinds.Duration_Unit))) + 1 << 16, 1, max(u32)}
	for detail, index in details {
		head := Fuzz_Value_Runs_Head{text_length = 32, cut = u16(8 * index), from = u16(5 * index), record_length = u8(1 + 7 * index), detail = detail}
		seed := make([dynamic]u8)
		append(&seed, ..mem.ptr_to_bytes(&head))
		append(&seed, ..slice.to_bytes(good[:]))
		append(seeds, seed[:])
	}
	for refusal in refusals {
		head := Fuzz_Value_Runs_Head{text_length = 32, record_length = 16}
		runs := good
		runs[1] = refusal
		seed := make([dynamic]u8)
		append(&seed, ..mem.ptr_to_bytes(&head))
		append(&seed, ..slice.to_bytes(runs[:]))
		append(seeds, seed[:])
	}
}

fuzz_value_runs_regions :: proc(input: []u8, regions: ^[dynamic]Fuzz_Region) {
	if len(input) < size_of(Fuzz_Value_Runs_Head) {
		return
	}
	append(regions, Fuzz_Region{offset = 0, type = Fuzz_Value_Runs_Head, count = 1})
	count := min((len(input) - size_of(Fuzz_Value_Runs_Head)) / size_of(value_kinds.Value_Run_In_Call), FUZZ_VALUE_RUN_LIMIT)
	if count > 0 {
		append(regions, Fuzz_Region{offset = size_of(Fuzz_Value_Runs_Head), type = value_kinds.Value_Run_In_Call, count = count})
	}
}

// ---------------------------------------------------------------------
// The sentences of the error records.

// Which sentence an input writes for its record.
@(private = "file")
Fuzz_Sentence :: enum u8 {
	Error,
	Error_With_Argument_Name,
	Kernel,
	Ring,
	Wrapper,
	Export,
	Export_Detail,
	Details_Rest,
}

// The buffer of a whole sentence: a name that a module file gives can be
// as long as the file.
@(private = "file")
FUZZ_SENTENCE_WHOLE_SIZE :: 2 * FUZZ_SENTENCES_INPUT_LIMIT

FUZZ_SENTENCES_INPUT_LIMIT :: 16 << 10

@(private = "file")
fuzz_sentence_write :: proc(writer: ^sentence.Writer, chosen: Fuzz_Sentence, record: ^errors.Error_Record, file: []u8) {
	switch chosen {
	case .Error:
		sentence.error_text(writer, record, "storage.write", "")
	case .Error_With_Argument_Name:
		sentence.error_text(writer, record, "storage.write", "name")
	case .Kernel:
		sentence.kernel_error_text(writer, record)
	case .Ring:
		sentence.ring_error_text(writer, record, "block", "read", "count")
	case .Wrapper:
		sentence.wrapper_error_text(writer, record, "display.open", []string{"width", "height"})
	case .Export:
		sentence.export_error_text(writer, file, u32(record.operation), "service", record)
	case .Export_Detail:
		sentence.export_error_detail_text(writer, file, u32(record.operation), "", u64(record.value), u64(record.limit), record)
	case .Details_Rest:
		sentence.error_details_rest_text(writer, u64(record.value), u64(record.limit))
	}
}

// fuzz_sentences_execute reads an error record, the sentence to write, the
// size of a small buffer and a module file. The sentence of any record is
// written with no fault and changes no record; written twice it is the
// same; a sentence of the names of the system is a valid text; and the
// sentence in a small buffer is the start of the whole sentence, then the
// cut mark with the count of the bytes that it lacks.
fuzz_sentences_execute :: proc(input: []u8) -> Fuzz_Verdict {
	record: errors.Error_Record
	copy(mem.ptr_to_bytes(&record), input)
	rest := input[min(len(input), size_of(record)):]
	choices := fuzz_choices_of(rest)
	chosen := foundation.enum_member_at(Fuzz_Sentence, fuzz_choice_below(&choices, len(Fuzz_Sentence)))
	small_size := fuzz_choice_below(&choices, 256)
	file := rest[min(len(rest), choices.place):]
	// The readers of a module file need validate first, as each caller
	// does; any other file is no file.
	if module.validate(file) != .None {
		file = nil
	}
	given := record
	whole_buffer := make([]u8, FUZZ_SENTENCE_WHOLE_SIZE, context.temp_allocator)
	whole := sentence.Writer{buffer = whole_buffer}
	fuzz_sentence_write(&whole, chosen, &record, file)
	whole_text := sentence.written(&whole)
	if record != given {
		return fuzz_broken(.Contract, "the sentence %v changed its record", chosen)
	}
	if sentence.written(&whole) != whole_text {
		return fuzz_broken(.Contract, "written gives another text the second time")
	}
	// The names of a module file are bytes of the file; each other name is
	// a name of the system.
	if (chosen != .Export && chosen != .Export_Detail || file == nil) && !text_encoding.text_valid(transmute([]u8)whole_text) {
		return fuzz_broken(.Contract, "the sentence %v is not a valid text: %q", chosen, whole_text)
	}
	again_buffer := make([]u8, FUZZ_SENTENCE_WHOLE_SIZE, context.temp_allocator)
	again := sentence.Writer{buffer = again_buffer}
	fuzz_sentence_write(&again, chosen, &record, file)
	if sentence.written(&again) != whole_text {
		return fuzz_broken(.Contract, "two sentences of one record differ")
	}
	if whole.dropped != 0 {
		return FUZZ_PASSED
	}
	small_buffer: [256]u8
	small := sentence.Writer{buffer = small_buffer[:small_size]}
	fuzz_sentence_write(&small, chosen, &record, file)
	small_text := sentence.written(&small)
	if len(small_text) > small_size {
		return fuzz_broken(.Contract, "a sentence of %d bytes in a buffer of %d", len(small_text), small_size)
	}
	if len(whole_text) <= small_size {
		if small_text != whole_text {
			return fuzz_broken(.Contract, "a sentence that fits its buffer differs from the whole sentence")
		}
		return FUZZ_PASSED
	}
	kept := small.mark_start
	if !small.marked || kept > len(small_text) || small_text[:kept] != whole_text[:kept] || small.mark_missing != u64(len(whole_text) - kept) {
		return fuzz_broken(.Contract, "a cut sentence keeps %d bytes and says %d missing, of a sentence of %d bytes", kept, small.mark_missing, len(whole_text))
	}
	if kept + cut_mark.mark_size(small.mark_missing) <= small_size {
		mark_buffer: [64]u8
		mark := sentence.format(mark_buffer[:], cut_mark.MARK_START, small.mark_missing, cut_mark.MARK_END)
		if small_text[kept:] != mark {
			return fuzz_broken(.Contract, "a cut sentence ends with %q, not with its mark %q", small_text[kept:], mark)
		}
	}
	return FUZZ_PASSED
}

fuzz_sentences_seeds :: proc(seeds: ^[dynamic][]u8) {
	// A record of each kind, of each unit in turn, with values at their
	// edges, then the words past the last kind and unit; each sentence in
	// turn, with a small buffer of each size class.
	records := make([dynamic]errors.Error_Record, context.temp_allocator)
	unit_count := len(errors.Unit)
	index := 0
	for kind in errors.Kind {
		append(&records, errors.Error_Record{kind = i64(kind), unit = i64(index % unit_count), operation = i64(index), argument = i64(index % 3), value = -1, limit = max(i64), found = min(i64)})
		index += 1
	}
	append(&records, errors.Error_Record{kind = i64(max(errors.Kind)) + 1, unit = i64(max(errors.Unit)) + 1, operation = max(i64), argument = -1, value = max(i64), limit = 0, found = 1})
	module_files := make([dynamic][]u8, context.temp_allocator)
	fuzz_module_seeds(&module_files)
	for &record, number in records {
		with_file := number == 0 && len(module_files) > 0
		if with_file {
			// The first export of the file, and the sentence of an export.
			record.operation = 1
		}
		seed := make([dynamic]u8)
		append(&seed, ..mem.ptr_to_bytes(&record))
		append(&seed, with_file ? u8(Fuzz_Sentence.Export) : u8(number % len(Fuzz_Sentence)), u8(number * 37))
		if with_file {
			append(&seed, ..module_files[0])
		}
		append(seeds, seed[:])
	}
}

fuzz_sentences_regions :: proc(input: []u8, regions: ^[dynamic]Fuzz_Region) {
	if len(input) >= size_of(errors.Error_Record) {
		append(regions, Fuzz_Region{offset = 0, type = errors.Error_Record, count = 1})
	}
}
