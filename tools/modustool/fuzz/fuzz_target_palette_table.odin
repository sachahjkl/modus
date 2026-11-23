package fuzz

import "core:mem"
import "core:slice"
import "modus:contract/enum_word"
import "modus:contract/palette_table"
import "modus:contract/text_encoding"
import "modustool:foundation"

// The fuzz target of the palette table (src/md/infrastructure/fuzzing.md,
// "The targets, in order of value"): the compositor maps the table of the
// console, another process, and copies its entries, its result area and
// its candidates; the console reads the arguments that the panel sends on
// a ring. Each reader checks its copy and trusts nothing of the memory.

// The first byte of an input chooses the reader; the bytes after it are
// the part of the table, or the words of a record, that it reads.
@(private = "file")
Fuzz_Palette_Part :: enum u8 {
	Entries, // A header, then entries: snapshot_take.
	Result, // A count of 8 bytes, then the result area: result_copy.
	Candidates, // A count of 8 bytes, then candidates: candidates_copy.
	Argument, // The 7 words of an Argument command: argument_unpack.
}

// The memory of a table, for the process: each execution writes its part
// and clears it after.
@(private = "file")
fuzz_palette_memory: []u8

@(private = "file")
fuzz_palette_snapshot: ^palette_table.Snapshot

@(private = "file")
fuzz_palette_entries: []palette_table.Entry

fuzz_palette_table_start :: proc() -> bool {
	bytes, ok := palette_table.table_bytes_for(palette_table.INITIAL_ENTRY_CAPACITY)
	if !ok {
		return false
	}
	fuzz_palette_memory = make([]u8, int(bytes))
	fuzz_palette_entries = make([]palette_table.Entry, palette_table.INITIAL_ENTRY_CAPACITY)
	fuzz_palette_snapshot = new(palette_table.Snapshot)
	if fuzz_palette_snapshot != nil {
		fuzz_palette_snapshot.entries = fuzz_palette_entries
	}
	return fuzz_palette_memory != nil && fuzz_palette_entries != nil && fuzz_palette_snapshot != nil
}

// fuzz_palette_place writes bytes at a place of the memory of the table,
// and gives the part that it wrote, for its clear after the execution.
@(private = "file")
fuzz_palette_place :: proc(offset: int, bytes: []u8) -> []u8 {
	part := fuzz_palette_memory[offset:][:min(len(bytes), len(fuzz_palette_memory) - offset)]
	copy(part, bytes)
	return part
}

fuzz_palette_table_execute :: proc(input: []u8) -> Fuzz_Verdict {
	if len(input) == 0 {
		return FUZZ_PASSED
	}
	body := input[1:]
	switch foundation.enum_member_at(Fuzz_Palette_Part, int(input[0]) % len(Fuzz_Palette_Part)) {
	case .Entries:
		header := fuzz_palette_place(0, body[:min(len(body), size_of(palette_table.Header))])
		entries := fuzz_palette_place(palette_table.ENTRIES_OFFSET, body[len(header):])
		defer {
			slice.zero(header)
			slice.zero(entries)
		}
		return fuzz_palette_entries_check()
	case .Result:
		length := fuzz_word_read(body, 0, min(len(body), 8), false)
		result := fuzz_palette_place(palette_table.RESULT_OFFSET, body[min(len(body), 8):][:min(max(len(body) - 8, 0), palette_table.RESULT_CAPACITY)])
		defer slice.zero(result)
		return fuzz_palette_result_check(length)
	case .Candidates:
		count := fuzz_word_read(body, 0, min(len(body), 8), false)
		candidates := fuzz_palette_place(palette_table.CANDIDATES_OFFSET, body[min(len(body), 8):][:min(max(len(body) - 8, 0), palette_table.CANDIDATE_CAPACITY * size_of(palette_table.Candidate))])
		defer slice.zero(candidates)
		return fuzz_palette_candidates_check(count)
	case .Argument:
		values: [7]u64
		copy(mem.ptr_to_bytes(&values), body)
		return fuzz_palette_argument_check(values)
	}
	return FUZZ_PASSED
}

// fuzz_palette_entries_check: a refused table gives no entry; a table in a
// change is never stable; an accepted one gives each entry as the memory
// holds it, with an even generation, and each entry passes its check
// again. The reader writes nothing in the memory.
@(private = "file")
fuzz_palette_entries_check :: proc() -> Fuzz_Verdict {
	memory := fuzz_palette_memory
	header: palette_table.Header
	mem.copy(&header, raw_data(memory), size_of(header))
	header_before := header
	snapshot := fuzz_palette_snapshot
	problem, index := palette_table.snapshot_take(memory, palette_table.entries_of_table(memory), snapshot)
	mem.copy(&header, raw_data(memory), size_of(header))
	if header != header_before {
		return fuzz_broken(.Contract, "snapshot_take changed the header of the table")
	}
	if problem > max(palette_table.Problem) {
		return fuzz_broken(.Contract, "snapshot_take gives a problem out of its enumeration: %d", u8(problem))
	}
	if (problem == .Never_Stable) != (header.change_count & 1 != 0) {
		return fuzz_broken(.Contract, "snapshot_take gives %v for the count of changes %d", problem, header.change_count)
	}
	if problem != .None {
		if snapshot.entry_count != 0 || snapshot.generation != 0 || index < 0 || index >= max(int(header.entry_count), 1) {
			return fuzz_broken(.Contract, "snapshot_take refuses with %v at the entry %d and gives %d entries", problem, index, snapshot.entry_count)
		}
		return FUZZ_PASSED
	}
	if header.magic != palette_table.MAGIC || header.version != palette_table.VERSION || snapshot.entry_count != int(header.entry_count) || snapshot.generation != header.change_count {
		return fuzz_broken(.Contract, "snapshot_take accepts a header %v and gives %d entries of the generation %d", header, snapshot.entry_count, snapshot.generation)
	}
	copied := slice.to_bytes(snapshot.entries[:snapshot.entry_count])
	if !slice.equal(copied, memory[palette_table.ENTRIES_OFFSET:][:len(copied)]) {
		return fuzz_broken(.Two_Readers, "the entries of the snapshot are not the entries of the memory")
	}
	for &entry, number in snapshot.entries[:snapshot.entry_count] {
		kind, kind_ok := palette_table.entry_kind_of_word(u64(entry.kind))
		if !kind_ok || palette_table.entry_problem(&entry) != .None {
			return fuzz_broken(.Contract, "the accepted entry %d fails its check", number)
		}
		name := entry.name[:entry.name_length]
		if !text_encoding.identifier_words_valid(name) || string(entry.signature[:entry.name_length]) != string(name) {
			return fuzz_broken(.Contract, "the accepted entry %d has the name %q", number, string(name))
		}
		// A second reader of a setting row, not the border of the
		// contract: an entry that joins a row is a Provider_Setting with
		// no parameter, and each of its buttons has a name.
		if entry.setting_name_length != 0 && (kind != .Provider_Setting || entry.parameter_count != 0 || entry.value_name_length == 0) {
			return fuzz_broken(.Contract, "the accepted entry %d joins a setting row and is a %v with %d parameters", number, kind, entry.parameter_count)
		}
	}
	return FUZZ_PASSED
}

// fuzz_palette_result_check: a result that result_copy accepts is the
// bytes of the area, and runs that the writer writes again to the same
// bytes, without its empty runs, when they fit the panel. What the writer
// writes, the reader accepts.
@(private = "file")
fuzz_palette_result_check :: proc(length: u64) -> Fuzz_Verdict {
	result: [palette_table.RESULT_CAPACITY]u8
	count, ok := palette_table.result_copy(fuzz_palette_memory, length, &result)
	if length > palette_table.RESULT_CAPACITY {
		if ok || count != 0 {
			return fuzz_broken(.Contract, "result_copy takes a length of %d", length)
		}
		return FUZZ_PASSED
	}
	if count != int(length) || !slice.equal(result[:count], fuzz_palette_memory[palette_table.RESULT_OFFSET:][:count]) {
		return fuzz_broken(.Contract, "result_copy gives %d bytes of %d, or other bytes", count, length)
	}
	if ok != palette_table.result_valid(result[:count]) {
		return fuzz_broken(.Two_Readers, "result_copy and result_valid differ")
	}
	if !ok {
		return FUZZ_PASSED
	}
	// The runs, written again.
	expected := make([dynamic]u8, context.temp_allocator)
	written_buffer: [palette_table.RESULT_CAPACITY]u8
	writer := palette_table.Result_Writer{buffer = written_buffer[:], fits = true}
	place := 0
	for place < count {
		part, run_length := result[place], int(result[place + 1])
		text := result[place + 2:][:run_length]
		place += 2 + run_length
		if part == u8(palette_table.Run_Part.End_Line) {
			palette_table.result_line_end(&writer)
			append(&expected, part, 0)
			continue
		}
		run_part, run_part_known := enum_word.member_of_word(palette_table.Run_Part, u64(part))
		if !run_part_known {
			return fuzz_broken(.Contract, "result_copy accepts the run part %d, which names no part", part)
		}
		palette_table.result_run(&writer, run_part, string(text))
		if run_length > 0 {
			append(&expected, part, u8(run_length))
			append(&expected, ..text)
		}
	}
	if !palette_table.result_valid(written_buffer[:writer.count]) {
		return fuzz_broken(.Round_Trip, "result_valid refuses the runs that the writer wrote")
	}
	if writer.fits && !slice.equal(written_buffer[:writer.count], expected[:]) {
		return fuzz_broken(.Round_Trip, "the runs written again are %d bytes, not the %d bytes of the result", writer.count, len(expected))
	}
	return FUZZ_PASSED
}

// fuzz_palette_candidates_check: candidates that candidates_copy accepts
// are the records of the area, each with a name of valid text; a refusal
// gives none.
@(private = "file")
fuzz_palette_candidates_check :: proc(count: u64) -> Fuzz_Verdict {
	candidates: [palette_table.CANDIDATE_CAPACITY]palette_table.Candidate
	copied, ok := palette_table.candidates_copy(fuzz_palette_memory, count, &candidates)
	if !ok {
		if copied != 0 {
			return fuzz_broken(.Contract, "candidates_copy refuses and gives %d candidates", copied)
		}
		return FUZZ_PASSED
	}
	if u64(copied) != count || !slice.equal(slice.to_bytes(candidates[:copied]), fuzz_palette_memory[palette_table.CANDIDATES_OFFSET:][:copied * size_of(palette_table.Candidate)]) {
		return fuzz_broken(.Contract, "candidates_copy gives %d candidates of %d, or other records", copied, count)
	}
	for &candidate, index in candidates[:copied] {
		if candidate.length == 0 || int(candidate.length) > palette_table.CANDIDATE_NAME_CAPACITY || !text_encoding.text_valid(candidate.name[:candidate.length]) {
			return fuzz_broken(.Contract, "candidates_copy accepts the candidate %d of %d bytes", index, candidate.length)
		}
	}
	return FUZZ_PASSED
}

// fuzz_palette_argument_check: an Argument command that argument_unpack
// refuses gives nothing; one that it accepts is an Integer or a Text with
// no quote, and argument_pack of it reads again to the same value. The
// words of the ring and of the answer name members or are refused.
@(private = "file")
fuzz_palette_argument_check :: proc(values: [7]u64) -> Fuzz_Verdict {
	parameter, argument, ok := palette_table.argument_unpack(values)
	if !ok {
		if parameter != 0 || argument != (palette_table.Argument_Value{}) {
			return fuzz_broken(.Contract, "argument_unpack refuses the words and gives the parameter %d, %v", parameter, argument.kind)
		}
	} else {
		if parameter < 0 || parameter >= palette_table.PARAMETER_CAPACITY || argument.kind != .Integer && argument.kind != .Text || argument.length < 0 || argument.length > palette_table.ARGUMENT_TEXT_CAPACITY {
			return fuzz_broken(.Contract, "argument_unpack gives the parameter %d, %v of %d bytes", parameter, argument.kind, argument.length)
		}
		text := argument.text[:argument.length]
		if argument.kind == .Text && (!text_encoding.text_valid(text) || slice.contains(text, '"')) {
			return fuzz_broken(.Contract, "argument_unpack gives a text that is not valid or has a quote")
		}
		packed := palette_table.argument_pack(parameter, argument.kind, argument.integer, string(text))
		again_parameter, again, again_ok := palette_table.argument_unpack(packed)
		if !again_ok || again_parameter != parameter || again.kind != argument.kind || again.integer != argument.integer || again.length != argument.length || string(again.text[:again.length]) != string(text) {
			return fuzz_broken(.Round_Trip, "the argument %v of the parameter %d packs and reads as another one", argument.kind, parameter)
		}
	}
	for word, place in values {
		if kind, known := palette_table.value_kind_of_word(word); known && u64(kind) != word || !known && kind != .None {
			return fuzz_broken(.Contract, "value_kind_of_word gives %v for the word %d at %d", kind, word, place)
		}
		if outcome, known := palette_table.outcome_of_word(word); known && u64(outcome) != word || !known && outcome != .None {
			return fuzz_broken(.Contract, "outcome_of_word gives %v for the word %d", outcome, word)
		}
		if kind, known := palette_table.entry_kind_of_word(word); known && u64(kind) != word {
			return fuzz_broken(.Contract, "entry_kind_of_word gives %v for the word %d", kind, word)
		}
		if command, known := palette_table.command_of_ring_word(u32(word)); known && (command == .None || u32(command) != u32(word)) {
			return fuzz_broken(.Contract, "command_of_ring_word gives %v for the word %d", command, u32(word))
		}
	}
	return FUZZ_PASSED
}

// fuzz_palette_entry_of gives an entry that passes its check, of a kind.
@(private = "file")
fuzz_palette_entry_of :: proc(kind: palette_table.Entry_Kind, name: string, about: string) -> (entry: palette_table.Entry) {
	entry.kind = u8(kind)
	entry.name_length = u8(copy(entry.name[:], name))
	signature := kind == .Export ? "revoke(name: Text, grant: Text) -> Integer" : name
	entry.signature_length = u8(copy(entry.signature[:], signature))
	entry.about_length = u8(copy(entry.about[:], about))
	switch kind {
	case .Command:
	case .Export:
		entry.parameter_count = 2
		entry.parameters[0], entry.parameters[1] = u8(palette_table.Value_Kind.Text), u8(palette_table.Value_Kind.Text)
		entry.result = u8(palette_table.Value_Kind.Integer)
		entry.parameter_name_lengths[0] = u8(copy(entry.parameter_names[0][:], "name"))
	case .Provider_Setting:
		// The member light of the parameter appearance of settings.set, in
		// use.
		entry.flags = {.In_Use}
		entry.setting_name_length = u8(copy(entry.setting_name[:], "appearance"))
		entry.value_name_length = u8(copy(entry.value_name[:], "light"))
		entry.act_name_length = u8(copy(entry.act_name[:], "settings.set:appearance"))
	}
	return entry
}

fuzz_palette_table_seeds :: proc(seeds: ^[dynamic][]u8) {
	// A table of one entry of each kind.
	seed_bytes, _ := palette_table.table_bytes_for(u64(len(palette_table.Entry_Kind)))
	header := palette_table.Header{magic = palette_table.MAGIC, version = palette_table.VERSION, change_count = 4, entry_count = len(palette_table.Entry_Kind), byte_length = seed_bytes}
	table := make([dynamic]u8)
	append(&table, u8(Fuzz_Palette_Part.Entries))
	append(&table, ..mem.ptr_to_bytes(&header))
	for kind in palette_table.Entry_Kind {
		entry := fuzz_palette_entry_of(kind, kind == .Command ? "set font to spleen" : "revoke", "what it does: \xC3\xA9")
		append(&table, ..mem.ptr_to_bytes(&entry))
	}
	append(seeds, table[:])
	// The same table in a change, and with one entry past the buffer capacity.
	over_bytes, _ := palette_table.table_bytes_for(palette_table.INITIAL_ENTRY_CAPACITY + 1)
	for change in ([2]palette_table.Header{{change_count = 5}, {entry_count = palette_table.INITIAL_ENTRY_CAPACITY + 1, byte_length = over_bytes}}) {
		changed := slice.clone(table[:])
		other := header
		other.change_count = change.change_count != 0 ? change.change_count : header.change_count
		other.entry_count = change.entry_count != 0 ? change.entry_count : header.entry_count
		other.byte_length = change.byte_length != 0 ? change.byte_length : header.byte_length
		copy(changed[1:], mem.ptr_to_bytes(&other))
		append(seeds, changed)
	}
	// A result of two lines with each part, then its length one past the
	// area; candidates of each length.
	runs := make([dynamic]u8, context.temp_allocator)
	for part in palette_table.Run_Part {
		if part == .End_Line {
			continue
		}
		append(&runs, u8(part), 3, 'a', 0xC3, 0xA9)
	}
	append(&runs, u8(palette_table.Run_Part.End_Line), 0, u8(palette_table.Run_Part.Plain), 0, u8(palette_table.Run_Part.End_Line), 0)
	for length in ([2]u64{u64(len(runs)), palette_table.RESULT_CAPACITY + 1}) {
		length_value := length
		result := make([dynamic]u8)
		append(&result, u8(Fuzz_Palette_Part.Result))
		append(&result, ..mem.ptr_to_bytes(&length_value))
		append(&result, ..runs[:])
		append(seeds, result[:])
	}
	for count in ([3]u64{2, 0, palette_table.CANDIDATE_CAPACITY + 1}) {
		candidates := make([dynamic]u8)
		append(&candidates, u8(Fuzz_Palette_Part.Candidates))
		count_value := count
		append(&candidates, ..mem.ptr_to_bytes(&count_value))
		for length in ([2]int{1, palette_table.CANDIDATE_NAME_CAPACITY}) {
			candidate := palette_table.Candidate{length = u8(length)}
			for &value in candidate.name[:length] {
				value = 'm'
			}
			append(&candidates, ..mem.ptr_to_bytes(&candidate))
		}
		append(seeds, candidates[:])
	}
	// An Integer and a Text argument, and a Text with a quote.
	for text, index in ([3]string{"", "k\xC3\xA9y", "a\"b"}) {
		values := palette_table.argument_pack(index, index == 0 ? .Integer : .Text, -1, text)
		argument := make([dynamic]u8)
		append(&argument, u8(Fuzz_Palette_Part.Argument))
		append(&argument, ..mem.ptr_to_bytes(&values))
		append(seeds, argument[:])
	}
}

fuzz_palette_table_regions :: proc(input: []u8, regions: ^[dynamic]Fuzz_Region) {
	if len(input) < 1 {
		return
	}
	switch foundation.enum_member_at(Fuzz_Palette_Part, int(input[0]) % len(Fuzz_Palette_Part)) {
	case .Entries:
		if len(input) >= 1 + size_of(palette_table.Header) {
			append(regions, Fuzz_Region{offset = 1, type = palette_table.Header, count = 1})
			count := min((len(input) - 1 - size_of(palette_table.Header)) / size_of(palette_table.Entry), palette_table.INITIAL_ENTRY_CAPACITY)
			if count > 0 {
				append(regions, Fuzz_Region{offset = 1 + size_of(palette_table.Header), type = palette_table.Entry, count = count})
			}
		}
	case .Candidates:
		count := min(max(len(input) - 9, 0) / size_of(palette_table.Candidate), palette_table.CANDIDATE_CAPACITY)
		if count > 0 {
			append(regions, Fuzz_Region{offset = 9, type = palette_table.Candidate, count = count})
		}
	case .Result, .Argument:
	}
}
