package interface

import "modus:contract/draw_record"
import "modus:contract/errors"
import "modus:support/display"
import "modus:support/graphics"
import "modus:support/system"

// A module built with this setting draws its window through the drawing
// module (docs/INTERFACE.md, section 7): window_frame_end calls the two
// exports of the module in place of the difference and the execution of
// this package, so the module holds no copy of that code. The modus tool
// sets it for each module that imports the drawing module (the module table,
// tools/modustool/foundation/module_table.odin).
//
// A window of such a process has at most one picture memory: a call of
// the module takes one. A frame with more than one is refused
// (frame_draw). A grid is in the text table, so the module draws it. The
// compositor, which shows many picture memories, calls
// draw_part_through_module once for each part of its screen, with the
// damage rectangles of its frame.
DRAWING_THROUGH_MODULE :: #config(DRAWING_THROUGH_MODULE, false)

// What a process keeps to draw its window with the package, in its own
// memory: the table of the frame that it builds, the table of the frame on
// its surface, the interface state and the input of the next frame.
Window_Drawing :: struct {
	now:    Draw_Table, // The table of the frame that the process builds.
	before: Draw_Table, // The table of the last frame that the window presented. Empty before the first frame.
	// The surface has two pictures: the process draws in one while the
	// compositor shows the other, so each picture holds an older frame.
	// What each picture owes against the table before.
	debts:  Picture_Debts,
	state:  Interface_State, // The focus and the element under the pointer, from frame to frame.
	input:  Input, // The input of the next frame.
	drawn:  bool, // The table before is the last frame that the window presented.
	// The last frame was left out: the compositor did not take the picture
	// before it (display.canvas_wait). The next frame draws what it built.
	late:   bool,
	// The measures of the last frame, in nanoseconds.
	build_time, difference_time, draw_time: u64,
	build_start: u64, // When the frame that is built now started.
	damage: Damage, // The damage of the last frame.
	// A process that draws through the drawing module: the calls of an
	// export of the module since the start (for a frame with damage, one
	// for the difference and one for the draw of all its rectangles), and
	// the error record of the last call that the module refused, which the
	// one line of the log of a refusal reads (module_refusal_log). A
	// process whose module has the package compiled in keeps the three zero.
	module_calls: u64,
	module_error: errors.Error_Record,
	module_refusal_logged: bool, // The line of a refusal is on the log: a window writes it one time.
	// The set of the act names that the compositor has from this window, as
	// hashes in the order of their frame. A frame sends its set only when it
	// differs (act_names_offer).
	act_names_sent:       [display.ACT_NAME_SET_CAPACITY]u64,
	act_names_sent_count: int,
	act_names_sent_once:  bool, // A set went to the compositor: before it, the compositor has none.
	act_names_dropped_logged: bool, // The line of a frame with act names that it did not keep is on the log: a window writes it one time.
	// The named elements that the log has from this window: a drawn frame
	// writes the lines of what differs (element_places_publish).
	element_places_written: Element_Places,
	element_places_dropped_logged: bool, // The line of a frame with element names that it did not keep is on the log: a window writes it one time.
	// The appearance of the last frame that the window presented, so that
	// the first frame of a new appearance writes one line
	// (appearance_presented_note).
	appearance_presented:       graphics.Appearance,
	appearance_presented_known: bool,
}

// appearance_presented_note writes one line when the window presents its
// first frame in an appearance other than the one of its frame before: a
// machine test waits for it before it takes a picture of the window in the
// new appearance. The first frame of a window writes nothing.
appearance_presented_note :: proc "contextless" (drawing: ^Window_Drawing, window: ^display.Window) {
	if drawing.appearance_presented_known && drawing.appearance_presented != graphics.appearance {
		system.log(.Info, "interface: ", string(window.title[:window.title_count]), ": a frame in the ", graphics.appearance == .Light ? "light" : "dark", " appearance")
	}
	drawing.appearance_presented, drawing.appearance_presented_known = graphics.appearance, true
}

// element_places_write writes on the log the element places of a frame
// that the window draws, when they changed: a machine test presses an
// element by its name from these lines.
@(private = "file")
element_places_write :: proc "contextless" (drawing: ^Window_Drawing, frame: ^Frame, window: ^display.Window) {
	title := string(window.title[:window.title_count])
	if frame.element_places.dropped > 0 && !drawing.element_places_dropped_logged {
		drawing.element_places_dropped_logged = true
		system.log(.Warning, "interface: ", title, ": a frame names ", u64(frame.element_places.dropped), " elements that the window does not keep: empty, longer than ", u64(ELEMENT_NAME_CAPACITY), " bytes, or past ", u64(ELEMENT_PLACE_CAPACITY), "; they have no element line. A window writes this line one time")
	}
	element_places_publish(&drawing.element_places_written, &frame.element_places, "interface: ", title)
}

// act_names_differ says if the act names of a frame differ from the set
// that the compositor has, in their order: a host test runs it with no
// window.
act_names_differ :: proc "contextless" (drawing: ^Window_Drawing, frame: ^Frame) -> bool {
	if !drawing.act_names_sent_once || drawing.act_names_sent_count != frame.act_name_count {
		return true
	}
	for &name, index in frame.act_names[:frame.act_name_count] {
		if drawing.act_names_sent[index] != name.hash {
			return true
		}
	}
	return false
}

// act_names_offer sends the set of the act names of a frame to the
// compositor, in one record, when it differs from the set that the
// compositor has. A full ring sends nothing: the next frame tries again.
@(private = "file")
act_names_offer :: proc "contextless" (drawing: ^Window_Drawing, frame: ^Frame, window: ^display.Window) {
	if frame.act_names_dropped > 0 && !drawing.act_names_dropped_logged {
		drawing.act_names_dropped_logged = true
		system.log(.Warning, "interface: ", string(window.title[:window.title_count]), ": a frame names ", u64(frame.act_names_dropped), " act names that the window does not keep: empty, longer than ", u64(display.ACT_NAME_CAPACITY), " bytes, or past ", u64(display.ACT_NAME_SET_CAPACITY), "; the palette cannot go to them. A window writes this line one time")
	}
	if !act_names_differ(drawing, frame) {
		return
	}
	hashes: [display.ACT_NAME_SET_CAPACITY]u64
	for &name, index in frame.act_names[:frame.act_name_count] {
		hashes[index] = name.hash
	}
	if !display.act_names_send(window, hashes[:frame.act_name_count]) {
		return
	}
	drawing.act_names_sent = hashes
	drawing.act_names_sent_count = frame.act_name_count
	drawing.act_names_sent_once = true
}

// act_go_to takes the event Go_To: the palette raised this window to reach
// an act name. The element of the last frame that named it takes the focus,
// and the next frame draws it.
@(private = "file")
act_go_to :: proc "contextless" (drawing: ^Window_Drawing, window: ^display.Window, hash: u64) {
	title := string(window.title[:window.title_count])
	if name, found := focus_by_act_name(&drawing.state, hash); found {
		system.log(.Info, "interface: ", title, ": the focus is on the element of ", name)
	} else {
		system.log(.Info, "interface: ", title, ": the palette came for an act name that no element of the last frame names")
	}
}

// A rectangle as the drawing module describes it: the fields of Rectangle,
// each an integer of 64 bits. The two have one layout, so the rectangles
// of a Damage are the records of the table, with no copy. The two records
// of the border are declared for each build, at the top of the file: the
// modus tool reads them there when it compares the declarations below
// with the descriptions of the exports.
Module_Rectangle :: struct {
	left, top, right, bottom: i64,
}
#assert(size_of(Module_Rectangle) == size_of(Rectangle))

// The shape of the canvas and the fill of each rectangle, as the drawing
// module describes them. The rectangles are a table of Module_Rectangle.
Module_Canvas_Shape :: struct {
	width:           i64, // Pixels of a line that belong to the canvas.
	height:          i64, // Lines.
	stride:          i64, // Pixels from one line to the next.
	fill_background: i64, // Not 0: each rectangle is painted with `background` first.
	background:      i64, // The color of that fill.
}

when DRAWING_THROUGH_MODULE {
	// The names of the exports hold the version of the draw record: a
	// module with another version has other names, so the loader refuses
	// it in place of a draw of records that it reads wrong. A new version
	// stops the build here, until the names follow.
	#assert(DRAW_RECORD_VERSION == 17)

	// The declarations name the record of the contract: the check of the
	// declarations of an import reads the layout of a struct by its name.
	foreign _ {
		@(link_name = "damage_of_draw_table_17")
		module_damage_of_draw_table :: proc "c" (before: ^system.Table_To_Read(draw_record.Draw_Record), before_text: ^system.Bytes_To_Read, now: ^system.Table_To_Read(draw_record.Draw_Record), now_text: ^system.Bytes_To_Read, result: ^[]Module_Rectangle, error: ^errors.Error_Record) -> i64 ---
		@(link_name = "execute_draw_table_in_rectangles_17")
		module_execute_draw_table_in_rectangles :: proc "c" (now: ^system.Table_To_Read(draw_record.Draw_Record), now_text: ^system.Bytes_To_Read, picture_memory: ^system.Bytes_To_Read, pixels: ^system.Bytes_To_Change, canvas: ^Module_Canvas_Shape, rectangles: ^system.Table_To_Read(Module_Rectangle), error: ^errors.Error_Record) -> i64 ---
	}

	// records_to_read gives the table place of the records first ..< first
	// + count of a draw table, cut to the records of the frame: the address
	// of the memory of the process, and its counts. The module reads the
	// records where they are.
	@(private = "file")
	records_to_read :: proc "contextless" (table: ^Draw_Table, first, count: int) -> system.Table_To_Read(Draw_Record) {
		start := clamp(first, 0, table.record_count)
		taken := clamp(count, 0, table.record_count - start)
		return {records = raw_data(table.records[start:]), count = u64(taken), capacity = u64(len(table.records) - start)}
	}

	// text_to_read gives the place of the text table of a draw table: the
	// texts and the cells of the grids.
	@(private = "file")
	text_to_read :: proc "contextless" (table: ^Draw_Table) -> system.Bytes_To_Read {
		return {bytes = raw_data(table.text), count = u64(table.text_count), capacity = u64(len(table.text))}
	}

	// difference_through_module finds the damage from the table before to
	// the table now, with the export of the drawing module: one call. The
	// module writes the rectangles into the memory of damage. It gives
	// false when the module refused the call: error has the record, and
	// damage is empty.
	difference_through_module :: proc "contextless" (before, now: ^Draw_Table, damage: ^Damage, error: ^errors.Error_Record) -> bool {
		before_records, before_text := records_to_read(before, 0, before.record_count), text_to_read(before)
		now_records, now_text := records_to_read(now, 0, now.record_count), text_to_read(now)
		result := ([^]Module_Rectangle)(&damage.rectangles[0])[:DAMAGE_CAPACITY]
		count := module_damage_of_draw_table(&before_records, &before_text, &now_records, &now_text, &result, error)
		if count < 0 {
			damage.count = 0
			return false
		}
		damage.count = int(min(count, DAMAGE_CAPACITY))
		return true
	}

	// draw_part_through_module draws the records first ..< first + count of
	// a table into a canvas, in each of the rectangles in their order, each
	// cut to its rectangle, with the export of the drawing module: one call
	// for all the rectangles, at most DAMAGE_CAPACITY. The pixels of the
	// canvas are bytes of the process that the module writes in place. A
	// Picture record of the part names picture memory 0: picture_memory,
	// which the module reads in place. With fill_background, each rectangle
	// is painted with background before its records. It gives false when
	// the module refused the call: error has the record.
	draw_part_through_module :: proc "contextless" (table: ^Draw_Table, first, count: int, picture_memory: []graphics.Color, canvas: graphics.Canvas, rectangles: []Rectangle, fill_background: bool, background: graphics.Color, error: ^errors.Error_Record) -> bool {
		records, text_bytes := records_to_read(table, first, count), text_to_read(table)
		memory_size := u64(len(picture_memory)) * size_of(graphics.Color)
		memory := system.Bytes_To_Read{bytes = ([^]u8)(raw_data(picture_memory)), count = memory_size, capacity = memory_size}
		size := u64(canvas.stride) * u64(canvas.height) * size_of(graphics.Color)
		pixels := system.Bytes_To_Change{bytes = ([^]u8)(canvas.pixels), count = size, capacity = size}
		fill := i64(0)
		if fill_background {
			fill = 1
		}
		shape := Module_Canvas_Shape{width = i64(canvas.width), height = i64(canvas.height), stride = i64(canvas.stride), fill_background = fill, background = i64(background)}
		// A Rectangle and a Module_Rectangle have one layout: the module
		// reads the rectangles of the caller where they are.
		places := system.Table_To_Read(Module_Rectangle){records = ([^]Module_Rectangle)(raw_data(rectangles)), count = u64(len(rectangles)), capacity = u64(len(rectangles))}
		return module_execute_draw_table_in_rectangles(&records, &text_bytes, &memory, &pixels, &shape, &places, error) >= 0
	}

	// frame_difference finds the damage from the table before to the table
	// now, with the export of the drawing module. It gives false when the
	// module refused the call: drawing.module_error has the record, and
	// damage is empty.
	@(private = "file")
	frame_difference :: proc "contextless" (drawing: ^Window_Drawing, before, now: ^Draw_Table, damage: ^Damage) -> bool {
		drawing.module_calls += 1
		if !difference_through_module(before, now, damage, &drawing.module_error) {
			module_refusal_log(drawing, "damage_of_draw_table_17")
			return false
		}
		return true
	}

	// frame_draw paints each rectangle with the background and draws the
	// records that touch it, with the export of the drawing module: one
	// call for all the rectangles of the frame. The pixels of the pictures
	// are the one picture memory of the table. It gives false when the
	// module refused the call, or when the table has more than one picture
	// memory, which one call cannot draw: drawing.module_error has the
	// record.
	@(private = "file")
	frame_draw :: proc "contextless" (drawing: ^Window_Drawing, now: ^Draw_Table, canvas: graphics.Canvas, rectangles: []Rectangle) -> bool {
		if len(now.picture_memories) > 1 {
			drawing.module_error = errors.error_make(.Unsupported, .None, 1, i64(len(now.picture_memories)))
			module_refusal_log(drawing, "execute_draw_table_in_rectangles_17")
			return false
		}
		picture_memory: []graphics.Color
		if len(now.picture_memories) == 1 {
			picture_memory = now.picture_memories[0]
		}
		drawing.module_calls += 1
		if !draw_part_through_module(now, 0, now.record_count, picture_memory, canvas, rectangles, true, graphics.colors.background, &drawing.module_error) {
			module_refusal_log(drawing, "execute_draw_table_in_rectangles_17")
			return false
		}
		return true
	}

	// module_refusal_log writes the one line of a window whose draw or
	// difference the drawing module refused: the export, and the error
	// record in words. A refused draw presents nothing and makes the next
	// frame whole, which is refused again: with no line, the window stays
	// empty and the log says nothing. One line for the life of the window:
	// the cause is in the process (a table, a shape, a picture memory), and
	// each frame has the same one.
	@(private = "file")
	module_refusal_log :: proc "contextless" (drawing: ^Window_Drawing, export_name: string) {
		if drawing.module_refusal_logged {
			return
		}
		drawing.module_refusal_logged = true
		record := drawing.module_error
		cause := "the module gave an error kind that this line has no words for"
		kind, kind_ok := errors.kind_of_word(record.kind)
		if !kind_ok {
			cause = "the module gave a word that names no error kind"
		}
		// Each kind is named, so that a new kind of the drawing module gets
		// its words here or joins this list by a choice.
		switch kind {
		case .None, .Empty, .Bad_Flags, .Bad_Byte, .Handle_Absent, .Handle_Ended, .Handle_Kind, .Handle_Rights, .Budget, .Budget_Hidden, .Over_Limit, .Full, .State, .Absent, .Damaged, .Device, .No_Grant, .Malformed, .No_Target, .Overlap, .Unknown_Operation, .Refused, .No_Answer, .Link_Down, .Busy, .Out_Of_Range, .Reserved, .Not_Payer, .Object_Shared, .Object_Marked, .Whole_Only, .Not_Multiple, .Not_Authentic, .Seed_Too_Weak, .Exists, .Starter_Module:
		case .Too_Long:
			cause = "a table has more records or bytes than the module takes"
		case .Bad_Value:
			cause = "the shape of the canvas has a width, a height or a stride that the module refuses"
			// The one other Bad_Value of the module: the order of the clips.
			// Its words end with the bound of the clips open, written from
			// the contract below.
			if unit, unit_ok := errors.unit_of_word(record.unit); unit_ok && unit == .Records {
				system.log(.Warning, "interface: the drawing module refused ", export_name, ": the clips of the table are out of order: a pop with no push open, a push with no pop, or a push past ", u64(draw_record.CLIP_DEPTH_LIMIT), " open (the error kind ", u64(max(record.kind, 0)), ", the argument ", u64(max(record.argument, 0)), ", the record ", u64(max(record.found, 0)), "). A refused draw leaves the window as it was. A window writes this line one time")
				return
			}
		case .Too_Small:
			cause = "the pixels do not hold the shape of the canvas"
		case .Bad_Address:
			cause = "the address of the pixels is not a multiple of 4"
		case .Unsupported:
			cause = "the frame has pictures in more than one picture memory, and one call of the module draws one"
		}
		system.log(.Warning, "interface: the drawing module refused ", export_name, ": ", cause, " (the error kind ", u64(max(record.kind, 0)), ", the argument ", u64(max(record.argument, 0)), "). A refused difference draws each frame whole; a refused draw leaves the window as it was. A window writes this line one time")
	}
} else {
	// frame_difference finds the damage from the table before to the table
	// now, with the package. It never fails.
	@(private = "file")
	frame_difference :: proc "contextless" (drawing: ^Window_Drawing, before, now: ^Draw_Table, damage: ^Damage) -> bool {
		damage_by_difference(before, now, damage)
		return true
	}

	// frame_draw paints each rectangle with the background and draws the
	// records that touch it, with the package. It never fails.
	@(private = "file")
	frame_draw :: proc "contextless" (drawing: ^Window_Drawing, now: ^Draw_Table, canvas: graphics.Canvas, rectangles: []Rectangle) -> bool {
		draw_damage_on_surface(now, canvas, rectangles)
		return true
	}
}

// window_drawing_of makes the drawing of a window with tables in the
// memory of the caller.
window_drawing_of :: proc "contextless" (records_now, records_before: []draw_record.Draw_Record, text_now, text_before: []u8) -> Window_Drawing {
	return {now = {records = records_now, text = text_now}, before = {records = records_before, text = text_before}}
}

// What a process keeps to draw one window, in one record of its own
// memory: the drawing, and the memory of its two draw tables. RECORDS is
// the capacity of each table in records, TEXT in bytes of text. A table
// with a grid starts at an address that is a multiple of 4, so TEXT is a
// multiple of 4: the second text table then starts at such an address too.
Window_Memory :: struct($RECORDS, $TEXT: int) where RECORDS > 0 && TEXT > 0 && TEXT % 4 == 0 {
	drawing:                     Window_Drawing,
	records_now, records_before: [RECORDS]Draw_Record,
	text_now, text_before:       [TEXT]u8,
}

// window_memory_drawing gives the drawing of a window memory, with its two
// tables in the memory of the record. A global record cannot hold slices of
// itself before the process runs, so each call gives the slices again: the
// same slices each time, and the other fields of the drawing (the input,
// the state, the picture memories) stay as they are.
window_memory_drawing :: proc "contextless" (memory: ^Window_Memory($RECORDS, $TEXT)) -> ^Window_Drawing {
	memory.drawing.now.records = memory.records_now[:]
	memory.drawing.now.text = memory.text_now[:]
	memory.drawing.before.records = memory.records_before[:]
	memory.drawing.before.text = memory.text_before[:]
	return &memory.drawing
}

// window_frame_start starts a frame of a window whose drawing is in a
// window memory: window_frame_begin, after the tables are given. It draws
// no background: the draw of a frame paints the background color under
// each rectangle first (draw_damage_on_surface), so a rectangle of that
// color over the window would draw no pixel. A window with the grid of
// points of the rules draws it with background.
window_frame_start :: proc "contextless" (memory: ^Window_Memory($RECORDS, $TEXT), window: ^display.Window = nil) -> Frame {
	return window_frame_begin(window_memory_drawing(memory), window)
}

// window_events takes the events of a window into the input of the next
// frame, until the input has KEY_CAPACITY keys. It gives true if an event
// came, and also when the last frame was left out and the compositor took
// the picture before it since: a process that draws only after an event
// then draws that frame.
window_events :: proc "contextless" (drawing: ^Window_Drawing, window: ^display.Window) -> bool {
	came := drawing.late && display.canvas_free(window)
	// A full input stops the reading: the other events wait in the ring.
	for input_has_room(&drawing.input) {
		event := display.next_event(window) or_break
		input_add(&drawing.input, event)
		came = true
		// A new font: each record is the same, each pixel of text is not.
		// The next frame of each picture draws the whole window.
		if event.kind == .Settings_Changed {
			draw_whole_window_next(drawing)
		}
		if event.kind == .Go_To {
			act_go_to(drawing, window, event.act)
		}
		// The principal resized the window: the surface of the new size
		// has no picture known, so the next frame draws it whole. A
		// refused surface keeps the old one, whose pictures stay known.
		if event.kind == .Resized && display.surface_resize(window, event.width, event.height) == .Ok {
			draw_whole_window_next(drawing)
		}
		// The keys of the clipboard wait for the next frame, whose element
		// with the focus takes them (clipboard_answer).
		if event.kind == .Copy_Asked {
			drawing.input.copy_asked = true
		}
		if event.kind == .Pasted {
			// A newer paste: the compositor ended the lend of the one
			// before, which no frame took.
			if drawing.input.paste.kind == .Pasted {
				display.paste_refuse(window, drawing.input.paste)
			}
			drawing.input.paste, drawing.input.paste_window = event, window
		}
	}
	return came
}

// clipboard_answer answers, after a frame, the keys of the clipboard that
// the frame had: the text that an element gave to a copy, or no content;
// and a paste that no element took. Then the frame holds them no more.
@(private = "file")
clipboard_answer :: proc "contextless" (drawing: ^Window_Drawing, frame: ^Frame, window: ^display.Window) {
	input := &drawing.input
	if input.copy_asked {
		if frame.copy_given {
			display.copy_send(window, frame.copied)
		} else {
			display.copy_decline(window)
		}
		input.copy_asked = false
	}
	if input.paste.kind == .Pasted {
		if !frame.paste_taken {
			display.paste_refuse(window, input.paste)
		}
		input.paste, input.paste_window = {}, nil
	}
	frame.copied, frame.copy_given, frame.paste_taken = nil, false, false
}

// draw_whole_window_next makes the next frame of each picture of the
// surface a whole frame: no picture is known. A process that reads its
// events with no window_events calls it on Settings_Changed.
draw_whole_window_next :: proc "contextless" (drawing: ^Window_Drawing) {
	drawing.debts = {}
}

// window_frame_begin starts a frame of the window.
window_frame_begin :: proc "contextless" (drawing: ^Window_Drawing, window: ^display.Window = nil) -> Frame {
	drawing.build_start = system.nanoseconds()
	// The choice of the settings page, read at each frame: the appearance
	// in force, the font, the order of the stripes and the grid fit. A
	// change holds from this frame, also before the event Settings_Changed
	// comes, and also when it never comes: the compositor tells only a
	// window with a surface, so a window that read the page before the boot
	// pass of `settings` and made its surface after it gets none. The
	// measure of a text decides its font here (font_in_use), so a stale
	// font would measure an interface text in B612 over the setting
	// `spleen`. Each picture then draws whole, so that no picture keeps a
	// part of the other font or appearance
	// (src/md/features/appearance.md).
	if display.text_settings_apply() {
		draw_whole_window_next(drawing)
	}
	if window != nil {
		display.picture_begin(window)
	}
	// The glyphs past the glyph cache that the process draws itself in
	// this frame count their use in it.
	display.text_frame_begin()
	display.text_not_kept_tell()
	// The elements of a window draw their names and titles in the
	// interface font of the process, when its starter gave it one.
	drawing.now.interface_font = display.interface_font_of()
	return frame_begin(&drawing.now, &drawing.state, &drawing.input, system.time())
}

// window_scroll_bar_wake gives the time, in milliseconds of the clock of
// the system, at which a held arrow button of a scroll bar of the window
// takes its next step: a process that sleeps while nothing changes wakes at
// that time and builds a frame. due is false when no step is due.
window_scroll_bar_wake :: proc "contextless" (drawing: ^Window_Drawing) -> (time: u64, due: bool) {
	return drawing.state.scroll_bar_repeat_at, drawing.state.scroll_bar_repeat_at != 0
}

// window_frame_end ends the frame: it finds what changed by difference
// with the last frame that the window presented, draws the records again
// in the changed rectangles and in the debt of the picture that the
// process draws now, and presents the changed part. It gives the count of
// the rectangles that it drew.
//
// A frame is shown whole or not at all:
// the frame is drawn in the picture that the compositor does not read, and
// only after the compositor took the picture before
// (display.canvas_wait). When the compositor does not take it, the frame
// is left out: nothing is drawn, the result is 0, and the next frame is
// compared with the last frame that was presented.
//
// The difference and the draw are the package compiled in, or the two
// exports of the drawing module (DRAWING_THROUGH_MODULE): the same code
// behind a border, crossed one time for the difference and one time for
// the draw of all the damage rectangles. A whole frame and a frame with
// damage draw the same way: each rectangle is painted with the
// background, then the records that touch it are drawn.
//
// The work is three procedures that read no clock, so a host test drives
// them on a window in plain memory: window_frame_gate, window_frame_changes
// and window_frame_show. This procedure calls them in this order and
// measures the time between them.
window_frame_end :: proc "contextless" (drawing: ^Window_Drawing, frame: ^Frame, window: ^display.Window) -> int {
	frame_end(frame)
	clipboard_answer(drawing, frame, window)
	input_clear(&drawing.input)
	act_names_offer(drawing, frame, window)
	drawing.build_time = system.nanoseconds() - drawing.build_start
	drawing.difference_time, drawing.draw_time = 0, 0
	if !window_frame_gate(drawing, window) {
		return 0
	}
	start := system.nanoseconds()
	changes := window_frame_changes(drawing, window)
	measured := system.nanoseconds()
	drawing.difference_time = measured - start
	count := window_frame_show(drawing, window, &changes)
	drawing.draw_time = system.nanoseconds() - measured
	element_places_write(drawing, frame, window)
	return count
}

// window_frame_gate says if the frame in drawing.now can be drawn: the
// compositor took the picture before (display.canvas_wait). false: the
// frame is left out, and no state of the pictures changes.
window_frame_gate :: proc "contextless" (drawing: ^Window_Drawing, window: ^display.Window) -> bool {
	drawing.damage = {}
	drawing.late = !display.canvas_wait(window)
	return !drawing.late
}

// What window_frame_changes found for the frame in drawing.now, and
// window_frame_show needs.
Frame_Changes :: struct {
	changed: Damage, // The difference from the last table to the frame. Empty when it is not known: no picture is known then.
	present: Damage, // Where the picture on the screen differs from the frame.
	picture: int, // The picture of the surface that the frame is drawn in.
}

// window_frame_changes finds what the frame in drawing.now draws
// (drawing.damage) and what it presents. Call it after a yes of
// window_frame_gate.
window_frame_changes :: proc "contextless" (drawing: ^Window_Drawing, window: ^display.Window) -> (changes: Frame_Changes) {
	surface := Rectangle{0, 0, window.canvas.width, window.canvas.height}
	changes.picture = window.picture
	// The difference from the last table to this frame. With no last
	// table, with a table that was full, or with a difference that the
	// drawing module refused, no picture is known against this frame:
	// each one is drawn whole.
	changed_known := drawing.drawn && !drawing.before.full
	if changed_known {
		changed_known = frame_difference(drawing, &drawing.before, &drawing.now, &changes.changed)
	}
	if !changed_known {
		changes.changed = {}
		drawing.debts = {}
	}
	// The screen shows the other picture; its difference with the frame
	// must reach the screen.
	damage_of_picture(&drawing.debts, changes.picture, &changes.changed, surface, &drawing.damage, &changes.present)
	return changes
}

// window_frame_show draws the frame in drawing.now in the canvas of the
// window and presents it, from the changes that window_frame_changes
// found, then keeps the frame as the last table. It gives the count of the
// rectangles that it drew.
window_frame_show :: proc "contextless" (drawing: ^Window_Drawing, window: ^display.Window, changes: ^Frame_Changes) -> int {
	surface := Rectangle{0, 0, window.canvas.width, window.canvas.height}
	// sent: the compositor has the present. When the command ring is full,
	// the present is lost, and the picture that was drawn is not the last
	// table: its next frame is whole. A draw that the drawing module
	// refused presents nothing, and does the same.
	sent := true
	if changes.present.count > 0 {
		sent = drawing.damage.count == 0 || frame_draw(drawing, &drawing.now, window.canvas, drawing.damage.rectangles[:drawing.damage.count])
		if sent {
			bounds := intersection(damage_bounds(&changes.present), surface)
			sent = display.present_rectangle(window, bounds.left, bounds.top, max(bounds.right - bounds.left, 0), max(bounds.bottom - bounds.top, 0))
		} else {
			display.picture_end(window)
			display.picture_due_set(window, false)
		}
		picture_debts_after(&drawing.debts, changes.picture, &changes.changed, sent)
	} else {
		// The screen shows the frame. The picture that the process draws
		// can still owe pixels: it pays them in the frame that changes
		// the screen. A frame with nothing to draw is a picture of the
		// measure too.
		drawing.damage = {}
		display.picture_end(window)
		// The frame is drawn: no picture is due, also when the frame
		// changed nothing on the screen.
		display.picture_due_set(window, false)
	}
	drawing.drawn = sent && draw_table_copy(&drawing.before, &drawing.now)
	if sent && changes.present.count > 0 {
		appearance_presented_note(drawing, window)
	}
	return drawing.damage.count
}

// window_frame_end_without_present ends the frame of a process that draws
// over it by hand: it draws the frame whole in window.canvas and presents
// nothing. The process then draws over the frame in window.canvas and
// calls display.present. With window_frame_end, window.canvas is the other
// picture after the call. The pixels that the process adds are in no
// table, so each frame of such a window is whole.
//
// false: the compositor did not take the picture before (the frame is
// left out), or the drawing module refused the draw. The process draws
// nothing and does not present.
window_frame_end_without_present :: proc "contextless" (drawing: ^Window_Drawing, frame: ^Frame, window: ^display.Window) -> bool {
	frame_end(frame)
	clipboard_answer(drawing, frame, window)
	input_clear(&drawing.input)
	act_names_offer(drawing, frame, window)
	drawing.build_time = system.nanoseconds() - drawing.build_start
	drawing.damage = {}
	drawing.debts = {}
	drawing.drawn = false
	drawing.late = !display.canvas_wait(window)
	if drawing.late {
		return false
	}
	whole_surface := [1]Rectangle{{0, 0, window.canvas.width, window.canvas.height}}
	if !frame_draw(drawing, &drawing.now, window.canvas, whole_surface[:]) {
		return false
	}
	drawing.damage.rectangles[0] = whole_surface[0]
	drawing.damage.count = 1
	element_places_write(drawing, frame, window)
	return true
}

// show_picture draws a frame of a window that is one picture of the
// process: one Picture record at (0, 0). generation is a new number when
// the pixels of the picture changed: with the same number, the frame draws
// nothing.
show_picture :: proc "contextless" (drawing: ^Window_Drawing, window: ^display.Window, picture: graphics.Canvas, generation: u32) {
	frame := window_frame_begin(drawing, window)
	draw_picture(frame.table, 0, 0, picture, generation)
	window_frame_end(drawing, &frame, window)
}

// window_drawing_of_picture makes the drawing of a window that is one
// picture of the process, with tables in the memory of the caller. The
// picture memories stay memory of the caller: the slice must live as
// long as the window.
window_drawing_of_picture :: proc "contextless" (records_now, records_before: []Draw_Record, picture_memories: [][]graphics.Color) -> Window_Drawing {
	drawing := Window_Drawing{now = {records = records_now}, before = {records = records_before}}
	drawing.now.picture_memories = picture_memories
	drawing.before.picture_memories = picture_memories
	return drawing
}
