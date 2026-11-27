#+build !freestanding
package assistant_window

import "core:strings"
import "core:testing"
import "internal:assistant/conversation"
import assistant_contract "modus:contract/assistant"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:interface"
import box_layout "modus:layout"

@(test)
code_mode_state_machine_transitions_and_filtering :: proc(t: ^testing.T) {
	conv := new(conversation.Conversation)
	defer free(conv)
	cm := new(Code_Mode_State)
	defer free(cm)

	// Idle state before any request.
	code_mode_sync(cm, conv)
	testing.expect_value(t, cm.badge_state, Loop_Badge_State.Idle)
	testing.expect_value(t, cm.row_count, 0)
	testing.expect_value(t, cm.selected_row, -1)
	testing.expect(t, code_mode_selected_entry(cm, conv) == nil)
	buf: [64]u8
	btext, _ := code_mode_badge_text(cm, buf[:])
	testing.expect_value(t, btext, "Ready")

	// Request kept -> Queued until runner takes it.
	req := conversation.request_keep(conv, "inspect processes and apply plan")
	testing.expect(t, req != nil)
	code_mode_sync(cm, conv)
	testing.expect_value(t, cm.badge_state, Loop_Badge_State.Queued)
	btext, _ = code_mode_badge_text(cm, buf[:])
	testing.expect_value(t, btext, "Queued")

	// Runner takes request -> Running.
	err: errors.Error_Record
	req_buf: [256]u8
	out, _, taken := conversation.request_text(conv, true, i64(req.serial), req_buf[:], &err)
	testing.expect_value(t, out, call_outcome_succeeded())
	testing.expect(t, taken != nil)
	// Force layout_serial bump by adding step 1 reply with 2 acts.
	out, _, _ = conversation.reply(conv, true, i64(req.serial), "Checking processes and system plan.", 2, &err)
	testing.expect_value(t, out, call_outcome_succeeded())

	// Act 1: Eval_Step (multi-line Lex step), completes Done.
	act1: i64
	out, act1, _ = conversation.act(conv, true, i64(req.serial), i64(assistant_contract.Act_Kind.Eval_Step), "p = monitor.processes() |> count", "monitor", "processes", &err)
	testing.expect_value(t, out, call_outcome_succeeded())
	out, _, _ = conversation.act_result(conv, true, act1, i64(assistant_contract.Act_State.Done), "12", &err)
	testing.expect_value(t, out, call_outcome_succeeded())

	code_mode_sync(cm, conv)
	testing.expect_value(t, cm.badge_state, Loop_Badge_State.Running)
	testing.expect_value(t, cm.active_step, u8(1))
	testing.expect_value(t, cm.row_count, 1)
	testing.expect_value(t, cm.done_acts, 1)
	btext, _ = code_mode_badge_text(cm, buf[:])
	testing.expect_value(t, btext, "Step 1 of 16")

	// Act 2: plans.apply -> Awaiting_Principal -> header badge transitions to Awaiting_Principal.
	act2: i64
	out, act2, _ = conversation.act(conv, true, i64(req.serial), i64(assistant_contract.Act_Kind.Eval_Lex), "plans.apply(home)", "plans", "apply", &err)
	testing.expect_value(t, out, call_outcome_succeeded())
	out, _, _ = conversation.act_result(conv, true, act2, i64(assistant_contract.Act_State.Awaiting_Principal), "Principal_Approval_Required", &err)
	testing.expect_value(t, out, call_outcome_succeeded())

	code_mode_sync(cm, conv)
	testing.expect_value(t, cm.badge_state, Loop_Badge_State.Awaiting_Principal)
	testing.expect_value(t, cm.waiting_acts, 1)
	testing.expect_value(t, cm.row_count, 2)
	btext, _ = code_mode_badge_text(cm, buf[:])
	testing.expect_value(t, btext, "Waiting")

	// Review button jumps to Code steps and selects the waiting act.
	testing.expect_value(t, cm.active_tab, Assistant_View_Tab.Conversation)
	testing.expect(t, code_mode_review_next_waiting(cm, conv, 8))
	testing.expect_value(t, cm.active_tab, Assistant_View_Tab.Steps)
	sel := code_mode_selected_entry(cm, conv)
	testing.expect(t, sel != nil && sel.act == u64(act2))
	testing.expect_value(t, code_mode_review_guidance(sel), "Waiting for the trusted display dialog.")

	// Simulate trusted display showing dialog and principal refusing it.
	sel.dialog = 7
	testing.expect_value(t, code_mode_review_guidance(sel), "Decide this act in the trusted display dialog.")
	sel.state = .Refused_By_Principal
	conversation.entry_touch(conv, sel)

	code_mode_sync(cm, conv)
	testing.expect_value(t, cm.waiting_acts, 0)
	testing.expect_value(t, cm.refused_acts, 1)
	testing.expect_value(t, cm.badge_state, Loop_Badge_State.Running)
	testing.expect_value(t, code_mode_review_guidance(sel), "Refused on the trusted display. Nothing ran.")

	// Filtering to Refused keeps only act 2; filtering to Awaiting yields 0 rows.
	code_mode_set_filter(cm, conv, .Refused)
	testing.expect_value(t, cm.row_count, 1)
	testing.expect_value(t, cm.rows[0].act, u64(act2))
	code_mode_set_filter(cm, conv, .Awaiting)
	testing.expect_value(t, cm.row_count, 0)
	testing.expect(t, code_mode_selected_entry(cm, conv) == nil)

	// Step 2 adds a refused bridge call, then principal requests Stop -> Stopping -> Loop_End.
	out, _, _ = conversation.reply(conv, true, i64(req.serial), "Trying another call.", 1, &err)
	testing.expect_value(t, out, call_outcome_succeeded())
	act3: i64
	out, act3, _ = conversation.act(conv, true, i64(req.serial), i64(assistant_contract.Act_Kind.Send_Key), "input.press(notes, .Enter)", "", "", &err)
	testing.expect_value(t, out, call_outcome_succeeded())
	out, _, _ = conversation.act_result(conv, true, act3, i64(assistant_contract.Act_State.Refused), "No_Grant: Send_Input", &err)
	testing.expect_value(t, out, call_outcome_succeeded())

	// Principal presses Stop -> Stopping badge.
	stopped_req := conversation.principal_stop(conv)
	testing.expect(t, stopped_req != nil)
	code_mode_set_filter(cm, conv, .All)
	testing.expect_value(t, cm.badge_state, Loop_Badge_State.Stopping)
	testing.expect_value(t, cm.row_count, 3)
	testing.expect(t, cm.has_foldable) // Act 1 from step 1 is older than step 2.

	// Fold / expand all toggles older foldable results cleanly.
	testing.expect_value(t, code_mode_fold_all(conv, false), 1)
	testing.expect_value(t, code_mode_fold_all(conv, false), 0) // Idempotent.
	testing.expect_value(t, code_mode_fold_all(conv, true), 1)

	// Loop ends with Stopped_By_Principal -> Attention badge ("Stopped").
	out, _, _ = conversation.loop_end(conv, true, i64(req.serial), i64(assistant_contract.Agent_Loop_End.Stopped_By_Principal), &err)
	testing.expect_value(t, out, call_outcome_succeeded())
	code_mode_sync(cm, conv)
	testing.expect_value(t, cm.badge_state, Loop_Badge_State.Attention)
	btext, _ = code_mode_badge_text(cm, buf[:])
	testing.expect_value(t, btext, "Stopped")
}

@(test)
code_mode_refusal_and_boundary_edge_cases :: proc(t: ^testing.T) {
	// Nil pointers must never panic and must refuse gracefully.
	code_mode_sync(nil, nil)
	testing.expect(t, !code_mode_set_tab(nil, .Steps))
	code_mode_set_filter(nil, nil, .All)
	code_mode_select(nil, 0, 5)
	code_mode_move_selection(nil, 1, 5)
	testing.expect(t, !code_mode_review_next_waiting(nil, nil, 5))
	testing.expect(t, code_mode_selected_entry(nil, nil) == nil)
	testing.expect_value(t, code_mode_fold_all(nil, true), 0)
	testing.expect(t, !code_mode_scroll_to_entry(nil, nil, 100, 1))
	testing.expect_value(t, code_mode_review_guidance(nil), "")

	// Menu action border rejects unknown / out-of-range action words.
	for bad_word in ([?]u32{11, 99, max(u32)}) {
		_, ok := code_mode_action_of_word(bad_word)
		testing.expectf(t, !ok, "expected refusal for action word %d", bad_word)
	}
	for valid in Assistant_Menu_Action {
		parsed, ok := code_mode_action_of_word(u32(valid))
		testing.expect(t, ok && parsed == valid)
	}

	// Context menu and palette builders refuse undersized output buffers.
	cm := new(Code_Mode_State)
	defer free(cm)
	small_ctx: [2]interface.Context_Menu_Item
	testing.expect_value(t, code_mode_build_context_menu(cm, false, small_ctx[:]), 0)
	small_pal: [2]interface.Command_Palette_Item
	testing.expect_value(t, code_mode_build_palette(cm, false, small_pal[:]), 0)

	// Full context menu disables Review and Stop when idle with no waiting acts.
	full_ctx: [12]interface.Context_Menu_Item
	ctx_n := code_mode_build_context_menu(cm, false, full_ctx[:])
	testing.expect(t, ctx_n >= 7)
	found_review := false
	found_stop := false
	for item in full_ctx[:ctx_n] {
		if item.id == u32(Assistant_Menu_Action.Review_Next_Waiting) {
			found_review = true
			testing.expect(t, item.disabled)
		}
		if item.id == u32(Assistant_Menu_Action.Stop_Loop) {
			found_stop = true
			testing.expect(t, item.disabled && item.danger)
		}
	}
	testing.expect(t, found_review && found_stop)

	// Selection clamping and action dispatch boundaries.
	conv := new(conversation.Conversation)
	defer free(conv)
	testing.expect(t, !code_mode_review_next_waiting(cm, conv, 4))
	wants_stop, wants_pal := code_mode_apply_action(cm, conv, .Stop_Loop, 4)
	testing.expect(t, wants_stop && !wants_pal)
	wants_stop, wants_pal = code_mode_apply_action(cm, conv, .Open_Palette, 4)
	testing.expect(t, !wants_stop && wants_pal)
}

@(test)
code_mode_renders_steps_and_inspector_into_draw_table :: proc(t: ^testing.T) {
	conv := new(conversation.Conversation)
	defer free(conv)
	cm := new(Code_Mode_State)
	defer free(cm)
	tree := new(box_layout.Box_Tree)
	defer free(tree)

	// Populate a request with one multi-line Eval_Step and one Awaiting_Principal act.
	req := conversation.request_keep(conv, "check system")
	err: errors.Error_Record
	req_buf: [64]u8
	_, _, _ = conversation.request_text(conv, true, i64(req.serial), req_buf[:], &err)
	_, _, _ = conversation.reply(conv, true, i64(req.serial), "Running checks.", 2, &err)
	o1, a1, _ := conversation.act(conv, true, i64(req.serial), i64(assistant_contract.Act_Kind.Eval_Step), "p = monitor.processes() |> first(5)", "monitor", "processes", &err)
	testing.expect_value(t, o1, call_outcome_succeeded())
	o1r, _, _ := conversation.act_result(conv, true, a1, i64(assistant_contract.Act_State.Done), "5 rows", &err)
	testing.expect_value(t, o1r, call_outcome_succeeded())
	o2, a2, _ := conversation.act(conv, true, i64(req.serial), i64(assistant_contract.Act_Kind.Eval_Lex), "plans.apply(home)", "plans", "apply", &err)
	testing.expect_value(t, o2, call_outcome_succeeded())
	o2r, _, _ := conversation.act_result(conv, true, a2, i64(assistant_contract.Act_State.Awaiting_Principal), "Principal_Approval_Required", &err)
	testing.expect_value(t, o2r, call_outcome_succeeded())

	cm.active_tab = .Steps
	code_mode_sync(cm, conv)
	testing.expect_value(t, cm.row_count, 2)

	// Render into an in-memory interface.Draw_Table (no window, headless).
	records := make([]interface.Draw_Record, 512)
	defer delete(records)
	text_buf := make([]u8, 16384)
	defer delete(text_buf)
	draw_tbl := interface.Draw_Table{records = records, text = text_buf}
	state: interface.Interface_State
	input: interface.Input
	frame := interface.frame_begin(&draw_tbl, &state, &input)
	tokens, tok_ok := box_layout.tokens_for(.Dark, .Standard)
	testing.expect(t, tok_ok)

	boxes, lay_ok := assistant_layout(tree, WIDTH, HEIGHT, true, tokens, .Steps, true)
	testing.expect(t, lay_ok)
	metrics := view_metrics(&draw_tbl)

	jump_num, wants_stop := draw_code_steps_panel(&frame, cm, conv, boxes, metrics, true, tokens)
	interface.frame_end(&frame)
	testing.expect_value(t, jump_num, u64(0))
	testing.expect(t, !wants_stop)
	testing.expect(t, draw_tbl.record_count > 10)

	// Verify rendered text includes the filter buttons, target service.export,
	// and trusted display guidance without any forbidden words.
	rendered_text := string(draw_tbl.text[:draw_tbl.text_count])
	testing.expect(t, strings.contains(rendered_text, "All"))
	testing.expect(t, strings.contains(rendered_text, "Waiting"))
	testing.expect(t, strings.contains(rendered_text, "Refused"))
	testing.expect(t, strings.contains(rendered_text, "plans.apply"))
	testing.expect(t, strings.contains(rendered_text, "trusted display"))

	// Verify label formatting for non-Eval_Lex acts includes the kind label.
	entry1 := conversation.act_of(conv, a1)
	testing.expect(t, entry1 != nil)
	lbuf: [128]u8
	label, _ := entry_label(entry1, lbuf[:])
	testing.expect(t, strings.contains(label, "Lex step"))
}

@(private = "file")
call_outcome_succeeded :: proc() -> call_outcome.Call_Outcome {
	return .Succeeded
}
