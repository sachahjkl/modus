#+build !freestanding
package tpm_policy

import "base:runtime"
import "core:testing"
import "modus:contract/blake3"
import "modus:contract/byte_order"
import ed25519 "core:crypto/ed25519"

@(private = "file")
test_digest :: proc(seed: u8) -> blake3.Hash {
	input := [4]u8{seed, seed ~ 0xA5, seed + 23, 0x3C}
	return blake3.hash(input[:])
}

@(private = "file")
test_keypair :: proc(seed_byte: u8) -> (priv: ed25519.Private_Key, pub: [PUBLISHER_KEY_TAG_SIZE]u8) {
	seed: [ed25519.PRIVATE_KEY_SIZE]u8
	for index in 0 ..< len(seed) {
		seed[index] = seed_byte + u8(index * 17 + 5)
	}
	ok := ed25519.private_key_set_bytes(&priv, seed[:])
	assert(ok)
	ed25519.private_key_public_bytes(&priv, pub[:])
	return priv, pub
}

@(private = "file")
ed25519_verify_callback :: proc "contextless" (
	pub_key: [PUBLISHER_KEY_TAG_SIZE]u8,
	message: []u8,
	signature: [TPM_POLICY_SIGNATURE_SIZE]u8,
	_: rawptr,
) -> bool {
	context = runtime.default_context()
	pub_copy := pub_key
	sig_copy := signature
	parsed: ed25519.Public_Key
	if !ed25519.public_key_set_bytes(&parsed, pub_copy[:]) {
		return false
	}
	return ed25519.verify(&parsed, message, sig_copy[:])
}

@(private = "file")
make_signed_policy :: proc(
	priv: ^ed25519.Private_Key,
	pub: [PUBLISHER_KEY_TAG_SIZE]u8,
	kind: Tpm_Policy_Kind,
	key_number: u32,
	version_floor: u32,
	policy_digest: [TPM_POLICY_DIGEST_SIZE]u8,
	pcr7_digest: [TPM_POLICY_DIGEST_SIZE]u8,
) -> Authorized_Policy_Envelope {
	env := Authorized_Policy_Envelope {
		version                = TPM_POLICY_FORMAT_VERSION,
		kind                   = kind,
		key_number             = key_number,
		version_floor          = version_floor,
		publisher_key_tag      = pub,
		approved_policy_digest = policy_digest,
		pcr7_digest            = pcr7_digest,
	}
	signing_buf: [AUTHORIZED_POLICY_SIGNING_SIZE]u8
	written, ref := authorized_policy_signing_bytes(&env, &signing_buf)
	assert(ref == .None && written == AUTHORIZED_POLICY_SIGNING_SIZE)
	ed25519.sign(priv, signing_buf[:written], env.signature[:])
	return env
}

@(test)
storage_hierarchy_auth_seal_refusals_and_round_trip :: proc(t: ^testing.T) {
	seal := Storage_Hierarchy_Auth_Seal {
		version                   = TPM_POLICY_FORMAT_VERSION,
		persistent_storage_handle = 0x8100_0001,
		policy_digest             = test_digest(1),
		auth_value                = test_digest(2),
	}
	tag, tag_ref := storage_auth_seal_compute_tag(&seal)
	testing.expect_value(t, tag_ref, Tpm_Policy_Refusal.None)
	seal.integrity_tag = tag

	// Zero auth value is refused.
	zero_auth := seal
	zero_auth.auth_value = {}
	testing.expect_value(t, storage_auth_seal_verify(&zero_auth), Tpm_Policy_Refusal.Zero_Auth_Value)

	// Zero persistent handle and zero policy digest are refused.
	zero_handle := seal
	zero_handle.persistent_storage_handle = 0
	testing.expect_value(t, storage_auth_seal_verify(&zero_handle), Tpm_Policy_Refusal.Zero_Persistent_Handle)

	zero_policy := seal
	zero_policy.policy_digest = {}
	testing.expect_value(t, storage_auth_seal_verify(&zero_policy), Tpm_Policy_Refusal.Zero_Policy_Digest)

	// Tampered integrity tag or auth value is refused.
	bad_tag := seal
	bad_tag.integrity_tag[0] ~= 0x01
	testing.expect_value(t, storage_auth_seal_verify(&bad_tag), Tpm_Policy_Refusal.Integrity_Mismatch)

	bad_auth := seal
	bad_auth.auth_value[31] ~= 0x80
	testing.expect_value(t, storage_auth_seal_verify(&bad_auth), Tpm_Policy_Refusal.Integrity_Mismatch)

	// Encode refuses short destination without mutating it.
	short_dst: [STORAGE_AUTH_SEAL_WIRE_SIZE - 1]u8
	for &b in short_dst {
		b = 0x55
	}
	short_written, short_ref := storage_auth_seal_encode(&seal, short_dst[:])
	testing.expect_value(t, short_ref, Tpm_Policy_Refusal.Bad_Wire_Length)
	testing.expect_value(t, short_written, 0)
	testing.expect_value(t, short_dst[0], u8(0x55))

	// Valid encode/decode round-trip.
	wire: [STORAGE_AUTH_SEAL_WIRE_SIZE]u8
	written, enc_ref := storage_auth_seal_encode(&seal, wire[:])
	testing.expect_value(t, enc_ref, Tpm_Policy_Refusal.None)
	testing.expect_value(t, written, STORAGE_AUTH_SEAL_WIRE_SIZE)

	decoded, dec_ref := storage_auth_seal_decode(wire[:])
	testing.expect_value(t, dec_ref, Tpm_Policy_Refusal.None)
	testing.expect_value(t, decoded, seal)

	// Decode refuses truncated, trailing, bad magic, bad version, and nonzero reserved.
	_, trunc_ref := storage_auth_seal_decode(wire[:STORAGE_AUTH_SEAL_WIRE_SIZE - 1])
	testing.expect_value(t, trunc_ref, Tpm_Policy_Refusal.Bad_Wire_Length)
	trailing: [STORAGE_AUTH_SEAL_WIRE_SIZE + 1]u8
	copy(trailing[:STORAGE_AUTH_SEAL_WIRE_SIZE], wire[:])
	_, trail_ref := storage_auth_seal_decode(trailing[:])
	testing.expect_value(t, trail_ref, Tpm_Policy_Refusal.Bad_Wire_Length)

	bad_magic := wire
	bad_magic[0] ~= 0xFF
	_, magic_ref := storage_auth_seal_decode(bad_magic[:])
	testing.expect_value(t, magic_ref, Tpm_Policy_Refusal.Bad_Magic)

	bad_ver := wire
	byte_order.write_u32_little_endian(bad_ver[:], 8, 9)
	_, ver_ref := storage_auth_seal_decode(bad_ver[:])
	testing.expect_value(t, ver_ref, Tpm_Policy_Refusal.Unsupported_Version)

	bad_res := wire
	byte_order.write_u32_little_endian(bad_res[:], 12, 1)
	_, res_ref := storage_auth_seal_decode(bad_res[:])
	testing.expect_value(t, res_ref, Tpm_Policy_Refusal.Nonzero_Reserved)
}

@(test)
authorized_policy_refusals_and_pcr7_transition :: proc(t: ^testing.T) {
	priv_pub, pub_trusted := test_keypair(10)
	priv_other, pub_other := test_keypair(11)
	pcr7_before := test_digest(20)
	pcr7_after_dbx := test_digest(21)
	policy_v3 := test_digest(30)
	policy_v4 := test_digest(31)

	env_v3 := make_signed_policy(&priv_pub, pub_trusted, .Machine_Key_Seal, 2, 3, policy_v3, pcr7_before)
	wire: [AUTHORIZED_POLICY_WIRE_SIZE]u8
	written, enc_ref := authorized_policy_encode(&env_v3, wire[:])
	testing.expect_value(t, enc_ref, Tpm_Policy_Refusal.None)
	testing.expect_value(t, written, AUTHORIZED_POLICY_WIRE_SIZE)

	decoded, dec_ref := authorized_policy_decode(wire[:])
	testing.expect_value(t, dec_ref, Tpm_Policy_Refusal.None)
	testing.expect_value(t, decoded, env_v3)

	// Missing verifier and zero trusted publisher key are refused.
	testing.expect_value(t, authorized_policy_verify(&decoded, .Machine_Key_Seal, pub_trusted, 2, 3, nil), Tpm_Policy_Refusal.Missing_Verifier)
	zero_key: [PUBLISHER_KEY_TAG_SIZE]u8
	testing.expect_value(t, authorized_policy_verify(&decoded, .Machine_Key_Seal, zero_key, 2, 3, ed25519_verify_callback), Tpm_Policy_Refusal.Zero_Publisher_Key)

	// Policy kind mismatch and unknown policy kind are refused.
	testing.expect_value(t, authorized_policy_verify(&decoded, .Rollback_Floor, pub_trusted, 2, 3, ed25519_verify_callback), Tpm_Policy_Refusal.Policy_Kind_Mismatch)
	testing.expect_value(t, authorized_policy_verify(&decoded, .None, pub_trusted, 2, 3, ed25519_verify_callback), Tpm_Policy_Refusal.Unknown_Policy_Kind)

	// Version floor downgrade (envelope floor 3 < current floor 4) is refused.
	testing.expect_value(t, authorized_policy_verify(&decoded, .Machine_Key_Seal, pub_trusted, 2, 4, ed25519_verify_callback), Tpm_Policy_Refusal.Version_Downgrade)

	// Revoked key number (envelope key 2 < current key floor 3) is refused.
	testing.expect_value(t, authorized_policy_verify(&decoded, .Machine_Key_Seal, pub_trusted, 3, 1, ed25519_verify_callback), Tpm_Policy_Refusal.Key_Revoked)

	// Untrusted publisher key is refused.
	untrusted := make_signed_policy(&priv_other, pub_other, .Machine_Key_Seal, 2, 4, policy_v4, pcr7_after_dbx)
	testing.expect_value(t, authorized_policy_verify(&untrusted, .Machine_Key_Seal, pub_trusted, 2, 3, ed25519_verify_callback), Tpm_Policy_Refusal.Untrusted_Publisher_Key)

	// Tampered policy digest fails signature check.
	tampered := decoded
	tampered.approved_policy_digest[0] ~= 0x01
	testing.expect_value(t, authorized_policy_verify(&tampered, .Machine_Key_Seal, pub_trusted, 2, 3, ed25519_verify_callback), Tpm_Policy_Refusal.Bad_Signature)

	// Out-of-range key numbers and version floors (0, 65, max(u32)) are refused on decode.
	bad_key_zero := wire
	byte_order.write_u32_little_endian(bad_key_zero[:], 16, 0)
	_, ref_k0 := authorized_policy_decode(bad_key_zero[:])
	testing.expect_value(t, ref_k0, Tpm_Policy_Refusal.Key_Number_Out_Of_Range)

	bad_key_65 := wire
	byte_order.write_u32_little_endian(bad_key_65[:], 16, 65)
	_, ref_k65 := authorized_policy_decode(bad_key_65[:])
	testing.expect_value(t, ref_k65, Tpm_Policy_Refusal.Key_Number_Out_Of_Range)

	bad_floor_0 := wire
	byte_order.write_u32_little_endian(bad_floor_0[:], 20, 0)
	_, ref_v0 := authorized_policy_decode(bad_floor_0[:])
	testing.expect_value(t, ref_v0, Tpm_Policy_Refusal.Version_Floor_Out_Of_Range)

	bad_floor_65 := wire
	byte_order.write_u32_little_endian(bad_floor_65[:], 20, 65)
	_, ref_v65 := authorized_policy_decode(bad_floor_65[:])
	testing.expect_value(t, ref_v65, Tpm_Policy_Refusal.Version_Floor_Out_Of_Range)

	// Wire length, unknown kind, and nonzero reserved bytes are refused.
	_, ref_short := authorized_policy_decode(wire[:AUTHORIZED_POLICY_WIRE_SIZE - 1])
	testing.expect_value(t, ref_short, Tpm_Policy_Refusal.Bad_Wire_Length)
	extra: [AUTHORIZED_POLICY_WIRE_SIZE + 1]u8
	copy(extra[:AUTHORIZED_POLICY_WIRE_SIZE], wire[:])
	_, ref_long := authorized_policy_decode(extra[:])
	testing.expect_value(t, ref_long, Tpm_Policy_Refusal.Bad_Wire_Length)

	bad_kind := wire
	bad_kind[12] = 9
	_, ref_kind := authorized_policy_decode(bad_kind[:])
	testing.expect_value(t, ref_kind, Tpm_Policy_Refusal.Unknown_Policy_Kind)

	bad_reserved := wire
	bad_reserved[13] = 1
	_, ref_res := authorized_policy_decode(bad_reserved[:])
	testing.expect_value(t, ref_res, Tpm_Policy_Refusal.Nonzero_Reserved)

	// Valid PCR 7 transition update (e.g., firmware dbx update changes PCR 7) passes
	// when signed by trusted publisher at or above current floors, for both kinds.
	env_pcr7_update := make_signed_policy(&priv_pub, pub_trusted, .Machine_Key_Seal, 2, 4, policy_v4, pcr7_after_dbx)
	testing.expect_value(t, authorized_policy_verify(&env_pcr7_update, .Machine_Key_Seal, pub_trusted, 2, 3, ed25519_verify_callback), Tpm_Policy_Refusal.None)

	floor_pcr7_update := make_signed_policy(&priv_pub, pub_trusted, .Rollback_Floor, 2, 64, policy_v4, pcr7_after_dbx)
	testing.expect_value(t, authorized_policy_verify(&floor_pcr7_update, .Rollback_Floor, pub_trusted, 2, 64, ed25519_verify_callback), Tpm_Policy_Refusal.None)

	// Border enum word checks.
	_, kind_0_ok := tpm_policy_kind_from_word(0)
	testing.expect(t, !kind_0_ok)
	_, kind_1_ok := tpm_policy_kind_from_word(1)
	testing.expect(t, kind_1_ok)
	_, kind_past_ok := tpm_policy_kind_from_word(u64(max(Tpm_Policy_Kind)) + 1)
	testing.expect(t, !kind_past_ok)

	_, ref_max_ok := tpm_policy_refusal_from_word(u64(max(Tpm_Policy_Refusal)))
	testing.expect(t, ref_max_ok)
	_, ref_past_ok := tpm_policy_refusal_from_word(u64(max(Tpm_Policy_Refusal)) + 1)
	testing.expect(t, !ref_past_ok)
}
