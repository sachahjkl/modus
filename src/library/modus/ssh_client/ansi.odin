// Pure zero-allocation VT100/ANSI escape parser state machine.
//
// Translates printable UTF-8, control characters, and CSI sequences (SGR colors,
// bold, underline, reverse, cursor move/home, erase in display/line) into bounded
// terminal grid edits. Malformed, oversized, or truncated sequences never panic or
// access outside the grid bounds.
package ssh_client

import "modus:contract/text_encoding"

MAX_GRID_COLS :: 160
MAX_GRID_ROWS :: 64
MAX_CSI_PARAMS :: 16
MAX_CSI_PARAM_VALUE :: u16(9999)

Ansi_Color :: enum u8 {
	Default        = 0,
	Black          = 1,
	Red            = 2,
	Green          = 3,
	Yellow         = 4,
	Blue           = 5,
	Magenta        = 6,
	Cyan           = 7,
	White          = 8,
	Bright_Black   = 9,
	Bright_Red     = 10,
	Bright_Green   = 11,
	Bright_Yellow  = 12,
	Bright_Blue    = 13,
	Bright_Magenta = 14,
	Bright_Cyan    = 15,
	Bright_White   = 16,
}

Cell_Attribute :: enum u8 {
	Bold      = 0,
	Reverse   = 1,
	Underline = 2,
}

Cell_Attributes :: bit_set[Cell_Attribute; u8]

Terminal_Cell :: struct {
	character:  rune,
	foreground: Ansi_Color,
	background: Ansi_Color,
	attributes: Cell_Attributes,
}

Terminal_Grid :: struct {
	cols:          int,
	rows:          int,
	cursor_col:    int,
	cursor_row:    int,
	current_fg:    Ansi_Color,
	current_bg:    Ansi_Color,
	current_attrs: Cell_Attributes,
	cells:         [MAX_GRID_COLS * MAX_GRID_ROWS]Terminal_Cell,
}

Ansi_State :: enum u8 {
	Ground     = 0,
	Escape     = 1,
	Csi_Entry  = 2,
	Csi_Param  = 3,
	Csi_Ignore = 4,
	Osc_String = 5,
	Osc_Esc    = 6,
}

Ansi_Parser :: struct {
	state:           Ansi_State,
	params:          [MAX_CSI_PARAMS]u16,
	param_count:     int,
	param_has_digit: bool,
	private_prefix:  bool,
	utf8_buf:        [4]u8,
	utf8_len:        int,
	utf8_expected:   int,
}

grid_blank_cell :: proc "contextless" (fg: Ansi_Color, bg: Ansi_Color, attrs: Cell_Attributes) -> Terminal_Cell {
	return Terminal_Cell{character = ' ', foreground = fg, background = bg, attributes = attrs}
}

grid_init :: proc "contextless" (grid: ^Terminal_Grid, cols, rows: int) -> Status {
	if grid == nil || cols < 1 || cols > MAX_GRID_COLS || rows < 1 || rows > MAX_GRID_ROWS {
		return .Invalid_Argument
	}
	grid.cols = cols
	grid.rows = rows
	grid.cursor_col = 0
	grid.cursor_row = 0
	grid.current_fg = .Default
	grid.current_bg = .Default
	grid.current_attrs = {}
	blank := grid_blank_cell(.Default, .Default, {})
	total := cols * rows
	for i in 0 ..< total {
		grid.cells[i] = blank
	}
	return .Ok
}

grid_cell :: proc "contextless" (grid: ^Terminal_Grid, col, row: int) -> (cell: Terminal_Cell, ok: bool) {
	if grid == nil || col < 0 || col >= grid.cols || row < 0 || row >= grid.rows {
		return {}, false
	}
	return grid.cells[row * grid.cols + col], true
}

ansi_parser_init :: proc "contextless" (parser: ^Ansi_Parser) {
	if parser == nil {
		return
	}
	parser^ = {}
}

@(private)
grid_scroll_up :: proc "contextless" (grid: ^Terminal_Grid) {
	if grid.rows <= 1 {
		blank := grid_blank_cell(grid.current_fg, grid.current_bg, {})
		for c in 0 ..< grid.cols {
			grid.cells[c] = blank
		}
		return
	}
	for r in 0 ..< grid.rows - 1 {
		dst_off := r * grid.cols
		src_off := (r + 1) * grid.cols
		for c in 0 ..< grid.cols {
			grid.cells[dst_off + c] = grid.cells[src_off + c]
		}
	}
	blank := grid_blank_cell(grid.current_fg, grid.current_bg, {})
	last_off := (grid.rows - 1) * grid.cols
	for c in 0 ..< grid.cols {
		grid.cells[last_off + c] = blank
	}
}

@(private)
grid_put_rune :: proc "contextless" (grid: ^Terminal_Grid, ch: rune) {
	if grid.cols <= 0 || grid.rows <= 0 {
		return
	}
	if grid.cursor_col >= grid.cols {
		grid.cursor_col = 0
		if grid.cursor_row + 1 >= grid.rows {
			grid_scroll_up(grid)
		} else {
			grid.cursor_row += 1
		}
	}
	grid.cells[grid.cursor_row * grid.cols + grid.cursor_col] = Terminal_Cell {
		character  = ch,
		foreground = grid.current_fg,
		background = grid.current_bg,
		attributes = grid.current_attrs,
	}
	grid.cursor_col += 1
}

@(private)
ansi_reset_csi :: proc "contextless" (parser: ^Ansi_Parser) {
	parser.params = {}
	parser.param_count = 0
	parser.param_has_digit = false
	parser.private_prefix = false
}

@(private)
csi_param_or_default :: proc "contextless" (parser: ^Ansi_Parser, index: int, fallback: int) -> int {
	if index < 0 || index >= parser.param_count {
		return fallback
	}
	val := int(parser.params[index])
	return val == 0 ? fallback : val
}

@(private)
ansi_apply_sgr :: proc "contextless" (parser: ^Ansi_Parser, grid: ^Terminal_Grid) {
	count := parser.param_count
	if count == 0 {
		grid.current_fg = .Default
		grid.current_bg = .Default
		grid.current_attrs = {}
		return
	}
	for i in 0 ..< count {
		code := parser.params[i]
		switch code {
		case 0:
			grid.current_fg = .Default
			grid.current_bg = .Default
			grid.current_attrs = {}
		case 1:
			grid.current_attrs += {.Bold}
		case 4:
			grid.current_attrs += {.Underline}
		case 7:
			grid.current_attrs += {.Reverse}
		case 22:
			grid.current_attrs -= {.Bold}
		case 24:
			grid.current_attrs -= {.Underline}
		case 27:
			grid.current_attrs -= {.Reverse}
		case 30 ..= 37:
			grid.current_fg = Ansi_Color(u8(Ansi_Color.Black) + u8(code - 30))
		case 39:
			grid.current_fg = .Default
		case 40 ..= 47:
			grid.current_bg = Ansi_Color(u8(Ansi_Color.Black) + u8(code - 40))
		case 49:
			grid.current_bg = .Default
		case 90 ..= 97:
			grid.current_fg = Ansi_Color(u8(Ansi_Color.Bright_Black) + u8(code - 90))
		case 100 ..= 107:
			grid.current_bg = Ansi_Color(u8(Ansi_Color.Bright_Black) + u8(code - 100))
		}
	}
}

@(private)
ansi_dispatch_csi :: proc "contextless" (parser: ^Ansi_Parser, grid: ^Terminal_Grid, final_byte: u8) {
	if parser.param_has_digit && parser.param_count < MAX_CSI_PARAMS {
		parser.param_count += 1
	}
	if parser.private_prefix {
		// Private DEC modes (e.g. ?25h/?25l) are ignored safely without corrupting grid state.
		return
	}
	switch final_byte {
	case 'H', 'f':
		row := csi_param_or_default(parser, 0, 1) - 1
		col := csi_param_or_default(parser, 1, 1) - 1
		grid.cursor_row = clamp(row, 0, grid.rows - 1)
		grid.cursor_col = clamp(col, 0, grid.cols - 1)
	case 'A':
		n := csi_param_or_default(parser, 0, 1)
		grid.cursor_row = max(0, grid.cursor_row - n)
	case 'B':
		n := csi_param_or_default(parser, 0, 1)
		grid.cursor_row = min(grid.rows - 1, grid.cursor_row + n)
	case 'C':
		n := csi_param_or_default(parser, 0, 1)
		grid.cursor_col = min(grid.cols - 1, grid.cursor_col + n)
	case 'D':
		n := csi_param_or_default(parser, 0, 1)
		grid.cursor_col = max(0, grid.cursor_col - n)
	case 'J':
		erase_select := parser.param_count > 0 ? parser.params[0] : 0
		blank := grid_blank_cell(grid.current_fg, grid.current_bg, {})
		cur := min(grid.cursor_row * grid.cols + min(grid.cursor_col, grid.cols - 1), grid.rows * grid.cols - 1)
		total := grid.rows * grid.cols
		switch erase_select {
		case 0:
			for i := cur; i < total; i += 1 {
				grid.cells[i] = blank
			}
		case 1:
			for i := 0; i <= cur; i += 1 {
				grid.cells[i] = blank
			}
		case 2, 3:
			for i := 0; i < total; i += 1 {
				grid.cells[i] = blank
			}
		}
	case 'K':
		erase_select := parser.param_count > 0 ? parser.params[0] : 0
		blank := grid_blank_cell(grid.current_fg, grid.current_bg, {})
		row_off := grid.cursor_row * grid.cols
		col := min(grid.cursor_col, grid.cols - 1)
		switch erase_select {
		case 0:
			for c := col; c < grid.cols; c += 1 {
				grid.cells[row_off + c] = blank
			}
		case 1:
			for c := 0; c <= col; c += 1 {
				grid.cells[row_off + c] = blank
			}
		case 2:
			for c := 0; c < grid.cols; c += 1 {
				grid.cells[row_off + c] = blank
			}
		}
	case 'm':
		ansi_apply_sgr(parser, grid)
	}
}

@(private)
ansi_flush_incomplete_utf8 :: proc "contextless" (parser: ^Ansi_Parser, grid: ^Terminal_Grid) {
	if parser.utf8_len > 0 {
		grid_put_rune(grid, text_encoding.REPLACEMENT_CHARACTER)
		parser.utf8_len = 0
		parser.utf8_expected = 0
	}
}

@(private)
ansi_handle_ground_byte :: proc "contextless" (parser: ^Ansi_Parser, grid: ^Terminal_Grid, b: u8) {
	// Continue an active multi-byte UTF-8 sequence.
	if parser.utf8_expected > 0 {
		if (b & 0xC0) == 0x80 {
			parser.utf8_buf[parser.utf8_len] = b
			parser.utf8_len += 1
			if parser.utf8_len == parser.utf8_expected {
				ch, dec_len, valid := text_encoding.character_decode(parser.utf8_buf[:parser.utf8_len], 0)
				if valid && dec_len == parser.utf8_expected {
					grid_put_rune(grid, ch)
				} else {
					grid_put_rune(grid, text_encoding.REPLACEMENT_CHARACTER)
				}
				parser.utf8_len = 0
				parser.utf8_expected = 0
			}
			return
		}
		// Non-continuation interrupted an incomplete UTF-8 sequence; emit replacement and reprocess b.
		ansi_flush_incomplete_utf8(parser, grid)
	}

	switch b {
	case 0x1B:
		parser.state = .Escape
	case '\r':
		grid.cursor_col = 0
	case '\n':
		if grid.cursor_row + 1 >= grid.rows {
			grid_scroll_up(grid)
		} else {
			grid.cursor_row += 1
		}
	case '\b':
		if grid.cursor_col > 0 {
			grid.cursor_col -= 1
		}
	case '\t':
		next_tab := ((grid.cursor_col / 8) + 1) * 8
		grid.cursor_col = min(next_tab, grid.cols - 1)
	case 0x20 ..= 0x7E:
		grid_put_rune(grid, rune(b))
	case 0xC2 ..= 0xDF:
		parser.utf8_buf[0] = b
		parser.utf8_len = 1
		parser.utf8_expected = 2
	case 0xE0 ..= 0xEF:
		parser.utf8_buf[0] = b
		parser.utf8_len = 1
		parser.utf8_expected = 3
	case 0xF0 ..= 0xF4:
		parser.utf8_buf[0] = b
		parser.utf8_len = 1
		parser.utf8_expected = 4
	case 0x80 ..= 0xC1, 0xF5 ..= 0xFF:
		grid_put_rune(grid, text_encoding.REPLACEMENT_CHARACTER)
	}
}

// ansi_feed processes an arbitrary chunk of terminal bytes into grid.
ansi_feed :: proc "contextless" (parser: ^Ansi_Parser, grid: ^Terminal_Grid, data: []u8) {
	if parser == nil || grid == nil || grid.cols < 1 || grid.rows < 1 || grid.cols > MAX_GRID_COLS || grid.rows > MAX_GRID_ROWS {
		return
	}
	for b in data {
		// CAN (0x18) and SUB (0x1A) abort any escape sequence cleanly per ECMA-48.
		if b == 0x18 || b == 0x1A {
			ansi_flush_incomplete_utf8(parser, grid)
			parser.state = .Ground
			continue
		}
		switch parser.state {
		case .Ground:
			ansi_handle_ground_byte(parser, grid, b)

		case .Escape:
			switch b {
			case '[':
				ansi_reset_csi(parser)
				parser.state = .Csi_Entry
			case ']':
				parser.state = .Osc_String
			case 0x1B:
				parser.state = .Escape
			case:
				parser.state = .Ground
			}

		case .Csi_Entry:
			switch b {
			case '?':
				parser.private_prefix = true
				parser.state = .Csi_Param
			case '0' ..= '9':
				parser.params[0] = u16(b - '0')
				parser.param_has_digit = true
				parser.state = .Csi_Param
			case ';':
				parser.params[0] = 0
				parser.param_count = 1
				parser.param_has_digit = false
				parser.state = .Csi_Param
			case 0x40 ..= 0x7E:
				ansi_dispatch_csi(parser, grid, b)
				parser.state = .Ground
			case 0x1B:
				parser.state = .Escape
			case:
				parser.state = .Csi_Ignore
			}

		case .Csi_Param:
			switch b {
			case '0' ..= '9':
				if parser.param_count < MAX_CSI_PARAMS {
					cur := u32(parser.params[parser.param_count]) * 10 + u32(b - '0')
					parser.params[parser.param_count] = cur > u32(MAX_CSI_PARAM_VALUE) ? MAX_CSI_PARAM_VALUE : u16(cur)
					parser.param_has_digit = true
				}
			case ';':
				if parser.param_count < MAX_CSI_PARAMS {
					parser.param_count += 1
				}
				parser.param_has_digit = false
			case 0x40 ..= 0x7E:
				ansi_dispatch_csi(parser, grid, b)
				parser.state = .Ground
			case 0x1B:
				parser.state = .Escape
			case:
				parser.state = .Csi_Ignore
			}

		case .Csi_Ignore:
			if b >= 0x40 && b <= 0x7E {
				parser.state = .Ground
			} else if b == 0x1B {
				parser.state = .Escape
			}

		case .Osc_String:
			if b == 0x07 {
				parser.state = .Ground
			} else if b == 0x1B {
				parser.state = .Osc_Esc
			}

		case .Osc_Esc:
			if b == '\\' {
				parser.state = .Ground
			} else if b == 0x1B {
				parser.state = .Escape
			} else {
				parser.state = .Osc_String
			}
		}
	}
}
