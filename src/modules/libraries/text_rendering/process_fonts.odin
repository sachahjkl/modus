package text_rendering_module

import "base:intrinsics"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/fixed_addresses"
import "modus:contract/font_outlines"
import "modus:system"
import "modus:text_rendering"
import "modus:vector_font"

// The written part for the processes that import this module
// (src/md/features/text_rendering.md, "Where the written shaping lives").
// A module of the system compiles the fast part of the package only: it
// places a text of simple characters itself, and calls these exports for
// each other line, for a glyph of a font of the script font set, and for a
// cluster of a grid of cells that is not simple. The exports work over the
// fonts of the process that calls them, which this copy of the module
// opens once from the fixed ranges of that process: the loader gives each
// process one copy of the data of the module, and puts the module in a
// process once. After the open the fonts are only read, so two threads of the
// process call at once with no lock.

// Where the fonts of the process stand in this copy.
@(private)
Process_Fonts_Stage :: enum u32 {
	Closed  = 0,
	Opening = 1, // One thread opens them: a call of another thread is refused.
	Open    = 2, // Opened, whole or not: the exports read them.
}

@(private)
process_fonts_stage: Process_Fonts_Stage
// The room of the records of the font outlines and of the script font set:
// each is opened in turn, and no record is kept past its open.
@(private)
process_records_room: font_outlines.Record_Room
// The starter mapped a script font set, and its fonts were opened.
@(private)
process_scripts_mapped: bool

// The place of a resource of fonts in the process: where its starter
// mapped it, the span of its range, and whether it mapped it.
@(private)
Resource_Place :: struct {
	range:  fixed_addresses.Address_Range,
	mapped: bool,
}

when ODIN_OS == .Freestanding {
	// process_places gives the fixed ranges of the font outlines and of the
	// script font set of the calling process.
	@(private)
	process_places :: proc "contextless" () -> (boot, scripts: Resource_Place) {
		mapped := fixed_addresses.ranges_mapped(&system.context_record().values)
		boot_range := fixed_addresses.range_of(.Font_Outlines)
		set_range := fixed_addresses.range_of(.Script_Fonts)
		boot = {range = boot_range, mapped = .Font_Outlines in mapped}
		scripts = {range = set_range, mapped = .Script_Fonts in mapped}
		return
	}
} else {
	// A host test gives the places of its resources, as a starter maps them,
	// so the export runs the path of a process.
	@(private)
	process_places_of_test: [2]Resource_Place
	@(private)
	process_places :: proc "contextless" () -> (boot, scripts: Resource_Place) {
		return process_places_of_test[0], process_places_of_test[1]
	}
}

// process_fonts_open_at opens the fonts of the process into the state of
// this copy: the font outlines, then the script font set when its starter
// mapped one. One room holds the records of each in turn, so the fonts of
// the boot image are opened before the room takes the records of the set:
// an open reads the records that its validation copied. A record of the
// set named as a font of the boot image is not read: the set opens the
// fonts of the script font set only.
@(private)
process_fonts_open_at :: proc "contextless" (boot, scripts: Resource_Place) {
	if !boot.mapped {
		return
	}
	outlines, problem := font_outlines.validate_at(uintptr(boot.range.address), boot.range.span, process_records_room[:])
	if problem.kind != .None {
		return
	}
	_ = text_rendering.open(&outlines)
	if !scripts.mapped {
		return
	}
	set, set_problem := font_outlines.validate_at(uintptr(scripts.range.address), scripts.range.span, process_records_room[:])
	if set_problem.kind != .None {
		return
	}
	_ = text_rendering.script_fonts_open(&set)
	process_scripts_mapped = true
}

// process_fonts_ready gives the spacing of a face at a size over the fonts
// of the process, with an error record for a face (argument 1) and a size
// (argument 2) that face_and_size_check refuses, and Absent before the
// open of the fonts of the process or when they lack the first font of the
// face.
@(private)
process_spacing :: proc "contextless" (face_word, size: i64, error: ^errors.Error_Record) -> (spacing: text_rendering.Spacing, outcome: call_outcome.Call_Outcome) {
	face, face_outcome := process_face_and_size_check(face_word, size, error)
	if face_outcome != .Succeeded {
		return {}, face_outcome
	}
	if intrinsics.atomic_load_explicit(&process_fonts_stage, .Acquire) != .Open {
		return {}, refuse(error, .Wrong_State, .State, .None, 0)
	}
	spacing_ok: bool
	spacing, spacing_ok = text_rendering.spacing_of(face, int(size))
	if !spacing_ok {
		return {}, refuse(error, .Nothing_Has_That_Name, .Absent, .None, 1, i64(text_rendering.face_forms[face].primary))
	}
	return spacing, .Succeeded
}

// refuse writes the error record of a refusal of a check and gives its
// call outcome, which the export gives with no value.
@(private = "file")
refuse :: proc "contextless" (error: ^errors.Error_Record, outcome: call_outcome.Call_Outcome, kind: errors.Kind, unit: errors.Unit = .None, argument: i64 = 0, value: i64 = 0, limit: i64 = 0, found: i64 = 0) -> call_outcome.Call_Outcome {
	refused, _ := call_outcome.fail(error, outcome, kind, unit, argument, value, limit, found)
	return refused
}

// process_face_and_size_check is face_and_size_check for the exports over
// the fonts of the process, whose face is argument 1 and size argument 2.
@(private)
process_face_and_size_check :: proc "contextless" (face_word, size: i64, error: ^errors.Error_Record) -> (face: text_rendering.Face, outcome: call_outcome.Call_Outcome) {
	face_ok: bool
	face, face_ok = text_rendering.face_of_word(face_word)
	if !face_ok {
		return .None, refuse(error, .Argument_Refused, .Bad_Value, .None, 1, face_word, i64(max(text_rendering.Face)))
	}
	switch text_rendering.size_check(int(size)) {
	case .None:
	case .Zero, .Too_Small:
		return .None, refuse(error, .Argument_Refused, .Too_Small, .None, 2, size, text_rendering.TEXT_SIZE_MINIMUM)
	case .Too_Large:
		return .None, refuse(error, .Argument_Refused, .Bad_Value, .None, 2, size, text_rendering.TEXT_SIZE_LIMIT)
	}
	return face, .Succeeded
}

// process_text checks a text argument: at most TEXT_LIMIT bytes.
@(private)
process_text :: proc "contextless" (text: ^system.Bytes_To_Read, argument: i64, error: ^errors.Error_Record) -> (bytes: []u8, outcome: call_outcome.Call_Outcome) {
	count := text.count
	if count > text_rendering.TEXT_LIMIT {
		return nil, refuse(error, .Argument_Refused, .Too_Long, .Bytes, argument, i64(min(count, TABLE_LIMIT)), text_rendering.TEXT_LIMIT)
	}
	return text.bytes[:count], .Succeeded
}

// process_fonts_open opens the fonts of the calling process for the written part, once: the font outlines that its starter mapped, and the script font set when the starter mapped one, with the caches of the walk of their tables. It appends one record for each font of the script font set when the starter mapped a set: Open (its measures and its glyph count), Missing, or Refused (its tables of GSUB and GPOS pass the bound of their read). A second call opens nothing and appends the same records; a call while another thread of the process opens them waits for the end of that open, whose reads are bounded. The result is the count of records of the full answer, or -1 with an error record: a table over 2^40 records (argument 1, Too_Long).
@(export, link_name = "process_fonts_open")
process_fonts_open :: proc "c" (held: ^system.Table_To_Append(text_rendering.Held_Font), error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	capacity, held_count := held.capacity, held.count
	if capacity > TABLE_LIMIT || held_count > TABLE_LIMIT {
		return call_outcome.fail(error, .Argument_Refused, .Too_Long, .Records, 1, i64(min(max(capacity, held_count), TABLE_LIMIT + 1)), i64(TABLE_LIMIT))
	}
	// One thread opens; a thread that comes during the open waits for its
	// end, as the open is bounded by the reads of each font.
	for stage := intrinsics.atomic_load_explicit(&process_fonts_stage, .Acquire); stage != .Open; stage = intrinsics.atomic_load_explicit(&process_fonts_stage, .Acquire) {
		switch stage {
		case .Closed:
			if _, opening := intrinsics.atomic_compare_exchange_strong_explicit(&process_fonts_stage, .Closed, .Opening, .Acquire, .Acquire); opening {
				boot, scripts := process_places()
				process_fonts_open_at(boot, scripts)
				intrinsics.atomic_store_explicit(&process_fonts_stage, .Open, .Release)
			}
		case .Opening:
			intrinsics.cpu_relax()
		case .Open:
		}
	}
	found: u64
	if process_scripts_mapped {
		for font in text_rendering.SCRIPT_FONTS {
			if held_count + found < capacity {
				held.records[held_count + found] = text_rendering.held_font_of(font)
			}
			found += 1
		}
	}
	held.count = held_count + found
	return .Succeeded, i64(held.count)
}

// line_shape appends the placed glyphs of a UTF-8 text of one line in a face at a text size, over the fonts of the calling process, the written part whole: the marks, Arabic, Thai, the scripts of India and the order of a line of mixed direction. The placed glyphs are those of shape_text. The result is the count of placed glyphs of the full answer (larger than the capacity: it did not fit), or a call outcome with an error record: a face that is not 1 to 5 (argument 1), a size under 256 or over 16384 (argument 2), a text of more than 65536 bytes (argument 3), a table over 2^40 records (argument 4), or fonts of the process that are not open or lack the first font of the face (Absent). Nothing is written on a refusal.
@(export, link_name = "line_shape")
line_shape :: proc "c" (face: i64, size: i64, text: ^system.Bytes_To_Read, placed: ^system.Table_To_Append(text_rendering.Placed_Glyph), error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	spacing, spacing_outcome := process_spacing(face, size, error)
	if spacing_outcome != .Succeeded {
		return spacing_outcome, 0
	}
	bytes, text_outcome := process_text(text, 3, error)
	if text_outcome != .Succeeded {
		return text_outcome, 0
	}
	capacity, placed_count := placed.capacity, placed.count
	if capacity > TABLE_LIMIT || placed_count > TABLE_LIMIT {
		return call_outcome.fail(error, .Argument_Refused, .Too_Long, .Records, 4, i64(min(max(capacity, placed_count), TABLE_LIMIT + 1)), i64(TABLE_LIMIT))
	}
	room: []text_rendering.Placed_Glyph
	if placed_count < capacity {
		room = placed.records[placed_count:][:capacity - placed_count]
	}
	count, _, _ := text_rendering.shape(&spacing, bytes, room)
	placed.count = placed_count + u64(count)
	return .Succeeded, i64(placed.count)
}

// line_widths writes the width of each text of a table of ranges into one table of bytes, in a face at a text size, over the fonts of the calling process, in 1/64 of a pixel: the sum of the advances of its placed glyphs (line_shape). A width is a field of its range, so a width below 0, when the pairs of a font take more than the advances, is told apart from a refusal. The result is the count of ranges, or a call outcome with an error record: a face (argument 1) or a size (argument 2) as for line_shape, a table of bytes (argument 3) or of ranges (argument 4) over 2^40, a range past the end of the bytes (Out_Of_Range: its end, the count of bytes, the number of the range from 1), a range of more than 65536 bytes (Too_Long: its count, the limit, the number of the range from 1), or fonts of the process that are not open (Absent). The ranges before the one that fails have their width; it and the ranges after it are not written.
@(export, link_name = "line_widths")
line_widths :: proc "c" (face: i64, size: i64, text: ^system.Bytes_To_Read, ranges: ^system.Table_To_Change(text_rendering.Text_Range), error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	spacing, spacing_outcome := process_spacing(face, size, error)
	if spacing_outcome != .Succeeded {
		return spacing_outcome, 0
	}
	text_count, range_count := text.count, ranges.count
	if text_count > TABLE_LIMIT {
		return call_outcome.fail(error, .Argument_Refused, .Too_Long, .Bytes, 3, i64(min(text_count, TABLE_LIMIT + 1)), i64(TABLE_LIMIT))
	}
	if range_count > TABLE_LIMIT {
		return call_outcome.fail(error, .Argument_Refused, .Too_Long, .Records, 4, i64(min(range_count, TABLE_LIMIT + 1)), i64(TABLE_LIMIT))
	}
	problem, index, end := text_rendering.measure_ranges(&spacing, text.bytes[:text_count], ranges.records[:range_count])
	switch problem {
	case .Past_The_Text:
		return call_outcome.fail(error, .Argument_Refused, .Out_Of_Range, .Bytes, 4, i64(end), i64(text_count), i64(index + 1))
	case .Too_Long:
		return call_outcome.fail(error, .Argument_Refused, .Too_Long, .Bytes, 4, i64(end), text_rendering.TEXT_LIMIT, i64(index + 1))
	case .None:
	}
	return .Succeeded, i64(range_count)
}

// line_fit gives the bytes of the longest start of a UTF-8 text in a face at a text size, over the fonts of the calling process, whose width is at most room, in 1/64 of a pixel: whole clusters, so a cut never splits a character, a letter from its marks or a syllable. 0 for a room below the first advance. The result is the bytes, or a call outcome with an error record: a face (argument 1), a size (argument 2) or a text (argument 3) as for line_shape, or fonts of the process that are not open (Absent).
@(export, link_name = "line_fit")
line_fit :: proc "c" (face: i64, size: i64, text: ^system.Bytes_To_Read, room: i64, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	spacing, spacing_outcome := process_spacing(face, size, error)
	if spacing_outcome != .Succeeded {
		return spacing_outcome, 0
	}
	bytes, text_outcome := process_text(text, 3, error)
	if text_outcome != .Succeeded {
		return text_outcome, 0
	}
	return .Succeeded, i64(text_rendering.text_fit(&spacing, bytes, room))
}

// glyph_find finds a character in the chain of a face, over the fonts of the calling process, the script font set with them: the first font that has it. The result is the font (a text_rendering.Outline_Font) times 65536 plus the glyph index in that font, 0 for a character that no font of the chain has, or a call outcome with an error record: a face that is not 1 to 5 (argument 1), a character past U+10FFFF or below 0 (argument 2), or fonts of the process that are not open (Absent).
@(export, link_name = "glyph_find")
glyph_find :: proc "c" (face: i64, character: i64, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	face_checked, face_ok := text_rendering.face_of_word(face)
	if !face_ok {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 1, face, i64(max(text_rendering.Face)))
	}
	if character < 0 || character > 0x10FFFF {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 2, character, 0x10FFFF)
	}
	if intrinsics.atomic_load_explicit(&process_fonts_stage, .Acquire) != .Open {
		return call_outcome.fail(error, .Wrong_State, .State, .None, 0)
	}
	font, index := text_rendering.font_glyph_of(face_checked, rune(character))
	if font == .None {
		return .Succeeded, 0
	}
	return .Succeeded, i64(font) << 16 | i64(index & 0xFFFF)
}

// glyph_outline appends the outline of a glyph of a font of the chain of a face, over the fonts of the calling process: its points, in units of the font, and the index after the last point of each contour. The result is the advance of the glyph in units of the font, or a call outcome with an error record: a face that is not 1 to 5 (argument 1), a font that the face does not name or that is not open (argument 2), a glyph index past the font (argument 3), points (argument 4) or contours (argument 5) that do not fit their table (Full), an outline that the reader refuses (Bad_Value: value the vector_font.Font_Problem), or fonts of the process that are not open (Absent). The tables of the caller start empty: the count on entry is 0. On a refusal both counts stay 0, so the caller reads no record; the reader may have written records past them, in the capacity of the tables, before it refused the outline.
@(export, link_name = "glyph_outline")
glyph_outline :: proc "c" (face: i64, font: i64, glyph: i64, points: ^system.Table_To_Append(text_rendering.Outline_Word), contours: ^system.Table_To_Append(text_rendering.Contour_End), error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	face_checked, face_ok := text_rendering.face_of_word(face)
	if !face_ok {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 1, face, i64(max(text_rendering.Face)))
	}
	if intrinsics.atomic_load_explicit(&process_fonts_stage, .Acquire) != .Open {
		return call_outcome.fail(error, .Wrong_State, .State, .None, 0)
	}
	if font <= i64(text_rendering.Outline_Font.None) || font > i64(max(text_rendering.Outline_Font)) {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 2, font, i64(max(text_rendering.Outline_Font)))
	}
	outline_font := text_rendering.Outline_Font(font)
	opened := text_rendering.font_at(&text_rendering.state.font_set, outline_font)
	if outline_font not_in text_rendering.fonts_of_face(face_checked) || !opened.opened {
		return call_outcome.fail(error, .Nothing_Has_That_Name, .Absent, .None, 2, font)
	}
	if glyph <= 0 || glyph >= i64(opened.file.glyph_count) {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 3, glyph, i64(opened.file.glyph_count) - 1)
	}
	point_capacity, contour_capacity := min(points.capacity, TABLE_LIMIT), min(contours.capacity, TABLE_LIMIT)
	if points.count != 0 || contours.count != 0 {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .Records, points.count != 0 ? 4 : 5, i64(min(max(points.count, contours.count), TABLE_LIMIT)), 0)
	}
	outline := vector_font.Outline {
		points       = ([^]vector_font.Outline_Point)(points.records)[:point_capacity],
		contour_ends = ([^]int)(contours.records)[:contour_capacity],
	}
	switch problem := vector_font.glyph_outline(&opened.file, int(glyph), &outline); problem {
	case .None:
	case .Too_Many_Points:
		return call_outcome.fail(error, .Budget_Or_Capacity_Exhausted, .Full, .Records, 4, 0, i64(point_capacity))
	case .Too_Short, .Missing_Table, .Unknown_Format, .Composite_Too_Deep, .No_Glyph, .No_Face, .No_Feature, .No_Room, .Too_Much_Work:
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 3, i64(problem))
	}
	// The reader wrote the bool of each point: its word holds 0 or 1 whole.
	words := ([^]text_rendering.Outline_Word)(points.records)
	for index in 0 ..< outline.point_count {
		words[index].on_curve = words[index].on_curve & 0xFF != 0 ? 1 : 0
	}
	points.count = u64(outline.point_count)
	contours.count = u64(outline.contour_count)
	return .Succeeded, i64(outline.advance)
}

// cell_cluster_read reads the cluster of a grid of cells that starts at a byte of a UTF-8 text, in a face, over the fonts of the calling process: a base and its marks, composed and in canonical order, and the split of a SARA AM of Thai (text_rendering.cluster_read). sara_am_taken is the byte of the SARA AM whose NIKHAHIT the cluster before took, -1 for none. It appends the cluster and its marks. The result is 1, 0 at the end of the text, or a call outcome with an error record: a face that is not 1 to 5 (argument 1), a text of more than 65536 bytes (argument 2), a byte past the text (argument 3), a table of clusters (argument 5) or of marks (argument 6) that has no room for the answer (Full), or fonts of the process that are not open (Absent). Nothing is written on a refusal.
@(export, link_name = "cell_cluster_read")
cell_cluster_read :: proc "c" (face: i64, text: ^system.Bytes_To_Read, place: i64, sara_am_taken: i64, cluster: ^system.Table_To_Append(text_rendering.Cell_Cluster), marks: ^system.Table_To_Append(text_rendering.Cell_Mark), error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	face_checked, face_ok := text_rendering.face_of_word(face)
	if !face_ok {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 1, face, i64(max(text_rendering.Face)))
	}
	bytes, text_outcome := process_text(text, 2, error)
	if text_outcome != .Succeeded {
		return text_outcome, 0
	}
	if place < 0 || place > i64(len(bytes)) {
		return call_outcome.fail(error, .Argument_Refused, .Out_Of_Range, .Bytes, 3, place, i64(len(bytes)))
	}
	if intrinsics.atomic_load_explicit(&process_fonts_stage, .Acquire) != .Open {
		return call_outcome.fail(error, .Wrong_State, .State, .None, 0)
	}
	read, ok := text_rendering.cluster_read(&text_rendering.state.font_set, face_checked, bytes, int(place), int(clamp(sara_am_taken, -1, i64(len(bytes)))))
	if !ok {
		return .Succeeded, 0
	}
	if cluster.count >= min(cluster.capacity, TABLE_LIMIT) {
		return call_outcome.fail(error, .Budget_Or_Capacity_Exhausted, .Full, .Records, 5, 0, i64(min(cluster.capacity, TABLE_LIMIT)))
	}
	if marks.count > TABLE_LIMIT || min(marks.capacity, TABLE_LIMIT) - min(marks.count, min(marks.capacity, TABLE_LIMIT)) < u64(read.mark_count) {
		return call_outcome.fail(error, .Budget_Or_Capacity_Exhausted, .Full, .Records, 6, 0, i64(min(marks.capacity, TABLE_LIMIT)))
	}
	mark_room := marks.records[marks.count:][:read.mark_count]
	head, mark_count := text_rendering.cell_cluster_of(&read, mark_room)
	cluster.records[cluster.count] = head
	cluster.count += 1
	marks.count += u64(mark_count)
	return .Succeeded, 1
}
