package build

import "modus:contract/value_kinds"
import "modus:support/sentence"
import "core:strings"
import "core:testing"
import "modustool:foundation"

// The log facts of the windows of the system against the lines that they
// replaced (src/md/features/log_facts.md, "The migration"): compositor,
// console, terminal, edit, manual, settings, inspect, debugger_window,
// monitor and log. The fact types come from the extraction of the tool on
// the sources of each module: a host test does not depend on a build. Each
// sentence is compared with the parts of the old line written by
// sentence.format, at the edges of each field: the counts 0, 1 and the
// largest value of the field, the least and the largest i64, the longest
// text that a writer puts in a Text field, and a short one.

// The edges of an unsigned count, and of a field with a unit, which holds
// an i64.
@(private = "file")
COUNTS := [3]u64{0, 1, max(u64)}
@(private = "file")
UNIT_VALUES := [2]u64{0, u64(max(i64))}

// The longest name of a process or of a window, which a
// Module_Name_Field holds with its zero byte, and a short one.
@(private = "file")
name_longest :: proc() -> string {
	return strings.repeat("w", value_kinds.MODULE_NAME_FIELD_BYTES - 1, context.temp_allocator)
}
@(private = "file")
NAME_SHORT :: "console"

// The longest name of a palette entry (palette.NAME_CAPACITY).
@(private = "file")
entry_longest :: proc() -> string {
	return strings.repeat("e", 64, context.temp_allocator)
}

// The most bytes of the text of one Text field, which its field holds with
// a zero byte after it.
@(private = "file")
Text_Bytes_Most :: struct {
	name: string,
	most: u32,
}

// text_bytes_most_of gives the map of facts_expect_text_fields_last, in the
// memory of the test.
@(private = "file")
text_bytes_most_of :: proc(pairs: ..Text_Bytes_Most) -> map[string]u32 {
	most := make(map[string]u32, context.temp_allocator)
	for pair in pairs {
		most[pair.name] = pair.most
	}
	return most
}

// window_facts_file gives the module file of the fact types of one module
// of this group.
@(private = "file")
window_facts_file :: proc(t: ^testing.T, folder: string) -> (file: []u8, ok: bool) {
	return facts_file_of_folder(t, strings.concatenate({foundation.SYSTEM_MODULE_SOURCES, folder}, context.temp_allocator))
}

// The facts of monitor: the whole hash, the longest nickname and hash
// prefix, and short ones.
@(test)
the_facts_of_monitor_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := window_facts_file(t, "monitor")
	if !ok {
		return
	}
	hash: [32]u8
	for index in 0 ..< len(hash) {
		hash[index] = u8(255 - index)
	}
	nicknames := [2]string{strings.repeat("n", 23, context.temp_allocator), "importer"}
	prefixes := [2]string{"0123456789abcdef", "0"}
	for nickname in nicknames {
		for prefix in prefixes {
			facts_expect_line(t, fact_test_render(t, file, "monitor", "Disk_Process_Shown", {{"file_hash", hash}, {"hash_prefix", prefix}, {"nickname", nickname}}), line_of_before("monitor: the disk process ", nickname, ", hash prefix ", prefix, ", the file ", sentence.Hash{hash[:]}, ", from the root service"))
		}
	}
	facts_expect_text_fields_last(t, file, text_bytes_most_of({"hash_prefix", 16}, {"nickname", 23}))
}

// The facts of the window log: the counts 0, 1 and the largest; the size
// in KiB 0 and the largest i64.
@(test)
the_facts_of_log_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := window_facts_file(t, "log")
	if !ok {
		return
	}
	for count in COUNTS {
		other := max(u64) - count
		facts_expect_line(t, fact_test_render(t, file, "log", "Records_Not_Readable", {{"status_word", count}}), line_of_before("log: cannot read the records of the log: status ", count))
		facts_expect_line(t, fact_test_render(t, file, "log", "Window_Ready", {{"records", count}, {"gone_before_start", other}, {"lost", count}, {"processes", other}}), line_of_before("log: ok, ", count, " records, ", other, " gone before its start, ", count, " lost since, ", other, " processes"))
		for memory in UNIT_VALUES {
			facts_expect_line(t, fact_test_render(t, file, "log", "Log_Memory", {{"capacity", count}, {"memory", memory}}), line_of_before("log: the memory of the log: ", count, " records in ", sentence.Size{memory, .Kibibytes}))
		}
	}
}

// The facts of settings: each value name of each setting, the two words of
// the store, the time zones at their edges.
@(test)
the_facts_of_settings_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := window_facts_file(t, "settings")
	if !ok {
		return
	}
	render :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
		return fact_test_render(t, file, "settings_process", type_name, values)
	}
	// Two choices: the first value of each setting, and the longest one.
	Choice :: struct {
		font, subpixel_order, pointer_theme, grid_fit, keyboard_layout, appearance: string,
	}
	choices := [2]Choice{{"vector", "rgb", "owner", "on", "us", "auto"}, {"spleen", "none", "system", "off", "french", "light"}}
	stores := [2]string{"kept in the store", "NOT kept: the store refused"}
	for choice in choices {
		values := choice
		fields := [6]Fact_Test_Field{{"font", values.font}, {"subpixel_order", values.subpixel_order}, {"pointer_theme", values.pointer_theme}, {"grid_fit", values.grid_fit}, {"keyboard_layout", values.keyboard_layout}, {"appearance", values.appearance}}
		values_line := line_of_before("font ", values.font, ", subpixel order ", values.subpixel_order, ", pointer theme ", values.pointer_theme, ", grid fit ", values.grid_fit, ", keyboard layout ", values.keyboard_layout, ", appearance ", values.appearance)
		for store in stores {
			with_store := [7]Fact_Test_Field{fields[0], fields[1], fields[2], fields[3], fields[4], fields[5], {"store", store}}
			facts_expect_line(t, render(t, file, "Values_Changed", with_store[:]), line_of_before("settings: ", values_line, "; ", store))
		}
		facts_expect_line(t, render(t, file, "Values_Drawn", fields[:]), line_of_before("settings: drawn with ", values_line))
		facts_expect_line(t, render(t, file, "Window_Ready", fields[:]), line_of_before("settings: ok, ", values_line))
	}
	zones := [3]string{"-12:00", "+00:00", "+14:00"}
	for zone in zones {
		for store in stores {
			facts_expect_line(t, render(t, file, "Zone_Changed", {{"zone", zone}, {"store", store}}), line_of_before("settings: time zone ", zone, "; ", store))
		}
	}
	for count in COUNTS {
		facts_expect_line(t, render(t, file, "Records_Repeated", {{"records", count}}), line_of_before("settings: kept ", count, " records, one commit each"))
		facts_expect_line(t, render(t, file, "No_Settings_Page", {{"status_word", count}}), line_of_before("settings: no settings page: status ", count))
	}
	facts_expect_text_fields_last(t, file, text_bytes_most_of({"font", 6}, {"subpixel_order", 6}, {"pointer_theme", 6}, {"grid_fit", 6}, {"keyboard_layout", 6}, {"appearance", 6}, {"store", u32(len(stores[1]))}, {"zone", 6}))
}

// The facts of inspect: the counts at their edges, the longest process
// name and a short one, the two words of the state of the sample.
@(test)
the_facts_of_inspect_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := window_facts_file(t, "inspect")
	if !ok {
		return
	}
	render :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
		return fact_test_render(t, file, "inspect", type_name, values)
	}
	names := [2]string{name_longest(), NAME_SHORT}
	for count in COUNTS {
		other := max(u64) - count
		facts_expect_line(t, render(t, file, "Module_Writer_Refused", {{"base", count}, {"writer_word", other}}), line_of_before("inspect: the module record at ", count, " has the writer word ", other, ", which names no writer"))
		facts_expect_line(t, render(t, file, "Sample_Mixed", {{"slot", count}, {"dropped", other}}), line_of_before("inspect: a sample mixed two processes of slot ", count, ": dropped, ", other, " in all"))
		facts_expect_line(t, render(t, file, "Filter_Emptied", {{"processes", count}}), line_of_before("inspect: the list shows all ", count, " processes"))
		facts_expect_line(t, render(t, file, "Window_Ready", {{"processes", count}}), line_of_before("inspect: ok, ", count, " processes; up, down, letters: choose; space: freeze; tab: the bytes of its own memory"))
		for name in names {
			facts_expect_line(t, render(t, file, "Process_Counts", {{"mappings", count}, {"mapped_pages", other}, {"present_pages", count}, {"threads", other}, {"modules", count}, {"kernel_mapped_pages", other}, {"kernel_threads", count}, {"sampled_process", name}}), line_of_before("inspect: ", name, ": ", count, " mappings, ", other, " mapped pages, ", count, " with a frame, ", other, " threads, ", count, " modules; the kernel says ", other, " mapped pages and ", count, " threads"))
		}
	}
	for time in UNIT_VALUES {
		for name in names {
			facts_expect_line(t, render(t, file, "Sample_Cost", {{"elapsed", time}, {"kernel_entries", max(u64)}, {"sampled_process", name}}), line_of_before("inspect: one sample of ", name, " took ", time, " us and ", max(u64), " kernel entries"))
		}
		facts_expect_line(t, render(t, file, "Interface_Measured", {{"records", u64(0)}, {"damage_rectangles", max(u64)}, {"build_time", time}, {"difference_time", u64(1)}, {"draw_time", time}}), line_of_before("inspect: the interface: ", u64(0), " records; 20 frames with ", max(u64), " damage rectangles in all; the last frame: build ", time, " us, difference ", u64(1), " us, draw ", time, " us"))
	}
	states := [2]string{"frozen", "live"}
	for state in states {
		facts_expect_line(t, render(t, file, "Sample_State_Changed", {{"sample_state", state}}), line_of_before("inspect: the sample is ", state))
	}
	facts_expect_text_fields_last(t, file, text_bytes_most_of({"sampled_process", value_kinds.MODULE_NAME_FIELD_BYTES - 1}, {"sample_state", 6}))
}

// The facts of debugger_window: the threads, frames and breakpoints at the
// edges of an i64, each act of a thread, the longest procedure name.
@(test)
the_facts_of_debugger_window_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := window_facts_file(t, "debugger_window")
	if !ok {
		return
	}
	render :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
		return fact_test_render(t, file, "debugger_window", type_name, values)
	}
	names := [2]string{name_longest(), "debug_target"}
	for name in names {
		facts_expect_line(t, render(t, file, "Attached_To", {{"debugged_process", name}}), line_of_before("debugger_window: attached to ", name))
		facts_expect_line(t, render(t, file, "Detached_From", {{"debugged_process", name}}), line_of_before("debugger_window: detached from ", name))
	}
	facts_expect_line(t, render(t, file, "Act_On_Each_Thread", {{"act", "let each thread run"}}), line_of_before("debugger_window: let each thread run"))
	acts := [5]string{"held", "let run", "one instruction of", "one line of", "one line, over each call, of"}
	pendings := [2]string{"", ": it runs, and its stop comes later"}
	numbers := [3]i64{min(i64), 0, max(i64)}
	for number in numbers {
		for act in acts {
			for pending in pendings {
				facts_expect_line(t, render(t, file, "Act_On_Thread", {{"thread", signed_bits(number)}, {"act", act}, {"pending", pending}}), line_of_before("debugger_window: ", act, " the thread ", number, pending))
			}
		}
		facts_expect_line(t, render(t, file, "Thread_Chosen", {{"thread", signed_bits(number)}}), line_of_before("debugger_window: chose the thread ", number))
		facts_expect_line(t, render(t, file, "Breakpoint_Removed", {{"breakpoint", signed_bits(number)}}), line_of_before("debugger_window: removed the breakpoint ", number))
		procedure := strings.repeat("p", 79, context.temp_allocator)
		facts_expect_line(t, render(t, file, "Frame_Chosen", {{"frame", signed_bits(number)}, {"thread", signed_bits(-number)}, {"variables", u64(0)}, {"source_lines", max(u64)}, {"procedure", procedure}}), line_of_before("debugger_window: the frame ", number, " of the thread ", -number, ": ", procedure, ", ", u64(0), " variables, ", max(u64), " source lines"))
	}
	cards := [2]string{"the registers", "the variables"}
	for count in COUNTS {
		for card in cards {
			facts_expect_line(t, render(t, file, "Variables_Card_Shown", {{"rows", count}, {"card", card}}), line_of_before("debugger_window: the card of the variables shows ", card, ": ", count, " rows"))
		}
		facts_expect_line(t, render(t, file, "Window_Ready", {{"exports", count}}), line_of_before("debugger_window: ok, connected to the service debugger; ", count, " exports, each record with the size of its description"))
	}
	facts_expect_text_fields_last(t, file, text_bytes_most_of({"debugged_process", value_kinds.MODULE_NAME_FIELD_BYTES - 1}, {"act", u32(len(acts[4]))}, {"pending", u32(len(pendings[1]))}, {"procedure", 79}, {"card", 13}))
}

// The facts of manual: the counts and the times at their edges, each words
// of the entry of a module, the longest module name.
@(test)
the_facts_of_manual_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := window_facts_file(t, "manual")
	if !ok {
		return
	}
	render :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
		return fact_test_render(t, file, "manual", type_name, values)
	}
	entry_words := [2]string{"a module with an entry", "no entry"}
	names := [2]string{name_longest(), "calendar"}
	for count in COUNTS {
		other := max(u64) - count
		facts_expect_line(t, render(t, file, "Overview_Shown", {{"modules", count}, {"exports", other}, {"imports", count}, {"running_modules", other}}), line_of_before("manual: overview: ", count, " modules, ", other, " exports, ", count, " imports, ", other, " modules that run in processes"))
		for time in UNIT_VALUES {
			facts_expect_line(t, render(t, file, "Information_Measured", {{"modules", count}, {"exports", other}, {"list_time", time}, {"importers", count}, {"question_time", time}, {"problems", other}}), line_of_before("manual: information: ", count, " modules and ", other, " exports listed in ", time, " us; who imports calendar: ", count, " modules, in ", time, " us; ", other, " modules break a rule"))
		}
		facts_expect_line(t, render(t, file, "List_Cut", {{"shown", count}, {"modules", other}}), line_of_before("manual: the list shows ", count, " of the ", other, " modules of the boot image"))
		for words in entry_words {
			for name in names {
				facts_expect_line(t, render(t, file, "Module_Page_Shown", {{"exports", count}, {"rows", other}, {"entry_words", words}, {"module_name", name}}), line_of_before("manual: ", name, ": ", words, ", ", count, " exports, ", other, " rows"))
			}
		}
		facts_expect_line(t, render(t, file, "Window_Ready", {{"modules", count}, {"documented", other}}), line_of_before("manual: ok, ", count, " modules, ", other, " have their documentation"))
		facts_expect_line(t, render(t, file, "Link_Pages_Refused", {{"rule", count}}), line_of_before("manual: the link pages break the rule ", count, " of their format: not read"))
		facts_expect_line(t, render(t, file, "Link_Pages_Read", {{"pages", count}}), line_of_before("manual: ", count, " link pages"))
		facts_expect_line(t, render(t, file, "Markdown_Check_Failed", {{"bold", count}, {"italics", other}, {"code", count}, {"list_items", other}, {"links_that_open", count}, {"links", other}, {"marks_left", count}, {"widest", other}, {"text_width", count}}), line_of_before("manual: the Markdown of its page: FAILED: ", count, " bold, ", other, " italics, ", count, " code, ", other, " list items, ", count, " links that open a page of ", other, ", ", count, " marks left, the widest row ", other, " of ", count, " pixels"))
	}
	facts_expect_text_fields_last(t, file, text_bytes_most_of({"entry_words", u32(len(entry_words[0]))}, {"module_name", value_kinds.MODULE_NAME_FIELD_BYTES - 1}))
}

// The facts of edit: the sizes and the generations at their edges, each
// action, each problem of the walk of the versions.
@(test)
the_facts_of_edit_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := window_facts_file(t, "edit")
	if !ok {
		return
	}
	render :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
		return fact_test_render(t, file, "edit", type_name, values)
	}
	actions := [2]string{"undo", "redo"}
	problems := [4]string{"the text has no version yet", "the list of the versions is not in order", "no version is older", "no undo to go forward along"}
	replaced_words := [2]string{"", ", with invalid sequences replaced"}
	generations := [3]i64{min(i64), 0, max(i64)}
	for size in UNIT_VALUES {
		facts_expect_line(t, render(t, file, "Stored_Text_Too_Long", {{"text_capacity", size}}), line_of_before("edit: the text in the store has more than ", size, " bytes: the editor starts empty and keeps nothing"))
		facts_expect_line(t, render(t, file, "Cleaned_Text_Too_Long", {{"text_capacity", size}}), line_of_before("edit: the text in the store passes ", size, " bytes with its replacement characters: the editor starts empty and keeps nothing"))
		for count in COUNTS {
			facts_expect_line(t, render(t, file, "Text_Restored", {{"length", size}, {"lines", count}}), line_of_before("edit: restored a text of ", size, " bytes, ", count, " lines"))
			facts_expect_line(t, render(t, file, "Text_Restored_With_Replacements", {{"length", size}, {"lines", count}, {"replaced", max(u64) - count}}), line_of_before("edit: restored a text of ", size, " bytes, ", count, " lines, with ", max(u64) - count, " invalid sequences replaced by the replacement character"))
			facts_expect_line(t, render(t, file, "Selection_Made", {{"selected", size}, {"first", count}, {"last", max(u64) - count}, {"lines", count}}), line_of_before("edit: the selection has ", size, " bytes, from byte ", count, " to byte ", max(u64) - count, ", over ", count, " lines"))
		}
	}
	for action in actions {
		for generation in generations {
			facts_expect_line(t, render(t, file, "Too_Many_Versions", {{"versions", signed_bits(generation)}, {"listed_versions", u64(256)}, {"action", action}}), line_of_before("edit: ", action, ": the text has ", generation, " versions, more than the ", u64(256), " that the editor lists"))
			facts_expect_line(t, render(t, file, "Version_Too_Long", {{"generation", signed_bits(generation)}, {"action", action}}), line_of_before("edit: ", action, ": the version of generation ", generation, " is too long for the editor"))
			for words in replaced_words {
				facts_expect_line(t, render(t, file, "Version_Restored", {{"length", u64(max(i64))}, {"caret", max(u64)}, {"generation", signed_bits(generation)}, {"action", action}, {"replaced_words", words}}), line_of_before("edit: ", action, ": the text has ", u64(max(i64)), " bytes, the caret at byte ", max(u64), ", the version of generation ", generation, words))
			}
		}
		for problem in problems {
			facts_expect_line(t, render(t, file, "Walk_Refused", {{"action", action}, {"walk_problem", problem}}), line_of_before("edit: ", action, ": ", problem))
		}
	}
	facts_expect_text_fields_last(t, file, text_bytes_most_of({"action", 4}, {"replaced_words", u32(len(replaced_words[1]))}, {"walk_problem", u32(len(problems[1]))}))
}

// The facts of the terminal: the counts at their edges, the longest name of
// the process that it shows and a short one, each part of a scroll bar,
// each font of the fallback chain.
@(test)
the_facts_of_the_terminal_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := window_facts_file(t, "terminal")
	if !ok {
		return
	}
	render :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
		return fact_test_render(t, file, "terminal_process", type_name, values)
	}
	names := [2]string{name_longest(), "flood"}
	parts := [6]string{"no part", "the arrow up", "the arrow down", "the track above the thumb", "the track under the thumb", "the thumb"}
	scroll_acts := [2]string{"a press on", "a drag of"}
	fonts := [4]string{"b612", "b612_bold", "paper_mono", "paper_mono_semibold"}
	for name in names {
		facts_expect_line(t, render(t, file, "Drawer_Wake_Lost", {{"shown_process", name}}), line_of_before("terminal: ", name, ": the drawer slept to its deadline after a change of the view, and no wake came"))
		facts_expect_line(t, render(t, file, "Key_Serial_Refused", {{"shown_process", name}}), line_of_before("terminal: ", name, " named a key serial past the keys that it got: it is refused, and the next ones are counted"))
		facts_expect_line(t, render(t, file, "Code_Runs_Refused", {{"shown_process", name}}), line_of_before("terminal: ", name, " sent runs of code that do not fit their row: the row is drawn plain, its text whole"))
		facts_expect_line(t, render(t, file, "List_Row_Refused", {{"shown_process", name}}), line_of_before("terminal: ", name, " sent a row of a completion list whose icon names no icon: the row is refused"))
		facts_expect_line(t, render(t, file, "Interface_Text_In_Interface_Font", {{"shown_process", name}}), line_of_before("terminal: ", name, " draws its interface text in the interface font"))
		facts_expect_line(t, render(t, file, "Interface_Text_In_Cell_Font", {{"shown_process", name}}), line_of_before("terminal: ", name, " draws its interface text in the font of the cells"))
		facts_expect_line(t, render(t, file, "First_Key_Sent", {{"shown_process", name}}), line_of_before("terminal: the first key goes to ", name))
		facts_expect_line(t, render(t, file, "Wheel_Follows", {{"shown_process", name}}), line_of_before("terminal: the wheel moves the view of ", name, ": the view follows the last lines"))
		for count in COUNTS {
			other := max(u64) - count
			facts_expect_line(t, render(t, file, "Reader_Stuck", {{"records", count}, {"shown_process", name}}), line_of_before("terminal: ", name, ": the reader waits with ", count, " records in its ring, and read none since the last look"))
			facts_expect_line(t, render(t, file, "Record_Kind_Refused", {{"kind_word", count}, {"shown_process", name}}), line_of_before("terminal: ", name, " sent a record of the kind ", count, ", which names no record: it is refused"))
			facts_expect_line(t, render(t, file, "View_Stays", {{"line", count}, {"shown_process", name}}), line_of_before("terminal: the view stays at line ", count, ", ", name, " continues"))
			facts_expect_line(t, render(t, file, "Window_Ready", {{"ring_records", count}, {"shown_process", name}}), line_of_before("terminal: ok, ", name, " writes in a ring of ", count, " records"))
			facts_expect_line(t, render(t, file, "Keys_Read_Again", {{"lost_keys", count}, {"shown_process", name}}), line_of_before("terminal: ", name, " reads its keys again: ", count, " keys were lost"))
			facts_expect_line(t, render(t, file, "Keys_Not_Read", {{"queue_keys", count}, {"shown_process", name}}), line_of_before("terminal: ", name, " does not read its keys: its queue of ", count, " keys is full, and a new key is lost"))
			facts_expect_line(t, render(t, file, "Stopped_With_Lost_Keys", {{"lost_keys", count}, {"shown_process", name}}), line_of_before("terminal: ", name, " stopped and did not read its keys: ", count, " keys were lost"))
			facts_expect_line(t, render(t, file, "Stopped_After_Refused_Records", {{"refused", count}, {"shown_process", name}}), line_of_before("terminal: ", name, " stopped after ", count, " records whose kind names no record"))
			facts_expect_line(t, render(t, file, "Second_Measured", {{"lines_per_second", count}, {"records_per_second", other}, {"kernel_entries_per_million", count}, {"pictures_per_second", other}, {"shown_process", name}}), line_of_before("terminal: ", name, " wrote ", count, " lines in one second, ", other, " records, with ", count, " kernel entries for one million records; the terminal drew ", other, " pictures"))
			facts_expect_line(t, render(t, file, "List_Wheel_Moved", {{"first_row", count}, {"rows", other}, {"shown_process", name}}), line_of_before("terminal: the wheel moves the completion list of ", name, ": the rows from ", count, " of ", other))
			facts_expect_line(t, render(t, file, "List_Thumb_Dragged", {{"first_row", count}, {"rows", other}, {"shown_process", name}}), line_of_before("terminal: a drag of the thumb of the scroll bar of the completion list of ", name, ": the rows from ", count, " of ", other))
			facts_expect_line(t, render(t, file, "Cell_Replacement_Glyph", {{"character", count}, {"shown_process", name}}), line_of_before("terminal: ", name, " shows the character ", count, " in its cells as the replacement glyph: no font of its fallback chain has it"))
			facts_expect_line(t, render(t, file, "Wheel_At_Line", {{"line", count}, {"lines", other}, {"shown_process", name}}), line_of_before("terminal: the wheel moves the view of ", name, ": the view starts at line ", count, " of ", other))
			facts_expect_line(t, render(t, file, "Paste_Too_Large", {{"characters", count}, {"room", other}, {"shown_process", name}}), line_of_before("terminal: the paste of ", count, " characters is larger than the room of ", other, " keys of ", name, ": nothing is typed"))
			facts_expect_line(t, render(t, file, "Paste_Sent", {{"characters", count}, {"shown_process", name}}), line_of_before("terminal: a paste of ", count, " characters goes to ", name))
			for font in fonts {
				facts_expect_line(t, render(t, file, "Cell_From_Fallback_Font", {{"character", count}, {"fallback_font", font}, {"shown_process", name}}), line_of_before("terminal: ", name, " shows the character ", count, " in its cells, drawn by this process from the font ", font, " of its fallback chain"))
			}
			for part in parts {
				facts_expect_line(t, render(t, file, "List_Scroll_Pressed", {{"first_row", count}, {"rows", other}, {"scroll_part", part}, {"shown_process", name}}), line_of_before("terminal: a press on ", part, " of the scroll bar of the completion list of ", name, ": the rows from ", count, " of ", other))
				for act in scroll_acts {
					facts_expect_line(t, render(t, file, "Scroll_At_Line", {{"line", count}, {"lines", other}, {"scroll_act", act}, {"scroll_part", part}, {"shown_process", name}}), line_of_before("terminal: ", act, " ", part, " of the scroll bar of ", name, ": the view starts at line ", count, " of ", other))
				}
			}
		}
		for part in parts {
			for act in scroll_acts {
				facts_expect_line(t, render(t, file, "Scroll_Follows", {{"scroll_act", act}, {"scroll_part", part}, {"shown_process", name}}), line_of_before("terminal: ", act, " ", part, " of the scroll bar of ", name, ": the view follows the last lines"))
			}
		}
	}
	for count in COUNTS {
		facts_expect_line(t, render(t, file, "Paste_Without_Process", {{"characters", count}}), line_of_before("terminal: a paste of ", count, " characters, and no process to type them"))
	}
	facts_expect_text_fields_last(t, file, text_bytes_most_of({"shown_process", value_kinds.MODULE_NAME_FIELD_BYTES - 1}, {"scroll_part", u32(len(parts[3]))}, {"scroll_act", u32(len(scroll_acts[0]))}, {"fallback_font", u32(len(fonts[3]))}))
}

// The facts of the console: the counts and the times at their edges, the
// longest search, entry name, module name and problem of the history, each
// kind of a result.
@(test)
the_facts_of_the_console_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := window_facts_file(t, "console")
	if !ok {
		return
	}
	render :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
		return fact_test_render(t, file, "console", type_name, values)
	}
	hash: [32]u8
	for index in 0 ..< len(hash) {
		hash[index] = u8(index * 7)
	}
	searches := [2]string{strings.repeat("s", 64, context.temp_allocator), "leng"}
	problems := [2]string{"it has more lines than the history holds", "its hash is wrong"}
	kinds := [3]string{"None", "Integer", "an error"}
	names := [2]string{name_longest(), "sandboxed"}
	for count in COUNTS {
		other := max(u64) - count
		facts_expect_line(t, render(t, file, "Module_Writer_Refused", {{"base", count}, {"slot", other}, {"writer_word", count}}), line_of_before("console: process_modules: the module record at ", count, " of the process slot ", other, " has the writer word ", count, ", which names no writer"))
		for search in searches {
			facts_expect_line(t, render(t, file, "History_Search_Chose", {{"row", count}, {"rows", other}, {"search", search}}), line_of_before("console: the history search \"", search, "\" chooses the row ", count, " of ", other))
		}
		facts_expect_line(t, render(t, file, "History_Restored", {{"lines", count}}), line_of_before("console: the line history: ", count, " lines kept from before the stop"))
		facts_expect_line(t, render(t, file, "Waiting_Keys_Full", {{"capacity", count}}), line_of_before("console: ", count, " keys wait for the end of the line, and the console reads on to find an Escape: a new key is lost"))
		facts_expect_line(t, render(t, file, "Line_Ended_With_Lost_Keys", {{"lost_keys", count}}), line_of_before("console: the line ended: ", count, " keys were lost while it ran"))
		facts_expect_line(t, render(t, file, "Palette_Table_Written", {{"entries", count}, {"table_generation", other}}), line_of_before("console: the palette table has ", count, " entries, generation ", other))
		facts_expect_line(t, render(t, file, "Palette_Command_Refused", {{"command_word", count}}), line_of_before("console: the palette sent the command word ", count, ", which names no command: it is refused"))
		facts_expect_line(t, render(t, file, "Palette_Candidates_Given", {{"candidates", count}, {"parameter", other}, {"entry_name", entry_longest()}}), line_of_before("console: the palette gets ", count, " candidates for the parameter ", other, " of ", entry_longest()))
		for kind in kinds {
			facts_expect_line(t, render(t, file, "Palette_Result_Given", {{"result_lines", count}, {"result_kind", kind}}), line_of_before("console: the palette gets ", kind, ", ", count, " lines"))
		}
	}
	for size in UNIT_VALUES {
		for name in names {
			facts_expect_line(t, render(t, file, "Module_From_Memory", {{"size", size}, {"module_hash", hash}, {"module_name", name}}), line_of_before("console: ", name, " is a module from memory: ", size, " bytes, the hash ", sentence.Hash{hash[:]}))
		}
		facts_expect_line(t, render(t, file, "History_Too_Long", {{"limit", size}}), line_of_before("console: the line history has more than ", size, " bytes: the history starts empty"))
		facts_expect_line(t, render(t, file, "Escape_Stops_Line", {{"line_time", size}, {"waiting_keys", max(u64)}}), line_of_before("console: Escape stops the line after ", size, " ms; keys that wait: ", max(u64)))
	}
	for problem in problems {
		facts_expect_line(t, render(t, file, "History_Refused", {{"history_problem", problem}}), line_of_before("console: the line history is refused, ", problem, ": the history starts empty"))
	}
	for kind in kinds[:2] {
		facts_expect_line(t, render(t, file, "Palette_Result_In_Console", {{"result_kind", kind}}), line_of_before("console: the result of the palette choice is in the console: ", kind))
	}
	facts_expect_text_fields_last(t, file, text_bytes_most_of({"search", 64}, {"history_problem", u32(len(problems[0]))}, {"entry_name", 64}, {"result_kind", u32(len("an Integer"))}, {"module_name", value_kinds.MODULE_NAME_FIELD_BYTES - 1}))
}

// The facts of the compositor past the lines of its windows: the counts
// and the times at their edges, the longest title and a short one, the
// longest entry name of the palette, each word of each closed set.
@(test)
the_other_facts_of_the_compositor_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := window_facts_file(t, "compositor")
	if !ok {
		return
	}
	render :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
		return fact_test_render(t, file, "compositor", type_name, values)
	}
	windows := [2]string{name_longest(), "clock"}
	entries := [2]string{entry_longest(), "set font to spleen"}
	scroll_parts := [6]string{"no part", "the arrow up", "the arrow down", "the track above the thumb", "the track under the thumb", "the thumb"}
	refusal := strings.repeat("r", 96, context.temp_allocator)
	for window in windows {
		facts_expect_line(t, render(t, file, "Copy_Key_Sent", {{"window", window}}), line_of_before("compositor: the copy key goes to ", window))
		facts_expect_line(t, render(t, file, "Paste_Of_Empty_Clipboard", {{"window", window}}), line_of_before("compositor: a paste with an empty clipboard: nothing goes to ", window))
		facts_expect_line(t, render(t, file, "Paste_Refused", {{"window", window}}), line_of_before("compositor: the paste to ", window, " is refused by the kernel: nothing goes"))
		facts_expect_line(t, render(t, file, "Nothing_To_Copy", {{"window", window}}), line_of_before("compositor: ", window, " has nothing to copy"))
		facts_expect_line(t, render(t, file, "Clipboard_Emptied", {{"window", window}}), line_of_before("compositor: the clipboard is empty: ", window, " ended"))
		facts_expect_line(t, render(t, file, "Disk_Process_In_Menu", {{"hash_prefix", "0123456789abcdef"}, {"window", window}}), line_of_before("compositor: the menu of the windows shows the disk process ", window, " with the hash prefix ", "0123456789abcdef", ", from the root service"))
		facts_expect_line(t, render(t, file, "Act_Names_Refused", {{"window", window}}), line_of_before("compositor: the window ", window, " gave a set of act names that is refused: it has none now"))
		facts_expect_line(t, render(t, file, "Palette_Closes_Window", {{"window", window}}), line_of_before("compositor: the palette closes the window ", window))
		facts_expect_line(t, render(t, file, "No_Memory_For_Waiting_Records", {{"window", window}}), line_of_before("compositor: no memory for the records that wait for window ", window, ": each record that its full ring refuses is lost"))
		facts_expect_line(t, render(t, file, "Pointer_Shape_Asked", {{"shape_name", "resize_top_left_bottom_right"}, {"window", window}}), line_of_before("compositor: ", window, " asks for the pointer shape ", "resize_top_left_bottom_right", " over its surface"))
		facts_expect_line(t, render(t, file, "Resizable_Refused", {{"limits_problem", "a least size is below the least size of a resizable surface"}, {"window", window}}), line_of_before("compositor: window ", window, " asks to be resizable with limits that it cannot have: ", "a least size is below the least size of a resizable surface", "; it stays as it was. A window writes this line one time"))
		for size in UNIT_VALUES {
			facts_expect_line(t, render(t, file, "Paste_Sent", {{"length", size}, {"owner_window", windows[1]}, {"window", window}}), line_of_before("compositor: a paste of ", size, " bytes of text from ", windows[1], " goes to ", window))
			facts_expect_line(t, render(t, file, "Text_Copied", {{"length", size}, {"window", window}}), line_of_before("compositor: a copy of ", size, " bytes of text from ", window))
			facts_expect_line(t, render(t, file, "Window_Move_Measured", {{"frames", max(u64)}, {"time_per_frame", size}, {"longest_frame", u64(1)}, {"window", window}}), line_of_before("compositor: the move of ", window, ": ", max(u64), " frames, ", size, " us per frame, ", u64(1), " us the longest"))
		}
		for count in COUNTS {
			other := max(u64) - count
			facts_expect_line(t, render(t, file, "Window_Moved", {{"x", count}, {"y", other}, {"window", window}}), line_of_before("compositor: window ", window, " moved to ", count, ",", other))
			facts_expect_line(t, render(t, file, "Act_Names_Given", {{"act_names", count}, {"window", window}}), line_of_before("compositor: the window ", window, " gave ", count, " act names"))
			facts_expect_line(t, render(t, file, "Window_Resizable", {{"least_width", count}, {"least_height", other}, {"largest_width", count}, {"largest_height", other}, {"window", window}}), line_of_before("compositor: window ", window, " is resizable from ", count, "x", other, " to ", count, "x", other))
			facts_expect_line(t, render(t, file, "Surface_Not_Mapped", {{"width", count}, {"height", other}, {"window", window}}), line_of_before("compositor: window ", window, ": the surface of ", count, "x", other, " cannot be mapped; the window keeps its size"))
			facts_expect_line(t, render(t, file, "Window_Keeps_Size", {{"width", count}, {"height", other}, {"window", window}}), line_of_before("compositor: window ", window, " keeps its size ", count, "x", other))
			facts_expect_line(t, render(t, file, "Window_Resized", {{"old_width", count}, {"old_height", other}, {"width", other}, {"height", count}, {"window", window}}), line_of_before("compositor: window ", window, " resized from ", count, "x", other, " to ", other, "x", count))
			facts_expect_line(t, render(t, file, "Draw_Size_Asked", {{"width", count}, {"height", other}, {"window", window}}), line_of_before("compositor: window ", window, " asked to draw at ", count, "x", other))
			for entry in entries {
				facts_expect_line(t, render(t, file, "Palette_Goes_To_Window", {{"entry", entry}, {"window", window}}), line_of_before("compositor: the palette goes to ", entry, " in the window ", window, ", now in front"))
			}
		}
	}
	refusals := [2]string{"a list of viewers past its capacity, or with no capture face", "a second capture face"}
	for capture_refusal in refusals {
		facts_expect_line(t, render(t, file, "Capture_Command_Refused", {{"capture_refusal", capture_refusal}}), line_of_before("compositor: refused a command of the capture face: ", capture_refusal, "; the next refusals are counted only"))
	}
	capture_ends := [2]string{"the service closed it", "its service stopped"}
	yes_no := [2]string{"yes", "no"}
	for count in COUNTS {
		other := max(u64) - count
		facts_expect_line(t, render(t, file, "Capture_Face_Opened", {{"width", count}, {"height", other}}), line_of_before("compositor: the capture face is open: a copy of ", count, "x", other, " after each frame, and the mark of a viewer in the bar"))
		for capture_end in capture_ends {
			facts_expect_line(t, render(t, file, "Capture_Face_Ended", {{"pictures", count}, {"viewer_keys", other}, {"viewer_pointer_records", count}, {"refused", other}, {"capture_end", capture_end}}), line_of_before("compositor: the capture face ended (", capture_end, ") after ", count, " pictures, ", other, " keys and ", count, " pointer records of viewers, ", other, " refused commands"))
		}
		facts_expect_line(t, render(t, file, "Bar_In_Interface_Font", {{"start_width", count}, {"windows_width", other}, {"name_width", count}}), line_of_before("compositor: the bar is in the interface font: start ", count, " pixels, windows ", other, ", the widest name ", count))
		facts_expect_line(t, render(t, file, "Screen_Past_Budget", {{"width", count}, {"height", other}, {"needed_pages", count}, {"budget_pages", other}}), line_of_before("compositor: a screen of ", count, "x", other, " needs ", count, " pages, the budget holds ", other))
		facts_expect_line(t, render(t, file, "Compositor_Ready", {{"width", count}, {"height", other}}), line_of_before("compositor: ok ", count, "x", other))
		facts_expect_line(t, render(t, file, "Left_Button_Pressed", {{"x", count}, {"y", other}}), line_of_before("compositor: a press of the left button at ", count, ",", other))
		facts_expect_line(t, render(t, file, "Page_Flip_Refused", {{"screen_page", count}}), line_of_before("compositor: the display refused the page flip to the screen page ", count, ": each later frame is written into the screen page 0, which the display shows"))
		facts_expect_line(t, render(t, file, "Screen_Draw_Refused", {{"error_kind", count}, {"error_argument", other}}), line_of_before("compositor: the drawing module refused execute_draw_table_in_rectangles_18 (the error kind ", count, ", the argument ", other, "): the part of the screen is not drawn. The compositor writes this line one time"))
		facts_expect_line(t, render(t, file, "Provider_Table_Refused", {{"entry_index", count}, {"table_problem", "a text that is not UTF-8 or has a control character, or a name that is not ASCII"}}), line_of_before("compositor: the table of the palette provider is refused: ", "a text that is not UTF-8 or has a control character, or a name that is not ASCII", ", entry ", count, "; the palette lists the processes and the windows only"))
		facts_expect_line(t, render(t, file, "Palette_Candidates_Ready", {{"candidates", count}, {"field", other}, {"buttons_words", ", as a row of buttons"}}), line_of_before("compositor: the palette has ", count, " candidates for the field ", other, ", as a row of buttons"))
		facts_expect_line(t, render(t, file, "Palette_Candidates_Ready", {{"candidates", count}, {"field", other}, {"buttons_words", ""}}), line_of_before("compositor: the palette has ", count, " candidates for the field ", other))
		facts_expect_line(t, render(t, file, "Palette_Caret_Put", {{"field", count}, {"characters", other}}), line_of_before("compositor: a press puts the caret of the palette in the field ", count, ", after ", other, " characters"))
		facts_expect_line(t, render(t, file, "Palette_Wheel_Moved", {{"first_row", count}}), line_of_before("compositor: the wheel moves the rows of the palette: the rows from ", count))
		facts_expect_line(t, render(t, file, "Palette_Thumb_Dragged", {{"first_row", count}}), line_of_before("compositor: the scroll bar of the palette: a drag of the thumb, the rows from ", count))
		for part in scroll_parts {
			facts_expect_line(t, render(t, file, "Palette_Scroll_Pressed", {{"first_row", count}, {"scroll_part", part}}), line_of_before("compositor: the scroll bar of the palette: a press on ", part, ", the rows from ", count))
		}
		facts_expect_line(t, render(t, file, "Key_Measure_Losses", {{"lost_keys", count}, {"refused_serials", other}}), line_of_before("compositor: the measure of the keys to the screen: ", count, " keys left the table before a flip showed them, and ", other, " serials that a window named were past the keys that it got, since the start"))
		for entry in entries {
			facts_expect_line(t, render(t, file, "Palette_Sends_With_Arguments", {{"arguments", count}, {"sent_entry", entry}}), line_of_before("compositor: the palette sends ", entry, " with ", count, " arguments to the console"))
			facts_expect_line(t, render(t, file, "Palette_Setting_Row_Shown", {{"values", count}, {"entry", entry}}), line_of_before("compositor: the palette shows the setting ", entry, " as one row of ", count, " values"))
			facts_expect_line(t, render(t, file, "Palette_Field_Unit", {{"field", count}, {"entry", entry}, {"unit", "pages"}}), line_of_before("compositor: the field ", count, " of ", entry, " takes a number in", " pages"))
		}
		for time in UNIT_VALUES {
			facts_expect_line(t, render(t, file, "Pointer_Picture_Measured", {{"frames", count}, {"mean_time", time}, {"longest_time", u64(0)}}), line_of_before("compositor: the pointer picture in ", count, " frames: ", time, " ns for a frame in the mean, ", u64(0), " ns the longest"))
			facts_expect_line(t, render(t, file, "Arrow_Blend_Measured", {{"width", count}, {"height", other}, {"transparent_pixels", count}, {"pixels", other}, {"blend_time", time}, {"copy_time", u64(1)}}), line_of_before("compositor: the blend of the arrow of ", count, "x", other, " (", count, " of ", other, " pixels transparent): ", time, " ns; a copy of the same size: ", u64(1), " ns"))
			theme := strings.repeat("t", 32, context.temp_allocator)
			facts_expect_line(t, render(t, file, "Pointer_Theme_Validated", {{"shapes", count}, {"pictures", other}, {"size", time}, {"elapsed", time}, {"theme", theme}, {"license", "CC-BY-SA-4.0"}}), line_of_before("compositor: the pointer theme ", theme, " (", "CC-BY-SA-4.0", "): ", count, " shapes, ", other, " pictures, ", time, " bytes, validated in ", time, " us"))
		}
	}
	for word in yes_no {
		facts_expect_line(t, render(t, file, "Processor_Copy_Features", {{"erms", word}, {"fsrm", yes_no[1]}}), line_of_before("compositor: the processor: ERMS ", word, ", FSRM ", yes_no[1]))
	}
	inputs := [2]string{"a press", "a key"}
	for entry in entries {
		facts_expect_line(t, render(t, file, "Act_Without_Window", {{"entry", entry}}), line_of_before("compositor: no open window names what ", entry, " acts on: the palette does not go to it"))
		facts_expect_line(t, render(t, file, "Palette_Did", {{"sent_entry", entry}}), line_of_before("compositor: the palette did: ", entry))
		facts_expect_line(t, render(t, file, "Palette_Asks_To_Confirm", {{"entry", entry}}), line_of_before("compositor: the palette asks to confirm: ", entry))
		facts_expect_line(t, render(t, file, "Palette_Asks_For_Arguments", {{"entry", entry}}), line_of_before("compositor: the palette asks for the arguments of ", entry))
		facts_expect_line(t, render(t, file, "Palette_Opens_In_Console", {{"entry", entry}}), line_of_before("compositor: the palette opens ", entry, " in the console"))
		facts_expect_line(t, render(t, file, "Palette_Asks_For_Manual", {{"sent_entry", entry}}), line_of_before("compositor: the palette asks for the page of the manual of ", entry))
		facts_expect_line(t, render(t, file, "Palette_Sends", {{"sent_entry", entry}}), line_of_before("compositor: the palette sends ", entry, " to the console"))
		facts_expect_line(t, render(t, file, "Palette_Starts", {{"entry", entry}}), line_of_before("compositor: the palette starts ", entry))
		facts_expect_line(t, render(t, file, "Palette_Brings_To_Front", {{"entry", entry}}), line_of_before("compositor: the palette brings ", entry, " to the front"))
		facts_expect_line(t, render(t, file, "Palette_Chooses_Entry", {{"entry", entry}, {"kind_words", "close a window"}}), line_of_before("compositor: the palette chooses ", entry, " (", "close a window", ")"))
		value_name := strings.repeat("v", 24, context.temp_allocator)
		facts_expect_line(t, render(t, file, "Palette_Chooses_Value", {{"entry", entry}, {"value_name", value_name}}), line_of_before("compositor: the palette chooses the value ", value_name, " of ", entry))
		for input in inputs {
			facts_expect_line(t, render(t, file, "Palette_Sets_Value", {{"entry", entry}, {"value_name", value_name}, {"input", input}}), line_of_before("compositor: the palette sets ", entry, " to ", value_name, ", by ", input))
		}
	}
	facts_expect_line(t, render(t, file, "Palette_Key_Refused", {{"form_refusal", refusal}}), line_of_before("compositor: the palette refuses the key: ", refusal))
	facts_expect_line(t, render(t, file, "Palette_Arguments_Refused", {{"form_refusal", refusal}}), line_of_before("compositor: the palette refuses the arguments: ", refusal))
	result_kinds := [3]string{"an Integer", "a Record", "Bytes"}
	for kind in result_kinds {
		facts_expect_line(t, render(t, file, "Palette_Shows_Result", {{"result_kind", kind}}), line_of_before("compositor: the palette shows ", kind))
	}
	close_causes := [3]string{"the key escape", "the key super", "a press of the pointer outside it"}
	for cause in close_causes {
		facts_expect_line(t, render(t, file, "Palette_Closed", {{"close_cause", cause}}), line_of_before("compositor: the palette is closed by ", cause))
	}
	forms := [2]string{"light", "dark"}
	for form in forms {
		facts_expect_line(t, render(t, file, "Pointer_Form_In_Use", {{"pointer_form", form}}), line_of_before("compositor: the pointer form in use: ", form))
	}
	facts_expect_line(t, render(t, file, "Pointer_Theme_In_Use", {{"theme", "owner"}}), line_of_before("compositor: the pointer theme in use: ", "owner"))
	dates := [3]i64{min(i64), 0, max(i64)}
	for date in dates {
		facts_expect_line(t, render(t, file, "Bar_Local_Time", {{"date", signed_bits(date)}, {"local_time", "2026-11-20 14:05:00"}, {"zone", "+05:45"}}), line_of_before("compositor: the bar shows the local time ", "2026-11-20 14:05:00", " with the time zone ", "+05:45", ", at ", date, " s since 1970"))
	}
}

// Each fact type of the compositor ends with its Text fields, and each one
// holds the longest text of its writer and a zero byte.
@(test)
the_texts_of_the_compositor_facts_come_last_and_whole :: proc(t: ^testing.T) {
	file, ok := window_facts_file(t, "compositor")
	if !ok {
		return
	}
	most := make(map[string]u32, context.temp_allocator)
	most["window"] = value_kinds.MODULE_NAME_FIELD_BYTES - 1
	most["owner_window"] = value_kinds.MODULE_NAME_FIELD_BYTES - 1
	most["element"] = 32
	most["capture_refusal"] = u32(len("a list of viewers past its capacity, or with no capture face"))
	most["capture_end"] = u32(len("the service closed it"))
	most["hash_prefix"] = 16
	most["erms"] = 3
	most["fsrm"] = 3
	most["table_problem"] = u32(len("a text that is not UTF-8 or has a control character, or a name that is not ASCII"))
	most["entry"] = 64
	most["sent_entry"] = 64
	most["buttons_words"] = u32(len(", as a row of buttons"))
	most["result_kind"] = u32(len("an Integer"))
	most["value_name"] = 24
	most["input"] = u32(len("a press"))
	most["unit"] = u32(len("blocks"))
	most["form_refusal"] = 96
	most["kind_words"] = u32(len("close a window"))
	most["scroll_part"] = u32(len("the track above the thumb"))
	most["close_cause"] = u32(len("a press of the pointer outside it"))
	most["theme"] = 32
	most["license"] = 32
	most["pointer_form"] = u32(len("light"))
	most["shape_name"] = u32(len("resize_top_left_bottom_right"))
	most["limits_problem"] = u32(len("a least size is below the least size of a resizable surface"))
	most["local_time"] = 19
	most["zone"] = 6
	facts_expect_text_fields_last(t, file, most)
}
