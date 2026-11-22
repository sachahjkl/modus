// The state of the clock application with no window and no clock: the
// stopwatch, the countdown timer, the month of the calendar and the texts
// of a time. Each procedure takes the time as an argument, so a host test
// drives each state machine through each edge
// (src/md/features/clock_application.md).
package clock_model

import "modus:calendar"

// The texts.

// A text that a procedure of this package writes, in the memory of the
// caller. A text past the room is cut: no text of this package is longer.
Text_Room :: struct {
	bytes: [64]u8,
	count: int,
}

text_put :: proc "contextless" (room: ^Text_Room, part: string) {
	for byte in transmute([]u8)part {
		if room.count < len(room.bytes) {
			room.bytes[room.count] = byte
			room.count += 1
		}
	}
}

// text_put_digits writes the decimal digits of a value, with zeros in
// front up to digits: 7 with 2 digits is "07". A value with more digits
// keeps them all.
text_put_digits :: proc "contextless" (room: ^Text_Room, value: u64, digits: int) {
	buffer: [20]u8
	count := 0
	rest := value
	for count < len(buffer) && (rest > 0 || count < digits) {
		buffer[len(buffer) - 1 - count] = u8('0' + rest % 10)
		rest /= 10
		count += 1
	}
	text_put(room, string(buffer[len(buffer) - count:]))
}

text_of :: proc "contextless" (room: ^Text_Room) -> string {
	return string(room.bytes[:room.count])
}

MILLISECONDS_IN_A_SECOND :: 1000
MILLISECONDS_IN_A_MINUTE :: 60 * MILLISECONDS_IN_A_SECOND
MILLISECONDS_IN_AN_HOUR :: 60 * MILLISECONDS_IN_A_MINUTE

// elapsed_text writes a time of the stopwatch with its tenths of a second:
// "04:07.3" under an hour, "1:04:07.3" past it. The tenth is cut, never
// rounded up: the text never shows a time that has not come yet.
elapsed_text :: proc "contextless" (room: ^Text_Room, milliseconds: u64) -> string {
	room.count = 0
	hours := milliseconds / MILLISECONDS_IN_AN_HOUR
	if hours > 0 {
		text_put_digits(room, hours, 1)
		text_put(room, ":")
	}
	text_put_digits(room, milliseconds / MILLISECONDS_IN_A_MINUTE % 60, 2)
	text_put(room, ":")
	text_put_digits(room, milliseconds / MILLISECONDS_IN_A_SECOND % 60, 2)
	text_put(room, ".")
	text_put_digits(room, milliseconds / 100 % 10, 1)
	return text_of(room)
}

// remaining_text writes a time that the timer has left, in whole seconds
// rounded up: "05:00" until the last millisecond of the first second has
// gone, then "04:59". So the text shows "00:00" only at the end.
remaining_text :: proc "contextless" (room: ^Text_Room, milliseconds: u64) -> string {
	room.count = 0
	seconds := milliseconds / MILLISECONDS_IN_A_SECOND + (milliseconds % MILLISECONDS_IN_A_SECOND != 0 ? 1 : 0)
	if seconds >= 3600 {
		text_put_digits(room, seconds / 3600, 1)
		text_put(room, ":")
	}
	text_put_digits(room, seconds / 60 % 60, 2)
	text_put(room, ":")
	text_put_digits(room, seconds % 60, 2)
	return text_of(room)
}

// time_of_day_text writes the hour, the minute and the second of a date:
// "09:05:03".
time_of_day_text :: proc "contextless" (room: ^Text_Room, value: calendar.Civil) -> string {
	room.count = 0
	text_put_digits(room, u64(clamp(value.hour, 0, 23)), 2)
	text_put(room, ":")
	text_put_digits(room, u64(clamp(value.minute, 0, 59)), 2)
	text_put(room, ":")
	text_put_digits(room, u64(clamp(value.second, 0, 59)), 2)
	return text_of(room)
}

@(rodata)
WEEKDAY_NAMES := [calendar.Weekday]string {
	.Monday    = "Monday",
	.Tuesday   = "Tuesday",
	.Wednesday = "Wednesday",
	.Thursday  = "Thursday",
	.Friday    = "Friday",
	.Saturday  = "Saturday",
	.Sunday    = "Sunday",
}

@(rodata)
MONTH_NAMES := [12]string{"January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"}

// month_name gives the name of a month from 1 to 12, or "" for a number
// that names no month.
month_name :: proc "contextless" (month: int) -> string {
	if month < 1 || month > 12 {
		return ""
	}
	return MONTH_NAMES[month - 1]
}

// zone_text writes a time zone as an offset from UTC, in the form of ISO
// 8601 after "UTC": "UTC+01:00", "UTC-03:30", "UTC+00:00". A zone is a
// whole count of minutes; the seconds of the page are cut. A zone past the
// bound of the date page is cut to it, as local_civil cuts it, so the text
// names the zone of the time beside it.
zone_text :: proc "contextless" (room: ^Text_Room, zone_offset_seconds: i64) -> string {
	zone := clamp(zone_offset_seconds, -ZONE_OFFSET_SECONDS_LIMIT, ZONE_OFFSET_SECONDS_LIMIT)
	room.count = 0
	text_put(room, "UTC")
	text_put(room, zone < 0 ? "-" : "+")
	minutes := u64(abs(zone)) / 60
	text_put_digits(room, minutes / 60, 2)
	text_put(room, ":")
	text_put_digits(room, minutes % 60, 2)
	return text_of(room)
}

// date_text writes the date in words, with the zone after it: "Sunday 22
// November 2026, UTC+01:00".
date_text :: proc "contextless" (room: ^Text_Room, value: calendar.Civil, zone_offset_seconds: i64) -> string {
	zone: Text_Room
	zone_text(&zone, zone_offset_seconds)
	room.count = 0
	text_put(room, WEEKDAY_NAMES[value.weekday])
	text_put(room, " ")
	text_put_digits(room, u64(clamp(value.day, 0, 31)), 1)
	text_put(room, " ")
	text_put(room, month_name(value.month))
	text_put(room, " ")
	text_put_digits(room, u64(max(value.year, 0)), 4)
	text_put(room, ", ")
	text_put(room, text_of(&zone))
	return text_of(room)
}

// month_title_text writes the title of a month of the calendar: "November
// 2026".
month_title_text :: proc "contextless" (room: ^Text_Room, year: i64, month: int) -> string {
	room.count = 0
	text_put(room, month_name(month))
	text_put(room, " ")
	text_put_digits(room, u64(max(year, 0)), 4)
	return text_of(room)
}

// The largest time zone of the earth, as the date page bounds it.
ZONE_OFFSET_SECONDS_LIMIT :: i64(14 * 3600)

// local_civil gives the local date and time of a date in milliseconds since
// 1970 (UTC), with a zone. The zone is cut to the bound of the date page,
// so a sum never wraps.
local_civil :: proc "contextless" (milliseconds_since_1970: i64, zone_offset_seconds: i64) -> calendar.Civil {
	zone := clamp(zone_offset_seconds, -ZONE_OFFSET_SECONDS_LIMIT, ZONE_OFFSET_SECONDS_LIMIT)
	return calendar.civil(calendar.floor_divide(milliseconds_since_1970, 1000) + zone)
}

// milliseconds_to_next_second gives the wait to the next whole second of a
// date in milliseconds: 1 to 1000.
milliseconds_to_next_second :: proc "contextless" (milliseconds_since_1970: i64) -> u64 {
	return u64(1000 - (milliseconds_since_1970 % 1000 + 1000) % 1000)
}

// The stopwatch.

LAP_CAPACITY :: 99 // The laps of one run of the stopwatch: two digits of a lap number.

Stopwatch_State :: enum u8 {
	Stopped = 0, // It does not count. With no elapsed time and no lap, it is reset.
	Running = 1, // It counts from started_at.
}

// The stopwatch counts from the time of the system, never by a step at each
// wake: the elapsed time is the sum of the closed runs and the time since
// the last start.
Stopwatch :: struct {
	state:           Stopwatch_State,
	elapsed_of_runs: u64, // The milliseconds of the runs that a stop closed.
	started_at:      u64, // The time of the system at the last start, in milliseconds.
	laps:            [LAP_CAPACITY]u64, // The elapsed time at each lap, in milliseconds, the first lap first.
	lap_count:       int,
}

// stopwatch_elapsed gives the elapsed time at the time now of the system.
// A time before the start counts as the start: the time of the system
// never goes back, and a caller that read it before the start gets no
// negative run.
stopwatch_elapsed :: proc "contextless" (watch: ^Stopwatch, now: u64) -> u64 {
	switch watch.state {
	case .Stopped:
		return watch.elapsed_of_runs
	case .Running:
		return watch.elapsed_of_runs + (now > watch.started_at ? now - watch.started_at : 0)
	}
	return watch.elapsed_of_runs
}

// stopwatch_start starts a stopped stopwatch. false: it runs already, and
// nothing changed.
stopwatch_start :: proc "contextless" (watch: ^Stopwatch, now: u64) -> bool {
	if watch.state == .Running {
		return false
	}
	watch.state = .Running
	watch.started_at = now
	return true
}

// stopwatch_stop stops a running stopwatch and keeps its elapsed time.
// false: it does not run, and nothing changed.
stopwatch_stop :: proc "contextless" (watch: ^Stopwatch, now: u64) -> bool {
	if watch.state != .Running {
		return false
	}
	watch.elapsed_of_runs = stopwatch_elapsed(watch, now)
	watch.state = .Stopped
	return true
}

// stopwatch_toggle starts a stopped stopwatch and stops a running one: the
// key Space and the first button.
stopwatch_toggle :: proc "contextless" (watch: ^Stopwatch, now: u64) {
	if !stopwatch_start(watch, now) {
		stopwatch_stop(watch, now)
	}
}

Lap_Refusal :: enum u8 {
	None        = 0, // The lap is kept.
	Not_Running = 1, // A stopped stopwatch takes no lap: its time does not move.
	Full        = 2, // LAP_CAPACITY laps are kept already.
}

// stopwatch_lap keeps the elapsed time at now as a lap.
stopwatch_lap :: proc "contextless" (watch: ^Stopwatch, now: u64) -> Lap_Refusal {
	if watch.state != .Running {
		return .Not_Running
	}
	if watch.lap_count >= LAP_CAPACITY {
		return .Full
	}
	watch.laps[watch.lap_count] = stopwatch_elapsed(watch, now)
	watch.lap_count += 1
	return .None
}

// stopwatch_reset sets a stopped stopwatch to zero and removes its laps.
// false: it runs; a reset of a running stopwatch would lose the run, so the
// principal stops it first.
stopwatch_reset :: proc "contextless" (watch: ^Stopwatch) -> bool {
	if watch.state == .Running {
		return false
	}
	watch^ = {}
	return true
}

// stopwatch_lap_times gives the time of one lap (from the lap before it)
// and its total, for a lap number from 0. ok is false for a number that
// names no lap.
stopwatch_lap_times :: proc "contextless" (watch: ^Stopwatch, index: int) -> (own, total: u64, ok: bool) {
	if index < 0 || index >= watch.lap_count || index >= LAP_CAPACITY {
		return 0, 0, false
	}
	total = watch.laps[index]
	before := index > 0 ? watch.laps[index - 1] : 0
	return total - min(before, total), total, true
}

// The countdown timer.

TIMER_DURATION_LEAST :: u64(1 * MILLISECONDS_IN_A_SECOND) // The shortest duration: one second.
TIMER_DURATION_LIMIT :: u64((99 * 3600 + 59 * 60 + 59) * MILLISECONDS_IN_A_SECOND) // The longest: 99:59:59, two digits of hours.
TIMER_DURATION_FIRST :: u64(5 * MILLISECONDS_IN_A_MINUTE) // The duration at the start of the process.

Timer_State :: enum u8 {
	Ready   = 0, // It holds its whole duration; the duration can change.
	Running = 1, // It counts down to ends_at.
	Paused  = 2, // It keeps the time that it has left.
	Ended   = 3, // It reached 0; it stays there until a reset.
}

// The timer keeps the time of the system at which it ends, so a late wake
// does not move the end.
Timer :: struct {
	state:              Timer_State,
	duration:           u64, // The whole duration, in milliseconds: TIMER_DURATION_LEAST to TIMER_DURATION_LIMIT.
	remaining_at_pause: u64, // Ready and Paused: the milliseconds left.
	ends_at:            u64, // Running: the time of the system at the end, in milliseconds.
}

// timer_make gives a ready timer of a duration, cut to the range of a
// duration.
timer_make :: proc "contextless" (duration: u64 = TIMER_DURATION_FIRST) -> Timer {
	kept := clamp(duration, TIMER_DURATION_LEAST, TIMER_DURATION_LIMIT)
	return {state = .Ready, duration = kept, remaining_at_pause = kept}
}

// timer_remaining gives the milliseconds that the timer has left at the
// time now of the system.
timer_remaining :: proc "contextless" (timer: ^Timer, now: u64) -> u64 {
	switch timer.state {
	case .Ready, .Paused:
		return timer.remaining_at_pause
	case .Running:
		return timer.ends_at > now ? timer.ends_at - now : 0
	case .Ended:
		return 0
	}
	return 0
}

// timer_duration_set sets the duration of a timer that is ready. false: the
// timer is not ready, or the duration is out of its range; nothing changed.
timer_duration_set :: proc "contextless" (timer: ^Timer, duration: u64) -> bool {
	if timer.state != .Ready || duration < TIMER_DURATION_LEAST || duration > TIMER_DURATION_LIMIT {
		return false
	}
	timer.duration = duration
	timer.remaining_at_pause = duration
	return true
}

// timer_duration_change adds a signed count of milliseconds to the duration
// of a ready timer, and stops at the two bounds: -1 min on 30 s gives the
// least duration, one second. false: the timer is not ready, or the
// duration is at that bound already; nothing changed.
timer_duration_change :: proc "contextless" (timer: ^Timer, change: i64) -> bool {
	if timer.state != .Ready {
		return false
	}
	wanted: u64
	if change < 0 {
		// The negation of the least i64 has no i64: take one away first.
		taken := u64(-(change + 1)) + 1
		wanted = timer.duration > taken ? timer.duration - taken : 0
	} else {
		room := TIMER_DURATION_LIMIT - min(timer.duration, TIMER_DURATION_LIMIT)
		wanted = u64(change) > room ? TIMER_DURATION_LIMIT : timer.duration + u64(change)
	}
	wanted = clamp(wanted, TIMER_DURATION_LEAST, TIMER_DURATION_LIMIT)
	if wanted == timer.duration {
		return false
	}
	return timer_duration_set(timer, wanted)
}

// timer_start starts a ready or a paused timer. false: it runs or it
// ended; nothing changed.
timer_start :: proc "contextless" (timer: ^Timer, now: u64) -> bool {
	switch timer.state {
	case .Ready, .Paused:
		timer.ends_at = now + timer.remaining_at_pause
		timer.state = .Running
		return true
	case .Running, .Ended:
		return false
	}
	return false
}

// timer_pause pauses a running timer and keeps the time that it has left.
// false: it does not run; nothing changed.
timer_pause :: proc "contextless" (timer: ^Timer, now: u64) -> bool {
	if timer.state != .Running {
		return false
	}
	timer.remaining_at_pause = timer_remaining(timer, now)
	timer.state = .Paused
	return true
}

// timer_toggle starts a ready or a paused timer, and pauses a running one:
// the key Space and the first button. An ended timer does not change.
timer_toggle :: proc "contextless" (timer: ^Timer, now: u64) {
	if !timer_start(timer, now) {
		timer_pause(timer, now)
	}
}

// timer_reset makes the timer ready with its whole duration, from each
// state.
timer_reset :: proc "contextless" (timer: ^Timer) {
	timer.state = .Ready
	timer.remaining_at_pause = timer.duration
	timer.ends_at = 0
}

// timer_step ends a running timer whose end came: true once, at the step
// that sees the end. The process posts its notification then.
timer_step :: proc "contextless" (timer: ^Timer, now: u64) -> (ended_now: bool) {
	if timer.state != .Running || now < timer.ends_at {
		return false
	}
	timer.state = .Ended
	timer.remaining_at_pause = 0
	return true
}

// timer_left_in_millionths gives the part of the duration that is left, in
// millionths: 1 000 000 at the start, 0 at the end.
timer_left_in_millionths :: proc "contextless" (timer: ^Timer, now: u64) -> u64 {
	if timer.duration == 0 {
		return 0
	}
	remaining := min(timer_remaining(timer, now), timer.duration)
	// The duration is at most 360 million milliseconds: the product stays
	// far inside 64 bits.
	return remaining * 1_000_000 / timer.duration
}

// The month of the calendar.

// The months that the calendar shows: the dates of the date page, from
// 1970 to the end of 9999.
CALENDAR_YEAR_FIRST :: i64(1970)
CALENDAR_YEAR_LAST :: i64(9999)
WEEK_DAYS :: 7
MONTH_ROWS_LIMIT :: 6 // A month of 31 days that starts on a Saturday spans 6 weeks.

// A month of the calendar as a grid of weeks, Monday first (ISO 8601).
Month_Grid :: struct {
	year:         i64,
	month:        int, // 1 to 12.
	first_column: int, // The column of day 1: 0 is Monday.
	day_count:    int, // 28 to 31.
	row_count:    int, // The weeks that the month spans: 4 to 6.
}

// month_grid gives the grid of a month. ok is false for a month that is
// not 1 to 12, and for a year out of the range of the calendar.
month_grid :: proc "contextless" (year: i64, month: int) -> (grid: Month_Grid, ok: bool) {
	if month < 1 || month > 12 || year < CALENDAR_YEAR_FIRST || year > CALENDAR_YEAR_LAST {
		return {}, false
	}
	first_day := calendar.days_from_civil(year, month, 1)
	// 1970-01-01, day 0, was a Thursday: column 3.
	grid.first_column = int((first_day % WEEK_DAYS + WEEK_DAYS + 3) % WEEK_DAYS)
	grid.year, grid.month = year, month
	grid.day_count = calendar.days_in_month(year, month)
	grid.row_count = (grid.first_column + grid.day_count + WEEK_DAYS - 1) / WEEK_DAYS
	return grid, true
}

// month_grid_day gives the day in a cell of the grid, from row 0 and
// column 0 (Monday), or false for a cell before day 1 or after the last
// day.
month_grid_day :: proc "contextless" (grid: Month_Grid, row, column: int) -> (day: int, ok: bool) {
	if row < 0 || row >= MONTH_ROWS_LIMIT || column < 0 || column >= WEEK_DAYS {
		return 0, false
	}
	day = row * WEEK_DAYS + column - grid.first_column + 1
	if day < 1 || day > grid.day_count {
		return 0, false
	}
	return day, true
}

// month_step moves a month by a signed count of months. ok is false when
// the month is not 1 to 12, or when the result is out of the range of the
// calendar; the month given back is then the month given.
month_step :: proc "contextless" (year: i64, month: int, step: int) -> (new_year: i64, new_month: int, ok: bool) {
	if month < 1 || month > 12 || year < CALENDAR_YEAR_FIRST || year > CALENDAR_YEAR_LAST {
		return year, month, false
	}
	index := year * 12 + i64(month - 1) + i64(step)
	new_year = calendar.floor_divide(index, 12)
	new_month = int(index - new_year * 12) + 1
	if new_year < CALENDAR_YEAR_FIRST || new_year > CALENDAR_YEAR_LAST {
		return year, month, false
	}
	return new_year, new_month, true
}
