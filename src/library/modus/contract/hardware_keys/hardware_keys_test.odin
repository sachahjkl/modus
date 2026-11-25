#+build !freestanding
package hardware_keys

import "base:runtime"
import "core:testing"
import "modus:contract/blake3"
import "modus:contract/byte_order"
import ed25519 "core:crypto/ed25519"

@(private = "file")
test_challenge_bytes :: proc(seed: u8) -> [HARDWARE_KEY_CHALLENGE_SIZE]u8 {
	input := [4]u8{seed, seed ~ 0x6B, seed + 31, 0x91}
	return blake3.hash(input[:])
}

@(private = "file")
test_keypair :: proc(seed_byte: u8) -> (priv: ed25519.Private_Key, pub: [HARDWARE_KEY_PUBLIC_KEY_SIZE]u8) {
	seed: [ed25519.PRIVATE_KEY_SIZE]u8
	for index in 0 ..< len(seed) {
		seed[index] = seed_byte + u8(index * 19 + 11)
	}
	ok := ed25519.private_key_set_bytes(&priv, seed[:])
	assert(ok)
	ed25519.private_key_public_bytes(&priv, pub[:])
	return priv, pub
}

@(private = "file")
ed25519_verify_callback :: proc "contextless" (
	pub_key: [HARDWARE_KEY_PUBLIC_KEY_SIZE]u8,
	message: []u8,
	signature: [HARDWARE_KEY_SIGNATURE_SIZE]u8,
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
make_signed_assertion :: proc(
	priv: ^ed25519.Private_Key,
	pub: [HARDWARE_KEY_PUBLIC_KEY_SIZE]u8,
	protocol: Hardware_Key_Protocol,
	purpose: Hardware_Key_Purpose,
	flags: Hardware_Key_Flags,
	sign_count: u32,
	challenge: [HARDWARE_KEY_CHALLENGE_SIZE]u8,
	scope: string,
) -> Hardware_Key_Assertion {
	assertion := Hardware_Key_Assertion {
		version    = HARDWARE_KEY_VERSION,
		protocol   = protocol,
		purpose    = purpose,
		flags      = flags,
		sign_count = sign_count,
		challenge  = challenge,
		public_key = pub,
	}
	scope_ref := hardware_key_assertion_scope_set(&assertion, scope)
	assert(scope_ref == .None)
	signing_buf: [HARDWARE_KEY_SIGNING_LIMIT]u8
	written, build_ref := hardware_key_signing_bytes(&assertion, &signing_buf)
	assert(build_ref == .None && written > len(HARDWARE_KEY_DOMAIN))
	ed25519.sign(priv, signing_buf[:written], assertion.signature[:])
	return assertion
}

@(test)
hardware_key_refuses_all_bad_edges :: proc(t: ^testing.T) {
	priv, pub := test_keypair(30)
	priv_other, pub_other := test_keypair(31)
	nonce := test_challenge_bytes(1)
	other_nonce := test_challenge_bytes(2)

	ch := Hardware_Key_Challenge {
		protocol                  = .Ctap2_Fido2,
		purpose                   = .Approve_Wide_Grant,
		challenge                 = nonce,
		scope                     = "modus.wide_grant",
		require_user_presence     = true,
		require_user_verification = true,
	}

	valid := make_signed_assertion(&priv, pub, .Ctap2_Fido2, .Approve_Wide_Grant, {.User_Present, .User_Verified}, 5, nonce, "modus.wide_grant")
	wire: [HARDWARE_KEY_WIRE_LIMIT]u8
	written, enc_ref := hardware_key_assertion_encode(&valid, wire[:])
	testing.expect_value(t, enc_ref, Hardware_Key_Refusal.None)

	// Encode refuses short buffer without mutating it.
	short_dst: [HARDWARE_KEY_HEADER_SIZE]u8
	for &b in short_dst {
		b = 0xCC
	}
	short_written, short_ref := hardware_key_assertion_encode(&valid, short_dst[:])
	testing.expect_value(t, short_ref, Hardware_Key_Refusal.Bad_Wire_Length)
	testing.expect_value(t, short_written, 0)
	testing.expect_value(t, short_dst[0], u8(0xCC))

	// Decode refuses truncated and trailing buffers.
	_, ref_short := hardware_key_assertion_decode(wire[:written - 1])
	testing.expect_value(t, ref_short, Hardware_Key_Refusal.Bad_Wire_Length)
	wire[written] = 0x00
	_, ref_long := hardware_key_assertion_decode(wire[:written + 1])
	testing.expect_value(t, ref_long, Hardware_Key_Refusal.Bad_Wire_Length)

	// Decode refuses bad magic, bad version, unknown protocol, unknown purpose, unknown flags, nonzero reserved.
	bad_magic := wire
	bad_magic[0] ~= 0x01
	_, ref_magic := hardware_key_assertion_decode(bad_magic[:written])
	testing.expect_value(t, ref_magic, Hardware_Key_Refusal.Bad_Magic)

	bad_ver := wire
	byte_order.write_u32_little_endian(bad_ver[:], 8, 2)
	_, ref_ver := hardware_key_assertion_decode(bad_ver[:written])
	testing.expect_value(t, ref_ver, Hardware_Key_Refusal.Unsupported_Version)

	bad_proto := wire
	bad_proto[12] = 99
	_, ref_proto := hardware_key_assertion_decode(bad_proto[:written])
	testing.expect_value(t, ref_proto, Hardware_Key_Refusal.Unknown_Protocol)

	bad_purpose := wire
	bad_purpose[13] = 99
	_, ref_purpose := hardware_key_assertion_decode(bad_purpose[:written])
	testing.expect_value(t, ref_purpose, Hardware_Key_Refusal.Unknown_Purpose)

	bad_flags := wire
	bad_flags[14] = 0x04
	_, ref_flags := hardware_key_assertion_decode(bad_flags[:written])
	testing.expect_value(t, ref_flags, Hardware_Key_Refusal.Unknown_Flags)

	bad_res := wire
	bad_res[15] = 1
	_, ref_res := hardware_key_assertion_decode(bad_res[:written])
	testing.expect_value(t, ref_res, Hardware_Key_Refusal.Nonzero_Reserved)

	// Scope length 0, over limit, and whitespace byte are refused.
	empty_scope_assertion := valid
	testing.expect_value(t, hardware_key_assertion_scope_set(&empty_scope_assertion, ""), Hardware_Key_Refusal.Empty_Scope)
	long_scope: [HARDWARE_KEY_SCOPE_LIMIT + 1]u8
	for &b in long_scope {
		b = 'x'
	}
	testing.expect_value(t, hardware_key_assertion_scope_set(&empty_scope_assertion, string(long_scope[:])), Hardware_Key_Refusal.Scope_Too_Long)
	testing.expect_value(t, hardware_key_assertion_scope_set(&empty_scope_assertion, "bad scope"), Hardware_Key_Refusal.Bad_Scope_Byte)

	// Verifier refuses missing verifier, zero challenge, zero key, zero signature.
	testing.expect_value(t, hardware_key_assertion_verify(&ch, &valid, pub, 4, nil), Hardware_Key_Refusal.Missing_Verifier)
	zero_ch := ch
	zero_ch.challenge = {}
	testing.expect_value(t, hardware_key_assertion_verify(&zero_ch, &valid, pub, 4, ed25519_verify_callback), Hardware_Key_Refusal.Zero_Challenge)
	zero_pub: [HARDWARE_KEY_PUBLIC_KEY_SIZE]u8
	testing.expect_value(t, hardware_key_assertion_verify(&ch, &valid, zero_pub, 4, ed25519_verify_callback), Hardware_Key_Refusal.Zero_Public_Key)
	zero_sig := valid
	zero_sig.signature = {}
	testing.expect_value(t, hardware_key_assertion_verify(&ch, &zero_sig, pub, 4, ed25519_verify_callback), Hardware_Key_Refusal.Zero_Signature)

	// Missing UP or missing UV when required is refused.
	no_up := make_signed_assertion(&priv, pub, .Ctap2_Fido2, .Approve_Wide_Grant, {.User_Verified}, 5, nonce, "modus.wide_grant")
	testing.expect_value(t, hardware_key_assertion_verify(&ch, &no_up, pub, 4, ed25519_verify_callback), Hardware_Key_Refusal.User_Presence_Missing)

	no_uv := make_signed_assertion(&priv, pub, .Ctap2_Fido2, .Approve_Wide_Grant, {.User_Present}, 5, nonce, "modus.wide_grant")
	testing.expect_value(t, hardware_key_assertion_verify(&ch, &no_uv, pub, 4, ed25519_verify_callback), Hardware_Key_Refusal.User_Verification_Missing)

	// Purpose mismatch (cross-purpose replay from Browser_WebAuthn to Approve_Wide_Grant) is refused.
	wrong_purpose := make_signed_assertion(&priv, pub, .Ctap2_Fido2, .Browser_WebAuthn, {.User_Present, .User_Verified}, 5, nonce, "modus.wide_grant")
	testing.expect_value(t, hardware_key_assertion_verify(&ch, &wrong_purpose, pub, 4, ed25519_verify_callback), Hardware_Key_Refusal.Purpose_Mismatch)

	// Protocol mismatch, scope mismatch, challenge replay mismatch, key mismatch, and sign count rollback.
	wrong_proto := make_signed_assertion(&priv, pub, .Smartcard_Piv, .Approve_Wide_Grant, {.User_Present, .User_Verified}, 5, nonce, "modus.wide_grant")
	testing.expect_value(t, hardware_key_assertion_verify(&ch, &wrong_proto, pub, 4, ed25519_verify_callback), Hardware_Key_Refusal.Protocol_Mismatch)

	wrong_scope := make_signed_assertion(&priv, pub, .Ctap2_Fido2, .Approve_Wide_Grant, {.User_Present, .User_Verified}, 5, nonce, "evil.example")
	testing.expect_value(t, hardware_key_assertion_verify(&ch, &wrong_scope, pub, 4, ed25519_verify_callback), Hardware_Key_Refusal.Scope_Mismatch)

	replayed := make_signed_assertion(&priv, pub, .Ctap2_Fido2, .Approve_Wide_Grant, {.User_Present, .User_Verified}, 5, other_nonce, "modus.wide_grant")
	testing.expect_value(t, hardware_key_assertion_verify(&ch, &replayed, pub, 4, ed25519_verify_callback), Hardware_Key_Refusal.Challenge_Mismatch)

	other_key_assertion := make_signed_assertion(&priv_other, pub_other, .Ctap2_Fido2, .Approve_Wide_Grant, {.User_Present, .User_Verified}, 5, nonce, "modus.wide_grant")
	testing.expect_value(t, hardware_key_assertion_verify(&ch, &other_key_assertion, pub, 4, ed25519_verify_callback), Hardware_Key_Refusal.Key_Mismatch)

	testing.expect_value(t, hardware_key_assertion_verify(&ch, &valid, pub, 5, ed25519_verify_callback), Hardware_Key_Refusal.Sign_Count_Rollback)
	testing.expect_value(t, hardware_key_assertion_verify(&ch, &valid, pub, 10, ed25519_verify_callback), Hardware_Key_Refusal.Sign_Count_Rollback)

	// Tampered signature or tampered sign_count fails Ed25519 signature verification.
	tampered_sig := valid
	tampered_sig.signature[63] ~= 0x01
	testing.expect_value(t, hardware_key_assertion_verify(&ch, &tampered_sig, pub, 4, ed25519_verify_callback), Hardware_Key_Refusal.Bad_Signature)

	tampered_count := valid
	tampered_count.sign_count = 99
	testing.expect_value(t, hardware_key_assertion_verify(&ch, &tampered_count, pub, 4, ed25519_verify_callback), Hardware_Key_Refusal.Bad_Signature)

	// Border word checks.
	_, p0_ok := hardware_key_protocol_from_word(0)
	testing.expect(t, !p0_ok)
	_, p_past_ok := hardware_key_protocol_from_word(u64(max(Hardware_Key_Protocol)) + 1)
	testing.expect(t, !p_past_ok)
	_, u0_ok := hardware_key_purpose_from_word(0)
	testing.expect(t, !u0_ok)
	_, u_past_ok := hardware_key_purpose_from_word(u64(max(Hardware_Key_Purpose)) + 1)
	testing.expect(t, !u_past_ok)
	_, f_bad_ok := hardware_key_flags_from_word(0x04)
	testing.expect(t, !f_bad_ok)
	_, r_max_ok := hardware_key_refusal_from_word(u64(max(Hardware_Key_Refusal)))
	testing.expect(t, r_max_ok)
	_, r_past_ok := hardware_key_refusal_from_word(u64(max(Hardware_Key_Refusal)) + 1)
	testing.expect(t, !r_past_ok)
}

@(test)
hardware_key_all_protocols_and_purposes_round_trip :: proc(t: ^testing.T) {
	priv, pub := test_keypair(60)
	cases := [?]struct {
		protocol: Hardware_Key_Protocol,
		purpose:  Hardware_Key_Purpose,
		scope:    string,
		flags:    Hardware_Key_Flags,
		req_up:   bool,
		req_uv:   bool,
		count:    u32,
	} {
		{.Ctap2_Fido2, .Unlock, "modus.unlock", {.User_Present, .User_Verified}, true, true, 1},
		{.Ctap2_Fido2, .Approve_Wide_Grant, "modus.wide_grant", {.User_Present, .User_Verified}, true, true, 2},
		{.Smartcard_OpenPGP, .Sign_Realisation, "cache.modus.systems", {.User_Verified}, false, true, 0},
		{.Smartcard_Piv, .Browser_WebAuthn, "example.org", {.User_Present}, true, false, 7},
	}

	for entry, index in cases {
		nonce := test_challenge_bytes(u8(index + 10))
		ch := Hardware_Key_Challenge {
			protocol                  = entry.protocol,
			purpose                   = entry.purpose,
			challenge                 = nonce,
			scope                     = entry.scope,
			require_user_presence     = entry.req_up,
			require_user_verification = entry.req_uv,
		}
		assertion := make_signed_assertion(&priv, pub, entry.protocol, entry.purpose, entry.flags, entry.count, nonce, entry.scope)
		wire: [HARDWARE_KEY_WIRE_LIMIT]u8
		written, enc_ref := hardware_key_assertion_encode(&assertion, wire[:])
		testing.expect_value(t, enc_ref, Hardware_Key_Refusal.None)

		decoded, dec_ref := hardware_key_assertion_decode(wire[:written])
		testing.expect_value(t, dec_ref, Hardware_Key_Refusal.None)
		testing.expect_value(t, hardware_key_assertion_scope(&decoded), entry.scope)
		testing.expect_value(t, hardware_key_assertion_verify(&ch, &decoded, pub, 0, ed25519_verify_callback), Hardware_Key_Refusal.None)
	}
}
