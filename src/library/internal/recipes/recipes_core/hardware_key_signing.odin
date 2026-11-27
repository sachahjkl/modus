// Hardware security key verification for realisation signing in recipes_core
// (src/md/features/hardware_keys.md; src/md/features/recipes.md).
//
// Verifies canonical "MODHWK01" hardware-key assertions bound strictly to
// Hardware_Key_Purpose.Sign_Realisation, the recipe output hash scope, user
// presence, and a monotonic signature counter without heap allocation.
package recipes_core

import "modus:contract/blake3"
import "modus:contract/hardware_keys"

// Format property: "realisation:" prefix + 64 lowercase hex digits of BLAKE3 hash.
REALISATION_SCOPE_PREFIX :: "realisation:"
REALISATION_SCOPE_BYTES :: len(REALISATION_SCOPE_PREFIX) + 64

// State tracking the enrolled hardware key, single-use challenge nonce, and
// last accepted monotonic sign count for realisation signing.
Realisation_Key_Gate :: struct {
	expected_public_key: [hardware_keys.HARDWARE_KEY_PUBLIC_KEY_SIZE]u8,
	protocol:            hardware_keys.Hardware_Key_Protocol,
	last_sign_count:     u32,
	configured:          bool,
	has_challenge:       bool,
	pending_nonce:       [hardware_keys.HARDWARE_KEY_CHALLENGE_SIZE]u8,
}

// realisation_scope_format writes "realisation:<64-hex-hash>" into out.
realisation_scope_format :: proc "contextless" (output_hash: blake3.Hash, out: ^[REALISATION_SCOPE_BYTES]u8) -> string {
	hex := "0123456789abcdef"
	copy(out[:len(REALISATION_SCOPE_PREFIX)], REALISATION_SCOPE_PREFIX)
	pos := len(REALISATION_SCOPE_PREFIX)
	for b in output_hash {
		out[pos] = hex[b >> 4]
		out[pos + 1] = hex[b & 0x0F]
		pos += 2
	}
	return string(out[:])
}

// realisation_key_gate_init binds an unconfigured gate to one enrolled
// hardware-key public key and protocol, refusing re-initialization so an
// already-configured gate's monotonic sign_count cannot be reset.
realisation_key_gate_init :: proc "contextless" (
	gate: ^Realisation_Key_Gate,
	protocol: hardware_keys.Hardware_Key_Protocol,
	public_key: [hardware_keys.HARDWARE_KEY_PUBLIC_KEY_SIZE]u8,
) -> hardware_keys.Hardware_Key_Refusal {
	if gate == nil {
		return .Bad_Wire_Length
	}
	if gate.configured {
		return .Key_Mismatch
	}
	if _, ok := hardware_keys.hardware_key_protocol_from_word(u64(protocol)); !ok {
		return .Unknown_Protocol
	}
	acc: u8
	for b in public_key {
		acc |= b
	}
	if acc == 0 {
		return .Zero_Public_Key
	}
	gate^ = {}
	gate.protocol = protocol
	gate.expected_public_key = public_key
	gate.configured = true
	return .None
}

// realisation_key_challenge_issue stores a single-use 32-byte nonce on gate
// and builds the Hardware_Key_Challenge requiring both User Presence and User
// Verification for .Sign_Realisation.
realisation_key_challenge_issue :: proc "contextless" (
	gate: ^Realisation_Key_Gate,
	output_hash: blake3.Hash,
	nonce: [hardware_keys.HARDWARE_KEY_CHALLENGE_SIZE]u8,
	scope_out: ^[REALISATION_SCOPE_BYTES]u8,
) -> (challenge: hardware_keys.Hardware_Key_Challenge, refusal: hardware_keys.Hardware_Key_Refusal) {
	if gate == nil || !gate.configured {
		return {}, .Zero_Public_Key
	}
	if scope_out == nil {
		return {}, .Bad_Wire_Length
	}
	acc: u8
	for b in nonce {
		acc |= b
	}
	if acc == 0 {
		return {}, .Zero_Challenge
	}
	gate.pending_nonce = nonce
	gate.has_challenge = true
	return hardware_keys.Hardware_Key_Challenge{
		protocol                  = gate.protocol,
		purpose                   = .Sign_Realisation,
		challenge                 = nonce,
		scope                     = realisation_scope_format(output_hash, scope_out),
		require_user_presence     = true,
		require_user_verification = true,
	}, .None
}

// realisation_hardware_key_verify consumes gate's pending single-use challenge
// and verifies that the hardware token signed output_hash under purpose
// .Sign_Realisation with User_Present, User_Verified, and a monotonic sign_count.
realisation_hardware_key_verify :: proc "contextless" (
	gate: ^Realisation_Key_Gate,
	output_hash: blake3.Hash,
	wire_assertion: []u8,
	verify_sig: hardware_keys.Hardware_Key_Verify_Proc,
	user: rawptr = nil,
) -> hardware_keys.Hardware_Key_Refusal {
	if gate == nil || !gate.configured {
		return .Zero_Public_Key
	}
	if !gate.has_challenge {
		return .Zero_Challenge
	}
	// Consume single-use challenge unconditionally before decoding or verifying.
	expected_nonce := gate.pending_nonce
	gate.has_challenge = false
	gate.pending_nonce = {}

	assertion, dec_ref := hardware_keys.hardware_key_assertion_decode(wire_assertion)
	if dec_ref != .None {
		return dec_ref
	}
	scope_buf: [REALISATION_SCOPE_BYTES]u8
	scope := realisation_scope_format(output_hash, &scope_buf)
	challenge := hardware_keys.Hardware_Key_Challenge{
		protocol                  = gate.protocol,
		purpose                   = .Sign_Realisation,
		challenge                 = expected_nonce,
		scope                     = scope,
		require_user_presence     = true,
		require_user_verification = true,
	}
	ver_ref := hardware_keys.hardware_key_assertion_verify(
		&challenge,
		&assertion,
		gate.expected_public_key,
		gate.last_sign_count,
		verify_sig,
		user,
	)
	if ver_ref != .None {
		return ver_ref
	}
	if assertion.sign_count > gate.last_sign_count {
		gate.last_sign_count = assertion.sign_count
	}
	return .None
}
