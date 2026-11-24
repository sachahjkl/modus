// The terminal: it shows the text that a process gives as records, and it
// gives the keys that the input types to that process (src/library/modus/terminal).
//
// The terminal starts no process. The root service starts a process and its
// terminal, and gives the same terminal ring and text region to the two.
// The terminal holds a surface, these two memory objects, and a handle that
// reads the state of the process: it has nothing of the start grant set of the process.
// The name of the process, the size of the text and what the window shows
// are values of its context.
//
// Keys: Page Up and Page Down move the view. Each other key goes to the
// process, and the view returns to the last lines.
//
// The pointer: the scroll bar at the right of the lines moves the view. A
// press on an arrow button moves it by one line, and again while the
// button is held; a press on the track by one page; the thumb follows the
// pointer while it is held (src/library/modus/interface/scroll_bar.odin).
//
// Two threads:
//   the reader   It reads the records of the terminal ring and keeps the
//                lines. It owns the lines: no lock exists.
//   the drawer   The first thread. At the rate of the screen it asks the
//                reader for a view: the cells of the rows that the window
//                shows. Then it draws the view. The reader makes the view
//                between two groups of records: some microseconds.
//                The surface has two pictures: the compositor never reads
//                a picture that the drawer changes. Before each wait it
//                tells the compositor whether a change waits for its
//                next picture (src/md/features/terminal_due_picture.md).
//
// The reader does not wait for a picture, so the process that writes does
// not wait for a picture. A line that the window does not show costs one
// copy of its bytes, and no pixel.
//
// The lines that the terminal keeps are in three areas of fixed size: the
// lines, the runs, the bytes. Each area starts again at its first place
// when it is full: the oldest lines go.
//
// **What it is for.** A process with the grant **Terminal** (the console,
// flood) writes typed records, not pixels and not escape sequences: a run
// of text has its style as a field. The process never draws, never waits
// for a picture, and never parses a key sequence. See the terms
// [terminal](term:terminal) and [terminal ring](term:terminal-ring).
//
// **Start**: nothing starts it by name. The root service starts one
// terminal with each process that has the grant **Terminal**, and refuses
// `start("terminal")`. Its row of `start_grant_sets` has the grant
// System_Part only: it receives only the handles above.
//
// **What a reader sees**: a window with the name of the process, its
// lines, a status bar that the process fills, the
// [action bar](term:action-bar) of Page Up and Page Down at the right of
// its last line, and on the log:
//
// - "terminal: ok, console writes in a ring of N records";
// - "terminal: the first key goes to console";
// - "terminal: a press on the arrow up of the scroll bar of console: the
//   view starts at line L of N", or "... the view follows the last lines";
// - "terminal: a drag of the thumb of the scroll bar of console: ...";
// - "terminal: console stopped: itself, done, after L lines and R
//   records", with the stop outcome in place of "done", or the text of
//   another stop cause in place of "itself, done";
// - "terminal: console draws its interface text in the interface font", or
//   "... in the font of the cells", at its first frame and at each change
//   of the setting `font`;
// - "terminal: console shows the character N in its cells, drawn by this
//   process from the font F of its fallback chain", once for each font F,
//   for the first or the last character of the view past the 192
//   characters of Spleen that a font of the chain of the cells has
//   (src/md/features/glyphs_on_demand.md); and "terminal: console shows
//   the character N in its cells as the replacement glyph: no font of its
//   fallback chain has it", once, for the first or the last such
//   character that no font has.
//
// The terminal of flood measures: it shows the rates of the process, and
// writes one line with the lines, the records and the kernel entries of one
// second.
//
// **What it proves**: a text output with no kernel entry for each line, and
// a writer that never waits for the screen. It does not prove fairness
// between two writers: one terminal serves one process.
package terminal_process

import "modus:contract/call_outcome"
import "internal:terminal/grid_resize"
import "internal:terminal/wide_cells"
import "modus:contract/enum_word"
import op "modus:contract/operation"
import "modus:contract/reference_screen"
import "modus:display"
import "modus:text_rendering"
import "modus:graphics"
import "modus:interface"
import "modus:key_path"
import "modus:kind_icons"
import box_layout "modus:layout"
import "modus:contract/value_kinds"
import "modus:contract/ring"
import "modus:contract/text_encoding"
import "modus:system"
import terminal "modus:terminal"
import "base:intrinsics"

// The lines that it keeps, and the initial surface of its window at start:
// their size follows the columns and the rows that its starter gives and the
// scale, so the tool cannot count them. The lines take 3840 pages, the
// initial surface up to 1800 pages (measured peak 5405 pages), and the glyph
// memory of both copies of the text rendering takes 2 x 354 pages
// (display.TEXT_MEMORY_PAGES) = 708 pages. 3840 + 1800 + 708 = 6348
// (checked under the type Line). A resize to the reference screen (two
// surfaces of 4050 pages at once) happens after ready and fits inside twice
// the floor. A window larger than the logical screen of a scale does not
// fit: display.surface_resize declines the resize with a line, and a rescale
// declines the scale. The cells of the largest grid are in the module: the
// tool counts them.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 6348, processes = 1, threads = 2}

COLUMNS_LIMIT :: terminal.COLUMNS_LIMIT
ROWS_LIMIT :: terminal.ROWS_LIMIT
CELL_WIDTH :: graphics.CELL_WIDTH
CELL_HEIGHT :: graphics.CELL_HEIGHT

MARGIN :: graphics.GAP
HEAD_HEIGHT :: 72
TEXT_X :: MARGIN
SCROLL_WIDTH :: interface.SCROLL_BAR_THICKNESS
SCROLL_GAP :: graphics.GAP // From the text to the scroll bar.
// The scroll bar of the completion list takes its last two cells and the
// column of its border.
LIST_SCROLL_CELLS :: 2
// The cells of a row of the completion list that hold its kind icon: an
// icon of 12 pixels, then a space before the name.
LIST_ICON_CELLS :: 3
#assert(LIST_SCROLL_CELLS * CELL_WIDTH + 1 == SCROLL_WIDTH)

// What the root service chose for this terminal, and the places that
// follow from it.
process_name: string
name_bytes: system.Name
columns, rows: int
measure: bool // The window shows the rates of the process, and the status on its own line.
text_y, text_width, text_height, status_y, hint_y, width, height, graph_x: int
scroll_area: interface.Area // The scroll bar of the lines: at the right edge of the window, from the head to the line over the status.
text_view_area: interface.Area // The rows of the lines: the wheel over them moves the view.
scroll_identity: interface.Element_Identity
terminal_layout_tree: box_layout.Box_Tree

// Minimum chrome bounds: 40x4 minimum terminal grid plus chrome stays positive
// and avoids overlap in both standard and measure modes.
#assert(40 * CELL_WIDTH >= HISTORY * GRAPH_BAR)
#assert(HEAD_HEIGHT - 6 >= GRAPH_HEIGHT + 10)
#assert(interface.ACTION_BAR_ROW_HEIGHT >= CELL_HEIGHT + 4)

Terminal_Places :: struct {
	head:       interface.Area,
	graph:      interface.Area,
	text_view:  interface.Area,
	scroll_bar: interface.Area,
	status_bar: interface.Area,
	bottom_bar: interface.Area,
}
terminal_places: Terminal_Places

@(private)
area_of :: proc "contextless" (tree: ^box_layout.Box_Tree, index: box_layout.Box_Index) -> interface.Area {
	box := box_layout.box_of(tree, index)
	if box == nil {
		return {}
	}
	return {int(box.rect.x), int(box.rect.y), int(box.rect.width), int(box.rect.height)}
}

// terminal_window_layout solves the terminal chrome regions using modus:layout.
// Called on startup and Resized (never in the per-frame draw loop) so text grid
// rendering stays zero-allocation and incurs zero per-frame layout overhead.
terminal_window_layout :: proc "contextless" (tree: ^box_layout.Box_Tree, surface_width, surface_height, cols, row_count: int, measure_mode: bool) -> (places: Terminal_Places, ok: bool) {
	if tree == nil || surface_width <= 0 || surface_height <= 0 || surface_width > box_layout.LENGTH_LIMIT || surface_height > box_layout.LENGTH_LIMIT || cols <= 0 || row_count <= 0 {
		return {}, false
	}
	if box_layout.tree_begin(tree, i32(surface_width), i32(surface_height), {child_axis = .Y}) != .Done {
		return {}, false
	}
	head_box, graph_box: box_layout.Box_Index
	if measure_mode {
		sh: box_layout.Box_Status
		head_box, sh = box_layout.box_open(tree, {size = {.X = box_layout.fill(), .Y = box_layout.px(HEAD_HEIGHT - 6)}, child_axis = .X, padding = {.X = TEXT_X, .Y = 9}})
		_, sp_left := box_layout.box_add(tree, {size = {.X = box_layout.fill(), .Y = box_layout.fill()}})
		sg: box_layout.Box_Status
		graph_box, sg = box_layout.box_add(tree, {size = {.X = box_layout.px(HISTORY * GRAPH_BAR), .Y = box_layout.px(GRAPH_HEIGHT)}})
		_, sp_right := box_layout.box_add(tree, {size = {.X = box_layout.px(SCROLL_GAP + SCROLL_WIDTH), .Y = box_layout.fill()}})
		sc_h := box_layout.box_close(tree)
		if sh != .Done || sp_left != .Done || sg != .Done || sp_right != .Done || sc_h != .Done {
			return {}, false
		}
	}

	// The scroll bar runs flush from the head (or top edge) to the separator
	// line over the status bar; the text column keeps its top and bottom inset.
	_, s_mid := box_layout.box_open(tree, {size = {.X = box_layout.fill(), .Y = box_layout.fill()}, child_axis = .X})
	_, s_col := box_layout.box_open(tree, {size = {.X = box_layout.fill(), .Y = box_layout.fill()}, child_axis = .Y})
	top_inset: i32 = measure_mode ? 6 : MARGIN
	_, s_top := box_layout.box_add(tree, {size = {.X = box_layout.px(0), .Y = box_layout.px(top_inset)}})
	_, s_row := box_layout.box_open(tree, {size = {.X = box_layout.fill(), .Y = box_layout.fill()}, child_axis = .X})
	_, s_lp := box_layout.box_add(tree, {size = {.X = box_layout.px(TEXT_X), .Y = box_layout.fill()}})
	text_box, s_tb := box_layout.box_add(tree, {size = {.X = box_layout.fill(), .Y = box_layout.fill()}})
	_, s_sg := box_layout.box_add(tree, {size = {.X = box_layout.px(SCROLL_GAP), .Y = box_layout.fill()}})
	sc_row := box_layout.box_close(tree)
	_, s_pad := box_layout.box_add(tree, {size = {.X = box_layout.px(0), .Y = box_layout.px(4)}})
	sc_col := box_layout.box_close(tree)
	sb_box, s_sb := box_layout.box_add(tree, {size = {.X = box_layout.px(SCROLL_WIDTH), .Y = box_layout.fill()}})
	sc_mid := box_layout.box_close(tree)
	if s_mid != .Done || s_col != .Done || s_top != .Done || s_row != .Done || s_lp != .Done || s_tb != .Done || s_sg != .Done || sc_row != .Done || s_pad != .Done || sc_col != .Done || s_sb != .Done || sc_mid != .Done {
		return {}, false
	}

	status_box: box_layout.Box_Index
	s_stat := box_layout.Box_Status.Done
	if measure_mode {
		status_box, s_stat = box_layout.box_add(tree, {size = {.X = box_layout.fill(), .Y = box_layout.px(24)}})
	}
	bottom_box, s_bot := box_layout.box_add(tree, {size = {.X = box_layout.fill(), .Y = box_layout.px(CELL_HEIGHT + 10)}})
	if s_stat != .Done || s_bot != .Done || box_layout.solve(tree) != .Done {
		return {}, false
	}
	if measure_mode {
		places.head = area_of(tree, head_box)
		places.graph = area_of(tree, graph_box)
		places.status_bar = area_of(tree, status_box)
	}
	text_slot := area_of(tree, text_box)
	places.text_view = {text_slot.x, text_slot.y, min(cols * CELL_WIDTH, text_slot.width), min(row_count * CELL_HEIGHT, text_slot.height)}
	places.scroll_bar = area_of(tree, sb_box)
	places.bottom_bar = area_of(tree, bottom_box)
	return places, true
}

chrome_size :: proc "contextless" () -> (chrome_width, chrome_height: int) {
	chrome_width = TEXT_X + SCROLL_GAP + SCROLL_WIDTH
	chrome_height = (measure ? HEAD_HEIGHT + 24 : MARGIN) + 8 + CELL_HEIGHT + 6
	return
}

layout_for_size :: proc "contextless" (surface_width, surface_height: int) {
	if places, ok := terminal_window_layout(&terminal_layout_tree, surface_width, surface_height, columns, rows, measure); ok {
		terminal_places = places
		text_y = places.text_view.y
		text_width = columns * CELL_WIDTH
		text_height = rows * CELL_HEIGHT
		width = surface_width
		height = surface_height
		hint_y = places.bottom_bar.y + 4
		status_y = measure ? places.status_bar.y + 4 : hint_y
		graph_x = measure ? places.graph.x : TEXT_X + text_width - HISTORY * GRAPH_BAR
		scroll_area = places.scroll_bar
		text_view_area = places.text_view
	} else {
		text_y = measure ? HEAD_HEIGHT : MARGIN
		text_width = columns * CELL_WIDTH
		text_height = rows * CELL_HEIGHT
		width = surface_width
		height = surface_height
		hint_y = height - CELL_HEIGHT - 6
		status_y = measure ? hint_y - 24 : hint_y
		graph_x = TEXT_X + text_width - HISTORY * GRAPH_BAR
		scroll_top := measure ? HEAD_HEIGHT - 6 : 0
		scroll_area = {width - SCROLL_WIDTH, scroll_top, SCROLL_WIDTH, status_y - 4 - scroll_top}
		text_view_area = {TEXT_X, text_y, text_width, text_height}
	}
	scroll_identity = interface.identity("the scroll bar of the lines")
	list_scroll_identity = interface.identity("the scroll bar of the completion list")
}

layout :: proc "contextless" () {
	chrome_w, chrome_h := chrome_size()
	layout_for_size(chrome_w + columns * CELL_WIDTH, chrome_h + rows * CELL_HEIGHT)
}

FRAME_TIME :: 16 // Milliseconds.
SAMPLE_TIME :: 250 // Milliseconds of one measure of the rates.
HISTORY :: 48 // The measures that the graph shows.
GRAPH_BAR :: 4
GRAPH_HEIGHT :: 48

// The completion list: a card over the text, its chosen row in the chosen
// blue of the rules with its text in white, the matched characters in the
// accent, a border of one pixel in the color of the kernel as the menus of
// the bar.
LIST_WIDTH_LEAST :: 16 // Cells: a list of short names stays wide enough to read.

// The colors that are the terminal's own: the tone of each run of text, the
// graph of the head, the states of the process and the cursor. Each has a
// value in each appearance (src/md/features/appearance.md): a light value
// is the dark one at the shade that keeps 4.5 to 1 on the light surfaces.
Terminal_Colors :: struct {
	tones:     [terminal.Tone]graphics.Color, // The color of each tone.
	graph:     graphics.Color, // A bar of the graph of the head.
	graph_dim: graphics.Color, // The empty part of a bar of the graph.
	stopped:   graphics.Color, // "the process does not run".
	held:      graphics.Color, // The view is held, and the rate of kernel entries.
	cursor:    graphics.Color, // The cell of the cursor, in reverse.
}

@(rodata)
terminal_colors := [graphics.Appearance]Terminal_Colors {
	.Dark = {
		tones = {.Default = 0xC8D0D8, .Dim = 0x6C7986, .Strong = 0xFFFFFF, .Good = 0x58D878, .Warning = 0xF0C050, .Bad = 0xF06060, .Accent = 0x58B8F0, .Number = 0x8C98A6},
		graph = 0x58D878,
		graph_dim = 0x1C3A28,
		stopped = 0xF07060,
		held = 0xF0C050,
		cursor = 0x7FC8FF,
	},
	.Light = {
		// The text, the dim text and the strong text of the light tokens;
		// the green and the red of the light tokens; the amber and the
		// accent at 50 and 55 %, the gray of a number at 55 %.
		tones = {.Default = 0x0B1018, .Dim = 0x4A525B, .Strong = 0x000000, .Good = 0x327C45, .Warning = 0x775F27, .Bad = 0xBA4A4A, .Accent = 0x306583, .Number = 0x4C535B},
		graph = 0x327C45,
		graph_dim = 0xD5E2DB, // The light background with 40 % of the green.
		stopped = 0xA74E43, // The dark value at 70 %.
		held = 0x775F27,
		cursor = 0x3F637F, // The dark value at 50 %: the light background on it has 5.8 to 1.
	},
}

// own_colors gives the colors of the terminal in the appearance in force.
own_colors :: proc "contextless" () -> ^Terminal_Colors {
	return &terminal_colors[graphics.appearance]
}

// ---- The lines that the terminal keeps. Only the reader uses them.

LINE_CAPACITY :: 1 << 16
RUN_CAPACITY :: 1 << 18
BYTE_CAPACITY :: 1 << 23
LINE_RUNS :: 1024 // A line of more runs continues on a new line.

Run :: struct {
	start:  u64, // The count of bytes that the terminal kept before this run.
	style:  terminal.Style,
	length: u32,
}

Line :: struct {
	first_run: u64, // The count of runs that the terminal kept before this line.
	run_count: u32,
	length:    u32, // Bytes of UTF-8.
}

// The working memory of the floor holds the lines, the initial window
// surface and both glyph caches; twice the working memory holds the lines,
// two full surfaces of the reference screen during a resize and both glyph
// caches.
LINES_PAGES :: (LINE_CAPACITY * size_of(Line) + RUN_CAPACITY * size_of(Run) + BYTE_CAPACITY + system.PAGE_SIZE - 1) / system.PAGE_SIZE
INITIAL_SURFACE_PAGES :: 1800
SCREEN_SURFACE_PAGES :: (display.PICTURE_COUNT * reference_screen.WIDTH * reference_screen.HEIGHT * size_of(graphics.Color) + system.PAGE_SIZE - 1) / system.PAGE_SIZE
#assert(LINES_PAGES + INITIAL_SURFACE_PAGES + 2 * display.TEXT_MEMORY_PAGES <= MODULE_BUDGET.working_memory_pages)
#assert(2 * MODULE_BUDGET.working_memory_pages >= LINES_PAGES + 2 * SCREEN_SURFACE_PAGES + 2 * display.TEXT_MEMORY_PAGES)

lines: [^]Line
runs: [^]Run
bytes: []u8
lines_written: u64 // The lines that ended. lines[lines_written] is the line that the process writes now.
runs_written: u64
bytes_written: u64
oldest: u64 // The oldest line that the terminal still has.
records_read: u64
source: ring.Ring // The terminal ring.
source_text: []u8 // The text region, read-only.
source_read: u64 // The bytes that the reader took from the text region.

Status_Line :: struct {
	text:   [COLUMNS_LIMIT]u8,
	length: int,
	value:  u64,
	total:  u64,
	style:  terminal.Style,
}
status_line: Status_Line

// The line that the process changes (terminal.Kind.Edit).
Edit_Line :: struct {
	text:       [terminal.EDIT_TEXT_LIMIT]u8,
	length:     int,
	cursor:     int,
	has_cursor: bool,
	style:      terminal.Style,
	code:       terminal.Edit_Code_Runs, // Checked against the text. None: the line is plain.
}
edit_line: Edit_Line
// The parts of the next edit line, which wait for its Edit record.
edit_staging: terminal.Edit_Staging
// The characters of the edit line as the view lays them out: in the memory
// of the reader, as an edit line has up to EDIT_TEXT_LIMIT bytes.
edit_characters: [terminal.EDIT_TEXT_LIMIT]rune
edit_starts: [terminal.EDIT_TEXT_LIMIT]u16 // The byte where each character starts.
edit_places: [terminal.EDIT_TEXT_LIMIT][2]u16 // The row and the column of each character in the flow.
#assert(terminal.EDIT_TEXT_LIMIT <= int(max(u16)))
// The serial of the newest key that an Edit record named (terminal.edit):
// the reader keeps it, the view gives it to the drawer.
edit_key_serial: u64
// The newest key serial that the drawer forwarded to the process: the
// reader refuses an Edit serial past it. The drawer stores it before the
// send, so the reader sees it before any Edit that answers the key.
key_serial_forwarded: u64
// The Edit records whose serial was refused (the reader only).
edit_serials_refused: u64
// The runs of code that the next Edit record takes (terminal.Kind.Code_Runs).
edit_runs_pending: terminal.Edit_Code_Runs
// The lists of runs of code that were refused for the edit line: each one
// left its line plain. The list counts its own.
edit_runs_refused: u64
runs_refusal_logged: bool
// The log says one time that the process sent a list row that names no icon.
rows_refusal_logged: bool
// The records whose kind names no record, or None: the log says it one time.
records_refused: u64
records_refusal_logged: bool

// The line under the edit line (terminal.Kind.Hint): a long form, and a
// short form for a terminal too narrow for the long one. The text holds
// the long form, then the short form.
Hint_Line :: struct {
	text:       [terminal.RUN_LIMIT]u8,
	length:     int,
	long_count: int,
	marked:     [terminal.Hint_Form][2]int, // The first byte and the count of bytes that each form marks.
	style:      terminal.Style,
}
hint_line: Hint_Line

// The completion list (terminal.Kind.List_Row, terminal.Kind.List).
list_keeping: terminal.List_Keeping

// ---- What the drawer asks, and the view that the reader gives.

Request :: struct {
	follow: bool, // The view shows the last lines.
	top:    u64, // If not follow: the line of the first row.
	stopped: bool, // The process stopped: the reader writes a line that says it.
	cause:   op.Stop_Cause,
	outcome: op.Stop_Outcome,
}

Cell :: interface.Text_Grid_Cell

View :: struct {
	cells:   [ROWS_LIMIT][COLUMNS_LIMIT]Cell,
	top:     u64,
	count:   u64, // The lines since the start.
	oldest:  u64,
	gone:    bool, // The terminal does not have the lines of the cells now.
	records: u64,
	bytes:   u64,
	status:  Status_Line,
	// The cells of the completion list, for its border: list_columns 0 is
	// no list.
	list_left, list_top, list_columns, list_rows: int,
	// The scroll bar of the completion list: the names of the whole list,
	// and the first one that the rows show. list_scroll false: each name
	// is shown, and the list has no scroll bar.
	list_scroll: bool,
	list_total, list_first: int,
	// The kind icon of each row of the list, and its color. list_icon_cells
	// 0: no row has an icon, and the list keeps no room for one.
	list_icon_cells: int,
	list_icons:      [terminal.LIST_ROWS]^kind_icons.Cells,
	list_icon_colors: [terminal.LIST_ROWS]graphics.Color,
	// The rows of the view that show lines of the text: the edit line and
	// the row under it are not lines of the text. After a clear, the view
	// can show none.
	text_rows: u64,
	// The first and the last cells of the lines of the text past the glyph
	// cache; 0: none. The drawer says once for each font of the fallback
	// chain that it draws one, and once that one has no font.
	fallback_first, fallback_last: rune,
	key_serial: u64, // The newest key that the edit line of the view shows (edit_key_serial).
}

request: Request
view: View
grid: grid_resize.Resizable_Grid
request_word: u32 // 1: the drawer asks for a view. The reader sets 0 when the view is ready.
reader_idle: u32 // The reader waits, or will wait.
drawer_waits: u32
// The reader adds 1 after each group of records. The drawer draws a new
// picture only after a change: a terminal that receives nothing draws nothing.
activity: u32
drawer_idle: u32
drawer_wakes: u32 // The wakes of the drawer that the reader made after a change.

// The state of the check of a lost wake: what the drawer saw at its last
// look at the reader.
reader_read_seen: u32 // The records that the reader had read.
reader_stuck_seen: bool // The reader was in a wait with records in its ring.
lost_wake_logged: [2]bool // A line of the log for each side, one time.

// lost_wake_check looks, after each wait of the drawer with nothing to draw,
// for a wake that did not come. Each side wakes the other one at each
// change, so neither case can happen; a line of the log says which one did:
//
// - the drawer: its wait ended at its deadline, the reader changed the view
//   during it, and the reader made no wake;
// - the reader: at two looks in a row that each end a whole wait of the
//   drawer to its deadline, the reader is in its wait, its ring holds
//   records, and it read none between the two.
//
// It changes no state: the drawer draws the change at this turn anyway.
lost_wake_check :: proc "contextless" (ended_by_time: bool, wakes_before: u32) {
	if !ended_by_time {
		reader_stuck_seen = false
		return
	}
	if intrinsics.atomic_load(&drawer_wakes) == wakes_before && intrinsics.atomic_load(&activity) != activity_at_wait && !lost_wake_logged[0] {
		lost_wake_logged[0] = true
		system.log_fact(.Info, Drawer_Wake_Lost{shown_process = shown_process_field()})
	}
	read := intrinsics.atomic_load(&source.commands.counters.read)
	stuck := intrinsics.atomic_load(&reader_idle) != 0 && ring.count(&source.commands) != 0
	if stuck && reader_stuck_seen && read == reader_read_seen && !lost_wake_logged[1] {
		lost_wake_logged[1] = true
		system.log_fact(.Info, Reader_Stuck{records = u64(ring.count(&source.commands)), shown_process = shown_process_field()})
	}
	reader_read_seen, reader_stuck_seen = read, stuck
}

activity_at_wait: u32 // The value of activity that the drawer waited on.

line_valid :: proc "contextless" (index: u64) -> bool {
	line := lines[index & (LINE_CAPACITY - 1)]
	if line.run_count == 0 {
		return true
	}
	return runs_written - line.first_run <= RUN_CAPACITY && bytes_written - runs[line.first_run & (RUN_CAPACITY - 1)].start <= BYTE_CAPACITY
}

line_end :: proc "contextless" () {
	lines_written += 1
	lines[lines_written & (LINE_CAPACITY - 1)] = {first_run = runs_written}
}

// take gives the next count bytes of the text region as two parts: the
// text region starts again at its first byte after its last.
take :: proc "contextless" (count: u32) -> (first, second: []u8) {
	count := int(min(count, terminal.RUN_LIMIT))
	place := int(source_read % terminal.TEXT_SIZE)
	size := min(count, terminal.TEXT_SIZE - place)
	source_read += u64(count)
	return source_text[place:][:size], source_text[:count - size]
}

// put copies bytes to the bytes that the terminal keeps. The process can
// change the text region at any time: the terminal uses only this copy.
put :: proc "contextless" (text: []u8) {
	place := int(bytes_written & (BYTE_CAPACITY - 1))
	size := min(len(text), BYTE_CAPACITY - place)
	copy(bytes[place:], text[:size])
	copy(bytes, text[size:])
	bytes_written += u64(len(text))
}

// keep adds a run to the line that the process writes now. The text of the
// run is two parts.
keep :: proc "contextless" (first, second: []u8, style: terminal.Style) {
	line := &lines[lines_written & (LINE_CAPACITY - 1)]
	length := u32(len(first) + len(second))
	if length != 0 {
		if line.run_count == LINE_RUNS {
			line_end()
			line = &lines[lines_written & (LINE_CAPACITY - 1)]
		}
		runs[runs_written & (RUN_CAPACITY - 1)] = {start = bytes_written, style = style, length = length}
		runs_written += 1
		put(first)
		put(second)
		line.run_count += 1
		line.length += length
	}
	if .End_Line in style.flags {
		line_end()
	}
}

apply :: proc "contextless" (record: ring.Record) {
	records_read += 1
	// The process writes the word: a word that names no record, and None,
	// are refused and counted, and the log says it once.
	kind, kind_ok := terminal.kind_of_ring_word(record.kind)
	if !kind_ok {
		// The drawer reads the count when the process stops.
		intrinsics.atomic_add(&records_refused, 1)
		if !records_refusal_logged {
			records_refusal_logged = true
			system.log_fact(.Info, Record_Kind_Refused{kind_word = u64(record.kind), shown_process = shown_process_field()})
		}
		return
	}
	switch kind {
	case .None:
		// Refused above.
	case .Text:
		first, second := take(record.tag)
		keep(first, second, transmute(terminal.Style)record.values[0])
	case .Status:
		first, second := take(record.tag)
		status_line = {value = record.values[1], total = record.values[2], style = transmute(terminal.Style)record.values[0]}
		status_line.length = copy(status_line.text[:], first)
		status_line.length += copy(status_line.text[status_line.length:], second)
		// A status longer than its field keeps its whole characters.
		if status_line.length < len(first) + len(second) {
			status_line.length = text_encoding.complete_characters(status_line.text[:status_line.length])
		}
	case .Clear:
		forget()
	case .Edit:
		first, second := take(record.tag)
		// The newest key whose character the process put in its line: the
		// next picture shows it. A serial past the keys that the terminal
		// forwarded is refused, counted, and the log says it once.
		if terminal.edit_key_serial_take(&edit_key_serial, record.values[2], intrinsics.atomic_load(&key_serial_forwarded)) {
			edit_serials_refused += 1
			if edit_serials_refused == 1 {
				system.log_fact(.Info, Key_Serial_Refused{shown_process = shown_process_field()})
			}
		}
		edit_line = {style = transmute(terminal.Style)record.values[0]}
		edit_line.length = terminal.edit_staging_end(&edit_staging, first, second, &edit_line.text)
		if record.values[1] != terminal.NO_CURSOR {
			edit_line.has_cursor = true
			edit_line.cursor = int(min(record.values[1], u64(edit_line.length)))
		}
		edit_line.code = edit_runs_pending
		edit_runs_pending = {}
		if edit_line.code.count != 0 && !terminal.code_runs_check(&edit_line.code, edit_line.length) {
			edit_runs_refused += 1
		}
	case .Hint:
		first, second := take(record.tag)
		hint_line = {style = transmute(terminal.Style)record.values[0]}
		hint_line.length = copy(hint_line.text[:], first)
		hint_line.length += copy(hint_line.text[hint_line.length:], second)
		hint_line.long_count = int(min(record.values[3], u64(hint_line.length)))
		short_count := hint_line.length - hint_line.long_count
		long_start := int(min(record.values[1], u64(hint_line.long_count)))
		short_start := int(min(record.values[4], u64(short_count)))
		hint_line.marked[.Long] = {long_start, int(min(record.values[2], u64(hint_line.long_count - long_start)))}
		hint_line.marked[.Short] = {short_start, int(min(record.values[5], u64(short_count - short_start)))}
	case .List_Row:
		first, second := take(record.tag)
		terminal.list_keep_row(&list_keeping, record.values, first, second)
	case .List:
		terminal.list_keep_show(&list_keeping, record.values)
	case .Edit_Part:
		first, second := take(record.tag)
		terminal.edit_part_keep(&edit_staging, first, second)
	case .Code_Runs:
		first, second := take(record.tag)
		target, target_ok := enum_word.member_of_word(terminal.Kind, record.values[0])
		if !target_ok {
			edit_runs_refused += 1 // The target names no record.
			break
		}
		switch target {
		case .Edit:
			if !terminal.edit_code_runs_add(&edit_runs_pending, first, second) {
				edit_runs_refused += 1
			}
		case .List_Row:
			terminal.list_keep_code_runs(&list_keeping, record.values, first, second)
		case .None, .Text, .Status, .Clear, .Hint, .List, .Code_Runs, .Edit_Part:
			edit_runs_refused += 1 // No other record takes runs.
		}
	}
	// A process that sends runs that do not fit its rows: its rows stay
	// plain, and the log says it once.
	if !runs_refusal_logged && edit_runs_refused + list_keeping.runs_refused != 0 {
		runs_refusal_logged = true
		system.log_fact(.Info, Code_Runs_Refused{shown_process = shown_process_field()})
	}
	if !rows_refusal_logged && list_keeping.rows_refused != 0 {
		rows_refusal_logged = true
		system.log_fact(.Info, List_Row_Refused{shown_process = shown_process_field()})
	}
}

// style_color gives the color of a run of text: its own color with the
// flag Color; if not, the color of its value kind when it has one; if not,
// the color of its code kind when the kind has one; if not, the color of
// its tone. Each color but its own is the one of the appearance in force,
// read at each draw. The bytes of the style come from another process: a
// tone that names no tone draws in the color of plain text, and a value
// kind or a code kind that names no kind gives no color of its own.
style_color :: proc "contextless" (style: terminal.Style) -> graphics.Color {
	if .Color in style.flags {
		return style.color & 0xFFFFFF
	}
	colors := own_colors()
	plain := colors.tones[.Default]
	if tone, tone_ok := terminal.tone_of_byte(style.tone); tone_ok {
		plain = colors.tones[tone]
	}
	if value_kind, value_kind_ok := value_kinds.value_kind_of(style.value_kind); value_kind_ok && value_kind != .None {
		return graphics.value_kind_color(value_kind, graphics.appearance, plain)
	}
	code_kind, code_kind_ok := terminal.code_kind_of(style.code)
	if !code_kind_ok {
		return plain
	}
	return terminal.code_kind_color(code_kind, plain)
}

// The text of each record is UTF-8 from another process: a cell holds one
// character, decoded once here, and an invalid sequence is one cell of the replacement
// character (src/library/modus/contract/text_encoding). A count of bytes of a
// record (a cursor, a mark, a match, a run of code) names the character
// that starts at that byte.

// character_at gives the character that a cell shows for the bytes of a
// record at place, and its bytes.
character_at :: #force_inline proc "contextless" (text: []u8, place: int) -> (character: rune, length: int) {
	character, length, _ = text_encoding.character_decode(text, place)
	return
}

// cells_of gives the cells that a text of a record takes: two for a wide
// character, none for a combining mark, one for each other character and
// each invalid sequence (text_rendering.cell_width_of).
cells_of :: #force_inline proc "contextless" (text: []u8) -> int {
	return text_rendering.cell_count(text)
}

// A row of the view as the terminal lays it out: each wide character a
// lead and a trail (internal:terminal/wide_cells), each cell with its
// style. cells_from_wide turns it into the cells that the drawer draws:
// the lead holds the character, the trail is a blank cell of the same
// style, so the cells keep their format of 16 bytes.
Wide_Row :: [COLUMNS_LIMIT]wide_cells.Cell(Cell)

cells_from_wide :: proc "contextless" (row: ^[COLUMNS_LIMIT]Cell, wide: []wide_cells.Cell(Cell)) {
	for cell, column in wide {
		switch cell.part {
		case .Empty:
			row[column] = {}
		case .Single, .Wide_Lead:
			row[column] = cell.payload
			row[column].character = cell.character
		case .Wide_Trail:
			row[column] = cell.payload
			row[column].character = ' '
		}
	}
}

// edit_column_of gives the column of the character of the edit line that
// starts at a byte, in the flow of the edit line over rows of columns
// cells: a wide character that finds one column left starts the next row.
edit_column_of :: proc "contextless" (byte_place: int) -> int {
	flow := wide_cells.Flow{columns = columns}
	text := edit_line.text[:edit_line.length]
	for place := 0; place < len(text) && place < byte_place; {
		character, length := character_at(text, place)
		wide_cells.flow_place(&flow, character)
		place += length
	}
	_, column := wide_cells.flow_cursor(flow)
	return column
}

// list_fill writes the cells of the completion list over the rows of the
// view, at the edit line: under it when the rows below hold the list, if
// not above it, and if neither holds it, on the larger side with fewer
// rows. edit_top is the row of the view of the first row of the edit line,
// below the first row under the edit line and its hint.
list_fill :: proc "contextless" (edit_top, below: int) {
	view.list_columns = 0
	if list_keeping.shown.row_count == 0 || edit_top < 0 || edit_top >= rows {
		return
	}
	shown_rows := list_keeping.shown.row_count
	space_below := max(rows - below, 0)
	space_above := edit_top
	top: int
	switch {
	case space_below >= shown_rows:
		top = below
	case space_above >= shown_rows:
		top = edit_top - shown_rows
	case space_below >= space_above:
		top, shown_rows = below, space_below
	case:
		top, shown_rows = 0, space_above
	}
	if shown_rows <= 0 {
		return
	}
	// The rows shown keep the chosen row in view.
	offset := list_keeping.shown.chosen >= shown_rows ? list_keeping.shown.chosen - shown_rows + 1 : 0
	scroll := list_keeping.shown.total > list_keeping.shown.row_count || shown_rows < list_keeping.shown.row_count ? LIST_SCROLL_CELLS : 0
	longest := 0
	// The room of the kind icons, before the names: one row with an icon
	// gives it to each row, so the names stay in one column.
	icon_cells := 0
	for &row in list_keeping.shown.rows[offset:][:shown_rows] {
		name_cells := cells_of(row.text[:row.name_length])
		about_cells := cells_of(row.text[row.name_length:row.length])
		longest = max(longest, name_cells + (about_cells > 0 ? 2 + about_cells : 0))
		if row.icon != .None {
			icon_cells = LIST_ICON_CELLS
		}
	}
	list_width := min(max(longest + 2 + icon_cells + scroll, LIST_WIDTH_LEAST), columns)
	// A terminal too narrow for the icons and one character of a name
	// shows the names alone.
	if list_width - 2 - scroll - icon_cells < 1 {
		icon_cells = 0
	}
	// The anchor is a byte of the edit line: the list starts at the cell of
	// its character.
	anchor := edit_column_of(min(list_keeping.shown.anchor, edit_line.length))
	left := min(anchor, columns - list_width)
	inner := list_width - 2 - scroll - icon_cells
	view.list_icon_cells = icon_cells
	view.list_icons = {}
	// The scroll bar: the drawer draws it over the last cells of the rows,
	// at the place of the rows shown in all the names. The count of the
	// names comes from the process: it is at least the rows shown.
	shown_first := max(list_keeping.shown.first, 0) + offset
	view.list_scroll = scroll != 0
	view.list_first = shown_first
	view.list_total = max(list_keeping.shown.total, shown_first + shown_rows)
	for index in 0 ..< shown_rows {
		row := &list_keeping.shown.rows[offset + index]
		chosen := offset + index == list_keeping.shown.chosen
		background: graphics.Color = chosen ? graphics.colors.chosen : graphics.colors.card_top
		name_color: graphics.Color = chosen ? graphics.COLOR_WHITE : graphics.colors.text
		about_color: graphics.Color = chosen ? graphics.COLOR_WHITE : own_colors().tones[.Dim]
		cells := view.cells[top + index][left:][:list_width]
		for &cell in cells {
			cell = {character = ' ', filled = true, color = name_color, background = background}
		}
		// The kind icon of the row: white on the chosen row, as its text.
		if icon_cells != 0 {
			icon, color := list_icon_form(row.icon)
			view.list_icons[index], view.list_icon_colors[index] = icon, chosen ? graphics.COLOR_WHITE : color
		}
		// A row with runs of code: each part in the color of its kind, and
		// the part with no kind in the color of the name. On the chosen row
		// each part is white: no color of a kind keeps its contrast on the
		// blue (docs/CONSOLE.md, section 7). A matched character is in the
		// accent over its kind: the match is the typed text. No tone
		// but white keeps its contrast on the chosen blue, so there a matched
		// character is the reverse: the chosen blue on a white cell.
		colored := row.code.count != 0
		if colored && !chosen {
			about_color = name_color
		}
		code_cursor := 0 // The run of code of the bytes of the row, in order.
		// One cell for each character of the name; a match and a run of
		// code name the byte where the character starts.
		name_text := row.text[:row.name_length]
		name_shown, name_place := 0, 0
		for name_place < len(name_text) && name_shown < inner {
			character, length := character_at(name_text, name_place)
			matched := name_place < 128 && row.matched[name_place / 64] & (1 << u64(name_place % 64)) != 0
			kind := terminal.code_runs_kind_at(&row.code, name_place, &code_cursor)
			name_cell := Cell{character = character, filled = true, color = chosen ? name_color : terminal.code_kind_color(kind, name_color), background = background}
			switch {
			case matched && chosen:
				name_cell.color, name_cell.background = graphics.colors.chosen, graphics.COLOR_WHITE
			case matched:
				name_cell.color = own_colors().tones[.Accent]
			}
			cells[1 + icon_cells + name_shown] = name_cell
			name_shown += 1
			name_place += length
		}
		// What the name is, at the right, cut at its end when the room is short.
		about_text := row.text[row.name_length:row.length]
		about_room := inner - name_shown - 2
		about_shown := about_room > 0 ? min(cells_of(about_text), about_room) : 0
		about_left := 1 + icon_cells + inner - about_shown
		about_place := 0
		for cell_index in 0 ..< about_shown {
			character, length := character_at(about_text, about_place)
			kind := terminal.code_runs_kind_at(&row.code, row.name_length + about_place, &code_cursor)
			color := chosen ? about_color : terminal.code_kind_color(kind, about_color)
			cells[about_left + cell_index] = {character = character, filled = true, color = color, background = background}
			about_place += length
		}
	}
	view.list_left, view.list_top, view.list_columns, view.list_rows = left, top, list_width, shown_rows
}

// list_icon_form gives the form and the color of the kind icon of a row of
// the completion list, the same as a row of the palette has for the same
// kind (src/library/internal/compositor/palette, entry_icon). nil: no icon.
//
// - A service, a module and a process take the form of a module.
// - An export is a part of a module: its own form, in the color of a module.
// - A command that makes a record gives a type; a variable holds a value;
//   a line of the history has the form of a time.
list_icon_form :: proc "contextless" (icon: terminal.List_Icon) -> (form: ^kind_icons.Cells, color: graphics.Color) {
	module_color := graphics.value_kind_color(value_kinds.Value_Kind.Module, graphics.appearance)
	switch icon {
	case .None:
	case .Command:
		return kind_icons.cells_of_value_kind(.Command), graphics.value_kind_color(value_kinds.Value_Kind.Command, graphics.appearance)
	case .Export:
		return kind_icons.cells_of_desktop_kind(.Export), module_color
	case .Record:
		return kind_icons.cells_of_value_kind(.Type), graphics.value_kind_color(value_kinds.Value_Kind.Type, graphics.appearance)
	case .Service, .Module, .Process:
		return kind_icons.cells_of_value_kind(.Module), module_color
	case .Variable:
		return kind_icons.cells_of_value_kind(.Value), graphics.value_kind_color(value_kinds.Value_Kind.Value, graphics.appearance)
	case .History_Line:
		return kind_icons.cells_of_value_kind(.Time), graphics.value_kind_color(value_kinds.Value_Kind.Time, graphics.appearance)
	}
	return nil, graphics.colors.text
}

forget :: proc "contextless" () {
	lines_written += 1
	lines[lines_written & (LINE_CAPACITY - 1)] = {first_run = runs_written}
	oldest = lines_written
	status_line = {}
}

// note adds a line of the terminal itself.
note :: proc "contextless" (parts: ..system.Part) {
	buffer: [COLUMNS_LIMIT]u8
	if lines[lines_written & (LINE_CAPACITY - 1)].run_count != 0 {
		line_end()
	}
	keep(transmute([]u8)system.format(buffer[:], ..parts), nil, {tone = u8(terminal.Tone.Warning), flags = {.End_Line}})
}

// view_make fills the view for the request.
view_make :: proc "contextless" () {
	if request.stopped {
		stop_buffer: [64]u8
		stop_text := system.Writer{buffer = stop_buffer[:]}
		system.stop_write(&stop_text, request.cause, request.outcome)
		note("-- ", process_name, " stopped: ", system.written(&stop_text), ", after ", lines_written, " lines --")
		status_line.total = 0
		edit_line = {}
		edit_runs_pending = {}
		hint_line = {}
		terminal.list_keep_forget(&list_keeping)
	}
	view.key_serial = edit_key_serial
	count := lines_written
	if lines[lines_written & (LINE_CAPACITY - 1)].run_count != 0 {
		count += 1
	}
	// The line that the process changes takes rows after the last line: its
	// characters, decoded once here, flow over the rows, two cells for a
	// wide character, which starts the next row when one column is left;
	// and one cell for the cursor.
	edit_count := 0
	edit_flow := wide_cells.Flow{columns = columns}
	edit_cursor_row, edit_cursor_column := -1, 0
	for edit_place := 0; edit_place < edit_line.length; edit_count += 1 {
		character, length := character_at(edit_line.text[:edit_line.length], edit_place)
		place_row, place_column, _ := wide_cells.flow_place(&edit_flow, character)
		if edit_line.has_cursor && edit_cursor_row < 0 && edit_place >= edit_line.cursor {
			edit_cursor_row, edit_cursor_column = place_row, place_column
		}
		edit_characters[edit_count], edit_starts[edit_count] = character, u16(edit_place)
		edit_places[edit_count] = {u16(place_row), u16(place_column)}
		edit_place += length
	}
	if edit_line.has_cursor && (edit_cursor_row < 0 || edit_cursor_column >= columns) {
		// The cursor after the last character, or after a mark of no width
		// at the end of a full row.
		if edit_cursor_row < 0 {
			edit_cursor_row, edit_cursor_column = wide_cells.flow_cursor(edit_flow)
		} else {
			edit_cursor_row, edit_cursor_column = edit_cursor_row + 1, 0
		}
	}
	edit_used_rows := 0
	if edit_count > 0 {
		edit_used_rows = edit_flow.row + 1
	}
	if edit_line.has_cursor {
		edit_used_rows = max(edit_used_rows, edit_cursor_row + 1)
	}
	// A line of more rows than the view leaves the free row under it shows
	// its rows around the cursor: the cursor row is the last one shown.
	edit_rows := u64(min(edit_used_rows, max(rows - 1, 1)))
	edit_first_row := 0
	if edit_used_rows > int(edit_rows) && edit_line.has_cursor {
		edit_first_row = clamp(edit_cursor_row - int(edit_rows) + 1, 0, edit_used_rows - int(edit_rows))
	}
	// One row under the edit line stays free at all times, with or without
	// a hint line: the hint is drawn over it, as the list is drawn over the
	// text, so the text does not move when a hint comes or goes.
	free_rows: u64 = edit_rows > 0 ? 1 : 0
	total := count + edit_rows + free_rows
	top := request.top
	if request.follow || top + u64(rows) > total {
		top = total > u64(rows) ? total - u64(rows) : 0
	}
	view.count, view.oldest, view.records, view.bytes, view.status = count, oldest, records_read, bytes_written, status_line
	// The held view shows lines that the terminal does not have now: the
	// view keeps its cells.
	view.gone = !request.follow && top == view.top && top < oldest
	if view.gone {
		view.list_columns = 0
		view.text_rows = 0
		return
	}
	view.text_rows = 0
	view.fallback_first, view.fallback_last = 0, 0
	top = max(top, oldest)
	view.top = top
	edit_color := style_color(edit_line.style)
	// One row of lead and trail cells for each row of the view, in turn:
	// one array on the stack of the reader, not one for each kind of row.
	wide_row: Wide_Row
	for &row, index in view.cells[:rows] {
		wide_row = {}
		row = {}
		number := top + u64(index)
		if number >= count && number - count < edit_rows {
			edit_row := int(number - count) + edit_first_row
			code_cursor := 0 // The run of code of the bytes of this row, in order.
			for character_index in 0 ..< edit_count {
				if int(edit_places[character_index][0]) != edit_row {
					continue
				}
				kind := terminal.code_runs_kind_at(&edit_line.code, int(edit_starts[character_index]), &code_cursor)
				wide_cells.row_put(wide_row[:columns], int(edit_places[character_index][1]), edit_characters[character_index], Cell{color = terminal.code_kind_color(kind, edit_color)})
			}
			cells_from_wide(&row, wide_row[:columns])
			if edit_line.has_cursor && edit_cursor_row == edit_row && edit_cursor_column < columns {
				row[edit_cursor_column] = {character = max(row[edit_cursor_column].character, ' '), reverse = true, color = own_colors().cursor}
			}
			continue
		}
		if free_rows == 1 && number == count + edit_rows {
			hint_fill(&row)
			continue
		}
		if number >= count || !line_valid(number) {
			continue
		}
		view.text_rows += 1
		line := lines[number & (LINE_CAPACITY - 1)]
		column := 0
		continues := false // The line has a character after the last column.
		for run_index in line.first_run ..< line.first_run + u64(line.run_count) {
			run := runs[run_index & (RUN_CAPACITY - 1)]
			color := style_color(run.style)
			reverse := .Reverse in run.style.flags
			// The bytes of the run in one piece, since the kept bytes start
			// again at their first byte after their last. A run has at most
			// RUN_LIMIT bytes, and the library cuts a text after a whole
			// character, so a run holds whole characters.
			run_bytes: [terminal.RUN_LIMIT]u8
			run_byte_count := int(min(run.length, terminal.RUN_LIMIT))
			for offset in 0 ..< run_byte_count {
				run_bytes[offset] = bytes[(run.start + u64(offset)) & (BYTE_CAPACITY - 1)]
			}
			run_place := 0
			for run_place < run_byte_count {
				character, length := character_at(run_bytes[:run_byte_count], run_place)
				// A character that does not fit before the end of the row,
				// a wide one at the last column too: the line continues.
				next, result := wide_cells.row_put(wide_row[:columns], column, character, Cell{reverse = reverse, color = color})
				if result == .No_Room {
					continues = true
					break
				}
				// The fill of the view looks at each cell already: the
				// drawer then looks at one character, not at the cells.
				if result == .Placed && !graphics.cell_font_draws(character) {
					if view.fallback_first == 0 {
						view.fallback_first = character
					}
					view.fallback_last = character
				}
				column = next
				run_place += length
			}
			if continues {
				break
			}
		}
		if continues {
			// The line continues after the window. The mark clears the
			// half of a wide character that it covers.
			wide_cells.row_put(wide_row[:columns], columns - 1, '>', Cell{reverse = true, color = graphics.colors.dim})
		}
		cells_from_wide(&row, wide_row[:columns])
	}
	edit_top := int(i64(count) - i64(top))
	list_fill(edit_top, edit_top + int(edit_rows + free_rows))
}

// hint_fill writes the hint line in the free row under the edit line: its
// long form when it fits in the columns, if not its short form, cut to the
// columns.
hint_fill :: proc "contextless" (row: ^[COLUMNS_LIMIT]Cell) {
	long_text := hint_line.text[:hint_line.long_count]
	short_text := hint_line.text[hint_line.long_count:hint_line.length]
	form, shown := terminal.hint_form_choose(cells_of(long_text), cells_of(short_text), columns)
	text := form == .Long ? long_text : short_text
	marked := hint_line.marked[form]
	color := style_color(hint_line.style)
	place := 0 // The byte of the form where the character starts: the mark is in bytes.
	column := 0
	wide_row: Wide_Row
	for place < len(text) {
		character, length := character_at(text, place)
		in_mark := place >= marked[0] && place < marked[0] + marked[1]
		next, result := wide_cells.row_put(wide_row[:shown], column, character, Cell{color = in_mark ? own_colors().tones[.Accent] : color})
		if result == .No_Room {
			break
		}
		column = next
		place += length
	}
	cells_from_wide(row, wide_row[:shown])
}

BATCH :: 1024 // The records that the reader reads between two looks at the request.

read :: proc "c" (parameter: rawptr) -> ! {
	queue := &source.commands
	for {
		if intrinsics.atomic_load(&request_word) != 0 {
			view_make()
			intrinsics.atomic_store(&request_word, 0)
			if intrinsics.atomic_exchange(&drawer_waits, 0) != 0 {
				system.word_wake(&request_word)
			}
		}
		count := 0
		for count < BATCH {
			record, ok := system.receive(queue)
			if !ok {
				break
			}
			apply(record)
			count += 1
		}
		if count != 0 {
			intrinsics.atomic_add(&activity, 1)
			if intrinsics.atomic_load(&drawer_idle) != 0 && intrinsics.atomic_exchange(&drawer_idle, 0) != 0 {
				intrinsics.atomic_add(&drawer_wakes, 1)
				system.word_wake(&activity)
			}
		}
		// The oldest lines go when an area starts again.
		if lines_written >= LINE_CAPACITY {
			oldest = max(oldest, lines_written + 1 - LINE_CAPACITY)
		}
		for oldest < lines_written && !line_valid(oldest) {
			oldest += 1
		}
		if count == 0 {
			list: system.Wait
			system.wait_records(&list, queue)
			system.wait_word(&list, &request_word, 0, &reader_idle)
			if !system.wait_spin(&list) {
				system.wait_end(&list)
			}
		}
	}
}

// view_take asks the reader for a view, and waits for it.
view_take :: proc "contextless" () {
	intrinsics.atomic_store(&request_word, 1)
	if intrinsics.atomic_exchange(&reader_idle, 0) != 0 {
		system.word_wake(&request_word)
	}
	for _ in 0 ..< 4000 {
		if intrinsics.atomic_load(&request_word) == 0 {
			break
		}
		intrinsics.cpu_relax()
	}
	for intrinsics.atomic_load(&request_word) != 0 {
		list: system.Wait
		system.wait_word(&list, &request_word, 1, &drawer_waits)
		system.wait_end(&list)
	}
	request.stopped = false
}

// ---- The drawer.

process: system.Handle // The process that writes, with the right Read. 0 after it stopped.

Rates :: struct {
	lines:   u64, // In one second.
	records: u64,
	bytes:   u64,
	entries: u64, // Kernel entries of the process that writes, for one million records.
	frames:  u64,
}

rates: Rates
history: [HISTORY]u64 // Lines in one second, the last measure at the end.

// number gives a number as text, with a space between each three digits.
number :: proc "contextless" (buffer: ^[27]u8, value: u64) -> string {
	place := len(buffer)
	rest := value
	for digit := 0;; digit += 1 {
		if digit != 0 && digit % 3 == 0 {
			place -= 1
			buffer[place] = ' '
		}
		place -= 1
		buffer[place] = u8('0' + rest % 10)
		rest /= 10
		if rest == 0 {
			break
		}
	}
	return string(buffer[place:])
}

// The drawing of the window through the drawing module: the cells of the
// view are a text grid, so a frame damages only the cells that changed.
// draw_text_grid copies the cells into the text table of the frame, and
// the table before keeps them in its own copy of the text. The text
// tables are words: the cells hold 4-byte colors, so the table starts at
// an address that is a multiple of 4. Each holds the texts of a frame, the
// 3 bytes at most before the cells, and the cells of the largest grid.
// The count of records does not follow the rows: the grid is one record,
// and the only records of each row are the icons of the completion list,
// at most terminal.LIST_ROWS.
records_now, records_before: [448]interface.Draw_Record
TEXT_WORDS :: (1024 + 4 + ROWS_LIMIT * COLUMNS_LIMIT * size_of(Cell)) / 4
text_words_now, text_words_before: [TEXT_WORDS]u32
// What the pointer did to the scroll bar of the lines in the last frame.
scroll_result: interface.Scroll_Bar_Result
// The scroll bar of the completion list in the last frame: its area (no
// width: the frame had no such bar), and what the pointer did to it.
list_scroll_area: interface.Area
list_view_area: interface.Area // The cells of the rows of the completion list in the last frame, or no width: the wheel over them belongs to the list.
list_scroll_result: interface.Scroll_Bar_Result
list_scroll_identity: interface.Element_Identity
// The first row that the terminal asked the process for, and the first row
// that the list had then: the scroll bar gives the same row at each frame
// until the process answers, and the terminal asks one time. -1: no
// request waits for an answer.
list_first_asked := -1
list_first_when_asked: int
// The pointer shape that the terminal asked for last is the arrow: the
// pointer was over a scroll bar, or held one. If not, it is the text shape.
pointer_shape_is_arrow: bool
drawing: interface.Window_Drawing

drawing_start :: proc "contextless" () {
	text_now := ([^]u8)(&text_words_now[0])[:TEXT_WORDS * 4]
	text_before := ([^]u8)(&text_words_before[0])[:TEXT_WORDS * 4]
	drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now, text_before)
}

// view_grid gives the cells of the view that the window shows: the rows
// and the columns of this terminal, in the cells of the largest view.
view_grid :: proc "contextless" () -> interface.Text_Grid {
	return grid_resize.grid_text_grid(&grid)
}

tile :: proc "contextless" (table: ^interface.Draw_Table, x: int, label: string, value: u64, color: graphics.Color) {
	buffer: [27]u8
	interface.draw_text(table, x, 8, label, graphics.colors.dim)
	interface.draw_text(table, x, 28, number(&buffer, value), color, interface.FONT_LARGE)
}

// The font of the interface text of the window in the last frame, once
// known: the log names each change, so that a machine test knows which
// font a picture shows before it takes it.
interface_text_font_told: interface.Font_Kind
interface_text_font_known: bool

// interface_text_font_tell writes one line when the font that draws the
// interface text of the window changes: the interface font, or the font of
// the cells (the setting `spleen`, or no interface font).
interface_text_font_tell :: proc "contextless" (table: ^interface.Draw_Table) {
	used := interface.font_in_use(table, interface.FONT_INTERFACE, 0).kind
	if interface_text_font_known && used == interface_text_font_told {
		return
	}
	interface_text_font_told, interface_text_font_known = used, true
	if used == .Interface {
		system.log_fact(.Info, Interface_Text_In_Interface_Font{shown_process = shown_process_field()})
	} else {
		system.log_fact(.Info, Interface_Text_In_Cell_Font{shown_process = shown_process_field()})
	}
}

draw :: proc "contextless" (window: ^display.Window, follow: bool) {
	buffer: [27]u8
	frame := interface.window_frame_begin(&drawing, window)
	table := frame.table
	interface_text_font_tell(table)
	// While the list of the action bar is open, a press is the bar's: the
	// scroll bars under the list do not take it.
	interface.action_bar_input_take(&frame, &bar)

	if measure {
		// The head: the rates, and the graph of the lines in one second.
		interface.draw_rectangle(table, 0, 0, width, HEAD_HEIGHT - 6, graphics.colors.card_top)
		tile(table, 12, "lines in one second", rates.lines, own_colors().graph)
		tile(table, 196, "records in one second", rates.records, graphics.colors.text)
		tile(table, 388, "kernel entries, million records", rates.entries, own_colors().held)
		most: u64 = 1
		for value in history {
			most = max(most, value)
		}
		for value, index in history {
			bar_height := int(value * GRAPH_HEIGHT / most)
			x := graph_x + index * GRAPH_BAR
			interface.draw_rectangle(table, x, 9, GRAPH_BAR - 1, GRAPH_HEIGHT - bar_height, own_colors().graph_dim)
			interface.draw_rectangle(table, x, 9 + GRAPH_HEIGHT - bar_height, GRAPH_BAR - 1, bar_height, own_colors().graph)
		}
	}

	// The text: only the rows of the window, as one text grid.
	interface.draw_text_grid(table, TEXT_X, text_y, view_grid())

	// The status of the process: a text, and a value of a total. With the
	// rates it has its own line. If not, it takes the place of the line count.
	// The line of the keys is the band of the action bar, from edge to
	// edge, under each text of the line: with no rates the status shares
	// it, and the line at the top of the band is the line over the status.
	bar_y := hint_y - 4
	interface.draw_rectangle(table, 0, bar_y, width, interface.ACTION_BAR_ROW_HEIGHT, graphics.colors.card_bottom)
	interface.draw_rectangle(table, 0, status_y - 4, width, 1, graphics.colors.track)
	if measure {
		interface.draw_rectangle(table, 0, bar_y, width, 1, graphics.colors.track)
	}
	status := &view.status
	has_status := status.total != 0
	status_end := TEXT_X // Where the text of the status ends: the keys at the right must not run over it.
	if has_status {
		color := style_color(status.style)
		x := interface.draw_text(table, TEXT_X, status_y, string(status.text[:status.length]), graphics.colors.text) + 12
		STATUS_BAR_WIDTH :: 240
		interface.draw_rectangle(table, x, status_y + 4, STATUS_BAR_WIDTH, 8, graphics.colors.track)
		interface.draw_rectangle(table, x, status_y + 4, status_bar_length(status.value, status.total, STATUS_BAR_WIDTH), 8, color)
		x = interface.draw_text(table, x + STATUS_BAR_WIDTH + 12, status_y, number(&buffer, status.value), graphics.colors.text)
		x = interface.draw_text(table, x, status_y, " of ", graphics.colors.dim)
		status_end = interface.draw_text(table, x, status_y, number(&buffer, status.total), graphics.colors.dim)
	} else if process == 0 && measure {
		interface.draw_text(table, TEXT_X, status_y, "The process does not run.", own_colors().stopped)
	}
	if measure {
		// At the right: the frames of the terminal.
		frames := number(&buffer, rates.frames)
		x := width - MARGIN - (len(frames) + len(" pictures in one second")) * CELL_WIDTH
		x = interface.draw_text(table, x, status_y, frames, graphics.colors.text)
		interface.draw_text(table, x, status_y, " pictures in one second", graphics.colors.dim)
	}

	// The place of the view, and the keys.
	// Where the text at the left of the keys ends. With no rates, the status
	// is on the line of the keys.
	hint_left := measure ? TEXT_X : status_end
	if measure || !has_status {
		// The lines of the text that the rows show: the edit line and the
		// row under it are not lines of the text.
		x := interface.draw_text(table, TEXT_X, hint_y, follow ? "lines " : "held at lines ", follow ? graphics.colors.dim : own_colors().held)
		if view.text_rows == 0 {
			x = interface.draw_text(table, x, hint_y, "none in view", follow ? graphics.colors.text : own_colors().held)
		} else {
			x = interface.draw_text(table, x, hint_y, number(&buffer, view.top + 1), follow ? graphics.colors.text : own_colors().held)
			x = interface.draw_text(table, x, hint_y, " to ", graphics.colors.dim)
			x = interface.draw_text(table, x, hint_y, number(&buffer, view.top + view.text_rows), follow ? graphics.colors.text : own_colors().held)
		}
		x = interface.draw_text(table, x, hint_y, " of ", graphics.colors.dim)
		x = interface.draw_text(table, x, hint_y, number(&buffer, view.count), graphics.colors.text)
		if view.gone {
			x = interface.draw_text(table, x, hint_y, "  older than the lines kept", graphics.colors.dim)
		}
		if process == 0 && !measure {
			x = interface.draw_text(table, x, hint_y, "  the process does not run", own_colors().stopped)
		}
		hint_left = x
	}
	// The keys: the action bar, at the right of the text of the line. Its
	// items stand from the right edge, so they keep their places while the
	// numbers at the left change. The bar is drawn last, below.
	bar_left := hint_left + 2 * CELL_WIDTH
	bar_area := interface.Area{bar_left, bar_y, max(width - MARGIN - bar_left, 0), interface.ACTION_BAR_ROW_HEIGHT}
	// The border of the completion list, one pixel outside its cells. It
	// comes last, so that the records before keep their places in the
	// table when the list opens or closes: the damage stays small.
	list_scroll_area = {}
	list_view_area = {}
	list_scroll_result = {}
	if view.list_columns > 0 {
		x := TEXT_X + view.list_left * CELL_WIDTH - 1
		y := text_y + view.list_top * CELL_HEIGHT - 1
		list_width := view.list_columns * CELL_WIDTH + 2
		list_height := view.list_rows * CELL_HEIGHT + 2
		interface.draw_rectangle(table, x, y, list_width, 1, graphics.colors.kernel)
		interface.draw_rectangle(table, x, y + list_height - 1, list_width, 1, graphics.colors.kernel)
		interface.draw_rectangle(table, x, y, 1, list_height, graphics.colors.kernel)
		interface.draw_rectangle(table, x + list_width - 1, y, 1, list_height, graphics.colors.kernel)
		// The kind icon of each row, over the cells that the row keeps for
		// it: one pixel for a cell of the icon, at the left of its cells, in the middle
		// of the height of the row.
		if view.list_icon_cells != 0 {
			icon_x := TEXT_X + (view.list_left + 1) * CELL_WIDTH + 2
			for index in 0 ..< view.list_rows {
				icon_y := text_y + (view.list_top + index) * CELL_HEIGHT + (CELL_HEIGHT - kind_icons.ICON_SIZE) / 2
				interface.draw_kind_icon(table, icon_x, icon_y, view.list_icons[index], 1, view.list_icon_colors[index])
			}
		}
		// The cells of the rows: the wheel over them belongs to the list.
		// A list with no scroll bar shows each row, so a notch over it
		// moves nothing: it does not move the lines under the list.
		list_view_area = {TEXT_X + view.list_left * CELL_WIDTH, text_y + view.list_top * CELL_HEIGHT, view.list_columns * CELL_WIDTH, view.list_rows * CELL_HEIGHT}
		if !view.list_scroll && frame.input.pointer_known && interface.area_contains(list_view_area, frame.input.pointer_x, frame.input.pointer_y) {
			frame.input.wheel = 0
		}
		// The scroll bar of the list, over its last cells and the right
		// column of its border. The process that writes owns the list and
		// its choice: the bar takes the pointer, and the first row that
		// the pointer asks for goes to the process (list_scroll_send).
		if view.list_scroll {
			bar_length := view.list_rows * CELL_HEIGHT
			bar_x := TEXT_X + (view.list_left + view.list_columns - LIST_SCROLL_CELLS) * CELL_WIDTH
			list_scroll_area = {bar_x, text_y + view.list_top * CELL_HEIGHT, SCROLL_WIDTH, bar_length}
			// The list lies over the lines: its bar comes before the bar of
			// the lines, and takes the wheel over the list first.
			// While the process has not answered a request, the bar starts
			// from the row that the terminal asked for: else a second
			// notch, or a second press, gives the same row again and is
			// lost.
			list_first := view.list_first
			if list_first_asked >= 0 && view.list_first == list_first_when_asked {
				list_first = list_first_asked
			}
			list_scroll_result = interface.scroll_bar(&frame, list_scroll_area, list_scroll_identity, .Vertical, {total = view.list_total, visible = view.list_rows, first = list_first}, {}, "", list_view_area)
		}
	}
	// The scroll bar of the lines: where the view is in the lines that the
	// terminal has. It is the last element: the pointer changes the count
	// of its records, and the records before it keep their places.
	kept := view.count - view.oldest
	shown_lines := min(u64(rows), kept)
	first_line: u64
	if !view.gone && view.top >= view.oldest {
		first_line = min(view.top - view.oldest, kept - shown_lines)
	}
	scroll_result = interface.scroll_bar(&frame, scroll_area, scroll_identity, .Vertical, {total = int(max(kept, 1)), visible = int(max(shown_lines, 1)), first = int(first_line)}, {page = rows - 1}, "scroll bar", text_view_area)
	// The action bar, after each other element: its list opens over the
	// lines and the scroll bar.
	items := bar_items()
	bar_result = interface.action_bar(&frame, bar_area, items[:], &bar, {alignment = .Right})
	interface.window_frame_end(&drawing, &frame, window)
	if table.full {
		system.log_fact(.Info, Draw_Table_Full{})
	}
}

// The keys of the terminal, in its action bar (docs/INTERFACE.md, "4.4
// The action bar"). Each other key goes to the process, which names its
// own keys.
// A procedure, not a global array: an item is made by a call, and a
// freestanding process runs no call before its entry.
bar_items :: proc "contextless" () -> [2]interface.Action_Bar_Item {
	return {interface.action_bar_item("Lines before", 1, "Page Up"), interface.action_bar_item("Lines after", 1, "Page Down")}
}
bar: interface.Action_Bar_State
bar_result: interface.Action_Bar_Result // What the action bar of the last frame ran.

// page_move gives the lines that a key moves the view: a page less one
// line for Page Up and Page Down, 0 for another key.
page_move :: proc "contextless" (code: u32) -> i64 {
	switch code {
	case display.KEY_PAGE_UP:
		return -i64(rows - 1)
	case display.KEY_PAGE_DOWN:
		return i64(rows - 1)
	}
	return 0
}

// view_move asks for the view moved by some lines: the view holds there
// while the process writes, and follows the last lines again when it
// reaches them.
view_move :: proc "contextless" (move: i64) {
	if move == 0 {
		return
	}
	was_following := request.follow
	request.follow = false
	request.top = u64(max(i64(view.top) + move, i64(view.oldest)))
	if request.top + u64(rows) >= view.count {
		request.follow = true
	}
	if was_following && !request.follow {
		system.log_fact(.Info, View_Stays{line = request.top + 1, shown_process = shown_process_field()})
	}
}

// status_bar_length gives the pixels of the bar of a status: value of total
// on length pixels. The process that writes chooses both numbers: a
// product value x length can pass the largest u64, so a large total is
// divided first. The bar is never longer than length.
status_bar_length :: proc "contextless" (value, total: u64, length: int) -> int {
	if total == 0 {
		return 0
	}
	shown := min(value, total)
	if total <= max(u64) / u64(length) {
		return int(shown * u64(length) / total)
	}
	return int(min(shown / (total / u64(length)), u64(length)))
}

fail :: proc "contextless" (text: string) -> ! {
	system.log_fact(.Info, Start_Failed{failure = value_kinds.text_field(text, FAILURE_FIELD_BYTES)})
	system.stop(.Failed)
}

// The entry of the terminal: it opens the window of one process, starts the
// reader thread, then draws the lines and sends the keys until the machine
// stops.
//
// When the root service starts it, the entry:
//
// 1. reads its values: the name of the process, the columns (40 at least),
//    the rows (4 at least), and the flag that it measures;
// 2. opens a window of two pictures with the name of the process; with no
//    window, it writes "terminal: no surface" and stops with `Failed`;
// 3. creates the three areas of the lines;
// 4. opens the terminal ring and maps the text region, read-only; a wrong
//    ring or region stops it with `Failed`;
// 5. starts the reader thread, and writes "terminal: ok, ...".
//
// The first thread is then the drawer. It sleeps while nothing changes,
// and wakes for a record, a key, the stop of the process, or every 250 ms
// to look at the state of the process. Page Up and Page Down move the
// view; each other key goes to the process, and a key is lost when the
// queue is full. When the process
// stops, the terminal shows its code and keeps its lines: it does not stop
// with it.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	name_bytes = system.name_unpack({ctx.values[terminal.VALUE_NAME], ctx.values[terminal.VALUE_NAME + 1], ctx.values[terminal.VALUE_NAME + 2], ctx.values[terminal.VALUE_NAME + 3]})
	process_name = system.name_of(name_bytes[:])
	columns = int(clamp(ctx.values[terminal.VALUE_COLUMNS], 40, COLUMNS_LIMIT))
	rows = int(clamp(ctx.values[terminal.VALUE_ROWS], 4, ROWS_LIMIT))
	measure = ctx.values[terminal.VALUE_MEASURE] != 0
	layout()
	process = ctx.handles[terminal.GRANT_PROCESS]
	window, ok := display.open(ctx, width, height, process_name)
	if !ok {
		fail("no surface")
	}
	// Bind the resizable grid to view.cells and declare window resize limits.
	_ = grid_resize.grid_init(&grid, ([^]Cell)(&view.cells[0][0])[:ROWS_LIMIT * COLUMNS_LIMIT], COLUMNS_LIMIT, columns, rows, grid_resize.TERMINAL_WINDOW_BOUNDS)
	chrome_w, chrome_h := chrome_size()
	if limits, limits_ok := grid_resize.window_size_limits(chrome_w, chrome_h, CELL_WIDTH, CELL_HEIGHT, grid_resize.TERMINAL_WINDOW_BOUNDS); limits_ok {
		_, _ = display.resizable_set(&window, limits)
	}
	// The surface is text: the pointer over it is the text shape.
	display.pointer_shape_set(&window, .Text)
	drawing_start()

	// The areas of the lines.
	area :: proc "contextless" (size: u64) -> rawptr {
		memory, status := system.memory_create((size + system.PAGE_SIZE - 1) / system.PAGE_SIZE)
		if status != .Succeeded {
			fail("no memory for the lines")
		}
		address: rawptr
		if address, status = system.memory_map(memory); status != .Succeeded {
			fail("no memory for the lines")
		}
		return address
	}
	lines = ([^]Line)(area(LINE_CAPACITY * size_of(Line)))
	runs = ([^]Run)(area(RUN_CAPACITY * size_of(Run)))
	bytes = ([^]u8)(area(BYTE_CAPACITY))[:BYTE_CAPACITY]

	// The terminal ring and the text region, from the root service. This
	// process has the right Read only on the text region.
	status: call_outcome.Call_Outcome
	if source, status = system.ring_open(ctx.handles[terminal.GRANT_RING]); status != .Succeeded {
		fail("no terminal ring")
	}
	if text_pages, text_status := system.memory_size(ctx.handles[terminal.GRANT_TEXT]); text_status != .Succeeded || text_pages != terminal.TEXT_PAGES {
		fail("no text region")
	}
	if address, map_status := system.memory_map(ctx.handles[terminal.GRANT_TEXT], {}); map_status == .Succeeded {
		source_text = ([^]u8)(address)[:terminal.TEXT_SIZE]
	} else {
		fail("no text region")
	}
	if _, status = system.thread_start(read, nil); status != .Succeeded {
		fail("no thread")
	}
	system.log_fact(.Info, Window_Ready{ring_records = u64(ring.capacity(&source.commands)), shown_process = shown_process_field()})

	request.follow = true
	now := system.time()
	next_frame := now
	sample_time := now
	sample_lines, sample_records, sample_bytes, sample_entries: u64
	frames, sample_frames: u64
	sample_entries = system.process_entries(process)
	keys_sent: u64
	keys_loss: key_path.Loss_Period // The keys that the full queue of the process refused.
	// One line of the log, for the second that follows the first second.
	second_start: u64
	second_lines, second_records, second_entries, second_frames: u64
	second_logged := false
	drawn: u32 // The value of activity at the last picture.
	dirty := true // The view changed with no record: a key, the first picture.
	STATE_TIME :: 250 // Milliseconds between two looks at the state of the process.
	picture_waits := false // A picture waits until the compositor took the picture before it.
	// The event word of this thread at the last look at the state of the
	// process: the kernel adds 1 to it when the process stops.
	events_seen := intrinsics.volatile_load(system.events())
	for {
		// One read of the count of the groups of records decides the wait,
		// and the compositor learns the due state before it: in each wait the
		// terminal looks the same as a terminal with nothing to draw. A record
		// that came while the last picture was drawn is due too, and the
		// Present of that picture ended the due state that came before it
		// (src/md/features/terminal_due_picture.md).
		seen := intrinsics.atomic_load(&activity)
		turn_wait, due := terminal.picture_wait_choose(measure, dirty, seen, drawn, picture_waits)
		display.picture_due_set(&window, due)
		switch turn_wait {
		case .Nothing_To_Draw:
			// Wait for a record, a key, the stop of the process, or the next
			// look at the process. A record after the read of seen, or a stop
			// after the last look at the state, ends the wait at once.
			wait: system.Wait
			display.wait_events(&wait, &window)
			system.wait_word(&wait, &activity, seen, &drawer_idle)
			system.wait_word(&wait, system.events(), events_seen)
			// A held arrow button of the scroll bar takes its next step at
			// a time of the clock: the wait ends there at the latest.
			deadline := process != 0 ? system.time() + STATE_TIME : system.WAIT_FOREVER
			step_time, step_due := interface.window_scroll_bar_wake(&drawing)
			if step_due {
				deadline = min(deadline, step_time)
			}
			wakes_before := intrinsics.atomic_load(&drawer_wakes)
			activity_at_wait = seen
			system.wait_end(&wait, deadline)
			now = system.time()
			next_frame = now
			if step_due && now >= step_time {
				dirty = true
			}
			lost_wake_check(now >= deadline, wakes_before)
		case .Compositor:
			// The wait ends when the compositor has read the ring of the
			// window, or at the next look at the process.
			now = display.wait(&window, system.time() + STATE_TIME)
		case .Next_Frame:
			// A record during this wait needs no wake: the picture is due
			// already, and the next picture takes it.
			now = display.wait(&window, next_frame)
		}
		// The choice of the settings page, read at each turn: the
		// compositor tells only a window with a surface, and this window
		// can read the page before the boot pass of `settings` and make its
		// surface after it. A change then draws the whole window, as the
		// event does. The number of the changes, not the answer of the
		// call: next_event applies the page too, before this turn sees it.
		_ = display.text_settings_apply()
		if interface.text_settings_follow(&drawing) {
			dirty = true
		}
		// The window layer takes each event first: the bars, the wheel and
		// the page keys of a window that does not fit the work area, and
		// the pointer in the coordinates of the layout.
		for event in interface.window_next_event(&drawing, &window, .Every_Event) {
			// A new font: each record of the frame is the same, each pixel
			// of text is not. The next frame of each picture is whole.
			if event.kind == .Presentation {
				interface.draw_whole_window_next(&drawing)
				dirty = true
				continue
			}
			// An answer of a surface request: the window may hold a new
			// surface, whose pictures hold nothing yet (display, scale.odin).
			if event.kind == .Surface_Answer {
				interface.draw_whole_window_next(&drawing)
				dirty = true
				continue
			}
			// A window resize: compute new grid dimensions, resize the surface
			// and cell buffer atomically, update layout, and notify the client.
			if event.kind == .Resized {
				cw, ch := chrome_size()
				new_columns, new_rows, resize_err := grid_resize.grid_dimensions_from_window(event.width, event.height, cw, ch, CELL_WIDTH, CELL_HEIGHT, grid.bounds)
				if resize_err != .None {
					_ = display.resize_decline(&window)
					continue
				}
				if display.surface_resize(&window, event.width, event.height) != .Succeeded {
					continue
				}
				if grid_resize.grid_resize_cells(&grid, new_columns, new_rows) == .None {
					columns = grid.columns
					rows = grid.rows
					layout_for_size(window.width, window.height)
					if process != 0 {
						_ = system.send(&source.completions, ring.Record{kind = u32(terminal.Input.Resized), values = {0 = u64(columns), 1 = u64(rows)}})
					}
				}
				interface.draw_whole_window_next(&drawing)
				dirty = true
				continue
			}
			// The pointer goes to the scroll bars and to the action bar, and
			// to no other part of the window: a frame is built only when
			// the pointer is on one of them, holds it, leaves it lit, turns
			// the wheel over the view of a scroll bar, or the list of the
			// action bar is open.
			if event.kind == .Pointer {
				if interface.window_scroll_frame_take(&drawing) || interface.scroll_bar_wants_frame(&drawing.state, &drawing.input, scroll_area, scroll_identity, text_view_area) || interface.scroll_bar_wants_frame(&drawing.state, &drawing.input, list_scroll_area, list_scroll_identity, list_view_area) || interface.action_bar_wants_frame(&bar, &drawing.input) {
					dirty = true
				} else {
					// A notch over no view moves nothing: it must not wait
					// in the input for a later frame and move a view then.
					drawing.input.wheel -= event.wheel
				}
				pointer_shape_follow(&window)
				continue
			}
			// The clipboard (src/md/features/clipboard.md): the terminal has
			// no selection, so it declines a copy; a paste goes to the
			// process as typed characters.
			if event.kind == .Copy_Asked {
				display.copy_decline(&window)
				continue
			}
			if event.kind == .Pasted {
				paste_type(&window, event)
				dirty = true
				continue
			}
			if event.kind != .Key || !event.pressed {
				continue
			}
			dirty = true
			// The open list of the action bar takes its keys first.
			outcome := interface.action_bar_key(&bar, {code = event.code, character = event.character, modifiers = event.modifiers})
			if outcome.ran {
				view_move(page_move(outcome.run.code))
			}
			if outcome.taken {
				continue
			}
			move := page_move(event.code)
			switch event.code {
			case display.KEY_PAGE_UP, display.KEY_PAGE_DOWN:
			case:
				// The key goes to the process. The terminal never waits for
				// the process: this thread also draws the window and moves
				// the view, and a process that reads no key must not stop
				// them. The queue holds the keys typed ahead; when it is
				// full, the key is lost, and the log has one line when the
				// loss begins and one line with the count when it ends.
				if process != 0 {
					if event.key_serial > intrinsics.atomic_load(&key_serial_forwarded) {
						intrinsics.atomic_store(&key_serial_forwarded, event.key_serial)
					}
					if system.send(&source.completions, ring.Record{kind = u32(terminal.Input.Key), tag = event.code, values = {0 = u64(event.character), 1 = u64(event.modifiers), 2 = event.key_serial}}) {
						keys_sent += 1
						if keys_sent == 1 {
							system.log_fact(.Info, First_Key_Sent{shown_process = shown_process_field()})
						}
						if lost, ended := key_path.loss_end(&keys_loss); ended {
							system.log_fact(.Info, Keys_Read_Again{lost_keys = lost, shown_process = shown_process_field()})
						}
					} else if key_path.loss_count(&keys_loss) {
						system.log_fact(.Info, Keys_Not_Read{queue_keys = u64(ring.capacity(&source.completions)), shown_process = shown_process_field()})
					}
				}
				request.follow = true
			}
			view_move(move)
		}
		// A new surface waits for its first picture: the compositor shows
		// the frame of the window with the background until then.
		if display.picture_owed(&window) {
			dirty = true
		}
		// A change that this turn does not draw waits for the next picture:
		// the start of the next turn says it, before its wait.
		if now < next_frame {
			continue
		}
		// The stop of the process is a change too: it is known before the
		// look at the canvas, so a stop that waits for the compositor is a
		// due picture. The event word is read before the state: a stop
		// after this read ends the next wait with nothing to draw at once.
		events_seen = intrinsics.volatile_load(system.events())
		if process != 0 {
			if state, cause, outcome := system.process_state(process); state == .Stopped {
				request.stopped, request.cause, request.outcome = true, cause, outcome
				view_take()
				if cause == .Itself {
					system.log_fact(.Info, Stopped_Itself{lines = view.count - 1, records = view.records, cause = op.Stop_Cause_Word(cause), outcome = op.Stop_Outcome_Word(outcome), shown_process = shown_process_field()})
				} else {
					system.log_fact(.Info, Stopped_Without_Outcome{lines = view.count - 1, records = view.records, cause = op.Stop_Cause_Word(cause), shown_process = shown_process_field()})
				}
				if lost, ended := key_path.loss_end(&keys_loss); ended {
					system.log_fact(.Info, Stopped_With_Lost_Keys{lost_keys = lost, shown_process = shown_process_field()})
				}
				if refused := intrinsics.atomic_load(&records_refused); refused != 0 {
					system.log_fact(.Info, Stopped_After_Refused_Records{refused = refused, shown_process = shown_process_field()})
				}
				system.close(process)
				process = 0
				dirty = true
			}
		}
		// The compositor did not take the last picture yet: it can still
		// read the picture that this one would be drawn in. The keys are
		// taken; the picture waits for the compositor.
		picture_waits = !display.canvas_free(&window)
		if picture_waits {
			continue
		}
		next_frame = max(next_frame + FRAME_TIME, now + 1)
		current := intrinsics.atomic_load(&activity)
		if !measure && !dirty && current == drawn {
			continue
		}
		drawn, dirty = current, false
		view_take()
		// The picture shows the edit line of the view: its Present names the
		// newest key that the process put in it, for the measure of a key
		// to the screen.
		display.key_shown(&window, view.key_serial)
		frames += 1
		if now - sample_time >= SAMPLE_TIME {
			elapsed := now - sample_time
			entries := process != 0 ? system.process_entries(process) : sample_entries
			records := view.records - sample_records
			rates = {
				lines   = (view.count - sample_lines) * 1000 / elapsed,
				records = records * 1000 / elapsed,
				bytes   = (view.bytes - sample_bytes) * 1000 / elapsed,
				entries = records != 0 && entries >= sample_entries ? (entries - sample_entries) * 1_000_000 / records : 0,
				frames  = (frames - sample_frames) * 1000 / elapsed,
			}
			copy(history[:], history[1:])
			history[HISTORY - 1] = rates.lines
			sample_time, sample_lines, sample_records, sample_bytes, sample_entries, sample_frames = now, view.count, view.records, view.bytes, entries, frames
			if measure && !second_logged && process != 0 {
				if second_start == 0 {
					if view.records != 0 {
						second_start, second_lines, second_records, second_entries, second_frames = now, view.count, view.records, entries, frames
					}
				} else if now - second_start >= 1000 {
					second_logged = true
					time := now - second_start
					system.log_fact(
						.Info,
						Second_Measured {
							lines_per_second = (view.count - second_lines) * 1000 / time,
							records_per_second = (view.records - second_records) * 1000 / time,
							kernel_entries_per_million = (entries - second_entries) * 1_000_000 / max(view.records - second_records, 1),
							pictures_per_second = (frames - second_frames) * 1000 / time,
							shown_process = shown_process_field(),
						},
					)
				}
			}
		}
		// The frame of the text of this process: the glyphs past the glyph
		// cache that it draws below, as the drawing module draws them in
		// its own copy, from the same outlines.
		display.text_frame_begin()
		display.text_not_kept_tell()
		draw(&window, request.follow)
		fallback_cells_tell()
		// A frame that did not reach the compositor (a Present that the full
		// command ring refused, a frame left out, a draw that the module
		// refused) is still owed: the next turn draws it again, and says
		// before its wait that it is due.
		if drawing.late || !drawing.drawn {
			dirty = true
		}
		// A press on an item of the action bar runs its key, as the key
		// does: the next picture shows the moved view.
		if bar_result.ran {
			view_move(page_move(bar_result.run.code))
			dirty = true
		}
		// The scroll bar moved the view: the next picture shows the lines
		// from its first unit. The log has one line for a press that moved
		// the view and one for a drag, not one for each step.
		if scroll_result.changed {
			request.top = view.oldest + u64(scroll_result.first)
			request.follow = request.top + u64(rows) >= view.count
			dirty = true
			scroll_drag_moved ||= scroll_result.held == .Thumb
			if scroll_result.pressed_now != .None && scroll_result.pressed_now != .Thumb {
				scroll_log("a press on", scroll_part_words(scroll_result.pressed_now))
			}
			if scroll_result.wheel_taken {
				wheel_log()
			}
		}
		if scroll_result.drag_ended {
			if scroll_drag_moved {
				scroll_log("a drag of", "the thumb")
			}
			scroll_drag_moved = false
		}
		if list_scroll_send() {
			dirty = true
		}
		// A frame can end a press on a scroll bar, or move the list under
		// a still pointer: the shape follows with no move of the pointer.
		pointer_shape_follow(&window)
	}
}

// list_scroll_send gives the process the first row that the pointer asked
// for on the scroll bar of the completion list, as one input record. The
// process owns the list: it answers with the rows of its new view. The
// scroll bar gives the same row at each frame until that answer, so a row
// is asked one time, and again only after the list moved. It gives true
// when it sent a record. The log has one line for a press that moved the
// view and one for a drag, not one for each step.
list_scroll_send :: proc "contextless" () -> (sent: bool) {
	if list_scroll_area.width == 0 || list_first_asked >= 0 && view.list_first != list_first_when_asked {
		list_first_asked = -1 // No list, or the process answered.
	}
	moved := list_scroll_result
	if moved.changed && process != 0 && moved.first != list_first_asked {
		sent = system.send(&source.completions, ring.Record{kind = u32(terminal.Input.List_First), values = {0 = u64(moved.first)}})
		if sent {
			list_first_asked, list_first_when_asked = moved.first, view.list_first
			list_drag_moved ||= moved.held == .Thumb
			if moved.pressed_now != .None && moved.pressed_now != .Thumb {
				system.log_fact(.Info, List_Scroll_Pressed{first_row = u64(moved.first), rows = u64(view.list_total), scroll_part = scroll_part_field(scroll_part_words(moved.pressed_now)), shown_process = shown_process_field()})
			}
			if moved.wheel_taken {
				system.log_fact(.Info, List_Wheel_Moved{first_row = u64(moved.first), rows = u64(view.list_total), shown_process = shown_process_field()})
			}
		}
	}
	if moved.drag_ended {
		if list_drag_moved {
			system.log_fact(.Info, List_Thumb_Dragged{first_row = u64(moved.first), rows = u64(view.list_total), shown_process = shown_process_field()})
		}
		list_drag_moved = false
	}
	return sent
}

list_drag_moved: bool // The drag of the thumb of the completion list that is held now moved its view.
fallback_fonts_told: text_rendering.Outline_Fonts // The fonts of the fallback chain whose first cell drawn by this process is on the log.
missing_cell_told: bool // The line of the first cell that no font of the chain has is on the log.
fallback_cells_all_told: bool // Each line that fallback_cells_tell can write is on the log: it looks at no cell again.

// fallback_cells_tell says, after a frame, where the first and the last
// cells past the 192 characters of Spleen of the view come from: once for each font of
// the fallback chain, and once for no font. The process draws the glyph
// of the cell as the drawing module drew it, from the same outlines, and
// checks that it has ink and stays in its cell. Once each line is on the
// log, it returns at once: no lookup runs at each frame for nothing.
fallback_cells_tell :: proc "contextless" () {
	if fallback_cells_all_told {
		return
	}
	defer if missing_cell_told && fallback_fonts_told >= text_rendering.chain_fonts(.Cells) {
		fallback_cells_all_told = true
	}
	for character in ([2]rune{view.fallback_first, view.fallback_last}) {
		if character == 0 {
			return
		}
		found := display.cell_fallback_of(character)
		switch found.source {
		case .Private_Cache, .Not_Kept:
			if found.font not_in fallback_fonts_told && found.rows > 0 && found.inside {
				fallback_fonts_told += {found.font}
				system.log_fact(.Info, Cell_From_Fallback_Font{character = u64(character), fallback_font = value_kinds.text_field(text_rendering.outline_font_name(found.font), FONT_NAME_FIELD_BYTES), shown_process = shown_process_field()})
			}
		case .Banded:
			// Drawn band by band, before the process had its glyph memory
			// (display.cell_fallback_of reserves it): told at a later
			// frame, when the glyph is in the private glyph cache.
		case .Busy:
			// Refused because another thread held the private glyph cache.
		case .Missing:
			if !missing_cell_told && found.font == .None {
				missing_cell_told = true
				system.log_fact(.Info, Cell_Replacement_Glyph{character = u64(character), shown_process = shown_process_field()})
			}
		}
	}
}

// pointer_shape_follow asks the compositor for the arrow while the pointer
// is over a scroll bar of the window or holds one, and for the text shape
// over the rest of the surface: a scroll bar is a control, not text
// (docs/POINTERS.md, "The request of a process"). It asks only at a change:
// the compositor writes one line of the log for each request.
pointer_shape_follow :: proc "contextless" (window: ^display.Window) {
	input := &drawing.input
	held := drawing.state.pressed
	over := held == scroll_identity || held == list_scroll_identity
	if !over && input.pointer_known {
		over = interface.area_contains(scroll_area, input.pointer_x, input.pointer_y) || interface.area_contains(list_scroll_area, input.pointer_x, input.pointer_y)
	}
	if over == pointer_shape_is_arrow {
		return
	}
	pointer_shape_is_arrow = over
	if over {
		display.pointer_shape_set(window, .Arrow)
	} else {
		display.pointer_shape_set(window, .Text)
	}
}

scroll_drag_moved: bool // The drag of the thumb that is held now moved the view.

// scroll_part_words gives the words of the log for a part of the scroll bar.
scroll_part_words :: proc "contextless" (part: interface.Scroll_Bar_Part) -> string {
	switch part {
	case .None:
		return "no part"
	case .Arrow_Back:
		return "the arrow up"
	case .Arrow_Forward:
		return "the arrow down"
	case .Track_Back:
		return "the track above the thumb"
	case .Track_Forward:
		return "the track under the thumb"
	case .Thumb:
		return "the thumb"
	}
	return "no part"
}

// wheel_log writes that the wheel moved the view of the lines, and where
// the view is after it: one line for each frame that the wheel moved.
wheel_log :: proc "contextless" () {
	if request.follow {
		system.log_fact(.Info, Wheel_Follows{shown_process = shown_process_field()})
	} else {
		system.log_fact(.Info, Wheel_At_Line{line = request.top + 1, lines = view.count, shown_process = shown_process_field()})
	}
}

// scroll_log writes what the pointer did on the scroll bar of the lines,
// and where the view is after it. The act is "a press on" or "a drag of".
scroll_log :: proc "contextless" (act, part: string) {
	if request.follow {
		system.log_fact(.Info, Scroll_Follows{scroll_act = value_kinds.text_field(act, SCROLL_ACT_FIELD_BYTES), scroll_part = scroll_part_field(part), shown_process = shown_process_field()})
	} else {
		system.log_fact(.Info, Scroll_At_Line{line = request.top + 1, lines = view.count, scroll_act = value_kinds.text_field(act, SCROLL_ACT_FIELD_BYTES), scroll_part = scroll_part_field(part), shown_process = shown_process_field()})
	}
}

// The memory of a paste: the copy that display.paste_read checks. The
// terminal types a paste as one key record for each character, and its
// queue holds RING_CAPACITY records: a paste of more characters is refused
// whole, so the copy holds the longest characters of a full queue.
paste_bytes: [terminal.RING_CAPACITY * text_encoding.CHARACTER_BYTES_LIMIT]u8

// paste_type gives the text of a paste to the process as typed characters:
// one key record with no key code for each character, in the order of the
// text, as the principal could type them (src/md/features/clipboard.md).
// The text holds no control character, so a paste never presses Enter.
// The terminal never waits for the process: the paste goes whole when the
// queue of the process has room for each of its characters, else nothing
// is typed, and the log says it.
paste_type :: proc "contextless" (window: ^display.Window, event: display.Event) {
	count, problem := display.paste_read(window, event, paste_bytes[:])
	if problem != .None {
		return
	}
	text := paste_bytes[:count]
	characters := text_encoding.character_count(text)
	if process == 0 {
		system.log_fact(.Info, Paste_Without_Process{characters = u64(characters)})
		return
	}
	room := int(ring.capacity(&source.completions) - ring.count(&source.completions))
	if characters > room {
		system.log_fact(.Info, Paste_Too_Large{characters = u64(characters), room = u64(room), shown_process = shown_process_field()})
		return
	}
	for place := 0; place < count; {
		character, length, _ := text_encoding.character_decode(text, place)
		if length == 0 {
			break
		}
		place += length
		system.send(&source.completions, ring.Record{kind = u32(terminal.Input.Key), tag = 0, values = {0 = u64(character), 1 = 0}})
	}
	system.log_fact(.Info, Paste_Sent{characters = u64(characters), shown_process = shown_process_field()})
}
