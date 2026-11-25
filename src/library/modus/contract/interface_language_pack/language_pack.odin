// Content-addressed Language_Pack_Manifest and Script_Font_Pack_Manifest
// referencing BLAKE3 object-cache hashes so a machine fetches only the
// languages and scripts its plan names (src/md/features/interface_language.md;
// src/md/features/script_fonts.md).
package interface_language_pack

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/enum_word"

// Format property: 8-byte ASCII magics for language and script-font manifests.
LANGUAGE_PACK_MANIFEST_MAGIC :: [8]u8{'M', 'O', 'D', 'L', 'P', 'K', '0', '1'}
SCRIPT_FONT_MANIFEST_MAGIC :: [8]u8{'M', 'O', 'D', 'S', 'F', 'P', '0', '1'}
PACK_MANIFEST_VERSION :: u32(1)
PACK_MANIFEST_HEADER_SIZE :: 24
LANGUAGE_PACK_ENTRY_SIZE :: 80
SCRIPT_FONT_ENTRY_SIZE :: 48

// Plan value: bound manifest entry counts so a plan manifest fits one 4 KiB page.
LANGUAGE_PACK_ENTRY_LIMIT :: 32
SCRIPT_FONT_ENTRY_LIMIT :: 32

// Closed script codes matching src/md/features/script_fonts.md.
Script_Code :: enum u8 {
	Latin      = 1,
	Greek      = 2,
	Cyrillic   = 3,
	Hebrew     = 4,
	Arabic     = 5,
	Devanagari = 6,
	Thai       = 7,
	Han_Cjk    = 8,
	Emoji      = 9,
	Symbols    = 10,
}

// Closed refusal reasons for pack manifest encoding, validation, and fetch planning.
Pack_Manifest_Refusal :: enum u8 {
	None                = 0,
	Buffer_Too_Small    = 1,
	Bad_Magic           = 2,
	Unsupported_Version = 3,
	Bad_Length          = 4,
	Too_Many_Entries    = 5,
	Invalid_Tag         = 6,
	Unknown_Enum_Word   = 7,
	Zero_Hash           = 8,
	Zero_Byte_Size      = 9,
	Duplicate_Entry     = 10,
	Entry_Not_Found     = 11,
}

script_code_of_word :: proc "contextless" (word: u64) -> (code: Script_Code, ok: bool) {
	return enum_word.member_of_word(Script_Code, word)
}

@(private = "file")
hash_is_zero :: proc "contextless" (hash: blake3.Hash) -> bool {
	acc := u8(0)
	for b in hash {
		acc |= b
	}
	return acc == 0
}

// One content-addressed language pack entry inside Language_Pack_Manifest.
Language_Pack_Entry :: struct {
	tag:        Cldr_Language_Tag, // 36 bytes
	reserved:   u32,               // 4 bytes (must be 0)
	object_hash: blake3.Hash,      // 32 bytes (BLAKE3 in object cache)
	byte_size:  u64,               // 8 bytes (must be > 0)
}
#assert(size_of(Language_Pack_Entry) == LANGUAGE_PACK_ENTRY_SIZE)

// Top-level manifest of available cached language packs pinned to CLDR version.
Language_Pack_Manifest :: struct {
	cldr_version: u32,
	entries:      [LANGUAGE_PACK_ENTRY_LIMIT]Language_Pack_Entry,
	entry_count:  u32,
}

// One content-addressed script font pack entry inside Script_Font_Pack_Manifest.
Script_Font_Entry :: struct {
	script:      Script_Code,
	reserved:    [7]u8,
	object_hash: blake3.Hash,
	byte_size:   u64,
}
#assert(size_of(Script_Font_Entry) == SCRIPT_FONT_ENTRY_SIZE)

// Top-level manifest of available cached script font packs pinned to Unicode version.
Script_Font_Pack_Manifest :: struct {
	unicode_version: u32,
	entries:         [SCRIPT_FONT_ENTRY_LIMIT]Script_Font_Entry,
	entry_count:     u32,
}

language_pack_manifest_encode :: proc "contextless" (manifest: ^Language_Pack_Manifest, out: []u8) -> (written: int, refusal: Pack_Manifest_Refusal) {
	if manifest == nil {
		return 0, .Bad_Length
	}
	if manifest.entry_count > LANGUAGE_PACK_ENTRY_LIMIT {
		return 0, .Too_Many_Entries
	}
	total := PACK_MANIFEST_HEADER_SIZE + int(manifest.entry_count) * LANGUAGE_PACK_ENTRY_SIZE
	if total > len(out) {
		return 0, .Buffer_Too_Small
	}
	for i in u32(0) ..< manifest.entry_count {
		entry := manifest.entries[i]
		if cldr_tag_record_valid(entry.tag) != .None {
			return 0, .Invalid_Tag
		}
		if entry.reserved != 0 {
			return 0, .Bad_Length
		}
		if hash_is_zero(entry.object_hash) {
			return 0, .Zero_Hash
		}
		if entry.byte_size == 0 {
			return 0, .Zero_Byte_Size
		}
		for j in u32(0) ..< i {
			if manifest.entries[j].tag == entry.tag {
				return 0, .Duplicate_Entry
			}
		}
	}

	magic := LANGUAGE_PACK_MANIFEST_MAGIC
	for i in 0 ..< 8 {
		out[i] = magic[i]
	}
	byte_order.write_u32_little_endian(out, 8, PACK_MANIFEST_VERSION)
	byte_order.write_u32_little_endian(out, 12, manifest.cldr_version)
	byte_order.write_u32_little_endian(out, 16, manifest.entry_count)
	byte_order.write_u32_little_endian(out, 20, u32(total))

	at := PACK_MANIFEST_HEADER_SIZE
	for i in u32(0) ..< manifest.entry_count {
		entry := manifest.entries[i]
		copy(out[at + 0 : at + 8], entry.tag.language[:])
		copy(out[at + 8 : at + 12], entry.tag.script[:])
		copy(out[at + 12 : at + 16], entry.tag.region[:])
		copy(out[at + 16 : at + 24], entry.tag.variants[0][:])
		copy(out[at + 24 : at + 32], entry.tag.variants[1][:])
		out[at + 32] = entry.tag.variant_count
		out[at + 33] = 0
		out[at + 34] = 0
		out[at + 35] = 0
		byte_order.write_u32_little_endian(out, at + 36, 0)
		copy(out[at + 40 : at + 72], entry.object_hash[:])
		byte_order.write_u64_little_endian(out, at + 72, entry.byte_size)
		at += LANGUAGE_PACK_ENTRY_SIZE
	}
	return total, .None
}

language_pack_manifest_decode :: proc "contextless" (bytes: []u8, manifest: ^Language_Pack_Manifest) -> Pack_Manifest_Refusal {
	if manifest == nil || len(bytes) < PACK_MANIFEST_HEADER_SIZE {
		return .Buffer_Too_Small
	}
	magic := LANGUAGE_PACK_MANIFEST_MAGIC
	for i in 0 ..< 8 {
		if bytes[i] != magic[i] {
			return .Bad_Magic
		}
	}
	if byte_order.read_u32_little_endian(bytes, 8) != PACK_MANIFEST_VERSION {
		return .Unsupported_Version
	}
	cldr_ver := byte_order.read_u32_little_endian(bytes, 12)
	count := byte_order.read_u32_little_endian(bytes, 16)
	declared_total := byte_order.read_u32_little_endian(bytes, 20)
	if count > LANGUAGE_PACK_ENTRY_LIMIT {
		return .Too_Many_Entries
	}
	expected_total := PACK_MANIFEST_HEADER_SIZE + int(count) * LANGUAGE_PACK_ENTRY_SIZE
	if int(declared_total) != expected_total || len(bytes) != expected_total {
		return .Bad_Length
	}

	parsed: Language_Pack_Manifest
	parsed.cldr_version = cldr_ver
	parsed.entry_count = count
	at := PACK_MANIFEST_HEADER_SIZE
	for i in u32(0) ..< count {
		entry: Language_Pack_Entry
		copy(entry.tag.language[:], bytes[at + 0 : at + 8])
		copy(entry.tag.script[:], bytes[at + 8 : at + 12])
		copy(entry.tag.region[:], bytes[at + 12 : at + 16])
		copy(entry.tag.variants[0][:], bytes[at + 16 : at + 24])
		copy(entry.tag.variants[1][:], bytes[at + 24 : at + 32])
		entry.tag.variant_count = bytes[at + 32]
		entry.tag.reserved = {bytes[at + 33], bytes[at + 34], bytes[at + 35]}
		entry.reserved = byte_order.read_u32_little_endian(bytes, at + 36)
		copy(entry.object_hash[:], bytes[at + 40 : at + 72])
		entry.byte_size = byte_order.read_u64_little_endian(bytes, at + 72)

		if cldr_tag_record_valid(entry.tag) != .None {
			return .Invalid_Tag
		}
		if entry.reserved != 0 {
			return .Bad_Length
		}
		if hash_is_zero(entry.object_hash) {
			return .Zero_Hash
		}
		if entry.byte_size == 0 {
			return .Zero_Byte_Size
		}
		for j in u32(0) ..< i {
			if parsed.entries[j].tag == entry.tag {
				return .Duplicate_Entry
			}
		}
		parsed.entries[i] = entry
		at += LANGUAGE_PACK_ENTRY_SIZE
	}
	manifest^ = parsed
	return .None
}

script_font_manifest_encode :: proc "contextless" (manifest: ^Script_Font_Pack_Manifest, out: []u8) -> (written: int, refusal: Pack_Manifest_Refusal) {
	if manifest == nil {
		return 0, .Bad_Length
	}
	if manifest.entry_count > SCRIPT_FONT_ENTRY_LIMIT {
		return 0, .Too_Many_Entries
	}
	total := PACK_MANIFEST_HEADER_SIZE + int(manifest.entry_count) * SCRIPT_FONT_ENTRY_SIZE
	if total > len(out) {
		return 0, .Buffer_Too_Small
	}
	for i in u32(0) ..< manifest.entry_count {
		entry := manifest.entries[i]
		if _, ok := script_code_of_word(u64(entry.script)); !ok {
			return 0, .Unknown_Enum_Word
		}
		if entry.reserved != {} {
			return 0, .Bad_Length
		}
		if hash_is_zero(entry.object_hash) {
			return 0, .Zero_Hash
		}
		if entry.byte_size == 0 {
			return 0, .Zero_Byte_Size
		}
		for j in u32(0) ..< i {
			if manifest.entries[j].script == entry.script {
				return 0, .Duplicate_Entry
			}
		}
	}

	magic := SCRIPT_FONT_MANIFEST_MAGIC
	for i in 0 ..< 8 {
		out[i] = magic[i]
	}
	byte_order.write_u32_little_endian(out, 8, PACK_MANIFEST_VERSION)
	byte_order.write_u32_little_endian(out, 12, manifest.unicode_version)
	byte_order.write_u32_little_endian(out, 16, manifest.entry_count)
	byte_order.write_u32_little_endian(out, 20, u32(total))

	at := PACK_MANIFEST_HEADER_SIZE
	for i in u32(0) ..< manifest.entry_count {
		entry := manifest.entries[i]
		out[at + 0] = u8(entry.script)
		for k in 1 ..< 8 {
			out[at + k] = 0
		}
		copy(out[at + 8 : at + 40], entry.object_hash[:])
		byte_order.write_u64_little_endian(out, at + 40, entry.byte_size)
		at += SCRIPT_FONT_ENTRY_SIZE
	}
	return total, .None
}

script_font_manifest_decode :: proc "contextless" (bytes: []u8, manifest: ^Script_Font_Pack_Manifest) -> Pack_Manifest_Refusal {
	if manifest == nil || len(bytes) < PACK_MANIFEST_HEADER_SIZE {
		return .Buffer_Too_Small
	}
	magic := SCRIPT_FONT_MANIFEST_MAGIC
	for i in 0 ..< 8 {
		if bytes[i] != magic[i] {
			return .Bad_Magic
		}
	}
	if byte_order.read_u32_little_endian(bytes, 8) != PACK_MANIFEST_VERSION {
		return .Unsupported_Version
	}
	unicode_ver := byte_order.read_u32_little_endian(bytes, 12)
	count := byte_order.read_u32_little_endian(bytes, 16)
	declared_total := byte_order.read_u32_little_endian(bytes, 20)
	if count > SCRIPT_FONT_ENTRY_LIMIT {
		return .Too_Many_Entries
	}
	expected_total := PACK_MANIFEST_HEADER_SIZE + int(count) * SCRIPT_FONT_ENTRY_SIZE
	if int(declared_total) != expected_total || len(bytes) != expected_total {
		return .Bad_Length
	}

	parsed: Script_Font_Pack_Manifest
	parsed.unicode_version = unicode_ver
	parsed.entry_count = count
	at := PACK_MANIFEST_HEADER_SIZE
	for i in u32(0) ..< count {
		entry: Script_Font_Entry
		script_member, script_ok := script_code_of_word(u64(bytes[at + 0]))
		if !script_ok {
			return .Unknown_Enum_Word
		}
		entry.script = script_member
		for k in 0 ..< 7 {
			if bytes[at + 1 + k] != 0 {
				return .Bad_Length
			}
		}
		copy(entry.object_hash[:], bytes[at + 8 : at + 40])
		entry.byte_size = byte_order.read_u64_little_endian(bytes, at + 40)
		if hash_is_zero(entry.object_hash) {
			return .Zero_Hash
		}
		if entry.byte_size == 0 {
			return .Zero_Byte_Size
		}
		for j in u32(0) ..< i {
			if parsed.entries[j].script == entry.script {
				return .Duplicate_Entry
			}
		}
		parsed.entries[i] = entry
		at += SCRIPT_FONT_ENTRY_SIZE
	}
	manifest^ = parsed
	return .None
}

// plan_fetch_hashes_collect resolves only the BLAKE3 hashes for the languages
// and scripts named by a machine's plan, deduplicating identical object hashes.
plan_fetch_hashes_collect :: proc "contextless" (
	lang_manifest: ^Language_Pack_Manifest,
	wanted_languages: []Cldr_Language_Tag,
	font_manifest: ^Script_Font_Pack_Manifest,
	wanted_scripts: []Script_Code,
	out_hashes: []blake3.Hash,
) -> (count: int, refusal: Pack_Manifest_Refusal) {
	append_unique :: proc "contextless" (dst: []blake3.Hash, used: ^int, h: blake3.Hash) -> Pack_Manifest_Refusal {
		if hash_is_zero(h) {
			return .Zero_Hash
		}
		for i in 0 ..< used^ {
			if dst[i] == h {
				return .None
			}
		}
		if used^ >= len(dst) {
			return .Buffer_Too_Small
		}
		dst[used^] = h
		used^ += 1
		return .None
	}

	used := 0
	for wanted in wanted_languages {
		if lang_manifest == nil {
			return 0, .Entry_Not_Found
		}
		found := false
		for i in u32(0) ..< lang_manifest.entry_count {
			if lang_manifest.entries[i].tag == wanted {
				if err := append_unique(out_hashes, &used, lang_manifest.entries[i].object_hash); err != .None {
					return 0, err
				}
				found = true
				break
			}
		}
		if !found {
			return 0, .Entry_Not_Found
		}
	}
	for wanted in wanted_scripts {
		if font_manifest == nil {
			return 0, .Entry_Not_Found
		}
		found := false
		for i in u32(0) ..< font_manifest.entry_count {
			if font_manifest.entries[i].script == wanted {
				if err := append_unique(out_hashes, &used, font_manifest.entries[i].object_hash); err != .None {
					return 0, err
				}
				found = true
				break
			}
		}
		if !found {
			return 0, .Entry_Not_Found
		}
	}
	return used, .None
}
