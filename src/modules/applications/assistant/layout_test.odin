#+build !freestanding
package assistant_window

import "base:intrinsics"
import "core:testing"
import "modus:interface"
import box_layout "modus:layout"

// The test runs on the host: the module links src/library/modus/system,
// whose call of an export is an entry of the machine that the host does
// not have. No test here calls an export; a call stops the test.
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
assistant_layout_refuses_out_of_bounds_and_avoids_overlap :: proc(t: ^testing.T) {
	tree := new(box_layout.Box_Tree)
	defer free(tree)

	dark_tokens, dark_ok := box_layout.tokens_for(.Dark, .Standard)
	light_tokens, light_ok := box_layout.tokens_for(.Light, .Standard)
	testing.expect(t, dark_ok && light_ok)

	// Refusal edges: nil tree, zero/negative sizes, 1 pixel below minimums.
	_, ok := assistant_layout(nil, WIDTH, HEIGHT, false, dark_tokens)
	testing.expect(t, !ok)
	for bad in ([?][2]int{{0, 0}, {-1, HEIGHT}, {WIDTH, -1}, {MINIMUM_WIDTH - 1, HEIGHT}, {WIDTH, MINIMUM_HEIGHT - 1}}) {
		_, bad_ok := assistant_layout(tree, bad[0], bad[1], true, dark_tokens)
		testing.expectf(t, !bad_ok, "expected refusal for %dx%d", bad[0], bad[1])
	}

	// Valid sizes across dark and light appearances, both idle and running.
	sizes := [?][2]int{{MINIMUM_WIDTH, MINIMUM_HEIGHT}, {WIDTH, HEIGHT}, {1280, 900}}
	appearances := [?]box_layout.Element_Tokens{dark_tokens, light_tokens}
	for tokens in appearances {
		for dim in sizes {
			w, h := dim[0], dim[1]
			idle, idle_ok := assistant_layout(tree, w, h, false, tokens)
			testing.expect(t, idle_ok)
			testing.expect(t, !idle.has_stop)
			testing.expect(t, area_inside(idle.view, w, h))
			testing.expect(t, area_inside(idle.scroll_bar, w, h))
			testing.expect(t, area_inside(idle.input, w, h))
			testing.expect(t, !areas_overlap(idle.view, idle.scroll_bar))
			testing.expect(t, !areas_overlap(idle.view, idle.input))
			testing.expect(t, !areas_overlap(idle.scroll_bar, idle.input))
			testing.expect_value(t, idle.scroll_bar.width, interface.SCROLL_BAR_THICKNESS)
			testing.expect_value(t, idle.input.height, INPUT_HEIGHT)

			running, run_ok := assistant_layout(tree, w, h, true, tokens)
			testing.expect(t, run_ok)
			testing.expect(t, running.has_stop)
			testing.expect(t, area_inside(running.view, w, h))
			testing.expect(t, area_inside(running.scroll_bar, w, h))
			testing.expect(t, area_inside(running.input, w, h))
			testing.expect(t, area_inside(running.stop_button, w, h))
			testing.expect(t, !areas_overlap(running.view, running.scroll_bar))
			testing.expect(t, !areas_overlap(running.view, running.input))
			testing.expect(t, !areas_overlap(running.view, running.stop_button))
			testing.expect(t, !areas_overlap(running.input, running.stop_button))
			testing.expect(t, running.stop_button.x >= running.input.x + running.input.width)
			testing.expect_value(t, running.stop_button.width, STOP_WIDTH)
			testing.expect(t, idle.input.width > running.input.width)
		}
	}
}
