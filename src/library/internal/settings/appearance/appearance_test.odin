#+build !freestanding
package appearance

import "modus:contract/date"
import "modus:contract/settings"
import "core:testing"

// 2026-11-16 00:00:00 UTC, in milliseconds since 1970.
DAY_START :: i64(1_794_787_200) * 1000

@(private = "file")
at :: proc(hours, minutes, seconds: i64, milliseconds: i64 = 0, zone: i64 = 0) -> Moment {
	return {known = true, milliseconds = DAY_START + ((hours * 60 + minutes) * 60 + seconds) * 1000 + milliseconds, zone_offset_seconds = zone}
}

// The rule at each edge: 07:00:00 is light and the millisecond before it is
// dark; 19:00:00 is dark and the millisecond before it is light.
@(test)
the_rule_at_its_edges :: proc(t: ^testing.T) {
	testing.expect_value(t, in_force_of(.Auto, at(6, 59, 59, 999)), settings.Appearance_In_Force.Dark)
	testing.expect_value(t, in_force_of(.Auto, at(7, 0, 0)), settings.Appearance_In_Force.Light)
	testing.expect_value(t, in_force_of(.Auto, at(12, 0, 0)), settings.Appearance_In_Force.Light)
	testing.expect_value(t, in_force_of(.Auto, at(18, 59, 59, 999)), settings.Appearance_In_Force.Light)
	testing.expect_value(t, in_force_of(.Auto, at(19, 0, 0)), settings.Appearance_In_Force.Dark)
	testing.expect_value(t, in_force_of(.Auto, at(0, 0, 0)), settings.Appearance_In_Force.Dark)
	testing.expect_value(t, in_force_of(.Auto, at(23, 59, 59, 999)), settings.Appearance_In_Force.Dark)
}

// A setting that is not auto is itself at each hour, and a system with no
// date is dark.
@(test)
the_settings_that_are_not_auto :: proc(t: ^testing.T) {
	for moment in ([?]Moment{at(3, 0, 0), at(12, 0, 0), {}}) {
		testing.expect_value(t, in_force_of(.Dark, moment), settings.Appearance_In_Force.Dark)
		testing.expect_value(t, in_force_of(.Light, moment), settings.Appearance_In_Force.Light)
	}
	testing.expect_value(t, in_force_of(.Auto, {}), settings.Appearance_In_Force.Dark)
}

// The zone moves the edges: 07:00 of a zone of +2 hours is 05:00 of UTC,
// and 06:59 of a zone of -1 hour is 07:59 of UTC.
@(test)
the_zone_moves_the_edges :: proc(t: ^testing.T) {
	testing.expect_value(t, in_force_of(.Auto, at(5, 0, 0, 0, 7_200)), settings.Appearance_In_Force.Light)
	testing.expect_value(t, in_force_of(.Auto, at(4, 59, 59, 999, 7_200)), settings.Appearance_In_Force.Dark)
	testing.expect_value(t, in_force_of(.Auto, at(7, 59, 0, 0, -3_600)), settings.Appearance_In_Force.Dark)
	testing.expect_value(t, in_force_of(.Auto, at(8, 0, 0, 0, -3_600)), settings.Appearance_In_Force.Light)
	// A zone that crosses midnight: 01:00 of UTC is 20:00 of the day before
	// at -5 hours.
	testing.expect_value(t, local_second_of_day(at(1, 0, 0, 0, -18_000)), i64(20 * 3_600))
}

// The next edge is always later than the moment, and is the next 07:00 or
// 19:00: at an edge itself, the other edge.
@(test)
the_next_edge :: proc(t: ^testing.T) {
	testing.expect_value(t, next_edge(at(1, 4, 0)), at(7, 0, 0).milliseconds)
	testing.expect_value(t, next_edge(at(6, 59, 59, 999)), at(7, 0, 0).milliseconds)
	testing.expect_value(t, next_edge(at(7, 0, 0)), at(19, 0, 0).milliseconds)
	testing.expect_value(t, next_edge(at(7, 0, 0, 1)), at(19, 0, 0).milliseconds)
	testing.expect_value(t, next_edge(at(19, 0, 0)), at(31, 0, 0).milliseconds) // 07:00 of the next day.
	testing.expect_value(t, next_edge(at(23, 30, 0)), at(31, 0, 0).milliseconds)
	for hour in i64(0) ..< 24 {
		moment := at(hour, 17, 3, 250)
		edge := next_edge(moment)
		testing.expectf(t, edge > moment.milliseconds && edge - moment.milliseconds <= 12 * 3_600 * 1000, "the next edge after %d:17:03.250", hour)
		// The rule changes at the edge, and not in the second before it.
		before := moment
		before.milliseconds = edge - 1
		after := moment
		after.milliseconds = edge
		testing.expect(t, in_force_of(.Auto, before) != in_force_of(.Auto, after))
		testing.expect_value(t, in_force_of(.Auto, before), in_force_of(.Auto, moment))
	}
}

// The moment of a date page: the date of the page and the time of the
// system; no page, or a page with no date, gives a moment that is not
// known, and a zone past the limit is cut.
@(test)
the_moment_of_a_date_page :: proc(t: ^testing.T) {
	testing.expect_value(t, moment_of(nil, 5000), Moment{})
	page: date.Page
	testing.expect_value(t, moment_of(&page, 5000), Moment{})
	date.write(&page, .Real_Time_Clock, DAY_START)
	testing.expect_value(t, moment_of(&page, 5000), Moment{known = true, milliseconds = DAY_START + 5000})
	page.zone_offset_seconds = 1 << 40
	testing.expect_value(t, moment_of(&page, 0).zone_offset_seconds, date.ZONE_OFFSET_SECONDS_LIMIT)
	page.zone_offset_seconds = -(1 << 40)
	testing.expect_value(t, moment_of(&page, 0).zone_offset_seconds, -date.ZONE_OFFSET_SECONDS_LIMIT)
}

// The zone that the process `date` writes is the zone of the moment, and
// it moves the rule: 01:04 of UTC is 09:04 at +08:00, in the day, where
// UTC is in the night. This is the case of the machine test.
@(test)
the_zone_of_a_date_page :: proc(t: ^testing.T) {
	page: date.Page
	date.write(&page, .Real_Time_Clock, DAY_START)
	night := moment_of(&page, u64((1 * 60 + 4) * 60 * 1000))
	testing.expect_value(t, in_force_of(.Auto, night), settings.Appearance_In_Force.Dark)
	EIGHT_HOURS :: i64(8 * 3_600)
	date.zone_write(&page, EIGHT_HOURS)
	testing.expect_value(t, page.change_count, u32(4))
	day := moment_of(&page, u64((1 * 60 + 4) * 60 * 1000))
	testing.expect_value(t, day.zone_offset_seconds, EIGHT_HOURS)
	testing.expect_value(t, local_second_of_day(day), (9 * 60 + 4) * i64(60))
	testing.expect_value(t, in_force_of(.Auto, day), settings.Appearance_In_Force.Light)
	// The next edge is 19:00 of the local time: 11:00 of UTC.
	testing.expect_value(t, next_edge(day), at(11, 0, 0).milliseconds)
}

// The sentence of the log: what the modus tool reads.
@(test)
the_sentence_of_the_log :: proc(t: ^testing.T) {
	buffer: [256]u8
	testing.expect_value(t, sentence_write(buffer[:], .Light, at(1, 4, 0)), "the appearance in force is light: the setting light")
	testing.expect_value(t, sentence_write(buffer[:], .Dark, {}), "the appearance in force is dark: the setting dark")
	testing.expect_value(t, sentence_write(buffer[:], .Auto, {}), "the appearance in force is dark: auto, and the system has no date")
	testing.expect_value(t, sentence_write(buffer[:], .Auto, at(1, 4, 0, 500)), "the appearance in force is dark: auto, light from 07:00 to 19:00 of the local time; the local time is 01:04 with a zone of 0 s, at 1794791040 s since 1970")
	testing.expect_value(t, sentence_write(buffer[:], .Auto, at(7, 0, 0, 0, -3_600)), "the appearance in force is dark: auto, light from 07:00 to 19:00 of the local time; the local time is 06:00 with a zone of -3600 s, at 1794812400 s since 1970")
	// A buffer too short cuts the sentence, does not fault, and ends with
	// the cut mark of the writer of the system: never a silent cut.
	short: [8]u8
	cut := sentence_write(short[:], .Auto, at(12, 0, 0))
	testing.expect(t, len(cut) <= len(short))
	testing.expect_value(t, cut, "... and ")
}
