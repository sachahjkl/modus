package assistant_window

import "internal:assistant/conversation"
import "internal:assistant/result_lines"
import assistant_contract "modus:contract/assistant"
import "modus:console_results"
import "modus:graphics"
import "modus:interface"

// The typed result of an act, painted as the console draws a result
// (src/md/features/assistant.md, "The result of an act"). The lines, their
// fit to the room and their notes are in internal:assistant/result_lines;
// this file keeps them and paints them in the font of the cells.

// The results whose lines the window keeps: the ones that a frame shows,
// which a conversation of a window of this height holds few of. The lines
// of a result are computed when its act, the width or the room changes,
// never at each frame (the table of a done act never changes).
RESULT_CACHE_SLOTS :: 3

Result_Slot :: struct {
	valid:       bool,
	act:         u64,
	row_count:   int,
	row_offset:  int,
	width_cells: int,
	line_room:   int,
	used:        u64, // The frame that used it last: the oldest slot takes a new result.
	lines:       result_lines.Lines,
}

result_slots: [RESULT_CACHE_SLOTS]Result_Slot
result_scratch: result_lines.Scratch
result_frame: u64

// result_lines_of gives the lines of the result of an act at a width, a
// room and a starting row offset: the kept ones, or new ones written into
// the oldest slot. nil when the result cannot show in that room.
result_lines_of :: proc "contextless" (entry: ^conversation.Entry, table: ^conversation.Act_Table, width_cells, line_room, row_offset: int) -> ^result_lines.Lines {
	// No room: no slot is chosen, so a kept result stays kept.
	if table == nil || line_room < 1 {
		return nil
	}
	result_frame += 1
	oldest := &result_slots[0]
	for &slot in result_slots {
		if slot.valid && slot.act == entry.act && slot.row_count == table.row_count && slot.row_offset == row_offset && slot.width_cells == width_cells && slot.line_room == line_room {
			slot.used = result_frame
			return &slot.lines
		}
		if !slot.valid || slot.used < oldest.used {
			oldest = &slot
		}
	}
	// The fields are set in place: a slot holds about 64 KiB of lines, and
	// a record literal of it would be a temporary on the stack. fit resets
	// the counts of the lines.
	oldest.valid = false
	oldest.act, oldest.row_count, oldest.row_offset, oldest.width_cells, oldest.line_room, oldest.used = entry.act, table.row_count, row_offset, width_cells, line_room, result_frame
	if !result_lines.fit(&oldest.lines, &result_scratch, table, width_cells, line_room, row_offset) {
		return nil
	}
	oldest.valid = true
	return &oldest.lines
}

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

// The records of one frame. A painted line takes one record for each run
// of one color: at most a run for each column and one for the notes. The
// lines of a frame are at most the height in cells of the font of the
// cells. The text is each cell of those lines, 4 bytes for a character.
LINES_IN_A_FRAME :: HEIGHT / graphics.CELL_HEIGHT + 1
RUNS_IN_A_LINE :: assistant_contract.ACT_TABLE_COLUMN_CAPACITY + 2
WINDOW_RECORDS :: LINES_IN_A_FRAME * RUNS_IN_A_LINE + 64
WINDOW_TEXT_BYTES :: (LINES_IN_A_FRAME * (WIDTH / graphics.CELL_WIDTH) * 4 + 4096 + 3) / 4 * 4
#assert(WINDOW_RECORDS >= LINES_IN_A_FRAME * RUNS_IN_A_LINE)

// result_lines_paint draws the lines at a place in the font of the cells:
// the parts of one color in a row, with the blanks between them, are one
// record at the column of their first part.
result_lines_paint :: proc "contextless" (draw_table: ^interface.Draw_Table, lines: ^result_lines.Lines, x, y, cell_width, line_height: int) {
	run: [1024]u8
	run_count, run_column, column, line := 0, 0, 0, -1
	run_color: graphics.Color
	flush :: proc "contextless" (draw_table: ^interface.Draw_Table, run: []u8, count: ^int, x, y, column, cell_width: int, color: graphics.Color) {
		// Blanks at the end of a run draw nothing.
		end := count^
		for end > 0 && run[end - 1] == ' ' {
			end -= 1
		}
		if end > 0 {
			interface.draw_text(draw_table, x + column * cell_width, y, string(run[:end]), color, FONT_CODE)
		}
		count^ = 0
	}
	for index in 0 ..< lines.part_count {
		part := lines.parts[index]
		if int(part.line) != line {
			flush(draw_table, run[:], &run_count, x, y + line * line_height, run_column, cell_width, run_color)
			line, column = int(part.line), 0
		}
		text := string(lines.text[part.start:][:part.count])
		blank := true
		for character in transmute([]u8)text {
			if character != ' ' {
				blank = false
				break
			}
		}
		color := result_part_color(part.part)
		switch {
		case blank:
			// Blanks before a run start nothing: the next run starts after
			// them. Blanks inside a run join it.
			if run_count > 0 && run_count + len(text) <= len(run) {
				run_count += copy(run[run_count:], text)
			}
		case run_count == 0:
			run_column, run_color = column, color
			run_count = copy(run[:], text)
		case color == run_color && run_count + len(text) <= len(run):
			run_count += copy(run[run_count:], text)
		case:
			flush(draw_table, run[:], &run_count, x, y + line * line_height, run_column, cell_width, run_color)
			run_column, run_color = column, color
			run_count = copy(run[:], text)
		}
		column += console_results.text_columns(text)
	}
	flush(draw_table, run[:], &run_count, x, y + line * line_height, run_column, cell_width, run_color)
}
