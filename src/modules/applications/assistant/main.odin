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
import "internal:assistant/conversation_view"
import assistant_contract "modus:contract/assistant"
import "modus:contract/errors"
import "modus:contract/module"
import "modus:contract/reference_screen"
import "modus:contract/scale_factor"
import "modus:display"
import "modus:graphics"
import "modus:interface"
import "modus:system"

// Room for a table of the processes: about 90 cells of the font of the
// cells, and 24 lines.
WIDTH :: 760
HEIGHT :: 560
// The working memory, counted from the sizes of the state below (the
// checks after it tie the literal to them; the tool counts the window at
// the window bound, docs/MODULE_CONTRACT.md, "The budget that a module asks
// for"):
//
//   talk               6 738 376 bytes  288 entries of 16 KiB, 16 kept tables of 64 rows and the staging copy
//   view_layouts         617 472        the layout of each entry: its lines
//   view_places            4 624        the place of each entry in the view
//   result_slots         394 032        the lines of 6 results that a frame paints
//   layout_lines          65 624        the lines that measure a result at its layout
//   result_scratch        20 480        the description and the rows of one draw
//   window_memory        139 256        the two draw tables of the worst frame
//   typed                  4 096        the request that the principal types
//   the rest of the state, the port of the act dialog: some hundred bytes
//
// 1950 pages; then 1748 pages for the stack, the small tables and the glyph
// memory, as paint states them for itself, which this process draws as,
// and the glyph memory of the copy of the text rendering of the drawing
// module, 354 pages (display.TEXT_MEMORY_PAGES): 1950 + 1748 + 354 = 4052.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 4052, window_width = WIDTH, window_height = HEIGHT}

// The pages of the stack, the small tables and the glyph memory, as paint
// counts them (src/modules/demonstrations/paint/main.odin).
STACK_AND_GLYPH_PAGES :: 1748
STATE_BYTES :: size_of(talk) + size_of(view_layouts) + size_of(view_places) + size_of(view_scroll) + size_of(result_slots) + size_of(layout_lines) + size_of(result_scratch) + size_of(window_memory) + size_of(typed) + size_of(typed_count) + size_of(display_port)
STATE_PAGES :: (STATE_BYTES + system.PAGE_SIZE - 1) / system.PAGE_SIZE
#assert(MODULE_BUDGET.working_memory_pages == STATE_PAGES + STACK_AND_GLYPH_PAGES + display.TEXT_MEMORY_PAGES)
// The window at the largest scale, cut to the reference screen, two
// pictures, as the tool counts it: the budget stays under the largest
// budget of a module.
WINDOW_SCREEN_WIDTH :: min((u64(WIDTH) * u64(scale_factor.LARGEST) + scale_factor.EIGHTHS_OF_ONE / 2) / scale_factor.EIGHTHS_OF_ONE, u64(reference_screen.WIDTH))
WINDOW_SCREEN_HEIGHT :: min((u64(HEIGHT) * u64(scale_factor.LARGEST) + scale_factor.EIGHTHS_OF_ONE / 2) / scale_factor.EIGHTHS_OF_ONE, u64(reference_screen.HEIGHT))
WINDOW_PAGES :: (2 * WINDOW_SCREEN_WIDTH * WINDOW_SCREEN_HEIGHT * 4 + system.PAGE_SIZE - 1) / system.PAGE_SIZE
#assert(u64(MODULE_BUDGET.working_memory_pages) + WINDOW_PAGES <= module.LARGEST_BUDGET_PAGES)

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

// draw builds one frame: the view of the conversation, its scroll bar, and
// the field of the request (with Stop while a loop runs) at the foot.
draw :: proc "contextless" (window: ^display.Window) {
	frame := interface.window_frame_start(&window_memory, window)
	table := frame.table
	interface.background(&frame, {0, 0, window.width, window.height})
	room := window.width - 2 * MARGIN
	input_top := window.height - MARGIN - INPUT_HEIGHT
	metrics := view_metrics(table)
	running := conversation.request_running(&talk)
	view_area := interface.Area{MARGIN, MARGIN, room - interface.SCROLL_BAR_THICKNESS - MARGIN / 2, input_top - 2 * MARGIN}
	bar_area := interface.Area{MARGIN + room - interface.SCROLL_BAR_THICKNESS, MARGIN, interface.SCROLL_BAR_THICKNESS, view_area.height}
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
		case key.code == display.KEY_ESCAPE && running != nil:
			request_stop()
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
			// A new request shows: the view follows the newest entry again.
			view_scroll.following = true
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
		deadline := waiting ? system.time() + DECISION_POLL_MILLISECONDS : system.WAIT_FOREVER
		// A held arrow of the scroll bar takes its next step at a time of
		// the clock: the wait ends there at the latest.
		step_time, step_due := interface.window_scroll_bar_wake(&window_memory.drawing)
		if step_due {
			deadline = min(deadline, step_time)
		}
		system.wait_end(&wait, deadline)
		system.service_run(&service)
		came := interface.window_events(&window_memory.drawing, &window)
		if came || talk.changed || (step_due && system.time() >= step_time) {
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