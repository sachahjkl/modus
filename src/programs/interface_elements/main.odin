// The elements of the interface package, live (docs/INTERFACE.md).
//
// The window shows each element of the package: a button, a list with a
// choice, a text input, bars, lines of a label and a value, a table, the
// large number of a card. A second card shows the draw table of the last
// frame: its records, its bytes of text, its damage rectangles and the time
// of each part. A button shows the damage rectangles of each frame over the
// window, as records of the next frame.
//
// At its start the program measures the damage by difference on its own
// window: a frame where nothing changed, a frame where one number changed,
// a frame where everything moved, and the whole frame drawn with no
// comparison. The log has the numbers.
//
// **What it is for.** It is the catalog of the
// [elements](term:element) of the [interface package](term:interface-package),
// each in its live state, and the measure of
// [damage by difference](term:damage-by-difference): a frame is a
// [draw table](term:draw-table) that the package compares with the table
// of the frame before, and only the rectangles that differ are drawn again.
//
// **What a reader sees.** Start it from the menu of the programs, or with
// `start("interface_elements")` in the console. The input can press the
// button, choose a line of the list, and type in the text input; the
// second card shows the cost of each frame. The [action bar](term:action-bar)
// at the bottom names the keys, and a press on an item runs its key. The
// log gets one line for each
// measured frame (`interface_elements: <frame>: <count> records, <count>
// damage rectangles, ...`), the time of one whole frame, then
// `interface_elements: ok, ...`.
//
// **Its grants**: none. A window is all that it needs.
package interface_elements

import "modus:support/display"
import "modus:support/graphics"
import "modus:support/interface"
import "modus:support/system"

WIDTH :: 816
HEIGHT :: 560
ELEMENTS_CARD_WIDTH :: 472 // The card of the elements; the card of the frame takes the rest.
CARDS_HEIGHT :: HEIGHT - 16 - interface.ACTION_BAR_ROW_HEIGHT // The cards stand over the action bar.
TICK :: 100 // Milliseconds between two frames.

// The keys of the window, in its action bar (docs/INTERFACE.md, "4.4 The
// action bar"). Each one is a key of the interface package: the focus,
// the press of a button, the choice of the list.
// A procedure, not a global array: an item is made by a call, and a
// freestanding program runs no call before its entry.
bar_items :: proc "contextless" () -> [5]interface.Action_Bar_Item {
	return {
		interface.action_bar_item("next element", 6, "Tab"),
		interface.action_bar_item("element before", 3, "Shift", "Tab"),
		interface.action_bar_item("press", 5, "Enter"),
		interface.action_bar_item("line before", 4, "Up"),
		interface.action_bar_item("line after", 4, "Down"),
	}
}
bar: interface.Action_Bar_State

window_memory: interface.Window_Memory(512, 8192)

// What the window shows: the state of the program.
presses: u64
names := [?]string{"boot", "clock", "remote", "scheduler", "palette", "compositor"}
choice: int
typed: [32]u8
typed_count: int
show_damage: bool
frames: u64
moved: bool // The measure of a frame where everything moved.
last_damage: interface.Damage

Part :: struct {
	text:  string,
	color: graphics.Color,
}

// build describes the whole window for one frame.
build :: proc "contextless" (frame: ^interface.Frame, number: u64) -> interface.Action_Bar_Result {
	builder: interface.Text_Builder
	offset := moved ? 8 : 0
	interface.background(frame, {0, 0, WIDTH, HEIGHT})

	// The elements.
	// The width of the card holds its three texts in the font of the cells,
	// the widest font: the title, the caption of 23 characters and the keys.
	// The keys of the window are in its action bar, not in the count of
	// this card: one fact once on a screen.
	interface.action_bar_input_take(frame, &bar)
	content := interface.card(frame, {8 + offset, 8, ELEMENTS_CARD_WIDTH, CARDS_HEIGHT}, "ELEMENTS", "modus:support/interface", graphics.colors.kernel)
	column := interface.column_of(content, 8)
	pressed := interface.button(frame, interface.column_take(&column, 24), interface.identity("press"), "press this button")
	if pressed.activated {
		presses += 1
		system.log("interface_elements: the button was pressed ", presses, " times")
	}
	interface.label_value_line(frame, interface.column_take(&column, 16), "presses", interface.number_text(&builder, presses))
	interface.cell_text(frame, interface.column_take(&column, 16), "a list with a choice", graphics.colors.dim, .Left, interface.FONT_INTERFACE)
	list_area := interface.column_take(&column, 3 * interface.TABLE_LINE)
	// The element name lets a machine test put the pointer over the list,
	// where the wheel moves its view.
	interface.element_name(frame, list_area, "list")
	listed := interface.list_with_choice(frame, list_area, interface.identity("list"), names[:], &choice, {chosen_hint = "enter: start"})
	if listed.changed {
		system.log("interface_elements: the list chooses ", names[choice])
	}
	interface.cell_text(frame, interface.column_take(&column, 16), "a text input", graphics.colors.dim, .Left, interface.FONT_INTERFACE)
	typed_result := interface.text_input(frame, interface.column_take(&column, 24), interface.identity("text"), typed[:], &typed_count, "type a text")
	if typed_result.changed {
		system.log("interface_elements: the text is \"", string(typed[:typed_count]), "\"")
	}
	interface.cell_text(frame, interface.column_take(&column, 16), "bars: a value against a maximum, parts of one total", graphics.colors.dim, .Left, interface.FONT_INTERFACE)
	interface.bar(frame, interface.column_take(&column, 8), number % 100, 100, graphics.colors.program)
	parts := [3]u64{number % 50 + 10, 20, 15}
	colors := [3]graphics.Color{graphics.colors.kernel, graphics.colors.memory, graphics.colors.failed}
	interface.bar_parts(frame, interface.column_take(&column, 8), parts[:], colors[:], 100)
	interface.cell_text(frame, interface.column_take(&column, 16), "a table", graphics.colors.dim, .Left, interface.FONT_INTERFACE)
	cells: [3]interface.Area
	sizes := [3]interface.Size{interface.share(), interface.characters(10), interface.characters(10)}
	interface.row_split(interface.column_take(&column, 24), sizes[:], cells[:], 16)
	interface.table_header(frame, cells[:], {"element", "records", "bytes"}, {.Left, .Right, .Right})
	Line :: struct {
		name:          string,
		records, size: u64,
	}
	lines := [?]Line{{"card", 5, 0}, {"bar", 2, 0}, {"button", 2, 0}}
	for line, index in lines {
		area := interface.column_take(&column, 24)
		interface.table_band(frame, area, index)
		interface.row_split({area.x + 8, area.y, area.width - 16, area.height}, sizes[:], cells[:], 16)
		interface.cell_text(frame, cells[0], line.name, graphics.colors.text, .Left, interface.FONT_INTERFACE)
		interface.cell_text(frame, cells[1], interface.number_text(&builder, line.records), graphics.colors.text, .Right)
		interface.cell_text(frame, cells[2], interface.number_text(&builder, line.records * size_of(interface.Draw_Record)), graphics.colors.text, .Right)
	}

	// The draw table of the last frame.
	content = interface.card(frame, {ELEMENTS_CARD_WIDTH + 16 + offset, 8, WIDTH - ELEMENTS_CARD_WIDTH - 24, CARDS_HEIGHT}, "THE FRAME", "Draw_Table, Damage", graphics.colors.machine)
	column = interface.column_of(content, 8)
	interface.large_number(frame, content.x, interface.column_take(&column, 48).y, interface.number_text(&builder, number), graphics.colors.machine)
	interface.cell_text(frame, interface.column_take(&column, 16), "frames", graphics.colors.dim, .Left, interface.FONT_INTERFACE)
	facts := [?]struct {
		name:  string,
		value: u64,
		unit:  string,
	} {
		{"records", u64(window_memory.drawing.before.record_count), ""},
		{"bytes of text", u64(window_memory.drawing.before.text_count), " B"},
		{"damage rectangles", u64(last_damage.count), ""},
		{"build", window_memory.drawing.build_time / 1000, " us"},
		{"difference", window_memory.drawing.difference_time / 1000, " us"},
		{"draw", window_memory.drawing.draw_time / 1000, " us"},
	}
	for fact in facts {
		value: interface.Text_Builder
		interface.text_put_number(&value, fact.value)
		interface.text_put(&value, fact.unit)
		interface.label_value_line(frame, interface.column_take(&column, 16), fact.name, interface.text_of(&value))
	}
	interface.column_take(&column, 8)
	overlay := interface.button(frame, interface.column_take(&column, 24), interface.identity("damage"), show_damage ? "hide the damage" : "show the damage", show_damage)
	if overlay.activated {
		show_damage = !show_damage
		system.log("interface_elements: the damage is ", show_damage ? "shown" : "hidden")
	}
	interface.cell_text(frame, interface.column_take(&column, 16), "a frame draws only its damage", graphics.colors.dim, .Left, interface.FONT_INTERFACE)
	// The damage of the last frame, as outlines of 2 pixels over the window.
	// They are records: when the damage stays the same, they do not damage.
	if show_damage {
		for rectangle in last_damage.rectangles[:last_damage.count] {
			width, height := rectangle.right - rectangle.left, rectangle.bottom - rectangle.top
			interface.draw_rectangle(frame.table, rectangle.left, rectangle.top, width, 2, graphics.colors.machine)
			interface.draw_rectangle(frame.table, rectangle.left, rectangle.bottom - 2, width, 2, graphics.colors.machine)
			interface.draw_rectangle(frame.table, rectangle.left, rectangle.top, 2, height, graphics.colors.machine)
			interface.draw_rectangle(frame.table, rectangle.right - 2, rectangle.top, 2, height, graphics.colors.machine)
		}
	}
	// The action bar, last: its list opens over the cards.
	items := bar_items()
	return interface.action_bar(frame, {0, HEIGHT - interface.ACTION_BAR_ROW_HEIGHT, WIDTH, interface.ACTION_BAR_ROW_HEIGHT}, items[:], &bar)
}

// frame_draw builds and draws one frame. The key of an item that a press
// ran goes into the input of the next frame, the way of a typed key.
frame_draw :: proc "contextless" (window: ^display.Window) {
	frame := interface.window_frame_start(&window_memory, window)
	bar_result := build(&frame, frames)
	interface.window_frame_end(&window_memory.drawing, &frame, window)
	if bar_result.ran {
		interface.input_key_add(&window_memory.drawing.input, bar_result.run)
	}
	last_damage = window_memory.drawing.damage
	frames += 1
}

// measure builds the window and compares it with the frame before, in one
// case: nothing changed, one number changed, or everything moved.
measure :: proc "contextless" (name: string, number_before, number_now: u64, move: bool) {
	ROUNDS :: 100
	before := interface.Draw_Table{records = window_memory.records_before[:], text = window_memory.text_before[:], interface_font = display.interface_font_of()}
	now := interface.Draw_Table{records = window_memory.records_now[:], text = window_memory.text_now[:], interface_font = display.interface_font_of()}
	state: interface.Interface_State
	input: interface.Input
	difference, rectangles: u64
	damage: interface.Damage
	for _ in 0 ..< ROUNDS {
		moved = false
		frame := interface.frame_begin(&before, &state, &input)
		build(&frame, number_before)
		interface.frame_end(&frame)
		moved = move
		frame = interface.frame_begin(&now, &state, &input)
		build(&frame, number_now)
		interface.frame_end(&frame)
		damage = {}
		start := system.nanoseconds()
		interface.damage_by_difference(&before, &now, &damage)
		difference += system.nanoseconds() - start
		rectangles = u64(damage.count)
	}
	moved = false
	bounds := interface.damage_bounds(&damage)
	area := u64(max(bounds.right - bounds.left, 0) * max(bounds.bottom - bounds.top, 0))
	system.log("interface_elements: ", name, ": ", u64(now.record_count), " records, ", rectangles, " damage rectangles, ", area * 100 / (WIDTH * HEIGHT), " % of the window, the difference in ", difference / ROUNDS / 100 / 10, ".", difference / ROUNDS / 100 % 10, " us")
}

// measure_fonts gives the time of one whole frame of the window, built and
// drawn into the window with no comparison, in the font of the cells and
// in the interface font: the least of ROUNDS rounds, so that a round that
// the host stops in its middle does not count. The window shows the frame
// that frame_draw draws after it.
measure_fonts :: proc "contextless" (window: ^display.Window) {
	ROUNDS :: 20
	interface_font := display.interface_font_of()
	fonts := [2]^display.Interface_Font{nil, interface_font}
	least := [2]u64{max(u64), max(u64)}
	for font, index in fonts {
		if index == 1 && font == nil {
			break
		}
		for _ in 0 ..< ROUNDS {
			table := interface.Draw_Table{records = window_memory.records_now[:], text = window_memory.text_now[:], interface_font = font}
			state: interface.Interface_State
			input: interface.Input
			start := system.nanoseconds()
			frame := interface.frame_begin(&table, &state, &input)
			build(&frame, 7)
			interface.frame_end(&frame)
			graphics.clear(window.canvas, graphics.colors.background)
			interface.execute(&table, window.canvas)
			least[index] = min(least[index], system.nanoseconds() - start)
		}
	}
	if interface_font == nil {
		system.log("interface_elements: one whole frame, built and drawn (the least of 20): the font of the cells ", least[0] / 1000, " us; no interface font")
		return
	}
	system.log("interface_elements: one whole frame, built and drawn (the least of 20): the font of the cells ", least[0] / 1000, " us, the interface font ", least[1] / 1000, " us")
}

// entry opens the window, runs the four measures of the damage by
// difference and the measure of one whole frame, writes them on the log,
// then draws a frame at each event of the window until the program is
// stopped. With no window, it stops with the code 1.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "interface_elements")
	if !ok {
		system.stop(1)
	}
	measure("nothing changed", 7, 7, false)
	measure("one number changed", 7, 8, false)
	measure("everything moved", 7, 7, true)
	measure_fonts(&window)
	// The whole frame, drawn with no comparison, then a frame where only
	// the counters changed, drawn in its damage. The surface has two
	// pictures, and the first frame of each one is whole: the third frame
	// is the first that is drawn in its damage, the changes of two frames.
	frame_draw(&window)
	whole := window_memory.drawing.draw_time
	frame_draw(&window)
	frame_draw(&window)
	system.log("interface_elements: ok, the whole frame drawn in ", whole / 1000, " us; the next frame drawn in its ", u64(window_memory.drawing.damage.count), " damage rectangles in ", window_memory.drawing.draw_time / 1000, " us")
	deadline := system.time()
	for {
		deadline += TICK
		display.wait(&window, deadline)
		interface.window_events(&window_memory.drawing, &window)
		frame_draw(&window)
	}
}
