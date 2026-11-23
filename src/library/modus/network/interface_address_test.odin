#+build !freestanding
package network

import "core:testing"

// The mask of each prefix length: 0, 1, 8, 16, 24, 31, 32 bits, and each
// length past 32 refused.
@(test)
prefix_mask_of_each_length_and_refusal_past_32 :: proc(t: ^testing.T) {
	for length in ([?]u8{33, 64, 255}) {
		_, ok := prefix_mask(length)
		testing.expectf(t, !ok, "the prefix length %d gave a mask", length)
	}
	masks := [?]struct {
		length: u8,
		mask:   u32,
	}{{0, 0}, {1, 0x8000_0000}, {8, 0xFF00_0000}, {16, 0xFFFF_0000}, {22, 0xFFFF_FC00}, {24, 0xFFFF_FF00}, {31, 0xFFFF_FFFE}, {32, 0xFFFF_FFFF}}
	for item in masks {
		mask, ok := prefix_mask(item.length)
		testing.expectf(t, ok && mask == item.mask, "the prefix length %d gave %x", item.length, mask)
	}
}

// Each address of an interface that cannot work is refused: a prefix of 0
// or past 32, a local address of 0, all ones, multicast, or the network or
// broadcast address of its prefix, a gateway off the link, of 0, or the
// local address. Then the networks of real use pass: /8, /16, /22, /24,
// /30, /31.
@(test)
interface_address_refuses_each_edge_and_takes_real_networks :: proc(t: ^testing.T) {
	refused := [?]struct {
		address: Interface_Address,
		problem: Interface_Problem,
	} {
		{{0x0A00020F, 0x0A000202, 0}, .Prefix_Length},
		{{0x0A00020F, 0x0A000202, 33}, .Prefix_Length},
		{{0x0A00020F, 0x0A000202, 255}, .Prefix_Length},
		{{0, 0x0A000202, 24}, .Local_Address},
		{{0xFFFF_FFFF, 0x0A000202, 24}, .Local_Address},
		{{0xE000_0001, 0xE000_0002, 24}, .Local_Address},
		{{0x0A000200, 0x0A000202, 24}, .Local_Address}, // The network address.
		{{0x0A0002FF, 0x0A000202, 24}, .Local_Address}, // The broadcast address.
		{{0x0A00FFFF, 0x0A000202, 16}, .Local_Address}, // The broadcast of a /16.
		{{0x0A00020F, 0x0A000302, 24}, .Gateway}, // Off the link of a /24.
		{{0x0A00020F, 0x0A010002, 16}, .Gateway}, // Off the link of a /16.
		{{0x0A00020F, 0, 24}, .Gateway},
		{{0x0A00020F, 0x0A00020F, 24}, .Gateway},
		{{0x0A00020F, 0x0A0002FF, 24}, .Gateway}, // The broadcast address.
		{{0x0A00020F, 0x0A00020E, 32}, .Gateway}, // No gateway is on the link of a /32.
	}
	for item in refused {
		mask, problem := interface_address_check(item.address)
		testing.expectf(t, problem == item.problem && mask == 0, "%v gave %v, not %v", item.address, problem, item.problem)
	}
	taken := [?]struct {
		address: Interface_Address,
		mask:    u32,
	} {
		{{0x0A00020F, 0x0A000202, 24}, 0xFFFF_FF00}, // The network of QEMU.
		{{0xAC10_0A05, 0xAC10_0001, 16}, 0xFFFF_0000}, // 172.16.10.5/16 through 172.16.0.1.
		{{0xC0A8_0305, 0xC0A8_0001, 22}, 0xFFFF_FC00}, // 192.168.3.5/22 through 192.168.0.1.
		{{0x0A0B_0C0D, 0x0A00_0001, 8}, 0xFF00_0000},
		{{0xC0A8_0001, 0xC0A8_0002, 30}, 0xFFFF_FFFC},
		{{0xC0A8_0000, 0xC0A8_0001, 31}, 0xFFFF_FFFE}, // RFC 3021: both addresses of a /31 are hosts.
	}
	for item in taken {
		mask, problem := interface_address_check(item.address)
		testing.expectf(t, problem == .None && mask == item.mask, "%v gave %v and %x", item.address, problem, mask)
	}
}

// The next hop follows the prefix: on a /16 an address of another /24 of
// the same /16 is on the link, and an address out of the /16 goes to the
// gateway; on a /24 that same address goes to the gateway.
@(test)
next_hop_follows_the_prefix_length :: proc(t: ^testing.T) {
	wide := Interface_Address{0xAC10_0A05, 0xAC10_0001, 16}
	wide_mask, wide_problem := interface_address_check(wide)
	testing.expect_value(t, wide_problem, Interface_Problem.None)
	testing.expect_value(t, next_hop(wide, wide_mask, 0xAC10_C801), u32(0xAC10_C801)) // 172.16.200.1: same /16.
	testing.expect_value(t, next_hop(wide, wide_mask, 0xAC11_0001), wide.gateway) // 172.17.0.1: out of it.
	narrow := Interface_Address{0xAC10_0A05, 0xAC10_0A01, 24}
	narrow_mask, narrow_problem := interface_address_check(narrow)
	testing.expect_value(t, narrow_problem, Interface_Problem.None)
	testing.expect_value(t, next_hop(narrow, narrow_mask, 0xAC10_C801), narrow.gateway)
	testing.expect_value(t, next_hop(narrow, narrow_mask, 0xAC10_0A63), u32(0xAC10_0A63))
	// The subnet broadcast of a /16 is not a valid source; one under it is.
	testing.expect(t, !source_valid(0xAC10_FFFF, wide.local, wide_mask))
	testing.expect(t, source_valid(0xAC10_FFFE, wide.local, wide_mask))
	testing.expect(t, source_valid(0xAC10_0AFF, wide.local, wide_mask), "a /24 broadcast inside a /16 is a host")
}
