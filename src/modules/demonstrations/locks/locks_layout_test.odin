#+build !freestanding
package locks

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
locks_layout_refuses_bad_sizes :: proc(t: ^testing.T) {
	tree := new(layout.Box_Tree)
	defer free(tree)
	tokens, _ := layout.tokens_for(.Dark, .Standard)
	for size in ([][2]int{{0, HEIGHT}, {WIDTH, 0}, {-1, HEIGHT}, {WIDTH, -1}, {layout.LENGTH_LIMIT + 1, HEIGHT}}) {
		places, ok := locks_window_layout(tree, size[0], size[1], tokens)
		testing.expect(t, !ok && places == {})
	}
}

@(test)
locks_layout_non_overlap_across_sizes_scales_and_appearances :: proc(t: ^testing.T) {
	tree := new(layout.Box_Tree)
	defer free(tree)
	for appearance in graphics.Appearance {
		tokens, tok_ok := layout.tokens_for(appearance, .Standard)
		testing.expect(t, tok_ok)
		for size in ([][2]int{{WIDTH, HEIGHT}, {1024, 768}}) {
			window := interface.Area{0, 0, size[0], size[1]}
			places, ok := locks_window_layout(tree, size[0], size[1], tokens)
			testing.expect(t, ok)

			rows: [dynamic]interface.Area
			defer delete(rows)
			append(&rows, places.intro, places.lockers_header, places.lockers_rows[0], places.lockers_rows[1], places.pair_header, places.pair_row, places.locks_header)
			for r in places.locks_rows {
				append(&rows, r)
			}
			append(&rows, places.cache_header)
			for r in places.cache_rows {
				append(&rows, r)
			}
			append(&rows, places.stress_row, places.verdict_row)
			for a, i in rows {
				testing.expectf(t, area_inside(a, window), "row %d left window %v", i, size)
				for b in rows[i + 1:] {
					testing.expect(t, areas_apart(a, b))
				}
			}
			// Verify table columns never overlap horizontally.
			for i in 0 ..< len(places.lockers_cols) - 1 {
				testing.expect(t, places.lockers_cols[i].x + places.lockers_cols[i].width <= places.lockers_cols[i + 1].x)
			}
			for i in 0 ..< len(places.locks_cols) - 1 {
				testing.expect(t, places.locks_cols[i].x + places.locks_cols[i].width <= places.locks_cols[i + 1].x)
			}
			for i in 0 ..< len(places.cache_cols) - 1 {
				testing.expect(t, places.cache_cols[i].x + places.cache_cols[i].width <= places.cache_cols[i + 1].x)
			}
			for scale in scale_factor.Scale {
				sw := scale_factor.screen_pixel_of_logical_pixel(i32(size[0]), scale)
				sh := scale_factor.screen_pixel_of_logical_pixel(i32(size[1]), scale)
				testing.expect(t, sw >= i64(size[0]) && sh >= i64(size[1]))
			}
		}
	}
}
