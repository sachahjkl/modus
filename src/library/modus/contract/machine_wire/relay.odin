// The relay envelope: an opaque datagram that a relay machine carries
// between two machines that cannot reach each other
// (src/md/features/several_machines.md, "The relay envelope").
//
// The two end machines share a key from their pairing. The sender seals the
// datagram with an AEAD (ChaCha20-Poly1305) under that key, with the routing
// token as its associated data. The envelope holds only the routing token
// and the sealed bytes: no identity key, no address, no byte of plaintext.
// The relay holds no key, so it cannot open, change or forge an envelope.
// It knows the two ends of each route, which its principal named, and the
// identity keys that the handshakes of their connections proved.
//
// A route has one sender and one receiver: only the sender deposits on it,
// and only the receiver collects. Two directions are two routes. A request
// of a machine that is not the bound end of the route gets the same refusal
// as an unknown token, so a paired machine learns nothing of the routes of
// others. An envelope that waits past its lifetime is dropped.
//
// The routing token is a keyed hash of the shared key and an epoch, so the
// relay cannot link two epochs of one pair.
package machine_wire

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/machine_mesh"

ROUTING_TOKEN_SIZE :: 16
RELAY_NONCE_SIZE :: 12
RELAY_TAG_SIZE :: 16
// The sealed bytes: the nonce, then the AEAD ciphertext with its tag.
RELAY_SEALED_MINIMUM :: RELAY_NONCE_SIZE + RELAY_TAG_SIZE
RELAY_SEALED_LIMIT :: 1200
RELAY_ENVELOPE_HEADER_SIZE :: ROUTING_TOKEN_SIZE + 8 // The token, the count of sealed bytes, a zero word.
RELAY_ENVELOPE_LIMIT :: RELAY_ENVELOPE_HEADER_SIZE + RELAY_SEALED_LIMIT
RELAY_ROUTE_CAPACITY :: 4
RELAY_QUEUE_DEPTH :: 2 // Envelopes that wait on one route: a sender past it is refused, never dropped in silence.
RELAY_ENVELOPE_LIFETIME_MS :: 60_000 // An envelope that waits longer is dropped: a datagram of a link is late after it.
ROUTING_TOKEN_DOMAIN :: "modus relay routing token v1"
RELAY_DIRECTION_KEY_DOMAIN :: "modus relay directional key v1"
// Format property: ChaCha20-Poly1305 associated data binding sender identity,
// receiver identity, and routing token (32 + 32 + 16 = 80 bytes).
RELAY_AAD_SIZE :: machine_mesh.PUBLIC_KEY_SIZE + machine_mesh.PUBLIC_KEY_SIZE + ROUTING_TOKEN_SIZE

Routing_Token :: [ROUTING_TOKEN_SIZE]u8

Relay_Envelope :: struct {
	token:  Routing_Token,
	sealed: []u8, // A view of the input bytes.
}

Relay_Status :: enum u8 {
	Ok                     = 1,
	Refused_Zero_Token     = 2,
	Refused_Unknown_Token  = 3, // No route of the relay has this token with the sender as its bound end.
	Refused_Too_Short      = 4, // Fewer sealed bytes than a nonce and a tag.
	Refused_Too_Large      = 5,
	Refused_Length_Differs = 6, // The count of sealed bytes differs from the bytes of the body.
	Refused_Reserved_Set   = 7,
	Refused_Queue_Full     = 8,
	Refused_Empty          = 9, // No envelope waits on the route.
	Refused_Table_Full     = 10,
	Refused_Exists         = 11,
	Refused_Bad_Ends       = 12, // A route whose sender or receiver is zero, or the same machine.
}

// relay_routing_token derives the token of one epoch of a pair from the key
// that the two end machines share.
relay_routing_token :: proc "contextless" (shared_key: [32]u8, epoch: u64) -> (token: Routing_Token) {
	input: [40]u8
	key := shared_key
	defer machine_mesh.clear_bytes_explicitly(key[:])
	defer machine_mesh.clear_bytes_explicitly(input[:])
	copy(input[:32], key[:])
	byte_order.write_u64_little_endian(input[:], 32, epoch)
	derived := blake3.derive_key(ROUTING_TOKEN_DOMAIN, input[:])
	defer machine_mesh.clear_bytes_explicitly(derived[:])
	copy(token[:], derived[:ROUTING_TOKEN_SIZE])
	return token
}

// relay_directional_key derives a direction-bound AEAD key for envelopes from
// sender to receiver, preventing reflection attacks where a relay echoes a
// sender's own sealed envelope back to the sender.
relay_directional_key :: proc "contextless" (shared_key: [32]u8, sender, receiver: [32]u8) -> (directional_key: [32]u8) {
	input: [96]u8
	key := shared_key
	sender_copy := sender
	receiver_copy := receiver
	defer machine_mesh.clear_bytes_explicitly(key[:])
	defer machine_mesh.clear_bytes_explicitly(input[:])
	copy(input[0:32], key[:])
	copy(input[32:64], sender_copy[:])
	copy(input[64:96], receiver_copy[:])
	return blake3.derive_key(RELAY_DIRECTION_KEY_DOMAIN, input[:])
}

// relay_directional_routing_token derives a direction-bound routing token for
// sender -> receiver in epoch so a relay can host both directions of a pair in
// the same epoch without token collision.
relay_directional_routing_token :: proc "contextless" (shared_key: [32]u8, sender, receiver: [32]u8, epoch: u64) -> (token: Routing_Token) {
	dir_key := relay_directional_key(shared_key, sender, receiver)
	defer machine_mesh.clear_bytes_explicitly(dir_key[:])
	return relay_routing_token(dir_key, epoch)
}

// relay_envelope_aad builds the 80-byte AEAD associated data binding sender,
// receiver, and routing token for a sealed relay envelope.
relay_envelope_aad :: proc "contextless" (sender, receiver: [32]u8, token: Routing_Token) -> (aad: [RELAY_AAD_SIZE]u8) {
	sender_copy := sender
	receiver_copy := receiver
	token_copy := token
	copy(aad[0:32], sender_copy[:])
	copy(aad[32:64], receiver_copy[:])
	copy(aad[64:80], token_copy[:])
	return aad
}

@(private)
token_is_zero :: proc "contextless" (token: Routing_Token) -> bool {
	accumulated: u8
	for value in token {
		accumulated |= value
	}
	return accumulated == 0
}

// relay_envelope_write writes a Relay_Deposit or a Relay_Delivery frame.
relay_envelope_write :: proc "contextless" (output: []u8, message: Message, token: Routing_Token, sealed: []u8) -> (frame: []u8, status: Relay_Status) {
	switch {
	case token_is_zero(token):
		return nil, .Refused_Zero_Token
	case len(sealed) < RELAY_SEALED_MINIMUM:
		return nil, .Refused_Too_Short
	case len(sealed) > RELAY_SEALED_LIMIT || (message != .Relay_Deposit && message != .Relay_Delivery):
		return nil, .Refused_Too_Large
	}
	body, ok := frame_begin(output, message, RELAY_ENVELOPE_HEADER_SIZE + len(sealed))
	if !ok {
		return nil, .Refused_Too_Large
	}
	write_token := token
	copy(body[:ROUTING_TOKEN_SIZE], write_token[:])
	byte_order.write_u32_little_endian(body, ROUTING_TOKEN_SIZE, u32(len(sealed)))
	byte_order.write_u32_little_endian(body, ROUTING_TOKEN_SIZE + 4, 0)
	copy(body[RELAY_ENVELOPE_HEADER_SIZE:], sealed)
	return frame_bytes(output, body), .Ok
}

// relay_envelope_read is the border of an envelope body. It reads the
// token and the count; it never reads the sealed bytes.
relay_envelope_read :: proc "contextless" (body: []u8) -> (envelope: Relay_Envelope, status: Relay_Status) {
	if len(body) < RELAY_ENVELOPE_HEADER_SIZE {
		return {}, .Refused_Too_Short
	}
	copy(envelope.token[:], body[:ROUTING_TOKEN_SIZE])
	count := u64(byte_order.read_u32_little_endian(body, ROUTING_TOKEN_SIZE))
	switch {
	case token_is_zero(envelope.token):
		return {}, .Refused_Zero_Token
	case byte_order.read_u32_little_endian(body, ROUTING_TOKEN_SIZE + 4) != 0:
		return {}, .Refused_Reserved_Set
	case count != u64(len(body) - RELAY_ENVELOPE_HEADER_SIZE):
		return {}, .Refused_Length_Differs
	case count < RELAY_SEALED_MINIMUM:
		return {}, .Refused_Too_Short
	case count > RELAY_SEALED_LIMIT:
		return {}, .Refused_Too_Large
	}
	envelope.sealed = body[RELAY_ENVELOPE_HEADER_SIZE:]
	return envelope, .Ok
}

Relay_Held_Envelope :: struct {
	deposited_at_ms: u64,
	count:           int, // The bytes of the body of the deposit.
	bytes:           [RELAY_ENVELOPE_LIMIT]u8,
}

Relay_Route :: struct {
	in_use:   bool,
	token:    Routing_Token,
	sender:   [32]u8, // The one machine that deposits on the route.
	receiver: [32]u8, // The one machine that collects from it.
	held:     [RELAY_QUEUE_DEPTH]Relay_Held_Envelope,
	first:    int,
	count:    int,
}

Relay_Table :: struct {
	routes: [RELAY_ROUTE_CAPACITY]Relay_Route,
}

@(private)
relay_route_find :: proc "contextless" (table: ^Relay_Table, token: Routing_Token) -> ^Relay_Route {
	for &route in table.routes {
		if route.in_use && route.token == token {
			return &route
		}
	}
	return nil
}

// relay_route_add opens a route: the principal of the relay machine names
// the token of a pair, the machine that sends on it and the machine that
// receives.
relay_route_add :: proc "contextless" (table: ^Relay_Table, token: Routing_Token, sender, receiver: [32]u8) -> Relay_Status {
	if token_is_zero(token) {
		return .Refused_Zero_Token
	}
	if machine_mesh.key_is_zero(sender) || machine_mesh.key_is_zero(receiver) || sender == receiver {
		return .Refused_Bad_Ends
	}
	if relay_route_find(table, token) != nil {
		return .Refused_Exists
	}
	for &route in table.routes {
		if !route.in_use {
			route = Relay_Route{in_use = true, token = token, sender = sender, receiver = receiver}
			return .Ok
		}
	}
	return .Refused_Table_Full
}

// relay_route_remove closes a route and erases what waits on it.
relay_route_remove :: proc "contextless" (table: ^Relay_Table, token: Routing_Token) -> Relay_Status {
	route := relay_route_find(table, token)
	if route == nil {
		return .Refused_Unknown_Token
	}
	route^ = {}
	return .Ok
}

// relay_drop_expired erases the envelopes at the head of a route that
// waited past their lifetime.
@(private)
relay_drop_expired :: proc "contextless" (route: ^Relay_Route, now_ms: u64) {
	for route.count > 0 {
		held := &route.held[route.first]
		if now_ms < held.deposited_at_ms || now_ms - held.deposited_at_ms < RELAY_ENVELOPE_LIFETIME_MS {
			return
		}
		held^ = {}
		route.first = (route.first + 1) % RELAY_QUEUE_DEPTH
		route.count -= 1
	}
}

// relay_deposit keeps the body of a deposit of the sender of its route,
// unchanged: the relay neither opens nor checks the sealed bytes.
relay_deposit :: proc "contextless" (table: ^Relay_Table, sender: [32]u8, body: []u8, now_ms: u64) -> Relay_Status {
	envelope, status := relay_envelope_read(body)
	if status != .Ok {
		return status
	}
	route := relay_route_find(table, envelope.token)
	if route == nil || !machine_mesh.keys_equal_constant_time(route.sender, sender) {
		return .Refused_Unknown_Token
	}
	relay_drop_expired(route, now_ms)
	if route.count >= RELAY_QUEUE_DEPTH {
		return .Refused_Queue_Full
	}
	held := &route.held[(route.first + route.count) % RELAY_QUEUE_DEPTH]
	held.deposited_at_ms = now_ms
	held.count = copy(held.bytes[:], body)
	route.count += 1
	return .Ok
}

// relay_collect gives the receiver of a route its oldest envelope as a
// Relay_Delivery frame, byte for byte the body that was deposited, and
// frees its place.
relay_collect :: proc "contextless" (table: ^Relay_Table, receiver: [32]u8, token: Routing_Token, now_ms: u64, output: []u8) -> (frame: []u8, status: Relay_Status) {
	if token_is_zero(token) {
		return nil, .Refused_Zero_Token
	}
	route := relay_route_find(table, token)
	if route == nil || !machine_mesh.keys_equal_constant_time(route.receiver, receiver) {
		return nil, .Refused_Unknown_Token
	}
	relay_drop_expired(route, now_ms)
	if route.count == 0 {
		return nil, .Refused_Empty
	}
	held := &route.held[route.first]
	body, ok := frame_begin(output, .Relay_Delivery, held.count)
	if !ok {
		return nil, .Refused_Too_Large
	}
	copy(body, held.bytes[:held.count])
	held^ = {}
	route.first = (route.first + 1) % RELAY_QUEUE_DEPTH
	route.count -= 1
	return frame_bytes(output, body), .Ok
}

RELAY_COLLECT_BODY_SIZE :: ROUTING_TOKEN_SIZE

relay_collect_write :: proc "contextless" (output: []u8, token: Routing_Token) -> []u8 {
	body, ok := frame_begin(output, .Relay_Collect, RELAY_COLLECT_BODY_SIZE)
	if !ok {
		return nil
	}
	write_token := token
	copy(body, write_token[:])
	return frame_bytes(output, body)
}
