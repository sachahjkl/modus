package build

import "modus:contract/call_outcome"
import op "modus:contract/operation"
import "modus:contract/output"
import "modus:contract/value_kinds"
import "modus:sentence"
import "core:strings"
import "core:testing"
import "modustool:foundation"

// The log facts of the wiring service, of the demonstration pair of the
// start list and of the test modules of the record outputs and of
// log.follow against the lines that they replaced
// (src/md/features/log_facts.md). The fact types come from the extraction
// of the tool on the sources of each module: a host test does not depend
// on a build. Each sentence is compared with the parts of the old line
// written by sentence.format, at the edges of each field; a status that
// the line wrote as its number is compared with the name of its member.
// The helpers are in fact_test_helpers_test.odin.

// The edges of a count and of a signed value.
@(private = "file")
OUTPUT_FACT_COUNTS := [3]u64{0, 1, max(u64)}
@(private = "file")
OUTPUT_FACT_SIGNED := [3]i64{-1, 0, max(i64)}

// The test modules whose helper wrong writes the fact Wrong.
@(private = "file")
WRONG_FOLDERS := [?]string{"generic_source", "generic_wiring", "log_follower", "output_count_reader", "output_liar", "output_measure", "output_measure_reader", "output_measure_writer", "output_reader", "output_side", "output_wiring", "output_writer", "requests_pace", "requests_reader"}

// The test modules whose helper wrong_refused writes the fact
// Wrong_Refused.
@(private = "file")
WRONG_REFUSED_FOLDERS := [?]string{"generic_wiring", "log_follower", "output_measure", "output_wiring", "requests_pace"}

// The test modules whose helper refused writes the facts Wrong_Refusal,
// Wrong_Refusal_Wanted and Wrong_Budget.
@(private = "file")
REFUSAL_FOLDERS := [?]string{"generic_wiring", "output_wiring"}

@(private = "file")
output_test_file :: proc(t: ^testing.T, folder: string) -> (file: []u8, ok: bool) {
	return facts_file_of_folder(t, strings.concatenate({foundation.TEST_MODULE_SOURCES, folder}, context.temp_allocator))
}

// The texts of a view at their edges, and the longest check of a caller.
@(private = "file")
output_view_texts :: proc() -> []string {
	texts := make([dynamic]string, context.temp_allocator)
	append(&texts, ..view_texts())
	append(&texts, "the end of a Wire with a step that names no wiring gave the status")
	return texts[:]
}

// The facts Wrong, Wrong_Refused, Wrong_Refusal, Wrong_Refusal_Wanted and
// Wrong_Budget of each test module that has them write the line of
// before, byte for byte, with each text of a view whole, or cut with the
// cut mark past the area.
@(test)
the_wrong_facts_of_the_output_test_modules_write_the_lines_of_before :: proc(t: ^testing.T) {
	texts := output_view_texts()
	for folder in WRONG_FOLDERS {
		file, ok := output_test_file(t, folder)
		if !ok {
			continue
		}
		for text in texts {
			for count in OUTPUT_FACT_COUNTS {
				rendered, written := views_render(t, file, folder, "Wrong", {{"value", count}}, {text})
				if len(written) == 1 {
					facts_expect_line(t, rendered, line_of_before(folder, ": WRONG: ", written[0], " ", count))
				}
			}
		}
	}
	for folder in WRONG_REFUSED_FOLDERS {
		file, ok := output_test_file(t, folder)
		if !ok {
			continue
		}
		for text in texts {
			for count in OUTPUT_FACT_COUNTS {
				other := max(u64) - count
				rendered, written := views_render(t, file, folder, "Wrong_Refused", {{"status", count}, {"error_kind", other}, {"error_unit", count}, {"error_operation", other}, {"error_argument", count}, {"error_value", other}, {"error_limit", count}, {"error_found", other}}, {text})
				if len(written) == 1 {
					facts_expect_line(t, rendered, line_of_before(folder, ": WRONG: ", written[0], " ", count, "; the error record: ", other, " ", count, " ", other, " ", count, " ", other, " ", count, " ", other))
				}
			}
		}
	}
	for folder in REFUSAL_FOLDERS {
		file, ok := output_test_file(t, folder)
		if !ok {
			continue
		}
		for text in texts {
			for outcome in call_outcome.Call_Outcome {
				name := call_outcome.CALL_OUTCOME_NAMES[outcome]
				for value in OUTPUT_FACT_SIGNED {
					bits := signed_bits(value)
					rendered, written := views_render(t, file, folder, "Wrong_Refusal", {{"outcome", u64(outcome)}, {"kind", bits}, {"unit", bits}, {"operation", bits}, {"argument", bits}, {"value", bits}, {"limit", bits}, {"found", bits}}, {text})
					if len(written) == 1 {
						facts_expect_line(t, rendered, line_of_before(folder, ": WRONG: ", written[0], ": the outcome ", name, ", the kind ", value, ", the unit ", value, ", the operation ", value, ", the argument ", value, ", the value ", value, ", the limit ", value, ", the found ", value))
					}
					rendered, written = views_render(t, file, folder, "Wrong_Refusal_Wanted", {{"outcome", u64(outcome)}, {"kind", bits}, {"unit", bits}, {"operation", bits}, {"argument", bits}, {"value", bits}, {"limit", bits}, {"found", bits}}, {text})
					if len(written) == 1 {
						facts_expect_line(t, rendered, line_of_before(folder, ": WRONG: ", written[0], ": wanted the outcome ", name, ", the kind ", value, ", the unit ", value, ", the operation ", value, ", the argument ", value, ", the value ", value, ", the limit ", value, ", the found ", value))
					}
				}
			}
			// An outcome word that names no member keeps its number.
			past := u64(max(call_outcome.Call_Outcome)) + 1
			rendered, written := views_render(t, file, folder, "Wrong_Refusal", {{"outcome", past}}, {text})
			if len(written) == 1 {
				zero := i64(0)
				facts_expect_line(t, rendered, line_of_before(folder, ": WRONG: ", written[0], ": the outcome ", past, ", the kind ", zero, ", the unit ", zero, ", the operation ", zero, ", the argument ", zero, ", the value ", zero, ", the limit ", zero, ", the found ", zero))
			}
			for count in OUTPUT_FACT_COUNTS {
				other := max(u64) - count
				rendered, written = views_render(t, file, folder, "Wrong_Budget", {{"pages_before", count}, {"pages_after", other}}, {text})
				if len(written) == 1 {
					facts_expect_line(t, rendered, line_of_before(folder, ": WRONG: ", written[0], ": the budget held ", count, " pages before and ", other, " after"))
				}
			}
		}
	}
}

// Each fact type of the wiring service writes the line of before, byte for
// byte: a module name of 31 bytes, the longest that its field holds with
// its zero byte, a short one and an empty one; the counts 0, 1 and
// max(u64); a status by the name of its member.
@(test)
the_facts_of_the_wiring_service_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := facts_file_of_folder(t, strings.concatenate({foundation.SYSTEM_MODULE_SOURCES, "wiring"}, context.temp_allocator))
	if !ok {
		return
	}
	names := [3]string{strings.repeat("m", value_kinds.MODULE_NAME_FIELD_BYTES - 1, context.temp_allocator), "log_flood", ""}
	for writer in names {
		for reader in names {
			for count in OUTPUT_FACT_COUNTS {
				other := max(u64) - count
				facts_expect_line(t, fact_test_render(t, file, "wiring", "Log_Wired_To_Asker", {{"wiring_number", count}, {"writer_module", writer}, {"reader_module", reader}}), line_of_before("wiring: wired the record output log of ", sentence.Module_Name{writer}, " to ", "its asker ", sentence.Module_Name{reader}, ", wiring ", count))
				facts_expect_line(t, fact_test_render(t, file, "wiring", "Log_Wired", {{"wiring_number", count}, {"writer_module", writer}, {"reader_module", reader}}), line_of_before("wiring: wired the record output log of ", sentence.Module_Name{writer}, " to ", "", sentence.Module_Name{reader}, ", wiring ", count))
				facts_expect_line(t, fact_test_render(t, file, "wiring", "Output_Wired_To_Asker", {{"writer_output", other}, {"wiring_number", count}, {"writer_module", writer}, {"reader_module", reader}}), line_of_before("wiring: wired the record output ", other, " of ", sentence.Module_Name{writer}, " to ", "its asker ", sentence.Module_Name{reader}, ", wiring ", count))
				facts_expect_line(t, fact_test_render(t, file, "wiring", "Output_Wired", {{"writer_output", other}, {"wiring_number", count}, {"writer_module", writer}, {"reader_module", reader}}), line_of_before("wiring: wired the record output ", other, " of ", sentence.Module_Name{writer}, " to ", "", sentence.Module_Name{reader}, ", wiring ", count))
			}
		}
		for count in OUTPUT_FACT_COUNTS {
			facts_expect_line(t, fact_test_render(t, file, "wiring", "Wiring_End_Refused", {{"wiring_number", count}, {"process_module", writer}}), line_of_before("wiring: ", sentence.Module_Name{writer}, " refused its end of the wiring ", count))
			facts_expect_line(t, fact_test_render(t, file, "wiring", "Wiring_Word_Dropped", {{"wiring_number", count}, {"process_module", writer}}), line_of_before("wiring: ", sentence.Module_Name{writer}, " wrote a word of its wiring ring for the wiring ", count, " after its answer: dropped"))
		}
		facts_expect_line(t, fact_test_render(t, file, "wiring", "Unknown_Wiring_Word", {{"process_module", writer}}), line_of_before("wiring: ", sentence.Module_Name{writer}, " wrote a word of its wiring ring that names no wiring of it: it is dropped, and each later one is counted until its stop"))
	}
	for count in OUTPUT_FACT_COUNTS {
		facts_expect_line(t, fact_test_render(t, file, "wiring", "Stop_Notice_Refused", {{"notice_kind", count}}), line_of_before("wiring: refused malformed stop notice on stops ring, kind ", count))
		facts_expect_line(t, fact_test_render(t, file, "wiring", "Ready", {{"image_bytes", count}}), line_of_before("wiring: ready, read-only boot image ", count, " bytes"))
		facts_expect_line(t, fact_test_render(t, file, "wiring", "Stalled_Wiring_Revoked", {{"wiring_number", count}}), line_of_before("wiring: revoked stalled Always_Holds_Writer wiring ", count))
		for status in op.Status {
			facts_expect_line(t, fact_test_render(t, file, "wiring", "End_Page_Not_Mapped", {{"wiring_slot", count}, {"status", u64(status)}}), line_of_before("wiring: cannot map end page of slot ", count, ": status ", op.STATUS_NAMES[status]))
		}
		past := u64(max(op.Status)) + 1
		facts_expect_line(t, fact_test_render(t, file, "wiring", "End_Page_Not_Mapped", {{"wiring_slot", count}, {"status", past}}), line_of_before("wiring: cannot map end page of slot ", count, ": status ", past))
	}
	reasons := [?][2]string{{"No_Service_Ring", "no service ring"}, {"No_Stops_Ring", "no stops ring"}, {"No_Boot_Image", "no read-only boot image"}, {"Boot_Image_Not_Mapped", "cannot map boot image"}, {"Transfer_Region_Too_Small", "transfer region too small"}, {"Transfer_Region_Not_Mapped", "cannot map transfer region"}}
	for reason in reasons {
		facts_expect_line(t, fact_test_render(t, file, "wiring", reason[0], {}), line_of_before("wiring: ", reason[1]))
	}
}

// Each fact type of the demonstration pair of the start list writes the
// line of before, byte for byte.
@(test)
the_facts_of_the_wired_pair_write_the_lines_of_before :: proc(t: ^testing.T) {
	reader_file, reader_ok := facts_file_of_folder(t, strings.concatenate({foundation.DEMONSTRATION_MODULE_SOURCES, "wired_reader"}, context.temp_allocator))
	writer_file, writer_ok := facts_file_of_folder(t, strings.concatenate({foundation.DEMONSTRATION_MODULE_SOURCES, "wired_writer"}, context.temp_allocator))
	if !reader_ok || !writer_ok {
		return
	}
	for count in OUTPUT_FACT_COUNTS {
		other := max(u64) - count
		facts_expect_line(t, fact_test_render(t, reader_file, "wired_reader", "Numbers_Read", {{"numbers", count}}), line_of_before("wired_reader: read the joined record of 0, the ", count, " numbers of wired_writer in order, and a clean end: the start list wired them before the first instruction of the writer"))
		facts_expect_line(t, fact_test_render(t, writer_file, "wired_writer", "Numbers_Written", {{"numbers", count}, {"readers", other}}), line_of_before("wired_writer: wrote ", count, " numbers to ", other, " reader, and ended numbers"))
		for text in output_view_texts() {
			rendered, written := views_render(t, reader_file, "wired_reader", "Wrong", {{"value", count}}, {text})
			if len(written) == 1 {
				facts_expect_line(t, rendered, line_of_before("wired_reader: WRONG: ", written[0], " ", count))
			}
		}
	}
}

// One fact type with no field of the test modules: its folder, its name,
// and the line that it replaced.
@(private = "file")
Output_Fact_With_No_Field :: struct {
	folder, type_name, line: string,
}

// Each fact type with no field writes the line of before, byte for byte.
@(test)
the_facts_with_no_field_of_the_output_test_modules_write_the_lines_of_before :: proc(t: ^testing.T) {
	facts := [?]Output_Fact_With_No_Field {
		{"generic_wiring", "Refusals_Checked", "generic_wiring: a second source of another record, a generic output with no fixed type, a record of no terms into a running generic input and a condition on no field: refused, each with its status and its error record and the budget unchanged: as it must"},
		{"generic_wiring", "No_Field_Ended", "generic_wiring: filter with a condition on the field 0 ended kept at once with the error record of that field: as it must"},
		{"log_follower", "Flood_Record", "log_follower: a record of the flood"},
		{"output_liar", "Waits_For_Reader", "output_liar: it waits for a reader"},
		{"output_liar", "Record_Written_Past_Condition", "output_liar: wrote a record of the status 200 into a ring whose wiring has a condition: as it must"},
		{"output_measure", "Measured", "output_measure: the writer with 1, 2, 4 and 8 readers, each record read in order by each reader, and with its log wired, each log record read in order: as it must"},
		{"output_reader", "Watched_Read", "output_reader: watched: the joined record and one probe, then this reader stops: as it must"},
		{"output_side", "Ends_Written", "output_side: refused the end of its start; for the end of a Wire, wrote Closed for a number of no wiring, then Taken, Taken again, one probe and Closed; it reads no more commands: as it must"},
		{"output_wiring", "List_Page_Checked", "output_wiring: Wire before its list page, with a step that names nothing and with a reserved word, and the list page past the budget: refused, each with its status and its error record, the budget unchanged; then the list page, its handle revoked, unmapped and closed, and a new handle of it: as it must"},
		{"output_wiring", "Start_Refusals_Checked", "output_wiring: the refusals of Start and of its list, each with its status and its error record and the budget unchanged: as it must"},
		{"output_wiring", "Stopped_Ends_Checked", "output_wiring: the writer that stopped and the reader that stopped: as it must"},
		{"output_wiring", "Checked", "output_wiring: ok"},
		{"output_writer", "Unended_Written", "output_writer: unended: one probe, then the stop with no end record: as it must"},
		{"requests_reader", "Phase_One_Read", "requests_reader: phase 1 read"},
		{"requests_reader", "Phase_Two_Read", "requests_reader: phase 2 read"},
	}
	for fact in facts {
		file, ok := output_test_file(t, fact.folder)
		if !ok {
			continue
		}
		facts_expect_line(t, fact_test_render(t, file, fact.folder, fact.type_name, {}), fact.line)
	}
}

// Each fact type of the test modules of the record outputs with fields
// writes the line of before, byte for byte, at the edges of each field.
@(test)
the_facts_of_the_output_test_modules_write_the_lines_of_before :: proc(t: ^testing.T) {
	folders := [?]string{"generic_source", "generic_wiring", "log_follower", "output_counter", "output_count_reader", "output_measure", "output_measure_reader", "output_measure_writer", "output_reader", "output_wiring", "output_writer", "requests_pace", "requests_reader"}
	files := make(map[string][]u8, context.temp_allocator)
	for folder in folders {
		file, ok := output_test_file(t, folder)
		if !ok {
			return
		}
		files[folder] = file
	}
	end_words := [?]output.End_Word{.Writer_Stopped, .Reader_Stopped, .Asker_Stopped, .Side_Closed, .None}
	for count in OUTPUT_FACT_COUNTS {
		a := count
		b := max(u64) - count
		for signed in OUTPUT_FACT_SIGNED {
			s := signed_bits(signed)
			facts_expect_line(t, fact_test_render(t, files["generic_wiring"], "generic_wiring", "Wrong_Kept_End", {{"end_word", a}, {"error_kind", s}, {"records", b}, {"wanted_records", a}}), line_of_before("generic_wiring: WRONG: filter.kept ended with the end word ", a, " and the error kind ", signed, " after ", b, " records; wanted a clean end record after ", a))
			facts_expect_line(t, fact_test_render(t, files["generic_wiring"], "generic_wiring", "Wrong_No_Field_End", {{"joined_status_word", a}, {"end_status_word", b}, {"end_word", a}, {"error_kind", s}, {"error_unit", s}, {"error_argument", s}, {"error_value", s}, {"error_limit", s}}), line_of_before("generic_wiring: WRONG: filter with the field 0: the joined status word ", a, ", the end status word ", b, ", the end word ", a, ", the error kind ", signed, ", unit ", signed, ", argument ", signed, ", value ", signed, ", limit ", signed))
			facts_expect_line(t, fact_test_render(t, files["log_follower"], "log_follower", "Wrong_After_Gap", {{"gap_count", a}, {"gap_serial", b}, {"kind_word", a}, {"serial", b}, {"row_number", s}, {"last_row_number", s}}), line_of_before("log_follower: WRONG: after the gap of ", a, " records from the serial ", b, ": the kind word ", a, ", the serial ", b, " and the number ", signed, "; the last row before the gap had the number ", signed))
			facts_expect_line(t, fact_test_render(t, files["log_follower"], "log_follower", "Wrong_Before_Gap", {{"kind_word", a}, {"serial", b}, {"row_number", s}, {"last_serial", a}, {"last_row_number", s}}), line_of_before("log_follower: WRONG: before the gap: the kind word ", a, ", the serial ", b, " and the number ", signed, " after the serial ", a, " and the number ", signed))
		}
		facts_expect_line(t, fact_test_render(t, files["generic_source"], "generic_source", "Probes_Written", {{"probes", a}}), line_of_before("generic_source: wrote ", a, " probes into left and into right, and ended both"))
		facts_expect_line(t, fact_test_render(t, files["generic_wiring"], "generic_wiring", "Wrong_Kept_Record", {{"status_word", a}, {"kind_word", b}, {"serial", a}, {"probe_side", b}, {"probe_number", a}, {"probe_mark", b}, {"wanted_serial", a}}), line_of_before("generic_wiring: WRONG: filter.kept gave the status word ", a, ", the kind word ", b, ", the serial ", a, " and the probe of the side ", b, ", number ", a, ", mark ", b, "; wanted the serial ", a))
		facts_expect_line(t, fact_test_render(t, files["generic_wiring"], "generic_wiring", "Chain_Kept", {{"probes", a}}), line_of_before("generic_wiring: generic_source to merge to filter with mark = 1 to this asker, in one start list, after a refused Wire of Other into filter.source kept no type: the joined record of 0, the ", a, " probes of mark 1 of the two sides, each side in its order, then a clean end: as it must"))
		facts_expect_line(t, fact_test_render(t, files["generic_wiring"], "generic_wiring", "Checked", {{"refusals", a}}), line_of_before("generic_wiring: ok, after ", a, " refusals"))
		facts_expect_line(t, fact_test_render(t, files["log_follower"], "log_follower", "Wrong_Flood_Not_Taken", {{"target", a}, {"written", b}, {"bound_milliseconds", a}}), line_of_before("log_follower: WRONG: the kernel took fewer than ", a, " of ", b, " lines within the hang bound, in milliseconds: ", a))
		facts_expect_line(t, fact_test_render(t, files["log_follower"], "log_follower", "Wrong_Read", {{"status_word", a}, {"kind_word", b}, {"end_word", a}}), line_of_before("log_follower: WRONG: a read of log.follow gave the status word ", a, ", the kind word ", b, " and the end word ", a))
		facts_expect_line(t, fact_test_render(t, files["log_follower"], "log_follower", "Wrong_Gap", {{"serial", a}, {"gap_count", b}, {"rows_before", a}, {"last_serial", b}}), line_of_before("log_follower: WRONG: the gap record of log.follow: the serial ", a, " and the count ", b, " after ", a, " rows, the last of the serial ", b))
		facts_expect_line(t, fact_test_render(t, files["log_follower"], "log_follower", "Gap_Read", {{"rows_before", a}, {"gap_count", b}, {"written", a}}), line_of_before("log_follower: log.follow gave ", a, " rows in order, then one gap record of ", b, " records that the kernel wrote over, then the row of the number after them, after ", a, " lines of this process that the kernel took: as it must"))
		facts_expect_line(t, fact_test_render(t, files["output_counter"], "output_counter", "Running", {{"interval_milliseconds", a}}), line_of_before("output_counter: it writes one record of counts each ", a, " ms while a reader is wired, and waits for a reader"))
		facts_expect_line(t, fact_test_render(t, files["output_counter"], "output_counter", "Reader_Left", {{"records", a}}), line_of_before("output_counter: counts has no reader after ", a, " records: it waits for one"))
		facts_expect_line(t, fact_test_render(t, files["output_count_reader"], "output_count_reader", "Counts_Read", {{"joined_serial", a}, {"records", b}, {"first_serial", a}, {"second_serial", b}, {"third_serial", a}}), line_of_before("output_count_reader: joined after ", a, " records, then ", b, " records of the status 404, serials ", a, ", ", b, " and ", a, ", each 3 or more past the one before: as it must"))
		facts_expect_line(t, fact_test_render(t, files["output_measure"], "output_measure", "Wrong_Log_Record", {{"record_serial", a}, {"status_word", b}, {"kind_word", a}, {"serial", b}}), line_of_before("output_measure: WRONG: the log of the writer: the record ", a, " came as the status word ", b, ", the kind word ", a, " and the serial ", b))
		facts_expect_line(t, fact_test_render(t, files["output_measure"], "output_measure", "Wrong_Log_End", {{"end_word", a}, {"stop_outcome", b}, {"records", a}}), line_of_before("output_measure: WRONG: the log of the writer ended with the end word ", a, " and the stop outcome ", b, " after ", a, " records"))
		facts_expect_line(t, fact_test_render(t, files["output_measure"], "output_measure", "Log_Read", {{"records", a}}), line_of_before("output_measure: the log of the writer, wired: ", a, " records in order, then its stop"))
		facts_expect_line(t, fact_test_render(t, files["output_measure_reader"], "output_measure_reader", "Wrong_Record", {{"wanted_serial", a}, {"status_word", b}, {"kind_word", a}, {"serial", b}}), line_of_before("output_measure_reader: WRONG: wanted the record ", a, ", read the status word ", b, ", the kind word ", a, " and the serial ", b))
		facts_expect_line(t, fact_test_render(t, files["output_measure_reader"], "output_measure_reader", "Wake_Measured", {{"least", a}, {"median", b}, {"wake_records", a}, {"burst_records", b}, {"wakes", a}}), line_of_before("output_measure_reader: the wake: from a write to the read of a reader that waits on another processor: least ", a, ", median ", b, " cycles, of ", a, " records; a burst of ", b, " records: ", a, " wakes"))
		facts_expect_line(t, fact_test_render(t, files["output_measure_writer"], "output_measure_writer", "Write_Measured", {{"readers", a}, {"record_bytes", b}, {"least", a}, {"median", b}, {"writes", a}}), line_of_before("output_measure_writer: ", a, " readers: one write of a record of ", b, " bytes into the ring of each reader: least ", a, ", median ", b, " cycles, of ", a, " writes"))
		facts_expect_line(t, fact_test_render(t, files["output_measure_writer"], "output_measure_writer", "Log_Fact_Measured", {{"least", a}, {"median", b}, {"facts", a}}), line_of_before("output_measure_writer: one log fact of the same record: least ", a, ", median ", b, " cycles, of ", a, " facts"))
		for state in ([2]string{"wired", "not wired"}) {
			facts_expect_line(t, fact_test_render(t, files["output_measure_writer"], "output_measure_writer", "Measure_Nine_Fact", {{"least", a}, {"median", b}, {"facts", a}, {"log_state", state}}), line_of_before("output_measure_writer: measure 9, the log ", state, ": one log fact: least ", a, ", median ", b, " cycles, of ", a, " facts"))
			facts_expect_line(t, fact_test_render(t, files["output_measure_writer"], "output_measure_writer", "Measure_Nine_Line", {{"least", a}, {"median", b}, {"lines", a}, {"log_state", state}}), line_of_before("output_measure_writer: measure 9, the log ", state, ": one line of text with one value: least ", a, ", median ", b, " cycles, of ", a, " lines"))
		}
		facts_expect_line(t, fact_test_render(t, files["output_reader"], "output_reader", "Probes_Read", {{"joined_serial", a}, {"first_probe", b}, {"last_probe", a}}), line_of_before("output_reader: probes: joined after ", a, " records, the probes ", b, " to ", a, " in order, and a clean end: as it must"))
		facts_expect_line(t, fact_test_render(t, files["output_writer"], "output_writer", "Probes_Written", {{"probes", a}, {"probes_before_second", b}}), line_of_before("output_writer: probes: ", a, " probes to two readers, the second one after ", b, ", a clean end, and Ended after it: as it must"))
		facts_expect_line(t, fact_test_render(t, files["output_writer"], "output_writer", "Large_Rings_Revoked", {{"rings", a}}), line_of_before("output_writer: large: ", a, " rings, each ended with the end word Revoked: as it must"))
		facts_expect_line(t, fact_test_render(t, files["output_wiring"], "output_wiring", "Lent_Handles_Given_Back", {{"lent_handles", a}}), line_of_before("output_wiring: ", a, " lent handles given back with lists of no row, each list refused with its status and its error record and the budget unchanged: as it must"))
		facts_expect_line(t, fact_test_render(t, files["output_wiring"], "output_wiring", "Wiring_Refusals_Checked", {{"lent_handles", a}, {"conditions", b}}), line_of_before("output_wiring: the refusals of a wiring, each with its status and its error record and the budget unchanged, ", a, " lent memory handles among them, ", b, " conditions that the root service refuses at its border, and the Wire of the second reader: as it must"))
		facts_expect_line(t, fact_test_render(t, files["output_wiring"], "output_wiring", "Wrong_Log_Record", {{"record_serial", a}, {"status_word", b}, {"kind_word", a}, {"serial", b}}), line_of_before("output_wiring: WRONG: the log of log_flood: the record ", a, " came as the status word ", b, ", the kind word ", a, " and the serial ", b))
		facts_expect_line(t, fact_test_render(t, files["output_wiring"], "output_wiring", "Wrong_Flood_Fact", {{"record_serial", a}, {"form_word", b}, {"level_word", a}, {"part", b}, {"part_count", a}, {"value_count", b}}), line_of_before("output_wiring: WRONG: the log of log_flood: the record ", a, " is not the fact Flood_Fact: the form ", b, ", the level ", a, ", the part ", b, " of ", a, ", the values ", b))
		facts_expect_line(t, fact_test_render(t, files["output_wiring"], "output_wiring", "Wrong_Log_Ring_Not_Full", {{"end_word", a}, {"held_compartments", b}, {"capacity", a}}), line_of_before("output_wiring: WRONG: the ring of the log of log_flood was not full with log_flood waiting on it: the end ", a, ", ", b, " compartments of ", a))
		facts_expect_line(t, fact_test_render(t, files["output_wiring"], "output_wiring", "Wrong_Flood_Stop", {{"stop_cause_word", a}, {"stop_outcome_word", b}}), line_of_before("output_wiring: WRONG: log_flood, held by its log, stopped after the end of its reader with the cause ", a, " and the outcome ", b, "; wanted itself and Done"))
		facts_expect_line(t, fact_test_render(t, files["output_wiring"], "output_wiring", "Flood_Log_Kept", {{"records", a}, {"calls", b}}), line_of_before("output_wiring: the log of log_flood kept its ", a, " records in order while the kernel refused its ", b, " calls; then this asker closed its end, and log_flood, which its log held, stopped with Done: as it must"))
		facts_expect_line(t, fact_test_render(t, files["output_wiring"], "output_wiring", "Asker_Limit_Checked", {{"wirings", a}}), line_of_before("output_wiring: ", a, " wirings of one asker, past 8, 9 and 20, until its budget paid no more; one more refused with Wire and with a Start, each with the budget unchanged, then the revocation of the grant wirings: as it must"))
		facts_expect_line(t, fact_test_render(t, files["output_wiring"], "output_wiring", "Side_Checked", {{"ends", a}}), line_of_before("output_wiring: the end that a side refused ended with Refused, the wiring that a side closed gave its probe then Side_Closed, and ", a, " ends filled the wiring ring that it does not read, then one more refused with Busy, its status and its error record and the budget unchanged: as it must"))
		facts_expect_line(t, fact_test_render(t, files["output_wiring"], "output_wiring", "Asker_Wiring_Checked", {{"refusals", a}}), line_of_before("output_wiring: the wiring of this asker gave the joined record of 0 and the probe 0, after ", a, " refusals; this asker stops: as it must"))
		facts_expect_line(t, fact_test_render(t, files["requests_pace"], "requests_pace", "Server_Runs", {{"ring_capacity", a}}), line_of_before("requests_pace: server runs with three readers of requests: held of the pace Always_Holds_Writer and gapped of the pace Never_Holds_Writer, in rings of ", a, ", and this process, the fast reader"))
		facts_expect_line(t, fact_test_render(t, files["requests_pace"], "requests_pace", "Wrong_Fast_Record", {{"wanted_serial", a}, {"status_word", b}, {"kind_word", a}, {"serial", b}}), line_of_before("requests_pace: WRONG: the fast reader wanted the record ", a, ", and read the status word ", b, ", the kind word ", a, " and the serial ", b))
		facts_expect_line(t, fact_test_render(t, files["requests_pace"], "requests_pace", "Wrong_Counts", {{"written", a}, {"discarded", b}, {"refused", a}, {"held", b}, {"wanted_written", a}, {"wanted_held", b}}), line_of_before("requests_pace: WRONG: the counts of the server: written ", a, ", discarded ", b, ", refused ", a, ", held ", b, "; wanted ", a, ", 0, 0 and ", b))
		facts_expect_line(t, fact_test_render(t, files["requests_pace"], "requests_pace", "Fast_Reader_Read", {{"records", a}}), line_of_before("requests_pace: the fast reader read the ", a, " records; it waits for the stop of server"))
		facts_expect_line(t, fact_test_render(t, files["requests_pace"], "requests_pace", "Fast_Reader_Checked", {{"records", a}, {"held", b}}), line_of_before("requests_pace: the fast reader: the joined record of 0 and the ", a, " records in order, no gap; the server was held ", b, " times by the slow reader of the pace Always_Holds_Writer and refused no record: as it must"))
		facts_expect_line(t, fact_test_render(t, files["requests_reader"], "requests_reader", "Wrong_Held_Not_Full", {{"phase", a}, {"end_word", b}}), line_of_before("requests_reader: WRONG: the ring of held was not full with the server waiting on it, in the phase ", a, "; the end word ", b))
		facts_expect_line(t, fact_test_render(t, files["requests_reader"], "requests_reader", "Wrong_Counts", {{"written", a}, {"discarded", b}, {"refused", a}, {"held", b}, {"rings_past_gap", a}, {"wanted_written", b}, {"wanted_held", a}}), line_of_before("requests_reader: WRONG: the counts of the server in the ring of held: written ", a, ", discarded ", b, ", refused ", a, ", held ", b, ", past their gap ", a, "; wanted ", b, ", 0, 0, ", a, " and 0"))
		facts_expect_line(t, fact_test_render(t, files["requests_reader"], "requests_reader", "Held_Read", {{"records", a}, {"ring_capacity", b}}), line_of_before("requests_reader: held, of the pace Always_Holds_Writer: the joined record of 0 and the ", a, " records in order, no gap, with a ring of ", b, " that held the server twice: as it must"))
		facts_expect_line(t, fact_test_render(t, files["requests_reader"], "requests_reader", "Gapped_Read", {{"records", a}, {"gap_records", b}, {"gap_serial", a}}), line_of_before("requests_reader: gapped, of the pace Never_Holds_Writer: the joined record of 0, ", a, " records, and one gap record of exactly ", b, " records from the serial ", a, ", which the records around it meet: as it must"))
		for end_word in end_words {
			word_name := output.end_word_names[end_word]
			facts_expect_line(t, fact_test_render(t, files["output_measure_reader"], "output_measure_reader", "Wrong_End", {{"records", a}, {"status_word", b}, {"end_word", word_name}}), line_of_before("output_measure_reader: WRONG: after ", a, " records, the status word ", b, " and the end word ", word_name))
			for case_name in ([2]string{"watched", "asked"}) {
				facts_expect_line(t, fact_test_render(t, files["output_writer"], "output_writer", "Ring_Ended", {{"case_name", case_name}, {"end_word", word_name}}), line_of_before("output_writer: ", case_name, ": the ring ended with the end word ", word_name, ": as it must"))
			}
			for cause in op.Stop_Cause {
				for outcome in op.Stop_Outcome {
					facts_expect_line(t, fact_test_render(t, files["output_reader"], "output_reader", "Unended_Read", {{"stop_cause", u64(cause)}, {"stop_outcome", u64(outcome)}, {"end_word", word_name}}), line_of_before("output_reader: unended: the joined record of 0, one probe, then the end word ", word_name, " with the stop ", op.STOP_CAUSE_TEXTS[cause], ", ", op.STOP_OUTCOME_TEXTS[outcome], ": as it must"))
				}
			}
		}
	}
	// The facts with a text view, at the edges of their texts: each text
	// whole in the sentence, or cut with the cut mark past the area.
	texts := output_view_texts()
	for text in texts {
		for count in OUTPUT_FACT_COUNTS {
			other := max(u64) - count
			rendered, written := views_render(t, files["output_wiring"], "output_wiring", "Wrong_Budget_Not_Settled", {{"pages_held", count}, {"pages_wanted", other}}, {text})
			if len(written) == 1 {
				facts_expect_line(t, rendered, line_of_before("output_wiring: WRONG: after ", written[0], ", the budget held ", count, " pages within the hang bound, and ", other, " at its start"))
			}
			rendered, written = views_render(t, files["output_wiring"], "output_wiring", "Wrong_Log_Text", {{"record_serial", count}, {"form_word", other}, {"level_word", count}, {"more", other}, {"runs", count}}, {text, "log_flood: line 599"})
			if len(written) == 2 {
				facts_expect_line(t, rendered, line_of_before("output_wiring: WRONG: the log of log_flood: the record ", count, " has the form ", other, ", the level ", count, ", more ", other, ", the runs ", count, " and the text \"", written[0], "\"; wanted \"", written[1], "\""))
			}
			rendered, written = views_render(t, files["requests_reader"], "requests_reader", "Wrong_Read_Status", {{"serial", count}, {"status_word", other}}, {text})
			if len(written) == 1 {
				facts_expect_line(t, rendered, line_of_before("requests_reader: WRONG: ", written[0], ": the read of the serial ", count, " gave the status word ", other))
			}
			rendered, written = views_render(t, files["requests_reader"], "requests_reader", "Wrong_Read_Record", {{"wanted_kind_word", count}, {"wanted_serial", other}, {"kind_word", count}, {"serial", other}}, {text})
			if len(written) == 1 {
				facts_expect_line(t, rendered, line_of_before("requests_reader: WRONG: ", written[0], ": wanted the kind word ", count, " and the serial ", other, ", read the kind word ", count, " and the serial ", other))
			}
			for end_word in end_words {
				word_name := output.end_word_names[end_word]
				rendered, written = views_render(t, files["requests_reader"], "requests_reader", "Wrong_End_Not_Read", {{"status_word", count}, {"end_word", word_name}}, {text})
				if len(written) == 1 {
					facts_expect_line(t, rendered, line_of_before("requests_reader: WRONG: ", written[0], ": after the last request, the status word ", count, " (No_Record: no end within the hang bound)", " and the end word ", word_name))
				}
				rendered, written = views_render(t, files["requests_reader"], "requests_reader", "Wrong_End", {{"status_word", count}, {"end_word", word_name}}, {text})
				if len(written) == 1 {
					facts_expect_line(t, rendered, line_of_before("requests_reader: WRONG: ", written[0], ": after the last request, the status word ", count, "", " and the end word ", word_name))
				}
			}
		}
	}
}

// The Text fields of these fact types hold the longest text of their
// writer and a zero byte, and come after the other fields.
@(test)
the_texts_of_the_output_test_module_facts_come_last_and_whole :: proc(t: ^testing.T) {
	most := make(map[string]u32, context.temp_allocator)
	longest_end_word: u32 = 0
	for name in output.end_word_names {
		longest_end_word = max(longest_end_word, u32(len(name)))
	}
	most["end_word"] = longest_end_word
	most["case_name"] = u32(len("watched"))
	most["log_state"] = u32(len("not wired"))
	// The access record that output_measure_writer measures.
	most["method"] = u32(len("GET"))
	most["target"] = u32(len("/counts.json"))
	most["peer"] = u32(len("10.0.2.2 port 49200"))
	folders := [?]string{"output_measure_reader", "output_measure_writer", "output_reader", "output_writer", "requests_reader"}
	for folder in folders {
		file, ok := output_test_file(t, folder)
		if !ok {
			continue
		}
		facts_expect_text_fields_last(t, file, most)
	}
	wiring_file, wiring_ok := facts_file_of_folder(t, strings.concatenate({foundation.SYSTEM_MODULE_SOURCES, "wiring"}, context.temp_allocator))
	if wiring_ok {
		names := make(map[string]u32, context.temp_allocator)
		names["writer_module"] = value_kinds.MODULE_NAME_FIELD_BYTES - 1
		names["reader_module"] = value_kinds.MODULE_NAME_FIELD_BYTES - 1
		names["process_module"] = value_kinds.MODULE_NAME_FIELD_BYTES - 1
		facts_expect_text_fields_last(t, wiring_file, names)
	}
}
