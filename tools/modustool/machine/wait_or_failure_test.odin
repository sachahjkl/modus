package machine

import "core:testing"

// A Wait with a failure text fails when the failure text comes before the
// text, and when it is on the line where the text is, before or after it:
// the palette writes its whole list on one line. The line of the text
// counts once it ended. The successes come last: the failure text on a
// later line, no failure text, and a last line read as it is at the bound.
@(test)
a_failure_on_the_line_of_the_wait_fails_the_step :: proc(t: ^testing.T) {
	TEXT :: " for \":font\": font (setting)"
	FAILURE :: "settings.set scale to fourteen_eighths"
	Case :: struct {
		log:         string,
		whole_lines: bool,
		outcome:     Wait_Outcome,
		line:        string,
	}
	cases := [?]Case {
		// The failure text first, on a line of its own.
		{"a: settings.set scale to fourteen_eighths (setting)\nb: lists 2 for \":font\": font (setting)\n", true, .Failure_Found, "settings.set scale to fourteen_eighths (setting)"},
		// On the line of the text, after it and before it.
		{"lists 2 for \":font\": font (setting), settings.set scale to fourteen_eighths (setting)\n", true, .Failure_Found, "lists 2 for \":font\": font (setting), settings.set scale to fourteen_eighths (setting)"},
		{"x\nb: settings.set scale to fourteen_eighths, then for \":font\": font (setting)\n", true, .Failure_Found, "settings.set scale to fourteen_eighths, then for \":font\": font (setting)"},
		// On the line of the text, which has not ended: the failure is
		// there already.
		{"lists 2 for \":font\": font (setting), settings.set scale to fourteen_eighths", true, .Failure_Found, "lists 2 for \":font\": font (setting), settings.set scale to fourteen_eighths"},
		// The line of the text has not ended, with no failure yet: its
		// rest can still bring one.
		{"lists 1 for \":font\": font (setting)", true, .Waiting, ""},
		{"lists 1 for \":font\": font (setting), settings.set scale", true, .Waiting, ""},
		// Neither text.
		{"", true, .Waiting, ""},
		{"lists 0 for \":fo\"\n", true, .Waiting, ""},
		// The successes: the failure text on a later line, no failure, a
		// line with \r, and the last line at the bound.
		{"lists 1 for \":font\": font (setting)\nsettings.set scale to fourteen_eighths\n", true, .Text_Found, ""},
		{"lists 1 for \":font\": font (setting)\n", true, .Text_Found, ""},
		{"lists 1 for \":font\": font (setting)\r\n", true, .Text_Found, ""},
		{"lists 1 for \":font\": font (setting)", false, .Text_Found, ""},
	}
	for item in cases {
		outcome, line := wait_or_failure_decide(item.log, TEXT, FAILURE, item.whole_lines)
		testing.expectf(t, outcome == item.outcome && line == item.line, "%q: %v %q, not %v %q", item.log, outcome, line, item.outcome, item.line)
	}
	// No failure text: the text alone decides.
	outcome, line := wait_or_failure_decide("lists 1 for \":font\": font (setting)\n", TEXT, "", true)
	testing.expect(t, outcome == .Text_Found && line == "")
}
