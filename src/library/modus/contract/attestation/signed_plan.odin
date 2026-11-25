// Signed plans from an enrolled organization authority key
// (src/md/features/attestation.md).
//
// Principal 0 enrolls one organization Ed25519 public key bound to a target
// machine identifier and a closed Plan_Field_Scope mask. Remote fleet updates
// carry a Signed_Plan_Envelope that is accepted only when the signer matches
// the enrolled key, the target machine matches, generation strictly advances,
// every requested field stays inside both the enrolled mask and the signed
// envelope mask, and the Ed25519 signature verifies over the canonical
// domain-separated signing bytes.
package attestation

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/enum_word"

// Format property: domain separation prefix prepended to signed plan bytes.
SIGNED_PLAN_DOMAIN :: "modus signed plan v1"

// Format property: canonical envelope format version.
SIGNED_PLAN_VERSION :: u32(1)

// Format property: byte length of an Ed25519 authority public key.
SIGNED_PLAN_PUBLIC_KEY_SIZE :: 32

// Format property: byte length of an Ed25519 signature over a plan envelope.
SIGNED_PLAN_SIGNATURE_SIZE :: 64

// Format property: byte length of a target machine identity digest.
SIGNED_PLAN_MACHINE_ID_SIZE :: 32

// Format property: exact byte length of the domain-separated signing message
// (domain + u32 version + 32-byte key + 32-byte machine id + u64 generation + u64 scope + 32-byte plan hash).
SIGNED_PLAN_SIGNING_BYTES_SIZE :: len(SIGNED_PLAN_DOMAIN) + 4 + SIGNED_PLAN_PUBLIC_KEY_SIZE + SIGNED_PLAN_MACHINE_ID_SIZE + 8 + 8 + blake3.HASH_SIZE

// Closed set of plan fields that an enrolled authority can be scoped to manage.
Plan_Field_Kind :: enum u8 {
	Role_Holders  = 0, // Role-to-module overrides for the machine.
	Plan_Values   = 1, // Service parameter values, retention, and quotas.
	Signer_Policy = 2, // Allowed object-cache publisher keys.
	Grant_Caps    = 3, // Session grant ceilings and network/store limits.
	Script_Fonts  = 4, // Pinned script font set hash.
	Start_Policy  = 5, // Selected start policy hash.
}

// Bit set of plan fields carried by an Enrolled_Authority or Signed_Plan_Envelope.
Plan_Field_Scope :: bit_set[Plan_Field_Kind;u64]

// Mask of every defined Plan_Field_Kind bit; bits outside this mask are refused at the border.
ALL_PLAN_FIELDS :: Plan_Field_Scope{.Role_Holders, .Plan_Values, .Signer_Policy, .Grant_Caps, .Script_Fonts, .Start_Policy}

// Closed set of refusal reasons for signed plan validation and verification.
Signed_Plan_Refusal :: enum u8 {
	None                = 0,
	Unsupported_Version = 1,
	Zero_Authority_Key  = 2,
	Zero_Machine_Id     = 3,
	Zero_Plan_Hash      = 4,
	Zero_Signature      = 5,
	Zero_Generation     = 6,
	Stale_Generation    = 7,
	Empty_Scope         = 8,
	Unknown_Scope_Bits  = 9,
	Scope_Exceeded      = 10,
	Unauthorized_Signer = 11,
	Machine_Mismatch    = 12,
	Missing_Verifier    = 13,
	Bad_Signature       = 14,
}

// signed_plan_refusal_from_word converts a transport word into a
// Signed_Plan_Refusal at the border, refusing any unknown value.
signed_plan_refusal_from_word :: proc "contextless" (word: u64) -> (refusal: Signed_Plan_Refusal, ok: bool) {
	return enum_word.member_of_word(Signed_Plan_Refusal, word)
}

// plan_field_scope_to_word returns the canonical u64 transport word of scope.
plan_field_scope_to_word :: proc "contextless" (scope: Plan_Field_Scope) -> u64 {
	return transmute(u64)scope
}

// plan_field_scope_from_word converts a transport word into a Plan_Field_Scope
// at the border, refusing any unknown bit outside ALL_PLAN_FIELDS.
plan_field_scope_from_word :: proc "contextless" (word: u64) -> (scope: Plan_Field_Scope, ok: bool) {
	all_fields := ALL_PLAN_FIELDS
	allowed_bits := transmute(u64)all_fields
	if (word & ~allowed_bits) != 0 {
		return {}, false
	}
	return transmute(Plan_Field_Scope)word, true
}

// Organization authority enrolled once by principal 0 at provisioning.
Enrolled_Authority :: struct {
	public_key:    [SIGNED_PLAN_PUBLIC_KEY_SIZE]u8,
	machine_id:    [SIGNED_PLAN_MACHINE_ID_SIZE]u8,
	allowed_scope: Plan_Field_Scope,
}

// Signed plan update envelope delivered by a fleet administration tool.
Signed_Plan_Envelope :: struct {
	version:              u32,
	authority_public_key: [SIGNED_PLAN_PUBLIC_KEY_SIZE]u8,
	target_machine_id:    [SIGNED_PLAN_MACHINE_ID_SIZE]u8,
	generation:           u64,
	scope_mask:           Plan_Field_Scope,
	plan_hash:            blake3.Hash,
	signature:            [SIGNED_PLAN_SIGNATURE_SIZE]u8,
}

// Callback supplied by callers to verify an Ed25519 signature over a signed plan.
Signed_Plan_Signature_Verify_Proc :: #type proc "contextless" (
	public_key: [SIGNED_PLAN_PUBLIC_KEY_SIZE]u8,
	message: []u8,
	signature: [SIGNED_PLAN_SIGNATURE_SIZE]u8,
	user: rawptr,
) -> bool

// scope_check validates that scope has no unknown bits and is non-empty.
@(private = "file")
scope_check :: proc "contextless" (scope: Plan_Field_Scope) -> Signed_Plan_Refusal {
	word := plan_field_scope_to_word(scope)
	if _, ok := plan_field_scope_from_word(word); !ok {
		return .Unknown_Scope_Bits
	}
	if scope == {} {
		return .Empty_Scope
	}
	return .None
}

// signed_plan_signing_bytes writes the canonical domain-separated byte
// sequence signed by the enrolled Ed25519 authority key.
signed_plan_signing_bytes :: proc "contextless" (
	envelope: ^Signed_Plan_Envelope,
	out: ^[SIGNED_PLAN_SIGNING_BYTES_SIZE]u8,
) -> (written: int, refusal: Signed_Plan_Refusal) {
	if envelope == nil || out == nil {
		return 0, .Unsupported_Version
	}
	if envelope.version != SIGNED_PLAN_VERSION {
		return 0, .Unsupported_Version
	}
	key := envelope.authority_public_key
	if is_zero_bytes(key[:]) {
		return 0, .Zero_Authority_Key
	}
	machine_id := envelope.target_machine_id
	if is_zero_bytes(machine_id[:]) {
		return 0, .Zero_Machine_Id
	}
	if envelope.generation == 0 {
		return 0, .Zero_Generation
	}
	if scope_refusal := scope_check(envelope.scope_mask); scope_refusal != .None {
		return 0, scope_refusal
	}
	plan_hash := envelope.plan_hash
	if is_zero_bytes(plan_hash[:]) {
		return 0, .Zero_Plan_Hash
	}

	offset := 0
	copy(out[offset:][:len(SIGNED_PLAN_DOMAIN)], SIGNED_PLAN_DOMAIN)
	offset += len(SIGNED_PLAN_DOMAIN)
	byte_order.write_u32_little_endian(out[:], offset, envelope.version)
	offset += 4
	copy(out[offset:][:SIGNED_PLAN_PUBLIC_KEY_SIZE], envelope.authority_public_key[:])
	offset += SIGNED_PLAN_PUBLIC_KEY_SIZE
	copy(out[offset:][:SIGNED_PLAN_MACHINE_ID_SIZE], envelope.target_machine_id[:])
	offset += SIGNED_PLAN_MACHINE_ID_SIZE
	byte_order.write_u64_little_endian(out[:], offset, envelope.generation)
	offset += 8
	byte_order.write_u64_little_endian(out[:], offset, plan_field_scope_to_word(envelope.scope_mask))
	offset += 8
	copy(out[offset:][:blake3.HASH_SIZE], envelope.plan_hash[:])
	offset += blake3.HASH_SIZE
	return offset, .None
}

// signed_plan_verify checks that envelope is authorized by authority, targets
// the enrolled machine, strictly advances current_generation, keeps both its
// declared scope and requested_scope within authority.allowed_scope, and
// carries a valid Ed25519 signature.
signed_plan_verify :: proc "contextless" (
	authority: ^Enrolled_Authority,
	envelope: ^Signed_Plan_Envelope,
	current_generation: u64,
	requested_scope: Plan_Field_Scope,
	verify_sig: Signed_Plan_Signature_Verify_Proc,
	user: rawptr = nil,
) -> Signed_Plan_Refusal {
	if verify_sig == nil {
		return .Missing_Verifier
	}
	if authority == nil || envelope == nil {
		return .Unsupported_Version
	}
	if envelope.version != SIGNED_PLAN_VERSION {
		return .Unsupported_Version
	}
	enrolled_key := authority.public_key
	if is_zero_bytes(enrolled_key[:]) {
		return .Zero_Authority_Key
	}
	envelope_key := envelope.authority_public_key
	if is_zero_bytes(envelope_key[:]) {
		return .Zero_Authority_Key
	}
	enrolled_machine := authority.machine_id
	if is_zero_bytes(enrolled_machine[:]) {
		return .Zero_Machine_Id
	}
	envelope_machine := envelope.target_machine_id
	if is_zero_bytes(envelope_machine[:]) {
		return .Zero_Machine_Id
	}
	plan_hash := envelope.plan_hash
	if is_zero_bytes(plan_hash[:]) {
		return .Zero_Plan_Hash
	}
	sig := envelope.signature
	if is_zero_bytes(sig[:]) {
		return .Zero_Signature
	}
	if envelope.generation == 0 {
		return .Zero_Generation
	}
	if scope_refusal := scope_check(authority.allowed_scope); scope_refusal != .None {
		return scope_refusal
	}
	if scope_refusal := scope_check(envelope.scope_mask); scope_refusal != .None {
		return scope_refusal
	}
	if scope_refusal := scope_check(requested_scope); scope_refusal != .None {
		return scope_refusal
	}

	if !constant_time_equal(enrolled_key[:], envelope_key[:]) {
		return .Unauthorized_Signer
	}
	if !constant_time_equal(enrolled_machine[:], envelope_machine[:]) {
		return .Machine_Mismatch
	}
	if envelope.generation <= current_generation {
		return .Stale_Generation
	}
	if (envelope.scope_mask - authority.allowed_scope) != {} {
		return .Scope_Exceeded
	}
	if (requested_scope - envelope.scope_mask) != {} {
		return .Scope_Exceeded
	}

	signing_buf: [SIGNED_PLAN_SIGNING_BYTES_SIZE]u8
	written, build_refusal := signed_plan_signing_bytes(envelope, &signing_buf)
	if build_refusal != .None {
		return build_refusal
	}
	if !verify_sig(authority.public_key, signing_buf[:written], envelope.signature, user) {
		return .Bad_Signature
	}
	return .None
}
