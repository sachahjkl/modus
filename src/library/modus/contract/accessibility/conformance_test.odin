#+build !freestanding
#+build !modus
package accessibility

import "core:testing"
import "modus:contract/draw_record"

// The conformance suite of the assistive role, the part that a holder runs
// against the contract itself
// (src/md/features/accessibility.md, "2. The assistive role"): hostile
// tables are refused with no fault, an action that the element did not
// declare never runs, and a protected field publishes nothing of its value. The reader and the magnifier part is in
// src/library/modus/contract/screen_reader.

// The push fields of a record, to damage one field of a table that the
// builder wrote whole.
@(private = "file")
push_fields_of :: proc(record: ^draw_record.Draw_Record) -> ^draw_record.Element_Push_Fields {
	return (^draw_record.Element_Push_Fields)(&record.fields[0])
}

// A table that uses each part of the format: clips, nested elements, text
// runs, details of each kind of value, relations, a protected field.
@(private = "file")
conformance_table :: proc(b: ^Test_Builder) {
	b^ = {}
	press := [?]Element_Detail_Record{detail_actions_record({.Press, .Focus}), detail_relation_record(.Controls, 5)}
	value := [?]Element_Detail_Record{
		detail_integer_record(.Value_Now, 40),
		detail_integer_record(.Value_Minimum, 0),
		detail_integer_record(.Value_Maximum, 100),
		detail_actions_record({.Increment, .Decrement, .Set_Value}),
	}
	secret_first, secret_count := builder_append_bytes(b, "hunter2")
	secret := [?]Element_Detail_Record{
		detail_range_record(.Value_Text, secret_first, secret_count),
		detail_integer_record(.Caret, 7),
		detail_actions_record({.Focus, .Insert_Text}),
	}
	builder_push(b, 1, .Dialog, right = 400, bottom = 300, states = {.Modal}, name = "Settings")
	builder_clip_push(b, 0, 0, 400, 300)
	builder_push(b, 2, .Button, states = {.Focusable, .Focused}, details = press[:])
	builder_text(b, "Save", 2)
	builder_pop(b)
	builder_push(b, 3, .Slider, top = 30, bottom = 54, states = {.Focusable}, name = "Volume", details = value[:])
	builder_pop(b)
	builder_push(b, 4, .Text_Box, top = 60, bottom = 84, states = {.Focusable, .Protected}, name = "Passphrase", details = secret[:])
	builder_text(b, "hunter2", 4)
	builder_pop(b)
	builder_push(b, 5, .Status, top = 90, bottom = 114)
	builder_text(b, "Saved", 5)
	builder_pop(b)
	builder_clip_pop(b)
	builder_pop(b)
}

// A tree that a refusal leaves: empty, so a holder reads nothing of a table
// that it refused.
@(private = "file")
tree_is_cleared :: proc(tree: ^Semantic_Tree) -> bool {
	return tree.node_count == 0 && tree.first_root == -1 && tree.focused_node == -1 && tree.text_count == 0 && tree.focusable_count == 0
}

// The checks that each tree that extract takes must keep, whatever the
// table: links inside the nodes, texts inside the buffer, no protected value.
@(private = "file")
tree_is_sound :: proc(tree: ^Semantic_Tree) -> bool {
	if tree.node_count < 0 || tree.node_count > SEMANTIC_TREE_NODE_CAPACITY || tree.text_count < 0 || tree.text_count > SEMANTIC_TREE_TEXT_CAPACITY {
		return false
	}
	for index in 0 ..< tree.node_count {
		node := &tree.nodes[index]
		if node.parent >= i32(index) || node.parent < -1 {
			return false
		}
		if node.first_child != -1 && (node.first_child <= i32(index) || int(node.first_child) >= tree.node_count) {
			return false
		}
		if node.next_sibling != -1 && (node.next_sibling <= i32(index) || int(node.next_sibling) >= tree.node_count) {
			return false
		}
		if int(node.name_first) + int(node.name_count) > tree.text_count {
			return false
		}
		if .Protected in node.states {
			if node.has_value_now || node.has_caret || node.has_selection || node.value_text_count != 0 || node.live_text_count != 0 || .Insert_Text in node.actions {
				return false
			}
		}
	}
	return true
}

// Each hostile table of the borders is refused with its refusal, the tree
// is left empty, and the audit and the query of the same table refuse it
// too, with no fault.
@(test)
conformance_hostile_tables_are_refused_with_no_fault :: proc(t: ^testing.T) {
	b := new(Test_Builder)
	defer free(b)
	tree := new(Semantic_Tree)
	defer free(tree)
	findings: [8]Audit_Finding

	conformance_table(b)
	refusal, _ := semantic_tree_extract(b.records[:b.record_count], b.bytes[:b.byte_count], tree)
	testing.expect_value(t, refusal, Semantic_Tree_Refusal.None)
	testing.expect(t, tree.node_count == 5 && tree_is_sound(tree), "the whole table is taken")

	Damage :: enum {
		Kind_Word_Unknown,
		Header_Reserved,
		Element_Word_Zero,
		Role_Word_Unknown,
		State_Bit_Unknown,
		Name_Past_Table,
		Name_Damaged_Text,
		Detail_Unaligned,
		Detail_Count_Past_Limit,
		Detail_Past_Table,
		Detail_Kind_Zero,
		Detail_Kind_Unknown,
		Detail_Reserved,
		Detail_Action_Bit_Unknown,
		Relation_High_Word,
		Text_Of_Another_Element,
		Pop_Removed,
		Clip_Pop_Before_Element_Pop,
		Stray_Pop,
	}
	expected := [Damage]Semantic_Tree_Refusal{
		.Kind_Word_Unknown           = .Record_Invalid,
		.Header_Reserved             = .Record_Invalid,
		.Element_Word_Zero           = .Element_Word_Zero,
		.Role_Word_Unknown           = .Record_Invalid,
		.State_Bit_Unknown           = .Record_Invalid,
		.Name_Past_Table             = .Name_Range_Out_Of_Bounds,
		.Name_Damaged_Text           = .Name_Invalid_Text,
		.Detail_Unaligned            = .Record_Invalid,
		.Detail_Count_Past_Limit     = .Record_Invalid,
		.Detail_Past_Table           = .Detail_Range_Out_Of_Bounds,
		.Detail_Kind_Zero            = .Detail_Invalid,
		.Detail_Kind_Unknown         = .Detail_Invalid,
		.Detail_Reserved             = .Detail_Invalid,
		.Detail_Action_Bit_Unknown   = .Detail_Invalid,
		.Relation_High_Word          = .Detail_Invalid,
		.Text_Of_Another_Element     = .Element_Word_Mismatch,
		.Pop_Removed                 = .Push_Without_Pop,
		.Clip_Pop_Before_Element_Pop = .Pop_Wrong_Kind,
		.Stray_Pop                   = .Pop_Without_Push,
	}
	// The record of the button is 2; its details start after the text
	// "hunter2" of the builder, at the first multiple of 4.
	for damage in Damage {
		conformance_table(b)
		button := &b.records[2]
		fields := push_fields_of(button)
		switch damage {
		case .Kind_Word_Unknown:
			button.kind = 200
		case .Header_Reserved:
			button.reserved[1] = 1
		case .Element_Word_Zero:
			button.element = 0
		case .Role_Word_Unknown:
			fields.role = 255
		case .State_Bit_Unknown:
			fields.states |= 0x8000_0000
		case .Name_Past_Table:
			fields.name_first = u32(b.byte_count) - 1
			fields.name_count = 8
		case .Name_Damaged_Text:
			first, _ := builder_append_bytes(b, "\xC3\x28ok")
			fields.name_first, fields.name_count = first, 4
		case .Detail_Unaligned:
			fields.detail_first += 1
		case .Detail_Count_Past_Limit:
			fields.detail_count = ELEMENT_DETAIL_LIMIT + 1
		case .Detail_Past_Table:
			fields.detail_count = ELEMENT_DETAIL_LIMIT
		case .Detail_Kind_Zero:
			(^Element_Detail_Record)(&b.bytes[fields.detail_first]).kind = 0
		case .Detail_Kind_Unknown:
			(^Element_Detail_Record)(&b.bytes[fields.detail_first]).kind = 999
		case .Detail_Reserved:
			(^Element_Detail_Record)(&b.bytes[fields.detail_first]).reserved = 1
		case .Detail_Action_Bit_Unknown:
			(^Element_Detail_Record)(&b.bytes[fields.detail_first]).value_high = 0x8000_0000
		case .Relation_High_Word:
			(^Element_Detail_Record)(&b.bytes[int(fields.detail_first) + ELEMENT_DETAIL_RECORD_SIZE]).value_high = 1
		case .Text_Of_Another_Element:
			b.records[3].element = 3
		case .Pop_Removed:
			b.record_count -= 1
		case .Clip_Pop_Before_Element_Pop:
			b.records[b.record_count - 1], b.records[b.record_count - 2] = b.records[b.record_count - 2], b.records[b.record_count - 1]
		case .Stray_Pop:
			builder_pop(b)
		}
		records := b.records[:b.record_count]
		bytes := b.bytes[:b.byte_count]
		got, _ := semantic_tree_extract(records, bytes, tree)
		testing.expectf(t, got == expected[damage], "%v: refusal %v, want %v", damage, got, expected[damage])
		testing.expectf(t, tree_is_cleared(tree), "%v: a refused table must leave no node", damage)
		written, total := semantic_tree_audit_into(records, bytes, tree, findings[:])
		testing.expectf(t, written == 1 && total == 1 && findings[0].problem == .Table_Refused && findings[0].refusal == expected[damage], "%v: the audit must refuse the table", damage)
		_, found := semantic_query_element(records, bytes, .Button, "Save")
		testing.expectf(t, !found, "%v: the query must refuse the table", damage)
		report := semantic_tree_audit_table(records, bytes)
		testing.expectf(t, report.violation_count <= SEMANTIC_AUDIT_VIOLATION_CAPACITY && report.total_violations >= report.violation_count, "%v: the report keeps its bounds", damage)
	}

	// The bounds: one push past the depth, one node past the capacity.
	b^ = {}
	for depth in 0 ..= ELEMENT_DEPTH_LIMIT {
		builder_push(b, u32(depth + 1), .Group, name = "g")
	}
	for _ in 0 ..= ELEMENT_DEPTH_LIMIT {
		builder_pop(b)
	}
	got, problem := semantic_tree_extract(b.records[:b.record_count], b.bytes[:b.byte_count], tree)
	testing.expect(t, got == .Push_Past_Depth_Limit && problem == ELEMENT_DEPTH_LIMIT && tree_is_cleared(tree), "one push past the depth is refused")

	many := make([]draw_record.Draw_Record, 2 * (SEMANTIC_TREE_NODE_CAPACITY + 1))
	defer delete(many)
	for index in 0 ..= SEMANTIC_TREE_NODE_CAPACITY {
		many[2 * index] = draw_record.record_of(draw_record.Draw_Element_Push{role = .Group}, u32(index + 1), 0, 0, 64, 64)
		many[2 * index + 1] = draw_record.record_of(draw_record.Draw_Element_Pop{}, 0, 0, 0, 0, 0)
	}
	got, problem = semantic_tree_extract(many[:2 * SEMANTIC_TREE_NODE_CAPACITY], nil, tree)
	testing.expect(t, got == .None && tree.node_count == SEMANTIC_TREE_NODE_CAPACITY, "the capacity itself is taken")
	got, problem = semantic_tree_extract(many, nil, tree)
	testing.expect(t, got == .Node_Capacity_Exceeded && problem == 2 * SEMANTIC_TREE_NODE_CAPACITY && tree_is_cleared(tree), "one node past the capacity is refused")

	// An empty table is a window with no element: no node, no refusal.
	got, _ = semantic_tree_extract(nil, nil, tree)
	testing.expect(t, got == .None && tree_is_cleared(tree), "an empty table is an empty tree")
}

// Each byte of a valid table, damaged in turn and then at random, gives a
// tree that keeps its checks or a refusal with an empty tree: never a fault,
// never a protected value.
@(test)
conformance_damaged_bytes_never_fault :: proc(t: ^testing.T) {
	b := new(Test_Builder)
	defer free(b)
	tree := new(Semantic_Tree)
	defer free(tree)
	findings: [8]Audit_Finding

	conformance_table(b)
	record_bytes := b.record_count * size_of(draw_record.Draw_Record)
	total_bytes := record_bytes + b.byte_count
	original := new(Test_Builder)
	defer free(original)
	original^ = b^

	check_one :: proc(t: ^testing.T, b: ^Test_Builder, tree: ^Semantic_Tree, findings: []Audit_Finding, place: int) {
		records := b.records[:b.record_count]
		bytes := b.bytes[:b.byte_count]
		refusal, _ := semantic_tree_extract(records, bytes, tree)
		if refusal == .None {
			testing.expectf(t, tree_is_sound(tree), "damage at %d: a taken tree must keep its checks", place)
		} else {
			testing.expectf(t, tree_is_cleared(tree), "damage at %d: refusal %v left nodes", place, refusal)
		}
		_, _ = semantic_tree_audit_into(records, bytes, tree, findings)
		_ = semantic_tree_audit_table(records, bytes)
		_, _ = semantic_query_element(records, bytes, .Button, "Save")
	}

	// Each byte, set to each of the edges of a byte.
	for place in 0 ..< total_bytes {
		for value in ([?]u8{0x00, 0x01, 0x7F, 0x80, 0xFF}) {
			b^ = original^
			if place < record_bytes {
				(cast([^]u8)&b.records[0])[place] = value
			} else {
				b.bytes[place - record_bytes] = value
			}
			check_one(t, b, tree, findings[:], place)
		}
	}

	// Then several bytes at once, from a fixed seed so a failure repeats.
	state: u64 = 0x9E37_79B9_7F4A_7C15
	next :: proc(state: ^u64) -> u64 {
		state^ ~= state^ << 13
		state^ ~= state^ >> 7
		state^ ~= state^ << 17
		return state^
	}
	for round in 0 ..< 4000 {
		b^ = original^
		for _ in 0 ..< 1 + int(next(&state) % 6) {
			place := int(next(&state) % u64(total_bytes))
			value := u8(next(&state))
			if place < record_bytes {
				(cast([^]u8)&b.records[0])[place] = value
			} else {
				b.bytes[place - record_bytes] = value
			}
		}
		check_one(t, b, tree, findings[:], round)
	}
}

// An action runs only when the element declared it in its last frame: each
// word that names no action, each element that is absent, each action that
// was not declared is refused, and the window layer then sends no key.
@(test)
conformance_undeclared_action_never_fires :: proc(t: ^testing.T) {
	b := new(Test_Builder)
	defer free(b)
	tree := new(Semantic_Tree)
	defer free(tree)
	conformance_table(b)
	refusal, _ := semantic_tree_extract(b.records[:b.record_count], b.bytes[:b.byte_count], tree)
	testing.expect_value(t, refusal, Semantic_Tree_Refusal.None)

	// The keys that a fake window layer sends: one for each action that
	// the check takes, none for a refusal.
	fired: [dynamic]Element_Action
	defer delete(fired)
	declared := [6]Element_Actions{
		0 = {},
		1 = {},
		2 = {.Press, .Focus},
		3 = {.Increment, .Decrement, .Set_Value},
		4 = {.Focus}, // Insert_Text is gone: the field is protected.
		5 = {},
	}
	for element in u32(1) ..= 5 {
		for word in 0 ..= 255 {
			action, index, why := element_action_authorize(tree, element, u8(word))
			member, known := element_action_of_word(u8(word))
			switch {
			case !known:
				testing.expectf(t, why == .Action_Unknown && index == -1, "element %d word %d: %v", element, word, why)
			case member in declared[element]:
				testing.expectf(t, why == .None && action == member && tree.nodes[index].element == element, "element %d: declared %v refused: %v", element, member, why)
			case member == .Insert_Text && element == 4:
				testing.expectf(t, why == .Protected_Text && index == -1, "protected field: Insert_Text gave %v", why)
			case:
				testing.expectf(t, why == .Action_Not_Declared && index == -1, "element %d: undeclared %v gave %v", element, member, why)
			}
			if why == .None {
				append(&fired, action)
			}
		}
	}
	testing.expect_value(t, len(fired), 6)

	// An element that the frame does not hold: 0, an unknown word, the
	// largest word.
	for element in ([?]u32{0, 6, max(u32)}) {
		_, index, why := element_action_authorize(tree, element, u8(Element_Action.Press))
		testing.expectf(t, why == .Element_Absent && index == -1, "absent element %d gave %v", element, why)
	}
	_, nil_index, nil_why := element_action_authorize(nil, 2, u8(Element_Action.Press))
	testing.expect(t, nil_why == .Element_Absent && nil_index == -1, "no tree: no element")

	// A node built by hand with Insert_Text and Protected: the state wins.
	hand := Semantic_Node{element = 9, states = {.Protected}, actions = {.Insert_Text, .Focus}}
	_, hand_why := element_action_authorize_node(&hand, u8(Element_Action.Insert_Text))
	testing.expect_value(t, hand_why, Element_Action_Refusal.Protected_Text)
	_, hand_why = element_action_authorize_node(&hand, u8(Element_Action.Focus))
	testing.expect_value(t, hand_why, Element_Action_Refusal.None)
	anonymous := Semantic_Node{element = 0, actions = {.Press}}
	_, hand_why = element_action_authorize_node(&anonymous, u8(Element_Action.Press))
	testing.expect_value(t, hand_why, Element_Action_Refusal.Element_Absent)
	_, hand_why = element_action_authorize_node(nil, u8(Element_Action.Press))
	testing.expect_value(t, hand_why, Element_Action_Refusal.Element_Absent)

	// A second push of the same word is an anonymous group: it declares no
	// action, so the word acts on the first push only.
	b^ = {}
	press := [1]Element_Detail_Record{detail_actions_record({.Press})}
	builder_push(b, 7, .Button, states = {.Focusable}, name = "First", details = press[:])
	builder_pop(b)
	builder_push(b, 7, .Button, states = {.Focusable}, name = "Second", details = press[:])
	builder_pop(b)
	refusal, _ = semantic_tree_extract(b.records[:b.record_count], b.bytes[:b.byte_count], tree)
	testing.expect_value(t, refusal, Semantic_Tree_Refusal.None)
	testing.expect(t, tree.nodes[1].element == 0 && tree.nodes[1].actions == {}, "the duplicate declares nothing")
	_, index, why := element_action_authorize(tree, 7, u8(Element_Action.Press))
	testing.expect(t, why == .None && index == 0, "the word acts on the first push")
}

// A protected field publishes no value, no caret, no selection and no
// length; no event of two frames says its change; the audit names the leak.
@(test)
conformance_protected_field_publishes_nothing :: proc(t: ^testing.T) {
	b := new(Test_Builder)
	defer free(b)
	before := new(Semantic_Tree)
	defer free(before)
	now := new(Semantic_Tree)
	defer free(now)

	frame :: proc(b: ^Test_Builder, secret: string, caret: i64) {
		b^ = {}
		first, count := builder_append_bytes(b, secret)
		details := [?]Element_Detail_Record{
			detail_range_record(.Value_Text, first, count),
			detail_integer_record(.Value_Now, i64(count)),
			detail_integer_record(.Caret, caret),
			detail_integer_record(.Selection_Start, 0),
			detail_integer_record(.Selection_End, caret),
			detail_actions_record({.Focus, .Insert_Text}),
		}
		builder_push(b, 4, .Text_Box, states = {.Focusable, .Focused, .Protected}, live = .Assertive, name = "Passphrase", details = details[:])
		builder_text(b, secret, 4)
		builder_pop(b)
	}

	frame(b, "a", 1)
	refusal, _ := semantic_tree_extract(b.records[:b.record_count], b.bytes[:b.byte_count], before)
	testing.expect_value(t, refusal, Semantic_Tree_Refusal.None)
	frame(b, "hunter2", 7)
	refusal, _ = semantic_tree_extract(b.records[:b.record_count], b.bytes[:b.byte_count], now)
	testing.expect_value(t, refusal, Semantic_Tree_Refusal.None)

	node := &now.nodes[0]
	testing.expect(t, .Protected in node.states && node.protected_value_leaked, "the leak is marked")
	testing.expect(t, !node.has_value_now && !node.has_caret && !node.has_selection, "no value, caret or selection")
	testing.expect(t, node.value_text_count == 0 && node.live_text_count == 0, "no length")
	testing.expect_value(t, semantic_node_value_text(now, node), "")
	testing.expect_value(t, semantic_node_live_text(now, node), "")
	testing.expect_value(t, semantic_node_name(now, node), "Passphrase")
	testing.expect(t, .Insert_Text not_in node.actions, "a protected field declares no Insert_Text")
	testing.expect_value(t, now.protected_value_leaks, u32(1))

	// No byte of the secret is in the text of the tree.
	text := string(now.text_buffer[:now.text_count])
	for index in 0 ..< max(0, len(text) - 1) {
		testing.expectf(t, text[index:][:2] != "hu", "the secret is in the tree text: %q", text)
	}

	// The change of the secret makes no value event and no announcement.
	events: [16]Semantic_Event
	written, _ := semantic_tree_diff(before, now, events[:])
	for event in events[:written] {
		testing.expectf(t, event.kind != .Value_Changed && event.kind != .Live_Announcement, "the secret changed an event: %v", event.kind)
	}

	findings: [8]Audit_Finding
	audit_written, _ := semantic_tree_audit_nodes(now, findings[:])
	leak := false
	for finding in findings[:audit_written] {
		leak ||= finding.problem == .Protected_Field_Has_Value && finding.element == 4
	}
	testing.expect(t, leak, "the audit names the protected field that sent a value")

	// A protected field that sends nothing is no fault.
	b^ = {}
	builder_push(b, 4, .Text_Box, states = {.Focusable, .Protected}, name = "Passphrase")
	builder_pop(b)
	refusal, _ = semantic_tree_extract(b.records[:b.record_count], b.bytes[:b.byte_count], now)
	testing.expect(t, refusal == .None && !now.nodes[0].protected_value_leaked && now.protected_value_leaks == 0, "a clean protected field")
}
