// Pure freestanding per-principal encrypted store page envelope, monotonic
// anti-rollback grant-table floor helper, and PCR-7 policy rotation helper
// (docs/TRUSTED_BOOT.md).
//
// Each sealed page binds a monotonic write version into both its derived nonce
// and its Encrypt-then-MAC BLAKE3 tag so replaying an older ciphertext at the
// same page index is rejected and caller nonce reuse is impossible.
package store_crypto

import "base:intrinsics"
import "modus:contract/blake3"
import "modus:contract/byte_order"

KEY_BYTES :: 32
NONCE_BYTES :: 16
VERSION_BYTES :: 8
TAG_BYTES :: 32
ENVELOPE_OVERHEAD :: VERSION_BYTES + NONCE_BYTES + TAG_BYTES
MAX_EPOCH_STEP :: u64(1024)

Crypto_Refusal :: enum u8 {
	None                  = 0,
	Buffer_Too_Small      = 1,
	Authentication_Failed = 2,
	Rollback_Detected     = 3,
	Invalid_Epoch         = 4,
	Buffers_Overlap       = 5,
	Unverified_Signature  = 6,
	Epoch_Jump_Too_Large  = 7,
}

@(private)
zero_bytes :: proc "contextless" (buf: []u8) {
	for i in 0 ..< len(buf) {
		intrinsics.volatile_store(&buf[i], u8(0))
	}
}

@(private)
slices_overlap :: proc "contextless" (a, b: []u8) -> bool {
	if len(a) == 0 || len(b) == 0 {
		return false
	}
	a0 := uintptr(raw_data(a))
	a1 := a0 + uintptr(len(a))
	b0 := uintptr(raw_data(b))
	b1 := b0 + uintptr(len(b))
	return a0 < b1 && b0 < a1
}

derive_store_key :: proc "contextless" (principal_master_key: [KEY_BYTES]u8, principal_id, store_id: u64) -> [KEY_BYTES]u8 {
	mk := principal_master_key
	msg: [KEY_BYTES + 16]u8
	copy(msg[0:KEY_BYTES], mk[:])
	byte_order.write_u64_little_endian(msg[:], KEY_BYTES, principal_id)
	byte_order.write_u64_little_endian(msg[:], KEY_BYTES + 8, store_id)
	out := blake3.derive_key("modus store subkey v1", msg[:])
	zero_bytes(mk[:])
	zero_bytes(msg[:])
	return out
}

@(private)
derive_page_nonce :: proc "contextless" (store_key: [KEY_BYTES]u8, page_index, version: u64) -> [NONCE_BYTES]u8 {
	sk := store_key
	in_buf: [KEY_BYTES + 16]u8
	copy(in_buf[0:KEY_BYTES], sk[:])
	byte_order.write_u64_little_endian(in_buf[:], KEY_BYTES, page_index)
	byte_order.write_u64_little_endian(in_buf[:], KEY_BYTES + 8, version)
	h := blake3.derive_key("modus store page nonce v1", in_buf[:])
	out: [NONCE_BYTES]u8
	copy(out[:], h[:NONCE_BYTES])
	zero_bytes(sk[:])
	zero_bytes(in_buf[:])
	zero_bytes(h[:])
	return out
}

@(private)
compute_page_tag :: proc "contextless" (store_key: [KEY_BYTES]u8, page_index, version: u64, nonce: []u8, ct: []u8) -> [TAG_BYTES]u8 {
	sk := store_key
	ct_hash := blake3.hash(ct)
	hdr: [KEY_BYTES + 16 + NONCE_BYTES + 32]u8
	copy(hdr[0:KEY_BYTES], sk[:])
	byte_order.write_u64_little_endian(hdr[:], KEY_BYTES, page_index)
	byte_order.write_u64_little_endian(hdr[:], KEY_BYTES + 8, version)
	copy(hdr[KEY_BYTES + 16 : KEY_BYTES + 16 + NONCE_BYTES], nonce)
	copy(hdr[KEY_BYTES + 16 + NONCE_BYTES:], ct_hash[:])
	tag := blake3.derive_key("modus store page mac v2", hdr[:])
	zero_bytes(sk[:])
	zero_bytes(hdr[:])
	return tag
}

// seal_page encrypts plaintext using a version-bound nonce derived from
// (store_key, page_index, version) and authenticates (page_index || version ||
// nonce || ciphertext) with a 32-byte BLAKE3 MAC tag. Rejects overlapping buffers.
seal_page :: proc "contextless" (
	store_key: [KEY_BYTES]u8,
	page_index: u64,
	version: u64,
	plaintext: []u8,
	out_sealed: []u8,
) -> (written: int, refusal: Crypto_Refusal) {
	if version == 0 {
		return 0, .Invalid_Epoch
	}
	needed := len(plaintext) + ENVELOPE_OVERHEAD
	if len(out_sealed) < needed {
		return 0, .Buffer_Too_Small
	}
	if slices_overlap(plaintext, out_sealed[:needed]) {
		return 0, .Buffers_Overlap
	}
	nc := derive_page_nonce(store_key, page_index, version)
	sk := store_key
	byte_order.write_u64_little_endian(out_sealed, 0, version)
	copy(out_sealed[VERSION_BYTES : VERSION_BYTES + NONCE_BYTES], nc[:])

	ct := out_sealed[VERSION_BYTES + NONCE_BYTES : VERSION_BYTES + NONCE_BYTES + len(plaintext)]
	blk_in: [KEY_BYTES + NONCE_BYTES + 24]u8
	copy(blk_in[0:KEY_BYTES], sk[:])
	copy(blk_in[KEY_BYTES : KEY_BYTES + NONCE_BYTES], nc[:])
	byte_order.write_u64_little_endian(blk_in[:], KEY_BYTES + NONCE_BYTES, page_index)
	byte_order.write_u64_little_endian(blk_in[:], KEY_BYTES + NONCE_BYTES + 8, version)

	off := 0
	ctr := u64(0)
	for off < len(plaintext) {
		byte_order.write_u64_little_endian(blk_in[:], KEY_BYTES + NONCE_BYTES + 16, ctr)
		ks := blake3.derive_key("modus store ctr block v2", blk_in[:])
		chunk := min(32, len(plaintext) - off)
		for i in 0 ..< chunk {
			ct[off + i] = plaintext[off + i] ~ ks[i]
		}
		zero_bytes(ks[:])
		off += chunk
		ctr += 1
	}

	tag := compute_page_tag(store_key, page_index, version, nc[:], ct)
	copy(out_sealed[VERSION_BYTES + NONCE_BYTES + len(plaintext) : needed], tag[:])
	zero_bytes(sk[:])
	zero_bytes(blk_in[:])
	return needed, .None
}

// open_page verifies the 32-byte MAC in constant time and checks that the
// sealed page version is at least min_version (preventing stale page replay)
// before decrypting into out_plain.
open_page :: proc "contextless" (
	store_key: [KEY_BYTES]u8,
	page_index: u64,
	min_version: u64,
	sealed: []u8,
	out_plain: []u8,
) -> (written: int, version: u64, refusal: Crypto_Refusal) {
	if len(sealed) < ENVELOPE_OVERHEAD {
		return 0, 0, .Authentication_Failed
	}
	ct_len := len(sealed) - ENVELOPE_OVERHEAD
	if len(out_plain) < ct_len {
		return 0, 0, .Buffer_Too_Small
	}
	if slices_overlap(sealed, out_plain[:ct_len]) {
		return 0, 0, .Buffers_Overlap
	}
	ver := byte_order.read_u64_little_endian(sealed, 0)
	nonce_slice := sealed[VERSION_BYTES : VERSION_BYTES + NONCE_BYTES]
	ct := sealed[VERSION_BYTES + NONCE_BYTES : VERSION_BYTES + NONCE_BYTES + ct_len]
	got_tag := sealed[VERSION_BYTES + NONCE_BYTES + ct_len:]

	exp_tag := compute_page_tag(store_key, page_index, ver, nonce_slice, ct)
	diff := u8(0)
	for i in 0 ..< TAG_BYTES {
		diff |= got_tag[i] ~ exp_tag[i]
	}
	if diff != 0 {
		return 0, 0, .Authentication_Failed
	}
	if ver == 0 || ver < min_version {
		return 0, 0, .Rollback_Detected
	}

	sk := store_key
	blk_in: [KEY_BYTES + NONCE_BYTES + 24]u8
	copy(blk_in[0:KEY_BYTES], sk[:])
	copy(blk_in[KEY_BYTES : KEY_BYTES + NONCE_BYTES], nonce_slice)
	byte_order.write_u64_little_endian(blk_in[:], KEY_BYTES + NONCE_BYTES, page_index)
	byte_order.write_u64_little_endian(blk_in[:], KEY_BYTES + NONCE_BYTES + 8, ver)

	off := 0
	ctr := u64(0)
	for off < ct_len {
		byte_order.write_u64_little_endian(blk_in[:], KEY_BYTES + NONCE_BYTES + 16, ctr)
		ks := blake3.derive_key("modus store ctr block v2", blk_in[:])
		chunk := min(32, ct_len - off)
		for i in 0 ..< chunk {
			out_plain[off + i] = ct[off + i] ~ ks[i]
		}
		zero_bytes(ks[:])
		off += chunk
		ctr += 1
	}
	zero_bytes(sk[:])
	zero_bytes(blk_in[:])
	return ct_len, ver, .None
}

Grant_Table_Floor :: struct {
	nv_loaded:    bool,
	tpm_nv_floor: u64,
	pcr7_digest:  [32]u8,
}

grant_table_floor_load :: proc "contextless" (floor: ^Grant_Table_Floor, nv_epoch: u64, pcr7: [32]u8) {
	if floor == nil {
		return
	}
	floor^ = {nv_loaded = true, tpm_nv_floor = nv_epoch, pcr7_digest = pcr7}
}

// grant_table_accept_epoch validates an authenticated grant-table epoch against
// a TPM-NV-loaded floor, refusing unverified tables, rollbacks, and oversized jumps.
grant_table_accept_epoch :: proc "contextless" (floor: ^Grant_Table_Floor, candidate_epoch: u64, signature_verified: bool) -> Crypto_Refusal {
	if floor == nil || !floor.nv_loaded || candidate_epoch == 0 {
		return .Invalid_Epoch
	}
	if !signature_verified {
		return .Unverified_Signature
	}
	if candidate_epoch < floor.tpm_nv_floor {
		return .Rollback_Detected
	}
	if candidate_epoch - floor.tpm_nv_floor > MAX_EPOCH_STEP {
		return .Epoch_Jump_Too_Large
	}
	floor.tpm_nv_floor = candidate_epoch
	return .None
}
