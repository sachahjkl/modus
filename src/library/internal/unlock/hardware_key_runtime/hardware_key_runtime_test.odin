#+build !freestanding
package hardware_key_runtime

import "core:testing"
import "modus:contract/hardware_keys"

@(private = "file")
verify_accept :: proc "contextless" (
	public_key: [hardware_keys.HARDWARE_KEY_PUBLIC_KEY_SIZE]u8,
	message: []u8,
	signature: [hardware_keys.HARDWARE_KEY_SIGNATURE_SIZE]u8,
	user: rawptr,
) -> bool {
	_ = public_key
	_ = message
	_ = user
	return signature[0] == 0x5A
}

@(test)
unlock_hardware_key_enrollment_challenge_replay_and_rollback :: proc(t: ^testing.T) {
	reg: Registry
	pub: [hardware_keys.HARDWARE_KEY_PUBLIC_KEY_SIZE]u8
	pub[0] = 0x33
	nonce: [hardware_keys.HARDWARE_KEY_CHALLENGE_SIZE]u8
	nonce[0] = 0x77
	sig: [hardware_keys.HARDWARE_KEY_SIGNATURE_SIZE]u8
	sig[0] = 0x5A

	// Refusal edges: nil registry, bad protocol, zero key, duplicate, zero nonce, unenrolled.
	testing.expect_value(t, enroll(nil, 1, .Ctap2_Fido2, pub), Enrollment_Refusal.Null_Registry)
	testing.expect_value(t, enroll(&reg, 1, .None, pub), Enrollment_Refusal.Bad_Protocol)
	testing.expect_value(t, enroll(&reg, 1, .Ctap2_Fido2, {}), Enrollment_Refusal.Zero_Public_Key)
	_, un_ref := challenge_issue(&reg, 1, nonce)
	testing.expect_value(t, un_ref, Enrollment_Refusal.Not_Enrolled)

	testing.expect_value(t, enroll(&reg, 1, .Ctap2_Fido2, pub), Enrollment_Refusal.None)
	testing.expect_value(t, enroll(&reg, 1, .Ctap2_Fido2, pub), Enrollment_Refusal.Already_Enrolled)

	_, z_ref := challenge_issue(&reg, 1, {})
	testing.expect_value(t, z_ref, Enrollment_Refusal.Zero_Challenge)

	// Verify without pending challenge is refused.
	e_ref, _ := verify_unlock_assertion(&reg, 1, nil, verify_accept)
	testing.expect_value(t, e_ref, Enrollment_Refusal.No_Pending_Challenge)

	// Issue challenge, build valid assertion, verify success.
	ch, ch_ref := challenge_issue(&reg, 1, nonce)
	testing.expect_value(t, ch_ref, Enrollment_Refusal.None)
	testing.expect_value(t, ch.purpose, hardware_keys.Hardware_Key_Purpose.Unlock)
	testing.expect(t, ch.require_user_presence && ch.require_user_verification)

	assertion := hardware_keys.Hardware_Key_Assertion{
		version    = hardware_keys.HARDWARE_KEY_VERSION,
		protocol   = .Ctap2_Fido2,
		purpose    = .Unlock,
		flags      = {.User_Present, .User_Verified},
		sign_count = 5,
		challenge  = nonce,
		public_key = pub,
		signature  = sig,
	}
	testing.expect_value(t, hardware_keys.hardware_key_assertion_scope_set(&assertion, UNLOCK_SCOPE), hardware_keys.Hardware_Key_Refusal.None)
	wire: [hardware_keys.HARDWARE_KEY_WIRE_LIMIT]u8
	wlen, enc_ref := hardware_keys.hardware_key_assertion_encode(&assertion, wire[:])
	testing.expect_value(t, enc_ref, hardware_keys.Hardware_Key_Refusal.None)

	er, kr := verify_unlock_assertion(&reg, 1, wire[:wlen], verify_accept)
	testing.expect_value(t, er, Enrollment_Refusal.None)
	testing.expect_value(t, kr, hardware_keys.Hardware_Key_Refusal.None)

	// Immediate replay of same assertion is refused (single-use challenge consumed).
	er, _ = verify_unlock_assertion(&reg, 1, wire[:wlen], verify_accept)
	testing.expect_value(t, er, Enrollment_Refusal.No_Pending_Challenge)

	// New challenge with rolled-back sign_count (5 <= 5) is refused.
	nonce2 := nonce
	nonce2[1] = 0x88
	_, _ = challenge_issue(&reg, 1, nonce2)
	assertion.challenge = nonce2
	wlen, _ = hardware_keys.hardware_key_assertion_encode(&assertion, wire[:])
	er, kr = verify_unlock_assertion(&reg, 1, wire[:wlen], verify_accept)
	testing.expect_value(t, er, Enrollment_Refusal.None)
	testing.expect_value(t, kr, hardware_keys.Hardware_Key_Refusal.Sign_Count_Rollback)

	// Missing User_Verified bit on unlock assertion is refused.
	_, _ = challenge_issue(&reg, 1, nonce2)
	assertion.sign_count = 6
	assertion.flags = {.User_Present}
	wlen, _ = hardware_keys.hardware_key_assertion_encode(&assertion, wire[:])
	er, kr = verify_unlock_assertion(&reg, 1, wire[:wlen], verify_accept)
	testing.expect_value(t, er, Enrollment_Refusal.None)
	testing.expect_value(t, kr, hardware_keys.Hardware_Key_Refusal.User_Verification_Missing)

	// Cross-purpose assertion (.Browser_WebAuthn) is refused.
	_, _ = challenge_issue(&reg, 1, nonce2)
	assertion.flags = {.User_Present, .User_Verified}
	assertion.purpose = .Browser_WebAuthn
	wlen, _ = hardware_keys.hardware_key_assertion_encode(&assertion, wire[:])
	er, kr = verify_unlock_assertion(&reg, 1, wire[:wlen], verify_accept)
	testing.expect_value(t, er, Enrollment_Refusal.None)
	testing.expect_value(t, kr, hardware_keys.Hardware_Key_Refusal.Purpose_Mismatch)

	// Table capacity bound: fill remaining slots, bound+1 returns Table_Full.
	for p in u64(2) ..= u64(ENROLLMENT_CAPACITY) {
		pk := pub
		pk[1] = u8(p)
		testing.expect_value(t, enroll(&reg, p, .Smartcard_Piv, pk), Enrollment_Refusal.None)
	}
	testing.expect_value(t, enroll(&reg, u64(ENROLLMENT_CAPACITY) + 1, .Smartcard_Piv, pub), Enrollment_Refusal.Table_Full)
}
