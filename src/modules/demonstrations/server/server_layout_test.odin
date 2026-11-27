#+build !freestanding
package server

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
server_layout_refuses_bad_inputs :: proc(t: ^testing.T) {
	tree := new(layout.Box_Tree)
	defer free(tree)
	places, ok := server_layout(nil, WIDTH, HEIGHT)
	testing.expect(t, !ok && places == {})
	for size in ([][2]int{{0, HEIGHT}, {WIDTH, 0}, {0, 0}, {-1, HEIGHT}, {WIDTH, -1}, {-100, -100}, {layout.LENGTH_LIMIT + 1, HEIGHT}, {WIDTH, layout.LENGTH_LIMIT + 1}, {max(int), HEIGHT}}) {
		places, ok = server_layout(tree, size[0], size[1])
		testing.expectf(t, !ok && places == {}, "expected refusal for %v", size)
	}
}

@(test)
server_layout_nominal_and_edge_sizes :: proc(t: ^testing.T) {
	tree := new(layout.Box_Tree)
	defer free(tree)

	// Nominal size checks exact card placement and non-overlapping cards and columns.
	nominal, ok := server_layout(tree, WIDTH, HEIGHT)
	testing.expect(t, ok)
	testing.expect_value(t, nominal.listen, interface.Area{8, 8, LISTEN_CARD_WIDTH, TOP_HEIGHT})
	testing.expect_value(t, nominal.answers, interface.Area{272, 8, ANSWERS_CARD_WIDTH, TOP_HEIGHT})
	testing.expect_value(t, nominal.measures, interface.Area{512, 8, 456, TOP_HEIGHT})
	testing.expect_value(t, nominal.connections, interface.Area{8, 184, CONNECTIONS_CARD_WIDTH, 488})
	testing.expect_value(t, nominal.requests, interface.Area{552, 184, 416, 488})

	for size in ([][2]int{{WIDTH, HEIGHT}, {1280, 720}, {layout.LENGTH_LIMIT, layout.LENGTH_LIMIT}}) {
		places, size_ok := server_layout(tree, size[0], size[1])
		testing.expectf(t, size_ok, "expected valid layout for %v", size)
		window := interface.Area{0, 0, size[0], size[1]}
		cards := [5]interface.Area{places.listen, places.answers, places.measures, places.connections, places.requests}
		for card, i in cards {
			testing.expectf(t, card.width > 0 && card.height > 0, "card %d empty at %v", i, size)
			testing.expectf(t, area_inside(card, window), "card %d left window at %v", i, size)
			for other in cards[i + 1:] {
				testing.expectf(t, areas_apart(card, other), "cards overlap at %v", size)
			}
		}

		// Connection table columns stay inside card content and do not overlap.
		for col, i in places.connection_columns {
			col_area := interface.Area{int(col.x), places.connections_content.y, int(col.width), places.connections_content.height}
			testing.expect(t, col.width > 0)
			testing.expect(t, area_inside(col_area, places.connections_content))
			for next in places.connection_columns[i + 1:] {
				testing.expect(t, col.x + col.width <= next.x)
			}
		}

		// Request table columns stay inside card content and do not overlap.
		for col, i in places.request_columns {
			col_area := interface.Area{int(col.x), places.requests_content.y, int(col.width), places.requests_content.height}
			testing.expect(t, col.width > 0)
			testing.expect(t, area_inside(col_area, places.requests_content))
			for next in places.request_columns[i + 1:] {
				testing.expect(t, col.x + col.width <= next.x)
			}
		}
	}

	// Minimal positive edge sizes solve cleanly without overlapping cards or columns.
	for size in ([][2]int{{1, 1}, {16, 16}, {320, 200}}) {
		places, edge_ok := server_layout(tree, size[0], size[1])
		testing.expectf(t, edge_ok, "expected edge layout for %v", size)
		cards := [5]interface.Area{places.listen, places.answers, places.measures, places.connections, places.requests}
		for card, i in cards {
			for other in cards[i + 1:] {
				testing.expect(t, areas_apart(card, other))
			}
		}
		for col, i in places.connection_columns {
			for next in places.connection_columns[i + 1:] {
				testing.expect(t, col.x + col.width <= next.x)
			}
		}
		for col, i in places.request_columns {
			for next in places.request_columns[i + 1:] {
				testing.expect(t, col.x + col.width <= next.x)
			}
		}
	}

	for scale in scale_factor.Scale {
		sw := scale_factor.screen_pixel_of_logical_pixel(i32(WIDTH), scale)
		sh := scale_factor.screen_pixel_of_logical_pixel(i32(HEIGHT), scale)
		testing.expect(t, sw >= i64(WIDTH) && sh >= i64(HEIGHT))
	}
	_ = graphics.GAP
}
