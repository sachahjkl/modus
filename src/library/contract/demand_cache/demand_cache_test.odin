#+build !freestanding
package demand_cache

import "core:mem"
import "core:testing"
import "modus:contract/glyph_cache"
import "modus:contract/ring"

// A demand cache in the memory of the test, on a page, all zero.
@(private = "file")
cache_memory_make :: proc() -> []u8 {
	bytes, error := mem.alloc_bytes(SIZE, PAGE_SIZE)
	assert(error == nil)
	return bytes
}

// A glyph cache of the form of the demand cache, with no glyph: only its
// header and its sizes are read.
@(private = "file")
Form :: struct {
	header: glyph_cache.Header,
	sizes:  [SIZE_COUNT]glyph_cache.Size_Entry,
	cache:  glyph_cache.Cache,
}

@(private = "file")
form_make :: proc(form: ^Form, hash_byte: u8) {
	form.header.flags = glyph_cache.FLAG_PROPORTIONAL | glyph_cache.FLAG_GRID_FIT
	form.header.font_hash[0] = hash_byte
	for &size, index in form.sizes {
		size.position_count = u16(position_count_of(index + 1))
	}
	form.cache = {header = &form.header, sizes = form.sizes[:]}
}

// An entry of one glyph of ink at each place, inside the cache.
@(private = "file")
drawn_entry :: proc(word_offset: u32) -> (entry: Entry) {
	entry.state = .Drawn
	for scale in 1 ..= SIZE_COUNT {
		entry.advances[scale - 1] = i32(8 * scale * glyph_cache.SUBPIXEL)
		for position in 0 ..< position_count_of(scale) {
			place, _ := glyph_place_of(scale, position)
			entry.glyphs[place] = {first_row = 2, row_count = 4, word_offset = word_offset, left = -1, width = 5}
		}
	}
	return entry
}

// A request holds 14 code points, two in each value, and the reader of the
// font service reads back each one; a value that is no character of a text
// is left out.
@(test)
a_request_holds_fourteen_code_points :: proc(t: ^testing.T) {
	characters: [20]rune
	for &character, index in characters {
		character = rune(0x0391 + index)
	}
	record, count := request_pack(characters[:], 7)
	testing.expect_value(t, count, CHARACTERS_PER_REQUEST)
	testing.expect_value(t, record.kind, u32(Request_Kind.Glyphs))
	testing.expect_value(t, record.tag, u32(7))
	read: [CHARACTERS_PER_REQUEST]rune
	testing.expect_value(t, request_unpack(record, &read), CHARACTERS_PER_REQUEST)
	for character, index in read {
		testing.expect_value(t, character, characters[index])
	}
	// Three characters: the other halves are 0, which is no character.
	record, count = request_pack(characters[:3], 8)
	testing.expect_value(t, count, 3)
	testing.expect_value(t, request_unpack(record, &read), 3)
	// A hostile record: a control character, a surrogate, a number past the
	// last code point, then one character.
	hostile := ring.Record {
		kind = u32(Request_Kind.Glyphs),
		values = {0 = 0x1B | u64(0xD800) << 32, 1 = 0x0011_0000 | u64(0x03A9) << 32},
	}
	testing.expect_value(t, request_unpack(hostile, &read), 1)
	testing.expect_value(t, read[0], rune(0x03A9))
}

// A published entry is found from the next frame: the frame that started
// before the publication does not see it, so its measure and its draw
// agree. A cache with no magic, or of another font, finds nothing.
@(test)
a_published_entry_is_found_from_the_next_frame :: proc(t: ^testing.T) {
	bytes := cache_memory_make()
	defer mem.free_bytes(bytes)
	base := uintptr(raw_data(bytes))
	form: Form
	form_make(&form, 1)
	reader, ok := reader_of(base, &form.cache)
	testing.expect(t, ok)
	// Before the font service wrote the header: nothing.
	reader_frame_begin(&reader)
	_, state := find(&reader, 0x03A9)
	testing.expect_value(t, state, Entry_State.Empty)
	writer := writer_open(base, form.header.font_hash, 1, form.header.flags)
	reader_frame_begin(&reader)
	place, search := place_find(&writer, 0x03A9)
	testing.expect_value(t, search, Place_Search.Free)
	offset, taken := words_take(&writer, 20)
	testing.expect(t, taken)
	publish(&writer, place, 0x03A9, drawn_entry(u32(offset)))
	// The frame that began before the publication.
	_, state = find(&reader, 0x03A9)
	testing.expect_value(t, state, Entry_State.Empty)
	// The next frame.
	reader_frame_begin(&reader)
	entry: Entry
	entry, state = find(&reader, 0x03A9)
	testing.expect_value(t, state, Entry_State.Drawn)
	testing.expect_value(t, entry.advances[2], i32(24 * glyph_cache.SUBPIXEL))
	glyph, has_glyph := glyph_of_entry(&entry, 1, 2)
	testing.expect(t, has_glyph)
	testing.expect_value(t, glyph.width, u16(5))
	_, has_glyph = glyph_of_entry(&entry, 2, 1)
	testing.expect(t, !has_glyph)
	// A second search finds it published.
	_, search = place_find(&writer, 0x03A9)
	testing.expect_value(t, search, Place_Search.Published)
	// An absent character.
	place, search = place_find(&writer, 0x0101)
	testing.expect_value(t, search, Place_Search.Free)
	publish(&writer, place, 0x0101, Entry{state = .Absent})
	reader_frame_begin(&reader)
	_, state = find(&reader, 0x0101)
	testing.expect_value(t, state, Entry_State.Absent)
	// A reader of another font finds nothing.
	other_form: Form
	form_make(&other_form, 2)
	other, _ := reader_of(base, &other_form.cache)
	reader_frame_begin(&other)
	testing.expect_value(t, other.generation_limit, u64(0))
	_, state = find(&other, 0x03A9)
	testing.expect_value(t, state, Entry_State.Empty)
	// A glyph cache of another form has no reader.
	form.sizes[0].position_count = 1
	_, ok = reader_of(base, &form.cache)
	testing.expect(t, !ok)
}

// A wrong entry of the shared memory is never a read outside the cache:
// each one is found Absent, and draws the replacement glyph.
@(test)
a_wrong_entry_is_never_a_read_outside_the_cache :: proc(t: ^testing.T) {
	bytes := cache_memory_make()
	defer mem.free_bytes(bytes)
	base := uintptr(raw_data(bytes))
	form: Form
	form_make(&form, 1)
	reader, _ := reader_of(base, &form.cache)
	writer := writer_open(base, form.header.font_hash, 1, form.header.flags)
	Wrong :: enum {
		Words_Past_The_Cache,
		Too_Wide,
		Rows_Past_The_Line,
		Left_Too_Far,
		Negative_Advance,
		Advance_Too_Large,
		Unknown_State,
	}
	for wrong, index in Wrong {
		entry := drawn_entry(0)
		switch wrong {
		case .Words_Past_The_Cache:
			entry.glyphs[GLYPH_COUNT - 1].word_offset = WORD_CAPACITY - 3
		case .Too_Wide:
			entry.glyphs[0].width = glyph_cache.GLYPH_WIDTH_LIMIT + 1
		case .Rows_Past_The_Line:
			entry.glyphs[0].first_row = LINE_HEIGHT_AT_SCALE_ONE - 1
		case .Left_Too_Far:
			entry.glyphs[1].left = -glyph_cache.LEFT_LIMIT - 1
		case .Negative_Advance:
			entry.advances[0] = -1
		case .Advance_Too_Large:
			entry.advances[1] = glyph_cache.ADVANCE_LIMIT + 1
		case .Unknown_State:
			entry.state = Entry_State(u32(max(Entry_State)) + 1)
		}
		character := rune(0x0391 + index)
		place, _ := place_find(&writer, character)
		publish(&writer, place, character, entry)
		reader_frame_begin(&reader)
		_, state := find(&reader, character)
		testing.expectf(t, state == .Absent, "%v: the entry is refused", wrong)
	}
	// The same entry with each field inside its limits is drawn.
	place, _ := place_find(&writer, 0x03B1)
	publish(&writer, place, 0x03B1, drawn_entry(WORD_CAPACITY - 20))
	reader_frame_begin(&reader)
	_, state := find(&reader, 0x03B1)
	testing.expect_value(t, state, Entry_State.Drawn)
}

// A character whose places are all taken is refused, and its search ends
// after PROBE_LIMIT places. The words end at their capacity.
@(test)
a_full_search_and_full_words_are_refused :: proc(t: ^testing.T) {
	bytes := cache_memory_make()
	defer mem.free_bytes(bytes)
	base := uintptr(raw_data(bytes))
	form: Form
	form_make(&form, 1)
	reader, _ := reader_of(base, &form.cache)
	writer := writer_open(base, form.header.font_hash, 1, form.header.flags)
	character := rune(0x03A9)
	home := home_place_of(character)
	for probe in 0 ..< PROBE_LIMIT {
		other := rune(0x4E00 + probe) // Characters that are not the one searched.
		publish(&writer, (home + probe) & (ENTRY_CAPACITY - 1), other, Entry{state = .Absent})
	}
	_, search := place_find(&writer, character)
	testing.expect_value(t, search, Place_Search.Full)
	reader_frame_begin(&reader)
	_, state := find(&reader, character)
	testing.expect_value(t, state, Entry_State.Empty)
	_, taken := words_take(&writer, WORD_CAPACITY)
	testing.expect(t, taken)
	_, taken = words_take(&writer, 1)
	testing.expect(t, !taken)
	refusal_count(&writer)
	testing.expect_value(t, writer.header.refused, u64(1))
}

// A frame wants each character once, and at most WANTED_LIMIT of them.
@(test)
a_frame_wants_each_character_once :: proc(t: ^testing.T) {
	reader: Reader
	for _ in 0 ..< 3 {
		want(&reader, 0x03A9)
	}
	testing.expect_value(t, reader.wanted_count, 1)
	for index in 0 ..< 2 * WANTED_LIMIT {
		want(&reader, rune(0x0391 + index))
	}
	testing.expect_value(t, reader.wanted_count, WANTED_LIMIT)
	// The start of a frame empties the list.
	reader_frame_begin(&reader)
	testing.expect_value(t, reader.wanted_count, 0)
}

// The subset: the 48 Greek letters, with no small rho and no U+03A2; a
// character of the glyph cache is not in it.
@(test)
the_subset_is_the_greek_letters :: proc(t: ^testing.T) {
	testing.expect_value(t, subset_count(), 48)
	inside := [?]rune{0x0391, 0x03A9, 0x03B1, 0x03C0, 0x03C2, 0x03C9}
	for character in inside {
		testing.expectf(t, in_subset(character), "U+%04X is in the subset", int(character))
	}
	outside := [?]rune{'W', 0xE9, 0x20AC, 0x0390, 0x03A2, 0x03C1, 0x03CA, 0x4E00}
	for character in outside {
		testing.expectf(t, !in_subset(character), "U+%04X is not in the subset", int(character))
	}
}

// The places of the glyphs: three positions at scale 1, one at the scales 2
// and 3, each glyph its own place.
@(test)
the_places_of_the_glyphs :: proc(t: ^testing.T) {
	seen: [GLYPH_COUNT]bool
	for scale in 1 ..= SIZE_COUNT {
		for position in 0 ..< position_count_of(scale) {
			place, ok := glyph_place_of(scale, position)
			testing.expect(t, ok && !seen[place])
			seen[place] = true
		}
	}
	for each in seen {
		testing.expect(t, each)
	}
	_, ok := glyph_place_of(0, 0)
	testing.expect(t, !ok)
	_, ok = glyph_place_of(SIZE_COUNT + 1, 0)
	testing.expect(t, !ok)
}
