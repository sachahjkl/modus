#+build !freestanding
package tables

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
tables_layout_refuses_bad_inputs :: proc(t: ^testing.T) {
	tree := new(layout.Box_Tree)
	defer free(tree)
	places, ok := tables_layout(nil, WIDTH, HEIGHT, 240, 220)
	testing.expect(t, !ok && places == {})
	bad_cases := [][4]int{
		{0, HEIGHT, 240, 220},
		{WIDTH, 0, 240, 220},
		{-1, HEIGHT, 240, 220},
		{WIDTH, -1, 240, 220},
		{WIDTH, HEIGHT, -1, 220},
		{WIDTH, HEIGHT, 240, -1},
		{layout.LENGTH_LIMIT + 1, HEIGHT, 240, 220},
		{WIDTH, layout.LENGTH_LIMIT + 1, 240, 220},
		{WIDTH, HEIGHT, layout.LENGTH_LIMIT + 1, 220},
		{WIDTH, HEIGHT, 240, layout.LENGTH_LIMIT + 1},
		{max(int), HEIGHT, 240, 220},
	}
	for c in bad_cases {
		places, ok = tables_layout(tree, c[0], c[1], c[2], c[3])
		testing.expectf(t, !ok && places == {}, "expected refusal for %v", c)
	}
}

@(test)
tables_layout_nominal_and_edge_sizes :: proc(t: ^testing.T) {
	tree := new(layout.Box_Tree)
	defer free(tree)

	// Nominal size with representative card heights.
	nominal, ok := tables_layout(tree, WIDTH, HEIGHT, 248, 228)
	testing.expect(t, ok)
	testing.expect_value(t, nominal.cases_card, interface.Area{16, 16, WIDTH - 32, 248})
	testing.expect_value(t, nominal.hostile_card, interface.Area{16, 280, WIDTH - 32, 228})
	testing.expect_value(t, nominal.measures_card, interface.Area{16, HEIGHT - 16 - MEASURES_HEIGHT, WIDTH - 32, MEASURES_HEIGHT})

	for size in ([][2]int{{WIDTH, HEIGHT}, {1280, 800}, {layout.LENGTH_LIMIT, layout.LENGTH_LIMIT}}) {
		window := interface.Area{0, 0, size[0], size[1]}
		for heights in ([][2]int{{0, 0}, {CARD_HEAD + LINE, CARD_HEAD}, {248, 228}, {248, 400}}) {
			places, size_ok := tables_layout(tree, size[0], size[1], heights[0], heights[1])
			testing.expectf(t, size_ok, "expected valid layout for size=%v heights=%v", size, heights)
			cards := [3]interface.Area{places.cases_card, places.hostile_card, places.measures_card}
			for card, i in cards {
				testing.expectf(t, area_inside(card, window), "card %d left window at %v", i, size)
				for other in cards[i + 1:] {
					testing.expectf(t, areas_apart(card, other), "cards overlap for size=%v heights=%v", size, heights)
				}
			}
			for col, i in places.cases_columns {
				col_area := interface.Area{int(col.x), places.cases_content.y, int(col.width), places.cases_content.height}
				testing.expect(t, col.width > 0)
				testing.expect(t, area_inside(col_area, places.cases_content))
				for next in places.cases_columns[i + 1:] {
					testing.expect(t, col.x + col.width <= next.x)
				}
			}
			for col, i in places.hostile_columns {
				col_area := interface.Area{int(col.x), places.hostile_content.y, int(col.width), places.hostile_content.height}
				testing.expect(t, col.width > 0)
				testing.expect(t, area_inside(col_area, places.hostile_content))
				for next in places.hostile_columns[i + 1:] {
					testing.expect(t, col.x + col.width <= next.x)
				}
			}
			for col, i in places.measures_columns {
				col_area := interface.Area{int(col.x), places.measures_content.y, int(col.width), places.measures_content.height}
				testing.expect(t, col.width > 0)
				testing.expect(t, area_inside(col_area, places.measures_content))
				for next in places.measures_columns[i + 1:] {
					testing.expect(t, col.x + col.width <= next.x)
				}
			}
		}
	}

	// Minimal positive edge sizes solve cleanly without overlapping cards or columns.
	for size in ([][2]int{{1, 1}, {16, 16}, {320, 240}}) {
		places, edge_ok := tables_layout(tree, size[0], size[1], 100, 100)
		testing.expectf(t, edge_ok, "expected edge layout for %v", size)
		cards := [3]interface.Area{places.cases_card, places.hostile_card, places.measures_card}
		for card, i in cards {
			for other in cards[i + 1:] {
				testing.expect(t, areas_apart(card, other))
			}
		}
		for col, i in places.cases_columns {
			for next in places.cases_columns[i + 1:] {
				testing.expect(t, col.x + col.width <= next.x)
			}
		}
		for col, i in places.hostile_columns {
			for next in places.hostile_columns[i + 1:] {
				testing.expect(t, col.x + col.width <= next.x)
			}
		}
		for col, i in places.measures_columns {
			for next in places.measures_columns[i + 1:] {
				testing.expect(t, col.x + col.width <= next.x)
			}
		}
	}

	for scale in scale_factor.Scale {
		sw := scale_factor.screen_pixel_of_logical_pixel(i32(WIDTH), scale)
		sh := scale_factor.screen_pixel_of_logical_pixel(i32(HEIGHT), scale)
		testing.expect(t, sw >= i64(WIDTH) && sh >= i64(HEIGHT))
	}
	_ = graphics.MARGIN
}
