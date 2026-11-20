package checks

import "core:fmt"
import "core:os"
import "modustool:foundation"

// The comparison of two measure records: two builds, or two runs of one
// build (docs/TOOLS.md, "The comparison of two measure records"). A
// measure that changes the code of a writer, as the conversion of a module
// to log facts, is read from the record of the build before and the record
// of the build after (src/md/features/log_facts.md, "The measures that
// decide it"). The command prints and asserts nothing: two runs of one
// build differ, and the noise of the host is in each number.

// run_measure_compare prints the comparison of the two measure records that
// its two arguments name: the record before, then the record after.
run_measure_compare :: proc(args: []string) -> int {
	if len(args) != 2 {
		fmt.eprintln("modustool measure-compare takes two measure records: the record before, then the record after")
		return foundation.EXIT_USAGE
	}
	records: [2]Measure_Record
	for path, index in args {
		data, read_error := os.read_entire_file(path, context.temp_allocator)
		if read_error != nil {
			fmt.eprintfln("modustool: measure-compare: cannot read %s: %v", path, read_error)
			return foundation.EXIT_FAILURE
		}
		record, problem := measure_record_parse(string(data))
		if problem != "" {
			fmt.eprintfln("modustool: measure-compare: %s is not a measure record: %s", path, problem)
			return foundation.EXIT_FAILURE
		}
		records[index] = record
	}
	for line in measure_compare_lines(records[0], records[1]) {
		fmt.println(line)
	}
	return 0
}

// measure_compare_lines gives the lines of the comparison: the two runs,
// then for each measure of the first record its line in each record, and,
// for a measure that a series follows, its number in each and the ratio of
// the second to the first. A measure that one record does not hold, or
// that one run did not give, says so.
measure_compare_lines :: proc(before, after: Measure_Record) -> []string {
	lines := make([dynamic]string, context.temp_allocator)
	append(&lines, fmt.tprintf("modustool: measure-compare: before, the run of %s of %s; after, the run of %s of %s", measure_compare_commit(before), before.time, measure_compare_commit(after), after.time))
	for number in before.numbers {
		other, in_after := measure_compare_find(after, number.sentence)
		switch {
		case !in_after:
			append(&lines, fmt.tprintf("%s: only in the record before", number.sentence))
		case !number.found || !other.found:
			append(&lines, fmt.tprintf("%s: a run did not give it", number.sentence))
		case:
			append(&lines, fmt.tprintf("%s:", number.sentence), fmt.tprintf("  before: %s", number.line), fmt.tprintf("  after: %s", other.line))
			series, has_series := measure_compare_series(number.sentence)
			if !has_series {
				continue
			}
			before_text, before_value, before_ok := measure_history_value(series, number.line)
			after_text, after_value, after_ok := measure_history_value(series, other.line)
			if !before_ok || !after_ok || before_value <= 0 {
				append(&lines, fmt.tprintf("  %s: the words of a line changed, so no number is compared", series.title))
				continue
			}
			append(&lines, fmt.tprintf("  %s: %s %s before, %s after, %.3f times", series.title, before_text, series.unit, after_text, after_value / before_value))
		}
	}
	for number in after.numbers {
		if _, in_before := measure_compare_find(before, number.sentence); !in_before {
			append(&lines, fmt.tprintf("%s: only in the record after", number.sentence))
		}
	}
	return lines[:]
}

// measure_compare_find gives the number of a record with a sentence.
measure_compare_find :: proc(record: Measure_Record, sentence: string) -> (number: Measure_Record_Number, found: bool) {
	for item in record.numbers {
		if item.sentence == sentence {
			return item, true
		}
	}
	return {}, false
}

// measure_compare_series gives the series that follows a measure.
measure_compare_series :: proc(sentence: string) -> (series: Measure_History_Series, found: bool) {
	for item in measure_history_series {
		if item.sentence == sentence {
			return item, true
		}
	}
	return {}, false
}

// measure_compare_commit gives the short commit of a record, or "unknown".
measure_compare_commit :: proc(record: Measure_Record) -> string {
	if record.commit == "" {
		return "unknown"
	}
	return record.commit[:min(MEASURE_COMMIT_SHORT_LENGTH, len(record.commit))]
}
