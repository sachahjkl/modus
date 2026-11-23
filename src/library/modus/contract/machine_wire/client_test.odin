#+build !freestanding
package machine_wire

import "base:runtime"
import "core:crypto/ed25519"
import "core:testing"
import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/call_outcome"
import "modus:contract/machine_mesh"
import "modus:contract/machine_sync"
import "modus:contract/role_contract"

// ---- Helpers of the outbound side ----

@(private = "file")
client_key_pair :: proc(seed_byte: u8) -> (private_key: ed25519.Private_Key, public_key: [32]u8) {
	seed: [ed25519.PRIVATE_KEY_SIZE]u8
	for index in 0 ..< len(seed) {
		seed[index] = seed_byte + u8(index * 11 + 3)
	}
	ok := ed25519.private_key_set_bytes(&private_key, seed[:])
	assert(ok)
	ed25519.private_key_public_bytes(&private_key, public_key[:])
	return private_key, public_key
}

@(private = "file")
client_verify :: proc "contextless" (public_key: [32]u8, message: []u8, signature: [64]u8, _: rawptr) -> bool {
	context = runtime.default_context()
	key, signature_copy := public_key, signature
	parsed: ed25519.Public_Key
	if !ed25519.public_key_set_bytes(&parsed, key[:]) {
		return false
	}
	return ed25519.verify(&parsed, message, signature_copy[:])
}

@(private = "file")
Client_Machine :: struct {
	peer:    Peer,
	seed:    u8,
	counter: u64,
}

@(private = "file")
client_random :: proc "contextless" (bytes: []u8, user_data: rawptr) -> bool {
	machine := (^Client_Machine)(user_data)
	machine.counter += 1
	input: [9]u8
	input[0] = machine.seed
	byte_order.write_u64_little_endian(input[:], 1, machine.counter)
	derived := blake3.derive_key("modus machine wire client test random", input[:])
	for index in 0 ..< len(bytes) {
		bytes[index] = derived[index % 32]
	}
	return true
}

// Export 1 answers the reversed arguments, export 2 refuses, export 3
// breaks the contract with an outcome of a link.
@(private = "file")
client_role_holder :: proc "contextless" (role: role_contract.Role, export: u32, arguments: []u8, result: []u8, _: rawptr) -> (value: i64, result_count: int, outcome: Role_Outcome) {
	switch export {
	case 1:
		for index in 0 ..< len(arguments) {
			result[index] = arguments[len(arguments) - 1 - index]
		}
		return i64(len(arguments)), len(arguments), .Answered
	case 2:
		return -1, 0, .Refused
	}
	return 0, 0, .Unknown_Outcome
}

@(private = "file")
client_machine_make :: proc(seed: u8) -> ^Client_Machine {
	machine := new(Client_Machine)
	machine.seed = seed
	_, public_key := client_key_pair(seed)
	ok := peer_init(&machine.peer, public_key, Peer_Services{signature_verify = client_verify, fill_random = client_random, role_holder = client_role_holder, user_data = machine})
	assert(ok)
	return machine
}

@(private = "file")
client_identity :: proc(machine: ^Client_Machine) -> [32]u8 {
	return machine.peer.identity.public_key
}

// The network of the tests: each stream reaches the machine of the pinned
// key, and that machine sees the key of the client, as the handshake proves
// it. The faults: no connection, an answer lost after the request ran, a
// bound that passes, a changed bit of the answer, a hostile key.
@(private = "file")
Client_Network :: struct {
	client:          ^Client_Machine,
	machines:        [4]^Client_Machine,
	count:           int,
	now_ms:          u64,
	down:            bool,
	lose_answer:     bool,
	time_out:        bool,
	flip_last_bit:   bool,
	other_call:      bool, // A role reply comes back with the identifier of another call.
	proved_override: [32]u8,
	served:          int,
	output:          [FRAME_LIMIT]u8,
}

@(private = "file")
network_find :: proc "contextless" (network: ^Client_Network, identity: [32]u8) -> ^Client_Machine {
	for machine in network.machines[:network.count] {
		if machine.peer.identity.public_key == identity {
			return machine
		}
	}
	return nil
}

@(private = "file")
network_connect :: proc "contextless" (pinned: [32]u8, _: u64, user_data: rawptr) -> (proved: [32]u8, connected: bool) {
	network := (^Client_Network)(user_data)
	if network.down || network_find(network, pinned) == nil {
		return {}, false
	}
	if !machine_mesh.key_is_zero(network.proved_override) {
		return network.proved_override, true
	}
	return pinned, true
}

@(private = "file")
network_round_trip :: proc "contextless" (pinned: [32]u8, request: []u8, answer_buffer: []u8, _: u64, user_data: rawptr) -> (int, Mesh_Delivery) {
	network := (^Client_Network)(user_data)
	machine := network_find(network, pinned)
	if network.down || machine == nil {
		return 0, .Not_Connected
	}
	client := network.client.peer.identity.public_key
	serve_context := Serve_Context {
		peer_identity   = client,
		channel_binding = channel_binding_of_identities(pinned, client),
		now_ms          = network.now_ms,
	}
	answer := serve(&machine.peer, &serve_context, request, network.output[:])
	network.served += 1
	if network.lose_answer {
		return 0, .Link_Broken
	}
	if network.time_out {
		return 0, .Timed_Out
	}
	count := copy(answer_buffer, answer)
	if reply_frame, status := frame_decode(answer_buffer[:count]); network.other_call && status == .Ok && reply_frame.message == .Role_Reply {
		identifier := byte_order.read_u64_little_endian(reply_frame.body, 0)
		byte_order.write_u64_little_endian(reply_frame.body, 0, identifier + 1)
	}
	if network.flip_last_bit && count > 0 {
		answer_buffer[count - 1] ~= 1
	}
	return count, .Answered
}

@(private = "file")
network_transport :: proc(network: ^Client_Network) -> Mesh_Transport {
	return Mesh_Transport{connect = network_connect, round_trip = network_round_trip, user_data = network}
}

@(private = "file")
Client_Buffers :: struct {
	request: [FRAME_LIMIT]u8,
	answer:  [FRAME_LIMIT]u8,
}

// join_by_link pairs joiner with offerer through the outbound session of
// the joiner: a link of purpose Pairing and the two pairing frames.
@(private = "file")
join_by_link :: proc(t: ^testing.T, offerer, joiner: ^Client_Machine, network: ^Client_Network, buffers: ^Client_Buffers, location := #caller_location) -> bool {
	random_bytes := [8]u8{offerer.seed, joiner.seed, u8(network.now_ms), 4, 5, 6, 7, 8}
	code, offer_status := machine_mesh.pairing_offer(&offerer.peer.pairing, client_identity(offerer), random_bytes, network.now_ms)
	testing.expect_value(t, offer_status, machine_mesh.Pairing_Status.Ok, loc = location)
	offerer.peer.pairing_uses = {.Calls}
	joiner.peer.pairing_uses = {.Calls}
	testing.expect_value(t, machine_mesh.pairing_join(&joiner.peer.pairing, client_identity(joiner), code[:], network.now_ms), machine_mesh.Pairing_Status.Ok, loc = location)
	transport := network_transport(network)
	link: Mesh_Link
	testing.expect_value(t, mesh_connect(&link, &joiner.peer, &transport, client_identity(offerer), .Pairing, network.now_ms, 1_000), Mesh_Client_Status.Ok, loc = location)
	// A pairing link carries no other request.
	testing.expect_value(t, mesh_fetch_object(&joiner.peer, &link, &transport, .Blob, blake3.hash([]u8{1}), network.now_ms, 1_000, buffers.request[:], buffers.answer[:]).exchange.status, Mesh_Client_Status.Refused_Bad_Request, loc = location)
	joined := mesh_pair_join(&joiner.peer, &link, &transport, network.now_ms, 1_000, buffers.request[:], buffers.answer[:])
	testing.expect_value(t, joined.pairing, machine_mesh.Pairing_Status.Ok, loc = location)
	return joined.pairing == .Ok
}

// ---- The tests ----

@(test)
client_link_refuses_each_wrong_key_and_phase :: proc(t: ^testing.T) {
	laptop := client_machine_make(0x41)
	home := client_machine_make(0x51)
	stranger := client_machine_make(0x61)
	defer free(laptop)
	defer free(home)
	defer free(stranger)
	network := new(Client_Network)
	defer free(network)
	network^ = Client_Network{client = laptop, now_ms = 10_000}
	network.machines[0], network.machines[1] = home, stranger
	network.count = 2
	buffers := new(Client_Buffers)
	defer free(buffers)
	transport := network_transport(network)

	link: Mesh_Link
	testing.expect_value(t, mesh_link_open(&link, &laptop.peer, {}, .Paired, 10_000, 1_000), Mesh_Client_Status.Refused_Zero_Key)
	testing.expect_value(t, mesh_link_open(&link, &laptop.peer, client_identity(laptop), .Paired, 10_000, 1_000), Mesh_Client_Status.Refused_Same_Machine)
	testing.expect_value(t, mesh_link_open(&link, &laptop.peer, client_identity(home), .Paired, 10_000, 1_000), Mesh_Client_Status.Refused_Not_Paired)
	testing.expect_value(t, mesh_link_open(&link, &laptop.peer, client_identity(home), .Pairing, 10_000, 1_000), Mesh_Client_Status.Refused_No_Pairing)
	testing.expect_value(t, mesh_link_open(&link, &laptop.peer, client_identity(home), .None, 10_000, 1_000), Mesh_Client_Status.Refused_Bad_Purpose)
	testing.expect_value(t, link.state, Mesh_Link_State.Idle)

	// A request before any link never leaves.
	request := object_request_write(buffers.request[:], .Blob, blake3.hash([]u8{7}))
	_, begin_status := mesh_request_begin(&link, request, 10_000, 1_000)
	testing.expect_value(t, begin_status, Mesh_Client_Status.Refused_Bad_Phase)

	testing.expect(t, join_by_link(t, home, laptop, network, buffers))
	testing.expect(t, machine_grant_set(&home.peer, client_identity(laptop), {.Objects}, {}))

	// The bounds: 0, and one past the largest time.
	testing.expect_value(t, mesh_link_open(&link, &laptop.peer, client_identity(home), .Paired, 10_000, 0), Mesh_Client_Status.Refused_Bad_Bound)
	testing.expect_value(t, mesh_link_open(&link, &laptop.peer, client_identity(home), .Paired, 10_000, max(u64) - 10_000 + 1), Mesh_Client_Status.Refused_Bad_Bound)

	// The handshake proves another key than the pinned key: the link breaks,
	// and no frame reaches either machine.
	network.proved_override = client_identity(stranger)
	served := network.served
	testing.expect_value(t, mesh_connect(&link, &laptop.peer, &transport, client_identity(home), .Paired, 10_000, 1_000), Mesh_Client_Status.Refused_Identity_Mismatch)
	testing.expect_value(t, link.state, Mesh_Link_State.Broken)
	fetch := mesh_fetch_object(&laptop.peer, &link, &transport, .Blob, blake3.hash([]u8{7}), 10_000, 1_000, buffers.request[:], buffers.answer[:])
	testing.expect_value(t, fetch.exchange.outcome, call_outcome.Call_Outcome.Callee_Unavailable)
	testing.expect_value(t, network.served, served)

	// A zero proved key is refused too.
	network.proved_override = {}
	testing.expect_value(t, mesh_link_open(&link, &laptop.peer, client_identity(home), .Paired, 10_000, 1_000), Mesh_Client_Status.Ok)
	testing.expect_value(t, mesh_link_established(&link, {}), Mesh_Client_Status.Refused_Identity_Mismatch)
	// A link that is up cannot open again, and an established step needs
	// the handshake phase.
	testing.expect_value(t, mesh_connect(&link, &laptop.peer, &transport, client_identity(home), .Paired, 10_000, 1_000), Mesh_Client_Status.Ok)
	testing.expect_value(t, mesh_link_open(&link, &laptop.peer, client_identity(home), .Paired, 10_000, 1_000), Mesh_Client_Status.Refused_Bad_Phase)
	testing.expect_value(t, mesh_link_established(&link, client_identity(home)), Mesh_Client_Status.Refused_Bad_Phase)

	// A paired link carries no pairing frame, and no answer message.
	element: [FRAME_HEADER_SIZE + PAIRING_ELEMENT_SIZE]u8
	element_body, _ := frame_begin(element[:], .Pairing_Element, PAIRING_ELEMENT_SIZE)
	_, begin_status = mesh_request_begin(&link, frame_bytes(element[:], element_body), 10_000, 1_000)
	testing.expect_value(t, begin_status, Mesh_Client_Status.Refused_Bad_Request)
	response: [FRAME_HEADER_SIZE]u8
	response_body, _ := frame_begin(response[:], .Object_Response, 0)
	_, begin_status = mesh_request_begin(&link, frame_bytes(response[:], response_body), 10_000, 1_000)
	testing.expect_value(t, begin_status, Mesh_Client_Status.Refused_Bad_Request)
	_, begin_status = mesh_request_begin(&link, request[:FRAME_HEADER_SIZE - 1], 10_000, 1_000)
	testing.expect_value(t, begin_status, Mesh_Client_Status.Refused_Bad_Request)
	testing.expect_value(t, mesh_link_in_flight(&link), 0)

	// A machine that is not paired: no link opens to it.
	other: Mesh_Link
	testing.expect_value(t, mesh_link_open(&other, &laptop.peer, client_identity(stranger), .Paired, 10_000, 1_000), Mesh_Client_Status.Refused_Not_Paired)
}

@(test)
client_fetches_objects_and_keeps_only_bytes_of_the_hash :: proc(t: ^testing.T) {
	laptop := client_machine_make(0x42)
	home := client_machine_make(0x52)
	defer free(laptop)
	defer free(home)
	network := new(Client_Network)
	defer free(network)
	network^ = Client_Network{client = laptop, now_ms = 20_000}
	network.machines[0] = home
	network.count = 1
	buffers := new(Client_Buffers)
	defer free(buffers)
	transport := network_transport(network)
	testing.expect(t, join_by_link(t, home, laptop, network, buffers))
	// Both machines hold the row of the other.
	_, home_has := machine_mesh.paired_machine_find(&home.peer.paired, client_identity(laptop))
	_, laptop_has := machine_mesh.paired_machine_find(&laptop.peer.paired, client_identity(home))
	testing.expect(t, home_has && laptop_has)

	first := transmute([]u8)string("the first object")
	second := transmute([]u8)string("the second object")
	testing.expect_value(t, object_publish(&home.peer, .Blob, blake3.hash(first), first), machine_sync.Object_Store_Status.Stored)
	testing.expect_value(t, object_publish(&home.peer, .Blob, blake3.hash(second), second), machine_sync.Object_Store_Status.Stored)

	link: Mesh_Link
	testing.expect_value(t, mesh_connect(&link, &laptop.peer, &transport, client_identity(home), .Paired, 20_000, 1_000), Mesh_Client_Status.Ok)

	// No use granted: refused before any table is read.
	fetch := mesh_fetch_object(&laptop.peer, &link, &transport, .Blob, blake3.hash(first), 20_000, 1_000, buffers.request[:], buffers.answer[:])
	testing.expect_value(t, fetch.exchange.outcome, call_outcome.Call_Outcome.Grant_Or_Right_Missing)
	testing.expect_value(t, fetch.exchange.reason, Refusal_Reason.Use_Not_Granted)
	testing.expect_value(t, fetch.fetch, Object_Fetch_Status.Refused)

	testing.expect(t, machine_grant_set(&home.peer, client_identity(laptop), {.Objects}, {}))
	// One changed bit of the bytes in transit: nothing is kept.
	network.flip_last_bit = true
	fetch = mesh_fetch_object(&laptop.peer, &link, &transport, .Blob, blake3.hash(first), 20_000, 1_000, buffers.request[:], buffers.answer[:])
	testing.expect_value(t, fetch.exchange.outcome, call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, fetch.fetch, Object_Fetch_Status.Hash_Mismatch)
	testing.expect(t, object_lookup(&laptop.peer, blake3.hash(first)) == nil)
	network.flip_last_bit = false

	fetch = mesh_fetch_object(&laptop.peer, &link, &transport, .Blob, blake3.hash(first), 20_000, 1_000, buffers.request[:], buffers.answer[:])
	testing.expect_value(t, fetch.fetch, Object_Fetch_Status.Stored)
	testing.expect(t, string(object_lookup(&laptop.peer, blake3.hash(first))) == "the first object")

	// An object of another kind, and an object that the machine does not hold.
	fetch = mesh_fetch_object(&laptop.peer, &link, &transport, .Tree, blake3.hash(second), 20_000, 1_000, buffers.request[:], buffers.answer[:])
	testing.expect_value(t, fetch.exchange.reason, Refusal_Reason.Object_Absent)
	fetch = mesh_fetch_object(&laptop.peer, &link, &transport, .Blob, blake3.hash([]u8{9}), 20_000, 1_000, buffers.request[:], buffers.answer[:])
	testing.expect_value(t, fetch.exchange.outcome, call_outcome.Call_Outcome.Nothing_Has_That_Name)

	// The answer is lost after the request ran: the outcome is in doubt,
	// nothing is kept, and the link breaks.
	network.lose_answer = true
	fetch = mesh_fetch_object(&laptop.peer, &link, &transport, .Blob, blake3.hash(second), 20_000, 1_000, buffers.request[:], buffers.answer[:])
	testing.expect_value(t, fetch.exchange.outcome, call_outcome.Call_Outcome.Connection_Ended_During_The_Call)
	testing.expect(t, object_lookup(&laptop.peer, blake3.hash(second)) == nil)
	testing.expect_value(t, link.state, Mesh_Link_State.Broken)
	network.lose_answer = false
	served := network.served
	fetch = mesh_fetch_object(&laptop.peer, &link, &transport, .Blob, blake3.hash(second), 20_000, 1_000, buffers.request[:], buffers.answer[:])
	testing.expect_value(t, fetch.exchange.outcome, call_outcome.Call_Outcome.Callee_Unavailable)
	testing.expect_value(t, network.served, served)

	// The link opens again; a machine that is down gives Unreachable.
	network.down = true
	testing.expect_value(t, mesh_connect(&link, &laptop.peer, &transport, client_identity(home), .Paired, 20_000, 1_000), Mesh_Client_Status.Unreachable)
	network.down = false
	testing.expect_value(t, mesh_connect(&link, &laptop.peer, &transport, client_identity(home), .Paired, 20_000, 1_000), Mesh_Client_Status.Ok)
	fetch = mesh_fetch_object(&laptop.peer, &link, &transport, .Blob, blake3.hash(second), 20_000, 1_000, buffers.request[:], buffers.answer[:])
	testing.expect_value(t, fetch.fetch, Object_Fetch_Status.Stored)
}

@(test)
client_role_calls_end_answered_refused_or_unknown :: proc(t: ^testing.T) {
	laptop := client_machine_make(0x43)
	home := client_machine_make(0x53)
	defer free(laptop)
	defer free(home)
	network := new(Client_Network)
	defer free(network)
	network^ = Client_Network{client = laptop, now_ms = 30_000}
	network.machines[0] = home
	network.count = 1
	buffers := new(Client_Buffers)
	defer free(buffers)
	transport := network_transport(network)
	testing.expect(t, join_by_link(t, home, laptop, network, buffers))
	testing.expect(t, machine_grant_set(&home.peer, client_identity(laptop), {.Roles}, {.Storage}))
	link: Mesh_Link
	testing.expect_value(t, mesh_connect(&link, &laptop.peer, &transport, client_identity(home), .Paired, 30_000, 1_000), Mesh_Client_Status.Ok)

	call := mesh_call_role(&link, &transport, .Storage, 1, {}, transmute([]u8)string("abc"), 30_000, 1_000, buffers.request[:], buffers.answer[:])
	testing.expect_value(t, call.exchange.outcome, call_outcome.Call_Outcome.Succeeded)
	testing.expect(t, string(call.reply.result) == "cba" && call.reply.value == 3)

	// The holder refused: the call did not run.
	call = mesh_call_role(&link, &transport, .Storage, 2, {}, nil, 30_000, 1_000, buffers.request[:], buffers.answer[:])
	testing.expect_value(t, call.exchange.outcome, call_outcome.Call_Outcome.Callee_Unavailable)
	// A role that the grant does not name: refused before it runs.
	call = mesh_call_role(&link, &transport, .Sound_Device, 1, {}, nil, 30_000, 1_000, buffers.request[:], buffers.answer[:])
	testing.expect_value(t, call.exchange.outcome, call_outcome.Call_Outcome.Callee_Unavailable)
	testing.expect_value(t, call.exchange.reason, Refusal_Reason.Role_Refused)
	// The holder ran and broke its contract: it stopped during the call.
	call = mesh_call_role(&link, &transport, .Storage, 3, {}, nil, 30_000, 1_000, buffers.request[:], buffers.answer[:])
	testing.expect_value(t, call.exchange.outcome, call_outcome.Call_Outcome.Callee_Stopped_During_The_Call)
	testing.expect_value(t, call.exchange.reason, Refusal_Reason.Role_Holder_Fault)
	// A reply that names another call than the call in flight: unreadable,
	// never taken as the answer of this call. The holder ran it.
	network.other_call = true
	call = mesh_call_role(&link, &transport, .Storage, 1, {}, transmute([]u8)string("abc"), 30_000, 1_000, buffers.request[:], buffers.answer[:])
	testing.expect_value(t, call.exchange.outcome, call_outcome.Call_Outcome.Answer_Unreadable)
	testing.expect_value(t, call.exchange.reason, Refusal_Reason.Malformed)
	testing.expect(t, call.reply.result == nil)
	testing.expect_value(t, mesh_link_in_flight(&link), 0)
	network.other_call = false
	call = mesh_call_role(&link, &transport, .Storage, 1, {}, transmute([]u8)string("de"), 30_000, 1_000, buffers.request[:], buffers.answer[:])
	testing.expect(t, call.exchange.outcome == .Succeeded && string(call.reply.result) == "ed")
	// The bound passes: in doubt, and the link stays up.
	network.time_out = true
	call = mesh_call_role(&link, &transport, .Storage, 1, {}, nil, 30_000, 1_000, buffers.request[:], buffers.answer[:])
	testing.expect_value(t, call.exchange.outcome, call_outcome.Call_Outcome.Deadline_Passed_During_The_Call)
	testing.expect_value(t, link.state, Mesh_Link_State.Up)
	network.time_out = false
	// The role None and too many argument bytes never leave.
	call = mesh_call_role(&link, &transport, .None, 1, {}, nil, 30_000, 1_000, buffers.request[:], buffers.answer[:])
	testing.expect_value(t, call.exchange.status, Mesh_Client_Status.Refused_Bad_Request)
	testing.expect_value(t, call.exchange.outcome, call_outcome.Call_Outcome.Argument_Refused)
	big: [ROLE_ARGUMENT_LIMIT + 1]u8
	call = mesh_call_role(&link, &transport, .Storage, 1, {}, big[:], 30_000, 1_000, buffers.request[:], buffers.answer[:])
	testing.expect_value(t, call.exchange.status, Mesh_Client_Status.Refused_Bad_Request)
	testing.expect_value(t, call.exchange.outcome, call_outcome.Call_Outcome.Argument_Refused)
	// The link breaks during the call.
	network.lose_answer = true
	call = mesh_call_role(&link, &transport, .Storage, 1, {}, nil, 30_000, 1_000, buffers.request[:], buffers.answer[:])
	testing.expect_value(t, call.exchange.outcome, call_outcome.Call_Outcome.Connection_Ended_During_The_Call)
	call = mesh_call_role(&link, &transport, .Storage, 1, {}, nil, 30_000, 1_000, buffers.request[:], buffers.answer[:])
	testing.expect_value(t, call.exchange.outcome, call_outcome.Call_Outcome.Callee_Unavailable)
}

@(test)
client_session_ends_requests_on_break_bound_and_bad_answer :: proc(t: ^testing.T) {
	laptop := client_machine_make(0x44)
	home := client_machine_make(0x54)
	defer free(laptop)
	defer free(home)
	network := new(Client_Network)
	defer free(network)
	network^ = Client_Network{client = laptop, now_ms = 40_000}
	network.machines[0] = home
	network.count = 1
	buffers := new(Client_Buffers)
	defer free(buffers)
	testing.expect(t, join_by_link(t, home, laptop, network, buffers))

	link: Mesh_Link
	testing.expect_value(t, mesh_link_open(&link, &laptop.peer, client_identity(home), .Paired, 40_000, 500), Mesh_Client_Status.Ok)
	// The handshake passes its bound: the link breaks, and no request left.
	_, count := mesh_link_expire(&link, 40_499)
	testing.expect_value(t, count, 0)
	testing.expect_value(t, link.state, Mesh_Link_State.Connecting)
	_, count = mesh_link_expire(&link, 40_500)
	testing.expect_value(t, link.state, Mesh_Link_State.Broken)

	testing.expect_value(t, mesh_link_open(&link, &laptop.peer, client_identity(home), .Paired, 40_000, 500), Mesh_Client_Status.Ok)
	testing.expect_value(t, mesh_link_established(&link, client_identity(home)), Mesh_Client_Status.Ok)
	request := object_request_write(buffers.request[:], .Blob, blake3.hash([]u8{1}))
	identifiers: [MESH_REQUESTS_AT_ONCE]u64
	for index in 0 ..< MESH_REQUESTS_AT_ONCE {
		status: Mesh_Client_Status
		identifiers[index], status = mesh_request_begin(&link, request, 40_000, 100 + u64(index) * 100)
		testing.expect_value(t, status, Mesh_Client_Status.Ok)
	}
	_, full := mesh_request_begin(&link, request, 40_000, 100)
	testing.expect_value(t, full, Mesh_Client_Status.Refused_Full)
	_, bad_bound := mesh_request_begin(&link, request, 40_000, 0)
	testing.expect_value(t, bad_bound, Mesh_Client_Status.Refused_Bad_Bound)

	// The bound: the request at its deadline ends, the next one does not.
	ended, ended_count := mesh_link_expire(&link, 40_099)
	testing.expect_value(t, ended_count, 0)
	ended, ended_count = mesh_link_expire(&link, 40_100)
	testing.expect_value(t, ended_count, 1)
	testing.expect(t, ended[0].identifier == identifiers[0] && ended[0].outcome == .Deadline_Passed_During_The_Call)

	// A malformed answer, an answer of another message, a malformed refusal.
	_, outcome, _, _, found := mesh_answer_accept(&link, identifiers[1], []u8{1, 2, 3})
	testing.expect(t, found && outcome == .Answer_Unreadable)
	wrong: [FRAME_HEADER_SIZE]u8
	wrong_body, _ := frame_begin(wrong[:], .Role_Reply, 0)
	_, outcome, _, _, found = mesh_answer_accept(&link, identifiers[2], frame_bytes(wrong[:], wrong_body))
	testing.expect(t, found && outcome == .Answer_Unreadable)
	refusal: [FRAME_HEADER_SIZE + REFUSAL_BODY_SIZE]u8
	refusal_frame := refusal_write(refusal[:], .Not_Paired, 0)
	byte_order.write_u32_little_endian(refusal_frame, FRAME_HEADER_SIZE, 999)
	_, outcome, _, _, found = mesh_answer_accept(&link, identifiers[3], refusal_frame)
	testing.expect(t, found && outcome == .Answer_Unreadable)
	// An answer of a request that is not in flight changes nothing.
	_, _, _, _, found = mesh_answer_accept(&link, identifiers[3], refusal_frame)
	testing.expect(t, !found)
	_, _, _, _, found = mesh_answer_accept(&link, 0, refusal_frame)
	testing.expect(t, !found)

	// A refusal that says the request did not run.
	identifier, _ := mesh_request_begin(&link, request, 40_000, 100)
	reason: Refusal_Reason
	_, outcome, reason, _, found = mesh_answer_accept(&link, identifier, refusal_write(refusal[:], .Not_Paired, 0))
	testing.expect(t, found && outcome == .Grant_Or_Right_Missing && reason == .Not_Paired)

	// The break ends each request in flight with Connection_Ended_During_The_Call.
	first, _ := mesh_request_begin(&link, request, 40_000, 100)
	second, _ := mesh_request_begin(&link, request, 40_000, 100)
	ended, ended_count = mesh_link_broken(&link)
	testing.expect_value(t, ended_count, 2)
	testing.expect(t, ended[0].identifier == first && ended[1].identifier == second)
	testing.expect(t, ended[0].outcome == .Connection_Ended_During_The_Call && ended[1].outcome == .Connection_Ended_During_The_Call)
	_, unreachable := mesh_request_begin(&link, request, 40_000, 100)
	testing.expect_value(t, unreachable, Mesh_Client_Status.Unreachable)
}

@(test)
client_syncs_a_store_and_repeats_a_lost_offer :: proc(t: ^testing.T) {
	laptop := client_machine_make(0x45)
	home := client_machine_make(0x55)
	defer free(laptop)
	defer free(home)
	network := new(Client_Network)
	defer free(network)
	network^ = Client_Network{client = laptop, now_ms = 50_000}
	network.machines[0] = home
	network.count = 1
	buffers := new(Client_Buffers)
	defer free(buffers)
	transport := network_transport(network)
	testing.expect(t, join_by_link(t, home, laptop, network, buffers))
	store_identifier := blake3.hash(transmute([]u8)string("notes"))
	laptop_store, laptop_status := store_exchange_add(&laptop.peer.stores, store_identifier, client_identity(home))
	home_store, home_status := store_exchange_add(&home.peer.stores, store_identifier, client_identity(laptop))
	testing.expect(t, laptop_status == .Ok && home_status == .Ok)
	object := blake3.hash(transmute([]u8)string("a page"))
	content := blake3.hash(transmute([]u8)string("its text"))
	testing.expect_value(t, store_write(laptop_store, object, content), Store_Status.Ok)

	link: Mesh_Link
	testing.expect_value(t, mesh_connect(&link, &laptop.peer, &transport, client_identity(home), .Paired, 50_000, 1_000), Mesh_Client_Status.Ok)
	// No use Stores: refused, and the offer stays.
	sync := mesh_sync_store(&laptop.peer, &link, &transport, store_identifier, 50_000, 1_000, buffers.request[:], buffers.answer[:])
	testing.expect_value(t, sync.exchange.reason, Refusal_Reason.Use_Not_Granted)
	testing.expect(t, machine_grant_set(&home.peer, client_identity(laptop), {.Stores}, {}))

	// The reply is lost after home merged: the next sync repeats the same
	// snapshot, and home answers it again with no change.
	network.lose_answer = true
	sync = mesh_sync_store(&laptop.peer, &link, &transport, store_identifier, 50_000, 1_000, buffers.request[:], buffers.answer[:])
	testing.expect_value(t, sync.exchange.outcome, call_outcome.Call_Outcome.Connection_Ended_During_The_Call)
	testing.expect(t, store_version_lookup(&home_store.current, object) == content)
	network.lose_answer = false
	testing.expect_value(t, mesh_connect(&link, &laptop.peer, &transport, client_identity(home), .Paired, 50_000, 1_000), Mesh_Client_Status.Ok)
	sync = mesh_sync_store(&laptop.peer, &link, &transport, store_identifier, 50_000, 1_000, buffers.request[:], buffers.answer[:])
	testing.expect_value(t, sync.exchange.outcome, call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, sync.store, Store_Status.Ok)
	testing.expect(t, store_version_hash(&laptop_store.common) == store_version_hash(&home_store.common))

	// A store that is not exchanged, and a link to another partner.
	sync = mesh_sync_store(&laptop.peer, &link, &transport, blake3.hash([]u8{1}), 50_000, 1_000, buffers.request[:], buffers.answer[:])
	testing.expect_value(t, sync.store, Store_Status.Refused_Unknown_Store)
	other := Mesh_Link{state = .Up, purpose = .Paired, pinned_identity = client_identity(laptop)}
	sync = mesh_sync_store(&laptop.peer, &other, &transport, store_identifier, 50_000, 1_000, buffers.request[:], buffers.answer[:])
	testing.expect_value(t, sync.store, Store_Status.Refused_Not_Partner)
}

@(test)
client_pairing_link_refuses_an_ended_code :: proc(t: ^testing.T) {
	laptop := client_machine_make(0x47)
	home := client_machine_make(0x57)
	defer free(laptop)
	defer free(home)
	started: u64 = 70_000
	random_bytes := [8]u8{1, 3, 5, 7, 9, 11, 13, 15}
	code, _ := machine_mesh.pairing_offer(&home.peer.pairing, client_identity(home), random_bytes, started)
	testing.expect_value(t, machine_mesh.pairing_join(&laptop.peer.pairing, client_identity(laptop), code[:], started), machine_mesh.Pairing_Status.Ok)
	link: Mesh_Link
	// The edges: the last millisecond of the code, its end, a clock before
	// its start.
	ended := started + machine_mesh.PAIRING_CODE_LIFETIME_MS
	testing.expect_value(t, mesh_link_open(&link, &laptop.peer, client_identity(home), .Pairing, ended, 1_000), Mesh_Client_Status.Refused_Code_Expired)
	testing.expect_value(t, mesh_link_open(&link, &laptop.peer, client_identity(home), .Pairing, max(u64) - 1_000, 1_000), Mesh_Client_Status.Refused_Code_Expired)
	testing.expect_value(t, mesh_link_open(&link, &laptop.peer, client_identity(home), .Pairing, started - 1, 1_000), Mesh_Client_Status.Refused_Code_Expired)
	testing.expect_value(t, link.state, Mesh_Link_State.Idle)
	testing.expect_value(t, mesh_link_open(&link, &laptop.peer, client_identity(home), .Pairing, ended - 1, 1_000), Mesh_Client_Status.Ok)
}

@(test)
client_pairing_link_breaks_and_spends_the_code :: proc(t: ^testing.T) {
	laptop := client_machine_make(0x46)
	home := client_machine_make(0x56)
	defer free(laptop)
	defer free(home)
	network := new(Client_Network)
	defer free(network)
	network^ = Client_Network{client = laptop, now_ms = 60_000}
	network.machines[0] = home
	network.count = 1
	buffers := new(Client_Buffers)
	defer free(buffers)
	transport := network_transport(network)
	random_bytes := [8]u8{9, 8, 7, 6, 5, 4, 3, 2}
	code, _ := machine_mesh.pairing_offer(&home.peer.pairing, client_identity(home), random_bytes, 60_000)
	home.peer.pairing_uses = {.Calls}
	laptop.peer.pairing_uses = {.Calls}
	testing.expect_value(t, machine_mesh.pairing_join(&laptop.peer.pairing, client_identity(laptop), code[:], 60_000), machine_mesh.Pairing_Status.Ok)
	link: Mesh_Link
	testing.expect_value(t, mesh_connect(&link, &laptop.peer, &transport, client_identity(home), .Pairing, 60_000, 1_000), Mesh_Client_Status.Ok)
	network.lose_answer = true
	joined := mesh_pair_join(&laptop.peer, &link, &transport, 60_000, 1_000, buffers.request[:], buffers.answer[:])
	testing.expect(t, joined.pairing != .Ok)
	testing.expect_value(t, joined.exchange.outcome, call_outcome.Call_Outcome.Connection_Ended_During_The_Call)
	_, paired := machine_mesh.paired_machine_find(&laptop.peer.paired, client_identity(home))
	testing.expect(t, !paired)
	testing.expect_value(t, laptop.peer.pairing.phase, machine_mesh.Pairing_Phase.Failed)
	// The code is spent on this machine: the same code runs no second
	// exchange.
	network.lose_answer = false
	testing.expect_value(t, machine_mesh.pairing_join(&laptop.peer.pairing, client_identity(laptop), code[:], 60_000), machine_mesh.Pairing_Status.Ok)
	testing.expect_value(t, mesh_connect(&link, &laptop.peer, &transport, client_identity(home), .Pairing, 60_000, 1_000), Mesh_Client_Status.Ok)
	served := network.served
	joined = mesh_pair_join(&laptop.peer, &link, &transport, 60_000, 1_000, buffers.request[:], buffers.answer[:])
	testing.expect_value(t, joined.pairing, machine_mesh.Pairing_Status.Refused_Code_Spent)
	testing.expect_value(t, network.served, served)
}

// Each refusal of the other machine gives an outcome of Nothing_Changed,
// since the request did not run, and a fault of a holder that ran is in
// doubt. Each refusal of the session before the request left changes
// nothing too. None of them is Succeeded.
@(test)
the_ends_of_a_request_name_their_outcome :: proc(t: ^testing.T) {
	for reason in Refusal_Reason {
		outcome := mesh_refusal_outcome(reason)
		group := call_outcome.effect_group_of(outcome)
		if reason == .Role_Holder_Fault {
			testing.expect_value(t, outcome, call_outcome.Call_Outcome.Callee_Stopped_During_The_Call)
		} else {
			testing.expectf(t, group == .Nothing_Changed, "the reason %v gives %v", reason, outcome)
		}
	}
	for status in Mesh_Client_Status {
		outcome := mesh_status_outcome(status)
		if status == .Ok {
			testing.expect_value(t, outcome, call_outcome.Call_Outcome.Succeeded)
			continue
		}
		testing.expectf(t, call_outcome.effect_group_of(outcome) == .Nothing_Changed, "the status %v gives %v", status, outcome)
		exchange := mesh_exchange_refused(status)
		testing.expect(t, exchange.outcome != .Succeeded && !mesh_refused_by_peer(exchange))
	}
}
