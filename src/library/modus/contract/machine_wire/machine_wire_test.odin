#+build !freestanding
package machine_wire

import "base:runtime"
import "core:crypto/chacha20poly1305"
import "core:crypto/ed25519"
import "core:testing"
import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/machine_mesh"
import "modus:contract/object_cache"
import "modus:contract/remote"
import "modus:contract/role_contract"

// ---- Helpers ----

@(private = "file")
key_pair :: proc(seed_byte: u8) -> (private_key: ed25519.Private_Key, public_key: [32]u8) {
	seed: [ed25519.PRIVATE_KEY_SIZE]u8
	for index in 0 ..< len(seed) {
		seed[index] = seed_byte + u8(index * 7 + 1)
	}
	ok := ed25519.private_key_set_bytes(&private_key, seed[:])
	assert(ok)
	ed25519.private_key_public_bytes(&private_key, public_key[:])
	return private_key, public_key
}

@(private = "file")
verify_ed25519 :: proc "contextless" (public_key: [32]u8, message: []u8, signature: [64]u8, _: rawptr) -> bool {
	context = runtime.default_context()
	key, signature_copy := public_key, signature
	parsed: ed25519.Public_Key
	if !ed25519.public_key_set_bytes(&parsed, key[:]) {
		return false
	}
	return ed25519.verify(&parsed, message, signature_copy[:])
}

// Deterministic random bytes: a counter hashed with the identity of the peer.
@(private = "file")
Test_Random :: struct {
	seed:    u8,
	counter: u64,
	broken:  bool, // The generator fails: no key can be made.
}

@(private = "file")
fill_test_random :: proc "contextless" (bytes: []u8, user_data: rawptr) -> bool {
	state := (^Test_Random)(user_data)
	if state.broken {
		return false
	}
	state.counter += 1
	input: [9]u8
	input[0] = state.seed
	byte_order.write_u64_little_endian(input[:], 1, state.counter)
	derived := blake3.derive_key("modus machine wire test random", input[:])
	for index in 0 ..< len(bytes) {
		bytes[index] = derived[index % 32]
	}
	return true
}

// The role holder of the tests: export 1 answers with the reversed
// arguments, export 2 refuses, export 3 lies with a link outcome.
@(private = "file")
test_role_holder :: proc "contextless" (role: role_contract.Role, export: u32, arguments: []u8, result: []u8, _: rawptr) -> (value: i64, result_count: int, outcome: Role_Outcome) {
	switch export {
	case 1:
		for index in 0 ..< len(arguments) {
			result[index] = arguments[len(arguments) - 1 - index]
		}
		return i64(len(arguments)), len(arguments), .Answered
	case 2:
		return -1, 0, .Refused
	case 3:
		return 0, 0, .Unknown_Outcome
	}
	return 0, len(result) + 1, .Answered
}

@(private = "file")
Machine :: struct {
	peer:        Peer,
	random:      Test_Random,
	private_key: ed25519.Private_Key,
	output:      [FRAME_LIMIT]u8,
}

@(private = "file")
machine_make :: proc(seed: u8) -> ^Machine {
	machine := new(Machine)
	public_key: [32]u8
	machine.private_key, public_key = key_pair(seed)
	machine.random.seed = seed
	ok := peer_init(&machine.peer, public_key, Peer_Services{signature_verify = verify_ed25519, fill_random = fill_test_random, role_holder = test_role_holder, user_data = &machine.random})
	assert(ok)
	return machine
}

@(private = "file")
machine_free :: proc(machines: ..^Machine) {
	for machine in machines {
		free(machine)
	}
}

@(private = "file")
identity_of :: proc(machine: ^Machine) -> [32]u8 {
	return machine.peer.identity.public_key
}

// exchange carries one request of client on a stream to server, as remote
// does: the key that the handshake proved comes from the transport.
@(private = "file")
exchange :: proc(server: ^Machine, client_identity: [32]u8, request: []u8, now_ms: u64 = 1_000, root_key: [32]u8 = {}) -> []u8 {
	serve_context := Serve_Context {
		peer_identity        = client_identity,
		peer_root_public_key = root_key,
		channel_binding      = channel_binding_of_identities(identity_of(server), client_identity),
		now_ms               = now_ms,
	}
	return serve(&server.peer, &serve_context, request, server.output[:])
}

@(private = "file")
expect_refusal :: proc(t: ^testing.T, answer: []u8, reason: Refusal_Reason, detail: u32, location := #caller_location) {
	_, got_reason, got_detail, ok := answer_expect(answer, .Refusal)
	testing.expect(t, !ok, "a refusal was expected", loc = location)
	testing.expectf(t, got_reason == reason && got_detail == detail, "refusal %v/%d, expected %v/%d", got_reason, got_detail, reason, detail, loc = location)
}

// grant_uses gives machine other the uses, and the roles, of the plan.
@(private = "file")
grant_uses :: proc(t: ^testing.T, machine, other: ^Machine, uses: Machine_Uses, roles: Role_Set = {}, location := #caller_location) {
	testing.expect(t, machine_grant_set(&machine.peer, identity_of(other), uses, roles), loc = location)
}

// pair runs the whole pairing of joiner with offerer, by the frames.
@(private = "file")
pair :: proc(t: ^testing.T, offerer, joiner: ^Machine, now_ms: u64) -> bool {
	// The code differs for each pairing: a spent code is refused.
	random_bytes := [8]u8{offerer.random.seed, u8(now_ms), u8(now_ms >> 8), 4, 5, 6, 7, 8}
	code, offer_status := machine_mesh.pairing_offer(&offerer.peer.pairing, identity_of(offerer), random_bytes, now_ms)
	if offer_status != .Ok {
		return false
	}
	offerer.peer.pairing_uses_word = remote.client_uses_word({.Calls})
	joiner.peer.pairing_uses_word = remote.client_uses_word({.Calls})
	if machine_mesh.pairing_join(&joiner.peer.pairing, identity_of(joiner), code[:], now_ms) != .Ok {
		return false
	}
	request: [FRAME_LIMIT]u8
	element, element_status := pairing_element_write(&joiner.peer, identity_of(offerer), channel_binding_of_identities(identity_of(offerer), identity_of(joiner)), now_ms, request[:])
	testing.expect_value(t, element_status, machine_mesh.Pairing_Status.Ok)
	reply := exchange(offerer, identity_of(joiner), element, now_ms)
	confirm_request: [FRAME_LIMIT]u8
	confirm, confirm_status := pairing_element_reply_accept(&joiner.peer, reply, now_ms, confirm_request[:])
	testing.expect_value(t, confirm_status, machine_mesh.Pairing_Status.Ok)
	confirmed := exchange(offerer, identity_of(joiner), confirm, now_ms)
	_, _, ok := pairing_confirmed_accept(&joiner.peer, identity_of(offerer), confirmed)
	return ok && confirm_status == .Ok
}

// ---- The frames ----

@(test)
frame_border_refuses_each_malformed_frame :: proc(t: ^testing.T) {
	home := machine_make(0x10)
	defer machine_free(home)
	stranger := [32]u8{0 = 9, 31 = 9}

	// Fewer bytes than a header, and a call request: not a mesh frame.
	expect_refusal(t, exchange(home, stranger, []u8{2, 0, 0}), .Malformed, u32(Frame_Status.Too_Short))
	call: [FRAME_HEADER_SIZE]u8
	byte_order.write_u32_little_endian(call[:], 0, u32(remote.Request_Kind.Call))
	expect_refusal(t, exchange(home, stranger, call[:]), .Malformed, u32(Frame_Status.Not_Mesh))
	testing.expect(t, !stream_is_mesh(call[:]))
	testing.expect(t, !stream_is_mesh([]u8{2, 0}))

	// The message word: None, one past the last member, the largest word.
	for word in ([?]u32{0, u32(max(Message)) + 1, max(u32)}) {
		frame: [FRAME_HEADER_SIZE]u8
		byte_order.write_u32_little_endian(frame[:], 0, u32(remote.Request_Kind.Mesh))
		byte_order.write_u32_little_endian(frame[:], 4, word)
		expect_refusal(t, exchange(home, stranger, frame[:]), .Malformed, u32(Frame_Status.Bad_Message))
	}
	// The zero word, the count of the body: one less, one more, over the limit.
	frame: [FRAME_HEADER_SIZE + 4]u8
	body, _ := frame_begin(frame[:], .Object_Request, 4)
	_ = body
	whole := frame_bytes(frame[:], frame[FRAME_HEADER_SIZE:])
	byte_order.write_u32_little_endian(whole, 12, 1)
	expect_refusal(t, exchange(home, stranger, whole), .Malformed, u32(Frame_Status.Reserved_Set))
	byte_order.write_u32_little_endian(whole, 12, 0)
	expect_refusal(t, exchange(home, stranger, whole[:len(whole) - 1]), .Malformed, u32(Frame_Status.Length_Differs))
	byte_order.write_u32_little_endian(whole, 8, 5)
	expect_refusal(t, exchange(home, stranger, whole), .Malformed, u32(Frame_Status.Length_Differs))
	byte_order.write_u32_little_endian(whole, 8, FRAME_BODY_LIMIT + 1)
	expect_refusal(t, exchange(home, stranger, whole), .Malformed, u32(Frame_Status.Too_Large))

	// An answer message sent as a request.
	for message in ([?]Message{.Refusal, .Pairing_Element_Reply, .Pairing_Confirmed, .Object_Response, .Grant_Accepted, .Store_Offer_Reply, .Role_Reply, .Relay_Deposited, .Relay_Delivery}) {
		empty: [FRAME_HEADER_SIZE]u8
		request_body, ok := frame_begin(empty[:], message, 0)
		testing.expect(t, ok)
		expect_refusal(t, exchange(home, stranger, frame_bytes(empty[:], request_body)), .Unexpected_Message, u32(message))
	}
	// frame_begin refuses None, a negative body, a body over the limit and a small output.
	_, begin_ok := frame_begin(frame[:], .None, 0)
	testing.expect(t, !begin_ok)
	_, begin_ok = frame_begin(frame[:], .Object_Request, -1)
	testing.expect(t, !begin_ok)
	_, begin_ok = frame_begin(frame[:], .Object_Request, FRAME_BODY_LIMIT + 1)
	testing.expect(t, !begin_ok)
	_, begin_ok = frame_begin(frame[:], .Object_Request, 5)
	testing.expect(t, !begin_ok)

	// The call path refuses a mesh frame, so the word chooses one protocol.
	mesh_frame: [remote.REQUEST_SIZE]u8
	byte_order.write_u32_little_endian(mesh_frame[:], 0, u32(remote.Request_Kind.Mesh))
	_, _, error, call_ok := remote.request_check(mesh_frame[:], remote.REGION_SIZE)
	testing.expect(t, !call_ok && error.argument == remote.FIELD_KIND)

	// A refusal with no reason, or of another size, is malformed.
	refusal: [FRAME_HEADER_SIZE + REFUSAL_BODY_SIZE]u8
	written := refusal_write(refusal[:], .None, 0)
	_, reason, _, answer_ok := answer_expect(written, .Object_Response)
	testing.expect(t, !answer_ok && reason == .Malformed)
	testing.expect(t, refusal_write(refusal[:FRAME_HEADER_SIZE + REFUSAL_BODY_SIZE - 1], .Malformed, 0) == nil)

	// A peer with no identity answers No_Identity.
	empty_peer := new(Machine)
	defer free(empty_peer)
	request: [FRAME_LIMIT]u8
	serve_context := Serve_Context{peer_identity = stranger}
	expect_refusal(t, serve(&empty_peer.peer, &serve_context, object_request_write(request[:], .Blob, blake3.hash([]u8{1})), empty_peer.output[:]), .No_Identity, 0)
	testing.expect(t, !peer_init(&empty_peer.peer, {}, Peer_Services{signature_verify = verify_ed25519, fill_random = fill_test_random}))
	testing.expect(t, !peer_init(&empty_peer.peer, stranger, Peer_Services{fill_random = fill_test_random}))
}

// ---- Pairing ----

@(test)
pairing_by_frames_writes_both_rows_and_refuses_strangers :: proc(t: ^testing.T) {
	home := machine_make(0x20)
	laptop := machine_make(0x30)
	defer machine_free(home, laptop)
	stranger := [32]u8{0 = 0x77, 31 = 0x77}

	// No pairing is open: an unknown key is not admitted.
	testing.expect(t, !peer_admits(&home.peer, identity_of(laptop), 5_000))
	testing.expect(t, pair(t, home, laptop, 5_000))

	home_row, home_has := machine_mesh.paired_machine_find(&home.peer.paired, identity_of(laptop))
	laptop_row, laptop_has := machine_mesh.paired_machine_find(&laptop.peer.paired, identity_of(home))
	testing.expect(t, home_has && laptop_has)
	testing.expect(t, home_row.transcript_fingerprint == laptop_row.transcript_fingerprint)
	testing.expect(t, home_row.uses == {.Calls})
	testing.expect(t, peer_admits(&home.peer, identity_of(laptop), 5_000))
	testing.expect(t, !peer_admits(&home.peer, stranger, 5_000))
	testing.expect(t, !peer_admits(&home.peer, {}, 5_000))

	// A second Pairing_Element after the pairing: the session is spent.
	request: [FRAME_LIMIT]u8
	body, _ := frame_begin(request[:], .Pairing_Element, PAIRING_ELEMENT_SIZE)
	expect_refusal(t, exchange(home, identity_of(laptop), frame_bytes(request[:], body)), .Pairing_Refused, u32(machine_mesh.Pairing_Status.Refused_Bad_Phase))
	// A body of another size.
	body, _ = frame_begin(request[:], .Pairing_Element, PAIRING_ELEMENT_SIZE - 1)
	expect_refusal(t, exchange(home, identity_of(laptop), frame_bytes(request[:], body)), .Malformed, 0)
	// A stranger is not paired: each frame of a paired machine is refused.
	expect_refusal(t, exchange(home, stranger, object_request_write(request[:], .Blob, blake3.hash([]u8{1}))), .Not_Paired, 0)
}

@(test)
pairing_with_a_wrong_code_ends_on_both_machines :: proc(t: ^testing.T) {
	home := machine_make(0x40)
	laptop := machine_make(0x50)
	late := machine_make(0x60)
	defer machine_free(home, laptop, late)
	now := u64(9_000)

	code, _ := machine_mesh.pairing_offer(&home.peer.pairing, identity_of(home), [8]u8{1, 2, 3, 4, 5, 6, 7, 8}, now)
	home.peer.pairing_uses_word = remote.client_uses_word({.Calls})
	laptop.peer.pairing_uses_word = remote.client_uses_word({.Calls})
	wrong := code
	wrong[0] = wrong[0] == 'A' ? 'B' : 'A'
	testing.expect_value(t, machine_mesh.pairing_join(&laptop.peer.pairing, identity_of(laptop), wrong[:], now), machine_mesh.Pairing_Status.Ok)

	request, confirm_request: [FRAME_LIMIT]u8
	element, _ := pairing_element_write(&laptop.peer, identity_of(home), channel_binding_of_identities(identity_of(home), identity_of(laptop)), now, request[:])
	reply := exchange(home, identity_of(laptop), element, now)
	confirm, status := pairing_element_reply_accept(&laptop.peer, reply, now, confirm_request[:])
	testing.expect_value(t, status, machine_mesh.Pairing_Status.Refused_Confirmation_Failed)
	// The frame still goes, so the offerer ends too.
	testing.expect(t, confirm != nil)
	expect_refusal(t, exchange(home, identity_of(laptop), confirm, now), .Pairing_Refused, u32(machine_mesh.Pairing_Status.Refused_Confirmation_Failed))
	testing.expect_value(t, home.peer.paired.count, 0)
	testing.expect_value(t, laptop.peer.paired.count, 0)
	testing.expect(t, !peer_admits(&home.peer, identity_of(laptop), now))

	// The right code, typed later on a third machine: the code is gone.
	machine_mesh.pairing_join(&late.peer.pairing, identity_of(late), code[:], now)
	late_element, _ := pairing_element_write(&late.peer, identity_of(home), channel_binding_of_identities(identity_of(home), identity_of(late)), now, request[:])
	expect_refusal(t, exchange(home, identity_of(late), late_element, now), .Pairing_Refused, u32(machine_mesh.Pairing_Status.Refused_Bad_Phase))
}

@(test)
pairing_refuses_a_swapped_key_a_late_confirm_and_no_random :: proc(t: ^testing.T) {
	home := machine_make(0x70)
	laptop := machine_make(0x80)
	relay := machine_make(0x90)
	defer machine_free(home, laptop, relay)
	now := u64(1_000)
	request: [FRAME_LIMIT]u8

	// The element names the key of the laptop, but the handshake proved the
	// key of a relay on the path: the associated data differs.
	code, _ := machine_mesh.pairing_offer(&home.peer.pairing, identity_of(home), [8]u8{9, 2, 3, 4, 5, 6, 7, 8}, now)
	machine_mesh.pairing_join(&laptop.peer.pairing, identity_of(laptop), code[:], now)
	element, _ := pairing_element_write(&laptop.peer, identity_of(home), channel_binding_of_identities(identity_of(home), identity_of(laptop)), now, request[:])
	expect_refusal(t, exchange(home, identity_of(relay), element, now), .Pairing_Refused, u32(machine_mesh.Pairing_Status.Refused_Peer_Key_Mismatch))
	testing.expect(t, !peer_admits(&home.peer, identity_of(relay), now))

	// A confirm from another key than the key of the exchange.
	code, _ = machine_mesh.pairing_offer(&home.peer.pairing, identity_of(home), [8]u8{7, 7, 3, 4, 5, 6, 7, 8}, now)
	laptop.peer.pairing = {}
	machine_mesh.pairing_join(&laptop.peer.pairing, identity_of(laptop), code[:], now)
	element, _ = pairing_element_write(&laptop.peer, identity_of(home), channel_binding_of_identities(identity_of(home), identity_of(laptop)), now, request[:])
	exchange(home, identity_of(laptop), element, now)
	confirm: [FRAME_HEADER_SIZE + PAIRING_CONFIRM_SIZE]u8
	confirm_body, _ := frame_begin(confirm[:], .Pairing_Confirm, PAIRING_CONFIRM_SIZE)
	expect_refusal(t, exchange(home, identity_of(relay), frame_bytes(confirm[:], confirm_body), now), .Pairing_Refused, u32(machine_mesh.Pairing_Status.Refused_Bad_Phase))
	testing.expect_value(t, home.peer.paired.count, 0)

	// A confirm of another key does not end the exchange of the laptop;
	// the principal ends it by a new offer.
	testing.expect_value(t, home.peer.pairing.phase, machine_mesh.Pairing_Phase.Confirming)
	machine_mesh.pairing_session_clear(&home.peer.pairing)

	// No random bytes: no scalar, and the pairing ends.
	code, _ = machine_mesh.pairing_offer(&home.peer.pairing, identity_of(home), [8]u8{5, 5, 3, 4, 5, 6, 7, 8}, now)
	laptop.peer.pairing = {}
	machine_mesh.pairing_join(&laptop.peer.pairing, identity_of(laptop), code[:], now)
	element, _ = pairing_element_write(&laptop.peer, identity_of(home), channel_binding_of_identities(identity_of(home), identity_of(laptop)), now, request[:])
	home.random.broken = true
	expect_refusal(t, exchange(home, identity_of(laptop), element, now), .Pairing_Refused, u32(machine_mesh.Pairing_Status.Refused_Exchange))
	testing.expect_value(t, home.peer.pairing.phase, machine_mesh.Pairing_Phase.Failed)
}

// ---- Objects by hash ----

@(test)
object_fetch_keeps_only_bytes_that_hash_to_the_request :: proc(t: ^testing.T) {
	home := machine_make(0xA0)
	laptop := machine_make(0xB0)
	defer machine_free(home, laptop)
	testing.expect(t, pair(t, home, laptop, 1_000))
	grant_uses(t, home, laptop, {.Objects})

	text := "the bytes of a module that the laptop wants"
	other := "another object"
	hash := blake3.hash(transmute([]u8)text)
	other_hash := blake3.hash(transmute([]u8)other)
	testing.expect(t, home_publish(home, transmute([]u8)text) == hash)
	home_publish(home, transmute([]u8)other)

	request: [FRAME_LIMIT]u8
	answer := exchange(home, identity_of(laptop), object_request_write(request[:], .Blob, hash))

	// Each bit of the bytes, flipped one at a time: each copy is refused,
	// and nothing is kept.
	tampered: [FRAME_LIMIT]u8
	copy(tampered[:], answer)
	payload_start := FRAME_HEADER_SIZE + OBJECT_RESPONSE_HEADER_SIZE
	for bit in 0 ..< len(text) * 8 {
		place := payload_start + bit / 8
		tampered[place] ~= u8(1) << uint(bit % 8)
		status, _ := object_response_accept(&laptop.peer, .Blob, hash, tampered[:len(answer)])
		testing.expect_value(t, status, Object_Fetch_Status.Hash_Mismatch)
		tampered[place] ~= u8(1) << uint(bit % 8)
	}
	testing.expect_value(t, laptop.peer.objects.count, 0)

	// The answer of another object, a wrong kind, a count that lies.
	status, _ := object_response_accept(&laptop.peer, .Blob, other_hash, answer)
	testing.expect_value(t, status, Object_Fetch_Status.Other_Object)
	status, _ = object_response_accept(&laptop.peer, .Tree, hash, answer)
	testing.expect_value(t, status, Object_Fetch_Status.Other_Object)
	byte_order.write_u32_little_endian(tampered[:], FRAME_HEADER_SIZE + 4, u32(len(text) + 1))
	status, _ = object_response_accept(&laptop.peer, .Blob, hash, tampered[:len(answer)])
	testing.expect_value(t, status, Object_Fetch_Status.Malformed)
	status, _ = object_response_accept(&laptop.peer, .Blob, hash, answer[:FRAME_HEADER_SIZE + 4])
	testing.expect_value(t, status, Object_Fetch_Status.Malformed)
	testing.expect_value(t, laptop.peer.objects.count, 0)

	// The true answer is kept, once.
	status, _ = object_response_accept(&laptop.peer, .Blob, hash, answer)
	testing.expect_value(t, status, Object_Fetch_Status.Stored)
	status, _ = object_response_accept(&laptop.peer, .Blob, hash, answer)
	testing.expect_value(t, status, Object_Fetch_Status.Already_Stored)
	kept := object_lookup(&laptop.peer, hash)
	testing.expect(t, string(kept) == text)

	// An absent hash, the same hash asked as a tree, a bad kind word, a zero word set.
	reason: Refusal_Reason
	status, reason = object_response_accept(&laptop.peer, .Blob, blake3.hash([]u8{0}), exchange(home, identity_of(laptop), object_request_write(request[:], .Blob, blake3.hash([]u8{0}))))
	testing.expect(t, status == .Refused && reason == .Object_Absent)
	expect_refusal(t, exchange(home, identity_of(laptop), object_request_write(request[:], .Tree, hash)), .Object_Absent, 0)
	bad := object_request_write(request[:], .Blob, hash)
	byte_order.write_u32_little_endian(bad, FRAME_HEADER_SIZE, 7)
	expect_refusal(t, exchange(home, identity_of(laptop), bad), .Malformed, 0)
	byte_order.write_u32_little_endian(bad, FRAME_HEADER_SIZE, u32(object_cache.Cache_Object_Kind.Blob))
	byte_order.write_u32_little_endian(bad, FRAME_HEADER_SIZE + 4, 1)
	expect_refusal(t, exchange(home, identity_of(laptop), bad), .Malformed, 0)
}

@(private = "file")
home_publish :: proc(machine: ^Machine, bytes: []u8) -> blake3.Hash {
	hash := blake3.hash(bytes)
	object_publish(&machine.peer, .Blob, hash, bytes)
	return hash
}

// ---- Store exchange ----

@(private = "file")
object_hash :: proc(text: string) -> blake3.Hash {
	return blake3.hash(transmute([]u8)text)
}

// store_offer_to runs one whole exchange: the client offers, the server answers.
@(private = "file")
store_offer_to :: proc(server: ^Machine, client: ^Machine, store: ^Exchanged_Store) -> (status: Store_Status, reason: Refusal_Reason, detail: u32) {
	request: [FRAME_LIMIT]u8
	answer := exchange(server, identity_of(client), store_offer_begin(store, request[:]))
	return store_offer_reply_accept(store, answer)
}

@(private = "file")
stores_paired :: proc(t: ^testing.T, home, laptop: ^Machine, notes: blake3.Hash) -> (home_store, laptop_store: ^Exchanged_Store) {
	testing.expect(t, pair(t, home, laptop, 1_000))
	grant_uses(t, home, laptop, {.Stores})
	grant_uses(t, laptop, home, {.Stores})
	home_status, laptop_status: Store_Status
	home_store, home_status = store_exchange_add(&home.peer.stores, notes, identity_of(laptop))
	laptop_store, laptop_status = store_exchange_add(&laptop.peer.stores, notes, identity_of(home))
	testing.expect(t, home_status == .Ok && laptop_status == .Ok)
	return home_store, laptop_store
}

@(test)
store_merge_keeps_both_writes_as_a_conflict_until_one_resolution :: proc(t: ^testing.T) {
	home := machine_make(0xC0)
	laptop := machine_make(0xD0)
	defer machine_free(home, laptop)
	notes := object_hash("store notes")
	first, second, third := object_hash("object 1"), object_hash("object 2"), object_hash("object 3")
	home_store, laptop_store := stores_paired(t, home, laptop, notes)
	_, again := store_exchange_add(&home.peer.stores, notes, identity_of(laptop))
	testing.expect_value(t, again, Store_Status.Refused_Exists)

	// The first exchange: the laptop has nothing, and takes the version of home.
	testing.expect_value(t, store_write(home_store, first, object_hash("first, version 1")), Store_Status.Ok)
	testing.expect_value(t, store_write(home_store, second, object_hash("second, version 1")), Store_Status.Ok)
	status, _, _ := store_offer_to(home, laptop, laptop_store)
	testing.expect_value(t, status, Store_Status.Ok)
	testing.expect(t, store_version_hash(&home_store.current) == store_version_hash(&laptop_store.current))
	testing.expect_value(t, laptop_store.current.count, 2)

	// Each machine writes with no link: both change the first object, the
	// laptop removes the second, home adds a third.
	home_side, laptop_side := object_hash("first, written at home"), object_hash("first, written on the laptop")
	store_write(home_store, first, home_side)
	store_write(home_store, third, object_hash("third"))
	store_write(laptop_store, first, laptop_side)
	store_write(laptop_store, second, {})
	status, _, _ = store_offer_to(home, laptop, laptop_store)
	testing.expect_value(t, status, Store_Status.Ok)

	// Both machines hold the same version and the same conflict.
	testing.expect(t, store_version_hash(&home_store.current) == store_version_hash(&laptop_store.current))
	testing.expect(t, store_version_hash(&home_store.common) == store_version_hash(&laptop_store.common))
	testing.expect_value(t, store_version_lookup(&home_store.current, second), blake3.Hash{})
	testing.expect_value(t, store_version_lookup(&laptop_store.current, third), object_hash("third"))
	testing.expect(t, home_store.current.conflict_count == 1 && laptop_store.current.conflict_count == 1)
	for store in ([?]^Exchanged_Store{home_store, laptop_store}) {
		conflict := store_conflict_find(&store.current, first)
		testing.expect(t, conflict != nil)
		sides := [2]blake3.Hash{conflict.value.local_hash, conflict.value.remote_hash}
		// Neither write is lost: the conflict keeps both, and the base.
		testing.expect(t, (sides[0] == home_side && sides[1] == laptop_side) || (sides[0] == laptop_side && sides[1] == home_side))
		testing.expect(t, conflict.value.base_hash == object_hash("first, version 1"))
		testing.expect(t, store_version_lookup(&store.current, first) == conflict.value.conflict_value_hash)
		testing.expect_value(t, store_write(store, first, object_hash("a third write")), Store_Status.Refused_Holds_Conflict)
	}
	// An exchange with no change keeps the conflict on both sides.
	status, _, _ = store_offer_to(home, laptop, laptop_store)
	testing.expect(t, status == .Ok && home_store.current.conflict_count == 1 && laptop_store.current.conflict_count == 1)

	// The principal resolves it once, on home; a second resolution is refused,
	// and so is a resolution that keeps the conflict value.
	conflict_hash := store_conflict_find(&home_store.current, first).value.conflict_value_hash
	testing.expect_value(t, store_conflict_resolve(home_store, first, conflict_hash), Store_Status.Refused_Bad_Resolution)
	testing.expect_value(t, store_conflict_resolve(home_store, first, laptop_side), Store_Status.Ok)
	testing.expect_value(t, store_conflict_resolve(home_store, first, home_side), Store_Status.Refused_No_Conflict)
	testing.expect_value(t, store_conflict_resolve(home_store, second, home_side), Store_Status.Refused_No_Conflict)

	// The resolution crosses with the next exchange, offered by home this time.
	status, _, _ = store_offer_to(laptop, home, home_store)
	testing.expect_value(t, status, Store_Status.Ok)
	testing.expect(t, home_store.current.conflict_count == 0 && laptop_store.current.conflict_count == 0)
	testing.expect_value(t, store_version_lookup(&laptop_store.current, first), laptop_side)
	testing.expect(t, store_version_hash(&home_store.current) == store_version_hash(&laptop_store.current))
	testing.expect_value(t, store_write(laptop_store, first, home_side), Store_Status.Ok)
}

// A conflict that one side creates over its later writes crosses with its
// record, and the other side takes the record with the entry.
@(test)
store_offer_survives_a_lost_reply_and_a_write_in_flight :: proc(t: ^testing.T) {
	home := machine_make(0xC1)
	laptop := machine_make(0xD1)
	defer machine_free(home, laptop)
	notes := object_hash("notes")
	first, second := object_hash("first"), object_hash("second")
	home_store, laptop_store := stores_paired(t, home, laptop, notes)
	store_write(home_store, first, object_hash("first, home"))
	store_write(laptop_store, second, object_hash("second, laptop"))

	// (a) The laptop offers; home merges, and the reply is lost.
	request: [FRAME_LIMIT]u8
	lost := exchange(home, identity_of(laptop), store_offer_begin(laptop_store, request[:]))
	_, _, _, lost_ok := answer_expect(lost, .Store_Offer_Reply)
	testing.expect(t, lost_ok)
	testing.expect(t, laptop_store.has_offer && laptop_store.common.count == 0 && home_store.common.count == 2)
	// Home writes after its merge.
	store_write(home_store, object_hash("third"), object_hash("third, home"))

	// Home offers now: its common version is not the common version of the
	// laptop, so the laptop refuses, and nothing changes there.
	home_offer: [FRAME_LIMIT]u8
	laptop_before := laptop_store^
	answer := exchange(laptop, identity_of(home), store_offer_begin(home_store, home_offer[:]))
	expect_refusal(t, answer, .Store_Refused, u32(Store_Status.Refused_Base_Differs))
	testing.expect(t, laptop_store^ == laptop_before)
	status, reason, detail := store_offer_reply_accept(home_store, answer)
	testing.expect(t, status == .Refused_Nil_Input && reason == .Store_Refused && detail == u32(Store_Status.Refused_Base_Differs))

	// (b) The laptop writes while its offer is in flight, then sends the same
	// offer again: home answers the same reply, and changes nothing.
	store_write(laptop_store, object_hash("fourth"), object_hash("fourth, laptop"))
	home_before := home_store^
	status, _, _ = store_offer_to(home, laptop, laptop_store)
	testing.expect_value(t, status, Store_Status.Ok)
	testing.expect(t, home_store^ == home_before)
	testing.expect(t, store_version_hash(&home_store.common) == store_version_hash(&laptop_store.common))
	// The write in flight stays on the laptop, and crosses at the next exchange.
	testing.expect_value(t, store_version_lookup(&laptop_store.current, object_hash("fourth")), object_hash("fourth, laptop"))
	testing.expect_value(t, store_version_lookup(&laptop_store.common, object_hash("fourth")), blake3.Hash{})
	testing.expect(t, !laptop_store.has_offer)
	status, _, _ = store_offer_to(home, laptop, laptop_store)
	testing.expect_value(t, status, Store_Status.Ok)
	testing.expect(t, store_version_hash(&home_store.current) == store_version_hash(&laptop_store.current))
	testing.expect_value(t, home_store.current.count, 4)
	// A second reply to an offer that is done is refused.
	status, _, _ = store_offer_reply_accept(laptop_store, lost)
	testing.expect_value(t, status, Store_Status.Refused_No_Offer)

	// A write in flight on an object that the merge also changes: a conflict
	// on the laptop, whose record crosses to home with its entry.
	store_write(home_store, first, object_hash("first, home again"))
	store_write(laptop_store, first, object_hash("first, laptop"))
	offer := store_offer_begin(laptop_store, request[:])
	store_write(laptop_store, first, object_hash("first, laptop in flight"))
	status, _, _ = store_offer_reply_accept(laptop_store, exchange(home, identity_of(laptop), offer))
	testing.expect_value(t, status, Store_Status.Ok)
	testing.expect(t, store_conflict_find(&laptop_store.current, first) != nil)
	status, _, _ = store_offer_to(home, laptop, laptop_store)
	testing.expect_value(t, status, Store_Status.Ok)
	testing.expect(t, store_version_hash(&home_store.current) == store_version_hash(&laptop_store.current))
	home_conflict := store_conflict_find(&home_store.current, first)
	testing.expect(t, home_conflict != nil && home_conflict.value.conflict_value_hash == store_version_lookup(&home_store.current, first))
	// The older conflict that the new one names as a side stays: the write
	// of home is still one of the sides.
	testing.expect_value(t, home_store.current.conflict_count, 2)
	older := home_conflict.value.local_hash == object_hash("first, laptop in flight") ? home_conflict.value.remote_hash : home_conflict.value.local_hash
	older_found := false
	for index in 0 ..< home_store.current.conflict_count {
		record := home_store.current.conflicts[index]
		if record.value.conflict_value_hash == older {
			older_found = true
			testing.expect(t, record.value.local_hash == object_hash("first, home again") || record.value.remote_hash == object_hash("first, home again"))
		}
	}
	testing.expect(t, older_found)
	testing.expect_value(t, store_write(home_store, first, object_hash("x")), Store_Status.Refused_Holds_Conflict)
	// One resolution ends both records.
	testing.expect_value(t, store_conflict_resolve(home_store, first, object_hash("first, home again")), Store_Status.Ok)
	testing.expect_value(t, home_store.current.conflict_count, 0)
}

@(test)
store_offer_refuses_unknown_stores_strangers_and_malformed_versions :: proc(t: ^testing.T) {
	home := machine_make(0xE0)
	laptop := machine_make(0xF0)
	defer machine_free(home, laptop)
	notes := object_hash("notes")
	testing.expect(t, pair(t, home, laptop, 1_000))
	grant_uses(t, home, laptop, {.Stores})
	other_machine := [32]u8{0 = 1, 31 = 1}

	// A store that home does not exchange, and a store exchanged with another machine.
	laptop_secrets, _ := store_exchange_add(&laptop.peer.stores, object_hash("secrets"), identity_of(home))
	_, reason, detail := store_offer_to(home, laptop, laptop_secrets)
	testing.expect(t, reason == .Store_Refused && detail == u32(Store_Status.Refused_Unknown_Store))
	store_exchange_add(&home.peer.stores, object_hash("shared elsewhere"), other_machine)
	laptop_elsewhere, _ := store_exchange_add(&laptop.peer.stores, object_hash("shared elsewhere"), identity_of(home))
	_, reason, detail = store_offer_to(home, laptop, laptop_elsewhere)
	testing.expect(t, reason == .Store_Refused && detail == u32(Store_Status.Refused_Not_Partner))
	_, full := store_exchange_add(&laptop.peer.stores, notes, identity_of(home))
	testing.expect_value(t, full, Store_Status.Refused_Full)
	testing.expect_value(t, store_exchange_remove(&laptop.peer.stores, object_hash("secrets")), Store_Status.Ok)
	testing.expect_value(t, store_exchange_remove(&laptop.peer.stores, object_hash("secrets")), Store_Status.Refused_Unknown_Store)
	testing.expect_value(t, store_exchange_remove(&home.peer.stores, object_hash("shared elsewhere")), Store_Status.Ok)

	home_store, _ := store_exchange_add(&home.peer.stores, notes, identity_of(laptop))
	for index in 0 ..< 20 {
		name := [2]u8{'h', u8(index)}
		store_write(home_store, blake3.hash(name[:]), blake3.hash(name[:]))
	}
	home_before := home_store^

	// Malformed versions, each refused before any change: unsorted, a
	// duplicate identifier, a zero hash, a zero identifier, counts that lie
	// or pass the capacity, a forged conflict record, another common version.
	laptop_store, _ := store_exchange_add(&laptop.peer.stores, notes, identity_of(home))
	store_write(laptop_store, object_hash("b"), object_hash("b, 1"))
	store_write(laptop_store, object_hash("c"), object_hash("c, 1"))
	request: [FRAME_LIMIT]u8
	offer := store_offer_begin(laptop_store, request[:])
	entries := FRAME_HEADER_SIZE + STORE_OFFER_HEADER_SIZE
	cases := [?]struct {
		change: proc(offer: []u8, entries: int),
		status: Store_Status,
	} {
		{proc(offer: []u8, entries: int) {swap_entries(offer, entries)}, .Refused_Not_Sorted},
		{proc(offer: []u8, entries: int) {copy(offer[entries + STORE_ENTRY_WIRE_SIZE:][:32], offer[entries:][:32])}, .Refused_Duplicate_Identifier},
		{proc(offer: []u8, entries: int) {for index in 0 ..< 32 {offer[entries + 32 + index] = 0}}, .Refused_Zero_Hash},
		{proc(offer: []u8, entries: int) {for index in 0 ..< 32 {offer[entries + index] = 0}}, .Refused_Zero_Identifier},
		{proc(offer: []u8, entries: int) {byte_order.write_u32_little_endian(offer, FRAME_HEADER_SIZE + 64, 3)}, .Refused_Bad_Count},
		{proc(offer: []u8, entries: int) {byte_order.write_u32_little_endian(offer, FRAME_HEADER_SIZE + 64, STORE_ENTRY_CAPACITY + 1)}, .Refused_Bad_Count},
		{proc(offer: []u8, entries: int) {byte_order.write_u32_little_endian(offer, FRAME_HEADER_SIZE + 68, 1)}, .Refused_Bad_Count},
		{proc(offer: []u8, entries: int) {offer[FRAME_HEADER_SIZE + 32] ~= 1}, .Refused_Base_Differs},
		{proc(offer: []u8, entries: int) {for index in 0 ..< 32 {offer[FRAME_HEADER_SIZE + index] = 0}}, .Refused_Unknown_Store},
	}
	for item, index in cases {
		changed: [FRAME_LIMIT]u8
		copy(changed[:], offer)
		item.change(changed[:len(offer)], entries)
		answer := exchange(home, identity_of(laptop), changed[:len(offer)])
		_, got_reason, got_detail, _ := answer_expect(answer, .Store_Offer_Reply)
		testing.expectf(t, got_reason == .Store_Refused && got_detail == u32(item.status), "case %d: %v %d", index, got_reason, got_detail)
		testing.expectf(t, home_store^ == home_before, "case %d changed the store", index)
	}

	// A forged conflict record: its hash does not match its entry.
	forged_store := Exchanged_Store{in_use = true, store_identifier = notes}
	store_write(&forged_store, object_hash("d"), object_hash("not a conflict value"))
	forged_store.current.conflicts[0] = Store_Conflict{identifier = object_hash("d"), value = {base_hash = object_hash("1"), local_hash = object_hash("2"), remote_hash = object_hash("3")}}
	forged_store.current.conflict_count = 1
	forged: [FRAME_LIMIT]u8
	expect_refusal(t, exchange(home, identity_of(laptop), store_offer_begin(&forged_store, forged[:])), .Store_Refused, u32(Store_Status.Refused_Bad_Conflict))
	testing.expect(t, home_store^ == home_before)

	// A version that does not fit: 20 objects on home, 20 others on the
	// laptop, 32 at most. The offer is refused whole, with no partial write.
	for index in 0 ..< 20 {
		name := [2]u8{'l', u8(index)}
		store_write(laptop_store, blake3.hash(name[:]), blake3.hash(name[:]))
	}
	laptop_store.has_offer = false
	_, reason, detail = store_offer_to(home, laptop, laptop_store)
	testing.expect(t, reason == .Store_Refused && detail == u32(Store_Status.Refused_Full))
	testing.expect(t, home_store^ == home_before)

	// A reply that names another store is refused by the sender, which keeps its offer.
	reply: [FRAME_LIMIT]u8
	other_version: Store_Version
	laptop_before := laptop_store^
	status, _, _ := store_offer_reply_accept(laptop_store, store_offer_write(reply[:], .Store_Offer_Reply, object_hash("other"), {}, &other_version))
	testing.expect_value(t, status, Store_Status.Refused_Other_Store)
	testing.expect(t, laptop_store^ == laptop_before)
	_, zero := store_exchange_add(&home.peer.stores, {}, identity_of(laptop))
	testing.expect_value(t, zero, Store_Status.Refused_Zero_Identifier)
	testing.expect_value(t, store_write(laptop_store, {}, object_hash("x")), Store_Status.Refused_Zero_Identifier)
}

@(private = "file")
swap_entries :: proc(offer: []u8, entries: int) {
	first: [STORE_ENTRY_WIRE_SIZE]u8
	copy(first[:], offer[entries:][:STORE_ENTRY_WIRE_SIZE])
	copy(offer[entries:][:STORE_ENTRY_WIRE_SIZE], offer[entries + STORE_ENTRY_WIRE_SIZE:][:STORE_ENTRY_WIRE_SIZE])
	copy(offer[entries + STORE_ENTRY_WIRE_SIZE:][:STORE_ENTRY_WIRE_SIZE], first[:])
}

// ---- Remote roles ----

@(test)
role_call_answers_and_a_broken_link_gives_no_false_refusal :: proc(t: ^testing.T) {
	home := machine_make(0x11)
	laptop := machine_make(0x21)
	defer machine_free(home, laptop)
	testing.expect(t, pair(t, home, laptop, 1_000))
	grant_uses(t, home, laptop, {.Roles}, {.Storage})
	proxy := new(Role_Proxy)
	defer free(proxy)
	request: [FRAME_LIMIT]u8
	now := u64(2_000)

	// A call that the holder answers.
	identifier, frame, status := role_call_begin(proxy, .Storage, 1, {}, transmute([]u8)string("abcde"), now, 500, request[:])
	testing.expect_value(t, status, Role_Proxy_Status.Sent)
	reply, found := role_reply_accept(proxy, identifier, exchange(home, identity_of(laptop), frame))
	testing.expect(t, found && reply.outcome == .Answered && reply.value == 5 && string(reply.result) == "edcba")
	// Its reply is taken once.
	_, found = role_reply_accept(proxy, identifier, exchange(home, identity_of(laptop), frame))
	testing.expect(t, !found)

	// The holder refuses; a role that the plan did not give; a holder that lies.
	identifier, frame, _ = role_call_begin(proxy, .Storage, 2, {}, nil, now, 500, request[:])
	reply, _ = role_reply_accept(proxy, identifier, exchange(home, identity_of(laptop), frame))
	testing.expect(t, reply.outcome == .Refused && reply.value == -1)
	identifier, frame, _ = role_call_begin(proxy, .Sound_Device, 1, {}, nil, now, 500, request[:])
	reply, _ = role_reply_accept(proxy, identifier, exchange(home, identity_of(laptop), frame))
	testing.expect_value(t, reply.outcome, Role_Outcome.Refused)
	// The holder ran, then gave an outcome of a link or a count past its
	// result: the call can have run, so it is no refusal.
	for export in ([?]u32{3, 4}) {
		identifier, frame, _ = role_call_begin(proxy, .Storage, export, {}, nil, now, 500, request[:])
		answer := exchange(home, identity_of(laptop), frame)
		_, fault, _, _ := answer_expect(answer, .Role_Reply)
		testing.expect_value(t, fault, Refusal_Reason.Role_Holder_Fault)
		reply, _ = role_reply_accept(proxy, identifier, answer)
		testing.expect_value(t, reply.outcome, Role_Outcome.Unknown_Outcome)
	}

	// The link breaks with two calls in flight: the call that is not
	// idempotent ends with Unknown_Outcome, never Refused; the idempotent
	// one waits for the link.
	once, once_frame, _ := role_call_begin(proxy, .Storage, 1, {}, transmute([]u8)string("once"), now, 500, request[:])
	_ = once_frame
	again_frame_bytes: [FRAME_LIMIT]u8
	again, _, _ := role_call_begin(proxy, .Storage, 1, {.Idempotent}, transmute([]u8)string("again"), now, 500, again_frame_bytes[:])
	ended, count := role_link_broken(proxy)
	testing.expect(t, count == 1 && ended[0].identifier == once && ended[0].outcome == .Unknown_Outcome)
	testing.expect_value(t, proxy.link, Role_Link_State.Broken)
	// A new call while the link is broken: Unreachable at once.
	_, unreachable_frame, unreachable := role_call_begin(proxy, .Storage, 1, {}, nil, now, 500, request[:])
	testing.expect(t, unreachable == .Unreachable && unreachable_frame == nil)
	// A reply of the broken call that comes late is no outcome.
	_, found = role_reply_accept(proxy, once, exchange(home, identity_of(laptop), once_frame))
	testing.expect(t, !found)
	_, _, resent := role_resend_next(proxy, request[:])
	testing.expect(t, !resent)

	// The link holds again: the idempotent call goes again and is answered.
	role_link_restored(proxy)
	resend_identifier, resend_frame, resend_found := role_resend_next(proxy, request[:])
	testing.expect(t, resend_found && resend_identifier == again)
	reply, found = role_reply_accept(proxy, again, exchange(home, identity_of(laptop), resend_frame))
	testing.expect(t, found && reply.outcome == .Answered && string(reply.result) == "niaga")

	// No call waits past its bound: it ends with Unknown_Outcome.
	late, _, _ := role_call_begin(proxy, .Storage, 1, {}, nil, now, 500, request[:])
	ended, count = role_calls_expire(proxy, now + 499)
	testing.expect_value(t, count, 0)
	ended, count = role_calls_expire(proxy, now + 500)
	testing.expect(t, count == 1 && ended[0].identifier == late && ended[0].outcome == .Unknown_Outcome)

	// A malformed reply, a reply for another call, and a link outcome on the
	// wire: each is Unknown_Outcome, never trusted as a refusal or an answer.
	for change in 0 ..< 3 {
		call, call_frame, _ := role_call_begin(proxy, .Storage, 1, {}, transmute([]u8)string("xy"), now, 500, request[:])
		answer_bytes: [FRAME_LIMIT]u8
		answer := answer_bytes[:copy(answer_bytes[:], exchange(home, identity_of(laptop), call_frame))]
		switch change {
		case 0:
			answer = answer[:len(answer) - 1]
		case 1:
			byte_order.write_u64_little_endian(answer, FRAME_HEADER_SIZE, call + 100)
		case 2:
			byte_order.write_u32_little_endian(answer, FRAME_HEADER_SIZE + 8, u32(Role_Outcome.Unknown_Outcome))
		}
		reply, found = role_reply_accept(proxy, call, answer)
		testing.expectf(t, found && reply.outcome == .Unknown_Outcome, "change %d: %v", change, reply.outcome)
	}

	// The borders of a call: no role, too many arguments, no bound, a full table.
	_, _, status = role_call_begin(proxy, .None, 1, {}, nil, now, 500, request[:])
	testing.expect_value(t, status, Role_Proxy_Status.Refused_Bad_Role)
	big: [ROLE_ARGUMENT_LIMIT + 1]u8
	_, _, status = role_call_begin(proxy, .Storage, 1, {}, big[:], now, 500, request[:])
	testing.expect_value(t, status, Role_Proxy_Status.Refused_Too_Large)
	_, _, status = role_call_begin(proxy, .Storage, 1, {}, nil, now, 0, request[:])
	testing.expect_value(t, status, Role_Proxy_Status.Refused_Bad_Bound)
	_, _, status = role_call_begin(proxy, .Storage, 1, {}, nil, now, max(u64) - now + 1, request[:])
	testing.expect_value(t, status, Role_Proxy_Status.Refused_Bad_Bound)
	_, _, status = role_call_begin(proxy, .Storage, 1, {}, nil, max(u64), 1, request[:])
	testing.expect_value(t, status, Role_Proxy_Status.Refused_Bad_Bound)
	for _ in 0 ..< ROLE_CALLS_AT_ONCE {
		_, _, status = role_call_begin(proxy, .Storage, 1, {}, nil, now, 500, request[:])
		testing.expect_value(t, status, Role_Proxy_Status.Sent)
	}
	_, _, status = role_call_begin(proxy, .Storage, 1, {}, nil, now, 500, request[:])
	testing.expect_value(t, status, Role_Proxy_Status.Refused_Full)

	// The server refuses a malformed call: a zero identifier, an unknown flag, a role word of None.
	call_frame := role_call_write(request[:], Role_Call{identifier = 9, role = .Storage, export = 1})
	byte_order.write_u64_little_endian(call_frame, FRAME_HEADER_SIZE, 0)
	expect_refusal(t, exchange(home, identity_of(laptop), call_frame), .Malformed, 0)
	call_frame = role_call_write(request[:], Role_Call{identifier = 9, role = .Storage, export = 1})
	byte_order.write_u32_little_endian(call_frame, FRAME_HEADER_SIZE + 16, 2)
	expect_refusal(t, exchange(home, identity_of(laptop), call_frame), .Malformed, 0)
	byte_order.write_u32_little_endian(call_frame, FRAME_HEADER_SIZE + 16, 0)
	byte_order.write_u32_little_endian(call_frame, FRAME_HEADER_SIZE + 8, 0)
	expect_refusal(t, exchange(home, identity_of(laptop), call_frame), .Malformed, 0)
	// A machine that is not paired gets no role.
	expect_refusal(t, exchange(home, [32]u8{0 = 3}, role_call_write(request[:], Role_Call{identifier = 9, role = .Storage, export = 1})), .Not_Paired, 0)
	testing.expect(t, !machine_grant_set(&home.peer, identity_of(laptop), {.Roles}, {.None}))
	testing.expect(t, !machine_grant_set(&home.peer, identity_of(laptop), {.Roles}, {}))
	testing.expect(t, !machine_grant_set(&home.peer, identity_of(laptop), {.Objects}, {.Storage}))
	testing.expect(t, machine_grant_set(&home.peer, identity_of(laptop), {}, {}))
	expect_refusal(t, exchange(home, identity_of(laptop), role_call_write(request[:], Role_Call{identifier = 9, role = .Storage, export = 1})), .Use_Not_Granted, u32(Machine_Use.Roles))
}

// ---- Signed grants ----

@(private = "file")
sign_grant :: proc(grant: ^machine_mesh.Signed_Grant, signing_key: ^ed25519.Private_Key) {
	bytes, status := machine_mesh.signed_grant_signing_bytes(grant)
	assert(status == .Accepted)
	ed25519.sign(signing_key, bytes[:], grant.signature[:])
}

@(test)
signed_grant_holds_for_a_day_and_refuses_expired_revoked_and_forged :: proc(t: ^testing.T) {
	home := machine_make(0x31)
	presenter := machine_make(0x32)
	defer machine_free(home, presenter)
	root_key, root_public := key_pair(0x41)
	signing_key, signing_public := key_pair(0x51)
	_, transport_public := key_pair(0x61)
	_, receiver_root := key_pair(0x71)
	_, other_root := key_pair(0x81)
	now := u64(50_000)
	request: [FRAME_LIMIT]u8

	grant := machine_mesh.Signed_Grant {
		grant_serial               = 7,
		grantor_root_public_key    = root_public,
		grantor_signing_public_key = signing_public,
		serving_machine_id         = identity_of(home),
		grantee_root_public_key    = receiver_root,
		target_kind                = .Store_Object,
		target_hash                = object_hash("notes"),
		rights                     = {.Read},
		issued_at_ms               = now,
		expires_at_ms              = now + machine_mesh.MAX_SHORT_GRANT_LIFE_MS,
	}
	sign_grant(&grant, &signing_key)
	present, _ := grant_present_write(request[:], &grant)

	// A machine that is not paired, then paired with no use Grants, presents nothing.
	expect_refusal(t, exchange(home, identity_of(presenter), present, now, receiver_root), .Not_Paired, 0)
	testing.expect(t, pair(t, home, presenter, now))
	expect_refusal(t, exchange(home, identity_of(presenter), present, now, receiver_root), .Use_Not_Granted, u32(Machine_Use.Grants))
	grant_uses(t, home, presenter, {.Grants})
	// No principal that the transport proved: nothing is checked.
	expect_refusal(t, exchange(home, identity_of(presenter), present, now, {}), .No_Principal, 0)

	// No machine list yet: no grant holds.
	expect_refusal(t, exchange(home, identity_of(presenter), present, now, receiver_root), .Grant_Refused, u32(machine_mesh.Grant_Check_Status.Refused_Grantor_Key_Not_Active))

	// The machine list of the principal of home names home and its signing key.
	list := machine_mesh.Signed_Machine_List{principal_root_public_key = root_public, sequence_number = 1, entry_count = 1}
	list.entries[0] = machine_mesh.Machine_Entry{machine_id = identity_of(home), signing_public_key = signing_public, transport_public_key = transport_public, uses = {.Calls}, tpm_attested = true, state = .Active, added_at_ms = 1}
	list_bytes: [machine_mesh.MAX_MACHINE_LIST_SIGNING_BYTES]u8
	written, _ := machine_mesh.machine_list_signing_bytes(&list, list_bytes[:])
	ed25519.sign(&root_key, list_bytes[:written], list.signature[:])
	testing.expect(t, machine_mesh.machine_list_holder_init(&home.peer.machine_list, root_public))
	list_status, _, _, _ := machine_mesh.machine_list_holder_update(&home.peer.machine_list, &home.peer.paired, identity_of(home), &list, {}, verify_ed25519, now)
	testing.expect_value(t, list_status, machine_mesh.Machine_List_Status.Accepted)

	// A grant of exactly one day holds, for the receiver that the handshake proved.
	serial, expires, _, _, accepted := grant_accepted_read(exchange(home, identity_of(presenter), present, now, receiver_root))
	testing.expect(t, accepted && serial == 7 && expires == now + machine_mesh.MAX_SHORT_GRANT_LIFE_MS)
	serial, _, _, _, accepted = grant_accepted_read(exchange(home, identity_of(presenter), present, now + machine_mesh.MAX_SHORT_GRANT_LIFE_MS - 1, receiver_root))
	testing.expect(t, accepted)
	// At its end time, before its start, for another receiver, for no receiver.
	expect_refusal(t, exchange(home, identity_of(presenter), present, now + machine_mesh.MAX_SHORT_GRANT_LIFE_MS, receiver_root), .Grant_Refused, u32(machine_mesh.Grant_Check_Status.Refused_Expired))
	expect_refusal(t, exchange(home, identity_of(presenter), present, now - 1, receiver_root), .Grant_Refused, u32(machine_mesh.Grant_Check_Status.Refused_Not_Yet_Valid))
	expect_refusal(t, exchange(home, identity_of(presenter), present, now, other_root), .Grant_Refused, u32(machine_mesh.Grant_Check_Status.Refused_Wrong_Grantee))
	answer: []u8
	reason: Refusal_Reason

	// One millisecond over a day with no revocation list.
	long := grant
	long.grant_serial = 8
	long.expires_at_ms = now + machine_mesh.MAX_SHORT_GRANT_LIFE_MS + 1
	sign_grant(&long, &signing_key)
	present, _ = grant_present_write(request[:], &long)
	expect_refusal(t, exchange(home, identity_of(presenter), present, now, receiver_root), .Grant_Refused, u32(machine_mesh.Grant_Check_Status.Refused_Long_Grant_Without_Revocation))

	// A long grant under a revocation list: it holds, until its serial is revoked.
	long.revocation_list_epoch = 1
	long.expires_at_ms = now + 30 * machine_mesh.MAX_SHORT_GRANT_LIFE_MS
	sign_grant(&long, &signing_key)
	revocations := machine_mesh.Revocation_List{grantor_root_public_key = root_public, signer_public_key = signing_public, epoch = 1}
	revocation_bytes: [machine_mesh.MAX_REVOCATION_LIST_SIGNING_BYTES]u8
	revocation_written, _ := machine_mesh.revocation_list_signing_bytes(&revocations, revocation_bytes[:])
	ed25519.sign(&signing_key, revocation_bytes[:revocation_written], revocations.signature[:])
	testing.expect_value(t, machine_mesh.revocation_list_apply_update(&home.peer.machine_list.list, &home.peer.revocations, false, &revocations, verify_ed25519), machine_mesh.Revocation_List_Status.Accepted)
	home.peer.has_revocations = true
	present, _ = grant_present_write(request[:], &long)
	_, _, _, _, accepted = grant_accepted_read(exchange(home, identity_of(presenter), present, now, receiver_root))
	testing.expect(t, accepted)
	revoked := machine_mesh.Revocation_List{grantor_root_public_key = root_public, signer_public_key = signing_public, epoch = 2, revoked_count = 1}
	revoked.revoked_serials[0] = 8
	revocation_written, _ = machine_mesh.revocation_list_signing_bytes(&revoked, revocation_bytes[:])
	ed25519.sign(&signing_key, revocation_bytes[:revocation_written], revoked.signature[:])
	testing.expect_value(t, machine_mesh.revocation_list_apply_update(&home.peer.machine_list.list, &home.peer.revocations, true, &revoked, verify_ed25519), machine_mesh.Revocation_List_Status.Accepted)
	expect_refusal(t, exchange(home, identity_of(presenter), present, now, receiver_root), .Grant_Refused, u32(machine_mesh.Grant_Check_Status.Refused_Revoked))

	// A forged grant: one byte of the signature, one byte of the target, a grant signed by another key.
	present, _ = grant_present_write(request[:], &grant)
	for place in ([?]int{len(present) - 1, FRAME_HEADER_SIZE + 4 + 1 + 1 + 2 + 8 + 128}) {
		forged: [FRAME_LIMIT]u8
		copy(forged[:], present)
		forged[place] ~= 0x01
		answer = exchange(home, identity_of(presenter), forged[:len(present)], now, receiver_root)
		_, reason, _, _ = answer_expect(answer, .Grant_Accepted)
		testing.expect_value(t, reason, Refusal_Reason.Grant_Refused)
	}
	other_signer, _ := key_pair(0x91)
	forged_grant := grant
	sign_grant(&forged_grant, &other_signer)
	present, _ = grant_present_write(request[:], &forged_grant)
	expect_refusal(t, exchange(home, identity_of(presenter), present, now, receiver_root), .Grant_Refused, u32(machine_mesh.Grant_Check_Status.Refused_Invalid_Signature))
	// A body of another size.
	present, _ = grant_present_write(request[:], &grant)
	shorter := present[:len(present) - 1]
	byte_order.write_u32_little_endian(shorter, 8, u32(len(shorter) - FRAME_HEADER_SIZE))
	answer = exchange(home, identity_of(presenter), shorter, now, receiver_root)
	_, reason, _, _ = answer_expect(answer, .Grant_Accepted)
	testing.expect_value(t, reason, Refusal_Reason.Grant_Refused)
}

// ---- The relay ----

@(private = "file")
seal :: proc(key: [32]u8, token: Routing_Token, nonce_seed: u8, plaintext: []u8, output: []u8) -> []u8 {
	key_copy, token_copy := key, token
	aead: chacha20poly1305.Context
	chacha20poly1305.init(&aead, key_copy[:])
	nonce := output[:RELAY_NONCE_SIZE]
	for index in 0 ..< RELAY_NONCE_SIZE {
		nonce[index] = nonce_seed + u8(index)
	}
	ciphertext := output[RELAY_NONCE_SIZE:][:len(plaintext)]
	tag := output[RELAY_NONCE_SIZE + len(plaintext):][:RELAY_TAG_SIZE]
	chacha20poly1305.seal(&aead, ciphertext, tag, nonce, token_copy[:], plaintext)
	return output[:RELAY_NONCE_SIZE + len(plaintext) + RELAY_TAG_SIZE]
}

@(private = "file")
open :: proc(key: [32]u8, token: Routing_Token, sealed: []u8, output: []u8) -> (plaintext: []u8, ok: bool) {
	key_copy, token_copy := key, token
	aead: chacha20poly1305.Context
	chacha20poly1305.init(&aead, key_copy[:])
	count := len(sealed) - RELAY_NONCE_SIZE - RELAY_TAG_SIZE
	ok = chacha20poly1305.open(&aead, output[:count], sealed[:RELAY_NONCE_SIZE], token_copy[:], sealed[RELAY_NONCE_SIZE:][:count], sealed[RELAY_NONCE_SIZE + count:])
	return output[:count], ok
}

@(private = "file")
contains :: proc(haystack: []u8, needle: []u8) -> bool {
	if len(needle) == 0 || len(needle) > len(haystack) {
		return false
	}
	for start in 0 ..= len(haystack) - len(needle) {
		if string(haystack[start:][:len(needle)]) == string(needle) {
			return true
		}
	}
	return false
}

@(test)
relay_carries_sealed_bytes_unchanged_and_refuses_malformed_envelopes :: proc(t: ^testing.T) {
	relay := machine_make(0x13)
	laptop := machine_make(0x23)
	desktop := machine_make(0x33)
	intruder := machine_make(0x43)
	defer machine_free(relay, laptop, desktop, intruder)
	testing.expect(t, pair(t, relay, laptop, 1_000))
	testing.expect(t, pair(t, relay, desktop, 2_000))
	testing.expect(t, pair(t, relay, intruder, 3_000))
	testing.expect(t, relay.peer.spent_codes.count == 3)
	grant_uses(t, relay, laptop, {.Relay})
	grant_uses(t, relay, desktop, {.Relay})
	grant_uses(t, relay, intruder, {.Relay})

	// The key of the two end machines: the relay never holds it.
	shared_key := object_hash("the key of laptop and desktop")
	token := relay_routing_token(shared_key, 1)
	testing.expect(t, token != relay_routing_token(shared_key, 2))
	testing.expect_value(t, relay_route_add(&relay.peer.relay, token, identity_of(laptop), identity_of(desktop)), Relay_Status.Ok)
	testing.expect_value(t, relay_route_add(&relay.peer.relay, token, identity_of(laptop), identity_of(desktop)), Relay_Status.Refused_Exists)
	testing.expect_value(t, relay_route_add(&relay.peer.relay, relay_routing_token(shared_key, 3), identity_of(laptop), identity_of(laptop)), Relay_Status.Refused_Bad_Ends)
	testing.expect_value(t, relay_route_add(&relay.peer.relay, relay_routing_token(shared_key, 3), {}, identity_of(desktop)), Relay_Status.Refused_Bad_Ends)
	testing.expect_value(t, relay_route_add(&relay.peer.relay, relay_routing_token(shared_key, 3), identity_of(laptop), {}), Relay_Status.Refused_Bad_Ends)

	plaintext := transmute([]u8)string("a datagram of the laptop for the desktop")
	sealed_bytes: [RELAY_SEALED_LIMIT]u8
	sealed := seal(shared_key, token, 1, plaintext, sealed_bytes[:])
	request: [FRAME_LIMIT]u8
	deposit, deposit_status := relay_envelope_write(request[:], .Relay_Deposit, token, sealed)
	testing.expect_value(t, deposit_status, Relay_Status.Ok)
	_, _, _, deposited := answer_expect(exchange(relay, identity_of(laptop), deposit), .Relay_Deposited)
	testing.expect(t, deposited)

	// What the relay holds: the token and the sealed bytes, no plaintext and no identity key.
	held := relay.peer.relay.routes[0].held[0]
	held_bytes := held.bytes[:held.count]
	testing.expect(t, !contains(held_bytes, plaintext))
	testing.expect(t, !contains(held_bytes, plaintext[:8]))
	laptop_identity, desktop_identity := identity_of(laptop), identity_of(desktop)
	testing.expect(t, !contains(held_bytes, laptop_identity[:]) && !contains(held_bytes, desktop_identity[:]))
	testing.expect(t, !contains(held_bytes, shared_key[:]))

	// Another paired machine that knows the token, and the receiver itself,
	// cannot deposit on the route; the sender, and that other machine,
	// cannot collect from it. Each gets the refusal of an unknown token,
	// and the envelope stays.
	collect: [FRAME_HEADER_SIZE + RELAY_COLLECT_BODY_SIZE]u8
	for depositor in ([?]^Machine{intruder, desktop}) {
		expect_refusal(t, exchange(relay, identity_of(depositor), deposit), .Relay_Refused, u32(Relay_Status.Refused_Unknown_Token))
	}
	for collector in ([?]^Machine{intruder, laptop}) {
		expect_refusal(t, exchange(relay, identity_of(collector), relay_collect_write(collect[:], token)), .Relay_Refused, u32(Relay_Status.Refused_Unknown_Token))
	}
	testing.expect_value(t, relay.peer.relay.routes[0].count, 1)

	// The desktop collects the same bytes, and opens them.
	delivery := exchange(relay, identity_of(desktop), relay_collect_write(collect[:], token))
	delivered_body, _, _, delivered := answer_expect(delivery, .Relay_Delivery)
	testing.expect(t, delivered && string(delivered_body) == string(deposit[FRAME_HEADER_SIZE:]))
	envelope, read_status := relay_envelope_read(delivered_body)
	testing.expect(t, read_status == .Ok && envelope.token == token)
	opened_bytes: [RELAY_SEALED_LIMIT]u8
	opened, opened_ok := open(shared_key, token, envelope.sealed, opened_bytes[:])
	testing.expect(t, opened_ok && string(opened) == string(plaintext))
	// One flipped bit of the sealed bytes, or another token as associated data: the end refuses it.
	flipped: [RELAY_SEALED_LIMIT]u8
	copy(flipped[:], envelope.sealed)
	flipped[RELAY_NONCE_SIZE + 3] ~= 0x10
	_, opened_ok = open(shared_key, token, flipped[:len(envelope.sealed)], opened_bytes[:])
	testing.expect(t, !opened_ok)
	_, opened_ok = open(shared_key, relay_routing_token(shared_key, 2), envelope.sealed, opened_bytes[:])
	testing.expect(t, !opened_ok)
	// Nothing waits any more.
	expect_refusal(t, exchange(relay, identity_of(desktop), relay_collect_write(collect[:], token)), .Relay_Refused, u32(Relay_Status.Refused_Empty))

	// Malformed tokens and envelopes.
	unknown := relay_routing_token(shared_key, 9)
	deposit, _ = relay_envelope_write(request[:], .Relay_Deposit, unknown, sealed)
	expect_refusal(t, exchange(relay, identity_of(laptop), deposit), .Relay_Refused, u32(Relay_Status.Refused_Unknown_Token))
	expect_refusal(t, exchange(relay, identity_of(desktop), relay_collect_write(collect[:], unknown)), .Relay_Refused, u32(Relay_Status.Refused_Unknown_Token))
	expect_refusal(t, exchange(relay, identity_of(desktop), relay_collect_write(collect[:], {})), .Relay_Refused, u32(Relay_Status.Refused_Zero_Token))
	_, write_status := relay_envelope_write(request[:], .Relay_Deposit, {}, sealed)
	testing.expect_value(t, write_status, Relay_Status.Refused_Zero_Token)
	_, write_status = relay_envelope_write(request[:], .Relay_Deposit, token, sealed[:RELAY_SEALED_MINIMUM - 1])
	testing.expect_value(t, write_status, Relay_Status.Refused_Too_Short)
	too_long: [RELAY_SEALED_LIMIT + 1]u8
	_, write_status = relay_envelope_write(request[:], .Relay_Deposit, token, too_long[:])
	testing.expect_value(t, write_status, Relay_Status.Refused_Too_Large)

	cases := [?]struct {
		change: proc(frame: []u8) -> int,
		status: Relay_Status,
	} {
		{proc(frame: []u8) -> int {for index in 0 ..< ROUTING_TOKEN_SIZE {frame[FRAME_HEADER_SIZE + index] = 0}; return len(frame)}, .Refused_Zero_Token},
		{proc(frame: []u8) -> int {byte_order.write_u32_little_endian(frame, FRAME_HEADER_SIZE + 16, u32(len(frame)));return len(frame)}, .Refused_Length_Differs},
		{proc(frame: []u8) -> int {byte_order.write_u32_little_endian(frame, FRAME_HEADER_SIZE + 20, 1);return len(frame)}, .Refused_Reserved_Set},
		{proc(frame: []u8) -> int {
				count := FRAME_HEADER_SIZE + RELAY_ENVELOPE_HEADER_SIZE + RELAY_SEALED_MINIMUM - 1
				byte_order.write_u32_little_endian(frame, 8, u32(count - FRAME_HEADER_SIZE))
				byte_order.write_u32_little_endian(frame, FRAME_HEADER_SIZE + 16, RELAY_SEALED_MINIMUM - 1)
				return count
			}, .Refused_Too_Short},
		{proc(frame: []u8) -> int {
				count := FRAME_HEADER_SIZE + RELAY_ENVELOPE_HEADER_SIZE - 1
				byte_order.write_u32_little_endian(frame, 8, u32(count - FRAME_HEADER_SIZE))
				return count
			}, .Refused_Too_Short},
	}
	for item, index in cases {
		changed: [FRAME_LIMIT]u8
		deposit, _ = relay_envelope_write(changed[:], .Relay_Deposit, token, sealed)
		count := item.change(deposit)
		answer := exchange(relay, identity_of(laptop), changed[:count])
		_, reason, detail, _ := answer_expect(answer, .Relay_Deposited)
		testing.expectf(t, reason == .Relay_Refused && detail == u32(item.status), "case %d: %v %d", index, reason, detail)
	}
	testing.expect_value(t, relay.peer.relay.routes[0].count, 0)

	// The queue of a route is bounded: past it a deposit is refused, never dropped.
	for _ in 0 ..< RELAY_QUEUE_DEPTH {
		deposit, _ = relay_envelope_write(request[:], .Relay_Deposit, token, sealed)
		_, _, _, deposited = answer_expect(exchange(relay, identity_of(laptop), deposit), .Relay_Deposited)
		testing.expect(t, deposited)
	}
	deposit, _ = relay_envelope_write(request[:], .Relay_Deposit, token, sealed)
	expect_refusal(t, exchange(relay, identity_of(laptop), deposit), .Relay_Refused, u32(Relay_Status.Refused_Queue_Full))
	// The intruder cannot fill the queue nor empty it: only past the
	// lifetime of the envelopes does the route take a deposit again.
	expect_refusal(t, exchange(relay, identity_of(intruder), deposit), .Relay_Refused, u32(Relay_Status.Refused_Unknown_Token))
	expect_refusal(t, exchange(relay, identity_of(laptop), deposit, 1_000 + RELAY_ENVELOPE_LIFETIME_MS - 1), .Relay_Refused, u32(Relay_Status.Refused_Queue_Full))
	_, _, _, deposited = answer_expect(exchange(relay, identity_of(laptop), deposit, 1_000 + RELAY_ENVELOPE_LIFETIME_MS), .Relay_Deposited)
	testing.expect(t, deposited)
	testing.expect_value(t, relay.peer.relay.routes[0].count, 1)
	expect_refusal(t, exchange(relay, identity_of(desktop), relay_collect_write(collect[:], token), 1_000 + 2 * RELAY_ENVELOPE_LIFETIME_MS), .Relay_Refused, u32(Relay_Status.Refused_Empty))
	// A machine that is not paired with the relay can neither deposit nor collect.
	stranger := [32]u8{0 = 0x99}
	expect_refusal(t, exchange(relay, stranger, deposit), .Not_Paired, 0)
	expect_refusal(t, exchange(relay, stranger, relay_collect_write(collect[:], token)), .Not_Paired, 0)
	// A collect body of another size.
	bad_collect := relay_collect_write(collect[:], token)
	byte_order.write_u32_little_endian(bad_collect, 8, RELAY_COLLECT_BODY_SIZE - 1)
	expect_refusal(t, exchange(relay, identity_of(desktop), bad_collect[:len(bad_collect) - 1]), .Malformed, 0)
	// The route ends: what waited on it is erased.
	testing.expect_value(t, relay_route_remove(&relay.peer.relay, token), Relay_Status.Ok)
	testing.expect_value(t, relay_route_remove(&relay.peer.relay, token), Relay_Status.Refused_Unknown_Token)
	testing.expect_value(t, relay_route_add(&relay.peer.relay, {}, identity_of(laptop), identity_of(desktop)), Relay_Status.Refused_Zero_Token)
	for index in 0 ..< RELAY_ROUTE_CAPACITY {
		testing.expect_value(t, relay_route_add(&relay.peer.relay, relay_routing_token(shared_key, u64(100 + index)), identity_of(laptop), identity_of(desktop)), Relay_Status.Ok)
	}
	testing.expect_value(t, relay_route_add(&relay.peer.relay, relay_routing_token(shared_key, 200), identity_of(laptop), identity_of(desktop)), Relay_Status.Refused_Table_Full)
}
// ---- Authorization of each request ----

// One request of each message that is not a pairing step.
@(private = "file")
Request_Case :: struct {
	message: Message,
	use:     Machine_Use,
}

@(private = "file")
REQUEST_CASES := [?]Request_Case {
	{.Object_Request, .Objects},
	{.Store_Offer, .Stores},
	{.Role_Call, .Roles},
	{.Relay_Deposit, .Relay},
	{.Relay_Collect, .Relay},
	{.Grant_Present, .Grants},
}

@(private = "file")
request_of :: proc(message: Message, output: []u8) -> []u8 {
	token := relay_routing_token(object_hash("a key"), 1)
	#partial switch message {
	case .Object_Request:
		return object_request_write(output, .Blob, object_hash("an object"))
	case .Store_Offer:
		store := Exchanged_Store{in_use = true, store_identifier = object_hash("notes")}
		store_write(&store, object_hash("a"), object_hash("a, 1"))
		return store_offer_begin(&store, output)
	case .Role_Call:
		return role_call_write(output, Role_Call{identifier = 1, role = .Storage, export = 1})
	case .Relay_Deposit:
		sealed: [RELAY_SEALED_MINIMUM + 4]u8
		frame, _ := relay_envelope_write(output, .Relay_Deposit, token, sealed[:])
		return frame
	case .Relay_Collect:
		return relay_collect_write(output, token)
	case .Grant_Present:
		body, _ := frame_begin(output, .Grant_Present, machine_mesh.SIGNED_GRANT_WIRE_SIZE)
		return frame_bytes(output, body)
	}
	return nil
}

@(test)
each_request_needs_a_pairing_and_its_use :: proc(t: ^testing.T) {
	home := machine_make(0x15)
	laptop := machine_make(0x25)
	joiner := machine_make(0x35)
	defer machine_free(home, laptop, joiner)
	testing.expect(t, pair(t, home, laptop, 1_000))
	store, _ := store_exchange_add(&home.peer.stores, object_hash("notes"), identity_of(laptop))
	store_write(store, object_hash("a"), object_hash("a, home"))
	token := relay_routing_token(object_hash("a key"), 1)
	relay_route_add(&home.peer.relay, token, identity_of(laptop), identity_of(joiner))
	home_publish(home, transmute([]u8)string("an object"))
	root := [32]u8{0 = 5, 31 = 5}

	// (a) An open offer admits any key for its pairing steps, and for
	// nothing else: each other request is refused before any table is read.
	machine_mesh.pairing_offer(&home.peer.pairing, identity_of(home), [8]u8{4, 4, 4, 4, 5, 6, 7, 8}, 1_000)
	testing.expect(t, peer_admits(&home.peer, identity_of(joiner), 1_000))
	store_before, relay_before, objects_before := store^, home.peer.relay, home.peer.objects.count
	request: [FRAME_LIMIT]u8
	for item in REQUEST_CASES {
		expect_refusal(t, exchange(home, identity_of(joiner), request_of(item.message, request[:]), 1_000, root), .Not_Paired, 0)
	}
	testing.expect(t, store^ == store_before && home.peer.relay == relay_before && home.peer.objects.count == objects_before)
	testing.expect_value(t, home.peer.pairing.phase, machine_mesh.Pairing_Phase.Code_Ready)

	// (b) A paired machine with no grant, then with one use at a time: each
	// request of another use is refused with that use, and changes nothing.
	for item in REQUEST_CASES {
		expect_refusal(t, exchange(home, identity_of(laptop), request_of(item.message, request[:]), 1_000, root), .Use_Not_Granted, u32(item.use))
	}
	for granted in Machine_Use {
		roles: Role_Set = granted == .Roles ? {.Display} : {}
		grant_uses(t, home, laptop, {granted}, roles)
		for item in REQUEST_CASES {
			answer := exchange(home, identity_of(laptop), request_of(item.message, request[:]), 1_000, root)
			_, reason, detail, _ := answer_expect(answer, .Refusal)
			if item.use == granted {
				testing.expectf(t, reason != .Use_Not_Granted && reason != .Not_Paired, "%v with %v: %v", item.message, granted, reason)
			} else {
				testing.expectf(t, reason == .Use_Not_Granted && detail == u32(item.use), "%v with %v: %v %d", item.message, granted, reason, detail)
			}
		}
	}
	// Only the request of the granted use changed a table: the laptop, the
	// sender of the route, deposited once with the use Relay.
	testing.expect_value(t, home.peer.relay.routes[0].count, 1)
	testing.expect_value(t, store.current.count, 1)

	// A grant outlives no pairing row.
	grant_uses(t, home, laptop, {.Objects})
	machine_mesh.paired_machine_remove(&home.peer.paired, identity_of(laptop))
	expect_refusal(t, exchange(home, identity_of(laptop), request_of(.Object_Request, request[:])), .Not_Paired, 0)
	_, found := machine_grant_of(&home.peer, identity_of(laptop))
	testing.expect(t, !found)

	// The border of the word of the uses.
	_, ok := machine_uses_of_word(1 << 5)
	testing.expect(t, !ok)
	_, ok = machine_uses_of_word(max(u32))
	testing.expect(t, !ok)
	uses, all_ok := machine_uses_of_word(transmute(u32)Machine_Uses{.Objects, .Grants})
	testing.expect(t, all_ok && uses == {.Objects, .Grants})
	testing.expect(t, !machine_grant_set(&home.peer, {}, {.Objects}, {}))
}

@(test)
an_abandoned_offer_admits_no_key_after_its_code_ends :: proc(t: ^testing.T) {
	home := machine_make(0x16)
	joiner := machine_make(0x26)
	defer machine_free(home, joiner)
	started := u64(10_000)
	ended := started + machine_mesh.PAIRING_CODE_LIFETIME_MS
	machine_mesh.pairing_offer(&home.peer.pairing, identity_of(home), [8]u8{6, 6, 3, 4, 5, 6, 7, 8}, started)

	testing.expect(t, peer_admits(&home.peer, identity_of(joiner), ended - 1))
	testing.expect(t, !peer_admits(&home.peer, identity_of(joiner), ended))
	// A clock before the offer is no time inside it.
	testing.expect(t, !peer_admits(&home.peer, identity_of(joiner), started - 1))
	testing.expect(t, !pairing_expire(&home.peer, ended - 1))
	testing.expect_value(t, home.peer.pairing.phase, machine_mesh.Pairing_Phase.Code_Ready)
	testing.expect(t, pairing_expire(&home.peer, ended))
	testing.expect_value(t, home.peer.pairing.phase, machine_mesh.Pairing_Phase.Failed)
	testing.expect(t, !pairing_expire(&home.peer, ended + 1))
	// Its secrets are gone, and a late element is refused.
	testing.expect(t, machine_mesh.bytes_all_zero(home.peer.pairing.code_secret[:]))
	request: [FRAME_LIMIT]u8
	body, _ := frame_begin(request[:], .Pairing_Element, PAIRING_ELEMENT_SIZE)
	expect_refusal(t, exchange(home, identity_of(joiner), frame_bytes(request[:], body), ended), .Pairing_Refused, u32(machine_mesh.Pairing_Status.Refused_Bad_Phase))
}
