package checks

import "core:strings"
import "core:testing"

// A log of a measure run with each line of the quality measures in its
// form, and the line that starts with replaced_start replaced by
// replaced_line ("" leaves it out).
@(private = "file")
quality_log :: proc(replaced_start: string = "", replaced_line: string = "") -> string {
	lines := [?]string {
		"[compositor] " + QUALITY_PROFILE_LINE,
		"[compositor] " + QUALITY_WINDOW_START_LOCKS + "51234.5 us",
		"[compositor] " + QUALITY_FRAME + ": least 812.4 us, median 9031.0 us, over 64 frames",
		"[compositor] " + QUALITY_KEY + ": least 1203.7 us, median 14000.2 us, over 16 keys",
	}
	kept := make([dynamic]string, context.temp_allocator)
	for line in lines {
		if replaced_start != "" && strings.contains(line, replaced_start) {
			if replaced_line != "" {
				append(&kept, replaced_line)
			}
			continue
		}
		append(&kept, line)
	}
	return strings.join(kept[:], "\n", context.temp_allocator)
}

// Each line of the frames or of the keys whose times are not in the form
// is refused with its reason; the least equal to the median passes.
@(test)
quality_spread_problem_refuses_each_broken_form :: proc(t: ^testing.T) {
	Case :: struct {
		times:   string,
		problem: string, // A part of the reason.
	}
	cases := [?]Case {
		{": least 812 us, median 9031.0 us, over 64 frames", "the least \"812\""},
		{": least 812.45 us, median 9031.0 us, over 64 frames", "the least \"812.45\""},
		{": least -1.0 us, median 9031.0 us, over 64 frames", "the least \"-1.0\""},
		{": least 812.4 us, median .5 us, over 64 frames", "the median \".5\""},
		{": least 812.4 us, median 9031.0 us, over +64 frames", "the count \"+64\""},
		{": least 812.4 us, median 9031.0 us, over 0 frames", "the line measures 0 frames"},
		{": least 9031.1 us, median 9031.0 us, over 64 frames", "is above the median"},
		{": least 812.4 us, median 9031.0 us, over 64 keys", "its times are not in the words"},
		{": least 812.4 us, mean 9031.0 us, over 64 frames", "it has no \" us, median \""},
		{": least 812.4 us, median 9031.0 us, over frames", "it has no count"},
		{" with no times", "it has no \": least \""},
	}
	for item in cases {
		line := strings.concatenate({QUALITY_FRAME, item.times}, context.temp_allocator)
		problem := quality_spread_problem(line, "frames")
		testing.expectf(t, strings.contains(problem, item.problem), "the line %q gave the problem %q, not one with %q", line, problem, item.problem)
	}
	testing.expect_value(t, quality_spread_problem(strings.concatenate({QUALITY_KEY, ": least 0.1 us, median 0.1 us, over 1 keys"}, context.temp_allocator), "keys"), "")
}

// A line of the start of a window with no name, a name with a space, or a
// time not in its form is refused; the line of locks passes.
@(test)
quality_start_problem_refuses_each_broken_form :: proc(t: ^testing.T) {
	refused := [?]string {
		QUALITY_WINDOW_START + QUALITY_WINDOW_START_TAIL + "12.3 us",
		QUALITY_WINDOW_START + "two words" + QUALITY_WINDOW_START_TAIL + "12.3 us",
		QUALITY_WINDOW_START_LOCKS + "12 us",
		QUALITY_WINDOW_START_LOCKS + "12.3",
		QUALITY_WINDOW_START_LOCKS + "12.3 ms",
		QUALITY_WINDOW_START + "locks: 12.3 us",
	}
	for line in refused {
		testing.expectf(t, quality_start_problem(line) != "", "the line %q is taken", line)
	}
	testing.expect_value(t, quality_start_problem(QUALITY_WINDOW_START_LOCKS + "0.0 us"), "")
}

// A log with no line of a kind, two lines of the profile, or a line out of
// its form is refused; the log of a whole run passes, last.
@(test)
quality_lines_problems_need_each_line :: proc(t: ^testing.T) {
	for start in ([]string{QUALITY_PROFILE_LINE, QUALITY_WINDOW_START_LOCKS, QUALITY_FRAME, QUALITY_KEY}) {
		problems := quality_lines_problems(quality_log(start, ""))
		testing.expectf(t, len(problems) == 1, "the log with no line %q gave %d problems", start, len(problems))
	}
	twice := strings.concatenate({quality_log(), "\n[compositor] ", QUALITY_PROFILE_LINE}, context.temp_allocator)
	testing.expect_value(t, len(quality_lines_problems(twice)), 1)
	broken := quality_lines_problems(quality_log(QUALITY_KEY, QUALITY_KEY + ": least 2.0 us, median 1.0 us, over 16 keys"))
	testing.expect_value(t, len(broken), 1)
	// The start of another window counts for no line of locks.
	other := quality_lines_problems(quality_log(QUALITY_WINDOW_START_LOCKS, QUALITY_WINDOW_START + "clock" + QUALITY_WINDOW_START_TAIL + "10.0 us"))
	testing.expect_value(t, len(other), 1)
	testing.expect_value(t, len(quality_lines_problems("")), 4)
	testing.expect_value(t, len(quality_lines_problems(quality_log())), 0)
}
