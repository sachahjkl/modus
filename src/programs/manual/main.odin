// The manual: it shows the documentation of each module of the boot image.
//
// A module carries its documentation in its file
// ([the description tables](docs/MODULE_CONTRACT.md#description-tables)):
//
// - one line that says what the module is, and a text;
// - for each export: its name, the name and the type of each parameter, the type of the result, and a text.
//
// The build tool takes all of it from the comments of the source of the module, and the text keeps their Markdown.
// The manual reads it: a bold word is in the bold weight, a word in italics has a thin line under it, a name of
// code is in the font of the cells, a list item has its mark and its indentation, and an example is a block. A
// link is a colored name. A link that opens has a line under it: a link to a module, to an export or to a record of
// the boot image, and a link to a term of the glossary or to a heading of a guide, whose
// [link page](term:link-page) the boot image carries in the resource `manual_pages`. An address of another host is shown after its link, and does not open.
// This program reads the file only: it **does not load the module**, and it does not start it.
//
// The page of a module also says how the module can be used. The system has *one kind of file* for a program, a
// library and a service, so the answer comes from two facts: the module has an entry or not, and it has exports
// or not.
//
// **Keys**
//
// - up, down: the module before, the module after;
// - page up, page down: move the text;
// - home: the start of the text;
// - Tab, Shift+Tab: the focus on the next link, or the one before;
// - Enter: open the link with the focus;
// - Backspace: back to the page before;
// - o: the table of all the modules, as `overview()` shows it.
//
// A click on a name of the list shows that module. A click on a link with a line under it shows the page that it
// names.
//
// The manual is a service: another program asks for a page with [show](manual.show), and reads a description as
// a text with [about](manual.about) and [signature](manual.signature). The other exports give the facts of the
// modules as tables, which the console combines with `where()`, `sort()`, `join()` and `columns()`.
//
// **Start**: the console line `start("manual")`, or the bar of the desktop. A call of `connect("manual")` from
// the console also reaches it when it runs.
//
// **Grants**, as the root service gives them:
//
// - **Serve**: other programs call its exports through connections.
// - **Image**: it reads the file of each module of the boot image, read-only.
// - **Replacements**: it reads the replacement table, so that a page names the module that a loader gives in
//   place of an import.
// - **Inspect**: it reads the module records of each program that runs. It gives these facts only to a caller
//   that acts for the principal (information.odin).
//
// **What it proves**: the documentation of a module is in its file, and a reader needs neither its source nor a
// load of it. It does not prove that a text is true: the build copies the comments, and checks only their form.
//
// The design of the description tables: (docs/MODULE_CONTRACT.md, "Description tables").
package manual

import "modus:contract/errors"
import "modus:support/display"
import "modus:support/graphics"
import "modus:support/interface"
import "modus:support/manual_navigation"
import info "modus:contract/boot_info"
import "modus:contract/manual_pages"
import module "modus:contract/module"
import "modus:support/system"

// The window is built with the interface package (docs/INTERFACE.md).
records_now, records_before: [512]interface.Draw_Record
text_now, text_before: [8192]u8
drawing: interface.Window_Drawing

CELL_WIDTH :: graphics.CELL_WIDTH
CELL_HEIGHT :: graphics.CELL_HEIGHT
LIST_COLUMNS :: 20
LIST_WIDTH :: LIST_COLUMNS * CELL_WIDTH + 16
MARGIN :: 12
COLUMNS :: 84 // The width of the text.
ROWS :: 33
SCROLL_WIDTH :: interface.SCROLL_BAR_THICKNESS
SCROLL_GAP :: 11 // From the text to the scroll bar: the band of an example passes the text by 4 pixels.
WIDTH :: LIST_WIDTH + MARGIN + COLUMNS * CELL_WIDTH + SCROLL_GAP + SCROLL_WIDTH
HEIGHT :: ROWS * CELL_HEIGHT + 2 * MARGIN + CELL_HEIGHT + 8
#assert(WIDTH % 8 == 0)

// scroll_area gives the place of the scroll bar of the text: at the right
// edge of the window, from its top to the line over the keys.
scroll_area :: proc "contextless" () -> interface.Area {
	return {WIDTH - SCROLL_WIDTH, 0, SCROLL_WIDTH, HEIGHT - CELL_HEIGHT - 6 - 4}
}

// text_view_area gives the place of the text, at the right of the list:
// the wheel over it moves the text.
text_view_area :: proc "contextless" () -> interface.Area {
	return {LIST_WIDTH, 0, WIDTH - SCROLL_WIDTH - LIST_WIDTH, HEIGHT - CELL_HEIGHT - 6 - 4}
}

// scroll_identity gives the identity of the scroll bar of the text.
scroll_identity :: proc "contextless" () -> interface.Element_Identity {
	return interface.identity("the scroll bar of the text")
}

// The scroll bar moved the text in the last frame: the next frame shows it.
text_moved_by_scroll_bar: bool

COLOR_SELECTED :: 0x2C3A4C
COLOR_TITLE :: 0xF0C050
COLOR_HEADING :: 0x6CB4F0
COLOR_EXPORT :: 0x7CD890
COLOR_CODE :: 0xE0A878

image: []u8
built: [16384]u8 // The lines that this program writes: the signatures and the facts.
built_count: int
selected: int // The index of the module of the list, in the boot image: the module of the page when the page is a module page.
first_line: int // The first line that the window shows.
page_kind: manual_navigation.Page_Kind // What the page shows.
link_page_index: int // Link_Page: the index of the page in the resource manual_pages.
history: manual_navigation.History // The pages that the principal left: Backspace goes back.

// navigation_leave keeps the page that the window shows in the history,
// before a change of the page.
navigation_leave :: proc "contextless" () {
	index := page_kind == .Link_Page ? link_page_index : selected
	manual_navigation.history_push(&history, {kind = page_kind, index = i32(index), first_line = i32(first_line)})
}

// page_back shows the last page of the history, at its first row, and
// writes it on the log.
page_back :: proc "contextless" () {
	place, ok := manual_navigation.history_back(&history)
	if !ok {
		system.log("manual: back: no page before")
		return
	}
	system.log("manual: back to the page before")
	switch place.kind {
	case .Module:
		select(int(place.index))
	case .Overview:
		overview_build()
	case .Link_Page:
		link_page_build(int(place.index))
	}
	first_line = clamp(int(place.first_line), 0, max(rows() - ROWS, 0))
	if place.kind != .Overview {
		page_log()
	}
}

// page_rebuild writes the page that the window shows again, at the same
// row: the widths of the words change with the font.
page_rebuild :: proc "contextless" () {
	kept := first_line
	switch page_kind {
	case .Module:
		page_build()
	case .Overview:
		return // The table is in the font of the cells.
	case .Link_Page:
		link_page_build(link_page_index)
	}
	first_line = clamp(kept, 0, max(rows() - ROWS, 0))
}

// file_of gives the file of an entry of the boot image, or nothing when the
// file is not a valid module.
file_of :: proc "contextless" (entry: ^info.Image_Entry) -> []u8 {
	if entry.offset > u64(len(image)) || entry.size > u64(len(image)) - entry.offset {
		return nil
	}
	file := image[entry.offset:][:entry.size]
	return module.validate(file) == .None ? file : nil
}

// The replacement table of the machine, that the root service writes.
replacement_table: ^system.Replacement_Table
replacement_records: [system.REPLACEMENT_CAPACITY]module.Replacement

// module_text gives the name of a module of the boot image and the start of
// its hash, in the built lines.
module_text :: proc "contextless" (hash: [32]u8) -> string {
	writer := system.Writer {
		buffer = built[built_count:],
	}
	if entry := system.image_entry_of(image, hash); entry != nil {
		system.write_part(&writer, system.name_of(entry.name[:]))
		system.write_part(&writer, " ")
	}
	system.write_hash(&writer, hash)
	built_count += writer.count
	return system.written(&writer)
}

// find gives the index of a module of the boot image, by name, or -1.
find :: proc "contextless" (name: string) -> int {
	for &entry, index in system.image_entries(image) {
		if system.name_of(entry.name[:]) == name {
			return index
		}
	}
	return -1
}

// described_exports gives the count of exports of a module that have a
// description: each export but the entry.
described_exports :: proc "contextless" (file: []u8) -> (count: int) {
	head, _ := module.header(file)
	for index in 1 ..< module.count(file, .Exports) {
		if function, ok := module.function(file, index); ok && index != head.entry_export && function.name_count != 0 {
			count += 1
		}
	}
	return count
}

// write_signature writes the description of an export as one line:
// "name(parameter: Type, ...) -> Type".
write_signature :: proc "contextless" (writer: ^system.Writer, file: []u8, function: module.Function) {
	function := function
	system.write_part(writer, module.string_at(file, function.name_offset, function.name_count))
	system.write_part(writer, "(")
	for type, parameter in function.parameters[:min(int(function.parameter_count), module.PARAMETER_CAPACITY)] {
		system.write_part(writer, parameter > 0 ? ", " : "")
		system.write_part(writer, module.string_at(file, function.parameter_names[parameter], u32(function.parameter_name_counts[parameter])))
		system.write_part(writer, ": ")
		system.write_parameter_type(writer, file, type, function.parameter_details[parameter], function.parameter_directions[parameter])
	}
	system.write_part(writer, ")")
	if function.result != .None {
		system.write_part(writer, " -> ")
		system.write_type(writer, file, function.result, function.result_detail)
	}
}

// put_built writes a line from parts, and keeps its bytes in built.
put_built :: proc "contextless" (indent: int, color: graphics.Color, parts: ..system.Part) {
	writer := system.Writer {
		buffer = built[built_count:],
	}
	for part in parts {
		system.write_part(&writer, part)
	}
	built_count += writer.count
	put(system.written(&writer), indent, color)
}

// put_paragraph breaks a paragraph at the width of the text, between
// words. An empty paragraph adds no row.
put_paragraph :: proc "contextless" (text: string, indent: int, color: graphics.Color) {
	if len(text) > 0 {
		put(text, indent, color)
	}
}

// USE_INDENT is the indentation of a call of "HOW TO USE IT", in cells.
USE_INDENT :: 2

// put_use adds one way to use a module: the call, with the name of the
// module, then what the call gives. The two are on one row when the name is
// short: the description starts two cells after the longest of the calls,
// so the descriptions of a page stay in one column. When the row cannot
// hold the two, the description is on the row under the call: the two
// texts never meet.
put_use :: proc "contextless" (call, name, description: string) {
	put_built(USE_INDENT, COLOR_CODE, call, "(\"", name, "\")")
	column := max(USE_INDENT + len("connect(\"\")") + len(name) + 2, 24)
	if fits_after(description, column) {
		put(description, column, graphics.COLOR_TEXT)
		line_join()
	} else {
		put(description, USE_INDENT + 4, graphics.COLOR_TEXT)
	}
}

// page_build writes the page of the selected module.
page_build :: proc "contextless" () {
	page_clear()
	wanted_row = -1
	// Before the text: a link to a record looks first in the module of the
	// page.
	page_kind = .Module
	entries := system.image_entries(image)
	if selected < 0 || selected >= len(entries) {
		return
	}
	entry := &entries[selected]
	name := system.name_of(entry.name[:])
	file := file_of(entry)
	if file == nil {
		put_built(0, COLOR_TITLE, name)
		put("This file is not a valid module.", 0, graphics.COLOR_TEXT)
		return
	}
	head, _ := module.header(file)
	about, text := module.documentation(file)
	exports := described_exports(file)
	has_entry := head.entry_export != 0
	imports := int(max(module.count(file, .Imports), 1)) - 1

	put_built(0, COLOR_TITLE, name)
	put_paragraph(about, 0, graphics.COLOR_TEXT)
	put("", 0, 0)
	hash: [16]u8
	digits := system.HEX_DIGITS
	for b, index in entry.hash[:8] {
		hash[2 * index], hash[2 * index + 1] = digits[b >> 4], digits[b & 0xF]
	}
	put_built(0, graphics.COLOR_DIM, "file      ", entry.size, " bytes, hash ", string(hash[:]), "...")
	put_built(0, graphics.COLOR_DIM, "memory    ", head.memory_size >> 10, " KiB when loaded, ", u64(max(module.count(file, .Segments), 1) - 1), " segments, ", u64(imports), " imports")
	put_built(0, graphics.COLOR_DIM, "exports   ", u64(exports), has_entry ? ", and an entry" : ", and no entry")
	put("", 0, 0)

	put("HOW TO USE IT", 0, COLOR_HEADING)
	if has_entry {
		put_use("start", name, "a program: the module has an entry")
	}
	if exports > 0 && has_entry {
		put_use("connect", name, "a service: calls to the program that runs, if it serves")
	}
	if exports > 0 {
		put_use("load", name, "a library: direct calls, in the memory of the caller")
		put_use("isolate", name, "a sandboxed program: calls through a ring, no handle")
	}
	put("", 0, 0)

	// The imports, and the replacement table of the machine: the module
	// that a loader gives in place of an import, at this time.
	replaced := system.replacements_read(replacement_table, &replacement_records)
	replaced_count := 0
	for item in replaced {
		if item.from == entry.hash || item.to == entry.hash {
			replaced_count += 1
		}
	}
	if imports > 0 || replaced_count > 0 {
		put_built(0, COLOR_HEADING, "IMPORTS (", u64(imports), ")")
		for number in 1 ..= u32(imports) {
			record, _ := module.record(file, .Imports, number, module.Import)
			put_built(2, COLOR_CODE, module_text(record.hash))
			for item in replaced {
				if item.from == record.hash {
					put_built(4, COLOR_TITLE, "on this machine a loader gives ", module_text(item.to), " in its place")
				}
			}
		}
		for item in replaced {
			if item.from == entry.hash {
				put_built(2, COLOR_TITLE, "on this machine ", module_text(item.to), " replaces this module in each import")
			}
			if item.to == entry.hash {
				put_built(2, COLOR_TITLE, "on this machine this module replaces ", module_text(item.from), " in each import")
			}
		}
		put("", 0, 0)
	}

	information_page(entry.hash)
	put("DOCUMENTATION", 0, COLOR_HEADING)
	put_markdown(text, 0, graphics.COLOR_TEXT)
	if exports == 0 {
		return
	}
	put("", 0, 0)
	put_built(0, COLOR_HEADING, "EXPORTS (", u64(exports), ")")
	for index in 1 ..< module.count(file, .Exports) {
		function, ok := module.function(file, index)
		if !ok || index == head.entry_export || function.name_count == 0 {
			continue
		}
		writer := system.Writer {
			buffer = built[built_count:],
		}
		write_signature(&writer, file, function)
		built_count += writer.count
		if wanted_export != "" && module.string_at(file, function.name_offset, function.name_count) == wanted_export {
			wanted_row = row_count
		}
		put(system.written(&writer), 0, COLOR_EXPORT)
		put_markdown(module.string_at(file, function.text_offset, function.text_count), 4, graphics.COLOR_TEXT)
		put("", 0, 0)
	}
	// The records that the exports use: the name, the size, and each field.
	records := module.count(file, .Records)
	if records <= 1 {
		return
	}
	put_built(0, COLOR_HEADING, "RECORDS (", u64(records - 1), ")")
	for index in 1 ..< records {
		described, ok := module.record_type(file, index)
		if !ok {
			continue
		}
		if wanted_record != "" && module.string_at(file, described.name_offset, described.name_count) == wanted_record {
			wanted_row = row_count
		}
		put_built(0, COLOR_EXPORT, module.string_at(file, described.name_offset, described.name_count), "  ", u64(described.size), " bytes")
		for number in 0 ..< described.field_count {
			item, _ := module.field(file, described, number)
			writer := system.Writer {
				buffer = built[built_count:],
			}
			system.write_part(&writer, module.string_at(file, item.name_offset, item.name_count))
			system.write_part(&writer, ": ")
			system.write_field_type(&writer, file, item)
			system.write_part(&writer, ", at byte ")
			system.write_part(&writer, u64(item.offset))
			built_count += writer.count
			put(system.written(&writer), 4, graphics.COLOR_TEXT)
		}
		put("", 0, 0)
	}
}

// draw builds a frame of the window with the interface package.
draw :: proc "contextless" (window: ^display.Window) {
	if drawing.now.records == nil {
		drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:])
	}
	frame := interface.window_frame_begin(&drawing, window)
	draw_records(&frame)
	// The scroll bar of the text: the pointer on it moves the text as Page
	// Up and Page Down do, and the wheel over the text moves it too.
	moved := interface.scroll_bar(&frame, scroll_area(), scroll_identity(), .Vertical, {total = rows(), visible = ROWS, first = first_line}, {page = ROWS - 2}, "", text_view_area())
	interface.window_frame_end(&drawing, &frame, window)
	if moved.changed {
		first_line = moved.first
		text_moved_by_scroll_bar = true
	}
}

// COLOR_FOCUS is the line under the link with the focus: white, as the
// frame of the focus of a button.
COLOR_FOCUS :: 0xFFFFFF

draw_records :: proc "contextless" (frame: ^interface.Frame) {
	table := frame.table
	interface.draw_rectangle(table, 0, 0, WIDTH, HEIGHT, graphics.COLOR_BACKGROUND)
	interface.draw_rectangle(table, 0, 0, LIST_WIDTH, HEIGHT, graphics.COLOR_CARD_TOP)
	entries := system.image_entries(image)
	first_row := list_first_row()
	for index in 0 ..< list_count {
		start, end := list_row[index], list_row[index + 1]
		if start < first_row {
			continue // A name whose first line is over the window: its row is not drawn in part.
		}
		if end > first_row + LIST_ROWS {
			break
		}
		y := 4 + (start - first_row) * CELL_HEIGHT
		if index == selected && page_kind == .Module {
			interface.draw_rectangle(table, 0, y, LIST_WIDTH, (end - start) * CELL_HEIGHT, COLOR_SELECTED)
		}
		exports := list_exports[index]
		interface.draw_text_wrapped(table, 8, y, list_name_room(exports), system.name_of(entries[index].name[:]), list_colors[index])
		if exports > 0 {
			buffer: [8]u8
			count := system.format(buffer[:], u64(exports))
			interface.draw_text(table, LIST_WIDTH - 8 - len(count) * CELL_WIDTH, y, count, graphics.COLOR_DIM)
		}
	}

	left := LIST_WIDTH + MARGIN
	row := -first_line - 1
	for &part, part_index in row_parts[:row_part_count] {
		if .Row_Start in part.flags {
			row += 1
			if row >= ROWS {
				break
			}
		}
		if row < 0 {
			continue
		}
		x := left + int(part.x)
		y := MARGIN + row * CELL_HEIGHT
		if .Code_Block in part.flags {
			// An example is a block: a band from its indentation to the end
			// of the text, on each of its rows.
			interface.draw_rectangle(table, x - 4, y, left + TEXT_WIDTH + 4 - (x - 4), CELL_HEIGHT, graphics.COLOR_TRACK)
		}
		focused := part.link > 0 && int(part.link) == focused_link
		if focused {
			// The band is the box of the part: it covers no other text.
			interface.draw_rectangle(table, x, y, int(part.width), CELL_HEIGHT, COLOR_SELECTED)
		}
		interface.draw_text(table, x, y, part.text, part.color, part.font)
		switch {
		case focused:
			interface.draw_rectangle(table, x, y + CELL_HEIGHT - 2, int(part.width), 2, COLOR_FOCUS)
		case .Opens_A_Page in part.flags:
			interface.draw_rectangle(table, x, y + CELL_HEIGHT - 2, int(part.width), 1, part.color)
		case .Underlined in part.flags:
			interface.draw_rectangle(table, x, y + CELL_HEIGHT - 2, int(part.width), 1, graphics.COLOR_DIM)
		}
		// A link names itself by its label, at its first part: a machine
		// test presses it by that name (src/md/infrastructure/test_pointer.md).
		if part.link > 0 && int(part.link) <= page_link_count && page_links[part.link - 1].first_part == part_index {
			interface.element_name(frame, {x, y, int(part.width), CELL_HEIGHT}, page_links[part.link - 1].label)
		}
	}
	bottom := HEIGHT - CELL_HEIGHT - 6
	interface.draw_rectangle(table, LIST_WIDTH, bottom - 4, WIDTH - LIST_WIDTH, 1, 0x30363C)
	hint := interface.draw_text(table, left, bottom, "up, down: module  Tab, Enter: link  Backspace: back", graphics.COLOR_DIM)
	buffer: [64]u8
	total := rows()
	place := system.format(buffer[:], "rows ", u64(min(first_line + 1, total)), " to ", u64(min(first_line + ROWS, total)), " of ", u64(total))
	interface.draw_text(table, max(hint + 16, WIDTH - MARGIN - len(place) * CELL_WIDTH), bottom, place, graphics.COLOR_DIM)
}

// The list of the modules, at the left of the window. The name of a module
// has a box: from the left of the list to the count of its exports. A name
// wider than its box goes on more lines (interface.text_wrap_line), and its
// row has the height of its lines: no name runs over the page. The boot
// image does not change while the system runs, so the rows are made once.
LIST_ROWS :: (HEIGHT - 8) / CELL_HEIGHT // The lines of the list in the window.
LIST_ENTRY_CAPACITY :: 1024
list_row: [LIST_ENTRY_CAPACITY + 1]int // The first line of each module, and at list_count the count of the lines.
list_exports: [LIST_ENTRY_CAPACITY]int // The count of the described exports of each module.
list_colors: [LIST_ENTRY_CAPACITY]graphics.Color
list_count: int

// list_name_room gives the width of the box of a name of the list, in
// pixels: the list without its margins and without the count of the
// exports, when the module has one, and a space before it.
list_name_room :: proc "contextless" (exports: int) -> int {
	room := LIST_WIDTH - 16
	if exports > 0 {
		buffer: [8]u8
		room -= (len(system.format(buffer[:], u64(exports))) + 1) * CELL_WIDTH
	}
	return room
}

// list_build makes the rows of the list from the boot image. A boot image
// with more modules than the list holds is stated on the log with the two
// counts: `show` and the keys still reach the page of each module.
list_build :: proc "contextless" () {
	entries := system.image_entries(image)
	list_count = min(len(entries), LIST_ENTRY_CAPACITY)
	line := 0
	for index in 0 ..< list_count {
		entry := &entries[index]
		file := file_of(entry)
		head, _ := module.header(file)
		exports := described_exports(file)
		color := graphics.Color(graphics.COLOR_DIM)
		switch {
		case exports > 0 && head.entry_export != 0:
			color = COLOR_EXPORT
		case exports > 0:
			color = COLOR_TITLE
		case head.entry_export != 0:
			color = graphics.COLOR_TEXT
		}
		list_row[index], list_exports[index], list_colors[index] = line, exports, color
		line += max(interface.text_wrapped_line_count(nil, {}, system.name_of(entry.name[:]), list_name_room(exports)), 1)
	}
	list_row[list_count] = line
	if list_count < len(entries) {
		system.log("manual: the list shows ", u64(list_count), " of the ", u64(len(entries)), " modules of the boot image")
	}
}

// list_first_row gives the first line of the list that the window shows:
// the row of the selected module is in the middle when the list is longer
// than the window.
list_first_row :: proc "contextless" () -> int {
	selected_row := selected < list_count ? list_row[selected] : 0
	return clamp(selected_row - LIST_ROWS / 2, 0, max(list_row[list_count] - LIST_ROWS, 0))
}

// list_index_at gives the module whose row is at a height of the window,
// or -1: a row that the window does not show whole takes no press.
list_index_at :: proc "contextless" (y: int) -> int {
	if y < 4 {
		return -1
	}
	first_row := list_first_row()
	row := first_row + (y - 4) / CELL_HEIGHT
	for index in 0 ..< list_count {
		if row >= list_row[index] && row < list_row[index + 1] {
			return list_row[index] >= first_row && list_row[index + 1] <= first_row + LIST_ROWS ? index : -1
		}
	}
	return -1
}

select :: proc "contextless" (index: int) {
	count := len(system.image_entries(image))
	if count == 0 {
		return
	}
	selected = clamp(index, 0, count - 1)
	page_build()
}

scroll :: proc "contextless" (rows_moved: int) {
	first_line = clamp(first_line + rows_moved, 0, max(rows() - ROWS, 0))
}

// text_result writes a text in the buffer of a Text result, and gives the
// count of bytes of the full text.
text_result :: proc "contextless" (text: string, result: ^[]u8) -> i64 {
	for i in 0 ..< min(len(text), len(result)) {
		result[i] = text[i]
	}
	return i64(len(text))
}

// show shows the page of a module of the boot image, by name.
//
// **Result**: the count of exports of the module, or a negative number with an error record:
//
// - `Absent` (-1): no module of the boot image has this name.
@(export, link_name = "show")
show :: proc "c" (name: ^string, error: ^errors.Error_Record) -> i64 {
	index := find(name^)
	if index < 0 {
		return errors.fail(error, -1, .Absent, .Modules, 1)
	}
	navigation_leave()
	select(index)
	return i64(page_log())
}

// page_log writes on the log which page the window shows. It gives the
// count of exports of the module of a module page.
page_log :: proc "contextless" () -> int {
	if page_kind == .Link_Page {
		system.log("manual: the page ", manual_pages.target_of(link_pages, link_page_index), ": ", manual_pages.title_of(link_pages, link_page_index), ", ", u64(rows()), " rows")
		return 0
	}
	entries := system.image_entries(image)
	file := file_of(&entries[selected])
	head, _ := module.header(file)
	exports := described_exports(file)
	system.log("manual: ", system.name_of(entries[selected].name[:]), head.entry_export != 0 ? ": a program, " : ": no entry, ", u64(exports), " exports, ", u64(rows()), " rows")
	return exports
}

// about gives the line that says what a module is, by name. The text is empty when the boot image has no module with this name.
@(export, link_name = "about")
about :: proc "c" (name: ^string, result: ^[]u8) -> i64 {
	index := find(name^)
	if index < 0 {
		return 0
	}
	line, _ := module.documentation(file_of(&system.image_entries(image)[index]))
	return text_result(line, result)
}

// signature gives the description of one export of a module as a text: its name, the name and the type of each parameter, and the type of the result. The exports have the numbers from 1. The text is empty when the module has no such export.
@(export, link_name = "signature")
signature :: proc "c" (name: ^string, export: i64, result: ^[]u8) -> i64 {
	index := find(name^)
	if index < 0 || export < 1 {
		return 0
	}
	file := file_of(&system.image_entries(image)[index])
	head, _ := module.header(file)
	number: i64
	for export_index in 1 ..< module.count(file, .Exports) {
		function, ok := module.function(file, export_index)
		if !ok || export_index == head.entry_export || function.name_count == 0 {
			continue
		}
		number += 1
		if number == export {
			buffer: [256]u8
			writer := system.Writer {
				buffer = buffer[:],
			}
			write_signature(&writer, file, function)
			return text_result(system.written(&writer), result)
		}
	}
	return 0
}

// The entry of the manual: it opens its service and its window, then serves calls and keys until the principal
// closes the window.
//
// When the loader starts it, the entry:
//
// 1. opens the service ring, so that callers can reach the exports;
// 2. opens a window of two pictures; with no window, it stops with the code 1;
// 3. maps the boot image and the replacement table, read-only;
// 4. measures the information functions once (`information_start`), and writes the line
//    "manual: information: ... modules break a rule" on the log;
// 5. shows the page of the module `manual` and writes "manual: ok, N modules, M have their documentation".
//
// Then one loop waits on the events of the window and on the service ring. A call to an export runs in this
// loop and can change the page; a key moves the page or the list. The window is drawn again only after a change.
// The program never stops by itself: the compositor or the console stops it.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	service, _ := system.service_open(ctx)
	window, ok := display.open(ctx, WIDTH, HEIGHT, "manual")
	if !ok {
		system.stop(1)
	}
	if address, status := system.memory_map(ctx.handles[system.GRANT_IMAGE], {}); status == .Ok {
		image = ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	}
	if address, status := system.memory_map(ctx.handles[system.GRANT_REPLACEMENTS], {}); status == .Ok {
		replacement_table = (^system.Replacement_Table)(address)
	}
	// Before the first page: its links to terms and guides read the
	// resource.
	link_pages_open()
	information_start(ctx)
	list_build()
	entries := system.image_entries(image)
	documented := 0
	for &item in entries {
		line, _ := module.documentation(file_of(&item))
		documented += int(line != "")
	}
	select(max(find("manual"), 0))
	system.log("manual: ok, ", u64(len(entries)), " modules, ", u64(documented), " have their documentation")
	markdown_check()
	changed := true
	pressed := false
	for {
		if changed && display.canvas_free(&window) {
			draw(&window)
			changed = text_moved_by_scroll_bar
			text_moved_by_scroll_bar = false
		}
		// A picture that waits for the compositor: display.canvas_free said
		// no, and the wait then ends when the compositor has read the ring
		// of the window. The question comes before the wait list, which
		// reads its answer. With a free canvas, the page that the scroll
		// bar moved is drawn in the next turn, with no wait. A held arrow
		// button of the scroll bar takes its next step at a time of the
		// clock: the wait ends there at the latest.
		deadline := changed && display.canvas_free(&window) ? system.time() : system.WAIT_FOREVER
		wait: system.Wait
		display.wait_events(&wait, &window)
		system.service_wait(&wait, &service)
		step_time, step_due := interface.window_scroll_bar_wake(&drawing)
		if step_due {
			deadline = min(deadline, step_time)
		}
		system.wait_end(&wait, deadline)
		changed |= step_due && system.time() >= step_time
		changed |= system.service_run(&service) > 0
		for event in display.next_event(&window) {
			#partial switch event.kind {
			case .Settings_Changed:
				// A new font: each record is the same, each pixel of text is
				// not. The next frame of each picture is whole.
				interface.draw_whole_window_next(&drawing)
				// The widths of the words changed with the font: the rows
				// of the page are made again, at the same place.
				// The focus stays on its link.
				focus_kept := focused_link
				page_rebuild()
				focused_link = clamp(focus_kept, 0, page_link_count)
				changed = true
			case .Key:
				if !event.pressed {
					continue
				}
				changed = true
				switch event.code {
				case display.KEY_UP:
					navigation_leave()
					select(selected - 1)
					page_log()
				case display.KEY_DOWN:
					navigation_leave()
					select(selected + 1)
					page_log()
				case display.KEY_PAGE_UP:
					scroll(-(ROWS - 2))
				case display.KEY_PAGE_DOWN:
					scroll(ROWS - 2)
				case display.KEY_HOME:
					scroll(-ROW_PART_CAPACITY)
				case interface.KEY_TAB:
					link_focus_move(event.modifiers & display.MODIFIER_SHIFT != 0)
				case display.KEY_ENTER:
					link_open(focused_link)
				case display.KEY_BACKSPACE:
					page_back()
				case:
					if event.character == 'o' {
						navigation_leave()
						overview_build()
					}
				}
			case .Pointer:
				// The scroll bar of the text takes the pointer from the input
				// of the next frame.
				interface.input_add(&drawing.input, event)
				if interface.scroll_bar_wants_frame(&drawing.state, &drawing.input, scroll_area(), scroll_identity(), text_view_area()) {
					changed = true
				} else {
					// A notch over no view moves nothing, and does not wait
					// for a later frame.
					drawing.input.wheel -= event.wheel
				}
				down := event.buttons & display.BUTTON_LEFT != 0
				if down && !pressed && event.x >= 0 && event.x < LIST_WIDTH {
					if index := list_index_at(event.y); index >= 0 {
						navigation_leave()
						select(index)
						page_log()
						changed = true
					}
				}
				if down && !pressed && event.x >= LIST_WIDTH {
					if number := link_at_place(event.x, event.y); number > 0 {
						link_open(number)
						changed = true
					}
				}
				pressed = down
			}
		}
	}
}
