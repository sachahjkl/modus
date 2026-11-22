package console

import "modus:contract/enum_word"
import "modus:contract/isolated"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/palette_table"
import "modus:contract/ring"
import "modus:contract/text_encoding"
import "modus:contract/value_kinds"
import "internal:console/console_results"
import "modus:lex_parser"
import "modus:line_editor"
import "modus:system"
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
#assert(u8(console_results.Part.Size) == u8(palette_table.Run_Part.Size) && u8(console_results.Part.Time) == u8(palette_table.Run_Part.Time))
#assert(u8(console_results.Part.Module) == u8(palette_table.Run_Part.Module) && u8(console_results.Part.Version) == u8(palette_table.Run_Part.Version) && max(console_results.Part) == console_results.Part.Version)
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
// checked against this copy, never against the shared memory. Both buffers
// grow on demand via system.memory_create so there is no fixed entry cap.
palette_entries_handle, palette_next_handle: system.Handle
palette_entries: []palette_table.Entry
palette_next_entries: []palette_table.Entry
palette_entry_count: int
palette_table_lock: system.Lock
palette_send_lock: system.Lock // The ring has two writers: the two threads.
palette_tag: u32 // Not 0: the line that runs is a choice of the palette with this tag.
line_value: Value // The value of the line that ran last, for the answer to the palette.

// palette_next_append appends one entry to palette_next_entries, growing its
// backing memory object if needed. Returns false only if the kernel refuses
// memory allocation.
palette_next_append :: proc "contextless" (count: ^int, entry: palette_table.Entry) -> bool {
	if count^ >= len(palette_next_entries) {
		new_cap := max(len(palette_next_entries) * 2, palette_table.INITIAL_ENTRY_CAPACITY)
		if new_cap <= count^ {
			new_cap = count^ + palette_table.INITIAL_ENTRY_CAPACITY
		}
		pages := (u64(new_cap) * size_of(palette_table.Entry) + system.PAGE_SIZE - 1) / system.PAGE_SIZE
		new_handle, create_status := system.memory_create(pages)
		if create_status != .Ok {
			return false
		}
		address, map_status := system.memory_map(new_handle, {.Write})
		if map_status != .Ok {
			system.close(new_handle)
			return false
		}
		capacity := int(pages * system.PAGE_SIZE / size_of(palette_table.Entry))
		new_slice := ([^]palette_table.Entry)(address)[:capacity]
		if count^ > 0 {
			copy(new_slice[:count^], palette_next_entries[:count^])
		}
		if palette_next_handle != 0 {
			system.memory_unmap(raw_data(palette_next_entries))
			system.close(palette_next_handle)
		}
		palette_next_handle = new_handle
		palette_next_entries = new_slice
	}
	palette_next_entries[count^] = entry
	count^ += 1
	return true
}

// palette_kept_ensure guarantees palette_entries can hold at least needed
// entries (called under palette_table_lock).
palette_kept_ensure :: proc "contextless" (needed: int) -> bool {
	if needed <= len(palette_entries) {
		return true
	}
	new_cap := max(len(palette_entries) * 2, needed, palette_table.INITIAL_ENTRY_CAPACITY)
	pages := (u64(new_cap) * size_of(palette_table.Entry) + system.PAGE_SIZE - 1) / system.PAGE_SIZE
	new_handle, create_status := system.memory_create(pages)
	if create_status != .Ok {
		return false
	}
	address, map_status := system.memory_map(new_handle, {.Write})
	if map_status != .Ok {
		system.close(new_handle)
		return false
	}
	capacity := int(pages * system.PAGE_SIZE / size_of(palette_table.Entry))
	new_slice := ([^]palette_table.Entry)(address)[:capacity]
	if palette_entry_count > 0 {
		copy(new_slice[:palette_entry_count], palette_entries[:palette_entry_count])
	}
	if palette_entries_handle != 0 {
		system.memory_unmap(raw_data(palette_entries))
		system.close(palette_entries_handle)
	}
	palette_entries_handle = new_handle
	palette_entries = new_slice
	return true
}

// palette_provider_start asks the root service for the entry table and the
// ring, and writes the first table. The first thread calls it once, before
// a line runs. Without the grant the console has no provider part, and the
// palette lists the modules and the windows only.
palette_provider_start :: proc "contextless" () {
	// The root service answers when it reaches its loop, after its boot
	// passes: the bound only ends a hang.
	completion, answered := request_record(.Palette_Provide, "console", 0, 60_000)
	if !answered || system.Status(completion.kind) != .Ok {
		system.log_fact(.Info, Provider_Refused{})
		return
	}
	palette_table_handle, palette_ring_handle = system.Handle(completion.values[0]), system.Handle(completion.values[1])
	table_kind, _, _ := system.handle_state(palette_table_handle)
	table_pages, table_status := system.memory_size(palette_table_handle)
	if table_kind != .Memory || table_status != .Ok || table_pages < palette_table.MIN_TABLE_PAGES {
		system.log_fact(.Info, Provider_Without_Table{})
		return
	}
	address, status := system.memory_map(palette_table_handle)
	if status != .Ok {
		system.log_fact(.Info, Provider_Table_Not_Mapped{})
		return
	}
	opened, ring_status := system.ring_open(palette_ring_handle)
	if ring_status != .Ok {
		system.memory_unmap(address)
		system.log_fact(.Info, Provider_Without_Ring{})
		return
	}
	palette_commands_add()
	palette_ring = opened
	palette_memory = ([^]u8)(address)[:table_pages * system.PAGE_SIZE]
	header := (^palette_table.Header)(address)
	header.magic = palette_table.MAGIC
	header.version = palette_table.VERSION
	header.entry_count = 0
	header.byte_length = palette_table.MIN_TABLE_BYTES
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
	// A command whose call is a choice of members has its rows of buttons
	// (palette_enum_rows_write), and no entry beside them: one act is shown
	// once.
	if palette_row_takes(item) {
		return {}, false
	}
	for &later in commands[number + 1:command_count] {
		if later.name == item.name {
			return {}, false
		}
	}
	// A parameter that the parser reads as a name (a condition, a fact
	// name) has no field of the form of the panel: the console line calls
	// that command.
	// A parameter that the parser reads as a name, and one that takes a
	// typed name of a record stream, has no field of the form either.
	given_count := item.optional_last ? item.parameter_count - 1 : item.parameter_count
	for index in 0 ..< given_count {
		if item.parameter_forms[index] != .Expression || item.parameters[index] == .Stream || item.parameters[index] == .Record_Input {
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
	// The form asks for the parameters that a call needs: the palette
	// starts a process with no wiring list.
	entry.parameter_count = u8(given_count)
	for kind, index in item.parameters[:entry.parameter_count] {
		entry.parameters[index] = u8(palette_value_kind_of(kind))
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
	entry.result = u8(palette_value_kind_of(item.result))
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

// palette_value_kind_of gives the kind of a value of the palette table of a
// kind of the console: the kinds of the console only (a Stream, a record
// input, a literal, a member not typed yet) are no value of the table.
palette_value_kind_of :: proc "contextless" (kind: Kind) -> (value_kind: palette_table.Value_Kind) {
	switch kind {
	case .None:
		value_kind = .None
	case .Integer:
		value_kind = .Integer
	case .Text:
		value_kind = .Text
	case .Record:
		value_kind = .Record
	case .Handle:
		value_kind = .Handle
	case .Table:
		value_kind = .Table
	case .Bytes:
		value_kind = .Bytes
	case .Enum:
		value_kind = .Enum
	case .Stream, .Record_Input, .Record_Literal, .Member, .Function, .List, .Hash, .Boolean, .Record_With, .Module_Ref, .Recipe_Ref, .Follow_Ref, .Store_Ref, .Plan_Value, .Project_Value:
		value_kind = .None
	}
	return value_kind
}

// The member in use of one row of buttons, by the act name of the row: what
// its getter gave when the panel opened last. The table written after a
// line keeps these marks, and calls no getter.
Palette_Row_In_Use :: struct {
	act:        [palette_table.ACT_NAME_CAPACITY]u8,
	act_length: int,
	value:      i64,
}
PALETTE_ROW_CAPACITY :: 32 // The rows whose member in use the provider keeps; a row past them has no mark.
palette_rows_in_use: [PALETTE_ROW_CAPACITY]Palette_Row_In_Use
palette_rows_in_use_count: int

// palette_row_takes says if a command gives one row of buttons for each of
// its Enum parameters (src/md/features/enum_parameters.md): an export of
// one parameter, an Enum, whose call is one choice; or an export whose
// parameters are each an optional Enum, whose call with one argument is one
// choice. An export with other parameters is a call with arguments: it
// opens as a form or in the console.
palette_row_takes :: proc "contextless" (item: ^Command) -> bool {
	if item.run != nil || item.record != 0 || item.parameter_count == 0 || item.parameter_count > ARGUMENT_CAPACITY {
		return false
	}
	if item.parameter_count == 1 && item.parameters[0] == .Enum {
		return true
	}
	for kind, index in item.parameters[:item.parameter_count] {
		if kind != .Enum || !module.parameter_optional(item.function, index) {
			return false
		}
	}
	return true
}

// PALETTE_GETTERS_LIMIT bounds one refresh of the marks, all getters
// together: a service that is slow, or many rows, cannot hold the thread
// of the lines past it.
PALETTE_GETTERS_LIMIT :: 1000 // Milliseconds.

// One refresh of the marks: its end, and the sandboxes and services that
// missed a getter in it, which it asks nothing more.
Palette_Getters :: struct {
	limit:          u64,
	missed:         bit_set[0 ..< SANDBOX_CAPACITY],
	sent:           u64, // The getters sent to a service or an isolated process.
	in_the_console: u64, // The getters of modules in the process of the console: not called.
}

// palette_getter_value calls the getter of an Enum parameter of a command:
// the export getter of its module, with no argument, in an isolated
// process or a service, within the bound of the refresh. It gives the
// value of its member, or ok false: the getter is no command now, its
// module is in the process of the console, the process that serves it
// does not run or missed a getter before in this refresh, or it gave no
// answer before the end of the refresh.
//
// A module that the console loaded in its own process is never called: a
// direct call has no bound, and a getter that loops would hold the console
// for good. Only the thread of the lines calls it, when no line runs: it
// owns the rings of the sandboxes and of the services.
palette_getter_value :: proc "contextless" (refresh: ^Palette_Getters, item: ^Command, getter: u32, enum_type: module.Enum_Type) -> (value: i64, ok: bool) {
	found: ^Command
	for &command in commands[:command_count] {
		if command.run == nil && command.record == 0 && command.export == getter && raw_data(command.file) == raw_data(item.file) {
			found = &command
		}
	}
	if found != nil && found.address != 0 {
		refresh.in_the_console += 1
		return 0, false
	}
	if found == nil || found.sandbox == 0 || int(found.sandbox) > SANDBOX_CAPACITY {
		return 0, false
	}
	place := int(found.sandbox - 1)
	sandbox := &sandboxes[place]
	if sandbox.process == 0 || place in refresh.missed || system.time() >= refresh.limit {
		return 0, false
	}
	// Each way out below that gives no member is a miss of the service.
	missed := true
	defer if missed {
		refresh.missed += {place}
	}
	offset, size, _, _, encoded := isolated.encode(found.file, found.function, nil, sandbox.region)
	if !encoded {
		return 0, false
	}
	sandbox.calls += 1
	if !system.send(&sandbox.ring.commands, ring.Record{kind = getter, tag = sandbox.calls, values = {0 = offset, 1 = size}}) {
		return 0, false
	}
	refresh.sent += 1
	for {
		wait := system.wait_begin()
		for _ in 0 ..< ring.CAPACITY {
			completion, has_completion := system.receive(&sandbox.ring.completions)
			if !has_completion {
				break
			}
			if completion.tag != sandbox.calls {
				continue
			}
			// The process writes the word: a word that names no status is
			// refused, never read as a status.
			call_status, call_status_ok := enum_word.member_of_word(isolated.Status, u64(completion.kind))
			if !call_status_ok || call_status != .Ok {
				return 0, false
			}
			missed = false
			return module.enum_value_of_register(enum_type, i64(completion.values[0])), true
		}
		if state, _, _ := system.process_state(sandbox.process); state == .Stopped {
			return 0, false
		}
		system.wait_records(&wait, &sandbox.ring.completions)
		if system.wait_end(&wait, refresh.limit) >= refresh.limit {
			return 0, false
		}
	}
}

// palette_row_in_use gives the member in use of the row of an act name:
// from its getter in a refresh, which it keeps, or else the value that the
// getter gave last. A getter that gives no member removes the value that
// the row kept, so the row shows no old mark. moved: a getter gave another
// member than the row kept, or the row kept none.
palette_row_in_use :: proc "contextless" (act: string, item: ^Command, getter: u32, enum_type: module.Enum_Type, refresh: ^Palette_Getters) -> (value: i64, known: bool, moved: bool) {
	kept_place := -1
	for &row, place in palette_rows_in_use[:palette_rows_in_use_count] {
		if string(row.act[:row.act_length]) == act {
			kept_place = place
		}
	}
	if refresh == nil {
		if kept_place < 0 {
			return 0, false, false
		}
		return palette_rows_in_use[kept_place].value, true, false
	}
	if getter != 0 {
		value, known = palette_getter_value(refresh, item, getter, enum_type)
	}
	if !known {
		if kept_place >= 0 {
			palette_rows_in_use_count -= 1
			palette_rows_in_use[kept_place] = palette_rows_in_use[palette_rows_in_use_count]
		}
		return 0, false, false
	}
	kept: ^Palette_Row_In_Use
	if kept_place >= 0 {
		kept = &palette_rows_in_use[kept_place]
	}
	moved = kept == nil || kept.value != value
	if kept == nil && palette_rows_in_use_count < PALETTE_ROW_CAPACITY {
		kept = &palette_rows_in_use[palette_rows_in_use_count]
		palette_rows_in_use_count += 1
		kept.act_length = copy(kept.act[:], act)
	}
	if kept != nil {
		kept.value = value
	}
	return value, true, moved
}

// A mark that a refresh moved: the console logs it once the table that
// holds it is written. The names point into the command table, which no
// refresh changes.
Palette_Moved_Mark :: struct {
	member, command, parameter: string,
}
palette_marks_moved: [PALETTE_ROW_CAPACITY]Palette_Moved_Mark
palette_marks_moved_count: int

// palette_marks_log logs each mark that the table written last moved.
palette_marks_log :: proc "contextless" () {
	for mark in palette_marks_moved[:palette_marks_moved_count] {
		system.log_fact(.Info, Palette_Mark_Moved{member = value_kinds.text_field(mark.member, MARK_MEMBER_FIELD_BYTES), command = value_kinds.text_field(mark.command, MARK_COMMAND_FIELD_BYTES), parameter = value_kinds.text_field(mark.parameter, MARK_PARAMETER_FIELD_BYTES)})
	}
	palette_marks_moved_count = 0
}

// The language tags of the principal, in the order of the preference, for
// the display texts that the palette and the completion show. A fallback:
// `en` alone, until the interface follows the language of the principal
// (ROADMAP.md, "The interface in the language of the principal"), which
// gives the tags of the principal in its place.
@(rodata)
principal_language_tags_fallback := [1]string{"en"}

// palette_line_name_valid says if the name of a command is names of Lex
// joined by '.': the service, then the export. The line of a row starts
// with it, so it must add nothing to that line.
palette_line_name_valid :: proc "contextless" (name: string) -> bool {
	start := 0
	for index in 0 ..= len(name) {
		if index == len(name) || name[index] == '.' {
			if !lex_parser.name_valid(name[start:index]) {
				return false
			}
			start = index + 1
		}
	}
	return true
}

// palette_enum_rows_write adds the rows of buttons of the Enum parameters
// of the commands after count entries, and gives the new count: one entry
// for each member, whose line is the call with that member. The entries of
// one parameter follow each other, with one row name and one act name, so
// the panel joins them into one row. The member in use has the flag
// In_Use.
palette_enum_rows_write :: proc "contextless" (start: int, refresh: ^Palette_Getters) -> (count: int) {
	count = start
	commands_loop: for number in 0 ..< command_count {
		item := &commands[number]
		if !palette_row_takes(item) || len(item.name) > palette_table.NAME_CAPACITY || !palette_line_name_valid(item.name) {
			continue
		}
		for &later in commands[number + 1:command_count] {
			if later.name == item.name {
				continue commands_loop
			}
		}
		for parameter in 0 ..< item.parameter_count {
			enum_index, getter := module.enum_detail_of(item.function.parameter_details[parameter])
			described, problem := module.enum_type(item.file, enum_index)
			parameter_name := item.parameter_names[parameter]
			if problem != .None || !lex_parser.name_valid(parameter_name) {
				continue
			}
			act_buffer: [palette_table.ACT_NAME_CAPACITY]u8
			act_writer := system.Writer{buffer = act_buffer[:]}
			system.write_part(&act_writer, item.name)
			system.write_part(&act_writer, ":")
			system.write_part(&act_writer, parameter_name)
			if act_writer.dropped != 0 {
				continue
			}
			act := string(act_buffer[:act_writer.count])
			in_use, in_use_known, moved := palette_row_in_use(act, item, getter, described, refresh)
			// A row whose name the table cannot hold has no entry: its mark
			// is not logged either.
			if moved && palette_marks_moved_count < PALETTE_ROW_CAPACITY && len(parameter_name) <= palette_table.SETTING_NAME_CAPACITY {
				if member_name, named := module.enum_name_of_value(item.file, described, in_use); named {
					palette_marks_moved[palette_marks_moved_count] = {member = member_name, command = item.name, parameter = parameter_name}
					palette_marks_moved_count += 1
				}
			}
			for member_number in 0 ..< described.member_count {
				member, _ := module.enum_member(item.file, described, member_number)
				member_name := module.string_at(item.file, member.name_offset, member.name_count)
				// The principal reads the display text; the line types the
				// name (src/md/features/enum_parameters.md, "The display
				// text of a member").
				display_text := module.member_display_text(item.file, enum_index, described, member_number, principal_language_tags_fallback[:])
				entry := palette_table.Entry{kind = u8(palette_table.Entry_Kind.Provider_Setting), result = u8(palette_value_kind_of(item.result))}
				if in_use_known && member.value == in_use {
					entry.flags += {.In_Use}
				}
				name := system.Writer{buffer = entry.name[:]}
				system.write_part(&name, item.name)
				system.write_part(&name, " ")
				system.write_part(&name, parameter_name)
				system.write_part(&name, " to ")
				system.write_part(&name, display_text)
				// The help of the entry is the line that the console runs.
				about := system.Writer{buffer = entry.about[:]}
				system.write_part(&about, item.name)
				system.write_part(&about, "(")
				system.write_part(&about, parameter_name)
				system.write_part(&about, " = .")
				system.write_part(&about, member_name)
				system.write_part(&about, ")")
				row := system.Writer{buffer = entry.setting_name[:]}
				system.write_part(&row, parameter_name)
				value_name := system.Writer{buffer = entry.value_name[:]}
				system.write_part(&value_name, display_text)
				if name.dropped != 0 || about.dropped != 0 || row.dropped != 0 || value_name.dropped != 0 {
					continue
				}
				entry.name_length = u8(name.count)
				entry.signature_length = u8(copy(entry.signature[:], entry.name[:name.count]))
				entry.about_length = u8(about.count)
				entry.act_name_length = u8(copy(entry.act_name[:], act))
				entry.setting_name_length = u8(row.count)
				entry.value_name_length = u8(value_name.count)
				if !palette_next_append(&count, entry) {
					return count
				}
			}
		}
	}
	return count
}

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
// after it, and wakes the reader. One thread writes: the first thread at
// the start, before the thread of the lines runs; then only the thread of
// the lines, after each line and for each refresh. call_getters: call the
// getter of each row of buttons for its member in use, all within
// PALETTE_GETTERS_LIMIT; else each row keeps the mark of the last call.
palette_table_write :: proc "contextless" (call_getters := false) {
	if !palette_active() {
		return
	}
	refresh := Palette_Getters{limit = system.time() + PALETTE_GETTERS_LIMIT}
	// After the table is written and its lock let go: a test that reads
	// the fact then finds the mark in the table.
	defer {
		palette_marks_log()
		if call_getters {
			system.log_fact(.Info, Palette_Marks_Refreshed{sent = refresh.sent, in_the_console = refresh.in_the_console})
		}
	}
	count := 0
	for number in 0 ..< command_count {
		if entry, ok := palette_entry_make(number); ok {
			if !palette_next_append(&count, entry) {
				break
			}
		}
	}
	// One row of buttons for each Enum parameter of an export whose call
	// with one member is one choice: "settings.set font to spleen". Its
	// help is the line that the console runs for it.
	count = palette_enum_rows_write(count, call_getters ? &refresh : nil)
	// One entry for each scheduling strategy: "set strategy to eevdf". Its
	// help is the line that the console runs for it. The strategy is a
	// state of the kernel that no page holds: the console reads it in the
	// system report, and marks the entry of the strategy in use.
	strategy_in_use := palette_strategy_in_use()
	for strategy in op.Strategy {
		if strategy == .None {
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
		if !palette_next_append(&count, entry) {
			break
		}
	}
	expected_bytes, bytes_ok := palette_table.table_bytes_for(u64(count))
	if !bytes_ok {
		return
	}
	size := count * size_of(palette_table.Entry)
	system.lock(&palette_table_lock)
	defer system.unlock(&palette_table_lock)
	header := (^palette_table.Header)(raw_data(palette_memory))
	written_before := header.change_count != 0
	next_bytes := size > 0 ? ([^]u8)(&palette_next_entries[0])[:size] : nil
	if written_before && count == palette_entry_count {
		kept_same := size == 0 || (len(palette_entries) >= count && string(next_bytes) == string(([^]u8)(&palette_entries[0])[:size]))
		if kept_same {
			return
		}
	}
	if !palette_kept_ensure(count) {
		return
	}
	// The grant can end while a line runs: the table is used only while
	// the console is the provider.
	if !palette_active() {
		return
	}
	// If the current shared table cannot hold all entries, allocate a new
	// memory object sized for count and give a read-only handle to the
	// compositor through the palette ring. Do not update palette_entries or
	// palette_entry_count until the replacement succeeds so a failed grow
	// retries cleanly on the next write.
	if expected_bytes > u64(len(palette_memory)) {
		needed_pages, pages_ok := palette_table.table_pages_for(u64(count))
		if !pages_ok {
			return
		}
		old_pages := u64(len(palette_memory)) / system.PAGE_SIZE
		new_pages := needed_pages
		if old_pages <= max(u64) / 2 {
			new_pages = max(needed_pages, old_pages * 2)
		}
		new_handle, create_status := system.memory_create(new_pages)
		if create_status != .Ok {
			return
		}
		new_addr, map_status := system.memory_map(new_handle, {.Write})
		if map_status != .Ok {
			system.close(new_handle)
			return
		}
		new_memory := ([^]u8)(new_addr)[:new_pages * system.PAGE_SIZE]
		copy(new_memory[:palette_table.ENTRIES_OFFSET], palette_memory[:palette_table.ENTRIES_OFFSET])
		if size > 0 {
			copy(new_memory[palette_table.ENTRIES_OFFSET:], next_bytes)
		}
		generation := header.change_count + 2
		new_header := (^palette_table.Header)(new_addr)
		new_header^ = {magic = palette_table.MAGIC, version = palette_table.VERSION, change_count = generation, entry_count = u32(count), byte_length = expected_bytes}
		given, give_status := system.give(palette_ring_handle, new_handle, {.Read})
		if give_status != .Ok {
			system.memory_unmap(new_addr)
			system.close(new_handle)
			return
		}
		system.lock(&palette_send_lock)
		sent := system.send(&palette_ring.completions, ring.Record{values = {0 = u64(palette_table.Outcome.Table_Replaced), 1 = u64(given), 2 = u64(len(new_memory))}})
		system.unlock(&palette_send_lock)
		if !sent {
			// Revoke the handle already transferred into the compositor so
			// neither the handle slot nor the memory object leaks.
			_, _ = system.handle_revoke(new_handle)
			system.memory_unmap(new_addr)
			system.close(new_handle)
			return
		}
		if size > 0 {
			copy(([^]u8)(&palette_entries[0])[:size], next_bytes)
		}
		palette_entry_count = count
		system.memory_unmap(raw_data(palette_memory))
		system.close(palette_table_handle)
		palette_table_handle = new_handle
		palette_memory = new_memory
		system.log_fact(.Info, Palette_Table_Written{entries = u64(count), table_generation = u64(generation)})
		return
	}
	if size > 0 {
		copy(([^]u8)(&palette_entries[0])[:size], next_bytes)
	}
	palette_entry_count = count
	intrinsics.atomic_add(&header.change_count, 1)
	if size > 0 {
		copy(palette_memory[palette_table.ENTRIES_OFFSET:], next_bytes)
	}
	header.entry_count = u32(count)
	header.byte_length = expected_bytes
	generation := intrinsics.atomic_add(&header.change_count, 1) + 1
	system.word_wake(&header.change_count, 64)
	system.log_fact(.Info, Palette_Table_Written{entries = u64(count), table_generation = u64(generation)})
}

// palette_answer sends the answer to a choice.
palette_answer :: proc "contextless" (tag: u32, outcome: palette_table.Outcome, kind: Kind, length: int) {
	if !palette_active() {
		return
	}
	system.lock(&palette_send_lock)
	system.send(&palette_ring.completions, ring.Record{tag = tag, values = {0 = u64(outcome), 1 = u64(palette_value_kind_of(kind)), 2 = u64(length)}})
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
	system.log_fact(.Info, Palette_Choice_Refused{refusal = value_kinds.text_field(sentence, CHOICE_REFUSAL_FIELD_BYTES)})
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
	if pending.count > 0 || ring.count(&output.ring.completions) > 0 {
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
			system.log_fact(.Info, Palette_Command_Refused{command_word = u64(record.kind)})
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
			// The panel opened: the strategy and the member in use of each
			// row can have changed with no line of the console. The thread
			// of the lines calls the getters, which wait for other
			// processes: this thread holds the keys and never waits for
			// one. The panel shows the table of now, and the marks of the
			// getters when they answer.
			palette_refresh_ask()
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

// palette_entry_named gives the copy of the entry that a record of the
// compositor names, when the index is inside the table of the console and
// the hash is the hash of the name of that entry: an index that names
// another entry, after the table changed, is not the entry that the panel
// showed. Each number is the number of another process.
palette_entry_named :: proc "contextless" (record: ring.Record) -> (entry: palette_table.Entry, ok: bool) {
	index, hash := record.values[1], record.values[2]
	system.lock(&palette_table_lock)
	if index < u64(palette_entry_count) && index < u64(len(palette_entries)) {
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
	system.log_fact(.Info, Palette_Runs_Line{}, text)
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
	if entry.kind == u8(palette_table.Entry_Kind.Provider_Setting) {
		// The line of a member of a row, and of a scheduling strategy, is
		// the help of its entry, which the console wrote itself.
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
		// A command whose last parameter a call may leave out takes the
		// choice with that parameter left out, as a line takes it.
		if found.optional_last && record.values[4] == u64(count - 1) {
			count -= 1
		}
		fits := count <= palette_table.PARAMETER_CAPACITY && palette_arguments_tag == record.tag && palette_arguments_bad != record.tag && record.values[4] == u64(count) && count > 0
		// A Text of the palette and a line of the console are UTF-8. A text
		// that a line cannot hold (an invalid sequence, which the
		// compositor already refuses, or a quote) is refused in words,
		// never changed in silence.
		outside_line := false
		no_member_name := false
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
			case found.parameters[index] == .Enum && argument.kind == .Text:
				// A member: its name after a ".". A text that is no name
				// of a member is refused in words; the line checks the
				// name against the enum when it runs.
				member_name := string(argument.text[:argument.length])
				if !module.enum_member_name_valid(member_name) {
					no_member_name = true
				}
				system.write_part(&writer, ".")
				system.write_part(&writer, member_name)
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
		if fits && no_member_name {
			palette_refuse(record.tag, "a member is a name in lower case: a letter, then letters, digits and _")
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
		// The line is the name and the parentheses: the template writes them.
		system.log_fact(.Info, Palette_Opens_In_Edit_Line{entry_name = value_kinds.text_field(name, ENTRY_NAME_FIELD_BYTES)})
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
	}
	// An Enum parameter of an export: the members of its enum.
	if found := palette_command_named(command_name); found != nil && parameter < u64(found.parameter_count) && found.parameters[parameter] == .Enum {
		return .Member
	}
	return .None
}

// palette_candidates_closed says if the candidates of a kind are the only
// values that a parameter takes: the strategies of the kernel and the
// members of an enum are; the processes that run, the modules and the
// grants are suggestions, since a line can name another one.
palette_candidates_closed :: proc "contextless" (kind: palette_table.Candidate_Kind) -> bool {
	switch kind {
	case .Strategy, .Member:
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
	case .Member:
		// The members of the enum of the parameter, as its module file
		// names them; a line writes each one after a ".".
		if found := palette_command_named(string(entry.name[:entry.name_length])); found != nil && record.values[3] < u64(found.parameter_count) {
			enum_index, _ := module.enum_detail_of(found.function.parameter_details[record.values[3]])
			if described, problem := module.enum_type(found.file, enum_index); problem == .None {
				for number in 0 ..< described.member_count {
					member, _ := module.enum_member(found.file, described, number)
					add(&candidates, &count, module.string_at(found.file, member.name_offset, member.name_count))
				}
			}
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
	system.log_fact(.Info, Palette_Candidates_Given{candidates = u64(count), parameter = record.values[3], entry_name = value_kinds.text_field(string(entry.name[:named ? int(entry.name_length) : 0]), ENTRY_NAME_FIELD_BYTES)})
	system.lock(&palette_send_lock)
	facts: u64 = palette_candidates_closed(kind) ? palette_table.CANDIDATES_CLOSED : 0
	system.send(&palette_ring.completions, ring.Record{tag = record.tag, values = {0 = u64(palette_table.Outcome.Candidates_Ready), 1 = u64(kind), 2 = u64(count), 3 = facts}})
	system.unlock(&palette_send_lock)
}

// palette_commands_add adds the two commands that the palette runs under
// a short name: each one is an export of a service.
palette_commands_add :: proc "contextless" () {
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
	case .Module:
		run_part = .Module
	case .Version:
		run_part = .Version
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
		system.log_fact(.Info, Manual_Page_Shown{})
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
		case .Enum:
			console_results.draw_member(&sink, value.file, value.detail, value.integer)
		case .Handle, .Table, .Bytes, .Stream, .Record_Input, .Record_Literal, .Member, .Function, .List, .Hash, .Boolean, .Record_With, .Module_Ref, .Recipe_Ref, .Follow_Ref, .Store_Ref, .Plan_Value, .Project_Value:
			// The panel has no drawer for these: the console window shows them.
			writer.fits = false
		}
		if !writer.fits {
			outcome = .Shown_In_Console
			writer = {buffer = area[:]} // No run goes to the panel.
		}
	}
	if outcome == .Shown_In_Console {
		system.log_fact(.Info, Palette_Result_In_Console{result_kind = value_kinds.text_field(kind_names[value.kind], RESULT_KIND_FIELD_BYTES)})
	} else {
		system.log_fact(.Info, Palette_Result_Given{result_lines = u64(writer.lines), result_kind = value_kinds.text_field(failed ? "an error" : kind_names[value.kind], RESULT_KIND_FIELD_BYTES)})
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
	system.log_fact(.Info, Provider_Ended{})
}
