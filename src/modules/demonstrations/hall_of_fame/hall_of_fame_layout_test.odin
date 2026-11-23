#+build !freestanding
package hall_of_fame

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
hall_layout_refuses_bad_sizes :: proc(t: ^testing.T) {
	tree := new(layout.Box_Tree)
	defer free(tree)
	tokens, _ := layout.tokens_for(.Dark, .Standard)
	heights := [ROW_COUNT]int{200, 200, 200, 200, 200, 120}
	for size in ([][2]int{{0, HEIGHT}, {WIDTH, 0}, {-1, HEIGHT}, {WIDTH, -1}, {layout.LENGTH_LIMIT + 1, HEIGHT}}) {
		places, ok := hall_window_layout(tree, size[0], size[1], heights[:], 0, 2, tokens)
		testing.expect(t, !ok && places == {})
	}
}

@(test)
hall_layout_non_overlap_across_scroll_rows_and_scales :: proc(t: ^testing.T) {
	tree := new(layout.Box_Tree)
	defer free(tree)
	heights := [ROW_COUNT]int{210, 210, 210, 210, 210, 140}
	for appearance in graphics.Appearance {
		tokens, tok_ok := layout.tokens_for(appearance, .Standard)
		testing.expect(t, tok_ok)
		window := interface.Area{0, 0, WIDTH, HEIGHT}
		for first in 0 ..< ROW_COUNT {
			visible := min(3, ROW_COUNT - first)
			places, ok := hall_window_layout(tree, WIDTH, HEIGHT, heights[:], first, visible, tokens)
			testing.expect(t, ok)
			testing.expect(t, area_inside(places.header, window))
			testing.expect(t, area_inside(places.cards_view, window))
			testing.expect(t, area_inside(places.scroll_bar, window))
			testing.expect(t, areas_apart(places.header, places.cards_view))
			testing.expect(t, areas_apart(places.header, places.scroll_bar))
			testing.expect(t, areas_apart(places.cards_view, places.scroll_bar))

			shown_cards: [dynamic]interface.Area
			defer delete(shown_cards)
			for i in 0 ..< PERSON_COUNT {
				if places.card_shown[i] {
					append(&shown_cards, places.cards[i])
					testing.expect(t, area_inside(places.cards[i], places.cards_view))
					testing.expect(t, areas_apart(places.cards[i], places.scroll_bar))
				}
			}
			testing.expect(t, len(shown_cards) > 0)
			for a, i in shown_cards {
				for b in shown_cards[i + 1:] {
					testing.expect(t, areas_apart(a, b))
				}
			}
		}
		for scale in scale_factor.Scale {
			sw := scale_factor.screen_pixel_of_logical_pixel(i32(WIDTH), scale)
			sh := scale_factor.screen_pixel_of_logical_pixel(i32(HEIGHT), scale)
			testing.expect(t, sw >= i64(WIDTH) && sh >= i64(HEIGHT))
		}
	}
}
