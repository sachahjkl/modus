package text_rendering

import "modus:contract/errors"
import "modus:contract/text_encoding"
import "modus:system"
import "modus:vector_font"

// The two parts of the package (src/md/features/text_rendering.md, "Where
// the written shaping lives"). The fast part places a text of simple
// characters in the fonts of the boot image and draws each glyph; each
// module that draws text compiles it. The written part places every other
// text: the clusters with their marks, Arabic, Thai, the scripts of India,
// the engine of the lookups, the order of a line of mixed direction, the
// script font set and the reader of CFF. The library module text_rendering
// compiles it, and so does each host build; a module of the system calls
// that module for each line that is not simple.
WRITTEN_SHAPING_COMPILED_IN :: #config(WRITTEN_SHAPING_COMPILED_IN, ODIN_OS != .Freestanding)

// The error record and the text of a call of the library module.
@(private)
Module_Error :: errors.Error_Record
@(private)
Module_Text :: system.Bytes_To_Read

// What the library module did with a font of the script font set of its
// process.
Held_Standing :: enum u8 {
	Open    = 1, // It draws: its glyphs come from the module.
	Missing = 2, // The set lacks it, or the parser refused it.
	Refused = 3, // Its tables of GSUB and GPOS passed the bound of their read at the open: it draws the replacement glyph.
}

// Held_Font: a font of the script font set that the library module
// text_rendering opened for its process. The fast part keeps its measures
// and its glyph count, which place a glyph of it in the frame of a face,
// and asks the module for its outlines. Flat integers: a record of an
// export holds no struct.
Held_Font :: struct {
	font:              u16, // An Outline_Font of SCRIPT_FONTS.
	standing:          Held_Standing,
	own_monospace:     u8, // 1: Font_Measures.monospace of its own measures.
	stated_monospace:  u8, // 1: Font_Measures.monospace of its stated measures.
	reserved:          u8,
	reserved_wide:     u16,
	glyph_count:       u32,
	own_advance:       i32,
	own_x_height:      i32,
	own_cap_height:    i32,
	own_top:           i32,
	own_bottom:        i32,
	stated_advance:    i32,
	stated_x_height:   i32,
	stated_cap_height: i32,
	stated_top:        i32,
	stated_bottom:     i32,
}

// Outline_Word: one point of an outline that the module reads for the
// fast part. Its layout is the layout of vector_font.Outline_Point, so the
// module writes into the outline memory of the caller with no copy; on_curve
// is 0 or 1, in the place of the bool.
Outline_Word :: struct {
	x:        i32,
	y:        i32,
	on_curve: u32,
}
#assert(size_of(Outline_Word) == size_of(vector_font.Outline_Point))
#assert(offset_of(Outline_Word, x) == offset_of(vector_font.Outline_Point, x))
#assert(offset_of(Outline_Word, y) == offset_of(vector_font.Outline_Point, y))
#assert(offset_of(Outline_Word, on_curve) == offset_of(vector_font.Outline_Point, on_curve))

// Contour_End: the index after the last point of one contour, as
// vector_font.Outline holds it.
Contour_End :: struct {
	after: i64,
}
#assert(size_of(Contour_End) == size_of(int))

// Cell_Cluster: a cluster of a grid of cells (Cluster), as the module
// reads it for the fast part; its marks are the records of a second table.
Cell_Cluster :: struct {
	base:          u32, // A code point.
	base_valid:    u8, // 1: base is a character; 0: an invalid sequence.
	dotted:        u8, // 1: the marks had no base; base is the dotted circle.
	reserved:      u16,
	start:         u32,
	end:           u32,
	sara_am_taken: i32, // The byte of the SARA AM after it whose NIKHAHIT it took; -1: none.
	mark_count:    u32,
}

// Cell_Mark: one mark of a Cell_Cluster, in its order.
Cell_Mark :: struct {
	character: u32,
	place:     u32, // Its first byte in the text.
}

// held_font_of writes the record of a font of the set of the state: the
// module gives it to the fast part of its caller.
held_font_of :: proc "contextless" (font: Outline_Font) -> (held: Held_Font) {
	held.font = u16(font)
	opened := font_at(&state.font_set, font)
	switch {
	case opened.opened:
		held.standing = .Open
	case font in state.layout_refused:
		held.standing = .Refused
		return held
	case:
		held.standing = .Missing
		return held
	}
	held.glyph_count = u32(opened.file.glyph_count)
	held.own_monospace = u8(opened.own.monospace)
	held.stated_monospace = u8(opened.stated.monospace)
	held.own_advance, held.own_x_height, held.own_cap_height, held.own_top, held.own_bottom = i32(opened.own.advance), i32(opened.own.x_height), i32(opened.own.cap_height), i32(opened.own.top), i32(opened.own.bottom)
	held.stated_advance, held.stated_x_height, held.stated_cap_height, held.stated_top, held.stated_bottom = i32(opened.stated.advance), i32(opened.stated.x_height), i32(opened.stated.cap_height), i32(opened.stated.top), i32(opened.stated.bottom)
	return held
}

// held_font_take puts a font that the module holds into the set of the
// state of the fast part: a slot with its measures and its glyph count, no
// file. A record that names no font of the set, or a standing that is no
// member, is not taken. It gives the font when it is missing or refused.
@(private)
held_font_take :: proc "contextless" (held: Held_Font) -> (missing: Outline_Fonts) {
	if int(held.font) <= int(Outline_Font.None) || int(held.font) > int(max(Outline_Font)) {
		return {}
	}
	font := Outline_Font(held.font)
	if font not_in SCRIPT_FONTS {
		return {}
	}
	switch held.standing {
	case .Open:
	case .Refused:
		state.layout_refused += {font}
		return {font}
	case .Missing:
		return {font}
	case:
		return {font}
	}
	slot, has_room := font_slot(state_set(), font)
	if !has_room {
		return {font}
	}
	slot^ = {held = true, opened = true}
	slot.file.glyph_count = int(held.glyph_count)
	slot.own = {advance = int(held.own_advance), x_height = int(held.own_x_height), cap_height = int(held.own_cap_height), top = int(held.own_top), bottom = int(held.own_bottom), monospace = held.own_monospace != 0}
	slot.stated = {advance = int(held.stated_advance), x_height = int(held.stated_x_height), cap_height = int(held.stated_cap_height), top = int(held.stated_top), bottom = int(held.stated_bottom), monospace = held.stated_monospace != 0}
	return {}
}

// The calls of the fast part to the written part: the written part
// compiled in, or the exports of the library module text_rendering. Each
// gives called false when the module refused the call, as before its open:
// the caller then places the text one character at a time.
when WRITTEN_SHAPING_COMPILED_IN {
	// The written part is compiled in: the fonts of the state are open
	// whole, so nothing is held.
	@(private)
	held_fonts_open :: proc "contextless" () -> (missing: Outline_Fonts, called: bool) {
		return {}, false
	}
} else {
	// The declarations name the records of the package: the check of the
	// declarations of an import reads the layout of a struct by its name.
	foreign _ {
		@(link_name = "process_fonts_open")
		module_process_fonts_open :: proc "c" (held: ^system.Table_To_Append(Held_Font), error: ^errors.Error_Record) -> i64 ---
		@(link_name = "line_shape")
		module_line_shape :: proc "c" (face: i64, size: i64, text: ^system.Bytes_To_Read, placed: ^system.Table_To_Append(Placed_Glyph), error: ^errors.Error_Record) -> i64 ---
		@(link_name = "line_widths")
		module_line_widths :: proc "c" (face: i64, size: i64, text: ^system.Bytes_To_Read, ranges: ^system.Table_To_Change(Text_Range), error: ^errors.Error_Record) -> i64 ---
		@(link_name = "line_fit")
		module_line_fit :: proc "c" (face: i64, size: i64, text: ^system.Bytes_To_Read, room: i64, error: ^errors.Error_Record) -> i64 ---
		@(link_name = "glyph_find")
		module_glyph_find :: proc "c" (face: i64, character: i64, error: ^errors.Error_Record) -> i64 ---
		@(link_name = "glyph_outline")
		module_glyph_outline :: proc "c" (face: i64, font: i64, glyph: i64, points: ^system.Table_To_Append(Outline_Word), contours: ^system.Table_To_Append(Contour_End), error: ^errors.Error_Record) -> i64 ---
		@(link_name = "cell_cluster_read")
		module_cell_cluster_read :: proc "c" (face: i64, text: ^system.Bytes_To_Read, place: i64, sara_am_taken: i64, cluster: ^system.Table_To_Append(Cell_Cluster), marks: ^system.Table_To_Append(Cell_Mark), error: ^errors.Error_Record) -> i64 ---
	}

	// held_fonts_open asks the library module to open the fonts of the
	// process, and takes the fonts of the script font set that it holds
	// into the set of the state. It gives the fonts of the set that are
	// missing or refused.
	@(private)
	held_fonts_open :: proc "contextless" () -> (missing: Outline_Fonts, called: bool) {
		records: [len(Outline_Font)]Held_Font
		table := system.Table_To_Append(Held_Font){records = &records[0], capacity = len(records)}
		error: errors.Error_Record
		if module_process_fonts_open(&table, &error) < 0 {
			return SCRIPT_FONTS, false
		}
		for held in records[:min(int(table.count), len(records))] {
			missing += held_font_take(held)
		}
		return missing, true
	}

	// The module places the lines of the state of its process only: a set
	// of a caller, a grid of cells and a text with no pair are placed by
	// the fast part.
	@(private)
	module_places :: #force_inline proc "contextless" (spacing: ^Spacing) -> bool {
		return (spacing.fonts == nil || spacing.fonts == &state.font_set) && spacing.cell_advance == 0 && !spacing.without_pairs
	}

	@(private)
	text_to_read :: #force_inline proc "contextless" (text: []u8) -> Module_Text {
		return {bytes = raw_data(text), count = u64(len(text)), capacity = u64(len(text))}
	}

	@(private)
	written_line_shape :: proc "contextless" (spacing: ^Spacing, text: []u8, placed: []Placed_Glyph) -> (count: int, width: i64, called: bool) {
		if !module_places(spacing) {
			return 0, 0, false
		}
		bytes := text_to_read(text)
		error: errors.Error_Record
		if len(placed) == 0 {
			// The count is not asked: a caller with no room reads the width.
			width, called = module_width(spacing, text)
			return 0, width, called
		}
		table := system.Table_To_Append(Placed_Glyph){records = raw_data(placed), capacity = u64(len(placed))}
		total := module_line_shape(i64(spacing.face), i64(spacing.size), &bytes, &table, &error)
		if total < 0 {
			return 0, 0, false
		}
		count = int(total)
		if count <= len(placed) {
			for glyph in placed[:count] {
				width += i64(glyph.advance)
			}
			return count, width, true
		}
		width, called = module_width(spacing, text)
		return count, width, called
	}

	// module_width gives the width of a line through the module: one range
	// of the whole text, whose width the export writes.
	@(private)
	module_width :: proc "contextless" (spacing: ^Spacing, text: []u8) -> (width: i64, called: bool) {
		bytes := text_to_read(text)
		ranges := [1]Text_Range{{start = 0, count = u32(len(text))}}
		table := system.Table_To_Change(Text_Range){records = &ranges[0], count = 1, capacity = 1}
		error: errors.Error_Record
		if module_line_widths(i64(spacing.face), i64(spacing.size), &bytes, &table, &error) != 1 {
			return 0, false
		}
		return ranges[0].width, true
	}

	@(private)
	written_line_fit :: proc "contextless" (spacing: ^Spacing, text: []u8, room: i64) -> (count: int, called: bool) {
		if !module_places(spacing) {
			return 0, false
		}
		bytes := text_to_read(text)
		error: errors.Error_Record
		fit := module_line_fit(i64(spacing.face), i64(spacing.size), &bytes, room, &error)
		if fit < 0 || fit > i64(len(text)) {
			return 0, false
		}
		return int(fit), true
	}

	// held_glyph_find finds a character in the chain of a face through the
	// module, when the walk of the fast part meets a font that it holds.
	@(private)
	held_glyph_find :: proc "contextless" (face: Face, character: rune) -> (font: Outline_Font, glyph_index: int) {
		error: errors.Error_Record
		found := module_glyph_find(i64(face), i64(character), &error)
		if found <= 0 {
			return .None, 0
		}
		word := found >> 16
		if word <= i64(Outline_Font.None) || word > i64(max(Outline_Font)) {
			return .None, 0
		}
		return Outline_Font(word), int(found & 0xFFFF)
	}

	// held_glyph_outline reads the outline of a glyph of a font that the
	// module holds into an outline of the caller.
	@(private)
	held_glyph_outline :: proc "contextless" (face: Face, font: Outline_Font, glyph_index: int, outline: ^vector_font.Outline) -> bool {
		points := system.Table_To_Append(Outline_Word){records = ([^]Outline_Word)(raw_data(outline.points)), capacity = u64(len(outline.points))}
		contours := system.Table_To_Append(Contour_End){records = ([^]Contour_End)(raw_data(outline.contour_ends)), capacity = u64(len(outline.contour_ends))}
		error: errors.Error_Record
		advance := module_glyph_outline(i64(face), i64(font), i64(glyph_index), &points, &contours, &error)
		if advance < 0 || points.count > u64(len(outline.points)) || contours.count > u64(len(outline.contour_ends)) {
			return false
		}
		outline.point_count = int(points.count)
		outline.contour_count = int(contours.count)
		outline.advance = int(advance)
		// Each contour ends inside the points: the rasterizer reads by them.
		for end in outline.contour_ends[:outline.contour_count] {
			if end < 0 || end > outline.point_count {
				return false
			}
		}
		return true
	}

	// held_cluster_read reads a cluster of a grid of cells through the
	// module.
	@(private)
	held_cluster_read :: proc "contextless" (face: Face, text: []u8, place, sara_am_taken: int) -> (cluster: Cluster, ok, called: bool) {
		bytes := text_to_read(text)
		head: [1]Cell_Cluster
		marks: [CLUSTER_MARK_LIMIT]Cell_Mark
		head_table := system.Table_To_Append(Cell_Cluster){records = &head[0], capacity = 1}
		mark_table := system.Table_To_Append(Cell_Mark){records = &marks[0], capacity = len(marks)}
		error: errors.Error_Record
		read := module_cell_cluster_read(i64(face), &bytes, i64(place), i64(sara_am_taken), &head_table, &mark_table, &error)
		if read < 0 {
			return {}, false, false
		}
		if read == 0 || head_table.count != 1 {
			return {}, false, true
		}
		found := head[0]
		if found.start != u32(place) || found.end <= found.start || found.end > u32(len(text)) || found.mark_count > CLUSTER_MARK_LIMIT || u64(found.mark_count) != mark_table.count {
			return {}, false, false
		}
		cluster = {base = rune(found.base), base_valid = found.base_valid != 0, dotted = found.dotted != 0, mark_count = int(found.mark_count), start = int(found.start), end = int(found.end), sara_am_taken = int(found.sara_am_taken)}
		for mark, index in marks[:found.mark_count] {
			cluster.marks[index] = rune(mark.character)
			cluster.mark_places[index] = mark.place
		}
		return cluster, true, true
	}
}

// cell_cluster_of writes a cluster as the records of a grid of cells: the
// module gives them to the fast part of its caller.
cell_cluster_of :: proc "contextless" (cluster: ^Cluster, marks: []Cell_Mark) -> (head: Cell_Cluster, mark_count: int) {
	head = {base = u32(cluster.base), base_valid = u8(cluster.base_valid), dotted = u8(cluster.dotted), start = u32(cluster.start), end = u32(cluster.end), sara_am_taken = i32(cluster.sara_am_taken)}
	mark_count = min(cluster.mark_count, len(marks), CLUSTER_MARK_LIMIT)
	for index in 0 ..< mark_count {
		marks[index] = {character = u32(cluster.marks[index]), place = cluster.mark_places[index]}
	}
	head.mark_count = u32(mark_count)
	return head, mark_count
}

// cluster_of_one is the cluster of one character with no mark: each
// cluster of a text of simple characters, and the cluster of the fast part
// when the module refused the read.
@(private)
cluster_of_one :: proc "contextless" (text: []u8, place: int) -> (cluster: Cluster, ok: bool) {
	character, length, valid := text_encoding.character_decode(text, place)
	if length == 0 {
		return {}, false
	}
	return {base = character, base_valid = valid, start = place, end = place + length, sara_am_taken = -1}, true
}
