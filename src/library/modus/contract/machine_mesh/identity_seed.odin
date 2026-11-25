// Machine identity seed derivation, TPM quote qualifying data, and monotonic
// machine-list revocation preparation (src/md/features/several_machines.md,
// "Machine identity" and "A principal across machines").
//
// Each machine derives its Ed25519 identity seed from its TPM-sealed machine
// key through domain-separated BLAKE3 key derivation, binds its identity public
// key and freshness nonce into TPM quote qualifying data, and prepares unsigned
// monotonic revocation updates for offline root signing.
//
// This contract file imports no support or host package and allocates no memory.
package machine_mesh

import "modus:contract/blake3"
import "modus:contract/enum_word"

// Format property: domain separation context string for deriving a machine's
// Ed25519 identity seed from its TPM-sealed machine key
// (src/md/features/several_machines.md, "Machine identity").
MACHINE_IDENTITY_SEED_DOMAIN :: "modus machine identity key"

// Format property: domain separation context string for binding a machine's
// identity public key and freshness nonce into TPM quote qualifying data
// (src/md/features/several_machines.md, "Machine identity").
MACHINE_IDENTITY_QUOTE_DOMAIN :: "modus machine identity quote v1"

// Format property: 256-bit freshness nonce matching blake3.HASH_SIZE.
MACHINE_IDENTITY_QUOTE_NONCE_SIZE :: 32

// Closed set of refusals returned by machine identity seed and quote helpers.
Machine_Identity_Seed_Refusal :: enum u8 {
	None              = 0,
	Zero_Machine_Key  = 1,
	Zero_Identity_Key = 2,
	Zero_Nonce        = 3,
}

// Closed outcome of preparing an unsigned successor machine list that revokes
// one active machine entry for offline root signing.
Machine_Revocation_Status :: enum u8 {
	Prepared                  = 1,
	Refused_Nil_Input         = 2,
	Refused_Invalid_List      = 3,
	Refused_Zero_Machine_Id   = 4,
	Refused_Sequence_Overflow = 5,
	Refused_Machine_Absent    = 6,
	Refused_Already_Revoked   = 7,
	Refused_Bad_Timestamp     = 8,
}

// machine_identity_seed_refusal_of_word is the single border converting a raw
// word into a Machine_Identity_Seed_Refusal member. Unknown values are refused.
machine_identity_seed_refusal_of_word :: proc "contextless" (word: u64) -> (refusal: Machine_Identity_Seed_Refusal, ok: bool) {
	return enum_word.member_of_word(Machine_Identity_Seed_Refusal, word)
}

// machine_revocation_status_of_word is the single border converting a raw word
// into a Machine_Revocation_Status member. Unknown values are refused.
machine_revocation_status_of_word :: proc "contextless" (word: u64) -> (status: Machine_Revocation_Status, ok: bool) {
	return enum_word.member_of_word(Machine_Revocation_Status, word)
}

// derive_machine_identity_seed derives the 32-byte Ed25519 identity seed from
// a TPM-sealed 32-byte machine key using BLAKE3 derive_key mode. Refuses an
// all-zero machine key and erases its local key copy before returning.
derive_machine_identity_seed :: proc "contextless" (machine_key: blake3.Hash) -> (seed: blake3.Hash, refusal: Machine_Identity_Seed_Refusal) {
	key_copy := machine_key
	defer clear_bytes_explicitly(key_copy[:])
	if bytes_all_zero(key_copy[:]) {
		return {}, .Zero_Machine_Key
	}
	return blake3.derive_key(MACHINE_IDENTITY_SEED_DOMAIN, key_copy[:]), .None
}

// machine_identity_quote_qualifying_data computes the canonical 32-byte
// qualifying data digest passed to a TPM quote, binding identity_public_key and
// freshness nonce under MACHINE_IDENTITY_QUOTE_DOMAIN. Refuses an all-zero
// identity key or an all-zero nonce.
machine_identity_quote_qualifying_data :: proc "contextless" (
	identity_public_key: [PUBLIC_KEY_SIZE]u8,
	nonce: [MACHINE_IDENTITY_QUOTE_NONCE_SIZE]u8,
) -> (qualifying: blake3.Hash, refusal: Machine_Identity_Seed_Refusal) {
	if key_is_zero(identity_public_key) {
		return {}, .Zero_Identity_Key
	}
	nonce_copy := nonce
	if bytes_all_zero(nonce_copy[:]) {
		return {}, .Zero_Nonce
	}
	pub_copy := identity_public_key
	payload: [PUBLIC_KEY_SIZE + MACHINE_IDENTITY_QUOTE_NONCE_SIZE]u8
	copy(payload[0:PUBLIC_KEY_SIZE], pub_copy[:])
	copy(payload[PUBLIC_KEY_SIZE:], nonce_copy[:])
	return blake3.derive_key(MACHINE_IDENTITY_QUOTE_DOMAIN, payload[:]), .None
}

// machine_list_prepare_revocation builds an unsigned successor Signed_Machine_List
// with sequence_number + 1 and revoked_machine_id transitioned from Active to
// Revoked at revoked_at_ms, ready for the offline principal root key to sign.
// Any refusal leaves next untouched. Aliasing current == next is safe.
machine_list_prepare_revocation :: proc "contextless" (
	current: ^Signed_Machine_List,
	revoked_machine_id: [PUBLIC_KEY_SIZE]u8,
	revoked_at_ms: u64,
	next: ^Signed_Machine_List,
) -> Machine_Revocation_Status {
	if current == nil || next == nil {
		return .Refused_Nil_Input
	}
	_, structure_status := validate_machine_list_structure(current)
	if structure_status != .Accepted {
		return .Refused_Invalid_List
	}
	if key_is_zero(revoked_machine_id) {
		return .Refused_Zero_Machine_Id
	}
	if current.sequence_number == max(u64) {
		return .Refused_Sequence_Overflow
	}
	if revoked_at_ms == 0 {
		return .Refused_Bad_Timestamp
	}

	found_index := -1
	for index in 0 ..< int(current.entry_count) {
		if keys_equal_constant_time(current.entries[index].machine_id, revoked_machine_id) {
			found_index = index
			break
		}
	}
	if found_index < 0 {
		return .Refused_Machine_Absent
	}
	target := current.entries[found_index]
	if target.state == .Revoked {
		return .Refused_Already_Revoked
	}
	if revoked_at_ms < target.added_at_ms {
		return .Refused_Bad_Timestamp
	}

	updated := current^
	updated.sequence_number = current.sequence_number + 1
	updated.signature = {}
	updated.entries[found_index].state = .Revoked
	updated.entries[found_index].revoked_at_ms = revoked_at_ms
	next^ = updated
	return .Prepared
}
