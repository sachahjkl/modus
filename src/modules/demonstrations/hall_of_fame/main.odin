// The hall of fame: the people whose work inspired modus, each on a card
// (src/md/features/hall_of_fame.md).
//
// **What it is for.** It names the work that this system learned from:
// the languages, the tools, the engines and the ways of programming that
// shaped it. A card has the name of a person and one line on what they
// made. A card with a portrait has the credit of the picture under it: its
// author and its license. A person with no picture under a free license
// has a card with no picture.
//
// **What a reader sees.** Start it from the start menu, or with
// `start("hall_of_fame")` in the console. Three columns of cards, in whole
// rows. The arrows, Home and End move the chosen card; a press of the
// pointer on a card chooses it. The view moves by whole rows to keep the
// chosen card in it, and its scroll bar moves it too. The log gets
// `hall_of_fame: ok, the first frame drew <count> of the 16 people in <time> us`
// after the first frame, and `hall_of_fame: chose <name>` at each choice.
//
// **Its grants**: none. A window is all that it needs.
package hall_of_fame

import "modus:support/display"
import "modus:support/graphics"
import "modus:support/interface"
import "modus:support/system"

WIDTH :: 1000
HEIGHT :: 696
MARGIN :: 8 // Around the header, the cards and the scroll bar.
COLUMNS :: 3
CARD_WIDTH :: 312
GAP :: graphics.GAP // Between two cards, across and down.
PADDING :: graphics.MARGIN // Inside a card, on each side.
LINE :: interface.LINE
TEXT_GAP :: 8 // Between the name and the line, and between the portrait and its credit.
HEADER_Y :: 8
GRID_TOP :: 32 // The first row of cards starts under the header.
VIEW_HEIGHT :: HEIGHT - GRID_TOP - MARGIN // The rows of cards are inside it.
SCROLL_BAR_X :: WIDTH - MARGIN - interface.SCROLL_BAR_THICKNESS
#assert(MARGIN + COLUMNS * CARD_WIDTH + COLUMNS * GAP <= SCROLL_BAR_X)
CREDIT_ROOM :: CARD_WIDTH - 2 * PADDING // The credit takes the whole width of the card, under the portrait.

TITLE :: "Hall of fame"
CAPTION :: "the people whose work inspired modus"
HINT :: "arrows, Home, End or the pointer: choose a person"

// The portraits, in the order of their pixels in portrait_pixels. The
// pixels are made by `modustool portraits` from the pictures and the
// credits of resources/hall_of_fame.
Portrait :: enum u8 {
	None,
	Jonathan_Blow,
	Theprimeagen,
	Andreas_Kling,
	Linus_Torvalds,
	John_Carmack,
}
PORTRAIT_COUNT :: int(max(Portrait)) // None has no pixels.
PORTRAIT_WIDTH :: 96
PORTRAIT_HEIGHT :: 128
PORTRAIT_PIXELS :: PORTRAIT_WIDTH * PORTRAIT_HEIGHT

// One person of the hall of fame. A person with a portrait has the credit
// of the picture, as resources/hall_of_fame/CREDITS.md writes it: a host
// test of the modus tool checks that both texts are here.
Person :: struct {
	name:           string,
	work:           string, // One line on what the person made.
	portrait:       Portrait,
	credit_author:  string, // Who made the picture.
	credit_license: string, // The license of the picture.
}

@(rodata)
people := [?]Person {
	{name = "Casey Muratori", work = "Handmade Hero, Molly Rocket, and the spread of the immediate-mode interface."},
	{name = "Jonathan Blow", work = "Braid, The Witness, Order of the Sinking Star, and the language Jai.", portrait = .Jonathan_Blow, credit_author = "The producers of the video", credit_license = "All rights reserved by its producers; used as a credited frame"},
	{name = "United States Graphics Company", work = "Engineering graphics, and the typeface Berkeley Mono."},
	{name = "ThePrimeagen (Michael Paulson)", work = "Videos and streams about programming.", portrait = .Theprimeagen, credit_author = "Tessa Bury", credit_license = "CC BY 4.0"},
	{name = "Ginger Bill (Bill Hall)", work = "Odin, the language that modus is written in."},
	{name = "Dax Raad", work = "OpenCode, the open source coding agent, with its team."},
	{name = "Andreas Kling", work = "Ladybird, an independent browser engine written from scratch in the open, and SerenityOS.", portrait = .Andreas_Kling, credit_author = "London Web Standards", credit_license = "CC BY 3.0"},
	{name = "Ryan Fleury", work = "The RAD Debugger, and its immediate-mode interface."},
	{name = "Fabrice Bellard", work = "QEMU, FFmpeg and QuickJS. modus runs its tests in QEMU."},
	{name = "Alexander Borisov", work = "Lexbor, the HTML parser."},
	{name = "Linus Torvalds", work = "Linux and Git.", portrait = .Linus_Torvalds, credit_author = "Krd (photo), Von Sprat (crop)", credit_license = "CC BY-SA 4.0"},
	{name = "Kit Langton", work = "Videos about programming, and libraries for Scala."},
	{name = "Carson Gross", work = "htmx, and hypermedia systems."},
	{name = "John Carmack", work = "Doom, Quake, and the id Tech engines.", portrait = .John_Carmack, credit_author = "RoboSabs", credit_license = "CC0"},
	{name = "Tsoding (Alexey Kutepov)", work = "Programming streams, written from scratch."},
	{name = "bea4dev", work = "ShojiWM, a Wayland compositor that TypeScript customises, and AntiWebUI, a native interface toolkit that the GPU draws."},
}
PERSON_COUNT :: len(people)
ROW_COUNT :: (PERSON_COUNT + COLUMNS - 1) / COLUMNS

// The places of the texts of one card, measured in the font that draws
// them: no text is cut, and the card is as tall as its lines.
Card_Shape :: struct {
	portrait:      bool, // The card shows a portrait, with its credit under it.
	text_x:        int, // The left side of the name and of the line, from the left side of the card.
	text_room:     int, // The width of the name and of the line.
	name_lines:    int,
	work_lines:    int,
	author_lines:  int,
	license_lines: int,
	top_height:    int, // The portrait and the texts beside it, or the texts alone.
	height:        int, // The whole card.
}

// The pixels of the portraits, one after the other: the one picture
// memory of the draw tables, which the drawing module reads in place.
portrait_pixels: [PORTRAIT_COUNT * PORTRAIT_PIXELS]graphics.Color
portrait_ready: [Portrait]bool // The pixels of the portrait have the size of a portrait.
picture_memories: [1][]graphics.Color
credit_authors: [PERSON_COUNT]interface.Text_Builder // "Picture: <author>", made once.
shapes: [PERSON_COUNT]Card_Shape
row_heights: [ROW_COUNT]int // Each card of a row has the height of the tallest one.

window_memory: interface.Window_Memory(512, 8192)

chosen: int // The chosen card.
first_row: int // The first row of the view.

// portraits_prepare copies the pixels of each portrait into the picture
// memory. A file with another size is a fault of the build: its person
// gets a card with no picture, and the log says so.
portraits_prepare :: proc "contextless" () {
	sources := #partial [Portrait][]u32 {
		.Jonathan_Blow  = #load("portraits/jonathan_blow.pixels", []u32),
		.Theprimeagen   = #load("portraits/theprimeagen.pixels", []u32),
		.Andreas_Kling  = #load("portraits/andreas_kling.pixels", []u32),
		.Linus_Torvalds = #load("portraits/linus_torvalds.pixels", []u32),
		.John_Carmack   = #load("portraits/john_carmack.pixels", []u32),
	}
	for source, portrait in sources {
		if portrait == .None {
			continue
		}
		if len(source) != PORTRAIT_PIXELS {
			system.log("hall_of_fame: the portrait ", u64(portrait), " has ", u64(len(source)), " pixels, not ", u64(PORTRAIT_PIXELS), ": its card shows no picture")
			continue
		}
		first := (int(portrait) - 1) * PORTRAIT_PIXELS
		copy(portrait_pixels[first:][:PORTRAIT_PIXELS], source)
		portrait_ready[portrait] = true
	}
	for person, index in people {
		interface.text_put(&credit_authors[index], "Picture: ")
		interface.text_put(&credit_authors[index], person.credit_author)
	}
}

// portrait_canvas gives the pixels of one portrait in the picture memory.
portrait_canvas :: proc "contextless" (portrait: Portrait) -> graphics.Canvas {
	first := (int(portrait) - 1) * PORTRAIT_PIXELS
	return {pixels = raw_data(portrait_pixels[first:]), width = PORTRAIT_WIDTH, height = PORTRAIT_HEIGHT, stride = PORTRAIT_WIDTH}
}

// shapes_measure measures the texts of each card in the font that the
// table draws them in, and gives each row the height of its tallest card.
// A new font changes the widths, so each frame measures again: the cards
// are few.
shapes_measure :: proc "contextless" (table: ^interface.Draw_Table) {
	row_heights = {}
	for person, index in people {
		shape := &shapes[index]
		shape^ = {portrait = person.portrait != .None && portrait_ready[person.portrait], text_x = PADDING}
		if shape.portrait {
			shape.text_x = PADDING + PORTRAIT_WIDTH + PADDING
		}
		shape.text_room = CARD_WIDTH - shape.text_x - PADDING
		shape.name_lines = interface.text_wrapped_line_count(table, interface.FONT_INTERFACE_BOLD, person.name, shape.text_room)
		shape.work_lines = interface.text_wrapped_line_count(table, interface.FONT_INTERFACE, person.work, shape.text_room)
		shape.top_height = (shape.name_lines + shape.work_lines) * LINE + TEXT_GAP
		shape.height = PADDING + shape.top_height + PADDING
		if shape.portrait {
			shape.top_height = max(shape.top_height, PORTRAIT_HEIGHT)
			shape.author_lines = interface.text_wrapped_line_count(table, interface.FONT_INTERFACE, interface.text_of(&credit_authors[index]), CREDIT_ROOM)
			shape.license_lines = interface.text_wrapped_line_count(table, interface.FONT_INTERFACE, person.credit_license, CREDIT_ROOM)
			shape.height = PADDING + shape.top_height + TEXT_GAP + (shape.author_lines + shape.license_lines) * LINE + PADDING
		}
		row := index / COLUMNS
		row_heights[row] = max(row_heights[row], shape.height)
	}
}

// visible_rows_from gives the count of the whole rows that the view holds
// from a first row. A row taller than the view is shown alone.
visible_rows_from :: proc "contextless" (first: int) -> (count: int) {
	used := 0
	for row in first ..< ROW_COUNT {
		needed := row_heights[row]
		if count > 0 {
			needed += GAP
			if used + needed > VIEW_HEIGHT {
				break
			}
		}
		used += needed
		count += 1
	}
	return
}

// last_first_row gives the first row of the view that shows the last row:
// the view goes no further down.
last_first_row :: proc "contextless" () -> int {
	for first in 0 ..< ROW_COUNT {
		if first + visible_rows_from(first) == ROW_COUNT {
			return first
		}
	}
	return ROW_COUNT - 1
}

// card_place gives the area of a card in the view, or false when its row
// is not in the view.
card_place :: proc "contextless" (index: int) -> (area: interface.Area, shown: bool) {
	row := index / COLUMNS
	if row < first_row || row >= first_row + visible_rows_from(first_row) {
		return {}, false
	}
	y := GRID_TOP
	for above in first_row ..< row {
		y += row_heights[above] + GAP
	}
	return {MARGIN + index % COLUMNS * (CARD_WIDTH + GAP), y, CARD_WIDTH, row_heights[row]}, true
}

// choose_by_input moves the chosen card by the keys of the frame and by a
// press of the pointer on a card of the view that the reader saw.
choose_by_input :: proc "contextless" (frame: ^interface.Frame) {
	input := frame.input
	if input.pressed && input.pointer_known {
		for index in 0 ..< PERSON_COUNT {
			if area, shown := card_place(index); shown && interface.area_contains(area, input.press_x, input.press_y) {
				chosen = index
			}
		}
	}
	for &key in input.keys[:input.key_count] {
		if key.taken {
			continue
		}
		key.taken = true
		switch key.code {
		case display.KEY_LEFT:
			chosen = max(chosen - 1, 0)
		case display.KEY_RIGHT:
			chosen = min(chosen + 1, PERSON_COUNT - 1)
		case display.KEY_UP:
			if chosen >= COLUMNS {
				chosen -= COLUMNS
			}
		case display.KEY_DOWN:
			if chosen / COLUMNS < ROW_COUNT - 1 {
				chosen = min(chosen + COLUMNS, PERSON_COUNT - 1)
			}
		case display.KEY_HOME:
			chosen = 0
		case display.KEY_END:
			chosen = PERSON_COUNT - 1
		case:
			key.taken = false
		}
	}
}

// view_show_chosen moves the view by whole rows until the row of the
// chosen card is in it.
view_show_chosen :: proc "contextless" () {
	row := chosen / COLUMNS
	if row < first_row {
		first_row = row
	}
	for row >= first_row + visible_rows_from(first_row) {
		first_row += 1
	}
}

// header_draw draws the title, then the caption and the keys when each
// one has its whole width: a text is whole or absent.
header_draw :: proc "contextless" (table: ^interface.Draw_Table) {
	after := interface.draw_text(table, MARGIN, HEADER_Y, TITLE, graphics.colors.text, interface.FONT_INTERFACE_BOLD)
	caption_x := after + 16
	caption_end := caption_x + interface.text_measured_width(table, interface.FONT_INTERFACE, CAPTION)
	hint_x := WIDTH - MARGIN - interface.text_measured_width(table, interface.FONT_INTERFACE, HINT)
	if caption_end <= WIDTH - MARGIN {
		interface.draw_text(table, caption_x, HEADER_Y, CAPTION, graphics.colors.dim, interface.FONT_INTERFACE)
	}
	if caption_end + 16 <= hint_x {
		interface.draw_text(table, hint_x, HEADER_Y, HINT, graphics.colors.dim, interface.FONT_INTERFACE)
	}
}

// card_draw draws one card: the surface of a card with a border of 1
// pixel, or of 2 pixels in the chosen blue for the chosen card; the
// portrait with its credit under it; the name and the line.
card_draw :: proc "contextless" (frame: ^interface.Frame, index: int, area: interface.Area) {
	table := frame.table
	person := people[index]
	shape := &shapes[index]
	border := 1
	if index == chosen {
		border = 2
		interface.draw_rectangle(table, area.x, area.y, area.width, area.height, graphics.colors.chosen)
	} else {
		interface.draw_vertical_gradient(table, area.x, area.y, area.width, area.height, graphics.shade(graphics.colors.dim, 28), graphics.shade(graphics.colors.dim, 14))
	}
	interface.draw_vertical_gradient(table, area.x + border, area.y + border, area.width - 2 * border, area.height - 2 * border, graphics.colors.card_top, graphics.colors.card_bottom)
	interface.element_name(frame, area, person.name)

	text_x := area.x + shape.text_x
	text_y := area.y + PADDING
	interface.draw_text_wrapped(table, text_x, text_y, shape.text_room, person.name, graphics.colors.text, interface.FONT_INTERFACE_BOLD)
	text_y += shape.name_lines * LINE + TEXT_GAP
	interface.draw_text_wrapped(table, text_x, text_y, shape.text_room, person.work, graphics.colors.text, interface.FONT_INTERFACE)
	if !shape.portrait {
		return
	}
	interface.draw_picture(table, area.x + PADDING, area.y + PADDING, portrait_canvas(person.portrait), 1)
	credit_y := area.y + PADDING + shape.top_height + TEXT_GAP
	interface.draw_text_wrapped(table, area.x + PADDING, credit_y, CREDIT_ROOM, interface.text_of(&credit_authors[index]), graphics.colors.dim, interface.FONT_INTERFACE)
	credit_y += shape.author_lines * LINE
	interface.draw_text_wrapped(table, area.x + PADDING, credit_y, CREDIT_ROOM, person.credit_license, graphics.colors.dim, interface.FONT_INTERFACE)
}

// build describes the whole window for one frame, and gives the count of
// the cards that it drew.
build :: proc "contextless" (frame: ^interface.Frame) -> (drawn: int) {
	table := frame.table
	shapes_measure(table)
	first_row = min(first_row, last_first_row())
	before := chosen
	choose_by_input(frame)
	if chosen != before {
		view_show_chosen()
		system.log("hall_of_fame: chose ", people[chosen].name)
	}

	interface.background(frame, {0, 0, WIDTH, HEIGHT})
	header_draw(table)
	// The scroll bar shows the rows: the view can start at each row from
	// the first to the last first row.
	last := last_first_row()
	if last > 0 {
		rows := interface.Scroll_Range{total = ROW_COUNT, visible = ROW_COUNT - last, first = first_row}
		// The wheel over the cards moves the rows too.
		cards_view := interface.Area{MARGIN, GRID_TOP, SCROLL_BAR_X - MARGIN, VIEW_HEIGHT}
		moved := interface.scroll_bar(frame, {SCROLL_BAR_X, GRID_TOP, interface.SCROLL_BAR_THICKNESS, VIEW_HEIGHT}, interface.identity("people"), .Vertical, rows, {}, "people", cards_view)
		if moved.changed {
			first_row = moved.first
		}
	}
	for index in 0 ..< PERSON_COUNT {
		if area, shown := card_place(index); shown {
			card_draw(frame, index, area)
			drawn += 1
		}
	}
	return
}

// entry opens the window, prepares the portraits, then draws a frame at
// each event of the window until the process is stopped. With no window,
// it stops with the code 1.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "hall_of_fame")
	if !ok {
		system.stop(1)
	}
	portraits_prepare()
	picture_memories[0] = portrait_pixels[:]
	window_memory.drawing.now.picture_memories = picture_memories[:]
	window_memory.drawing.before.picture_memories = picture_memories[:]
	logged := false
	for {
		frame := interface.window_frame_start(&window_memory, &window)
		drawn := build(&frame)
		interface.window_frame_end(&window_memory.drawing, &frame, &window)
		// A frame that the compositor did not take is drawn at the next
		// wake: the line says what the screen has.
		if !logged && !window_memory.drawing.late {
			logged = true
			system.log("hall_of_fame: ok, the first frame drew ", u64(drawn), " of the ", u64(PERSON_COUNT), " people in ", window_memory.drawing.draw_time / 1000, " us")
		}
		deadline: u64 = system.WAIT_FOREVER
		if time, due := interface.window_scroll_bar_wake(&window_memory.drawing); due {
			deadline = time
		}
		display.wait(&window, deadline)
		interface.window_events(&window_memory.drawing, &window)
	}
}
