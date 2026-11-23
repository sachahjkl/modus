package build

import "core:os"
import "core:strings"
import "core:testing"

// The words that the command reads are in the template of the fact: a
// change of the sentence breaks this test, not the command in silence.
@(test)
the_floors_command_reads_the_template_of_the_fact :: proc(t: ^testing.T) {
	source, read_error := os.read_entire_file("src/modules/system/root/facts_start.odin", context.temp_allocator)
	if !testing.expect(t, read_error == nil) {
		return
	}
	text := string(source)
	template := "root: {ready_process}" + FLOORS_PEAK_MIDDLE + "{peak_pages}" + FLOORS_PEAK_FLOOR + "{floor_pages}" + FLOORS_PEAK_END
	testing.expect(t, strings.contains(text, template), "the template of Budget_Peak_At_Ready is the one that the command reads")
}

// The lines of a log: a peak among other lines, a line with a line end of
// a serial port, a second line of one module (the larger peak holds, also
// when it comes first), the largest numbers, and the lines that are not
// whole: a number that is not one, a number past 64 bits, no floor, no
// end, a name with a space, an empty log.
@(test)
the_floors_command_reads_the_peaks_of_a_log :: proc(t: ^testing.T) {
	log := "kernel: started\n" +
		"root: clock reached its first state of work with a peak of 1500 pages, for a floor of 2400 pages\r\n" +
		"root: clock reached its first state of work with a peak of 900 pages, for a floor of 2400 pages\n" +
		"root: net reached its first state of work with a peak of 0 pages, for a floor of 18446744073709551615 pages\n" +
		"root: net reached its first state of work with a peak of 7 pages, for a floor of 1 pages\n" +
		"root: bad reached its first state of work with a peak of x pages, for a floor of 1 pages\n" +
		"root: big reached its first state of work with a peak of 18446744073709551616 pages, for a floor of 1 pages\n" +
		"root: cut reached its first state of work with a peak of 5 pages\n" +
		"root: end reached its first state of work with a peak of 5 pages, for a floor of 6\n" +
		"root: two words reached its first state of work with a peak of 5 pages, for a floor of 6 pages"
	measures := make([dynamic]Floor_Measure, context.temp_allocator)
	floors_measured_of_text(log, &measures)
	testing.expect_value(t, len(measures), 2)
	testing.expect_value(t, measures[0], Floor_Measure{name = "clock", peak = 1500, floor = 2400})
	testing.expect_value(t, measures[1], Floor_Measure{name = "net", peak = 7, floor = 1})
	empty := make([dynamic]Floor_Measure, context.temp_allocator)
	floors_measured_of_text("", &empty)
	testing.expect_value(t, len(empty), 0)
}

// The working memory that makes the floor the peak, edges first.
@(test)
the_measured_working_memory_makes_the_floor_the_peak :: proc(t: ^testing.T) {
	testing.expect_value(t, working_memory_measured(2048, 2400, 2400), u64(2048))
	testing.expect_value(t, working_memory_measured(2048, 1500, 2400), u64(1148))
	testing.expect_value(t, working_memory_measured(2048, 2600, 2400), u64(2248))
	testing.expect_value(t, working_memory_measured(2048, 0, 2400), u64(0))
	testing.expect_value(t, working_memory_measured(2048, 351, 2400), u64(0))
	testing.expect_value(t, working_memory_measured(2048, 352, 2400), u64(0))
	testing.expect_value(t, working_memory_measured(2048, 353, 2400), u64(1))
	testing.expect_value(t, working_memory_measured(0, 0, 0), u64(0))
	testing.expect_value(t, working_memory_measured(max(u64), 1, 0), max(u64))
	testing.expect_value(t, working_memory_measured(1, max(u64), 0), max(u64))
}
