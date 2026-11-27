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

// Plan value: caps a single context menu to 32 entries without heap allocation.
CONTEXT_MENU_MAX_ITEMS :: 32
// Plan value: caps live fuzzy filter queries in filterable context menus.
CONTEXT_MENU_MAX_FILTER :: 32
// Plan value: width of a filterable desktop context menu holding label + shortcut in Spleen 8x16.
CONTEXT_MENU_WIDTH :: 264
// Plan value: width of a compact right-click menu; holds "Snap right" + "Ctrl+Shift+Right" (224 px) in Spleen 8x16 within 232 px label room.
CONTEXT_MENU_COMPACT_WIDTH :: 256
// Plan value: row height (16 px text + 5 px vertical padding each side) for crisp pointer targets.
CONTEXT_MENU_ROW_HEIGHT :: 26
// Plan value: height of the filter field, its margins, and the hairline under it.
CONTEXT_MENU_HEADER_HEIGHT :: 36
// Plan value: top inset for compact right-click menus without a filter field.
CONTEXT_MENU_COMPACT_HEAD :: 6
// Plan value: vertical space for a 1 px divider between groups.
CONTEXT_MENU_SEPARATOR_HEIGHT :: 7
// Plan value: bottom inset under the last row so its plate does not touch the border.
CONTEXT_MENU_FOOT :: 6
// Plan value: margin around the filter field inside the card.
CONTEXT_MENU_FIELD_MARGIN :: 6
// Plan value: horizontal inset from the card border to the highlight plate of a chosen row.
CONTEXT_MENU_ROW_INSET :: 4
// Plan value: horizontal inset from the left of the card to a label.
CONTEXT_MENU_TEXT_X :: 12
// Plan value: least horizontal room between a label and its shortcut.
CONTEXT_MENU_SHORTCUT_GAP :: 16
// Plan value: margin keeping a menu inside the screen or window edges.
CONTEXT_MENU_SCREEN_MARGIN :: 4
// Plan value: sharp drop shadow offset under floating menus (docs/DESIGN.md, "3. Surfaces").
CONTEXT_MENU_SHADOW_OFFSET :: 3

Context_Menu_Item :: struct {
	id:               u32,
	label:            string,
	shortcut:         string, // A dim text at the right of the row: the keys that do the same act. Empty: none.
	disabled:         bool,
	danger:           bool, // Draws destructive actions (Close, Delete) in the failure/coral accent.
	separator_before: bool, // Draws a 1 px horizontal divider above this row when not the first visible row.
}

Context_Menu_Match :: struct {
	item_index: int,
	score:      int,
	match_mask: u64, // Bit i = 1 when label[i] matched a query character.
}

Context_Menu_State :: struct {
	open:        bool,
	compact:     bool, // True for crisp right-click menus without a search header.
	x, y:        int,
	width:       int,
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

@(private = "file")
context_menu_header_height :: proc "contextless" (m: ^Context_Menu_State) -> int {
	if m != nil && m.compact {
		return CONTEXT_MENU_COMPACT_HEAD
	}
	return CONTEXT_MENU_HEADER_HEIGHT
}

@(private = "file")
context_menu_card_width :: proc "contextless" (m: ^Context_Menu_State) -> int {
	if m != nil && m.width > 0 {
		return m.width
	}
	return (m != nil && m.compact) ? CONTEXT_MENU_COMPACT_WIDTH : CONTEXT_MENU_WIDTH
}

@(private = "file")
context_menu_row_has_separator :: proc "contextless" (m: ^Context_Menu_State, row: int) -> bool {
	if m == nil || row <= 0 || row >= m.match_count || m.filter_len > 0 {
		return false
	}
	return m.items[m.matches[row].item_index].separator_before
}

// context_menu_height gives the height of the card for its rows now: a
// filter that matches nothing keeps one row for the words "No match".
context_menu_height :: proc "contextless" (m: ^Context_Menu_State) -> int {
	rows := m == nil ? 1 : max(1, m.match_count)
	seps := 0
	if m != nil {
		for row in 1 ..< m.match_count {
			if context_menu_row_has_separator(m, row) {
				seps += 1
			}
		}
	}
	return context_menu_header_height(m) + rows * CONTEXT_MENU_ROW_HEIGHT + seps * CONTEXT_MENU_SEPARATOR_HEIGHT + CONTEXT_MENU_FOOT
}

// context_menu_open opens a filterable context menu clamped to screen bounds.
context_menu_open :: proc "contextless" (m: ^Context_Menu_State, x, y, screen_w, screen_h: int, items: []Context_Menu_Item) {
	context_menu_open_mode(m, x, y, screen_w, screen_h, items, false)
}

// context_menu_open_compact opens a sleek right-click menu without a search
// field at the top, suited for app and titlebar action menus.
context_menu_open_compact :: proc "contextless" (m: ^Context_Menu_State, x, y, screen_w, screen_h: int, items: []Context_Menu_Item) {
	context_menu_open_mode(m, x, y, screen_w, screen_h, items, true)
}

@(private = "file")
context_menu_open_mode :: proc "contextless" (m: ^Context_Menu_State, x, y, screen_w, screen_h: int, items: []Context_Menu_Item, compact: bool) {
	if m == nil {
		return
	}
	w := compact ? CONTEXT_MENU_COMPACT_WIDTH : CONTEXT_MENU_WIDTH
	m^ = {open = true, compact = compact, width = w}
	n := min(len(items), CONTEXT_MENU_MAX_ITEMS)
	for i in 0 ..< n {
		m.items[i] = items[i]
	}
	m.item_count = n
	context_menu_refilter(m)
	// The height with every item: a filter only shrinks the card from its foot.
	h := context_menu_height(m)
	m.x = clamp(x, CONTEXT_MENU_SCREEN_MARGIN, max(CONTEXT_MENU_SCREEN_MARGIN, screen_w - w - CONTEXT_MENU_SCREEN_MARGIN))
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
	w := context_menu_card_width(m)
	return point_x >= m.x && point_x < m.x + w && point_y >= m.y && point_y < m.y + context_menu_height(m)
}

// context_menu_row_rect gives the place of a row of the matches: the draw
// and the pointer read this one place, so a press lands on the row that the
// eye sees. ok is false for a row past the matches.
context_menu_row_rect :: proc "contextless" (m: ^Context_Menu_State, row: int) -> (x, y, width, height: int, ok: bool) {
	if m == nil || row < 0 || row >= m.match_count {
		return 0, 0, 0, 0, false
	}
	y_pos := m.y + context_menu_header_height(m)
	for r in 0 ..= row {
		if context_menu_row_has_separator(m, r) {
			y_pos += CONTEXT_MENU_SEPARATOR_HEIGHT
		}
		if r < row {
			y_pos += CONTEXT_MENU_ROW_HEIGHT
		}
	}
	w := context_menu_card_width(m)
	return m.x + CONTEXT_MENU_ROW_INSET, y_pos, w - 2 * CONTEXT_MENU_ROW_INSET, CONTEXT_MENU_ROW_HEIGHT, true
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

// context_menu_row_enabled reports whether match row is valid and clickable.
context_menu_row_enabled :: proc "contextless" (m: ^Context_Menu_State, row: int) -> bool {
	if m == nil || !m.open || row < 0 || row >= m.match_count {
		return false
	}
	return !m.items[m.matches[row].item_index].disabled
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
context_menu_handle_key :: proc "contextless" (m: ^Context_Menu_State, code: u32, character: rune, pressed: bool, modifiers: u32 = 0) -> (consumed: bool, triggered_id: u32) {
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
	no_cmd_mod := modifiers & (display.MODIFIER_CONTROL | display.MODIFIER_ALT) == 0
	if !m.compact && no_cmd_mod && character >= 0x20 && character < 0x7F && m.filter_len < CONTEXT_MENU_MAX_FILTER {
		m.filter[m.filter_len] = u8(character)
		m.filter_len += 1
		context_menu_refilter(m)
		return true, 0
	}
	return true, 0
}

// context_menu_draw draws the menu as a floating card with a sharp drop shadow,
// crisp edge outline, optional filter field, optional group dividers, and danger
// styling for destructive items.
context_menu_draw :: proc "contextless" (table: ^Draw_Table, m: ^Context_Menu_State) {
	if table == nil || m == nil || !m.open {
		return
	}
	card_w := context_menu_card_width(m)
	total_h := context_menu_height(m)
	// Sharp drop shadow (docs/DESIGN.md, "3. Surfaces").
	draw_rectangle(table, m.x + CONTEXT_MENU_SHADOW_OFFSET, m.y + CONTEXT_MENU_SHADOW_OFFSET, card_w, total_h, graphics.colors.shadow)
	draw_vertical_gradient(table, m.x, m.y, card_w, total_h, graphics.colors.card_top, graphics.colors.card_bottom)
	draw_outline(table, m.x, m.y, card_w, total_h, 1, graphics.colors.edge)
	draw_rectangle(table, m.x + 1, m.y + 1, card_w - 2, 1, graphics.shade(graphics.colors.card_top, 130))

	if !m.compact {
		// The filter field has the focus while the menu is open: the line of
		// the focus is always drawn, with the caret at the end of the filter.
		field_frame := Frame{table = table}
		field := Area{m.x + CONTEXT_MENU_FIELD_MARGIN, m.y + CONTEXT_MENU_FIELD_MARGIN, card_w - 2 * CONTEXT_MENU_FIELD_MARGIN, CONTEXT_MENU_HEADER_HEIGHT - 2 * CONTEXT_MENU_FIELD_MARGIN - 1}
		filter_text := string(m.filter[:m.filter_len])
		text_input_line(&field_frame, field, filter_text, len(filter_text), 0, "Type to filter", name = "filter")
		draw_rectangle(table, m.x + 1, m.y + CONTEXT_MENU_HEADER_HEIGHT - 1, card_w - 2, 1, graphics.colors.track)
	}

	if m.match_count == 0 {
		draw_text(table, m.x + CONTEXT_MENU_TEXT_X, m.y + context_menu_header_height(m) + 4, "No match", graphics.colors.dim, FONT_INTERFACE)
		return
	}
	for row in 0 ..< m.match_count {
		match := m.matches[row]
		item := m.items[match.item_index]
		row_x, row_y, row_width, row_height, _ := context_menu_row_rect(m, row)
		if context_menu_row_has_separator(m, row) {
			sep_y := row_y - CONTEXT_MENU_SEPARATOR_HEIGHT / 2 - 1
			draw_rectangle(table, m.x + 8, sep_y, card_w - 16, 1, graphics.colors.track)
		}
		chosen := row == m.selected && !item.disabled
		if chosen {
			plate_col := item.danger ? graphics.colors.stop_process : graphics.colors.chosen
			draw_vertical_gradient(table, row_x, row_y, row_width, row_height, plate_col, graphics.shade(plate_col, 86))
			draw_rectangle(table, row_x + 1, row_y, row_width - 2, 1, graphics.shade(plate_col, 136))
		}
		label_color: graphics.Color
		switch {
		case item.disabled:
			label_color = graphics.colors.dim
		case chosen:
			label_color = graphics.COLOR_WHITE
		case item.danger:
			label_color = graphics.colors.failed
		case:
			label_color = graphics.colors.text
		}
		label_x := m.x + CONTEXT_MENU_TEXT_X
		label_room := m.x + card_w - CONTEXT_MENU_TEXT_X - label_x
		text_y := row_y + (row_height - LINE) / 2
		// The shortcut takes its room first, the label the rest; a shortcut
		// that leaves the label no room is not drawn.
		if item.shortcut != "" {
			shortcut_width := text_measured_width(table, FONT_INTERFACE, item.shortcut)
			if shortcut_width + CONTEXT_MENU_SHORTCUT_GAP < label_room {
				draw_text_right(table, m.x + card_w - CONTEXT_MENU_TEXT_X, text_y, item.shortcut, chosen ? graphics.COLOR_WHITE : graphics.colors.dim, FONT_INTERFACE)
				label_room -= shortcut_width + CONTEXT_MENU_SHORTCUT_GAP
			}
		}
		label := text_fit(table, FONT_INTERFACE, item.label, label_room)
		draw_text(table, label_x, text_y, label, label_color, FONT_INTERFACE)
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
			draw_rectangle(table, label_x + start_x, text_y + LINE, end_x - start_x, 2, chosen ? graphics.COLOR_WHITE : graphics.colors.kernel)
		}
	}
}
