// The text rendering as a module (src/md/features/text_rendering.md, "The
// library module"): each export calls one function of
// src/library/modus/text_rendering over the bytes and the tables of the
// caller. The caller gives the font outlines as bytes: the resource
// font_outlines that its starter mapped, or a copy of it. Each call opens
// the fonts of those bytes on its stack and measures with them; the module
// keeps nothing between two calls, so an isolated call gives the same
// answer as a direct call.
//
// The bytes are hostile input: in an isolated call they are in the call
// region, which another thread can change during the call. The header and
// the records of the outlines are copied once and checked
// (font_outlines.validate); the parser of the fonts checks each read of a
// font file against its bytes; each advance and each pair is kept in its
// bound when it is read. A changed byte gives other numbers, never a read
// out of the bytes and never a sum that wraps.
//
// **What it is for.** A caller that does not compile the package (a
// module of a third party, an isolated call) places the glyphs of a text,
// measures many texts in one call, and breaks a text into the lines of a
// box, with the numbers of a process that compiles the package in.
//
// **The units**: each position, width and room is in 1/64 of a pixel. A
// face is a number of text_rendering.Face (1 Interface, 2 Interface_Bold,
// 3 Cells, 4 Cells_Without_Grid_Fit, 5 Cells_Bold); a text size is the
// height of a line in 1/64 of a pixel, from 256 to 16384.
//
// **What it does not do**: no script font (the caller gives the font
// outlines only, so Hebrew, Arabic, the ideographs and the emoji are the
// replacement glyph), no shaping of the scripts of India and of Southeast
// Asia. The composition of the marks and the order of a line of mixed
// direction are those of the package.
package text_rendering_module

import "modus:contract/errors"
import "modus:contract/font_outlines"
import "modus:system"
import "modus:text_rendering"

// The most records or bytes of a table of a caller, its count included: no
// count times a size wraps, and a count holds in the i64 of the result.
@(private)
TABLE_LIMIT :: u64(1) << 40

// The fonts of one call, opened from the bytes of the caller, and the
// memory of the outlines of their measures, on the stack of the call. A
// call runs on the stack of a worker thread of its caller, 64 KiB: the
// whole call stays under CALL_STACK_BOUND, which a host test measures.
@(private)
Call_Fonts :: struct {
	set:     text_rendering.Font_Set,
	// The room of the set: a call opens the fonts of the boot image only,
	// so a script font takes none of the stack of a call.
	room:    [text_rendering.BOOT_FONT_COUNT]text_rendering.Font,
	outline: text_rendering.Measure_Memory,
}

// The most stack that one call uses, its locals and those of each
// procedure that it calls: a quarter of the stack of a worker thread.
CALL_STACK_BOUND :: 16 << 10
// The fonts of a call take less than two thirds of it: the shaper, the
// order of a line and the open of a font take the rest
// (one_call_stays_under_its_stack_bound measures the whole call).
#assert(size_of(Call_Fonts) <= 10 << 10)

// face_and_size_check refuses a face (argument 2) and a text size
// (argument 3) with an error record.
@(private)
face_and_size_check :: proc "contextless" (face_word, size: i64, error: ^errors.Error_Record) -> (face: text_rendering.Face, ok: bool) {
	face, ok = text_rendering.face_of_word(face_word)
	if !ok {
		errors.fail(error, -1, .Bad_Value, .None, 2, face_word, i64(max(text_rendering.Face)))
		return .None, false
	}
	switch text_rendering.size_check(int(size)) {
	case .None:
	case .Zero, .Too_Small:
		errors.fail(error, -1, .Too_Small, .None, 3, size, text_rendering.TEXT_SIZE_MINIMUM)
		return .None, false
	case .Too_Large:
		errors.fail(error, -1, .Bad_Value, .None, 3, size, text_rendering.TEXT_SIZE_LIMIT)
		return .None, false
	}
	return face, true
}

// call_spacing opens the fonts of the outlines of the caller (argument 1)
// into fonts and gives the spacing of the face at the size. It gives an
// error record for outlines that font_outlines.validate refuses (Bad_Value:
// value the font_outlines.Problem_Kind, found the record from 1), for more
// bytes than TABLE_LIMIT (Too_Long), and for outlines with no first font of
// the face (Absent: value the text_rendering.Outline_Font).
@(private)
call_spacing :: proc "contextless" (fonts: ^Call_Fonts, outlines: ^system.Bytes_To_Read, face: text_rendering.Face, size: i64, error: ^errors.Error_Record) -> (spacing: text_rendering.Spacing, ok: bool) {
	count := outlines.count
	if count > TABLE_LIMIT {
		errors.fail(error, -1, .Too_Long, .Bytes, 1, i64(min(count, TABLE_LIMIT + 1)), i64(TABLE_LIMIT))
		return {}, false
	}
	resource, problem := font_outlines.validate(outlines.bytes[:count])
	if problem.kind != .None {
		errors.fail(error, -1, .Bad_Value, .Bytes, 1, i64(problem.kind), 0, i64(problem.index) + 1)
		return {}, false
	}
	fonts.set.room = fonts.room[:]
	outline := text_rendering.measure_outline_of(&fonts.outline)
	// Only the fonts that the chains of the face name: each open reads the
	// outlines of 94 characters for its measures.
	_ = text_rendering.fonts_open(&fonts.set, &resource, &outline, text_rendering.fonts_of_face(face))
	spacing, ok = text_rendering.spacing_in(&fonts.set, face, int(size))
	if !ok {
		errors.fail(error, -1, .Absent, .None, 1, i64(text_rendering.face_forms[face].primary))
		return {}, false
	}
	return spacing, true
}

// shape_text appends the placed glyphs of a UTF-8 text in a face at a text size, measured from the font files of the outlines: one for each character, x from the origin of the text and the advance with the pair adjustment of the font, in 1/64 of a pixel, and the first byte of the character as its cluster. The glyph is the character index for 32 to 126 (0 to 94), U+00A0 to U+00FF (95 to 190) and the euro sign (191); 16777216 plus the code point for another character that a font of the chain of the face has; 4294967295, the replacement glyph, with the advance of "0", for a character that no font of the chain has and each invalid sequence. The outlines are the resource font_outlines, on 8 bytes. The result is the count of placed glyphs of the full answer (larger than the capacity: it did not fit), or -1 with an error record: a face that is not 1 to 5 (argument 2), a size under 256 or over 16384 (argument 3), a text of more than 65536 bytes (argument 4), a table of placed glyphs over 2^40 records (argument 5), outlines that are refused or lack the first font of the face (argument 1). Nothing is written on a refusal.
@(export, link_name = "shape_text")
shape_text :: proc "c" (outlines: ^system.Bytes_To_Read, face: i64, size: i64, text: ^system.Bytes_To_Read, placed: ^system.Table_To_Append(text_rendering.Placed_Glyph), error: ^errors.Error_Record) -> i64 {
	face_checked, face_ok := face_and_size_check(face, size, error)
	if !face_ok {
		return -1
	}
	text_count := text.count
	if text_count > text_rendering.TEXT_LIMIT {
		return errors.fail(error, -1, .Too_Long, .Bytes, 4, i64(min(text_count, TABLE_LIMIT)), text_rendering.TEXT_LIMIT)
	}
	capacity, placed_count := placed.capacity, placed.count
	if capacity > TABLE_LIMIT || placed_count > TABLE_LIMIT {
		return errors.fail(error, -1, .Too_Long, .Records, 5, i64(min(max(capacity, placed_count), TABLE_LIMIT + 1)), i64(TABLE_LIMIT))
	}
	fonts: Call_Fonts
	spacing, ok := call_spacing(&fonts, outlines, face_checked, size, error)
	if !ok {
		return -1
	}
	// The Append rule: write only at or after the count and before the
	// capacity; the count grows by the full answer.
	room: []text_rendering.Placed_Glyph
	if placed_count < capacity {
		room = placed.records[placed_count:][:capacity - placed_count]
	}
	count, _, _ := text_rendering.shape(&spacing, text.bytes[:text_count], room)
	placed.count = placed_count + u64(count)
	return i64(placed.count)
}

// measure_texts writes the width of each text of a table of ranges into one table of bytes, in a face at a text size, in 1/64 of a pixel: a window measures all its labels in one call. The width of a text is the sum of the advances of its placed glyphs (shape_text). The result is the count of ranges, or -1 with an error record: a face (argument 2) or a size (argument 3) as for shape_text, a table of bytes (argument 4) or of ranges (argument 5) over 2^40, outlines as for shape_text (argument 1), a range past the end of the bytes (Out_Of_Range: its end, the count of bytes, the number of the range from 1), or a range of more than 65536 bytes (Too_Long: its count, the limit, the number of the range from 1). The ranges before the one that fails have their width; it and the ranges after it are not written.
@(export, link_name = "measure_texts")
measure_texts :: proc "c" (outlines: ^system.Bytes_To_Read, face: i64, size: i64, text: ^system.Bytes_To_Read, ranges: ^system.Table_To_Change(text_rendering.Text_Range), error: ^errors.Error_Record) -> i64 {
	face_checked, face_ok := face_and_size_check(face, size, error)
	if !face_ok {
		return -1
	}
	text_count, range_count := text.count, ranges.count
	if text_count > TABLE_LIMIT {
		return errors.fail(error, -1, .Too_Long, .Bytes, 4, i64(min(text_count, TABLE_LIMIT + 1)), i64(TABLE_LIMIT))
	}
	if range_count > TABLE_LIMIT {
		return errors.fail(error, -1, .Too_Long, .Records, 5, i64(min(range_count, TABLE_LIMIT + 1)), i64(TABLE_LIMIT))
	}
	fonts: Call_Fonts
	spacing, ok := call_spacing(&fonts, outlines, face_checked, size, error)
	if !ok {
		return -1
	}
	problem, index, end := text_rendering.measure_ranges(&spacing, text.bytes[:text_count], ranges.records[:range_count])
	switch problem {
	case .Past_The_Text:
		return errors.fail(error, -1, .Out_Of_Range, .Bytes, 5, i64(end), i64(text_count), i64(index + 1))
	case .Too_Long:
		return errors.fail(error, -1, .Too_Long, .Bytes, 5, i64(end), text_rendering.TEXT_LIMIT, i64(index + 1))
	case .None:
	}
	return i64(range_count)
}

// break_text appends the lines of a UTF-8 text in a box of room, in a face at a text size: each line as a range of the text (its first byte, its bytes with no space at its end, and its width in 1/64 of a pixel). A line ends at the last space that fits; a word wider than the box ends a line after its last "/", ":" or "_" that fits, else after its last character that fits; a line has at least one whole character, also in a room of 0 or below. The lines, joined, are the text with no space at a break. An empty text has no line. The result is the count of lines of the full answer (larger than the capacity: it did not fit), or -1 with an error record: a face (argument 2) or a size (argument 3) as for shape_text, a text of more than 65536 bytes (argument 4), a table of lines over 2^40 records (argument 6), outlines as for shape_text (argument 1). Nothing is written on a refusal.
@(export, link_name = "break_text")
break_text :: proc "c" (outlines: ^system.Bytes_To_Read, face: i64, size: i64, text: ^system.Bytes_To_Read, room: i64, lines: ^system.Table_To_Append(text_rendering.Text_Range), error: ^errors.Error_Record) -> i64 {
	face_checked, face_ok := face_and_size_check(face, size, error)
	if !face_ok {
		return -1
	}
	text_count := text.count
	if text_count > text_rendering.TEXT_LIMIT {
		return errors.fail(error, -1, .Too_Long, .Bytes, 4, i64(min(text_count, TABLE_LIMIT)), text_rendering.TEXT_LIMIT)
	}
	capacity, line_count := lines.capacity, lines.count
	if capacity > TABLE_LIMIT || line_count > TABLE_LIMIT {
		return errors.fail(error, -1, .Too_Long, .Records, 6, i64(min(max(capacity, line_count), TABLE_LIMIT + 1)), i64(TABLE_LIMIT))
	}
	fonts: Call_Fonts
	spacing, ok := call_spacing(&fonts, outlines, face_checked, size, error)
	if !ok {
		return -1
	}
	bytes := text.bytes[:text_count]
	start := 0
	found: u64
	for start < len(bytes) {
		rest := bytes[start:]
		end, next := text_rendering.line_break(&spacing, rest, room)
		// The rest is always shorter than the text: a break of no byte
		// would never end the loop.
		if next <= 0 || next > len(rest) {
			next = len(rest)
		}
		end = clamp(end, 0, len(rest))
		width, _ := text_rendering.text_width(&spacing, rest[:end])
		if line_count + found < capacity {
			lines.records[line_count + found] = {start = u32(start), count = u32(end), width = width}
		}
		found += 1
		start += next
	}
	lines.count = line_count + found
	return i64(lines.count)
}
