#+build !freestanding
package terminal_process

import "base:intrinsics"
import "core:testing"
import "internal:terminal/grid_resize"
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
terminal_layout_refuses_bad_sizes :: proc(t: ^testing.T) {
	tree := new(layout.Box_Tree)
	defer free(tree)
	for bad in ([][4]int{{0, 400, 80, 24}, {640, 0, 80, 24}, {-1, 400, 80, 24}, {640, 400, 0, 24}, {640, 400, 80, 0}, {layout.LENGTH_LIMIT + 1, 400, 80, 24}}) {
		places, ok := terminal_window_layout(tree, bad[0], bad[1], bad[2], bad[3], false)
		testing.expect(t, !ok && places == {})
	}
}

@(test)
terminal_layout_non_overlap_across_grid_bounds_modes_and_scales :: proc(t: ^testing.T) {
	tree := new(layout.Box_Tree)
	defer free(tree)
	grids := [][2]int{
		{grid_resize.TERMINAL_WINDOW_BOUNDS.min_columns, grid_resize.TERMINAL_WINDOW_BOUNDS.min_rows},
		{80, 24},
		{COLUMNS_LIMIT, ROWS_LIMIT},
	}
	for appearance in graphics.Appearance {
		_, tok_ok := layout.tokens_for(appearance, .Standard)
		testing.expect(t, tok_ok)
		for measure_mode in ([2]bool{false, true}) {
			chrome_w := TEXT_X + SCROLL_GAP + SCROLL_WIDTH
			chrome_h := (measure_mode ? HEAD_HEIGHT + 24 : MARGIN) + 8 + CELL_HEIGHT + 6
			for g in grids {
				w := chrome_w + g[0] * CELL_WIDTH
				h := chrome_h + g[1] * CELL_HEIGHT
				window := interface.Area{0, 0, w, h}
				places, ok := terminal_window_layout(tree, w, h, g[0], g[1], measure_mode)
				testing.expectf(t, ok, "terminal layout failed for %v measure=%v", g, measure_mode)

				testing.expect(t, area_inside(places.text_view, window))
				testing.expect(t, area_inside(places.scroll_bar, window))
				testing.expect(t, area_inside(places.bottom_bar, window))
				testing.expect_value(t, places.text_view.width, g[0] * CELL_WIDTH)
				testing.expect_value(t, places.text_view.height, g[1] * CELL_HEIGHT)

				testing.expect(t, areas_apart(places.text_view, places.scroll_bar))
				testing.expect(t, areas_apart(places.text_view, places.bottom_bar))
				testing.expect(t, areas_apart(places.scroll_bar, places.bottom_bar))
				expected_scroll_top := measure_mode ? HEAD_HEIGHT - 6 : 0
				expected_scroll_end := measure_mode ? places.status_bar.y : places.bottom_bar.y
				testing.expect_value(t, places.scroll_bar.y, expected_scroll_top)
				testing.expect_value(t, places.scroll_bar.y + places.scroll_bar.height, expected_scroll_end)
				testing.expect_value(t, places.text_view.y, measure_mode ? HEAD_HEIGHT : MARGIN)

				if measure_mode {
					testing.expect(t, area_inside(places.head, window))
					testing.expect(t, area_inside(places.graph, places.head))
					testing.expect(t, area_inside(places.status_bar, window))
					testing.expect(t, areas_apart(places.head, places.text_view))
					testing.expect(t, areas_apart(places.head, places.scroll_bar))
					testing.expect(t, areas_apart(places.text_view, places.status_bar))
					testing.expect(t, areas_apart(places.scroll_bar, places.status_bar))
					testing.expect(t, areas_apart(places.status_bar, places.bottom_bar))
				}

				for scale in scale_factor.Scale {
					sw := scale_factor.screen_pixel_of_logical_pixel(i32(w), scale)
					sh := scale_factor.screen_pixel_of_logical_pixel(i32(h), scale)
					testing.expect(t, sw >= i64(w) && sh >= i64(h))
				}
			}
		}
	}
}

@(test)
terminal_apply_surface_size_updates_grid_and_chrome :: proc(t: ^testing.T) {
	measure = false
	columns = 80
	rows = 24
	cw, ch := chrome_size()
	layout_for_size(cw + columns * CELL_WIDTH, ch + rows * CELL_HEIGHT)
	_ = grid_resize.grid_init(&grid, ([^]Cell)(&view.cells[0][0])[:ROWS_LIMIT * COLUMNS_LIMIT], COLUMNS_LIMIT, columns, rows, grid_resize.TERMINAL_WINDOW_BOUNDS)
	old_width, old_height := width, height

	testing.expect(t, !terminal_apply_surface_size(0, 400))
	testing.expect(t, !terminal_apply_surface_size(old_width, old_height))

	// Shrink width and grow height, matching a mixed resize drag.
	new_width := old_width - 80
	new_height := old_height + 120
	testing.expect(t, terminal_apply_surface_size(new_width, new_height))
	testing.expect_value(t, width, new_width)
	testing.expect_value(t, height, new_height)
	testing.expect(t, columns < 80)
	testing.expect(t, rows > 24)
	testing.expect_value(t, terminal_places.bottom_bar.y + terminal_places.bottom_bar.height, new_height)
	testing.expect_value(t, terminal_places.bottom_bar.width, new_width)
	testing.expect(t, hint_y > old_height)
}
