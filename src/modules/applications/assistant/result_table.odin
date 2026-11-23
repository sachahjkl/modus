package assistant_window

import "internal:assistant/result_lines"
import "modus:console_results"
import "modus:graphics"
import "modus:interface"

// The typed result of an act, painted as the console draws a result
// (src/md/features/assistant.md, "The result of an act"). The lines, their
// fit to the room and their notes are in internal:assistant/result_lines;
// this file paints them in the font of the cells.

// The lines of the result that is drawn: the window draws one entry at a
// time, in its one thread.
result_memory: result_lines.Lines

// result_part_color gives the color of a part: a value in the color of its
// value kind, as in the console; a label and a note dim; a failure in the
// color of a failure.
result_part_color :: proc "contextless" (part: console_results.Part) -> graphics.Color {
	if kind := console_results.part_value_kind(part); kind != .None {
		return graphics.value_kind_color(kind, graphics.appearance, graphics.colors.text)
	}
	switch part {
	case .Label, .Note:
		return graphics.colors.dim
	case .Failure:
		return graphics.colors.failed
	case .Plain, .Number, .Handle, .Type, .Status, .Operation, .Size, .Time, .Module, .Version:
	}
	return graphics.colors.text
}

// result_lines_paint draws the lines at a place, each part at its column
// in the font of the cells.
result_lines_paint :: proc "contextless" (draw_table: ^interface.Draw_Table, lines: ^result_lines.Lines, x, y, cell_width, line_height: int) {
	line, column := -1, 0
	for index in 0 ..< lines.part_count {
		part := lines.parts[index]
		if part.line != line {
			line, column = part.line, 0
		}
		text := string(lines.text[part.start:][:part.count])
		blank := true
		for character in transmute([]u8)text {
			if character != ' ' {
				blank = false
				break
			}
		}
		if !blank {
			interface.draw_text(draw_table, x + column * cell_width, y + line * line_height, text, result_part_color(part.part), FONT_CODE)
		}
		column += console_results.text_columns(text)
	}
}
