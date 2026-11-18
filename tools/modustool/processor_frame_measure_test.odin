package modustool

import "core:strings"
import "core:testing"

// The times of a line in the form of the process.
@(private = "file")
times_text :: proc(least, median, frames, rounds: string) -> string {
	return strings.concatenate({PROCESSOR_FRAME_LEAST, least, PROCESSOR_FRAME_MEDIAN, median, PROCESSOR_FRAME_FRAMES, frames, PROCESSOR_FRAME_ROUNDS, rounds, PROCESSOR_FRAME_END}, context.temp_allocator)
}

// A log of a measure run with the four lines and the last line, each part
// with the same right times, and the line of one part replaced when
// replaced_part is not "".
@(private = "file")
log_of_the_run :: proc(replaced_part: string = "", replaced_line: string = "") -> string {
	lines := make([dynamic]string, context.temp_allocator)
	append(&lines, "[root] root: ok")
	for part in processor_frame_parts {
		line := strings.concatenate({"[processor_frame] ", part, times_text("2310.4", "2401.7", "416", "21")}, context.temp_allocator)
		if part == replaced_part {
			line = replaced_line
		}
		if line != "" {
			append(&lines, line)
		}
	}
	append(&lines, strings.concatenate({"[processor_frame] ", PROCESSOR_FRAME_DONE, ", the drawing module refused no call, and each table holds each of its records"}, context.temp_allocator))
	return strings.join(lines[:], "\n", context.temp_allocator)
}

// Each line whose times are not in the form is refused with its reason;
// the edges of the frames in one second first.
@(test)
processor_frame_line_problem_refuses_each_broken_form :: proc(t: ^testing.T) {
	Case :: struct {
		times:   string,
		problem: string, // A part of the reason.
	}
	cases := [?]Case {
		{times_text("2310", "2401.7", "416", "21"), "the least \"2310\" is not a time with one decimal"},
		{times_text("2310.45", "2401.7", "416", "21"), "the least \"2310.45\""},
		{times_text("-1.0", "2401.7", "416", "21"), "the least \"-1.0\""},
		{times_text(".4", "2401.7", "416", "21"), "the least \".4\""},
		{times_text("2310.4", "2401.x", "416", "21"), "the median \"2401.x\""},
		{times_text("2310.4", "2401.7", "+416", "21"), "the frames in one second \"+416\""},
		{times_text("2310.4", "2401.7", "416", ""), "the count of frames \"\""},
		{times_text("2310.4", "2401.7", "416", "0"), "the part ran 0 frames"},
		{times_text("0.0", "0.0", "0", "21"), "the median is 0.0 us"},
		{times_text("2401.8", "2401.7", "416", "21"), "is above the median"},
		// 10 000 000 / 24017 tenths: at most 416, at least 416.
		{times_text("2310.4", "2401.7", "417", "21"), "do not follow from the median"},
		{times_text("2310.4", "2401.7", "414", "21"), "do not follow from the median"},
		{": least 2310.4 us, mean 2401.7 us, 416 frames in one second at the median, over 21 frames", "its times are not in the words"},
		{": least 2310.4 us, median 2401.7 us, 416 frames in one second at the median, over 21", "its times are not in the words"},
		{"a line with no times", "it has no \": least \""},
	}
	for item in cases {
		line := strings.concatenate({PROCESSOR_FRAME_CLEAR_AND_PRESENT, item.times}, context.temp_allocator)
		problem := processor_frame_line_problem(line)
		testing.expectf(t, strings.contains(problem, item.problem), "the line %q gave the problem %q, not one with %q", line, problem, item.problem)
	}
	// The edges that the median allows: the most frames and one fewer than
	// the fewest pass, the least equal to the median passes, and the
	// smallest median that is not 0, one tenth of a microsecond, gives
	// 10 000 000 frames at most.
	testing.expect_value(t, processor_frame_line_problem(strings.concatenate({PROCESSOR_FRAME_CLEAR_AND_PRESENT, times_text("2401.7", "2401.7", "416", "21")}, context.temp_allocator)), "")
	testing.expect_value(t, processor_frame_line_problem(strings.concatenate({PROCESSOR_FRAME_CLEAR_AND_PRESENT, times_text("2310.4", "2401.7", "415", "21")}, context.temp_allocator)), "")
	testing.expect_value(t, processor_frame_line_problem(strings.concatenate({PROCESSOR_FRAME_CLEAR_AND_PRESENT, times_text("0.1", "0.1", "10000000", "1")}, context.temp_allocator)), "")
	testing.expect(t, processor_frame_line_problem(strings.concatenate({PROCESSOR_FRAME_CLEAR_AND_PRESENT, times_text("0.1", "0.1", "10000001", "1")}, context.temp_allocator)) != "")
}

// A log with a part missing, a part twice, a broken line or no last line is
// refused; the log of a whole run passes, last.
@(test)
processor_frame_lines_problems_need_each_part_once :: proc(t: ^testing.T) {
	missing := processor_frame_lines_problems(log_of_the_run(PROCESSOR_FRAME_FULL_FRAME, ""))
	testing.expect_value(t, len(missing), 1)
	if len(missing) == 1 {
		testing.expect(t, strings.contains(missing[0], "the log has 0 lines"))
	}

	twice := strings.concatenate({log_of_the_run(), "\n[processor_frame] ", PROCESSOR_FRAME_DRAW_TABLE, "339 records", times_text("1.0", "1.0", "1000000", "21")}, context.temp_allocator)
	twice_problems := processor_frame_lines_problems(twice)
	testing.expect_value(t, len(twice_problems), 1)
	if len(twice_problems) == 1 {
		testing.expect(t, strings.contains(twice_problems[0], "the log has 2 lines"))
	}

	broken := processor_frame_lines_problems(log_of_the_run(PROCESSOR_FRAME_FRAME_IN_ITS_DAMAGE, strings.concatenate({PROCESSOR_FRAME_FRAME_IN_ITS_DAMAGE, times_text("9.0", "8.0", "125000", "21")}, context.temp_allocator)))
	testing.expect_value(t, len(broken), 1)
	if len(broken) == 1 {
		testing.expect(t, strings.contains(broken[0], "is above the median"))
	}

	without_end, _ := strings.replace_all(log_of_the_run(), PROCESSOR_FRAME_DONE, "processor_frame: wrong: ", context.temp_allocator)
	end_problems := processor_frame_lines_problems(without_end)
	testing.expect_value(t, len(end_problems), 1)

	testing.expect_value(t, len(processor_frame_lines_problems("")), len(processor_frame_parts) + 1)
	testing.expect_value(t, len(processor_frame_lines_problems(log_of_the_run())), 0)
}

// Each part that the scenario of the measure run waits for is a line that
// the check reads, and each is a number of the measure record.
@(test)
processor_frame_parts_are_waited_for_and_recorded :: proc(t: ^testing.T) {
	for part in processor_frame_parts {
		waited := false
		for step in scenario_measure {
			waited ||= step.kind == .Wait && step.text == part
		}
		testing.expectf(t, waited, "the scenario of the measure run does not wait for %q", part)
		recorded := false
		for measure in site_measures {
			recorded ||= measure.pattern == part && measure.files[0] == TEST_OUTPUT_MEASURE
		}
		testing.expectf(t, recorded, "no number of the measure record reads %q", part)
	}
}
