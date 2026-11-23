// The clock of the desktop: the local time, the date, a calendar of a
// month, a stopwatch with laps and a countdown timer.
//
// **What it is for.** It is the clock that a principal opens from the bar
// or from the menu of the desktop. The design is in
// src/md/features/clock_application.md.
//
// **What a reader sees.** Start it from the start menu, from the menu of
// the desktop ("open clock"), or with start("clock") in the console.
// Three tabs at the top choose a section; the keys 1, 2 and 3 do the same.
//
// - **clock**: the local time in large digits, the date with its time zone,
//   and the calendar of a month. Page Up and Page Down change the month,
//   Home comes back to the month of today.
// - **stopwatch**: Space starts and stops, L takes a lap, R resets a
//   stopped stopwatch. The laps show the newest first.
// - **timer**: + and - change the duration by one minute, Space starts and
//   pauses, R resets. At the end the window shows 00:00 in the warning
//   color, and the process asks the compositor for a desktop notification.
//
// The local time is the date page and its time zone (the setting
// time_zone of the settings): no kernel entry.
//
// **Its grants**: **Connect** to the compositor only, for the notification
// at the end of the timer, and **Image**, for the description of the
// exports of the compositor.
package clock

import "internal:clock/clock_model"
import "modus:contract/call_outcome"
import "modus:calendar"
import "modus:contract/accessibility"
import "modus:contract/date"
import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/module"
import "modus:contract/reference_screen"
import "modus:contract/ring"
import "modus:contract/scale_factor"
import "modus:contract/value_kinds"
import "modus:display"
import "modus:graphics"
import "modus:interface"
import "modus:system"

// The size of the window at its start, its least size, and its largest:
// the logical screen of the reference screen (src/md/features/window_resize.md).
WIDTH :: 720
HEIGHT :: 560
LEAST_WIDTH :: 480
LEAST_HEIGHT :: 420
LARGEST_WIDTH :: 1536
LARGEST_HEIGHT :: 864

// The tool counts the two pictures of the window at its largest size. A
// resize holds the old surface and the new one together until the
// compositor shows the new one, so the working memory holds a second
// surface at the largest size: 1536 x 864 logical pixels at the largest
// scale, cut on each axis to the reference screen as the tool counts it
// (src/md/features/desktop_to_browser.md, "The budgets"), are 1920 x 1080
// pixels, 4 bytes each, two pictures: 4050 pages. It also holds the least
// budget of 2048 pages less a window of 480 x 320 (300 pages): 1748 pages
// for its stack, its tables and the glyphs that it draws itself. And the
// glyph memory of the copy of the text rendering of the drawing module:
// 354 pages (display.TEXT_MEMORY_PAGES). 4050 + 1748 + 354 = 6152.
// The worker thread of the notification has a stack of 64 pages, 48 more
// than the tool counts for a thread. 6152 + 48 = 6200. The tool reads the
// literal; the check below ties it to these parts.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 6200, processes = 1, threads = 2, window_width = LARGEST_WIDTH, window_height = LARGEST_HEIGHT, window_least_width = LEAST_WIDTH, window_least_height = LEAST_HEIGHT}

// The rule of the tool (scale_factor.window_surface_largest), from the same
// constants: a constant cannot call the procedure. The cut holds because
// the window is resizable with a least size within the logical screen at
// the largest scale: the budget states that least size, and the tool checks
// it against the call of resizable_set.
#assert(LEAST_WIDTH > 0 && LEAST_HEIGHT > 0 && LEAST_WIDTH <= scale_factor.LARGEST_LOGICAL_WIDTH && LEAST_HEIGHT <= scale_factor.LARGEST_LOGICAL_HEIGHT)
WINDOW_SCREEN_WIDTH :: min((u64(LARGEST_WIDTH) * u64(scale_factor.LARGEST) + scale_factor.EIGHTHS_OF_ONE / 2) / scale_factor.EIGHTHS_OF_ONE, u64(reference_screen.WIDTH))
WINDOW_SCREEN_HEIGHT :: min((u64(LARGEST_HEIGHT) * u64(scale_factor.LARGEST) + scale_factor.EIGHTHS_OF_ONE / 2) / scale_factor.EIGHTHS_OF_ONE, u64(reference_screen.HEIGHT))
SECOND_SURFACE_PAGES :: (2 * WINDOW_SCREEN_WIDTH * WINDOW_SCREEN_HEIGHT * 4 + system.PAGE_SIZE - 1) / system.PAGE_SIZE
#assert(MODULE_BUDGET.working_memory_pages == SECOND_SURFACE_PAGES + 1748 + display.TEXT_MEMORY_PAGES + 48)

MARGIN :: graphics.MARGIN
GAP :: graphics.GAP
BUTTON_HEIGHT :: 28
TAB_WIDTH :: 120
// The waits while a stopwatch or a timer runs and is shown: the tenths of
// a second move.
RUNNING_FRAME_MILLISECONDS :: 50
// The largest digits: the bound of a text record.
DIGITS_SIZE_LIMIT :: 128
DIGITS_SIZE_LEAST :: 32

Section :: enum u8 {
	Clock     = 0,
	Stopwatch = 1,
	Timer     = 2,
}

@(rodata)
SECTION_NAMES := [Section]string {
	.Clock     = "Clock",
	.Stopwatch = "Stopwatch",
	.Timer     = "Timer",
}

// The memory of the interface package for the window (docs/INTERFACE.md).
window_memory: interface.Window_Memory(512, 8192)

section: Section
watch: clock_model.Stopwatch
timer: clock_model.Timer
date_page: ^date.Page
// The month that the calendar shows. A zero year follows the month of
// today, so the calendar moves at midnight of the last day of a month.
calendar_year: i64
calendar_month: int

// The notification at the end of the timer: a job of the worker thread of
// the window asks the root service for a connection to the compositor once,
// at the first end, keeps it, and calls notify
// (src/md/features/background_work.md). The notifier belongs to the job.
work: interface.Background_Work
// An end that waits for the worker: a job of an earlier end still runs.
notification_due: bool
// The duration of the timer at its last end, kept by the window.
ended_duration: u64
// The duration that the job writes on its card: the job owns it from the
// ask to the take.
notification_duration: u64
Notifier :: struct {
	tried:      bool,
	connected:  bool,
	requests:   ring.Ring,
	connection: system.Call_Connection,
	file:       []u8, // The module file of the compositor, in the boot image.
	export:     u32, // The export notify.
}
notifier: Notifier
process_context: ^system.Context

// notifier_open asks for the connection to the compositor and finds its
// export notify in the boot image. cause says why there is none.
notifier_open :: proc "contextless" () -> (cause: string) {
	ctx := process_context
	if ctx.handles[system.GRANT_IMAGE] == 0 {
		return "this process has no boot image"
	}
	address, mapped := system.memory_map(ctx.handles[system.GRANT_IMAGE], {})
	if mapped != .Ok {
		return "the boot image does not map"
	}
	image := ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	notifier.file = system.image_find(image, "compositor")
	if notifier.file == nil {
		return "the boot image has no module compositor"
	}
	notifier.export = module.export_find(notifier.file, "notify")
	if notifier.export == 0 {
		return "the compositor has no export notify"
	}
	if ctx.handles[system.GRANT_ROOT] == 0 {
		return "this process has no ring to the root service"
	}
	opened: system.Status
	notifier.requests, opened = system.ring_open(ctx.handles[system.GRANT_ROOT], receive_handles = true)
	if opened != .Ok {
		return "the ring to the root service does not open"
	}
	connected: call_outcome.Call_Outcome
	notifier.connection, connected = system.service_connection(&notifier.requests, 1, "compositor")
	if connected != .Succeeded {
		return "the root service gave no connection to the compositor"
	}
	notifier.connected = true
	return ""
}

// notification_job asks the compositor for a desktop notification, on the
// worker thread: the connection and the call wait for other processes. The
// window shows the end in each case.
notification_job :: proc "contextless" (parameter: rawptr) {
	if !notifier.tried {
		notifier.tried = true
		if cause := notifier_open(); cause != "" {
			system.log_fact(.Warning, Notification_Not_Connected{cause = value_kinds.text_field(cause, 80)})
		}
	}
	if !notifier.connected {
		return
	}
	room: clock_model.Text_Room
	title := "The timer ended"
	body := clock_model.remaining_text(&room, notification_duration)
	arguments: [2]isolated.Argument
	arguments[0].text = transmute([]u8)title
	arguments[1].text = transmute([]u8)body
	error: errors.Error_Record
	result, outcome := system.call_isolated(&notifier.connection, notifier.file, notifier.export, arguments[:], &error)
	if outcome == .Succeeded {
		system.log_fact(.Info, Notification_Posted{identifier = u64(result)})
	} else {
		system.log_fact(.Warning, Notification_Refused(errors.error_record_fact_fields(error)))
	}
}

// digits_font gives the font of the large digits that fit a width of
// cells cells and a height: each cell of the font of the cells is half
// its size wide, so the digits never move when one changes.
digits_font :: proc "contextless" (width, height, cells: int) -> interface.Font {
	size := clamp(min(2 * width / max(cells, 1), height), DIGITS_SIZE_LEAST, DIGITS_SIZE_LIMIT)
	return interface.Font{size = u16(size * interface.TEXT_SIZE_UNITS)}
}

// text_centered draws a text in the middle of an area, across, at its top.
text_centered :: proc "contextless" (frame: ^interface.Frame, area: interface.Area, text: string, color: graphics.Color, font: interface.Font) {
	width := interface.text_measured_width(frame.table, font, text)
	interface.draw_text(frame.table, area.x + max((area.width - width) / 2, 0), area.y, text, color, font)
}

// buttons_row draws the buttons whose label is not empty, of one width,
// from the left of an area, and gives the index of the one that the
// principal activated, or -1.
buttons_row :: proc "contextless" (frame: ^interface.Frame, area: interface.Area, labels: []string, width: int) -> int {
	activated := -1
	x := area.x
	for label, index in labels {
		if label == "" {
			continue
		}
		box := interface.Area{x, area.y, width, BUTTON_HEIGHT}
		if interface.button(frame, box, interface.identity(label), label).activated {
			activated = index
		}
		x += width + GAP
	}
	return activated
}

// buttons_row_width gives the width of the buttons whose label is not
// empty, with their gaps.
buttons_row_width :: proc "contextless" (labels: []string, width: int) -> int {
	shown := 0
	for label in labels {
		shown += label != "" ? 1 : 0
	}
	return max(shown * width + (shown - 1) * GAP, 0)
}

// calendar_month_shown gives the month of today, or the month that the
// principal chose.
calendar_month_shown :: proc "contextless" (today: calendar.Civil) -> (year: i64, month: int) {
	if calendar_year == 0 {
		return today.year, today.month
	}
	return calendar_year, calendar_month
}

// calendar_move moves the calendar by a count of months; a month out of
// the range of the calendar keeps the month shown.
calendar_move :: proc "contextless" (today: calendar.Civil, step: int) {
	year, month := calendar_month_shown(today)
	if new_year, new_month, ok := clock_model.month_step(year, month, step); ok {
		calendar_year, calendar_month = new_year, new_month
	}
	if calendar_year == today.year && calendar_month == today.month {
		calendar_year = 0
	}
}

@(rodata)
WEEKDAY_HEADS := [7]string{"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"}

// calendar_draw draws the month: its title with its buttons, the heads of
// the days, and a cell for each day; today is in the chosen blue.
calendar_draw :: proc "contextless" (frame: ^interface.Frame, area: interface.Area, today: calendar.Civil) {
	year, month := calendar_month_shown(today)
	grid, ok := clock_model.month_grid(year, month)
	if !ok {
		return
	}
	title: clock_model.Text_Room
	interface.draw_text(frame.table, area.x, area.y + (BUTTON_HEIGHT - interface.LINE) / 2, clock_model.month_title_text(&title, year, month), graphics.colors.text, interface.FONT_INTERFACE_BOLD)
	// The button today shows only away from the month of today.
	labels := [3]string{"Previous", calendar_year == 0 ? "" : "Today", "Next"}
	BUTTON_WIDTH :: 88
	row_width := buttons_row_width(labels[:], BUTTON_WIDTH)
	switch buttons_row(frame, {area.x + area.width - row_width, area.y, row_width, BUTTON_HEIGHT}, labels[:], BUTTON_WIDTH) {
	case 0:
		calendar_move(today, -1)
	case 1:
		calendar_year = 0
	case 2:
		calendar_move(today, 1)
	}
	top := area.y + BUTTON_HEIGHT + GAP
	cell_width := min(area.width / clock_model.WEEK_DAYS, 96)
	rest := area.height - (top - area.y) - interface.TABLE_LINE
	cell_height := clamp(rest / clock_model.MONTH_ROWS_LIMIT, interface.TABLE_LINE, 64)
	left := area.x + (area.width - cell_width * clock_model.WEEK_DAYS) / 2
	for head, column in WEEKDAY_HEADS {
		interface.cell_text(frame, {left + column * cell_width + 6, top, cell_width - 8, interface.TABLE_LINE}, head, graphics.colors.dim)
	}
	top += interface.TABLE_LINE
	is_today_month := year == today.year && month == today.month
	for row_index in 0 ..< grid.row_count {
		for column in 0 ..< clock_model.WEEK_DAYS {
			day, has_day := clock_model.month_grid_day(grid, row_index, column)
			if !has_day {
				continue
			}
			x, y := left + column * cell_width, top + row_index * cell_height
			today_cell := is_today_month && day == today.day
			interface.draw_rectangle(frame.table, x, y, cell_width - 2, cell_height - 2, today_cell ? graphics.colors.chosen : graphics.colors.track)
			number: clock_model.Text_Room
			clock_model.text_put_digits(&number, u64(day), 1)
			interface.draw_text(frame.table, x + 6, y + 4, clock_model.text_of(&number), today_cell ? graphics.COLOR_WHITE : graphics.colors.text)
		}
	}
}

// clock_section draws the local time, the date and the calendar.
clock_section :: proc "contextless" (frame: ^interface.Frame, area: interface.Area, milliseconds: i64, known: bool, zone: i64) {
	if !known {
		interface.cell_text(frame, {area.x, area.y, area.width, interface.LINE}, "The system has no date: the date page is absent or holds no date.", graphics.colors.dim)
		return
	}
	today := clock_model.local_civil(milliseconds, zone)
	font := digits_font(area.width, area.height / 4, 8)
	room: clock_model.Text_Room
	text_centered(frame, area, clock_model.time_of_day_text(&room, today), graphics.colors.text_strong, font)
	y := area.y + interface.line_height(font) + GAP
	text_centered(frame, {area.x, y, area.width, interface.LINE}, clock_model.date_text(&room, today, zone), graphics.colors.dim, interface.FONT_INTERFACE)
	y += interface.LINE + 2 * MARGIN
	calendar_draw(frame, {area.x, y, area.width, area.y + area.height - y}, today)
}

// stopwatch_section draws the elapsed time, its buttons and the laps.
stopwatch_section :: proc "contextless" (frame: ^interface.Frame, area: interface.Area, now: u64) {
	font := digits_font(area.width, area.height / 4, 9)
	room: clock_model.Text_Room
	text_centered(frame, area, clock_model.elapsed_text(&room, clock_model.stopwatch_elapsed(&watch, now)), graphics.colors.text_strong, font)
	y := area.y + interface.line_height(font) + MARGIN
	// Only the acts that the state takes have a button.
	labels: [3]string
	switch watch.state {
	case .Running:
		labels = {"Stop", watch.lap_count < clock_model.LAP_CAPACITY ? "Lap" : "", ""}
	case .Stopped:
		labels = {"Start", "", watch.elapsed_of_runs > 0 || watch.lap_count > 0 ? "Reset" : ""}
	}
	BUTTON_WIDTH :: 104
	row_width := buttons_row_width(labels[:], BUTTON_WIDTH)
	switch buttons_row(frame, {area.x + (area.width - row_width) / 2, y, row_width, BUTTON_HEIGHT}, labels[:], BUTTON_WIDTH) {
	case 0:
		stopwatch_toggle_told(now)
	case 1:
		clock_model.stopwatch_lap(&watch, now)
	case 2:
		clock_model.stopwatch_reset(&watch)
	}
	y += BUTTON_HEIGHT + MARGIN
	if watch.lap_count == 0 {
		return
	}
	cells: [3]interface.Area
	sizes := [3]interface.Size{interface.characters(8), interface.share(), interface.share()}
	table_width := min(area.width, 480)
	table_x := area.x + (area.width - table_width) / 2
	interface.row_split({table_x, y, table_width, interface.TABLE_LINE}, sizes[:], cells[:], 16)
	interface.table_header(frame, cells[:], {"Lap", "Lap time", "Total"}, {.Left, .Right, .Right})
	y += interface.TABLE_LINE
	band := 0
	for index := watch.lap_count - 1; index >= 0 && y + interface.TABLE_LINE <= area.y + area.height; index -= 1 {
		own, total, ok := clock_model.stopwatch_lap_times(&watch, index)
		if !ok {
			continue
		}
		line := interface.Area{table_x, y, table_width, interface.TABLE_LINE}
		interface.table_band(frame, line, band)
		interface.row_split(line, sizes[:], cells[:], 16)
		number, own_text, total_text: clock_model.Text_Room
		clock_model.text_put_digits(&number, u64(index + 1), 1)
		interface.cell_text(frame, cells[0], clock_model.text_of(&number), graphics.colors.dim)
		interface.cell_text(frame, cells[1], clock_model.elapsed_text(&own_text, own), graphics.colors.text, .Right)
		interface.cell_text(frame, cells[2], clock_model.elapsed_text(&total_text, total), graphics.colors.text, .Right)
		y += interface.TABLE_LINE
		band += 1
	}
}

// stopwatch_toggle_told starts or stops the stopwatch, and writes the
// change on the log: a machine test waits for it.
stopwatch_toggle_told :: proc "contextless" (now: u64) {
	clock_model.stopwatch_toggle(&watch, now)
	switch watch.state {
	case .Running:
		system.log_fact(.Info, Stopwatch_Started{})
	case .Stopped:
		system.log_fact(.Info, Stopwatch_Stopped{elapsed_milliseconds = watch.elapsed_of_runs})
	}
}

@(rodata)
DURATION_STEPS := [4]i64{-60_000, -10_000, 10_000, 60_000}
@(rodata)
DURATION_PRESETS := [4]u64{60_000, 300_000, 600_000, 1_500_000}

// timer_section draws the time left, the bar of the part left, the buttons,
// and, for a ready timer, the steps and the presets of the duration.
timer_section :: proc "contextless" (frame: ^interface.Frame, area: interface.Area, now: u64) {
	font := digits_font(area.width, area.height / 4, 8)
	room: clock_model.Text_Room
	ended := timer.state == .Ended
	text_centered(frame, area, clock_model.remaining_text(&room, clock_model.timer_remaining(&timer, now)), ended ? graphics.colors.warning : graphics.colors.text_strong, font)
	y := area.y + interface.line_height(font) + GAP
	// The part of the duration that is left, as a rectangular bar.
	BAR_HEIGHT :: 8
	bar_width := min(area.width, 560)
	bar_x := area.x + (area.width - bar_width) / 2
	interface.draw_rectangle(frame.table, bar_x, y, bar_width, BAR_HEIGHT, graphics.colors.track)
	filled := int(u64(bar_width) * clock_model.timer_left_in_millionths(&timer, now) / 1_000_000)
	if filled > 0 {
		interface.draw_rectangle(frame.table, bar_x, y, filled, BAR_HEIGHT, graphics.colors.chosen)
	}
	y += BAR_HEIGHT + MARGIN
	if ended {
		text_centered(frame, {area.x, y, area.width, interface.LINE}, "The timer ended.", graphics.colors.warning, interface.FONT_INTERFACE)
		y += interface.LINE + MARGIN
	}
	labels: [2]string
	switch timer.state {
	case .Ready:
		labels = {"Start", ""}
	case .Running:
		labels = {"Pause", "Reset"}
	case .Paused:
		labels = {"Resume", "Reset"}
	case .Ended:
		labels = {"", "Reset"}
	}
	BUTTON_WIDTH :: 104
	row_width := buttons_row_width(labels[:], BUTTON_WIDTH)
	switch buttons_row(frame, {area.x + (area.width - row_width) / 2, y, row_width, BUTTON_HEIGHT}, labels[:], BUTTON_WIDTH) {
	case 0:
		clock_model.timer_toggle(&timer, now)
	case 1:
		clock_model.timer_reset(&timer)
	}
	if timer.state != .Ready {
		return
	}
	y += BUTTON_HEIGHT + MARGIN
	step_labels := [4]string{"-1 min", "-10 s", "+10 s", "+1 min"}
	STEP_WIDTH :: 80
	steps_width := buttons_row_width(step_labels[:], STEP_WIDTH)
	if chosen := buttons_row(frame, {area.x + (area.width - steps_width) / 2, y, steps_width, BUTTON_HEIGHT}, step_labels[:], STEP_WIDTH); chosen >= 0 {
		clock_model.timer_duration_change(&timer, DURATION_STEPS[chosen])
	}
	y += BUTTON_HEIGHT + GAP
	preset_labels := [4]string{"1 min", "5 min", "10 min", "25 min"}
	if chosen := buttons_row(frame, {area.x + (area.width - steps_width) / 2, y, steps_width, BUTTON_HEIGHT}, preset_labels[:], STEP_WIDTH); chosen >= 0 {
		clock_model.timer_duration_set(&timer, DURATION_PRESETS[chosen])
	}
}

// keys_run runs the keys of a frame that no element took.
keys_run :: proc "contextless" (frame: ^interface.Frame, now: u64, today: calendar.Civil, known: bool) {
	for {
		key := interface.key_take(frame) or_break
		switch key.character {
		case '1':
			section = .Clock
			continue
		case '2':
			section = .Stopwatch
			continue
		case '3':
			section = .Timer
			continue
		}
		switch section {
		case .Clock:
			if !known {
				continue
			}
			switch key.code {
			case display.KEY_PAGE_UP:
				calendar_move(today, -1)
			case display.KEY_PAGE_DOWN:
				calendar_move(today, 1)
			case display.KEY_HOME:
				calendar_year = 0
			}
		case .Stopwatch:
			switch key.character {
			case ' ':
				stopwatch_toggle_told(now)
			case 'l', 'L':
				clock_model.stopwatch_lap(&watch, now)
			case 'r', 'R':
				clock_model.stopwatch_reset(&watch)
			}
		case .Timer:
			switch key.character {
			case ' ':
				clock_model.timer_toggle(&timer, now)
			case 'r', 'R':
				clock_model.timer_reset(&timer)
			case '+', '=':
				clock_model.timer_duration_change(&timer, 60_000)
			case '-':
				clock_model.timer_duration_change(&timer, -60_000)
			}
		}
	}
}

// draw builds one frame: the tabs, then the section that is chosen.
draw :: proc "contextless" (window: ^display.Window, now: u64, milliseconds: i64, known: bool, zone: i64) {
	frame := interface.window_frame_start(&window_memory, window)
	width, height := window.width, window.height
	interface.background(&frame, {0, 0, width, height})
	x := MARGIN
	for name, chosen in SECTION_NAMES {
		toggle := chosen == section ? accessibility.Toggle_State.True : accessibility.Toggle_State.False
		if interface.button(&frame, {x, MARGIN, TAB_WIDTH, BUTTON_HEIGHT}, interface.identity(name), name, chosen == section, toggle).activated {
			section = chosen
		}
		x += TAB_WIDTH + GAP
	}
	interface.draw_rectangle(frame.table, MARGIN, MARGIN + BUTTON_HEIGHT + GAP, width - 2 * MARGIN, 1, graphics.colors.track)
	top := MARGIN + BUTTON_HEIGHT + 2 * MARGIN
	content := interface.Area{MARGIN, top, width - 2 * MARGIN, height - top - MARGIN}
	today := known ? clock_model.local_civil(milliseconds, zone) : calendar.Civil{}
	switch section {
	case .Clock:
		clock_section(&frame, content, milliseconds, known, zone)
	case .Stopwatch:
		stopwatch_section(&frame, content, now)
	case .Timer:
		timer_section(&frame, content, now)
	}
	keys_run(&frame, now, today, known)
	interface.window_frame_end(&window_memory.drawing, &frame, window)
}

// next_wake gives the time of the system at which the window must draw
// again with no event: the next second of the local time, every
// RUNNING_FRAME_MILLISECONDS while a running stopwatch or timer is shown,
// and the end of a running timer.
next_wake :: proc "contextless" (now: u64, milliseconds: i64, known: bool) -> u64 {
	wake := now + (known ? clock_model.milliseconds_to_next_second(milliseconds) : 1000)
	if section == .Stopwatch && watch.state == .Running {
		wake = min(wake, now + RUNNING_FRAME_MILLISECONDS)
	}
	if timer.state == .Running {
		if section == .Timer {
			wake = min(wake, now + RUNNING_FRAME_MILLISECONDS)
		}
		wake = min(wake, max(timer.ends_at, now))
	}
	return wake
}

// The entry of clock: it opens its window, then draws a frame at each
// event and at each wake of next_wake. It never returns; with no window,
// it stops with Failed.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	process_context = ctx
	window, ok := display.open(ctx, WIDTH, HEIGHT, "clock")
	if !ok {
		system.stop(.Failed)
	}
	// The limits are constants of this process: a refusal is a fault of
	// this source, which the line says. The ring holds the one record of
	// the surface: a full ring is a fault of the compositor.
	if problem, sent := display.resizable_set(&window, {least_width = LEAST_WIDTH, least_height = LEAST_HEIGHT, largest_width = LARGEST_WIDTH, largest_height = LARGEST_HEIGHT}); problem != .None {
		system.log_fact(.Info, Window_Stays_Fixed{cause = value_kinds.text_field(display.SIZE_LIMITS_PROBLEM_SENTENCES[problem], 64)})
	} else if !sent {
		system.log_fact(.Info, Window_Stays_Fixed{cause = value_kinds.text_field("the command ring of the window is full", 64)})
	}
	date_page = date.page_of(ctx)
	timer = clock_model.timer_make()
	if interface.background_work_start(&work) != .Ok {
		// No worker: the window shows the end of a timer, and no card.
		notifier.tried = true
		system.log_fact(.Warning, Notification_Not_Connected{cause = value_kinds.text_field("the worker thread of the window did not start", 80)})
	}
	first := true
	no_date_told := false
	for {
		now := system.time()
		milliseconds, known := date.milliseconds_now(date_page, now)
		zone := date.zone_offset_seconds_read(date_page)
		if !known && !no_date_told {
			no_date_told = true
			system.log_fact(.Info, No_Date{})
		}
		// The frame that sees the end ends the timer, also after a long
		// sleep: the end is told once.
		if clock_model.timer_step(&timer, now) {
			system.log_fact(.Info, Timer_Ended{duration_seconds = timer.duration / 1000})
			// The duration of this end: a reset and a new duration before
			// the job is asked do not change the text of its card.
			notification_due = true
			ended_duration = timer.duration
		}
		// The job of an earlier end is taken first; an end waits for it.
		interface.background_work_take(&work)
		if notification_due && work.started && !interface.background_work_busy(&work) {
			notification_duration = ended_duration
			notification_due = !interface.background_work_ask(&work, notification_job, nil)
		}
		draw(&window, now, milliseconds, known, zone)
		if first {
			first = false
			system.log_fact(.Info, First_Frame_Drawn{})
		}
		wait: system.Wait
		display.wait_events(&wait, &window)
		ready := interface.background_work_wait(&wait, &work)
		system.wait_end(&wait, ready ? now : next_wake(now, milliseconds, known))
		interface.window_events(&window_memory.drawing, &window)
	}
}
