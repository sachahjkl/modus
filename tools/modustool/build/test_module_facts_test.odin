package build

import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "core:strings"
import "core:testing"
import "modustool:foundation"

// The log facts of the test modules against the lines that they replaced
// (src/md/features/log_facts.md). The fact types come from the extraction
// of the tool on the sources of each module: a host test does not depend
// on a build. Each sentence is compared with the parts of the old line
// written by sentence.format, at the edges of each field. The helpers are
// in fact_test_helpers_test.odin.

// The longest name of a call of Log that log_reader gives to the kernel
// for a refusal, and the longest name of an edge that Log takes.
@(private = "file")
REFUSAL_NAME_LONGEST :: "a fact at the level one past the last member"
@(private = "file")
EDGE_NAME_LONGEST :: "one byte on the last byte of a mapped page"

// The folders of the test modules that write log facts.
@(private = "file")
TEST_FACT_FOLDERS := [?]string{"arena", "debug_target", "disk_start_policy", "flood", "hierarchy", "hostile_terminal", "iommu_device", "ranges", "shortage", "store_importer", "visitor", "log_reader"}

// The edges of a count, of a signed count, and of a time in milliseconds:
// a Time field is signed, so its largest value is max(i64).
@(private = "file")
TEST_FACT_COUNTS := [3]u64{0, 1, max(u64)}
@(private = "file")
TEST_FACT_SIGNED := [3]i64{-1, 0, max(i64)}
@(private = "file")
TEST_FACT_TIMES := [2]u64{0, u64(max(i64))}

// test_facts_file gives the module file of the fact types of one test
// module.
@(private = "file")
test_facts_file :: proc(t: ^testing.T, folder: string) -> (file: []u8, ok: bool) {
	return facts_file_of_folder(t, strings.concatenate({foundation.TEST_MODULE_SOURCES, folder}, context.temp_allocator))
}

// Each fact type of the test modules with a Text field ends with its Text
// fields, and each Text field holds the longest text of its writer and a
// zero byte.
@(test)
the_texts_of_the_test_module_facts_come_last_and_whole :: proc(t: ^testing.T) {
	most := make(map[string]u32, context.temp_allocator)
	most["started_process"] = value_kinds.MODULE_NAME_FIELD_BYTES - 1
	most["child"] = value_kinds.MODULE_NAME_FIELD_BYTES - 1
	most["caller"] = value_kinds.MODULE_NAME_FIELD_BYTES - 1
	most["service"] = value_kinds.MODULE_NAME_FIELD_BYTES - 1
	most["refusal"] = len(REFUSAL_NAME_LONGEST)
	most["edge"] = len(EDGE_NAME_LONGEST)
	for folder in TEST_FACT_FOLDERS {
		file, ok := test_facts_file(t, folder)
		if ok {
			facts_expect_text_fields_last(t, file, most)
		}
	}
}

// Each fact type of arena, debug_target, flood, hostile_terminal,
// iommu_device, store_importer and visitor writes the line of before, byte
// for byte: the counts 0, 1 and max(u64), the kind words of the test and
// the largest, and the times 0 and max(i64).
@(test)
the_facts_of_the_small_test_modules_write_the_lines_of_before :: proc(t: ^testing.T) {
	arena_file, arena_ok := test_facts_file(t, "arena")
	debug_file, debug_ok := test_facts_file(t, "debug_target")
	flood_file, flood_ok := test_facts_file(t, "flood")
	terminal_file, terminal_ok := test_facts_file(t, "hostile_terminal")
	iommu_file, iommu_ok := test_facts_file(t, "iommu_device")
	importer_file, importer_ok := test_facts_file(t, "store_importer")
	visitor_file, visitor_ok := test_facts_file(t, "visitor")
	if !arena_ok || !debug_ok || !flood_ok || !terminal_ok || !iommu_ok || !importer_ok || !visitor_ok {
		return
	}
	for count in TEST_FACT_COUNTS {
		other := max(u64) - count
		facts_expect_line(t, fact_test_render(t, arena_file, "arena", "Arena_Grew", {{"committed_pages", count}, {"commits", other}, {"reservation_pages", count}, {"pushes", other}, {"budget_pages_before", count}, {"budget_pages_after", other}}), line_of_before("arena: grew to ", count, " pages in ", other, " commits, in a reservation of ", count, " pages, and gave ", other, " pushes of one page; the budget held ", count, " pages before, and ", other, " after the refusal"))
		facts_expect_line(t, fact_test_render(t, arena_file, "arena", "Wrong_Pushes", {{"pushes", count}, {"nonzero_pages", other}}), line_of_before("arena: WRONG: ", count, " pushes, and ", other, " pages that did not read zero before their first write"))
		facts_expect_line(t, fact_test_render(t, debug_file, "debug_target", "Wrong_Totals", {{"wrong_totals", count}}), line_of_before("debug_target: 64 more rounds ran, and ", count, " rounds gave a wrong total: WRONG"))
		facts_expect_line(t, fact_test_render(t, flood_file, "flood", "Lines_Paused", {{"last_line", count}}), line_of_before("flood: Space: no more lines after ", count))
		facts_expect_line(t, fact_test_render(t, iommu_file, "iommu_device_service", "Undeclared_Read_Given_Back", {{"device_status", count}}), line_of_before("iommu_device: a read into a page that was not declared: the device gave the request back with the status ", count, ", and the page keeps its 4096 bytes: as it must"))
		facts_expect_line(t, fact_test_render(t, importer_file, "store_importer", "Wrong_Result", {{"result", count}}), line_of_before("store_importer: triple(14) gives ", count, ", and 42 is the answer: WRONG"))
		facts_expect_line(t, fact_test_render(t, visitor_file, "visitor", "Wrong_Grant_Handles", {{"grant_handles", count}}), line_of_before("visitor: the context holds ", count, " handles of a grant: WRONG"))
		facts_expect_line(t, fact_test_render(t, visitor_file, "visitor", "Wrong_Count_Size", {{"count_bytes", count}}), line_of_before("visitor: the count in the store has ", count, " bytes, not 8: WRONG"))
		facts_expect_line(t, fact_test_render(t, visitor_file, "visitor", "Visit_Read_Again", {{"visit", count}}), line_of_before("visitor: the store of its nickname holds the visit ", count, ", read again: as it must"))
	}
	// The kind words that the test sends, and the largest word.
	words := [?]u64{0, 9, u64(max(u32)), max(u64)}
	for word in words {
		facts_expect_line(t, fact_test_render(t, terminal_file, "hostile_terminal", "Kind_Words_Read", {{"first_word", word}, {"second_word", u64(9)}, {"third_word", max(u64) - word}}), line_of_before("hostile_terminal: the terminal read the kind words ", word, ", ", u64(9), " and ", max(u64) - word, ", and the line after them: as it must"))
	}
	for time in TEST_FACT_TIMES {
		facts_expect_line(t, fact_test_render(t, terminal_file, "hostile_terminal", "Wrong_Records_Not_Read", {{"bound", time}}), line_of_before("hostile_terminal: WRONG: the terminal did not read its records in ", time, " ms"))
	}
}

// Each fact type of disk_start_policy writes the line of before, byte for
// byte: a process name of 31 bytes, the longest that its field holds with
// its zero byte, and a short one; the counts 0, 1 and max(u64).
@(test)
the_facts_of_disk_start_policy_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := test_facts_file(t, "disk_start_policy")
	if !ok {
		return
	}
	names := [2]string{strings.repeat("p", value_kinds.MODULE_NAME_FIELD_BYTES - 1, context.temp_allocator), "input"}
	for name in names {
		facts_expect_line(t, fact_test_render(t, file, "disk_start_policy", "Not_Started_Without_Screen", {{"started_process", name}}), line_of_before("disk_start_policy: ", name, " is not started: the machine has no screen"))
		facts_expect_line(t, fact_test_render(t, file, "disk_start_policy", "Started", {{"started_process", name}}), line_of_before("disk_start_policy: started ", name))
	}
	for count in TEST_FACT_COUNTS {
		facts_expect_line(t, fact_test_render(t, file, "disk_start_policy", "Wrong_Context", {{"other_handles", count}, {"list_bytes", max(u64) - count}}), line_of_before("disk_start_policy: the context holds ", count, " other handles and a list of ", max(u64) - count, " bytes: WRONG"))
	}
}

// Each fact type of hierarchy and of ranges writes the line of before,
// byte for byte: the signed counts -1, 0 and max(i64), the counts 0, 1 and
// max(u64), and the times 0 and max(i64).
@(test)
the_facts_of_hierarchy_and_ranges_write_the_lines_of_before :: proc(t: ^testing.T) {
	hierarchy_file, hierarchy_ok := test_facts_file(t, "hierarchy")
	ranges_file, ranges_ok := test_facts_file(t, "ranges")
	if !hierarchy_ok || !ranges_ok {
		return
	}
	for objects in TEST_FACT_SIGNED {
		facts_expect_line(t, fact_test_render(t, hierarchy_file, "hierarchy", "Store_Remounted", {{"objects", signed_bits(objects)}}), line_of_before("hierarchy: a store with ", objects, " objects: the run after the remount"))
		facts_expect_line(t, fact_test_render(t, ranges_file, "ranges", "Store_Remounted", {{"objects", signed_bits(objects)}}), line_of_before("ranges: a store with ", objects, " objects: the run after the remount"))
		for time in TEST_FACT_TIMES {
			facts_expect_line(t, fact_test_render(t, hierarchy_file, "hierarchy", "Objects_Made", {{"objects", signed_bits(objects)}, {"commits", max(u64) - time}, {"elapsed", time}}), line_of_before("hierarchy: ", objects, " objects made in ", max(u64) - time, " commits, in ", time, " ms"))
		}
	}
	for count in TEST_FACT_COUNTS {
		facts_expect_line(t, fact_test_render(t, hierarchy_file, "hierarchy", "Run_Done", {{"wrong_cases", count}}), line_of_before("hierarchy: done, ", count, " wrong"))
		facts_expect_line(t, fact_test_render(t, ranges_file, "ranges", "Run_Done", {{"wrong_cases", count}}), line_of_before("ranges: done, ", count, " wrong"))
		other := max(u64) - count
		for time in TEST_FACT_TIMES {
			measure := []Fact_Test_Field{{"changed", count}, {"object_blocks", other}, {"hashed_blocks", count}, {"hashed_nodes", other}, {"written", count}, {"elapsed", time}}
			facts_expect_line(t, fact_test_render(t, ranges_file, "ranges", "Sparse_Object_Committed", measure), line_of_before("ranges: ", "the commit of the sparse object: ", count, " blocks changed of ", other, ", ", count, " blocks and ", other, " object nodes hashed, ", count, " blocks written, in ", time, " ms"))
			facts_expect_line(t, fact_test_render(t, ranges_file, "ranges", "Scrambled_Writes_Committed", measure), line_of_before("ranges: ", "1000 writes at scrambled offsets, then one commit: ", count, " blocks changed of ", other, ", ", count, " blocks and ", other, " object nodes hashed, ", count, " blocks written, in ", time, " ms"))
			facts_expect_line(t, fact_test_render(t, ranges_file, "ranges", "Loop_Commits_Made", {{"commits", count}, {"elapsed", time}}), line_of_before("ranges: loop, ", count, " commits of 4 range writes, in ", time, " ms"))
		}
	}
	for time in TEST_FACT_TIMES {
		facts_expect_line(t, fact_test_render(t, ranges_file, "ranges", "Range_Writes_Pending", {{"elapsed", time}}), line_of_before("ranges: 1000 range writes at scrambled offsets are pending, in ", time, " ms"))
		facts_expect_line(t, fact_test_render(t, ranges_file, "ranges", "Cases_Done", {{"elapsed", time}}), line_of_before("ranges: the cases took ", time, " ms"))
	}
}

// Each fact type of shortage writes the line of before, byte for byte: the
// counts 0, 1 and max(u64), and the times 0 and max(i64).
@(test)
the_facts_of_shortage_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := test_facts_file(t, "shortage")
	if !ok {
		return
	}
	for count in TEST_FACT_COUNTS {
		other := max(u64) - count
		facts_expect_line(t, fact_test_render(t, file, "shortage", "Started", {{"payable_pages", count}, {"own_pages", other}, {"processors", count}}), line_of_before("shortage: start: ", count, " free pages that budgets can pay, ", other, " of them in the budget of this process, ", count, " processors"))
		for time in TEST_FACT_TIMES {
			facts_expect_line(t, fact_test_render(t, file, "shortage", "Freed", {{"elapsed", time}, {"budget_pages", count}, {"own_pages", other}, {"kept_pages", count}, {"payable_pages_after", other}, {"payable_pages_before", count}}), line_of_before("shortage: freed in ", time, " ms; the budget holds ", count, " pages of ", other, " (", count, " pages kept); the free pages that budgets can pay: ", other, " of ", count))
		}
	}
}

// Each fact type of log_reader writes the line of before, byte for byte:
// the counts 0, 1 and max(u64), the signed counts -1, 0 and max(i64), each
// status, each stop cause with each outcome of a stop of itself, the name
// of a process of 31 bytes and each name of a child, the longest name of a
// refused call and of an edge. A status or a stop cause past the last
// member writes its number, never the name of another member.
@(test)
the_facts_of_log_reader_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := test_facts_file(t, "log_reader")
	if !ok {
		return
	}
	render :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
		return fact_test_render(t, file, "log_reader", type_name, values)
	}
	children := [?]string{"log_reader child 1", "log_reader child 2", "log_reader storm", strings.repeat("c", value_kinds.MODULE_NAME_FIELD_BYTES - 1, context.temp_allocator)}
	refusals := [?]string{REFUSAL_NAME_LONGEST, "the address 0"}
	edges := [?]string{EDGE_NAME_LONGEST, "a text of 0 bytes"}

	for count in TEST_FACT_COUNTS {
		other := max(u64) - count
		facts_expect_line(t, render(t, file, "Wrong_Other_Rows", {{"other_rows", count}}), line_of_before("log_reader: WRONG: the log service gave ", count, " rows of other processes"))
		facts_expect_line(t, render(t, file, "Wrong_Other_Runs", {{"other_runs", count}}), line_of_before("log_reader: WRONG: the log service gave ", count, " value runs of other records"))
		facts_expect_line(t, render(t, file, "Own_Value_Runs_Read", {{"runs", count}, {"own_value", other}}), line_of_before("log_reader: the value runs: ", count, " rows, each of a record of this process, with the run of its value ", other, ": as it must"))
		facts_expect_line(t, render(t, file, "Own_Log_Rings_Kept", {{"storm_records", count}, {"whole_log_capacity", other}}), line_of_before("log_reader: a child wrote ", count, " records after the records of this process and of its two children, more than the ", other, " that the whole log keeps, and the own log ring of each one kept its records: as it must"))
		facts_expect_line(t, render(t, file, "Storm_Log_Records_Taken", {{"storm_log_records", count}, {"whole_log_records", other}, {"kept_log_records", count}}), line_of_before("log_reader: the storm child took ", count, " of the ", other, " log records of each second of this process, which kept ", count, ", and each child gave its records back at its stop: as it must"))
		facts_expect_line(t, render(t, file, "Facts_Written", {{"head_bytes", count}, {"whole_bytes", other}}), line_of_before("log_reader: Log wrote a fact of ", count, " bytes and a fact of ", other, " bytes, and system.log_fact the fact Fact_Probe, each in one record: as it must"))
		facts_expect_line(t, render(t, file, "Facts_Read_Back", {{"whole_value_bytes", count}, {"probe_value_bytes", other}}), line_of_before("log_reader: the three facts read back: the form Fact, no next record, the reserved bytes 0, the key of each writer, 0, ", count, " and ", other, " value bytes, and the hash of this module in the fact of system.log_fact: as it must"))
		facts_expect_line(t, render(t, file, "Wrong_Refused_Calls_Changed_Budget", {{"log_records_before", count}, {"refused_before", other}, {"log_records_after", other}, {"refused_after", count}}), line_of_before("log_reader: WRONG: the budget held ", count, " log records and counted ", other, " refused before the refused calls of Log, and ", other, " and ", count, " after them"))
		facts_expect_line(t, render(t, file, "Texts_Written", {{"text_bytes", count}, {"text_records", other}, {"call_runs", count}, {"kept_runs", other}}), line_of_before("log_reader: Log wrote a text of 0 bytes, of 1 byte and of ", count, " bytes in 1, 1 and ", other, " records, a text at the level Error, a text with ", count, " runs that keeps ", other, ", and one byte on the last byte of a page: as it must"))
		facts_expect_line(t, render(t, file, "Wrong_Children_Records_Held", {{"held_log_records", count}, {"whole_log_records", other}}), line_of_before("log_reader: WRONG: after the stop of the two children, this process holds ", count, " log records of each second, and not ", other))
		facts_expect_line(t, render(t, file, "Wrong_Storm_Records_Kept", {{"kept_log_records", count}, {"whole_log_records", other}}), line_of_before("log_reader: WRONG: while the storm child runs, this process holds ", count, " log records of each second of its ", other))
		facts_expect_line(t, render(t, file, "Wrong_Storm_Records_Held", {{"held_log_records", count}, {"whole_log_records", other}}), line_of_before("log_reader: WRONG: after the stop of the storm child, this process holds ", count, " log records of each second, and not ", other))
		for child in children {
			facts_expect_line(t, render(t, file, "Wrong_Child_Other_Rows", {{"other_rows", count}, {"child", child}}), line_of_before("log_reader: WRONG: the records of ", child, ": ", count, " rows of another process"))
			facts_expect_line(t, render(t, file, "Wrong_Child_Rows", {{"rows", count}, {"child", child}}), line_of_before("log_reader: WRONG: the records of ", child, ": ", count, " rows; one row, its record with the number 0 and lost 0, was the answer"))
			facts_expect_line(t, render(t, file, "Wrong_Child_Runs", {{"runs", count}, {"child", child}}), line_of_before("log_reader: WRONG: the value runs of ", child, ": ", count, " rows; one row, the run of its value, was the answer"))
			facts_expect_line(t, render(t, file, "Child_Records_Read", {{"rows", count}, {"child", child}}), line_of_before("log_reader: the records of ", child, ": ", count, " rows from the own number 0, its one record, lost 0: no row of this process, of the other child or of an earlier run: as it must"))
			facts_expect_line(t, render(t, file, "Child_Value_Runs_Read", {{"runs", count}, {"child_value", other}, {"child", child}}), line_of_before("log_reader: the value runs of ", child, ": ", count, " rows, the run of its value ", other, ": as it must"))
		}
		for signed in TEST_FACT_SIGNED {
			facts_expect_line(t, render(t, file, "Wrong_Own_Record_Missing", {{"own_rows", count}, {"first_lost", signed_bits(signed)}}), line_of_before("log_reader: WRONG: the log service gave ", count, " rows, the first with lost ", signed, ", and not the record that this process wrote"))
			facts_expect_line(t, render(t, file, "Wrong_Own_Rows", {{"rows", count}, {"first", signed_bits(signed)}, {"lost", signed_bits(-signed)}, {"own_number", signed_bits(signed)}}), line_of_before("log_reader: WRONG: the log service gave ", count, " rows of the name log_reader, the first with the number ", signed, " and lost ", -signed, ", the record of this process with the number ", signed, "; one row, its first record, with the number 0 and lost 0, was the answer"))
			facts_expect_line(t, render(t, file, "Own_Records_Read", {{"own_rows", count}, {"slot", signed_bits(signed)}}), line_of_before("log_reader: its own records: ", count, " rows from the own number 0, its first record, in the slot ", signed, ", lost 0: no row of another process or of an earlier run: as it must"))
			facts_expect_line(t, render(t, file, "Wrong_Runs_Kept", {{"call_runs", count}, {"kept_runs", signed_bits(signed)}}), line_of_before("log_reader: WRONG: the record of the text with ", count, " runs kept ", signed, " runs"))
		}
	}

	for signed in TEST_FACT_SIGNED {
		other := signed == max(i64) ? i64(-1) : max(i64)
		facts_expect_line(t, render(t, file, "Wrong_Refused_Facts_Changed", {{"records_before", signed_bits(signed)}, {"records_after", signed_bits(other)}}), line_of_before("log_reader: WRONG: the refused facts changed the own log ring (", signed, " then ", other, " records) or the budget"))
		facts_expect_line(t, render(t, file, "Wrong_Fact_Records", {{"records_taken", signed_bits(signed)}, {"records_expected", signed_bits(other)}}), line_of_before("log_reader: WRONG: the two facts at the edges and the fact of system.log_fact took ", signed, " records, not ", other))
		facts_expect_line(t, render(t, file, "Wrong_Fact_Count", {{"facts", signed_bits(signed)}}), line_of_before("log_reader: WRONG: log.fact_records gave ", signed, " facts of this process, not 3"))
		facts_expect_line(t, render(t, file, "Wrong_Refused_Calls_Wrote", {{"records_before", signed_bits(signed)}, {"records_after", signed_bits(other)}}), line_of_before("log_reader: WRONG: the own log ring kept ", signed, " records before the refused calls of Log, and ", other, " after them"))
		facts_expect_line(t, render(t, file, "Wrong_Edge_Records", {{"records_taken", signed_bits(signed)}, {"records_expected", signed_bits(other)}}), line_of_before("log_reader: WRONG: the calls at the edges took ", signed, " records, not ", other))
	}

	// Each status, with the edges of the values of an error record and of
	// the length of a fact.
	lengths := [3]u64{0, u64(op.LOG_FACT_HEAD_BYTES), u64(max(u32))}
	for status in op.Status {
		for refusal in refusals {
			for signed in TEST_FACT_SIGNED {
				error_record := []Fact_Test_Field{{"error_kind", signed_bits(signed)}, {"argument", signed_bits(-signed)}, {"value", signed_bits(signed)}, {"status", u64(status)}, {"refusal", refusal}}
				facts_expect_line(t, render(t, file, "Wrong_Fact_Refusal", error_record), line_of_before("log_reader: WRONG: Log of a fact with ", refusal, " gave ", op.STATUS_NAMES[status], ", the error kind ", signed, " for the argument ", -signed, " with the value ", signed))
				facts_expect_line(t, render(t, file, "Wrong_Text_Refusal", error_record), line_of_before("log_reader: WRONG: Log with ", refusal, " gave ", op.STATUS_NAMES[status], ", the error kind ", signed, " for the argument ", -signed, " with the value ", signed))
			}
		}
		for length in lengths {
			facts_expect_line(t, render(t, file, "Wrong_Fact_Edge_Refused", {{"length", length}, {"status", u64(status)}}), line_of_before("log_reader: WRONG: Log of a fact of ", length, " bytes gave ", op.STATUS_NAMES[status]))
		}
		for edge in edges {
			facts_expect_line(t, render(t, file, "Wrong_Edge_Refused", {{"status", u64(status)}, {"edge", edge}}), line_of_before("log_reader: WRONG: Log with ", edge, " gave ", op.STATUS_NAMES[status]))
		}
		facts_expect_line(t, render(t, file, "Wrong_Service_Handle_Lent", {{"status", u64(status)}}), line_of_before("log_reader: WRONG: the lend of the process handle of the log service gave ", op.STATUS_NAMES[status]))
		for child in children {
			facts_expect_line(t, render(t, file, "Wrong_Child_Not_Started", {{"status", u64(status)}, {"child", child}}), line_of_before("log_reader: WRONG: ", child, " did not start: ", op.STATUS_NAMES[status]))
		}
	}
	// A status word that names no member: the render writes its number.
	past_status := u64(max(op.Status)) + 1
	facts_expect_line(t, render(t, file, "Wrong_Service_Handle_Lent", {{"status", past_status}}), line_of_before("log_reader: WRONG: the lend of the process handle of the log service gave ", past_status))

	// The stops of a child: each cause, with each outcome for a stop of
	// itself, and a cause word that names no member.
	for child in children {
		facts_expect_line(t, render(t, file, "Wrong_Child_Not_Stopped", {{"child", child}}), line_of_before("log_reader: WRONG: ", child, " did not stop"))
		for cause in op.Stop_Cause {
			if cause == .Itself {
				for outcome in op.Stop_Outcome {
					facts_expect_line(t, render(t, file, "Wrong_Child_Stopped", {{"cause", u64(cause)}, {"outcome", u64(outcome)}, {"child", child}}), line_of_before("log_reader: WRONG: ", child, " stopped: ", op.STOP_CAUSE_TEXTS[cause], ", ", op.STOP_OUTCOME_TEXTS[outcome]))
				}
				continue
			}
			facts_expect_line(t, render(t, file, "Wrong_Child_Stopped_Without_Outcome", {{"cause", u64(cause)}, {"child", child}}), line_of_before("log_reader: WRONG: ", child, " stopped: ", op.STOP_CAUSE_TEXTS[cause]))
		}
		past_cause := u64(max(op.Stop_Cause)) + 1
		facts_expect_line(t, render(t, file, "Wrong_Child_Stopped_Without_Outcome", {{"cause", past_cause}, {"child", child}}), line_of_before("log_reader: WRONG: ", child, " stopped: ", past_cause))
	}
}
