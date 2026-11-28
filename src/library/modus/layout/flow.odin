// Flow wrapping: places variable-size items across as many horizontal lines as
// needed inside a bounding rectangle with integer gaps and per-line alignment
// (src/md/features/box_layout.md). Zero floats, zero heap allocation.
package layout

// One item given to flow_wrap: its measured logical width and height.
Flow_Item :: struct {
	width:  i32,
	height: i32,
}

// The solved placement of one item from flow_wrap.
Flow_Place :: struct {
	x:      i32,
	y:      i32,
	width:  i32,
	height: i32,
	line:   i32, // 0-based wrapped row index.
}

// flow_wrap places items left-to-right across multiple rows inside rect,
// starting a new row whenever the next item would exceed rect.width. Each row
// aligns horizontally by align (.Start, .Center, .End) and vertically centers
// shorter items to the tallest item in that row.
// Refuses unknown Align members, negative/oversized dimensions, or a places
// slice shorter than items without writing to places.
flow_wrap :: proc "contextless" (
	items: []Flow_Item,
	places: []Flow_Place,
	rect: Rect,
	gap_x: i32,
	gap_y: i32,
	align: Align = .Start,
) -> (total_height: i32, line_count: i32, status: Box_Status) {
	if u8(align) > u8(max(Align)) {
		return 0, 0, .Unknown_Member
	}
	if len(places) < len(items) {
		return 0, 0, .Places_Too_Few
	}
	if rect.width < 0 || rect.height < 0 || rect.width > LENGTH_LIMIT || rect.height > LENGTH_LIMIT ||
	   gap_x < 0 || gap_x > LENGTH_LIMIT || gap_y < 0 || gap_y > LENGTH_LIMIT {
		return 0, 0, .Length_Refused
	}
	for item in items {
		if item.width < 0 || item.height < 0 || item.width > LENGTH_LIMIT || item.height > LENGTH_LIMIT {
			return 0, 0, .Length_Refused
		}
	}
	if len(items) == 0 {
		return 0, 0, .Done
	}

	line_idx: i32 = 0
	y: i64 = i64(rect.y)
	i := 0
	for i < len(items) {
		row_start := i
		row_width: i64 = 0
		row_height: i32 = 0
		for i < len(items) {
			w := i64(items[i].width)
			next_w := i == row_start ? w : row_width + i64(gap_x) + w
			if i > row_start && next_w > i64(rect.width) {
				break
			}
			row_width = next_w
			if items[i].height > row_height {
				row_height = items[i].height
			}
			i += 1
		}
		extra := max(i64(rect.width) - row_width, 0)
		start_x := i64(rect.x)
		switch align {
		case .Start:
		case .Center:
			start_x += extra / 2
		case .End:
			start_x += extra
		}
		x := start_x
		for j in row_start ..< i {
			item := items[j]
			item_y := y + i64(row_height - item.height) / 2
			places[j] = {
				x      = i32(x),
				y      = i32(item_y),
				width  = item.width,
				height = item.height,
				line   = line_idx,
			}
			x += i64(item.width) + i64(gap_x)
		}
		y += i64(row_height)
		if i < len(items) {
			y += i64(gap_y)
		}
		line_idx += 1
	}
	return i32(y - i64(rect.y)), line_idx, .Done
}
