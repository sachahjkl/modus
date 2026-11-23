package build

import "modus:contract/call_outcome"
import "modus:contract/errors"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/storage_status"
import "modus:contract/value_kinds"
import "modus:sentence"
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

// The longest text of the other Text fields of the test modules: the name
// of a command of the root ring, a verdict, a name that a share refuses,
// the reason of a failure of log_reader, and the cause of a failure of
// iommu_device and of operation_fuzzing.
@(private = "file")
COMMAND_LONGEST :: "Disk_Grant_Persistence"
@(private = "file")
VERDICT_LONGEST :: "as it must"
@(private = "file")
SHARE_NAME_LONGEST :: "part_000/../.."
@(private = "file")
PROBLEM_LONGEST :: "the log service gave a row before the first record of this process, or of an earlier run"
@(private = "file")
IOMMU_DEVICE_CAUSE_LONGEST :: "without the registers of the other device behind the conventional bridge, a declaration was not refused"
@(private = "file")
FUZZING_CAUSE_LONGEST :: "Memory_Physical refused the mailbox"

// The folders of the test modules that write log facts.
@(private = "file")
TEST_FACT_FOLDERS := [?]string{"arena", "debug_target", "disk_start_policy", "flood", "hierarchy", "hostile_terminal", "iommu", "iommu_device", "operation_fuzzing", "probe", "ranges", "shortage", "stops_failed", "stops_refused", "store_importer", "visitor", "log_reader"}

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
	most["command"] = len(COMMAND_LONGEST)
	most["verdict"] = len(VERDICT_LONGEST)
	most["name"] = len(SHARE_NAME_LONGEST)
	most["problem"] = len(PROBLEM_LONGEST)
	for folder in TEST_FACT_FOLDERS {
		file, ok := test_facts_file(t, folder)
		if !ok {
			continue
		}
		// A cause of a failure is a sentence of its module: each module
		// has its own longest one.
		most["cause"] = folder == "operation_fuzzing" ? len(FUZZING_CAUSE_LONGEST) : len(IOMMU_DEVICE_CAUSE_LONGEST)
		facts_expect_text_fields_last(t, file, most)
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

// One fact type with no field: its folder, its package, its name, and the
// line that it replaced.
@(private = "file")
Fact_With_No_Field :: struct {
	folder, package_name, type_name, line: string,
}

// Each fact type with no field writes the line of before, byte for byte:
// its sentence is its template. A fact of one value byte is refused: a
// fact type with no field takes no value.
@(test)
the_facts_with_no_field_of_the_test_modules_write_the_lines_of_before :: proc(t: ^testing.T) {
	facts := [?]Fact_With_No_Field {
		{"arena", "arena", "Wrong_Reset", "arena: WRONG: after a reset the same pushes did not take the same pages with no commit"},
		{"arena", "arena", "Arena_Checked", "arena: the budget refused the commit with No_Budget, the arena kept its state, a reset took the same pages again with no commit, and its end gave every page back to the budget: as it must"},
		{"debug_target", "debug_target", "Rounds_Ran", "debug_target: 64 more rounds ran, so the process is not held: as it must"},
		{"debug_target", "debug_target", "Running", "debug_target: runs, with a thread that waits"},
		{"disk_start_policy", "disk_start_policy", "Running", "disk_start_policy: ok, a start policy from the disk: its order is in its code"},
		{"disk_start_policy", "disk_start_policy", "Context_Checked", "disk_start_policy: the context holds the log, the budget and the root ring, no other handle and no start list: as it must"},
		{"disk_start_policy", "disk_start_policy", "Parts_Page_Refused", "disk_start_policy: the machine parts page is refused: it starts the console only"},
		{"disk_start_policy", "disk_start_policy", "Wrong_Start_Policy_Start_Taken", "disk_start_policy: a start of the start policy of the boot image is taken: WRONG"},
		{"disk_start_policy", "disk_start_policy", "Commands_Refused", "disk_start_policy: Start_Policy_Choice, Start_From_Disk, Disk_Grant and Connect are refused with Grant_Or_Right_Missing: as it must"},
		{"disk_start_policy", "disk_start_policy", "Machine_Is_Usable", "disk_start_policy: the console runs: the machine is usable"},
		{"flood", "flood", "No_Terminal", "flood: no terminal"},
		{"flood", "flood", "Running", "flood: ok"},
		{"flood", "flood", "Lines_Continue", "flood: Space: the lines continue"},
		{"hierarchy", "hierarchy", "First_Run", "hierarchy: a new store: the first run"},
		{"hierarchy", "hierarchy", "Wrong_No_Store", "hierarchy: WRONG: no store"},
		{"hierarchy", "hierarchy", "Wrong_No_Usage", "hierarchy: WRONG: no usage"},
		{"hostile_terminal", "hostile_terminal", "No_Terminal", "hostile_terminal: no terminal"},
		{"iommu", "iommu_client", "No_Block_Ring", "iommu: no block ring"},
		{"iommu", "iommu_client", "Block_Ring_Full", "iommu: the block ring has no room"},
		{"iommu", "iommu_client", "Machine_Goes_On", "iommu: the test device service answered after its read into a page that was not declared: the machine goes on: as it must"},
		{"iommu", "iommu_client", "Device_Service_Silent", "iommu: the test device service did not answer before the hang bound"},
		{"iommu_device", "iommu_device_service", "Block_Arrived", "iommu_device: a block written from a declared page and read into another declared page: the 4096 bytes arrived: as it must"},
		{"iommu_device", "iommu_device_service", "Interrupt_Arrived", "iommu_device: the message interrupt of the device arrived through its entry: as it must"},
		{"iommu_device", "iommu_device_service", "Interrupt_Addresses_Refused", "iommu_device: a read into the interrupt addresses, to entries that the kernel did not give this device: the device gave the request back: as it must"},
		{"iommu_device", "iommu_device_service", "Undeclared_Page_Written", "iommu_device: a read into a page that was not declared: the device wrote the page: no IOMMU keeps the device in the memory of its service on this machine"},
		{"iommu_device", "iommu_device_service", "Undeclared_Read_Needs_Reset", "iommu_device: a read into a page that was not declared: the device needs a reset, and the page keeps its 4096 bytes: as it must"},
		{"iommu_device", "iommu_device_service", "Undeclared_Read_Silent", "iommu_device: a read into a page that was not declared: the device did not end the request before the hang bound"},
		{"iommu_device", "iommu_device_service", "Declaration_Refused_Behind_Bridge", "iommu_device: without the registers of the other device behind the conventional bridge, a declaration is refused: as it must"},
		{"iommu_device", "iommu_device_service", "Read_After_Domain_End", "iommu_device: a read given to the device after the end of its domain: the service waits for the new size of the disk"},
		{"iommu_device", "iommu_device_service", "Domain_Ended", "iommu_device: after the end of its domain, a read of the device into a page that this service declared before does not end, the page keeps its 4096 bytes, and no interrupt of the device arrives, also for its new size: as it must"},
		{"log_reader", "log_reader", "Wrong_Facts_Changed_Budget", "log_reader: WRONG: the facts changed the log records of the budget or its refused count"},
		{"log_reader", "log_reader", "Service_Handle_Not_Lent", "log_reader: the process handle of the log service from connect, with Read and no Give: the lend failed with No_Right, and it reads no record of the service: as it must"},
		{"log_reader", "log_reader", "Memory_Lent_Refused", "log_reader: a memory object in place of a process handle: the log service refused it with Handle_Kind: as it must"},
		{"log_reader", "log_reader", "Checked", "log_reader: ok"},
		{"probe", "probe", "Spin_Runs", "probe: spin runs, and never returns"},
		{"ranges", "ranges", "First_Run", "ranges: a new store: the first run"},
		{"ranges", "ranges", "Wrong_No_Store", "ranges: WRONG: no store"},
		{"ranges", "ranges", "Wrong_No_Usage", "ranges: WRONG: no usage"},
		{"shortage", "shortage", "Shortage_Checked", "shortage: ok, the stacks were drained for takes that cannot fail, a new object failed only when its budget could pay no page, and each frame returned"},
		{"shortage", "shortage", "Wrong", "shortage: wrong"},
		{"stops_failed", "stops_failed", "Fails_On_Purpose", "stops_failed: it fails on purpose"},
		{"stops_refused", "stops_refused", "Refuses_On_Purpose", "stops_refused: it refuses its context on purpose"},
		{"store_importer", "store_importer", "Triple_Checked", "store_importer: triple(14) of the module store_library of the store module_files gives 42: as it must"},
		{"visitor", "visitor", "Running", "visitor: ok, a module that the boot image does not hold"},
		{"visitor", "visitor", "Context_With_Store", "visitor: the context holds the log, a window, the budget and a store, and no other handle of a grant: as it must"},
		{"visitor", "visitor", "Context_Without_Grant", "visitor: the context holds the log, a window and the budget, and no handle of a grant: as it must"},
		{"visitor", "visitor", "Root_Ring_Refused", "visitor: no ring to the root service: the open of its handle is refused: as it must"},
		{"visitor", "visitor", "Wrong_Count_Read_Again", "visitor: the count read again is not the count written: WRONG"},
	}
	for fact in facts {
		file, ok := test_facts_file(t, fact.folder)
		if !ok {
			continue
		}
		facts_expect_line(t, fact_test_render(t, file, fact.package_name, fact.type_name, {}), fact.line)
		key := fact_key(fact.package_name, fact.type_name)
		one_byte := [1]u8{0}
		buffer: [module.FACT_SENTENCE_BYTES_MOST]u8
		_, _, refusal := module.fact_sentence_write(file, key, one_byte[:], buffer[:], nil)
		testing.expectf(t, refusal == .Value_Count, "the fact %s.%s of no field takes one value byte: %v", fact.package_name, fact.type_name, refusal)
	}
}

// Each fact type with a status, an error kind, a status of another party
// or a cause writes its sentence: a status and an error kind by the names
// of their members, where the line of before wrote their numbers; a word
// that names no member, and the largest word, by their numbers. The other
// values at their edges.
@(test)
the_statuses_and_causes_of_the_test_modules_write_their_sentences :: proc(t: ^testing.T) {
	arena_file, arena_ok := test_facts_file(t, "arena")
	debug_file, debug_ok := test_facts_file(t, "debug_target")
	policy_file, policy_ok := test_facts_file(t, "disk_start_policy")
	visitor_file, visitor_ok := test_facts_file(t, "visitor")
	fuzzing_file, fuzzing_ok := test_facts_file(t, "operation_fuzzing")
	iommu_file, iommu_ok := test_facts_file(t, "iommu")
	device_file, device_ok := test_facts_file(t, "iommu_device")
	shortage_file, shortage_ok := test_facts_file(t, "shortage")
	if !arena_ok || !debug_ok || !policy_ok || !visitor_ok || !fuzzing_ok || !iommu_ok || !device_ok || !shortage_ok {
		return
	}
	process := strings.repeat("p", value_kinds.MODULE_NAME_FIELD_BYTES - 1, context.temp_allocator)
	commands := [2]string{COMMAND_LONGEST, "Connect"}
	causes := [2]string{FUZZING_CAUSE_LONGEST, "no mailbox"}
	for status in op.Status {
		name := op.STATUS_NAMES[status]
		word := u64(status)
		for count in TEST_FACT_COUNTS {
			other := max(u64) - count
			facts_expect_line(t, fact_test_render(t, arena_file, "arena", "Wrong_Reservation", {{"reservation_pages", count}, {"status", word}}), line_of_before("arena: WRONG: the reservation of ", count, " pages failed with ", name))
			facts_expect_line(t, fact_test_render(t, arena_file, "arena", "Wrong_After_Refusal", {{"budget_pages", count}, {"status", word}}), line_of_before("arena: WRONG: after the refusal the budget held ", count, " pages, and a second push gave ", name, " or changed the arena"))
			facts_expect_line(t, fact_test_render(t, arena_file, "arena", "Wrong_End", {{"status", word}, {"budget_pages_after", count}, {"budget_pages_before", other}}), line_of_before("arena: WRONG: the end gave ", name, ", and the budget holds ", count, " pages of ", other))
		}
		for kind in errors.Kind {
			facts_expect_line(t, fact_test_render(t, arena_file, "arena", "Wrong_Growth_Stop", {{"status", word}, {"error_kind", u64(kind)}}), line_of_before("arena: WRONG: the growth stopped with ", name, " and the error kind ", errors.KIND_NAMES[kind], ", not with No_Budget"))
		}
		facts_expect_line(t, fact_test_render(t, debug_file, "debug_target", "Thread_Not_Started", {{"status", word}}), line_of_before("debug_target: the second thread did not start: status ", name))
		facts_expect_line(t, fact_test_render(t, policy_file, "disk_start_policy", "Root_Ring_Refused", {{"status", word}}), line_of_before("disk_start_policy: the root ring does not open: status ", name))
		facts_expect_line(t, fact_test_render(t, visitor_file, "visitor", "Wrong_Root_Ring", {{"status", word}}), line_of_before("visitor: a ring to the root service opens with status ", name, ": WRONG"))
		for cause in causes {
			facts_expect_line(t, fact_test_render(t, fuzzing_file, "operation_fuzzing", "Failed", {{"status", word}, {"cause", cause}}), line_of_before("operation_fuzzing: failed: ", cause, ": status ", name))
		}
	}
	// The refusals of the root service that disk_start_policy writes: each
	// outcome by its name, then a word that names none by its number.
	for outcome in call_outcome.Call_Outcome {
		name := call_outcome.CALL_OUTCOME_NAMES[outcome]
		word := u64(outcome)
		facts_expect_line(t, fact_test_render(t, policy_file, "disk_start_policy", "Start_Policy_Start_Refused", {{"outcome", word}}), line_of_before("disk_start_policy: a start of the start policy of the boot image is refused with the outcome ", name, ": as it must"))
		facts_expect_line(t, fact_test_render(t, policy_file, "disk_start_policy", "Machine_Usable_Refused", {{"outcome", word}}), line_of_before("disk_start_policy: the root service refused Machine_Usable: outcome ", name))
		facts_expect_line(t, fact_test_render(t, policy_file, "disk_start_policy", "Start_Refused", {{"outcome", word}, {"started_process", process}}), line_of_before("disk_start_policy: cannot start ", process, ": outcome ", name))
		for command in commands {
			facts_expect_line(t, fact_test_render(t, policy_file, "disk_start_policy", "Wrong_Command_Not_Refused", {{"outcome", word}, {"command", command}}), line_of_before("disk_start_policy: the command ", command, " gives the outcome ", name, ", not Grant_Or_Right_Missing: WRONG"))
		}
		facts_expect_line(t, fact_test_render(t, policy_file, "disk_start_policy", "Wiring_Wrong", {{"case_number", u64(7)}, {"outcome", word}}), line_of_before("disk_start_policy: WRONG: the case ", u64(7), " of the wiring refusals gave the outcome ", name))
	}
	past_root_outcome := u64(max(call_outcome.Call_Outcome)) + 1
	facts_expect_line(t, fact_test_render(t, policy_file, "disk_start_policy", "Machine_Usable_Refused", {{"outcome", past_root_outcome}}), line_of_before("disk_start_policy: the root service refused Machine_Usable: outcome ", past_root_outcome))
	// A status that names no member, the largest status word of 8 bytes and
	// an error kind that names no member: their numbers, never the name of
	// another member.
	past_status := u64(max(op.Status)) + 1
	past_kind := u64(max(errors.Kind)) + 1
	facts_expect_line(t, fact_test_render(t, arena_file, "arena", "Wrong_Growth_Stop", {{"status", past_status}, {"error_kind", past_kind}}), line_of_before("arena: WRONG: the growth stopped with ", past_status, " and the error kind ", past_kind, ", not with No_Budget"))
	facts_expect_line(t, fact_test_render(t, arena_file, "arena", "Wrong_End", {{"status", max(u64)}, {"budget_pages_after", u64(0)}, {"budget_pages_before", u64(0)}}), line_of_before("arena: WRONG: the end gave ", max(u64), ", and the budget holds ", u64(0), " pages of ", u64(0)))
	facts_expect_line(t, fact_test_render(t, debug_file, "debug_target", "Thread_Not_Started", {{"status", past_status}}), line_of_before("debug_target: the second thread did not start: status ", past_status))

	// An outcome of the block service and a status of the storage service:
	// the names of their members, and the number of a word that names none.
	for outcome in call_outcome.Call_Outcome {
		facts_expect_line(t, fact_test_render(t, iommu_file, "iommu_client", "Info_Refused", {{"outcome", u64(outcome)}}), line_of_before("iommu: the test device service gave the outcome ", call_outcome.CALL_OUTCOME_NAMES[outcome], " to Info"))
	}
	for status in storage_status.Status {
		name := storage_status.STATUS_NAMES[status]
		facts_expect_line(t, fact_test_render(t, visitor_file, "visitor", "Wrong_Count_Not_Read", {{"status", u64(status)}}), line_of_before("visitor: the store did not give the count: status ", name, ": WRONG"))
		facts_expect_line(t, fact_test_render(t, visitor_file, "visitor", "Wrong_Count_Not_Kept", {{"status", u64(status)}}), line_of_before("visitor: the store did not keep the count: status ", name, ": WRONG"))
	}
	past_outcome := u64(max(call_outcome.Call_Outcome)) + 1
	facts_expect_line(t, fact_test_render(t, iommu_file, "iommu_client", "Info_Refused", {{"outcome", past_outcome}}), line_of_before("iommu: the test device service gave the outcome ", past_outcome, " to Info"))
	facts_expect_line(t, fact_test_render(t, visitor_file, "visitor", "Wrong_Count_Not_Read", {{"status", max(u64)}}), line_of_before("visitor: the store did not give the count: status ", max(u64), ": WRONG"))
	// A word of the device, which keeps its number, and the lines of the
	// mailbox.
	for count in TEST_FACT_COUNTS {
		facts_expect_line(t, fact_test_render(t, fuzzing_file, "operation_fuzzing", "Mailbox_Ready", {{"mailbox_address", count}, {"mailbox_pages", max(u64) - count}}), line_of_before("operation_fuzzing: mailbox at ", count, ", ", max(u64) - count, " pages"))
		facts_expect_line(t, fact_test_render(t, fuzzing_file, "operation_fuzzing", "Sequence_Ended", {{"sequence", count}}), line_of_before("operation_fuzzing: sequence ", count, " ended"))
	}
	// The causes of a failure of iommu_device: the longest and a short one.
	device_causes := [2]string{IOMMU_DEVICE_CAUSE_LONGEST, "no block ring"}
	for cause in device_causes {
		facts_expect_line(t, fact_test_render(t, device_file, "iommu_device_service", "Failed", {{"cause", cause}}), line_of_before("iommu_device: ", cause))
	}

	// The full machine of shortage: each error kind, with the words of the
	// fact type of its case, and the status and the kind by their names.
	for count in TEST_FACT_COUNTS {
		other := max(u64) - count
		for time in TEST_FACT_TIMES {
			values := []Fact_Test_Field{{"pages", count}, {"objects", other}, {"threads", u64(4)}, {"elapsed", time}, {"budget_pages", count}, {"payable_pages", other}, {"reserved_pages", count}, {"drains", other}, {"status", u64(op.Status.No_Budget)}, {"error_kind", u64(errors.Kind.Budget)}}
			facts_expect_line(t, fact_test_render(t, shortage_file, "shortage", "Full_Refused_By_Budget", values), line_of_before("shortage: full: ", count, " pages written in ", other, " objects by ", u64(4), " threads in ", time, " ms; the budget of this process holds ", count, " pages; the free pages that budgets can pay: ", other, " (the pages that the root service kept), and the reserved pages: ", count, "; drains of the stacks: ", other, "; a new memory object of 1 page: status ", "No_Budget", ", error kind ", "Budget", " (Budget: the budget cannot pay)"))
			values[9].value = u64(errors.Kind.Budget_Hidden)
			facts_expect_line(t, fact_test_render(t, shortage_file, "shortage", "Full_Refused_By_Another_Kind", values), line_of_before("shortage: full: ", count, " pages written in ", other, " objects by ", u64(4), " threads in ", time, " ms; the budget of this process holds ", count, " pages; the free pages that budgets can pay: ", other, " (the pages that the root service kept), and the reserved pages: ", count, "; drains of the stacks: ", other, "; a new memory object of 1 page: status ", "No_Budget", ", error kind ", "Budget_Hidden", " (another kind)"))
		}
	}
}

// Each case of hierarchy and of ranges is one fact type: its values, then
// its verdict. Each writes the sentence of the case, then "as it must" or
// "WRONG", at the edges of its values: the counts 0, 1 and max(u64), the
// signed counts -1, 0 and max(i64), the times 0 and max(i64).
@(test)
the_cases_of_hierarchy_and_ranges_write_their_verdicts :: proc(t: ^testing.T) {
	hierarchy_file, hierarchy_ok := test_facts_file(t, "hierarchy")
	ranges_file, ranges_ok := test_facts_file(t, "ranges")
	if !hierarchy_ok || !ranges_ok {
		return
	}
	render_hierarchy :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
		return fact_test_render(t, file, "hierarchy", type_name, values)
	}
	render_ranges :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
		return fact_test_render(t, file, "ranges", type_name, values)
	}
	verdicts := [2]string{VERDICT_LONGEST, "WRONG"}
	names := [2]string{SHARE_NAME_LONGEST, "."}
	// A status of the storage service by the name of its member; a word
	// that names none, and the largest word, by their numbers.
	past_status := u64(max(storage_status.Status)) + 1
	for verdict in verdicts {
		for status in storage_status.Status {
			name := storage_status.STATUS_NAMES[status]
			word := u64(status)
			facts_expect_line(t, render_hierarchy(t, hierarchy_file, "Top_Trees_Refused", {{"status", word}, {"verdict", verdict}}), line_of_before("hierarchy: the top trees: status ", name, ": ", verdict))
			facts_expect_line(t, render_hierarchy(t, hierarchy_file, "Top_Tree_Open_Refused", {{"status", word}, {"verdict", verdict}}), line_of_before("hierarchy: open a top tree: status ", name, ": ", verdict))
			facts_expect_line(t, render_hierarchy(t, hierarchy_file, "Part_Open_Refused", {{"status", word}, {"verdict", verdict}}), line_of_before("hierarchy: open a part: status ", name, ": ", verdict))
			facts_expect_line(t, render_hierarchy(t, hierarchy_file, "Part_Objects_Refused", {{"status", word}, {"verdict", verdict}}), line_of_before("hierarchy: add the objects of a part: status ", name, ": ", verdict))
			facts_expect_line(t, render_hierarchy(t, hierarchy_file, "Scrambled_Tree_Refused", {{"status", word}, {"open_status", past_status}, {"verdict", verdict}}), line_of_before("hierarchy: the tree scrambled: status ", name, " ", past_status, ": ", verdict))
			facts_expect_line(t, render_hierarchy(t, hierarchy_file, "Scrambled_Adds_Refused", {{"status", word}, {"verdict", verdict}}), line_of_before("hierarchy: the scrambled adds: status ", name, ": ", verdict))
		}
		facts_expect_line(t, render_hierarchy(t, hierarchy_file, "Scrambled_Adds_Refused", {{"status", max(u64)}, {"verdict", verdict}}), line_of_before("hierarchy: the scrambled adds: status ", max(u64), ": ", verdict))
		for index in 0 ..< len(TEST_FACT_COUNTS) {
			c := TEST_FACT_COUNTS[index]
			s := TEST_FACT_SIGNED[index]
			m := TEST_FACT_TIMES[min(index, len(TEST_FACT_TIMES) - 1)]
			b := signed_bits(s)
			facts_expect_line(t, render_hierarchy(t, hierarchy_file, "Trees_Made", {{"objects", b}, {"trees", b}, {"commits", c}, {"elapsed", m}, {"blocks", b}, {"verdict", verdict}}), line_of_before("hierarchy: made ", s, " objects and ", s, " trees in ", c, " commits, in ", m, " ms, ", s, " blocks: ", verdict))
			facts_expect_line(t, render_hierarchy(t, hierarchy_file, "Root_Listed", {{"trees", b}, {"verdict", verdict}}), line_of_before("hierarchy: the root in pages of 16: ", s, " trees, in order: ", verdict))
			facts_expect_line(t, render_hierarchy(t, hierarchy_file, "Parts_Listed", {{"objects", b}, {"trees", b}, {"elapsed", m}, {"verdict", verdict}}), line_of_before("hierarchy: listed ", s, " objects in ", s, " trees in pages of 16, each page after the one before, in ", m, " ms: ", verdict))
			facts_expect_line(t, render_hierarchy(t, hierarchy_file, "Object_Renamed", {{"objects", b}, {"verdict", verdict}}), line_of_before("hierarchy: rename of an object to the root: the part has ", s, " objects: ", verdict))
			facts_expect_line(t, render_hierarchy(t, hierarchy_file, "Tree_Renamed", {{"trees", b}, {"objects", b}, {"verdict", verdict}}), line_of_before("hierarchy: rename of a tree of ", s, " trees and ", s, " objects: one commit: ", verdict))
			facts_expect_line(t, render_hierarchy(t, hierarchy_file, "Tree_Removed", {{"removing", b}, {"verdict", verdict}}), line_of_before("hierarchy: remove of a tree: the name is gone at its commit; ", s, " trees wait to be freed: ", verdict))
			facts_expect_line(t, render_hierarchy(t, hierarchy_file, "Removal_Freed", {{"objects", b}, {"trees", b}, {"blocks", b}, {"elapsed", m}, {"verdict", verdict}}), line_of_before("hierarchy: the removal freed ", s, " objects, ", s, " trees and ", s, " blocks, in ", m, " ms: ", verdict))
			facts_expect_line(t, render_hierarchy(t, hierarchy_file, "First_Run_Left", {{"objects", b}, {"trees", b}, {"verdict", verdict}}), line_of_before("hierarchy: the first run leaves ", s, " objects and ", s, " trees: ", verdict))
			facts_expect_line(t, render_hierarchy(t, hierarchy_file, "Scrambled_Names_Checked", {{"added", b}, {"commits", c}, {"removed", b}, {"left", b}, {"elapsed", m}, {"verdict", verdict}}), line_of_before("hierarchy: added ", s, " names in a scrambled order in ", c, " commits, listed in order, each read back; removed ", s, " in another order, ", s, " left in order, in ", m, " ms: ", verdict))
			facts_expect_line(t, render_hierarchy(t, hierarchy_file, "Share_Count_Checked", {{"share_took", b}, {"maker_took", b}, {"share_saw", b}, {"freed", b}, {"verdict", verdict}}), line_of_before("hierarchy: while a writable share of a tree is open, its write took ", s, " blocks of the count of its tree; the same bytes written by the maker outside the tree took ", s, " blocks of the store and ", s, " of the count of the share; the removal through the share freed ", s, ": the share sees the count of its own tree only: ", verdict))
			facts_expect_line(t, render_hierarchy(t, hierarchy_file, "Guess_Hidden", {{"maker_took", b}, {"verdict", verdict}}), line_of_before("hierarchy: after unshare, the guess of the holder stays hidden: the same bytes written by the maker took ", s, " blocks: ", verdict))
			facts_expect_line(t, render_hierarchy(t, hierarchy_file, "Share_Listed", {{"trees", b}, {"verdict", verdict}}), line_of_before("hierarchy: the share lists the ", s, " trees of tree_003 only: ", verdict))
			facts_expect_line(t, render_hierarchy(t, hierarchy_file, "Remount_Counted", {{"objects", b}, {"trees", b}, {"verdict", verdict}}), line_of_before("hierarchy: after the remount: ", s, " objects and ", s, " trees: ", verdict))
			facts_expect_line(t, render_hierarchy(t, hierarchy_file, "Remount_Scrambled_Left", {{"left", b}, {"verdict", verdict}}), line_of_before("hierarchy: after the remount: ", s, " scrambled names left, in order: ", verdict))
			facts_expect_line(t, render_hierarchy(t, hierarchy_file, "Remount_Parts_Listed", {{"objects", b}, {"contents", b}, {"elapsed", m}, {"verdict", verdict}}), line_of_before("hierarchy: after the remount: ", s, " objects listed in the parts, ", s, " contents byte for byte, the renamed tree and object in their places, in ", m, " ms: ", verdict))

			facts_expect_line(t, render_ranges(t, ranges_file, "Writes_Pending", {{"size", c}, {"verdict", verdict}}), line_of_before("ranges: three range writes are pending, and the size of the object is ", c, " bytes: ", verdict))
			facts_expect_line(t, render_ranges(t, ranges_file, "Sparse_Object_Held", {{"held_blocks", c}, {"verdict", verdict}}), line_of_before("ranges: a sparse object of 8 GiB from 3 writes and one commit holds ", c, " blocks: ", verdict))
			facts_expect_line(t, render_ranges(t, ranges_file, "Scrambled_Commit_Bounded", {{"hashed_blocks", c}, {"hashed_nodes", max(u64) - c}, {"object_blocks", c}, {"verdict", verdict}}), line_of_before("ranges: the commit of 1000 scrambled writes hashed ", c, " blocks and ", max(u64) - c, " object nodes, bounded by the blocks changed, not by the ", c, " blocks of the object: ", verdict))
			facts_expect_line(t, render_ranges(t, ranges_file, "Version_Blocks_Shared", {{"own_blocks", b}, {"verdict", verdict}}), line_of_before("ranges: the version before the 1000 writes holds ", s, " blocks of its own: the root and the path of the first block; its other blocks are shared with the new state: ", verdict))
			facts_expect_line(t, render_ranges(t, ranges_file, "Cut_And_Extension", {{"cut_blocks", c}, {"extended_blocks", max(u64) - c}, {"verdict", verdict}}), line_of_before("ranges: a cut of an object of 70 blocks to 6000 bytes holds ", c, " blocks; an extension to 1 GiB holds ", max(u64) - c, " blocks, and reads zero bytes past the cut: ", verdict))
			facts_expect_line(t, render_ranges(t, ranges_file, "Twin_Held", {{"held_blocks", c}, {"written_blocks", max(u64) - c}, {"verdict", verdict}}), line_of_before("ranges: the same object of 1 MiB under two names holds ", c, " blocks of the store, one object's worth; the second commit wrote ", max(u64) - c, " blocks of its block tree: ", verdict))
			facts_expect_line(t, render_ranges(t, ranges_file, "Twin_Changed", {{"written_blocks", c}, {"verdict", verdict}}), line_of_before("ranges: a change of one block of the second name wrote ", c, " blocks of its block tree; the first name reads its bytes as before: ", verdict))
			facts_expect_line(t, render_ranges(t, ranges_file, "Loop_Done", {{"commits", c}, {"verdict", verdict}}), line_of_before("ranges: the loop made ", c, " commits of range writes: ", verdict))
			facts_expect_line(t, render_ranges(t, ranges_file, "Remount_Sparse_Read", {{"size", c}, {"verdict", verdict}}), line_of_before("ranges: after the remount: the sparse object of ", c, " bytes reads its 3 blocks and its 1000 writes, byte for byte: ", verdict))
		}
		for name in names {
			facts_expect_line(t, render_hierarchy(t, hierarchy_file, "Name_Refused", {{"name", name}, {"verdict", verdict}}), line_of_before("hierarchy: the name \"", name, "\" is refused: ", verdict))
		}
		facts_expect_line(t, render_hierarchy(t, hierarchy_file, "Move_Inside_Refused", {{"verdict", verdict}}), line_of_before("hierarchy: a tree cannot move inside itself: ", verdict))
		facts_expect_line(t, render_hierarchy(t, hierarchy_file, "Rename_Onto_Name_Refused", {{"verdict", verdict}}), line_of_before("hierarchy: a rename onto a name that exists is refused: ", verdict))
		facts_expect_line(t, render_hierarchy(t, hierarchy_file, "Read_Only_Share_Made", {{"verdict", verdict}}), line_of_before("hierarchy: a read-only share of tree_003: ", verdict))
		facts_expect_line(t, render_hierarchy(t, hierarchy_file, "Foreign_Place_Refused", {{"verdict", verdict}}), line_of_before("hierarchy: a place of another connection names nothing on the share: ", verdict))
		facts_expect_line(t, render_hierarchy(t, hierarchy_file, "Foreign_Store_Refused", {{"verdict", verdict}}), line_of_before("hierarchy: a name of another store is refused: ", verdict))
		facts_expect_line(t, render_hierarchy(t, hierarchy_file, "Read_Only_Write_Refused", {{"verdict", verdict}}), line_of_before("hierarchy: the read-only share cannot write: ", verdict))
		facts_expect_line(t, render_hierarchy(t, hierarchy_file, "Read_Only_Remove_Refused", {{"verdict", verdict}}), line_of_before("hierarchy: the read-only share cannot remove: ", verdict))
		facts_expect_line(t, render_hierarchy(t, hierarchy_file, "Share_Handles_Revoked", {{"verdict", verdict}}), line_of_before("hierarchy: after unshare, the handles of the share are revoked: a call gives Gone: ", verdict))
		facts_expect_line(t, render_hierarchy(t, hierarchy_file, "Writable_Share_Written", {{"verdict", verdict}}), line_of_before("hierarchy: a writable share writes in tree_005, and the maker reads it: ", verdict))
		facts_expect_line(t, render_hierarchy(t, hierarchy_file, "Share_Root_Refused", {{"verdict", verdict}}), line_of_before("hierarchy: a share of a tree cannot open the root of its own store: ", verdict))
		facts_expect_line(t, render_ranges(t, ranges_file, "Sparse_Object_Read", {{"verdict", verdict}}), line_of_before("ranges: its three blocks read back, a hole reads as zero bytes, and a read across a block edge gives the end of a block and zero bytes: ", verdict))
		facts_expect_line(t, render_ranges(t, ranges_file, "Scrambled_Writes_Read", {{"verdict", verdict}}), line_of_before("ranges: the 1000 writes read back, each one byte for byte, and the three blocks before them: ", verdict))
		facts_expect_line(t, render_ranges(t, ranges_file, "Old_Version_Read", {{"verdict", verdict}}), line_of_before("ranges: an old version reads its old bytes after a range write, and compare gives the one range written: ", verdict))
		facts_expect_line(t, render_ranges(t, ranges_file, "End_Read", {{"verdict", verdict}}), line_of_before("ranges: a read at the end gives no byte, and a read past the end is refused: ", verdict))
		facts_expect_line(t, render_ranges(t, ranges_file, "Places_Refused", {{"verdict", verdict}}), line_of_before("ranges: a place of another store, a place of no connection, and a commit with no pending change are refused: ", verdict))
		facts_expect_line(t, render_ranges(t, ranges_file, "Conflict_Refused", {{"verdict", verdict}}), line_of_before("ranges: a commit after another change of the object is refused, and its pending changes are dropped: ", verdict))
		facts_expect_line(t, render_ranges(t, ranges_file, "Twin_Removed", {{"verdict", verdict}}), line_of_before("ranges: the removal of the second name frees its own blocks only, the first name reads its 1 MiB, and the second name written again takes no block: ", verdict))
		facts_expect_line(t, render_ranges(t, ranges_file, "Remount_Objects_Read", {{"verdict", verdict}}), line_of_before("ranges: after the remount: the small object, the object of the cut and the object of the loop: ", verdict))
		facts_expect_line(t, render_ranges(t, ranges_file, "Remount_Twin_Found", {{"verdict", verdict}}), line_of_before("ranges: after the remount: the same object of 1 MiB under a third name took no block: the open found it by its hash: ", verdict))
	}
}

// Each fact type of log_reader of this round writes the line of before,
// byte for byte, or its new sentence: the counts 0, 1 and max(u64), the
// signed counts -1, 0 and max(i64), each error kind by its name, a number
// in 16 hexadecimal digits as system.Hex writes it, the longest reason of
// a failure and a short one, and the measures at their edges.
@(test)
the_facts_of_log_reader_of_its_checks_and_measures_write_their_sentences :: proc(t: ^testing.T) {
	file, ok := test_facts_file(t, "log_reader")
	if !ok {
		return
	}
	render :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
		return fact_test_render(t, file, "log_reader", type_name, values)
	}
	children := [2]string{"log_reader child 1", strings.repeat("c", value_kinds.MODULE_NAME_FIELD_BYTES - 1, context.temp_allocator)}
	problems := [2]string{PROBLEM_LONGEST, "the boot image does not map"}
	for index in 0 ..< len(TEST_FACT_COUNTS) {
		c := TEST_FACT_COUNTS[index]
		o := max(u64) - c
		s := TEST_FACT_SIGNED[index]
		b := signed_bits(s)
		facts_expect_line(t, render(t, file, "Refused_Facts_Checked", {{"refusals", c}, {"own_records", o}}), line_of_before("log_reader: Log refused ", c, " wrong facts, each with its status and its error record: the form word, a run, the length below the head and past the whole fact, an address that the process cannot read, and the level; the own log ring kept the same ", o, " records, and the budget the same log records and the same refused count: as it must"))
		facts_expect_line(t, render(t, file, "Refused_Calls_Checked", {{"refusals", c}, {"own_records", o}}), line_of_before("log_reader: Log refused ", c, " wrong calls, each with its status and its error record: the level word, the runs and the length past their bounds, an address that the process cannot read, and a text or its runs past the end of what it can read; the own log ring kept the same ", o, " records, and the budget the same log records and the same refused count: as it must"))
		for form in op.Log_Record_Form {
			facts_expect_line(t, render(t, file, "Wrong_Fact_Row", {{"index", c}, {"form", u64(form)}, {"continues", b}, {"part", c}, {"part_count", o}, {"key", o}, {"value_count", b}, {"first_values", c}, {"last_value", o}}), line_of_before("log_reader: WRONG: the fact ", c, " has the form ", op.LOG_RECORD_FORM_NAMES[form], ", more ", s, ", the part ", c, " of ", o, ", the key ", sentence.Hex(o), ", ", s, " value bytes, the first ", sentence.Hex(c), " and the last ", o))
		}
		// A form word that names no member: its number.
		past_form := u64(max(op.Log_Record_Form)) + 1
		facts_expect_line(t, render(t, file, "Wrong_Fact_Row", {{"index", c}, {"form", past_form}, {"continues", b}, {"part", c}, {"part_count", o}, {"key", o}, {"value_count", b}, {"first_values", c}, {"last_value", o}}), line_of_before("log_reader: WRONG: the fact ", c, " has the form ", past_form, ", more ", s, ", the part ", c, " of ", o, ", the key ", sentence.Hex(o), ", ", s, " value bytes, the first ", sentence.Hex(c), " and the last ", o))
		// A kind word of -1, as a record of another party can hold, and an
		// object kind and an outcome of a call that name no member: their
		// numbers.
		past_call := u64(max(call_outcome.Call_Outcome)) + 1
		past_object := u64(max(op.Object_Kind)) + 1
		facts_expect_line(t, render(t, file, "Wrong_Memory_Lent", {{"outcome", past_call}, {"kind", max(u64)}, {"argument", b}, {"found_kind", past_object}}), line_of_before("log_reader: WRONG: a memory object in place of a process handle gave the outcome ", past_call, ", the kind ", max(u64), ", the argument ", s, " and the found kind ", past_object))
		facts_expect_line(t, render(t, file, "Wrong_Service_Handle_Call", {{"outcome", past_call}}), line_of_before("log_reader: WRONG: the call of log.process_records with the process handle of the log service gave the outcome ", past_call))
		facts_expect_line(t, render(t, file, "Write_Measured", {{"calls", c}, {"bad_block_text_least", o}, {"bad_block_text_median", c}, {"bad_block_fact_least", o}, {"bad_block_fact_median", c}, {"connected_text_least", o}, {"connected_text_median", c}, {"connected_fact_least", o}, {"connected_fact_median", c}}), line_of_before("log_reader: measure: the write of one line, in ns, the least and the median of ", c, " calls: a bad block as text ", o, " and ", c, ", as a fact ", o, " and ", c, "; a connection as text ", o, " and ", c, ", as a fact ", o, " and ", c))
		facts_expect_line(t, render(t, file, "Log_Operation_Measured", {{"calls", c}, {"text_least", o}, {"text_median", c}, {"fact_least", o}, {"fact_median", c}, {"refused_least", o}, {"refused_median", c}}), line_of_before("log_reader: measure: the operation Log, in ns from the call to the return, the least and the median of ", c, " calls: the text of a bad block ", o, " and ", c, ", its fact ", o, " and ", c, ", a call that the kernel refuses at the border of the form ", o, " and ", c))
		facts_expect_line(t, render(t, file, "Render_Measured", {{"renders", c}, {"render_least", o}, {"render_median", c}, {"window_rows", o}, {"window_rows_time", c}}), line_of_before("log_reader: measure: the render of a log fact by module.fact_sentence_write, in ns, the least and the median of ", c, " renders of two fact types of this module: ", o, " and ", c, "; ", o, " rows of the window of the log at the median: ", c, " ns"))
	}
	for problem in problems {
		facts_expect_line(t, render(t, file, "Wrong_Check", {{"problem", problem}}), line_of_before("log_reader: WRONG: ", problem))
	}
	// An outcome of a call by the name of its member, and each object kind
	// and each error kind by theirs.
	for outcome in call_outcome.Call_Outcome {
		name := call_outcome.CALL_OUTCOME_NAMES[outcome]
		word := u64(outcome)
		facts_expect_line(t, render(t, file, "Wrong_Service_Handle_Call", {{"outcome", word}}), line_of_before("log_reader: WRONG: the call of log.process_records with the process handle of the log service gave the outcome ", name))
		for child in children {
			facts_expect_line(t, render(t, file, "Wrong_Child_Records_Call", {{"outcome", word}, {"child", child}}), line_of_before("log_reader: WRONG: the call of log.process_records for ", child, " gave the outcome ", name))
			facts_expect_line(t, render(t, file, "Wrong_Child_Runs_Call", {{"outcome", word}, {"child", child}}), line_of_before("log_reader: WRONG: the call of log.process_value_runs for ", child, " gave the outcome ", name))
		}
		for object in op.Object_Kind {
			for kind in errors.Kind {
				for signed in TEST_FACT_SIGNED {
					facts_expect_line(t, render(t, file, "Wrong_Memory_Lent", {{"outcome", word}, {"kind", u64(kind)}, {"argument", signed_bits(signed)}, {"found_kind", u64(object)}}), line_of_before("log_reader: WRONG: a memory object in place of a process handle gave the outcome ", name, ", the kind ", errors.KIND_NAMES[kind], ", the argument ", signed, " and the found kind ", op.OBJECT_KIND_MEMBER_NAMES[object]))
				}
			}
		}
	}
	// The facts of several records and the log limit of a child, at the
	// edges of their counts.
	for index in 0 ..< len(TEST_FACT_COUNTS) {
		c := TEST_FACT_COUNTS[index]
		o := max(u64) - c
		facts_expect_line(t, render(t, file, "Long_Facts_Read_Back", {{"short_bytes", c}, {"short_records", o}, {"long_bytes", c}, {"long_records", o}}), line_of_before("log_reader: a fact of ", c, " value bytes in ", o, " records and a fact of ", c, " value bytes in ", o, " records, at the bound of a call, read back: each record with its part, the count of its parts and its value bytes, joined whole into the bytes given: as it must"))
		facts_expect_line(t, render(t, file, "Fact_Budget_Checked", {{"log_limit", c}, {"most_records", o}, {"past_limit_records", c}}), line_of_before("log_reader: a child whose log limit holds ", c, " records: a fact of ", o, " records and one of ", c, " were refused whole, each record counted as refused; a fact of as many records as its limit was taken, and one of 3 records after one of 2 in the same budget was refused; its records hold whole facts only: as it must"))
	}
	// The sentences that the machine test waits for, with the values that
	// the process writes.
	facts_expect_line(t, render(t, file, "Long_Facts_Read_Back", {{"short_bytes", u64(op.LOG_FACT_VALUE_CAPACITY + 1)}, {"short_records", u64(2)}, {"long_bytes", u64(op.LOG_FACT_VALUES_MOST)}, {"long_records", u64(op.LOG_FACT_RECORDS_MOST)}}), "log_reader: a fact of 145 value bytes in 2 records and a fact of 1168 value bytes in 9 records, at the bound of a call, read back: each record with its part, the count of its parts and its value bytes, joined whole into the bytes given: as it must")
}
