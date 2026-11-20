package checks

import "core:strings"
import "core:testing"

// The comparison of two records: a measure that a series follows gives
// its two numbers and their ratio; a measure of the first record only, of
// the second only, absent from one run, or whose words changed, says so
// and gives no number. A record with no commit says "unknown".
@(test)
measure_compare_reads_two_records :: proc(t: ^testing.T) {
	records_line :: proc(count: string) -> string {
		return strings.concatenate({"modustool: measure: the records of the log of build/test_output.txt: 412 up to \"kernel: ok\", ", count, " up to \"the machine is usable\""}, context.temp_allocator)
	}
	before := Measure_Record {
		time    = "2026-11-20 01:42 UTC",
		commit  = "72fc3a82e50a96df4ea7dbf647d89e7b3bae4b20",
		numbers = []Measure_Record_Number {
			{sentence = LOG_RECORDS_OF_THE_START_SENTENCE, found = true, line = records_line("2000")},
			{sentence = LOG_MODULE_FILES_SENTENCE, found = true, line = "modustool: measure: the module files: root 1000 bytes, 10 bytes of code; compositor 2000 bytes, 20 bytes of code"},
			{sentence = "Only before", found = true, line = "a line"},
			{sentence = "Absent after", found = true, line = "a line"},
		},
	}
	after := Measure_Record {
		time    = "2026-11-21 01:42 UTC",
		numbers = []Measure_Record_Number {
			{sentence = LOG_RECORDS_OF_THE_START_SENTENCE, found = true, line = records_line("1500")},
			{sentence = LOG_MODULE_FILES_SENTENCE, found = true, line = "modustool: measure: the module files: root cannot be read; compositor cannot be read"},
			{sentence = "Absent after", absent = "build/test_output.txt: no file"},
			{sentence = "Only after", found = true, line = "a line"},
		},
	}
	lines := measure_compare_lines(before, after)
	text := strings.join(lines, "\n", context.temp_allocator)
	testing.expect_value(t, lines[0], "modustool: measure-compare: before, the run of 72fc3a8 of 2026-11-20 01:42 UTC; after, the run of unknown of 2026-11-21 01:42 UTC")
	testing.expect(t, strings.contains(text, "The log records up to a usable machine: 2000 log records before, 1500 after, 0.750 times"), text)
	testing.expect(t, strings.contains(text, "The module file of the root service: the words of a line changed, so no number is compared"), text)
	testing.expect(t, strings.contains(text, "Only before: only in the record before"), text)
	testing.expect(t, strings.contains(text, "Absent after: a run did not give it"), text)
	testing.expect(t, strings.contains(text, "Only after: only in the record after"), text)
	testing.expect(t, !strings.contains(text, "Only before:\n"), text)
}
