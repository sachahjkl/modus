#+build !freestanding
package processors

import "base:intrinsics"
import "core:testing"
import "modus:contract/scale_factor"
import "modus:graphics"
import "modus:interface"
import "modus:layout"

@(export, link_name = "export_call")
host_export_call :: proc "c" (address: uintptr, integers, floats, results: rawptr) {intrinsics.trap()}

@(private = "file")
area_inside :: proc(inner, outer: interface.Area) -> bool {
	return inner.x >= outer.x && inner.y >= outer.y && inner.x + inner.width <= outer.x + outer.width && inner.y + inner.height <= outer.y + outer.height
}

@(private = "file")
areas_apart :: proc(first, second: interface.Area) -> bool {
	return first.x + first.width <= second.x || second.x + second.width <= first.x || first.y + first.height <= second.y || second.y + second.height <= first.y
}

@(test)
processors_layout_refuses_bad_sizes :: proc(t: ^testing.T) {
	tree := new(layout.Box_Tree)
	defer free(tree)
	tokens, _ := layout.tokens_for(.Dark, .Standard)
	for size in ([][2]int{{0, HEIGHT}, {WIDTH, 0}, {-1, HEIGHT}, {WIDTH, -1}, {layout.LENGTH_LIMIT + 1, HEIGHT}, {WIDTH, layout.LENGTH_LIMIT + 1}}) {
		places, ok := processors_window_layout(tree, size[0], size[1], 4, tokens)
		testing.expect(t, !ok && places == {})
	}
}

@(test)
processors_layout_non_overlap_across_counts_sizes_and_scales :: proc(t: ^testing.T) {
	tree := new(layout.Box_Tree)
	defer free(tree)
	for appearance in graphics.Appearance {
		tokens, tok_ok := layout.tokens_for(appearance, .Standard)
		testing.expect(t, tok_ok)
		for size in ([][2]int{{WIDTH, HEIGHT}, {1024, 576}}) {
			window := interface.Area{0, 0, size[0], size[1]}
			for proc_count in ([]int{1, 4, PROCESSOR_ROWS}) {
				places, ok := processors_window_layout(tree, size[0], size[1], proc_count, tokens)
				testing.expect(t, ok)
				testing.expect(t, area_inside(places.header, window))
				testing.expect(t, area_inside(places.picture, window))
				testing.expect(t, area_inside(places.panel, window))
				testing.expect(t, areas_apart(places.header, places.picture))
				testing.expect(t, areas_apart(places.header, places.panel))
				testing.expect(t, areas_apart(places.picture, places.panel))
				testing.expect_value(t, places.picture.width, PICTURE_WIDTH)
				testing.expect_value(t, places.picture.height, PICTURE_HEIGHT)

				// Panel rows sit cleanly inside panel and never overlap each other.
				rows: [dynamic]interface.Area
				defer delete(rows)
				append(&rows, places.summary)
				for i in 0 ..< proc_count {
					append(&rows, places.processor_rows[i])
				}
				append(&rows, places.times_header)
				for i in 0 ..< 3 {
					append(&rows, places.time_rows[i])
				}
				append(&rows, places.workers_header)
				for i in 0 ..< WORKER_COUNT {
					append(&rows, places.worker_rows[i])
				}
				append(&rows, places.lock_waits)
				for a, i in rows {
					if proc_count <= 4 {
						testing.expectf(t, area_inside(a, places.panel), "row %d left panel", i)
					}
					for b in rows[i + 1:] {
						testing.expect(t, areas_apart(a, b))
					}
				}
			}
			for scale in scale_factor.Scale {
				sw := scale_factor.screen_pixel_of_logical_pixel(i32(size[0]), scale)
				sh := scale_factor.screen_pixel_of_logical_pixel(i32(size[1]), scale)
				testing.expect(t, sw >= i64(size[0]) && sh >= i64(size[1]))
			}
		}
	}
}
