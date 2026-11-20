#+build !freestanding
package palette_table

import "core:testing"
import "modus:contract/value_kinds"

@(private = "file")
table_of_test :: proc(count: int) -> []u8 {
	memory := make([]u8, TABLE_BYTES)
	header := (^Header)(raw_data(memory))
	header^ = {magic = MAGIC, version = VERSION, change_count = 2, entry_count = u32(count)}
	for index in 0 ..< count {
		entry := (^Entry)(&memory[ENTRIES_OFFSET + index * size_of(Entry)])
		entry.name_length = u8(copy(entry.name[:], "time"))
		entry.signature_length = u8(copy(entry.signature[:], "time() -> Integer"))
		entry.about_length = u8(copy(entry.about[:], "the time of the system"))
		entry.result = u8(Value_Kind.Integer)
	}
	return memory
}

// A good table gives its entries and its generation; a full table too.
@(test)
a_good_table_is_copied :: proc(t: ^testing.T) {
	snapshot := new(Snapshot)
	defer free(snapshot)
	for count in ([]int{0, 3, ENTRY_CAPACITY}) {
		memory := table_of_test(count)
		defer delete(memory)
		problem, _ := snapshot_take(memory, snapshot)
		testing.expect_value(t, problem, Problem.None)
		testing.expect_value(t, snapshot.entry_count, count)
		testing.expect_value(t, snapshot.generation, 2)
	}
	result, result_ok := result_kind_of(&snapshot.entries[ENTRY_CAPACITY - 1])
	testing.expect(t, result_ok)
	testing.expect_value(t, result, Value_Kind.Integer)
}

// The copy is checked, not the memory: a problem names its entry, and the
// snapshot then has no entry.
@(test)
a_bad_entry_is_named :: proc(t: ^testing.T) {
	snapshot := new(Snapshot)
	defer free(snapshot)
	memory := table_of_test(5)
	defer delete(memory)
	entry := (^Entry)(&memory[ENTRIES_OFFSET + 4 * size_of(Entry)])
	entry.reserved = 1
	// A stable generation that is not 0: a refusal must not give it.
	(^Header)(raw_data(memory)).change_count = 4
	problem, index := snapshot_take(memory, snapshot)
	testing.expect_value(t, problem, Problem.Bad_Kind)
	testing.expect_value(t, index, 4)
	testing.expect_value(t, snapshot.entry_count, 0)
	testing.expect_value(t, snapshot.generation, 0)
	entry.reserved = 0
	entry.signature_length = 2 // Shorter than the name.
	problem, index = snapshot_take(memory, snapshot)
	testing.expect_value(t, problem, Problem.Bad_Signature)
	// A count past the capacity is refused before any entry is read.
	(^Header)(raw_data(memory)).entry_count = ENTRY_CAPACITY + 1
	problem, _ = snapshot_take(memory, snapshot)
	testing.expect_value(t, problem, Problem.Too_Many_Entries)
	// A table that its writer changes with no end is no table.
	(^Header)(raw_data(memory)).change_count = 9
	problem, _ = snapshot_take(memory, snapshot)
	testing.expect_value(t, problem, Problem.Never_Stable)
	problem, _ = snapshot_take(memory[:TABLE_BYTES - 1], snapshot)
	testing.expect_value(t, problem, Problem.Too_Small)
}

// A byte of the kind of the result or of a parameter that names no kind is
// refused by the check of the entry and by each border: one past the last
// kind, and the largest byte. An index of a parameter past the capacity, or
// negative, is refused. Each kind then reads back from its own byte.
@(test)
a_kind_of_a_result_or_a_parameter_that_names_no_kind :: proc(t: ^testing.T) {
	entry: Entry
	entry.kind = u8(Entry_Kind.Command)
	entry.name_length = u8(copy(entry.name[:], "time"))
	entry.signature_length = u8(copy(entry.signature[:], "time"))
	refused_bytes := [?]u8{u8(max(Value_Kind)) + 1, max(u8)}
	for value in refused_bytes {
		entry.result = value
		testing.expect_value(t, entry_problem(&entry), Problem.Bad_Kind)
		_, result_ok := result_kind_of(&entry)
		testing.expectf(t, !result_ok, "the result byte %d names no kind, and it is taken", value)
		entry.result = u8(Value_Kind.None)
		for index in 0 ..< PARAMETER_CAPACITY {
			entry.parameters[index] = value
			testing.expect_value(t, entry_problem(&entry), Problem.Bad_Kind)
			_, parameter_ok := parameter_kind_of(&entry, index)
			testing.expectf(t, !parameter_ok, "the byte %d of the parameter %d names no kind, and it is taken", value, index)
			entry.parameters[index] = u8(Value_Kind.None)
		}
	}
	_, below_ok := parameter_kind_of(&entry, -1)
	_, past_ok := parameter_kind_of(&entry, PARAMETER_CAPACITY)
	testing.expect(t, !below_ok && !past_ok)
	testing.expect_value(t, entry_problem(&entry), Problem.None)
	for member in Value_Kind {
		entry.result = u8(member)
		entry.parameters[PARAMETER_CAPACITY - 1] = u8(member)
		result, result_ok := result_kind_of(&entry)
		parameter, parameter_ok := parameter_kind_of(&entry, PARAMETER_CAPACITY - 1)
		testing.expect(t, result_ok && parameter_ok)
		testing.expect_value(t, result, member)
		testing.expect_value(t, parameter, member)
	}
}

// The runs of a result: what a writer writes is valid; a line or a run
// that does not fit the panel says so and writes no part of it.
@(test)
the_runs_of_a_result :: proc(t: ^testing.T) {
	area: [RESULT_CAPACITY]u8
	writer := Result_Writer{buffer = area[:], fits = true}
	result_run(&writer, .Label, "pages  ")
	result_run(&writer, .Number, "4096")
	result_line_end(&writer)
	result_run(&writer, .Plain, "a \x07 byte")
	result_line_end(&writer)
	testing.expect(t, writer.fits)
	testing.expect_value(t, writer.lines, 2)
	testing.expect(t, result_valid(area[:writer.count]))
	testing.expect_value(t, area[0], u8(Run_Part.Label))
	testing.expect_value(t, string(area[2:9]), "pages  ")
	// A size and a time of a field are runs of their own kind; a byte past
	// the last kind, but the end of a line, is refused.
	kinds := Result_Writer{buffer = area[:], fits = true}
	result_run(&kinds, .Size, "120 pages")
	result_run(&kinds, .Time, "45 ms")
	result_run(&kinds, .Module, "storage")
	result_run(&kinds, .Version, "1a2b")
	result_line_end(&kinds)
	testing.expect(t, result_valid(area[:kinds.count]))
	area[0] = u8(RUN_PART_LAST) + 1
	testing.expect(t, !result_valid(area[:kinds.count]))
	area[0] = max(u8) - 1
	testing.expect(t, !result_valid(area[:kinds.count]))
	// A line wider than the panel.
	wide := Result_Writer{buffer = area[:], fits = true}
	for _ in 0 ..< RESULT_COLUMN_CAPACITY / 10 + 1 {
		result_run(&wide, .Plain, "0123456789")
	}
	testing.expect(t, !wide.fits)
	// More lines than the panel shows.
	tall := Result_Writer{buffer = area[:], fits = true}
	for _ in 0 ..< RESULT_LINE_CAPACITY {
		result_run(&tall, .Plain, "x")
		result_line_end(&tall)
	}
	testing.expect(t, tall.fits)
	result_run(&tall, .Plain, "x")
	testing.expect(t, !tall.fits)
	// The copy of an area: a length past the area is refused.
	memory := make([]u8, TABLE_BYTES)
	defer delete(memory)
	copied: [RESULT_CAPACITY]u8
	memory[RESULT_OFFSET] = u8(Run_Part.Number)
	memory[RESULT_OFFSET + 1] = 1
	memory[RESULT_OFFSET + 2] = '7'
	count, ok := result_copy(memory, 3, &copied)
	testing.expect(t, ok && count == 3)
	_, ok = result_copy(memory, RESULT_CAPACITY + 1, &copied)
	testing.expect(t, !ok)
	_, ok = result_copy(memory, 2, &copied) // The run ends past the length.
	testing.expect(t, !ok)
	testing.expect_value(t, name_hash("memory") == name_hash("memorx"), false)
}

// A Provider_Setting entry has no parameter, and only such an entry says
// that the machine uses its value.
@(test)
a_provider_setting_entry_is_checked :: proc(t: ^testing.T) {
	entry: Entry
	entry.kind = u8(Entry_Kind.Provider_Setting)
	entry.name_length = u8(copy(entry.name[:], "set strategy to eevdf"))
	entry.signature_length = u8(copy(entry.signature[:], "set strategy to eevdf"))
	testing.expect_value(t, entry_problem(&entry), Problem.None)
	entry.flags = {.In_Use}
	testing.expect_value(t, entry_problem(&entry), Problem.None)
	entry.parameter_count = 1
	testing.expect_value(t, entry_problem(&entry), Problem.Bad_Setting)
	entry.parameter_count = 0
	// The bytes where a Setting entry named a setting and its value are
	// reserved now: each byte that is not 0 is refused.
	entry.reserved_first = 1
	testing.expect_value(t, entry_problem(&entry), Problem.Bad_Kind)
	entry.reserved_first = 0
	for place in 0 ..< 2 {
		entry.reserved[place] = max(u8)
		testing.expect_value(t, entry_problem(&entry), Problem.Bad_Kind)
		entry.reserved[place] = 0
	}
	entry.kind = u8(Entry_Kind.Command)
	testing.expect_value(t, entry_problem(&entry), Problem.Bad_Setting)
	entry.kind = u8(Entry_Kind.Export)
	testing.expect_value(t, entry_problem(&entry), Problem.Bad_Setting)
	entry.flags = {}
	testing.expect_value(t, entry_problem(&entry), Problem.None)
	// A flag that the contract does not know is refused as a kind.
	entry.flags = transmute(Entry_Flags)u8(1 << 2)
	testing.expect_value(t, entry_problem(&entry), Problem.Bad_Kind)
	entry.flags = {}
	entry.kind = u8(max(Entry_Kind)) + 1
	testing.expect_value(t, entry_problem(&entry), Problem.Bad_Kind)
	entry.kind = max(u8)
	testing.expect_value(t, entry_problem(&entry), Problem.Bad_Kind)
}

// The compositor writes the kind of each record of the ring of the provider:
// None, one past the last command and the largest word are refused, and
// give None. Then each command but None comes back from its word.
@(test)
command_of_ring_word_refuses_a_word_that_names_no_command :: proc(t: ^testing.T) {
	refused := [?]u32{u32(Command.None), u32(max(Command)) + 1, max(u32)}
	for word in refused {
		read, ok := command_of_ring_word(word)
		testing.expectf(t, !ok, "the word %d names no command, and it is taken", word)
		testing.expect_value(t, read, Command.None)
	}
	for member in Command {
		if member != .None {
			read, ok := command_of_ring_word(u32(member))
			testing.expect(t, ok)
			testing.expect_value(t, read, member)
		}
	}
}

// The kind of an entry is a word that the provider wrote: one past the last
// kind, a word past the width of the byte and the largest word name no
// kind. Each kind then comes back from its own word. 0 is the kind Command.
@(test)
entry_kind_of_word_refuses_a_word_that_names_no_kind :: proc(t: ^testing.T) {
	refused := [?]u64{u64(max(Entry_Kind)) + 1, 256, max(u64)}
	for word in refused {
		_, ok := entry_kind_of_word(word)
		testing.expectf(t, !ok, "the word %d names no kind of an entry, and it is taken", word)
	}
	for member in Entry_Kind {
		read, ok := entry_kind_of_word(u64(member))
		testing.expect(t, ok)
		testing.expect_value(t, read, member)
	}
}

// The name of a parameter: its length and its bytes.
@(test)
a_parameter_name_is_checked :: proc(t: ^testing.T) {
	entry: Entry
	entry.kind = u8(Entry_Kind.Command)
	entry.name_length = u8(copy(entry.name[:], "settings.set"))
	entry.signature_length = u8(copy(entry.signature[:], "settings.set"))
	testing.expect_value(t, entry_problem(&entry), Problem.None)
	entry.parameter_name_lengths[2] = PARAMETER_NAME_CAPACITY + 1
	testing.expect_value(t, entry_problem(&entry), Problem.Bad_Length)
	entry.parameter_name_lengths[2] = 2
	entry.parameter_names[2][1] = 3
	testing.expect_value(t, entry_problem(&entry), Problem.Bad_Byte)
}

// The candidates of a parameter, and the typed values of a choice: each
// one is checked after its copy.
@(test)
candidates_and_arguments_are_checked :: proc(t: ^testing.T) {
	memory := make([]u8, TABLE_BYTES)
	defer delete(memory)
	copied := new([CANDIDATE_CAPACITY]Candidate)
	defer free(copied)
	for index in 0 ..< 3 {
		candidate := (^Candidate)(&memory[CANDIDATES_OFFSET + index * size_of(Candidate)])
		candidate.length = u8(copy(candidate.name[:], "plasma"))
	}
	count, ok := candidates_copy(memory, 3, copied)
	testing.expect(t, ok && count == 3)
	testing.expect_value(t, string(copied[2].name[:copied[2].length]), "plasma")
	_, ok = candidates_copy(memory, CANDIDATE_CAPACITY + 1, copied)
	testing.expect(t, !ok)
	_, ok = candidates_copy(memory, 4, copied) // The fourth one has no name.
	testing.expect(t, !ok)
	(^Candidate)(&memory[CANDIDATES_OFFSET]).length = 200
	_, ok = candidates_copy(memory, 1, copied)
	testing.expect(t, !ok)
	(^Candidate)(&memory[CANDIDATES_OFFSET]).length = 2
	memory[CANDIDATES_OFFSET + 2] = 10
	_, ok = candidates_copy(memory, 1, copied)
	testing.expect(t, !ok)
	// An Integer and a Text go and come back whole.
	parameter, argument, good := argument_unpack(argument_pack(4, .Integer, -42, ""))
	testing.expect(t, good && parameter == 4 && argument.kind == .Integer && argument.integer == -42)
	parameter, argument, good = argument_unpack(argument_pack(1, .Text, 0, "acts_for_principal"))
	testing.expect(t, good && parameter == 1 && string(argument.text[:argument.length]) == "acts_for_principal")
	// What a console refuses: a quote, a byte that the font does not draw,
	// a kind with no typed value, a parameter past the last, a length past
	// the values.
	_, _, good = argument_unpack(argument_pack(0, .Text, 0, "a\"b"))
	testing.expect(t, !good)
	_, _, good = argument_unpack(argument_pack(0, .Text, 0, "a\tb"))
	testing.expect(t, !good)
	_, _, good = argument_unpack(argument_pack(0, .Table, 0, ""))
	testing.expect(t, !good)
	// A member goes as the Text of its name, never as a kind Enum.
	_, _, good = argument_unpack(argument_pack(0, .Enum, 0, "french"))
	testing.expect(t, !good)
	_, _, good = argument_unpack(argument_pack(PARAMETER_CAPACITY, .Integer, 1, ""))
	testing.expect(t, !good)
	_, _, good = argument_unpack({0 = u64(Value_Kind.Text) << 8 | 200 << 16})
	testing.expect(t, !good)
	_, _, good = argument_unpack({0 = u64(Value_Kind.Text) << 8 | 1 << 24})
	testing.expect(t, !good)
	// A kind byte that names no kind: one past the last kind, the largest byte.
	_, _, good = argument_unpack({0 = (u64(max(Value_Kind)) + 1) << 8})
	testing.expect(t, !good)
	_, _, good = argument_unpack({0 = 0xFF << 8})
	testing.expect(t, !good)
	// An Integer with a length of text is refused, and the refusal gives
	// no parameter and no value: one byte, and the largest length.
	for length in ([2]u64{1, 0xFF}) {
		parameter, argument, good = argument_unpack({0 = 3 | u64(Value_Kind.Integer) << 8 | length << 16, 1 = 42})
		testing.expect(t, !good && parameter == 0 && argument == (Argument_Value{}))
	}
}

// A word of the provider that names no kind or no outcome is refused:
// one past the last member and the largest word. Then each member comes
// back from its own word.
@(test)
a_word_that_names_no_kind_or_outcome_is_refused :: proc(t: ^testing.T) {
	refused_kinds := [?]u64{u64(max(Value_Kind)) + 1, 1 << 32, max(u64)}
	for word in refused_kinds {
		_, ok := value_kind_of_word(word)
		testing.expectf(t, !ok, "the word %d names no kind, and it is taken", word)
	}
	refused_outcomes := [?]u64{u64(max(Outcome)) + 1, 1 << 32, max(u64)}
	for word in refused_outcomes {
		_, ok := outcome_of_word(word)
		testing.expectf(t, !ok, "the word %d names no outcome, and it is taken", word)
	}
	for member in Value_Kind {
		read, ok := value_kind_of_word(u64(member))
		testing.expect(t, ok)
		testing.expect_value(t, read, member)
	}
	for member in Outcome {
		read, ok := outcome_of_word(u64(member))
		testing.expect(t, ok)
		testing.expect_value(t, read, member)
	}
}

// The act name, the name of a setting and the name of a value: each is
// checked as the other texts, and a setting row is made of setting entries
// whose buttons each have a name.
@(test)
an_act_name_and_a_setting_row_are_checked :: proc(t: ^testing.T) {
	entry: Entry
	entry.kind = u8(Entry_Kind.Provider_Setting)
	entry.name_length = u8(copy(entry.name[:], "settings.set font to spleen"))
	entry.signature_length = u8(copy(entry.signature[:], "settings.set font to spleen"))
	entry.act_name_length = u8(copy(entry.act_name[:], "settings.set:font"))
	entry.setting_name_length = u8(copy(entry.setting_name[:], "font"))
	entry.value_name_length = u8(copy(entry.value_name[:], "spleen"))
	testing.expect_value(t, entry_problem(&entry), Problem.None)
	entry.value_name_length = 0 // A button with no name.
	testing.expect_value(t, entry_problem(&entry), Problem.Bad_Setting)
	entry.value_name_length = VALUE_NAME_CAPACITY + 1
	testing.expect_value(t, entry_problem(&entry), Problem.Bad_Length)
	entry.value_name_length = 6
	entry.act_name[3] = 7
	testing.expect_value(t, entry_problem(&entry), Problem.Bad_Byte)
	entry.act_name[3] = 't'
	entry.act_name_length = ACT_NAME_CAPACITY + 1
	testing.expect_value(t, entry_problem(&entry), Problem.Bad_Length)
	entry.act_name_length = 17
	entry.reserved_end = 1
	testing.expect_value(t, entry_problem(&entry), Problem.Bad_Kind)
	entry.reserved_end = 0
	// A command can have an act name, and joins no setting row.
	entry.kind = u8(Entry_Kind.Command)
	testing.expect_value(t, entry_problem(&entry), Problem.Bad_Setting)
	entry.setting_name_length, entry.value_name_length = 0, 0
	testing.expect_value(t, entry_problem(&entry), Problem.None)
	entry.value_name_length = 6 // A value with no setting.
	testing.expect_value(t, entry_problem(&entry), Problem.Bad_Setting)
}

// An integer unit is one of the contract, and only on an Integer parameter
// that the entry has: the panel shows it after the number of the field.
@(test)
an_integer_unit_is_checked :: proc(t: ^testing.T) {
	entry: Entry
	entry.kind = u8(Entry_Kind.Command)
	entry.name_length = u8(copy(entry.name[:], "bytes"))
	entry.signature_length = u8(copy(entry.signature[:], "bytes(Handle, Integer, Integer) -> Bytes"))
	entry.parameter_count = 3
	entry.parameters[0], entry.parameters[1], entry.parameters[2] = u8(Value_Kind.Handle), u8(Value_Kind.Integer), u8(Value_Kind.Integer)
	entry.parameter_units[2] = value_kinds.size_in(.Bytes)
	testing.expect_value(t, entry_problem(&entry), Problem.None)
	entry.parameter_units[2] = value_kinds.time_in(.Seconds)
	testing.expect_value(t, entry_problem(&entry), Problem.None)
	entry.parameter_units[2] = {kind = .Size, unit = u8(max(value_kinds.Size_Unit)) + 1} // Past the units of a size.
	testing.expect_value(t, entry_problem(&entry), Problem.Bad_Kind)
	entry.parameter_units[2] = {kind = .Module, unit = 0} // A kind that counts nothing.
	testing.expect_value(t, entry_problem(&entry), Problem.Bad_Kind)
	entry.parameter_units[2] = {kind = .None, unit = 1} // A unit of no kind.
	testing.expect_value(t, entry_problem(&entry), Problem.Bad_Kind)
	entry.parameter_units[2] = {}
	entry.parameter_units[0] = value_kinds.size_in(.Pages) // A Handle has no number.
	testing.expect_value(t, entry_problem(&entry), Problem.Bad_Kind)
	entry.parameter_units[0] = {}
	entry.parameter_units[3] = value_kinds.size_in(.Pages) // A parameter that the entry does not have.
	testing.expect_value(t, entry_problem(&entry), Problem.Bad_Kind)
	testing.expect_value(t, value_kinds.integer_unit_text(value_kinds.size_in(.Pages)), " pages")
	testing.expect_value(t, value_kinds.integer_unit_text(value_kinds.time_in(.Milliseconds)), " ms")
	testing.expect_value(t, value_kinds.integer_unit_text({}), "")
}

// Each text of an entry for a reader is UTF-8: a help sentence, a
// signature and a parameter name with "é" pass, and with a broken
// sequence, an overlong form or a control character are refused. A name,
// an act name, a setting name and a value name are identifiers: ASCII, so
// "café" is refused there. A result run and a Text argument are UTF-8.
@(test)
the_texts_of_an_entry_are_utf_8 :: proc(t: ^testing.T) {
	entry: Entry
	entry.kind = u8(Entry_Kind.Command)
	entry.name_length = u8(copy(entry.name[:], "time"))
	entry.signature_length = u8(copy(entry.signature[:], "time(durée: Integer) -> Integer"))
	entry.about_length = u8(copy(entry.about[:], "the été of the year"))
	entry.parameter_name_lengths[0] = u8(copy(entry.parameter_names[0][:], "durée"))
	testing.expect_value(t, entry_problem(&entry), Problem.None)
	// The identifiers: "café" is refused in each of them.
	named := entry
	named.name_length = u8(copy(named.name[:], "café"))
	named.signature_length = u8(copy(named.signature[:], "café()"))
	testing.expect_value(t, entry_problem(&named), Problem.Bad_Byte)
	act := entry
	act.act_name_length = u8(copy(act.act_name[:], "café"))
	testing.expect_value(t, entry_problem(&act), Problem.Bad_Byte)
	act.act_name_length = u8(copy(act.act_name[:], "settings.set:font"))
	testing.expect_value(t, entry_problem(&act), Problem.None)
	act.act_name_length = u8(copy(act.act_name[:], "a b")) // An identifier has no space.
	testing.expect_value(t, entry_problem(&act), Problem.Bad_Byte)
	row := entry
	row.kind = u8(Entry_Kind.Provider_Setting)
	row.setting_name_length = u8(copy(row.setting_name[:], "subpixel order"))
	row.value_name_length = u8(copy(row.value_name[:], "rgb"))
	testing.expect_value(t, entry_problem(&row), Problem.None)
	row.value_name_length = u8(copy(row.value_name[:], "café"))
	testing.expect_value(t, entry_problem(&row), Problem.Bad_Byte)
	row.value_name_length = u8(copy(row.value_name[:], "rgb"))
	row.setting_name_length = u8(copy(row.setting_name[:], "café"))
	testing.expect_value(t, entry_problem(&row), Problem.Bad_Byte)
	broken := [?]string{"caf\xc3", "caf\xc3(", "\xc0\xaf", "\xed\xa0\x80", "a\xc2\x85", "a\x1b[2J"}
	for name in broken {
		bad := entry
		bad.name_length = u8(copy(bad.name[:], name))
		bad.signature_length = u8(copy(bad.signature[:], name))
		testing.expectf(t, entry_problem(&bad) == .Bad_Byte, "the name %q must be refused", name)
		about := entry
		about.about_length = u8(copy(about.about[:], name))
		testing.expectf(t, entry_problem(&about) == .Bad_Byte, "the help sentence %q must be refused", name)
		parameter := entry
		parameter.parameter_name_lengths[0] = u8(copy(parameter.parameter_names[0][:], name))
		testing.expectf(t, entry_problem(&parameter) == .Bad_Byte, "the parameter name %q must be refused", name)
	}
	// A run of a result: the writer replaces an invalid sequence, the check refuses one.
	area: [RESULT_CAPACITY]u8
	writer := Result_Writer{buffer = area[:], fits = true}
	result_run(&writer, .Plain, "café \xc3")
	result_line_end(&writer)
	testing.expect(t, writer.fits && result_valid(area[:writer.count]))
	testing.expect_value(t, string(area[2:][:int(area[1])]), "café ?")
	testing.expect_value(t, writer.column, 0)
	area[2 + 3] = 0xC0 // The first byte of "é" becomes the start of an overlong form.
	testing.expect(t, !result_valid(area[:writer.count]))
	// A column of the panel is one character: 76 times "é" fit, 77 do not.
	wide := Result_Writer{buffer = area[:], fits = true}
	for _ in 0 ..< RESULT_COLUMN_CAPACITY {
		result_run(&wide, .Plain, "é")
	}
	testing.expect(t, wide.fits)
	result_run(&wide, .Plain, "é")
	testing.expect(t, !wide.fits)
	// A Text argument: "é" passes, a broken sequence does not.
	_, argument, ok := argument_unpack(argument_pack(0, .Text, 0, "été"))
	testing.expect(t, ok && string(argument.text[:argument.length]) == "été")
	_, _, ok = argument_unpack(argument_pack(0, .Text, 0, "\xe9t\xe9"))
	testing.expect(t, !ok)
	// A text cut by the pack ends after a whole character: 47 bytes, not 48.
	long: [ARGUMENT_TEXT_CAPACITY + 1]u8
	long[0] = 'a'
	for index := 1; index + 1 < len(long); index += 2 {
		long[index], long[index + 1] = 0xC3, 0xA9
	}
	_, argument, ok = argument_unpack(argument_pack(0, .Text, 0, string(long[:])))
	testing.expect(t, ok && argument.length == ARGUMENT_TEXT_CAPACITY - 1)
}
