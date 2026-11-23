#+build !freestanding
package text_rendering

import "core:testing"

// The ranges are in order and apart: else the search misses a range.
@(test)
the_ranges_of_cell_widths_are_in_order_and_apart :: proc(t: ^testing.T) {
	for range, index in cell_width_ranges {
		testing.expect(t, range.first <= range.last)
		testing.expect(t, range.width != .One, "a range of one cell says what the default says")
		if index > 0 {
			testing.expectf(t, cell_width_ranges[index - 1].last < range.first, "range %d starts before the end of the range before it", index)
		}
	}
}

// Each range at its edges: the character before its first, its first, its
// last, and the character after its last. Outside, a character takes one
// cell, or the cells of the next range when the ranges touch.
@(test)
each_range_holds_its_edges_and_nothing_past_them :: proc(t: ^testing.T) {
	outside :: proc(character: rune) -> Cell_Width {
		if is_mark(character) {
			return .Zero
		}
		for range in cell_width_ranges {
			if character >= range.first && character <= range.last {
				return range.width
			}
		}
		return .One
	}
	for range in cell_width_ranges {
		testing.expect_value(t, cell_width_of(range.first), range.width)
		testing.expect_value(t, cell_width_of(range.last), range.width)
		testing.expect_value(t, cell_width_of(range.first - 1), outside(range.first - 1))
		testing.expect_value(t, cell_width_of(range.last + 1), outside(range.last + 1))
	}
}

// The ranges that a terminal of Chinese, Japanese and Korean needs, each
// at start - 1, start, end and end + 1.
@(test)
the_east_asian_ranges_at_their_edges :: proc(t: ^testing.T) {
	Edge :: struct {
		first, last: rune,
		before, after: Cell_Width,
	}
	edges := [?]Edge {
		{0x4E00, 0x9FFF, .One, .Two}, // CJK Unified Ideographs; A000 starts Yi.
		{0x3400, 0x4DBF, .Two, .One}, // Extension A; 33FF is CJK Compatibility, 4DC0 a hexagram.
		{0xF900, 0xFAFF, .One, .One}, // CJK Compatibility Ideographs.
		{0x3040, 0x30FF, .One, .Two}, // Hiragana and Katakana; 303F is the half fill space, 3100 starts Bopomofo.
		{0xAC00, 0xD7A3, .One, .One}, // Hangul Syllables.
		{0xFF01, 0xFF60, .One, .One}, // Fullwidth Forms; FF61 is a halfwidth katakana.
	}
	for edge in edges {
		testing.expect_value(t, cell_width_of(edge.first - 1), edge.before)
		testing.expect_value(t, cell_width_of(edge.first), Cell_Width.Two)
		testing.expect_value(t, cell_width_of(edge.last), Cell_Width.Two)
		testing.expect_value(t, cell_width_of(edge.last + 1), edge.after)
	}
	testing.expect_value(t, cell_width_of('a'), Cell_Width.One)
	testing.expect_value(t, cell_width_of('é'), Cell_Width.One)
	testing.expect_value(t, cell_width_of(0x0301), Cell_Width.Zero) // A combining acute accent.
	testing.expect_value(t, cell_width_of(0x200D), Cell_Width.Zero) // The zero width joiner.
	testing.expect_value(t, cell_width_of(0xFE0F), Cell_Width.Zero) // A variation selector.
}

// A value that is no code point takes one cell: the replacement character.
@(test)
a_value_that_is_no_code_point_takes_one_cell :: proc(t: ^testing.T) {
	for value in ([?]rune{-1, min(rune), 0xD800, 0xDFFF, 0x110000, max(rune), 0}) {
		testing.expect_value(t, cell_width_of(value), Cell_Width.One)
	}
}

// The part of a text that fits in a room of cells: a wide character that
// finds one cell left stays for the next row.
@(test)
the_part_of_a_text_that_fits_in_a_room :: proc(t: ^testing.T) {
	text := transmute([]u8)string("ab日本")
	Case :: struct {
		room:         int,
		bytes, cells: int,
	}
	cases := [?]Case {
		{-1, 0, 0},
		{0, 0, 0},
		{1, 1, 1},
		{2, 2, 2},
		{3, 2, 2}, // One cell left for 日: it waits for the next row.
		{4, 5, 4},
		{5, 5, 4},
		{6, 8, 6},
		{max(int), 8, 6},
	}
	for test_case in cases {
		bytes, cells := cell_part(text, test_case.room)
		testing.expectf(t, bytes == test_case.bytes && cells == test_case.cells, "room %d: %d bytes and %d cells, not %d and %d", test_case.room, bytes, cells, test_case.bytes, test_case.cells)
	}
	// A wide character first, in a room of one cell: nothing fits.
	bytes, cells := cell_part(transmute([]u8)string("日"), 1)
	testing.expect_value(t, bytes, 0)
	testing.expect_value(t, cells, 0)
	// A mark of no width goes with the character before it, at the edge.
	bytes, cells = cell_part(transmute([]u8)string("e\u0301x"), 1)
	testing.expect_value(t, bytes, 3)
	testing.expect_value(t, cells, 1)
	empty_bytes, _ := cell_part(nil, 10)
	testing.expect_value(t, empty_bytes, 0)
}

@(test)
the_cells_of_a_text :: proc(t: ^testing.T) {
	testing.expect_value(t, cell_count(nil), 0)
	testing.expect_value(t, cell_count(transmute([]u8)string("abc")), 3)
	testing.expect_value(t, cell_count(transmute([]u8)string("日本語")), 6)
	testing.expect_value(t, cell_count(transmute([]u8)string("a日b")), 4)
	testing.expect_value(t, cell_count(transmute([]u8)string("e\u0301")), 1)
	testing.expect_value(t, cell_count(transmute([]u8)string("한국어")), 6)
	// An invalid byte is one cell of the replacement character, as
	// text_encoding.character_count counts it: each byte of a cut ideograph.
	testing.expect_value(t, cell_count([]u8{0xFF}), 1)
	testing.expect_value(t, cell_count([]u8{0xE6, 0x97}), 2)
}
