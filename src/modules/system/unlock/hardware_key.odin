// Live hardware security key verification bridge in unlock
// (src/md/features/hardware_keys.md).
//
// Connects internal:unlock/hardware_key_runtime to unlock's imported
// cryptography module (ed25519_verify) so enrolled hardware tokens can
// verify principal unlock challenges with UP+UV and monotonic sign counters.
package unlock

import hwk_rt "internal:unlock/hardware_key_runtime"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/hardware_keys"

foreign _ {
	@(require_results)
	ed25519_verify :: proc "c" (public, message, signature: ^string, error: ^errors.Error_Record) -> (call_outcome.Call_Outcome, i64) ---
}

// Package-level BSS registry of enrolled principal hardware tokens.
unlock_hardware_keys: hwk_rt.Registry

@(private = "file")
unlock_ed25519_verify :: proc "contextless" (
	public_key: [hardware_keys.HARDWARE_KEY_PUBLIC_KEY_SIZE]u8,
	message: []u8,
	signature: [hardware_keys.HARDWARE_KEY_SIGNATURE_SIZE]u8,
	user: rawptr,
) -> bool {
	_ = user
	pub := public_key
	sig := signature
	pub_str := string(pub[:])
	msg_str := string(message)
	sig_str := string(sig[:])
	err: errors.Error_Record
	outcome, _ := ed25519_verify(&pub_str, &msg_str, &sig_str, &err)
	return outcome == .Succeeded
}

// hardware_key_unlock_verify verifies a canonical hardware-key assertion wire
// payload against principal's pending unlock challenge using Ed25519.
hardware_key_unlock_verify :: proc "contextless" (
	principal: u64,
	wire_assertion: []u8,
) -> (enroll_ref: hwk_rt.Enrollment_Refusal, key_ref: hardware_keys.Hardware_Key_Refusal) {
	return hwk_rt.verify_unlock_assertion(&unlock_hardware_keys, principal, wire_assertion, unlock_ed25519_verify)
}
