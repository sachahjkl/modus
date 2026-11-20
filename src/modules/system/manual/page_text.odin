package manual

import "modus:contract/blake3"
import "modus:contract/manual_pages"
import "modus:support/display"
import "modus:private/manual/manual_navigation"
import "modus:support/graphics"
import "modus:support/interface"
import markdown "modus:private/manual/source_comment_markdown"
import module "modus:contract/module"
import "modus:support/system"

// The text of a page: rows of parts. A part of a row is a run of text with
// one font and one color. The facts of a module (its sizes, its imports, the
// signatures of its exports) are values: they are in the font of the cells,
// one part for each row or two. A documentation text is Markdown
// (docs/SITE.md, "The Markdown of a source comment"): its words are in the
// interface font, its code in the font of the cells, and a row is broken
// between two words at the width of the text.

TEXT_WIDTH :: COLUMNS * CELL_WIDTH // The width of the text, in pixels.
LIST_INDENT :: 2 * CELL_WIDTH // The indentation of an item inside an item.
ROW_PART_CAPACITY :: 4096

Row_Part_Flag :: enum u8 {
	Row_Start, // The part starts a row. Without it, the part is on the row of the part before.
	Underlined, // A word in italics: the system has no italic face, so a thin line is under it.
	Code_Block, // A row of an example: a band is behind it.
	From_Markdown, // The part comes from a documentation text.
	Opens_A_Page, // A part of a link that opens a page: a press, or Enter with the focus, shows it.
}
Row_Part_Flags :: bit_set[Row_Part_Flag;u8]

// One run of text of the page. The text is in the file of the module, in
// the resource of the link pages, or in built.
Row_Part :: struct {
	text:  string,
	x:     i32, // From the left of the text, in pixels.
	width: i32, // In the font that draws it, in pixels.
	color: graphics.Color,
	font:  interface.Font,
	flags: Row_Part_Flags,
	link:  i32, // Opens_A_Page: the number of its link in page_links, from 1. 0: no link.
}

// Where a link goes (src/md/features/manual_links.md).
Link_Destination_Kind :: enum u8 {
	None, // No page: the link is drawn with no line under it.
	Address, // An address of another host: shown, not opened.
	Module, // The page of a module of the boot image.
	Export, // The page of a module, from the signature of an export.
	Record, // The page of a module, from the description of a record.
	Link_Page, // A page of the resource manual_pages: a term, a heading of a guide, or a declaration that no module describes.
}

Link_Destination :: struct {
	kind:   Link_Destination_Kind,
	index:  int, // Module, Export, Record: the module in the boot image. Link_Page: the page in the resource.
	name:   string, // Export, Record: its name, in the module file.
}

// One link of the page that opens: its target, where it goes, the text of
// its first part (its element name), the row and the part where it starts.
Page_Link :: struct {
	target:      string,
	destination: Link_Destination,
	label:       string,
	first_row:   int,
	first_part:  int,
}

PAGE_LINK_CAPACITY :: 512 // A link past it is drawn with no line, and takes no press.
page_links: [PAGE_LINK_CAPACITY]Page_Link
page_link_count: int
focused_link: int // The link with the focus, from 1. 0: no focus.

row_parts: [ROW_PART_CAPACITY]Row_Part
row_part_count: int
row_count: int // The rows of the page.

// The export or the record that the next page shows first, and the row of
// its signature or of its description on that page, or -1.
wanted_export: string
wanted_record: string
wanted_row: int

// What the documentation texts of the page hold: the entry checks the page
// of the manual itself with these counts.
Page_Marks :: struct {
	bold, italic, code, items, examples, links, links_that_open: int,
}
page_marks: Page_Marks

// page_clear empties the page, its heading too.
page_clear :: proc "contextless" () {
	row_part_count, row_count, built_count, first_line = 0, 0, 0, 0
	page_link_count, focused_link = 0, 0
	page_marks = {}
	page_heading, page_heading_color, heading_rows = "", 0, 0
}

// The heading of the page: its title, at the heading size, over the rows
// (docs/DESIGN.md, "5. Text"). It is not a row: the rows keep one height,
// so the scroll counts rows and a press finds its row by a division. The
// heading takes whole rows of the text column instead, its lines and a gap
// under them, and it stays when the rows move.
page_heading: string // In the module file, the resource of the link pages or built.
page_heading_color: graphics.Color
heading_rows: int // The rows of the text column that the heading takes.

// heading_set gives the page its heading, and computes the rows that it
// takes: its lines at the heading size in the width of the text, never
// cut, and a gap under them.
heading_set :: proc "contextless" (text: string, color: graphics.Color) {
	measure_table.interface_font = display.interface_font_of()
	page_heading, page_heading_color = text, color
	height := interface.heading_height(&measure_table, text, TEXT_WIDTH) + graphics.GAP
	heading_rows = (height + CELL_HEIGHT - 1) / CELL_HEIGHT
}

// view_rows gives the rows of the page that the window shows: the rows of
// the text column under the heading. A heading of many lines leaves one
// row at least.
view_rows :: proc "contextless" () -> int {
	return max(ROWS - heading_rows, 1)
}

// rows_top gives the y of the first row that the window shows: under the
// heading.
rows_top :: proc "contextless" () -> int {
	return MARGIN + heading_rows * CELL_HEIGHT
}

// row_part_add adds a part to the page. It gives false when the page is
// full.
row_part_add :: proc "contextless" (part: Row_Part) -> bool {
	if row_part_count >= ROW_PART_CAPACITY {
		return false
	}
	row_parts[row_part_count] = part
	row_part_count += 1
	row_count += int(.Row_Start in part.flags)
	return true
}

// put adds a text in the font of the cells, at an indentation in cells: one
// row when it fits in the width of the text, else one row for each of its
// lines (interface.text_wrap_line), each at the indentation. No byte of the
// text is left out: a signature or a fact that is longer than the window
// is read whole. An empty text is an empty row.
put :: proc "contextless" (text: string, indent: int, color: graphics.Color) {
	x := i32(indent * CELL_WIDTH)
	if len(text) == 0 {
		row_part_add({x = x, color = color, flags = {.Row_Start}})
		return
	}
	room := max(COLUMNS - indent, 1) * CELL_WIDTH
	rest := text
	for len(rest) > 0 {
		line: string
		line, rest = interface.text_wrap_line(nil, {}, rest, room)
		row_part_add({text = line, x = x, width = i32(len(line) * CELL_WIDTH), color = color, flags = {.Row_Start}})
	}
}

// fits_after says if a text of the font of the cells, at an indentation in
// cells, ends inside the width of the text.
fits_after :: proc "contextless" (text: string, indent: int) -> bool {
	return indent + len(text) <= COLUMNS
}

// line_join puts the last row on the row before it: a row with two colors.
line_join :: proc "contextless" () {
	if row_part_count >= 2 && .Row_Start in row_parts[row_part_count - 1].flags {
		row_parts[row_part_count - 1].flags -= {.Row_Start}
		row_count -= 1
	}
}

// rows gives the count of rows that the page takes in the window.
rows :: proc "contextless" () -> int {
	return row_count
}

// The font, the color and the signs of a word of a documentation text.
Text_Style :: struct {
	font:  interface.Font,
	color: graphics.Color,
	flags: Row_Part_Flags,
	link:  i32, // The number of its link in page_links, from 1, or 0.
}

same_style :: proc "contextless" (first, second: Text_Style) -> bool {
	return first.font == second.font && first.color == second.color && first.flags == second.flags && first.link == second.link
}

// One word of the row that is being filled, or a part of a word where its
// style changes.
Piece :: struct {
	text:  string,
	style: Text_Style,
	x:     int,
	width: int,
	glued: bool, // No space is between it and the piece before: the two are one word, and a row is never broken between them.
}

PIECE_CAPACITY :: 128

// The state of the layout of one documentation text.
Flow :: struct {
	base_indent:  int, // The indentation of the text, in pixels.
	color:        graphics.Color, // The color of its plain words.
	left:         int, // Where a row of the block starts.
	space:        int, // The width of the space between two words.
	space_before: bool, // A space is before the next word.
	any_block:    bool, // The text has a block already.
	lines:        bool, // The block is an example: each span is one row, as it is.
	mark_on_row:  bool, // The mark of a list item is on the row that is being filled: the row has its start.
	pieces:       [PIECE_CAPACITY]Piece,
	piece_count:  int,
	// The link of the spans that are being placed: the spans of one link
	// share the range of its target in the text, so a new range is a new
	// link. -1: the last span was no link.
	link_target_start: int,
	link_number:       i32, // Its number in page_links, or 0 when it does not open.
	// The address of the last link, "(https://...)", which follows its
	// label when the link ends.
	pending_address:   string,
}
flow: Flow

// A table with no record: the measure of a text reads only its font.
measure_table: interface.Draw_Table

measure :: proc "contextless" (font: interface.Font, text: string) -> int {
	return interface.text_measured_width(&measure_table, font, text)
}

// put_markdown adds the rows of a documentation text, at an indentation in
// cells. No word is cut, unless it is longer than a row; no text is left
// out.
put_markdown :: proc "contextless" (text: string, indent: int, color: graphics.Color) {
	measure_table.interface_font = display.interface_font_of()
	flow.base_indent, flow.color = indent * CELL_WIDTH, color
	flow.left = flow.base_indent
	flow.space = max(measure(interface.FONT_INTERFACE, " "), 2)
	flow.space_before, flow.any_block, flow.lines, flow.mark_on_row = false, false, false, false
	flow.piece_count = 0
	flow.link_target_start, flow.link_number, flow.pending_address = -1, 0, ""
	markdown.read(text, {block = markdown_block, span = markdown_span})
	link_address_place()
	row_flush(flow.piece_count)
}

markdown_block :: proc "contextless" (data: rawptr, text: string, block: markdown.Block) {
	link_address_place()
	flow.link_target_start, flow.link_number = -1, 0
	row_flush(flow.piece_count)
	if block.after_empty_line && flow.any_block {
		put("", 0, 0)
	}
	flow.any_block = true
	flow.space_before, flow.mark_on_row = false, false
	flow.lines = block.kind == .Fenced || block.kind == .Example
	indent := flow.base_indent + int(block.depth) * LIST_INDENT
	switch block.kind {
	case .List_Item:
		mark := "-"
		if block.ordered {
			// The label and the period after it.
			mark = text[block.mark_start:min(block.mark_end + 1, len(text))]
		}
		row_part_add({text = mark, x = i32(indent), width = i32(len(mark) * CELL_WIDTH), color = graphics.colors.dim, flags = {.Row_Start, .From_Markdown}})
		flow.left = indent + (len(mark) + 1) * CELL_WIDTH
		flow.mark_on_row = true
		page_marks.items += 1
	case .Paragraph, .Fenced, .Example:
		flow.left = indent + (block.inside_item ? LIST_INDENT : 0)
		page_marks.examples += int(flow.lines)
	}
	// A deep item keeps room for words.
	flow.left = min(flow.left, TEXT_WIDTH - 16 * CELL_WIDTH)
}

markdown_span :: proc "contextless" (data: rawptr, text: string, span: markdown.Span) {
	part := text[span.start:span.end]
	if flow.lines {
		code_line(part)
		return
	}
	style := Text_Style {
		font  = interface.FONT_INTERFACE,
		color = flow.color,
		flags = {.From_Markdown},
	}
	bold := .Bold in span.styles
	switch {
	case .Code in span.styles:
		// Code is a text that a reader copies: the font of the cells.
		style.font = bold ? interface.FONT_BOLD : interface.Font{}
		style.color = graphics.colors.text
		page_marks.code += 1
	case bold:
		style.font = interface.FONT_INTERFACE_BOLD
	}
	page_marks.bold += int(bold)
	if .Italic in span.styles {
		style.flags += {.Underlined}
		page_marks.italic += 1
	}
	if .Link in span.styles {
		style.color = graphics.colors.link
		if span.target_start != flow.link_target_start {
			link_begin(text, span)
		}
		if flow.link_number != 0 {
			style.flags += {.Opens_A_Page}
			style.link = flow.link_number
		}
	} else {
		link_address_place()
		flow.link_target_start, flow.link_number = -1, 0
	}
	index := 0
	for index < len(part) {
		if is_space(part[index]) {
			flow.space_before = true
			index += 1
			continue
		}
		end := index
		for end < len(part) && !is_space(part[end]) {
			end += 1
		}
		word_place(part[index:end], style)
		index = end
	}
}

is_space :: proc "contextless" (character: u8) -> bool {
	return character == ' ' || character == '\n' || character == '\t' || character == '\r'
}

// code_line adds a line of an example as a row, as it is. A line that is
// longer than the row goes on the next rows, broken at a space when it has
// one.
code_line :: proc "contextless" (line: string) {
	columns := max((TEXT_WIDTH - flow.left) / CELL_WIDTH, 1)
	rest := line
	for first := true; first || len(rest) > 0; first = false {
		cut := len(rest)
		if cut > columns {
			cut = columns
			for cut > 0 && rest[cut] != ' ' {
				cut -= 1
			}
			if cut == 0 {
				cut = columns // A word longer than the row.
			}
		}
		row_part_add({text = rest[:cut], x = i32(flow.left), width = i32(cut * CELL_WIDTH), color = graphics.colors.text, flags = {.Row_Start, .Code_Block, .From_Markdown}})
		rest = rest[cut:]
		for len(rest) > 0 && len(rest) < len(line) && rest[0] == ' ' {
			rest = rest[1:]
		}
	}
}

// word_place puts a word on the row that is being filled, or on the next
// row when it does not fit. A word that follows another with no space (a
// bold word and the comma after it) moves to the next row with it. Only a
// word that is longer than a row is cut.
word_place :: proc "contextless" (word: string, style: Text_Style) {
	rest := word
	glued := !flow.space_before && flow.piece_count > 0
	flow.space_before = false
	for len(rest) > 0 {
		if flow.piece_count == PIECE_CAPACITY {
			row_flush(flow.piece_count)
			glued = false
		}
		// A text in the interface font has a limit of bytes: a longer one
		// is drawn in another font than the font that measured it.
		head := rest[:min(len(rest), interface.INTERFACE_TEXT_LIMIT)]
		x := flow.left
		if flow.piece_count > 0 {
			last := flow.pieces[flow.piece_count - 1]
			x = last.x + last.width + (glued ? 0 : flow.space)
		}
		width := measure(style.font, head)
		if x + width <= TEXT_WIDTH {
			flow.pieces[flow.piece_count] = {text = head, style = style, x = x, width = width, glued = glued}
			flow.piece_count += 1
			rest = rest[len(head):]
			glued = true
			continue
		}
		if flow.piece_count > 0 {
			// The first piece of the word that this piece is a part of.
			unit := flow.piece_count
			if glued {
				unit -= 1
				for unit > 0 && flow.pieces[unit].glued {
					unit -= 1
				}
			}
			if unit > 0 {
				row_flush(unit)
				continue
			}
		}
		// The word is longer than a row: it is cut where the row ends.
		fit := interface.text_fit(&measure_table, style.font, head, TEXT_WIDTH - x)
		if len(fit) == 0 {
			if flow.piece_count > 0 {
				row_flush(flow.piece_count)
				glued = false
				continue
			}
			fit = head[:1]
		}
		flow.pieces[flow.piece_count] = {text = fit, style = style, x = x, width = measure(style.font, fit), glued = glued}
		flow.piece_count += 1
		rest = rest[len(fit):]
		glued = true
		if len(rest) > 0 {
			row_flush(flow.piece_count)
			glued = false
		}
	}
}

// row_flush ends the row with the first `count` pieces, and starts the next
// row with the others. Pieces of one style that follow each other in the
// text with one space between them are one part of the row: one record of text for
// the frame, and the font spaces their letters as one text.
row_flush :: proc "contextless" (count: int) {
	if count <= 0 {
		return
	}
	x := flow.pieces[0].x
	index := 0
	for index < count {
		piece := flow.pieces[index]
		if index > 0 && !piece.glued {
			x += flow.space
		}
		merged := piece.text
		index += 1
		for index < count {
			next := flow.pieces[index]
			gap := next.glued ? 0 : 1
			if !same_style(next.style, piece.style) || len(merged) + gap + len(next.text) > interface.INTERFACE_TEXT_LIMIT {
				break
			}
			if uintptr(raw_data(next.text)) != uintptr(raw_data(merged)) + uintptr(len(merged) + gap) {
				break
			}
			// The byte between the two is in the text: the next piece is
			// after it.
			if gap == 1 && raw_data(merged)[len(merged)] != ' ' {
				break
			}
			merged = string(raw_data(merged)[:len(merged) + gap + len(next.text)])
			index += 1
		}
		width := measure(piece.style.font, merged)
		flags := piece.style.flags
		if !flow.mark_on_row {
			flags += {.Row_Start}
		}
		flow.mark_on_row = true // The row has its start: the next parts are on it.
		link := piece.style.link
		if row_part_add({text = merged, x = i32(x), width = i32(width), color = piece.style.color, font = piece.style.font, flags = flags, link = link}) && link > 0 && int(link) <= page_link_count {
			// The first part of a link gives its row, its place and its
			// element name.
			link_record := &page_links[link - 1]
			if link_record.first_part < 0 {
				link_record.first_part, link_record.first_row = row_part_count - 1, row_count - 1
				if link_record.label == "" {
					link_record.label = merged
				}
			}
		}
		x += width
	}
	flow.mark_on_row = false
	kept := flow.piece_count - count
	if kept > 0 {
		shift := flow.pieces[count].x - flow.left
		for place in 0 ..< kept {
			flow.pieces[place] = flow.pieces[count + place]
			flow.pieces[place].x -= shift
		}
		flow.pieces[0].glued = false
	}
	flow.piece_count = kept
}

// link_begin starts a new link of the documentation text: it finds where
// its target goes, and gives it a number in page_links when it opens.
link_begin :: proc "contextless" (text: string, span: markdown.Span) {
	link_address_place()
	flow.link_target_start, flow.link_number = span.target_start, 0
	page_marks.links += 1
	target := text[span.target_start:span.target_end]
	destination := link_resolve(target)
	switch destination.kind {
	case .None:
	case .Address:
		// The bytes around the target are "(" and ")" when the reader
		// found a link of Markdown, its label in square brackets and its
		// target in parentheses: the address is shown with them.
		flow.pending_address = target
		if span.target_start > 0 && span.target_end < len(text) && text[span.target_start - 1] == '(' && text[span.target_end] == ')' {
			flow.pending_address = text[span.target_start - 1:span.target_end + 1]
		}
	case .Module, .Export, .Record, .Link_Page:
		if page_link_count >= PAGE_LINK_CAPACITY {
			return
		}
		page_links[page_link_count] = {target = target, destination = destination, label = link_label(text, span.target_start), first_row = -1, first_part = -1}
		page_link_count += 1
		flow.link_number = i32(page_link_count)
		page_marks.links_that_open += 1
	}
}

// link_label gives the whole label of a link, in built, from the bytes of
// a link of Markdown (its label in square brackets, its target in
// parentheses) before its target: with no marks of code or bold, and
// a line feed as a space. A link that wraps keeps one name. It gives ""
// when the bytes before the target are not "](", and the text of the first
// part of the link is its label then.
link_label :: proc "contextless" (text: string, target_start: int) -> string {
	if target_start < 2 || target_start > len(text) || text[target_start - 1] != '(' || text[target_start - 2] != ']' {
		return ""
	}
	label_end := target_start - 2
	label_start := label_end
	for label_start > 0 && text[label_start - 1] != '[' {
		label_start -= 1
	}
	writer := system.Writer {
		buffer = built[built_count:],
	}
	for index in label_start ..< label_end {
		switch text[index] {
		case '`', '*':
		case '\n', '\r', '\t':
			system.write_part(&writer, " ")
		case:
			system.write_part(&writer, text[index:index + 1])
		}
	}
	built_count += writer.count
	return system.written(&writer)
}

// link_address_place puts the address of the link that just ended after
// its label: in the font of the cells, in the dim color.
link_address_place :: proc "contextless" () {
	if flow.pending_address == "" {
		return
	}
	address := flow.pending_address
	flow.pending_address = ""
	flow.space_before = true
	word_place(address, {font = {}, color = graphics.colors.dim, flags = {.From_Markdown}})
}

// link_resolve gives where the target of a link goes
// (src/md/features/manual_links.md, "The chosen form"): an address is
// shown; a term and a guide open their link page when the resource has
// it; a name opens a module, a module and its export, or a record that a
// module describes, first in the module of the page, and else the link
// page of its declaration when the resource has it.
link_resolve :: proc "contextless" (target: string) -> Link_Destination {
	switch manual_pages.link_target_kind(target) {
	case .Address:
		return {kind = .Address}
	case .Term, .Guide:
		if index, found := manual_pages.find(link_pages, target); found {
			return {kind = .Link_Page, index = index}
		}
		return {}
	case .Name:
	}
	name, export := target, ""
	for place in 0 ..< len(target) {
		if target[place] == '.' {
			name, export = target[:place], target[place + 1:]
			break
		}
	}
	if len(export) > 2 && export[len(export) - 2:] == "()" {
		export = export[:len(export) - 2]
	}
	if index := find(name); index >= 0 {
		if file := file_of(&system.image_entries(image)[index]); file != nil {
			if export == "" {
				return {kind = .Module, index = index}
			}
			head, _ := module.header(file)
			for export_index in 1 ..< module.count(file, .Exports) {
				function, ok := module.function(file, export_index)
				if ok && export_index != head.entry_export && function.name_count != 0 && module.string_at(file, function.name_offset, function.name_count) == export {
					return {kind = .Export, index = index, name = export}
				}
			}
		}
	}
	// A record: the last name of the target ("information.Module" names the
	// record Module). The package of a declaration is no module name, so
	// the module of the page comes first.
	record := target
	for place := len(target) - 1; place >= 0; place -= 1 {
		if target[place] == '.' {
			record = target[place + 1:]
			break
		}
	}
	if page_kind == .Module && record_described(selected, record) {
		return {kind = .Record, index = selected, name = record}
	}
	for index in 0 ..< len(system.image_entries(image)) {
		if record_described(index, record) {
			return {kind = .Record, index = index, name = record}
		}
	}
	// A declaration that no module describes: its page, which the build
	// took from the sources, under the target of the link.
	if index, found := manual_pages.find(link_pages, target); found {
		return {kind = .Link_Page, index = index}
	}
	return {}
}

// record_described says if a module of the boot image describes a record
// with this name.
record_described :: proc "contextless" (index: int, name: string) -> bool {
	entries := system.image_entries(image)
	if index < 0 || index >= len(entries) || name == "" {
		return false
	}
	file := file_of(&entries[index])
	if file == nil {
		return false
	}
	for record_index in 1 ..< module.count(file, .Records) {
		if described, ok := module.record_type(file, record_index); ok && module.string_at(file, described.name_offset, described.name_count) == name {
			return true
		}
	}
	return false
}

// link_at_place gives the number of the link that opens a page at a place
// of the window, or 0.
link_at_place :: proc "contextless" (x, y: int) -> int {
	left := LIST_WIDTH + MARGIN
	top := rows_top()
	if y < top || y >= top + view_rows() * CELL_HEIGHT {
		return 0
	}
	wanted := first_line + (y - top) / CELL_HEIGHT
	row := -1
	for &part in row_parts[:row_part_count] {
		row += int(.Row_Start in part.flags)
		if row > wanted {
			break
		}
		if row == wanted && part.link > 0 && x >= left + int(part.x) && x < left + int(part.x + part.width) {
			return int(part.link)
		}
	}
	return 0
}

// link_open shows the page of a link of the page, by its number, and keeps
// the page that it leaves in the history.
link_open :: proc "contextless" (number: int) {
	if number < 1 || number > page_link_count {
		return
	}
	// A copy: the next page clears the table. The target and the label
	// are bytes of a module file, of the resource or of built; the log
	// line is written before the page changes.
	link := page_links[number - 1]
	system.log(.Info, "manual: the link ", link.label, " opens ", link.target)
	navigation_leave()
	destination_show(link.destination)
}

// destination_show shows the page where a link goes, and writes it on the
// log.
destination_show :: proc "contextless" (destination: Link_Destination) {
	switch destination.kind {
	case .None, .Address:
	case .Module, .Export, .Record:
		// The bytes of the name are in the boot image or in the resource:
		// they stay when the page changes.
		wanted_export = destination.kind == .Export ? destination.name : ""
		wanted_record = destination.kind == .Record ? destination.name : ""
		select(destination.index)
		wanted_export, wanted_record = "", ""
		if wanted_row >= 0 {
			first_line = clamp(wanted_row, 0, max(rows() - view_rows(), 0))
		}
		page_log()
	case .Link_Page:
		link_page_build(destination.index)
		page_log()
	}
}

// link_focus_move moves the focus to the next link of the page that opens,
// or to the one before, and scrolls the page so that the view shows it.
link_focus_move :: proc "contextless" (backward: bool) {
	first_in_view := page_link_count
	for index in 0 ..< page_link_count {
		if page_links[index].first_row >= first_line {
			first_in_view = index
			break
		}
	}
	next := manual_navigation.focus_step(page_link_count, focused_link - 1, first_in_view, backward)
	if next < 0 {
		focused_link = 0
		system.log_fact(.Info, No_Link_That_Opens{})
		return
	}
	focused_link = next + 1
	link := &page_links[next]
	if link.first_row >= 0 && (link.first_row < first_line || link.first_row >= first_line + view_rows()) {
		first_line = clamp(link.first_row - view_rows() / 3, 0, max(rows() - view_rows(), 0))
	}
	system.log(.Info, "manual: the focus is on the link ", link.label, " to ", link.target)
}

// The link pages: the resource manual_pages of the boot image, validated
// once at the start. With no valid resource, a link to a term or a guide
// has no page.
link_pages: manual_pages.Pages

// link_pages_open finds the resource of the link pages, checks the hash of
// its bytes against its entry and its format, and writes the result on
// the log.
link_pages_open :: proc "contextless" () {
	entry := system.image_resource_find(image, manual_pages.RESOURCE_NAME)
	if entry == nil {
		system.log_fact(.Info, No_Link_Pages{})
		return
	}
	bytes := image[entry.offset:][:entry.size]
	if blake3.hash(bytes) != entry.hash {
		system.log_fact(.Warning, Link_Pages_Hash_Wrong{})
		return
	}
	pages, problem := manual_pages.validate(bytes)
	if problem != .None {
		system.log_fact(.Warning, Link_Pages_Refused{rule = u64(problem)})
		return
	}
	link_pages = pages
	system.log_fact(.Info, Link_Pages_Read{pages = u64(pages.count)})
}

// link_page_build writes a link page: its title as its heading, where it
// comes from, and its text.
link_page_build :: proc "contextless" (index: int) {
	page_clear()
	wanted_row = -1
	page_kind, link_page_index = .Link_Page, index
	target := manual_pages.target_of(link_pages, index)
	heading_set(manual_pages.title_of(link_pages, index), graphics.colors.text)
	source := ""
	switch manual_pages.link_target_kind(target) {
	case .Term:
		source = "docs/glossary"
	case .Guide:
		source = target
		for place in 0 ..< len(target) {
			if target[place] == '#' {
				source = target[:place]
				break
			}
		}
	case .Name, .Address:
		// The page of a declaration names its file and its line in its
		// first sentence: a line "from" would say it twice.
	}
	// The gap under the heading starts the text; the line of the source
	// has an empty row under it.
	if source != "" {
		put_built(0, graphics.colors.dim, "from ", source)
		put("", 0, 0)
	}
	put_markdown(manual_pages.text_of(link_pages, index), 0, graphics.colors.text)
}

// markdown_check checks the documentation texts of the page that the
// window shows, and writes the result on the log. The entry runs it on the
// page of the manual itself, whose comments use each of these marks.
markdown_check :: proc "contextless" () {
	widest := 0
	marks_left := 0
	for &part in row_parts[:row_part_count] {
		if .From_Markdown not_in part.flags {
			continue
		}
		widest = max(widest, int(part.x + part.width))
		if part.font.kind != .Interface {
			continue // Code keeps its signs.
		}
		for character, place in part.text {
			if character == '`' || character == '*' && place + 1 < len(part.text) && part.text[place + 1] == '*' {
				marks_left += 1
			}
		}
	}
	marks := page_marks
	if marks.bold > 0 && marks.italic > 0 && marks.code > 0 && marks.items > 0 && marks.links_that_open > 0 && marks_left == 0 && widest <= TEXT_WIDTH {
		system.log_fact(.Info, Markdown_Check_Passed{})
		return
	}
	system.log_fact(.Info, Markdown_Check_Failed{bold = u64(marks.bold), italics = u64(marks.italic), code = u64(marks.code), list_items = u64(marks.items), links_that_open = u64(marks.links_that_open), links = u64(marks.links), marks_left = u64(marks_left), widest = u64(widest), text_width = u64(TEXT_WIDTH)})
}
