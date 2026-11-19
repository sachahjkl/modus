#+build !freestanding
package drawing

import "base:runtime"
import "modus:contract/draw_record"
import "modus:contract/errors"
import "modus:contract/font_outlines"
import "core:log"
import "core:sync"
import "core:testing"
import "modus:support/display"
import "modus:support/graphics"
import "modus:support/interface"
import "modus:support/system"
import "modus:support/text_rendering"

// The text state of the graphics package and the text of the module are
// one for the host process of the tests, and the tests run on several threads: each
// test that draws holds this lock, so the proof of the same pixels changes
// the fonts with no other draw at that time.
@(private = "file")
draw_lock: sync.Mutex

@(private = "file")
records_to_read :: proc(table: ^interface.Draw_Table) -> system.Table_To_Read(interface.Draw_Record) {
	return {records = raw_data(table.records), count = u64(table.record_count), capacity = u64(len(table.records))}
}

@(private = "file")
text_to_read :: proc(table: ^interface.Draw_Table) -> system.Bytes_To_Read {
	return {bytes = raw_data(table.text), count = u64(table.text_count), capacity = u64(len(table.text))}
}

@(private = "file")
rectangles_to_read :: proc(rectangles: []Damage_Rectangle) -> system.Table_To_Read(Damage_Rectangle) {
	return {records = raw_data(rectangles), count = u64(len(rectangles)), capacity = u64(len(rectangles))}
}

// The record of a primitive in a box of whole pixels.
@(private = "file")
record_in_pixels :: proc(primitive: draw_record.Draw_Primitive, left, top, right, bottom: int) -> interface.Draw_Record {
	return draw_record.record_of(primitive, 0, draw_record.units_of_pixels(left), draw_record.units_of_pixels(top), draw_record.units_of_pixels(right), draw_record.units_of_pixels(bottom))
}

// The kind of a record that the border reads; None for a refused record.
@(private = "file")
kind_of :: proc(record: interface.Draw_Record) -> interface.Draw_Kind {
	if _, problem := draw_record.read(record); problem != .None {
		return .None
	}
	kind, _ := draw_record.draw_kind_of_word(record.kind)
	return kind
}

// A canvas whose stride times its height wraps, as a hostile caller gives
// it: the export refuses it with its error record, and draws nothing. So
// does a picture memory at an address that is not a multiple of 4, and a
// table of more rectangles than a frame has.
@(test)
canvas_shape_that_wraps_is_refused :: proc(t: ^testing.T) {
	sync.mutex_lock(&draw_lock)
	defer sync.mutex_unlock(&draw_lock)
	pixels: [16]u32
	records := [1]interface.Draw_Record{record_in_pixels(draw_record.Draw_Rectangle{color = 0xFFFFFFFF}, 0, 0, 1, 4)}
	now := system.Table_To_Read(interface.Draw_Record){records = &records[0], count = 1, capacity = 1}
	text := system.Bytes_To_Read{}
	no_pictures := system.Bytes_To_Read{}
	bytes := system.Bytes_To_Change{bytes = ([^]u8)(&pixels[0]), count = size_of(pixels), capacity = size_of(pixels)}
	refused: errors.Error_Record
	column := [1]Damage_Rectangle{{0, 0, 1, 4}}
	places := rectangles_to_read(column[:])
	shape := Canvas_Shape{width = 1, height = 4, stride = (1 << 62) + 1}
	testing.expect_value(t, execute_draw_table_in_rectangles_17(&now, &text, &no_pictures, &bytes, &shape, &places, &refused), -1)
	testing.expect_value(t, refused.kind, i64(errors.Kind.Too_Small))
	testing.expect_value(t, refused.argument, 4)
	shape = {width = 1, height = 0, stride = 1}
	testing.expect_value(t, execute_draw_table_in_rectangles_17(&now, &text, &no_pictures, &bytes, &shape, &places, &refused), -1)
	testing.expect_value(t, refused.kind, i64(errors.Kind.Bad_Value))
	testing.expect_value(t, refused.argument, 5)
	shape = {width = 4, height = 4, stride = 1}
	testing.expect_value(t, execute_draw_table_in_rectangles_17(&now, &text, &no_pictures, &bytes, &shape, &places, &refused), -1)
	testing.expect_value(t, refused.kind, i64(errors.Kind.Bad_Value))
	testing.expect(t, pixels == [16]u32{}, "a refused call draws nothing")
	// An address of the pixels that is not a multiple of 4.
	shifted := system.Bytes_To_Change{bytes = ([^]u8)(&pixels[0])[1:], count = 16, capacity = 16}
	shape = {width = 1, height = 4, stride = 1}
	testing.expect_value(t, execute_draw_table_in_rectangles_17(&now, &text, &no_pictures, &shifted, &shape, &places, &refused), -1)
	testing.expect_value(t, refused.kind, i64(errors.Kind.Bad_Address))
	testing.expect_value(t, refused.argument, 4)
	// An address of the picture memory that is not a multiple of 4.
	shifted_pictures := system.Bytes_To_Read{bytes = ([^]u8)(&pixels[0])[1:], count = 16, capacity = 16}
	shape = {width = 1, height = 4, stride = 4}
	testing.expect_value(t, execute_draw_table_in_rectangles_17(&now, &text, &shifted_pictures, &bytes, &shape, &places, &refused), -1)
	testing.expect_value(t, refused.kind, i64(errors.Kind.Bad_Address))
	testing.expect_value(t, refused.argument, 3)
	testing.expect(t, pixels == [16]u32{}, "a refused call draws nothing")
	// Nine rectangles, one more than the damage of a frame has, and a count
	// that a hostile caller writes past the records: refused before any
	// rectangle is read or drawn.
	nine: [RECTANGLE_CAPACITY + 1]Damage_Rectangle
	for &rectangle in nine {
		rectangle = {0, 0, 1, 4}
	}
	too_many := rectangles_to_read(nine[:])
	testing.expect_value(t, execute_draw_table_in_rectangles_17(&now, &text, &no_pictures, &bytes, &shape, &too_many, &refused), -1)
	testing.expect_value(t, refused.kind, i64(errors.Kind.Too_Long))
	testing.expect_value(t, refused.argument, 6)
	testing.expect_value(t, refused.value, RECTANGLE_CAPACITY + 1)
	testing.expect_value(t, refused.limit, RECTANGLE_CAPACITY)
	wild_count := system.Table_To_Read(Damage_Rectangle){records = &column[0], count = 1 << 62, capacity = 1}
	testing.expect_value(t, execute_draw_table_in_rectangles_17(&now, &text, &no_pictures, &bytes, &shape, &wild_count, &refused), -1)
	testing.expect_value(t, refused.kind, i64(errors.Kind.Too_Long))
	testing.expect_value(t, refused.argument, 6)
	testing.expect(t, pixels == [16]u32{}, "a refused call draws nothing")
	// No rectangle: the call is good, and draws nothing.
	no_rectangles := system.Table_To_Read(Damage_Rectangle){}
	testing.expect_value(t, execute_draw_table_in_rectangles_17(&now, &text, &no_pictures, &bytes, &shape, &no_rectangles, &refused), 0)
	testing.expect(t, pixels == [16]u32{}, "a call with no rectangle draws nothing")
	// A good shape with its rectangle, and no error record asked.
	testing.expect_value(t, execute_draw_table_in_rectangles_17(&now, &text, &no_pictures, &bytes, &shape, &places, nil), 0)
	testing.expect_value(t, pixels[4], 0xFFFFFF)
}

// Tables whose clips are out of order, as a hostile caller gives them: a
// pop with no push, a push past the bound, a push with no pop. The export
// refuses each before the first pixel, with -1 and the error record
// Bad_Value of the argument now, unit Records, the problem as the value and
// the number from 1 of the record as found, and the pixels stay as they
// were. The same table in order draws.
@(test)
clips_out_of_order_are_refused :: proc(t: ^testing.T) {
	sync.mutex_lock(&draw_lock)
	defer sync.mutex_unlock(&draw_lock)
	SIDE :: 8
	pixels: [SIDE * SIDE]u32
	for &pixel in pixels {
		pixel = 0x00ABCDEF
	}
	kept := pixels
	push := record_in_pixels(draw_record.Draw_Clip_Push{}, 0, 0, 4, 4)
	pop := record_in_pixels(draw_record.Draw_Clip_Pop{}, 0, 0, 0, 0)
	fill := record_in_pixels(draw_record.Draw_Rectangle{color = 0xFFFFFFFF}, 0, 0, SIDE, SIDE)
	text := system.Bytes_To_Read{}
	no_pictures := system.Bytes_To_Read{}
	bytes := system.Bytes_To_Change{bytes = ([^]u8)(&pixels[0]), count = size_of(pixels), capacity = size_of(pixels)}
	shape := Canvas_Shape{width = SIDE, height = SIDE, stride = SIDE}
	whole := [1]Damage_Rectangle{{0, 0, SIDE, SIDE}}
	places := rectangles_to_read(whole[:])
	Out_Of_Order :: struct {
		records: [draw_record.CLIP_DEPTH_LIMIT + 2]interface.Draw_Record,
		count:   int,
		problem: draw_record.Clip_Order_Problem,
		found:   i64,
	}
	cases: [3]Out_Of_Order
	cases[0].records[0], cases[0].records[1], cases[0].records[2] = fill, pop, fill
	cases[0].count, cases[0].problem, cases[0].found = 3, .Pop_Without_Push, 2
	for place in 0 ..= draw_record.CLIP_DEPTH_LIMIT {
		cases[1].records[place] = push
	}
	cases[1].records[draw_record.CLIP_DEPTH_LIMIT + 1] = fill
	cases[1].count, cases[1].problem, cases[1].found = draw_record.CLIP_DEPTH_LIMIT + 2, .Push_Past_Depth_Limit, draw_record.CLIP_DEPTH_LIMIT + 1
	cases[2].records[0], cases[2].records[1], cases[2].records[2] = fill, push, fill
	cases[2].count, cases[2].problem, cases[2].found = 3, .Push_Without_Pop, 2
	for &item in cases {
		now := system.Table_To_Read(interface.Draw_Record){records = &item.records[0], count = u64(item.count), capacity = u64(len(item.records))}
		refused: errors.Error_Record
		testing.expect_value(t, execute_draw_table_in_rectangles_17(&now, &text, &no_pictures, &bytes, &shape, &places, &refused), -1)
		testing.expect_value(t, refused.kind, i64(errors.Kind.Bad_Value))
		testing.expect_value(t, refused.unit, i64(errors.Unit.Records))
		testing.expect_value(t, refused.argument, ARGUMENT_NOW)
		testing.expect_value(t, refused.value, i64(item.problem))
		testing.expect_value(t, refused.found, item.found)
		testing.expectf(t, pixels == kept, "a table refused for %v changed a pixel", item.problem)
	}
	// In order: the fill under the clip covers its 4 by 4 pixels only.
	in_order := [3]interface.Draw_Record{push, fill, pop}
	now := system.Table_To_Read(interface.Draw_Record){records = &in_order[0], count = 3, capacity = 3}
	testing.expect_value(t, execute_draw_table_in_rectangles_17(&now, &text, &no_pictures, &bytes, &shape, &places, nil), 0)
	for y in 0 ..< SIDE {
		for x in 0 ..< SIDE {
			expected := u32(x < 4 && y < 4 ? 0xFFFFFF : 0x00ABCDEF)
			testing.expectf(t, pixels[y * SIDE + x] == expected, "the pixel (%d, %d) of a table in order", x, y)
		}
	}
}

// A text record that names bytes past the text table, and a count of
// records over the limit, as a hostile caller gives them: no fault; the
// record past the text differs, so its rectangle is damaged; the count is
// refused with its error record.
@(test)
hostile_records_are_refused :: proc(t: ^testing.T) {
	text_bytes := [4]u8{'a', 'b', 'c', 'd'}
	before_records := [1]interface.Draw_Record{record_in_pixels(draw_record.Draw_Text{first = 2, count = 4, color = draw_record.opaque(0), origin_x = draw_record.units_of_pixels(8), scale = 1}, 8, 0, 16, 16)}
	now_records := before_records
	before := system.Table_To_Read(interface.Draw_Record){records = &before_records[0], count = 1, capacity = 1}
	now := system.Table_To_Read(interface.Draw_Record){records = &now_records[0], count = 1, capacity = 1}
	text := system.Bytes_To_Read{bytes = &text_bytes[0], count = 4, capacity = 4}
	buffer: [8]Damage_Rectangle
	result := buffer[:]
	refused: errors.Error_Record
	testing.expect_value(t, damage_of_draw_table_17(&before, &text, &now, &text, &result, &refused), 1)
	testing.expect_value(t, buffer[0], Damage_Rectangle{8, 0, 16, 16})
	testing.expect_value(t, refused.kind, 0)
	// A buffer of no rectangle: the count of the full table, and no write.
	none := buffer[:0]
	buffer[0] = {}
	testing.expect_value(t, damage_of_draw_table_17(&before, &text, &now, &text, &none, &refused), 1)
	testing.expect_value(t, buffer[0], Damage_Rectangle{})
	now.count = 1 << 41
	testing.expect_value(t, damage_of_draw_table_17(&before, &text, &now, &text, &result, &refused), -1)
	testing.expect_value(t, refused.kind, i64(errors.Kind.Too_Long))
	testing.expect_value(t, refused.argument, 3)
	now.count = 1
	long_text := system.Bytes_To_Read{bytes = &text_bytes[0], count = 1 << 41, capacity = 4}
	testing.expect_value(t, damage_of_draw_table_17(&before, &long_text, &now, &text, &result, &refused), -1)
	testing.expect_value(t, refused.argument, 2)
}

// Text records in the interface font of a hostile caller, through the
// exports: a range outside the text table, an origin off a third of a
// pixel, an origin past the largest ink margin, a scale of 0, a word of a
// font that names none, the word of the kind Interface_Text that left the
// format, a word of a kind that names none. Each draws nothing and makes no
// fault, and the first is damaged by the difference with an equal copy (a
// range outside its table is equal to no record). The good record draws.
@(test)
hostile_interface_text_records :: proc(t: ^testing.T) {
	sync.mutex_lock(&draw_lock)
	defer sync.mutex_unlock(&draw_lock)
	text_bytes := [5]u8{'T', 'o', ' ', 'L', 'T'}
	text := system.Bytes_To_Read{bytes = &text_bytes[0], count = 5, capacity = 5}
	Fields :: draw_record.Text_Fields
	INTERFACE :: u8(draw_record.Font_Kind.Interface)
	interface_text :: proc(fields: Fields) -> interface.Draw_Record {
		return {kind = u8(interface.Draw_Kind.Text), right = draw_record.units_of_pixels(60), bottom = draw_record.units_of_pixels(16), fields = transmute([draw_record.FIELDS_SIZE]u8)fields}
	}
	origin := draw_record.units_of_pixels(2)
	good := interface_text({count = 5, color = 0xFFFFFFFF, origin_x = origin, font = INTERFACE, scale = 1})
	unknown_kind := good
	unknown_kind.kind = u8(max(interface.Draw_Kind)) + 1
	INTERFACE_TEXT_WORD :: 11
	old_kind := good
	old_kind.kind = INTERFACE_TEXT_WORD
	hostile := [?]interface.Draw_Record {
		interface_text({first = 3, count = 5, color = 0xFFFFFFFF, origin_x = origin, font = INTERFACE, scale = 1}),
		interface_text({count = 5, color = 0xFFFFFFFF, origin_x = origin + 1, font = INTERFACE, scale = 1}),
		interface_text({count = 5, color = 0xFFFFFFFF, origin_x = max(i32), font = INTERFACE, scale = 1}),
		interface_text({count = 5, color = 0xFFFFFFFF, origin_x = origin, font = INTERFACE, scale = 0}),
		interface_text({count = 5, color = 0xFFFFFFFF, origin_x = origin, font = u8(max(draw_record.Font_Kind)) + 1, scale = 1}),
		old_kind,
		unknown_kind,
	}
	pixels: [64 * 16]u32
	bytes := system.Bytes_To_Change{bytes = ([^]u8)(&pixels[0]), count = size_of(pixels), capacity = size_of(pixels)}
	shape := Canvas_Shape{width = 64, height = 16, stride = 64}
	whole := [1]Damage_Rectangle{{0, 0, 64, 16}}
	places := rectangles_to_read(whole[:])
	no_pictures := system.Bytes_To_Read{}
	for record, index in hostile {
		records := [1]interface.Draw_Record{record}
		now := system.Table_To_Read(interface.Draw_Record){records = &records[0], count = 1, capacity = 1}
		pixels = {}
		testing.expect_value(t, execute_draw_table_in_rectangles_17(&now, &text, &no_pictures, &bytes, &shape, &places, nil), 0)
		testing.expectf(t, pixels == [64 * 16]u32{}, "the hostile record %v draws", index)
		if index == 0 {
			buffer: [8]Damage_Rectangle
			result := buffer[:]
			testing.expect_value(t, damage_of_draw_table_17(&now, &text, &now, &text, &result, nil), 1)
		}
	}
	good_records := [1]interface.Draw_Record{good}
	good_table := system.Table_To_Read(interface.Draw_Record){records = &good_records[0], count = 1, capacity = 1}
	testing.expect_value(t, execute_draw_table_in_rectangles_17(&good_table, &text, &no_pictures, &bytes, &shape, &places, nil), 0)
	testing.expect(t, pixels != [64 * 16]u32{}, "the good record draws")
}

// The fill of the area: with it, a rectangle with no record is the
// background; without it, the pixels stay. A Text_Grid record with no
// column and no cells draws nothing. A Picture record draws the pixels of
// the picture memory of the call, and nothing when it names a pixel past
// that memory or a picture memory other than 0, as a hostile caller can
// write it.
@(test)
fill_of_the_background_pictures_and_grids :: proc(t: ^testing.T) {
	sync.mutex_lock(&draw_lock)
	defer sync.mutex_unlock(&draw_lock)
	pixels: [8 * 8]u32
	for &pixel in pixels {
		pixel = 0x123456
	}
	hostile := [3]interface.Draw_Record {
		record_in_pixels(draw_record.Draw_Picture{first = 1, stride = 8}, 0, 0, 8, 8),
		record_in_pixels(draw_record.Draw_Picture{memory = 1, stride = 8}, 0, 0, 8, 8),
		record_in_pixels(draw_record.Draw_Picture{first = max(u32), stride = max(u32)}, 0, 0, 8, 8),
	}
	records := [4]interface.Draw_Record{hostile[0], hostile[1], hostile[2], record_in_pixels(draw_record.Draw_Text_Grid{}, 0, 0, 8, 8)}
	now := system.Table_To_Read(interface.Draw_Record){records = &records[0], count = 4, capacity = 4}
	text := system.Bytes_To_Read{}
	picture_pixels: [8 * 8]u32
	for &pixel, index in picture_pixels {
		pixel = u32(index) + 1
	}
	picture_memory := system.Bytes_To_Read{bytes = ([^]u8)(&picture_pixels[0]), count = size_of(picture_pixels), capacity = size_of(picture_pixels)}
	bytes := system.Bytes_To_Change{bytes = ([^]u8)(&pixels[0]), count = size_of(pixels), capacity = size_of(pixels)}
	shape := Canvas_Shape{width = 8, height = 8, stride = 8}
	middle := [1]Damage_Rectangle{{2, 2, 6, 6}}
	places := rectangles_to_read(middle[:])
	testing.expect_value(t, execute_draw_table_in_rectangles_17(&now, &text, &picture_memory, &bytes, &shape, &places, nil), 0)
	for pixel in pixels {
		testing.expect_value(t, pixel, 0x123456)
	}
	shape.fill_background, shape.background = 1, 0xABCDEF
	testing.expect_value(t, execute_draw_table_in_rectangles_17(&now, &text, &picture_memory, &bytes, &shape, &places, nil), 0)
	for pixel, index in pixels {
		x, y := index % 8, index / 8
		expected: u32 = 0x123456
		if x >= 2 && x < 6 && y >= 2 && y < 6 {
			expected = 0xABCDEF
		}
		testing.expect_value(t, pixel, expected)
	}
	// The good picture: the whole memory, in the rectangle of the area.
	records[0] = record_in_pixels(draw_record.Draw_Picture{stride = 8, generation = 1}, 0, 0, 8, 8)
	testing.expect_value(t, execute_draw_table_in_rectangles_17(&now, &text, &picture_memory, &bytes, &shape, &places, nil), 0)
	for pixel, index in pixels {
		x, y := index % 8, index / 8
		expected: u32 = 0x123456
		if x >= 2 && x < 6 && y >= 2 && y < 6 {
			expected = u32(index) + 1
		}
		testing.expect_value(t, pixel, expected)
	}
}

// A Picture record of the format Straight_Alpha through the export: each
// pixel of the picture memory, of each alpha, blends over the pixels of the
// canvas by the rule of the colors, in the two rectangles of a damage, and
// gives the pixels of graphics.blend_copy with a table of the test. The
// same picture with the format Opaque and the same generation is another
// record: the difference damages its box.
@(test)
picture_with_alpha_through_the_exports :: proc(t: ^testing.T) {
	sync.mutex_lock(&draw_lock)
	defer sync.mutex_unlock(&draw_lock)
	table: [4096]u8
	graphics.square_root_table_fill(&table)
	SIDE :: 8
	pixels, expected: [SIDE * SIDE]u32
	for &pixel, index in pixels {
		pixel = u32(index) * 0x9E3779B1 & 0x00FFFFFF
	}
	expected = pixels
	alphas := [5]u32{0, 1, 128, 254, 255}
	picture_pixels: [4 * 4]u32
	for &pixel, index in picture_pixels {
		pixel = alphas[index % len(alphas)] << 24 | u32(index) * 0x00071F3B & 0x00FFFFFF
	}
	with_alpha := record_in_pixels(draw_record.Draw_Picture{format = .Straight_Alpha, stride = 4, generation = 1}, 1, 1, 5, 5)
	records := [1]interface.Draw_Record{with_alpha}
	now := system.Table_To_Read(interface.Draw_Record){records = &records[0], count = 1, capacity = 1}
	text := system.Bytes_To_Read{}
	picture_memory := system.Bytes_To_Read{bytes = ([^]u8)(&picture_pixels[0]), count = size_of(picture_pixels), capacity = size_of(picture_pixels)}
	bytes := system.Bytes_To_Change{bytes = ([^]u8)(&pixels[0]), count = size_of(pixels), capacity = size_of(pixels)}
	shape := Canvas_Shape{width = SIDE, height = SIDE, stride = SIDE}
	parts := [2]Damage_Rectangle{{0, 0, SIDE, 3}, {0, 3, SIDE, SIDE}}
	places := rectangles_to_read(parts[:])
	testing.expect_value(t, execute_draw_table_in_rectangles_17(&now, &text, &picture_memory, &bytes, &shape, &places, nil), 0)
	graphics.blend_copy({pixels = raw_data(expected[:]), width = SIDE, height = SIDE, stride = SIDE}, 1, 1, {pixels = raw_data(picture_pixels[:]), width = 4, height = 4, stride = 4}, &table)
	testing.expect(t, pixels == expected, "a picture with alpha through the export draws other pixels than blend_copy")
	// The format changes and the generation stays: the box is damaged.
	before_records := [1]interface.Draw_Record{record_in_pixels(draw_record.Draw_Picture{format = .Opaque, stride = 4, generation = 1}, 1, 1, 5, 5)}
	before := system.Table_To_Read(interface.Draw_Record){records = &before_records[0], count = 1, capacity = 1}
	damage: [RECTANGLE_CAPACITY]Damage_Rectangle
	result := damage[:]
	testing.expect_value(t, damage_of_draw_table_17(&before, &text, &now, &text, &result, nil), 1)
	testing.expect_value(t, damage[0], Damage_Rectangle{1, 1, 5, 5})
	// The same record in the two frames damages nothing.
	testing.expect_value(t, damage_of_draw_table_17(&now, &text, &now, &text, &result, nil), 0)
}

// The proof of the same pixels (docs/INTERFACE.md, section 7): the frames
// below are drawn two times, with the package as a window drew them before
// the module (the clear and the execution of a whole frame, then the
// difference and the draw of the damage), and through the two exports,
// with the argument forms of a caller. The damage rectangles are equal,
// and the two canvases are the same bytes after the whole frame and after
// the damage, in each font and each order of the stripes.

@(private = "file")
PROOF_WIDTH :: 400
@(private = "file")
PROOF_HEIGHT :: 240
// Three pixels more than the width: the pixels between two lines are not
// of the canvas, and no draw writes them.
@(private = "file")
PROOF_STRIDE :: PROOF_WIDTH + 3
@(private = "file")
PROOF_SEEDS :: 24
// The parts of a frame of build_proof_frame that a change can name.
@(private = "file")
PROOF_PARTS :: 35
@(private = "file")
GUARD_PIXEL :: 0xA5A5A5A5

// The picture memory of the frames of the proof: a pattern that differs at
// each pixel, so a picture at a wrong place or with a wrong stride shows.
@(private = "file")
PROOF_PICTURE_WIDTH :: 64
@(private = "file")
PROOF_PICTURE_HEIGHT :: 32
@(private = "file")
proof_picture_pixels: [PROOF_PICTURE_WIDTH * PROOF_PICTURE_HEIGHT]graphics.Color
@(private = "file")
proof_picture_memories: [1][]graphics.Color

@(private = "file")
Proof_Tables :: struct {
	records: [512]interface.Draw_Record,
	text:    [8192]u8,
}

// The generator of the tests: the same numbers on each host.
@(private = "file")
next_number :: proc(state: ^u32) -> int {
	state^ = state^ * 1664525 + 1013904223
	return int(state^ >> 8)
}

// pick gives the next number of the generator; for the part that changed,
// the number after it. The generator takes the same steps in both frames,
// so each other part is the same.
@(private = "file")
pick :: proc(state: ^u32, part: ^int, changed: int) -> int {
	number := next_number(state)
	if part^ == changed {
		number += 1
	}
	part^ += 1
	return number
}

// word and color give the next word and the next color of a frame.
@(private = "file")
word :: proc(list: []string, generator: ^u32, place: ^int, part_changed: int) -> string {
	return list[pick(generator, place, part_changed) % len(list)]
}

@(private = "file")
color :: proc(list: []graphics.Color, generator: ^u32, place: ^int, part_changed: int) -> graphics.Color {
	return list[pick(generator, place, part_changed) % len(list)]
}

// One frame with a record of each kind that the module draws: the
// elements of a window (a background with its grid of points, a card, a
// name with its value, a band, a cell, a bar, a large number), two
// pictures of one picture memory (the whole width of a part, and a part
// with a stride larger than its width), the two gradients, a folded gap, a
// line at an angle, an outline, a clip around two texts, the text of the
// cells at the three scales and in bold, and the text of the interface
// font at a third of a pixel, to the right, bold and at scale 2. The part
// `changed` differs from the frame with no change.
@(private = "file")
build_proof_frame :: proc(table: ^interface.Draw_Table, seed: u32, changed: int) {
	words := [?]string{"To", "LT", "Ty", "settings", "AVATAR", "Wave", "palette", "jj", "fill", "rings", "0O 1lI", "Monitor", "the clock", "W", "i", "{0}%e", "12:34:56"}
	colors := [?]graphics.Color{graphics.colors.text, graphics.colors.dim, graphics.colors.kernel, graphics.colors.process, graphics.colors.memory, graphics.colors.failed, graphics.COLOR_WHITE}
	state := seed
	part := 0
	interface.draw_table_clear(table)
	interface_state: interface.Interface_State
	input: interface.Input
	frame := interface.Frame{table = table, state = &interface_state, input = &input}
	interface.background(&frame, {0, 0, PROOF_WIDTH, PROOF_HEIGHT})
	memory := graphics.Canvas{pixels = raw_data(proof_picture_pixels[:]), width = PROOF_PICTURE_WIDTH, height = PROOF_PICTURE_HEIGHT, stride = PROOF_PICTURE_WIDTH}
	interface.draw_picture(table, 8, 214, graphics.view(memory, 0, 0, 40, 20), u32(pick(&state, &part, changed) % 3))
	interface.draw_picture(table, 52, 212, graphics.view(memory, pick(&state, &part, changed) % 16, pick(&state, &part, changed) % 8, 24, 20), 1)
	title := word(words[:], &state, &part, changed)
	caption := word(words[:], &state, &part, changed)
	content := interface.card(&frame, {8, 8, 236, 124}, title, caption, color(colors[:], &state, &part, changed))
	label := word(words[:], &state, &part, changed)
	value := word(words[:], &state, &part, changed)
	interface.label_value_line(&frame, {content.x, content.y, content.width, interface.TABLE_LINE}, label, value, color(colors[:], &state, &part, changed))
	interface.table_band(&frame, {content.x, content.y + 24, content.width, interface.TABLE_LINE}, pick(&state, &part, changed) % 2)
	cell := word(words[:], &state, &part, changed)
	interface.cell_text(&frame, {content.x, content.y + 24, content.width, interface.TABLE_LINE}, cell, color(colors[:], &state, &part, changed), pick(&state, &part, changed) % 2 == 0 ? .Left : .Right)
	interface.bar(&frame, {content.x, content.y + 56, content.width, 8}, u64(pick(&state, &part, changed) % 101), 100, color(colors[:], &state, &part, changed))
	interface.draw_vertical_gradient(table, 256, 8, 64, 40, color(colors[:], &state, &part, changed), graphics.colors.card_bottom)
	interface.draw_horizontal_gradient(table, 256, 56, 136, 24, graphics.colors.title, color(colors[:], &state, &part, changed))
	interface.draw_folded_gap(table, 328, 8, 40 + pick(&state, &part, changed) % 16, 16)
	interface.draw_line(table, 256 + pick(&state, &part, changed) % 100, 92, 384, 92 + pick(&state, &part, changed) % 36, 1 + pick(&state, &part, changed) % 4, color(colors[:], &state, &part, changed))
	interface.draw_outline(table, 250, 134, 144, 60, 2, color(colors[:], &state, &part, changed))
	// Two texts cut by two clips: the second passes the right edge of the
	// outer clip, and the inner clip, larger than the outer one, keeps it.
	interface.draw_clip_push(table, 256, 138, 120, 52)
	medium := word(words[:], &state, &part, changed)
	interface.draw_text(table, 250 + pick(&state, &part, changed) % 30, 140, medium, color(colors[:], &state, &part, changed), interface.FONT_MEDIUM)
	interface.draw_clip_push(table, 240, 160, 200 + pick(&state, &part, changed) % 20, 40)
	bold := word(words[:], &state, &part, changed)
	interface.draw_text(table, 300, 174, bold, graphics.colors.text, interface.FONT_BOLD)
	interface.draw_clip_pop(table)
	interface.draw_clip_pop(table)
	large := word(words[:], &state, &part, changed)
	interface.draw_text(table, 8, 140, large[:min(len(large), 5)], color(colors[:], &state, &part, changed), interface.FONT_LARGE)
	// The interface font, when the table has it; else the font of the cells.
	first := word(words[:], &state, &part, changed)
	interface.draw_text(table, 8 + pick(&state, &part, changed) % 5, 196, first, color(colors[:], &state, &part, changed), {kind = .Interface})
	second := word(words[:], &state, &part, changed)
	interface.draw_text_right(table, 240, 196, second, graphics.colors.text, {kind = .Interface, weight = .Bold})
	third := word(words[:], &state, &part, changed)
	interface.draw_text(table, 250, 204, third, color(colors[:], &state, &part, changed), {kind = .Interface, scale = 2})
}

// The fonts of the proof: the faces of the font outlines, the font of the
// cells (Paper Mono) and the two weights of the interface font (B612).
@(private = "file")
Proof_Fonts :: struct {
	interface_font: display.Interface_Font,
}

// The font outlines of the proof, opened once in the state of the text
// rendering of the test process, which the package and the exports share,
// with its glyph memory: a text is measured from its font file, and its
// glyphs are drawn into the private glyph cache. The words and the memory
// stay for the run, as the open fonts and the cache read them, so they
// come from the heap of the process.
@(private = "file")
proof_outlines_lock: sync.Mutex
@(private = "file")
proof_outlines_words: []u64

@(private = "file")
proof_outlines_open :: proc(t: ^testing.T) {
	sync.mutex_lock(&proof_outlines_lock)
	defer sync.mutex_unlock(&proof_outlines_lock)
	if proof_outlines_words != nil {
		return
	}
	fonts := [4]font_outlines.Font_Input {
		{"b612", #load("../../../../resources/fonts/b612.ttf")},
		{"b612_bold", #load("../../../../resources/fonts/b612_bold.ttf")},
		{"paper_mono", #load("../../../../resources/fonts/paper_mono.ttf")},
		{"paper_mono_semibold", #load("../../../../resources/fonts/paper_mono_semibold.ttf")},
	}
	size := font_outlines.resource_size(fonts[:])
	proof_outlines_words = make([]u64, (size + 7) / 8, runtime.heap_allocator())
	bytes := ([^]u8)(raw_data(proof_outlines_words))[:size]
	_, written := font_outlines.resource_write(fonts[:], bytes)
	testing.expect(t, written)
	outlines, problem := font_outlines.validate(bytes)
	testing.expect_value(t, problem.kind, font_outlines.Problem_Kind.None)
	text_rendering.memory_give(new(text_rendering.Glyph_Memory, runtime.heap_allocator()))
	_ = text_rendering.open(&outlines)
}

// proof_fonts_build opens the outlines once and gives the faces of the
// cells and of the bold weight to the text state of the process; the
// caller gives them back with proof_fonts_end.
@(private = "file")
proof_fonts_build :: proc(t: ^testing.T) -> (fonts: Proof_Fonts) {
	proof_outlines_open(t)
	testing.expect(t, display.interface_faces_opened())
	graphics.text_faces_use(.Cells, .Cells_Bold)
	testing.expect_value(t, graphics.text_state.cell_face, text_rendering.Face.Cells)
	testing.expect_value(t, graphics.text_state.bold_face, text_rendering.Face.Cells_Bold)
	return {interface_font = display.INTERFACE_FONT}
}

// proof_fonts_end gives the text state of the process back as a test found
// it: no face, the vector font, and no interface font in the module.
@(private = "file")
proof_fonts_end :: proc() {
	process_text = {}
	graphics.text_faces_use(.None, .None)
	graphics.text_choice_set(.Vector, .Red_Green_Blue)
}

// One font state of a process: the setting of the font of the cells, the
// order of the stripes, and whether the process has the interface font.
@(private = "file")
Proof_Configuration :: struct {
	name:           string,
	font:           graphics.Text_Font,
	order:          graphics.Subpixel_Order,
	interface_font: bool,
}

// first_difference gives the index of the first pixel that differs, or -1.
@(private = "file")
first_difference :: proc(first, second: []u32) -> int {
	for pixel, index in first {
		if pixel != second[index] {
			return index
		}
	}
	return -1
}

// draw_through_the_exports draws rectangles of a table through the export,
// with the fill of the background and the one picture memory of the
// table: one call for all the rectangles, as the window layer of the
// interface package calls it, or one call for each rectangle when
// one_call_for_each.
@(private = "file")
draw_through_the_exports :: proc(t: ^testing.T, table: ^interface.Draw_Table, pixels: []u32, rectangles: []Damage_Rectangle, fill_background: bool = true, one_call_for_each: bool = false) -> (calls: int) {
	now, now_text := records_to_read(table), text_to_read(table)
	picture_memory: system.Bytes_To_Read
	if len(table.picture_memories) == 1 {
		size := u64(len(table.picture_memories[0]) * size_of(graphics.Color))
		picture_memory = {bytes = ([^]u8)(raw_data(table.picture_memories[0])), count = size, capacity = size}
	}
	bytes := system.Bytes_To_Change{bytes = ([^]u8)(raw_data(pixels)), count = u64(len(pixels) * size_of(u32)), capacity = u64(len(pixels) * size_of(u32))}
	shape := Canvas_Shape{width = PROOF_WIDTH, height = PROOF_HEIGHT, stride = PROOF_STRIDE, fill_background = fill_background ? 1 : 0, background = i64(graphics.colors.background)}
	refused: errors.Error_Record
	if !one_call_for_each {
		places := rectangles_to_read(rectangles)
		testing.expect_value(t, execute_draw_table_in_rectangles_17(&now, &now_text, &picture_memory, &bytes, &shape, &places, &refused), 0)
		testing.expect_value(t, refused.kind, 0)
		return 1
	}
	for index in 0 ..< len(rectangles) {
		places := rectangles_to_read(rectangles[index:][:1])
		testing.expect_value(t, execute_draw_table_in_rectangles_17(&now, &now_text, &picture_memory, &bytes, &shape, &places, &refused), 0)
		testing.expect_value(t, refused.kind, 0)
		calls += 1
	}
	return calls
}

@(test)
the_exports_draw_the_same_bytes_as_the_package :: proc(t: ^testing.T) {
	sync.mutex_lock(&draw_lock)
	defer sync.mutex_unlock(&draw_lock)
	fonts := proof_fonts_build(t)
	defer proof_fonts_end()
	configurations := [?]Proof_Configuration {
		{"Spleen, no interface font", .Spleen, .Red_Green_Blue, false},
		{"the vector font, red green blue", .Vector, .Red_Green_Blue, false},
		{"the vector font, blue green red", .Vector, .Blue_Green_Red, false},
		{"the vector font, grayscale", .Vector, .None, false},
		{"the interface font, red green blue", .Vector, .Red_Green_Blue, true},
		{"the interface font, blue green red, over Spleen", .Spleen, .Blue_Green_Red, true},
		{"the interface font, grayscale", .Vector, .None, true},
	}
	before_memory := new(Proof_Tables)
	now_memory := new(Proof_Tables)
	defer free(before_memory)
	defer free(now_memory)
	package_pixels := make([]u32, PROOF_STRIDE * PROOF_HEIGHT)
	export_pixels := make([]u32, PROOF_STRIDE * PROOF_HEIGHT)
	defer delete(package_pixels)
	defer delete(export_pixels)
	package_canvas := graphics.Canvas{pixels = raw_data(package_pixels), width = PROOF_WIDTH, height = PROOF_HEIGHT, stride = PROOF_STRIDE}
	for &pixel, index in proof_picture_pixels {
		pixel = graphics.Color(u32(index) * 0x010307 + 0x204060)
	}
	proof_picture_memories[0] = proof_picture_pixels[:]
	frames, damage_rectangles, text_records, picture_records := 0, 0, 0, 0
	for configuration in configurations {
		graphics.text_choice_set(configuration.font, configuration.order)
		// The module reads the interface font of the process in its own
		// data; the package reads it in the draw table.
		process_text = {loaded = true, interface_font = fonts.interface_font, interface_font_given = configuration.interface_font}
		font_of_tables: ^display.Interface_Font
		if configuration.interface_font {
			font_of_tables = &fonts.interface_font
		}
		for seed in 0 ..< u32(PROOF_SEEDS) {
			before := interface.Draw_Table{records = before_memory.records[:], text = before_memory.text[:], picture_memories = proof_picture_memories[:], interface_font = font_of_tables}
			now := interface.Draw_Table{records = now_memory.records[:], text = now_memory.text[:], picture_memories = proof_picture_memories[:], interface_font = font_of_tables}
			build_proof_frame(&before, seed * 7919 + 1, -1)
			build_proof_frame(&now, seed * 7919 + 1, int(seed) % PROOF_PARTS)
			if !testing.expectf(t, !before.full && !before.refused && !now.full && !now.refused, "%s, seed %v: a frame did not fit its tables", configuration.name, seed) {
				return
			}
			for record in now.records[:now.record_count] {
				_, _, is_text := interface.text_of_record(&now, record)
				text_records += int(is_text)
				picture_records += int(kind_of(record) == .Picture)
			}
			for &pixel, index in package_pixels {
				pixel = GUARD_PIXEL
				export_pixels[index] = GUARD_PIXEL
			}
			// The whole frame.
			graphics.clear(package_canvas, graphics.colors.background)
			interface.execute(&before, package_canvas)
			whole := [1]Damage_Rectangle{{0, 0, PROOF_WIDTH, PROOF_HEIGHT}}
			draw_through_the_exports(t, &before, export_pixels, whole[:])
			if place := first_difference(package_pixels, export_pixels); !testing.expectf(t, place < 0, "%s, seed %v: the whole frame differs at x %v, y %v", configuration.name, seed, place % PROOF_STRIDE, place / PROOF_STRIDE) {
				return
			}
			// The damage: the rectangles, then the pixels.
			package_damage: interface.Damage
			interface.damage_by_difference(&before, &now, &package_damage)
			export_damage: [interface.DAMAGE_CAPACITY]Damage_Rectangle
			buffer := export_damage[:]
			before_records, before_text := records_to_read(&before), text_to_read(&before)
			now_records, now_text := records_to_read(&now), text_to_read(&now)
			refused: errors.Error_Record
			count := damage_of_draw_table_17(&before_records, &before_text, &now_records, &now_text, &buffer, &refused)
			if !testing.expect_value(t, count, i64(package_damage.count)) {
				return
			}
			for rectangle, index in package_damage.rectangles[:package_damage.count] {
				testing.expect_value(t, export_damage[index], Damage_Rectangle{i64(rectangle.left), i64(rectangle.top), i64(rectangle.right), i64(rectangle.bottom)})
			}
			interface.draw_damage_on_surface(&now, package_canvas, package_damage.rectangles[:package_damage.count])
			draw_through_the_exports(t, &now, export_pixels, export_damage[:count])
			if place := first_difference(package_pixels, export_pixels); !testing.expectf(t, place < 0, "%s, seed %v: the frame after the damage differs at x %v, y %v", configuration.name, seed, place % PROOF_STRIDE, place / PROOF_STRIDE) {
				return
			}
			// The pixels between two lines are of no canvas: nobody wrote them.
			for line in 0 ..< PROOF_HEIGHT {
				for column in PROOF_WIDTH ..< PROOF_STRIDE {
					testing.expect_value(t, export_pixels[line * PROOF_STRIDE + column], GUARD_PIXEL)
				}
			}
			// The damage was enough: the canvas is the canvas of a whole
			// frame of the table now.
			graphics.clear(package_canvas, graphics.colors.background)
			interface.execute(&now, package_canvas)
			if place := first_difference(package_pixels, export_pixels); !testing.expectf(t, place < 0, "%s, seed %v: the damage through the exports is not the whole frame at x %v, y %v", configuration.name, seed, place % PROOF_STRIDE, place / PROOF_STRIDE) {
				return
			}
			frames += 2
			damage_rectangles += int(count)
		}
	}
	// One frame must change something, and the frames must hold text: a
	// proof over empty frames proves nothing.
	testing.expect(t, damage_rectangles > 0, "no frame had damage")
	testing.expect(t, text_records > 0, "no frame had text")
	testing.expect(t, picture_records > 0, "no frame had a picture")
	log.infof("the exports and the package drew the same bytes: %v frames of %v x %v pixels in %v font states, %v damage rectangles, %v text records, %v picture records", frames, PROOF_WIDTH, PROOF_HEIGHT, len(configurations), damage_rectangles, text_records, picture_records)
}

// The proof of the rectangles in one call (src/md/api/picture.md, "The draw
// export: the rectangles of a frame in one call"): a frame of each kind of
// record, drawn in 1 to 8 rectangles that the seed chooses, three times:
// one call of the export with the N rectangles, N calls with one rectangle
// each, and the package. The rectangles overlap, pass the edges of the
// canvas, and are empty now and then. With the fill of the background the
// package is draw_damage_on_surface; with none, execute_in_rectangles over
// the pixels of a whole frame. The three canvases are the same bytes.

// proof_rectangle gives a rectangle from the generator: most in the canvas,
// some that pass an edge, and some empty.
@(private = "file")
proof_rectangle :: proc(state: ^u32) -> Damage_Rectangle {
	left := i64(next_number(state) % (PROOF_WIDTH + 40)) - 20
	top := i64(next_number(state) % (PROOF_HEIGHT + 40)) - 20
	width := i64(next_number(state) % 160)
	height := i64(next_number(state) % 120)
	if next_number(state) % 9 == 0 {
		width = 0
	}
	return {left, top, left + width, top + height}
}

@(test)
one_call_with_the_rectangles_draws_as_one_call_for_each :: proc(t: ^testing.T) {
	sync.mutex_lock(&draw_lock)
	defer sync.mutex_unlock(&draw_lock)
	fonts := proof_fonts_build(t)
	defer proof_fonts_end()
	configurations := [?]Proof_Configuration {
		{"Spleen, no interface font", .Spleen, .Red_Green_Blue, false},
		{"the interface font, red green blue", .Vector, .Red_Green_Blue, true},
	}
	table_memory := new(Proof_Tables)
	defer free(table_memory)
	package_pixels := make([]u32, PROOF_STRIDE * PROOF_HEIGHT)
	each_pixels := make([]u32, PROOF_STRIDE * PROOF_HEIGHT)
	one_call_pixels := make([]u32, PROOF_STRIDE * PROOF_HEIGHT)
	defer delete(package_pixels)
	defer delete(each_pixels)
	defer delete(one_call_pixels)
	package_canvas := graphics.Canvas{pixels = raw_data(package_pixels), width = PROOF_WIDTH, height = PROOF_HEIGHT, stride = PROOF_STRIDE}
	for &pixel, index in proof_picture_pixels {
		pixel = graphics.Color(u32(index) * 0x010307 + 0x204060)
	}
	proof_picture_memories[0] = proof_picture_pixels[:]
	frames, rectangles_drawn, overlaps, one_calls, calls_for_each := 0, 0, 0, 0, 0
	for configuration in configurations {
		graphics.text_choice_set(configuration.font, configuration.order)
		process_text = {loaded = true, interface_font = fonts.interface_font, interface_font_given = configuration.interface_font}
		font_of_table: ^display.Interface_Font
		if configuration.interface_font {
			font_of_table = &fonts.interface_font
		}
		for seed in 0 ..< u32(PROOF_SEEDS) {
			table := interface.Draw_Table{records = table_memory.records[:], text = table_memory.text[:], picture_memories = proof_picture_memories[:], interface_font = font_of_table}
			build_proof_frame(&table, seed * 7919 + 1, int(seed) % PROOF_PARTS)
			if !testing.expectf(t, !table.full && !table.refused, "%s, seed %v: the frame did not fit its tables", configuration.name, seed) {
				return
			}
			state := seed * 2654435761 + 17
			rectangles: [RECTANGLE_CAPACITY]Damage_Rectangle
			count := 1 + int(seed) % RECTANGLE_CAPACITY
			for index in 0 ..< count {
				rectangles[index] = proof_rectangle(&state)
			}
			package_rectangles: [RECTANGLE_CAPACITY]interface.Rectangle
			for rectangle, index in rectangles[:count] {
				package_rectangles[index] = {int(rectangle.left), int(rectangle.top), int(rectangle.right), int(rectangle.bottom)}
				for other in rectangles[:index] {
					overlaps += int(rectangle.left < other.right && other.left < rectangle.right && rectangle.top < other.bottom && other.top < rectangle.bottom)
				}
			}
			fills := [2]bool{true, false}
			for fill_background in fills {
				// The three canvases start as the same pattern that is not
				// the background, so a draw with no fill draws over pixels
				// that differ from place to place. The pixels between two
				// lines are guards that no draw writes.
				graphics.clear(package_canvas, graphics.colors.background)
				for place in 0 ..< PROOF_STRIDE * PROOF_HEIGHT {
					if place % PROOF_STRIDE >= PROOF_WIDTH {
						package_pixels[place] = GUARD_PIXEL
					}
				}
				for line in 0 ..< PROOF_HEIGHT {
					for column in 0 ..< PROOF_WIDTH {
						package_pixels[line * PROOF_STRIDE + column] ~= u32(line * 7 + column * 3) & 0x3F3F3F
					}
				}
				copy(each_pixels, package_pixels)
				copy(one_call_pixels, package_pixels)
				if fill_background {
					interface.draw_damage_on_surface(&table, package_canvas, package_rectangles[:count])
				} else {
					interface.execute_in_rectangles(&table, package_canvas, package_rectangles[:count])
				}
				calls_for_each += draw_through_the_exports(t, &table, each_pixels, rectangles[:count], fill_background, true)
				one_calls += draw_through_the_exports(t, &table, one_call_pixels, rectangles[:count], fill_background, false)
				if place := first_difference(each_pixels, one_call_pixels); !testing.expectf(t, place < 0, "%s, seed %v, fill %v: one call of %v rectangles differs from one call for each at x %v, y %v", configuration.name, seed, fill_background, count, place % PROOF_STRIDE, place / PROOF_STRIDE) {
					return
				}
				if place := first_difference(package_pixels, one_call_pixels); !testing.expectf(t, place < 0, "%s, seed %v, fill %v: one call of %v rectangles differs from the package at x %v, y %v", configuration.name, seed, fill_background, count, place % PROOF_STRIDE, place / PROOF_STRIDE) {
					return
				}
				frames += 1
				rectangles_drawn += count
			}
		}
	}
	// The proof needs rectangles that overlap, and frames of several
	// rectangles: one rectangle for each frame proves nothing of the order.
	testing.expect(t, overlaps > 0, "no two rectangles of a frame overlapped")
	testing.expect(t, rectangles_drawn > frames, "no frame had more than one rectangle")
	log.infof("one call with the rectangles drew the same bytes as one call for each rectangle and as the package: %v frames, %v rectangles, %v of them overlapping another, %v calls in place of %v", frames, rectangles_drawn, overlaps, one_calls, calls_for_each)
}

// The proof of the same pixels for a text grid (src/md/api/text_grid.md):
// the frames of a terminal, with runs of one color, spaces in a run, empty
// cells at the end of a line, reverse cells, and a completion list of
// filled cells with its border drawn over the grid. The frame now changes
// some cells, and moves the cells in the text table with a status of
// another length. The package and the exports give the same damage
// rectangles and the same bytes of the canvas, in the font of the cells
// and in the vector font.

@(private = "file")
GRID_COLUMNS :: 40
@(private = "file")
GRID_ROWS :: 12

// The tables of a frame with a grid: the text table is words, so it starts
// at an address that is a multiple of 4, as the cells must.
@(private = "file")
Grid_Proof_Tables :: struct {
	records: [64]interface.Draw_Record,
	text:    [3072]u32, // The cells of the grid (16 bytes each) and the text of the head.
}

@(private = "file")
grid_proof_table :: proc(memory: ^Grid_Proof_Tables) -> interface.Draw_Table {
	return {records = memory.records[:], text = ([^]u8)(&memory.text[0])[:len(memory.text) * 4]}
}

// grid_proof_cells fills the cells of a terminal from a seed.
@(private = "file")
grid_proof_cells :: proc(cells: []interface.Text_Grid_Cell, seed: u32) {
	state := seed
	colors := [?]graphics.Color{graphics.colors.text, graphics.colors.dim, graphics.colors.kernel, graphics.colors.process, graphics.COLOR_WHITE}
	characters := "let x = 12; -- the line {0}%e Wave jj"
	for &cell, index in cells {
		row, column := index / GRID_COLUMNS, index % GRID_COLUMNS
		number := next_number(&state)
		cell = {character = rune(characters[(column + row * 3 + number % 3) % len(characters)]), color = colors[(column / 5 + row) % len(colors)]}
		if column >= 30 + row % 7 {
			cell.character = 0 // The end of a line.
		}
		if number % 29 == 0 {
			cell.reverse = true
		}
		if row >= 3 && row < 7 && column >= 10 && column < 26 {
			chosen := row == 4
			cell = {character = column < 20 ? rune(characters[column % len(characters)]) : 0, filled = true, color = chosen ? graphics.COLOR_WHITE : graphics.colors.text, background = chosen ? graphics.colors.chosen : graphics.colors.card_top}
		}
	}
}

// build_grid_frame builds a frame of a terminal: a head with a status, the
// grid, and the border of the completion list after the grid.
@(private = "file")
build_grid_frame :: proc(table: ^interface.Draw_Table, cells: []interface.Text_Grid_Cell, status: string) {
	interface.draw_table_clear(table)
	interface.draw_rectangle(table, 0, 0, PROOF_WIDTH, 20, graphics.colors.card_top)
	interface.draw_text(table, 8, 2, status, graphics.colors.text)
	interface.draw_text_grid(table, 8, 24, {cells = cells, columns = GRID_COLUMNS, rows = GRID_ROWS, stride = GRID_COLUMNS})
	interface.draw_outline(table, 8 + 10 * graphics.CELL_WIDTH - 1, 24 + 3 * graphics.CELL_HEIGHT - 1, 16 * graphics.CELL_WIDTH + 2, 4 * graphics.CELL_HEIGHT + 2, 1, graphics.colors.kernel)
}

@(test)
the_exports_draw_a_text_grid_as_the_package :: proc(t: ^testing.T) {
	sync.mutex_lock(&draw_lock)
	defer sync.mutex_unlock(&draw_lock)
	_ = proof_fonts_build(t)
	defer proof_fonts_end()
	fonts_of_the_cells := [2]graphics.Text_Font{.Spleen, .Vector}
	before_memory := new(Grid_Proof_Tables)
	now_memory := new(Grid_Proof_Tables)
	defer free(before_memory)
	defer free(now_memory)
	cells_before := make([]interface.Text_Grid_Cell, GRID_COLUMNS * GRID_ROWS)
	cells_now := make([]interface.Text_Grid_Cell, GRID_COLUMNS * GRID_ROWS)
	defer delete(cells_before)
	defer delete(cells_now)
	package_pixels := make([]u32, PROOF_STRIDE * PROOF_HEIGHT)
	export_pixels := make([]u32, PROOF_STRIDE * PROOF_HEIGHT)
	defer delete(package_pixels)
	defer delete(export_pixels)
	package_canvas := graphics.Canvas{pixels = raw_data(package_pixels), width = PROOF_WIDTH, height = PROOF_HEIGHT, stride = PROOF_STRIDE}
	frames, damage_rectangles, grid_records := 0, 0, 0
	for font in fonts_of_the_cells {
		graphics.text_choice_set(font, .Red_Green_Blue)
		process_text = {loaded = true}
		for seed in 0 ..< u32(PROOF_SEEDS) {
			grid_proof_cells(cells_before, seed * 7919 + 1)
			copy(cells_now, cells_before)
			state := seed * 31 + 7
			for change in 0 ..< 1 + int(seed % 4) {
				index := next_number(&state) % len(cells_now)
				cells_now[index].character = rune('Q' + change)
				if seed % 5 == 0 {
					cells_now[index].reverse = !cells_now[index].reverse
				}
				if seed % 7 == 0 {
					cells_now[index].color = graphics.colors.failed
				}
			}
			before := grid_proof_table(before_memory)
			now := grid_proof_table(now_memory)
			build_grid_frame(&before, cells_before, "lines 1 to 12 of 40")
			// A status of 21 bytes in place of 19: the cells start at byte
			// 24 in place of byte 20 of the text table.
			build_grid_frame(&now, cells_now, seed % 2 == 0 ? "lines 1 to 12 of 40" : "held at lines 2 to 13")
			if !testing.expectf(t, !before.full && !before.refused && !now.full && !now.refused, "seed %v: a frame did not fit its tables", seed) {
				return
			}
			for record in now.records[:now.record_count] {
				grid_records += int(kind_of(record) == .Text_Grid)
			}
			for &pixel, index in package_pixels {
				pixel = GUARD_PIXEL
				export_pixels[index] = GUARD_PIXEL
			}
			graphics.clear(package_canvas, graphics.colors.background)
			interface.execute(&before, package_canvas)
			whole := [1]Damage_Rectangle{{0, 0, PROOF_WIDTH, PROOF_HEIGHT}}
			draw_through_the_exports(t, &before, export_pixels, whole[:])
			if place := first_difference(package_pixels, export_pixels); !testing.expectf(t, place < 0, "%v, seed %v: the whole grid differs at x %v, y %v", font, seed, place % PROOF_STRIDE, place / PROOF_STRIDE) {
				return
			}
			package_damage: interface.Damage
			interface.damage_by_difference(&before, &now, &package_damage)
			export_damage: [interface.DAMAGE_CAPACITY]Damage_Rectangle
			buffer := export_damage[:]
			before_records, before_text := records_to_read(&before), text_to_read(&before)
			now_records, now_text := records_to_read(&now), text_to_read(&now)
			refused: errors.Error_Record
			count := damage_of_draw_table_17(&before_records, &before_text, &now_records, &now_text, &buffer, &refused)
			if !testing.expect_value(t, count, i64(package_damage.count)) {
				return
			}
			for rectangle, index in package_damage.rectangles[:package_damage.count] {
				testing.expect_value(t, export_damage[index], Damage_Rectangle{i64(rectangle.left), i64(rectangle.top), i64(rectangle.right), i64(rectangle.bottom)})
			}
			interface.draw_damage_on_surface(&now, package_canvas, package_damage.rectangles[:package_damage.count])
			draw_through_the_exports(t, &now, export_pixels, export_damage[:count])
			if place := first_difference(package_pixels, export_pixels); !testing.expectf(t, place < 0, "%v, seed %v: the grid after the damage differs at x %v, y %v", font, seed, place % PROOF_STRIDE, place / PROOF_STRIDE) {
				return
			}
			// The damage was enough: the canvas is the frame now drawn whole.
			graphics.clear(package_canvas, graphics.colors.background)
			interface.execute(&now, package_canvas)
			if place := first_difference(package_pixels, export_pixels); !testing.expectf(t, place < 0, "%v, seed %v: the damage of the grid through the exports is not the whole frame at x %v, y %v", font, seed, place % PROOF_STRIDE, place / PROOF_STRIDE) {
				return
			}
			frames += 2
			damage_rectangles += int(count)
		}
	}
	testing.expect(t, damage_rectangles > 0, "no frame had damage")
	testing.expect(t, grid_records > 0, "no frame had a grid")
	log.infof("the exports and the package drew the same bytes for a text grid: %v frames of %v x %v cells in %v fonts of the cells, %v damage rectangles", frames, GRID_COLUMNS, GRID_ROWS, len(fonts_of_the_cells), damage_rectangles)
}

// The proof of the parts of a screen (src/md/api/picture.md, "The
// compositor: one call for each part"): windows that overlap, each with a
// frame, a title and a surface in a picture memory of its own, then a bar
// with a heron in one more memory, over a background picture. The package
// draws the whole table in each damage rectangle, with the list of all the
// memories, one rectangle after the other. The exports draw as the
// compositor does: the background in each rectangle, then one call for
// each part, with the one memory of the part and all the rectangles of the
// frame. The rectangles of a frame do not touch, as the damage of the
// compositor. The two canvases are the same bytes after each frame.

@(private = "file")
SURFACE_COUNT :: 4

// One part of the table of the screen: its records and its memory.
@(private = "file")
Screen_Proof_Part :: struct {
	first, count: int,
	memory:       []graphics.Color,
}

// build_screen_proof builds the table of a screen. in_parts: each Picture
// record names memory 0 of the list of its part, and parts gets the parts;
// else each record names its memory in the list of all the memories.
@(private = "file")
build_screen_proof :: proc(table: ^interface.Draw_Table, surfaces: []graphics.Canvas, memories: [][]graphics.Color, seed: int, in_parts: bool, parts: []Screen_Proof_Part) -> (part_count: int) {
	interface.draw_table_clear(table)
	one: [1][]graphics.Color
	for surface, index in surfaces {
		first := table.record_count
		x, y := 12 + index * 70 + seed % 13, 26 + index * 30 + seed % 7
		interface.draw_horizontal_gradient(table, x, y, surface.width + 4, 20, graphics.colors.title, graphics.colors.card_top)
		interface.draw_rectangle(table, x, y + 20, 2, surface.height, graphics.colors.title)
		interface.draw_rectangle(table, x + surface.width + 2, y + 20, 2, surface.height, graphics.colors.card_top)
		interface.draw_text(table, x + 4, y + 2, index % 2 == 0 ? "life" : "monitor", graphics.COLOR_WHITE)
		table.picture_memories = memories
		if in_parts {
			one[0] = memories[index]
			table.picture_memories = one[:]
		}
		interface.draw_picture(table, x + 2, y + 20, surface, 1)
		table.picture_memories = nil
		if in_parts {
			parts[part_count] = {first = first, count = table.record_count - first, memory = memories[index]}
			part_count += 1
		}
	}
	first := table.record_count
	interface.draw_vertical_gradient(table, 0, 0, PROOF_WIDTH, 23, graphics.colors.card_top, graphics.colors.card_bottom)
	interface.draw_rectangle(table, 0, 23, PROOF_WIDTH, 1, graphics.colors.track)
	heron := memories[len(memories) - 1]
	table.picture_memories = memories
	if in_parts {
		one[0] = heron
		table.picture_memories = one[:]
	}
	interface.draw_picture(table, 4, 4, {pixels = raw_data(heron), width = 16, height = 16, stride = 16}, 1)
	table.picture_memories = nil
	interface.draw_text(table, PROOF_WIDTH - 72, 4, "12:34:56", graphics.colors.text)
	if in_parts {
		parts[part_count] = {first = first, count = table.record_count - first, memory = heron}
		part_count += 1
	}
	return part_count
}

@(test)
the_parts_of_a_screen_draw_the_same_bytes_as_the_package :: proc(t: ^testing.T) {
	sync.mutex_lock(&draw_lock)
	defer sync.mutex_unlock(&draw_lock)
	defer {
		process_text = {}
		graphics.text_choice_set(.Vector, .Red_Green_Blue)
	}
	graphics.text_choice_set(.Spleen, .Red_Green_Blue)
	process_text = {loaded = true}
	// Each surface in an allocation of its own, with a stride larger than
	// its width; the heron is the last memory.
	sizes := [SURFACE_COUNT][2]int{{64, 40}, {96, 56}, {48, 48}, {120, 32}}
	surfaces: [SURFACE_COUNT]graphics.Canvas
	memories: [SURFACE_COUNT + 1][]graphics.Color
	for size, index in sizes {
		stride := size[0] + 5
		memories[index] = make([]graphics.Color, stride * size[1])
		for &pixel, place in memories[index] {
			pixel = graphics.Color(u32(place) * 0x010307 + u32(index) * 0x305070)
		}
		surfaces[index] = {pixels = raw_data(memories[index]), width = size[0], height = size[1], stride = stride}
	}
	memories[SURFACE_COUNT] = make([]graphics.Color, 16 * 16)
	for &pixel, place in memories[SURFACE_COUNT] {
		pixel = graphics.Color(u32(place) * 0x0A0B0C)
	}
	defer {
		for memory in memories {
			delete(memory)
		}
	}
	background_pixels := make([]u32, PROOF_STRIDE * PROOF_HEIGHT)
	defer delete(background_pixels)
	for &pixel, place in background_pixels {
		pixel = u32(place % 24 < 2 ? graphics.colors.point : graphics.colors.background)
	}
	background := graphics.Canvas{pixels = raw_data(background_pixels), width = PROOF_WIDTH, height = PROOF_HEIGHT, stride = PROOF_STRIDE}
	package_memory := new(Proof_Tables)
	parts_memory := new(Proof_Tables)
	defer free(package_memory)
	defer free(parts_memory)
	package_pixels := make([]u32, PROOF_STRIDE * PROOF_HEIGHT)
	export_pixels := make([]u32, PROOF_STRIDE * PROOF_HEIGHT)
	defer delete(package_pixels)
	defer delete(export_pixels)
	package_canvas := graphics.Canvas{pixels = raw_data(package_pixels), width = PROOF_WIDTH, height = PROOF_HEIGHT, stride = PROOF_STRIDE}
	export_canvas := graphics.Canvas{pixels = raw_data(export_pixels), width = PROOF_WIDTH, height = PROOF_HEIGHT, stride = PROOF_STRIDE}
	bytes := system.Bytes_To_Change{bytes = ([^]u8)(raw_data(export_pixels)), count = u64(len(export_pixels) * size_of(u32)), capacity = u64(len(export_pixels) * size_of(u32))}
	// Two frames: the whole screen, then 8 rectangles that do not touch: a
	// rectangle over three windows, two of the bar, a tall one over the
	// windows, and slivers that cut a picture and a text.
	whole_screen := [1]Damage_Rectangle{{0, 0, PROOF_WIDTH, PROOF_HEIGHT}}
	apart := [8]Damage_Rectangle{{0, 0, 40, 30}, {50, 40, 170, 120}, {180, 10, 260, 200}, {97, 130, 99, PROOF_HEIGHT}, {0, 61, 40, 64}, {270, 0, PROOF_WIDTH, 23}, {300, 200, PROOF_WIDTH, PROOF_HEIGHT}, {120, 125, 170, 129}}
	frames_of_rectangles := [2][]Damage_Rectangle{whole_screen[:], apart[:]}
	for rectangles in frames_of_rectangles {
		for first, index in rectangles {
			for second in rectangles[index + 1:] {
				touch := first.left <= second.right && second.left <= first.right && first.top <= second.bottom && second.top <= first.bottom
				testing.expectf(t, !touch, "the rectangles %v and %v of one frame touch: the compositor never draws such a frame", first, second)
			}
		}
	}
	parts: [SURFACE_COUNT + 1]Screen_Proof_Part
	calls, calls_for_each_rectangle, picture_records := 0, 0, 0
	for seed in 0 ..< PROOF_SEEDS {
		package_table := interface.Draw_Table{records = package_memory.records[:], text = package_memory.text[:]}
		parts_table := interface.Draw_Table{records = parts_memory.records[:], text = parts_memory.text[:]}
		_ = build_screen_proof(&package_table, surfaces[:], memories[:], seed, false, nil)
		part_count := build_screen_proof(&parts_table, surfaces[:], memories[:], seed, true, parts[:])
		if !testing.expectf(t, !package_table.refused && !parts_table.refused && !package_table.full && !parts_table.full, "seed %v: a screen did not fit its tables", seed) {
			return
		}
		testing.expect_value(t, part_count, SURFACE_COUNT + 1)
		for record in parts_table.records[:parts_table.record_count] {
			primitive, _ := draw_record.read(record)
			if picture_fields, is_picture := primitive.(draw_record.Draw_Picture); is_picture {
				picture_records += 1
				testing.expect_value(t, picture_fields.memory, 0)
			}
		}
		package_table.picture_memories = memories[:]
		for &pixel, index in package_pixels {
			pixel = GUARD_PIXEL
			export_pixels[index] = GUARD_PIXEL
		}
		for rectangles in frames_of_rectangles {
			// The package: each rectangle with all its steps, one after the
			// other, as the compositor drew before.
			for rectangle in rectangles {
				area := interface.Rectangle{int(rectangle.left), int(rectangle.top), int(rectangle.right), int(rectangle.bottom)}
				graphics.copy(graphics.view(package_canvas, area.left, area.top, area.right - area.left, area.bottom - area.top), -area.left, -area.top, background)
				interface.execute_in_rectangle(&package_table, package_canvas, area)
			}
			// The exports, in the phases of the compositor: the background
			// in each rectangle, then one call for each part with all the
			// rectangles.
			for rectangle in rectangles {
				left, top := int(rectangle.left), int(rectangle.top)
				graphics.copy(graphics.view(export_canvas, left, top, int(rectangle.right) - left, int(rectangle.bottom) - top), -left, -top, background)
			}
			now_text := text_to_read(&parts_table)
			places := rectangles_to_read(rectangles)
			for part in parts[:part_count] {
				records := system.Table_To_Read(interface.Draw_Record){records = &parts_table.records[part.first], count = u64(part.count), capacity = u64(part.count)}
				memory_size := u64(len(part.memory) * size_of(graphics.Color))
				picture_memory := system.Bytes_To_Read{bytes = ([^]u8)(raw_data(part.memory)), count = memory_size, capacity = memory_size}
				shape := Canvas_Shape{width = PROOF_WIDTH, height = PROOF_HEIGHT, stride = PROOF_STRIDE}
				refused: errors.Error_Record
				testing.expect_value(t, execute_draw_table_in_rectangles_17(&records, &now_text, &picture_memory, &bytes, &shape, &places, &refused), 0)
				testing.expect_value(t, refused.kind, 0)
				calls += 1
			}
			calls_for_each_rectangle += part_count * len(rectangles)
			if place := first_difference(package_pixels, export_pixels); !testing.expectf(t, place < 0, "seed %v, a frame of %v rectangles: the parts differ from the package at x %v, y %v", seed, len(rectangles), place % PROOF_STRIDE, place / PROOF_STRIDE) {
				return
			}
		}
		for line in 0 ..< PROOF_HEIGHT {
			for column in PROOF_WIDTH ..< PROOF_STRIDE {
				testing.expect_value(t, export_pixels[line * PROOF_STRIDE + column], GUARD_PIXEL)
			}
		}
	}
	testing.expect(t, picture_records > 0, "no screen had a picture")
	log.infof("the parts of a screen drew the same bytes as the package: %v screens of %v surfaces and a heron, %v calls of the export, where one call for each part and each rectangle makes %v", PROOF_SEEDS, SURFACE_COUNT, calls, calls_for_each_rectangle)
}

// A terminal that scrolls, drawn through the exports into the two pictures
// of a surface, as the window layer draws it (src/library/support/interface,
// window_drawing.odin): the difference with the last table that was
// presented, the draw of the changed rectangles and of the debt of the
// picture, the present of the rectangle where the screen differs, and the
// copy of the table after a present. The frames scroll by no line, by a few
// lines, by more than the rows, and by many thousand lines; a line now and
// then is empty, as a line that the terminal no longer keeps; an error has
// its label in filled cells; the bars of the head come and go, so the grid
// record moves in the table; a thumb moves at places that are not on the
// rows; a status of another length moves the cells in the text table. One
// Present in 16 is lost, and one frame in 50 has a new font. After each
// frame the picture and a screen that takes each presented rectangle are
// the frame drawn whole by the package.

@(private = "file")
SCROLL_FRAMES :: 600

// scroll_put writes a text into a row of cells from a column, and gives the
// column after it.
@(private = "file")
scroll_put :: proc(row: []interface.Text_Grid_Cell, column: int, text: string, color: graphics.Color, background: graphics.Color = 0) -> int {
	place := column
	for character in transmute([]u8)text {
		if place >= len(row) {
			break
		}
		row[place] = {character = rune(character), color = color, filled = background != 0, background = background}
		place += 1
	}
	return place
}

// scroll_line_cells writes the line `number` of the terminal into a row:
// its number in 10 digits, its level, its text. A line whose number is a
// multiple of 37 is empty.
@(private = "file")
scroll_line_cells :: proc(row: []interface.Text_Grid_Cell, number: u64) {
	for &cell in row {
		cell = {}
	}
	if number % 37 == 0 {
		return
	}
	digits: [10]u8
	rest := number
	for place := 9; place >= 0; place -= 1 {
		digits[place] = u8('0' + rest % 10)
		rest /= 10
	}
	levels := [4]string{"info", "debug", "warning", "error"}
	messages := [5]string{"the queue was full: the writer waited", "the block 81 244 has the hash", "the line left the view", "a process gave a handle", "one wake for 2048 records"}
	column := scroll_put(row, 0, string(digits[:]), graphics.colors.dim)
	level := levels[number % 4]
	column = scroll_put(row, column + 1, level, level == "error" ? graphics.COLOR_WHITE : graphics.colors.process, level == "error" ? graphics.colors.failed : 0)
	scroll_put(row, column + 1, messages[number % 5], graphics.colors.text)
}

// build_scrolling_frame builds the frame of a terminal whose first row
// shows the line `top`.
@(private = "file")
build_scrolling_frame :: proc(table: ^interface.Draw_Table, cells: []interface.Text_Grid_Cell, top: u64, frame: int) {
	interface.draw_table_clear(table)
	// The bars of the head: a bar of 0 or of the full height has no record
	// for one of its two parts.
	state := u32(frame) * 2654435761 + 1
	for bar in 0 ..< 12 {
		height := next_number(&state) % 4 * 4
		interface.draw_rectangle(table, 200 + bar * 6, 4, 5, 12 - height, graphics.colors.track)
		interface.draw_rectangle(table, 200 + bar * 6, 16 - height, 5, height, graphics.colors.process)
	}
	x := interface.draw_text(table, 8, 4, "lines ", graphics.colors.dim)
	x = interface.draw_unsigned(table, x, 4, top + 1, graphics.colors.text)
	for row in 0 ..< GRID_ROWS {
		scroll_line_cells(cells[row * GRID_COLUMNS:][:GRID_COLUMNS], top + u64(row))
	}
	interface.draw_text_grid(table, 8, 24, {cells = cells, columns = GRID_COLUMNS, rows = GRID_ROWS, stride = GRID_COLUMNS})
	interface.draw_rectangle(table, 0, 24 + GRID_ROWS * graphics.CELL_HEIGHT + 2, PROOF_WIDTH, 1, graphics.colors.track)
	interface.draw_unsigned(table, 8, 24 + GRID_ROWS * graphics.CELL_HEIGHT + 4, top + GRID_ROWS, graphics.colors.text)
	// The thumb of the scroll bar, at places that are not on the rows.
	interface.draw_rectangle(table, 336 + 8, 24 + int(top * 7 % 170), 6, 13, graphics.colors.dim)
}

@(test)
a_scrolling_grid_in_two_pictures_is_each_frame :: proc(t: ^testing.T) {
	sync.mutex_lock(&draw_lock)
	defer sync.mutex_unlock(&draw_lock)
	defer {
		process_text = {}
		graphics.text_choice_set(.Vector, .Red_Green_Blue)
	}
	graphics.text_choice_set(.Spleen, .Red_Green_Blue)
	process_text = {loaded = true}
	before_memory := new(Grid_Proof_Tables)
	now_memory := new(Grid_Proof_Tables)
	defer free(before_memory)
	defer free(now_memory)
	cells := make([]interface.Text_Grid_Cell, GRID_COLUMNS * GRID_ROWS)
	defer delete(cells)
	// Pixels that no frame draws: a picture or a screen that the rule takes
	// for the frame while it is not shows them.
	NEVER_DRAWN :: 0xFF00FF
	buffers: [4][]u32
	for &buffer in buffers {
		buffer = make([]u32, PROOF_STRIDE * PROOF_HEIGHT)
		for &pixel in buffer {
			pixel = NEVER_DRAWN
		}
	}
	defer {
		for buffer in buffers {
			delete(buffer)
		}
	}
	pictures := [2][]u32{buffers[0], buffers[1]}
	screen, whole := buffers[2], buffers[3]
	whole_canvas := graphics.Canvas{pixels = raw_data(whole), width = PROOF_WIDTH, height = PROOF_HEIGHT, stride = PROOF_STRIDE}
	surface := interface.Rectangle{0, 0, PROOF_WIDTH, PROOF_HEIGHT}
	before := grid_proof_table(before_memory)
	now := grid_proof_table(now_memory)
	debts: interface.Picture_Debts
	drawn := false // The table before is the last frame that was presented.
	picture := 0
	top: u64 = 1000
	seed: u32 = 11
	presented_frames, lost_presents, frames_with_no_present, long_scrolls := 0, 0, 0, 0
	for frame in 0 ..< SCROLL_FRAMES {
		seed = seed * 1103515245 + 12345
		chance := int(seed >> 16) % 16
		switch chance % 4 {
		case 1:
			top += u64(1 + chance)
		case 2:
			top += u64(GRID_ROWS + chance)
		case 3:
			top += 84_000 + u64(chance)
			long_scrolls += 1
		}
		build_scrolling_frame(&now, cells, top, chance == 0 ? frame - 1 : frame)
		if !testing.expectf(t, !now.full && !now.refused, "frame %v did not fit its tables", frame) {
			return
		}
		if frame % 50 == 49 {
			debts = {} // A new font: draw_whole_window_next.
		}
		// The reference: the frame drawn whole by the package.
		graphics.clear(whole_canvas, graphics.colors.background)
		interface.execute(&now, whole_canvas)
		// The difference through the export, as frame_difference.
		changed: interface.Damage
		if drawn && !before.full {
			buffer := ([^]Damage_Rectangle)(&changed.rectangles[0])[:interface.DAMAGE_CAPACITY]
			before_records, before_text := records_to_read(&before), text_to_read(&before)
			now_records, now_text := records_to_read(&now), text_to_read(&now)
			count := damage_of_draw_table_17(&before_records, &before_text, &now_records, &now_text, &buffer, nil)
			if !testing.expectf(t, count >= 0, "frame %v: the difference was refused", frame) {
				return
			}
			changed.count = int(min(count, interface.DAMAGE_CAPACITY))
		} else {
			debts = {}
		}
		draw, present: interface.Damage
		interface.damage_of_picture(&debts, picture, &changed, surface, &draw, &present)
		if present.count == 0 {
			frames_with_no_present += 1
			if place := first_difference(screen, whole); !testing.expectf(t, place < 0, "frame %v: nothing is presented, and the screen differs from the frame at x %v, y %v", frame, place % PROOF_STRIDE, place / PROOF_STRIDE) {
				return
			}
			drawn = interface.draw_table_copy(&before, &now)
			continue
		}
		// The draw through the export, one call for all the rectangles, as
		// frame_draw.
		rectangles: [interface.DAMAGE_CAPACITY]Damage_Rectangle
		for rectangle, index in draw.rectangles[:draw.count] {
			rectangles[index] = {i64(rectangle.left), i64(rectangle.top), i64(rectangle.right), i64(rectangle.bottom)}
		}
		draw_through_the_exports(t, &now, pictures[picture], rectangles[:draw.count])
		if place := first_difference(pictures[picture], whole); !testing.expectf(t, place < 0, "frame %v: the picture %v differs from the frame at x %v, y %v", frame, picture, place % PROOF_STRIDE, place / PROOF_STRIDE) {
			return
		}
		sent := chance != 1
		interface.picture_debts_after(&debts, picture, &changed, sent)
		if !sent {
			lost_presents += 1
			drawn = false
			continue
		}
		presented_frames += 1
		// The compositor takes the presented rectangle of the picture.
		bounds := interface.intersection(interface.damage_bounds(&present), surface)
		for y in bounds.top ..< bounds.bottom {
			copy(screen[y * PROOF_STRIDE + bounds.left:y * PROOF_STRIDE + bounds.right], pictures[picture][y * PROOF_STRIDE + bounds.left:y * PROOF_STRIDE + bounds.right])
		}
		if place := first_difference(screen, whole); !testing.expectf(t, place < 0, "frame %v: the screen differs from the frame at x %v, y %v", frame, place % PROOF_STRIDE, place / PROOF_STRIDE) {
			return
		}
		drawn = interface.draw_table_copy(&before, &now)
		testing.expect(t, drawn, "the table before holds the frame")
		picture = 1 - picture
	}
	testing.expectf(t, presented_frames > 300 && lost_presents > 0 && frames_with_no_present > 0 && long_scrolls > 0, "the run must have each case: %v frames presented, %v Present lost, %v frames with no Present, %v long scrolls", presented_frames, lost_presents, frames_with_no_present, long_scrolls)
	log.infof("a scrolling grid in two pictures through the exports: %v frames presented, %v Present lost, %v frames with no Present, %v scrolls of many thousand lines: the screen was each frame", presented_frames, lost_presents, frames_with_no_present, long_scrolls)
}
