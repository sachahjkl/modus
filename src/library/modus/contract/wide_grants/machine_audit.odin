// Machine grant wide scopes and the machine audit space contract
// (src/md/features/several_principals.md, "The authority over the machine").
//
// A machine grant is used as a wide grant for principal 0, carrying
// Machine_Principals and/or Machine_System scopes. Every use is recorded in
// the machine audit space (source "root", output "machine_acts") of principal
// 0's collector, which every admitted principal may read. The act that ends a
// full audit space is exempt from the full-space refusal so no holder can trap
// a machine wide grant open by filling its audit space.
//
// Contract package: imports base and contract packages only, calls no kernel
// operation, and allocates no memory.
package wide_grants

import "modus:contract/byte_order"
import "modus:contract/enum_word"

// Canonical source and output name of the machine audit space in principal 0's
// collector.
MACHINE_AUDIT_SOURCE :: "root"
MACHINE_AUDIT_OUTPUT :: "machine_acts"

// Format property: byte length of a persistent 256-bit principal identifier.
MACHINE_AUDIT_IDENTIFIER_SIZE :: 32

// Format property: canonical fixed byte length of a Machine_Audit_Record.
MACHINE_AUDIT_RECORD_SIZE :: 128

// Machine wide-grant authority scopes allowed in principal 0's wide grants.
MACHINE_AUTHORITIES :: Wide_Authorities{.Machine_Principals, .Machine_System}

// Closed set of act kinds recorded in the machine audit space.
// Zero means unset and is refused at the border.
Machine_Audit_Act_Kind :: enum u64 {
	None                       = 0,
	Machine_Grant_Granted      = 1, // First-principal bootstrap or grant of machine scopes.
	Machine_Grant_Revoked      = 2, // Revocation of machine scopes from a principal.
	Machine_Grant_Recovered    = 3, // Machine recovery key restored both scopes on the chooser.
	Machine_Wide_Grant_Started = 4, // Holder proved passphrase and opened a machine wide grant for principal 0.
	Machine_Wide_Grant_Ended   = 5, // Machine wide grant ended (revoked, expired, or session locked); exempt from full space.
	Principal_Admitted         = 6, // Holder of Principals admitted a new named principal.
	Principal_Removed          = 7, // Holder of Principals removed a named principal without consent.
	Principal_Budget_Changed   = 8, // Holder of Principals changed session budgets.
	System_Action              = 9, // Holder of System changed plan, start policy, trusted path, device grant, machine passphrase, or update.
}

// Fixed-layout 128-byte act record stored in the machine audit space.
Machine_Audit_Record :: struct {
	grant_serial:      u64,
	timestamp_ms:      u64,
	act_kind_word:     u64, // Machine_Audit_Act_Kind (1..9).
	scopes_word:       u64, // Wide_Authorities subset of MACHINE_AUTHORITIES (or 0 when n/a for recovery).
	actor_identifier:  [MACHINE_AUDIT_IDENTIFIER_SIZE]u8,
	target_identifier: [MACHINE_AUDIT_IDENTIFIER_SIZE]u8,
	detail_word_0:     u64,
	detail_word_1:     u64,
	reserved_0:        u64,
	reserved_1:        u64,
}

#assert(size_of(Machine_Audit_Record) == MACHINE_AUDIT_RECORD_SIZE)
#assert(MACHINE_AUDIT_RECORD_SIZE <= SPACE_RECORD_BYTES_MOST)

// machine_grant_authorities_of_word validates a word of wide authorities for a
// machine grant (principal 0): non-empty subset of MACHINE_AUTHORITIES only.
machine_grant_authorities_of_word :: proc "contextless" (word: u64) -> (authorities: Wide_Authorities, ok: bool) {
	read := wide_authorities_from_word(word) or_return
	if read == {} || (read - MACHINE_AUTHORITIES) != {} {
		return {}, false
	}
	return read, true
}

// machine_audit_act_kind_from_word converts a transport word into a
// Machine_Audit_Act_Kind at the border, refusing None and unknown words.
machine_audit_act_kind_from_word :: proc "contextless" (word: u64) -> (kind: Machine_Audit_Act_Kind, ok: bool) {
	member := enum_word.member_of_word(Machine_Audit_Act_Kind, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

// machine_audit_act_ends_grant reports whether kind is the act that ends a
// machine wide grant, which is exempt from a full audit space refusal.
machine_audit_act_ends_grant :: proc "contextless" (kind: Machine_Audit_Act_Kind) -> bool {
	return kind == .Machine_Wide_Grant_Ended
}

// space_names_machine_audit reports whether (source, output) names the machine
// audit space.
space_names_machine_audit :: proc "contextless" (source, output: []u8) -> bool {
	return string(source) == MACHINE_AUDIT_SOURCE && string(output) == MACHINE_AUDIT_OUTPUT
}

// space_is_machine_audit reports whether space is the machine audit space.
space_is_machine_audit :: proc "contextless" (space: ^Collector_Space) -> bool {
	if space == nil {
		return false
	}
	src_len := 0
	for src_len < SPACE_NAME_BYTES && space.source[src_len] != 0 {
		src_len += 1
	}
	out_len := 0
	for out_len < SPACE_NAME_BYTES && space.output[out_len] != 0 {
		out_len += 1
	}
	return space_names_machine_audit(space.source[:src_len], space.output[:out_len])
}

// machine_audit_record_encode validates and serializes record into 128 bytes.
// Refuses unknown act kinds, non-zero reserved words, or invalid machine
// authority bits without modifying out.
machine_audit_record_encode :: proc "contextless" (record: ^Machine_Audit_Record, out: []u8) -> bool {
	if record == nil || len(out) < MACHINE_AUDIT_RECORD_SIZE {
		return false
	}
	if record.reserved_0 != 0 || record.reserved_1 != 0 {
		return false
	}
	if _, kind_ok := machine_audit_act_kind_from_word(record.act_kind_word); !kind_ok {
		return false
	}
	if record.scopes_word != 0 {
		if _, scopes_ok := machine_grant_authorities_of_word(record.scopes_word); !scopes_ok {
			return false
		}
	}
	byte_order.write_u64_little_endian(out, 0, record.grant_serial)
	byte_order.write_u64_little_endian(out, 8, record.timestamp_ms)
	byte_order.write_u64_little_endian(out, 16, record.act_kind_word)
	byte_order.write_u64_little_endian(out, 24, record.scopes_word)
	copy(out[32:64], record.actor_identifier[:])
	copy(out[64:96], record.target_identifier[:])
	byte_order.write_u64_little_endian(out, 96, record.detail_word_0)
	byte_order.write_u64_little_endian(out, 104, record.detail_word_1)
	byte_order.write_u64_little_endian(out, 112, 0)
	byte_order.write_u64_little_endian(out, 120, 0)
	return true
}

// machine_audit_record_decode validates and decodes 128 bytes from the machine
// audit space.
machine_audit_record_decode :: proc "contextless" (bytes: []u8) -> (record: Machine_Audit_Record, ok: bool) {
	if len(bytes) != MACHINE_AUDIT_RECORD_SIZE {
		return {}, false
	}
	reserved_0 := byte_order.read_u64_little_endian(bytes, 112)
	reserved_1 := byte_order.read_u64_little_endian(bytes, 120)
	if reserved_0 != 0 || reserved_1 != 0 {
		return {}, false
	}
	act_kind_word := byte_order.read_u64_little_endian(bytes, 16)
	if _, kind_ok := machine_audit_act_kind_from_word(act_kind_word); !kind_ok {
		return {}, false
	}
	scopes_word := byte_order.read_u64_little_endian(bytes, 24)
	if scopes_word != 0 {
		if _, scopes_ok := machine_grant_authorities_of_word(scopes_word); !scopes_ok {
			return {}, false
		}
	}
	record.grant_serial = byte_order.read_u64_little_endian(bytes, 0)
	record.timestamp_ms = byte_order.read_u64_little_endian(bytes, 8)
	record.act_kind_word = act_kind_word
	record.scopes_word = scopes_word
	copy(record.actor_identifier[:], bytes[32:64])
	copy(record.target_identifier[:], bytes[64:96])
	record.detail_word_0 = byte_order.read_u64_little_endian(bytes, 96)
	record.detail_word_1 = byte_order.read_u64_little_endian(bytes, 104)
	return record, true
}

// machine_audit_append appends a validated Machine_Audit_Record into the
// machine audit space, refusing any non-machine-audit space and exempting
// Machine_Wide_Grant_Ended from a full-space refusal.
machine_audit_append :: proc "contextless" (
	store: ^Space_Store,
	space_number: u32,
	record: ^Machine_Audit_Record,
) -> (serial: u64, refusal: Space_Refusal) {
	if ready := space_store_ready(store); ready != .None {
		return 0, ready
	}
	space := space_of(store, space_number)
	if space == nil {
		return 0, space_missing(store, space_number)
	}
	if !space_is_machine_audit(space) {
		return 0, .Bad_Kind
	}
	encoded: [MACHINE_AUDIT_RECORD_SIZE]u8
	if !machine_audit_record_encode(record, encoded[:]) {
		return 0, .Bad_Kind
	}
	kind, kind_ok := machine_audit_act_kind_from_word(record.act_kind_word)
	if !kind_ok {
		return 0, .Bad_Kind
	}
	return record_append_with_end_exemption(store, space_number, encoded[:], record.timestamp_ms, machine_audit_act_ends_grant(kind))
}
