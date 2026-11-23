#+build !freestanding
package scale_factor

import "core:testing"
import "modus:contract/draw_record"
import "modus:contract/reference_screen"

// The border refuses each word that names no count of the range: 0, 1, 7
// (one under the scale 1), 17 (one past the largest member), 255, a word
// whose low byte names a member, and the largest words. The scale that it
// gives with a problem names no member, so a caller that keeps it by
// mistake cannot draw at a scale that it did not get.
@(test)
the_border_refuses_a_word_that_names_no_count_of_the_range :: proc(t: ^testing.T) {
	refused := [?]u64{0, 1, EIGHTHS_OF_ONE - 1, u64(Scale.Sixteen_Eighths) + 1, u64(max(u8)), 256 + u64(Scale.Ten_Eighths), 256 + EIGHTHS_OF_ONE, u64(max(u32)), max(u64)}
	for word in refused {
		scale, problem := scale_of_word(word)
		testing.expectf(t, problem == .No_Member, "the word %d gave %v", word, problem)
		testing.expectf(t, u8(scale) == 0, "the word %d gave the scale %d with its refusal", word, u8(scale))
	}
}

// The success case last: each count from 8, the scale 1, to 16, the scale
// 2, is its member; the range has no hole; the default and the largest
// scale are members.
@(test)
the_border_takes_each_scale_from_one_to_two :: proc(t: ^testing.T) {
	testing.expect_value(t, u64(min(Scale)), u64(EIGHTHS_OF_ONE))
	testing.expect_value(t, u64(max(Scale)), u64(2 * EIGHTHS_OF_ONE))
	testing.expect_value(t, len(Scale), EIGHTHS_OF_ONE + 1)
	for word in u64(EIGHTHS_OF_ONE) ..= u64(2 * EIGHTHS_OF_ONE) {
		scale, problem := scale_of_word(word)
		testing.expect_value(t, problem, Scale_Problem.None)
		testing.expect_value(t, u64(scale), word)
	}
	for scale in ([?]Scale{DEFAULT, LARGEST}) {
		_, problem := scale_of_word(u64(scale))
		testing.expect_value(t, problem, Scale_Problem.None)
	}
	testing.expect_value(t, LARGEST, max(Scale))
}

// Each edge rounds to the nearest pixel, a half up, also left of the
// corner: a place of -0.5 screen pixel rounds up to 0, one of -0.5 minus a
// unit rounds to -1. The places are chosen so that the product is exactly
// a half, the edge that a wrong rounding breaks.
@(test)
an_edge_rounds_to_the_nearest_pixel_a_half_up :: proc(t: ^testing.T) {
	UNITS :: draw_record.UNITS_PER_PIXEL
	// At 1.25, 2 logical pixels are 2.5 pixels of the screen: a half, up.
	testing.expect_value(t, screen_edge(2 * UNITS, .Ten_Eighths), 3)
	testing.expect_value(t, screen_edge(-2 * UNITS, .Ten_Eighths), -2)
	// 1 logical pixel is 1.25: down. -1 is -1.25: -1.
	testing.expect_value(t, screen_edge(UNITS, .Ten_Eighths), 1)
	testing.expect_value(t, screen_edge(-UNITS, .Ten_Eighths), -1)
	// 3 logical pixels are 3.75: up. -3 are -3.75: -4.
	testing.expect_value(t, screen_edge(3 * UNITS, .Ten_Eighths), 4)
	testing.expect_value(t, screen_edge(-3 * UNITS, .Ten_Eighths), -4)
	// 0 and one unit: a unit is 1/64 logical pixel, 0.0195 at 1.25.
	testing.expect_value(t, screen_edge(0, .Ten_Eighths), 0)
	testing.expect_value(t, screen_edge(1, .Ten_Eighths), 0)
	testing.expect_value(t, screen_edge(-1, .Ten_Eighths), 0)
	// The place one unit under a half and the place of the half.
	half_at_two := i32(UNITS * 2) // 2.5 screen pixels at 1.25.
	testing.expect_value(t, screen_edge(half_at_two - 1, .Ten_Eighths), 2)
	// A multiple of 8 logical pixels needs no rounding at any scale.
	for scale in Scale {
		for eighths in i32(-4) ..= 4 {
			place := eighths * 8 * UNITS
			testing.expectf(t, screen_edge(place, scale) == i64(eighths) * i64(scale), "8 x %d logical pixels at %d eighths", eighths, u8(scale))
		}
	}
}

// The largest and the smallest place of the type: no product wraps, and
// the edge is the exact quotient.
@(test)
the_largest_places_of_the_type_do_not_wrap :: proc(t: ^testing.T) {
	for scale in Scale {
		largest := screen_edge(max(i32), scale)
		smallest := screen_edge(min(i32), scale)
		expected_largest := (i64(max(i32)) * i64(scale) + 256) / 512
		testing.expectf(t, largest == expected_largest, "the largest place at %d eighths: %d, not %d", u8(scale), largest, expected_largest)
		testing.expectf(t, smallest < 0 && smallest >= -(i64(1) << 31) * i64(scale) / 512 - 1, "the smallest place at %d eighths: %d", u8(scale), smallest)
		testing.expect(t, screen_place(max(i32), scale) > 0 && screen_place(min(i32), scale) < 0)
		testing.expect(t, screen_pixel_of_logical_pixel(max(i32), scale) > 0 && screen_pixel_of_logical_pixel(min(i32), scale) < 0)
		testing.expect(t, logical_pixel_of_screen_pixel(max(i32), scale) > 0 && logical_pixel_of_screen_pixel(min(i32), scale) < 0)
	}
}

// Two boxes that share an edge in logical pixels share it on the screen,
// whatever the place of that edge: the right of the first is the left of
// the second, so no pixel is in both and no pixel between them is in none.
// A row of boxes of any widths then covers the screen from its first edge
// to its last one, each pixel once.
@(test)
shared_edges_never_gap_or_overlap :: proc(t: ^testing.T) {
	for scale in Scale {
		// Boxes of 1 to 37 units, then of 1 to 9 whole pixels, from -500
		// logical pixels, so the negative places are tried too.
		place := i32(-500 * draw_record.UNITS_PER_PIXEL)
		covered_until := screen_edge(place, scale)
		for width in i32(1) ..= 37 {
			right := place + width
			left_edge, right_edge := screen_edge(place, scale), screen_edge(right, scale)
			testing.expectf(t, left_edge == covered_until, "a gap or an overlap at the place %d, %d eighths", place, u8(scale))
			testing.expectf(t, right_edge >= left_edge, "a box turned over at the place %d, %d eighths", place, u8(scale))
			covered_until = right_edge
			place = right
		}
		for pixels in i32(1) ..= 9 {
			right := place + pixels * draw_record.UNITS_PER_PIXEL
			box := screen_box(place, 0, right, pixels * draw_record.UNITS_PER_PIXEL, scale)
			testing.expectf(t, box.left == covered_until, "a gap or an overlap at the place %d, %d eighths", place, u8(scale))
			covered_until = box.right
			place = right
		}
	}
}

// A line of 1 logical pixel keeps at least 1 pixel of the screen at each
// place and each scale, and at most 2 at the scale 2.
@(test)
a_line_of_one_logical_pixel_keeps_one_screen_pixel :: proc(t: ^testing.T) {
	for scale in Scale {
		for pixel in i32(-1000) ..= 1000 {
			width := screen_pixel_of_logical_pixel(pixel + 1, scale) - screen_pixel_of_logical_pixel(pixel, scale)
			testing.expectf(t, width >= 1 && width <= 2, "the logical pixel %d at %d eighths is %d pixels", pixel, u8(scale), width)
			units_width := screen_edge((pixel + 1) * draw_record.UNITS_PER_PIXEL, scale) - screen_edge(pixel * draw_record.UNITS_PER_PIXEL, scale)
			testing.expectf(t, units_width == width, "the edge in units and in pixels differ at %d, %d eighths", pixel, u8(scale))
		}
	}
}

// Each pixel of the screen belongs to exactly one logical pixel: the one
// whose box on the screen holds it. Negative pixels too, and the pixels
// of the edges of the reference screen.
@(test)
each_screen_pixel_belongs_to_one_logical_pixel :: proc(t: ^testing.T) {
	for scale in Scale {
		for pixel in i32(-2000) ..= i32(reference_screen.WIDTH) + 40 {
			logical := logical_pixel_of_screen_pixel(pixel, scale)
			left := screen_pixel_of_logical_pixel(i32(logical), scale)
			right := screen_pixel_of_logical_pixel(i32(logical) + 1, scale)
			testing.expectf(t, left <= i64(pixel) && i64(pixel) < right, "the screen pixel %d at %d eighths gave the logical pixel %d, whose box is %d to %d", pixel, u8(scale), logical, left, right)
		}
	}
}

// A place keeps its part of a pixel: the origin of a text on a third of a
// logical pixel lands within half a unit of its exact place.
@(test)
a_place_rounds_to_the_nearest_unit :: proc(t: ^testing.T) {
	testing.expect_value(t, screen_place(0, .Ten_Eighths), 0)
	// 1 unit at 1.25 is 1.25 units: 1. 2 units are 2.5: 3. -2 are -2.5: -2.
	testing.expect_value(t, screen_place(1, .Ten_Eighths), 1)
	testing.expect_value(t, screen_place(2, .Ten_Eighths), 3)
	testing.expect_value(t, screen_place(-2, .Ten_Eighths), -2)
	testing.expect_value(t, screen_place(-3, .Ten_Eighths), -4)
	for scale in Scale {
		for place in i32(-3000) ..= 3000 {
			exact := i64(place) * i64(scale)
			error := screen_place(place, scale) * EIGHTHS_OF_ONE - exact
			testing.expectf(t, error > -EIGHTHS_OF_ONE / 2 && error <= EIGHTHS_OF_ONE / 2, "the place %d at %d eighths is %d eighths of a unit off", place, u8(scale), error)
		}
	}
}

// The text sizes of the tokens at each scale: the body of 16 is 20 at 1.25
// and 22 at 1.375; the caption of 14 is 17.5 at 1.25, a size between two
// pixels that the glyphs draw at.
@(test)
the_text_sizes_at_a_scale :: proc(t: ^testing.T) {
	UNITS :: draw_record.UNITS_PER_PIXEL
	testing.expect_value(t, screen_text_size(16 * UNITS, .Ten_Eighths), 20 * UNITS)
	testing.expect_value(t, screen_text_size(16 * UNITS, .Eleven_Eighths), 22 * UNITS)
	testing.expect_value(t, screen_text_size(14 * UNITS, .Ten_Eighths), 17 * UNITS + UNITS / 2)
	testing.expect_value(t, screen_text_size(16 * UNITS, .Sixteen_Eighths), 32 * UNITS)
	testing.expect_value(t, screen_text_size(max(u16), .Sixteen_Eighths), 2 * int(max(u16)))
	testing.expect_value(t, screen_text_size(0, .Ten_Eighths), 0)
}

// The logical screen of each scale: the reference screen in logical
// pixels, whose last logical pixel ends at the edge of the screen or
// before it, and whose next one would pass it.
@(test)
the_logical_screen_of_each_scale :: proc(t: ^testing.T) {
	width, height := logical_screen(.Ten_Eighths)
	testing.expect_value(t, width, 1536)
	testing.expect_value(t, height, 864)
	width, height = logical_screen(.Eleven_Eighths)
	testing.expect_value(t, width, 1396)
	testing.expect_value(t, height, 785)
	width, height = logical_screen(.Twelve_Eighths)
	testing.expect_value(t, width, 1280)
	testing.expect_value(t, height, 720)
	width, height = logical_screen(.Sixteen_Eighths)
	testing.expect_value(t, width, 960)
	testing.expect_value(t, height, 540)
	for scale in Scale {
		logical_width, logical_height := logical_screen(scale)
		testing.expect(t, screen_pixel_of_logical_pixel(i32(logical_width), scale) <= reference_screen.WIDTH)
		testing.expect(t, screen_pixel_of_logical_pixel(i32(logical_width) + 1, scale) > reference_screen.WIDTH)
		testing.expect(t, screen_pixel_of_logical_pixel(i32(logical_height), scale) <= reference_screen.HEIGHT)
		testing.expect(t, screen_pixel_of_logical_pixel(i32(logical_height) + 1, scale) > reference_screen.HEIGHT)
	}
}

// The least work area fits the logical screen of each scale, the largest
// one too, so the bar and the window that sets the scale back are on the
// screen at each scale. No part of one holder is counted: a holder with no
// bar and a holder that keeps HOLDER_LINES_MOST both give the least work
// area at the largest scale, and a holder that keeps one line more does not.
@(test)
the_least_work_area_fits_each_scale :: proc(t: ^testing.T) {
	SETTINGS_LEAST_HEIGHT :: 320
	TITLE :: 40
	testing.expect_value(t, WORK_AREA_LEAST_HEIGHT, SETTINGS_LEAST_HEIGHT + TITLE)
	for scale in Scale {
		_, height := logical_screen(scale)
		testing.expectf(t, height >= WORK_AREA_LEAST_HEIGHT, "the scale %d eighths: the least work area does not fit %d lines", u8(scale), height)
	}
	_, largest_height := logical_screen(LARGEST)
	testing.expect_value(t, largest_height, LARGEST_LOGICAL_HEIGHT)
	testing.expect(t, HOLDER_LINES_MOST >= 0)
	for holder_lines in ([3]i64{0, HOLDER_LINES_MOST, HOLDER_LINES_MOST + 1}) {
		work_height := largest_height - holder_lines
		testing.expectf(t, (work_height >= WORK_AREA_LEAST_HEIGHT) == (holder_lines <= HOLDER_LINES_MOST), "a holder that keeps %d lines", holder_lines)
	}
}

// A rectangle of damage on the screen holds the box on the screen of each
// record inside it, also a record whose edges are not on whole pixels.
@(test)
a_rectangle_of_damage_holds_the_boxes_inside_it :: proc(t: ^testing.T) {
	UNITS :: draw_record.UNITS_PER_PIXEL
	for scale in Scale {
		damage := screen_rectangle_of_logical_rectangle(-7, 3, 41, 29, scale)
		for left in i32(-7 * UNITS) ..< -5 * UNITS {
			box := screen_box(left, 3 * UNITS + 17, 41 * UNITS - 1, 29 * UNITS, scale)
			testing.expectf(t, box.left >= damage.left && box.top >= damage.top && box.right <= damage.right && box.bottom <= damage.bottom, "a box of the place %d passed its damage at %d eighths", left, u8(scale))
		}
	}
}
