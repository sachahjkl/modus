#+build !freestanding
package interface

import "core:testing"
import "modus:contract/ring"
import "modus:contract/scale_factor"
import "modus:display"
import "modus:graphics"

// A press lands on the element that the screen shows there, at each scale.
// The compositor gives each pointer event in logical pixels; the frame of a
// window must draw its records at the scale of the surface. A frame that
// drew in the pixels of the surface, with no scale, put each element up and
// left of the place where the press reached it: the element under the press
// was another one.
//
// The element is in the corner far from the origin, where the two ways
// differ most. For each scale, the press is in the element, the element is
// under the pointer, and the pixel of the surface under the press has the
// color of the element. The same records drawn with no scale give the
// background there: the last check proves that the check can fail.
@(test)
window_frame_draws_each_element_where_a_press_reaches_it :: proc(t: ^testing.T) {
	LOGICAL_SIZE :: 80
	ELEMENT :: Area{56, 56, 20, 20}
	PRESS_X :: 70
	PRESS_Y :: 70
	ELEMENT_COLOR :: graphics.Color(0x30A050)
	BACKGROUND :: graphics.Color(0x101010)
	SURFACE_LIMIT :: (LOGICAL_SIZE * 16 + scale_factor.EIGHTHS_OF_ONE - 1) / scale_factor.EIGHTHS_OF_ONE
	pixels: [SURFACE_LIMIT * SURFACE_LIMIT]graphics.Color
	for scale in scale_factor.Scale {
		surface := int(scale_factor.screen_pixel_of_logical_pixel(LOGICAL_SIZE, scale))
		testing.expect(t, surface <= SURFACE_LIMIT)
		canvas := graphics.Canvas{pixels = raw_data(pixels[:]), width = surface, height = surface, stride = surface}
		counters: ring.Counters
		ring_records: [8]ring.Record
		window: display.Window
		window.ring.commands = {counters = &counters, records = raw_data(ring_records[:]), mask = 7}
		window.pictures = {canvas, canvas}
		window.canvas = canvas
		window.width, window.height = LOGICAL_SIZE, LOGICAL_SIZE
		window.rescale = {phase = .Steady, scale = scale, wanted = scale, serial = 1}
		memory: Window_Memory(16, 64)
		drawing := window_memory_drawing(&memory)
		testing.expect(t, input_add(&drawing.input, {kind = .Pointer, x = PRESS_X, y = PRESS_Y, buttons = display.BUTTON_LEFT}))

		frame := window_frame_begin_at(drawing, &window, nil, 0)
		testing.expectf(t, frame.table.scale == scale, "the frame at %v has the scale %v", scale, frame.table.scale)
		result := element_interact(&frame, identity("far corner"), ELEMENT, .Button)
		testing.expectf(t, result.under_pointer, "at %v the press at %d,%d is not on the element", scale, PRESS_X, PRESS_Y)
		draw_rectangle(frame.table, ELEMENT.x, ELEMENT.y, ELEMENT.width, ELEMENT.height, ELEMENT_COLOR)
		frame_end(&frame)

		pressed_x := int(scale_factor.screen_pixel_of_logical_pixel(PRESS_X, scale))
		pressed_y := int(scale_factor.screen_pixel_of_logical_pixel(PRESS_Y, scale))
		graphics.clear(canvas, BACKGROUND)
		execute(frame.table, canvas)
		testing.expectf(t, pixels[pressed_y * surface + pressed_x] == ELEMENT_COLOR, "at %v the pixel %d,%d under the press is %x, not the element", scale, pressed_x, pressed_y, pixels[pressed_y * surface + pressed_x])

		// The same records with no scale: at each scale but 1 the element is
		// elsewhere; at 1 a logical pixel is a pixel of the surface, and the
		// two draw the same.
		frame.table.scale = nil
		graphics.clear(canvas, BACKGROUND)
		execute(frame.table, canvas)
		unscaled := pixels[pressed_y * surface + pressed_x]
		if u64(scale) == scale_factor.EIGHTHS_OF_ONE {
			testing.expectf(t, unscaled == ELEMENT_COLOR, "at %v a frame with no scale misses the element", scale)
		} else {
			testing.expectf(t, unscaled == BACKGROUND, "at %v a frame with no scale still covers the pixel under the press: the check cannot fail", scale)
		}
	}
}
