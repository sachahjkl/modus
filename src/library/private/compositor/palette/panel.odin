package palette

import "modus:contract/enum_word"
import "modus:contract/palette_table"
import "modus:contract/value_kinds"
import "modus:support/graphics"
import "modus:support/interface"
import "modus:support/kind_icons"

// The geometry of the panel (docs/DESIGN.md, "Palette"). From the top: the
// input band, the list, a gap, the detail line, the footer, a margin.
PANEL_WIDTH :: 640
PANEL_TOP :: 96 // The top of the panel on the screen: fixed, so the input band never moves when the list changes.
INPUT_BAND_HEIGHT :: 48 // The input band, with the line of 2 pixels that is its last 2 pixels.
INPUT_SCALE :: 2 // The typed part: cells of 16 x 32 pixels.
ROW_HEIGHT :: interface.TABLE_LINE // One row of the list.
LIST_TOP :: INPUT_BAND_HEIGHT // From the top of the panel to the list.
LIST_HEIGHT :: LIST_ROWS * ROW_HEIGHT
LIST_GAP :: graphics.GAP // Between the list and the detail line.
DETAIL_TOP :: LIST_TOP + LIST_HEIGHT + LIST_GAP // The detail line: what the chosen entry does.
DETAIL_HEIGHT :: 24
FOOTER_TOP :: DETAIL_TOP + DETAIL_HEIGHT // The footer: the source of the chosen entry, the count, the keys.
FOOTER_HEIGHT :: 24
BOTTOM_MARGIN :: graphics.GAP
PANEL_HEIGHT :: FOOTER_TOP + FOOTER_HEIGHT + BOTTOM_MARGIN
BORDER :: 1 // The border of the panel under the input band: at the left, the right and the bottom.
TEXT_MARGIN :: graphics.MARGIN // From a side of the panel to a text.

#assert(PANEL_HEIGHT == 400)

// panel_place gives the top left corner of the panel on a screen: in the
// middle of its width, at a fixed height in its upper third. On a screen of
// an odd free width, the panel is half a pixel to the left of the middle.
panel_place :: proc "contextless" (screen_width: int) -> (x, y: int) {
	return max(screen_width - PANEL_WIDTH, 0) / 2, PANEL_TOP
}

// A part of the panel, for the pointer.
Part :: enum u8 {
	Outside    = 0, // Not in the panel: a press there closes it.
	Input_Band = 1, // The input band: the pointer has the shape of a text.
	List       = 2, // The area of the list, on a row or under the last one.
	Rest       = 3, // The detail line, the footer, the margins: a press there does nothing.
}

// part_at gives the part of the panel at a point of the screen. panel_x
// and panel_y: the corner of the panel.
part_at :: proc "contextless" (panel_x, panel_y, x, y: int) -> Part {
	if x < panel_x || x >= panel_x + PANEL_WIDTH || y < panel_y || y >= panel_y + PANEL_HEIGHT {
		return .Outside
	}
	switch {
	case y < panel_y + INPUT_BAND_HEIGHT:
		return .Input_Band
	case y < panel_y + LIST_TOP + LIST_HEIGHT:
		return .List
	}
	return .Rest
}

// rows_right gives the x after the last pixel of the rows of a list of a
// count of rows: the border of the panel, or the scroll bar of a list that
// does not show each row. A point at the right of it is on no row.
@(private)
rows_right :: proc "contextless" (panel_x, row_count: int) -> int {
	return panel_x + PANEL_WIDTH - BORDER - (row_count > LIST_ROWS ? interface.LIST_ROW_SCROLL_WIDTH : 0)
}

// row_at gives the row of the list at a point of the screen, or NO_ROW: a
// row that the panel shows now, an entry or a heading. A point on the
// scroll bar is on no row.
row_at :: proc "contextless" (panel: ^Panel, panel_x, panel_y, x, y: int) -> int {
	if panel.list == nil || panel.state != .Search && panel.state != .Confirm || panel.form.active {
		return NO_ROW
	}
	if part_at(panel_x, panel_y, x, y) != .List || x < panel_x + BORDER || x >= rows_right(panel_x, panel.list.row_count) {
		return NO_ROW
	}
	row := panel.first_row + (y - panel_y - LIST_TOP) / ROW_HEIGHT
	return row < panel.list.row_count ? row : NO_ROW
}

// candidate_at gives the candidate of the form at a point of the screen,
// as an index in the shown candidates, or NO_ROW: the panel is not in a
// form, or the point is on no candidate.
candidate_at :: proc "contextless" (panel: ^Panel, panel_x, panel_y, x, y: int) -> int {
	form := &panel.form
	if panel.state != .Arguments || !form.active || field_control(form, form.current) == .Buttons {
		// A row of buttons takes the keys only: the list area holds no
		// candidate under the pointer.
		return NO_ROW
	}
	if part_at(panel_x, panel_y, x, y) != .List || x < panel_x + BORDER || x >= rows_right(panel_x, form.shown_count) {
		return NO_ROW
	}
	shown := candidates_first(form) + (y - panel_y - LIST_TOP) / ROW_HEIGHT
	return shown < form.shown_count ? shown : NO_ROW
}

// The name of the scroll bar of the panel, for its identity: the list of
// the entries and the candidates of a form are never on the screen
// together, so one name serves both.
SCROLL_BAR_NAME :: "the scroll bar of the palette"
// The element name of that scroll bar: its parts are "scroll bar arrow
// down" and the others (interface.scroll_bar).
SCROLL_BAR_ELEMENT_NAME :: "scroll bar"

// scroll_bar_identity gives the identity of the scroll bar of the panel in
// the interface state of its owner.
scroll_bar_identity :: proc "contextless" () -> interface.Element_Identity {
	return interface.identity(SCROLL_BAR_NAME)
}

// scroll_bar_area gives the area of the scroll bar that takes the pointer
// now, for a panel whose corner is at (panel_x, panel_y): the bar of the
// entries in the search, of the candidates in a form. shown is false when
// the rows fit, and in each other state: the panel then has no scroll bar
// that the pointer moves.
scroll_bar_area :: proc "contextless" (panel: ^Panel, panel_x, panel_y: int) -> (area: interface.Area, shown: bool) {
	total := 0
	switch panel.state {
	case .Closed, .Confirm, .Running, .Result:
		// No rows: no scroll bar.
	case .Search:
		if panel.list != nil && !panel.form.active {
			total = panel.list.row_count
		}
	case .Arguments:
		if panel.form.active {
			total = panel.form.shown_count
		}
	}
	if total <= LIST_ROWS {
		return {}, false
	}
	return {rows_right(panel_x, total), panel_y + LIST_TOP, interface.LIST_ROW_SCROLL_WIDTH, LIST_HEIGHT}, true
}

// scroll_view_area gives the area of the rows that the scroll bar of the
// panel moves, with the bar: the wheel over it moves the view. It is the
// list area of the entries and of the candidates, which panel_draw gives
// the list as its view.
scroll_view_area :: proc "contextless" (panel_x, panel_y: int) -> interface.Area {
	return {panel_x + BORDER, panel_y + LIST_TOP, PANEL_WIDTH - 2 * BORDER, LIST_HEIGHT}
}

// view_scrolled applies what the pointer did to the scroll bar in the last
// draw of the panel (Panel.scrolled): the view goes to the first row that
// the scroll bar asks for, and the choice goes with it, to the nearest
// entry that the view shows. The palette runs the row that is drawn: a
// choice outside the view is an entry that Enter runs and that no frame
// shows. It gives true when the view moved: the owner draws the
// panel again.
view_scrolled :: proc "contextless" (panel: ^Panel) -> bool {
	moved := panel.scrolled
	panel.scrolled = {}
	if !moved.changed {
		return false
	}
	switch panel.state {
	case .Closed, .Confirm, .Running, .Result:
		// scroll_bar_area shows no scroll bar in these states.
	case .Search:
		list := panel.list
		if list == nil || list.row_count <= LIST_ROWS {
			return false
		}
		first := clamp(moved.first, 0, list.row_count - LIST_ROWS)
		if first == panel.first_row {
			return false
		}
		panel.first_row = first
		last := first + LIST_ROWS - 1
		if panel.choice < first {
			for row in first ..= last {
				if row_is_entry(panel, row) {
					panel.choice = row
					break
				}
			}
		} else if panel.choice > last {
			for row := last; row >= first; row -= 1 {
				if row_is_entry(panel, row) {
					panel.choice = row
					break
				}
			}
		}
		return true
	case .Arguments:
		form := &panel.form
		if !form.active || form.shown_count <= LIST_ROWS {
			return false
		}
		first := clamp(moved.first, 0, form.shown_count - LIST_ROWS)
		if first == candidates_first(form) {
			return false
		}
		form.candidate_first = first
		if form.candidate_choice >= 0 {
			form.candidate_choice = clamp(form.candidate_choice, first, first + LIST_ROWS - 1)
		}
		return true
	}
	return false
}

// kind_words gives what a kind is, in words: the text at the right of a row.
kind_words :: proc "contextless" (kind: Entry_Kind) -> string {
	switch kind {
	case .Window:
		return "window"
	case .Module:
		return "module"
	case .Close_Window:
		return "close a window"
	case .Command:
		return "command"
	case .Export:
		return "export"
	case .Setting:
		return "setting"
	}
	return ""
}

// entry_words gives the text at the right of the row of an entry: its
// kind, and that the panel cannot run it when it has parameters.
entry_words :: proc "contextless" (entry: ^Entry) -> string {
	if .Needs_Arguments in entry.flags {
		return entry.kind == .Command ? "command, needs arguments" : "export, needs arguments"
	}
	return kind_words(entry.kind)
}

// entry_hint gives what Enter does on an entry: the footer says it. form:
// the panel has a field for each parameter of the entry. manual: the typed
// part has the prefix of the manual.
entry_hint :: proc "contextless" (entry: ^Entry, form: bool, manual: bool) -> string {
	if manual && entry.kind == .Module {
		return "enter: its page of the manual"
	}
	switch entry.kind {
	case .Window:
		return "enter: to the front"
	case .Module:
		return "enter: start"
	case .Close_Window:
		return "enter: close"
	case .Command, .Export:
		if .Needs_Arguments not_in entry.flags {
			return "enter: run"
		}
		return form ? "enter: arguments" : "enter: arguments in the console"
	case .Setting:
		return "enter: set"
	}
	return ""
}

// given_of gives the record that the provider wrote for an entry, in the
// checked copy of its table; nil for an entry of the compositor.
given_of :: proc "contextless" (list: ^List, entry: ^Entry) -> ^palette_table.Entry {
	if !entry_of_provider(entry) || int(entry.number) >= list.snapshot.entry_count {
		return nil
	}
	return &list.snapshot.entries[entry.number]
}

// entry_about writes the sentence of the detail line: what the choice of
// the entry does, with the facts of now. An entry of a provider has the
// help sentence that the provider gave.
entry_about :: proc "contextless" (builder: ^interface.Text_Builder, list: ^List, entry: ^Entry) {
	switch entry.kind {
	case .Window:
		if entry.mark == .Has_Focus {
			interface.text_put(builder, "The window of the process ")
			interface.text_put(builder, entry_name(entry))
			interface.text_put(builder, ". It has the focus.")
		} else {
			interface.text_put(builder, "Brings the window of the process ")
			interface.text_put(builder, entry_name(entry))
			interface.text_put(builder, " to the front and gives it the focus.")
		}
	case .Module:
		interface.text_put(builder, "Starts the module ")
		interface.text_put(builder, entry_name(entry))
		if entry.windows == 0 {
			interface.text_put(builder, ". It has no window now.")
		} else {
			interface.text_put(builder, " one more time. It has ")
			interface.text_put_number(builder, u64(entry.windows))
			interface.text_put(builder, entry.windows == 1 ? " window now." : " windows now.")
		}
	case .Close_Window:
		interface.text_put(builder, "Stops the process ")
		interface.text_put(builder, window_title_of(entry))
		interface.text_put(builder, ": its window closes. Asks for a second Enter.")
	case .Command, .Export, .Setting:
		if given := given_of(list, entry); given != nil {
			interface.text_put(builder, string(given.about[:given.about_length]))
		}
	}
}

// setting_in_use says if a Setting entry is the value that the machine
// uses now: for a setting of the machine, from the values that the owner of
// the panel gave; for a value that only the provider knows, from its mark.
setting_in_use :: proc "contextless" (panel: ^Panel, entry: ^Entry) -> bool {
	if entry.mark == .In_Use {
		return true
	}
	// A setting row: one of its values is in use; its line says which.
	if entry_is_setting_row(entry) {
		for value in 0 ..< int(entry.value_count) {
			if value_in_use(panel, entry, value) {
				return true
			}
		}
		return false
	}
	given := given_of(panel.list, entry)
	if given == nil || given.kind != u8(palette_table.Entry_Kind.Setting) || int(given.setting) >= len(panel.settings_in_use) {
		return false
	}
	return panel.settings_in_use[given.setting] == given.setting_value
}

// signature_fit gives the parameters and the result of a command for a
// room in cells: whole when they fit; else the parameters that fit whole,
// then ", ...)"; else "(...)". The text is never cut inside a parameter.
// buffer holds the cut form.
signature_fit :: proc "contextless" (detail: string, cells: int, buffer: []u8) -> string {
	if len(detail) <= cells {
		return detail
	}
	// The end of each parameter: the place of ", " at the level of the
	// parentheses of the call.
	depth := 0
	best := 0
	for index in 0 ..< len(detail) {
		switch detail[index] {
		case '(':
			depth += 1
		case ')':
			depth -= 1
		case ',':
			if depth == 1 && index + len(", ...)") <= cells {
				best = index
			}
		}
	}
	if best == 0 {
		short := "(...)"
		return len(short) <= cells ? short : ""
	}
	count := copy(buffer, detail[:best])
	count += copy(buffer[count:], ", ...)")
	return string(buffer[:count])
}

// The color of the icon of an entry that destroys: the red of "stop a
// process" in its brighter form, the red of the close button under the
// pointer. The deep red of the button is too near the surface of a card for
// the thin parts of an icon.
icon_color_of_stop :: proc "contextless" () -> graphics.Color {
	return graphics.colors.stop_process_pointer_over
}

// The color of the icon of an entry in its quiet state: a module with no
// window, a window that has not the focus, a value of a setting that the
// machine does not use, a command that the panel cannot run at once.
icon_color_quiet :: proc "contextless" () -> graphics.Color {
	return graphics.colors.dim
}

// entry_icon gives the icon of an entry and its color on a row that is not
// chosen (docs/DESIGN.md, "The icons of the kinds"). The form says what the
// entry is, so a reader who does not tell the colors apart still tells a
// window from a module; an entry that destroys has the icon of that act,
// whatever its kind. The color says one fact of the entry: the color of
// its kind when the thing is there or in use, the quiet color when it is
// not. in_use: the entry is the value of a setting that the machine uses
// now.
entry_icon :: proc "contextless" (entry: ^Entry, in_use: bool) -> (icon: ^kind_icons.Cells, color: graphics.Color) {
	if entry.mark == .Destroys || entry.kind == .Close_Window {
		return kind_icons.cells_of_desktop_kind(.Stop), icon_color_of_stop()
	}
	quiet := .Needs_Arguments in entry.flags
	switch entry.kind {
	case .Window:
		icon = kind_icons.cells_of_desktop_kind(.Window)
		color = graphics.colors.title
		quiet = entry.mark != .Has_Focus
	case .Module:
		icon = kind_icons.cells_of_value_kind(.Module)
		color = graphics.value_kind_color(value_kinds.Value_Kind.Module, graphics.appearance)
		quiet = entry.mark != .Has_Window
	case .Close_Window:
	case .Command:
		icon = kind_icons.cells_of_value_kind(.Command)
		color = graphics.value_kind_color(value_kinds.Value_Kind.Command, graphics.appearance)
	case .Export:
		// An export is a part of a module: the color of a module.
		icon = kind_icons.cells_of_desktop_kind(.Export)
		color = graphics.value_kind_color(value_kinds.Value_Kind.Module, graphics.appearance)
	case .Setting:
		icon = kind_icons.cells_of_desktop_kind(.Setting)
		color = graphics.colors.text
		quiet = !in_use
	}
	if quiet {
		color = icon_color_quiet()
	}
	return
}

// candidate_icon gives the icon of the candidates of a field of a form and
// its color: the kind of what the field takes.
candidate_icon :: proc "contextless" (kind: palette_table.Candidate_Kind) -> (icon: ^kind_icons.Cells, color: graphics.Color) {
	switch kind {
	case .None:
	case .Process, .Module:
		return kind_icons.cells_of_value_kind(.Module), graphics.value_kind_color(value_kinds.Value_Kind.Module, graphics.appearance)
	case .Grant:
		return kind_icons.cells_of_value_kind(.Grant), graphics.value_kind_color(value_kinds.Value_Kind.Grant, graphics.appearance)
	case .Strategy, .Setting:
		// A strategy is a value of a state that the provider sets, as a
		// setting is: the icon and the color of a setting row.
		return kind_icons.cells_of_desktop_kind(.Setting), graphics.colors.text
	}
	return nil, 0
}

// part_color gives the color of a run of a result: a value has the color
// of its value kind, as in the console, in the log and on the site.
part_color :: proc "contextless" (part: palette_table.Run_Part) -> graphics.Color {
	switch part {
	case .Plain:
		return graphics.colors.text
	case .Label, .Note, .End_Line:
		return graphics.colors.dim
	case .Failure:
		return graphics.colors.failed
	case .Number:
		return graphics.value_kind_color(value_kinds.Value_Kind.Number, graphics.appearance)
	case .Size:
		return graphics.value_kind_color(value_kinds.Value_Kind.Size, graphics.appearance)
	case .Time:
		return graphics.value_kind_color(value_kinds.Value_Kind.Time, graphics.appearance)
	case .Handle:
		return graphics.value_kind_color(value_kinds.Value_Kind.Handle, graphics.appearance)
	case .Type:
		return graphics.value_kind_color(value_kinds.Value_Kind.Type, graphics.appearance)
	case .Status:
		return graphics.value_kind_color(value_kinds.Value_Kind.Status, graphics.appearance)
	case .Operation:
		return graphics.value_kind_color(value_kinds.Value_Kind.Operation, graphics.appearance)
	}
	return graphics.colors.text
}

HEADING_RECENT :: "recent"
HEADING_WINDOWS :: "windows"
HEADING_MODULES :: "modules"
PLACEHOLDER :: "type a part of a name"
KEYS_END :: "   esc: close"
MODE_RUN :: "enter: run" // The mode of an entry that runs: each entry that does not destroy.
MODE_DESTROY :: "enter enter: destroy" // The mode of an entry that destroys: a second Enter runs it.
MODE_GO_TO :: "shift enter: go to" // An open window names the act name of the entry.
MODE_GAP :: "   " // Between two texts at the right of the input band.
WORDS_OF_BUTTONS :: "left, right: choose a value   tab: take it"
KEYS_OF_PREFIXES :: "> commands  @ windows  : settings  ? manual"
KEYS_OF_ARGUMENTS :: "tab: next field   enter: run   esc: back"
KEYS_OF_ARGUMENTS_MORE :: "tab, enter: next field   ctrl enter: run   esc: back"
KEYS_OF_CONFIRM :: "enter: confirm   another key: back"
KEYS_OF_RUNNING :: "esc: close; the line goes on in the console"
KEYS_OF_RESULT :: "esc: close   another key: back"
WORDS_OF_RUNNING :: "runs in the console"
NOTE_NO_PROVIDER :: "entries, no commands"
NOTE_REFUSED_PROVIDER :: "entries, commands refused"
WORD_OF_COUNT :: "entries"
RESULT_CALL_TOP :: 8 // From the top of the list area to the line of the call of a result.
RESULT_LINES_TOP :: 40 // From the top of the list area to the first line of a result.

// mode_words writes the mode of an entry and its key, as the input band
// says it: "enter: run", "enter enter: destroy", and "shift enter: go to"
// after it when an open window names the act name of the entry.
mode_words :: proc "contextless" (builder: ^interface.Text_Builder, entry: ^Entry, go_to: bool) {
	interface.text_put(builder, entry_destroys(entry) ? MODE_DESTROY : MODE_RUN)
	if go_to {
		interface.text_put(builder, MODE_GAP)
		interface.text_put(builder, MODE_GO_TO)
	}
}

// band_text_end gives the x, from the left of the panel, after what the
// input band shows of the typed part with its caret, or after its
// placeholder: the words at the right of the band start 16 pixels after it
// at the least. The numbers are those of interface.text_input_line.
band_text_end :: proc "contextless" (table: ^interface.Draw_Table, typed: string) -> int {
	cell := graphics.CELL_WIDTH * INPUT_SCALE
	caret := 2 * INPUT_SCALE
	if len(typed) == 0 {
		return interface.TEXT_INPUT_LINE_MARGIN + cell + interface.text_measured_width(table, interface.Font{kind = .Interface, scale = INPUT_SCALE}, PLACEHOLDER)
	}
	fit := max((PANEL_WIDTH - 2 * interface.TEXT_INPUT_LINE_MARGIN - caret) / cell, 1)
	return interface.TEXT_INPUT_LINE_MARGIN + min(len(typed), fit) * cell + caret
}

// band_words_draw draws the words at the right of the input band of the
// search: the word of the prefix and the mode of the chosen entry, in the
// room that the typed part leaves. When both do not fit, the mode stays;
// when it does not fit either, the word of the prefix alone. It gives true
// when the band shows the mode.
@(private)
band_words_draw :: proc "contextless" (table: ^interface.Draw_Table, panel: ^Panel, chosen: ^Entry, prefix: Prefix, x, y: int) -> (mode_shown: bool) {
	room := PANEL_WIDTH - TEXT_MARGIN - (band_text_end(table, typed_text(panel)) + 16)
	word := prefix_words(prefix)
	mode: interface.Text_Builder
	if chosen != nil {
		mode_words(&mode, chosen, panel.go_to_offered)
	}
	both: interface.Text_Builder
	interface.text_put(&both, word)
	if word != "" && chosen != nil {
		interface.text_put(&both, MODE_GAP)
	}
	interface.text_put(&both, interface.text_of(&mode))
	text := ""
	switch {
	case interface.text_measured_width(table, interface.FONT_INTERFACE, interface.text_of(&both)) <= room:
		text = interface.text_of(&both)
		mode_shown = chosen != nil
	case chosen != nil && interface.text_measured_width(table, interface.FONT_INTERFACE, interface.text_of(&mode)) <= room:
		text = interface.text_of(&mode)
		mode_shown = true
	case interface.text_measured_width(table, interface.FONT_INTERFACE, word) <= room:
		text = word
	}
	if text != "" {
		interface.draw_text_right(table, x + PANEL_WIDTH - TEXT_MARGIN, y + (INPUT_BAND_HEIGHT - interface.LINE) / 2, text, graphics.colors.dim, interface.FONT_INTERFACE)
	}
	return mode_shown
}

// panel_draw appends the draw records of an open panel whose corner is at
// (x, y). The work is the 12 rows that the panel shows and a fixed count
// of other records: it does not grow with the entries.
//
// The input band is the top of the panel: its fill touches the top, the
// left and the right edge, and nothing is around it. The line of 2 pixels
// under it goes from edge to edge. The rest has a border of 1 pixel at the
// left, the right and the bottom.
panel_draw :: proc "contextless" (frame: ^interface.Frame, panel: ^Panel, x, y: int) {
	table := frame.table
	list := panel.list
	// What the pointer did to the scroll bar is of this draw only: a draw
	// that has no scroll bar leaves nothing for view_scrolled.
	panel.scrolled = {}
	with_form := panel.form.active && panel.state != .Result
	prefix, _ := prefix_of(typed_text(panel))
	// The band says the mode of the chosen entry in the search and in its
	// question; the footer says the act of Enter on it.
	if with_form {
		form_band_draw(frame, &panel.form, x, y)
	} else {
		interface.text_input_line(frame, {x, y, PANEL_WIDTH, INPUT_BAND_HEIGHT}, typed_text(panel), panel.line.caret, INPUT_SCALE, PLACEHOLDER)
		// At the right of the band: the word of the prefix, what the list
		// is restricted to, and the mode of the chosen entry.
		band_chosen: ^Entry
		if panel.state == .Search || panel.state == .Confirm {
			band_chosen = chosen_entry(panel)
		}
		band_words_draw(table, panel, band_chosen, prefix, x, y)
	}

	// Under the band: the border, as the menus of the bar have it, then
	// the surface of a card. The border has no top side: the line of the
	// band is the edge there.
	body_top := y + INPUT_BAND_HEIGHT
	body_height := PANEL_HEIGHT - INPUT_BAND_HEIGHT
	interface.draw_vertical_gradient(table, x, body_top, PANEL_WIDTH, body_height, graphics.shade(graphics.colors.kernel, 28), graphics.shade(graphics.colors.kernel, 14))
	interface.draw_vertical_gradient(table, x + BORDER, body_top, PANEL_WIDTH - 2 * BORDER, body_height - BORDER, graphics.colors.card_top, graphics.colors.card_bottom)
	if list == nil {
		return
	}
	text_room := PANEL_WIDTH - 2 * TEXT_MARGIN
	chosen := chosen_entry(panel)

	if panel.state == .Arguments || panel.state == .Confirm && with_form {
		form_list_draw(frame, panel, x, y)
	} else if panel.state == .Result || panel.state == .Running {
		// The list makes room for the entry that the panel sent: a new
		// list can come while the provider runs it.
		result_draw(frame, panel, x, y)
	} else {
		// The rows that the panel shows.
		list_area := scroll_view_area(x, y)
		confirm_text: interface.Text_Builder
		signatures: [LIST_ROWS][palette_table.SIGNATURE_CAPACITY + 8]u8
		rows: [LIST_ROWS]interface.List_Row
		setting_rows: [LIST_ROWS]int // The shown rows that are setting rows, as indexes in `rows`.
		setting_row_count := 0
		first := clamp(panel.first_row, 0, max(list.row_count - 1, 0))
		shown_count := clamp(list.row_count - first, 0, LIST_ROWS)
		chosen_shown := NO_ROW
		for index in 0 ..< shown_count {
			row := list.rows[first + index]
			switch row.kind {
			case .Heading_Recent:
				rows[index] = {kind = .Heading, name = HEADING_RECENT}
			case .Heading_Windows:
				rows[index] = {kind = .Heading, name = HEADING_WINDOWS}
			case .Heading_Modules:
				rows[index] = {kind = .Heading, name = HEADING_MODULES}
			case .Entry:
				entry := &list.entries[min(int(row.entry), ENTRY_CAPACITY - 1)]
				in_use := entry.kind == .Setting && setting_in_use(panel, entry)
				icon, icon_color := entry_icon(entry, in_use)
				rows[index] = {kind = .Entry, name = entry_name(entry), matched_places = transmute(u128)row.places, icon = icon, icon_color = icon_color, right_text = entry_words(entry)}
				if prefix := entry_hash_prefix(entry); prefix != "" {
					// A window of a disk process: the hash prefix of its
					// file, faded after its nickname, one cell apart, as the
					// menu of the windows shows it. A nickname that looks
					// like the name of another process is told apart.
					detail := signatures[index][:]
					detail[0] = ' '
					count := 1 + copy(detail[1:], prefix)
					rows[index].detail = string(detail[:count])
				}
				if entry_is_setting_row(entry) {
					// Its buttons are drawn over the row after the list:
					// the line under a value says which one is in use.
					setting_rows[setting_row_count] = index
					setting_row_count += 1
				} else if entry.kind == .Setting {
					// The value in use has its icon in the text color, and
					// says so in words.
					if in_use {
						rows[index].right_text = "setting, in use"
					}
				} else if given := given_of(list, entry); given != nil {
					// A command is code: its name in the font of the cells,
					// then its parameters and its result, quiet. A command
					// that the panel cannot run is dim.
					rows[index].name_in_cells = true
					rows[index].name_color = .Needs_Arguments in entry.flags ? graphics.Color(graphics.colors.dim) : graphics.code_class_color(.Name, graphics.appearance)
					// The room of the signature: the row, less its name and the
					// words at its right. It is cut at the end of a parameter.
					words_width := interface.text_measured_width(table, interface.FONT_INTERFACE, rows[index].right_text)
					room := list_area.width - (list.row_count > LIST_ROWS ? interface.LIST_ROW_SCROLL_WIDTH : 0) - interface.LIST_ROW_NAME_X - interface.LIST_ROW_RIGHT_MARGIN - words_width - 16 - int(given.name_length) * graphics.CELL_WIDTH
					rows[index].detail = signature_fit(string(given.signature[given.name_length:given.signature_length]), room / graphics.CELL_WIDTH, signatures[index][:])
				}
				if first + index == panel.choice {
					chosen_shown = index
					if panel.state == .Confirm {
						// The row says the act in full, and no letter is marked:
						// the text is no longer the name that the input searched.
						confirm_sentence(&confirm_text, list, entry)
						rows[index] = {kind = .Entry, name = interface.text_of(&confirm_text), icon = icon, icon_color = icon_color, right_text = rows[index].right_text}
					}
				}
			}
		}
		// The chosen row keeps its kind at its right, in white: two rows
		// with one name stay two things. What Enter does is in the footer.
		options := interface.List_Rows_Options{chosen = chosen_shown, first = first, total = list.row_count}
		if panel.state == .Confirm {
			options.chosen_color = graphics.colors.stop_process
		} else {
			// The scroll bar takes the pointer in the search. The question
			// of an entry that destroys keeps its row: its bar only shows.
			options.scroll_bar = scroll_bar_identity()
			options.scroll_bar_name = SCROLL_BAR_ELEMENT_NAME
			options.scrolled = &panel.scrolled
		}
		interface.list_of_rows(frame, list_area, rows[:shown_count], options)
		for shown in setting_rows[:setting_row_count] {
			entry := &list.entries[min(int(list.rows[first + shown].entry), ENTRY_CAPACITY - 1)]
			// The area of the row as list_of_rows drew it: the rows less the
			// scroll bar of a list that does not show each row.
			area := interface.Area{list_area.x, list_area.y + shown * ROW_HEIGHT, rows_right(x, list.row_count) - list_area.x, ROW_HEIGHT}
			value_buttons_draw(frame, panel, entry, area, rows[shown].right_text, shown == chosen_shown)
		}
		if list.row_count == 0 {
			// No entry has the typed part: one dim line says so.
			empty: interface.Text_Builder
			interface.text_put(&empty, "nothing has \"")
			interface.text_put(&empty, typed_text(panel))
			interface.text_put(&empty, "\" in its name")
			interface.draw_text(table, x + TEXT_MARGIN, y + LIST_TOP + 4, interface.text_fit(table, interface.FONT_INTERFACE, interface.text_of(&empty), text_room), graphics.colors.dim, interface.FONT_INTERFACE)
		}
		// The detail line: what the chosen entry does, whole.
		if chosen != nil {
			about: interface.Text_Builder
			if entry_is_setting_row(chosen) {
				// The line that the chosen value runs.
				if given := value_given(list, chosen, value_chosen(panel, chosen)); given != nil {
					interface.text_put(&about, string(given.about[:given.about_length]))
				}
			} else {
				entry_about(&about, list, chosen)
			}
			interface.draw_text(table, x + TEXT_MARGIN, y + DETAIL_TOP + 4, interface.text_fit(table, interface.FONT_INTERFACE, interface.text_of(&about), text_room), graphics.colors.dim, interface.FONT_INTERFACE)
		}
	}

	// The footer: at the right the keys of the state, with what Enter does
	// on the chosen entry, or the prefixes while nothing is typed; at the
	// left, in the search only, the count of the entries that match of all
	// the entries, and what the list lacks when the console gives no
	// commands. The count is a value: the font of the cells.
	keys: interface.Text_Builder
	switch panel.state {
	case .Closed, .Search:
		if len(typed_text(panel)) == 0 && list.provider == .Ready {
			// Nothing is typed: the footer teaches the prefixes. With no
			// provider two of them list nothing, and the footer says
			// what the list lacks.
			interface.text_put(&keys, KEYS_OF_PREFIXES)
		} else {
			interface.text_put(&keys, chosen != nil ? entry_hint(chosen, form_can_open(given_of(list, chosen)), prefix == .Manual) : "enter: run")
			interface.text_put(&keys, KEYS_END)
		}
	case .Confirm:
		interface.text_put(&keys, KEYS_OF_CONFIRM)
	case .Running:
		interface.text_put(&keys, KEYS_OF_RUNNING)
	case .Result:
		interface.text_put(&keys, KEYS_OF_RESULT)
	case .Arguments:
		interface.text_put(&keys, panel.form.field_count > 1 ? KEYS_OF_ARGUMENTS_MORE : KEYS_OF_ARGUMENTS)
	}
	keys_width := interface.text_measured_width(table, interface.FONT_INTERFACE, interface.text_of(&keys))
	interface.draw_text_right(table, x + PANEL_WIDTH - TEXT_MARGIN, y + FOOTER_TOP + 4, interface.text_of(&keys), graphics.colors.dim, interface.FONT_INTERFACE)
	if panel.state != .Search && panel.state != .Closed {
		return
	}
	count: interface.Text_Builder
	interface.text_put_number(&count, u64(list.matched_count))
	interface.text_put(&count, " of ")
	interface.text_put_number(&count, u64(list.entry_count))
	after := interface.draw_text(table, x + TEXT_MARGIN, y + FOOTER_TOP + 4, interface.text_of(&count), graphics.colors.text)
	words := WORD_OF_COUNT
	switch list.provider {
	case .Ready:
	case .Absent:
		words = NOTE_NO_PROVIDER
	case .Refused:
		words = NOTE_REFUSED_PROVIDER
	}
	words_room := x + PANEL_WIDTH - TEXT_MARGIN - keys_width - 16 - (after + 8)
	interface.draw_text(table, after + 8, y + FOOTER_TOP + 4, interface.text_fit(table, interface.FONT_INTERFACE, words, words_room), graphics.colors.dim, interface.FONT_INTERFACE)
}

// The classes of the characters of the band of a form.
@(private)
Band_Class :: enum u8 {
	Name, // The name of the command.
	Quiet, // Punctuation, and the name of a parameter that has not the caret.
	Label, // The name of the parameter that has the caret.
	Value, // What the input typed.
	Size_Unit, // The unit after the number of a field that counts a size.
	Time_Unit, // The unit after the number of a field that counts a time.
}

BAND_CAPACITY :: 512 // The characters of the band of a form: more than a name and six fields of 48 characters with their names.
BAND_CELL_WIDTH :: graphics.CELL_WIDTH * INPUT_SCALE // One character of the band.
BAND_CARET_WIDTH :: 2 * INPUT_SCALE // The caret of the band.

// The band of a form as characters: what the drawing draws and what the
// pointer points at. One layout serves both, so a press never lands on a
// place that the drawing shows elsewhere.
@(private)
Band_Layout :: struct {
	characters:   [BAND_CAPACITY]u8, // The call: "revoke(name: plasma, grant: )".
	classes:      [BAND_CAPACITY]Band_Class, // What each character is.
	count:        int, // The characters in use.
	caret:        int, // The character that the caret is before.
	field_starts: [FIELD_CAPACITY]int, // The first character of each field: of its name, or of its value when it has no name.
	value_starts: [FIELD_CAPACITY]int, // The first character of the value of each field.
	value_counts: [FIELD_CAPACITY]int, // The characters of the value of each field.
	first:        int, // The first character that the band shows: a call wider than the band shows the part that holds the caret.
	last:         int, // The character after the last one that the band shows.
}

@(private)
band_put :: proc "contextless" (band: ^Band_Layout, text: string, class: Band_Class) {
	for index in 0 ..< len(text) {
		if band.count < BAND_CAPACITY {
			band.characters[band.count] = text[index]
			band.classes[band.count] = class
			band.count += 1
		}
	}
}

// form_band_layout makes the characters of the band of a form, the places
// of its fields, and the part that the band shows.
@(private)
form_band_layout :: proc "contextless" (form: ^Form, band: ^Band_Layout) {
	band.count, band.caret = 0, 0
	band_put(band, entry_name(&form.entry), .Name)
	band_put(band, "(", .Quiet)
	for field in 0 ..< min(form.field_count, FIELD_CAPACITY) {
		if field > 0 {
			band_put(band, ", ", .Quiet)
		}
		band.field_starts[field] = band.count
		if name := field_name(form, field); name != "" {
			band_put(band, name, field == form.current ? Band_Class.Label : Band_Class.Quiet)
			band_put(band, ": ", .Quiet)
		}
		band.value_starts[field] = band.count
		if field == form.current {
			band.caret = band.count + clamp(form.fields[field].caret, 0, form.fields[field].count)
		}
		band_put(band, field_text(form, field), .Value)
		band.value_counts[field] = band.count - band.value_starts[field]
		// The unit stays while the field is empty: it says what to type.
		// A press on it puts the caret at the end of the number.
		band_put(band, field_unit_text(form, field), field_unit(form, field).kind == .Time ? Band_Class.Time_Unit : Band_Class.Size_Unit)
	}
	band_put(band, ")", .Quiet)
	band.caret = min(band.caret, band.count)
	fit := (PANEL_WIDTH - 2 * interface.TEXT_INPUT_LINE_MARGIN - BAND_CARET_WIDTH) / BAND_CELL_WIDTH
	band.first = band.count > fit ? clamp(band.caret - fit + 4, 0, band.count - fit) : 0
	band.last = min(band.first + fit, band.count)
}

// form_place_at gives the field of a form and the place of the caret in it
// for a point of the input band, for a panel whose left side is at
// panel_x: the place between two characters that is nearest to the point.
// A point on the name of a parameter gives the start of its field; a point
// on the punctuation after a field gives its end. ok is false for a point
// on the name of the command, or outside the part of the call that the band
// shows.
form_place_at :: proc "contextless" (form: ^Form, panel_x, x: int) -> (field: int, caret: int, ok: bool) {
	band: Band_Layout
	form_band_layout(form, &band)
	text_x := panel_x + interface.TEXT_INPUT_LINE_MARGIN
	if x < text_x {
		return 0, 0, false
	}
	place := band.first + (x - text_x + BAND_CELL_WIDTH / 2) / BAND_CELL_WIDTH
	fields := min(form.field_count, FIELD_CAPACITY)
	if place > band.last || fields == 0 || place < band.field_starts[0] {
		return 0, 0, false
	}
	for index := fields - 1; index >= 0; index -= 1 {
		if place >= band.field_starts[index] {
			return index, clamp(place - band.value_starts[index], 0, band.value_counts[index]), true
		}
	}
	return 0, 0, false
}

// The buttons of the field of a form whose control is a row of buttons
// (field_control): the shown candidates, in their order.
Form_Buttons :: struct {
	count:   int, // The buttons: the shown candidates. 0: the field has no row of buttons.
	areas:   [BUTTON_CAPACITY]interface.Area,
	in_band: bool, // In the input band at the right of the call; else on the first row under the band.
}

// form_buttons_layout places the buttons of the current field of a form,
// for a panel whose corner is at (x, y): in the input band at the right of
// the call when the band has the room, else on the first row under the
// band. A row that does not fit there either has no button: the field then
// shows the list of its candidates, which has room for each name.
form_buttons_layout :: proc "contextless" (table: ^interface.Draw_Table, form: ^Form, x, y: int) -> (buttons: Form_Buttons) {
	if field_control(form, form.current) != .Buttons || form.shown_count == 0 {
		return {}
	}
	count := min(form.shown_count, BUTTON_CAPACITY)
	widths: [BUTTON_CAPACITY]int
	total := 0
	for index in 0 ..< count {
		widths[index] = interface.text_measured_width(table, interface.FONT_INTERFACE, candidate_name(form, index)) + 2 * VALUE_BUTTON_PADDING
		total += widths[index] + (index > 0 ? VALUE_BUTTON_GAP : 0)
	}
	right := x + PANEL_WIDTH - TEXT_MARGIN
	band: Band_Layout
	form_band_layout(form, &band)
	start := x + interface.TEXT_INPUT_LINE_MARGIN + (band.last - band.first) * BAND_CELL_WIDTH + BAND_CARET_WIDTH + graphics.MARGIN
	top := y + (INPUT_BAND_HEIGHT - 2 - VALUE_BUTTON_HEIGHT) / 2
	buttons.in_band = start + total <= right
	if !buttons.in_band {
		start = x + TEXT_MARGIN
		top = y + LIST_TOP + VALUE_BUTTON_TOP
		if start + total > right {
			return {}
		}
	}
	for index in 0 ..< count {
		buttons.areas[index] = {start, top, widths[index], VALUE_BUTTON_HEIGHT}
		start += widths[index] + VALUE_BUTTON_GAP
	}
	buttons.count = count
	return buttons
}

// form_button_at gives the button of the current field of a form under a
// point of the screen, as an index in the shown candidates, or NO_ROW: the
// same layout as the drawing (form_buttons_layout), for a panel whose
// corner is at (panel_x, panel_y). table: the draw table of the last frame
// of the panel, for the measure of the names.
form_button_at :: proc "contextless" (panel: ^Panel, table: ^interface.Draw_Table, panel_x, panel_y, x, y: int) -> int {
	if panel.state != .Arguments || !panel.form.active {
		return NO_ROW
	}
	buttons := form_buttons_layout(table, &panel.form, panel_x, panel_y)
	for area, index in buttons.areas[:buttons.count] {
		if interface.area_contains(area, x, y) {
			return index
		}
	}
	return NO_ROW
}

// form_buttons_draw draws the buttons of the current field of a form: the
// chosen candidate filled. In the band, a button that is not chosen has
// the surface of a card, so it shows on the track of the band; under the
// band, the track. The name of each candidate is the element name of its
// button: a machine test presses "round_robin".
@(private)
form_buttons_draw :: proc "contextless" (frame: ^interface.Frame, form: ^Form, buttons: ^Form_Buttons) {
	table := frame.table
	for index in 0 ..< buttons.count {
		area := buttons.areas[index]
		interface.element_name(frame, area, candidate_name(form, index))
		chosen := index == form.candidate_choice
		fill := graphics.Color(buttons.in_band ? graphics.colors.card_top : graphics.colors.track)
		color := graphics.Color(graphics.colors.text)
		if chosen {
			fill, color = graphics.COLOR_WHITE, graphics.COLOR_INK
		}
		interface.draw_rectangle(table, area.x, area.y, area.width, area.height, fill)
		interface.draw_text(table, area.x + VALUE_BUTTON_PADDING, area.y + (area.height - interface.LINE) / 2, candidate_name(form, index), color, interface.FONT_INTERFACE)
	}
}

// form_band_draw draws the input band of a form: the call as code, at the
// scale of the typed part: the name of the command, then each parameter
// with its name and what the input typed in it, and the caret in the
// current field: "revoke(name: console, grant: |)". A call wider than the
// band shows the part that holds the caret.
@(private)
form_band_draw :: proc "contextless" (frame: ^interface.Frame, form: ^Form, x, y: int) {
	table := frame.table
	band: Band_Layout
	form_band_layout(form, &band)
	characters, classes := &band.characters, &band.classes
	caret, first, last := band.caret, band.first, band.last

	text_height := graphics.CELL_HEIGHT * INPUT_SCALE
	interface.draw_rectangle(table, x, y, PANEL_WIDTH, INPUT_BAND_HEIGHT - 2, graphics.colors.track)
	interface.draw_rectangle(table, x, y + INPUT_BAND_HEIGHT - 2, PANEL_WIDTH, 2, graphics.colors.title)
	text_x := x + interface.TEXT_INPUT_LINE_MARGIN
	text_y := y + (INPUT_BAND_HEIGHT - text_height) / 2
	interface.draw_rectangle(table, text_x + (caret - first) * BAND_CELL_WIDTH, text_y, BAND_CARET_WIDTH, text_height, graphics.colors.title)
	font := interface.Font{scale = INPUT_SCALE}
	// One text record for each run of one class.
	start := first
	for start < last {
		end := start + 1
		for end < last && classes[end] == classes[start] {
			end += 1
		}
		color: graphics.Color
		switch classes[start] {
		case .Name:
			color = graphics.code_class_color(.Name, graphics.appearance)
		case .Quiet:
			color = graphics.code_class_color(.Punctuation, graphics.appearance)
		case .Label:
			color = graphics.colors.text
		case .Value:
			color = graphics.colors.text_strong
		case .Size_Unit:
			color = graphics.value_kind_color(.Size, graphics.appearance)
		case .Time_Unit:
			color = graphics.value_kind_color(.Time, graphics.appearance)
		}
		interface.draw_text(table, text_x + (start - first) * BAND_CELL_WIDTH, text_y, string(characters[start:end]), color, font)
		start = end
	}
	// Each field that the band shows is an element: "field 1", from the
	// first character of its name to the end of its unit, as much of it as
	// the band shows. A press there puts the caret in it (form_place_at).
	// The number of a field has two digits at most.
	#assert(FIELD_CAPACITY <= 100)
	for field in 0 ..< min(form.field_count, FIELD_CAPACITY) {
		field_start := max(band.field_starts[field], first)
		field_end := min(band.value_starts[field] + band.value_counts[field] + len(field_unit_text(form, field)), last)
		if field_end <= field_start {
			continue
		}
		digits: [2]u8
		digit_count := 0
		if field >= 10 {
			digits[0] = u8('0' + field / 10)
			digit_count = 1
		}
		digits[digit_count] = u8('0' + field % 10)
		digit_count += 1
		area := interface.Area{text_x + (field_start - first) * BAND_CELL_WIDTH, y, (field_end - field_start) * BAND_CELL_WIDTH, INPUT_BAND_HEIGHT - 2}
		interface.element_name_joined(frame, area, "field", string(digits[:digit_count]))
	}
	// A field with a few closed values: its buttons at the right of the
	// call, when the band has the room.
	if buttons := form_buttons_layout(table, form, x, y); buttons.in_band {
		form_buttons_draw(frame, form, &buttons)
	}
}

// form_list_draw draws the list area and the detail line of a form: the
// candidates of the field that has the caret, the chosen one filled; and
// under them why a key or a field was refused, or the signature of the
// command. While the panel asks for a second Enter after a form, the list
// area has the one row that says the act.
@(private)
form_list_draw :: proc "contextless" (frame: ^interface.Frame, panel: ^Panel, x, y: int) {
	table := frame.table
	form := &panel.form
	list_area := scroll_view_area(x, y)
	text_room := PANEL_WIDTH - 2 * TEXT_MARGIN
	rows: [LIST_ROWS]interface.List_Row
	if panel.state == .Confirm {
		act: interface.Text_Builder
		interface.text_put(&act, entry_name(&form.entry))
		interface.text_put(&act, "(")
		for field in 0 ..< form.field_count {
			interface.text_put(&act, field > 0 ? ", " : "")
			interface.text_put(&act, field_text(form, field))
			interface.text_put(&act, field_unit_text(form, field))
		}
		interface.text_put(&act, "): ")
		interface.text_put(&act, string(form.given.about[:form.given.about_length]))
		rows[0] = {kind = .Entry, name = interface.text_of(&act), icon = kind_icons.cells_of_desktop_kind(.Stop), icon_color = icon_color_of_stop(), right_text = entry_words(&form.entry)}
		interface.list_of_rows(frame, list_area, rows[:1], {chosen = 0, chosen_color = graphics.colors.stop_process, total = 1})
		return
	}
	words := ""
	switch form.candidate_kind {
	case .None:
	case .Process:
		words = "process"
	case .Module:
		words = "module"
	case .Grant:
		words = "grant"
	case .Strategy:
		words = "strategy"
	case .Setting:
		words = "setting"
	}
	if buttons := form_buttons_layout(table, form, x, y); buttons.count > 0 {
		// A few closed values: a row of buttons in place of the list, in
		// the band or on the first row, and what the keys do under it.
		if !buttons.in_band {
			form_buttons_draw(frame, form, &buttons)
		}
		hint_top := buttons.in_band ? y + LIST_TOP + 4 : y + LIST_TOP + ROW_HEIGHT + 4
		interface.draw_text(table, x + TEXT_MARGIN, hint_top, interface.text_fit(table, interface.FONT_INTERFACE, WORDS_OF_BUTTONS, text_room), graphics.colors.dim, interface.FONT_INTERFACE)
	} else {
		candidates_icon, candidates_color := candidate_icon(form.candidate_kind)
		choice := form.candidate_choice
		first := candidates_first(form)
		shown_count := clamp(form.shown_count - first, 0, LIST_ROWS)
		for index in 0 ..< shown_count {
			rows[index] = {kind = .Entry, name = candidate_name(form, first + index), icon = candidates_icon, icon_color = candidates_color, right_text = words}
		}
		chosen_shown := choice >= first && choice < first + shown_count ? choice - first : NO_ROW
		interface.list_of_rows(frame, list_area, rows[:shown_count], {chosen = chosen_shown, first = first, total = form.shown_count, scroll_bar = scroll_bar_identity(), scrolled = &panel.scrolled, scroll_bar_name = SCROLL_BAR_ELEMENT_NAME})
	}
	if form.shown_count == 0 {
		prompt: interface.Text_Builder
		interface.text_put(&prompt, "type the value of ")
		name := field_name(form, form.current)
		interface.text_put(&prompt, name != "" ? name : "the parameter")
		interface.text_put(&prompt, field_is_integer(form, form.current) ? ": an Integer" : ": a Text")
		if unit_text := field_unit_text(form, form.current); unit_text != "" {
			interface.text_put(&prompt, ", in")
			interface.text_put(&prompt, unit_text)
		}
		interface.draw_text(table, x + TEXT_MARGIN, y + LIST_TOP + 4, interface.text_fit(table, interface.FONT_INTERFACE, interface.text_of(&prompt), text_room), graphics.colors.dim, interface.FONT_INTERFACE)
	}
	if message := form_message(form); message != "" {
		interface.draw_text(table, x + TEXT_MARGIN, y + DETAIL_TOP + 4, interface.text_fit(table, interface.FONT_INTERFACE, message, text_room), graphics.colors.failed, interface.FONT_INTERFACE)
		return
	}
	// The whole signature, as code, then the help sentence.
	signature := string(form.given.signature[:form.given.signature_length])
	after := interface.draw_text(table, x + TEXT_MARGIN, y + DETAIL_TOP + 4, interface.text_fit(table, {}, signature, text_room), graphics.code_class_color(.Punctuation, graphics.appearance))
	about := string(form.given.about[:form.given.about_length])
	interface.draw_text(table, after + 16, y + DETAIL_TOP + 4, interface.text_fit(table, interface.FONT_INTERFACE, about, x + TEXT_MARGIN + text_room - after - 16), graphics.colors.dim, interface.FONT_INTERFACE)
}

// result_draw draws, in the place of the list, the entry that the panel
// sent and what the provider gave: the call, then, while the panel waits,
// that it runs; after that the lines of the result, each run in the color of what it is.
// The one number of an Integer result is at three times the size of the
// font. The runs are a checked copy; the bounds are checked here once
// more, so a fault of the check draws less and reads nothing else.
@(private)
result_draw :: proc "contextless" (frame: ^interface.Frame, panel: ^Panel, x, y: int) {
	table := frame.table
	result := &panel.result
	call: interface.Text_Builder
	interface.text_put(&call, sent_text(panel))
	interface.text_put(&call, "()")
	after_call := interface.draw_text(table, x + TEXT_MARGIN, y + LIST_TOP + RESULT_CALL_TOP, interface.text_of(&call), graphics.code_class_color(.Name, graphics.appearance))
	if panel.state == .Running {
		interface.draw_text(table, after_call + 16, y + LIST_TOP + RESULT_CALL_TOP, WORDS_OF_RUNNING, graphics.colors.dim, interface.FONT_INTERFACE)
		return
	}
	runs := result.runs[:clamp(result.count, 0, len(result.runs))]
	large := result.outcome == .Shown_In_Panel && result.kind == .Integer
	place, line := 0, 0
	run_x := x + TEXT_MARGIN
	for place + 2 <= len(runs) && line < palette_table.RESULT_LINE_CAPACITY {
		part, length := runs[place], int(runs[place + 1])
		place += 2
		if part == u8(palette_table.Run_Part.End_Line) {
			line += 1
			run_x = x + TEXT_MARGIN
			continue
		}
		run_part, run_part_known := enum_word.member_of_word(palette_table.Run_Part, u64(part))
		if !run_part_known || part > u8(palette_table.RUN_PART_LAST) || length > len(runs) - place {
			return
		}
		text := string(runs[place:][:length])
		place += length
		line_y := y + LIST_TOP + RESULT_LINES_TOP + line * interface.LINE
		if large && line == 0 {
			run_x = interface.large_number(frame, run_x, line_y, text, part_color(run_part))
			continue
		}
		run_x = interface.draw_text(table, run_x, line_y, text, part_color(run_part))
	}
}

// window_title_of gives the title of the window of an entry: the name of a
// window entry, or the name of a close entry after its start.
window_title_of :: proc "contextless" (entry: ^Entry) -> string {
	name := entry_name(entry)
	if entry.kind == .Close_Window && len(name) >= len(CLOSE_NAME_START) {
		return name[len(CLOSE_NAME_START):]
	}
	return name
}

// confirm_sentence writes the text of the row that asks for a second
// Enter. It says the act in full: "stop plasma: its window closes" for the
// close of a window; the call and the help sentence of a command of a
// provider, "shutdown(): stop the machine".
@(private)
confirm_sentence :: proc "contextless" (builder: ^interface.Text_Builder, list: ^List, entry: ^Entry) {
	if entry.kind == .Close_Window {
		interface.text_put(builder, "stop ")
		interface.text_put(builder, window_title_of(entry))
		interface.text_put(builder, ": its window closes")
		return
	}
	interface.text_put(builder, entry_name(entry))
	interface.text_put(builder, "()")
	if given := given_of(list, entry); given != nil && given.about_length > 0 {
		interface.text_put(builder, ": ")
		interface.text_put(builder, string(given.about[:given.about_length]))
	}
}
