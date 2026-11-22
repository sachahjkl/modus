// Pure freestanding multi-machine protocols: remote role proxy framing,
// content-addressed 2-machine store Merkle diff, peer-authenticated bounded
// cross-machine grants with nonce replay set, and NAT-traversal relay framing
// (src/md/features/several_machines.md).
package machine_sync

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/enum_word"
import "modus:contract/role_contract"

HASH_BYTES :: 32
MAX_SYNC_HASHES :: 64
MAX_RELAY_PAYLOAD :: 1200
MAX_GRANT_TTL_SECONDS :: u64(86_400) // 24 hours max TTL
MAX_SEEN_NONCES :: 64

Sync_Kind :: enum u8 {
	Role_Proxy_Call   = 1,
	Role_Proxy_Reply  = 2,
	Store_Have_Roots  = 3,
	Store_Pull_Object = 4,
	Cross_Grant_Offer = 5,
	Relay_Forward     = 6,
}

sync_kind_of_word :: proc "contextless" (word: u64) -> (k: Sync_Kind, ok: bool) {
	return enum_word.member_of_word(Sync_Kind, word)
}

// store_missing_hashes computes deduplicated object hashes in remote_have that
// are absent from local_have, enforcing MAX_SYNC_HASHES and reporting truncation.
store_missing_hashes :: proc "contextless" (
	local_have: [][HASH_BYTES]u8,
	remote_have: [][HASH_BYTES]u8,
	out_missing: [][HASH_BYTES]u8,
) -> (count: int, truncated: bool) {
	if len(local_have) > MAX_SYNC_HASHES || len(remote_have) > MAX_SYNC_HASHES {
		return 0, true
	}
	for rh in remote_have {
		found := false
		for lh in local_have {
			if lh == rh {
				found = true
				break
			}
		}
		if found {
			continue
		}
		// Deduplicate repeated remote hashes.
		dup := false
		for i in 0 ..< count {
			if out_missing[i] == rh {
				dup = true
				break
			}
		}
		if dup {
			continue
		}
		if count >= len(out_missing) {
			return count, true
		}
		out_missing[count] = rh
		count += 1
	}
	return count, false
}

Cross_Machine_Grant :: struct {
	issuer_machine: [32]u8,
	target_machine: [32]u8,
	role_word:      u16,
	scope_flags:    u16,
	expiry_seconds: u64,
	grant_nonce:    u64,
	mac:            [32]u8,
}

Nonce_Replay_Set :: struct {
	nonces: [MAX_SEEN_NONCES]u64,
	count:  int,
}

cross_grant_mac :: proc "contextless" (shared_secret: [32]u8, g: Cross_Machine_Grant) -> [32]u8 {
	sec := shared_secret
	gc := g
	buf: [32 + 32 + 32 + 20]u8
	copy(buf[0:32], sec[:])
	copy(buf[32:64], gc.issuer_machine[:])
	copy(buf[64:96], gc.target_machine[:])
	byte_order.write_u16_little_endian(buf[:], 96, gc.role_word)
	byte_order.write_u16_little_endian(buf[:], 98, gc.scope_flags)
	byte_order.write_u64_little_endian(buf[:], 100, gc.expiry_seconds)
	byte_order.write_u64_little_endian(buf[:], 108, gc.grant_nonce)
	return blake3.derive_key("modus cross machine grant v1", buf[:])
}

// cross_grant_verify verifies peer/local machine identity, role enum border,
// bounded expiry TTL, nonce replay exclusion, and constant-time MAC equality.
cross_grant_verify :: proc "contextless" (
	shared_secret: [32]u8,
	local_machine: [32]u8,
	peer_machine: [32]u8,
	g: Cross_Machine_Grant,
	now_seconds: u64,
	seen: ^Nonce_Replay_Set,
) -> bool {
	if g.target_machine != local_machine || g.issuer_machine != peer_machine || local_machine == peer_machine {
		return false
	}
	role, role_ok := enum_word.member_of_word(role_contract.Role, u64(g.role_word))
	if !role_ok || role == .None {
		return false
	}
	if g.grant_nonce == 0 || g.expiry_seconds == 0 || now_seconds > g.expiry_seconds {
		return false
	}
	if g.expiry_seconds - now_seconds > MAX_GRANT_TTL_SECONDS {
		return false
	}
	if seen != nil {
		for i in 0 ..< seen.count {
			if seen.nonces[i] == g.grant_nonce {
				return false // Replayed nonce refused.
			}
		}
	}
	exp := cross_grant_mac(shared_secret, g)
	diff := u8(0)
	for i in 0 ..< 32 {
		diff |= exp[i] ~ g.mac[i]
	}
	if diff != 0 {
		return false
	}
	if seen != nil && seen.count < MAX_SEEN_NONCES {
		seen.nonces[seen.count] = g.grant_nonce
		seen.count += 1
	}
	return true
}

RELAY_HEADER_BYTES :: 36

Relay_Packet :: struct {
	dest_machine: [32]u8,
	payload_len:  u16,
	flags:        u16,
}

relay_encode :: proc "contextless" (dest_machine: [32]u8, encrypted_payload: []u8, out: []u8) -> (n: int, ok: bool) {
	if len(encrypted_payload) == 0 || len(encrypted_payload) > MAX_RELAY_PAYLOAD || len(out) < RELAY_HEADER_BYTES + len(encrypted_payload) {
		return 0, false
	}
	dm := dest_machine
	copy(out[0:32], dm[:])
	byte_order.write_u16_little_endian(out, 32, u16(len(encrypted_payload)))
	byte_order.write_u16_little_endian(out, 34, 0)
	copy(out[RELAY_HEADER_BYTES:], encrypted_payload)
	return RELAY_HEADER_BYTES + len(encrypted_payload), true
}

relay_decode :: proc "contextless" (wire: []u8) -> (hdr: Relay_Packet, payload: []u8, ok: bool) {
	if len(wire) < RELAY_HEADER_BYTES {
		return {}, nil, false
	}
	copy(hdr.dest_machine[:], wire[0:32])
	hdr.payload_len = byte_order.read_u16_little_endian(wire, 32)
	hdr.flags = byte_order.read_u16_little_endian(wire, 34)
	if hdr.flags != 0 || hdr.payload_len == 0 || int(hdr.payload_len) > MAX_RELAY_PAYLOAD || len(wire) != RELAY_HEADER_BYTES + int(hdr.payload_len) {
		return {}, nil, false
	}
	return hdr, wire[RELAY_HEADER_BYTES:], true
}
