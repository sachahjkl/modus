// The demand cache (src/md/features/glyphs_on_demand.md): the glyphs past
// the glyph caches of the boot image, which the font service draws: each
// character of subset_ranges at its start, before it reads a request. The
// root service creates the memory; the font service (the program `glyphs`)
// is its one writer; each program that the root service gives a request
// ring maps it read-only at ADDRESS.
//
// A program asks for the glyphs that it lacks through its request ring at
// REQUESTS_ADDRESS: records of CHARACTERS_PER_REQUEST code points
// (request_pack). The font service answers each record with one
// completion: the generation after the glyphs of the record, and the
// counts of drawn, absent and refused characters.
//
// The cache changes while a program reads it: the font service publishes
// one entry after the other. So a reader copies each entry once and checks
// it against the constants of this contract, never against a field of the
// shared memory (find). A wrong entry draws the replacement glyph; it is
// never a read outside the cache.
//
//   Header      128 bytes, at 0, in its own page
//   Entry       ENTRY_SIZE bytes x ENTRY_CAPACITY, at ENTRIES_OFFSET: a hash table by code point
//   words       u32 x WORD_CAPACITY, at WORDS_OFFSET: the words of coverage, as in a glyph cache
//
// The glyphs of an entry have the form of a proportional glyph cache with
// POSITIONS_AT_SCALE_ONE positions at scale 1 and one position at the
// scales 2 and 3: the form of the glyph cache of the interface font, whose
// font file the header names by its hash.
//
// See [demand cache](term:demand-cache) and [font service](term:font-service).
package demand_cache

import "base:intrinsics"
import "modus:contract/fixed_addresses"
import "modus:contract/glyph_cache"
import "modus:contract/ring"
import "modus:contract/text_encoding"

MAGIC :: u64(0x444E414D45444C47) // The bytes "GLDEMAND".
VERSION :: 1 // The version of the format. A reader refuses another.
PAGE_SIZE :: 4096
HEADER_SIZE :: 128 // The bytes of `Header`.
ENTRY_SIZE :: 96 // The bytes of `Entry`.
ENTRY_BITS :: 10
ENTRY_CAPACITY :: 1 << ENTRY_BITS // The places of the hash table: a power of two.
// The places that a search reads at most, from the home place of a code
// point. A character that finds no free place in them is refused.
PROBE_LIMIT :: 16
ENTRIES_OFFSET :: PAGE_SIZE // The table after the page of the header.
WORDS_OFFSET :: ENTRIES_OFFSET + ENTRY_CAPACITY * ENTRY_SIZE
WORD_CAPACITY :: 256 * 1024 // The words of coverage: 1 MiB, about 470 characters of the interface font.
SIZE :: WORDS_OFFSET + WORD_CAPACITY * 4 // The bytes of the demand cache.
PAGE_COUNT :: SIZE / PAGE_SIZE
#assert(SIZE % PAGE_SIZE == 0)
#assert(WORDS_OFFSET % 64 == 0)
#assert(SIZE <= fixed_addresses.RANGE_SPAN)

ADDRESS :: fixed_addresses.DEMAND_CACHE_ADDRESS // Where a program maps the demand cache, read-only.
REQUESTS_ADDRESS :: fixed_addresses.GLYPH_REQUESTS_ADDRESS // Where a program maps its request ring, with Write.
REQUEST_RING_PAGES :: ring.PAGE_COUNT // The pages of a request ring: ring.CAPACITY records.

// The form of the glyphs: each scale of the grid, three positions at scale
// 1 and one at the scales 2 and 3.
SIZE_COUNT :: glyph_cache.SIZE_LIMIT
POSITIONS_AT_SCALE_ONE :: glyph_cache.POSITION_LIMIT
GLYPH_COUNT :: POSITIONS_AT_SCALE_ONE + SIZE_COUNT - 1 // The glyph entries of one character.
LINE_HEIGHT_AT_SCALE_ONE :: glyph_cache.CELL_HEIGHT_LIMIT / glyph_cache.SIZE_LIMIT // 16 pixels.

// The characters that the subset of the interface font holds past the
// glyph cache, in the order of the code points: the Greek letters of B612.
// B612 1.008 has no small rho (U+03C1), so the small letters are two
// ranges. The modus tool adds them to the subset after the characters of
// the glyph cache (tools/modustool/vector_fonts.odin), so the glyph cache
// of the build does not change.
Character_Range :: struct {
	first, last: rune,
}
@(rodata)
subset_ranges := [?]Character_Range{{0x0391, 0x03A1}, {0x03A3, 0x03A9}, {0x03B1, 0x03C0}, {0x03C2, 0x03C9}}

// in_subset says if a character is one of subset_ranges. The font service
// draws these and no other character: a character of the glyph cache, or
// of the font outside the ranges, is answered as absent.
in_subset :: proc "contextless" (character: rune) -> bool {
	for range in subset_ranges {
		if character >= range.first && character <= range.last {
			return true
		}
	}
	return false
}

// subset_count gives the count of the characters of subset_ranges.
subset_count :: proc "contextless" () -> (count: int) {
	for range in subset_ranges {
		count += int(range.last - range.first) + 1
	}
	return count
}

// The first 128 bytes of the demand cache. The font service writes it once,
// the magic last; then only `generation`, `entry_count`, `words_used` and
// `refused` change.
Header :: struct {
	magic:            u64, // MAGIC, with release, after the other fields.
	version:          u32, // VERSION.
	renderer_version: u32, // The version of the renderer of src/library/support/vector_font.
	font_hash:        [32]u8, // BLAKE3 of the font file of the outlines: the file of the glyph cache that this cache goes with.
	flags:            u32, // The flags of that glyph cache: glyph_cache.FLAG_GRID_FIT, FLAG_PROPORTIONAL and the filter.
	entry_count:      u32, // The entries published. A reader does not use it.
	generation:       u64, // The count of the publications. A reader reads it once at the start of a frame.
	words_used:       u64, // The words written. A reader does not use it.
	refused:          u64, // The characters that did not fit the table or the words.
	reserved:         [48]u8,
}
#assert(size_of(Header) == HEADER_SIZE && offset_of(Header, generation) == 56)

// The state of an entry.
Entry_State :: enum u32 {
	Empty  = 0, // No character: a free place, or a character that a reader does not find yet.
	Drawn  = 1, // The glyphs and the advances of the character.
	Absent = 2, // No glyph: a reader draws the replacement glyph and does not ask again. find gives it for an entry that its check refuses; the font service of today publishes no such entry.
}

// One character of the demand cache. The font service writes each field,
// then `character` with release. An entry never changes after that.
Entry :: struct {
	character:    u32, // The code point; 0: a free place.
	state:        Entry_State,
	generation:   u64, // The generation of the header after its publication.
	advances:     [SIZE_COUNT]i32, // The advance at each scale, in 1/64 of a pixel.
	reserved:     u32,
	glyphs:       [GLYPH_COUNT]glyph_cache.Glyph_Entry, // glyph_place_of; word_offset is from WORDS_OFFSET.
	reserved_end: u32,
}
#assert(size_of(Entry) == ENTRY_SIZE && offset_of(Entry, generation) == 8 && offset_of(Entry, glyphs) == 32)

// position_count_of gives the positions of a scale: 0 for a scale that the
// cache does not have.
position_count_of :: proc "contextless" (scale: int) -> int {
	switch {
	case scale == 1:
		return POSITIONS_AT_SCALE_ONE
	case scale >= 2 && scale <= SIZE_COUNT:
		return 1
	}
	return 0
}

// glyph_place_of gives the place of the glyph of a scale and a position in
// Entry.glyphs: the positions of scale 1, then one glyph for each other
// scale.
glyph_place_of :: proc "contextless" (scale, position: int) -> (place: int, ok: bool) {
	if position < 0 || position >= position_count_of(scale) {
		return 0, false
	}
	if scale == 1 {
		return position, true
	}
	return POSITIONS_AT_SCALE_ONE + scale - 2, true
}

// home_place_of gives the first place that a search reads for a code point:
// a multiplicative hash, so that the letters of one script, which are next
// to each other, spread over the table.
home_place_of :: #force_inline proc "contextless" (character: rune) -> int {
	return int((u32(character) * 2654435769) >> (32 - ENTRY_BITS))
}

// entry_valid checks a copied entry against the constants of the contract:
// its state, each advance, and the rows, the columns and the words of each
// glyph. A reader that checked an entry draws its glyphs with no other
// check: each word is inside the words of the cache.
entry_valid :: proc "contextless" (entry: ^Entry) -> bool {
	if entry.state == .Absent {
		return true
	}
	if entry.state != .Drawn {
		return false
	}
	for advance in entry.advances {
		if advance < 0 || advance > glyph_cache.ADVANCE_LIMIT {
			return false
		}
	}
	for scale in 1 ..= SIZE_COUNT {
		for position in 0 ..< position_count_of(scale) {
			place, _ := glyph_place_of(scale, position)
			glyph := entry.glyphs[place]
			end_row := u64(glyph.first_row) + u64(glyph.row_count)
			end_word := u64(glyph.word_offset) + u64(glyph.row_count) * u64(glyph.width)
			if end_row > u64(LINE_HEIGHT_AT_SCALE_ONE * scale) || glyph.width > glyph_cache.GLYPH_WIDTH_LIMIT || glyph.left < -glyph_cache.LEFT_LIMIT || glyph.left > glyph_cache.GLYPH_WIDTH_LIMIT || end_word > WORD_CAPACITY {
				return false
			}
		}
	}
	return true
}

// glyph_of_entry gives the glyph of a checked entry at a scale and a
// position.
glyph_of_entry :: proc "contextless" (entry: ^Entry, scale, position: int) -> (glyph: glyph_cache.Glyph_Entry, ok: bool) {
	place := glyph_place_of(scale, position) or_return
	return entry.glyphs[place], true
}

// The characters that one frame can collect for a request: more are found
// again by the next frame, after the answers to these.
WANTED_LIMIT :: 64

// Reader: the side of a program. reader_of makes it; reader_frame_begin
// starts each frame; find gives an entry; want collects the characters to
// ask for.
Reader :: struct {
	header:           ^Header,
	entries:          [^]Entry,
	words:            [^]u32, // WORD_CAPACITY words.
	font_hash:        [32]u8, // The hash of the glyph cache that this reader goes with.
	generation_limit: u64, // The generation at the start of the frame: 0, nothing is found.
	wanted:           [WANTED_LIMIT]rune, // The characters of this frame that the cache does not have.
	wanted_count:     int,
}

// reader_matches says if the glyphs of the demand cache can stand beside
// the glyphs of a glyph cache: a proportional cache with the form of the
// demand cache at each scale. The font file is checked at each frame
// (reader_frame_begin), against the hash of this cache.
reader_matches :: proc "contextless" (cache: ^glyph_cache.Cache) -> bool {
	if cache.header == nil || cache.header.flags & glyph_cache.FLAG_PROPORTIONAL == 0 || len(cache.sizes) != SIZE_COUNT {
		return false
	}
	for size, index in cache.sizes {
		if int(size.position_count) != position_count_of(index + 1) {
			return false
		}
	}
	return true
}

// reader_of makes the reader of the demand cache mapped at base, for the
// glyphs that stand beside a glyph cache. ok is false when the cache has
// another form (reader_matches).
reader_of :: proc "contextless" (base: uintptr, cache: ^glyph_cache.Cache) -> (reader: Reader, ok: bool) {
	if base == 0 || base % PAGE_SIZE != 0 || !reader_matches(cache) {
		return {}, false
	}
	reader.header = (^Header)(base)
	reader.entries = ([^]Entry)(base + ENTRIES_OFFSET)
	reader.words = ([^]u32)(base + WORDS_OFFSET)
	reader.font_hash = cache.header.font_hash
	return reader, true
}

// reader_frame_begin starts a frame: it empties the wanted characters and
// reads the generation once. The measure and the draw of the frame find an
// entry only when its generation is at most that value, so a glyph that the
// font service publishes during the frame is used from the next frame by
// both. A cache with no magic yet, another version or another font gives
// the limit 0: no entry is found, and each character is wanted.
reader_frame_begin :: proc "contextless" (reader: ^Reader) {
	reader.wanted_count = 0
	reader.generation_limit = 0
	if reader.header == nil || intrinsics.atomic_load_explicit(&reader.header.magic, .Acquire) != MAGIC {
		return
	}
	hash := reader.header.font_hash
	if reader.header.version != VERSION || hash != reader.font_hash {
		return
	}
	reader.generation_limit = intrinsics.atomic_load_explicit(&reader.header.generation, .Acquire)
}

// find gives the entry of a character, copied and checked. The state is
// Empty when the cache does not hold the character at the generation of
// the frame: the reader draws the replacement glyph and wants it. Absent:
// the font has no glyph, or the entry is wrong; the reader draws the
// replacement glyph and does not ask again.
find :: proc "contextless" (reader: ^Reader, character: rune) -> (entry: Entry, state: Entry_State) {
	if reader.generation_limit == 0 || character <= 0 || character > text_encoding.CODE_POINT_LAST {
		return {}, .Empty
	}
	home := home_place_of(character)
	for probe in 0 ..< PROBE_LIMIT {
		place := (home + probe) & (ENTRY_CAPACITY - 1)
		stored := intrinsics.atomic_load_explicit(&reader.entries[place].character, .Acquire)
		if stored == 0 {
			return {}, .Empty
		}
		if stored != u32(character) {
			continue
		}
		copied := intrinsics.volatile_load(&reader.entries[place])
		if copied.character != u32(character) || copied.generation == 0 || copied.generation > reader.generation_limit {
			return {}, .Empty
		}
		if !entry_valid(&copied) {
			return {}, .Absent
		}
		return copied, copied.state
	}
	return {}, .Empty
}

// want adds a character to the characters that the frame asks for, once.
// A character past WANTED_LIMIT is left: the next frame finds it again.
want :: proc "contextless" (reader: ^Reader, character: rune) {
	for wanted in reader.wanted[:reader.wanted_count] {
		if wanted == character {
			return
		}
	}
	if reader.wanted_count < WANTED_LIMIT {
		reader.wanted[reader.wanted_count] = character
		reader.wanted_count += 1
	}
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
// the magic last.
writer_open :: proc "contextless" (base: uintptr, font_hash: [32]u8, renderer_version: u32, flags: u32) -> (writer: Writer) {
	writer.header = (^Header)(base)
	writer.entries = ([^]Entry)(base + ENTRIES_OFFSET)
	writer.words = ([^]u32)(base + WORDS_OFFSET)
	writer.header.version = VERSION
	writer.header.renderer_version = renderer_version
	writer.header.font_hash = font_hash
	writer.header.flags = flags
	intrinsics.atomic_store_explicit(&writer.header.magic, MAGIC, .Release)
	return writer
}

// Place_Search: what place_find found for a character.
Place_Search :: enum u8 {
	Free, // A free place: the character is not in the cache.
	Published, // The character is in the cache.
	Full, // No free place in PROBE_LIMIT places: the character is refused.
}

// place_find finds the place of a character: its entry, or the first free
// place of its search.
place_find :: proc "contextless" (writer: ^Writer, character: rune) -> (place: int, search: Place_Search) {
	home := home_place_of(character)
	for probe in 0 ..< PROBE_LIMIT {
		place = (home + probe) & (ENTRY_CAPACITY - 1)
		switch writer.entries[place].character {
		case u32(character):
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

// publish writes an entry at a free place: each field, then the code point
// with release, then the generation of the header. A reader that finds the
// code point sees each field.
publish :: proc "contextless" (writer: ^Writer, place: int, character: rune, entry: Entry) {
	writer.generation += 1
	target := &writer.entries[place]
	target.state = entry.state
	target.generation = writer.generation
	target.advances = entry.advances
	target.glyphs = entry.glyphs
	intrinsics.atomic_store_explicit(&target.character, u32(character), .Release)
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

// The command of a request ring: the program asks for the glyphs of up to
// CHARACTERS_PER_REQUEST code points.
Request_Kind :: enum u32 {
	Glyphs = 1,
}
// The completion of a request: kind 0, the tag of the request, and the
// values below.
ANSWER_GENERATION :: 0 // The generation of the cache after the glyphs of the request.
ANSWER_DRAWN :: 1 // The characters that the request added, drawn.
ANSWER_ABSENT :: 2 // The characters that the font does not have.
ANSWER_REFUSED :: 3 // The characters that did not fit the cache.
ANSWER_PUBLISHED_BEFORE :: 4 // The characters that were in the cache already.

// Two code points in each of the seven values of a record.
CHARACTERS_PER_REQUEST :: 14
#assert(size_of(ring.Record) == 2 * size_of(u32) + CHARACTERS_PER_REQUEST * size_of(u32))

// request_pack writes the first CHARACTERS_PER_REQUEST characters of a list
// in a request record: two code points in each value, the low half first;
// 0 is no character. It gives the count that it wrote.
request_pack :: proc "contextless" (characters: []rune, tag: u32) -> (record: ring.Record, count: int) {
	record.kind = u32(Request_Kind.Glyphs)
	record.tag = tag
	count = min(len(characters), CHARACTERS_PER_REQUEST)
	for character, index in characters[:count] {
		record.values[index / 2] |= u64(u32(character)) << (32 * uint(index % 2))
	}
	return record, count
}

// request_unpack reads the code points of a request record, each value
// once. A value that is no character of a text is left out: the record
// comes from another program.
request_unpack :: proc "contextless" (record: ring.Record, characters: ^[CHARACTERS_PER_REQUEST]rune) -> (count: int) {
	for value in record.values {
		for half in 0 ..< 2 {
			character := rune(u32(value >> (32 * uint(half))))
			if character > 0 && character <= text_encoding.CODE_POINT_LAST && text_encoding.character_in_text(character) {
				characters[count] = character
				count += 1
			}
		}
	}
	return count
}

// The control ring of the font service: the root service names each
// request ring that it gives.
Control_Kind :: enum u32 {
	Client_Add    = 1, // values[0]: the ring in the handle table of the font service; values[1..4]: the name of the program (name_pack).
	Client_Remove = 2, // values[0]: the ring of Client_Add. The program stopped.
}

// The handles of the context of the font service.
SERVICE_GRANT_CACHE :: 0 // The demand cache, with Read and Write.
SERVICE_GRANT_CONTROL :: 1 // The control ring from the root service.
// The request rings that the font service serves at one time: with its
// control ring and the event word, the words of one wait of its thread
// (each ring two words).
CLIENT_CAPACITY :: 28
