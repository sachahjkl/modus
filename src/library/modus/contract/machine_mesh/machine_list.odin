// Per-machine keys and the signed machine list of a principal
// (src/md/features/several_machines.md, "A principal across machines").
//
// Each principal has one offline root public key. Every machine that joins
// the principal generates and seals its own signing and transport keys locally;
// no secret key crosses the network. The offline root key signs a monotonic
// machine list naming each machine's identity key, per-machine signing key,
// transport key, allowed uses, TPM attestation flag, lifecycle state, and
// timestamps.
//
// Revoking a stolen machine signs a new list with a higher sequence number
// marking that machine Revoked (or omitting it) while preserving the principal's
// root identity across every remaining machine.
package machine_mesh

import "modus:contract/byte_order"
import "modus:contract/enum_word"
import "modus:contract/remote"

// Maximum machines listed in a single signed machine list.
MAX_MACHINE_LIST_ENTRIES :: 16

// Wire magic and version for canonical binary encoding of a signed machine list.
MACHINE_LIST_WIRE_MAGIC :: [4]u8{'M', 'M', 'L', 'S'}
MACHINE_LIST_WIRE_VERSION :: u8(1)

// Domain separation prefix for the offline root key signature over a machine list.
MACHINE_LIST_SIGNING_DOMAIN :: "modus machine list v1"

// Fixed canonical sizes of header, entry, signing payload, and wire record.
//
// Signing payload layout:
//   [0..21]   "modus machine list v1"
//   [21]      0x00 separator
//   [22]      wire version (1)
//   [23]      entry_count (1 ..= MAX_MACHINE_LIST_ENTRIES)
//   [24..56]  principal_root_public_key (32 bytes)
//   [56..64]  sequence_number (u64 LE)
//   followed by entry_count * MACHINE_ENTRY_CANONICAL_SIZE bytes:
//     [0..32]    machine_id (32 bytes)
//     [32..64]   signing_public_key (32 bytes)
//     [64..96]   transport_public_key (32 bytes)
//     [96..104]  uses word (u64 LE)
//     [104]      tpm_attested (0 or 1)
//     [105]      state (1 = Active, 2 = Revoked)
//     [106..112] reserved zero bytes (6 bytes)
//     [112..120] added_at_ms (u64 LE)
//     [120..128] revoked_at_ms (u64 LE)
MACHINE_LIST_SIGNING_HEADER_SIZE :: len(MACHINE_LIST_SIGNING_DOMAIN) + 1 + 1 + 1 + PUBLIC_KEY_SIZE + 8
MACHINE_ENTRY_CANONICAL_SIZE :: PUBLIC_KEY_SIZE * 3 + 8 + 1 + 1 + 6 + 8 + 8
MAX_MACHINE_LIST_SIGNING_BYTES :: MACHINE_LIST_SIGNING_HEADER_SIZE + MAX_MACHINE_LIST_ENTRIES * MACHINE_ENTRY_CANONICAL_SIZE

// Wire format layout:
//   [0..4]    magic "MMLS"
//   [4]       version (1)
//   [5]       entry_count
//   [6..8]    reserved zero bytes
//   [8..40]   principal_root_public_key
//   [40..48]  sequence_number (u64 LE)
//   [48..112] signature (64 bytes)
//   [112..]   entry_count * MACHINE_ENTRY_CANONICAL_SIZE bytes
MACHINE_LIST_WIRE_HEADER_SIZE :: 4 + 1 + 1 + 2 + PUBLIC_KEY_SIZE + 8 + SIGNATURE_SIZE
MAX_MACHINE_LIST_WIRE_BYTES :: MACHINE_LIST_WIRE_HEADER_SIZE + MAX_MACHINE_LIST_ENTRIES * MACHINE_ENTRY_CANONICAL_SIZE

#assert(MACHINE_LIST_SIGNING_HEADER_SIZE == 64)
#assert(MACHINE_ENTRY_CANONICAL_SIZE == 128)
#assert(MACHINE_LIST_WIRE_HEADER_SIZE == 112)

// Closed lifecycle state of one machine entry in a principal's machine list.
Machine_Entry_State :: enum u8 {
	Active  = 1,
	Revoked = 2,
}

// One machine belonging to a principal, with its own locally generated keys.
Machine_Entry :: struct {
	machine_id:           [PUBLIC_KEY_SIZE]u8,
	signing_public_key:   [PUBLIC_KEY_SIZE]u8,
	transport_public_key: [PUBLIC_KEY_SIZE]u8,
	uses:                 remote.Client_Uses,
	tpm_attested:         bool,
	state:                Machine_Entry_State,
	added_at_ms:          u64,
	revoked_at_ms:        u64,
}

// Monotonic record signed by the offline principal root key.
Signed_Machine_List :: struct {
	principal_root_public_key: Principal_Root_Public_Key,
	sequence_number:           u64,
	entry_count:               u8,
	entries:                   [MAX_MACHINE_LIST_ENTRIES]Machine_Entry,
	signature:                 [SIGNATURE_SIZE]u8,
}

// Policy controlling whether a machine without TPM attestation may join as an
// active entry. Zero value refuses non-TPM machines by default.
Join_Policy :: struct {
	allow_without_tpm: bool,
}

// Closed outcome of validating or applying a signed machine list.
Machine_List_Status :: enum u8 {
	Accepted                       = 1,
	Accepted_Without_Tpm_Warning   = 2,
	Refused_Nil_Input              = 3,
	Refused_Zero_Root_Key          = 4,
	Refused_Zero_Sequence_Number   = 5,
	Refused_Replay_Or_Downgrade    = 6,
	Refused_Empty_List             = 7,
	Refused_Too_Many_Entries       = 8,
	Refused_Bad_Entry_State        = 9,
	Refused_Zero_Key               = 10,
	Refused_Duplicate_Machine_Id   = 11,
	Refused_Duplicate_Signing_Key  = 12,
	Refused_Duplicate_Transport_Key = 13,
	Refused_Bad_Uses               = 14,
	Refused_Bad_Timestamps         = 15,
	Refused_Without_Tpm            = 16,
	Refused_Root_Key_Mismatch      = 17,
	Refused_Invalid_Signature      = 18,
	Refused_Buffer_Too_Small       = 19,
	Refused_Malformed_Wire         = 20,
}

// machine_entry_state_of_word is the single border converting a transport word
// into a Machine_Entry_State member.
machine_entry_state_of_word :: proc "contextless" (word: u64) -> (state: Machine_Entry_State, ok: bool) {
	return enum_word.member_of_word(Machine_Entry_State, word)
}

// machine_list_status_accepted reports whether status grants acceptance (either
// clean or with the explicit non-TPM warning).
machine_list_status_accepted :: proc "contextless" (status: Machine_List_Status) -> bool {
	return status == .Accepted || status == .Accepted_Without_Tpm_Warning
}

// default_join_policy returns the safe default policy: machines without TPM
// attestation are refused.
default_join_policy :: proc "contextless" () -> Join_Policy {
	return Join_Policy{allow_without_tpm = false}
}

// write_canonical_machine_entry serializes one validated Machine_Entry into an
// exact 128-byte slice.
@(private)
write_canonical_machine_entry :: proc "contextless" (entry: ^Machine_Entry, destination: []u8) {
	copy(destination[0:32], entry.machine_id[:])
	copy(destination[32:64], entry.signing_public_key[:])
	copy(destination[64:96], entry.transport_public_key[:])
	byte_order.write_u64_little_endian(destination, 96, remote.client_uses_word(entry.uses))
	destination[104] = entry.tpm_attested ? 1 : 0
	destination[105] = u8(entry.state)
	for index in 106 ..< 112 {
		destination[index] = 0
	}
	byte_order.write_u64_little_endian(destination, 112, entry.added_at_ms)
	byte_order.write_u64_little_endian(destination, 120, entry.revoked_at_ms)
}

// validate_machine_list_structure checks every structural invariant of list
// without checking the signature or comparing against a previous sequence.
// It also reports whether any active entry lacks TPM attestation.
@(private)
validate_machine_list_structure :: proc "contextless" (list: ^Signed_Machine_List) -> (has_active_without_tpm: bool, status: Machine_List_Status) {
	if list == nil {
		return false, .Refused_Nil_Input
	}
	if key_is_zero(list.principal_root_public_key) {
		return false, .Refused_Zero_Root_Key
	}
	if list.sequence_number == 0 {
		return false, .Refused_Zero_Sequence_Number
	}
	if list.entry_count == 0 {
		return false, .Refused_Empty_List
	}
	if int(list.entry_count) > MAX_MACHINE_LIST_ENTRIES {
		return false, .Refused_Too_Many_Entries
	}
	count := int(list.entry_count)
	for index in 0 ..< count {
		entry := &list.entries[index]
		checked_state, state_ok := machine_entry_state_of_word(u64(entry.state))
		if !state_ok {
			return false, .Refused_Bad_Entry_State
		}
		if key_is_zero(entry.machine_id) || key_is_zero(entry.signing_public_key) || key_is_zero(entry.transport_public_key) {
			return false, .Refused_Zero_Key
		}
		// No per-machine key may ever reuse the offline principal root public key.
		if keys_equal_constant_time(entry.machine_id, list.principal_root_public_key) {
			return false, .Refused_Duplicate_Machine_Id
		}
		if keys_equal_constant_time(entry.signing_public_key, list.principal_root_public_key) {
			return false, .Refused_Duplicate_Signing_Key
		}
		if keys_equal_constant_time(entry.transport_public_key, list.principal_root_public_key) {
			return false, .Refused_Duplicate_Transport_Key
		}
		if _, uses_ok := remote.client_uses_of_word(remote.client_uses_word(entry.uses)); !uses_ok {
			return false, .Refused_Bad_Uses
		}
		switch checked_state {
		case .Active:
			if entry.revoked_at_ms != 0 {
				return false, .Refused_Bad_Timestamps
			}
			if !entry.tpm_attested {
				has_active_without_tpm = true
			}
		case .Revoked:
			if entry.revoked_at_ms == 0 || entry.revoked_at_ms < entry.added_at_ms {
				return false, .Refused_Bad_Timestamps
			}
		}
		for earlier in 0 ..< index {
			prev := &list.entries[earlier]
			if keys_equal_constant_time(prev.machine_id, entry.machine_id) {
				return false, .Refused_Duplicate_Machine_Id
			}
			if keys_equal_constant_time(prev.signing_public_key, entry.signing_public_key) {
				return false, .Refused_Duplicate_Signing_Key
			}
			if keys_equal_constant_time(prev.transport_public_key, entry.transport_public_key) {
				return false, .Refused_Duplicate_Transport_Key
			}
		}
	}
	return has_active_without_tpm, .Accepted
}

// machine_list_signing_bytes writes the canonical domain-separated bytes signed
// by the offline principal root key into output. Refused calls write no bytes.
machine_list_signing_bytes :: proc "contextless" (list: ^Signed_Machine_List, output: []u8) -> (written: int, status: Machine_List_Status) {
	_, structure_status := validate_machine_list_structure(list)
	if structure_status != .Accepted {
		return 0, structure_status
	}
	required := MACHINE_LIST_SIGNING_HEADER_SIZE + int(list.entry_count) * MACHINE_ENTRY_CANONICAL_SIZE
	if len(output) < required {
		return 0, .Refused_Buffer_Too_Small
	}
	domain := MACHINE_LIST_SIGNING_DOMAIN
	copy(output[0:len(domain)], domain)
	output[21] = 0
	output[22] = MACHINE_LIST_WIRE_VERSION
	output[23] = list.entry_count
	copy(output[24:56], list.principal_root_public_key[:])
	byte_order.write_u64_little_endian(output, 56, list.sequence_number)
	for index in 0 ..< int(list.entry_count) {
		offset := MACHINE_LIST_SIGNING_HEADER_SIZE + index * MACHINE_ENTRY_CANONICAL_SIZE
		write_canonical_machine_entry(&list.entries[index], output[offset:offset + MACHINE_ENTRY_CANONICAL_SIZE])
	}
	return required, .Accepted
}

// machine_list_validate checks a candidate signed machine list against an
// optional current list, the TPM join policy, and the offline principal root
// public key signature.
//
// Active entries without TPM attestation are refused by default unless
// policy.allow_without_tpm is true, in which case the validator returns
// Accepted_Without_Tpm_Warning so the caller displays a clear warning.
machine_list_validate :: proc "contextless" (
	current: ^Signed_Machine_List,
	candidate: ^Signed_Machine_List,
	policy: Join_Policy,
	verify_signature: Signature_Verify_Proc,
	user_data: rawptr = nil,
) -> Machine_List_Status {
	has_active_without_tpm, structure_status := validate_machine_list_structure(candidate)
	if structure_status != .Accepted {
		return structure_status
	}
	if current != nil {
		if !keys_equal_constant_time(current.principal_root_public_key, candidate.principal_root_public_key) {
			return .Refused_Root_Key_Mismatch
		}
		if candidate.sequence_number <= current.sequence_number {
			return .Refused_Replay_Or_Downgrade
		}
	}
	if has_active_without_tpm && !policy.allow_without_tpm {
		return .Refused_Without_Tpm
	}
	if verify_signature == nil {
		return .Refused_Invalid_Signature
	}
	signing_buffer: [MAX_MACHINE_LIST_SIGNING_BYTES]u8
	signing_length, signing_status := machine_list_signing_bytes(candidate, signing_buffer[:])
	if signing_status != .Accepted {
		return signing_status
	}
	if !verify_signature(candidate.principal_root_public_key, signing_buffer[:signing_length], candidate.signature, user_data) {
		return .Refused_Invalid_Signature
	}
	if has_active_without_tpm {
		return .Accepted_Without_Tpm_Warning
	}
	return .Accepted
}

// machine_list_apply_update validates candidate and atomically replaces state^
// only when validation succeeds. Any refusal leaves state^ completely unchanged.
machine_list_apply_update :: proc "contextless" (
	state: ^Signed_Machine_List,
	has_current: bool,
	candidate: ^Signed_Machine_List,
	policy: Join_Policy,
	verify_signature: Signature_Verify_Proc,
	user_data: rawptr = nil,
) -> Machine_List_Status {
	if state == nil || candidate == nil {
		return .Refused_Nil_Input
	}
	current_ptr: ^Signed_Machine_List = has_current ? state : nil
	status := machine_list_validate(current_ptr, candidate, policy, verify_signature, user_data)
	if !machine_list_status_accepted(status) {
		return status
	}
	state^ = candidate^
	return status
}

// machine_list_find_active_by_machine_id looks up an active machine entry by
// its identity public key. Revoked entries are never returned.
machine_list_find_active_by_machine_id :: proc "contextless" (
	list: ^Signed_Machine_List,
	machine_id: [PUBLIC_KEY_SIZE]u8,
) -> (entry: Machine_Entry, found: bool) {
	if list == nil || key_is_zero(machine_id) || int(list.entry_count) > MAX_MACHINE_LIST_ENTRIES {
		return {}, false
	}
	for index in 0 ..< int(list.entry_count) {
		candidate := list.entries[index]
		if candidate.state == .Active && keys_equal_constant_time(candidate.machine_id, machine_id) {
			return candidate, true
		}
	}
	return {}, false
}

// machine_list_find_active_by_signing_key looks up an active machine entry by
// its per-machine principal signing public key. Revoked entries are never returned.
machine_list_find_active_by_signing_key :: proc "contextless" (
	list: ^Signed_Machine_List,
	signing_public_key: [PUBLIC_KEY_SIZE]u8,
) -> (entry: Machine_Entry, found: bool) {
	if list == nil || key_is_zero(signing_public_key) || int(list.entry_count) > MAX_MACHINE_LIST_ENTRIES {
		return {}, false
	}
	for index in 0 ..< int(list.entry_count) {
		candidate := list.entries[index]
		if candidate.state == .Active && keys_equal_constant_time(candidate.signing_public_key, signing_public_key) {
			return candidate, true
		}
	}
	return {}, false
}

// machine_list_encode serializes a structurally valid Signed_Machine_List into
// output. A refused call writes zero bytes to output.
machine_list_encode :: proc "contextless" (list: ^Signed_Machine_List, output: []u8) -> (written: int, status: Machine_List_Status) {
	_, structure_status := validate_machine_list_structure(list)
	if structure_status != .Accepted {
		return 0, structure_status
	}
	required := MACHINE_LIST_WIRE_HEADER_SIZE + int(list.entry_count) * MACHINE_ENTRY_CANONICAL_SIZE
	if len(output) < required {
		return 0, .Refused_Buffer_Too_Small
	}
	magic := MACHINE_LIST_WIRE_MAGIC
	copy(output[0:4], magic[:])
	output[4] = MACHINE_LIST_WIRE_VERSION
	output[5] = list.entry_count
	output[6] = 0
	output[7] = 0
	copy(output[8:40], list.principal_root_public_key[:])
	byte_order.write_u64_little_endian(output, 40, list.sequence_number)
	copy(output[48:112], list.signature[:])
	for index in 0 ..< int(list.entry_count) {
		offset := MACHINE_LIST_WIRE_HEADER_SIZE + index * MACHINE_ENTRY_CANONICAL_SIZE
		write_canonical_machine_entry(&list.entries[index], output[offset:offset + MACHINE_ENTRY_CANONICAL_SIZE])
	}
	return required, .Accepted
}

// machine_list_decode strictly parses a wire-encoded Signed_Machine_List.
// Refuses bad magic, unknown versions, non-zero reserved bytes, unknown enum
// words, non-boolean attestation bytes, truncation, and trailing bytes.
// Callers must still pass the decoded list through machine_list_validate to
// check signatures, monotonicity, and TPM join policy.
machine_list_decode :: proc "contextless" (input: []u8) -> (list: Signed_Machine_List, status: Machine_List_Status) {
	if len(input) < MACHINE_LIST_WIRE_HEADER_SIZE {
		return {}, .Refused_Malformed_Wire
	}
	magic := MACHINE_LIST_WIRE_MAGIC
	for index in 0 ..< len(magic) {
		if input[index] != magic[index] {
			return {}, .Refused_Malformed_Wire
		}
	}
	if input[4] != MACHINE_LIST_WIRE_VERSION || input[6] != 0 || input[7] != 0 {
		return {}, .Refused_Malformed_Wire
	}
	count := input[5]
	if count == 0 {
		return {}, .Refused_Empty_List
	}
	if int(count) > MAX_MACHINE_LIST_ENTRIES {
		return {}, .Refused_Too_Many_Entries
	}
	expected_size := MACHINE_LIST_WIRE_HEADER_SIZE + int(count) * MACHINE_ENTRY_CANONICAL_SIZE
	if len(input) != expected_size {
		return {}, .Refused_Malformed_Wire
	}
	list.entry_count = count
	copy(list.principal_root_public_key[:], input[8:40])
	list.sequence_number = byte_order.read_u64_little_endian(input, 40)
	copy(list.signature[:], input[48:112])
	for index in 0 ..< int(count) {
		offset := MACHINE_LIST_WIRE_HEADER_SIZE + index * MACHINE_ENTRY_CANONICAL_SIZE
		entry_bytes := input[offset:offset + MACHINE_ENTRY_CANONICAL_SIZE]
		entry := &list.entries[index]
		copy(entry.machine_id[:], entry_bytes[0:32])
		copy(entry.signing_public_key[:], entry_bytes[32:64])
		copy(entry.transport_public_key[:], entry_bytes[64:96])
		uses, uses_ok := remote.client_uses_of_word(byte_order.read_u64_little_endian(entry_bytes, 96))
		if !uses_ok {
			return {}, .Refused_Bad_Uses
		}
		entry.uses = uses
		tpm_byte := entry_bytes[104]
		if tpm_byte != 0 && tpm_byte != 1 {
			return {}, .Refused_Malformed_Wire
		}
		entry.tpm_attested = tpm_byte == 1
		state, state_ok := machine_entry_state_of_word(u64(entry_bytes[105]))
		if !state_ok {
			return {}, .Refused_Bad_Entry_State
		}
		entry.state = state
		for pad_index in 106 ..< 112 {
			if entry_bytes[pad_index] != 0 {
				return {}, .Refused_Malformed_Wire
			}
		}
		entry.added_at_ms = byte_order.read_u64_little_endian(entry_bytes, 112)
		entry.revoked_at_ms = byte_order.read_u64_little_endian(entry_bytes, 120)
	}
	_, structure_status := validate_machine_list_structure(&list)
	if structure_status != .Accepted {
		return {}, structure_status
	}
	return list, .Accepted
}
