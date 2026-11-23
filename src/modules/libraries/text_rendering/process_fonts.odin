package text_rendering_module

import "base:intrinsics"
import "modus:contract/errors"
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

// process_fonts_open_from opens the fonts of the process into the state of
// this copy: the font outlines, then the script font set when scripts is
// not nil. A host test calls it with outlines of its own; a freestanding
// build reads the fixed ranges of the process (process_fonts_open).
process_fonts_open_from :: proc "contextless" (outlines: ^font_outlines.Outlines, scripts: ^font_outlines.Outlines) {
	_ = text_rendering.open(outlines)
	if scripts != nil {
		_ = text_rendering.script_fonts_open(scripts)
		process_scripts_mapped = true
	}
	intrinsics.atomic_store_explicit(&process_fonts_stage, .Open, .Release)
}

// process_fonts_ready gives the spacing of a face at a size over the fonts
// of the process, with an error record for a face (argument 1) and a size
// (argument 2) that face_and_size_check refuses, and Absent before the
// open of the fonts of the process or when they lack the first font of the
// face.
@(private)
process_spacing :: proc "contextless" (face_word, size: i64, error: ^errors.Error_Record) -> (spacing: text_rendering.Spacing, ok: bool) {
	face, face_ok := process_face_and_size_check(face_word, size, error)
	if !face_ok {
		return {}, false
	}
	if intrinsics.atomic_load_explicit(&process_fonts_stage, .Acquire) != .Open {
		errors.fail(error, -1, .Absent, .None, 0)
		return {}, false
	}
	spacing, ok = text_rendering.spacing_of(face, int(size))
	if !ok {
		errors.fail(error, -1, .Absent, .None, 1, i64(text_rendering.face_forms[face].primary))
		return {}, false
	}
	return spacing, true
}

// process_face_and_size_check is face_and_size_check for the exports over
// the fonts of the process, whose face is argument 1 and size argument 2.
@(private)
process_face_and_size_check :: proc "contextless" (face_word, size: i64, error: ^errors.Error_Record) -> (face: text_rendering.Face, ok: bool) {
	face, ok = text_rendering.face_of_word(face_word)
	if !ok {
		errors.fail(error, -1, .Bad_Value, .None, 1, face_word, i64(max(text_rendering.Face)))
		return .None, false
	}
	switch text_rendering.size_check(int(size)) {
	case .None:
	case .Zero, .Too_Small:
		errors.fail(error, -1, .Too_Small, .None, 2, size, text_rendering.TEXT_SIZE_MINIMUM)
		return .None, false
	case .Too_Large:
		errors.fail(error, -1, .Bad_Value, .None, 2, size, text_rendering.TEXT_SIZE_LIMIT)
		return .None, false
	}
	return face, true
}

// process_text checks a text argument: at most TEXT_LIMIT bytes.
@(private)
process_text :: proc "contextless" (text: ^system.Bytes_To_Read, argument: i64, error: ^errors.Error_Record) -> (bytes: []u8, ok: bool) {
	count := text.count
	if count > text_rendering.TEXT_LIMIT {
		errors.fail(error, -1, .Too_Long, .Bytes, argument, i64(min(count, TABLE_LIMIT)), text_rendering.TEXT_LIMIT)
		return nil, false
	}
	return text.bytes[:count], true
}

// process_fonts_open opens the fonts of the calling process for the written part, once: the font outlines that its starter mapped, and the script font set when the starter mapped one, with the caches of the walk of their tables. It appends one record for each font of the script font set when the starter mapped a set: Open (its measures and its glyph count), Missing, or Refused (its tables of GSUB and GPOS pass the bound of their read). A second call opens nothing and appends the same records. The result is the count of records of the full answer, or -1 with an error record: a table over 2^40 records (argument 1, Too_Long), or another thread of the process that opens them now (Absent).
@(export, link_name = "process_fonts_open")
process_fonts_open :: proc "c" (held: ^system.Table_To_Append(text_rendering.Held_Font), error: ^errors.Error_Record) -> i64 {
	capacity, held_count := held.capacity, held.count
	if capacity > TABLE_LIMIT || held_count > TABLE_LIMIT {
		return errors.fail(error, -1, .Too_Long, .Records, 1, i64(min(max(capacity, held_count), TABLE_LIMIT + 1)), i64(TABLE_LIMIT))
	}
	if _, opening := intrinsics.atomic_compare_exchange_strong_explicit(&process_fonts_stage, .Closed, .Opening, .Acquire, .Acquire); opening {
		when ODIN_OS == .Freestanding {
			values := &system.context_record().values
			if outlines, problem := font_outlines.open(values, process_records_room[:]); problem.kind == .None {
				scripts, script_problem := font_outlines.script_fonts_open(values, process_records_room[:])
				// The boot fonts are opened before the room holds the
				// records of the set.
				_ = text_rendering.open(&outlines)
				if script_problem.kind == .None {
					_ = text_rendering.script_fonts_open(&scripts)
					process_scripts_mapped = true
				}
			}
		}
		intrinsics.atomic_store_explicit(&process_fonts_stage, .Open, .Release)
	}
	if intrinsics.atomic_load_explicit(&process_fonts_stage, .Acquire) != .Open {
		return errors.fail(error, -1, .Absent, .None, 0)
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
	return i64(held.count)
}

// line_shape appends the placed glyphs of a UTF-8 text of one line in a face at a text size, over the fonts of the calling process, the written part whole: the marks, Arabic, Thai, the scripts of India and the order of a line of mixed direction. The placed glyphs are those of shape_text. The result is the count of placed glyphs of the full answer (larger than the capacity: it did not fit), or -1 with an error record: a face that is not 1 to 5 (argument 1), a size under 256 or over 16384 (argument 2), a text of more than 65536 bytes (argument 3), a table over 2^40 records (argument 4), or fonts of the process that are not open or lack the first font of the face (Absent). Nothing is written on a refusal.
@(export, link_name = "line_shape")
line_shape :: proc "c" (face: i64, size: i64, text: ^system.Bytes_To_Read, placed: ^system.Table_To_Append(text_rendering.Placed_Glyph), error: ^errors.Error_Record) -> i64 {
	spacing, ok := process_spacing(face, size, error)
	if !ok {
		return -1
	}
	bytes, text_ok := process_text(text, 3, error)
	if !text_ok {
		return -1
	}
	capacity, placed_count := placed.capacity, placed.count
	if capacity > TABLE_LIMIT || placed_count > TABLE_LIMIT {
		return errors.fail(error, -1, .Too_Long, .Records, 4, i64(min(max(capacity, placed_count), TABLE_LIMIT + 1)), i64(TABLE_LIMIT))
	}
	room: []text_rendering.Placed_Glyph
	if placed_count < capacity {
		room = placed.records[placed_count:][:capacity - placed_count]
	}
	count, _, _ := text_rendering.shape(&spacing, bytes, room)
	placed.count = placed_count + u64(count)
	return i64(placed.count)
}

// line_width gives the width of a UTF-8 text of one line in a face at a text size, over the fonts of the calling process, in 1/64 of a pixel: the sum of the advances of its placed glyphs (line_shape). A width can be below 0, when the pairs of a font take more than the advances; a refusal is told by the error record, with the result -1: a face (argument 1), a size (argument 2) or a text (argument 3) as for line_shape, or fonts of the process that are not open (Absent).
@(export, link_name = "line_width")
line_width :: proc "c" (face: i64, size: i64, text: ^system.Bytes_To_Read, error: ^errors.Error_Record) -> i64 {
	spacing, ok := process_spacing(face, size, error)
	if !ok {
		return -1
	}
	bytes, text_ok := process_text(text, 3, error)
	if !text_ok {
		return -1
	}
	width, _ := text_rendering.text_width(&spacing, bytes)
	return width
}

// line_fit gives the bytes of the longest start of a UTF-8 text in a face at a text size, over the fonts of the calling process, whose width is at most room, in 1/64 of a pixel: whole clusters, so a cut never splits a character, a letter from its marks or a syllable. 0 for a room below the first advance. The result is the bytes, or -1 with an error record: a face (argument 1), a size (argument 2) or a text (argument 3) as for line_shape, or fonts of the process that are not open (Absent).
@(export, link_name = "line_fit")
line_fit :: proc "c" (face: i64, size: i64, text: ^system.Bytes_To_Read, room: i64, error: ^errors.Error_Record) -> i64 {
	spacing, ok := process_spacing(face, size, error)
	if !ok {
		return -1
	}
	bytes, text_ok := process_text(text, 3, error)
	if !text_ok {
		return -1
	}
	return i64(text_rendering.text_fit(&spacing, bytes, room))
}

// glyph_find finds a character in the chain of a face, over the fonts of the calling process, the script font set with them: the first font that has it. The result is the font (a text_rendering.Outline_Font) times 65536 plus the glyph index in that font, 0 for a character that no font of the chain has, or -1 with an error record: a face that is not 1 to 5 (argument 1), a character past U+10FFFF or below 0 (argument 2), or fonts of the process that are not open (Absent).
@(export, link_name = "glyph_find")
glyph_find :: proc "c" (face: i64, character: i64, error: ^errors.Error_Record) -> i64 {
	face_checked, face_ok := text_rendering.face_of_word(face)
	if !face_ok {
		return errors.fail(error, -1, .Bad_Value, .None, 1, face, i64(max(text_rendering.Face)))
	}
	if character < 0 || character > 0x10FFFF {
		return errors.fail(error, -1, .Bad_Value, .None, 2, character, 0x10FFFF)
	}
	if intrinsics.atomic_load_explicit(&process_fonts_stage, .Acquire) != .Open {
		return errors.fail(error, -1, .Absent, .None, 0)
	}
	font, index := text_rendering.font_glyph_of(face_checked, rune(character))
	if font == .None {
		return 0
	}
	return i64(font) << 16 | i64(index & 0xFFFF)
}

// glyph_outline appends the outline of a glyph of a font of the chain of a face, over the fonts of the calling process: its points, in units of the font, and the index after the last point of each contour. The result is the advance of the glyph in units of the font, or -1 with an error record: a face that is not 1 to 5 (argument 1), a font that the face does not name or that is not open (argument 2), a glyph index past the font (argument 3), points (argument 4) or contours (argument 5) that do not fit their table (Full), an outline that the reader refuses (Bad_Value: value the vector_font.Font_Problem), or fonts of the process that are not open (Absent). The tables of the caller start empty: the count on entry is 0.
@(export, link_name = "glyph_outline")
glyph_outline :: proc "c" (face: i64, font: i64, glyph: i64, points: ^system.Table_To_Append(text_rendering.Outline_Word), contours: ^system.Table_To_Append(text_rendering.Contour_End), error: ^errors.Error_Record) -> i64 {
	face_checked, face_ok := text_rendering.face_of_word(face)
	if !face_ok {
		return errors.fail(error, -1, .Bad_Value, .None, 1, face, i64(max(text_rendering.Face)))
	}
	if intrinsics.atomic_load_explicit(&process_fonts_stage, .Acquire) != .Open {
		return errors.fail(error, -1, .Absent, .None, 0)
	}
	if font <= i64(text_rendering.Outline_Font.None) || font > i64(max(text_rendering.Outline_Font)) {
		return errors.fail(error, -1, .Bad_Value, .None, 2, font, i64(max(text_rendering.Outline_Font)))
	}
	outline_font := text_rendering.Outline_Font(font)
	opened := text_rendering.font_at(&text_rendering.state.font_set, outline_font)
	if outline_font not_in text_rendering.fonts_of_face(face_checked) || !opened.opened {
		return errors.fail(error, -1, .Absent, .None, 2, font)
	}
	if glyph <= 0 || glyph >= i64(opened.file.glyph_count) {
		return errors.fail(error, -1, .Bad_Value, .None, 3, glyph, i64(opened.file.glyph_count) - 1)
	}
	point_capacity, contour_capacity := min(points.capacity, TABLE_LIMIT), min(contours.capacity, TABLE_LIMIT)
	if points.count != 0 || contours.count != 0 {
		return errors.fail(error, -1, .Bad_Value, .Records, points.count != 0 ? 4 : 5, i64(min(max(points.count, contours.count), TABLE_LIMIT)), 0)
	}
	outline := vector_font.Outline {
		points       = ([^]vector_font.Outline_Point)(points.records)[:point_capacity],
		contour_ends = ([^]int)(contours.records)[:contour_capacity],
	}
	switch problem := vector_font.glyph_outline(&opened.file, int(glyph), &outline); problem {
	case .None:
	case .Too_Many_Points:
		return errors.fail(error, -1, .Full, .Records, 4, 0, i64(point_capacity))
	case .Too_Short, .Missing_Table, .Unknown_Format, .Composite_Too_Deep, .No_Glyph, .No_Face, .No_Feature, .No_Room, .Too_Much_Work:
		return errors.fail(error, -1, .Bad_Value, .None, 3, i64(problem))
	}
	// The reader wrote the bool of each point: its word holds 0 or 1 whole.
	words := ([^]text_rendering.Outline_Word)(points.records)
	for index in 0 ..< outline.point_count {
		words[index].on_curve = words[index].on_curve & 0xFF != 0 ? 1 : 0
	}
	points.count = u64(outline.point_count)
	contours.count = u64(outline.contour_count)
	return i64(outline.advance)
}

// cell_cluster_read reads the cluster of a grid of cells that starts at a byte of a UTF-8 text, in a face, over the fonts of the calling process: a base and its marks, composed and in canonical order, and the split of a SARA AM of Thai (text_rendering.cluster_read). sara_am_taken is the byte of the SARA AM whose NIKHAHIT the cluster before took, -1 for none. It appends the cluster and its marks. The result is 1, 0 at the end of the text, or -1 with an error record: a face that is not 1 to 5 (argument 1), a text of more than 65536 bytes (argument 2), a byte past the text (argument 3), a table of clusters (argument 5) or of marks (argument 6) that has no room for the answer (Full), or fonts of the process that are not open (Absent). Nothing is written on a refusal.
@(export, link_name = "cell_cluster_read")
cell_cluster_read :: proc "c" (face: i64, text: ^system.Bytes_To_Read, place: i64, sara_am_taken: i64, cluster: ^system.Table_To_Append(text_rendering.Cell_Cluster), marks: ^system.Table_To_Append(text_rendering.Cell_Mark), error: ^errors.Error_Record) -> i64 {
	face_checked, face_ok := text_rendering.face_of_word(face)
	if !face_ok {
		return errors.fail(error, -1, .Bad_Value, .None, 1, face, i64(max(text_rendering.Face)))
	}
	bytes, text_ok := process_text(text, 2, error)
	if !text_ok {
		return -1
	}
	if place < 0 || place > i64(len(bytes)) {
		return errors.fail(error, -1, .Out_Of_Range, .Bytes, 3, place, i64(len(bytes)))
	}
	if intrinsics.atomic_load_explicit(&process_fonts_stage, .Acquire) != .Open {
		return errors.fail(error, -1, .Absent, .None, 0)
	}
	read, ok := text_rendering.cluster_read(&text_rendering.state.font_set, face_checked, bytes, int(place), int(clamp(sara_am_taken, -1, i64(len(bytes)))))
	if !ok {
		return 0
	}
	if cluster.count >= min(cluster.capacity, TABLE_LIMIT) {
		return errors.fail(error, -1, .Full, .Records, 5, 0, i64(min(cluster.capacity, TABLE_LIMIT)))
	}
	if marks.count > TABLE_LIMIT || min(marks.capacity, TABLE_LIMIT) - min(marks.count, min(marks.capacity, TABLE_LIMIT)) < u64(read.mark_count) {
		return errors.fail(error, -1, .Full, .Records, 6, 0, i64(min(marks.capacity, TABLE_LIMIT)))
	}
	mark_room := marks.records[marks.count:][:read.mark_count]
	head, mark_count := text_rendering.cell_cluster_of(&read, mark_room)
	cluster.records[cluster.count] = head
	cluster.count += 1
	marks.count += u64(mark_count)
	return 1
}
