// The date of the machine: this service reads the real-time clock of the machine (the CMOS clock, ports 0x70 and 0x71) at its start and each 10 seconds, and writes in the date page the date of the time 0 of the system. Each program reads the date from the page and the time page, with no kernel entry and no call (src/library/contract/date).
//
// A driver of a clock is a program, not a part of the kernel: the root service gives this program the two ports and the page with the right Write, and nothing else.
//
// The clock gives whole seconds. The service waits for the clock to change its second, so the date of the time 0 is exact to about one millisecond. The clock of the machine keeps UTC (QEMU: -rtc base=utc). Leap seconds are not counted. The year has two digits: the dates are from 2020 to 2099 (src/library/support/calendar, clock_seconds).
//
// **What it is for.** It gives the system a [date](term:date) with no
// kernel entry for a read: the service writes once, in the
// [date page](term:date-page), the date of the time 0 of the system; a
// program adds the time of the [time page](term:time-page) to it. The bar
// of the compositor shows the date and the time this way.
//
// **The time zone** (src/md/features/time_zone.md). The principal chooses
// it with the setting `time_zone` of the program `settings`. This program
// waits on the settings page, which it reads as each program does, and
// copies the zone into the date page: the page then holds the whole local
// time, and the root service, which waits on the date page, moves the next
// edge of the rule of the day at once.
//
// **What a reader sees.** No window. The root service starts it at each
// boot, before the console. The log gets `date: ok, <date> UTC, seconds
// since 1970 <count>, from the real-time clock at the time <time> ms of the
// system; ...`, then, after a new read of the clock, a line with the
// correction (`date: the clock read again ... the date moved by <count>
// ms`): after the first read, after each 30th read, and after a move of one
// second or more. With no valid clock, the log says `the system has no
// date` at the level error, and the bar shows the time since boot. At each
// new zone: `date: the time zone of the date page is +08:00, from the
// setting time_zone`.
//
// **Its grants**: **Clock**, the date page with the right Write and the two
// ports of the clock (the one writer of the date), and **Serve**, its
// export `now`. The settings page, read-only, as each program that is not
// a terminal.
//
// ```
// connect("date")
// date.now()
// ```
package date_service

import "base:intrinsics"
import "modus:contract/date"
import "modus:contract/fixed_addresses"
import "modus:contract/settings"
import "modus:support/calendar"
import "modus:support/system"

PORT_INDEX :: 0x70
PORT_DATA :: 0x71

REGISTER_SECONDS :: 0x00
REGISTER_MINUTES :: 0x02
REGISTER_HOURS :: 0x04
REGISTER_DAY :: 0x07
REGISTER_MONTH :: 0x08
REGISTER_YEAR :: 0x09
REGISTER_STATUS_A :: 0x0A // Bit 7: the clock updates its registers now.
REGISTER_STATUS_B :: 0x0B // The mode of the values (calendar.CLOCK_STATUS_BINARY, CLOCK_STATUS_24_HOURS).

// The bounds of the reads: a clock that never ends an update, or whose
// registers change at each read, gives no date; the service then waits for
// no clock.
UPDATE_READS_LIMIT :: 10_000 // An update takes about 2 ms; one read of a port takes about 1 us.
STABLE_READS_LIMIT :: 8

// register_read reads one register of the clock. Bit 7 of the index is 0,
// so the non-maskable interrupt stays on. The grant of the two ports lets
// this program write any index and read any byte of the memory of the
// clock: the processor gives a program a port, not a value of a port.
register_read :: proc "contextless" (register: u8) -> u8 {
	system.port_write_8(PORT_INDEX, register)
	return system.port_read_8(PORT_DATA)
}

// clock_read reads the registers of the date, after the end of an update.
clock_read :: proc "contextless" () -> (reading: calendar.Clock_Reading, valid: bool) {
	for reads := 0; register_read(REGISTER_STATUS_A) & 0x80 != 0; reads += 1 {
		if reads >= UPDATE_READS_LIMIT {
			return {}, false
		}
	}
	reading.second = register_read(REGISTER_SECONDS)
	reading.minute = register_read(REGISTER_MINUTES)
	reading.hour = register_read(REGISTER_HOURS)
	reading.day = register_read(REGISTER_DAY)
	reading.month = register_read(REGISTER_MONTH)
	reading.year = register_read(REGISTER_YEAR)
	return reading, true
}

// stable_read reads the clock until two readings agree: an update between
// two registers gives a wrong mix.
stable_read :: proc "contextless" () -> (reading: calendar.Clock_Reading, valid: bool) {
	reading = clock_read() or_return
	for _ in 0 ..< STABLE_READS_LIMIT {
		again := clock_read() or_return
		if again == reading {
			return reading, true
		}
		reading = again
	}
	return {}, false
}

// seconds_of_reading gives the seconds since 1970 of a reading, in the mode
// of the clock (calendar.clock_seconds checks each field).
seconds_of_reading :: proc "contextless" (reading: calendar.Clock_Reading) -> (seconds: i64, valid: bool) {
	return calendar.clock_seconds(reading, register_read(REGISTER_STATUS_B))
}

// One answer of now().
Date :: struct {
	milliseconds: i64, // Since 1970-01-01 00:00:00 UTC.
	year:         i64,
	month:        i64,
	day:          i64,
	hour:         i64,
	minute:       i64,
	second:       i64,
	weekday:      i64, // 1: Monday to 7: Sunday (ISO 8601).
}

page: ^date.Page
settings_page: ^settings.Page // The settings page, read-only; nil: the zone stays UTC.

// zone_follow copies the time zone of the settings page into the date page
// when the two differ, and wakes the waiters of the date page: the root
// service then computes the rule of the day in the new local time. A read
// that gave up or that refused the page copies nothing: from a page left in
// a change (an odd count), from a read whose count moved after it (the
// count only grows, so the wait of the loop ends at once and the next turn
// reads the page again), and from a page with a word that names no value.
zone_follow :: proc "contextless" () {
	if settings_page == nil {
		return
	}
	choice, ok := settings.read(settings_page)
	if !ok || intrinsics.atomic_load_explicit(&settings_page.change_count, .Acquire) != choice.change_count {
		return
	}
	zone := i64(choice.zone_offset_minutes) * 60
	if zone == date.zone_offset_seconds_read(page) {
		return
	}
	// The line comes before the write: the lines that the new zone causes
	// (the root service, the bar) then come after it on the log.
	text: [settings.ZONE_TEXT_SIZE]u8
	system.log("date: the time zone of the date page is ", settings.zone_text(text[:], choice.zone_offset_minutes), ", from the setting ", settings.TIME_ZONE_NAME)
	date.zone_write(page, zone)
	system.word_wake(&page.change_count, system.WAKE_ALL)
}

// now gives the date and the time of day in UTC, from the date page and the time page: the same value that each program reads with no call. All zero: the machine has no date.
//
// **What it is for.** A caller with no date page (the console, the host
// through the remote service) reads the date as one record, with its
// fields already split.
//
// **The record** (`Date`): `milliseconds` since 1970-01-01 00:00:00 UTC;
// `year`, `month` (1 to 12), `day`, `hour`, `minute`, `second`; `weekday`,
// 1 for Monday to 7 for Sunday (ISO 8601). Leap seconds are not counted.
//
// **Errors**: none. A record of zeros means that the date page has no date
// yet: the clock was not read, or gave no valid date. The export needs no
// grant beyond a connection to the service.
//
// ```
// connect("date")
// date.now().year
// ```
@(export, link_name = "now")
now :: proc "c" (result: ^Date) {
	milliseconds, known := date.milliseconds_now(page, system.time())
	if !known {
		result^ = {}
		return
	}
	value := calendar.civil(calendar.floor_divide(milliseconds, 1000))
	result^ = {milliseconds = milliseconds, year = value.year, month = i64(value.month), day = i64(value.day), hour = i64(value.hour), minute = i64(value.minute), second = i64(value.second), weekday = i64(value.weekday) + 1}
}

RESYNC_MILLISECONDS :: 10_000 // The time between two reads of the clock.

// synchronize waits for the clock to change its second (up to 2 seconds),
// and gives the date of the time 0 of the system at that edge.
synchronize :: proc "contextless" () -> (at_zero: i64, seconds: i64, edge_milliseconds: u64, valid: bool) {
	started := system.nanoseconds()
	first := stable_read() or_return
	reading := first
	edge: u64
	for reading.second == first.second && system.nanoseconds() - started < 2_000_000_000 {
		system.sleep(system.time() + 1)
		reading = stable_read() or_return
		edge = system.nanoseconds()
	}
	seconds, valid = seconds_of_reading(reading)
	if !valid || reading.second == first.second {
		return 0, 0, 0, false
	}
	return seconds * 1000 - i64(edge / 1_000_000), seconds, edge / 1_000_000, true
}

// entry maps the date page, reads the clock and writes the first date,
// then reads the clock again each 10 seconds and serves `now`, until the
// machine stops.
//
// **The first read** waits for the clock to change its second
// (`synchronize`), so the date of the time 0 is exact to about one
// millisecond. **Each next read** corrects the page: the time of the
// system comes from the cycle counter, with a frequency that the kernel
// measured at boot, and it drifts from the clock.
//
// **The stop**: with no date page or no ports, it writes `date: no date
// page or no ports of the clock: the system has no date` at the level
// error, and stops with the code 1. A clock that gives no valid date does
// not stop it: it writes the error, and tries again at the next read.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	service, _ := system.service_open(ctx)
	address, status := system.memory_map(ctx.handles[date.GRANT_PAGE], {.Write})
	if status != .Ok || ctx.handles[date.GRANT_PORTS] == 0 {
		system.log_in("date", .Error, "date: no date page or no ports of the clock: the system has no date")
		system.stop(1)
	}
	page = (^date.Page)(address)
	if .Settings_Page in fixed_addresses.ranges_mapped(&ctx.values) {
		settings_page = (^settings.Page)(uintptr(settings.PAGE_ADDRESS))
	}
	zone_follow()
	started := system.nanoseconds()
	at_zero, seconds, edge, valid := synchronize()
	if !valid {
		system.log_in("date", .Error, "date: the real-time clock gives no valid date: the system has no date")
	} else {
		date.write(page, .Real_Time_Clock, at_zero)
		// The first date changes the rule of the day: the root service waits
		// on this word for it.
		system.word_wake(&page.change_count, system.WAKE_ALL)
		text: [32]u8
		system.log("date: ok, ", calendar.iso_text(text[:], seconds), " UTC, seconds since 1970 ", seconds, ", from the real-time clock at the time ", edge, " ms of the system; the date of the time 0 in ", (system.nanoseconds() - started) / 1000, " us")
	}
	// The time of the system comes from the cycle counter, with a frequency
	// that the kernel measured at boot: it can run faster or slower than the
	// clock. The service reads the clock again at an interval and corrects the
	// page, so the date never drifts more than the drift of one interval.
	first_at_zero := at_zero
	corrections: u64
	next := system.time() + RESYNC_MILLISECONDS
	for {
		wait: system.Wait
		system.service_wait(&wait, &service)
		// The count is read before the zone: a change of the settings
		// page after this read ends the wait at once.
		if settings_page != nil {
			system.wait_word(&wait, &settings_page.change_count, intrinsics.atomic_load_explicit(&settings_page.change_count, .Acquire))
		}
		zone_follow()
		system.wait_end(&wait, next)
		system.service_run(&service)
		if system.time() < next {
			continue
		}
		next = system.time() + RESYNC_MILLISECONDS
		corrected, _, edge_now, corrected_valid := synchronize()
		if !corrected_valid {
			continue
		}
		_, known := date.milliseconds_now(page, 0)
		before := page.milliseconds_at_time_zero
		date.write(page, .Real_Time_Clock, corrected)
		corrections += 1
		if !known || corrections == 1 || corrections % 30 == 0 || abs(corrected - before) >= 1000 {
			// The drift since the first read: what the time of the system lost
			// or gained against the clock.
			system.log("date: the clock read again at the time ", edge_now, " ms of the system: the date moved by ", corrected - before, " ms; ", corrected - first_at_zero, " ms since the start, ", corrections, corrections == 1 ? string(" read") : string(" reads"), " after the first")
			// The first date after a clock that gave none, or a move of a
			// second or more (a machine paused, a clock set again), can move
			// the next edge of the rule of the day: the root service waits on
			// this word for it. A drift of milliseconds moves no edge, so the
			// other corrections wake nobody, and the reads that only log wake
			// the root service for one turn that changes nothing.
			system.word_wake(&page.change_count, system.WAKE_ALL)
		}
	}
}
