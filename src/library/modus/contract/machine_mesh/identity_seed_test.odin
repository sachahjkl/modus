#+build !freestanding
package machine_mesh

import "base:runtime"
import "core:crypto/ed25519"
import "core:testing"
import "modus:contract/blake3"

@(private = "file")
seed_test_keypair :: proc(seed_byte: u8) -> (private_key: ed25519.Private_Key, public_bytes: [PUBLIC_KEY_SIZE]u8) {
	seed: [ed25519.PRIVATE_KEY_SIZE]u8
	for index in 0 ..< len(seed) {
		seed[index] = seed_byte + u8(index * 13 + 5)
	}
	ok := ed25519.private_key_set_bytes(&private_key, seed[:])
	assert(ok)
	ed25519.private_key_public_bytes(&private_key, public_bytes[:])
	return private_key, public_bytes
}

@(private = "file")
seed_test_verify_ed25519 :: proc "contextless" (
	public_key: [PUBLIC_KEY_SIZE]u8,
	message: []u8,
	signature: [SIGNATURE_SIZE]u8,
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
seed_test_make_entry :: proc(seed: u8, added_at_ms: u64) -> Machine_Entry {
	_, machine_id := seed_test_keypair(seed)
	_, signing_pub := seed_test_keypair(seed + 1)
	_, transport_pub := seed_test_keypair(seed + 2)
	return Machine_Entry {
		machine_id           = machine_id,
		signing_public_key   = signing_pub,
		transport_public_key = transport_pub,
		uses                 = {.Calls, .View},
		tpm_attested         = true,
		state                = .Active,
		added_at_ms          = added_at_ms,
		revoked_at_ms        = 0,
	}
}

@(private = "file")
seed_test_sign_list :: proc(list: ^Signed_Machine_List, root_priv: ^ed25519.Private_Key) {
	buf: [MAX_MACHINE_LIST_SIGNING_BYTES]u8
	written, status := machine_list_signing_bytes(list, buf[:])
	assert(status == .Accepted)
	ed25519.sign(root_priv, buf[:written], list.signature[:])
}

@(test)
identity_seed_enum_word_borders_refuse_unknown_values :: proc(t: ^testing.T) {
	for member in Machine_Identity_Seed_Refusal {
		got, ok := machine_identity_seed_refusal_of_word(u64(member))
		testing.expect(t, ok)
		testing.expect_value(t, got, member)
	}
	_, bad_ref_1 := machine_identity_seed_refusal_of_word(4)
	_, bad_ref_2 := machine_identity_seed_refusal_of_word(max(u64))
	testing.expect(t, !bad_ref_1)
	testing.expect(t, !bad_ref_2)

	for member in Machine_Revocation_Status {
		got, ok := machine_revocation_status_of_word(u64(member))
		testing.expect(t, ok)
		testing.expect_value(t, got, member)
	}
	_, bad_rev_0 := machine_revocation_status_of_word(0)
	_, bad_rev_9 := machine_revocation_status_of_word(9)
	_, bad_rev_max := machine_revocation_status_of_word(max(u64))
	testing.expect(t, !bad_rev_0)
	testing.expect(t, !bad_rev_9)
	testing.expect(t, !bad_rev_max)
}

@(test)
derive_machine_identity_seed_refuses_zero_and_separates_domains :: proc(t: ^testing.T) {
	zero_key: blake3.Hash
	zero_seed, zero_ref := derive_machine_identity_seed(zero_key)
	testing.expect_value(t, zero_ref, Machine_Identity_Seed_Refusal.Zero_Machine_Key)
	testing.expect(t, bytes_all_zero(zero_seed[:]))

	machine_key := blake3.hash([]u8{'m', 'a', 'c', 'h', 'i', 'n', 'e', '1'})
	seed_a, ref_a := derive_machine_identity_seed(machine_key)
	seed_b, ref_b := derive_machine_identity_seed(machine_key)
	testing.expect_value(t, ref_a, Machine_Identity_Seed_Refusal.None)
	testing.expect_value(t, ref_b, Machine_Identity_Seed_Refusal.None)
	testing.expect(t, seed_a == seed_b)
	testing.expect(t, !bytes_all_zero(seed_a[:]))

	plain_hash := blake3.hash(machine_key[:])
	testing.expect(t, seed_a != plain_hash)

	flipped := machine_key
	flipped[0] ~= 0x01
	seed_flipped, ref_flipped := derive_machine_identity_seed(flipped)
	testing.expect_value(t, ref_flipped, Machine_Identity_Seed_Refusal.None)
	testing.expect(t, seed_flipped != seed_a)
}

@(test)
machine_identity_quote_qualifying_data_refuses_zeros_and_binds_inputs :: proc(t: ^testing.T) {
	_, pub := seed_test_keypair(20)
	nonce := blake3.hash([]u8{'n', 'o', 'n', 'c', 'e', '1'})
	zero_pub: [PUBLIC_KEY_SIZE]u8
	zero_nonce: [MACHINE_IDENTITY_QUOTE_NONCE_SIZE]u8

	q0, r0 := machine_identity_quote_qualifying_data(zero_pub, nonce)
	testing.expect_value(t, r0, Machine_Identity_Seed_Refusal.Zero_Identity_Key)
	testing.expect(t, bytes_all_zero(q0[:]))

	q1, r1 := machine_identity_quote_qualifying_data(pub, zero_nonce)
	testing.expect_value(t, r1, Machine_Identity_Seed_Refusal.Zero_Nonce)
	testing.expect(t, bytes_all_zero(q1[:]))

	q2, r2 := machine_identity_quote_qualifying_data(zero_pub, zero_nonce)
	testing.expect_value(t, r2, Machine_Identity_Seed_Refusal.Zero_Identity_Key)
	testing.expect(t, bytes_all_zero(q2[:]))

	qa, ra := machine_identity_quote_qualifying_data(pub, nonce)
	qb, rb := machine_identity_quote_qualifying_data(pub, nonce)
	testing.expect_value(t, ra, Machine_Identity_Seed_Refusal.None)
	testing.expect_value(t, rb, Machine_Identity_Seed_Refusal.None)
	testing.expect(t, qa == qb)
	testing.expect(t, !bytes_all_zero(qa[:]))

	other_pub := pub
	other_pub[31] ~= 0x80
	qc, rc := machine_identity_quote_qualifying_data(other_pub, nonce)
	testing.expect_value(t, rc, Machine_Identity_Seed_Refusal.None)
	testing.expect(t, qc != qa)

	other_nonce := nonce
	other_nonce[15] ~= 0x04
	qd, rd := machine_identity_quote_qualifying_data(pub, other_nonce)
	testing.expect_value(t, rd, Machine_Identity_Seed_Refusal.None)
	testing.expect(t, qd != qa)
}

@(test)
machine_list_prepare_revocation_refusals_and_monotonic_apply :: proc(t: ^testing.T) {
	root_priv, root_pub := seed_test_keypair(40)
	entry_a := seed_test_make_entry(50, 1000)
	entry_b := seed_test_make_entry(60, 2000)
	_, absent_id := seed_test_keypair(90)
	zero_id: [PUBLIC_KEY_SIZE]u8

	current := Signed_Machine_List {
		principal_root_public_key = root_pub,
		sequence_number           = 1,
		entry_count               = 2,
	}
	current.entries[0] = entry_a
	current.entries[1] = entry_b
	seed_test_sign_list(&current, &root_priv)

	sentinel := Signed_Machine_List{sequence_number = 77}
	out := sentinel

	// Nil inputs.
	testing.expect_value(t, machine_list_prepare_revocation(nil, entry_a.machine_id, 3000, &out), Machine_Revocation_Status.Refused_Nil_Input)
	testing.expect_value(t, machine_list_prepare_revocation(&current, entry_a.machine_id, 3000, nil), Machine_Revocation_Status.Refused_Nil_Input)
	testing.expect_value(t, out.sequence_number, u64(77))

	// Invalid list.
	bad_list := current
	bad_list.entry_count = 0
	testing.expect_value(t, machine_list_prepare_revocation(&bad_list, entry_a.machine_id, 3000, &out), Machine_Revocation_Status.Refused_Invalid_List)
	testing.expect_value(t, out.sequence_number, u64(77))

	// Zero machine id.
	testing.expect_value(t, machine_list_prepare_revocation(&current, zero_id, 3000, &out), Machine_Revocation_Status.Refused_Zero_Machine_Id)
	testing.expect_value(t, out.sequence_number, u64(77))

	// Sequence number overflow at max(u64).
	max_seq := current
	max_seq.sequence_number = max(u64)
	testing.expect_value(t, machine_list_prepare_revocation(&max_seq, entry_a.machine_id, 3000, &out), Machine_Revocation_Status.Refused_Sequence_Overflow)
	testing.expect_value(t, out.sequence_number, u64(77))

	// Zero timestamp or timestamp before added_at_ms.
	testing.expect_value(t, machine_list_prepare_revocation(&current, entry_a.machine_id, 0, &out), Machine_Revocation_Status.Refused_Bad_Timestamp)
	testing.expect_value(t, machine_list_prepare_revocation(&current, entry_a.machine_id, 999, &out), Machine_Revocation_Status.Refused_Bad_Timestamp)
	testing.expect_value(t, out.sequence_number, u64(77))

	// Absent machine id.
	testing.expect_value(t, machine_list_prepare_revocation(&current, absent_id, 3000, &out), Machine_Revocation_Status.Refused_Machine_Absent)
	testing.expect_value(t, out.sequence_number, u64(77))

	// Valid revocation of entry_a at boundary revoked_at_ms == added_at_ms.
	testing.expect_value(t, machine_list_prepare_revocation(&current, entry_a.machine_id, 1000, &out), Machine_Revocation_Status.Prepared)
	testing.expect_value(t, out.sequence_number, u64(2))
	testing.expect(t, bytes_all_zero(out.signature[:]))
	testing.expect_value(t, out.entries[0].state, Machine_Entry_State.Revoked)
	testing.expect_value(t, out.entries[0].revoked_at_ms, u64(1000))
	testing.expect_value(t, out.entries[1].state, Machine_Entry_State.Active)

	// Unsigned successor must be refused until root signs it.
	policy := default_join_policy()
	testing.expect_value(t, machine_list_validate(&current, &out, policy, seed_test_verify_ed25519), Machine_List_Status.Refused_Invalid_Signature)

	// Sign successor with offline root key and apply monotonically.
	seed_test_sign_list(&out, &root_priv)
	state := current
	apply_status := machine_list_apply_update(&state, true, &out, policy, seed_test_verify_ed25519)
	testing.expect_value(t, apply_status, Machine_List_Status.Accepted)
	testing.expect_value(t, state.sequence_number, u64(2))

	_, a_active := machine_list_find_active_by_machine_id(&state, entry_a.machine_id)
	_, b_active := machine_list_find_active_by_machine_id(&state, entry_b.machine_id)
	testing.expect(t, !a_active)
	testing.expect(t, b_active)

	// Re-revoking an already revoked machine is refused without mutating output.
	already_out := sentinel
	testing.expect_value(t, machine_list_prepare_revocation(&state, entry_a.machine_id, 4000, &already_out), Machine_Revocation_Status.Refused_Already_Revoked)
	testing.expect_value(t, already_out.sequence_number, u64(77))

	// In-place aliasing (current == next) works safely when revoking entry_b.
	in_place := state
	testing.expect_value(t, machine_list_prepare_revocation(&in_place, entry_b.machine_id, 5000, &in_place), Machine_Revocation_Status.Prepared)
	testing.expect_value(t, in_place.sequence_number, u64(3))
	testing.expect_value(t, in_place.entries[1].state, Machine_Entry_State.Revoked)
	testing.expect_value(t, in_place.entries[1].revoked_at_ms, u64(5000))
}
