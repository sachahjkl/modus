#+build !freestanding
package text_rendering_module

import "core:testing"
import "modus:contract/errors"
import "modus:contract/font_outlines"
import "modus:support/system"
import "modus:support/text_rendering"

@(private = "file")
b612_file := #load("../../../../resources/fonts/b612.ttf")
@(private = "file")
b612_bold_file := #load("../../../../resources/fonts/b612_bold.ttf")
@(private = "file")
paper_mono_file := #load("../../../../resources/fonts/paper_mono.ttf")
@(private = "file")
paper_mono_semibold_file := #load("../../../../resources/fonts/paper_mono_semibold.ttf")

// A resource of font outlines in words of the test, on 8 bytes, as the
// caller passes it.
@(private = "file")
Test_Outlines :: struct {
	words: []u64,
	bytes: []u8,
	table: system.Bytes_To_Read,
}

@(private = "file")
test_outlines_of :: proc(t: ^testing.T, fonts: []font_outlines.Font_Input) -> (outlines: Test_Outlines) {
	size := font_outlines.resource_size(fonts)
	outlines.words = make([]u64, (size + 7) / 8)
	outlines.bytes = ([^]u8)(raw_data(outlines.words))[:size]
	written, ok := font_outlines.resource_write(fonts, outlines.bytes)
	testing.expect(t, ok && written == size)
	outlines.table = bytes_to_read(outlines.bytes)
	return outlines
}

@(private = "file")
repository_outlines :: proc(t: ^testing.T) -> Test_Outlines {
	fonts := [4]font_outlines.Font_Input{{"b612", b612_file}, {"b612_bold", b612_bold_file}, {"paper_mono", paper_mono_file}, {"paper_mono_semibold", paper_mono_semibold_file}}
	return test_outlines_of(t, fonts[:])
}

@(private = "file")
bytes_to_read :: proc(bytes: []u8) -> system.Bytes_To_Read {
	return {bytes = raw_data(bytes), count = u64(len(bytes)), capacity = u64(len(bytes))}
}

// The package over a set of fonts of the test: the numbers that a process
// that compiles the package in gets. The set lives in memory of the test.
@(private = "file")
Package_Fonts :: struct {
	set:     text_rendering.Font_Set,
	outline: text_rendering.Outline_Memory,
}

@(private = "file")
package_spacing :: proc(t: ^testing.T, fonts: ^Package_Fonts, outlines: ^Test_Outlines, face: text_rendering.Face, size: int) -> text_rendering.Spacing {
	resource, problem := font_outlines.validate(outlines.bytes)
	testing.expect_value(t, problem.kind, font_outlines.Problem_Kind.None)
	outline := text_rendering.outline_of(&fonts.outline)
	missing := text_rendering.fonts_open(&fonts.set, &resource, &outline)
	testing.expect_value(t, missing, text_rendering.Outline_Fonts{})
	spacing, ok := text_rendering.spacing_in(&fonts.set, face, size)
	testing.expect(t, ok)
	return spacing
}

@(private = "file")
expect_error :: proc(t: ^testing.T, result: i64, error: errors.Error_Record, kind: errors.Kind, argument: i64, loc := #caller_location) {
	testing.expect_value(t, result, -1, loc = loc)
	testing.expect_value(t, errors.Kind(error.kind), kind, loc = loc)
	testing.expect_value(t, error.argument, argument, loc = loc)
}

// The three ways to call give the same records: the package compiled in;
// the export called with the bytes of the caller (a direct call of the
// module); the export called with copies of the outlines and of the text
// in another place, whose answer is copied back (the form of an isolated
// call, where the receiver sees them in the call region). Each way, at the
// three sizes of the glyph caches and at a size of no cache, places the
// glyphs, measures the texts and breaks the lines alike.
@(test)
the_three_ways_give_the_same_records :: proc(t: ^testing.T) {
	outlines := repository_outlines(t)
	defer delete(outlines.words)
	copied := repository_outlines(t)
	defer delete(copied.words)
	text := "Settings: To AVATAR, LT Wave. Δt = 16 ms ┌─┐ €"
	text_bytes := transmute([]u8)text
	region_text := make([]u8, len(text))
	defer delete(region_text)
	copy(region_text, text_bytes)
	text_table := bytes_to_read(text_bytes)
	text_copy := bytes_to_read(region_text)
	Case :: struct {
		face: text_rendering.Face,
		size: int,
	}
	cases := [?]Case{{.Interface, 1024}, {.Interface, 2048}, {.Interface, 3072}, {.Interface, 1280}, {.Interface_Bold, 1024}, {.Cells, 1024}, {.Cells_Bold, 1536}}
	for each in cases {
		package_fonts := new(Package_Fonts)
		defer free(package_fonts)
		spacing := package_spacing(t, package_fonts, &outlines, each.face, each.size)
		compiled_in: [64]text_rendering.Placed_Glyph
		count, width, ok := text_rendering.shape(&spacing, text_bytes, compiled_in[:])
		testing.expect(t, ok && count < len(compiled_in))
		error: errors.Error_Record
		direct: [64]text_rendering.Placed_Glyph
		placed := system.Table_To_Append(text_rendering.Placed_Glyph){records = &direct[0], count = 0, capacity = 64}
		testing.expect_value(t, shape_text(&outlines.table, i64(each.face), i64(each.size), &text_table, &placed, &error), i64(count))
		testing.expect_value(t, error.kind, i64(0))
		isolated: [64]text_rendering.Placed_Glyph
		placed_copy := system.Table_To_Append(text_rendering.Placed_Glyph){records = &isolated[0], count = 0, capacity = 64}
		testing.expect_value(t, shape_text(&copied.table, i64(each.face), i64(each.size), &text_copy, &placed_copy, &error), i64(count))
		testing.expectf(t, compiled_in == direct && direct == isolated, "%v at %v: the same placed glyphs in the three ways", each.face, each.size)
		// The measure: the width of shape, in each way.
		ranges := [2]text_rendering.Text_Range{{start = 0, count = u32(len(text))}, {start = 9, count = 2}}
		problem, _, _ := text_rendering.measure_ranges(&spacing, text_bytes, ranges[:])
		testing.expect(t, problem == .None && ranges[0].width == width)
		direct_ranges := [2]text_rendering.Text_Range{{start = 0, count = u32(len(text))}, {start = 9, count = 2}}
		range_table := system.Table_To_Change(text_rendering.Text_Range){records = &direct_ranges[0], count = 2, capacity = 2}
		testing.expect_value(t, measure_texts(&outlines.table, i64(each.face), i64(each.size), &text_table, &range_table, &error), 2)
		region_ranges := direct_ranges
		region_ranges[0].width, region_ranges[1].width = 0, 0
		range_copy := system.Table_To_Change(text_rendering.Text_Range){records = &region_ranges[0], count = 2, capacity = 2}
		testing.expect_value(t, measure_texts(&copied.table, i64(each.face), i64(each.size), &text_copy, &range_copy, &error), 2)
		testing.expect(t, ranges == direct_ranges && direct_ranges == region_ranges, "the same widths in the three ways")
		// The lines in a box of a third of the text: the package gives the
		// same lines, one break at a time.
		room := width / 3
		lines: [16]text_rendering.Text_Range
		line_table := system.Table_To_Append(text_rendering.Text_Range){records = &lines[0], count = 0, capacity = 16}
		line_count := break_text(&outlines.table, i64(each.face), i64(each.size), &text_table, room, &line_table, &error)
		testing.expect(t, line_count > 1 && line_count <= 16)
		start := 0
		for line in lines[:line_count] {
			end, next := text_rendering.line_break(&spacing, text_bytes[start:], room)
			line_width, _ := text_rendering.text_width(&spacing, text_bytes[start:][:end])
			testing.expect_value(t, line, text_rendering.Text_Range{start = u32(start), count = u32(end), width = line_width})
			start += next
		}
		testing.expect_value(t, start, len(text))
	}
}

// The Append rule across calls: the count of the full answer; nothing is
// written at or after the capacity; each text starts at x 0.
@(test)
placed_glyphs_across_calls :: proc(t: ^testing.T) {
	outlines := repository_outlines(t)
	defer delete(outlines.words)
	memory: [4]text_rendering.Placed_Glyph // 3 places, then a guard record.
	memory[3] = {glyph = 0xA5A5_A5A5}
	placed := system.Table_To_Append(text_rendering.Placed_Glyph){records = &memory[0], count = 0, capacity = 3}
	error: errors.Error_Record
	two := bytes_to_read(transmute([]u8)string("To"))
	size := i64(text_rendering.TEXT_SIZE_OF_SCALE_ONE)
	face := i64(text_rendering.Face.Interface)
	testing.expect_value(t, shape_text(&outlines.table, face, size, &two, &placed, &error), 2)
	testing.expect_value(t, shape_text(&outlines.table, face, size, &two, &placed, &error), 4) // 1 of 2 fits.
	testing.expect_value(t, memory[2].x, i32(0)) // The "T" of the second text, at its origin.
	testing.expect_value(t, memory[2].glyph, text_rendering.glyph_of('T'))
	empty := bytes_to_read(nil)
	testing.expect_value(t, shape_text(&outlines.table, face, size, &empty, &placed, &error), 4)
	testing.expect_value(t, shape_text(&outlines.table, face, size, &two, &placed, &error), 6)
	testing.expect_value(t, memory[3].glyph, u32(0xA5A5_A5A5))
}

// Each argument of a hostile caller is refused with its argument named,
// and nothing is written: a face that names no member, the face None, a
// size at each edge of its range, a text over its limit, a table over its
// limit, outlines that are damaged, empty, not on 8 bytes, or that lack
// the first font of the face. The edges that pass come last.
@(test)
hostile_callers_are_refused :: proc(t: ^testing.T) {
	outlines := repository_outlines(t)
	defer delete(outlines.words)
	error: errors.Error_Record
	text := bytes_to_read(transmute([]u8)string("To"))
	room: [4]text_rendering.Placed_Glyph
	sentinel := text_rendering.Placed_Glyph{glyph = 7, x = 7, advance = 7, cluster = 7}
	for &record in room {
		record = sentinel
	}
	placed := system.Table_To_Append(text_rendering.Placed_Glyph){records = &room[0], count = 0, capacity = 4}
	size := i64(text_rendering.TEXT_SIZE_OF_SCALE_ONE)
	face := i64(text_rendering.Face.Interface)
	unchanged :: proc(t: ^testing.T, placed: system.Table_To_Append(text_rendering.Placed_Glyph), room: [4]text_rendering.Placed_Glyph, sentinel: text_rendering.Placed_Glyph, loc := #caller_location) {
		testing.expect_value(t, placed.count, u64(0), loc = loc)
		for record in room {
			testing.expect_value(t, record, sentinel, loc = loc)
		}
	}
	// The face: the words around the members.
	for word in ([?]i64{i64(text_rendering.Face.None), -1, i64(max(text_rendering.Face)) + 1, max(i64), min(i64)}) {
		expect_error(t, shape_text(&outlines.table, word, size, &text, &placed, &error), error, .Bad_Value, 2)
		testing.expect_value(t, error.value, word)
		unchanged(t, placed, room, sentinel)
	}
	// The size: 0, 1, one under the least, a negative size and the least
	// i64 are too small; one past the largest and the largest i64 are past
	// the bound.
	for small in ([?]i64{0, 1, text_rendering.TEXT_SIZE_MINIMUM - 1, -1, min(i64)}) {
		expect_error(t, shape_text(&outlines.table, face, small, &text, &placed, &error), error, .Too_Small, 3)
		testing.expect_value(t, error.limit, i64(text_rendering.TEXT_SIZE_MINIMUM))
		unchanged(t, placed, room, sentinel)
	}
	for large in ([?]i64{text_rendering.TEXT_SIZE_LIMIT + 1, max(i64)}) {
		expect_error(t, shape_text(&outlines.table, face, large, &text, &placed, &error), error, .Bad_Value, 3)
		testing.expect_value(t, error.limit, i64(text_rendering.TEXT_SIZE_LIMIT))
		unchanged(t, placed, room, sentinel)
	}
	// A text one byte past the limit.
	large := make([]u8, text_rendering.TEXT_LIMIT + 1)
	defer delete(large)
	large_text := bytes_to_read(large)
	expect_error(t, shape_text(&outlines.table, face, size, &large_text, &placed, &error), error, .Too_Long, 4)
	// A capacity of 2^63: a negative int.
	huge := system.Table_To_Append(text_rendering.Placed_Glyph){records = &room[0], count = 0, capacity = 1 << 63}
	expect_error(t, shape_text(&outlines.table, face, size, &text, &huge, &error), error, .Too_Long, 5)
	unchanged(t, placed, room, sentinel)
	// The outlines: another magic, no byte, not on 8 bytes, a count past
	// the bound of a table, and outlines with no B612.
	damaged := repository_outlines(t)
	defer delete(damaged.words)
	damaged.bytes[0] ~= 1
	expect_error(t, shape_text(&damaged.table, face, size, &text, &placed, &error), error, .Bad_Value, 1)
	testing.expect_value(t, error.value, i64(font_outlines.Problem_Kind.Bad_Magic))
	nothing := bytes_to_read(nil)
	expect_error(t, shape_text(&nothing, face, size, &text, &placed, &error), error, .Bad_Value, 1)
	testing.expect_value(t, error.value, i64(font_outlines.Problem_Kind.Too_Short))
	shifted := system.Bytes_To_Read{bytes = raw_data(outlines.bytes[1:]), count = outlines.table.count - 1, capacity = outlines.table.count - 1}
	expect_error(t, shape_text(&shifted, face, size, &text, &placed, &error), error, .Bad_Value, 1)
	testing.expect_value(t, error.value, i64(font_outlines.Problem_Kind.Too_Short))
	past := outlines.table
	past.count = TABLE_LIMIT + 1
	expect_error(t, shape_text(&past, face, size, &text, &placed, &error), error, .Too_Long, 1)
	only_cells := [1]font_outlines.Font_Input{{"paper_mono", paper_mono_file}}
	cells := test_outlines_of(t, only_cells[:])
	defer delete(cells.words)
	expect_error(t, shape_text(&cells.table, face, size, &text, &placed, &error), error, .Absent, 1)
	testing.expect_value(t, error.value, i64(text_rendering.Outline_Font.B612))
	unchanged(t, placed, room, sentinel)
	// The measure: a range past the bytes, and one over the limit; the
	// ranges before it have their width, it and the next keep theirs.
	ranges := [3]text_rendering.Text_Range{{start = 0, count = 2}, {start = 1, count = 2, width = 5}, {start = 0, count = 1, width = 5}}
	range_table := system.Table_To_Change(text_rendering.Text_Range){records = &ranges[0], count = 3, capacity = 3}
	expect_error(t, measure_texts(&outlines.table, face, size, &text, &range_table, &error), error, .Out_Of_Range, 5)
	testing.expect(t, error.value == 3 && error.limit == 2 && error.found == 2)
	testing.expect(t, ranges[0].width > 0 && ranges[1].width == 5 && ranges[2].width == 5)
	long_ranges := [1]text_rendering.Text_Range{{start = 0, count = text_rendering.TEXT_LIMIT + 1}}
	long_table := system.Table_To_Change(text_rendering.Text_Range){records = &long_ranges[0], count = 1, capacity = 1}
	expect_error(t, measure_texts(&outlines.table, face, size, &large_text, &long_table, &error), error, .Too_Long, 5)
	testing.expect_value(t, error.found, i64(1))
	many_ranges := range_table
	many_ranges.count = TABLE_LIMIT + 1
	expect_error(t, measure_texts(&outlines.table, face, size, &text, &many_ranges, &error), error, .Too_Long, 5)
	// The lines: a table past its bound, and a text past its limit.
	lines: [2]text_rendering.Text_Range
	huge_lines := system.Table_To_Append(text_rendering.Text_Range){records = &lines[0], count = 0, capacity = 1 << 63}
	expect_error(t, break_text(&outlines.table, face, size, &text, 0, &huge_lines, &error), error, .Too_Long, 6)
	line_table := system.Table_To_Append(text_rendering.Text_Range){records = &lines[0], count = 0, capacity = 2}
	expect_error(t, break_text(&outlines.table, face, size, &large_text, 0, &line_table, &error), error, .Too_Long, 4)
	testing.expect_value(t, line_table.count, u64(0))
	// The edges that pass, last: the least size and the largest size.
	for edge in ([?]i64{text_rendering.TEXT_SIZE_MINIMUM, text_rendering.TEXT_SIZE_LIMIT}) {
		error = {}
		placed.count = 0
		result := shape_text(&outlines.table, face, edge, &text, &placed, &error)
		testing.expect_value(t, result, i64(2))
		testing.expect_value(t, placed.count, u64(2))
		testing.expect_value(t, error.kind, i64(0))
	}
}

// The lines of a text: an empty text has none; a room of 0, and a room
// below 0, give lines of one whole character each, of several bytes too; a
// room of the whole width gives one line. The lines, joined with the
// spaces of each break, are the text.
@(test)
the_lines_of_a_text :: proc(t: ^testing.T) {
	outlines := repository_outlines(t)
	defer delete(outlines.words)
	error: errors.Error_Record
	lines: [16]text_rendering.Text_Range
	size := i64(text_rendering.TEXT_SIZE_OF_SCALE_ONE)
	face := i64(text_rendering.Face.Interface)
	empty := bytes_to_read(nil)
	table := system.Table_To_Append(text_rendering.Text_Range){records = &lines[0], count = 0, capacity = 16}
	testing.expect_value(t, break_text(&outlines.table, face, size, &empty, 100, &table, &error), 0)
	euros := bytes_to_read(transmute([]u8)string("€€€"))
	for room in ([?]i64{0, -1, min(i64)}) {
		table.count = 0
		testing.expect_value(t, break_text(&outlines.table, face, size, &euros, room, &table, &error), 3)
		for line, index in lines[:3] {
			testing.expect_value(t, line.start, u32(3 * index))
			testing.expect_value(t, line.count, u32(3))
		}
	}
	// One line in a room of max(i64), with its width.
	words := "one two three"
	words_table := bytes_to_read(transmute([]u8)words)
	table.count = 0
	testing.expect_value(t, break_text(&outlines.table, face, size, &words_table, max(i64), &table, &error), 1)
	testing.expect_value(t, lines[0].count, u32(len(words)))
	whole := [1]text_rendering.Text_Range{{start = 0, count = u32(len(words))}}
	whole_table := system.Table_To_Change(text_rendering.Text_Range){records = &whole[0], count = 1, capacity = 1}
	testing.expect_value(t, measure_texts(&outlines.table, face, size, &words_table, &whole_table, &error), 1)
	testing.expect_value(t, lines[0].width, whole[0].width)
	// A room of the width of "one two": two lines, and no space at the end
	// of the first or at the start of the second. A table of one line holds
	// the first, and the count is the full answer.
	pair := [1]text_rendering.Text_Range{{start = 0, count = 7}}
	pair_table := system.Table_To_Change(text_rendering.Text_Range){records = &pair[0], count = 1, capacity = 1}
	_ = measure_texts(&outlines.table, face, size, &words_table, &pair_table, &error)
	one: [2]text_rendering.Text_Range
	one[1] = {start = 99, count = 99, width = 99}
	one_table := system.Table_To_Append(text_rendering.Text_Range){records = &one[0], count = 0, capacity = 1}
	testing.expect_value(t, break_text(&outlines.table, face, size, &words_table, pair[0].width, &one_table, &error), 2)
	testing.expect_value(t, one[0], text_rendering.Text_Range{start = 0, count = 7, width = pair[0].width})
	testing.expect_value(t, one[1], text_rendering.Text_Range{start = 99, count = 99, width = 99})
}

// The bounds of the shaper hold at the largest size: a text of the largest
// count of bytes, each a wide letter, at the largest size: each advance is
// at most one line, each x is the sum of the advances before it, and the
// width stays in an i32. At the least size each advance is above 0.
@(test)
the_bounds_hold_at_each_size :: proc(t: ^testing.T) {
	outlines := repository_outlines(t)
	defer delete(outlines.words)
	error: errors.Error_Record
	wide := make([]u8, text_rendering.TEXT_LIMIT)
	defer delete(wide)
	for &value, index in wide {
		value = index % 2 == 0 ? 'W' : 'A'
	}
	wide_text := bytes_to_read(wide)
	placed := make([]text_rendering.Placed_Glyph, text_rendering.TEXT_LIMIT)
	defer delete(placed)
	for size in ([?]i64{text_rendering.TEXT_SIZE_MINIMUM, text_rendering.TEXT_SIZE_LIMIT}) {
		for face in ([?]text_rendering.Face{.Interface, .Interface_Bold, .Cells}) {
			table := system.Table_To_Append(text_rendering.Placed_Glyph){records = raw_data(placed), count = 0, capacity = u64(len(placed))}
			testing.expect_value(t, shape_text(&outlines.table, i64(face), size, &wide_text, &table, &error), i64(text_rendering.TEXT_LIMIT))
			sum: i64
			for glyph in placed {
				testing.expect_value(t, i64(glyph.x), sum)
				testing.expect(t, glyph.advance > 0 && i64(glyph.advance) <= size + size / 2)
				sum += i64(glyph.advance)
			}
			testing.expect(t, sum < 1 << 31)
		}
	}
}
