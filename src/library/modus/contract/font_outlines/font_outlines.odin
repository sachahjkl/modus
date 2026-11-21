// The font outlines (src/md/features/glyphs_on_demand.md, "Layer 0: the
// outlines, shared and read-only"): the font files of the system in one
// resource of the boot image,
// RESOURCE_NAME. The modus tool writes it from the subsets of
// resources/fonts. The root service checks its hash once, and maps it
// read-only at ADDRESS in each process that gets the glyph caches. A
// process draws from it the glyphs past the glyph caches into its private
// glyph cache.
//
//   Header        HEADER_SIZE bytes, at 0
//   Font_Record   RECORD_SIZE bytes x font_count, at RECORDS_OFFSET
//   font files    each at its offset, inside file_size
//
// A process validates the header and the records once (validate_at): no
// process writes the resource, as no process writes a glyph cache
// (docs/FONTS.md, "Who can write a cache"). The parser of
// src/library/modus/vector_font checks each read of a font file against
// its bytes.
//
// See [font outlines](term:font-outlines).
package font_outlines

import "base:intrinsics"
import "modus:contract/blake3"
import "modus:contract/fixed_addresses"
import op "modus:contract/operation"

MAGIC :: u64(0x53454E494C54554F) // The bytes "OUTLINES".
VERSION :: 1 // The version of the format. A reader refuses another.
HEADER_SIZE :: 64 // The bytes of `Header`.
RECORD_SIZE :: 80 // The bytes of `Font_Record`.
RECORDS_OFFSET :: HEADER_SIZE // The records follow the header.
// The bytes of a font name, its zero bytes included: the size of a name
// of the boot image, so each subset of resources/fonts has room
// (paper_mono_semibold has 19 bytes).
NAME_SIZE :: 32
FONT_LIMIT :: 8 // The most fonts of one resource.
RESOURCE_NAME :: "font_outlines" // The name of the resource in the boot image.
ADDRESS :: fixed_addresses.FONT_OUTLINES_ADDRESS // Where a process maps it, read-only.

// A run of code points with no gap.
Character_Range :: struct {
	first, last: rune,
}

// The characters past the glyph cache that the subsets of the outlines
// hold, after the characters of the glyph cache: the modus tool writes
// them into the subsets (`modustool vector_fonts`), and the golden hashes
// of the glyphs that a process draws from them name them. A process does
// not need the list: it draws any character that a font of its chain has.
//
// The subset of B612 Regular: the Greek letters that the character map of
// B612 1.008 has. It lacks the capital pi (U+03A0) and the small rho
// (U+03C1); U+03A2 is no character.
@(rodata)
interface_past_cache_ranges := [?]Character_Range {
	{0x0391, 0x039F}, // Alpha to omicron, capitals.
	{0x03A1, 0x03A1}, // Rho, capital.
	{0x03A3, 0x03A9}, // Sigma to omega, capitals.
	{0x03B1, 0x03C0}, // Alpha to pi, small.
	{0x03C2, 0x03C9}, // Final sigma to omega, small.
}
INTERFACE_PAST_CACHE_COUNT :: 47 // The characters of interface_past_cache_ranges.

// The subsets of Paper Mono and Paper Mono SemiBold: the five Greek
// letters of Paper Mono, the box-drawing characters and the block
// elements. It has no other Greek letter.
@(rodata)
cell_past_cache_ranges := [?]Character_Range {
	{0x039B, 0x039B}, // Lambda, capital.
	{0x03A9, 0x03A9}, // Omega, capital.
	{0x03BB, 0x03BC}, // Lambda and mu, small.
	{0x03C0, 0x03C0}, // Pi, small.
	{0x2500, 0x257F}, // The box-drawing characters.
	{0x2580, 0x259F}, // The block elements.
}
CELL_PAST_CACHE_COUNT :: 165 // The characters of cell_past_cache_ranges.

// The first HEADER_SIZE bytes of the resource.
Header :: struct {
	magic:      u64, // MAGIC.
	version:    u32, // VERSION.
	font_count: u32, // The records: 1 to FONT_LIMIT.
	file_size:  u64, // The bytes of the resource.
	reserved:   [40]u8,
}
#assert(size_of(Header) == HEADER_SIZE)

// One font file of the resource.
Font_Record :: struct {
	name:   [NAME_SIZE]u8, // The name of the font file in resources/fonts, with no extension: bytes 33 to 126, then zero bytes.
	hash:   [32]u8, // The BLAKE3 hash of the font file: the hash that its glyph cache names.
	offset: u64, // The first byte of the font file, from the start of the resource.
	size:   u64, // The bytes of the font file.
}
#assert(size_of(Font_Record) == RECORD_SIZE)

// Why a resource was refused.
Problem_Kind :: enum u8 {
	None, // The resource is valid.
	Not_Mapped, // The starter of the process did not map it: no byte was read.
	Too_Short, // The resource is shorter than its header or than its records, or its address is not aligned.
	Bad_Magic, // It does not start with MAGIC.
	Bad_Version, // Another version.
	Bad_Size, // file_size is under the header or past the span of the range.
	Bad_Count, // font_count is 0 or above FONT_LIMIT.
	Bad_Name, // A name has a byte outside 33 to 126 before its end, no byte, or a byte after its end; or two records have one name.
	Font_Outside, // A font file is empty, or passes the end of the resource.
}

// The words of each problem, for the log.
problem_sentences := [Problem_Kind]string {
	.None         = "none",
	.Not_Mapped   = "the starter did not map them",
	.Too_Short    = "they are shorter than their header or their records",
	.Bad_Magic    = "they do not start with the magic of the format",
	.Bad_Version  = "they have another version of the format",
	.Bad_Size     = "their size is under their header or past their range",
	.Bad_Count    = "their count of fonts is 0 or past the limit",
	.Bad_Name     = "a font has a name that is not printable bytes, or the name of another font",
	.Font_Outside = "a font file is empty or passes their end",
}

// Why a resource was refused, with the record and the value.
Problem :: struct {
	kind:  Problem_Kind, // What is wrong.
	index: u32, // The record.
	value: u64, // The value that the resource has.
	limit: u64, // The value that the reader needs.
}

// Outlines: a resource that validate accepted, with a copy of its header
// and of its records. The bytes of the resource can be memory that another
// thread changes, as a call region is: each span of a font comes from the
// copy that validate checked, never from a second read of the bytes.
Outlines :: struct {
	header:  Header,
	records: [FONT_LIMIT]Font_Record, // The first count records.
	count:   int, // The records: 1 to FONT_LIMIT.
	bytes:   []u8, // The whole resource: file_size bytes.
}

// name_of gives the name of a record of a valid resource.
name_of :: proc "contextless" (record: ^Font_Record) -> string {
	length := 0
	for length < NAME_SIZE && record.name[length] != 0 {
		length += 1
	}
	return string(record.name[:length])
}

// name_valid says if a name has 1 to NAME_SIZE - 1 bytes from 33 to 126,
// then only zero bytes.
@(private)
name_valid :: proc "contextless" (name: [NAME_SIZE]u8) -> bool {
	length := 0
	for length < NAME_SIZE && name[length] != 0 {
		if name[length] < 33 || name[length] > 126 {
			return false
		}
		length += 1
	}
	if length == 0 || length == NAME_SIZE {
		return false
	}
	for index in length ..< NAME_SIZE {
		if name[index] != 0 {
			return false
		}
	}
	return true
}

// validate checks a resource: its header, then each record: its name, and
// its font file inside the resource. It copies the header and each record
// once, with one read, and checks the copies: a byte that changes after
// that read changes no span that it gives.
validate :: proc "contextless" (bytes: []u8) -> (outlines: Outlines, problem: Problem) {
	if len(bytes) < HEADER_SIZE || uintptr(raw_data(bytes)) % 8 != 0 {
		return {}, {kind = .Too_Short, value = u64(len(bytes)), limit = HEADER_SIZE}
	}
	outlines.header = intrinsics.volatile_load((^Header)(raw_data(bytes)))
	header := &outlines.header
	if header.magic != MAGIC {
		return {}, {kind = .Bad_Magic, value = header.magic, limit = MAGIC}
	}
	if header.version != VERSION {
		return {}, {kind = .Bad_Version, value = u64(header.version), limit = VERSION}
	}
	if header.file_size != u64(len(bytes)) {
		return {}, {kind = .Bad_Size, value = header.file_size, limit = u64(len(bytes))}
	}
	count := header.font_count
	if count == 0 || count > FONT_LIMIT {
		return {}, {kind = .Bad_Count, value = u64(count), limit = FONT_LIMIT}
	}
	records_end := u64(RECORDS_OFFSET) + u64(count) * RECORD_SIZE
	if records_end > u64(len(bytes)) {
		return {}, {kind = .Too_Short, value = u64(len(bytes)), limit = records_end}
	}
	in_bytes := ([^]Font_Record)(&bytes[RECORDS_OFFSET])
	for index in 0 ..< int(count) {
		outlines.records[index] = intrinsics.volatile_load(&in_bytes[index])
		record := &outlines.records[index]
		if !name_valid(record.name) {
			return {}, {kind = .Bad_Name, index = u32(index)}
		}
		for &before in outlines.records[:index] {
			if before.name == record.name {
				return {}, {kind = .Bad_Name, index = u32(index)}
			}
		}
		// No sum wraps: each value is under the size of the resource first.
		if record.size == 0 || record.offset < records_end || record.offset > u64(len(bytes)) || record.size > u64(len(bytes)) - record.offset {
			return {}, {kind = .Font_Outside, index = u32(index), value = record.offset, limit = u64(len(bytes))}
		}
	}
	outlines.count = int(count)
	outlines.bytes = bytes
	return outlines, {}
}

// validate_at checks the resource that a starter mapped at an address: the
// size of its header, inside the span of the range, then the whole
// resource.
validate_at :: proc "contextless" (address: uintptr, span: u64) -> (outlines: Outlines, problem: Problem) {
	if address == 0 || address % 8 != 0 {
		return {}, {kind = .Too_Short, value = u64(address)}
	}
	size := (^Header)(address).file_size
	if size < HEADER_SIZE || size > span {
		return {}, {kind = .Bad_Size, value = size, limit = span}
	}
	return validate(([^]u8)(address)[:size])
}

// open validates the resource that the starter of a process mapped at
// ADDRESS: Not_Mapped when the bit of its range is clear, and nothing is
// read.
open :: proc "contextless" (values: ^[op.CONTEXT_VALUES]u64) -> (outlines: Outlines, problem: Problem) {
	if .Font_Outlines not_in fixed_addresses.ranges_mapped(values) {
		return {}, {kind = .Not_Mapped}
	}
	place := fixed_addresses.range_of(.Font_Outlines)
	return validate_at(uintptr(place.address), place.span)
}

// font_bytes gives the font file of a record of a valid resource, from the
// copy of the record that validate checked.
font_bytes :: proc "contextless" (outlines: ^Outlines, index: int) -> []u8 {
	record := &outlines.records[index]
	return outlines.bytes[record.offset:][:record.size]
}

// Font_Input: one font file that resource_write puts in a resource.
Font_Input :: struct {
	name:  string, // 1 to NAME_SIZE - 1 bytes from 33 to 126.
	bytes: []u8,
}

// FONT_ALIGNMENT: each font file starts on a multiple of it.
FONT_ALIGNMENT :: 8

// resource_size gives the bytes of the resource of a list of fonts.
resource_size :: proc "contextless" (fonts: []Font_Input) -> int {
	size := RECORDS_OFFSET + len(fonts) * RECORD_SIZE
	for font in fonts {
		size = (size + FONT_ALIGNMENT - 1) / FONT_ALIGNMENT * FONT_ALIGNMENT + len(font.bytes)
	}
	return size
}

// resource_write writes the resource of a list of fonts into out, at most
// FONT_LIMIT of them, each with the BLAKE3 hash of its file: the modus tool
// writes the resource of the boot image with it. ok is false, and out is
// left as it was, for no font, more than FONT_LIMIT, an empty file, a name
// that validate refuses, or an out shorter than resource_size; out must
// start on a multiple of 8.
resource_write :: proc "contextless" (fonts: []Font_Input, out: []u8) -> (size: int, ok: bool) {
	size = resource_size(fonts)
	if len(fonts) == 0 || len(fonts) > FONT_LIMIT || len(out) < size || uintptr(raw_data(out)) % 8 != 0 {
		return 0, false
	}
	for font, index in fonts {
		if len(font.name) == 0 || len(font.name) >= NAME_SIZE || len(font.bytes) == 0 {
			return 0, false
		}
		for name_byte in transmute([]u8)font.name {
			if name_byte < 33 || name_byte > 126 {
				return 0, false
			}
		}
		for before in fonts[:index] {
			if before.name == font.name {
				return 0, false
			}
		}
	}
	for &cleared in out[:size] {
		cleared = 0
	}
	header := (^Header)(raw_data(out))
	header^ = {magic = MAGIC, version = VERSION, font_count = u32(len(fonts)), file_size = u64(size)}
	records := ([^]Font_Record)(&out[RECORDS_OFFSET])[:len(fonts)]
	place := RECORDS_OFFSET + len(fonts) * RECORD_SIZE
	for font, index in fonts {
		place = (place + FONT_ALIGNMENT - 1) / FONT_ALIGNMENT * FONT_ALIGNMENT
		copy(records[index].name[:], font.name)
		records[index].hash = blake3.hash(font.bytes)
		records[index].offset = u64(place)
		records[index].size = u64(len(font.bytes))
		copy(out[place:][:len(font.bytes)], font.bytes)
		place += len(font.bytes)
	}
	return size, true
}
