// Bounded UI <-> worker ring queues and pure SQLite execution + atomic
// dirty-range storage sync orchestration (src/md/features/db_browser.md).
package db_browser_core

import "modus:contract/call_outcome"
import "modus:contract/errors"

// Inline capacity: pending interactive requests between UI and worker thread.
// Full queues return false so UI reports .Queue_Full instead of blocking.
QUEUE_CAPACITY :: 16

// Inline capacity: SQL text carried in one queued request.
SQL_REQUEST_MAX_BYTES :: 32768

// Inline capacity: dirty-range rows fetched per sync chunk.
DIRTY_RANGE_CHUNK :: 64

Request_Kind :: enum u8 {
	None            = 0,
	Open_Initial    = 1,
	Execute_Sql     = 2,
	Browse_Table    = 3,
	Refresh_Schema  = 4,
	Sort_Results    = 5,
	List_Versions   = 6,
	Preview_Version = 7,
	Restore_Version = 8,
	Pick_Store      = 9,
}

Result_Kind :: enum u8 {
	None             = 0,
	Opened           = 1,
	Query_Done       = 2,
	Schema_Updated   = 3,
	Sorted           = 4,
	Versions_Listed  = 5,
	Version_Previewed = 6,
	Version_Restored = 7,
	Store_Picked     = 8,
	Failed           = 9,
}

Worker_Request :: struct {
	kind:           Request_Kind,
	serial:         u64,
	sql:            [SQL_REQUEST_MAX_BYTES]u8,
	sql_len:        int,
	table_index:    int,
	sort_column:    int,
	sort_direction: Sort_Direction,
	generation:     i64,
}

Worker_Result :: struct {
	kind:            Result_Kind,
	serial:          u64,
	has_snapshot:    bool, // True only when worker wrote snapshots[snapshot_index] and awaits UI ack.
	snapshot_index:  int,  // 0 or 1 in double-buffered Result_Snapshot array.
	problem:         Problem_Kind,
	detail:          [DIAGNOSTIC_DETAIL_BYTES]u8,
	detail_len:      int,
	error_offset:    i32,
	store_connected: bool,
	read_only:       bool,
	engine_ready:    bool,
	generation:      i64,
	version_count:   int,
	versions:        [VERSION_LIST_CAPACITY]Version_Entry,
}

Ring_Queue :: struct($T: typeid) {
	items: [QUEUE_CAPACITY]T,
	head:  int,
	tail:  int,
	count: int,
}

queue_push :: proc "contextless" (q: ^Ring_Queue($T), item: ^T) -> bool {
	if q.count >= QUEUE_CAPACITY {
		return false
	}
	q.items[q.tail] = item^
	q.tail = (q.tail + 1) % QUEUE_CAPACITY
	q.count += 1
	return true
}

queue_pop :: proc "contextless" (q: ^Ring_Queue($T), out: ^T) -> bool {
	if q.count <= 0 {
		return false
	}
	out^ = q.items[q.head]
	q.head = (q.head + 1) % QUEUE_CAPACITY
	q.count -= 1
	return true
}

// Pluggable storage persistence callbacks used by worker_sync_dirty_pages.
// Implemented over modus:storage in worker.odin and mocked in host tests.
Storage_Sync_Port :: struct {
	user_data:   rawptr,
	write_range: proc "contextless" (user_data: rawptr, offset: u64, data: []u8) -> bool,
	set_size:    proc "contextless" (user_data: rawptr, size: u64) -> bool,
	commit:      proc "contextless" (user_data: rawptr, committed_bytes: u64) -> (generation: i64, ok: bool),
}

// Reusable scratch buffers owned by the worker thread (never allocated on stack).
Worker_Scratch :: struct {
	columns:    [SNAPSHOT_MAX_COLUMNS]Column_Row,
	cells:      [SNAPSHOT_MAX_CELLS]Cell_Row,
	payload:    [SNAPSHOT_PAYLOAD_BYTES]u8,
	diagnostic: [DIAGNOSTIC_DETAIL_BYTES]u8,
	ranges:     [DIRTY_RANGE_CHUNK]Dirty_Range_Row,
}

// worker_sync_dirty_pages persists every dirty 4 KiB page range and size change
// (including VACUUM shrinks) to the store atomically, then calls mark_synced.
// Never calls mark_synced if any write_range, set_size, or commit fails.
worker_sync_dirty_pages :: proc "contextless" (
	bridge: ^Sqlite_Bridge,
	sync: ^Storage_Sync_Port,
	db_bytes: []u8,
	new_size: u64,
	prev_size: u64,
	scratch: ^Worker_Scratch,
) -> (generation: i64, ranges_written: int, ok: bool) {
	if bridge == nil || sync == nil || scratch == nil {
		return 0, 0, false
	}
	err: errors.Error_Record
	total_ranges := 0
	outcome := bridge.dirty_ranges(bridge.user_data, scratch.ranges[:], &total_ranges, &err)
	if outcome != .Succeeded {
		return 0, 0, false
	}
	if total_ranges == 0 && new_size == prev_size {
		return 0, 0, true
	}

	// Write every dirty range clamped strictly to [0, new_size].
	count := min(total_ranges, len(scratch.ranges))
	for i in 0 ..< count {
		r := scratch.ranges[i]
		if r.byte_offset >= new_size || r.byte_length == 0 {
			continue
		}
		end := min(r.byte_offset + r.byte_length, new_size)
		if end > u64(len(db_bytes)) {
			return 0, ranges_written, false
		}
		if !sync.write_range(sync.user_data, r.byte_offset, db_bytes[r.byte_offset:end]) {
			return 0, ranges_written, false
		}
		ranges_written += 1
	}

	// If more dirty ranges existed than fit in one chunk, flush whole [0, new_size]
	// in 4 KiB-aligned 64 KiB strips so no dirty page is ever skipped.
	if total_ranges > len(scratch.ranges) && new_size > 0 {
		if new_size > u64(len(db_bytes)) {
			return 0, ranges_written, false
		}
		STRIP :: u64(65536)
		for offset := u64(0); offset < new_size; offset += STRIP {
			end := min(offset + STRIP, new_size)
			if !sync.write_range(sync.user_data, offset, db_bytes[offset:end]) {
				return 0, ranges_written, false
			}
			ranges_written += 1
		}
	}

	if new_size != prev_size {
		if !sync.set_size(sync.user_data, new_size) {
			return 0, ranges_written, false
		}
	}

	gen, committed := sync.commit(sync.user_data, new_size)
	if !committed {
		return 0, ranges_written, false
	}

	mark_outcome := bridge.mark_synced(bridge.user_data, &err)
	if mark_outcome != .Succeeded {
		return gen, ranges_written, false
	}
	return gen, ranges_written, true
}

// problem_of_sqlite_outcome maps a Call_Outcome from sqlite.module into a
// user-facing Problem_Kind following docs/WRITING.md.
problem_of_sqlite_outcome :: proc "contextless" (outcome: call_outcome.Call_Outcome) -> Problem_Kind {
	switch outcome {
	case .Succeeded:
		return .None
	case .Argument_Refused:
		return .Sql_Error
	case .Grant_Or_Right_Missing:
		return .Read_Only
	case .Budget_Or_Capacity_Exhausted:
		return .Out_Of_Budget
	case .Data_Damaged:
		return .Database_Damaged
	case .Callee_Stopped_During_The_Call, .Connection_Ended_During_The_Call:
		return .Engine_Crashed
	case .Deadline_Passed_During_The_Call:
		return .Engine_Timeout
	case .Callee_Unavailable, .Callee_Busy, .Operation_Unsupported, .Wrong_State, .Nothing_Has_That_Name, .Name_Already_Taken, .Another_Change_Came_First, .Stopped_After_A_Partial_Change, .Answer_Unreadable:
		return .Engine_Unavailable
	}
	return .Engine_Unavailable
}

// worker_execute_and_sync executes SQL through bridge, guarantees dirty-range
// sync on both success and post-error dirty state (e.g. non-autocommit partial
// writes), populates snap on success, and fetches diagnostic text on failure.
worker_execute_and_sync :: proc "contextless" (
	bridge: ^Sqlite_Bridge,
	sync: ^Storage_Sync_Port,
	sql: string,
	db_buf: []u8,
	db_size: ^u64,
	read_only: bool,
	snap: ^Result_Snapshot,
	scratch: ^Worker_Scratch,
) -> (outcome: call_outcome.Call_Outcome, problem: Problem_Kind, error_offset: i32, diag_len: int, committed_gen: i64) {
	error_offset = -1
	if bridge == nil || db_size == nil || snap == nil || scratch == nil {
		return .Callee_Unavailable, .Engine_Unavailable, -1, 0, 0
	}
	prev_size := db_size^
	summary: Query_Summary
	col_count, cell_count, pay_count, d_count := 0, 0, 0, 0
	err: errors.Error_Record

	outcome = bridge.execute(
		bridge.user_data,
		sql,
		db_buf,
		scratch.columns[:],
		scratch.cells[:],
		scratch.payload[:],
		scratch.diagnostic[:],
		&summary,
		&col_count,
		&cell_count,
		&pay_count,
		&d_count,
		&err,
	)

	if outcome != .Succeeded {
		problem = problem_of_sqlite_outcome(outcome)
		// modus_sqlite_entry stores sqlite3_error_offset in err.value (-1 when none).
		if err.value >= 0 {
			error_offset = i32(err.value)
		}
		// Isolated calls drop non-error append tables on failure; fetch the
		// saved diagnostic explicitly when d_count is 0.
		if d_count == 0 && bridge.last_diagnostic != nil {
			diag_err: errors.Error_Record
			_ = bridge.last_diagnostic(bridge.user_data, scratch.diagnostic[:], &d_count, &diag_err)
		}
		diag_len = min(d_count, len(scratch.diagnostic))

		// Even on SQL error, check whether the session holds dirty pages
		// (e.g. an explicit user transaction wrote before failing) and persist.
		if !read_only && sync != nil && bridge.info != nil {
			info: Session_Info
			info_err: errors.Error_Record
			if bridge.info(bridge.user_data, &info, &info_err) == .Succeeded {
				if info.dirty_pages > 0 || info.database_bytes != prev_size {
					gen, _, sync_ok := worker_sync_dirty_pages(bridge, sync, db_buf, info.database_bytes, prev_size, scratch)
					if sync_ok {
						db_size^ = info.database_bytes
						if gen > 0 {
							committed_gen = gen
						}
					}
				}
			}
		}
		return outcome, problem, error_offset, diag_len, committed_gen
	}

	// Execution succeeded: persist dirty pages and size changes before reporting done.
	new_size := summary.database_bytes
	if !read_only && sync != nil && (summary.dirty_pages > 0 || new_size != prev_size) {
		gen, _, sync_ok := worker_sync_dirty_pages(bridge, sync, db_buf, new_size, prev_size, scratch)
		if !sync_ok {
			return .Succeeded, .Store_Write_Refused, -1, 0, 0
		}
		db_size^ = new_size
		committed_gen = gen
	} else {
		db_size^ = new_size
	}

	snapshot_populate_query(
		snap,
		scratch.columns[:min(col_count, len(scratch.columns))],
		scratch.cells[:min(cell_count, len(scratch.cells))],
		scratch.payload[:min(pay_count, len(scratch.payload))],
		summary,
	)
	if committed_gen > 0 {
		snap.generation = committed_gen
	}
	return .Succeeded, .None, -1, 0, committed_gen
}

// worker_refresh_schema reads tables/views from sqlite_master and the selected
// table's columns via PRAGMA table_info into snap.
worker_refresh_schema :: proc "contextless" (
	bridge: ^Sqlite_Bridge,
	db_buf: []u8,
	snap: ^Result_Snapshot,
	scratch: ^Worker_Scratch,
) -> bool {
	if bridge == nil || snap == nil || scratch == nil {
		return false
	}
	schema_sql := "SELECT name, type FROM sqlite_master WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%' ORDER BY name;"
	summary: Query_Summary
	col_count, cell_count, pay_count, d_count := 0, 0, 0, 0
	err: errors.Error_Record
	outcome := bridge.execute(
		bridge.user_data,
		schema_sql,
		db_buf,
		scratch.columns[:],
		scratch.cells[:],
		scratch.payload[:],
		scratch.diagnostic[:],
		&summary,
		&col_count,
		&cell_count,
		&pay_count,
		&d_count,
		&err,
	)
	if outcome != .Succeeded {
		return false
	}
	snap.table_count = 0
	if col_count >= 2 {
		rows := min(cell_count / col_count, SNAPSHOT_MAX_TABLES)
		for r in 0 ..< rows {
			name_cell := scratch.cells[r * col_count + 0]
			type_cell := scratch.cells[r * col_count + 1]
			ns := int(name_cell.payload_offset)
			nl := int(name_cell.payload_length)
			if ns < 0 || nl <= 0 || ns + nl > pay_count {
				continue
			}
			entry := &snap.tables[snap.table_count]
			entry^ = {}
			n_copy := min(nl, SQLITE_COLUMN_NAME_BYTES)
			copy(entry.name[:n_copy], scratch.payload[ns:][:n_copy])
			entry.name_len = u8(n_copy)
			ts := int(type_cell.payload_offset)
			tl := int(type_cell.payload_length)
			if ts >= 0 && tl == 4 && ts + tl <= pay_count && string(scratch.payload[ts:][:4]) == "view" {
				entry.is_view = true
			}
			snap.table_count += 1
		}
	}

	if snap.table_count == 0 {
		snap.selected_table = -1
		snap.schema_column_count = 0
		return true
	}
	if snap.selected_table < 0 || snap.selected_table >= snap.table_count {
		snap.selected_table = 0
	}

	// Fetch column metadata for the selected table via escaped PRAGMA table_info.
	pragma_buf: [SQL_IDENTIFIER_MAX_BYTES * 2 + 40]u8
	pragma_sql, pragma_ok := format_table_info_sql(snapshot_table_name(snap, snap.selected_table), pragma_buf[:])
	snap.schema_column_count = 0
	if !pragma_ok {
		return true
	}
	col_count, cell_count, pay_count, d_count = 0, 0, 0, 0
	p_outcome := bridge.execute(
		bridge.user_data,
		pragma_sql,
		db_buf,
		scratch.columns[:],
		scratch.cells[:],
		scratch.payload[:],
		scratch.diagnostic[:],
		&summary,
		&col_count,
		&cell_count,
		&pay_count,
		&d_count,
		&err,
	)
	// PRAGMA table_info returns: cid(0), name(1), type(2), notnull(3), dflt_value(4), pk(5).
	if p_outcome == .Succeeded && col_count >= 6 {
		rows := min(cell_count / col_count, SNAPSHOT_MAX_SCHEMA_COLUMNS)
		for r in 0 ..< rows {
			name_cell := scratch.cells[r * col_count + 1]
			type_cell := scratch.cells[r * col_count + 2]
			notnull_cell := scratch.cells[r * col_count + 3]
			pk_cell := scratch.cells[r * col_count + 5]
			ns, nl := int(name_cell.payload_offset), int(name_cell.payload_length)
			if ns < 0 || nl <= 0 || ns + nl > pay_count {
				continue
			}
			sc := &snap.schema_columns[snap.schema_column_count]
			sc^ = {}
			n_copy := min(nl, SQLITE_COLUMN_NAME_BYTES)
			copy(sc.name[:n_copy], scratch.payload[ns:][:n_copy])
			sc.name_len = u8(n_copy)
			ts, tl := int(type_cell.payload_offset), int(type_cell.payload_length)
			if ts >= 0 && tl > 0 && ts + tl <= pay_count {
				t_copy := min(tl, len(sc.type_name))
				copy(sc.type_name[:t_copy], scratch.payload[ts:][:t_copy])
				sc.type_len = u8(t_copy)
			}
			sc.not_null = notnull_cell.integer_or_bits != 0
			sc.primary_key = pk_cell.integer_or_bits != 0
			snap.schema_column_count += 1
		}
	}
	return true
}
