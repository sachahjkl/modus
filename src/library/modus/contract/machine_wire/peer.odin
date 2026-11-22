// The state of one machine among the machines of its principal, and the
// dispatch of each mesh frame that a paired machine sends on a stream of
// remote (src/md/features/several_machines.md).
//
// serve answers one request frame with one answer frame. The identity key
// that the handshake proved, and the binding of the connection, come from
// the transport, never from the frame: a body that names another key is
// refused. The service remote holds one Peer and calls serve for each stream
// whose first word is the word of Request_Kind.Mesh.
package machine_wire

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/machine_mesh"
import "modus:contract/machine_sync"
import "modus:contract/object_cache"
import "modus:contract/role_contract"

OBJECT_CAPACITY :: 8 // The objects by hash that a peer keeps: a few small objects, in the data of the process.
OBJECT_BYTES_LIMIT :: 16 * 1024
OBJECT_REQUEST_SIZE :: 8 + blake3.HASH_SIZE // The kind, a zero word, the hash.
OBJECT_RESPONSE_HEADER_SIZE :: 8 + blake3.HASH_SIZE // The kind, the count of bytes, the hash.
CHANNEL_BINDING_DOMAIN :: "modus mesh channel binding v1"

PAIRING_ELEMENT_SIZE :: machine_mesh.CPACE_PUBLIC_ELEMENT_SIZE + machine_mesh.PUBLIC_KEY_SIZE
PAIRING_ELEMENT_REPLY_SIZE :: PAIRING_ELEMENT_SIZE + machine_mesh.CPACE_CONFIRM_TAG_SIZE
PAIRING_CONFIRM_SIZE :: machine_mesh.CPACE_CONFIRM_TAG_SIZE
PAIRING_CONFIRMED_SIZE :: blake3.HASH_SIZE
GRANT_ACCEPTED_SIZE :: 16

// The random bytes for a key: the CPace scalar of each exchange.
Fill_Random_Proc :: #type proc "contextless" (bytes: []u8, user_data: rawptr) -> bool

// The holder of a role on this machine, for a call of a paired machine. It
// writes at most len(result) bytes and gives their count. Only Answered and
// Refused are outcomes of a holder.
Role_Holder_Proc :: #type proc "contextless" (role: role_contract.Role, export: u32, arguments: []u8, result: []u8, user_data: rawptr) -> (value: i64, result_count: int, outcome: Role_Outcome)

Role_Set :: bit_set[role_contract.Role;u64]

// What a paired machine may ask of this machine. A pairing gives no use:
// the plan of the principal gives each use to each paired machine, and each
// request of a use that the machine lacks is refused before any table is
// read.
Machine_Use :: enum u32 {
	Objects = 0, // Object_Request: fetch an object by its hash.
	Stores  = 1, // Store_Offer: exchange the stores that the plan names with this machine.
	Roles   = 2, // Role_Call: call the roles of the grant.
	Relay   = 3, // Relay_Deposit and Relay_Collect, on the routes that name this machine.
	Grants  = 4, // Grant_Present: a signed grant for the principal that the transport proved.
}
Machine_Uses :: bit_set[Machine_Use;u32]

// machine_uses_of_word is the border of the word of the uses: it refuses a
// bit that names no use.
machine_uses_of_word :: proc "contextless" (word: u32) -> (uses: Machine_Uses, ok: bool) {
	known := Machine_Uses{.Objects, .Stores, .Roles, .Relay, .Grants}
	if word & ~transmute(u32)known != 0 {
		return {}, false
	}
	return transmute(Machine_Uses)word, true
}

// The uses and the roles that this machine gives one paired machine, by the
// plan of the principal. roles is empty unless uses holds Roles.
Machine_Grant :: struct {
	identity: [machine_mesh.PUBLIC_KEY_SIZE]u8,
	uses:     Machine_Uses,
	roles:    Role_Set,
}

// What the process gives the peer: the cryptography of its module and the
// holder of its roles.
Peer_Services :: struct {
	signature_verify: machine_mesh.Signature_Verify_Proc,
	fill_random:      Fill_Random_Proc,
	role_holder:      Role_Holder_Proc,
	user_data:        rawptr,
}

// What the transport proved for one stream.
Serve_Context :: struct {
	peer_identity:        [machine_mesh.PUBLIC_KEY_SIZE]u8, // The key that the handshake proved.
	peer_root_public_key: machine_mesh.Principal_Root_Public_Key, // The principal root key whose list names that key; zero when none.
	channel_binding:      [machine_mesh.PAIRING_CHANNEL_BINDING_SIZE]u8, // channel_binding_of_identities.
	now_ms:               u64,
}

Peer :: struct {
	identity:          machine_mesh.Machine_Identity,
	has_identity:      bool,
	services:          Peer_Services,
	pairing:           machine_mesh.Pairing_Session,
	spent_codes:       machine_mesh.Pairing_Code_Ledger,
	paired:            machine_mesh.Paired_Machine_Table,
	// The uses that the principal gave at the offer or the join: the row of
	// the other machine takes them when the exchange confirms.
	pairing_uses_word: u64,
	machine_list:      machine_mesh.Machine_List_Holder,
	has_principal:     bool,
	// Zero: a machine with no TPM attestation is refused, as the design
	// asks by default.
	join_policy:       machine_mesh.Join_Policy,
	revocations:       machine_mesh.Revocation_List,
	has_revocations:   bool,
	objects:           machine_sync.Object_Store,
	object_rows:       [OBJECT_CAPACITY]machine_sync.Stored_Object,
	object_bytes:      [OBJECT_BYTES_LIMIT]u8,
	stores:            [EXCHANGED_STORE_CAPACITY]Exchanged_Store,
	machine_grants:    [machine_mesh.MAX_PAIRED_MACHINES]Machine_Grant,
	relay:             Relay_Table,
}

// peer_init takes the public identity key of this machine and empties the
// state. ok is false for a zero key or no signature check.
peer_init :: proc "contextless" (peer: ^Peer, identity_public_key: [machine_mesh.PUBLIC_KEY_SIZE]u8, services: Peer_Services) -> bool {
	if peer == nil || services.signature_verify == nil || services.fill_random == nil {
		return false
	}
	identity, ok := machine_mesh.machine_identity_from_public_key(identity_public_key)
	if !ok {
		return false
	}
	peer^ = {}
	peer.identity = identity
	peer.has_identity = true
	peer.services = services
	return machine_sync.object_store_init(&peer.objects, peer.object_rows[:], peer.object_bytes[:])
}

// channel_binding_of_identities binds a pairing to the two identity keys
// that the handshake of the connection proved, in the order server, client.
// The two sides compute the same bytes; a relay that ends the handshake with
// a key of its own gives other bytes. The QUIC library has no TLS exporter
// yet: when it has one, the exporter replaces this binding
// (src/md/features/several_machines.md, "The frames on a stream of remote").
channel_binding_of_identities :: proc "contextless" (server_identity, client_identity: [machine_mesh.PUBLIC_KEY_SIZE]u8) -> [machine_mesh.PAIRING_CHANNEL_BINDING_SIZE]u8 {
	input: [2 * machine_mesh.PUBLIC_KEY_SIZE]u8
	server, client := server_identity, client_identity
	copy(input[:32], server[:])
	copy(input[32:], client[:])
	return blake3.derive_key(CHANNEL_BINDING_DOMAIN, input[:])
}

// peer_admits is the check of the handshake for a key that the client
// table does not hold: a paired machine, or the machine of an open pairing
// whose code has not ended.
peer_admits :: proc "contextless" (peer: ^Peer, key: [machine_mesh.PUBLIC_KEY_SIZE]u8, now_ms: u64) -> bool {
	if !peer.has_identity || machine_mesh.key_is_zero(key) {
		return false
	}
	if _, paired := machine_mesh.paired_machine_find(&peer.paired, key); paired {
		return true
	}
	if peer.pairing.side != .Offerer || machine_mesh.pairing_code_expired(peer.pairing.code_started_at_ms, now_ms) {
		return false
	}
	switch peer.pairing.phase {
	case .Code_Ready:
		return true
	case .Exchanging, .Confirming:
		return machine_mesh.keys_equal_constant_time(peer.pairing.peer_identity, key)
	case .Idle, .Paired, .Failed:
	}
	return false
}

// machine_grant_set gives a paired machine its uses and the roles that the
// plan of the principal names for it, in place of its earlier grant. Empty
// uses remove the grant. Roles without the use Roles, the use Roles without
// a role, and the role None are refused.
machine_grant_set :: proc "contextless" (peer: ^Peer, identity: [machine_mesh.PUBLIC_KEY_SIZE]u8, uses: Machine_Uses, roles: Role_Set) -> bool {
	if machine_mesh.key_is_zero(identity) || .None in roles || (.Roles in uses) != (roles != {}) {
		return false
	}
	free := -1
	for &grant, index in peer.machine_grants {
		if grant.uses != {} && grant.identity == identity {
			grant = uses == {} ? {} : Machine_Grant{identity = identity, uses = uses, roles = roles}
			return true
		}
		if grant.uses == {} && free < 0 {
			free = index
		}
	}
	if uses == {} {
		return true
	}
	if free < 0 {
		return false
	}
	peer.machine_grants[free] = Machine_Grant{identity = identity, uses = uses, roles = roles}
	return true
}

// machine_grant_clear removes any grant row of an unpaired machine so a
// later pairing starts with no leftover uses or roles.
machine_grant_clear :: proc "contextless" (peer: ^Peer, identity: [machine_mesh.PUBLIC_KEY_SIZE]u8) {
	for &item in peer.machine_grants {
		if item.identity == identity {
			item = {}
		}
	}
}

// machine_grant_of gives the grant of a machine that is paired now, or none:
// a grant outlives no row of the paired machines.
machine_grant_of :: proc "contextless" (peer: ^Peer, identity: [machine_mesh.PUBLIC_KEY_SIZE]u8) -> (grant: Machine_Grant, found: bool) {
	if !peer_is_paired(peer, identity) {
		return {}, false
	}
	for item in peer.machine_grants {
		if item.uses != {} && item.identity == identity {
			return item, true
		}
	}
	return {}, false
}

// pairing_expire ends an open pairing whose code ended: the service calls
// it at each pass, so an abandoned offer admits no key and holds no secret.
// It gives true when it ended one.
pairing_expire :: proc "contextless" (peer: ^Peer, now_ms: u64) -> bool {
	switch peer.pairing.phase {
	case .Code_Ready, .Exchanging, .Confirming:
		if machine_mesh.pairing_code_expired(peer.pairing.code_started_at_ms, now_ms) {
			machine_mesh.pairing_fail(&peer.pairing, .Refused_Code_Expired)
			return true
		}
	case .Idle, .Paired, .Failed:
	}
	return false
}

@(private)
peer_is_paired :: proc "contextless" (peer: ^Peer, identity: [machine_mesh.PUBLIC_KEY_SIZE]u8) -> bool {
	_, paired := machine_mesh.paired_machine_find(&peer.paired, identity)
	return paired
}

// serve answers one request frame of the machine that the context names.
// The answer is always one frame in output: the answer message or a Refusal.
// output must hold FRAME_LIMIT bytes.
serve :: proc "contextless" (peer: ^Peer, serve_context: ^Serve_Context, input: []u8, output: []u8) -> []u8 {
	frame, frame_status := frame_decode(input)
	if frame_status != .Ok {
		return refusal_write(output, .Malformed, u32(frame_status))
	}
	if !peer.has_identity {
		return refusal_write(output, .No_Identity, 0)
	}
	// Each request is authorized here, before any table is read. A machine
	// that the handshake admitted only for an open offer reaches the two
	// pairing steps; a paired machine reaches a request of a use only when
	// its grant holds that use.
	use: Machine_Use
	switch frame.message {
	case .Pairing_Element:
		return serve_pairing_element(peer, serve_context, frame.body, output)
	case .Pairing_Confirm:
		return serve_pairing_confirm(peer, serve_context, frame.body, output)
	case .Grant_Present:
		use = .Grants
	case .Object_Request:
		use = .Objects
	case .Store_Offer:
		use = .Stores
	case .Role_Call:
		use = .Roles
	case .Relay_Deposit, .Relay_Collect:
		use = .Relay
	case .None, .Refusal, .Pairing_Element_Reply, .Pairing_Confirmed, .Object_Response, .Grant_Accepted, .Store_Offer_Reply, .Role_Reply, .Relay_Deposited, .Relay_Delivery:
		return refusal_write(output, .Unexpected_Message, u32(frame.message))
	}
	if !peer_is_paired(peer, serve_context.peer_identity) {
		return refusal_write(output, .Not_Paired, 0)
	}
	grant, granted := machine_grant_of(peer, serve_context.peer_identity)
	if !granted || use not_in grant.uses {
		return refusal_write(output, .Use_Not_Granted, u32(use))
	}
	switch frame.message {
	case .Grant_Present:
		return serve_grant_present(peer, serve_context, frame.body, output)
	case .Object_Request:
		return serve_object_request(peer, serve_context, frame.body, output)
	case .Store_Offer:
		return serve_store_offer(peer, serve_context, frame.body, output)
	case .Role_Call:
		return serve_role_call(peer, &grant, frame.body, output)
	case .Relay_Deposit:
		return serve_relay_deposit(peer, serve_context, frame.body, output)
	case .Relay_Collect:
		return serve_relay_collect(peer, serve_context, frame.body, output)
	case .None, .Refusal, .Pairing_Element, .Pairing_Element_Reply, .Pairing_Confirm, .Pairing_Confirmed, .Object_Response, .Grant_Accepted, .Store_Offer_Reply, .Role_Reply, .Relay_Deposited, .Relay_Delivery:
		return refusal_write(output, .Unexpected_Message, u32(frame.message))
	}
	return refusal_write(output, .Unexpected_Message, u32(frame.message))
}

// ---- Pairing ----

@(private)
serve_pairing_element :: proc "contextless" (peer: ^Peer, serve_context: ^Serve_Context, body: []u8, output: []u8) -> []u8 {
	if len(body) != PAIRING_ELEMENT_SIZE {
		return refusal_write(output, .Malformed, 0)
	}
	if peer.pairing.side != .Offerer {
		return refusal_write(output, .Pairing_Refused, u32(machine_mesh.Pairing_Status.Refused_Bad_Phase))
	}
	joiner_element: [machine_mesh.CPACE_PUBLIC_ELEMENT_SIZE]u8
	copy(joiner_element[:], body[:machine_mesh.CPACE_PUBLIC_ELEMENT_SIZE])
	joiner_identity := body[machine_mesh.CPACE_PUBLIC_ELEMENT_SIZE:]
	scalar: [machine_mesh.CPACE_SCALAR_SIZE]u8
	defer machine_mesh.clear_bytes_explicitly(scalar[:])
	if !peer.services.fill_random(scalar[:], peer.services.user_data) {
		machine_mesh.pairing_fail(&peer.pairing, .Refused_Exchange)
		return refusal_write(output, .Pairing_Refused, u32(machine_mesh.Pairing_Status.Refused_Exchange))
	}
	own_element, start_status := machine_mesh.pairing_exchange_start(&peer.pairing, &peer.spent_codes, serve_context.peer_identity, serve_context.channel_binding[:], scalar, serve_context.now_ms)
	if start_status != .Ok {
		return refusal_write(output, .Pairing_Refused, u32(start_status))
	}
	// The associated data must be the key of the handshake: a body that
	// names another key fails here, and the session ends.
	own_tag, finish_status := machine_mesh.pairing_exchange_finish(&peer.pairing, joiner_element, joiner_identity)
	if finish_status != .Ok {
		return refusal_write(output, .Pairing_Refused, u32(finish_status))
	}
	reply, ok := frame_begin(output, .Pairing_Element_Reply, PAIRING_ELEMENT_REPLY_SIZE)
	if !ok {
		return refusal_write(output, .Malformed, 0)
	}
	copy(reply[:32], own_element[:])
	copy(reply[32:64], peer.identity.public_key[:])
	copy(reply[64:96], own_tag[:])
	return frame_bytes(output, reply)
}

@(private)
serve_pairing_confirm :: proc "contextless" (peer: ^Peer, serve_context: ^Serve_Context, body: []u8, output: []u8) -> []u8 {
	if len(body) != PAIRING_CONFIRM_SIZE {
		return refusal_write(output, .Malformed, 0)
	}
	if peer.pairing.side != .Offerer || peer.pairing.phase != .Confirming || !machine_mesh.keys_equal_constant_time(peer.pairing.peer_identity, serve_context.peer_identity) {
		return refusal_write(output, .Pairing_Refused, u32(machine_mesh.Pairing_Status.Refused_Bad_Phase))
	}
	tag: [machine_mesh.CPACE_CONFIRM_TAG_SIZE]u8
	copy(tag[:], body)
	paired, status := machine_mesh.pairing_confirm(&peer.pairing, &peer.paired, tag, peer.pairing_uses_word, serve_context.now_ms)
	if status != .Ok {
		return refusal_write(output, .Pairing_Refused, u32(status))
	}
	reply, ok := frame_begin(output, .Pairing_Confirmed, PAIRING_CONFIRMED_SIZE)
	if !ok {
		return refusal_write(output, .Malformed, 0)
	}
	copy(reply, paired.transcript_fingerprint[:])
	return frame_bytes(output, reply)
}

// pairing_element_write is the first frame of the joiner, after
// pairing_join with the code that the principal typed. server_identity is
// the key that the handshake proved for the offerer.
pairing_element_write :: proc "contextless" (peer: ^Peer, server_identity: [machine_mesh.PUBLIC_KEY_SIZE]u8, channel_binding: [machine_mesh.PAIRING_CHANNEL_BINDING_SIZE]u8, now_ms: u64, output: []u8) -> (frame: []u8, status: machine_mesh.Pairing_Status) {
	if peer.pairing.side != .Joiner {
		return nil, .Refused_Bad_Side
	}
	scalar: [machine_mesh.CPACE_SCALAR_SIZE]u8
	defer machine_mesh.clear_bytes_explicitly(scalar[:])
	if !peer.services.fill_random(scalar[:], peer.services.user_data) {
		return nil, machine_mesh.pairing_fail(&peer.pairing, .Refused_Exchange)
	}
	binding := channel_binding
	element, start_status := machine_mesh.pairing_exchange_start(&peer.pairing, &peer.spent_codes, server_identity, binding[:], scalar, now_ms)
	if start_status != .Ok {
		return nil, start_status
	}
	body, ok := frame_begin(output, .Pairing_Element, PAIRING_ELEMENT_SIZE)
	if !ok {
		return nil, machine_mesh.pairing_fail(&peer.pairing, .Refused_Nil_Input)
	}
	copy(body[:32], element[:])
	copy(body[32:], peer.identity.public_key[:])
	return frame_bytes(output, body), .Ok
}

// pairing_element_reply_accept takes the reply of the offerer: it checks
// its tag, writes the row of the offerer, and writes the Pairing_Confirm
// frame. When the tag of the offerer fails, the frame still goes, with the
// tag of this side, so that the offerer fails too and the code ends on
// both machines.
pairing_element_reply_accept :: proc "contextless" (peer: ^Peer, answer: []u8, now_ms: u64, output: []u8) -> (frame: []u8, status: machine_mesh.Pairing_Status) {
	body, _, _, ok := answer_expect(answer, .Pairing_Element_Reply)
	if !ok {
		return nil, machine_mesh.pairing_fail(&peer.pairing, .Refused_Exchange)
	}
	if len(body) != PAIRING_ELEMENT_REPLY_SIZE {
		return nil, machine_mesh.pairing_fail(&peer.pairing, .Refused_Exchange)
	}
	element: [machine_mesh.CPACE_PUBLIC_ELEMENT_SIZE]u8
	tag: [machine_mesh.CPACE_CONFIRM_TAG_SIZE]u8
	copy(element[:], body[:32])
	copy(tag[:], body[64:96])
	own_tag, finish_status := machine_mesh.pairing_exchange_finish(&peer.pairing, element, body[32:64])
	if finish_status != .Ok {
		return nil, finish_status
	}
	confirm_body, frame_ok := frame_begin(output, .Pairing_Confirm, PAIRING_CONFIRM_SIZE)
	if !frame_ok {
		return nil, machine_mesh.pairing_fail(&peer.pairing, .Refused_Nil_Input)
	}
	copy(confirm_body, own_tag[:])
	_, confirm_status := machine_mesh.pairing_confirm(&peer.pairing, &peer.paired, tag, peer.pairing_uses_word, now_ms)
	return frame_bytes(output, confirm_body), confirm_status
}

// pairing_confirmed_accept takes the last answer of the offerer: the
// fingerprint of its session key must be the one of this side, or the row
// of the offerer leaves again.
pairing_confirmed_accept :: proc "contextless" (peer: ^Peer, server_identity: [machine_mesh.PUBLIC_KEY_SIZE]u8, answer: []u8) -> (reason: Refusal_Reason, detail: u32, ok: bool) {
	row, paired := machine_mesh.paired_machine_find(&peer.paired, server_identity)
	body, refusal, refusal_detail, answer_ok := answer_expect(answer, .Pairing_Confirmed)
	if answer_ok && paired && len(body) == PAIRING_CONFIRMED_SIZE && machine_mesh.slices_equal_constant_time(body, row.transcript_fingerprint[:]) {
		return .None, 0, true
	}
	if paired {
		machine_mesh.paired_machine_remove(&peer.paired, server_identity)
		machine_grant_clear(peer, server_identity)
	}
	if answer_ok {
		return .Malformed, 0, false
	}
	return refusal, refusal_detail, false
}

// ---- Objects by hash ----

object_request_write :: proc "contextless" (output: []u8, kind: object_cache.Cache_Object_Kind, hash: blake3.Hash) -> []u8 {
	body, ok := frame_begin(output, .Object_Request, OBJECT_REQUEST_SIZE)
	if !ok {
		return nil
	}
	request_hash := hash
	byte_order.write_u32_little_endian(body, 0, u32(kind))
	byte_order.write_u32_little_endian(body, 4, 0)
	copy(body[8:], request_hash[:])
	return frame_bytes(output, body)
}

@(private)
serve_object_request :: proc "contextless" (peer: ^Peer, serve_context: ^Serve_Context, body: []u8, output: []u8) -> []u8 {
	if len(body) != OBJECT_REQUEST_SIZE || byte_order.read_u32_little_endian(body, 4) != 0 {
		return refusal_write(output, .Malformed, 0)
	}
	kind, kind_ok := object_cache.cache_object_kind_of_word(u64(byte_order.read_u32_little_endian(body, 0)))
	if !kind_ok {
		return refusal_write(output, .Malformed, 0)
	}
	hash: blake3.Hash
	copy(hash[:], body[8:])
	bytes, held_kind, found := machine_sync.object_store_lookup(&peer.objects, hash)
	if !found || held_kind != kind {
		return refusal_write(output, .Object_Absent, 0)
	}
	reply, ok := frame_begin(output, .Object_Response, OBJECT_RESPONSE_HEADER_SIZE + len(bytes))
	if !ok {
		return refusal_write(output, .Malformed, 0)
	}
	byte_order.write_u32_little_endian(reply, 0, u32(kind))
	byte_order.write_u32_little_endian(reply, 4, u32(len(bytes)))
	copy(reply[8:], hash[:])
	copy(reply[OBJECT_RESPONSE_HEADER_SIZE:], bytes)
	return frame_bytes(output, reply)
}

// object_publish keeps an object of this machine that its paired machines
// can fetch, only when its bytes hash to hash.
object_publish :: proc "contextless" (peer: ^Peer, kind: object_cache.Cache_Object_Kind, hash: blake3.Hash, bytes: []u8) -> machine_sync.Object_Store_Status {
	return machine_sync.object_store_accept(&peer.objects, kind, hash, bytes)
}

// object_lookup gives the bytes of an object that this machine keeps.
object_lookup :: proc "contextless" (peer: ^Peer, hash: blake3.Hash) -> []u8 {
	bytes, _, _ := machine_sync.object_store_lookup(&peer.objects, hash)
	return bytes
}

Object_Fetch_Status :: enum u8 {
	Stored         = 1,
	Already_Stored = 2,
	Refused        = 3, // The other machine answered with a Refusal.
	Malformed      = 4, // The answer broke the format.
	Other_Object   = 5, // The answer names another hash or another kind than the request.
	Hash_Mismatch  = 6, // The bytes do not hash to the requested hash: nothing was kept.
	Full           = 7,
	Too_Large      = 8,
}

// object_response_accept keeps the object of an answer to a request of
// this machine, only when its bytes hash to the requested hash: the hash is
// computed again before any byte is kept.
object_response_accept :: proc "contextless" (peer: ^Peer, kind: object_cache.Cache_Object_Kind, requested_hash: blake3.Hash, answer: []u8) -> (status: Object_Fetch_Status, reason: Refusal_Reason) {
	body, refusal, _, ok := answer_expect(answer, .Object_Response)
	if !ok {
		if refusal == .Malformed || refusal == .Unexpected_Message {
			return .Malformed, refusal
		}
		return .Refused, refusal
	}
	if len(body) < OBJECT_RESPONSE_HEADER_SIZE {
		return .Malformed, .None
	}
	count := u64(byte_order.read_u32_little_endian(body, 4))
	if count != u64(len(body) - OBJECT_RESPONSE_HEADER_SIZE) {
		return .Malformed, .None
	}
	answer_kind, kind_ok := object_cache.cache_object_kind_of_word(u64(byte_order.read_u32_little_endian(body, 0)))
	answer_hash: blake3.Hash
	copy(answer_hash[:], body[8:OBJECT_RESPONSE_HEADER_SIZE])
	if !kind_ok || answer_kind != kind || answer_hash != requested_hash {
		return .Other_Object, .None
	}
	switch machine_sync.object_store_accept(&peer.objects, kind, requested_hash, body[OBJECT_RESPONSE_HEADER_SIZE:]) {
	case .Stored:
		return .Stored, .None
	case .Already_Stored:
		return .Already_Stored, .None
	case .Refused_Hash_Mismatch:
		return .Hash_Mismatch, .None
	case .Refused_Full:
		return .Full, .None
	case .Refused_Too_Large:
		return .Too_Large, .None
	case .Refused_Malformed, .Refused_Nil_Input:
	}
	return .Malformed, .None
}

// ---- Signed grants ----

grant_present_write :: proc "contextless" (output: []u8, grant: ^machine_mesh.Signed_Grant) -> (frame: []u8, status: machine_mesh.Grant_Check_Status) {
	body, ok := frame_begin(output, .Grant_Present, machine_mesh.SIGNED_GRANT_WIRE_SIZE)
	if !ok {
		return nil, .Refused_Buffer_Too_Small
	}
	written, encode_status := machine_mesh.signed_grant_encode(grant, body)
	if encode_status != .Accepted || written != machine_mesh.SIGNED_GRANT_WIRE_SIZE {
		return nil, encode_status
	}
	return frame_bytes(output, body), .Accepted
}

// serve_grant_present checks a signed grant that a paired machine with the
// use Grants presents: the receiver is the principal root key that the
// transport proved, never a key that the frame names. With no proven
// principal, nothing is checked.
@(private)
serve_grant_present :: proc "contextless" (peer: ^Peer, serve_context: ^Serve_Context, body: []u8, output: []u8) -> []u8 {
	if machine_mesh.key_is_zero(serve_context.peer_root_public_key) {
		return refusal_write(output, .No_Principal, 0)
	}
	if !peer.machine_list.has_list {
		return refusal_write(output, .Grant_Refused, u32(machine_mesh.Grant_Check_Status.Refused_Grantor_Key_Not_Active))
	}
	grant, decode_status := machine_mesh.signed_grant_decode(body)
	if decode_status != .Accepted {
		return refusal_write(output, .Grant_Refused, u32(decode_status))
	}
	revocations: ^machine_mesh.Revocation_List = peer.has_revocations ? &peer.revocations : nil
	status := machine_mesh.signed_grant_check(&grant, &peer.machine_list.list, peer.identity.public_key, serve_context.peer_root_public_key, serve_context.now_ms, revocations, peer.services.signature_verify, peer.services.user_data)
	if status != .Accepted {
		return refusal_write(output, .Grant_Refused, u32(status))
	}
	reply, ok := frame_begin(output, .Grant_Accepted, GRANT_ACCEPTED_SIZE)
	if !ok {
		return refusal_write(output, .Malformed, 0)
	}
	byte_order.write_u64_little_endian(reply, 0, grant.grant_serial)
	byte_order.write_u64_little_endian(reply, 8, grant.expires_at_ms)
	return frame_bytes(output, reply)
}

grant_accepted_read :: proc "contextless" (answer: []u8) -> (serial: u64, expires_at_ms: u64, reason: Refusal_Reason, detail: u32, ok: bool) {
	body, refusal, refusal_detail, answer_ok := answer_expect(answer, .Grant_Accepted)
	if !answer_ok {
		return 0, 0, refusal, refusal_detail, false
	}
	if len(body) != GRANT_ACCEPTED_SIZE {
		return 0, 0, .Malformed, 0, false
	}
	return byte_order.read_u64_little_endian(body, 0), byte_order.read_u64_little_endian(body, 8), .None, 0, true
}

// ---- Store exchange ----

@(private)
serve_store_offer :: proc "contextless" (peer: ^Peer, serve_context: ^Serve_Context, body: []u8, output: []u8) -> []u8 {
	if len(body) < STORE_OFFER_HEADER_SIZE {
		return refusal_write(output, .Store_Refused, u32(Store_Status.Refused_Bad_Count))
	}
	identifier: blake3.Hash
	copy(identifier[:], body[:blake3.HASH_SIZE])
	store := store_exchange_find(&peer.stores, identifier)
	if store == nil {
		return refusal_write(output, .Store_Refused, u32(Store_Status.Refused_Unknown_Store))
	}
	if !machine_mesh.keys_equal_constant_time(store.partner_identity, serve_context.peer_identity) {
		return refusal_write(output, .Store_Refused, u32(Store_Status.Refused_Not_Partner))
	}
	// The whole offer is read and merged before the store changes.
	frame, status := store_offer_answer(store, body, output)
	if status != .Ok {
		return refusal_write(output, .Store_Refused, u32(status))
	}
	return frame
}

// ---- Role calls ----

@(private)
serve_role_call :: proc "contextless" (peer: ^Peer, grant: ^Machine_Grant, body: []u8, output: []u8) -> []u8 {
	call, ok := role_call_read(body)
	if !ok {
		return refusal_write(output, .Malformed, 0)
	}
	if call.role not_in grant.roles || peer.services.role_holder == nil {
		return refusal_write(output, .Role_Refused, u32(call.role))
	}
	result: [ROLE_RESULT_LIMIT]u8
	value, result_count, outcome := peer.services.role_holder(call.role, call.export, call.arguments, result[:], peer.services.user_data)
	// From here the holder ran: a fault of its answer is no refusal, since
	// the call can have changed the state of the holder.
	if result_count < 0 || result_count > len(result) {
		return refusal_write(output, .Role_Holder_Fault, u32(call.role))
	}
	switch outcome {
	case .Answered, .Refused:
	case .None, .Unknown_Outcome, .Unreachable:
		// A holder gives no outcome of a link.
		return refusal_write(output, .Role_Holder_Fault, u32(call.role))
	}
	reply := role_reply_write(output, Role_Reply{identifier = call.identifier, outcome = outcome, value = value, result = result[:result_count]})
	if reply == nil {
		return refusal_write(output, .Role_Holder_Fault, u32(call.role))
	}
	return reply
}

// ---- Relay ----

@(private)
serve_relay_deposit :: proc "contextless" (peer: ^Peer, serve_context: ^Serve_Context, body: []u8, output: []u8) -> []u8 {
	status := relay_deposit(&peer.relay, serve_context.peer_identity, body, serve_context.now_ms)
	if status != .Ok {
		return refusal_write(output, .Relay_Refused, u32(status))
	}
	reply, ok := frame_begin(output, .Relay_Deposited, 0)
	if !ok {
		return refusal_write(output, .Malformed, 0)
	}
	return frame_bytes(output, reply)
}

@(private)
serve_relay_collect :: proc "contextless" (peer: ^Peer, serve_context: ^Serve_Context, body: []u8, output: []u8) -> []u8 {
	if len(body) != RELAY_COLLECT_BODY_SIZE {
		return refusal_write(output, .Malformed, 0)
	}
	token: Routing_Token
	copy(token[:], body)
	frame, status := relay_collect(&peer.relay, serve_context.peer_identity, token, serve_context.now_ms, output)
	if status != .Ok {
		return refusal_write(output, .Relay_Refused, u32(status))
	}
	return frame
}
