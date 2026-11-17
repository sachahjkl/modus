package modustool

import "core:slice"
import "modus:contract/errors"
import "modus:support/quic"
import "modus:support/random"

// The fuzz targets of QUIC and TLS 1.3 (src/md/infrastructure/fuzzing.md,
// "The targets, in order of value"): they read the network before any key
// is known. The library takes its clock (`now`) and its generator from its
// caller, so each execution gives a fixed clock and generators seeded the
// same way: one input gives one run.

FUZZ_QUIC_STREAMS :: 4 // The stream records of each side.
FUZZ_QUIC_START_TIME :: 1_000_000 // The clock of the start, in microseconds.
FUZZ_QUIC_STEP_LIMIT :: 40 // The steps of the choices of one execution.
FUZZ_QUIC_PUMP_LIMIT :: 64 // The rounds after the steps, with no change, until both sides are connected.
FUZZ_QUIC_TIME_STEP_LIMIT :: 50_000 // The most microseconds of one step of the clock: far under the idle timeout.
FUZZ_QUIC_PROTOCOL :: "kernel-remote"

// The private key of the server of the targets: a key of the test, which
// protects nothing.
@(rodata)
fuzz_quic_server_private_key := [quic.ED25519_KEY_SIZE]u8 {
	0x9d, 0x61, 0xb1, 0x9d, 0xef, 0xfd, 0x5a, 0x60, 0xba, 0x84, 0x4a, 0xf4, 0x92, 0xec, 0x2c, 0xc4,
	0x44, 0x49, 0xc5, 0x69, 0x7b, 0x32, 0x69, 0x19, 0x70, 0x3b, 0xac, 0x03, 0x1c, 0xae, 0x7f, 0x60,
}

// The state of the targets of QUIC, made once in a process.
Fuzz_Quic :: struct {
	cryptography:         quic.Cryptography,
	server_configuration: quic.Connection_Configuration,
	client_configuration: quic.Connection_Configuration,
	server_generator:     random.Generator,
	client_generator:     random.Generator,
	server:               quic.Connection,
	client:               quic.Connection,
	server_streams:       [FUZZ_QUIC_STREAMS]quic.Stream,
	client_streams:       [FUZZ_QUIC_STREAMS]quic.Stream,
	server_tls:           quic.Tls_Handshake,
	client_tls:           quic.Tls_Handshake,
	buffer:               [quic.DATAGRAM_LIMIT]u8,
	resealed:             [quic.DATAGRAM_LIMIT]u8,
}

fuzz_quic: ^Fuzz_Quic

fuzz_quic_start :: proc() -> bool {
	state := new(Fuzz_Quic)
	fuzz_quic = state
	state.cryptography = quic_cryptography_of_the_host()
	server := &state.server_configuration
	server^ = {idle_timeout_milliseconds = 30_000}
	server.tls = {role = .Server, least_seed_strength = .Processor}
	server.tls.application_protocol_length = copy(server.tls.application_protocol[:], FUZZ_QUIC_PROTOCOL)
	server.tls.server_private_key = fuzz_quic_server_private_key
	client := &state.client_configuration
	client^ = {idle_timeout_milliseconds = 30_000}
	client.tls = {role = .Client, least_seed_strength = .Processor}
	client.tls.application_protocol_length = copy(client.tls.application_protocol[:], FUZZ_QUIC_PROTOCOL)
	error: errors.Error_Record
	secret := string(server.tls.server_private_key[:])
	public := client.tls.server_public_key[:]
	return state.cryptography.ed25519_public_key(&secret, &public, &error) >= 0
}

// fuzz_quic_generators_seed seeds the two generators the same way at the
// start of each execution.
fuzz_quic_generators_seed :: proc() {
	client_seed, server_seed: [random.SEED_SIZE]u8
	for index in 0 ..< random.SEED_SIZE {
		client_seed[index] = u8(7 + index)
		server_seed[index] = u8(77 + index)
	}
	random.generator_seed(&fuzz_quic.client_generator, &client_seed, .Processor)
	random.generator_seed(&fuzz_quic.server_generator, &server_seed, .Processor)
}

// fuzz_quic_connections_start starts a server and a client.
fuzz_quic_connections_start :: proc() -> bool {
	state := fuzz_quic
	fuzz_quic_generators_seed()
	error: errors.Error_Record
	return quic.connection_start_server(&state.server, state.server_streams[:], &state.server_configuration, &state.cryptography, &state.server_generator, FUZZ_QUIC_START_TIME, &error) &&
		quic.connection_start_client(&state.client, state.client_streams[:], &state.client_configuration, &state.cryptography, &state.client_generator, FUZZ_QUIC_START_TIME, &error)
}

// fuzz_quic_headers_read reads each packet header of a datagram, and checks
// that each one stays inside the datagram and moves forward.
fuzz_quic_headers_read :: proc(datagram: []u8) -> Fuzz_Verdict {
	start := 0
	for start < len(datagram) {
		header: quic.Packet_Header
		error: errors.Error_Record
		if !quic.header_read(datagram, start, quic.CONNECTION_ID_SIZE, &header, &error) {
			break
		}
		if header.end <= start || header.end > len(datagram) || header.packet_number_offset > header.end || header.token_offset + header.token_length > header.end {
			return fuzz_broken(.Contract, "header_read gives a header past its datagram: start %d, end %d, length %d", start, header.end, len(datagram))
		}
		start = header.end
	}
	return FUZZ_PASSED
}

// fuzz_quic_datagram_execute gives one datagram to a server that waits for
// its client, then lets it answer.
fuzz_quic_datagram_execute :: proc(input: []u8) -> Fuzz_Verdict {
	state := fuzz_quic
	if verdict := fuzz_quic_headers_read(input); verdict.oracle != .None {
		return verdict
	}
	private_memory: [quic.DATAGRAM_LIMIT]u8
	error: errors.Error_Record
	copy_of_the_datagram, taken := quic.datagram_take(input, private_memory[:], &error)
	if taken != (len(input) <= quic.DATAGRAM_LIMIT) || (taken && !slice.equal(copy_of_the_datagram, input)) {
		return fuzz_broken(.Contract, "datagram_take takes a datagram of %d bytes: %v", len(input), taken)
	}
	if !fuzz_quic_connections_start() {
		return fuzz_broken(.Contract, "a connection of the target does not start")
	}
	_ = quic.connection_datagram_receive(&state.server, input, FUZZ_QUIC_START_TIME, &error)
	if state.server.state > max(quic.Connection_State) {
		return fuzz_broken(.Contract, "the state of the server is out of its enumeration: %d", u8(state.server.state))
	}
	length := quic.connection_datagram_send(&state.server, state.buffer[:], FUZZ_QUIC_START_TIME + 1000)
	if length < 0 || length > quic.MAX_DATAGRAM_SIZE {
		return fuzz_broken(.Contract, "the server sends a datagram of %d bytes", length)
	}
	return FUZZ_PASSED
}

// fuzz_quic_datagram_seeds gives the first datagram of a client: an
// Initial packet that opens, with its ClientHello.
fuzz_quic_datagram_seeds :: proc(seeds: ^[dynamic][]u8) {
	if fuzz_quic == nil && !fuzz_quic_start() {
		return
	}
	if !fuzz_quic_connections_start() {
		return
	}
	length := quic.connection_datagram_send(&fuzz_quic.client, fuzz_quic.buffer[:], FUZZ_QUIC_START_TIME)
	if length > 0 {
		append(seeds, slice.clone(fuzz_quic.buffer[:length]))
	}
}

// fuzz_quic_reseal opens a 1-RTT packet of the sender with its own keys,
// puts the frames of the choices in place of its frames, and seals it
// again with the same keys and the same packet number. The receiver then
// reads frames that the sender never wrote, behind an authentic packet.
fuzz_quic_reseal :: proc(sender: ^quic.Connection, datagram: []u8, choices: ^Fuzz_Choices) -> (resealed: []u8, ok: bool) {
	state := fuzz_quic
	space := &sender.spaces[.Application]
	if len(datagram) == 0 || datagram[0] & quic.LONG_HEADER_FORM != 0 || !space.keys_installed {
		return nil, false
	}
	opened_copy := slice.clone(datagram, context.temp_allocator)
	header: quic.Packet_Header
	opened: quic.Opened_Packet
	error: errors.Error_Record
	largest := space.next_packet_number > 0 ? space.next_packet_number - 1 : 0
	if !quic.header_read(opened_copy, 0, quic.CONNECTION_ID_SIZE, &header, &error) || !quic.packet_open(&state.cryptography, &space.send_keys, opened_copy, &header, largest, &opened, &error) {
		return nil, false
	}
	frames := opened_copy[opened.payload_offset:][:opened.payload_length]
	// The new frames: the old ones with one frame of the choices inserted at
	// a place, or the frames of the choices alone.
	payload := make([dynamic]u8, context.temp_allocator)
	added := fuzz_quic_frames(choices)
	if fuzz_choice_flag(choices) {
		place := fuzz_choice_below(choices, len(frames) + 1)
		append(&payload, ..frames[:place])
		append(&payload, ..added)
		append(&payload, ..frames[place:])
	} else {
		append(&payload, ..added)
	}
	number_length := int(opened.first_byte & 0x03) + 1
	// The sample of header protection needs 4 bytes of number and frames:
	// PADDING frames (0) fill the rest.
	for number_length + len(payload) < 4 {
		append(&payload, 0)
	}
	number_offset := 1 + int(header.destination_connection_id.length)
	end := number_offset + number_length + len(payload) + quic.TAG_SIZE
	if end > len(state.resealed) {
		return nil, false
	}
	state.resealed[0] = opened.first_byte
	copy(state.resealed[1:], quic.connection_identifier_bytes(&header.destination_connection_id))
	copy(state.resealed[number_offset + number_length:], payload[:])
	sealed_end, sealed := quic.packet_seal(&state.cryptography, &space.send_keys, state.resealed[:end], 0, number_offset, len(payload), opened.packet_number, &error)
	if !sealed {
		return nil, false
	}
	return state.resealed[:sealed_end], true
}

// fuzz_quic_integer_write appends the variable-length integer of QUIC
// (RFC 9000, section 16), in the shortest of its encodings.
fuzz_quic_integer_write :: proc(into: ^[dynamic]u8, value: u64) {
	switch {
	case value < 1 << 6:
		append(into, u8(value))
	case value < 1 << 14:
		append(into, u8(value >> 8) | 0x40, u8(value))
	case value < 1 << 30:
		append(into, u8(value >> 24) | 0x80, u8(value >> 16), u8(value >> 8), u8(value))
	case:
		capped := min(value, (u64(1) << 62) - 1)
		append(into, u8(capped >> 56) | 0xC0, u8(capped >> 48), u8(capped >> 40), u8(capped >> 32), u8(capped >> 24), u8(capped >> 16), u8(capped >> 8), u8(capped))
	}
}

// fuzz_quic_field gives a field of a frame: a small value, a boundary of
// the encodings, or any value.
fuzz_quic_field :: proc(source: ^Fuzz_Choices) -> u64 {
	switch fuzz_choice_below(source, 4) {
	case 0:
		return u64(fuzz_choice_below(source, 16))
	case 1:
		edges := [?]u64{63, 64, 16383, 16384, (1 << 30) - 1, 1 << 30, (u64(1) << 62) - 1}
		return edges[fuzz_choice_below(source, len(edges))]
	}
	return fuzz_choice_word(source, 8)
}

// fuzz_quic_frames writes frames from the choices: a known type of frame
// with fields of the choices, or any type and any bytes.
fuzz_quic_frames :: proc(choices: ^Fuzz_Choices) -> []u8 {
	bytes := make([dynamic]u8, context.temp_allocator)
	count := 1 + fuzz_choice_below(choices, 3)
	for _ in 0 ..< count {
		// The types of RFC 9000, section 19: 0x00 to 0x1e, and 0x30 and
		// above, which no version defines.
		frame_type := u64(fuzz_choice_below(choices, 0x20))
		if fuzz_choice_rare(choices, 16) {
			frame_type = fuzz_quic_field(choices)
		}
		fuzz_quic_integer_write(&bytes, frame_type)
		fields := fuzz_choice_below(choices, 6)
		for _ in 0 ..< fields {
			fuzz_quic_integer_write(&bytes, fuzz_quic_field(choices))
		}
		data := fuzz_choice_below(choices, 32)
		for _ in 0 ..< data {
			append(&bytes, fuzz_choice_byte(choices))
		}
	}
	return bytes[:]
}

// fuzz_quic_deliver sends the next datagram of one side, changes it as the
// choices say, and gives it to the other side. changed says if the
// datagram was changed.
fuzz_quic_deliver :: proc(from, to: ^quic.Connection, now: u64, choices: ^Fuzz_Choices) -> (sent: bool, changed: bool) {
	state := fuzz_quic
	length := quic.connection_datagram_send(from, state.buffer[:], now)
	if length <= 0 {
		return false, false
	}
	datagram := state.buffer[:length]
	if choices != nil {
		switch fuzz_choice_below(choices, 10) {
		case 7:
			// Bytes changed: the header, or the protected payload.
			for _ in 0 ..< 1 + fuzz_choice_below(choices, 4) {
				datagram[fuzz_choice_below(choices, len(datagram))] ~= 1 << u8(fuzz_choice_below(choices, 8))
			}
			changed = true
		case 8:
			if resealed, ok := fuzz_quic_reseal(from, datagram, choices); ok {
				datagram = resealed
				changed = true
			}
		case 9:
			datagram = datagram[:fuzz_choice_below(choices, len(datagram))]
			changed = true
		}
	}
	error: errors.Error_Record
	_ = quic.connection_datagram_receive(to, datagram, now, &error)
	return true, changed
}

// fuzz_quic_connection_execute runs a client and a server in memory: steps
// of the choices deliver a datagram one way or the other, change it, or let
// the clock pass. Then the two sides exchange their datagrams with no
// change. When no step changed a datagram, the handshake must complete:
// a client and a server of the system agree.
fuzz_quic_connection_execute :: proc(input: []u8) -> Fuzz_Verdict {
	state := fuzz_quic
	if !fuzz_quic_connections_start() {
		return fuzz_broken(.Contract, "a connection of the target does not start")
	}
	choices := fuzz_choices_of(input)
	now := u64(FUZZ_QUIC_START_TIME)
	changed_any := false
	for _ in 0 ..< fuzz_choice_below(&choices, FUZZ_QUIC_STEP_LIMIT) {
		if fuzz_choices_ran_out(&choices) {
			break
		}
		switch fuzz_choice_below(&choices, 3) {
		case 0:
			_, changed := fuzz_quic_deliver(&state.client, &state.server, now, &choices)
			changed_any ||= changed
		case 1:
			_, changed := fuzz_quic_deliver(&state.server, &state.client, now, &choices)
			changed_any ||= changed
		case 2:
			now += u64(1 + fuzz_choice_below(&choices, FUZZ_QUIC_TIME_STEP_LIMIT))
			quic.connection_time_passes(&state.client, now)
			quic.connection_time_passes(&state.server, now)
		}
		if state.client.state > max(quic.Connection_State) || state.server.state > max(quic.Connection_State) {
			return fuzz_broken(.Contract, "a state is out of its enumeration")
		}
	}
	for _ in 0 ..< FUZZ_QUIC_PUMP_LIMIT {
		if state.client.state == .Connected && state.server.state == .Connected {
			break
		}
		client_sent, _ := fuzz_quic_deliver(&state.client, &state.server, now, nil)
		server_sent, _ := fuzz_quic_deliver(&state.server, &state.client, now, nil)
		if !client_sent && !server_sent {
			now += 10_000
			quic.connection_time_passes(&state.client, now)
			quic.connection_time_passes(&state.server, now)
		}
	}
	if !changed_any && (state.client.state != .Connected || state.server.state != .Connected) {
		return fuzz_broken(.Two_Readers, "a client and a server with no change of their datagrams do not connect: client %v, server %v", state.client.state, state.server.state)
	}
	return FUZZ_PASSED
}

// ---------------------------------------------------------------------
// The messages of TLS.

// The input of the target: one byte for the role (bit 0: the server),
// then messages, each one byte of its level, two bytes of its length in
// little-endian order, and its bytes.
fuzz_tls_messages_execute :: proc(input: []u8) -> Fuzz_Verdict {
	state := fuzz_quic
	if len(input) == 0 {
		return FUZZ_PASSED
	}
	fuzz_quic_generators_seed()
	error: errors.Error_Record
	handshake: ^quic.Tls_Handshake
	if input[0] & 1 == 1 {
		handshake = &state.server_tls
		configuration := state.server_configuration.tls
		fuzz_tls_transport_parameters(&configuration)
		if !quic.tls_start(handshake, &configuration, &state.cryptography, &state.server_generator, &error) {
			return fuzz_broken(.Contract, "the server of the target does not start")
		}
	} else {
		handshake = &state.client_tls
		configuration := state.client_configuration.tls
		fuzz_tls_transport_parameters(&configuration)
		if !quic.tls_start(handshake, &configuration, &state.cryptography, &state.client_generator, &error) {
			return fuzz_broken(.Contract, "the client of the target does not start")
		}
	}
	at := 1
	for at + 3 <= len(input) {
		level := quic.Encryption_Level(input[at] % 3)
		length := int(input[at + 1]) | int(input[at + 2]) << 8
		at += 3
		bytes := input[at:min(at + length, len(input))]
		at += len(bytes)
		_ = quic.tls_receive(handshake, level, bytes, &error)
		if handshake.state > max(quic.Tls_State) {
			return fuzz_broken(.Contract, "the state of the handshake is out of its enumeration: %d", u8(handshake.state))
		}
		for sent_level in quic.Encryption_Level {
			waiting := quic.tls_bytes_to_send(handshake, sent_level)
			quic.tls_bytes_sent(handshake, sent_level, len(waiting))
		}
	}
	return FUZZ_PASSED
}

// fuzz_tls_transport_parameters writes the transport parameters of the
// role of a configuration: the defaults, and for a server the identifier
// of the first Initial packet.
fuzz_tls_transport_parameters :: proc(configuration: ^quic.Tls_Configuration) {
	parameters := quic.sent_transport_parameters_default()
	if configuration.role == .Server {
		parameters.original_destination_connection_id = quic.connection_identifier_of_chosen({})
	}
	configuration.transport_parameters_length = quic.transport_parameters_write(&parameters, configuration.role, configuration.transport_parameters[:])
}

// fuzz_tls_messages_seeds gives the messages of a whole handshake between
// a client and a server of the targets, with the same seeds as each
// execution: the ClientHello to the server, and the flight of the server
// to the client, which then reaches its last state.
fuzz_tls_messages_seeds :: proc(seeds: ^[dynamic][]u8) {
	if fuzz_quic == nil && !fuzz_quic_start() {
		return
	}
	state := fuzz_quic
	fuzz_quic_generators_seed()
	error: errors.Error_Record
	client_configuration := state.client_configuration.tls
	server_configuration := state.server_configuration.tls
	fuzz_tls_transport_parameters(&client_configuration)
	fuzz_tls_transport_parameters(&server_configuration)
	if !quic.tls_start(&state.client_tls, &client_configuration, &state.cryptography, &state.client_generator, &error) || !quic.tls_start(&state.server_tls, &server_configuration, &state.cryptography, &state.server_generator, &error) {
		return
	}
	to_server := make([dynamic]u8)
	to_client := make([dynamic]u8)
	append(&to_server, 1)
	append(&to_client, 0)
	message :: proc(into: ^[dynamic]u8, level: quic.Encryption_Level, bytes: []u8) {
		if len(bytes) == 0 {
			return
		}
		append(into, u8(level), u8(len(bytes)), u8(len(bytes) >> 8))
		append(into, ..bytes)
	}
	// Two rounds: the ClientHello, the flight of the server, the Finished
	// of the client.
	for _ in 0 ..< 2 {
		for level in quic.Encryption_Level {
			bytes := quic.tls_bytes_to_send(&state.client_tls, level)
			message(&to_server, level, bytes)
			_ = quic.tls_receive(&state.server_tls, level, bytes, &error)
			quic.tls_bytes_sent(&state.client_tls, level, len(bytes))
		}
		for level in quic.Encryption_Level {
			bytes := quic.tls_bytes_to_send(&state.server_tls, level)
			message(&to_client, level, bytes)
			_ = quic.tls_receive(&state.client_tls, level, bytes, &error)
			quic.tls_bytes_sent(&state.server_tls, level, len(bytes))
		}
	}
	append(seeds, to_server[:], to_client[:])
}

// ---------------------------------------------------------------------
// The transport parameters.

// The input: one byte for the role of the sender (bit 0: the server), then
// the bytes of the parameters. What the reader accepts, the writer takes:
// the part of the record that this system sends, which the reader reads
// again to that part with the defaults of RFC 9000, section 18.2, in the
// parameters that the writer has no field for.
fuzz_transport_parameters_execute :: proc(input: []u8) -> Fuzz_Verdict {
	if len(input) == 0 {
		return FUZZ_PASSED
	}
	sender := input[0] & 1 == 1 ? quic.Tls_Role.Server : quic.Tls_Role.Client
	parameters: quic.Transport_Parameters
	if quic.transport_parameters_read(input[1:], sender, &parameters) != .No_Error {
		return FUZZ_PASSED
	}
	buffer: [quic.TRANSPORT_PARAMETERS_LIMIT]u8
	length := quic.transport_parameters_write(&parameters.sent, sender, buffer[:])
	if length == 0 {
		return fuzz_broken(.Round_Trip, "the writer refuses parameters that the reader accepted")
	}
	again: quic.Transport_Parameters
	if result := quic.transport_parameters_read(buffer[:length], sender, &again); result != .No_Error {
		return fuzz_broken(.Round_Trip, "the reader refuses what the writer wrote: %v", result)
	}
	if again != quic.transport_parameters_of_sent(parameters.sent) {
		return fuzz_broken(.Round_Trip, "the parameters read again differ from the parameters read first")
	}
	return FUZZ_PASSED
}

fuzz_transport_parameters_seeds :: proc(seeds: ^[dynamic][]u8) {
	for role in quic.Tls_Role {
		parameters := quic.sent_transport_parameters_default()
		if role == .Server {
			parameters.original_destination_connection_id = quic.connection_identifier_of_chosen({})
		}
		buffer: [quic.TRANSPORT_PARAMETERS_LIMIT]u8
		length := quic.transport_parameters_write(&parameters, role, buffer[:])
		seed := make([]u8, 1 + length)
		seed[0] = role == .Server ? 1 : 0
		copy(seed[1:], buffer[:length])
		append(seeds, seed)
	}
}
