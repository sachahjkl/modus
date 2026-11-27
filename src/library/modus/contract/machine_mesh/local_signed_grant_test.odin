#+build !freestanding
#+build !modus
package machine_mesh

import "core:testing"
import "modus:contract/blake3"
import "modus:contract/principals_rules"

@(private = "file")
local_key_of :: proc(seed: u8) -> (k: [PUBLIC_KEY_SIZE]u8) {
	for &b, idx in k {
		b = seed + u8(idx + 1)
	}
	return k
}

@(private = "file")
local_mock_sign :: proc(public_key: [PUBLIC_KEY_SIZE]u8, payload: []u8) -> (sig: [SIGNATURE_SIZE]u8) {
	pk := public_key
	h1 := blake3.derive_key("local grant test sig 1", payload)
	h2 := blake3.derive_key("local grant test sig 2", pk[:])
	for i in 0 ..< 32 {
		sig[i] = h1[i] ~ h2[i]
		sig[32 + i] = h1[31 - i] ~ h2[i]
	}
	return sig
}

@(private = "file")
local_mock_verify :: proc "contextless" (public_key: [PUBLIC_KEY_SIZE]u8, message: []u8, signature: [SIGNATURE_SIZE]u8, user_data: rawptr) -> bool {
	_ = user_data
	pk := public_key
	expected: [SIGNATURE_SIZE]u8
	h1 := blake3.derive_key("local grant test sig 1", message)
	h2 := blake3.derive_key("local grant test sig 2", pk[:])
	for i in 0 ..< 32 {
		expected[i] = h1[i] ~ h2[i]
		expected[32 + i] = h1[31 - i] ~ h2[i]
	}
	diff: u8
	for i in 0 ..< SIGNATURE_SIZE {
		diff |= expected[i] ~ signature[i]
	}
	return diff == 0
}

// Local signed grants reuse Signed_Grant and signed_grant_check directly:
// principal 0, self-grants, zero machine id, wrong machine id, wrong grantee,
// forged signature, expired lifetime, and revoked serials are all refused.
@(test)
local_signed_grant_enforces_cross_principal_and_signed_grant_rules :: proc(t: ^testing.T) {
	local_machine := local_key_of(0x50)
	other_machine := local_key_of(0x60)

	alice := Local_Principal_Entry {
		slot               = 1,
		root_public_key    = local_key_of(0x10),
		signing_public_key = local_key_of(0x11),
	}
	bob := Local_Principal_Entry {
		slot               = 2,
		root_public_key    = local_key_of(0x20),
		signing_public_key = local_key_of(0x21),
	}

	grant := Signed_Grant {
		grant_serial               = 7,
		grantor_root_public_key    = alice.root_public_key,
		grantor_signing_public_key = alice.signing_public_key,
		serving_machine_id         = local_machine,
		grantee_root_public_key    = bob.root_public_key,
		target_kind                = .Store_Object,
		target_hash                = blake3.hash(transmute([]u8)string("shared-doc")),
		rights                     = {.Read},
		issued_at_ms               = 1_000,
		expires_at_ms              = 1_000 + 60_000,
		revocation_list_epoch      = 0,
	}
	sb, sb_status := signed_grant_signing_bytes(&grant)
	testing.expect_value(t, sb_status, Grant_Check_Status.Accepted)
	grant.signature = local_mock_sign(alice.signing_public_key, sb[:])

	// Refusal 1: principal 0 or out-of-range slot (>= PRINCIPAL_CAPACITY, max(u64)) as grantor or grantee.
	for bad_slot in ([?]u64{0, principals_rules.PRINCIPAL_CAPACITY, max(u64)}) {
		bad_grantor := alice
		bad_grantor.slot = bad_slot
		ref_g, st_g := local_signed_grant_check(&grant, &bad_grantor, &bob, local_machine, 5_000, nil, local_mock_verify)
		testing.expect_value(t, ref_g, Local_Grant_Refusal.Bad_Principal_Slot)
		testing.expect_value(t, st_g, Grant_Check_Status.Refused_Wrong_Grantor)

		bad_grantee := bob
		bad_grantee.slot = bad_slot
		ref_e, st_e := local_signed_grant_check(&grant, &alice, &bad_grantee, local_machine, 5_000, nil, local_mock_verify)
		testing.expect_value(t, ref_e, Local_Grant_Refusal.Bad_Principal_Slot)
		testing.expect_value(t, st_e, Grant_Check_Status.Refused_Wrong_Grantee)
	}
	ref: Local_Grant_Refusal

	// Refusal 2: self-grant (same slot or same root public key).
	ref, _ = local_signed_grant_check(&grant, &alice, &alice, local_machine, 5_000, nil, local_mock_verify)
	testing.expect_value(t, ref, Local_Grant_Refusal.Self_Grant_Refused)
	same_key := bob
	same_key.root_public_key = alice.root_public_key
	ref, _ = local_signed_grant_check(&grant, &alice, &same_key, local_machine, 5_000, nil, local_mock_verify)
	testing.expect_value(t, ref, Local_Grant_Refusal.Self_Grant_Refused)

	// Refusal 3: zero local machine identifier.
	ref, _ = local_signed_grant_check(&grant, &alice, &bob, {}, 5_000, nil, local_mock_verify)
	testing.expect_value(t, ref, Local_Grant_Refusal.Zero_Machine_Id)

	// Refusal 4: grant signed for another machine is refused on this machine.
	st: Grant_Check_Status
	ref, st = local_signed_grant_check(&grant, &alice, &bob, other_machine, 5_000, nil, local_mock_verify)
	testing.expect_value(t, ref, Local_Grant_Refusal.Grant_Check_Failed)
	testing.expect_value(t, st, Grant_Check_Status.Refused_Wrong_Serving_Machine)

	// Refusal 5: forged signature.
	forged := grant
	forged.signature[0] ~= 0x01
	ref, st = local_signed_grant_check(&forged, &alice, &bob, local_machine, 5_000, nil, local_mock_verify)
	testing.expect_value(t, ref, Local_Grant_Refusal.Grant_Check_Failed)
	testing.expect_value(t, st, Grant_Check_Status.Refused_Invalid_Signature)

	// Refusal 6: expired grant.
	ref, st = local_signed_grant_check(&grant, &alice, &bob, local_machine, 61_000, nil, local_mock_verify)
	testing.expect_value(t, ref, Local_Grant_Refusal.Grant_Check_Failed)
	testing.expect_value(t, st, Grant_Check_Status.Refused_Expired)

	// Refusal 7: revoked grant via signed Revocation_List.
	rev := Revocation_List {
		grantor_root_public_key = alice.root_public_key,
		signer_public_key       = alice.signing_public_key,
		epoch                   = 1,
		revoked_count           = 1,
		revoked_serials         = {0 = 7},
	}
	rev_buf: [INLINE_REVOCATION_LIST_SIGNING_BYTES]u8
	rev_len, rev_st := revocation_list_signing_bytes(&rev, rev_buf[:])
	testing.expect_value(t, rev_st, Revocation_List_Status.Accepted)
	rev.signature = local_mock_sign(alice.signing_public_key, rev_buf[:rev_len])
	ref, st = local_signed_grant_check(&grant, &alice, &bob, local_machine, 5_000, &rev, local_mock_verify)
	testing.expect_value(t, ref, Local_Grant_Refusal.Grant_Check_Failed)
	testing.expect_value(t, st, Grant_Check_Status.Refused_Revoked)

	// Accepted cases last: valid local cross-principal share between Alice (slot 1)
	// and Bob (slot 2), plus upper slot bound (PRINCIPAL_CAPACITY - 1).
	ref, st = local_signed_grant_check(&grant, &alice, &bob, local_machine, 5_000, nil, local_mock_verify)
	testing.expect_value(t, ref, Local_Grant_Refusal.None)
	testing.expect_value(t, st, Grant_Check_Status.Accepted)

	bob_max := bob
	bob_max.slot = principals_rules.PRINCIPAL_CAPACITY - 1
	ref, st = local_signed_grant_check(&grant, &alice, &bob_max, local_machine, 5_000, nil, local_mock_verify)
	testing.expect_value(t, ref, Local_Grant_Refusal.None)
	testing.expect_value(t, st, Grant_Check_Status.Accepted)
}
