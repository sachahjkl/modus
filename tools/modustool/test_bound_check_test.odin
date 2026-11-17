package modustool

import "core:testing"

// The call is split in the texts below, so that the check of this folder
// does not read them as calls of the tool.
@(private = "file")
SLEEP :: "time." + "sleep("

// The reader of a line finds the period of each call of time.sleep, and
// only of a call: a comment, another name and a line with no call give none.
@(test)
the_period_of_a_sleep_is_read_from_its_line :: proc(t: ^testing.T) {
	period, has_sleep := sleep_period_of_a_line("\t\t" + SLEEP + "CONDITION_POLL_PERIOD)")
	testing.expect(t, has_sleep)
	testing.expect_value(t, period, "CONDITION_POLL_PERIOD)")
	// A number: the check refuses it by its first byte.
	period, has_sleep = sleep_period_of_a_line(SLEEP + "20 * time.Millisecond)")
	testing.expect(t, has_sleep)
	testing.expect_value(t, period, "20 * time.Millisecond)")
	period, has_sleep = sleep_period_of_a_line(SLEEP + "  5)")
	testing.expect(t, has_sleep)
	testing.expect_value(t, period, "5)")
	// A call with nothing after it: an empty period, which the check refuses.
	period, has_sleep = sleep_period_of_a_line(SLEEP)
	testing.expect(t, has_sleep)
	testing.expect_value(t, period, "")
	// In a comment, in a longer name, or absent: no call.
	_, has_sleep = sleep_period_of_a_line("// " + SLEEP + "20 * time.Millisecond)")
	testing.expect(t, !has_sleep)
	_, has_sleep = sleep_period_of_a_line("my" + SLEEP + "20)")
	testing.expect(t, !has_sleep)
	_, has_sleep = sleep_period_of_a_line("")
	testing.expect(t, !has_sleep)
	_, has_sleep = sleep_period_of_a_line("time.tick_now()")
	testing.expect(t, !has_sleep)
	// The call before a comment is read; the comment is not.
	period, has_sleep = sleep_period_of_a_line(SLEEP + "LOG_POLL_PERIOD) // 20 ms")
	testing.expect(t, has_sleep)
	testing.expect_value(t, period, "LOG_POLL_PERIOD)")
}
