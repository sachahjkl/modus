package network

// The address of the interface of the network service: its own address,
// its gateway and the length of the prefix of its network. The prefix
// decides which address is on the link (ARP for it) and which goes to the
// gateway; it is a field, not a mask that the code assumes, so a network of
// /16 or /22 works as a network of /24 does. The functions have no input
// or output, so the host runs their tests (interface_address_test.odin).

// The longest prefix of IPv4.
PREFIX_LENGTH_LIMIT :: 32

// The address of one interface.
Interface_Address :: struct {
	local:         u32, // The address of the machine.
	gateway:       u32, // The router of each address that is not on the link.
	prefix_length: u8, // The bits of the network part of local: 1 to PREFIX_LENGTH_LIMIT.
}

// Why interface_address_check refused an address of an interface.
Interface_Problem :: enum u8 {
	None,
	Prefix_Length, // A prefix of 0 bits, or past PREFIX_LENGTH_LIMIT.
	Local_Address, // The local address is 0, all ones, multicast, or the network or the broadcast address of its prefix.
	Gateway, // The gateway is 0, the local address, or not on the link of the prefix.
}

// prefix_mask gives the mask of a prefix length: its first bits set. ok is
// false past PREFIX_LENGTH_LIMIT.
prefix_mask :: proc "contextless" (prefix_length: u8) -> (mask: u32, ok: bool) {
	if prefix_length > PREFIX_LENGTH_LIMIT {
		return 0, false
	}
	if prefix_length == 0 {
		return 0, true
	}
	return ~u32(0) << (PREFIX_LENGTH_LIMIT - u32(prefix_length)), true
}

// interface_address_check is the border of an address of an interface: it
// gives the mask of its prefix, or the problem. A prefix of 31 or 32 bits
// has no network and no broadcast address (RFC 3021), so its local address
// is only refused when it is 0, all ones or multicast; its gateway must
// still be on the link, which a prefix of 32 bits never holds.
interface_address_check :: proc "contextless" (address: Interface_Address) -> (mask: u32, problem: Interface_Problem) {
	if address.prefix_length == 0 || address.prefix_length > PREFIX_LENGTH_LIMIT {
		return 0, .Prefix_Length
	}
	mask, _ = prefix_mask(address.prefix_length)
	local := address.local
	switch {
	case local == 0, local == 0xFFFF_FFFF, local >> 28 == 0xE:
		return 0, .Local_Address
	case address.prefix_length <= 30 && (local & ~mask == 0 || local | mask == 0xFFFF_FFFF):
		return 0, .Local_Address
	}
	gateway := address.gateway
	if gateway == 0 || gateway == local || gateway & mask != local & mask {
		return 0, .Gateway
	}
	if address.prefix_length <= 30 && (gateway & ~mask == 0 || gateway | mask == 0xFFFF_FFFF) {
		return 0, .Gateway
	}
	return mask, .None
}

// on_link says if an address is on the link of an interface whose mask
// interface_address_check gave.
on_link :: proc "contextless" (address: Interface_Address, mask: u32, other: u32) -> bool {
	return other & mask == address.local & mask
}

// next_hop gives the address whose hardware address a frame to other needs:
// other itself on the link, else the gateway.
next_hop :: proc "contextless" (address: Interface_Address, mask: u32, other: u32) -> u32 {
	return on_link(address, mask, other) ? other : address.gateway
}
