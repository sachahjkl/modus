// A light web browser in one window: an address field, a history, and a
// page of HTML and CSS. The contract package html_css lays out and paints
// the page. The design: src/md/features/desktop_to_browser.md, "E. A light
// browser".
//
// **What it is for.** It shows the path of a page from its bytes to the
// draw table: html_css parses the HTML into a bounded tree of nodes, reads
// its style sheets, resolves the cascade, lays out block, inline and flex
// boxes, and paints them as draw records. The window copies the records
// that its view shows into its own draw table. Each page is parsed under
// its document origin by the origin worker of that origin, and the state
// of one origin is refused to a page of another.
//
// **Start**: `start("browser")` in the console.
//
// **Grants**: Serve, for its settings (settings.odin), and Store, which
// keeps them. The pages that it shows are built into it (modus://welcome,
// modus://properties, modus://guide, modus://forms). An address of HTTP or HTTPS gets a page that shows the
// request that the worker of its origin writes, and says that this window
// has no grant of the network.
//
// **What a reader sees.** A window that the principal resizes, laid out by
// the layout tree of modus:layout (src/md/features/box_layout.md). The top
// band: back, forward, reload, the address field in its recessed well, go,
// and the origin badge of the page. Under it, the bookmarks band: one
// button for each page built in, the page shown marked. Then the page with
// its scroll bar. The status band: the title of the
// page, its nodes and its document boxes, then the address of the link under
// the pointer, or what the last act did.
//
// **Keys**: Enter in the address field loads its address, and in a field of
// a form sends the form. Page Up, Page Down, Home, End, Up and Down scroll
// the page; the wheel scrolls it too. Tab moves the focus.
package browser

import "modus:contract/draw_record"
import "modus:contract/html_css"
import "modus:contract/value_kinds"
import "modus:display"
import "modus:graphics"
import "modus:interface"
import "modus:kept_choices"
import box_layout "modus:layout"
import "modus:system"

// The window opens at WIDTH by HEIGHT; the principal resizes it from
// LEAST_WIDTH by LEAST_HEIGHT up to LARGEST_WIDTH by LARGEST_HEIGHT
// (src/md/features/window_resize.md). Literals, so the tool reads the
// window of the budget.
WIDTH :: 840
HEIGHT :: 600
LEAST_WIDTH :: 640
LEAST_HEIGHT :: 420
LARGEST_WIDTH :: 1280
LARGEST_HEIGHT :: 900
#assert(LEAST_WIDTH <= WIDTH && WIDTH <= LARGEST_WIDTH)
#assert(LEAST_HEIGHT <= HEIGHT && HEIGHT <= LARGEST_HEIGHT)

// The tool counts the module, its imports, its load, its two threads and its
// resizable window at the largest scale. Post-ready document arenas, the glyph
// memory and a second resize surface draw from browser's default plan budget
// row (64 MiB); a larger page takes what the budget holds and is cut past it.
MODULE_BUDGET :: system.Stated_Budget{processes = 1, threads = 2, window_width = LARGEST_WIDTH, window_height = LARGEST_HEIGHT, window_least_width = LEAST_WIDTH, window_least_height = LEAST_HEIGHT}

LINE :: graphics.LINE_HEIGHT
ROW_HEIGHT :: interface.TABLE_LINE // A text field and a button.
TOP_BAND_HEIGHT :: ROW_HEIGHT + 2 * graphics.GAP
STATUS_BAND_HEIGHT :: 2 * LINE + 8
NAVIGATION_BUTTON_WIDTH :: 40
// "reload" in the interface font, with the room of a button at each side.
RELOAD_BUTTON_WIDTH :: 72
GO_BUTTON_WIDTH :: 56
// The top band holds at the least width of the window: two gaps of
// padding, five gaps between six boxes, back, forward, reload, the least
// address field, go, and the badge of "origin modus://properties".
ADDRESS_LEAST_WIDTH :: 140
// The well of the address field: the field lies this far inside it.
ADDRESS_WELL_INSET :: 2
// The badge of the origin: its mark, a square in the color of an expected
// state, and the room from the mark to the text.
ORIGIN_MARK_SIZE :: 8
ORIGIN_MARK_ROOM :: ORIGIN_MARK_SIZE + 6
#assert(2 * graphics.GAP + 5 * graphics.GAP + 2 * NAVIGATION_BUTTON_WIDTH + RELOAD_BUTTON_WIDTH + ADDRESS_LEAST_WIDTH + GO_BUTTON_WIDTH + 2 * graphics.GAP + ORIGIN_MARK_ROOM + len("origin modus://properties") * graphics.CELL_WIDTH <= LEAST_WIDTH)
// The bookmarks band: a row of buttons, BOOKMARK_HEIGHT high, with the
// room of the band around them.
BOOKMARK_HEIGHT :: 22
BOOKMARK_BAND_HEIGHT :: BOOKMARK_HEIGHT + 2 * 5
// The room inside a bookmark, at each side of its label.
BOOKMARK_PADDING :: 12
// The bevel of a button: a light line on its top edge and a dark line on
// its bottom edge, at these alphas.
BEVEL_LIGHT_ALPHA :: 56
BEVEL_DARK_ALPHA :: 48
// A wheel notch or an arrow key moves the page by this, and a page key by
// the view less this, so a line of the view before stays in sight.
SCROLL_LINE :: 3 * LINE

// The back and forward history: the addresses of the pages that the window
// showed, and the scroll of each when the window left it.
HISTORY_CAPACITY :: 256

History_Entry :: struct {
	address: [ADDRESS_CAPACITY]u8,
	count:   int,
	scroll:  int,
}

history: [HISTORY_CAPACITY]History_Entry
history_count: int // The entries in use.
history_place: int // The entry of the page shown.

// The page shown: its address, what it is, and the buffers of its source.
current: Address
current_kind: Page_Kind
// What the origin worker gave for the page shown.
current_render: Origin_Render_Tree
// The page alone, kept so that a change of the appearance composes the
// document again with the other style sheet.
page_source: [PAGE_SOURCE_CAPACITY]u8
page_source_count: int
document_source: [DOCUMENT_SOURCE_CAPACITY]u8
document_source_count: int
loaded_appearance: graphics.Appearance
scroll: int
view_width: i32 = WIDTH - interface.SCROLL_BAR_THICKNESS
view_height: i32 = HEIGHT - TOP_BAND_HEIGHT - BOOKMARK_BAND_HEIGHT - STATUS_BAND_HEIGHT

// The text of the address field.
address_field: [ADDRESS_CAPACITY]u8
address_field_count: int

// The second line of the status band: what the last act did.
status_text: [ADDRESS_CAPACITY + 96]u8
status_count: int
status_failed: bool

window_memory: interface.Window_Memory(2048, 65536)

// The layout tree of each frame and the state of its boxes across frames.
// They are large: they live in the memory of the module, never on the
// stack (src/md/features/box_layout.md, "Constraints").
box_tree: box_layout.Box_Tree
box_states: box_layout.Box_States
tokens: box_layout.Element_Tokens

// What a frame asked for: an act runs after the frame, as it changes the
// document that the frame drew.
Act_Kind :: enum u8 {
	None,
	Back,
	Forward,
	Reload,
	Load_Address_Field,
	Follow_Link,
	Send_Form,
	Open_Bookmark,
}

Act :: struct {
	kind:     Act_Kind,
	node:     u32, // The element a of a link, or the form to send.
	bookmark: Built_In_Page, // The page of a bookmark.
}

// The label of the bookmark of each page built in.
@(rodata)
BOOKMARK_LABELS := [Built_In_Page]string {
	.Welcome    = "Welcome",
	.Properties = "Properties",
	.Guide      = "Guide",
	.Forms      = "Forms",
}

// The addresses that the bookmarks load.
@(rodata)
BOOKMARK_ADDRESSES := [Built_In_Page]string {
	.Welcome    = "modus://welcome",
	.Properties = "modus://properties",
	.Guide      = "modus://guide",
	.Forms      = "modus://forms",
}

// The boxes of the window that the frame draws into.
Window_Boxes :: struct {
	top_band, back, forward, reload, address, go, origin:  box_layout.Box_Index,
	bookmark_band:                                         box_layout.Box_Index,
	bookmarks:                                             [Built_In_Page]box_layout.Box_Index,
	page, scroll_bar:                                      box_layout.Box_Index,
	status_band, status_title, status_counts, status_line: box_layout.Box_Index,
}

area_of :: proc "contextless" (index: box_layout.Box_Index) -> interface.Area {
	box := box_layout.box_of(&box_tree, index)
	if box == nil {
		return {}
	}
	return {int(box.rect.x), int(box.rect.y), int(box.rect.width), int(box.rect.height)}
}

status_set :: proc "contextless" (failed: bool, parts: ..string) {
	writer := Source_Writer{bytes = status_text[:]}
	for part in parts {
		put(&writer, part)
	}
	status_count, status_failed = writer.count, failed
}

// document_build composes the style sheet of the appearance and the page,
// and sends them to the worker of the origin of the address, which parses
// them and lays the document out at the width of the view.
document_build :: proc "contextless" (page: string) {
	loaded_appearance = graphics.appearance
	writer := Source_Writer{bytes = document_source[:]}
	put(&writer, "<html><head><style>")
	put(&writer, APPEARANCE_STYLES[loaded_appearance])
	put(&writer, "</style></head>")
	put(&writer, page)
	document_source_count = writer.count
	origin := origin_of(&current)
	current_render = origin_render_ask(&origin, document_source[:document_source_count], view_width)
}

// page_forms_keep asks the origin of the page shown to keep the values of
// its fields, or to give them back, under the path of the page.
page_forms_keep :: proc "contextless" (kind: Origin_Request_Kind) {
	own := origin_of(&current)
	request := origin_request_make(kind, &own, &own, address_path(&current))
	origin_ask(&request)
}

// page_load loads the page of an address. A history push makes it the
// entry after the page shown, and drops the entries after that one. false:
// the browser refuses the address, and the page shown stays.
page_load :: proc "contextless" (text: string, history_push: bool) -> bool {
	address, problem := address_parse(text)
	if problem != .None {
		status_set(true, "refused: ", ADDRESS_PROBLEM_SENTENCES[problem])
		system.log_fact(.Info, Address_Refused{}, ADDRESS_PROBLEM_SENTENCES[problem], text)
		return false
	}
	// The values typed in the page shown stay with its origin.
	if history_count > 0 {
		page_forms_keep(.Forms_Save)
	}
	current = address
	page_writer := Source_Writer{bytes = page_source[:]}
	current_kind = page_write(&page_writer, &current)
	page_source_count = page_writer.count
	document_build(writer_text(&page_writer))
	// Back, forward and reload give a page the values that it had.
	if !history_push {
		page_forms_keep(.Forms_Restore)
	}
	canonical: [ADDRESS_CAPACITY + 8]u8
	canonical_writer := Source_Writer{bytes = canonical[:]}
	address_write(&canonical_writer, &current)
	canonical_text := writer_text(&canonical_writer)
	address_field_count = copy(address_field[:], canonical_text)
	if history_push {
		if history_count > 0 {
			history[history_place].scroll = scroll
			history_place += 1
		}
		if history_place >= HISTORY_CAPACITY {
			// The oldest entry leaves: the history keeps the newest ones.
			copy(history[:HISTORY_CAPACITY - 1], history[1:])
			history_place = HISTORY_CAPACITY - 1
		}
		entry := &history[history_place]
		entry.count = copy(entry.address[:], canonical_text)
		entry.scroll = 0
		history_count = history_place + 1
		scroll = 0
	}
	status_count = 0
	if page_writer.full {
		status_set(true, "the page is longer than the buffer of the window: its end is cut")
	}
	system.log_fact(.Info, Page_Loaded{nodes = u64(current_render.node_count), rules = u64(current_render.rule_count), boxes = u64(current_render.box_count), records = u64(current_render.record_count), bytes = u64(document_source_count), kind = value_kinds.text_field(PAGE_KIND_WORDS[current_kind], PAGE_KIND_FIELD_BYTES)}, canonical_text)
	return true
}

// history_go shows the entry of the history at a place, at the scroll that
// it had when the window left it.
history_go :: proc "contextless" (place: int) {
	if place < 0 || place >= history_count || place == history_place {
		return
	}
	history[history_place].scroll = scroll
	history_place = place
	entry := &history[place]
	if page_load(string(entry.address[:entry.count]), false) {
		scroll = entry.scroll
	}
}

// link_follow loads the address of a link, resolved against the page.
link_follow :: proc "contextless" (anchor: u32) {
	href, _ := html_css_attribute(anchor, "href")
	target: [ADDRESS_CAPACITY + 8]u8
	writer := Source_Writer{bytes = target[:]}
	address_resolve(&writer, &current, href)
	from := string(history[history_place].address[:history[history_place].count])
	from_copy: [ADDRESS_CAPACITY]u8
	from_text := string(from_copy[:copy(from_copy[:], from)])
	if page_load(writer_text(&writer), true) {
		system.log_fact(.Info, Link_Followed{}, from_text, writer_text(&writer))
	}
}

// form_send writes the fields of a form into the query of its action and
// loads that address.
form_send :: proc "contextless" (form: u32) {
	action, _ := html_css_attribute(form, "action")
	target: [ADDRESS_CAPACITY + 8]u8
	writer := Source_Writer{bytes = target[:]}
	address_resolve(&writer, &current, action)
	put(&writer, "?")
	fields := 0
	for &field in form_fields[:form_field_count] {
		if field.form != form {
			continue
		}
		if fields > 0 {
			put(&writer, "&")
		}
		put_query_encoded(&writer, string(field.name[:field.name_count]))
		put(&writer, "=")
		put_query_encoded(&writer, string(field.text[:field.count]))
		fields += 1
	}
	if writer.full {
		status_set(true, "refused: the values of the form are longer than an address holds")
		return
	}
	if page_load(writer_text(&writer), true) {
		system.log_fact(.Info, Form_Sent{fields = u64(fields)}, writer_text(&writer))
	}
}

html_css_attribute :: proc "contextless" (node: u32, name: string) -> (value: string, found: bool) {
	bytes, has := html_css.dom_node_attr(&document_tree, node, name)
	return string(bytes), has
}

act_run :: proc "contextless" (act: Act) -> bool {
	// A page that the principal asked for stays when the kept home comes.
	if act.kind != .None && act.kind != .Reload {
		page_chosen_after_start = true
	}
	switch act.kind {
	case .None:
		return false
	case .Back:
		history_go(history_place - 1)
	case .Forward:
		history_go(history_place + 1)
	case .Reload:
		// The page shown, parsed again from its address: the history and
		// the scroll stay.
		entry := &history[history_place]
		page_load(string(entry.address[:entry.count]), false)
	case .Open_Bookmark:
		page_load(BOOKMARK_ADDRESSES[act.bookmark], true)
	case .Load_Address_Field:
		page_load(string(address_field[:address_field_count]), true)
	case .Follow_Link:
		link_follow(act.node)
	case .Send_Form:
		form_send(act.node)
	}
	return true
}

// layout_build makes the layout tree of the window at its size, and solves
// it: the top band, the bookmarks band, the page with its scroll bar, and
// the status band.
layout_build :: proc "contextless" (window: ^display.Window, origin_width, counts_width: int, bookmark_widths: ^[Built_In_Page]int) -> (boxes: Window_Boxes) {
	width := i32(clamp(window.width, 0, box_layout.LENGTH_LIMIT))
	height := i32(clamp(window.height, 0, box_layout.LENGTH_LIMIT))
	gap := tokens.gap
	_ = box_layout.tree_begin(&box_tree, width, height, {label = "browser", child_axis = .Y})
	boxes.top_band, _ = box_layout.box_open(&box_tree, {size = {.X = box_layout.fill(), .Y = box_layout.px(TOP_BAND_HEIGHT)}, child_axis = .X, cross_align = .Center, padding = {.X = gap, .Y = 0}, gap = gap})
	boxes.back, _ = box_layout.box_add(&box_tree, {size = {.X = box_layout.px(NAVIGATION_BUTTON_WIDTH), .Y = box_layout.px(ROW_HEIGHT)}})
	boxes.forward, _ = box_layout.box_add(&box_tree, {size = {.X = box_layout.px(NAVIGATION_BUTTON_WIDTH), .Y = box_layout.px(ROW_HEIGHT)}})
	boxes.reload, _ = box_layout.box_add(&box_tree, {size = {.X = box_layout.px(RELOAD_BUTTON_WIDTH), .Y = box_layout.px(ROW_HEIGHT)}})
	boxes.address, _ = box_layout.box_add(&box_tree, {size = {.X = box_layout.fill_least(ADDRESS_LEAST_WIDTH), .Y = box_layout.px(ROW_HEIGHT)}})
	boxes.go, _ = box_layout.box_add(&box_tree, {size = {.X = box_layout.px(GO_BUTTON_WIDTH), .Y = box_layout.px(ROW_HEIGHT)}})
	boxes.origin, _ = box_layout.box_add(&box_tree, {size = {.X = box_layout.text_size(gap, 10_000), .Y = box_layout.px(ROW_HEIGHT)}, text_width = i32(clamp(origin_width + ORIGIN_MARK_ROOM, 0, box_layout.LENGTH_LIMIT))})
	_ = box_layout.box_close(&box_tree)
	boxes.bookmark_band, _ = box_layout.box_open(&box_tree, {size = {.X = box_layout.fill(), .Y = box_layout.px(BOOKMARK_BAND_HEIGHT)}, child_axis = .X, cross_align = .Center, padding = {.X = gap, .Y = 0}, gap = 6})
	for page in Built_In_Page {
		boxes.bookmarks[page], _ = box_layout.box_add(&box_tree, {size = {.X = box_layout.text_size(BOOKMARK_PADDING, 10_000), .Y = box_layout.px(BOOKMARK_HEIGHT)}, text_width = i32(clamp(bookmark_widths[page], 0, box_layout.LENGTH_LIMIT))})
	}
	_ = box_layout.box_close(&box_tree)
	_, _ = box_layout.box_open(&box_tree, {size = {.X = box_layout.fill(), .Y = box_layout.fill()}, child_axis = .X, overflow = {.X = .Clip, .Y = .Clip}})
	boxes.page, _ = box_layout.box_add(&box_tree, {identity = box_layout.identity_of(PAGE_LABEL), size = {.X = box_layout.fill(), .Y = box_layout.fill()}})
	boxes.scroll_bar, _ = box_layout.box_add(&box_tree, {size = {.X = box_layout.px(interface.SCROLL_BAR_THICKNESS), .Y = box_layout.fill()}})
	_ = box_layout.box_close(&box_tree)
	boxes.status_band, _ = box_layout.box_open(&box_tree, {size = {.X = box_layout.fill(), .Y = box_layout.px(STATUS_BAND_HEIGHT)}, child_axis = .Y, padding = {.X = gap, .Y = 4}})
	_, _ = box_layout.box_open(&box_tree, {size = {.X = box_layout.fill(), .Y = box_layout.px(LINE)}, child_axis = .X, gap = gap})
	boxes.status_title, _ = box_layout.box_add(&box_tree, {size = {.X = box_layout.fill(), .Y = box_layout.px(LINE)}})
	boxes.status_counts, _ = box_layout.box_add(&box_tree, {size = {.X = box_layout.text_size(0, 10_000), .Y = box_layout.px(LINE)}, text_width = i32(clamp(counts_width, 0, box_layout.LENGTH_LIMIT))})
	_ = box_layout.box_close(&box_tree)
	boxes.status_line, _ = box_layout.box_add(&box_tree, {size = {.X = box_layout.fill(), .Y = box_layout.px(LINE)}})
	_ = box_layout.box_close(&box_tree)
	_ = box_layout.solve(&box_tree)
	_ = box_layout.states_record(&box_states, &box_tree)
	return
}

// The identity of the box of the page: its state gives the press that
// follows a link.
PAGE_LABEL :: "browser page"

// origin_label_write writes the origin of the document as the tree holds
// it: the label shows the origin that the parse bound, not a copy of the
// address.
origin_label_write :: proc "contextless" (writer: ^Source_Writer) {
	origin := &document_tree.origin
	put(writer, "origin ")
	put(writer, SCHEME_NAMES[origin.scheme])
	put(writer, "://")
	put(writer, string(origin.host[:origin.host_len]))
	if origin.port != SCHEME_PORTS[origin.scheme] {
		put(writer, ":")
		put_number(writer, u64(origin.port))
	}
}

// draw builds one frame, and gives the act that it asked for.
draw :: proc "contextless" (window: ^display.Window) -> (act: Act) {
	frame := interface.window_frame_start(&window_memory, window)
	table := frame.table
	tokens, _ = box_layout.tokens_for(graphics.appearance, .Standard)
	interface.background(&frame, {0, 0, window.width, window.height})
	input := frame.input
	box_layout.states_frame_begin(&box_states, {pointer_x = i32(clamp(input.pointer_x, int(min(i32)), int(max(i32)))), pointer_y = i32(clamp(input.pointer_y, int(min(i32)), int(max(i32)))), pointer_present = input.pointer_known, primary_down = input.button_held, primary_pressed = input.pressed, primary_released = input.released, primary_press_count = input.pressed ? 1 : 0})
	// The appearance changed: the page takes the style sheet of the new one.
	if graphics.appearance != loaded_appearance {
		page_forms_keep(.Forms_Save)
		document_build(string(page_source[:page_source_count]))
		page_forms_keep(.Forms_Restore)
	}
	origin_buffer: [HOST_CAPACITY + 32]u8
	origin_writer := Source_Writer{bytes = origin_buffer[:]}
	origin_label_write(&origin_writer)
	origin_text := writer_text(&origin_writer)
	counts_buffer: [64]u8
	counts_text := system.format(counts_buffer[:], u64(document_tree.node_count), " nodes, ", u64(document_layout.box_count), " document boxes")
	bookmark_widths: [Built_In_Page]int
	for page in Built_In_Page {
		bookmark_widths[page] = interface.text_measured_width(table, interface.FONT_INTERFACE, BOOKMARK_LABELS[page])
	}
	boxes := layout_build(window, interface.text_measured_width(table, {}, origin_text), interface.text_measured_width(table, {}, counts_text), &bookmark_widths)
	// The page: laid out at the width of its view, scrolled, then painted.
	page := area_of(boxes.page)
	view_width, view_height = i32(max(page.width, 0)), i32(max(page.height, 0))
	document_lay_out(view_width, view_height)
	scroll = clamp(scroll, 0, max(document_height - page.height, 0))
	scrolled := interface.scroll_bar(&frame, area_of(boxes.scroll_bar), interface.identity("browser scroll bar"), .Vertical, {total = max(document_height, page.height), visible = page.height, first = scroll}, {line = SCROLL_LINE, page = max(page.height - LINE, LINE)}, "page", page)
	scroll = scrolled.first
	page_input, _ := box_layout.box_input(&box_states, box_layout.identity_of(PAGE_LABEL))
	hovered: Node_Target
	if input.pointer_known && interface.area_contains(page, input.pointer_x, input.pointer_y) {
		hovered = target_at(input.pointer_x - page.x, input.pointer_y - page.y + scroll)
	}
	if page_input.activated && hovered.kind != .None {
		act = {kind = hovered.kind == .Link ? .Follow_Link : .Send_Form, node = hovered.node}
	}
	document_paint(table, page, scroll, tokens.surface_card)
	fields_draw(&frame, page, &act)
	draw_top_band(&frame, &boxes, origin_text, &act)
	draw_bookmark_band(&frame, &boxes, &act)
	draw_status_band(table, &boxes, counts_text, hovered)
	// The keys that no element took scroll the page.
	for &press in frame.input.keys[:frame.input.key_count] {
		if press.taken {
			continue
		}
		switch press.code {
		case display.KEY_PAGE_UP:
			scroll -= max(page.height - LINE, LINE)
		case display.KEY_PAGE_DOWN:
			scroll += max(page.height - LINE, LINE)
		case display.KEY_HOME:
			scroll = 0
		case display.KEY_END:
			scroll = document_height
		case display.KEY_UP:
			scroll -= SCROLL_LINE
		case display.KEY_DOWN:
			scroll += SCROLL_LINE
		case:
			continue
		}
		press.taken = true
		scroll = clamp(scroll, 0, max(document_height - page.height, 0))
	}
	interface.window_frame_end(&window_memory.drawing, &frame, window)
	return
}

// fields_draw draws an editable field of the interface package over the
// document box of each field of a form that the view shows whole: a press
// outside the view never reaches a field.
fields_draw :: proc "contextless" (frame: ^interface.Frame, page: interface.Area, act: ^Act) {
	base := interface.identity("browser form field")
	for &field, index in form_fields[:form_field_count] {
		if field.box == html_css.NO_NODE {
			continue
		}
		box := &document_layout.boxes[field.box]
		area := interface.Area{page.x + int(box.x), page.y + int(box.y) - scroll, int(box.width), int(box.height)}
		if area.width <= 0 || area.height <= 0 || area.y < page.y || area.y + area.height > page.y + page.height || area.x + area.width > page.x + page.width {
			continue
		}
		if interface.text_input(frame, area, interface.identity_with(base, index), field.text[:], &field.count, string(field.name[:field.name_count])).activated && field.form != html_css.NO_NODE {
			act^ = {kind = .Send_Form, node = field.form}
		}
	}
}

// bevel_draw draws the bevel of a button: a light line on its top edge and
// a dark line on its bottom edge, so the button stands out of its band in
// both appearances.
bevel_draw :: proc "contextless" (table: ^interface.Draw_Table, area: interface.Area) {
	if area.width <= 0 || area.height < 2 {
		return
	}
	interface.draw_rectangle_with_alpha(table, area.x, area.y, area.width, 1, draw_record.with_alpha(graphics.COLOR_WHITE, BEVEL_LIGHT_ALPHA))
	interface.draw_rectangle_with_alpha(table, area.x, area.y + area.height - 1, area.width, 1, draw_record.with_alpha(graphics.COLOR_BLACK, BEVEL_DARK_ALPHA))
}

// bevelled_button draws a button of the interface package with its bevel.
bevelled_button :: proc "contextless" (frame: ^interface.Frame, area: interface.Area, element: interface.Element_Identity, label: string, open := false) -> interface.Element_Result {
	result := interface.button(frame, area, element, label, open)
	bevel_draw(frame.table, area)
	return result
}

// draw_top_band draws back, forward, reload, the address field in its
// recessed well, go, and the origin badge. The address field takes the
// focus when no element has it, so the keys type an address.
draw_top_band :: proc "contextless" (frame: ^interface.Frame, boxes: ^Window_Boxes, origin_text: string, act: ^Act) {
	table := frame.table
	band := area_of(boxes.top_band)
	interface.draw_vertical_gradient(table, band.x, band.y, band.width, band.height, graphics.colors.card_top, graphics.colors.card_bottom)
	interface.draw_rectangle(table, band.x, band.y + band.height - 1, band.width, 1, tokens.divider)
	address_identity := interface.identity("browser address field")
	if frame.state.focus == 0 {
		frame.state.focus = address_identity
	}
	if bevelled_button(frame, area_of(boxes.back), interface.identity("browser back"), "<").activated && history_place > 0 {
		act^ = {kind = .Back}
	}
	if bevelled_button(frame, area_of(boxes.forward), interface.identity("browser forward"), ">").activated && history_place + 1 < history_count {
		act^ = {kind = .Forward}
	}
	if bevelled_button(frame, area_of(boxes.reload), interface.identity("browser reload"), "Reload").activated && history_count > 0 {
		act^ = {kind = .Reload}
	}
	// The well: a recess with a border that a reader sees on each surface,
	// and the field inside it. The field draws its focus ring around it.
	well := area_of(boxes.address)
	interface.draw_rectangle(table, well.x, well.y, well.width, well.height, tokens.surface_recess)
	interface.draw_outline(table, well.x, well.y, well.width, well.height, 1, tokens.border)
	field := interface.Area{well.x + ADDRESS_WELL_INSET, well.y + ADDRESS_WELL_INSET, max(well.width - 2 * ADDRESS_WELL_INSET, 0), max(well.height - 2 * ADDRESS_WELL_INSET, 0)}
	if interface.text_input(frame, field, address_identity, address_field[:], &address_field_count, "An address").activated {
		act^ = {kind = .Load_Address_Field}
	}
	if bevelled_button(frame, area_of(boxes.go), interface.identity("browser go"), "Go").activated {
		act^ = {kind = .Load_Address_Field}
	}
	// The badge of the origin, outlined in the color of an expected state,
	// with its square mark: each origin is isolated, and the badge says
	// which one the page is. Its box is as wide as its whole text.
	badge := area_of(boxes.origin)
	interface.draw_rectangle(table, badge.x, badge.y, badge.width, badge.height, tokens.surface_recess)
	interface.draw_outline(table, badge.x, badge.y, badge.width, badge.height, 1, tokens.expected)
	mark_x := badge.x + int(tokens.gap)
	interface.draw_rectangle(table, mark_x, badge.y + (badge.height - ORIGIN_MARK_SIZE) / 2, ORIGIN_MARK_SIZE, ORIGIN_MARK_SIZE, tokens.expected)
	text_x := mark_x + ORIGIN_MARK_ROOM
	interface.draw_text(table, text_x, badge.y + (badge.height - LINE) / 2, interface.text_fit(table, {}, origin_text, badge.x + badge.width - int(tokens.gap) - text_x), tokens.expected)
}

// draw_bookmark_band draws one bookmark for each page built in. The
// bookmark of the page shown is marked as open; a press loads its page.
draw_bookmark_band :: proc "contextless" (frame: ^interface.Frame, boxes: ^Window_Boxes, act: ^Act) {
	table := frame.table
	band := area_of(boxes.bookmark_band)
	interface.draw_rectangle(table, band.x, band.y, band.width, band.height, graphics.colors.card_bottom)
	interface.draw_rectangle(table, band.x, band.y + band.height - 1, band.width, 1, tokens.divider)
	shown, shown_found := Built_In_Page{}, false
	if current.scheme == .Modus && current.path_count == 0 && current.query_count == 0 {
		shown, shown_found = built_in_of(address_host(&current))
	}
	base := interface.identity("browser bookmark")
	for page in Built_In_Page {
		if bevelled_button(frame, area_of(boxes.bookmarks[page]), interface.identity_with(base, int(page)), BOOKMARK_LABELS[page], shown_found && shown == page).activated {
			act^ = {kind = .Open_Bookmark, bookmark = page}
		}
	}
}

// draw_status_band draws the title of the page and its counts, then the
// address of the link under the pointer, or what the last act did.
draw_status_band :: proc "contextless" (table: ^interface.Draw_Table, boxes: ^Window_Boxes, counts_text: string, hovered: Node_Target) {
	band := area_of(boxes.status_band)
	interface.draw_rectangle(table, band.x, band.y, band.width, band.height, tokens.surface_card)
	interface.draw_rectangle(table, band.x, band.y, band.width, 1, tokens.divider)
	title := area_of(boxes.status_title)
	interface.draw_text(table, title.x, title.y, interface.text_fit(table, {}, document_title(), title.width), tokens.text_strong)
	counts := area_of(boxes.status_counts)
	interface.draw_text(table, counts.x, counts.y, counts_text, tokens.text_dim)
	line := area_of(boxes.status_line)
	buffer: [ADDRESS_CAPACITY + 32]u8
	writer := Source_Writer{bytes = buffer[:]}
	switch hovered.kind {
	case .Link:
		href, _ := html_css_attribute(hovered.node, "href")
		put(&writer, "link: ")
		address_resolve(&writer, &current, href)
	case .Submit:
		action, _ := html_css_attribute(hovered.node, "action")
		put(&writer, "send the form to ")
		address_resolve(&writer, &current, action)
	case .None:
	}
	if writer.count > 0 {
		interface.draw_text(table, line.x, line.y, interface.text_fit(table, {}, writer_text(&writer), line.width), tokens.text)
	} else if status_count > 0 {
		interface.draw_text(table, line.x, line.y, interface.text_fit(table, {}, string(status_text[:status_count]), line.width), status_failed ? tokens.failed : tokens.text_dim)
	} else {
		interface.draw_text(table, line.x, line.y, interface.text_fit(table, {}, PAGE_KIND_WORDS[current_kind], line.width), tokens.text_dim)
	}
}

// The frames that one event can build: the frame of the event, and the
// frame that shows what its act loaded.
FRAME_ROUNDS :: 2

frame_build :: proc "contextless" (window: ^display.Window) {
	act := draw(window)
	for _ in 1 ..< FRAME_ROUNDS {
		if !act_run(act) {
			return
		}
		act = draw(window)
	}
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "browser")
	if !ok {
		system.stop(.Failed)
	}
	// The limits are constants of this process: a refusal is a fault of
	// this source, and a full ring a fault of the compositor; the line says
	// which, and the window keeps its size. The interface package takes the
	// event Resized and makes the surface of the new size.
	if problem, sent := display.resizable_set(&window, {least_width = LEAST_WIDTH, least_height = LEAST_HEIGHT, largest_width = LARGEST_WIDTH, largest_height = LARGEST_HEIGHT}); problem != .None {
		system.log_fact(.Info, Window_Stays_Fixed{cause = value_kinds.text_field(display.SIZE_LIMITS_PROBLEM_SENTENCES[problem], STAYS_FIXED_CAUSE_FIELD_BYTES)})
	} else if !sent {
		system.log_fact(.Info, Window_Stays_Fixed{cause = value_kinds.text_field("the command ring of the window is full", STAYS_FIXED_CAUSE_FIELD_BYTES)})
	}
	// The arenas of the document reserve the pages that the budget holds:
	// a page is as large as the budget pays, and no larger.
	own, _ := system.budget_read()
	if status := document_memory_create(system.arena_reservation_pages(own.pages)); status != .Succeeded {
		system.log_fact(.Warning, Document_Memory_Refused{status = u64(status)})
		system.stop(.Failed)
	}
	service, _ := system.service_open(ctx)
	settings_open(ctx) // settings.odin: its read waits for the first frame.
	page_load(home_text(), true)
	frame_build(&window)
	system.log_fact(.Info, Window_Ready{pages = u64(len(Built_In_Page))})
	kept_choices.kept_load(&browser_kept)
	for {
		wait: system.Wait
		display.wait_events(&wait, &window)
		system.service_wait(&wait, &service)
		ready := kept_choices.kept_wait(&browser_kept, &wait)
		system.wait_end(&wait, ready ? system.time() : system.WAIT_FOREVER)
		system.service_run(&service)
		settings_step()
		if interface.window_events(&window_memory.drawing, &window) {
			frame_build(&window)
		}
	}
}
