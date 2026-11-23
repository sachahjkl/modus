#+build !freestanding
package interface

import "core:testing"
import "modus:contract/accessibility"
import "modus:contract/draw_record"
import "modus:graphics"

@(private = "file")
Semantic_Test_Memory :: struct {
	records: [512]Draw_Record,
	text:    [8192]u8,
}

@(private = "file")
semantic_table_of :: proc(m: ^Semantic_Test_Memory) -> Draw_Table {
	return {records = m.records[:], text = m.text[:]}
}

// Every core widget of the interface package produces a balanced draw table
// that passes table_order_check, reconstructs a full semantic tree with
// accurate WAI-ARIA 1.2 roles, names, states and details, and passes
// semantic_tree_audit with zero findings.
@(test)
interface_widgets_produce_valid_zero_audit_semantic_tree :: proc(t: ^testing.T) {
	process_drawing_begin()
	memory := new(Semantic_Test_Memory)
	defer free(memory)
	table := semantic_table_of(memory)
	state: Interface_State
	input: Input
	bar_state: Action_Bar_State

	typed: [32]u8
	typed_count := copy(typed[:], "hello")
	secret: [32]u8
	secret_count := copy(secret[:], "s3cr3t")
	names := [?]string{"alpha", "beta", "gamma", "delta"}
	choice := 1
	rows := [?]List_Row{
		{kind = .Heading, name = "Section"},
		{kind = .Entry, name = "item one", detail = "ready"},
		{kind = .Entry, name = "item two", detail = "idle"},
	}
	actions := [?]Action_Bar_Item{
		action_bar_item("save", 2, "Ctrl", "s"),
		action_bar_item("close", 1, "Esc"),
	}

	frame := frame_begin(&table, &state, &input)
	draw_heading(&frame, 8, 8, 300, "Dashboard", graphics.colors.text)
	_ = card(&frame, {8, 40, 320, 120}, "Controls", "Interactive elements", graphics.colors.kernel, "2")
	_ = button(&frame, {20, 80, 100, 24}, identity("apply"), "Apply")
	_ = button(&frame, {130, 80, 120, 24}, identity("pin"), "Pinned", true)
	_ = text_input(&frame, {20, 112, 180, 24}, identity("search"), typed[:], &typed_count, "Type query", "Search")
	_ = text_input(&frame, {210, 112, 100, 24}, identity("pass"), secret[:], &secret_count, "Passphrase", "Unlock passphrase", true)
	_ = list_with_choice(&frame, {8, 170, 200, 72}, identity("items"), names[:], &choice, {name = "Items"})
	_ = list_of_rows(&frame, {220, 170, 200, 72}, rows[:], {chosen = -1, total = len(rows), element = identity("rows"), name = "Rows"})
	bar_with_value(&frame, {8, 250, 220, TABLE_LINE}, 120, 42, 100, graphics.colors.process)
	col := column_of({8, 280, 320, 80})
	_, _ = case_lines(&frame, &col, 0, "ping", "ok", 140, graphics.colors.dim, graphics.colors.process)
	_ = action_bar(&frame, {0, 380, 480, ACTION_BAR_ROW_HEIGHT}, actions[:], &bar_state)
	frame_end(&frame)

	testing.expect(t, !table.refused && !table.full, "frame table must not be refused or full")
	order_problem, order_index := draw_record.table_order_check(table.records[:table.record_count])
	testing.expectf(t, order_problem == .None, "table_order_check failed with %v at %d", order_problem, order_index)

	tree := new(accessibility.Semantic_Tree)
	defer free(tree)
	findings: [32]accessibility.Audit_Finding
	written, total := accessibility.semantic_tree_audit(table.records[:table.record_count], table.text[:table.text_count], tree, findings[:])
	for f in findings[:written] {
		testing.expectf(t, false, "unexpected audit finding: problem=%v refusal=%v role=%v element=%d record=%d", f.problem, f.refusal, f.role, f.element, f.record_index)
	}
	testing.expect_value(t, total, 0)
	testing.expect(t, tree.node_count >= 15, "expected semantic nodes for all drawn widgets")

	// Spot-check key nodes by element identity.
	apply_idx := accessibility.semantic_tree_find_by_element(tree, u32(identity("apply")))
	testing.expect(t, apply_idx >= 0, "apply button must exist in tree")
	if apply_idx >= 0 {
		n := &tree.nodes[apply_idx]
		testing.expect_value(t, n.role, accessibility.Element_Role.Button)
		testing.expect_value(t, accessibility.semantic_node_name(tree, n), "Apply")
		testing.expect(t, .Focusable in n.states && .Press in n.actions, "button must be focusable and pressable")
	}

	pin_idx := accessibility.semantic_tree_find_by_element(tree, u32(identity("pin")))
	testing.expect(t, pin_idx >= 0, "pin toggle button must exist")
	if pin_idx >= 0 {
		testing.expect_value(t, tree.nodes[pin_idx].toggle, accessibility.Toggle_State.True)
	}

	search_idx := accessibility.semantic_tree_find_by_element(tree, u32(identity("search")))
	testing.expect(t, search_idx >= 0, "search textbox must exist")
	if search_idx >= 0 {
		n := &tree.nodes[search_idx]
		testing.expect_value(t, n.role, accessibility.Element_Role.Text_Box)
		testing.expect_value(t, accessibility.semantic_node_name(tree, n), "Search")
		testing.expect_value(t, accessibility.semantic_node_placeholder(tree, n), "Type query")
		testing.expect_value(t, accessibility.semantic_node_value_text(tree, n), "hello")
		testing.expect_value(t, n.caret, u64(5))
	}

	pass_idx := accessibility.semantic_tree_find_by_element(tree, u32(identity("pass")))
	testing.expect(t, pass_idx >= 0, "protected textbox must exist")
	if pass_idx >= 0 {
		n := &tree.nodes[pass_idx]
		testing.expect(t, .Protected in n.states, "passphrase must carry Protected state")
		testing.expect_value(t, accessibility.semantic_node_value_text(tree, n), "")
		testing.expect(t, !n.has_caret, "protected field must not publish caret")
		testing.expect(t, .Insert_Text not_in n.actions, "protected field must not declare Insert_Text")
	}

	list_idx := accessibility.semantic_tree_find_by_element(tree, u32(identity("items")))
	testing.expect(t, list_idx >= 0, "listbox must exist")
	if list_idx >= 0 {
		testing.expect_value(t, tree.nodes[list_idx].role, accessibility.Element_Role.List_Box)
		testing.expect_value(t, accessibility.semantic_node_name(tree, &tree.nodes[list_idx]), "Items")
	}
	chosen_opt_idx := accessibility.semantic_tree_find_by_element(tree, u32(identity_with(identity("items"), 1)))
	testing.expect(t, chosen_opt_idx >= 0, "chosen option must exist")
	if chosen_opt_idx >= 0 {
		n := &tree.nodes[chosen_opt_idx]
		testing.expect_value(t, n.role, accessibility.Element_Role.Option)
		testing.expect(t, .Selected in n.states, "chosen option must be selected")
		testing.expect_value(t, accessibility.semantic_node_name(tree, n), "beta")
		testing.expect_value(t, n.position_in_set, u32(2))
		testing.expect_value(t, n.set_size, u32(4))
	}
}

// Snapshot diffing over interactive interface frames detects focus moves,
// button toggle changes, text value edits, list selection changes, and scroll
// bar updates while emitting nothing for protected field edits.
@(test)
interface_widget_interactions_emit_semantic_diff_events :: proc(t: ^testing.T) {
	process_drawing_begin()
	mem_a := new(Semantic_Test_Memory)
	mem_b := new(Semantic_Test_Memory)
	tree_a := new(accessibility.Semantic_Tree)
	tree_b := new(accessibility.Semantic_Tree)
	defer free(mem_a)
	defer free(mem_b)
	defer free(tree_a)
	defer free(tree_b)

	state: Interface_State
	input: Input
	typed: [32]u8
	typed_count := copy(typed[:], "go")
	secret: [32]u8
	secret_count := copy(secret[:], "pw")
	names := [?]string{"one", "two", "three"}
	choice := 0
	toggled := false
	scroll_first := 0

	draw_scene :: proc(table: ^Draw_Table, state: ^Interface_State, input: ^Input, toggled: bool, typed: []u8, typed_count: ^int, secret: []u8, secret_count: ^int, names: []string, choice: ^int, scroll_first: int) {
		frame := frame_begin(table, state, input)
		_ = button(&frame, {8, 8, 100, 24}, identity("toggle"), "Toggle", toggled)
		_ = text_input(&frame, {8, 40, 160, 24}, identity("edit"), typed, typed_count, "query", "Query")
		_ = text_input(&frame, {8, 72, 160, 24}, identity("secret"), secret, secret_count, "secret", "Secret", true)
		_ = list_with_choice(&frame, {8, 104, 160, 72}, identity("choices"), names, choice, {name = "Choices"})
		_ = scroll_bar(&frame, {180, 104, SCROLL_BAR_THICKNESS, 120}, identity("scroll"), .Vertical, {total = 50, visible = 10, first = scroll_first}, {}, "content")
		frame_end(&frame)
		input_clear(input)
	}

	// Frame 1: initial unfocused state.
	table_a := semantic_table_of(mem_a)
	draw_scene(&table_a, &state, &input, toggled, typed[:], &typed_count, secret[:], &secret_count, names[:], &choice, scroll_first)
	refusal, _ := accessibility.semantic_tree_extract(table_a.records[:table_a.record_count], table_a.text[:table_a.text_count], tree_a)
	testing.expect_value(t, refusal, accessibility.Semantic_Tree_Refusal.None)

	// Frame 2: focus edit field, type '!', toggle button, move list choice, scroll bar, and mutate protected secret.
	state.focus = identity("edit")
	input_add(&input, {kind = .Key, pressed = true, character = '!'})
	toggled = true
	choice = 2
	scroll_first = 12
	secret[secret_count] = '9'
	secret_count += 1

	table_b := semantic_table_of(mem_b)
	draw_scene(&table_b, &state, &input, toggled, typed[:], &typed_count, secret[:], &secret_count, names[:], &choice, scroll_first)
	refusal, _ = accessibility.semantic_tree_extract(table_b.records[:table_b.record_count], table_b.text[:table_b.text_count], tree_b)
	testing.expect_value(t, refusal, accessibility.Semantic_Tree_Refusal.None)

	events: [32]accessibility.Semantic_Event
	written, total := accessibility.semantic_tree_diff(tree_a, tree_b, events[:])
	testing.expect(t, written == total && total > 0, "expected diff events across state changes")

	saw_focus := false
	saw_toggle := false
	saw_edit_value := false
	saw_scroll_value := false
	saw_option_selected := false
	saw_secret_value := false
	for ev in events[:written] {
		if ev.kind == .Focus_Changed && ev.element == u32(identity("edit")) {
			saw_focus = true
		}
		if ev.kind == .State_Changed && ev.element == u32(identity("toggle")) && ev.old_toggle == .None && ev.new_toggle == .True {
			saw_toggle = true
		}
		if ev.kind == .Value_Changed && ev.element == u32(identity("edit")) {
			saw_edit_value = true
		}
		if ev.kind == .Value_Changed && ev.element == u32(identity("scroll")) {
			saw_scroll_value = true
		}
		if ev.kind == .State_Changed && ev.element == u32(identity_with(identity("choices"), 2)) && .Selected in ev.new_states {
			saw_option_selected = true
		}
		if ev.kind == .Value_Changed && ev.element == u32(identity("secret")) {
			saw_secret_value = true
		}
	}
	testing.expect(t, saw_focus, "expected Focus_Changed on edit field")
	testing.expect(t, saw_toggle, "expected State_Changed toggle on button")
	testing.expect(t, saw_edit_value, "expected Value_Changed on edit field")
	testing.expect(t, saw_scroll_value, "expected Value_Changed on scroll bar")
	testing.expect(t, saw_option_selected, "expected State_Changed .Selected on newly chosen option")
	testing.expect(t, !saw_secret_value, "protected field edit must never emit Value_Changed")
}

// Writer guards: draw_element_push / draw_element_pop refuse zero element word,
// depth past ELEMENT_DEPTH_LIMIT, interleaved clip pops, and frame_end closes
// any forgotten pushes cleanly in LIFO order so table_order_check always holds.
@(test)
element_push_writer_enforces_order_and_bounds :: proc(t: ^testing.T) {
	memory := new(Semantic_Test_Memory)
	defer free(memory)
	table := semantic_table_of(memory)
	state: Interface_State
	input: Input

	// 1. Element word 0 is refused and its pop is skipped cleanly.
	frame := frame_begin(&table, &state, &input)
	draw_element_push(frame.table, {0, 0, 50, 20}, 0, .Button, {name = "bad"})
	draw_rectangle(frame.table, 0, 0, 50, 20, graphics.colors.track, 7)
	draw_element_pop(frame.table)
	frame_end(&frame)
	testing.expect(t, table.refused, "element word 0 must set refused")
	problem, _ := draw_record.table_order_check(table.records[:table.record_count])
	testing.expect_value(t, problem, draw_record.Table_Order_Problem.None)

	// 2. Depth past ELEMENT_DEPTH_LIMIT sets refused and still produces a balanced table.
	frame = frame_begin(&table, &state, &input)
	for i in 0 ..= draw_record.ELEMENT_DEPTH_LIMIT {
		draw_element_push(frame.table, {0, 0, 50, 20}, u32(i + 1), .Group)
	}
	draw_rectangle(frame.table, 0, 0, 10, 10, graphics.colors.track, 999)
	for _ in 0 ..= draw_record.ELEMENT_DEPTH_LIMIT {
		draw_element_pop(frame.table)
	}
	frame_end(&frame)
	testing.expect(t, table.refused, "depth past ELEMENT_DEPTH_LIMIT must set refused")
	problem, _ = draw_record.table_order_check(table.records[:table.record_count])
	testing.expect_value(t, problem, draw_record.Table_Order_Problem.None)

	// 3. Interleaved pop is refused, and frame_end unwinds open clip+element pushes in LIFO order.
	frame = frame_begin(&table, &state, &input)
	draw_clip_push(frame.table, 0, 0, 100, 100)
	draw_element_push(frame.table, {0, 0, 80, 24}, 42, .Group, {name = "outer"})
	// Wrong pop kind: clip pop while element push is on top.
	draw_clip_pop(frame.table)
	testing.expect(t, table.refused, "interleaved clip pop must set refused")
	// Leave both pushes open; frame_end must close them in LIFO order.
	frame_end(&frame)
	problem, _ = draw_record.table_order_check(table.records[:table.record_count])
	testing.expect_value(t, problem, draw_record.Table_Order_Problem.None)
}
