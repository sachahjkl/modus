package server

// The window, by the rules of docs/DESIGN.md: rectangles only, the grid of
// 8 pixels, a card for each subject with a caption that names its record,
// the colors of the concepts. Each value is a field of a record of the
// connection table (tcp.Table, tcp.Connection) or a count of this process.

import "modus:contract/value_kinds"
import "modus:display"
import "modus:graphics"
import "modus:interface"
import "modus:layout"
import "modus:network"
import "modus:system"
import "modus:tcp"
import "modus:web"

// Plan value: nominal logical dimensions of the server dashboard window.
WIDTH :: 976
HEIGHT :: 680

// The colors of the concepts (src/library/modus/graphics/rules.odin, docs/DESIGN.md)
// that this window uses for TCP:
//   boot program  a connection that starts: the handshake.
//   process       a connection that runs.
//   kernel        the end of a connection: the FIN states and TIME-WAIT.
//   memory        bytes and windows.
//   machine       the remote machines and the link.
//   not usable    a connection that ended.

// Plan value: height of one table row in logical pixels.
LINE :: 24

// Plan value: height of the top row of cards, fitting the six lines of MEASURES.
TOP_HEIGHT :: 168
// Plan value: fixed widths of the left and middle top cards; MEASURES fills the rest.
LISTEN_CARD_WIDTH :: 256
ANSWERS_CARD_WIDTH :: 232
// Plan value: fixed width of the connections table card; REQUESTS fills the rest.
CONNECTIONS_CARD_WIDTH :: 536

// Plan value: value column offset in LISTEN and MEASURES; "new connections" has 15 characters.
LISTEN_VALUE_COLUMN :: 120
MEASURES_VALUE_COLUMN :: 136

// Plan value: width of the congestion window bar representing 64 KiB.
WINDOW_BAR :: 56
// Plan value: maximum connection rows shown in the CONNECTIONS card at nominal height.
CONNECTION_ROWS_LIMIT :: 17

// Plan value: column counts of the two bottom tables.
CONNECTION_COLUMN_COUNT :: 6
REQUEST_COLUMN_COUNT :: 5

// Plan value: draw table record and text capacities, sized for all five cards
// and their maximum visible rows with headroom.
window_memory: interface.Window_Memory(1024, 16384)
// The layout tree of one frame (modus:layout). Lives in module memory, never on stack.
server_layout_tree: layout.Box_Tree
window_drawn_logged: bool

Server_Places :: struct {
	listen:              interface.Area,
	answers:             interface.Area,
	measures:            interface.Area,
	connections:         interface.Area,
	requests:            interface.Area,
	connections_content: interface.Area,
	requests_content:    interface.Area,
	connection_columns:  [CONNECTION_COLUMN_COUNT]layout.Table_Column_Place,
	request_columns:     [REQUEST_COLUMN_COUNT]layout.Table_Column_Place,
}

@(private = "file")
area_of :: proc "contextless" (tree: ^layout.Box_Tree, index: layout.Box_Index) -> interface.Area {
	box := layout.box_of(tree, index)
	if box == nil {
		return {}
	}
	return {int(box.rect.x), int(box.rect.y), int(box.rect.width), int(box.rect.height)}
}

@(private = "file")
card_content_of :: proc "contextless" (area: interface.Area) -> interface.Area {
	return {
		x      = area.x + graphics.MARGIN,
		y      = area.y + graphics.TITLE,
		width  = max(area.width - 2 * graphics.MARGIN, 0),
		height = max(area.height - graphics.TITLE - graphics.GAP, 0),
	}
}

// server_layout computes the five dashboard cards and the column places of the
// CONNECTIONS and REQUESTS tables with modus:layout.
server_layout :: proc "contextless" (tree: ^layout.Box_Tree, width, height: int) -> (places: Server_Places, ok: bool) {
	if tree == nil || width <= 0 || height <= 0 || width > layout.LENGTH_LIMIT || height > layout.LENGTH_LIMIT {
		return {}, false
	}
	gap := i32(graphics.GAP)
	if layout.tree_begin(tree, i32(width), i32(height), {child_axis = .Y, padding = {.X = gap, .Y = gap}, gap = gap}) != .Done {
		return {}, false
	}
	_, s0 := layout.box_open(tree, {size = {.X = layout.fill(), .Y = layout.px(TOP_HEIGHT)}, child_axis = .X, gap = gap})
	listen_box, s1 := layout.box_add(tree, {size = {.X = layout.px(LISTEN_CARD_WIDTH), .Y = layout.fill()}})
	answers_box, s2 := layout.box_add(tree, {size = {.X = layout.px(ANSWERS_CARD_WIDTH), .Y = layout.fill()}})
	measures_box, s3 := layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.fill()}})
	sc0 := layout.box_close(tree)

	_, s4 := layout.box_open(tree, {size = {.X = layout.fill(), .Y = layout.fill()}, child_axis = .X, gap = gap})
	connections_box, s5 := layout.box_add(tree, {size = {.X = layout.px(CONNECTIONS_CARD_WIDTH), .Y = layout.fill()}})
	requests_box, s6 := layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.fill()}})
	sc1 := layout.box_close(tree)

	if s0 != .Done || s1 != .Done || s2 != .Done || s3 != .Done || sc0 != .Done || s4 != .Done || s5 != .Done || s6 != .Done || sc1 != .Done || layout.solve(tree) != .Done {
		return {}, false
	}

	places.listen = area_of(tree, listen_box)
	places.answers = area_of(tree, answers_box)
	places.measures = area_of(tree, measures_box)
	places.connections = area_of(tree, connections_box)
	places.requests = area_of(tree, requests_box)
	places.connections_content = card_content_of(places.connections)
	places.requests_content = card_content_of(places.requests)

	// Plan value: column widths of CONNECTIONS (total 504 px at nominal width).
	// remote takes remaining width; state, in, out, srtt, and cwnd keep fixed rooms.
	conn_spec := [CONNECTION_COLUMN_COUNT]layout.Table_Column {
		{weight = 1, least = 120}, // remote
		{width = 96}, // state ("SYN-RECEIVED" is 12 cells)
		{width = 72}, // in (right-aligned)
		{width = 80}, // out (right-aligned)
		{width = 72}, // srtt (right-aligned)
		{width = WINDOW_BAR + graphics.GAP}, // cwnd bar with leading gap
	}
	conn_rect := layout.Rect{i32(places.connections_content.x), i32(places.connections_content.y), i32(places.connections_content.width), i32(places.connections_content.height)}
	if layout.table_columns(conn_spec[:], places.connection_columns[:], conn_rect, 0) != .Done {
		return {}, false
	}

	// Plan value: column widths of REQUESTS (total 384 px at nominal width).
	// method fits "OPTIONS" plus one cell; target fills remaining space and wraps.
	req_spec := [REQUEST_COLUMN_COUNT]layout.Table_Column {
		{width = 8 * graphics.CELL_WIDTH}, // method
		{weight = 1, least = 8 * graphics.CELL_WIDTH}, // target
		{width = 48}, // status ("status" header + 3-digit code)
		{width = 56}, // bytes (right-aligned)
		{width = 80}, // time (right-aligned)
	}
	req_rect := layout.Rect{i32(places.requests_content.x), i32(places.requests_content.y), i32(places.requests_content.width), i32(places.requests_content.height)}
	if layout.table_columns(req_spec[:], places.request_columns[:], req_rect, 0) != .Done {
		return {}, false
	}

	return places, true
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

connection_row_draw :: proc "contextless" (frame: ^interface.Frame, inside: interface.Area, cols: [CONNECTION_COLUMN_COUNT]layout.Table_Column_Place, y: int, connection: ^tcp.Connection, how: string, row_index: int) {
	table := frame.table
	interface.table_band(frame, {inside.x - graphics.GAP, y - 4, inside.width + 2 * graphics.GAP, LINE}, row_index)
	ended := how != ""
	text_color := graphics.Color(ended ? graphics.colors.dim : graphics.colors.text)
	buffer: [48]u8
	writer := system.Writer{buffer = buffer[:]}
	network.address_write(&writer, connection.remote_address)
	system.write_bytes(&writer, {':'})
	system.write_unsigned(&writer, u64(connection.remote_port))
	interface.draw_text(table, int(cols[0].x), y, system.written(&writer), ended ? graphics.colors.dim : graphics.colors.machine)
	if ended {
		interface.draw_text(table, int(cols[1].x), y, how, how == "reset" || how == "timed out" || how == "aborted" ? graphics.colors.failed : graphics.colors.not_usable)
	} else {
		interface.draw_text(table, int(cols[1].x), y, state_names[connection.state], state_color(connection.state))
	}
	interface.draw_text_right(table, int(cols[2].x + cols[2].width), y, size_text(buffer[:], connection.bytes_received), text_color)
	interface.draw_text_right(table, int(cols[3].x + cols[3].width), y, size_text(buffer[:], connection.bytes_sent), text_color)
	interface.draw_text_right(table, int(cols[4].x + cols[4].width), y, connection.rtt_samples == 0 ? "-" : time_text(buffer[:], connection.smoothed_rtt), text_color)
	// The congestion window: its width is its size, against the window limit of 64 KiB.
	bar_width := min(WINDOW_BAR, max(int(cols[5].width) - graphics.GAP, 0))
	window_bytes := min(u64(connection.congestion_window), u64(tcp.WINDOW_LIMIT))
	interface.bar(frame, {int(cols[5].x) + graphics.GAP, y + 4, bar_width, 8}, window_bytes, u64(tcp.WINDOW_LIMIT), ended ? graphics.colors.not_usable : graphics.colors.memory)
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
access_row_height :: proc "contextless" (table: ^interface.Draw_Table, record: ^Access_Row, target_room: int) -> int {
	lines := max(interface.text_wrapped_line_count(table, {}, access_target(record), target_room), 1)
	return LINE + (lines - 1) * interface.line_height({})
}

// access_row_draw draws the row of a request. The target is whole, on the
// lines that it needs in its column.
access_row_draw :: proc "contextless" (frame: ^interface.Frame, inside: interface.Area, cols: [REQUEST_COLUMN_COUNT]layout.Table_Column_Place, y: int, record: ^Access_Row, target_room: int, row_height: int, row_index: int) {
	table := frame.table
	interface.table_band(frame, {inside.x - graphics.GAP, y - 4, inside.width + 2 * graphics.GAP, row_height}, row_index)
	buffer: [32]u8
	method := web.request_method_name(record.method)
	interface.draw_text(table, int(cols[0].x), y, method == "" ? "-" : method, graphics.colors.dim)
	interface.draw_text_wrapped(table, int(cols[1].x), y, target_room, access_target(record), graphics.colors.text)
	interface.draw_text(table, int(cols[2].x) + graphics.GAP, y, system.format(buffer[:], u64(record.status)), status_color(record.status))
	interface.draw_text_right(table, int(cols[3].x + cols[3].width), y, size_text(buffer[:], record.bytes), graphics.colors.text)
	interface.draw_text_right(table, int(cols[4].x + cols[4].width), y, time_text(buffer[:], max(record.time, 1)), graphics.colors.machine)
}

draw :: proc "contextless" (window: ^display.Window) {
	started := system.nanoseconds()
	frame := interface.window_frame_start(&window_memory, window)
	table := frame.table
	width, height := window.width, window.height
	interface.background(&frame, {0, 0, width, height})

	places, layout_ok := server_layout(&server_layout_tree, width, height)
	if layout_ok {
		buffer: [64]u8
		other: [64]u8
		open := tcp_open_count()

		// The listen grant and the table.
		inside := interface.card(&frame, places.listen, "LISTEN", "tcp.Table", graphics.colors.process)
		interface.large_number(&frame, inside.x, inside.y, system.format(buffer[:], u64(open)), graphics.colors.process)
		interface.draw_caption(&frame, inside.x, inside.y + interface.line_height(interface.FONT_LARGE), inside.width, open == 1 ? "connection" : "connections")
		interface.label_value_line(&frame, {inside.x, inside.y + 56, inside.width, 20}, "port", system.format(buffer[:], u64(listen_port), ", any host"), nil, LISTEN_VALUE_COLUMN)
		interface.label_value_line(&frame, {inside.x, inside.y + 76, inside.width, 20}, "most at once", system.format(buffer[:], u64(most_open), " of ", u64(CAPACITY)), nil, LISTEN_VALUE_COLUMN)
		interface.label_value_line(&frame, {inside.x, inside.y + 96, inside.width, 20}, "accepted", system.format(buffer[:], accepted, ", ", aborted_count, " ended"), nil, LISTEN_VALUE_COLUMN)

		// The answers by class of status.
		inside = interface.card(&frame, places.answers, "ANSWERS", "web.Request", graphics.colors.memory)
		interface.large_number(&frame, inside.x, inside.y, system.format(buffer[:], requests_answered), graphics.colors.memory)
		interface.draw_caption(&frame, inside.x, inside.y + interface.line_height(interface.FONT_LARGE), inside.width, "requests")
		total := max(requests_answered, 1)
		classes := [3]int{2, 4, 5}
		names := [3]string{"2xx", "4xx", "5xx"}
		colors := [3]graphics.Color{graphics.colors.process, graphics.colors.boot_program, graphics.colors.failed}
		for class, row in classes {
			y := inside.y + 56 + row * 20
			interface.draw_text(table, inside.x, y, names[row], graphics.colors.dim, interface.FONT_INTERFACE)
			interface.bar(&frame, {inside.x + 40, y + 4, 96, 8}, status_classes[class], total, colors[row])
			interface.draw_text(table, inside.x + 144, y, system.format(buffer[:], status_classes[class]), graphics.colors.text)
		}

		// The measures, with the cycle counter.
		inside = interface.card(&frame, places.measures, "MEASURES", "system.nanoseconds", graphics.colors.machine)
		interface.label_value_line(&frame, {inside.x, inside.y + 0, inside.width, 20}, "handshake", handshake_last == 0 ? "" : system.format(buffer[:], time_text(other[:], handshake_last), ", least ", handshake_least, " us"), graphics.colors.machine, MEASURES_VALUE_COLUMN)
		interface.label_value_line(&frame, {inside.x, inside.y + 20, inside.width, 20}, "one connection", best_keep_alive_rate == 0 ? "" : system.format(buffer[:], best_keep_alive_rate, " requests in 1 s, the best"), graphics.colors.machine, MEASURES_VALUE_COLUMN)
		interface.label_value_line(&frame, {inside.x, inside.y + 40, inside.width, 20}, "new connections", best_new_connection_rate == 0 ? "" : system.format(buffer[:], best_new_connection_rate, " requests in 1 s, the best"), graphics.colors.machine, MEASURES_VALUE_COLUMN)
		interface.label_value_line(&frame, {inside.x, inside.y + 60, inside.width, 20}, "one second", best_second_requests == 0 ? "" : system.format(buffer[:], best_second_requests, " requests at most"), graphics.colors.machine, MEASURES_VALUE_COLUMN)
		interface.label_value_line(&frame, {inside.x, inside.y + 80, inside.width, 20}, "one draw", draw_time == 0 ? "" : time_text(buffer[:], draw_time), graphics.colors.text, MEASURES_VALUE_COLUMN)
		interface.label_value_line(&frame, {inside.x, inside.y + 100, inside.width, 20}, "ISN secret", system.format(buffer[:], "modus:random, ", process_generator.served, " B"), graphics.colors.text, MEASURES_VALUE_COLUMN)

		// The connection table, live, then the connections that ended.
		inside = interface.card(&frame, places.connections, "CONNECTIONS", "tcp.Connection", graphics.colors.process)
		conn_cols := places.connection_columns
		interface.draw_text(table, int(conn_cols[0].x), inside.y, "remote", graphics.colors.dim, interface.FONT_INTERFACE)
		interface.draw_text(table, int(conn_cols[1].x), inside.y, "state", graphics.colors.dim, interface.FONT_INTERFACE)
		interface.draw_text_right(table, int(conn_cols[2].x + conn_cols[2].width), inside.y, "in", graphics.colors.dim, interface.FONT_INTERFACE)
		interface.draw_text_right(table, int(conn_cols[3].x + conn_cols[3].width), inside.y, "out", graphics.colors.dim, interface.FONT_INTERFACE)
		interface.draw_text_right(table, int(conn_cols[4].x + conn_cols[4].width), inside.y, "srtt", graphics.colors.dim, interface.FONT_INTERFACE)
		interface.draw_text(table, int(conn_cols[5].x) + graphics.GAP, inside.y, "cwnd", graphics.colors.dim, interface.FONT_INTERFACE)
		interface.draw_rectangle(table, inside.x, inside.y + 20, inside.width, 1, graphics.colors.track)
		y := inside.y + 28
		rows := 0
		for &connection in connections {
			if connection.state == .Closed || rows == CONNECTION_ROWS_LIMIT || y - 4 + LINE > inside.y + inside.height {
				continue
			}
			connection_row_draw(&frame, inside, conn_cols, y, &connection, "", rows)
			y += LINE
			rows += 1
		}
		if rows == 0 {
			interface.draw_text(table, inside.x, y, "no connection: the table waits for a SYN", graphics.colors.dim, interface.FONT_INTERFACE)
			y += LINE
			rows += 1
		}
		for back in 1 ..= CONNECTION_HISTORY {
			if rows == CONNECTION_ROWS_LIMIT || y - 4 + LINE > inside.y + inside.height {
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
			connection_row_draw(&frame, inside, conn_cols, y, &item.record, how, rows)
			y += LINE
			rows += 1
		}

		// The last requests, the newest first.
		inside = interface.card(&frame, places.requests, "REQUESTS", "Access_Record", graphics.colors.memory)
		req_cols := places.request_columns
		target_room := max(int(req_cols[1].width) - graphics.CELL_WIDTH, graphics.CELL_WIDTH)
		interface.draw_text(table, int(req_cols[0].x), inside.y, "method", graphics.colors.dim, interface.FONT_INTERFACE)
		interface.draw_text(table, int(req_cols[1].x), inside.y, "target", graphics.colors.dim, interface.FONT_INTERFACE)
		interface.draw_text(table, int(req_cols[2].x), inside.y, "status", graphics.colors.dim, interface.FONT_INTERFACE)
		interface.draw_text_right(table, int(req_cols[3].x + req_cols[3].width), inside.y, "bytes", graphics.colors.dim, interface.FONT_INTERFACE)
		interface.draw_text_right(table, int(req_cols[4].x + req_cols[4].width), inside.y, "time", graphics.colors.dim, interface.FONT_INTERFACE)
		interface.draw_rectangle(table, inside.x, inside.y + 20, inside.width, 1, graphics.colors.track)
		y = inside.y + 28
		shown := 0
		// The table is a view of the newest requests: it shows the rows that
		// fit whole in the card, and the log has each request.
		for back in 1 ..= ACCESS_HISTORY {
			record := &access_records[(access_next - back + ACCESS_HISTORY) % ACCESS_HISTORY]
			if record.status == 0 {
				break
			}
			row_h := access_row_height(table, record, target_room)
			if y - 4 + row_h > inside.y + inside.height {
				break
			}
			access_row_draw(&frame, inside, req_cols, y, record, target_room, row_h, shown)
			y += row_h
			shown += 1
		}
		if shown == 0 {
			interface.draw_text(table, inside.x, y, "no request yet", graphics.colors.dim, interface.FONT_INTERFACE)
		}
	}

	interface.window_frame_end(&window_memory.drawing, &frame, window)
	microseconds_taken := (system.nanoseconds() - started) / 1000
	if !window_drawn_logged && !window_memory.drawing.late {
		window_drawn_logged = true
		system.log_fact(.Info, Window_Drawn{drawing = value_kinds.Time_In_Microseconds(microseconds_taken)})
	}
	if !window_memory.drawing.late {
		draw_time = microseconds_taken
	}
}
