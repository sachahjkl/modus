package bootscreen

import "modus:graphics"

// The scale of the boot display (src/md/features/boot_display_scale.md):
// one scale in eighths from the size of the screen, snapped to the sizes
// of Spleen, and the one rounding of a logical place into a screen place.
// A cell of the text is 8 logical pixels, so at a scale of s eighths it is
// s screen pixels: each scale of the list is the width of a size of
// Spleen, and its text fills its cells exactly.

SCALE_ONE :: 8 // Eighths: scale 1, Spleen 8x16, the look of the base size.
SCREEN_MARGIN :: 8 // Screen pixels that stay free on each side of a panel above scale 1.
#assert(SCALE_ONE == 1 << 3) // scaled divides by a shift.
#assert(SCALE_ONE == graphics.CELL_WIDTH) // Scale 1 is Spleen 8x16.

// The scales above 1, from the largest: 4 (32x64), 2 (16x32), 1.5 (12x24).
DISPLAY_SCALES :: [3]int{SPLEEN_32X64_WIDTH, SPLEEN_16X32_WIDTH, SPLEEN_12X24_WIDTH}

// Where the panel goes on a screen, and its scale.
Display_Place :: struct {
	eighths: int, // The scale: SCALE_ONE or a member of DISPLAY_SCALES.
	x, y:    int, // The top left of the panel on the screen.
	width:   int, // The panel in screen pixels: WIDTH at the scale.
	height:  int, // HEIGHT at the scale.
}

// scaled gives the screen place of a logical place at a scale: the nearest
// pixel, a half up, for a place of any sign. A size is the difference of
// its two rounded edges, so two neighbours share their edge on the screen.
scaled :: #force_inline proc "contextless" (logical, eighths: int) -> int {
	return (logical * eighths + SCALE_ONE / 2) >> 3
}

// display_place gives the place of the panel on a screen: the largest
// scale of DISPLAY_SCALES whose panel and margins fit the width and the
// height, in the middle; else scale 1, in the middle when the screen holds
// the base size, else at the top left, where the screen cuts it. ok is
// false for a width or a height of 0 or below: that is no screen.
display_place :: proc "contextless" (screen_width, screen_height: int) -> (place: Display_Place, ok: bool) {
	if screen_width <= 0 || screen_height <= 0 {
		return {}, false
	}
	scales := DISPLAY_SCALES
	for eighths in scales {
		width, height := scaled(WIDTH, eighths), scaled(HEIGHT, eighths)
		// Compared as rooms, so the largest width of the type does not wrap.
		if width <= screen_width - 2 * SCREEN_MARGIN && height <= screen_height - 2 * SCREEN_MARGIN {
			return {eighths = eighths, x = (screen_width - width) / 2, y = (screen_height - height) / 2, width = width, height = height}, true
		}
	}
	return {eighths = SCALE_ONE, x = max((screen_width - WIDTH) / 2, 0), y = max((screen_height - HEIGHT) / 2, 0), width = WIDTH, height = HEIGHT}, true
}
