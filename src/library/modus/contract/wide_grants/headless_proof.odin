// Headless wide-grant proof signed by a principal's host authority key and
// session-lock wide-grant termination helper (src/md/features/wide_grants.md).
//
// Contract package: imports base and contract packages only, calls no kernel
// operation, and allocates no memory. Signature verification crosses an
// injected verifier callback so callers wire Ed25519 outside the contract.
package wide_grants

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/enum_word"

// Format property: wire version of a headless wide-grant proof payload.
HEADLESS_PROOF_VERSION :: u32(1)

// Format property: domain separation tag prepended to the canonical signing
// bytes so a headless proof signature cannot collide with another record kind.
HEADLESS_PROOF_DOMAIN_TAG :: "modus headless wide grant v1"

// Format property: Ed25519 public key byte size.
HEADLESS_PROOF_KEY_BYTES :: 32

// Format property: Ed25519 signature byte size.
HEADLESS_PROOF_SIGNATURE_BYTES :: 64

// Format property: random nonce byte size preventing replay of one proof.
HEADLESS_PROOF_NONCE_BYTES :: 32

// Format property: exact length of canonical little-endian signing bytes:
// domain tag (28) + version (4) + machine_id (32) + principal_id (8) +
// client_key (32) + authorities_word (8) + nonce (32) + duration_ms (8) +
// issued_at_ms (8) = 160 bytes.
HEADLESS_PROOF_SIGNING_BYTES :: len(HEADLESS_PROOF_DOMAIN_TAG) + 4 + 32 + 8 + HEADLESS_PROOF_KEY_BYTES + 8 + HEADLESS_PROOF_NONCE_BYTES + 8 + 8

// Format property: exact serialized wire length of Headless_Wide_Grant_Proof:
// version (4) + machine_id (32) + principal_id (8) + client_key (32) +
// authorities_word (8) + nonce (32) + duration_ms (8) + issued_at_ms (8) +
// host_public_key (32) + signature (64) = 228 bytes.
HEADLESS_PROOF_WIRE_BYTES :: 4 + 32 + 8 + HEADLESS_PROOF_KEY_BYTES + 8 + HEADLESS_PROOF_NONCE_BYTES + 8 + 8 + HEADLESS_PROOF_KEY_BYTES + HEADLESS_PROOF_SIGNATURE_BYTES

// Inline capacity: fixed ring of accepted nonces checked to refuse replays
// without heap allocation.
HEADLESS_NONCE_CACHE_CAPACITY :: 64

// Plan value: maximum age of a headless proof in milliseconds (5 minutes),
// bounding the replay window even after nonce cache eviction.
HEADLESS_PROOF_MAX_AGE_MS :: u64(300_000)

// Plan value: maximum allowed forward clock skew of a headless proof in
// milliseconds (30 seconds) so future-dated proofs cannot evade cache eviction.
HEADLESS_PROOF_MAX_FUTURE_SKEW_MS :: u64(30_000)

// Plan value: fixed table capacity of active wide grants tracked across
// principals for session-lock termination.
ACTIVE_WIDE_GRANT_TABLE_CAPACITY :: 16

// Closed set of refusal reasons returned by headless proof encoding, decoding,
// verification, and session-lock termination. Zero means accepted.
Headless_Proof_Refusal :: enum u8 {
	None                   = 0,
	Nil_Input              = 1,
	Bad_Version            = 2,
	Zero_Machine_Id        = 3,
	Machine_Id_Mismatch    = 4,
	Principal_Mismatch     = 5,
	Zero_Client_Key        = 6,
	Bad_Authorities        = 7,
	Zero_Nonce             = 8,
	Replayed_Nonce         = 9,
	Duration_Zero          = 10,
	Duration_Past_Bound    = 11,
	Zero_Host_Key          = 12,
	Host_Key_Mismatch      = 13,
	Zero_Signature         = 14,
	Missing_Verifier       = 15,
	Signature_Refused      = 16,
	Buffer_Too_Small       = 17,
	Bad_Wire_Length        = 18,
	Grant_Table_Full       = 19,
	Duplicate_Grant_Serial = 20,
	Zero_Grant_Serial      = 21,
	Clock_Went_Back        = 22,
	Zero_Issued_At         = 23,
	Proof_Expired          = 24,
	Proof_From_Future      = 25,
	Timestamp_Overflow     = 26,
}

// Ed25519 signature verifier callback supplied by the caller at the border.
Headless_Signature_Verify :: #type proc "contextless" (
	public_key: [HEADLESS_PROOF_KEY_BYTES]u8,
	message: []u8,
	signature: [HEADLESS_PROOF_SIGNATURE_BYTES]u8,
) -> bool

// Host-key-signed proof authorizing a wide grant on a headless machine where
// no person sits at the local keyboard.
Headless_Wide_Grant_Proof :: struct {
	version:          u32,
	machine_id:       [32]u8,
	principal_id:     u64,
	client_key:       [HEADLESS_PROOF_KEY_BYTES]u8,
	authorities_word: u64,
	nonce:            [HEADLESS_PROOF_NONCE_BYTES]u8,
	duration_ms:      u64,
	issued_at_ms:     u64,
	host_public_key:  [HEADLESS_PROOF_KEY_BYTES]u8,
	signature:        [HEADLESS_PROOF_SIGNATURE_BYTES]u8,
}

// Validated headless wide-grant outcome carrying Proof_Origin.Local_Host_Key
// and Proof_Kind.Host_Key_Signed.
Headless_Verified_Grant :: struct {
	machine_id:    [32]u8,
	principal_id:  u64,
	client_key:    [HEADLESS_PROOF_KEY_BYTES]u8,
	authorities:   Wide_Authorities,
	duration_ms:   u64,
	issued_at_ms:  u64,
	origin:        Proof_Origin,
	kind:          Proof_Kind,
	host_key_hash: blake3.Hash,
}

// Fixed-capacity ring cache of recently accepted headless proof nonces and
// their issued_at timestamps. When the ring wraps past capacity, evicted_floor_ms
// advances to the highest evicted issued_at_ms so evicted nonces cannot replay
// even within the freshness window.
Headless_Nonce_Cache :: struct {
	count:            u32,
	next_slot:        u32,
	evicted_floor_ms: u64,
	nonces:           [HEADLESS_NONCE_CACHE_CAPACITY][HEADLESS_PROOF_NONCE_BYTES]u8,
	issued_at_ms:     [HEADLESS_NONCE_CACHE_CAPACITY]u64,
}

// One tracked wide grant slot used by session-lock termination.
Active_Wide_Grant_Slot :: struct {
	grant_serial:      u64,
	principal_id:      u64,
	state:             Wide_Grant_State,
	authorities:       Wide_Authorities,
	started_at_ms:     u64,
	ends_at_ms:        u64,
	revocation_reason: Revocation_Reason,
	ended_at_ms:       u64,
}

// Fixed-capacity table of wide grants tracked for session-lock termination.
Wide_Grant_Session_Table :: struct {
	count:  u32,
	grants: [ACTIVE_WIDE_GRANT_TABLE_CAPACITY]Active_Wide_Grant_Slot,
}

// headless_proof_refusal_from_word converts a raw transport word into a
// Headless_Proof_Refusal, refusing every unknown word.
headless_proof_refusal_from_word :: proc "contextless" (word: u64) -> (refusal: Headless_Proof_Refusal, ok: bool) {
	return enum_word.member_of_word(Headless_Proof_Refusal, word)
}

// headless_is_zero_bytes reports whether every byte in slice is zero.
@(private = "file")
headless_is_zero_bytes :: proc "contextless" (bytes: []u8) -> bool {
	acc: u8 = 0
	for value in bytes {
		acc |= value
	}
	return acc == 0
}

// headless_constant_time_equal compares two equal-length byte slices without
// early exit on mismatch.
@(private = "file", optimization_mode = "none")
headless_constant_time_equal :: proc "contextless" (left, right: []u8) -> bool {
	if len(left) != len(right) {
		return false
	}
	diff: u8 = 0
	for index in 0 ..< len(left) {
		diff |= left[index] ~ right[index]
	}
	return diff == 0
}

@(private = "file")
nonce_cache_contains :: proc "contextless" (cache: ^Headless_Nonce_Cache, nonce: [HEADLESS_PROOF_NONCE_BYTES]u8) -> bool {
	if cache == nil {
		return false
	}
	local_nonce := nonce
	limit := min(int(cache.count), HEADLESS_NONCE_CACHE_CAPACITY)
	matched := false
	for index in 0 ..< limit {
		if headless_constant_time_equal(cache.nonces[index][:], local_nonce[:]) {
			matched = true
		}
	}
	return matched
}

@(private = "file")
nonce_cache_record :: proc "contextless" (cache: ^Headless_Nonce_Cache, nonce: [HEADLESS_PROOF_NONCE_BYTES]u8, issued_at_ms: u64) {
	if cache == nil {
		return
	}
	slot := int(cache.next_slot % HEADLESS_NONCE_CACHE_CAPACITY)
	if cache.count >= HEADLESS_NONCE_CACHE_CAPACITY {
		if cache.issued_at_ms[slot] > cache.evicted_floor_ms {
			cache.evicted_floor_ms = cache.issued_at_ms[slot]
		}
	}
	cache.nonces[slot] = nonce
	cache.issued_at_ms[slot] = issued_at_ms
	cache.next_slot = (cache.next_slot + 1) % HEADLESS_NONCE_CACHE_CAPACITY
	if cache.count < HEADLESS_NONCE_CACHE_CAPACITY {
		cache.count += 1
	}
}

// headless_proof_signing_bytes writes the canonical domain-separated bytes
// signed by the principal's host authority key into out_bytes.
headless_proof_signing_bytes :: proc "contextless" (
	proof: ^Headless_Wide_Grant_Proof,
	out_bytes: []u8,
) -> (written: int, refusal: Headless_Proof_Refusal) {
	if proof == nil {
		return 0, .Nil_Input
	}
	if len(out_bytes) < HEADLESS_PROOF_SIGNING_BYTES {
		return 0, .Buffer_Too_Small
	}
	offset := 0
	domain := HEADLESS_PROOF_DOMAIN_TAG
	copy(out_bytes[offset:][:len(domain)], domain)
	offset += len(domain)
	byte_order.write_u32_little_endian(out_bytes, offset, proof.version)
	offset += 4
	copy(out_bytes[offset:][:32], proof.machine_id[:])
	offset += 32
	byte_order.write_u64_little_endian(out_bytes, offset, proof.principal_id)
	offset += 8
	copy(out_bytes[offset:][:HEADLESS_PROOF_KEY_BYTES], proof.client_key[:])
	offset += HEADLESS_PROOF_KEY_BYTES
	byte_order.write_u64_little_endian(out_bytes, offset, proof.authorities_word)
	offset += 8
	copy(out_bytes[offset:][:HEADLESS_PROOF_NONCE_BYTES], proof.nonce[:])
	offset += HEADLESS_PROOF_NONCE_BYTES
	byte_order.write_u64_little_endian(out_bytes, offset, proof.duration_ms)
	offset += 8
	byte_order.write_u64_little_endian(out_bytes, offset, proof.issued_at_ms)
	offset += 8
	return offset, .None
}

// headless_proof_encode serializes proof into canonical little-endian wire
// bytes of length HEADLESS_PROOF_WIRE_BYTES.
headless_proof_encode :: proc "contextless" (
	proof: ^Headless_Wide_Grant_Proof,
	out_bytes: []u8,
) -> (written: int, refusal: Headless_Proof_Refusal) {
	if proof == nil {
		return 0, .Nil_Input
	}
	if len(out_bytes) < HEADLESS_PROOF_WIRE_BYTES {
		return 0, .Buffer_Too_Small
	}
	offset := 0
	byte_order.write_u32_little_endian(out_bytes, offset, proof.version)
	offset += 4
	copy(out_bytes[offset:][:32], proof.machine_id[:])
	offset += 32
	byte_order.write_u64_little_endian(out_bytes, offset, proof.principal_id)
	offset += 8
	copy(out_bytes[offset:][:HEADLESS_PROOF_KEY_BYTES], proof.client_key[:])
	offset += HEADLESS_PROOF_KEY_BYTES
	byte_order.write_u64_little_endian(out_bytes, offset, proof.authorities_word)
	offset += 8
	copy(out_bytes[offset:][:HEADLESS_PROOF_NONCE_BYTES], proof.nonce[:])
	offset += HEADLESS_PROOF_NONCE_BYTES
	byte_order.write_u64_little_endian(out_bytes, offset, proof.duration_ms)
	offset += 8
	byte_order.write_u64_little_endian(out_bytes, offset, proof.issued_at_ms)
	offset += 8
	copy(out_bytes[offset:][:HEADLESS_PROOF_KEY_BYTES], proof.host_public_key[:])
	offset += HEADLESS_PROOF_KEY_BYTES
	copy(out_bytes[offset:][:HEADLESS_PROOF_SIGNATURE_BYTES], proof.signature[:])
	offset += HEADLESS_PROOF_SIGNATURE_BYTES
	return offset, .None
}

// headless_proof_decode parses exact-length canonical little-endian wire bytes
// into a Headless_Wide_Grant_Proof without authenticating its signature.
headless_proof_decode :: proc "contextless" (bytes: []u8) -> (proof: Headless_Wide_Grant_Proof, refusal: Headless_Proof_Refusal) {
	if len(bytes) != HEADLESS_PROOF_WIRE_BYTES {
		return {}, .Bad_Wire_Length
	}
	offset := 0
	proof.version = byte_order.read_u32_little_endian(bytes, offset)
	offset += 4
	copy(proof.machine_id[:], bytes[offset:][:32])
	offset += 32
	proof.principal_id = byte_order.read_u64_little_endian(bytes, offset)
	offset += 8
	copy(proof.client_key[:], bytes[offset:][:HEADLESS_PROOF_KEY_BYTES])
	offset += HEADLESS_PROOF_KEY_BYTES
	proof.authorities_word = byte_order.read_u64_little_endian(bytes, offset)
	offset += 8
	copy(proof.nonce[:], bytes[offset:][:HEADLESS_PROOF_NONCE_BYTES])
	offset += HEADLESS_PROOF_NONCE_BYTES
	proof.duration_ms = byte_order.read_u64_little_endian(bytes, offset)
	offset += 8
	proof.issued_at_ms = byte_order.read_u64_little_endian(bytes, offset)
	offset += 8
	copy(proof.host_public_key[:], bytes[offset:][:HEADLESS_PROOF_KEY_BYTES])
	offset += HEADLESS_PROOF_KEY_BYTES
	copy(proof.signature[:], bytes[offset:][:HEADLESS_PROOF_SIGNATURE_BYTES])
	return proof, .None
}

// headless_wide_grant_proof_verify validates every field of a headless proof,
// enforces freshness against now_ms and max_age_ms, verifies its Ed25519
// signature over the canonical signing bytes against expected_host_public_key,
// and records the nonce in nonce_cache on success. Any refusal leaves
// nonce_cache unchanged.
headless_wide_grant_proof_verify :: proc "contextless" (
	proof: ^Headless_Wide_Grant_Proof,
	expected_machine_id: [32]u8,
	expected_principal_id: u64,
	expected_host_public_key: [HEADLESS_PROOF_KEY_BYTES]u8,
	now_ms: u64,
	nonce_cache: ^Headless_Nonce_Cache,
	verify_fn: Headless_Signature_Verify,
	max_age_ms: u64 = HEADLESS_PROOF_MAX_AGE_MS,
) -> (verified: Headless_Verified_Grant, refusal: Headless_Proof_Refusal) {
	if proof == nil {
		return {}, .Nil_Input
	}
	if verify_fn == nil {
		return {}, .Missing_Verifier
	}
	if proof.version != HEADLESS_PROOF_VERSION {
		return {}, .Bad_Version
	}
	exp_machine := expected_machine_id
	if headless_is_zero_bytes(exp_machine[:]) || headless_is_zero_bytes(proof.machine_id[:]) {
		return {}, .Zero_Machine_Id
	}
	if !headless_constant_time_equal(proof.machine_id[:], exp_machine[:]) {
		return {}, .Machine_Id_Mismatch
	}
	if proof.principal_id != expected_principal_id {
		return {}, .Principal_Mismatch
	}
	if headless_is_zero_bytes(proof.client_key[:]) {
		return {}, .Zero_Client_Key
	}
	authorities, auth_ok := wide_authorities_from_word(proof.authorities_word)
	if !auth_ok || (.Send_Input in authorities && .View_Screen not_in authorities) {
		return {}, .Bad_Authorities
	}
	if headless_is_zero_bytes(proof.nonce[:]) {
		return {}, .Zero_Nonce
	}
	if proof.duration_ms == 0 {
		return {}, .Duration_Zero
	}
	if proof.duration_ms > MAX_WIDE_GRANT_DURATION_MS {
		return {}, .Duration_Past_Bound
	}
	if proof.issued_at_ms == 0 {
		return {}, .Zero_Issued_At
	}
	if proof.issued_at_ms > max(u64) - proof.duration_ms {
		return {}, .Timestamp_Overflow
	}
	if now_ms == 0 {
		return {}, .Proof_Expired
	}
	if proof.issued_at_ms > now_ms {
		if proof.issued_at_ms - now_ms > HEADLESS_PROOF_MAX_FUTURE_SKEW_MS {
			return {}, .Proof_From_Future
		}
	} else {
		effective_max_age := min(max_age_ms, HEADLESS_PROOF_MAX_AGE_MS)
		if effective_max_age == 0 || now_ms - proof.issued_at_ms > effective_max_age {
			return {}, .Proof_Expired
		}
		if now_ms >= proof.issued_at_ms + proof.duration_ms {
			return {}, .Proof_Expired
		}
	}
	exp_host := expected_host_public_key
	if headless_is_zero_bytes(exp_host[:]) || headless_is_zero_bytes(proof.host_public_key[:]) {
		return {}, .Zero_Host_Key
	}
	if !headless_constant_time_equal(proof.host_public_key[:], exp_host[:]) {
		return {}, .Host_Key_Mismatch
	}
	if headless_is_zero_bytes(proof.signature[:]) {
		return {}, .Zero_Signature
	}
	if nonce_cache != nil && nonce_cache.evicted_floor_ms > 0 && proof.issued_at_ms <= nonce_cache.evicted_floor_ms {
		return {}, .Proof_Expired
	}
	if nonce_cache_contains(nonce_cache, proof.nonce) {
		return {}, .Replayed_Nonce
	}

	signing_buf: [HEADLESS_PROOF_SIGNING_BYTES]u8
	written, encode_refusal := headless_proof_signing_bytes(proof, signing_buf[:])
	if encode_refusal != .None {
		return {}, encode_refusal
	}
	if !verify_fn(expected_host_public_key, signing_buf[:written], proof.signature) {
		return {}, .Signature_Refused
	}

	nonce_cache_record(nonce_cache, proof.nonce, proof.issued_at_ms)
	verified = Headless_Verified_Grant {
		machine_id    = proof.machine_id,
		principal_id  = proof.principal_id,
		client_key    = proof.client_key,
		authorities   = authorities,
		duration_ms   = proof.duration_ms,
		issued_at_ms  = proof.issued_at_ms,
		origin        = .Local_Host_Key,
		kind          = .Host_Key_Signed,
		host_key_hash = blake3.hash(exp_host[:]),
	}
	return verified, .None
}

// wide_grant_session_register adds one active wide grant to the session table
// tracked for session-lock termination. Inactive or revoked slots are reclaimed
// cleanly; any refusal leaves table unchanged.
wide_grant_session_register :: proc "contextless" (
	table: ^Wide_Grant_Session_Table,
	grant_serial: u64,
	principal_id: u64,
	authorities: Wide_Authorities,
	started_at_ms: u64,
	duration_ms: u64,
) -> Headless_Proof_Refusal {
	if table == nil {
		return .Nil_Input
	}
	if grant_serial == 0 {
		return .Zero_Grant_Serial
	}
	word := wide_authorities_to_word(authorities)
	parsed, auth_ok := wide_authorities_from_word(word)
	if !auth_ok || (.Send_Input in parsed && .View_Screen not_in parsed) {
		return .Bad_Authorities
	}
	if duration_ms == 0 {
		return .Duration_Zero
	}
	if duration_ms > MAX_WIDE_GRANT_DURATION_MS {
		return .Duration_Past_Bound
	}
	if started_at_ms > max(u64) - duration_ms {
		return .Timestamp_Overflow
	}

	free_slot := -1
	for &slot, index in table.grants {
		if slot.grant_serial == 0 || slot.state != .Active {
			if free_slot < 0 {
				free_slot = index
			}
			continue
		}
		if slot.grant_serial == grant_serial {
			return .Duplicate_Grant_Serial
		}
	}
	if free_slot < 0 {
		return .Grant_Table_Full
	}

	table.grants[free_slot] = Active_Wide_Grant_Slot {
		grant_serial  = grant_serial,
		principal_id  = principal_id,
		state         = .Active,
		authorities   = parsed,
		started_at_ms = started_at_ms,
		ends_at_ms    = started_at_ms + duration_ms,
	}
	table.count = u32(wide_grant_session_total_active(table))
	return .None
}

@(private = "file")
wide_grant_session_total_active :: proc "contextless" (table: ^Wide_Grant_Session_Table) -> int {
	active := 0
	for slot in table.grants {
		if slot.grant_serial != 0 && slot.state == .Active {
			active += 1
		}
	}
	return active
}

// wide_grant_session_lock_end transitions every Active wide grant belonging to
// principal_id to Revoked with Revocation_Reason.Session_Locked, writes one
// collector Act_Stream_Record per terminated grant into out_end_records, and
// reclaims each terminated slot so subsequent grants can reuse the table.
// Active grants of other principals remain untouched. Any refusal leaves both
// table and out_end_records untouched.
wide_grant_session_lock_end :: proc "contextless" (
	table: ^Wide_Grant_Session_Table,
	principal_id: u64,
	lock_timestamp_ms: u64,
	out_end_records: []Act_Stream_Record,
) -> (ended_count: int, refusal: Headless_Proof_Refusal) {
	if table == nil {
		return 0, .Nil_Input
	}

	matching := 0
	for slot in table.grants {
		if slot.grant_serial == 0 || slot.state != .Active || slot.principal_id != principal_id {
			continue
		}
		if lock_timestamp_ms < slot.started_at_ms {
			return 0, .Clock_Went_Back
		}
		matching += 1
	}
	if matching > len(out_end_records) {
		return 0, .Buffer_Too_Small
	}

	written := 0
	for &slot in table.grants {
		if slot.grant_serial == 0 || slot.state != .Active || slot.principal_id != principal_id {
			continue
		}
		out_end_records[written] = Act_Stream_Record {
			grant_serial     = slot.grant_serial,
			principal_id     = slot.principal_id,
			timestamp_ms     = lock_timestamp_ms,
			producer_word    = u64(Act_Producer.Root_Service),
			act_kind_word    = u64(Act_Kind.Grant_Revoked),
			target_window_id = 0,
			detail_word_0    = u64(Revocation_Reason.Session_Locked),
			detail_word_1    = 0,
		}
		slot = {}
		written += 1
	}
	table.count = u32(wide_grant_session_total_active(table))

	return written, .None
}

// wide_grant_session_active_count reports how many Active wide grants remain
// for principal_id inside table.
wide_grant_session_active_count :: proc "contextless" (table: ^Wide_Grant_Session_Table, principal_id: u64) -> int {
	if table == nil {
		return 0
	}
	active := 0
	for slot in table.grants {
		if slot.grant_serial != 0 && slot.state == .Active && slot.principal_id == principal_id {
			active += 1
		}
	}
	return active
}
