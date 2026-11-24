#+build !freestanding
package grants_window

import "base:intrinsics"
import "core:testing"
import "modus:interface"
import box_layout "modus:layout"

@(export, link_name = "export_call")
host_export_call :: proc "c" (address: uintptr, integers, floats, results: rawptr) {intrinsics.trap()}

@(private = "file")
areas_overlap :: proc(a, b: interface.Area) -> bool {
	if a.width <= 0 || a.height <= 0 || b.width <= 0 || b.height <= 0 {
		return false
	}
	return a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
}

@(private = "file")
area_inside :: proc(inner: interface.Area, width, height: int) -> bool {
	return inner.width > 0 && inner.height > 0 &&
		inner.x >= 0 && inner.y >= 0 &&
		inner.x + inner.width <= width && inner.y + inner.height <= height
}

@(test)
grants_layout_refuses_out_of_bounds_and_avoids_overlap :: proc(t: ^testing.T) {
	tree := new(box_layout.Box_Tree)
	defer free(tree)

	dark_tokens, dark_ok := box_layout.tokens_for(.Dark, .Standard)
	light_tokens, light_ok := box_layout.tokens_for(.Light, .Standard)
	testing.expect(t, dark_ok && light_ok)

	// Refusal edges: nil tree, zero/negative, 1 px below minimums, above limit.
	_, nil_ok := grants_layout(nil, WIDTH, HEIGHT, dark_tokens)
	testing.expect(t, !nil_ok)
	for bad in ([?][2]int{{0, 0}, {-1, HEIGHT}, {WIDTH, -1}, {MINIMUM_WIDTH - 1, HEIGHT}, {WIDTH, MINIMUM_HEIGHT - 1}, {int(box_layout.LENGTH_LIMIT) + 1, HEIGHT}}) {
		_, bad_ok := grants_layout(tree, bad[0], bad[1], dark_tokens)
		testing.expectf(t, !bad_ok, "expected refusal for %dx%d", bad[0], bad[1])
	}

	// Valid sizes across both dark and light appearances.
	sizes := [?][2]int{{LEAST_WIDTH, LEAST_HEIGHT}, {WIDTH, HEIGHT}, {LARGEST_WIDTH, LARGEST_HEIGHT}}
	appearances := [?]box_layout.Element_Tokens{dark_tokens, light_tokens}
	for tokens in appearances {
		for dim in sizes {
			w, h := dim[0], dim[1]
			boxes, ok := grants_layout(tree, w, h, tokens)
			testing.expect(t, ok)
			testing.expect(t, area_inside(boxes.status_area, w, h))
			testing.expect(t, area_inside(boxes.refresh_button, w, h))
			testing.expect(t, area_inside(boxes.viewport, w, h))
			testing.expect(t, area_inside(boxes.scroll_bar, w, h))
			testing.expect(t, area_inside(boxes.action_bar, w, h))
			testing.expect(t, !areas_overlap(boxes.status_area, boxes.refresh_button))
			testing.expect(t, !areas_overlap(boxes.header, boxes.body_row))
			testing.expect(t, !areas_overlap(boxes.viewport, boxes.scroll_bar))
			testing.expect(t, !areas_overlap(boxes.body_row, boxes.action_bar))
			testing.expect_value(t, boxes.refresh_button.width, REFRESH_BUTTON_WIDTH)
			testing.expect_value(t, boxes.scroll_bar.width, interface.SCROLL_BAR_THICKNESS)
			testing.expect_value(t, boxes.action_bar.height, interface.ACTION_BAR_ROW_HEIGHT)
		}
	}
}
