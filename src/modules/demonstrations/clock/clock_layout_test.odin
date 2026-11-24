#+build !freestanding
package clock

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
clock_layout_refuses_bad_sizes :: proc(t: ^testing.T) {
	tree := new(layout.Box_Tree)
	defer free(tree)
	tokens, _ := layout.tokens_for(.Dark, .Standard)
	for size in ([][2]int{{0, HEIGHT}, {WIDTH, 0}, {-1, HEIGHT}, {WIDTH, -1}, {layout.LENGTH_LIMIT + 1, HEIGHT}, {WIDTH, layout.LENGTH_LIMIT + 1}, {min(int), min(int)}, {max(int), max(int)}}) {
		places, ok := clock_window_layout(tree, size[0], size[1], tokens)
		testing.expectf(t, !ok && places == {}, "bad size %v accepted", size)
	}
	_, nil_ok := clock_window_layout(nil, WIDTH, HEIGHT, tokens)
	testing.expect(t, !nil_ok)
}

@(test)
clock_layouts_do_not_overlap_across_sizes_scales_and_appearances :: proc(t: ^testing.T) {
	tree := new(layout.Box_Tree)
	defer free(tree)
	sizes := [][2]int{
		{LEAST_WIDTH, LEAST_HEIGHT},
		{WIDTH, HEIGHT},
		{LARGEST_WIDTH, LARGEST_HEIGHT},
	}
	for appearance in graphics.Appearance {
		tokens, tok_ok := layout.tokens_for(appearance, .Standard)
		testing.expect(t, tok_ok)
		for size in sizes {
			window := interface.Area{0, 0, size[0], size[1]}
			places, ok := clock_window_layout(tree, size[0], size[1], tokens)
			testing.expectf(t, ok, "clock_window_layout failed for %v", size)
			// Tabs stay inside window and apart from each other, divider, and content.
			for a in Section {
				testing.expect(t, area_inside(places.tabs[a], window))
				testing.expect(t, areas_apart(places.tabs[a], places.divider))
				testing.expect(t, areas_apart(places.tabs[a], places.content))
				for b in Section {
					if a < b {
						testing.expect(t, areas_apart(places.tabs[a], places.tabs[b]))
					}
				}
			}
			testing.expect(t, area_inside(places.divider, window))
			testing.expect(t, area_inside(places.content, window))
			testing.expect(t, areas_apart(places.divider, places.content))

			// Clock section non-overlap.
			c_font := digits_font(places.content.width, places.content.height / 4, 8)
			cp, cok := clock_section_layout(tree, places.content, interface.line_height(c_font), 3 * 88 + 2 * GAP, tokens)
			testing.expect(t, cok)
			c_areas := [5]interface.Area{cp.digits, cp.date, cp.cal_header, cp.cal_weekdays, cp.cal_grid}
			for a, i in c_areas {
				testing.expect(t, area_inside(a, places.content))
				for b in c_areas[i + 1:] {
					testing.expect(t, areas_apart(a, b))
				}
			}
			testing.expect(t, area_inside(cp.cal_buttons, cp.cal_header))

			// Stopwatch section non-overlap + columns.
			s_font := digits_font(places.content.width, places.content.height / 4, 9)
			sp, sok := stopwatch_section_layout(tree, places.content, interface.line_height(s_font), 2 * 104 + GAP, tokens)
			testing.expect(t, sok)
			s_areas := [4]interface.Area{sp.digits, sp.buttons, sp.table_header, sp.table_rows}
			for a, i in s_areas {
				testing.expect(t, area_inside(a, places.content))
				for b in s_areas[i + 1:] {
					testing.expect(t, areas_apart(a, b))
				}
			}
			testing.expect(t, sp.columns[0].x + sp.columns[0].width <= sp.columns[1].x)
			testing.expect(t, sp.columns[1].x + sp.columns[1].width <= sp.columns[2].x)

			// Timer section (ready and ended) non-overlap.
			for ended in ([2]bool{false, true}) {
				tp, tok := timer_section_layout(tree, places.content, interface.line_height(c_font), 2 * 104 + GAP, 4 * 80 + 3 * GAP, ended, tokens)
				testing.expect(t, tok)
				t_areas := [5]interface.Area{tp.digits, tp.bar, tp.actions, tp.steps, tp.presets}
				for a, i in t_areas {
					testing.expect(t, area_inside(a, places.content))
					for b in t_areas[i + 1:] {
						testing.expect(t, areas_apart(a, b))
					}
				}
				if ended {
					testing.expect(t, area_inside(tp.ended, places.content))
					testing.expect(t, areas_apart(tp.bar, tp.ended))
					testing.expect(t, areas_apart(tp.ended, tp.actions))
				}
			}

			// Verify HiDPI scaling across every scale factor preserves non-overlapping bounds.
			for scale in scale_factor.Scale {
				sw := scale_factor.screen_pixel_of_logical_pixel(i32(size[0]), scale)
				sh := scale_factor.screen_pixel_of_logical_pixel(i32(size[1]), scale)
				testing.expect(t, sw >= i64(size[0]) && sh >= i64(size[1]))
				cx_end := scale_factor.screen_pixel_of_logical_pixel(i32(places.content.x + places.content.width), scale)
				cy_end := scale_factor.screen_pixel_of_logical_pixel(i32(places.content.y + places.content.height), scale)
				testing.expect(t, cx_end <= sw && cy_end <= sh)
			}
		}
	}
}
