#+build !freestanding
package paint_model

import "core:testing"
import "modus:contract/scale_factor"
import "modus:graphics"
import "modus:layout"

@(private = "file")
rect_inside :: proc(inner, outer: layout.Rect) -> bool {
	return inner.x >= outer.x && inner.y >= outer.y && inner.x + inner.width <= outer.x + outer.width && inner.y + inner.height <= outer.y + outer.height
}

@(private = "file")
rects_apart :: proc(first, second: layout.Rect) -> bool {
	return first.x + first.width <= second.x || second.x + second.width <= first.x || first.y + first.height <= second.y || second.y + second.height <= first.y
}

@(test)
paint_layout_refuses_bad_sizes :: proc(t: ^testing.T) {
	tree := new(layout.Box_Tree)
	defer free(tree)
	tokens, _ := layout.tokens_for(.Dark, .Standard)
	for size in ([][2]int{{0, LAYOUT_DEFAULT_HEIGHT}, {LAYOUT_DEFAULT_WIDTH, 0}, {-1, LAYOUT_DEFAULT_HEIGHT}, {LAYOUT_DEFAULT_WIDTH, -1}, {layout.LENGTH_LIMIT + 1, LAYOUT_DEFAULT_HEIGHT}}) {
		places, ok := window_layout(tree, size[0], size[1], .None, tokens)
		testing.expect(t, !ok && places == {})
	}
}

@(test)
paint_layout_non_overlap_across_panels_sizes_and_scales :: proc(t: ^testing.T) {
	tree := new(layout.Box_Tree)
	defer free(tree)
	sizes := [][2]int{
		{LAYOUT_LEAST_WIDTH, LAYOUT_LEAST_HEIGHT},
		{LAYOUT_DEFAULT_WIDTH, LAYOUT_DEFAULT_HEIGHT},
		{LAYOUT_LARGEST_WIDTH, LAYOUT_LARGEST_HEIGHT},
	}
	for appearance in graphics.Appearance {
		tokens, tok_ok := layout.tokens_for(appearance, .Standard)
		testing.expect(t, tok_ok)
		for size in sizes {
			window := layout.Rect{0, 0, i32(size[0]), i32(size[1])}
			for panel_kind in Panel_Kind {
				places, ok := window_layout(tree, size[0], size[1], panel_kind, tokens)
				testing.expectf(t, ok, "window_layout failed for %v %v", size, panel_kind)
				main_rects := [4]layout.Rect{places.tools_row, places.palette_row, places.canvas, places.status_bar}
				for a, i in main_rects {
					testing.expect(t, rect_inside(a, window))
					for b in main_rects[i + 1:] {
						testing.expect(t, rects_apart(a, b))
					}
				}
				testing.expect(t, places.canvas.width >= 200 && places.canvas.height >= 200)
				if panel_kind != .None {
					testing.expect(t, rect_inside(places.panel, window))
					testing.expect(t, rects_apart(places.canvas, places.panel))
					testing.expect(t, rects_apart(places.panel, places.status_bar))
				}
				switch panel_kind {
				case .None:
				case .Color:
					testing.expect(t, rect_inside(places.color_sample, places.panel))
					testing.expect(t, rect_inside(places.color_hex_field, places.panel))
					testing.expect(t, rect_inside(places.color_apply_btn, places.panel))
					testing.expect(t, rects_apart(places.color_hex_field, places.color_apply_btn))
					for ch in Channel {
						c := places.color_channels[ch]
						row_items := [4]layout.Rect{c.label, c.less, c.bar, c.more}
						for a, i in row_items {
							testing.expect(t, rect_inside(a, places.panel))
							for b in row_items[i + 1:] {
								testing.expect(t, rects_apart(a, b))
							}
						}
					}
				case .Pictures:
					controls := [8]layout.Rect{
						places.pic_name_field, places.pic_new_btn, places.pic_rename_btn,
						places.pic_list, places.pic_open_btn, places.pic_delete_btn,
						places.pic_prev_btn, places.pic_next_btn,
					}
					for a, i in controls {
						testing.expect(t, rect_inside(a, places.panel))
						for b in controls[i + 1:] {
							testing.expect(t, rects_apart(a, b))
						}
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
