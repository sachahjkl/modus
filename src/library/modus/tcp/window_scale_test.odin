#+build !freestanding
package tcp

import "core:testing"

// The window scale option goes through header_write and header_read, after
// the MSS option, in a header of HEADER_SYN bytes. A shift past the limit
// reads as the limit, and an option of kind 3 with another length is not
// a window scale.
@(test)
window_scale_option_round_trip_and_edges :: proc(t: ^testing.T) {
	segment: [HEADER_SYN]u8
	header := Header{source_port = 1, destination_port = 2, sequence = 3, flags = {.Syn}, window = 65535, mss = 1460, window_scale = 7, has_window_scale = true}
	testing.expect_value(t, header_size(header), HEADER_SYN)
	header_write(segment[:], ADDRESS_A, ADDRESS_B, header, HEADER_SYN)
	testing.expect(t, checksum_valid(ADDRESS_A, ADDRESS_B, segment[:]))
	read, ok := header_read(segment[:])
	testing.expect(t, ok && read.mss == 1460 && read.has_window_scale && read.window_scale == 7 && read.window == 65535)
	// A shift of 15 and of 255 read as 14.
	for shift in ([?]u8{15, 255}) {
		segment[HEADER + 7] = shift
		read, ok = header_read(segment[:])
		testing.expectf(t, ok && read.has_window_scale && read.window_scale == WINDOW_SCALE_LIMIT, "a shift of %d read as %d", shift, read.window_scale)
	}
	// A kind 3 of length 2 or 4 is not a window scale.
	options := [?][4]u8{{3, 2, 1, 1}, {3, 4, 9, 9}}
	for &option in options {
		bytes: [HEADER + 4]u8
		copy(bytes[:], segment[:HEADER])
		bytes[12] = u8(HEADER + 4) / 4 << 4
		copy(bytes[HEADER:], option[:])
		other, other_ok := header_read(bytes[:])
		testing.expectf(t, other_ok && !other.has_window_scale, "the option %v read as a window scale", option)
	}
	// A header with the window scale alone, no MSS.
	alone := Header{flags = {.Syn}, window_scale = 0, has_window_scale = true}
	testing.expect_value(t, header_size(alone), HEADER + 4)
}

// The shift of a buffer: the least shift whose window holds the buffer,
// at the edges of each power of two, and at most the limit.
@(test)
window_scale_of_a_buffer_at_its_edges :: proc(t: ^testing.T) {
	cases := [?]struct {
		size:  u32,
		shift: u8,
	}{{0, 0}, {1, 0}, {65535, 0}, {65536, 1}, {131070, 1}, {131071, 2}, {1 << 20, 5}, {1 << 29, 14}, {1 << 30, 14}, {max(u32), 14}}
	for item in cases {
		testing.expectf(t, window_scale_of_buffer(item.size) == item.shift, "a buffer of %d bytes gave the shift %d", item.size, window_scale_of_buffer(item.size))
	}
}

// One table that listens, with a buffer of 1 MiB to receive.
@(private = "file")
Listener :: struct {
	table:       Table,
	connections: [2]Connection,
	buffers:     []u8,
	memory:      [4 * PLACE_SIZE]u8,
	places:      [4]u32,
	segments:    [4]Outgoing,
	events:      [2]Event,
}

@(private = "file")
listener_make :: proc(receive_size: u32) -> ^Listener {
	listener := new(Listener)
	listener.buffers = make([]u8, 2 * int(64 * 1024 + receive_size))
	error := table_init(&listener.table, listener.connections[:], listener.buffers, 64 * 1024, receive_size, ADDRESS_B, {})
	assert(error.kind == 0)
	listener.table.listen_port = PORT_B
	return listener
}

@(private = "file")
listener_free :: proc(listener: ^Listener) {
	delete(listener.buffers)
	free(listener)
}

// listener_take gives one segment from A to the listener, and gives the
// first segment that it answers, read back.
@(private = "file")
listener_take :: proc(listener: ^Listener, header: Header, now: u64) -> (answer: Header, answered: bool) {
	bytes: [HEADER_SYN]u8
	length := header_size(header)
	header_write(bytes[:], ADDRESS_A, ADDRESS_B, header, length)
	for &place, index in listener.places {
		place = u32(index)
	}
	output := Output{memory = listener.memory[:], place_size = PLACE_SIZE, places = listener.places[:], segments = listener.segments[:]}
	step(&listener.table, {{remote_address = ADDRESS_A, segment = bytes[:length]}}, now, &output, listener.events[:])
	if output.count == 0 {
		return {}, false
	}
	item := output.segments[0]
	return header_read(listener.memory[int(item.place) * PLACE_SIZE:][:item.length])
}

// A SYN with no window scale gets a SYN, ACK with none, and no window is
// scaled: an ACK that gives 1000 gives a window of 1000. A SYN with the
// shift 3 gets a SYN, ACK with the shift of the buffer of the listener,
// and an ACK that gives 1000 gives a window of 8000. The window of each
// SYN, ACK is not scaled and fits the field.
@(test)
window_scale_is_agreed_only_when_both_syns_carry_it :: proc(t: ^testing.T) {
	RECEIVE :: 1 << 20
	for offered in ([?]bool{false, true}) {
		listener := listener_make(RECEIVE)
		defer listener_free(listener)
		syn := Header{source_port = 4000, destination_port = PORT_B, sequence = 1000, flags = {.Syn}, window = 65535, mss = 1460, window_scale = 3, has_window_scale = offered}
		answer, answered := listener_take(listener, syn, 1)
		testing.expect(t, answered && answer.flags == {.Syn, .Ack} && answer.acknowledgment == 1001)
		testing.expectf(t, answer.has_window_scale == offered, "a SYN with the option %v got a SYN, ACK with the option %v", offered, answer.has_window_scale)
		connection := &listener.connections[0]
		testing.expect_value(t, connection.window_scale_agreed, offered)
		if offered {
			testing.expect_value(t, answer.window_scale, window_scale_of_buffer(RECEIVE))
			testing.expect_value(t, connection.send_scale, 3)
			testing.expect_value(t, connection.receive_scale, window_scale_of_buffer(RECEIVE))
		} else {
			testing.expect_value(t, connection.send_scale, 0)
			testing.expect_value(t, connection.receive_scale, 0)
		}
		testing.expect(t, connection.send_window == 65535, "the window of a SYN is scaled")
		ack := Header{source_port = 4000, destination_port = PORT_B, sequence = 1001, acknowledgment = answer.sequence + 1, flags = {.Ack}, window = 1000}
		listener_take(listener, ack, 2)
		testing.expect_value(t, connection.state, State.Established)
		testing.expect_value(t, connection.send_window, offered ? u32(8000) : u32(1000))
		// The window that this side gives after the handshake: the room of
		// its buffer, past 65535 only when the scale is agreed.
		window := window_offer(&listener.table, connection)
		if offered {
			testing.expect(t, window > WINDOW_LIMIT && window % (1 << connection.receive_scale) == 0, "a scaled window is not past 65535")
		} else {
			testing.expect(t, window <= WINDOW_LIMIT)
		}
	}
}

// Two sides with buffers of 1 MiB move 3 MB through windows past 65535:
// each side offers the scale of its buffer in its SYN, and the window that
// each side reads is the window that the other gives.
@(test)
a_transfer_through_scaled_windows :: proc(t: ^testing.T) {
	link := link_make(5, 1 << 20, 1 << 20)
	defer link_free(link)
	if !transfer_run(t, link, 3_000_000) {
		return
	}
	a := &link.sides[0].connections[0]
	b := &link.sides[1].connections[0]
	testing.expect(t, a.window_scale_agreed && b.window_scale_agreed)
	testing.expect_value(t, a.send_scale, window_scale_of_buffer(1 << 20))
	testing.expect_value(t, b.send_scale, window_scale_of_buffer(1 << 20))
	testing.expect(t, a.send_window_most > WINDOW_LIMIT, "the window of the receiver never passed 65535")
	testing.expect_value(t, b.bytes_received, 3_000_000)
}
