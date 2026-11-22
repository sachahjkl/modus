// Pure freestanding multi-machine protocols: remote role proxy framing,
// content-addressed 2-machine store Merkle diff, signed cross-machine grants,
// and encrypted NAT-traversal relay envelopes (src/md/features/several_machines.md).
package machine_sync

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/enum_word"

HASH_BYTES :: 32
MAX_SYNC_HASHES :: 64
MAX_RELAY_PAYLOAD :: 1200

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

// Merkle-root set diff: computes which object hashes in remote_have are absent
// from local_have so two machines sync a store in one round trip.
store_missing_hashes :: proc "contextless" (
	local_have: [][HASH_BYTES]u8,
	remote_have: [][HASH_BYTES]u8,
	out_missing: [][HASH_BYTES]u8,
) -> int {
	count := 0
	for rh in remote_have {
		found := false
		for lh in local_have {
			if lh == rh {
				found = true
				break
			}
		}
		if !found && count < len(out_missing) {
			out_missing[count] = rh
			count += 1
		}
	}
	return count
}

// Cross-machine signed grant token (principal A on machine X grants capability
// to principal B on machine Y, bounded by expiry_unix_seconds).
Cross_Machine_Grant :: struct {
	issuer_machine: [32]u8,
	target_machine: [32]u8,
	role_word:      u16,
	scope_flags:    u16,
	expiry_seconds: u64,
	grant_nonce:    u64,
	mac:            [32]u8,
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

cross_grant_verify :: proc "contextless" (shared_secret: [32]u8, g: Cross_Machine_Grant, now_seconds: u64) -> bool {
	if g.expiry_seconds == 0 || now_seconds > g.expiry_seconds {
		return false
	}
	exp := cross_grant_mac(shared_secret, g)
	diff := u8(0)
	for i in 0 ..< 32 {
		diff |= exp[i] ~ g.mac[i]
	}
	return diff == 0
}

// NAT-traversal relay packet header (blind forwarding by destination machine ID;
// payload remains end-to-end encrypted by Noise/QUIC between the two machines).
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
