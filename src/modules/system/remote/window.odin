package remote_service

import "modus:contract/call_outcome"
import "modus:contract/remote"
import "modus:display"
import "modus:graphics"
import "modus:interface"
import "modus:quic_server"
import "modus:system"

// An answer with an error record: the call ran, and the service gave its
// error as a value. Not the color "failed" (no call failed to run), and not
// the color of a result: the amber that the process log gives to the level
// Warning, the color of a failure that the caller can act on. A refusal by
// remote itself (no call ran) and by the service keep the color "failed".

// The window follows docs/DESIGN.md: rectangles only, the grid of 8 pixels,
// three cards with a title in the accent of their concept and a caption
// that names their record, names in the dim color, values in the text
// color, the state of a call in the color of a process that runs or in the
// color "failed", with a text that says the same.

WIDTH :: 720
HEIGHT :: 552

// The window is built with the interface package (docs/INTERFACE.md): the
// elements of the rules, the damage by difference, a present of the part
// that changed.

LINE :: graphics.LINE_HEIGHT

window_memory: interface.Window_Memory(512, 8192)

// hash_color gives the color of a module from its hash (docs/DESIGN.md:
// a thing with an identity takes its color from it).
hash_color :: proc "contextless" (hash: [32]u8) -> graphics.Color {
	return graphics.mix(graphics.rgb(u32(hash[0]) | 0x40, u32(hash[1]) | 0x40, u32(hash[2]) | 0x40), graphics.colors.text, 64)
}

draw :: proc "contextless" (window: ^display.Window) {
	frame := interface.window_frame_start(&window_memory, window)
	table := frame.table
	interface.background(&frame, {0, 0, WIDTH, HEIGHT})
	buffer: [64]u8
	if weak_seed {
		inside := interface.card(&frame, {8, 8, WIDTH - 16, 100}, "NO KEY", "the random seed of this process is weaker than \"processor\"", graphics.colors.failed)
		interface.draw_text(table, inside.x, inside.y, "Seed_Too_Weak: this service makes no key, and listens on nothing", graphics.colors.failed)
		interface.window_frame_end(&window_memory.drawing, &frame, window)
		return
	}

	// The calls of the host, with the large number of the card.
	inside := interface.card(&frame, {8, 8, WIDTH - 16, 192}, "CALLS FROM THE HOST", "one QUIC stream: remote.Request -> isolated call -> remote.Answer", graphics.colors.process)
	COLUMN :: 232
	VALUE :: 456
	// The label of the number is a caption under it. A digit of the large
	// size is 16 pixels: a count of 14 digits stops before the column of
	// the facts.
	interface.large_number(&frame, inside.x, inside.y, system.format(buffer[:], counts.calls), graphics.colors.process)
	interface.draw_caption(&frame, inside.x, inside.y + interface.line_height(interface.FONT_LARGE), COLUMN - graphics.GAP, "calls that ran")
	Fact :: struct {
		name:  string,
		value: u64,
		unit:  string,
	}
	facts := [?]Fact {
		{"whole requests", counts.requests, ""},
		{"refused by this process", counts.refused, ""},
		{"streams reset", counts.too_large + counts.timeouts, ""},
		{"given up by the host", counts.cancelled, ""},
		{"bytes in", counts.bytes_in, " B"},
		{"bytes out", counts.bytes_out, " B"},
	}
	for item, index in facts {
		color := (item.name == "refused by this process" || item.name == "streams reset") && item.value != 0 ? graphics.Color(graphics.colors.failed) : graphics.colors.text
		interface.label_value_line(&frame, {inside.x + COLUMN, inside.y + index * LINE, VALUE + 64 - COLUMN, LINE}, item.name, system.format(buffer[:], item.value, item.unit), color)
	}
	interface.draw_text(table, inside.x + VALUE + 96, inside.y, "listens on", graphics.colors.dim)
	interface.draw_text(table, inside.x + VALUE + 96, inside.y + LINE, system.format(buffer[:], "UDP ", u64(listen_port)), graphics.colors.text)
	interface.draw_text(table, inside.x + VALUE + 96, inside.y + 2 * LINE, "admits", graphics.colors.dim)
	interface.draw_text(table, inside.x + VALUE + 96, inside.y + 3 * LINE, "10.0.2.2 only", graphics.colors.text)
	// One bar: the width of each part is its count of requests.
	BAR_Y :: 96
	parts := [3]u64{counts.calls - counts.failed, counts.failed, counts.refused}
	colors := [3]graphics.Color{graphics.colors.process, graphics.colors.boot_program, graphics.colors.failed}
	interface.bar_parts(&frame, {inside.x, inside.y + BAR_Y, inside.width, 8}, parts[:], colors[:], max(counts.requests, 1))
	x := interface.draw_text(table, inside.x, inside.y + BAR_Y + 12, system.format(buffer[:], counts.calls - counts.failed, " gave a result"), graphics.colors.process)
	x = interface.draw_text(table, x + 24, inside.y + BAR_Y + 12, system.format(buffer[:], counts.failed, " gave an error record"), graphics.colors.boot_program)
	interface.draw_text(table, x + 24, inside.y + BAR_Y + 12, system.format(buffer[:], counts.refused, " refused"), graphics.colors.failed)
	// The key that the host pins: 64 hexadecimal digits.
	key: [64]u8
	at := interface.draw_text(table, inside.x, inside.y + BAR_Y + 12 + LINE + 8, "public key ", graphics.colors.dim)
	interface.draw_text(table, at, inside.y + BAR_Y + 12 + LINE + 8, quic_server.hex_text(key[:], public_key[:]), graphics.colors.text)

	// The connections that the root service made.
	inside = interface.card(&frame, {8, 208, WIDTH - 16, 144}, "CONNECTIONS", "root: Connect, a call ring and a call region of 64 KiB", graphics.colors.memory)
	shown := 0
	for &connection in service_connections {
		if connection.state != .Ready {
			continue
		}
		y := inside.y + shown * LINE
		interface.mark(&frame, inside.x, y + 2, 12, hash_color(connection.hash))
		interface.draw_text(table, inside.x + 24, y, remote.name_text(&connection.name), graphics.colors.text)
		hash: [16]u8
		digits := system.HEX_DIGITS
		for index in 0 ..< 8 {
			hash[2 * index] = digits[connection.hash[index] >> 4]
			hash[2 * index + 1] = digits[connection.hash[index] & 15]
		}
		interface.draw_text(table, inside.x + 160, y, string(hash[:]), hash_color(connection.hash))
		// The principal of the row of the client table that the connection
		// is for: "principal" and up to 5 digits end before the count.
		interface.draw_text(table, inside.x + 304, y, system.format(buffer[:], "principal ", connection.principal), graphics.colors.dim)
		interface.draw_text_right(table, inside.x + VALUE + 64, y, system.format(buffer[:], connection.count, " calls"), graphics.colors.text)
		shown += 1
	}
	if shown == 0 {
		interface.draw_text(table, inside.x, inside.y, "none: a connection starts at the next call of a client to a service", graphics.colors.dim)
	}

	// The last calls, the last one first.
	inside = interface.card(&frame, {8, 360, WIDTH - 16, 184}, "LAST CALLS", "remote.Answer: status, value, bytes, time in this process", graphics.colors.process)
	for row in 0 ..< min(recent_count, RECENT_CAPACITY) {
		item := &recent[(recent_count - 1 - row) % RECENT_CAPACITY]
		y := inside.y + int(row) * LINE
		interface.draw_text(table, inside.x, y, item.service[0] != 0 ? remote.name_text(&item.service) : "-", graphics.colors.text)
		state, color := "ok", graphics.Color(graphics.colors.process)
		switch {
		case item.status == .Refused:
			state, color = "refused by remote", graphics.colors.failed
		case item.outcome != .Succeeded:
			state, color = call_outcome.CALL_OUTCOME_NAMES[item.outcome], graphics.colors.failed
		}
		if item.status != .Refused {
			interface.draw_text(table, inside.x + 96, y, system.format(buffer[:], "export ", u64(item.export)), graphics.colors.dim)
		}
		interface.mark(&frame, inside.x + 200, y + 4, 8, color)
		interface.draw_text(table, inside.x + 216, y, state, color)
		if item.text_count != 0 {
			text_place := 216 + interface.text_width({}, state) + 16
			interface.draw_text(table, inside.x + text_place, y, string(item.text[:min(item.text_count, (inside.width - text_place) / graphics.CELL_WIDTH)]), graphics.colors.dim)
		} else {
			interface.draw_text_right(table, inside.x + 488, y, system.format(buffer[:], item.value), graphics.colors.text)
			interface.draw_text_right(table, inside.x + 576, y, system.format(buffer[:], item.bytes, " B"), graphics.colors.text)
			interface.draw_text_right(table, inside.x + inside.width, y, system.format(buffer[:], item.microseconds, " us"), graphics.colors.text)
		}
	}
	if recent_count == 0 {
		interface.draw_text(table, inside.x, inside.y, "none yet: modustool call <public key> \"monitor.processes()\" on the host", graphics.colors.dim)
	}
	interface.window_frame_end(&window_memory.drawing, &frame, window)
}
