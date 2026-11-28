// Scoped styling and theme stack for modus:interface widgets
// (src/md/features/rich_widgets.md).
//
// Every widget resolves its surface, border, text, accent, intent, and spacing
// tokens from theme_current(frame). When no custom theme is pushed on the
// frame, widget_theme_default() derives every role directly from the active
// graphics.colors table (dark, light, and forced high-contrast modes).
package interface

import "modus:graphics"

// Plan value: nested themed subtrees in one frame (window -> card -> panel -> modal -> popup).
THEME_STACK_CAPACITY :: 8

// Complete set of color and geometry tokens read by widgets in modus:interface.
Widget_Theme :: struct {
	// Surfaces.
	background:     graphics.Color,
	card_top:       graphics.Color,
	card_bottom:    graphics.Color,
	recess:         graphics.Color,
	track:          graphics.Color,
	chosen:         graphics.Color,
	hover:          graphics.Color,
	pressed:        graphics.Color,
	// Borders and dividers.
	border:         graphics.Color,
	border_strong:  graphics.Color,
	divider:        graphics.Color,
	focus_ring:     graphics.Color,
	// Text roles.
	text:           graphics.Color,
	text_strong:    graphics.Color,
	text_dim:       graphics.Color,
	text_on_chosen: graphics.Color,
	// Semantic intents.
	accent:         graphics.Color,
	ok:             graphics.Color,
	warning:        graphics.Color,
	danger:         graphics.Color,
	// Spacing and control geometry in logical pixels.
	padding_x:      int,
	padding_y:      int,
	gap:            int,
	row_height:     int,
}

// widget_theme_default builds the default widget theme from the active
// graphics.colors palette (respecting dark, light, and high-contrast modes).
widget_theme_default :: proc "contextless" () -> Widget_Theme {
	c := graphics.colors
	return {
		background     = c.background,
		card_top       = c.card_top,
		card_bottom    = c.card_bottom,
		recess         = c.recess,
		track          = c.track,
		chosen         = c.chosen,
		hover          = graphics.shade(c.title, 62),
		pressed        = graphics.shade(c.chosen, 82),
		border         = c.not_usable,
		border_strong  = c.dim,
		divider        = c.point,
		focus_ring     = c.text_strong,
		text           = c.text,
		text_strong    = c.text_strong,
		text_dim       = c.dim,
		text_on_chosen = graphics.COLOR_WHITE,
		accent         = c.title,
		ok             = c.process,
		warning        = c.warning,
		danger         = c.stop_process,
		padding_x      = 10,
		padding_y      = 4,
		gap            = graphics.GAP,
		row_height     = 26,
	}
}

// widget_theme_with_accent derives a cohesive theme from widget_theme_default()
// with a custom accent/chosen tint for a window, card, or control group.
widget_theme_with_accent :: proc "contextless" (accent: graphics.Color) -> Widget_Theme {
	t := widget_theme_default()
	t.accent = accent
	t.chosen = graphics.shade(accent, 84)
	t.hover = graphics.shade(accent, 64)
	t.pressed = graphics.shade(accent, 72)
	t.border_strong = graphics.shade(accent, 90)
	return t
}

// theme_push makes theme the active Widget_Theme for subsequent widgets on
// frame. Returns false without modifying the stack if frame is nil or full.
theme_push :: proc "contextless" (frame: ^Frame, theme: Widget_Theme) -> bool {
	if frame == nil || frame.theme_depth < 0 || frame.theme_depth >= THEME_STACK_CAPACITY {
		return false
	}
	frame.theme_stack[frame.theme_depth] = theme
	frame.theme_depth += 1
	return true
}

// theme_pop restores the Widget_Theme active before the last theme_push.
// Returns false if frame is nil or the stack is empty.
theme_pop :: proc "contextless" (frame: ^Frame) -> bool {
	if frame == nil || frame.theme_depth <= 0 || frame.theme_depth > THEME_STACK_CAPACITY {
		return false
	}
	frame.theme_depth -= 1
	return true
}

// theme_current returns the active Widget_Theme on frame, or
// widget_theme_default() when no custom theme is pushed.
theme_current :: proc "contextless" (frame: ^Frame) -> Widget_Theme {
	if frame == nil || frame.theme_depth <= 0 || frame.theme_depth > THEME_STACK_CAPACITY {
		return widget_theme_default()
	}
	return frame.theme_stack[frame.theme_depth - 1]
}
