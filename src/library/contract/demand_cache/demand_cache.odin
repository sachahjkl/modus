// The demand cache (src/md/features/glyphs_on_demand.md, "Layer 1: the
// fixed subsets, shared and read-only"): the glyphs of the fixed subsets
// past the glyph caches of the boot image,
// which the font service draws whole at its start, in a fixed order,
// before it ends. The root service creates the memory; the font service
// (the process `glyphs`) is its one writer; each process that gets the
// glyph caches maps it read-only at ADDRESS. So its entries are the same
// whatever the processes draw. A character past it is drawn by the process
// itself, into its private glyph cache (src/library/support/fallback_glyphs).
//
// A face is one glyph cache that the demand cache stands beside (Face): a
// font file in one form. An entry is keyed by its face and its code point,
// so the glyphs of each face stay apart.
//
// The cache changes while a process reads it: the font service publishes
// one entry after the other. So a reader copies each entry once and checks
// it against the constants of this contract, never against a field of the
// shared memory (find). A wrong entry draws the replacement glyph; it is
// never a read outside the cache.
//
//   Header      HEADER_SIZE bytes, at 0, in its own page
//   Entry       ENTRY_SIZE bytes x ENTRY_CAPACITY, at ENTRIES_OFFSET: a hash table by face and code point
//   words       u32 x WORD_CAPACITY, at WORDS_OFFSET: the words of coverage, as in a glyph cache
//
// The glyphs of an entry have the form of the glyph cache of its face
// (face_forms): for the face Interface, a proportional cache with three
// positions at scale 1 and one at the scales 2 and 3; for a cell face, a
// cache of cells with one position at each of its scales, each glyph
// inside its cell.
//
// See [demand cache](term:demand-cache), [font service](term:font-service)
// and [demand face](term:demand-face).
package demand_cache

import "base:intrinsics"
import "modus:contract/fixed_addresses"
import "modus:contract/glyph_cache"
import "modus:contract/text_encoding"

MAGIC :: u64(0x444E414D45444C47) // The bytes "GLDEMAND".
VERSION :: 3 // The version of the format. A reader refuses another.
PAGE_SIZE :: 4096
HEADER_SIZE :: 256 // The bytes of `Header`.
ENTRY_SIZE :: 96 // The bytes of `Entry`.
ENTRY_BITS :: 11
ENTRY_CAPACITY :: 1 << ENTRY_BITS // The places of the hash table: a power of two.
// The places that a search reads at most, from the home place of a key. A
// character that finds no free place in them is refused.
PROBE_LIMIT :: 16
ENTRIES_OFFSET :: PAGE_SIZE // The table after the page of the header.
WORDS_OFFSET :: ENTRIES_OFFSET + ENTRY_CAPACITY * ENTRY_SIZE
// The words of coverage: 4 MiB, for the most words that the subsets can
// take within the limits that entry_valid checks (WORD_BOUND): about 5 %
// of margin over it.
WORD_CAPACITY :: 1024 * 1024
SIZE :: WORDS_OFFSET + WORD_CAPACITY * 4 // The bytes of the demand cache.
PAGE_COUNT :: SIZE / PAGE_SIZE
#assert(SIZE % PAGE_SIZE == 0)
#assert(WORDS_OFFSET % 64 == 0)
#assert(SIZE <= fixed_addresses.RANGE_SPAN)
#assert(HEADER_SIZE <= PAGE_SIZE)

ADDRESS :: fixed_addresses.DEMAND_CACHE_ADDRESS // Where a process maps the demand cache, read-only.

// The scales and the places of the glyphs of one entry: three positions
// at scale 1 and one at the scales 2 and 3, the most that a face has.
SIZE_COUNT :: glyph_cache.SIZE_LIMIT
POSITIONS_AT_SCALE_ONE :: glyph_cache.POSITION_LIMIT
GLYPH_COUNT :: POSITIONS_AT_SCALE_ONE + SIZE_COUNT - 1 // The glyph entries of one character.
LINE_HEIGHT_AT_SCALE_ONE :: glyph_cache.CELL_HEIGHT_LIMIT / glyph_cache.SIZE_LIMIT // 16 pixels.
CELL_WIDTH_AT_SCALE_ONE :: glyph_cache.CELL_WIDTH_LIMIT / glyph_cache.SIZE_LIMIT // 8 pixels.

// The faces of the demand cache: each glyph cache of the boot image that a
// glyph on demand stands beside. The order is the order of the work of the
// font service at its start.
Face :: enum u8 {
	Interface, // B612 Regular: the glyph cache of the interface font.
	Cells, // Paper Mono, with the grid fit: the glyph cache of the cells.
	Cells_Without_Grid_Fit, // Paper Mono, with no grid fit: the cache of the setting grid_fit off.
	Cells_Bold, // Paper Mono SemiBold, at scale 1: the cache of the bold weight.
}

// The form of the glyph cache of a face. A face of cells keeps each glyph
// in its cell: it starts at the left of the cell, is at most as wide as
// the cell, and its advance is the width of the cell.
Face_Form :: struct {
	proportional: bool, // Each character has its own advance; a glyph is the box of its ink.
	grid_fit:     bool, // The flag FLAG_GRID_FIT of the glyph cache.
	scale_count:  int, // The scales 1 ..= scale_count.
	positions:    [SIZE_COUNT]int, // The positions of each scale; 0 past scale_count.
}

@(rodata)
face_forms := [Face]Face_Form {
	.Interface = {proportional = true, grid_fit = true, scale_count = 3, positions = {3, 1, 1}},
	.Cells = {grid_fit = true, scale_count = 3, positions = {1, 1, 1}},
	.Cells_Without_Grid_Fit = {grid_fit = false, scale_count = 3, positions = {1, 1, 1}},
	.Cells_Bold = {grid_fit = true, scale_count = 1, positions = {1, 0, 0}},
}

// The characters that the subset of a face holds past the glyph cache, in
// the order of the code points, as runs with no gap. The modus tool adds
// them to the subset of the font file of the face, after the characters of
// the glyph cache (tools/modustool/resources/vector_fonts.odin), so the glyphs of the
// glyph cache of the build do not change; only the hash of the font file
// in its header does. Each count of a subset comes from these
// lists (subset_count).
Character_Range :: struct {
	first, last: rune,
}

// The Greek letters that the character map of B612 1.008 has. It lacks the
// capital pi (U+03A0) and the small rho (U+03C1); U+03A2 is no character.
@(rodata)
interface_subset_ranges := [?]Character_Range {
	{0x0391, 0x039F}, // Alpha to omicron, capitals.
	{0x03A1, 0x03A1}, // Rho, capital.
	{0x03A3, 0x03A9}, // Sigma to omega, capitals.
	{0x03B1, 0x03C0}, // Alpha to pi, small.
	{0x03C2, 0x03C9}, // Final sigma to omega, small.
}

// The characters past the glyph cache that Paper Mono has, in its regular
// and its SemiBold weight: its five Greek letters, the box-drawing
// characters and the block elements. It has no other Greek letter.
@(rodata)
cell_subset_ranges := [?]Character_Range {
	{0x039B, 0x039B}, // Lambda, capital.
	{0x03A9, 0x03A9}, // Omega, capital.
	{0x03BB, 0x03BC}, // Lambda and mu, small.
	{0x03C0, 0x03C0}, // Pi, small.
	{0x2500, 0x257F}, // The box-drawing characters.
	{0x2580, 0x259F}, // The block elements.
}

// The counts of the two subsets, as constants: the bound of the words is
// computed from them at compile time, and a host test checks that each
// equals subset_count of its face.
INTERFACE_SUBSET_COUNT :: 47
CELL_SUBSET_COUNT :: 165

// The most words of one character within the limits of entry_valid: a
// proportional glyph as wide as GLYPH_WIDTH_LIMIT and as high as its line,
// at each position of each scale; a cell glyph that fills its cell at each
// scale.
INTERFACE_CHARACTER_WORDS_LIMIT :: glyph_cache.GLYPH_WIDTH_LIMIT * LINE_HEIGHT_AT_SCALE_ONE * (POSITIONS_AT_SCALE_ONE * 1 + 2 + 3)
CELL_CHARACTER_WORDS_LIMIT :: CELL_WIDTH_AT_SCALE_ONE * LINE_HEIGHT_AT_SCALE_ONE * (1 * 1 + 2 * 2 + 3 * 3)
BOLD_CELL_CHARACTER_WORDS_LIMIT :: CELL_WIDTH_AT_SCALE_ONE * LINE_HEIGHT_AT_SCALE_ONE
// The most words that the four faces can take: 997 504. The words of the
// cache hold it, so no subset is ever refused, whatever glyphs a font file
// gives within the limits. The subsets of today take 678 016 at most: the
// Greek letters of B612 take under 65 536 (host test
// each_face_of_the_subset_fits_the_demand_cache).
WORD_BOUND :: INTERFACE_SUBSET_COUNT * INTERFACE_CHARACTER_WORDS_LIMIT + 2 * CELL_SUBSET_COUNT * CELL_CHARACTER_WORDS_LIMIT + CELL_SUBSET_COUNT * BOLD_CELL_CHARACTER_WORDS_LIMIT
#assert(WORD_BOUND <= WORD_CAPACITY)

// subset_of gives the runs of the subset of a face.
subset_of :: proc "contextless" (face: Face) -> []Character_Range {
	if face == .Interface {
		return interface_subset_ranges[:]
	}
	return cell_subset_ranges[:]
}

// in_subset says if a character is in the subset of a face. The font
// service draws these and no other character.
in_subset :: proc "contextless" (face: Face, character: rune) -> bool {
	for range in subset_of(face) {
		if character >= range.first && character <= range.last {
			return true
		}
	}
	return false
}

// subset_count gives the count of the characters of the subset of a face.
subset_count :: proc "contextless" (face: Face) -> (count: int) {
	for range in subset_of(face) {
		count += int(range.last - range.first) + 1
	}
	return count
}

// The font file and the style of the glyphs of one face.
Face_Header :: struct {
	font_hash: [32]u8, // BLAKE3 of the font file of the outlines: the file of the glyph cache that the face goes with.
	flags:     u32, // The flags of that glyph cache: glyph_cache.FLAG_GRID_FIT, FLAG_PROPORTIONAL and the filter.
	reserved:  u32,
}
#assert(size_of(Face_Header) == 40)

// The first HEADER_SIZE bytes of the demand cache. The font service writes
// it once, the magic last; then only `generation`, `entry_count`,
// `words_used` and `refused` change.
Header :: struct {
	magic:            u64, // MAGIC, with release, after the other fields.
	version:          u32, // VERSION.
	renderer_version: u32, // The version of the renderer of src/library/support/vector_font.
	generation:       u64, // The count of the publications. A reader reads it once at the start of a frame.
	words_used:       u64, // The words written. A reader does not use it.
	refused:          u64, // The characters that did not fit the table or the words.
	entry_count:      u32, // The entries published. A reader does not use it.
	reserved_word:    u32,
	faces:            [Face]Face_Header,
	reserved:         [48]u8,
}
#assert(size_of(Header) == HEADER_SIZE && offset_of(Header, generation) == 16 && offset_of(Header, faces) == 48)

// The state of an entry.
Entry_State :: enum u32 {
	Empty  = 0, // No character: a free place, or a character that a reader does not find yet.
	Drawn  = 1, // The glyphs and the advances of the character.
	Absent = 2, // A wrong entry: find gives it for an entry that its check refuses, and the process draws the glyph itself. The font service publishes no such entry.
}

// One character of one face of the demand cache. The font service writes
// each field, then `key` with release. An entry never changes after that.
Entry :: struct {
	key:          u32, // key_of the face and the code point; 0: a free place.
	state:        Entry_State,
	generation:   u64, // The generation of the header after its publication.
	advances:     [SIZE_COUNT]i32, // The advance at each scale, in 1/64 of a pixel.
	reserved:     u32,
	glyphs:       [GLYPH_COUNT]glyph_cache.Glyph_Entry, // glyph_place_of; word_offset is from WORDS_OFFSET.
	reserved_end: u32,
}
#assert(size_of(Entry) == ENTRY_SIZE && offset_of(Entry, generation) == 8 && offset_of(Entry, glyphs) == 32)

// The key of an entry: the face above the 21 bits of a code point. A code
// point is never 0 in a key, so a key is never 0, the free place.
KEY_FACE_SHIFT :: 24
#assert(text_encoding.CODE_POINT_LAST < 1 << KEY_FACE_SHIFT)

key_of :: #force_inline proc "contextless" (face: Face, character: rune) -> u32 {
	return u32(face) << KEY_FACE_SHIFT | u32(character)
}

// position_count_of gives the positions of a scale of a face: 0 for a
// scale that the face does not have.
position_count_of :: proc "contextless" (face: Face, scale: int) -> int {
	if scale < 1 || scale > face_forms[face].scale_count {
		return 0
	}
	return face_forms[face].positions[scale - 1]
}

// glyph_place_of gives the place of the glyph of a scale and a position in
// Entry.glyphs: the positions of scale 1, then one glyph for each other
// scale. Each face uses these places, so a face with one position at
// scale 1 leaves the places 1 and 2 empty.
glyph_place_of :: proc "contextless" (scale, position: int) -> (place: int, ok: bool) {
	if scale < 1 || scale > SIZE_COUNT || position < 0 || (scale == 1 && position >= POSITIONS_AT_SCALE_ONE) || (scale > 1 && position != 0) {
		return 0, false
	}
	if scale == 1 {
		return position, true
	}
	return POSITIONS_AT_SCALE_ONE + scale - 2, true
}

// home_place_of gives the first place that a search reads for a key: a
// multiplicative hash, so that the letters of one script, which are next
// to each other, spread over the table.
home_place_of :: #force_inline proc "contextless" (key: u32) -> int {
	return int((key * 2654435769) >> (32 - ENTRY_BITS))
}

// entry_valid checks a copied entry of a face against the constants of the
// contract: its state, each advance, and the rows, the columns and the
// words of each glyph of each scale of the face. A glyph of a face of
// cells starts at the left of its cell, is at most as wide as the cell,
// and its advance is the width of the cell: the damage of a grid of text
// cells depends on it. A reader that checked an entry draws its glyphs
// with no other check: each word is inside the words of the cache.
entry_valid :: proc "contextless" (face: Face, entry: ^Entry) -> bool {
	if entry.state == .Absent {
		return true
	}
	if entry.state != .Drawn {
		return false
	}
	form := face_forms[face]
	for scale in 1 ..= form.scale_count {
		advance := entry.advances[scale - 1]
		cell_width := CELL_WIDTH_AT_SCALE_ONE * scale
		if advance < 0 || advance > glyph_cache.ADVANCE_LIMIT || !form.proportional && advance != i32(cell_width * glyph_cache.SUBPIXEL) {
			return false
		}
		for position in 0 ..< position_count_of(face, scale) {
			place, _ := glyph_place_of(scale, position)
			glyph := entry.glyphs[place]
			end_row := u64(glyph.first_row) + u64(glyph.row_count)
			end_word := u64(glyph.word_offset) + u64(glyph.row_count) * u64(glyph.width)
			outside_cell := !form.proportional && (glyph.left != 0 || int(glyph.width) > cell_width)
			if end_row > u64(LINE_HEIGHT_AT_SCALE_ONE * scale) || glyph.width > glyph_cache.GLYPH_WIDTH_LIMIT || glyph.left < -glyph_cache.LEFT_LIMIT || glyph.left > glyph_cache.GLYPH_WIDTH_LIMIT || outside_cell || end_word > WORD_CAPACITY {
				return false
			}
		}
	}
	return true
}

// glyph_of_entry gives the glyph of a checked entry of a face at a scale
// and a position; ok is false for a scale or a position that the face does
// not have.
glyph_of_entry :: proc "contextless" (face: Face, entry: ^Entry, scale, position: int) -> (glyph: glyph_cache.Glyph_Entry, ok: bool) {
	if position < 0 || position >= position_count_of(face, scale) {
		return {}, false
	}
	place := glyph_place_of(scale, position) or_return
	return entry.glyphs[place], true
}

// Reader: the side of a process, for one face. reader_of makes it;
// reader_frame_begin starts each frame; find gives an entry.
Reader :: struct {
	header:           ^Header,
	entries:          [^]Entry,
	words:            [^]u32, // WORD_CAPACITY words.
	face:             Face, // The face of the glyph cache that this reader goes with.
	font_hash:        [32]u8, // The hash of the font file of that glyph cache.
	flags:            u32, // The flags of that glyph cache.
	generation_limit: u64, // The generation at the start of the frame: 0, nothing is found.
}

// reader_matches says if the glyphs of a face can stand beside the glyphs
// of a glyph cache: the cache has the form of the face at each scale. The
// font file and the flags are checked at each frame (reader_frame_begin),
// against the header of the face.
reader_matches :: proc "contextless" (face: Face, cache: ^glyph_cache.Cache) -> bool {
	form := face_forms[face]
	if cache.header == nil || (cache.header.flags & glyph_cache.FLAG_PROPORTIONAL != 0) != form.proportional || (cache.header.flags & glyph_cache.FLAG_GRID_FIT != 0) != form.grid_fit || len(cache.sizes) != form.scale_count {
		return false
	}
	for size, index in cache.sizes {
		if int(size.position_count) != position_count_of(face, index + 1) {
			return false
		}
	}
	return true
}

// reader_of makes the reader of a face of the demand cache mapped at base,
// for the glyphs of a font file (its hash) drawn with the flags of a glyph
// cache. The header names the hash and the flags of each face: a reader
// whose hash or flags differ finds nothing (reader_frame_begin). ok is
// false for a base that is 0 or not on a page.
reader_of :: proc "contextless" (base: uintptr, face: Face, font_hash: [32]u8, flags: u32) -> (reader: Reader, ok: bool) {
	if base == 0 || base % PAGE_SIZE != 0 {
		return {}, false
	}
	reader.header = (^Header)(base)
	reader.entries = ([^]Entry)(base + ENTRIES_OFFSET)
	reader.words = ([^]u32)(base + WORDS_OFFSET)
	reader.face = face
	reader.font_hash = font_hash
	reader.flags = flags
	return reader, true
}

// reader_frame_begin starts a frame: it reads the generation once. The
// draws of the frame find an entry only when its generation is at most
// that value. The measure does not read the cache: the advance of a
// character comes from its font file. A cache with no magic yet, another
// version, or another font file or flags for the face of the reader gives
// the limit 0: no entry is found, and the process draws the glyph itself.
reader_frame_begin :: proc "contextless" (reader: ^Reader) {
	reader.generation_limit = 0
	if reader.header == nil || intrinsics.atomic_load_explicit(&reader.header.magic, .Acquire) != MAGIC {
		return
	}
	face := reader.header.faces[reader.face]
	if reader.header.version != VERSION || face.font_hash != reader.font_hash || face.flags != reader.flags {
		return
	}
	reader.generation_limit = intrinsics.atomic_load_explicit(&reader.header.generation, .Acquire)
}

// find gives the entry of a character of the face of the reader, copied
// and checked. The state is Empty when the cache does not hold the
// character at the generation of the frame. Absent: the entry is wrong.
// In both cases the process draws the glyph itself.
find :: proc "contextless" (reader: ^Reader, character: rune) -> (entry: Entry, state: Entry_State) {
	if reader.generation_limit == 0 || character <= 0 || character > text_encoding.CODE_POINT_LAST {
		return {}, .Empty
	}
	key := key_of(reader.face, character)
	home := home_place_of(key)
	for probe in 0 ..< PROBE_LIMIT {
		place := (home + probe) & (ENTRY_CAPACITY - 1)
		stored := intrinsics.atomic_load_explicit(&reader.entries[place].key, .Acquire)
		if stored == 0 {
			return {}, .Empty
		}
		if stored != key {
			continue
		}
		copied := intrinsics.volatile_load(&reader.entries[place])
		if copied.key != key || copied.generation == 0 || copied.generation > reader.generation_limit {
			return {}, .Empty
		}
		if !entry_valid(reader.face, &copied) {
			return {}, .Absent
		}
		return copied, copied.state
	}
	return {}, .Empty
}

// Writer: the side of the font service, the one writer. It keeps its own
// counts: it never reads a count back from the shared memory.
Writer :: struct {
	header:      ^Header,
	entries:     [^]Entry,
	words:       [^]u32, // WORD_CAPACITY words.
	words_used:  int,
	entry_count: int,
	generation:  u64,
	refused:     u64,
}

// writer_open writes the header of a new demand cache, all zero, at base,
// with the font file and the flags of each face, the magic last.
writer_open :: proc "contextless" (base: uintptr, renderer_version: u32, faces: [Face]Face_Header) -> (writer: Writer) {
	writer.header = (^Header)(base)
	writer.entries = ([^]Entry)(base + ENTRIES_OFFSET)
	writer.words = ([^]u32)(base + WORDS_OFFSET)
	writer.header.version = VERSION
	writer.header.renderer_version = renderer_version
	writer.header.faces = faces
	intrinsics.atomic_store_explicit(&writer.header.magic, MAGIC, .Release)
	return writer
}

// Place_Search: what place_find found for a character.
Place_Search :: enum u8 {
	Free, // A free place: the character is not in the cache.
	Published, // The character is in the cache.
	Full, // No free place in PROBE_LIMIT places: the character is refused.
}

// place_find finds the place of a character of a face: its entry, or the
// first free place of its search.
place_find :: proc "contextless" (writer: ^Writer, face: Face, character: rune) -> (place: int, search: Place_Search) {
	key := key_of(face, character)
	home := home_place_of(key)
	for probe in 0 ..< PROBE_LIMIT {
		place = (home + probe) & (ENTRY_CAPACITY - 1)
		switch writer.entries[place].key {
		case key:
			return place, .Published
		case 0:
			return place, .Free
		}
	}
	return 0, .Full
}

// words_take gives the offset of count free words. ok is false when the
// words are full: the character is refused.
words_take :: proc "contextless" (writer: ^Writer, count: int) -> (offset: int, ok: bool) {
	if count < 0 || count > WORD_CAPACITY - writer.words_used {
		return 0, false
	}
	offset = writer.words_used
	writer.words_used += count
	return offset, true
}

// publish writes an entry of a face at a free place: each field, then the
// key with release, then the generation of the header. A reader that
// finds the key sees each field.
publish :: proc "contextless" (writer: ^Writer, place: int, face: Face, character: rune, entry: Entry) {
	writer.generation += 1
	target := &writer.entries[place]
	target.state = entry.state
	target.generation = writer.generation
	target.advances = entry.advances
	target.glyphs = entry.glyphs
	intrinsics.atomic_store_explicit(&target.key, key_of(face, character), .Release)
	writer.entry_count += 1
	writer.header.entry_count = u32(writer.entry_count)
	writer.header.words_used = u64(writer.words_used)
	intrinsics.atomic_store_explicit(&writer.header.generation, writer.generation, .Release)
}

// refusal_count adds one refused character to the count of the header.
refusal_count :: proc "contextless" (writer: ^Writer) {
	writer.refused += 1
	intrinsics.atomic_store_explicit(&writer.header.refused, writer.refused, .Relaxed)
}

// The handle of the context of the font service: an index in the fixed
// table of its handles.
SERVICE_GRANT_CACHE :: 0 // The demand cache, with Read and Write.
