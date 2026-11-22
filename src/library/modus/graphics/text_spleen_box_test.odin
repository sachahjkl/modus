#+build !freestanding
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