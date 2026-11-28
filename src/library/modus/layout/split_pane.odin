// The split pane and the table columns: the places of the parts of a box
// that the principal resizes with a divider (src/md/features/box_layout.md,
// "The chosen form").
package layout

// The split ratio, in parts of 10 000, is never under SPLIT_RATIO_LEAST or
// over SPLIT_RATIO_MOST, so neither part of a split pane disappears.
SPLIT_RATIO_LEAST :: 1_000
SPLIT_RATIO_MOST :: 9_000

// The places of a split pane: its two parts and the divider between them.
Split_Pane :: struct {
	first:   Rect,
	divider: Rect,
	second:  Rect,
}

// split_ratio_clamp gives the nearest split ratio that a split pane takes.
split_ratio_clamp :: proc "contextless" (ratio: i32) -> i32 {
	return clamp(ratio, SPLIT_RATIO_LEAST, SPLIT_RATIO_MOST)
}

// split_pane gives the places of a split pane in a rect, along an axis, with
// a divider of a thickness in pixels. The ratio is the part of the room
// without the divider that the first part takes.
split_pane :: proc "contextless" (rect: Rect, axis: Axis, ratio: i32, divider_thickness: i32) -> (Split_Pane, Box_Status) {
	if u8(axis) > u8(max(Axis)) {
		return {}, .Unknown_Member
	}
	if rect.width < 0 || rect.height < 0 || rect.width > LENGTH_LIMIT || rect.height > LENGTH_LIMIT {
		return {}, .Length_Refused
	}
	length := axis == .X ? rect.width : rect.height
	if divider_thickness < 0 || divider_thickness > length {
		return {}, .Length_Refused
	}
	room := length - divider_thickness
	first_length := i32(i64(room) * i64(split_ratio_clamp(ratio)) / RATIO_WHOLE)
	pane := Split_Pane{first = rect, divider = rect, second = rect}
	if axis == .X {
		pane.first.width = first_length
		pane.divider.x = rect.x + first_length
		pane.divider.width = divider_thickness
		pane.second.x = pane.divider.x + divider_thickness
		pane.second.width = room - first_length
	} else {
		pane.first.height = first_length
		pane.divider.y = rect.y + first_length
		pane.divider.height = divider_thickness
		pane.second.y = pane.divider.y + divider_thickness
		pane.second.height = room - first_length
	}
	return pane, .Done
}

// split_ratio_dragged gives the split ratio after a drag of the divider by a
// distance in pixels, in a room in pixels (the length of the pane without
// its divider). A room of 0 keeps the ratio.
split_ratio_dragged :: proc "contextless" (ratio: i32, drag_distance: i32, room: i32) -> i32 {
	if room <= 0 {
		return split_ratio_clamp(ratio)
	}
	moved := i64(split_ratio_clamp(ratio)) + i64(drag_distance) * RATIO_WHOLE / i64(room)
	return split_ratio_clamp(i32(clamp(moved, i64(min(i32)), i64(max(i32)))))
}

// One column of a table: a fixed width, or a weight of the room that the
// fixed columns leave.
Table_Column :: struct {
	width:  i32, // The width of a fixed column, in pixels.
	weight: i32, // 0: the column is fixed. Over 0: its share of the room left.
	least:  i32, // Pixels that a flexible column never goes under.
}

// The place of one column, and the divider at its right edge, which the
// principal drags to resize it.
Table_Column_Place :: struct {
	x:       i32,
	width:   i32,
	divider: Rect,
}

// table_columns gives the place of each column of a table in a rect. The
// flexible columns share what the fixed ones leave by their weights, each
// never under its least: a table that is too narrow then passes its edge,
// and its box clips or scrolls it.
table_columns :: proc "contextless" (columns: []Table_Column, places: []Table_Column_Place, rect: Rect, divider_thickness: i32) -> Box_Status {
	if len(places) < len(columns) {
		return .Places_Too_Few
	}
	if rect.width < 0 || rect.height < 0 || rect.width > LENGTH_LIMIT || rect.height > LENGTH_LIMIT || divider_thickness < 0 || divider_thickness > LENGTH_LIMIT {
		return .Length_Refused
	}
	fixed, weights: i64
	for column in columns {
		if column.width < 0 || column.width > LENGTH_LIMIT || column.least < 0 || column.least > LENGTH_LIMIT || column.weight < 0 || column.weight > RATIO_WHOLE {
			return .Length_Refused
		}
		if column.weight == 0 {
			fixed += i64(column.width)
		} else {
			weights += i64(column.weight)
		}
	}
	rest := max(i64(rect.width) - fixed, 0)
	x := i64(rect.x)
	running, given_before: i64
	for column, index in columns {
		width := i64(column.width)
		if column.weight > 0 {
			// The running sum gives the flexible columns all of the room, with no pixel lost to a rounding.
			running += i64(column.weight)
			given_to_here := rest * running / weights
			width = max(given_to_here - given_before, i64(column.least))
			given_before = given_to_here
		}
		right := x + width
		places[index] = {
			x       = i32(x),
			width   = i32(width),
			divider = {i32(right - i64(divider_thickness) / 2), rect.y, divider_thickness, rect.height},
		}
		x = right
	}
	return .Done
}

// table_column_dragged gives the width of a fixed column after a drag of its
// divider by a distance in pixels, never under its least and never over
// LENGTH_LIMIT.
table_column_dragged :: proc "contextless" (column: Table_Column, drag_distance: i32) -> i32 {
	return i32(clamp(i64(column.width) + i64(drag_distance), i64(column.least), LENGTH_LIMIT))
}
