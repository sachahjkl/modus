// The glyph cache file (docs/FONTS.md, "The glyph cache"): the glyphs of
// one font, already drawn, for each size of the grid, with the advance of
// each character and the pair adjustments of the font. The modus tool
// makes it at build time from the font file; the boot image holds it as a
// resource; the root service gives each process a read-only mapping of it.
// A process draws a character with a copy and a blend of its words: no
// outline is read at run time.
//
// One format for a monospace font and for a proportional font. A monospace
// cache (no FLAG_PROPORTIONAL) has one position, each glyph inside its cell
// from its left side, each advance the width of the cell, and no pair:
// validate checks it, because the damage of a grid of text cells depends
// on a glyph that stays in its cell. A
// proportional cache (the interface font, docs/FONTS.md, section 12) keeps
// each glyph at position_count subpixel positions, each glyph as wide as
// its ink, and the pairs.
//
// One file, read in place after one validation. All numbers are
// little-endian; each record has a fixed size.
//
// The characters of a cache are fixed: the printable characters of ASCII,
// 32 to 126, the Latin-1 Supplement, U+00A0 to U+00FF, and the added
// characters (added_characters): the euro sign. Each table keys a
// character by its character index (character_index): 0 to 94, then 95 to
// 190, then 191 for the euro sign. A character of a text outside them has
// no glyph, and the reader draws the replacement glyph (docs/FONTS.md, "The
// glyph cache").
//
//   Header         128 bytes  at 0
//   Size_Entry     16 bytes   x size_count, at 128
//   Glyph_Entry    12 bytes   x the sum of position_count x CHARACTER_COUNT of each size
//   advance        i32        x size_count x CHARACTER_COUNT, in 1/64 of a pixel
//   Pair_Entry     8 bytes    x size_count x pair_count
//   (zero bytes to a multiple of 64)
//   words          u32 each   at word_offset, word_count of them
//
// A word is 0xGGRRGGBB: the coverage of the whole pixel (for grayscale) in
// the high byte, then the coverage of the red, the green and the blue
// stripe after the filter, with red at the left of the pixel. A glyph keeps
// only its rows with ink: rows first_row ..< first_row + row_count of the
// line, each row width words from the column left.
package glyph_cache

MAGIC :: u64(0x5345485048594C47) // The bytes "GLYPHSES" ("GLYPH" and "SES").
VERSION :: 4 // The version of the format. A reader refuses another. A change of the characters of a cache is a new version.
HEADER_SIZE :: 128 // The bytes of `Header`.
SIZE_ENTRY_SIZE :: 16 // The bytes of `Size_Entry`.
GLYPH_ENTRY_SIZE :: 12 // The bytes of `Glyph_Entry`.
ADVANCE_SIZE :: 4 // The bytes of one advance: an i32.
PAIR_ENTRY_SIZE :: 8 // The bytes of `Pair_Entry`.
SIZE_LIMIT :: 3 // The scales 1, 2 and 3 of the grid (docs/DESIGN.md, section 5).
// The two ranges of the characters of a cache.
ASCII_FIRST :: 32 // The space.
ASCII_LAST :: 126 // The tilde.
LATIN_FIRST :: 0xA0 // The first character of the Latin-1 Supplement: the space with no break.
LATIN_LAST :: 0xFF // The last one: y with a diaeresis.
ASCII_COUNT :: ASCII_LAST - ASCII_FIRST + 1 // 95: the character index of LATIN_FIRST.
ADDED_FIRST_INDEX :: ASCII_COUNT + LATIN_LAST - LATIN_FIRST + 1 // 191: the character index of the first added character.
// The added characters: the characters past the Latin-1 Supplement that
// each font draws. Each one is chosen, not a range: the characters that a
// language of the layouts needs past Latin-1 are far apart in Unicode, and
// a range would hold thousands that the fonts of the system do not draw.
// The list is in the order of the code points: the character map of a
// subset needs its segments in that order, and a reader can search the
// list by halves. A character added to the list moves the index of each
// character after it, so each change of the list is a new VERSION.
EURO_SIGN :: 0x20AC
ADDED_COUNT :: 1
@(rodata)
added_characters := [ADDED_COUNT]rune{EURO_SIGN}
CHARACTER_COUNT :: ADDED_FIRST_INDEX + ADDED_COUNT // 192: the characters of each cache.
#assert(CHARACTER_COUNT <= 256) // A pair names a character index in one byte.
CELL_WIDTH_LIMIT :: 24 // The widest cell: 8 pixels at scale 3.
CELL_HEIGHT_LIMIT :: 48 // The tallest cell: 16 pixels at scale 3.
// The positions of a glyph inside one pixel: 0, 1/3 and 2/3 of a pixel at
// most, the step of the color stripes.
POSITION_LIMIT :: 3
// The widest glyph, in pixels, and how far left of its origin a glyph can
// start: the ink of a proportional glyph at scale 3 with the spread of the
// filter and its position.
GLYPH_WIDTH_LIMIT :: 64 // Pixels.
LEFT_LIMIT :: 16 // Pixels.
// The largest advance and the largest adjustment of a pair, in 1/64 of a
// pixel: 64 pixels.
ADVANCE_LIMIT :: 64 * 64
PAIR_LIMIT :: CHARACTER_COUNT * CHARACTER_COUNT // Each pair of two characters at most once.
SUBPIXEL :: 64 // An advance, a pair adjustment and a place of text are in 1/64 of a pixel.

// The first 128 bytes of a glyph cache file.
Header :: struct #packed {
	magic:            u64, // MAGIC.
	version:          u32, // VERSION.
	renderer_version: u32, // The version of the renderer of src/library/support/vector_font that drew the words.
	file_size:        u64, // The bytes of the file.
	reserved_first:   u32, // 0. The characters are fixed: see character_index.
	character_count:  u32, // CHARACTER_COUNT.
	size_count:       u32, // One entry for each scale, in the order 1, 2, 3.
	flags:            u32, // FLAG_GRID_FIT, FLAG_PROPORTIONAL, and the filter in bits 8 to 15 (FILTER_COUNT values).
	word_offset:      u64, // From the start of the file; a multiple of 64.
	word_count:       u64, // The words of coverage.
	font_hash:        [32]u8, // BLAKE3 of the font file that the glyphs come from: the cache is named by what made it.
	font_name:        [32]u8, // ASCII 32 to 126, then zero bytes.
	pair_count:       u32, // The pairs of each size; 0 for a monospace font.
	reserved:         u32, // 0.
}
#assert(size_of(Header) == HEADER_SIZE)

FLAG_GRID_FIT :: 1 // The baseline, the x-height and the cap height are on whole pixels.
FLAG_PROPORTIONAL :: 2 // Each character has its own advance; glyphs are boxes of ink at their positions.
FILTER_SHIFT :: 8 // The first bit of the filter in `flags`.
FILTER_COUNT :: 3 // The filters of the color stripes of src/library/support/vector_font (Stripe_Filter).
// The bits of `flags` that a reader takes; another bit is Bad_Flags.
FLAGS_KNOWN :: FLAG_GRID_FIT | FLAG_PROPORTIONAL | 0xFF << FILTER_SHIFT

// One size of the cache: one scale of the grid.
Size_Entry :: struct #packed {
	cell_width:     u16, // 8, 16, 24: the cell of the grid; the advance of every character of a monospace font.
	cell_height:    u16, // 16, 32, 48: the line.
	baseline:       u16, // The row of the baseline, from the top of the line.
	position_count: u16, // 1 to POSITION_LIMIT: the glyphs of this size are drawn at each k / position_count of a pixel.
	first_glyph:    u32, // The index of the entry of the first character at the first position of this size.
	reserved:       u32, // 0.
}
#assert(size_of(Size_Entry) == SIZE_ENTRY_SIZE)

// The glyph of position p of character c of a size is the entry
// first_glyph + p * character_count + c.
Glyph_Entry :: struct #packed {
	first_row:   u16, // The first row with ink, from the top of the line.
	row_count:   u16, // 0: a glyph with no ink, a space.
	word_offset: u32, // From the first word: the first word of row first_row.
	left:        i16, // The column of the first word, in pixels from the whole pixel of the origin.
	width:       u16, // The words of each row.
}
#assert(size_of(Glyph_Entry) == GLYPH_ENTRY_SIZE)

// A pair adjustment: the advance of left changes by adjustment when right
// follows it. The pairs of one size are sorted by left, then right. The
// layout of the C language, with no gap, as each record of a file.
Pair_Entry :: struct {
	left:       u8, // The character index of a character.
	right:      u8, // The character index of the character that follows.
	reserved:   u16, // 0.
	adjustment: i32, // In 1/64 of a pixel.
}
#assert(size_of(Pair_Entry) == PAIR_ENTRY_SIZE && offset_of(Pair_Entry, adjustment) == 4)

// Problem: why a file was refused. A zero problem is a valid file.
Problem_Kind :: enum u8 {
	None, // The file is valid.
	Too_Short, // The file is shorter than its header or than a table.
	Bad_Magic, // The file does not start with MAGIC.
	Bad_Version, // Another version.
	Bad_Size, // file_size is not the size of the file.
	Bad_Count, // A count is 0 or above its limit, the count of the characters is not CHARACTER_COUNT, a size does not start where the sizes before it end, or a reserved field of the header or of a size is not 0.
	Bad_Cell, // A cell size or a baseline is out of its limits.
	Bad_Words, // The words are not where the header says.
	Bad_Glyph, // A glyph has rows outside its line, a width or a left side out of the limits, or words outside the words.
	Bad_Advance, // An advance is negative or above ADVANCE_LIMIT.
	Bad_Pair, // A pair names a character outside the cache, is out of order or twice, has an adjustment above ADVANCE_LIMIT, or has a reserved field that is not 0.
	Bad_Flags, // A flag that this reader does not know, or a filter past FILTER_COUNT.
	Bad_Name, // font_name has a byte outside 32 to 126 before its end, no zero byte, or a byte after its end.
	Proportional, // A valid cache of a proportional font, where a reader needs the cache of a font of cells.
	Not_Mapped, // The starter of the process did not map this cache: no byte was read.
}

// Why a file was refused, with the place and the value.
Problem :: struct {
	kind:  Problem_Kind, // What is wrong.
	index: u32, // The size, the glyph, the advance or the pair.
	value: u64, // The value that the file has.
	limit: u64, // The value that the reader needs.
}

// The sentence of each problem, for the log.
problem_sentences := [Problem_Kind]string {
	.None        = "the glyph cache is valid",
	.Too_Short   = "the glyph cache is shorter than its header or its tables",
	.Bad_Magic   = "the glyph cache does not start with the bytes GLYPHSES",
	.Bad_Version = "the glyph cache has a version that this reader does not know",
	.Bad_Size    = "the size in the header of the glyph cache is not the size of the file",
	.Bad_Count   = "a count of the glyph cache is 0 or above its limit",
	.Bad_Cell    = "a cell of the glyph cache is out of the limits of the grid",
	.Bad_Words   = "the words of the glyph cache are not where its header says",
	.Bad_Glyph   = "a glyph of the glyph cache has rows or columns outside its limits or words outside the file",
	.Bad_Advance = "an advance of the glyph cache is out of its limits",
	.Bad_Pair    = "a pair of the glyph cache names a character outside the cache, is out of order, or is out of its limits",
	.Bad_Flags   = "the glyph cache has a flag or a filter that this reader does not know",
	.Bad_Name    = "the name of the font of the glyph cache is not printable text with an end",
	.Proportional = "the glyph cache is of a proportional font, not of a font of cells",
	.Not_Mapped  = "the starter of the process did not map this glyph cache",
}

// Cache: a valid file, read in place.
Cache :: struct {
	header:   ^Header,
	sizes:    []Size_Entry,
	glyphs:   []Glyph_Entry,
	advances: []i32, // size_count x character_count.
	pairs:    []Pair_Entry, // size_count x pair_count.
	words:    []u32,
}

// validate checks a whole file once. After it, a reader trusts each entry.
// No count from the file is multiplied before it is checked against its
// limit, so no product wraps.
validate :: proc "contextless" (bytes: []u8) -> (cache: Cache, problem: Problem) {
	if len(bytes) < HEADER_SIZE || uintptr(raw_data(bytes)) % 8 != 0 {
		return {}, {kind = .Too_Short, value = u64(len(bytes)), limit = HEADER_SIZE}
	}
	header := (^Header)(raw_data(bytes))
	if header.magic != MAGIC {
		return {}, {kind = .Bad_Magic, value = header.magic, limit = MAGIC}
	}
	if header.version != VERSION {
		return {}, {kind = .Bad_Version, value = u64(header.version), limit = VERSION}
	}
	if header.file_size != u64(len(bytes)) {
		return {}, {kind = .Bad_Size, value = header.file_size, limit = u64(len(bytes))}
	}
	if header.character_count != CHARACTER_COUNT {
		return {}, {kind = .Bad_Count, value = u64(header.character_count), limit = CHARACTER_COUNT}
	}
	if header.reserved_first != 0 {
		return {}, {kind = .Bad_Count, value = u64(header.reserved_first), limit = 0}
	}
	// A reserved field that is not 0 is refused, so that a later version can
	// give it a meaning that no reader of this version takes for nothing.
	if header.reserved != 0 {
		return {}, {kind = .Bad_Count, value = u64(header.reserved), limit = 0}
	}
	if header.size_count == 0 || header.size_count > SIZE_LIMIT {
		return {}, {kind = .Bad_Count, value = u64(header.size_count), limit = SIZE_LIMIT}
	}
	if header.pair_count > PAIR_LIMIT {
		return {}, {kind = .Bad_Count, value = u64(header.pair_count), limit = PAIR_LIMIT}
	}
	if header.flags & ~u32(FLAGS_KNOWN) != 0 || (header.flags >> FILTER_SHIFT) & 0xFF >= FILTER_COUNT {
		return {}, {kind = .Bad_Flags, value = u64(header.flags), limit = u64(FLAGS_KNOWN)}
	}
	// The name: printable bytes, then at least one zero byte, then zeros.
	ended := false
	for byte, index in header.font_name {
		if ended && byte != 0 || !ended && byte != 0 && (byte < 32 || byte > 126) {
			return {}, {kind = .Bad_Name, index = u32(index), value = u64(byte)}
		}
		if byte == 0 {
			ended = true
		}
	}
	if !ended {
		return {}, {kind = .Bad_Name, index = u32(len(header.font_name)), value = 0}
	}
	monospace := header.flags & FLAG_PROPORTIONAL == 0
	if monospace && header.pair_count != 0 {
		return {}, {kind = .Bad_Count, value = u64(header.pair_count), limit = 0}
	}
	size_count := int(header.size_count)
	character_count := int(header.character_count)
	if len(bytes) < HEADER_SIZE + size_count * SIZE_ENTRY_SIZE {
		return {}, {kind = .Too_Short, value = u64(len(bytes)), limit = u64(HEADER_SIZE + size_count * SIZE_ENTRY_SIZE)}
	}
	sizes := ([^]Size_Entry)(raw_data(bytes[HEADER_SIZE:]))[:size_count]
	// The glyphs of each size follow those of the size before.
	glyph_count := 0
	for size, index in sizes {
		if size.position_count == 0 || size.position_count > POSITION_LIMIT || monospace && size.position_count != 1 {
			return {}, {kind = .Bad_Count, index = u32(index), value = u64(size.position_count), limit = POSITION_LIMIT}
		}
		if int(size.first_glyph) != glyph_count {
			return {}, {kind = .Bad_Count, index = u32(index), value = u64(size.first_glyph), limit = u64(glyph_count)}
		}
		if size.reserved != 0 {
			return {}, {kind = .Bad_Count, index = u32(index), value = u64(size.reserved), limit = 0}
		}
		glyph_count += int(size.position_count) * character_count
	}
	glyphs_place := HEADER_SIZE + size_count * SIZE_ENTRY_SIZE
	advances_place := glyphs_place + glyph_count * GLYPH_ENTRY_SIZE
	pairs_place := advances_place + size_count * character_count * ADVANCE_SIZE
	tables_end := pairs_place + size_count * int(header.pair_count) * PAIR_ENTRY_SIZE
	if tables_end > len(bytes) {
		return {}, {kind = .Too_Short, value = u64(len(bytes)), limit = u64(tables_end)}
	}
	aligned := (tables_end + 63) / 64 * 64
	if header.word_offset != u64(aligned) || aligned > len(bytes) || header.word_count > u64(len(bytes) - aligned) / 4 || u64(aligned) + header.word_count * 4 != u64(len(bytes)) {
		return {}, {kind = .Bad_Words, value = header.word_offset, limit = u64(aligned)}
	}
	cache.header = header
	cache.sizes = sizes
	cache.glyphs = ([^]Glyph_Entry)(raw_data(bytes[glyphs_place:]))[:glyph_count]
	cache.advances = ([^]i32)(raw_data(bytes[advances_place:]))[:size_count * character_count]
	cache.pairs = ([^]Pair_Entry)(raw_data(bytes[pairs_place:]))[:size_count * int(header.pair_count)]
	cache.words = ([^]u32)(raw_data(bytes[aligned:]))[:header.word_count]
	for size, index in cache.sizes {
		scale := u16(index + 1)
		if size.cell_width != 8 * scale || size.cell_height != 16 * scale || size.baseline == 0 || size.baseline > size.cell_height {
			return {}, {kind = .Bad_Cell, index = u32(index), value = u64(size.cell_width), limit = u64(8 * scale)}
		}
		for glyph, offset in cache.glyphs[size.first_glyph:][:int(size.position_count) * character_count] {
			end_row := u64(glyph.first_row) + u64(glyph.row_count)
			end_word := u64(glyph.word_offset) + u64(glyph.row_count) * u64(glyph.width)
			outside_cell := monospace && (glyph.left != 0 || glyph.width > size.cell_width)
			if end_row > u64(size.cell_height) || glyph.width > GLYPH_WIDTH_LIMIT || glyph.left < -LEFT_LIMIT || glyph.left > GLYPH_WIDTH_LIMIT || outside_cell || end_word > header.word_count {
				return {}, {kind = .Bad_Glyph, index = size.first_glyph + u32(offset), value = end_word, limit = header.word_count}
			}
		}
		for advance, character in cache.advances[index * character_count:][:character_count] {
			if advance < 0 || advance > ADVANCE_LIMIT || monospace && advance != i32(size.cell_width) * SUBPIXEL {
				return {}, {kind = .Bad_Advance, index = u32(index * character_count + character), value = u64(i64(advance)), limit = ADVANCE_LIMIT}
			}
		}
		// Sorted, each pair once, so a reader finds a pair by a binary search.
		previous := -1
		for pair, offset in cache.pairs[index * int(header.pair_count):][:int(header.pair_count)] {
			key := int(pair.left) << 8 | int(pair.right)
			if int(pair.left) >= character_count || int(pair.right) >= character_count || key <= previous || pair.adjustment < -ADVANCE_LIMIT || pair.adjustment > ADVANCE_LIMIT {
				return {}, {kind = .Bad_Pair, index = u32(index * int(header.pair_count) + offset), value = u64(key), limit = u64(previous + 1)}
			}
			// Its own record, so that a reader sees the field and not an order.
			if pair.reserved != 0 {
				return {}, {kind = .Bad_Pair, index = u32(index * int(header.pair_count) + offset), value = u64(pair.reserved), limit = 0}
			}
			previous = key
		}
	}
	return cache, {}
}

// validate_at validates a cache that the starter of the process mapped at
// a fixed address, in a range of span bytes. The cache states its own size:
// file_size in its header. The header is mapped (a mapping has whole pages,
// and a starter maps no cache shorter than its header), so the size is
// read there, bounded by the span of the range and by the header, and
// then the whole file is validated, which checks file_size again. The
// caller has checked that the starter states the range as mapped. A
// starter that states a range as mapped, maps less than the size that the
// header states, or maps memory that it can still write, makes this read
// fault or the cache change after the validation: a process trusts its
// starter (docs/FONTS.md, section 5, "Who can write a cache").
validate_at :: proc "contextless" (address: uintptr, span: u64) -> (cache: Cache, problem: Problem) {
	if address == 0 || address % 8 != 0 {
		return {}, {kind = .Too_Short, value = u64(address)}
	}
	size := (^Header)(address).file_size
	if size < HEADER_SIZE || size > span {
		return {}, {kind = .Bad_Size, value = size, limit = span}
	}
	return validate(([^]u8)(address)[:size])
}

// character_index gives the index of a character in each table of a cache:
// 0 to 94 for 32 to 126, then 95 to 190 for U+00A0 to U+00FF, then the
// added characters from ADDED_FIRST_INDEX, in the order of their list.
// found is false for each other character: a control character, and each
// character past U+00FF that the list does not name.
character_index :: #force_inline proc "contextless" (character: rune) -> (index: int, found: bool) {
	switch character {
	case ASCII_FIRST ..= ASCII_LAST:
		return int(character) - ASCII_FIRST, true
	case LATIN_FIRST ..= LATIN_LAST:
		return int(character) - LATIN_FIRST + ASCII_COUNT, true
	}
	if character > LATIN_LAST {
		for added, offset in added_characters {
			if added == character {
				return ADDED_FIRST_INDEX + offset, true
			}
		}
	}
	return 0, false
}

// character_of_index gives the character of a character index; found is
// false for an index past the last character.
character_of_index :: proc "contextless" (index: int) -> (character: rune, found: bool) {
	switch {
	case index >= 0 && index < ASCII_COUNT:
		return rune(index + ASCII_FIRST), true
	case index >= ASCII_COUNT && index < ADDED_FIRST_INDEX:
		return rune(index - ASCII_COUNT + LATIN_FIRST), true
	case index >= ADDED_FIRST_INDEX && index < CHARACTER_COUNT:
		return added_characters[index - ADDED_FIRST_INDEX], true
	}
	return 0, false
}

// glyph gives the size, and the entry of one character at one scale (1 to
// 3) at the position 0, of a valid cache; found is false for a character
// out of the cache.
glyph :: #force_inline proc "contextless" (cache: ^Cache, character: rune, scale: int) -> (size: Size_Entry, entry: Glyph_Entry, found: bool) {
	return glyph_at_position(cache, character, scale, 0)
}

// glyph_at_position gives the entry of one character at one scale and one
// position (0 ..< position_count of the size) of a valid cache.
glyph_at_position :: #force_inline proc "contextless" (cache: ^Cache, character: rune, scale: int, position: int) -> (size: Size_Entry, entry: Glyph_Entry, found: bool) {
	index, in_cache := character_index(character)
	if !in_cache {
		return {}, {}, false
	}
	return glyph_of_index(cache, index, scale, position)
}

// glyph_of_index gives the entry of one character index at one scale and
// one position of a valid cache: the placed glyph of the shaper is a
// character index.
glyph_of_index :: #force_inline proc "contextless" (cache: ^Cache, index: int, scale: int, position: int) -> (size: Size_Entry, entry: Glyph_Entry, found: bool) {
	if index < 0 || index >= int(cache.header.character_count) || scale < 1 || scale > len(cache.sizes) {
		return {}, {}, false
	}
	size = cache.sizes[scale - 1]
	if position < 0 || position >= int(size.position_count) {
		return {}, {}, false
	}
	return size, cache.glyphs[int(size.first_glyph) + position * int(cache.header.character_count) + index], true
}

// advances_of gives the advances of the characters of one scale, in 1/64
// of a pixel; empty for a scale that the cache does not have.
advances_of :: proc "contextless" (cache: ^Cache, scale: int) -> []i32 {
	if scale < 1 || scale > len(cache.sizes) {
		return nil
	}
	count := int(cache.header.character_count)
	return cache.advances[(scale - 1) * count:][:count]
}

// pairs_of gives the pairs of one scale, sorted.
pairs_of :: proc "contextless" (cache: ^Cache, scale: int) -> []Pair_Entry {
	if scale < 1 || scale > len(cache.sizes) {
		return nil
	}
	count := int(cache.header.pair_count)
	return cache.pairs[(scale - 1) * count:][:count]
}

// position_of gives the whole pixel and the position of a place of text in
// 1/64 of a pixel, with position_count positions in a pixel: the nearest
// position, so the error is at most half of a step.
position_of :: proc "contextless" (place: i64, position_count: int) -> (pixel: i64, position: int) {
	count := i64(max(position_count, 1))
	steps := place * count + SUBPIXEL / 2
	nearest := steps >= 0 ? steps / SUBPIXEL : -((-steps + SUBPIXEL - 1) / SUBPIXEL)
	pixel = nearest >= 0 ? nearest / count : -((-nearest + count - 1) / count)
	return pixel, int(nearest - pixel * count)
}
