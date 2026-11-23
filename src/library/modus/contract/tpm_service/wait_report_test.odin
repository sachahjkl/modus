#+build !freestanding
package tpm_service

import "core:testing"

@(private = "file")
INTERVAL :: WAIT_REPORT_INTERVAL_MILLISECONDS
// The largest count of reports whose next time the clock can hold.
@(private = "file")
LARGEST_COUNT :: max(u64) / INTERVAL

// A wait reports nothing before its first interval: at its start, one
// millisecond before the interval, and at a time before its start, which
// the clock never gives. Nothing changes on a refusal.
@(test)
a_wait_reports_nothing_before_its_first_interval :: proc(t: ^testing.T) {
	START :: 1_000
	reports := wait_reports_start(START)
	for now in ([?]u64{0, START - 1, START, START + INTERVAL - 1}) {
		due, passed := wait_report_due(&reports, now)
		testing.expectf(t, !due && passed == 0, "a report at %d", now)
		testing.expect_value(t, reports.written, 0)
	}
	testing.expect_value(t, wait_report_next(reports), START + INTERVAL)
}

// A check that comes late writes one report, and names the first interval:
// the reports come one after another, so "60 s" always comes, and after
// "30 s". The same time checked again writes the next report only once
// its own time passed.
@(test)
a_late_check_writes_the_reports_one_after_another :: proc(t: ^testing.T) {
	reports := wait_reports_start(0)
	late :: 5 * INTERVAL + 7
	expected := [?]u64{30, 60, 90, 120, 150}
	for seconds in expected {
		due, passed := wait_report_due(&reports, late)
		testing.expect(t, due)
		testing.expect_value(t, passed, seconds)
	}
	due, passed := wait_report_due(&reports, late)
	testing.expect(t, !due && passed == 0)
	testing.expect_value(t, reports.written, 5)
	testing.expect_value(t, wait_report_next(reports), 6 * INTERVAL)
}

// The count of reports at its edges. One below the largest count gives a
// real time; the largest count and past it give the largest value of the
// clock, "never", whatever the start.
@(test)
the_count_of_reports_at_its_edges :: proc(t: ^testing.T) {
	below := Wait_Reports{started = 0, written = LARGEST_COUNT - 1}
	testing.expect_value(t, wait_report_next(below), LARGEST_COUNT * INTERVAL)
	testing.expect(t, LARGEST_COUNT * INTERVAL < max(u64))
	for written in ([?]u64{LARGEST_COUNT, LARGEST_COUNT + 1, max(u64)}) {
		testing.expect_value(t, wait_report_next(Wait_Reports{started = 0, written = written}), max(u64))
	}
}

// At the largest count, a check at the largest time of the clock writes no
// report, and the count does not move: the next report would wrap.
@(test)
no_report_at_the_largest_count :: proc(t: ^testing.T) {
	reports := Wait_Reports{started = 0, written = LARGEST_COUNT}
	for now in ([?]u64{0, LARGEST_COUNT * INTERVAL, max(u64)}) {
		due, passed := wait_report_due(&reports, now)
		testing.expectf(t, !due && passed == 0, "a report at %d", now)
		testing.expect_value(t, reports.written, LARGEST_COUNT)
	}
}

// A start near the largest value of the clock. The largest value is the
// sentinel "never": a start whose first report falls exactly on it gets
// no report, as a start past it, and a start one millisecond before gets
// its report at max(u64) - 1, a real time.
@(test)
the_time_of_the_next_report_never_wraps :: proc(t: ^testing.T) {
	OFFSET :: INTERVAL
	exact := wait_reports_start(max(u64) - OFFSET)
	testing.expect_value(t, wait_report_next(exact), max(u64))
	due, passed := wait_report_due(&exact, max(u64))
	testing.expect(t, !due && passed == 0)
	testing.expect_value(t, exact.written, 0)

	for started in ([?]u64{max(u64) - OFFSET + 1, max(u64) - 10, max(u64)}) {
		past := wait_reports_start(started)
		testing.expect_value(t, wait_report_next(past), max(u64))
		due, _ = wait_report_due(&past, max(u64))
		testing.expect(t, !due)
		testing.expect_value(t, past.written, 0)
	}

	real := wait_reports_start(max(u64) - OFFSET - 1)
	testing.expect_value(t, wait_report_next(real), max(u64) - 1)
	due, passed = wait_report_due(&real, max(u64) - 1)
	testing.expect(t, due)
	testing.expect_value(t, passed, 30)
	testing.expect_value(t, real.written, 1)
	// Its second report would pass the clock: never.
	testing.expect_value(t, wait_report_next(real), max(u64))
}

// The success case: a wait checked each millisecond writes its first
// report at 30 s exactly and its second at 60 s exactly, and nothing
// between them.
@(test)
a_wait_checked_often_reports_at_each_interval :: proc(t: ^testing.T) {
	START :: 500
	reports := wait_reports_start(START)
	passed_list: [dynamic]u64
	defer delete(passed_list)
	times: [dynamic]u64
	defer delete(times)
	for now := u64(START); now <= START + 2 * INTERVAL; now += 1 {
		if due, passed := wait_report_due(&reports, now); due {
			append(&passed_list, passed)
			append(&times, now)
		}
	}
	testing.expect_value(t, len(passed_list), 2)
	if len(passed_list) == 2 {
		testing.expect_value(t, passed_list[0], 30)
		testing.expect_value(t, passed_list[1], 60)
		testing.expect_value(t, times[0], START + INTERVAL)
		testing.expect_value(t, times[1], START + 2 * INTERVAL)
	}
}

// Before both bounds, no bound is reached. The earlier bound ends the wait.
// When both are reached, the earlier one is named, not the one checked
// first. A deadline that passed before the wait started ends it at once,
// and is named. On a tie the step is named.
@(test)
the_bound_that_ended_a_wait :: proc(t: ^testing.T) {
	Case :: struct {
		now, step_limit, work_deadline: u64,
		reached:                        bool,
		bound:                          Wait_Bound,
	}
	cases := [?]Case {
		{now = 0, step_limit = 100, work_deadline = 200, reached = false, bound = .Step},
		{now = 99, step_limit = 100, work_deadline = 200, reached = false, bound = .Step},
		{now = 100, step_limit = 100, work_deadline = 200, reached = true, bound = .Step},
		{now = 199, step_limit = 200, work_deadline = 100, reached = true, bound = .Deadline_Of_Work},
		// Both reached: the earlier one, either way round.
		{now = 500, step_limit = 100, work_deadline = 200, reached = true, bound = .Step},
		{now = 500, step_limit = 200, work_deadline = 100, reached = true, bound = .Deadline_Of_Work},
		// A deadline already past at the start of the wait (now 50).
		{now = 50, step_limit = 50 + 120_000, work_deadline = 10, reached = true, bound = .Deadline_Of_Work},
		{now = 50, step_limit = 50 + 120_000, work_deadline = 0, reached = true, bound = .Deadline_Of_Work},
		// A tie.
		{now = 100, step_limit = 100, work_deadline = 100, reached = true, bound = .Step},
		// The largest values of the clock.
		{now = max(u64) - 1, step_limit = max(u64), work_deadline = max(u64), reached = false, bound = .Step},
		{now = max(u64), step_limit = max(u64), work_deadline = max(u64) - 1, reached = true, bound = .Deadline_Of_Work},
	}
	for item in cases {
		reached, bound := wait_bound_reached(item.now, item.step_limit, item.work_deadline)
		testing.expectf(t, reached == item.reached && (!reached || bound == item.bound), "%v gives %v %v", item, reached, bound)
	}
}

// Each request and each bound has its words, and none is empty: a report
// names it.
@(test)
each_request_and_each_bound_has_its_words :: proc(t: ^testing.T) {
	for command in Command {
		testing.expectf(t, command_words[command] != "", "%v has no words", command)
	}
	for bound in Wait_Bound {
		testing.expectf(t, wait_bound_words[bound] != "", "%v has no words", bound)
	}
}
