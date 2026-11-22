#+build !freestanding
package store_crypto

import "core:testing"

@(test)
encrypted_store_page_aead_and_tpm_anti_rollback :: proc(t: ^testing.T) {
	master: [KEY_BYTES]u8
	for i in 0 ..< KEY_BYTES {
		master[i] = u8(i + 1)
	}
	k1 := derive_store_key(master, 1, 100)
	k2 := derive_store_key(master, 2, 100)
	testing.expect(t, k1 != k2)

	nonce: [NONCE_BYTES]u8 = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}
	plain := transmute([]u8)string("secret principal store record payload 1234567890")
	sealed: [128]u8
	wn, r1 := seal_page(k1, 42, nonce, plain, sealed[:])
	testing.expect_value(t, r1, Crypto_Refusal.None)
	testing.expect_value(t, wn, len(plain) + ENVELOPE_OVERHEAD)

	out: [128]u8
	rn, r2 := open_page(k1, 42, sealed[:wn], out[:])
	testing.expect_value(t, r2, Crypto_Refusal.None)
	testing.expect_value(t, string(out[:rn]), string(plain))

	// Wrong page_index, wrong key, or flipped ciphertext bit all fail authentication.
	_, rw_idx := open_page(k1, 43, sealed[:wn], out[:])
	testing.expect_value(t, rw_idx, Crypto_Refusal.Authentication_Failed)
	_, rw_key := open_page(k2, 42, sealed[:wn], out[:])
	testing.expect_value(t, rw_key, Crypto_Refusal.Authentication_Failed)
	sealed[NONCE_BYTES] ~= 0x01
	_, rw_bit := open_page(k1, 42, sealed[:wn], out[:])
	testing.expect_value(t, rw_bit, Crypto_Refusal.Authentication_Failed)

	// TPM NV monotonic floor refuses disk restore rollback.
	floor := Grant_Table_Floor{tpm_nv_floor = 10}
	testing.expect_value(t, grant_table_accept_epoch(&floor, 11), Crypto_Refusal.None)
	testing.expect_value(t, grant_table_accept_epoch(&floor, 10), Crypto_Refusal.Rollback_Detected)
}
