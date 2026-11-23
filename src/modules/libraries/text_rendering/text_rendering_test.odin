#+build !freestanding
package text_rendering_module

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/font_outlines"
import "modus:system"
import "modus:text_rendering"
import "modus:vector_font"

// The measures of this file run only with -define:MEASURE=true: a test
// that measures time is opt-in, and a normal run prints nothing.
MEASURE :: #config(MEASURE, false)

@(private = "file")
b612_file := #load("../../../../resources/fonts/b612.ttf")
@(private = "file")
b612_bold_file := #load("../../../../resources/fonts/b612_bold.ttf")
@(private = "file")
paper_mono_file := #load("../../../../resources/fonts/paper_mono.ttf")
@(private = "file")
paper_mono_semibold_file := #load("../../../../resources/fonts/paper_mono_semibold.ttf")
@(private = "file")
noto_sans_file := #load("../../../../resources/fonts/noto_sans.ttf")

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
	fonts := [5]font_outlines.Font_Input{{"b612", b612_file}, {"b612_bold", b612_bold_file}, {"paper_mono", paper_mono_file}, {"paper_mono_semibold", paper_mono_semibold_file}, {"noto_sans", noto_sans_file}}
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
	room:    text_rendering.Font_Room,
	outline: text_rendering.Outline_Memory,
}

@(private = "file")
package_spacing :: proc(t: ^testing.T, fonts: ^Package_Fonts, outlines: ^Test_Outlines, face: text_rendering.Face, size: int) -> text_rendering.Spacing {
	resource, problem := font_outlines.validate(outlines.bytes, new(font_outlines.Record_Room, context.temp_allocator)[:])
	testing.expect_value(t, problem.kind, font_outlines.Problem_Kind.None)
	fonts.set.room = fonts.room[:]
	outline := text_rendering.outline_of(&fonts.outline)
	missing := text_rendering.fonts_open(&fonts.set, &resource, &outline)
	testing.expect_value(t, missing, text_rendering.Outline_Fonts{})
	spacing, ok := text_rendering.spacing_in(&fonts.set, face, size)
	testing.expect(t, ok)
	return spacing
}

// The pair of an export, as one value that a test compares.
@(private = "file")
Answer :: struct {
	outcome: call_outcome.Call_Outcome,
	value:   i64,
}

@(private = "file")
// value_of gives the value of a call that succeeded, and -1 for a refusal:
// the tests of a count read the count, and expect_error reads the refusal.
value_of :: proc(outcome: call_outcome.Call_Outcome, value: i64) -> i64 {
	return outcome == .Succeeded ? value : -1
}

answer_of :: proc(outcome: call_outcome.Call_Outcome, value: i64) -> Answer {
	return {outcome, value}
}

// expect_error checks a refused argument that changed nothing: the outcome
// Argument_Refused with the value 0, and the kind and the argument of the
// record.
@(private = "file")
expect_error :: proc(t: ^testing.T, result: Answer, error: errors.Error_Record, kind: errors.Kind, argument: i64, outcome := call_outcome.Call_Outcome.Argument_Refused, loc := #caller_location) {
	testing.expect_value(t, result, Answer{outcome, 0}, loc = loc)
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
		testing.expect_value(t, answer_of(shape_text(&outlines.table, i64(each.face), i64(each.size), &text_table, &placed, &error)), Answer{.Succeeded, i64(count)})
		testing.expect_value(t, error.kind, i64(0))
		isolated: [64]text_rendering.Placed_Glyph
		placed_copy := system.Table_To_Append(text_rendering.Placed_Glyph){records = &isolated[0], count = 0, capacity = 64}
		testing.expect_value(t, answer_of(shape_text(&copied.table, i64(each.face), i64(each.size), &text_copy, &placed_copy, &error)), Answer{.Succeeded, i64(count)})
		testing.expectf(t, compiled_in == direct && direct == isolated, "%v at %v: the same placed glyphs in the three ways", each.face, each.size)
		// The measure: the width of shape, in each way.
		ranges := [2]text_rendering.Text_Range{{start = 0, count = u32(len(text))}, {start = 9, count = 2}}
		problem, _, _ := text_rendering.measure_ranges(&spacing, text_bytes, ranges[:])
		testing.expect(t, problem == .None && ranges[0].width == width)
		direct_ranges := [2]text_rendering.Text_Range{{start = 0, count = u32(len(text))}, {start = 9, count = 2}}
		range_table := system.Table_To_Change(text_rendering.Text_Range){records = &direct_ranges[0], count = 2, capacity = 2}
		testing.expect_value(t, answer_of(measure_texts(&outlines.table, i64(each.face), i64(each.size), &text_table, &range_table, &error)), Answer{.Succeeded, 2})
		region_ranges := direct_ranges
		region_ranges[0].width, region_ranges[1].width = 0, 0
		range_copy := system.Table_To_Change(text_rendering.Text_Range){records = &region_ranges[0], count = 2, capacity = 2}
		testing.expect_value(t, answer_of(measure_texts(&copied.table, i64(each.face), i64(each.size), &text_copy, &range_copy, &error)), Answer{.Succeeded, 2})
		testing.expect(t, ranges == direct_ranges && direct_ranges == region_ranges, "the same widths in the three ways")
		// The lines in a box of a third of the text: the package gives the
		// same lines, one break at a time.
		room := width / 3
		lines: [16]text_rendering.Text_Range
		line_table := system.Table_To_Append(text_rendering.Text_Range){records = &lines[0], count = 0, capacity = 16}
		line_outcome, line_count := value_of(break_text(&outlines.table, i64(each.face), i64(each.size), &text_table, room, &line_table, &error))
		testing.expect(t, line_outcome == .Succeeded && line_count > 1 && line_count <= 16)
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
	testing.expect_value(t, answer_of(shape_text(&outlines.table, face, size, &two, &placed, &error)), Answer{.Succeeded, 2})
	testing.expect_value(t, answer_of(shape_text(&outlines.table, face, size, &two, &placed, &error)), Answer{.Succeeded, 4}) // 1 of 2 fits.
	testing.expect_value(t, memory[2].x, i32(0)) // The "T" of the second text, at its origin.
	testing.expect_value(t, memory[2].glyph, text_rendering.glyph_of('T'))
	empty := bytes_to_read(nil)
	testing.expect_value(t, answer_of(shape_text(&outlines.table, face, size, &empty, &placed, &error)), Answer{.Succeeded, 4})
	testing.expect_value(t, answer_of(shape_text(&outlines.table, face, size, &two, &placed, &error)), Answer{.Succeeded, 6})
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
		expect_error(t, answer_of(shape_text(&outlines.table, word, size, &text, &placed, &error)), error, .Bad_Value, 2)
		testing.expect_value(t, error.value, word)
		unchanged(t, placed, room, sentinel)
	}
	// The size: 0, 1, one under the least, a negative size and the least
	// i64 are too small; one past the largest and the largest i64 are past
	// the bound.
	for small in ([?]i64{0, 1, text_rendering.TEXT_SIZE_MINIMUM - 1, -1, min(i64)}) {
		expect_error(t, answer_of(shape_text(&outlines.table, face, small, &text, &placed, &error)), error, .Too_Small, 3)
		testing.expect_value(t, error.limit, i64(text_rendering.TEXT_SIZE_MINIMUM))
		unchanged(t, placed, room, sentinel)
	}
	for large in ([?]i64{text_rendering.TEXT_SIZE_LIMIT + 1, max(i64)}) {
		expect_error(t, answer_of(shape_text(&outlines.table, face, large, &text, &placed, &error)), error, .Bad_Value, 3)
		testing.expect_value(t, error.limit, i64(text_rendering.TEXT_SIZE_LIMIT))
		unchanged(t, placed, room, sentinel)
	}
	// A text one byte past the limit.
	large := make([]u8, text_rendering.TEXT_LIMIT + 1)
	defer delete(large)
	large_text := bytes_to_read(large)
	expect_error(t, answer_of(shape_text(&outlines.table, face, size, &large_text, &placed, &error)), error, .Too_Long, 4)
	// A capacity of 2^63: a negative int.
	huge := system.Table_To_Append(text_rendering.Placed_Glyph){records = &room[0], count = 0, capacity = 1 << 63}
	expect_error(t, answer_of(shape_text(&outlines.table, face, size, &text, &huge, &error)), error, .Too_Long, 5)
	unchanged(t, placed, room, sentinel)
	// The outlines: another magic, no byte, not on 8 bytes, a count past
	// the bound of a table, and outlines with no B612.
	damaged := repository_outlines(t)
	defer delete(damaged.words)
	damaged.bytes[0] ~= 1
	expect_error(t, answer_of(shape_text(&damaged.table, face, size, &text, &placed, &error)), error, .Bad_Value, 1)
	testing.expect_value(t, error.value, i64(font_outlines.Problem_Kind.Bad_Magic))
	nothing := bytes_to_read(nil)
	expect_error(t, answer_of(shape_text(&nothing, face, size, &text, &placed, &error)), error, .Bad_Value, 1)
	testing.expect_value(t, error.value, i64(font_outlines.Problem_Kind.Too_Short))
	shifted := system.Bytes_To_Read{bytes = raw_data(outlines.bytes[1:]), count = outlines.table.count - 1, capacity = outlines.table.count - 1}
	expect_error(t, answer_of(shape_text(&shifted, face, size, &text, &placed, &error)), error, .Bad_Value, 1)
	testing.expect_value(t, error.value, i64(font_outlines.Problem_Kind.Too_Short))
	past := outlines.table
	past.count = TABLE_LIMIT + 1
	expect_error(t, answer_of(shape_text(&past, face, size, &text, &placed, &error)), error, .Too_Long, 1)
	only_cells := [1]font_outlines.Font_Input{{"paper_mono", paper_mono_file}}
	cells := test_outlines_of(t, only_cells[:])
	defer delete(cells.words)
	expect_error(t, answer_of(shape_text(&cells.table, face, size, &text, &placed, &error)), error, .Absent, 1)
	testing.expect_value(t, error.value, i64(text_rendering.Outline_Font.B612))
	unchanged(t, placed, room, sentinel)
	// The measure: a range past the bytes, and one over the limit; the
	// ranges before it have their width, it and the next keep theirs.
	ranges := [3]text_rendering.Text_Range{{start = 0, count = 2}, {start = 1, count = 2, width = 5}, {start = 0, count = 1, width = 5}}
	range_table := system.Table_To_Change(text_rendering.Text_Range){records = &ranges[0], count = 3, capacity = 3}
	// The first range got its width before the refusal: a change that the
	// outcome states.
	testing.expect_value(t, answer_of(measure_texts(&outlines.table, face, size, &text, &range_table, &error)), Answer{.Stopped_After_A_Partial_Change, 0})
	testing.expect(t, errors.Kind(error.kind) == .Out_Of_Range && error.argument == 5)
	testing.expect(t, error.value == 3 && error.limit == 2 && error.found == 2)
	testing.expect(t, ranges[0].width > 0 && ranges[1].width == 5 && ranges[2].width == 5)
	long_ranges := [1]text_rendering.Text_Range{{start = 0, count = text_rendering.TEXT_LIMIT + 1}}
	long_table := system.Table_To_Change(text_rendering.Text_Range){records = &long_ranges[0], count = 1, capacity = 1}
	expect_error(t, answer_of(measure_texts(&outlines.table, face, size, &large_text, &long_table, &error)), error, .Too_Long, 5)
	testing.expect_value(t, error.found, i64(1))
	many_ranges := range_table
	many_ranges.count = TABLE_LIMIT + 1
	expect_error(t, answer_of(measure_texts(&outlines.table, face, size, &text, &many_ranges, &error)), error, .Too_Long, 5)
	// The lines: a table past its bound, and a text past its limit.
	lines: [2]text_rendering.Text_Range
	huge_lines := system.Table_To_Append(text_rendering.Text_Range){records = &lines[0], count = 0, capacity = 1 << 63}
	expect_error(t, answer_of(break_text(&outlines.table, face, size, &text, 0, &huge_lines, &error)), error, .Too_Long, 6)
	line_table := system.Table_To_Append(text_rendering.Text_Range){records = &lines[0], count = 0, capacity = 2}
	expect_error(t, answer_of(break_text(&outlines.table, face, size, &large_text, 0, &line_table, &error)), error, .Too_Long, 4)
	testing.expect_value(t, line_table.count, u64(0))
	// The edges that pass, last: the least size and the largest size.
	for edge in ([?]i64{text_rendering.TEXT_SIZE_MINIMUM, text_rendering.TEXT_SIZE_LIMIT}) {
		error = {}
		placed.count = 0
		testing.expect_value(t, answer_of(shape_text(&outlines.table, face, edge, &text, &placed, &error)), Answer{.Succeeded, 2})
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
	testing.expect_value(t, answer_of(break_text(&outlines.table, face, size, &empty, 100, &table, &error)), Answer{.Succeeded, 0})
	euros := bytes_to_read(transmute([]u8)string("€€€"))
	for room in ([?]i64{0, -1, min(i64)}) {
		table.count = 0
		testing.expect_value(t, answer_of(break_text(&outlines.table, face, size, &euros, room, &table, &error)), Answer{.Succeeded, 3})
		for line, index in lines[:3] {
			testing.expect_value(t, line.start, u32(3 * index))
			testing.expect_value(t, line.count, u32(3))
		}
	}
	// One line in a room of max(i64), with its width.
	words := "one two three"
	words_table := bytes_to_read(transmute([]u8)words)
	table.count = 0
	testing.expect_value(t, answer_of(break_text(&outlines.table, face, size, &words_table, max(i64), &table, &error)), Answer{.Succeeded, 1})
	testing.expect_value(t, lines[0].count, u32(len(words)))
	whole := [1]text_rendering.Text_Range{{start = 0, count = u32(len(words))}}
	whole_table := system.Table_To_Change(text_rendering.Text_Range){records = &whole[0], count = 1, capacity = 1}
	testing.expect_value(t, answer_of(measure_texts(&outlines.table, face, size, &words_table, &whole_table, &error)), Answer{.Succeeded, 1})
	testing.expect_value(t, lines[0].width, whole[0].width)
	// A room of the width of "one two": two lines, and no space at the end
	// of the first or at the start of the second. A table of one line holds
	// the first, and the count is the full answer.
	pair := [1]text_rendering.Text_Range{{start = 0, count = 7}}
	pair_table := system.Table_To_Change(text_rendering.Text_Range){records = &pair[0], count = 1, capacity = 1}
	testing.expect_value(t, answer_of(measure_texts(&outlines.table, face, size, &words_table, &pair_table, &error)), Answer{.Succeeded, 1})
	one: [2]text_rendering.Text_Range
	one[1] = {start = 99, count = 99, width = 99}
	one_table := system.Table_To_Append(text_rendering.Text_Range){records = &one[0], count = 0, capacity = 1}
	testing.expect_value(t, answer_of(break_text(&outlines.table, face, size, &words_table, pair[0].width, &one_table, &error)), Answer{.Succeeded, 2})
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
			testing.expect_value(t, answer_of(shape_text(&outlines.table, i64(face), size, &wide_text, &table, &error)), Answer{.Succeeded, i64(text_rendering.TEXT_LIMIT)})
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

// The lies of a hostile B612, each in one copy of its file.
@(private = "file")
Lie :: enum {
	Advance_Of_The_Largest, // The hmtx advance of "W" is 0xFFFF units.
	Pairs_Of_The_Least, // Each kern adjustment is -32768 units.
	Pairs_Of_The_Most, // Each kern adjustment is +32767 units.
	Pair_Count_Past_The_Table, // The kern subtable states 0xFFFF pairs.
	Subtable_Length_Wrong, // The kern subtable states a length of 0.
	One_Long_Metric, // hhea states one long metric: each other glyph is past numberOfHMetrics.
}

// The places in the table kern: the subtable after the 4 bytes of the
// table header, its length and its count of pairs, and its first pair, of
// 6 bytes, whose adjustment is at 4.
@(private = "file")
KERN_SUBTABLE :: 4
@(private = "file")
KERN_LENGTH :: KERN_SUBTABLE + 2
@(private = "file")
KERN_PAIR_COUNT :: KERN_SUBTABLE + 6
@(private = "file")
KERN_FIRST_PAIR :: KERN_SUBTABLE + 14
@(private = "file")
HHEA_LONG_METRICS :: 34

@(private = "file")
write_u16 :: proc(bytes: []u8, at: int, value: int) {
	bytes[at] = u8(value >> 8 & 0xFF)
	bytes[at + 1] = u8(value & 0xFF)
}

@(private = "file")
read_u16 :: proc(bytes: []u8, at: int) -> int {
	return int(bytes[at]) << 8 | int(bytes[at + 1])
}

// lying_b612 gives a copy of B612 with one lie.
@(private = "file")
lying_b612 :: proc(t: ^testing.T, lie: Lie) -> []u8 {
	bytes := make([]u8, len(b612_file))
	copy(bytes, b612_file)
	font, problem := vector_font.font_open(b612_file)
	testing.expect_value(t, problem, vector_font.Font_Problem.None)
	kern := font.kern.offset
	testing.expect(t, font.kern.length > KERN_FIRST_PAIR)
	pair_count := read_u16(bytes, kern + KERN_PAIR_COUNT)
	switch lie {
	case .Advance_Of_The_Largest:
		glyph, found := vector_font.glyph_of(&font, 'W')
		testing.expect(t, found == .None && glyph < font.horizontal_metrics)
		write_u16(bytes, font.hmtx.offset + 4 * glyph, 0xFFFF)
	case .Pairs_Of_The_Least:
		for index in 0 ..< pair_count {
			write_u16(bytes, kern + KERN_FIRST_PAIR + 6 * index + 4, 0x8000)
		}
	case .Pairs_Of_The_Most:
		for index in 0 ..< pair_count {
			write_u16(bytes, kern + KERN_FIRST_PAIR + 6 * index + 4, 0x7FFF)
		}
	case .Pair_Count_Past_The_Table:
		write_u16(bytes, kern + KERN_PAIR_COUNT, 0xFFFF)
	case .Subtable_Length_Wrong:
		write_u16(bytes, kern + KERN_LENGTH, 0)
	case .One_Long_Metric:
		write_u16(bytes, font.hhea.offset + HHEA_LONG_METRICS, 1)
	}
	return bytes
}

// shape_through_module shapes a text in the face Interface through the
// export, and gives its placed glyphs and its width.
@(private = "file")
shape_through_module :: proc(t: ^testing.T, outlines: ^Test_Outlines, text: string, size: int, placed: []text_rendering.Placed_Glyph) -> (count: int, width: i64) {
	error: errors.Error_Record
	text_table := bytes_to_read(transmute([]u8)text)
	table := system.Table_To_Append(text_rendering.Placed_Glyph){records = raw_data(placed), count = 0, capacity = u64(len(placed))}
	outcome, result := value_of(shape_text(&outlines.table, i64(text_rendering.Face.Interface), i64(size), &text_table, &table, &error))
	testing.expect_value(t, outcome, call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, error.kind, i64(0))
	count = int(result)
	for glyph in placed[:min(count, len(placed))] {
		width += i64(glyph.advance)
	}
	return count, width
}

// The bounds hold over a font that lies: an advance of 0xFFFF units is one
// line; a pair of -32768 or +32767 units is half a line, on its side; a
// table kern with a count of pairs past its end is refused, and the font
// still measures, with no pair; a length of a subtable that disagrees with
// its count changes nothing, as the count and the table are the bounds; a
// glyph past numberOfHMetrics has the advance of the last long metric. A
// text of the largest count of bytes at the largest size keeps each x the
// sum of the advances before it, in an i32.
@(test)
a_font_that_lies_keeps_the_bounds :: proc(t: ^testing.T) {
	true_outlines := repository_outlines(t)
	defer delete(true_outlines.words)
	placed: [4]text_rendering.Placed_Glyph
	size := text_rendering.TEXT_SIZE_OF_SCALE_ONE
	shape_through_module(t, &true_outlines, "T", size, placed[:])
	t_alone := placed[0].advance
	shape_through_module(t, &true_outlines, "To", size, placed[:])
	t_before_o := placed[0].advance
	testing.expect(t, t_before_o < t_alone) // B612 has the pair "To".
	shape_through_module(t, &true_outlines, "A", size, placed[:])
	a_alone := placed[0].advance
	long := make([]u8, text_rendering.TEXT_LIMIT)
	defer delete(long)
	for &value, index in long {
		value = index % 2 == 0 ? 'T' : 'o'
	}
	many := make([]text_rendering.Placed_Glyph, text_rendering.TEXT_LIMIT)
	defer delete(many)
	for lie in Lie {
		lying := lying_b612(t, lie)
		defer delete(lying)
		fonts := [5]font_outlines.Font_Input{{"b612", lying}, {"b612_bold", b612_bold_file}, {"paper_mono", paper_mono_file}, {"paper_mono_semibold", paper_mono_semibold_file}, {"noto_sans", noto_sans_file}}
		outlines := test_outlines_of(t, fonts[:])
		defer delete(outlines.words)
		switch lie {
		case .Advance_Of_The_Largest:
			for line in ([?]int{size, text_rendering.TEXT_SIZE_LIMIT}) {
				shape_through_module(t, &outlines, "W", line, placed[:])
				testing.expectf(t, placed[0].advance == i32(line), "%v at %v: %v, one line", lie, line, placed[0].advance)
			}
			for &value in long {
				value = 'W'
			}
		case .Pairs_Of_The_Least:
			shape_through_module(t, &outlines, "To", size, placed[:])
			testing.expect_value(t, placed[0].advance, t_alone - i32(size / 2))
		case .Pairs_Of_The_Most:
			shape_through_module(t, &outlines, "To", size, placed[:])
			testing.expect_value(t, placed[0].advance, t_alone + i32(size / 2))
		case .Pair_Count_Past_The_Table:
			shape_through_module(t, &outlines, "To", size, placed[:])
			testing.expect_value(t, placed[0].advance, t_alone)
			shape_through_module(t, &outlines, "A", size, placed[:])
			testing.expect_value(t, placed[0].advance, a_alone)
		case .Subtable_Length_Wrong:
			shape_through_module(t, &outlines, "To", size, placed[:])
			testing.expect_value(t, placed[0].advance, t_before_o)
		case .One_Long_Metric:
			shape_through_module(t, &outlines, "A", size, placed[:])
			first := placed[0].advance
			shape_through_module(t, &outlines, "W", size, placed[:])
			testing.expect_value(t, placed[0].advance, first)
			testing.expect(t, first >= 0 && i64(first) <= i64(size))
		}
		// The longest text at the largest size.
		count, width := shape_through_module(t, &outlines, string(long), text_rendering.TEXT_SIZE_LIMIT, many)
		testing.expect_value(t, count, text_rendering.TEXT_LIMIT)
		limit := i64(text_rendering.TEXT_SIZE_LIMIT)
		sum: i64
		for glyph in many {
			testing.expect_value(t, i64(glyph.x), sum)
			testing.expect(t, i64(glyph.advance) >= -limit / 2 && i64(glyph.advance) <= limit + limit / 2)
			sum += i64(glyph.advance)
		}
		testing.expect(t, sum == width && sum < 1 << 31 && sum > -(1 << 31))
		for &value, index in long {
			value = index % 2 == 0 ? 'T' : 'o'
		}
	}
}

// A call opens only the fonts that the chains of its face name: the bold
// weights and Paper Mono SemiBold stay closed for the face Interface. A
// font that is not wanted is not missing. A letter of Greek, of Cyrillic
// and of Latin Extended-A that B612 lacks comes from Noto Sans, the last
// font of each chain, with its own advance.
@(test)
a_call_opens_the_fonts_of_its_face :: proc(t: ^testing.T) {
	outlines := repository_outlines(t)
	defer delete(outlines.words)
	testing.expect_value(t, text_rendering.fonts_of_face(.None), text_rendering.Outline_Fonts{})
	// The script fonts are in the chains of each face; a caller gives the
	// font outlines only, so a call never opens them.
	testing.expect_value(t, text_rendering.fonts_of_face(.Interface), text_rendering.Outline_Fonts{.B612, .Paper_Mono, .Noto_Sans} + text_rendering.SCRIPT_FONTS)
	testing.expect_value(t, text_rendering.fonts_of_face(.Cells_Bold), text_rendering.Outline_Fonts{.Paper_Mono_Semibold, .B612_Bold, .B612, .Noto_Sans} + text_rendering.SCRIPT_FONTS)
	placed: [3]text_rendering.Placed_Glyph
	count, _ := shape_through_module(t, &outlines, "ΠЖā", text_rendering.TEXT_SIZE_OF_SCALE_ONE, placed[:])
	testing.expect_value(t, count, 3)
	for character, index in ([3]rune{0x03A0, 0x0416, 0x0101}) {
		testing.expectf(t, placed[index].glyph == text_rendering.FALLBACK_GLYPH_FIRST + u32(character) && placed[index].advance > 0, "U+%04X: the glyph %v, the advance %v", int(character), placed[index].glyph, placed[index].advance)
	}
	resource, problem := font_outlines.validate(outlines.bytes, new(font_outlines.Record_Room, context.temp_allocator)[:])
	testing.expect_value(t, problem.kind, font_outlines.Problem_Kind.None)
	fonts := new(Package_Fonts)
	defer free(fonts)
	fonts.set.room = fonts.room[:]
	outline := text_rendering.outline_of(&fonts.outline)
	missing := text_rendering.fonts_open(&fonts.set, &resource, &outline, text_rendering.fonts_of_face(.Interface))
	testing.expect_value(t, missing, text_rendering.Outline_Fonts{})
	for font in text_rendering.Outline_Font {
		wanted := font == .B612 || font == .Paper_Mono || font == .Noto_Sans
		testing.expectf(t, text_rendering.font_at(&fonts.set, font).opened == wanted, "%v is open: %v", font, text_rendering.font_at(&fonts.set, font).opened)
	}
}

// The time of one call of shape_text on a label, from its start to its
// end, the open of the fonts of its face included: the least of 200. A
// measure, never a test of a speed; it runs only with -define:MEASURE=true.
@(test)
the_time_of_one_call :: proc(t: ^testing.T) {
	if !MEASURE {
		return
	}
	outlines := repository_outlines(t)
	defer delete(outlines.words)
	LABEL :: "Settings"
	label := bytes_to_read(transmute([]u8)string(LABEL))
	placed: [len(LABEL)]text_rendering.Placed_Glyph
	least := max(i64)
	for _ in 0 ..< 200 {
		error: errors.Error_Record
		table := system.Table_To_Append(text_rendering.Placed_Glyph){records = &placed[0], count = 0, capacity = len(LABEL)}
		start := time.tick_now()
		answer := answer_of(shape_text(&outlines.table, i64(text_rendering.Face.Interface), text_rendering.TEXT_SIZE_OF_SCALE_ONE, &label, &table, &error))
		least = min(least, i64(time.tick_since(start)))
		testing.expect_value(t, answer, Answer{.Succeeded, i64(len(LABEL))})
	}
	fmt.printfln("text_rendering: one call of shape_text on a label of %v bytes, the fonts of its face opened, the least of 200: %v ns", len(LABEL), least)
}
// The stack of one call (CALL_STACK_BOUND): the test paints the 64 KiB of
// stack below its frame, makes the call, and finds the lowest byte that
// changed. The calls are the deepest that the module makes: a text of
// mixed direction long enough for the reorder of each glyph, marks, the
// breaks of its lines, and its measure. Each export, each face. A byte
// that a call writes with the paint itself is counted as unused: the bound
// has room for that.
@(private = "file")
STACK_PAINTED :: 64 << 10
@(private = "file")
STACK_PAINT :: u8(0xA5)
// The frame of stack_used_by is below its marker: no call starts above
// this many bytes under it.
@(private = "file")
STACK_FRAME_MARGIN :: 1024

@(private = "file")
Stack_Call :: struct {
	outlines: ^Test_Outlines,
	face:     i64,
	text:     system.Bytes_To_Read,
	placed:   system.Table_To_Append(text_rendering.Placed_Glyph),
	ranges:   system.Table_To_Change(text_rendering.Text_Range),
	lines:    system.Table_To_Append(text_rendering.Text_Range),
	export:   int,
	result:   i64,
	// The exports over the fonts of the process.
	font, glyph: i64,
	points:   system.Table_To_Append(text_rendering.Outline_Word),
	contours: system.Table_To_Append(text_rendering.Contour_End),
	cluster:  system.Table_To_Append(text_rendering.Cell_Cluster),
	marks:    system.Table_To_Append(text_rendering.Cell_Mark),
}

@(private = "file")
stack_call_make :: proc "c" (call: ^Stack_Call) {
	error: errors.Error_Record
	switch call.export {
	case 0:
		call.result = value_of(shape_text(&call.outlines.table, call.face, i64(text_rendering.TEXT_SIZE_OF_SCALE_ONE), &call.text, &call.placed, &error))
	case 1:
		call.result = value_of(measure_texts(&call.outlines.table, call.face, i64(text_rendering.TEXT_SIZE_OF_SCALE_ONE), &call.text, &call.ranges, &error))
	case 2:
		call.result = value_of(break_text(&call.outlines.table, call.face, i64(text_rendering.TEXT_SIZE_OF_SCALE_ONE), &call.text, 40 * 64, &call.lines, &error))
	case 3:
		call.result = value_of(line_shape(call.face, i64(text_rendering.TEXT_SIZE_OF_SCALE_ONE), &call.text, &call.placed, &error))
	case 4:
		call.result = value_of(line_widths(call.face, i64(text_rendering.TEXT_SIZE_OF_SCALE_ONE), &call.text, &call.ranges, &error))
	case 5:
		call.result = value_of(line_fit(call.face, i64(text_rendering.TEXT_SIZE_OF_SCALE_ONE), &call.text, 40 * 64, &error))
	case 6:
		call.result = value_of(glyph_outline(call.face, call.font, call.glyph, &call.points, &call.contours, &error))
	case:
		call.result = value_of(cell_cluster_read(call.face, &call.text, 0, -1, &call.cluster, &call.marks, &error))
	}
}

// stack_used_by gives the bytes of stack that one call used, its margin
// counted as used.
@(private = "file")
stack_used_by :: #force_no_inline proc(call: ^Stack_Call) -> int {
	marker: u8
	top := uintptr(&marker) - STACK_FRAME_MARGIN
	bottom := top - STACK_PAINTED
	for address := bottom; address < top; address += 1 {
		intrinsics.volatile_store((^u8)(address), STACK_PAINT)
	}
	stack_call_make(call)
	deepest := top
	for address := bottom; address < top; address += 1 {
		if intrinsics.volatile_load((^u8)(address)) != STACK_PAINT {
			deepest = address
			break
		}
	}
	return int(top - deepest) + STACK_FRAME_MARGIN
}

// vector_font_source reads a font that VECTOR_FONT_SOURCES of the
// development shell names.
@(private = "file")
vector_font_source :: proc(t: ^testing.T, name: string) -> []u8 {
	sources := os.get_env("VECTOR_FONT_SOURCES", context.temp_allocator)
	testing.expect(t, sources != "", "VECTOR_FONT_SOURCES is set: run the tests in the development shell")
	rest := sources
	prefix := strings.concatenate({name, "="}, context.temp_allocator)
	for item in strings.split_iterator(&rest, ";") {
		if strings.has_prefix(item, prefix) {
			bytes, error := os.read_entire_file(item[len(prefix):], context.temp_allocator)
			if testing.expectf(t, error == nil, "%s can be read", item[len(prefix):]) {
				return bytes
			}
		}
	}
	return nil
}

@(test)
one_call_stays_under_its_stack_bound :: proc(t: ^testing.T) {
	// The fonts of the repository, then a caller whose interface font is
	// the whole Noto Sans, with its GPOS: its marks go through the anchors
	// (mark_anchor_offset), the deepest path of the shaper in a call.
	cases := make([dynamic]Test_Outlines, context.temp_allocator)
	append(&cases, repository_outlines(t))
	if whole := vector_font_source(t, "noto_sans"); whole != nil {
		fonts := [5]font_outlines.Font_Input{{"b612", whole}, {"b612_bold", b612_bold_file}, {"paper_mono", paper_mono_file}, {"paper_mono_semibold", paper_mono_semibold_file}, {"noto_sans", noto_sans_file}}
		append(&cases, test_outlines_of(t, fonts[:]))
	}
	defer for each in cases {
		delete(each.words)
	}
	for &outlines in cases {
		stack_calls_measure(t, &outlines)
	}
}

@(private = "file")
stack_calls_measure :: proc(t: ^testing.T, outlines: ^Test_Outlines) {
	line := "abc \u05D0\u05D1\u05D2 (123) e\u0301 q\u0323\u0302 \u0628\u064A\u062A def "
	text := make([dynamic]u8)
	defer delete(text)
	for len(text) + len(line) < 2 * text_rendering.BIDI_GLYPH_LIMIT {
		append(&text, line)
	}
	placed := make([]text_rendering.Placed_Glyph, 2 * len(text))
	defer delete(placed)
	ranges := [4]text_rendering.Text_Range{{start = 0, count = u32(len(line))}, {start = 0, count = u32(len(text))}, {start = 3, count = 40}, {start = 0, count = 0}}
	lines := make([]text_rendering.Text_Range, len(text))
	defer delete(lines)
	most := 0
	for face in ([?]i64{i64(text_rendering.Face.Interface), i64(text_rendering.Face.Cells_Bold)}) {
		for export in 0 ..< 3 {
			// The exports over the bytes of the caller.
			call := Stack_Call {
				outlines = outlines,
				face     = face,
				text     = bytes_to_read(text[:]),
				placed   = {records = raw_data(placed), capacity = u64(len(placed))},
				ranges   = {records = raw_data(ranges[:]), count = len(ranges)},
				lines    = {records = raw_data(lines), capacity = u64(len(lines))},
				export   = export,
			}
			used := stack_used_by(&call)
			testing.expectf(t, call.result > 0, "the export %d of the face %d answers: %d", export, face, call.result)
			testing.expectf(t, used <= CALL_STACK_BOUND, "the export %d of the face %d uses %d bytes of stack, past %d", export, face, used, CALL_STACK_BOUND)
			most = max(most, used)
		}
	}
	when MEASURE {
		fmt.printfln("one call: at most %d bytes of stack", most)
	}
}

// The fonts of the process for the exports over them: the fonts of the
// repository, and the script font set of the development shell.
@(private = "file")
Process_Test_Fonts :: struct {
	boot:    Test_Outlines,
	scripts: Test_Outlines,
	inputs:  [dynamic]font_outlines.Font_Input,
}

// test_place gives the place of a resource of the test, as a starter maps
// it: its bytes and a span of their size.
@(private = "file")
test_place :: proc(outlines: ^Test_Outlines) -> Resource_Place {
	return {range = {address = u64(uintptr(raw_data(outlines.bytes))), span = u64(len(outlines.bytes))}, mapped = true}
}

// process_test_fonts_open gives the export the places of the fonts of the
// repository and of the script font set of the shell; the first call of
// process_fonts_open opens them, in one room, as in a process.
@(private = "file")
process_test_fonts_open :: proc(t: ^testing.T, fonts: ^Process_Test_Fonts) -> (scripts_open: bool) {
	fonts.boot = repository_outlines(t)
	sources := os.get_env("SCRIPT_FONT_SOURCES", context.temp_allocator)
	testing.expect(t, sources != "", "SCRIPT_FONT_SOURCES is set: run the tests in the development shell or in the check of the flake")
	fonts.inputs = make([dynamic]font_outlines.Font_Input)
	for font in text_rendering.SCRIPT_FONTS {
		name := text_rendering.outline_font_name(font)
		rest := sources
		prefix := strings.concatenate({name, "="}, context.temp_allocator)
		for item in strings.split_iterator(&rest, ";") {
			if strings.has_prefix(item, prefix) {
				if bytes, error := os.read_entire_file(item[len(prefix):], context.allocator); error == nil {
					append(&fonts.inputs, font_outlines.Font_Input{name, bytes})
				}
			}
		}
	}
	process_places_of_test = {test_place(&fonts.boot), {}}
	if len(fonts.inputs) != card(text_rendering.SCRIPT_FONTS) {
		return false
	}
	fonts.scripts = test_outlines_of(t, fonts.inputs[:])
	process_places_of_test[1] = test_place(&fonts.scripts)
	return true
}

@(private = "file")
process_test_fonts_close :: proc(fonts: ^Process_Test_Fonts) {
	text_rendering.state = {}
	process_fonts_stage = .Closed
	process_scripts_mapped = false
	process_places_of_test = {}
	delete(fonts.boot.words)
	delete(fonts.scripts.words)
	for input in fonts.inputs {
		delete(input.bytes)
	}
	delete(fonts.inputs)
}

// The exports over the fonts of the process (process_fonts.odin): each is
// refused before the open; then each refuses what its contract refuses,
// with its error record and nothing written; then the line of each script
// and its glyphs, and the stack of each call against CALL_STACK_BOUND.
// One test, as the fonts of the process are the state of the package.
@(test)
the_exports_over_the_fonts_of_the_process :: proc(t: ^testing.T) {
	size := i64(text_rendering.TEXT_SIZE_OF_SCALE_ONE)
	interface := i64(text_rendering.Face.Interface)
	error: errors.Error_Record
	devanagari := "हिन्दी"
	text := bytes_to_read(transmute([]u8)devanagari)
	placed: [64]text_rendering.Placed_Glyph
	placed_table := system.Table_To_Append(text_rendering.Placed_Glyph){records = &placed[0], capacity = len(placed)}
	points: [vector_font.OUTLINE_POINT_LIMIT]text_rendering.Outline_Word
	contours: [vector_font.OUTLINE_CONTOUR_LIMIT]text_rendering.Contour_End
	points_table := system.Table_To_Append(text_rendering.Outline_Word){records = &points[0], capacity = len(points)}
	contours_table := system.Table_To_Append(text_rendering.Contour_End){records = &contours[0], capacity = len(contours)}
	cluster: [1]text_rendering.Cell_Cluster
	marks: [text_rendering.CLUSTER_MARK_LIMIT]text_rendering.Cell_Mark
	cluster_table := system.Table_To_Append(text_rendering.Cell_Cluster){records = &cluster[0], capacity = 1}
	marks_table := system.Table_To_Append(text_rendering.Cell_Mark){records = &marks[0], capacity = len(marks)}

	// Before the open: Absent, and nothing written.
	expect_error(t, answer_of(line_shape(interface, size, &text, &placed_table, &error)), error, .State, 0, .Wrong_State)
	testing.expect_value(t, placed_table.count, 0)
	whole := [1]text_rendering.Text_Range{{start = 0, count = u32(len(devanagari))}}
	whole_table := system.Table_To_Change(text_rendering.Text_Range){records = &whole[0], count = 1, capacity = 1}
	expect_error(t, answer_of(line_widths(interface, size, &text, &whole_table, &error)), error, .State, 0, .Wrong_State)
	testing.expect_value(t, whole[0].width, 0)
	expect_error(t, answer_of(line_fit(interface, size, &text, 1 << 20, &error)), error, .State, 0, .Wrong_State)
	expect_error(t, answer_of(glyph_find(interface, 'a', &error)), error, .State, 0, .Wrong_State)
	expect_error(t, answer_of(glyph_outline(interface, i64(text_rendering.Outline_Font.B612), 1, &points_table, &contours_table, &error)), error, .State, 0, .Wrong_State)
	expect_error(t, answer_of(cell_cluster_read(interface, &text, 0, -1, &cluster_table, &marks_table, &error)), error, .State, 0, .Wrong_State)
	testing.expect(t, points_table.count == 0 && contours_table.count == 0 && cluster_table.count == 0 && marks_table.count == 0)

	fonts: Process_Test_Fonts
	scripts_open := process_test_fonts_open(t, &fonts)
	defer process_test_fonts_close(&fonts)

	// The records of the fonts of the set: one for each, Open. A second
	// call gives the same records.
	held: [len(text_rendering.Outline_Font)]text_rendering.Held_Font
	for _ in 0 ..< 2 {
		held_table := system.Table_To_Append(text_rendering.Held_Font){records = &held[0], capacity = len(held)}
		count := value_of(process_fonts_open(&held_table, &error))
		if scripts_open {
			testing.expect_value(t, count, i64(card(text_rendering.SCRIPT_FONTS)))
			for record in held[:count] {
				testing.expectf(t, record.standing == .Open && record.glyph_count > 0 && record.stated_cap_height > 0, "the font %d of the set is open, with its measures: %v", record.font, record)
			}
		} else {
			testing.expect_value(t, count, 0)
		}
	}
	// A table with no room takes no record, and the count of the full
	// answer still comes.
	empty_held := system.Table_To_Append(text_rendering.Held_Font){records = &held[0], capacity = 0}
	testing.expect_value(t, value_of(process_fonts_open(&empty_held, &error)), scripts_open ? i64(card(text_rendering.SCRIPT_FONTS)) : 0)
	huge_held := system.Table_To_Append(text_rendering.Held_Font){records = &held[0], capacity = TABLE_LIMIT + 1}
	expect_error(t, answer_of(process_fonts_open(&huge_held, &error)), error, .Too_Long, 1)

	// The refusals of the borders, each with nothing written.
	expect_error(t, answer_of(line_shape(0, size, &text, &placed_table, &error)), error, .Bad_Value, 1)
	expect_error(t, answer_of(line_shape(i64(max(text_rendering.Face)) + 1, size, &text, &placed_table, &error)), error, .Bad_Value, 1)
	expect_error(t, answer_of(line_shape(interface, 0, &text, &placed_table, &error)), error, .Too_Small, 2)
	expect_error(t, answer_of(line_shape(interface, i64(text_rendering.TEXT_SIZE_LIMIT) + 1, &text, &placed_table, &error)), error, .Bad_Value, 2)
	long := bytes_to_read(transmute([]u8)devanagari)
	long.count = text_rendering.TEXT_LIMIT + 1
	expect_error(t, answer_of(line_shape(interface, size, &long, &placed_table, &error)), error, .Too_Long, 3)
	// A range past the bytes, and a range past TEXT_LIMIT: refused with the
	// number of the range, and no width written.
	past := [2]text_rendering.Text_Range{{start = 0, count = 3}, {start = 3, count = u32(len(devanagari))}}
	past_table := system.Table_To_Change(text_rendering.Text_Range){records = &past[0], count = 2, capacity = 2}
	expect_error(t, answer_of(line_widths(interface, size, &text, &past_table, &error)), error, .Out_Of_Range, 4)
	testing.expect(t, error.found == 2 && past[0].width > 0 && past[1].width == 0, "the range 2 is past the bytes; the range 1 has its width")
	huge_range := [1]text_rendering.Text_Range{{start = 0, count = text_rendering.TEXT_LIMIT + 1}}
	huge_range_table := system.Table_To_Change(text_rendering.Text_Range){records = &huge_range[0], count = 1, capacity = 1}
	long_bytes := make([]u8, text_rendering.TEXT_LIMIT + 1)
	defer delete(long_bytes)
	long_text := bytes_to_read(long_bytes)
	expect_error(t, answer_of(line_widths(interface, size, &long_text, &huge_range_table, &error)), error, .Too_Long, 4)
	too_many := system.Table_To_Change(text_rendering.Text_Range){records = &whole[0], count = TABLE_LIMIT + 1, capacity = 1}
	expect_error(t, answer_of(line_widths(interface, size, &text, &too_many, &error)), error, .Too_Long, 4)
	expect_error(t, answer_of(line_fit(interface, size, &long, 0, &error)), error, .Too_Long, 3)
	huge_placed := system.Table_To_Append(text_rendering.Placed_Glyph){records = &placed[0], capacity = TABLE_LIMIT + 1}
	expect_error(t, answer_of(line_shape(interface, size, &text, &huge_placed, &error)), error, .Too_Long, 4)
	testing.expect_value(t, placed_table.count, 0)
	expect_error(t, answer_of(glyph_find(0, 'a', &error)), error, .Bad_Value, 1)
	expect_error(t, answer_of(glyph_find(interface, -1, &error)), error, .Bad_Value, 2)
	expect_error(t, answer_of(glyph_find(interface, 0x110000, &error)), error, .Bad_Value, 2)
	expect_error(t, answer_of(glyph_outline(interface, 0, 1, &points_table, &contours_table, &error)), error, .Bad_Value, 2)
	expect_error(t, answer_of(glyph_outline(interface, i64(max(text_rendering.Outline_Font)) + 1, 1, &points_table, &contours_table, &error)), error, .Bad_Value, 2)
	// A font that no chain of the interface names.
	outside: text_rendering.Outline_Font
	for font in text_rendering.Outline_Font {
		if font != .None && font not_in text_rendering.fonts_of_face(.Interface) {
			outside = font
			break
		}
	}
	testing.expect(t, outside != .None, "a font is outside the chains of the interface")
	expect_error(t, answer_of(glyph_outline(interface, i64(outside), 1, &points_table, &contours_table, &error)), error, .Absent, 2, .Nothing_Has_That_Name)
	b612_glyphs := i64(text_rendering.font_at(&text_rendering.state.font_set, .B612).file.glyph_count)
	expect_error(t, answer_of(glyph_outline(interface, i64(text_rendering.Outline_Font.B612), 0, &points_table, &contours_table, &error)), error, .Bad_Value, 3)
	expect_error(t, answer_of(glyph_outline(interface, i64(text_rendering.Outline_Font.B612), b612_glyphs, &points_table, &contours_table, &error)), error, .Bad_Value, 3)
	testing.expect(t, points_table.count == 0 && contours_table.count == 0)
	expect_error(t, answer_of(cell_cluster_read(interface, &text, -1, -1, &cluster_table, &marks_table, &error)), error, .Out_Of_Range, 3)
	expect_error(t, answer_of(cell_cluster_read(interface, &text, i64(len(devanagari)) + 1, -1, &cluster_table, &marks_table, &error)), error, .Out_Of_Range, 3)
	expect_error(t, answer_of(cell_cluster_read(interface, &long, 0, -1, &cluster_table, &marks_table, &error)), error, .Too_Long, 2)
	testing.expect_value(t, value_of(cell_cluster_read(interface, &text, i64(len(devanagari)), -1, &cluster_table, &marks_table, &error)), 0)

	// The answers: the line of the export is the line of the package.
	spacing, ok := text_rendering.spacing_of(.Interface, int(size))
	testing.expect(t, ok)
	for line in ([?]string{devanagari, "שלום (abc) بيت", "é q̣̂ 中文 ⬛", "Settings"}) {
		bytes := bytes_to_read(transmute([]u8)line)
		placed_table.count = 0
		count := value_of(line_shape(interface, size, &bytes, &placed_table, &error))
		expected: [64]text_rendering.Placed_Glyph
		expected_count, expected_width, _ := text_rendering.shape(&spacing, transmute([]u8)line, expected[:])
		testing.expectf(t, count == i64(expected_count) && count > 0, "%q: %d placed glyphs, the package %d", line, count, expected_count)
		for index in 0 ..< min(int(count), expected_count, len(placed)) {
			testing.expectf(t, placed[index] == expected[index], "%q, glyph %d: %v, the package %v", line, index, placed[index], expected[index])
		}
		line_range := [1]text_rendering.Text_Range{{start = 0, count = u32(len(line))}}
		line_table := system.Table_To_Change(text_rendering.Text_Range){records = &line_range[0], count = 1, capacity = 1}
		testing.expect_value(t, value_of(line_widths(interface, size, &bytes, &line_table, &error)), 1)
		testing.expect_value(t, line_range[0].width, expected_width)
		testing.expect_value(t, value_of(line_fit(interface, size, &bytes, 1 << 30, &error)), i64(len(line)))
		testing.expect_value(t, value_of(line_fit(interface, size, &bytes, -1, &error)), 0)
	}
	// A table too small for the line takes what fits, and the count of the
	// full answer comes.
	small := system.Table_To_Append(text_rendering.Placed_Glyph){records = &placed[0], capacity = 1}
	settings := bytes_to_read(transmute([]u8)string("Settings"))
	testing.expect_value(t, value_of(line_shape(interface, size, &settings, &small, &error)), 8)
	testing.expect_value(t, small.count, 8)

	// The glyphs: a letter of B612, and the ideograph of Noto Sans CJK, a
	// font of CFF outlines, which the module reads for the fast part.
	found := value_of(glyph_find(interface, 'a', &error))
	testing.expect_value(t, text_rendering.Outline_Font(found >> 16), text_rendering.Outline_Font.B612)
	testing.expect_value(t, value_of(glyph_find(interface, 0x0378, &error)), 0)
	outline_of := proc(t: ^testing.T, face, found: i64, points_table: ^system.Table_To_Append(text_rendering.Outline_Word), contours_table: ^system.Table_To_Append(text_rendering.Contour_End), points: []text_rendering.Outline_Word, contours: []text_rendering.Contour_End) {
		error: errors.Error_Record
		points_table.count, contours_table.count = 0, 0
		advance := value_of(glyph_outline(face, found >> 16, found & 0xFFFF, points_table, contours_table, &error))
		testing.expectf(t, advance > 0 && points_table.count > 0 && contours_table.count > 0, "the outline of the glyph %d of the font %d: advance %d, %d points, %d contours", found & 0xFFFF, found >> 16, advance, points_table.count, contours_table.count)
		for word in points[:points_table.count] {
			testing.expect(t, word.on_curve <= 1)
		}
		before := i64(0)
		for end in contours[:contours_table.count] {
			testing.expect(t, end.after > before && end.after <= i64(points_table.count))
			before = end.after
		}
	}
	outline_of(t, interface, found, &points_table, &contours_table, points[:], contours[:])
	// Tables of one point and of one contour have no room for the outline.
	one_point := system.Table_To_Append(text_rendering.Outline_Word){records = &points[0], capacity = 1}
	contours_table.count = 0
	expect_error(t, answer_of(glyph_outline(interface, found >> 16, found & 0xFFFF, &one_point, &contours_table, &error)), error, .Full, 4, .Budget_Or_Capacity_Exhausted)
	// A table that holds records already is refused: the outline starts it.
	points_table.count = 1
	expect_error(t, answer_of(glyph_outline(interface, found >> 16, found & 0xFFFF, &points_table, &contours_table, &error)), error, .Bad_Value, 4)
	points_table.count = 0
	if scripts_open {
		ideograph := value_of(glyph_find(interface, 0x4E2D, &error))
		testing.expect_value(t, text_rendering.Outline_Font(ideograph >> 16), text_rendering.Outline_Font.Noto_Sans_CJK)
		outline_of(t, interface, ideograph, &points_table, &contours_table, points[:], contours[:])
	}

	// The clusters of the cells: a letter and its mark compose; two marks
	// that stay apart need a table of marks with room for them.
	cells := i64(text_rendering.Face.Cells)
	composed := bytes_to_read(transmute([]u8)string("éx"))
	cluster_table.count, marks_table.count = 0, 0
	testing.expect_value(t, value_of(cell_cluster_read(cells, &composed, 0, -1, &cluster_table, &marks_table, &error)), 1)
	testing.expectf(t, cluster[0].base == 0x00E9 && cluster[0].mark_count == 0 && cluster[0].end == 3, "e and U+0301 make one cluster of é: %v", cluster[0])
	expect_error(t, answer_of(cell_cluster_read(cells, &composed, 0, -1, &cluster_table, &marks_table, &error)), error, .Full, 5, .Budget_Or_Capacity_Exhausted)
	apart := bytes_to_read(transmute([]u8)string("q̣̂"))
	cluster_table.count = 0
	no_marks := system.Table_To_Append(text_rendering.Cell_Mark){records = &marks[0], capacity = 1}
	expect_error(t, answer_of(cell_cluster_read(cells, &apart, 0, -1, &cluster_table, &no_marks, &error)), error, .Full, 6, .Budget_Or_Capacity_Exhausted)
	testing.expect(t, cluster_table.count == 0 && no_marks.count == 0)

	// The stack of each export over the fonts of the process, with the
	// longest line of the scripts of India, Khmer, Myanmar, Tibetan,
	// Arabic, Hebrew, brackets and marks, in each face.
	line := "हिन्दी क्षि ក្រុ မြန်မာ བསྒྲུབས بيت אב (123) é q̣̂ กำ "
	long_line := make([dynamic]u8)
	defer delete(long_line)
	for len(long_line) + len(line) < 2 * text_rendering.BIDI_GLYPH_LIMIT {
		append(&long_line, line)
	}
	long_placed := make([]text_rendering.Placed_Glyph, 2 * len(long_line))
	defer delete(long_placed)
	long_range := [1]text_rendering.Text_Range{{start = 0, count = u32(len(long_line))}}
	most := 0
	for face in ([?]i64{interface, i64(text_rendering.Face.Cells_Bold)}) {
		for export in 3 ..< 8 {
			call := Stack_Call {
				face     = face,
				text     = bytes_to_read(long_line[:]),
				placed   = {records = raw_data(long_placed), capacity = u64(len(long_placed))},
				ranges   = {records = &long_range[0], count = 1, capacity = 1},
				export   = export,
				font     = found >> 16,
				glyph    = found & 0xFFFF,
				points   = {records = &points[0], capacity = len(points)},
				contours = {records = &contours[0], capacity = len(contours)},
				cluster  = {records = &cluster[0], capacity = 1},
				marks    = {records = &marks[0], capacity = len(marks)},
			}
			used := stack_used_by(&call)
			testing.expectf(t, call.result >= 0, "the export %d of the face %d answers: %d", export, face, call.result)
			testing.expectf(t, used <= CALL_STACK_BOUND, "the export %d of the face %d uses %d bytes of stack, past %d", export, face, used, CALL_STACK_BOUND)
			most = max(most, used)
		}
	}
	when MEASURE {
		fmt.printfln("one call over the fonts of the process: at most %d bytes of stack on the host; the records of its deepest path, the bound of the freestanding build: %d bytes, of %d", most, size_of(text_rendering.Spacing) + text_rendering.SHAPE_STACK_RECORDS_BYTES, CALL_STACK_BOUND - CALL_STACK_BOUND / 8)
		fmt.printfln("one call over bytes: the records of its deepest path, the bound of the freestanding build: %d bytes, of %d", size_of(Call_Fonts) + size_of(font_outlines.Outlines) + text_rendering.SHAPE_STACK_RECORDS_BYTES, CALL_STACK_BOUND - CALL_STACK_BOUND / 8)
	}

	// A second thread that calls during an open waits for its end, then
	// gets the records of that open: the export never refuses it for the
	// life of the process.
	if scripts_open {
		text_rendering.state = {}
		process_scripts_mapped = false
		intrinsics.atomic_store(&process_fonts_stage, .Opening)
		Waiter :: struct {
			done:    bool,
			count:   i64,
			records: [len(text_rendering.Outline_Font)]text_rendering.Held_Font,
		}
		waiter: Waiter
		waiting := thread.create_and_start_with_data(&waiter, proc(data: rawptr) {
			waiter := (^Waiter)(data)
			table := system.Table_To_Append(text_rendering.Held_Font){records = &waiter.records[0], capacity = len(waiter.records)}
			error: errors.Error_Record
			waiter.count = value_of(process_fonts_open(&table, &error))
			intrinsics.atomic_store(&waiter.done, true)
		})
		boot_place, set_place := process_places()
		process_fonts_open_at(boot_place, set_place)
		intrinsics.atomic_store(&process_fonts_stage, .Open)
		// The waiter ends once the stage is Open; the time only ends a hang.
		started := time.tick_now()
		for !intrinsics.atomic_load(&waiter.done) {
			if time.duration_milliseconds(time.tick_since(started)) > f64(system.TEST_HANG_BOUND_MILLISECONDS) {
				testing.expect(t, false, "the waiter did not end within the hang bound")
				return
			}
			thread.yield()
		}
		thread.join(waiting)
		thread.destroy(waiting)
		testing.expect_value(t, waiter.count, i64(card(text_rendering.SCRIPT_FONTS)))
		testing.expect(t, waiter.records[0].standing == .Open, "the waiter reads the fonts of the open that it waited for")
	}

	// A set with a record named as a font of the boot image: the boot
	// fonts open from the font outlines before the room takes the records
	// of the set, and the set opens its own fonts only. The record of the
	// set never names bytes of the font outlines.
	if !scripts_open {
		return
	}
	boot_b612_glyphs := text_rendering.font_at(&text_rendering.state.font_set, .B612).file.glyph_count
	text_rendering.state = {}
	process_fonts_stage = .Closed
	process_scripts_mapped = false
	hebrew: []u8
	for input in fonts.inputs {
		if input.name == "noto_sans_hebrew" {
			hebrew = input.bytes
		}
	}
	hostile_inputs := [2]font_outlines.Font_Input{{"b612", hebrew}, {"noto_sans_hebrew", hebrew}}
	hostile := test_outlines_of(t, hostile_inputs[:])
	defer delete(hostile.words)
	process_places_of_test[1] = test_place(&hostile)
	held_table := system.Table_To_Append(text_rendering.Held_Font){records = &held[0], capacity = len(held)}
	testing.expect_value(t, value_of(process_fonts_open(&held_table, &error)), i64(card(text_rendering.SCRIPT_FONTS)))
	b612 := text_rendering.font_at(&text_rendering.state.font_set, .B612)
	testing.expectf(t, b612.opened && b612.file.glyph_count == boot_b612_glyphs, "B612 is the font of the outlines: %d glyphs, the outlines hold %d", b612.file.glyph_count, boot_b612_glyphs)
	testing.expect(t, text_rendering.font_at(&text_rendering.state.font_set, .Noto_Sans_Hebrew).opened, "the set opens its Hebrew font")
	placed_table.count = 0
	testing.expect_value(t, value_of(line_shape(interface, size, &settings, &placed_table, &error)), 8)
}
