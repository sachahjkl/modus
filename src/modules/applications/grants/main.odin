// The desktop Grants window (src/md/features/grants_window.md): displays
// active recorded grants of running processes, any active wide grant, and
// remembered disk grants for the current principal session, with one-click
// inline-confirmed revocation.
//
// **Grants**, as the root service gives them:
// - **Grants_Manage**: a root ring restricted strictly to reading and
//   revoking grants of the caller's own principal session (never Allow,
//   Start, Stop, Replace, or Acts_For_Principal).
package grants_window

import "internal:grants/grants_model"
import "modus:contract/module"
import "modus:contract/reference_screen"
import "modus:contract/scale_factor"
import "modus:display"
import "modus:graphics"
import "modus:interface"
import box_layout "modus:layout"
import "modus:system"

// Computed: working memory holds module state (~90 pages), glyph cache
// (display.TEXT_MEMORY_PAGES), worker stack (interface.BACKGROUND_STACK_PAGES),
// and module/stack overhead matching the resizable notes application budget.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 1700, processes = 1, threads = 2, window_width = LARGEST_WIDTH, window_height = LARGEST_HEIGHT}
#assert(LEAST_HEIGHT + 40 <= scale_factor.WORK_AREA_LEAST_HEIGHT)
WINDOW_SCREEN_WIDTH :: min((u64(LARGEST_WIDTH) * u64(scale_factor.LARGEST) + scale_factor.EIGHTHS_OF_ONE / 2) / scale_factor.EIGHTHS_OF_ONE, u64(reference_screen.WIDTH))
WINDOW_SCREEN_HEIGHT :: min((u64(LARGEST_HEIGHT) * u64(scale_factor.LARGEST) + scale_factor.EIGHTHS_OF_ONE / 2) / scale_factor.EIGHTHS_OF_ONE, u64(reference_screen.HEIGHT))
WINDOW_PAGES :: (2 * WINDOW_SCREEN_WIDTH * WINDOW_SCREEN_HEIGHT * 4 + system.PAGE_SIZE - 1) / system.PAGE_SIZE
#assert(u64(MODULE_BUDGET.working_memory_pages) + WINDOW_PAGES <= module.LARGEST_BUDGET_LEAST_PAGES)

// Preallocated frame drawing memory and layout tree (never on the stack).
window_memory: interface.Window_Memory(512, 16384)
box_tree: box_layout.Box_Tree

// Immutable snapshot and precomputed flat display list; rebuilt only when the
// worker completes a job, never per frame.
active_snapshot: grants_model.Snapshot
display_list: grants_model.Display_List
row_y_offsets: [grants_model.DISPLAY_ROW_CAPACITY + 1]int
total_content_height: int
scroll_offset: int

confirm_state: grants_model.Confirm_State
status_text: [STATUS_TEXT_CAPACITY]u8
status_length: int
status_is_warning: bool
action_bar_state: interface.Action_Bar_State

// Refresh timer for active wide-grant remaining time display (10 s; no per-frame
// wake while idle without an active wide grant).
WIDE_GRANT_TICK_MILLISECONDS :: u64(10_000)

FONT_SECTION_TITLE :: interface.Font{kind = .Interface, size = graphics.TEXT_CAPTION * interface.TEXT_SIZE_UNITS, weight = .Bold}
FONT_PROCESS_NAME :: interface.Font{size = graphics.TEXT_BODY * interface.TEXT_SIZE_UNITS, weight = .Bold}
FONT_MONO :: interface.Font{size = graphics.TEXT_BODY * interface.TEXT_SIZE_UNITS}
FONT_MONO_CAPTION :: interface.Font{size = graphics.TEXT_CAPTION * interface.TEXT_SIZE_UNITS}

bar_items :: proc "contextless" () -> [4]interface.Action_Bar_Item {
	return {
		interface.action_bar_item("Next", 2, "Tab"),
		interface.action_bar_item("Activate", 3, "Enter"),
		interface.action_bar_item("Refresh", 3, "R"),
		interface.action_bar_item("Cancel", 1, "Escape"),
	}
}

@(private = "file")
row_height_of :: proc "contextless" (kind: grants_model.Display_Row_Kind) -> int {
	switch kind {
	case .Section_Heading:
		return SECTION_HEADING_HEIGHT
	case .Process_Heading:
		return PROCESS_HEADING_HEIGHT
	case .Empty_Notice, .Wide_Grant_Item, .Process_Grant, .Disk_Grant_Item, .Truncation_Notice:
		return ROW_HEIGHT
	}
	return ROW_HEIGHT
}

// rebuild_display_list updates the precomputed flat row array and prefix y
// offsets once when a new snapshot arrives.
@(private = "file")
rebuild_display_list :: proc "contextless" () {
	grants_model.display_list_build(&display_list, &active_snapshot)
	grants_model.confirm_reconcile(&confirm_state, &active_snapshot)
	y := 0
	for i in 0 ..< display_list.count {
		if display_list.rows[i].kind == .Section_Heading && i > 0 {
			y += graphics.GAP
		}
		row_y_offsets[i] = y
		y += row_height_of(display_list.rows[i].kind)
	}
	row_y_offsets[display_list.count] = y
	total_content_height = y
}

@(private = "file")
clamp_scroll :: proc "contextless" (visible_height: int) {
	max_scroll := max(total_content_height - visible_height, 0)
	if scroll_offset < 0 {
		scroll_offset = 0
	} else if scroll_offset > max_scroll {
		scroll_offset = max_scroll
	}
}

@(private = "file")
section_title_and_accent :: proc "contextless" (section: grants_model.Section_Kind) -> (title: string, accent: graphics.Color) {
	switch section {
	case .Wide_Grant:
		return "ACTIVE WIDE GRANT", active_snapshot.wide_grant.active ? graphics.colors.warning : graphics.colors.not_usable
	case .Process:
		return "RUNNING PROCESS GRANTS", graphics.colors.process
	case .Disk_Grant:
		return "REMEMBERED DISK GRANTS", graphics.colors.memory
	}
	return "", graphics.colors.dim
}

@(private = "file")
empty_notice_text :: proc "contextless" (section: grants_model.Section_Kind) -> string {
	switch section {
	case .Wide_Grant:
		return "No active wide grant."
	case .Process:
		return "No running process holds a revocable grant."
	case .Disk_Grant:
		return "No remembered disk grant."
	}
	return ""
}

@(private = "file")
execute_confirmed_action :: proc "contextless" (target: grants_model.Action_Target) {
	switch target.kind {
	case .None:
	case .Wide_Grant:
		if active_snapshot.wide_grant.active {
			if worker_ask_revoke_wide(active_snapshot.wide_grant.client_key) {
				grants_model.confirm_cancel(&confirm_state)
			}
		}
	case .Process_Grant:
		if target.process_index >= 0 && target.process_index < active_snapshot.process_count {
			name := grants_model.process_row_name(&active_snapshot.processes[target.process_index])
			if worker_ask_revoke_process(name, target.root_grant) {
				grants_model.confirm_cancel(&confirm_state)
			}
		}
	case .Disk_Grant:
		if target.disk_index >= 0 && target.disk_index < active_snapshot.disk_count {
			nickname := grants_model.disk_row_nickname(&active_snapshot.disks[target.disk_index])
			if worker_ask_disallow_disk(nickname) {
				grants_model.confirm_cancel(&confirm_state)
			}
		}
	}
}

// draw_action_controls renders either a single Revoke/Disallow button or the
// inline action-named Confirm + Cancel pair on the right side of a row.
@(private = "file")
draw_action_controls :: proc "contextless" (
	frame: ^interface.Frame,
	row_area: interface.Area,
	row_index: int,
	target: grants_model.Action_Target,
	action_label: string,
	confirm_label: string,
	busy: bool,
	redraw: ^bool,
) -> (left_of_buttons: int) {
	right := row_area.x + row_area.width - 8
	btn_y := row_area.y + 3
	btn_h := row_area.height - 6
	if grants_model.confirm_matches(&confirm_state, target) {
		cancel_area := interface.Area{right - CANCEL_BUTTON_WIDTH, btn_y, CANCEL_BUTTON_WIDTH, btn_h}
		confirm_area := interface.Area{cancel_area.x - 6 - CONFIRM_BUTTON_WIDTH, btn_y, CONFIRM_BUTTON_WIDTH, btn_h}
		cancel_id := interface.identity_with(interface.identity("cancel_action"), row_index)
		confirm_id := interface.identity_with(interface.identity("confirm_action"), row_index)
		if !busy {
			if interface.button(frame, confirm_area, confirm_id, confirm_label).activated {
				execute_confirmed_action(target)
				redraw^ = true
			}
			if interface.button(frame, cancel_area, cancel_id, "Cancel").activated {
				grants_model.confirm_cancel(&confirm_state)
				redraw^ = true
			}
		} else {
			interface.draw_text(frame.table, confirm_area.x, btn_y + 4, "Working...", graphics.colors.dim, interface.FONT_INTERFACE)
		}
		return confirm_area.x - 8
	}
	action_area := interface.Area{right - ACTION_BUTTON_WIDTH, btn_y, ACTION_BUTTON_WIDTH, btn_h}
	action_id := interface.identity_with(interface.identity("arm_action"), row_index)
	if !busy {
		if interface.button(frame, action_area, action_id, action_label).activated {
			if grants_model.confirm_arm(&confirm_state, &active_snapshot, target) {
				redraw^ = true
			}
		}
	} else {
		interface.draw_outline(frame.table, action_area.x, action_area.y, action_area.width, action_area.height, 1, graphics.colors.track)
		interface.draw_text(frame.table, action_area.x + 12, btn_y + 4, action_label, graphics.colors.dim, interface.FONT_INTERFACE)
	}
	return action_area.x - 8
}

// draw renders one frame using modus:layout and draws only visible rows inside
// the clipped viewport. redraw is true when an activation changed UI state so
// the caller draws the updated controls immediately.
draw :: proc "contextless" (window: ^display.Window) -> (bar_result: interface.Action_Bar_Result, redraw: bool) {
	frame := interface.window_frame_start(&window_memory, window)
	table := frame.table
	tokens, tokens_ok := box_layout.tokens_for(graphics.appearance, .Standard)
	if !tokens_ok {
		interface.window_frame_end(&window_memory.drawing, &frame, window)
		return {}, false
	}
	interface.draw_rectangle(table, 0, 0, window.width, window.height, tokens.surface_background)

	boxes, layout_ok := grants_layout(&box_tree, window.width, window.height, tokens)
	if !layout_ok {
		interface.window_frame_end(&window_memory.drawing, &frame, window)
		return {}, false
	}

	busy := interface.background_work_busy(&worker_bg)

	// Header: concise status on the left, Refresh button on the right.
	if status_length > 0 {
		status_color := status_is_warning ? graphics.colors.failed : graphics.colors.process
		shown := interface.text_fit(table, interface.FONT_INTERFACE, string(status_text[:status_length]), boxes.status_area.width)
		interface.draw_text(table, boxes.status_area.x, boxes.status_area.y + (boxes.status_area.height - graphics.CELL_HEIGHT) / 2, shown, status_color, interface.FONT_INTERFACE)
	} else if busy && !active_snapshot.loaded {
		interface.draw_text(table, boxes.status_area.x, boxes.status_area.y + (boxes.status_area.height - graphics.CELL_HEIGHT) / 2, "Loading session grants...", graphics.colors.dim, interface.FONT_INTERFACE)
	}
	refresh_label := busy ? "Refreshing" : "Refresh"
	if interface.button(&frame, boxes.refresh_button, interface.identity("refresh_grants"), refresh_label).activated && !busy {
		if worker_ask_refresh() {
			redraw = true
		}
	}

	// Scroll bar and keyboard scrolling.
	viewport := boxes.viewport
	clamp_scroll(viewport.height)
	page_step := max(viewport.height - ROW_HEIGHT, ROW_HEIGHT)
	for &key in frame.input.keys[:frame.input.key_count] {
		if key.taken {
			continue
		}
		switch {
		case key.code == display.KEY_ESCAPE:
			if confirm_state.armed {
				grants_model.confirm_cancel(&confirm_state)
				redraw = true
				key.taken = true
			}
		case key.code == display.KEY_PAGE_UP:
			scroll_offset -= page_step
			clamp_scroll(viewport.height)
			redraw = true
			key.taken = true
		case key.code == display.KEY_PAGE_DOWN:
			scroll_offset += page_step
			clamp_scroll(viewport.height)
			redraw = true
			key.taken = true
		case key.character == 'r' || key.character == 'R':
			if !busy && worker_ask_refresh() {
				redraw = true
				key.taken = true
			}
		}
	}

	if total_content_height > viewport.height {
		moved := interface.scroll_bar(&frame, boxes.scroll_bar, interface.identity("grants_scroll"), .Vertical, {total = total_content_height, visible = viewport.height, first = scroll_offset}, {line = ROW_HEIGHT, page = page_step}, "grants", viewport)
		if moved.changed {
			scroll_offset = moved.first
			clamp_scroll(viewport.height)
			redraw = true
		}
	}

	// Viewport surface and visible row pass.
	interface.draw_vertical_gradient(table, viewport.x, viewport.y, viewport.width, viewport.height, graphics.colors.card_top, graphics.colors.card_bottom)
	interface.draw_outline(table, viewport.x, viewport.y, viewport.width, viewport.height, 1, graphics.colors.track)
	interface.draw_clip_push(table, viewport.x + 1, viewport.y + 1, viewport.width - 2, viewport.height - 2)

	now_ms := system.time()
	for i in 0 ..< display_list.count {
		row := display_list.rows[i]
		row_h := row_height_of(row.kind)
		y := viewport.y + 6 + row_y_offsets[i] - scroll_offset
		if y + row_h <= viewport.y || y >= viewport.y + viewport.height {
			continue
		}
		row_area := interface.Area{viewport.x + 8, y, viewport.width - 16, row_h}
		switch row.kind {
		case .Section_Heading:
			title, accent := section_title_and_accent(row.section)
			interface.draw_rectangle(table, row_area.x, row_area.y + 7, 4, 16, accent)
			interface.draw_text(table, row_area.x + 12, row_area.y + 7, title, accent, FONT_SECTION_TITLE)
			interface.draw_rectangle(table, row_area.x, row_area.y + row_area.height - 1, row_area.width, 1, graphics.colors.track)
		case .Empty_Notice:
			interface.draw_text(table, row_area.x + 12, row_area.y + 8, empty_notice_text(row.section), graphics.colors.dim, interface.FONT_INTERFACE)
		case .Wide_Grant_Item:
			wg := &active_snapshot.wide_grant
			target := grants_model.Action_Target{kind = .Wide_Grant}
			text_limit := draw_action_controls(&frame, row_area, i, target, "Revoke", "Confirm revoke", busy, &redraw)
			key_words := transmute([4]u64)wg.client_key
			hex_buf: [16]u8
			scope_buf: [32]u8
			time_buf: [24]u8
			line_buf: [120]u8
			w := system.Writer{buffer = line_buf[:]}
			system.write_part(&w, grants_model.format_hex_prefix(&hex_buf, key_words[0]))
			system.write_part(&w, "  ")
			system.write_part(&w, grants_model.format_wide_scopes(&scope_buf, wg.scopes))
			system.write_part(&w, "  (")
			system.write_part(&w, grants_model.format_remaining_time(&time_buf, now_ms, wg.ends_at_ms))
			system.write_part(&w, ")")
			shown := interface.text_fit(table, FONT_MONO, system.written(&w), max(text_limit - (row_area.x + 12), 0))
			interface.draw_text(table, row_area.x + 12, row_area.y + 8, shown, graphics.colors.text, FONT_MONO)
		case .Process_Heading:
			if row.process_index >= 0 && row.process_index < active_snapshot.process_count {
				name := grants_model.process_row_name(&active_snapshot.processes[row.process_index])
				interface.draw_text(table, row_area.x + 12, row_area.y + 6, name, graphics.colors.text_strong, FONT_PROCESS_NAME)
			}
		case .Process_Grant:
			grant_name := system.root_grant_names[row.root_grant]
			if row.removable {
				target := grants_model.Action_Target{kind = .Process_Grant, process_index = row.process_index, root_grant = row.root_grant}
				text_limit := draw_action_controls(&frame, row_area, i, target, "Revoke", "Confirm revoke", busy, &redraw)
				shown := interface.text_fit(table, FONT_MONO, grant_name, max(text_limit - (row_area.x + 28), 0))
				interface.draw_text(table, row_area.x + 28, row_area.y + 8, shown, graphics.colors.text, FONT_MONO)
			} else {
				line_buf: [64]u8
				w := system.Writer{buffer = line_buf[:]}
				system.write_part(&w, grant_name)
				system.write_part(&w, "  revoked")
				shown := interface.text_fit(table, FONT_MONO, system.written(&w), max(row_area.width - 36, 0))
				interface.draw_text(table, row_area.x + 28, row_area.y + 8, shown, graphics.colors.dim, FONT_MONO)
			}
		case .Disk_Grant_Item:
			if row.disk_index >= 0 && row.disk_index < active_snapshot.disk_count {
				drow := &active_snapshot.disks[row.disk_index]
				text_limit := row_area.x + row_area.width - 8
				if row.removable {
					target := grants_model.Action_Target{kind = .Disk_Grant, disk_index = row.disk_index, disk_grant = row.disk_grant}
					text_limit = draw_action_controls(&frame, row_area, i, target, "Disallow", "Confirm disallow", busy, &redraw)
				}
				hex_buf: [16]u8
				line_buf: [128]u8
				w := system.Writer{buffer = line_buf[:]}
				system.write_part(&w, grants_model.disk_row_nickname(drow))
				system.write_part(&w, "  ")
				system.write_part(&w, grants_model.format_hex_prefix(&hex_buf, drow.hash_prefix))
				system.write_part(&w, "  ")
				system.write_part(&w, grants_model.disk_row_grant_label(row))
				system.write_part(&w, "  ")
				system.write_part(&w, grants_model.disk_persistence_label(drow))
				shown := interface.text_fit(table, FONT_MONO_CAPTION, system.written(&w), max(text_limit - (row_area.x + 12), 0))
				interface.draw_text(table, row_area.x + 12, row_area.y + 9, shown, row.removable ? graphics.colors.text : graphics.colors.dim, FONT_MONO_CAPTION)
			}
		case .Truncation_Notice:
			extra := row.section == .Process ? active_snapshot.processes_truncated : active_snapshot.disks_truncated
			note_buf: [80]u8
			w := system.Writer{buffer = note_buf[:]}
			system.write_part(&w, extra)
			system.write_part(&w, " more entries are not shown.")
			interface.draw_text(table, row_area.x + 12, row_area.y + 8, system.written(&w), graphics.colors.dim, interface.FONT_INTERFACE)
		}
	}
	interface.draw_clip_pop(table)

	items := bar_items()
	bar_result = interface.action_bar(&frame, boxes.action_bar, items[:], &action_bar_state, {})
	interface.window_frame_end(&window_memory.drawing, &frame, window)
	return bar_result, redraw
}

@(private = "file")
take_worker_result :: proc "contextless" () -> bool {
	if !interface.background_work_take(&worker_bg) {
		return false
	}
	if worker_result.has_snapshot {
		active_snapshot = worker_result.snapshot
		rebuild_display_list()
	}
	status_length = copy(status_text[:], worker_result.status_text[:worker_result.status_length])
	status_is_warning = worker_result.status_is_warning
	return true
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	if !worker_start(ctx) {
		system.stop(.Failed)
	}
	window, ok := display.open(ctx, WIDTH, HEIGHT, "grants")
	if !ok {
		system.stop(.Failed)
	}
	_, _ = display.resizable_set(&window, {least_width = LEAST_WIDTH, least_height = LEAST_HEIGHT, largest_width = LARGEST_WIDTH, largest_height = LARGEST_HEIGHT})

	rebuild_display_list()
	_ = worker_ask_refresh()
	_, _ = draw(&window)
	system.log_fact(.Info, Running{})

	wide_grant_next_tick: u64
	for {
		if take_worker_result() {
			wide_grant_next_tick = active_snapshot.wide_grant.active ? system.time() + WIDE_GRANT_TICK_MILLISECONDS : 0
			_, _ = draw(&window)
		}
		wait: system.Wait
		display.wait_events(&wait, &window)
		worker_ready := interface.background_work_wait(&wait, &worker_bg)
		deadline := system.WAIT_FOREVER
		if worker_ready {
			deadline = system.time()
		} else if active_snapshot.wide_grant.active {
			if wide_grant_next_tick == 0 {
				wide_grant_next_tick = system.time() + WIDE_GRANT_TICK_MILLISECONDS
			}
			deadline = wide_grant_next_tick
		} else {
			wide_grant_next_tick = 0
		}
		system.wait_end(&wait, deadline)

		changed := take_worker_result()
		if changed {
			wide_grant_next_tick = active_snapshot.wide_grant.active ? system.time() + WIDE_GRANT_TICK_MILLISECONDS : 0
		}
		if interface.window_events(&window_memory.drawing, &window) {
			changed = true
		}
		if active_snapshot.wide_grant.active && wide_grant_next_tick != 0 {
			now := system.time()
			if now >= wide_grant_next_tick {
				changed = true
				wide_grant_next_tick = now + WIDE_GRANT_TICK_MILLISECONDS
			}
		}
		if changed {
			bar_result, redraw := draw(&window)
			if bar_result.ran {
				switch {
				case bar_result.run.character == 'r' || bar_result.run.character == 'R':
					_ = worker_ask_refresh()
				case bar_result.run.code == display.KEY_ESCAPE:
					grants_model.confirm_cancel(&confirm_state)
				}
				redraw = true
			}
			if redraw {
				_, _ = draw(&window)
			}
		}
	}
}
