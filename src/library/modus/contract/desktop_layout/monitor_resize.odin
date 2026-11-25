// Resizable monitor window layout and double-buffered surface page budget
// calculator (src/md/features/desktop_to_browser.md and src/md/features/box_layout.md).
//
// Validates that a requested monitor window (width, height) at a given scale
// fits inside the stated double-buffered surface page budget and computes
// non-overlapping header, graph, and process table rectangles together with
// deterministic visible process row and graph column counts.
package desktop_layout

// Format property: hardware memory page size and 32-bit BGRA surface pixel width.
MONITOR_PAGE_BYTES :: u64(4096)
MONITOR_BYTES_PER_PIXEL :: u64(4)

// Plan value: double-buffered front and back window surfaces.
MONITOR_SURFACE_COUNT :: u64(2)

// Plan value: scale factor range in eighths matching scale_factor.Scale (1.0x..2.0x).
MONITOR_SCALE_EIGHTHS_MIN :: u32(8)
MONITOR_SCALE_EIGHTHS_MAX :: u32(16)

// Plan value: smallest readable monitor window dimensions and 4K logical ceiling.
MONITOR_MIN_WIDTH :: i32(480)
MONITOR_MIN_HEIGHT :: i32(320)
MONITOR_MAX_WIDTH :: i32(3840)
MONITOR_MAX_HEIGHT :: i32(2160)

// Plan value: logical layout geometry constants for monitor sections.
MONITOR_PADDING :: i32(12)
MONITOR_SECTION_GAP :: i32(12)
MONITOR_HEADER_HEIGHT :: i32(48)
MONITOR_GRAPH_MIN_HEIGHT :: i32(96)
MONITOR_GRAPH_MAX_HEIGHT :: i32(240)
MONITOR_TABLE_HEADER_HEIGHT :: i32(24)
MONITOR_ROW_HEIGHT :: i32(22)
MONITOR_GRAPH_COLUMN_WIDTH :: i32(4)

// Closed refusal set returned by resizable monitor layout procedures.
Monitor_Resize_Refusal :: enum u8 {
	None                = 0,
	Dimension_Too_Small = 1,
	Dimension_Too_Large = 2,
	Scale_Out_Of_Range  = 3,
	Zero_Budget         = 4,
	Budget_Exceeded     = 5,
}

// Surface memory budget and active scale factor (in eighths) for monitor.
Monitor_Surface_Budget :: struct {
	max_surface_pages: u64,
	scale_eighths:     u32,
}

// Computed non-overlapping layout and resource metrics for one monitor size.
Monitor_Layout :: struct {
	window_width:         i32,
	window_height:        i32,
	scaled_width:         u32,
	scaled_height:        u32,
	surface_pages:        u64,
	header:               Rect,
	graph:                Rect,
	process_table:        Rect,
	visible_process_rows: int,
	graph_columns:        int,
}

// monitor_surface_pages_needed computes the double-buffered surface pages
// needed for a logical (width, height) window at scale_eighths (8..=16).
monitor_surface_pages_needed :: proc "contextless" (
	width: i32,
	height: i32,
	scale_eighths: u32,
) -> (
	pages: u64,
	scaled_width: u32,
	scaled_height: u32,
	refusal: Monitor_Resize_Refusal,
) {
	if width < MONITOR_MIN_WIDTH || height < MONITOR_MIN_HEIGHT {
		return 0, 0, 0, .Dimension_Too_Small
	}
	if width > MONITOR_MAX_WIDTH || height > MONITOR_MAX_HEIGHT {
		return 0, 0, 0, .Dimension_Too_Large
	}
	if scale_eighths < MONITOR_SCALE_EIGHTHS_MIN || scale_eighths > MONITOR_SCALE_EIGHTHS_MAX {
		return 0, 0, 0, .Scale_Out_Of_Range
	}
	// Round up to cover every physical pixel edge at scale_eighths / 8.
	sw := (u64(width) * u64(scale_eighths) + 7) / 8
	sh := (u64(height) * u64(scale_eighths) + 7) / 8
	one_surface_bytes := sw * sh * MONITOR_BYTES_PER_PIXEL
	one_surface_pages := (one_surface_bytes + MONITOR_PAGE_BYTES - 1) / MONITOR_PAGE_BYTES
	return one_surface_pages * MONITOR_SURFACE_COUNT, u32(sw), u32(sh), .None
}

// monitor_compute_layout validates (width, height) against budget and computes
// deterministic header, graph, and process table rectangles plus row/column counts.
monitor_compute_layout :: proc "contextless" (
	width: i32,
	height: i32,
	budget: Monitor_Surface_Budget,
) -> (
	layout: Monitor_Layout,
	refusal: Monitor_Resize_Refusal,
) {
	if budget.max_surface_pages == 0 {
		return {}, .Zero_Budget
	}
	pages, scaled_w, scaled_h, page_r := monitor_surface_pages_needed(width, height, budget.scale_eighths)
	if page_r != .None {
		return {}, page_r
	}
	if pages > budget.max_surface_pages {
		return {}, .Budget_Exceeded
	}

	inner_w := width - 2 * MONITOR_PADDING
	header_y := MONITOR_PADDING
	header := Rect{x = MONITOR_PADDING, y = header_y, width = inner_w, height = MONITOR_HEADER_HEIGHT}

	remaining_h := height - 2 * MONITOR_PADDING - MONITOR_HEADER_HEIGHT - 2 * MONITOR_SECTION_GAP
	graph_h := remaining_h / 3
	if graph_h < MONITOR_GRAPH_MIN_HEIGHT {
		graph_h = MONITOR_GRAPH_MIN_HEIGHT
	} else if graph_h > MONITOR_GRAPH_MAX_HEIGHT {
		graph_h = MONITOR_GRAPH_MAX_HEIGHT
	}
	graph_y := header.y + header.height + MONITOR_SECTION_GAP
	graph := Rect{x = MONITOR_PADDING, y = graph_y, width = inner_w, height = graph_h}

	table_y := graph.y + graph.height + MONITOR_SECTION_GAP
	table_h := height - MONITOR_PADDING - table_y
	table := Rect{x = MONITOR_PADDING, y = table_y, width = inner_w, height = table_h}

	rows := 0
	if table.height > MONITOR_TABLE_HEADER_HEIGHT {
		rows = int((table.height - MONITOR_TABLE_HEADER_HEIGHT) / MONITOR_ROW_HEIGHT)
	}
	cols := int(graph.width / MONITOR_GRAPH_COLUMN_WIDTH)

	return Monitor_Layout {
		window_width         = width,
		window_height        = height,
		scaled_width         = scaled_w,
		scaled_height        = scaled_h,
		surface_pages        = pages,
		header               = header,
		graph                = graph,
		process_table        = table,
		visible_process_rows = rows,
		graph_columns        = cols,
	}, .None
}
