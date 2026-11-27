#+build !freestanding
package recipes_core

import "core:testing"
import "modus:contract/blake3"
import "modus:contract/hardware_keys"

@(private = "file")
realisation_test_verify :: proc "contextless" (
	public_key: [hardware_keys.HARDWARE_KEY_PUBLIC_KEY_SIZE]u8,
	message: []u8,
	signature: [hardware_keys.HARDWARE_KEY_SIGNATURE_SIZE]u8,
	user: rawptr,
) -> bool {
	_ = public_key
	_ = message
	_ = user
	return signature[0] == 0xC3
}

@(test)
realisation_hardware_key_signing_enforces_purpose_scope_and_monotonic_count :: proc(t: ^testing.T) {
	gate: Realisation_Key_Gate
	pub: [hardware_keys.HARDWARE_KEY_PUBLIC_KEY_SIZE]u8
	pub[0] = 0x44
	challenge: [hardware_keys.HARDWARE_KEY_CHALLENGE_SIZE]u8
	challenge[0] = 0x99
	sig: [hardware_keys.HARDWARE_KEY_SIGNATURE_SIZE]u8
	sig[0] = 0xC3

	output_hash := blake3.hash([]u8{'o', 'u', 't'})
	other_hash := blake3.hash([]u8{'b', 'a', 'd'})

	// Refusals: unconfigured gate, bad protocol, zero key.
	testing.expect_value(t, realisation_key_gate_init(&gate, .None, pub), hardware_keys.Hardware_Key_Refusal.Unknown_Protocol)
	testing.expect_value(t, realisation_key_gate_init(&gate, .Smartcard_OpenPGP, {}), hardware_keys.Hardware_Key_Refusal.Zero_Public_Key)
	testing.expect_value(t, realisation_hardware_key_verify(&gate, output_hash, nil, realisation_test_verify), hardware_keys.Hardware_Key_Refusal.Zero_Public_Key)

	testing.expect_value(t, realisation_key_gate_init(&gate, .Smartcard_OpenPGP, pub), hardware_keys.Hardware_Key_Refusal.None)

	scope_buf: [REALISATION_SCOPE_BYTES]u8
	scope := realisation_scope_format(output_hash, &scope_buf)

	// Zero nonce and missing pending challenge are refused.
	_, zref := realisation_key_challenge_issue(&gate, output_hash, {}, &scope_buf)
	testing.expect_value(t, zref, hardware_keys.Hardware_Key_Refusal.Zero_Challenge)
	testing.expect_value(t, realisation_hardware_key_verify(&gate, output_hash, nil, realisation_test_verify), hardware_keys.Hardware_Key_Refusal.Zero_Challenge)

	assertion := hardware_keys.Hardware_Key_Assertion{
		version    = hardware_keys.HARDWARE_KEY_VERSION,
		protocol   = .Smartcard_OpenPGP,
		purpose    = .Sign_Realisation,
		flags      = {.User_Present},
		sign_count = 3,
		challenge  = challenge,
		public_key = pub,
		signature  = sig,
	}
	testing.expect_value(t, hardware_keys.hardware_key_assertion_scope_set(&assertion, scope), hardware_keys.Hardware_Key_Refusal.None)
	wire: [hardware_keys.HARDWARE_KEY_WIRE_LIMIT]u8
	wlen, enc_ref := hardware_keys.hardware_key_assertion_encode(&assertion, wire[:])
	testing.expect_value(t, enc_ref, hardware_keys.Hardware_Key_Refusal.None)

	// Missing User_Verified flag is refused and consumes the pending challenge.
	_, iref := realisation_key_challenge_issue(&gate, output_hash, challenge, &scope_buf)
	testing.expect_value(t, iref, hardware_keys.Hardware_Key_Refusal.None)
	testing.expect_value(t, realisation_hardware_key_verify(&gate, output_hash, wire[:wlen], realisation_test_verify), hardware_keys.Hardware_Key_Refusal.User_Verification_Missing)
	testing.expect_value(t, realisation_hardware_key_verify(&gate, output_hash, wire[:wlen], realisation_test_verify), hardware_keys.Hardware_Key_Refusal.Zero_Challenge)

	// Add User_Verified flag; wrong output hash is refused as Scope_Mismatch.
	assertion.flags = {.User_Present, .User_Verified}
	wlen, enc_ref = hardware_keys.hardware_key_assertion_encode(&assertion, wire[:])
	testing.expect_value(t, enc_ref, hardware_keys.Hardware_Key_Refusal.None)
	_, iref = realisation_key_challenge_issue(&gate, output_hash, challenge, &scope_buf)
	testing.expect_value(t, iref, hardware_keys.Hardware_Key_Refusal.None)
	testing.expect_value(t, realisation_hardware_key_verify(&gate, other_hash, wire[:wlen], realisation_test_verify), hardware_keys.Hardware_Key_Refusal.Scope_Mismatch)

	// Valid assertion succeeds and updates last_sign_count to 3.
	_, iref = realisation_key_challenge_issue(&gate, output_hash, challenge, &scope_buf)
	testing.expect_value(t, iref, hardware_keys.Hardware_Key_Refusal.None)
	testing.expect_value(t, realisation_hardware_key_verify(&gate, output_hash, wire[:wlen], realisation_test_verify), hardware_keys.Hardware_Key_Refusal.None)
	testing.expect_value(t, gate.last_sign_count, u32(3))

	// Immediate replay is refused because challenge was consumed.
	testing.expect_value(t, realisation_hardware_key_verify(&gate, output_hash, wire[:wlen], realisation_test_verify), hardware_keys.Hardware_Key_Refusal.Zero_Challenge)

	// Re-initialization of configured gate is refused and preserves last_sign_count.
	testing.expect_value(t, realisation_key_gate_init(&gate, .Smartcard_OpenPGP, pub), hardware_keys.Hardware_Key_Refusal.Key_Mismatch)
	testing.expect_value(t, gate.last_sign_count, u32(3))

	// Fresh challenge with equal sign_count is refused as Sign_Count_Rollback.
	_, iref = realisation_key_challenge_issue(&gate, output_hash, challenge, &scope_buf)
	testing.expect_value(t, iref, hardware_keys.Hardware_Key_Refusal.None)
	testing.expect_value(t, realisation_hardware_key_verify(&gate, output_hash, wire[:wlen], realisation_test_verify), hardware_keys.Hardware_Key_Refusal.Sign_Count_Rollback)

	// Cross-purpose assertion (.Unlock) is refused.
	assertion.sign_count = 4
	assertion.purpose = .Unlock
	wlen, _ = hardware_keys.hardware_key_assertion_encode(&assertion, wire[:])
	_, iref = realisation_key_challenge_issue(&gate, output_hash, challenge, &scope_buf)
	testing.expect_value(t, iref, hardware_keys.Hardware_Key_Refusal.None)
	testing.expect_value(t, realisation_hardware_key_verify(&gate, output_hash, wire[:wlen], realisation_test_verify), hardware_keys.Hardware_Key_Refusal.Purpose_Mismatch)
}
