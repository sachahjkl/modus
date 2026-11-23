// The outbound side of the mesh: the session that a machine keeps for one
// link to a paired machine, and the requests that it sends on that link
// (src/md/features/several_machines.md, "The outbound link").
//
// A link pins one identity key before it connects. The transport proves a
// key in its handshake, and the link refuses each other key: the frames of a
// link reach only the machine whose key the principal paired. Each request
// is one frame on a new stream, with a bound. Its end is one of four:
//
// - Answered: the answer message of the request came.
// - Refused: the other machine said that the request did not run.
// - Unknown_Outcome: the request left, and no valid answer came before the
//   link broke or the bound passed. The request can have run.
// - Unreachable: the link was not up, so the request never left.
//
// The session holds no transport. remote drives it from its QUIC loop
// (mesh_link_open, mesh_link_established, mesh_request_begin,
// mesh_answer_accept, mesh_link_broken, mesh_link_expire). A caller whose
// transport answers at once, such as a host test or a scheduler, uses
// mesh_connect and mesh_exchange over a Mesh_Transport.
package machine_wire

import "modus:contract/blake3"
import "modus:contract/enum_word"
import "modus:contract/machine_mesh"
import "modus:contract/object_cache"
import "modus:contract/role_contract"

// The requests that one link has in flight at most.
MESH_REQUESTS_AT_ONCE :: 4

// The state of one link, as this machine sees it.
Mesh_Link_State :: enum u8 {
	Idle       = 0, // No connection, and none asked.
	Connecting = 1, // The handshake runs: no request has left yet.
	Up         = 2, // The handshake proved the pinned key: requests leave.
	Broken     = 3, // The connection ended: each new request is Unreachable until the link opens again.
}

// What a link is for. A link to a paired machine carries no pairing frame;
// a link of a pairing carries only the two pairing frames.
Mesh_Link_Purpose :: enum u8 {
	None    = 0,
	Paired  = 1, // The other machine is a row of the paired machines.
	Pairing = 2, // This machine joins the offer of the other machine with a code.
}

// The requests that this machine sends. Each is one request message.
Mesh_Request_Kind :: enum u8 {
	None            = 0,
	Pairing_Element = 1,
	Pairing_Confirm = 2,
	Object_Request  = 3,
	Store_Offer     = 4,
	Role_Call       = 5,
}

// The end of one request.
Mesh_Outcome :: enum u8 {
	None            = 0,
	Answered        = 1, // The answer message came.
	Refused         = 2, // The other machine refused it before it ran.
	Unknown_Outcome = 3, // It left, and no valid answer came: it can have run.
	Unreachable     = 4, // The link was not up: it never left.
}

// The refusals of the session. A refusal changes nothing, except
// Refused_Identity_Mismatch, which breaks the link.
Mesh_Client_Status :: enum u8 {
	Ok                        = 1,
	Refused_Zero_Key          = 2, // The pinned key is zero.
	Refused_Same_Machine      = 3, // The pinned key is the key of this machine.
	Refused_Not_Paired        = 4, // A link of purpose Paired to a key that no row holds.
	Refused_No_Pairing        = 5, // A link of purpose Pairing, and this machine joins no offer.
	Refused_Identity_Mismatch = 6, // The handshake proved another key than the pinned key.
	Refused_Bad_Phase         = 7, // The state of the link does not allow the step.
	Refused_Bad_Bound         = 8, // A bound of 0, or a deadline past the largest time.
	Refused_Bad_Request       = 9, // The frame is malformed, is no request, or does not fit the purpose of the link.
	Refused_Full              = 10, // MESH_REQUESTS_AT_ONCE requests are in flight.
	Unreachable               = 11, // The link is not up: the request never left.
	Refused_Bad_Purpose       = 12, // The purpose None.
	Refused_Code_Expired      = 13, // A link of purpose Pairing, and the code of the pairing ended, or the clock is before its start.
}

// One request in flight.
Mesh_Pending :: struct {
	identifier:  u64, // 0: a free place.
	kind:        Mesh_Request_Kind,
	deadline_ms: u64,
}

// The end of a request that the session decided with no answer.
Mesh_Request_End :: struct {
	identifier: u64,
	outcome:    Mesh_Outcome,
}

// The session of one link.
Mesh_Link :: struct {
	state:               Mesh_Link_State,
	purpose:             Mesh_Link_Purpose,
	own_identity:        [machine_mesh.PUBLIC_KEY_SIZE]u8,
	pinned_identity:     [machine_mesh.PUBLIC_KEY_SIZE]u8,
	connect_deadline_ms: u64,
	next_identifier:     u64,
	pending:             [MESH_REQUESTS_AT_ONCE]Mesh_Pending,
}

// mesh_request_kind_of_message is the border between a request message and
// a kind of this side. A message that this side never sends gives ok false.
mesh_request_kind_of_message :: proc "contextless" (message: Message) -> (kind: Mesh_Request_Kind, ok: bool) {
	switch message {
	case .Pairing_Element:
		return .Pairing_Element, true
	case .Pairing_Confirm:
		return .Pairing_Confirm, true
	case .Object_Request:
		return .Object_Request, true
	case .Store_Offer:
		return .Store_Offer, true
	case .Role_Call:
		return .Role_Call, true
	case .None, .Refusal, .Pairing_Element_Reply, .Pairing_Confirmed, .Object_Response, .Grant_Present, .Grant_Accepted, .Store_Offer_Reply, .Role_Reply, .Relay_Deposit, .Relay_Deposited, .Relay_Collect, .Relay_Delivery:
	}
	return .None, false
}

// mesh_answer_message_of gives the answer message of each kind of request.
mesh_answer_message_of :: proc "contextless" (kind: Mesh_Request_Kind) -> Message {
	switch kind {
	case .Pairing_Element:
		return .Pairing_Element_Reply
	case .Pairing_Confirm:
		return .Pairing_Confirmed
	case .Object_Request:
		return .Object_Response
	case .Store_Offer:
		return .Store_Offer_Reply
	case .Role_Call:
		return .Role_Reply
	case .None:
	}
	return .None
}

// mesh_link_open pins the identity key of the other machine and starts the
// handshake. A link of purpose Paired needs a row of the paired machines; a
// link of purpose Pairing needs a pairing of this machine as the joiner. A
// broken link opens again; a link that connects or is up is refused.
mesh_link_open :: proc "contextless" (
	link: ^Mesh_Link,
	peer: ^Peer,
	pinned_identity: [machine_mesh.PUBLIC_KEY_SIZE]u8,
	purpose: Mesh_Link_Purpose,
	now_ms: u64,
	bound_ms: u64,
) -> Mesh_Client_Status {
	if link == nil || peer == nil || !peer.has_identity {
		return .Refused_Bad_Phase
	}
	if link.state == .Connecting || link.state == .Up {
		return .Refused_Bad_Phase
	}
	if machine_mesh.key_is_zero(pinned_identity) {
		return .Refused_Zero_Key
	}
	if machine_mesh.keys_equal_constant_time(pinned_identity, peer.identity.public_key) {
		return .Refused_Same_Machine
	}
	if bound_ms == 0 || bound_ms > max(u64) - now_ms {
		return .Refused_Bad_Bound
	}
	switch purpose {
	case .None:
		return .Refused_Bad_Purpose
	case .Paired:
		if !peer_is_paired(peer, pinned_identity) {
			return .Refused_Not_Paired
		}
	case .Pairing:
		if peer.pairing.side != .Joiner || peer.pairing.phase != .Code_Ready {
			return .Refused_No_Pairing
		}
		// The same rule as peer_admits on the offerer: an ended code opens
		// no link.
		if machine_mesh.pairing_code_expired(peer.pairing.code_started_at_ms, now_ms) {
			return .Refused_Code_Expired
		}
	}
	link^ = Mesh_Link {
		state               = .Connecting,
		purpose             = purpose,
		own_identity        = peer.identity.public_key,
		pinned_identity     = pinned_identity,
		connect_deadline_ms = now_ms + bound_ms,
		next_identifier     = link.next_identifier,
	}
	return .Ok
}

// mesh_link_established takes the key that the handshake proved. A key that
// is not the pinned key breaks the link: no frame goes to that machine.
mesh_link_established :: proc "contextless" (link: ^Mesh_Link, proved_identity: [machine_mesh.PUBLIC_KEY_SIZE]u8) -> Mesh_Client_Status {
	if link == nil || link.state != .Connecting {
		return .Refused_Bad_Phase
	}
	if machine_mesh.key_is_zero(proved_identity) || !machine_mesh.keys_equal_constant_time(proved_identity, link.pinned_identity) {
		mesh_link_broken(link)
		return .Refused_Identity_Mismatch
	}
	link.state = .Up
	return .Ok
}

// mesh_link_channel_binding is the binding of the pairing on this link: the
// other machine is the server, this machine the client.
mesh_link_channel_binding :: proc "contextless" (link: ^Mesh_Link) -> [machine_mesh.PAIRING_CHANNEL_BINDING_SIZE]u8 {
	return channel_binding_of_identities(link.pinned_identity, link.own_identity)
}

@(private)
mesh_pending_find :: proc "contextless" (link: ^Mesh_Link, identifier: u64) -> ^Mesh_Pending {
	if identifier == 0 {
		return nil
	}
	for &item in link.pending {
		if item.identifier == identifier {
			return &item
		}
	}
	return nil
}

@(private)
mesh_pending_drop :: proc "contextless" (link: ^Mesh_Link, identifier: u64) {
	if pending := mesh_pending_find(link, identifier); pending != nil {
		pending^ = {}
	}
}

// mesh_request_begin keeps one request frame in flight with its bound. The
// caller sends the frame on a new stream. A link that is not up gives
// Unreachable: the request never leaves. The kind of the frame must fit the
// purpose of the link.
mesh_request_begin :: proc "contextless" (link: ^Mesh_Link, request: []u8, now_ms: u64, bound_ms: u64) -> (identifier: u64, status: Mesh_Client_Status) {
	if link == nil {
		return 0, .Refused_Bad_Phase
	}
	frame, frame_status := frame_decode(request)
	if frame_status != .Ok {
		return 0, .Refused_Bad_Request
	}
	kind, is_request := mesh_request_kind_of_message(frame.message)
	if !is_request {
		return 0, .Refused_Bad_Request
	}
	pairing_kind := kind == .Pairing_Element || kind == .Pairing_Confirm
	switch link.purpose {
	case .None:
		return 0, .Refused_Bad_Phase
	case .Paired:
		if pairing_kind {
			return 0, .Refused_Bad_Request
		}
	case .Pairing:
		if !pairing_kind {
			return 0, .Refused_Bad_Request
		}
	}
	if bound_ms == 0 || bound_ms > max(u64) - now_ms {
		return 0, .Refused_Bad_Bound
	}
	switch link.state {
	case .Up:
	case .Idle, .Connecting, .Broken:
		return 0, .Unreachable
	}
	for &item in link.pending {
		if item.identifier != 0 {
			continue
		}
		link.next_identifier += 1
		if link.next_identifier == 0 {
			link.next_identifier = 1
		}
		item = Mesh_Pending{identifier = link.next_identifier, kind = kind, deadline_ms = now_ms + bound_ms}
		return item.identifier, .Ok
	}
	return 0, .Refused_Full
}

// mesh_answer_accept takes the bytes of the stream of a request. A Refusal
// whose reason says that the request did not run is Refused. Each other
// answer that is not the answer message (a malformed frame, a malformed
// refusal, another message, a fault of a holder that ran) is
// Unknown_Outcome: the request can have run. found is false for a request
// that is not in flight; it then changes nothing.
mesh_answer_accept :: proc "contextless" (link: ^Mesh_Link, identifier: u64, answer: []u8) -> (body: []u8, outcome: Mesh_Outcome, reason: Refusal_Reason, detail: u32, found: bool) {
	if link == nil {
		return nil, .None, .None, 0, false
	}
	pending := mesh_pending_find(link, identifier)
	if pending == nil {
		return nil, .None, .None, 0, false
	}
	expected := mesh_answer_message_of(pending.kind)
	pending^ = {}
	frame, frame_status := frame_decode(answer)
	if frame_status != .Ok {
		return nil, .Unknown_Outcome, .Malformed, u32(frame_status), true
	}
	if frame.message == expected {
		return frame.body, .Answered, .None, 0, true
	}
	if frame.message != .Refusal {
		return nil, .Unknown_Outcome, .Unexpected_Message, u32(frame.message), true
	}
	refusal_reason, refusal_detail, read_ok := refusal_read(frame.body)
	if !read_ok {
		return nil, .Unknown_Outcome, .Malformed, 0, true
	}
	switch refusal_reason {
	case .Role_Holder_Fault:
		return nil, .Unknown_Outcome, refusal_reason, refusal_detail, true
	case .Malformed, .Unexpected_Message, .Not_Paired, .Pairing_Refused, .Object_Absent, .Grant_Refused, .Store_Refused, .Role_Refused, .Relay_Refused, .No_Identity, .Use_Not_Granted, .No_Principal:
		return nil, .Refused, refusal_reason, refusal_detail, true
	case .None:
	}
	return nil, .Unknown_Outcome, .Malformed, 0, true
}

// mesh_link_broken is the end of the connection. Each request in flight
// ends: Unknown_Outcome when the link was up, since it can have run;
// Unreachable when the handshake never proved the key, since nothing left.
mesh_link_broken :: proc "contextless" (link: ^Mesh_Link) -> (ended: [MESH_REQUESTS_AT_ONCE]Mesh_Request_End, count: int) {
	if link == nil {
		return
	}
	outcome := link.state == .Up ? Mesh_Outcome.Unknown_Outcome : Mesh_Outcome.Unreachable
	for &item in link.pending {
		if item.identifier == 0 {
			continue
		}
		ended[count] = Mesh_Request_End{identifier = item.identifier, outcome = outcome}
		count += 1
		item = {}
	}
	link.state = .Broken
	return ended, count
}

// mesh_link_expire ends each request past its bound with Unknown_Outcome,
// and breaks a link whose handshake passed its bound.
mesh_link_expire :: proc "contextless" (link: ^Mesh_Link, now_ms: u64) -> (ended: [MESH_REQUESTS_AT_ONCE]Mesh_Request_End, count: int) {
	if link == nil {
		return
	}
	if link.state == .Connecting && now_ms >= link.connect_deadline_ms {
		return mesh_link_broken(link)
	}
	for &item in link.pending {
		if item.identifier == 0 || now_ms < item.deadline_ms {
			continue
		}
		ended[count] = Mesh_Request_End{identifier = item.identifier, outcome = .Unknown_Outcome}
		count += 1
		item = {}
	}
	return ended, count
}

// mesh_link_in_flight counts the requests in flight.
mesh_link_in_flight :: proc "contextless" (link: ^Mesh_Link) -> int {
	count := 0
	for item in link.pending {
		if item.identifier != 0 {
			count += 1
		}
	}
	return count
}

// ---- A transport that answers at once ----

// What happened to one request on a transport that answers at once.
Mesh_Delivery :: enum u8 {
	None          = 0,
	Answered      = 1, // The stream carried the answer.
	Link_Broken   = 2, // The request left, and the connection ended before the answer.
	Timed_Out     = 3, // The request left, and the bound passed before the answer.
	Not_Connected = 4, // The connection was down: the request never left.
}

// The handshake of a transport: it connects to the machine of the pinned
// key and gives the key that the handshake proved.
Mesh_Connect_Proc :: #type proc "contextless" (pinned_identity: [machine_mesh.PUBLIC_KEY_SIZE]u8, bound_ms: u64, user_data: rawptr) -> (proved_identity: [machine_mesh.PUBLIC_KEY_SIZE]u8, connected: bool)

// One stream of a transport: the request goes, and the answer comes into
// answer_buffer within bound_ms.
Mesh_Round_Trip_Proc :: #type proc "contextless" (pinned_identity: [machine_mesh.PUBLIC_KEY_SIZE]u8, request: []u8, answer_buffer: []u8, bound_ms: u64, user_data: rawptr) -> (answer_count: int, delivery: Mesh_Delivery)

Mesh_Transport :: struct {
	connect:    Mesh_Connect_Proc,
	round_trip: Mesh_Round_Trip_Proc,
	user_data:  rawptr,
}

// The end of one exchange on a transport that answers at once.
Mesh_Exchange :: struct {
	outcome: Mesh_Outcome,
	status:  Mesh_Client_Status, // Ok, or the refusal of the session before the request left.
	reason:  Refusal_Reason, // The reason of a Refusal, or of an Unknown_Outcome.
	detail:  u32,
	body:    []u8, // The body of the answer message: a view of the answer buffer.
	answer:  []u8, // The whole answer frame.
}

// mesh_connect opens the link and runs the handshake of the transport. The
// link is up only when the proved key is the pinned key.
mesh_connect :: proc "contextless" (
	link: ^Mesh_Link,
	peer: ^Peer,
	transport: ^Mesh_Transport,
	pinned_identity: [machine_mesh.PUBLIC_KEY_SIZE]u8,
	purpose: Mesh_Link_Purpose,
	now_ms: u64,
	bound_ms: u64,
) -> Mesh_Client_Status {
	if transport == nil || transport.connect == nil || transport.round_trip == nil {
		return .Refused_Bad_Phase
	}
	status := mesh_link_open(link, peer, pinned_identity, purpose, now_ms, bound_ms)
	if status != .Ok {
		return status
	}
	proved, connected := transport.connect(pinned_identity, bound_ms, transport.user_data)
	if !connected {
		mesh_link_broken(link)
		return .Unreachable
	}
	return mesh_link_established(link, proved)
}

// mesh_exchange sends one request frame and takes its answer. A request
// that never left is Unreachable; a request that left and lost its answer
// is Unknown_Outcome, and a broken connection ends the other requests of
// the link as mesh_link_broken does.
mesh_exchange :: proc "contextless" (link: ^Mesh_Link, transport: ^Mesh_Transport, request: []u8, now_ms: u64, bound_ms: u64, answer_buffer: []u8) -> (result: Mesh_Exchange) {
	if transport == nil || transport.round_trip == nil {
		return Mesh_Exchange{outcome = .None, status = .Refused_Bad_Phase}
	}
	identifier, status := mesh_request_begin(link, request, now_ms, bound_ms)
	if status == .Unreachable {
		return Mesh_Exchange{outcome = .Unreachable, status = .Unreachable}
	}
	if status != .Ok {
		return Mesh_Exchange{outcome = .None, status = status}
	}
	count, delivery := transport.round_trip(link.pinned_identity, request, answer_buffer, bound_ms, transport.user_data)
	switch delivery {
	case .Answered:
		if count < 0 || count > len(answer_buffer) {
			mesh_pending_drop(link, identifier)
			return Mesh_Exchange{outcome = .Unknown_Outcome, status = .Ok, reason = .Malformed}
		}
		answer := answer_buffer[:count]
		body, outcome, reason, detail, _ := mesh_answer_accept(link, identifier, answer)
		return Mesh_Exchange{outcome = outcome, status = .Ok, reason = reason, detail = detail, body = body, answer = answer}
	case .Timed_Out:
		mesh_pending_drop(link, identifier)
		return Mesh_Exchange{outcome = .Unknown_Outcome, status = .Ok}
	case .Not_Connected:
		// Nothing left: this request is Unreachable, and the others of the
		// link, which left while it was up, end as the break says.
		mesh_pending_drop(link, identifier)
		mesh_link_broken(link)
		return Mesh_Exchange{outcome = .Unreachable, status = .Unreachable}
	case .Link_Broken, .None:
	}
	mesh_link_broken(link)
	return Mesh_Exchange{outcome = .Unknown_Outcome, status = .Ok}
}

// ---- The requests ----

// The end of one fetch of an object by its hash.
Mesh_Object_Fetch :: struct {
	exchange: Mesh_Exchange,
	fetch:    Object_Fetch_Status, // Stored or Already_Stored: the bytes hash to the requested hash and are kept.
}

// mesh_fetch_object asks the other machine for an object by its kind and
// hash. The bytes are kept in the objects of peer only when they hash to the
// requested hash: object_response_accept computes the hash again.
mesh_fetch_object :: proc "contextless" (
	peer: ^Peer,
	link: ^Mesh_Link,
	transport: ^Mesh_Transport,
	kind: object_cache.Cache_Object_Kind,
	hash: blake3.Hash,
	now_ms: u64,
	bound_ms: u64,
	request_buffer: []u8,
	answer_buffer: []u8,
) -> (result: Mesh_Object_Fetch) {
	// One request for each piece: an object of any size crosses in pieces
	// of OBJECT_CHUNK_BYTES, and each answer gives the offset of the next.
	offset: u64 = 0
	for {
		request := object_request_write(request_buffer, kind, hash, offset)
		if request == nil {
			result.exchange.status = .Refused_Bad_Request
			return result
		}
		result.exchange = mesh_exchange(link, transport, request, now_ms, bound_ms, answer_buffer)
		switch result.exchange.outcome {
		case .Answered:
			next: u64
			result.fetch, _, next = object_response_accept(peer, kind, hash, result.exchange.answer, offset)
			if result.fetch == .Partial {
				offset = next
				continue
			}
		case .Refused:
			result.fetch = .Refused
		case .None, .Unknown_Outcome, .Unreachable:
		}
		return result
	}
}

// The end of one role call on a link.
Mesh_Role_Call :: struct {
	exchange: Mesh_Exchange,
	reply:    Role_Reply, // When the outcome is Answered: the value and the result bytes of the holder.
}

// mesh_call_role sends one call of a role contract held on the other
// machine. The call identifier is the identifier of the request in flight,
// and the reply must name it: a reply of another call (a reply that came
// late or out of order), or a malformed reply, is Unknown_Outcome. A holder
// that refused gives the outcome Refused.
mesh_call_role :: proc "contextless" (
	link: ^Mesh_Link,
	transport: ^Mesh_Transport,
	role: role_contract.Role,
	export: u32,
	flags: Role_Call_Flags,
	arguments: []u8,
	now_ms: u64,
	bound_ms: u64,
	request_buffer: []u8,
	answer_buffer: []u8,
) -> (result: Mesh_Role_Call) {
	if link == nil {
		result.exchange.status = .Refused_Bad_Phase
		return result
	}
	// The call identifier is the identifier that the session gives this
	// request next, so a reply names the request of this link and no other.
	identifier := link.next_identifier + 1
	if identifier == 0 {
		identifier = 1
	}
	request := role_call_write(request_buffer, Role_Call{identifier = identifier, role = role, export = export, flags = flags, arguments = arguments})
	if request == nil {
		result.exchange.status = .Refused_Bad_Request
		return result
	}
	result.exchange = mesh_exchange(link, transport, request, now_ms, bound_ms, answer_buffer)
	if result.exchange.outcome != .Answered {
		return result
	}
	reply, read_ok := role_reply_read(result.exchange.body)
	if !read_ok || reply.identifier != identifier {
		result.exchange.outcome = .Unknown_Outcome
		result.exchange.reason = .Malformed
		return result
	}
	if reply.outcome == .Refused {
		result.exchange.outcome = .Refused
		result.exchange.reason = .Role_Refused
	}
	result.reply = reply
	return result
}

// The end of one store exchange on a link.
Mesh_Store_Sync :: struct {
	exchange: Mesh_Exchange,
	// When the outcome is Answered or Refused: Ok when both machines merged
	// to one common version, else the refusal. With no answer the offer stays
	// in flight, and the next exchange sends the same snapshot.
	store:    Store_Status,
}

// mesh_sync_store offers the version of an exchanged store to its partner,
// page by page, and merges the reply, which comes page by page. A lost
// answer keeps the offer in flight: the next call sends the same snapshot
// from its first page, which the partner answers again.
mesh_sync_store :: proc "contextless" (
	peer: ^Peer,
	link: ^Mesh_Link,
	transport: ^Mesh_Transport,
	store_identifier: blake3.Hash,
	now_ms: u64,
	bound_ms: u64,
	request_buffer: []u8,
	answer_buffer: []u8,
) -> (result: Mesh_Store_Sync) {
	store := store_exchange_find(peer.stores, store_identifier)
	if store == nil {
		result.store = .Refused_Unknown_Store
		result.exchange.status = .Refused_Bad_Request
		return result
	}
	if link == nil || !machine_mesh.keys_equal_constant_time(store.partner_identity, link.pinned_identity) {
		result.store = .Refused_Not_Partner
		result.exchange.status = .Refused_Bad_Request
		return result
	}
	request := store_offer_begin(store, request_buffer)
	for {
		if request == nil {
			result.store = .Refused_Full
			result.exchange.status = .Refused_Bad_Request
			return result
		}
		result.exchange = mesh_exchange(link, transport, request, now_ms, bound_ms, answer_buffer)
		switch result.exchange.outcome {
		case .Answered:
			more: bool
			result.store, _, _, more = store_offer_reply_accept(store, result.exchange.answer)
			if result.store == .Ok && more {
				request = store_offer_next(store, request_buffer)
				continue
			}
		case .Refused:
			result.store = .Refused_Nil_Input
			if result.exchange.reason == .Store_Refused {
				if status, known := enum_word.member_of_word(Store_Status, u64(result.exchange.detail)); known {
					result.store = status
				}
			}
		case .None, .Unknown_Outcome, .Unreachable:
		}
		return result
	}
}

// The end of a pairing that this machine joins.
Mesh_Pairing_Join :: struct {
	exchange: Mesh_Exchange, // The exchange that ended the pairing.
	pairing:  machine_mesh.Pairing_Status,
}

// mesh_pair_join runs the two pairing frames of the joiner on a link of
// purpose Pairing. A link that breaks fails the pairing, which erases its
// secrets: the code is spent on this machine.
mesh_pair_join :: proc "contextless" (peer: ^Peer, link: ^Mesh_Link, transport: ^Mesh_Transport, now_ms: u64, bound_ms: u64, request_buffer: []u8, answer_buffer: []u8) -> (result: Mesh_Pairing_Join) {
	if peer == nil || link == nil || link.purpose != .Pairing || link.state != .Up {
		result.exchange.status = .Refused_Bad_Phase
		result.pairing = .Refused_Bad_Phase
		return result
	}
	element, element_status := pairing_element_write(peer, link.pinned_identity, mesh_link_channel_binding(link), now_ms, request_buffer)
	if element_status != .Ok {
		result.pairing = element_status
		return result
	}
	result.exchange = mesh_exchange(link, transport, element, now_ms, bound_ms, answer_buffer)
	if result.exchange.outcome != .Answered {
		result.pairing = machine_mesh.pairing_fail(&peer.pairing, .Refused_Exchange)
		return result
	}
	confirm, confirm_status := pairing_element_reply_accept(peer, result.exchange.answer, now_ms, request_buffer)
	if confirm == nil {
		result.pairing = confirm_status
		return result
	}
	// The confirm goes also when the tag of the offerer failed, so the
	// code ends on both machines.
	result.exchange = mesh_exchange(link, transport, confirm, now_ms, bound_ms, answer_buffer)
	if confirm_status != .Ok {
		result.pairing = confirm_status
		return result
	}
	if result.exchange.outcome != .Answered {
		// The offerer can have written its row; this side did not see it
		// confirmed, so it keeps no row.
		pairing_confirmed_accept(peer, link.pinned_identity, nil)
		result.pairing = .Refused_Confirmation_Failed
		return result
	}
	if _, _, ok := pairing_confirmed_accept(peer, link.pinned_identity, result.exchange.answer); !ok {
		result.pairing = .Refused_Confirmation_Failed
		return result
	}
	result.pairing = .Ok
	return result
}
