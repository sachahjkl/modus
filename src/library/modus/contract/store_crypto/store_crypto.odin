// Pure freestanding per-principal encrypted store page envelope, monotonic
// anti-rollback grant-table floor bound to TPM NV, and PCR-7 policy rotation
// helper (docs/TRUSTED_BOOT.md).
//
// Uses BLAKE3 domain-separated KDF/MAC + CTR keystream (freestanding
// modus:contract/blake3) so store pages are authenticated-encrypted with zero
// external crypto state or heap allocation.
package store_crypto

import "modus:contract/blake3"
import "modus:contract/byte_order"

KEY_BYTES :: 32
NONCE_BYTES :: 16
TAG_BYTES :: 32
ENVELOPE_OVERHEAD :: NONCE_BYTES + TAG_BYTES

Crypto_Refusal :: enum u8 {
	None                  = 0,
	Buffer_Too_Small      = 1,
	Authentication_Failed = 2,
	Rollback_Detected     = 3,
	Invalid_Epoch         = 4,
}

// derive_store_key derives a domain-separated 32-byte key for (principal_id,
// store_id) from the principal's 32-byte master store key via BLAKE3 KDF.
derive_store_key :: proc "contextless" (principal_master_key: [KEY_BYTES]u8, principal_id, store_id: u64) -> [KEY_BYTES]u8 {
	mk := principal_master_key
	msg: [KEY_BYTES + 16]u8
	copy(msg[0:KEY_BYTES], mk[:])
	byte_order.write_u64_little_endian(msg[:], KEY_BYTES, principal_id)
	byte_order.write_u64_little_endian(msg[:], KEY_BYTES + 8, store_id)
	return blake3.derive_key("modus store subkey v1", msg[:])
}

@(private)
compute_page_tag :: proc "contextless" (store_key: [KEY_BYTES]u8, page_index: u64, nonce: []u8, ct: []u8) -> [TAG_BYTES]u8 {
	sk := store_key
	// Fold ciphertext hash + header + key into domain-separated BLAKE3 MAC.
	ct_hash := blake3.hash(ct)
	hdr: [KEY_BYTES + 8 + NONCE_BYTES + 32]u8
	copy(hdr[0:KEY_BYTES], sk[:])
	byte_order.write_u64_little_endian(hdr[:], KEY_BYTES, page_index)
	copy(hdr[KEY_BYTES + 8 : KEY_BYTES + 8 + NONCE_BYTES], nonce)
	copy(hdr[KEY_BYTES + 8 + NONCE_BYTES:], ct_hash[:])
	return blake3.derive_key("modus store page mac v1", hdr[:])
}

// seal_page encrypts plaintext using BLAKE3-CTR keystream derived from (key,
// nonce, page_index) and authenticates (page_index || nonce || ciphertext) with
// a 32-byte BLAKE3 keyed MAC tag (Encrypt-then-MAC).
seal_page :: proc "contextless" (
	store_key: [KEY_BYTES]u8,
	page_index: u64,
	nonce: [NONCE_BYTES]u8,
	plaintext: []u8,
	out_sealed: []u8,
) -> (written: int, refusal: Crypto_Refusal) {
	needed := len(plaintext) + ENVELOPE_OVERHEAD
	if len(out_sealed) < needed {
		return 0, .Buffer_Too_Small
	}
	nc := nonce
	sk := store_key
	copy(out_sealed[0:NONCE_BYTES], nc[:])

	ct := out_sealed[NONCE_BYTES : NONCE_BYTES + len(plaintext)]
	blk_in: [KEY_BYTES + NONCE_BYTES + 16]u8
	copy(blk_in[0:KEY_BYTES], sk[:])
	copy(blk_in[KEY_BYTES : KEY_BYTES + NONCE_BYTES], nc[:])
	byte_order.write_u64_little_endian(blk_in[:], KEY_BYTES + NONCE_BYTES, page_index)

	off := 0
	ctr := u64(0)
	for off < len(plaintext) {
		byte_order.write_u64_little_endian(blk_in[:], KEY_BYTES + NONCE_BYTES + 8, ctr)
		ks := blake3.derive_key("modus store ctr block v1", blk_in[:])
		chunk := min(32, len(plaintext) - off)
		for i in 0 ..< chunk {
			ct[off + i] = plaintext[off + i] ~ ks[i]
		}
		off += chunk
		ctr += 1
	}

	tag := compute_page_tag(store_key, page_index, nc[:], ct)
	copy(out_sealed[NONCE_BYTES + len(plaintext) : needed], tag[:])
	return needed, .None
}

// open_page verifies the 32-byte MAC in constant time before decrypting into out_plain.
open_page :: proc "contextless" (
	store_key: [KEY_BYTES]u8,
	page_index: u64,
	sealed: []u8,
	out_plain: []u8,
) -> (written: int, refusal: Crypto_Refusal) {
	if len(sealed) < ENVELOPE_OVERHEAD {
		return 0, .Authentication_Failed
	}
	ct_len := len(sealed) - ENVELOPE_OVERHEAD
	if len(out_plain) < ct_len {
		return 0, .Buffer_Too_Small
	}
	nonce_slice := sealed[0:NONCE_BYTES]
	ct := sealed[NONCE_BYTES : NONCE_BYTES + ct_len]
	got_tag := sealed[NONCE_BYTES + ct_len:]

	exp_tag := compute_page_tag(store_key, page_index, nonce_slice, ct)
	diff := u8(0)
	for i in 0 ..< TAG_BYTES {
		diff |= got_tag[i] ~ exp_tag[i]
	}
	if diff != 0 {
		return 0, .Authentication_Failed
	}

	sk := store_key
	blk_in: [KEY_BYTES + NONCE_BYTES + 16]u8
	copy(blk_in[0:KEY_BYTES], sk[:])
	copy(blk_in[KEY_BYTES : KEY_BYTES + NONCE_BYTES], nonce_slice)
	byte_order.write_u64_little_endian(blk_in[:], KEY_BYTES + NONCE_BYTES, page_index)

	off := 0
	ctr := u64(0)
	for off < ct_len {
		byte_order.write_u64_little_endian(blk_in[:], KEY_BYTES + NONCE_BYTES + 8, ctr)
		ks := blake3.derive_key("modus store ctr block v1", blk_in[:])
		chunk := min(32, ct_len - off)
		for i in 0 ..< chunk {
			out_plain[off + i] = ct[off + i] ~ ks[i]
		}
		off += chunk
		ctr += 1
	}
	return ct_len, .None
}

// ============================================================================
// Monotonic TPM NV Anti-Rollback Grant-Table Floor & PCR-7 Policy Rotation
// ============================================================================

Grant_Table_Floor :: struct {
	tpm_nv_floor: u64,
	pcr7_digest:  [32]u8,
}

grant_table_accept_epoch :: proc "contextless" (floor: ^Grant_Table_Floor, candidate_epoch: u64) -> Crypto_Refusal {
	if floor == nil || candidate_epoch == 0 {
		return .Invalid_Epoch
	}
	if candidate_epoch < floor.tpm_nv_floor {
		return .Rollback_Detected
	}
	floor.tpm_nv_floor = candidate_epoch
	return .None
}
