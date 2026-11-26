#+build !freestanding
#+build !modus
package text_rendering

import "core:testing"

// The place of a glyph of text: the nearest third of a pixel, a half
// toward the next position, on each side of 0. A position_count of 1 gives
// the nearest whole pixel, and a position_count under 1 is taken as 1.
@(test)
the_position_of_a_place :: proc(t: ^testing.T) {
	Case :: struct {
		place:    i64,
		pixel:    i64,
		position: int,
	}
	cases := [?]Case{{0, 0, 0}, {10, 0, 0}, {11, 0, 1}, {21, 0, 1}, {32, 0, 2}, {53, 0, 2}, {54, 1, 0}, {64 * 7 + 22, 7, 1}, {-1, 0, 0}, {-40, -1, 1}, {-64, -1, 0}}
	for item in cases {
		pixel, position := position_of(item.place, POSITION_LIMIT)
		testing.expectf(t, pixel == item.pixel && position == item.position, "%v: %v %v, expected %v %v", item.place, pixel, position, item.pixel, item.position)
	}
	for count in ([3]int{1, 0, -1}) {
		pixel, position := position_of(64 * 5 + 40, count)
		testing.expectf(t, pixel == 6 && position == 0, "%v positions: %v %v", count, pixel, position)
	}
}

// A flat capital of B612 sits on ten rows at the size of the body: the
// cap height that the font states (1500 units) is ten rows, rows 2 to 11
// over the baseline on row 12 (vector_font, the_stated_cap_height_sizes_b612).
@(test)
a_flat_capital_sits_on_ten_rows :: proc(t: ^testing.T) {
	test_state_take()
	fonts := repository_fonts()
	_, words := outlines_open(t, fonts[:])
	defer delete(words)
	baseline, ok := baseline_row(.Interface, TEXT_SIZE_OF_SCALE_ONE)
	testing.expect(t, ok && baseline == 12)
	for character in ([3]rune{'E', 'T', 'Z'}) {
		frame_begin()
		entry, _, source := glyph(.Interface, character, TEXT_SIZE_OF_SCALE_ONE, 0)
		testing.expect_value(t, source, Glyph_Source.Private_Cache)
		testing.expectf(t, entry.first_row == 2 && entry.row_count == 10, "%c: rows %v to %v, expected 2 to 11", character, entry.first_row, int(entry.first_row) + int(entry.row_count) - 1)
	}
}
