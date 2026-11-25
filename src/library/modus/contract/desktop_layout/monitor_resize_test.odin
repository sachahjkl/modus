#+build !freestanding
package desktop_layout

import "core:testing"

@(test)
monitor_resize_refuses_invalid_bounds_scale_and_budget :: proc(t: ^testing.T) {
	ok_budget := Monitor_Surface_Budget{max_surface_pages = 8192, scale_eighths = 10}

	// Too small.
	_, r := monitor_compute_layout(MONITOR_MIN_WIDTH - 1, MONITOR_MIN_HEIGHT, ok_budget)
	testing.expect_value(t, r, Monitor_Resize_Refusal.Dimension_Too_Small)
	_, r = monitor_compute_layout(MONITOR_MIN_WIDTH, MONITOR_MIN_HEIGHT - 1, ok_budget)
	testing.expect_value(t, r, Monitor_Resize_Refusal.Dimension_Too_Small)
	_, r = monitor_compute_layout(0, 0, ok_budget)
	testing.expect_value(t, r, Monitor_Resize_Refusal.Dimension_Too_Small)

	// Too large.
	_, r = monitor_compute_layout(MONITOR_MAX_WIDTH + 1, 1080, ok_budget)
	testing.expect_value(t, r, Monitor_Resize_Refusal.Dimension_Too_Large)
	_, r = monitor_compute_layout(1920, MONITOR_MAX_HEIGHT + 1, ok_budget)
	testing.expect_value(t, r, Monitor_Resize_Refusal.Dimension_Too_Large)

	// Scale out of [8..=16].
	_, r = monitor_compute_layout(800, 600, {max_surface_pages = 8192, scale_eighths = 7})
	testing.expect_value(t, r, Monitor_Resize_Refusal.Scale_Out_Of_Range)
	_, r = monitor_compute_layout(800, 600, {max_surface_pages = 8192, scale_eighths = 17})
	testing.expect_value(t, r, Monitor_Resize_Refusal.Scale_Out_Of_Range)

	// Zero budget.
	_, r = monitor_compute_layout(800, 600, {max_surface_pages = 0, scale_eighths = 8})
	testing.expect_value(t, r, Monitor_Resize_Refusal.Zero_Budget)

	// Tight budget refused at 1920x1080 @ 2.0x (needs 3840*2160*4/4096 * 2 = 16200 pages).
	pages_2x, sw, sh, pr := monitor_surface_pages_needed(1920, 1080, 16)
	testing.expect_value(t, pr, Monitor_Resize_Refusal.None)
	testing.expect_value(t, sw, u32(3840))
	testing.expect_value(t, sh, u32(2160))
	testing.expect_value(t, pages_2x, u64(16200))

	_, r = monitor_compute_layout(1920, 1080, {max_surface_pages = pages_2x - 1, scale_eighths = 16})
	testing.expect_value(t, r, Monitor_Resize_Refusal.Budget_Exceeded)
}

@(test)
monitor_compute_layout_non_overlapping_and_monotonic_with_size :: proc(t: ^testing.T) {
	budget := Monitor_Surface_Budget{max_surface_pages = 8192, scale_eighths = 10} // 1.25x

	small, r1 := monitor_compute_layout(MONITOR_MIN_WIDTH, MONITOR_MIN_HEIGHT, budget)
	testing.expect_value(t, r1, Monitor_Resize_Refusal.None)
	medium, r2 := monitor_compute_layout(960, 640, budget)
	testing.expect_value(t, r2, Monitor_Resize_Refusal.None)
	large, r3 := monitor_compute_layout(1536, 864, budget)
	testing.expect_value(t, r3, Monitor_Resize_Refusal.None)

	// Verify strict non-overlap and bounds inside window for every size.
	for lay in ([?]Monitor_Layout{small, medium, large}) {
		testing.expect(t, lay.header.x >= MONITOR_PADDING && lay.header.y >= MONITOR_PADDING)
		testing.expect(t, lay.header.y + lay.header.height + MONITOR_SECTION_GAP == lay.graph.y)
		testing.expect(t, lay.graph.y + lay.graph.height + MONITOR_SECTION_GAP == lay.process_table.y)
		testing.expect(t, lay.process_table.y + lay.process_table.height + MONITOR_PADDING == lay.window_height)
		testing.expect(t, lay.visible_process_rows > 0)
		testing.expect(t, lay.graph_columns > 0)
		testing.expect(t, lay.surface_pages <= budget.max_surface_pages)
	}

	// Larger windows strictly yield more visible rows and more graph columns.
	testing.expect(t, small.visible_process_rows < medium.visible_process_rows)
	testing.expect(t, medium.visible_process_rows < large.visible_process_rows)
	testing.expect(t, small.graph_columns < medium.graph_columns)
	testing.expect(t, medium.graph_columns < large.graph_columns)
}
