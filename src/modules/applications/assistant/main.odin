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
import assistant_contract "modus:contract/assistant"
import "modus:contract/errors"
import "modus:display"
import "modus:graphics"
import "modus:interface"
import "modus:system"

WIDTH :: 560
HEIGHT :: 420
// The window, the entries of the conversation (about 90 KiB), the two
// draw tables (about 40 KiB), the stack, and the glyph memory of a window
// of paint, which this process draws as: the tool counts the window at the
// window bound (docs/MODULE_CONTRACT.md, "The budget that a module asks
// for").
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 1820, window_width = WIDTH, window_height = HEIGHT}

MARGIN :: 12
INPUT_HEIGHT :: 28
// The time between two reads of the decision of the principal while an
// act waits for it: shorter than a person reads a dialog.
DECISION_POLL_MILLISECONDS :: 100

// The records and the text of one frame: a conversation that fills the
// window holds about 40 lines, each a record, of the text of its entries.
window_memory: interface.Window_Memory(256, 8192)

// The text that the principal types: one request.
typed: [assistant_contract.REQUEST_TEXT_BYTES]u8
typed_count: int

INPUT_IDENTITY :: "request"

// entry_label gives the words above an entry, and their color.
entry_label :: proc "contextless" (entry: ^conversation.Entry, buffer: []u8) -> (label: string, color: graphics.Color) {
	switch entry.kind {
	case .Request:
		return system.format(buffer, "you, request ", entry.serial), graphics.colors.link
	case .Reply:
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
	}
	return "", graphics.colors.dim
}

// entry_body gives the text under the label of an entry.
entry_body :: proc "contextless" (entry: ^conversation.Entry, buffer: []u8) -> string {
	switch entry.kind {
	case .Request, .Reply:
		return string(entry.text[:entry.text_count])
	case .Reply_Refused:
		kind, _ := errors.kind_of_word(entry.error.kind)
		unit, _ := errors.unit_of_word(entry.error.unit)
		return system.format(buffer, errors.KIND_NAMES[kind], ", unit ", errors.UNIT_NAMES[unit], ", argument ", entry.error.argument, ", value ", entry.error.value, ", limit ", entry.error.limit, "; no act of it runs")
	case .Act:
		line := string(entry.line[:entry.line_count])
		switch entry.state {
		case .Proposed:
			return line
		case .Done, .Refused:
			return system.format(buffer, line, ": ", string(entry.text[:entry.text_count]))
		case .Awaiting_Principal:
			if entry.dialog == 0 {
				return system.format(buffer, line, ": waiting for the trusted display")
			}
			return system.format(buffer, line, ": decide it in the act dialog of the trusted display")
		case .Allowed_By_Principal:
			return system.format(buffer, line, ": allowed; the act runs when the agent console of a wide grant runs it")
		case .Refused_By_Principal, .Not_Shown:
			return system.format(buffer, line, ": nothing ran")
		}
	}
	return ""
}

// draw builds one frame: the conversation from the newest entry up, as far
// as the room goes, and the field of the request at the foot.
draw :: proc "contextless" (window: ^display.Window) {
	frame := interface.window_frame_start(&window_memory, window)
	table := frame.table
	interface.background(&frame, {0, 0, window.width, window.height})
	room := window.width - 2 * MARGIN
	input_top := window.height - MARGIN - INPUT_HEIGHT
	line := interface.line_height(interface.FONT_INTERFACE)
	bottom := input_top - MARGIN
	// From the newest entry up: only the entries that show are measured.
	for index := talk.entry_count - 1; index >= 0 && bottom > MARGIN; index -= 1 {
		entry := conversation.entry_at(&talk, index)
		label_buffer: [160]u8
		body_buffer: [assistant_contract.REPLY_TEXT_BYTES + assistant_contract.ACT_LINE_BYTES + 160]u8
		label, color := entry_label(entry, label_buffer[:])
		body := entry_body(entry, body_buffer[:])
		lines := interface.text_wrapped_line_count(table, interface.FONT_INTERFACE, body, room)
		height := line + lines * line + MARGIN / 2
		top := bottom - height
		if top < MARGIN {
			break
		}
		interface.draw_text(table, MARGIN, top, label, color, interface.FONT_INTERFACE_BOLD)
		interface.draw_text_wrapped(table, MARGIN, top + line, room, body, graphics.colors.text, interface.FONT_INTERFACE)
		bottom = top
	}
	if talk.entry_count == 0 {
		interface.draw_text_wrapped(table, MARGIN, MARGIN, room, "Ask the agent for help. It reads your request on the host, and each act that it proposes shows here before its result.", graphics.colors.dim, interface.FONT_INTERFACE)
	}
	// The field takes the keys when nothing else has the focus.
	if frame.state.focus == 0 {
		frame.state.focus = interface.identity(INPUT_IDENTITY)
	}
	field := interface.text_input(&frame, {MARGIN, input_top, room, INPUT_HEIGHT}, interface.identity(INPUT_IDENTITY), typed[:], &typed_count, "ask the assistant")
	if field.activated && typed_count > 0 {
		if request_keep(string(typed[:typed_count])) {
			typed_count = 0
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
