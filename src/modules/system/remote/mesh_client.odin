package remote_service

// The outbound links of this machine to its paired machines
// (src/md/features/several_machines.md, "The outbound link").
//
// remote answers the mesh frames of the streams that a paired machine opens
// (mesh.odin). This file opens the other direction: a QUIC connection of a
// client from this process to a paired machine, whose TLS handshake pins
// the identity key of that machine, and whose own key is the identity key
// of this machine. machine_wire.Mesh_Link keeps the session of each link:
// the pinned key, the requests in flight with their bounds, and the end of
// each one (Answered, Refused, Unknown_Outcome, Unreachable).
//
// The datagrams of a link cross the endpoint of the server: a datagram that
// arrives from the address and the port of a link goes to its connection
// before the server sees the others (mesh_client_receive), and the loop
// sends the datagrams of each link after the pass of the server
// (mesh_client_work). The listen grant of today admits the address of the
// host only, so the network service drops each datagram to another
// address: such a link never comes up, and its requests end Unreachable at
// the bound of the handshake.
//
// The procedures mesh_connect, mesh_fetch_object, mesh_call_role,
// mesh_sync_store and mesh_pairing_join_send start one step and give 0 or
// an identifier, or -1 with an error record; mesh_request_result gives the
// end of a request when it came.

import "modus:contract/blake3"
import "modus:contract/enum_word"
import "modus:contract/errors"
import "modus:contract/machine_mesh"
import "modus:contract/machine_wire"
import "modus:contract/object_cache"
import "modus:contract/remote"
import "modus:contract/ring"
import "modus:contract/role_contract"
import "modus:network"
import "modus:quic"
import "modus:quic_server"
import "modus:system"

MESH_LINK_CAPACITY :: 2
MESH_STREAMS_PER_LINK :: machine_wire.MESH_REQUESTS_AT_ONCE
MESH_HANDSHAKE_BOUND_MILLISECONDS :: 10_000
MESH_REQUEST_BOUND_MILLISECONDS :: 10_000

Mesh_Client_Phase :: enum u8 {
	Free      = 0,
	Sending   = 1, // The frame waits for a stream, or goes into it.
	Receiving = 2, // The whole frame went; the answer comes.
	Ended     = 3, // The end is known: mesh_request_result gives it once, then the place is free.
}

// One request of a link: its frame, its answer, and what its end needs.
Mesh_Client_Request :: struct {
	phase:            Mesh_Client_Phase,
	kind:             machine_wire.Mesh_Request_Kind,
	identifier:       u64, // The identifier of the session.
	stream:           u64,
	has_stream:       bool,
	request_length:   int,
	written:          int,
	received:         int,
	outcome:          machine_wire.Mesh_Outcome,
	reason:           machine_wire.Refusal_Reason,
	detail:           u32,
	object_kind:      object_cache.Cache_Object_Kind,
	hash:             blake3.Hash, // The object of a fetch, or the store of an offer.
	fetch:            machine_wire.Object_Fetch_Status,
	store:            machine_wire.Store_Status,
	role_value:       i64,
	role_result_size: int,
	request:          [machine_wire.FRAME_LIMIT]u8,
	answer:           [machine_wire.FRAME_LIMIT]u8,
}

Mesh_Client_Link :: struct {
	in_use:   bool,
	logged:   bool, // The fact of the link that is up went to the log.
	session:  machine_wire.Mesh_Link,
	address:  quic.Remote,
	requests: [MESH_STREAMS_PER_LINK]Mesh_Client_Request,
}

// The memory of the outbound links: in the data of the process, never a
// stack. A connection record has about 88 KiB, a stream record about
// 130 KiB.
Mesh_Client_Memory :: struct {
	configuration: quic.Connection_Configuration,
	configured:    bool,
	links:         [MESH_LINK_CAPACITY]Mesh_Client_Link,
	connections:   [MESH_LINK_CAPACITY]quic.Connection,
	streams:       [MESH_LINK_CAPACITY][MESH_STREAMS_PER_LINK]quic.Stream,
}
MESH_CLIENT_PAGES :: (size_of(Mesh_Client_Memory) + system.PAGE_SIZE - 1) / system.PAGE_SIZE

mesh_client: Mesh_Client_Memory

// mesh_client_configure takes the configuration of the server before its
// private key is erased: the key of this machine proves this machine to a
// paired machine, as a client key.
mesh_client_configure :: proc "contextless" (server_configuration: ^quic.Connection_Configuration) {
	configuration := &mesh_client.configuration
	configuration^ = {idle_timeout_milliseconds = server_configuration.idle_timeout_milliseconds}
	configuration.tls = {role = .Client, least_seed_strength = .Processor}
	configuration.tls.application_protocol_length = copy(configuration.tls.application_protocol[:], remote.APPLICATION_PROTOCOL)
	configuration.tls.client_private_key = server_configuration.tls.server_private_key
	mesh_client.configured = true
}

@(private = "file")
mesh_link_find :: proc "contextless" (identity: [32]u8) -> (link: ^Mesh_Client_Link, index: int) {
	for &item, place in mesh_client.links {
		if item.in_use && item.session.pinned_identity == identity {
			return &item, place
		}
	}
	return nil, -1
}

@(private = "file")
mesh_client_status_fail :: proc "contextless" (error: ^errors.Error_Record, status: machine_wire.Mesh_Client_Status, argument: i64) -> i64 {
	found := i64(status)
	switch status {
	case .Ok:
		return 0
	case .Refused_Zero_Key, .Refused_Same_Machine, .Refused_Bad_Request, .Refused_Bad_Purpose:
		return errors.fail(error, -1, .Bad_Value, .None, argument, 0, 0, found)
	case .Refused_Not_Paired, .Refused_No_Pairing:
		return errors.fail(error, -1, .Absent, .Records, argument, 0, 0, found)
	case .Refused_Identity_Mismatch:
		return errors.fail(error, -1, .Not_Authentic, .None, argument, 0, 0, found)
	case .Refused_Bad_Phase:
		return errors.fail(error, -1, .State, .None, argument, 0, 0, found)
	case .Refused_Bad_Bound:
		return errors.fail(error, -1, .Out_Of_Range, .Milliseconds, argument, 0, 0, found)
	case .Refused_Full:
		return errors.fail(error, -1, .Full, .Requests, argument, 0, machine_wire.MESH_REQUESTS_AT_ONCE, found)
	case .Unreachable:
		return errors.fail(error, -1, .Link_Down, .Connection, argument, 0, 0, found)
	}
	return errors.fail(error, -1, .Bad_Value, .None, argument, 0, 0, found)
}

// mesh_connect opens the outbound link to a machine, at an address and a
// port. purpose_word is the word of machine_wire.Mesh_Link_Purpose: Paired
// for a paired machine, Pairing to join the offer of that machine with the
// code that mesh_pairing_join took. The handshake pins its identity key. It
// gives the place of the link, or -1 with an error record.
mesh_connect :: proc "contextless" (identity: [32]u8, address: u32, port: u16, purpose_word: u64, error: ^errors.Error_Record) -> i64 {
	if !mesh.has_identity || !mesh_client.configured {
		return errors.fail(error, -1, .State, .None, 0)
	}
	purpose, purpose_known := enum_word.member_of_word(machine_wire.Mesh_Link_Purpose, purpose_word)
	if !purpose_known || purpose == .None {
		return errors.fail(error, -1, .Bad_Value, .None, 4, i64(purpose_word))
	}
	if address == 0 || port == 0 {
		return errors.fail(error, -1, .Bad_Value, .None, 2, i64(address))
	}
	link, index := mesh_link_find(identity)
	if link == nil {
		for &item, place in mesh_client.links {
			if !item.in_use {
				link, index = &item, place
				break
			}
		}
	}
	if link == nil {
		return errors.fail(error, -1, .Full, .Connections, 1, 0, MESH_LINK_CAPACITY)
	}
	now := system.time()
	status := machine_wire.mesh_link_open(&link.session, &mesh, identity, purpose, now, MESH_HANDSHAKE_BOUND_MILLISECONDS)
	if status != .Ok {
		return mesh_client_status_fail(error, status, 1)
	}
	link.in_use = true
	link.logged = false
	link.address = quic.Remote{address = address, port = port}
	configuration := mesh_client.configuration
	configuration.tls.server_public_key = identity
	if !quic.connection_start_client(&mesh_client.connections[index], mesh_client.streams[index][:], &configuration, &cryptography, &process_generator, now_microseconds(), error) {
		machine_wire.mesh_link_broken(&link.session)
		quic.secret_erase(&configuration.tls.client_private_key, size_of(configuration.tls.client_private_key))
		return -1
	}
	quic.secret_erase(&configuration.tls.client_private_key, size_of(configuration.tls.client_private_key))
	return i64(index)
}

// mesh_client_begin keeps one request frame of a link, which the loop
// sends on a new stream when the link is up.
@(private = "file")
mesh_client_begin :: proc "contextless" (identity: [32]u8, frame: []u8, error: ^errors.Error_Record) -> (request: ^Mesh_Client_Request, identifier: i64) {
	link, _ := mesh_link_find(identity)
	if link == nil {
		return nil, errors.fail(error, -1, .Absent, .Connection, 1)
	}
	if frame == nil {
		return nil, errors.fail(error, -1, .Bad_Value, .None, 2)
	}
	session_identifier, status := machine_wire.mesh_request_begin(&link.session, frame, system.time(), MESH_REQUEST_BOUND_MILLISECONDS)
	if status != .Ok {
		return nil, mesh_client_status_fail(error, status, 2)
	}
	for &item in link.requests {
		if item.phase != .Free {
			continue
		}
		decoded, _ := machine_wire.frame_decode(frame)
		kind, _ := machine_wire.mesh_request_kind_of_message(decoded.message)
		item = {}
		item.phase = .Sending
		item.kind = kind
		item.identifier = session_identifier
		item.request_length = copy(item.request[:], frame)
		return &item, i64(session_identifier)
	}
	// A place of an ended request that nobody read holds its end.
	machine_wire.mesh_answer_accept(&link.session, session_identifier, nil)
	return nil, errors.fail(error, -1, .Full, .Requests, 2, 0, MESH_STREAMS_PER_LINK)
}

// The frame of a request is written in the answer place, which is free until
// the answer comes, then copied into the request place.
@(private = "file")
mesh_frame_buffer: [machine_wire.FRAME_LIMIT]u8

// mesh_fetch_object asks a paired machine for an object by its kind and
// hash. The object is kept only when its bytes hash to the hash.
mesh_fetch_object :: proc "contextless" (identity: [32]u8, kind_word: u64, hash: blake3.Hash, error: ^errors.Error_Record) -> i64 {
	kind, kind_ok := object_cache.cache_object_kind_of_word(kind_word)
	if !kind_ok {
		return errors.fail(error, -1, .Bad_Value, .None, 2, i64(kind_word))
	}
	request, identifier := mesh_client_begin(identity, machine_wire.object_request_write(mesh_frame_buffer[:], kind, hash), error)
	if request == nil {
		return identifier
	}
	request.object_kind = kind
	request.hash = hash
	return identifier
}

// mesh_call_role sends one call of a role contract held on a paired
// machine. role_word is a role_contract.Role, flags_word the word of
// machine_wire.Role_Call_Flags.
mesh_call_role :: proc "contextless" (identity: [32]u8, role_word: u64, export: u32, flags_word: u64, arguments: []u8, error: ^errors.Error_Record) -> i64 {
	role, role_ok := enum_word.member_of_word(role_contract.Role, role_word)
	if !role_ok || role == .None {
		return errors.fail(error, -1, .Bad_Value, .None, 2, i64(role_word))
	}
	if flags_word > u64(max(u32)) {
		return errors.fail(error, -1, .Bad_Flags, .None, 4, i64(flags_word))
	}
	flags, flags_ok := machine_wire.role_call_flags_of_word(u32(flags_word))
	if !flags_ok {
		return errors.fail(error, -1, .Bad_Flags, .None, 4, i64(flags_word))
	}
	if len(arguments) > machine_wire.ROLE_ARGUMENT_LIMIT {
		return errors.fail(error, -1, .Too_Long, .Bytes, 5, i64(len(arguments)), machine_wire.ROLE_ARGUMENT_LIMIT)
	}
	link, _ := mesh_link_find(identity)
	if link == nil {
		return errors.fail(error, -1, .Absent, .Connection, 1)
	}
	// The call identifier is the identifier that the session gives this
	// request: a reply names this request and no other.
	call_identifier := link.session.next_identifier + 1
	frame := machine_wire.role_call_write(mesh_frame_buffer[:], machine_wire.Role_Call{identifier = call_identifier, role = role, export = export, flags = flags, arguments = arguments})
	_, identifier := mesh_client_begin(identity, frame, error)
	return identifier
}

// mesh_sync_store offers the version of an exchanged store to its partner.
// A request with no answer keeps the offer: the next sync sends it again.
mesh_sync_store :: proc "contextless" (identity: [32]u8, store_identifier: blake3.Hash, error: ^errors.Error_Record) -> i64 {
	store := machine_wire.store_exchange_find(&mesh.stores, store_identifier)
	if store == nil {
		return errors.fail(error, -1, .Absent, .Stores, 2)
	}
	if store.partner_identity != identity {
		return errors.fail(error, -1, .No_Grant, .Stores, 1)
	}
	request, identifier := mesh_client_begin(identity, machine_wire.store_offer_begin(store, mesh_frame_buffer[:]), error)
	if request != nil {
		request.hash = store_identifier
	}
	return identifier
}

// mesh_pairing_join_send sends the first pairing frame of the joiner on a
// link of purpose Pairing; the loop sends the confirmation when the reply
// comes.
mesh_pairing_join_send :: proc "contextless" (identity: [32]u8, error: ^errors.Error_Record) -> i64 {
	link, _ := mesh_link_find(identity)
	if link == nil || link.session.purpose != .Pairing {
		return errors.fail(error, -1, .Absent, .Connection, 1)
	}
	if link.session.state != .Up {
		return errors.fail(error, -1, .Link_Down, .Connection, 1)
	}
	frame, status := machine_wire.pairing_element_write(&mesh, identity, machine_wire.mesh_link_channel_binding(&link.session), system.time(), mesh_frame_buffer[:])
	if status != .Ok {
		return errors.fail(error, -1, .Refused, .None, 1, 0, 0, i64(status))
	}
	_, identifier := mesh_client_begin(identity, frame, error)
	return identifier
}

// mesh_request_result gives the end of a request: 0 while it is in
// flight, 1 when it was answered and its effect holds (the object kept, the
// store merged, the pairing confirmed, the role answered: value and the
// result bytes), or -1 with an error record: Refused, No_Answer for an
// unknown outcome, Link_Down for a request that never left, Not_Authentic
// for an object whose bytes do not hash to its hash.
mesh_request_result :: proc "contextless" (identity: [32]u8, identifier: u64, value: ^i64, result: []u8, error: ^errors.Error_Record) -> i64 {
	link, _ := mesh_link_find(identity)
	if link == nil {
		return errors.fail(error, -1, .Absent, .Connection, 1)
	}
	for &item in link.requests {
		if item.phase == .Free || item.identifier != identifier {
			continue
		}
		if item.phase != .Ended {
			return 0
		}
		// The end is read once: the place is free after this call. The
		// record holds two frames, so it is read in place, never copied to
		// the stack.
		ended := &item
		defer ended^ = {}
		switch ended.outcome {
		case .Answered:
		case .Refused:
			return errors.fail(error, -1, .Refused, .None, 2, i64(ended.detail), 0, i64(ended.reason))
		case .Unknown_Outcome:
			return errors.fail(error, -1, .No_Answer, .Requests, 2, i64(ended.detail), 0, i64(ended.reason))
		case .Unreachable, .None:
			return errors.fail(error, -1, .Link_Down, .Connection, 2)
		}
		switch ended.kind {
		case .Object_Request:
			switch ended.fetch {
			case .Stored, .Already_Stored:
			case .Hash_Mismatch:
				return errors.fail(error, -1, .Not_Authentic, .Objects, 2)
			case .Full:
				return errors.fail(error, -1, .Full, .Objects, 2, 0, machine_wire.OBJECT_CAPACITY)
			case .Too_Large:
				return errors.fail(error, -1, .Too_Long, .Bytes, 2, 0, machine_wire.OBJECT_BYTES_LIMIT)
			case .Refused, .Malformed, .Other_Object:
				return errors.fail(error, -1, .Malformed, .Objects, 2, 0, 0, i64(ended.fetch))
			}
		case .Store_Offer:
			if ended.store != .Ok {
				return errors.fail(error, -1, .Refused, .Stores, 2, 0, 0, i64(ended.store))
			}
		case .Role_Call:
			if value != nil {
				value^ = ended.role_value
			}
			// The bytes of the result are still in the answer frame.
			if reply_frame, frame_status := machine_wire.frame_decode(ended.answer[:ended.received]); frame_status == .Ok {
				if reply, read_ok := machine_wire.role_reply_read(reply_frame.body); read_ok {
					copy(result, reply.result)
				}
			}
		case .Pairing_Element, .Pairing_Confirm, .None:
		}
		return 1
	}
	return errors.fail(error, -1, .Absent, .Requests, 2, i64(identifier))
}

// mesh_client_receive gives each datagram that arrived from the address of
// a link to its connection, and gives back the count of the others, which
// stay at the front of arrived for the server.
mesh_client_receive :: proc "contextless" (arrived: []ring.Record, now_us: u64) -> int {
	kept := 0
	for record in arrived {
		link_index := -1
		if record.tag < u32(quic_endpoint.receive_places) && record.values[2] <= u64(max(u32)) && record.values[3] <= u64(max(u16)) {
			for &link, place in mesh_client.links {
				if link.in_use && link.address.address == u32(record.values[2]) && link.address.port == u16(record.values[3]) {
					link_index = place
				}
			}
		}
		if link_index < 0 {
			arrived[kept] = record
			kept += 1
			continue
		}
		bytes := quic_server.place_bytes(&quic_endpoint, record.tag)
		if bytes != nil && record.values[1] >= network.UDP_HEADER && record.values[1] <= u64(len(bytes)) {
			// QUIC authenticates each packet: the UDP checksum adds nothing.
			if data, whole := network.udp_data_read(bytes[:record.values[1]], u32(record.values[2]), quic_endpoint.local_address, .Do_Not_Verify); whole {
				error: errors.Error_Record
				quic.connection_datagram_receive(&mesh_client.connections[link_index], data, now_us, &error)
			}
		}
		quic_server.post_receive(&quic_endpoint, record.tag)
	}
	return kept
}

@(private = "file")
mesh_request_end :: proc "contextless" (link: ^Mesh_Client_Link, identifier: u64, outcome: machine_wire.Mesh_Outcome) {
	for &item in link.requests {
		if item.phase != .Free && item.phase != .Ended && item.identifier == identifier {
			item.outcome = outcome
			item.phase = .Ended
		}
	}
}

// mesh_answer_take reads the answer of one request and applies its effect.
@(private = "file")
mesh_answer_take :: proc "contextless" (link: ^Mesh_Client_Link, item: ^Mesh_Client_Request) {
	answer := item.answer[:item.received]
	_, outcome, reason, detail, found := machine_wire.mesh_answer_accept(&link.session, item.identifier, answer)
	if !found {
		item.phase = .Ended
		item.outcome = .Unknown_Outcome
		return
	}
	item.outcome = outcome
	item.reason = reason
	item.detail = detail
	item.phase = .Ended
	if outcome != .Answered {
		if item.kind == .Pairing_Element || item.kind == .Pairing_Confirm {
			machine_mesh.pairing_fail(&mesh.pairing, .Refused_Exchange)
		}
		return
	}
	switch item.kind {
	case .Object_Request:
		item.fetch, _ = machine_wire.object_response_accept(&mesh, item.object_kind, item.hash, answer)
	case .Store_Offer:
		if store := machine_wire.store_exchange_find(&mesh.stores, item.hash); store != nil {
			item.store, _, _ = machine_wire.store_offer_reply_accept(store, answer)
		} else {
			item.store = .Refused_Unknown_Store
		}
	case .Role_Call:
		frame, _ := machine_wire.frame_decode(answer)
		reply, read_ok := machine_wire.role_reply_read(frame.body)
		if !read_ok || reply.identifier != item.identifier {
			item.outcome = .Unknown_Outcome
			return
		}
		if reply.outcome == .Refused {
			item.outcome = .Refused
			item.reason = .Role_Refused
		}
		item.role_value = reply.value
		item.role_result_size = len(reply.result)
	case .Pairing_Element:
		confirm, status := machine_wire.pairing_element_reply_accept(&mesh, answer, system.time(), mesh_frame_buffer[:])
		if confirm != nil {
			// The confirm goes also when the tag of the offerer failed, so
			// the code ends on both machines.
			error: errors.Error_Record
			mesh_client_begin(link.session.pinned_identity, confirm, &error)
		}
		if status != .Ok {
			item.outcome = .Refused
			item.reason = .Pairing_Refused
			item.detail = u32(status)
		}
	case .Pairing_Confirm:
		if _, _, ok := machine_wire.pairing_confirmed_accept(&mesh, link.session.pinned_identity, answer); !ok {
			item.outcome = .Refused
			item.reason = .Pairing_Refused
		}
	case .None:
	}
}

// mesh_client_work moves each link: its handshake, its requests and their
// streams, its bounds and its datagrams. It gives the nearest deadline of
// the links, in microseconds.
mesh_client_work :: proc "contextless" (now_us: u64) -> (deadline_us: u64) {
	deadline_us = max(u64)
	now_ms := now_us / 1000
	for &link, index in mesh_client.links {
		if !link.in_use {
			continue
		}
		connection := &mesh_client.connections[index]
		quic.connection_time_passes(connection, now_us)
		if link.session.state == .Connecting && connection.state == .Connected {
			if machine_wire.mesh_link_established(&link.session, connection.configuration.tls.server_public_key) != .Ok {
				quic.connection_close(connection, u64(remote.Stream_Error.Revoked), now_us)
			} else if !link.logged {
				link.logged = true
				system.log_fact(.Info, Mesh_Link_Up{client_key_head = key_head_field(link.session.pinned_identity), peer = peer_field(link.address)})
			}
		}
		connection_ended := connection.state == .Closing || connection.state == .Draining || connection.state == .Closed
		if connection_ended && (link.session.state == .Connecting || link.session.state == .Up) {
			ended, count := machine_wire.mesh_link_broken(&link.session)
			unknown, unreachable: u64
			for end in ended[:count] {
				mesh_request_end(&link, end.identifier, end.outcome)
				if end.outcome == .Unknown_Outcome {
					unknown += 1
				} else {
					unreachable += 1
				}
			}
			system.log_fact(.Info, Mesh_Link_Ended{unknown_outcome = unknown, unreachable = unreachable, client_key_head = key_head_field(link.session.pinned_identity), peer = peer_field(link.address)})
		}
		ended, count := machine_wire.mesh_link_expire(&link.session, now_ms)
		for end in ended[:count] {
			for &item in link.requests {
				if item.phase != .Free && item.phase != .Ended && item.identifier == end.identifier && item.has_stream {
					quic.stream_reset(connection, item.stream, u64(remote.Stream_Error.Timeout))
				}
			}
			mesh_request_end(&link, end.identifier, end.outcome)
		}
		if link.session.state == .Broken && !connection_ended {
			quic.connection_close(connection, u64(remote.Stream_Error.Timeout), now_us)
		}
		if connection.state == .Connected {
			for &item in link.requests {
				switch item.phase {
				case .Free, .Ended:
				case .Sending:
					if !item.has_stream {
						item.stream, item.has_stream = quic.stream_open(connection)
						if !item.has_stream {
							continue
						}
					}
					item.written += quic.stream_write(connection, item.stream, item.request[item.written:item.request_length], true)
					if item.written >= item.request_length {
						item.phase = .Receiving
					}
				case .Receiving:
					count_read, finished, reset := quic.stream_read(connection, item.stream, item.answer[item.received:])
					item.received += count_read
					if reset {
						// The other machine reset the stream after the request
						// left: it can have run.
						machine_wire.mesh_answer_accept(&link.session, item.identifier, nil)
						item.phase = .Ended
						item.outcome = .Unknown_Outcome
					} else if finished {
						mesh_answer_take(&link, &item)
					} else if item.received >= len(item.answer) {
						quic.stream_reset(connection, item.stream, u64(remote.Stream_Error.Too_Large))
						machine_wire.mesh_answer_accept(&link.session, item.identifier, nil)
						item.phase = .Ended
						item.outcome = .Unknown_Outcome
					}
				}
			}
		}
		// The datagrams of the link go through the endpoint of the server.
		for quic_endpoint.free_count > 0 && connection.state != .Idle && connection.state != .Closed {
			place, has := quic_server.place_take(&quic_endpoint)
			if !has {
				break
			}
			length := quic.connection_datagram_send(connection, quic_server.data_bytes(&quic_endpoint, place), now_us)
			if length <= 0 || !quic_server.send_datagram(&quic_endpoint, place, length, link.address) {
				quic_server.place_return(&quic_endpoint, place)
				break
			}
		}
		if connection.state == .Closed && link.session.state != .Connecting && link.session.state != .Up {
			// The link ended: its place serves again when no request end
			// waits to be read.
			waiting := false
			for item in link.requests {
				if item.phase != .Free {
					waiting = true
				}
			}
			if !waiting {
				link.in_use = false
			}
		}
		if connection.state != .Idle && connection.state != .Closed {
			deadline_us = min(deadline_us, quic.connection_deadline(connection))
		}
		if link.session.state == .Connecting {
			deadline_us = min(deadline_us, link.session.connect_deadline_ms * 1000)
		}
		for pending in link.session.pending {
			if pending.identifier != 0 {
				deadline_us = min(deadline_us, pending.deadline_ms * 1000)
			}
		}
	}
	return deadline_us
}
