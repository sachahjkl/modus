// The assistant: a window where the principal asks an agent for help, and
// reads the conversation: the replies of the agent, each act that it
// proposes, and the result of each act (src/md/features/assistant.md).
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
import "internal:assistant/result_lines"
import assistant_contract "modus:contract/assistant"
import "modus:contract/errors"
import "modus:contract/text_encoding"
import "modus:display"
import "modus:graphics"
import "modus:interface"
import "modus:system"

// Room for a table of the processes: about 90 cells of the font of the
// cells, and 24 lines.
WIDTH :: 760
HEIGHT :: 560
// The window, the entries of the conversation (288 entries of 16 KiB text
// and a pool of 16 typed 64-row tables plus staging, about 6.6 MiB), the
// kept lines of three results (about 192 KiB), the two draw tables of the
// worst frame (about 130 KiB: result_table.odin), the stack, and the glyph
// memory of a window of paint, which this process draws as: the tool
// counts the window at the window bound (docs/MODULE_CONTRACT.md, "The
// budget that a module asks for").
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 3800, window_width = WIDTH, window_height = HEIGHT}

MARGIN :: 12
INPUT_HEIGHT :: 28
STOP_WIDTH :: 80
// The time between two reads of the decision of the principal while an
// act waits for it: shorter than a person reads a dialog.
DECISION_POLL_MILLISECONDS :: 100

// The records and the text of one frame, sized for the worst frame: a
// window of results, each line a record for each run of one color
// (result_table.odin).
window_memory: interface.Window_Memory(WINDOW_RECORDS, WINDOW_TEXT_BYTES)

// The text that the principal types: one request.
typed: [assistant_contract.REQUEST_TEXT_BYTES]u8
typed_count: int

INPUT_IDENTITY :: "request"
STOP_IDENTITY :: "stop"

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
		state_color := graphics.colors.dim
		switch entry.state {
		case .Proposed, .Awaiting_Principal:
			state_color = graphics.colors.warning
		case .Done, .Allowed_By_Principal:
			state_color = graphics.colors.process
		case .Refused, .Refused_By_Principal, .Not_Shown:
			state_color = graphics.colors.failed
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
			return code, "allowed; the act runs when the agent console of a wide grant runs it", false
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
			return "", "The agent proposed the same acts as in the step before, so the loop stopped.", false
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

// fold_summary writes the short label of a folded act result button.
@(private = "file")
fold_summary :: proc "contextless" (entry: ^conversation.Entry, table: ^conversation.Act_Table, buffer: []u8) -> string {
	if table != nil {
		name := conversation.act_table_name(table)
		switch table.shape {
		case .Table:
			return system.format(buffer, "Show ", u64(table.total_rows), " rows of ", name)
		case .Record:
			return system.format(buffer, "Show ", name)
		}
	}
	preview_limit := min(entry.text_count, 48)
	preview_count := text_encoding.complete_characters(entry.text[:preview_limit])
	preview := string(entry.text[:preview_count])
	if preview_count < entry.text_count {
		return system.format(buffer, "Show result: ", preview, "...")
	}
	return system.format(buffer, "Show result: ", preview)
}

// draw builds one frame: the conversation from the newest entry up, as far
// as the room goes, and the field of the request (with Stop while running)
// at the foot.
draw :: proc "contextless" (window: ^display.Window) {
	frame := interface.window_frame_start(&window_memory, window)
	table := frame.table
	interface.background(&frame, {0, 0, window.width, window.height})
	room := window.width - 2 * MARGIN
	input_top := window.height - MARGIN - INPUT_HEIGHT
	line := interface.line_height(interface.FONT_INTERFACE)
	code_line := interface.line_height(FONT_CODE)
	fold_height := line + 4
	// The font of the cells has one advance: the width of a cell.
	cell_width := max(interface.text_measured_width(table, FONT_CODE, "0"), 1)
	running := conversation.request_running(&talk)
	if running != nil {
		for &key in frame.input.keys[:frame.input.key_count] {
			if !key.taken && key.code == display.KEY_ESCAPE {
				key.taken = true
				request_stop()
				break
			}
		}
	}
	bottom := input_top - MARGIN
	// From the newest entry up: only the entries that show are measured.
	for index := talk.entry_count - 1; index >= 0 && bottom > MARGIN; index -= 1 {
		entry := conversation.entry_at(&talk, index)
		label_buffer: [160]u8
		body_buffer: [256]u8
		fold_buffer: [128]u8
		page_buffer: [64]u8
		label, color := entry_label(entry, label_buffer[:])
		code, words, words_are_value := entry_body(entry, body_buffer[:])
		code_lines := code != "" ? interface.text_wrapped_line_count(table, FONT_CODE, code, room) : 0
		folded_default := conversation.act_folded_by_default(&talk, entry)
		folded := conversation.act_folded(&talk, entry)
		act_tbl := entry.kind == .Act && entry.state == .Done ? conversation.act_table_of(&talk, entry) : nil
		fold_label := ""
		toggle_height := 0
		if folded {
			fold_label = fold_summary(entry, act_tbl, fold_buffer[:])
			toggle_height = fold_height
			words = ""
		} else if folded_default {
			fold_label = "Hide result"
			toggle_height = fold_height
		}
		// A result that came typed is drawn as the console draws it, in
		// place of its words, within the room left above: the rows that
		// fit, with Previous/Next paging when more carried rows exist.
		result: ^result_lines.Lines
		page_height := 0
		row_offset := int(entry.table_row_offset)
		if !folded && act_tbl != nil {
			// Reserve space for the paging bar when the carried table might
			// need more than one page.
			max_lines := (bottom - MARGIN - line - code_lines * code_line - toggle_height - MARGIN / 2) / code_line
			needs_paging := act_tbl.shape == .Table && (row_offset > 0 || act_tbl.row_count + 4 > max_lines)
			reserved := needs_paging ? fold_height : 0
			line_room := (bottom - MARGIN - line - code_lines * code_line - toggle_height - reserved - MARGIN / 2) / code_line
			if lines := result_lines_of(entry, act_tbl, room / cell_width, line_room, row_offset); lines != nil {
				result, words = lines, ""
				if act_tbl.shape == .Table && (row_offset > 0 || row_offset + lines.shown_rows < act_tbl.row_count) {
					page_height = fold_height
				}
			}
		}
		words_font := words_are_value ? FONT_CODE : interface.FONT_INTERFACE
		words_line := words_are_value ? code_line : line
		word_lines := words != "" ? interface.text_wrapped_line_count(table, words_font, words, room) : 0
		result_line_count := result != nil ? result.line_count : 0
		height := line + code_lines * code_line + toggle_height + word_lines * words_line + result_line_count * code_line + page_height + MARGIN / 2
		top := bottom - height
		// The newest entry always shows: a reply of up to 16 KiB can be
		// taller than the window, so it shows its start, cut to the room,
		// and its text is bounded so the frame keeps its records.
		clipped := false
		if top < MARGIN {
			if bottom != input_top - MARGIN || words == "" {
				break
			}
			room_lines := max((bottom - MARGIN - line - code_lines * code_line - toggle_height) / words_line, 1)
			byte_bound := room_lines * max(room / cell_width, 1) * 2
			if len(words) > byte_bound {
				words = words[:text_encoding.complete_characters(transmute([]u8)words[:byte_bound])]
			}
			top = MARGIN
			interface.draw_clip_push(table, 0, MARGIN, window.width, bottom - MARGIN)
			clipped = true
		}
		defer if clipped {
			interface.draw_clip_pop(table)
		}
		interface.draw_text(table, MARGIN, top, label, color, interface.FONT_INTERFACE_BOLD)
		body_top := top + line
		if code != "" {
			interface.draw_text_wrapped(table, MARGIN, body_top, room, code, graphics.colors.text, FONT_CODE)
			body_top += code_lines * code_line
		}
		if toggle_height > 0 {
			fold_width := min(interface.text_measured_width(table, interface.FONT_INTERFACE, fold_label) + 20, room)
			fold_id := interface.identity_with(interface.identity("act_fold"), int(entry.act))
			toggle_result := interface.button(&frame, {MARGIN, body_top, fold_width, fold_height}, fold_id, fold_label, toggle = folded ? .False : .True)
			if toggle_result.activated {
				conversation.act_fold_toggle(&talk, entry)
			}
			body_top += fold_height
		}
		if words != "" {
			interface.draw_text_wrapped(table, MARGIN, body_top, room, words, graphics.colors.text, words_font)
		}
		if result != nil {
			result_lines_paint(table, result, MARGIN, body_top, cell_width, code_line)
			body_top += result.line_count * code_line
			if page_height > 0 {
				page_x := MARGIN
				step_rows := max(result.shown_rows, 1)
				if row_offset > 0 {
					prev_w := interface.text_measured_width(table, interface.FONT_INTERFACE, "Previous rows") + 16
					prev_id := interface.identity_with(interface.identity("act_prev"), int(entry.act))
					if interface.button(&frame, {page_x, body_top, prev_w, fold_height}, prev_id, "Previous rows").activated {
						conversation.act_table_page(&talk, entry, max(row_offset - step_rows, 0))
					}
					page_x += prev_w + MARGIN / 2
				}
				if row_offset + result.shown_rows < act_tbl.row_count {
					next_w := interface.text_measured_width(table, interface.FONT_INTERFACE, "Next rows") + 16
					next_id := interface.identity_with(interface.identity("act_next"), int(entry.act))
					if interface.button(&frame, {page_x, body_top, next_w, fold_height}, next_id, "Next rows").activated {
						conversation.act_table_page(&talk, entry, row_offset + step_rows)
					}
					page_x += next_w + MARGIN / 2
				}
				first_row := u64(min(row_offset + 1, act_tbl.row_count))
				last_row := u64(min(row_offset + result.shown_rows, act_tbl.row_count))
				page_text := system.format(page_buffer[:], "rows ", first_row, " to ", last_row, " of ", u64(act_tbl.row_count))
				interface.draw_text(table, page_x, body_top + 2, page_text, graphics.colors.dim, interface.FONT_INTERFACE)
			}
		}
		bottom = top
		if clipped {
			break
		}
	}
	if talk.entry_count == 0 {
		interface.draw_text_wrapped(table, MARGIN, MARGIN, room, "Ask the agent for help. It reads your request on the host, and each act that it proposes shows here before its result.", graphics.colors.dim, interface.FONT_INTERFACE)
	}
	// The field takes the keys when nothing else has the focus.
	if frame.state.focus == 0 || (running == nil && frame.state.focus == interface.identity(STOP_IDENTITY)) {
		frame.state.focus = interface.identity(INPUT_IDENTITY)
	}
	input_width := running != nil ? room - STOP_WIDTH - MARGIN / 2 : room
	field := interface.text_input(&frame, {MARGIN, input_top, input_width, INPUT_HEIGHT}, interface.identity(INPUT_IDENTITY), typed[:], &typed_count, "ask the assistant")
	if field.activated && typed_count > 0 {
		if request_keep(string(typed[:typed_count])) {
			typed_count = 0
		}
	}
	if running != nil {
		stop_label := running.stop_requested ? "Stopping" : "Stop"
		stop_area := interface.Area{MARGIN + room - STOP_WIDTH, input_top, STOP_WIDTH, INPUT_HEIGHT}
		stop_result := interface.button(&frame, stop_area, interface.identity(STOP_IDENTITY), stop_label)
		if stop_result.activated {
			request_stop()
		}
	}
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
	window, ok := display.open(ctx, WIDTH, HEIGHT, "assistant")
	if !ok {
		system.stop(.Failed)
	}
	draw(&window)
	system.log_fact(.Info, Running{})
	for {
		waiting := acts_waiting_step()
		wait: system.Wait
		display.wait_events(&wait, &window)
		system.service_wait(&wait, &service)
		system.wait_end(&wait, waiting ? system.time() + DECISION_POLL_MILLISECONDS : system.WAIT_FOREVER)
		system.service_run(&service)
		came := interface.window_events(&window_memory.drawing, &window)
		if came || talk.changed {
			talk.changed = false
			draw(&window)
			// A request that the field kept draws in the next frame.
			if talk.changed {
				talk.changed = false
				draw(&window)
			}
		}
	}
}
