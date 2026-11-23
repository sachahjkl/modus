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

// listener_ack makes the listener send an ACK on its first connection, and
// gives it read back.
@(private = "file")
listener_ack :: proc(listener: ^Listener) -> Header {
	for &place, index in listener.places {
		place = u32(index)
	}
	output := Output{memory = listener.memory[:], place_size = PLACE_SIZE, places = listener.places[:], segments = listener.segments[:]}
	connection := &listener.connections[0]
	sent := segment_send(&listener.table, &output, 0, {.Ack}, connection.send_next, 0, 0)
	assert(sent && output.count == 1)
	item := output.segments[0]
	header, ok := header_read(listener.memory[int(item.place) * PLACE_SIZE:][:item.length])
	assert(ok)
	return header
}

// listener_established takes a SYN with the shift 3 and the ACK of its
// SYN, ACK: a connection whose scales are agreed.
@(private = "file")
listener_established :: proc(t: ^testing.T, listener: ^Listener) -> ^Connection {
	syn := Header{source_port = 4000, destination_port = PORT_B, sequence = 1000, flags = {.Syn}, window = 65535, mss = 1460, window_scale = 3, has_window_scale = true}
	answer, _ := listener_take(listener, syn, 1)
	listener_take(listener, Header{source_port = 4000, destination_port = PORT_B, sequence = 1001, acknowledgment = answer.sequence + 1, flags = {.Ack}, window = 1000}, 2)
	connection := &listener.connections[0]
	testing.expect_value(t, connection.state, State.Established)
	return connection
}

// A window scale option on a segment that is not a SYN changes no scale
// and no window: RFC 7323 takes the option of the SYN only.
@(test)
a_window_scale_option_past_the_syn_changes_nothing :: proc(t: ^testing.T) {
	listener := listener_make(1 << 20)
	defer listener_free(listener)
	connection := listener_established(t, listener)
	send_scale, receive_scale := connection.send_scale, connection.receive_scale
	for shift in ([?]u8{0, 7, WINDOW_SCALE_LIMIT}) {
		ack := Header{source_port = 4000, destination_port = PORT_B, sequence = 1001, acknowledgment = connection.send_next, flags = {.Ack}, window = 1000, window_scale = shift, has_window_scale = true}
		listener_take(listener, ack, 3)
		testing.expect_value(t, connection.send_scale, send_scale)
		testing.expect_value(t, connection.receive_scale, receive_scale)
		testing.expect(t, connection.window_scale_agreed)
		testing.expect_value(t, connection.send_window, u32(1000) << send_scale)
	}
}

// An active open offers the option; a SYN, ACK with none means that the
// remote does not scale: both scales are 0, and the windows of both ways
// are the fields.
@(test)
an_active_open_answered_with_no_option_scales_nothing :: proc(t: ^testing.T) {
	listener := listener_make(1 << 20)
	defer listener_free(listener)
	listener.table.port_first = 49152
	listener.table.port_count = 16
	index, error := connect(&listener.table, ADDRESS_A, 4000, 1)
	testing.expect(t, error.kind == 0 && index == 0)
	connection := &listener.connections[0]
	// The step sends the SYN, with the option.
	syn, sent := listener_take(listener, Header{source_port = 1, destination_port = 1, flags = {.Rst}}, 1)
	testing.expect(t, sent && .Syn in syn.flags && syn.has_window_scale, "the SYN of an active open does not offer the window scale")
	syn_ack := Header{source_port = 4000, destination_port = connection.local_port, sequence = 7000, acknowledgment = connection.initial_send + 1, flags = {.Syn, .Ack}, window = 60000, mss = 1460}
	listener_take(listener, syn_ack, 2)
	testing.expect_value(t, connection.state, State.Established)
	testing.expect(t, !connection.window_scale_agreed)
	testing.expect_value(t, connection.send_scale, 0)
	testing.expect_value(t, connection.receive_scale, 0)
	testing.expect_value(t, connection.send_window, 60000)
	testing.expect(t, listener_ack(listener).window <= WINDOW_LIMIT)
}

// The largest shift of the largest field gives 65535 << 14, which a u32
// holds: no wrap to a small window.
@(test)
the_largest_scaled_window_does_not_wrap :: proc(t: ^testing.T) {
	connection := Connection{send_scale = WINDOW_SCALE_LIMIT}
	testing.expect_value(t, window_of(&connection, Header{flags = {.Ack}, window = 65535}), u32(65535) << 14)
	testing.expect_value(t, window_of(&connection, Header{flags = {.Ack}, window = 65535}), u32(1_073_725_440))
	// The window of a SYN is never scaled.
	testing.expect_value(t, window_of(&connection, Header{flags = {.Syn, .Ack}, window = 65535}), 65535)
}

// The right edge that the remote reads, acknowledgment + field << scale,
// never moves back while bytes arrive one at a time and none is read.
@(test)
the_advertised_right_edge_never_moves_back :: proc(t: ^testing.T) {
	listener := listener_make(1 << 20)
	defer listener_free(listener)
	connection := listener_established(t, listener)
	testing.expect(t, connection.receive_scale > 0)
	first := listener_ack(listener)
	most := first.acknowledgment + u32(first.window) << connection.receive_scale
	for count in 1 ..= 40 {
		// count bytes arrive and stay in the buffer.
		connection.receive_next += u32(count)
		connection.receive_ready += u32(count)
		ack := listener_ack(listener)
		edge := ack.acknowledgment + u32(ack.window) << connection.receive_scale
		testing.expectf(t, !before(edge, most), "after %d bytes the edge moved back by %d", count, most - edge)
		testing.expectf(t, !before(edge, connection.receive_edge), "the edge that the remote reads is before receive_edge")
		testing.expectf(t, edge == connection.receive_edge, "the edge that the remote reads is not receive_edge")
		most = edge
	}
}

// When the edge rounded up to a unit passes the free room of the buffer, a
// segment up to the edge gives only the bytes that the room holds: no byte
// that waits to be read is written over.
@(test)
bytes_past_the_free_room_are_not_taken :: proc(t: ^testing.T) {
	listener := listener_make(1 << 20)
	defer listener_free(listener)
	connection := listener_established(t, listener)
	// The buffer holds all but 10 bytes, and the edge is 20 bytes away.
	connection.receive_ready = listener.table.receive_size - 10
	connection.receive_edge = connection.receive_next + 20
	before_bytes := connection.bytes_received
	data: [20]u8
	header := Header{source_port = 4000, destination_port = PORT_B, sequence = connection.receive_next, acknowledgment = connection.send_next, flags = {.Ack}, window = 1000}
	bytes: [HEADER + 20]u8
	copy(bytes[HEADER:], data[:])
	header_write(bytes[:], ADDRESS_A, ADDRESS_B, header, len(bytes))
	for &place, index in listener.places {
		place = u32(index)
	}
	output := Output{memory = listener.memory[:], place_size = PLACE_SIZE, places = listener.places[:], segments = listener.segments[:]}
	step(&listener.table, {{remote_address = ADDRESS_A, segment = bytes[:]}}, 3, &output, listener.events[:])
	testing.expect_value(t, connection.bytes_received - before_bytes, 10)
	testing.expect_value(t, connection.receive_ready, listener.table.receive_size)
}
