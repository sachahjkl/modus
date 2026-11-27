// Interactive showcase of the modus:interface widget library: tabs, styled
// buttons with hover/pressed/disabled states, toggle switches, segmented
// controls, draggable sliders, badges, drag-and-drop reorderable lists,
// right-click context menu, Ctrl+K command palette, action bar, and live
// damage-by-difference metrics (docs/INTERFACE.md; src/md/features/rich_widgets.md).
package interface_elements

import "modus:contract/enum_word"
import "modus:contract/value_kinds"
import "modus:display"
import "modus:graphics"
import "modus:interface"
import "modus:system"

// Initial, minimum, and maximum logical window sizes. Literals so modustool
// computes MODULE_BUDGET directly.
WIDTH :: 880
HEIGHT :: 600
LEAST_WIDTH :: 640
LEAST_HEIGHT :: 440
LARGEST_WIDTH :: 1280
LARGEST_HEIGHT :: 900
// The tool counts the module, its load, its stacks and its window at the largest scale.
MODULE_BUDGET :: system.Stated_Budget{window_width = LARGEST_WIDTH, window_height = LARGEST_HEIGHT, window_least_width = LEAST_WIDTH, window_least_height = LEAST_HEIGHT}

// Plan value: periodic refresh interval (100 ms) for animated demo bars and frame counter.
TICK :: 100
// Plan value: top header bar height holding tabs, status badges, and Ctrl+K pill.
HEADER_HEIGHT :: 34
// Plan value: clearance on the right of the header/footer away from window edge.
HEADER_RIGHT_MARGIN :: 12

// The keys of the window in its action bar (docs/INTERFACE.md, "4.4 The action bar").
bar_items :: proc "contextless" () -> [5]interface.Action_Bar_Item {
	return {
		interface.action_bar_item("Next element", 6, "Tab"),
		interface.action_bar_item("Element before", 3, "Shift", "Tab"),
		interface.action_bar_item("Press", 5, "Enter"),
		interface.action_bar_item("Line before", 4, "Up"),
		interface.action_bar_item("Line after", 4, "Down"),
	}
}
bar: interface.Action_Bar_State

window_memory: interface.Window_Memory(2048, 32768)

// Closed set of actions in the right-click context menu and Ctrl+K palette.
Demo_Action :: enum u32 {
	None          = 0,
	Tab_Controls  = 1,
	Tab_Drag_Drop = 2,
	Tab_States    = 3,
	Toggle_Damage = 4,
	Toggle_Live   = 5,
	Reset_Demo    = 6,
	Reverse_Order = 7,
	Open_Palette  = 8,
}

// Live demo state.
active_tab: int
presses: u64
names := [?]string{"boot", "clock", "remote", "scheduler", "palette", "compositor"}
choice: int
typed: [32]u8
typed_count: int
show_damage: bool
live_bars := true
density_choice := 1 // 0 Compact, 1 Balanced, 2 Spacious.
slider_value := 65

// Drag-and-drop reorderable list state (Tab 0 mini board and Tab 1 priority board).
mini_labels := [?]string{"Compositor", "Terminal", "Settings", "Editor"}
mini_order := [4]int{0, 1, 2, 3}
mini_selected: int
mini_drag: interface.Reorder_Drag_State

board_labels := [?]string{
	"Display-driven frame pacing",
	"Live coalesced window resize",
	"Native right-click context menus",
	"Rich interactive widget library",
	"Sidebar settings preferences",
	"Hardware GPU scanout path",
}
board_order := [6]int{0, 1, 2, 3, 4, 5}
board_selected: int
board_drag: interface.Reorder_Drag_State

demo_ctx_menu: interface.Context_Menu_State
demo_palette: interface.Command_Palette_State
palette_pill_area: interface.Area

frames: u64
moved: bool // The measure of a frame where everything moved.
last_damage: interface.Damage
window_w := WIDTH
window_h := HEIGHT

demo_ctx_menu_open :: proc "contextless" (x, y: int) {
	interface.command_palette_close(&demo_palette)
	items := [6]interface.Context_Menu_Item{
		{id = u32(Demo_Action.Tab_Controls), label = "Controls tab", disabled = active_tab == 0},
		{id = u32(Demo_Action.Tab_Drag_Drop), label = "Drag & Drop tab", disabled = active_tab == 1},
		{id = u32(Demo_Action.Tab_States), label = "States & Table tab", disabled = active_tab == 2},
		{id = u32(Demo_Action.Toggle_Damage), label = show_damage ? "Hide frame damage" : "Show frame damage", separator_before = true},
		{id = u32(Demo_Action.Reset_Demo), label = "Reset controls"},
		{id = u32(Demo_Action.Open_Palette), label = "Command palette", shortcut = "Ctrl+K", separator_before = true},
	}
	interface.context_menu_open_compact(&demo_ctx_menu, x, y, window_w, window_h, items[:])
}

demo_palette_open :: proc "contextless" () {
	interface.context_menu_close(&demo_ctx_menu)
	items := [7]interface.Command_Palette_Item{
		{id = u32(Demo_Action.Tab_Controls), label = "Switch to Controls", category = "Tabs"},
		{id = u32(Demo_Action.Tab_Drag_Drop), label = "Switch to Drag & Drop", category = "Tabs"},
		{id = u32(Demo_Action.Tab_States), label = "Switch to States & Table", category = "Tabs"},
		{id = u32(Demo_Action.Toggle_Damage), label = show_damage ? "Hide frame damage overlay" : "Show frame damage overlay", category = "Inspector"},
		{id = u32(Demo_Action.Toggle_Live), label = live_bars ? "Pause live bars" : "Resume live bars", category = "Controls"},
		{id = u32(Demo_Action.Reverse_Order), label = "Reverse priority list order", category = "Drag & Drop"},
		{id = u32(Demo_Action.Reset_Demo), label = "Reset all demo controls", category = "Controls", danger = true},
	}
	interface.command_palette_open(&demo_palette, "Demo commands", items[:], window_h)
}

demo_action_run :: proc "contextless" (action_word: u32) {
	action, ok := enum_word.member_of_word(Demo_Action, u64(action_word))
	if !ok {
		return
	}
	switch action {
	case .None:
	case .Tab_Controls:
		active_tab = 0
	case .Tab_Drag_Drop:
		active_tab = 1
	case .Tab_States:
		active_tab = 2
	case .Toggle_Damage:
		show_damage = !show_damage
		system.log_fact(.Info, Damage_Overlay_Changed{overlay = value_kinds.text_field(show_damage ? "shown" : "hidden", OVERLAY_FIELD_BYTES)})
	case .Toggle_Live:
		live_bars = !live_bars
	case .Reset_Demo:
		presses = 0
		slider_value = 65
		density_choice = 1
		typed_count = 0
		mini_order = {0, 1, 2, 3}
		board_order = {0, 1, 2, 3, 4, 5}
	case .Reverse_Order:
		for i in 0 ..< len(board_order) / 2 {
			j := len(board_order) - 1 - i
			board_order[i], board_order[j] = board_order[j], board_order[i]
		}
		for i in 0 ..< len(mini_order) / 2 {
			j := len(mini_order) - 1 - i
			mini_order[i], mini_order[j] = mini_order[j], mini_order[i]
		}
	case .Open_Palette:
		demo_palette_open()
	}
}

// build describes the whole window for one frame at (w, h).
build :: proc "contextless" (frame: ^interface.Frame, number: u64, w, h: int) -> interface.Action_Bar_Result {
	builder: interface.Text_Builder
	offset := moved ? 8 : 0

	// Process Ctrl+K / Ctrl+Shift+P and overlay input before underlying widgets.
	for &key in frame.input.keys[:frame.input.key_count] {
		if key.taken {
			continue
		}
		if interface.is_command_palette_shortcut(key.code, key.character, key.modifiers) {
			key.taken = true
			if demo_palette.open {
				interface.command_palette_close(&demo_palette)
			} else {
				demo_palette_open()
			}
			continue
		}
		if demo_palette.open {
			consumed, act := interface.command_palette_handle_key(&demo_palette, key.code, key.character, true, key.modifiers, h)
			if consumed {
				key.taken = true
			}
			if act != 0 {
				demo_action_run(act)
			}
			continue
		}
		if demo_ctx_menu.open {
			consumed, act := interface.context_menu_handle_key(&demo_ctx_menu, key.code, key.character, true, key.modifiers)
			if consumed {
				key.taken = true
			}
			if act != 0 {
				demo_action_run(act)
			}
		}
	}
	if frame.input.right_pressed {
		frame.input.right_pressed = false
		demo_ctx_menu_open(frame.input.right_press_x, frame.input.right_press_y)
	}
	if demo_palette.open {
		res := interface.command_palette_pointer(&demo_palette, frame.input.pointer_x, frame.input.pointer_y, frame.input.pressed, frame.input.wheel, w, h)
		if res.triggered {
			demo_action_run(res.triggered_id)
		}
		frame.input.pressed = false
		frame.input.released = false
		frame.input.wheel = 0
	} else if demo_ctx_menu.open {
		res := interface.context_menu_pointer(&demo_ctx_menu, frame.input.pointer_x, frame.input.pointer_y, frame.input.pressed)
		if res.triggered {
			demo_action_run(res.triggered_id)
		}
		frame.input.pressed = false
		frame.input.released = false
		frame.input.wheel = 0
	}

	interface.background(frame, {0, 0, w, h})
	interface.action_bar_input_take(frame, &bar)

	// Top header strip: tabs on left, live status badge + Ctrl+K pill on right.
	interface.draw_rectangle(frame.table, 0, 0, w, HEADER_HEIGHT, graphics.colors.card_bottom)
	tabs := [3]string{"Controls", "Drag & Drop", "States & Table"}
	pill_label := "Ctrl+K"
	pill_w := interface.text_measured_width(frame.table, interface.FONT_CAPTION, pill_label) + 14
	palette_pill_area = {w - HEADER_RIGHT_MARGIN - pill_w, (HEADER_HEIGHT - 18) / 2, pill_w, 18}
	badge_buf: interface.Text_Builder
	interface.text_put_number(&badge_buf, u64(last_damage.count))
	interface.text_put(&badge_buf, " dmg")
	dmg_text := interface.text_of(&badge_buf)
	dmg_w := interface.text_measured_width(frame.table, interface.FONT_CAPTION, dmg_text) + 16
	dmg_x := palette_pill_area.x - 8 - dmg_w
	tab_w := max(dmg_x - 16, 120)
	_ = interface.tab_bar(frame, {8 + offset, 2, tab_w, HEADER_HEIGHT - 2}, interface.identity("demo tabs"), tabs[:], &active_tab)
	if dmg_x > tab_w + 12 {
		interface.badge(frame, {dmg_x, (HEADER_HEIGHT - 18) / 2, dmg_w, 18}, dmg_text, show_damage ? graphics.colors.machine : graphics.colors.process)
	}
	if palette_pill_area.x > 0 {
		hot := !demo_ctx_menu.open && !demo_palette.open && frame.input.pointer_known && interface.area_contains(palette_pill_area, frame.input.pointer_x, frame.input.pointer_y)
		if hot && frame.input.pressed {
			demo_palette_open()
		}
		interface.draw_rectangle(frame.table, palette_pill_area.x, palette_pill_area.y, palette_pill_area.width, palette_pill_area.height, hot ? graphics.shade(graphics.colors.track, 128) : graphics.colors.track)
		interface.draw_outline(frame.table, palette_pill_area.x, palette_pill_area.y, palette_pill_area.width, palette_pill_area.height, 1, hot ? graphics.colors.title : graphics.colors.not_usable)
		cap_y := palette_pill_area.y + (palette_pill_area.height - interface.line_height(interface.FONT_CAPTION)) / 2
		interface.draw_text(frame.table, palette_pill_area.x + 7, cap_y, pill_label, hot ? graphics.colors.text_strong : graphics.colors.dim, interface.FONT_CAPTION)
	}

	body_top := HEADER_HEIGHT + 8
	body_h := max(h - body_top - 8 - interface.ACTION_BAR_ROW_HEIGHT, 64)
	row_gap := density_choice == 0 ? 5 : (density_choice == 2 ? 10 : 7)

	switch active_tab {
	case 0:
		// Two-column interactive dashboard: Controls on left, Drag & Drop + Frame Inspector on right.
		left_w := max((w - 24) * 58 / 100, 320)
		right_w := max(w - 24 - left_w, 220)
		content := interface.card(frame, {8 + offset, body_top, left_w, body_h}, "CONTROLS", "modus:interface", graphics.colors.kernel)
		col := interface.column_of(content, row_gap)

		// Row 1: Styled button variants with tactile hover/active/disabled states.
		btn_row := interface.column_take(&col, 26)
		btn_cells: [5]interface.Area
		btn_sizes := [5]interface.Size{interface.share(4), interface.share(2), interface.share(2), interface.share(2), interface.share(2)}
		interface.row_split(btn_row, btn_sizes[:], btn_cells[:], 6)
		pressed := interface.button_styled(frame, btn_cells[0], interface.identity("press"), "Press this button", .Primary)
		if pressed.activated {
			presses += 1
			system.log_fact(.Info, Button_Pressed{presses = presses})
		}
		if interface.button_styled(frame, btn_cells[1], interface.identity("reset"), "Reset", .Secondary).activated {
			presses = 0
			slider_value = 65
		}
		if interface.button_styled(frame, btn_cells[2], interface.identity("ghost_tab"), "Drag tab", .Ghost).activated {
			active_tab = 1
		}
		if interface.button_styled(frame, btn_cells[3], interface.identity("danger_clear"), "Clear", .Danger).activated {
			typed_count = 0
		}
		_ = interface.button_styled(frame, btn_cells[4], interface.identity("disabled_btn"), "Locked", .Secondary, disabled = true)

		interface.label_value_line(frame, interface.column_take(&col, 16), "presses", interface.number_text(&builder, presses))

		// Row 2: Tactile toggle switches.
		if interface.toggle_switch(frame, interface.column_take(&col, 24), interface.identity("damage"), show_damage ? "Hide the damage" : "Show the damage", &show_damage).changed {
			system.log_fact(.Info, Damage_Overlay_Changed{overlay = value_kinds.text_field(show_damage ? "shown" : "hidden", OVERLAY_FIELD_BYTES)})
		}
		_ = interface.toggle_switch(frame, interface.column_take(&col, 24), interface.identity("live_bars"), "Animate live meters", &live_bars)

		// Row 3: Connected segmented control (live density switcher).
		density_labels := [3]string{"Compact", "Balanced", "Spacious"}
		_ = interface.segmented_control(frame, interface.column_take(&col, 26), interface.identity("density"), density_labels[:], &density_choice)

		// Row 4: Interactive draggable slider + live value readout.
		sl_row := interface.column_take(&col, 24)
		sl_cells: [2]interface.Area
		sl_sizes := [2]interface.Size{interface.share(), interface.characters(6)}
		interface.row_split(sl_row, sl_sizes[:], sl_cells[:], 8)
		_ = interface.slider(frame, sl_cells[0], interface.identity("fill slider"), &slider_value, 0, 100, 5, name = "Fill level")
		sl_buf: interface.Text_Builder
		interface.text_put_number(&sl_buf, u64(slider_value))
		interface.text_put(&sl_buf, " %")
		interface.cell_text(frame, sl_cells[1], interface.text_of(&sl_buf), graphics.colors.text, .Right)

		// Row 5: List with choice (wheel & keyboard).
		interface.cell_text(frame, interface.column_take(&col, 16), "List with choice", graphics.colors.dim, .Left, interface.FONT_INTERFACE)
		list_area := interface.column_take(&col, 3 * interface.TABLE_LINE)
		interface.element_name(frame, list_area, "list")
		listed := interface.list_with_choice(frame, list_area, interface.identity("list"), names[:], &choice, {chosen_hint = "enter: start"})
		if listed.changed {
			system.log_fact(.Info, List_Chose{chosen_name = value_kinds.text_field(names[choice], LIST_NAME_FIELD_BYTES)})
		}

		// Row 6: Text input (typing & clipboard copy/paste).
		interface.cell_text(frame, interface.column_take(&col, 16), "Text input", graphics.colors.dim, .Left, interface.FONT_INTERFACE)
		typed_result := interface.text_input(frame, interface.column_take(&col, 26), interface.identity("text"), typed[:], &typed_count, "type a text")
		if typed_result.changed {
			system.log_fact(.Info, Text_Typed{typed_text = value_kinds.text_field(string(typed[:typed_count]), TYPED_TEXT_FIELD_BYTES)})
		}

		// Row 7: Live progress bars driven by slider & frame counter.
		bar_val := live_bars ? (u64(slider_value) + number % 36) % 101 : u64(slider_value)
		interface.bar(frame, interface.column_take(&col, 8), bar_val, 100, graphics.colors.process)
		parts := [3]u64{u64(clamp(slider_value / 2, 5, 55)), 22, 15}
		colors := [3]graphics.Color{graphics.colors.kernel, graphics.colors.memory, graphics.colors.failed}
		interface.bar_parts(frame, interface.column_take(&col, 8), parts[:], colors[:], 100)

		// Right Card: Live Drag & Drop list + Frame Damage Inspector.
		rcontent := interface.card(frame, {left_w + 16 + offset, body_top, right_w, body_h}, "DRAG & FRAME", "Reorder, Draw_Table", graphics.colors.machine)
		rcol := interface.column_of(rcontent, row_gap)
		interface.cell_text(frame, interface.column_take(&rcol, 16), "Drag rows or press Alt+Up / Alt+Down", graphics.colors.dim, .Left, interface.FONT_INTERFACE)
		_ = interface.reorder_list(frame, interface.column_take(&rcol, 4 * interface.REORDER_ROW_HEIGHT), interface.identity("mini reorder"), mini_labels[:], mini_order[:], &mini_selected, &mini_drag, "Quick reorder")

		// Frame metrics below the drag-and-drop list.
		number_height := interface.line_height(interface.FONT_LARGE)
		number_area := interface.column_take(&rcol, number_height + interface.caption_height(frame.table, "frames", rcontent.width))
		interface.large_number(frame, number_area.x, number_area.y, interface.number_text(&builder, number), graphics.colors.machine)
		interface.draw_caption(frame, number_area.x, number_area.y + number_height, number_area.width, "frames")
		facts := [?]struct {
			name:  string,
			value: u64,
			unit:  string,
		}{
			{"records", u64(window_memory.drawing.before.record_count), ""},
			{"bytes of text", u64(window_memory.drawing.before.text_count), " B"},
			{"damage rectangles", u64(last_damage.count), ""},
			{"build", window_memory.drawing.build_time / 1000, " us"},
			{"difference", window_memory.drawing.difference_time / 1000, " us"},
			{"draw", window_memory.drawing.draw_time / 1000, " us"},
		}
		for fact in facts {
			value: interface.Text_Builder
			interface.text_put_number(&value, fact.value)
			interface.text_put(&value, fact.unit)
			interface.label_value_line(frame, interface.column_take(&rcol, 16), fact.name, interface.text_of(&value))
		}

	case 1:
		// Dedicated Drag & Drop Priority Board tab.
		content := interface.card(frame, {8 + offset, body_top, w - 16, body_h}, "DRAG & DROP PRIORITY BOARD", "Reorder_Drag_State", graphics.colors.kernel)
		col := interface.column_of(content, 10)
		cap_text := "Grab any row by mouse and drag up or down to reorder live, or use Alt+Up / Alt+Down with keyboard focus."
		cap_area := interface.column_take(&col, interface.caption_height(frame.table, cap_text, col.area.width))
		interface.draw_caption(frame, cap_area.x, cap_area.y, cap_area.width, cap_text)
		_ = interface.reorder_list(frame, interface.column_take(&col, 6 * interface.REORDER_ROW_HEIGHT), interface.identity("board reorder"), board_labels[:], board_order[:], &board_selected, &board_drag, "Priority board")
		act_row := interface.column_take(&col, 28)
		act_cells: [3]interface.Area
		act_sizes := [3]interface.Size{interface.characters(16), interface.characters(16), interface.share()}
		interface.row_split(act_row, act_sizes[:], act_cells[:], 8)
		if interface.button_styled(frame, act_cells[0], interface.identity("board reset"), "Reset order", .Secondary).activated {
			board_order = {0, 1, 2, 3, 4, 5}
		}
		if interface.button_styled(frame, act_cells[1], interface.identity("board reverse"), "Reverse order", .Primary).activated {
			demo_action_run(u32(Demo_Action.Reverse_Order))
		}

	case 2:
		// Button states matrix, badge gallery, and record table.
		left_w := max((w - 24) / 2, 260)
		right_w := max(w - 24 - left_w, 260)
		lcontent := interface.card(frame, {8 + offset, body_top, left_w, body_h}, "BUTTON VARIANTS & BADGES", "Rest, Hover, Active, Disabled", graphics.colors.process)
		lcol := interface.column_of(lcontent, 10)
		variants := [5]struct {
			name:    string,
			variant: interface.Button_Variant,
		}{
			{"Primary", .Primary},
			{"Secondary", .Secondary},
			{"Ghost", .Ghost},
			{"Danger", .Danger},
			{"Sidebar row", .Sidebar_Row},
		}
		for v, idx in variants {
			row := interface.column_take(&lcol, 26)
			cells: [3]interface.Area
			sizes := [3]interface.Size{interface.share(), interface.share(), interface.share()}
			interface.row_split(row, sizes[:], cells[:], 6)
			_ = interface.button_styled(frame, cells[0], interface.identity_with(interface.identity("v_norm"), idx), v.name, v.variant)
			_ = interface.button_styled(frame, cells[1], interface.identity_with(interface.identity("v_open"), idx), "Active", v.variant, open = true)
			_ = interface.button_styled(frame, cells[2], interface.identity_with(interface.identity("v_dis"), idx), "Disabled", v.variant, disabled = true)
		}
		interface.cell_text(frame, interface.column_take(&lcol, 16), "Status badges", graphics.colors.dim, .Left, interface.FONT_INTERFACE)
		b_row := interface.column_take(&lcol, 22)
		b_cells: [5]interface.Area
		b_sizes := [5]interface.Size{interface.share(), interface.share(), interface.share(), interface.share(), interface.share()}
		interface.row_split(b_row, b_sizes[:], b_cells[:], 6)
		interface.badge(frame, b_cells[0], "Kernel", graphics.colors.kernel)
		interface.badge(frame, b_cells[1], "Running", graphics.colors.process)
		interface.badge(frame, b_cells[2], "Memory", graphics.colors.memory)
		interface.badge(frame, b_cells[3], "Warning", graphics.colors.warning)
		interface.badge(frame, b_cells[4], "Failed", graphics.colors.failed)

		rcontent := interface.card(frame, {left_w + 16 + offset, body_top, right_w, body_h}, "ELEMENT TABLE", "Draw_Record cost", graphics.colors.kernel)
		rcol := interface.column_of(rcontent, 6)
		cells: [3]interface.Area
		sizes := [3]interface.Size{interface.share(), interface.characters(9), interface.characters(9)}
		interface.row_split(interface.column_take(&rcol, 24), sizes[:], cells[:], 12)
		interface.table_header(frame, cells[:], {"Element", "Records", "Bytes"}, {.Left, .Right, .Right})
		Line :: struct {
			name:    string,
			records: u64,
		}
		lines := [?]Line{
			{"card", 5},
			{"button_styled", 4},
			{"toggle_switch", 5},
			{"segmented_control", 8},
			{"tab_bar", 7},
			{"slider", 5},
			{"reorder_list", 24},
			{"command_palette", 32},
		}
		for line, index in lines {
			area := interface.column_take(&rcol, 24)
			interface.table_band(frame, area, index)
			interface.row_split({area.x + 8, area.y, area.width - 16, area.height}, sizes[:], cells[:], 12)
			interface.cell_text(frame, cells[0], line.name, graphics.colors.text, .Left, interface.FONT_INTERFACE)
			interface.cell_text(frame, cells[1], interface.number_text(&builder, line.records), graphics.colors.text, .Right)
			interface.cell_text(frame, cells[2], interface.number_text(&builder, line.records * size_of(interface.Draw_Record)), graphics.colors.text, .Right)
		}
	}

	// Damage overlay outlines when enabled.
	if show_damage {
		for rectangle in last_damage.rectangles[:last_damage.count] {
			rw, rh := rectangle.right - rectangle.left, rectangle.bottom - rectangle.top
			interface.draw_rectangle(frame.table, rectangle.left, rectangle.top, rw, 2, graphics.colors.machine)
			interface.draw_rectangle(frame.table, rectangle.left, rectangle.bottom - 2, rw, 2, graphics.colors.machine)
			interface.draw_rectangle(frame.table, rectangle.left, rectangle.top, 2, rh, graphics.colors.machine)
			interface.draw_rectangle(frame.table, rectangle.right - 2, rectangle.top, 2, rh, graphics.colors.machine)
		}
	}

	// Action bar at the foot, then floating right-click menu / command palette above everything.
	items := bar_items()
	bar_res := interface.action_bar(frame, {0, h - interface.ACTION_BAR_ROW_HEIGHT, w, interface.ACTION_BAR_ROW_HEIGHT}, items[:], &bar)
	if demo_ctx_menu.open {
		interface.context_menu_draw(frame.table, &demo_ctx_menu)
	}
	if demo_palette.open {
		interface.command_palette_draw(frame.table, &demo_palette, w, h)
	}
	return bar_res
}

// frame_draw builds and draws one frame. The key of an item that a press
// ran goes into the input of the next frame, the way of a typed key.
frame_draw :: proc "contextless" (window: ^display.Window) {
	if window.width > 0 && window.height > 0 {
		window_w, window_h = window.width, window.height
	}
	frame := interface.window_frame_start(&window_memory, window)
	bar_result := build(&frame, frames, window_w, window_h)
	interface.window_frame_end(&window_memory.drawing, &frame, window)
	if bar_result.ran {
		interface.input_key_add(&window_memory.drawing.input, bar_result.run)
	}
	last_damage = window_memory.drawing.damage
	frames += 1
}

// measure builds the window and compares it with the frame before, in one
// case: nothing changed, one number changed, or everything moved.
measure :: proc "contextless" (name: string, number_before, number_now: u64, move: bool) {
	ROUNDS :: 100
	before := interface.Draw_Table{records = window_memory.records_before[:], text = window_memory.text_before[:], interface_font = display.interface_font_of()}
	now := interface.Draw_Table{records = window_memory.records_now[:], text = window_memory.text_now[:], interface_font = display.interface_font_of()}
	state: interface.Interface_State
	input: interface.Input
	difference, rectangles: u64
	damage: interface.Damage
	for _ in 0 ..< ROUNDS {
		moved = false
		frame := interface.frame_begin(&before, &state, &input)
		build(&frame, number_before, WIDTH, HEIGHT)
		interface.frame_end(&frame)
		moved = move
		frame = interface.frame_begin(&now, &state, &input)
		build(&frame, number_now, WIDTH, HEIGHT)
		interface.frame_end(&frame)
		damage = {}
		start := system.nanoseconds()
		interface.damage_by_difference(&before, &now, &damage)
		difference += system.nanoseconds() - start
		rectangles = u64(damage.count)
	}
	moved = false
	bounds := interface.damage_bounds(&damage)
	area := u64(max(bounds.right - bounds.left, 0) * max(bounds.bottom - bounds.top, 0))
	system.log_fact(.Info, Damage_Measured{records = u64(now.record_count), rectangles = rectangles, window_percent = area * 100 / (WIDTH * HEIGHT), difference = value_kinds.Nanoseconds_As_Microseconds(difference / ROUNDS), measure = value_kinds.text_field(name, MEASURE_NAME_FIELD_BYTES)})
}

// measure_fonts gives the time of one whole frame of the window, built and
// drawn into the window with no comparison, in the font of the cells and
// in the interface font.
measure_fonts :: proc "contextless" (window: ^display.Window) {
	ROUNDS :: 20
	interface_font := display.interface_font_of()
	fonts := [2]^display.Interface_Font{nil, interface_font}
	least := [2]u64{max(u64), max(u64)}
	for font, index in fonts {
		if index == 1 && font == nil {
			break
		}
		for _ in 0 ..< ROUNDS {
			table := interface.Draw_Table{records = window_memory.records_now[:], text = window_memory.text_now[:], interface_font = font}
			state: interface.Interface_State
			input: interface.Input
			start := system.nanoseconds()
			frame := interface.frame_begin(&table, &state, &input)
			build(&frame, 7, WIDTH, HEIGHT)
			interface.frame_end(&frame)
			graphics.clear(window.canvas, graphics.colors.background)
			interface.execute(&table, window.canvas)
			least[index] = min(least[index], system.nanoseconds() - start)
		}
	}
	if interface_font == nil {
		system.log_fact(.Info, Whole_Frame_Measured_Without_Interface_Font{cell_font = microseconds(least[0])})
		return
	}
	system.log_fact(.Info, Whole_Frame_Measured{cell_font = microseconds(least[0]), interface_font = microseconds(least[1])})
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "interface_elements")
	if !ok {
		system.stop(.Failed)
	}
	_, _ = display.resizable_set(&window, {least_width = LEAST_WIDTH, least_height = LEAST_HEIGHT, largest_width = LARGEST_WIDTH, largest_height = LARGEST_HEIGHT})
	measure("nothing changed", 7, 7, false)
	measure("one number changed", 7, 8, false)
	measure("everything moved", 7, 7, true)
	measure_fonts(&window)
	frame_draw(&window)
	whole := window_memory.drawing.draw_time
	frame_draw(&window)
	frame_draw(&window)
	system.log_fact(.Info, Frames_Drawn{whole_frame = microseconds(whole), damage_rectangles = u64(window_memory.drawing.damage.count), damage_frame = microseconds(window_memory.drawing.draw_time)})
	deadline := system.time()
	for {
		deadline += TICK
		display.wait(&window, deadline)
		interface.window_events(&window_memory.drawing, &window)
		frame_draw(&window)
	}
}
