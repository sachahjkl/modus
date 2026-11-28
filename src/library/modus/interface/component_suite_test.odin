#+build !freestanding
package interface

import "core:testing"
import "modus:display"
import "modus:graphics"

@(private = "file")
Suite_Harness :: struct {
	records: [4096]Draw_Record,
	text:    [32768]u8,
	table:   Draw_Table,
	state:   Interface_State,
	input:   Input,
}

@(private = "file")
suite_harness_init :: proc(h: ^Suite_Harness) {
	h.table = Draw_Table{records = h.records[:], text = h.text[:]}
}

@(test)
theme_stack_push_pop_and_bounds :: proc(t: ^testing.T) {
	h: Suite_Harness
	suite_harness_init(&h)
	frame := frame_begin(&h.table, &h.state, &h.input)

	// Nil frame and empty pop are refused cleanly.
	testing.expect(t, !theme_push(nil, widget_theme_default()))
	testing.expect(t, !theme_pop(nil))
	testing.expect(t, !theme_pop(&frame))

	base := theme_current(&frame)
	testing.expect_value(t, base.accent, graphics.colors.title)

	custom := widget_theme_with_accent(graphics.rgb(220, 140, 30))
	for _ in 0 ..< THEME_STACK_CAPACITY {
		testing.expect(t, theme_push(&frame, custom))
	}
	// Overflow past THEME_STACK_CAPACITY is refused without mutating stack depth.
	testing.expect(t, !theme_push(&frame, base))
	testing.expect_value(t, theme_current(&frame).accent, custom.accent)

	for _ in 0 ..< THEME_STACK_CAPACITY {
		testing.expect(t, theme_pop(&frame))
	}
	testing.expect(t, !theme_pop(&frame))
	testing.expect_value(t, theme_current(&frame).accent, graphics.colors.title)
}

@(test)
adaptive_toolbar_folds_by_priority_and_wraps_groups :: proc(t: ^testing.T) {
	h: Suite_Harness
	suite_harness_init(&h)

	groups := [3]Toolbar_Group{
		{title = "Tools", priority = 2},
		{title = "Extra", priority = 0, separator = true},
		{title = "Actions", priority = 5, pinned = true},
	}
	items := [5]Toolbar_Item{
		{id = 1, group = 0, label = "Select"},
		{id = 2, group = 0, label = "Draw"},
		{id = 3, group = 1, label = "Grid"},
		{id = 4, group = 1, label = "Snap"},
		{id = 5, group = 2, label = "Save", variant = .Primary},
	}
	tb_state: Toolbar_State

	// Narrow width in .Fold mode must fold low-priority items while keeping pinned Save visible.
	frame := frame_begin(&h.table, &h.state, &h.input)
	res_fold := toolbar(&frame, {0, 0, 220, TOOLBAR_ROW_HEIGHT}, identity("tb"), groups[:], items[:], &tb_state, {overflow = .Fold}, 640, 400)
	frame_end(&frame)
	testing.expect_value(t, res_fold.line_count, 1)
	testing.expect(t, res_fold.folded_count >= 2)
	testing.expect(t, tb_state.more_area.width == TOOLBAR_MORE_WIDTH)

	// Clicking "..." (press + release) opens the overflow menu containing folded items.
	h.input = {pointer_x = tb_state.more_area.x + 6, pointer_y = tb_state.more_area.y + 6, pointer_known = true, pressed = true, button_held = true}
	frame = frame_begin(&h.table, &h.state, &h.input)
	_ = toolbar(&frame, {0, 0, 220, TOOLBAR_ROW_HEIGHT}, identity("tb"), groups[:], items[:], &tb_state, {overflow = .Fold}, 640, 400)
	frame_end(&frame)
	h.input = {pointer_x = tb_state.more_area.x + 6, pointer_y = tb_state.more_area.y + 6, pointer_known = true, released = true}
	frame = frame_begin(&h.table, &h.state, &h.input)
	_ = toolbar(&frame, {0, 0, 220, TOOLBAR_ROW_HEIGHT}, identity("tb"), groups[:], items[:], &tb_state, {overflow = .Fold}, 640, 400)
	toolbar_draw_overlay(&frame, &tb_state)
	frame_end(&frame)
	testing.expect(t, tb_state.overflow_menu.open)
	testing.expect(t, tb_state.overflow_menu.item_count == res_fold.folded_count)

	// Same narrow width in .Wrap mode expands to multiple lines with zero folded items.
	h.input = {}
	wrap_h := toolbar_measure_height(&h.table, 220, groups[:], items[:], .Wrap)
	testing.expect(t, wrap_h > TOOLBAR_ROW_HEIGHT)
	frame = frame_begin(&h.table, &h.state, &h.input)
	res_wrap := toolbar(&frame, {0, 0, 220, wrap_h}, identity("tb"), groups[:], items[:], &tb_state, {overflow = .Wrap}, 640, 400)
	frame_end(&frame)
	testing.expect(t, res_wrap.line_count >= 2)
	testing.expect_value(t, res_wrap.folded_count, 0)
	testing.expect(t, !tb_state.overflow_menu.open)
}

@(test)
checkbox_radio_stepper_and_disclosure_interactions :: proc(t: ^testing.T) {
	h: Suite_Harness
	suite_harness_init(&h)

	// Tri-state checkbox transitions Mixed -> Checked -> Unchecked, and refuses disabled clicks.
	tri := Checkbox_State.Mixed
	h.input = {pointer_x = 12, pointer_y = 12, pointer_known = true, pressed = true, button_held = true}
	f := frame_begin(&h.table, &h.state, &h.input)
	r := checkbox_tri(&f, {0, 0, 180, 24}, identity("cb"), "Select all", &tri)
	frame_end(&f)
	h.input = {pointer_x = 12, pointer_y = 12, pointer_known = true, released = true}
	f = frame_begin(&h.table, &h.state, &h.input)
	r = checkbox_tri(&f, {0, 0, 180, 24}, identity("cb"), "Select all", &tri)
	frame_end(&f)
	testing.expect(t, r.changed)
	testing.expect_value(t, tri, Checkbox_State.Checked)

	// Disabled checkbox stays unchanged on click.
	h.input = {pointer_x = 12, pointer_y = 12, pointer_known = true, pressed = true, button_held = true}
	f = frame_begin(&h.table, &h.state, &h.input)
	r = checkbox_tri(&f, {0, 0, 180, 24}, identity("cb"), "Select all", &tri, disabled = true)
	frame_end(&f)
	testing.expect(t, !r.changed)
	testing.expect_value(t, tri, Checkbox_State.Checked)

	// Radio group clamps out-of-range initial value and handles click on second item.
	radios := [3]string{"Alpha", "Beta", "Gamma"}
	choice := 99
	h.input = {pointer_x = 20, pointer_y = 32, pointer_known = true, pressed = true, button_held = true}
	f = frame_begin(&h.table, &h.state, &h.input)
	rr := radio_group(&f, {0, 0, 160, 72}, identity("rg"), radios[:], &choice, .Vertical)
	frame_end(&f)
	testing.expect(t, rr.changed)
	testing.expect_value(t, choice, 1)

	// Number stepper increments on "+" click and clamps at max.
	val := 9
	h.input = {pointer_x = 110, pointer_y = 12, pointer_known = true, pressed = true, button_held = true}
	f = frame_begin(&h.table, &h.state, &h.input)
	sr := number_stepper(&f, {0, 0, 120, 24}, identity("ns"), &val, 0, 10, 5)
	frame_end(&f)
	testing.expect(t, sr.changed)
	testing.expect_value(t, val, 10)

	// Disclosure toggles open state.
	open := false
	h.input = {pointer_x = 20, pointer_y = 12, pointer_known = true, pressed = true, button_held = true}
	f = frame_begin(&h.table, &h.state, &h.input)
	_ = disclosure(&f, {0, 0, 200, 26}, identity("disc"), "Advanced", &open)
	frame_end(&f)
	h.input = {pointer_x = 20, pointer_y = 12, pointer_known = true, released = true}
	f = frame_begin(&h.table, &h.state, &h.input)
	dr := disclosure(&f, {0, 0, 200, 26}, identity("disc"), "Advanced", &open)
	frame_end(&f)
	testing.expect(t, dr.changed)
	testing.expect(t, open)
}

@(test)
dropdown_combobox_and_multi_select_filter_and_choose :: proc(t: ^testing.T) {
	h: Suite_Harness
	suite_harness_init(&h)

	options := [4]string{"Compositor", "Storage", "Network", "Scheduler"}
	selected := 0
	dd: Dropdown_State
	dd.open = true
	dd.trigger = {10, 10, 200, 26}

	// Type "net" to filter to "Network" (index 2), then press Enter.
	h.input = {}
	_ = input_key_add(&h.input, {character = 'n'})
	_ = input_key_add(&h.input, {character = 'e'})
	_ = input_key_add(&h.input, {character = 't'})
	f := frame_begin(&h.table, &h.state, &h.input)
	_ = dropdown_overlay(&f, identity("dd"), options[:], &selected, &dd, 640, 480, searchable = true)
	frame_end(&f)
	testing.expect_value(t, dd.filter_len, 3)

	h.input = {}
	_ = input_key_add(&h.input, {code = display.KEY_ENTER})
	f = frame_begin(&h.table, &h.state, &h.input)
	changed := dropdown_overlay(&f, identity("dd"), options[:], &selected, &dd, 640, 480, searchable = true)
	frame_end(&f)
	testing.expect(t, changed)
	testing.expect_value(t, selected, 2)
	testing.expect(t, !dd.open)

	// Multi-select toggles item with Enter and stays open until Escape.
	ms_sel := [4]bool{true, false, false, false}
	ms: Multi_Select_State
	ms.open = true
	ms.highlighted = 1
	ms.trigger = {10, 10, 240, 28}
	h.input = {}
	_ = input_key_add(&h.input, {code = display.KEY_ENTER})
	f = frame_begin(&h.table, &h.state, &h.input)
	mchanged := multi_select_overlay(&f, identity("ms"), options[:], ms_sel[:], &ms, 640, 480, searchable = true)
	frame_end(&f)
	testing.expect(t, mchanged)
	testing.expect(t, ms_sel[1])
	testing.expect(t, ms.open)

	h.input = {}
	_ = input_key_add(&h.input, {code = display.KEY_ESCAPE})
	f = frame_begin(&h.table, &h.state, &h.input)
	_ = multi_select_overlay(&f, identity("ms"), options[:], ms_sel[:], &ms, 640, 480, searchable = true)
	frame_end(&f)
	testing.expect(t, !ms.open)
}

@(test)
split_pane_data_table_tree_text_area_and_modal :: proc(t: ^testing.T) {
	h: Suite_Harness
	suite_harness_init(&h)

	// Split divider double-click resets to 5000.
	ratio: i32 = 3000
	drag: Split_Drag_State
	h.input = {pointer_x = 102, pointer_y = 50, pointer_known = true, pressed = true, button_held = true}
	f := frame_begin(&h.table, &h.state, &h.input, time = 100)
	_ = split_pane_divider(&f, {100, 0, 6, 200}, identity("sp"), .Horizontal, &ratio, 400, &drag)
	frame_end(&f)
	h.input = {pointer_x = 102, pointer_y = 50, pointer_known = true, pressed = true, button_held = true}
	f = frame_begin(&h.table, &h.state, &h.input, time = 220)
	sr := split_pane_divider(&f, {100, 0, 6, 200}, identity("sp"), .Horizontal, &ratio, 400, &drag)
	frame_end(&f)
	testing.expect(t, sr.changed)
	testing.expect_value(t, ratio, i32(SPLIT_RATIO_DEFAULT))

	// Data table sorts on header click and toggles multi-select on row click.
	cols := [2]Data_Table_Column{
		{title = "Module", min_width = 80, sortable = true},
		{title = "Pages", min_width = 60, alignment = .Right, sortable = true},
	}
	widths := [2]int{140, 80}
	cells := [4]string{"root", "120", "console", "45"}
	sel_rows := [2]bool{}
	dt: Data_Table_State
	h.input = {pointer_x = 20, pointer_y = 12, pointer_known = true, pressed = true, button_held = true}
	f = frame_begin(&h.table, &h.state, &h.input)
	dtr := data_table(&f, {0, 0, 260, 120}, identity("dt"), cols[:], widths[:], 2, cells[:], sel_rows[:], &dt, multi_select = true)
	frame_end(&f)
	testing.expect(t, dtr.sort_changed)
	testing.expect_value(t, dt.sort_column, 0)
	testing.expect_value(t, dt.sort_order, Table_Sort_Order.Ascending)

	// Tree view toggles parent on click.
	tree_rows := [2]Tree_Row{
		{id = 1, label = "src", depth = 0, has_children = true, expanded = false},
		{id = 2, label = "docs", depth = 0, has_children = false},
	}
	tv: Tree_View_State
	h.input = {pointer_x = 24, pointer_y = 12, pointer_known = true, pressed = true, button_held = true}
	f = frame_begin(&h.table, &h.state, &h.input)
	tvr := tree_view(&f, {0, 0, 200, 100}, identity("tv"), tree_rows[:], &tv)
	frame_end(&f)
	testing.expect_value(t, tvr.toggle_index, 0)

	// Text area inserts characters and newline, then respects buffer capacity.
	buf: [6]u8
	cnt := 0
	ta: Text_Area_State
	h.state.focus = identity("ta")
	h.input = {}
	_ = input_key_add(&h.input, {character = 'a'})
	_ = input_key_add(&h.input, {code = display.KEY_ENTER})
	_ = input_key_add(&h.input, {character = 'b'})
	f = frame_begin(&h.table, &h.state, &h.input)
	tar := text_area(&f, {0, 0, 240, 100}, identity("ta"), buf[:], &cnt, &ta)
	frame_end(&f)
	testing.expect(t, tar.changed)
	testing.expect_value(t, string(buf[:cnt]), "a\nb")

	// Modal dialog closes on Escape.
	modal_open := true
	h.input = {}
	_ = input_key_add(&h.input, {code = display.KEY_ESCAPE})
	f = frame_begin(&h.table, &h.state, &h.input)
	mr := modal_dialog(&f, 640, 480, identity("md"), &modal_open, "Delete item", "Are you sure?")
	frame_end(&f)
	testing.expect(t, mr.closed)
	testing.expect(t, !modal_open)
}
