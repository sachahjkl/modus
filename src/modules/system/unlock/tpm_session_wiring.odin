// TPM lockout classification and direction-separated session helper for unlock.
package unlock

import "modus:contract/serial_ring"

unlock_tpm_lockout_state :: proc "contextless" (counter, max_tries: u32) -> serial_ring.Tpm_Lockout_State {
	return serial_ring.tpm_lockout_classify(counter, max_tries)
}

unlock_tpm_protect_parameter :: proc "contextless" (dir: serial_ring.Session_Direction, session_key, nonce_caller, nonce_tpm: [32]u8, payload: []u8) {
	serial_ring.session_xor_mask(dir, session_key, nonce_caller, nonce_tpm, payload)
}
