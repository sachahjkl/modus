package console

import "modus:contract/enum_word"
import op "modus:contract/operation"
import "modus:contract/palette_table"
import "modus:contract/ring"
import "modus:contract/settings"
import "modus:contract/text_encoding"
import "modus:private/console/console_results"
import "modus:support/line_editor"
import "modus:support/system"
import "base:intrinsics"

// The palette provider (docs/CONSOLE.md, "8. The palette provider"): the
// console gives the palette of the desktop one entry for each of its
// commands, and runs the entry that the input chose there.
//
// The console writes the entry table (modus:contract/palette_table), a memory
// object that the compositor maps read-only, after each line: a line can
// load a module or connect to a service, and the command table then has
// new commands. The compositor names a chosen entry on a ring, by the
// generation of the table that it showed, the index of the entry and the
// hash of its name. The console checks the three, builds the line from its
// own command table, and runs it as a line that the input typed: the line
// is echoed, it goes in the line history, the log records show under it,
// and the drawers draw its result. The console then answers with a short
// result, as runs of text with what each run is, or says that its window
// has the result.
//
// Nothing of the compositor is trusted: an index past the table, a hash
// that names another entry and an entry with parameters are refused.

// The built-in commands that destroy something: the palette asks for a
// second Enter before it sends one of them.
@(rodata)
palette_destroying_commands := [?]string{"shutdown", "stop", "revoke", "lock", "history_clear", "unload", "replace"}

#assert(u8(console_results.Part.Operation) == u8(palette_table.Run_Part.Operation))
#assert(u8(console_results.Part.Size) == u8(palette_table.Run_Part.Size) && u8(console_results.Part.Time) == u8(palette_table.Run_Part.Time) && max(console_results.Part) == console_results.Part.Time)
#assert(u8(console_results.Part.Plain) == u8(palette_table.Run_Part.Plain) && u8(console_results.Part.Failure) == u8(palette_table.Run_Part.Failure) && u8(console_results.Part.Number) == u8(palette_table.Run_Part.Number))

palette_ring: ring.Ring // The ring from the compositor: its choices, and the answers of the console.
palette_table_handle, palette_ring_handle: system.Handle
palette_memory: []u8 // The mapping of the entry table.
// 1: the console is the palette provider. The two threads read it; it goes
// to 0 once, before the grant ends.
palette_provided: u32
// The thread that runs the lines asks the first thread to stop its use of
// the ring before a revocation of the grant: 1 is the request, and the
// first thread answers with 1 in palette_stopped.
palette_stop_request, palette_stopped: u32
// The entries as the console wrote them last, and their count: a choice is
// checked against this copy, never against the shared memory. The lock is
// held for one copy in memory.
palette_entries: [palette_table.ENTRY_CAPACITY]palette_table.Entry
palette_entry_count: int
palette_table_lock: system.Lock
palette_send_lock: system.Lock // The ring has two writers: the two threads.
palette_tag: u32 // Not 0: the line that runs is a choice of the palette with this tag.
line_value: Value // The value of the line that ran last, for the answer to the palette.

// palette_provider_start asks the root service for the entry table and the
// ring, and writes the first table. The first thread calls it once, before
// a line runs. Without the grant the console has no provider part, and the
// palette lists the modules and the windows only.
palette_provider_start :: proc "contextless" () {
	// The root service answers when it reaches its loop, after its boot
	// passes: the bound only ends a hang.
	completion, answered := request_record(.Palette_Provide, "console", 0, 60_000)
	if !answered || system.Status(completion.kind) != .Ok {
		system.log(.Info, "console: the console is not the palette provider: the root service refused")
		return
	}
	palette_table_handle, palette_ring_handle = system.Handle(completion.values[0]), system.Handle(completion.values[1])
	table_kind, _, _ := system.handle_state(palette_table_handle)
	table_pages, table_status := system.memory_size(palette_table_handle)
	if table_kind != .Memory || table_status != .Ok || table_pages < palette_table.TABLE_PAGES {
		system.log(.Info, "console: the console is not the palette provider: no entry table")
		return
	}
	address, status := system.memory_map(palette_table_handle)
	if status != .Ok {
		system.log(.Info, "console: the console is not the palette provider: the entry table cannot be mapped")
		return
	}
	opened, ring_status := system.ring_open(palette_ring_handle)
	if ring_status != .Ok {
		system.memory_unmap(address)
		system.log(.Info, "console: the console is not the palette provider: no ring")
		return
	}
	palette_commands_add()
	palette_ring = opened
	palette_memory = ([^]u8)(address)[:palette_table.TABLE_BYTES]
	header := (^palette_table.Header)(address)
	header.magic = palette_table.MAGIC
	header.version = palette_table.VERSION
	intrinsics.atomic_store(&palette_provided, 1)
	palette_table_write()
}

// palette_active says if the console is the palette provider now.
palette_active :: proc "contextless" () -> bool {
	return intrinsics.atomic_load_explicit(&palette_provided, .Relaxed) != 0
}

// palette_entry_make makes the entry of one command. ok is false for a
// command that the palette does not list: a command that makes a record
// from its fields, a command with more parameters than the form of the
// panel has fields (the console line calls it), a name that does not fit or
// that is no identifier, and a command that a later command with the same
// name hides.
palette_entry_make :: proc "contextless" (number: int) -> (entry: palette_table.Entry, ok: bool) {
	item := &commands[number]
	if item.record != 0 || item.parameter_count > palette_table.PARAMETER_CAPACITY || len(item.name) == 0 || len(item.name) > palette_table.NAME_CAPACITY || !text_encoding.identifier_valid(transmute([]u8)item.name) {
		return {}, false
	}
	for &later in commands[number + 1:command_count] {
		if later.name == item.name {
			return {}, false
		}
	}
	entry.kind = u8(palette_table.Entry_Kind.Export)
	if item.run != nil {
		entry.kind = u8(palette_table.Entry_Kind.Command)
		for name in palette_destroying_commands {
			if name == item.name {
				entry.flags += {.Destroys}
			}
		}
	}
	entry.parameter_count = u8(item.parameter_count)
	for kind, index in item.parameters[:entry.parameter_count] {
		entry.parameters[index] = u8(kind)
		// What the number counts, where the command or the description of
		// the export states it: the panel shows the unit after the number
		// of the field.
		if kind == .Integer {
			entry.parameter_units[index] = item.parameter_units[index]
		}
	}
	// The name of each parameter, whole or absent: the form of the palette
	// names its fields with them.
	for name, index in item.parameter_names[:entry.parameter_count] {
		if len(name) <= palette_table.PARAMETER_NAME_CAPACITY && text_encoding.text_valid(transmute([]u8)name) {
			entry.parameter_name_lengths[index] = u8(copy(entry.parameter_names[index][:], name))
		}
	}
	entry.result = u8(item.result)
	entry.name_length = u8(copy(entry.name[:], item.name))
	// The signature, whole; one that does not fit shows no parameter.
	buffer: [512]u8
	writer := system.Writer {
		buffer = buffer[:],
	}
	_, _ = signature_write(&writer, item, -1, true)
	signature := string(buffer[:writer.count])
	if writer.dropped != 0 || len(signature) > palette_table.SIGNATURE_CAPACITY || !text_encoding.text_valid(transmute([]u8)signature) {
		short := system.Writer {
			buffer = buffer[:],
		}
		system.write_part(&short, item.name)
		system.write_part(&short, item.parameter_count > 0 ? "(...)" : "()")
		signature = string(buffer[:short.count])
	}
	entry.signature_length = u8(copy(entry.signature[:], signature))
	// The help sentence: its start, when it is longer than its field, cut
	// after a whole character; an invalid sequence of it becomes "?", so that the table
	// passes its check.
	about := transmute([]u8)item.about
	about_length := min(len(about), palette_table.ABOUT_CAPACITY)
	if about_length < len(about) {
		about_length = text_encoding.complete_characters(about[:about_length])
	}
	entry.about_length = u8(copy(entry.about[:], about[:about_length]))
	text_encoding.invalid_sequences_replace(entry.about[:entry.about_length])
	return entry, true
}

// An entry never holds more parameters than a call of the console takes.
#assert(palette_table.PARAMETER_CAPACITY <= ARGUMENT_CAPACITY)
#assert(u8(Kind.Bytes) == u8(palette_table.Value_Kind.Bytes))

// The entries that the next table holds: made here, then compared with
// the entries of the table before, so that a line that changes no command
// changes no table. Only the thread that writes the table uses it.
palette_next_entries: [palette_table.ENTRY_CAPACITY]palette_table.Entry

PALETTE_STRATEGY_VALUE_CAPACITY :: 16 // The bytes of the name of a strategy as a value of the command `strategy`.
// The act name of the entries of the strategies, and the name of their
// row: the name of the command that they run. The process `scheduler`
// names the tile of the strategy in use with it.
PALETTE_STRATEGY_ACT_NAME :: "strategy"

// palette_strategy_value gives the name of a scheduling strategy as the
// command `strategy` takes it: the name of the kernel contract in lower
// case, with "_" for a space: "round_robin", "fair", "eevdf". The process
// `scheduler` reads the same names (its export `strategy_set`). A name
// that does not fit gives "".
palette_strategy_value :: proc "contextless" (buffer: ^[PALETTE_STRATEGY_VALUE_CAPACITY]u8, strategy: op.Strategy) -> string {
	name := op.STRATEGY_NAMES[strategy]
	if len(name) > len(buffer) {
		return ""
	}
	for index in 0 ..< len(name) {
		character := name[index]
		switch {
		case character >= 'A' && character <= 'Z':
			character += 'a' - 'A'
		case character == ' ':
			character = '_'
		}
		buffer[index] = character
	}
	return string(buffer[:len(name)])
}

// palette_strategy_in_use gives the scheduling strategy that the machine
// uses now, from the system report, or None when the report is refused:
// no entry then has the mark.
palette_strategy_in_use :: proc "contextless" () -> op.Strategy {
	report: op.System_Report
	if _, status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.System), 0, u64(uintptr(&report)), size_of(report)); status != .Ok {
		return .None
	}
	return report.strategy
}

// palette_table_write writes the entry table from the command table of
// now and the scheduling strategy of now, when it differs from the table
// before. The writer adds 1 to the change count before the change and 1
// after it, and wakes the reader. One thread writes at a time: the first
// thread at the start, and when the panel opens while no line runs
// (Refresh); the thread that runs the lines after each line, before the
// first thread learns that the line ended.
palette_table_write :: proc "contextless" () {
	if !palette_active() {
		return
	}
	count := 0
	for number in 0 ..< command_count {
		if count == palette_table.ENTRY_CAPACITY {
			break
		}
		if entry, ok := palette_entry_make(number); ok {
			palette_next_entries[count] = entry
			count += 1
		}
	}
	// One entry for each value of each setting of the machine: "set font
	// to spleen". Its help is the line that the console runs for it.
	for setting in settings.Setting {
		description := settings.descriptions[setting]
		for value in 0 ..< description.value_count {
			if count == palette_table.ENTRY_CAPACITY {
				break
			}
			entry := palette_table.Entry{kind = u8(palette_table.Entry_Kind.Setting), setting = u8(setting), setting_value = u8(value), result = u8(palette_table.Value_Kind.Integer)}
			name := system.Writer{buffer = entry.name[:]}
			system.write_part(&name, "set ")
			system.write_part(&name, description.title)
			system.write_part(&name, " to ")
			system.write_part(&name, description.value_names[value])
			about := system.Writer{buffer = entry.about[:]}
			palette_setting_line(&about, description.name, description.value_names[value])
			// The form of the entry in the panel: the values of one
			// setting are one row, and the window of `settings` names its
			// buttons with the same act name.
			act := system.Writer{buffer = entry.act_name[:]}
			system.write_part(&act, "settings.set:")
			system.write_part(&act, description.name)
			row := system.Writer{buffer = entry.setting_name[:]}
			system.write_part(&row, description.title)
			value_name := system.Writer{buffer = entry.value_name[:]}
			system.write_part(&value_name, description.value_names[value])
			if name.dropped != 0 || about.dropped != 0 || act.dropped != 0 || row.dropped != 0 || value_name.dropped != 0 {
				continue
			}
			entry.name_length = u8(name.count)
			entry.signature_length = u8(copy(entry.signature[:], entry.name[:name.count]))
			entry.about_length = u8(about.count)
			entry.act_name_length = u8(act.count)
			entry.setting_name_length = u8(row.count)
			entry.value_name_length = u8(value_name.count)
			palette_next_entries[count] = entry
			count += 1
		}
	}
	// One entry for each scheduling strategy: "set strategy to eevdf". Its
	// help is the line that the console runs for it. The strategy is a
	// state of the kernel that no page holds: the console reads it in the
	// system report, and marks the entry of the strategy in use.
	strategy_in_use := palette_strategy_in_use()
	for strategy in op.Strategy {
		if strategy == .None || count == palette_table.ENTRY_CAPACITY {
			continue
		}
		value_buffer: [PALETTE_STRATEGY_VALUE_CAPACITY]u8
		value := palette_strategy_value(&value_buffer, strategy)
		entry := palette_table.Entry{kind = u8(palette_table.Entry_Kind.Provider_Setting), result = u8(palette_table.Value_Kind.Integer)}
		if strategy == strategy_in_use {
			entry.flags += {.In_Use}
		}
		name := system.Writer{buffer = entry.name[:]}
		system.write_part(&name, "set strategy to ")
		system.write_part(&name, value)
		about := system.Writer{buffer = entry.about[:]}
		system.write_part(&about, "strategy(\"")
		system.write_part(&about, value)
		system.write_part(&about, "\")")
		// One row for the strategies; the window of `scheduler` names the
		// tile of the strategy in use with the same act name.
		act := system.Writer{buffer = entry.act_name[:]}
		system.write_part(&act, PALETTE_STRATEGY_ACT_NAME)
		row := system.Writer{buffer = entry.setting_name[:]}
		system.write_part(&row, PALETTE_STRATEGY_ACT_NAME)
		value_name := system.Writer{buffer = entry.value_name[:]}
		system.write_part(&value_name, value)
		if value == "" || name.dropped != 0 || about.dropped != 0 || act.dropped != 0 || row.dropped != 0 || value_name.dropped != 0 {
			continue
		}
		entry.name_length = u8(name.count)
		entry.signature_length = u8(copy(entry.signature[:], entry.name[:name.count]))
		entry.about_length = u8(about.count)
		entry.act_name_length = u8(act.count)
		entry.setting_name_length = u8(row.count)
		entry.value_name_length = u8(value_name.count)
		palette_next_entries[count] = entry
		count += 1
	}
	header := (^palette_table.Header)(raw_data(palette_memory))
	size := count * size_of(palette_table.Entry)
	system.lock(&palette_table_lock)
	defer system.unlock(&palette_table_lock)
	written_before := header.change_count != 0
	next_bytes := ([^]u8)(&palette_next_entries[0])[:size]
	kept_bytes := ([^]u8)(&palette_entries[0])[:size]
	if written_before && count == palette_entry_count && string(next_bytes) == string(kept_bytes) {
		return
	}
	copy(kept_bytes, next_bytes)
	palette_entry_count = count
	// The grant can end while a line runs: the table is used only while
	// the console is the provider.
	if !palette_active() {
		return
	}
	intrinsics.atomic_add(&header.change_count, 1)
	copy(palette_memory[palette_table.ENTRIES_OFFSET:], kept_bytes)
	header.entry_count = u32(count)
	generation := intrinsics.atomic_add(&header.change_count, 1) + 1
	system.word_wake(&header.change_count, 64)
	system.log(.Info, "console: the palette table has ", u64(count), " entries, generation ", u64(generation))
}

// palette_answer sends the answer to a choice.
palette_answer :: proc "contextless" (tag: u32, outcome: palette_table.Outcome, kind: Kind, length: int) {
	if !palette_active() {
		return
	}
	system.lock(&palette_send_lock)
	system.send(&palette_ring.completions, ring.Record{tag = tag, values = {0 = u64(outcome), 1 = u64(kind), 2 = u64(length)}})
	system.unlock(&palette_send_lock)
}

// palette_result_write copies the runs of a result into the result area of
// the table. It gives the count of its bytes.
palette_result_write :: proc "contextless" (runs: []u8) -> int {
	system.lock(&palette_table_lock)
	defer system.unlock(&palette_table_lock)
	if !palette_active() || len(runs) > palette_table.RESULT_CAPACITY {
		return 0
	}
	copy(palette_memory[palette_table.RESULT_OFFSET:][:palette_table.RESULT_CAPACITY], runs)
	return len(runs)
}

// palette_refuse answers a choice that the console does not run, with the
// sentence that the panel shows.
palette_refuse :: proc "contextless" (tag: u32, sentence: string) {
	area: [256]u8
	writer := palette_table.Result_Writer{buffer = area[:], fits = true}
	palette_table.result_run(&writer, .Failure, sentence)
	palette_table.result_line_end(&writer)
	system.log(.Info, "console: the palette choice is refused: ", sentence)
	palette_answer(tag, .Refused, .None, palette_result_write(area[:writer.count]))
}

// palette_turn is the part of the palette in the loop of the first
// thread. It answers a request to stop the use of the ring; and, when no
// line runs, it takes one choice of the compositor: the next one waits in
// the ring for the end of the line, as a key does.
palette_turn :: proc "contextless" () {
	if intrinsics.atomic_load_explicit(&palette_stop_request, .Relaxed) != 0 && intrinsics.atomic_load_explicit(&palette_stopped, .Relaxed) == 0 {
		intrinsics.atomic_store(&palette_provided, 0)
		intrinsics.atomic_store(&palette_stopped, 1)
		system.word_wake(&palette_stopped)
	}
	if !palette_active() || running {
		return
	}
	// The keys first: a key that waits for the end of a line, or that is
	// still in the terminal ring, was typed before the choice, and acts
	// before it. The loop reads the terminal ring at its next turn, which
	// comes at once: the ring is in its wait while no line runs.
	if pending_count > 0 || ring.count(&output.ring.completions) > 0 {
		return
	}
	// The typed values of a choice come before it, with its tag: they are
	// taken with it.
	for {
		record, received := system.receive(&palette_ring.commands)
		if !received {
			return
		}
		// The compositor writes the word: a word that names no command, and
		// None, are refused with a line, and the next record is read.
		palette_command, palette_command_ok := palette_table.command_of_ring_word(record.kind)
		if !palette_command_ok {
			system.log(.Info, "console: the palette sent the command word ", u64(record.kind), ", which names no command: it is refused")
			continue
		}
		switch palette_command {
		case .None:
			// Refused above.
			continue
		case .Argument:
			if parameter, argument, ok := palette_table.argument_unpack(record.values); ok {
				if palette_arguments_tag != record.tag {
					palette_arguments_tag = record.tag
					palette_arguments_given = {}
				}
				palette_arguments[parameter] = argument
				palette_arguments_given += {parameter}
			} else {
				// A value that is none: the choice of this tag is refused.
				palette_arguments_tag = record.tag
				palette_arguments_given = {}
				palette_arguments_bad = record.tag
			}
			continue
		case .Candidates:
			palette_candidates_give(record)
			continue
		case .Refresh:
			// The panel opened: the strategy can have changed with no
			// line of the console. No line runs now, so this thread is
			// the one writer of the table.
			palette_table_write()
			continue
		case .Manual:
			palette_manual_page(record)
		case .Choose:
			palette_choice(record)
		}
		return
	}
}

// The typed values of the choice that comes next on the ring.
palette_arguments: [palette_table.PARAMETER_CAPACITY]palette_table.Argument_Value
palette_arguments_given: bit_set[0 ..< palette_table.PARAMETER_CAPACITY]
palette_arguments_tag: u32 // The tag of the choice that the values are for.
palette_arguments_bad: u32 // The tag of a choice with a value that failed its check.
palette_manual: bool // The line that runs shows a page of the manual.

// palette_setting_line writes the line that sets a setting.
palette_setting_line :: proc "contextless" (writer: ^system.Writer, name: string, value: string) {
	system.write_part(writer, "setting(\"")
	system.write_part(writer, name)
	system.write_part(writer, "\", \"")
	system.write_part(writer, value)
	system.write_part(writer, "\")")
}

// palette_entry_named gives the copy of the entry that a record of the
// compositor names, when the index is inside the table of the console and
// the hash is the hash of the name of that entry: an index that names
// another entry, after the table changed, is not the entry that the panel
// showed. Each number is the number of another process.
palette_entry_named :: proc "contextless" (record: ring.Record) -> (entry: palette_table.Entry, ok: bool) {
	index, hash := record.values[1], record.values[2]
	system.lock(&palette_table_lock)
	if index < u64(palette_entry_count) {
		entry = palette_entries[index]
		ok = true
	}
	system.unlock(&palette_table_lock)
	return entry, ok && palette_table.name_hash(string(entry.name[:entry.name_length])) == hash
}

// palette_command_named gives the command of the command table that a
// call of a name runs: the last one with the name.
palette_command_named :: proc "contextless" (name: string) -> (found: ^Command) {
	for &item in commands[:command_count] {
		if item.name == name {
			found = &item
		}
	}
	return found
}

// palette_line_run runs a line that the console built for the palette, as
// a line that the input typed. What the input typed in the edit line and
// did not enter yet is kept: it is in the edit line again after the line
// of the palette is entered, so no typed key is lost.
palette_line_run :: proc "contextless" (tag: u32, text: string) {
	completion_close()
	history_place = 0
	typed_before := line
	line_editor.line_set(&line, text)
	system.log(.Info, "console: the palette runs ", text)
	palette_tag = tag
	line_enter()
	line = typed_before
}

// palette_choice takes one choice of the compositor.
palette_choice :: proc "contextless" (record: ring.Record) {
	mode, mode_ok := enum_word.member_of_word(palette_table.Choose_Mode, record.values[3])
	entry, named := palette_entry_named(record)
	if !named || !mode_ok {
		palette_refuse(record.tag, "the commands changed: choose again")
		return
	}
	name := string(entry.name[:entry.name_length])
	palette_manual = false
	if entry.kind == u8(palette_table.Entry_Kind.Setting) || entry.kind == u8(palette_table.Entry_Kind.Provider_Setting) {
		// The line of a setting, and of a scheduling strategy, is the
		// help of its entry, which the console wrote itself.
		palette_line_run(record.tag, string(entry.about[:entry.about_length]))
		return
	}
	found := palette_command_named(name)
	if found == nil {
		palette_refuse(record.tag, "the commands changed: choose again")
		return
	}
	text: [LINE_CAPACITY]u8
	writer := system.Writer{buffer = text[:]}
	system.write_part(&writer, name)
	system.write_part(&writer, "(")
	if mode == .Run_With_Arguments {
		// Each value has the kind of its parameter, and each parameter
		// has a value: the console checks them as it checks a line.
		// The values of a choice are in an array of the size of the form: a
		// command with more parameters has no entry, and the command table
		// can change between the entry and the choice.
		count := found.parameter_count
		fits := count <= palette_table.PARAMETER_CAPACITY && palette_arguments_tag == record.tag && palette_arguments_bad != record.tag && record.values[4] == u64(count) && count > 0
		// A Text of the palette and a line of the console are UTF-8. A text
		// that a line cannot hold (an invalid sequence, which the
		// compositor already refuses, or a quote) is refused in words,
		// never changed in silence.
		outside_line := false
		for index in 0 ..< count {
			if !fits || index not_in palette_arguments_given {
				fits = false
				break
			}
			argument := &palette_arguments[index]
			system.write_part(&writer, index > 0 ? ", " : "")
			switch {
			case found.parameters[index] == .Integer && argument.kind == .Integer:
				system.write_part(&writer, argument.integer)
			case found.parameters[index] == .Text && argument.kind == .Text:
				argument_text := argument.text[:argument.length]
				if !text_encoding.text_valid(argument_text) {
					outside_line = true
				}
				for value in argument_text {
					if value == '"' {
						outside_line = true
					}
				}
				system.write_part(&writer, "\"")
				system.write_part(&writer, string(argument.text[:argument.length]))
				system.write_part(&writer, "\"")
			case:
				fits = false
			}
		}
		palette_arguments_given = {}
		system.write_part(&writer, ")")
		if fits && outside_line {
			palette_refuse(record.tag, "a line of the console holds no quote and no invalid sequence of UTF-8 in a text")
			return
		}
		if !fits || writer.dropped != 0 {
			palette_refuse(record.tag, "the arguments do not fit the command: type the line in the console")
			return
		}
		palette_line_run(record.tag, string(text[:writer.count]))
		return
	}
	system.write_part(&writer, ")")
	if mode == .Edit || found.parameter_count > 0 {
		// The input writes the arguments: the caret is between the
		// parentheses.
		completion_close()
		history_place = 0
		line_editor.line_set(&line, string(text[:writer.count]))
		line_editor.line_key(&line, .Left)
		system.log(.Info, "console: the palette opens ", string(text[:writer.count]), " in the edit line")
		palette_answer(record.tag, .Edit_Opened, .None, 0)
		return
	}
	palette_line_run(record.tag, string(text[:writer.count]))
}

// palette_manual_page runs the line that shows the page of the manual of
// a module: the compositor gave its name as a typed value.
palette_manual_page :: proc "contextless" (record: ring.Record) {
	packed := system.name_unpack({record.values[0], record.values[1], record.values[2], record.values[3]})
	name := system.name_of(packed[:])
	valid := len(name) > 0
	for index in 0 ..< len(name) {
		if name[index] < 32 || name[index] > 126 || name[index] == '"' {
			valid = false
		}
	}
	if !valid {
		palette_refuse(record.tag, "the name of the module is no name")
		return
	}
	text: [LINE_CAPACITY]u8
	writer := system.Writer{buffer = text[:]}
	system.write_part(&writer, "manual_page(\"")
	system.write_part(&writer, name)
	system.write_part(&writer, "\")")
	// The mark first: the thread that runs the lines reads it at the end
	// of the line.
	palette_manual = true
	palette_line_run(record.tag, string(text[:writer.count]))
}

// What the values of a parameter of a command are, for the candidates of
// a field of the palette.
palette_candidate_kind :: proc "contextless" (command_name: string, parameter: u64) -> palette_table.Candidate_Kind {
	switch command_name {
	case "stop", "grants", "connect", "debug":
		if parameter == 0 {
			return .Process
		}
	case "revoke":
		if parameter == 0 {
			return .Process
		}
		if parameter == 1 {
			return .Grant
		}
	case "start", "load", "isolate", "manual_page":
		if parameter == 0 {
			return .Module
		}
	case "replace":
		if parameter <= 1 {
			return .Module
		}
	case "strategy":
		if parameter == 0 {
			return .Strategy
		}
	case "setting":
		if parameter == 0 {
			return .Setting
		}
	}
	return .None
}

// palette_candidates_closed says if the candidates of a kind are the only
// values that a parameter takes: the strategies of the kernel and the names
// of the settings are; the processes that run, the modules and the grants
// are suggestions, since a line can name another one.
palette_candidates_closed :: proc "contextless" (kind: palette_table.Candidate_Kind) -> bool {
	switch kind {
	case .Strategy, .Setting:
		return true
	case .None, .Process, .Module, .Grant:
	}
	return false
}

// palette_candidates_give answers a request for the candidates of one
// parameter of one entry: it writes their names in the candidate area of
// the table, then their kind and their count on the ring. A name that
// does not fit a candidate is left out. With no candidate the count is 0.
palette_candidates_give :: proc "contextless" (record: ring.Record) {
	entry, named := palette_entry_named(record)
	kind := palette_table.Candidate_Kind.None
	if named {
		kind = palette_candidate_kind(string(entry.name[:entry.name_length]), record.values[3])
	}
	candidates: [palette_table.CANDIDATE_CAPACITY]palette_table.Candidate
	count := 0
	add :: proc "contextless" (into: ^[palette_table.CANDIDATE_CAPACITY]palette_table.Candidate, used: ^int, added: string) {
		if used^ < palette_table.CANDIDATE_CAPACITY && len(added) > 0 && len(added) <= palette_table.CANDIDATE_NAME_CAPACITY && text_encoding.text_valid(transmute([]u8)added) {
			into[used^].length = u8(copy(into[used^].name[:], added))
			used^ += 1
		}
	}
	switch kind {
	case .None:
	case .Strategy:
		for strategy in op.Strategy {
			if strategy == .None {
				continue
			}
			value_buffer: [PALETTE_STRATEGY_VALUE_CAPACITY]u8
			add(&candidates, &count, palette_strategy_value(&value_buffer, strategy))
		}
	case .Setting:
		for description in settings.descriptions {
			add(&candidates, &count, description.name)
		}
	case .Grant:
		for grant in system.Root_Grant {
			add(&candidates, &count, system.root_grant_names[grant])
		}
	case .Module:
		entries := system.image_entries(image)
		for &image_entry in entries {
			add(&candidates, &count, system.name_of(image_entry.name[:]))
		}
	case .Process:
		// The processes that run, from the reports of the machine, as the
		// completion of the edit line reads them.
		report: op.System_Report
		if _, status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.System), 0, u64(uintptr(&report)), size_of(report)); status == .Ok {
			for slot in 1 ..< report.process_slots {
				process: op.Process_Report
				if _, process_status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Process), slot, u64(uintptr(&process)), size_of(process)); process_status != .Ok {
					continue
				}
				if process.state == .None || process.state == .Stopped {
					continue
				}
				// One row for each name: two processes can have one.
				name := system.name_of(process.name[:])
				known := false
				for &candidate in candidates[:count] {
					if string(candidate.name[:candidate.length]) == name {
						known = true
					}
				}
				if !known {
					add(&candidates, &count, name)
				}
			}
		}
	}
	system.lock(&palette_table_lock)
	if palette_active() {
		bytes := ([^]u8)(&candidates[0])[:count * size_of(palette_table.Candidate)]
		copy(palette_memory[palette_table.CANDIDATES_OFFSET:], bytes)
	}
	system.unlock(&palette_table_lock)
	if !palette_active() {
		return
	}
	system.log(.Info, "console: the palette gets ", u64(count), " candidates for the parameter ", record.values[3], " of ", string(entry.name[:named ? int(entry.name_length) : 0]))
	system.lock(&palette_send_lock)
	facts: u64 = palette_candidates_closed(kind) ? palette_table.CANDIDATES_CLOSED : 0
	system.send(&palette_ring.completions, ring.Record{tag = record.tag, values = {0 = u64(palette_table.Outcome.Candidates_Ready), 1 = u64(kind), 2 = u64(count), 3 = facts}})
	system.unlock(&palette_send_lock)
}

// palette_commands_add adds the two commands that the palette runs under
// a short name: each one is an export of a service.
palette_commands_add :: proc "contextless" () {
	// Sets one setting of the machine: the export `set` of the service
	// `settings`, under a short name.
	//
	// - `name`: the name of a setting: `font`, `subpixel_order`,
	//   `pointer_theme`, `grid_fit`.
	// - `value`: the name of one of its values.
	//
	// The command connects to `settings` when the console has no
	// connection to it yet. The palette of the desktop runs it for an
	// entry such as "set font to spleen".
	//
	// Errors: those of `connect("settings")`, and those of the export.
	command("setting", {.Text, .Text}, .Integer, "set a setting of the machine: settings.set()", proc "contextless" (arguments: []Value) -> Value {
		return bound_call("settings", "set", arguments)
	})
	// Shows the page of a module in the window of the manual: the export
	// `show` of the service `manual`, under a short name. It gives the
	// count of the exports of the module.
	//
	// - `name`: the name of a module of the boot image.
	//
	// The process `manual` must run: the command starts no process.
	//
	// Errors: those of `connect("manual")`, and those of the export.
	command("manual_page", {.Text}, .Integer, "show the page of a module in the manual: manual.show()", proc "contextless" (arguments: []Value) -> Value {
		return bound_call("manual", "show", arguments)
	})
	// Sets the scheduling strategy of the machine: the export
	// `strategy_set` of the service `scheduler`, under a short name. It
	// gives the number of the strategy that the machine used before.
	//
	// - `name`: `round_robin`, `fair` or `eevdf`.
	//
	// The console holds no right to change the strategy: the process
	// `scheduler` holds it, and must run. The command starts no process.
	// The palette of the desktop runs it for an entry such as "set
	// strategy to eevdf".
	//
	// Errors: those of `connect("scheduler")`, and those of the export.
	command("strategy", {.Text}, .Integer, "set the scheduling strategy: scheduler.strategy_set()", proc "contextless" (arguments: []Value) -> Value {
		return bound_call("scheduler", "strategy_set", arguments)
	})
	// The names of the parameters of the built-in commands that the form
	// of the palette asks for: a field says what it takes. help() and
	// describe() show them too.
	Named :: struct {
		command: string,
		names:   [2]string,
	}
	named := [?]Named {
		{"start", {"name", ""}},
		{"start_from_disk", {"name", "hash"}},
		{"start_policy_choose", {"nickname", "hash"}},
		{"stop", {"name", ""}},
		{"grants", {"name", ""}},
		{"revoke", {"name", "grant"}},
		{"connect", {"name", ""}},
		{"load", {"name", ""}},
		{"isolate", {"name", ""}},
		{"unload", {"name", ""}},
		{"replace", {"module", "by"}},
		{"debug", {"process", ""}},
		{"describe", {"name", ""}},
		{"setting", {"name", "value"}},
		{"manual_page", {"name", ""}},
		{"strategy", {"name", ""}},
		{"buffer", {"count", ""}},
		{"debug_memory", {"place", "count"}},
		{"wait_stop", {"milliseconds", ""}},
		{"stop_report", {"process", ""}},
	}
	for item in named {
		if found := palette_command_named(item.command); found != nil && found.run != nil {
			for name, index in item.names {
				if index < found.parameter_count {
					found.parameter_names[index] = name
				}
			}
		}
	}
}

// run_part_of gives the run part of the palette of a part of a result: the
// two enums have one member for each part, and a switch names each.
run_part_of :: proc "contextless" (part: console_results.Part) -> (run_part: palette_table.Run_Part) {
	switch part {
	case .Plain:
		run_part = .Plain
	case .Label:
		run_part = .Label
	case .Note:
		run_part = .Note
	case .Failure:
		run_part = .Failure
	case .Number:
		run_part = .Number
	case .Handle:
		run_part = .Handle
	case .Type:
		run_part = .Type
	case .Status:
		run_part = .Status
	case .Operation:
		run_part = .Operation
	case .Size:
		run_part = .Size
	case .Time:
		run_part = .Time
	}
	return run_part
}

// palette_line_ended answers the choice of the palette that the line was,
// after the console drew its result in its own window. The thread that
// runs the lines calls it after each line. A short result goes to the
// panel as the runs that its drawer writes: an Integer, a Text of one
// line, a Record of few fields, an error. Each other result is in the
// window of the console only, and the answer says so.
palette_line_ended :: proc "contextless" () {
	tag := palette_tag
	if tag == 0 {
		return
	}
	palette_tag = 0
	area: [palette_table.RESULT_CAPACITY]u8
	writer := palette_table.Result_Writer{buffer = area[:], fits = true}
	sink := console_results.Sink {
		data = &writer,
		write = proc "contextless" (sink: ^console_results.Sink, text: string, part: console_results.Part) {
			palette_table.result_run((^palette_table.Result_Writer)(sink.data), run_part_of(part), text)
		},
		end_line = proc "contextless" (sink: ^console_results.Sink) {
			palette_table.result_line_end((^palette_table.Result_Writer)(sink.data))
		},
	}
	outcome := palette_table.Outcome.Shown_In_Panel
	value := line_value
	manual := palette_manual
	palette_manual = false
	if manual && !failed {
		// The window of the manual shows the page: the panel has nothing
		// to draw.
		system.log(.Info, "console: the manual shows the page that the palette asked for")
		palette_answer(tag, .Manual_Opened, .Integer, 0)
		return
	}
	if failed {
		outcome = .Failed
		value = {}
		drawn := console_results.Failure {
			sentence       = string(failure.sentence[:failure.sentence_count]),
			operation      = string(failure.operation[:failure.operation_count]),
			argument_names = failure.argument_names[:failure.argument_count],
		}
		if failure.has_record {
			drawn.record = &failure.record
		}
		console_results.draw_failure(&sink, drawn)
		if !writer.fits {
			// The whole error is in the window of the console; the panel
			// has the start of its sentence.
			writer = {buffer = area[:], fits = true}
			palette_table.result_run(&writer, .Failure, console_results.FAILURE_START)
			// The start of the sentence ends after a whole character.
			room := min(len(drawn.sentence), palette_table.RESULT_COLUMN_CAPACITY - len(console_results.FAILURE_START))
			start := text_encoding.complete_characters(transmute([]u8)drawn.sentence[:room])
			palette_table.result_run(&writer, .Failure, drawn.sentence[:start])
			palette_table.result_line_end(&writer)
		}
	} else {
		switch value.kind {
		case .None:
			palette_table.result_run(&writer, .Note, "done")
			palette_table.result_line_end(&writer)
		case .Integer:
			console_results.draw_integer(&sink, value.integer)
		case .Text:
			one_line := true
			for index in 0 ..< len(value.text) {
				if value.text[index] == '\n' {
					one_line = false
				}
			}
			if one_line {
				console_results.draw_text(&sink, value.text)
			} else {
				writer.fits = false
			}
		case .Record:
			console_results.draw_record(&sink, value.file, value.detail, value.record)
		case .Handle, .Table, .Bytes:
			// The panel has no drawer for these: the console window shows them.
			writer.fits = false
		}
		if !writer.fits {
			outcome = .Shown_In_Console
			writer = {buffer = area[:]} // No run goes to the panel.
		}
	}
	if outcome == .Shown_In_Console {
		system.log(.Info, "console: the result of the palette choice is in the console: ", kind_names[value.kind])
	} else {
		system.log(.Info, "console: the palette gets ", failed ? "an error" : kind_names[value.kind], ", ", u64(writer.lines), " lines")
	}
	palette_answer(tag, outcome, value.kind, palette_result_write(area[:writer.count]))
}

// palette_stop_before_revoke ends the use of the table and of the ring by
// the two threads, before the console asks the root service to end its own
// grant: after the revocation the two mappings are gone. The thread that
// runs the lines calls it; it waits for the first thread, which can be in
// a wait on the ring, with the bound of a hang of a call to the root
// service.
palette_stop_before_revoke :: proc "contextless" () {
	if !palette_active() {
		return
	}
	intrinsics.atomic_store(&palette_stop_request, 1)
	change()
	limit := system.time() + 3000
	for intrinsics.atomic_load_explicit(&palette_stopped, .Relaxed) == 0 && system.time() < limit {
		system.word_wait(&palette_stopped, 0, limit)
	}
	intrinsics.atomic_store(&palette_provided, 0)
	system.log(.Info, "console: the console is no more the palette provider")
}
