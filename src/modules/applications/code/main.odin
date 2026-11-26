// Content-addressed AST code editor (src/md/features/codebase_ast.md).
//
// Displays and edits binary MODAST1 AST definitions with Unison-style
// alpha-normalized BLAKE3 content hashes and a Dion-style projected cursor.
// All storage I/O runs off the window thread via interface.Background_Work,
// and all AST projection and C preview lowering run only on edits or toggles,
// never inside draw().
package code

import "modus:ast_codebase"
import "modus:contract/value_kinds"
import "modus:display"
import "modus:graphics"
import "modus:interface"
import box_layout "modus:layout"
import "modus:storage"
import "modus:system"
import "modus:text_model"

// Window surface limits (resizable from 480x320 up to 1280x960, 880x600 default).
WIDTH :: 880
HEIGHT :: 600
LEAST_WIDTH :: 480
LEAST_HEIGHT :: 320
LARGEST_WIDTH :: 1280
LARGEST_HEIGHT :: 960

// Plan value: layout chrome dimensions in logical pixels.
SIDEBAR_WIDTH :: 232
DIVIDER_WIDTH :: 1
HEADER_HEIGHT :: 36
STATUS_HEIGHT :: 24
SIDEBAR_HEADING_HEIGHT :: 28
SIDEBAR_ROW_HEIGHT :: graphics.CELL_HEIGHT + 10
SIDEBAR_PADDING :: 10
CODE_PADDING :: 12
LINE_NUM_WIDTH :: 36
CARET_WIDTH :: 2

// PS/2 Set 1 scan code for F2 (immediately precedes display.KEY_F3 = 0x3D).
KEY_F2 :: 0x3C

// Plan value: private store object name for the binary MODAST1 codebase.
CODEBASE_OBJECT_NAME :: "codebase.ast"

// Plan value: working memory budget covers AST pools, projected tokens,
// undo snapshots, store transfer buffers, glyph cache, and two thread stacks.
MODULE_BUDGET :: system.Stated_Budget{
	working_memory_pages = 2048,
	processes            = 1,
	threads              = 2,
	window_width         = LARGEST_WIDTH,
	window_height        = LARGEST_HEIGHT,
	window_least_width   = LEAST_WIDTH,
	window_least_height  = LEAST_HEIGHT,
}

// Plan value: capacity of the in-memory MODAST1 snapshot ring for instant
// Ctrl+Z undo and Ctrl+Y redo.
HISTORY_CAPACITY :: 32
HISTORY_SLOT_BYTES :: 8192

// Plan value: maximum transfer size of one encoded MODAST1 store object.
STORE_BUFFER_BYTES :: 65536

// Plan value: emitted C preview buffer and precomputed line span index.
C_PREVIEW_BYTES :: 32768
C_PREVIEW_MAX_LINES :: 512

// Window draw-table memory (2048 records, 32 KiB text table per double frame).
window_memory: interface.Window_Memory(2048, 32768)
box_tree: box_layout.Box_Tree
tokens: box_layout.Element_Tokens
bar: interface.Action_Bar_State

// Closed set of status-band problem messages obeying docs/WRITING.md.
Window_Problem :: enum u8 {
	None           = 0,
	No_Store       = 1,
	Not_Kept       = 2,
	Full           = 3,
	Rename_Refused = 4,
	Corrupt_Store  = 5,
}

@(rodata)
window_problem_texts := [Window_Problem]string {
	.None           = "",
	.No_Store       = "No store: changes are not kept after this window stops.",
	.Not_Kept       = "The store refused the codebase: changes are not kept.",
	.Full           = "The codebase reached its capacity limit.",
	.Rename_Refused = "That name cannot be used: enter a unique identifier starting with a letter.",
	.Corrupt_Store  = "The stored codebase could not be read: loaded the sample codebase.",
}

// Closed set of main pane display modes.
View_Mode :: enum u8 {
	Ast_Editor = 0,
	Emitted_C  = 1,
}

// Closed set of background store jobs.
Store_Job_Kind :: enum u8 {
	None  = 0,
	Load  = 1,
	Write = 2,
}

// Closed set of background store job outcomes.
Store_Outcome :: enum u8 {
	None     = 0,
	No_Store = 1,
	Absent   = 2,
	Loaded   = 3,
	Written  = 4,
	Refused  = 5,
}

Line_Span :: struct {
	start: u32,
	len:   u32,
}

// Static application state (kept in module memory, never on a stack).
codebase: ast_codebase.Codebase
editor: ast_codebase.Ast_Editor
view_mode: View_Mode = .Ast_Editor
problem_shown: Window_Problem = .None
top_line: int = 0
visible_lines: int = 1
sidebar_first_row: int = 0

// Precomputed C preview lines and per-line syntax carry states (updated only
// on edit or Ctrl+E, never in draw()).
C_LINE_HIGHLIGHT_LIMIT :: 256
c_preview_buf: [C_PREVIEW_BYTES]u8
c_preview_len: int = 0
c_preview_lines: [C_PREVIEW_MAX_LINES]Line_Span
c_preview_carries: [C_PREVIEW_MAX_LINES]text_model.Syntax_Carry
c_preview_line_count: int = 0

// Instant Undo/Redo MODAST1 snapshot history.
history_blobs: [HISTORY_CAPACITY][HISTORY_SLOT_BYTES]u8
history_lens: [HISTORY_CAPACITY]int
history_count: int = 0
history_cursor: int = -1

// Cached hit-test geometry from the last frame.
sidebar_rows_area: interface.Area
code_view_area: interface.Area
code_text_left: int = 0
code_text_top: int = 0
pointer_buttons_before: u32 = 0

// Background store worker state (all storage calls run off the window thread).
store_work: interface.Background_Work
store_ctx: ^system.Context
store_client: storage.Client
store_open_attempted: bool = false
store_available: bool = false
store_job_kind: Store_Job_Kind = .None
store_outcome: Store_Outcome = .None
store_generation: i64 = 0
store_read_buf: [STORE_BUFFER_BYTES]u8
store_read_len: int = 0
store_write_buf: [STORE_BUFFER_BYTES]u8
store_write_len: int = 0
commit_dirty: bool = false
new_def_serial: int = 1

store_read_room :: proc "contextless" (data: rawptr, minimum: int) -> (room: []u8, ok: bool) {
	_ = data
	if minimum < 0 || minimum > len(store_read_buf) {
		return nil, false
	}
	return store_read_buf[:minimum], true
}

// store_worker_job runs exclusively on interface.Background_Work's thread.
store_worker_job :: proc "contextless" (parameter: rawptr) {
	_ = parameter
	if !store_open_attempted {
		store_open_attempted = true
		client, ok := storage.open(store_ctx)
		if ok {
			store_client = client
			store_available = true
		} else {
			store_available = false
		}
	}
	if !store_available {
		store_outcome = .No_Store
		return
	}
	switch store_job_kind {
	case .None:
		store_outcome = .None
	case .Load:
		bytes, read_outcome, status := storage.read_whole(&store_client, storage.ROOT, CODEBASE_OBJECT_NAME, store_read_room, nil)
		switch read_outcome {
		case .Read:
			store_read_len = len(bytes)
			store_outcome = .Loaded
		case .Absent:
			store_read_len = 0
			store_outcome = .Absent
		case .Too_Long, .Refused:
			_ = status
			store_read_len = 0
			store_outcome = .Refused
		}
	case .Write:
		gen, status := storage.write_whole(&store_client, storage.ROOT, CODEBASE_OBJECT_NAME, store_write_buf[:store_write_len])
		if status == .Ok {
			store_generation = gen
			store_outcome = .Written
		} else {
			store_outcome = .Refused
		}
	}
}

schedule_store_write :: proc "contextless" () {
	if !store_available || interface.background_work_busy(&store_work) {
		commit_dirty = true
		return
	}
	written, err := ast_codebase.codebase_encode(&codebase, store_write_buf[:])
	if err != .Ok {
		problem_shown = .Full
		commit_dirty = false
		return
	}
	store_write_len = written
	store_job_kind = .Write
	store_outcome = .None
	commit_dirty = false
	_ = interface.background_work_ask(&store_work, store_worker_job, nil)
}

// refresh_c_preview lowers the AST to freestanding C, slices line offsets, and
// precomputes per-line Syntax_Carry states once after an edit or mode toggle
// so draw() stays strictly O(visible cells).
refresh_c_preview :: proc "contextless" () {
	c_preview_line_count = 0
	written, ok := ast_codebase.ast_emit_c(&codebase, c_preview_buf[:])
	if !ok {
		c_preview_len = 0
		return
	}
	c_preview_len = written
	line_start := 0
	carry := text_model.Syntax_Carry(0)
	for i in 0 ..< c_preview_len {
		if c_preview_buf[i] == '\n' {
			if c_preview_line_count < C_PREVIEW_MAX_LINES {
				span := Line_Span{start = u32(line_start), len = u32(i - line_start)}
				c_preview_lines[c_preview_line_count] = span
				c_preview_carries[c_preview_line_count] = carry
				line_bytes := c_preview_buf[span.start:span.start + span.len]
				carry = text_model.syntax_highlight_row(.C, line_bytes, carry, true, nil) & ~text_model.SYNTAX_CARRY_STRING
				c_preview_line_count += 1
			}
			line_start = i + 1
		}
	}
	if line_start < c_preview_len && c_preview_line_count < C_PREVIEW_MAX_LINES {
		span := Line_Span{start = u32(line_start), len = u32(c_preview_len - line_start)}
		c_preview_lines[c_preview_line_count] = span
		c_preview_carries[c_preview_line_count] = carry
		c_preview_line_count += 1
	}
}

history_reset_with_current :: proc "contextless" () {
	written, err := ast_codebase.codebase_encode(&codebase, history_blobs[0][:])
	if err != .Ok {
		history_count = 0
		history_cursor = -1
		return
	}
	history_lens[0] = written
	history_count = 1
	history_cursor = 0
}

history_push_current :: proc "contextless" () {
	slot := history_cursor + 1
	if slot >= HISTORY_CAPACITY {
		// Drop the oldest snapshot so recent history stays bounded.
		for i in 1 ..< HISTORY_CAPACITY {
			history_blobs[i - 1] = history_blobs[i]
			history_lens[i - 1] = history_lens[i]
		}
		slot = HISTORY_CAPACITY - 1
	}
	written, err := ast_codebase.codebase_encode(&codebase, history_blobs[slot][:])
	if err != .Ok {
		return
	}
	history_lens[slot] = written
	history_cursor = slot
	history_count = slot + 1
}

apply_history_slot :: proc "contextless" (slot: int) -> bool {
	if slot < 0 || slot >= history_count {
		return false
	}
	prev_def := editor.active_def
	if ast_codebase.codebase_decode(history_blobs[slot][:history_lens[slot]], &codebase) != .Ok {
		return false
	}
	history_cursor = slot
	target_def := clamp(prev_def, 0, max(int(codebase.def_count) - 1, 0))
	ast_codebase.ast_editor_init(&editor, &codebase, target_def)
	if view_mode == .Emitted_C {
		refresh_c_preview()
	}
	schedule_store_write()
	return true
}

mark_edited :: proc "contextless" () {
	if problem_shown == .Rename_Refused || problem_shown == .Full {
		problem_shown = store_available ? .None : .No_Store
	}
	history_push_current()
	if view_mode == .Emitted_C {
		refresh_c_preview()
	}
	schedule_store_write()
}

add_new_definition :: proc "contextless" () {
	if editor.inline_active {
		_ = ast_codebase.ast_editor_commit_inline(&editor, &codebase)
	}
	name_buf: [24]u8
	def_name := ""
	for attempt := 0; attempt < 256; attempt += 1 {
		candidate := system.format(name_buf[:], "fn_", u64(new_def_serial))
		new_def_serial += 1
		if _, exists := ast_codebase.codebase_find_name(&codebase, candidate); !exists {
			def_name = candidate
			break
		}
	}
	if len(def_name) == 0 {
		problem_shown = .Full
		return
	}
	px, ok_px := ast_codebase.param_make("x", .Int)
	hole_id, ok_h := ast_codebase.ast_add_hole(&codebase, .Int)
	ret_id, ok_r := ast_codebase.ast_add_return(&codebase, hole_id)
	if !ok_px || !ok_h || !ok_r {
		problem_shown = .Full
		return
	}
	stmts := [1]ast_codebase.Node_Id{ret_id}
	body_id, ok_b := ast_codebase.ast_add_block(&codebase, stmts[:])
	if !ok_b {
		problem_shown = .Full
		return
	}
	params := [1]ast_codebase.Param{px}
	new_idx, ok_def := ast_codebase.codebase_add_definition(&codebase, def_name, params[:], .Int, body_id)
	if !ok_def {
		problem_shown = .Full
		return
	}
	_ = ast_codebase.ast_editor_select_def(&editor, &codebase, new_idx)
	top_line = 0
	mark_edited()
}

scroll_to_cursor :: proc "contextless" () {
	total := view_mode == .Emitted_C ? c_preview_line_count : editor.line_count
	if view_mode == .Ast_Editor {
		if editor.cursor_line < top_line {
			top_line = editor.cursor_line
		}
		if editor.cursor_line >= top_line + visible_lines {
			top_line = editor.cursor_line - visible_lines + 1
		}
	}
	top_line = clamp(top_line, 0, max(total - visible_lines, 0))
}

bar_items :: proc "contextless" (items: ^[6]interface.Action_Bar_Item) -> int {
	preview_label := view_mode == .Emitted_C ? "Edit AST" : "Preview C"
	items^ = {
		interface.action_bar_item("New definition", 5, "Ctrl", "N"),
		interface.action_bar_item("Rename", 4, "Ctrl", "R"),
		interface.action_bar_item("Next hole", 3, "Tab"),
		interface.action_bar_item(preview_label, 2, "Ctrl", "E"),
		interface.action_bar_item("Undo", 1, "Ctrl", "Z"),
		interface.action_bar_item("Redo", 0, "Ctrl", "Y"),
	}
	return 6
}

key_run :: proc "contextless" (press: interface.Key_Press) {
	control := press.modifiers & display.MODIFIER_CONTROL != 0
	shift := press.modifiers & display.MODIFIER_SHIFT != 0
	alt := press.modifiers & display.MODIFIER_ALT != 0

	if control {
		switch press.code {
		case display.KEY_UP:
			if editor.active_def > 0 {
				_ = ast_codebase.ast_editor_select_def(&editor, &codebase, editor.active_def - 1)
				top_line = 0
			}
			return
		case display.KEY_DOWN:
			if editor.active_def + 1 < int(codebase.def_count) {
				_ = ast_codebase.ast_editor_select_def(&editor, &codebase, editor.active_def + 1)
				top_line = 0
			}
			return
		}
		switch press.character {
		case 'n', 'N':
			view_mode = .Ast_Editor
			add_new_definition()
		case 'r', 'R':
			view_mode = .Ast_Editor
			_ = ast_codebase.ast_editor_action(&editor, &codebase, .Begin_Rename)
		case 'e', 'E':
			if editor.inline_active {
				_ = ast_codebase.ast_editor_commit_inline(&editor, &codebase)
			}
			if view_mode == .Ast_Editor {
				view_mode = .Emitted_C
				refresh_c_preview()
			} else {
				view_mode = .Ast_Editor
			}
			top_line = 0
		case 'z', 'Z':
			if history_cursor > 0 {
				_ = apply_history_slot(history_cursor - 1)
			}
		case 'y', 'Y':
			if history_cursor + 1 < history_count {
				_ = apply_history_slot(history_cursor + 1)
			}
		}
		return
	}

	if alt {
		switch press.code {
		case display.KEY_UP:
			if view_mode == .Ast_Editor {
				_ = ast_codebase.ast_editor_action(&editor, &codebase, .Expand_Selection)
				scroll_to_cursor()
			}
			return
		case display.KEY_DOWN:
			if view_mode == .Ast_Editor {
				_ = ast_codebase.ast_editor_action(&editor, &codebase, .Shrink_Selection)
				scroll_to_cursor()
			}
			return
		}
	}

	// Emitted C preview mode scrolls with Up/Down/Page Up/Page Down/Esc.
	if view_mode == .Emitted_C {
		switch press.code {
		case display.KEY_UP:
			top_line = max(top_line - 1, 0)
		case display.KEY_DOWN:
			top_line = min(top_line + 1, max(c_preview_line_count - visible_lines, 0))
		case display.KEY_ESCAPE:
			view_mode = .Ast_Editor
			top_line = 0
		}
		return
	}

	switch press.code {
	case KEY_F2:
		_ = ast_codebase.ast_editor_action(&editor, &codebase, .Begin_Rename)
	case display.KEY_LEFT:
		_ = ast_codebase.ast_editor_action(&editor, &codebase, .Left)
	case display.KEY_RIGHT:
		_ = ast_codebase.ast_editor_action(&editor, &codebase, .Right)
	case display.KEY_UP:
		_ = ast_codebase.ast_editor_action(&editor, &codebase, .Up)
	case display.KEY_DOWN:
		_ = ast_codebase.ast_editor_action(&editor, &codebase, .Down)
	case display.KEY_TAB:
		_ = ast_codebase.ast_editor_action(&editor, &codebase, shift ? .Prev_Hole : .Next_Hole)
	case display.KEY_ENTER:
		was_rename := editor.inline_active && (editor.inline_target == .Def_Name || editor.inline_target == .Param_Name || editor.inline_target == .Let_Name)
		renamed_def := editor.inline_def
		was_def_rename := editor.inline_active && editor.inline_target == .Def_Name
		if editor.inline_active {
			if ast_codebase.ast_editor_commit_inline(&editor, &codebase) {
				if was_def_rename {
					dname := ast_codebase.codebase_def_display_name(&codebase, renamed_def)
					system.log_fact(.Info, Definition_Renamed{name = value_kinds.text_field(dname, NAME_FIELD_BYTES)})
				}
				if was_rename || editor.last_hash_changed {
					mark_edited()
				}
			} else {
				problem_shown = .Rename_Refused
			}
		} else if ast_codebase.ast_editor_action(&editor, &codebase, .Insert_Stmt) {
			mark_edited()
		}
	case display.KEY_ESCAPE:
		_ = ast_codebase.ast_editor_action(&editor, &codebase, .Cancel_Inline)
	case display.KEY_BACKSPACE:
		if ast_codebase.ast_editor_action(&editor, &codebase, .Backspace) {
			if !editor.inline_active {
				mark_edited()
			}
		}
	case:
		if press.character >= 0x20 && press.character <= 0x7E {
			if ast_codebase.ast_editor_type_char(&editor, &codebase, press.character) {
				if !editor.inline_active || editor.last_hash_changed {
					mark_edited()
				}
			}
		}
	}
	scroll_to_cursor()
}

inside :: proc "contextless" (area: interface.Area, x, y: int) -> bool {
	return x >= area.x && x < area.x + area.width && y >= area.y && y < area.y + area.height
}

pointer_event :: proc "contextless" (event: display.Event) {
	left := event.buttons & display.BUTTON_LEFT != 0
	pressed := left && pointer_buttons_before & display.BUTTON_LEFT == 0
	pointer_buttons_before = event.buttons
	if pressed && interface.action_bar_takes_pointer(&bar, event.x, event.y) {
		return
	}
	if !pressed {
		return
	}
	if inside(sidebar_rows_area, event.x, event.y) {
		row := sidebar_first_row + (event.y - sidebar_rows_area.y) / SIDEBAR_ROW_HEIGHT
		if row >= 0 && row < int(codebase.def_count) {
			_ = ast_codebase.ast_editor_select_def(&editor, &codebase, row)
			view_mode = .Ast_Editor
			top_line = 0
		}
		return
	}
	if view_mode == .Ast_Editor && inside(code_view_area, event.x, event.y) {
		line := top_line + (event.y - code_text_top) / graphics.CELL_HEIGHT
		col := event.x < code_text_left ? 0 : (event.x - code_text_left) / graphics.CELL_WIDTH
		_ = ast_codebase.ast_editor_click_at(&editor, &codebase, line, col)
	}
}

handle_store_completion :: proc "contextless" () {
	outcome := store_outcome
	kind := store_job_kind
	store_outcome = .None
	store_job_kind = .None

	switch outcome {
	case .None:
	case .No_Store:
		problem_shown = .No_Store
		system.log_fact(.Info, No_Store{})
	case .Absent:
		// Fresh store: persist the initial sample codebase.
		schedule_store_write()
	case .Loaded:
		if ast_codebase.codebase_decode(store_read_buf[:store_read_len], &codebase) == .Ok && codebase.def_count > 0 {
			ast_codebase.ast_editor_init(&editor, &codebase, 0)
			history_reset_with_current()
			if view_mode == .Emitted_C {
				refresh_c_preview()
			}
			problem_shown = .None
			system.log_fact(.Info, Codebase_Restored{definitions = u64(codebase.def_count), bytes = u64(store_read_len)})
		} else {
			_ = ast_codebase.codebase_seed_sample(&codebase)
			ast_codebase.ast_editor_init(&editor, &codebase, 0)
			history_reset_with_current()
			problem_shown = .Corrupt_Store
		}
	case .Written:
		if problem_shown == .Not_Kept {
			problem_shown = .None
		}
		system.log_fact(.Info, Codebase_Committed{generation = store_generation, bytes = u64(store_write_len)})
		if commit_dirty {
			schedule_store_write()
		}
	case .Refused:
		if kind == .Write {
			problem_shown = .Not_Kept
		}
	}
}

// --- Box layout & rendering (strictly O(visible lines), zero AST walks) ---

Window_Boxes :: struct {
	sidebar, divider, right_col, header, code_area, scroll_bar, status, status_left, status_right, action_bar: box_layout.Box_Index,
}

area_of :: proc "contextless" (index: box_layout.Box_Index) -> interface.Area {
	box := box_layout.box_of(&box_tree, index)
	if box == nil {
		return {}
	}
	return {int(box.rect.x), int(box.rect.y), int(box.rect.width), int(box.rect.height)}
}

layout_build :: proc "contextless" (window: ^display.Window, table: ^interface.Draw_Table, right_status: string) -> (boxes: Window_Boxes) {
	w := i32(clamp(window.width, 0, box_layout.LENGTH_LIMIT))
	h := i32(clamp(window.height, 0, box_layout.LENGTH_LIMIT))
	_ = box_layout.tree_begin(&box_tree, w, h, {label = "code", child_axis = .Y})

	// Main horizontal split: DEFINITIONS sidebar | divider | header + editor.
	_, _ = box_layout.box_open(&box_tree, {size = {.X = box_layout.fill(), .Y = box_layout.fill()}, child_axis = .X, overflow = {.X = .Clip, .Y = .Clip}})
	boxes.sidebar, _ = box_layout.box_add(&box_tree, {size = {.X = box_layout.px(SIDEBAR_WIDTH), .Y = box_layout.fill()}})
	boxes.divider, _ = box_layout.box_add(&box_tree, {size = {.X = box_layout.px(DIVIDER_WIDTH), .Y = box_layout.fill()}})

	boxes.right_col, _ = box_layout.box_open(&box_tree, {size = {.X = box_layout.fill(), .Y = box_layout.fill()}, child_axis = .Y})
	boxes.header, _ = box_layout.box_add(&box_tree, {size = {.X = box_layout.fill(), .Y = box_layout.px(HEADER_HEIGHT)}})
	_, _ = box_layout.box_open(&box_tree, {size = {.X = box_layout.fill(), .Y = box_layout.fill()}, child_axis = .X})
	boxes.code_area, _ = box_layout.box_add(&box_tree, {size = {.X = box_layout.fill(), .Y = box_layout.fill()}})
	boxes.scroll_bar, _ = box_layout.box_add(&box_tree, {size = {.X = box_layout.px(interface.SCROLL_BAR_THICKNESS), .Y = box_layout.fill()}})
	_ = box_layout.box_close(&box_tree)
	_ = box_layout.box_close(&box_tree)
	_ = box_layout.box_close(&box_tree)

	right_width := i32(interface.text_measured_width(table, {}, right_status))
	boxes.status, _ = box_layout.box_open(&box_tree, {size = {.X = box_layout.fill(), .Y = box_layout.px(STATUS_HEIGHT)}, child_axis = .X, cross_align = .Center, padding = {.X = tokens.gap, .Y = 0}, gap = 2 * tokens.gap})
	boxes.status_left, _ = box_layout.box_add(&box_tree, {size = {.X = box_layout.fill(), .Y = box_layout.px(graphics.CELL_HEIGHT)}})
	boxes.status_right, _ = box_layout.box_add(&box_tree, {size = {.X = box_layout.text_size(), .Y = box_layout.px(graphics.CELL_HEIGHT)}, text_width = right_width})
	_ = box_layout.box_close(&box_tree)

	boxes.action_bar, _ = box_layout.box_add(&box_tree, {size = {.X = box_layout.fill(), .Y = box_layout.px(interface.ACTION_BAR_ROW_HEIGHT)}})
	_ = box_layout.solve(&box_tree)
	return
}

draw_sidebar :: proc "contextless" (table: ^interface.Draw_Table, area: interface.Area) {
	interface.draw_rectangle(table, area.x, area.y, area.width, area.height, tokens.surface_card)
	interface.draw_clip_push(table, area.x, area.y, area.width, area.height)
	defer interface.draw_clip_pop(table)

	left := area.x + SIDEBAR_PADDING
	interface.draw_text(table, left, area.y + (SIDEBAR_HEADING_HEIGHT - graphics.CELL_HEIGHT) / 2, "DEFINITIONS", tokens.text_dim, interface.FONT_INTERFACE_BOLD)

	sidebar_rows_area = {area.x, area.y + SIDEBAR_HEADING_HEIGHT, area.width, max(area.height - SIDEBAR_HEADING_HEIGHT, 0)}
	row_room := max(sidebar_rows_area.height / SIDEBAR_ROW_HEIGHT, 1)
	total := int(codebase.def_count)
	if editor.active_def < sidebar_first_row {
		sidebar_first_row = max(editor.active_def, 0)
	}
	if editor.active_def >= sidebar_first_row + row_room {
		sidebar_first_row = editor.active_def - row_room + 1
	}
	sidebar_first_row = clamp(sidebar_first_row, 0, max(total - row_room, 0))

	hash_col_w := 8 * graphics.CELL_WIDTH
	name_room := max(area.width - 2 * SIDEBAR_PADDING - hash_col_w - 8, 24)

	for row in sidebar_first_row ..< min(total, sidebar_first_row + row_room) {
		y := sidebar_rows_area.y + (row - sidebar_first_row) * SIDEBAR_ROW_HEIGHT
		is_active := row == editor.active_def
		if is_active {
			interface.draw_rectangle(table, area.x, y, area.width, SIDEBAR_ROW_HEIGHT, tokens.surface_chosen)
		}
		text_y := y + (SIDEBAR_ROW_HEIGHT - graphics.CELL_HEIGHT) / 2
		name_color := is_active ? tokens.text_on_chosen : tokens.text
		hash_color := is_active ? tokens.text_on_chosen : tokens.text_dim

		dname := ast_codebase.codebase_def_display_name(&codebase, row)
		if len(dname) == 0 {
			dname = "unnamed"
		}
		interface.draw_text(table, left, text_y, interface.text_fit(table, {}, dname, name_room), name_color)

		hex_buf: [16]u8
		badge := ast_codebase.hash_hex_prefix(codebase.defs[row].hash, hex_buf[:], 8)
		badge_x := area.x + area.width - SIDEBAR_PADDING - hash_col_w
		interface.draw_text(table, badge_x, text_y, badge, hash_color)
	}
}

draw_header :: proc "contextless" (table: ^interface.Draw_Table, area: interface.Area) {
	interface.draw_rectangle(table, area.x, area.y, area.width, area.height, tokens.surface_card)
	interface.draw_rectangle(table, area.x, area.y + area.height - 1, area.width, 1, tokens.divider)
	interface.draw_clip_push(table, area.x, area.y, area.width, area.height)
	defer interface.draw_clip_pop(table)

	text_y := area.y + (area.height - graphics.CELL_HEIGHT) / 2
	mode_tag := view_mode == .Emitted_C ? "EMITTED C" : "AST EDITOR"
	interface.draw_text(table, area.x + CODE_PADDING, text_y, mode_tag, tokens.text_dim, interface.FONT_INTERFACE_BOLD)

	if editor.active_def >= 0 && editor.active_def < int(codebase.def_count) {
		def := &codebase.defs[editor.active_def]
		dname := ast_codebase.codebase_def_display_name(&codebase, editor.active_def)
		hex_buf: [24]u8
		hex16 := ast_codebase.hash_hex_prefix(def.hash, hex_buf[:], 16)
		hdr_buf: [128]u8
		hdr := system.format(hdr_buf[:], dname, "  blake3:", hex16)
		hdr_w := interface.text_measured_width(table, {}, hdr)
		hx := max(area.x + CODE_PADDING + 116, area.x + area.width - CODE_PADDING - hdr_w)
		interface.draw_text(table, hx, text_y, interface.text_fit(table, {}, hdr, area.x + area.width - hx - CODE_PADDING), tokens.expected)
	}
}

token_draw_color :: proc "contextless" (class: graphics.Code_Class) -> graphics.Color {
	if class == .None {
		return tokens.text
	}
	return graphics.code_class_color(class, graphics.appearance)
}

draw_ast_lines :: proc "contextless" (table: ^interface.Draw_Table, area: interface.Area) {
	end_line := min(top_line + visible_lines, editor.line_count)
	for line_idx in top_line ..< end_line {
		y := code_text_top + (line_idx - top_line) * graphics.CELL_HEIGHT
		// Line number gutter.
		num_buf: [12]u8
		num_str := system.format(num_buf[:], u64(line_idx + 1))
		interface.draw_text(table, area.x + CODE_PADDING, y, num_str, tokens.text_dim)

		line := &editor.lines[line_idx]
		start := int(line.token_start)
		end := start + int(line.token_count)
		for tok_idx in start ..< end {
			tok := &editor.tokens[tok_idx]
			tx := code_text_left + int(tok.col_start) * graphics.CELL_WIDTH
			tw := max(int(tok.col_end - tok.col_start), 1) * graphics.CELL_WIDTH
			txt := ast_codebase.token_text(tok)

			is_cursor := tok_idx == editor.cursor_token
			if tok.slot == .Hole {
				// Crisp `?` hole pill highlight.
				bg := is_cursor ? tokens.surface_chosen : tokens.surface_recess
				fg := is_cursor ? tokens.text_on_chosen : tokens.warning
				interface.draw_rectangle(table, tx - 2, y, tw + 4, graphics.CELL_HEIGHT, bg)
				interface.draw_text(table, tx, y, txt, fg, interface.FONT_BOLD)
			} else if is_cursor {
				interface.draw_rectangle(table, tx - 1, y, tw + 2, graphics.CELL_HEIGHT, tokens.surface_chosen)
				interface.draw_text(table, tx, y, txt, tokens.text_on_chosen)
				if editor.inline_active {
					interface.draw_rectangle(table, tx + tw, y, CARET_WIDTH, graphics.CELL_HEIGHT, tokens.text_strong)
				}
			} else if tok.in_selection {
				interface.draw_rectangle(table, tx, y, tw, graphics.CELL_HEIGHT, tokens.surface_recess)
				interface.draw_text(table, tx, y, txt, token_draw_color(tok.code_class))
			} else {
				interface.draw_text(table, tx, y, txt, token_draw_color(tok.code_class))
			}
		}
	}
}

draw_c_preview_lines :: proc "contextless" (table: ^interface.Draw_Table, area: interface.Area) {
	room := max(area.width - LINE_NUM_WIDTH - 2 * CODE_PADDING, 16)
	max_cols := min(room / graphics.CELL_WIDTH, C_LINE_HIGHLIGHT_LIMIT)
	end_line := min(top_line + visible_lines, c_preview_line_count)
	classes: [C_LINE_HIGHLIGHT_LIMIT]graphics.Code_Class
	for line_idx in top_line ..< end_line {
		y := code_text_top + (line_idx - top_line) * graphics.CELL_HEIGHT
		num_buf: [12]u8
		num_str := system.format(num_buf[:], u64(line_idx + 1))
		interface.draw_text(table, area.x + CODE_PADDING, y, num_str, tokens.text_dim)

		span := c_preview_lines[line_idx]
		line_bytes := c_preview_buf[span.start:span.start + span.len]
		vis_len := min(len(line_bytes), max_cols)
		if vis_len <= 0 {
			continue
		}
		_ = text_model.syntax_highlight_row(.C, line_bytes[:vis_len], c_preview_carries[line_idx], true, classes[:vis_len])
		run_start := 0
		for run_start < vis_len {
			run_class := classes[run_start]
			run_end := run_start + 1
			for run_end < vis_len && classes[run_end] == run_class {
				run_end += 1
			}
			interface.draw_text(table, code_text_left + run_start * graphics.CELL_WIDTH, y, string(line_bytes[run_start:run_end]), token_draw_color(run_class))
			run_start = run_end
		}
	}
}

draw :: proc "contextless" (window: ^display.Window) -> interface.Action_Bar_Result {
	frame := interface.window_frame_start(&window_memory, window)
	interface.action_bar_input_take(&frame, &bar)
	table := frame.table
	tokens, _ = box_layout.tokens_for(graphics.appearance, .Standard)

	right_buf: [96]u8
	store_state := store_available ? (interface.background_work_busy(&store_work) ? "committing" : "kept") : "memory only"
	right_status := system.format(right_buf[:], u64(codebase.def_count), " defs, ", u64(codebase.node_count), " nodes, ", store_state)

	boxes := layout_build(window, table, right_status)

	interface.draw_rectangle(table, 0, 0, window.width, window.height, tokens.surface_background)
	draw_sidebar(table, area_of(boxes.sidebar))

	divider := area_of(boxes.divider)
	interface.draw_rectangle(table, divider.x, divider.y, divider.width, divider.height, tokens.divider)

	draw_header(table, area_of(boxes.header))

	code_area := area_of(boxes.code_area)
	code_view_area = code_area
	code_text_left = code_area.x + CODE_PADDING + LINE_NUM_WIDTH
	code_text_top = code_area.y + CODE_PADDING
	lines_now := max((code_area.height - 2 * CODE_PADDING) / graphics.CELL_HEIGHT, 1)
	if lines_now != visible_lines {
		visible_lines = lines_now
		scroll_to_cursor()
	}
	total_lines := view_mode == .Emitted_C ? c_preview_line_count : editor.line_count
	top_line = clamp(top_line, 0, max(total_lines - visible_lines, 0))
	scrolled := interface.scroll_bar(&frame, area_of(boxes.scroll_bar), interface.identity("code scroll bar"), .Vertical, {total = max(total_lines, 1), visible = visible_lines, first = top_line}, {}, "", code_area)
	if scrolled.changed {
		top_line = scrolled.first
	}

	interface.draw_clip_push(table, code_area.x, code_area.y, code_area.width, code_area.height)
	if view_mode == .Emitted_C {
		draw_c_preview_lines(table, code_area)
	} else {
		draw_ast_lines(table, code_area)
	}
	interface.draw_clip_pop(table)

	// Bottom status band.
	status_area := area_of(boxes.status)
	interface.draw_rectangle(table, status_area.x, status_area.y, status_area.width, status_area.height, tokens.surface_card)
	interface.draw_rectangle(table, status_area.x, status_area.y, status_area.width, 1, tokens.divider)
	status_left := area_of(boxes.status_left)
	left_msg := window_problem_texts[problem_shown]
	left_color := problem_shown == .None ? tokens.text_dim : tokens.failed
	if left_msg == "" && editor.inline_active {
		left_msg = "Editing inline: press Enter to confirm or Esc to cancel."
		left_color = tokens.expected
	}
	if left_msg != "" {
		interface.draw_text(table, status_left.x, status_left.y, interface.text_fit(table, {}, left_msg, status_left.width), left_color)
	}
	status_right := area_of(boxes.status_right)
	interface.draw_text(table, status_right.x, status_right.y, right_status, tokens.text_dim)

	items: [6]interface.Action_Bar_Item
	count := bar_items(&items)
	bar_result := interface.action_bar(&frame, area_of(boxes.action_bar), items[:count], &bar, {})
	interface.window_frame_end(&window_memory.drawing, &frame, window)
	return bar_result
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "code")
	if !ok {
		system.stop(.Failed)
	}
	_, _ = display.resizable_set(&window, {
		least_width    = LEAST_WIDTH,
		least_height   = LEAST_HEIGHT,
		largest_width  = LARGEST_WIDTH,
		largest_height = LARGEST_HEIGHT,
	})

	// Seed immediately so the first frame presents real AST content with zero stall.
	_ = ast_codebase.codebase_seed_sample(&codebase)
	ast_codebase.ast_editor_init(&editor, &codebase, 0)
	history_reset_with_current()

	store_ctx = ctx
	if interface.background_work_start(&store_work) == .Succeeded {
		store_job_kind = .Load
		store_outcome = .None
		_ = interface.background_work_ask(&store_work, store_worker_job, nil)
	}

	first_frame := true
	for {
		if interface.background_work_take(&store_work) {
			handle_store_completion()
		}

		bar_result := draw(&window)
		if first_frame {
			first_frame = false
			system.log_fact(.Info, Window_Ready{definitions = u64(codebase.def_count)})
		}
		if bar_result.ran {
			key_run(bar_result.run)
			continue
		}

		wait: system.Wait
		display.wait_events(&wait, &window)
		work_ready := interface.background_work_wait(&wait, &store_work)
		system.wait_end(&wait, work_ready ? system.time() : system.WAIT_FOREVER)

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
			case .Copy_Asked:
				display.copy_decline(&window)
			case .None, .Pasted, .Go_To, .Capture_Size, .Capture_Frame, .Capture_Disconnect, .Capture_Opened, .Work_Area:
			}
		}
	}
}
