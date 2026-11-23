#+build !freestanding
package db_browser_core

import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "modus:contract/blake3"
import "modus:contract/call_outcome"
import "modus:contract/declaration_eval"
import "modus:contract/errors"
import box_layout "modus:layout"
import "modus:lex_evaluator"

@(test)
value_kind_border_refuses_unknown_words :: proc(t: ^testing.T) {
	for w in u8(0) ..= u8(5) {
		kind, ok := value_kind_of_word(w)
		testing.expect(t, ok, "valid Value_Kind byte must parse")
		testing.expect_value(t, u8(kind), w)
	}
	for bad in ([?]u8{6, 7, 127, 255}) {
		_, ok := value_kind_of_word(bad)
		testing.expect(t, !ok, "unknown Value_Kind byte must be refused")
	}
}

@(test)
sql_identifier_escaping_refuses_edges_and_doubles_quotes :: proc(t: ^testing.T) {
	out: [256]u8

	// Refusals: empty, NUL byte, invalid UTF-8, over-length, tiny buffer.
	_, ok := escape_sql_identifier("", out[:])
	testing.expect(t, !ok, "empty identifier must be refused")

	_, ok = escape_sql_identifier("abc\x00def", out[:])
	testing.expect(t, !ok, "NUL byte in identifier must be refused")

	bad_utf8 := [2]u8{0xFF, 0xFE}
	_, ok = escape_sql_identifier(string(bad_utf8[:]), out[:])
	testing.expect(t, !ok, "invalid UTF-8 identifier must be refused")

	too_long: [SQL_IDENTIFIER_MAX_BYTES + 1]u8
	for &b in too_long {
		b = 'a'
	}
	_, ok = escape_sql_identifier(string(too_long[:]), out[:])
	testing.expect(t, !ok, "identifier past SQL_IDENTIFIER_MAX_BYTES must be refused")

	tiny: [3]u8
	_, ok = escape_sql_identifier("a\"b", tiny[:])
	testing.expect(t, !ok, "output buffer too small for doubled quote must be refused")

	// Success: embedded quotes, spaces, Unicode, SQL injection payload safely quoted.
	sql, browse_ok := format_browse_table_sql("weird \"table\"; DROP TABLE x;--", out[:])
	testing.expect(t, browse_ok, "valid identifier with quotes must escape")
	testing.expect_value(t, sql, "SELECT * FROM \"weird \"\"table\"\"; DROP TABLE x;--\" LIMIT 500;")

	pragma, pragma_ok := format_table_info_sql("café\"1", out[:])
	testing.expect(t, pragma_ok, "Unicode + quote identifier must escape in PRAGMA")
	testing.expect_value(t, pragma, "PRAGMA table_info(\"café\"\"1\");")
}

@(test)
sql_error_offset_and_value_formatters_handle_all_edges :: proc(t: ^testing.T) {
	sql := "SELECT 1;\nSELECT café, bad_col\nFROM items;"

	// Refusals: negative and past end.
	_, _, ok := sql_error_line_and_column(sql, -1)
	testing.expect(t, !ok)
	_, _, ok = sql_error_line_and_column(sql, len(sql) + 1)
	testing.expect(t, !ok)

	// Start of line 1, line 2 after UTF-8 "café", and end of string.
	line, col, valid := sql_error_line_and_column(sql, 0)
	testing.expect(t, valid && line == 1 && col == 1)

	bad_idx := strings.index(sql, "bad_col")
	line, col, valid = sql_error_line_and_column(sql, bad_idx)
	testing.expect(t, valid)
	testing.expect_value(t, line, 2)
	testing.expect_value(t, col, 14) // "SELECT café, " is 13 characters (é is 2 bytes)

	// Signed integers including min(i64) and max(i64).
	buf: [64]u8
	testing.expect_value(t, format_i64(0, buf[:]), "0")
	testing.expect_value(t, format_i64(-1, buf[:]), "-1")
	testing.expect_value(t, format_i64(min(i64), buf[:]), "-9223372036854775808")
	testing.expect_value(t, format_i64(max(i64), buf[:]), "9223372036854775807")

	// Floating point bits: 0.0, -0.0, negative fractional, NaN, Inf, -Inf, scientific.
	testing.expect_value(t, format_f64_bits(transmute(u64)f64(0.0), buf[:]), "0.0")
	testing.expect_value(t, format_f64_bits(u64(1) << 63, buf[:]), "-0.0")
	testing.expect_value(t, format_f64_bits(transmute(u64)f64(-12.75), buf[:]), "-12.75")
	testing.expect_value(t, format_f64_bits(0x7FF8_0000_0000_0000, buf[:]), "NaN")
	testing.expect_value(t, format_f64_bits(0x7FF0_0000_0000_0000, buf[:]), "Inf")
	testing.expect_value(t, format_f64_bits(0xFFF0_0000_0000_0000, buf[:]), "-Inf")
	testing.expect_value(t, format_f64_bits(transmute(u64)f64(1.5e20), buf[:]), "1.5e+20")

	// BLOB badge and single-line text sanitization.
	testing.expect_value(t, format_blob_badge(42, buf[:]), "<42 B>")
	testing.expect_value(t, format_blob_badge(-5, buf[:]), "<0 B>")
	raw := "a\nb\tc\r\nd"
	n := sanitize_single_line_text(transmute([]u8)raw, buf[:])
	testing.expect_value(t, string(buf[:n]), "a b c  d")
}

@(test)
result_snapshot_drops_partial_row_and_sorts_deterministically :: proc(t: ^testing.T) {
	snap := new(Result_Snapshot, context.temp_allocator)
	cols := [2]Column_Row{
		{column_index = 0, declared_kind = u8(Value_Kind.Integer), name_length = 2},
		{column_index = 1, declared_kind = u8(Value_Kind.Text), name_length = 4},
	}
	copy(cols[0].name[:], "id")
	copy(cols[1].name[:], "name")

	payload := "betaalphagamma"
	// 4 complete rows + 1 trailing orphan cell (must be dropped and set truncated_rows).
	cells := [9]Cell_Row{
		{row_index = 0, column_index = 0, value_kind = u8(Value_Kind.Null)},
		{row_index = 0, column_index = 1, value_kind = u8(Value_Kind.Text), payload_offset = 0, payload_length = 4}, // beta
		{row_index = 1, column_index = 0, value_kind = u8(Value_Kind.Integer), integer_or_bits = 10},
		{row_index = 1, column_index = 1, value_kind = u8(Value_Kind.Text), payload_offset = 4, payload_length = 5}, // alpha
		{row_index = 2, column_index = 0, value_kind = u8(Value_Kind.Real_Bits), integer_or_bits = transmute(i64)f64(2.5)},
		{row_index = 2, column_index = 1, value_kind = u8(Value_Kind.Blob), integer_or_bits = 16},
		{row_index = 3, column_index = 0, value_kind = u8(Value_Kind.Integer), integer_or_bits = -5},
		{row_index = 3, column_index = 1, value_kind = u8(Value_Kind.Text), payload_offset = 9, payload_length = 5}, // gamma
		// Orphan partial cell for row 4:
		{row_index = 4, column_index = 0, value_kind = u8(Value_Kind.Integer), integer_or_bits = 99},
	}
	summary := Query_Summary{column_count = 2, row_count = 5, has_rows = 1}
	snapshot_populate_query(snap, cols[:], cells[:], transmute([]u8)payload, summary)

	testing.expect_value(t, snap.row_count, 4)
	testing.expect(t, snap.truncated_rows, "partial trailing row must be dropped and mark truncated_rows")

	// Refusal: out-of-range sort column.
	testing.expect(t, !snapshot_sort_by_column(snap, -1, .Ascending))
	testing.expect(t, !snapshot_sort_by_column(snap, 2, .Ascending))

	// Sort col 0 ascending: -5, 2.5, 10, NULL (NULLs always last).
	testing.expect(t, snapshot_sort_by_column(snap, 0, .Ascending))
	buf: [64]u8
	t0, a0, k0, _ := snapshot_cell_display(snap, 0, 0, buf[:])
	testing.expect(t, t0 == "-5" && a0 == .Right && k0 == .Integer)
	t1, a1, k1, _ := snapshot_cell_display(snap, 1, 0, buf[:])
	testing.expect(t, t1 == "2.5" && a1 == .Right && k1 == .Real_Bits)
	t2, _, _, _ := snapshot_cell_display(snap, 2, 0, buf[:])
	testing.expect_value(t, t2, "10")
	t3, a3, k3, _ := snapshot_cell_display(snap, 3, 0, buf[:])
	testing.expect(t, t3 == "NULL" && a3 == .Left && k3 == .Null)

	// Sort col 0 descending: 10, 2.5, -5, NULL (NULLs still last).
	testing.expect(t, snapshot_sort_by_column(snap, 0, .Descending))
	t0, _, _, _ = snapshot_cell_display(snap, 0, 0, buf[:])
	testing.expect_value(t, t0, "10")
	t3, _, _, _ = snapshot_cell_display(snap, 3, 0, buf[:])
	testing.expect_value(t, t3, "NULL")

	// Sort direction .None restores original order (row 0 = NULL).
	testing.expect(t, snapshot_sort_by_column(snap, 0, .None))
	t0, _, _, _ = snapshot_cell_display(snap, 0, 0, buf[:])
	testing.expect_value(t, t0, "NULL")

	// Sort col 1 ascending: alpha, beta, gamma, <16 B> (TEXT < BLOB).
	testing.expect(t, snapshot_sort_by_column(snap, 1, .Ascending))
	t0, _, _, _ = snapshot_cell_display(snap, 0, 1, buf[:])
	testing.expect_value(t, t0, "alpha")
	t3, a3, k3, _ = snapshot_cell_display(snap, 3, 1, buf[:])
	testing.expect(t, t3 == "<16 B>" && a3 == .Right && k3 == .Blob)
}

@(test)
layout_spec_never_overlaps_across_all_window_sizes :: proc(t: ^testing.T) {
	tree := new(box_layout.Box_Tree, context.temp_allocator)

	// Refusals: below minimum bounds.
	_, ok := compute_layout(tree, LEAST_WIDTH - 1, LEAST_HEIGHT, DEFAULT_SPLIT_RATIOS, 120)
	testing.expect(t, !ok, "width below LEAST_WIDTH must be refused")
	_, ok = compute_layout(tree, LEAST_WIDTH, LEAST_HEIGHT - 1, DEFAULT_SPLIT_RATIOS, 120)
	testing.expect(t, !ok, "height below LEAST_HEIGHT must be refused")

	sizes := [3][2]i32{
		{LEAST_WIDTH, LEAST_HEIGHT},
		{DEFAULT_WIDTH, DEFAULT_HEIGHT},
		{LARGEST_WIDTH, LARGEST_HEIGHT},
	}
	extreme_ratios := [3]Split_Ratios{
		{sidebar_ratio = 0, editor_ratio = 0},
		DEFAULT_SPLIT_RATIOS,
		{sidebar_ratio = 10_000, editor_ratio = 10_000},
	}
	for sz in sizes {
		for r in extreme_ratios {
			lay, solved := compute_layout(tree, sz[0], sz[1], r, 240)
			testing.expect(t, solved, "valid size must solve")
			testing.expect(t, lay.sidebar.width >= SIDEBAR_MIN_WIDTH, "sidebar min width holds")
			testing.expect(t, lay.right_column.width >= RIGHT_MIN_WIDTH, "right column min width holds")
			testing.expect(t, lay.editor_pane.height >= EDITOR_MIN_HEIGHT, "editor min height holds")
			testing.expect(t, lay.grid_pane.height >= GRID_MIN_HEIGHT, "grid min height holds")
			testing.expect(t, lay.grid_header.height == GRID_HEADER_HEIGHT, "grid header visible")
			testing.expect(t, lay.grid_body.height > 0, "grid body positive height")
			testing.expect(t, lay.status.height == STATUS_HEIGHT, "status band height")
			testing.expect(t, lay.action_bar.height == ACTION_BAR_HEIGHT, "action bar height")

			// Non-overlap between every pair of top-level sibling regions.
			regions := [7]box_layout.Rect{
				lay.sidebar_tables,
				lay.sidebar_columns,
				lay.sidebar_divider,
				lay.editor_pane,
				lay.editor_divider,
				lay.grid_pane,
				lay.status,
			}
			for i in 0 ..< len(regions) {
				for j in i + 1 ..< len(regions) {
					testing.expect(t, !rects_overlap(regions[i], regions[j]), "sibling layout panes must never overlap")
				}
			}
			testing.expect(t, !rects_overlap(lay.status, lay.action_bar))
			testing.expect(t, !rects_overlap(lay.grid_header, lay.grid_body))
			testing.expect(t, !rects_overlap(lay.grid_body, lay.grid_vscroll))
			testing.expect(t, !rects_overlap(lay.grid_body, lay.grid_hscroll))
		}
	}
}

@(test)
session_state_and_writing_rules_hold :: proc(t: ^testing.T) {
	s: Session_State
	session_init(&s)

	// Serial gating drops stale replies.
	s1 := session_next_serial(&s)
	s2 := session_next_serial(&s)
	testing.expect(t, session_accept_serial(&s, s2))
	testing.expect(t, !session_accept_serial(&s, s1), "stale serial must be dropped")
	testing.expect(t, !session_accept_serial(&s, 0), "zero serial must be dropped")

	// Revocation forces read-only and blocks version restore.
	s.store_connected = true
	s.read_only = false
	vers := [2]Version_Entry{
		{generation = 1, bytes = 4096, current = false},
		{generation = 2, bytes = 8192, current = true},
	}
	testing.expect(t, session_enter_versions(&s, vers[:]))
	testing.expect(t, !session_can_restore_chosen(&s), "current version cannot be restored")
	gen, ok := session_choose_version(&s, 0)
	testing.expect(t, ok && gen == 1)
	testing.expect(t, session_can_restore_chosen(&s), "older version can be restored when writable")

	session_mark_revoked(&s)
	testing.expect(t, !s.store_connected && s.read_only)
	testing.expect(t, !session_can_restore_chosen(&s), "revoked store must block version restore")

	// Queue overflow refusal.
	q: Ring_Queue(int)
	for i in 0 ..< QUEUE_CAPACITY {
		v := i
		testing.expect(t, queue_push(&q, &v))
	}
	extra := 99
	testing.expect(t, !queue_push(&q, &extra), "full queue must refuse push")

	// docs/WRITING.md audit: no forbidden words or raw SQLite codes in any Problem_Kind text.
	forbidden := [?]string{"invalid", "illegal", "fatal", "please", "sorry", "failed", "Error", "SQLITE_", "n't", "can't", "won't"}
	for kind in Problem_Kind {
		sentence := PROBLEM_SENTENCES[kind]
		lower := strings.to_lower(sentence, context.temp_allocator)
		for bad in forbidden {
			check := bad == "Error" || bad == "SQLITE_" ? sentence : lower
			testing.expectf(t, !strings.contains(check, bad), "Problem_Kind.%v violates docs/WRITING.md with %q: %q", kind, bad, sentence)
		}
	}
}

@(test)
worker_sync_handles_vacuum_shrink_and_post_error_dirty_pages :: proc(t: ^testing.T) {
	Mock_State :: struct {
		dirty_ranges:    [2]Dirty_Range_Row,
		dirty_count:     int,
		new_db_size:     u64,
		fail_execute:    bool,
		fail_commit:     bool,
		marked_synced:   bool,
		writes:          int,
		set_size_called: bool,
		set_size_value:  u64,
		commits:         int,
	}

	mock := Mock_State {
		dirty_ranges = {{byte_offset = 0, byte_length = 4096}, {byte_offset = 4096, byte_length = 4096}},
		dirty_count  = 2,
		new_db_size  = 8192,
	}

	bridge := Sqlite_Bridge {
		user_data = &mock,
		execute = proc "contextless" (
			ud: rawptr,
			_: string,
			_: []u8,
			_: []Column_Row,
			_: []Cell_Row,
			_: []u8,
			_: []u8,
			summary: ^Query_Summary,
			_: ^int,
			_: ^int,
			_: ^int,
			diag_count: ^int,
			err: ^errors.Error_Record,
		) -> call_outcome.Call_Outcome {
			m := (^Mock_State)(ud)
			summary^ = {dirty_pages = u64(m.dirty_count), database_bytes = m.new_db_size}
			if m.fail_execute {
				err^ = errors.error_make(.Bad_Value, .None, 8)
				diag_count^ = 0
				return .Argument_Refused
			}
			return .Succeeded
		},
		dirty_ranges = proc "contextless" (ud: rawptr, out: []Dirty_Range_Row, total: ^int, _: ^errors.Error_Record) -> call_outcome.Call_Outcome {
			m := (^Mock_State)(ud)
			n := min(m.dirty_count, len(out))
			for i in 0 ..< n {
				out[i] = m.dirty_ranges[i]
			}
			total^ = m.dirty_count
			return .Succeeded
		},
		mark_synced = proc "contextless" (ud: rawptr, _: ^errors.Error_Record) -> call_outcome.Call_Outcome {
			m := (^Mock_State)(ud)
			m.marked_synced = true
			m.dirty_count = 0
			return .Succeeded
		},
		info = proc "contextless" (ud: rawptr, out_info: ^Session_Info, _: ^errors.Error_Record) -> call_outcome.Call_Outcome {
			m := (^Mock_State)(ud)
			out_info^ = {database_bytes = m.new_db_size, dirty_pages = u64(m.dirty_count), page_size = 4096, open = 1}
			return .Succeeded
		},
		last_diagnostic = proc "contextless" (_: rawptr, out_diag: []u8, out_count: ^int, _: ^errors.Error_Record) -> call_outcome.Call_Outcome {
			msg := "no such table: missing"
			out_count^ = copy(out_diag, msg)
			return .Succeeded
		},
	}

	sync := Storage_Sync_Port {
		user_data = &mock,
		write_range = proc "contextless" (ud: rawptr, _: u64, _: []u8) -> bool {
			(^Mock_State)(ud).writes += 1
			return true
		},
		set_size = proc "contextless" (ud: rawptr, sz: u64) -> bool {
			m := (^Mock_State)(ud)
			m.set_size_called = true
			m.set_size_value = sz
			return true
		},
		commit = proc "contextless" (ud: rawptr) -> (i64, bool) {
			m := (^Mock_State)(ud)
			if m.fail_commit {
				return 0, false
			}
			m.commits += 1
			return i64(m.commits), true
		},
	}

	db_buf := make([]u8, 65536, context.temp_allocator)
	snap := new(Result_Snapshot, context.temp_allocator)
	scratch := new(Worker_Scratch, context.temp_allocator)

	// 1. VACUUM shrink from 32768 -> 8192: writes dirty ranges, calls set_size(8192), commits, marks synced.
	db_size: u64 = 32768
	outcome, prob, _, _, gen := worker_execute_and_sync(&bridge, &sync, "VACUUM;", db_buf, &db_size, false, snap, scratch)
	testing.expect_value(t, outcome, call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, prob, Problem_Kind.None)
	testing.expect_value(t, db_size, u64(8192))
	testing.expect_value(t, mock.writes, 2)
	testing.expect(t, mock.set_size_called && mock.set_size_value == 8192)
	testing.expect(t, mock.marked_synced && gen == 1)

	// 2. Commit failure must NOT call mark_synced and must report Store_Write_Refused.
	mock.dirty_count = 1
	mock.marked_synced = false
	mock.fail_commit = true
	_, prob, _, _, _ = worker_execute_and_sync(&bridge, &sync, "INSERT INTO t VALUES (1);", db_buf, &db_size, false, snap, scratch)
	testing.expect_value(t, prob, Problem_Kind.Store_Write_Refused)
	testing.expect(t, !mock.marked_synced, "failed commit must never clear dirty pages")

	// 3. Failed SQL with residual dirty pages still fetches diagnostic AND syncs dirty pages.
	mock.fail_commit = false
	mock.fail_execute = true
	mock.dirty_count = 1
	mock.marked_synced = false
	err_off: i32
	diag_len: int
	outcome, prob, err_off, diag_len, _ = worker_execute_and_sync(&bridge, &sync, "SELECT * FROM missing;", db_buf, &db_size, false, snap, scratch)
	testing.expect_value(t, outcome, call_outcome.Call_Outcome.Argument_Refused)
	testing.expect_value(t, prob, Problem_Kind.Sql_Error)
	testing.expect_value(t, err_off, i32(7))
	testing.expect_value(t, string(scratch.diagnostic[:diag_len]), "no such table: missing")
	testing.expect(t, mock.marked_synced, "residual dirty pages after SQL error must still be synced")
}

@(test)
project_lex_and_pins_evaluate_cleanly :: proc(t: ^testing.T) {
	project_bytes, p_err := os.read_entire_file("src/outside/projects/db_browser/project.lex", context.temp_allocator)
	testing.expect(t, p_err == nil && len(project_bytes) > 0, "project.lex must exist and be readable")
	pins_bytes, pins_err := os.read_entire_file("src/outside/projects/db_browser/pins.lex", context.temp_allocator)
	testing.expect(t, pins_err == nil && len(pins_bytes) > 0, "pins.lex must exist and be readable")

	workspace := new(lex_evaluator.Declaration_Workspace, context.temp_allocator)
	pools := lex_evaluator.declaration_pools_of_scale(0)
	memory, _ := mem.alloc_bytes(lex_evaluator.declaration_workspace_bytes(pools), 64, context.temp_allocator)
	lex_evaluator.declaration_workspace_carve(workspace, memory, pools)

	here := blake3.hash(project_bytes)
	cfg := lex_evaluator.Declaration_Config{has_here = true, here_hash = here, stack_bytes = 2 * 1024 * 1024}
	out_buf: [4096]u8
	out_len, ok := lex_evaluator.declaration_evaluate_to_buffer(workspace, string(project_bytes), "", cfg, out_buf[:])
	testing.expect(t, ok, "project.lex must evaluate cleanly")
	header, refusal := declaration_eval.output_validate(out_buf[:out_len])
	testing.expect_value(t, refusal, declaration_eval.Output_Refusal.None)
	testing.expect_value(t, header.status, declaration_eval.Output_Status.Ok)
}
