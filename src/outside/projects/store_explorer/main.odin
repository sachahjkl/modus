// store_explorer: graphical Store & Version Explorer for modus
// (src/md/features/store_explorer.md).
//
// Two-thread architecture: this UI thread never blocks on storage, hashing,
// or filtering; it renders only visible rows from double-buffered immutable
// snapshots published by worker.odin.
package store_explorer

import "core"
import "modus:calendar"
import "modus:display"
import "modus:graphics"
import "modus:interface"
import box_layout "modus:layout"
import "modus:system"

#assert(core.ACTION_BAR_HEIGHT == interface.ACTION_BAR_ROW_HEIGHT)
#assert(core.SCROLL_BAR_THICKNESS == interface.SCROLL_BAR_THICKNESS)

// Plan value: 8 MiB working memory (two immutable snapshots, layout tree,
// draw table, and worker stack), 1 process, 2 threads, surface up to 1280x960.
// Literals so modustool reads the budget directly without evaluating imports.
MODULE_BUDGET :: system.Stated_Budget {
	working_memory_pages = 2048,
	processes            = 1,
	threads              = 2,
	window_width         = 1280,
	window_height        = 960,
}
#assert(MODULE_BUDGET.window_width == core.LARGEST_WIDTH)
#assert(MODULE_BUDGET.window_height == core.LARGEST_HEIGHT)

window_memory: interface.Window_Memory(2048, 32768)

session: core.Session_State
ratios := core.DEFAULT_SPLIT_RATIOS
box_tree: box_layout.Box_Tree
tokens: box_layout.Element_Tokens
last_layout: core.Window_Layout
has_last_layout: bool

sidebar_stores_first: int
sidebar_path_first: int
sidebar_versions_first: int
list_first_row: int
inspector_first_row: int

bar: interface.Action_Bar_State
ui_request: core.Worker_Request
ui_result: core.Worker_Result

pointer_buttons_before: u32
dragging_sidebar_divider: bool
dragging_middle_divider: bool
drag_last_x: i32
drag_last_y: i32

@(private = "file")
to_area :: proc "contextless" (r: box_layout.Rect) -> interface.Area {
	return {int(r.x), int(r.y), int(r.width), int(r.height)}
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
action_select_entry :: proc "contextless" (index: int) {
	snap := &snapshots[active_snapshot]
	if index < 0 || index >= snap.filtered_count {
		return
	}
	session.inspector_override = false
	inspector_first_row = 0
	ui_request = {kind = .Select_Entry, index = index}
	dispatch_request(&ui_request)
}

@(private = "file")
action_activate_entry :: proc "contextless" (index: int) {
	snap := &snapshots[active_snapshot]
	entry, ok := core.snapshot_filtered_entry(snap, index)
	if !ok {
		return
	}
	if entry.kind == .Tree {
		list_first_row = 0
		inspector_first_row = 0
		ui_request = {kind = .Enter_Tree, index = index}
		dispatch_request(&ui_request)
	} else {
		action_select_entry(index)
	}
}

@(private = "file")
action_open_versions :: proc "contextless" () {
	snap := &snapshots[active_snapshot]
	entry, ok := core.snapshot_filtered_entry(snap, snap.selected_entry)
	if !ok || entry.kind != .Object {
		return
	}
	ui_request = {kind = .List_Versions}
	dispatch_request(&ui_request)
}

@(private = "file")
action_preview_version :: proc "contextless" (index: int) {
	snap := &snapshots[active_snapshot]
	if snap.version_count <= 0 {
		return
	}
	clamped := clamp(index, 0, snap.version_count - 1)
	gen := snap.versions[clamped].generation
	inspector_first_row = 0
	ui_request = {kind = .Preview_Version, index = clamped, generation = gen}
	dispatch_request(&ui_request)
}

@(private = "file")
action_close_versions :: proc "contextless" () {
	session.mode = .Browse
	bar = {}
	inspector_first_row = 0
	ui_request = {kind = .Preview_Version, generation = 0}
	dispatch_request(&ui_request)
}

@(private = "file")
action_restore_version :: proc "contextless" () {
	snap := &snapshots[active_snapshot]
	if !core.session_can_restore(&session, snap) {
		return
	}
	gen := snap.versions[snap.version_chosen].generation
	ui_request = {kind = .Restore_Version, generation = gen}
	dispatch_request(&ui_request)
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

	if res.problem == .Store_Revoked {
		core.session_mark_revoked(&session)
		return
	}
	if res.problem != .None {
		core.session_set_problem(&session, res.problem)
	} else {
		core.session_clear_problem(&session)
	}

	snap := &snapshots[active_snapshot]
	if !session.inspector_override && snap.has_object {
		session.inspector_mode = snap.preview_is_utf8 ? .Text : .Hex
	}

	switch res.kind {
	case .None, .Opened, .Tree_Loaded, .Object_Inspected, .Filtered, .Entry_Changed, .Failed:
	case .Versions_Listed:
		if res.problem == .None && snap.version_count > 0 {
			session.mode = .Versions
			bar = {}
			sidebar_versions_first = 0
		}
	case .Version_Previewed:
	case .Version_Restored:
		if res.problem == .None {
			session.mode = .Browse
			bar = {}
		}
	}
}

@(private = "file")
bar_items :: proc "contextless" (items: ^[7]interface.Action_Bar_Item) -> int {
	if session.prompt == .Confirm_Remove {
		items[0] = interface.action_bar_item("Delete", 4, "Enter")
		items[1] = interface.action_bar_item("Keep", 3, "Esc")
		return 2
	}
	if session.prompt != .None {
		items[0] = interface.action_bar_item("Apply", 4, "Enter")
		items[1] = interface.action_bar_item("Cancel", 3, "Esc")
		return 2
	}
	switch session.mode {
	case .Browse:
		items^ = {
			interface.action_bar_item("Versions", 6, "Ctrl", "H"),
			interface.action_bar_item("Filter", 5, "Ctrl", "F"),
			interface.action_bar_item("New object", 4, "Ctrl", "N"),
			interface.action_bar_item("New tree", 3, "Ctrl", "T"),
			interface.action_bar_item("Delete", 2, "Ctrl", "D"),
			interface.action_bar_item("Hex/Text", 1, "Ctrl", "X"),
			interface.action_bar_item("Refresh", 0, "Ctrl", "R"),
		}
		return 7
	case .Versions:
		items[0] = interface.action_bar_item("Older", 3, "Down")
		items[1] = interface.action_bar_item("Newer", 2, "Up")
		items[2] = interface.action_bar_item("Restore", 4, "Enter")
		items[3] = interface.action_bar_item("Back", 1, "Esc")
		return 4
	}
	return 0
}

@(private = "file")
prompt_submit :: proc "contextless" () {
	mode := session.prompt
	// Copy prompt text before closing/resetting prompt_len.
	submitted_buf: [core.PROMPT_INPUT_MAX]u8
	submitted_len := copy(submitted_buf[:], core.session_prompt_text(&session))
	submitted := string(submitted_buf[:submitted_len])
	core.session_prompt_close(&session)
	bar = {}

	switch mode {
	case .None:
	case .Filter:
		ui_request = {kind = .Apply_Filter}
		ui_request.text_len = copy(ui_request.text[:], submitted)
		list_first_row = 0
		dispatch_request(&ui_request)
	case .New_Object:
		ui_request = {kind = .Create_Object}
		ui_request.text_len = copy(ui_request.text[:], submitted)
		dispatch_request(&ui_request)
	case .New_Tree:
		ui_request = {kind = .Create_Tree}
		ui_request.text_len = copy(ui_request.text[:], submitted)
		dispatch_request(&ui_request)
	case .Confirm_Remove:
		ui_request = {kind = .Remove_Entry}
		ui_request.text_len = copy(ui_request.text[:], submitted)
		dispatch_request(&ui_request)
	}
}

@(private = "file")
key_run :: proc "contextless" (press: interface.Key_Press) {
	if session.prompt != .None {
		switch press.code {
		case display.KEY_ENTER:
			prompt_submit()
		case display.KEY_ESCAPE:
			was_filter := session.prompt == .Filter
			core.session_prompt_close(&session)
			bar = {}
			if was_filter {
				ui_request = {kind = .Apply_Filter, text_len = 0}
				dispatch_request(&ui_request)
			}
		case display.KEY_BACKSPACE:
			if session.prompt != .Confirm_Remove {
				_ = core.session_prompt_backspace(&session)
			}
		case:
			if session.prompt != .Confirm_Remove && press.character != 0 {
				_ = core.session_prompt_push_rune(&session, press.character)
			}
		}
		return
	}

	if session.mode == .Versions {
		snap := &snapshots[active_snapshot]
		switch press.code {
		case display.KEY_DOWN:
			action_preview_version(snap.version_chosen - 1)
		case display.KEY_UP:
			action_preview_version(snap.version_chosen + 1)
		case display.KEY_ENTER:
			action_restore_version()
		case display.KEY_ESCAPE:
			action_close_versions()
		}
		return
	}

	ctrl := press.modifiers & display.MODIFIER_CONTROL != 0
	snap := &snapshots[active_snapshot]
	if ctrl {
		switch press.character {
		case 'h', 'H':
			action_open_versions()
		case 'f', 'F':
			core.session_prompt_open(&session, .Filter, string(snap.filter_text[:snap.filter_len]))
			bar = {}
		case 'n', 'N':
			if !session.read_only {
				core.session_prompt_open(&session, .New_Object)
				bar = {}
			} else {
				core.session_set_problem(&session, .Read_Only)
			}
		case 't', 'T':
			if !session.read_only {
				core.session_prompt_open(&session, .New_Tree)
				bar = {}
			} else {
				core.session_set_problem(&session, .Read_Only)
			}
		case 'd', 'D':
			if entry, ok := core.snapshot_filtered_entry(snap, snap.selected_entry); ok {
				if session.read_only {
					core.session_set_problem(&session, .Read_Only)
				} else {
					core.session_prompt_open(&session, .Confirm_Remove, string(entry.name[:entry.name_len]))
					bar = {}
				}
			}
		case 'x', 'X':
			core.session_toggle_inspector_mode(&session)
			inspector_first_row = 0
		case 'r', 'R':
			ui_request = {kind = .Refresh}
			dispatch_request(&ui_request)
		}
		return
	}

	switch press.code {
	case display.KEY_UP:
		if snap.selected_entry > 0 {
			action_select_entry(snap.selected_entry - 1)
		}
	case display.KEY_DOWN:
		if snap.selected_entry + 1 < snap.filtered_count {
			action_select_entry(snap.selected_entry + 1)
		}
	case display.KEY_ENTER:
		if snap.selected_entry >= 0 {
			action_activate_entry(snap.selected_entry)
		}
	case display.KEY_BACKSPACE:
		if snap.path_depth > 0 {
			list_first_row = 0
			ui_request = {kind = .Navigate_Up}
			dispatch_request(&ui_request)
		}
	}
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
		dragging_sidebar_divider = false
		dragging_middle_divider = false
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
	if dragging_middle_divider {
		dy := py - drag_last_y
		drag_last_y = py
		room := last_layout.right_column.height - core.DIVIDER_THICKNESS
		ratios.list_ratio = core.clamp_split_ratio(
			last_layout.right_column.height,
			core.DIVIDER_THICKNESS,
			core.LIST_MIN_HEIGHT,
			core.INSPECTOR_MIN_HEIGHT,
			box_layout.split_ratio_dragged(ratios.list_ratio, dy, room),
		)
		return
	}

	if !pressed {
		return
	}
	if core.rect_contains(last_layout.sidebar_divider, px, py) {
		dragging_sidebar_divider = true
		drag_last_x = px
		return
	}
	if core.rect_contains(last_layout.middle_divider, px, py) {
		dragging_middle_divider = true
		drag_last_y = py
		return
	}

	snap := &snapshots[active_snapshot]
	if session.mode == .Versions {
		if row := core.hit_test_sidebar_row(last_layout.sidebar, sidebar_versions_first, snap.version_count, px, py); row >= 0 {
			action_preview_version(snap.version_count - 1 - row)
			return
		}
		return
	}

	if row := core.hit_test_sidebar_row(last_layout.sidebar_stores, sidebar_stores_first, snap.store_count, px, py); row >= 0 {
		list_first_row = 0
		ui_request = {kind = .Select_Store, index = row}
		dispatch_request(&ui_request)
		return
	}
	// Sidebar path rows: row 0 is root, row i is depth i.
	if row := core.hit_test_sidebar_row(last_layout.sidebar_path, sidebar_path_first, snap.path_depth + 1, px, py); row >= 0 {
		list_first_row = 0
		ui_request = {kind = .Navigate_Depth, index = row}
		dispatch_request(&ui_request)
		return
	}
	if row := core.hit_test_list_row(last_layout.list_body, list_first_row, snap.filtered_count, px, py); row >= 0 {
		action_activate_entry(row)
		return
	}
}

@(private = "file")
draw_sidebar :: proc "contextless" (table: ^interface.Draw_Table, lay: ^core.Window_Layout, snap: ^core.Explorer_Snapshot) {
	sb := lay.sidebar
	interface.draw_rectangle(table, int(sb.x), int(sb.y), int(sb.width), int(sb.height), tokens.surface_card)
	interface.draw_clip_push(table, int(sb.x), int(sb.y), int(sb.width), int(sb.height))
	defer interface.draw_clip_pop(table)

	left := int(sb.x) + core.PANE_PADDING
	room := max(int(sb.width) - 2 * core.PANE_PADDING, 0)

	if session.mode == .Versions {
		heading := snap.versions_truncated ? "VERSIONS (oldest 128)" : "VERSIONS"
		interface.draw_text(table, left, int(sb.y) + (core.PANE_HEADING_HEIGHT - graphics.CELL_HEIGHT) / 2, interface.text_fit(table, interface.FONT_INTERFACE_BOLD, heading, room), tokens.text_dim, interface.FONT_INTERFACE_BOLD)
		rows_y := int(sb.y) + core.PANE_HEADING_HEIGHT
		visible := max((int(sb.height) - core.PANE_HEADING_HEIGHT) / core.PANE_ROW_HEIGHT, 1)
		chosen_vis := snap.version_count - 1 - snap.version_chosen
		if chosen_vis < sidebar_versions_first {
			sidebar_versions_first = max(chosen_vis, 0)
		}
		if chosen_vis >= sidebar_versions_first + visible {
			sidebar_versions_first = chosen_vis - visible + 1
		}
		sidebar_versions_first = clamp(sidebar_versions_first, 0, max(snap.version_count - visible, 0))
		for row in sidebar_versions_first ..< min(snap.version_count, sidebar_versions_first + visible) {
			y := rows_y + (row - sidebar_versions_first) * core.PANE_ROW_HEIGHT
			is_chosen := row == chosen_vis
			if is_chosen {
				interface.draw_rectangle(table, int(sb.x), y, int(sb.width), core.PANE_ROW_HEIGHT, tokens.surface_chosen)
			}
			ver := &snap.versions[snap.version_count - 1 - row]
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
			color := is_chosen ? tokens.text_on_chosen : tokens.text
			interface.draw_text(table, left, y + (core.PANE_ROW_HEIGHT - graphics.CELL_HEIGHT) / 2, interface.text_fit(table, {}, string(label_buf[:pos]), room), color)
		}
		return
	}

	// Top section: accessible stores.
	st_rect := lay.sidebar_stores
	interface.draw_text(table, left, int(st_rect.y) + (core.PANE_HEADING_HEIGHT - graphics.CELL_HEIGHT) / 2, "STORES", tokens.text_dim, interface.FONT_INTERFACE_BOLD)
	st_y := int(st_rect.y) + core.PANE_HEADING_HEIGHT
	st_vis := max((int(st_rect.height) - core.PANE_HEADING_HEIGHT) / core.PANE_ROW_HEIGHT, 1)
	sidebar_stores_first = clamp(sidebar_stores_first, 0, max(snap.store_count - st_vis, 0))
	for row in sidebar_stores_first ..< min(snap.store_count, sidebar_stores_first + st_vis) {
		y := st_y + (row - sidebar_stores_first) * core.PANE_ROW_HEIGHT
		is_chosen := row == snap.active_store
		if is_chosen {
			interface.draw_rectangle(table, int(st_rect.x), y, int(st_rect.width), core.PANE_ROW_HEIGHT, tokens.surface_chosen)
		}
		color := is_chosen ? tokens.text_on_chosen : tokens.text
		interface.draw_text(table, left, y + (core.PANE_ROW_HEIGHT - graphics.CELL_HEIGHT) / 2, interface.text_fit(table, interface.FONT_INTERFACE, core.snapshot_store_name(snap, row), room), color, interface.FONT_INTERFACE)
	}

	// Bottom section: tree path breadcrumbs.
	pt_rect := lay.sidebar_path
	interface.draw_rectangle(table, int(pt_rect.x), int(pt_rect.y) - 1, int(pt_rect.width), 1, tokens.divider)
	interface.draw_text(table, left, int(pt_rect.y) + (core.PANE_HEADING_HEIGHT - graphics.CELL_HEIGHT) / 2, "PATH", tokens.text_dim, interface.FONT_INTERFACE_BOLD)
	pt_y := int(pt_rect.y) + core.PANE_HEADING_HEIGHT
	pt_total := snap.path_depth + 1
	pt_vis := max((int(pt_rect.height) - core.PANE_HEADING_HEIGHT) / core.PANE_ROW_HEIGHT, 1)
	sidebar_path_first = clamp(sidebar_path_first, 0, max(pt_total - pt_vis, 0))
	for row in sidebar_path_first ..< min(pt_total, sidebar_path_first + pt_vis) {
		y := pt_y + (row - sidebar_path_first) * core.PANE_ROW_HEIGHT
		is_current := row == snap.path_depth
		if is_current {
			interface.draw_rectangle(table, int(pt_rect.x), y, int(pt_rect.width), core.PANE_ROW_HEIGHT, tokens.surface_track)
		}
		label := row == 0 ? "/" : string(snap.path[row - 1].name[:snap.path[row - 1].name_len])
		interface.draw_text(table, left + min(row, 4) * 8, y + (core.PANE_ROW_HEIGHT - graphics.CELL_HEIGHT) / 2, interface.text_fit(table, interface.FONT_INTERFACE, label, max(room - min(row, 4) * 8, 0)), tokens.text, interface.FONT_INTERFACE)
	}
}

@(private = "file")
draw_entries_list :: proc "contextless" (frame: ^interface.Frame, lay: ^core.Window_Layout, snap: ^core.Explorer_Snapshot) {
	table := frame.table
	hdr := lay.list_header
	interface.draw_rectangle(table, int(hdr.x), int(hdr.y), int(hdr.width), int(hdr.height), tokens.surface_card)
	interface.draw_rectangle(table, int(hdr.x), int(hdr.y + hdr.height) - 1, int(hdr.width), 1, tokens.divider)

	path_buf: [256]u8
	crumb := core.format_breadcrumb_path(snap, path_buf[:])
	hdr_buf: [320]u8
	pos := 0
	core.append_text(hdr_buf[:], &pos, crumb)
	if snap.filter_len > 0 {
		core.append_text(hdr_buf[:], &pos, "  [filter: ")
		core.append_text(hdr_buf[:], &pos, string(snap.filter_text[:snap.filter_len]))
		core.append_text(hdr_buf[:], &pos, "]")
	}
	if snap.entries_truncated {
		core.append_text(hdr_buf[:], &pos, "  (first 512 shown)")
	}
	interface.draw_text(
		table,
		int(hdr.x) + core.PANE_PADDING,
		int(hdr.y) + (int(hdr.height) - graphics.CELL_HEIGHT) / 2,
		interface.text_fit(table, interface.FONT_INTERFACE_BOLD, string(hdr_buf[:pos]), max(int(hdr.width) - 2 * core.PANE_PADDING, 0)),
		tokens.text_strong,
		interface.FONT_INTERFACE_BOLD,
	)

	body := lay.list_body
	visible := max(int(body.height) / core.PANE_ROW_HEIGHT, 1)
	if snap.selected_entry >= 0 {
		if snap.selected_entry < list_first_row {
			list_first_row = snap.selected_entry
		}
		if snap.selected_entry >= list_first_row + visible {
			list_first_row = snap.selected_entry - visible + 1
		}
	}
	list_first_row = clamp(list_first_row, 0, max(snap.filtered_count - visible, 0))
	v_res := interface.scroll_bar(
		frame,
		to_area(lay.list_scroll),
		interface.identity("store_explorer list scroll"),
		.Vertical,
		{total = max(snap.filtered_count, 1), visible = visible, first = list_first_row},
		{},
		"",
		to_area(body),
	)
	if v_res.changed {
		list_first_row = v_res.first
	}

	interface.draw_rectangle(table, int(body.x), int(body.y), int(body.width), int(body.height), tokens.surface_background)
	interface.draw_clip_push(table, int(body.x), int(body.y), int(body.width), int(body.height))
	defer interface.draw_clip_pop(table)

	if snap.filtered_count == 0 {
		empty_msg := snap.entry_count == 0 ? "This tree is empty." : "No entry matches the filter."
		interface.draw_text(table, int(body.x) + core.PANE_PADDING, int(body.y) + core.PANE_PADDING, empty_msg, tokens.text_dim, interface.FONT_INTERFACE)
		return
	}

	end_row := min(list_first_row + visible + 1, snap.filtered_count)
	for r in list_first_row ..< end_row {
		entry, ok := core.snapshot_filtered_entry(snap, r)
		if !ok {
			continue
		}
		y := int(body.y) + (r - list_first_row) * core.PANE_ROW_HEIGHT
		is_sel := r == snap.selected_entry
		if is_sel {
			interface.draw_rectangle(table, int(body.x), y, int(body.width), core.PANE_ROW_HEIGHT, tokens.surface_chosen)
		} else if r % 2 == 1 {
			interface.draw_rectangle(table, int(body.x), y, int(body.width), core.PANE_ROW_HEIGHT, tokens.surface_card)
		}
		text_y := y + (core.PANE_ROW_HEIGHT - graphics.CELL_HEIGHT) / 2
		meta_buf: [64]u8
		sz_buf: [32]u8
		num_buf: [24]u8
		m_pos := 0
		if entry.kind == .Tree {
			core.append_text(meta_buf[:], &m_pos, "[tree]")
		} else {
			core.append_text(meta_buf[:], &m_pos, core.format_byte_size(entry.size, sz_buf[:]))
			if entry.generation > 0 {
				core.append_text(meta_buf[:], &m_pos, " · v")
				core.append_text(meta_buf[:], &m_pos, core.format_i64(entry.generation, num_buf[:]))
			}
		}
		meta_str := string(meta_buf[:m_pos])
		meta_w := interface.text_measured_width(table, {}, meta_str)
		name_room := max(int(body.width) - 3 * core.PANE_PADDING - meta_w, 0)
		name_color := is_sel ? tokens.text_on_chosen : tokens.text
		meta_color := is_sel ? tokens.text_on_chosen : tokens.text_dim
		interface.draw_text(table, int(body.x) + core.PANE_PADDING, text_y, interface.text_fit(table, interface.FONT_INTERFACE, string(entry.name[:entry.name_len]), name_room), name_color, interface.FONT_INTERFACE)
		interface.draw_text_right(table, int(body.x + body.width) - core.PANE_PADDING, text_y, meta_str, meta_color)
	}
}

@(private = "file")
draw_inspector :: proc "contextless" (frame: ^interface.Frame, lay: ^core.Window_Layout, snap: ^core.Explorer_Snapshot) {
	table := frame.table
	hdr := lay.inspector_header
	body := lay.inspector_body

	interface.draw_rectangle(table, int(hdr.x), int(hdr.y), int(hdr.width), int(hdr.height), tokens.surface_card)
	interface.draw_rectangle(table, int(hdr.x), int(hdr.y + hdr.height) - 1, int(hdr.width), 1, tokens.divider)

	hdr_buf: [256]u8
	pos := 0
	if !snap.has_object {
		core.append_text(hdr_buf[:], &pos, "INSPECTOR")
	} else {
		core.append_text(hdr_buf[:], &pos, string(snap.object_name[:snap.object_name_len]))
		core.append_text(hdr_buf[:], &pos, " · ")
		sz_buf: [32]u8
		core.append_text(hdr_buf[:], &pos, core.format_byte_size(snap.object_size, sz_buf[:]))
		if snap.has_hash {
			hash_buf: [16]u8
			core.append_text(hdr_buf[:], &pos, " · blake3:")
			core.append_text(hdr_buf[:], &pos, core.format_blake3_hex(snap.object_hash, hash_buf[:]))
		}
		core.append_text(hdr_buf[:], &pos, session.inspector_mode == .Text ? " · Text" : " · Hex")
		if snap.preview_truncated {
			core.append_text(hdr_buf[:], &pos, " (first 64 KiB)")
		}
		if session.mode == .Versions {
			diff_buf: [64]u8
			core.append_text(hdr_buf[:], &pos, " · ")
			core.append_text(hdr_buf[:], &pos, core.format_diff_summary(snap.diff_ranges[:snap.diff_count], diff_buf[:]))
		}
	}
	interface.draw_text(
		table,
		int(hdr.x) + core.PANE_PADDING,
		int(hdr.y) + (int(hdr.height) - graphics.CELL_HEIGHT) / 2,
		interface.text_fit(table, {}, string(hdr_buf[:pos]), max(int(hdr.width) - 2 * core.PANE_PADDING, 0)),
		tokens.text_dim,
	)

	total_rows := 0
	if snap.has_object {
		total_rows = session.inspector_mode == .Text ? snap.preview_line_count : core.hex_row_count(snap.preview_len)
	}
	visible := max((int(body.height) - 2 * core.PANE_PADDING) / graphics.CELL_HEIGHT, 1)
	inspector_first_row = clamp(inspector_first_row, 0, max(total_rows - visible, 0))
	v_res := interface.scroll_bar(
		frame,
		to_area(lay.inspector_scroll),
		interface.identity("store_explorer inspector scroll"),
		.Vertical,
		{total = max(total_rows, 1), visible = visible, first = inspector_first_row},
		{},
		"",
		to_area(body),
	)
	if v_res.changed {
		inspector_first_row = v_res.first
	}

	interface.draw_rectangle(table, int(body.x), int(body.y), int(body.width), int(body.height), tokens.surface_background)
	interface.draw_clip_push(table, int(body.x), int(body.y), int(body.width), int(body.height))
	defer interface.draw_clip_pop(table)

	if !snap.has_object {
		interface.draw_text(table, int(body.x) + core.PANE_PADDING, int(body.y) + core.PANE_PADDING, "Select an object to inspect its contents and hash.", tokens.text_dim, interface.FONT_INTERFACE)
		return
	}
	if snap.preview_len == 0 {
		interface.draw_text(table, int(body.x) + core.PANE_PADDING, int(body.y) + core.PANE_PADDING, "Empty object (0 B).", tokens.text_dim, interface.FONT_INTERFACE)
		return
	}

	left := int(body.x) + core.PANE_PADDING
	top := int(body.y) + core.PANE_PADDING
	room := max(int(body.width) - 2 * core.PANE_PADDING, 0)
	end_row := min(inspector_first_row + visible + 1, total_rows)
	hex_buf: [96]u8
	for r in inspector_first_row ..< end_row {
		y := top + (r - inspector_first_row) * graphics.CELL_HEIGHT
		if session.inspector_mode == .Hex {
			line := core.format_hex_row(snap.preview_bytes[:snap.preview_len], r, hex_buf[:])
			interface.draw_text(table, left, y, interface.text_fit(table, {}, line, room), tokens.text)
		} else {
			span := snap.preview_lines[r]
			if int(span.start) <= snap.preview_len && int(span.length) <= snap.preview_len - int(span.start) {
				line := string(snap.preview_bytes[span.start:][:span.length])
				interface.draw_text(table, left, y, interface.text_fit(table, {}, line, room), tokens.text)
			}
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
	right_buf: [128]u8
	right_text := core.format_usage_summary(snap.usage, session.read_only, right_buf[:])
	right_width := i32(interface.text_measured_width(table, {}, right_text))
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

	draw_entries_list(&frame, &lay, snap)
	interface.draw_rectangle(table, int(lay.middle_divider.x), int(lay.middle_divider.y), int(lay.middle_divider.width), int(lay.middle_divider.height), tokens.divider)
	draw_inspector(&frame, &lay, snap)

	// Status band.
	interface.draw_rectangle(table, int(lay.status.x), int(lay.status.y), int(lay.status.width), int(lay.status.height), tokens.surface_card)
	interface.draw_rectangle(table, int(lay.status.x), int(lay.status.y), int(lay.status.width), 1, tokens.divider)
	left_buf: [256]u8
	left_sentence := core.session_status_sentence(&session, snap, left_buf[:])
	if left_sentence != "" {
		left_color := tokens.text_dim
		if session.prompt == .Confirm_Remove {
			left_color = tokens.warning
		} else if session.prompt != .None {
			left_color = tokens.text_strong
		} else {
			switch session.problem {
			case .None:
				left_color = session.mode == .Versions ? tokens.warning : tokens.text_dim
			case .No_Store, .Store_Revoked, .Read_Only:
				left_color = tokens.warning
			case .Store_Open_Refused, .Tree_Read_Refused, .Object_Damaged, .Object_Unreadable, .Name_Refused, .Entry_Exists, .Write_Refused, .Remove_Refused, .Version_Unreadable, .Restore_Refused, .Path_Too_Deep, .Queue_Full:
				left_color = tokens.failed
			}
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
	if right_text != "" {
		interface.draw_text(table, int(lay.status_right.x), int(lay.status_right.y), right_text, tokens.text_dim)
	}

	items: [7]interface.Action_Bar_Item
	count := bar_items(&items)
	bar_result := interface.action_bar(&frame, to_area(lay.action_bar), items[:count], &bar, {})
	interface.window_frame_end(&window_memory.drawing, &frame, window)
	return bar_result
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, core.DEFAULT_WIDTH, core.DEFAULT_HEIGHT, "store_explorer")
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
			case .Resized:
				if display.surface_resize(&window, event.width, event.height) == .Succeeded {
					interface.draw_whole_window_next(&window_memory.drawing)
				}
			case .Presentation, .Surface_Answer:
				interface.draw_whole_window_next(&window_memory.drawing)
			case .None, .Copy_Asked, .Pasted, .Go_To, .Capture_Size, .Capture_Frame, .Capture_Disconnect, .Capture_Opened, .Work_Area:
			}
		}
	}
}
