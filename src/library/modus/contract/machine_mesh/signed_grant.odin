// Signed cross-principal grants and monotonic revocation lists
// (src/md/features/several_machines.md, "Sharing between two principals").
//
// A principal shares one store object/tree or one role contract with another
// principal by signing a grant record with an active per-machine signing key
// for the receiver's principal root public key. Because a signed grant leaves
// the machine that issued it, its lifetime is either bounded to at most one
// day (MAX_SHORT_GRANT_LIFE_MS) or bound to a signed, monotonic revocation
// list checked by the serving machine.
package machine_mesh

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/enum_word"

// Maximum lifetime in milliseconds of a short-lived grant that does not
// require an accompanying revocation list check (24 hours).
MAX_SHORT_GRANT_LIFE_MS :: u64(86_400_000)

// Inline capacity for revoked grant serials carried inside Revocation_List
// (observed common case: <= 64 active revocations per grantor verify in a
// stack signing buffer without caller scratch). Lists past this threshold
// move to external_serials up to the wire u16 format bound MAX_REVOKED_GRANTS
// and count accepted slow-tier validations in slow_tier_uses.
INLINE_REVOKED_GRANTS :: 64

// Format property: exact upper bound of the u16 revoked_count wire field.
MAX_REVOKED_GRANTS :: 65535

// Domain separation prefixes for Ed25519 signatures.
SIGNED_GRANT_SIGNING_DOMAIN :: "modus signed grant v1"
REVOCATION_LIST_SIGNING_DOMAIN :: "modus revocation list v1"

// Wire magics and versions.
SIGNED_GRANT_WIRE_MAGIC :: [4]u8{'M', 'S', 'G', 'T'}
REVOCATION_LIST_WIRE_MAGIC :: [4]u8{'M', 'R', 'V', 'L'}
SIGNED_GRANT_WIRE_VERSION :: u8(1)
REVOCATION_LIST_WIRE_VERSION :: u8(1)

// Canonical signing payload size of a Signed_Grant:
//   [0..21]    "modus signed grant v1"
//   [21]       0x00 separator
//   [22]       wire version (1)
//   [23]       target_kind (1 = Store_Object, 2 = Role_Contract)
//   [24..32]   grant_serial (u64 LE)
//   [32..64]   grantor_root_public_key (32 bytes)
//   [64..96]   grantor_signing_public_key (32 bytes)
//   [96..128]  serving_machine_id (32 bytes)
//   [128..160] grantee_root_public_key (32 bytes)
//   [160..192] target_hash (32 bytes)
//   [192..200] rights word (u64 LE)
//   [200..208] issued_at_ms (u64 LE)
//   [208..216] expires_at_ms (u64 LE)
//   [216..224] revocation_list_epoch (u64 LE)
SIGNED_GRANT_SIGNING_BYTES_SIZE :: len(SIGNED_GRANT_SIGNING_DOMAIN) + 1 + 1 + 1 + 8 + PUBLIC_KEY_SIZE * 4 + blake3.HASH_SIZE + 8 * 4

// Wire size of a Signed_Grant:
//   [0..4]     magic "MSGT"
//   [4]        version (1)
//   [5]        target_kind
//   [6..8]     reserved (0)
//   [8..16]    grant_serial (u64 LE)
//   [16..48]   grantor_root_public_key
//   [48..80]   grantor_signing_public_key
//   [80..112]  serving_machine_id
//   [112..144] grantee_root_public_key
//   [144..176] target_hash
//   [176..184] rights word (u64 LE)
//   [184..192] issued_at_ms (u64 LE)
//   [192..200] expires_at_ms (u64 LE)
//   [200..208] revocation_list_epoch (u64 LE)
//   [208..272] signature (64 bytes)
SIGNED_GRANT_WIRE_SIZE :: 4 + 1 + 1 + 2 + 8 + PUBLIC_KEY_SIZE * 4 + blake3.HASH_SIZE + 8 * 4 + SIGNATURE_SIZE

// Canonical signing payload header of a Revocation_List:
//   [0..24]   "modus revocation list v1"
//   [24]      0x00 separator
//   [25]      version (1)
//   [26..28]  revoked_count (u16 LE)
//   [28..32]  reserved (0)
//   [32..64]  grantor_root_public_key (32 bytes)
//   [64..96]  signer_public_key (32 bytes)
//   [96..104] epoch (u64 LE)
//   followed by revoked_count * 8 bytes (u64 LE serials, strictly increasing)
REVOCATION_LIST_SIGNING_HEADER_SIZE :: len(REVOCATION_LIST_SIGNING_DOMAIN) + 1 + 1 + 2 + 4 + PUBLIC_KEY_SIZE * 2 + 8
INLINE_REVOCATION_LIST_SIGNING_BYTES :: REVOCATION_LIST_SIGNING_HEADER_SIZE + INLINE_REVOKED_GRANTS * 8
MAX_REVOCATION_LIST_SIGNING_BYTES :: REVOCATION_LIST_SIGNING_HEADER_SIZE + MAX_REVOKED_GRANTS * 8

#assert(SIGNED_GRANT_SIGNING_BYTES_SIZE == 224)
#assert(SIGNED_GRANT_WIRE_SIZE == 272)
#assert(REVOCATION_LIST_SIGNING_HEADER_SIZE == 104)

// Closed set of access rights carried in a signed cross-principal grant.
Share_Right :: enum u64 {
	Read  = 0,
	Write = 1,
}
Share_Rights :: bit_set[Share_Right; u64]

// Closed kind of resource named by a signed grant.
Grant_Target_Kind :: enum u8 {
	Store_Object  = 1,
	Role_Contract = 2,
}

// Signed grant issued by a grantor's active per-machine signing key to one
// receiver principal root key, scoped to one serving machine and one target.
Signed_Grant :: struct {
	grant_serial:               u64,
	grantor_root_public_key:    Principal_Root_Public_Key,
	grantor_signing_public_key: [PUBLIC_KEY_SIZE]u8,
	serving_machine_id:         [PUBLIC_KEY_SIZE]u8,
	grantee_root_public_key:    Principal_Root_Public_Key,
	target_kind:                Grant_Target_Kind,
	target_hash:                blake3.Hash,
	rights:                     Share_Rights,
	issued_at_ms:               u64,
	expires_at_ms:              u64,
	revocation_list_epoch:      u64,
	signature:                  [SIGNATURE_SIZE]u8,
}

// Monotonic list of revoked grant serials signed by an active per-machine
// signing key of the grantor. Lists of at most INLINE_REVOKED_GRANTS (64)
// entries live inline in revoked_serials; larger lists supply external_serials
// (length >= revoked_count, up to MAX_REVOKED_GRANTS) and validate with a
// caller-supplied signing_scratch buffer.
Revocation_List :: struct {
	grantor_root_public_key: Principal_Root_Public_Key,
	signer_public_key:       [PUBLIC_KEY_SIZE]u8,
	epoch:                   u64,
	revoked_count:           u16,
	revoked_serials:         [INLINE_REVOKED_GRANTS]u64,
	external_serials:        []u64,
	slow_tier_uses:          u64,
	signature:               [SIGNATURE_SIZE]u8,
}

// Closed status returned by signed_grant_check and grant wire helpers.
Grant_Check_Status :: enum u8 {
	Accepted                                 = 1,
	Refused_Nil_Input                        = 2,
	Refused_Zero_Serial                      = 3,
	Refused_Zero_Key                         = 4,
	Refused_Zero_Target_Hash                 = 5,
	Refused_Bad_Target_Kind                  = 6,
	Refused_Bad_Rights                       = 7,
	Refused_Bad_Lifetime                     = 8,
	Refused_Wrong_Grantor                    = 9,
	Refused_Wrong_Serving_Machine            = 10,
	Refused_Wrong_Grantee                    = 11,
	Refused_Grantor_Key_Not_Active           = 12,
	Refused_Invalid_Signature                = 13,
	Refused_Long_Grant_Without_Revocation    = 14,
	Refused_Bad_Revocation_List              = 15,
	Refused_Stale_Revocation_List            = 16,
	Refused_Revoked                          = 17,
	Refused_Not_Yet_Valid                    = 18,
	Refused_Expired                          = 19,
	Refused_Buffer_Too_Small                 = 20,
	Refused_Malformed_Wire                   = 21,
	Refused_Serving_Machine_Not_Active       = 22,
}

// Closed status returned by revocation_list_validate and revocation updates.
Revocation_List_Status :: enum u8 {
	Accepted                   = 1,
	Refused_Nil_Input          = 2,
	Refused_Zero_Key           = 3,
	Refused_Zero_Epoch         = 4,
	Refused_Replay_Or_Downgrade = 5,
	Refused_Too_Many_Entries   = 6,
	Refused_Zero_Serial        = 7,
	Refused_Not_Strictly_Sorted = 8,
	Refused_Wrong_Grantor      = 9,
	Refused_Signer_Not_Active  = 10,
	Refused_Invalid_Signature  = 11,
	Refused_Buffer_Too_Small   = 12,
}

// share_rights_word encodes a Share_Rights bit_set as its transport u64 word.
share_rights_word :: proc "contextless" (rights: Share_Rights) -> u64 {
	return transmute(u64)rights
}

// share_rights_of_word is the single border converting a transport word into a
// non-empty Share_Rights bit_set. Zero rights, unknown bits, and Write without
// Read are refused (src/md/features/several_machines.md, "Sharing between two
// principals").
share_rights_of_word :: proc "contextless" (word: u64) -> (rights: Share_Rights, ok: bool) {
	known := share_rights_word({.Read, .Write})
	if word == 0 || word & ~known != 0 {
		return {}, false
	}
	rights = transmute(Share_Rights)word
	if .Write in rights && .Read not_in rights {
		return {}, false
	}
	return rights, true
}

// grant_target_kind_of_word is the single border converting a transport word
// into a Grant_Target_Kind member.
grant_target_kind_of_word :: proc "contextless" (word: u64) -> (kind: Grant_Target_Kind, ok: bool) {
	return enum_word.member_of_word(Grant_Target_Kind, word)
}

// validate_signed_grant_structure checks all local structural fields of grant.
@(private)
validate_signed_grant_structure :: proc "contextless" (grant: ^Signed_Grant) -> (checked_kind: Grant_Target_Kind, status: Grant_Check_Status) {
	if grant == nil {
		return {}, .Refused_Nil_Input
	}
	if grant.grant_serial == 0 {
		return {}, .Refused_Zero_Serial
	}
	if key_is_zero(grant.grantor_root_public_key) ||
		key_is_zero(grant.grantor_signing_public_key) ||
		key_is_zero(grant.serving_machine_id) ||
		key_is_zero(grant.grantee_root_public_key) {
		return {}, .Refused_Zero_Key
	}
	if key_is_zero(grant.target_hash) {
		return {}, .Refused_Zero_Target_Hash
	}
	parsed_kind, kind_ok := grant_target_kind_of_word(u64(grant.target_kind))
	if !kind_ok {
		return {}, .Refused_Bad_Target_Kind
	}
	if _, rights_ok := share_rights_of_word(share_rights_word(grant.rights)); !rights_ok {
		return {}, .Refused_Bad_Rights
	}
	if grant.expires_at_ms <= grant.issued_at_ms {
		return {}, .Refused_Bad_Lifetime
	}
	return parsed_kind, .Accepted
}

// signed_grant_signing_bytes builds the exact canonical 224-byte domain-separated
// payload signed by grantor_signing_public_key for a Signed_Grant.
signed_grant_signing_bytes :: proc "contextless" (
	grant: ^Signed_Grant,
) -> (signing_bytes: [SIGNED_GRANT_SIGNING_BYTES_SIZE]u8, status: Grant_Check_Status) {
	checked_kind, structure_status := validate_signed_grant_structure(grant)
	if structure_status != .Accepted {
		return {}, structure_status
	}
	domain := SIGNED_GRANT_SIGNING_DOMAIN
	copy(signing_bytes[0:len(domain)], domain)
	signing_bytes[21] = 0
	signing_bytes[22] = SIGNED_GRANT_WIRE_VERSION
	signing_bytes[23] = u8(checked_kind)
	byte_order.write_u64_little_endian(signing_bytes[:], 24, grant.grant_serial)
	copy(signing_bytes[32:64], grant.grantor_root_public_key[:])
	copy(signing_bytes[64:96], grant.grantor_signing_public_key[:])
	copy(signing_bytes[96:128], grant.serving_machine_id[:])
	copy(signing_bytes[128:160], grant.grantee_root_public_key[:])
	copy(signing_bytes[160:192], grant.target_hash[:])
	byte_order.write_u64_little_endian(signing_bytes[:], 192, share_rights_word(grant.rights))
	byte_order.write_u64_little_endian(signing_bytes[:], 200, grant.issued_at_ms)
	byte_order.write_u64_little_endian(signing_bytes[:], 208, grant.expires_at_ms)
	byte_order.write_u64_little_endian(signing_bytes[:], 216, grant.revocation_list_epoch)
	return signing_bytes, .Accepted
}

// revocation_list_signing_bytes_size returns the exact signing payload length
// in bytes for a Revocation_List carrying revoked_count serials.
revocation_list_signing_bytes_size :: proc "contextless" (revoked_count: u16) -> int {
	return REVOCATION_LIST_SIGNING_HEADER_SIZE + int(revoked_count) * 8
}

// revocation_list_serials returns the active slice of revoked serials and
// whether list uses the slower external_serials tier. Returns ok == false
// (fail closed) when revoked_count exceeds the active backing capacity.
@(private)
revocation_list_serials :: proc "contextless" (list: ^Revocation_List) -> (serials: []u64, slow_tier: bool, ok: bool) {
	if list == nil {
		return nil, false, false
	}
	count := int(list.revoked_count)
	if count > MAX_REVOKED_GRANTS {
		return nil, false, false
	}
	if len(list.external_serials) > 0 {
		if count > len(list.external_serials) {
			return nil, true, false
		}
		return list.external_serials[:count], true, true
	}
	if count > INLINE_REVOKED_GRANTS {
		return nil, true, false
	}
	return list.revoked_serials[:count], false, true
}

// validate_revocation_list_structure checks all structural invariants of list
// (keys, epoch, entry count within active tier, non-zero strictly sorted serials).
@(private)
validate_revocation_list_structure :: proc "contextless" (list: ^Revocation_List) -> Revocation_List_Status {
	if list == nil {
		return .Refused_Nil_Input
	}
	if key_is_zero(list.grantor_root_public_key) || key_is_zero(list.signer_public_key) {
		return .Refused_Zero_Key
	}
	if list.epoch == 0 {
		return .Refused_Zero_Epoch
	}
	serials, _, ok := revocation_list_serials(list)
	if !ok {
		return .Refused_Too_Many_Entries
	}
	for index in 0 ..< len(serials) {
		serial := serials[index]
		if serial == 0 {
			return .Refused_Zero_Serial
		}
		if index > 0 && serial <= serials[index - 1] {
			return .Refused_Not_Strictly_Sorted
		}
	}
	return .Accepted
}

// revocation_list_signing_bytes writes the canonical domain-separated bytes
// signed by an active per-machine signing key of the grantor.
revocation_list_signing_bytes :: proc "contextless" (
	list: ^Revocation_List,
	output: []u8,
) -> (written: int, status: Revocation_List_Status) {
	structure_status := validate_revocation_list_structure(list)
	if structure_status != .Accepted {
		return 0, structure_status
	}
	serials, _, _ := revocation_list_serials(list)
	required := revocation_list_signing_bytes_size(list.revoked_count)
	if len(output) < required {
		return 0, .Refused_Buffer_Too_Small
	}
	domain := REVOCATION_LIST_SIGNING_DOMAIN
	copy(output[0:len(domain)], domain)
	output[24] = 0
	output[25] = REVOCATION_LIST_WIRE_VERSION
	byte_order.write_u16_little_endian(output, 26, list.revoked_count)
	for index in 28 ..< 32 {
		output[index] = 0
	}
	copy(output[32:64], list.grantor_root_public_key[:])
	copy(output[64:96], list.signer_public_key[:])
	byte_order.write_u64_little_endian(output, 96, list.epoch)
	for index in 0 ..< len(serials) {
		offset := REVOCATION_LIST_SIGNING_HEADER_SIZE + index * 8
		byte_order.write_u64_little_endian(output, offset, serials[index])
	}
	return required, .Accepted
}

// revocation_list_validate checks a revocation list against the grantor's
// machine list, an optional previous revocation list (enforcing monotonic
// epochs), and the signer's Ed25519 signature. Lists of at most
// INLINE_REVOKED_GRANTS serials verify in an inline stack buffer; larger lists
// require a caller-supplied signing_scratch of at least
// revocation_list_signing_bytes_size(candidate.revoked_count) bytes and fail
// closed with Refused_Buffer_Too_Small when scratch is absent or too short.
revocation_list_validate :: proc "contextless" (
	grantor_machine_list: ^Signed_Machine_List,
	current: ^Revocation_List,
	candidate: ^Revocation_List,
	verify_signature: Signature_Verify_Proc,
	user_data: rawptr = nil,
	signing_scratch: []u8 = nil,
) -> Revocation_List_Status {
	if grantor_machine_list == nil || candidate == nil {
		return .Refused_Nil_Input
	}
	structure_status := validate_revocation_list_structure(candidate)
	if structure_status != .Accepted {
		return structure_status
	}
	if !keys_equal_constant_time(candidate.grantor_root_public_key, grantor_machine_list.principal_root_public_key) {
		return .Refused_Wrong_Grantor
	}
	if current != nil {
		if !keys_equal_constant_time(current.grantor_root_public_key, candidate.grantor_root_public_key) {
			return .Refused_Wrong_Grantor
		}
		if candidate.epoch <= current.epoch {
			return .Refused_Replay_Or_Downgrade
		}
	}
	if _, active := machine_list_find_active_by_signing_key(grantor_machine_list, candidate.signer_public_key); !active {
		return .Refused_Signer_Not_Active
	}
	if verify_signature == nil {
		return .Refused_Invalid_Signature
	}
	_, slow_tier, _ := revocation_list_serials(candidate)
	required := revocation_list_signing_bytes_size(candidate.revoked_count)
	inline_buffer: [INLINE_REVOCATION_LIST_SIGNING_BYTES]u8
	signing_slice: []u8
	if required <= INLINE_REVOCATION_LIST_SIGNING_BYTES {
		signing_slice = inline_buffer[:]
	} else {
		if len(signing_scratch) < required {
			return .Refused_Buffer_Too_Small
		}
		signing_slice = signing_scratch[:required]
	}
	signing_length, signing_status := revocation_list_signing_bytes(candidate, signing_slice)
	if signing_status != .Accepted {
		return signing_status
	}
	if !verify_signature(candidate.signer_public_key, signing_slice[:signing_length], candidate.signature, user_data) {
		return .Refused_Invalid_Signature
	}
	if slow_tier {
		candidate.slow_tier_uses += 1
	}
	return .Accepted
}

// revocation_list_apply_update validates candidate and replaces state^ only
// when accepted; refused updates leave state^ unchanged.
revocation_list_apply_update :: proc "contextless" (
	grantor_machine_list: ^Signed_Machine_List,
	state: ^Revocation_List,
	has_current: bool,
	candidate: ^Revocation_List,
	verify_signature: Signature_Verify_Proc,
	user_data: rawptr = nil,
	signing_scratch: []u8 = nil,
) -> Revocation_List_Status {
	if state == nil || candidate == nil {
		return .Refused_Nil_Input
	}
	current_ptr: ^Revocation_List = has_current ? state : nil
	status := revocation_list_validate(grantor_machine_list, current_ptr, candidate, verify_signature, user_data, signing_scratch)
	if status != .Accepted {
		return status
	}
	state^ = candidate^
	return .Accepted
}

// revocation_list_contains_serial checks whether serial is listed in a
// structurally validated Revocation_List via binary search.
revocation_list_contains_serial :: proc "contextless" (list: ^Revocation_List, serial: u64) -> bool {
	if list == nil || serial == 0 {
		return false
	}
	serials, _, ok := revocation_list_serials(list)
	if !ok {
		return false
	}
	low := 0
	high := len(serials)
	for low < high {
		middle := low + (high - low) / 2
		candidate := serials[middle]
		if candidate == serial {
			return true
		}
		if candidate < serial {
			low = middle + 1
		} else {
			high = middle
		}
	}
	return false
}

// signed_grant_check strictly verifies a cross-principal signed grant on the
// serving machine.
//
// Enforces:
//   - structural validity (non-zero serial/keys/target, valid kind, non-zero rights)
//   - matching grantor root key, serving machine id, and grantee root key
//   - grantor_signing_public_key is Active in grantor_machine_list
//   - valid Ed25519 signature over the domain-separated grant payload
//   - lifetime <= MAX_SHORT_GRANT_LIFE_MS (1 day), OR a valid non-stale signed
//     Revocation_List checked for grant_serial
//   - if a Revocation_List is supplied for a short-lived grant, it is still
//     verified and consulted so early revocations take effect immediately
//   - issued_at_ms <= now_ms < expires_at_ms
signed_grant_check :: proc "contextless" (
	grant: ^Signed_Grant,
	grantor_machine_list: ^Signed_Machine_List,
	serving_machine_id: [PUBLIC_KEY_SIZE]u8,
	expected_grantee_root_key: Principal_Root_Public_Key,
	now_ms: u64,
	revocation_list: ^Revocation_List,
	verify_signature: Signature_Verify_Proc,
	user_data: rawptr = nil,
	revocation_scratch: []u8 = nil,
) -> Grant_Check_Status {
	if grant == nil || grantor_machine_list == nil {
		return .Refused_Nil_Input
	}
	_, structure_status := validate_signed_grant_structure(grant)
	if structure_status != .Accepted {
		return structure_status
	}
	if key_is_zero(serving_machine_id) || key_is_zero(expected_grantee_root_key) {
		return .Refused_Zero_Key
	}
	if !keys_equal_constant_time(grant.grantor_root_public_key, grantor_machine_list.principal_root_public_key) {
		return .Refused_Wrong_Grantor
	}
	if !keys_equal_constant_time(grant.serving_machine_id, serving_machine_id) {
		return .Refused_Wrong_Serving_Machine
	}
	if _, serving_active := machine_list_find_active_by_machine_id(grantor_machine_list, serving_machine_id); !serving_active {
		return .Refused_Serving_Machine_Not_Active
	}
	if !keys_equal_constant_time(grant.grantee_root_public_key, expected_grantee_root_key) {
		return .Refused_Wrong_Grantee
	}
	if _, active := machine_list_find_active_by_signing_key(grantor_machine_list, grant.grantor_signing_public_key); !active {
		return .Refused_Grantor_Key_Not_Active
	}
	if verify_signature == nil {
		return .Refused_Invalid_Signature
	}
	signing_bytes, signing_status := signed_grant_signing_bytes(grant)
	if signing_status != .Accepted {
		return signing_status
	}
	if !verify_signature(grant.grantor_signing_public_key, signing_bytes[:], grant.signature, user_data) {
		return .Refused_Invalid_Signature
	}
	lifetime_ms := grant.expires_at_ms - grant.issued_at_ms
	requires_revocation_check := lifetime_ms > MAX_SHORT_GRANT_LIFE_MS || grant.revocation_list_epoch > 0
	if requires_revocation_check {
		if grant.revocation_list_epoch == 0 || revocation_list == nil {
			return .Refused_Long_Grant_Without_Revocation
		}
	}
	if revocation_list != nil {
		rev_status := revocation_list_validate(grantor_machine_list, nil, revocation_list, verify_signature, user_data, revocation_scratch)
		if rev_status != .Accepted {
			return .Refused_Bad_Revocation_List
		}
		if grant.revocation_list_epoch > 0 && revocation_list.epoch < grant.revocation_list_epoch {
			return .Refused_Stale_Revocation_List
		}
		if revocation_list_contains_serial(revocation_list, grant.grant_serial) {
			return .Refused_Revoked
		}
	}
	if now_ms < grant.issued_at_ms {
		return .Refused_Not_Yet_Valid
	}
	if now_ms >= grant.expires_at_ms {
		return .Refused_Expired
	}
	return .Accepted
}

// signed_grant_encode serializes a structurally valid Signed_Grant into output.
// Refused calls leave output unchanged.
signed_grant_encode :: proc "contextless" (grant: ^Signed_Grant, output: []u8) -> (written: int, status: Grant_Check_Status) {
	checked_kind, structure_status := validate_signed_grant_structure(grant)
	if structure_status != .Accepted {
		return 0, structure_status
	}
	if len(output) < SIGNED_GRANT_WIRE_SIZE {
		return 0, .Refused_Buffer_Too_Small
	}
	magic := SIGNED_GRANT_WIRE_MAGIC
	copy(output[0:4], magic[:])
	output[4] = SIGNED_GRANT_WIRE_VERSION
	output[5] = u8(checked_kind)
	output[6] = 0
	output[7] = 0
	byte_order.write_u64_little_endian(output, 8, grant.grant_serial)
	copy(output[16:48], grant.grantor_root_public_key[:])
	copy(output[48:80], grant.grantor_signing_public_key[:])
	copy(output[80:112], grant.serving_machine_id[:])
	copy(output[112:144], grant.grantee_root_public_key[:])
	copy(output[144:176], grant.target_hash[:])
	byte_order.write_u64_little_endian(output, 176, share_rights_word(grant.rights))
	byte_order.write_u64_little_endian(output, 184, grant.issued_at_ms)
	byte_order.write_u64_little_endian(output, 192, grant.expires_at_ms)
	byte_order.write_u64_little_endian(output, 200, grant.revocation_list_epoch)
	copy(output[208:272], grant.signature[:])
	return SIGNED_GRANT_WIRE_SIZE, .Accepted
}

// signed_grant_decode strictly validates and decodes a wire-encoded Signed_Grant.
signed_grant_decode :: proc "contextless" (input: []u8) -> (grant: Signed_Grant, status: Grant_Check_Status) {
	if len(input) != SIGNED_GRANT_WIRE_SIZE {
		return {}, .Refused_Malformed_Wire
	}
	magic := SIGNED_GRANT_WIRE_MAGIC
	for index in 0 ..< len(magic) {
		if input[index] != magic[index] {
			return {}, .Refused_Malformed_Wire
		}
	}
	if input[4] != SIGNED_GRANT_WIRE_VERSION || input[6] != 0 || input[7] != 0 {
		return {}, .Refused_Malformed_Wire
	}
	checked_kind, kind_ok := grant_target_kind_of_word(u64(input[5]))
	if !kind_ok {
		return {}, .Refused_Bad_Target_Kind
	}
	rights, rights_ok := share_rights_of_word(byte_order.read_u64_little_endian(input, 176))
	if !rights_ok {
		return {}, .Refused_Bad_Rights
	}
	grant.target_kind = checked_kind
	grant.grant_serial = byte_order.read_u64_little_endian(input, 8)
	copy(grant.grantor_root_public_key[:], input[16:48])
	copy(grant.grantor_signing_public_key[:], input[48:80])
	copy(grant.serving_machine_id[:], input[80:112])
	copy(grant.grantee_root_public_key[:], input[112:144])
	copy(grant.target_hash[:], input[144:176])
	grant.rights = rights
	grant.issued_at_ms = byte_order.read_u64_little_endian(input, 184)
	grant.expires_at_ms = byte_order.read_u64_little_endian(input, 192)
	grant.revocation_list_epoch = byte_order.read_u64_little_endian(input, 200)
	copy(grant.signature[:], input[208:272])
	_, structure_status := validate_signed_grant_structure(&grant)
	if structure_status != .Accepted {
		return {}, structure_status
	}
	return grant, .Accepted
}
