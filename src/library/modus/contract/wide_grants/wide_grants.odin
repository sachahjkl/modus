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

import "base:intrinsics"
import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/enum_word"
import op "modus:contract/operation"

// Maximum explicit target window identifiers bound to a single wide grant.
MAX_TARGET_WINDOWS :: 16

// Upper bound on a single wide grant duration (24 hours in milliseconds).
MAX_WIDE_GRANT_DURATION_MS :: u64(24 * 60 * 60 * 1000)

// Default wide grant duration shown to the principal (1 hour in milliseconds).
DEFAULT_WIDE_GRANT_DURATION_MS :: u64(60 * 60 * 1000)

// Domain separation contexts for BLAKE3 derive_key so wide grant digests and
// act record hashes cannot collide with module hashes or each other.
TERMS_HASH_DOMAIN_CONTEXT :: "modus wide grant terms v1"
ACT_RECORD_HASH_DOMAIN_CONTEXT :: "modus act record v1"

// Domain separation prefix of the keyed proof payload, so that a tag under the
// authority key cannot be reused as the tag of another kind of record.
PROOF_TAG_DOMAIN_PREFIX :: "modus wide grant proof v2"

// The key that only the unlock authority and the verifier hold: a keyed
// BLAKE3 tag under it proves that the unlock authority issued the proof.
Authority_Key :: blake3.Hash

// The domain of the key of one principal: the keyed BLAKE3 hash, under the
// key of the run, of this text and the slot of the principal in 8 bytes
// little-endian.
PRINCIPAL_KEY_DOMAIN_PREFIX :: "modus wide grant authority key of one principal v1"

// Fixed stack buffer capacities for canonical encoding before BLAKE3 hashing.
TERMS_ENCODE_BUFFER_CAPACITY :: 256
PROOF_ENCODE_BUFFER_CAPACITY :: 160
ACT_RECORD_ENCODE_BUFFER_CAPACITY :: 128

// Genesis previous_hash for sequence_number 0 at the start of an act chain.
GENESIS_PREVIOUS_HASH :: blake3.Hash{}

// Context handle slots and value slots for the freestanding collector service.
// The principal sits in slot 4 (GRANT_VALUE_SERVICE_PRINCIPAL), and the
// authority key fills four value slots from slot 5 (5..8) in little-endian
// order of its bytes, avoiding the service and storage file slots (1..3) and
// the system seed slots (9..12).
SERVICE_RING_SLOT :: 10
SERVICE_REGION_SLOT :: 11
CONTEXT_VALUE_PRINCIPAL_SLOT :: 4
// The first 32 bytes of the collector shared region hold the principal
// identifier written by the root service before start (all zero for principal
// 0). Command payloads start at COLLECTOR_REGION_REQUEST_AT so a Create_Grant
// queued right after start never overwrites the identifier before the
// collector reads it.
COLLECTOR_REGION_IDENTIFIER_AT :: 0
COLLECTOR_REGION_REQUEST_AT :: COLLECTOR_REGION_IDENTIFIER_AT + COLLECTOR_IDENTIFIER_SIZE
#assert(COLLECTOR_REGION_REQUEST_AT >= COLLECTOR_REGION_IDENTIFIER_AT + COLLECTOR_IDENTIFIER_SIZE)
CONTEXT_VALUE_AUTHORITY_KEY_FIRST_SLOT :: 5
CONTEXT_VALUE_AUTHORITY_KEY_SLOT_COUNT :: 4

// Maximum commands drained from the collector service ring in a single pass.
REQUESTS_PER_PASS :: 8

// Closed set of wide authorities that a wide grant can confer.
// Values are explicit bit indices in Wide_Authorities; bit 0 is unused so
// word 0 always names no authority.
Wide_Authority :: enum u64 {
	View_Screen        = 1,
	Send_Input         = 2,
	Read_Semantic_Tree = 3,
	Machine_Principals = 4, // Machine grant scope Principals (wide grant for principal 0 only).
	Machine_System     = 5, // Machine grant scope System (wide grant for principal 0 only).
}

// Bit set of granted Wide_Authority flags.
Wide_Authorities :: bit_set[Wide_Authority;u64]

// Bit mask of all defined Wide_Authority bits.
WIDE_AUTHORITY_KNOWN_MASK :: (u64(1) << u64(Wide_Authority.View_Screen)) |
	(u64(1) << u64(Wide_Authority.Send_Input)) |
	(u64(1) << u64(Wide_Authority.Read_Semantic_Tree)) |
	(u64(1) << u64(Wide_Authority.Machine_Principals)) |
	(u64(1) << u64(Wide_Authority.Machine_System))

// Closed set of principal proof kinds accepted to activate a wide grant.
// Zero means unset and is refused at the border.
Proof_Kind :: enum u64 {
	None                = 0,
	Passphrase_Verified = 1,
	Host_Key_Signed     = 2,
}

// Closed set of the places where a principal proof was given. The origin is
// inside the authenticated payload: only the unlock authority states it.
// Zero means unset and is refused at the border.
Proof_Origin :: enum u64 {
	None                 = 0,
	Local_Unlock_Dialog  = 1,
	Local_Host_Key       = 2,
	Remote_Display_Input = 3,
}

// Closed set of the reasons of a revocation, recorded in the act chain.
// Zero means unset and is refused at the border.
Revocation_Reason :: enum u64 {
	None                    = 0,
	Principal_Revoked       = 1,
	Replaced_By_Newer_Grant = 2,
	Duplicate_Connection    = 3,
	Session_Locked          = 4, // The session of the principal was locked.
	Time_Bound              = 5, // The duration of the terms ran out.
	Audit_Ring_Closed       = 6, // A ring of act records of the grant ended or was closed: no act of its writer has a reader.
	Mark_Not_Shown          = 7, // The trusted display did not take the mark of the grant.
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
	Call_Made             = 10, // A call of an export through `remote`: detail 0 the head of the hash of the service, detail 1 the bytes of the request.
	// The input of a viewer reaches another window: the target window, then
	// detail 0 the keys and detail 1 the presses that the window before it
	// took. It comes before the first act on its window.
	Target_Window_Changed = 11,
	// The keys (detail 0) and the presses (detail 1) that the window of the
	// last record took since that record: at an interval while a grant
	// holds, and at its end with the time of the last act, so the counts of
	// the last window are not lost.
	Input_Counted = 12,
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
	// A record that the collector sends with no command, tag 0: it ended
	// the grant of values[0] itself, with the Revocation_Reason of
	// values[1] (an audit ring closed, or its end time).
	Grant_Ended = 4,
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
// proof_tag is the keyed BLAKE3 tag, under the authority key, of every other
// field: a caller without the key cannot forge it or change one field.
// proof_serial is a counter of the unlock authority: the verifier refuses a
// serial that is not past the last one it accepted, so a proof is used once.
Wide_Grant_Proof :: struct {
	proof_kind_word:            u64,
	origin_word:                u64,
	principal_id:               u64,
	proof_serial:               u64,
	proof_timestamp_ms:         u64,
	terms_hash:                 blake3.Hash,
	verifier_key_or_token_hash: blake3.Hash,
	proof_tag:                  blake3.Hash,
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
	if .Machine_Principals in authorities {
		word |= u64(1) << u64(Wide_Authority.Machine_Principals)
	}
	if .Machine_System in authorities {
		word |= u64(1) << u64(Wide_Authority.Machine_System)
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
	if word & (u64(1) << u64(Wide_Authority.Machine_Principals)) != 0 {
		decoded += {.Machine_Principals}
	}
	if word & (u64(1) << u64(Wide_Authority.Machine_System)) != 0 {
		decoded += {.Machine_System}
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

proof_origin_from_word :: proc "contextless" (word: u64) -> (origin: Proof_Origin, ok: bool) {
	member := enum_word.member_of_word(Proof_Origin, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

revocation_reason_from_word :: proc "contextless" (word: u64) -> (reason: Revocation_Reason, ok: bool) {
	member := enum_word.member_of_word(Revocation_Reason, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

// authority_key_from_words rebuilds the authority key from the four context
// value words that carry it.
authority_key_from_words :: proc "contextless" (words: [CONTEXT_VALUE_AUTHORITY_KEY_SLOT_COUNT]u64) -> (key: Authority_Key) {
	for word, word_index in words {
		byte_order.write_u64_little_endian(key[:], word_index * 8, word)
	}
	return key
}

// authority_key_to_words packs an authority key into the four context value
// words in little-endian order of its bytes.
authority_key_to_words :: proc "contextless" (key: Authority_Key) -> (words: [CONTEXT_VALUE_AUTHORITY_KEY_SLOT_COUNT]u64) {
	local := key
	for word_index in 0 ..< CONTEXT_VALUE_AUTHORITY_KEY_SLOT_COUNT {
		words[word_index] = byte_order.read_u64_little_endian(local[:], word_index * 8)
	}
	return words
}

// authority_key_is_valid refuses the all-zero key: a key that everybody
// knows authenticates nothing.
authority_key_is_valid :: proc "contextless" (key: Authority_Key) -> bool {
	return key != (Authority_Key{})
}

// Least entropy strength accepted for generating a fresh wide-grant authority
// key at boot: jitter-only (Weak) seeds are refused fail-closed.
AUTHORITY_KEY_LEAST_ENTROPY :: op.Seed_Strength.Processor

// Closed lifecycle state of the unlock authority's wide-grant key.
Authority_Key_Status :: enum u8 {
	Uninitialized        = 0,
	Ready                = 1,
	Refused_Weak_Entropy = 2,
	Refused_Zero_Key     = 3,
}

// What an authority key is for. The key of the run never signs a proof
// and never leaves the unlock authority: it only makes the key of each
// principal. The key of a principal signs the proofs of that principal
// only, and goes to the collector of that principal only, so a collector
// makes no proof that the collector of another principal accepts
// (src/md/features/several_principals.md, "The authority key of the wide
// grants, for each principal").
Authority_Scope :: enum u8 {
	Run       = 0,
	Principal = 1,
}

// State held exclusively by the unlock authority (the root service) for
// minting keyed Wide_Grant_Proof records and handing the authority key to
// the collector in its context at start. The proof serial is one sequence
// for each principal: a collector learns no count of the proofs of
// another principal.
Wide_Grant_Authority :: struct {
	status:            Authority_Key_Status,
	scope:             Authority_Scope,
	principal:         u64, // Scope Principal: the slot of the principal.
	key:               Authority_Key,
	next_proof_serial: u64,
}

// authority_init_from_bytes initializes the unlock authority from fresh random
// bytes produced by the system generator. Refuses weak entropy (below
// AUTHORITY_KEY_LEAST_ENTROPY or unknown Seed_Strength) and refuses an
// all-zero key, leaving the authority unusable so the collector refuses every
// wide grant.
authority_init_from_bytes :: proc "contextless" (
	authority: ^Wide_Grant_Authority,
	key_bytes: Authority_Key,
	entropy_strength: op.Seed_Strength,
) -> bool {
	authority_erase(authority)
	strength, strength_ok := op.seed_strength_of_word(u64(entropy_strength))
	if !strength_ok || strength < AUTHORITY_KEY_LEAST_ENTROPY {
		authority.status = .Refused_Weak_Entropy
		return false
	}
	if !authority_key_is_valid(key_bytes) {
		authority.status = .Refused_Zero_Key
		return false
	}
	authority.key = key_bytes
	authority.scope = .Run
	authority.status = .Ready
	return true
}

// authority_init_for_principal makes the authority of one principal from
// the authority of the run: its key is the keyed hash of the slot under the
// key of the run, and its proof serial starts at 1. Refuses a run that is
// not ready, and an authority of a principal in place of the run: a key is
// made from the key of the run only.
//
// Example: the run key K gives the principal 1 the key
// keyed_hash(K, "modus wide grant authority key of one principal v1" ||
// 01 00 00 00 00 00 00 00).
authority_init_for_principal :: proc "contextless" (authority: ^Wide_Grant_Authority, run: ^Wide_Grant_Authority, principal: u64) -> bool {
	if authority == nil {
		return false
	}
	authority_erase(authority)
	if run == nil || run == authority || run.status != .Ready || run.scope != .Run || !authority_key_is_valid(run.key) {
		return false
	}
	material: [len(PRINCIPAL_KEY_DOMAIN_PREFIX) + 8]u8
	copy(material[:], PRINCIPAL_KEY_DOMAIN_PREFIX)
	byte_order.write_u64_little_endian(material[:], len(PRINCIPAL_KEY_DOMAIN_PREFIX), principal)
	key := blake3.keyed_hash(run.key, material[:])
	defer intrinsics.mem_zero_volatile(&key, size_of(key))
	if !authority_key_is_valid(key) {
		authority.status = .Refused_Zero_Key
		return false
	}
	authority.key = key
	authority.scope = .Principal
	authority.principal = principal
	authority.next_proof_serial = 1
	authority.status = .Ready
	return true
}

// authority_ready_for_principal says if an authority signs the proofs of a
// principal: a ready authority of that principal, never the run.
authority_ready_for_principal :: proc "contextless" (authority: ^Wide_Grant_Authority, principal: u64) -> bool {
	return authority != nil && authority.status == .Ready && authority.scope == .Principal && authority.principal == principal && authority_key_is_valid(authority.key)
}

// authority_context_words returns the four context value words carrying the
// authority key to the collector when the authority is ready. Refuses any
// non-ready or zero-key state with ok == false.
authority_context_words :: proc "contextless" (authority: ^Wide_Grant_Authority) -> (words: [CONTEXT_VALUE_AUTHORITY_KEY_SLOT_COUNT]u64, ok: bool) {
	// The key of the run never leaves the unlock authority.
	if authority == nil || !authority_ready_for_principal(authority, authority.principal) {
		return {}, false
	}
	return authority_key_to_words(authority.key), true
}

// authority_mint_proof issues a fresh keyed Wide_Grant_Proof bound to terms
// with a strictly increasing proof serial. Refuses when the authority key is
// not ready, when the serial counter is exhausted, or when terms/origin fail
// validation, leaving next_proof_serial unchanged on any refusal.
authority_mint_proof :: proc "contextless" (
	authority: ^Wide_Grant_Authority,
	terms: ^Wide_Grant_Terms,
	kind: Proof_Kind,
	origin: Proof_Origin,
	verifier_key_or_token_hash: blake3.Hash,
	proof_timestamp_ms: u64,
) -> (proof: Wide_Grant_Proof, refusal: Wide_Grant_Refusal) {
	// The key of the run signs nothing, and the key of a principal signs
	// the terms of that principal only.
	if authority == nil || terms == nil || !authority_ready_for_principal(authority, terms.principal_id) {
		return {}, .Invalid_Proof
	}
	if authority.next_proof_serial == 0 || authority.next_proof_serial == max(u64) {
		return {}, .Invalid_Proof
	}
	proof, refusal = wide_grant_proof_make(
		authority.key,
		terms,
		kind,
		origin,
		authority.next_proof_serial,
		verifier_key_or_token_hash,
		proof_timestamp_ms,
	)
	if refusal != .None {
		return {}, refusal
	}
	authority.next_proof_serial += 1
	return proof, .None
}

// authority_erase clears the authority key material with a volatile zero write.
authority_erase :: proc "contextless" (authority: ^Wide_Grant_Authority) {
	if authority == nil {
		return
	}
	intrinsics.mem_zero_volatile(&authority.key, size_of(authority.key))
	authority.status = .Uninitialized
	authority.scope = .Run
	authority.principal = 0
	authority.next_proof_serial = 0
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
	case .Key_Injected, .Pointer_Moved, .Pointer_Clicked, .Action_Invoked, .Target_Window_Changed, .Input_Counted:
		return true
	case .None, .Frame_Read, .Grant_Started, .Grant_Revoked, .Grant_Expired, .Forbidden_Act_Blocked, .Call_Made:
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
	case .None, .Grant_Started, .Grant_Revoked, .Grant_Expired, .Forbidden_Act_Blocked, .Call_Made, .Target_Window_Changed, .Input_Counted:
		// A call and a change of target are recorded by their writer on its
		// own ring, never through the manager of the collector.
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
	is_machine_grant := (authorities & MACHINE_AUTHORITIES) != {}
	if is_machine_grant {
		// Machine grants are wide grants for principal 0 only, never mixed with
		// desktop agent authorities and targeting no window ids.
		if terms.principal_id != 0 || (authorities - MACHINE_AUTHORITIES) != {} {
			return .Invalid_Authority
		}
		if terms.target_window_count != 0 {
			return .Too_Many_Windows
		}
		for tail in u32(0) ..< MAX_TARGET_WINDOWS {
			if terms.target_window_ids[tail] != 0 {
				return .Too_Many_Windows
			}
		}
	} else {
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

// wide_grant_proof_tag computes the keyed BLAKE3 tag of every field of proof
// except proof_tag, under authority_key. It refuses the all-zero key.
wide_grant_proof_tag :: proc "contextless" (authority_key: Authority_Key, proof: ^Wide_Grant_Proof) -> (tag: blake3.Hash, ok: bool) {
	if !authority_key_is_valid(authority_key) {
		return {}, false
	}
	storage: [PROOF_ENCODE_BUFFER_CAPACITY]u8
	encoder := Canonical_Encoder{storage = storage[:]}
	encode_bytes(&encoder, transmute([]u8)string(PROOF_TAG_DOMAIN_PREFIX))
	encode_u64(&encoder, proof.proof_kind_word)
	encode_u64(&encoder, proof.origin_word)
	encode_u64(&encoder, proof.principal_id)
	encode_u64(&encoder, proof.proof_serial)
	encode_u64(&encoder, proof.proof_timestamp_ms)
	encode_bytes(&encoder, proof.terms_hash[:])
	encode_bytes(&encoder, proof.verifier_key_or_token_hash[:])
	if encoder.overflow {
		return {}, false
	}
	return blake3.keyed_hash(authority_key, storage[:encoder.position]), true
}

// proof_origin_matches_kind reports whether a proof kind can be given at an
// origin. No proof kind is accepted from remote display input: a remote
// viewer must never approve its own reach.
@(private = "file")
proof_origin_matches_kind :: proc "contextless" (kind: Proof_Kind, origin: Proof_Origin) -> bool {
	switch origin {
	case .None, .Remote_Display_Input:
		return false
	case .Local_Unlock_Dialog:
		return kind == .Passphrase_Verified
	case .Local_Host_Key:
		return kind == .Host_Key_Signed
	}
	return false
}

// wide_grant_proof_make is the step of the unlock authority: it builds the
// proof of a validated Wide_Grant_Terms record and tags it under
// authority_key. It refuses an origin that the kind cannot have.
wide_grant_proof_make :: proc "contextless" (
	authority_key: Authority_Key,
	terms: ^Wide_Grant_Terms,
	kind: Proof_Kind,
	origin: Proof_Origin,
	proof_serial: u64,
	verifier_key_or_token_hash: blake3.Hash,
	proof_timestamp_ms: u64,
) -> (proof: Wide_Grant_Proof, refusal: Wide_Grant_Refusal) {
	if !authority_key_is_valid(authority_key) {
		return {}, .Invalid_Proof
	}
	terms_refusal := wide_grant_terms_validate(terms)
	if terms_refusal != .None {
		return {}, terms_refusal
	}
	if kind == .None || verifier_key_or_token_hash == (blake3.Hash{}) || proof_serial == 0 {
		return {}, .Missing_Proof
	}
	if !proof_origin_matches_kind(kind, origin) {
		return {}, .Invalid_Proof
	}
	proof = Wide_Grant_Proof {
		proof_kind_word            = u64(kind),
		origin_word                = u64(origin),
		principal_id               = terms.principal_id,
		proof_serial               = proof_serial,
		proof_timestamp_ms         = proof_timestamp_ms,
		terms_hash                 = terms.terms_hash,
		verifier_key_or_token_hash = verifier_key_or_token_hash,
	}
	tag, tag_ok := wide_grant_proof_tag(authority_key, &proof)
	if !tag_ok {
		return {}, .Invalid_Proof
	}
	proof.proof_tag = tag
	return proof, .None
}

// tags_equal compares two tags in a time that does not depend on where they
// differ, so that the time of a refusal tells nothing of the right tag.
@(private = "file")
tags_equal :: proc "contextless" (left, right: blake3.Hash) -> bool {
	difference: u8 = 0
	for index in 0 ..< blake3.HASH_SIZE {
		difference |= left[index] ~ right[index]
	}
	return difference == 0
}

// wide_grant_proof_validate verifies that proof authorizes the exact sealed
// terms for the principal. It refuses the all-zero authority key, a missing
// proof, a tag that is not the keyed tag under authority_key, an origin that
// is remote or does not match the kind, mismatched terms hashes, unregistered
// host keys, and a proof serial that is not past last_accepted_proof_serial.
wide_grant_proof_validate :: proc "contextless" (
	authority_key: Authority_Key,
	terms: ^Wide_Grant_Terms,
	proof: ^Wide_Grant_Proof,
	expected_host_key_hash: blake3.Hash,
	last_accepted_proof_serial: u64,
) -> Wide_Grant_Refusal {
	if !authority_key_is_valid(authority_key) {
		return .Invalid_Proof
	}
	terms_refusal := wide_grant_terms_validate(terms)
	if terms_refusal != .None {
		return terms_refusal
	}
	if proof.proof_kind_word == 0 || proof.proof_tag == (blake3.Hash{}) {
		return .Missing_Proof
	}
	// The tag comes first: no field of an unauthenticated proof is read as a fact.
	expected_tag, tag_ok := wide_grant_proof_tag(authority_key, proof)
	if !tag_ok || !tags_equal(proof.proof_tag, expected_tag) {
		return .Invalid_Proof
	}
	kind, kind_ok := proof_kind_from_word(proof.proof_kind_word)
	if !kind_ok {
		return .Invalid_Proof
	}
	origin, origin_ok := proof_origin_from_word(proof.origin_word)
	if !origin_ok || !proof_origin_matches_kind(kind, origin) {
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
	if proof.proof_serial == 0 || proof.proof_serial <= last_accepted_proof_serial {
		return .Invalid_Proof
	}
	switch kind {
	case .None:
		return .Missing_Proof
	case .Passphrase_Verified:
	case .Host_Key_Signed:
		if expected_host_key_hash == (blake3.Hash{}) || proof.verifier_key_or_token_hash != expected_host_key_hash {
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
