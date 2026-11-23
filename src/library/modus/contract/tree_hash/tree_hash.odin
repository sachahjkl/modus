// The canonical binary encoding and domain-separated hash of an immutable tree
// node (src/md/features/declarations.md; src/md/features/recipes.md).
//
// An immutable tree is a sorted list of entries, each naming either an Object
// or another Tree by its 32-byte BLAKE3 hash. Every logical tree has one
// canonical byte representation:
//
//   Header (16 bytes):
//     [0..8]   magic       "MODTREE2"
//     [8..12]  entry_count little-endian u32 (0 ..= MAX_TREE_ENTRIES)
//     [12..16] reserved    little-endian u32 (must be 0)
//
//   Entry (34 + name_length bytes each, repeated entry_count times, strictly
//   sorted by the UTF-8 byte order of the names):
//     [0]                   kind        Tree_Entry_Kind (1 = Object, 2 = Tree, 3 = Part)
//     [1]                   name_length length in bytes (1 ..= 255)
//     [2..2+n]              name        UTF-8 name bytes
//     [2+n..2+n+32]         hash        32-byte BLAKE3 hash (object hash or child tree hash)
//
// An entry has the length of its name, not of the longest name: a folder of
// short names costs about 50 bytes for each entry, where a fixed stride of
// 255 bytes would cost 289. So an entry has no fixed place: a reader walks
// the entries in their order (tree_entry_next). The walk is the check of
// the whole tree too, so a lookup costs what its check costs already.
//
// A folder of more than MAX_TREE_ENTRIES entries is a tree of several
// nodes. Its entries, in their order, are cut into nodes of exactly
// MAX_TREE_ENTRIES entries, the last one with the rest (1 or more). Each
// node becomes a Part: an entry whose name is the first name under it and
// whose hash is the tree hash of its node. The parts, in their order, are
// cut the same way into nodes of exactly PART_FANOUT parts, and so on up
// to one node: the root, with 2 to PART_FANOUT parts. A node holds entries
// or parts, never both. The cut depends on the count of the entries only,
// so one folder has one form and one hash, and a folder of at most
// MAX_TREE_ENTRIES entries is one node as before (src/md/data/storage_capacity.md,
// "A folder of more than 4096 entries is a tree of several nodes").
//
// The tree hash uses BLAKE3 derive-key mode under TREE_HASH_DOMAIN so a tree
// hash can never collide with a plain object hash (blake3.hash).
package tree_hash

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/enum_word"
import "modus:contract/store"
import "modus:contract/text_encoding"

// Header magic identifying version 2 of the canonical modus tree format.
HEADER_MAGIC :: [8]u8{'M', 'O', 'D', 'T', 'R', 'E', 'E', '2'}

// Size in bytes of the canonical tree header.
HEADER_SIZE :: 16

// Maximum length in bytes of one entry name (matches store.ENTRY_NAME_CAPACITY).
ENTRY_NAME_CAPACITY :: store.ENTRY_NAME_CAPACITY
#assert(ENTRY_NAME_CAPACITY <= 255) // The length of a name is one byte.

// The bytes of an entry besides its name: kind, name_length and hash.
ENTRY_FIXED_SIZE :: 1 + 1 + blake3.HASH_SIZE

// The bytes of the largest encoded entry: a name of ENTRY_NAME_CAPACITY bytes.
ENTRY_SIZE_MOST :: ENTRY_FIXED_SIZE + ENTRY_NAME_CAPACITY

// Maximum number of entries in one immutable tree node: a folder of 4096
// files. The bound keeps the largest node, and each buffer that holds one,
// near 1 MiB; a typical node of short names is a sixth of that.
MAX_TREE_ENTRIES :: 4096

// Maximum size in bytes of a valid canonical tree node.
MAX_ENCODED_TREE_BYTES :: HEADER_SIZE + MAX_TREE_ENTRIES * ENTRY_SIZE_MOST

// The most parts of one node of parts: a node of parts stays small, so a
// reader holds one for each level of a large folder.
PART_FANOUT :: 64

// The largest node of parts.
MAX_ENCODED_PARTS_BYTES :: HEADER_SIZE + PART_FANOUT * ENTRY_SIZE_MOST

// The most levels of nodes of parts above the nodes of entries: 4096 *
// 64^4 entries, 2^36, more than a disk of 4 TiB holds.
PART_LEVEL_LIMIT :: 4

// Domain separation context string passed to blake3.derive_key so tree hashes
// are cryptographically separated from object blob hashes.
TREE_HASH_DOMAIN :: "modus tree v2"

#assert(ENTRY_FIXED_SIZE == 34)
#assert(ENTRY_SIZE_MOST == 289)
#assert(MAX_ENCODED_TREE_BYTES == 1183760)

// Closed set of entry kinds in an immutable tree node. Object and Tree
// match store.Entry_Kind (Object = 1, Tree = 2) explicitly across the
// binary border. A Part names one node of a tree of several nodes: it is
// not an entry of the folder, and a store has no such kind.
Tree_Entry_Kind :: enum u8 {
	Object = 1,
	Tree   = 2,
	Part   = 3,
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
	Mixed_Parts      = 11, // A node holds parts and entries, or more than PART_FANOUT parts.
}

// One entry of an immutable tree node in memory.
Tree_Entry :: struct {
	kind:        Tree_Entry_Kind,
	name_length: u8,
	name:        [ENTRY_NAME_CAPACITY]u8, // name_length bytes, then zero bytes.
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
// 1 to 255 bytes, valid non-control UTF-8 (via text_encoding.text_valid), no
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

// tree_encoded_size gives the exact byte count of the encoded tree of
// entries. Returns 0 when there are more than MAX_TREE_ENTRIES entries.
tree_encoded_size :: proc "contextless" (entries: []Tree_Entry) -> int {
	if len(entries) > MAX_TREE_ENTRIES {
		return 0
	}
	size := HEADER_SIZE
	for &entry in entries {
		size += ENTRY_FIXED_SIZE + min(int(entry.name_length), ENTRY_NAME_CAPACITY)
	}
	return size
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
	// Pass 1: validate every entry and strict UTF-8 byte ordering before writing.
	previous_name: []u8
	parts := 0
	for &entry, index in entries {
		if _, kind_ok := tree_entry_kind_of_word(u64(entry.kind)); !kind_ok {
			return 0, .Bad_Entry_Kind
		}
		parts += int(entry.kind == .Part)
		name_length := int(entry.name_length)
		if name_length == 0 {
			return 0, .Empty_Name
		}
		name_slice := entry.name[:name_length]
		if name_refusal := tree_name_validate(name_slice); name_refusal != .None {
			return 0, name_refusal
		}
		for pad in entry.name[name_length:] {
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
	if parts != 0 && (parts != len(entries) || parts > PART_FANOUT) {
		return 0, .Mixed_Parts
	}
	required := tree_encoded_size(entries)
	if len(output) < required {
		return 0, .Truncated
	}
	// Pass 2: write the canonical header and the entries.
	magic := HEADER_MAGIC
	copy(output[0:8], magic[:])
	byte_order.write_u32_little_endian(output, 8, u32(len(entries)))
	byte_order.write_u32_little_endian(output, 12, 0)
	offset := HEADER_SIZE
	for &entry in entries {
		name_length := int(entry.name_length)
		output[offset] = u8(entry.kind)
		output[offset + 1] = entry.name_length
		copy(output[offset + 2:][:name_length], entry.name[:name_length])
		copy(output[offset + 2 + name_length:][:blake3.HASH_SIZE], entry.hash[:])
		offset += ENTRY_FIXED_SIZE + name_length
	}
	return required, .None
}

// tree_entry_read reads the entry at offset of canonical bytes, with the
// checks of one entry: its kind, its length inside the bytes, and its name.
// It does not check the order against the entry before.
@(private = "file")
tree_entry_read :: proc "contextless" (canonical_bytes: []u8, offset: int) -> (entry: Tree_Entry, next_offset: int, refusal: Tree_Refusal) {
	if offset + 2 > len(canonical_bytes) {
		return {}, offset, .Truncated
	}
	kind, kind_ok := tree_entry_kind_of_word(u64(canonical_bytes[offset]))
	if !kind_ok {
		return {}, offset, .Bad_Entry_Kind
	}
	name_length := int(canonical_bytes[offset + 1])
	if name_length == 0 {
		return {}, offset, .Empty_Name
	}
	next_offset = offset + ENTRY_FIXED_SIZE + name_length
	if next_offset > len(canonical_bytes) {
		return {}, offset, .Truncated
	}
	name_slice := canonical_bytes[offset + 2:][:name_length]
	if name_refusal := tree_name_validate(name_slice); name_refusal != .None {
		return {}, offset, name_refusal
	}
	entry.kind = kind
	entry.name_length = u8(name_length)
	copy(entry.name[:], name_slice)
	copy(entry.hash[:], canonical_bytes[offset + 2 + name_length:][:blake3.HASH_SIZE])
	return entry, next_offset, .None
}

// tree_validate strictly verifies canonical_bytes against every rule of the
// immutable tree format: header magic, zero reserved word, entry count bound,
// exact byte length (no truncation or trailing garbage), valid entry kinds,
// valid UTF-8 non-control names, and strict UTF-8 byte order with no
// duplicate names.
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
	offset := HEADER_SIZE
	previous_offset, previous_length := 0, 0
	parts := 0
	for index in 0 ..< count {
		entry_refusal: Tree_Refusal
		next: int
		read: Tree_Entry
		read, next, entry_refusal = tree_entry_read(canonical_bytes, offset)
		if entry_refusal != .None {
			return 0, entry_refusal
		}
		parts += int(read.kind == .Part)
		name_length := int(canonical_bytes[offset + 1])
		if index > 0 {
			order := compare_name_bytes(canonical_bytes[previous_offset + 2:][:previous_length], canonical_bytes[offset + 2:][:name_length])
			if order == 0 {
				return 0, .Duplicate_Name
			}
			if order > 0 {
				return 0, .Not_Sorted
			}
		}
		previous_offset, previous_length = offset, name_length
		offset = next
	}
	if len(canonical_bytes) > offset {
		return 0, .Trailing_Bytes
	}
	if parts != 0 && (parts != count || parts > PART_FANOUT) {
		return 0, .Mixed_Parts
	}
	return count, .None
}

// tree_holds_parts says if already-validated canonical bytes are a node of
// parts: its entries are parts.
tree_holds_parts :: proc "contextless" (canonical_bytes: []u8) -> bool {
	return len(canonical_bytes) > HEADER_SIZE && canonical_bytes[HEADER_SIZE] == u8(Tree_Entry_Kind.Part)
}

// tree_entry_count gives the count of entries of already-validated
// canonical bytes.
tree_entry_count :: proc "contextless" (canonical_bytes: []u8) -> int {
	if len(canonical_bytes) < HEADER_SIZE {
		return 0
	}
	return int(byte_order.read_u32_little_endian(canonical_bytes, 8))
}

// tree_part_find gives the part of a node of parts under which `name` is:
// the last part whose name is at most name, its place and the count of the
// parts. found is false when name comes before the first part.
tree_part_find :: proc "contextless" (canonical_bytes: []u8, name: string) -> (part: Tree_Entry, index: int, count: int, found: bool) {
	count = tree_entry_count(canonical_bytes)
	target := transmute([]u8)name
	offset := HEADER_SIZE
	for place in 0 ..< count {
		entry, next, ok := tree_entry_next(canonical_bytes, offset)
		if !ok {
			return {}, 0, count, false
		}
		if compare_name_bytes(entry.name[:entry.name_length], target) > 0 {
			break
		}
		part, index, found = entry, place, true
		offset = next
	}
	return part, index, count, found
}

// tree_hash validates canonical_bytes and computes the domain-separated BLAKE3
// hash of the tree node. Refused inputs return a zero hash and the refusal.
tree_hash :: proc "contextless" (canonical_bytes: []u8) -> (hash: blake3.Hash, refusal: Tree_Refusal) {
	if _, validation_refusal := tree_validate(canonical_bytes); validation_refusal != .None {
		return {}, validation_refusal
	}
	return blake3.derive_key(TREE_HASH_DOMAIN, canonical_bytes), .None
}

// tree_entry_next decodes the entry at offset of already-validated canonical
// tree bytes, and gives the offset of the next one. The first entry is at
// HEADER_SIZE. ok is false past the last entry or on bytes that break a rule.
tree_entry_next :: proc "contextless" (canonical_bytes: []u8, offset: int) -> (entry: Tree_Entry, next_offset: int, ok: bool) {
	if offset < HEADER_SIZE {
		return {}, offset, false
	}
	refusal: Tree_Refusal
	entry, next_offset, refusal = tree_entry_read(canonical_bytes, offset)
	return entry, next_offset, refusal == .None
}

// tree_entry_at decodes entry number index from already-validated canonical
// tree bytes, walking the entries before it. Returns false if index is out
// of bounds or an entry before it breaks a rule. A reader of each entry
// uses tree_entry_next.
tree_entry_at :: proc "contextless" (canonical_bytes: []u8, index: int) -> (entry: Tree_Entry, ok: bool) {
	if index < 0 || len(canonical_bytes) < HEADER_SIZE || index >= int(byte_order.read_u32_little_endian(canonical_bytes, 8)) {
		return {}, false
	}
	offset := HEADER_SIZE
	for _ in 0 ..= index {
		entry, offset, ok = tree_entry_next(canonical_bytes, offset)
		if !ok {
			return {}, false
		}
	}
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
	offset := HEADER_SIZE
	for index in 0 ..< count {
		entry, next, ok := tree_entry_next(canonical_bytes, offset)
		if !ok {
			return .Bad_Entry_Kind
		}
		if !visit(index, entry, user_data) {
			break
		}
		offset = next
	}
	return .None
}

// tree_lookup validates canonical_bytes and looks up name. The entries have
// no fixed place, so the lookup walks them in their order and stops at the
// first name past it: no more work than the check of the tree.
tree_lookup :: proc "contextless" (canonical_bytes: []u8, name: string) -> (entry: Tree_Entry, found: bool, refusal: Tree_Refusal) {
	count, validation_refusal := tree_validate(canonical_bytes)
	if validation_refusal != .None {
		return {}, false, validation_refusal
	}
	target := transmute([]u8)name
	if name_refusal := tree_name_validate(target); name_refusal != .None {
		return {}, false, name_refusal
	}
	offset := HEADER_SIZE
	for _ in 0 ..< count {
		name_length := int(canonical_bytes[offset + 1])
		order := compare_name_bytes(canonical_bytes[offset + 2:][:name_length], target)
		if order == 0 {
			decoded, _, ok := tree_entry_next(canonical_bytes, offset)
			if !ok {
				return {}, false, .Bad_Entry_Kind
			}
			return decoded, true, .None
		}
		if order > 0 {
			break
		}
		offset += ENTRY_FIXED_SIZE + name_length
	}
	return {}, false, .None
}
