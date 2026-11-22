// Per-view independent zoom in eighths (0.5x to 4.0x), composed in one exact
// rounding step with the desktop Scale factor so every view gets crisp vector
// and outline-font zoom with zero per-program zoom boilerplate
// (src/md/features/desktop_to_browser.md, "A. The desktop foundations").
package scale_factor

import "modus:contract/enum_word"

// Independent per-view zoom factor, in eighths of 1.0x (4 = 0.5x, 8 = 1.0x, 32 = 4.0x).
VIEW_ZOOM_MIN_EIGHTHS :: u8(4)
VIEW_ZOOM_DEFAULT_EIGHTHS :: u8(8)
VIEW_ZOOM_MAX_EIGHTHS :: u8(32)

// Combined denominator for desktop_scale (eighths) * view_zoom (eighths) = 64ths.
@(private)
SIXTY_FOURTHS_OF_ONE :: i64(EIGHTHS_OF_ONE * EIGHTHS_OF_ONE)

View_Zoom :: enum u8 {
	Half                = 4,  // 0.5x
	Five_Eighths        = 5,  // 0.625x
	Three_Quarters      = 6,  // 0.75x
	Seven_Eighths       = 7,  // 0.875x
	One                 = 8,  // 1.0x (default)
	Nine_Eighths        = 9,  // 1.125x
	Five_Quarters       = 10, // 1.25x
	Eleven_Eighths      = 11, // 1.375x
	Three_Halves        = 12, // 1.5x
	Thirteen_Eighths    = 13, // 1.625x
	Seven_Quarters      = 14, // 1.75x
	Fifteen_Eighths     = 15, // 1.875x
	Two                 = 16, // 2.0x
	Twenty_Eighths      = 20, // 2.5x
	Three               = 24, // 3.0x
	Twenty_Eight_Eighths = 28, // 3.5x
	Four                = 32, // 4.0x
}

VIEW_ZOOM_DEFAULT :: View_Zoom.One

// Ordered zoom stops for Ctrl++ / Ctrl+- / Ctrl+wheel stepping.
@(private, rodata)
VIEW_ZOOM_STOPS := [?]View_Zoom{
	.Half,
	.Five_Eighths,
	.Three_Quarters,
	.Seven_Eighths,
	.One,
	.Nine_Eighths,
	.Five_Quarters,
	.Eleven_Eighths,
	.Three_Halves,
	.Thirteen_Eighths,
	.Seven_Quarters,
	.Fifteen_Eighths,
	.Two,
	.Twenty_Eighths,
	.Three,
	.Twenty_Eight_Eighths,
	.Four,
}

view_zoom_of_word :: proc "contextless" (word: u64) -> (zoom: View_Zoom, ok: bool) {
	return enum_word.member_of_word(View_Zoom, word)
}

// view_zoom_step moves zoom by delta_steps stops (positive zooms in, negative
// zooms out), clamped cleanly to [.Half, .Four].
view_zoom_step :: proc "contextless" (zoom: View_Zoom, delta_steps: int) -> View_Zoom {
	idx := 4 // .One
	for stop, i in VIEW_ZOOM_STOPS {
		if stop == zoom {
			idx = i
			break
		}
	}
	next := clamp(idx + delta_steps, 0, len(VIEW_ZOOM_STOPS) - 1)
	return VIEW_ZOOM_STOPS[next]
}

// view_effective_sixty_fourths returns the exact combined scale numerator
// (desktop_scale * view_zoom) over 64.
view_effective_sixty_fourths :: proc "contextless" (desktop_scale: Scale, zoom: View_Zoom) -> i64 {
	return i64(desktop_scale) * i64(zoom)
}

// view_screen_pixel converts a view-local logical coordinate into a screen
// pixel in one exact rounding step (zero double-rounding gaps between adjacent boxes).
view_screen_pixel :: proc "contextless" (view_pixel: i32, desktop_scale: Scale, zoom: View_Zoom) -> i64 {
	num := i64(view_pixel) * view_effective_sixty_fourths(desktop_scale, zoom)
	return divide_down(num + SIXTY_FOURTHS_OF_ONE / 2, SIXTY_FOURTHS_OF_ONE)
}

// view_logical_pixel maps a screen pixel back to its owning view-local logical
// pixel (the exact inverse of view_screen_pixel for pointer hit-testing inside
// independently zoomed views).
view_logical_pixel :: proc "contextless" (screen_pixel: i32, desktop_scale: Scale, zoom: View_Zoom) -> i64 {
	eff := view_effective_sixty_fourths(desktop_scale, zoom)
	// Largest v such that floor((v * eff + 32) / 64) <= screen_pixel.
	return divide_down(i64(screen_pixel) * SIXTY_FOURTHS_OF_ONE + SIXTY_FOURTHS_OF_ONE - 1 - SIXTY_FOURTHS_OF_ONE / 2, eff)
}
