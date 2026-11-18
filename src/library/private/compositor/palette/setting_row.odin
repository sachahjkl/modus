package palette

import "modus:contract/palette_table"
import "modus:support/graphics"
import "modus:support/interface"

// The setting row
// (src/md/features/palette.md, "The form of an entry, from its descriptions"):
// the entries of one setting, side by side in the table
// of the provider, are one row of the list. The row has the name of the
// setting, then one button for each value; the value in use has a line
// under its name; on the chosen row, the value that Enter sets is filled.
// Left and Right choose it. Enter sends the entry of that value to the
// provider, as the panel sends one entry: the provider and its checks see
// no row.

VALUE_BUTTON_PADDING :: 8 // From a side of a button to its name.
VALUE_BUTTON_GAP :: 8 // Between two buttons.
VALUE_BUTTON_TOP :: 2 // From the top of the row to the top of a button.
VALUE_BUTTON_HEIGHT :: ROW_HEIGHT - 2 * VALUE_BUTTON_TOP
VALUE_TEXT_TOP :: 4 // From the top of the row to its text: the text of each row is there.
VALUE_MARK_TOP :: 20 // From the top of the row to the line that marks the value in use: under the text, inside the button.

#assert(VALUE_MARK_TOP + 2 <= VALUE_BUTTON_TOP + VALUE_BUTTON_HEIGHT)

// value_given gives the record of the provider for one value of a setting
// row, in the checked copy of its table; nil for a value past the row.
value_given :: proc "contextless" (list: ^List, entry: ^Entry, value: int) -> ^palette_table.Entry {
	if !entry_is_setting_row(entry) || value < 0 || value >= int(entry.value_count) {
		return nil
	}
	index := int(entry.number) + value
	if index >= list.snapshot.entry_count {
		return nil
	}
	return &list.snapshot.entries[index]
}

// value_name gives the name of one value of a setting row: the name of its
// button.
value_name :: proc "contextless" (list: ^List, entry: ^Entry, value: int) -> string {
	given := value_given(list, entry, value)
	if given == nil {
		return ""
	}
	return string(given.value_name[:min(int(given.value_name_length), palette_table.VALUE_NAME_CAPACITY)])
}

// value_in_use says if the machine uses one value of a setting row now: a
// setting of the machine from the values that the owner of the panel gave;
// a value that only the provider knows from its flag In_Use.
value_in_use :: proc "contextless" (panel: ^Panel, entry: ^Entry, value: int) -> bool {
	given := value_given(panel.list, entry, value)
	if given == nil {
		return false
	}
	if given.kind == u8(palette_table.Entry_Kind.Provider_Setting) {
		return .In_Use in given.flags
	}
	return given.kind == u8(palette_table.Entry_Kind.Setting) && int(given.setting) < len(panel.settings_in_use) && panel.settings_in_use[given.setting] == given.setting_value
}

// value_chosen gives the value that Enter sets on a setting row: the value
// that Left and Right chose on this row, or else the value in use, or else
// the first one.
value_chosen :: proc "contextless" (panel: ^Panel, entry: ^Entry) -> int {
	if !entry_is_setting_row(entry) {
		return 0
	}
	if panel.value_row_length > 0 && string(panel.value_row[:min(panel.value_row_length, NAME_CAPACITY)]) == entry_name(entry) {
		return clamp(panel.value_choice, 0, int(entry.value_count) - 1)
	}
	for value in 0 ..< int(entry.value_count) {
		if value_in_use(panel, entry, value) {
			return value
		}
	}
	return 0
}

// value_set chooses one value of a setting row.
value_set :: proc "contextless" (panel: ^Panel, entry: ^Entry, value: int) {
	panel.value_row_length = copy(panel.value_row[:], entry_name(entry))
	panel.value_choice = clamp(value, 0, max(int(entry.value_count) - 1, 0))
}

// value_move moves the chosen value of the chosen setting row: step 1 the
// next value, -1 the value before, from the last to the first and back. It
// gives true when the value changed.
value_move :: proc "contextless" (panel: ^Panel, step: int) -> bool {
	entry := chosen_entry(panel)
	if entry == nil || !entry_is_setting_row(entry) || entry.value_count < 2 {
		return false
	}
	count := int(entry.value_count)
	value_set(panel, entry, (value_chosen(panel, entry) + step + count) % count)
	return true
}

// entry_sent gives what the panel sends to the provider for an entry: its
// index in the snapshot and its name, whose hash the provider checks. A
// setting row sends the entry of its chosen value. The name is valid while
// the list is.
entry_sent :: proc "contextless" (panel: ^Panel, entry: ^Entry) -> (number: u32, name: string) {
	if entry_is_setting_row(entry) {
		value := value_chosen(panel, entry)
		if given := value_given(panel.list, entry, value); given != nil {
			return entry.number + u32(value), string(given.name[:given.name_length])
		}
	}
	return entry.number, entry_name(entry)
}

// The buttons of one setting row, as the drawing and the pointer read them:
// one layout serves both.
Value_Buttons :: struct {
	count: int, // The buttons that fit the row, from the first value.
	areas: [BUTTON_CAPACITY]interface.Area, // The area of each one.
	rest:  interface.Area, // The place of the count of the values that do not fit. Width 0: each value fits.
}

// value_buttons_layout places the buttons of a setting row in the area of
// its row: after its name, and before the words at its right, each button
// as wide as its name and two paddings. A button that does not fit is not
// drawn: the count of those values takes its place, when it fits.
value_buttons_layout :: proc "contextless" (table: ^interface.Draw_Table, list: ^List, entry: ^Entry, row: interface.Area, right_text: string) -> (buttons: Value_Buttons) {
	name_room := row.width - interface.LIST_ROW_NAME_X - interface.LIST_ROW_RIGHT_MARGIN
	right := row.x + row.width - interface.LIST_ROW_RIGHT_MARGIN
	if right_text != "" {
		// list_of_rows draws the words only when they leave 16 pixels.
		right_width := interface.text_measured_width(table, interface.FONT_INTERFACE, right_text)
		if right_width <= name_room - 16 {
			right -= right_width + 16
		}
	}
	name_width := interface.text_measured_width(table, interface.FONT_INTERFACE, entry_name(entry))
	x := row.x + interface.LIST_ROW_NAME_X + name_width + graphics.MARGIN
	count := min(int(entry.value_count), BUTTON_CAPACITY)
	for value in 0 ..< count {
		width := interface.text_measured_width(table, interface.FONT_INTERFACE, value_name(list, entry, value)) + 2 * VALUE_BUTTON_PADDING
		if x + width > right {
			// The count of the values left, in words that fit: "+2".
			rest: interface.Text_Builder
			interface.text_put(&rest, "+")
			interface.text_put_number(&rest, u64(count - value))
			rest_width := interface.text_measured_width(table, interface.FONT_INTERFACE, interface.text_of(&rest))
			if x + rest_width <= right {
				buttons.rest = {x, row.y + VALUE_BUTTON_TOP, rest_width, VALUE_BUTTON_HEIGHT}
			}
			break
		}
		buttons.areas[value] = {x, row.y + VALUE_BUTTON_TOP, width, VALUE_BUTTON_HEIGHT}
		buttons.count += 1
		x += width + VALUE_BUTTON_GAP
	}
	return buttons
}

// value_buttons_draw draws the buttons of one setting row whose row is in
// the area row. chosen: the row is the chosen row, so the value that Enter
// sets is filled. The line under a name says the value in use: a form, so
// the fact does not stand on a color alone.
value_buttons_draw :: proc "contextless" (frame: ^interface.Frame, panel: ^Panel, entry: ^Entry, row: interface.Area, right_text: string, chosen: bool) {
	table := frame.table
	buttons := value_buttons_layout(table, panel.list, entry, row, right_text)
	choice := value_chosen(panel, entry)
	for value in 0 ..< buttons.count {
		area := buttons.areas[value]
		filled := chosen && value == choice
		fill := filled ? graphics.Color(graphics.COLOR_WHITE) : graphics.Color(graphics.colors.track)
		in_use := value_in_use(panel, entry, value)
		color := graphics.Color(graphics.colors.text)
		switch {
		case filled:
			color = graphics.COLOR_INK
		case in_use:
			color = graphics.colors.text_strong
		}
		interface.draw_rectangle(table, area.x, area.y, area.width, area.height, fill)
		name := value_name(panel.list, entry, value)
		text_x := area.x + VALUE_BUTTON_PADDING
		after := interface.draw_text(table, text_x, row.y + VALUE_TEXT_TOP, name, color, interface.FONT_INTERFACE)
		if in_use {
			interface.draw_rectangle(table, text_x, row.y + VALUE_MARK_TOP, after - text_x, 2, color)
		}
	}
	if buttons.rest.width > 0 {
		rest: interface.Text_Builder
		interface.text_put(&rest, "+")
		interface.text_put_number(&rest, u64(int(entry.value_count) - buttons.count))
		interface.draw_text(table, buttons.rest.x, row.y + VALUE_TEXT_TOP, interface.text_of(&rest), chosen ? graphics.Color(graphics.COLOR_WHITE) : graphics.Color(graphics.colors.dim), interface.FONT_INTERFACE)
	}
}

// row_area gives the area of a row of the list that the panel shows, for
// a panel whose corner is at (panel_x, panel_y): the width of the rows, less
// the scroll bar of a list that does not show each row.
row_area :: proc "contextless" (panel: ^Panel, panel_x, panel_y, row: int) -> interface.Area {
	// The first row as panel_draw clamps it, so the drawing and the
	// pointer read one place.
	first := clamp(panel.first_row, 0, max(panel.list.row_count - 1, 0))
	return {panel_x + BORDER, panel_y + LIST_TOP + (row - first) * ROW_HEIGHT, rows_right(panel_x, panel.list.row_count) - panel_x - BORDER, ROW_HEIGHT}
}

// value_at gives the setting row and its value under a point of the
// screen, or NO_ROW: the same layout as the drawing (value_buttons_layout).
// table: the draw table of the panel, for the measure of the names.
value_at :: proc "contextless" (panel: ^Panel, table: ^interface.Draw_Table, panel_x, panel_y, x, y: int) -> (row: int, value: int) {
	row = row_at(panel, panel_x, panel_y, x, y)
	if !row_is_entry(panel, row) {
		return NO_ROW, NO_ROW
	}
	entry := &panel.list.entries[panel.list.rows[row].entry]
	if !entry_is_setting_row(entry) {
		return NO_ROW, NO_ROW
	}
	buttons := value_buttons_layout(table, panel.list, entry, row_area(panel, panel_x, panel_y, row), entry_words(entry))
	for area, index in buttons.areas[:buttons.count] {
		if interface.area_contains(area, x, y) {
			return row, index
		}
	}
	return NO_ROW, NO_ROW
}
