package inspect

import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "internal:inspect/addresses"
import "modus:display"
import "modus:graphics"
import "modus:interface"
import "modus:layout"
import "modus:system"

// The window follows docs/DESIGN.md: cards with a title in the accent of
// their concept and a caption that names their record, rectangles only, the
// grid of 8 pixels, names in the dim color and values in the text color. A
// value that changed since the sample before is in the color of the boot
// program for one sample; a word says the same fact where a color does.

WIDTH :: 1000
HEIGHT :: 704
// The least budget of 2048 pages, in which it ran before it stated its
// window, less that window at the scale 1 (1375 pages): its module, its
// stack, its tables and its glyph memory. The tool counts the window at
// the largest scale (docs/MODULE_CONTRACT.md, "The floor of a module").
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 673, window_width = WIDTH, window_height = HEIGHT}

LINE :: graphics.LINE_HEIGHT
// The lengths of the layout at the start of the window, in logical pixels.
// Each place comes from the layout tree (inspect_layout), from the size
// that the window has now.
LIST_WIDTH :: 208 // The title of the card and the name of its record, whole, in the interface font.
FILTER_HEIGHT :: 24 // The line of the filter, and the room under it.
SAMPLE_HEIGHT :: 80 // A line of room, then the four lines of the sample under the rows.
SAMPLE_TOP :: 16
LIST_MORE_LINES :: 2 // The lines that say how many rows the list does not show.
MAP_HEIGHT :: 336
MODULES_WIDTH :: 296
BAND_HEIGHT :: 40
// The longest name of a kind, "module constants", then a space.
KIND_ROOM :: 17 * graphics.CELL_WIDTH

// The columns of the list of the processes: the name, the mark of its
// state, its slot.
List_Column :: enum u8 {
	Name  = 0,
	State = 1,
	Slot  = 2,
}

// The columns of the table of the mappings. Space keeps the numbers of the
// pages apart from the bar of the pages with a frame.
Mapping_Column :: enum u8 {
	Address = 0,
	Pages   = 1,
	Space   = 2,
	Frame   = 3,
	Kind    = 4,
	Rights  = 5,
	Shared  = 6,
}

// The columns of the table of the threads.
Thread_Column :: enum u8 {
	Number  = 0,
	State   = 1,
	Runs    = 2,
	Weight  = 3,
	Request = 4,
	Lag     = 5,
	Time    = 6,
}

// The columns of a row of the bytes of inspect: its address, its 16 bytes
// in two halves, and their characters.
Hex_Column :: enum u8 {
	Address    = 0,
	Bytes      = 1,
	Characters = 2,
}

// The widths of the columns: each fixed but the one that takes the room
// left, so a wider window gives it to the text that needs it.
@(rodata)
list_column_widths := [List_Column]layout.Table_Column {
	.Name  = {weight = 1, least = 48},
	.State = {width = 16},
	.Slot  = {width = 24},
}

@(rodata)
mapping_column_widths := [Mapping_Column]layout.Table_Column {
	.Address = {width = 256},
	.Pages   = {width = 80},
	.Space   = {width = 16},
	.Frame   = {width = 160},
	.Kind    = {weight = 1, least = KIND_ROOM},
	.Rights  = {width = 40},
	.Shared  = {width = 48},
}

// The bytes keep 24 pixels each, with 8 between the halves and a space
// before the characters; the characters keep 8 pixels each.
@(rodata)
hex_column_widths := [Hex_Column]layout.Table_Column {
	.Address    = {weight = 1, least = 200},
	.Bytes      = {width = 16 * 24 + 24},
	.Characters = {width = 16 * graphics.CELL_WIDTH},
}

@(rodata)
thread_column_widths := [Thread_Column]layout.Table_Column {
	.Number  = {width = 24},
	.State   = {width = 72},
	.Runs    = {width = 56},
	.Weight  = {width = 48},
	.Request = {width = 72},
	.Lag     = {width = 88},
	.Time    = {weight = 1, least = 64},
}

// The places of the window that the draw reads after the solve. The
// columns are from the left of the content of their card.
Inspect_Places :: struct {
	list_card:       interface.Area,
	list_rows:       interface.Area, // The rows of the list, under its filter.
	list_sample:     interface.Area, // The lines of the cost of one sample.
	list_lines:      int, // The lines that the rows of the list take at most.
	map_card:        interface.Area,
	low_row:         interface.Area, // The modules and the threads, or the bytes of inspect in their place.
	modules_card:    interface.Area,
	side_card:       interface.Area, // The threads, or the stop report.
	list_columns:    [List_Column]layout.Table_Column_Place,
	mapping_columns: [Mapping_Column]layout.Table_Column_Place,
	thread_columns:  [Thread_Column]layout.Table_Column_Place,
	hex_columns:     [Hex_Column]layout.Table_Column_Place,
}

// The places of the last frame: the press of the pointer finds its row of
// the list in the places that the principal saw.
places: Inspect_Places

// The layout tree of a frame. A global: the tree is too large for the stack.
layout_tree: layout.Box_Tree

// The colors and the spacing of the frame, from the appearance in force.
element_tokens: layout.Element_Tokens

// The window is built with the interface package (docs/INTERFACE.md): its
// draw table holds the records of a frame, and a sample that changes few
// values damages only their places.
window_memory: interface.Window_Memory(2048, 32768)
frame_table: ^interface.Draw_Table // The table of the frame that draw builds.

kind_color :: proc "contextless" (kind: addresses.Kind) -> graphics.Color {
	switch kind {
	case .Module_Code:
		return element_tokens.expected
	case .Module_Constants:
		return graphics.shade(element_tokens.expected, 72)
	case .Module_Data:
		return graphics.shade(element_tokens.expected, 50)
	case .Thread_Area:
		return graphics.colors.kernel
	case .Device:
		return graphics.colors.machine
	case .Shared:
		return graphics.shade(graphics.colors.memory, 140)
	case .Memory:
		return graphics.colors.memory
	}
	return graphics.colors.not_usable
}

state_color :: proc "contextless" (state: op.Process_State) -> graphics.Color {
	switch state {
	case .Stopped:
		return element_tokens.failed
	case .Created:
		return graphics.colors.boot_program
	case .None, .Ready, .Waiting:
		// A process that runs, or waits, has the color of a process.
	}
	return element_tokens.expected
}

// hash_color gives the color of a module from its hash.
hash_color :: proc "contextless" (hash: [32]u8) -> graphics.Color {
	return graphics.mix(graphics.rgb(u32(hash[0]) | 0x40, u32(hash[1]) | 0x40, u32(hash[2]) | 0x40), element_tokens.text, 64)
}

// text draws parts at (x, y) of an area, and gives the x after them.
text :: proc "contextless" (area: interface.Area, x, y: int, color: graphics.Color, parts: ..system.Part) -> int {
	buffer: [160]u8
	return interface.draw_text(frame_table, area.x + x, area.y + y, system.format(buffer[:], ..parts), color) - area.x
}

// right draws parts that end at x of an area.
right :: proc "contextless" (area: interface.Area, x, y: int, color: graphics.Color, parts: ..system.Part) {
	buffer: [64]u8
	interface.draw_text_right(frame_table, area.x + x, area.y + y, system.format(buffer[:], ..parts), color)
}

// fill draws a rectangle at (x, y) of an area.
fill :: proc "contextless" (area: interface.Area, x, y, width, height: int, color: graphics.Color) {
	interface.draw_rectangle(frame_table, area.x + x, area.y + y, width, height, color)
}

// write draws a text at (x, y) of an area, and gives the x after it.
write :: proc "contextless" (area: interface.Area, x, y: int, characters: string, color: graphics.Color) -> int {
	return interface.draw_text(frame_table, area.x + x, area.y + y, characters, color) - area.x
}

// card_at draws a card in the area that the layout gave it, and gives the
// area of its content.
card_at :: proc "contextless" (frame: ^interface.Frame, area: interface.Area, title, caption: string, accent: graphics.Color) -> interface.Area {
	return interface.card(frame, area, title, caption, accent)
}

// Layout_Builder adds boxes to a tree and keeps the first refusal, so that
// one check after the last box says whether the whole tree was built.
Layout_Builder :: struct {
	tree:   ^layout.Box_Tree,
	status: layout.Box_Status,
}

builder_open :: proc "contextless" (builder: ^Layout_Builder, description: layout.Box_Description) -> layout.Box_Index {
	index, status := layout.box_open(builder.tree, description)
	if builder.status == .Done {
		builder.status = status
	}
	return index
}

builder_add :: proc "contextless" (builder: ^Layout_Builder, description: layout.Box_Description) -> layout.Box_Index {
	index, status := layout.box_add(builder.tree, description)
	if builder.status == .Done {
		builder.status = status
	}
	return index
}

builder_close :: proc "contextless" (builder: ^Layout_Builder) {
	status := layout.box_close(builder.tree)
	if builder.status == .Done {
		builder.status = status
	}
}

// area_of gives the area of the interface package of a box that the
// solver placed.
area_of :: proc "contextless" (tree: ^layout.Box_Tree, index: layout.Box_Index) -> interface.Area {
	box := layout.box_of(tree, index)
	if box == nil {
		return {}
	}
	return {int(box.rect.x), int(box.rect.y), int(box.rect.width), int(box.rect.height)}
}

// A space of a height across the whole width.
spacer :: proc "contextless" (height: i32) -> layout.Box_Description {
	return {size = {.X = layout.fill(), .Y = layout.px(height)}}
}

// card_open opens the box of a card and adds the room of its title: the
// boxes added until card_close are its content, between its margins, as
// interface.card gives it.
card_open :: proc "contextless" (builder: ^Layout_Builder, width, height: layout.Size, tokens: layout.Element_Tokens) -> layout.Box_Index {
	index := builder_open(builder, {size = {.X = width, .Y = height}, child_axis = .Y, padding = {.X = tokens.margin, .Y = 0}})
	builder_add(builder, spacer(tokens.title))
	return index
}

// card_close adds the room under the content of a card, and closes it.
card_close :: proc "contextless" (builder: ^Layout_Builder, tokens: layout.Element_Tokens) {
	builder_add(builder, spacer(tokens.gap))
	builder_close(builder)
}

// A box that takes the room that its siblings leave.
filled :: proc "contextless" () -> layout.Box_Description {
	return {size = {.X = layout.fill(), .Y = layout.fill()}}
}

// inspect_layout builds and solves the layout tree of the window at a
// size: the list of the processes at the left; at the right the address
// space over the modules and the threads. ok false: the tree refused a box
// or a table refused its columns, and the caller keeps the places before.
inspect_layout :: proc "contextless" (width, height: int, tokens: layout.Element_Tokens) -> (laid_out: Inspect_Places, ok: bool) {
	tree := &layout_tree
	if width <= 0 || height <= 0 || width > layout.LENGTH_LIMIT || height > layout.LENGTH_LIMIT {
		return {}, false
	}
	gap := tokens.gap
	if layout.tree_begin(tree, i32(width), i32(height), {child_axis = .X, padding = {.X = gap, .Y = gap}, gap = gap}) != .Done {
		return {}, false
	}
	builder := Layout_Builder{tree = tree}
	list_card := card_open(&builder, layout.px(LIST_WIDTH), layout.fill(), tokens)
	list_content := builder_open(&builder, {size = {.X = layout.fill(), .Y = layout.fill()}, child_axis = .Y})
	builder_add(&builder, spacer(FILTER_HEIGHT))
	list_rows := builder_add(&builder, filled())
	list_sample := builder_add(&builder, spacer(SAMPLE_HEIGHT))
	builder_close(&builder)
	card_close(&builder, tokens)
	builder_open(&builder, {size = {.X = layout.fill(), .Y = layout.fill()}, child_axis = .Y, gap = gap})
	// The address space keeps its height, and the low row takes the rest:
	// a fill box shares a lack of room with each sibling that is not strict.
	map_card := card_open(&builder, layout.fill(), layout.px(MAP_HEIGHT), tokens)
	map_content := builder_add(&builder, filled())
	card_close(&builder, tokens)
	low_row := builder_open(&builder, {size = {.X = layout.fill(), .Y = layout.fill()}, child_axis = .X, gap = gap})
	modules_card := card_open(&builder, layout.px(MODULES_WIDTH), layout.fill(), tokens)
	builder_add(&builder, filled())
	card_close(&builder, tokens)
	side_card := card_open(&builder, layout.fill(), layout.fill(), tokens)
	side_content := builder_add(&builder, filled())
	card_close(&builder, tokens)
	builder_close(&builder)
	builder_close(&builder)
	if builder.status != .Done || layout.solve(tree) != .Done {
		return {}, false
	}
	laid_out = {
		list_card    = area_of(tree, list_card),
		list_rows    = area_of(tree, list_rows),
		list_sample  = area_of(tree, list_sample),
		map_card     = area_of(tree, map_card),
		low_row      = area_of(tree, low_row),
		modules_card = area_of(tree, modules_card),
		side_card    = area_of(tree, side_card),
	}
	laid_out.list_lines = laid_out.list_rows.height / LINE
	// The columns of each table, from the left of the content of its card.
	columns_rect :: proc "contextless" (tree: ^layout.Box_Tree, index: layout.Box_Index) -> layout.Rect {
		rect := tree.boxes[index].rect
		return {0, 0, rect.width, rect.height}
	}
	list_widths, mapping_widths, thread_widths, hex_widths := list_column_widths, mapping_column_widths, thread_column_widths, hex_column_widths
	if columns_place(&list_widths, &laid_out.list_columns, columns_rect(tree, list_content)) != .Done {
		return {}, false
	}
	if columns_place(&mapping_widths, &laid_out.mapping_columns, columns_rect(tree, map_content)) != .Done {
		return {}, false
	}
	if columns_place(&thread_widths, &laid_out.thread_columns, columns_rect(tree, side_content)) != .Done {
		return {}, false
	}
	// The card of the bytes takes the whole low row, between its margins.
	hex_rect := layout.Rect{0, 0, max(i32(laid_out.low_row.width) - 2 * tokens.margin, 0), i32(laid_out.low_row.height)}
	if columns_place(&hex_widths, &laid_out.hex_columns, hex_rect) != .Done {
		return {}, false
	}
	return laid_out, true
}

// columns_place gives the places of the columns of a table, each named by
// a member of its enum: table_columns takes slices, and an array indexed
// by an enum is not one.
columns_place :: proc "contextless" (widths: ^[$Column]layout.Table_Column, column_places: ^[Column]layout.Table_Column_Place, rect: layout.Rect) -> layout.Box_Status {
	count := len(widths^)
	return layout.table_columns(([^]layout.Table_Column)(widths)[:count], ([^]layout.Table_Column_Place)(column_places)[:count], rect, 0)
}

// column_end gives the right edge of a column: a number ends there.
column_end :: proc "contextless" (column: layout.Table_Column_Place) -> int {
	return int(column.x + column.width)
}

// changed says if a sample of the same process had another value.
changed :: proc "contextless" (now, before: u64) -> bool {
	return previous.slot == current.slot && now != before
}

// The first line of each row of the list, and at shown_count the count of
// the lines of all the rows: made when the list is read, not at each
// picture.
shown_row: []int // One more than the slots: tables_take.

// The width of the column of the names in which shown_row counted the
// lines: a frame whose column has another width counts them again.
shown_row_name_room: int

// list_rows_update counts the lines of the name of each row of the list, in
// the column of the names. A name wider than it goes on more lines
// (interface.text_wrap_line), and its row has the height of its lines.
list_rows_update :: proc "contextless" () {
	name_room := int(places.list_columns[.Name].width)
	shown_row_name_room = name_room
	line := 0
	for position in 0 ..< shown_count {
		shown_row[position] = line
		line += max(interface.text_wrapped_line_count(nil, {}, system.name_of(entries[shown[position]].name[:]), name_room), 1)
	}
	shown_row[shown_count] = line
}

// list_drawn_count gives the count of rows that the list shows: all of
// them when they fit, else the rows that leave room for the lines that
// count the others.
list_drawn_count :: proc "contextless" () -> int {
	if shown_row[shown_count] <= places.list_lines {
		return shown_count
	}
	drawn := 0
	for drawn < shown_count && shown_row[drawn + 1] <= places.list_lines - LIST_MORE_LINES {
		drawn += 1
	}
	return drawn
}

list_place :: proc "contextless" (x, y: int) -> (position: int, inside: bool) {
	card, rows := places.list_card, places.list_rows
	if x < card.x || x >= card.x + card.width || y < rows.y {
		return 0, false
	}
	line := (y - rows.y) / LINE
	for row in 0 ..< list_drawn_count() {
		if line >= shown_row[row] && line < shown_row[row + 1] {
			return row, true
		}
	}
	return 0, false
}

draw :: proc "contextless" (window: ^display.Window) {
	frame := interface.window_frame_start(&window_memory, window)
	frame_table = frame.table
	// graphics holds only members of the appearance: the tokens of the
	// standard contrast are the colors that the window drew with before.
	element_tokens, _ = layout.tokens_for(graphics.appearance, .Standard)
	// The size of the window now: a resize or a new scale moves each place.
	// A size that the tree refuses keeps the places before.
	if laid_out, laid_out_ok := inspect_layout(window.width, window.height, element_tokens); laid_out_ok {
		places = laid_out
	}
	if int(places.list_columns[.Name].width) != shown_row_name_room {
		list_rows_update()
	}
	interface.background(&frame, {0, 0, window.width, window.height})
	draw_list(&frame)
	if current.slot == 0 {
		inside := card_at(&frame, places.map_card, "ADDRESS SPACE", "op.Process_Mapping_Report", graphics.colors.memory)
		write(inside, 0, 0, "not known yet: choose a process in the list", element_tokens.text_dim)
	} else {
		draw_map(&frame)
	}
	if hex_view {
		draw_hex(&frame)
	} else {
		draw_modules(&frame)
		if current.stop.cause != 0 {
			draw_stop(&frame)
		} else {
			draw_threads(&frame)
		}
	}
	damage := interface.window_frame_end(&window_memory.drawing, &frame, window)
	samples_drawn += 1
	damage_total += u64(damage)
	if system.measure_run() && samples_drawn == 20 {
		system.log_fact(.Info, Interface_Measured{records = u64(window_memory.drawing.now.record_count), damage_rectangles = damage_total, build_time = value_kinds.Time_In_Microseconds(window_memory.drawing.build_time / 1000), difference_time = value_kinds.Time_In_Microseconds(window_memory.drawing.difference_time / 1000), draw_time = value_kinds.Time_In_Microseconds(window_memory.drawing.draw_time / 1000)})
	}
}

samples_drawn, damage_total: u64 // The measure of the damage of the first 20 frames.

draw_list :: proc "contextless" (frame: ^interface.Frame) {
	list_card := places.list_card
	inside := card_at(frame, list_card, "SLOTS", "Process_Report", element_tokens.expected)
	x := write(inside, 0, 0, "filter ", element_tokens.text_dim)
	x = write(inside, x, 0, string(filter[:filter_count]), element_tokens.text)
	fill(inside, x, 0, 8, 16, element_tokens.surface_track)
	columns := &places.list_columns
	rows_top := places.list_rows.y - inside.y
	drawn := list_drawn_count()
	for position in 0 ..< drawn {
		item := &entries[shown[position]]
		y := rows_top + shown_row[position] * LINE
		height := (shown_row[position + 1] - shown_row[position]) * LINE
		chosen := item.slot == selected_slot && item.process_serial == selected_process_serial
		// The row takes a press where list_place finds it; the name of its
		// process is its element name.
		interface.element_name(frame, {list_card.x, inside.y + y, list_card.width, height}, system.name_of(item.name[:]))
		if chosen {
			fill(inside, -8, y, inside.width + 8, height, element_tokens.surface_track)
			fill(inside, -8, y, 4, height, element_tokens.expected)
		}
		interface.draw_text_wrapped(frame_table, inside.x + int(columns[.Name].x), inside.y + y, int(columns[.Name].width), system.name_of(item.name[:]), chosen ? graphics.COLOR_WHITE : element_tokens.text)
		fill(inside, int(columns[.State].x) + 8, y + 5, 6, 6, state_color(item.state))
		right(inside, column_end(columns[.Slot]), y, element_tokens.text_dim, item.slot)
	}
	if drawn < shown_count {
		// The list never hides a row in silence: it counts the rows that it
		// does not show, and the filter reaches each of them.
		more: [64]u8
		interface.draw_text_wrapped(frame_table, inside.x, inside.y + rows_top + shown_row[drawn] * LINE, inside.width, system.format(more[:], "and ", u64(shown_count - drawn), " more: type a part of a name"), element_tokens.text_dim)
	}
	// The cost of one sample: measured, not estimated.
	y := places.list_sample.y - inside.y + SAMPLE_TOP
	text(inside, 0, y, element_tokens.text_dim, "one sample")
	right(inside, inside.width, y, element_tokens.text, current.nanoseconds / 1000, " us")
	text(inside, 0, y + LINE, element_tokens.text_dim, "kernel entries")
	right(inside, inside.width, y + LINE, element_tokens.text, current.entries)
	text(inside, 0, y + 2 * LINE, element_tokens.text_dim, frozen ? "frozen: space" : "4 samples in 1 s", "")
	right(inside, inside.width, y + 2 * LINE, frozen ? graphics.colors.boot_program : element_tokens.expected, frozen ? "frozen" : "live")
	text(inside, 0, y + 3 * LINE, element_tokens.text_dim, "tab: bytes")
}

// The parts of the band of the address space: two for each mapping, 48 KiB,
// which the stack of the window does not hold.
map_segments: [2 * op.MAPPING_REPORT_CAPACITY]addresses.Segment

draw_map :: proc "contextless" (frame: ^interface.Frame) {
	name := system.name_of(current.process.name[:])
	buffer: [64]u8
	inside := card_at(frame, places.map_card, "ADDRESS SPACE", system.format(buffer[:], "op.Process_Mapping_Report of ", name), graphics.colors.memory)
	mappings := current.mappings.mappings[:min(current.mappings.count, op.MAPPING_REPORT_CAPACITY)]
	modules := current.modules.modules[:min(current.modules.count, op.PROCESS_MODULE_CAPACITY)]
	pages, present, before_present: u64
	for &item in mappings {
		pages += item.page_count
		present += item.present
	}
	for &item in previous.mappings.mappings[:min(previous.mappings.count, op.MAPPING_REPORT_CAPACITY)] {
		before_present += item.present
	}
	x := text(inside, 0, 0, element_tokens.text, u64(len(mappings)))
	x = text(inside, x, 0, element_tokens.text_dim, " mappings  ")
	x = text(inside, x, 0, element_tokens.text, pages)
	x = text(inside, x, 0, element_tokens.text_dim, " pages mapped  ")
	x = text(inside, x, 0, changed(present, before_present) ? graphics.colors.boot_program : graphics.colors.memory, present)
	x = text(inside, x, 0, element_tokens.text_dim, " with a frame  ")
	x = text(inside, x, 0, state_color(current.process.state), current.process.state == .Stopped ? "stopped" : "runs")
	// The band: each mapping scaled by its pages, each gap folded.
	segments := &map_segments
	count := addresses.band(mappings, inside.width, 16, 4, segments[:])
	BAND_Y :: 24
	if len(mappings) == 0 {
		write(inside, 0, BAND_Y + 12, "no mapping: the kernel ended each mapping when the process stopped", element_tokens.text_dim)
	}
	for &segment in segments[:count] {
		if segment.mapping < 0 {
			// A folded gap: a part with no measure on this scale.
			interface.draw_folded_gap(frame.table, inside.x + segment.x, inside.y + BAND_Y, segment.width, BAND_HEIGHT)
			continue
		}
		item := mappings[segment.mapping]
		color := kind_color(addresses.kind_of(item, modules))
		width := max(segment.width - 1, 1)
		interface.draw_vertical_gradient(frame.table, inside.x + segment.x, inside.y + BAND_Y, width, BAND_HEIGHT - 6, graphics.shade(color, 125), graphics.shade(color, 78))
		// Under each block: the part of its pages that have a frame.
		fill(inside, segment.x, BAND_Y + BAND_HEIGHT - 4, width, 4, element_tokens.surface_track)
		fill(inside, segment.x, BAND_Y + BAND_HEIGHT - 4, int(u64(width) * item.present / max(item.page_count, 1)), 4, element_tokens.text)
	}
	// The kinds, as a legend.
	x = 0
	for kind in addresses.Kind {
		fill(inside, x, 76, 8, 8, kind_color(kind))
		x = write(inside, x + 12, 72, addresses.KIND_NAMES[kind], element_tokens.text_dim) + 8
	}
	// The table: one row for each mapping, in the columns of the layout.
	// The last two columns end at the right edge of the card, and the
	// column of the kind is never narrower than its longest name.
	TABLE_Y :: 96
	columns := &places.mapping_columns
	frame_x := int(columns[.Frame].x)
	write(inside, int(columns[.Address].x), TABLE_Y, "address", element_tokens.text_dim)
	right(inside, column_end(columns[.Pages]), TABLE_Y, element_tokens.text_dim, "pages")
	write(inside, frame_x, TABLE_Y, "with a frame", element_tokens.text_dim)
	write(inside, int(columns[.Kind].x), TABLE_Y, "kind", element_tokens.text_dim)
	write(inside, int(columns[.Rights].x), TABLE_Y, "rights", element_tokens.text_dim)
	rows := (inside.height - TABLE_Y - LINE) / LINE
	for &item, number in mappings {
		y := TABLE_Y + LINE + number * LINE
		if number == rows - 1 && len(mappings) > rows {
			text(inside, 0, y, element_tokens.text_dim, "and ", u64(len(mappings) - number), " mappings more: inspect.mappings() gives each one")
			break
		}
		writer := system.Writer{buffer = buffer[:]}
		address_write(&writer, item.address)
		kind := addresses.kind_of(item, modules)
		fill(inside, int(columns[.Address].x), y + 4, 8, 8, kind_color(kind))
		write(inside, int(columns[.Address].x) + 16, y, system.written(&writer), element_tokens.text)
		right(inside, column_end(columns[.Pages]), y, element_tokens.text, item.page_count)
		before := u64(0)
		if number < int(previous.mappings.count) && previous.mappings.mappings[number].address == item.address {
			before = previous.mappings.mappings[number].present
		} else {
			before = item.present
		}
		// The bar of the pages with a frame, then their count, which ends
		// before the column of the kind.
		fill(inside, frame_x, y + 4, 96, 8, element_tokens.surface_track)
		fill(inside, frame_x, y + 4, int(96 * item.present / max(item.page_count, 1)), 8, graphics.colors.memory)
		right(inside, column_end(columns[.Frame]) - 16, y, changed(item.present, before) ? graphics.colors.boot_program : element_tokens.text, item.present)
		write(inside, int(columns[.Kind].x), y, addresses.KIND_NAMES[kind], kind_color(kind))
		rights := [3]u8{'r', .Write in item.flags ? 'w' : '-', .Execute in item.flags ? 'x' : '-'}
		write(inside, int(columns[.Rights].x), y, string(rights[:]), element_tokens.text)
		if .Shared in item.flags {
			write(inside, int(columns[.Shared].x), y, "shared", element_tokens.text_dim)
		}
	}
}

draw_modules :: proc "contextless" (frame: ^interface.Frame) {
	inside := card_at(frame, places.modules_card, "MODULES", "op.Module_Report", element_tokens.expected)
	if current.slot == 0 {
		return
	}
	// The name has the room before the size, a number of at most five
	// digits and its unit; the base and the start of the hash have the
	// width of the card. Each goes on more lines when it is wider.
	name_room := max(inside.width - 16 - 10 * graphics.CELL_WIDTH, graphics.CELL_WIDTH)
	modules := current.modules.modules[:min(current.modules.count, op.PROCESS_MODULE_CAPACITY)]
	y := 0
	for &item, number in modules {
		name := "a module with no name"
		if entry := system.image_entry_of(image, item.hash); entry != nil {
			name = system.name_of(entry.name[:])
		}
		writer_buffer: [48]u8
		writer := system.Writer{buffer = writer_buffer[:]}
		system.write_number(&writer, item.base)
		system.write_part(&writer, "  ")
		system.write_hash(&writer, item.hash)
		place := system.written(&writer)
		lines := interface.text_wrapped_line_count(frame_table, {}, name, name_room) + interface.text_wrapped_line_count(frame_table, {}, place, inside.width - 16)
		if rest_line_needed(y, lines, number, len(modules), inside.height) {
			text(inside, 0, y, element_tokens.text_dim, "and ", u64(len(modules) - number), " more: inspect.modules()")
			break
		}
		fill(inside, 0, y + 4, 8, 8, hash_color(item.hash))
		right(inside, inside.width, y, element_tokens.text, item.size / 1024, " KiB")
		y += LINE * interface.draw_text_wrapped(frame_table, inside.x + 16, inside.y + y, name_room, name, element_tokens.text)
		y += LINE * interface.draw_text_wrapped(frame_table, inside.x + 16, inside.y + y, inside.width - 16, place, hash_color(item.hash))
	}
}

// rest_line_needed says if a row of `lines` lines at y does not fit in a
// card of a height, with one line kept under it when it is not the last
// row: the line that counts the rows that the card does not show. A card
// never ends its rows in silence.
rest_line_needed :: proc "contextless" (y, lines, number, count, height: int) -> bool {
	kept := number == count - 1 ? 0 : LINE
	return y + lines * LINE > height - kept
}

draw_threads :: proc "contextless" (frame: ^interface.Frame) {
	inside := card_at(frame, places.side_card, "THREADS", "op.Thread_Table_Report", graphics.colors.kernel)
	if current.slot == 0 {
		return
	}
	columns := &places.thread_columns
	state_x, runs_x := int(columns[.State].x), int(columns[.Runs].x)
	write(inside, int(columns[.Number].x), 0, "#", element_tokens.text_dim)
	write(inside, state_x, 0, "state", element_tokens.text_dim)
	write(inside, runs_x, 0, "runs", element_tokens.text_dim)
	right(inside, column_end(columns[.Weight]), 0, element_tokens.text_dim, "weight")
	right(inside, column_end(columns[.Request]), 0, element_tokens.text_dim, "req us")
	right(inside, column_end(columns[.Lag]), 0, element_tokens.text_dim, "lag")
	right(inside, column_end(columns[.Time]), 0, element_tokens.text_dim, "time ms")
	threads := current.threads.threads[:min(current.threads.count, op.THREAD_REPORT_CAPACITY)]
	y := LINE
	for &item, number in threads {
		// The second line of a thread: what it waits for, and its virtual
		// time. It goes on more lines when the number is long.
		wait := "no wait"
		if item.words != 0 {
			wait = item.deadline != 0 && item.deadline != op.WAIT_FOREVER ? "a word wait, with a deadline" : "a word wait"
		} else if item.queued != 0 {
			wait = "in the run queue"
		}
		second_buffer: [96]u8
		second := system.format(second_buffer[:], wait, "  virtual ", item.virtual)
		lines := 1 + interface.text_wrapped_line_count(frame_table, {}, second, inside.width - 24)
		if rest_line_needed(y, lines, number, len(threads), inside.height) {
			text(inside, 0, y, element_tokens.text_dim, "and ", u64(len(threads) - number), " more: inspect.threads()")
			break
		}
		before: op.Thread_Report
		for &other in previous.threads.threads[:min(previous.threads.count, op.THREAD_REPORT_CAPACITY)] {
			if other.number == item.number {
				before = other
			}
		}
		text(inside, int(columns[.Number].x), y, element_tokens.text, u64(item.number))
		fill(inside, state_x, y + 4, 8, 8, item.processor != 0 ? element_tokens.expected : graphics.colors.not_usable)
		write(inside, state_x + 16, y, item.processor != 0 ? "runs" : item.state == .Waiting ? "waits" : "ready", changed(u64(item.state) << 8 | u64(item.processor), u64(before.state) << 8 | u64(before.processor)) ? graphics.colors.boot_program : element_tokens.text)
		if item.processor != 0 {
			text(inside, runs_x, y, element_tokens.text, "cpu ", u64(item.processor - 1))
		} else {
			text(inside, runs_x, y, element_tokens.text_dim, "home ", u64(item.home))
		}
		right(inside, column_end(columns[.Weight]), y, element_tokens.text, u64(item.weight))
		right(inside, column_end(columns[.Request]), y, element_tokens.text, u64(item.request))
		right(inside, column_end(columns[.Lag]), y, element_tokens.text, item.lag)
		right(inside, column_end(columns[.Time]), y, changed(item.run_time, before.run_time) ? graphics.colors.boot_program : element_tokens.text, item.run_time)
		y += LINE
		y += LINE * interface.draw_text_wrapped(frame_table, inside.x + 24, inside.y + y, inside.width - 24, second, element_tokens.text_dim)
	}
	if current.threads.count == 0 {
		write(inside, 0, LINE, "no thread: the process ended", element_tokens.text_dim)
	}
}

draw_stop :: proc "contextless" (frame: ^interface.Frame) {
	inside := card_at(frame, places.side_card, "STOP REPORT", "op.Stop_Report: where it stopped", element_tokens.failed)
	stop := &current.stop
	buffer: [FRAME_NAME_CAPACITY]u8
	writer := system.Writer{buffer = buffer[:]}
	system.write_part(&writer, stop.vector == 14 ? "page fault: the address " : "fault: the address ")
	system.write_number(&writer, stop.address)
	if stop.hidden_value_count != 0 {
		system.write_part(&writer, "; values hidden: ")
		system.write_part(&writer, stop.hidden_value_count)
	}
	// Each text of the report has the width of the card, and each frame the
	// width after its number and its mark: a name with its file and its
	// line is wider than the card, so it goes on more lines, and the frame
	// under it starts under its last line.
	y := LINE * interface.draw_text_wrapped(frame_table, inside.x, inside.y, inside.width, system.written(&writer), element_tokens.failed)
	y += 8
	y += LINE * interface.draw_text_wrapped(frame_table, inside.x, inside.y + y, inside.width, "the stack trace, from the frame pointers:", element_tokens.text_dim)
	y += 8
	frames := stop.frames[:min(stop.frame_count, op.STOP_FRAME_CAPACITY)]
	for &stop_frame, number in frames {
		line := system.Writer{buffer = buffer[:]}
		if stop_frame.address == 0 {
			system.write_part(&line, "not code: the kernel gives no value of this frame")
		} else if name := frame_name(number); name != "" {
			system.write_part(&line, name)
		} else {
			address_write(&line, stop_frame.address, true)
		}
		place := system.written(&line)
		lines := interface.text_wrapped_line_count(frame_table, {}, place, inside.width - 40)
		if rest_line_needed(y, lines, number, len(frames), inside.height) {
			// The log has each frame: the line "inspect: <name> stopped:".
			interface.draw_text_wrapped(frame_table, inside.x, inside.y + y, inside.width, system.format(buffer[:], "and ", u64(len(frames) - number), " frames more: the log has each one"), element_tokens.text_dim)
			break
		}
		text(inside, 0, y, element_tokens.text_dim, u64(number))
		fill(inside, 24, y + 4, 8, 8, stop_frame.base != 0 ? hash_color(stop_frame.hash) : graphics.colors.not_usable)
		y += LINE * interface.draw_text_wrapped(frame_table, inside.x + 40, inside.y + y, inside.width - 40, place, number == 0 ? element_tokens.failed : element_tokens.text)
	}
}
