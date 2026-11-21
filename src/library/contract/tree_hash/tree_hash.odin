// The canonical binary encoding and domain-separated hash of an immutable tree
// node (src/md/features/declarations.md, src/md/features/recipes.md).
//
// An immutable tree is a sorted list of entries, each naming either an Object
// or another Tree by its 32-byte BLAKE3 hash. Every logical tree has one
// canonical byte representation:
//
//   Header (16 bytes):
//     [0..8]   magic       "MODTREE1"
//     [8..12]  entry_count little-endian u32 (0 ..= MAX_TREE_ENTRIES)
//     [12..16] reserved    little-endian u32 (must be 0)
//
//   Entry (98 bytes each, repeated entry_count times, strictly sorted by UTF-8
//   byte order of entry names):
//     [0]      kind        Tree_Entry_Kind (1 = Object, 2 = Tree)
//     [1]      name_length length in bytes (1 ..= 64)
//     [2..66]  name        UTF-8 name bytes, padded with zero bytes to 64 bytes
//     [66..98] hash        32-byte BLAKE3 hash (object hash or child tree hash)
//
// Because entries have a fixed stride and are strictly sorted, lookup runs in
// O(log N) binary search without a separate offset table or dynamic allocation.
//
// The tree hash uses BLAKE3 derive-key mode under TREE_HASH_DOMAIN so a tree
// hash can never collide with a plain object hash (blake3.hash).
package tree_hash

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/enum_word"
import "modus:contract/store"
import "modus:contract/text_encoding"

// Header magic identifying version 1 of the canonical modus tree format.
HEADER_MAGIC :: [8]u8{'M', 'O', 'D', 'T', 'R', 'E', 'E', '1'}

// Size in bytes of the canonical tree header.
HEADER_SIZE :: 16

// Maximum length in bytes of one entry name (matches store.ENTRY_NAME_CAPACITY).
ENTRY_NAME_CAPACITY :: store.ENTRY_NAME_CAPACITY

// Size in bytes of one encoded tree entry: kind + name_length + name + hash.
ENTRY_SIZE :: 1 + 1 + ENTRY_NAME_CAPACITY + blake3.HASH_SIZE

// Maximum number of entries in one immutable tree node.
// With 512 entries, the largest encoded tree is 50,192 bytes, fitting inside a
// single 64 KiB call region of the storage service.
MAX_TREE_ENTRIES :: 512

// Maximum size in bytes of a valid canonical tree node.
MAX_ENCODED_TREE_BYTES :: HEADER_SIZE + MAX_TREE_ENTRIES * ENTRY_SIZE

// Domain separation context string passed to blake3.derive_key so tree hashes
// are cryptographically separated from object blob hashes.
TREE_HASH_DOMAIN :: "modus tree v1"

#assert(ENTRY_SIZE == 98)
#assert(MAX_ENCODED_TREE_BYTES == 50192)

// Closed set of entry kinds in an immutable tree node. Values match
// store.Entry_Kind (Object = 1, Tree = 2) explicitly across the binary border.
Tree_Entry_Kind :: enum u8 {
	Object = 1,
	Tree   = 2,
}

// Closed set of validation and encoding refusals for immutable tree nodes.
Tree_Refusal :: enum u8 {
	None             = 0,
	Bad_Header       = 1,
	Bad_Entry_Kind   = 2,
	Empty_Name       = 3,
	Name_Too_Long    = 4,
	Invalid_Name     = 5,
	Not_Sorted       = 6,
	Duplicate_Name   = 7,
	Too_Many_Entries = 8,
	Trailing_Bytes   = 9,
	Truncated        = 10,
}

// One entry of an immutable tree node in memory.
Tree_Entry :: struct {
	kind:        Tree_Entry_Kind,
	name_length: u8,
	name:        [ENTRY_NAME_CAPACITY]u8,
	hash:        blake3.Hash,
}

// tree_entry_kind_of_word is the single border converting a raw transport byte
// or word into a Tree_Entry_Kind member. Unknown values are refused.
tree_entry_kind_of_word :: proc "contextless" (word: u64) -> (kind: Tree_Entry_Kind, ok: bool) {
	return enum_word.member_of_word(Tree_Entry_Kind, word)
}

// tree_entry_name returns the active UTF-8 slice of a Tree_Entry name.
tree_entry_name :: proc "contextless" (entry: ^Tree_Entry) -> string {
	length := min(int(entry.name_length), ENTRY_NAME_CAPACITY)
	return string(entry.name[:length])
}

// tree_name_validate checks that name is a valid single-step UTF-8 entry name:
// 1 to 64 bytes, valid non-control UTF-8 (via text_encoding.text_valid), no
// '/' byte, no zero byte, and neither "." nor "..".
tree_name_validate :: proc "contextless" (name: []u8) -> Tree_Refusal {
	if len(name) == 0 {
		return .Empty_Name
	}
	if len(name) > ENTRY_NAME_CAPACITY {
		return .Name_Too_Long
	}
	if (len(name) == 1 && name[0] == '.') || (len(name) == 2 && name[0] == '.' && name[1] == '.') {
		return .Invalid_Name
	}
	for value in name {
		if value == 0 || value == '/' {
			return .Invalid_Name
		}
	}
	if !text_encoding.text_valid(name) {
		return .Invalid_Name
	}
	return .None
}

// tree_entry_make constructs a validated Tree_Entry with zero-padded name bytes.
tree_entry_make :: proc "contextless" (kind: Tree_Entry_Kind, name: string, hash: blake3.Hash) -> (entry: Tree_Entry, refusal: Tree_Refusal) {
	checked_kind, kind_ok := tree_entry_kind_of_word(u64(kind))
	if !kind_ok {
		return {}, .Bad_Entry_Kind
	}
	name_bytes := transmute([]u8)name
	if name_refusal := tree_name_validate(name_bytes); name_refusal != .None {
		return {}, name_refusal
	}
	entry.kind = checked_kind
	entry.name_length = u8(len(name_bytes))
	copy(entry.name[:], name_bytes)
	entry.hash = hash
	return entry, .None
}

// tree_encoded_size gives the exact byte count of an encoded tree with
// entry_count entries. Returns 0 when entry_count is negative or above
// MAX_TREE_ENTRIES.
tree_encoded_size :: proc "contextless" (entry_count: int) -> int {
	if entry_count < 0 || entry_count > MAX_TREE_ENTRIES {
		return 0
	}
	return HEADER_SIZE + entry_count * ENTRY_SIZE
}

// compare_name_bytes compares two entry names in raw UTF-8 byte order:
// -1 if left < right, 0 if equal, 1 if left > right.
compare_name_bytes :: proc "contextless" (left, right: []u8) -> int {
	limit := min(len(left), len(right))
	for index in 0 ..< limit {
		if left[index] != right[index] {
			return left[index] < right[index] ? -1 : 1
		}
	}
	if len(left) < len(right) {
		return -1
	}
	if len(left) > len(right) {
		return 1
	}
	return 0
}

// tree_encode serializes entries into canonical binary form inside output.
// All entries are validated before any byte of output is written, so a refused
// call leaves output unchanged.
tree_encode :: proc "contextless" (entries: []Tree_Entry, output: []u8) -> (written: int, refusal: Tree_Refusal) {
	if len(entries) > MAX_TREE_ENTRIES {
		return 0, .Too_Many_Entries
	}
	required := HEADER_SIZE + len(entries) * ENTRY_SIZE
	if len(output) < required {
		return 0, .Truncated
	}
	// Pass 1: validate every entry and strict UTF-8 byte ordering before writing.
	previous_name: []u8
	for &entry, index in entries {
		if _, kind_ok := tree_entry_kind_of_word(u64(entry.kind)); !kind_ok {
			return 0, .Bad_Entry_Kind
		}
		name_length := int(entry.name_length)
		if name_length == 0 {
			return 0, .Empty_Name
		}
		if name_length > ENTRY_NAME_CAPACITY {
			return 0, .Name_Too_Long
		}
		name_slice := entry.name[:name_length]
		if name_refusal := tree_name_validate(name_slice); name_refusal != .None {
			return 0, name_refusal
		}
		for pad in entry.name[name_length:ENTRY_NAME_CAPACITY] {
			if pad != 0 {
				return 0, .Invalid_Name
			}
		}
		if index > 0 {
			order := compare_name_bytes(previous_name, name_slice)
			if order == 0 {
				return 0, .Duplicate_Name
			}
			if order > 0 {
				return 0, .Not_Sorted
			}
		}
		previous_name = name_slice
	}
	// Pass 2: write canonical header and fixed-stride entries.
	magic := HEADER_MAGIC
	copy(output[0:8], magic[:])
	byte_order.write_u32_little_endian(output, 8, u32(len(entries)))
	byte_order.write_u32_little_endian(output, 12, 0)
	for &entry, index in entries {
		offset := HEADER_SIZE + index * ENTRY_SIZE
		output[offset] = u8(entry.kind)
		output[offset + 1] = entry.name_length
		copy(output[offset + 2:][:ENTRY_NAME_CAPACITY], entry.name[:])
		copy(output[offset + 2 + ENTRY_NAME_CAPACITY:][:blake3.HASH_SIZE], entry.hash[:])
	}
	return required, .None
}

// tree_validate strictly verifies canonical_bytes against every rule of the
// immutable tree format: header magic, zero reserved word, entry count bound,
// exact byte length (no truncation or trailing garbage), valid entry kinds,
// valid UTF-8 non-control names, zero name padding, and strict UTF-8 byte
// order with no duplicate names.
tree_validate :: proc "contextless" (canonical_bytes: []u8) -> (entry_count: int, refusal: Tree_Refusal) {
	if len(canonical_bytes) < HEADER_SIZE {
		return 0, .Truncated
	}
	magic := HEADER_MAGIC
	for index in 0 ..< len(magic) {
		if canonical_bytes[index] != magic[index] {
			return 0, .Bad_Header
		}
	}
	if byte_order.read_u32_little_endian(canonical_bytes, 12) != 0 {
		return 0, .Bad_Header
	}
	raw_count := byte_order.read_u32_little_endian(canonical_bytes, 8)
	if raw_count > MAX_TREE_ENTRIES {
		return 0, .Too_Many_Entries
	}
	count := int(raw_count)
	expected_size := HEADER_SIZE + count * ENTRY_SIZE
	if len(canonical_bytes) < expected_size {
		return 0, .Truncated
	}
	if len(canonical_bytes) > expected_size {
		return 0, .Trailing_Bytes
	}
	previous_name: []u8
	for index in 0 ..< count {
		offset := HEADER_SIZE + index * ENTRY_SIZE
		if _, kind_ok := tree_entry_kind_of_word(u64(canonical_bytes[offset])); !kind_ok {
			return 0, .Bad_Entry_Kind
		}
		name_length := int(canonical_bytes[offset + 1])
		if name_length == 0 {
			return 0, .Empty_Name
		}
		if name_length > ENTRY_NAME_CAPACITY {
			return 0, .Name_Too_Long
		}
		name_slice := canonical_bytes[offset + 2:][:name_length]
		if name_refusal := tree_name_validate(name_slice); name_refusal != .None {
			return 0, name_refusal
		}
		for pad in canonical_bytes[offset + 2 + name_length:offset + 2 + ENTRY_NAME_CAPACITY] {
			if pad != 0 {
				return 0, .Invalid_Name
			}
		}
		if index > 0 {
			order := compare_name_bytes(previous_name, name_slice)
			if order == 0 {
				return 0, .Duplicate_Name
			}
			if order > 0 {
				return 0, .Not_Sorted
			}
		}
		previous_name = name_slice
	}
	return count, .None
}

// tree_hash validates canonical_bytes and computes the domain-separated BLAKE3
// hash of the tree node. Refused inputs return a zero hash and the refusal.
tree_hash :: proc "contextless" (canonical_bytes: []u8) -> (hash: blake3.Hash, refusal: Tree_Refusal) {
	if _, validation_refusal := tree_validate(canonical_bytes); validation_refusal != .None {
		return {}, validation_refusal
	}
	return blake3.derive_key(TREE_HASH_DOMAIN, canonical_bytes), .None
}

// tree_entry_at decodes entry number index from already-validated canonical
// tree bytes. Returns false if index is out of bounds or the entry kind is invalid.
tree_entry_at :: proc "contextless" (canonical_bytes: []u8, index: int) -> (entry: Tree_Entry, ok: bool) {
	if index < 0 || len(canonical_bytes) < HEADER_SIZE {
		return {}, false
	}
	offset := HEADER_SIZE + index * ENTRY_SIZE
	if offset + ENTRY_SIZE > len(canonical_bytes) {
		return {}, false
	}
	kind, kind_ok := tree_entry_kind_of_word(u64(canonical_bytes[offset]))
	if !kind_ok {
		return {}, false
	}
	name_length := canonical_bytes[offset + 1]
	if name_length == 0 || int(name_length) > ENTRY_NAME_CAPACITY {
		return {}, false
	}
	entry.kind = kind
	entry.name_length = name_length
	copy(entry.name[:], canonical_bytes[offset + 2:][:ENTRY_NAME_CAPACITY])
	copy(entry.hash[:], canonical_bytes[offset + 2 + ENTRY_NAME_CAPACITY:][:blake3.HASH_SIZE])
	return entry, true
}

// tree_iterate validates canonical_bytes and invokes visit on every entry in
// canonical sorted order. Returning false from visit stops iteration early.
tree_iterate :: proc "contextless" (
	canonical_bytes: []u8,
	visit: proc "contextless" (index: int, entry: Tree_Entry, user_data: rawptr) -> bool,
	user_data: rawptr = nil,
) -> Tree_Refusal {
	count, refusal := tree_validate(canonical_bytes)
	if refusal != .None {
		return refusal
	}
	if visit == nil {
		return .None
	}
	for index in 0 ..< count {
		entry, ok := tree_entry_at(canonical_bytes, index)
		if !ok {
			return .Bad_Entry_Kind
		}
		if !visit(index, entry, user_data) {
			break
		}
	}
	return .None
}

// tree_lookup validates canonical_bytes and looks up name using O(log N) binary
// search on the sorted fixed-stride entries.
tree_lookup :: proc "contextless" (canonical_bytes: []u8, name: string) -> (entry: Tree_Entry, found: bool, refusal: Tree_Refusal) {
	count, validation_refusal := tree_validate(canonical_bytes)
	if validation_refusal != .None {
		return {}, false, validation_refusal
	}
	target := transmute([]u8)name
	if name_refusal := tree_name_validate(target); name_refusal != .None {
		return {}, false, name_refusal
	}
	low := 0
	high := count
	for low < high {
		middle := low + (high - low) / 2
		offset := HEADER_SIZE + middle * ENTRY_SIZE
		name_length := int(canonical_bytes[offset + 1])
		candidate := canonical_bytes[offset + 2:][:name_length]
		order := compare_name_bytes(candidate, target)
		if order == 0 {
			decoded, ok := tree_entry_at(canonical_bytes, middle)
			if !ok {
				return {}, false, .Bad_Entry_Kind
			}
			return decoded, true, .None
		}
		if order < 0 {
			low = middle + 1
		} else {
			high = middle
		}
	}
	return {}, false, .None
}
