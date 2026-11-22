#+build !freestanding
package monitor

import "base:intrinsics"
import "core:testing"
import "internal:monitor/sample_history"
import "modus:interface"
import "modus:layout"

// The test runs on the host: the module links src/library/modus/system,
// whose call of an export is an entry of the machine that the host does
// not have. No test here calls an export; a call stops the test.
@(export, link_name = "export_call")
host_export_call :: proc "c" (address: uintptr, integers, floats, results: rawptr) {intrinsics.trap()}

// area_inside says if an area lies whole inside another one.
@(private = "file")
area_inside :: proc(inner, outer: interface.Area) -> bool {
	return inner.x >= outer.x && inner.y >= outer.y && inner.x + inner.width <= outer.x + outer.width && inner.y + inner.height <= outer.y + outer.height
}

@(private = "file")
areas_apart :: proc(first, second: interface.Area) -> bool {
	return first.x + first.width <= second.x || second.x + second.width <= first.x || first.y + first.height <= second.y || second.y + second.height <= first.y
}

// The layout refuses each size that no tree takes, and keeps nothing of it.
@(test)
monitor_layout_refuses_each_size_out_of_bounds :: proc(t: ^testing.T) {
	tokens, _ := layout.tokens_for(.Dark, .Standard)
	for size in ([][2]int{{0, HEIGHT}, {WIDTH, 0}, {-1, HEIGHT}, {WIDTH, -1}, {layout.LENGTH_LIMIT + 1, HEIGHT}, {WIDTH, layout.LENGTH_LIMIT + 1}, {min(int), min(int)}, {max(int), max(int)}}) {
		result, ok := monitor_layout(size[0], size[1], tokens)
		testing.expectf(t, !ok, "the size %v was taken", size)
		testing.expect(t, result == {}, "a refusal gave places")
	}
}

// At the size of its start, every card lies inside the window and apart
// from each other card, each line of a card inside its card, each graph box
// is one that a sample history takes, the bar column keeps its least width,
// and the table holds ten rows and its last line.
@(test)
monitor_layout_at_the_start_size :: proc(t: ^testing.T) {
	tokens, _ := layout.tokens_for(.Light, .Standard)
	result, ok := monitor_layout(WIDTH, HEIGHT, tokens)
	testing.expect(t, ok)
	window := interface.Area{0, 0, WIDTH, HEIGHT}
	cards: [dynamic]interface.Area
	defer delete(cards)
	for metric in Metric {
		card := result.metric_cards[metric]
		append(&cards, card)
		for line in Metric_Line {
			area := result.metric_lines[metric][line]
			testing.expectf(t, area_inside(area, card), "%v %v leaves its card", metric, line)
			testing.expect_value(t, i32(area.height), metric_line_height(line))
		}
		// The longest detail of the cells: all the memory of a machine of
		// 16 GiB, in the caption size.
		testing.expect(t, interface.text_measured_width(nil, interface.FONT_CAPTION, "16384 / 16384 MiB") <= result.metric_lines[metric][.Detail].width)
		testing.expect(t, interface.text_measured_width(nil, FONT_METRIC, "100%") <= result.metric_lines[metric][.Value].width)
		testing.expect(t, interface.text_measured_width(nil, FONT_METRIC, "9999E") <= result.metric_lines[metric][.Value].width)
	}
	for graph in Graph {
		card := result.graph_cards[graph]
		append(&cards, card)
		box := result.graph_boxes[graph]
		testing.expect(t, sample_history.box_valid(box))
		testing.expect_value(t, box.height, GRAPH_HEIGHT)
		testing.expect(t, area_inside({box.left, box.top, box.width, box.height}, card))
		testing.expect(t, area_inside(result.graph_headers[graph], card))
	}
	append(&cards, result.table_card)
	for card, index in cards {
		testing.expectf(t, area_inside(card, window), "the card %d leaves the window", index)
		for other in cards[index + 1:] {
			testing.expect(t, areas_apart(card, other), "two cards overlap")
		}
	}
	for area in ([]interface.Area{result.table_title, result.table_header, result.table_rows}) {
		testing.expect(t, area_inside(area, result.table_card))
	}
	testing.expect(t, int(result.columns[.Processor_Bar].width) >= BAR_LEAST + int(tokens.gap))
	share := result.columns[.Share]
	testing.expect_value(t, int(share.x + share.width), result.table_rows.x + result.table_rows.width)
	testing.expect(t, result.table_rows.height >= 10 * LINE + LINE)
}
