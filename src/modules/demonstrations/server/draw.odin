package server

// The window, by the rules of docs/DESIGN.md: rectangles only, the grid of
// 8 pixels, a card for each subject with a caption that names its record,
// the colors of the concepts. Each value is a field of a record of the
// connection table (tcp.Table, tcp.Connection) or a count of this process.

import "modus:contract/value_kinds"
import "modus:support/display"
import "modus:support/graphics"
import "modus:support/interface"
import "modus:support/network"
import "modus:support/system"
import "modus:support/tcp"
import "modus:support/web"

WIDTH :: 976
HEIGHT :: 680

// The colors of the concepts (src/library/support/graphics/rules.odin, docs/DESIGN.md
// section 4) that this window uses for TCP:
//   boot program  a connection that starts: the handshake.
//   process       a connection that runs.
//   kernel        the end of a connection: the FIN states and TIME-WAIT.
//   memory        bytes and windows.
//   machine       the remote machines and the link.
//   not usable    a connection that ended.

CARD_TITLE :: graphics.TITLE
CARD_MARGIN :: graphics.MARGIN
LINE :: 24

// bar draws the full part of a bar: 120 % of its color at the top, 78 % at the bottom.
bar :: proc "contextless" (canvas: graphics.Canvas, x, y, width, height: int, color: graphics.Color) {
	graphics.block(canvas, x, y, width, height, graphics.shade(color, 120), graphics.shade(color, 78))
}

// large_number draws the one number of a card at the large text size
// (docs/DESIGN.md, "5. Text"). Its line is LARGE_NUMBER_HEIGHT high, an
// even size: the caption under it starts there.
large_number :: proc "contextless" (canvas: graphics.Canvas, x, y: int, characters: string, color: graphics.Color) {
	graphics.text_sized(canvas, x, y, characters, color, interface.font_text_size(interface.FONT_LARGE))
}
LARGE_NUMBER_HEIGHT :: graphics.TEXT_LARGE

// caption draws a caption in the dim color at the caption size: the label
// under the number of a card, or the caption of a card.
caption :: proc "contextless" (canvas: graphics.Canvas, x, y: int, characters: string) {
	graphics.text_sized(canvas, x, y, characters, graphics.colors.dim, interface.font_text_size(interface.FONT_CAPTION_CELLS))
}

// card draws the frame of one subject and gives the canvas of its content.
// Its caption is at the caption size, on the baseline of its title.
card :: proc "contextless" (canvas: graphics.Canvas, x, y, width, height: int, title, caption_text: string, accent: graphics.Color) -> graphics.Canvas {
	graphics.block(canvas, x, y, width, height, graphics.shade(accent, 28), graphics.shade(accent, 14))
	graphics.block(canvas, x + 1, y + 1, width - 2, height - 2, graphics.colors.card_top, graphics.colors.card_bottom)
	title_top := y + 12
	graphics.block(canvas, x + CARD_MARGIN, title_top, 4, 16, graphics.shade(accent, 130), accent)
	after := graphics.text(canvas, x + CARD_MARGIN + 12, title_top, title, accent)
	caption(canvas, after + 2 * graphics.GAP, interface.text_top_on_baseline(nil, {}, title_top, interface.FONT_CAPTION_CELLS), caption_text)
	return graphics.view(canvas, x + CARD_MARGIN, y + CARD_TITLE, width - 2 * CARD_MARGIN, height - CARD_TITLE - graphics.GAP)
}

// right draws a text that ends at x.
right :: proc "contextless" (canvas: graphics.Canvas, x, y: int, text: string, color: graphics.Color) {
	graphics.text(canvas, x - graphics.text_width(text), y, text, color)
}

// fact draws "name   value" on one line of a card.
// A name and its value. The value starts at value_column: one character of
// 8 pixels after the longest name of its card.
fact :: proc "contextless" (canvas: graphics.Canvas, y: int, name: string, value: string, color: Maybe(graphics.Color) = nil, value_column := 120) {
	graphics.text(canvas, 0, y, name, graphics.colors.dim)
	value_color := color.? or_else graphics.colors.text
	graphics.text(canvas, value_column, y, value, value == "" ? graphics.colors.dim : value_color)
}

size_text :: proc "contextless" (buffer: []u8, bytes: u64) -> string {
	switch {
	case bytes < 1 << 10:
		return system.format(buffer, bytes, " B")
	case bytes < 1 << 20:
		return system.format(buffer, bytes >> 10, ".", (bytes & 1023) * 10 >> 10, " KiB")
	}
	return system.format(buffer, bytes >> 20, ".", (bytes & (1 << 20 - 1)) * 10 >> 20, " MiB")
}

time_text :: proc "contextless" (buffer: []u8, microseconds: u64) -> string {
	switch {
	case microseconds == 0:
		return "not known yet"
	case microseconds < 10_000:
		return system.format(buffer, microseconds, " us")
	case microseconds < 1_000_000:
		return system.format(buffer, microseconds / 1000, ".", microseconds % 1000 / 100, " ms")
	}
	return system.format(buffer, microseconds / 1_000_000, ".", microseconds % 1_000_000 / 100_000, " s")
}

@(rodata)
state_names := [tcp.State]string {
	.Closed       = "CLOSED",
	.Syn_Sent     = "SYN-SENT",
	.Syn_Received = "SYN-RECEIVED",
	.Established  = "ESTABLISHED",
	.Fin_Wait_1   = "FIN-WAIT-1",
	.Fin_Wait_2   = "FIN-WAIT-2",
	.Closing      = "CLOSING",
	.Time_Wait    = "TIME-WAIT",
	.Close_Wait   = "CLOSE-WAIT",
	.Last_Ack     = "LAST-ACK",
}

state_color :: proc "contextless" (state: tcp.State) -> graphics.Color {
	switch state {
	case .Syn_Sent, .Syn_Received:
		return graphics.colors.boot_program
	case .Established, .Close_Wait:
		return graphics.colors.process
	case .Closed:
		return graphics.colors.not_usable
	case .Fin_Wait_1, .Fin_Wait_2, .Closing, .Time_Wait, .Last_Ack:
		// The end of a connection.
	}
	return graphics.colors.kernel
}

// The columns of the table of connections (a card 536 pixels wide).
COLUMN_STATE :: 120
// "new connections", the longest name of MEASURES, has 15 characters.
MEASURES_VALUE_COLUMN :: 136
COLUMN_IN :: 288 // Right edges.
COLUMN_OUT :: 368
COLUMN_RTT :: 440
COLUMN_WINDOW :: 448 // A bar of WINDOW_BAR pixels for 64 KiB.
WINDOW_BAR :: 56

// The columns of the table of the last requests (a card 416 pixels wide).
// The target starts one character after the longest name of a method
// ("OPTIONS", 7 characters), and its box ends one character before the
// status: a target wider than the box goes on more lines
// (docs/INTERFACE.md, "The text in a box").
ACCESS_TARGET :: 8 * graphics.CELL_WIDTH
ACCESS_STATUS :: 208
ACCESS_TARGET_ROOM :: ACCESS_STATUS - graphics.CELL_WIDTH - ACCESS_TARGET
ACCESS_BYTES :: 304 // Right edges.
ACCESS_TIME :: 384
#assert(ACCESS_TIME <= 416 - 2 * CARD_MARGIN)

// The cards of the top row, as high as the six lines of MEASURES; the two
// tables under them.
TOP_HEIGHT :: 168
TABLES_Y :: 8 + TOP_HEIGHT + 8
TABLES_HEIGHT :: HEIGHT - TABLES_Y - 8

connection_row_draw :: proc "contextless" (canvas: graphics.Canvas, y: int, connection: ^tcp.Connection, how: string, band: bool) {
	if band {
		graphics.fill(canvas, -8, y - 4, canvas.width + 16, LINE, graphics.colors.track)
	}
	ended := how != ""
	text_color := graphics.Color(ended ? graphics.colors.dim : graphics.colors.text)
	buffer: [48]u8
	writer := system.Writer{buffer = buffer[:]}
	network.address_write(&writer, connection.remote_address)
	system.write_bytes(&writer, {':'})
	system.write_unsigned(&writer, u64(connection.remote_port))
	graphics.text(canvas, 0, y, system.written(&writer), ended ? graphics.colors.dim : graphics.colors.machine)
	if ended {
		graphics.text(canvas, COLUMN_STATE, y, how, how == "reset" || how == "timed out" || how == "aborted" ? graphics.colors.failed : graphics.colors.not_usable)
	} else {
		graphics.text(canvas, COLUMN_STATE, y, state_names[connection.state], state_color(connection.state))
	}
	right(canvas, COLUMN_IN, y, size_text(buffer[:], connection.bytes_received), text_color)
	right(canvas, COLUMN_OUT, y, size_text(buffer[:], connection.bytes_sent), text_color)
	right(canvas, COLUMN_RTT, y, connection.rtt_samples == 0 ? "-" : time_text(buffer[:], connection.smoothed_rtt), text_color)
	// The congestion window: its width is its size, against the window limit of 64 KiB.
	graphics.fill(canvas, COLUMN_WINDOW, y + 4, WINDOW_BAR, 8, graphics.colors.track)
	window := min(u64(connection.congestion_window), u64(tcp.WINDOW_LIMIT))
	filled := int(window * WINDOW_BAR / tcp.WINDOW_LIMIT)
	if filled > 0 {
		bar(canvas, COLUMN_WINDOW, y + 4, filled, 8, ended ? graphics.colors.not_usable : graphics.colors.memory)
	}
}

status_color :: proc "contextless" (status: int) -> graphics.Color {
	switch {
	case status < 300:
		return graphics.colors.process
	case status < 500:
		return graphics.colors.boot_program
	}
	return graphics.colors.failed
}

// access_target gives the target of a request as the record keeps it.
access_target :: proc "contextless" (record: ^Access_Row) -> string {
	return string(record.target[:clamp(record.target_length, 0, len(record.target))])
}

// access_row_height gives the height of the row of a request: a line of the
// table, and one line of text more for each more line of its target.
access_row_height :: proc "contextless" (record: ^Access_Row) -> int {
	lines := max(interface.text_wrapped_line_count(nil, {}, access_target(record), ACCESS_TARGET_ROOM), 1)
	return LINE + (lines - 1) * graphics.LINE_HEIGHT
}

// access_row_draw draws the row of a request. The target is whole, on the
// lines that it needs in its column (the rule of interface.text_wrap_line;
// the window draws with src/library/support/graphics).
access_row_draw :: proc "contextless" (canvas: graphics.Canvas, y: int, record: ^Access_Row, band: bool) {
	if band {
		graphics.fill(canvas, -8, y - 4, canvas.width + 16, access_row_height(record), graphics.colors.track)
	}
	buffer: [32]u8
	method := web.request_method_name(record.method)
	graphics.text(canvas, 0, y, method == "" ? "-" : method, graphics.colors.dim)
	rest := access_target(record)
	for line_y := y; len(rest) > 0; line_y += graphics.LINE_HEIGHT {
		line: string
		line, rest = interface.text_wrap_line(nil, {}, rest, ACCESS_TARGET_ROOM)
		graphics.text(canvas, ACCESS_TARGET, line_y, line, graphics.colors.text)
	}
	graphics.text(canvas, ACCESS_STATUS, y, system.format(buffer[:], u64(record.status)), status_color(record.status))
	right(canvas, ACCESS_BYTES, y, size_text(buffer[:], record.bytes), graphics.colors.text)
	right(canvas, ACCESS_TIME, y, time_text(buffer[:], max(record.time, 1)), graphics.colors.machine)
}

draw :: proc "contextless" (window: ^display.Window) {
	started := system.nanoseconds()
	canvas := window.canvas
	graphics.clear(canvas, graphics.colors.background)
	for y := 12; y < HEIGHT; y += graphics.POINT_STEP {
		for x := 12; x < WIDTH; x += graphics.POINT_STEP {
			graphics.fill(canvas, x, y, graphics.POINT_SIZE, graphics.POINT_SIZE, graphics.colors.point)
		}
	}
	buffer: [64]u8
	other: [64]u8
	open := tcp_open_count()

	// The listen grant and the table.
	inside := card(canvas, 8, 8, 256, TOP_HEIGHT, "LISTEN", "tcp.Table", graphics.colors.process)
	large_number(inside, 0, 0, system.format(buffer[:], u64(open)), graphics.colors.process)
	caption(inside, 0, LARGE_NUMBER_HEIGHT, open == 1 ? "connection" : "connections")
	fact(inside, 56, "port", system.format(buffer[:], u64(listen_port), ", any host"))
	fact(inside, 76, "most at once", system.format(buffer[:], u64(most_open), " of ", u64(CAPACITY)))
	fact(inside, 96, "accepted", system.format(buffer[:], accepted, ", ", aborted_count, " ended"))

	// The answers by class of status.
	inside = card(canvas, 272, 8, 232, TOP_HEIGHT, "ANSWERS", "web.Request", graphics.colors.memory)
	large_number(inside, 0, 0, system.format(buffer[:], requests_answered), graphics.colors.memory)
	caption(inside, 0, LARGE_NUMBER_HEIGHT, "requests")
	total := max(requests_answered, 1)
	classes := [3]int{2, 4, 5}
	names := [3]string{"2xx", "4xx", "5xx"}
	colors := [3]graphics.Color{graphics.colors.process, graphics.colors.boot_program, graphics.colors.failed}
	for class, row in classes {
		y := 56 + row * 20
		graphics.text(inside, 0, y, names[row], graphics.colors.dim)
		graphics.fill(inside, 40, y + 4, 96, 8, graphics.colors.track)
		filled := int(status_classes[class] * 96 / total)
		if filled > 0 {
			bar(inside, 40, y + 4, filled, 8, colors[row])
		}
		graphics.text(inside, 144, y, system.format(buffer[:], status_classes[class]), graphics.colors.text)
	}

	// The measures, with the cycle counter.
	inside = card(canvas, 512, 8, 456, TOP_HEIGHT, "MEASURES", "system.nanoseconds", graphics.colors.machine)
	fact(inside, 0, "handshake", handshake_last == 0 ? "" : system.format(buffer[:], time_text(other[:], handshake_last), ", least ", handshake_least, " us"), graphics.colors.machine, MEASURES_VALUE_COLUMN)
	fact(inside, 20, "one connection", best_keep_alive_rate == 0 ? "" : system.format(buffer[:], best_keep_alive_rate, " requests in 1 s, the best"), graphics.colors.machine, MEASURES_VALUE_COLUMN)
	fact(inside, 40, "new connections", best_new_connection_rate == 0 ? "" : system.format(buffer[:], best_new_connection_rate, " requests in 1 s, the best"), graphics.colors.machine, MEASURES_VALUE_COLUMN)
	fact(inside, 60, "one second", best_second_requests == 0 ? "" : system.format(buffer[:], best_second_requests, " requests at most"), graphics.colors.machine, MEASURES_VALUE_COLUMN)
	fact(inside, 80, "one draw", draw_time == 0 ? "" : time_text(buffer[:], draw_time), graphics.colors.text, MEASURES_VALUE_COLUMN)
	fact(inside, 100, "ISN secret", system.format(buffer[:], "modus:support/random, ", process_generator.served, " B"), graphics.colors.text, MEASURES_VALUE_COLUMN)

	// The connection table, live, then the connections that ended.
	inside = card(canvas, 8, TABLES_Y, 536, TABLES_HEIGHT, "CONNECTIONS", "tcp.Connection", graphics.colors.process)
	graphics.text(inside, 0, 0, "remote", graphics.colors.dim)
	graphics.text(inside, COLUMN_STATE, 0, "state", graphics.colors.dim)
	right(inside, COLUMN_IN, 0, "in", graphics.colors.dim)
	right(inside, COLUMN_OUT, 0, "out", graphics.colors.dim)
	right(inside, COLUMN_RTT, 0, "srtt", graphics.colors.dim)
	graphics.text(inside, COLUMN_WINDOW, 0, "cwnd", graphics.colors.dim)
	graphics.fill(inside, 0, 20, inside.width, 1, graphics.colors.track)
	y := 28
	rows := 0
	ROWS :: 17
	for &connection in connections {
		if connection.state == .Closed || rows == ROWS {
			continue
		}
		connection_row_draw(inside, y, &connection, "", rows % 2 == 1)
		y += LINE
		rows += 1
	}
	if rows == 0 {
		graphics.text(inside, 0, y, "no connection: the table waits for a SYN", graphics.colors.dim)
		y += LINE
		rows += 1
	}
	for back in 1 ..= CONNECTION_HISTORY {
		if rows == ROWS {
			break
		}
		item := &ended_connections[(ended_connection_next - back + CONNECTION_HISTORY) % CONNECTION_HISTORY]
		if !item.known {
			break
		}
		// A connection in TIME-WAIT is in the history already: its live row shows it.
		waits := false
		for &connection in connections {
			if connection.state == .Time_Wait && connection.remote_address == item.record.remote_address && connection.remote_port == item.record.remote_port {
				waits = true
			}
		}
		if waits {
			continue
		}
		how := item.how
		switch {
		case how == "reset by the remote":
			how = "reset"
		case how == "closed, the remote first":
			how = "closed by it"
		case how == "closed, this server first":
			how = "closed by us"
		case len(how) >= 7 && how[:7] == "aborted":
			how = "aborted"
		}
		connection_row_draw(inside, y, &item.record, how, rows % 2 == 1)
		y += LINE
		rows += 1
	}

	// The last requests, the newest first.
	inside = card(canvas, 552, TABLES_Y, 416, TABLES_HEIGHT, "REQUESTS", "Access_Record", graphics.colors.memory)
	graphics.text(inside, 0, 0, "method", graphics.colors.dim)
	graphics.text(inside, ACCESS_TARGET, 0, "target", graphics.colors.dim)
	graphics.text(inside, ACCESS_STATUS - 8, 0, "status", graphics.colors.dim)
	right(inside, ACCESS_BYTES, 0, "bytes", graphics.colors.dim)
	right(inside, ACCESS_TIME, 0, "time", graphics.colors.dim)
	graphics.fill(inside, 0, 20, inside.width, 1, graphics.colors.track)
	y = 28
	shown := 0
	// The table is a view of the newest requests: it shows the rows that
	// fit whole in the card, and the log has each request.
	for back in 1 ..= ACCESS_HISTORY {
		record := &access_records[(access_next - back + ACCESS_HISTORY) % ACCESS_HISTORY]
		if record.status == 0 || y - 4 + access_row_height(record) > inside.height {
			break
		}
		access_row_draw(inside, y, record, shown % 2 == 1)
		y += access_row_height(record)
		shown += 1
	}
	if shown == 0 {
		graphics.text(inside, 0, y, "no request yet", graphics.colors.dim)
	}
	display.present(window)
	microseconds_taken := (system.nanoseconds() - started) / 1000
	if draw_time == 0 {
		system.log_fact(.Info, Window_Drawn{drawing = value_kinds.Time_In_Microseconds(microseconds_taken)})
	}
	draw_time = microseconds_taken
}
