package quic_echo

// The window: the public key of the server (a client pins it), its
// connections with their counts, and what the server refused.

import "modus:support/display"
import "modus:support/graphics"
import "modus:support/interface"
import "modus:support/quic"

WIDTH :: 960
HEIGHT :: 640
LINE :: interface.TABLE_LINE
CONNECTIONS_HEIGHT :: 244 // The card of the connections: its title, the header of the table, six rows, and the line that counts the connections with no row.
COUNTED_Y :: 116 + CONNECTIONS_HEIGHT + 8 // The card of the counts, under it.
// The card of the counts holds seven rows, three of them with a sentence of two lines.
#assert(HEIGHT - COUNTED_Y - 8 - graphics.TITLE - 8 >= 7 * LINE + 3 * graphics.LINE_HEIGHT)

window_memory: interface.Window_Memory(768, 16384)

state_text :: proc "contextless" (connection: ^quic.Connection) -> string {
	switch connection.state {
	case .Idle:
		return "idle"
	case .Handshake:
		return "handshake"
	case .Connected:
		return connection.handshake_confirmed ? "connected" : "connected, not confirmed"
	case .Closing:
		return "closing"
	case .Draining:
		return "draining"
	case .Closed:
		return "closed"
	}
	return ""
}

number_text :: proc "contextless" (builder: ^interface.Text_Builder, value: u64, unit: string) -> string {
	builder.count = 0
	interface.text_put_number(builder, value)
	interface.text_put(builder, unit)
	return interface.text_of(builder)
}

draw :: proc "contextless" (window: ^display.Window) {
	frame := interface.window_frame_start(&window_memory, window)
	interface.background(&frame, {0, 0, WIDTH, HEIGHT})
	builder: interface.Text_Builder
	if weak_seed {
		content := interface.card(&frame, {8, 8, WIDTH - 16, 100}, "NO KEY", "the random seed of this process is weaker than \"processor\"", graphics.colors.failed)
		column := interface.column_of(content)
		interface.label_value_line(&frame, interface.column_take(&column, LINE), "error", "Seed_Too_Weak: this server makes no key, and listens on nothing", graphics.colors.failed, 120)
		interface.window_frame_end(&window_memory.drawing, &frame, window)
		return
	}
	content := interface.card(&frame, {8, 8, WIDTH - 16, 100}, "THE SERVER", "QUIC in this process, over a listen grant of UDP", graphics.colors.process)
	column := interface.column_of(content)
	key: [64]u8
	interface.label_value_line(&frame, interface.column_take(&column, LINE), "public key", hex_text(key[:], public_key[:]), graphics.colors.text, 120)
	interface.label_value_line(&frame, interface.column_take(&column, LINE), "UDP port", number_text(&builder, u64(listen_port), ", Ed25519, a raw public key that a client pins"), graphics.colors.text, 120)

	content = interface.card(&frame, {8, 116, WIDTH - 16, CONNECTIONS_HEIGHT}, "THE CONNECTIONS", "up to 4 streams each: each byte goes back", graphics.colors.machine)
	column = interface.column_of(content)
	cells: [5]interface.Area
	sizes := [5]interface.Size{interface.characters(24), interface.characters(24), interface.share(), interface.share(), interface.characters(12)}
	interface.row_split(interface.column_take(&column, LINE), sizes[:], cells[:], 16)
	interface.table_header(&frame, cells[:], {"remote", "state", "in", "out", "srtt"}, {.Left, .Left, .Right, .Right, .Right})
	row := 0
	not_shown := 0 // The connections that the card has no line for.
	for record, place in records {
		if !record.in_use {
			continue
		}
		// The last line of the card is kept for the count of the
		// connections that the card does not show: no row is drawn past
		// the card, and none is left out in silence.
		if interface.column_rest(&column).height < 2 * LINE {
			not_shown += 1
			continue
		}
		connection := &connections[place]
		line := interface.column_take(&column, LINE)
		interface.table_band(&frame, {line.x - 8, line.y, line.width + 16, line.height}, row)
		row += 1
		interface.row_split(line, sizes[:], cells[:], 16)
		remote_text: [40]u8
		interface.cell_text(&frame, cells[0], address_text(remote_text[:], record.remote), graphics.colors.text)
		interface.cell_text(&frame, cells[1], state_text(connection), graphics.colors.dim)
		interface.cell_text(&frame, cells[2], number_text(&builder, connection.data_consumed_total, " bytes"), graphics.colors.text, .Right)
		interface.cell_text(&frame, cells[3], number_text(&builder, connection.data_sent_total, " bytes"), graphics.colors.text, .Right)
		interface.cell_text(&frame, cells[4], number_text(&builder, connection.smoothed_round_trip, " us"), graphics.colors.text, .Right)
	}
	if not_shown > 0 {
		interface.cell_text(&frame, interface.column_take(&column, LINE), number_text(&builder, u64(not_shown), " connections more: the card has no line for them"), graphics.colors.dim)
	}

	// Each count has its sentence, whole: a sentence wider than its box
	// has two lines, and the card has the height of seven rows with three
	// such sentences.
	content = interface.card(&frame, {8, COUNTED_Y, WIDTH - 16, HEIGHT - COUNTED_Y - 8}, "WHAT THE SERVER COUNTED", "since its start", graphics.colors.kernel)
	column = interface.column_of(content)
	counters := server.counters
	interface.label_value_lines(&frame, &column, "accepted", number_text(&builder, counters.accepted, " connections, each with an authentic Initial"), 200, graphics.colors.text, LINE)
	interface.label_value_lines(&frame, &column, "ended", number_text(&builder, counters.ended, " connections"), 200, graphics.colors.text, LINE)
	interface.label_value_lines(&frame, &column, "Retries", number_text(&builder, counters.retries, " Initials with no token: a Retry, no record kept"), 200, graphics.colors.text, LINE)
	interface.label_value_lines(&frame, &column, "refused tokens", number_text(&builder, counters.tokens_refused + counters.tokens_expired + counters.tokens_used_again + counters.not_authentic, " Initials: a token of another address, too old, used before, or a packet that does not open"), 200, graphics.colors.text, LINE)
	interface.label_value_lines(&frame, &column, "over the budget", number_text(&builder, counters.over_budget + counters.over_address_budget + counters.address_table_full, " datagrams of new identifiers, dropped before any cryptography"), 200, graphics.colors.text, LINE)
	interface.label_value_lines(&frame, &column, "refused by a limit", number_text(&builder, counters.refused_remote_limit + counters.refused_handshake_limit + counters.refused_full, " Initials (each try of a client counts): one address, the handshakes, a full table"), 200, graphics.colors.text, LINE)
	interface.label_value_lines(&frame, &column, "datagrams", number_text(&builder, counters.datagrams, " received"), 200, graphics.colors.text, LINE)
	interface.window_frame_end(&window_memory.drawing, &frame, window)
}
