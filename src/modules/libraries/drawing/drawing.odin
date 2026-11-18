// The drawing module: the damage of a frame and the draw of its records,
// for each process that imports it (docs/INTERFACE.md, section 7). It holds
// the code that finds what changed between two draw tables and the code
// that draws the records of a draw table into pixels: the fills, the
// gradients, the lines, the text of the cells and the text of the
// interface font, with their blends. A process that imports it holds none
// of that code: the system has one copy.
//
// **What it is for.** It is the first [library module](term:library-module):
// code that each module with a window compiled into its own file. The
// [interface package](term:interface-package) keeps, in the process, what a
// process calls many times for each frame: the elements, the layout, the
// input. The [drawing module](term:drawing-module) takes what a process
// calls a few times for each frame: `damage_of_draw_table_17` one time, then
// `execute_draw_table_in_rectangles_17` one time for all the damage
// rectangles of the frame.
//
// **No copy.** Each parameter is memory of the caller, and a direct call
// passes its address: the [draw table](term:draw-table) of the frame, the
// draw table of the frame before, the [picture memory](term:picture-memory)
// of the pictures, and the pixels of the surface, which the module writes
// in place.
//
// **What it keeps.** It allocates nothing, and it keeps no address of the
// caller after a call. Its own data is a cache, one copy for each process
// that imports it: the text settings of the process (the choice of the
// font, the glyph caches, the font outlines and the demand cache that the
// starter of the process mapped, validated at the first draw), its private
// glyph cache, and the tables of the blend of a text. It reads the choice
// of the settings again at each draw, so a process sends it nothing when a
// setting changes. A character past the glyph caches is drawn from the
// demand cache or into the private glyph cache of this copy, which the
// budget of the process pays (src/md/features/glyphs_on_demand.md).
//
// **Pictures.** A [picture record](term:picture-record) names its pixels by
// values: the place of its first pixel in a picture memory, and its
// stride. The caller passes one picture memory as bytes, and the module
// checks each picture against it.
//
// **Grids.** A Text_Grid record names its cells by values too: the cells
// are a copy in the text table of the frame, so the module reads them in
// the text that each export already takes. The terminal draws its grid
// through the module (src/md/api/text_grid.md).
//
// **The version in the names.** The 15 in the name of each export is the
// version of the [draw record](term:draw-record). A draw record of another
// version has exports with other names, so a module that reads the records
// in another way cannot take the place of this one.
package drawing

import "base:intrinsics"
import "modus:contract/draw_record"
import "modus:contract/errors"
import "modus:contract/glyph_cache"
import "modus:contract/settings"
import "modus:support/display"
import "modus:support/graphics"
import "modus:support/interface"
import "modus:support/system"

// The names of the exports say which draw record they read.
#assert(interface.DRAW_RECORD_VERSION == 17)

// A rectangle of the surface, in pixels: right and bottom are not in it.
Damage_Rectangle :: struct {
	left:   i64,
	top:    i64,
	right:  i64,
	bottom: i64,
}

// The shape of the pixels of a canvas, 4 bytes for each pixel, and what
// the draw does in each rectangle before the records. The rectangles are a
// table beside it: a record holds no table.
Canvas_Shape :: struct {
	width:           i64, // Pixels of a line that belong to the canvas.
	height:          i64, // Lines.
	stride:          i64, // Pixels from one line to the next: at least `width`.
	fill_background: i64, // Not 0: each rectangle is painted with `background` first, so a record that the frame no longer has leaves no pixel.
	background:      i64, // The color of that fill, 0x00RRGGBB.
}

// The most rectangles of one draw: the most that the damage of a frame
// has, so a frame is always one call. The module copies them into its
// frame before it uses them, so the bound is the size of that copy.
@(private)
RECTANGLE_CAPACITY :: interface.DAMAGE_CAPACITY

// The most records or bytes of a table of a caller: no count times a size
// wraps, and a count holds in an int.
@(private)
TABLE_LIMIT :: u64(1) << 40

// The numbers of the parameters in an error record, from 1.
@(private)
ARGUMENT_BEFORE :: 1
@(private)
ARGUMENT_BEFORE_TEXT :: 2
@(private)
ARGUMENT_DAMAGE_NOW :: 3
@(private)
ARGUMENT_DAMAGE_NOW_TEXT :: 4
@(private)
ARGUMENT_NOW :: 1
@(private)
ARGUMENT_NOW_TEXT :: 2
@(private)
ARGUMENT_PICTURE_MEMORY :: 3
@(private)
ARGUMENT_PIXELS :: 4
@(private)
ARGUMENT_CANVAS :: 5
@(private)
ARGUMENT_RECTANGLES :: 6

// The text of the process that runs this copy of the module: what the
// module loads one time, at the first draw. It is data of the module, and
// the loader gives each process its own copy.
//
// The rule of the callers: one thread of a process at a time calls
// execute_draw_table_in_rectangles_17. It is the rule of the text state of
// the graphics package, which changes "between two frames" (src/library/support/graphics,
// text.odin), and each window of the system has one loop that draws. The
// module takes no lock for it and waits for no other thread: the load
// below, the choice of the settings that each draw applies, the square
// root table and the blend tables are all written with no guard.
//
// What a second thread gets when a process breaks the rule: the two
// threads can both load (they write the same values), and one can draw
// while the other writes the choice of the font or a blend table. That
// draw can show a text in the wrong font or with wrong colors, and when
// the choice of the settings changes at that moment it can read a glyph
// cache record that is half of one cache and half of the other, and
// fault. All of it is inside the process that broke the rule: the module
// runs in its address space, with its own copy of this data.
// damage_of_draw_table_17 reads no text state: any thread can call it.
@(private)
Process_Text :: struct {
	loaded:               bool, // The text settings and the interface font were looked for.
	interface_font:       display.Interface_Font, // The two glyph caches of the interface font, validated.
	interface_font_given: bool, // The starter mapped both, and both are of a proportional font.
}

@(private)
process_text: Process_Text

// A context with no bit set: what a host test reads, as it has no context
// of a process. No fixed range is mapped in it, so nothing is loaded.
@(private)
no_context: system.Context

// process_text_load loads the text settings and the interface font of the
// process, one time, then gives the choice of the settings page to the
// text code of this module: a change of a setting reaches the next draw
// with no message from the process. It writes no line on the log: the
// process validated the same caches when it opened its window, and wrote
// the lines. One thread of a process at a time runs it (Process_Text).
@(private)
process_text_load :: proc "contextless" () {
	if !process_text.loaded {
		context_record := &no_context
		when ODIN_OS == .Freestanding {
			context_record = system.context_record()
		}
		_, _ = display.text_settings_load(context_record)
		weights := [2]settings.Glyph_Cache{.Interface, .Interface_Bold}
		caches: [2]glyph_cache.Cache
		given := true
		for weight, index in weights {
			problem: glyph_cache.Problem
			caches[index], problem = settings.glyph_cache_open(&context_record.values, weight)
			if problem.kind != .None || caches[index].header.flags & glyph_cache.FLAG_PROPORTIONAL == 0 {
				given = false
			}
		}
		if given {
			process_text.interface_font = {regular = caches[0], bold = caches[1]}
			process_text.interface_font_given = true
		}
		process_text.loaded = true
	}
	display.text_settings_apply()
}

// draw_table_of makes a draw table of the package over a Read table and
// its text: the same memory, no copy. Each count is read one time. ok is
// false, with the error record, when a count passes TABLE_LIMIT.
//
// The module does not check the text range of each record here: the
// package checks each range where it uses the record
// (src/library/support/interface, difference.odin and execute.odin), so one place
// holds the rule. These checks protect a correct caller from a wrong count
// or a wrong record: no fault, and no write outside the pixels. They are
// not a defence against a caller that changes its tables during the call.
// The shape, the counts and the rectangles are read one time
// (volatile_load); a draw record is a plain read, which the compiler can
// make again after a check. A direct call is not a border of trust: the
// module runs in the address space of its caller, with the rights of that
// process and its own copy of the data of the module, so a caller that
// cheats reaches only its own memory. In an isolated call the receiver
// gives the export its own copy of the arguments.
@(private)
draw_table_of :: proc "contextless" (records: ^system.Table_To_Read(draw_record.Draw_Record), text: ^system.Bytes_To_Read, records_argument, text_argument: i64, error: ^errors.Error_Record) -> (table: interface.Draw_Table, ok: bool) {
	record_count := intrinsics.volatile_load(&records.count)
	text_count := intrinsics.volatile_load(&text.count)
	if record_count > TABLE_LIMIT {
		errors.fail(error, -1, .Too_Long, .Records, records_argument, i64(min(record_count, u64(max(i64)))), i64(TABLE_LIMIT))
		return {}, false
	}
	if text_count > TABLE_LIMIT {
		errors.fail(error, -1, .Too_Long, .Bytes, text_argument, i64(min(text_count, u64(max(i64)))), i64(TABLE_LIMIT))
		return {}, false
	}
	return {records = records.records[:record_count], record_count = int(record_count), text = text.bytes[:text_count], text_count = int(text_count)}, true
}

// damage_of_draw_table_17 gives the rectangles of the surface that differ between the draw table before and the draw table now. The result is a Table of at most 8 rectangles, which no two of them touch. A record that the border of the draw record refuses differs from each record of other bytes, and a text record or a Path record that names bytes past its text table differs from each record: the box of each is damaged. A Path record compares the bytes of its points, wherever they are in its text table, as a text compares its bytes. A Picture record differs when its generation, its format, its picture memory, its first pixel or its stride differs: the module reads no pixel of a picture. A Text_Grid record of the same place and size in the two tables damages, in each row, the span from the first changed cell to the last one; its cells are in its text table, and a grid whose cells its text table does not hold is damaged whole. Nothing is copied in a direct call: the two tables are read where the caller has them, and the rectangles are written into the buffer of the caller. It fails with -1 and the error record Too_Long, with the argument, for a table over 2^40 records or bytes.
@(export, link_name = "damage_of_draw_table_17")
damage_of_draw_table_17 :: proc "c" (before: ^system.Table_To_Read(draw_record.Draw_Record), before_text: ^system.Bytes_To_Read, now: ^system.Table_To_Read(draw_record.Draw_Record), now_text: ^system.Bytes_To_Read, result: ^[]Damage_Rectangle, error: ^errors.Error_Record) -> i64 {
	before_table, before_ok := draw_table_of(before, before_text, ARGUMENT_BEFORE, ARGUMENT_BEFORE_TEXT, error)
	if !before_ok {
		return -1
	}
	now_table, now_ok := draw_table_of(now, now_text, ARGUMENT_DAMAGE_NOW, ARGUMENT_DAMAGE_NOW_TEXT, error)
	if !now_ok {
		return -1
	}
	damage: interface.Damage
	interface.damage_by_difference(&before_table, &now_table, &damage)
	buffer := result^
	for rectangle, index in damage.rectangles[:damage.count] {
		if index < len(buffer) {
			buffer[index] = {i64(rectangle.left), i64(rectangle.top), i64(rectangle.right), i64(rectangle.bottom)}
		}
	}
	return i64(damage.count)
}

// execute_draw_table_in_rectangles_17 draws the records of a draw table into the pixels of a canvas, in each rectangle of `rectangles`, in their order, each cut to its rectangle: the pixels are those of one draw for each rectangle, also where two rectangles overlap. With `fill_background` of the canvas not 0, each rectangle is painted with the color `background` before its records. A table of no rectangle draws nothing. The pixels are memory of the caller, written in place: no copy in a direct call. The text is drawn in the font that the settings of the process choose, from the glyph caches of the process; a character past them is drawn from the fallback chain of its font, from the demand cache or into the private glyph cache of the process, when the starter of the process mapped the font outlines, or as the replacement glyph. Each color of a record is 0xAARRGGBB with straight alpha, and blends over the pixels by one rule in linear light; an opaque color writes its pixels. The alpha of a text scales the cover of each pixel of its ink. A Rectangle with no pattern and a Gradient can have a box inside the pixels: the part of an edge pixel inside the box scales its alpha. A Gradient mixes its two colors at the level of the center of each pixel on the line of its two points, in steps of 1/255. A Picture record of picture memory 0 takes its pixels from `picture_memory`, from its first pixel, a line each stride pixels: the format Opaque copies each pixel, and the format Straight_Alpha blends each pixel, 0xAARRGGBB, by the rule of the colors. A Text_Grid record draws its cells from `now_text`, from its first byte, a row each `columns` cells. A Path record reads its points from `now_text`, 12 bytes each, from its first byte: it fills its subpaths by the nonzero rule, then strokes them with butt ends and bevel joins, each pixel by the exact part of it that the shape covers, and cuts each quadratic curve into at most 16 segments. A record that the border of the draw record refuses (a word that names no kind, a reserved byte that is not 0, a box that is inverted, past the coordinate limit or not on whole pixels in a kind that draws on whole pixels, a color of alpha 0 that is not 0, two ends of a gradient of alpha 0 that are not both 0, two points of a gradient that are equal or too far apart, a path of fewer than 2 or more than 1024 points, a stroke of no width, wider than 64 pixels or with no color, a format of a picture that names no member, a field past its bound, a Clip_Pop whose box is not 0) draws nothing. A Clip_Push cuts the records after it to its box and to each clip open before it, until its Clip_Pop; a refused Clip_Push is an empty clip, and at most 16 clips are open. A text record that names bytes past its text table, a Picture record of another picture memory or with a pixel past `picture_memory`, a Text_Grid record with no column, with bytes that are not a whole count of rows, past its text table or at an address that is not a multiple of 4, and a Path record whose points are past its text table, at an address that is not a multiple of 4, or that the border of the points refuses (a command that names none, a first point that is not a Move, a subpath with no segment, a curve with no end, a Close out of its place, a point past the coordinate limit), draw nothing. The result is 0. It fails with -1 and an error record, and draws nothing: Bad_Value of `canvas` for a width or a height below 1 or a stride below the width, Too_Small of `pixels` for bytes that do not hold `stride` times `height` pixels, Bad_Address of `pixels` or of `picture_memory` for an address that is not a multiple of 4, Too_Long of `rectangles` for more than 8 rectangles, Too_Long for a table over 2^40 records or bytes, Bad_Value of `now` with the unit Records for clips out of order: the value is the problem (1 a Clip_Pop with no Clip_Push open, 2 a Clip_Push past 16 open, 3 a Clip_Push that no Clip_Pop ends), and found the number from 1 of the record.
@(export, link_name = "execute_draw_table_in_rectangles_17")
execute_draw_table_in_rectangles_17 :: proc "c" (now: ^system.Table_To_Read(draw_record.Draw_Record), now_text: ^system.Bytes_To_Read, picture_memory: ^system.Bytes_To_Read, pixels: ^system.Bytes_To_Change, canvas: ^Canvas_Shape, rectangles: ^system.Table_To_Read(Damage_Rectangle), error: ^errors.Error_Record) -> i64 {
	// One copy of the shape, of each count and of the rectangles: the
	// caller can change them during the call, and a value that is checked
	// is the value that is used.
	canvas_shape := intrinsics.volatile_load(canvas)
	pixel_bytes := intrinsics.volatile_load(&pixels.count)
	pixel_address := intrinsics.volatile_load(&pixels.bytes)
	picture_bytes := intrinsics.volatile_load(&picture_memory.count)
	picture_address := intrinsics.volatile_load(&picture_memory.bytes)
	rectangle_count := intrinsics.volatile_load(&rectangles.count)
	rectangle_address := intrinsics.volatile_load(&rectangles.records)
	if canvas_shape.width <= 0 || canvas_shape.height <= 0 || canvas_shape.stride < canvas_shape.width {
		return errors.fail(error, -1, .Bad_Value, .None, ARGUMENT_CANVAS, canvas_shape.width <= 0 ? canvas_shape.width : canvas_shape.height <= 0 ? canvas_shape.height : canvas_shape.stride)
	}
	// No product wraps, also for a stride near 2^62 that a hostile caller
	// gives: the stride is compared with the pixels of one line that the
	// bytes hold.
	if u64(canvas_shape.stride) > pixel_bytes / 4 / u64(canvas_shape.height) {
		return errors.fail(error, -1, .Too_Small, .Bytes, ARGUMENT_PIXELS, i64(min(pixel_bytes, u64(max(i64)))))
	}
	if uintptr(pixel_address) % align_of(graphics.Color) != 0 {
		return errors.fail(error, -1, .Bad_Address, .Bytes, ARGUMENT_PIXELS, i64(uintptr(pixel_address)), i64(min(pixel_bytes, u64(max(i64)))), 1)
	}
	if picture_bytes > TABLE_LIMIT {
		return errors.fail(error, -1, .Too_Long, .Bytes, ARGUMENT_PICTURE_MEMORY, i64(min(picture_bytes, u64(max(i64)))), i64(TABLE_LIMIT))
	}
	if uintptr(picture_address) % align_of(graphics.Color) != 0 {
		return errors.fail(error, -1, .Bad_Address, .Bytes, ARGUMENT_PICTURE_MEMORY, i64(uintptr(picture_address)), i64(picture_bytes), 1)
	}
	if rectangle_count > RECTANGLE_CAPACITY {
		return errors.fail(error, -1, .Too_Long, .Records, ARGUMENT_RECTANGLES, i64(min(rectangle_count, u64(max(i64)))), RECTANGLE_CAPACITY)
	}
	// The rectangles are copied before the first one is drawn: a draw
	// never reads a rectangle that the caller wrote after the check.
	copied_rectangles: [RECTANGLE_CAPACITY]Damage_Rectangle
	for index in 0 ..< int(rectangle_count) {
		copied_rectangles[index] = intrinsics.volatile_load(&rectangle_address[index])
	}
	table, table_ok := draw_table_of(now, now_text, ARGUMENT_NOW, ARGUMENT_NOW_TEXT, error)
	if !table_ok {
		return -1
	}
	// The order of the clips is a fact of the whole table: it is checked
	// before the first pixel, so a refused table draws nothing. The draw
	// walks the order again, since the caller can change the table after
	// this check (src/md/api/draw_table.md, "The kinds").
	if problem, place := draw_record.clip_order_check(table.records[:table.record_count]); problem != .None {
		return errors.fail(error, -1, .Bad_Value, .Records, ARGUMENT_NOW, i64(problem), 0, i64(place) + 1)
	}
	// The one picture memory of a call is number 0 of the table: the
	// package checks each Picture record against it where it draws the
	// record, so one place holds the rule.
	picture_memories := [1][]graphics.Color{([^]graphics.Color)(picture_address)[:picture_bytes / size_of(graphics.Color)]}
	table.picture_memories = picture_memories[:]
	process_text_load()
	// One frame of the order of use of the private glyph cache, and one
	// generation of the demand cache, for each glyph of this draw.
	display.text_frame_begin()
	if process_text.interface_font_given {
		table.interface_font = &process_text.interface_font
	}
	target := graphics.Canvas{pixels = ([^]graphics.Color)(pixel_address), width = int(canvas_shape.width), height = int(canvas_shape.height), stride = int(canvas_shape.stride)}
	surface := interface.Rectangle{0, 0, target.width, target.height}
	// Each rectangle takes the fill and the draw before the next one
	// starts, as one call for each rectangle did: the pixels where two
	// rectangles overlap are those of the last one.
	for copied in copied_rectangles[:rectangle_count] {
		rectangle := interface.Rectangle{int(copied.left), int(copied.top), int(copied.right), int(copied.bottom)}
		if canvas_shape.fill_background != 0 {
			filled := interface.intersection(rectangle, surface)
			if !interface.empty(filled) {
				graphics.fill(target, filled.left, filled.top, filled.right - filled.left, filled.bottom - filled.top, graphics.Color(canvas_shape.background))
			}
		}
		interface.execute_in_rectangle(&table, target, rectangle)
	}
	return 0
}
