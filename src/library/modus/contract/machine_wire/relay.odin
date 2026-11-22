// The relay envelope: an opaque datagram that a relay machine carries
// between two machines that cannot reach each other
// (src/md/features/several_machines.md, "The relay envelope").
//
// The two end machines share a key from their pairing. The sender seals the
// datagram with an AEAD (ChaCha20-Poly1305) under that key, with the routing
// token as its associated data, and the relay sees only the routing token
// and the sealed bytes: no identity key, no address of an end, no byte of
// plaintext. The relay holds no key, so it cannot open, change or forge an
// envelope: it keeps the bytes of a deposit unchanged and gives them to a
// machine that collects for the token.
//
// The routing token is a keyed hash of the shared key and an epoch, so the
// relay cannot link two epochs of one pair, and a party without the key
// cannot name a route that the relay holds. A route exists only when the
// principal of the relay machine adds its token.
package machine_wire

import "modus:contract/blake3"
import "modus:contract/byte_order"

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
ROUTING_TOKEN_DOMAIN :: "modus relay routing token v1"

Routing_Token :: [ROUTING_TOKEN_SIZE]u8

Relay_Envelope :: struct {
	token:  Routing_Token,
	sealed: []u8, // A view of the input bytes.
}

Relay_Status :: enum u8 {
	Ok                     = 1,
	Refused_Zero_Token     = 2,
	Refused_Unknown_Token  = 3, // No route of the relay has this token.
	Refused_Too_Short      = 4, // Fewer sealed bytes than a nonce and a tag.
	Refused_Too_Large      = 5,
	Refused_Length_Differs = 6, // The count of sealed bytes differs from the bytes of the body.
	Refused_Reserved_Set   = 7,
	Refused_Queue_Full     = 8,
	Refused_Empty          = 9, // No envelope waits on the route.
	Refused_Table_Full     = 10,
	Refused_Exists         = 11,
}

// relay_routing_token derives the token of one epoch of a pair from the key
// that the two end machines share.
relay_routing_token :: proc "contextless" (shared_key: [32]u8, epoch: u64) -> (token: Routing_Token) {
	input: [40]u8
	key := shared_key
	copy(input[:32], key[:])
	byte_order.write_u64_little_endian(input[:], 32, epoch)
	derived := blake3.derive_key(ROUTING_TOKEN_DOMAIN, input[:])
	copy(token[:], derived[:ROUTING_TOKEN_SIZE])
	return token
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
	count: int, // The bytes of the body of the deposit.
	bytes: [RELAY_ENVELOPE_LIMIT]u8,
}

Relay_Route :: struct {
	in_use: bool,
	token:  Routing_Token,
	held:   [RELAY_QUEUE_DEPTH]Relay_Held_Envelope,
	first:  int,
	count:  int,
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
// the token of a pair that it relays for.
relay_route_add :: proc "contextless" (table: ^Relay_Table, token: Routing_Token) -> Relay_Status {
	if token_is_zero(token) {
		return .Refused_Zero_Token
	}
	if relay_route_find(table, token) != nil {
		return .Refused_Exists
	}
	for &route in table.routes {
		if !route.in_use {
			route = Relay_Route{in_use = true, token = token}
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

// relay_deposit keeps the body of a deposit on the route of its token,
// unchanged: the relay neither opens nor checks the sealed bytes.
relay_deposit :: proc "contextless" (table: ^Relay_Table, body: []u8) -> Relay_Status {
	envelope, status := relay_envelope_read(body)
	if status != .Ok {
		return status
	}
	route := relay_route_find(table, envelope.token)
	if route == nil {
		return .Refused_Unknown_Token
	}
	if route.count >= RELAY_QUEUE_DEPTH {
		return .Refused_Queue_Full
	}
	held := &route.held[(route.first + route.count) % RELAY_QUEUE_DEPTH]
	held.count = copy(held.bytes[:], body)
	route.count += 1
	return .Ok
}

// relay_collect gives the oldest envelope of a route as a Relay_Delivery
// frame, byte for byte the body that was deposited, and frees its place.
relay_collect :: proc "contextless" (table: ^Relay_Table, token: Routing_Token, output: []u8) -> (frame: []u8, status: Relay_Status) {
	if token_is_zero(token) {
		return nil, .Refused_Zero_Token
	}
	route := relay_route_find(table, token)
	if route == nil {
		return nil, .Refused_Unknown_Token
	}
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
