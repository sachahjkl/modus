// db_browser: interactive SQLite database browser for modus
// (src/md/features/db_browser.md).
//
// Two-thread architecture: this UI thread handles input and draws only visible
// viewport rows from an immutable double-buffered Result_Snapshot; worker.odin
// owns the private store connection and runs sqlite.module inside a zero-grant
// child call host.
package db_browser

import "core"
import "modus:calendar"
import "modus:display"
import "modus:graphics"
import "modus:interface"
import box_layout "modus:layout"
import "modus:system"
import "modus:text_model"

#assert(core.ACTION_BAR_HEIGHT == interface.ACTION_BAR_ROW_HEIGHT)
#assert(core.SCROLL_BAR_THICKNESS == interface.SCROLL_BAR_THICKNESS)

// Plan value: 16 MiB working memory, 2 processes (db_browser + isolated sqlite
// child call host), 3 threads (UI + worker + 1 thread for sqlite_host child),
// resizable surface up to 1280x960.
// Literals so modustool reads the budget directly without evaluating imports.
MODULE_BUDGET :: system.Stated_Budget {
	working_memory_pages = 4096,
	processes            = 2,
	threads              = 3,
	window_width         = 1280,
	window_height        = 960,
}
#assert(MODULE_BUDGET.window_width == core.LARGEST_WIDTH)
#assert(MODULE_BUDGET.window_height == core.LARGEST_HEIGHT)

// Inline capacities for modus:interface draw commands and text bytes per frame.
window_memory: interface.Window_Memory(2048, 32768)

// Arena reservations for the SQL editor and clipboard transfer.
EDITOR_TEXT_RESERVE_PAGES :: 64 // 256 KiB SQL script text ceiling.
EDITOR_ROWS_RESERVE_PAGES :: 64 // 32 Ki visual rows ceiling.
TRANSFER_RESERVE_PAGES :: 64    // 256 KiB clipboard copy/paste ceiling.
ROW_BUFFER_SIZE :: 4 * text_model.COLUMNS_LIMIT

editor_text_arena: system.Arena
editor_rows_arena: system.Arena
transfer_arena: system.Arena

// UI-thread state.
session: core.Session_State
editor_text: text_model.Text
editor_layout: text_model.Layout
editor_columns := text_model.COLUMNS_LEAST
editor_top_row: int
editor_visible_rows := 1
editor_error_line := -1

ratios := core.DEFAULT_SPLIT_RATIOS
box_tree: box_layout.Box_Tree
tokens: box_layout.Element_Tokens
last_layout: core.Window_Layout
has_last_layout: bool

sidebar_tables_first_row: int
sidebar_columns_first_row: int
sidebar_versions_first_row: int
grid_first_row: int
grid_scroll_x: int

bar: interface.Action_Bar_State
ui_request: core.Worker_Request
ui_result: core.Worker_Result

pointer_buttons_before: u32
dragging_editor: bool
dragging_sidebar_divider: bool
dragging_editor_divider: bool
drag_last_x: i32
drag_last_y: i32

@(private = "file")
to_area :: proc "contextless" (r: box_layout.Rect) -> interface.Area {
	return {int(r.x), int(r.y), int(r.width), int(r.height)}
}

@(private = "file")
ui_arenas_init :: proc "contextless" () {
	editor_text_arena, _ = system.arena_create(EDITOR_TEXT_RESERVE_PAGES)
	editor_rows_arena, _ = system.arena_create(EDITOR_ROWS_RESERVE_PAGES)
	transfer_arena, _ = system.arena_create(TRANSFER_RESERVE_PAGES)
	text_model.text_init_buffer(&editor_text, nil, system.arena_grow, &editor_text_arena)
	text_model.layout_init_buffer(&editor_layout, nil, system.arena_grow, &editor_rows_arena)
	_ = text_model.text_insert(&editor_text, transmute([]u8)string(core.DEFAULT_SQL))
}

@(private = "file")
transfer_bytes :: proc "contextless" (count: int) -> []u8 {
	whole, status := system.arena_extend_to(&transfer_arena, u64(max(count, 0)))
	if status != .Succeeded {
		return nil
	}
	return whole[:count]
}

@(private = "file")
editor_columns_for_width :: proc "contextless" (body_width: i32) -> int {
	usable := int(body_width) - 2 * core.PANE_PADDING - 2
	return clamp(usable / graphics.CELL_WIDTH, text_model.COLUMNS_LEAST, text_model.COLUMNS_LIMIT)
}

@(private = "file")
editor_layout_refresh :: proc "contextless" () {
	text_model.layout_compute(&editor_layout, &editor_text, editor_columns, .Word)
	editor_scroll_to_caret()
}

@(private = "file")
editor_scroll_to_caret :: proc "contextless" () {
	row := text_model.row_of(&editor_layout, editor_text.caret)
	if row < editor_top_row {
		editor_top_row = row
	}
	if row >= editor_top_row + editor_visible_rows {
		editor_top_row = row - editor_visible_rows + 1
	}
	editor_top_row = clamp(editor_top_row, 0, max(editor_layout.row_count - editor_visible_rows, 0))
}

@(private = "file")
editor_set_sql :: proc "contextless" (sql: string) {
	text_model.text_select_all(&editor_text)
	_ = text_model.selection_delete(&editor_text)
	_ = text_model.text_insert(&editor_text, transmute([]u8)sql)
	editor_top_row = 0
	editor_layout_refresh()
}

@(private = "file")
editor_copy_into :: proc "contextless" (out: []u8) -> int {
	n := min(text_model.text_length(&editor_text), len(out))
	for i in 0 ..< n {
		out[i] = text_model.byte_at(&editor_text, i)
	}
	return n
}

@(private = "file")
dispatch_request :: proc "contextless" (req: ^core.Worker_Request) {
	req.serial = core.session_next_serial(&session)
	if !worker_push_request(req) {
		session.busy = false
		core.session_set_problem(&session, .Queue_Full)
	}
}

@(private = "file")
action_execute_editor_sql :: proc "contextless" () {
	if session.mode == .Versions {
		return
	}
	ui_request = {kind = .Execute_Sql}
	ui_request.sql_len = editor_copy_into(ui_request.sql[:])
	core.session_clear_problem(&session)
	dispatch_request(&ui_request)
}

@(private = "file")
action_browse_table :: proc "contextless" (table_index: int) {
	snap := &snapshots[active_snapshot]
	if table_index < 0 || table_index >= snap.table_count {
		return
	}
	name := core.snapshot_table_name(snap, table_index)
	sql_buf: [core.SQL_IDENTIFIER_MAX_BYTES * 2 + 40]u8
	sql, ok := core.format_browse_table_sql(name, sql_buf[:])
	if !ok {
		return
	}
	editor_set_sql(sql)
	ui_request = {kind = .Browse_Table, table_index = table_index}
	ui_request.sql_len = copy(ui_request.sql[:], sql)
	core.session_clear_problem(&session)
	dispatch_request(&ui_request)
}

@(private = "file")
action_sort_column :: proc "contextless" (col: int) {
	snap := &snapshots[active_snapshot]
	if col < 0 || col >= snap.column_count {
		return
	}
	dir := core.next_sort_direction(snap.sort_column, snap.sort_direction, col)
	ui_request = {kind = .Sort_Results, sort_column = col, sort_direction = dir}
	dispatch_request(&ui_request)
}

@(private = "file")
action_refresh_schema :: proc "contextless" () {
	ui_request = {kind = .Refresh_Schema, table_index = snapshots[active_snapshot].selected_table}
	dispatch_request(&ui_request)
}

@(private = "file")
action_open_versions :: proc "contextless" () {
	if !session.store_connected {
		core.session_set_problem(&session, .No_Store)
		return
	}
	ui_request = {kind = .List_Versions}
	dispatch_request(&ui_request)
}

@(private = "file")
action_preview_version :: proc "contextless" (index: int) {
	gen, ok := core.session_choose_version(&session, index)
	if !ok {
		return
	}
	ui_request = {kind = .Preview_Version, generation = gen}
	dispatch_request(&ui_request)
}

@(private = "file")
action_close_versions :: proc "contextless" () {
	core.session_exit_versions(&session)
	bar = {}
	ui_request = {kind = .Preview_Version, generation = 0}
	dispatch_request(&ui_request)
}

@(private = "file")
action_restore_version :: proc "contextless" () {
	if !core.session_can_restore_chosen(&session) {
		return
	}
	gen := session.versions[session.version_chosen].generation
	ui_request = {kind = .Restore_Version, generation = gen}
	dispatch_request(&ui_request)
}

@(private = "file")
action_pick_store :: proc "contextless" () {
	ui_request = {kind = .Pick_Store}
	dispatch_request(&ui_request)
}

@(private = "file")
editor_clear_error_line :: proc "contextless" () {
	session.error_offset = -1
	editor_error_line = -1
}

@(private = "file")
apply_worker_result :: proc "contextless" (res: ^core.Worker_Result) {
	if res.has_snapshot {
		worker_ack_snapshot(res.snapshot_index)
	}
	if !core.session_accept_serial(&session, res.serial) {
		return
	}
	session.store_connected = res.store_connected
	session.read_only = res.read_only
	session.engine_ready = res.engine_ready

	if res.problem == .Store_Revoked {
		editor_error_line = -1
		core.session_mark_revoked(&session)
		return
	}
	if res.problem != .None {
		detail := res.detail_len > 0 ? string(res.detail[:res.detail_len]) : ""
		core.session_set_problem(&session, res.problem, detail, res.error_offset)
		// Compute error line once when the worker answers, never per frame.
		if res.error_offset >= 0 && editor_layout.row_count > 0 {
			byte_place := clamp(int(res.error_offset), 0, text_model.text_length(&editor_text))
			err_row := text_model.row_of(&editor_layout, byte_place)
			editor_error_line = int(editor_layout.rows[clamp(err_row, 0, editor_layout.row_count - 1)].line)
		} else {
			editor_error_line = -1
		}
	} else {
		editor_error_line = -1
		core.session_clear_problem(&session)
	}

	switch res.kind {
	case .None, .Opened, .Schema_Updated, .Store_Picked, .Failed:
	case .Query_Done:
		grid_first_row = 0
		grid_scroll_x = 0
	case .Sorted:
		grid_first_row = 0
	case .Versions_Listed:
		if res.problem == .None && core.session_enter_versions(&session, res.versions[:res.version_count]) {
			bar = {}
			sidebar_versions_first_row = 0
		}
	case .Version_Previewed:
		grid_first_row = 0
		grid_scroll_x = 0
	case .Version_Restored:
		if res.problem == .None {
			core.session_exit_versions(&session)
			bar = {}
		}
	}
}

@(private = "file")
bar_items :: proc "contextless" (items: ^[4]interface.Action_Bar_Item) -> int {
	switch session.mode {
	case .Tables:
		items^ = {
			interface.action_bar_item("Run", 4, "Ctrl", "Enter"),
			interface.action_bar_item("Open store", 2, "Ctrl", "O"),
			interface.action_bar_item("Versions", 3, "Ctrl", "H"),
			interface.action_bar_item("Refresh", 1, "Ctrl", "R"),
		}
		return 4
	case .Versions:
		items^ = {
			interface.action_bar_item("Older", 3, "Down"),
			interface.action_bar_item("Newer", 2, "Up"),
			interface.action_bar_item("Restore", 4, "Enter"),
			interface.action_bar_item("Back", 1, "Esc"),
		}
		return 4
	}
	return 0
}

@(private = "file")
editor_move :: proc "contextless" (motion: text_model.Motion, extend: bool) {
	text_model.caret_move(&editor_text, &editor_layout, motion, extend, editor_visible_rows)
	editor_scroll_to_caret()
}

@(private = "file")
editor_insert_rune :: proc "contextless" (ch: rune) {
	switch text_model.text_insert_character(&editor_text, ch) {
	case .None:
		editor_clear_error_line()
		editor_layout_refresh()
	case .Too_Long:
		core.session_set_problem(&session, .Editor_Full)
	case .Empty, .Not_Text:
	}
}

@(private = "file")
key_run :: proc "contextless" (press: interface.Key_Press) {
	ctrl := press.modifiers & display.MODIFIER_CONTROL != 0
	shift := press.modifiers & display.MODIFIER_SHIFT != 0

	if session.mode == .Versions {
		switch press.code {
		case display.KEY_DOWN:
			action_preview_version(session.version_chosen - 1)
		case display.KEY_UP:
			action_preview_version(session.version_chosen + 1)
		case display.KEY_ENTER:
			action_restore_version()
		case display.KEY_ESCAPE:
			action_close_versions()
		}
		return
	}

	if ctrl {
		switch press.code {
		case display.KEY_ENTER:
			action_execute_editor_sql()
			return
		case display.KEY_HOME:
			editor_move(.Text_Start, shift)
			return
		case display.KEY_END:
			editor_move(.Text_End, shift)
			return
		}
		switch press.character {
		case 'a', 'A':
			text_model.text_select_all(&editor_text)
			editor_scroll_to_caret()
		case 'h', 'H':
			action_open_versions()
		case 'o', 'O':
			action_pick_store()
		case 'r', 'R':
			action_refresh_schema()
		}
		return
	}

	switch press.code {
	case display.KEY_LEFT:
		editor_move(.Left, shift)
	case display.KEY_RIGHT:
		editor_move(.Right, shift)
	case display.KEY_UP:
		editor_move(.Up, shift)
	case display.KEY_DOWN:
		editor_move(.Down, shift)
	case display.KEY_HOME:
		editor_move(.Line_Start, shift)
	case display.KEY_END:
		editor_move(.Line_End, shift)
	case display.KEY_PAGE_UP:
		editor_move(.Page_Up, shift)
	case display.KEY_PAGE_DOWN:
		editor_move(.Page_Down, shift)
	case display.KEY_BACKSPACE:
		if text_model.text_delete_before(&editor_text) {
			editor_clear_error_line()
			editor_layout_refresh()
		}
	case display.KEY_DELETE:
		if text_model.text_delete_after(&editor_text) {
			editor_clear_error_line()
			editor_layout_refresh()
		}
	case display.KEY_ENTER:
		editor_insert_rune(text_model.LINE_END)
	case display.KEY_TAB:
		editor_insert_rune(text_model.TAB)
	case display.KEY_ESCAPE:
		editor_text.anchor = editor_text.caret
	case:
		if press.character != 0 {
			editor_insert_rune(press.character)
		}
	}
}

@(private = "file")
copy_event :: proc "contextless" (window: ^display.Window, action: display.Copy_Action) {
	if session.mode != .Tables {
		display.copy_decline(window)
		return
	}
	sel_len := text_model.selection_count(&editor_text)
	room := transfer_bytes(sel_len)
	defer system.arena_reset(&transfer_arena)
	count, problem := text_model.selection_copy(&editor_text, room)
	if room == nil && sel_len > 0 {
		problem = .Too_Long
	}
	if problem != .None {
		display.copy_decline(window)
		if problem == .Too_Long {
			core.session_set_problem(&session, .Selection_Too_Long)
		}
		return
	}
	if send_problem, _ := display.copy_send(window, room[:count]); send_problem != .None {
		return
	}
	if action == .Cut && text_model.selection_delete(&editor_text) {
		editor_clear_error_line()
		editor_layout_refresh()
	}
}

@(private = "file")
paste_event :: proc "contextless" (window: ^display.Window, event: display.Event) {
	if session.mode != .Tables {
		return
	}
	room := transfer_bytes(max(event.byte_count, 0))
	defer system.arena_reset(&transfer_arena)
	pasted, problem := display.paste_read(window, event, room, .Multi_Line)
	if problem == .Too_Large {
		core.session_set_problem(&session, .Editor_Full)
		return
	}
	if problem != .None {
		return
	}
	switch text_model.text_insert(&editor_text, room[:pasted]) {
	case .None:
		editor_clear_error_line()
		editor_layout_refresh()
	case .Too_Long:
		core.session_set_problem(&session, .Editor_Full)
	case .Empty, .Not_Text:
	}
}

@(private = "file")
editor_place_of_pointer :: proc "contextless" (x, y: i32) -> int {
	left := int(last_layout.editor_body.x) + core.PANE_PADDING
	top := int(last_layout.editor_body.y) + core.PANE_PADDING
	row_in_view := int(y) < top ? -1 : (int(y) - top) / graphics.CELL_HEIGHT
	row := clamp(editor_top_row + row_in_view, 0, max(editor_layout.row_count - 1, 0))
	col := int(x) < left ? 0 : (int(x) - left + graphics.CELL_WIDTH / 2) / graphics.CELL_WIDTH
	return text_model.place_at_column(&editor_layout, &editor_text, row, col)
}

@(private = "file")
pointer_event :: proc "contextless" (event: display.Event) {
	left := event.buttons & display.BUTTON_LEFT != 0
	pressed := left && pointer_buttons_before & display.BUTTON_LEFT == 0
	pointer_buttons_before = event.buttons
	if pressed && interface.action_bar_takes_pointer(&bar, event.x, event.y) {
		return
	}
	if !has_last_layout {
		return
	}
	px, py := i32(event.x), i32(event.y)

	if !left {
		dragging_editor = false
		dragging_sidebar_divider = false
		dragging_editor_divider = false
		return
	}

	if dragging_sidebar_divider {
		dx := px - drag_last_x
		drag_last_x = px
		room := last_layout.content.width - core.DIVIDER_THICKNESS
		ratios.sidebar_ratio = core.clamp_split_ratio(
			last_layout.content.width,
			core.DIVIDER_THICKNESS,
			core.SIDEBAR_MIN_WIDTH,
			core.RIGHT_MIN_WIDTH,
			box_layout.split_ratio_dragged(ratios.sidebar_ratio, dx, room),
		)
		return
	}
	if dragging_editor_divider {
		dy := py - drag_last_y
		drag_last_y = py
		room := last_layout.right_column.height - core.DIVIDER_THICKNESS
		ratios.editor_ratio = core.clamp_split_ratio(
			last_layout.right_column.height,
			core.DIVIDER_THICKNESS,
			core.EDITOR_MIN_HEIGHT,
			core.GRID_MIN_HEIGHT,
			box_layout.split_ratio_dragged(ratios.editor_ratio, dy, room),
		)
		return
	}

	if pressed {
		if core.rect_contains(last_layout.sidebar_divider, px, py) {
			dragging_sidebar_divider = true
			drag_last_x = px
			return
		}
		if core.rect_contains(last_layout.editor_divider, px, py) {
			dragging_editor_divider = true
			drag_last_y = py
			return
		}
		snap := &snapshots[active_snapshot]
		if session.mode == .Versions {
			if row := core.hit_test_sidebar_row(last_layout.sidebar, sidebar_versions_first_row, session.version_count, px, py); row >= 0 {
				action_preview_version(session.version_count - 1 - row)
				return
			}
		} else {
			if row := core.hit_test_sidebar_row(last_layout.sidebar_tables, sidebar_tables_first_row, snap.table_count, px, py); row >= 0 {
				action_browse_table(row)
				return
			}
		}
		if col := core.hit_test_grid_header(&last_layout, snap, i32(grid_scroll_x), px, py); col >= 0 {
			action_sort_column(col)
			return
		}
		if core.rect_contains(last_layout.editor_body, px, py) && session.mode == .Tables {
			dragging_editor = true
			session.focus = .Editor
			place := editor_place_of_pointer(px, py)
			text_model.selection_set(&editor_text, place, place)
			return
		}
	} else if dragging_editor {
		text_model.selection_set(&editor_text, editor_text.anchor, editor_place_of_pointer(px, py))
		editor_scroll_to_caret()
	}
}

@(private = "file")
draw_sidebar :: proc "contextless" (table: ^interface.Draw_Table, lay: ^core.Window_Layout, snap: ^core.Result_Snapshot) {
	sb := lay.sidebar
	interface.draw_rectangle(table, int(sb.x), int(sb.y), int(sb.width), int(sb.height), tokens.surface_card)
	interface.draw_clip_push(table, int(sb.x), int(sb.y), int(sb.width), int(sb.height))
	defer interface.draw_clip_pop(table)

	left := int(sb.x) + core.PANE_PADDING
	room := max(int(sb.width) - 2 * core.PANE_PADDING, 0)

	if session.mode == .Versions {
		interface.draw_text(table, left, int(sb.y) + (core.PANE_HEADING_HEIGHT - graphics.CELL_HEIGHT) / 2, "VERSIONS", tokens.text_dim, interface.FONT_INTERFACE_BOLD)
		rows_y := int(sb.y) + core.PANE_HEADING_HEIGHT
		visible := max((int(sb.height) - core.PANE_HEADING_HEIGHT) / core.PANE_ROW_HEIGHT, 1)
		chosen_visual := session.version_count - 1 - session.version_chosen
		if chosen_visual < sidebar_versions_first_row {
			sidebar_versions_first_row = max(chosen_visual, 0)
		}
		if chosen_visual >= sidebar_versions_first_row + visible {
			sidebar_versions_first_row = chosen_visual - visible + 1
		}
		sidebar_versions_first_row = clamp(sidebar_versions_first_row, 0, max(session.version_count - visible, 0))
		for row in sidebar_versions_first_row ..< min(session.version_count, sidebar_versions_first_row + visible) {
			y := rows_y + (row - sidebar_versions_first_row) * core.PANE_ROW_HEIGHT
			is_chosen := row == chosen_visual
			if is_chosen {
				interface.draw_rectangle(table, int(sb.x), y, int(sb.width), core.PANE_ROW_HEIGHT, tokens.surface_chosen)
			}
			ver := &session.versions[session.version_count - 1 - row]
			label_buf: [64]u8
			date_buf: [24]u8
			num_buf: [24]u8
			pos := 0
			core.append_text(label_buf[:], &pos, "v")
			core.append_text(label_buf[:], &pos, core.format_i64(ver.generation, num_buf[:]))
			if ver.date != 0 {
				core.append_text(label_buf[:], &pos, " · ")
				core.append_text(label_buf[:], &pos, calendar.iso_text(date_buf[:], ver.date))
			}
			if ver.current {
				core.append_text(label_buf[:], &pos, " (current)")
			}
			label := string(label_buf[:pos])
			color := is_chosen ? tokens.text_on_chosen : tokens.text
			interface.draw_text(table, left, y + (core.PANE_ROW_HEIGHT - graphics.CELL_HEIGHT) / 2, interface.text_fit(table, {}, label, room), color)
		}
		return
	}

	// Top section: Tables.
	tb := lay.sidebar_tables
	interface.draw_text(table, left, int(tb.y) + (core.PANE_HEADING_HEIGHT - graphics.CELL_HEIGHT) / 2, "TABLES", tokens.text_dim, interface.FONT_INTERFACE_BOLD)
	t_rows_y := int(tb.y) + core.PANE_HEADING_HEIGHT
	t_visible := max((int(tb.height) - core.PANE_HEADING_HEIGHT) / core.PANE_ROW_HEIGHT, 1)
	if snap.table_count == 0 {
		interface.draw_text(table, left, t_rows_y + 4, interface.text_fit(table, interface.FONT_INTERFACE, "No tables yet", room), tokens.text_dim, interface.FONT_INTERFACE)
	} else {
		sidebar_tables_first_row = clamp(sidebar_tables_first_row, 0, max(snap.table_count - t_visible, 0))
		for row in sidebar_tables_first_row ..< min(snap.table_count, sidebar_tables_first_row + t_visible) {
			y := t_rows_y + (row - sidebar_tables_first_row) * core.PANE_ROW_HEIGHT
			is_chosen := row == snap.selected_table
			if is_chosen {
				interface.draw_rectangle(table, int(tb.x), y, int(tb.width), core.PANE_ROW_HEIGHT, tokens.surface_chosen)
			}
			name := core.snapshot_table_name(snap, row)
			color := is_chosen ? tokens.text_on_chosen : tokens.text
			interface.draw_text(table, left, y + (core.PANE_ROW_HEIGHT - graphics.CELL_HEIGHT) / 2, interface.text_fit(table, interface.FONT_INTERFACE, name, room), color, interface.FONT_INTERFACE)
		}
	}

	// Divider between Tables and Columns.
	cb := lay.sidebar_columns
	interface.draw_rectangle(table, int(cb.x), int(cb.y) - 1, int(cb.width), 1, tokens.divider)
	interface.draw_text(table, left, int(cb.y) + (core.PANE_HEADING_HEIGHT - graphics.CELL_HEIGHT) / 2, "COLUMNS", tokens.text_dim, interface.FONT_INTERFACE_BOLD)
	c_rows_y := int(cb.y) + core.PANE_HEADING_HEIGHT
	c_visible := max((int(cb.height) - core.PANE_HEADING_HEIGHT) / core.PANE_ROW_HEIGHT, 1)
	sidebar_columns_first_row = clamp(sidebar_columns_first_row, 0, max(snap.schema_column_count - c_visible, 0))
	for row in sidebar_columns_first_row ..< min(snap.schema_column_count, sidebar_columns_first_row + c_visible) {
		y := c_rows_y + (row - sidebar_columns_first_row) * core.PANE_ROW_HEIGHT
		sc := &snap.schema_columns[row]
		col_name := string(sc.name[:sc.name_len])
		col_type := string(sc.type_name[:sc.type_len])
		line_buf: [128]u8
		pos := 0
		core.append_text(line_buf[:], &pos, col_name)
		if len(col_type) > 0 {
			core.append_text(line_buf[:], &pos, "  ")
			core.append_text(line_buf[:], &pos, col_type)
		}
		if sc.primary_key {
			core.append_text(line_buf[:], &pos, "  PK")
		}
		interface.draw_text(table, left, y + (core.PANE_ROW_HEIGHT - graphics.CELL_HEIGHT) / 2, interface.text_fit(table, {}, string(line_buf[:pos]), room), tokens.text_dim)
	}
}

@(private = "file")
draw_editor_row :: proc "contextless" (table: ^interface.Draw_Table, text_left, y, row, sel_first, sel_last: int, is_error_line: bool) {
	if is_error_line {
		interface.draw_rectangle(table, int(last_layout.editor_body.x), y, int(last_layout.editor_body.width), graphics.CELL_HEIGHT, graphics.shade(tokens.failed, 35))
	}
	start := int(editor_layout.rows[row].start)
	end := text_model.row_bytes_end(&editor_layout, &editor_text, row)
	from, to := max(sel_first, start), min(sel_last, end)
	if from < to {
		left := text_left + text_model.column_of(&editor_layout, &editor_text, row, from) * graphics.CELL_WIDTH
		right := text_left + text_model.column_of(&editor_layout, &editor_text, row, to) * graphics.CELL_WIDTH
		interface.draw_rectangle(table, left, y, right - left, graphics.CELL_HEIGHT, tokens.surface_chosen)
	}
	buf: [ROW_BUFFER_SIZE]u8
	count, col, run_col := 0, 0, 0
	run_sel := false
	place := start
	for place < end && count + 4 <= len(buf) {
		sel := place >= sel_first && place < sel_last
		if sel != run_sel && count > 0 {
			interface.draw_text(table, text_left + run_col * graphics.CELL_WIDTH, y, string(buf[:count]), run_sel ? tokens.text_on_chosen : tokens.text)
			count = 0
		}
		if count == 0 {
			run_col, run_sel = col, sel
		}
		b := text_model.byte_at(&editor_text, place)
		if b == text_model.TAB {
			w := text_model.TAB_WIDTH - col % text_model.TAB_WIDTH
			for _ in 0 ..< w {
				buf[count] = ' '
				count += 1
			}
			col += w
			place += 1
		} else {
			ln := text_model.character_length(&editor_text, place)
			for off in 0 ..< ln {
				buf[count] = text_model.byte_at(&editor_text, place + off)
				count += 1
			}
			col += 1
			place += ln
		}
	}
	if count > 0 {
		interface.draw_text(table, text_left + run_col * graphics.CELL_WIDTH, y, string(buf[:count]), run_sel ? tokens.text_on_chosen : tokens.text)
	}
}

@(private = "file")
draw_editor :: proc "contextless" (frame: ^interface.Frame, lay: ^core.Window_Layout) {
	table := frame.table
	hdr := lay.editor_header
	interface.draw_rectangle(table, int(hdr.x), int(hdr.y), int(hdr.width), int(hdr.height), tokens.surface_card)
	interface.draw_rectangle(table, int(hdr.x), int(hdr.y + hdr.height) - 1, int(hdr.width), 1, tokens.divider)
	interface.draw_text(table, int(hdr.x) + core.PANE_PADDING, int(hdr.y) + (int(hdr.height) - graphics.CELL_HEIGHT) / 2, "SQL", tokens.text_dim, interface.FONT_INTERFACE_BOLD)

	body := lay.editor_body
	interface.element_name(frame, to_area(body), "sql editor")
	interface.draw_rectangle(table, int(body.x), int(body.y), int(body.width), int(body.height), tokens.surface_background)

	if new_cols := editor_columns_for_width(body.width); new_cols != editor_columns {
		editor_columns = new_cols
		editor_layout_refresh()
	}
	rows_now := max((int(body.height) - 2 * core.PANE_PADDING) / graphics.CELL_HEIGHT, 1)
	if rows_now != editor_visible_rows {
		editor_visible_rows = rows_now
		editor_scroll_to_caret()
	}
	editor_top_row = clamp(editor_top_row, 0, max(editor_layout.row_count - editor_visible_rows, 0))
	scrolled := interface.scroll_bar(
		frame,
		to_area(lay.editor_scroll),
		interface.identity("db_browser editor scroll"),
		.Vertical,
		{total = max(editor_layout.row_count, 1), visible = editor_visible_rows, first = editor_top_row},
		{},
		"",
		to_area(body),
	)
	if scrolled.changed {
		editor_top_row = scrolled.first
	}

	interface.draw_clip_push(table, int(body.x), int(body.y), int(body.width), int(body.height))
	text_left := int(body.x) + core.PANE_PADDING
	text_top := int(body.y) + core.PANE_PADDING
	sel_first, sel_last := text_model.selection(&editor_text)
	end_row := min(editor_top_row + editor_visible_rows, editor_layout.row_count)
	for row in editor_top_row ..< end_row {
		y := text_top + (row - editor_top_row) * graphics.CELL_HEIGHT
		is_err := editor_error_line >= 0 && int(editor_layout.rows[row].line) == editor_error_line
		draw_editor_row(table, text_left, y, row, sel_first, sel_last, is_err)
	}
	caret_row := text_model.row_of(&editor_layout, editor_text.caret)
	if session.mode == .Tables && caret_row >= editor_top_row && caret_row < end_row {
		caret_col := text_model.column_of(&editor_layout, &editor_text, caret_row, editor_text.caret)
		interface.draw_rectangle(table, text_left + caret_col * graphics.CELL_WIDTH, text_top + (caret_row - editor_top_row) * graphics.CELL_HEIGHT, 2, graphics.CELL_HEIGHT, tokens.text_strong)
	}
	interface.draw_clip_pop(table)
}

@(private = "file")
draw_result_grid :: proc "contextless" (frame: ^interface.Frame, lay: ^core.Window_Layout, snap: ^core.Result_Snapshot) {
	table := frame.table
	hdr := lay.grid_header
	body := lay.grid_body

	// Scrollbars for result rows (vertical) and column pixel width (horizontal).
	visible_rows := max(int(body.height) / core.GRID_ROW_HEIGHT, 1)
	grid_first_row = clamp(grid_first_row, 0, max(snap.row_count - visible_rows, 0))
	v_res := interface.scroll_bar(
		frame,
		to_area(lay.grid_vscroll),
		interface.identity("db_browser grid vscroll"),
		.Vertical,
		{total = max(snap.row_count, 1), visible = visible_rows, first = grid_first_row},
		{},
		"",
		to_area(body),
	)
	if v_res.changed {
		grid_first_row = v_res.first
	}

	total_width := int(core.snapshot_total_grid_width(snap))
	grid_scroll_x = clamp(grid_scroll_x, 0, max(total_width - int(body.width), 0))
	h_res := interface.scroll_bar(
		frame,
		to_area(lay.grid_hscroll),
		interface.identity("db_browser grid hscroll"),
		.Horizontal,
		{total = max(total_width, 1), visible = max(int(body.width), 1), first = grid_scroll_x},
		{line = 32, page = max(int(body.width) / 2, 32)},
	)
	if h_res.changed {
		grid_scroll_x = h_res.first
	}
	corner := lay.grid_corner
	interface.draw_rectangle(table, int(corner.x), int(corner.y), int(corner.width), int(corner.height), tokens.surface_card)

	// Sticky clickable column headers.
	interface.draw_rectangle(table, int(hdr.x), int(hdr.y), int(hdr.width), int(hdr.height), tokens.surface_card)
	interface.draw_rectangle(table, int(hdr.x), int(hdr.y + hdr.height) - 1, int(hdr.width), 1, tokens.divider)
	interface.draw_clip_push(table, int(hdr.x), int(hdr.y), int(hdr.width), int(hdr.height))
	if snap.column_count > 0 {
		x := int(hdr.x) - grid_scroll_x
		for c in 0 ..< snap.column_count {
			cw := int(snap.column_widths[c])
			if x + cw > int(hdr.x) && x < int(hdr.x + hdr.width) {
				col_name := core.snapshot_column_name(snap, c)
				col_left := max(x, int(hdr.x))
				col_right := min(x + cw, int(hdr.x + hdr.width))
				if col_right > col_left && len(col_name) > 0 {
					interface.element_name_joined(frame, {col_left, int(hdr.y), col_right - col_left, int(hdr.height)}, "column", col_name)
				}
				title_buf: [80]u8
				pos := 0
				core.append_text(title_buf[:], &pos, col_name)
				if snap.sort_column == c {
					switch snap.sort_direction {
					case .None:
					case .Ascending:
						core.append_text(title_buf[:], &pos, " ^")
					case .Descending:
						core.append_text(title_buf[:], &pos, " v")
					}
				}
				label := interface.text_fit(table, interface.FONT_INTERFACE_BOLD, string(title_buf[:pos]), max(cw - 12, 0))
				interface.draw_text(table, x + 6, int(hdr.y) + (int(hdr.height) - graphics.CELL_HEIGHT) / 2, label, tokens.text_strong, interface.FONT_INTERFACE_BOLD)
				interface.draw_rectangle(table, x + cw - 1, int(hdr.y), 1, int(hdr.height), tokens.divider)
			}
			x += cw
		}
	}
	interface.draw_clip_pop(table)

	// Virtualized grid body: draws ONLY visible rows.
	interface.draw_rectangle(table, int(body.x), int(body.y), int(body.width), int(body.height), tokens.surface_background)
	interface.draw_clip_push(table, int(body.x), int(body.y), int(body.width), int(body.height))
	defer interface.draw_clip_pop(table)

	if snap.column_count == 0 {
		msg := snap.changes > 0 ? "Statement completed." : "Run a SQL query to inspect results."
		interface.draw_text(table, int(body.x) + core.PANE_PADDING, int(body.y) + core.PANE_PADDING, msg, tokens.text_dim, interface.FONT_INTERFACE)
		return
	}
	if snap.row_count == 0 {
		interface.draw_text(table, int(body.x) + core.PANE_PADDING, int(body.y) + core.PANE_PADDING, "No rows returned.", tokens.text_dim, interface.FONT_INTERFACE)
		return
	}

	end_row := min(grid_first_row + visible_rows + 1, snap.row_count)
	cell_buf: [128]u8
	for vr in grid_first_row ..< end_row {
		y := int(body.y) + (vr - grid_first_row) * core.GRID_ROW_HEIGHT
		if vr % 2 == 1 {
			interface.draw_rectangle(table, int(body.x), y, int(body.width), core.GRID_ROW_HEIGHT, tokens.surface_card)
		}
		x := int(body.x) - grid_scroll_x
		text_y := y + (core.GRID_ROW_HEIGHT - graphics.CELL_HEIGHT) / 2
		for c in 0 ..< snap.column_count {
			cw := int(snap.column_widths[c])
			if x + cw > int(body.x) && x < int(body.x + body.width) {
				txt, align, kind, _ := core.snapshot_cell_display(snap, vr, c, cell_buf[:])
				color := (kind == .Null || kind == .Blob) ? tokens.text_dim : tokens.text
				cell_room := max(cw - 12, 0)
				fitted := interface.text_fit(table, {}, txt, cell_room)
				if align == .Right {
					interface.draw_text_right(table, x + cw - 6, text_y, fitted, color)
				} else {
					interface.draw_text(table, x + 6, text_y, fitted, color)
				}
				interface.draw_rectangle(table, x + cw - 1, y, 1, core.GRID_ROW_HEIGHT, tokens.divider)
			}
			x += cw
		}
	}
}

@(private = "file")
draw_frame :: proc "contextless" (window: ^display.Window) -> interface.Action_Bar_Result {
	frame := interface.window_frame_start(&window_memory, window)
	interface.action_bar_input_take(&frame, &bar)
	table := frame.table
	tokens, _ = box_layout.tokens_for(graphics.appearance, .Standard)

	snap := &snapshots[active_snapshot]
	metrics_buf: [96]u8
	metrics := core.format_status_metrics(
		metrics_buf[:],
		snap.row_count,
		snap.column_count,
		snap.database_bytes,
		snap.generation,
		snap.truncated_rows,
		session.read_only,
	)
	right_width := i32(interface.text_measured_width(table, {}, metrics))
	lay, solved := core.compute_layout(&box_tree, i32(window.width), i32(window.height), ratios, right_width, tokens.gap)
	if !solved {
		interface.window_frame_end(&window_memory.drawing, &frame, window)
		return {}
	}
	last_layout = lay
	has_last_layout = true

	interface.draw_rectangle(table, 0, 0, window.width, window.height, tokens.surface_background)
	draw_sidebar(table, &lay, snap)
	interface.draw_rectangle(table, int(lay.sidebar_divider.x), int(lay.sidebar_divider.y), int(lay.sidebar_divider.width), int(lay.sidebar_divider.height), tokens.divider)

	draw_editor(&frame, &lay)
	interface.draw_rectangle(table, int(lay.editor_divider.x), int(lay.editor_divider.y), int(lay.editor_divider.width), int(lay.editor_divider.height), tokens.divider)
	draw_result_grid(&frame, &lay, snap)

	// Status band.
	interface.draw_rectangle(table, int(lay.status.x), int(lay.status.y), int(lay.status.width), int(lay.status.height), tokens.surface_card)
	interface.draw_rectangle(table, int(lay.status.x), int(lay.status.y), int(lay.status.width), 1, tokens.divider)
	status_buf: [256]u8
	left_sentence := core.session_status_sentence(&session, status_buf[:])
	if left_sentence != "" {
		left_color := tokens.text_dim
		switch session.problem {
		case .None:
			left_color = session.mode == .Versions ? tokens.warning : tokens.text_dim
		case .No_Store, .Store_Revoked, .Read_Only:
			left_color = tokens.warning
		case .Store_Write_Refused, .Database_Too_Large, .Database_Damaged, .Engine_Unavailable, .Engine_Crashed, .Engine_Timeout, .Sql_Error, .Out_Of_Budget, .Queue_Full, .Version_Unreadable, .Store_Pick_Unavailable, .Selection_Too_Long, .Editor_Full:
			left_color = tokens.failed
		}
		interface.draw_text(
			table,
			int(lay.status_left.x),
			int(lay.status_left.y),
			interface.text_fit(table, interface.FONT_INTERFACE, left_sentence, int(lay.status_left.width)),
			left_color,
			interface.FONT_INTERFACE,
		)
	}
	if metrics != "" {
		interface.draw_text(table, int(lay.status_right.x), int(lay.status_right.y), metrics, tokens.text_dim)
	}

	items: [4]interface.Action_Bar_Item
	count := bar_items(&items)
	bar_result := interface.action_bar(&frame, to_area(lay.action_bar), items[:count], &bar, {})
	interface.window_frame_end(&window_memory.drawing, &frame, window)
	return bar_result
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, core.DEFAULT_WIDTH, core.DEFAULT_HEIGHT, "db_browser")
	if !ok {
		system.stop(.Failed)
	}
	_, _ = display.resizable_set(&window, {
		least_width    = core.LEAST_WIDTH,
		least_height   = core.LEAST_HEIGHT,
		largest_width  = core.LARGEST_WIDTH,
		largest_height = core.LARGEST_HEIGHT,
	})

	core.session_init(&session)
	ui_arenas_init()
	editor_layout_refresh()

	if _, st := system.thread_start(worker_thread_entry, ctx, WORKER_THREAD_STACK_PAGES); st != .Succeeded {
		system.stop(.Failed)
	}

	ui_request = {kind = .Open_Initial}
	dispatch_request(&ui_request)

	first_picture := true
	for {
		res_seen := system.event_count(&res_event)
		for worker_pop_result(&ui_result) {
			apply_worker_result(&ui_result)
		}

		bar_result := draw_frame(&window)
		if first_picture {
			first_picture = false
			system.log_fact(.Info, First_Picture_Presented{})
		}
		if bar_result.ran {
			key_run(bar_result.run)
			continue
		}

		wait: system.Wait
		display.wait_events(&wait, &window)
		system.wait_event(&wait, &res_event, res_seen)
		system.wait_end(&wait, system.WAIT_FOREVER)

		for event in display.next_event(&window) {
			switch event.kind {
			case .Pointer:
				place, in_layout, _ := interface.window_scroll_event(&window_memory.drawing, &window, event, .Every_Event)
				if in_layout {
					pointer_event(place)
				} else {
					pointer_buttons_before = event.buttons
				}
			case .Key:
				if !event.pressed {
					continue
				}
				press := interface.Key_Press{code = event.code, character = event.character, modifiers = event.modifiers}
				outcome := interface.action_bar_key(&bar, press)
				if outcome.ran {
					key_run(outcome.run)
				}
				if !outcome.taken {
					key_run(press)
				}
			case .Copy_Asked:
				copy_event(&window, event.copy_action)
			case .Pasted:
				paste_event(&window, event)
			case .Resized:
				if display.surface_resize(&window, event.width, event.height) == .Succeeded {
					interface.draw_whole_window_next(&window_memory.drawing)
				}
			case .Presentation, .Surface_Answer:
				interface.draw_whole_window_next(&window_memory.drawing)
			case .None, .Go_To, .Capture_Size, .Capture_Frame, .Capture_Disconnect, .Capture_Opened, .Work_Area:
			}
		}
	}
}
