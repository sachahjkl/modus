// Compile-time string interner backed by modus:hash_table.Slice_Hash_Index.
//
// Interns identifiers, field names, enum members, and static keys once at
// parse/compile time into compact 32-bit Sym_Id handles so equality checks
// are single integer compares. Dynamic runtime strings (concatenation,
// interpolation) live in the evaluation string arena and never enter the
// interner table.
//
// Freestanding, zero allocation, caller-supplied slices and hash seed (0 is
// valid and deterministic for zero-handle declaration_eval).
package lex_parser

import "modus:hash_table"

// Interned compile-time symbol identifier. 0 is NO_SYM (ZII); valid symbols
// start at 1.
Sym_Id :: distinct u32

NO_SYM :: Sym_Id(0)

// Location of one interned symbol's UTF-8 bytes inside String_Interner.bytes.
Sym_Span :: struct {
	offset: u32,
	length: u32,
	hash:   u64,
}

// Compile-time string interner backed by caller-owned slices.
String_Interner :: struct {
	index:     hash_table.Slice_Hash_Index(u32),
	spans:     []Sym_Span, // Indexed by Sym_Id (slot 0 unused so NO_SYM == 0).
	sym_count: u32,        // Number of interned symbols; next Sym_Id is sym_count + 1.
	bytes:     []u8,       // Backing byte arena holding copied symbol UTF-8 bytes.
	byte_used: u32,
}

// interner_init binds caller-owned slices into an empty String_Interner with
// caller-supplied hash seed. Refuses undersized buffers (fewer than 2 span
// slots or invalid Slice_Hash_Index slices) without mutating caller memory.
interner_init :: proc "contextless" (
	controls: []u8,
	references: []u32,
	spans: []Sym_Span,
	bytes: []u8,
	seed: u64 = 0,
) -> (interner: String_Interner, ok: bool) {
	if len(spans) < 2 {
		return {}, false
	}
	idx := hash_table.slice_index_init(u32, controls, references, seed) or_return
	spans[0] = {}
	return {
		index     = idx,
		spans     = spans,
		sym_count = 0,
		bytes     = bytes,
		byte_used = 0,
	}, true
}

// interner_clear empties all interned symbols while keeping the table seed.
interner_clear :: proc "contextless" (interner: ^String_Interner) {
	hash_table.slice_index_clear(&interner.index)
	interner.sym_count = 0
	interner.byte_used = 0
}

@(private = "file")
interner_hash_of_reference :: proc "contextless" (owner: rawptr, reference: u64) -> u64 {
	interner := (^String_Interner)(owner)
	idx := int(reference)
	if idx <= 0 || idx >= len(interner.spans) {
		return 0
	}
	return interner.spans[idx].hash
}

// intern_lookup finds an already-interned symbol without mutating the table.
intern_lookup :: proc "contextless" (interner: ^String_Interner, text: string) -> (sym: Sym_Id, found: bool) {
	if interner == nil || interner.index.group_count <= 0 {
		return NO_SYM, false
	}
	h := hash_table.slice_index_hash_bytes(&interner.index, transmute([]u8)text)
	search := hash_table.slice_index_search_begin(&interner.index, h)
	for ref, _ in hash_table.slice_index_search_next(&interner.index, &search) {
		if int(ref) <= int(interner.sym_count) {
			span := interner.spans[ref]
			if int(span.length) == len(text) && string(interner.bytes[span.offset:span.offset + span.length]) == text {
				return Sym_Id(ref), true
			}
		}
	}
	return NO_SYM, false
}

// intern returns the Sym_Id for `text`, inserting a copy into the interner if
// absent. Returns (NO_SYM, false) cleanly without modifying state if spans,
// bytes, or hash index capacity is exhausted.
intern :: proc "contextless" (interner: ^String_Interner, text: string) -> (sym: Sym_Id, ok: bool) {
	if interner == nil || interner.index.group_count <= 0 {
		return NO_SYM, false
	}
	h := hash_table.slice_index_hash_bytes(&interner.index, transmute([]u8)text)
	search := hash_table.slice_index_search_begin(&interner.index, h)
	for ref, _ in hash_table.slice_index_search_next(&interner.index, &search) {
		if int(ref) <= int(interner.sym_count) {
			span := interner.spans[ref]
			if int(span.length) == len(text) && string(interner.bytes[span.offset:span.offset + span.length]) == text {
				return Sym_Id(ref), true
			}
		}
	}
	next_id := interner.sym_count + 1
	if int(next_id) >= len(interner.spans) {
		return NO_SYM, false
	}
	if len(text) > len(interner.bytes) - int(interner.byte_used) {
		return NO_SYM, false
	}
	// Pre-populate span before insert so any in-place rebuild sees its hash.
	off := interner.byte_used
	copy(interner.bytes[off:], text)
	interner.spans[next_id] = {offset = off, length = u32(len(text)), hash = h}
	if !hash_table.slice_index_insert(&interner.index, h, next_id, interner, interner_hash_of_reference) {
		interner.spans[next_id] = {}
		return NO_SYM, false
	}
	interner.byte_used = off + u32(len(text))
	interner.sym_count = next_id
	return Sym_Id(next_id), true
}

// sym_text returns the UTF-8 string of an interned symbol, or "" for NO_SYM
// or an out-of-range id.
sym_text :: proc "contextless" (interner: ^String_Interner, sym: Sym_Id) -> string {
	if interner == nil || sym == NO_SYM || u32(sym) > interner.sym_count || int(sym) >= len(interner.spans) {
		return ""
	}
	span := interner.spans[sym]
	if int(span.offset) + int(span.length) > len(interner.bytes) {
		return ""
	}
	return string(interner.bytes[span.offset:span.offset + span.length])
}
