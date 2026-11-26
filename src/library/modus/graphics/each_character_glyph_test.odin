#+build !freestanding
#+build !modus
package graphics

import "core:slice"
import "core:sync"
import "core:testing"
import "modus:text_rendering"
import "modus:vector_font"

// The font files, read here apart from the resource of the outlines that
// the drawing reads: the expected glyph of a character is the one that the
// table cmap of its own file gives.
@(private = "file")
b612_file := #load("../../../../resources/fonts/b612.ttf")
@(private = "file")
b612_bold_file := #load("../../../../resources/fonts/b612_bold.ttf")
@(private = "file")
paper_mono_file := #load("../../../../resources/fonts/paper_mono.ttf")
@(private = "file")
paper_mono_semibold_file := #load("../../../../resources/fonts/paper_mono_semibold.ttf")

@(private = "file")
Face_Font :: struct {
	face:  text_rendering.Face,
	font:  text_rendering.Outline_Font,
	bytes: []u8,
}

// The first printable character of ASCII after the space, and the last. The
// space has no ink: it is the one character whose glyph is empty.
@(private = "file")
PRINTABLE_FIRST :: 33
@(private = "file")
PRINTABLE_LAST :: 126

// Each printable character of ASCII takes, in the drawing, the glyph that
// the cmap of the font of its face gives, in that font and not in a font of
// the fallback; and its drawn glyph differs from the glyph of each other
// printable character, at the sizes of the scales 1 to 3 and at each
// position. A map of a character to the glyph of another one, as a "(" that
// draws as "[", fails here.
@(test)
each_printable_character_draws_its_own_glyph_in_each_face :: proc(t: ^testing.T) {
	sync.mutex_lock(&fallback_test_lock)
	defer sync.mutex_unlock(&fallback_test_lock)
	faces := [?]Face_Font {
		{.Interface, .B612, b612_file},
		{.Interface_Bold, .B612_Bold, b612_bold_file},
		{.Cells, .Paper_Mono, paper_mono_file},
		{.Cells_Bold, .Paper_Mono_Semibold, paper_mono_semibold_file},
	}
	for item in faces {
		glyphs := test_glyphs_of(t, item.face)
		defer test_glyphs_free(glyphs)
		for scale in 1 ..= TEST_SCALE_COUNT {
			for position in 0 ..< glyphs.position_count {
				for first in rune(PRINTABLE_FIRST) ..= PRINTABLE_LAST {
					for second in first + 1 ..= PRINTABLE_LAST {
						testing.expectf(t, !glyphs_equal(glyphs, first, second, scale, position), "%v at scale %d, position %d: %c and %c draw one glyph", item.face, scale, position, first, second)
					}
				}
			}
		}
	}
}

// The drawing takes the glyph of the cmap of the file of the face, in that
// font: the map of the drawing is the map of the file.
@(test)
the_drawing_maps_each_printable_character_as_its_font_file :: proc(t: ^testing.T) {
	sync.mutex_lock(&fallback_test_lock)
	defer sync.mutex_unlock(&fallback_test_lock)
	outline_words := fallback_open_for_test(t)
	defer delete(outline_words)
	defer text_rendering.state = {}
	faces := [?]Face_Font {
		{.Interface, .B612, b612_file},
		{.Interface_Bold, .B612_Bold, b612_bold_file},
		{.Cells, .Paper_Mono, paper_mono_file},
		{.Cells_Bold, .Paper_Mono_Semibold, paper_mono_semibold_file},
	}
	for item in faces {
		file, problem := vector_font.font_open(item.bytes)
		testing.expectf(t, problem == .None, "%v: the file does not open: %v", item.face, problem)
		for character in rune(PRINTABLE_FIRST) ..= PRINTABLE_LAST {
			font, index := text_rendering.font_glyph_of(item.face, character)
			expected, expected_problem := vector_font.glyph_of(&file, character)
			testing.expectf(t, expected_problem == .None && expected != 0, "%v %c: the file has no glyph", item.face, character)
			testing.expectf(t, font == item.font && index == expected, "%v %c: the drawing takes the glyph %d of %v, the file maps it to the glyph %d of %v", item.face, character, index, font, expected, item.font)
		}
	}
}

// glyphs_equal says if two characters draw the same glyph: the same box and
// the same words.
@(private = "file")
glyphs_equal :: proc(glyphs: ^Test_Glyphs, first, second: rune, scale, position: int) -> bool {
	first_entry, first_words, _ := test_glyph(glyphs, first, scale, position)
	second_entry, second_words, _ := test_glyph(glyphs, second, scale, position)
	if first_entry.width != second_entry.width || first_entry.row_count != second_entry.row_count {
		return false
	}
	count := int(first_entry.width) * int(first_entry.row_count)
	if count == 0 {
		return true
	}
	return slice.equal(first_words[:count], second_words[:count])
}

// With Spleen in force, each printable character of ASCII draws a picture
// of its own at each whole scale of Spleen: no two characters give the same
// pixels in their cell.
@(test)
each_printable_character_draws_its_own_glyph_in_spleen :: proc(t: ^testing.T) {
	sync.mutex_lock(&fallback_test_lock)
	defer sync.mutex_unlock(&fallback_test_lock)
	text_choice_set(.Spleen, .Red_Green_Blue)
	defer text_choice_set(.Vector, .Red_Green_Blue)
	WIDTH :: 64
	HEIGHT :: 96
	COUNT :: PRINTABLE_LAST - PRINTABLE_FIRST + 1
	for scale in 1 ..= 3 {
		size := scale * CELL_HEIGHT * text_rendering.SUBPIXEL
		if text_rendering.size_check(size) != .None {
			continue
		}
		pictures := make([][WIDTH * HEIGHT]Color, COUNT, context.temp_allocator)
		for character in PRINTABLE_FIRST ..= PRINTABLE_LAST {
			one := [1]u8{u8(character)}
			picture := &pictures[character - PRINTABLE_FIRST]
			canvas := Canvas{pixels = raw_data(picture[:]), width = WIDTH, height = HEIGHT, stride = WIDTH}
			text_sized(canvas, 0, 0, string(one[:]), 0xFFFFFF, size)
		}
		for first in 0 ..< COUNT {
			for second in first + 1 ..< COUNT {
				testing.expectf(t, pictures[first] != pictures[second], "Spleen at scale %d: %c and %c draw one picture", scale, rune(first + PRINTABLE_FIRST), rune(second + PRINTABLE_FIRST))
			}
		}
	}
}
