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
// each one, a call outcome (machine_wire, "The ends of a request").
//
// The datagrams of a link cross the endpoint of the server: a datagram
// whose first packet names the connection identifier that a link chose goes
// to that link before the server sees the others (mesh_client_receive), and the loop
// sends the datagrams of each link after the pass of the server
// (mesh_client_work). The listen grant of today admits the address of the
// host only, so the network service drops each datagram to another
// address: such a link never comes up, and its requests end Unreachable at
// the bound of the handshake.
//
// The procedures mesh_connect, mesh_fetch_object, mesh_call_role,
// mesh_sync_store and mesh_pairing_join_send start one step and give
// Succeeded with 0 or an identifier, or a failure with its call outcome and
// an error record; mesh_request_result gives the end of a request when it
// came.

import "base:intrinsics"
import "modus:contract/blake3"
import "modus:contract/call_outcome"
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
	outcome:          call_outcome.Call_Outcome,
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

// mesh_client_configure takes the configuration of the outbound links from
// the configuration of the server, with no private key. The key of this
// machine proves this machine to a paired machine as a client key; the
// server keeps it for its life, and mesh_connect copies it only for the
// start of one connection, so no idle copy waits in this memory.
mesh_client_configure :: proc "contextless" (server_configuration: ^quic.Connection_Configuration) {
	configuration := &mesh_client.configuration
	configuration^ = {idle_timeout_milliseconds = server_configuration.idle_timeout_milliseconds}
	configuration.tls = {role = .Client, least_seed_strength = .Processor}
	configuration.tls.application_protocol_length = copy(configuration.tls.application_protocol[:], remote.APPLICATION_PROTOCOL)
	mesh_client.configured = true
}

// mesh_client_key_erase writes zeros over a copy of the private key of
// this machine. Each store is volatile: a plain store of zeros to memory
// that is not read again can be removed by the compiler.
mesh_client_key_erase :: proc "contextless" (key: ^[quic.ED25519_KEY_SIZE]u8) {
	for index in 0 ..< len(key) {
		intrinsics.volatile_store(&key[index], 0)
	}
}

// mesh_client_shutdown ends each outbound link. The service calls it before
// it stops on a failure; after it, mesh_connect refuses until a new
// mesh_client_configure.
mesh_client_shutdown :: proc "contextless" () {
	now_us := now_microseconds()
	for &link, index in mesh_client.links {
		if !link.in_use {
			continue
		}
		connection := &mesh_client.connections[index]
		if connection.state != .Idle && connection.state != .Closed {
			quic.connection_close(connection, u64(remote.Stream_Error.None), now_us)
		}
		machine_wire.mesh_link_broken(&link.session)
	}
	mesh_client.configured = false
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
// mesh_client_status_fail writes the record of a refusal of the session,
// with the outcome that machine_wire.mesh_status_outcome gives it: the
// request did not leave, so nothing changed. found is the status.
mesh_client_status_fail :: proc "contextless" (error: ^errors.Error_Record, status: machine_wire.Mesh_Client_Status, argument: i64) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	outcome = machine_wire.mesh_status_outcome(status)
	found := i64(status)
	switch status {
	case .Ok:
		return .Succeeded, 0
	case .Refused_Zero_Key, .Refused_Same_Machine, .Refused_Bad_Request, .Refused_Bad_Purpose:
		return call_outcome.fail(error, outcome, .Bad_Value, .None, argument, 0, 0, found)
	case .Refused_Not_Paired, .Refused_No_Pairing:
		return call_outcome.fail(error, outcome, .No_Grant, .Records, argument, 0, 0, found)
	case .Refused_Identity_Mismatch:
		// The handshake proved another key: the machine of the key did not answer.
		return call_outcome.fail(error, outcome, .Refused, .None, argument, 0, 0, found)
	case .Refused_Bad_Phase:
		return call_outcome.fail(error, outcome, .State, .None, argument, 0, 0, found)
	case .Refused_Bad_Bound:
		return call_outcome.fail(error, outcome, .Out_Of_Range, .Milliseconds, argument, 0, 0, found)
	case .Refused_Code_Expired:
		return call_outcome.fail(error, outcome, .State, .Milliseconds, argument, 0, i64(machine_mesh.PAIRING_CODE_LIFETIME_MS), found)
	case .Refused_Full:
		return call_outcome.fail(error, outcome, .Full, .Requests, argument, 0, machine_wire.MESH_REQUESTS_AT_ONCE, found)
	case .Unreachable:
		return call_outcome.fail(error, outcome, .Link_Down, .Connection, argument, 0, 0, found)
	}
	return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, argument, 0, 0, found)
}

// mesh_connect opens the outbound link to a machine, at an address and a
// port. purpose_word is the word of machine_wire.Mesh_Link_Purpose: Paired
// for a paired machine, Pairing to join the offer of that machine with the
// code that mesh_pairing_join took. The handshake pins its identity key. It
// gives the place of the link, or a failure with its call outcome and an
// error record.
mesh_connect :: proc "contextless" (identity: [32]u8, address: u32, port: u16, purpose_word: u64, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !mesh.has_identity || !mesh_client.configured {
		return call_outcome.fail(error, .Wrong_State, .State, .None, 0)
	}
	purpose, purpose_known := enum_word.member_of_word(machine_wire.Mesh_Link_Purpose, purpose_word)
	if !purpose_known || purpose == .None {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 4, i64(purpose_word))
	}
	if address == 0 || port == 0 {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 2, i64(address))
	}
	link, index := mesh_link_find(identity)
	// One link for one address and port: two links there would share one
	// path, and a reader of the datagrams would mistake one for the other.
	for &item in mesh_client.links {
		if item.in_use && &item != link && item.address.address == address && item.address.port == port {
			return call_outcome.fail(error, .Name_Already_Taken, .Exists, .Connections, 2, i64(address))
		}
	}
	if link == nil {
		for &item, place in mesh_client.links {
			if !item.in_use {
				link, index = &item, place
				break
			}
		}
	}
	if link == nil {
		return call_outcome.fail(error, .Callee_Busy, .Full, .Connections, 1, 0, MESH_LINK_CAPACITY)
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
	// The key of this machine, from the server that keeps it, for this
	// start only.
	configuration.tls.client_private_key = server.configuration.tls.server_private_key
	if !quic.connection_start_client(&mesh_client.connections[index], mesh_client.streams[index][:], &configuration, &cryptography, &process_generator, now_microseconds(), error) {
		machine_wire.mesh_link_broken(&link.session)
		mesh_client_key_erase(&configuration.tls.client_private_key)
		// The connection did not start: nothing left.
		return .Callee_Unavailable, 0
	}
	// The connection keeps its own copy of the key: the copy on the stack
	// is erased on each path.
	mesh_client_key_erase(&configuration.tls.client_private_key)
	return .Succeeded, i64(index)
}

// mesh_failed gives the outcome of a failure, for a procedure that gives
// a request too.
@(private = "file")
mesh_failed :: proc "contextless" (outcome: call_outcome.Call_Outcome, _: i64) -> (call_outcome.Call_Outcome, i64) {
	return outcome, 0
}

// mesh_client_begin keeps one request frame of a link, which the loop
// sends on a new stream when the link is up.
@(private = "file")
mesh_client_begin :: proc "contextless" (identity: [32]u8, frame: []u8, error: ^errors.Error_Record) -> (request: ^Mesh_Client_Request, outcome: call_outcome.Call_Outcome, identifier: i64) {
	link, _ := mesh_link_find(identity)
	if link == nil {
		return nil, mesh_failed(call_outcome.fail(error, .Nothing_Has_That_Name, .Absent, .Connection, 1))
	}
	if frame == nil {
		return nil, mesh_failed(call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 2))
	}
	session_identifier, status := machine_wire.mesh_request_begin(&link.session, frame, system.time(), MESH_REQUEST_BOUND_MILLISECONDS)
	if status != .Ok {
		failure, _ := mesh_client_status_fail(error, status, 2)
		return nil, failure, 0
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
		return &item, .Succeeded, i64(session_identifier)
	}
	// A place of an ended request that nobody read holds its end.
	machine_wire.mesh_answer_accept(&link.session, session_identifier, nil)
	return nil, mesh_failed(call_outcome.fail(error, .Callee_Busy, .Full, .Requests, 2, 0, MESH_STREAMS_PER_LINK))
}

// The frame of a request is written in the answer place, which is free until
// the answer comes, then copied into the request place.
@(private = "file")
mesh_frame_buffer: [machine_wire.FRAME_LIMIT]u8

// mesh_fetch_object asks a paired machine for an object by its kind and
// hash. The object is kept only when its bytes hash to the hash.
mesh_fetch_object :: proc "contextless" (identity: [32]u8, kind_word: u64, hash: blake3.Hash, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	kind, kind_ok := object_cache.cache_object_kind_of_word(kind_word)
	if !kind_ok {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 2, i64(kind_word))
	}
	request, begun, identifier := mesh_client_begin(identity, machine_wire.object_request_write(mesh_frame_buffer[:], kind, hash), error)
	if request == nil {
		return begun, 0
	}
	request.object_kind = kind
	request.hash = hash
	return .Succeeded, identifier
}

// mesh_call_role sends one call of a role contract held on a paired
// machine. role_word is a role_contract.Role, flags_word the word of
// machine_wire.Role_Call_Flags.
mesh_call_role :: proc "contextless" (identity: [32]u8, role_word: u64, export: u32, flags_word: u64, arguments: []u8, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	role, role_ok := enum_word.member_of_word(role_contract.Role, role_word)
	if !role_ok || role == .None {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 2, i64(role_word))
	}
	if flags_word > u64(max(u32)) {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Flags, .None, 4, i64(flags_word))
	}
	flags, flags_ok := machine_wire.role_call_flags_of_word(u32(flags_word))
	if !flags_ok {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Flags, .None, 4, i64(flags_word))
	}
	if len(arguments) > machine_wire.ROLE_ARGUMENT_LIMIT {
		return call_outcome.fail(error, .Argument_Refused, .Too_Long, .Bytes, 5, i64(len(arguments)), machine_wire.ROLE_ARGUMENT_LIMIT)
	}
	link, _ := mesh_link_find(identity)
	if link == nil {
		return call_outcome.fail(error, .Nothing_Has_That_Name, .Absent, .Connection, 1)
	}
	// The call identifier is the identifier that the session gives this
	// request: a reply names this request and no other.
	call_identifier := link.session.next_identifier + 1
	if call_identifier == 0 {
		call_identifier = 1
	}
	frame := machine_wire.role_call_write(mesh_frame_buffer[:], machine_wire.Role_Call{identifier = call_identifier, role = role, export = export, flags = flags, arguments = arguments})
	_, begun, identifier := mesh_client_begin(identity, frame, error)
	return begun, identifier
}

// mesh_sync_store offers the version of an exchanged store to its partner.
// A request with no answer keeps the offer: the next sync sends it again.
mesh_sync_store :: proc "contextless" (identity: [32]u8, store_identifier: blake3.Hash, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	store := machine_wire.store_exchange_find(&mesh.stores, store_identifier)
	if store == nil {
		return call_outcome.fail(error, .Nothing_Has_That_Name, .Absent, .Stores, 2)
	}
	if store.partner_identity != identity {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Stores, 1)
	}
	request, begun, identifier := mesh_client_begin(identity, machine_wire.store_offer_begin(store, mesh_frame_buffer[:]), error)
	if request != nil {
		request.hash = store_identifier
	}
	return begun, identifier
}

// mesh_pairing_join_send sends the first pairing frame of the joiner on a
// link of purpose Pairing; the loop sends the confirmation when the reply
// comes.
mesh_pairing_join_send :: proc "contextless" (identity: [32]u8, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	link, _ := mesh_link_find(identity)
	if link == nil || link.session.purpose != .Pairing {
		return call_outcome.fail(error, .Nothing_Has_That_Name, .Absent, .Connection, 1)
	}
	if link.session.state != .Up {
		return call_outcome.fail(error, .Callee_Unavailable, .Link_Down, .Connection, 1)
	}
	frame, status := machine_wire.pairing_element_write(&mesh, identity, machine_wire.mesh_link_channel_binding(&link.session), system.time(), mesh_frame_buffer[:])
	if status != .Ok {
		return call_outcome.fail(error, .Callee_Unavailable, .Refused, .None, 1, 0, 0, i64(status))
	}
	_, begun, identifier := mesh_client_begin(identity, frame, error)
	return begun, identifier
}

// mesh_request_result gives the end of a request: Succeeded with 0 while it
// is in flight, Succeeded with 1 when it was answered and its effect holds
// (the object kept, the store merged, the pairing confirmed, the role
// answered: value and the result bytes), or a failure with its outcome and
// an error record: the outcome that the session decided for a request that
// the other machine refused, that is in doubt or that never left;
// Data_Damaged for an object whose bytes do not hash to its hash;
// Answer_Unreadable for an object that is not one; Argument_Refused for a
// role result larger than result. For a role call, result_count is the exact
// count of the result bytes.
mesh_request_result :: proc "contextless" (identity: [32]u8, identifier: u64, value: ^i64, result: []u8, result_count: ^int, error: ^errors.Error_Record) -> (call_outcome.Call_Outcome, i64) {
	link, _ := mesh_link_find(identity)
	if link == nil {
		return call_outcome.fail(error, .Nothing_Has_That_Name, .Absent, .Connection, 1)
	}
	for &item in link.requests {
		if item.phase == .Free || item.identifier != identifier {
			continue
		}
		if item.phase != .Ended {
			return .Succeeded, 0
		}
		// The end is read once: the place is free after this call. The
		// record holds two frames, so it is read in place, never copied to
		// the stack.
		ended := &item
		defer ended^ = {}
		if ended.outcome != .Succeeded {
			// The outcome that the session decided, with the reason of the
			// other machine as the value found.
			return call_outcome.fail(error, ended.outcome, .Refused, .None, 2, i64(ended.detail), 0, i64(ended.reason))
		}
		switch ended.kind {
		case .Object_Request:
			switch ended.fetch {
			case .Stored, .Already_Stored:
			case .Hash_Mismatch:
				return call_outcome.fail(error, .Data_Damaged, .Damaged, .Objects, 2)
			case .Full:
				return call_outcome.fail(error, .Budget_Or_Capacity_Exhausted, .Full, .Objects, 2, 0, machine_wire.OBJECT_CAPACITY)
			case .Too_Large:
				return call_outcome.fail(error, .Answer_Unreadable, .Out_Of_Range, .Bytes, 2, 0, machine_wire.OBJECT_BYTES_LIMIT)
			case .Refused, .Malformed, .Other_Object:
				return call_outcome.fail(error, .Answer_Unreadable, .Malformed, .Objects, 2, 0, 0, i64(ended.fetch))
			}
		case .Store_Offer:
			if ended.store != .Ok {
				return call_outcome.fail(error, .Callee_Unavailable, .Refused, .Stores, 2, 0, 0, i64(ended.store))
			}
		case .Role_Call:
			if len(result) < ended.role_result_size {
				return call_outcome.fail(error, .Argument_Refused, .Too_Long, .Bytes, 4, i64(ended.role_result_size), i64(len(result)))
			}
			if value != nil {
				value^ = ended.role_value
			}
			// The bytes of the result are still in the answer frame.
			copied := 0
			if reply_frame, frame_status := machine_wire.frame_decode(ended.answer[:ended.received]); frame_status == .Ok {
				if reply, read_ok := machine_wire.role_reply_read(reply_frame.body); read_ok {
					copied = copy(result, reply.result)
				}
			}
			if result_count != nil {
				result_count^ = copied
			}
		case .Pairing_Element, .Pairing_Confirm, .None:
		}
		return .Succeeded, 1
	}
	return call_outcome.fail(error, .Nothing_Has_That_Name, .Absent, .Requests, 2, i64(identifier))
}

// mesh_client_receive gives each datagram whose first packet names the
// connection identifier of a link to that link, and gives back the count of
// the others, which stay at the front of arrived for the server. The
// address and the port do not choose the link: a paired machine that
// connects to this machine while this machine connects to it sends both
// from one address and one port, and only the Destination Connection ID
// says which connection a packet is for.
mesh_client_receive :: proc "contextless" (arrived: []ring.Record, now_us: u64) -> int {
	kept := 0
	for record in arrived {
		link_index := -1
		data: []u8
		if record.tag < u32(quic_endpoint.receive_places) && record.values[2] <= u64(max(u32)) && record.values[3] <= u64(max(u16)) {
			bytes := quic_server.place_bytes(&quic_endpoint, record.tag)
			if bytes != nil && record.values[1] >= network.UDP_HEADER && record.values[1] <= u64(len(bytes)) {
				// QUIC authenticates each packet: the UDP checksum adds nothing.
				whole: bool
				data, whole = network.udp_data_read(bytes[:record.values[1]], u32(record.values[2]), quic_endpoint.local_address, .Do_Not_Verify)
				if whole {
					link_index = mesh_link_of_datagram(data, quic.Remote{address = u32(record.values[2]), port = u16(record.values[3])})
				}
			}
		}
		if link_index < 0 {
			arrived[kept] = record
			kept += 1
			continue
		}
		error: errors.Error_Record
		quic.connection_datagram_receive(&mesh_client.connections[link_index], data, now_us, &error)
		quic_server.post_receive(&quic_endpoint, record.tag)
	}
	return kept
}

// mesh_link_of_datagram gives the link whose connection chose the
// Destination Connection ID of the first packet, when the datagram comes
// from the address and the port of that link; -1 for each other datagram.
@(private = "file")
mesh_link_of_datagram :: proc "contextless" (data: []u8, from: quic.Remote) -> int {
	header: quic.Packet_Header
	error: errors.Error_Record
	if !quic.header_read(data, 0, quic.CONNECTION_ID_SIZE, &header, &error) {
		return -1
	}
	destination := quic.connection_identifier_bytes(&header.destination_connection_id)
	for &link, place in mesh_client.links {
		connection := &mesh_client.connections[place]
		if !link.in_use || connection.state == .Idle || connection.state == .Closed || link.address != from {
			continue
		}
		if string(destination) == string(connection.local_connection_id[:]) {
			return place
		}
	}
	return -1
}

// mesh_pairing_abandon ends the pairing of a pairing request that ended with
// no answer that confirms it: a break, a bound, a reset, a refusal, a
// malformed answer, or a confirmation that could not leave. The pairing
// fails, which erases its secrets; the code was spent when its exchange
// started. A confirmation that did not come back removes the row of the
// offerer that the reply of its element wrote.
@(private = "file")
mesh_pairing_abandon :: proc "contextless" (link: ^Mesh_Client_Link, kind: machine_wire.Mesh_Request_Kind, row_written: bool) {
	switch kind {
	case .Pairing_Element, .Pairing_Confirm:
	case .None, .Object_Request, .Store_Offer, .Role_Call:
		return
	}
	machine_mesh.pairing_fail(&mesh.pairing, .Refused_Exchange)
	if kind == .Pairing_Confirm || row_written {
		machine_wire.pairing_confirmed_accept(&mesh, link.session.pinned_identity, nil)
	}
}

@(private = "file")
mesh_request_end :: proc "contextless" (link: ^Mesh_Client_Link, identifier: u64, outcome: call_outcome.Call_Outcome) {
	for &item in link.requests {
		if item.phase != .Free && item.phase != .Ended && item.identifier == identifier {
			item.outcome = outcome
			item.phase = .Ended
			mesh_pairing_abandon(link, item.kind, false)
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
		item.outcome = .Answer_Unreadable
		mesh_pairing_abandon(link, item.kind, false)
		return
	}
	item.outcome = outcome
	item.reason = reason
	item.detail = detail
	item.phase = .Ended
	if outcome != .Succeeded {
		mesh_pairing_abandon(link, item.kind, false)
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
			item.outcome = .Answer_Unreadable
			return
		}
		if reply.outcome != .Succeeded {
			item.outcome = reply.outcome
			if call_outcome.effect_group_of(reply.outcome) == .Nothing_Changed {
				item.reason = .Role_Refused
			}
		}
		item.role_value = reply.value
		item.role_result_size = len(reply.result)
	case .Pairing_Element:
		confirm, status := machine_wire.pairing_element_reply_accept(&mesh, answer, system.time(), mesh_frame_buffer[:])
		confirm_sent := false
		if confirm != nil {
			// The confirm goes also when the tag of the offerer failed, so
			// the code ends on both machines.
			error: errors.Error_Record
			request, _, _ := mesh_client_begin(link.session.pinned_identity, confirm, &error)
			confirm_sent = request != nil
		}
		if status != .Ok || !confirm_sent {
			item.outcome = machine_wire.mesh_refusal_outcome(.Pairing_Refused)
			item.reason = .Pairing_Refused
			item.detail = u32(status)
			// The reply wrote the row of the offerer when its tag held: with
			// no confirmation on its way, that row leaves.
			if !confirm_sent {
				mesh_pairing_abandon(link, .Pairing_Element, true)
			}
		}
	case .Pairing_Confirm:
		if _, _, ok := machine_wire.pairing_confirmed_accept(&mesh, link.session.pinned_identity, answer); !ok {
			// pairing_confirmed_accept removed the row; the pairing fails too.
			item.outcome = machine_wire.mesh_refusal_outcome(.Pairing_Refused)
			item.reason = .Pairing_Refused
			mesh_pairing_abandon(link, .Pairing_Confirm, false)
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
		// A paired link whose machine is no longer paired (a newer machine
		// list, a revocation) ends at once, as an inbound connection does.
		if link.session.purpose == .Paired && (link.session.state == .Connecting || link.session.state == .Up) {
			if _, paired := machine_mesh.paired_machine_find(&mesh.paired, link.session.pinned_identity); !paired && connection.state != .Closing && connection.state != .Draining && connection.state != .Closed {
				quic.connection_close(connection, u64(remote.Stream_Error.Revoked), now_us)
			}
		}
		if link.session.state == .Connecting && connection.state == .Connected {
			// The key that the handshake read from the Certificate and proved
			// by its signature, not the key that this side pinned.
			if machine_wire.mesh_link_established(&link.session, connection.tls.server_public_key) != .Ok {
				quic.connection_close(connection, u64(remote.Stream_Error.Revoked), now_us)
			} else if !link.logged {
				link.logged = true
				system.log_fact(.Info, Mesh_Link_Up{client_key_head = key_head_field(link.session.pinned_identity), peer = peer_field(link.address)})
			}
		}
		connection_ended := connection.state == .Closing || connection.state == .Draining || connection.state == .Closed
		if connection_ended && (link.session.state == .Connecting || link.session.state == .Up) {
			ended, count := machine_wire.mesh_link_broken(&link.session)
			in_doubt, unreachable: u64
			for end in ended[:count] {
				mesh_request_end(&link, end.identifier, end.outcome)
				if call_outcome.effect_group_of(end.outcome) == .Change_In_Doubt {
					in_doubt += 1
				} else {
					unreachable += 1
				}
			}
			system.log_fact(.Info, Mesh_Link_Ended{in_doubt = in_doubt, unreachable = unreachable, client_key_head = key_head_field(link.session.pinned_identity), peer = peer_field(link.address)})
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
					if !reset && !finished && item.received >= len(item.answer) {
						// A frame of exactly FRAME_LIMIT bytes fills the place:
						// one more byte, not a full place, means too large.
						probe: [1]u8
						extra: int
						extra, finished, reset = quic.stream_read(connection, item.stream, probe[:])
						if extra > 0 {
							quic.stream_reset(connection, item.stream, u64(remote.Stream_Error.Too_Large))
							machine_wire.mesh_answer_accept(&link.session, item.identifier, nil)
							item.phase = .Ended
							item.outcome = .Answer_Unreadable
							mesh_pairing_abandon(&link, item.kind, false)
							continue
						}
					}
					if reset {
						// The other machine reset the stream after the request
						// left: it can have run.
						machine_wire.mesh_answer_accept(&link.session, item.identifier, nil)
						item.phase = .Ended
						item.outcome = .Connection_Ended_During_The_Call
						mesh_pairing_abandon(&link, item.kind, false)
					} else if finished {
						mesh_answer_take(&link, &item)
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
