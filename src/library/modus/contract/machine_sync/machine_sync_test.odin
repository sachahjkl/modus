#+build !freestanding
package machine_sync

import "core:testing"

@(test)
merkle_sync_cross_machine_grant_and_nat_relay :: proc(t: ^testing.T) {
	_, bad := sync_kind_of_word(99)
	testing.expect(t, !bad)

	h1: [HASH_BYTES]u8; h1[0] = 1
	h2: [HASH_BYTES]u8; h2[0] = 2
	h3: [HASH_BYTES]u8; h3[0] = 3
	local := [2][HASH_BYTES]u8{h1, h2}
	remote := [2][HASH_BYTES]u8{h2, h3}
	missing: [4][HASH_BYTES]u8
	mn := store_missing_hashes(local[:], remote[:], missing[:])
	testing.expect_value(t, mn, 1)
	testing.expect(t, missing[0] == h3)

	secret: [32]u8; secret[0] = 0xAA
	g := Cross_Machine_Grant{role_word = 5, scope_flags = 1, expiry_seconds = 10_000, grant_nonce = 7}
	g.mac = cross_grant_mac(secret, g)
	testing.expect(t, cross_grant_verify(secret, g, 9_999))
	testing.expect(t, !cross_grant_verify(secret, g, 10_001)) // Expired refused.

	dest: [32]u8; dest[0] = 0x55
	wire: [256]u8
	rn, rok := relay_encode(dest, transmute([]u8)string("encrypted-quic-frame"), wire[:])
	testing.expect(t, rok)
	hdr, payload, dok := relay_decode(wire[:rn])
	testing.expect(t, dok)
	testing.expect(t, hdr.dest_machine == dest)
	testing.expect_value(t, string(payload), "encrypted-quic-frame")
}
