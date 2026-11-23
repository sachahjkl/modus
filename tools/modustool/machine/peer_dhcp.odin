package machine

// The DHCP server of the peer (src/md/features/dhcp_client.md): the network
// service of the machine asks its address of the peer, as of a server of a
// real network. The peer reads and writes the messages with its own code,
// not with internal:network/dhcp_client, so a fault of the client in a
// field is a fault that the peer sees.
//
// The hostile case: the peer answers the first DISCOVER with an OFFER whose
// router is outside the subnet, then with the correct OFFER. The client
// refuses the first whole and takes the second: the machine test waits for
// the line of the refusal, then for the line of the address.

import "core:sync"

DHCP_SERVER_PORT :: 67
DHCP_CLIENT_PORT :: 68
DHCP_MAGIC_COOKIE :: 0x6382_5363
// The lease of the peer: one hour, longer than each machine test.
DHCP_LEASE_SECONDS :: 3600
// The router of the hostile OFFER: 10.0.3.2, outside 10.0.2.0/24.
@(rodata)
DHCP_ROUTER_OUTSIDE := [4]u8{10, 0, 3, 2}

// What the peer counts of DHCP, for the line of the check.
Peer_Dhcp :: struct {
	offers:      int,
	acks:        int,
	hostile_sent: bool,
	firmware:    int, // Messages of the firmware (option 60): the peer does not answer them.
}

// peer_dhcp takes a frame of the machine: true when it is a DHCP message
// from port 68 to port 67, which the peer answers here. A message that
// breaks the form of the client is a wrong frame.
peer_dhcp :: proc(peer: ^Peer, frame: []u8) -> bool {
	if len(frame) < 42 || be16(frame, 12) != 0x0800 || frame[23] != 17 || be16(frame, 34) != DHCP_CLIENT_PORT || be16(frame, 36) != DHCP_SERVER_PORT {
		return false
	}
	ip_length := be16(frame, 16)
	if 14 + ip_length > len(frame) || ip_length < 20 + 8 + 240 {
		peer_wrong(peer, "a DHCP message shorter than its fixed part")
		return true
	}
	message := frame[42:14 + ip_length]
	if message[0] != 1 || message[1] != 1 || message[2] != 6 || be32_at(message, 236) != DHCP_MAGIC_COOKIE {
		peer_wrong(peer, "a DHCP message with a wrong fixed part")
		return true
	}
	kind := 0
	requested: [4]u8
	at := 240
	for at < len(message) && message[at] != 255 {
		code := message[at]
		if code == 0 {
			at += 1
			continue
		}
		if at + 1 >= len(message) || at + 2 + int(message[at + 1]) > len(message) {
			peer_wrong(peer, "a DHCP option past the end of its message")
			return true
		}
		length := int(message[at + 1])
		value := message[at + 2:][:length]
		switch code {
		case 53:
			if length == 1 {
				kind = int(value[0])
			}
		case 50:
			if length == 4 {
				copy(requested[:], value)
			}
		case 60:
			// The vendor class of the firmware: its own stack, before the
			// network service. The network service sends none.
			peer.dhcp.firmware += 1
			return true
		}
		at += 2 + length
	}
	switch kind {
	case 1: // DISCOVER
		if !peer.dhcp.hostile_sent {
			peer.dhcp.hostile_sent = true
			peer_send(peer, peer_dhcp_reply(peer, message, 2, DHCP_ROUTER_OUTSIDE))
		}
		peer_send(peer, peer_dhcp_reply(peer, message, 2, PEER_ADDRESS))
		peer.dhcp.offers += 1
	case 3: // REQUEST: of the offer, or the renewal of the lease (ciaddr).
		ciaddr := address_of_bytes(message[12:16])
		if requested != MACHINE_ADDRESS && ciaddr != MACHINE_ADDRESS {
			peer_wrong(peer, "a DHCP REQUEST of another address")
			return true
		}
		peer_send(peer, peer_dhcp_reply(peer, message, 5, PEER_ADDRESS))
		peer.dhcp.acks += 1
	case:
		peer_wrong(peer, "a DHCP message that is not a DISCOVER or a REQUEST")
	}
	return true
}

// peer_dhcp_reply writes an OFFER (2) or an ACK (5) of 10.0.2.15/24 to
// the broadcast address, with a router, the server 10.0.2.2 and the lease.
@(private = "file")
peer_dhcp_reply :: proc(peer: ^Peer, request: []u8, kind: u8, router: [4]u8) -> []u8 {
	MESSAGE :: 240 + 3 + 6 + 6 + 6 + 6 + 1
	frame := make([]u8, 42 + MESSAGE, context.temp_allocator)
	sync.mutex_lock(&peer.lock)
	hardware := peer.hardware
	sync.mutex_unlock(&peer.lock)
	peer_ipv4(frame, {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF}, 8 + MESSAGE, 17)
	// To the broadcast address: the client holds no address yet.
	ip := frame[14:34]
	copy(ip[16:20], []u8{255, 255, 255, 255})
	put16(ip, 10, 0)
	put16(ip, 10, internet_sum(0, ip))
	put16(frame, 34, DHCP_SERVER_PORT)
	put16(frame, 36, DHCP_CLIENT_PORT)
	put16(frame, 38, 8 + MESSAGE)
	message := frame[42:]
	message[0], message[1], message[2] = 2, 1, 6
	copy(message[4:8], request[4:8]) // The transaction word of the client.
	message[10] = request[10]
	copy(message[16:20], MACHINE_ADDRESS[:])
	copy(message[20:24], PEER_ADDRESS[:])
	copy(message[28:34], hardware[:])
	put32(message, 236, DHCP_MAGIC_COOKIE)
	at := 240
	message[at], message[at + 1], message[at + 2] = 53, 1, kind
	at += 3
	message[at], message[at + 1] = 54, 4
	copy(message[at + 2:], PEER_ADDRESS[:])
	at += 6
	message[at], message[at + 1] = 51, 4
	put32(message, at + 2, DHCP_LEASE_SECONDS)
	at += 6
	message[at], message[at + 1] = 1, 4
	copy(message[at + 2:], []u8{255, 255, 255, 0})
	at += 6
	message[at], message[at + 1] = 3, 4
	router_bytes := router
	copy(message[at + 2:], router_bytes[:])
	at += 6
	message[at] = 255
	broadcast := [4]u8{255, 255, 255, 255}
	value := internet_sum(pseudo_sum(PEER_ADDRESS[:], broadcast[:], 8 + MESSAGE), frame[34:])
	put16(frame, 40, value == 0 ? 0xFFFF : value)
	return frame
}

@(private = "file")
be32_at :: proc(bytes: []u8, offset: int) -> int {
	return be16(bytes, offset) << 16 | be16(bytes, offset + 2)
}

@(private = "file")
put32 :: proc(bytes: []u8, offset: int, value: int) {
	put16(bytes, offset, value >> 16)
	put16(bytes, offset + 2, value & 0xFFFF)
}

@(private = "file")
address_of_bytes :: proc(bytes: []u8) -> (address: [4]u8) {
	copy(address[:], bytes[:4])
	return address
}
