#+build !freestanding
package clock_model

import "core:testing"
import "modus:calendar"

// A stopwatch refuses each act that its state does not take, and nothing
// changes: a stop and a lap of a stopped watch, a start and a reset of a
// running one.
@(test)
a_stopwatch_refuses_the_acts_of_the_other_state :: proc(t: ^testing.T) {
	watch: Stopwatch
	testing.expect(t, !stopwatch_stop(&watch, 0))
	testing.expect_value(t, stopwatch_lap(&watch, 0), Lap_Refusal.Not_Running)
	testing.expect_value(t, watch.lap_count, 0)
	testing.expect(t, stopwatch_start(&watch, 100))
	testing.expect(t, !stopwatch_start(&watch, 900), "a second start would move the start")
	testing.expect_value(t, watch.started_at, u64(100))
	testing.expect(t, !stopwatch_reset(&watch), "a reset of a running watch loses the run")
	testing.expect_value(t, stopwatch_elapsed(&watch, 600), u64(500))
}

// The elapsed time is the sum of the runs: a pause loses no millisecond,
// and a time before the start counts as the start.
@(test)
the_elapsed_time_is_the_sum_of_the_runs :: proc(t: ^testing.T) {
	watch: Stopwatch
	testing.expect_value(t, stopwatch_elapsed(&watch, max(u64)), u64(0))
	stopwatch_start(&watch, 1000)
	testing.expect_value(t, stopwatch_elapsed(&watch, 999), u64(0))
	testing.expect_value(t, stopwatch_elapsed(&watch, 1000), u64(0))
	testing.expect_value(t, stopwatch_elapsed(&watch, 1001), u64(1))
	stopwatch_stop(&watch, 3500)
	testing.expect_value(t, stopwatch_elapsed(&watch, 99_999), u64(2500))
	stopwatch_toggle(&watch, 10_000)
	testing.expect_value(t, watch.state, Stopwatch_State.Running)
	testing.expect_value(t, stopwatch_elapsed(&watch, 10_250), u64(2750))
	stopwatch_toggle(&watch, 10_250)
	testing.expect_value(t, watch.state, Stopwatch_State.Stopped)
	testing.expect(t, stopwatch_reset(&watch))
	testing.expect_value(t, stopwatch_elapsed(&watch, 20_000), u64(0))
}

// The laps fill to their capacity and refuse one more; each lap has its own
// time and its total; a number that names no lap is refused.
@(test)
the_laps_stop_at_their_capacity :: proc(t: ^testing.T) {
	watch: Stopwatch
	stopwatch_start(&watch, 0)
	for index in 0 ..< LAP_CAPACITY {
		testing.expect_value(t, stopwatch_lap(&watch, u64(index + 1) * 10), Lap_Refusal.None)
	}
	testing.expect_value(t, stopwatch_lap(&watch, 5000), Lap_Refusal.Full)
	testing.expect_value(t, watch.lap_count, LAP_CAPACITY)
	for index in ([]int{-1, LAP_CAPACITY, max(int)}) {
		_, _, ok := stopwatch_lap_times(&watch, index)
		testing.expectf(t, !ok, "the lap %d is refused", index)
	}
	own, total, ok := stopwatch_lap_times(&watch, 0)
	testing.expect(t, ok && own == 10 && total == 10)
	own, total, ok = stopwatch_lap_times(&watch, LAP_CAPACITY - 1)
	testing.expect(t, ok && own == 10 && total == LAP_CAPACITY * 10)
	stopwatch_stop(&watch, 2000)
	stopwatch_reset(&watch)
	_, _, ok = stopwatch_lap_times(&watch, 0)
	testing.expect(t, !ok, "a reset removes the laps")
}

// A duration out of its range is refused and nothing changes; the edges
// are taken.
@(test)
a_timer_refuses_a_duration_out_of_its_range :: proc(t: ^testing.T) {
	timer := timer_make()
	for duration in ([]u64{0, 1, TIMER_DURATION_LEAST - 1, TIMER_DURATION_LIMIT + 1, max(u64)}) {
		testing.expectf(t, !timer_duration_set(&timer, duration), "the duration %d is refused", duration)
		testing.expect_value(t, timer.duration, TIMER_DURATION_FIRST)
	}
	testing.expect(t, timer_duration_set(&timer, TIMER_DURATION_LEAST))
	testing.expect(t, !timer_duration_change(&timer, -1), "at the least bound, a step down changes nothing")
	testing.expect(t, !timer_duration_change(&timer, min(i64)))
	testing.expect_value(t, timer.duration, TIMER_DURATION_LEAST)
	testing.expect(t, timer_duration_change(&timer, max(i64)))
	testing.expect_value(t, timer.duration, TIMER_DURATION_LIMIT)
	testing.expect(t, !timer_duration_change(&timer, 1))
	testing.expect(t, timer_duration_set(&timer, 30_000))
	testing.expect(t, timer_duration_change(&timer, -60_000), "a step past the bound stops at the bound")
	testing.expect_value(t, timer.duration, TIMER_DURATION_LEAST)
	// timer_make cuts its duration to the range too.
	testing.expect_value(t, timer_make(0).duration, TIMER_DURATION_LEAST)
	testing.expect_value(t, timer_make(max(u64)).duration, TIMER_DURATION_LIMIT)
}

// A timer that is not ready refuses a change of its duration; each state
// refuses the acts that it does not take.
@(test)
a_timer_refuses_the_acts_of_the_other_states :: proc(t: ^testing.T) {
	timer := timer_make(10_000)
	testing.expect(t, !timer_pause(&timer, 0), "a ready timer does not pause")
	testing.expect(t, !timer_step(&timer, max(u64)), "a ready timer does not end")
	testing.expect(t, timer_start(&timer, 1000))
	testing.expect(t, !timer_start(&timer, 2000))
	testing.expect(t, !timer_duration_set(&timer, 20_000))
	testing.expect(t, !timer_duration_change(&timer, 1000))
	testing.expect_value(t, timer.duration, u64(10_000))
	testing.expect(t, timer_pause(&timer, 4000))
	testing.expect(t, !timer_duration_set(&timer, 20_000), "a paused timer keeps its duration")
	testing.expect(t, !timer_step(&timer, max(u64)), "a paused timer does not end")
	testing.expect_value(t, timer_remaining(&timer, max(u64)), u64(7000))
}

// The end is a time of the system: a pause moves it by the pause, a late
// step ends the timer once, and the end stays until a reset.
@(test)
the_timer_ends_once_at_its_time :: proc(t: ^testing.T) {
	timer := timer_make(10_000)
	timer_toggle(&timer, 1000)
	testing.expect_value(t, timer_remaining(&timer, 1000), u64(10_000))
	testing.expect_value(t, timer_left_in_millionths(&timer, 6000), u64(500_000))
	timer_toggle(&timer, 6000)
	testing.expect_value(t, timer.state, Timer_State.Paused)
	timer_toggle(&timer, 100_000)
	testing.expect_value(t, timer.ends_at, u64(105_000))
	testing.expect(t, !timer_step(&timer, 104_999))
	testing.expect_value(t, timer_remaining(&timer, 104_999), u64(1))
	testing.expect(t, timer_step(&timer, 900_000), "a late step ends it")
	testing.expect(t, !timer_step(&timer, 900_001), "the end comes once")
	testing.expect_value(t, timer.state, Timer_State.Ended)
	testing.expect_value(t, timer_remaining(&timer, 0), u64(0))
	testing.expect(t, !timer_start(&timer, 0), "an ended timer does not start again")
	timer_toggle(&timer, 0)
	testing.expect_value(t, timer.state, Timer_State.Ended)
	timer_reset(&timer)
	testing.expect_value(t, timer.state, Timer_State.Ready)
	testing.expect_value(t, timer_remaining(&timer, 0), u64(10_000))
	testing.expect_value(t, timer_left_in_millionths(&timer, 0), u64(1_000_000))
}

// The texts of a time: the edges of each unit.
@(test)
the_texts_of_a_time :: proc(t: ^testing.T) {
	room: Text_Room
	testing.expect_value(t, elapsed_text(&room, 0), "00:00.0")
	testing.expect_value(t, elapsed_text(&room, 99), "00:00.0")
	testing.expect_value(t, elapsed_text(&room, 59_999), "00:59.9")
	testing.expect_value(t, elapsed_text(&room, 3_599_999), "59:59.9")
	testing.expect_value(t, elapsed_text(&room, 3_600_000), "1:00:00.0")
	testing.expect_value(t, elapsed_text(&room, max(u64)), "5124095576030:25:51.6")
	testing.expect_value(t, remaining_text(&room, 0), "00:00")
	testing.expect_value(t, remaining_text(&room, 1), "00:01")
	testing.expect_value(t, remaining_text(&room, 1000), "00:01")
	testing.expect_value(t, remaining_text(&room, 1001), "00:02")
	testing.expect_value(t, remaining_text(&room, 3_600_000), "1:00:00")
	testing.expect_value(t, remaining_text(&room, TIMER_DURATION_LIMIT), "99:59:59")
	testing.expect_value(t, zone_text(&room, 0), "UTC+00:00")
	testing.expect_value(t, zone_text(&room, 3600), "UTC+01:00")
	testing.expect_value(t, zone_text(&room, -(3 * 3600 + 30 * 60)), "UTC-03:30")
	testing.expect_value(t, zone_text(&room, 5 * 3600 + 45 * 60 + 59), "UTC+05:45")
	testing.expect_value(t, zone_text(&room, min(i64)), "UTC-14:00")
	testing.expect_value(t, zone_text(&room, max(i64)), "UTC+14:00")
	testing.expect_value(t, month_name(0), "")
	testing.expect_value(t, month_name(13), "")
	testing.expect_value(t, month_name(-1), "")
	testing.expect_value(t, month_name(1), "January")
	testing.expect_value(t, month_name(12), "December")
	// 2026-11-22 00:00:00 UTC was a Sunday.
	sunday := calendar.civil(1_795_305_600)
	testing.expect_value(t, date_text(&room, sunday, 3600), "Sunday 22 November 2026, UTC+01:00")
	testing.expect_value(t, time_of_day_text(&room, sunday), "00:00:00")
	testing.expect_value(t, month_title_text(&room, 2026, 11), "November 2026")
}

// The local time: the zone moves the date across midnight in each
// direction, and a zone past the bound of the page is cut to it.
@(test)
the_local_time_crosses_midnight :: proc(t: ^testing.T) {
	// 2026-11-22 23:30:00 UTC.
	late := i64(1_795_305_600 + 23 * 3600 + 30 * 60) * 1000
	east := local_civil(late, 3600)
	testing.expect(t, east.day == 23 && east.hour == 0 && east.minute == 30)
	west := local_civil(i64(1_795_305_600) * 1000, -60)
	testing.expect(t, west.day == 21 && west.hour == 23 && west.minute == 59)
	cut := local_civil(late, max(i64))
	testing.expect(t, cut.day == 23 && cut.hour == 13 && cut.minute == 30, "the zone is cut to 14 hours")
	testing.expect_value(t, milliseconds_to_next_second(0), u64(1000))
	testing.expect_value(t, milliseconds_to_next_second(1), u64(999))
	testing.expect_value(t, milliseconds_to_next_second(999), u64(1))
	testing.expect_value(t, milliseconds_to_next_second(-1), u64(1))
}

// A month that is not 1 to 12, or a year out of the range, has no grid; a
// step past the range is refused and gives back the month given.
@(test)
the_calendar_refuses_a_month_out_of_its_range :: proc(t: ^testing.T) {
	for month in ([]int{0, 13, -1, max(int), min(int)}) {
		_, ok := month_grid(2026, month)
		testing.expectf(t, !ok, "the month %d is refused", month)
		_, _, stepped := month_step(2026, month, 1)
		testing.expect(t, !stepped)
	}
	for year in ([]i64{CALENDAR_YEAR_FIRST - 1, CALENDAR_YEAR_LAST + 1, min(i64), max(i64)}) {
		_, ok := month_grid(year, 1)
		testing.expectf(t, !ok, "the year %d is refused", year)
	}
	year, month, ok := month_step(CALENDAR_YEAR_FIRST, 1, -1)
	testing.expect(t, !ok && year == CALENDAR_YEAR_FIRST && month == 1)
	year, month, ok = month_step(CALENDAR_YEAR_LAST, 12, 1)
	testing.expect(t, !ok && year == CALENDAR_YEAR_LAST && month == 12)
	year, month, ok = month_step(2026, 12, 1)
	testing.expect(t, ok && year == 2027 && month == 1)
	year, month, ok = month_step(2026, 1, -1)
	testing.expect(t, ok && year == 2025 && month == 12)
	year, month, ok = month_step(2026, 11, -24)
	testing.expect(t, ok && year == 2024 && month == 11)
}

// The grid of a month: its first column, its days and its weeks, with the
// rule of 400 years that the faulty library module forgets.
@(test)
the_grid_of_a_month :: proc(t: ^testing.T) {
	november, ok := month_grid(2026, 11)
	testing.expect(t, ok)
	// 2026-11-01 was a Sunday: the last column.
	testing.expect_value(t, november.first_column, 6)
	testing.expect_value(t, november.day_count, 30)
	testing.expect_value(t, november.row_count, 6)
	day, found := month_grid_day(november, 0, 6)
	testing.expect(t, found && day == 1)
	_, found = month_grid_day(november, 0, 5)
	testing.expect(t, !found, "the cell before day 1 has no day")
	day, found = month_grid_day(november, 5, 0)
	testing.expect(t, found && day == 30)
	_, found = month_grid_day(november, 5, 1)
	testing.expect(t, !found, "the cell after the last day has no day")
	for cell in ([][2]int{{-1, 0}, {0, -1}, {MONTH_ROWS_LIMIT, 0}, {0, WEEK_DAYS}}) {
		_, found = month_grid_day(november, cell[0], cell[1])
		testing.expect(t, !found)
	}
	february_2000, _ := month_grid(2000, 2)
	testing.expect_value(t, february_2000.day_count, 29)
	february_2100, _ := month_grid(2100, 2)
	testing.expect_value(t, february_2100.day_count, 28)
	// February 2027 starts on a Monday: four whole weeks.
	february_2027, _ := month_grid(2027, 2)
	testing.expect(t, february_2027.first_column == 0 && february_2027.row_count == 4)
	// The first month of the range: 1970-01-01 was a Thursday.
	first, _ := month_grid(CALENDAR_YEAR_FIRST, 1)
	testing.expect_value(t, first.first_column, 3)
}
