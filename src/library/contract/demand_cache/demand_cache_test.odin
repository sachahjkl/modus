#+build !freestanding
package demand_cache

import "core:mem"
import "core:testing"
import "modus:contract/glyph_cache"

// A demand cache in the memory of the test, on a page, all zero.
@(private = "file")
cache_memory_make :: proc() -> []u8 {
	bytes, error := mem.alloc_bytes(SIZE, PAGE_SIZE)
	assert(error == nil)
	return bytes
}

// A glyph cache of the form of a face, with no glyph: only its header and
// its sizes are read.
@(private = "file")
Form :: struct {
	header: glyph_cache.Header,
	sizes:  [SIZE_COUNT]glyph_cache.Size_Entry,
	cache:  glyph_cache.Cache,
}

@(private = "file")
form_make :: proc(form: ^Form, face: Face, hash_byte: u8) {
	shape := face_forms[face]
	form.header.flags = (shape.proportional ? glyph_cache.FLAG_PROPORTIONAL : 0) | (shape.grid_fit ? glyph_cache.FLAG_GRID_FIT : 0)
	form.header.font_hash[0] = hash_byte
	for &size, index in form.sizes[:shape.scale_count] {
		size.position_count = u16(position_count_of(face, index + 1))
	}
	form.cache = {header = &form.header, sizes = form.sizes[:shape.scale_count]}
}

// The headers of the faces of a writer: each face with the file and the
// flags of its form.
@(private = "file")
faces_of :: proc(forms: ^[Face]Form) -> (faces: [Face]Face_Header) {
	for form, face in forms^ {
		faces[face] = {font_hash = form.header.font_hash, flags = form.header.flags}
	}
	return faces
}

// The forms of the four faces, each with its own font file but the two
// faces of Paper Mono, which share one.
@(private = "file")
forms_make :: proc(forms: ^[Face]Form) {
	form_make(&forms[.Interface], .Interface, 1)
	form_make(&forms[.Cells], .Cells, 2)
	form_make(&forms[.Cells_Without_Grid_Fit], .Cells_Without_Grid_Fit, 2)
	form_make(&forms[.Cells_Bold], .Cells_Bold, 3)
}

// The reader of a face for the font file and the flags of a form.
@(private = "file")
reader_of_form :: proc(base: uintptr, face: Face, form: ^Form) -> (reader: Reader, ok: bool) {
	return reader_of(base, face, form.header.font_hash, form.header.flags)
}

// An entry of one glyph of ink at each place of a face, inside the cache
// and inside the cell of a cell face.
@(private = "file")
drawn_entry :: proc(face: Face, word_offset: u32) -> (entry: Entry) {
	entry.state = .Drawn
	proportional := face_forms[face].proportional
	for scale in 1 ..= face_forms[face].scale_count {
		entry.advances[scale - 1] = i32(CELL_WIDTH_AT_SCALE_ONE * scale * glyph_cache.SUBPIXEL)
		for position in 0 ..< position_count_of(face, scale) {
			place, _ := glyph_place_of(scale, position)
			entry.glyphs[place] = {first_row = 2, row_count = 4, word_offset = word_offset, left = proportional ? -1 : 0, width = 5}
		}
	}
	return entry
}

// A reader at an address that is 0 or not on a page is refused.
@(test)
a_reader_off_a_page_is_refused :: proc(t: ^testing.T) {
	hash: [32]u8
	_, ok := reader_of(0, .Interface, hash, 0)
	testing.expect(t, !ok)
	_, ok = reader_of(PAGE_SIZE + 8, .Interface, hash, 0)
	testing.expect(t, !ok)
	_, ok = reader_of(PAGE_SIZE - 1, .Cells, hash, 0)
	testing.expect(t, !ok)
	_, ok = reader_of(PAGE_SIZE, .Cells, hash, 0)
	testing.expect(t, ok)
}

// A cache with no magic, of another version, or of another font file or
// flags gives a reader nothing; a published entry is found from the next
// frame, as each draw of a frame takes the same entries. A code point that
// is 0, negative or past the last code point is found Empty.
@(test)
a_published_entry_is_found_from_the_next_frame :: proc(t: ^testing.T) {
	bytes := cache_memory_make()
	defer mem.free_bytes(bytes)
	base := uintptr(raw_data(bytes))
	forms: [Face]Form
	forms_make(&forms)
	reader, ok := reader_of_form(base, .Interface, &forms[.Interface])
	testing.expect(t, ok)
	// Before the font service wrote the header: nothing.
	reader_frame_begin(&reader)
	testing.expect_value(t, reader.generation_limit, u64(0))
	_, state := find(&reader, 0x03A9)
	testing.expect_value(t, state, Entry_State.Empty)
	writer := writer_open(base, 1, faces_of(&forms))
	reader_frame_begin(&reader)
	place, search := place_find(&writer, .Interface, 0x03A9)
	testing.expect_value(t, search, Place_Search.Free)
	offset, taken := words_take(&writer, 20)
	testing.expect(t, taken)
	publish(&writer, place, .Interface, 0x03A9, drawn_entry(.Interface, u32(offset)))
	// The frame that began before the publication.
	_, state = find(&reader, 0x03A9)
	testing.expect_value(t, state, Entry_State.Empty)
	// The next frame.
	reader_frame_begin(&reader)
	for character in ([?]rune{0, -1, 0x0011_0000, max(rune)}) {
		_, state = find(&reader, character)
		testing.expectf(t, state == .Empty, "the code point %v is found Empty", character)
	}
	// Another version: nothing.
	writer.header.version = VERSION + 1
	reader_frame_begin(&reader)
	_, state = find(&reader, 0x03A9)
	testing.expect_value(t, state, Entry_State.Empty)
	writer.header.version = VERSION
	reader_frame_begin(&reader)
	entry: Entry
	entry, state = find(&reader, 0x03A9)
	testing.expect_value(t, state, Entry_State.Drawn)
	testing.expect_value(t, entry.advances[2], i32(24 * glyph_cache.SUBPIXEL))
	glyph, has_glyph := glyph_of_entry(.Interface, &entry, 1, 2)
	testing.expect(t, has_glyph)
	testing.expect_value(t, glyph.width, u16(5))
	_, has_glyph = glyph_of_entry(.Interface, &entry, 2, 1)
	testing.expect(t, !has_glyph)
	// A second search finds it published.
	_, search = place_find(&writer, .Interface, 0x03A9)
	testing.expect_value(t, search, Place_Search.Published)
	// A reader of another font finds nothing.
	other_form: Form
	form_make(&other_form, .Interface, 9)
	other, _ := reader_of_form(base, .Interface, &other_form)
	reader_frame_begin(&other)
	testing.expect_value(t, other.generation_limit, u64(0))
	_, state = find(&other, 0x03A9)
	testing.expect_value(t, state, Entry_State.Empty)
}

// The faces keep their glyphs apart: one code point in two faces is two
// entries, a reader of one face does not find the entry of the other, and
// the two faces of Paper Mono, which share one font file, are told apart by
// their flags. A glyph cache of cells does not match the face Interface,
// and a cache of the interface font matches no cell face.
@(test)
the_faces_keep_their_glyphs_apart :: proc(t: ^testing.T) {
	bytes := cache_memory_make()
	defer mem.free_bytes(bytes)
	base := uintptr(raw_data(bytes))
	forms: [Face]Form
	forms_make(&forms)
	testing.expect(t, !reader_matches(.Interface, &forms[.Cells].cache))
	testing.expect(t, !reader_matches(.Cells, &forms[.Interface].cache))
	testing.expect(t, !reader_matches(.Cells, &forms[.Cells_Without_Grid_Fit].cache))
	testing.expect(t, !reader_matches(.Cells_Bold, &forms[.Cells].cache))
	writer := writer_open(base, 1, faces_of(&forms))
	OMEGA :: rune(0x03A9)
	BOX :: rune(0x2500)
	for face in ([2]Face{.Interface, .Cells}) {
		place, search := place_find(&writer, face, OMEGA)
		testing.expectf(t, search == .Free, "%v: Ω has a place of its own", face)
		publish(&writer, place, face, OMEGA, drawn_entry(face, 0))
	}
	place, _ := place_find(&writer, .Cells, BOX)
	publish(&writer, place, .Cells, BOX, drawn_entry(.Cells, 0))
	readers: [Face]Reader
	for face in Face {
		testing.expectf(t, reader_matches(face, &forms[face].cache), "%v: the glyph cache of its form matches", face)
		readers[face], _ = reader_of_form(base, face, &forms[face])
		reader_frame_begin(&readers[face])
		testing.expectf(t, readers[face].generation_limit == writer.generation, "%v: the font file and the flags of the face are the ones of its glyph cache", face)
	}
	// A reader of the face Cells with the flags of the cache with no grid
	// fit: the flags of the face differ, and it finds nothing.
	crossed := readers[.Cells]
	crossed.flags = forms[.Cells_Without_Grid_Fit].header.flags
	reader_frame_begin(&crossed)
	testing.expect_value(t, crossed.generation_limit, u64(0))
	_, state := find(&readers[.Interface], BOX)
	testing.expect_value(t, state, Entry_State.Empty)
	for face in ([2]Face{.Cells_Without_Grid_Fit, .Cells_Bold}) {
		_, state = find(&readers[face], BOX)
		testing.expectf(t, state == .Empty, "%v: the entry of the face Cells is not its own", face)
	}
	_, state = find(&readers[.Interface], OMEGA)
	testing.expect_value(t, state, Entry_State.Drawn)
	_, state = find(&readers[.Cells], BOX)
	testing.expect_value(t, state, Entry_State.Drawn)
}

// A wrong entry of the shared memory is never a read outside the cache:
// each one is found Absent, and the process draws the glyph itself. A cell
// entry whose glyph leaves its cell, or whose advance is not its cell, is
// wrong too.
@(test)
a_wrong_entry_is_never_a_read_outside_the_cache :: proc(t: ^testing.T) {
	bytes := cache_memory_make()
	defer mem.free_bytes(bytes)
	base := uintptr(raw_data(bytes))
	forms: [Face]Form
	forms_make(&forms)
	writer := writer_open(base, 1, faces_of(&forms))
	Wrong :: enum {
		Words_Past_The_Cache,
		Too_Wide,
		Rows_Past_The_Line,
		Left_Too_Far,
		Negative_Advance,
		Advance_Too_Large,
		Unknown_State,
		Empty_State,
		Cell_Glyph_Left_Of_Its_Cell,
		Cell_Glyph_Wider_Than_Its_Cell,
		Cell_Advance_Not_Its_Cell,
	}
	for wrong, index in Wrong {
		face := Face.Interface
		switch wrong {
		case .Cell_Glyph_Left_Of_Its_Cell, .Cell_Glyph_Wider_Than_Its_Cell, .Cell_Advance_Not_Its_Cell:
			face = .Cells
		case .Words_Past_The_Cache, .Too_Wide, .Rows_Past_The_Line, .Left_Too_Far, .Negative_Advance, .Advance_Too_Large, .Unknown_State, .Empty_State:
		}
		entry := drawn_entry(face, 0)
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
		case .Empty_State:
			entry.state = .Empty
		case .Cell_Glyph_Left_Of_Its_Cell:
			entry.glyphs[0].left = 1
		case .Cell_Glyph_Wider_Than_Its_Cell:
			entry.glyphs[0].width = CELL_WIDTH_AT_SCALE_ONE + 1
		case .Cell_Advance_Not_Its_Cell:
			entry.advances[2] -= 1
		}
		character := rune(0x0391 + index)
		place, _ := place_find(&writer, face, character)
		publish(&writer, place, face, character, entry)
		reader, _ := reader_of_form(base, face, &forms[face])
		reader_frame_begin(&reader)
		_, state := find(&reader, character)
		testing.expectf(t, state == .Absent, "%v: the entry is refused", wrong)
	}
	// The same entries with each field at its limit are drawn.
	for face in ([2]Face{.Interface, .Cells}) {
		place, _ := place_find(&writer, face, 0x03B1)
		publish(&writer, place, face, 0x03B1, drawn_entry(face, WORD_CAPACITY - 20))
		reader, _ := reader_of_form(base, face, &forms[face])
		reader_frame_begin(&reader)
		_, state := find(&reader, 0x03B1)
		testing.expectf(t, state == .Drawn, "%v: the entry inside its limits is drawn", face)
	}
}

// A character whose places are all taken is refused, and its search ends
// after PROBE_LIMIT places. The words end at their capacity: a count past
// them and a negative count are refused.
@(test)
a_full_search_and_full_words_are_refused :: proc(t: ^testing.T) {
	bytes := cache_memory_make()
	defer mem.free_bytes(bytes)
	base := uintptr(raw_data(bytes))
	forms: [Face]Form
	forms_make(&forms)
	reader, _ := reader_of_form(base, .Interface, &forms[.Interface])
	writer := writer_open(base, 1, faces_of(&forms))
	character := rune(0x03A9)
	home := home_place_of(key_of(.Interface, character))
	for probe in 0 ..< PROBE_LIMIT {
		other := rune(0x4E00 + probe) // Characters that are not the one searched.
		publish(&writer, (home + probe) & (ENTRY_CAPACITY - 1), .Interface, other, Entry{state = .Absent})
	}
	_, search := place_find(&writer, .Interface, character)
	testing.expect_value(t, search, Place_Search.Full)
	reader_frame_begin(&reader)
	_, state := find(&reader, character)
	testing.expect_value(t, state, Entry_State.Empty)
	_, taken := words_take(&writer, -1)
	testing.expect(t, !taken)
	_, taken = words_take(&writer, WORD_CAPACITY + 1)
	testing.expect(t, !taken)
	testing.expect_value(t, writer.words_used, 0)
	_, taken = words_take(&writer, WORD_CAPACITY)
	testing.expect(t, taken)
	_, taken = words_take(&writer, 1)
	testing.expect(t, !taken)
	refusal_count(&writer)
	testing.expect_value(t, writer.header.refused, u64(1))
}

// The subset of each face: runs in the order of the code points, with a
// gap between two runs or two runs of two blocks of Unicode that touch;
// subset_count is the count of its characters, and in_subset says yes for
// each of them only. The subset of the face Interface is the Greek letters
// of B612, without the capital pi and the small rho; the cell subset is
// the five Greek letters of Paper Mono and the 160 box-drawing characters
// and block elements. A character of the glyph cache is in no subset.
// That each font has each character of its subset is the host test of the
// tool, each_source_font_has_the_characters_of_a_cache.
@(test)
the_subsets_of_the_faces :: proc(t: ^testing.T) {
	outside := [?]rune{-1, 0, 'W', 0xE9, 0x20AC, 0x0390, 0x03A0, 0x03A2, 0x03C1, 0x03CA, 0x4E00, 0x0011_0000}
	for character in outside {
		testing.expectf(t, !in_subset(.Interface, character), "U+%04X is not in the subset of the interface font", int(character))
	}
	cell_outside := [?]rune{-1, 0, 'W', 0x03B1, 0x0391, 0x24FF, 0x25A0, 0x0011_0000}
	for character in cell_outside {
		testing.expectf(t, !in_subset(.Cells, character), "U+%04X is not in the cell subset", int(character))
	}
	for face in Face {
		counted := 0
		previous_last := rune(-1)
		for range in subset_of(face) {
			testing.expectf(t, range.first <= range.last && range.first > previous_last, "%v: U+%04X to U+%04X: a run after the run before", face, int(range.first), int(range.last))
			for character in range.first ..= range.last {
				testing.expectf(t, in_subset(face, character), "%v: U+%04X is in the subset", face, int(character))
				_, in_cache := glyph_cache.character_index(character)
				testing.expectf(t, !in_cache, "%v: U+%04X is past the glyph cache", face, int(character))
				counted += 1
			}
			previous_last = range.last
		}
		testing.expect_value(t, subset_count(face), counted)
	}
	greek := 0
	for character in rune(0x0300) ..= 0x03FF {
		if in_subset(.Interface, character) {
			greek += 1
		}
	}
	testing.expect_value(t, greek, subset_count(.Interface))
	boxes := 0
	for character in rune(0x2500) ..= 0x259F {
		testing.expectf(t, in_subset(.Cells, character), "U+%04X is in the cell subset", int(character))
		boxes += 1
	}
	cell_greek := [?]rune{0x039B, 0x03A9, 0x03BB, 0x03BC, 0x03C0}
	for character in cell_greek {
		testing.expectf(t, in_subset(.Cells, character), "U+%04X is in the cell subset", int(character))
	}
	testing.expect_value(t, subset_count(.Cells), boxes + len(cell_greek))
	// The constants of the bound of the words are the counts of the lists.
	testing.expect_value(t, subset_count(.Interface), INTERFACE_SUBSET_COUNT)
	for face in ([3]Face{.Cells, .Cells_Without_Grid_Fit, .Cells_Bold}) {
		testing.expectf(t, subset_count(face) == CELL_SUBSET_COUNT, "%v: the count of CELL_SUBSET_COUNT", face)
	}
}

// The places of the glyphs: three positions at scale 1, one at the scales
// 2 and 3, each glyph its own place. A cell face has one position at each
// of its scales; the bold face has scale 1 only. A scale or a position
// that a face does not have has no place.
@(test)
the_places_of_the_glyphs :: proc(t: ^testing.T) {
	refused := [?][2]int{{0, 0}, {-1, 0}, {SIZE_COUNT + 1, 0}, {1, -1}, {1, POSITIONS_AT_SCALE_ONE}, {2, 1}, {max(int), 0}}
	for pair in refused {
		_, ok := glyph_place_of(pair[0], pair[1])
		testing.expectf(t, !ok, "scale %v, position %v has no place", pair[0], pair[1])
	}
	testing.expect_value(t, position_count_of(.Cells_Bold, 2), 0)
	testing.expect_value(t, position_count_of(.Interface, 0), 0)
	testing.expect_value(t, position_count_of(.Interface, SIZE_COUNT + 1), 0)
	entry: Entry
	_, ok := glyph_of_entry(.Cells_Bold, &entry, 2, 0)
	testing.expect(t, !ok)
	_, ok = glyph_of_entry(.Cells, &entry, 1, 1)
	testing.expect(t, !ok)
	_, ok = glyph_of_entry(.Interface, &entry, 1, -1)
	testing.expect(t, !ok)
	seen: [GLYPH_COUNT]bool
	for scale in 1 ..= SIZE_COUNT {
		for position in 0 ..< position_count_of(.Interface, scale) {
			place, place_ok := glyph_place_of(scale, position)
			testing.expect(t, place_ok && !seen[place])
			seen[place] = true
		}
	}
	for each in seen {
		testing.expect(t, each)
	}
	for scale in 1 ..= SIZE_COUNT {
		testing.expect_value(t, position_count_of(.Cells, scale), 1)
	}
	testing.expect_value(t, position_count_of(.Cells_Bold, 1), 1)
}

// The keys of the faces: never 0, and one code point of two faces gives two
// keys.
@(test)
the_keys_of_the_faces :: proc(t: ^testing.T) {
	for face in Face {
		testing.expect(t, key_of(face, 1) != 0)
		for other in Face {
			testing.expect(t, face == other || key_of(face, 0x03A9) != key_of(other, 0x03A9))
		}
	}
}
