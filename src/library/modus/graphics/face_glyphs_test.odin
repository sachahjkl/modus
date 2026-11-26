#+build !freestanding
#+build !modus
package graphics

import "core:sync"
import "core:testing"
import "modus:contract/font_characters"
import "modus:text_rendering"

// The glyphs of the tests of the blend: the characters of ASCII of one
// face, at the sizes of the scales 1 to TEST_SCALE_COUNT and at each
// position of the face, drawn by the text rendering and copied out of the
// private glyph cache into memory of the test. Their words are the words
// of the face, which the golden hashes of the text rendering hold; the
// tests of the blend then draw them with each blend, with no lock held.

TEST_SCALE_COUNT :: 3

Test_Glyphs :: struct {
	face:           text_rendering.Face,
	position_count: int,
	entries:        [TEST_SCALE_COUNT][text_rendering.POSITION_LIMIT][font_characters.ASCII_COUNT]text_rendering.Glyph_Entry,
	words:          [dynamic]u32,
}

// test_glyphs_of draws and copies the glyphs of a face. The caller holds
// fallback_test_lock: the outlines open in the state of the package, which
// it sets back to zero after the copy.
test_glyphs_of :: proc(t: ^testing.T, face: text_rendering.Face) -> (glyphs: ^Test_Glyphs) {
	outline_words := fallback_open_for_test(t)
	defer delete(outline_words)
	defer text_rendering.state = {}
	glyphs = new(Test_Glyphs)
	glyphs.face = face
	glyphs.position_count = text_rendering.positions_of(face)
	for scale in 1 ..= TEST_SCALE_COUNT {
		for position in 0 ..< glyphs.position_count {
			for index in 0 ..< font_characters.ASCII_COUNT {
				character, _ := font_characters.character_of_index(index)
				// A new frame for each glyph: no glyph is drawn and not kept.
				text_rendering.frame_begin()
				entry, words, source := text_rendering.glyph(face, character, text_rendering.size_of_scale(scale), position)
				testing.expectf(t, source == .Private_Cache, "%v %c at scale %v, position %v: from %v", face, character, scale, position, source)
				copied := entry
				copied.word_offset = u32(len(glyphs.words))
				count := int(entry.row_count) * int(entry.width)
				if count > 0 {
					append(&glyphs.words, ..words[:count])
				}
				glyphs.entries[scale - 1][position][index] = copied
			}
		}
	}
	return glyphs
}

test_glyphs_free :: proc(glyphs: ^Test_Glyphs) {
	delete(glyphs.words)
	free(glyphs)
}

// test_glyph gives the glyph of a character of ASCII at a scale and a
// position, and its first word; found is false for another character, a
// scale or a position out of the copy.
test_glyph :: proc(glyphs: ^Test_Glyphs, character: rune, scale: int, position := 0) -> (entry: text_rendering.Glyph_Entry, words: [^]u32, found: bool) {
	index, in_font := font_characters.character_index(character)
	if !in_font || index >= font_characters.ASCII_COUNT || scale < 1 || scale > TEST_SCALE_COUNT || position < 0 || position >= glyphs.position_count {
		return {}, nil, false
	}
	entry = glyphs.entries[scale - 1][position][index]
	if entry.row_count == 0 {
		return entry, nil, true
	}
	return entry, raw_data(glyphs.words[entry.word_offset:]), true
}

// test_glyph_fast_draw draws a glyph of the copy with the fast blend of the
// text of the system (glyph_words_draw).
test_glyph_fast_draw :: proc(glyphs: ^Test_Glyphs, square_root: ^[4096]u8, tables: ^Blend_Tables, order: Subpixel_Order, canvas: Canvas, x, y: int, character: rune, color: Color, scale: int, alpha: u32 = OPAQUE, position := 0) {
	entry, words, found := test_glyph(glyphs, character, scale, position)
	if !found || entry.row_count == 0 {
		return
	}
	glyph_words_draw(entry, words, square_root, tables, order, canvas, x, y, color, alpha)
}

// test_glyph_reference_draw draws a glyph of the copy with the blend of
// one row at a time (blend_coverage_row): the reference of the fast blend.
test_glyph_reference_draw :: proc(glyphs: ^Test_Glyphs, square_root: ^[4096]u8, order: Subpixel_Order, canvas: Canvas, x, y: int, character: rune, color: Color, scale: int, alpha: u32 = OPAQUE, position := 0) {
	entry, words, found := test_glyph(glyphs, character, scale, position)
	if !found || entry.row_count == 0 {
		return
	}
	column_x := x + int(entry.left)
	width := int(entry.width)
	first_column := max(0, -column_x)
	last_column := min(width, canvas.width - column_x)
	first_row := max(0, -(y + int(entry.first_row)))
	last_row := min(int(entry.row_count), canvas.height - y - int(entry.first_row))
	if first_column >= last_column || first_row >= last_row {
		return
	}
	for row in first_row ..< last_row {
		line := canvas.pixels[(y + int(entry.first_row) + row) * canvas.stride + column_x:]
		blend_coverage_row(line, words[row * width:], first_column, last_column, color, order, square_root, alpha)
	}
}

// A copy refuses each character, scale and position outside it, and the
// space has no ink: the edges of test_glyph, before the tests of the blend
// trust it.
@(test)
the_glyphs_of_the_tests_refuse_what_they_lack :: proc(t: ^testing.T) {
	sync.mutex_lock(&fallback_test_lock)
	defer sync.mutex_unlock(&fallback_test_lock)
	glyphs := test_glyphs_of(t, .Cells)
	defer test_glyphs_free(glyphs)
	Refused :: struct {
		character:       rune,
		scale, position: int,
	}
	refused := [?]Refused{{'A', 0, 0}, {'A', TEST_SCALE_COUNT + 1, 0}, {'A', 1, -1}, {'A', 1, 1}, {font_characters.ASCII_FIRST - 1, 1, 0}, {font_characters.ASCII_LAST + 1, 1, 0}, {'é', 1, 0}, {-1, 1, 0}}
	for each in refused {
		_, _, found := test_glyph(glyphs, each.character, each.scale, each.position)
		testing.expectf(t, !found, "%v at scale %v, position %v is not in the copy", each.character, each.scale, each.position)
	}
	space, _, space_found := test_glyph(glyphs, ' ', 1)
	testing.expect(t, space_found && space.row_count == 0)
	letter, words, letter_found := test_glyph(glyphs, 'A', TEST_SCALE_COUNT)
	testing.expect(t, letter_found && letter.row_count > 0 && words != nil)
}
