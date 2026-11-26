#+build !freestanding
#+build !modus
package accessibility

import "core:testing"
import "modus:contract/draw_record"

// semantic_audit_issue_of_word accepts every defined issue member and refuses
// every byte outside the closed enum.
@(test)
semantic_audit_issue_border_refuses_unknown_words :: proc(t: ^testing.T) {
	for word in 0 ..= 255 {
		issue, ok := semantic_audit_issue_of_word(u8(word))
		if word <= int(max(Semantic_Audit_Issue)) {
			testing.expectf(t, ok && u8(issue) == u8(word), "valid issue %d refused", word)
		} else {
			testing.expectf(t, !ok, "unknown issue %d accepted as %v", word, issue)
		}
	}
}

// semantic_tree_audit(table, text_bytes) catches unbalanced element push/pop
// stacks, interleaved clip/element pops, and depth past ELEMENT_DEPTH_LIMIT.
@(test)
semantic_tree_audit_table_refuses_unbalanced_stacks :: proc(t: ^testing.T) {
	b := new(Test_Builder)
	defer free(b)

	// 1. Stray Element_Pop with empty stack.
	b^ = {}
	builder_pop(b)
	report := semantic_tree_audit(b.records[:b.record_count], b.bytes[:b.byte_count])
	testing.expect(t, !semantic_audit_report_ok(&report), "stray pop must fail audit")
	testing.expect(t, semantic_audit_report_has_issue(&report, .Unbalanced_Element_Stack), "expected Unbalanced_Element_Stack")
	testing.expect_value(t, report.violations[0].record_index, i32(0))

	// 2. Unclosed Element_Push at end of table.
	b^ = {}
	act_press := [1]Element_Detail_Record{detail_actions_record({.Press, .Focus})}
	builder_push(b, 1, .Button, states = {.Focusable}, name = "Save", details = act_press[:])
	report = semantic_tree_audit(b.records[:b.record_count], b.bytes[:b.byte_count])
	testing.expect(t, semantic_audit_report_has_issue(&report, .Unbalanced_Element_Stack), "unclosed push must fail")

	// 3. Interleaved Element_Push -> Clip_Push -> Element_Pop -> Clip_Pop.
	b^ = {}
	builder_push(b, 1, .Group, name = "Card")
	builder_clip_push(b, 0, 0, 100, 100)
	builder_pop(b)
	builder_clip_pop(b)
	report = semantic_tree_audit(b.records[:b.record_count], b.bytes[:b.byte_count])
	testing.expect(t, semantic_audit_report_has_issue(&report, .Unbalanced_Element_Stack), "interleaved clip/element pop must fail")

	// 4. Nesting depth past ELEMENT_DEPTH_LIMIT.
	b^ = {}
	for i in 0 ..= ELEMENT_DEPTH_LIMIT {
		builder_push(b, u32(i + 1), .Group, name = "Nested")
	}
	for _ in 0 ..= ELEMENT_DEPTH_LIMIT {
		builder_pop(b)
	}
	report = semantic_tree_audit(b.records[:b.record_count], b.bytes[:b.byte_count])
	testing.expect(t, semantic_audit_report_has_issue(&report, .Unbalanced_Element_Stack), "depth past bound must fail")
}

// semantic_tree_audit(table, text_bytes) refuses focusable elements with empty
// or whitespace-only names, pressable buttons without keyboard activation,
// duplicate focused elements, invalid role words, and unknown state bits.
@(test)
semantic_tree_audit_table_catches_all_semantic_violations :: proc(t: ^testing.T) {
	b := new(Test_Builder)
	defer free(b)
	act_press := [1]Element_Detail_Record{detail_actions_record({.Press, .Focus})}

	// 1. Focusable element with empty name.
	b^ = {}
	builder_push(b, 1, .Button, states = {.Focusable}, details = act_press[:])
	builder_pop(b)
	report := semantic_tree_audit(b.records[:b.record_count], b.bytes[:b.byte_count])
	testing.expect(t, semantic_audit_report_has_issue(&report, .Missing_Focusable_Name), "empty focusable name must fail")

	// 2. Focusable element with ASCII/UTF-8 whitespace-only name.
	b^ = {}
	builder_push(b, 2, .Button, states = {.Focusable}, name = "   ", details = act_press[:])
	builder_pop(b)
	report = semantic_tree_audit(b.records[:b.record_count], b.bytes[:b.byte_count])
	testing.expect(t, semantic_audit_report_has_issue(&report, .Missing_Focusable_Name), "whitespace-only focusable name must fail")

	// 3. Focusable element with whitespace-only content text.
	b^ = {}
	builder_push(b, 3, .Button, states = {.Focusable}, details = act_press[:])
	builder_text(b, "   ", 3)
	builder_pop(b)
	report = semantic_tree_audit(b.records[:b.record_count], b.bytes[:b.byte_count])
	testing.expect(t, semantic_audit_report_has_issue(&report, .Missing_Focusable_Name), "whitespace-only content name must fail")

	// 4. Pressable button with no keyboard action or focusability.
	b^ = {}
	builder_push(b, 4, .Button, name = "Mouse Only")
	builder_pop(b)
	report = semantic_tree_audit(b.records[:b.record_count], b.bytes[:b.byte_count])
	testing.expect(t, semantic_audit_report_has_issue(&report, .Missing_Keyboard_Action), "pressable button without keyboard activation must fail")

	// 5. Pressable button that is focusable but declared zero actions.
	b^ = {}
	builder_push(b, 5, .Button, states = {.Focusable}, name = "No Actions")
	builder_pop(b)
	report = semantic_tree_audit(b.records[:b.record_count], b.bytes[:b.byte_count])
	testing.expect(t, semantic_audit_report_has_issue(&report, .Missing_Keyboard_Action), "focusable button with no declared action must fail")

	// 6. Multiple focused elements in the same draw table.
	b^ = {}
	builder_push(b, 6, .Button, states = {.Focusable, .Focused}, name = "First", details = act_press[:])
	builder_pop(b)
	builder_push(b, 7, .Button, states = {.Focusable, .Focused}, name = "Second", details = act_press[:])
	builder_pop(b)
	report = semantic_tree_audit(b.records[:b.record_count], b.bytes[:b.byte_count])
	testing.expect_value(t, report.focused_count, 2)
	testing.expect(t, semantic_audit_report_has_issue(&report, .Duplicate_Focused_Element), "duplicate focused elements must fail")

	// 7. Invalid role word and invalid state bits directly on raw Element_Push bytes.
	b^ = {}
	builder_push(b, 8, .Button, states = {.Focusable}, name = "Corrupt", details = act_press[:])
	b.records[0].fields[offset_of(draw_record.Element_Push_Fields, role)] = u8(max(Element_Role)) + 1
	bad_states := u32(1) << 31
	states_off := offset_of(draw_record.Element_Push_Fields, states)
	b.records[0].fields[states_off + 0] = u8(bad_states)
	b.records[0].fields[states_off + 1] = u8(bad_states >> 8)
	b.records[0].fields[states_off + 2] = u8(bad_states >> 16)
	b.records[0].fields[states_off + 3] = u8(bad_states >> 24)
	builder_pop(b)
	report = semantic_tree_audit(b.records[:b.record_count], b.bytes[:b.byte_count])
	testing.expect(t, semantic_audit_report_has_issue(&report, .Invalid_Role_Word), "unknown role word must be reported")
	testing.expect(t, semantic_audit_report_has_issue(&report, .Invalid_State_Bits), "unknown state bits must be reported")
}

// Valid draw table passes semantic_tree_audit(table, text_bytes) cleanly and
// supports exact semantic_query_element lookups including pressed button checks
// ("the button spleen is pressed"), while malformed tables never match.
@(test)
semantic_query_element_locates_widgets_and_refuses_corrupt_tables :: proc(t: ^testing.T) {
	b := new(Test_Builder)
	defer free(b)

	act_btn := [1]Element_Detail_Record{detail_actions_record({.Press, .Focus})}
	builder_push(b, 10, .Toolbar, left = 0, top = 0, right = 400, bottom = 40, name = "Font selector")
	builder_push(b, 11, .Button, left = 8, top = 8, right = 120, bottom = 32, states = {.Focusable}, toggle = .False, details = act_btn[:])
	builder_text(b, "vector", 11)
	builder_pop(b)
	builder_push(b, 12, .Button, left = 128, top = 8, right = 240, bottom = 32, states = {.Focusable, .Focused}, toggle = .True, details = act_btn[:])
	builder_text(b, "spleen", 12)
	builder_pop(b)
	builder_pop(b)

	// Audit passes with zero violations.
	report := semantic_tree_audit(b.records[:b.record_count], b.bytes[:b.byte_count])
	testing.expect(t, semantic_audit_report_ok(&report), "valid toolbar must pass audit")
	testing.expect_value(t, report.element_count, 3)
	testing.expect_value(t, report.focused_count, 1)

	// Exact query: "the button spleen is focused and pressed".
	match, found := semantic_query_element(b.records[:b.record_count], b.bytes[:b.byte_count], .Button, "spleen", {.Focusable, .Focused})
	testing.expect(t, found, "expected to find button spleen")
	testing.expect_value(t, match.element, u32(12))
	testing.expect_value(t, match.toggle, Toggle_State.True)
	testing.expect_value(t, semantic_query_match_name(&match), "spleen")
	testing.expect_value(t, match.box.left, i32(128))
	testing.expect_value(t, match.box.right, i32(240))

	// Query with required_toggle = .True matches spleen and refuses vector.
	_, pressed_ok := semantic_query_element(b.records[:b.record_count], b.bytes[:b.byte_count], .Button, "spleen", {.Focusable}, .True)
	testing.expect(t, pressed_ok, "spleen button must match Toggle_State.True")
	_, vector_pressed := semantic_query_element(b.records[:b.record_count], b.bytes[:b.byte_count], .Button, "vector", {.Focusable}, .True)
	testing.expect(t, !vector_pressed, "unpressed vector button must not match Toggle_State.True")

	// Wrong role, wrong name, or missing required state do not match.
	_, wrong_role := semantic_query_element(b.records[:b.record_count], b.bytes[:b.byte_count], .Checkbox, "spleen", {.Focusable})
	testing.expect(t, !wrong_role, "wrong role must not match")
	_, wrong_name := semantic_query_element(b.records[:b.record_count], b.bytes[:b.byte_count], .Button, "spleen ", {.Focusable})
	testing.expect(t, !wrong_name, "non-exact name must not match")
	_, missing_state := semantic_query_element(b.records[:b.record_count], b.bytes[:b.byte_count], .Button, "vector", {.Focused})
	testing.expect(t, !missing_state, "missing required state must not match")

	// Corrupting the table (unclosed push) causes semantic_query_element to refuse completely.
	_, corrupt_match := semantic_query_element(b.records[:b.record_count - 1], b.bytes[:b.byte_count], .Button, "spleen", {.Focusable})
	testing.expect(t, !corrupt_match, "malformed table must never return a query match")

	// Invalid enum words passed to semantic_query_element are refused cleanly.
	_, bad_role := semantic_query_element(b.records[:b.record_count], b.bytes[:b.byte_count], Element_Role(255), "spleen", {})
	testing.expect(t, !bad_role, "unknown role query must be refused")
	_, bad_toggle := semantic_query_element(b.records[:b.record_count], b.bytes[:b.byte_count], .Button, "spleen", {}, Toggle_State(99))
	testing.expect(t, !bad_toggle, "unknown toggle query must be refused")
}
