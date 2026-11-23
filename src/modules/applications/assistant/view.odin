package assistant_window

import "internal:assistant/conversation"
import "internal:assistant/conversation_view"
import "internal:assistant/result_lines"
import "modus:contract/text_encoding"
import "modus:graphics"
import "modus:interface"
import "modus:system"

// The view of the conversation (src/md/features/assistant.md, "The view of
// the conversation"): the entries, oldest first, in a view that scrolls,
// which shows the newest entry until the principal moves it up. Each entry
// is laid out once for each change of it (view_layout), and each frame
// draws only the lines that the view meets: the text of a frame is bounded
// by the lines of the view, however long the entries are.
//
// The view is its own, not the scroll of the window layer
// (src/md/features/window_scroll.md): that scroll moves the whole layout of
// a window larger than its surface, and the conversation is a view inside
// a window that fits, above the field of the request, anchored on its
// newest entry.

// The layout of each place of the ring of the conversation.
view_layouts: [conversation_view.ENTRY_CAPACITY]conversation_view.Entry_Layout
view_places: conversation_view.Places
// The view follows the newest entry from the start.
view_scroll := conversation_view.Scroll{following = true}

// The sizes and the serial that the places are of: a change of one lays
// out again.
view_laid_out: bool
view_layout_serial: u64
view_layout_metrics: u64
view_layout_width: int
view_layout_height: int

// The lines that a layout fits a typed result into, to know its height:
// the lines that a frame paints are in the slots of result_table.odin.
layout_lines: result_lines.Lines

// The sizes of the lines of a frame.
View_Metrics :: struct {
	line:        int, // A line of the interface font.
	code_line:   int, // A line of the font of the cells.
	fold_height: int, // A button of an entry.
	cell_width:  int, // A cell of the font of the cells.
}

view_metrics :: proc "contextless" (table: ^interface.Draw_Table) -> View_Metrics {
	line := interface.line_height(interface.FONT_INTERFACE)
	return {
		line        = line,
		code_line   = interface.line_height(FONT_CODE),
		fold_height = line + 4,
		cell_width  = max(interface.text_measured_width(table, FONT_CODE, "0"), 1),
	}
}

@(private = "file")
metrics_key :: proc "contextless" (metrics: View_Metrics) -> u64 {
	return u64(u16(metrics.line)) | u64(u16(metrics.code_line)) << 16 | u64(u16(metrics.fold_height)) << 32 | u64(u16(metrics.cell_width)) << 48
}

// wrap_into breaks a text into the lines of a room, keeps the first ones in
// lines, and gives the count of all of them.
@(private = "file")
wrap_into :: proc "contextless" (table: ^interface.Draw_Table, font: interface.Font, text: string, room: int, lines: []conversation_view.Line) -> (count: int) {
	rest := text
	for len(rest) > 0 {
		line, next := interface.text_wrap_line(table, font, rest, room)
		if count < len(lines) {
			lines[count] = {start = u16(len(text) - len(rest)), count = u16(len(line))}
		}
		count += 1
		// A line has one character at least: no text stays in place.
		if len(next) >= len(rest) {
			break
		}
		rest = next
	}
	return count
}

// layout_entry lays out one entry: its code, its words bounded to the room
// of the view, or its typed result fitted to it, and its buttons.
@(private = "file")
layout_entry :: proc "contextless" (table: ^interface.Draw_Table, entry: ^conversation.Entry, layout: ^conversation_view.Entry_Layout, width, height: int, metrics: View_Metrics, key: u64, folded: bool, act_table: ^conversation.Act_Table) {
	body_buffer: [256]u8
	code, words, words_are_value := entry_body(entry, body_buffer[:])
	layout.number, layout.revision = entry.number, entry.revision
	layout.width, layout.view_height, layout.metrics = i32(width), i32(height), key
	layout.folded, layout.has_table = folded, act_table != nil
	layout.table_rows = act_table != nil ? i32(act_table.row_count) : 0
	layout.words_are_value = words_are_value
	layout.more_button, layout.page_bar = false, false
	layout.result_lines, layout.result_room = 0, 0
	layout.word_total, layout.word_count = 0, 0
	layout.code_count = u16(min(wrap_into(table, FONT_CODE, code, width, layout.code[:]), conversation_view.CODE_LINE_CAPACITY))
	layout.fold_button = conversation.act_folded_by_default(&talk, entry)
	fold := layout.fold_button ? metrics.fold_height : 0
	room := height - metrics.line - int(layout.code_count) * metrics.code_line - fold - MARGIN / 2
	body := 0
	shows_table := false
	if !folded && act_table != nil {
		width_cells := width / metrics.cell_width
		offset := int(entry.table_row_offset)
		line_room := max(room / metrics.code_line, 1)
		fitted := result_lines.fit(&layout_lines, &result_scratch, act_table, width_cells, line_room, offset)
		if fitted && act_table.shape == .Table && (offset > 0 || offset + layout_lines.shown_rows < act_table.row_count) {
			layout.page_bar = true
			line_room = max((room - metrics.fold_height) / metrics.code_line, 1)
			fitted = result_lines.fit(&layout_lines, &result_scratch, act_table, width_cells, line_room, offset)
		}
		if fitted {
			shows_table = true
			layout.result_lines, layout.result_room = i32(layout_lines.line_count), i32(line_room)
			body = layout_lines.line_count * metrics.code_line + (layout.page_bar ? metrics.fold_height : 0)
		} else {
			layout.page_bar = false
		}
	}
	if !folded && !shows_table && words != "" {
		font := words_are_value ? FONT_CODE : interface.FONT_INTERFACE
		words_line := words_are_value ? metrics.code_line : metrics.line
		total := wrap_into(table, font, words, width, layout.words[:])
		shown := min(total, conversation_view.WORD_LINE_CAPACITY)
		if total > max(room / words_line, 0) || total > conversation_view.WORD_LINE_CAPACITY {
			layout.more_button = true
			shown, _ = conversation_view.lines_bound(total, (room - metrics.fold_height) / words_line, entry.expanded)
		}
		layout.word_total, layout.word_count = i32(total), u16(shown)
		body = shown * words_line + (layout.more_button ? metrics.fold_height : 0)
	}
	layout.height = i32(metrics.line + int(layout.code_count) * metrics.code_line + fold + body + MARGIN / 2)
}

// view_layout lays out each entry whose layout is not of now, and the
// places of all of them. It works only when the conversation, the room or
// a font changed: a frame with no change reads the places it kept.
view_layout :: proc "contextless" (table: ^interface.Draw_Table, width, height: int, metrics: View_Metrics) {
	key := metrics_key(metrics)
	if view_laid_out && view_layout_serial == talk.layout_serial && view_layout_metrics == key && view_layout_width == width && view_layout_height == height {
		return
	}
	view_laid_out, view_layout_serial, view_layout_metrics = true, talk.layout_serial, key
	view_layout_width, view_layout_height = width, height
	view_places.count = talk.entry_count
	y := 0
	for index in 0 ..< talk.entry_count {
		entry := conversation.entry_at(&talk, index)
		layout := &view_layouts[(talk.entry_first + index) % len(view_layouts)]
		folded := conversation.act_folded(&talk, entry)
		act_table := entry.kind == .Act && entry.state == .Done ? conversation.act_table_of(&talk, entry) : nil
		table_rows := act_table != nil ? i32(act_table.row_count) : 0
		same := layout.number == entry.number && layout.revision == entry.revision && layout.metrics == key && int(layout.width) == width && int(layout.view_height) == height && layout.folded == folded && layout.has_table == (act_table != nil) && layout.table_rows == table_rows && layout.fold_button == conversation.act_folded_by_default(&talk, entry)
		if !same {
			layout_entry(table, entry, layout, width, height, metrics, key, folded, act_table)
		}
		view_places.tops[index] = y
		view_places.numbers[index] = entry.number
		y += int(layout.height)
	}
	view_places.tops[talk.entry_count] = y
}

// fold_summary writes the short label of a folded act result button.
@(private = "file")
fold_summary :: proc "contextless" (entry: ^conversation.Entry, table: ^conversation.Act_Table, buffer: []u8) -> string {
	if table != nil {
		name := conversation.act_table_name(table)
		switch table.shape {
		case .Table:
			return system.format(buffer, "Show ", u64(table.total_rows), " rows of ", name)
		case .Record:
			return system.format(buffer, "Show ", name)
		}
	}
	preview_limit := min(entry.text_count, 48)
	preview_count := text_encoding.complete_characters(entry.text[:preview_limit])
	preview := string(entry.text[:preview_count])
	if preview_count < entry.text_count {
		return system.format(buffer, "Show result: ", preview, "...")
	}
	return system.format(buffer, "Show result: ", preview)
}

// meets says if a band of the content of a height at y shows in the view.
@(private = "file")
meets :: proc "contextless" (area: interface.Area, y, height: int) -> bool {
	return y + height > area.y && y < area.y + area.height
}

// inside says if a band shows whole in the view: a button that the view
// cuts takes no press, so it is not drawn.
@(private = "file")
inside :: proc "contextless" (area: interface.Area, y, height: int) -> bool {
	return y >= area.y && y + height <= area.y + area.height
}

// view_button draws a button of an entry when it shows whole, and says if
// it was pressed.
@(private = "file")
view_button :: proc "contextless" (frame: ^interface.Frame, area: interface.Area, x, y, height: int, element: interface.Element_Identity, label: string) -> bool {
	if !inside(area, y, height) {
		return false
	}
	width := min(interface.text_measured_width(frame.table, interface.FONT_INTERFACE, label) + 20, area.x + area.width - x)
	return interface.button(frame, {x, y, width, height}, element, label).activated
}

// paint_entry draws the parts of one entry that meet the view, from its
// top in the window.
@(private = "file")
paint_entry :: proc "contextless" (frame: ^interface.Frame, area: interface.Area, entry: ^conversation.Entry, layout: ^conversation_view.Entry_Layout, top: int, metrics: View_Metrics) {
	table := frame.table
	label_buffer: [160]u8
	body_buffer: [256]u8
	button_buffer: [160]u8
	label, color := entry_label(entry, label_buffer[:])
	code, words, words_are_value := entry_body(entry, body_buffer[:])
	x := area.x
	y := top
	if meets(area, y, metrics.line) {
		interface.draw_text(table, x, y, label, color, interface.FONT_INTERFACE_BOLD)
	}
	y += metrics.line
	for line in layout.code[:layout.code_count] {
		if meets(area, y, metrics.code_line) && int(line.start) + int(line.count) <= len(code) {
			interface.draw_text(table, x, y, code[line.start:][:line.count], graphics.colors.text, FONT_CODE)
		}
		y += metrics.code_line
	}
	act_table := layout.has_table ? conversation.act_table_of(&talk, entry) : nil
	if layout.fold_button {
		fold_label := layout.folded ? fold_summary(entry, act_table, button_buffer[:]) : "Hide result"
		if view_button(frame, area, x, y, metrics.fold_height, interface.identity_with(interface.identity("act_fold"), int(entry.act)), fold_label) {
			conversation.act_fold_toggle(&talk, entry)
		}
		y += metrics.fold_height
	}
	if layout.folded {
		return
	}
	if layout.result_lines > 0 && act_table != nil {
		offset := int(entry.table_row_offset)
		lines := result_lines_of(entry, act_table, int(layout.width) / metrics.cell_width, int(layout.result_room), offset)
		if lines != nil {
			result_lines_paint(table, lines, x, y, metrics.cell_width, metrics.code_line, area.y, area.y + area.height)
		}
		y += int(layout.result_lines) * metrics.code_line
		if layout.page_bar && lines != nil {
			page_x := x
			step := max(lines.shown_rows, 1)
			if offset > 0 {
				if view_button(frame, area, page_x, y, metrics.fold_height, interface.identity_with(interface.identity("act_prev"), int(entry.act)), "Previous rows") {
					conversation.act_table_page(&talk, entry, max(offset - step, 0))
				}
				page_x += interface.text_measured_width(table, interface.FONT_INTERFACE, "Previous rows") + 20 + MARGIN / 2
			}
			if offset + lines.shown_rows < act_table.row_count {
				if view_button(frame, area, page_x, y, metrics.fold_height, interface.identity_with(interface.identity("act_next"), int(entry.act)), "Next rows") {
					conversation.act_table_page(&talk, entry, offset + step)
				}
				page_x += interface.text_measured_width(table, interface.FONT_INTERFACE, "Next rows") + 20 + MARGIN / 2
			}
			if meets(area, y, metrics.fold_height) {
				page_buffer: [64]u8
				first_row := u64(min(offset + 1, act_table.row_count))
				last_row := u64(min(offset + lines.shown_rows, act_table.row_count))
				interface.draw_text(table, page_x, y + 2, system.format(page_buffer[:], "rows ", first_row, " to ", last_row, " of ", u64(act_table.row_count)), graphics.colors.dim, interface.FONT_INTERFACE)
			}
		}
		return
	}
	font := words_are_value ? FONT_CODE : interface.FONT_INTERFACE
	words_line := words_are_value ? metrics.code_line : metrics.line
	for line in layout.words[:layout.word_count] {
		if meets(area, y, words_line) && int(line.start) + int(line.count) <= len(words) {
			interface.draw_text(table, x, y, words[line.start:][:line.count], graphics.colors.text, font)
		}
		y += words_line
	}
	if layout.more_button {
		hidden := u64(int(layout.word_total) - int(layout.word_count))
		more_label: string
		switch {
		case !entry.expanded:
			more_label = system.format(button_buffer[:], "Show ", hidden, hidden == 1 ? " more line" : " more lines")
		case hidden > 0:
			more_label = system.format(button_buffer[:], "Show fewer lines; ", hidden, hidden == 1 ? " line past the bound is not shown" : " lines past the bound are not shown")
		case:
			more_label = "Show fewer lines"
		}
		if view_button(frame, area, x, y, metrics.fold_height, interface.identity_with(interface.identity("entry_more"), int(entry.number)), more_label) {
			conversation.entry_expand_toggle(&talk, entry)
		}
	}
}

// view_paint draws the entries that the view meets, cut to the view.
view_paint :: proc "contextless" (frame: ^interface.Frame, area: interface.Area, metrics: View_Metrics) {
	start, end := conversation_view.visible(&view_places, view_scroll.first, area.height)
	interface.draw_clip_push(frame.table, area.x, area.y, area.width, area.height)
	for index in start ..< end {
		entry := conversation.entry_at(&talk, index)
		layout := &view_layouts[(talk.entry_first + index) % len(view_layouts)]
		paint_entry(frame, area, entry, layout, area.y + view_places.tops[index] - view_scroll.first, metrics)
	}
	interface.draw_clip_pop(frame.table)
}
