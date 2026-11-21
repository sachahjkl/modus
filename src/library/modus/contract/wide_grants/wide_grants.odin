// Wide-authority grant and hash-chained act record contract
// (src/md/features/wide_grants.md; src/md/features/module_outputs.md).
//
// Defines the closed enums, fixed-layout grant terms, proof binding records,
// domain-separated BLAKE3 hash-chained act records, strict border validators,
// chain verifier, and sensitive-action guard for wide grants.
//
// This is a contract package: it imports base and contract packages only,
// calls no kernel operation, and allocates no memory.
package wide_grants

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/enum_word"

// Maximum explicit target window identifiers bound to a single wide grant.
MAX_TARGET_WINDOWS :: 16

// Upper bound on a single wide grant duration (24 hours in milliseconds).
MAX_WIDE_GRANT_DURATION_MS :: u64(24 * 60 * 60 * 1000)

// Default wide grant duration shown to the principal (1 hour in milliseconds).
DEFAULT_WIDE_GRANT_DURATION_MS :: u64(60 * 60 * 1000)

// Byte length of a proof token carried in a Wide_Grant_Proof record.
PROOF_TOKEN_BYTES :: 64

// Domain separation contexts for BLAKE3 derive_key so wide grant digests and
// act record hashes cannot collide with module hashes or each other.
TERMS_HASH_DOMAIN_CONTEXT :: "modus wide grant terms v1"
PROOF_TAG_DOMAIN_CONTEXT :: "modus wide grant proof v1"
ACT_RECORD_HASH_DOMAIN_CONTEXT :: "modus act record v1"

// Fixed stack buffer capacities for canonical encoding before BLAKE3 hashing.
TERMS_ENCODE_BUFFER_CAPACITY :: 256
PROOF_ENCODE_BUFFER_CAPACITY :: 128
ACT_RECORD_ENCODE_BUFFER_CAPACITY :: 128

// Genesis previous_hash for sequence_number 0 at the start of an act chain.
GENESIS_PREVIOUS_HASH :: blake3.Hash{}

// Context handle slots and value slots for the freestanding collector service.
SERVICE_RING_SLOT :: 10
SERVICE_REGION_SLOT :: 11
CONTEXT_VALUE_PRINCIPAL_SLOT :: 0

// Maximum commands drained from the collector service ring in a single pass.
REQUESTS_PER_PASS :: 8

// Closed set of wide authorities that a wide grant can confer.
// Values are explicit bit indices in Wide_Authorities; bit 0 is unused so
// word 0 always names no authority.
Wide_Authority :: enum u64 {
	View_Screen        = 1,
	Send_Input         = 2,
	Read_Semantic_Tree = 3,
}

// Bit set of granted Wide_Authority flags.
Wide_Authorities :: bit_set[Wide_Authority;u64]

// Bit mask of all defined Wide_Authority bits.
WIDE_AUTHORITY_KNOWN_MASK :: (u64(1) << u64(Wide_Authority.View_Screen)) |
	(u64(1) << u64(Wide_Authority.Send_Input)) |
	(u64(1) << u64(Wide_Authority.Read_Semantic_Tree))

// Closed set of principal proof kinds accepted to activate a wide grant.
// Zero means unset and is refused at the border.
Proof_Kind :: enum u64 {
	None                = 0,
	Passphrase_Verified = 1,
	Host_Key_Signed     = 2,
}

// Closed lifecycle state machine of a wide grant.
// Zero means unset and is refused at the border.
Wide_Grant_State :: enum u64 {
	None    = 0,
	Pending = 1,
	Active  = 2,
	Revoked = 3,
	Expired = 4,
}

// Closed set of act kinds recorded in the append-only hash-chained act log.
// Zero means unset and is refused at the border.
Act_Kind :: enum u64 {
	None                  = 0,
	Frame_Read            = 1,
	Key_Injected          = 2,
	Pointer_Moved         = 3,
	Pointer_Clicked       = 4,
	Action_Invoked        = 5,
	Grant_Started         = 6,
	Grant_Revoked         = 7,
	Grant_Expired         = 8,
	Forbidden_Act_Blocked = 9,
}

// Closed set of refusal reasons returned by wide grant border validators,
// act chain verification, and the collector wide grant manager.
Wide_Grant_Refusal :: enum u64 {
	None                          = 0,
	Invalid_Authority             = 1,
	Empty_Window_Set              = 2,
	Too_Many_Windows              = 3,
	Duration_Zero                 = 4,
	Duration_Past_Bound           = 5,
	Missing_Proof                 = 6,
	Invalid_Proof                 = 7,
	Grant_Expired                 = 8,
	Grant_Revoked                 = 9,
	Window_Not_In_Scope           = 10,
	Act_Still_Requires_Principal  = 11,
	Act_Log_Full                  = 12,
	Chain_Tampered                = 13,
	Restart_Persistence_Forbidden = 14,
}

// Closed set of sensitive action classes evaluated by
// act_requires_principal_proof. Sensitive operations still require fresh
// principal proof even while a wide grant is active.
Sensitive_Action :: enum u64 {
	None                         = 0,
	Normal_Window_Input          = 1,
	Normal_Screen_Read           = 2,
	Normal_Semantic_Read         = 3,
	Plans_Apply_Adding_Grant     = 4,
	Passphrase_Or_Unlock_Dialog  = 5,
	Trusted_Display_Grant_Dialog = 6,
	Disk_Grant_Change            = 7,
	Principal_Management         = 8,
	Module_Replace_Or_Debug      = 9,
	Wide_Grant_Screen_Or_Mark    = 10,
}

// Closed set of collector space kinds (src/md/features/module_outputs.md).
Collector_Space_Kind :: enum u64 {
	None  = 0,
	Keep  = 1,
	Audit = 2,
}

// Closed set of commands carried on the collector service ring.
Collector_Ring_Command :: enum u32 {
	None                     = 0,
	Create_Grant             = 1,
	Revoke_Grant             = 2,
	Authorize_And_Record_Act = 3,
	Append_Act_Record        = 4,
	Verify_Act_Chain         = 5,
	Query_By_Grant           = 6,
	Query_By_Window          = 7,
	Query_Status             = 8,
}

// Closed set of completion statuses returned on the collector service ring.
Collector_Ring_Status :: enum u32 {
	Ok          = 0,
	Refused     = 1,
	Bad_Command = 2,
	Busy        = 3,
}

// Fixed-layout terms of one wide grant proposed and fixed before principal
// proof. survives_restart must be false: a wide grant never persists across
// a restart.
Wide_Grant_Terms :: struct {
	principal_id:          u64,
	grantee_identity_hash: blake3.Hash,
	authorities_word:      u64,
	target_window_count:   u32,
	reserved_pad:          u32,
	target_window_ids:     [MAX_TARGET_WINDOWS]u64,
	duration_ms:           u64,
	survives_restart:      bool,
	terms_hash:            blake3.Hash,
}

// Principal proof record bound to a specific sealed Wide_Grant_Terms hash.
// Neither passphrase verification nor host-key signing may arrive through
// remote display input.
Wide_Grant_Proof :: struct {
	proof_kind_word:                u64,
	principal_id:                   u64,
	terms_hash:                     blake3.Hash,
	verifier_key_or_token_hash:     blake3.Hash,
	proof_bytes:                    [PROOF_TOKEN_BYTES]u8,
	proof_timestamp_ms:             u64,
	proof_verified_by_local_unlock: bool,
	from_remote_display_input:      bool,
}

// Fixed-layout hash-chained act record stored by the collector. Each record
// chains to the previous record's BLAKE3 digest with domain separation
// "modus act record v1".
Act_Record :: struct {
	sequence_number:  u64,
	grant_serial:     u64,
	timestamp_ms:     u64,
	act_kind_word:    u64,
	target_window_id: u64,
	detail_word_0:    u64,
	detail_word_1:    u64,
	previous_hash:    [32]u8,
	record_hash:      [32]u8,
}

// Shared-region request payload for Collector_Ring_Command.Create_Grant.
Create_Grant_Request :: struct {
	terms: Wide_Grant_Terms,
	proof: Wide_Grant_Proof,
}

// Shared-region request payload for Collector_Ring_Command.Authorize_And_Record_Act.
Authorize_Act_Request :: struct {
	grant_serial:          u64,
	act_kind_word:         u64,
	target_window_id:      u64,
	sensitive_action_word: u64,
	detail_word_0:         u64,
	detail_word_1:         u64,
}

// Border parsers: each converts a raw transport word into its closed enum,
// refusing unknown words and zero where zero means unset.

wide_authority_from_word :: proc "contextless" (word: u64) -> (authority: Wide_Authority, ok: bool) {
	return enum_word.member_of_word(Wide_Authority, word)
}

wide_authorities_to_word :: proc "contextless" (authorities: Wide_Authorities) -> u64 {
	word: u64 = 0
	if .View_Screen in authorities {
		word |= u64(1) << u64(Wide_Authority.View_Screen)
	}
	if .Send_Input in authorities {
		word |= u64(1) << u64(Wide_Authority.Send_Input)
	}
	if .Read_Semantic_Tree in authorities {
		word |= u64(1) << u64(Wide_Authority.Read_Semantic_Tree)
	}
	return word
}

wide_authorities_from_word :: proc "contextless" (word: u64) -> (authorities: Wide_Authorities, ok: bool) {
	if word == 0 || word & ~WIDE_AUTHORITY_KNOWN_MASK != 0 {
		return {}, false
	}
	decoded: Wide_Authorities
	if word & (u64(1) << u64(Wide_Authority.View_Screen)) != 0 {
		decoded += {.View_Screen}
	}
	if word & (u64(1) << u64(Wide_Authority.Send_Input)) != 0 {
		decoded += {.Send_Input}
	}
	if word & (u64(1) << u64(Wide_Authority.Read_Semantic_Tree)) != 0 {
		decoded += {.Read_Semantic_Tree}
	}
	return decoded, true
}

proof_kind_from_word :: proc "contextless" (word: u64) -> (kind: Proof_Kind, ok: bool) {
	member := enum_word.member_of_word(Proof_Kind, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

wide_grant_state_from_word :: proc "contextless" (word: u64) -> (state: Wide_Grant_State, ok: bool) {
	member := enum_word.member_of_word(Wide_Grant_State, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

act_kind_from_word :: proc "contextless" (word: u64) -> (kind: Act_Kind, ok: bool) {
	member := enum_word.member_of_word(Act_Kind, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

wide_grant_refusal_from_word :: proc "contextless" (word: u64) -> (refusal: Wide_Grant_Refusal, ok: bool) {
	return enum_word.member_of_word(Wide_Grant_Refusal, word)
}

sensitive_action_from_word :: proc "contextless" (word: u64) -> (action: Sensitive_Action, ok: bool) {
	member := enum_word.member_of_word(Sensitive_Action, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

collector_space_kind_from_word :: proc "contextless" (word: u64) -> (kind: Collector_Space_Kind, ok: bool) {
	member := enum_word.member_of_word(Collector_Space_Kind, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

collector_ring_command_from_word :: proc "contextless" (word: u32) -> (command: Collector_Ring_Command, ok: bool) {
	member := enum_word.member_of_word(Collector_Ring_Command, u64(word)) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

// act_requires_principal_proof reports whether action still requires fresh
// principal proof even while a wide grant holds. Fails closed: unknown or
// unset actions return true.
act_requires_principal_proof :: proc "contextless" (action: Sensitive_Action) -> bool {
	switch action {
	case .Normal_Window_Input, .Normal_Screen_Read, .Normal_Semantic_Read:
		return false
	case .None,
		.Plans_Apply_Adding_Grant,
		.Passphrase_Or_Unlock_Dialog,
		.Trusted_Display_Grant_Dialog,
		.Disk_Grant_Change,
		.Principal_Management,
		.Module_Replace_Or_Debug,
		.Wide_Grant_Screen_Or_Mark:
		return true
	}
	return true
}

// act_kind_requires_target_window reports whether an act kind must name a
// non-zero target window identifier.
act_kind_requires_target_window :: proc "contextless" (kind: Act_Kind) -> bool {
	switch kind {
	case .Key_Injected, .Pointer_Moved, .Pointer_Clicked, .Action_Invoked:
		return true
	case .None, .Frame_Read, .Grant_Started, .Grant_Revoked, .Grant_Expired, .Forbidden_Act_Blocked:
		return false
	}
	return true
}

// act_kind_is_agent_invocable reports whether an agent may submit an act of
// this kind under a wide grant. Lifecycle records are emitted only by the
// manager.
act_kind_is_agent_invocable :: proc "contextless" (kind: Act_Kind) -> bool {
	switch kind {
	case .Frame_Read, .Key_Injected, .Pointer_Moved, .Pointer_Clicked, .Action_Invoked:
		return true
	case .None, .Grant_Started, .Grant_Revoked, .Grant_Expired, .Forbidden_Act_Blocked:
		return false
	}
	return false
}

// Canonical binary encoder using an explicit cursor name so no field triggers
// text-writer static checks.
@(private = "file")
Canonical_Encoder :: struct {
	storage:  []u8,
	position: int,
	overflow: bool,
}

@(private = "file")
encode_byte :: proc "contextless" (encoder: ^Canonical_Encoder, value: u8) {
	if encoder.overflow || encoder.position >= len(encoder.storage) {
		encoder.overflow = true
		return
	}
	encoder.storage[encoder.position] = value
	encoder.position += 1
}

@(private = "file")
encode_u32 :: proc "contextless" (encoder: ^Canonical_Encoder, value: u32) {
	if encoder.overflow || len(encoder.storage) - encoder.position < 4 {
		encoder.overflow = true
		return
	}
	byte_order.write_u32_little_endian(encoder.storage, encoder.position, value)
	encoder.position += 4
}

@(private = "file")
encode_u64 :: proc "contextless" (encoder: ^Canonical_Encoder, value: u64) {
	if encoder.overflow || len(encoder.storage) - encoder.position < 8 {
		encoder.overflow = true
		return
	}
	byte_order.write_u64_little_endian(encoder.storage, encoder.position, value)
	encoder.position += 8
}

@(private = "file")
encode_bytes :: proc "contextless" (encoder: ^Canonical_Encoder, data: []u8) {
	if encoder.overflow || len(encoder.storage) - encoder.position < len(data) {
		encoder.overflow = true
		return
	}
	for index in 0 ..< len(data) {
		encoder.storage[encoder.position + index] = data[index]
	}
	encoder.position += len(data)
}

// wide_grant_terms_compute_hash computes the deterministic domain-separated
// BLAKE3 digest of the canonical payload of Wide_Grant_Terms (excluding
// terms_hash itself).
wide_grant_terms_compute_hash :: proc "contextless" (terms: ^Wide_Grant_Terms) -> (digest: blake3.Hash, refusal: Wide_Grant_Refusal) {
	if terms.target_window_count > MAX_TARGET_WINDOWS {
		return {}, .Too_Many_Windows
	}
	storage: [TERMS_ENCODE_BUFFER_CAPACITY]u8
	encoder := Canonical_Encoder{storage = storage[:]}
	encode_u64(&encoder, terms.principal_id)
	encode_bytes(&encoder, terms.grantee_identity_hash[:])
	encode_u64(&encoder, terms.authorities_word)
	encode_u32(&encoder, terms.target_window_count)
	for index in u32(0) ..< terms.target_window_count {
		encode_u64(&encoder, terms.target_window_ids[index])
	}
	encode_u64(&encoder, terms.duration_ms)
	encode_byte(&encoder, terms.survives_restart ? 1 : 0)
	if encoder.overflow {
		return {}, .Too_Many_Windows
	}
	return blake3.derive_key(TERMS_HASH_DOMAIN_CONTEXT, storage[:encoder.position]), .None
}

// wide_grant_terms_validate_fields checks all structural constraints of
// Wide_Grant_Terms except terms_hash verification.
@(private = "file")
wide_grant_terms_validate_fields :: proc "contextless" (terms: ^Wide_Grant_Terms) -> Wide_Grant_Refusal {
	if terms.survives_restart {
		return .Restart_Persistence_Forbidden
	}
	if terms.reserved_pad != 0 {
		return .Invalid_Authority
	}
	authorities, auth_ok := wide_authorities_from_word(terms.authorities_word)
	if !auth_ok {
		return .Invalid_Authority
	}
	// Sending input requires screen view so the grant honestly states its reach.
	if .Send_Input in authorities && .View_Screen not_in authorities {
		return .Invalid_Authority
	}
	if terms.target_window_count == 0 {
		return .Empty_Window_Set
	}
	if terms.target_window_count > MAX_TARGET_WINDOWS {
		return .Too_Many_Windows
	}
	for index in u32(0) ..< terms.target_window_count {
		window_id := terms.target_window_ids[index]
		if window_id == 0 {
			return .Window_Not_In_Scope
		}
		for earlier in u32(0) ..< index {
			if terms.target_window_ids[earlier] == window_id {
				return .Window_Not_In_Scope
			}
		}
	}
	for tail in terms.target_window_count ..< MAX_TARGET_WINDOWS {
		if terms.target_window_ids[tail] != 0 {
			return .Too_Many_Windows
		}
	}
	if terms.duration_ms == 0 {
		return .Duration_Zero
	}
	if terms.duration_ms > MAX_WIDE_GRANT_DURATION_MS {
		return .Duration_Past_Bound
	}
	if terms.grantee_identity_hash == (blake3.Hash{}) {
		return .Invalid_Proof
	}
	return .None
}

// wide_grant_terms_seal validates the structural fields of Wide_Grant_Terms
// and populates its canonical domain-separated BLAKE3 terms_hash.
wide_grant_terms_seal :: proc "contextless" (terms: ^Wide_Grant_Terms) -> Wide_Grant_Refusal {
	field_refusal := wide_grant_terms_validate_fields(terms)
	if field_refusal != .None {
		return field_refusal
	}
	digest, hash_refusal := wide_grant_terms_compute_hash(terms)
	if hash_refusal != .None {
		return hash_refusal
	}
	terms.terms_hash = digest
	return wide_grant_terms_validate(terms)
}

// wide_grant_terms_validate strictly validates a Wide_Grant_Terms record at
// the border, including canonical terms_hash verification.
wide_grant_terms_validate :: proc "contextless" (terms: ^Wide_Grant_Terms) -> Wide_Grant_Refusal {
	field_refusal := wide_grant_terms_validate_fields(terms)
	if field_refusal != .None {
		return field_refusal
	}
	expected_hash, hash_refusal := wide_grant_terms_compute_hash(terms)
	if hash_refusal != .None {
		return hash_refusal
	}
	if terms.terms_hash == (blake3.Hash{}) || terms.terms_hash != expected_hash {
		return .Invalid_Proof
	}
	return .None
}

// wide_grant_terms_contains_window reports whether target_window_id is an
// explicit non-zero member of terms.target_window_ids.
wide_grant_terms_contains_window :: proc "contextless" (terms: ^Wide_Grant_Terms, target_window_id: u64) -> bool {
	if target_window_id == 0 || terms.target_window_count == 0 || terms.target_window_count > MAX_TARGET_WINDOWS {
		return false
	}
	for index in u32(0) ..< terms.target_window_count {
		if terms.target_window_ids[index] == target_window_id {
			return true
		}
	}
	return false
}

// wide_grant_proof_tag computes the domain-separated BLAKE3 binding tag linking
// a proof kind, principal id, terms hash, and verifier key or unlock token hash.
wide_grant_proof_tag :: proc "contextless" (
	kind: Proof_Kind,
	principal_id: u64,
	terms_hash: blake3.Hash,
	verifier_key_or_token_hash: blake3.Hash,
) -> blake3.Hash {
	storage: [PROOF_ENCODE_BUFFER_CAPACITY]u8
	encoder := Canonical_Encoder{storage = storage[:]}
	terms_hash_copy := terms_hash
	verifier_hash_copy := verifier_key_or_token_hash
	encode_u64(&encoder, u64(kind))
	encode_u64(&encoder, principal_id)
	encode_bytes(&encoder, terms_hash_copy[:])
	encode_bytes(&encoder, verifier_hash_copy[:])
	return blake3.derive_key(PROOF_TAG_DOMAIN_CONTEXT, storage[:encoder.position])
}

// wide_grant_proof_make constructs a properly bound Wide_Grant_Proof for a
// validated Wide_Grant_Terms record.
wide_grant_proof_make :: proc "contextless" (
	terms: ^Wide_Grant_Terms,
	kind: Proof_Kind,
	verifier_key_or_token_hash: blake3.Hash,
	proof_timestamp_ms: u64,
) -> (proof: Wide_Grant_Proof, refusal: Wide_Grant_Refusal) {
	terms_refusal := wide_grant_terms_validate(terms)
	if terms_refusal != .None {
		return {}, terms_refusal
	}
	if kind == .None {
		return {}, .Missing_Proof
	}
	if verifier_key_or_token_hash == (blake3.Hash{}) {
		return {}, .Missing_Proof
	}
	proof = Wide_Grant_Proof {
		proof_kind_word                = u64(kind),
		principal_id                   = terms.principal_id,
		terms_hash                     = terms.terms_hash,
		verifier_key_or_token_hash     = verifier_key_or_token_hash,
		proof_timestamp_ms             = proof_timestamp_ms,
		proof_verified_by_local_unlock = kind == .Passphrase_Verified,
		from_remote_display_input      = false,
	}
	tag := wide_grant_proof_tag(kind, terms.principal_id, terms.terms_hash, verifier_key_or_token_hash)
	for index in 0 ..< blake3.HASH_SIZE {
		proof.proof_bytes[index] = tag[index]
	}
	return proof, .None
}

// wide_grant_proof_validate verifies that proof authorizes the exact sealed
// terms for the principal. Refuses missing proofs, remote display input,
// mismatched terms hashes, unregistered host keys, and tampered proof tags.
wide_grant_proof_validate :: proc "contextless" (
	terms: ^Wide_Grant_Terms,
	proof: ^Wide_Grant_Proof,
	expected_host_key_hash: blake3.Hash,
) -> Wide_Grant_Refusal {
	terms_refusal := wide_grant_terms_validate(terms)
	if terms_refusal != .None {
		return terms_refusal
	}
	if proof.proof_kind_word == 0 {
		return .Missing_Proof
	}
	kind, kind_ok := proof_kind_from_word(proof.proof_kind_word)
	if !kind_ok {
		return .Invalid_Proof
	}
	if proof.from_remote_display_input {
		return .Invalid_Proof
	}
	if proof.principal_id != terms.principal_id {
		return .Invalid_Proof
	}
	if proof.terms_hash == (blake3.Hash{}) || proof.terms_hash != terms.terms_hash {
		return .Invalid_Proof
	}
	if proof.verifier_key_or_token_hash == (blake3.Hash{}) {
		return .Missing_Proof
	}
	has_nonzero_proof_byte := false
	for value in proof.proof_bytes {
		if value != 0 {
			has_nonzero_proof_byte = true
			break
		}
	}
	if !has_nonzero_proof_byte {
		return .Missing_Proof
	}

	switch kind {
	case .None:
		return .Missing_Proof
	case .Passphrase_Verified:
		if !proof.proof_verified_by_local_unlock {
			return .Invalid_Proof
		}
	case .Host_Key_Signed:
		if expected_host_key_hash == (blake3.Hash{}) {
			return .Invalid_Proof
		}
		if proof.verifier_key_or_token_hash != expected_host_key_hash {
			return .Invalid_Proof
		}
	}

	expected_tag := wide_grant_proof_tag(kind, proof.principal_id, proof.terms_hash, proof.verifier_key_or_token_hash)
	for index in 0 ..< blake3.HASH_SIZE {
		if proof.proof_bytes[index] != expected_tag[index] {
			return .Invalid_Proof
		}
	}
	return .None
}

// act_record_compute_hash computes the domain-separated BLAKE3 digest
// ("modus act record v1") over previous_hash and all fields of Act_Record.
act_record_compute_hash :: proc "contextless" (record: ^Act_Record) -> (digest: blake3.Hash, refusal: Wide_Grant_Refusal) {
	if _, ok := act_kind_from_word(record.act_kind_word); !ok {
		return {}, .Chain_Tampered
	}
	storage: [ACT_RECORD_ENCODE_BUFFER_CAPACITY]u8
	encoder := Canonical_Encoder{storage = storage[:]}
	encode_bytes(&encoder, record.previous_hash[:])
	encode_u64(&encoder, record.sequence_number)
	encode_u64(&encoder, record.grant_serial)
	encode_u64(&encoder, record.timestamp_ms)
	encode_u64(&encoder, record.act_kind_word)
	encode_u64(&encoder, record.target_window_id)
	encode_u64(&encoder, record.detail_word_0)
	encode_u64(&encoder, record.detail_word_1)
	if encoder.overflow {
		return {}, .Chain_Tampered
	}
	return blake3.derive_key(ACT_RECORD_HASH_DOMAIN_CONTEXT, storage[:encoder.position]), .None
}

// act_record_seal validates the structural fields of an Act_Record and
// populates its domain-separated BLAKE3 record_hash.
act_record_seal :: proc "contextless" (record: ^Act_Record) -> Wide_Grant_Refusal {
	if record.grant_serial == 0 {
		return .Chain_Tampered
	}
	kind, kind_ok := act_kind_from_word(record.act_kind_word)
	if !kind_ok {
		return .Chain_Tampered
	}
	if act_kind_requires_target_window(kind) && record.target_window_id == 0 {
		return .Window_Not_In_Scope
	}
	digest, hash_refusal := act_record_compute_hash(record)
	if hash_refusal != .None {
		return hash_refusal
	}
	record.record_hash = digest
	return .None
}

// act_record_validate strictly checks an Act_Record at the border, including
// enum validity, window requirements, and record_hash integrity.
act_record_validate :: proc "contextless" (record: ^Act_Record) -> Wide_Grant_Refusal {
	if record.grant_serial == 0 {
		return .Chain_Tampered
	}
	kind, kind_ok := act_kind_from_word(record.act_kind_word)
	if !kind_ok {
		return .Chain_Tampered
	}
	if act_kind_requires_target_window(kind) && record.target_window_id == 0 {
		return .Window_Not_In_Scope
	}
	expected_hash, hash_refusal := act_record_compute_hash(record)
	if hash_refusal != .None {
		return hash_refusal
	}
	if record.record_hash == (blake3.Hash{}) || record.record_hash != expected_hash {
		return .Chain_Tampered
	}
	return .None
}

// act_chain_verify walks a slice of Act_Record entries and verifies every
// record hash, strictly sequential sequence_number, hash-chain linkage to
// previous_hash, and monotonic timestamp ordering. Detects any deleted,
// inserted, reordered, modified, or forked record and returns its exact index.
act_chain_verify :: proc "contextless" (
	records: []Act_Record,
	expected_start_sequence: u64 = 0,
	expected_initial_previous_hash: blake3.Hash = GENESIS_PREVIOUS_HASH,
) -> (refusal: Wide_Grant_Refusal, failing_index: u64) {
	if len(records) == 0 {
		return .None, 0
	}
	expected_previous := expected_initial_previous_hash
	for index in 0 ..< len(records) {
		record := &records[index]
		offset := u64(index)
		if offset > max(u64) - expected_start_sequence {
			return .Chain_Tampered, offset
		}
		expected_sequence := expected_start_sequence + offset
		if record.sequence_number != expected_sequence {
			return .Chain_Tampered, offset
		}
		if record.previous_hash != expected_previous {
			return .Chain_Tampered, offset
		}
		if index > 0 && record.timestamp_ms < records[index - 1].timestamp_ms {
			return .Chain_Tampered, offset
		}
		if act_record_validate(record) != .None {
			return .Chain_Tampered, offset
		}
		expected_previous = record.record_hash
	}
	return .None, 0
}

// act_chain_verify_with_head verifies the full act chain and checks the
// expected total record count and head digest to detect tail truncation or
// silent drop of the most recent records.
act_chain_verify_with_head :: proc "contextless" (
	records: []Act_Record,
	expected_count: u64,
	expected_head_hash: blake3.Hash,
) -> (refusal: Wide_Grant_Refusal, failing_index: u64) {
	if u64(len(records)) != expected_count {
		return .Chain_Tampered, u64(len(records))
	}
	chain_refusal, bad_index := act_chain_verify(records, 0, GENESIS_PREVIOUS_HASH)
	if chain_refusal != .None {
		return chain_refusal, bad_index
	}
	if expected_count == 0 {
		if expected_head_hash != GENESIS_PREVIOUS_HASH {
			return .Chain_Tampered, 0
		}
		return .None, 0
	}
	last_index := expected_count - 1
	if records[last_index].record_hash != expected_head_hash {
		return .Chain_Tampered, last_index
	}
	return .None, 0
}
