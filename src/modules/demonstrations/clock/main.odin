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
import "modus:layout"
import "modus:system"

// The size of the window at its start, its least size, and its largest:
// the logical screen of the reference screen (src/md/features/window_resize.md).
WIDTH :: 720
HEIGHT :: 560
LEAST_WIDTH :: 480
LEAST_HEIGHT :: 420
LARGEST_WIDTH :: 1536
LARGEST_HEIGHT :: 864

// The tool counts the module, the thread stacks and the two pictures of the
// window at its largest size (4050 pages, cut on each axis to the reference
// screen as the tool counts it). The working memory of the floor holds the
// glyph memory of both copies of text rendering (2 x 354 = 708 pages), the
// worker stack past the default stack (48 pages) and 268 pages for tables
// and mappings: 1024 pages. During a resize after ready, the second surface
// (4050 pages) draws from the growth factor of the budget. The tool reads
// the literal; the checks below tie it to these parts.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 1024, processes = 1, threads = 2, window_width = LARGEST_WIDTH, window_height = LARGEST_HEIGHT, window_least_width = LEAST_WIDTH, window_least_height = LEAST_HEIGHT}

// The rule of the tool (scale_factor.window_surface_largest), from the same
// constants: a constant cannot call the procedure. The cut holds because
// the window is resizable with a least size within the logical screen at
// the largest scale: the budget states that least size, and the tool checks
// it against the call of resizable_set.
#assert(LEAST_WIDTH > 0 && LEAST_HEIGHT > 0 && LEAST_WIDTH <= scale_factor.LARGEST_LOGICAL_WIDTH && LEAST_HEIGHT <= scale_factor.LARGEST_LOGICAL_HEIGHT)
WINDOW_SCREEN_WIDTH :: min((u64(LARGEST_WIDTH) * u64(scale_factor.LARGEST) + scale_factor.EIGHTHS_OF_ONE / 2) / scale_factor.EIGHTHS_OF_ONE, u64(reference_screen.WIDTH))
WINDOW_SCREEN_HEIGHT :: min((u64(LARGEST_HEIGHT) * u64(scale_factor.LARGEST) + scale_factor.EIGHTHS_OF_ONE / 2) / scale_factor.EIGHTHS_OF_ONE, u64(reference_screen.HEIGHT))
SECOND_SURFACE_PAGES :: (2 * WINDOW_SCREEN_WIDTH * WINDOW_SCREEN_HEIGHT * 4 + system.PAGE_SIZE - 1) / system.PAGE_SIZE
#assert(MODULE_BUDGET.working_memory_pages == 268 + 2 * display.TEXT_MEMORY_PAGES + 48)
#assert(2 * (SECOND_SURFACE_PAGES + MODULE_BUDGET.working_memory_pages) >= 2 * SECOND_SURFACE_PAGES + 2 * display.TEXT_MEMORY_PAGES + 48)

MARGIN :: graphics.MARGIN
GAP :: graphics.GAP
BUTTON_HEIGHT :: 28
TAB_WIDTH :: 120
// Minimum pane bounds so the tab strip, digits, buttons, and calendar fit
// without overlap or clipped text at the smallest resizable window size.
#assert(LEAST_WIDTH >= 2 * MARGIN + 3 * TAB_WIDTH + 2 * GAP)
#assert(LEAST_HEIGHT >= 3 * MARGIN + BUTTON_HEIGHT + GAP + 1 + DIGITS_SIZE_LEAST + 2 * BUTTON_HEIGHT + 4 * interface.TABLE_LINE)
// The waits while a stopwatch or a timer runs and is shown: the tenths of
// a second move.
RUNNING_FRAME_MILLISECONDS :: 50
// The largest digits: the bound of a text record.
DIGITS_SIZE_LIMIT :: 128
DIGITS_SIZE_LEAST :: 32

// The layout tree of one frame (modus:layout). Lives in module memory, never on stack.
clock_layout_tree: layout.Box_Tree
clock_tokens: layout.Element_Tokens

Clock_Places :: struct {
	tabs:    [Section]interface.Area,
	divider: interface.Area,
	content: interface.Area,
}

Clock_Section_Places :: struct {
	digits:       interface.Area,
	date:         interface.Area,
	cal_header:   interface.Area,
	cal_buttons:  interface.Area,
	cal_weekdays: interface.Area,
	cal_grid:     interface.Area,
}

Stopwatch_Section_Places :: struct {
	digits:       interface.Area,
	buttons:      interface.Area,
	table_header: interface.Area,
	table_rows:   interface.Area,
	columns:      [3]layout.Table_Column_Place,
}

Timer_Section_Places :: struct {
	digits:  interface.Area,
	bar:     interface.Area,
	ended:   interface.Area,
	actions: interface.Area,
	steps:   interface.Area,
	presets: interface.Area,
}

@(private)
area_of :: proc "contextless" (tree: ^layout.Box_Tree, index: layout.Box_Index) -> interface.Area {
	box := layout.box_of(tree, index)
	if box == nil {
		return {}
	}
	return {int(box.rect.x), int(box.rect.y), int(box.rect.width), int(box.rect.height)}
}

// clock_window_layout computes the top-level tab strip, divider, and section
// content area with modus:layout.
clock_window_layout :: proc "contextless" (tree: ^layout.Box_Tree, width, height: int, tokens: layout.Element_Tokens) -> (places: Clock_Places, ok: bool) {
	if tree == nil || width <= 0 || height <= 0 || width > layout.LENGTH_LIMIT || height > layout.LENGTH_LIMIT {
		return {}, false
	}
	if layout.tree_begin(tree, i32(width), i32(height), {child_axis = .Y, padding = {.X = tokens.margin, .Y = tokens.margin}, gap = tokens.gap}) != .Done {
		return {}, false
	}
	tab_boxes: [Section]layout.Box_Index
	if _, st := layout.box_open(tree, {size = {.X = layout.fill(), .Y = layout.px(BUTTON_HEIGHT)}, child_axis = .X, gap = tokens.gap}); st != .Done {
		return {}, false
	}
	for chosen in Section {
		st: layout.Box_Status
		tab_boxes[chosen], st = layout.box_add(tree, {size = {.X = layout.px(TAB_WIDTH), .Y = layout.fill()}})
		if st != .Done {
			return {}, false
		}
	}
	if layout.box_close(tree) != .Done {
		return {}, false
	}
	div_box, div_st := layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.px(1)}})
	if div_st != .Done {
		return {}, false
	}
	if _, sp_st := layout.box_add(tree, {size = {.X = layout.px(0), .Y = layout.px(tokens.gap)}}); sp_st != .Done {
		return {}, false
	}
	content_box, content_st := layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.fill()}})
	if content_st != .Done {
		return {}, false
	}
	if layout.solve(tree) != .Done {
		return {}, false
	}
	for chosen in Section {
		places.tabs[chosen] = area_of(tree, tab_boxes[chosen])
	}
	places.divider = area_of(tree, div_box)
	places.content = area_of(tree, content_box)
	return places, true
}

// clock_section_layout places the digits, date, calendar header, weekdays, and grid.
clock_section_layout :: proc "contextless" (tree: ^layout.Box_Tree, content: interface.Area, digits_height, buttons_width: int, tokens: layout.Element_Tokens) -> (places: Clock_Section_Places, ok: bool) {
	if tree == nil || content.width <= 0 || content.height <= 0 || content.width > layout.LENGTH_LIMIT || content.height > layout.LENGTH_LIMIT {
		return {}, false
	}
	if layout.tree_begin(tree, i32(content.width), i32(content.height), {child_axis = .Y, gap = tokens.gap}) != .Done {
		return {}, false
	}
	digits_box, s1 := layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.px(i32(max(digits_height, 1)))}})
	date_box, s2 := layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.px(interface.LINE)}})
	_, s3 := layout.box_add(tree, {size = {.X = layout.px(0), .Y = layout.px(tokens.margin)}})
	cal_hdr_row, s4 := layout.box_open(tree, {size = {.X = layout.fill(), .Y = layout.px(BUTTON_HEIGHT)}, child_axis = .X, gap = tokens.gap})
	_, s5 := layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.fill()}})
	cal_btns, s6 := layout.box_add(tree, {size = {.X = layout.px(i32(clamp(buttons_width, 0, content.width))), .Y = layout.fill()}})
	s7 := layout.box_close(tree)
	cal_wk, s8 := layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.px(interface.TABLE_LINE)}})
	cal_grid, s9 := layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.fill()}})
	if s1 != .Done || s2 != .Done || s3 != .Done || s4 != .Done || s5 != .Done || s6 != .Done || s7 != .Done || s8 != .Done || s9 != .Done || layout.solve(tree) != .Done {
		return {}, false
	}
	shift :: proc "contextless" (a: interface.Area, ox, oy: int) -> interface.Area {
		return {a.x + ox, a.y + oy, a.width, a.height}
	}
	places.digits = shift(area_of(tree, digits_box), content.x, content.y)
	places.date = shift(area_of(tree, date_box), content.x, content.y)
	places.cal_header = shift(area_of(tree, cal_hdr_row), content.x, content.y)
	places.cal_buttons = shift(area_of(tree, cal_btns), content.x, content.y)
	places.cal_weekdays = shift(area_of(tree, cal_wk), content.x, content.y)
	places.cal_grid = shift(area_of(tree, cal_grid), content.x, content.y)
	return places, true
}

// stopwatch_section_layout places the digits, action buttons, and laps table.
stopwatch_section_layout :: proc "contextless" (tree: ^layout.Box_Tree, content: interface.Area, digits_height, buttons_width: int, tokens: layout.Element_Tokens) -> (places: Stopwatch_Section_Places, ok: bool) {
	if tree == nil || content.width <= 0 || content.height <= 0 || content.width > layout.LENGTH_LIMIT || content.height > layout.LENGTH_LIMIT {
		return {}, false
	}
	if layout.tree_begin(tree, i32(content.width), i32(content.height), {child_axis = .Y, cross_align = .Center, gap = tokens.margin}) != .Done {
		return {}, false
	}
	digits_box, s1 := layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.px(i32(max(digits_height, 1)))}})
	btns_box, s2 := layout.box_add(tree, {size = {.X = layout.px(i32(clamp(buttons_width, 0, content.width))), .Y = layout.px(BUTTON_HEIGHT)}})
	table_w := i32(min(content.width, 480))
	_, s3 := layout.box_open(tree, {size = {.X = layout.px(table_w), .Y = layout.fill()}, child_axis = .Y})
	hdr_box, s4 := layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.px(interface.TABLE_LINE)}})
	rows_box, s5 := layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.fill()}})
	s6 := layout.box_close(tree)
	if s1 != .Done || s2 != .Done || s3 != .Done || s4 != .Done || s5 != .Done || s6 != .Done || layout.solve(tree) != .Done {
		return {}, false
	}
	shift :: proc "contextless" (a: interface.Area, ox, oy: int) -> interface.Area {
		return {a.x + ox, a.y + oy, a.width, a.height}
	}
	places.digits = shift(area_of(tree, digits_box), content.x, content.y)
	places.buttons = shift(area_of(tree, btns_box), content.x, content.y)
	places.table_header = shift(area_of(tree, hdr_box), content.x, content.y)
	places.table_rows = shift(area_of(tree, rows_box), content.x, content.y)
	cols := [3]layout.Table_Column{
		{width = 8 * graphics.CELL_WIDTH},
		{weight = 1, least = 8 * graphics.CELL_WIDTH},
		{weight = 1, least = 8 * graphics.CELL_WIDTH},
	}
	hdr_rect := layout.Rect{i32(places.table_header.x), i32(places.table_header.y), i32(places.table_header.width), i32(places.table_header.height)}
	if layout.table_columns(cols[:], places.columns[:], hdr_rect, 0) != .Done {
		return {}, false
	}
	return places, true
}

// timer_section_layout places the digits, remaining bar, ended banner, actions,
// duration step buttons, and preset buttons.
timer_section_layout :: proc "contextless" (tree: ^layout.Box_Tree, content: interface.Area, digits_height, actions_width, steps_width: int, ended: bool, tokens: layout.Element_Tokens) -> (places: Timer_Section_Places, ok: bool) {
	if tree == nil || content.width <= 0 || content.height <= 0 || content.width > layout.LENGTH_LIMIT || content.height > layout.LENGTH_LIMIT {
		return {}, false
	}
	if layout.tree_begin(tree, i32(content.width), i32(content.height), {child_axis = .Y, cross_align = .Center, gap = tokens.gap}) != .Done {
		return {}, false
	}
	digits_box, s1 := layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.px(i32(max(digits_height, 1)))}})
	bar_box, s2 := layout.box_add(tree, {size = {.X = layout.px(i32(min(content.width, 560))), .Y = layout.px(8)}})
	ended_box: layout.Box_Index
	s3 := layout.Box_Status.Done
	if ended {
		ended_box, s3 = layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.px(interface.LINE)}})
	}
	actions_box, s4 := layout.box_add(tree, {size = {.X = layout.px(i32(clamp(actions_width, 0, content.width))), .Y = layout.px(BUTTON_HEIGHT)}})
	steps_box, s5 := layout.box_add(tree, {size = {.X = layout.px(i32(clamp(steps_width, 0, content.width))), .Y = layout.px(BUTTON_HEIGHT)}})
	presets_box, s6 := layout.box_add(tree, {size = {.X = layout.px(i32(clamp(steps_width, 0, content.width))), .Y = layout.px(BUTTON_HEIGHT)}})
	if s1 != .Done || s2 != .Done || s3 != .Done || s4 != .Done || s5 != .Done || s6 != .Done || layout.solve(tree) != .Done {
		return {}, false
	}
	shift :: proc "contextless" (a: interface.Area, ox, oy: int) -> interface.Area {
		return {a.x + ox, a.y + oy, a.width, a.height}
	}
	places.digits = shift(area_of(tree, digits_box), content.x, content.y)
	places.bar = shift(area_of(tree, bar_box), content.x, content.y)
	if ended {
		places.ended = shift(area_of(tree, ended_box), content.x, content.y)
	}
	places.actions = shift(area_of(tree, actions_box), content.x, content.y)
	places.steps = shift(area_of(tree, steps_box), content.x, content.y)
	places.presets = shift(area_of(tree, presets_box), content.x, content.y)
	return places, true
}

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
	if mapped != .Succeeded {
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
	opened: call_outcome.Call_Outcome
	notifier.requests, opened = system.ring_open(ctx.handles[system.GRANT_ROOT], receive_handles = true)
	if opened != .Succeeded {
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
//
// It is never inlined. Inlined into draw, its calendar grid loop raises the
// register pressure enough that LLVM schedules spills differently when debug
// instructions stand in the function, changing the module bytes with and
// without debug information (src/md/infrastructure/debug_information_and_code.md).
calendar_draw :: #force_no_inline proc "contextless" (frame: ^interface.Frame, places: Clock_Section_Places, today: calendar.Civil) {
	year, month := calendar_month_shown(today)
	grid, ok := clock_model.month_grid(year, month)
	if !ok {
		return
	}
	title: clock_model.Text_Room
	interface.draw_text(frame.table, places.cal_header.x, places.cal_header.y + (BUTTON_HEIGHT - interface.LINE) / 2, clock_model.month_title_text(&title, year, month), clock_tokens.text, interface.FONT_INTERFACE_BOLD)
	// The button today shows only away from the month of today.
	labels := [3]string{"Previous", calendar_year == 0 ? "" : "Today", "Next"}
	BUTTON_WIDTH :: 88
	switch buttons_row(frame, places.cal_buttons, labels[:], BUTTON_WIDTH) {
	case 0:
		calendar_move(today, -1)
	case 1:
		calendar_year = 0
	case 2:
		calendar_move(today, 1)
	}
	cell_width := min(places.cal_grid.width / clock_model.WEEK_DAYS, 96)
	cell_height := clamp(places.cal_grid.height / clock_model.MONTH_ROWS_LIMIT, interface.TABLE_LINE, 64)
	left := places.cal_grid.x + (places.cal_grid.width - cell_width * clock_model.WEEK_DAYS) / 2
	for head, column in WEEKDAY_HEADS {
		interface.cell_text(frame, {left + column * cell_width + 6, places.cal_weekdays.y, cell_width - 8, interface.TABLE_LINE}, head, clock_tokens.text_dim)
	}
	is_today_month := year == today.year && month == today.month
	for row_index in 0 ..< grid.row_count {
		for column in 0 ..< clock_model.WEEK_DAYS {
			day, has_day := clock_model.month_grid_day(grid, row_index, column)
			if !has_day {
				continue
			}
			x, y := left + column * cell_width, places.cal_grid.y + row_index * cell_height
			today_cell := is_today_month && day == today.day
			interface.draw_rectangle(frame.table, x, y, cell_width - 2, cell_height - 2, today_cell ? clock_tokens.surface_chosen : clock_tokens.surface_track)
			number: clock_model.Text_Room
			clock_model.text_put_digits(&number, u64(day), 1)
			interface.draw_text(frame.table, x + 6, y + 4, clock_model.text_of(&number), today_cell ? clock_tokens.text_on_chosen : clock_tokens.text)
		}
	}
}

// clock_section draws the local time, the date and the calendar.
clock_section :: proc "contextless" (frame: ^interface.Frame, area: interface.Area, milliseconds: i64, known: bool, zone: i64) {
	if !known {
		interface.cell_text(frame, {area.x, area.y, area.width, interface.LINE}, "The system has no date: the date page is absent or holds no date.", clock_tokens.text_dim)
		return
	}
	today := clock_model.local_civil(milliseconds, zone)
	font := digits_font(area.width, area.height / 4, 8)
	labels := [3]string{"Previous", calendar_year == 0 ? "" : "Today", "Next"}
	places, layout_ok := clock_section_layout(&clock_layout_tree, area, interface.line_height(font), buttons_row_width(labels[:], 88), clock_tokens)
	if !layout_ok {
		return
	}
	room: clock_model.Text_Room
	text_centered(frame, places.digits, clock_model.time_of_day_text(&room, today), clock_tokens.text_strong, font)
	text_centered(frame, places.date, clock_model.date_text(&room, today, zone), clock_tokens.text_dim, interface.FONT_INTERFACE)
	calendar_draw(frame, places, today)
}

// stopwatch_section draws the elapsed time, its buttons and the laps.
stopwatch_section :: proc "contextless" (frame: ^interface.Frame, area: interface.Area, now: u64) {
	font := digits_font(area.width, area.height / 4, 9)
	// Only the acts that the state takes have a button.
	labels: [3]string
	switch watch.state {
	case .Running:
		labels = {"Stop", watch.lap_count < clock_model.LAP_CAPACITY ? "Lap" : "", ""}
	case .Stopped:
		labels = {"Start", "", watch.elapsed_of_runs > 0 || watch.lap_count > 0 ? "Reset" : ""}
	}
	BUTTON_WIDTH :: 104
	places, layout_ok := stopwatch_section_layout(&clock_layout_tree, area, interface.line_height(font), buttons_row_width(labels[:], BUTTON_WIDTH), clock_tokens)
	if !layout_ok {
		return
	}
	room: clock_model.Text_Room
	text_centered(frame, places.digits, clock_model.elapsed_text(&room, clock_model.stopwatch_elapsed(&watch, now)), clock_tokens.text_strong, font)
	switch buttons_row(frame, places.buttons, labels[:], BUTTON_WIDTH) {
	case 0:
		stopwatch_toggle_told(now)
	case 1:
		clock_model.stopwatch_lap(&watch, now)
	case 2:
		clock_model.stopwatch_reset(&watch)
	}
	if watch.lap_count == 0 {
		return
	}
	header_cells := [3]interface.Area{
		{int(places.columns[0].x), places.table_header.y, int(places.columns[0].width), interface.TABLE_LINE},
		{int(places.columns[1].x), places.table_header.y, int(places.columns[1].width), interface.TABLE_LINE},
		{int(places.columns[2].x), places.table_header.y, int(places.columns[2].width), interface.TABLE_LINE},
	}
	interface.table_header(frame, header_cells[:], {"Lap", "Lap time", "Total"}, {.Left, .Right, .Right})
	y := places.table_rows.y
	band := 0
	for index := watch.lap_count - 1; index >= 0 && y + interface.TABLE_LINE <= places.table_rows.y + places.table_rows.height; index -= 1 {
		own, total, ok := clock_model.stopwatch_lap_times(&watch, index)
		if !ok {
			continue
		}
		line := interface.Area{places.table_rows.x, y, places.table_rows.width, interface.TABLE_LINE}
		interface.table_band(frame, line, band)
		cells := [3]interface.Area{
			{int(places.columns[0].x), y, int(places.columns[0].width), interface.TABLE_LINE},
			{int(places.columns[1].x), y, int(places.columns[1].width), interface.TABLE_LINE},
			{int(places.columns[2].x), y, int(places.columns[2].width), interface.TABLE_LINE},
		}
		number, own_text, total_text: clock_model.Text_Room
		clock_model.text_put_digits(&number, u64(index + 1), 1)
		interface.cell_text(frame, cells[0], clock_model.text_of(&number), clock_tokens.text_dim)
		interface.cell_text(frame, cells[1], clock_model.elapsed_text(&own_text, own), clock_tokens.text, .Right)
		interface.cell_text(frame, cells[2], clock_model.elapsed_text(&total_text, total), clock_tokens.text, .Right)
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
	ended := timer.state == .Ended
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
	STEP_WIDTH :: 80
	step_labels := [4]string{"-1 min", "-10 s", "+10 s", "+1 min"}
	places, layout_ok := timer_section_layout(&clock_layout_tree, area, interface.line_height(font), buttons_row_width(labels[:], BUTTON_WIDTH), buttons_row_width(step_labels[:], STEP_WIDTH), ended, clock_tokens)
	if !layout_ok {
		return
	}
	room: clock_model.Text_Room
	text_centered(frame, places.digits, clock_model.remaining_text(&room, clock_model.timer_remaining(&timer, now)), ended ? clock_tokens.warning : clock_tokens.text_strong, font)
	// The part of the duration that is left, as a rectangular bar.
	interface.draw_rectangle(frame.table, places.bar.x, places.bar.y, places.bar.width, places.bar.height, clock_tokens.surface_track)
	filled := int(u64(places.bar.width) * clock_model.timer_left_in_millionths(&timer, now) / 1_000_000)
	if filled > 0 {
		interface.draw_rectangle(frame.table, places.bar.x, places.bar.y, filled, places.bar.height, clock_tokens.surface_chosen)
	}
	if ended {
		text_centered(frame, places.ended, "The timer ended.", clock_tokens.warning, interface.FONT_INTERFACE)
	}
	switch buttons_row(frame, places.actions, labels[:], BUTTON_WIDTH) {
	case 0:
		clock_model.timer_toggle(&timer, now)
	case 1:
		clock_model.timer_reset(&timer)
	}
	if timer.state != .Ready {
		return
	}
	if chosen := buttons_row(frame, places.steps, step_labels[:], STEP_WIDTH); chosen >= 0 {
		clock_model.timer_duration_change(&timer, DURATION_STEPS[chosen])
	}
	preset_labels := [4]string{"1 min", "5 min", "10 min", "25 min"}
	if chosen := buttons_row(frame, places.presets, preset_labels[:], STEP_WIDTH); chosen >= 0 {
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
	clock_tokens, _ = layout.tokens_for(graphics.appearance, .Standard)
	width, height := window.width, window.height
	interface.background(&frame, {0, 0, width, height})
	places, layout_ok := clock_window_layout(&clock_layout_tree, width, height, clock_tokens)
	if layout_ok {
		for name, chosen in SECTION_NAMES {
			toggle := chosen == section ? accessibility.Toggle_State.True : accessibility.Toggle_State.False
			if interface.button(&frame, places.tabs[chosen], interface.identity(name), name, chosen == section, toggle).activated {
				section = chosen
			}
		}
		interface.draw_rectangle(frame.table, places.divider.x, places.divider.y, places.divider.width, places.divider.height, clock_tokens.surface_track)
		today := known ? clock_model.local_civil(milliseconds, zone) : calendar.Civil{}
		switch section {
		case .Clock:
			clock_section(&frame, places.content, milliseconds, known, zone)
		case .Stopwatch:
			stopwatch_section(&frame, places.content, now)
		case .Timer:
			timer_section(&frame, places.content, now)
		}
		keys_run(&frame, now, today, known)
	}
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
	if interface.background_work_start(&work) != .Succeeded {
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
