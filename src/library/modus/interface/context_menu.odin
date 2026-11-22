// Rich, filterable right-click context menu primitive with fuzzy subsequence
// matching and per-character highlight bitmasks for modus:interface
// (src/md/features/desktop_to_browser.md, "A. The desktop foundations").
//
// Any program or shell (compositor, console, editor, browser) can open a
// Context_Menu on right-click; typing filters entries live and highlights
// matched characters, Up/Down navigates, Enter triggers, Escape closes.
package interface

import "modus:display"
import "modus:graphics"

CONTEXT_MENU_MAX_ITEMS :: 32
CONTEXT_MENU_MAX_FILTER :: 32
CONTEXT_MENU_WIDTH :: 232
CONTEXT_MENU_ROW_HEIGHT :: 24
CONTEXT_MENU_HEADER_HEIGHT :: 28

Context_Menu_Item :: struct {
	id:       u32,
	label:    string,
	shortcut: string,
	disabled: bool,
}

Context_Menu_Match :: struct {
	item_index: int,
	score:      int,
	match_mask: u64, // Bit i = 1 when label[i] matched a query character.
}

Context_Menu_State :: struct {
	open:           bool,
	x, y:           int,
	items:          [CONTEXT_MENU_MAX_ITEMS]Context_Menu_Item,
	item_count:     int,
	filter:         [CONTEXT_MENU_MAX_FILTER]u8,
	filter_len:     int,
	matches:        [CONTEXT_MENU_MAX_ITEMS]Context_Menu_Match,
	match_count:    int,
	selected:       int,
	chosen_id:      u32,
	has_chosen:     bool,
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
	h := CONTEXT_MENU_HEADER_HEIGHT + max(1, m.match_count) * CONTEXT_MENU_ROW_HEIGHT + 8
	m.x = clamp(x, 4, max(4, screen_w - CONTEXT_MENU_WIDTH - 4))
	m.y = clamp(y, 4, max(4, screen_h - h - 4))
}

context_menu_close :: proc "contextless" (m: ^Context_Menu_State) {
	if m == nil {
		return
	}
	m.open = false
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

// context_menu_draw renders the filter bar and matching rows with highlighted
// fuzzy-matched characters directly into table.
context_menu_draw :: proc "contextless" (table: ^Draw_Table, m: ^Context_Menu_State) {
	if table == nil || m == nil || !m.open {
		return
	}
	rows := max(1, m.match_count)
	total_h := CONTEXT_MENU_HEADER_HEIGHT + rows * CONTEXT_MENU_ROW_HEIGHT + 6
	draw_rectangle(table, m.x, m.y, CONTEXT_MENU_WIDTH, total_h, graphics.colors.card_bottom)
	draw_outline(table, m.x, m.y, CONTEXT_MENU_WIDTH, total_h, 1, graphics.colors.title)
	// Filter header strip
	draw_rectangle(table, m.x + 1, m.y + 1, CONTEXT_MENU_WIDTH - 2, CONTEXT_MENU_HEADER_HEIGHT - 2, graphics.colors.card_top)
	if m.filter_len > 0 {
		draw_text(table, m.x + 8, m.y + 6, string(m.filter[:m.filter_len]), graphics.COLOR_WHITE, FONT_INTERFACE)
	} else {
		draw_text(table, m.x + 8, m.y + 6, "Filter actions...", graphics.colors.dim, FONT_INTERFACE)
	}
	if m.match_count == 0 {
		draw_text(table, m.x + 8, m.y + CONTEXT_MENU_HEADER_HEIGHT + 4, "No match", graphics.colors.dim, FONT_INTERFACE)
		return
	}
	for row_idx in 0 ..< m.match_count {
		mt := m.matches[row_idx]
		item := m.items[mt.item_index]
		ry := m.y + CONTEXT_MENU_HEADER_HEIGHT + 2 + row_idx * CONTEXT_MENU_ROW_HEIGHT
		sel := row_idx == m.selected
		if sel {
			draw_rectangle(table, m.x + 2, ry, CONTEXT_MENU_WIDTH - 4, CONTEXT_MENU_ROW_HEIGHT, graphics.colors.chosen)
		}
		// Render label character-by-character when filtering so matched letters pop visually.
		if m.filter_len > 0 && mt.match_mask != 0 {
			cx := m.x + 8
			for i := 0; i < len(item.label) && cx < m.x + CONTEXT_MENU_WIDTH - 12; i += 1 {
				hit := i < 64 && ((mt.match_mask & (u64(1) << u32(i))) != 0)
				col := sel ? graphics.COLOR_WHITE : (hit ? graphics.colors.title : graphics.colors.text)
				if item.disabled {
					col = graphics.colors.dim
				}
				draw_character(table, cx, ry + 4, item.label[i], col)
				cx += graphics.CELL_WIDTH
			}
		} else {
			col := item.disabled ? graphics.colors.dim : (sel ? graphics.COLOR_WHITE : graphics.colors.text)
			fit := text_fit(table, FONT_INTERFACE, item.label, CONTEXT_MENU_WIDTH - 16)
			draw_text(table, m.x + 8, ry + 4, fit, col, FONT_INTERFACE)
		}
	}
}
