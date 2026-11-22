// Live TPM lockout classification and encrypted parameter session helper wired
// into the unlock service.
package unlock

import "modus:contract/serial_ring"

unlock_tpm_lockout_state :: proc "contextless" (counter, max_tries: u32) -> serial_ring.Tpm_Lockout_State {
	return serial_ring.tpm_lockout_classify(counter, max_tries)
}

unlock_tpm_protect_parameter :: proc "contextless" (session_key, nonce_caller, nonce_tpm: [32]u8, payload: []u8) {
	serial_ring.tpm_session_xor_parameter(session_key, nonce_caller, nonce_tpm, payload)
}
