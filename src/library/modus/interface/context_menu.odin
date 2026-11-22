// Rich, filterable right-click context menu primitive with fuzzy subsequence
// matching and per-character highlight bitmasks for modus:interface
// (src/md/features/desktop_to_browser.md, "A. The desktop foundations").
//
// Any program or shell (compositor, console, editor, browser) can open a
// Context_Menu on right-click; typing filters entries live and marks the
// matched characters, Up/Down or the pointer chooses a row, Enter or a press
// on the row triggers it, Escape or a press outside closes the menu.
package interface

import "modus:display"
import "modus:graphics"

CONTEXT_MENU_MAX_ITEMS :: 32
CONTEXT_MENU_MAX_FILTER :: 32
CONTEXT_MENU_WIDTH :: 264
CONTEXT_MENU_ROW_HEIGHT :: 24
CONTEXT_MENU_HEADER_HEIGHT :: 36 // The filter field and its margins, with the line under them.
CONTEXT_MENU_FOOT :: 6 // Under the last row, so that its plate does not touch the border.
CONTEXT_MENU_FIELD_MARGIN :: 6 // Around the filter field, inside the card.
CONTEXT_MENU_ROW_INSET :: 3 // From the border of the card to the plate of a chosen row.
CONTEXT_MENU_TEXT_X :: 12 // From the left of the card to a label.
CONTEXT_MENU_SHORTCUT_GAP :: 16 // The least room between a label and its shortcut.
CONTEXT_MENU_SCREEN_MARGIN :: 4 // The menu stays this far inside the screen.

Context_Menu_Item :: struct {
	id:       u32,
	label:    string,
	shortcut: string, // A dim text at the right of the row: the keys that do the same act. Empty: none.
	disabled: bool,
}

Context_Menu_Match :: struct {
	item_index: int,
	score:      int,
	match_mask: u64, // Bit i = 1 when label[i] matched a query character.
}

Context_Menu_State :: struct {
	open:        bool,
	x, y:        int,
	items:       [CONTEXT_MENU_MAX_ITEMS]Context_Menu_Item,
	item_count:  int,
	filter:      [CONTEXT_MENU_MAX_FILTER]u8,
	filter_len:  int,
	matches:     [CONTEXT_MENU_MAX_ITEMS]Context_Menu_Match,
	match_count: int,
	selected:    int,
	chosen_id:   u32,
	has_chosen:  bool,
}

// What a pointer event did to an open context menu.
Context_Menu_Pointer_Result :: struct {
	consumed:     bool, // The pointer was over the menu: nothing under it receives the event.
	changed:      bool, // The menu draws differently: the chosen row moved, or the menu closed.
	triggered:    bool, // A press on a row that is not disabled chose it.
	triggered_id: u32,
}

@(private = "file")
ascii_lower_byte :: proc "contextless" (b: u8) -> u8 {
	if b >= 'A' && b <= 'Z' {
		return b + 32
	}
	return b
}

// context_menu_fuzzy_match matches query as a case-insensitive subsequence of
// label, scoring consecutive and word-boundary matches higher and returning a
// 64-bit character highlight mask for matched positions.
context_menu_fuzzy_match :: proc "contextless" (query: []u8, label: string) -> (matched: bool, score: int, mask: u64) {
	if len(query) == 0 {
		return true, 0, 0
	}
	qi := 0
	prev_match := -2
	for i := 0; i < len(label) && qi < len(query); i += 1 {
		if ascii_lower_byte(label[i]) == ascii_lower_byte(query[qi]) {
			if i < 64 {
				mask |= u64(1) << u32(i)
			}
			score += 10
			if i == prev_match + 1 {
				score += 15 // Consecutive character bonus.
			}
			if i == 0 || label[i - 1] == ' ' || label[i - 1] == '_' || label[i - 1] == '-' {
				score += 12 // Word-start bonus.
			}
			prev_match = i
			qi += 1
		}
	}
	if qi != len(query) {
		return false, 0, 0
	}
	score -= len(label) // Prefer tighter matches.
	return true, score, mask
}

context_menu_refilter :: proc "contextless" (m: ^Context_Menu_State) {
	if m == nil {
		return
	}
	m.match_count = 0
	q := m.filter[:m.filter_len]
	for i in 0 ..< m.item_count {
		ok, score, mask := context_menu_fuzzy_match(q, m.items[i].label)
		if !ok {
			continue
		}
		// Insertion sort by descending score (preserve original order on ties).
		pos := m.match_count
		for pos > 0 && m.matches[pos - 1].score < score {
			m.matches[pos] = m.matches[pos - 1]
			pos -= 1
		}
		m.matches[pos] = {item_index = i, score = score, match_mask = mask}
		m.match_count += 1
	}
	if m.match_count == 0 {
		m.selected = 0
	} else if m.selected >= m.match_count {
		m.selected = m.match_count - 1
	}
}

// context_menu_height gives the height of the card for its rows now: a
// filter that matches nothing keeps one row for the words "No match".
context_menu_height :: proc "contextless" (m: ^Context_Menu_State) -> int {
	rows := m == nil ? 1 : max(1, m.match_count)
	return CONTEXT_MENU_HEADER_HEIGHT + rows * CONTEXT_MENU_ROW_HEIGHT + CONTEXT_MENU_FOOT
}

// context_menu_open opens a filterable context menu clamped to screen bounds.
context_menu_open :: proc "contextless" (m: ^Context_Menu_State, x, y, screen_w, screen_h: int, items: []Context_Menu_Item) {
	if m == nil {
		return
	}
	m^ = {open = true}
	n := min(len(items), CONTEXT_MENU_MAX_ITEMS)
	for i in 0 ..< n {
		m.items[i] = items[i]
	}
	m.item_count = n
	context_menu_refilter(m)
	// The height with every item: a filter only shrinks the card from its foot.
	h := context_menu_height(m)
	m.x = clamp(x, CONTEXT_MENU_SCREEN_MARGIN, max(CONTEXT_MENU_SCREEN_MARGIN, screen_w - CONTEXT_MENU_WIDTH - CONTEXT_MENU_SCREEN_MARGIN))
	m.y = clamp(y, CONTEXT_MENU_SCREEN_MARGIN, max(CONTEXT_MENU_SCREEN_MARGIN, screen_h - h - CONTEXT_MENU_SCREEN_MARGIN))
}

context_menu_close :: proc "contextless" (m: ^Context_Menu_State) {
	if m == nil {
		return
	}
	m.open = false
}

// context_menu_contains reports whether a point is on the card of an open menu.
context_menu_contains :: proc "contextless" (m: ^Context_Menu_State, point_x, point_y: int) -> bool {
	if m == nil || !m.open {
		return false
	}
	return point_x >= m.x && point_x < m.x + CONTEXT_MENU_WIDTH && point_y >= m.y && point_y < m.y + context_menu_height(m)
}

// context_menu_row_rect gives the place of a row of the matches: the draw
// and the pointer read this one place, so a press lands on the row that the
// eye sees. ok is false for a row past the matches.
context_menu_row_rect :: proc "contextless" (m: ^Context_Menu_State, row: int) -> (x, y, width, height: int, ok: bool) {
	if m == nil || row < 0 || row >= m.match_count {
		return 0, 0, 0, 0, false
	}
	return m.x + CONTEXT_MENU_ROW_INSET, m.y + CONTEXT_MENU_HEADER_HEIGHT + row * CONTEXT_MENU_ROW_HEIGHT, CONTEXT_MENU_WIDTH - 2 * CONTEXT_MENU_ROW_INSET, CONTEXT_MENU_ROW_HEIGHT, true
}

// context_menu_row_at gives the row of the matches at a point, or -1: on
// the filter field, the foot, the border or outside the card.
context_menu_row_at :: proc "contextless" (m: ^Context_Menu_State, point_x, point_y: int) -> int {
	if m == nil || !m.open {
		return -1
	}
	for row in 0 ..< m.match_count {
		x, y, width, height, _ := context_menu_row_rect(m, row)
		if point_x >= x && point_x < x + width && point_y >= y && point_y < y + height {
			return row
		}
	}
	return -1
}

// context_menu_pointer takes a pointer event while the menu is open: the
// row under the pointer becomes the chosen row, a press on it triggers its
// item, and a press outside the card closes the menu and is not consumed, so
// that it goes on to what is under it.
context_menu_pointer :: proc "contextless" (m: ^Context_Menu_State, point_x, point_y: int, pressed: bool) -> (result: Context_Menu_Pointer_Result) {
	if m == nil || !m.open {
		return
	}
	if !context_menu_contains(m, point_x, point_y) {
		if pressed {
			m.open = false
			result.changed = true
		}
		return
	}
	result.consumed = true
	row := context_menu_row_at(m, point_x, point_y)
	if row >= 0 && row != m.selected {
		m.selected = row
		result.changed = true
	}
	if !pressed || row < 0 {
		return
	}
	item := m.items[m.matches[row].item_index]
	if item.disabled {
		return
	}
	m.chosen_id = item.id
	m.has_chosen = true
	m.open = false
	result.changed = true
	result.triggered = true
	result.triggered_id = item.id
	return
}

// context_menu_handle_key processes typing (live filter), Backspace, Up/Down,
// Enter (select & close), and Escape (cancel) while the menu is open.
context_menu_handle_key :: proc "contextless" (m: ^Context_Menu_State, code: u32, character: rune, pressed: bool) -> (consumed: bool, triggered_id: u32) {
	if m == nil || !m.open || !pressed {
		return false, 0
	}
	switch code {
	case display.KEY_ESCAPE:
		m.open = false
		return true, 0
	case display.KEY_UP:
		if m.match_count > 0 {
			m.selected = (m.selected + m.match_count - 1) % m.match_count
		}
		return true, 0
	case display.KEY_DOWN:
		if m.match_count > 0 {
			m.selected = (m.selected + 1) % m.match_count
		}
		return true, 0
	case display.KEY_ENTER:
		if m.match_count > 0 && m.selected < m.match_count {
			item := m.items[m.matches[m.selected].item_index]
			if !item.disabled {
				m.chosen_id = item.id
				m.has_chosen = true
				m.open = false
				return true, item.id
			}
		}
		return true, 0
	case display.KEY_BACKSPACE:
		if m.filter_len > 0 {
			m.filter_len -= 1
			context_menu_refilter(m)
		}
		return true, 0
	}
	if character >= 0x20 && character < 0x7F && m.filter_len < CONTEXT_MENU_MAX_FILTER {
		m.filter[m.filter_len] = u8(character)
		m.filter_len += 1
		context_menu_refilter(m)
		return true, 0
	}
	return true, 0
}

// context_menu_draw draws the menu as a card of the desktop: a vertical
// gradient with a line of light under its top border, the filter field with
// its caret and the line of the focus, a line under the field, then the
// matching rows. The chosen row is a plate in a gradient of the chosen blue
// with its own line of light; a matched character has a line of 2 pixels
// under it, as in the palette; a shortcut is dim at the right of its row.
context_menu_draw :: proc "contextless" (table: ^Draw_Table, m: ^Context_Menu_State) {
	if table == nil || m == nil || !m.open {
		return
	}
	total_h := context_menu_height(m)
	draw_vertical_gradient(table, m.x, m.y, CONTEXT_MENU_WIDTH, total_h, graphics.colors.card_top, graphics.colors.card_bottom)
	draw_outline(table, m.x, m.y, CONTEXT_MENU_WIDTH, total_h, 1, graphics.colors.title)
	draw_rectangle(table, m.x + 1, m.y + 1, CONTEXT_MENU_WIDTH - 2, 1, graphics.shade(graphics.colors.card_top, 135))

	// The filter field has the focus while the menu is open: the line of
	// the focus is always drawn, with the caret at the end of the filter.
	field_frame := Frame{table = table}
	field := Area{m.x + CONTEXT_MENU_FIELD_MARGIN, m.y + CONTEXT_MENU_FIELD_MARGIN, CONTEXT_MENU_WIDTH - 2 * CONTEXT_MENU_FIELD_MARGIN, CONTEXT_MENU_HEADER_HEIGHT - 2 * CONTEXT_MENU_FIELD_MARGIN - 1}
	filter_text := string(m.filter[:m.filter_len])
	text_input_line(&field_frame, field, filter_text, len(filter_text), 0, "Type to filter", name = "filter")
	draw_rectangle(table, m.x + 1, m.y + CONTEXT_MENU_HEADER_HEIGHT - 1, CONTEXT_MENU_WIDTH - 2, 1, graphics.colors.track)

	if m.match_count == 0 {
		draw_text(table, m.x + CONTEXT_MENU_TEXT_X, m.y + CONTEXT_MENU_HEADER_HEIGHT + 4, "No match", graphics.colors.dim, FONT_INTERFACE)
		return
	}
	for row in 0 ..< m.match_count {
		match := m.matches[row]
		item := m.items[match.item_index]
		row_x, row_y, row_width, row_height, _ := context_menu_row_rect(m, row)
		chosen := row == m.selected
		if chosen {
			draw_vertical_gradient(table, row_x, row_y, row_width, row_height, graphics.colors.chosen, graphics.shade(graphics.colors.chosen, 86))
			draw_rectangle(table, row_x + 1, row_y, row_width - 2, 1, graphics.shade(graphics.colors.chosen, 140))
		}
		label_color := item.disabled ? graphics.colors.dim : (chosen ? graphics.COLOR_WHITE : graphics.colors.text)
		label_x := m.x + CONTEXT_MENU_TEXT_X
		label_room := m.x + CONTEXT_MENU_WIDTH - CONTEXT_MENU_TEXT_X - label_x
		// The shortcut takes its room first, the label the rest; a shortcut
		// that leaves the label no room is not drawn.
		if item.shortcut != "" {
			shortcut_width := text_measured_width(table, FONT_INTERFACE, item.shortcut)
			if shortcut_width + CONTEXT_MENU_SHORTCUT_GAP < label_room {
				draw_text_right(table, m.x + CONTEXT_MENU_WIDTH - CONTEXT_MENU_TEXT_X, row_y + 4, item.shortcut, chosen ? graphics.COLOR_WHITE : graphics.colors.dim, FONT_INTERFACE)
				label_room -= shortcut_width + CONTEXT_MENU_SHORTCUT_GAP
			}
		}
		label := text_fit(table, FONT_INTERFACE, item.label, label_room)
		draw_text(table, label_x, row_y + 4, label, label_color, FONT_INTERFACE)
		if m.filter_len == 0 || match.match_mask == 0 {
			continue
		}
		// A line under each run of matched characters of the label shown,
		// in the color of the kernel, white on the chosen row.
		for run in matched_runs(label, u128(match.match_mask)) {
			if run.end <= run.start {
				break
			}
			start_x := text_measured_width(table, FONT_INTERFACE, label[:run.start])
			end_x := text_measured_width(table, FONT_INTERFACE, label[:run.end])
			draw_rectangle(table, label_x + start_x, row_y + 20, end_x - start_x, 2, chosen ? graphics.COLOR_WHITE : graphics.colors.kernel)
		}
	}
}
