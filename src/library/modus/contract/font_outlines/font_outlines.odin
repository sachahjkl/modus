// The font outlines (src/md/features/glyphs_on_demand.md, "Layer 0: the
// outlines, shared and read-only"): the font files of the system in one
// image-tree object, RESOURCE_NAME, served read-only by the storage service at
// FONT_OUTLINES_OBJECT_PATH. The modus tool writes it from the subsets of
// resources/fonts. Each process maps it through storage.map_object and draws
// glyphs past the glyph caches into its private glyph cache.
//
//   Header        HEADER_SIZE bytes, at 0
//   Font_Record   RECORD_SIZE bytes x font_count, at RECORDS_OFFSET
//   font files    each at its offset, inside file_size
//
// A process validates the header and the records once (validate): no process
// writes the object (docs/FONTS.md, "Who can write a cache"). The parser of
// src/library/modus/vector_font checks each read of a font file against its
// bytes.
//
// See [font outlines](term:font-outlines).
package font_outlines

import "base:intrinsics"
import "modus:contract/blake3"

MAGIC :: u64(0x53454E494C54554F) // The bytes "OUTLINES".
VERSION :: 1 // The version of the format. A reader refuses another.
HEADER_SIZE :: 64 // The bytes of `Header`.
RECORD_SIZE :: 80 // The bytes of `Font_Record`.
RECORDS_OFFSET :: HEADER_SIZE // The records follow the header.
// The bytes of a font name, its zero bytes included: the size of a name
// of the boot image, so each subset of resources/fonts has room
// (paper_mono_semibold has 19 bytes).
NAME_SIZE :: 32
// The most fonts of one resource: a property of the format. A font of a
// resource has an index of one byte, 1 to FONT_LIMIT, with 0 for none; the
// font field of the key of a glyph cache and of a placed glyph holds the
// fonts of the boot image and FONT_LIMIT more (text_rendering,
// FONT_FIELD_BITS). The tool refuses to write more (resource_write), and
// each reader refuses a header that names more (validate). The records of
// a resource that a reader validated live in the room that the reader
// gives (Outlines.records), sized from the header: a reader that takes
// any resource gives a room of FONT_LIMIT records (Record_Room), a call of
// the library module text_rendering a room of the fonts that it opens.
FONT_LIMIT :: 255
#assert(FONT_LIMIT < 1 << 8)

// A room for the records of any resource that the format allows.
Record_Room :: [FONT_LIMIT]Font_Record
RESOURCE_NAME :: "font_outlines" // The name of the resource in the boot image.
FONT_OUTLINES_OBJECT_PATH :: "fonts/font_outlines" // Exact storage object path under the "fonts" tree grant.
SCRIPT_FONTS_OBJECT_PATH :: "fonts/script_fonts" // Exact storage object path for the verified script font set under the "fonts" tree grant.

// A run of code points with no gap.
Character_Range :: struct {
	first, last: rune,
}

// The characters past the glyph cache that the subsets of the outlines
// hold, after the characters of the glyph cache: the modus tool writes
// them into the subsets (`modustool vector_fonts`). A process does not need
// the lists: it draws any character that a font of its chain has.
//
// The rule of each list: each character of the basic plane past U+00FF
// that the character map of the source font has, with an advance above
// zero or a mark (Mn or Me) with an outline, and that is not a format
// character, a separator of lines or paragraphs, a private use character
// or a control character. A mark that does not compose with its letter
// is drawn on it (src/md/features/written_shaping.md), and a private use
// character names no character that a text of another system holds. So
// the fonts of the system draw each other character that they have, and a
// character is the replacement glyph only when no font of the system has
// it.

// The subsets of B612 Regular and B612 Bold, which have the same
// characters: Latin, the Greek letters, General Punctuation, the arrows,
// the mathematical operators, some geometric shapes and symbols. B612 has
// no capital pi (U+03A0) and no small rho (U+03C1).
@(rodata)
interface_past_cache_ranges := [?]Character_Range {
	{0x0152, 0x0153}, {0x0160, 0x0161}, {0x0178, 0x0178}, {0x0192, 0x0192}, {0x02C6, 0x02C7},
	{0x02D8, 0x02DD}, {0x0391, 0x039F}, {0x03A1, 0x03A1}, {0x03A3, 0x03A9}, {0x03B1, 0x03C0},
	{0x03C2, 0x03C9}, {0x03D1, 0x03D2}, {0x03D5, 0x03D6}, {0x2010, 0x2010}, {0x2013, 0x2016},
	{0x2018, 0x201A}, {0x201C, 0x201E}, {0x2020, 0x2023}, {0x2026, 0x2026}, {0x2030, 0x2035},
	{0x2039, 0x203A}, {0x2042, 0x2042}, {0x2051, 0x2051}, {0x2070, 0x2071}, {0x2074, 0x208E},
	{0x20B9, 0x20B9}, {0x2103, 0x2103}, {0x2109, 0x2109}, {0x2111, 0x2111}, {0x2113, 0x2113},
	{0x2118, 0x2118}, {0x211C, 0x211C}, {0x2122, 0x2122}, {0x2126, 0x2126}, {0x212B, 0x212B},
	{0x2134, 0x2135}, {0x2153, 0x216B}, {0x2170, 0x217B}, {0x2190, 0x2199}, {0x21A9, 0x21AA},
	{0x21B3, 0x21B3}, {0x21B5, 0x21B7}, {0x21D0, 0x21D9}, {0x21DE, 0x21E3}, {0x21E7, 0x21E7},
	{0x21EA, 0x21EA}, {0x2200, 0x2205}, {0x2207, 0x2209}, {0x220B, 0x220C}, {0x2212, 0x2213},
	{0x2218, 0x2218}, {0x221A, 0x221A}, {0x221D, 0x221E}, {0x2222, 0x2222}, {0x2225, 0x2225},
	{0x2227, 0x222B}, {0x222E, 0x222E}, {0x2234, 0x2235}, {0x223C, 0x223C}, {0x2243, 0x2243},
	{0x2245, 0x2245}, {0x2248, 0x2248}, {0x2259, 0x2259}, {0x2260, 0x2261}, {0x2264, 0x2265},
	{0x2282, 0x2283}, {0x2286, 0x2287}, {0x2295, 0x2298}, {0x22A5, 0x22A5}, {0x22C6, 0x22C6},
	{0x22EE, 0x22EE}, {0x2302, 0x2302}, {0x2308, 0x230B}, {0x231C, 0x231F}, {0x25B6, 0x25B9},
	{0x25BC, 0x25BF}, {0x25C9, 0x25C9}, {0x25CE, 0x25D3}, {0x2600, 0x2603}, {0x2605, 0x2605},
	{0x260E, 0x260E}, {0x2610, 0x2612}, {0x2639, 0x263A}, {0x263C, 0x263C}, {0x263E, 0x263E},
	{0x2660, 0x2663}, {0x2690, 0x2691}, {0x26A0, 0x26A1}, {0x2708, 0x2709}, {0x2713, 0x2713},
	{0x2780, 0x2794}, {0xFB00, 0xFB06},
}
INTERFACE_PAST_CACHE_COUNT :: 326 // The characters of interface_past_cache_ranges.

// The subsets of Paper Mono and Paper Mono SemiBold, which have the same
// characters: most of Latin Extended-A, the letters of Romanian, five
// Greek letters, General Punctuation, the arrows, some mathematical
// operators, the box-drawing characters and the block elements.
@(rodata)
cell_past_cache_ranges := [?]Character_Range {
	{0x0100, 0x0113}, {0x0116, 0x012B}, {0x012E, 0x0137}, {0x0139, 0x0148}, {0x014A, 0x014D},
	{0x0150, 0x017E}, {0x018F, 0x018F}, {0x0192, 0x0192}, {0x01CD, 0x01CE}, {0x01E4, 0x01E9},
	{0x0218, 0x021B}, {0x0237, 0x0237}, {0x0259, 0x0259}, {0x02C6, 0x02C7}, {0x02D8, 0x02DD},
	{0x0300, 0x0304}, {0x0306, 0x0308}, {0x030A, 0x030C}, {0x0312, 0x0312}, {0x0326, 0x0328},
	{0x0335, 0x0338}, {0x039B, 0x039B}, {0x03A9, 0x03A9}, {0x03BB, 0x03BC}, {0x03C0, 0x03C0},
	{0x0E3F, 0x0E3F}, {0x1E20, 0x1E21}, {0x1E80, 0x1E85}, {0x1E9E, 0x1E9E}, {0x1EBC, 0x1EBD},
	{0x1EF2, 0x1EF3}, {0x1EF8, 0x1EF9}, {0x2013, 0x2014}, {0x2018, 0x201A}, {0x201C, 0x201E},
	{0x2020, 0x2022}, {0x2026, 0x2026}, {0x2030, 0x2030}, {0x2032, 0x2033}, {0x2039, 0x203A},
	{0x2044, 0x2044}, {0x2070, 0x2070}, {0x2074, 0x2079}, {0x2080, 0x2089}, {0x20AA, 0x20AA},
	{0x20B1, 0x20B1}, {0x20B4, 0x20B4}, {0x20B9, 0x20B9}, {0x20BD, 0x20BD}, {0x2116, 0x2117},
	{0x2122, 0x2122}, {0x2153, 0x2155}, {0x215B, 0x215E}, {0x2190, 0x2199}, {0x21A9, 0x21AA},
	{0x21B0, 0x21B1}, {0x21B3, 0x21B5}, {0x21B9, 0x21B9}, {0x21C6, 0x21C6}, {0x21E4, 0x21E5},
	{0x21E7, 0x21E7}, {0x21EA, 0x21EA}, {0x2202, 0x2202}, {0x2206, 0x2206}, {0x220F, 0x220F},
	{0x2211, 0x2212}, {0x221A, 0x221A}, {0x221E, 0x221E}, {0x222B, 0x222B}, {0x2236, 0x2236},
	{0x2248, 0x2248}, {0x2260, 0x2260}, {0x2264, 0x2265}, {0x2303, 0x2303}, {0x2318, 0x2318},
	{0x2325, 0x2327}, {0x232B, 0x232B}, {0x238B, 0x238B}, {0x23CE, 0x23CE}, {0x2460, 0x2468},
	{0x24EA, 0x24EA}, {0x24FF, 0x259F}, {0x25CA, 0x25CB}, {0x25CF, 0x25CF}, {0x25E6, 0x25E6},
	{0x2776, 0x277E}, {0x3003, 0x3003}, {0x301C, 0x301C}, {0xA78B, 0xA78C}, {0xFB01, 0xFB02},
}
CELL_PAST_CACHE_COUNT :: 467 // The characters of cell_past_cache_ranges.

// The subset of Noto Sans, the font of the scripts that the fonts of the
// faces lack: Latin Extended-A, Latin Extended-B and Latin Extended
// Additional (Vietnamese), the whole Greek and Cyrillic blocks, General
// Punctuation and the currency signs. It closes each fallback chain.
@(rodata)
script_fallback_past_cache_ranges := [?]Character_Range {
	{0x0100, 0x0377}, {0x037A, 0x037F}, {0x0384, 0x038A}, {0x038C, 0x038C}, {0x038E, 0x03A1},
	{0x03A3, 0x03E1}, {0x03F0, 0x052F}, {0x10FB, 0x10FB}, {0x1AB0, 0x1AC0}, {0x1AC5, 0x1AC5},
	{0x1AC7, 0x1ACE}, {0x1C80, 0x1C88}, {0x1D00, 0x1DF9}, {0x1DFB, 0x1F15}, {0x1F18, 0x1F1D},
	{0x1F20, 0x1F45}, {0x1F48, 0x1F4D}, {0x1F50, 0x1F57}, {0x1F59, 0x1F59}, {0x1F5B, 0x1F5B},
	{0x1F5D, 0x1F5D}, {0x1F5F, 0x1F7D}, {0x1F80, 0x1FB4}, {0x1FB6, 0x1FC4}, {0x1FC6, 0x1FD3},
	{0x1FD6, 0x1FDB}, {0x1FDD, 0x1FEF}, {0x1FF2, 0x1FF4}, {0x1FF6, 0x1FFE}, {0x2000, 0x200A},
	{0x2010, 0x2027}, {0x202F, 0x205F}, {0x2070, 0x2071}, {0x2074, 0x208E}, {0x2090, 0x209C},
	{0x20A0, 0x20AB}, {0x20AD, 0x20C0}, {0x20F0, 0x20F0}, {0x2100, 0x215F}, {0x2183, 0x2184},
	{0x2189, 0x2189}, {0x2212, 0x2212}, {0x25CC, 0x25CC}, {0x2C60, 0x2C7F}, {0x2DE0, 0x2E5D},
	{0xA640, 0xA69F}, {0xA700, 0xA7CA}, {0xA7D0, 0xA7D1}, {0xA7D3, 0xA7D3}, {0xA7D5, 0xA7D9},
	{0xA7F2, 0xA7FF}, {0xA92E, 0xA92E}, {0xAB30, 0xAB6B}, {0xFB00, 0xFB06}, {0xFE20, 0xFE2F},
	{0xFFFC, 0xFFFD},
}
SCRIPT_FALLBACK_PAST_CACHE_COUNT :: 2654 // The characters of script_fallback_past_cache_ranges.

// The first HEADER_SIZE bytes of the resource.
Header :: struct {
	magic:      u64, // MAGIC.
	version:    u32, // VERSION.
	font_count: u32, // The records: 1 to FONT_LIMIT, a property of the format.
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
	No_Room, // font_count is above the records of the room of the reader.
	Bad_Name, // A name has a byte outside 33 to 126 before its end, no byte, or a byte after its end; or two records have one name.
	Font_Outside, // A font file is empty, or passes the end of the resource.
	Hash_Mismatch, // The bytes of the resource are not the object that the plan names, or a font file does not give the hash of its record.
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
	.No_Room      = "their count of fonts is past the room of the reader",
	.Bad_Name     = "a font has a name that is not printable bytes, or the name of another font",
	.Font_Outside = "a font file is empty or passes their end",
	.Hash_Mismatch = "their bytes do not give the hash that names them",
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
	records: []Font_Record, // The count records, copied into the room of the reader.
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
// its font file inside the resource. It copies the header, then each
// record into the room of the caller, once, with one read, and checks the
// copies: a byte that changes after that read changes no span that it
// gives. A count past FONT_LIMIT is Bad_Count; a count past the room is
// No_Room, with the room as its limit.
validate :: proc "contextless" (bytes: []u8, room: []Font_Record) -> (outlines: Outlines, problem: Problem) {
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
	if int(count) > len(room) {
		return {}, {kind = .No_Room, value = u64(count), limit = u64(len(room))}
	}
	outlines.records = room[:count]
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

// Where a machine holds the script font set (src/md/features/script_fonts.md):
// the object SCRIPT_FONTS_OBJECT_NAME of the private store
// SCRIPT_FONTS_STORE_NAME of the machine (principal 0). The root service reads
// it once at each start, through the delegated service disk_processes, checks
// it, and publishes a read-only handle to the storage service at
// SCRIPT_FONTS_OBJECT_PATH.
SCRIPT_FONTS_STORE_NAME :: "script_fonts"
SCRIPT_FONTS_OBJECT_NAME :: "script_fonts"

// The most bytes of a set: the root service makes its memory from its own
// budget before it checks the hash, so the limit bounds what an object of
// a disk takes from that budget. The set of today is 35 772 620 bytes.
SCRIPT_FONTS_BYTES_LIMIT :: 64 << 20

// The blocks of the store of the set, as the root service grants the read
// and as the modus tool writes it: the bytes of the limit, and the blocks
// of the tree of the object.
SCRIPT_FONTS_STORE_BLOCKS :: SCRIPT_FONTS_BYTES_LIMIT / 4096 + 1024

// The resource of the boot image that names the set when no plan names
// one: the 32 bytes of the BLAKE3 hash of the set that the build wrote. The
// signed system description lists it as each resource, so the default set
// of a machine is part of its signed system.
SCRIPT_FONTS_NAME_RESOURCE :: "script_fonts_name"

// script_fonts_check checks a script font set where the tool writes it:
// its bytes give the hash that the plan names, its form is valid, and each
// font file gives the hash of its record. Each check is a refusal of the
// whole object: a set is never taken in part. The root service checks the
// hash of the whole object and its form only: the hash of the whole
// already names these bytes (src/md/features/script_fonts.md, "The hash of
// each font against its record in the root service").
script_fonts_check :: proc "contextless" (bytes: []u8, named: [32]u8, room: []Font_Record) -> (outlines: Outlines, problem: Problem) {
	if blake3.hash(bytes) != named {
		return {}, {kind = .Hash_Mismatch}
	}
	outlines, problem = validate(bytes, room)
	if problem.kind != .None {
		return {}, problem
	}
	for index in 0 ..< outlines.count {
		if blake3.hash(font_bytes(&outlines, index)) != outlines.records[index].hash {
			return {}, {kind = .Hash_Mismatch, index = u32(index)}
		}
	}
	return outlines, {}
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