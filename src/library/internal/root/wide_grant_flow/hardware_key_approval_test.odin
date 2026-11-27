#+build !freestanding
package wide_grant_flow

import "core:testing"
import "modus:contract/hardware_keys"

@(private = "file")
wg_test_verify :: proc "contextless" (
	public_key: [hardware_keys.HARDWARE_KEY_PUBLIC_KEY_SIZE]u8,
	message: []u8,
	signature: [hardware_keys.HARDWARE_KEY_SIGNATURE_SIZE]u8,
	user: rawptr,
) -> bool {
	_ = public_key
	_ = message
	_ = user
	return signature[0] == 0x7E
}

@(test)
wide_grant_hardware_key_approval_enforces_uv_up_and_replay_protection :: proc(t: ^testing.T) {
	table: Wide_Grant_Hardware_Keys
	pub: [hardware_keys.HARDWARE_KEY_PUBLIC_KEY_SIZE]u8
	pub[0] = 0x55
	nonce: [hardware_keys.HARDWARE_KEY_CHALLENGE_SIZE]u8
	nonce[0] = 0x66
	sig: [hardware_keys.HARDWARE_KEY_SIGNATURE_SIZE]u8
	sig[0] = 0x7E

	// Out-of-range principal, unknown protocol, and zero key are refused.
	testing.expect_value(t, hardware_key_enroll(&table, PRINCIPALS_MOST, .Ctap2_Fido2, pub), hardware_keys.Hardware_Key_Refusal.Bad_Wire_Length)
	testing.expect_value(t, hardware_key_enroll(&table, 1, .None, pub), hardware_keys.Hardware_Key_Refusal.Unknown_Protocol)
	testing.expect_value(t, hardware_key_enroll(&table, 1, .Ctap2_Fido2, {}), hardware_keys.Hardware_Key_Refusal.Zero_Public_Key)
	testing.expect_value(t, hardware_key_enroll(&table, 1, .Ctap2_Fido2, pub), hardware_keys.Hardware_Key_Refusal.None)

	// Zero nonce refused; missing pending challenge refused.
	_, zref := hardware_key_challenge_begin(&table, 1, {})
	testing.expect_value(t, zref, hardware_keys.Hardware_Key_Refusal.Zero_Challenge)
	testing.expect_value(t, hardware_key_approve_verify(&table, 1, nil, wg_test_verify), hardware_keys.Hardware_Key_Refusal.Zero_Challenge)

	// Valid wide-grant approval assertion passes.
	ch, cref := hardware_key_challenge_begin(&table, 1, nonce)
	testing.expect_value(t, cref, hardware_keys.Hardware_Key_Refusal.None)
	testing.expect_value(t, ch.purpose, hardware_keys.Hardware_Key_Purpose.Approve_Wide_Grant)

	assertion := hardware_keys.Hardware_Key_Assertion{
		version    = hardware_keys.HARDWARE_KEY_VERSION,
		protocol   = .Ctap2_Fido2,
		purpose    = .Approve_Wide_Grant,
		flags      = {.User_Present, .User_Verified},
		sign_count = 12,
		challenge  = nonce,
		public_key = pub,
		signature  = sig,
	}
	testing.expect_value(t, hardware_keys.hardware_key_assertion_scope_set(&assertion, WIDE_GRANT_HARDWARE_SCOPE), hardware_keys.Hardware_Key_Refusal.None)
	wire: [hardware_keys.HARDWARE_KEY_WIRE_LIMIT]u8
	wlen, enc_ref := hardware_keys.hardware_key_assertion_encode(&assertion, wire[:])
	testing.expect_value(t, enc_ref, hardware_keys.Hardware_Key_Refusal.None)

	testing.expect_value(t, hardware_key_approve_verify(&table, 1, wire[:wlen], wg_test_verify), hardware_keys.Hardware_Key_Refusal.None)
	testing.expect_value(t, table.principals[1].last_sign_count, u32(12))

	// Re-enrolling an already-enrolled principal is refused and preserves last_sign_count.
	other_pub := pub
	other_pub[1] = 0xAA
	testing.expect_value(t, hardware_key_enroll(&table, 1, .Ctap2_Fido2, other_pub), hardware_keys.Hardware_Key_Refusal.Key_Mismatch)
	testing.expect_value(t, table.principals[1].last_sign_count, u32(12))
	testing.expect_value(t, table.principals[1].public_key, pub)

	// Replayed wire assertion is refused because challenge was consumed.
	testing.expect_value(t, hardware_key_approve_verify(&table, 1, wire[:wlen], wg_test_verify), hardware_keys.Hardware_Key_Refusal.Zero_Challenge)

	// Missing User_Present on a fresh challenge is refused.
	nonce2 := nonce
	nonce2[1] = 0xAA
	_, _ = hardware_key_challenge_begin(&table, 1, nonce2)
	assertion.challenge = nonce2
	assertion.sign_count = 13
	assertion.flags = {.User_Verified}
	wlen, _ = hardware_keys.hardware_key_assertion_encode(&assertion, wire[:])
	testing.expect_value(t, hardware_key_approve_verify(&table, 1, wire[:wlen], wg_test_verify), hardware_keys.Hardware_Key_Refusal.User_Presence_Missing)
}
