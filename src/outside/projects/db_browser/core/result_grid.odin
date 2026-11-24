// Immutable worker-produced Result_Snapshot, off-thread deterministic sorting,
// and O(1) viewport cell display lookup for db_browser
// (src/md/features/db_browser.md).
package db_browser_core

// Inline capacities sized for interactive browsing inside db_browser's budget.
// Exceeding SNAPSHOT_MAX_CELLS or SNAPSHOT_MAX_ROWS drops no partial row and
// sets truncated_rows = true.
SNAPSHOT_MAX_COLUMNS :: 64
SNAPSHOT_MAX_ROWS :: 1024
SNAPSHOT_MAX_CELLS :: 16384
SNAPSHOT_PAYLOAD_BYTES :: 262144 // 256 KiB payload bytes per snapshot.
SNAPSHOT_MAX_TABLES :: 128
SNAPSHOT_MAX_SCHEMA_COLUMNS :: 128

COLUMN_MIN_WIDTH :: 72
COLUMN_MAX_WIDTH :: 320
COLUMN_CHAR_WIDTH :: 8
COLUMN_HEADER_PAD :: 28

Sort_Direction :: enum u8 {
	None       = 0,
	Ascending  = 1,
	Descending = 2,
}

Cell_Alignment :: enum u8 {
	Left  = 0,
	Right = 1,
}

Table_Entry :: struct {
	name:     [SQLITE_COLUMN_NAME_BYTES]u8,
	name_len: u8,
	is_view:  bool,
}

Schema_Column_Entry :: struct {
	name:        [SQLITE_COLUMN_NAME_BYTES]u8,
	name_len:    u8,
	type_name:   [32]u8,
	type_len:    u8,
	primary_key: bool,
	not_null:    bool,
}

// Immutable snapshot produced off the UI thread; the UI thread only reads
// visible viewport rows through snapshot_cell_display.
Result_Snapshot :: struct {
	serial:              u64,
	columns:             [SNAPSHOT_MAX_COLUMNS]Column_Row,
	column_count:        int,
	column_widths:       [SNAPSHOT_MAX_COLUMNS]i32,
	cells:               [SNAPSHOT_MAX_CELLS]Cell_Row,
	cell_count:          int,
	payload:             [SNAPSHOT_PAYLOAD_BYTES]u8,
	payload_len:         int,
	row_order:           [SNAPSHOT_MAX_ROWS]u32,
	row_count:           int,
	sort_column:         int, // -1 when unsorted.
	sort_direction:      Sort_Direction,
	truncated_rows:      bool,
	has_rows:            bool,
	changes:             i64,
	database_bytes:      u64,
	generation:          i64,
	tables:              [SNAPSHOT_MAX_TABLES]Table_Entry,
	table_count:         int,
	schema_columns:      [SNAPSHOT_MAX_SCHEMA_COLUMNS]Schema_Column_Entry,
	schema_column_count: int,
	selected_table:      int,
}

snapshot_reset_query :: proc "contextless" (snap: ^Result_Snapshot) {
	snap.column_count = 0
	snap.cell_count = 0
	snap.payload_len = 0
	snap.row_count = 0
	snap.sort_column = -1
	snap.sort_direction = .None
	snap.truncated_rows = false
	snap.has_rows = false
	snap.changes = 0
}

// snapshot_populate_query copies typed SQLite results into snap and computes
// column display widths off-thread. Never keeps a partial row.
snapshot_populate_query :: proc "contextless" (
	snap: ^Result_Snapshot,
	columns: []Column_Row,
	cells: []Cell_Row,
	payload: []u8,
	summary: Query_Summary,
) {
	snapshot_reset_query(snap)
	snap.database_bytes = summary.database_bytes
	snap.changes = summary.changes
	snap.has_rows = summary.has_rows != 0
	snap.truncated_rows = summary.truncated_rows != 0

	col_count := min(len(columns), SNAPSHOT_MAX_COLUMNS)
	snap.column_count = col_count
	for i in 0 ..< col_count {
		snap.columns[i] = columns[i]
		name_len := min(int(columns[i].name_length), SQLITE_COLUMN_NAME_BYTES)
		snap.column_widths[i] = clamp(i32(name_len * COLUMN_CHAR_WIDTH + COLUMN_HEADER_PAD), COLUMN_MIN_WIDTH, COLUMN_MAX_WIDTH)
	}

	pay_len := min(len(payload), SNAPSHOT_PAYLOAD_BYTES)
	if pay_len > 0 {
		copy(snap.payload[:pay_len], payload[:pay_len])
	}
	snap.payload_len = pay_len

	if col_count == 0 {
		return
	}

	// Only accept complete rows fitting both SNAPSHOT_MAX_ROWS and SNAPSHOT_MAX_CELLS.
	complete_rows := len(cells) / col_count
	max_rows_by_cells := SNAPSHOT_MAX_CELLS / col_count
	kept_rows := min(complete_rows, min(SNAPSHOT_MAX_ROWS, max_rows_by_cells))
	if kept_rows < int(summary.row_count) || complete_rows * col_count < len(cells) {
		snap.truncated_rows = true
	}
	kept_cells := kept_rows * col_count
	if kept_cells > 0 {
		copy(snap.cells[:kept_cells], cells[:kept_cells])
	}
	snap.cell_count = kept_cells
	snap.row_count = kept_rows
	for r in 0 ..< kept_rows {
		snap.row_order[r] = u32(r)
	}

	// Measure first 64 rows off-thread to auto-size columns without cutting values.
	sample_rows := min(kept_rows, 64)
	tmp: [96]u8
	for r in 0 ..< sample_rows {
		for c in 0 ..< col_count {
			text, _, _, _ := snapshot_cell_display(snap, r, c, tmp[:])
			needed := i32(len(text) * COLUMN_CHAR_WIDTH + 20)
			if needed > snap.column_widths[c] {
				snap.column_widths[c] = min(needed, COLUMN_MAX_WIDTH)
			}
		}
	}
}

// snapshot_column_name returns the validated UTF-8 name slice of column c.
snapshot_column_name :: proc "contextless" (snap: ^Result_Snapshot, col: int) -> string {
	if col < 0 || col >= snap.column_count {
		return ""
	}
	n := min(int(snap.columns[col].name_length), SQLITE_COLUMN_NAME_BYTES)
	return string(snap.columns[col].name[:n])
}

// snapshot_table_name returns the name of sidebar table index i.
snapshot_table_name :: proc "contextless" (snap: ^Result_Snapshot, index: int) -> string {
	if index < 0 || index >= snap.table_count {
		return ""
	}
	n := min(int(snap.tables[index].name_len), SQLITE_COLUMN_NAME_BYTES)
	return string(snap.tables[index].name[:n])
}

// snapshot_cell_at returns the Cell_Row at (visual_row, col) using row_order.
snapshot_cell_at :: proc "contextless" (snap: ^Result_Snapshot, visual_row: int, col: int) -> (cell: Cell_Row, ok: bool) {
	if visual_row < 0 || visual_row >= snap.row_count || col < 0 || col >= snap.column_count {
		return {}, false
	}
	phys_row := int(snap.row_order[visual_row])
	idx := phys_row * snap.column_count + col
	if idx < 0 || idx >= snap.cell_count {
		return {}, false
	}
	return snap.cells[idx], true
}

// snapshot_cell_display formats one visible cell into out with its alignment
// and typed Value_Kind. O(1) lookup safe for UI viewport rendering.
snapshot_cell_display :: proc "contextless" (
	snap: ^Result_Snapshot,
	visual_row: int,
	col: int,
	out: []u8,
) -> (text: string, alignment: Cell_Alignment, kind: Value_Kind, truncated: bool) {
	cell, ok := snapshot_cell_at(snap, visual_row, col)
	if !ok {
		return "", .Left, .None, false
	}
	vk, vk_ok := value_kind_of_word(cell.value_kind)
	if !vk_ok {
		return "", .Left, .None, false
	}
	truncated = cell.truncated != 0
	switch vk {
	case .None:
		return "", .Left, .None, false
	case .Null:
		return string(out[:copy(out, "NULL")]), .Left, .Null, false
	case .Integer:
		return format_i64(cell.integer_or_bits, out), .Right, .Integer, false
	case .Real_Bits:
		return format_f64_bits(u64(cell.integer_or_bits), out), .Right, .Real_Bits, false
	case .Text:
		start := int(cell.payload_offset)
		length := int(cell.payload_length)
		if start < 0 || length < 0 || start > snap.payload_len || length > snap.payload_len - start {
			return "", .Left, .Text, truncated
		}
		written := sanitize_single_line_text(snap.payload[start:][:length], out)
		return string(out[:written]), .Left, .Text, truncated
	case .Blob:
		return format_blob_badge(cell.integer_or_bits, out), .Right, .Blob, truncated
	}
	return "", .Left, .None, false
}

// next_sort_direction cycles None -> Ascending -> Descending -> None on header clicks.
next_sort_direction :: proc "contextless" (current_col: int, current_dir: Sort_Direction, clicked_col: int) -> Sort_Direction {
	if current_col != clicked_col {
		return .Ascending
	}
	switch current_dir {
	case .None:
		return .Ascending
	case .Ascending:
		return .Descending
	case .Descending:
		return .None
	}
	return .Ascending
}

// storage_class_rank follows SQLite's storage class ordering:
// NULL < NUMERIC (Integer/Real) < TEXT < BLOB.
@(private = "file")
storage_class_rank :: proc "contextless" (kind: Value_Kind) -> int {
	switch kind {
	case .None, .Null:
		return 0
	case .Integer, .Real_Bits:
		return 1
	case .Text:
		return 2
	case .Blob:
		return 3
	}
	return 0
}

@(private = "file")
compare_bytes :: proc "contextless" (a, b: []u8) -> int {
	n := min(len(a), len(b))
	for i in 0 ..< n {
		if a[i] < b[i] {
			return -1
		}
		if a[i] > b[i] {
			return 1
		}
	}
	if len(a) < len(b) {
		return -1
	}
	if len(a) > len(b) {
		return 1
	}
	return 0
}

@(private = "file")
compare_rows_by_col :: proc "contextless" (snap: ^Result_Snapshot, row_a, row_b: u32, col: int, desc: bool) -> int {
	idx_a := int(row_a) * snap.column_count + col
	idx_b := int(row_b) * snap.column_count + col
	if idx_a < 0 || idx_a >= snap.cell_count || idx_b < 0 || idx_b >= snap.cell_count {
		return row_a < row_b ? -1 : (row_a > row_b ? 1 : 0)
	}
	ca := snap.cells[idx_a]
	cb := snap.cells[idx_b]
	ka, _ := value_kind_of_word(ca.value_kind)
	kb, _ := value_kind_of_word(cb.value_kind)

	// Always place NULLs after non-NULLs so sorted values appear at the top.
	a_null := ka == .Null || ka == .None
	b_null := kb == .Null || kb == .None
	if a_null != b_null {
		return a_null ? 1 : -1
	}
	if a_null && b_null {
		return row_a < row_b ? -1 : (row_a > row_b ? 1 : 0)
	}

	cmp := 0
	ra := storage_class_rank(ka)
	rb := storage_class_rank(kb)
	if ra != rb {
		cmp = ra < rb ? -1 : 1
	} else {
		switch ka {
		case .None, .Null:
			cmp = 0
		case .Integer, .Real_Bits:
			if ka == .Integer && kb == .Integer {
				if ca.integer_or_bits < cb.integer_or_bits {
					cmp = -1
				} else if ca.integer_or_bits > cb.integer_or_bits {
					cmp = 1
				}
			} else {
				fa := ka == .Integer ? f64(ca.integer_or_bits) : transmute(f64)u64(ca.integer_or_bits)
				fb := kb == .Integer ? f64(cb.integer_or_bits) : transmute(f64)u64(cb.integer_or_bits)
				// Deterministic NaN handling: NaN sorts after finite numbers.
				a_nan := fa != fa
				b_nan := fb != fb
				if a_nan != b_nan {
					cmp = a_nan ? 1 : -1
				} else if fa < fb {
					cmp = -1
				} else if fa > fb {
					cmp = 1
				}
			}
		case .Text, .Blob:
			sa := snap.payload[min(int(ca.payload_offset), snap.payload_len):][:min(int(ca.payload_length), snap.payload_len - min(int(ca.payload_offset), snap.payload_len))]
			sb := snap.payload[min(int(cb.payload_offset), snap.payload_len):][:min(int(cb.payload_length), snap.payload_len - min(int(cb.payload_offset), snap.payload_len))]
			cmp = compare_bytes(sa, sb)
			if cmp == 0 && ca.integer_or_bits != cb.integer_or_bits {
				cmp = ca.integer_or_bits < cb.integer_or_bits ? -1 : 1
			}
		}
	}

	if cmp != 0 {
		return desc ? -cmp : cmp
	}
	// Stable deterministic tie-breaker by physical row index.
	return row_a < row_b ? -1 : (row_a > row_b ? 1 : 0)
}

// snapshot_sort_by_column sorts snap.row_order off-thread in O(N log N) worst-case
// time with zero recursion (iterative heapsort). Direction .None restores original row order.
snapshot_sort_by_column :: proc "contextless" (snap: ^Result_Snapshot, col: int, direction: Sort_Direction) -> bool {
	if snap == nil {
		return false
	}
	if direction == .None {
		for r in 0 ..< snap.row_count {
			snap.row_order[r] = u32(r)
		}
		snap.sort_column = -1
		snap.sort_direction = .None
		return true
	}
	if col < 0 || col >= snap.column_count {
		return false
	}
	snap.sort_column = col
	snap.sort_direction = direction
	n := snap.row_count
	if n <= 1 {
		return true
	}
	desc := direction == .Descending
	order := snap.row_order[:n]

	sift_down :: proc "contextless" (snap: ^Result_Snapshot, order: []u32, start, end, col: int, desc: bool) {
		root := start
		for {
			child := 2 * root + 1
			if child > end {
				break
			}
			swap := root
			if compare_rows_by_col(snap, order[swap], order[child], col, desc) < 0 {
				swap = child
			}
			if child + 1 <= end && compare_rows_by_col(snap, order[swap], order[child + 1], col, desc) < 0 {
				swap = child + 1
			}
			if swap == root {
				break
			}
			order[root], order[swap] = order[swap], order[root]
			root = swap
		}
	}

	for start := (n - 2) / 2; start >= 0; start -= 1 {
		sift_down(snap, order, start, n - 1, col, desc)
	}
	for end := n - 1; end > 0; end -= 1 {
		order[end], order[0] = order[0], order[end]
		sift_down(snap, order, 0, end - 1, col, desc)
	}
	return true
}

// snapshot_total_grid_width returns the total pixel width of all columns.
snapshot_total_grid_width :: proc "contextless" (snap: ^Result_Snapshot) -> i32 {
	total: i32 = 0
	for c in 0 ..< snap.column_count {
		total += snap.column_widths[c]
	}
	return total
}
