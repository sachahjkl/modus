// Virtual UDP switch and live host QUIC NAT relay for two-machine QEMU mesh
// runs (src/md/features/several_machines.md).
//
// Each QEMU machine's `remote` service holds a UDP listen grant scoped to the
// gateway address 10.0.2.2 on port 7100. Peer_Mesh_Switch assigns each node
// (guest QEMU machine or host QUIC relay) a virtual port on 10.0.2.2 in the
// range [MESH_SWITCH_PORT_BASE ..< MESH_SWITCH_PORT_BASE + MESH_SWITCH_MAX_NODES]:
//
//   node 0 (Machine A) <-> 10.0.2.2:42100
//   node 1 (Machine B) <-> 10.0.2.2:42101
//   node 2 (NAT Relay) <-> 10.0.2.2:42102
//
// When node X sends a UDP datagram from port 7100 to 10.0.2.2:(42100 + Y), the
// switch checks direct_blocked[X][Y] (NAT isolation policy) and injects an
// Ethernet/IPv4/UDP frame into node Y from 10.0.2.2:(42100 + X) to
// 10.0.2.15:7100. Both machines keep their isolated 10.0.2.15 addresses and
// host call channels (43000+) with zero ambient network access.
//
// Host_Mesh_Relay attaches a real modus:quic Server + machine_wire.Peer to a
// switch node so NAT-isolated QEMU machines exchange end-to-end sealed
// Relay_Deposit / Relay_Collect envelopes over real QUIC + TLS 1.3.
package machine

import "core:sync"
import "core:thread"
import "core:time"
import "modus:contract/errors"
import "modus:contract/machine_mesh"
import "modus:contract/machine_sync"
import "modus:contract/machine_wire"
import "modus:contract/remote"
import "modus:quic"
import "modus:random"
import "modustool:fuzz"

// Plan value: supports two live QEMU machines, one host NAT relay, and one spare
// node in a multi-machine mesh test.
MESH_SWITCH_MAX_NODES :: 4

// Plan value: disjoint from RELAY_PORT_FIRST (42000..42015) and
// PEER_REMOTE_PORT_FIRST (43000+) on 10.0.2.2.
MESH_SWITCH_PORT_BASE :: u16(42100)

// Format property: maximum IPv4/UDP payload inside one 1500-byte Ethernet frame.
MESH_SWITCH_DATA_LIMIT :: RELAY_DATA_LIMIT

// Callback invoked when a switch node delivers a UDP datagram to a host node.
Mesh_Switch_Host_Receive_Proc :: #type proc(from_node: int, data: []u8, user_data: rawptr)

// Virtual UDP switch connecting up to MESH_SWITCH_MAX_NODES QEMU Peers and
// host QUIC endpoints with per-pair NAT blocking. Locking order: always
// acquire node_locks[node_id] before sw.lock, never two node_locks at once.
Peer_Mesh_Switch :: struct {
	lock:             sync.Mutex,
	node_locks:       [MESH_SWITCH_MAX_NODES]sync.Mutex,
	peers:            [MESH_SWITCH_MAX_NODES]^Peer,
	host_receivers:   [MESH_SWITCH_MAX_NODES]Mesh_Switch_Host_Receive_Proc,
	host_user:        [MESH_SWITCH_MAX_NODES]rawptr,
	direct_blocked:   [MESH_SWITCH_MAX_NODES][MESH_SWITCH_MAX_NODES]bool,
	forwarded:        u64,
	dropped_nat:      u64,
	dropped_unknown:  u64,
	dropped_too_long: u64,
}

mesh_switch_init :: proc(sw: ^Peer_Mesh_Switch) {
	if sw == nil {
		return
	}
	sw^ = {}
}

mesh_switch_node_port :: proc(node_id: int) -> (port: u16, ok: bool) {
	if node_id < 0 || node_id >= MESH_SWITCH_MAX_NODES {
		return 0, false
	}
	return MESH_SWITCH_PORT_BASE + u16(node_id), true
}

mesh_switch_node_of_port :: proc(port: u16) -> (node_id: int, ok: bool) {
	if port < MESH_SWITCH_PORT_BASE || int(port - MESH_SWITCH_PORT_BASE) >= MESH_SWITCH_MAX_NODES {
		return -1, false
	}
	return int(port - MESH_SWITCH_PORT_BASE), true
}

mesh_switch_attach_peer :: proc(sw: ^Peer_Mesh_Switch, node_id: int, peer: ^Peer) -> bool {
	if sw == nil || peer == nil || node_id < 0 || node_id >= MESH_SWITCH_MAX_NODES {
		return false
	}
	sync.mutex_lock(&sw.node_locks[node_id])
	defer sync.mutex_unlock(&sw.node_locks[node_id])
	sync.mutex_lock(&sw.lock)
	defer sync.mutex_unlock(&sw.lock)
	if sw.peers[node_id] != nil || sw.host_receivers[node_id] != nil {
		return false
	}
	sw.peers[node_id] = peer
	return true
}

mesh_switch_detach_peer :: proc(sw: ^Peer_Mesh_Switch, node_id: int) {
	if sw == nil || node_id < 0 || node_id >= MESH_SWITCH_MAX_NODES {
		return
	}
	sync.mutex_lock(&sw.node_locks[node_id])
	defer sync.mutex_unlock(&sw.node_locks[node_id])
	sync.mutex_lock(&sw.lock)
	sw.peers[node_id] = nil
	sync.mutex_unlock(&sw.lock)
}

mesh_switch_attach_host :: proc(sw: ^Peer_Mesh_Switch, node_id: int, receiver: Mesh_Switch_Host_Receive_Proc, user_data: rawptr) -> bool {
	if sw == nil || receiver == nil || node_id < 0 || node_id >= MESH_SWITCH_MAX_NODES {
		return false
	}
	sync.mutex_lock(&sw.node_locks[node_id])
	defer sync.mutex_unlock(&sw.node_locks[node_id])
	sync.mutex_lock(&sw.lock)
	defer sync.mutex_unlock(&sw.lock)
	if sw.peers[node_id] != nil || sw.host_receivers[node_id] != nil {
		return false
	}
	sw.host_receivers[node_id] = receiver
	sw.host_user[node_id] = user_data
	return true
}

mesh_switch_detach_host :: proc(sw: ^Peer_Mesh_Switch, node_id: int) {
	if sw == nil || node_id < 0 || node_id >= MESH_SWITCH_MAX_NODES {
		return
	}
	sync.mutex_lock(&sw.node_locks[node_id])
	defer sync.mutex_unlock(&sw.node_locks[node_id])
	sync.mutex_lock(&sw.lock)
	sw.host_receivers[node_id] = nil
	sw.host_user[node_id] = nil
	sync.mutex_unlock(&sw.lock)
}

// mesh_switch_set_nat_blocked toggles bidirectional NAT isolation between two
// distinct nodes: when blocked is true, direct datagrams between node_a and
// node_b are dropped and counted in dropped_nat, forcing traffic through a
// relay node.
mesh_switch_set_nat_blocked :: proc(sw: ^Peer_Mesh_Switch, node_a, node_b: int, blocked: bool) -> bool {
	if sw == nil || node_a < 0 || node_a >= MESH_SWITCH_MAX_NODES || node_b < 0 || node_b >= MESH_SWITCH_MAX_NODES || node_a == node_b {
		return false
	}
	sync.mutex_lock(&sw.lock)
	sw.direct_blocked[node_a][node_b] = blocked
	sw.direct_blocked[node_b][node_a] = blocked
	sync.mutex_unlock(&sw.lock)
	return true
}

// mesh_switch_deliver routes one UDP payload from from_node to to_node.
@(private = "file")
mesh_switch_deliver :: proc(sw: ^Peer_Mesh_Switch, from_node, to_node: int, data: []u8) -> bool {
	if sw == nil || from_node < 0 || from_node >= MESH_SWITCH_MAX_NODES || to_node < 0 || to_node >= MESH_SWITCH_MAX_NODES || from_node == to_node {
		return false
	}
	if len(data) > MESH_SWITCH_DATA_LIMIT {
		sync.mutex_lock(&sw.lock)
		sw.dropped_too_long += 1
		sync.mutex_unlock(&sw.lock)
		return true
	}
	// Hold node_locks[to_node] across endpoint delivery so detach waits for
	// any in-flight packet before the destination Peer or Host_Mesh_Relay is
	// closed or freed.
	sync.mutex_lock(&sw.node_locks[to_node])
	defer sync.mutex_unlock(&sw.node_locks[to_node])
	sync.mutex_lock(&sw.lock)
	blocked := sw.direct_blocked[from_node][to_node]
	dst_peer := sw.peers[to_node]
	dst_host := sw.host_receivers[to_node]
	dst_user := sw.host_user[to_node]
	if blocked {
		sw.dropped_nat += 1
		sync.mutex_unlock(&sw.lock)
		return true
	}
	if dst_peer == nil && dst_host == nil {
		sw.dropped_unknown += 1
		sync.mutex_unlock(&sw.lock)
		return true
	}
	sw.forwarded += 1
	sync.mutex_unlock(&sw.lock)

	if dst_peer != nil {
		src_port, _ := mesh_switch_node_port(from_node)
		peer_send(dst_peer, peer_udp_to_machine(dst_peer, PEER_ADDRESS, src_port, remote.LISTEN_PORT, data))
		return true
	}
	if dst_host != nil {
		dst_host(from_node, data, dst_user)
		return true
	}
	return true
}

// mesh_switch_forward_from_peer intercepts a UDP datagram from a guest QEMU
// machine's remote port 7100 targeting 10.0.2.2:dst_port. Returns true when
// dst_port belongs to the switch port range (even if dropped by NAT policy).
mesh_switch_forward_from_peer :: proc(sw: ^Peer_Mesh_Switch, from_node: int, dst_port: u16, data: []u8) -> bool {
	if sw == nil {
		return false
	}
	to_node, is_switch_port := mesh_switch_node_of_port(dst_port)
	if !is_switch_port {
		return false
	}
	if from_node < 0 || from_node >= MESH_SWITCH_MAX_NODES || from_node == to_node {
		sync.mutex_lock(&sw.lock)
		sw.dropped_unknown += 1
		sync.mutex_unlock(&sw.lock)
		return true
	}
	return mesh_switch_deliver(sw, from_node, to_node, data)
}

// mesh_switch_send_from_host injects a UDP payload from a host node (such as
// Host_Mesh_Relay) to to_node on the switch.
mesh_switch_send_from_host :: proc(sw: ^Peer_Mesh_Switch, from_node, to_node: int, data: []u8) -> bool {
	return mesh_switch_deliver(sw, from_node, to_node, data)
}

// ---- Live host QUIC NAT relay on Peer_Mesh_Switch ----

// Plan value: supports concurrent QUIC connections from two QEMU machines plus
// host test peers.
HOST_MESH_RELAY_CONNECTIONS :: 8
HOST_MESH_RELAY_STREAMS :: 4
HOST_MESH_RELAY_INBOX_CAPACITY :: 64

Host_Mesh_Inbox_Packet :: struct {
	from_node: int,
	length:    int,
	data:      [MESH_SWITCH_DATA_LIMIT]u8,
}

Host_Mesh_Stream_State :: struct {
	active:     bool,
	identifier: u64,
	generation: u64,
	received:   int,
	answered:   bool,
	answer_len: int,
	written:    int,
	buffer:     [machine_wire.FRAME_LIMIT]u8,
}

// A live host QUIC server backed by machine_wire.Peer attached to a
// Peer_Mesh_Switch node, used as a real QUIC NAT relay (Relay_Deposit /
// Relay_Collect) and multi-peer mesh endpoint.
Host_Mesh_Relay :: struct {
	lock:           sync.Mutex,
	sw:             ^Peer_Mesh_Switch,
	node_id:        int,
	cryptography:   quic.Cryptography,
	generator:      random.Generator,
	public_key:     [32]u8,
	server:         quic.Server,
	records:        [HOST_MESH_RELAY_CONNECTIONS]quic.Server_Record,
	connections:    [HOST_MESH_RELAY_CONNECTIONS]quic.Connection,
	streams:        [HOST_MESH_RELAY_CONNECTIONS * HOST_MESH_RELAY_STREAMS]quic.Stream,
	stream_states:  [HOST_MESH_RELAY_CONNECTIONS * HOST_MESH_RELAY_STREAMS]Host_Mesh_Stream_State,
	peer:           machine_wire.Peer,
	object_rows:    [32]machine_sync.Stored_Object,
	object_bytes:   [64 * 1024]u8,
	store_rows:     [4]machine_wire.Exchanged_Store,
	store_entries:  [256]machine_wire.Store_Entry,
	store_conflicts:[64]machine_wire.Store_Conflict,
	answer_scratch: [machine_wire.FRAME_LIMIT]u8,
	inbox:          [HOST_MESH_RELAY_INBOX_CAPACITY]Host_Mesh_Inbox_Packet,
	inbox_head:     int,
	inbox_count:    int,
	inbox_dropped:  u64,
	frames_served:  u64,
	now_ms:         u64,
	start_tick:     time.Tick,
	stop:           bool,
	thread:         ^thread.Thread,
}

// Active relay pointer used during quic.Client_Key_Check callback (no user_data
// parameter in TLS client_key_check). Protected by active_relay_lock.
@(private = "file")
active_relay_lock: sync.Mutex
@(private = "file")
active_relay_for_check: ^Host_Mesh_Relay

@(private = "file")
host_mesh_relay_client_key_allowed :: proc "contextless" (key: ^[32]u8) -> bool {
	relay := active_relay_for_check
	if relay == nil || key == nil {
		return false
	}
	return machine_wire.peer_admits(&relay.peer, key^, relay.now_ms)
}

@(private = "file")
host_mesh_relay_sig_verify :: proc "contextless" (
	public_key: [machine_mesh.PUBLIC_KEY_SIZE]u8,
	message: []u8,
	signature: [machine_mesh.SIGNATURE_SIZE]u8,
	user_data: rawptr,
) -> bool {
	relay := (^Host_Mesh_Relay)(user_data)
	if relay == nil {
		return false
	}
	key_copy := public_key
	sig_copy := signature
	key_text := string(key_copy[:])
	msg_text := string(message)
	sig_text := string(sig_copy[:])
	error: errors.Error_Record
	outcome, count := relay.cryptography.ed25519_verify(&key_text, &msg_text, &sig_text, &error)
	return outcome == .Succeeded && count == 0
}

@(private = "file")
host_mesh_relay_fill_random :: proc "contextless" (bytes: []u8, user_data: rawptr) -> bool {
	relay := (^Host_Mesh_Relay)(user_data)
	if relay == nil {
		return false
	}
	error: errors.Error_Record
	return random.fill_for_a_key(&relay.generator, bytes, .Processor, &error)
}

@(private = "file")
host_mesh_relay_receive_cb :: proc(from_node: int, data: []u8, user_data: rawptr) {
	relay := (^Host_Mesh_Relay)(user_data)
	if relay == nil || len(data) == 0 || len(data) > MESH_SWITCH_DATA_LIMIT {
		return
	}
	sync.mutex_lock(&relay.lock)
	defer sync.mutex_unlock(&relay.lock)
	if relay.inbox_count >= HOST_MESH_RELAY_INBOX_CAPACITY {
		relay.inbox_dropped += 1
		return
	}
	slot := (relay.inbox_head + relay.inbox_count) % HOST_MESH_RELAY_INBOX_CAPACITY
	relay.inbox[slot].from_node = from_node
	relay.inbox[slot].length = copy(relay.inbox[slot].data[:], data)
	relay.inbox_count += 1
}

// host_mesh_relay_make initializes a Host_Mesh_Relay with deterministic seed
// bytes and attaches it to sw at node_id.
host_mesh_relay_make :: proc(sw: ^Peer_Mesh_Switch, node_id: int, seed_byte: u8 = 0x61) -> (relay: ^Host_Mesh_Relay, ok: bool) {
	relay = new(Host_Mesh_Relay)
	relay.sw = sw
	relay.node_id = node_id
	relay.cryptography = fuzz.quic_cryptography_of_the_host()
	seed: [random.SEED_SIZE]u8
	for i in 0 ..< random.SEED_SIZE {
		seed[i] = seed_byte + u8(i)
	}
	random.generator_seed(&relay.generator, &seed, .Processor)
	config := quic.Connection_Configuration{idle_timeout_milliseconds = 30_000}
	config.tls = {role = .Server, least_seed_strength = .Processor}
	config.tls.application_protocol_length = copy(config.tls.application_protocol[:], remote.APPLICATION_PROTOCOL)
	defer quic.secret_erase(&config.tls.server_private_key, size_of(config.tls.server_private_key))
	error: errors.Error_Record
	if !random.fill_for_a_key(&relay.generator, config.tls.server_private_key[:], .Processor, &error) {
		free(relay)
		return nil, false
	}
	secret := string(config.tls.server_private_key[:])
	pub_slice := relay.public_key[:]
	if pub_out, pub_count := relay.cryptography.ed25519_public_key(&secret, &pub_slice, &error); pub_out != .Succeeded || pub_count != 32 {
		free(relay)
		return nil, false
	}
	config.tls.client_key_check = host_mesh_relay_client_key_allowed

	services := machine_wire.Peer_Services {
		signature_verify = host_mesh_relay_sig_verify,
		fill_random      = host_mesh_relay_fill_random,
		user_data        = relay,
	}
	memory := machine_wire.Peer_Memory {
		object_rows     = relay.object_rows[:],
		object_bytes    = relay.object_bytes[:],
		stores          = relay.store_rows[:],
		store_entries   = relay.store_entries[:],
		store_conflicts = relay.store_conflicts[:],
	}
	if !machine_wire.peer_init(&relay.peer, relay.public_key, services, memory) {
		free(relay)
		return nil, false
	}
	limits := quic.server_limits_of_one_address(HOST_MESH_RELAY_CONNECTIONS)
	if !quic.server_init(&relay.server, relay.connections[:], relay.records[:], relay.streams[:], &config, &relay.cryptography, &relay.generator, limits, &error) {
		free(relay)
		return nil, false
	}
	relay.start_tick = time.tick_now()
	if !mesh_switch_attach_host(sw, node_id, host_mesh_relay_receive_cb, relay) {
		free(relay)
		return nil, false
	}
	return relay, true
}

host_mesh_relay_now_ms :: proc(relay: ^Host_Mesh_Relay) -> u64 {
	if relay == nil {
		return 1
	}
	return u64(time.tick_since(relay.start_tick) / time.Millisecond) + 1
}

host_mesh_relay_public_key_hex :: proc(relay: ^Host_Mesh_Relay) -> string {
	return hex_of(relay.public_key[:])
}

// host_mesh_relay_offer_pairing starts a CPace pairing offer on the relay
// under relay.lock so a guest machine can pair with the relay over QUIC.
host_mesh_relay_offer_pairing :: proc(
	relay: ^Host_Mesh_Relay,
	random_bytes: [8]u8,
	uses: remote.Client_Uses,
	now_ms: u64,
) -> (code: [machine_mesh.PAIRING_CODE_TEXT_SIZE]u8, status: machine_mesh.Pairing_Status) {
	if relay == nil {
		return {}, .Refused_Nil_Input
	}
	sync.mutex_lock(&relay.lock)
	defer sync.mutex_unlock(&relay.lock)
	code, status = machine_mesh.pairing_offer(&relay.peer.pairing, relay.public_key, random_bytes, now_ms)
	if status == .Ok {
		relay.peer.pairing_uses = uses
	}
	return code, status
}

// host_mesh_relay_grant_peer sets the mesh uses and roles for an already
// paired peer on the relay without adding a duplicate paired row.
host_mesh_relay_grant_peer :: proc(relay: ^Host_Mesh_Relay, peer_identity: [32]u8, uses: machine_wire.Machine_Uses, roles: machine_wire.Role_Set = {}) -> bool {
	if relay == nil {
		return false
	}
	sync.mutex_lock(&relay.lock)
	defer sync.mutex_unlock(&relay.lock)
	return machine_wire.machine_grant_set(&relay.peer, peer_identity, uses, roles)
}

// host_mesh_relay_allow_peer registers peer_identity as a paired peer on the
// relay with the given uses and optional roles.
host_mesh_relay_allow_peer :: proc(relay: ^Host_Mesh_Relay, peer_identity: [32]u8, uses: machine_wire.Machine_Uses, roles: machine_wire.Role_Set = {}) -> bool {
	if relay == nil {
		return false
	}
	sync.mutex_lock(&relay.lock)
	defer sync.mutex_unlock(&relay.lock)
	if _, exists := machine_mesh.paired_machine_find(&relay.peer.paired, peer_identity); !exists {
		status := machine_mesh.paired_machine_add(&relay.peer.paired, machine_mesh.Paired_Machine {
			identity_key = peer_identity,
			uses         = {.Calls},
			source       = .Pairing,
			paired_at_ms = 1,
		})
		if status != .Ok {
			return false
		}
	}
	return machine_wire.machine_grant_set(&relay.peer, peer_identity, uses, roles)
}

host_mesh_relay_route_add :: proc(relay: ^Host_Mesh_Relay, token: machine_wire.Routing_Token, sender, receiver: [32]u8) -> machine_wire.Relay_Status {
	if relay == nil {
		return .Refused_Bad_Ends
	}
	sync.mutex_lock(&relay.lock)
	defer sync.mutex_unlock(&relay.lock)
	return machine_wire.relay_route_add(&relay.peer.relay, token, sender, receiver)
}

// host_mesh_relay_tick drains pending switch packets, runs QUIC handshakes and
// machine_wire.serve on completed mesh streams, and injects outgoing QUIC
// datagrams back into Peer_Mesh_Switch.
host_mesh_relay_tick :: proc(relay: ^Host_Mesh_Relay, now_us: u64) {
	if relay == nil {
		return
	}
	sync.mutex_lock(&relay.lock)
	defer sync.mutex_unlock(&relay.lock)
	sync.mutex_lock(&active_relay_lock)
	active_relay_for_check = relay
	defer {
		active_relay_for_check = nil
		sync.mutex_unlock(&active_relay_lock)
	}

	now_ms := now_us / 1000
	relay.now_ms = now_ms
	// Drain inbound datagrams from Peer_Mesh_Switch.
	for relay.inbox_count > 0 {
		pkt := relay.inbox[relay.inbox_head]
		relay.inbox_head = (relay.inbox_head + 1) % HOST_MESH_RELAY_INBOX_CAPACITY
		relay.inbox_count -= 1
		port, ok := mesh_switch_node_port(pkt.from_node)
		if !ok {
			continue
		}
		peer_remote := quic.Remote{address = remote.HOST_ADDRESS, port = port}
		send_buf: [quic.MAX_DATAGRAM_SIZE]u8
		outcome := quic.server_datagram_receive(&relay.server, pkt.data[:pkt.length], peer_remote, send_buf[:], now_us)
		if outcome.answer_length > 0 {
			mesh_switch_send_from_host(relay.sw, relay.node_id, pkt.from_node, send_buf[:outcome.answer_length])
		}
		if outcome.validate_remote && outcome.record >= 0 {
			quic.server_validation_confirmed(&relay.server, outcome.record, relay.records[outcome.record].generation, true)
		}
	}

	quic.server_time_passes(&relay.server, now_us)
	released: [HOST_MESH_RELAY_CONNECTIONS]quic.Remote
	_ = quic.server_sweep(&relay.server, released[:])

	// Service completed mesh streams on connected peers.
	for &record, place in relay.records {
		if !record.in_use {
			continue
		}
		conn := &relay.connections[place]
		if conn.state != .Connected {
			continue
		}
		peer_identity := conn.tls.client_public_key
		for &stream, slot in conn.streams {
			st := &relay.stream_states[place * HOST_MESH_RELAY_STREAMS + slot]
			if !stream.in_use {
				st.active = false
				continue
			}
			if !st.active || st.identifier != stream.identifier || st.generation != record.generation {
				st^ = {active = true, identifier = stream.identifier, generation = record.generation}
			}
			if !st.answered {
				for {
					n, finished, reset := quic.stream_read(conn, stream.identifier, st.buffer[st.received:])
					st.received += n
					if reset {
						quic.stream_reset(conn, stream.identifier, u64(remote.Stream_Error.Cancelled))
						st.answered = true
						st.answer_len = 0
						st.written = 0
						break
					}
					if finished {
						serve_ctx := machine_wire.Serve_Context {
							peer_identity   = peer_identity,
							channel_binding = machine_wire.channel_binding_of_identities(relay.peer.identity.public_key, peer_identity),
							now_ms          = now_ms,
						}
						ans := machine_wire.serve(&relay.peer, &serve_ctx, st.buffer[:st.received], relay.answer_scratch[:])
						st.answer_len = copy(st.buffer[:], ans)
						st.written = 0
						st.answered = true
						relay.frames_served += 1
						break
					}
					if n == 0 {
						break
					}
				}
			}
			if st.answered && st.written < st.answer_len {
				st.written += quic.stream_write(conn, stream.identifier, st.buffer[st.written:st.answer_len], true)
			}
		}
	}

	// Flush outbound QUIC datagrams back to their respective switch nodes.
	out_buf: [quic.MAX_DATAGRAM_SIZE]u8
	for _ in 0 ..< 64 {
		sent_any := false
		for &record, place in relay.records {
			if !record.in_use {
				continue
			}
			conn := &relay.connections[place]
			if conn.state == .Idle || conn.state == .Closed {
				continue
			}
			n := quic.connection_datagram_send(conn, out_buf[:], now_us)
			if n <= 0 {
				continue
			}
			sent_any = true
			if dst_node, ok := mesh_switch_node_of_port(record.remote.port); ok {
				mesh_switch_send_from_host(relay.sw, relay.node_id, dst_node, out_buf[:n])
			}
		}
		if !sent_any {
			break
		}
	}
}

// Plan value: tick interval of the background host QUIC relay thread so QUIC
// handshakes and retransmissions make prompt progress while idling cheaply.
HOST_MESH_RELAY_TICK_PERIOD :: time.Millisecond

@(private = "file")
host_mesh_relay_thread_run :: proc(relay: ^Host_Mesh_Relay) {
	for !sync.atomic_load(&relay.stop) {
		now_us := u64(time.tick_since(relay.start_tick) / time.Microsecond) + 1000
		host_mesh_relay_tick(relay, now_us)
		free_all(context.temp_allocator)
		time.sleep(HOST_MESH_RELAY_TICK_PERIOD)
	}
}

host_mesh_relay_start_thread :: proc(relay: ^Host_Mesh_Relay) {
	if relay == nil || relay.thread != nil {
		return
	}
	relay.stop = false
	relay.thread = thread.create_and_start_with_poly_data(relay, host_mesh_relay_thread_run)
}

host_mesh_relay_stop :: proc(relay: ^Host_Mesh_Relay) {
	if relay == nil {
		return
	}
	// Detach from Peer_Mesh_Switch first so no concurrent switch delivery can
	// touch relay while its thread stops and its memory is freed.
	mesh_switch_detach_host(relay.sw, relay.node_id)
	if relay.thread != nil {
		sync.atomic_store(&relay.stop, true)
		thread.join(relay.thread)
		thread.destroy(relay.thread)
		relay.thread = nil
	}
	free(relay)
}
