package build

import "modus:contract/call_status"
import "modus:contract/errors"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "modus:sentence"
import "core:fmt"
import "core:strings"
import "core:testing"
import "modustool:foundation"

// The log facts of the demonstrations from imports to workers against the
// lines that they replaced (src/md/features/log_facts.md, "The facts of the
// demonstrations"), so that a wait on a sentence that did not change reads
// it as before. The fact types come from the extraction of the tool on the
// sources of each module: a host test does not depend on a build. Each
// sentence is compared with the parts of the old line written by
// sentence.format, at the edges of each field: the counts 0, 1 and
// max(u64); a time or a size 0, 1 and max(i64), the largest that its
// signed field holds; a signed value below 0; each member of a status and
// each words of a choice; the longest text of a Text field and a short one.
// A few sentences changed with the facts, and each is compared with its new
// sentence: a status by its name where a line wrote its number, a measure
// with one decimal as a field of hundredths with two, a long line or a
// loop as several facts, an error record as its seven fields. The helpers
// are in fact_test_helpers_test.odin.

@(private = "file")
DEMONSTRATION_EDGE_COUNTS := [3]u64{0, 1, max(u64)}
@(private = "file")
DEMONSTRATION_EDGE_TIMES := [3]u64{0, 1, u64(max(i64))}
@(private = "file")
DEMONSTRATION_VERDICTS := [2]string{"as it must", "WRONG"}
// The longest address of a host, as each address_text writes it, and a
// short one.
@(private = "file")
DEMONSTRATION_PEERS := [2]string{"255.255.255.255 port 65535", "10.0.2.2 port 7100"}

// facts_file_of_demonstration gives the module file of the fact types of one
// demonstration, or of a test module that was a demonstration before: the
// sentences of its facts stay the lines of before.
@(private = "file")
facts_file_of_demonstration :: proc(t: ^testing.T, folder: string) -> (file: []u8, ok: bool) {
	if folder == "persistence_check" {
		return facts_file_of_folder(t, strings.concatenate({foundation.TEST_MODULE_SOURCES, folder}, context.temp_allocator))
	}
	return facts_file_of_folder(t, strings.concatenate({foundation.DEMONSTRATION_MODULE_SOURCES, folder}, context.temp_allocator))
}

// One Text field of a demonstration and the most bytes of the text that
// its writer puts there.
@(private = "file")
Demonstration_Text_Most :: struct {
	name: string,
	most: u32,
}

// Each fact type of these demonstrations with a Text field ends with its
// Text fields, and each Text field holds the longest text of its writer
// and a zero byte. A field name means one text in one module, so each
// module has its own table.
@(test)
the_texts_of_the_facts_from_imports_to_workers_come_last_and_whole :: proc(t: ^testing.T) {
	LONGEST_PEER :: "255.255.255.255 port 65535"
	// The names of a load error: a name of a module or of an export has
	// module.NAME_SIZE bytes at most.
	load_names := [5]string{"module_name", "imported_name", "replacement_name", "subject_name", "export"}
	Module_Texts :: struct {
		folder: string,
		texts:  []Demonstration_Text_Most,
	}
	modules := [?]Module_Texts {
		{"imports", {{"process_writer", len("not found")}, {"own_writer", len("not found")}, {"case_text", 52}, {"answer", 87}}},
		{"interface_elements", {{"chosen_name", len("compositor")}, {"typed_text", 32}, {"overlay", len("hidden")}, {"measure", 18}}},
		{"interface_font", {{"font", len("paper_mono_semibold")}}},
		{"interface_through_module", {{"full_count", len("not the count of the full frame")}}},
		{"kernel_events", {{"child", len("the child that faults")}, {"verdict", len("as it must")}, {"operation", len("an unknown operation")}}},
		{"limits", {}},
		{"locker", {}},
		{"locks", {{"lock", 7}}},
		{"net", {{"problem", 128}, {"address", len("255.255.255.255")}, {"link", len("down")}, {"hardware", len("ff:ff:ff:ff:ff:ff")}, {"remote", len("255.255.255.255")}, {"wrong_mark", len(" (WRONG)")}}},
		{"persistence_check", {{"date", len("2026-11-20 10:20:30")}, {"note_text", 60}}},
		{"origin", {{"case_text", len("revoke a handle that the process does not have")}}},
		{"pointers", {{"theme", 31}, {"theme_name", 32}, {"license", 32}, {"shape", len("resize_left_right")}, {"part", 17}, {"field", 27}, {"rule", 60}}},
		{"processor_frame", {{"pixels_right", len("yes, yes, yes, yes")}, {"tables_whole", len("yes")}}},
		{"processors", {}},
		{"quic_echo", {{"cause", len("the module cryptography refused to make the public key")}, {"peer", len(LONGEST_PEER)}, {"public_key", 64}, {"end_cause", 22}, {"client_reason", 48}}},
		{"randomness", {{"strength", len("weak (the cycle counter only)")}, {"first_bytes", len("00112233 44556677 8899aabb ccddeeff")}}},
		{"return_fault", {{"case_name", len("a stack address that is not canonical at a syscall")}, {"verdict", len("as it must")}}},
		{"rights", {{"attempt", 44}}},
		{"rings", {{"cause", len("no grant to read the boot image")}}},
		{"scheduler", {{"verdict", len("as it must")}, {"strategy", len("round robin")}, {"previous_strategy", len("round robin")}, {"problem", 103}, {"verdict_words", len("no round had a lag below 0, so nothing was checked: WRONG")}, {"process_name", len("started_under_policy")}}},
		{"server", {{"cause", len("no endpoint: the process has no grant of the network")}, {"method", len("OPTIONS")}, {"target", 48}, {"peer", len(LONGEST_PEER)}, {"how", len("aborted: an answer under 4096 bytes in one second")}, {"page", 39}}},
		{"tables", {{"direct", len("refused")}, {"call_host", len("refused")}, {"service", len("refused")}, {"way", len("call host, memory object")}, {"case_name", 37}, {"call_way", 11}, {"answer", 87}}},
		{"threads", {}},
		{"tone", {{"case_name", len("a record past the end of the region")}, {"status", len("Out_Of_Range")}, {"command", 6}}},
		{"twin", {}},
		{"vector_glyphs", {{"font", len("Paper Mono (default)")}, {"font_problem", 66}}},
		{"workers", {}},
	}
	for item in modules {
		file, ok := facts_file_of_demonstration(t, item.folder)
		if !ok {
			continue
		}
		most := make(map[string]u32, context.temp_allocator)
		for text in item.texts {
			most[text.name] = text.most
		}
		if item.folder == "kernel_events" || item.folder == "scheduler" || item.folder == "tables" {
			for name in load_names {
				most[name] = module.NAME_SIZE
			}
		}
		facts_expect_text_fields_last(t, file, most)
	}
}

// Each fact type of imports and of interface_elements writes the line of
// before.
@(test)
the_facts_of_imports_and_interface_elements_write_the_lines_of_before :: proc(t: ^testing.T) {
	imports, imports_ok := facts_file_of_demonstration(t, "imports")
	elements, elements_ok := facts_file_of_demonstration(t, "interface_elements")
	if !imports_ok || !elements_ok {
		return
	}
	writers := [3]string{"process", "starter", "not found"}
	for count in DEMONSTRATION_EDGE_COUNTS {
		other := max(u64) - count
		facts_expect_line(t, fact_test_render(t, imports, "imports", "Module_Writer_Unknown", {{"base", count}, {"writer_word", other}}), line_of_before("imports: the module record at ", count, " has the writer word ", other, ", which names no writer"))
		for writer in writers {
			facts_expect_line(t, fact_test_render(t, imports, "imports", "Root_Service_Module_Record", {{"refused", count}, {"changes", other}, {"process_writer", writer}, {"own_writer", "process"}}), line_of_before("imports: the module record of the root service: ", count, " of ", other, " changes refused with Starter_Module, writer ", writer, "; calendar, loaded by this process: writer ", "process"))
		}
		facts_expect_line(t, fact_test_render(t, imports, "imports", "Cases_Passed", {{"cases", count}}), line_of_before("imports: ok, ", count, " cases"))
		facts_expect_line(t, fact_test_render(t, elements, "interface_elements", "Button_Pressed", {{"presses", count}}), line_of_before("interface_elements: the button was pressed ", count, " times"))
	}
	for size in DEMONSTRATION_EDGE_TIMES {
		facts_expect_line(t, fact_test_render(t, imports, "imports", "Calendar_Code_Shared", {{"pages", size}, {"mappings", max(u64)}}), line_of_before("imports: two processes import calendar at two places: one copy of its code, ", size, " pages, mapped ", max(u64), " times"))
		other := u64(max(i64)) - size
		facts_expect_line(t, fact_test_render(t, elements, "interface_elements", "Whole_Frame_Measured_Without_Interface_Font", {{"cell_font", size}}), line_of_before("interface_elements: one whole frame, built and drawn (the least of 20): the font of the cells ", size, " us; no interface font"))
		facts_expect_line(t, fact_test_render(t, elements, "interface_elements", "Whole_Frame_Measured", {{"cell_font", size}, {"interface_font", other}}), line_of_before("interface_elements: one whole frame, built and drawn (the least of 20): the font of the cells ", size, " us, the interface font ", other, " us"))
		facts_expect_line(t, fact_test_render(t, elements, "interface_elements", "Frames_Drawn", {{"whole_frame", size}, {"damage_rectangles", max(u64)}, {"damage_frame", other}}), line_of_before("interface_elements: ok, the whole frame drawn in ", size, " us; the next frame drawn in its ", max(u64), " damage rectangles in ", other, " us"))
	}
	names := [?]string{"boot", "clock", "remote", "scheduler", "palette", "compositor"}
	for name in names {
		facts_expect_line(t, fact_test_render(t, elements, "interface_elements", "List_Chose", {{"chosen_name", name}}), line_of_before("interface_elements: the list chooses ", name))
	}
	// The most bytes of the input, a short text, and a text with a quote.
	typed := [?]string{strings.repeat("w", 32, context.temp_allocator), "hello", "a \"b\""}
	for text in typed {
		facts_expect_line(t, fact_test_render(t, elements, "interface_elements", "Text_Typed", {{"typed_text", text}}), line_of_before("interface_elements: the text is \"", text, "\""))
	}
	for overlay in ([2]string{"shown", "hidden"}) {
		facts_expect_line(t, fact_test_render(t, elements, "interface_elements", "Damage_Overlay_Changed", {{"overlay", overlay}}), line_of_before("interface_elements: the damage is ", overlay))
	}
}

// Each fact type of interface_font and of interface_through_module writes
// the line of before.
@(test)
the_facts_of_the_interface_demonstrations_write_the_lines_of_before :: proc(t: ^testing.T) {
	font, font_ok := facts_file_of_demonstration(t, "interface_font")
	module_file, module_ok := facts_file_of_demonstration(t, "interface_through_module")
	if !font_ok || !module_ok {
		return
	}
	render_font :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
		return fact_test_render(t, file, "interface_font", type_name, values)
	}
	render_module :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
		return fact_test_render(t, file, "interface_through_module", type_name, values)
	}
	FAULT :: "interface_font: the fallback chain of the interface is wrong: "
	fonts := [?]string{"paper_mono_semibold", "b612", ""}
	for count in DEMONSTRATION_EDGE_COUNTS {
		other := max(u64) - count
		facts_expect_line(t, render_font(t, font, "Greek_Letters_Drawn", {{"letters", count}}), line_of_before("interface_font: each Greek letter of B612 is drawn by this process: ", count, " letters: as it must"))
		facts_expect_line(t, render_font(t, font, "Greek_Letters_Missing", {{"drawn", count}, {"letters", other}, {"missing", count}}), line_of_before("interface_font: not each Greek letter of B612 is drawn: ", count, " of ", other, ", ", count, " with no glyph"))
		for name in fonts {
			facts_expect_line(t, render_font(t, font, "Box_Character_Wrong", {{"character", count}, {"ink_rows", other}, {"font", name}}), line_of_before(FAULT, "the character ", count, " comes from the font ", name, ", with ", other, " rows of ink"))
		}
		facts_expect_line(t, render_font(t, font, "Box_Characters_From_Paper_Mono", {{"characters", count}}), line_of_before("interface_font: the box-drawing characters come from paper_mono, the second font of the chain of the interface: ", count, " characters: as it must"))
		facts_expect_line(t, render_font(t, font, "Missing_Character_Has_Glyph", {{"character", count}}), line_of_before(FAULT, "the character ", count, " has a glyph, and no font of the chain has it"))
		facts_expect_line(t, render_font(t, font, "Missing_Character_Has_Advance", {{"character", count}}), line_of_before(FAULT, "the character ", count, " has an advance of a font"))
		facts_expect_line(t, render_font(t, font, "Replacement_Glyph_Drawn", {{"characters", count}}), line_of_before("interface_font: ", count, " characters that no font of the chain has draw the replacement glyph: as it must"))
		facts_expect_line(t, render_font(t, font, "Fonts_Ready", {{"regular_pairs", count}, {"bold_pairs", other}}), line_of_before("interface_font: ok, B612 Regular and Bold, ", count, " and ", other, " pairs"))
		facts_expect_line(t, render_module(t, module_file, "Drawing_Module_Refused", {{"error_kind", count}, {"argument", other}}), line_of_before("interface_through_module: the drawing module refused the frame, with the error kind ", count, " of the argument ", other, ": WRONG"))
		facts_expect_line(t, render_module(t, module_file, "Same_Pixels", {{"pixels", count}, {"text_records", other}}), line_of_before("interface_through_module: one frame drawn by the package compiled in and by the drawing module: ", count, " pixels, ", other, " text records, the same bytes: as it must"))
		facts_expect_line(t, render_module(t, module_file, "Pixels_Differ", {{"different", count}, {"pixels", other}, {"text_records", count}}), line_of_before("interface_through_module: one frame drawn by the package compiled in and by the drawing module: ", count, " of ", other, " pixels differ, ", count, " text records: WRONG"))
		for full_count in ([2]string{"the count of the full frame", "not the count of the full frame"}) {
			facts_expect_line(t, render_module(t, module_file, "Frame_Did_Not_Fit", {{"asked", count}, {"drawn", other}, {"full_count", full_count}}), line_of_before("interface_through_module: a draw table of 16 places: the frame did not fit, ", count, " records asked, ", other, " drawn, ", full_count))
		}
	}
	for time in DEMONSTRATION_EDGE_TIMES {
		other := u64(max(i64)) - time
		facts_expect_line(t, render_font(t, font, "Line_Measured", {{"characters", max(u64)}, {"shaping", time}, {"drawing", other}, {"first_drawing", time}}), line_of_before("interface_font: one line of ", max(u64), " characters in B612 at scale 1 (the least of 50 batches): shaping ", time, " ns, drawing ", other, " ns; its first draw, each glyph from its outline: ", time, " ns"))
		facts_expect_line(t, render_module(t, module_file, "Frame_Built", {{"records", max(u64)}, {"text_bytes", u64(0)}, {"calls", u64(1)}, {"through_module", time}, {"compiled_in", other}, {"builds", max(u64)}}), line_of_before("interface_through_module: one frame of ", max(u64), " draw records and ", u64(0), " text bytes in ", u64(1), " element calls: ", time, " ns through the module, ", other, " ns with the package compiled in, the least of ", max(u64)))
		facts_expect_line(t, render_module(t, module_file, "Frame_Drawn", {{"drawing", time}, {"module_code", other}}), line_of_before("interface_through_module: the damage and the drawing through the module: ", time, " ns; interface_module has ", other, " bytes of code"))
	}
}

// Each fact type of kernel_events writes the line of before: each status,
// each stop cause and outcome, each verdict.
@(test)
the_facts_of_kernel_events_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := facts_file_of_demonstration(t, "kernel_events")
	if !ok {
		return
	}
	render :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
		return fact_test_render(t, file, "kernel_events", type_name, values)
	}
	children := [2]string{"the child that faults", "the load child"}
	for status in op.Status {
		word := u64(status)
		name := op.STATUS_NAMES[status]
		for child in children {
			facts_expect_line(t, render(t, file, "Shared_Page_Not_Made", {{"status", word}, {"child", child}}), line_of_before("kernel_events: ", child, ": memory_create of the shared page failed: ", name))
			facts_expect_line(t, render(t, file, "Shared_Page_Not_Mapped", {{"status", word}, {"child", child}}), line_of_before("kernel_events: ", child, ": memory_map of the shared page failed: ", name))
		}
		facts_expect_line(t, render(t, file, "Events_Set_Refused", {{"records", max(u64)}, {"rules", u64(max(u32))}, {"status", word}}), line_of_before("kernel_events: Events_Set with ", u64(max(u32)), " rules and ", max(u64), " records gave ", name))
		facts_expect_line(t, render(t, file, "Drainer_Not_Started", {{"status", word}}), line_of_before("kernel_events: the thread that empties the rings did not start: ", name))
		facts_expect_line(t, render(t, file, "Load_Memory_Not_Made", {{"status", word}}), line_of_before("kernel_events: the load child could not make its memory object: ", name))
		facts_expect_line(t, render(t, file, "Rings_Not_Made", {{"status", word}}), line_of_before("kernel_events: memory_create of the rings failed: ", name))
		facts_expect_line(t, render(t, file, "Rings_Not_Mapped", {{"status", word}}), line_of_before("kernel_events: memory_map of the rings failed: ", name))
		for verdict in DEMONSTRATION_VERDICTS {
			facts_expect_line(t, render(t, file, "No_Grant_Refused", {{"status", word}, {"verdict", verdict}}), line_of_before("kernel_events: no grant: Events_Set with a copy of the machine handle with no right gave ", name, ": ", verdict))
			facts_expect_line(t, render(t, file, "Seventeenth_Rule_Refused", {{"sixteen_rules", word}, {"seventeen_rules", u64(op.Status.No_Slot)}, {"verdict", verdict}}), line_of_before("kernel_events: a seventeenth rule: 16 rules ", name, ", 17 rules ", op.STATUS_NAMES[.No_Slot], ": ", verdict))
			facts_expect_line(t, render(t, file, "Table_Taken_Away", {{"records_after", max(u64)}, {"second_take", word}, {"verdict", verdict}}), line_of_before("kernel_events: the table taken away: ", max(u64), " records after it; a second take gave ", name, ": ", verdict))
			facts_expect_line(t, render(t, file, "Right_Revoked", {{"records_before", u64(1000)}, {"calls", u64(1000)}, {"records_after", u64(0)}, {"status", word}, {"verdict", verdict}}), line_of_before("kernel_events: the right revoked: ", u64(1000), " records of ", u64(1000), " before it; ", u64(0), " records after it; Events_Set after it gave ", name, ": ", verdict))
		}
	}
	rounds := [3]u64{0, 1, u64(max(u32))}
	for cause in op.Stop_Cause {
		for round in rounds {
			if cause == .Itself {
				for outcome in op.Stop_Outcome {
					facts_expect_line(t, render(t, file, "Load_Child_Stopped", {{"round", round}, {"cause", u64(cause)}, {"outcome", u64(outcome)}}), line_of_before("kernel_events: the load child stopped: ", op.STOP_CAUSE_TEXTS[cause], ", ", op.STOP_OUTCOME_TEXTS[outcome], ", before the end of the round ", round))
				}
			} else {
				facts_expect_line(t, render(t, file, "Load_Child_Stopped_Without_Outcome", {{"round", round}, {"cause", u64(cause)}}), line_of_before("kernel_events: the load child stopped: ", op.STOP_CAUSE_TEXTS[cause], ", before the end of the round ", round))
			}
		}
		facts_expect_line(t, render(t, file, "Fault_Cause_Kept", {{"cause", u64(cause)}}), line_of_before("kernel_events: the child that faults, stopped again by this process: its stop cause stays ", op.STOP_CAUSE_TEXTS[cause], ": as it must"))
		facts_expect_line(t, render(t, file, "Fault_Cause_Changed", {{"cause", u64(cause)}}), line_of_before("kernel_events: the child that faults, stopped again by this process: its stop cause stays ", op.STOP_CAUSE_TEXTS[cause], ", not a fault: WRONG"))
	}
	operations := [3]string{"Fault_Handler_Set", "an unknown operation", "Log"}
	for count in DEMONSTRATION_EDGE_COUNTS {
		other := max(u64) - count
		for time in DEMONSTRATION_EDGE_TIMES {
			for child in children {
				facts_expect_line(t, render(t, file, "Child_Budget_Not_Back", {{"bound", time}, {"child", child}}), line_of_before("kernel_events: ", child, ": the budget of this process did not get back every page, thread and process of the child in ", time, " ms"))
			}
			facts_expect_line(t, render(t, file, "Round_Not_Ended", {{"round", count}, {"bound", time}}), line_of_before("kernel_events: the load child did not end the round ", count, " in ", time, " ms"))
			for operation in operations {
				facts_expect_line(t, render(t, file, "Every_Process_Shown", {{"operations", count}, {"longest", time}, {"lock_waits", other}, {"operation", operation}}), line_of_before("kernel_events: in 200 ms while this process sleeps, every process: ", count, " operations, the longest ", operation, " in ", time, " ns; ", other, " waits for a lock (shown, not checked)"))
			}
		}
		for verdict in DEMONSTRATION_VERDICTS {
			facts_expect_line(t, render(t, file, "Operations_Counted", {{"records", count}, {"lost", other}, {"verdict", verdict}}), line_of_before("kernel_events: 1000 operations Memory_Size of one process: ", count, " records, ", other, " lost: ", verdict))
			facts_expect_line(t, render(t, file, "Sleeps_Counted", {{"switches", count}, {"verdict", verdict}}), line_of_before("kernel_events: a thread that sleeps 20 times: ", count, " switches to it: ", verdict))
			facts_expect_line(t, render(t, file, "One_In_Ten_Counted", {{"records", count}, {"verdict", verdict}}), line_of_before("kernel_events: one in 10: ", count, " records of 1000 operations: ", verdict))
			facts_expect_line(t, render(t, file, "Full_Ring_Counted", {{"written", count}, {"lost", other}, {"total", count}, {"verdict", verdict}}), line_of_before("kernel_events: a full ring of 16 records: ", count, " written, ", other, " lost, ", count, " of 1000: ", verdict))
			facts_expect_line(t, render(t, file, "Ends_Under_Load", {{"ends", count}, {"loaders", other}, {"records", count}, {"lost", other}, {"verdict", verdict}}), line_of_before("kernel_events: 1000 gives and ends under load: ", count, " ends with ", other, " loaders, ", count, " records and ", other, " lost in all, the pattern whole after each end: ", verdict))
		}
		facts_expect_line(t, render(t, file, "Round_Word_Unknown", {{"round_word", count}}), line_of_before("kernel_events: the load child got the round ", count, ", which names no round: it stops"))
		facts_expect_line(t, render(t, file, "Child_Past_Its_Fault", {{"role", count}}), line_of_before("kernel_events: the child of the role ", count, " came past its fault"))
		facts_expect_line(t, render(t, file, "Role_Word_Unknown", {{"role", count}}), line_of_before("kernel_events: the context names the role ", count, ", which names no role"))
		facts_expect_line(t, render(t, file, "Cases_Passed", {{"cases", count}}), line_of_before("kernel_events: ok, ", count, " cases: each count of the rings was exact, each refusal came, and each child gave back every page and every thread"))
		facts_expect_line(t, render(t, file, "Cases_Failed", {{"failed", count}, {"cases", other}}), line_of_before("kernel_events: failed: ", count, " cases of ", other))
	}
}

// Each fact type of limits, locker and locks writes the line of before.
@(test)
the_facts_of_limits_and_locks_write_the_lines_of_before :: proc(t: ^testing.T) {
	limits, limits_ok := facts_file_of_demonstration(t, "limits")
	locker, locker_ok := facts_file_of_demonstration(t, "locker")
	locks, locks_ok := facts_file_of_demonstration(t, "locks")
	if !limits_ok || !locker_ok || !locks_ok {
		return
	}
	render :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
		return fact_test_render(t, file, "locks", type_name, values)
	}
	for count in DEMONSTRATION_EDGE_COUNTS {
		other := max(u64) - count
		facts_expect_line(t, fact_test_render(t, limits, "limits", "Processor_Time_Used", {{"first_used", count}, {"first_limit", other}, {"second_used", count}, {"second_limit", other}, {"third_used", count}, {"third_limit", other}, {"process_used", count}, {"process_limit", other}}), line_of_before("limits: processor time of one second, used of limit: ", count, " of ", other, ", ", count, " of ", other, ", ", count, " of ", other, ", the process ", count, " of ", other))
		facts_expect_line(t, fact_test_render(t, limits, "limits", "Budgets_Within_Limits", {{"accepted", count}, {"refused", other}, {"log_limit", count}}), line_of_before("limits: ok, 4 budgets within their processor time, ", count, " log records written and ", other, " refused with ", count, " for each second"))
		facts_expect_line(t, fact_test_render(t, limits, "limits", "Checks_Wrong", {{"threads_started", count}, {"log_right", other}, {"rule_right", count}}), line_of_before("limits: wrong: threads ", count, " log ", other, " rule ", count))
		facts_expect_line(t, fact_test_render(t, locker, "locker", "Slot_Past_Board", {{"slot", count}}), line_of_before("locker: no board, or the slot ", count, " is past the board"))
		facts_expect_line(t, fact_test_render(t, locker, "locker", "Mode_Word_Unknown", {{"mode_word", count}}), line_of_before("locker: the board names the mode ", count, ", which names no mode"))
		facts_expect_line(t, render(t, locks, "Locker_Entries_Differ", {{"locker", count}, {"operations", other}, {"entries", count}, {"kernel_entries", other}}), line_of_before("locks: locker ", count, " counted ", other, " operations and ", count, " entries, the kernel ", other))
		facts_expect_line(t, render(t, locks, "Frames_Stress_Done", {{"made", count}, {"faulted", other}, {"reports", count}, {"wrong", other}}), line_of_before("locks: frames: ", count, " objects of 600 pages made and closed by two lockers while two lockers faulted ", other, " pages and this process read ", count, " reports; reports where the free pages less the reserved pages were not the pages of the budgets: ", other))
		lockers := []Fact_Test_Field{{"one_locker", count}, {"two_lockers", other}, {"four_lockers", count}}
		facts_expect_line(t, render(t, locks, "Kernel_Entries_Measured", lockers), line_of_before("locks: kernel entries in one second, each locker on its own objects: 1 locker ", count, ", 2 lockers ", other, ", 4 lockers ", count))
		facts_expect_line(t, render(t, locks, "Kernel_Entries_Counted", lockers), line_of_before("locks: kernel entries, each locker on its own objects: 1 locker ", count, ", 2 lockers ", other, ", 4 lockers ", count))
		facts_expect_line(t, render(t, locks, "Pages_On_First_Use_Measured", lockers), line_of_before("locks: pages on first use in one second, each locker in its own memory: 1 locker ", count, ", 2 lockers ", other, ", 4 lockers ", count))
		facts_expect_line(t, render(t, locks, "Pages_On_First_Use_Counted", lockers), line_of_before("locks: pages on first use, each locker in its own memory: 1 locker ", count, ", 2 lockers ", other, ", 4 lockers ", count))
		wakes := []Fact_Test_Field{{"alone", count}, {"loaded", other}, {"lost", count}}
		facts_expect_line(t, render(t, locks, "Word_Wait_Measured", wakes), line_of_before("locks: word wait, two threads wake each other: ", count, " wakes in one second alone, ", other, " while 2 lockers enter the kernel, ", count, " lost"))
		facts_expect_line(t, render(t, locks, "Word_Wait_Counted", wakes), line_of_before("locks: word wait, two threads wake each other: ", count, " wakes alone, ", other, " while 2 lockers enter the kernel, ", count, " lost"))
		facts_expect_line(t, render(t, locks, "Checks_Wrong", {{"entries_right", count}, {"faults_right", other}, {"pages_right", count}, {"wakes_right", other}, {"lost", count}, {"stress_right", other}, {"frames_right", count}}), line_of_before("locks: wrong: entries ", count, " faults ", other, " pages ", count, " wakes ", other, " lost ", count, " stress ", other, " frames ", count))
	}
}

// Each fact type of net writes the line of before: the longest problem
// that its buffer holds, each command word that names no command.
@(test)
the_facts_of_net_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := facts_file_of_demonstration(t, "net")
	if !ok {
		return
	}
	render :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
		return fact_test_render(t, file, "net", type_name, values)
	}
	problems := [2]string{strings.repeat("p", 128, context.temp_allocator), "udp, byte 34: the remote port 9 is not the port of the grant, 7"}
	words := [3]u64{0, 10, u64(max(u32))}
	for count in DEMONSTRATION_EDGE_COUNTS {
		other := max(u64) - count
		for problem in problems {
			facts_expect_line(t, render(t, file, "Refused_For_Endpoint", {{"count", count}, {"problem", problem}}), line_of_before("net: refused for this endpoint: ", count, " x ", problem))
			facts_expect_line(t, render(t, file, "Refused_For_Machine", {{"count", count}, {"problem", problem}}), line_of_before("net: refused for the machine: ", count, " x ", problem))
		}
		for word in words {
			facts_expect_line(t, render(t, file, "Command_Word_Refused", {{"word", word}}), line_of_before("net: the command word ", word, " of the datagram ring: refused with Bad_Command and the record Unsupported of the word, and the next Info is served: as it must"))
			// The error kind is written by its name, and a word that names
			// no kind by its number.
			kinds := [3]u64{u64(errors.Kind.Unsupported), u64(errors.Kind.None), max(u64)}
			kind_words := [3]string{errors.KIND_NAMES[.Unsupported], errors.KIND_NAMES[.None], "18446744073709551615"}
			for kind, index in kinds {
				facts_expect_line(t, render(t, file, "Command_Word_Wrong", {{"word", word}, {"status", count}, {"error_kind", kind}, {"operation", count}, {"next_status", other}}), line_of_before("net: the command word ", word, " of the datagram ring: WRONG: ", "the status ", count, ", the error kind ", kind_words[index], ", the operation ", count, "; the next Info: the status ", other))
				facts_expect_line(t, render(t, file, "Command_Word_Unanswered", {{"word", word}, {"status", count}, {"error_kind", kind}, {"operation", count}, {"next_status", other}}), line_of_before("net: the command word ", word, " of the datagram ring: WRONG: ", "no answer, the status ", count, ", the error kind ", kind_words[index], ", the operation ", count, "; the next Info: the status ", other))
			}
		}
		facts_expect_line(t, render(t, file, "Burst_Measured", {{"in_flight", count}, {"rate", other}, {"lost", count}}), line_of_before("net: a burst with ", count, " datagrams in flight: ", other, " datagrams in one second, sent and answered, ", count, " lost"))
		facts_expect_line(t, render(t, file, "Cases_Passed", {{"cases", count}}), line_of_before("net: ok, ", count, " cases"))
		facts_expect_line(t, render(t, file, "Cases_Wrong", {{"wrong", count}, {"cases", other}}), line_of_before("net: WRONG: ", count, " of ", other, " cases"))
	}
	for time in DEMONSTRATION_EDGE_TIMES {
		other := u64(max(i64)) - time
		facts_expect_line(t, render(t, file, "Round_Trip_Measured", {{"datagram_size", time}, {"least", other}, {"middle", time}, {"trips", max(u64)}}), line_of_before("net: the round trip of one datagram of ", time, " bytes: ", other, " us at least, ", time, " us in the middle, over ", max(u64)))
		facts_expect_line(t, render(t, file, "Refusal_Measured", {{"request", time}, {"refused", max(u64)}, {"requests", u64(0)}}), line_of_before("net: a refused request of the datagram ring (Send of 2000 bytes, Too_Large), from the command to its completion: ", time, " ns, ", max(u64), " of ", u64(0), " refused"))
		facts_expect_line(t, render(t, file, "Checksum_Measured", {{"datagram_size", time}, {"header_and_checksum", other}}), line_of_before("net: the header and the checksum of a datagram of ", time, " bytes: ", other, " ns, in this process (no offload)"))
	}
}

// Each fact type of persistence_check writes the line of before: the longest note and
// an empty one, a generation below 0, with a date and with none.
@(test)
the_facts_of_persistence_check_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := facts_file_of_demonstration(t, "persistence_check")
	if !ok {
		return
	}
	render :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
		return fact_test_render(t, file, "persistence_check", type_name, values)
	}
	note_texts := [3]string{strings.repeat("n", 60, context.temp_allocator), "kept across a restart", ""}
	generations := [4]i64{0, 1, -1, max(i64)}
	for count in DEMONSTRATION_EDGE_COUNTS {
		other := max(u64) - count
		for note_text in note_texts {
			for generation in generations {
				bits := signed_bits(generation)
				facts_expect_line(t, render(t, file, "Version_Shown", {{"version", count}, {"versions", other}, {"generation", bits}, {"date", "2026-11-20 10:20:30"}, {"note_text", note_text}}), line_of_before("persistence_check: the version ", count, " of ", other, ", generation ", generation, ", ", "2026-11-20 10:20:30", ": \"", note_text, "\""))
				facts_expect_line(t, render(t, file, "Version_Shown_Without_Date", {{"version", count}, {"versions", other}, {"generation", bits}, {"note_text", note_text}}), line_of_before("persistence_check: the version ", count, " of ", other, ", generation ", generation, "", "", ": \"", note_text, "\""))
				for time in DEMONSTRATION_EDGE_TIMES {
					facts_expect_line(t, render(t, file, "Version_Restored", {{"generation", bits}, {"commit", signed_bits(-generation)}, {"restore", time}, {"note_text", note_text}}), line_of_before("persistence_check: restored the version of generation ", generation, ": \"", note_text, "\", in the commit of generation ", -generation, " in ", time, " us; the note before it is a version"))
					facts_expect_line(t, render(t, file, "Note_Shown", {{"generation", bits}, {"versions", count}, {"commit_mean", time}, {"commits", other}, {"note_text", note_text}}), line_of_before("persistence_check: the note is \"", note_text, "\", generation ", generation, ", ", count, " versions; one commit of the note: ", time, " us in the mean of ", other))
				}
			}
			facts_expect_line(t, render(t, file, "Note_Restored", {{"count", count}, {"note_text", note_text}}), line_of_before("persistence_check: restored the note \"", note_text, "\" and the count ", count, ", its 3 blocks agree", ""))
			facts_expect_line(t, render(t, file, "Note_Restored_After_Stopped_Run", {{"count", count}, {"note_text", note_text}}), line_of_before("persistence_check: restored the note \"", note_text, "\" and the count ", count, ", its 3 blocks agree", ", the last run stopped before its end"))
		}
		facts_expect_line(t, render(t, file, "Note_Damaged", {{"count", count}}), line_of_before("persistence_check: WRONG: the storage service cannot give the note: the object is damaged; restored the count ", count, ", its 3 blocks agree"))
		facts_expect_line(t, render(t, file, "Count_Stepped", {{"count", count}}), line_of_before("persistence_check: count ", count))
		for time in DEMONSTRATION_EDGE_TIMES {
			facts_expect_line(t, render(t, file, "Count_Run_Stopped", {{"count", count}, {"commits", other}, {"elapsed", time}}), line_of_before("persistence_check: count ", count, ", stopped: ", other, " commits in ", time, " ms"))
		}
	}
	for rows in generations {
		for time in DEMONSTRATION_EDGE_TIMES {
			facts_expect_line(t, render(t, file, "Count_Versions_Listed", {{"rows", signed_bits(rows)}, {"elapsed", time}}), line_of_before("persistence_check: the versions of the count: ", rows, " rows in ", time, " us"))
		}
	}
}

// Each fact type of origin, pointers, processor_frame, processors and
// rights writes the line of before.
@(test)
the_facts_of_origin_pointers_and_processors_write_the_lines_of_before :: proc(t: ^testing.T) {
	origin, origin_ok := facts_file_of_demonstration(t, "origin")
	pointers, pointers_ok := facts_file_of_demonstration(t, "pointers")
	frame, frame_ok := facts_file_of_demonstration(t, "processor_frame")
	processors, processors_ok := facts_file_of_demonstration(t, "processors")
	rights, rights_ok := facts_file_of_demonstration(t, "rights")
	if !origin_ok || !pointers_ok || !frame_ok || !processors_ok || !rights_ok {
		return
	}
	cases := [2]string{"revoke a handle that the process does not have", "close the first copy"}
	for item in cases {
		facts_expect_line(t, fact_test_render(t, origin, "origin", "Answer_Wrong", {{"case_text", item}}), line_of_before("origin: wrong answer: ", item))
	}
	themes := [2]string{strings.repeat("t", 31, context.temp_allocator), "pointers_system"}
	theme_texts := [2]string{strings.repeat("x", 32, context.temp_allocator), "CC0-1.0"}
	shapes := [2]string{"resize_left_right", "arrow"}
	for shape in shapes {
		facts_expect_line(t, fact_test_render(t, pointers, "pointers", "Pointer_Over_Tile", {{"shape", shape}}), line_of_before("pointers: the pointer is over the tile ", shape))
	}
	for count in DEMONSTRATION_EDGE_COUNTS {
		other := max(u64) - count
		facts_expect_line(t, fact_test_render(t, origin, "origin", "Cases_Passed", {{"cases", count}}), line_of_before("origin: ok, ", count, " cases"))
		facts_expect_line(t, fact_test_render(t, processors, "processors", "Processors_Together", {{"together", count}}), line_of_before("processors: ok, ", count, " processors ran the process at the same time"))
		facts_expect_line(t, fact_test_render(t, processors, "processors", "Processors_Together_At_Most", {{"together", count}, {"processors", other}}), line_of_before("processors: at most ", count, " of ", other, " processors ran the process at the same time"))
		facts_expect_line(t, fact_test_render(t, rights, "rights", "Attempts_Passed", {{"allowed", count}, {"refused", other}}), line_of_before("rights: ok, ", count, " allowed, ", other, " refused"))
		answers := [2]string{"yes", "no"}
		for answer in answers {
			facts_expect_line(t, fact_test_render(t, frame, "processor_frame", "Parts_Wrong", {{"refused_calls", count}, {"pixels_right", "yes, no, yes, yes"}, {"tables_whole", answer}}), line_of_before("processor_frame: wrong: the pixels of the clear and present, the full frame, the frame in its damage and the draw table are right: ", "yes", ", ", "no", ", ", "yes", ", ", "yes", "; the drawing module refused ", count, " calls; each table holds each of its records: ", answer))
		}
	}
	for time in DEMONSTRATION_EDGE_TIMES {
		other := u64(max(i64)) - time
		facts_expect_line(t, fact_test_render(t, origin, "origin", "Handle_Cycles_Measured", {{"lend", time}, {"copy_and_close", other}}), line_of_before("origin: lend a handle and take it back: ", time, " ns with 4 kernel entries; copy and close: ", other, " ns with 2"))
		facts_expect_line(t, fact_test_render(t, processors, "processors", "Picture_Timed", {{"one_thread", time}, {"two_threads", other}, {"four_threads", time}}), line_of_before("processors: the picture took ", time, " ms with 1 thread, ", other, " ms with 2 threads, ", time, " ms with 4 threads"))
		for theme in themes {
			facts_expect_line(t, fact_test_render(t, pointers, "pointers", "Theme_Shown", {{"theme", theme}}), line_of_before("pointers: the theme ", theme, " is shown"))
			facts_expect_line(t, fact_test_render(t, pointers, "pointers", "Window_Drawn", {{"themes", max(u64)}, {"drawing", time}, {"theme", theme}}), line_of_before("pointers: ok, ", max(u64), " themes; the window of ", theme, " drawn in ", time, " us"))
			for text in theme_texts {
				facts_expect_line(t, fact_test_render(t, pointers, "pointers", "Theme_Valid", {{"shapes", max(u64)}, {"pictures", u64(0)}, {"file_size", other}, {"check", time}, {"theme", theme}, {"theme_name", text}, {"license", text}}), line_of_before("pointers: ", theme, ": ", text, ", ", text, ", ", max(u64), " shapes, ", u64(0), " pictures, ", other, " bytes; the hash and the validation in ", time, " us"))
			}
		}
	}
}

// Each fact type of quic_echo, randomness, return_fault and rings writes
// the line of before.
@(test)
the_facts_of_quic_echo_randomness_return_fault_and_rings_write_the_lines_of_before :: proc(t: ^testing.T) {
	quic, quic_ok := facts_file_of_demonstration(t, "quic_echo")
	randomness, randomness_ok := facts_file_of_demonstration(t, "randomness")
	return_fault, return_fault_ok := facts_file_of_demonstration(t, "return_fault")
	rings, rings_ok := facts_file_of_demonstration(t, "rings")
	if !quic_ok || !randomness_ok || !return_fault_ok || !rings_ok {
		return
	}
	quic_causes := [2]string{"the module cryptography refused to make the public key", "no datagram region"}
	for cause in quic_causes {
		facts_expect_line(t, fact_test_render(t, quic, "quic_echo", "Start_Failed", {{"cause", cause}}), line_of_before("quic_echo: ", cause))
	}
	ring_causes := [2]string{"no grant to read the boot image", "no surface"}
	for cause in ring_causes {
		facts_expect_line(t, fact_test_render(t, rings, "rings", "Start_Failed", {{"cause", cause}}), line_of_before("rings: ", cause))
	}
	key := strings.repeat("a", 64, context.temp_allocator)
	facts_expect_line(t, fact_test_render(t, quic, "quic_echo", "Public_Key_Made", {{"public_key", key}}), line_of_before("quic_echo: the public key of this server: ", key))
	for peer in DEMONSTRATION_PEERS {
		facts_expect_line(t, fact_test_render(t, quic, "quic_echo", "Connection_Arrived", {{"peer", peer}}), line_of_before("quic_echo: a connection from ", peer))
		for time in DEMONSTRATION_EDGE_TIMES {
			other := u64(max(i64)) - time
			facts_expect_line(t, fact_test_render(t, quic, "quic_echo", "Idle_End_Held", {{"silence", time}, {"idle_timeout", other}, {"bound", time}, {"after_bound", other}, {"peer", peer}}), line_of_before("quic_echo: ", peer, ": the idle end held its bound: ", time, " ms with no packet of the client, the idle timeout ", other, " ms, the bound ", time, " ms, ", other, " ms after the bound"))
			facts_expect_line(t, fact_test_render(t, quic, "quic_echo", "Idle_End_Not_Held", {{"silence", other}, {"idle_timeout", time}, {"bound", other}, {"after_bound", time}, {"peer", peer}}), line_of_before("quic_echo: ", peer, ": the idle end did NOT hold its bound: ", other, " ms with no packet of the client, the idle timeout ", time, " ms, the bound ", other, " ms, ", time, " ms after the bound"))
		}
	}
	strengths := [3]string{"weak (the cycle counter only)", "entropy (rdseed)", "none"}
	bytes := [2]string{"00112233 44556677 8899aabb ccddeeff", "ff"}
	for strength in strengths {
		for first in bytes {
			facts_expect_line(t, fact_test_render(t, randomness, "randomness", "Seed_Shown", {{"strength", strength}, {"first_bytes", first}}), line_of_before("randomness: the seed of the system: strength ", strength, "; the first bytes of the stream of this process: ", first))
		}
	}
	case_names := [2]string{"a stack address that is not canonical at a syscall", "the trap flag at a syscall"}
	for status in op.Status {
		name := op.STATUS_NAMES[status]
		facts_expect_line(t, fact_test_render(t, return_fault, "return_fault", "Instruction_Page_Not_Made", {{"status", u64(status)}}), line_of_before("return_fault: the child of the instruction address could not make its page: ", name))
		facts_expect_line(t, fact_test_render(t, return_fault, "return_fault", "Instruction_Page_Not_Mapped_To_Write", {{"status", u64(status)}}), line_of_before("return_fault: the child of the instruction address could not map its page to write it: ", name))
		facts_expect_line(t, fact_test_render(t, return_fault, "return_fault", "Instruction_Page_Not_Mapped_At_End", {{"status", u64(status)}}), line_of_before("return_fault: the child of the instruction address could not map its page at the last page: ", name))
	}
	for name in case_names {
		facts_expect_line(t, fact_test_render(t, return_fault, "return_fault", "Child_Not_Started", {{"case_name", name}}), line_of_before("return_fault: ", name, ": the child did not start"))
	}
	for count in DEMONSTRATION_EDGE_COUNTS {
		other := max(u64) - count
		facts_expect_line(t, fact_test_render(t, quic, "quic_echo", "Listening", {{"listen_port", count}, {"capacity", other}, {"connection_size", u64(max(i64))}, {"streams", count}, {"stream_size", u64(0)}}), line_of_before("quic_echo: listening on the UDP port ", count, ", a table of ", other, " connections of ", u64(max(i64)), " KiB, each with ", count, " streams of ", u64(0), " KiB, the key of this server from the generator of the process"))
		facts_expect_line(t, fact_test_render(t, randomness, "randomness", "Seed_Strength_Unknown", {{"strength_word", count}}), line_of_before("randomness: the root service gave the seed strength ", count, ", which names no strength: nothing is shown"))
		facts_expect_line(t, fact_test_render(t, randomness, "randomness", "Entropy_Device_Shown", {{"device_bytes", count & u64(max(i64))}, {"refused_reads", other}}), line_of_before("randomness: the entropy device: ", count & u64(max(i64)), " bytes mixed after the gathering; refused reads: ", other))
		facts_expect_line(t, fact_test_render(t, randomness, "randomness", "Byte_Counts_Shown", {{"least", count}, {"most", other}}), line_of_before("randomness: 1 MiB by the high 4 bits of each byte: from ", count, " to ", other, " in each of 16 (the mean is 65536)"))
		facts_expect_line(t, fact_test_render(t, randomness, "randomness", "Fresh_Bytes_Mixed", {{"change", count}}), line_of_before("randomness: the fresh bytes of the root service are mixed into the generator of this process, at the change ", count, " of its page"))
		facts_expect_line(t, fact_test_render(t, return_fault, "return_fault", "Role_Word_Unknown", {{"role", count}}), line_of_before("return_fault: the context names the role ", count, ", which names no role"))
		facts_expect_line(t, fact_test_render(t, return_fault, "return_fault", "Cases_Passed", {{"cases", count}}), line_of_before("return_fault: ok, ", count, " cases: each child stopped as its own fault or returned with the flags of a process, and the machine goes on"))
		facts_expect_line(t, fact_test_render(t, return_fault, "return_fault", "Cases_Failed", {{"failed", count}, {"cases", other}}), line_of_before("return_fault: failed: ", count, " cases of ", other))
		facts_expect_line(t, fact_test_render(t, rings, "rings", "Node_Stopped", {{"node", count}}), line_of_before("rings: node ", count, " stopped"))
		facts_expect_line(t, fact_test_render(t, rings, "rings", "Node_Started", {{"node", count}}), line_of_before("rings: node ", count, " started"))
		facts_expect_line(t, fact_test_render(t, rings, "rings", "Nodes_Running", {{"processes", count}, {"rings", other}, {"records", count}}), line_of_before("rings: ok, ", count, " processes, ", other, " rings, ", count, " records"))
		facts_expect_line(t, fact_test_render(t, rings, "rings", "Record_Added", {{"records", count}}), line_of_before("rings: the key a adds a record: ", count, " records in all"))
		facts_expect_line(t, fact_test_render(t, rings, "rings", "Node_Stopped_Alone", {{"node", count}}), line_of_before("rings: node ", count, " stopped alone"))
		facts_expect_line(t, fact_test_render(t, rings, "rings", "Records_Wait_Before_Node", {{"node", count}, {"records", other}}), line_of_before("rings: node ", count, " does not run: ", other, " records wait in the ring before it"))
	}
}

// Each fact type of scheduler writes the line of before: each status, each
// strategy, each verdict.
@(test)
the_facts_of_scheduler_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := facts_file_of_demonstration(t, "scheduler")
	if !ok {
		return
	}
	render :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
		return fact_test_render(t, file, "scheduler", type_name, values)
	}
	for verdict in DEMONSTRATION_VERDICTS {
		facts_expect_line(t, render(t, file, "Written_Weights_Ordered", {{"verdict", verdict}}), line_of_before("scheduler: the weights 1 2 4 written through the machine handle while 12 spinners ran: each write was read back, and the heavier weight got more under fair and EEVDF", ": ", verdict))
		facts_expect_line(t, render(t, file, "Schedule_Writes_During_Changes", {{"verdict", verdict}}), line_of_before("scheduler: writes of a schedule through the machine handle while the strategy changed 100 times: none was refused, each of the 8 spinners ran after them and has the schedule written last", ": ", verdict))
		facts_expect_line(t, render(t, file, "Other_Process_Schedule", {{"verdict", verdict}}), line_of_before("scheduler: a thread of another process, the root service, found by its name and its serial: through the machine handle its schedule was read, written, read back and written back", ": ", verdict))
		facts_expect_line(t, render(t, file, "Share_Policy_Orders_Parts", {{"verdict", verdict}}), line_of_before("scheduler: the process with 8 spinning threads against the process with 1, by the ticks of the kernel over one interval: its part is smaller under the share policy than without it", ": ", verdict))
		for count in DEMONSTRATION_EDGE_COUNTS {
			other := max(u64) - count
			facts_expect_line(t, render(t, file, "Idle_Processor_Reached", {{"reached", count}, {"verdict", verdict}}), line_of_before("scheduler: two spinners and the first thread kept on the processor 0; the spinner of the list got the processor 1 too through the machine handle: a report showed it on the processor 1: ", count, ": ", verdict))
			facts_expect_line(t, render(t, file, "Placement_Writes_During_Changes", {{"changes", count}, {"spinners", other}, {"verdict", verdict}}), line_of_before("scheduler: writes of a placement through the machine handle while the strategy changed ", count, " times: none was refused, each of the ", other, " spinners ran after them and has each processor again", ": ", verdict))
			facts_expect_line(t, render(t, file, "Started_Process_Weights", {{"above", count}, {"weight", other}, {"limit", count}, {"thread_limit", other}, {"verdict", verdict}}), line_of_before("scheduler: the first thread of a process started under the share policy, by a thread whose own new-thread weight limit is above ", count, ", has the weight, the weight limit and the new-thread weight limit ", other, ", ", count, " and ", other, ": ", verdict))
		}
	}
	strategies := [4]op.Strategy{.None, .Round_Robin, .Fair, .Eevdf}
	for strategy in strategies {
		for previous in strategies {
			facts_expect_line(t, render(t, file, "Strategy_Changed", {{"strategy", op.STRATEGY_NAMES[strategy]}, {"previous_strategy", op.STRATEGY_NAMES[previous]}}), line_of_before("scheduler: the strategy is now ", op.STRATEGY_NAMES[strategy], ", it was ", op.STRATEGY_NAMES[previous]))
		}
	}
	for status in op.Status {
		facts_expect_line(t, render(t, file, "Share_Policy_Thread_Not_Started", {{"status", u64(status)}}), line_of_before("scheduler: the thread of the share policy did not start: ", op.STATUS_NAMES[status]))
	}
	problems := [2]string{strings.repeat("q", 103, context.temp_allocator), "the stress case"}
	for problem in problems {
		facts_expect_line(t, render(t, file, "Check_Failed", {{"problem", problem}}), line_of_before("scheduler: wrong: ", problem))
	}
	for count in DEMONSTRATION_EDGE_COUNTS {
		other := max(u64) - count
		facts_expect_line(t, render(t, file, "Lag_Not_Checked", {{"processors", count}}), line_of_before("scheduler: the lag of a held spinner is not checked on a machine with ", count, " processors or more: each spinner can be alone in its queue"))
		facts_expect_line(t, render(t, file, "Lag_Measured", {{"rounds", count}, {"owing", other}, {"owed", count}, {"largest", other}}), line_of_before("scheduler: in ", count, " rounds the kernel reported the held spinner with a lag below 0 ", other, " times and above 0 ", count, " times; the lowest lag was minus ", other, " weighted cycles (measures)"))
		facts_expect_line(t, render(t, file, "Eevdf_Wakes_Compared", {{"ratio", count}}), line_of_before("scheduler: EEVDF woke ", count, " times as often as round robin (a measure)"))
		facts_expect_line(t, render(t, file, "Strategies_Passed", {{"eevdf_stints", count}, {"changes", other}}), line_of_before("scheduler: ok, no spinner starved under 3 strategies, a wake ended ", count, " stints under EEVDF and 0 under round robin, the weights ordered the shares, each thread ran after ", other, " changes, 0 wakes lost, a change needs the right Schedule"))
		facts_expect_line(t, render(t, file, "Refused_Placement_Not_Checked", {{"processors", count}}), line_of_before("scheduler: the refused writes of a placement are not checked on a machine with ", count, " processors: the case needs a processor that the thread does not have, and a processor that the machine does not have"))
		facts_expect_line(t, render(t, file, "Placement_Limit_Not_Checked", {{"processors", count}}), line_of_before("scheduler: the limit of a placement is not checked on a machine with ", count, " processors: the case needs a limit of two processors and a processor outside it"))
		facts_expect_line(t, render(t, file, "Set_Without_Home_Not_Checked", {{"processors", count}}), line_of_before("scheduler: a set without the home of a thread is not checked on a machine with ", count, " processors: the case needs a second processor, and one spinner more than the processors"))
		facts_expect_line(t, render(t, file, "Groups_Read", {{"samples", count}}), line_of_before("scheduler: the two groups were read in ", count, " reports (a measure)"))
		facts_expect_line(t, render(t, file, "Idle_Processor_Round", {{"round", count}}), line_of_before("scheduler: the spinner was seen on the processor 1 in the round ", count, " (a measure)"))
		facts_expect_line(t, render(t, file, "Placement_Writes_Measured", {{"writes", count}, {"changes", other}, {"refused", count}}), line_of_before("scheduler: ", count, " writes of a placement during ", other, " changes of strategy, ", count, " refused (measures)"))
		facts_expect_line(t, render(t, file, "Short_Threads_Parts", {{"without_policy", count}, {"with_policy", other}, {"without_ended", count}, {"with_ended", other}}), line_of_before("scheduler: the process of short threads got ", count, " % of the process of one long thread without the share policy, and ", other, " % with it; each interval ended on its count of ticks: ", count, " and ", other, " (measures)"))
	}
	for time in DEMONSTRATION_EDGE_TIMES {
		other := u64(max(i64)) - time
		facts_expect_line(t, render(t, file, "Strategy_Set_Measured", {{"least", time}, {"middle", other}, {"worst", time}}), line_of_before("scheduler: one Strategy_Set, with its kernel entry: ", time, " ns at least, ", other, " ns in the middle, ", time, " ns at worst"))
		facts_expect_line(t, render(t, file, "Window_Drawn", {{"drawing", time}}), line_of_before("scheduler: the window took ", time, " us to draw"))
		facts_expect_line(t, render(t, file, "Share_Policy_On", {{"period", time}}), line_of_before("scheduler: the share policy is on: each process has its process weight, divided between its threads that count, one round each ", time, " ms"))
		facts_expect_line(t, render(t, file, "Share_Policy_Round_Measured", {{"processes", max(u64)}, {"threads", u64(0)}, {"middle", time}, {"rounds", u64(1)}, {"writes", max(u64)}, {"raises", u64(0)}, {"period", other}}), line_of_before("scheduler: one round of the share policy, over ", max(u64), " processes and ", u64(0), " threads: ", time, " ns in the middle of ", u64(1), " rounds; ", max(u64), " writes of a schedule in all, ", u64(0), " of them raised a weight; the period of the rounds is ", other, " ms (measures)"))
	}
}

// Each fact type of server writes the line of before: the longest page
// name and each end of a connection. The access record is no fact: the
// record output requests holds it.
@(test)
the_facts_of_server_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := facts_file_of_demonstration(t, "server")
	if !ok {
		return
	}
	render :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
		return fact_test_render(t, file, "server", type_name, values)
	}
	causes := [2]string{"no endpoint: the process has no grant of the network", "no datagram region"}
	for cause in causes {
		facts_expect_line(t, render(t, file, "Run_Failed", {{"cause", cause}}), line_of_before("server: ", cause))
	}
	hows := [3]string{"aborted: an answer under 4096 bytes in one second", "timed out", "closed, this server first"}
	pages := [2]string{strings.repeat("p", 39, context.temp_allocator), "hello.txt"}
	for peer in DEMONSTRATION_PEERS {
		facts_expect_line(t, render(t, file, "Request_Timeout", {{"peer", peer}}), line_of_before("server: ", peer, ": no request in 10 s, closed"))
		for time in DEMONSTRATION_EDGE_TIMES {
			facts_expect_line(t, render(t, file, "Connection_Requests_Measured", {{"requests", max(u64)}, {"elapsed", time}, {"rate", u64(0)}, {"peer", peer}}), line_of_before("server: ", max(u64), " requests on one connection of ", peer, " in ", time, " ms: ", u64(0), " requests in one second"))
			for how in hows {
				facts_expect_line(t, render(t, file, "Connection_Ended", {{"requests", u64(0)}, {"bytes_received", max(u64)}, {"bytes_sent", u64(1)}, {"round_trip", time}, {"retransmissions", max(u64)}, {"probes", u64(0)}, {"challenges", u64(1)}, {"peer", peer}, {"how", how}}), line_of_before("server: ", peer, " ", how, ": ", u64(0), " requests, in ", max(u64), ", out ", u64(1), ", srtt ", time, " us, ", max(u64), " retransmissions, ", u64(0), " probes, ", u64(1), " challenges"))
			}
		}
	}
	for page in pages {
		facts_expect_line(t, render(t, file, "Page_Refused", {{"page", page}}), line_of_before("server: the store refused the page /", page, ": the page that is served did not change"))
		facts_expect_line(t, render(t, file, "Index_Refused", {{"page", page}}), line_of_before("server: the store refused the index of the pages: /", page, " is not served"))
		facts_expect_line(t, render(t, file, "Removal_Refused", {{"page", page}}), line_of_before("server: the store refused the removal of /", page, ": the page is still served"))
		facts_expect_line(t, render(t, file, "Index_Refused_After_Removal", {{"page", page}}), line_of_before("server: the store refused the index of the pages after the removal of /", page))
		facts_expect_line(t, render(t, file, "Page_Removed", {{"page", page}}), line_of_before("server: the page /", page, " is out of the store"))
		for size in DEMONSTRATION_EDGE_TIMES {
			facts_expect_line(t, render(t, file, "Page_Stored", {{"page_size", size}, {"page", page}}), line_of_before("server: the page /", page, " is in the store: ", size, " bytes"))
		}
	}
	for count in DEMONSTRATION_EDGE_COUNTS {
		other := max(u64) - count
		facts_expect_line(t, render(t, file, "Requests_In_One_Second", {{"requests", count}, {"new_connections", other}}), line_of_before("server: ", count, " requests answered in one second, on ", other, " new connections"))
		facts_expect_line(t, render(t, file, "Ends_Not_Logged", {{"ends", count}}), line_of_before("server: ", count, " ends of connections in one second are not on the log (the limit is 50)"))
		facts_expect_line(t, render(t, file, "Connections_Open", {{"open", count}}), line_of_before("server: ", count, " connections open at once"))
		facts_expect_line(t, render(t, file, "Segments_Dropped", {{"segments", count}}), line_of_before("server: ", count, " segments dropped for a wrong checksum"))
		facts_expect_line(t, render(t, file, "Listening", {{"listen_port", count}, {"capacity", other}}), line_of_before("server: listening on the TCP port ", count, ", a table of ", other, " connections, the secret of the initial sequence numbers from the generator of the process"))
		facts_expect_line(t, render(t, file, "Pages_Read", {{"loaded", count}, {"refused", other}}), line_of_before("server: ", count, " pages read from the private store, ", other, " refused"))
	}
	for time in DEMONSTRATION_EDGE_TIMES {
		facts_expect_line(t, render(t, file, "Window_Drawn", {{"drawing", time}}), line_of_before("server: one draw of the window: ", time, " us"))
	}
}

// Each fact type of tables, threads, tone, twin, vector_glyphs and workers
// writes the line of before.
@(test)
the_facts_of_tables_threads_tone_twin_vector_glyphs_and_workers_write_the_lines_of_before :: proc(t: ^testing.T) {
	tables, tables_ok := facts_file_of_demonstration(t, "tables")
	threads, threads_ok := facts_file_of_demonstration(t, "threads")
	tone, tone_ok := facts_file_of_demonstration(t, "tone")
	twin, twin_ok := facts_file_of_demonstration(t, "twin")
	glyphs, glyphs_ok := facts_file_of_demonstration(t, "vector_glyphs")
	workers, workers_ok := facts_file_of_demonstration(t, "workers")
	if !tables_ok || !threads_ok || !tone_ok || !twin_ok || !glyphs_ok || !workers_ok {
		return
	}
	states := [2]string{"ready", "refused"}
	for direct in states {
		for service in states {
			facts_expect_line(t, fact_test_render(t, tables, "tables", "Ways_Ready", {{"direct", direct}, {"call_host", service}, {"service", service}}), line_of_before("tables: the ways: direct ", direct, ", call host ", service, ", service ", service))
		}
	}
	ways := [2]string{"call host, memory object", "direct call"}
	for way in ways {
		for time in DEMONSTRATION_EDGE_TIMES {
			other := u64(max(i64)) - time
			facts_expect_line(t, fact_test_render(t, tables, "tables", "Sum_Values_Measured", {{"small_table", time}, {"medium_table", other}, {"large_table", time}, {"way", way}}), line_of_before("tables: sum_values, ", way, ": ", time, " ns for 64 rows, ", other, " ns for 1024 rows, ", time, " ns for 65536 rows (0: refused)"))
		}
	}
	tone_cases := [2]string{"a record past the end of the region", "a record at the frame 0"}
	tone_statuses := [3]string{"Out_Of_Range", "Late", "Bad_Command"}
	for name in tone_cases {
		for status in tone_statuses {
			facts_expect_line(t, fact_test_render(t, tone, "tone", "Case_Refused", {{"case_name", name}, {"status", status}}), line_of_before("tone: ", name, " is refused with ", status, ": as it must"))
		}
	}
	fonts := [2]string{"Paper Mono (default)", "Iosevka"}
	font_problems := [2]string{strings.repeat("f", 66, context.temp_allocator), "the font has no table cmap"}
	for font in fonts {
		for problem in font_problems {
			facts_expect_line(t, fact_test_render(t, glyphs, "vector_glyphs", "Font_Refused", {{"font", font}, {"font_problem", problem}}), line_of_before("vector_glyphs: the font ", font, " is refused: ", problem))
		}
		for time in DEMONSTRATION_EDGE_TIMES {
			facts_expect_line(t, fact_test_render(t, glyphs, "vector_glyphs", "Font_Opened", {{"open_time", time}, {"font", font}}), line_of_before("vector_glyphs: the font ", font, " opened in ", time, " us"))
		}
	}
	for count in DEMONSTRATION_EDGE_COUNTS {
		other := max(u64) - count
		facts_expect_line(t, fact_test_render(t, tables, "tables", "Cases_Passed", {{"cases", count}, {"hostile_cases", other}}), line_of_before("tables: ok, ", count, " cases in 3 ways and ", other, " hostile cases"))
		facts_expect_line(t, fact_test_render(t, threads, "threads", "Sum_Added", {{"result", count}}), line_of_before("threads: a thread added the numbers to 1000: ", count))
		facts_expect_line(t, fact_test_render(t, threads, "threads", "Thread_Stopped", {{"thread", count}, {"frame", other}}), line_of_before("threads: thread ", count, " stopped at frame ", other))
		facts_expect_line(t, fact_test_render(t, threads, "threads", "Thread_Started", {{"thread", count}}), line_of_before("threads: thread ", count, " started"))
		facts_expect_line(t, fact_test_render(t, threads, "threads", "Threads_Drawing", {{"threads", count}}), line_of_before("threads: ok, ", count, " threads draw in one surface"))
		facts_expect_line(t, fact_test_render(t, tone, "tone", "Tone_Played", {{"frame", count}, {"frames", other}, {"underruns", count}}), line_of_before("tone: the tone of 440 Hz played from the frame ", count, " of the stream for ", other, " frames; underruns before its end: ", count))
		facts_expect_line(t, fact_test_render(t, twin, "twin", "Mode_Word_Unknown", {{"mode_word", count}}), line_of_before("twin: the mode ", count, " names no mode of a twin: nothing is done"))
		facts_expect_line(t, fact_test_render(t, glyphs, "vector_glyphs", "Glyph_Measured", {{"scale_one", count}, {"scale_two", other}, {"scale_three", count}, {"private_cache", other}, {"spleen", count}}), line_of_before("vector_glyphs: one glyph from its outline, in fixed point, with the stripes (the least of batches): scale 1 ", count, " ns, scale 2 ", other, " ns, scale 3 ", count, " ns; from the private glyph cache: ", other, " ns; Spleen 8x16: ", count, " ns"))
		facts_expect_line(t, fact_test_render(t, glyphs, "vector_glyphs", "Candidates_Ready", {{"candidates", count}}), line_of_before("vector_glyphs: ok, ", count, " candidates beside Spleen 8x16"))
		facts_expect_line(t, fact_test_render(t, workers, "workers", "Locked_Additions", {{"additions", count}, {"sum", other}, {"waits", count}}), line_of_before("workers: with the lock, 4 threads made ", count, " additions: the number is ", other, ", ", count, " waits"))
		facts_expect_line(t, fact_test_render(t, workers, "workers", "Free_Additions", {{"additions", count}, {"sum", other}}), line_of_before("workers: with no lock, 4 threads made ", count, " additions: the number is ", other))
		facts_expect_line(t, fact_test_render(t, workers, "workers", "Tiles_Computed", {{"tiles", count}, {"first_thread", other}, {"second_thread", count}, {"third_thread", other}, {"fourth_thread", count}}), line_of_before("workers: ok, 4 threads computed ", count, " tiles: ", other, " ", count, " ", other, " ", count))
	}
	for time in DEMONSTRATION_EDGE_TIMES {
		facts_expect_line(t, fact_test_render(t, tone, "tone", "Stream_Started", {{"held", time}}), line_of_before("tone: the stream started; the service holds ", time, " ns of frames"))
	}
}

// The facts with no value of these demonstrations write the line of
// before.
@(test)
the_facts_with_no_value_of_the_demonstrations_write_the_lines_of_before :: proc(t: ^testing.T) {
	Empty_Fact :: struct {
		folder:    string,
		type_name: string,
		line:      string,
	}
	facts := [?]Empty_Fact {
		{"imports", "No_Random_Seed", "imports: no random seed in the context"},
		{"interface_font", "Fallback_Without_Glyph_Memory", "interface_font: the fallback chain of the interface is wrong: this process has no glyph memory: each glyph is drawn band by band"},
		{"interface_font", "Font_Outlines_Missing", "interface_font: the boot image gives no font outlines with the interface font"},
		{"interface_font", "Glyph_Memory_Missing", "interface_font: this process has no glyph memory: each glyph is drawn band by band"},
		{"interface_through_module", "Draw_Tables_Equal", "interface_through_module: ok, the two draw tables are equal"},
		{"interface_through_module", "Draw_Tables_Differ", "interface_through_module: wrong: the two draw tables differ"},
		{"kernel_events", "Faulter_Not_Started", "kernel_events: the child that faults did not start: the cases 3 to 8 do not run"},
		{"kernel_events", "Table_Given", "kernel_events: the table is given; waiting for the revocation of the grant machine"},
		{"kernel_events", "No_Random_Seed", "kernel_events: no random seed in the context"},
		{"kernel_events", "No_Boot_Image", "kernel_events: no boot image"},
		{"kernel_events", "Load_Child_Not_Started", "kernel_events: the load child did not start: the cases 3 to 12 do not run"},
		{"life", "Running", "life: ok"},
		{"locks", "No_Random_Seed", "locks: no random seed in the context"},
		{"locks", "No_Boot_Image_Or_Memory", "locks: no boot image or no memory"},
		{"locks", "Checks_Passed", "locks: ok, the kernel counted each entry, each page returned, no wake was lost, each stopped process returned its pages, its slot and its threads"},
		{"net", "Key_Datagram_Unanswered", "net: a datagram to 10.0.2.2 port 7 after a key: no answer of the network service"},
		{"net", "Key_Datagram_Answered", "net: a datagram to 10.0.2.2 port 7 after a key: sent, and answer"},
		{"net", "Key_Datagram_Sent_Without_Answer", "net: a datagram to 10.0.2.2 port 7 after a key: sent, and no answer"},
		{"net", "No_Endpoint", "net: no endpoint: the process has no grant of the network"},
		{"net", "No_Datagram_Region", "net: no datagram region"},
		{"net", "Measures_Done", "net: the measures are done"},
		{"persistence_check", "No_Store", "persistence_check: no store"},
		{"persistence_check", "New_Store", "persistence_check: a new store: no note, the count 0"},
		{"persistence_check", "Count_Damaged", "persistence_check: WRONG: the storage service cannot give the count: the object is damaged"},
		{"persistence_check", "Count_Blocks_Differ", "persistence_check: WRONG: the 3 blocks of the count do not agree"},
		{"persistence_check", "First_Picture_Presented", "persistence_check: ok, the first picture is presented"},
		{"paint", "Running", "paint: ok"},
		{"plasma", "Running", "plasma: ok"},
		{"pointers", "No_Boot_Image", "pointers: no boot image"},
		{"pointers", "No_Pointer_Theme", "pointers: the boot image has no pointer theme"},
		{"pointers", "Owner_Theme_Hash_Differs", "pointers: pointers_posy is not valid: the bytes do not have the hash of the entry of the resource"},
		{"pointers", "System_Theme_Hash_Differs", "pointers: pointers_system is not valid: the bytes do not have the hash of the entry of the resource"},
		{"processor_frame", "No_Canvas_Memory", "processor_frame: wrong: the budget of this process gave no memory for its canvases"},
		{"processor_frame", "Parts_Drawn", "processor_frame: ok, each part drew its pixels, the drawing module refused no call, and each table holds each of its records"},
		{"processors", "Thread_Not_Started", "processors: cannot start a thread"},
		{"processors", "No_Inspect_Grant", "processors: no grant to inspect the machine"},
		{"quic_echo", "Seed_Weak", "quic_echo: the random seed of this process is weak: it makes no key of a server, and listens on nothing"},
		{"randomness", "No_Random_Seed", "randomness: no random seed in the context"},
		{"randomness", "Entropy_Device_Absent", "randomness: the entropy device: absent"},
		{"return_fault", "Nested_Task_Not_Set", "return_fault: the child of the nested task: popfq did not set the flag, so the case did not run"},
		{"return_fault", "Nested_Task_Came_Back", "return_fault: the child of the nested task: the flag came back after the entry"},
		{"return_fault", "No_Trap", "return_fault: the child of the trap flag: no trap came"},
		{"return_fault", "No_Random_Seed", "return_fault: no random seed in the context"},
		{"return_fault", "No_Boot_Image", "return_fault: no boot image"},
		{"rings", "No_Random_Seed", "rings: no random seed in the context"},
		{"sample", "No_Service_Ring", "sample: no service ring"},
		{"sample", "Serving", "sample: serves its exports"},
		{"server", "No_Random_Seed", "server: no random seed in the context"},
		{"server", "No_Private_Store", "server: no private store: it serves no page of a store"},
		{"server", "New_Store", "server: a new store: no page"},
		{"tables", "No_Random_Seed", "tables: no random seed in the context"},
		{"tally", "Running", "tally: ok"},
		{"threads", "Thread_Not_Started", "threads: cannot start a thread"},
		{"tone", "Stream_Ring_Full", "tone: the stream ring is full"},
		{"tone", "No_Stream_Ring", "tone: no stream ring"},
		{"tone", "No_Sample_Region", "tone: no sample region"},
		{"tone", "Stream_Ring_Not_Mapped", "tone: the sound service does not map the stream ring"},
		{"tone", "Tone_Not_Ended", "tone: the tone did not end before the hang bound"},
		{"tone", "Tone_At_Its_Frame", "tone: the tone played at the frame of its time: as it must"},
		{"workers", "No_Addition_Lost", "workers: the lock lost no addition"},
		{"workers", "Thread_Not_Started", "workers: cannot start a thread"},
	}
	for fact in facts {
		file, ok := facts_file_of_demonstration(t, fact.folder)
		if !ok {
			continue
		}
		facts_expect_line(t, fact_test_render(t, file, fact.folder, fact.type_name, {}), fact.line)
	}
}

// demonstration_error_record_line gives the words of an error record as a
// fact of an error record writes them after its own words.
@(private = "file")
demonstration_error_record_line :: proc(head: string, kind: errors.Kind, unit: errors.Unit, signed: i64) -> string {
	return line_of_before(head, "kind ", errors.KIND_NAMES[kind], ", unit ", errors.UNIT_MEMBER_NAMES[unit], ", operation ", signed, ", argument ", -signed, ", value ", signed, ", limit ", -signed, ", found ", signed)
}

// Each fact of an error record of these demonstrations writes its own
// words, then each field of the record: each kind and each unit by its
// name, a signed field below 0 and at its edges.
@(test)
the_facts_of_error_records_of_the_demonstrations_write_each_field :: proc(t: ^testing.T) {
	Record_Fact :: struct {
		folder:    string,
		type_name: string,
		head:      string,
	}
	facts := [?]Record_Fact {
		{"net", "Other_Port_Refused", "net: UDP to 10.0.2.2 port 9: refused: "},
		{"net", "Other_Port_Refused_Wrong", "net: UDP to 10.0.2.2 port 9: WRONG: "},
		{"net", "Other_Address_Echo_Refused", "net: ICMP echo to 10.0.2.3: refused: "},
		{"net", "Other_Address_Echo_Refused_Wrong", "net: ICMP echo to 10.0.2.3: WRONG: "},
		{"net", "Large_Datagram_Refused", "net: UDP of 2000 bytes: refused, no fragment: "},
		{"net", "Large_Datagram_Refused_Wrong", "net: UDP of 2000 bytes: WRONG: "},
		{"net", "Key_Datagram_Refused", "net: a datagram to 10.0.2.2 port 7 after a key: refused, the endpoint has no grant now: "},
		{"net", "Key_Datagram_Refused_Otherwise", "net: a datagram to 10.0.2.2 port 7 after a key: refused: "},
		{"persistence_check", "Note_Write_Refused", "persistence_check: the storage service refused the object note: "},
		{"persistence_check", "Count_Write_Refused", "persistence_check: the storage service refused the object count: "},
		{"tables", "Memory_Object_To_Service_Refused", "tables: a memory object to the service: "},
		{"tables", "Memory_Object_To_Service_Wrong", "tables: wrong answer: a memory object to the service: "},
		{"tables", "Budget_As_Table_Memory_Refused", "tables: a budget as the memory of a table: "},
		{"tables", "Budget_As_Table_Memory_Wrong", "tables: wrong answer: a budget as the memory of a table: "},
		{"tables", "Count_Past_Its_Bound_Refused", "tables: a count of 2^40 rows: "},
		{"tables", "Count_Past_Its_Bound_Wrong", "tables: wrong answer: a count of 2^40 rows: "},
		{"tables", "Start_That_Wraps_Refused", "tables: a start that wraps: "},
		{"tables", "Start_That_Wraps_Wrong", "tables: wrong answer: a start that wraps: "},
	}
	signed_values := [4]i64{0, 1, -1, max(i64)}
	for fact in facts {
		file, ok := facts_file_of_demonstration(t, fact.folder)
		if !ok {
			continue
		}
		for kind in errors.Kind {
			for unit in errors.Unit {
				for signed in signed_values {
					written := fact_test_render(t, file, fact.folder, fact.type_name, {{"kind", u64(kind)}, {"unit", u64(unit)}, {"operation", signed_bits(signed)}, {"argument", signed_bits(-signed)}, {"value", signed_bits(signed)}, {"limit", signed_bits(-signed)}, {"found", signed_bits(signed)}})
					facts_expect_line(t, written, demonstration_error_record_line(fact.head, kind, unit, signed))
				}
			}
		}
		// The least i64 is written whole, with its sign.
		facts_expect_line(t, fact_test_render(t, file, fact.folder, fact.type_name, {{"value", signed_bits(min(i64))}}), line_of_before(fact.head, "kind None, unit None, operation 0, argument 0, value ", min(i64), ", limit 0, found 0"))
	}
}

// demonstration_hundredths_text gives a number of hundredths with two
// decimals, as a field Hundredths writes it.
@(private = "file")
demonstration_hundredths_text :: proc(hundredths: u64) -> string {
	return fmt.tprintf("%d.%02d", hundredths / 100, hundredths % 100)
}

// demonstration_tenth_of_microsecond_text gives a time in nanoseconds as
// microseconds with one decimal, cut, as a field
// Nanoseconds_As_Microseconds writes it.
@(private = "file")
demonstration_tenth_of_microsecond_text :: proc(nanoseconds: u64) -> string {
	return fmt.tprintf("%d.%d us", nanoseconds / 1000, nanoseconds / 100 % 10)
}

// The measures that were lines with one decimal are fields of hundredths
// with two decimals now; the measures of microseconds with one decimal
// write the line of before.
@(test)
the_measures_of_the_demonstrations_write_their_decimals :: proc(t: ^testing.T) {
	imports, imports_ok := facts_file_of_demonstration(t, "imports")
	randomness, randomness_ok := facts_file_of_demonstration(t, "randomness")
	elements, elements_ok := facts_file_of_demonstration(t, "interface_elements")
	frame, frame_ok := facts_file_of_demonstration(t, "processor_frame")
	net, net_ok := facts_file_of_demonstration(t, "net")
	if !imports_ok || !randomness_ok || !elements_ok || !frame_ok || !net_ok {
		return
	}
	// None, one hundredth, a zero after the point, and the largest that
	// the signed field holds.
	hundredths := [4]u64{0, 1, 1205, u64(max(i64))}
	for value in hundredths {
		text := demonstration_hundredths_text(value)
		for time in DEMONSTRATION_EDGE_TIMES {
			facts_expect_line(t, fact_test_render(t, imports, "imports", "Import_Call_Measured", {{"call", value}, {"replaced_call", value}, {"runs", time}, {"calls", max(u64)}}), line_of_before("imports: a call through an import slot: ", text, " ns to calendar, ", text, " ns to calendar_fixed in its place, the least of ", time, " runs of ", max(u64), " calls"))
			facts_expect_line(t, fact_test_render(t, imports, "imports", "Import_Bind_Measured", {{"bind", value}, {"checked_bind", value}, {"load", time}, {"replaced_load", u64(max(i64)) - time}}), line_of_before("imports: the bind of agenda: ", text, " ns, and ", text, " ns with the check of the replacement; the load of agenda and its import: ", time, " us, and ", u64(max(i64)) - time, " us"))
			facts_expect_line(t, fact_test_render(t, randomness, "randomness", "Generator_Measured", {{"elapsed", time}, {"rate", value}}), line_of_before("randomness: the generator: 4 MiB in ", time, " us, ", text, " MB/s"))
		}
		facts_expect_line(t, fact_test_render(t, net, "net", "Burst_Entries_Measured", {{"this_process", value}, {"network_service", value}, {"frame_service", value}}), line_of_before("net: kernel entries for each datagram: ", text, " of this process, ", text, " of the network service, ", text, " of the frame service"))
	}
	// A time of 812 499 ns is 812.4 us: the tenth is cut, not rounded.
	nanoseconds := [4]u64{0, 99, 812_499, u64(max(i64))}
	names := [2]string{strings.repeat("m", 18, context.temp_allocator), "a whole frame"}
	for value in nanoseconds {
		text := demonstration_tenth_of_microsecond_text(value)
		for name in names {
			for count in DEMONSTRATION_EDGE_COUNTS {
				facts_expect_line(t, fact_test_render(t, elements, "interface_elements", "Damage_Measured", {{"records", count}, {"rectangles", max(u64) - count}, {"window_percent", count}, {"difference", value}, {"measure", name}}), line_of_before("interface_elements: ", name, ": ", count, " records, ", max(u64) - count, " damage rectangles, ", count, " % of the window, the difference in ", text))
			}
		}
		for count in DEMONSTRATION_EDGE_COUNTS {
			other := max(u64) - count
			tail := line_of_before(": least ", text, ", median ", text, ", ", count, " frames in one second at the median, over ", other, " frames")
			measures := []Fact_Test_Field{{"least", value}, {"median", value}, {"frames", count}, {"rounds", other}}
			facts_expect_line(t, fact_test_render(t, frame, "processor_frame", "Clear_And_Present_Measured", measures), strings.concatenate({"processor_frame: measure: a clear and a present of 1920x1080", tail}, context.temp_allocator))
			facts_expect_line(t, fact_test_render(t, frame, "processor_frame", "Full_Frame_Measured", measures), strings.concatenate({"processor_frame: measure: a full frame of the compositor at 1920x1080 with 4 windows", tail}, context.temp_allocator))
			facts_expect_line(t, fact_test_render(t, frame, "processor_frame", "Damage_Frame_Measured", {{"pixels", other}, {"least", value}, {"median", value}, {"frames", count}, {"rounds", other}}), line_of_before("processor_frame: measure: a frame of the compositor at 1920x1080 with 4 windows in its damage of 2 rectangles, ", other, " pixels", tail))
			facts_expect_line(t, fact_test_render(t, frame, "processor_frame", "Draw_Table_Measured", {{"records", count}, {"opaque_rectangles", other}, {"cell_texts", count}, {"interface_texts", other}, {"opaque_pictures", count}, {"with_alpha", other}, {"least", value}, {"median", value}, {"frames", count}, {"rounds", other}}), line_of_before("processor_frame: measure: the execution of a draw table of 1920x1080 with ", count, " records: ", other, " opaque rectangles and gradients, ", count, " texts in the font of the cells, ", other, " in the interface font, ", count, " opaque pictures, ", other, " rectangles and pictures with alpha", tail))
		}
	}
}

// Each fact of kernel_events, locks, quic_echo, return_fault, rights,
// server and tone that replaced a line with a value writes the line of
// before, or its new sentence: a status by its name where the line wrote
// its number, a long line as several facts.
@(test)
the_facts_of_the_demonstrations_with_statuses_and_addresses_write_their_lines :: proc(t: ^testing.T) {
	events, events_ok := facts_file_of_demonstration(t, "kernel_events")
	locks, locks_ok := facts_file_of_demonstration(t, "locks")
	quic, quic_ok := facts_file_of_demonstration(t, "quic_echo")
	return_fault, return_fault_ok := facts_file_of_demonstration(t, "return_fault")
	rights, rights_ok := facts_file_of_demonstration(t, "rights")
	server, server_ok := facts_file_of_demonstration(t, "server")
	tone, tone_ok := facts_file_of_demonstration(t, "tone")
	if !events_ok || !locks_ok || !quic_ok || !return_fault_ok || !rights_ok || !server_ok || !tone_ok {
		return
	}
	addresses := [3]u64{0, 0xffff_8000_0000_1000, max(u64)}
	case_names := [2]string{strings.repeat("c", 52, context.temp_allocator), "the trap flag at a syscall"}
	for address in addresses {
		hex := sentence.Hex(address)
		for verdict in DEMONSTRATION_VERDICTS {
			for cause in op.Stop_Cause {
				for outcome in op.Stop_Outcome {
					facts_expect_line(t, fact_test_render(t, events, "kernel_events", "Fault_Once_Stopped", {{"records", u64(1)}, {"vector", u64(14)}, {"address", address}, {"cause", u64(cause)}, {"outcome", u64(outcome)}, {"verdict", verdict}}), line_of_before("kernel_events: a child that faults once: ", u64(1), " record of a fault that stopped it, vector ", u64(14), ", address ", hex, ", stopped: ", op.STOP_CAUSE_TEXTS[cause], ", ", op.STOP_OUTCOME_TEXTS[outcome], ": ", verdict))
					for name in case_names {
						facts_expect_line(t, fact_test_render(t, return_fault, "return_fault", "Child_Stopped_Itself", {{"address", address}, {"cause", u64(cause)}, {"outcome", u64(outcome)}, {"case_name", name}, {"verdict", verdict}}), line_of_before("return_fault: ", name, ": the child stopped: ", op.STOP_CAUSE_TEXTS[cause], ", ", op.STOP_OUTCOME_TEXTS[outcome], ", the address ", hex, ": ", verdict))
					}
				}
				facts_expect_line(t, fact_test_render(t, events, "kernel_events", "Fault_Once_Stopped_Without_Outcome", {{"records", max(u64)}, {"vector", u64(0)}, {"address", address}, {"cause", u64(cause)}, {"verdict", verdict}}), line_of_before("kernel_events: a child that faults once: ", max(u64), " record of a fault that stopped it, vector ", u64(0), ", address ", hex, ", stopped: ", op.STOP_CAUSE_TEXTS[cause], ": ", verdict))
				for name in case_names {
					facts_expect_line(t, fact_test_render(t, return_fault, "return_fault", "Child_Stopped_On_Fault", {{"address", address}, {"vector", max(u64)}, {"cause", u64(cause)}, {"case_name", name}, {"verdict", verdict}}), line_of_before("return_fault: ", name, ": the child stopped: ", op.STOP_CAUSE_TEXTS[cause], ", vector ", max(u64), ", the address ", hex, ": ", verdict))
					facts_expect_line(t, fact_test_render(t, return_fault, "return_fault", "Child_Stopped", {{"address", address}, {"cause", u64(cause)}, {"case_name", name}, {"verdict", verdict}}), line_of_before("return_fault: ", name, ": the child stopped: ", op.STOP_CAUSE_TEXTS[cause], ", the address ", hex, ": ", verdict))
				}
			}
			for count in DEMONSTRATION_EDGE_COUNTS {
				facts_expect_line(t, fact_test_render(t, events, "kernel_events", "Fault_Address_In_A_Record", {{"page_faults", count}, {"with_address", max(u64) - count}, {"address", address}, {"verdict", verdict}}), line_of_before("kernel_events: the address of a fault: a rule for every process: ", count, " page faults, ", max(u64) - count, " with an address; a rule that names the child: its first use at ", hex, " is in a record: ", verdict))
				facts_expect_line(t, fact_test_render(t, events, "kernel_events", "Fault_Address_In_No_Record", {{"page_faults", count}, {"with_address", max(u64) - count}, {"address", address}, {"verdict", verdict}}), line_of_before("kernel_events: the address of a fault: a rule for every process: ", count, " page faults, ", max(u64) - count, " with an address; a rule that names the child: its first use at ", hex, " is in no record: ", verdict))
			}
		}
		for count in DEMONSTRATION_EDGE_COUNTS {
			facts_expect_line(t, fact_test_render(t, events, "kernel_events", "Record_After_End", {{"end", count}, {"offset", address}}), line_of_before("kernel_events: 1000 gives and ends under load: WRONG: after the end ", count, ", the word at the offset ", hex, " of the memory object of the rings changed: a record written after the end"))
			for time in DEMONSTRATION_EDGE_TIMES {
				facts_expect_line(t, fact_test_render(t, server, "server", "Sink_Received", {{"body_size", time}, {"body_hash", address}, {"rate", count}}), line_of_before("server: received /sink: ", time, " bytes, fnv1a64 ", hex, ", ", count, " MB/s"))
			}
		}
	}
	// The cost line of kernel_events is one fact for each rule.
	for count in DEMONSTRATION_EDGE_COUNTS {
		other := max(u64) - count
		for time in DEMONSTRATION_EDGE_TIMES {
			head :: "kernel_events: kernel entries in one second of the load child (its own count and time): "
			facts_expect_line(t, fact_test_render(t, events, "kernel_events", "Cost_Without_Rule", {{"rate", count}, {"operations", other}, {"elapsed", time}}), line_of_before(head, "no rule ", count, " (", other, " operations in ", time, " ns)"))
			counted := []Fact_Test_Field{{"rate", count}, {"operations", other}, {"elapsed", time}, {"records", count}, {"lost", other}}
			facts_expect_line(t, fact_test_render(t, events, "kernel_events", "Cost_Rule_Of_Another_Process", counted), line_of_before(head, "a rule that names another process ", count, " (", other, " operations in ", time, " ns; ", count, " records + ", other, " lost, of 0)"))
			facts_expect_line(t, fact_test_render(t, events, "kernel_events", "Cost_Rule_Matching_Nothing", counted), line_of_before(head, "a rule for every process that matches nothing ", count, " (", other, " operations in ", time, " ns; ", count, " records + ", other, " lost, of 0)"))
			for verdict in DEMONSTRATION_VERDICTS {
				facts_expect_line(t, fact_test_render(t, events, "kernel_events", "Cost_Rule_Of_Each_Operation", {{"rate", count}, {"operations", other}, {"elapsed", time}, {"records", count}, {"lost", other}, {"total", count}, {"expected", other}, {"verdict", verdict}}), line_of_before(head, "a rule that accepts each of its operations ", count, " (", other, " operations in ", time, " ns; ", count, " records + ", other, " lost = ", count, ", of ", other, "): ", verdict))
			}
		}
		facts_expect_line(t, fact_test_render(t, locks, "locks", "Stress_Done", {{"started", count}, {"stopped", other}, {"closed_only", count}, {"pages", other}, {"pages_at_start", count}, {"processes", other}, {"processes_at_start", count}, {"threads", other}, {"threads_at_start", count}, {"free_pages", other}, {"budget_pages", count}, {"reserved_pages", other}}), line_of_before("locks: stress: ", count, " processes started, ", other, " stopped by this process (some by a thread while another thread closed the last handle), ", count, " only by the close of their last handle, while their threads ran and they stopped each other; budget: pages ", other, " of ", count, ", processes ", other, " of ", count, ", threads ", other, " of ", count, "; free pages ", other, ", in budgets ", count, ", reserved ", other))
		// The lock waits are one fact for each lock, and the frame caches
		// one fact for each processor.
		for lock in op.Lock_Kind {
			name := op.LOCK_KIND_NAMES[lock]
			facts_expect_line(t, fact_test_render(t, locks, "locks", "Entry_Lock_Waits", {{"waits", count}, {"takes", other}, {"lock", name}}), line_of_before("locks: lock waits of takes, 4 lockers, kernel entries: ", name, " ", count, " of ", other))
			facts_expect_line(t, fact_test_render(t, locks, "locks", "Fault_Lock_Waits", {{"waits", count}, {"takes", other}, {"lock", name}}), line_of_before("locks: lock waits of takes, 4 lockers, pages on first use: ", name, " ", count, " of ", other))
			facts_expect_line(t, fact_test_render(t, locks, "locks", "Pair_Lock_Waits", {{"waits", count}, {"takes", other}, {"lock", name}}), line_of_before("locks: lock waits of takes, word wait with 2 lockers: ", name, " ", count, " of ", other))
		}
		facts_expect_line(t, fact_test_render(t, locks, "locks", "Frame_Cache_Shown", {{"processor", count}, {"frames", other}, {"batches_taken", count}, {"batches_given", other}, {"drains", count}}), line_of_before("locks: frame caches after the measures (frames now, batches taken, batches given, drains): processor ", count, ": ", other, ", ", count, ", ", other, ", ", count))
		// The counts of quic_echo are two facts: one template holds at most
		// 512 bytes.
		facts_expect_line(t, fact_test_render(t, quic, "quic_echo", "Server_Counts", {{"accepted", count}, {"ended", other}, {"retries", count}, {"tokens_refused", other}, {"not_authentic", count}, {"too_small", other}, {"refused_by_limit", count}, {"refused_full", other}}), line_of_before("quic_echo: accepted ", count, ", ended ", other, ", Retries ", count, ", tokens refused ", other, ", not authentic ", count, ", too small ", other, ", Initials refused by a limit (each try of a client counts) ", count, ", Initials refused with a full table ", other))
		facts_expect_line(t, fact_test_render(t, quic, "quic_echo", "Server_Budget_Counts", {{"over_budget", count}, {"over_address_budget", other}, {"address_table_full", count}, {"tokens_used_again", other}, {"version_negotiations", count}, {"sends_refused", other}, {"last_send_status", count}}), line_of_before("quic_echo: over the budget ", count, ", over the budget of an address ", other, ", new addresses with no place in the table of address budgets ", count, ", tokens used again ", other, ", version negotiations ", count, ", Sends refused by the network service ", other, " (the last status ", count, ")"))
		facts_expect_line(t, fact_test_render(t, tone, "tone", "Tag_Unknown", {{"tag", count}}), line_of_before("tone: a completion with the tag ", count, " came, and no command has it"))
		facts_expect_line(t, fact_test_render(t, tone, "tone", "Status_Word_Unknown", {{"tag", count}, {"word", other}}), line_of_before("tone: the sound service answered the tag ", count, " with the word ", other, ", which names no status"))
		facts_expect_line(t, fact_test_render(t, tone, "tone", "Sample_Region_Refused", {{"status_word", count}}), line_of_before("tone: the sound service refused the sample region with the status ", count))
		facts_expect_line(t, fact_test_render(t, tone, "tone", "Start_Refused", {{"status_word", count}}), line_of_before("tone: the sound service refused Start with the status ", count))
		facts_expect_line(t, fact_test_render(t, tone, "tone", "Format_Unknown", {{"format", count}}), line_of_before("tone: the stream has the format ", count))
		facts_expect_line(t, fact_test_render(t, tone, "tone", "Tone_Refused", {{"status_word", count}}), line_of_before("tone: the sound service refused the tone with the status ", count))
		for time in DEMONSTRATION_EDGE_TIMES {
			facts_expect_line(t, fact_test_render(t, tone, "tone", "Tone_At_Another_Frame", {{"frame", count}, {"played_time", time}, {"expected_frame", other}, {"expected_time", u64(max(i64)) - time}}), line_of_before("tone: the tone played from the frame ", count, " at ", time, " ns; its time names the frame ", other, " at ", u64(max(i64)) - time, " ns"))
		}
	}
	commands := [2]string{"Attach", "Tone"}
	for command in commands {
		facts_expect_line(t, fact_test_render(t, tone, "tone", "Completion_Missing", {{"command", command}}), line_of_before("tone: no completion of ", command, " before the hang bound"))
	}
	// A status is written by its name, where the lines of locks, rights and
	// tone wrote its number.
	attempts := [2]string{strings.repeat("a", 44, context.temp_allocator), "map the memory with no right Map"}
	for status in op.Status {
		name := op.STATUS_NAMES[status]
		facts_expect_line(t, fact_test_render(t, locks, "locks", "Locker_Not_Started", {{"status", u64(status)}}), line_of_before("locks: cannot start a locker: status ", name))
		facts_expect_line(t, fact_test_render(t, tone, "tone", "Second_Give_Refused", {{"status", u64(status)}}), line_of_before("tone: the second give of the region gave the status ", name))
		for attempt in attempts {
			facts_expect_line(t, fact_test_render(t, rights, "rights", "Attempt_Wrong", {{"status", u64(status)}, {"attempt", attempt}}), line_of_before("rights: wrong answer: ", attempt, ": status ", name))
		}
	}
	// A word that names no status is written as its number.
	facts_expect_line(t, fact_test_render(t, locks, "locks", "Locker_Not_Started", {{"status", u64(max(u32))}}), line_of_before("locks: cannot start a locker: status ", u64(max(u32))))
	tone_cases := [2]string{strings.repeat("r", 35, context.temp_allocator), "a record at the frame 0"}
	signed_values := [4]i64{0, 1, -1, max(i64)}
	for name in tone_cases {
		for kind in errors.Kind {
			for unit in errors.Unit {
				for signed in signed_values {
					facts_expect_line(t, fact_test_render(t, tone, "tone", "Case_Answered_Wrong", {{"status_word", u64(7)}, {"kind", u64(kind)}, {"unit", u64(unit)}, {"argument", signed_bits(signed)}, {"case_name", name}}), line_of_before("tone: ", name, " got the status ", u64(7), ", the kind ", errors.KIND_NAMES[kind], ", the unit ", errors.UNIT_MEMBER_NAMES[unit], ", the argument ", signed))
				}
			}
		}
	}
	// The end of a connection by the application: the longest peer, end
	// cause and reason of a client, and short ones.
	peers := [2]string{strings.repeat("p", 26, context.temp_allocator), "10.0.2.2 port 7100"}
	end_causes := [2]string{strings.repeat("e", 22, context.temp_allocator), "closed by the client"}
	reasons := [2]string{strings.repeat("r", 48, context.temp_allocator), ""}
	for peer in peers {
		for end_cause in end_causes {
			for reason in reasons {
				for time in DEMONSTRATION_EDGE_TIMES {
					facts_expect_line(t, fact_test_render(t, quic, "quic_echo", "Connection_Ended_By_Application", {{"code", max(u64)}, {"frame_type", u64(0x1d)}, {"bytes_in", time}, {"bytes_out", u64(max(i64)) - time}, {"round_trip", time}, {"peer", peer}, {"end_cause", end_cause}, {"client_reason", reason}}), line_of_before("quic_echo: ", peer, " ended (", end_cause, ", the code ", sentence.Hex(max(u64)), " of the application, the frame type ", sentence.Hex(0x1d), ", the reason of the client \"", reason, "\"): in ", time, " bytes, out ", u64(max(i64)) - time, " bytes, srtt ", time, " us"))
				}
			}
		}
	}
}

// Each fact of net, pointers and tables that replaced a line with a text
// writes its sentence: the longest text of each Text field and a short
// one, and the mark of a wrong answer.
@(test)
the_facts_of_net_pointers_and_tables_write_their_texts :: proc(t: ^testing.T) {
	net, net_ok := facts_file_of_demonstration(t, "net")
	pointers, pointers_ok := facts_file_of_demonstration(t, "pointers")
	tables, tables_ok := facts_file_of_demonstration(t, "tables")
	imports, imports_ok := facts_file_of_demonstration(t, "imports")
	if !net_ok || !pointers_ok || !tables_ok || !imports_ok {
		return
	}
	marks := [2]string{"", " (WRONG)"}
	addresses := [2]string{"255.255.255.255", "10.0.2.15"}
	hardware_texts := [2]string{"ff:ff:ff:ff:ff:ff", "52:54:00:12:34:56"}
	for mark in marks {
		for address in addresses {
			for hardware in hardware_texts {
				for link in ([2]string{"up", "down"}) {
					facts_expect_line(t, fact_test_render(t, net, "net", "Link_And_Address", {{"address", address}, {"link", link}, {"hardware", hardware}, {"wrong_mark", mark}}), line_of_before("net: the link and the address: ", address, "/24, the link is ", link, ", ", hardware, mark))
				}
			}
			for time in DEMONSTRATION_EDGE_TIMES {
				facts_expect_line(t, fact_test_render(t, net, "net", "Echo_Server_Answered", {{"remote_port", u64(7)}, {"took", time}, {"remote", address}, {"wrong_mark", mark}}), line_of_before("net: UDP to 10.0.2.2 port 7, 41 bytes: the same 41 bytes came back from ", address, " port ", u64(7), " in ", time, " us", mark))
			}
		}
		for time in DEMONSTRATION_EDGE_TIMES {
			for hardware in hardware_texts {
				facts_expect_line(t, fact_test_render(t, net, "net", "Gateway_Resolved", {{"took", time}, {"hardware", hardware}, {"wrong_mark", mark}}), line_of_before("net: ARP: who has 10.0.2.2: the gateway answered ", hardware, " in ", time, " us", mark))
			}
			facts_expect_line(t, fact_test_render(t, net, "net", "Gateway_Echoed", {{"took", time}, {"time_to_live", u64(64)}, {"wrong_mark", mark}}), line_of_before("net: ICMP echo to 10.0.2.2, 56 bytes: the echo reply came in ", time, " us, time to live ", u64(64), mark))
		}
		for count in DEMONSTRATION_EDGE_COUNTS {
			other := max(u64) - count
			facts_expect_line(t, fact_test_render(t, net, "net", "Source_Port_Refused", {{"found_port", count}, {"local_port", other}, {"wrong_mark", mark}}), line_of_before("net: UDP from the source port 1234: refused: the source port ", count, " of the header is not the local port of this endpoint, ", other, mark))
			facts_expect_line(t, fact_test_render(t, net, "net", "Length_Field_Refused", {{"field_bytes", count}, {"send_bytes", other}, {"wrong_mark", mark}}), line_of_before("net: UDP with a wrong length field: refused: the length field of the header says ", count, " bytes, the Send has ", other, mark))
			facts_expect_line(t, fact_test_render(t, net, "net", "Short_Datagram_Refused", {{"send_bytes", count}, {"least_bytes", other}, {"wrong_mark", mark}}), line_of_before("net: UDP of 7 bytes: refused: the Send has ", count, " bytes, a datagram has ", other, " bytes at least, its header", mark))
			facts_expect_line(t, fact_test_render(t, net, "net", "Wrong_Checksum_Dropped", {{"datagrams", count}, {"wrong_mark", mark}}), line_of_before("net: UDP from 10.0.2.2 port 7 with a wrong checksum: dropped by this process: ", count, " datagram; the network service gave it to the endpoint of its port", mark))
			facts_expect_line(t, fact_test_render(t, net, "net", "Wrong_Checksums_Dropped", {{"datagrams", count}, {"wrong_mark", mark}}), line_of_before("net: UDP from 10.0.2.2 port 7 with a wrong checksum: dropped by this process: ", count, " datagrams; the network service gave it to the endpoint of its port", mark))
			facts_expect_line(t, fact_test_render(t, net, "net", "Endpoint_Row_Found", {{"from_port", count}, {"wrong_mark", mark}}), line_of_before("net: UDP from 10.0.2.2 port 9 to this endpoint: refused: from port ", count, "; a row of this endpoint", mark))
			facts_expect_line(t, fact_test_render(t, net, "net", "Machine_Rows_Found", {{"refused", count}, {"kinds", other}, {"found", count}, {"expected", other}, {"wrong_mark", mark}}), line_of_before("net: malformed frames from the wire: ", count, " refused in ", other, " kinds, ", count, " of ", other, " expected; no fault", mark))
			facts_expect_line(t, fact_test_render(t, net, "net", "Echo_Request_Answered", {{"requests", count}, {"wrong_mark", mark}}), line_of_before("net: ICMP echo from 10.0.2.2 to this machine: the network service answered ", count, " request", mark))
			facts_expect_line(t, fact_test_render(t, net, "net", "Echo_Requests_Answered", {{"requests", count}, {"wrong_mark", mark}}), line_of_before("net: ICMP echo from 10.0.2.2 to this machine: the network service answered ", count, " requests", mark))
		}
		facts_expect_line(t, fact_test_render(t, net, "net", "Machine_Rows_Not_Shown", {{"wrong_mark", mark}}), line_of_before("net: malformed frames from the wire: not shown: the grant has no right Inspect", mark))
		facts_expect_line(t, fact_test_render(t, net, "net", "Echo_Requests_Not_Shown", {{"wrong_mark", mark}}), line_of_before("net: ICMP echo from 10.0.2.2 to this machine: not shown: the grant has no right Inspect", mark))
	}
	// The faults of a pointer theme, for each theme and each place.
	Theme :: struct {
		name:            string,
		whole, entry, pixel: string,
	}
	themes := [2]Theme{{"pointers_posy", "Owner_Theme_Not_Valid", "Owner_Theme_Entry_Not_Valid", "Owner_Theme_Pixel_Not_Valid"}, {"pointers_system", "System_Theme_Not_Valid", "System_Theme_Entry_Not_Valid", "System_Theme_Pixel_Not_Valid"}}
	parts := [2]string{strings.repeat("p", 17, context.temp_allocator), "the header"}
	fields := [2]string{strings.repeat("f", 27, context.temp_allocator), "width"}
	rules := [2]string{strings.repeat("r", 60, context.temp_allocator), "is above its limit"}
	for theme in themes {
		head := line_of_before("pointers: ", theme.name, " is not valid: ")
		for part in parts {
			for field in fields {
				for rule in rules {
					for count in DEMONSTRATION_EDGE_COUNTS {
						other := max(u64) - count
						tail := line_of_before(": ", field, " ", rule, " (value ", count, ", limit ", other, ")")
						facts_expect_line(t, fact_test_render(t, pointers, "pointers", theme.whole, {{"value", count}, {"limit", other}, {"part", part}, {"field", field}, {"rule", rule}}), strings.concatenate({head, part, tail}, context.temp_allocator))
						facts_expect_line(t, fact_test_render(t, pointers, "pointers", theme.entry, {{"index", other}, {"value", count}, {"limit", other}, {"part", part}, {"field", field}, {"rule", rule}}), line_of_before(head, part, ", entry ", other, tail))
						facts_expect_line(t, fact_test_render(t, pointers, "pointers", theme.pixel, {{"index", other}, {"value", count}, {"limit", other}, {"part", part}, {"field", field}, {"rule", rule}}), line_of_before(head, part, ", pixel ", other, tail))
					}
				}
			}
		}
	}
	// The answers of the cases of tables and imports.
	table_cases := [2]string{strings.repeat("c", 37, context.temp_allocator), "a count of 0 rows"}
	answers := [2]string{strings.repeat("a", 87, context.temp_allocator), "Ok"}
	call_ways := [2]string{"call host", "direct"}
	for name in table_cases {
		for answer in answers {
			facts_expect_line(t, fact_test_render(t, tables, "tables", "Hostile_Answer", {{"case_name", name}, {"answer", answer}}), line_of_before("tables: ", name, ": ", answer))
			facts_expect_line(t, fact_test_render(t, tables, "tables", "Hostile_Answer_Wrong", {{"case_name", name}, {"answer", answer}}), line_of_before("tables: wrong answer: ", name, ": ", answer))
			for way in call_ways {
				facts_expect_line(t, fact_test_render(t, tables, "tables", "Answer_Wrong", {{"case_name", name}, {"call_way", way}, {"answer", answer}}), line_of_before("tables: wrong answer: ", name, ", ", way, ": ", answer))
			}
		}
	}
	import_cases := [2]string{strings.repeat("c", 52, context.temp_allocator), "an import of a module that is not in the image"}
	for name in import_cases {
		for answer in answers {
			facts_expect_line(t, fact_test_render(t, imports, "imports", "Answer_Wrong", {{"case_text", name}, {"answer", answer}}), line_of_before("imports: wrong answer: ", name, ": ", answer))
		}
	}
	// The status of a call is written by its name, and a word that names
	// no status by its number.
	measure_ways := [2]string{strings.repeat("w", 24, context.temp_allocator), "direct call"}
	for way in measure_ways {
		for count in DEMONSTRATION_EDGE_COUNTS {
			other := max(u64) - count
			for status in call_status.Call_Status {
				facts_expect_line(t, fact_test_render(t, tables, "tables", "Measure_Call_Refused", {{"rows", count}, {"call", other}, {"status", u64(status)}, {"way", way}}), line_of_before("tables: ", way, ", ", count, " rows: call ", other, " gave the status ", call_status.CALL_STATUS_NAMES[status]))
			}
			facts_expect_line(t, fact_test_render(t, tables, "tables", "Measure_Call_Refused", {{"rows", count}, {"call", other}, {"status", max(u64)}, {"way", way}}), line_of_before("tables: ", way, ", ", count, " rows: call ", other, " gave the status ", max(u64)))
		}
	}
}

// Each start that failed writes the fact of its status and of its budgets:
// each status by its name, a word that names no status by its number, and
// the counts at their edges.
@(test)
the_refused_starts_of_the_demonstrations_write_their_statuses :: proc(t: ^testing.T) {
	events, events_ok := facts_file_of_demonstration(t, "kernel_events")
	scheduler, scheduler_ok := facts_file_of_demonstration(t, "scheduler")
	tables, tables_ok := facts_file_of_demonstration(t, "tables")
	if !events_ok || !scheduler_ok || !tables_ok {
		return
	}
	Status_Case :: struct {
		word: u64,
		text: string,
	}
	statuses := make([dynamic]Status_Case, context.temp_allocator)
	for status in op.Status {
		append(&statuses, Status_Case{u64(status), op.STATUS_NAMES[status]})
	}
	append(&statuses, Status_Case{max(u64), "18446744073709551615"})
	children := [2]string{"the child that faults", "the load child"}
	names := [2]string{"started_under_policy", "spinner_1"}
	for status in statuses {
		facts_expect_line(t, fact_test_render(t, tables, "tables", "Call_Host_Not_Started", {{"status", status.word}}), line_of_before("tables: the call host did not start: status ", status.text))
		for count in DEMONSTRATION_EDGE_COUNTS {
			other := max(u64) - count
			for child in children {
				facts_expect_line(t, fact_test_render(t, events, "kernel_events", "Child_Start_Refused", {{"status", status.word}, {"given_pages", count}, {"given_processes", other}, {"given_threads", count}, {"given_processor", other}, {"given_log_records", count}, {"asked_pages", other}, {"asked_processes", count}, {"asked_threads", other}, {"asked_processor", count}, {"asked_log_records", other}, {"child", child}}), line_of_before("kernel_events: ", child, ": process_start failed: ", status.text, "; this process can give pages ", count, ", processes ", other, ", threads ", count, ", processor ", other, ", log records ", count, "; the child asks pages ", other, ", processes ", count, ", threads ", other, ", processor ", count, ", log records ", other))
			}
			for name in names {
				facts_expect_line(t, fact_test_render(t, scheduler, "scheduler", "Share_Process_Not_Started", {{"status", status.word}, {"given_pages", count}, {"given_processes", other}, {"given_threads", count}, {"asked_pages", other}, {"asked_threads", count}, {"process_name", name}}), line_of_before("scheduler: the process ", name, " did not start: ", status.text, "; this process can give pages ", count, ", processes ", other, ", threads ", count, "; the process asks pages ", other, ", threads ", count))
			}
		}
	}
}

// demonstration_load_fact_render gives the sentence of a fact of a load
// error with the record that the procedure of its shape made.
@(private = "file")
demonstration_load_fact_render :: proc(t: ^testing.T, file: []u8, package_name, type_name: string, shape: $T) -> string {
	shape_bytes := transmute([size_of(T)]u8)shape
	record := shape_bytes[:]
	key := fact_key(package_name, type_name)
	_, _, description, found := module.fact_find(file, key)
	if !testing.expectf(t, found, "the module file has no fact type %s.%s", package_name, type_name) {
		return ""
	}
	if !testing.expectf(t, int(description.size) == len(record), "the fact type %s.%s has %d bytes, its shape %d", package_name, type_name, description.size, len(record)) {
		return ""
	}
	buffer: [module.FACT_SENTENCE_BYTES_MOST]u8
	count, _, refusal := module.fact_sentence_write(file, key, record, buffer[:], nil)
	if !testing.expectf(t, refusal == .None && count <= len(buffer), "the fact %s.%s is refused: %v", package_name, type_name, refusal) {
		return ""
	}
	return strings.clone(string(buffer[:count]), context.temp_allocator)
}

// demonstration_named gives a module of a load error: its name, and a hash
// whose bytes start at first.
@(private = "file")
demonstration_named :: proc(name: string, first: u8) -> (named: module.Named) {
	copy(named.name[:], name)
	for index in 0 ..< len(named.hash) {
		named.hash[index] = first + u8(index)
	}
	return named
}

// demonstration_hash_head gives the head of a hash as a fact writes it.
@(private = "file")
demonstration_hash_head :: proc(named: module.Named) -> string {
	hash := named.hash
	return fmt.tprintf("%02x%02x%02x%02x%s", hash[0], hash[1], hash[2], hash[3], value_kinds.HASH_HEAD_MARK)
}

// A load error of each stage, made as the loader makes it, gives the fact
// of its stage through the procedure of its shape, in each of the three
// demonstrations: the longest name, a short one and no name, each member of
// the enum of a stage, and the parameter and the import slot at their edges.
@(test)
the_load_errors_of_the_demonstrations_write_each_stage :: proc(t: ^testing.T) {
	Load_Fact_Module :: struct {
		folder:    string,
		type_head: string,
		head:      string,
	}
	modules := [3]Load_Fact_Module{{"kernel_events", "Child_Load_", "kernel_events: the load of the child: "}, {"scheduler", "Share_Load_", "scheduler: the load of a process of the share policy: "}, {"tables", "Call_Host_Load_", "tables: the load of the call host: "}}
	names := [3]string{strings.repeat("m", module.NAME_SIZE, context.temp_allocator), "calendar", ""}
	edges := [3]u32{0, 1, max(u32)}
	for item in modules {
		file, ok := facts_file_of_demonstration(t, item.folder)
		if !ok {
			continue
		}
		type_name :: proc(head, stage: string) -> string {
			return strings.concatenate({head, stage, "_Failed"}, context.temp_allocator)
		}
		for name in names {
			error: module.Load_Error
			error.module = demonstration_named(name, 0x1a)
			error.imported = demonstration_named("agenda", 0xf0)
			error.replacement = demonstration_named("calendar_fixed", 0x00)
			copy(error.export[:], name)
			own := name
			agenda := "agenda"

			error.stage = u32(module.Load_Stage.Find)
			find := module.load_find_fact_fields(&error)
			facts_expect_line(t, demonstration_load_fact_render(t, file, item.folder, type_name(item.type_head, "Find"), find), line_of_before(item.head, "the load of ", own, " (", demonstration_hash_head(error.module), ") found no file of its import ", agenda, " (", demonstration_hash_head(error.imported), ")"))

			error.stage = u32(module.Load_Stage.Read)
			for file_error in module.Error {
				error.file_error = u32(file_error)
				read := module.load_read_fact_fields(&error)
				// The stage concerns the import: it has a hash.
				facts_expect_line(t, demonstration_load_fact_render(t, file, item.folder, type_name(item.type_head, "Read"), read), line_of_before(item.head, "the file of ", agenda, " (", demonstration_hash_head(error.imported), ") does not have the hash that names it, or is not a valid module: ", module.ERROR_NAMES[file_error]))
			}

			error.stage = u32(module.Load_Stage.Cycle)
			cycle := module.load_cycle_fact_fields(&error)
			facts_expect_line(t, demonstration_load_fact_render(t, file, item.folder, type_name(item.type_head, "Cycle"), cycle), line_of_before(item.head, "an import cycle: ", own, " imports ", agenda, ", and ", "calendar_fixed", " still loads its imports"))

			error.stage = u32(module.Load_Stage.Check)
			for difference in module.Difference {
				for parameter in edges {
					error.difference, error.parameter = u32(difference), parameter
					check := module.load_check_fact_fields(&error)
					facts_expect_line(t, demonstration_load_fact_render(t, file, item.folder, type_name(item.type_head, "Check"), check), line_of_before(item.head, own, " imports ", agenda, ", and its replacement fails the check: export ", own, ": ", module.DIFFERENCE_NAMES[difference], ", parameter ", u64(parameter)))
				}
			}

			error.stage = u32(module.Load_Stage.Bind)
			for import_slot in edges {
				error.import_slot = import_slot
				bind := module.load_bind_fact_fields(&error)
				facts_expect_line(t, demonstration_load_fact_render(t, file, item.folder, type_name(item.type_head, "Bind"), bind), line_of_before(item.head, "import slot ", u64(import_slot), " of ", own, " cannot be bound: export ", own, " of ", agenda))
			}

			// Map and Unmap: each status by its name, and a word that names
			// no status by its number.
			stages := [2]module.Load_Stage{.Map, .Unmap}
			verbs := [2]string{"map", "remove"}
			for stage, index in stages {
				error.stage = u32(stage)
				for status in op.Status {
					error.status = u32(status)
					memory := module.load_memory_fact_fields(&error)
					facts_expect_line(t, demonstration_load_fact_render(t, file, item.folder, type_name(item.type_head, index == 0 ? "Map" : "Unmap"), memory), line_of_before(item.head, "the kernel refused to ", verbs[index], " ", own, " (", demonstration_hash_head(error.module), "): status ", op.STATUS_NAMES[status]))
				}
				error.status = max(u32)
				memory := module.load_memory_fact_fields(&error)
				facts_expect_line(t, demonstration_load_fact_render(t, file, item.folder, type_name(item.type_head, index == 0 ? "Map" : "Unmap"), memory), line_of_before(item.head, "the kernel refused to ", verbs[index], " ", own, " (", demonstration_hash_head(error.module), "): status ", u64(max(u32))))
			}

			error.stage = u32(module.Load_Stage.Room)
			room := module.load_room_fact_fields(&error)
			facts_expect_line(t, demonstration_load_fact_render(t, file, item.folder, type_name(item.type_head, "Room"), room), line_of_before(item.head, "no room for ", own, " (", demonstration_hash_head(error.module), "): a process has 16 modules at most, a module 8 imports, a table of prepared modules 64 parts, and its modules fit below the fixed ranges of the system"))
		}
	}
}
