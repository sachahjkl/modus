package modustool

import "core:slice"
import "modus:support/tcp"
import "modus:support/web"

// The fuzz targets of TCP and of the reader of an HTTP request
// (src/md/infrastructure/fuzzing.md, "The targets, in order of value"):
// they read the network. The library of TCP takes its clock from its
// caller, and its initial sequence numbers from a secret and that clock, so
// one input gives one run.

FUZZ_TCP_ADDRESS_A :: u32(0x0A00_0001) // The side that opens.
FUZZ_TCP_ADDRESS_B :: u32(0x0A00_0002) // The side that listens.
FUZZ_TCP_PORT_B :: 80
FUZZ_TCP_CONNECTIONS :: 4 // The records of each side.
FUZZ_TCP_BUFFER_SIZE :: 8 * 1024 // The send and the receive buffer of each record.
FUZZ_TCP_PLACES :: 16 // The segments of one step of one side.
FUZZ_TCP_PLACE_SIZE :: 1536 // At least tcp.SEGMENT_LIMIT.
FUZZ_TCP_START_TIME :: 1_000_000
FUZZ_TCP_STEP_LIMIT :: 60 // The steps of the choices of one execution.
FUZZ_TCP_PUMP_LIMIT :: 1000 // The rounds after the steps, with no change, until the bytes arrived.
FUZZ_TCP_PUMP_TIME_STEP :: 20_000 // The microseconds of one round: the timers of retransmission run.
FUZZ_TCP_TRANSFER_LIMIT :: 16 * 1024 // The bytes that A writes, at most.

// One side of the target: a table and its memory.
Fuzz_Tcp_Side :: struct {
	table:       tcp.Table,
	connections: [FUZZ_TCP_CONNECTIONS]tcp.Connection,
	buffers:     [FUZZ_TCP_CONNECTIONS * 2 * FUZZ_TCP_BUFFER_SIZE]u8,
	memory:      [FUZZ_TCP_PLACES * FUZZ_TCP_PLACE_SIZE]u8,
	places:      [FUZZ_TCP_PLACES]u32,
	segments:    [FUZZ_TCP_PLACES]tcp.Outgoing,
	events:      [FUZZ_TCP_CONNECTIONS]tcp.Event,
	address:     u32,
}

// The two sides, made once: about 200 KiB.
fuzz_tcp_sides: ^[2]Fuzz_Tcp_Side

fuzz_tcp_start :: proc() -> bool {
	fuzz_tcp_sides = new([2]Fuzz_Tcp_Side)
	return fuzz_tcp_sides != nil
}

// fuzz_tcp_side_init gives a side a new table.
fuzz_tcp_side_init :: proc(side: ^Fuzz_Tcp_Side, address: u32) -> bool {
	secret: [32]u8
	secret[0] = u8(address)
	side.address = address
	error := tcp.table_init(&side.table, side.connections[:], side.buffers[:], FUZZ_TCP_BUFFER_SIZE, FUZZ_TCP_BUFFER_SIZE, address, secret)
	side.table.port_first = 40000
	side.table.port_count = 16
	return error.kind == 0
}

// fuzz_tcp_step runs step on one side with the segments that arrived for
// it, and appends each segment that it sends to `sent`, in the temporary
// memory. It checks the bounds of each record.
fuzz_tcp_step :: proc(side: ^Fuzz_Tcp_Side, arrived: ^[dynamic][]u8, sent: ^[dynamic][]u8, from: u32, now: u64) -> Fuzz_Verdict {
	incoming := make([]tcp.Incoming, len(arrived^), context.temp_allocator)
	for segment, index in arrived^ {
		incoming[index] = {remote_address = from, segment = segment}
	}
	clear(arrived)
	for &place, number in side.places {
		place = u32(number)
	}
	output := tcp.Output{memory = side.memory[:], place_size = FUZZ_TCP_PLACE_SIZE, places = side.places[:], segments = side.segments[:]}
	_, _ = tcp.step(&side.table, incoming, now, &output, side.events[:])
	if output.count < 0 || output.count > FUZZ_TCP_PLACES {
		return fuzz_broken(.Contract, "step writes %d segments in %d places", output.count, FUZZ_TCP_PLACES)
	}
	for item in side.segments[:output.count] {
		if int(item.length) > FUZZ_TCP_PLACE_SIZE || int(item.place) >= FUZZ_TCP_PLACES {
			return fuzz_broken(.Contract, "step writes a segment out of its place: place %d, length %d", item.place, item.length)
		}
		bytes := side.memory[int(item.place) * FUZZ_TCP_PLACE_SIZE:][:item.length]
		if !tcp.checksum_valid(side.address, item.remote_address, bytes) {
			return fuzz_broken(.Contract, "step writes a segment with a wrong checksum")
		}
		append(sent, slice.clone(bytes, context.temp_allocator))
	}
	for &connection in side.connections {
		if connection.state > max(tcp.State) || connection.range_count > tcp.RANGE_CAPACITY || connection.receive_ready > FUZZ_TCP_BUFFER_SIZE || connection.send_length > FUZZ_TCP_BUFFER_SIZE {
			return fuzz_broken(.Contract, "a record breaks its bounds: state %d, ranges %d, ready %d, send %d", u8(connection.state), connection.range_count, connection.receive_ready, connection.send_length)
		}
	}
	return FUZZ_PASSED
}

// fuzz_tcp_checksum_set writes the checksum of a segment from source to
// destination.
fuzz_tcp_checksum_set :: proc(segment: []u8, source, destination: u32) {
	if len(segment) < tcp.HEADER {
		return
	}
	segment[16], segment[17] = 0, 0
	value := tcp.checksum(source, destination, segment)
	segment[16], segment[17] = u8(value >> 8), u8(value)
}

// fuzz_tcp_segment_execute: what header_read accepts, header_write writes
// again and header_read reads to the same fields; then a listening table
// takes the segment with its checksum made right, and answers.
fuzz_tcp_segment_execute :: proc(input: []u8) -> Fuzz_Verdict {
	header, read := tcp.header_read(input)
	if read {
		if len(header.data) > len(input) - tcp.HEADER {
			return fuzz_broken(.Contract, "header_read gives more data than the segment holds: %d of %d", len(header.data), len(input))
		}
		offset := header.mss != 0 ? tcp.HEADER_MSS : tcp.HEADER
		rewritten := make([]u8, offset + len(header.data), context.temp_allocator)
		copy(rewritten[offset:], header.data)
		tcp.header_write(rewritten, FUZZ_TCP_ADDRESS_A, FUZZ_TCP_ADDRESS_B, header, len(rewritten))
		again, read_again := tcp.header_read(rewritten)
		same := read_again && again.source_port == header.source_port && again.destination_port == header.destination_port && again.sequence == header.sequence && again.acknowledgment == header.acknowledgment && again.flags == header.flags && again.window == header.window && again.mss == header.mss && slice.equal(again.data, header.data)
		if !same {
			return fuzz_broken(.Round_Trip, "the header that header_write writes again reads to other fields")
		}
		if !tcp.checksum_valid(FUZZ_TCP_ADDRESS_A, FUZZ_TCP_ADDRESS_B, rewritten) {
			return fuzz_broken(.Round_Trip, "header_write writes a wrong checksum")
		}
	}
	side := &fuzz_tcp_sides[1]
	if !fuzz_tcp_side_init(side, FUZZ_TCP_ADDRESS_B) {
		return fuzz_broken(.Contract, "the table of the target does not start")
	}
	side.table.listen_port = FUZZ_TCP_PORT_B
	segment := slice.clone(input, context.temp_allocator)
	fuzz_tcp_checksum_set(segment, FUZZ_TCP_ADDRESS_A, FUZZ_TCP_ADDRESS_B)
	arrived := make([dynamic][]u8, context.temp_allocator)
	sent := make([dynamic][]u8, context.temp_allocator)
	append(&arrived, segment)
	if verdict := fuzz_tcp_step(side, &arrived, &sent, FUZZ_TCP_ADDRESS_A, FUZZ_TCP_START_TIME); verdict.oracle != .None {
		return verdict
	}
	return fuzz_tcp_step(side, &arrived, &sent, FUZZ_TCP_ADDRESS_A, FUZZ_TCP_START_TIME + 500_000)
}

// fuzz_tcp_listening_record gives the record of B that the open of A
// made, or -1.
fuzz_tcp_listening_record :: proc(side: ^Fuzz_Tcp_Side) -> int {
	for &connection, index in side.connections {
		if connection.state != .Closed {
			return index
		}
	}
	return -1
}

// fuzz_tcp_read_listening reads what the record of the listening side
// holds, and appends it.
fuzz_tcp_read_listening :: proc(listening: ^Fuzz_Tcp_Side, buffer: []u8, into: ^[dynamic]u8) {
	record := fuzz_tcp_listening_record(listening)
	if record < 0 {
		return
	}
	count, read_error := tcp.read(&listening.table, record, buffer)
	if read_error.kind == 0 && count > 0 {
		append(into, ..buffer[:count])
	}
}

// fuzz_tcp_connection_execute runs two tables in memory. A opens a
// connection to B and writes bytes; steps of the choices run a side, drop
// a segment, inject a segment to B near its window, write, read, or let the
// clock pass. The bytes that B reads are always a prefix of what A wrote.
// With no injected segment, the bytes arrive whole after the steps.
fuzz_tcp_connection_execute :: proc(input: []u8) -> Fuzz_Verdict {
	sides := fuzz_tcp_sides
	a, b := &sides[0], &sides[1]
	if !fuzz_tcp_side_init(a, FUZZ_TCP_ADDRESS_A) || !fuzz_tcp_side_init(b, FUZZ_TCP_ADDRESS_B) {
		return fuzz_broken(.Contract, "a table of the target does not start")
	}
	b.table.listen_port = FUZZ_TCP_PORT_B
	now := u64(FUZZ_TCP_START_TIME)
	index, error := tcp.connect(&a.table, FUZZ_TCP_ADDRESS_B, FUZZ_TCP_PORT_B, now)
	if error.kind != 0 {
		return fuzz_broken(.Contract, "the open of A is refused: %d", error.kind)
	}
	to_a := make([dynamic][]u8, context.temp_allocator)
	to_b := make([dynamic][]u8, context.temp_allocator)
	written := make([dynamic]u8, context.temp_allocator)
	received := make([dynamic]u8, context.temp_allocator)
	read_buffer: [FUZZ_TCP_BUFFER_SIZE]u8
	injected := false
	choices := fuzz_choices_of(input)
	for _ in 0 ..< fuzz_choice_below(&choices, FUZZ_TCP_STEP_LIMIT) {
		if fuzz_choices_ran_out(&choices) {
			break
		}
		switch fuzz_choice_below(&choices, 7) {
		case 0:
			if verdict := fuzz_tcp_step(a, &to_a, &to_b, FUZZ_TCP_ADDRESS_B, now); verdict.oracle != .None {
				return verdict
			}
		case 1:
			if verdict := fuzz_tcp_step(b, &to_b, &to_a, FUZZ_TCP_ADDRESS_A, now); verdict.oracle != .None {
				return verdict
			}
		case 2:
			// A segment lost: TCP sends it again.
			queue := fuzz_choice_flag(&choices) ? &to_a : &to_b
			if len(queue^) > 0 {
				ordered_remove(queue, fuzz_choice_below(&choices, len(queue^)))
			}
		case 3:
			record := fuzz_tcp_listening_record(b)
			if record < 0 {
				continue
			}
			connection := &b.connections[record]
			header := tcp.Header {
				source_port      = a.connections[index].local_port,
				destination_port = FUZZ_TCP_PORT_B,
				sequence         = connection.receive_next + u32(fuzz_choice_below(&choices, 64)) - 32,
				acknowledgment   = connection.send_next + u32(fuzz_choice_below(&choices, 64)) - 32,
				flags            = transmute(tcp.Flags)fuzz_choice_byte(&choices),
				window           = u16(fuzz_choice_word(&choices, 2)),
				mss              = fuzz_choice_rare(&choices, 4) ? u16(fuzz_choice_word(&choices, 2)) : 0,
			}
			data_length := fuzz_choice_below(&choices, 64)
			offset := header.mss != 0 ? tcp.HEADER_MSS : tcp.HEADER
			segment := make([]u8, offset + data_length, context.temp_allocator)
			fuzz_choice_fill(&choices, segment[offset:])
			tcp.header_write(segment, FUZZ_TCP_ADDRESS_A, FUZZ_TCP_ADDRESS_B, header, len(segment))
			append(&to_b, segment)
			injected = true
		case 4:
			if len(written) < FUZZ_TCP_TRANSFER_LIMIT {
				bytes: [512]u8
				count := fuzz_choice_range(&choices, 1, len(bytes))
				for &item, place in bytes[:count] {
					item = u8((len(written) + place) * 7 % 251)
				}
				accepted, write_error := tcp.write(&a.table, index, bytes[:count])
				if write_error.kind == 0 {
					append(&written, ..bytes[:accepted])
				}
			}
		case 5:
			fuzz_tcp_read_listening(b, read_buffer[:], &received)
		case 6:
			now += u64(1 + fuzz_choice_below(&choices, 200_000))
		}
		if len(received) > len(written) || !slice.equal(received[:], written[:len(received)]) {
			return fuzz_broken(.Two_Readers, "B read bytes that A did not write in that order: %d read, %d written", len(received), len(written))
		}
	}
	// No change from here: the two sides run until B read each byte.
	for _ in 0 ..< FUZZ_TCP_PUMP_LIMIT {
		if len(received) == len(written) && len(to_a) == 0 && len(to_b) == 0 {
			break
		}
		if verdict := fuzz_tcp_step(a, &to_a, &to_b, FUZZ_TCP_ADDRESS_B, now); verdict.oracle != .None {
			return verdict
		}
		if verdict := fuzz_tcp_step(b, &to_b, &to_a, FUZZ_TCP_ADDRESS_A, now); verdict.oracle != .None {
			return verdict
		}
		fuzz_tcp_read_listening(b, read_buffer[:], &received)
		now += FUZZ_TCP_PUMP_TIME_STEP
	}
	if len(received) > len(written) || !slice.equal(received[:], written[:len(received)]) {
		return fuzz_broken(.Two_Readers, "B read bytes that A did not write in that order: %d read, %d written", len(received), len(written))
	}
	established := a.connections[index].state == .Established
	if !injected && established && len(received) != len(written) {
		return fuzz_broken(.Two_Readers, "with no injected segment, B did not read each byte that A wrote: %d of %d", len(received), len(written))
	}
	return FUZZ_PASSED
}

// ---------------------------------------------------------------------
// The head of an HTTP request.

// fuzz_http_request_execute: the fields of a head that request_read gives
// stay in their limits, and a head that is whole and valid reads the same
// from its own bytes, and not whole from one byte less.
fuzz_http_request_execute :: proc(input: []u8) -> Fuzz_Verdict {
	request, complete := web.request_read(input)
	if request.problem > max(web.Request_Problem) || request.method > max(web.Request_Method) {
		return fuzz_broken(.Contract, "request_read gives a value out of its enumeration: problem %d, method %d", int(request.problem), int(request.method))
	}
	_ = web.request_problem_status(request.problem)
	_ = web.request_problem_text(request.problem)
	_ = web.request_method_name(request.method)
	if !complete || request.problem != .None {
		return FUZZ_PASSED
	}
	if request.head_size <= 0 || request.head_size > len(input) || request.head_size > web.REQUEST_HEAD_LIMIT {
		return fuzz_broken(.Contract, "the head size is out of the input or its limit: %d of %d", request.head_size, len(input))
	}
	if request.target_length < 0 || request.target_length > web.REQUEST_TARGET_LIMIT || request.field_count < 0 || request.field_count > web.REQUEST_FIELD_LIMIT {
		return fuzz_broken(.Contract, "a field of the head is out of its limit: target %d, fields %d", request.target_length, request.field_count)
	}
	_ = web.request_target(&request)
	again, again_complete := web.request_read(input[:request.head_size])
	if !again_complete || again != request {
		return fuzz_broken(.Two_Readers, "the head reads otherwise from its own bytes")
	}
	shorter, shorter_complete := web.request_read(input[:request.head_size - 1])
	if shorter_complete && shorter.problem == .None {
		return fuzz_broken(.Two_Readers, "the head less its last byte reads as whole and valid")
	}
	return FUZZ_PASSED
}

fuzz_http_request_seeds :: proc(seeds: ^[dynamic][]u8) {
	heads := [?]string {
		"GET / HTTP/1.1\r\nHost: modus\r\n\r\n",
		"POST /sink HTTP/1.1\r\nHost: modus\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello",
		"GET http://modus/page?x=1 HTTP/1.0\r\n\r\n",
		"HEAD /large HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n",
	}
	for head in heads {
		append(seeds, slice.clone(transmute([]u8)head))
	}
}
