// The tray widgets (src/md/features/tray_widgets.md): the button of the
// control center, the button of the notifications and the clock of the
// bar, the card that each opens, the history of the notifications, and the
// grid of a month. The compositor draws and acts; these procedures hold
// the places and the rules, so a host test gives each edge.
package bar

import "modus:calendar"
import "modus:contract/enum_word"

// A tray widget: a card that a part of the tray opens. The words cross the
// border of the export tray_widget_open.
Tray_Widget :: enum u8 {
	None           = 0, // No card is open.
	Control_Center = 1, // The tiles of the desktop and the launch buttons.
	Notifications  = 2, // The history of the notifications.
	Calendar       = 3, // The month of today, opened by the clock.
}

// tray_widget_of_word gives the member of a word of the export. ok is false
// for a word that names no member.
tray_widget_of_word :: proc "contextless" (word: u64) -> (widget: Tray_Widget, ok: bool) {
	return enum_word.member_of_word(Tray_Widget, word)
}

// The clock at the right end of the bar: the date and the time of day in
// the font of the cells, "2026-11-11 16:30:05".
CLOCK_WIDTH :: 19 * CHARACTER_WIDTH
CLOCK_MARGIN :: 16 // Between the clock and the right edge of the screen.
CLOCK_TEXT_Y :: 8 // The top of the text of the clock in the bar.
TRAY_CLOCK_GAP :: 12 // Between the tray and the clock: the hairline of the clock is in its middle.
// The plate of the clock reaches this far past its text on each side: less
// than half of TRAY_CLOCK_GAP, so it never covers the hairline.
CLOCK_PLATE_INSET :: 4
#assert(CLOCK_PLATE_INSET < TRAY_CLOCK_GAP / 2)

// A tray button: the place of an icon of ICON_SIZE pixels at the height of
// a pill. The gap keeps room for the outline of the focus of the keys.
TRAY_BUTTON_WIDTH :: 28
TRAY_BUTTON_GAP :: 2

// The card of a tray widget keeps this room from each side of the screen.
TRAY_CARD_MARGIN :: 8

// The control center: two rows of two tiles, a hairline, a row of four
// launch buttons.
CONTROL_CENTER_WIDTH :: 336
CONTROL_PADDING :: 12 // Inside the border, on each side.
CONTROL_TILE_GAP :: 8 // Between two tiles, and between two launch buttons.
CONTROL_TILE_HEIGHT :: 56
CONTROL_SECTION_GAP :: 12 // On each side of the hairline over the launch buttons.
CONTROL_LAUNCH_HEIGHT :: 48
CONTROL_TILE_COLUMNS :: 2
CONTROL_LAUNCH_COUNT :: 4
CONTROL_CENTER_HEIGHT :: 2 * BORDER + 2 * CONTROL_PADDING + 2 * CONTROL_TILE_HEIGHT + CONTROL_TILE_GAP + 2 * CONTROL_SECTION_GAP + 1 + CONTROL_LAUNCH_HEIGHT

// The notification center: a head with the button Clear all, then one row
// for each notification of the history; one line when it is empty.
NOTIFICATION_CENTER_WIDTH :: 320
NOTIFICATION_HEAD_HEIGHT :: TITLE
NOTIFICATION_ROW_HEIGHT :: 52
NOTIFICATION_EMPTY_HEIGHT :: 48
CLEAR_ALL_WIDTH :: 76
CLEAR_ALL_HEIGHT :: 22
CLEAR_ALL_LABEL :: "Clear all"

// The calendar: the month, the row of the days of the week, a recessed
// plate with 6 rows of 7 days, and a foot.
CALENDAR_COLUMNS :: 7
CALENDAR_ROWS :: 6 // A month of 31 days that starts on a Saturday needs 6 rows.
CALENDAR_CELL_WIDTH :: 36
CALENDAR_CELL_HEIGHT :: 26
CALENDAR_PADDING :: 12
CALENDAR_HEAD_HEIGHT :: 28
CALENDAR_WEEKDAY_HEIGHT :: 20
CALENDAR_GRID_INSET :: 4 // Between the recessed plate and its cells.
CALENDAR_FOOT_HEIGHT :: 32
CALENDAR_WIDTH :: 2 * BORDER + 2 * CALENDAR_PADDING + 2 * CALENDAR_GRID_INSET + CALENDAR_COLUMNS * CALENDAR_CELL_WIDTH
CALENDAR_HEIGHT :: 2 * BORDER + CALENDAR_PADDING + CALENDAR_HEAD_HEIGHT + CALENDAR_WEEKDAY_HEIGHT + 2 * CALENDAR_GRID_INSET + CALENDAR_ROWS * CALENDAR_CELL_HEIGHT + CALENDAR_FOOT_HEIGHT

// The days of the week from Monday, as the head of a column of the grid.
@(rodata)
CALENDAR_WEEKDAYS := [CALENDAR_COLUMNS]string{"Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"}

// The names of the months, January first.
@(rodata)
CALENDAR_MONTHS := [12]string{"January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"}

// clock_x gives the first column of the text of the clock.
clock_x :: proc "contextless" (screen_width: int) -> int {
	return screen_width - CLOCK_WIDTH - CLOCK_MARGIN
}

// tray_right gives the first column after the tray: the hairline of the
// clock is in the gap after it.
tray_right :: proc "contextless" (screen_width: int) -> int {
	return clock_x(screen_width) - TRAY_CLOCK_GAP
}

// tray_widget_button gives the place of the part of the bar that opens a
// widget: from the right, the clock, the button of the notifications, the
// button of the control center. None has no place: its width is 0.
tray_widget_button :: proc "contextless" (layout: Layout, screen_width: int, widget: Tray_Widget) -> (x, y, width, height: int) {
	y = top(layout) + TRAY_Y
	right := tray_right(screen_width)
	switch widget {
	case .None:
		return 0, 0, 0, 0
	case .Notifications:
		return right - TRAY_BUTTON_WIDTH, y, TRAY_BUTTON_WIDTH, TRAY_HEIGHT
	case .Control_Center:
		return right - 2 * TRAY_BUTTON_WIDTH - TRAY_BUTTON_GAP, y, TRAY_BUTTON_WIDTH, TRAY_HEIGHT
	case .Calendar:
		return clock_x(screen_width) - CLOCK_PLATE_INSET, y, CLOCK_WIDTH + 2 * CLOCK_PLATE_INSET, TRAY_HEIGHT
	}
	return 0, 0, 0, 0
}

// tray_buttons_left gives the first column of the leftmost tray button:
// the rest of the tray (the mark of a viewer, the marks of the assistive
// holders, the pills) ends before it.
tray_buttons_left :: proc "contextless" (screen_width: int) -> int {
	x, _, _, _ := tray_widget_button({}, screen_width, .Control_Center)
	return x
}

// tray_widget_button_at gives the widget whose button is at a point, or None.
tray_widget_button_at :: proc "contextless" (layout: Layout, screen_width, point_x, point_y: int) -> Tray_Widget {
	for widget in Tray_Widget {
		if x, y, width, height := tray_widget_button(layout, screen_width, widget); width > 0 && inside(point_x, point_y, x, y, width, height) {
			return widget
		}
	}
	return .None
}

// tray_card_size gives the size of the card of a widget. The card of the
// notifications grows with the history; None has no card.
tray_card_size :: proc "contextless" (widget: Tray_Widget, notification_count: int) -> (width, height: int) {
	switch widget {
	case .None:
		return 0, 0
	case .Control_Center:
		return CONTROL_CENTER_WIDTH, CONTROL_CENTER_HEIGHT
	case .Notifications:
		count := clamp(notification_count, 0, NOTIFICATION_HISTORY_CAPACITY)
		if count == 0 {
			return NOTIFICATION_CENTER_WIDTH, 2 * BORDER + NOTIFICATION_EMPTY_HEIGHT
		}
		return NOTIFICATION_CENTER_WIDTH, 2 * BORDER + NOTIFICATION_HEAD_HEIGHT + count * NOTIFICATION_ROW_HEIGHT
	case .Calendar:
		return CALENDAR_WIDTH, CALENDAR_HEIGHT
	}
	return 0, 0
}

// tray_card gives the place of the card of a widget: away from the bar
// edge, its right edge on the right edge of its button, kept
// TRAY_CARD_MARGIN inside the screen. None has no place: its width is 0.
tray_card :: proc "contextless" (layout: Layout, screen_width: int, widget: Tray_Widget, notification_count: int) -> (x, y, width, height: int) {
	if widget == .None {
		return 0, 0, 0, 0
	}
	width, height = tray_card_size(widget, notification_count)
	button_x, _, button_width, _ := tray_widget_button(layout, screen_width, widget)
	x = clamp(button_x + button_width - width, TRAY_CARD_MARGIN, max(TRAY_CARD_MARGIN, screen_width - width - TRAY_CARD_MARGIN))
	return x, menu_top(layout, height), width, height
}

// tray_card_inside reports whether a point is on the card of a widget.
tray_card_inside :: proc "contextless" (layout: Layout, screen_width: int, widget: Tray_Widget, notification_count, point_x, point_y: int) -> bool {
	x, y, width, height := tray_card(layout, screen_width, widget, notification_count)
	return width > 0 && inside(point_x, point_y, x, y, width, height)
}

// A part of a card: a tile or a launch button of the control center, or
// the button Clear all of the notification center.
Tray_Part :: enum u8 {
	None,
	Appearance_Tile, // The appearance in force. A press asks for the next one: auto, dark, light.
	Bar_Edge_Tile, // A press moves the bar to the other edge.
	Magnifier_Tile, // A press turns the magnifier on or off.
	Display_Tile, // The scanout and the size of the screen. It takes no press.
	Launch_Settings,
	Launch_Monitor,
	Launch_Browser,
	Launch_Edit,
	Clear_All, // A press empties the history.
}

// The parts that a press or Enter acts on, in the order of the keys, for
// each widget.
@(rodata)
CONTROL_CENTER_PARTS_IN_ORDER := [?]Tray_Part{.Appearance_Tile, .Bar_Edge_Tile, .Magnifier_Tile, .Launch_Settings, .Launch_Monitor, .Launch_Browser, .Launch_Edit}
@(rodata)
NOTIFICATION_PARTS_IN_ORDER := [?]Tray_Part{.Clear_All}

// tray_part_widget gives the widget whose card holds a part.
tray_part_widget :: proc "contextless" (part: Tray_Part) -> Tray_Widget {
	switch part {
	case .None:
		return .None
	case .Appearance_Tile, .Bar_Edge_Tile, .Magnifier_Tile, .Display_Tile, .Launch_Settings, .Launch_Monitor, .Launch_Browser, .Launch_Edit:
		return .Control_Center
	case .Clear_All:
		return .Notifications
	}
	return .None
}

// tray_part_takes_press reports whether a press on a part acts. A tile that
// only says a state takes none.
tray_part_takes_press :: proc "contextless" (part: Tray_Part) -> bool {
	switch part {
	case .None, .Display_Tile:
		return false
	case .Appearance_Tile, .Bar_Edge_Tile, .Magnifier_Tile, .Launch_Settings, .Launch_Monitor, .Launch_Browser, .Launch_Edit, .Clear_All:
		return true
	}
	return false
}

// tray_part_closes_card reports whether the card closes after the act of a
// part: a launch starts a window. A tile and Clear all keep the card open,
// so the principal sees the new state.
tray_part_closes_card :: proc "contextless" (part: Tray_Part) -> bool {
	switch part {
	case .Launch_Settings, .Launch_Monitor, .Launch_Browser, .Launch_Edit:
		return true
	case .None, .Appearance_Tile, .Bar_Edge_Tile, .Magnifier_Tile, .Display_Tile, .Clear_All:
		return false
	}
	return false
}

// tray_part_module gives the module that a launch button starts, and its
// label; an empty name for each other part.
tray_part_module :: proc "contextless" (part: Tray_Part) -> (module, label: string) {
	switch part {
	case .Launch_Settings:
		return "settings", "Settings"
	case .Launch_Monitor:
		return "monitor", "Monitor"
	case .Launch_Browser:
		return "browser", "Browser"
	case .Launch_Edit:
		return "edit", "Edit"
	case .None, .Appearance_Tile, .Bar_Edge_Tile, .Magnifier_Tile, .Display_Tile, .Clear_All:
		return "", ""
	}
	return "", ""
}

// tray_part_place gives the place of a part of the card of its widget. ok
// is false for None, and for Clear all with an empty history.
tray_part_place :: proc "contextless" (layout: Layout, screen_width: int, part: Tray_Part, notification_count: int) -> (x, y, width, height: int, ok: bool) {
	widget := tray_part_widget(part)
	card_x, card_y, card_width, _ := tray_card(layout, screen_width, widget, notification_count)
	inner_x := card_x + BORDER + CONTROL_PADDING
	inner_width := card_width - 2 * BORDER - 2 * CONTROL_PADDING
	switch part {
	case .None:
		return 0, 0, 0, 0, false
	case .Appearance_Tile, .Bar_Edge_Tile, .Magnifier_Tile, .Display_Tile:
		index := int(part) - int(Tray_Part.Appearance_Tile)
		tile_width := (inner_width - CONTROL_TILE_GAP) / CONTROL_TILE_COLUMNS
		column, row := index % CONTROL_TILE_COLUMNS, index / CONTROL_TILE_COLUMNS
		return inner_x + column * (tile_width + CONTROL_TILE_GAP), card_y + BORDER + CONTROL_PADDING + row * (CONTROL_TILE_HEIGHT + CONTROL_TILE_GAP), tile_width, CONTROL_TILE_HEIGHT, true
	case .Launch_Settings, .Launch_Monitor, .Launch_Browser, .Launch_Edit:
		index := int(part) - int(Tray_Part.Launch_Settings)
		launch_width := (inner_width - (CONTROL_LAUNCH_COUNT - 1) * CONTROL_TILE_GAP) / CONTROL_LAUNCH_COUNT
		launch_y := card_y + BORDER + CONTROL_PADDING + 2 * CONTROL_TILE_HEIGHT + CONTROL_TILE_GAP + 2 * CONTROL_SECTION_GAP + 1
		return inner_x + index * (launch_width + CONTROL_TILE_GAP), launch_y, launch_width, CONTROL_LAUNCH_HEIGHT, true
	case .Clear_All:
		if notification_count <= 0 {
			return 0, 0, 0, 0, false
		}
		return card_x + card_width - BORDER - PADDING - CLEAR_ALL_WIDTH, card_y + BORDER + (NOTIFICATION_HEAD_HEIGHT - CLEAR_ALL_HEIGHT) / 2, CLEAR_ALL_WIDTH, CLEAR_ALL_HEIGHT, true
	}
	return 0, 0, 0, 0, false
}

// control_center_hairline_y gives the row of the hairline over the launch
// buttons of a control center whose card starts at card_y.
control_center_hairline_y :: proc "contextless" (card_y: int) -> int {
	return card_y + BORDER + CONTROL_PADDING + 2 * CONTROL_TILE_HEIGHT + CONTROL_TILE_GAP + CONTROL_SECTION_GAP
}

// tray_part_at gives the part of the card of a widget at a point that a
// press acts on, or None.
tray_part_at :: proc "contextless" (layout: Layout, screen_width: int, widget: Tray_Widget, notification_count, point_x, point_y: int) -> Tray_Part {
	for part in Tray_Part {
		if part == .None || tray_part_widget(part) != widget || !tray_part_takes_press(part) {
			continue
		}
		if x, y, width, height, ok := tray_part_place(layout, screen_width, part, notification_count); ok && inside(point_x, point_y, x, y, width, height) {
			return part
		}
	}
	return .None
}

// tray_part_step gives the part that the keys choose after Down (forward)
// or Up, around the ends, among the parts of the card that a press acts
// on. A part of another card, or None, starts at the first part (Down) or
// the last (Up). A card with no such part gives None.
tray_part_step :: proc "contextless" (widget: Tray_Widget, notification_count: int, part: Tray_Part, forward: bool) -> Tray_Part {
	parts: []Tray_Part
	switch widget {
	case .None, .Calendar:
		return .None
	case .Control_Center:
		parts = CONTROL_CENTER_PARTS_IN_ORDER[:]
	case .Notifications:
		if notification_count <= 0 {
			return .None
		}
		parts = NOTIFICATION_PARTS_IN_ORDER[:]
	}
	place := -1
	for candidate, index in parts {
		if candidate == part {
			place = index
		}
	}
	if place < 0 {
		return parts[forward ? 0 : len(parts) - 1]
	}
	return parts[(place + (forward ? 1 : len(parts) - 1)) % len(parts)]
}

// notification_row gives the place of the row of a notification of the
// history, the newest at index 0. ok is false for an index outside the
// history.
notification_row :: proc "contextless" (layout: Layout, screen_width, notification_count, index: int) -> (x, y, width, height: int, ok: bool) {
	count := clamp(notification_count, 0, NOTIFICATION_HISTORY_CAPACITY)
	if index < 0 || index >= count {
		return 0, 0, 0, 0, false
	}
	card_x, card_y, card_width, _ := tray_card(layout, screen_width, .Notifications, count)
	return card_x + BORDER, card_y + BORDER + NOTIFICATION_HEAD_HEIGHT + index * NOTIFICATION_ROW_HEIGHT, card_width - 2 * BORDER, NOTIFICATION_ROW_HEIGHT, true
}

// The state of the tray widgets that the compositor keeps.
Tray_State :: struct {
	open:    Tray_Widget, // The card on the screen.
	hovered: Tray_Widget, // The button under the pointer: it is drawn lit.
	chosen:  Tray_Part, // The part under the pointer, or the one that the keys chose.
}

// What a press did to the tray widgets.
Tray_Press_Kind :: enum u8 {
	Not_Taken, // The press is on no tray button and no card is open: it goes on.
	Opened, // A button opened its card, and closed any other.
	Closed, // A press on the button of the open card, or outside it, closed it.
	Kept_Open, // A press on the card away from its parts.
	Part_Pressed, // A press on a part: the caller does its act.
}

Tray_Press :: struct {
	kind:   Tray_Press_Kind,
	widget: Tray_Widget, // The card that opened, closed or holds the part.
	part:   Tray_Part,
}

// tray_press takes a press of the left button. Every kind but Not_Taken
// takes the press: nothing under the card or the button receives it.
tray_press :: proc "contextless" (state: ^Tray_State, layout: Layout, screen_width, notification_count, point_x, point_y: int) -> Tray_Press {
	if under := tray_widget_button_at(layout, screen_width, point_x, point_y); under != .None {
		state.chosen = .None
		if state.open == under {
			state.open = .None
			return {kind = .Closed, widget = under}
		}
		state.open = under
		return {kind = .Opened, widget = under}
	}
	widget := state.open
	if widget == .None {
		return {}
	}
	if part := tray_part_at(layout, screen_width, widget, notification_count, point_x, point_y); part != .None {
		if tray_part_closes_card(part) {
			state.open, state.chosen = .None, .None
		}
		return {kind = .Part_Pressed, widget = widget, part = part}
	}
	if tray_card_inside(layout, screen_width, widget, notification_count, point_x, point_y) {
		return {kind = .Kept_Open, widget = widget}
	}
	state.open, state.chosen = .None, .None
	return {kind = .Closed, widget = widget}
}

// tray_open opens the card of a widget, or closes the open card with None.
// It reports whether the state changed.
tray_open :: proc "contextless" (state: ^Tray_State, widget: Tray_Widget) -> bool {
	if state.open == widget {
		return false
	}
	state.open, state.chosen = widget, .None
	return true
}

// tray_pointer_move takes a move of the pointer: the button and the part
// under it. It reports what changed, so the caller damages only that.
tray_pointer_move :: proc "contextless" (state: ^Tray_State, layout: Layout, screen_width, notification_count, point_x, point_y: int) -> (button_changed, part_changed: bool) {
	hovered := tray_widget_button_at(layout, screen_width, point_x, point_y)
	chosen := tray_part_at(layout, screen_width, state.open, notification_count, point_x, point_y)
	button_changed, part_changed = hovered != state.hovered, chosen != state.chosen
	state.hovered, state.chosen = hovered, chosen
	return
}

// The history of the notifications that the desktop showed: the newest
// first. A banner leaves the screen after its time; its record stays here
// until NOTIFICATION_HISTORY_CAPACITY newer ones came, or Clear all.
NOTIFICATION_HISTORY_CAPACITY :: 6
NOTIFICATION_TITLE_BYTES :: 48
NOTIFICATION_BODY_BYTES :: 96

Notification_Record :: struct {
	seconds:      i64, // The local time of the post in seconds since 1970, or the seconds since the boot when dated is false.
	title_length: u8,
	body_length:  u8,
	dated:        bool,
	title:        [NOTIFICATION_TITLE_BYTES]u8,
	body:         [NOTIFICATION_BODY_BYTES]u8,
}

Notification_History :: struct {
	records: [NOTIFICATION_HISTORY_CAPACITY]Notification_Record,
	count:   int,
}

// text_cut gives the longest start of a text of at most limit bytes that
// ends on the boundary of a UTF-8 character: a cut never leaves half of a
// character.
@(private)
text_cut :: proc "contextless" (text: string, limit: int) -> string {
	if len(text) <= limit {
		return text
	}
	end := max(limit, 0)
	for end > 0 && text[end] & 0xC0 == 0x80 {
		end -= 1
	}
	return text[:end]
}

// notification_history_add puts a notification at the head of the
// history; the oldest leaves a full history. A title or a body past its
// room is cut on a character. It refuses an empty title, as the queue of
// the banners does, and changes nothing then.
notification_history_add :: proc "contextless" (history: ^Notification_History, title, body: string, seconds: i64, dated: bool) -> bool {
	if len(title) == 0 {
		return false
	}
	kept := min(history.count, NOTIFICATION_HISTORY_CAPACITY - 1)
	for index := kept; index > 0; index -= 1 {
		history.records[index] = history.records[index - 1]
	}
	record := Notification_Record{seconds = seconds, dated = dated}
	title_kept := text_cut(title, NOTIFICATION_TITLE_BYTES)
	body_kept := text_cut(body, NOTIFICATION_BODY_BYTES)
	copy(record.title[:], title_kept)
	copy(record.body[:], body_kept)
	record.title_length, record.body_length = u8(len(title_kept)), u8(len(body_kept))
	history.records[0] = record
	history.count = kept + 1
	return true
}

// notification_history_clear empties the history. It reports whether it
// held a record.
notification_history_clear :: proc "contextless" (history: ^Notification_History) -> bool {
	held := history.count > 0
	history^ = {}
	return held
}

// notification_title gives the title of a record.
notification_title :: proc "contextless" (record: ^Notification_Record) -> string {
	return string(record.title[:min(int(record.title_length), NOTIFICATION_TITLE_BYTES)])
}

// notification_body gives the body of a record, empty when it has none.
notification_body :: proc "contextless" (record: ^Notification_Record) -> string {
	return string(record.body[:min(int(record.body_length), NOTIFICATION_BODY_BYTES)])
}

// notification_time_text gives the time of day of a record, "16:30": the
// local time with a date, else the time since the boot, its hours past a
// day kept whole.
notification_time_text :: proc "contextless" (record: ^Notification_Record, buffer: ^[8]u8) -> string {
	seconds := record.seconds
	hours, minutes: i64
	if record.dated {
		in_day := seconds - calendar.floor_divide(seconds, calendar.SECONDS_IN_A_DAY) * calendar.SECONDS_IN_A_DAY
		hours, minutes = in_day / 3600, in_day / 60 % 60
	} else {
		seconds = max(seconds, 0)
		hours, minutes = min(seconds / 3600, 99), seconds / 60 % 60
	}
	buffer[0] = u8('0' + hours / 10)
	buffer[1] = u8('0' + hours % 10)
	buffer[2] = ':'
	buffer[3] = u8('0' + minutes / 10)
	buffer[4] = u8('0' + minutes % 10)
	return string(buffer[:5])
}

// A month as the calendar shows it.
Calendar_Month :: struct {
	year:         i64,
	month:        int, // 1 to 12.
	today:        int, // The day of today in the month, 1 to 31.
	days:         int, // The days of the month: 28 to 31.
	first_column: int, // The column of the first day: 0 for a Monday, 6 for a Sunday.
}

// calendar_month_of gives the month of a local time in seconds since 1970.
calendar_month_of :: proc "contextless" (local_seconds: i64) -> Calendar_Month {
	today := calendar.civil(local_seconds)
	first_day := calendar.days_from_civil(today.year, today.month, 1)
	// 1970-01-01, day 0, was a Thursday: the column 3.
	column := int(first_day + 3 - calendar.floor_divide(first_day + 3, CALENDAR_COLUMNS) * CALENDAR_COLUMNS)
	return {year = today.year, month = today.month, today = today.day, days = calendar.days_in_month(today.year, today.month), first_column = column}
}

// calendar_cell gives the day of a cell of the grid. A cell before the
// first day has a day of the month before, a cell after the last day a day
// of the month after: in_month is false for both. A cell outside the grid
// gives 0.
calendar_cell :: proc "contextless" (month: Calendar_Month, row, column: int) -> (day: int, in_month: bool) {
	if row < 0 || row >= CALENDAR_ROWS || column < 0 || column >= CALENDAR_COLUMNS {
		return 0, false
	}
	index := row * CALENDAR_COLUMNS + column - month.first_column
	if index < 0 {
		before_year, before_month := month.year, month.month - 1
		if before_month < 1 {
			before_year, before_month = before_year - 1, 12
		}
		return calendar.days_in_month(before_year, before_month) + index + 1, false
	}
	if index >= month.days {
		return index - month.days + 1, false
	}
	return index + 1, true
}

// calendar_today_cell gives the row and the column of today in the grid.
calendar_today_cell :: proc "contextless" (month: Calendar_Month) -> (row, column: int) {
	index := month.first_column + month.today - 1
	return index / CALENDAR_COLUMNS, index % CALENDAR_COLUMNS
}

// calendar_title gives the name of the month and the year, "November 2026".
calendar_title :: proc "contextless" (month: Calendar_Month, buffer: ^[32]u8) -> string {
	name := CALENDAR_MONTHS[clamp(month.month, 1, 12) - 1]
	at := copy(buffer[:], name)
	buffer[at] = ' '
	at += 1
	year := month.year
	if year < 0 {
		buffer[at] = '-'
		at += 1
		year = -year
	}
	digits: [20]u8
	count := 0
	for {
		digits[count] = u8('0' + year % 10)
		count += 1
		year /= 10
		if year == 0 {
			break
		}
	}
	for count > 0 && at < len(buffer) {
		count -= 1
		buffer[at] = digits[count]
		at += 1
	}
	return string(buffer[:at])
}

// calendar_grid gives the recessed plate of the grid of the calendar.
calendar_grid :: proc "contextless" (layout: Layout, screen_width: int) -> (x, y, width, height: int) {
	card_x, card_y, _, _ := tray_card(layout, screen_width, .Calendar, 0)
	x = card_x + BORDER + CALENDAR_PADDING
	y = card_y + BORDER + CALENDAR_PADDING + CALENDAR_HEAD_HEIGHT + CALENDAR_WEEKDAY_HEIGHT
	return x, y, 2 * CALENDAR_GRID_INSET + CALENDAR_COLUMNS * CALENDAR_CELL_WIDTH, 2 * CALENDAR_GRID_INSET + CALENDAR_ROWS * CALENDAR_CELL_HEIGHT
}

// calendar_cell_place gives the place of a cell of the grid. ok is false
// for a cell outside the grid.
calendar_cell_place :: proc "contextless" (layout: Layout, screen_width, row, column: int) -> (x, y, width, height: int, ok: bool) {
	if row < 0 || row >= CALENDAR_ROWS || column < 0 || column >= CALENDAR_COLUMNS {
		return 0, 0, 0, 0, false
	}
	grid_x, grid_y, _, _ := calendar_grid(layout, screen_width)
	return grid_x + CALENDAR_GRID_INSET + column * CALENDAR_CELL_WIDTH, grid_y + CALENDAR_GRID_INSET + row * CALENDAR_CELL_HEIGHT, CALENDAR_CELL_WIDTH, CALENDAR_CELL_HEIGHT, true
}
