#+build !freestanding
package scheduler

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
scheduler_layout_refuses_bad_sizes :: proc(t: ^testing.T) {
	tree := new(layout.Box_Tree)
	defer free(tree)
	tokens, _ := layout.tokens_for(.Dark, .Standard)
	for size in ([][2]int{{0, HEIGHT}, {WIDTH, 0}, {-1, HEIGHT}, {WIDTH, -1}, {layout.LENGTH_LIMIT + 1, HEIGHT}}) {
		places, ok := scheduler_window_layout(tree, size[0], size[1], .Strategies, true, 4, tokens)
		testing.expect(t, !ok && places == {})
	}
}

@(test)
scheduler_layout_non_overlap_across_views_modes_and_scales :: proc(t: ^testing.T) {
	tree := new(layout.Box_Tree)
	defer free(tree)
	for appearance in graphics.Appearance {
		tokens, tok_ok := layout.tokens_for(appearance, .Standard)
		testing.expect(t, tok_ok)
		for size in ([][2]int{{WIDTH, HEIGHT}, {1280, 864}}) {
			window := interface.Area{0, 0, size[0], size[1]}
			// Strategies view in both check and measure modes.
			for measured in ([2]bool{false, true}) {
				places, ok := scheduler_window_layout(tree, size[0], size[1], .Strategies, measured, 4, tokens)
				testing.expect(t, ok)
				cards := [4]interface.Area{places.head_card, places.measures_card, places.processors_card, places.stress_card}
				for a, i in cards {
					testing.expect(t, area_inside(a, window))
					for b in cards[i + 1:] {
						testing.expect(t, areas_apart(a, b))
					}
				}
				// Head controls sit inside head_card without overlapping.
				head_items := [5]interface.Area{places.head_hint, places.strategy_tiles[0], places.strategy_tiles[1], places.strategy_tiles[2], places.view_button}
				for a, i in head_items {
					testing.expect(t, area_inside(a, places.head_card))
					for b in head_items[i + 1:] {
						testing.expect(t, areas_apart(a, b))
					}
				}
				for i in 0 ..< len(places.measures_cols) - 1 {
					testing.expect(t, places.measures_cols[i].x + places.measures_cols[i].width <= places.measures_cols[i + 1].x)
				}
				for i in 0 ..< len(places.processors_cols) - 1 {
					testing.expect(t, places.processors_cols[i].x + places.processors_cols[i].width <= places.processors_cols[i + 1].x)
				}
			}
			// Shares view.
			sp, sok := scheduler_window_layout(tree, size[0], size[1], .Shares, false, 4, tokens)
			testing.expect(t, sok)
			testing.expect(t, area_inside(sp.head_card, window))
			testing.expect(t, area_inside(sp.shares_card, window))
			testing.expect(t, areas_apart(sp.head_card, sp.shares_card))

			for scale in scale_factor.Scale {
				sw := scale_factor.screen_pixel_of_logical_pixel(i32(size[0]), scale)
				sh := scale_factor.screen_pixel_of_logical_pixel(i32(size[1]), scale)
				testing.expect(t, sw >= i64(size[0]) && sh >= i64(size[1]))
			}
		}
	}
}
