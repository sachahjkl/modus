package build

import "modus:contract/cut_mark"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/pointer_pictures"
import "modus:contract/value_kinds"
import "modus:support/sentence"
import "core:fmt"
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
	}
	facts_expect_text_fields_last(t, file, text_bytes_most_of({"font", 6}, {"subpixel_order", 6}, {"pointer_theme", 6}, {"grid_fit", 6}, {"keyboard_layout", 6}, {"appearance", 6}, {"store", u32(len(stores[1]))}, {"zone", 6}, {"in_force", 5}, {"setting_value", 5}, {"local_time", 5}))
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
	facts_expect_text_fields_last(t, file, text_bytes_most_of({"debugged_process", value_kinds.MODULE_NAME_FIELD_BYTES - 1}, {"act", u32(len(acts[4]))}, {"pending", u32(len(pendings[1]))}, {"procedure", 79}, {"card", 13}, {"problem", u32(len("a record of the service debugger has another size than in this window"))}))
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
	facts_expect_text_fields_last(t, file, text_bytes_most_of({"shown_process", value_kinds.MODULE_NAME_FIELD_BYTES - 1}, {"scroll_part", u32(len(parts[3]))}, {"scroll_act", u32(len(scroll_acts[0]))}, {"fallback_font", u32(len(fonts[3]))}, {"failure", u32(len("no memory for the lines"))}))
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
	facts_expect_text_fields_last(t, file, text_bytes_most_of({"search", 64}, {"history_problem", u32(len(problems[0]))}, {"entry_name", 64}, {"result_kind", u32(len("an Integer"))}, {"module_name", value_kinds.MODULE_NAME_FIELD_BYTES - 1}, {"refusal", u32(len(CHOICE_REFUSAL_LONGEST))}, {"name_set", u32(len("the names of this console"))}))
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
	for setting_field in ([7]string{"font", "subpixel_order", "pointer_theme", "grid_fit", "keyboard_layout", "appearance", "in_force"}) {
		most[setting_field] = 6
	}
	most["candidate"] = 31
	most["theme_file"] = u32(len(pointer_pictures.RESOURCE_OF_THE_SYSTEM))
	most["typed"] = 64
	most["profile"] = u32(len("the processor profile"))
	most["profile_reason"] = u32(len("the system drives no GPU device"))
	facts_expect_text_fields_last(t, file, most)
}

// The longest sentence of a refusal of a choice of the palette by the
// console.
@(private = "file")
CHOICE_REFUSAL_LONGEST :: "a line of the console holds no quote and no invalid sequence of UTF-8 in a text"

// The words of a word of a contract enum, as a reader writes them: the
// name of its member, or its number for a word that names none.
@(private = "file")
contract_enum_words :: proc(which: value_kinds.Contract_Enum, word: u64) -> string {
	if words, named := module.contract_enum_member_words(which, word); named {
		return words
	}
	return line_of_before(word)
}

// The words of the status of a line: each member of op.Status, and a word
// that names no member.
@(private = "file")
status_words :: proc() -> []u64 {
	words := make([dynamic]u64, context.temp_allocator)
	for status in op.Status {
		append(&words, u64(status))
	}
	append(&words, max(u64))
	return words[:]
}

// One error record at the edges of its fields: a kind and a unit that
// name members and words that name none, the least and the largest i64.
@(private = "file")
Error_Record_Case :: struct {
	kind, unit:                               u64,
	operation, argument, value, limit, found: i64,
}

@(private = "file")
error_record_cases :: proc() -> []Error_Record_Case {
	cases := make([dynamic]Error_Record_Case, context.temp_allocator)
	append(&cases, Error_Record_Case{kind = 0, unit = 0})
	append(&cases, Error_Record_Case{kind = 1, unit = 1, operation = 3, argument = 2, value = 300, limit = 255, found = 0})
	append(&cases, Error_Record_Case{kind = max(u64), unit = max(u64), operation = min(i64), argument = max(i64), value = -1, limit = min(i64), found = max(i64)})
	return cases[:]
}

// The fields and the words of one error record, after the words of a
// module.
@(private = "file")
error_record_fields :: proc(record: Error_Record_Case) -> []Fact_Test_Field {
	fields := make([]Fact_Test_Field, 7, context.temp_allocator)
	fields[0] = {"kind", record.kind}
	fields[1] = {"unit", record.unit}
	fields[2] = {"operation", signed_bits(record.operation)}
	fields[3] = {"argument", signed_bits(record.argument)}
	fields[4] = {"value", signed_bits(record.value)}
	fields[5] = {"limit", signed_bits(record.limit)}
	fields[6] = {"found", signed_bits(record.found)}
	return fields
}

@(private = "file")
error_record_words :: proc(record: Error_Record_Case) -> string {
	return line_of_before("kind ", contract_enum_words(.Error_Kind, record.kind), ", unit ", contract_enum_words(.Error_Unit, record.unit), ", operation ", record.operation, ", argument ", record.argument, ", value ", record.value, ", limit ", record.limit, ", found ", record.found)
}

// The edges of a time in nanoseconds that a line wrote in microseconds
// with one decimal, cut: 0, under one tenth, 812 499 ns, the largest.
@(private = "file")
NANOSECOND_VALUES := [4]u64{0, 99, 812_499, max(u64)}

// The old form of such a time: n / 1000, a dot, n / 100 % 10, " us".
@(private = "file")
microseconds_of :: proc(nanoseconds: u64) -> string {
	return line_of_before(nanoseconds / 1000, ".", nanoseconds / 100 % 10, " us")
}

// A fact type with no field writes its template.
@(private = "file")
expect_no_field_fact :: proc(t: ^testing.T, file: []u8, package_name, type_name, sentence_of_before: string, loc := #caller_location) {
	facts_expect_line(t, fact_test_render(t, file, package_name, type_name, {}), sentence_of_before, loc)
}

// A status that a line wrote as its number is written by the name of its
// member: the sentence changes, as the design of the log facts decided. A
// word that names no member stays its number.
@(test)
a_status_of_the_windows_is_written_by_its_member :: proc(t: ^testing.T) {
	log_file, log_ok := window_facts_file(t, "log")
	settings_file, settings_ok := window_facts_file(t, "settings")
	if !log_ok || !settings_ok {
		return
	}
	for word in status_words() {
		words := contract_enum_words(.Status, word)
		facts_expect_line(t, fact_test_render(t, log_file, "log", "Records_Not_Readable", {{"status", word}}), line_of_before("log: cannot read the records of the log: status ", words))
		facts_expect_line(t, fact_test_render(t, settings_file, "settings_process", "No_Settings_Page", {{"status", word}}), line_of_before("settings: no settings page: status ", words))
	}
	testing.expect_value(t, contract_enum_words(.Status, u64(op.Status.Ok)), "Ok")
}

// Each error record of the windows is written in the fields form, after
// the words of its module.
@(test)
the_error_records_of_the_windows_are_written_as_fields :: proc(t: ^testing.T) {
	Error_Fact :: struct {
		folder, package_name, type_name, before: string,
	}
	facts := [?]Error_Fact {
		{"settings", "settings_process", "Store_Refused", "settings: the store did not keep the settings: "},
		{"console", "console", "History_Root_Refused", "console: the line history stays in memory: the root service refused: "},
		{"console", "console", "History_Read_Refused", "console: the line history cannot be read, and the history starts empty: "},
		{"console", "console", "History_Save_Refused", "console: the line history is not kept: "},
		{"edit", "edit", "Text_Read_Refused", "edit: the text cannot be read, and it is not kept: "},
		{"edit", "edit", "Text_Write_Refused", "edit: the storage service refused the text, and the changes after it are not kept: "},
		{"edit", "edit", "Versions_List_Refused", "edit: the versions cannot be listed: "},
		{"edit", "edit", "Version_Read_Refused", "edit: the version cannot be read: "},
		{"edit", "edit", "Version_Restore_Refused", "edit: the version cannot be restored: "},
	}
	for fact in facts {
		file, ok := window_facts_file(t, fact.folder)
		if !ok {
			continue
		}
		for record in error_record_cases() {
			facts_expect_line(t, fact_test_render(t, file, fact.package_name, fact.type_name, error_record_fields(record)), line_of_before(fact.before, error_record_words(record)))
		}
	}
}

// Each line of the windows with no value is a fact type with no field
// whose sentence is the line of before.
@(test)
the_lines_of_the_windows_with_no_value_write_the_lines_of_before :: proc(t: ^testing.T) {
	No_Field_Fact :: struct {
		folder, package_name, type_name, line: string,
	}
	facts := [?]No_Field_Fact {
		{"monitor", "monitor", "No_Inspect_Grant", "monitor: no grant to inspect the machine"},
		{"monitor", "monitor", "Window_Ready", "monitor: ok"},
		{"settings", "settings_process", "Page_Refused", "settings: the settings page holds a value that its setting does not have, or was never stable: the defaults"},
		{"inspect", "inspect", "Own_Memory_Shown", "inspect: the bytes of the memory of inspect"},
		{"manual", "manual", "No_Page_Before", "manual: back: no page before"},
		{"manual", "manual", "Back_To_Page_Before", "manual: back to the page before"},
		{"manual", "manual", "No_Link_That_Opens", "manual: the page has no link that opens"},
		{"manual", "manual", "No_Link_Pages", "manual: the boot image has no link pages"},
		{"manual", "manual", "Link_Pages_Hash_Wrong", "manual: the link pages do not have the hash of their entry: not read"},
		{"manual", "manual", "Markdown_Check_Passed", "manual: the Markdown of its page: bold, italics, code, list items and links that open a page; no mark is left and no row passes the window: as it must"},
		{"edit", "edit", "No_Store", "edit: no store: the text is not kept"},
		{"edit", "edit", "Stored_Text_Damaged", "edit: the text in the store is damaged: the editor starts empty, and the next change writes a new text"},
		{"edit", "edit", "New_Store", "edit: a new store: an empty text"},
		{"edit", "edit", "Nothing_Selected", "edit: nothing is selected"},
		{"edit", "edit", "Undo_Without_Version", "edit: undo: the text is not kept: it has no version"},
		{"edit", "edit", "Redo_Without_Version", "edit: redo: the text is not kept: it has no version"},
		{"edit", "edit", "Window_Ready", "edit: ok, the first picture is presented"},
		{"edit", "edit", "Text_Read_Unanswered", "edit: the text cannot be read: the storage service did not answer the call: the text is not kept"},
		{"edit", "edit", "Text_Write_Unanswered", "edit: the storage service refused the text: the storage service did not answer the call: the changes after it are not kept"},
		{"edit", "edit", "Versions_List_Unanswered", "edit: the versions cannot be listed: the storage service did not answer the call"},
		{"edit", "edit", "Version_Read_Unanswered", "edit: the version cannot be read: the storage service did not answer the call"},
		{"edit", "edit", "Version_Restore_Unanswered", "edit: the version cannot be restored: the storage service did not answer the call"},
		{"terminal", "terminal_process", "Draw_Table_Full", "terminal: the draw table is full: records are missing"},
		{"console", "console", "History_Root_Silent", "console: the line history stays in memory: the root service did not answer"},
		{"console", "console", "History_Storage_File_Missing", "console: the line history stays in memory: the boot image has no valid file of the storage service"},
		{"console", "console", "History_Region_Not_Mapped", "console: the line history stays in memory: the call ring or the call region does not map"},
		{"console", "console", "History_Damaged", "console: the line history is damaged in its store: the history starts empty"},
		{"console", "console", "History_Read_Unanswered", "console: the line history cannot be read: the storage service did not answer the read: the history starts empty"},
		{"console", "console", "No_History_Kept", "console: no line history kept: the history starts empty"},
		{"console", "console", "History_Store_Unreachable", "console: the line history is not kept: the store of the history is not reachable"},
		{"console", "console", "No_Random_Seed", "console: no random seed in the context"},
		{"console", "console", "No_Terminal", "console: no terminal"},
		{"console", "console", "Thread_Not_Started", "console: cannot start a thread"},
		{"console", "console", "Ready", "console: ready"},
		{"console", "console", "Line_Empty_After_Paste", "console: the line is empty again after a paste"},
		{"console", "console", "Provider_Refused", "console: the console is not the palette provider: the root service refused"},
		{"console", "console", "Provider_Without_Table", "console: the console is not the palette provider: no entry table"},
		{"console", "console", "Provider_Table_Not_Mapped", "console: the console is not the palette provider: the entry table cannot be mapped"},
		{"console", "console", "Provider_Without_Ring", "console: the console is not the palette provider: no ring"},
		{"console", "console", "Manual_Page_Shown", "console: the manual shows the page that the palette asked for"},
		{"console", "console", "Provider_Ended", "console: the console is no more the palette provider"},
		{"compositor", "compositor", "First_Viewer_Key", "compositor: the first key of a viewer of the remote display goes along the path of the keys"},
		{"compositor", "compositor", "Copy_Key_Without_Window", "compositor: the copy key with no window in front"},
		{"compositor", "compositor", "Paste_Key_Without_Window", "compositor: the paste key with no window in front"},
		{"compositor", "compositor", "Bar_In_Cell_Font", "compositor: the bar is in the font of the cells"},
		{"compositor", "compositor", "No_Memory", "compositor: no memory"},
		{"compositor", "compositor", "Two_Screen_Pages", "compositor: two screen pages: each frame reaches the screen whole, by a page flip"},
		{"compositor", "compositor", "One_Screen_Page", "compositor: one screen page: each frame is written into the screen page that the display shows"},
		{"compositor", "compositor", "No_Framebuffer", "compositor: no framebuffer"},
		{"compositor", "compositor", "No_Input_Or_Control_Ring", "compositor: no input ring or no control ring"},
		{"compositor", "compositor", "First_Frame", "compositor: first frame"},
		{"compositor", "compositor", "Start_Menu_Open", "compositor: the start menu is open"},
		{"compositor", "compositor", "Screen_Draw_Table_Full", "compositor: the draw table of the screen is full: records are missing"},
		{"compositor", "compositor", "Ranking_Thread_Not_Started", "compositor: cannot start the ranking thread: the palette lists nothing"},
		{"compositor", "compositor", "Palette_Entries_Changed", "compositor: the palette goes back to the search: the entries changed"},
		{"compositor", "compositor", "Chosen_Entry_Left", "compositor: the chosen entry of the palette left the list: the first entry is chosen, and Enter waits for a frame"},
		{"compositor", "compositor", "Palette_Provider_Refused", "compositor: the palette provider is refused: its ring or its table cannot be mapped"},
		{"compositor", "compositor", "Palette_Provider_Present", "compositor: the palette has a provider"},
		{"compositor", "compositor", "Palette_Provider_Absent", "compositor: the palette has no provider"},
		{"compositor", "compositor", "Palette_Manual_Shown", "compositor: the manual shows the page"},
		{"compositor", "compositor", "Palette_Result_In_Console", "compositor: the result of the palette is in the console"},
		{"compositor", "compositor", "Palette_Entry_Opened_In_Console", "compositor: the palette opened the entry in the console"},
		{"compositor", "compositor", "Palette_Shows_Error", "compositor: the palette shows an error"},
		{"compositor", "compositor", "Palette_Shows_Refusal", "compositor: the palette shows a refusal"},
		{"compositor", "compositor", "Palette_Shows_No_Result", "compositor: the palette shows no result"},
		{"compositor", "compositor", "Palette_Enter_Dropped", "compositor: the palette drops Enter: the choice changed and no frame showed it yet"},
		{"compositor", "compositor", "Palette_Open", "compositor: the palette is open"},
		{"compositor", "compositor", "Palette_No_Entry_To_Run", "compositor: the palette has no entry to run"},
		{"compositor", "compositor", "Palette_Back_To_Arguments", "compositor: the palette goes back to the arguments"},
		{"compositor", "compositor", "Palette_Back_To_Search", "compositor: the palette goes back to the search"},
		{"compositor", "compositor", "Palette_Tab_Waits", "compositor: Tab waits for the candidates of the field"},
		{"compositor", "compositor", "Palette_Draw_Table_Full", "compositor: the draw table of the palette is full: records are missing"},
		{"compositor", "compositor", "No_Pointer_Theme", "compositor: no pointer theme: the arrow of squares"},
		{"compositor", "compositor", "Palette_Listed_More", "compositor: the palette lists more rows than the log names"},
	}
	for fact in facts {
		file, ok := window_facts_file(t, fact.folder)
		if ok {
			expect_no_field_fact(t, file, fact.package_name, fact.type_name, fact.line)
		}
	}
}

// The other new facts of the windows against the lines of before, at the
// edges of their fields: the appearance of settings, the boot pass, the
// times with one decimal, the lists that a loop wrote, the closed sets of
// words.
@(test)
the_other_lines_of_the_windows_write_the_lines_of_before :: proc(t: ^testing.T) {
	settings_file, settings_ok := window_facts_file(t, "settings")
	if settings_ok {
		render :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
			return fact_test_render(t, file, "settings_process", type_name, values)
		}
		appearances := [2]string{"dark", "light"}
		for in_force in appearances {
			for setting_value in appearances {
				facts_expect_line(t, render(t, settings_file, "Appearance_By_Setting", {{"in_force", in_force}, {"setting_value", setting_value}}), line_of_before("settings: the appearance in force is ", in_force, ": the setting ", setting_value))
			}
			facts_expect_line(t, render(t, settings_file, "Appearance_Without_Date", {{"in_force", in_force}}), line_of_before("settings: the appearance in force is ", in_force, ": auto, and the system has no date"))
			seconds := [3]i64{min(i64), 0, max(i64)}
			for second in seconds {
				facts_expect_line(t, render(t, settings_file, "Appearance_By_Rule", {{"zone_offset", signed_bits(-second)}, {"date", signed_bits(second)}, {"in_force", in_force}, {"local_time", "01:04"}}), line_of_before("settings: the appearance in force is ", in_force, ": auto, light from 07:00 to 19:00 of the local time; the local time is ", "01:04", " with a zone of ", -second, " s, at ", second, " s since 1970"))
			}
		}
		Boot_Case :: struct {
			type_name, what: string,
		}
		boot_cases := [?]Boot_Case {
			{"Boot_Pass_Nothing_Kept", "no settings kept: the defaults"},
			{"Boot_Pass_Read_Refused", "the store gives no record (status not Ok): the defaults"},
			{"Boot_Pass_Kept", "the settings kept in the store"},
			{"Boot_Pass_Record_Refused_Defaults_Kept", "the record of the store is refused (another version, or a value that its setting does not have): the defaults, kept in its place"},
			{"Boot_Pass_Record_Refused_Defaults_Not_Kept", "the record of the store is refused (another version, or a value that its setting does not have): the defaults, NOT kept: the store refused"},
			{"Boot_Pass_No_Store", "no private store: the defaults"},
		}
		for boot in boot_cases {
			for elapsed in UNIT_VALUES {
				facts_expect_line(t, render(t, settings_file, boot.type_name, {{"elapsed", elapsed}, {"font", "spleen"}, {"subpixel_order", "none"}, {"pointer_theme", "system"}, {"grid_fit", "off"}, {"keyboard_layout", "french"}, {"appearance", "light"}}), line_of_before("settings: the boot pass: ", boot.what, ": font spleen, subpixel order none, pointer theme system, grid fit off, keyboard layout french, appearance light; in ", elapsed, " us"))
			}
		}
		facts_expect_line(t, render(t, settings_file, "Boot_Pass_Nothing_Kept", {{"elapsed", u64(12)}, {"font", "vector"}, {"subpixel_order", "rgb"}, {"pointer_theme", "owner"}, {"grid_fit", "on"}, {"keyboard_layout", "us"}, {"appearance", "auto"}}), "settings: the boot pass: no settings kept: the defaults: font vector, subpixel order rgb, pointer theme owner, grid fit on, keyboard layout us, appearance auto; in 12 us")
	}

	inspect_file, inspect_ok := window_facts_file(t, "inspect")
	if inspect_ok {
		names := [2]string{name_longest(), NAME_SHORT}
		for name in names {
			facts_expect_line(t, fact_test_render(t, inspect_file, "inspect", "Reports_Shown", {{"sampled_process", name}}), line_of_before("inspect: the reports of ", name))
		}
	}

	debugger_file, debugger_ok := window_facts_file(t, "debugger_window")
	if debugger_ok {
		problems := [3]string{"the boot image has no module debugger", "a record of the service debugger has another size than in this window", "the root service gave no connection to the service debugger"}
		for problem in problems {
			facts_expect_line(t, fact_test_render(t, debugger_file, "debugger_window", "Service_Not_Reached", {{"problem", problem}}), line_of_before("debugger_window: ", problem))
		}
	}

	terminal_file, terminal_ok := window_facts_file(t, "terminal")
	if terminal_ok {
		failures := [4]string{"no surface", "no memory for the lines", "no text region", "no thread"}
		for failure in failures {
			facts_expect_line(t, fact_test_render(t, terminal_file, "terminal_process", "Start_Failed", {{"failure", failure}}), line_of_before("terminal: ", failure))
		}
		names := [2]string{name_longest(), "flood"}
		for name in names {
			for outcome in op.Stop_Outcome {
				for count in COUNTS {
					facts_expect_line(t, fact_test_render(t, terminal_file, "terminal_process", "Stopped_Itself", {{"lines", count}, {"records", max(u64) - count}, {"cause", u64(op.Stop_Cause.Itself)}, {"outcome", u64(outcome)}, {"shown_process", name}}), line_of_before("terminal: ", name, " stopped: ", op.STOP_CAUSE_TEXTS[.Itself], ", ", op.STOP_OUTCOME_TEXTS[outcome], ", after ", count, " lines and ", max(u64) - count, " records"))
				}
			}
		}
	}

	console_file, console_ok := window_facts_file(t, "console")
	if console_ok {
		refusals := [4]string{"the commands changed: choose again", CHOICE_REFUSAL_LONGEST, "the arguments do not fit the command: type the line in the console", "the name of the module is no name"}
		for refusal in refusals {
			facts_expect_line(t, fact_test_render(t, console_file, "console", "Palette_Choice_Refused", {{"refusal", refusal}}), line_of_before("console: the palette choice is refused: ", refusal))
		}
		entries := [2]string{entry_longest(), "memory"}
		for entry in entries {
			facts_expect_line(t, fact_test_render(t, console_file, "console", "Palette_Opens_In_Edit_Line", {{"entry_name", entry}}), line_of_before("console: the palette opens ", entry, "()", " in the edit line"))
		}
		name_sets := [2]string{"the names of this console", "512 names of 128 bytes"}
		for nanoseconds in NANOSECOND_VALUES {
			for name_set in name_sets {
				facts_expect_line(t, fact_test_render(t, console_file, "console", "Completion_Key_Measured", {{"collect", nanoseconds}, {"rank", u64(0)}, {"rows_time", nanoseconds}, {"colors", u64(812_499)}, {"names", max(u64)}, {"batches", u64(8)}, {"keys", u64(64)}, {"name_set", name_set}}), line_of_before("console: one key with the completion list: the collect ", microseconds_of(nanoseconds), ", the rank ", microseconds_of(0), ", the rows ", microseconds_of(nanoseconds), ", the colors ", microseconds_of(812_499), ", over ", max(u64), " names (", name_set, ", the least of ", u64(8), " batches of ", u64(64), ")"))
			}
		}
	}

	compositor_file, compositor_ok := window_facts_file(t, "compositor")
	if compositor_ok {
		render :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
			return fact_test_render(t, file, "compositor", type_name, values)
		}
		windows := [2]string{name_longest(), "console"}
		for nanoseconds in NANOSECOND_VALUES {
			other := NANOSECOND_VALUES[3] - nanoseconds
			facts_expect_line(t, render(t, compositor_file, "Bar_Measured_Without_Interface_Font", {{"cells_font_time", nanoseconds}}), line_of_before("compositor: the bar and the start menu, built and drawn (the least of 20): the font of the cells ", microseconds_of(nanoseconds), "; no interface font"))
			facts_expect_line(t, render(t, compositor_file, "Bar_Measured", {{"cells_font_time", nanoseconds}, {"interface_font_time", other}}), line_of_before("compositor: the bar and the start menu, built and drawn (the least of 20): the font of the cells ", microseconds_of(nanoseconds), ", the interface font ", microseconds_of(other)))
			facts_expect_line(t, render(t, compositor_file, "Title_Bar_Measured", {{"width", u64(1920)}, {"one_color_time", nanoseconds}, {"mix_time", other}, {"row_copy_time", u64(0)}}), line_of_before("compositor: a title bar of ", u64(1920), " pixels: one color ", microseconds_of(nanoseconds), ", a mix for each pixel ", microseconds_of(other), ", one row of colors then copies ", microseconds_of(0)))
			facts_expect_line(t, render(t, compositor_file, "Palette_Open_Measured", {{"frames", max(u64)}, {"frame_time", nanoseconds}, {"longest_list_time", other}, {"adopted_lists", u64(0)}, {"same_lists", u64(1)}}), line_of_before("compositor: the palette was open for ", max(u64), " frames, ", microseconds_of(nanoseconds), " per frame; the longest list of the ranking thread ", microseconds_of(other), "; ", u64(0), " lists adopted, ", u64(1), " of them the same"))
			facts_expect_line(t, render(t, compositor_file, "Frame_Time_Measured", {{"least", nanoseconds}, {"median", other}, {"frames", u64(64)}}), line_of_before("compositor: measure: the time of a frame, from the first record that the compositor reads to the flip: least ", microseconds_of(nanoseconds), ", median ", microseconds_of(other), ", over ", u64(64), " frames"))
			facts_expect_line(t, render(t, compositor_file, "Key_Time_Measured", {{"least", nanoseconds}, {"median", other}, {"keys", u64(16)}}), line_of_before("compositor: measure: the time of a key to the screen, from its record in the input service to the flip that shows it: least ", microseconds_of(nanoseconds), ", median ", microseconds_of(other), ", over ", u64(16), " keys"))
			for window in windows {
				facts_expect_line(t, render(t, compositor_file, "Window_Start_Measured", {{"start_time", nanoseconds}, {"window", window}}), line_of_before("compositor: measure: the start of the window ", window, ", from Process_Start to its first frame: ", microseconds_of(nanoseconds)))
			}
		}
		for count in COUNTS {
			other := max(u64) - count
			for window in windows {
				facts_expect_line(t, render(t, compositor_file, "Window_Listed", {{"place", count}, {"windows", other}, {"window", window}}), line_of_before("compositor: windows: ", window, ", the window ", count, " of ", other))
			}
			for elapsed in UNIT_VALUES {
				facts_expect_line(t, render(t, compositor_file, "Full_Frame_Measured", {{"width", count}, {"height", other}, {"windows", count}, {"elapsed", elapsed}}), line_of_before("compositor: a full frame of ", count, "x", other, " with ", count, " windows in ", elapsed, " us"))
			}
			facts_expect_line(t, render(t, compositor_file, "Settings_Changed", {{"windows", count}, {"font", "spleen"}, {"subpixel_order", "rgb"}, {"pointer_theme", "system"}, {"grid_fit", "off"}, {"keyboard_layout", "french"}, {"appearance", "auto"}, {"in_force", "light"}, {"zone", "+05:45"}}), line_of_before("compositor: the settings changed: font spleen, subpixel order rgb, pointer theme system, grid fit off, keyboard layout french, appearance auto; the appearance in force light; the time zone +05:45; ", count, " windows draw again"))
			candidates := [2]string{strings.repeat("c", 31, context.temp_allocator), "round_robin"}
			for candidate in candidates {
				facts_expect_line(t, render(t, compositor_file, "Palette_Takes_Candidate", {{"candidate", candidate}}), line_of_before("compositor: the palette takes the candidate ", candidate))
				facts_expect_line(t, render(t, compositor_file, "Palette_Button_Pressed", {{"field", count}, {"candidate", candidate}}), line_of_before("compositor: a press takes the button ", candidate, " of the field ", count))
			}
			typed := [3]string{"", "mon", strings.repeat("m", 64, context.temp_allocator)}
			for text in typed {
				facts_expect_line(t, render(t, compositor_file, "Palette_Listed", {{"matched", count}, {"entries", other}, {"typed", text}}), line_of_before("compositor: the palette lists ", count, " of ", other, " for \"", text, "\""))
			}
			facts_expect_line(t, render(t, compositor_file, "Palette_Listed_Row", {{"row", count}, {"entry", entry_longest()}, {"kind_words", "close a window"}}), line_of_before("compositor: the palette lists the row ", count, ": ", entry_longest(), " (", "close a window", ")"))
		}
		profiles := [2]string{"the processor profile", "the GPU profile"}
		reasons := [2]string{"the system drives no GPU device", "the system drives a GPU device"}
		for profile in profiles {
			for reason in reasons {
				facts_expect_line(t, render(t, compositor_file, "Quality_Profile_Chosen", {{"profile", profile}, {"profile_reason", reason}}), line_of_before("compositor: the quality profile is ", profile, ": ", reason))
			}
		}
		// The line that quality_lines_check reads, whole.
		facts_expect_line(t, render(t, compositor_file, "Quality_Profile_Chosen", {{"profile", "the processor profile"}, {"profile_reason", "the system drives no GPU device"}}), "compositor: the quality profile is the processor profile: the system drives no GPU device")
		facts_expect_line(t, render(t, compositor_file, "Full_Frame_Measured", {{"width", u64(1920)}, {"height", u64(1080)}, {"windows", u64(17)}, {"elapsed", u64(2272)}}), "compositor: a full frame of 1920x1080 with 17 windows in 2272 us")
	}
}

// views_values gives the values of a fact with text views: the fixed
// record, its views filled from texts in their order, and the out-of-line
// area of the long texts, as system.log_fact writes them: a text of at
// most 12 bytes in its view, a longer one in the area, and a text that the
// area has no room for cut with the cut mark.
@(private = "file")
views_values :: proc(fixed: []u8, texts: []string) -> []u8 {
	record_size := len(fixed)
	values := make([]u8, record_size + op.LOG_FACT_TEXT_AREA_BYTES_MOST, context.temp_allocator)
	copy(values, fixed)
	views_start := record_size - len(texts) * value_kinds.TEXT_VIEW_BYTES
	area := values[record_size:]
	area_count := 0
	for text, index in texts {
		view := values[views_start + index * value_kinds.TEXT_VIEW_BYTES:][:value_kinds.TEXT_VIEW_BYTES]
		length := len(text)
		if length <= value_kinds.TEXT_VIEW_INLINE_BYTES_MOST {
			copy(view[4:], text)
		} else {
			room := area[area_count:]
			length = copy(room, text)
			if length < len(text) {
				length, _, _ = cut_mark.apply(room, length, len(text) - length)
			}
			if length > value_kinds.TEXT_VIEW_INLINE_BYTES_MOST {
				copy(view[4:8], room[:value_kinds.TEXT_VIEW_PREFIX_BYTES])
				offset := u64(area_count)
				for place in 0 ..< 8 {
					view[8 + place] = u8(offset >> (8 * u64(place)))
				}
				area_count += length
			} else {
				for &byte_value in room[:length] {
					byte_value = 0
				}
				inline: [value_kinds.TEXT_VIEW_INLINE_BYTES_MOST]u8
				kept := copy(inline[:], text)
				length, _, _ = cut_mark.apply(inline[:], kept, len(text) - kept)
				copy(view[4:], inline[:length])
			}
		}
		view[0], view[1], view[2], view[3] = u8(length), u8(length >> 8), u8(length >> 16), u8(length >> 24)
	}
	return values[:record_size + area_count]
}

// views_text_written gives the text that a view of a fact holds after the
// write: the text, or the text cut with the cut mark.
@(private = "file")
views_text_written :: proc(values: []u8, record_size, view_index, view_count: int) -> string {
	start := record_size - (view_count - view_index) * value_kinds.TEXT_VIEW_BYTES
	text, ok := value_kinds.text_view_read(values[start:][:value_kinds.TEXT_VIEW_BYTES], values[record_size:])
	return ok ? strings.clone(string(text), context.temp_allocator) : "<a view that does not read>"
}

// views_render gives the sentence of a fact with text views: its fixed
// fields, then its texts in the order of its views. The sentence is the
// one of the texts as written, and written is that text for each view.
@(private = "file")
views_render :: proc(t: ^testing.T, file: []u8, package_name, type_name: string, values: []Fact_Test_Field, texts: []string) -> (rendered_sentence: string, written: []string) {
	key, fixed, made := fact_test_record(t, file, package_name, type_name, values)
	if !made {
		return "", nil
	}
	whole := views_values(fixed, texts)
	written = make([]string, len(texts), context.temp_allocator)
	for index in 0 ..< len(texts) {
		written[index] = views_text_written(whole, len(fixed), index, len(texts))
	}
	rendered := false
	rendered_sentence, rendered = fact_values_render(file, key, whole)
	testing.expectf(t, rendered, "the fact %s.%s with texts %v is refused", package_name, type_name, texts)
	return
}

// The texts of the views at their edges: empty, 12 bytes (whole in the
// view), 13 (the first in the area), a long one, and one past the area
// bound, which the write cuts with the mark.
@(private = "file")
view_texts :: proc() -> []string {
	texts := make([]string, 5, context.temp_allocator)
	texts[0] = ""
	texts[1] = strings.repeat("a", 12, context.temp_allocator)
	texts[2] = strings.repeat("b", 13, context.temp_allocator)
	texts[3] = "fault::three + 0x8 in fault (src/modules/demonstrations/fault/main.odin:15)"
	texts[4] = strings.repeat("z", op.LOG_FACT_TEXT_AREA_BYTES_MOST + 100, context.temp_allocator)
	return texts
}

// A text of no small bound is a text view, at its edges: each sentence is
// the line of before with the text whole, and the text past the area
// bound is cut, with the cut mark, never whole and never lost.
@(test)
the_texts_of_the_windows_are_views :: proc(t: ^testing.T) {
	texts := view_texts()
	longest := texts[len(texts) - 1]
	// The cut: the text past the bound is written cut, shorter than the
	// area, its start kept.
	{
		file, ok := window_facts_file(t, "console")
		if ok {
			_, written := views_render(t, file, "console", "Line_Entered", nil, {longest})
			if len(written) == 1 {
				testing.expect(t, written[0] != longest && len(written[0]) <= op.LOG_FACT_TEXT_AREA_BYTES_MOST && strings.has_prefix(written[0], longest[:op.LOG_FACT_TEXT_AREA_BYTES_MOST / 2]))
			}
		}
	}
	console_file, console_ok := window_facts_file(t, "console")
	debugger_file, debugger_ok := window_facts_file(t, "debugger_window")
	manual_file, manual_ok := window_facts_file(t, "manual")
	compositor_file, compositor_ok := window_facts_file(t, "compositor")
	inspect_file, inspect_ok := window_facts_file(t, "inspect")
	for text in texts {
		if console_ok {
			sentence_text, written := views_render(t, console_file, "console", "Line_Entered", nil, {text})
			facts_expect_line(t, sentence_text, line_of_before("> ", written[0]))
			sentence_text, written = views_render(t, console_file, "console", "Completion_Gave_Line", nil, {text})
			facts_expect_line(t, sentence_text, line_of_before("console: the completion gave the line ", written[0]))
			sentence_text, written = views_render(t, console_file, "console", "History_Search_Gave_Line", nil, {text})
			facts_expect_line(t, sentence_text, line_of_before("console: the history search gave the line ", written[0]))
			sentence_text, written = views_render(t, console_file, "console", "Line_After_Paste", nil, {text})
			facts_expect_line(t, sentence_text, line_of_before("console: the line shows \"", written[0], "\" after a paste"))
			sentence_text, written = views_render(t, console_file, "console", "Palette_Runs_Line", nil, {text})
			facts_expect_line(t, sentence_text, line_of_before("console: the palette runs ", written[0]))
			for count in COUNTS {
				sentence_text, written = views_render(t, console_file, "console", "Completion_List_Opened", {{"matched_names", count}, {"names", max(u64) - count}, {"longest_ranking", u64(max(i64))}, {"rankings", count}, {"code_runs", u64(0)}}, {text, "length"})
				facts_expect_line(t, sentence_text, line_of_before("console: the completion list opens by Tab: ", count, " names of ", max(u64) - count, " match \"", written[0], "\", the first is ", written[1], "; one ranking takes ", u64(max(i64)), " us at most, over ", count, " keys; its first row has ", u64(0), " runs of code"))
			}
		}
		if debugger_ok {
			sentence_text, written := views_render(t, debugger_file, "debugger_window", "Breakpoint_Placed", nil, {text})
			facts_expect_line(t, sentence_text, line_of_before("debugger_window: a breakpoint at ", written[0]))
			for size in UNIT_VALUES {
				sentence_text, written = views_render(t, debugger_file, "debugger_window", "Watch_Placed", {{"watch_length", size}}, {text})
				facts_expect_line(t, sentence_text, line_of_before("debugger_window: a watch of ", size, " bytes at ", written[0]))
			}
			for count in COUNTS {
				sentence_text, written = views_render(t, debugger_file, "debugger_window", "Memory_Shown", {{"rows", count}}, {text})
				facts_expect_line(t, sentence_text, line_of_before("debugger_window: the memory at ", written[0], ": ", count, " rows of 16 bytes"))
			}
		}
		if manual_ok {
			for count in COUNTS {
				sentence_text, written := views_render(t, manual_file, "manual", "Link_Page_Shown", {{"rows", count}}, {text, "Text view"})
				facts_expect_line(t, sentence_text, line_of_before("manual: the page ", written[0], ": ", written[1], ", ", count, " rows"))
			}
			sentence_text, written := views_render(t, manual_file, "manual", "Link_Opened", nil, {"the glossary", text})
			facts_expect_line(t, sentence_text, line_of_before("manual: the link ", written[0], " opens ", written[1]))
			sentence_text, written = views_render(t, manual_file, "manual", "Link_Focused", nil, {text, "term:text-view"})
			facts_expect_line(t, sentence_text, line_of_before("manual: the focus is on the link ", written[0], " to ", written[1]))
		}
		if compositor_ok {
			for count in COUNTS {
				sentence_text, written := views_render(t, compositor_file, "compositor", "Palette_Field_Shows", {{"field", count}, {"entry", entry_longest()}}, {text})
				facts_expect_line(t, sentence_text, line_of_before("compositor: the field ", count, " of ", entry_longest(), " shows \"", written[0], "\""))
			}
		}
		if inspect_ok {
			for count in COUNTS {
				sentence_text, written := views_render(t, inspect_file, "inspect", "Stack_Frame", {{"frame", count}, {"sampled_process", "fault"}}, {text})
				facts_expect_line(t, sentence_text, line_of_before("inspect: ", "fault", ", the frame ", count, " of the stack: ", written[0]))
			}
		}
	}
	// A text that the write keeps whole renders whole.
	if console_ok {
		sentence_text, _ := views_render(t, console_file, "console", "Line_Entered", nil, {"length(\"kept across a stop\")"})
		facts_expect_line(t, sentence_text, "> length(\"kept across a stop\")")
	}
}

// The last lines of the windows with new kinds: the stop of a terminal
// for each cause but itself, the copy measures in tenths, the fault of
// inspect in hexadecimal with no zero before the first digit, the problem
// of a pointer theme by the names of its members.
@(test)
the_last_lines_of_the_windows_write_their_fields :: proc(t: ^testing.T) {
	terminal_file, terminal_ok := window_facts_file(t, "terminal")
	if terminal_ok {
		for cause in op.Stop_Cause {
			if cause == .Itself {
				continue
			}
			for count in COUNTS {
				facts_expect_line(t, fact_test_render(t, terminal_file, "terminal_process", "Stopped_Without_Outcome", {{"lines", count}, {"records", max(u64) - count}, {"cause", u64(cause)}, {"shown_process", "flood"}}), line_of_before("terminal: ", "flood", " stopped: ", op.STOP_CAUSE_TEXTS[cause], ", after ", count, " lines and ", max(u64) - count, " records"))
			}
		}
		// A word of a cause that names no member is written as its number.
		facts_expect_line(t, fact_test_render(t, terminal_file, "terminal_process", "Stopped_Without_Outcome", {{"lines", u64(1)}, {"records", u64(2)}, {"cause", max(u64)}, {"shown_process", "flood"}}), line_of_before("terminal: flood stopped: ", max(u64), ", after ", u64(1), " lines and ", u64(2), " records"))
	}

	compositor_file, compositor_ok := window_facts_file(t, "compositor")
	if compositor_ok {
		Copy_Form :: struct {
			type_name, words: string,
		}
		forms := [?]Copy_Form {
			{"Copy_Aligned_Measured", "compositor: copy_bytes_without_overlap, ns for 8 64 512 4096 65536 3145600 bytes, aligned:"},
			{"Copy_Unaligned_Measured", "compositor: copy_bytes_without_overlap, not aligned:"},
			{"Loop_Aligned_Measured", "compositor: a loop of 16 bytes, aligned:"},
			{"Loop_Unaligned_Measured", "compositor: a loop of 16 bytes, not aligned:"},
			{"Fill_Aligned_Measured", "compositor: fill_bytes_with_value, aligned:"},
			{"Fill_Unaligned_Measured", "compositor: fill_bytes_with_value, not aligned:"},
		}
		// The old line wrote each value as value / 10, a dot, value % 10.
		tenths := [6]u64{0, 9, 10, 123, 999_999, u64(max(i64))}
		for form in forms {
			old := strings.builder_make(context.temp_allocator)
			strings.write_string(&old, form.words)
			for value in tenths {
				strings.write_string(&old, line_of_before(" ", value / 10, ".", value % 10))
			}
			facts_expect_line(t, fact_test_render(t, compositor_file, "compositor", form.type_name, {{"time_8", tenths[0]}, {"time_64", tenths[1]}, {"time_512", tenths[2]}, {"time_4096", tenths[3]}, {"time_65536", tenths[4]}, {"time_3145600", tenths[5]}}), strings.to_string(old))
		}
		// The problem of a pointer theme: each part, each rule, the largest
		// index and values, and words that name no member.
		files := [2]string{pointer_pictures.RESOURCE_OF_THE_OWNER, pointer_pictures.RESOURCE_OF_THE_SYSTEM}
		for theme_file in files {
			for part in pointer_pictures.Part {
				for kind in pointer_pictures.Problem_Kind {
					field := pointer_pictures.Field.Hot_Spot_X
					facts_expect_line(t, fact_test_render(t, compositor_file, "compositor", "Pointer_Theme_Refused", {{"problem_kind", u64(kind)}, {"theme_part", u64(part)}, {"theme_field", u64(field)}, {"place_index", u64(3)}, {"value", max(u64)}, {"limit", u64(0)}, {"theme_file", theme_file}}), line_of_before("compositor: the pointer theme file ", theme_file, " is not valid, not used: part ", contract_enum_words(.Pointer_Part, u64(part)), ", index ", u64(3), ", field ", contract_enum_words(.Pointer_Field, u64(field)), ", problem ", contract_enum_words(.Pointer_Problem, u64(kind)), ", value ", max(u64), ", limit ", u64(0)))
				}
			}
			facts_expect_line(t, fact_test_render(t, compositor_file, "compositor", "Pointer_Theme_Refused", {{"problem_kind", max(u64)}, {"theme_part", max(u64)}, {"theme_field", max(u64)}, {"place_index", max(u64)}, {"value", u64(0)}, {"limit", max(u64)}, {"theme_file", theme_file}}), line_of_before("compositor: the pointer theme file ", theme_file, " is not valid, not used: part ", max(u64), ", index ", max(u64), ", field ", max(u64), ", problem ", max(u64), ", value ", u64(0), ", limit ", max(u64)))
		}
		testing.expect_value(t, contract_enum_words(.Pointer_Field, u64(pointer_pictures.Field.Hot_Spot_X)), "Hot_Spot_X")
	}

	inspect_file, inspect_ok := window_facts_file(t, "inspect")
	if inspect_ok {
		// The old line wrote an address with system.write_number: "0x" and
		// the digits with no zero before the first.
		addresses := [4]u64{0, 0xf, 0x1a2b, max(u64)}
		names := [2]string{name_longest(), "fault"}
		for address in addresses {
			for name in names {
				facts_expect_line(t, fact_test_render(t, inspect_file, "inspect", "Stopped_On_Page_Fault", {{"address", address}, {"sampled_process", name}}), fmt.tprintf("inspect: %s stopped: page fault at 0x%x", name, address))
				facts_expect_line(t, fact_test_render(t, inspect_file, "inspect", "Stopped_On_Fault", {{"address", address}, {"sampled_process", name}}), fmt.tprintf("inspect: %s stopped: fault 0x%x", name, address))
			}
		}
		for count in COUNTS {
			facts_expect_line(t, fact_test_render(t, inspect_file, "inspect", "Values_Hidden", {{"hidden_values", count}, {"sampled_process", "fault"}}), line_of_before("inspect: fault: values hidden by the kernel: ", count))
		}
	}
}
