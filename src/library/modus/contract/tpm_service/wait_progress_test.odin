#+build !freestanding
package tpm_service

import "core:testing"

// A wait reports nothing before its first interval: at its start, one
// millisecond before the interval, and at a time before its start, which
// the clock never gives. Nothing changes on a refusal.
@(test)
a_wait_reports_nothing_before_its_first_interval :: proc(t: ^testing.T) {
	START :: 1_000
	progress := wait_progress_start(START)
	for now in ([?]u64{0, START - 1, START, START + WAIT_PROGRESS_INTERVAL_MILLISECONDS - 1}) {
		due, passed := wait_progress_due(&progress, now)
		testing.expectf(t, !due && passed == 0, "a report at %d", now)
		testing.expect_value(t, progress.reports, 0)
	}
	testing.expect_value(t, wait_progress_next(progress), START + WAIT_PROGRESS_INTERVAL_MILLISECONDS)
}

// A check that comes late writes one report, and names the first interval:
// the reports come one after another, so "60 s" always comes, and after
// "30 s". The same time checked again writes the next report only once
// its own time passed.
@(test)
a_late_check_writes_the_reports_one_after_another :: proc(t: ^testing.T) {
	progress := wait_progress_start(0)
	late :: 5 * WAIT_PROGRESS_INTERVAL_MILLISECONDS + 7
	expected := [?]u64{30, 60, 90, 120, 150}
	for seconds in expected {
		due, passed := wait_progress_due(&progress, late)
		testing.expect(t, due)
		testing.expect_value(t, passed, seconds)
	}
	// Five intervals passed: a sixth report waits for the sixth interval.
	due, passed := wait_progress_due(&progress, late)
	testing.expect(t, !due && passed == 0)
	testing.expect_value(t, progress.reports, 5)
	testing.expect_value(t, wait_progress_next(progress), 6 * WAIT_PROGRESS_INTERVAL_MILLISECONDS)
}

// A start near the largest value of the clock: the time of the next report
// does not wrap, it stays at the largest value, and no report comes, so a
// sleep until it never ends at once and the count does not move. A count of
// reports past the largest product gives the largest value too.
@(test)
the_time_of_the_next_report_never_wraps :: proc(t: ^testing.T) {
	progress := wait_progress_start(max(u64) - 10)
	testing.expect_value(t, wait_progress_next(progress), max(u64))
	due, _ := wait_progress_due(&progress, max(u64))
	testing.expect(t, !due)
	testing.expect_value(t, progress.reports, 0)
	counted := Wait_Progress{started = 0, reports = max(u64) / WAIT_PROGRESS_INTERVAL_MILLISECONDS}
	testing.expect_value(t, wait_progress_next(counted), max(u64))
	counted.reports = max(u64)
	testing.expect_value(t, wait_progress_next(counted), max(u64))
}

// The success case: a wait checked each millisecond writes its first
// report at 30 s exactly and its second at 60 s exactly, and nothing
// between them.
@(test)
a_wait_checked_often_reports_at_each_interval :: proc(t: ^testing.T) {
	START :: 500
	progress := wait_progress_start(START)
	reports: [dynamic]u64
	defer delete(reports)
	times: [dynamic]u64
	defer delete(times)
	for now := u64(START); now <= START + 2 * WAIT_PROGRESS_INTERVAL_MILLISECONDS; now += 1 {
		if due, passed := wait_progress_due(&progress, now); due {
			append(&reports, passed)
			append(&times, now)
		}
	}
	testing.expect_value(t, len(reports), 2)
	if len(reports) == 2 {
		testing.expect_value(t, reports[0], 30)
		testing.expect_value(t, reports[1], 60)
		testing.expect_value(t, times[0], START + WAIT_PROGRESS_INTERVAL_MILLISECONDS)
		testing.expect_value(t, times[1], START + 2 * WAIT_PROGRESS_INTERVAL_MILLISECONDS)
	}
}

// Each request has its words, and none is empty: a report names it.
@(test)
each_request_has_its_words :: proc(t: ^testing.T) {
	for command in Command {
		testing.expectf(t, command_words[command] != "", "%v has no words", command)
	}
}
