// The scale factor of the desktop: the count of pixels of the screen for
// one logical pixel, in eighths, and the one rule that turns a place in
// logical pixels into a place on the screen
// (src/md/features/desktop_to_browser.md, "The reference screen").
//
// A process places and sizes what it draws in logical pixels. The drawing
// module turns each place into pixels of the screen with the procedures of
// this package, so that no process computes a screen pixel and each place
// rounds one way. The setting of the principal reaches a reader as a word;
// scale_of_word is the one border that turns that word into a Scale.
//
// See [scale factor](term:scale-factor) and
// [logical pixel](term:logical-pixel).
package scale_factor

import "modus:contract/draw_record"
import "modus:contract/enum_word"
import "modus:contract/reference_screen"

// The eighths of the scale 1: a logical pixel that is one pixel of the
// screen.
EIGHTHS_OF_ONE :: 8

// The scale factor, as its count of eighths. The values are the words of
// the settings page, so they are stated. A count of eighths keeps each
// multiple of 8 logical pixels, as each spacing token, on whole pixels of
// the screen; a scale in hundredths has no value.
Scale :: enum u8 {
	Eight_Eighths    = 8, // 1: the logical screen is the screen, 1920 x 1080.
	Nine_Eighths     = 9, // 1.125: 1707 x 960.
	Ten_Eighths      = 10, // 1.25: 1536 x 864.
	Eleven_Eighths   = 11, // 1.375: 1396 x 785.
	Twelve_Eighths   = 12, // 1.5: 1280 x 720.
	Thirteen_Eighths = 13, // 1.625: 1181 x 664.
	Fourteen_Eighths = 14, // 1.75: 1097 x 617.
	Fifteen_Eighths  = 15, // 1.875: 1024 x 576.
	Sixteen_Eighths  = 16, // 2: 960 x 540.
}

// The scale of a desktop that the principal did not set.
DEFAULT :: Scale.Ten_Eighths

// The largest scale. The budget of a window counts its pictures at it, so
// a window pays its surface at each scale that a principal sets: a budget
// is fixed at the start of its process, and no operation grows it
// (src/md/features/window_resize.md, "The rescale").
LARGEST :: Scale.Sixteen_Eighths

// The lines of the logical screen at LARGEST, rounded down as
// logical_screen rounds them: 540.
LARGEST_LOGICAL_HEIGHT :: i64(reference_screen.HEIGHT * EIGHTHS_OF_ONE) / i64(LARGEST)

// The least height of the work area, in logical pixels, that a holder of
// the display leaves its windows at each scale: the least height of the
// window of settings, 320 lines, with a title of at most 40 lines that the
// holder draws over it. So at each scale the principal reaches the bar and
// the one window that sets the scale back. A window taller than the work
// area keeps its title on the screen. The principal reaches the rest by a
// move, or by a resize when the window is resizable and its least height,
// with its title, fits the work area, as the window of settings does. A
// window that is not resizable shows only its upper part until windows
// scroll in the work area (ROADMAP.md, "A window that scrolls when it does
// not fit the work area"). A window never sets the range of the scale.
WORK_AREA_LEAST_HEIGHT :: 360

// The most lines of the logical screen that a holder of the display keeps
// for itself at LARGEST (a bar, a panel): the rest is the least work area.
// A holder states that its own part fits, with this constant.
HOLDER_LINES_MOST :: LARGEST_LOGICAL_HEIGHT - WORK_AREA_LEAST_HEIGHT

// What scale_of_word refused. The package holds no table of words for
// them: a table of texts holds addresses that a loader writes, and the
// drawing module, which compiles this package, must have none
// (docs/MODULE_CONTRACT.md, "A library as a module").
Scale_Problem :: enum {
	None,
	No_Member, // The word is no count of eighths from 8 to 16: 0 and 7 too.
}

// scale_of_word is the one border of a word of the scale: the Scale that it
// names, or a problem. A word that names no member is refused, never
// clamped and never read as the default: the caller keeps the scale that it
// had. The scale is the zero value with a problem, which names no member: a
// caller reads it only with None.
scale_of_word :: proc "contextless" (word: u64) -> (scale: Scale, problem: Scale_Problem) {
	member, ok := enum_word.member_of_word(Scale, word)
	if !ok {
		return {}, .No_Member
	}
	return member, .None
}

// The product of a place in units and a count of eighths that is one pixel
// of the screen: 8 eighths of 64 units.
@(private)
PRODUCT_OF_ONE_SCREEN_PIXEL :: EIGHTHS_OF_ONE * draw_record.UNITS_PER_PIXEL

// divide_down gives the quotient rounded toward minus infinity, for a
// divisor above 0: a place left of the corner of the surface is negative,
// and must round the way a place right of it does.
@(private)
divide_down :: proc "contextless" (dividend, divisor: i64) -> i64 {
	quotient := dividend / divisor
	if dividend % divisor != 0 && dividend < 0 {
		quotient -= 1
	}
	return quotient
}

// screen_edge gives the pixel of the screen of an edge at a place in units
// of a logical pixel: the place times the scale, rounded to the nearest
// pixel, a half up. Each edge of a box rounds on its own, so two boxes that
// share an edge share it on the screen, with no gap and no overlap; the
// size of a box is the difference of its two rounded edges. The rule grows
// with the place, so no box turns over. An i32 place times 16 fits an i64.
screen_edge :: proc "contextless" (place: i32, scale: Scale) -> i64 {
	return divide_down(i64(place) * i64(scale) + PRODUCT_OF_ONE_SCREEN_PIXEL / 2, PRODUCT_OF_ONE_SCREEN_PIXEL)
}

// screen_pixel_of_logical_pixel gives the pixel of the screen of an edge at
// a whole logical pixel: screen_edge of its place in units, with no product
// in units that could pass an i32.
screen_pixel_of_logical_pixel :: proc "contextless" (pixel: i32, scale: Scale) -> i64 {
	return divide_down(i64(pixel) * i64(scale) + EIGHTHS_OF_ONE / 2, EIGHTHS_OF_ONE)
}

// screen_place gives a place in units of a logical pixel in units of a
// pixel of the screen, rounded to the nearest unit, a half up: the place of
// a point of a path, of a point of a gradient and of the origin of a text,
// which keep their part of a pixel.
screen_place :: proc "contextless" (place: i32, scale: Scale) -> i64 {
	return divide_down(i64(place) * i64(scale) + EIGHTHS_OF_ONE / 2, EIGHTHS_OF_ONE)
}

// logical_pixel_of_screen_pixel gives the logical pixel whose box on the
// screen holds a pixel of the screen: the largest logical pixel whose left
// edge on the screen is at or before it. So each pixel of the screen
// belongs to exactly one logical pixel, also where the rounding makes a
// logical pixel one pixel wider than its neighbour.
logical_pixel_of_screen_pixel :: proc "contextless" (pixel: i32, scale: Scale) -> i64 {
	// The largest L with (L * eighths + 4) / 8 rounded down at or before
	// pixel: L * eighths < 8 * pixel + 4.
	return divide_down(i64(pixel) * EIGHTHS_OF_ONE + EIGHTHS_OF_ONE / 2 - 1, i64(scale))
}

// screen_text_size gives a text size in units of a logical pixel in units
// of a pixel of the screen, a half up: the size at which the glyphs are
// drawn. A size that is a whole count of logical pixels is a whole count of
// units of the screen, since one logical pixel is 8 units times the
// eighths.
screen_text_size :: proc "contextless" (size: u16, scale: Scale) -> int {
	return int(screen_place(i32(size), scale))
}

// A rectangle of the screen, in pixels: right and bottom are not in it.
Screen_Rectangle :: struct {
	left, top, right, bottom: i64,
}

// screen_box gives the box on the screen of a box in units of a logical
// pixel: each edge by screen_edge.
screen_box :: proc "contextless" (left, top, right, bottom: i32, scale: Scale) -> Screen_Rectangle {
	return {screen_edge(left, scale), screen_edge(top, scale), screen_edge(right, scale), screen_edge(bottom, scale)}
}

// screen_rectangle_of_logical_rectangle gives the rectangle of the screen
// of a rectangle in whole logical pixels, as a rectangle of damage: each
// edge by screen_pixel_of_logical_pixel, so it holds the box on the screen
// of each record inside it.
screen_rectangle_of_logical_rectangle :: proc "contextless" (left, top, right, bottom: i32, scale: Scale) -> Screen_Rectangle {
	return {screen_pixel_of_logical_pixel(left, scale), screen_pixel_of_logical_pixel(top, scale), screen_pixel_of_logical_pixel(right, scale), screen_pixel_of_logical_pixel(bottom, scale)}
}

// logical_screen gives the size of the reference screen in logical pixels
// at a scale: the most logical pixels whose box on the screen is inside it.
logical_screen :: proc "contextless" (scale: Scale) -> (width, height: i64) {
	return logical_pixel_of_screen_pixel(reference_screen.WIDTH, scale), logical_pixel_of_screen_pixel(reference_screen.HEIGHT, scale)
}
