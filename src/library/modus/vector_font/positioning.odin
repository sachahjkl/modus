package vector_font

// The anchors of the marks of the table GPOS (OpenType): a mark is placed
// so that its anchor falls on the anchor of its base (mark-to-base, the
// feature mark, lookup type 4) or of the mark before it (mark-to-mark, the
// feature mkmk, lookup type 6). Noto Sans Arabic places the dots of its
// letters, which its feature ccmp makes marks, and its vowel signs on
// them; Noto Sans Hebrew places its points. A font with no table GPOS, or
// with no anchor for a pair, gives none, and the shaper centres the mark
// (src/md/features/written_shaping.md).
//
// The table is hostile input as the rest of the file: each offset is
// checked against the table, each count bounds its loop, and a coverage is
// a binary search (coverage_index_of).

// What a mark attaches to.
Mark_Attachment :: enum u8 {
	Base, // The glyph of its base: the feature mark, lookup type 4.
	Mark, // The mark before it on the same base: the feature mkmk, lookup type 6.
}

// mark_anchor_offset gives where a mark goes against the glyph that it
// attaches to, in units of the font: the anchor of that glyph less the
// anchor of the mark, both from the origin of their glyph. found is false
// when the font has no such feature or no anchor for the pair.
mark_anchor_offset :: proc "contextless" (font: ^Font_File, script: Feature_Tag, attachment: Mark_Attachment, attach_to, mark: int, budget: ^Layout_Budget) -> (dx, dy: int, found: bool, problem: Font_Problem) {
	tag := attachment == .Base ? Feature_Tag{'m', 'a', 'r', 'k'} : Feature_Tag{'m', 'k', 'm', 'k'}
	wanted := attachment == .Base ? 4 : 6
	// One feature: at most SUBSTITUTION_LOOKUP_LIMIT lookups, as a walk gives.
	walked: [SUBSTITUTION_LOOKUP_LIMIT]u16
	indices, _, lookup_problem := layout_feature_indices(font, font.gpos, script, {'D', 'F', 'L', 'T'}, tag, walked[:])
	if lookup_problem != .None {
		return 0, 0, false, lookup_problem == .No_Feature ? .None : lookup_problem
	}
	for index in indices {
		lookup, lookup_found := layout_lookup_of(font, font.gpos, int(index))
		if !lookup_found {
			return 0, 0, false, .Too_Short
		}
		subtable_count, count_read := read_u16(lookup, 4)
		if !count_read {
			return 0, 0, false, .Too_Short
		}
		// A lookup and each of its subtables take from the work of the call.
		if !layout_budget_take(budget, 1 + min(subtable_count, SUBSTITUTION_SUBTABLE_LIMIT)) {
			return 0, 0, false, .Too_Much_Work
		}
		for number in 0 ..< min(subtable_count, SUBSTITUTION_SUBTABLE_LIMIT) {
			subtable, taken := lookup_subtable(lookup, number, wanted, 9) or_return
			if !taken {
				continue
			}
			dx, dy, found = mark_subtable_offset(subtable, attach_to, mark) or_return
			if found {
				return dx, dy, true, .None
			}
		}
	}
	return 0, 0, false, .None
}

// mark_subtable_offset reads one subtable of format 1 of a lookup of type 4
// or 6: they have one form, a coverage of the marks and a coverage of the
// glyphs that they attach to, the classes and anchors of the marks, and
// for each such glyph one anchor of each class.
@(private)
mark_subtable_offset :: proc "contextless" (subtable: []u8, attach_to, mark: int) -> (dx, dy: int, found: bool, problem: Font_Problem) {
	format, format_read := read_u16(subtable, 0)
	mark_coverage_offset, mark_coverage_read := read_u16(subtable, 2)
	base_coverage_offset, base_coverage_read := read_u16(subtable, 4)
	class_count, class_count_read := read_u16(subtable, 6)
	mark_array_offset, mark_array_read := read_u16(subtable, 8)
	base_array_offset, base_array_read := read_u16(subtable, 10)
	if !format_read || !mark_coverage_read || !base_coverage_read || !class_count_read || !mark_array_read || !base_array_read {
		return 0, 0, false, .Too_Short
	}
	if format != 1 {
		return 0, 0, false, .Unknown_Format
	}
	mark_coverage, mark_coverage_ok := part_at(subtable, mark_coverage_offset)
	base_coverage, base_coverage_ok := part_at(subtable, base_coverage_offset)
	mark_array, mark_array_ok := part_at(subtable, mark_array_offset)
	base_array, base_array_ok := part_at(subtable, base_array_offset)
	if !mark_coverage_ok || !base_coverage_ok || !mark_array_ok || !base_array_ok {
		return 0, 0, false, .Too_Short
	}
	mark_index := coverage_index_of(mark_coverage, mark) or_return
	if mark_index < 0 {
		return 0, 0, false, .None
	}
	base_index := coverage_index_of(base_coverage, attach_to) or_return
	if base_index < 0 {
		return 0, 0, false, .None
	}
	mark_count, mark_count_read := read_u16(mark_array, 0)
	base_count, base_count_read := read_u16(base_array, 0)
	if !mark_count_read || !base_count_read {
		return 0, 0, false, .Too_Short
	}
	if mark_index >= mark_count || base_index >= base_count {
		return 0, 0, false, .Unknown_Format
	}
	class, class_read := read_u16(mark_array, 2 + 4 * mark_index)
	mark_anchor_offset, mark_anchor_read := read_u16(mark_array, 4 + 4 * mark_index)
	if !class_read || !mark_anchor_read {
		return 0, 0, false, .Too_Short
	}
	if class >= class_count {
		return 0, 0, false, .Unknown_Format
	}
	base_anchor_offset, base_anchor_read := read_u16(base_array, 2 + 2 * (base_index * class_count + class))
	if !base_anchor_read {
		return 0, 0, false, .Too_Short
	}
	// An offset of 0: the glyph has no anchor of this class.
	if base_anchor_offset == 0 || mark_anchor_offset == 0 {
		return 0, 0, false, .None
	}
	mark_x, mark_y := anchor_read(mark_array, mark_anchor_offset) or_return
	base_x, base_y := anchor_read(base_array, base_anchor_offset) or_return
	return base_x - mark_x, base_y - mark_y, true, .None
}

// anchor_read reads an anchor of format 1, 2 or 3: its x and its y. The
// point of a contour of format 2 and the device tables of format 3 tune
// the place at small sizes; the reader keeps the design place.
@(private)
anchor_read :: proc "contextless" (array: []u8, offset: int) -> (x, y: int, problem: Font_Problem) {
	anchor, anchor_ok := part_at(array, offset)
	format, format_read := read_u16(anchor, 0)
	x_read, y_read: bool
	x, x_read = read_i16(anchor, 2)
	y, y_read = read_i16(anchor, 4)
	if !anchor_ok || !format_read || !x_read || !y_read {
		return 0, 0, .Too_Short
	}
	if format < 1 || format > 3 {
		return 0, 0, .Unknown_Format
	}
	return x, y, .None
}
