#+build !freestanding
package accessibility

import "core:mem"
import "core:testing"
import "modus:contract/draw_record"

@(private = "package")
Test_Builder :: struct {
	records:      [512]draw_record.Draw_Record,
	record_count: int,
	bytes:        [8192]u8 `align(8)`,
	byte_count:   int,
}

@(private = "package")
builder_append_bytes :: proc(b: ^Test_Builder, text: string) -> (first, count: u32) {
	if len(text) == 0 {
		return 0, 0
	}
	first = u32(b.byte_count)
	copy(b.bytes[b.byte_count:], text)
	b.byte_count += len(text)
	return first, u32(len(text))
}

@(private = "package")
builder_append_details :: proc(b: ^Test_Builder, details: []Element_Detail_Record) -> (first: u32, count: u16) {
	if len(details) == 0 {
		return 0, 0
	}
	aligned := (b.byte_count + 3) & ~int(3)
	b.byte_count = aligned
	first = u32(aligned)
	size := len(details) * ELEMENT_DETAIL_RECORD_SIZE
	mem.copy(&b.bytes[aligned], raw_data(details), size)
	b.byte_count += size
	return first, u16(len(details))
}

@(private = "package")
builder_push :: proc(
	b: ^Test_Builder,
	element: u32,
	role: Element_Role,
	left := 0,
	top := 0,
	right := 100,
	bottom := 24,
	states: Element_States = {},
	live: Live_Mode = .Off,
	toggle: Toggle_State = .None,
	expanded: Expanded_State = .None,
	name := "",
	details: []Element_Detail_Record = nil,
) {
	nf, nc := builder_append_bytes(b, name)
	df, dc := builder_append_details(b, details)
	push := draw_record.Draw_Element_Push{
		role         = role,
		live         = live,
		toggle       = toggle,
		expanded     = expanded,
		states       = states,
		name_first   = nf,
		name_count   = u16(nc),
		detail_first = df,
		detail_count = dc,
	}
	b.records[b.record_count] = draw_record.record_of(
		push,
		element,
		draw_record.units_of_pixels(left),
		draw_record.units_of_pixels(top),
		draw_record.units_of_pixels(right),
		draw_record.units_of_pixels(bottom),
	)
	b.record_count += 1
}

@(private = "package")
builder_pop :: proc(b: ^Test_Builder, element: u32 = 0) {
	b.records[b.record_count] = draw_record.record_of(draw_record.Draw_Element_Pop{}, element, 0, 0, 0, 0)
	b.record_count += 1
}

@(private = "package")
builder_clip_push :: proc(b: ^Test_Builder, left, top, right, bottom: int, element: u32 = 0) {
	b.records[b.record_count] = draw_record.record_of(
		draw_record.Draw_Clip_Push{},
		element,
		draw_record.units_of_pixels(left),
		draw_record.units_of_pixels(top),
		draw_record.units_of_pixels(right),
		draw_record.units_of_pixels(bottom),
	)
	b.record_count += 1
}

@(private = "package")
builder_clip_pop :: proc(b: ^Test_Builder, element: u32 = 0) {
	b.records[b.record_count] = draw_record.record_of(draw_record.Draw_Clip_Pop{}, element, 0, 0, 0, 0)
	b.record_count += 1
}

@(private = "package")
builder_text :: proc(b: ^Test_Builder, text: string, element: u32 = 0, x := 0, y := 0) {
	first, count := builder_append_bytes(b, text)
	primitive := draw_record.Draw_Text{
		first    = first,
		count    = count,
		color    = draw_record.opaque(0x00FFFFFF),
		origin_x = draw_record.units_of_pixels(x),
		font     = .Cells_8x16,
		weight   = .Regular,
		size     = 16 * draw_record.UNITS_PER_PIXEL,
	}
	b.records[b.record_count] = draw_record.record_of(
		primitive,
		element,
		draw_record.units_of_pixels(x),
		draw_record.units_of_pixels(y),
		draw_record.units_of_pixels(x + max(len(text), 1) * 8),
		draw_record.units_of_pixels(y + 16),
	)
	b.record_count += 1
}

@(private = "file")
builder_rect :: proc(b: ^Test_Builder, element: u32 = 0, left := 0, top := 0, right := 20, bottom := 20) {
	b.records[b.record_count] = draw_record.record_of(
		draw_record.Draw_Rectangle{color = draw_record.opaque(0x00102030)},
		element,
		draw_record.units_of_pixels(left),
		draw_record.units_of_pixels(top),
		draw_record.units_of_pixels(right),
		draw_record.units_of_pixels(bottom),
	)
	b.record_count += 1
}

// Every border converter refuses every value outside its closed enum or bit mask.
@(test)
border_converters_refuse_unknown_words_and_bits :: proc(t: ^testing.T) {
	// Element_Action: 0..=max valid, past max refused.
	for word in 0 ..= 255 {
		action, ok := element_action_of_word(u8(word))
		if word <= int(max(Element_Action)) {
			testing.expectf(t, ok && u8(action) == u8(word), "valid action %d refused", word)
		} else {
			testing.expectf(t, !ok, "unknown action %d accepted as %v", word, action)
		}
	}

	// Element_Actions: every bit past max(Element_Action) refused.
	for bit in u64(max(Element_Action)) + 1 ..< 64 {
		bad := u64(1) << bit
		_, ok := element_actions_of_word(bad)
		testing.expectf(t, !ok, "unknown action bit %d accepted", bit)
		_, ok = element_actions_of_word(ELEMENT_ACTIONS_VALID_MASK | bad)
		testing.expectf(t, !ok, "valid actions with unknown bit %d accepted", bit)
	}
	_, all_actions_ok := element_actions_of_word(ELEMENT_ACTIONS_VALID_MASK)
	testing.expect(t, all_actions_ok, "all valid actions refused")

	// Element_Detail_Kind: 0 and max+1 and max(u32) refused; 1..=max valid.
	_, zero_detail_ok := element_detail_kind_of_word(0)
	testing.expect(t, !zero_detail_ok, "detail kind 0 must be refused")
	for word in u32(1) ..= u32(max(Element_Detail_Kind)) {
		kind, ok := element_detail_kind_of_word(word)
		testing.expectf(t, ok && u32(kind) == word, "valid detail kind %d refused", word)
	}
	for bad in ([?]u32{u32(max(Element_Detail_Kind)) + 1, 255, 65535, max(u32)}) {
		_, ok := element_detail_kind_of_word(bad)
		testing.expectf(t, !ok, "unknown detail kind %d accepted", bad)
	}

	// Sub-enums: past max and max(u64) refused.
	for bad in ([?]u64{u64(max(Element_Orientation)) + 1, max(u64)}) {
		_, ok := element_orientation_of_word(bad)
		testing.expect(t, !ok, "unknown orientation accepted")
	}
	for bad in ([?]u64{u64(max(Element_Sort)) + 1, max(u64)}) {
		_, ok := element_sort_of_word(bad)
		testing.expect(t, !ok, "unknown sort accepted")
	}
	for bad in ([?]u64{u64(max(Element_Current)) + 1, max(u64)}) {
		_, ok := element_current_of_word(bad)
		testing.expect(t, !ok, "unknown current accepted")
	}
	for bad in ([?]u64{u64(max(Element_Popup)) + 1, max(u64)}) {
		_, ok := element_popup_of_word(bad)
		testing.expect(t, !ok, "unknown popup accepted")
	}
	for bad in ([?]u64{u64(max(Element_Auto_Complete)) + 1, max(u64)}) {
		_, ok := element_auto_complete_of_word(bad)
		testing.expect(t, !ok, "unknown auto_complete accepted")
	}
	for bad in ([?]u64{ELEMENT_RELEVANT_VALID_MASK + 1, 1 << 8, max(u64)}) {
		_, ok := element_relevant_of_word(bad)
		testing.expect(t, !ok, "unknown relevant bit accepted")
	}
}

// element_detail_read refuses non-zero reserved words, unknown kinds, invalid
// UTF-8, out-of-bounds ranges, invalid enum/action words, and invalid relation
// targets (zero or non-zero high 32 bits).
@(test)
element_detail_read_refuses_hostile_records :: proc(t: ^testing.T) {
	valid_bytes := [?]u8{'h', 'e', 'l', 'l', 'o', 0xFF, 0x00}

	// Zeroed detail record (kind == 0) is refused.
	_, r := element_detail_read({}, valid_bytes[:])
	testing.expect_value(t, r, Semantic_Tree_Refusal.Detail_Invalid)

	// Non-zero reserved word is refused.
	bad_reserved := detail_unsigned_record(.Level, 2)
	bad_reserved.reserved = 1
	_, r = element_detail_read(bad_reserved, valid_bytes[:])
	testing.expect_value(t, r, Semantic_Tree_Refusal.Detail_Invalid)

	// Unknown detail kind is refused.
	_, r = element_detail_read({kind = u32(max(Element_Detail_Kind)) + 1}, valid_bytes[:])
	testing.expect_value(t, r, Semantic_Tree_Refusal.Detail_Invalid)

	// Text detail out of bounds, invalid UTF-8, control byte, past limit, or non-zero first with zero count.
	_, r = element_detail_read(detail_range_record(.Description, 0, 100), valid_bytes[:])
	testing.expect_value(t, r, Semantic_Tree_Refusal.Detail_Range_Out_Of_Bounds)
	_, r = element_detail_read(detail_range_record(.Description, 5, 1), valid_bytes[:])
	testing.expect_value(t, r, Semantic_Tree_Refusal.Detail_Invalid)
	_, r = element_detail_read(detail_range_record(.Description, 6, 1), valid_bytes[:])
	testing.expect_value(t, r, Semantic_Tree_Refusal.Detail_Invalid)
	_, r = element_detail_read({kind = u32(Element_Detail_Kind.Description), value_low = 2, value_high = 0}, valid_bytes[:])
	testing.expect_value(t, r, Semantic_Tree_Refusal.Detail_Invalid)
	_, r = element_detail_read(detail_range_record(.Description, 0, ELEMENT_DETAIL_TEXT_LIMIT + 1), valid_bytes[:])
	testing.expect_value(t, r, Semantic_Tree_Refusal.Detail_Invalid)

	// Invalid actions mask and invalid relation words.
	_, r = element_detail_read(detail_unsigned_record(.Actions, u64(1) << 63), valid_bytes[:])
	testing.expect_value(t, r, Semantic_Tree_Refusal.Detail_Invalid)
	_, r = element_detail_read(detail_relation_record(.Controls, 0), valid_bytes[:])
	testing.expect_value(t, r, Semantic_Tree_Refusal.Detail_Invalid)
	bad_rel := detail_relation_record(.Controls, 42)
	bad_rel.value_high = 1
	_, r = element_detail_read(bad_rel, valid_bytes[:])
	testing.expect_value(t, r, Semantic_Tree_Refusal.Detail_Invalid)

	// Valid text detail succeeds.
	detail, ok_r := element_detail_read(detail_range_record(.Description, 0, 5), valid_bytes[:])
	testing.expect_value(t, ok_r, Semantic_Tree_Refusal.None)
	testing.expect_value(t, detail.kind, Element_Detail_Kind.Description)
	testing.expect_value(t, detail.first, u32(0))
	testing.expect_value(t, detail.count, u32(5))
}

// semantic_tree_extract refuses every structural and encoding fault and leaves
// the tree empty on refusal.
@(test)
semantic_tree_extract_refuses_every_fault :: proc(t: ^testing.T) {
	tree := new(Semantic_Tree)
	defer free(tree)
	b := new(Test_Builder)
	defer free(b)

	// 1. Stray Element_Pop.
	b^ = {}
	builder_pop(b)
	refusal, idx := semantic_tree_extract(b.records[:b.record_count], b.bytes[:b.byte_count], tree)
	testing.expect_value(t, refusal, Semantic_Tree_Refusal.Pop_Without_Push)
	testing.expect_value(t, idx, 0)
	testing.expect_value(t, tree.node_count, 0)

	// 2. Unclosed Element_Push.
	b^ = {}
	builder_push(b, 1, .Button, name = "ok")
	refusal, idx = semantic_tree_extract(b.records[:b.record_count], b.bytes[:b.byte_count], tree)
	testing.expect_value(t, refusal, Semantic_Tree_Refusal.Push_Without_Pop)
	testing.expect_value(t, idx, 0)
	testing.expect_value(t, tree.node_count, 0)

	// 3. Interleaved Element_Push and Clip_Push.
	b^ = {}
	builder_push(b, 1, .Group)
	builder_clip_push(b, 0, 0, 50, 50)
	builder_pop(b)
	builder_clip_pop(b)
	refusal, idx = semantic_tree_extract(b.records[:b.record_count], b.bytes[:b.byte_count], tree)
	testing.expect_value(t, refusal, Semantic_Tree_Refusal.Pop_Wrong_Kind)
	testing.expect_value(t, idx, 2)

	// 4. Depth past ELEMENT_DEPTH_LIMIT.
	b^ = {}
	for i in 0 ..= ELEMENT_DEPTH_LIMIT {
		builder_push(b, u32(i + 1), .Group)
	}
	refusal, idx = semantic_tree_extract(b.records[:b.record_count], b.bytes[:b.byte_count], tree)
	testing.expect_value(t, refusal, Semantic_Tree_Refusal.Push_Past_Depth_Limit)
	testing.expect_value(t, idx, ELEMENT_DEPTH_LIMIT)

	// 5. Element word 0 on Element_Push.
	b^ = {}
	builder_push(b, 0, .Button)
	builder_pop(b)
	refusal, idx = semantic_tree_extract(b.records[:b.record_count], b.bytes[:b.byte_count], tree)
	testing.expect_value(t, refusal, Semantic_Tree_Refusal.Element_Word_Zero)
	testing.expect_value(t, idx, 0)

	// 6. Record carrying wrong element word inside an open push.
	b^ = {}
	builder_push(b, 10, .Button, name = "save")
	builder_rect(b, 99)
	builder_pop(b)
	refusal, idx = semantic_tree_extract(b.records[:b.record_count], b.bytes[:b.byte_count], tree)
	testing.expect_value(t, refusal, Semantic_Tree_Refusal.Element_Word_Mismatch)
	testing.expect_value(t, idx, 1)

	// 7. Unknown role word in raw record.
	b^ = {}
	builder_push(b, 10, .Button)
	b.records[0].fields[offset_of(draw_record.Element_Push_Fields, role)] = u8(max(Element_Role)) + 1
	builder_pop(b)
	refusal, idx = semantic_tree_extract(b.records[:b.record_count], b.bytes[:b.byte_count], tree)
	testing.expect_value(t, refusal, Semantic_Tree_Refusal.Record_Invalid)
	testing.expect_value(t, idx, 0)

	// 8. Name range out of bounds.
	b^ = {}
	b.records[0] = draw_record.record_of(draw_record.Draw_Element_Push{role = .Button, name_first = 0, name_count = 10}, 10, 0, 0, draw_record.units_of_pixels(20), draw_record.units_of_pixels(20))
	b.record_count = 1
	builder_pop(b)
	refusal, idx = semantic_tree_extract(b.records[:b.record_count], b.bytes[:0], tree)
	testing.expect_value(t, refusal, Semantic_Tree_Refusal.Name_Range_Out_Of_Bounds)
	testing.expect_value(t, idx, 0)

	// 9. Name with invalid UTF-8 bytes.
	b^ = {}
	b.bytes[0], b.bytes[1] = 0xFF, 0xFE
	b.byte_count = 2
	b.records[0] = draw_record.record_of(draw_record.Draw_Element_Push{role = .Button, name_first = 0, name_count = 2}, 10, 0, 0, draw_record.units_of_pixels(20), draw_record.units_of_pixels(20))
	b.record_count = 1
	builder_pop(b)
	refusal, idx = semantic_tree_extract(b.records[:b.record_count], b.bytes[:b.byte_count], tree)
	testing.expect_value(t, refusal, Semantic_Tree_Refusal.Name_Invalid_Text)
	testing.expect_value(t, idx, 0)

	// 10. Detail range out of bounds.
	b^ = {}
	b.records[0] = draw_record.record_of(draw_record.Draw_Element_Push{role = .Button, detail_first = 0, detail_count = 1}, 10, 0, 0, draw_record.units_of_pixels(20), draw_record.units_of_pixels(20))
	b.record_count = 1
	builder_pop(b)
	refusal, idx = semantic_tree_extract(b.records[:b.record_count], b.bytes[:8], tree)
	testing.expect_value(t, refusal, Semantic_Tree_Refusal.Detail_Range_Out_Of_Bounds)
	testing.expect_value(t, idx, 0)
}

// semantic_tree_audit detects unnamed focusable elements, pressable elements
// without keyboard action, unresolved relations, protected value leaks,
// duplicate element identities, focus count past 64, and refused tables.
@(test)
semantic_tree_audit_catches_every_accessibility_fault :: proc(t: ^testing.T) {
	tree := new(Semantic_Tree)
	defer free(tree)
	b := new(Test_Builder)
	defer free(b)
	findings: [32]Audit_Finding

	// 1. Focusable button with empty name + clickable button with no keyboard action.
	b^ = {}
	d_press := [1]Element_Detail_Record{detail_actions_record({.Press, .Focus})}
	builder_push(b, 1, .Button, states = {.Focusable}, details = d_press[:])
	builder_pop(b)
	// Clickable button with no actions and not focusable.
	builder_push(b, 2, .Button, name = "mouse only")
	builder_pop(b)
	written, total := semantic_tree_audit(b.records[:b.record_count], b.bytes[:b.byte_count], tree, findings[:])
	testing.expect_value(t, total, 2)
	testing.expect_value(t, written, 2)
	testing.expect_value(t, findings[0].problem, Audit_Problem.Focusable_Without_Name)
	testing.expect_value(t, findings[0].element, u32(1))
	testing.expect_value(t, findings[1].problem, Audit_Problem.Pressable_Without_Keyboard)
	testing.expect_value(t, findings[1].element, u32(2))

	// 2. Unresolved relation + Protected field that attempted to publish a value + duplicate identity.
	b^ = {}
	secret_first, secret_count := builder_append_bytes(b, "my-secret")
	bad_details := [3]Element_Detail_Record{
		detail_actions_record({.Focus, .Insert_Text}),
		detail_range_record(.Value_Text, secret_first, secret_count),
		detail_relation_record(.Labelled_By, 9999),
	}
	builder_push(b, 10, .Text_Box, states = {.Focusable, .Protected}, name = "Passphrase", details = bad_details[:])
	builder_text(b, "hidden", 10)
	builder_pop(b)
	// Duplicate element word 10.
	builder_push(b, 10, .Group, name = "dup")
	builder_pop(b)

	written, total = semantic_tree_audit(b.records[:b.record_count], b.bytes[:b.byte_count], tree, findings[:])
	testing.expect_value(t, total, 3)
	// Secret value MUST NOT be exposed in the extracted node even though it leaked in input!
	testing.expect_value(t, semantic_node_value_text(tree, &tree.nodes[0]), "")
	testing.expect(t, .Insert_Text not_in tree.nodes[0].actions, "protected field must strip Insert_Text")
	has_unresolved, has_protected, has_dup := false, false, false
	for f in findings[:written] {
		#partial switch f.problem {
		case .Unresolved_Relation:
			has_unresolved = true
		case .Protected_Field_Has_Value:
			has_protected = true
		case .Duplicate_Element_Identity:
			has_dup = true
		}
	}
	testing.expect(t, has_unresolved && has_protected && has_dup, "audit must report unresolved relation, protected leak, and duplicate identity")

	// 3. Focus count past SEMANTIC_FOCUS_LIMIT (64).
	b^ = {}
	act_focus := [1]Element_Detail_Record{detail_actions_record({.Press, .Focus})}
	for i in 0 ..= SEMANTIC_FOCUS_LIMIT {
		builder_push(b, u32(i + 1), .Button, states = {.Focusable}, name = "btn", details = act_focus[:])
		builder_pop(b)
	}
	written, total = semantic_tree_audit(b.records[:b.record_count], b.bytes[:b.byte_count], tree, findings[:])
	testing.expect_value(t, total, 1)
	testing.expect_value(t, findings[0].problem, Audit_Problem.Focus_Count_Past_Limit)
}

// Extraction computes names from content, resolves Labelled_By, tracks clipped
// visibility from the clip stack, and passes audit with zero findings.
@(test)
semantic_tree_extract_resolves_names_relations_and_clips :: proc(t: ^testing.T) {
	tree := new(Semantic_Tree)
	defer free(tree)
	b := new(Test_Builder)
	defer free(b)

	// Label node (element 1) + Text_Box labelled by element 1 (element 2) + Button with content name (element 3) + clipped offscreen element (element 4).
	builder_push(b, 1, .Heading, left = 0, top = 0, right = 120, bottom = 20)
	builder_text(b, "User", 1)
	builder_text(b, "Name", 1)
	builder_pop(b)

	val_first, val_count := builder_append_bytes(b, "alice")
	tb_details := [4]Element_Detail_Record{
		detail_relation_record(.Labelled_By, 1),
		detail_range_record(.Value_Text, val_first, val_count),
		detail_unsigned_record(.Caret, 5),
		detail_actions_record({.Focus, .Insert_Text, .Press}),
	}
	builder_push(b, 2, .Text_Box, left = 0, top = 24, right = 200, bottom = 48, states = {.Focusable, .Focused}, details = tb_details[:])
	builder_pop(b)

	btn_details := [1]Element_Detail_Record{detail_actions_record({.Press, .Focus})}
	builder_push(b, 3, .Button, left = 0, top = 56, right = 80, bottom = 80, states = {.Focusable}, toggle = .True, details = btn_details[:])
	builder_text(b, "Save", 3)
	builder_pop(b)

	// Clip to [0..50, 0..50], then place element 4 at [100..150, 100..120] -> clipped == true.
	builder_clip_push(b, 0, 0, 50, 50)
	builder_push(b, 4, .Status, left = 100, top = 100, right = 150, bottom = 120)
	builder_text(b, "Ready", 4)
	builder_pop(b)
	builder_clip_pop(b)

	findings: [8]Audit_Finding
	written, total := semantic_tree_audit(b.records[:b.record_count], b.bytes[:b.byte_count], tree, findings[:])
	testing.expect_value(t, total, 0)
	testing.expect_value(t, written, 0)
	testing.expect_value(t, tree.node_count, 4)
	testing.expect_value(t, semantic_node_name(tree, &tree.nodes[0]), "User Name")
	testing.expect_value(t, semantic_node_name(tree, &tree.nodes[1]), "User Name")
	testing.expect_value(t, semantic_node_value_text(tree, &tree.nodes[1]), "alice")
	testing.expect_value(t, tree.nodes[1].caret, u64(5))
	testing.expect_value(t, tree.focused_node, i32(1))
	testing.expect_value(t, semantic_node_name(tree, &tree.nodes[2]), "Save")
	testing.expect_value(t, tree.nodes[2].toggle, Toggle_State.True)
	testing.expect(t, !tree.nodes[2].clipped, "onscreen button must not be clipped")
	testing.expect(t, tree.nodes[3].clipped, "offscreen status must be marked clipped")
	testing.expect_value(t, tree.nodes[3].live, Live_Mode.Polite)
	testing.expect_value(t, semantic_node_live_text(tree, &tree.nodes[3]), "Ready")
}

// semantic_tree_diff emits zero events for equal trees, and emits Focus_Changed,
// Name_Changed, State_Changed, Value_Changed, Live_Announcement, and Tree_Changed
// when snapshots differ.
@(test)
semantic_tree_diff_emits_every_event_kind :: proc(t: ^testing.T) {
	before := new(Semantic_Tree)
	now := new(Semantic_Tree)
	defer free(before)
	defer free(now)
	b := new(Test_Builder)
	defer free(b)

	// Build frame 1.
	val1_f, val1_c := builder_append_bytes(b, "abc")
	tb1 := [2]Element_Detail_Record{detail_range_record(.Value_Text, val1_f, val1_c), detail_actions_record({.Focus, .Insert_Text})}
	act_btn := [1]Element_Detail_Record{detail_actions_record({.Press, .Focus})}
	builder_push(b, 1, .Button, states = {.Focusable, .Focused}, toggle = .False, name = "Play", details = act_btn[:])
	builder_pop(b)
	builder_push(b, 2, .Text_Box, states = {.Focusable}, name = "Filter", details = tb1[:])
	builder_pop(b)
	builder_push(b, 3, .Status)
	builder_text(b, "Idle", 3)
	builder_pop(b)
	builder_push(b, 4, .Generic, name = "Temporary")
	builder_pop(b)
	refusal, _ := semantic_tree_extract(b.records[:b.record_count], b.bytes[:b.byte_count], before)
	testing.expect_value(t, refusal, Semantic_Tree_Refusal.None)

	// Identical snapshot produces zero events.
	events: [32]Semantic_Event
	written, total := semantic_tree_diff(before, before, events[:])
	testing.expect_value(t, written, 0)
	testing.expect_value(t, total, 0)

	// Build frame 2: button renamed & toggled & unfocused, textbox focused & value changed, status live text changed, element 4 removed, element 5 added (Alert).
	b^ = {}
	val2_f, val2_c := builder_append_bytes(b, "abcd")
	tb2 := [2]Element_Detail_Record{detail_range_record(.Value_Text, val2_f, val2_c), detail_actions_record({.Focus, .Insert_Text})}
	builder_push(b, 1, .Button, states = {.Focusable}, toggle = .True, name = "Pause", details = act_btn[:])
	builder_pop(b)
	builder_push(b, 2, .Text_Box, states = {.Focusable, .Focused}, name = "Filter", details = tb2[:])
	builder_pop(b)
	builder_push(b, 3, .Status)
	builder_text(b, "Running", 3)
	builder_pop(b)
	builder_push(b, 5, .Alert)
	builder_text(b, "Disk full", 5)
	builder_pop(b)
	refusal, _ = semantic_tree_extract(b.records[:b.record_count], b.bytes[:b.byte_count], now)
	testing.expect_value(t, refusal, Semantic_Tree_Refusal.None)

	written, total = semantic_tree_diff(before, now, events[:])
	testing.expect(t, written == total && total > 0, "diff must report events")

	seen: [Semantic_Event_Kind]int
	saw_focus_1_to_2 := false
	saw_polite_status := false
	saw_assertive_alert := false
	for ev in events[:written] {
		seen[ev.kind] += 1
		if ev.kind == .Focus_Changed && ev.previous == 1 && ev.element == 2 {
			saw_focus_1_to_2 = true
		}
		if ev.kind == .Live_Announcement && ev.element == 3 && ev.live == .Polite {
			saw_polite_status = true
		}
		if ev.kind == .Live_Announcement && ev.element == 5 && ev.live == .Assertive {
			saw_assertive_alert = true
		}
	}
	testing.expect(t, seen[.Focus_Changed] == 1 && saw_focus_1_to_2, "expected Focus_Changed from 1 to 2")
	testing.expect(t, seen[.Name_Changed] == 1, "expected Name_Changed on button 1")
	testing.expect(t, seen[.State_Changed] == 2, "expected State_Changed on button 1 and textbox 2")
	testing.expect(t, seen[.Value_Changed] == 1, "expected Value_Changed on textbox 2")
	testing.expect(t, seen[.Live_Announcement] == 2 && saw_polite_status && saw_assertive_alert, "expected Polite status and Assertive alert announcements")
	testing.expect(t, seen[.Tree_Changed] == 2, "expected Tree_Changed for removed 4 and added 5")

	// Small output slice still reports full total without silent drop.
	small: [2]Semantic_Event
	small_written, small_total := semantic_tree_diff(before, now, small[:])
	testing.expect_value(t, small_written, 2)
	testing.expect_value(t, small_total, total)
}

// Capacity bounds, signed range values, Described_By resolution, Protected diff
// secrecy, and role table completeness.
@(test)
semantic_tree_edges_and_protected_diff_secrecy :: proc(t: ^testing.T) {
	// Every concrete WAI-ARIA role has a non-empty unique name.
	for role in Element_Role {
		name := ELEMENT_ROLE_NAMES[role]
		testing.expectf(t, len(name) > 0, "role %v has empty WAI-ARIA name", role)
		for other in Element_Role {
			if other != role {
				testing.expectf(t, ELEMENT_ROLE_NAMES[other] != name, "duplicate role name %q", name)
			}
		}
	}

	tree := new(Semantic_Tree)
	defer free(tree)
	b := new(Test_Builder)
	defer free(b)

	// Signed negative range values + Described_By resolution.
	builder_push(b, 1, .Note, name = "Temperature range")
	builder_pop(b)
	meter_details := [4]Element_Detail_Record{
		detail_integer_record(.Value_Minimum, -40),
		detail_integer_record(.Value_Now, -12),
		detail_integer_record(.Value_Maximum, 100),
		detail_relation_record(.Described_By, 1),
	}
	builder_push(b, 2, .Meter, name = "Thermometer", details = meter_details[:])
	builder_pop(b)
	refusal, _ := semantic_tree_extract(b.records[:b.record_count], b.bytes[:b.byte_count], tree)
	testing.expect_value(t, refusal, Semantic_Tree_Refusal.None)
	testing.expect_value(t, tree.nodes[1].value_minimum, i64(-40))
	testing.expect_value(t, tree.nodes[1].value_now, i64(-12))
	testing.expect_value(t, tree.nodes[1].value_maximum, i64(100))
	testing.expect_value(t, semantic_node_description(tree, &tree.nodes[1]), "Temperature range")

	// Protected field never emits Value_Changed or Live_Announcement across frames.
	before := new(Semantic_Tree)
	now := new(Semantic_Tree)
	defer free(before)
	defer free(now)
	b^ = {}
	act_prot := [1]Element_Detail_Record{detail_actions_record({.Focus, .Press})}
	builder_push(b, 50, .Text_Box, states = {.Focusable, .Protected}, live = .Polite, name = "Passphrase", details = act_prot[:])
	builder_text(b, "a", 50)
	builder_pop(b)
	refusal, _ = semantic_tree_extract(b.records[:b.record_count], b.bytes[:b.byte_count], before)
	testing.expect_value(t, refusal, Semantic_Tree_Refusal.None)

	b^ = {}
	builder_push(b, 50, .Text_Box, states = {.Focusable, .Protected}, live = .Polite, name = "Passphrase", details = act_prot[:])
	builder_text(b, "ab", 50)
	builder_pop(b)
	refusal, _ = semantic_tree_extract(b.records[:b.record_count], b.bytes[:b.byte_count], now)
	testing.expect_value(t, refusal, Semantic_Tree_Refusal.None)
	events: [8]Semantic_Event
	w, tot := semantic_tree_diff(before, now, events[:])
	testing.expect_value(t, w, 0)
	testing.expect_value(t, tot, 0)

	// Node capacity exceeded: SEMANTIC_TREE_NODE_CAPACITY + 1 pushes must be refused cleanly.
	many := make([]draw_record.Draw_Record, 2 * (SEMANTIC_TREE_NODE_CAPACITY + 1))
	defer delete(many)
	for i in 0 ..= SEMANTIC_TREE_NODE_CAPACITY {
		many[2 * i] = draw_record.record_of(draw_record.Draw_Element_Push{role = .Group}, u32(i + 1), 0, 0, draw_record.units_of_pixels(10), draw_record.units_of_pixels(10))
		many[2 * i + 1] = draw_record.record_of(draw_record.Draw_Element_Pop{}, 0, 0, 0, 0, 0)
	}
	cap_refusal, idx := semantic_tree_extract(many, nil, tree)
	testing.expect_value(t, cap_refusal, Semantic_Tree_Refusal.Node_Capacity_Exceeded)
	testing.expect_value(t, idx, 2 * SEMANTIC_TREE_NODE_CAPACITY)
	testing.expect_value(t, tree.node_count, 0)
}
