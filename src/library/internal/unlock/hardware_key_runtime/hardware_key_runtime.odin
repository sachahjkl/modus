// Hardware security key enrollment, challenge issuance, and assertion
// verification runtime for the unlock service (src/md/features/hardware_keys.md).
//
// Enforces .Unlock purpose binding, "modus.unlock" scope, required User
// Presence and User Verification, single-use challenge consumption, and
// monotonic sign_count tracking without heap allocation or kernel calls.
package hardware_key_runtime

import "modus:contract/hardware_keys"

// Plan value: matches the maximum principal table capacity of the system.
ENROLLMENT_CAPACITY :: 16

// Format property: canonical scope string bound to every unlock challenge.
UNLOCK_SCOPE :: "modus.unlock"

// Closed set of refusals for enrollment and challenge lifecycle operations.
Enrollment_Refusal :: enum u8 {
	None             = 0,
	Null_Registry    = 1,
	Bad_Protocol     = 2,
	Zero_Public_Key  = 3,
	Already_Enrolled = 4,
	Table_Full       = 5,
	Not_Enrolled     = 6,
	Zero_Challenge   = 7,
	No_Pending_Challenge = 8,
}

// One enrolled hardware security token bound to a principal.
Enrolled_Token :: struct {
	active:          bool,
	principal:       u64,
	protocol:        hardware_keys.Hardware_Key_Protocol,
	public_key:      [hardware_keys.HARDWARE_KEY_PUBLIC_KEY_SIZE]u8,
	last_sign_count: u32,
	has_challenge:   bool,
	pending_nonce:   [hardware_keys.HARDWARE_KEY_CHALLENGE_SIZE]u8,
}

// Fixed-capacity hardware key registry owned by unlock.
Registry :: struct {
	tokens: [ENROLLMENT_CAPACITY]Enrolled_Token,
	count:  u32,
}

@(private = "file")
is_all_zero :: proc "contextless" (bytes: []u8) -> bool {
	acc: u8
	for b in bytes {
		acc |= b
	}
	return acc == 0
}

@(private = "file")
find_token :: proc "contextless" (reg: ^Registry, principal: u64) -> ^Enrolled_Token {
	for &tok in reg.tokens {
		if tok.active && tok.principal == principal {
			return &tok
		}
	}
	return nil
}

// enroll registers one hardware security token public key for principal.
// Refuses zero keys, unknown or None protocols, duplicate principals, or a
// full registry without mutating state.
enroll :: proc "contextless" (
	reg: ^Registry,
	principal: u64,
	protocol: hardware_keys.Hardware_Key_Protocol,
	public_key: [hardware_keys.HARDWARE_KEY_PUBLIC_KEY_SIZE]u8,
) -> Enrollment_Refusal {
	if reg == nil {
		return .Null_Registry
	}
	if _, ok := hardware_keys.hardware_key_protocol_from_word(u64(protocol)); !ok {
		return .Bad_Protocol
	}
	key_copy := public_key
	if is_all_zero(key_copy[:]) {
		return .Zero_Public_Key
	}
	if find_token(reg, principal) != nil {
		return .Already_Enrolled
	}
	for &tok in reg.tokens {
		if !tok.active {
			tok = {
				active     = true,
				principal  = principal,
				protocol   = protocol,
				public_key = public_key,
			}
			reg.count += 1
			return .None
		}
	}
	return .Table_Full
}

// challenge_issue binds one fresh 32-byte nonce to principal's enrolled token
// and returns the Unlock Hardware_Key_Challenge requiring both UP and UV.
challenge_issue :: proc "contextless" (
	reg: ^Registry,
	principal: u64,
	nonce: [hardware_keys.HARDWARE_KEY_CHALLENGE_SIZE]u8,
) -> (challenge: hardware_keys.Hardware_Key_Challenge, refusal: Enrollment_Refusal) {
	if reg == nil {
		return {}, .Null_Registry
	}
	nonce_copy := nonce
	if is_all_zero(nonce_copy[:]) {
		return {}, .Zero_Challenge
	}
	tok := find_token(reg, principal)
	if tok == nil {
		return {}, .Not_Enrolled
	}
	tok.pending_nonce = nonce
	tok.has_challenge = true
	return hardware_keys.Hardware_Key_Challenge{
		protocol                  = tok.protocol,
		purpose                   = .Unlock,
		challenge                 = nonce,
		scope                     = UNLOCK_SCOPE,
		require_user_presence     = true,
		require_user_verification = true,
	}, .None
}

// verify_unlock_assertion decodes canonical wire_assertion bytes, consumes
// principal's single-use challenge on attempt, verifies purpose/protocol/key/
// UP/UV/sign_count/signature via hardware_keys, and advances last_sign_count
// only on success.
verify_unlock_assertion :: proc "contextless" (
	reg: ^Registry,
	principal: u64,
	wire_assertion: []u8,
	verify_sig: hardware_keys.Hardware_Key_Verify_Proc,
	user: rawptr = nil,
) -> (enroll_ref: Enrollment_Refusal, key_ref: hardware_keys.Hardware_Key_Refusal) {
	if reg == nil {
		return .Null_Registry, .None
	}
	tok := find_token(reg, principal)
	if tok == nil {
		return .Not_Enrolled, .None
	}
	if !tok.has_challenge {
		return .No_Pending_Challenge, .None
	}
	challenge := hardware_keys.Hardware_Key_Challenge{
		protocol                  = tok.protocol,
		purpose                   = .Unlock,
		challenge                 = tok.pending_nonce,
		scope                     = UNLOCK_SCOPE,
		require_user_presence     = true,
		require_user_verification = true,
	}
	// Consume single-use challenge before verification so failed attempts
	// cannot replay the same nonce.
	tok.has_challenge = false
	tok.pending_nonce = {}

	assertion, dec_ref := hardware_keys.hardware_key_assertion_decode(wire_assertion)
	if dec_ref != .None {
		return .None, dec_ref
	}
	ver_ref := hardware_keys.hardware_key_assertion_verify(
		&challenge,
		&assertion,
		tok.public_key,
		tok.last_sign_count,
		verify_sig,
		user,
	)
	if ver_ref != .None {
		return .None, ver_ref
	}
	if assertion.sign_count > tok.last_sign_count {
		tok.last_sign_count = assertion.sign_count
	}
	return .None, .None
}
