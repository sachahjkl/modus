#+build !freestanding
package manual

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
manual_layout_refuses_out_of_bounds_and_avoids_overlap :: proc(t: ^testing.T) {
	tree := new(box_layout.Box_Tree)
	defer free(tree)

	dark_tokens, dark_ok := box_layout.tokens_for(.Dark, .Standard)
	light_tokens, light_ok := box_layout.tokens_for(.Light, .Standard)
	testing.expect(t, dark_ok && light_ok)

	// Refusal edges: nil tree, zero/negative sizes, below minimums, negative heading rows.
	_, ok := manual_layout(nil, WIDTH, HEIGHT, 1, dark_tokens)
	testing.expect(t, !ok)
	_, ok = manual_layout(tree, WIDTH, HEIGHT, -1, dark_tokens)
	testing.expect(t, !ok)
	for bad in ([?][2]int{{0, 0}, {-1, HEIGHT}, {WIDTH, -1}, {MINIMUM_WIDTH - 1, HEIGHT}, {WIDTH, MINIMUM_HEIGHT - 1}}) {
		_, bad_ok := manual_layout(tree, bad[0], bad[1], 1, dark_tokens)
		testing.expectf(t, !bad_ok, "expected refusal for %dx%d", bad[0], bad[1])
	}

	// Default size holds the full 84-column TEXT_WIDTH cleanly.
	def, def_ok := manual_layout(tree, WIDTH, HEIGHT, 2, dark_tokens)
	testing.expect(t, def_ok)
	testing.expect_value(t, def.text_column.width, TEXT_WIDTH)
	testing.expect_value(t, def.list_pane.width, LIST_WIDTH)
	testing.expect_value(t, def.scroll_bar.width, SCROLL_WIDTH)

	// Valid sizes across dark/light tokens and multiple heading heights: zero overlap and full containment.
	sizes := [?][2]int{{MINIMUM_WIDTH, MINIMUM_HEIGHT}, {WIDTH, HEIGHT}, {1280, 800}}
	appearances := [?]box_layout.Element_Tokens{dark_tokens, light_tokens}
	headings := [?]int{0, 2, 4}
	for tokens in appearances {
		for dim in sizes {
			w, h := dim[0], dim[1]
			for hrows in headings {
				boxes, solved := manual_layout(tree, w, h, hrows, tokens)
				testing.expect(t, solved)
				testing.expect(t, area_inside(boxes.list_pane, w, h))
				testing.expect(t, area_inside(boxes.filter_field, w, h))
				testing.expect(t, area_inside(boxes.list_header, w, h))
				testing.expect(t, area_inside(boxes.list_rows, w, h))
				testing.expect(t, area_inside(boxes.right_pane, w, h))
				testing.expect(t, area_inside(boxes.text_view, w, h))
				testing.expect(t, area_inside(boxes.text_column, w, h))
				testing.expect(t, area_inside(boxes.scroll_bar, w, h))
				testing.expect(t, area_inside(boxes.action_bar, w, h))
				testing.expect(t, area_inside(boxes.row_status, w, h))

				testing.expect(t, !areas_overlap(boxes.list_pane, boxes.right_pane))
				testing.expect(t, !areas_overlap(boxes.filter_field, boxes.list_header))
				testing.expect(t, !areas_overlap(boxes.list_header, boxes.list_rows))
				testing.expect(t, !areas_overlap(boxes.text_view, boxes.scroll_bar))
				testing.expect(t, !areas_overlap(boxes.page_row, boxes.footer_row))
				testing.expect(t, !areas_overlap(boxes.action_bar, boxes.row_status))
				if hrows > 0 {
					testing.expect(t, area_inside(boxes.heading, w, h))
					testing.expect(t, !areas_overlap(boxes.heading, boxes.text_column))
				}
			}
		}
	}
}
