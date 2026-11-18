package bootscreen

// The scale of the boot display (src/md/features/boot_display_scale.md):
// one scale in eighths from the size of the screen, and the one rounding
// of a logical place into a screen place.

SCALE_ONE :: 8 // Eighths: scale 1, the look of the base size.
SCALE_LEAST :: 10 // The least scale of the range of the scale factor: 1.25.
SCALE_MOST :: 16 // The largest: 2.
SCREEN_MARGIN :: 8 // Screen pixels that stay free on each side of a panel above scale 1.
#assert(SCALE_ONE == 1 << 3) // scaled divides by a shift.

// Where the panel goes on a screen, and its scale.
Display_Place :: struct {
	eighths: int, // The scale: SCALE_ONE, or SCALE_LEAST to SCALE_MOST.
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
// scale of the range whose panel and margins fit the width and the height,
// in the middle; else scale 1, in the middle when the screen holds the
// base size, else at the top left, where the screen cuts it. ok is false
// for a width or a height of 0 or below: that is no screen.
display_place :: proc "contextless" (screen_width, screen_height: int) -> (place: Display_Place, ok: bool) {
	if screen_width <= 0 || screen_height <= 0 {
		return {}, false
	}
	for eighths := SCALE_MOST; eighths >= SCALE_LEAST; eighths -= 1 {
		width, height := scaled(WIDTH, eighths), scaled(HEIGHT, eighths)
		// Compared as rooms, so the largest width of the type does not wrap.
		if width <= screen_width - 2 * SCREEN_MARGIN && height <= screen_height - 2 * SCREEN_MARGIN {
			return {eighths = eighths, x = (screen_width - width) / 2, y = (screen_height - height) / 2, width = width, height = height}, true
		}
	}
	return {eighths = SCALE_ONE, x = max((screen_width - WIDTH) / 2, 0), y = max((screen_height - HEIGHT) / 2, 0), width = WIDTH, height = HEIGHT}, true
}
