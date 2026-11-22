// Built-in per-view independent zoom for modus:interface
// (src/md/features/desktop_to_browser.md, "A. The desktop foundations").
//
// Every view that calls frame_begin gets independent Ctrl++/Ctrl+-/Ctrl+0 zoom
// (0.5x to 4.0x in eighths) composed in one exact rounding step with the
// desktop scale factor, with zero per-program zoom code.
package interface

import "modus:contract/scale_factor"
import "modus:display"

// view_zoom_current returns the active per-view zoom of state (.One when unset).
view_zoom_current :: proc "contextless" (state: ^Interface_State) -> scale_factor.View_Zoom {
	if state == nil || state.view_zoom == scale_factor.View_Zoom(0) {
		return scale_factor.VIEW_ZOOM_DEFAULT
	}
	return state.view_zoom
}

// view_zoom_step_state adjusts a view's zoom by delta_steps stops.
view_zoom_step_state :: proc "contextless" (state: ^Interface_State, delta_steps: int) -> scale_factor.View_Zoom {
	if state == nil {
		return scale_factor.VIEW_ZOOM_DEFAULT
	}
	next := scale_factor.view_zoom_step(view_zoom_current(state), delta_steps)
	state.view_zoom = next
	return next
}

// view_zoom_reset_state resets a view's zoom to 1.0x (.One).
view_zoom_reset_state :: proc "contextless" (state: ^Interface_State) {
	if state == nil {
		return
	}
	state.view_zoom = scale_factor.VIEW_ZOOM_DEFAULT
}

// view_zoom_apply_keys consumes Ctrl++ / Ctrl+= (zoom in), Ctrl+- (zoom out),
// and Ctrl+0 (reset zoom) on input and updates state.view_zoom in place.
view_zoom_apply_keys :: proc "contextless" (state: ^Interface_State, input: ^Input) {
	if state == nil || input == nil {
		return
	}
	for &key in input.keys[:input.key_count] {
		if key.taken || (key.modifiers & display.MODIFIER_CONTROL) == 0 {
			continue
		}
		switch key.character {
		case '+', '=':
			view_zoom_step_state(state, 1)
			key.taken = true
		case '-', '_':
			view_zoom_step_state(state, -1)
			key.taken = true
		case '0':
			view_zoom_reset_state(state)
			key.taken = true
		}
	}
}

// view_zoom_pixel maps a view-local logical coordinate to a screen pixel
// combining desktop_scale and state.view_zoom in a single rounding step.
view_zoom_pixel :: proc "contextless" (state: ^Interface_State, desktop_scale: scale_factor.Scale, view_px: i32) -> i64 {
	return scale_factor.view_screen_pixel(view_px, desktop_scale, view_zoom_current(state))
}

// view_zoom_unscale_pixel maps a screen pixel back to its owning view-local
// logical pixel for pointer hit-testing inside a zoomed view.
view_zoom_unscale_pixel :: proc "contextless" (state: ^Interface_State, desktop_scale: scale_factor.Scale, screen_px: i32) -> i64 {
	return scale_factor.view_logical_pixel(screen_px, desktop_scale, view_zoom_current(state))
}
