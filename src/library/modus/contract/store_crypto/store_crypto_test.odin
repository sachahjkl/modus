#+build !freestanding
package store_crypto

import "core:testing"

@(test)
encrypted_store_page_aead_anti_replay_and_bounded_tpm_floor :: proc(t: ^testing.T) {
	master: [KEY_BYTES]u8
	for i in 0 ..< KEY_BYTES {
		master[i] = u8(i + 1)
	}
	k1 := derive_store_key(master, 1, 100)
	k2 := derive_store_key(master, 2, 100)
	testing.expect(t, k1 != k2)

	plain := transmute([]u8)string("secret principal store record payload 1234567890")
	sealed_v1: [160]u8
	wn1, r1 := seal_page(k1, 42, 1, plain, sealed_v1[:])
	testing.expect_value(t, r1, Crypto_Refusal.None)
	testing.expect_value(t, wn1, len(plain) + ENVELOPE_OVERHEAD)

	// Overlapping buffers refused.
	_, r_ov := seal_page(k1, 42, 1, sealed_v1[:len(plain)], sealed_v1[:])
	testing.expect_value(t, r_ov, Crypto_Refusal.Buffers_Overlap)

	out: [160]u8
	rn, ver, r2 := open_page(k1, 42, 1, sealed_v1[:wn1], out[:])
	testing.expect_value(t, r2, Crypto_Refusal.None)
	testing.expect_value(t, ver, u64(1))
	testing.expect_value(t, string(out[:rn]), string(plain))

	// Replay of version 1 when store expects min_version 2 is refused!
	_, _, r_rep := open_page(k1, 42, 2, sealed_v1[:wn1], out[:])
	testing.expect_value(t, r_rep, Crypto_Refusal.Rollback_Detected)

	// Wrong page_index, wrong key, or flipped ciphertext bit all fail authentication.
	_, _, rw_idx := open_page(k1, 43, 1, sealed_v1[:wn1], out[:])
	testing.expect_value(t, rw_idx, Crypto_Refusal.Authentication_Failed)
	_, _, rw_key := open_page(k2, 42, 1, sealed_v1[:wn1], out[:])
	testing.expect_value(t, rw_key, Crypto_Refusal.Authentication_Failed)
	sealed_v1[VERSION_BYTES + NONCE_BYTES] ~= 0x01
	_, _, rw_bit := open_page(k1, 42, 1, sealed_v1[:wn1], out[:])
	testing.expect_value(t, rw_bit, Crypto_Refusal.Authentication_Failed)

	// TPM NV floor requires nv_loaded, verified signature, and bounded step (prevents max(u64) DoS).
	floor: Grant_Table_Floor
	testing.expect_value(t, grant_table_accept_epoch(&floor, 10, true), Crypto_Refusal.Invalid_Epoch)
	grant_table_floor_load(&floor, 10, {})
	testing.expect_value(t, grant_table_accept_epoch(&floor, 11, false), Crypto_Refusal.Unverified_Signature)
	testing.expect_value(t, grant_table_accept_epoch(&floor, max(u64), true), Crypto_Refusal.Epoch_Jump_Too_Large)
	testing.expect_value(t, grant_table_accept_epoch(&floor, 11, true), Crypto_Refusal.None)
	testing.expect_value(t, grant_table_accept_epoch(&floor, 10, true), Crypto_Refusal.Rollback_Detected)
}
