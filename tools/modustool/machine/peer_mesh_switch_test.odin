package machine

import "core:testing"
import "modus:contract/blake3"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/machine_mesh"
import "modus:contract/machine_sync"
import "modus:contract/machine_wire"
import "modus:contract/remote"
import "modus:contract/role_contract"
import "modus:quic"
import "modus:random"
import "modustool:fuzz"

@(private = "file")
Switch_Capture :: struct {
	count:     int,
	last_from: int,
	last_len:  int,
	last_data: [MESH_SWITCH_DATA_LIMIT]u8,
}

@(private = "file")
switch_capture_cb :: proc(from_node: int, data: []u8, user_data: rawptr) {
	cap := (^Switch_Capture)(user_data)
	if cap == nil {
		return
	}
	cap.count += 1
	cap.last_from = from_node
	cap.last_len = copy(cap.last_data[:], data)
}

@(test)
test_mesh_switch_ports_and_nat_refusals :: proc(t: ^testing.T) {
	// Port border checks: negative, valid bounds, and past upper bound.
	_, ok_neg := mesh_switch_node_port(-1)
	testing.expect(t, !ok_neg, "negative node id refused")
	_, ok_over := mesh_switch_node_port(MESH_SWITCH_MAX_NODES)
	testing.expect(t, !ok_over, "node id at capacity refused")

	p0, ok0 := mesh_switch_node_port(0)
	testing.expect(t, ok0 && p0 == MESH_SWITCH_PORT_BASE)
	p_last, ok_last := mesh_switch_node_port(MESH_SWITCH_MAX_NODES - 1)
	testing.expect(t, ok_last && p_last == MESH_SWITCH_PORT_BASE + MESH_SWITCH_MAX_NODES - 1)

	_, low_ok := mesh_switch_node_of_port(MESH_SWITCH_PORT_BASE - 1)
	testing.expect(t, !low_ok)
	_, high_ok := mesh_switch_node_of_port(MESH_SWITCH_PORT_BASE + MESH_SWITCH_MAX_NODES)
	testing.expect(t, !high_ok)
	n0, n0_ok := mesh_switch_node_of_port(p0)
	testing.expect(t, n0_ok && n0 == 0)

	sw: Peer_Mesh_Switch
	mesh_switch_init(&sw)
	cap_a, cap_b: Switch_Capture

	// Attach refusals: nil switch, nil callback, out-of-range node, duplicate slot.
	testing.expect(t, !mesh_switch_attach_host(nil, 0, switch_capture_cb, &cap_a))
	testing.expect(t, !mesh_switch_attach_host(&sw, 0, nil, &cap_a))
	testing.expect(t, !mesh_switch_attach_host(&sw, -1, switch_capture_cb, &cap_a))
	testing.expect(t, !mesh_switch_attach_host(&sw, MESH_SWITCH_MAX_NODES, switch_capture_cb, &cap_a))
	testing.expect(t, mesh_switch_attach_host(&sw, 0, switch_capture_cb, &cap_a))
	testing.expect(t, !mesh_switch_attach_host(&sw, 0, switch_capture_cb, &cap_b), "duplicate node attachment refused")
	testing.expect(t, mesh_switch_attach_host(&sw, 1, switch_capture_cb, &cap_b))

	// NAT policy refusals: same node or out-of-range.
	testing.expect(t, !mesh_switch_set_nat_blocked(nil, 0, 1, true))
	testing.expect(t, !mesh_switch_set_nat_blocked(&sw, 0, 0, true))
	testing.expect(t, !mesh_switch_set_nat_blocked(&sw, -1, 1, true))
	testing.expect(t, !mesh_switch_set_nat_blocked(&sw, 0, MESH_SWITCH_MAX_NODES, true))

	// Direct delivery A -> B works.
	payload := transmute([]u8)string("hello-mesh-switch")
	testing.expect(t, mesh_switch_send_from_host(&sw, 0, 1, payload))
	testing.expect_value(t, cap_b.count, 1)
	testing.expect_value(t, cap_b.last_from, 0)
	testing.expect_value(t, string(cap_b.last_data[:cap_b.last_len]), "hello-mesh-switch")
	testing.expect_value(t, sw.forwarded, u64(1))

	// Oversized datagram is dropped and counted.
	oversized: [MESH_SWITCH_DATA_LIMIT + 1]u8
	testing.expect(t, mesh_switch_send_from_host(&sw, 0, 1, oversized[:]))
	testing.expect_value(t, cap_b.count, 1)
	testing.expect_value(t, sw.dropped_too_long, u64(1))

	// Unattached destination node is dropped and counted.
	testing.expect(t, mesh_switch_send_from_host(&sw, 0, 2, payload))
	testing.expect_value(t, sw.dropped_unknown, u64(1))

	// NAT block drops direct A <-> B in both directions.
	testing.expect(t, mesh_switch_set_nat_blocked(&sw, 0, 1, true))
	testing.expect(t, mesh_switch_send_from_host(&sw, 0, 1, payload))
	testing.expect(t, mesh_switch_send_from_host(&sw, 1, 0, payload))
	testing.expect_value(t, cap_b.count, 1)
	testing.expect_value(t, cap_a.count, 0)
	testing.expect_value(t, sw.dropped_nat, u64(2))

	// Non-switch port returns false so normal peer_remote traffic is untouched.
	testing.expect(t, !mesh_switch_forward_from_peer(&sw, 0, PEER_REMOTE_PORT_FIRST, payload))

	// Unblocking NAT restores direct B -> A delivery.
	testing.expect(t, mesh_switch_set_nat_blocked(&sw, 0, 1, false))
	testing.expect(t, mesh_switch_send_from_host(&sw, 1, 0, payload))
	testing.expect_value(t, cap_a.count, 1)
	testing.expect_value(t, cap_a.last_from, 1)
	testing.expect_value(t, sw.forwarded, u64(2))

	mesh_switch_detach_host(&sw, 0)
	mesh_switch_detach_host(&sw, 1)
}

// Synchronous QUIC client host node attached to Peer_Mesh_Switch for live
// end-to-end QUIC + TLS 1.3 + machine_wire tests without booting QEMU.
@(private = "file")
Test_Quic_Mesh_Client :: struct {
	sw:             ^Peer_Mesh_Switch,
	node_id:        int,
	target_node:    int,
	cryptography:   quic.Cryptography,
	generator:      random.Generator,
	private_key:    [32]u8,
	public_key:     [32]u8,
	conn:           quic.Connection,
	streams:        [4]quic.Stream,
	peer:           machine_wire.Peer,
	object_rows:    [32]machine_sync.Stored_Object,
	object_bytes:   [64 * 1024]u8,
	store_rows:     [4]machine_wire.Exchanged_Store,
	store_entries:  [256]machine_wire.Store_Entry,
	store_conflicts:[64]machine_wire.Store_Conflict,
	inbox:          [64]Host_Mesh_Inbox_Packet,
	inbox_head:     int,
	inbox_count:    int,
}

@(private = "file")
test_quic_client_recv_cb :: proc(from_node: int, data: []u8, user_data: rawptr) {
	c := (^Test_Quic_Mesh_Client)(user_data)
	if c == nil || c.inbox_count >= len(c.inbox) || len(data) > MESH_SWITCH_DATA_LIMIT {
		return
	}
	slot := (c.inbox_head + c.inbox_count) % len(c.inbox)
	c.inbox[slot].from_node = from_node
	c.inbox[slot].length = copy(c.inbox[slot].data[:], data)
	c.inbox_count += 1
}

@(private = "file")
test_client_sig_verify :: proc "contextless" (
	public_key: [machine_mesh.PUBLIC_KEY_SIZE]u8,
	message: []u8,
	signature: [machine_mesh.SIGNATURE_SIZE]u8,
	user_data: rawptr,
) -> bool {
	c := (^Test_Quic_Mesh_Client)(user_data)
	if c == nil {
		return false
	}
	k, s := public_key, signature
	kt, mt, st := string(k[:]), string(message), string(s[:])
	err: errors.Error_Record
	out, cnt := c.cryptography.ed25519_verify(&kt, &mt, &st, &err)
	return out == .Succeeded && cnt == 0
}

@(private = "file")
test_client_fill_random :: proc "contextless" (bytes: []u8, user_data: rawptr) -> bool {
	c := (^Test_Quic_Mesh_Client)(user_data)
	if c == nil {
		return false
	}
	err: errors.Error_Record
	return random.fill_for_a_key(&c.generator, bytes, .Processor, &err)
}

@(private = "file")
test_quic_client_init :: proc(c: ^Test_Quic_Mesh_Client, sw: ^Peer_Mesh_Switch, node_id: int, seed_byte: u8) -> bool {
	c^ = {sw = sw, node_id = node_id}
	c.cryptography = fuzz.quic_cryptography_of_the_host()
	seed: [random.SEED_SIZE]u8
	for i in 0 ..< random.SEED_SIZE {
		seed[i] = seed_byte + u8(i)
	}
	random.generator_seed(&c.generator, &seed, .Processor)
	err: errors.Error_Record
	if !random.fill_for_a_key(&c.generator, c.private_key[:], .Processor, &err) {
		return false
	}
	sec := string(c.private_key[:])
	pub := c.public_key[:]
	if out, cnt := c.cryptography.ed25519_public_key(&sec, &pub, &err); out != .Succeeded || cnt != 32 {
		return false
	}
	services := machine_wire.Peer_Services {
		signature_verify = test_client_sig_verify,
		fill_random      = test_client_fill_random,
		user_data        = c,
	}
	memory := machine_wire.Peer_Memory {
		object_rows     = c.object_rows[:],
		object_bytes    = c.object_bytes[:],
		stores          = c.store_rows[:],
		store_entries   = c.store_entries[:],
		store_conflicts = c.store_conflicts[:],
	}
	if !machine_wire.peer_init(&c.peer, c.public_key, services, memory) {
		return false
	}
	return mesh_switch_attach_host(sw, node_id, test_quic_client_recv_cb, c)
}

@(private = "file")
test_quic_client_pump :: proc(c: ^Test_Quic_Mesh_Client, server_a: ^Host_Mesh_Relay, relay_r: ^Host_Mesh_Relay, now_us: ^u64) {
	for _ in 0 ..< 8 {
		now_us^ += 1000
		// Drain client inbox into QUIC client connection.
		for c.inbox_count > 0 {
			pkt := c.inbox[c.inbox_head]
			c.inbox_head = (c.inbox_head + 1) % len(c.inbox)
			c.inbox_count -= 1
			err: errors.Error_Record
			quic.connection_datagram_receive(&c.conn, pkt.data[:pkt.length], now_us^, &err)
		}
		quic.connection_time_passes(&c.conn, now_us^)
		out_buf: [quic.MAX_DATAGRAM_SIZE]u8
		for _ in 0 ..< 16 {
			if c.conn.state == .Idle || c.conn.state == .Closed {
				break
			}
			n := quic.connection_datagram_send(&c.conn, out_buf[:], now_us^)
			if n <= 0 {
				break
			}
			mesh_switch_send_from_host(c.sw, c.node_id, c.target_node, out_buf[:n])
		}
		if server_a != nil {
			host_mesh_relay_tick(server_a, now_us^)
		}
		if relay_r != nil {
			host_mesh_relay_tick(relay_r, now_us^)
		}
	}
}

@(private = "file")
test_quic_connect :: proc(c: ^Test_Quic_Mesh_Client, server_a: ^Host_Mesh_Relay, relay_r: ^Host_Mesh_Relay, target_node: int, target_key: [32]u8, now_us: ^u64) -> bool {
	c.target_node = target_node
	cfg := quic.Connection_Configuration{idle_timeout_milliseconds = 30_000}
	cfg.tls = {
		role               = .Client,
		least_seed_strength = .Processor,
		server_public_key  = target_key,
		client_private_key = c.private_key,
	}
	cfg.tls.application_protocol_length = copy(cfg.tls.application_protocol[:], remote.APPLICATION_PROTOCOL)
	err: errors.Error_Record
	if !quic.connection_start_client(&c.conn, c.streams[:], &cfg, &c.cryptography, &c.generator, now_us^, &err) {
		return false
	}
	for _ in 0 ..< 64 {
		test_quic_client_pump(c, server_a, relay_r, now_us)
		if c.conn.state == .Connected {
			return true
		}
		if c.conn.state == .Closed || c.conn.state == .Closing || c.conn.state == .Draining {
			return false
		}
	}
	return false
}

@(private = "file")
test_quic_round_trip :: proc(c: ^Test_Quic_Mesh_Client, server_a: ^Host_Mesh_Relay, relay_r: ^Host_Mesh_Relay, request: []u8, answer_buf: []u8, now_us: ^u64) -> (ans_len: int, ok: bool) {
	stream_id, opened := quic.stream_open(&c.conn)
	if !opened {
		return 0, false
	}
	written := 0
	received := 0
	for _ in 0 ..< 128 {
		if written < len(request) {
			written += quic.stream_write(&c.conn, stream_id, request[written:], true)
		}
		test_quic_client_pump(c, server_a, relay_r, now_us)
		n, finished, reset := quic.stream_read(&c.conn, stream_id, answer_buf[received:])
		received += n
		if reset {
			return 0, false
		}
		if finished {
			return received, true
		}
	}
	return 0, false
}

@(private = "file")
test_role_holder :: proc "contextless" (role: role_contract.Role, export: u32, arguments: []u8, result: []u8, _: rawptr) -> (value: i64, result_count: int, outcome: call_outcome.Call_Outcome) {
	if role != .Recipes {
		return 0, 0, .Operation_Unsupported
	}
	if export != 1 {
		return 0, 0, .Operation_Unsupported
	}
	msg := "recipes-ok"
	copied := copy(result, msg)
	return 42 + i64(len(arguments)), copied, .Succeeded
}

// Exercises real modus:quic + TLS 1.3 mutual raw-public-key auth +
// machine_wire.Peer over Peer_Mesh_Switch for: unpaired handshake refusal,
// wrong-code CPace refusal, valid CPace pairing, multi-chunk (>16 KiB) object
// exchange, remote role call dispatch + refusal, store sync with conflict and
// resolution, and NAT-isolated ChaCha20-Poly1305 sealed relay forwarding.
@(test)
test_live_quic_two_machine_mesh_and_nat_relay :: proc(t: ^testing.T) {
	sw: Peer_Mesh_Switch
	mesh_switch_init(&sw)

	server_a, a_ok := host_mesh_relay_make(&sw, 0, seed_byte = 0x11)
	testing.expect(t, a_ok)
	if !a_ok {
		return
	}
	defer host_mesh_relay_stop(server_a)
	server_a.peer.services.role_holder = test_role_holder

	relay_r, r_ok := host_mesh_relay_make(&sw, 2, seed_byte = 0x33)
	testing.expect(t, r_ok)
	if !r_ok {
		return
	}
	defer host_mesh_relay_stop(relay_r)

	client_b := new(Test_Quic_Mesh_Client)
	defer {
		mesh_switch_detach_host(&sw, 1)
		free(client_b)
	}
	testing.expect(t, test_quic_client_init(client_b, &sw, 1, seed_byte = 0x22))

	now_us: u64 = 1_000_000

	// 1. Unpaired peer is refused in the QUIC TLS 1.3 handshake before any stream.
	testing.expect(t, !test_quic_connect(client_b, server_a, relay_r, 0, server_a.public_key, &now_us), "unpaired client refused at TLS handshake")

	// 2. Wrong CPace code is refused over real QUIC and leaves neither side paired.
	rand_wrong: [8]u8 = {1, 3, 5, 7, 9, 11, 13, 15}
	_, offer_wrong_status := host_mesh_relay_offer_pairing(server_a, rand_wrong, {.Calls}, now_us / 1000)
	testing.expect_value(t, offer_wrong_status, machine_mesh.Pairing_Status.Ok)
	client_b.peer.pairing_uses = {.Calls}
	testing.expect_value(t, machine_mesh.pairing_join(&client_b.peer.pairing, client_b.public_key, transmute([]u8)string("AAAAAAAAAB"), now_us / 1000), machine_mesh.Pairing_Status.Ok)
	testing.expect(t, test_quic_connect(client_b, server_a, relay_r, 0, server_a.public_key, &now_us))

	req_buf: [machine_wire.FRAME_LIMIT]u8
	ans_buf: [machine_wire.FRAME_LIMIT]u8
	binding := machine_wire.channel_binding_of_identities(server_a.public_key, client_b.public_key)
	el_frame, el_st := machine_wire.pairing_element_write(&client_b.peer, server_a.public_key, binding, now_us / 1000, req_buf[:])
	testing.expect_value(t, el_st, machine_mesh.Pairing_Status.Ok)
	ans_len, rt_ok := test_quic_round_trip(client_b, server_a, relay_r, el_frame, ans_buf[:], &now_us)
	testing.expect(t, rt_ok)
	confirm_frame, confirm_st := machine_wire.pairing_element_reply_accept(&client_b.peer, ans_buf[:ans_len], now_us / 1000, req_buf[:])
	testing.expect_value(t, confirm_st, machine_mesh.Pairing_Status.Refused_Confirmation_Failed)
	testing.expect(t, confirm_frame != nil)
	_, _ = test_quic_round_trip(client_b, server_a, relay_r, confirm_frame, ans_buf[:], &now_us)
	_, paired_a_wrong := machine_mesh.paired_machine_find(&server_a.peer.paired, client_b.public_key)
	_, paired_b_wrong := machine_mesh.paired_machine_find(&client_b.peer.paired, server_a.public_key)
	testing.expect(t, !paired_a_wrong && !paired_b_wrong, "wrong pairing code leaves neither side paired")

	// 3. Valid CPace pairing over real QUIC succeeds and derives matching relay_key.
	rand_good: [8]u8 = {2, 4, 6, 8, 10, 12, 14, 16}
	good_code, offer_good_status := host_mesh_relay_offer_pairing(server_a, rand_good, {.Calls}, now_us / 1000)
	testing.expect_value(t, offer_good_status, machine_mesh.Pairing_Status.Ok)
	testing.expect_value(t, machine_mesh.pairing_join(&client_b.peer.pairing, client_b.public_key, good_code[:], now_us / 1000), machine_mesh.Pairing_Status.Ok)
	testing.expect(t, test_quic_connect(client_b, server_a, relay_r, 0, server_a.public_key, &now_us))

	el_frame, el_st = machine_wire.pairing_element_write(&client_b.peer, server_a.public_key, binding, now_us / 1000, req_buf[:])
	testing.expect_value(t, el_st, machine_mesh.Pairing_Status.Ok)
	ans_len, rt_ok = test_quic_round_trip(client_b, server_a, relay_r, el_frame, ans_buf[:], &now_us)
	testing.expect(t, rt_ok)
	confirm_frame, confirm_st = machine_wire.pairing_element_reply_accept(&client_b.peer, ans_buf[:ans_len], now_us / 1000, req_buf[:])
	testing.expect_value(t, confirm_st, machine_mesh.Pairing_Status.Ok)
	ans_len, rt_ok = test_quic_round_trip(client_b, server_a, relay_r, confirm_frame, ans_buf[:], &now_us)
	testing.expect(t, rt_ok)
	_, _, confirmed_ok := machine_wire.pairing_confirmed_accept(&client_b.peer, server_a.public_key, ans_buf[:ans_len])
	testing.expect(t, confirmed_ok, "pairing confirmed over live QUIC")

	row_a, found_a := machine_mesh.paired_machine_find(&server_a.peer.paired, client_b.public_key)
	row_b, found_b := machine_mesh.paired_machine_find(&client_b.peer.paired, server_a.public_key)
	testing.expect(t, found_a && found_b)
	testing.expect_value(t, row_a.transcript_fingerprint, row_b.transcript_fingerprint)
	// Metadata copies never expose relay_key.
	testing.expect(t, machine_mesh.key_is_zero(row_a.relay_key) && machine_mesh.key_is_zero(row_b.relay_key))
	relay_key_a, rka_ok := machine_mesh.paired_machine_relay_key(&server_a.peer.paired, client_b.public_key)
	relay_key_b, rkb_ok := machine_mesh.paired_machine_relay_key(&client_b.peer.paired, server_a.public_key)
	defer machine_mesh.clear_bytes_explicitly(relay_key_a[:])
	defer machine_mesh.clear_bytes_explicitly(relay_key_b[:])
	testing.expect(t, rka_ok && rkb_ok)
	testing.expect_value(t, relay_key_a, relay_key_b)
	testing.expect(t, !machine_mesh.key_is_zero(relay_key_a))
	testing.expect(t, relay_key_a != row_a.transcript_fingerprint)

	// 4. Grant uses & roles on Server A, reconnect as Paired peer, and test object exchange (24 KiB multi-chunk).
	testing.expect(t, host_mesh_relay_grant_peer(server_a, client_b.public_key, {.Objects, .Stores, .Roles, .Relay}, {.Recipes}))
	testing.expect(t, test_quic_connect(client_b, server_a, relay_r, 0, server_a.public_key, &now_us))

	big_obj: [24 * 1024]u8
	for i in 0 ..< len(big_obj) {
		big_obj[i] = u8((i * 37 + 11) & 0xFF)
	}
	big_hash := blake3.hash(big_obj[:])
	testing.expect_value(t, machine_wire.object_publish(&server_a.peer, .Blob, big_hash, big_obj[:]), machine_sync.Object_Store_Status.Stored)

	offset: u64 = 0
	for {
		req := machine_wire.object_request_write(req_buf[:], .Blob, big_hash, offset)
		ans_len, rt_ok = test_quic_round_trip(client_b, server_a, relay_r, req, ans_buf[:], &now_us)
		testing.expect(t, rt_ok)
		f_st, _, next_off := machine_wire.object_response_accept(&client_b.peer, .Blob, big_hash, ans_buf[:ans_len], offset)
		if f_st == .Partial {
			offset = next_off
			continue
		}
		testing.expect_value(t, f_st, machine_wire.Object_Fetch_Status.Stored)
		break
	}
	fetched := machine_wire.object_lookup(&client_b.peer, big_hash)
	testing.expect_value(t, len(fetched), len(big_obj))
	testing.expect_value(t, blake3.hash(fetched), big_hash)

	// 5. Remote role call over QUIC: ungranted Display refused, granted Recipes succeeds.
	bad_role_req := machine_wire.role_call_write(req_buf[:], {identifier = 1, role = .Display, export = 0})
	ans_len, rt_ok = test_quic_round_trip(client_b, server_a, relay_r, bad_role_req, ans_buf[:], &now_us)
	testing.expect(t, rt_ok)
	bad_frame, bad_f_st := machine_wire.frame_decode(ans_buf[:ans_len])
	testing.expect(t, bad_f_st == .Ok && bad_frame.message == .Refusal)

	good_role_req := machine_wire.role_call_write(req_buf[:], {identifier = 2, role = .Recipes, export = 1, flags = {.Idempotent}, arguments = transmute([]u8)string("abc")})
	ans_len, rt_ok = test_quic_round_trip(client_b, server_a, relay_r, good_role_req, ans_buf[:], &now_us)
	testing.expect(t, rt_ok)
	good_frame, good_f_st := machine_wire.frame_decode(ans_buf[:ans_len])
	testing.expect(t, good_f_st == .Ok && good_frame.message == .Role_Reply)
	reply, rep_ok := machine_wire.role_reply_read(good_frame.body)
	testing.expect(t, rep_ok && reply.outcome == .Succeeded && reply.value == 45 && string(reply.result) == "recipes-ok")

	// 6. Store exchange over QUIC: fast-forward, concurrent conflict, and single resolution.
	store_id := blake3.hash(transmute([]u8)string("notes"))
	doc_id := blake3.hash(transmute([]u8)string("doc1"))
	store_a, sa_st := machine_wire.store_exchange_add(&server_a.peer.stores, store_id, client_b.public_key)
	store_b, sb_st := machine_wire.store_exchange_add(&client_b.peer.stores, store_id, server_a.public_key)
	testing.expect(t, sa_st == .Ok && sb_st == .Ok)
	testing.expect_value(t, machine_wire.store_write(store_a, doc_id, blake3.hash(transmute([]u8)string("v1"))), machine_wire.Store_Status.Ok)

	sync_once :: proc(t: ^testing.T, client_b: ^Test_Quic_Mesh_Client, server_a, relay_r: ^Host_Mesh_Relay, store_b: ^machine_wire.Exchanged_Store, req_buf, ans_buf: []u8, now_us: ^u64) {
		req := machine_wire.store_offer_begin(store_b, req_buf)
		for {
			al, ok := test_quic_round_trip(client_b, server_a, relay_r, req, ans_buf, now_us)
			testing.expect(t, ok)
			st, _, _, more := machine_wire.store_offer_reply_accept(store_b, ans_buf[:al])
			testing.expect_value(t, st, machine_wire.Store_Status.Ok)
			if !more {
				break
			}
			req = machine_wire.store_offer_next(store_b, req_buf)
		}
	}
	sync_once(t, client_b, server_a, relay_r, store_b, req_buf[:], ans_buf[:], &now_us)
	testing.expect_value(t, store_b.current.count, 1)
	testing.expect_value(t, machine_wire.store_version_hash(&store_a.current), machine_wire.store_version_hash(&store_b.current))

	// Conflicting concurrent edits -> conflict value on both -> resolve once -> converge.
	testing.expect_value(t, machine_wire.store_write(store_a, doc_id, blake3.hash(transmute([]u8)string("from-A"))), machine_wire.Store_Status.Ok)
	testing.expect_value(t, machine_wire.store_write(store_b, doc_id, blake3.hash(transmute([]u8)string("from-B"))), machine_wire.Store_Status.Ok)
	sync_once(t, client_b, server_a, relay_r, store_b, req_buf[:], ans_buf[:], &now_us)
	testing.expect_value(t, store_a.current.conflict_count, 1)
	testing.expect_value(t, store_b.current.conflict_count, 1)
	testing.expect_value(t, machine_wire.store_version_hash(&store_a.current), machine_wire.store_version_hash(&store_b.current))

	testing.expect_value(t, machine_wire.store_conflict_resolve(store_b, doc_id, blake3.hash(transmute([]u8)string("merged-AB"))), machine_wire.Store_Status.Ok)
	sync_once(t, client_b, server_a, relay_r, store_b, req_buf[:], ans_buf[:], &now_us)
	testing.expect_value(t, store_a.current.conflict_count, 0)
	testing.expect_value(t, store_b.current.conflict_count, 0)
	testing.expect_value(t, machine_wire.store_version_hash(&store_a.common), machine_wire.store_version_hash(&store_b.common))

	// 7. NAT isolation + end-to-end ChaCha20-Poly1305 sealed relay forwarding over QUIC.
	testing.expect(t, mesh_switch_set_nat_blocked(&sw, 0, 1, true))
	testing.expect(t, !test_quic_connect(client_b, server_a, relay_r, 0, server_a.public_key, &now_us), "direct A <-> B blocked under NAT")
	testing.expect(t, sw.dropped_nat > 0)

	// Allow client_b and server_a on NAT relay_r (node 2) and add BOTH
	// directional routes (B -> A and A -> B) in the SAME epoch without token
	// collision.
	token_b_to_a := machine_wire.relay_directional_routing_token(relay_key_b, client_b.public_key, server_a.public_key, 7)
	token_a_to_b := machine_wire.relay_directional_routing_token(relay_key_a, server_a.public_key, client_b.public_key, 7)
	testing.expect(t, token_b_to_a != token_a_to_b, "directional tokens in the same epoch must differ")
	testing.expect(t, host_mesh_relay_allow_peer(relay_r, client_b.public_key, {.Relay}))
	testing.expect(t, host_mesh_relay_allow_peer(relay_r, server_a.public_key, {.Relay}))
	testing.expect_value(t, host_mesh_relay_route_add(relay_r, token_b_to_a, client_b.public_key, server_a.public_key), machine_wire.Relay_Status.Ok)
	testing.expect_value(t, host_mesh_relay_route_add(relay_r, token_a_to_b, server_a.public_key, client_b.public_key), machine_wire.Relay_Status.Ok)

	// Seal payload end-to-end with ChaCha20-Poly1305 under directional key
	// (B -> A) + 80-byte AAD (sender || receiver || token).
	dir_key_b_to_a := machine_wire.relay_directional_key(relay_key_b, client_b.public_key, server_a.public_key)
	dir_key_a_to_b := machine_wire.relay_directional_key(relay_key_a, server_a.public_key, client_b.public_key)
	defer machine_mesh.clear_bytes_explicitly(dir_key_b_to_a[:])
	defer machine_mesh.clear_bytes_explicitly(dir_key_a_to_b[:])
	testing.expect(t, dir_key_b_to_a != dir_key_a_to_b)
	aad_b_to_a := machine_wire.relay_envelope_aad(client_b.public_key, server_a.public_key, token_b_to_a)
	aad_a_to_b := machine_wire.relay_envelope_aad(server_a.public_key, client_b.public_key, token_a_to_b)

	plaintext := "secret-nat-payload"
	nonce: [machine_wire.RELAY_NONCE_SIZE]u8 = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12}
	sealed: [machine_wire.RELAY_SEALED_MINIMUM + 18]u8
	copy(sealed[:12], nonce[:])
	key_s := string(dir_key_b_to_a[:])
	nonce_s := string(nonce[:])
	aad_s := string(aad_b_to_a[:])
	plain_s := plaintext
	ct_out := sealed[12:]
	aead_err: errors.Error_Record
	seal_out, seal_cnt := client_b.cryptography.seal_with_chacha20_poly1305(&key_s, &nonce_s, &aad_s, &plain_s, &ct_out, &aead_err)
	testing.expect(t, seal_out == .Succeeded && int(seal_cnt) == len(plaintext) + machine_wire.RELAY_TAG_SIZE)

	// Client B connects over QUIC to NAT relay_r (node 2) and deposits sealed envelope.
	testing.expect(t, test_quic_connect(client_b, server_a, relay_r, 2, relay_r.public_key, &now_us))
	dep_frame, dep_st := machine_wire.relay_envelope_write(req_buf[:], .Relay_Deposit, token_b_to_a, sealed[:])
	testing.expect_value(t, dep_st, machine_wire.Relay_Status.Ok)
	ans_len, rt_ok = test_quic_round_trip(client_b, server_a, relay_r, dep_frame, ans_buf[:], &now_us)
	testing.expect(t, rt_ok)
	dep_ans, dep_ans_st := machine_wire.frame_decode(ans_buf[:ans_len])
	testing.expect(t, dep_ans_st == .Ok && dep_ans.message == .Relay_Deposited)

	// Client B (the sender) cannot collect from a route whose receiver is server_a.
	bad_col := machine_wire.relay_collect_write(req_buf[:], token_b_to_a)
	ans_len, rt_ok = test_quic_round_trip(client_b, server_a, relay_r, bad_col, ans_buf[:], &now_us)
	testing.expect(t, rt_ok)
	bad_col_frame, _ := machine_wire.frame_decode(ans_buf[:ans_len])
	testing.expect_value(t, bad_col_frame.message, machine_wire.Message.Refusal)

	// Server A collects via relay_collect and opens ChaCha20-Poly1305 with its
	// matching directional key (B -> A) and AAD.
	del_frame, col_st := machine_wire.relay_collect(&relay_r.peer.relay, server_a.public_key, token_b_to_a, now_us / 1000, ans_buf[:])
	testing.expect_value(t, col_st, machine_wire.Relay_Status.Ok)
	del_dec, del_dec_st := machine_wire.frame_decode(del_frame)
	testing.expect(t, del_dec_st == .Ok && del_dec.message == .Relay_Delivery)
	env, env_st := machine_wire.relay_envelope_read(del_dec.body)
	testing.expect_value(t, env_st, machine_wire.Relay_Status.Ok)
	testing.expect_value(t, env.token, token_b_to_a)

	rx_dir_key := machine_wire.relay_directional_key(relay_key_a, client_b.public_key, server_a.public_key)
	defer machine_mesh.clear_bytes_explicitly(rx_dir_key[:])
	key_a_s := string(rx_dir_key[:])
	rx_nonce_s := string(env.sealed[:12])
	rx_ct_s := string(env.sealed[12:])
	opened: [64]u8
	opened_slice := opened[:len(plaintext)]
	open_out, open_cnt := server_a.cryptography.open_with_chacha20_poly1305(&key_a_s, &rx_nonce_s, &aad_s, &rx_ct_s, &opened_slice, &aead_err)
	testing.expect(t, open_out == .Succeeded && int(open_cnt) == len(plaintext))
	testing.expect_value(t, string(opened[:open_cnt]), plaintext)

	// Reflection resistance: if a compromised relay echoes B's own sealed
	// envelope back to B on the reverse direction (A -> B), B's receiving key
	// and AAD reject it cleanly.
	reflect_key_s := string(dir_key_a_to_b[:])
	reflect_aad_s := string(aad_a_to_b[:])
	reflected_out, _ := client_b.cryptography.open_with_chacha20_poly1305(&reflect_key_s, &rx_nonce_s, &reflect_aad_s, &rx_ct_s, &opened_slice, &aead_err)
	testing.expect(t, reflected_out != .Succeeded, "reflected relay envelope must fail AEAD open")

	// Flipping one bit in sealed ciphertext fails AEAD authentication cleanly.
	tampered := make([]u8, len(env.sealed), context.temp_allocator)
	copy(tampered, env.sealed)
	tampered[12] ~= 0x01
	t_ct_s := string(tampered[12:])
	bad_open_out, _ := server_a.cryptography.open_with_chacha20_poly1305(&key_a_s, &rx_nonce_s, &aad_s, &t_ct_s, &opened_slice, &aead_err)
	testing.expect(t, bad_open_out != .Succeeded, "tampered relay ciphertext must fail AEAD open")
}
