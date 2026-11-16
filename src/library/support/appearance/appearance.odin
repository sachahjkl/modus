// The rule of the day of the setting `auto` (src/md/features/appearance.md):
// the light appearance from 07:00 to 19:00 of the local time, the dark one
// from 19:00 to 07:00, and the dark one when the system has no date. The
// program `settings` gives the appearance in force with it at each change of
// a setting, the root service at each edge of the day, and the modus tool
// checks the line of the log with the same procedure.
//
// The package has no state and no kernel call, so a host test runs the rule
// at each edge.
package appearance

import "base:intrinsics"
import "modus:contract/date"
import "modus:contract/settings"

SECONDS_OF_A_DAY :: 86_400
LIGHT_FROM_SECOND :: 7 * 3_600 // 07:00 of the local time: the light appearance starts.
DARK_FROM_SECOND :: 19 * 3_600 // 19:00 of the local time: the dark appearance starts.
#assert(0 < LIGHT_FROM_SECOND && LIGHT_FROM_SECOND < DARK_FROM_SECOND && DARK_FROM_SECOND < SECONDS_OF_A_DAY)

// A moment as the date page gives it.
Moment :: struct {
	known:               bool, // The system has a date. If not, the other fields mean nothing.
	milliseconds:        i64, // Milliseconds since 1970-01-01 00:00:00 UTC.
	zone_offset_seconds: i64, // The time zone of the principal: the local time is the time of UTC and this.
}

// moment_of gives the moment of a date page at the time
// `system_milliseconds` of the system (system.time()): the date of now and
// the time zone of the page. A page that gives no date (none, or one that
// changes at each read) gives a moment that is not known.
moment_of :: proc "contextless" (page: ^date.Page, system_milliseconds: u64) -> Moment {
	milliseconds, known := date.milliseconds_now(page, system_milliseconds)
	if !known {
		return {}
	}
	// The zone is one word that no program writes yet: the date is in UTC
	// until the time zone is a setting.
	zone := intrinsics.atomic_load_explicit(&page.zone_offset_seconds, .Relaxed)
	return {known = true, milliseconds = milliseconds, zone_offset_seconds = clamp(zone, -ZONE_OFFSET_LIMIT, ZONE_OFFSET_LIMIT)}
}

// The largest time zone of the earth is 14 hours from UTC: a page with more
// is cut to it, so that a sum with a date never wraps.
ZONE_OFFSET_LIMIT :: i64(14 * 3_600)

// floor_modulo gives the rest of a division that rounds toward minus
// infinity: from 0 to divisor - 1 for a negative number too. The divisor is
// a constant of this package, never 0.
@(private)
floor_modulo :: proc "contextless" (number, divisor: i64) -> i64 {
	rest := number % divisor
	return rest < 0 ? rest + divisor : rest
}

// local_second_of_day gives the second of the local day of a moment that
// has a date, from 0 to SECONDS_OF_A_DAY - 1.
local_second_of_day :: proc "contextless" (moment: Moment) -> i64 {
	seconds := (moment.milliseconds - floor_modulo(moment.milliseconds, 1000)) / 1000
	return floor_modulo(seconds + moment.zone_offset_seconds, SECONDS_OF_A_DAY)
}

// in_force_of gives the appearance in force for a setting at a moment. The
// setting Dark or Light is itself; Auto is light from LIGHT_FROM_SECOND, its
// first second included, to DARK_FROM_SECOND, its first second excluded.
in_force_of :: proc "contextless" (setting: settings.Appearance, moment: Moment) -> settings.Appearance_In_Force {
	switch setting {
	case .Dark:
		return .Dark
	case .Light:
		return .Light
	case .Auto:
	}
	if !moment.known {
		return .Dark
	}
	second := local_second_of_day(moment)
	return second >= LIGHT_FROM_SECOND && second < DARK_FROM_SECOND ? .Light : .Dark
}

// next_edge gives the date, in milliseconds since 1970, of the next edge of
// the rule after a moment that has a date: the next 07:00:00 or 19:00:00 of
// the local time, always later than the moment. At an edge itself, the next
// one is 12 hours later.
next_edge :: proc "contextless" (moment: Moment) -> i64 {
	second := local_second_of_day(moment)
	wait: i64
	switch {
	case second < LIGHT_FROM_SECOND:
		wait = LIGHT_FROM_SECOND - second
	case second < DARK_FROM_SECOND:
		wait = DARK_FROM_SECOND - second
	case:
		wait = SECONDS_OF_A_DAY - second + LIGHT_FROM_SECOND
	}
	return moment.milliseconds - floor_modulo(moment.milliseconds, 1000) + wait * 1000
}

// The words of the sentence that the modus tool reads (sentence_write).
SENTENCE_START :: "the appearance in force is "
SENTENCE_ZONE :: " with a zone of "
SENTENCE_DATE :: " s, at "

// Writer: the bytes of a sentence in a buffer of the caller. A text that
// does not fit is cut at the end of the buffer.
@(private)
Writer :: struct {
	buffer: []u8,
	count:  int,
}

@(private)
part :: proc "contextless" (writer: ^Writer, text: string) {
	writer.count += copy(writer.buffer[writer.count:], text)
}

@(private)
decimal :: proc "contextless" (writer: ^Writer, number: i64, least_digits: int = 1) {
	digits: [24]u8
	count := 0
	value := number
	if value < 0 {
		part(writer, "-")
		value = -value
	}
	for value > 0 || count < least_digits {
		digits[len(digits) - 1 - count] = u8('0' + value % 10)
		value /= 10
		count += 1
	}
	part(writer, string(digits[len(digits) - count:]))
}

// sentence_write writes in buffer why a setting gives its appearance in
// force at a moment, for the log:
//
// - "the appearance in force is light: the setting light";
// - "the appearance in force is dark: auto, and the system has no date";
// - "the appearance in force is dark: auto, light from 07:00 to 19:00 of
//   the local time; the local time is 01:04 with a zone of 0 s, at
//   1794445440 s since 1970".
//
// The date is in seconds of UTC; the modus tool checks it against the
// clock that it gave the machine, then calls in_force_of over it.
sentence_write :: proc "contextless" (buffer: []u8, setting: settings.Appearance, moment: Moment) -> string {
	writer := Writer{buffer = buffer}
	in_force := in_force_of(setting, moment)
	part(&writer, SENTENCE_START)
	part(&writer, settings.appearance_in_force_names[in_force])
	if setting != .Auto {
		part(&writer, ": the setting ")
		part(&writer, settings.descriptions[.Appearance].value_names[u32(setting)])
		return string(buffer[:writer.count])
	}
	if !moment.known {
		part(&writer, ": auto, and the system has no date")
		return string(buffer[:writer.count])
	}
	part(&writer, ": auto, light from ")
	decimal(&writer, LIGHT_FROM_SECOND / 3_600, 2)
	part(&writer, ":00 to ")
	decimal(&writer, DARK_FROM_SECOND / 3_600, 2)
	part(&writer, ":00 of the local time; the local time is ")
	second := local_second_of_day(moment)
	decimal(&writer, second / 3_600, 2)
	part(&writer, ":")
	decimal(&writer, second / 60 % 60, 2)
	part(&writer, SENTENCE_ZONE)
	decimal(&writer, moment.zone_offset_seconds)
	part(&writer, SENTENCE_DATE)
	decimal(&writer, (moment.milliseconds - floor_modulo(moment.milliseconds, 1000)) / 1000)
	part(&writer, " s since 1970")
	return string(buffer[:writer.count])
}
