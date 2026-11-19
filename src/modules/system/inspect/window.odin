package inspect

import op "modus:contract/operation"
import "modus:private/inspect/addresses"
import "modus:support/display"
import "modus:support/graphics"
import "modus:support/interface"
import "modus:support/system"

// The window follows docs/DESIGN.md: cards with a title in the accent of
// their concept and a caption that names their record, rectangles only, the
// grid of 8 pixels, names in the dim color and values in the text color. A
// value that changed since the sample before is in the color of the boot
// program for one sample; a word says the same fact where a color does.

WIDTH :: 1000
HEIGHT :: 704

LINE :: graphics.LINE_HEIGHT
LIST_X :: 8
LIST_Y :: 8
LIST_WIDTH :: 208 // The title of the card and the name of its record, whole, in the interface font.
LIST_ROWS_Y :: LIST_Y + graphics.TITLE + 24 // The first row of the list, in the window.
// The box of the name of a process in the list: from the left of the card
// to the mark of its state. A name wider than it goes on more lines
// (interface.text_wrap_line), and its row has the height of its lines.
LIST_NAME_ROOM :: LIST_WIDTH - 2 * graphics.MARGIN - 40
// The lines of the list: the card without its title, the filter and the
// four lines of the sample under the rows.
LIST_LINES :: (HEIGHT - 16 - graphics.TITLE - 8 - 24 - 80) / LINE
LIST_MORE_LINES :: 2 // The lines that say how many rows the list does not show.
RIGHT_X :: LIST_X + LIST_WIDTH + 8
RIGHT_WIDTH :: WIDTH - RIGHT_X - 8
MAP_HEIGHT :: 336
LOW_Y :: 8 + MAP_HEIGHT + 8
LOW_HEIGHT :: HEIGHT - LOW_Y - 8
MODULES_WIDTH :: 296
BAND_HEIGHT :: 40

// The window is built with the interface package (docs/INTERFACE.md): its
// draw table holds the records of a frame, and a sample that changes few
// values damages only their places.
window_memory: interface.Window_Memory(2048, 32768)
frame_table: ^interface.Draw_Table // The table of the frame that draw builds.

kind_color :: proc "contextless" (kind: addresses.Kind) -> graphics.Color {
	switch kind {
	case .Module_Code:
		return graphics.colors.process
	case .Module_Constants:
		return graphics.shade(graphics.colors.process, 72)
	case .Module_Data:
		return graphics.shade(graphics.colors.process, 50)
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
		return graphics.colors.failed
	case .Created:
		return graphics.colors.boot_program
	case .None, .Ready, .Waiting:
		// A process that runs, or waits, has the color of a process.
	}
	return graphics.colors.process
}

// hash_color gives the color of a module from its hash.
hash_color :: proc "contextless" (hash: [32]u8) -> graphics.Color {
	return graphics.mix(graphics.rgb(u32(hash[0]) | 0x40, u32(hash[1]) | 0x40, u32(hash[2]) | 0x40), graphics.colors.text, 64)
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

card :: proc "contextless" (frame: ^interface.Frame, x, y, width, height: int, title, caption: string, accent: graphics.Color) -> interface.Area {
	return interface.card(frame, {x, y, width, height}, title, caption, accent)
}

// changed says if a sample of the same process had another value.
changed :: proc "contextless" (now, before: u64) -> bool {
	return previous.slot == current.slot && now != before
}

// The first line of each row of the list, and at shown_count the count of
// the lines of all the rows: made when the list is read, not at each
// picture.
shown_row: [PROCESS_SLOTS + 1]int

// list_rows_update counts the lines of the name of each row of the list.
list_rows_update :: proc "contextless" () {
	line := 0
	for position in 0 ..< shown_count {
		shown_row[position] = line
		line += max(interface.text_wrapped_line_count(nil, {}, system.name_of(entries[shown[position]].name[:]), LIST_NAME_ROOM), 1)
	}
	shown_row[shown_count] = line
}

// list_drawn_count gives the count of rows that the list shows: all of
// them when they fit, else the rows that leave room for the lines that
// count the others.
list_drawn_count :: proc "contextless" () -> int {
	if shown_row[shown_count] <= LIST_LINES {
		return shown_count
	}
	drawn := 0
	for drawn < shown_count && shown_row[drawn + 1] <= LIST_LINES - LIST_MORE_LINES {
		drawn += 1
	}
	return drawn
}

list_place :: proc "contextless" (x, y: int) -> (position: int, inside: bool) {
	if x < LIST_X || x >= LIST_X + LIST_WIDTH || y < LIST_ROWS_Y {
		return 0, false
	}
	line := (y - LIST_ROWS_Y) / LINE
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
	interface.background(&frame, {0, 0, WIDTH, HEIGHT})
	draw_list(&frame)
	if current.slot == 0 {
		inside := card(&frame, RIGHT_X, 8, RIGHT_WIDTH, MAP_HEIGHT, "ADDRESS SPACE", "op.Process_Mapping_Report", graphics.colors.memory)
		write(inside, 0, 0, "not known yet: choose a process in the list", graphics.colors.dim)
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
		system.log("inspect: the interface: ", u64(window_memory.drawing.now.record_count), " records; 20 frames with ", damage_total, " damage rectangles in all; the last frame: build ", window_memory.drawing.build_time / 1000, " us, difference ", window_memory.drawing.difference_time / 1000, " us, draw ", window_memory.drawing.draw_time / 1000, " us")
	}
}

samples_drawn, damage_total: u64 // The measure of the damage of the first 20 frames.

draw_list :: proc "contextless" (frame: ^interface.Frame) {
	inside := card(frame, LIST_X, LIST_Y, LIST_WIDTH, HEIGHT - 16, "SLOTS", "Process_Report", graphics.colors.process)
	x := write(inside, 0, 0, "filter ", graphics.colors.dim)
	x = write(inside, x, 0, string(filter[:filter_count]), graphics.colors.text)
	fill(inside, x, 0, 8, 16, graphics.colors.track)
	drawn := list_drawn_count()
	for position in 0 ..< drawn {
		item := &entries[shown[position]]
		y := 24 + shown_row[position] * LINE
		height := (shown_row[position + 1] - shown_row[position]) * LINE
		chosen := item.slot == selected_slot && item.process_serial == selected_process_serial
		// The row takes a press where list_place finds it; the name of its
		// process is its element name.
		interface.element_name(frame, {LIST_X, LIST_ROWS_Y + shown_row[position] * LINE, LIST_WIDTH, height}, system.name_of(item.name[:]))
		if chosen {
			fill(inside, -8, y, inside.width + 8, height, graphics.colors.track)
			fill(inside, -8, y, 4, height, graphics.colors.process)
		}
		interface.draw_text_wrapped(frame_table, inside.x, inside.y + y, LIST_NAME_ROOM, system.name_of(item.name[:]), chosen ? graphics.COLOR_WHITE : graphics.colors.text)
		fill(inside, inside.width - 32, y + 5, 6, 6, state_color(item.state))
		right(inside, inside.width, y, graphics.colors.dim, item.slot)
	}
	if drawn < shown_count {
		// The list never hides a row in silence: it counts the rows that it
		// does not show, and the filter reaches each of them.
		more: [64]u8
		interface.draw_text_wrapped(frame_table, inside.x, inside.y + 24 + shown_row[drawn] * LINE, inside.width, system.format(more[:], "and ", u64(shown_count - drawn), " more: type a part of a name"), graphics.colors.dim)
	}
	// The cost of one sample: measured, not estimated.
	y := inside.height - 64
	text(inside, 0, y, graphics.colors.dim, "one sample")
	right(inside, inside.width, y, graphics.colors.text, current.nanoseconds / 1000, " us")
	text(inside, 0, y + LINE, graphics.colors.dim, "kernel entries")
	right(inside, inside.width, y + LINE, graphics.colors.text, current.entries)
	text(inside, 0, y + 2 * LINE, graphics.colors.dim, frozen ? "frozen: space" : "4 samples in 1 s", "")
	right(inside, inside.width, y + 2 * LINE, frozen ? graphics.colors.boot_program : graphics.colors.process, frozen ? "frozen" : "live")
	text(inside, 0, y + 3 * LINE, graphics.colors.dim, "tab: bytes")
}

draw_map :: proc "contextless" (frame: ^interface.Frame) {
	name := system.name_of(current.process.name[:])
	buffer: [64]u8
	inside := card(frame, RIGHT_X, 8, RIGHT_WIDTH, MAP_HEIGHT, "ADDRESS SPACE", system.format(buffer[:], "op.Process_Mapping_Report of ", name), graphics.colors.memory)
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
	x := text(inside, 0, 0, graphics.colors.text, u64(len(mappings)))
	x = text(inside, x, 0, graphics.colors.dim, " mappings  ")
	x = text(inside, x, 0, graphics.colors.text, pages)
	x = text(inside, x, 0, graphics.colors.dim, " pages mapped  ")
	x = text(inside, x, 0, changed(present, before_present) ? graphics.colors.boot_program : graphics.colors.memory, present)
	x = text(inside, x, 0, graphics.colors.dim, " with a frame  ")
	x = text(inside, x, 0, state_color(current.process.state), current.process.state == .Stopped ? "stopped" : "runs")
	// The band: each mapping scaled by its pages, each gap folded.
	segments: [2 * op.MAPPING_REPORT_CAPACITY]addresses.Segment
	count := addresses.band(mappings, inside.width, 16, 4, segments[:])
	BAND_Y :: 24
	if len(mappings) == 0 {
		write(inside, 0, BAND_Y + 12, "no mapping: the kernel ended each mapping when the process stopped", graphics.colors.dim)
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
		fill(inside, segment.x, BAND_Y + BAND_HEIGHT - 4, width, 4, graphics.colors.track)
		fill(inside, segment.x, BAND_Y + BAND_HEIGHT - 4, int(u64(width) * item.present / max(item.page_count, 1)), 4, graphics.colors.text)
	}
	// The kinds, as a legend.
	x = 0
	for kind in addresses.Kind {
		fill(inside, x, 76, 8, 8, kind_color(kind))
		x = write(inside, x + 12, 72, addresses.KIND_NAMES[kind], graphics.colors.dim) + 8
	}
	// The table: one row for each mapping. The last two columns end at the
	// right edge of the card: the longest name of a kind ends before the
	// rights, and "shared" ends at the edge.
	TABLE_Y :: 96
	SHARED_X :: RIGHT_WIDTH - 2 * graphics.MARGIN - 6 * graphics.CELL_WIDTH
	RIGHTS_X :: SHARED_X - 5 * graphics.CELL_WIDTH
	#assert(RIGHTS_X >= 512 + 16 * graphics.CELL_WIDTH + graphics.CELL_WIDTH) // "module constants", then a space.
	write(inside, 0, TABLE_Y, "address", graphics.colors.dim)
	right(inside, 336, TABLE_Y, graphics.colors.dim, "pages")
	write(inside, 352, TABLE_Y, "with a frame", graphics.colors.dim)
	write(inside, 512, TABLE_Y, "kind", graphics.colors.dim)
	write(inside, RIGHTS_X, TABLE_Y, "rights", graphics.colors.dim)
	rows := (inside.height - TABLE_Y - LINE) / LINE
	for &item, number in mappings {
		y := TABLE_Y + LINE + number * LINE
		if number == rows - 1 && len(mappings) > rows {
			text(inside, 0, y, graphics.colors.dim, "and ", u64(len(mappings) - number), " mappings more: inspect.mappings() gives each one")
			break
		}
		writer := system.Writer{buffer = buffer[:]}
		address_write(&writer, item.address)
		kind := addresses.kind_of(item, modules)
		fill(inside, 0, y + 4, 8, 8, kind_color(kind))
		write(inside, 16, y, system.written(&writer), graphics.colors.text)
		right(inside, 336, y, graphics.colors.text, item.page_count)
		before := u64(0)
		if number < int(previous.mappings.count) && previous.mappings.mappings[number].address == item.address {
			before = previous.mappings.mappings[number].present
		} else {
			before = item.present
		}
		fill(inside, 352, y + 4, 96, 8, graphics.colors.track)
		fill(inside, 352, y + 4, int(96 * item.present / max(item.page_count, 1)), 8, graphics.colors.memory)
		right(inside, 496, y, changed(item.present, before) ? graphics.colors.boot_program : graphics.colors.text, item.present)
		write(inside, 512, y, addresses.KIND_NAMES[kind], kind_color(kind))
		rights := [3]u8{'r', .Write in item.flags ? 'w' : '-', .Execute in item.flags ? 'x' : '-'}
		write(inside, RIGHTS_X, y, string(rights[:]), graphics.colors.text)
		if .Shared in item.flags {
			write(inside, SHARED_X, y, "shared", graphics.colors.dim)
		}
	}
}

draw_modules :: proc "contextless" (frame: ^interface.Frame) {
	inside := card(frame, RIGHT_X, LOW_Y, MODULES_WIDTH, LOW_HEIGHT, "MODULES", "op.Module_Report", graphics.colors.process)
	if current.slot == 0 {
		return
	}
	// The name has the room before the size, a number of at most five
	// digits and its unit; the base and the start of the hash have the
	// width of the card. Each goes on more lines when it is wider.
	NAME_ROOM :: MODULES_WIDTH - 2 * graphics.MARGIN - 16 - 10 * graphics.CELL_WIDTH
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
		lines := interface.text_wrapped_line_count(frame_table, {}, name, NAME_ROOM) + interface.text_wrapped_line_count(frame_table, {}, place, inside.width - 16)
		if rest_line_needed(y, lines, number, len(modules), inside.height) {
			text(inside, 0, y, graphics.colors.dim, "and ", u64(len(modules) - number), " more: inspect.modules()")
			break
		}
		fill(inside, 0, y + 4, 8, 8, hash_color(item.hash))
		right(inside, inside.width, y, graphics.colors.text, item.size / 1024, " KiB")
		y += LINE * interface.draw_text_wrapped(frame_table, inside.x + 16, inside.y + y, NAME_ROOM, name, graphics.colors.text)
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
	x := RIGHT_X + MODULES_WIDTH + 8
	inside := card(frame, x, LOW_Y, WIDTH - 8 - x, LOW_HEIGHT, "THREADS", "op.Thread_Table_Report", graphics.colors.kernel)
	if current.slot == 0 {
		return
	}
	write(inside, 0, 0, "#", graphics.colors.dim)
	write(inside, 24, 0, "state", graphics.colors.dim)
	write(inside, 96, 0, "runs", graphics.colors.dim)
	right(inside, 200, 0, graphics.colors.dim, "weight")
	right(inside, 272, 0, graphics.colors.dim, "req us")
	right(inside, 360, 0, graphics.colors.dim, "lag")
	right(inside, inside.width, 0, graphics.colors.dim, "time ms")
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
			text(inside, 0, y, graphics.colors.dim, "and ", u64(len(threads) - number), " more: inspect.threads()")
			break
		}
		before: op.Thread_Report
		for &other in previous.threads.threads[:min(previous.threads.count, op.THREAD_REPORT_CAPACITY)] {
			if other.number == item.number {
				before = other
			}
		}
		text(inside, 0, y, graphics.colors.text, u64(item.number))
		fill(inside, 24, y + 4, 8, 8, item.processor != 0 ? graphics.colors.process : graphics.colors.not_usable)
		write(inside, 40, y, item.processor != 0 ? "runs" : item.state == .Waiting ? "waits" : "ready", changed(u64(item.state) << 8 | u64(item.processor), u64(before.state) << 8 | u64(before.processor)) ? graphics.colors.boot_program : graphics.colors.text)
		if item.processor != 0 {
			text(inside, 96, y, graphics.colors.text, "cpu ", u64(item.processor - 1))
		} else {
			text(inside, 96, y, graphics.colors.dim, "home ", u64(item.home))
		}
		right(inside, 200, y, graphics.colors.text, u64(item.weight))
		right(inside, 272, y, graphics.colors.text, u64(item.request))
		right(inside, 360, y, graphics.colors.text, item.lag)
		right(inside, inside.width, y, changed(item.run_time, before.run_time) ? graphics.colors.boot_program : graphics.colors.text, item.run_time)
		y += LINE
		y += LINE * interface.draw_text_wrapped(frame_table, inside.x + 24, inside.y + y, inside.width - 24, second, graphics.colors.dim)
	}
	if current.threads.count == 0 {
		write(inside, 0, LINE, "no thread: the process ended", graphics.colors.dim)
	}
}

draw_stop :: proc "contextless" (frame: ^interface.Frame) {
	x := RIGHT_X + MODULES_WIDTH + 8
	inside := card(frame, x, LOW_Y, WIDTH - 8 - x, LOW_HEIGHT, "STOP REPORT", "op.Stop_Report: where it stopped", graphics.colors.failed)
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
	y := LINE * interface.draw_text_wrapped(frame_table, inside.x, inside.y, inside.width, system.written(&writer), graphics.colors.failed)
	y += 8
	y += LINE * interface.draw_text_wrapped(frame_table, inside.x, inside.y + y, inside.width, "the stack trace, from the frame pointers:", graphics.colors.dim)
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
			interface.draw_text_wrapped(frame_table, inside.x, inside.y + y, inside.width, system.format(buffer[:], "and ", u64(len(frames) - number), " frames more: the log has each one"), graphics.colors.dim)
			break
		}
		text(inside, 0, y, graphics.colors.dim, u64(number))
		fill(inside, 24, y + 4, 8, 8, stop_frame.base != 0 ? hash_color(stop_frame.hash) : graphics.colors.not_usable)
		y += LINE * interface.draw_text_wrapped(frame_table, inside.x + 40, inside.y + y, inside.width - 40, place, number == 0 ? graphics.colors.failed : graphics.colors.text)
	}
}
