// Responsive component showcase of modus:interface and modus:layout:
// adaptive collapsing/wrapping toolbar, live theme presets (theme_push/pop),
// tabs, styled buttons, 2-state & indeterminate checkboxes, radio groups,
// toggle switches, segmented controls, number stepper, draggable slider with
// editable value, dropdown & searchable combobox, multi-select with removable
// chips, collapsible disclosures, progress bars, multi-line text area,
// draggable split pane, sortable/resizable multi-select data table, expandable
// tree view, drag-and-drop reorder list, tooltips, modal dialog, right-click
// context menu, Ctrl+K command palette, action bar, and damage-by-difference
// metrics (docs/INTERFACE.md; src/md/features/rich_widgets.md).
package interface_elements

import "modus:contract/enum_word"
import "modus:contract/value_kinds"
import "modus:display"
import "modus:graphics"
import "modus:interface"
import "modus:layout"
import "modus:system"

// Initial, minimum, and maximum logical window sizes. Literals so modustool
// computes MODULE_BUDGET directly.
WIDTH :: 940
HEIGHT :: 640
LEAST_WIDTH :: 640
LEAST_HEIGHT :: 440
LARGEST_WIDTH :: 1280
LARGEST_HEIGHT :: 900
// The tool counts the module, its load, its stacks and its window at the largest scale.
MODULE_BUDGET :: system.Stated_Budget{window_width = LARGEST_WIDTH, window_height = LARGEST_HEIGHT, window_least_width = LEAST_WIDTH, window_least_height = LEAST_HEIGHT}

// Plan value: periodic refresh interval (100 ms) for animated meters and frame counter.
TICK :: 100
// Plan value: top header bar height holding tabs, live damage badge, and Ctrl+K pill.
HEADER_HEIGHT :: 34
// Plan value: right margin inside header strip.
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

window_memory: interface.Window_Memory(4096, 65536)
layout_tree: layout.Box_Tree

// Closed set of actions in the toolbar, right-click context menu, and Ctrl+K palette.
Demo_Action :: enum u32 {
	None            = 0,
	Tab_Controls    = 1,
	Tab_Pickers     = 2,
	Tab_Data_Tree   = 3,
	Tab_Layout      = 4,
	Toggle_Damage   = 5,
	Toggle_Live     = 6,
	Reset_Demo      = 7,
	Reverse_Order   = 8,
	Open_Palette    = 9,
	Toggle_Toolbar  = 10,
	Theme_System    = 11,
	Theme_Amber     = 12,
	Theme_Emerald   = 13,
	Open_Modal      = 14,
}

// Theme preset indices demonstrating live per-subtree Widget_Theme styling.
Theme_Preset :: enum u8 {
	System  = 0,
	Amber   = 1,
	Emerald = 2,
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
slider_edit: interface.Slider_Edit_State

// Toolbar state (live toggle between .Fold overflow menu and .Wrap multi-line).
toolbar_overflow := interface.Toolbar_Overflow.Fold
toolbar_state: interface.Toolbar_State
theme_preset := Theme_Preset.System

// Selection and form controls state.
check_tri := interface.Checkbox_State.Mixed
check_sync := true
radio_choice := 1
stepper_value := 4
disclosure_open := true
modal_open := false
modal_last_action := "None yet"

// Dropdown, searchable combobox, and multi-select state.
role_labels := [?]string{"Compositor", "Storage", "Network", "Scheduler", "Debugger", "Assistant", "Manual", "Monitor"}
dropdown_choice := 0
dropdown_state: interface.Dropdown_State
combo_choice := 2
combo_state: interface.Dropdown_State
tag_labels := [?]string{"Freestanding", "Zero-Alloc", "Flexbox", "Stylable", "Keyboard", "Accessible"}
tag_selected := [6]bool{true, true, true, false, true, false}
multi_state: interface.Multi_Select_State

// Multi-line text_area state.
notes_buf: [512]u8
notes_count: int
notes_area_state: interface.Text_Area_State
notes_initialized := false

// Drag-and-drop reorderable list state.
mini_labels := [?]string{"Compositor", "Terminal", "Settings", "Editor"}
mini_order := [4]int{0, 1, 2, 3}
mini_selected: int
mini_drag: interface.Reorder_Drag_State

// Split pane + tree view + sortable/resizable multi-select data table state.
split_ratio: i32 = 3_600
split_drag: interface.Split_Drag_State

tree_expanded := [4]bool{true, true, false, true}
tree_state: interface.Tree_View_State

table_col_widths := [4]int{136, 92, 72, 84}
table_selected := [8]bool{true, false, true, false, false, false, false, false}
table_order := [8]int{0, 1, 2, 3, 4, 5, 6, 7}
table_state: interface.Data_Table_State

// Live flow_wrap playground alignment on Tab 3.
flow_align_choice := 0

demo_ctx_menu: interface.Context_Menu_State
demo_palette: interface.Command_Palette_State
palette_pill_area: interface.Area

frames: u64
moved: bool // The measure of a frame where everything moved.
last_damage: interface.Damage
window_w := WIDTH
window_h := HEIGHT

area_of :: proc "contextless" (r: layout.Rect) -> interface.Area {
	return {int(r.x), int(r.y), int(r.width), int(r.height)}
}

notes_init_once :: proc "contextless" () {
	if notes_initialized {
		return
	}
	initial := "modus:layout flexbox\nmodus:interface widgets\nzero heap allocation"
	notes_count = copy(notes_buf[:], initial)
	notes_area_state.caret = notes_count
	notes_initialized = true
}

active_theme_of :: proc "contextless" (preset: Theme_Preset) -> interface.Widget_Theme {
	switch preset {
	case .System:
		return interface.widget_theme_default()
	case .Amber:
		return interface.widget_theme_with_accent(graphics.rgb(218, 146, 38))
	case .Emerald:
		return interface.widget_theme_with_accent(graphics.rgb(46, 178, 120))
	}
	return interface.widget_theme_default()
}

demo_ctx_menu_open :: proc "contextless" (x, y: int) {
	interface.command_palette_close(&demo_palette)
	items := [7]interface.Context_Menu_Item{
		{id = u32(Demo_Action.Tab_Controls), label = "Controls tab", disabled = active_tab == 0},
		{id = u32(Demo_Action.Tab_Pickers), label = "Select & Text tab", disabled = active_tab == 1},
		{id = u32(Demo_Action.Tab_Data_Tree), label = "Data & Tree tab", disabled = active_tab == 2},
		{id = u32(Demo_Action.Tab_Layout), label = "Layout & Theme tab", disabled = active_tab == 3},
		{id = u32(Demo_Action.Toggle_Toolbar), label = toolbar_overflow == .Fold ? "Toolbar: Wrap mode" : "Toolbar: Fold mode", separator_before = true},
		{id = u32(Demo_Action.Toggle_Damage), label = show_damage ? "Hide frame damage" : "Show frame damage"},
		{id = u32(Demo_Action.Open_Palette), label = "Command palette", shortcut = "Ctrl+K", separator_before = true},
	}
	interface.context_menu_open_compact(&demo_ctx_menu, x, y, window_w, window_h, items[:])
}

demo_palette_open :: proc "contextless" () {
	interface.context_menu_close(&demo_ctx_menu)
	items := [9]interface.Command_Palette_Item{
		{id = u32(Demo_Action.Tab_Controls), label = "Switch to Controls", category = "Tabs"},
		{id = u32(Demo_Action.Tab_Pickers), label = "Switch to Select & Text", category = "Tabs"},
		{id = u32(Demo_Action.Tab_Data_Tree), label = "Switch to Data & Tree", category = "Tabs"},
		{id = u32(Demo_Action.Tab_Layout), label = "Switch to Layout & Theme", category = "Tabs"},
		{id = u32(Demo_Action.Toggle_Toolbar), label = "Toggle toolbar Fold / Wrap", category = "Layout"},
		{id = u32(Demo_Action.Theme_Amber), label = "Theme: Warm Amber", category = "Style"},
		{id = u32(Demo_Action.Theme_Emerald), label = "Theme: Emerald", category = "Style"},
		{id = u32(Demo_Action.Open_Modal), label = "Open modal dialog", category = "Overlay"},
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
	case .Tab_Pickers:
		active_tab = 1
	case .Tab_Data_Tree:
		active_tab = 2
	case .Tab_Layout:
		active_tab = 3
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
		split_ratio = 3_600
		stepper_value = 4
		theme_preset = .System
	case .Reverse_Order:
		for i in 0 ..< len(mini_order) / 2 {
			j := len(mini_order) - 1 - i
			mini_order[i], mini_order[j] = mini_order[j], mini_order[i]
		}
	case .Open_Palette:
		demo_palette_open()
	case .Toggle_Toolbar:
		toolbar_overflow = toolbar_overflow == .Fold ? .Wrap : .Fold
	case .Theme_System:
		theme_preset = .System
	case .Theme_Amber:
		theme_preset = .Amber
	case .Theme_Emerald:
		theme_preset = .Emerald
	case .Open_Modal:
		modal_open = true
	}
}

Table_Sample_Row :: struct {
	name:  string,
	kind:  string,
	pages: int,
	state: string,
}

@(rodata)
TABLE_SAMPLE_ROWS := [8]Table_Sample_Row{
	{"compositor", "Service", 412, "Running"},
	{"storage", "Service", 1280, "Running"},
	{"console", "Shell", 214, "Running"},
	{"network", "Service", 360, "Running"},
	{"settings", "App", 148, "Idle"},
	{"debugger", "Tool", 180, "Ready"},
	{"assistant", "Agent", 520, "Ready"},
	{"plasma", "Demo", 96, "Idle"},
}

table_sort_apply :: proc "contextless" () {
	if table_state.sort_order == .None {
		return
	}
	asc := table_state.sort_order == .Ascending
	col := table_state.sort_column
	// Simple insertion sort on 8 indices (zero allocation).
	for i := 1; i < len(table_order); i += 1 {
		key_idx := table_order[i]
		j := i - 1
		for j >= 0 {
			a := TABLE_SAMPLE_ROWS[table_order[j]]
			b := TABLE_SAMPLE_ROWS[key_idx]
			greater := false
			switch col {
			case 0:
				greater = a.name > b.name
			case 1:
				greater = a.kind > b.kind
			case 2:
				greater = a.pages > b.pages
			case 3:
				greater = a.state > b.state
			}
			if (asc && greater) || (!asc && !greater && table_order[j] != key_idx) {
				table_order[j + 1] = table_order[j]
				j -= 1
			} else {
				break
			}
		}
		table_order[j + 1] = key_idx
	}
}

// build describes the whole window for one frame at (w, h) using modus:layout.
build :: proc "contextless" (frame: ^interface.Frame, number: u64, w, h: int) -> interface.Action_Bar_Result {
	notes_init_once()
	builder: interface.Text_Builder
	offset := moved ? 8 : 0

	// Apply active custom theme preset for the entire frame via scoped theme stack.
	pushed_theme := theme_preset != .System && interface.theme_push(frame, active_theme_of(theme_preset))
	defer if pushed_theme {
		_ = interface.theme_pop(frame)
	}
	theme := interface.theme_current(frame)

	// Process floating overlays (Ctrl+K palette, context menu, toolbar overflow menu) first.
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
	if tb_trig, tb_id := interface.toolbar_handle_key(frame, &toolbar_state); tb_trig {
		demo_action_run(tb_id)
	}
	if frame.input.right_pressed && !modal_open {
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
	} else if toolbar_state.overflow_menu.open {
		if trig, id := interface.toolbar_overlay_pointer(frame, &toolbar_state); trig {
			demo_action_run(id)
		}
	}

	// Build adaptive toolbar items and measure exact wrapped/folded height for modus:layout.
	tb_groups := [4]interface.Toolbar_Group{
		{title = "Overflow", priority = 4},
		{title = "Theme", priority = 2, separator = true},
		{title = "View", priority = 1, separator = true},
		{title = "Quick", priority = 5, pinned = true, separator = true},
	}
	tb_items := [8]interface.Toolbar_Item{
		{id = u32(Demo_Action.Toggle_Toolbar), group = 0, label = toolbar_overflow == .Fold ? "Toolbar: Fold" : "Toolbar: Wrap", on = toolbar_overflow == .Wrap, variant = .Secondary},
		{id = u32(Demo_Action.Theme_System), group = 1, label = "System", on = theme_preset == .System, variant = .Ghost},
		{id = u32(Demo_Action.Theme_Amber), group = 1, label = "Amber", on = theme_preset == .Amber, variant = .Ghost},
		{id = u32(Demo_Action.Theme_Emerald), group = 1, label = "Emerald", on = theme_preset == .Emerald, variant = .Ghost},
		{id = u32(Demo_Action.Toggle_Live), group = 2, label = "Live meters", on = live_bars, variant = .Ghost},
		{id = u32(Demo_Action.Toggle_Damage), group = 2, label = "Damage box", on = show_damage, variant = .Ghost},
		{id = u32(Demo_Action.Open_Modal), group = 3, label = "Modal", shortcut = "Ctrl+M", variant = .Secondary},
		{id = u32(Demo_Action.Reset_Demo), group = 3, label = "Reset", variant = .Primary},
	}
	tb_h := interface.toolbar_measure_height(frame.table, w, tb_groups[:], tb_items[:], toolbar_overflow)

	// Solve outer window structure dynamically with modus:layout.Box_Tree (zero hardcoded body coords).
	_ = layout.tree_begin(&layout_tree, i32(w), i32(h), {child_axis = .Y})
	header_box, _ := layout.box_add(&layout_tree, {label = "header", size = {.X = layout.fill(), .Y = layout.px(HEADER_HEIGHT)}})
	toolbar_box, _ := layout.box_add(&layout_tree, {label = "toolbar", size = {.X = layout.fill(), .Y = layout.px(i32(tb_h))}})
	body_box, _ := layout.box_open(&layout_tree, {label = "body", size = {.X = layout.fill(), .Y = layout.fill()}, child_axis = .X, padding = {.X = 8, .Y = 8}, gap = 8})
	left_pane_box, _ := layout.box_add(&layout_tree, {label = "left", size = {.X = layout.pct(5_700, 0), .Y = layout.fill()}, minimum = {.X = 280, .Y = 0}})
	right_pane_box, _ := layout.box_add(&layout_tree, {label = "right", size = {.X = layout.fill(), .Y = layout.fill()}, minimum = {.X = 220, .Y = 0}})
	_ = layout.box_close(&layout_tree)
	footer_box, _ := layout.box_add(&layout_tree, {label = "footer", size = {.X = layout.fill(), .Y = layout.px(interface.ACTION_BAR_ROW_HEIGHT)}})
	_ = layout.solve(&layout_tree)

	header_area := area_of(layout.box_of(&layout_tree, header_box).rect)
	toolbar_area := area_of(layout.box_of(&layout_tree, toolbar_box).rect)
	body_area := area_of(layout.box_of(&layout_tree, body_box).rect)
	left_area := area_of(layout.box_of(&layout_tree, left_pane_box).rect)
	right_area := area_of(layout.box_of(&layout_tree, right_pane_box).rect)
	footer_area := area_of(layout.box_of(&layout_tree, footer_box).rect)

	// Shift body cards by offset during the "everything moved" damage measurement.
	left_area.x += offset
	right_area.x += offset
	full_body := interface.Area{body_area.x + 8 + offset, body_area.y + 8, max(body_area.width - 16, 64), max(body_area.height - 16, 64)}

	interface.background(frame, {0, 0, w, h})
	interface.action_bar_input_take(frame, &bar)

	// Top header strip: tabs (Focus 0), live damage badge, and Ctrl+K pill.
	interface.draw_rectangle(frame.table, header_area.x, header_area.y, header_area.width, header_area.height, theme.card_bottom)
	tabs := [4]string{"Controls", "Select & Text", "Data & Tree", "Layout & Theme"}
	pill_label := "Ctrl+K"
	pill_w := interface.text_measured_width(frame.table, interface.FONT_CAPTION, pill_label) + 14
	palette_pill_area = {w - HEADER_RIGHT_MARGIN - pill_w, (HEADER_HEIGHT - 18) / 2, pill_w, 18}
	badge_buf: interface.Text_Builder
	interface.text_put_number(&badge_buf, u64(last_damage.count))
	interface.text_put(&badge_buf, " dmg")
	dmg_text := interface.text_of(&badge_buf)
	dmg_w := interface.text_measured_width(frame.table, interface.FONT_CAPTION, dmg_text) + 16
	dmg_x := palette_pill_area.x - 8 - dmg_w
	tab_w := max(dmg_x - 16, 160)
	_ = interface.tab_bar(frame, {8 + offset, 2, tab_w, HEADER_HEIGHT - 2}, interface.identity("demo tabs"), tabs[:], &active_tab)
	if dmg_x > tab_w + 12 {
		interface.badge(frame, {dmg_x, (HEADER_HEIGHT - 18) / 2, dmg_w, 18}, dmg_text, show_damage ? theme.warning : theme.ok)
	}
	if palette_pill_area.x > 0 {
		hot := !demo_ctx_menu.open && !demo_palette.open && !modal_open && frame.input.pointer_known && interface.area_contains(palette_pill_area, frame.input.pointer_x, frame.input.pointer_y)
		if hot && frame.input.pressed {
			demo_palette_open()
		}
		interface.draw_rectangle(frame.table, palette_pill_area.x, palette_pill_area.y, palette_pill_area.width, palette_pill_area.height, hot ? graphics.shade(theme.track, 128) : theme.track)
		interface.draw_outline(frame.table, palette_pill_area.x, palette_pill_area.y, palette_pill_area.width, palette_pill_area.height, 1, hot ? theme.accent : theme.border)
		cap_y := palette_pill_area.y + (palette_pill_area.height - interface.line_height(interface.FONT_CAPTION)) / 2
		interface.draw_text(frame.table, palette_pill_area.x + 7, cap_y, pill_label, hot ? theme.text_strong : theme.text_dim, interface.FONT_CAPTION)
	}

	row_gap := density_choice == 0 ? 4 : (density_choice == 2 ? 9 : 6)
	tooltip_text := ""
	tooltip_anchor: interface.Area

	switch active_tab {
	case 0:
		// Left card: Controls (preserves focus order: tab_bar -> Press this button -> ... -> list -> text_input).
		content := interface.card(frame, left_area, "CONTROLS", "modus:interface", theme.accent)
		col := interface.column_of(content, row_gap)

		// Row 1: Styled button variants (Focus 1 is "Press this button" for keyboard scenario).
		btn_row := interface.column_take(&col, 26)
		btn_cells: [4]interface.Area
		btn_sizes := [4]interface.Size{interface.share(5), interface.share(2), interface.share(2), interface.share(2)}
		interface.row_split(btn_row, btn_sizes[:], btn_cells[:], 6)
		pressed := interface.button_styled(frame, btn_cells[0], interface.identity("press"), "Press this button", .Primary)
		if pressed.activated {
			presses += 1
			system.log_fact(.Info, Button_Pressed{presses = presses})
		}
		if pressed.under_pointer {
			tooltip_text = "Primary button styled via active Widget_Theme"
			tooltip_anchor = btn_cells[0]
		}
		if interface.button_styled(frame, btn_cells[1], interface.identity("reset"), "Reset", .Secondary).activated {
			demo_action_run(u32(Demo_Action.Reset_Demo))
		}
		if interface.button_styled(frame, btn_cells[2], interface.identity("danger_clear"), "Clear", .Danger).activated {
			typed_count = 0
		}
		_ = interface.button_styled(frame, btn_cells[3], interface.identity("disabled_btn"), "Locked", .Secondary, disabled = true)

		interface.label_value_line(frame, interface.column_take(&col, 16), "presses", interface.number_text(&builder, presses))

		// Row 2: Toggle switches + tri-state checkbox + checkbox side by side.
		if interface.toggle_switch(frame, interface.column_take(&col, 22), interface.identity("damage"), show_damage ? "Hide the damage" : "Show the damage", &show_damage).changed {
			system.log_fact(.Info, Damage_Overlay_Changed{overlay = value_kinds.text_field(show_damage ? "shown" : "hidden", OVERLAY_FIELD_BYTES)})
		}
		cb_row := interface.column_take(&col, 22)
		cb_cells: [2]interface.Area
		cb_sizes := [2]interface.Size{interface.share(), interface.share()}
		interface.row_split(cb_row, cb_sizes[:], cb_cells[:], 8)
		_ = interface.checkbox_tri(frame, cb_cells[0], interface.identity("cb_tri"), "Mixed checkbox", &check_tri)
		_ = interface.checkbox(frame, cb_cells[1], interface.identity("cb_sync"), "Auto-sync", &check_sync)

		// Row 3: Horizontal radio group + number stepper.
		rn_row := interface.column_take(&col, 24)
		rn_cells: [2]interface.Area
		rn_sizes := [2]interface.Size{interface.share(3), interface.share(2)}
		interface.row_split(rn_row, rn_sizes[:], rn_cells[:], 8)
		radio_labels := [3]string{"Low", "Med", "High"}
		_ = interface.radio_group(frame, rn_cells[0], interface.identity("priority_radio"), radio_labels[:], &radio_choice, .Horizontal)
		step_res := interface.number_stepper(frame, rn_cells[1], interface.identity("threads_stepper"), &stepper_value, 1, 32, 1, " cpu")
		if step_res.under_pointer {
			tooltip_text = "Wheel or Shift+Arrows for 10x step"
			tooltip_anchor = rn_cells[1]
		}

		// Row 4: Connected segmented control (density) & slider with editable value.
		density_labels := [3]string{"Compact", "Balanced", "Spacious"}
		_ = interface.segmented_control(frame, interface.column_take(&col, 24), interface.identity("density"), density_labels[:], &density_choice)
		_ = interface.slider_with_value(frame, interface.column_take(&col, 24), interface.identity("fill slider"), &slider_value, &slider_edit, 0, 100, step = 5, suffix = " %", value_width = 68, name = "Fill level", default_value = 65)

		// Row 5: List with choice IMMEDIATELY followed in focus order by text_input.
		interface.cell_text(frame, interface.column_take(&col, 16), "List with choice", theme.text_dim, .Left, interface.FONT_INTERFACE)
		list_area := interface.column_take(&col, 3 * interface.TABLE_LINE)
		interface.element_name(frame, list_area, "list")
		listed := interface.list_with_choice(frame, list_area, interface.identity("list"), names[:], &choice, {chosen_hint = "enter: start"})
		if listed.changed {
			system.log_fact(.Info, List_Chose{chosen_name = value_kinds.text_field(names[choice], LIST_NAME_FIELD_BYTES)})
		}

		interface.cell_text(frame, interface.column_take(&col, 16), "Text input", theme.text_dim, .Left, interface.FONT_INTERFACE)
		typed_result := interface.text_input(frame, interface.column_take(&col, 24), interface.identity("text"), typed[:], &typed_count, "type a text")
		if typed_result.changed {
			system.log_fact(.Info, Text_Typed{typed_text = value_kinds.text_field(string(typed[:typed_count]), TYPED_TEXT_FIELD_BYTES)})
		}

		// Row 6: Determinate + indeterminate progress bars.
		bar_val := live_bars ? int((u64(slider_value) + number % 36) % 101) : slider_value
		p_row := interface.column_take(&col, 18)
		p_cells: [2]interface.Area
		p_sizes := [2]interface.Size{interface.share(3), interface.share(2)}
		interface.row_split(p_row, p_sizes[:], p_cells[:], 8)
		interface.progress_bar(frame, p_cells[0], bar_val, false, 0, "Progress")
		interface.progress_bar(frame, p_cells[1], 0, live_bars, number * TICK, "Working")

		// Right card: Collapsible disclosure + Drag & Drop + Live Frame Metrics.
		rcontent := interface.card(frame, right_area, "DISCLOSURE & FRAME", "modus:layout", graphics.colors.machine)
		rcol := interface.column_of(rcontent, row_gap)

		_ = interface.disclosure(frame, interface.column_take(&rcol, 24), interface.identity("disc_reorder"), "Reorderable list", &disclosure_open, "Drag / Alt+Up")
		if disclosure_open {
			_ = interface.reorder_list(frame, interface.column_take(&rcol, 4 * interface.REORDER_ROW_HEIGHT), interface.identity("mini reorder"), mini_labels[:], mini_order[:], &mini_selected, &mini_drag, "Quick reorder")
		}

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
		interface.label_value_line(frame, interface.column_take(&rcol, 16), "modal", modal_last_action)

	case 1:
		// Tab 1: Dropdown, Searchable Combobox, Multi-Select with chips, Multi-Line Text Area.
		lcontent := interface.card(frame, left_area, "DROPDOWNS & MULTI-SELECT", "Filter, Chips, Keyboard", theme.accent)
		lcol := interface.column_of(lcontent, 8)

		interface.cell_text(frame, interface.column_take(&lcol, 16), "Single dropdown (flips upward near bottom)", theme.text_dim, .Left, interface.FONT_INTERFACE)
		_ = interface.dropdown_trigger(frame, interface.column_take(&lcol, 26), interface.identity("role_dd"), role_labels[:], &dropdown_choice, &dropdown_state, "Select module...")

		interface.cell_text(frame, interface.column_take(&lcol, 16), "Searchable combobox (type to filter live)", theme.text_dim, .Left, interface.FONT_INTERFACE)
		_ = interface.dropdown_trigger(frame, interface.column_take(&lcol, 26), interface.identity("combo_dd"), role_labels[:], &combo_choice, &combo_state, "Search modules...")

		interface.cell_text(frame, interface.column_take(&lcol, 16), "Multi-select (removable chips, Backspace, All/Clear)", theme.text_dim, .Left, interface.FONT_INTERFACE)
		_ = interface.multi_select_trigger(frame, interface.column_take(&lcol, 28), interface.identity("tags_ms"), tag_labels[:], tag_selected[:], &multi_state, "Choose tags...")

		interface.cell_text(frame, interface.column_take(&lcol, 16), "Selected summary", theme.text_dim, .Left, interface.FONT_INTERFACE)
		sel_cnt: u64
		for s in tag_selected {
			if s {
				sel_cnt += 1
			}
		}
		interface.label_value_line(frame, interface.column_take(&lcol, 18), "dropdown", dropdown_choice >= 0 ? role_labels[dropdown_choice] : "-")
		interface.label_value_line(frame, interface.column_take(&lcol, 18), "combobox", combo_choice >= 0 ? role_labels[combo_choice] : "-")
		interface.label_value_line(frame, interface.column_take(&lcol, 18), "multi-select count", interface.number_text(&builder, sel_cnt))

		rcontent := interface.card(frame, right_area, "MULTI-LINE TEXT AREA", "Line numbers, Scroll, Caret", graphics.colors.process)
		rcol := interface.column_of(rcontent, 8)
		interface.cell_text(frame, interface.column_take(&rcol, 16), "Editable buffer (Enter newline, arrows, Ctrl+C)", theme.text_dim, .Left, interface.FONT_INTERFACE)
		ta_h := max(rcol.area.height - 28, 80)
		_ = interface.text_area(frame, interface.column_take(&rcol, ta_h), interface.identity("demo_textarea"), notes_buf[:], &notes_count, &notes_area_state, "Write notes...", line_numbers = true)

	case 2:
		// Tab 2: Interactive Draggable Split Pane with Tree View (left) + Sortable Multi-Select Data Table (right).
		sp, _ := layout.split_pane({i32(full_body.x), i32(full_body.y), i32(full_body.width), i32(full_body.height)}, .X, split_ratio, 8)
		sp_first := area_of(sp.first)
		sp_div := area_of(sp.divider)
		sp_second := area_of(sp.second)

		// Tree View on left split pane.
		tcontent := interface.card(frame, sp_first, "TREE VIEW", "Expand / Collapse", theme.accent)
		tree_rows: [12]interface.Tree_Row
		tc := 0
		tree_rows[tc] = {id = 1, label = "src", detail = "dir", depth = 0, has_children = true, expanded = tree_expanded[0]}
		tc += 1
		if tree_expanded[0] {
			tree_rows[tc] = {id = 2, label = "modus:interface", detail = "widgets", depth = 1, has_children = true, expanded = tree_expanded[1]}
			tc += 1
			if tree_expanded[1] {
				tree_rows[tc] = {id = 3, label = "theme.odin", detail = "3 KB", depth = 2}
				tc += 1
				tree_rows[tc] = {id = 4, label = "toolbar.odin", detail = "12 KB", depth = 2}
				tc += 1
				tree_rows[tc] = {id = 5, label = "selection_widgets.odin", detail = "18 KB", depth = 2}
				tc += 1
				tree_rows[tc] = {id = 6, label = "data_widgets.odin", detail = "17 KB", depth = 2}
				tc += 1
			}
			tree_rows[tc] = {id = 7, label = "modus:layout", detail = "flexbox", depth = 1, has_children = true, expanded = tree_expanded[2]}
			tc += 1
			if tree_expanded[2] {
				tree_rows[tc] = {id = 8, label = "solve.odin", detail = "11 KB", depth = 2}
				tc += 1
				tree_rows[tc] = {id = 9, label = "flow.odin", detail = "3 KB", depth = 2}
				tc += 1
			}
		}
		tree_rows[tc] = {id = 10, label = "docs", detail = "guides", depth = 0, has_children = true, expanded = tree_expanded[3]}
		tc += 1
		if tree_expanded[3] {
			tree_rows[tc] = {id = 11, label = "INTERFACE.md", detail = "guide", depth = 1}
			tc += 1
		}
		tv_res := interface.tree_view(frame, tcontent, interface.identity("demo_tree"), tree_rows[:tc], &tree_state)
		if tv_res.toggle_index >= 0 && tv_res.toggle_index < tc {
			switch tree_rows[tv_res.toggle_index].id {
			case 1:
				tree_expanded[0] = !tree_expanded[0]
			case 2:
				tree_expanded[1] = !tree_expanded[1]
			case 7:
				tree_expanded[2] = !tree_expanded[2]
			case 10:
				tree_expanded[3] = !tree_expanded[3]
			}
		}

		// Draggable split divider between left and right panes (double-click resets to 50/50).
		_ = interface.split_pane_divider(frame, sp_div, interface.identity("demo_split"), .Horizontal, &split_ratio, full_body.width - 8, &split_drag)

		// Sortable, column-resizable, multi-select Data Table on right split pane.
		dcontent := interface.card(frame, sp_second, "DATA TABLE", "Sort, Resize, Multi-Select", graphics.colors.process)
		cols := [4]interface.Data_Table_Column{
			{title = "Module", min_width = 80, alignment = .Left, sortable = true},
			{title = "Role", min_width = 64, alignment = .Left, sortable = true},
			{title = "Pages", min_width = 56, alignment = .Right, sortable = true},
			{title = "State", min_width = 64, alignment = .Left, sortable = true},
		}
		page_bufs: [8][16]u8
		cells: [32]string
		for r in 0 ..< 8 {
			row := TABLE_SAMPLE_ROWS[table_order[r]]
			cells[r * 4 + 0] = row.name
			cells[r * 4 + 1] = row.kind
			pb: interface.Text_Builder
			interface.text_put_number(&pb, u64(row.pages))
			n := copy(page_bufs[r][:], interface.text_of(&pb))
			cells[r * 4 + 2] = string(page_bufs[r][:n])
			cells[r * 4 + 3] = row.state
		}
		dt_res := interface.data_table(frame, dcontent, interface.identity("demo_table"), cols[:], table_col_widths[:], 8, cells[:], table_selected[:], &table_state, multi_select = true)
		if dt_res.sort_changed {
			table_sort_apply()
		}

	case 3:
		// Tab 3: Live modus:layout.flow_wrap playground + Scoped Theme Subtree Preview.
		lcontent := interface.card(frame, left_area, "FLOW WRAP LAYOUT", "modus:layout.flow_wrap", theme.accent)
		lcol := interface.column_of(lcontent, 8)
		align_labels := [3]string{"Start", "Center", "End"}
		_ = interface.segmented_control(frame, interface.column_take(&lcol, 24), interface.identity("flow_align"), align_labels[:], &flow_align_choice)
		flow_area := interface.column_take(&lcol, max(lcol.area.height - 20, 80))
		interface.draw_rectangle(frame.table, flow_area.x, flow_area.y, flow_area.width, flow_area.height, theme.recess)
		interface.draw_outline(frame.table, flow_area.x, flow_area.y, flow_area.width, flow_area.height, 1, theme.border)
		chip_names := [?]string{"Box_Tree", "flex fill()", "children_sum()", "flow_wrap()", "split_pane()", "table_columns()", "Widget_Theme", "Toolbar Fold/Wrap", "Zero-Alloc", "Subpixel Snap"}
		f_items: [10]layout.Flow_Item
		f_places: [10]layout.Flow_Place
		for name, i in chip_names {
			f_items[i] = {width = i32(interface.text_measured_width(frame.table, interface.FONT_INTERFACE, name) + 20), height = 24}
		}
		align_options := [3]layout.Align{.Start, .Center, .End}
		align_val := align_options[clamp(flow_align_choice, 0, 2)]
		_, _, _ = layout.flow_wrap(f_items[:], f_places[:], {i32(flow_area.x + 8), i32(flow_area.y + 8), i32(max(flow_area.width - 16, 40)), i32(max(flow_area.height - 16, 40))}, 6, 6, align_val)
		for name, i in chip_names {
			p := f_places[i]
			interface.badge(frame, {int(p.x), int(p.y), int(p.width), int(p.height)}, name, i % 2 == 0 ? theme.accent : theme.ok)
		}

		// Right card: Two independent subtrees styled via theme_push / theme_pop side-by-side.
		rcontent := interface.card(frame, right_area, "SCOPED THEMES", "theme_push / theme_pop", graphics.colors.memory)
		rcol := interface.column_of(rcontent, 10)
		// Subtree 1: Amber accent.
		amber := interface.widget_theme_with_accent(graphics.rgb(218, 146, 38))
		if interface.theme_push(frame, amber) {
			interface.cell_text(frame, interface.column_take(&rcol, 16), "Amber subtree", amber.accent, .Left, interface.FONT_INTERFACE_BOLD)
			_ = interface.button_styled(frame, interface.column_take(&rcol, 26), interface.identity("sub_amber_btn"), "Amber Primary", .Primary)
			interface.progress_bar(frame, interface.column_take(&rcol, 14), 72, false, 0, "72%")
			_ = interface.theme_pop(frame)
		}
		// Subtree 2: Emerald accent.
		emerald := interface.widget_theme_with_accent(graphics.rgb(46, 178, 120))
		if interface.theme_push(frame, emerald) {
			interface.cell_text(frame, interface.column_take(&rcol, 16), "Emerald subtree", emerald.accent, .Left, interface.FONT_INTERFACE_BOLD)
			_ = interface.button_styled(frame, interface.column_take(&rcol, 26), interface.identity("sub_em_btn"), "Emerald Primary", .Primary)
			interface.progress_bar(frame, interface.column_take(&rcol, 14), 88, false, 0, "88%")
			_ = interface.theme_pop(frame)
		}
	}

	// Render adaptive collapsing/wrapping toolbar in its pre-solved layout rectangle
	// (drawn after Tab 0's primary controls so keyboard Tab focus order stays intact).
	tb_res := interface.toolbar(frame, toolbar_area, interface.identity("demo_toolbar"), tb_groups[:], tb_items[:], &toolbar_state, {overflow = toolbar_overflow}, w, h)
	if tb_res.triggered {
		demo_action_run(tb_res.triggered_id)
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

	// Action bar at the foot.
	items := bar_items()
	bar_res := interface.action_bar(frame, footer_area, items[:], &bar)

	// Floating overlays drawn last so they sit above every sibling card.
	if active_tab == 1 {
		_ = interface.dropdown_overlay(frame, interface.identity("role_dd"), role_labels[:], &dropdown_choice, &dropdown_state, w, h, searchable = false)
		_ = interface.dropdown_overlay(frame, interface.identity("combo_dd"), role_labels[:], &combo_choice, &combo_state, w, h, searchable = true)
		_ = interface.multi_select_overlay(frame, interface.identity("tags_ms"), tag_labels[:], tag_selected[:], &multi_state, w, h, searchable = true)
	}
	interface.toolbar_draw_overlay(frame, &toolbar_state)
	if tooltip_text != "" && !modal_open && !demo_ctx_menu.open && !demo_palette.open {
		interface.tooltip_draw(frame, tooltip_anchor, tooltip_text, w, h)
	}
	if demo_ctx_menu.open {
		interface.context_menu_draw(frame.table, &demo_ctx_menu)
	}
	if demo_palette.open {
		interface.command_palette_draw(frame.table, &demo_palette, w, h)
	}
	if modal_open {
		mr := interface.modal_dialog(frame, w, h, interface.identity("demo_modal"), &modal_open, "Reset component showcase", "Confirming resets every control to its default value.", "Reset now", "Cancel", danger = true)
		if mr.confirmed {
			demo_action_run(u32(Demo_Action.Reset_Demo))
			modal_last_action = "Confirmed"
		} else if mr.cancelled {
			modal_last_action = "Cancelled"
		} else if mr.closed {
			modal_last_action = "Dismissed"
		}
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
