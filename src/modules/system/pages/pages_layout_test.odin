#+build !freestanding
package pages

import "base:intrinsics"
import "core:testing"
import "modus:contract/scale_factor"
import "modus:interface"
import "modus:layout"

@(export, link_name = "export_call")
host_export_call :: proc "c" (address: uintptr, integers, floats, results: rawptr) {intrinsics.trap()}

@(private = "file")
area_inside :: proc(inner, outer: interface.Area) -> bool {
	if inner.width == 0 || inner.height == 0 {
		return true
	}
	return inner.x >= outer.x && inner.y >= outer.y && inner.x + inner.width <= outer.x + outer.width && inner.y + inner.height <= outer.y + outer.height
}

@(private = "file")
areas_apart :: proc(first, second: interface.Area) -> bool {
	if first.width == 0 || first.height == 0 || second.width == 0 || second.height == 0 {
		return true
	}
	return first.x + first.width <= second.x || second.x + second.width <= first.x || first.y + first.height <= second.y || second.y + second.height <= first.y
}

@(test)
pages_layout_refuses_bad_sizes_and_nil_tree :: proc(t: ^testing.T) {
	tree := new(layout.Box_Tree)
	defer free(tree)
	bad_sizes := [][2]int{
		{0, HEIGHT},
		{WIDTH, 0},
		{0, 0},
		{-1, HEIGHT},
		{WIDTH, -1},
		{layout.LENGTH_LIMIT + 1, HEIGHT},
		{WIDTH, layout.LENGTH_LIMIT + 1},
		{min(int), min(int)},
		{max(int), max(int)},
	}
	for size in bad_sizes {
		places, ok := pages_layout(tree, size[0], size[1])
		testing.expectf(t, !ok && places == {}, "bad size %v accepted", size)
	}
	nil_places, nil_ok := pages_layout(nil, WIDTH, HEIGHT)
	testing.expect(t, !nil_ok && nil_places == {})
}

@(test)
pages_layout_nominal_and_wide_sections_and_columns :: proc(t: ^testing.T) {
	tree := new(layout.Box_Tree)
	defer free(tree)
	for size in ([][2]int{{WIDTH, HEIGHT}, {1024, 768}}) {
		window := interface.Area{0, 0, size[0], size[1]}
		for counts in ([][2]int{{0, 0}, {1, 1}, {18, 9}, {KERNEL_ROWS, PROCESS_ROWS}, {KERNEL_ROWS + 1, PROCESS_ROWS + 1}}) {
			places, ok := pages_layout(tree, size[0], size[1], counts[0], counts[1])
			testing.expectf(t, ok, "pages_layout failed for size %v counts %v", size, counts)

			// Sections stay inside the window and never overlap.
			sections := [3]interface.Area{places.kernel_section, places.rules_section, places.process_section}
			for a, i in sections {
				testing.expect(t, area_inside(a, window))
				testing.expect(t, a.width == size[0] - 2 * MARGIN)
				for b in sections[i + 1:] {
					testing.expect(t, areas_apart(a, b))
				}
			}

			// Section headers and run areas stay inside their sections and never overlap.
			testing.expect(t, area_inside(places.kernel_header, places.kernel_section))
			testing.expect(t, area_inside(places.kernel_runs, places.kernel_section))
			testing.expect(t, areas_apart(places.kernel_header, places.kernel_runs))
			testing.expect_value(t, places.kernel_header.height, HEADER_HEIGHT)

			testing.expect(t, area_inside(places.process_header, places.process_section))
			testing.expect(t, area_inside(places.process_runs, places.process_section))
			testing.expect(t, areas_apart(places.process_header, places.process_runs))
			testing.expect_value(t, places.process_header.height, HEADER_HEIGHT)

			// All four rule rows fit inside rules_section at full line height and never overlap.
			testing.expect_value(t, places.rules_section.height, RULE_COUNT * LINE)
			for r, i in places.rule_rows {
				testing.expect(t, area_inside(r, places.rules_section))
				testing.expect_value(t, r.height, LINE)
				for other in places.rule_rows[i + 1:] {
					testing.expect(t, areas_apart(r, other))
				}
			}

			// Run columns are strictly ordered, non-overlapping, and fit inside the section width.
			testing.expect_value(t, int(places.columns[.Mark].x), MARGIN)
			testing.expect_value(t, int(places.columns[.Mark].width), MARK_COLUMN_WIDTH)
			testing.expect_value(t, int(places.columns[.Range].width), RANGE_COLUMN_WIDTH)
			testing.expect_value(t, int(places.columns[.Rights].width), RIGHTS_COLUMN_WIDTH)
			testing.expect(t, int(places.columns[.Part].width) >= PART_COLUMN_WIDTH)
			for c := Run_Column.Mark; c < Run_Column.Part; c = Run_Column(u8(c) + 1) {
				next := Run_Column(u8(c) + 1)
				testing.expect(t, places.columns[c].x + places.columns[c].width <= places.columns[next].x)
			}
			testing.expect_value(t, int(places.columns[.Part].x + places.columns[.Part].width), size[0] - MARGIN)
		}

		// Scale mapping stays monotonic inside the scaled surface.
		for scale in scale_factor.Scale {
			sw := scale_factor.screen_pixel_of_logical_pixel(i32(size[0]), scale)
			sh := scale_factor.screen_pixel_of_logical_pixel(i32(size[1]), scale)
			testing.expect(t, sw >= i64(size[0]) && sh >= i64(size[1]))
		}
	}
}

@(test)
pages_layout_handles_narrow_and_short_edges :: proc(t: ^testing.T) {
	tree := new(layout.Box_Tree)
	defer free(tree)
	edges := [][2]int{
		{1, 1},
		{2 * MARGIN, 2 * MARGIN},
		{64, 64},
		{160, 180},
		{320, 240},
		{WIDTH, 160},
		{240, HEIGHT},
	}
	for size in edges {
		window := interface.Area{0, 0, size[0], size[1]}
		places, ok := pages_layout(tree, size[0], size[1])
		testing.expectf(t, ok, "pages_layout refused edge size %v", size)

		sections := [3]interface.Area{places.kernel_section, places.rules_section, places.process_section}
		for a, i in sections {
			testing.expectf(t, area_inside(a, window), "section %d left edge window %v", i, size)
			for b in sections[i + 1:] {
				testing.expectf(t, areas_apart(a, b), "sections overlapped at edge %v", size)
			}
		}

		testing.expect(t, area_inside(places.kernel_header, places.kernel_section))
		testing.expect(t, area_inside(places.kernel_runs, places.kernel_section))
		testing.expect(t, areas_apart(places.kernel_header, places.kernel_runs))

		testing.expect(t, area_inside(places.process_header, places.process_section))
		testing.expect(t, area_inside(places.process_runs, places.process_section))
		testing.expect(t, areas_apart(places.process_header, places.process_runs))

		for r, i in places.rule_rows {
			testing.expect(t, area_inside(r, places.rules_section))
			for other in places.rule_rows[i + 1:] {
				testing.expect(t, areas_apart(r, other))
			}
		}

		// Columns keep strict non-overlapping order even on narrow windows.
		for c := Run_Column.Mark; c < Run_Column.Part; c = Run_Column(u8(c) + 1) {
			next := Run_Column(u8(c) + 1)
			testing.expect(t, places.columns[c].width > 0)
			testing.expect(t, places.columns[c].x + places.columns[c].width <= places.columns[next].x)
		}
		testing.expect(t, places.columns[.Part].width >= PART_COLUMN_WIDTH)
	}
}
