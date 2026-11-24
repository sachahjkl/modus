package machine

import "core:os"
import "core:strings"
import "core:testing"

// The mark of the check is in the template of the fact that the root
// service writes: a change of the sentence breaks this test, not the
// check in silence.
@(test)
the_floor_mark_is_in_the_fact_of_the_root_service :: proc(t: ^testing.T) {
	source, read_error := os.read_entire_file("src/modules/system/root/facts_start.odin", context.temp_allocator)
	if !testing.expect(t, read_error == nil, "the facts of the starts of the root service are readable") {
		return
	}
	text := string(source)
	place := strings.index(text, "Budget_Floor_Passed :: struct")
	testing.expect(t, place > 0, "the fact Budget_Floor_Passed exists")
	template_start := strings.last_index(text[:max(place, 0)], "@(log_fact = ")
	testing.expect(t, template_start >= 0 && strings.contains(text[template_start:place], FLOOR_PASSED_MARK), "the template of Budget_Floor_Passed holds the mark of the check")
}

// The check finds the line among others, at the first line, at the last
// line with no line end, and finds nothing in a log with no such line, in
// an empty log, and in the measure of a peak under its floor.
@(test)
the_floor_check_finds_the_passed_floor :: proc(t: ^testing.T) {
	passed := "root: clock passed its floor before its first state of work: a peak of 6656 pages, for a floor of 6195 pages"
	measure := "root: clock reached its first state of work with a peak of 5120 pages, for a floor of 6195 pages"
	_, found := floor_passed_line("")
	testing.expect(t, !found, "an empty log passes")
	_, found = floor_passed_line(strings.concatenate({measure, "\n"}, context.temp_allocator))
	testing.expect(t, !found, "a peak under the floor passes")
	line: string
	line, found = floor_passed_line(passed)
	testing.expect(t, found && line == passed, "the last line with no line end is read")
	line, found = floor_passed_line(strings.concatenate({measure, "\n", passed, "\n", measure, "\n"}, context.temp_allocator))
	testing.expect(t, found && line == passed, "the line among others is found")
	line, found = floor_passed_line(strings.concatenate({passed, "\r\n"}, context.temp_allocator))
	testing.expect(t, found && line == passed, "the line end of a serial port is no part of the line")
}
