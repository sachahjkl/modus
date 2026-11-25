#+build !freestanding
package attestation

import "base:runtime"
import "core:testing"
import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/role_contract"
import ed25519 "core:crypto/ed25519"

@(private = "file")
test_hash :: proc(seed: u8) -> blake3.Hash {
	input := [4]u8{seed, seed ~ 0x5A, seed + 19, 0xC3}
	return blake3.hash(input[:])
}

@(private = "file")
test_keypair :: proc(seed_byte: u8) -> (private_key: ed25519.Private_Key, public_bytes: [ed25519.PUBLIC_KEY_SIZE]u8) {
	seed: [ed25519.PRIVATE_KEY_SIZE]u8
	for index in 0 ..< len(seed) {
		seed[index] = seed_byte + u8(index * 13 + 7)
	}
	ok := ed25519.private_key_set_bytes(&private_key, seed[:])
	assert(ok)
	ed25519.private_key_public_bytes(&private_key, public_bytes[:])
	return private_key, public_bytes
}

@(private = "file")
ed25519_verify_callback :: proc "contextless" (
	public_key: [ATTESTATION_PUBLIC_KEY_SIZE]u8,
	message: []u8,
	signature: [ATTESTATION_SIGNATURE_SIZE]u8,
	_: rawptr,
) -> bool {
	context = runtime.default_context()
	pub_copy := public_key
	sig_copy := signature
	parsed: ed25519.Public_Key
	if !ed25519.public_key_set_bytes(&parsed, pub_copy[:]) {
		return false
	}
	return ed25519.verify(&parsed, message, sig_copy[:])
}

@(private = "file")
make_signed_attestation :: proc(
	seed_byte: u8,
	boot_hash: blake3.Hash,
	pcr_digest: blake3.Hash,
	plan_hash: blake3.Hash,
	roles_digest: blake3.Hash,
	nonce: [ATTESTATION_NONCE_SIZE]u8,
) -> Attestation_Payload {
	priv, pub := test_keypair(seed_byte)
	payload := Attestation_Payload {
		version               = ATTESTATION_VERSION,
		boot_description_hash = boot_hash,
		pcr_digest            = pcr_digest,
		active_plan_hash      = plan_hash,
		roles_digest          = roles_digest,
		nonce                 = nonce,
		signer_public_key     = pub,
	}
	signing_buf: [ATTESTATION_SIGNING_BYTES_SIZE]u8
	written, refusal := attestation_signing_bytes(&payload, &signing_buf)
	assert(refusal == .None && written == ATTESTATION_SIGNING_BYTES_SIZE)
	ed25519.sign(&priv, signing_buf[:written], payload.signature[:])
	return payload
}

@(private = "file")
make_signed_plan :: proc(
	priv: ^ed25519.Private_Key,
	pub: [SIGNED_PLAN_PUBLIC_KEY_SIZE]u8,
	machine_id: [SIGNED_PLAN_MACHINE_ID_SIZE]u8,
	generation: u64,
	scope: Plan_Field_Scope,
	plan_hash: blake3.Hash,
) -> Signed_Plan_Envelope {
	envelope := Signed_Plan_Envelope {
		version              = SIGNED_PLAN_VERSION,
		authority_public_key = pub,
		target_machine_id    = machine_id,
		generation           = generation,
		scope_mask           = scope,
		plan_hash            = plan_hash,
	}
	signing_buf: [SIGNED_PLAN_SIGNING_BYTES_SIZE]u8
	written, refusal := signed_plan_signing_bytes(&envelope, &signing_buf)
	assert(refusal == .None && written == SIGNED_PLAN_SIGNING_BYTES_SIZE)
	ed25519.sign(priv, signing_buf[:written], envelope.signature[:])
	return envelope
}

// ============================================================================
// Role measurement tests
// ============================================================================

@(test)
role_measurement_refuses_bad_inputs :: proc(t: ^testing.T) {
	// Empty slice.
	_, empty_ok := measure_role_holders(nil)
	testing.expect(t, !empty_ok)
	_, empty_refusal := measure_role_holders_checked(nil)
	testing.expect_value(t, empty_refusal, Role_Measurement_Refusal.Empty_Holders)

	// One past ROLE_HOLDER_CAPACITY.
	too_many: [ROLE_HOLDER_CAPACITY + 1]Measured_Role_Holder
	for index in 0 ..< len(too_many) {
		too_many[index] = {
			role_word   = u64(role_contract.Role.Display),
			module_name = "compositor",
			module_hash = test_hash(u8(index + 1)),
		}
	}
	_, cap_refusal := measure_role_holders_checked(too_many[:])
	testing.expect_value(t, cap_refusal, Role_Measurement_Refusal.Too_Many_Holders)

	// Unknown roles: 0 (None), one past max, and max(u64).
	unknown_words := [?]u64{0, u64(max(role_contract.Role)) + 1, max(u64)}
	for word in unknown_words {
		bad := [1]Measured_Role_Holder{{role_word = word, module_name = "compositor", module_hash = test_hash(1)}}
		_, ref := measure_role_holders_checked(bad[:])
		testing.expect_value(t, ref, Role_Measurement_Refusal.Unknown_Role)
	}

	// Duplicate roles (even when non-adjacent in input).
	dup := [3]Measured_Role_Holder {
		{role_word = u64(role_contract.Role.Storage), module_name = "storage", module_hash = test_hash(1)},
		{role_word = u64(role_contract.Role.Display), module_name = "compositor", module_hash = test_hash(2)},
		{role_word = u64(role_contract.Role.Storage), module_name = "storage_alt", module_hash = test_hash(3)},
	}
	_, dup_refusal := measure_role_holders_checked(dup[:])
	testing.expect_value(t, dup_refusal, Role_Measurement_Refusal.Duplicate_Role)

	// Empty module name.
	empty_name := [1]Measured_Role_Holder{{role_word = u64(role_contract.Role.Display), module_name = "", module_hash = test_hash(1)}}
	_, empty_name_ref := measure_role_holders_checked(empty_name[:])
	testing.expect_value(t, empty_name_ref, Role_Measurement_Refusal.Empty_Module_Name)

	// Name one byte past ROLE_HOLDER_NAME_LIMIT.
	long_bytes: [ROLE_HOLDER_NAME_LIMIT + 1]u8
	for &b in long_bytes {
		b = 'a'
	}
	long_name := [1]Measured_Role_Holder{{role_word = u64(role_contract.Role.Display), module_name = string(long_bytes[:]), module_hash = test_hash(1)}}
	_, long_ref := measure_role_holders_checked(long_name[:])
	testing.expect_value(t, long_ref, Role_Measurement_Refusal.Module_Name_Too_Long)

	// Disallowed bytes in module name.
	bad_names := [?]string{"bad name", "bad/name", "bad\x00name", "bad\nname"}
	for bad_name in bad_names {
		entry := [1]Measured_Role_Holder{{role_word = u64(role_contract.Role.Display), module_name = bad_name, module_hash = test_hash(1)}}
		_, bad_byte_ref := measure_role_holders_checked(entry[:])
		testing.expect_value(t, bad_byte_ref, Role_Measurement_Refusal.Bad_Module_Name_Byte)
	}

	// Zero module hash.
	zero_hash := [1]Measured_Role_Holder{{role_word = u64(role_contract.Role.Display), module_name = "compositor", module_hash = {}}}
	_, zero_ref := measure_role_holders_checked(zero_hash[:])
	testing.expect_value(t, zero_ref, Role_Measurement_Refusal.Zero_Module_Hash)

	// Border word check for Role_Measurement_Refusal.
	_, ok_zero := role_measurement_refusal_from_word(0)
	testing.expect(t, ok_zero)
	_, ok_max := role_measurement_refusal_from_word(u64(max(Role_Measurement_Refusal)))
	testing.expect(t, ok_max)
	_, ok_past := role_measurement_refusal_from_word(u64(max(Role_Measurement_Refusal)) + 1)
	testing.expect(t, !ok_past)
}

@(test)
role_measurement_is_canonical_and_sensitive :: proc(t: ^testing.T) {
	a := Measured_Role_Holder{role_word = u64(role_contract.Role.Display), module_name = "compositor", module_hash = test_hash(1)}
	b := Measured_Role_Holder{role_word = u64(role_contract.Role.Storage), module_name = "storage", module_hash = test_hash(2)}
	c := Measured_Role_Holder{role_word = u64(role_contract.Role.Settings), module_name = "settings_stand_in", module_hash = test_hash(3)}

	order_1 := [3]Measured_Role_Holder{a, b, c}
	order_2 := [3]Measured_Role_Holder{c, a, b}
	order_3 := [3]Measured_Role_Holder{b, c, a}

	d1, ok1 := measure_role_holders(order_1[:])
	d2, ok2 := measure_role_holders(order_2[:])
	d3, ok3 := measure_role_holders(order_3[:])
	testing.expect(t, ok1 && ok2 && ok3)
	testing.expect(t, !is_zero_bytes(d1[:]))
	testing.expect_value(t, d1, d2)
	testing.expect_value(t, d1, d3)

	// Exact bound: name of length ROLE_HOLDER_NAME_LIMIT succeeds.
	exact_name_bytes: [ROLE_HOLDER_NAME_LIMIT]u8
	for &ch in exact_name_bytes {
		ch = 'm'
	}
	exact := [1]Measured_Role_Holder{{role_word = u64(role_contract.Role.Plans), module_name = string(exact_name_bytes[:]), module_hash = test_hash(9)}}
	_, exact_ok := measure_role_holders(exact[:])
	testing.expect(t, exact_ok)

	// Sensitivity: changing module name or hash changes digest.
	changed_name := order_1
	changed_name[2].module_name = "settings"
	d_name, ok_name := measure_role_holders(changed_name[:])
	testing.expect(t, ok_name)
	testing.expect(t, d_name != d1)

	changed_hash := order_1
	changed_hash[1].module_hash[0] ~= 0x01
	d_hash, ok_hash := measure_role_holders(changed_hash[:])
	testing.expect(t, ok_hash)
	testing.expect(t, d_hash != d1)
}

// ============================================================================
// Remote TPM attestation quote payload tests
// ============================================================================

@(test)
attestation_wire_and_verify_refusals :: proc(t: ^testing.T) {
	boot := test_hash(10)
	pcr := test_hash(11)
	plan := test_hash(12)
	roles := test_hash(13)
	nonce := test_hash(14)

	valid := make_signed_attestation(42, boot, pcr, plan, roles, nonce)
	wire: [ATTESTATION_PAYLOAD_WIRE_SIZE]u8
	written, enc_ref := attestation_encode(&valid, wire[:])
	testing.expect_value(t, enc_ref, Attestation_Refusal.None)
	testing.expect_value(t, written, ATTESTATION_PAYLOAD_WIRE_SIZE)

	// Encode refuses short destination without writing to it.
	short_dst: [ATTESTATION_PAYLOAD_WIRE_SIZE - 1]u8
	for &b in short_dst {
		b = 0xAA
	}
	short_written, short_ref := attestation_encode(&valid, short_dst[:])
	testing.expect_value(t, short_ref, Attestation_Refusal.Bad_Wire_Length)
	testing.expect_value(t, short_written, 0)
	testing.expect_value(t, short_dst[0], u8(0xAA))

	// Decode refuses truncated and trailing buffers.
	_, dec_short := attestation_decode(wire[:ATTESTATION_PAYLOAD_WIRE_SIZE - 1])
	testing.expect_value(t, dec_short, Attestation_Refusal.Bad_Wire_Length)
	longer: [ATTESTATION_PAYLOAD_WIRE_SIZE + 1]u8
	copy(longer[:ATTESTATION_PAYLOAD_WIRE_SIZE], wire[:])
	_, dec_long := attestation_decode(longer[:])
	testing.expect_value(t, dec_long, Attestation_Refusal.Bad_Wire_Length)

	// Decode refuses bad magic, bad version, and nonzero reserved word.
	bad_magic := wire
	bad_magic[7] ~= 0x01
	_, ref_magic := attestation_decode(bad_magic[:])
	testing.expect_value(t, ref_magic, Attestation_Refusal.Bad_Magic)

	bad_ver := wire
	byte_order.write_u32_little_endian(bad_ver[:], 8, 2)
	_, ref_ver := attestation_decode(bad_ver[:])
	testing.expect_value(t, ref_ver, Attestation_Refusal.Unsupported_Version)

	bad_res := wire
	byte_order.write_u32_little_endian(bad_res[:], 12, 1)
	_, ref_res := attestation_decode(bad_res[:])
	testing.expect_value(t, ref_res, Attestation_Refusal.Nonzero_Reserved)

	trusted_signer := valid.signer_public_key

	// Verifier refuses nil callback.
	testing.expect_value(t, attestation_verify(&valid, trusted_signer, nonce, boot, plan, roles, nil), Attestation_Refusal.Missing_Verifier)

	// Verifier refuses zero expected or payload mandatory fields.
	zero_hash: blake3.Hash
	zero_signer: [ATTESTATION_PUBLIC_KEY_SIZE]u8
	testing.expect_value(t, attestation_verify(&valid, zero_signer, nonce, boot, plan, roles, ed25519_verify_callback), Attestation_Refusal.Zero_Signer_Key)
	testing.expect_value(t, attestation_verify(&valid, trusted_signer, zero_hash, boot, plan, roles, ed25519_verify_callback), Attestation_Refusal.Zero_Nonce)
	testing.expect_value(t, attestation_verify(&valid, trusted_signer, nonce, zero_hash, plan, roles, ed25519_verify_callback), Attestation_Refusal.Zero_Boot_Hash)
	testing.expect_value(t, attestation_verify(&valid, trusted_signer, nonce, boot, plan, zero_hash, ed25519_verify_callback), Attestation_Refusal.Zero_Roles_Digest)

	no_pcr := valid
	no_pcr.pcr_digest = {}
	testing.expect_value(t, attestation_verify(&no_pcr, trusted_signer, nonce, boot, plan, roles, ed25519_verify_callback), Attestation_Refusal.Zero_Pcr_Digest)

	no_signer := valid
	no_signer.signer_public_key = {}
	testing.expect_value(t, attestation_verify(&no_signer, trusted_signer, nonce, boot, plan, roles, ed25519_verify_callback), Attestation_Refusal.Zero_Signer_Key)

	no_sig := valid
	no_sig.signature = {}
	testing.expect_value(t, attestation_verify(&no_sig, trusted_signer, nonce, boot, plan, roles, ed25519_verify_callback), Attestation_Refusal.Zero_Signature)

	// Self-signed quote produced by an untrusted attacker keypair is refused.
	untrusted_self_signed := make_signed_attestation(99, boot, pcr, plan, roles, nonce)
	testing.expect_value(t, attestation_verify(&untrusted_self_signed, trusted_signer, nonce, boot, plan, roles, ed25519_verify_callback), Attestation_Refusal.Signer_Key_Mismatch)

	// Verifier refuses field mismatches.
	other := test_hash(99)
	testing.expect_value(t, attestation_verify(&valid, trusted_signer, other, boot, plan, roles, ed25519_verify_callback), Attestation_Refusal.Nonce_Mismatch)
	testing.expect_value(t, attestation_verify(&valid, trusted_signer, nonce, other, plan, roles, ed25519_verify_callback), Attestation_Refusal.Boot_Hash_Mismatch)
	testing.expect_value(t, attestation_verify(&valid, trusted_signer, nonce, boot, other, roles, ed25519_verify_callback), Attestation_Refusal.Plan_Hash_Mismatch)
	testing.expect_value(t, attestation_verify(&valid, trusted_signer, nonce, boot, plan, other, ed25519_verify_callback), Attestation_Refusal.Roles_Digest_Mismatch)

	// Tampered PCR digest or tampered signature fails signature verification.
	tampered_pcr := valid
	tampered_pcr.pcr_digest[0] ~= 0xFF
	testing.expect_value(t, attestation_verify(&tampered_pcr, trusted_signer, nonce, boot, plan, roles, ed25519_verify_callback), Attestation_Refusal.Bad_Signature)

	tampered_sig := valid
	tampered_sig.signature[0] ~= 0x01
	testing.expect_value(t, attestation_verify(&tampered_sig, trusted_signer, nonce, boot, plan, roles, ed25519_verify_callback), Attestation_Refusal.Bad_Signature)

	// Border word check for Attestation_Refusal.
	_, ok_max := attestation_refusal_from_word(u64(max(Attestation_Refusal)))
	testing.expect(t, ok_max)
	_, ok_past := attestation_refusal_from_word(u64(max(Attestation_Refusal)) + 1)
	testing.expect(t, !ok_past)
}

@(test)
attestation_round_trip_and_verify_succeed :: proc(t: ^testing.T) {
	holders := [2]Measured_Role_Holder {
		{role_word = u64(role_contract.Role.Display), module_name = "compositor", module_hash = test_hash(20)},
		{role_word = u64(role_contract.Role.Storage), module_name = "storage", module_hash = test_hash(21)},
	}
	roles_digest, roles_ok := measure_role_holders(holders[:])
	testing.expect(t, roles_ok)

	boot := test_hash(30)
	pcr := test_hash(31)
	plan := test_hash(32)
	nonce := test_hash(33)

	payload := make_signed_attestation(7, boot, pcr, plan, roles_digest, nonce)
	wire: [ATTESTATION_PAYLOAD_WIRE_SIZE]u8
	written, enc_ref := attestation_encode(&payload, wire[:])
	testing.expect_value(t, enc_ref, Attestation_Refusal.None)
	testing.expect_value(t, written, ATTESTATION_PAYLOAD_WIRE_SIZE)

	decoded, dec_ref := attestation_decode(wire[:])
	testing.expect_value(t, dec_ref, Attestation_Refusal.None)
	testing.expect_value(t, decoded, payload)
	testing.expect_value(t, attestation_verify(&decoded, payload.signer_public_key, nonce, boot, plan, roles_digest, ed25519_verify_callback), Attestation_Refusal.None)

	// A machine with no stored plan carries zero active_plan_hash and verifies when expected_plan_hash is also zero.
	no_plan_hash: blake3.Hash
	no_plan_payload := make_signed_attestation(8, boot, pcr, no_plan_hash, roles_digest, nonce)
	testing.expect_value(t, attestation_verify(&no_plan_payload, no_plan_payload.signer_public_key, nonce, boot, no_plan_hash, roles_digest, ed25519_verify_callback), Attestation_Refusal.None)
	testing.expect_value(t, attestation_verify(&no_plan_payload, no_plan_payload.signer_public_key, nonce, boot, plan, roles_digest, ed25519_verify_callback), Attestation_Refusal.Plan_Hash_Mismatch)
}

// ============================================================================
// Signed plan envelope tests
// ============================================================================

@(test)
signed_plan_refuses_all_bad_edges :: proc(t: ^testing.T) {
	priv_org, pub_org := test_keypair(50)
	priv_other, pub_other := test_keypair(51)
	machine_a := test_hash(60)
	machine_b := test_hash(61)
	plan_hash := test_hash(62)
	allowed := Plan_Field_Scope{.Role_Holders, .Plan_Values, .Signer_Policy}
	authority := Enrolled_Authority {
		public_key    = pub_org,
		machine_id    = machine_a,
		allowed_scope = allowed,
	}

	valid := make_signed_plan(&priv_org, pub_org, machine_a, 2, {.Role_Holders, .Plan_Values}, plan_hash)

	// Missing verifier.
	testing.expect_value(t, signed_plan_verify(&authority, &valid, 1, {.Role_Holders}, nil), Signed_Plan_Refusal.Missing_Verifier)

	// Wrong version.
	bad_ver := valid
	bad_ver.version = 0
	testing.expect_value(t, signed_plan_verify(&authority, &bad_ver, 1, {.Role_Holders}, ed25519_verify_callback), Signed_Plan_Refusal.Unsupported_Version)
	bad_ver.version = 2
	testing.expect_value(t, signed_plan_verify(&authority, &bad_ver, 1, {.Role_Holders}, ed25519_verify_callback), Signed_Plan_Refusal.Unsupported_Version)

	// Zero authority key, machine id, plan hash, signature, and generation.
	zero_auth := authority
	zero_auth.public_key = {}
	testing.expect_value(t, signed_plan_verify(&zero_auth, &valid, 1, {.Role_Holders}, ed25519_verify_callback), Signed_Plan_Refusal.Zero_Authority_Key)

	zero_env_key := valid
	zero_env_key.authority_public_key = {}
	testing.expect_value(t, signed_plan_verify(&authority, &zero_env_key, 1, {.Role_Holders}, ed25519_verify_callback), Signed_Plan_Refusal.Zero_Authority_Key)

	zero_machine := valid
	zero_machine.target_machine_id = {}
	testing.expect_value(t, signed_plan_verify(&authority, &zero_machine, 1, {.Role_Holders}, ed25519_verify_callback), Signed_Plan_Refusal.Zero_Machine_Id)

	zero_hash := valid
	zero_hash.plan_hash = {}
	testing.expect_value(t, signed_plan_verify(&authority, &zero_hash, 1, {.Role_Holders}, ed25519_verify_callback), Signed_Plan_Refusal.Zero_Plan_Hash)

	zero_sig := valid
	zero_sig.signature = {}
	testing.expect_value(t, signed_plan_verify(&authority, &zero_sig, 1, {.Role_Holders}, ed25519_verify_callback), Signed_Plan_Refusal.Zero_Signature)

	zero_gen := valid
	zero_gen.generation = 0
	testing.expect_value(t, signed_plan_verify(&authority, &zero_gen, 0, {.Role_Holders}, ed25519_verify_callback), Signed_Plan_Refusal.Zero_Generation)

	// Stale and replayed generations (equal and lower than current).
	testing.expect_value(t, signed_plan_verify(&authority, &valid, 2, {.Role_Holders}, ed25519_verify_callback), Signed_Plan_Refusal.Stale_Generation)
	testing.expect_value(t, signed_plan_verify(&authority, &valid, 5, {.Role_Holders}, ed25519_verify_callback), Signed_Plan_Refusal.Stale_Generation)

	// Empty scopes.
	testing.expect_value(t, signed_plan_verify(&authority, &valid, 1, {}, ed25519_verify_callback), Signed_Plan_Refusal.Empty_Scope)
	empty_auth := authority
	empty_auth.allowed_scope = {}
	testing.expect_value(t, signed_plan_verify(&empty_auth, &valid, 1, {.Role_Holders}, ed25519_verify_callback), Signed_Plan_Refusal.Empty_Scope)

	// Unknown scope bits refused at border and in verify.
	_, bit6_ok := plan_field_scope_from_word(u64(1) << 6)
	testing.expect(t, !bit6_ok)
	_, high_ok := plan_field_scope_from_word(max(u64))
	testing.expect(t, !high_ok)
	unknown_bits := u64(1) << 6
	unknown_scope := transmute(Plan_Field_Scope)unknown_bits
	testing.expect_value(t, signed_plan_verify(&authority, &valid, 1, unknown_scope, ed25519_verify_callback), Signed_Plan_Refusal.Unknown_Scope_Bits)

	// Out-of-scope field: envelope exceeds enrolled authority scope.
	over_scoped := make_signed_plan(&priv_org, pub_org, machine_a, 3, {.Role_Holders, .Start_Policy}, plan_hash)
	testing.expect_value(t, signed_plan_verify(&authority, &over_scoped, 1, {.Role_Holders}, ed25519_verify_callback), Signed_Plan_Refusal.Scope_Exceeded)

	// Out-of-scope field: requested_scope exceeds envelope's signed scope_mask.
	testing.expect_value(t, signed_plan_verify(&authority, &valid, 1, {.Signer_Policy}, ed25519_verify_callback), Signed_Plan_Refusal.Scope_Exceeded)

	// Unauthorized signer (signed by a different key).
	wrong_signer := make_signed_plan(&priv_other, pub_other, machine_a, 3, {.Role_Holders}, plan_hash)
	testing.expect_value(t, signed_plan_verify(&authority, &wrong_signer, 1, {.Role_Holders}, ed25519_verify_callback), Signed_Plan_Refusal.Unauthorized_Signer)

	// Target machine mismatch (signed for machine_b, presented to machine_a).
	wrong_machine := make_signed_plan(&priv_org, pub_org, machine_b, 3, {.Role_Holders}, plan_hash)
	testing.expect_value(t, signed_plan_verify(&authority, &wrong_machine, 1, {.Role_Holders}, ed25519_verify_callback), Signed_Plan_Refusal.Machine_Mismatch)

	// Tampered fields after signing fail Ed25519 verification.
	tampered_plan := valid
	tampered_plan.plan_hash[0] ~= 0x01
	testing.expect_value(t, signed_plan_verify(&authority, &tampered_plan, 1, {.Role_Holders}, ed25519_verify_callback), Signed_Plan_Refusal.Bad_Signature)

	tampered_gen := valid
	tampered_gen.generation = 99
	testing.expect_value(t, signed_plan_verify(&authority, &tampered_gen, 1, {.Role_Holders}, ed25519_verify_callback), Signed_Plan_Refusal.Bad_Signature)

	// Border word check for Signed_Plan_Refusal.
	_, ref_max_ok := signed_plan_refusal_from_word(u64(max(Signed_Plan_Refusal)))
	testing.expect(t, ref_max_ok)
	_, ref_past_ok := signed_plan_refusal_from_word(u64(max(Signed_Plan_Refusal)) + 1)
	testing.expect(t, !ref_past_ok)
}

@(test)
signed_plan_round_trip_succeeds :: proc(t: ^testing.T) {
	priv, pub := test_keypair(77)
	machine_id := test_hash(88)
	plan_hash := test_hash(89)
	authority := Enrolled_Authority {
		public_key    = pub,
		machine_id    = machine_id,
		allowed_scope = {.Role_Holders, .Plan_Values, .Signer_Policy, .Grant_Caps},
	}

	// First generation (1 over current 0) with exact scope.
	env_1 := make_signed_plan(&priv, pub, machine_id, 1, {.Role_Holders, .Plan_Values}, plan_hash)
	testing.expect_value(t, signed_plan_verify(&authority, &env_1, 0, {.Role_Holders, .Plan_Values}, ed25519_verify_callback), Signed_Plan_Refusal.None)

	// Subsequent generation (5 over current 1) with strict subset requested_scope.
	env_5 := make_signed_plan(&priv, pub, machine_id, 5, {.Role_Holders, .Plan_Values, .Grant_Caps}, test_hash(90))
	testing.expect_value(t, signed_plan_verify(&authority, &env_5, 1, {.Grant_Caps}, ed25519_verify_callback), Signed_Plan_Refusal.None)

	// Scope transport word round-trip for ALL_PLAN_FIELDS.
	all_word := plan_field_scope_to_word(ALL_PLAN_FIELDS)
	decoded_scope, decoded_ok := plan_field_scope_from_word(all_word)
	testing.expect(t, decoded_ok)
	testing.expect_value(t, decoded_scope, ALL_PLAN_FIELDS)
}
