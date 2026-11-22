package machine

import "modus:contract/settings"
import "internal:settings/appearance"
import "core:testing"

// The clock of a test machine is 01:00 UTC of the day of the host, whatever
// the hour of the host, and its offset brings a date of the machine back to
// the clock of the host. At that hour the setting auto is dark.
@(test)
machine_clock_at_night :: proc(t: ^testing.T) {
	DAY :: i64(1_794_787_200) // 2026-11-16 00:00:00 UTC.
	for host in ([?]i64{DAY, DAY + 3_600, DAY + 15 * 3_600 + 30 * 60, DAY + 86_399}) {
		clock := machine_clock_of(host)
		testing.expect_value(t, clock.argument, "base=2026-11-16T01:00:00")
		testing.expect_value(t, host + clock.offset_seconds, DAY + MACHINE_CLOCK_HOUR * 3_600)
		moment := appearance.Moment{known = true, milliseconds = (host + clock.offset_seconds) * 1000}
		testing.expect_value(t, appearance.in_force_of(.Auto, moment), settings.Appearance_In_Force.Dark)
	}
}
