// Canonical BLAKE3 measurement of principal 0's active role-holder set
// (src/md/features/attestation.md).
//
// Each active role holder binds its closed role enum word, printable ASCII
// module name, and 32-byte BLAKE3 module file hash. Sorting ascending by
// role_word makes the digest invariant to caller input order, and BLAKE3
// derive_key separates role-holder digests from plain file hashes.
//
// This is a contract package: it imports base and contract packages only,
// calls no kernel operation, and allocates no memory.
package attestation

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/enum_word"
import "modus:contract/role_contract"

// Format property: domain separation context string for BLAKE3 derive_key.
ROLE_MEASUREMENT_DOMAIN :: "modus role holders v1"

// Format property: maximum module name length in bytes for a measured holder.
ROLE_HOLDER_NAME_LIMIT :: 64

// Computed: stack capacity exceeding the 23 closed roles in role_contract.Role.
ROLE_HOLDER_CAPACITY :: 32

// Format property: maximum encoded bytes per holder (u64 role + u32 name length + name + 32-byte hash).
ROLE_HOLDER_WIRE_LIMIT :: 8 + 4 + ROLE_HOLDER_NAME_LIMIT + blake3.HASH_SIZE

// Computed: stack buffer size for canonical encoding of ROLE_HOLDER_CAPACITY holders plus u32 count.
ROLE_MEASUREMENT_BUFFER_SIZE :: 4 + ROLE_HOLDER_CAPACITY * ROLE_HOLDER_WIRE_LIMIT

// One active role holder included in the canonical start measurement.
Measured_Role_Holder :: struct {
	role_word:   u64,
	module_name: string,
	module_hash: blake3.Hash,
}

// Closed set of refusal reasons for role-holder measurement.
Role_Measurement_Refusal :: enum u8 {
	None                 = 0,
	Empty_Holders        = 1,
	Too_Many_Holders     = 2,
	Unknown_Role         = 3,
	Duplicate_Role       = 4,
	Empty_Module_Name    = 5,
	Module_Name_Too_Long = 6,
	Bad_Module_Name_Byte = 7,
	Zero_Module_Hash     = 8,
}

// role_measurement_refusal_from_word converts a transport word into a
// Role_Measurement_Refusal at the border, refusing any unknown value.
role_measurement_refusal_from_word :: proc "contextless" (word: u64) -> (refusal: Role_Measurement_Refusal, ok: bool) {
	return enum_word.member_of_word(Role_Measurement_Refusal, word)
}

// is_zero_bytes reports whether every byte of slice is zero.
@(private = "package")
is_zero_bytes :: proc "contextless" (bytes: []u8) -> bool {
	acc: u8 = 0
	for b in bytes {
		acc |= b
	}
	return acc == 0
}

// constant_time_equal compares two byte slices without early exit on mismatch
// so timing does not leak digest, nonce, or key prefixes.
@(private = "package", optimization_mode = "none")
constant_time_equal :: proc "contextless" (left, right: []u8) -> bool {
	if len(left) != len(right) {
		return false
	}
	diff: u8 = 0
	for index in 0 ..< len(left) {
		diff |= left[index] ~ right[index]
	}
	return diff == 0
}

// module_name_check validates that a measured holder name is non-empty, within
// ROLE_HOLDER_NAME_LIMIT, and contains only printable ASCII identifier bytes.
@(private = "file")
module_name_check :: proc "contextless" (name: string) -> Role_Measurement_Refusal {
	if len(name) == 0 {
		return .Empty_Module_Name
	}
	if len(name) > ROLE_HOLDER_NAME_LIMIT {
		return .Module_Name_Too_Long
	}
	for index in 0 ..< len(name) {
		b := name[index]
		is_lower := b >= 'a' && b <= 'z'
		is_upper := b >= 'A' && b <= 'Z'
		is_digit := b >= '0' && b <= '9'
		is_punct := b == '_' || b == '-' || b == '.'
		if !(is_lower || is_upper || is_digit || is_punct) {
			return .Bad_Module_Name_Byte
		}
	}
	return .None
}

// measure_role_holders_checked computes the canonical BLAKE3 measurement of
// holders sorted ascending by role_word, returning a detailed refusal reason
// if any entry violates the contract.
measure_role_holders_checked :: proc "contextless" (holders: []Measured_Role_Holder) -> (digest: blake3.Hash, refusal: Role_Measurement_Refusal) {
	count := len(holders)
	if count == 0 {
		return {}, .Empty_Holders
	}
	if count > ROLE_HOLDER_CAPACITY {
		return {}, .Too_Many_Holders
	}

	sorted: [ROLE_HOLDER_CAPACITY]Measured_Role_Holder
	for index in 0 ..< count {
		holder := holders[index]
		if _, role_ok := role_contract.role_from_word(holder.role_word); !role_ok {
			return {}, .Unknown_Role
		}
		if name_refusal := module_name_check(holder.module_name); name_refusal != .None {
			return {}, name_refusal
		}
		hash_copy := holder.module_hash
		if is_zero_bytes(hash_copy[:]) {
			return {}, .Zero_Module_Hash
		}
		sorted[index] = holder
	}

	// Insertion sort ascending by role_word so digest is invariant to input order.
	for i := 1; i < count; i += 1 {
		key := sorted[i]
		j := i - 1
		for j >= 0 && sorted[j].role_word > key.role_word {
			sorted[j + 1] = sorted[j]
			j -= 1
		}
		sorted[j + 1] = key
	}

	for index := 1; index < count; index += 1 {
		if sorted[index].role_word == sorted[index - 1].role_word {
			return {}, .Duplicate_Role
		}
	}

	buffer: [ROLE_MEASUREMENT_BUFFER_SIZE]u8
	offset := 0
	byte_order.write_u32_little_endian(buffer[:], offset, u32(count))
	offset += 4
	for index in 0 ..< count {
		entry := sorted[index]
		byte_order.write_u64_little_endian(buffer[:], offset, entry.role_word)
		offset += 8
		byte_order.write_u32_little_endian(buffer[:], offset, u32(len(entry.module_name)))
		offset += 4
		copy(buffer[offset:][:len(entry.module_name)], entry.module_name)
		offset += len(entry.module_name)
		copy(buffer[offset:][:blake3.HASH_SIZE], entry.module_hash[:])
		offset += blake3.HASH_SIZE
	}

	return blake3.derive_key(ROLE_MEASUREMENT_DOMAIN, buffer[:offset]), .None
}

// measure_role_holders computes the canonical BLAKE3 measurement of holders
// sorted ascending by role_word. Returns ok = false on duplicate roles,
// unknown roles, empty or malformed module names, or zero hashes.
measure_role_holders :: proc "contextless" (holders: []Measured_Role_Holder) -> (digest: blake3.Hash, ok: bool) {
	measured, refusal := measure_role_holders_checked(holders)
	if refusal != .None {
		return {}, false
	}
	return measured, true
}
