// Reusable per-application Command Palette (Ctrl+K / Ctrl+Shift+P) for
// modus:interface. Any window can embed a Command_Palette_State and offer
// fuzzy-filtered keyboard and pointer access to all of its commands without
// duplicating filtering, ranking, scrolling, or overlay drawing.
package interface

import "modus:display"
import "modus:graphics"

// Plan value: covers all commands of a rich desktop application in a single
// flat table without heap allocation.
COMMAND_PALETTE_MAX_ITEMS :: 48
// Plan value: holds typical multi-word fuzzy command queries.
COMMAND_PALETTE_MAX_FILTER :: 48
// Plan value: caps visible overlay height so the palette fits comfortably on
// every resizable desktop window down to 320 px height.
COMMAND_PALETTE_MAX_VISIBLE :: 8
// Plan value: minimum palette card width when the window allows it.
COMMAND_PALETTE_MIN_WIDTH :: 280
// Plan value: maximum palette card width so rows remain easy to scan on wide windows.
COMMAND_PALETTE_MAX_WIDTH :: 460
// Plan value: top inset from the window's top edge to the floating palette card.
COMMAND_PALETTE_TOP_MARGIN :: 24
// Plan value: search header height holding the filter input and bottom divider.
COMMAND_PALETTE_HEADER_HEIGHT :: 42
// Plan value: command row height (16 px text + 6 px vertical padding each side).
COMMAND_PALETTE_ROW_HEIGHT :: 28
// Plan value: slim footer strip height showing navigation hints and match counts.
COMMAND_PALETTE_FOOTER_HEIGHT :: 22
// Plan value: sharp drop shadow offset under the palette card (docs/DESIGN.md, "3. Surfaces").
COMMAND_PALETTE_SHADOW_OFFSET :: 4

Command_Palette_Item :: struct {
	id:       u32,
	label:    string,
	category: string, // Optional dim group label shown before the command name.
	shortcut: string, // Optional key hint aligned at the right of the row.
	disabled: bool,
	danger:   bool,
}

Command_Palette_State :: struct {
	open:         bool,
	title:        string,
	items:        [COMMAND_PALETTE_MAX_ITEMS]Command_Palette_Item,
	item_count:   int,
	filter:       [COMMAND_PALETTE_MAX_FILTER]u8,
	filter_len:   int,
	matches:      [COMMAND_PALETTE_MAX_ITEMS]Context_Menu_Match,
	match_count:  int,
	selected:     int,
	first_row:    int,
	visible_rows: int, // Last known visible row count for keyboard scrolling on short windows.
}

// is_command_palette_shortcut reports whether a key press is Ctrl+K or
// Ctrl+Shift+P (matching desktop command palette conventions).
is_command_palette_shortcut :: proc "contextless" (code: u32, character: rune, modifiers: u32) -> bool {
	ctrl := modifiers & display.MODIFIER_CONTROL != 0
	shift := modifiers & display.MODIFIER_SHIFT != 0
	alt := modifiers & display.MODIFIER_ALT != 0
	if !ctrl || alt {
		return false
	}
	if !shift && (character == 'k' || character == 'K') {
		return true
	}
	if shift && (character == 'p' || character == 'P') {
		return true
	}
	_ = code
	return false
}

// is_command_palette_shift_shortcut reports whether a key press is Ctrl+Shift+P
// alone, for terminal windows where bare Ctrl+K belongs to shell line editing.
is_command_palette_shift_shortcut :: proc "contextless" (code: u32, character: rune, modifiers: u32) -> bool {
	ctrl := modifiers & display.MODIFIER_CONTROL != 0
	shift := modifiers & display.MODIFIER_SHIFT != 0
	alt := modifiers & display.MODIFIER_ALT != 0
	_ = code
	return ctrl && shift && !alt && (character == 'p' || character == 'P')
}

// command_palette_open opens the palette with a title and list of commands.
command_palette_open :: proc "contextless" (p: ^Command_Palette_State, title: string, items: []Command_Palette_Item, win_h := 0) {
	if p == nil {
		return
	}
	p^ = {open = true, title = title}
	n := min(len(items), COMMAND_PALETTE_MAX_ITEMS)
	for i in 0 ..< n {
		p.items[i] = items[i]
	}
	p.item_count = n
	p.visible_rows = win_h > 0 ? command_palette_window_row_capacity(win_h) : COMMAND_PALETTE_MAX_VISIBLE
	command_palette_refilter(p)
}

command_palette_close :: proc "contextless" (p: ^Command_Palette_State) {
	if p == nil {
		return
	}
	p.open = false
}

command_palette_refilter :: proc "contextless" (p: ^Command_Palette_State) {
	if p == nil {
		return
	}
	p.match_count = 0
	q := p.filter[:p.filter_len]
	for i in 0 ..< p.item_count {
		ok, score, mask := context_menu_fuzzy_match(q, p.items[i].label)
		if !ok && p.items[i].category != "" {
			cat_ok, cat_score, _ := context_menu_fuzzy_match(q, p.items[i].category)
			if cat_ok {
				ok = true
				score = cat_score - 8 // Prefer label matches over category-only matches.
				mask = 0
			}
		}
		if !ok {
			continue
		}
		pos := p.match_count
		for pos > 0 && p.matches[pos - 1].score < score {
			p.matches[pos] = p.matches[pos - 1]
			pos -= 1
		}
		p.matches[pos] = {item_index = i, score = score, match_mask = mask}
		p.match_count += 1
	}
	if p.match_count == 0 {
		p.selected = 0
		p.first_row = 0
	} else {
		p.selected = clamp(p.selected, 0, p.match_count - 1)
		vis := p.visible_rows > 0 ? p.visible_rows : COMMAND_PALETTE_MAX_VISIBLE
		command_palette_scroll_to_selected(p, vis)
	}
}

@(private = "file")
command_palette_window_row_capacity :: proc "contextless" (win_h: int) -> int {
	max_by_window := max(1, (win_h - COMMAND_PALETTE_TOP_MARGIN - 16 - COMMAND_PALETTE_HEADER_HEIGHT - COMMAND_PALETTE_FOOTER_HEIGHT) / COMMAND_PALETTE_ROW_HEIGHT)
	return min(COMMAND_PALETTE_MAX_VISIBLE, max_by_window)
}

@(private = "file")
command_palette_visible_rows :: proc "contextless" (p: ^Command_Palette_State, win_h: int) -> int {
	if p == nil {
		return 1
	}
	return clamp(max(p.match_count, 1), 1, command_palette_window_row_capacity(win_h))
}

@(private = "file")
command_palette_scroll_to_selected :: proc "contextless" (p: ^Command_Palette_State, visible := COMMAND_PALETTE_MAX_VISIBLE) {
	if p == nil || p.match_count <= 0 {
		return
	}
	vis := max(1, min(visible, p.match_count))
	if p.selected < p.first_row {
		p.first_row = p.selected
	} else if p.selected >= p.first_row + vis {
		p.first_row = p.selected - vis + 1
	}
	p.first_row = clamp(p.first_row, 0, max(0, p.match_count - vis))
}

// command_palette_card_rect returns the centered card area inside (win_w, win_h).
command_palette_card_rect :: proc "contextless" (p: ^Command_Palette_State, win_w, win_h: int) -> Area {
	w := clamp(win_w - 48, min(COMMAND_PALETTE_MIN_WIDTH, max(win_w - 16, 0)), COMMAND_PALETTE_MAX_WIDTH)
	rows := command_palette_visible_rows(p, win_h)
	h := COMMAND_PALETTE_HEADER_HEIGHT + rows * COMMAND_PALETTE_ROW_HEIGHT + COMMAND_PALETTE_FOOTER_HEIGHT
	x := max(8, (win_w - w) / 2)
	y := min(COMMAND_PALETTE_TOP_MARGIN, max(4, (win_h - h) / 4))
	return {x, y, w, h}
}

// command_palette_row_at gives the match index under (px, py), or -1.
command_palette_row_at :: proc "contextless" (p: ^Command_Palette_State, px, py, win_w, win_h: int) -> int {
	if p == nil || !p.open || p.match_count == 0 {
		return -1
	}
	card := command_palette_card_rect(p, win_w, win_h)
	rows_top := card.y + COMMAND_PALETTE_HEADER_HEIGHT
	visible := command_palette_visible_rows(p, win_h)
	if px < card.x + 4 || px >= card.x + card.width - 4 || py < rows_top || py >= rows_top + visible * COMMAND_PALETTE_ROW_HEIGHT {
		return -1
	}
	row := p.first_row + (py - rows_top) / COMMAND_PALETTE_ROW_HEIGHT
	if row < 0 || row >= p.match_count {
		return -1
	}
	return row
}

// command_palette_pointer handles hover, wheel scrolling, click-to-run, and
// click-outside-to-dismiss while the palette is open.
command_palette_pointer :: proc "contextless" (p: ^Command_Palette_State, px, py: int, pressed: bool, wheel: int, win_w, win_h: int) -> (result: Context_Menu_Pointer_Result) {
	if p == nil || !p.open {
		return
	}
	card := command_palette_card_rect(p, win_w, win_h)
	inside_card := area_contains(card, px, py)
	if !inside_card {
		if pressed {
			p.open = false
			result.changed = true
			result.consumed = true
		}
		return
	}
	result.consumed = true
	p.visible_rows = command_palette_window_row_capacity(win_h)
	visible := command_palette_visible_rows(p, win_h)
	if wheel != 0 && p.match_count > visible {
		before := p.first_row
		next := clamp(i64(p.first_row) + i64(wheel), i64(0), i64(max(0, p.match_count - visible)))
		p.first_row = int(next)
		if p.first_row != before {
			result.changed = true
		}
	}
	row := command_palette_row_at(p, px, py, win_w, win_h)
	if row >= 0 && row != p.selected {
		p.selected = row
		result.changed = true
	}
	if pressed && row >= 0 {
		item := p.items[p.matches[row].item_index]
		if !item.disabled {
			p.open = false
			result.changed = true
			result.triggered = true
			result.triggered_id = item.id
		}
	}
	return
}

// command_palette_handle_key handles typing, Backspace, Up/Down, PageUp/Down,
// Enter, and Escape while the palette is open.
command_palette_handle_key :: proc "contextless" (p: ^Command_Palette_State, code: u32, character: rune, pressed: bool, modifiers: u32 = 0, win_h := 0) -> (consumed: bool, triggered_id: u32) {
	if p == nil || !p.open || !pressed {
		return false, 0
	}
	cap_rows := win_h > 0 ? command_palette_window_row_capacity(win_h) : (p.visible_rows > 0 ? p.visible_rows : COMMAND_PALETTE_MAX_VISIBLE)
	p.visible_rows = cap_rows
	visible := clamp(max(p.match_count, 1), 1, cap_rows)
	switch code {
	case display.KEY_ESCAPE:
		p.open = false
		return true, 0
	case display.KEY_UP:
		if p.match_count > 0 {
			p.selected = (p.selected + p.match_count - 1) % p.match_count
			command_palette_scroll_to_selected(p, visible)
		}
		return true, 0
	case display.KEY_DOWN:
		if p.match_count > 0 {
			p.selected = (p.selected + 1) % p.match_count
			command_palette_scroll_to_selected(p, visible)
		}
		return true, 0
	case display.KEY_PAGE_UP:
		if p.match_count > 0 {
			p.selected = max(0, p.selected - visible)
			command_palette_scroll_to_selected(p, visible)
		}
		return true, 0
	case display.KEY_PAGE_DOWN:
		if p.match_count > 0 {
			p.selected = min(p.match_count - 1, p.selected + visible)
			command_palette_scroll_to_selected(p, visible)
		}
		return true, 0
	case display.KEY_ENTER:
		if p.match_count > 0 && p.selected < p.match_count {
			item := p.items[p.matches[p.selected].item_index]
			if !item.disabled {
				p.open = false
				return true, item.id
			}
		}
		return true, 0
	case display.KEY_BACKSPACE:
		if p.filter_len > 0 {
			p.filter_len -= 1
			command_palette_refilter(p)
		}
		return true, 0
	}
	no_cmd_mod := modifiers & (display.MODIFIER_CONTROL | display.MODIFIER_ALT) == 0
	if no_cmd_mod && character >= 0x20 && character < 0x7F && p.filter_len < COMMAND_PALETTE_MAX_FILTER {
		p.filter[p.filter_len] = u8(character)
		p.filter_len += 1
		command_palette_refilter(p)
		return true, 0
	}
	return true, 0
}

// command_palette_draw renders the centered command palette card over the
// window content. Call this last in the frame so it floats above all panes.
command_palette_draw :: proc "contextless" (table: ^Draw_Table, p: ^Command_Palette_State, win_w, win_h: int) {
	if table == nil || p == nil || !p.open {
		return
	}
	card := command_palette_card_rect(p, win_w, win_h)
	if card.width < 32 || card.height <= 0 {
		return
	}
	// Sharp drop shadow + elevated card surface.
	draw_rectangle(table, card.x + COMMAND_PALETTE_SHADOW_OFFSET, card.y + COMMAND_PALETTE_SHADOW_OFFSET, card.width, card.height, graphics.colors.shadow)
	draw_vertical_gradient(table, card.x, card.y, card.width, card.height, graphics.colors.card_top, graphics.colors.card_bottom)
	draw_outline(table, card.x, card.y, card.width, card.height, 1, graphics.colors.title)
	draw_rectangle(table, card.x + 1, card.y + 1, card.width - 2, 1, graphics.shade(graphics.colors.card_top, 138))

	// Search input header with live caret.
	field_frame := Frame{table = table}
	field := Area{card.x + 8, card.y + 8, card.width - 16, COMMAND_PALETTE_HEADER_HEIGHT - 16}
	placeholder := p.title != "" ? p.title : "Type a command"
	filter_text := string(p.filter[:p.filter_len])
	text_input_line(&field_frame, field, filter_text, len(filter_text), 0, placeholder, name = "command palette")
	draw_rectangle(table, card.x + 1, card.y + COMMAND_PALETTE_HEADER_HEIGHT - 1, card.width - 2, 1, graphics.colors.track)

	rows_top := card.y + COMMAND_PALETTE_HEADER_HEIGHT
	p.visible_rows = command_palette_window_row_capacity(win_h)
	visible := command_palette_visible_rows(p, win_h)
	if p.match_count == 0 {
		empty_label := text_fit(table, FONT_INTERFACE, "No matching command", max(card.width - 28, 0))
		draw_text(table, card.x + 14, rows_top + (COMMAND_PALETTE_ROW_HEIGHT - LINE) / 2, empty_label, graphics.colors.dim, FONT_INTERFACE)
	} else {
		p.first_row = clamp(p.first_row, 0, max(0, p.match_count - visible))
		shown := min(visible, p.match_count - p.first_row)
		for offset in 0 ..< shown {
			row := p.first_row + offset
			match := p.matches[row]
			item := p.items[match.item_index]
			ry := rows_top + offset * COMMAND_PALETTE_ROW_HEIGHT
			chosen := row == p.selected && !item.disabled
			if chosen {
				plate_col := item.danger ? graphics.colors.stop_process : graphics.colors.chosen
				draw_vertical_gradient(table, card.x + 4, ry + 1, card.width - 8, COMMAND_PALETTE_ROW_HEIGHT - 2, plate_col, graphics.shade(plate_col, 86))
				draw_rectangle(table, card.x + 5, ry + 1, card.width - 10, 1, graphics.shade(plate_col, 136))
			}
			text_y := ry + (COMMAND_PALETTE_ROW_HEIGHT - LINE) / 2
			lx := card.x + 12
			right_edge := card.x + card.width - 12
			if item.shortcut != "" {
				sw := text_measured_width(table, FONT_INTERFACE, item.shortcut)
				if sw + 16 < right_edge - lx {
					draw_text_right(table, right_edge, text_y, item.shortcut, chosen ? graphics.COLOR_WHITE : graphics.colors.dim, FONT_INTERFACE)
					right_edge -= sw + 16
				}
			}
			if item.category != "" {
				cat_w := text_measured_width(table, FONT_CAPTION, item.category)
				if cat_w + 18 < right_edge - lx {
					cat_y := text_top_on_baseline(table, FONT_INTERFACE, text_y, FONT_CAPTION)
					draw_text(table, lx, cat_y, item.category, chosen ? graphics.COLOR_WHITE : graphics.colors.dim, FONT_CAPTION)
					lx += cat_w + 10
				}
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
			shown_label := text_fit(table, FONT_INTERFACE, item.label, max(right_edge - lx, 0))
			draw_text(table, lx, text_y, shown_label, label_color, FONT_INTERFACE)
			if p.filter_len > 0 && match.match_mask != 0 {
				for run in matched_runs(shown_label, u128(match.match_mask)) {
					if run.end <= run.start {
						break
					}
					sx := text_measured_width(table, FONT_INTERFACE, shown_label[:run.start])
					ex := text_measured_width(table, FONT_INTERFACE, shown_label[:run.end])
					draw_rectangle(table, lx + sx, text_y + LINE, ex - sx, 2, chosen ? graphics.COLOR_WHITE : graphics.colors.kernel)
				}
			}
		}
	}

	// Slim footer strip: match count on the right, navigation hint on the left when it fits.
	foot_y := card.y + card.height - COMMAND_PALETTE_FOOTER_HEIGHT
	draw_rectangle(table, card.x + 1, foot_y, card.width - 2, 1, graphics.colors.track)
	builder: Text_Builder
	text_put_number(&builder, u64(p.match_count))
	text_put(&builder, " / ")
	text_put_number(&builder, u64(p.item_count))
	count_text := text_of(&builder)
	count_w := text_measured_width(table, FONT_CAPTION, count_text)
	draw_text_right(table, card.x + card.width - 12, foot_y + 4, count_text, graphics.colors.dim, FONT_CAPTION)
	hint := "Enter run  Esc close"
	hint_w := text_measured_width(table, FONT_CAPTION, hint)
	if count_w + hint_w + 12 <= card.width - 24 {
		draw_text(table, card.x + 12, foot_y + 4, hint, graphics.colors.dim, FONT_CAPTION)
	}
}
