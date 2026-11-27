// The assistant: a window where the principal asks an agent for help, and
// reads the conversation: the replies of the agent, each act that it
// proposes, and the result of each act (src/md/features/assistant.md and
// src/md/features/agent_code_mode.md).
//
// **What it is for.** The agent runs on the host: `modustool assistant`
// reads each request through remote, asks a language model, runs each act
// of its reply through the host agent bridge, and gives the outcome back.
// An act that the bridge stops for the principal shows the act dialog of
// the trusted display; the principal decides it there, never the agent.
//
// **Start**: the start menu, or `start("assistant")` in the console. Type a
// request, then Enter.
//
// **Grants**, as the root service gives them:
//
// - **Serve**: its exports, for the agent runner through remote.
// - **Connect** to the role Display, with the boot image: the act dialog.
//   The term **asks_acts** lets it ask the trusted display for an act
//   dialog, and for nothing else that serves the principal: it acts for
//   nobody.
package assistant_window

import "internal:assistant/conversation"
import "internal:assistant/conversation_view"
import assistant_contract "modus:contract/assistant"
import "modus:contract/errors"
import "modus:contract/module"
import "modus:contract/reference_screen"
import "modus:contract/scale_factor"
import "modus:display"
import "modus:graphics"
import "modus:interface"
import box_layout "modus:layout"
import "modus:system"

// Room for a table of the processes: about 90 cells of the font of the
// cells, and 24 lines.
WIDTH :: 760
HEIGHT :: 560
// Two threads run the interface loop and the store worker; the tool counts
// the module, its fixed tables, its stacks and its window at the largest scale.
MODULE_BUDGET :: system.Stated_Budget{threads = 2, window_width = WIDTH, window_height = HEIGHT}

// The window at the largest scale, cut to the reference screen, two
// pictures, as the tool counts it: the budget stays under the largest
// budget of a module.
WINDOW_SCREEN_WIDTH :: min((u64(WIDTH) * u64(scale_factor.LARGEST) + scale_factor.EIGHTHS_OF_ONE / 2) / scale_factor.EIGHTHS_OF_ONE, u64(reference_screen.WIDTH))
WINDOW_SCREEN_HEIGHT :: min((u64(HEIGHT) * u64(scale_factor.LARGEST) + scale_factor.EIGHTHS_OF_ONE / 2) / scale_factor.EIGHTHS_OF_ONE, u64(reference_screen.HEIGHT))
WINDOW_PAGES :: (2 * WINDOW_SCREEN_WIDTH * WINDOW_SCREEN_HEIGHT * 4 + system.PAGE_SIZE - 1) / system.PAGE_SIZE
STATE_BYTES :: size_of(talk) + size_of(view_layouts) + size_of(view_places) + size_of(view_scroll) + size_of(result_slots) + size_of(layout_lines) + size_of(result_scratch) + size_of(window_memory) + size_of(box_tree) + size_of(typed) + size_of(typed_count) + size_of(display_port) + size_of(store_state) + size_of(code_mode) + size_of(assistant_ctx_menu) + size_of(assistant_palette)
STATE_PAGES :: (STATE_BYTES + system.PAGE_SIZE - 1) / system.PAGE_SIZE
#assert(STATE_PAGES + WINDOW_PAGES <= module.LARGEST_BUDGET_LEAST_PAGES)

// Plan value: outer margin and bottom input/stop bar geometry on an 8/4 px grid.
MARGIN :: 12
INPUT_HEIGHT :: 28
STOP_WIDTH :: 80
// Plan value: time between two reads of the decision of the principal while an
// act waits for it: shorter than a person reads a dialog.
DECISION_POLL_MILLISECONDS :: 100

// The records and the text of one frame, sized for the worst frame: a
// window of results, each line a record for each run of one color
// (result_table.odin).
window_memory: interface.Window_Memory(WINDOW_RECORDS, WINDOW_TEXT_BYTES)
// The layout tree of each frame: lives in module state, never on the stack.
box_tree: box_layout.Box_Tree

// Live code-mode step inspector, right-click menu, and command palette state.
code_mode: Code_Mode_State
assistant_ctx_menu: interface.Context_Menu_State
assistant_palette: interface.Command_Palette_State

// The text that the principal types: one request.
typed: [assistant_contract.REQUEST_TEXT_BYTES]u8
typed_count: int

INPUT_IDENTITY :: "request"
STOP_IDENTITY :: "stop"
TABS_IDENTITY :: "view tabs"
REVIEW_IDENTITY :: "review waiting"
STEPS_LIST_IDENTITY :: "code steps list"
STEPS_SCROLL_IDENTITY :: "code steps scroll"

// entry_label gives the words above an entry, and their color.
entry_label :: proc "contextless" (entry: ^conversation.Entry, buffer: []u8) -> (label: string, color: graphics.Color) {
	switch entry.kind {
	case .Request:
		return system.format(buffer, "you, request ", entry.serial), graphics.colors.link
	case .Reply:
		if entry.step_acts > 0 {
			return system.format(buffer, "step ", u64(entry.step)), graphics.colors.process
		}
		if entry.step > 1 {
			return system.format(buffer, "assistant, step ", u64(entry.step)), graphics.colors.process
		}
		return "assistant", graphics.colors.process
	case .Reply_Refused:
		return system.format(buffer, "the reply to request ", entry.serial, " was refused at the border"), graphics.colors.failed
	case .Act:
		state_color := code_mode_state_color(entry.state)
		if entry.act_kind != .Eval_Lex {
			return system.format(buffer, "act ", entry.act, " (", ACT_KIND_LABELS[entry.act_kind], "), ", STATE_WORDS[entry.state]), state_color
		}
		return system.format(buffer, "act ", entry.act, ", ", STATE_WORDS[entry.state]), state_color
	case .Loop_End:
		switch entry.end_cause {
		case .Final_Reply:
			return system.format(buffer, "request ", entry.serial, ", finished"), graphics.colors.process
		case .Step_Limit:
			return system.format(buffer, "step ", u64(entry.step), ", limit reached"), graphics.colors.warning
		case .Repeated_Step:
			return system.format(buffer, "step ", u64(entry.step), ", repeated step"), graphics.colors.warning
		case .Stopped_By_Principal:
			return system.format(buffer, "request ", entry.serial, ", stopped"), graphics.colors.warning
		case .Model_Failed:
			return system.format(buffer, "request ", entry.serial, ", model did not answer"), graphics.colors.failed
		case .Window_Failed:
			return system.format(buffer, "request ", entry.serial, ", window call stopped"), graphics.colors.failed
		case .Grant_Ended:
			return system.format(buffer, "request ", entry.serial, ", grant ended"), graphics.colors.failed
		}
	}
	return "", graphics.colors.dim
}

// The fonts of the body of an entry (docs/FONTS.md, section 12.6): the
// line of an act is code, and the result of an act that ran is a value, so
// both are in the font of the cells, Paper Mono, which a reader compares
// character by character (in B612 a parenthesis at 14 px reads as a
// bracket); the words that explain are in the interface font.
FONT_CODE :: interface.Font{}

// entry_body gives the text under the label of an entry: code, in the font
// of the cells, then words, in the interface font, or in the font of the
// cells when they are a value. Either can be empty.
entry_body :: proc "contextless" (entry: ^conversation.Entry, buffer: []u8) -> (code: string, words: string, words_are_value: bool) {
	switch entry.kind {
	case .Request, .Reply:
		return "", string(entry.text[:entry.text_count]), false
	case .Reply_Refused:
		kind, _ := errors.kind_of_word(entry.error.kind)
		unit, _ := errors.unit_of_word(entry.error.unit)
		return "", system.format(buffer, errors.KIND_NAMES[kind], ", unit ", errors.UNIT_NAMES[unit], ", argument ", entry.error.argument, ", value ", entry.error.value, ", limit ", entry.error.limit, "; no act of it runs"), false
	case .Act:
		code = string(entry.line[:entry.line_count])
		switch entry.state {
		case .Proposed:
			return code, "", false
		case .Done:
			return code, string(entry.text[:entry.text_count]), true
		case .Refused:
			return code, string(entry.text[:entry.text_count]), false
		case .Awaiting_Principal:
			if entry.dialog == 0 {
				return code, "waiting for the trusted display", false
			}
			return code, "decide it in the act dialog of the trusted display", false
		case .Allowed_By_Principal:
			return code, "allowed by the principal; waiting for execution under a wide grant", false
		case .Refused_By_Principal, .Not_Shown:
			return code, "nothing ran", false
		}
	case .Loop_End:
		switch entry.end_cause {
		case .Final_Reply:
			return "", "", false
		case .Step_Limit:
			return "", "The request reached the limit of 16 steps.", false
		case .Repeated_Step:
			return "", "The agent ran the acts of the step before again and got the same results, so the loop stopped.", false
		case .Stopped_By_Principal:
			return "", "You stopped the agent.", false
		case .Model_Failed:
			return "", "The model gave no usable reply.", false
		case .Window_Failed:
			return "", "A call to the window did not complete.", false
		case .Grant_Ended:
			return "", "The grant for the agent ended, so the loop stopped.", false
		}
	}
	return "", "", false
}

@(private = "file")
assistant_menu_open :: proc "contextless" (x, y, win_w, win_h: int, running: bool) {
	interface.command_palette_close(&assistant_palette)
	items: [12]interface.Context_Menu_Item
	count := code_mode_build_context_menu(&code_mode, running, items[:])
	if count > 0 {
		interface.context_menu_open_compact(&assistant_ctx_menu, x, y, win_w, win_h, items[:count])
	}
}

@(private = "file")
assistant_palette_open :: proc "contextless" (win_h: int, running: bool) {
	interface.context_menu_close(&assistant_ctx_menu)
	items: [12]interface.Command_Palette_Item
	count := code_mode_build_palette(&code_mode, running, items[:])
	if count > 0 {
		interface.command_palette_open(&assistant_palette, "Assistant commands", items[:count], win_h)
	}
}

@(private = "file")
assistant_run_menu_action :: proc "contextless" (action_word: u32, win_h: int, running: bool, visible_rows: int) {
	action, ok := code_mode_action_of_word(action_word)
	if !ok {
		return
	}
	wants_stop, wants_palette := code_mode_apply_action(&code_mode, &talk, action, visible_rows)
	if wants_stop {
		request_stop()
	}
	if wants_palette {
		assistant_palette_open(win_h, running)
	}
}

// draw_code_steps_panel draws the interactive Code steps view: filter strip,
// step/act list via interface.list_of_rows, and the execution trace & approval
// review inspector for the selected act.
draw_code_steps_panel :: proc "contextless" (
	frame: ^interface.Frame,
	cm: ^Code_Mode_State,
	conv: ^conversation.Conversation,
	boxes: Assistant_Boxes,
	metrics: View_Metrics,
	running: bool,
	tokens: box_layout.Element_Tokens,
) -> (jump_entry_num: u64, wants_stop: bool) {
	table := frame.table

	// Filter strip: All / Waiting / Refused + Fold or Expand older results.
	fx := boxes.steps_filter.x
	fy := boxes.steps_filter.y
	fh := boxes.steps_filter.height
	filter_gap := 6
	for filter in Step_Filter {
		label := STEP_FILTER_LABELS[filter]
		btn_w := interface.text_measured_width(table, interface.FONT_INTERFACE, label) + 18
		if fx + btn_w > boxes.steps_filter.x + boxes.steps_filter.width {
			break
		}
		is_open := cm.filter == filter
		btn_res := interface.button_styled(frame, {fx, fy, btn_w, fh}, interface.identity_with(interface.identity("step_filter"), int(filter)), label, is_open ? .Primary : .Secondary, open = is_open)
		if btn_res.activated {
			code_mode_set_filter(cm, conv, filter)
		}
		fx += btn_w + filter_gap
	}

	// Summary count aligned at the right of the filter bar when room permits.
	summary_buf: [64]u8
	summary := system.format(summary_buf[:], u64(cm.row_count), cm.row_count == 1 ? " act" : " acts")
	summary_w := interface.text_measured_width(table, interface.FONT_CAPTION, summary)
	if fx + summary_w + 8 <= boxes.steps_filter.x + boxes.steps_filter.width {
		sy := fy + (fh - interface.line_height(interface.FONT_CAPTION)) / 2
		interface.draw_text(table, boxes.steps_filter.x + boxes.steps_filter.width - summary_w, sy, summary, tokens.text_dim, interface.FONT_CAPTION)
	}

	// Step list box: card recess + interface.list_of_rows.
	list_area := boxes.steps_list
	interface.draw_rectangle(table, list_area.x, list_area.y, list_area.width, list_area.height, graphics.colors.recess)
	interface.draw_outline(table, list_area.x, list_area.y, list_area.width, list_area.height, 1, graphics.colors.edge)

	inner_list := interface.Area{list_area.x + 1, list_area.y + 1, max(list_area.width - 2, 0), max(list_area.height - 2, 0)}
	visible_rows := max(inner_list.height / interface.TABLE_LINE, 1)

	if cm.row_count == 0 {
		empty_msg := cm.total_acts == 0 ? "No agent step has run yet. Type a request below to start an agent loop." : "No step matches this filter."
		interface.draw_text_wrapped(table, inner_list.x + 12, inner_list.y + 10, max(inner_list.width - 24, 0), empty_msg, tokens.text_dim, interface.FONT_INTERFACE)
	} else {
		// Keyboard navigation over the step list when input does not hold focus or with Alt+Up/Down.
		for &key in frame.input.keys[:frame.input.key_count] {
			if key.taken {
				continue
			}
			switch key.code {
			case display.KEY_UP:
				code_mode_move_selection(cm, -1, visible_rows)
				key.taken = true
			case display.KEY_DOWN:
				code_mode_move_selection(cm, 1, visible_rows)
				key.taken = true
			case display.KEY_PAGE_UP:
				code_mode_move_selection(cm, -visible_rows, visible_rows)
				key.taken = true
			case display.KEY_PAGE_DOWN:
				code_mode_move_selection(cm, visible_rows, visible_rows)
				key.taken = true
			}
		}

		// Click selection inside the visible list rows (excluding the scroll bar).
		has_scroll := cm.row_count > visible_rows
		click_width := inner_list.width - (has_scroll ? interface.LIST_ROW_SCROLL_WIDTH : 0)
		if frame.input.pressed && frame.input.pointer_known &&
		   frame.input.press_x >= inner_list.x && frame.input.press_x < inner_list.x + click_width &&
		   frame.input.press_y >= inner_list.y && frame.input.press_y < inner_list.y + inner_list.height {
			clicked := cm.first_row + (frame.input.press_y - inner_list.y) / interface.TABLE_LINE
			if clicked >= 0 && clicked < cm.row_count {
				code_mode_select(cm, clicked, visible_rows)
			}
		}

		max_first := max(cm.row_count - visible_rows, 0)
		cm.first_row = clamp(cm.first_row, 0, max_first)
		slice_count := min(cm.row_count - cm.first_row, min(visible_rows, CODE_STEP_VISIBLE_CAPACITY))
		list_rows: [CODE_STEP_VISIBLE_CAPACITY]interface.List_Row
		right_bufs: [CODE_STEP_VISIBLE_CAPACITY][CODE_STEP_RIGHT_TEXT_BYTES]u8
		for i in 0 ..< slice_count {
			row := cm.rows[cm.first_row + i]
			entry := conversation.entry_at(conv, int(row.entry_index))
			line_text := string(entry.line[:entry.line_count])
			// Keep the first line of a multi-line eval_step as the row preview.
			for b_idx in 0 ..< len(line_text) {
				if line_text[b_idx] == '\n' {
					line_text = line_text[:b_idx]
					break
				}
			}
			list_rows[i] = {
				kind          = .Entry,
				name          = line_text,
				icon          = code_mode_kind_icon(row.kind),
				icon_color    = code_mode_state_color(row.state),
				right_text    = code_mode_row_right_text(row, right_bufs[i][:]),
				name_in_cells = true,
			}
		}
		scrolled: interface.Scroll_Bar_Result
		chosen_in_view := cm.selected_row >= cm.first_row && cm.selected_row < cm.first_row + slice_count ? cm.selected_row - cm.first_row : -1
		_ = interface.list_of_rows(frame, inner_list, list_rows[:slice_count], {
			chosen          = chosen_in_view,
			first           = cm.first_row,
			total           = cm.row_count,
			scroll_bar      = interface.identity(STEPS_SCROLL_IDENTITY),
			scrolled        = &scrolled,
			scroll_bar_name = "code steps",
			element         = interface.identity(STEPS_LIST_IDENTITY),
			name            = "Agent code steps",
		})
		if scrolled.changed {
			cm.first_row = clamp(scrolled.first, 0, max_first)
		}
	}

	// Execution trace & approval review inspector card.
	detail := boxes.steps_detail
	interface.draw_vertical_gradient(table, detail.x, detail.y, detail.width, detail.height, graphics.colors.card_top, graphics.colors.card_bottom)
	interface.draw_outline(table, detail.x, detail.y, detail.width, detail.height, 1, graphics.colors.edge)

	entry := code_mode_selected_entry(cm, conv)
	if entry == nil {
		interface.draw_text(table, detail.x + 10, detail.y + 10, "Select a step to inspect its code and trace.", tokens.text_dim, interface.FONT_INTERFACE)
		return 0, false
	}

	// Detail header: act title, state badge, and Show in chat / Stop loop buttons.
	pad := 10
	dx := detail.x + pad
	dy := detail.y + 8
	dw := max(detail.width - 2 * pad, 0)

	head_buf: [96]u8
	head_text := entry.step > 0 ? system.format(head_buf[:], "Step ", u64(entry.step), " | Act ", entry.act, " | ", ACT_KIND_LABELS[entry.act_kind]) : system.format(head_buf[:], "Act ", entry.act, " | ", ACT_KIND_LABELS[entry.act_kind])

	// Action buttons aligned right inside the inspector header.
	btn_h := 22
	right_cursor := detail.x + detail.width - pad
	jump_label := "Show in chat"
	jump_w := interface.text_measured_width(table, interface.FONT_INTERFACE, jump_label) + 16
	if right_cursor - jump_w > dx + 120 {
		right_cursor -= jump_w
		if interface.button_styled(frame, {right_cursor, dy - 2, jump_w, btn_h}, interface.identity("jump to chat"), jump_label, .Secondary).activated {
			jump_entry_num = entry.number
		}
		right_cursor -= 6
	}
	if entry.state == .Awaiting_Principal && running {
		halt_label := "Stop loop"
		halt_w := interface.text_measured_width(table, interface.FONT_INTERFACE, halt_label) + 16
		if right_cursor - halt_w > dx + 120 {
			right_cursor -= halt_w
			if interface.button_styled(frame, {right_cursor, dy - 2, halt_w, btn_h}, interface.identity("inspector stop"), halt_label, .Danger).activated {
				wants_stop = true
			}
			right_cursor -= 6
		}
	}
	badge_w := 84
	if right_cursor - badge_w > dx + 80 {
		right_cursor -= badge_w
		interface.badge(frame, {right_cursor, dy - 1, badge_w, 20}, STEP_BADGE_WORDS[entry.state], code_mode_state_color(entry.state))
		right_cursor -= 8
	}
	head_shown := interface.text_fit(table, interface.FONT_INTERFACE_BOLD, head_text, max(right_cursor - dx, 0))
	interface.draw_text(table, dx, dy, head_shown, graphics.colors.text, interface.FONT_INTERFACE_BOLD)

	dy += metrics.line + 6
	interface.draw_rectangle(table, detail.x + 1, dy, max(detail.width - 2, 0), 1, graphics.colors.track)
	dy += 6

	// Clip detail body cleanly to the inspector card.
	body_bottom := detail.y + detail.height - 6
	if dy >= body_bottom {
		return jump_entry_num, wants_stop
	}
	interface.draw_clip_push(table, dx, dy, dw, body_bottom - dy)
	defer interface.draw_clip_pop(table)

	// Code lines in Paper Mono (up to 3 wrapped lines so trace result retains room).
	code_text := string(entry.line[:entry.line_count])
	code_rest := code_text
	code_lines_drawn := 0
	for len(code_rest) > 0 && code_lines_drawn < 3 && dy + metrics.code_line <= body_bottom {
		line, next := interface.text_wrap_line(table, FONT_CODE, code_rest, dw)
		interface.draw_text(table, dx, dy, line, graphics.colors.text, FONT_CODE)
		dy += metrics.code_line
		code_lines_drawn += 1
		if len(next) >= len(code_rest) {
			break
		}
		code_rest = next
	}
	dy += 4

	// Approval target identifier when awaiting or decided on the trusted display.
	if entry.service_count > 0 && (entry.state == .Awaiting_Principal || entry.state == .Allowed_By_Principal || entry.state == .Refused_By_Principal || entry.state == .Not_Shown) {
		if dy + metrics.code_line <= body_bottom {
			target_buf: [96]u8
			svc := string(entry.service[:entry.service_count])
			exp := string(entry.export[:entry.export_count])
			target := entry.dialog > 0 ? system.format(target_buf[:], "Target: ", svc, ".", exp, " (dialog ", entry.dialog, ")") : system.format(target_buf[:], "Target: ", svc, ".", exp)
			interface.draw_text(table, dx, dy, interface.text_fit(table, FONT_CODE, target, dw), graphics.colors.dim, FONT_CODE)
			dy += metrics.code_line + 2
		}
	}

	// Trace outcome: typed table, refusal/result text, or approval guidance.
	act_table := entry.state == .Done ? conversation.act_table_of(conv, entry) : nil
	if act_table != nil && dy + metrics.code_line <= body_bottom {
		line_room := max((body_bottom - dy) / metrics.code_line, 1)
		width_cells := max(dw / metrics.cell_width, 1)
		lines := result_lines_of(entry, act_table, width_cells, line_room, 0)
		if lines != nil {
			result_lines_paint(table, lines, dx, dy, metrics.cell_width, metrics.code_line, dy, body_bottom)
			return jump_entry_num, wants_stop
		}
	}

	guidance := code_mode_review_guidance(entry)
	if guidance != "" && dy + metrics.line <= body_bottom {
		interface.draw_text_wrapped(table, dx, dy, dw, guidance, code_mode_state_color(entry.state), interface.FONT_INTERFACE)
		return jump_entry_num, wants_stop
	}
	if entry.text_count > 0 && dy + metrics.code_line <= body_bottom {
		result_text := string(entry.text[:entry.text_count])
		font := entry.state == .Done ? FONT_CODE : interface.FONT_INTERFACE
		color := entry.state == .Refused ? graphics.colors.failed : graphics.colors.text
		interface.draw_text_wrapped(table, dx, dy, dw, result_text, color, font)
	}
	return jump_entry_num, wants_stop
}

// draw builds one frame: the code-mode header (tabs + live status badge +
// optional review trigger), either the conversation view or the code-mode step
// trace inspector, the footer request input (with Stop while a loop runs), and
// any open context menu or command palette overlay.
draw :: proc "contextless" (window: ^display.Window) {
	frame := interface.window_frame_start(&window_memory, window)
	table := frame.table
	tokens, tokens_ok := box_layout.tokens_for(graphics.appearance, .Standard)
	if !tokens_ok {
		interface.window_frame_end(&window_memory.drawing, &frame, window)
		return
	}
	code_mode_sync(&code_mode, &talk)
	running := conversation.request_running(&talk)
	is_running := running != nil

	// Handle right-click context menu and Ctrl+K / Ctrl+Shift+P command palette
	// before widgets see pointer or key events.
	visible_estimate := max((window.height / 2) / interface.TABLE_LINE, 1)
	if frame.input.right_pressed {
		assistant_menu_open(frame.input.right_press_x, frame.input.right_press_y, window.width, window.height, is_running)
	}
	if assistant_palette.open {
		if frame.input.pointer_known {
			pres := interface.command_palette_pointer(&assistant_palette, frame.input.pointer_x, frame.input.pointer_y, frame.input.pressed, frame.input.wheel, window.width, window.height)
			if pres.consumed {
				frame.input.pressed = false
				frame.input.wheel = 0
			}
			if pres.triggered {
				assistant_run_menu_action(pres.triggered_id, window.height, is_running, visible_estimate)
			}
		}
		for &key in frame.input.keys[:frame.input.key_count] {
			if key.taken || !assistant_palette.open {
				continue
			}
			consumed, act_id := interface.command_palette_handle_key(&assistant_palette, key.code, key.character, true, key.modifiers, window.height)
			if consumed {
				key.taken = true
			}
			if act_id != 0 {
				assistant_run_menu_action(act_id, window.height, is_running, visible_estimate)
			}
		}
	} else if assistant_ctx_menu.open {
		if frame.input.pointer_known {
			mres := interface.context_menu_pointer(&assistant_ctx_menu, frame.input.pointer_x, frame.input.pointer_y, frame.input.pressed)
			if mres.consumed {
				frame.input.pressed = false
			}
			if mres.triggered {
				assistant_run_menu_action(mres.triggered_id, window.height, is_running, visible_estimate)
			}
		}
		for &key in frame.input.keys[:frame.input.key_count] {
			if key.taken || !assistant_ctx_menu.open {
				continue
			}
			consumed, act_id := interface.context_menu_handle_key(&assistant_ctx_menu, key.code, key.character, true, key.modifiers)
			if consumed {
				key.taken = true
			}
			if act_id != 0 {
				assistant_run_menu_action(act_id, window.height, is_running, visible_estimate)
			}
		}
	} else {
		for &key in frame.input.keys[:frame.input.key_count] {
			if key.taken {
				continue
			}
			control := key.modifiers & display.MODIFIER_CONTROL != 0
			switch {
			case interface.is_command_palette_shortcut(key.code, key.character, key.modifiers):
				assistant_palette_open(window.height, is_running)
				key.taken = true
			case control && key.character == '1':
				code_mode_set_tab(&code_mode, .Conversation)
				key.taken = true
			case control && key.character == '2':
				code_mode_set_tab(&code_mode, .Steps)
				key.taken = true
			case key.code == display.KEY_ESCAPE && is_running:
				request_stop()
				key.taken = true
			}
		}
	}

	// Re-sync in case a menu or shortcut mutated talk or filter.
	code_mode_sync(&code_mode, &talk)
	running = conversation.request_running(&talk)
	is_running = running != nil

	interface.draw_rectangle(table, 0, 0, window.width, window.height, tokens.surface_background)
	boxes, layout_ok := assistant_layout(&box_tree, window.width, window.height, is_running, tokens, code_mode.active_tab, code_mode.waiting_acts > 0)
	if !layout_ok {
		interface.window_frame_end(&window_memory.drawing, &frame, window)
		return
	}
	metrics := view_metrics(table)

	// Header bar: Conversation / Code steps tab bar, live status badge, and
	// optional Review button when an act awaits principal approval.
	tab_labels := [2]string{ASSISTANT_TAB_LABELS[.Conversation], ASSISTANT_TAB_LABELS[.Steps]}
	tab_idx := int(code_mode.active_tab)
	tab_res := interface.tab_bar(&frame, boxes.tab_bar, interface.identity(TABS_IDENTITY), tab_labels[:], &tab_idx)
	if tab_res.changed || tab_res.activated {
		next_tab := tab_idx == int(Assistant_View_Tab.Steps) ? Assistant_View_Tab.Steps : Assistant_View_Tab.Conversation
		if code_mode_set_tab(&code_mode, next_tab) {
			boxes, layout_ok = assistant_layout(&box_tree, window.width, window.height, is_running, tokens, code_mode.active_tab, code_mode.waiting_acts > 0)
			if !layout_ok {
				interface.window_frame_end(&window_memory.drawing, &frame, window)
				return
			}
		}
	}
	badge_buf: [48]u8
	badge_text, badge_accent := code_mode_badge_text(&code_mode, badge_buf[:])
	interface.badge(&frame, boxes.status_badge, badge_text, badge_accent)
	if boxes.has_review {
		review_res := interface.button_styled(&frame, boxes.review_button, interface.identity(REVIEW_IDENTITY), "Review", .Primary)
		if review_res.activated {
			_ = code_mode_review_next_waiting(&code_mode, &talk, visible_estimate)
			boxes, layout_ok = assistant_layout(&box_tree, window.width, window.height, is_running, tokens, code_mode.active_tab, code_mode.waiting_acts > 0)
			if !layout_ok {
				interface.window_frame_end(&window_memory.drawing, &frame, window)
				return
			}
		}
	}

	switch code_mode.active_tab {
	case .Conversation:
		view_area := boxes.view
		bar_area := boxes.scroll_bar
		view_layout(table, view_area.width, view_area.height, metrics)
		conversation_view.settle(&view_scroll, &view_places, view_area.height)
		// A page key moves the view by its height less one line, so the line at
		// an edge shows again; Control with Home or End goes to an end.
		page := max(view_area.height - metrics.line, metrics.line)
		for &key in frame.input.keys[:frame.input.key_count] {
			if key.taken {
				continue
			}
			control := key.modifiers & display.MODIFIER_CONTROL != 0
			switch {
			case key.code == display.KEY_PAGE_UP:
				conversation_view.scroll_set(&view_scroll, &view_places, view_area.height, view_scroll.first - page)
			case key.code == display.KEY_PAGE_DOWN:
				conversation_view.scroll_set(&view_scroll, &view_places, view_area.height, view_scroll.first + page)
			case key.code == display.KEY_HOME && control:
				conversation_view.scroll_set(&view_scroll, &view_places, view_area.height, 0)
			case key.code == display.KEY_END && control:
				conversation_view.scroll_set(&view_scroll, &view_places, view_area.height, conversation_view.total(&view_places))
			case:
				continue
			}
			key.taken = true
		}
		// The bar shows only when the content is taller than the view; its room
		// stays, so a new entry never moves the lines sideways.
		total := conversation_view.total(&view_places)
		if total > view_area.height {
			moved := interface.scroll_bar(&frame, bar_area, interface.identity("conversation scroll bar"), .Vertical, {total = total, visible = view_area.height, first = view_scroll.first}, {line = metrics.line, page = page}, "conversation", view_area)
			if moved.changed {
				conversation_view.scroll_set(&view_scroll, &view_places, view_area.height, moved.first)
			}
		}
		view_paint(&frame, view_area, metrics)
		if talk.entry_count == 0 {
			interface.draw_text_wrapped(table, boxes.body_row.x, boxes.body_row.y, boxes.body_row.width, "Ask the agent for help. It reads your request on the host, and each act that it proposes shows here before its result.", tokens.text_dim, interface.FONT_INTERFACE)
		}
	case .Steps:
		jump_num, inspector_stop := draw_code_steps_panel(&frame, &code_mode, &talk, boxes, metrics, is_running, tokens)
		if inspector_stop {
			request_stop()
		}
		if jump_num != 0 {
			code_mode_set_tab(&code_mode, .Conversation)
			conv_boxes, conv_ok := assistant_layout(&box_tree, window.width, window.height, is_running, tokens, .Conversation, code_mode.waiting_acts > 0)
			if conv_ok {
				view_layout(table, conv_boxes.view.width, conv_boxes.view.height, metrics)
				_ = code_mode_scroll_to_entry(&view_scroll, &view_places, conv_boxes.view.height, jump_num)
			}
			talk.changed = true
		}
	}

	// The request field takes the keys when nothing else has the focus.
	if frame.state.focus == 0 || (!is_running && frame.state.focus == interface.identity(STOP_IDENTITY)) {
		frame.state.focus = interface.identity(INPUT_IDENTITY)
	}
	field := interface.text_input(&frame, boxes.input, interface.identity(INPUT_IDENTITY), typed[:], &typed_count, "ask the assistant")
	if field.activated && typed_count > 0 {
		if request_keep(string(typed[:typed_count])) {
			typed_count = 0
			// A new request shows: the view follows the newest entry again.
			view_scroll.following = true
		}
	}
	if is_running && boxes.has_stop {
		stop_result := interface.button_styled(&frame, boxes.stop_button, interface.identity(STOP_IDENTITY), "Stop", .Danger, disabled = running.stop_requested)
		if stop_result.activated {
			request_stop()
		}
	}

	// Floating overlays draw last above every pane.
	interface.context_menu_draw(table, &assistant_ctx_menu)
	interface.command_palette_draw(table, &assistant_palette, window.width, window.height)
	interface.window_frame_end(&window_memory.drawing, &frame, window)
}

// The entry of the assistant: it opens its service and its window, then
// runs the calls of the runner and the events of the window in one loop.
// While an act waits for the principal, the loop also wakes to read the
// decision of the act dialog.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	service, _ := system.service_open(ctx)
	display_port_bind(ctx)
	// Open the display first so startup font mapping finishes and detaches the
	// shared storage ring before the store worker thread opens it.
	window, ok := display.open(ctx, WIDTH, HEIGHT, "assistant")
	if !ok {
		system.stop(.Failed)
	}
	store_start(ctx)
	draw(&window)
	system.log_fact(.Info, Running{})
	for {
		store_done_seen := system.event_count(&store_state.done_event)
		store_poll()
		waiting := acts_waiting_step()
		if talk.changed {
			talk.changed = false
			draw(&window)
		}
		wait: system.Wait
		display.wait_events(&wait, &window)
		system.service_wait(&wait, &service)
		system.wait_event(&wait, &store_state.done_event, store_done_seen)
		deadline := waiting ? system.time() + DECISION_POLL_MILLISECONDS : system.WAIT_FOREVER
		// A held arrow of the scroll bar takes its next step at a time of
		// the clock: the wait ends there at the latest.
		step_time, step_due := interface.window_scroll_bar_wake(&window_memory.drawing)
		if step_due {
			deadline = min(deadline, step_time)
		}
		system.wait_end(&wait, deadline)
		system.service_run(&service)
		store_poll()
		came := interface.window_events(&window_memory.drawing, &window)
		if came || talk.changed || (step_due && system.time() >= step_time) {
			talk.changed = false
			draw(&window)
			// A request that the field kept draws in the next frame.
			if talk.changed {
				talk.changed = false
				draw(&window)
			}
			store_poll()
		}
	}
}
