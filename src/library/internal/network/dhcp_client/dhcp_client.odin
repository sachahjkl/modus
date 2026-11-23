// The DHCP client of the network service (src/md/features/dhcp_client.md):
// the messages that it writes, the border of each message that it reads,
// and the state machine with its times (RFC 2131). Pure code: the network
// service gives it the time and the data of each datagram to UDP port 68,
// and sends what it gives back; the host tests drive it with hostile
// messages and a clock of their own.
//
// This package allocates no memory and calls no kernel operation.
package dhcp_client

import "modus:contract/chosen_values"
import "modus:contract/plan_values"

CLIENT_PORT :: 68
SERVER_PORT :: 67
// The fixed part of a message and the magic cookie (RFC 2131, section 2).
FIXED_SIZE :: 236
MESSAGE_LEAST :: FIXED_SIZE + 4
// The longest message that the client writes: the 576 bytes that each
// machine takes, less the headers of IPv4 and UDP (section 2).
MESSAGE_CAPACITY :: 576 - 20 - 8
MAGIC_COOKIE :: u32(0x6382_5363)

// The waits of section 4.1: the first wait for an answer, doubled at each
// send up to the last one. No random part: this service is one client.
FIRST_WAIT_MILLISECONDS :: u64(4_000)
LAST_WAIT_MILLISECONDS :: u64(64_000)
// The wait between two sends while the client renews or rebinds a lease
// (section 4.4.5 gives 60 s as its least).
RENEW_WAIT_MILLISECONDS :: u64(60_000)
// The lease that never ends (section 3.3).
INFINITE_LEASE :: u32(0xFFFF_FFFF)

// The kinds of message of option 53 (RFC 2132, section 9.6). The values
// cross the network, so they are stated.
Message_Type :: enum u8 {
	Discover = 1,
	Offer    = 2,
	Request  = 3,
	Decline  = 4,
	Ack      = 5,
	Nak      = 6,
	Release  = 7,
	Inform   = 8,
}

// The options that the client reads or writes (RFC 2132).
OPTION_PAD :: 0
OPTION_SUBNET_MASK :: 1
OPTION_ROUTER :: 3
OPTION_REQUESTED_ADDRESS :: 50
OPTION_LEASE_TIME :: 51
OPTION_OVERLOAD :: 52
OPTION_MESSAGE_TYPE :: 53
OPTION_SERVER :: 54
OPTION_PARAMETERS :: 55
OPTION_RENEW_TIME :: 58
OPTION_REBIND_TIME :: 59
OPTION_END :: 255

// Why the border refused a message. A refused message changes nothing.
Reply_Problem :: enum u8 {
	None              = 0,
	Too_Short         = 1, // Fewer bytes than the fixed part and the magic cookie.
	Not_A_Reply       = 2, // The op is not BOOTREPLY (2).
	Not_Ethernet      = 3, // The hardware type is not 1 or its length not 6.
	Other_Transaction = 4, // The transaction word is not the word of the transaction in flight.
	Other_Client      = 5, // The hardware address is not the address of this device.
	No_Cookie         = 6,
	Option_Past_End   = 7, // An option whose length passes the end of the message.
	Bytes_After_End   = 8, // A byte after the option END that is not padding.
	Option_Twice      = 9,
	Bad_Option_Length = 10, // An option that the client reads with another length than its form.
	No_Message_Type   = 11,
	Bad_Message_Type  = 12, // A message type that is not OFFER, ACK or NAK.
	No_Server         = 13,
	No_Lease          = 14,
	Zero_Lease        = 15,
	Bad_Mask          = 16, // No subnet mask, a mask that is not ones then zeros, or a prefix shorter than 8 or longer than 30.
	Bad_Address       = 17, // An address that a machine of its subnet cannot hold.
	Router_Outside    = 18, // A router that is not an address of the subnet.
	Bad_Times         = 19, // T1, T2 and the lease are not in the order T1 < T2 < lease.
	Overload          = 20, // The option 52: the client reads no field file or sname.
}

// What a reply gives that passed the border.
Reply :: struct {
	kind:           Message_Type, // Offer, Ack or Nak.
	address:        u32, // yiaddr: the address offered or bound. 0 in a NAK.
	server:         u32, // The server identifier.
	mask:           u32,
	prefix:         u8,
	router:         u32, // 0: none.
	lease_seconds:  u32,
	renew_seconds:  u32, // T1.
	rebind_seconds: u32, // T2.
}

@(private)
be32 :: proc "contextless" (bytes: []u8, at: int) -> u32 {
	return u32(bytes[at]) << 24 | u32(bytes[at + 1]) << 16 | u32(bytes[at + 2]) << 8 | u32(bytes[at + 3])
}

@(private)
be32_put :: proc "contextless" (bytes: []u8, at: int, value: u32) {
	bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3] = u8(value >> 24), u8(value >> 16), u8(value >> 8), u8(value)
}

// prefix_of_mask gives the prefix of a mask of ones then zeros, and false
// for any other mask.
prefix_of_mask :: proc "contextless" (mask: u32) -> (prefix: u8, ok: bool) {
	ones := u8(0)
	for ones < 32 && mask & (u32(1) << (31 - u32(ones))) != 0 {
		ones += 1
	}
	expected := ones == 0 ? u32(0) : ~u32(0) << (32 - u32(ones))
	return ones, mask == expected
}

// address_holdable says if a machine of a subnet can hold an address: not
// 0.0.0.0, not 255.255.255.255, no loopback, multicast or reserved
// address, and not the address of the subnet or its broadcast address.
address_holdable :: proc "contextless" (address, mask: u32) -> bool {
	first := address >> 24
	switch {
	case address == 0, address == 0xFFFF_FFFF, first == 0, first == 127, first >= 224:
		return false
	case address & ~mask == 0, address & ~mask == ~mask:
		return false
	}
	return true
}

// reply_read is the border of a message to the client: the fixed part, the
// options, then the rules of an OFFER, an ACK or a NAK
// (src/md/features/dhcp_client.md, "The border of a message").
reply_read :: proc "contextless" (message: []u8, transaction: u32, hardware: [6]u8) -> (reply: Reply, problem: Reply_Problem) {
	if len(message) < MESSAGE_LEAST {
		return {}, .Too_Short
	}
	switch {
	case message[0] != 2:
		return {}, .Not_A_Reply
	case message[1] != 1 || message[2] != 6:
		return {}, .Not_Ethernet
	case be32(message, 4) != transaction:
		return {}, .Other_Transaction
	}
	for byte, index in hardware {
		if message[28 + index] != byte {
			return {}, .Other_Client
		}
	}
	if be32(message, FIXED_SIZE) != MAGIC_COOKIE {
		return {}, .No_Cookie
	}
	reply.address = be32(message, 16)
	seen: [256]bool
	has_type, has_server, has_lease, has_mask: bool
	type_word: u8
	at := MESSAGE_LEAST
	ended := false
	for at < len(message) {
		code := message[at]
		if ended {
			if code != OPTION_PAD {
				return {}, .Bytes_After_End
			}
			at += 1
			continue
		}
		switch code {
		case OPTION_PAD:
			at += 1
			continue
		case OPTION_END:
			ended = true
			at += 1
			continue
		}
		if at + 1 >= len(message) || int(message[at + 1]) > len(message) - at - 2 {
			return {}, .Option_Past_End
		}
		length := int(message[at + 1])
		value := message[at + 2:][:length]
		if seen[code] {
			return {}, .Option_Twice
		}
		seen[code] = true
		four := length == 4
		switch code {
		case OPTION_OVERLOAD:
			return {}, .Overload
		case OPTION_MESSAGE_TYPE:
			if length != 1 {
				return {}, .Bad_Option_Length
			}
			has_type, type_word = true, value[0]
		case OPTION_SERVER, OPTION_LEASE_TIME, OPTION_SUBNET_MASK, OPTION_RENEW_TIME, OPTION_REBIND_TIME:
			if !four {
				return {}, .Bad_Option_Length
			}
			word := be32(value, 0)
			switch code {
			case OPTION_SERVER:
				reply.server, has_server = word, true
			case OPTION_LEASE_TIME:
				reply.lease_seconds, has_lease = word, true
			case OPTION_SUBNET_MASK:
				reply.mask, has_mask = word, true
			case OPTION_RENEW_TIME:
				reply.renew_seconds = word
			case OPTION_REBIND_TIME:
				reply.rebind_seconds = word
			}
		case OPTION_ROUTER:
			// A list of routers: the client takes the first.
			if length < 4 || length % 4 != 0 {
				return {}, .Bad_Option_Length
			}
			reply.router = be32(value, 0)
		}
		at += 2 + length
	}
	if !has_type {
		return {}, .No_Message_Type
	}
	switch type_word {
	case u8(Message_Type.Offer):
		reply.kind = .Offer
	case u8(Message_Type.Ack):
		reply.kind = .Ack
	case u8(Message_Type.Nak):
		reply.kind = .Nak
	case:
		return {}, .Bad_Message_Type
	}
	if !has_server {
		return {}, .No_Server
	}
	if reply.kind == .Nak {
		return {kind = .Nak, server = reply.server}, .None
	}
	switch {
	case !has_lease:
		return {}, .No_Lease
	case reply.lease_seconds == 0:
		return {}, .Zero_Lease
	case !has_mask:
		return {}, .Bad_Mask
	}
	prefix, mask_ok := prefix_of_mask(reply.mask)
	if !mask_ok || prefix < 8 || prefix > 30 {
		return {}, .Bad_Mask
	}
	reply.prefix = prefix
	if !address_holdable(reply.address, reply.mask) {
		return {}, .Bad_Address
	}
	if reply.router != 0 && (reply.router & reply.mask != reply.address & reply.mask || !address_holdable(reply.router, reply.mask)) {
		return {}, .Router_Outside
	}
	if reply.lease_seconds != INFINITE_LEASE {
		if reply.renew_seconds == 0 {
			reply.renew_seconds = reply.lease_seconds / 2
		}
		if reply.rebind_seconds == 0 {
			reply.rebind_seconds = u32(u64(reply.lease_seconds) * 7 / 8)
		}
		if !(reply.renew_seconds < reply.rebind_seconds && reply.rebind_seconds < reply.lease_seconds) {
			return {}, .Bad_Times
		}
	}
	return reply, .None
}

// What the client asks the caller to do.
Output :: struct {
	send:        bool, // Send the message of `length` bytes that the client wrote in the buffer of the caller.
	broadcast:   bool, // To 255.255.255.255 from 0.0.0.0; else to `destination` from the address bound.
	destination: u32,
	length:      int,
	event:       Event,
}

// A change of the address that the caller applies.
Event :: enum u8 {
	None    = 0,
	Bound   = 1, // The client holds `lease` now: the caller takes its address, mask and router.
	Renewed = 2, // The lease of the address held is longer: the address does not change.
	Lost    = 3, // The client holds no address: the lease ended, or the server refused it.
}

// The phase of the client (section 4.4, figure 5).
Phase :: enum u8 {
	Init       = 0, // No address, no message in flight: the next tick sends a DISCOVER.
	Selecting  = 1, // A DISCOVER is in flight.
	Requesting = 2, // A REQUEST of an offer is in flight.
	Bound      = 3,
	Renewing   = 4, // After T1: a REQUEST to the server of the lease.
	Rebinding  = 5, // After T2: a REQUEST to any server.
}

// The state of the client. A record of zeros is a client in Init.
Client :: struct {
	phase:       Phase,
	hardware:    [6]u8,
	transaction: u32,
	offer:       Reply, // Requesting: the offer that the REQUEST names.
	lease:       Reply, // Bound, Renewing, Rebinding: the lease held.
	bound_at:    u64, // The time of the ACK of the lease held, in milliseconds.
	wait:        u64, // The wait of the message in flight.
	deadline:    u64, // The time of the next tick that does something; max(u64): none.
}

// message_write writes a DISCOVER or a REQUEST. A REQUEST of an offer names
// the address and the server (Requesting); a REQUEST of a lease held puts
// the address in ciaddr and names nothing (Renewing, Rebinding).
@(private)
message_write :: proc "contextless" (out: []u8, client: ^Client, kind: Message_Type) -> int {
	if len(out) < MESSAGE_CAPACITY {
		return 0
	}
	for &byte in out[:MESSAGE_CAPACITY] {
		byte = 0
	}
	out[0], out[1], out[2] = 1, 1, 6
	be32_put(out, 4, client.transaction)
	holding := client.phase == .Renewing || client.phase == .Rebinding
	if holding {
		be32_put(out, 12, client.lease.address)
	} else {
		// The flag BROADCAST: a client with no address asks the answer by
		// broadcast.
		out[10] = 0x80
	}
	copy(out[28:34], client.hardware[:])
	be32_put(out, FIXED_SIZE, MAGIC_COOKIE)
	at := MESSAGE_LEAST
	out[at], out[at + 1], out[at + 2] = OPTION_MESSAGE_TYPE, 1, u8(kind)
	at += 3
	if kind == .Request && client.phase == .Requesting {
		out[at], out[at + 1] = OPTION_REQUESTED_ADDRESS, 4
		be32_put(out, at + 2, client.offer.address)
		at += 6
		out[at], out[at + 1] = OPTION_SERVER, 4
		be32_put(out, at + 2, client.offer.server)
		at += 6
	}
	parameters := [6]u8{OPTION_SUBNET_MASK, OPTION_ROUTER, OPTION_LEASE_TIME, OPTION_SERVER, OPTION_RENEW_TIME, OPTION_REBIND_TIME}
	out[at], out[at + 1] = OPTION_PARAMETERS, u8(len(parameters))
	copy(out[at + 2:], parameters[:])
	at += 2 + len(parameters)
	out[at] = OPTION_END
	return MESSAGE_LEAST + 64 // A fixed length, with room after END: padding.
}

// client_start starts a client of a device: the first tick sends a
// DISCOVER.
client_start :: proc "contextless" (client: ^Client, hardware: [6]u8, now: u64) {
	client^ = {phase = .Init, hardware = hardware, deadline = now}
}

// send_in_flight writes the message of the phase and sets the wait.
@(private)
send_in_flight :: proc "contextless" (client: ^Client, out: []u8, now: u64, kind: Message_Type, wait: u64) -> Output {
	client.wait = wait
	client.deadline = now + wait
	length := message_write(out, client, kind)
	unicast := client.phase == .Renewing
	return {send = length > 0, broadcast = !unicast, destination = unicast ? client.lease.server : 0xFFFF_FFFF, length = length}
}

// lease_deadline gives the next time of a lease held: T1, T2 or its end.
@(private)
lease_deadline :: proc "contextless" (client: ^Client) -> u64 {
	if client.lease.lease_seconds == INFINITE_LEASE {
		return max(u64)
	}
	seconds: u32
	switch client.phase {
	case .Bound:
		seconds = client.lease.renew_seconds
	case .Renewing:
		seconds = client.lease.rebind_seconds
	case .Rebinding, .Init, .Selecting, .Requesting:
		seconds = client.lease.lease_seconds
	}
	return client.bound_at + u64(seconds) * 1000
}

// client_tick runs what is due at the time `now`: the first DISCOVER, a
// send again after its wait, T1, T2, or the end of the lease. transaction
// is a fresh word of the generator: the client takes it for a new
// transaction only.
client_tick :: proc "contextless" (client: ^Client, out: []u8, now: u64, transaction: u32) -> Output {
	if now < client.deadline {
		return {}
	}
	switch client.phase {
	case .Init:
		client.phase, client.transaction = .Selecting, transaction
		return send_in_flight(client, out, now, .Discover, FIRST_WAIT_MILLISECONDS)
	case .Selecting:
		return send_in_flight(client, out, now, .Discover, min(client.wait * 2, LAST_WAIT_MILLISECONDS))
	case .Requesting:
		if client.wait >= LAST_WAIT_MILLISECONDS {
			// No ACK after the last wait: the offer is gone.
			client.phase, client.transaction = .Selecting, transaction
			return send_in_flight(client, out, now, .Discover, FIRST_WAIT_MILLISECONDS)
		}
		return send_in_flight(client, out, now, .Request, min(client.wait * 2, LAST_WAIT_MILLISECONDS))
	case .Bound, .Renewing, .Rebinding:
		end := client.bound_at + u64(client.lease.lease_seconds) * 1000
		if client.lease.lease_seconds != INFINITE_LEASE && now >= end {
			client^ = {phase = .Init, hardware = client.hardware, deadline = now}
			return {event = .Lost}
		}
		switch {
		case client.phase == .Bound:
			client.phase, client.transaction = .Renewing, transaction
		case client.phase == .Renewing && now >= client.bound_at + u64(client.lease.rebind_seconds) * 1000:
			client.phase, client.transaction = .Rebinding, transaction
		}
		output := send_in_flight(client, out, now, .Request, RENEW_WAIT_MILLISECONDS)
		// The next tick: the next send, or the next time of the lease if it
		// comes first.
		client.deadline = min(client.deadline, lease_deadline(client))
		return output
	}
	return {}
}

// client_receive takes the data of a datagram to the client port. A
// message that the border refuses, or that the phase does not wait for,
// changes nothing.
client_receive :: proc "contextless" (client: ^Client, message: []u8, out: []u8, now: u64) -> (output: Output, problem: Reply_Problem) {
	if client.phase == .Init || client.phase == .Bound {
		return {}, .None
	}
	reply: Reply
	reply, problem = reply_read(message, client.transaction, client.hardware)
	if problem != .None {
		return {}, problem
	}
	switch client.phase {
	case .Init, .Bound:
	case .Selecting:
		if reply.kind != .Offer {
			return {}, .None
		}
		client.offer = reply
		client.phase = .Requesting
		return send_in_flight(client, out, now, .Request, FIRST_WAIT_MILLISECONDS), .None
	case .Requesting:
		if reply.server != client.offer.server {
			return {}, .None
		}
		switch reply.kind {
		case .Nak:
			client^ = {phase = .Init, hardware = client.hardware, deadline = now}
			return {}, .None
		case .Ack:
			if reply.address != client.offer.address {
				return {}, .None
			}
			client.lease, client.bound_at, client.phase = reply, now, .Bound
			client.deadline = lease_deadline(client)
			return {event = .Bound}, .None
		case .Offer, .Discover, .Request, .Decline, .Release, .Inform:
			return {}, .None
		}
	case .Renewing, .Rebinding:
		if client.phase == .Renewing && reply.server != client.lease.server {
			return {}, .None
		}
		switch reply.kind {
		case .Nak:
			client^ = {phase = .Init, hardware = client.hardware, deadline = now}
			return {event = .Lost}, .None
		case .Ack:
			// The same address: a new address would move each endpoint.
			if reply.address != client.lease.address {
				return {}, .None
			}
			client.lease, client.bound_at, client.phase = reply, now, .Bound
			client.deadline = lease_deadline(client)
			return {event = .Renewed}, .None
		case .Offer, .Discover, .Request, .Decline, .Release, .Inform:
			return {}, .None
		}
	}
	return {}, .None
}
// The fields of the plan values of the owner `network`: a static address
// of the machine, its prefix, and the gateway (0: none). Only the plan of
// principal 0 gives them: an address of the machine is a plan-only value
// (src/md/features/dhcp_client.md).
STATIC_ADDRESS_FIELD :: "static_address"
STATIC_PREFIX_FIELD :: "static_prefix"
STATIC_GATEWAY_FIELD :: "static_gateway"

// A static address of the plan, as the service takes it.
Static :: struct {
	address: u32,
	mask:    u32,
	prefix:  u8,
	gateway: u32, // 0: no gateway.
}

// static_of is the border of the static address of the plan: the rules of
// an address of a reply (address_holdable, a prefix from 8 to 30, a
// gateway inside the subnet), the one border of each address that the
// service takes. found is false when the plan gives no address: the
// service asks DHCP. refused is true when the plan gives an address that
// the border refuses: the service asks DHCP, and the log says why.
static_of :: proc "contextless" (plan: plan_values.Owner_Values) -> (static: Static, found: bool, refused: bool) {
	any :: proc "contextless" (word: u64) -> bool {return true}
	empty: chosen_values.Record
	address, _, has_address := plan_values.value_in_force(STATIC_ADDRESS_FIELD, empty, plan, any)
	prefix, _, has_prefix := plan_values.value_in_force(STATIC_PREFIX_FIELD, empty, plan, any)
	gateway, _, has_gateway := plan_values.value_in_force(STATIC_GATEWAY_FIELD, empty, plan, any)
	if !has_address && !has_prefix && !has_gateway {
		return {}, false, false
	}
	if !has_address || !has_prefix || address > u64(max(u32)) || prefix < 8 || prefix > 30 || gateway > u64(max(u32)) {
		return {}, true, true
	}
	mask := ~u32(0) << (32 - u32(prefix))
	if !address_holdable(u32(address), mask) {
		return {}, true, true
	}
	if gateway != 0 && (u32(gateway) & mask != u32(address) & mask || !address_holdable(u32(gateway), mask) || gateway == address) {
		return {}, true, true
	}
	return {address = u32(address), mask = mask, prefix = u8(prefix), gateway = u32(gateway)}, true, false
}
