package modustool

import "modus:contract/settings"
import "modus:support/appearance"
import "modus:support/calendar"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"

// The real-time clock of a test machine (src/md/features/appearance.md,
// "Subtle points"). The setting `appearance` is `auto` on a new disk, and
// `auto` follows the hour: with the clock of the host, the pictures of a test
// would be light or dark by the hour of the run. So the tool gives each test
// machine a clock at MACHINE_CLOCK_HOUR UTC of the day of the host: the night,
// and six hours of it before 07:00. It keeps the difference to the clock of
// the host, and each check of a date of the machine takes it off first.
MACHINE_CLOCK_HOUR :: 1

// The clock that the tool gives a machine: the argument of `-rtc` of QEMU,
// and the seconds that the clock of the machine is ahead of the clock of the
// host (negative: behind).
Machine_Clock :: struct {
	argument:       string,
	offset_seconds: i64,
}

// machine_clock_of gives the clock of a test machine that starts at the
// time host_unix of the host, in seconds since 1970. QEMU reads the clock of
// the host again when it starts, a moment later: DATE_TOLERANCE_SECONDS
// covers that moment.
machine_clock_of :: proc(host_unix: i64) -> Machine_Clock {
	day_start := host_unix - host_unix %% 86_400
	base := day_start + MACHINE_CLOCK_HOUR * 3_600
	at := time.unix(base, 0)
	year, month, day := time.date(at)
	hour, minute, second := time.clock(at)
	argument := fmt.tprintf("base=%04d-%02d-%02dT%02d:%02d:%02d", year, int(month), day, hour, minute, second)
	return {argument = argument, offset_seconds = base - host_unix}
}

// step_line_wait waits, as a step Wait, for the text of a step, and gives
// the whole line of the log that starts with it, after the last Wait.
step_line_wait :: proc(machine: ^Machine, index: int, step: Step) -> (line: string, ok: bool) {
	seen_before := machine.seen
	if !log_wait(machine, step.text, step.any_order) {
		fmt.eprintfln("modustool: test failed: step %d: the machine did not print \"%s\"", index + 1, step.text)
		return "", false
	}
	log := log_read(machine)
	rest := log[seen_before:]
	at := strings.index(rest, step.text)
	if at < 0 {
		fmt.eprintfln("modustool: test failed: step %d: the line \"%s\" is not after the last Wait", index + 1, step.text)
		return "", false
	}
	line = rest[at:]
	if end := strings.index_byte(line, '\n'); end >= 0 {
		line = line[:end]
	}
	return line, true
}

// The words of the line of the bar of the compositor
// (src/modules/system/compositor/main.odin, screen_build): "compositor: the bar
// shows the local time 2026-11-16 09:04:05 with the time zone +08:00, at
// 1794791045 s since 1970".
BAR_LINE_ZONE :: " with the time zone "
BAR_LINE_DATE :: ", at "

// bar_local_time_check runs a step Bar_Local_Time. The line says the local
// time that the bar draws, its zone, and the date of UTC that the
// compositor read: date_check checks that date against the clock that the
// tool gave the machine, the zone must be the one that the test set, and
// the local time must be that date in that zone.
bar_local_time_check :: proc(machine: ^Machine, index: int, step: Step) -> bool {
	line := step_line_wait(machine, index, step) or_return
	rest := line[len(step.text):]
	zone_at := strings.index(rest, BAR_LINE_ZONE)
	if zone_at < 0 || len(rest) < zone_at + len(BAR_LINE_ZONE) + settings.ZONE_TEXT_SIZE {
		fmt.eprintfln("modustool: test failed: step %d: the line \"%s\" has no time zone", index + 1, line)
		return false
	}
	shown := rest[:zone_at]
	zone_text := rest[zone_at + len(BAR_LINE_ZONE):][:settings.ZONE_TEXT_SIZE]
	zone_minutes, zone_ok := settings.zone_parse(zone_text)
	seconds, date_found := number_after(rest, BAR_LINE_DATE)
	if !zone_ok || !date_found {
		fmt.eprintfln("modustool: test failed: step %d: the line \"%s\" has no valid zone or no date", index + 1, line)
		return false
	}
	if zone_text != step.expected {
		fmt.eprintfln("modustool: test failed: step %d: the bar shows the time zone %s, not %s", index + 1, zone_text, step.expected)
		return false
	}
	date_check(index, seconds, step.text, machine.started_unix, machine.clock_offset_seconds) or_return
	buffer: [24]u8
	wanted := calendar.iso_text(buffer[:], seconds + i64(zone_minutes) * 60)
	if shown != wanted {
		fmt.eprintfln("modustool: test failed: step %d: the bar shows \"%s\", and %d s since 1970 in the zone %s is \"%s\"", index + 1, shown, seconds, zone_text, wanted)
		return false
	}
	test_passed_print("the bar shows the local time %s, %d s since 1970 in the zone %s", shown, seconds, zone_text)
	return true
}

// appearance_auto_check runs a step Appearance_Auto. The test cannot choose
// the hour of the machine, and needs not: the line says the date that the
// rule read, date_check checks that date against the clock that the tool
// gave the machine, and the tool computes the same rule over it
// (appearance.in_force_of). The line must name the appearance of the rule.
appearance_auto_check :: proc(machine: ^Machine, index: int, step: Step) -> bool {
	line := step_line_wait(machine, index, step) or_return
	seconds, date_found := number_after(line, appearance.SENTENCE_DATE)
	zone, zone_found := number_after(line, appearance.SENTENCE_ZONE)
	if !date_found || !zone_found {
		fmt.eprintfln("modustool: test failed: step %d: the line \"%s\" has no date or no zone of the rule of auto", index + 1, line)
		return false
	}
	date_check(index, seconds, step.text, machine.started_unix, machine.clock_offset_seconds) or_return
	// The zone that the test set: the line must be of the rule in that
	// zone, not of a line written before the zone reached the date page.
	if step.expected != "" {
		wanted_zone, zone_ok := strconv.parse_i64(step.expected)
		if !zone_ok || zone != wanted_zone {
			fmt.eprintfln("modustool: test failed: step %d: the line \"%s\" has a zone of %d s, not %s s", index + 1, line, zone, step.expected)
			return false
		}
	}
	in_force := appearance.in_force_of(.Auto, {known = true, milliseconds = seconds * 1000, zone_offset_seconds = zone})
	wanted := strings.concatenate({appearance.SENTENCE_START, settings.appearance_in_force_names[in_force], ": auto, "}, context.temp_allocator)
	if !strings.contains(line, wanted) {
		fmt.eprintfln("modustool: test failed: step %d: the line \"%s\" does not say \"%s\", which the rule of the day gives at %d s since 1970 with a zone of %d s", index + 1, line, wanted, seconds, zone)
		return false
	}
	test_passed_print("the appearance in force of auto is %s, the rule of the day at %d s since 1970", settings.appearance_in_force_names[in_force], seconds)
	return true
}
