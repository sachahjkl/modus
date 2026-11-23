package checks

import "core:testing"

// The mark is refused wherever it stands on a line, one number for each
// line; a text that only resembles it is taken.
@(test)
cut_line_mark_on_good_and_bad_texts :: proc(t: ^testing.T) {
	near := "a line truncated to 2000 chars\n(line truncated\n(line truncated to\n(Line truncated to 2000 chars)"
	testing.expect_value(t, len(cut_line_mark_problems(near)), 0)
	testing.expect_value(t, len(cut_line_mark_problems("")), 0)

	bad := "first\nthe end of a long line... " + CUT_LINE_MARK + "2000 chars)\nthird\n" + CUT_LINE_MARK + "1 chars) " + CUT_LINE_MARK + "2 chars)\r\n" + CUT_LINE_MARK
	problems := cut_line_mark_problems(bad)
	testing.expect_value(t, len(problems), 3)
	if len(problems) == 3 {
		testing.expect(t, problems[0] == 2 && problems[1] == 4 && problems[2] == 5)
	}
	testing.expect_value(t, len(cut_line_mark_problems(CUT_LINE_MARK)), 1)
}
