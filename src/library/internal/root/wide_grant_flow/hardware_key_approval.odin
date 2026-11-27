// Hardware security key consent proof verification for wide-grant approval
// in root (src/md/features/hardware_keys.md; src/md/features/wide_grants.md).
//
// Verifies canonical "MODHWK01" hardware-key assertions bound strictly to
// Hardware_Key_Purpose.Approve_Wide_Grant, "modus.wide_grant" scope, User
// Presence and User Verification, single-use challenge consumption, and
// per-principal monotonic sign counters without heap allocation.
package wide_grant_flow

import "modus:contract/hardware_keys"

// Format property: canonical scope string bound to every wide-grant approval.
WIDE_GRANT_HARDWARE_SCOPE :: "modus.wide_grant"

// Plan value: tracks enrolled hardware keys per principal up to PRINCIPALS_MOST.
Wide_Grant_Key_Slot :: struct {
	enrolled:        bool,
	protocol:        hardware_keys.Hardware_Key_Protocol,
	public_key:      [hardware_keys.HARDWARE_KEY_PUBLIC_KEY_SIZE]u8,
	last_sign_count: u32,
	has_challenge:   bool,
	pending_nonce:   [hardware_keys.HARDWARE_KEY_CHALLENGE_SIZE]u8,
}

// Per-principal hardware-key approval table owned by root's wide_grant_authority.
Wide_Grant_Hardware_Keys :: struct {
	principals: [PRINCIPALS_MOST]Wide_Grant_Key_Slot,
}

// hardware_key_enroll binds an unenrolled principal slot to one hardware token
// for wide-grant approval. Re-enrolling an already-enrolled slot is refused so
// the monotonic sign_count cannot be rolled back.
hardware_key_enroll :: proc "contextless" (
	table: ^Wide_Grant_Hardware_Keys,
	principal: u64,
	protocol: hardware_keys.Hardware_Key_Protocol,
	public_key: [hardware_keys.HARDWARE_KEY_PUBLIC_KEY_SIZE]u8,
) -> hardware_keys.Hardware_Key_Refusal {
	if table == nil || principal >= PRINCIPALS_MOST {
		return .Bad_Wire_Length
	}
	if table.principals[principal].enrolled {
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
	table.principals[principal] = {
		enrolled   = true,
		protocol   = protocol,
		public_key = public_key,
	}
	return .None
}

// hardware_key_challenge_begin stores a fresh single-use 32-byte nonce for a
// pending wide-grant approval by principal.
hardware_key_challenge_begin :: proc "contextless" (
	table: ^Wide_Grant_Hardware_Keys,
	principal: u64,
	nonce: [hardware_keys.HARDWARE_KEY_CHALLENGE_SIZE]u8,
) -> (challenge: hardware_keys.Hardware_Key_Challenge, refusal: hardware_keys.Hardware_Key_Refusal) {
	if table == nil || principal >= PRINCIPALS_MOST {
		return {}, .Bad_Wire_Length
	}
	acc: u8
	for b in nonce {
		acc |= b
	}
	if acc == 0 {
		return {}, .Zero_Challenge
	}
	slot := &table.principals[principal]
	if !slot.enrolled {
		return {}, .Zero_Public_Key
	}
	slot.pending_nonce = nonce
	slot.has_challenge = true
	return hardware_keys.Hardware_Key_Challenge{
		protocol                  = slot.protocol,
		purpose                   = .Approve_Wide_Grant,
		challenge                 = nonce,
		scope                     = WIDE_GRANT_HARDWARE_SCOPE,
		require_user_presence     = true,
		require_user_verification = true,
	}, .None
}

// hardware_key_approve_verify consumes principal's pending challenge and
// verifies canonical wire_assertion bytes for .Approve_Wide_Grant with UP+UV.
hardware_key_approve_verify :: proc "contextless" (
	table: ^Wide_Grant_Hardware_Keys,
	principal: u64,
	wire_assertion: []u8,
	verify_sig: hardware_keys.Hardware_Key_Verify_Proc,
	user: rawptr = nil,
) -> hardware_keys.Hardware_Key_Refusal {
	if table == nil || principal >= PRINCIPALS_MOST {
		return .Bad_Wire_Length
	}
	slot := &table.principals[principal]
	if !slot.enrolled {
		return .Zero_Public_Key
	}
	if !slot.has_challenge {
		return .Zero_Challenge
	}
	challenge := hardware_keys.Hardware_Key_Challenge{
		protocol                  = slot.protocol,
		purpose                   = .Approve_Wide_Grant,
		challenge                 = slot.pending_nonce,
		scope                     = WIDE_GRANT_HARDWARE_SCOPE,
		require_user_presence     = true,
		require_user_verification = true,
	}
	slot.has_challenge = false
	slot.pending_nonce = {}

	assertion, dec_ref := hardware_keys.hardware_key_assertion_decode(wire_assertion)
	if dec_ref != .None {
		return dec_ref
	}
	ver_ref := hardware_keys.hardware_key_assertion_verify(
		&challenge,
		&assertion,
		slot.public_key,
		slot.last_sign_count,
		verify_sig,
		user,
	)
	if ver_ref != .None {
		return ver_ref
	}
	if assertion.sign_count > slot.last_sign_count {
		slot.last_sign_count = assertion.sign_count
	}
	return .None
}
