// A paint program: brushes, an eraser, a palette and a custom color, the
// tools line, rectangle, ellipse and fill, undo and redo, and pictures in
// the private store of the process. The design is in
// src/md/features/paint_application.md.
//
// This process is also a service: it serves its exports while it runs.
// Another process draws on the picture with isolated calls. The calls run
// in the one thread of this process, between two input events.
//
// **What it is for.** It is the paint program of the desktop, and the
// smallest process that is both an application and a service: the same
// window takes the pointer and the calls of the console, with one thread
// and no lock, because a call runs between two events.
//
// **Start**: start("paint") in the console, or the bar of the desktop.
// Then, from the console: connect("paint"), paint.line(0, 0, 479, 295, 4),
// paint.write(20, 20, "hello", 9). The log has "paint: ok" when the window
// opens.
//
// **The keys**: B brush, E eraser, L line, R rectangle, O ellipse, F fill,
// [ and ] the size, Ctrl+Z undo, Ctrl+Shift+Z and Ctrl+Y redo, Ctrl+O the
// pictures, C clear, Escape closes a panel. The right button draws with
// the paper.
//
// **Grants**, as the root service gives them:
//
// - **Serve**: its exports, for the console.
// - **Store**: its private store, for the pictures.
//
// **The picture**: the largest is the logical screen of the reference
// screen. The window shows its top left part; a resize never cuts it. The
// colors of the exports are the 16 colors of the palette, numbered 0 to
// 15: dark, white, gray, light gray, red, orange, yellow, green, teal,
// blue, violet, pink, brown, sand, navy, paper.
package paint

import "internal:paint/paint_model"
import "modus:contract/accessibility"
import "modus:contract/draw_record"
import "modus:contract/errors"
import "modus:contract/module"
import "modus:contract/reference_screen"
import "modus:contract/scale_factor"
import "modus:contract/value_kinds"
import "modus:display"
import "modus:graphics"
import "modus:interface"
import "modus:storage"
import "modus:system"
import "modus:trigonometry"

// The size of the window at its start, its least size and its largest:
// the logical screen of the reference screen.
WIDTH :: 640
HEIGHT :: 440
LEAST_WIDTH :: 600
LEAST_HEIGHT :: 360
LARGEST_WIDTH :: 1536
LARGEST_HEIGHT :: 864
#assert(LARGEST_WIDTH == paint_model.PICTURE_WIDTH_LIMIT)
#assert(LARGEST_HEIGHT == paint_model.PICTURE_HEIGHT_LIMIT)

// The budget of paint, under the largest budget that the root service
// gives a process (module.LARGEST_BUDGET_PAGES of the module contract, which
// the root service reads too: 16384 pages), with a margin. The tool counts the module pages (the code,
// the data and each array below), the stacks of the two threads and the
// two pictures of the window at its largest size; the source states the
// working memory. The arrays, in pages of 4 KiB:
//
//   picture_pixels    1296  the picture at its largest, 1536 x 864 x 4 bytes
//   backup_pixels     1296  the picture before a stroke; the rows of a read
//   history_arena      256  the steps of undo, 1 MiB
//   history_scratch     99  one strip of 32 rows and its compressed form
//   fill_memory         73  the bitmap and the stack of a fill
//   piece_bytes          9  one piece of a keep, and the header of a read
//
// The window: 1536 x 864 logical pixels at the largest scale, cut on each
// axis to the reference screen as the tool counts it
// (src/md/features/desktop_to_browser.md, "The budgets"): 1920 x 1080
// pixels, 4 bytes each, two pictures: 4050 pages. A resize holds the old
// surface and the new one together until the compositor shows the new one,
// so the working memory holds a second surface: 4050 pages. It also holds
// the least budget of 2048 pages less a window of 480 x 320 (300 pages):
// 1748 pages for the stack, the tables and the glyph memory; the glyph
// memory of the copy of the text rendering of the drawing module, 354
// pages (display.TEXT_MEMORY_PAGES); and 48 pages, the stack of the worker
// thread past the 16 pages that the tool counts for a thread.
// 4050 + 1748 + 354 + 48 = 6200. The tool reads the literal; a check below
// ties it to these parts.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 6200, threads = 2, window_width = LARGEST_WIDTH, window_height = LARGEST_HEIGHT, window_least_width = LEAST_WIDTH, window_least_height = LEAST_HEIGHT}

// The check of the sum against the cap, at compile time: an array that
// grows past the cap stops the build here.
PAGE_BYTES :: 4096
PAGES_MARGIN :: 512
// The rule of the tool (scale_factor.window_surface_largest), from the same
// constants: a constant cannot call the procedure. The cut holds because
// the window is resizable with a least size within the logical screen at
// the largest scale: the budget states that least size, and the tool checks
// it against the call of resizable_set.
#assert(LEAST_WIDTH > 0 && LEAST_HEIGHT > 0 && LEAST_WIDTH <= scale_factor.LARGEST_LOGICAL_WIDTH && LEAST_HEIGHT <= scale_factor.LARGEST_LOGICAL_HEIGHT)
WINDOW_SCREEN_WIDTH :: min((u64(LARGEST_WIDTH) * u64(scale_factor.LARGEST) + scale_factor.EIGHTHS_OF_ONE / 2) / scale_factor.EIGHTHS_OF_ONE, u64(reference_screen.WIDTH))
WINDOW_SCREEN_HEIGHT :: min((u64(LARGEST_HEIGHT) * u64(scale_factor.LARGEST) + scale_factor.EIGHTHS_OF_ONE / 2) / scale_factor.EIGHTHS_OF_ONE, u64(reference_screen.HEIGHT))
WINDOW_PAGES :: (2 * WINDOW_SCREEN_WIDTH * WINDOW_SCREEN_HEIGHT * 4 + PAGE_BYTES - 1) / PAGE_BYTES
#assert(MODULE_BUDGET.working_memory_pages == WINDOW_PAGES + 1748 + display.TEXT_MEMORY_PAGES + 48)
// The code, the data past the arrays, and the stacks of the two threads
// that the tool counts (72 and 19 pages): a bound over the measured module.
MODULE_PAGES_BOUND :: 512
ARRAY_PAGES :: (2 * size_of([paint_model.PICTURE_PIXELS]graphics.Color) + paint_model.HISTORY_BYTES + size_of(paint_model.History_Scratch) + size_of(paint_model.Fill_Memory) + paint_model.FILE_HEADER_BYTES + paint_model.KEEP_PIECE_BYTES + paint_model.FILE_HEADER_BYTES + PAGE_BYTES - 1) / PAGE_BYTES
#assert(ARRAY_PAGES + WINDOW_PAGES + MODULE_BUDGET.working_memory_pages + MODULE_PAGES_BOUND + PAGES_MARGIN <= module.LARGEST_BUDGET_PAGES)

GAP :: 4
ROW_HEIGHT :: 28 // The row of the tools.
PALETTE_TOP :: GAP + ROW_HEIGHT + GAP
PALETTE_CELL :: 24 // A cell of the palette, square.
CANVAS_TOP :: PALETTE_TOP + PALETTE_CELL + GAP
STATUS_HEIGHT :: interface.TABLE_LINE // The status line, and the action bar at its right.
PANEL_WIDTH :: 256 // A panel at the right of the canvas: the pictures, or the custom color.

// The exports draw lines of this width, as before the tools.
EXPORT_LINE_WIDTH :: 3

Panel :: enum u8 {
	None     = 0,
	Pictures = 1,
	Color    = 2,
}

// The picture and its memory. The arrays are in the module pages: the tool
// counts them.
picture_pixels: [paint_model.PICTURE_PIXELS]graphics.Color
backup_pixels: [paint_model.PICTURE_PIXELS]graphics.Color // The picture before the change in progress.
history_arena: [paint_model.HISTORY_BYTES]u8
history_scratch: paint_model.History_Scratch
fill_memory: paint_model.Fill_Memory
// The bytes of one piece of a keep, and the header of a read: the job of
// the store owns them from the ask to the take
// (src/md/features/background_work.md). A read puts the rows of a picture
// in backup_pixels: no stroke runs while a read waits or runs.
piece_bytes: [paint_model.FILE_HEADER_BYTES + paint_model.KEEP_PIECE_BYTES]u8
read_header: [paint_model.FILE_HEADER_BYTES]u8
picture: paint_model.Picture
history: paint_model.History

// The one picture memory of the draw tables: the drawing module reads the
// picture there.
picture_memories: [1][]graphics.Color
window_memory: interface.Window_Memory(512, 8192)

tool: paint_model.Tool
size_index := 2
color: graphics.Color = 0x202428
panel: Panel
// The last thing that happened that the status line says, or "".
message: string

drawn: i64 // The lines that calls drew since the last clear.

// The change of the picture that the pointer makes, from the press to the
// release.
drag: paint_model.Drag

// Where the canvas is in the window, from the last frame: a press inside it
// paints.
canvas_area: interface.Area
pointer_on_canvas: bool
pointer_x, pointer_y: int // On the picture.

// The store runs on the worker thread of the window: each call is a job
// (src/md/features/background_work.md). The client, the rows of a list, the
// names of a list, the file buffer and the request belong to the job from
// the ask to the take.
work: interface.Background_Work
process_context: ^system.Context
client: storage.Client
LIST_ROWS :: 64 // The rows of one page of a list.
// The pictures that the window lists: a store with more cannot take a new
// name, because a name past them could be taken.
PICTURE_LIST_CAPACITY :: 64
LIST_PAGES_LIMIT :: 1024 // The pages of one list: past them the list is not whole.
listed_rows: [LIST_ROWS]storage.Listed
listed_name_bytes: [LIST_ROWS * (paint_model.NAME_LIMIT + len(paint_model.OBJECT_SUFFIX))]u8
list_after: paint_model.Object_Name // The last object of a page: the next page starts after it.
job_names: [PICTURE_LIST_CAPACITY][paint_model.NAME_LIMIT]u8
job_name_counts: [PICTURE_LIST_CAPACITY]int

// The open picture: its name, and if the store holds an object of it. The
// store keeps it as it changes: no save action (src/md/features/
// paint_application.md, "No save action"). The keep is the state machine
// of the model: keep.rows holds the changed rows.
current_name: [paint_model.NAME_LIMIT]u8
current_name_count: int
keep: paint_model.Keep_State

Store_Act :: enum u8 {
	Open   = 0, // Open the store, then list it.
	Keep   = 1, // Write the header and the changed rows of the open picture, then commit.
	Read   = 2, // Read a picture.
	Rename = 3, // Rename the object of the open picture, then list.
	Delete = 4, // Remove a picture, then list.
	List   = 5, // List the pictures.
}

@(rodata)
STORE_ACT_NAMES := [Store_Act]string {
	.Open   = "open",
	.Keep   = "keep",
	.Read   = "read",
	.Rename = "rename",
	.Delete = "delete",
	.List   = "list",
}

// What the window asks of the store, and what the job gives back.
Store_Request :: struct {
	act:          Store_Act,
	name:         [paint_model.NAME_LIMIT]u8, // The picture of the act; Rename: the new name.
	name_count:   int,
	old_name:     [paint_model.NAME_LIMIT]u8, // Rename: the name before.
	old_count:    int,
	// Keep: one piece. The header is piece_bytes[:FILE_HEADER_BYTES], the
	// rows of the piece follow it.
	piece:        paint_model.Keep_Piece,
	size:         int, // The size of the object after the keep.
	band_rows:    int, // The rows of the whole keep, for its line of the log.
	// The results.
	opened:       bool, // Open: the store is open.
	act_failed:   bool, // The act failed: the log has the status of its call.
	listed:       bool, // A list ran to its end: the names of the job are the pictures of the store.
	listed_count: int, // The pictures of the list, at most PICTURE_LIST_CAPACITY.
	list_whole:   bool, // The store holds no picture past the list.
	newest:       int, // The picture of the list with the newest change, or -1.
	found:        bool, // Read: the object exists.
	file_count:   int, // Read: the bytes read.
}
store_request: Store_Request

// The name of the act that waits in the keep state.
pending_name: [paint_model.NAME_LIMIT]u8
pending_count: int

// The names of the pictures, copied from the names of the last list at the
// take: the window draws them while a new job writes its own.
picture_name_bytes: [PICTURE_LIST_CAPACITY][paint_model.NAME_LIMIT]u8
picture_names: [PICTURE_LIST_CAPACITY]string
picture_name_count: int
pictures_whole: bool // The last list held each picture of the store.
picture_choice: int
name_text: [paint_model.NAME_LIMIT]u8
name_count: int
hex_text: [7]u8
hex_count: int

// The key of each action of the window, in its action bar.
// A procedure, not a global array: an item is made by a call, and a
// freestanding process runs no call before its entry.
bar_items :: proc "contextless" () -> [4]interface.Action_Bar_Item {
	return {
		interface.action_bar_item("undo", 4, "Ctrl", "Z"),
		interface.action_bar_item("redo", 3, "Ctrl", "Shift", "Z"),
		interface.action_bar_item("pictures", 2, "Ctrl", "O"),
		interface.action_bar_item("clear", 1, "C"),
	}
}
bar: interface.Action_Bar_State

// line draws a line on the picture, with a color of the palette (0 to 15). A point off the picture is fine: the
// picture shows the part of the line on it.
//
// The line is 3 pixels wide. A coordinate beyond 4096 in either direction is taken as 4096: the picture is far
// smaller, so the visible part does not change. The line is not a step of undo.
//
// - **from_x**, **from_y**: the first point, in pixels of the picture (0, 0 is its top left corner).
// - **to_x**, **to_y**: the last point.
// - **color**: the number of a color of the palette, 0 to 15.
//
// The result is the count of lines that calls drew since the last clear. It fails with -1 and an error record:
// Bad_Value when the color is not 0 to 15; the record names the fifth argument.
//
// Example: paint.line(0, 0, 479, 295, 4) draws a red diagonal.
@(export, link_name = "line")
line :: proc "c" (from_x, from_y, to_x, to_y, color: i64, error: ^errors.Error_Record) -> i64 {
	if color < 0 || color >= paint_model.PALETTE_COUNT {
		return errors.fail(error, -1, .Bad_Value, .None, 5, color, paint_model.PALETTE_COUNT - 1)
	}
	limit :: paint_model.COORDINATE_LIMIT
	picture_changed_rows(paint_model.segment_draw(&picture, int(clamp(from_x, -limit, limit)), int(clamp(from_y, -limit, limit)), int(clamp(to_x, -limit, limit)), int(clamp(to_y, -limit, limit)), EXPORT_LINE_WIDTH, paint_model.PALETTE[color]))
	drawn += 1
	return drawn
}

// write draws a text on the picture, with a color of the palette (0 to 15).
//
// The text is drawn with the font of the system, from its top left corner. A text that passes the edge of the
// picture is cut there. The text is not a step of undo.
//
// - **x**: the left of the text, in the picture: 0 to its width less 1.
// - **y**: the top of the text, in the picture: 0 to its height less 1.
// - **text**: the bytes of the text.
// - **color**: the number of a color of the palette, 0 to 15.
//
// The result is the count of bytes of the text. It fails with -1 and an error record: Bad_Value when x or y is
// outside the picture, or when the color is not 0 to 15; the record names the argument.
@(export, link_name = "write")
write :: proc "c" (x, y: i64, text: ^string, color: i64, error: ^errors.Error_Record) -> i64 {
	switch {
	case x < 0 || x >= i64(picture.width):
		return errors.fail(error, -1, .Bad_Value, .None, 1, x, i64(picture.width) - 1)
	case y < 0 || y >= i64(picture.height):
		return errors.fail(error, -1, .Bad_Value, .None, 2, y, i64(picture.height) - 1)
	case color < 0 || color >= paint_model.PALETTE_COUNT:
		return errors.fail(error, -1, .Bad_Value, .None, 4, color, paint_model.PALETTE_COUNT - 1)
	}
	graphics.text(paint_model.picture_canvas(&picture), int(x), int(y), text^, paint_model.PALETTE[color])
	paint_model.picture_changed(&picture)
	// The rows of one line of the font of the system.
	picture_changed_rows(paint_model.box_cut(&picture, {0, int(y), picture.width, int(y) + graphics.LINE_HEIGHT}))
	return i64(len(text))
}

// clear erases the picture.
//
// It also sets the count of lines that [lines](paint.lines) gives back to 0. The key c in the window clears the
// picture too, as a step of undo. It has no parameter, no result, and never fails.
@(export, link_name = "clear")
clear :: proc "c" () {
	paint_model.picture_clear(&picture)
	picture_changed_rows({0, 0, picture.width, picture.height})
	drawn = 0
}

// lines gives the count of lines that calls drew since the last clear.
//
// Only the calls of [line](paint.line) count: the lines that the pointer draws do not. A test draws through
// calls, then reads this count to check that each call ran one time.
@(export, link_name = "lines")
lines :: proc "c" () -> i64 {
	return drawn
}
// change_begin keeps a copy of the picture before a change, for its step
// of undo.
change_begin :: proc "contextless" () {
	copy(backup_pixels[:], picture_pixels[:])
}

// change_end keeps the step of undo of the pixels that a change touched.
change_end :: proc "contextless" (changed: paint_model.Box) {
	picture_changed_rows(changed)
	switch paint_model.history_record(&history, backup_pixels[:], picture_pixels[:], changed, &history_scratch) {
	case .Kept, .Empty:
	case .Too_Large:
		message = "this change is too large to undo"
	}
}

// picture_clear_as_step clears the extent of the picture as a step of undo.
picture_clear_as_step :: proc "contextless" () {
	if !paint_model.picture_replace_allowed(&drag) {
		message = "finish the stroke first"
		return
	}
	if change_refused() {
		return
	}
	change_begin()
	paint_model.picture_clear(&picture)
	change_end({0, 0, picture.width, picture.height})
	drawn = 0
}

// undo and redo are refused during a drag: the drag holds the copy of
// the picture before its change, which an undo would make old.
undo :: proc "contextless" () {
	if !paint_model.picture_replace_allowed(&drag) {
		message = "finish the stroke first"
		return
	}
	if change_refused() {
		return
	}
	if !paint_model.history_can_undo(&history) {
		message = "nothing to undo"
		return
	}
	box := history.steps[history.done - 1].box
	message = paint_model.history_undo(&history, &picture, &history_scratch) ? "" : "this step of undo is damaged"
	picture_changed_rows(box)
}

redo :: proc "contextless" () {
	if !paint_model.picture_replace_allowed(&drag) {
		message = "finish the stroke first"
		return
	}
	if change_refused() {
		return
	}
	if !paint_model.history_can_redo(&history) {
		message = "nothing to redo"
		return
	}
	box := history.steps[history.done].box
	message = paint_model.history_redo(&history, &picture, &history_scratch) ? "" : "this step of redo is damaged"
	picture_changed_rows(box)
}

// store_job runs the request of the window on the worker thread: the
// calls of the store wait for the storage service.
store_job :: proc "contextless" (parameter: rawptr) {
	request := &store_request
	request.act_failed, request.listed = false, false
	room: paint_model.Object_Name
	object, valid := paint_model.object_name(&room, string(request.name[:request.name_count]))
	switch request.act {
	case .Open:
		opened: bool
		if client, opened = storage.open(process_context); !opened {
			system.log_fact(.Info, No_Store{})
			request.act_failed = true
			return
		}
		request.opened = true
		store_list(request, remove_partials = true)
	case .Keep:
		if !valid {
			request.act_failed = true
			return
		}
		// One piece: its rows, then with the last piece the header and the
		// size, then the commit, then the rename of a new picture
		// (src/md/features/paint_application.md, "Each committed state is
		// one whole picture").
		piece := request.piece
		target := object
		partial_room: paint_model.Object_Name
		if piece.object == .Partial {
			target, _ = paint_model.partial_object_name(&partial_room, string(request.name[:request.name_count]))
		}
		error: errors.Error_Record
		if piece.bytes > 0 {
			if _, status := storage.write_range(&client, storage.ROOT, target, u64(piece.offset), piece_bytes[paint_model.FILE_HEADER_BYTES:][:piece.bytes], &error); status != .Ok {
				store_failed(request, u64(status))
				return
			}
		}
		if piece.header {
			if _, status := storage.write_range(&client, storage.ROOT, target, 0, piece_bytes[:paint_model.FILE_HEADER_BYTES], &error); status != .Ok {
				store_failed(request, u64(status))
				return
			}
			if status := storage.set_size(&client, storage.ROOT, target, u64(piece.size), &error); status != .Ok {
				store_failed(request, u64(status))
				return
			}
		}
		if piece.commit {
			if _, status := storage.commit(&client, storage.ROOT, target, &error); status != .Ok {
				store_failed(request, u64(status))
				return
			}
		}
		if piece.rename {
			if _, status := storage.rename(&client, storage.ROOT, target, storage.ROOT, object, &error); status != .Ok {
				store_failed(request, u64(status))
				return
			}
		}
		if piece.last {
			system.log_fact(.Info, Picture_Kept{rows = u64(request.band_rows), bytes = u64(request.band_rows * paint_model.FILE_ROW_BYTES + paint_model.FILE_HEADER_BYTES), name = value_kinds.text_field(string(request.name[:request.name_count]), 40)})
		}
	case .Read:
		if !valid {
			request.act_failed = true
			return
		}
		// The size, then the object in pieces that fit the call region.
		size, status := storage.size(&client, storage.ROOT, object)
		if storage.export_failed_with(status, size, .Absent) {
			request.found = false
			return
		}
		if status != .Ok {
			store_failed(request, u64(status))
			return
		}
		// The header into its buffer, then the rows of its slot into the
		// memory of a picture. A header that the reader refuses, or an
		// object too short for its rows, gives no rows: the decode refuses
		// them, and the picture stays.
		request.found = true
		request.file_count = 0
		header, header_status := storage.read_range(&client, storage.ROOT, object, 0, read_header[:])
		if header_status != .Ok {
			store_failed(request, u64(header_status))
			return
		}
		if len(header) != paint_model.FILE_HEADER_BYTES {
			return
		}
		place, problem := paint_model.file_rows_of_header(header)
		if problem != .None || size < i64(place.offset + place.bytes) {
			request.file_count = paint_model.FILE_HEADER_BYTES
			return
		}
		rows := ([^]u8)(raw_data(backup_pixels[:]))[:place.bytes]
		read := 0
		for read < len(rows) {
			piece, piece_status := storage.read_range(&client, storage.ROOT, object, u64(place.offset + read), rows[read:min(read + paint_model.KEEP_PIECE_BYTES, len(rows))])
			if piece_status != .Ok {
				store_failed(request, u64(piece_status))
				return
			}
			if len(piece) == 0 {
				break
			}
			read += len(piece)
		}
		request.file_count = paint_model.FILE_HEADER_BYTES + read
	case .Rename:
		old_room: paint_model.Object_Name
		old_object, old_valid := paint_model.object_name(&old_room, string(request.old_name[:request.old_count]))
		if !valid || !old_valid {
			request.act_failed = true
			return
		}
		if _, status := storage.rename(&client, storage.ROOT, old_object, storage.ROOT, object); status != .Ok {
			store_failed(request, u64(status))
			return
		}
		store_list(request)
	case .Delete:
		if !valid {
			request.act_failed = true
			return
		}
		if _, status := storage.remove(&client, storage.ROOT, object); status != .Ok {
			store_failed(request, u64(status))
			return
		}
		store_list(request)
	case .List:
		store_list(request)
	}
}

// store_list lists each page of the store into the names of the job. A
// failed list leaves the names of the window as they were; the act before
// it stands. remove_partials: the open of the store removes each temporary
// object that a stop before its rename left; no keep runs before the open,
// so none is in use (src/md/features/paint_application.md, "Each committed
// state is one whole picture"). A remove that fails leaves the object,
// which the next open tries again.
store_list :: proc "contextless" (request: ^Store_Request, remove_partials := false) {
	request.listed_count, request.newest, request.list_whole = 0, -1, false
	newest_generation := i64(min(i64))
	after := ""
	for _ in 0 ..< LIST_PAGES_LIMIT {
		page, status := storage.list(&client, storage.ROOT, after, listed_rows[:], listed_name_bytes[:])
		if status != .Ok {
			system.log_fact(.Warning, Store_Call_Failed{status = u64(status), act = value_kinds.text_field("list", 16)})
			return
		}
		if len(page) == 0 {
			request.listed, request.list_whole = true, request.listed_count <= PICTURE_LIST_CAPACITY
			request.listed_count = min(request.listed_count, PICTURE_LIST_CAPACITY)
			return
		}
		last := ""
		for row in page {
			if row.name_offset < 0 || row.name_count < 0 || row.name_offset + row.name_count > i64(len(listed_name_bytes)) {
				continue
			}
			object := string(listed_name_bytes[row.name_offset:][:row.name_count])
			last = object
			if _, is_partial := paint_model.partial_name_of_object(object); is_partial && remove_partials {
				error: errors.Error_Record
				if _, remove_status := storage.remove(&client, storage.ROOT, object, &error); remove_status != .Ok {
					system.log_fact(.Warning, Store_Call_Failed{status = u64(remove_status), act = value_kinds.text_field("remove", 16)})
				}
				continue
			}
			name, is_picture := paint_model.picture_name_of_object(object)
			if !is_picture {
				continue
			}
			// One past the capacity says that the list is not whole.
			if request.listed_count < PICTURE_LIST_CAPACITY {
				job_name_counts[request.listed_count] = copy(job_names[request.listed_count][:], name)
				if row.generation > newest_generation {
					newest_generation, request.newest = row.generation, request.listed_count
				}
			}
			request.listed_count = min(request.listed_count + 1, PICTURE_LIST_CAPACITY + 1)
		}
		if last == "" || len(last) > len(list_after.bytes) {
			return
		}
		list_after.count = copy(list_after.bytes[:], last)
		after = string(list_after.bytes[:list_after.count])
	}
}

store_failed :: proc "contextless" (request: ^Store_Request, status: u64) {
	system.log_fact(.Warning, Store_Call_Failed{status = status, act = value_kinds.text_field(STORE_ACT_NAMES[request.act], 16)})
	request.act_failed = true
}

// store_ask gives the store a request: the caller checked that no job runs.
store_ask :: proc "contextless" (act: Store_Act, name: string) -> bool {
	store_request.act = act
	store_request.name_count = copy(store_request.name[:], name)
	return interface.background_work_ask(&work, store_job, nil)
}

current_picture_name :: proc "contextless" () -> string {
	return string(current_name[:current_name_count])
}

// picture_changed_rows adds the rows of a change of the picture to the
// band that the next keep writes.
picture_changed_rows :: proc "contextless" (box: paint_model.Box) {
	paint_model.changed_rows_add(&keep.rows, box, system.time())
}

// change_refused says if the picture must not change now, and says why:
// the first open is not taken yet, or a read of another picture runs; each
// would replace the change.
change_refused :: proc "contextless" () -> bool {
	if paint_model.change_allowed(&keep) {
		return false
	}
	message = keep.started ? "reading a picture: wait" : "the store opens: wait"
	return true
}

// keep_ask asks the job for the next piece of the keep of the open
// picture: a new keep takes the band of changed rows. The window copies the
// header and the rows of the piece into the buffer of the job.
keep_ask :: proc "contextless" () {
	if !keep.keeping {
		paint_model.keep_begin(&keep, picture.width, picture.height)
		store_request.band_rows = keep.keep_bottom - keep.keep_top
	}
	piece := paint_model.keep_piece(&keep)
	if piece.header {
		if _, ok := paint_model.file_header_write(keep.keep_width, keep.keep_height, keep.target_slot, piece_bytes[:]); !ok {
			keep.keeping = false
			return
		}
	}
	pixels := ([^]u8)(raw_data(picture_pixels[:]))[:paint_model.PICTURE_BYTES]
	copy(piece_bytes[paint_model.FILE_HEADER_BYTES:], pixels[piece.row:][:piece.bytes])
	store_request.piece = piece
	store_ask(.Keep, current_picture_name())
}

// store_drive asks for the job that the keep state gives: a keep, or the
// act that waits.
store_drive :: proc "contextless" (now: u64) {
	switch paint_model.keep_step(&keep, now, interface.background_work_busy(&work), drag.active) {
	case .Nothing:
		return
	case .Keep:
		keep_ask()
		return
	case .Pending:
	}
	name := string(pending_name[:pending_count])
	act := keep.pending
	paint_model.pending_started(&keep)
	switch act {
	case .None:
	case .Read:
		store_ask(.Read, name)
	case .New:
		// The open picture is kept: a new one starts, written at its first
		// change.
		picture_start_new(name)
		message = "new picture"
	case .Rename:
		if keep.written {
			store_request.old_count = copy(store_request.old_name[:], current_picture_name())
			store_ask(.Rename, name)
		} else {
			current_name_count = copy(current_name[:], name)
			message = "renamed"
		}
	case .Delete:
		store_ask(.Delete, name)
	}
}

// picture_start_new makes the picture of the window a new picture with a
// name: paper, the extent of the canvas, no history.
picture_start_new :: proc "contextless" (name: string) {
	paint_model.picture_clear(&picture)
	picture.width, picture.height = 0, 0
	paint_model.picture_extend(&picture, canvas_area.width, canvas_area.height)
	paint_model.history_clear(&history)
	current_name_count = copy(current_name[:], name)
	keep.written, keep.slot = false, 0
	keep.named = current_name_count > 0
	keep.rows = {}
	drawn = 0
}

// store_result_take reads the result of a job that is done, on the thread
// of the window. A picture that a job read waits for the end of a drag:
// the drag holds a copy of the picture that it changes.
store_result_take :: proc "contextless" (now: u64) {
	if interface.background_work_busy(&work) && store_request.act == .Read && !paint_model.picture_replace_allowed(&drag) {
		return
	}
	if !interface.background_work_take(&work) {
		return
	}
	request := &store_request
	switch request.act {
	case .Open:
		// The first open is taken: the picture may change from now, except
		// while the read of the newest picture waits or runs.
		keep.started = true
		keep.store_open = request.opened && request.listed
		pictures_copy(request)
		if !keep.store_open {
			if request.opened {
				message = "the store did not list its pictures: nothing is kept"
			}
			return
		}
		// The start opens the picture with the newest change, or starts a
		// new one with the first free name.
		if request.newest >= 0 {
			name := picture_names[request.newest]
			pending_count = copy(pending_name[:], name)
			paint_model.pending_ask(&keep, .Read)
			return
		}
		name_take_first_free()
	case .Keep:
		if request.act_failed {
			// The rows go back to the band; the act that waited is dropped:
			// the store refused, and a try at once would fail the same way.
			dropped := paint_model.keep_refused(&keep, now, picture.height)
			message = dropped == .None ? "the store refused to keep the picture: it tries again" : "the store refused to keep the picture: the act of the panel is dropped"
		} else {
			paint_model.keep_piece_written(&keep, request.piece)
		}
	case .Read:
		paint_model.read_taken(&keep)
		picture_decode_taken(request)
	case .Rename:
		if !request.act_failed {
			current_name_count = copy(current_name[:], string(request.name[:request.name_count]))
			message = "renamed"
		} else {
			message = "the store refused the name"
		}
		pictures_copy(request)
	case .Delete:
		message = request.act_failed ? "the store refused the delete" : "deleted"
		pictures_copy(request)
	case .List:
		pictures_copy(request)
	}
}

// name_take_first_free names a new picture with the first free name of a
// whole list. A list that is not whole names nothing, and the status says
// that the picture is not kept.
name_take_first_free :: proc "contextless" () {
	room: [paint_model.NAME_LIMIT]u8
	name, ok := paint_model.first_free_name(picture_names[:picture_name_count], &room)
	if !ok || !pictures_whole {
		message = "no free name: this picture is not kept"
		keep.named = false
		return
	}
	current_name_count = copy(current_name[:], name)
	keep.named = true
}

// pictures_copy keeps the names of the pictures of the last list.
pictures_copy :: proc "contextless" (request: ^Store_Request) {
	if !request.listed {
		return
	}
	picture_name_count = clamp(request.listed_count, 0, PICTURE_LIST_CAPACITY)
	for index in 0 ..< picture_name_count {
		count := copy(picture_name_bytes[index][:], job_names[index][:job_name_counts[index]])
		picture_names[index] = string(picture_name_bytes[index][:count])
	}
	pictures_whole = request.list_whole
	picture_choice = clamp(picture_choice, 0, max(picture_name_count - 1, 0))
}

// picture_listed says if the last list holds a name.
picture_listed :: proc "contextless" (name: string) -> bool {
	for listed in picture_names[:picture_name_count] {
		if listed == name {
			return true
		}
	}
	return false
}

// panel_act asks for an act of the panel: it waits for the keep of the open
// picture and for the job that runs. The name of the field gives a new
// picture or a new name; the list gives a picture to open or to delete.
panel_act :: proc "contextless" (act: paint_model.Store_Pending, name: string) {
	switch act {
	case .None:
		return
	case .New, .Rename:
		switch paint_model.name_check(name) {
		case .None:
		case .Empty:
			message = "a name has at least one character"
			return
		case .Too_Long:
			message = "a name has at most 32 characters"
			return
		case .Bad_Character:
			message = "a name has a-z, 0-9, - and _ only"
			return
		}
		if !pictures_whole {
			message = "the store holds more than 64 pictures: delete some first"
			return
		}
		if picture_listed(name) || name == current_picture_name() {
			message = "a picture has this name"
			return
		}
	case .Read:
		if name == current_picture_name() {
			message = "this picture is open"
			return
		}
	case .Delete:
		if name == current_picture_name() {
			message = "the open picture cannot be deleted"
			return
		}
	}
	if !keep.store_open {
		message = "no store: nothing is kept"
		return
	}
	if !paint_model.pending_ask(&keep, act) {
		message = "an act of the panel waits already"
		return
	}
	pending_count = copy(pending_name[:], name)
	message = act != .Delete && (keep.rows.changed || interface.background_work_busy(&work)) ? "waits for the keep" : ""
}

// picture_decode_taken decodes the file that a job read. A damaged file
// leaves the picture as it was.
picture_decode_taken :: proc "contextless" (request: ^Store_Request) {
	name := string(request.name[:request.name_count])
	if request.act_failed || !request.found {
		message = "the store has no such picture"
		if current_name_count == 0 {
			name_take_first_free()
		}
		return
	}
	rows := ([^]u8)(raw_data(backup_pixels[:]))[:max(request.file_count - paint_model.FILE_HEADER_BYTES, 0)]
	header := read_header[:request.file_count >= paint_model.FILE_HEADER_BYTES ? paint_model.FILE_HEADER_BYTES : 0]
	if problem := paint_model.picture_decode_parts(header, rows, &picture); problem != .None {
		system.log_fact(.Warning, Picture_Refused{problem = u64(problem), name = value_kinds.text_field(name, 40)})
		message = "the file of this picture is damaged"
		if current_name_count == 0 {
			name_take_first_free()
		}
		return
	}
	paint_model.history_clear(&history)
	current_name_count = copy(current_name[:], name)
	keep.written, keep.slot = true, paint_model.file_slot_of_header(read_header[:])
	keep.named = true
	keep.rows = {}
	// The picture holds at least the canvas: the rest is paper, which the
	// next keep writes.
	height_before := picture.height
	if paint_model.picture_extend(&picture, canvas_area.width, canvas_area.height) {
		paint_model.changed_rows_add(&keep.rows, {0, height_before, picture.width, picture.height}, system.time())
	}
	// The count of the pixels that are not paper: a machine test checks
	// that the drawing came back, after a stop of the process.
	drawn_pixels: u64
	for row in 0 ..< picture.height {
		for pixel in picture.pixels[row * paint_model.PICTURE_WIDTH_LIMIT:][:picture.width] {
			drawn_pixels += pixel != paint_model.COLOR_PAPER ? 1 : 0
		}
	}
	if drawn_pixels > 0 {
		system.log_fact(.Info, Picture_Opened{width = u64(picture.width), height = u64(picture.height), drawn_pixels = drawn_pixels, name = value_kinds.text_field(name, 40)})
	} else {
		system.log_fact(.Info, Picture_Opened_Blank{width = u64(picture.width), height = u64(picture.height), name = value_kinds.text_field(name, 40)})
	}
	message = "opened"
}

// panel_toggle opens a panel, or closes it when it is open.
panel_toggle :: proc "contextless" (wanted: Panel) {
	panel = panel == wanted ? .None : wanted
	if panel == .Pictures && keep.store_open && !interface.background_work_busy(&work) {
		store_ask(.List, "")
	}
	if panel == .Color {
		room: paint_model.Color_Text
		copy(hex_text[:], paint_model.color_text(&room, color))
		hex_count = len(hex_text)
	}
}

// key_run runs one key that no element took: a typed key, or the key of
// the item of the action bar that a press ran.
key_run :: proc "contextless" (press: interface.Key_Press) {
	control := press.modifiers & display.MODIFIER_CONTROL != 0
	shift := press.modifiers & display.MODIFIER_SHIFT != 0
	if control {
		switch press.character {
		case 'z', 'Z':
			if shift {
				redo()
			} else {
				undo()
			}
		case 'y', 'Y':
			redo()
		case 'o', 'O':
			panel_toggle(.Pictures)
		}
		return
	}
	if press.code == display.KEY_ESCAPE {
		panel = .None
		return
	}
	switch press.character {
	case 'b', 'B':
		tool = .Brush
	case 'e', 'E':
		tool = .Eraser
	case 'l', 'L':
		tool = .Line
	case 'r', 'R':
		tool = .Rectangle
	case 'o', 'O':
		tool = .Ellipse
	case 'f', 'F':
		tool = .Fill
	case '[':
		size_index = paint_model.size_index_step(size_index, -1)
	case ']':
		size_index = paint_model.size_index_step(size_index, 1)
	case 'c', 'C':
		picture_clear_as_step()
	}
}

// button_fitted draws a button as wide as its label and gives the x after
// it, and if it was activated.
button_fitted :: proc "contextless" (frame: ^interface.Frame, x, y: int, label: string, chosen := false) -> (next_x: int, activated: bool) {
	width := interface.text_measured_width(frame.table, interface.FONT_INTERFACE, label) + 16
	toggle := chosen ? accessibility.Toggle_State.True : accessibility.Toggle_State.None
	activated = interface.button(frame, {x, y, width, ROW_HEIGHT}, interface.identity(label), label, chosen, toggle).activated
	return x + width + GAP, activated
}

// tools_row draws the buttons of the tools and of the size.
tools_row :: proc "contextless" (frame: ^interface.Frame) {
	x := GAP
	for name, each in paint_model.TOOL_NAMES {
		activated: bool
		x, activated = button_fitted(frame, x, GAP, name, each == tool)
		if activated {
			tool = each
		}
	}
	x += 2 * GAP
	activated: bool
	x, activated = button_fitted(frame, x, GAP, "smaller")
	if activated {
		size_index = paint_model.size_index_step(size_index, -1)
	}
	x, activated = button_fitted(frame, x, GAP, "larger")
	if activated {
		size_index = paint_model.size_index_step(size_index, 1)
	}
}

// palette_row draws the cells of the palette and the button of the custom
// color. The chosen color has a frame of the strong text color.
palette_row :: proc "contextless" (frame: ^interface.Frame) {
	x := GAP
	for each, index in paint_model.PALETTE {
		area := interface.Area{x, PALETTE_TOP, PALETTE_CELL, PALETTE_CELL}
		element := interface.identity_with(interface.identity("palette"), index)
		result := interface.element_interact(frame, element, area, .Button)
		interface.element_name(frame, area, paint_model.PALETTE_NAMES[index])
		interface.draw_rectangle(frame.table, x, PALETTE_TOP, PALETTE_CELL, PALETTE_CELL, each)
		if each == color {
			interface.draw_outline(frame.table, x, PALETTE_TOP, PALETTE_CELL, PALETTE_CELL, 3, graphics.colors.text_strong)
			interface.draw_outline(frame.table, x + 3, PALETTE_TOP + 3, PALETTE_CELL - 6, PALETTE_CELL - 6, 1, graphics.colors.background)
		}
		if result.focused {
			interface.draw_focus_ring(frame.table, area, u32(element))
		}
		if result.activated {
			color = each
		}
		x += PALETTE_CELL + 2
	}
	x += 2 * GAP
	// The custom color: a cell of the color when it is no color of the
	// palette, and the button of the panel.
	in_palette := false
	for each in paint_model.PALETTE {
		in_palette ||= each == color
	}
	if !in_palette {
		interface.draw_rectangle(frame.table, x, PALETTE_TOP, PALETTE_CELL, PALETTE_CELL, color)
		interface.draw_outline(frame.table, x, PALETTE_TOP, PALETTE_CELL, PALETTE_CELL, 3, graphics.colors.text_strong)
		x += PALETTE_CELL + GAP
	}
	width := interface.text_measured_width(frame.table, interface.FONT_INTERFACE, "custom color") + 16
	if interface.button(frame, {x, PALETTE_TOP, width, PALETTE_CELL}, interface.identity("custom color"), "custom color", panel == .Color).activated {
		panel_toggle(.Color)
	}
}
@(rodata)
CHANNEL_NAMES := [paint_model.Channel]string {
	.Red   = "red",
	.Green = "green",
	.Blue  = "blue",
}

// color_panel draws the custom color: a sample, three channels each with
// a bar that a press sets and two steps, and the field of the hexadecimal
// form.
color_panel :: proc "contextless" (frame: ^interface.Frame, area: interface.Area) {
	x, y := area.x, area.y
	interface.draw_rectangle(frame.table, x, y, area.width, 40, color)
	interface.draw_outline(frame.table, x, y, area.width, 40, 1, graphics.colors.track)
	y += 40 + 2 * GAP
	STEP_WIDTH :: 44
	LABEL_WIDTH :: 48
	for name, channel in CHANNEL_NAMES {
		value := paint_model.channel_value(color, channel)
		interface.cell_text(frame, {x, y, LABEL_WIDTH, ROW_HEIGHT}, name, graphics.colors.dim)
		row_x := x + LABEL_WIDTH
		parent := interface.identity(name)
		if interface.button(frame, {row_x, y, STEP_WIDTH, ROW_HEIGHT}, interface.identity_in(parent, "less"), "-16").activated {
			color = paint_model.channel_step(color, channel, -16)
		}
		bar := interface.Area{row_x + STEP_WIDTH + GAP, y + 6, area.width - LABEL_WIDTH - 2 * (STEP_WIDTH + GAP), ROW_HEIGHT - 12}
		element := interface.identity_in(parent, "bar")
		result := interface.element_interact(frame, element, bar, .Button)
		interface.element_name(frame, bar, name)
		// A press on the bar, and a drag that started on it, set the value
		// from the place of the pointer.
		if frame.state.pressed == element && frame.input.button_held || result.activated {
			place := clamp(frame.input.pointer_x - bar.x, 0, max(bar.width - 1, 1))
			color = paint_model.channel_set(color, channel, u8(place * 255 / max(bar.width - 1, 1)))
			value = paint_model.channel_value(color, channel)
		}
		interface.draw_rectangle(frame.table, bar.x, bar.y, bar.width, bar.height, graphics.colors.track)
		interface.draw_rectangle(frame.table, bar.x, bar.y, int(value) * bar.width / 255, bar.height, paint_model.channel_set(0, channel, 255))
		if result.focused {
			interface.draw_focus_ring(frame.table, bar, u32(element))
		}
		if interface.button(frame, {bar.x + bar.width + GAP, y, STEP_WIDTH, ROW_HEIGHT}, interface.identity_in(parent, "more"), "+16").activated {
			color = paint_model.channel_step(color, channel, 16)
		}
		y += ROW_HEIGHT + GAP
	}
	y += GAP
	field := interface.Area{x, y, area.width - 80 - GAP, ROW_HEIGHT}
	entered := interface.text_input(frame, field, interface.identity("color text"), hex_text[:], &hex_count, "#RRGGBB").activated
	if interface.button(frame, {field.x + field.width + GAP, y, 80, ROW_HEIGHT}, interface.identity("apply"), "apply").activated || entered {
		if parsed, ok := paint_model.color_of_text(string(hex_text[:hex_count])); ok {
			color = parsed
			message = ""
		} else {
			message = "a color is #RRGGBB"
		}
	}
}

// pictures_panel draws the field of a name with the buttons new and
// rename, the list of the pictures of the store, and the buttons open and
// delete. No button saves: the store keeps the open picture as it changes.
pictures_panel :: proc "contextless" (frame: ^interface.Frame, area: interface.Area) {
	x, y := area.x, area.y
	if !keep.store_open {
		opening := interface.background_work_busy(&work) && store_request.act == .Open
		interface.cell_text(frame, {x, y, area.width, ROW_HEIGHT}, opening ? "the store opens" : "no store: nothing is kept", graphics.colors.dim)
		return
	}
	BUTTON_WIDTH :: 72
	field := interface.Area{x, y, area.width - 2 * (BUTTON_WIDTH + GAP), ROW_HEIGHT}
	interface.text_input(frame, field, interface.identity("picture name"), name_text[:], &name_count, "name")
	name := string(name_text[:name_count])
	if interface.button(frame, {field.x + field.width + GAP, y, BUTTON_WIDTH, ROW_HEIGHT}, interface.identity("new"), "new").activated {
		panel_act(.New, name)
	}
	if interface.button(frame, {field.x + field.width + 2 * GAP + BUTTON_WIDTH, y, BUTTON_WIDTH, ROW_HEIGHT}, interface.identity("rename"), "rename").activated {
		panel_act(.Rename, name)
	}
	y += ROW_HEIGHT + 2 * GAP
	list := interface.Area{x, y, area.width, max(area.y + area.height - y - ROW_HEIGHT - 2 * GAP, interface.TABLE_LINE)}
	chosen := interface.list_with_choice(frame, list, interface.identity("pictures"), picture_names[:picture_name_count], &picture_choice, {empty_text = "no picture in the store", name = "pictures"}).activated
	y = list.y + list.height + 2 * GAP
	if picture_name_count == 0 {
		return
	}
	chosen_name := picture_names[clamp(picture_choice, 0, picture_name_count - 1)]
	if interface.button(frame, {x, y, BUTTON_WIDTH, ROW_HEIGHT}, interface.identity("open"), "open").activated || chosen {
		panel_act(.Read, chosen_name)
	}
	if interface.button(frame, {x + BUTTON_WIDTH + GAP, y, BUTTON_WIDTH, ROW_HEIGHT}, interface.identity("delete"), "delete").activated {
		panel_act(.Delete, chosen_name)
	}
}

// The color of the change in progress: the paper for the eraser and for
// the right button.
drag_color :: proc "contextless" (paper: bool) -> graphics.Color {
	return paper || tool == .Eraser ? paint_model.COLOR_PAPER : color
}

ELLIPSE_PREVIEW_POINTS :: 64

// preview_draw draws the shape in progress over the picture, as records:
// the picture changes at the release only.
preview_draw :: proc "contextless" (frame: ^interface.Frame) {
	if !drag.active || tool == .Brush || tool == .Eraser || tool == .Fill {
		return
	}
	size := paint_model.BRUSH_SIZES[size_index]
	shown := drag_color(drag.paper)
	origin_x, origin_y := canvas_area.x, canvas_area.y
	interface.draw_clip_push(frame.table, canvas_area.x, canvas_area.y, canvas_area.width, canvas_area.height)
	defer interface.draw_clip_pop(frame.table)
	box := paint_model.shape_box(drag.from_x, drag.from_y, drag.last_x, drag.last_y)
	width, height := box.right - box.left, box.bottom - box.top
	switch tool {
	case .Brush, .Eraser, .Fill:
		// No preview: the change is in the picture.
	case .Line:
		interface.draw_line(frame.table, origin_x + drag.from_x, origin_y + drag.from_y, origin_x + drag.last_x, origin_y + drag.last_y, size, shown)
	case .Rectangle:
		interface.draw_outline(frame.table, origin_x + box.left, origin_y + box.top, width, height, clamp(size, 1, max(min(width, height), 1)), shown)
	case .Ellipse:
		// A path of points around the ellipse, at angles in turns; the
		// stroke is inside the box, as the drawn ellipse is.
		UNITS :: draw_record.UNITS_PER_PIXEL
		thickness := f64(min(size, max(min(width, height) / 2, 1)))
		center_x := f64(origin_x) + f64(box.left + box.right) / 2
		center_y := f64(origin_y) + f64(box.top + box.bottom) / 2
		radius_x := max(f64(width) / 2 - thickness / 2, 0.5)
		radius_y := max(f64(height) / 2 - thickness / 2, 0.5)
		points: [ELLIPSE_PREVIEW_POINTS + 1]interface.Path_Point
		for index in 0 ..< ELLIPSE_PREVIEW_POINTS {
			angle_turns := f64(index) / ELLIPSE_PREVIEW_POINTS
			points[index] = {
				command = index == 0 ? .Move : .Line,
				x = i32((center_x + radius_x * trigonometry.cosine(angle_turns)) * UNITS),
				y = i32((center_y + radius_y * trigonometry.sine(angle_turns)) * UNITS),
			}
		}
		points[ELLIPSE_PREVIEW_POINTS] = {command = .Close}
		interface.draw_path(frame.table, points[:], 0, draw_record.opaque(shown), i32(thickness * UNITS))
	}
}

// status_text writes the status line: the name of the open picture, the
// tool, the size, the color, the place of the pointer on the picture, and
// the last message.
status_text :: proc "contextless" (builder: ^interface.Text_Builder) -> string {
	builder.count = 0
	if current_name_count > 0 {
		interface.text_put(builder, current_picture_name())
		interface.text_put(builder, ", ")
	}
	interface.text_put(builder, paint_model.TOOL_NAMES[tool])
	interface.text_put(builder, ", ")
	interface.text_put_number(builder, u64(paint_model.BRUSH_SIZES[size_index]))
	interface.text_put(builder, " px, ")
	room: paint_model.Color_Text
	interface.text_put(builder, paint_model.color_text(&room, color))
	if pointer_on_canvas {
		interface.text_put(builder, ", x ")
		interface.text_put_number(builder, u64(max(pointer_x, 0)))
		interface.text_put(builder, " y ")
		interface.text_put_number(builder, u64(max(pointer_y, 0)))
	}
	if message != "" {
		interface.text_put(builder, " | ")
		interface.text_put(builder, message)
	}
	return interface.text_of(builder)
}

// frame_build builds one frame of the window, runs the keys that no
// element took, and gives the result of the action bar.
frame_build :: proc "contextless" (window: ^display.Window) -> (bar_result: interface.Action_Bar_Result) {
	frame := interface.window_frame_start(&window_memory, window)
	interface.action_bar_input_take(&frame, &bar)
	width, height := window.width, window.height
	interface.background(&frame, {0, 0, width, height})
	panel_room := panel != .None ? PANEL_WIDTH + 2 * GAP : 0
	canvas_area = {0, CANVAS_TOP, max(width - panel_room, 1), max(height - CANVAS_TOP - STATUS_HEIGHT, 1)}
	// A larger window grows the picture; a smaller one keeps it. A growth
	// is a change that the next keep writes: the new rows, and the header.
	width_before, height_before := picture.width, picture.height
	if paint_model.picture_extend(&picture, canvas_area.width, canvas_area.height) {
		picture_changed_rows({0, height_before, picture.width, picture.height})
		if picture.height == height_before && picture.width != width_before {
			paint_model.changed_rows_mark(&keep.rows, system.time())
		}
	}
	tools_row(&frame)
	palette_row(&frame)
	shown := graphics.Canvas{pixels = raw_data(picture_pixels[:]), width = min(picture.width, canvas_area.width), height = min(picture.height, canvas_area.height), stride = paint_model.PICTURE_WIDTH_LIMIT}
	interface.draw_picture(frame.table, canvas_area.x, canvas_area.y, shown, picture.generation)
	interface.element_name(&frame, canvas_area, "canvas")
	preview_draw(&frame)
	panel_area := interface.Area{canvas_area.width + GAP, CANVAS_TOP + GAP, PANEL_WIDTH, canvas_area.height - 2 * GAP}
	switch panel {
	case .None:
	case .Pictures:
		pictures_panel(&frame, panel_area)
	case .Color:
		color_panel(&frame, panel_area)
	}
	// The status line, and the action bar of the keys at its right
	// (docs/INTERFACE.md, "4.4 The action bar").
	status_y := height - STATUS_HEIGHT
	builder: interface.Text_Builder
	text_right := interface.draw_text(frame.table, GAP, status_y + (STATUS_HEIGHT - interface.LINE) / 2, status_text(&builder), graphics.colors.dim)
	bar_left := text_right + 16
	items := bar_items()
	bar_result = interface.action_bar(&frame, {bar_left, status_y, max(width - bar_left, 0), STATUS_HEIGHT}, items[:], &bar, {alignment = .Right})
	for {
		press := interface.key_take(&frame) or_break
		outcome := interface.action_bar_key(&bar, press)
		if outcome.ran {
			key_run(outcome.run)
		}
		if !outcome.taken {
			key_run(press)
		}
	}
	interface.window_frame_end(&window_memory.drawing, &frame, window)
	return bar_result
}

// The buttons of the last pointer event: a press is a change from none.
buttons_before: u32

// pointer_paint runs a pointer event on the picture: a press on the canvas
// starts a change, a move continues it, a release ends it and keeps its
// step of undo.
pointer_paint :: proc "contextless" (event: display.Event) {
	x, y := event.x - canvas_area.x, event.y - canvas_area.y
	pointer_on_canvas = interface.area_contains(canvas_area, event.x, event.y)
	pointer_x, pointer_y = x, y
	buttons := event.buttons & (display.BUTTON_LEFT | display.BUTTON_RIGHT)
	pressed_now := buttons != 0 && buttons_before == 0
	buttons_before = buttons
	size := paint_model.BRUSH_SIZES[size_index]
	if drag.active {
		shown := drag_color(drag.paper)
		if tool == .Brush || tool == .Eraser {
			drag.changed = paint_model.box_union(drag.changed, paint_model.segment_draw(&picture, drag.last_x, drag.last_y, x, y, size, shown))
		}
		drag.last_x, drag.last_y = x, y
		if buttons != 0 {
			return
		}
		// The release ends the change.
		changed := drag.changed
		switch tool {
		case .Brush, .Eraser, .Fill:
			// The segments are in the picture already.
		case .Line:
			changed = paint_model.segment_draw(&picture, drag.from_x, drag.from_y, x, y, size, shown)
		case .Rectangle:
			changed = paint_model.rectangle_draw(&picture, drag.from_x, drag.from_y, x, y, size, shown)
		case .Ellipse:
			changed = paint_model.ellipse_draw(&picture, drag.from_x, drag.from_y, x, y, size, shown)
		}
		drag.active = false
		change_end(changed)
		return
	}
	if !pressed_now || !pointer_on_canvas || interface.action_bar_takes_pointer(&bar, event.x, event.y) {
		return
	}
	if change_refused() {
		return
	}
	message = ""
	paper := event.buttons & display.BUTTON_RIGHT != 0
	change_begin()
	switch tool {
	case .Fill:
		change_end(paint_model.fill_region(&picture, x, y, drag_color(paper), &fill_memory))
	case .Brush, .Eraser:
		drag = {active = true, paper = paper, from_x = x, from_y = y, last_x = x, last_y = y}
		drag.changed = paint_model.segment_draw(&picture, x, y, x, y, size, drag_color(paper))
	case .Line, .Rectangle, .Ellipse:
		drag = {active = true, paper = paper, from_x = x, from_y = y, last_x = x, last_y = y}
	}
}

// events_take takes the events of the window: the pointer paints, and each
// event goes to the input of the next frame, as interface.window_events
// does, until the input has no room for a key.
events_take :: proc "contextless" (window: ^display.Window) {
	drawing := &window_memory.drawing
	for interface.input_has_room(&drawing.input) {
		event := display.next_event(window) or_break
		switch event.kind {
		case .Pointer:
			pointer_paint(event)
			interface.input_add(&drawing.input, event)
		case .Key:
			interface.input_add(&drawing.input, event)
		case .Resized:
			// The surface of the new size has no picture known: the next
			// frame draws it whole. A refused surface keeps the old one.
			if display.surface_resize(window, event.width, event.height) == .Ok {
				interface.draw_whole_window_next(drawing)
			}
		case .Settings_Changed, .Surface_Answer:
			interface.draw_whole_window_next(drawing)
		case .Copy_Asked:
			drawing.input.copy_asked = true
		case .Pasted:
			// A newer paste: the compositor ended the lend of the one
			// before, which no frame took.
			if drawing.input.paste.kind == .Pasted {
				display.paste_refuse(window, drawing.input.paste)
			}
			drawing.input.paste, drawing.input.paste_window = event, window
		case .None, .Go_To, .Capture_Size, .Capture_Frame, .Capture_Disconnect, .Work_Area:
			// next_event never gives None, and this window does nothing for the other events.
		}
	}
}

// The entry of paint: it opens its service, its window and its store, then
// runs the calls and the events in one loop until the principal closes the
// window.
//
// With no window it stops with Failed. Each turn draws a frame, then waits
// for an event or a call. The calls run first, then the events.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	service, _ := system.service_open(ctx)
	window, ok := display.open(ctx, WIDTH, HEIGHT, "paint")
	if !ok {
		system.stop(.Failed)
	}
	if problem, sent := display.resizable_set(&window, {least_width = LEAST_WIDTH, least_height = LEAST_HEIGHT, largest_width = LARGEST_WIDTH, largest_height = LARGEST_HEIGHT}); problem != .None {
		system.log_fact(.Info, Window_Stays_Fixed{cause = value_kinds.text_field(display.SIZE_LIMITS_PROBLEM_SENTENCES[problem], 64)})
	} else if !sent {
		system.log_fact(.Info, Window_Stays_Fixed{cause = value_kinds.text_field("the command ring of the window is full", 64)})
	}
	picture = {pixels = picture_pixels[:]}
	history.arena = history_arena[:]
	paint_model.picture_clear(&picture)
	paint_model.picture_extend(&picture, WIDTH, HEIGHT - CANVAS_TOP - STATUS_HEIGHT)
	picture_memories[0] = picture_pixels[:]
	window_memory.drawing.now.picture_memories = picture_memories[:]
	window_memory.drawing.before.picture_memories = picture_memories[:]
	// The store opens on the worker thread: the window draws at once.
	process_context = ctx
	if interface.background_work_start(&work) == .Ok {
		store_ask(.Open, "")
	} else {
		// No worker, so no open will be taken: the picture may change from
		// now, and nothing is kept.
		keep.started = true
		message = "no worker thread: nothing is kept"
		system.log_fact(.Info, No_Store{})
	}
	system.log_fact(.Info, Running{})
	for {
		now := system.time()
		store_result_take(now)
		store_drive(now)
		bar_result := frame_build(&window)
		if bar_result.ran {
			key_run(bar_result.run)
			continue
		}
		wait: system.Wait
		display.wait_events(&wait, &window)
		// The calls of the console change the picture: while it must not
		// change, they wait in their ring, and the loop does not wake for
		// them.
		if paint_model.change_allowed(&keep) {
			system.service_wait(&wait, &service)
		}
		// A read that waits for the end of a drag is no reason to wake:
		// the release of the pointer wakes the loop.
		ready := interface.background_work_wait(&wait, &work) && !(store_request.act == .Read && drag.active)
		// The keep of the picture is due after the pause of its changes:
		// the loop wakes for it only when a turn can then ask for it.
		deadline := system.WAIT_FOREVER
		if time, due := paint_model.keep_wake(&keep, interface.background_work_busy(&work)); due {
			deadline = time
		}
		system.wait_end(&wait, ready ? system.time() : deadline)
		// The calls of the console change the picture: they wait in their
		// ring while a read of another picture would replace it.
		if paint_model.change_allowed(&keep) {
			system.service_run(&service)
		}
		events_take(&window)
	}
}
