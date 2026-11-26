#+build !freestanding
#+build !modus
package graphics

import "core:sync"
import "core:testing"
import "modus:text_rendering"

// With Spleen in force, the ink of each character of the font of the cells
// stays inside the box of its measure, at each text size (interface.text_width
// is the count of the characters times cell_advance): the
// least, the caption under the body (where a glyph of 8 columns passed a
// cell of 7 and lost its last column), one under the body, the body, one
// past it, the sizes of a heading, one under twice the body and its edge of
// a half up, twice the body, and one past it. The draw ends where the measure
// ends.
@(test)
spleen_ink_stays_inside_its_measured_box :: proc(t: ^testing.T) {
	// The text state is of the process: one test changes it at a time.
	sync.mutex_lock(&fallback_test_lock)
	defer sync.mutex_unlock(&fallback_test_lock)
	text_choice_set(.Spleen, .Red_Green_Blue)
	defer text_choice_set(.Vector, .Red_Green_Blue)
	WIDTH :: 160
	HEIGHT :: 96
	LEFT :: 32
	pixels := new([WIDTH * HEIGHT]Color, context.temp_allocator)
	canvas := Canvas{pixels = raw_data(pixels[:]), width = WIDTH, height = HEIGHT, stride = WIDTH}
	sizes := [?]int{8, TEXT_CAPTION, 15, 16, 17, 20, 28, 30, 31, 32, 33}
	for size_pixels in sizes {
		size := size_pixels * text_rendering.SUBPIXEL
		if text_rendering.size_check(size) != .None {
			continue
		}
		for character in 33 ..= 126 {
			one := [2]u8{u8(character), u8(character)}
			text := string(one[:])
			for &pixel in pixels {
				pixel = 0
			}
			width := len(text) * cell_advance(size)
			end := text_sized(canvas, LEFT, 8, text, 0xFFFFFF, size)
			testing.expectf(t, end == LEFT + width, "size %d, %q: the draw ends at %d and the measure at %d", size_pixels, text, end, LEFT + width)
			outside := 0
			for row in 0 ..< HEIGHT {
				for column in 0 ..< WIDTH {
					if (column < LEFT || column >= LEFT + width) && pixels[row * WIDTH + column] != 0 {
						outside += 1
					}
				}
			}
			testing.expectf(t, outside == 0, "size %d, %q: %d pixels of ink outside the box of %d pixels", size_pixels, text, outside, width)
		}
	}
	// The advance of Spleen is its glyph at its scale: under the body, at
	// the body, between the body and twice the body (a heading, whose
	// letters stood apart in a wider cell), and at twice the body.
	testing.expect_value(t, cell_advance(TEXT_CAPTION * text_rendering.SUBPIXEL), CELL_WIDTH)
	testing.expect_value(t, cell_advance(16 * text_rendering.SUBPIXEL), CELL_WIDTH)
	testing.expect_value(t, cell_advance(28 * text_rendering.SUBPIXEL), CELL_WIDTH)
	testing.expect_value(t, cell_advance(30 * text_rendering.SUBPIXEL), CELL_WIDTH)
	// 31 pixels: the cell of the size is 16, a half up, and Spleen draws at
	// its scale 2.
	testing.expect_value(t, cell_advance(31 * text_rendering.SUBPIXEL), 2 * CELL_WIDTH)
	testing.expect_value(t, cell_advance(32 * text_rendering.SUBPIXEL), 2 * CELL_WIDTH)
	// Between two glyphs of a word at the size of a heading, the empty
	// columns are those that the glyphs of Spleen leave themselves, at
	// most two: "mm" read as "m m" with the cell of the size.
	for &pixel in pixels {
		pixel = 0
	}
	size := 28 * text_rendering.SUBPIXEL
	_ = text_sized(canvas, LEFT, 8, "mm", 0xFFFFFF, size)
	advance := cell_advance(size)
	column_has_ink :: proc(pixels: []Color, column: int) -> bool {
		for row in 0 ..< HEIGHT {
			if pixels[row * WIDTH + column] != 0 {
				return true
			}
		}
		return false
	}
	first_right, second_left := -1, -1
	for column in LEFT ..< LEFT + advance {
		if column_has_ink(pixels[:], column) {
			first_right = column
		}
	}
	for column := LEFT + 2 * advance - 1; column >= LEFT + advance; column -= 1 {
		if column_has_ink(pixels[:], column) {
			second_left = column
		}
	}
	testing.expectf(t, first_right >= 0 && second_left >= 0 && second_left - first_right - 1 <= 2, "the two letters of mm stand %d columns apart", second_left - first_right - 1)
}

// The advance that a draw at a scale gives (spleen_advance): 0 and a
// negative advance take cell_advance of the size; an advance takes the
// place of it, and the glyph takes the largest whole scale that fits it
// and that the size allows, in the middle of the advance. A glyph never
// passes into the next character, and the vector font ignores it.
@(test)
spleen_advance_of_a_scaled_draw :: proc(t: ^testing.T) {
	sync.mutex_lock(&fallback_test_lock)
	defer sync.mutex_unlock(&fallback_test_lock)
	text_choice_set(.Spleen, .Red_Green_Blue)
	defer text_choice_set(.Vector, .Red_Green_Blue)
	WIDTH :: 160
	HEIGHT :: 64
	LEFT :: 16
	pixels := new([WIDTH * HEIGHT]Color, context.temp_allocator)
	canvas := Canvas{pixels = raw_data(pixels[:]), width = WIDTH, height = HEIGHT, stride = WIDTH}
	body_on_screen := 20 * text_rendering.SUBPIXEL // The body at 1.25.
	// The columns with ink of "HH", from LEFT.
	ink_columns :: proc(pixels: []Color) -> (first, last: int) {
		first, last = -1, -1
		for column in 0 ..< WIDTH {
			for row in 0 ..< HEIGHT {
				if pixels[row * WIDTH + column] != 0 {
					if first < 0 {
						first = column
					}
					last = column
					break
				}
			}
		}
		return first, last
	}
	Case :: struct {
		size:    int,
		advance: int, // The advance that the draw gives.
		taken:   int, // The advance that the draw takes.
		glyph:   int, // The width of a glyph: 8 times its scale.
	}
	cases := [?]Case {
		{body_on_screen, 0, CELL_WIDTH, CELL_WIDTH},
		{body_on_screen, -10, CELL_WIDTH, CELL_WIDTH},
		{body_on_screen, 10, 10, CELL_WIDTH},
		// An advance of 16 at a size whose Spleen scale is 1: the glyph
		// keeps scale 1, in the middle of 16.
		{body_on_screen, 16, 16, CELL_WIDTH},
		// Twice the body: the scale 2 fits an advance of 16 and of 20.
		{32 * text_rendering.SUBPIXEL, 16, 16, 2 * CELL_WIDTH},
		{40 * text_rendering.SUBPIXEL, 20, 20, 2 * CELL_WIDTH},
		// A size of scale 2 with an advance of 12: the glyph of 16 would
		// pass into the next character, so it takes scale 1.
		{32 * text_rendering.SUBPIXEL, 12, 12, CELL_WIDTH},
	}
	for each in cases {
		for &pixel in pixels {
			pixel = 0
		}
		end := text_sized(canvas, LEFT, 4, "HH", 0xFFFFFF, each.size, false, OPAQUE, each.advance)
		testing.expectf(t, end == LEFT + 2 * each.taken, "%v: the draw ends at %d, not at %d", each, end, LEFT + 2 * each.taken)
		first, last := ink_columns(pixels[:])
		// Each H is in its own advance: the ink starts in the first one
		// and ends in the second one, and nothing passes the end.
		testing.expectf(t, first >= LEFT && first < LEFT + each.taken, "%v: the first ink at %d is not in the first advance", each, first)
		testing.expectf(t, last >= LEFT + each.taken && last < LEFT + 2 * each.taken, "%v: the last ink at %d is not in the second advance", each, last)
		// The glyph is in the middle of its advance: its box starts at
		// (advance - glyph) / 2, and H has ink in the columns of its box.
		testing.expectf(t, first >= LEFT + (each.taken - each.glyph) / 2 && last < LEFT + each.taken + (each.taken - each.glyph) / 2 + each.glyph, "%v: the ink %d..%d passes the boxes of the glyphs", each, first, last)
	}
}