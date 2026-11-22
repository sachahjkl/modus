#+build !freestanding
package interface

import "core:testing"
import "modus:contract/scale_factor"
import "modus:display"

@(test)
interface_frame_handles_independent_per_view_zoom_shortcuts :: proc(t: ^testing.T) {
	records: [16]Draw_Record
	text: [128]u8
	table := Draw_Table{records = records[:], text = text[:]}
	state_a: Interface_State
	state_b: Interface_State
	input: Input

	testing.expect_value(t, view_zoom_current(&state_a), scale_factor.View_Zoom.One)
	testing.expect_value(t, view_zoom_current(&state_b), scale_factor.View_Zoom.One)

	input.keys[0] = {character = '+', modifiers = display.MODIFIER_CONTROL}
	input.key_count = 1
	_ = frame_begin(&table, &state_a, &input)
	testing.expect(t, input.keys[0].taken)
	testing.expect_value(t, view_zoom_current(&state_a), scale_factor.View_Zoom.Nine_Eighths)
	testing.expect_value(t, view_zoom_current(&state_b), scale_factor.View_Zoom.One)

	input_clear(&input)
	input.keys[0] = {character = '0', modifiers = display.MODIFIER_CONTROL}
	input.key_count = 1
	_ = frame_begin(&table, &state_a, &input)
	testing.expect(t, input.keys[0].taken)
	testing.expect_value(t, view_zoom_current(&state_a), scale_factor.View_Zoom.One)

	input_clear(&input)
	input.keys[0] = {character = '+', modifiers = 0}
	input.key_count = 1
	_ = frame_begin(&table, &state_a, &input)
	testing.expect(t, !input.keys[0].taken)
	testing.expect_value(t, view_zoom_current(&state_a), scale_factor.View_Zoom.One)

	view_zoom_step_state(&state_a, 8) // 2.0x (.Two)
	testing.expect_value(t, view_zoom_current(&state_a), scale_factor.View_Zoom.Two)
	testing.expect_value(t, view_zoom_pixel(&state_a, .Ten_Eighths, 8), i64(20))
	testing.expect_value(t, view_zoom_unscale_pixel(&state_a, .Ten_Eighths, 20), i64(8))
}
