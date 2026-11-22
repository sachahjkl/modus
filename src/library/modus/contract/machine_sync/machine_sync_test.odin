#+build !freestanding
package machine_sync

import "core:testing"
import "modus:contract/role_contract"

@(test)
merkle_sync_peer_authenticated_grant_replay_defense :: proc(t: ^testing.T) {
	h1: [HASH_BYTES]u8; h1[0] = 1
	h2: [HASH_BYTES]u8; h2[0] = 2
	h3: [HASH_BYTES]u8; h3[0] = 3
	local := [2][HASH_BYTES]u8{h1, h2}
	remote := [3][HASH_BYTES]u8{h2, h3, h3} // Duplicate h3 deduplicated!
	missing: [4][HASH_BYTES]u8
	mn, trunc := store_missing_hashes(local[:], remote[:], missing[:])
	testing.expect(t, !trunc && mn == 1 && missing[0] == h3)

	secret: [32]u8; secret[0] = 0xAA
	m_local: [32]u8; m_local[0] = 0x11
	m_peer: [32]u8; m_peer[0] = 0x22
	seen: Nonce_Replay_Set
	g := Cross_Machine_Grant{
		issuer_machine = m_peer,
		target_machine = m_local,
		role_word      = u16(role_contract.Role.Storage),
		scope_flags    = 1,
		expiry_seconds = 10_000,
		grant_nonce    = 7,
	}
	g.mac = cross_grant_mac(secret, g)
	// Reflection back to peer refused!
	testing.expect(t, !cross_grant_verify(secret, m_peer, m_local, g, 9_500, &seen))
	// Valid first verification succeeds, replay of same nonce refused!
	testing.expect(t, cross_grant_verify(secret, m_local, m_peer, g, 9_500, &seen))
	testing.expect(t, !cross_grant_verify(secret, m_local, m_peer, g, 9_501, &seen))
}
