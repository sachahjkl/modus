package vector_font

// The table GDEF (OpenType): the class of each glyph (base, ligature, mark,
// component), the attachment class of each mark, and the mark sets that a
// lookup names with its flag UseMarkFilteringSet. The lookup flags of the
// engine (layout_engine.odin) read them. A font with no table GDEF gives
// each glyph no class, and each lookup flag that names a class skips
// nothing.

// The class of a glyph in GDEF.
Glyph_Class :: enum u8 {
	None      = 0,
	Base      = 1,
	Ligature  = 2,
	Mark      = 3,
	Component = 4,
}

// Gdef: the parts of the table GDEF that the engine reads; each empty when
// the font lacks it.
Gdef :: struct {
	glyph_classes: []u8, // A class definition: the class of each glyph.
	mark_classes:  []u8, // A class definition: the attachment class of each mark.
	mark_sets:     []u8, // The mark glyph sets (version 1.2): a count, then a coverage of each set.
}

// gdef_of reads the header of the table GDEF of a font. A part whose offset
// passes the table is left empty.
gdef_of :: proc "contextless" (font: ^Font_File) -> (gdef: Gdef) {
	place := font.gdef
	if place.length < 12 || place.offset < 0 || place.offset + place.length > len(font.bytes) {
		return {}
	}
	table := font.bytes[place.offset:][:place.length]
	major := read_u16(table, 0) or_else 0
	minor := read_u16(table, 2) or_else 0
	if major != 1 {
		return {}
	}
	if offset := read_u16(table, 4) or_else 0; offset != 0 {
		gdef.glyph_classes = part_at(table, offset) or_else nil
	}
	if offset := read_u16(table, 10) or_else 0; offset != 0 {
		gdef.mark_classes = part_at(table, offset) or_else nil
	}
	if minor >= 2 {
		if offset := read_u16(table, 12) or_else 0; offset != 0 {
			gdef.mark_sets = part_at(table, offset) or_else nil
		}
	}
	return gdef
}

// class_value gives the class of a glyph in a class definition of format 1
// (a first glyph and a class for each glyph after it) or 2 (ranges, by
// halves); 0 for a glyph that it does not name, and for a definition that
// passes its bytes.
class_value :: proc "contextless" (definition: []u8, glyph: int) -> int {
	format := read_u16(definition, 0) or_else 0
	switch format {
	case 1:
		first := read_u16(definition, 2) or_else 0
		count := read_u16(definition, 4) or_else 0
		if glyph < first || glyph >= first + count {
			return 0
		}
		return read_u16(definition, 6 + 2 * (glyph - first)) or_else 0
	case 2:
		count := read_u16(definition, 2) or_else 0
		if 4 + 6 * count > len(definition) {
			return 0
		}
		low, high := 0, count
		for low < high {
			middle := low + (high - low) / 2
			start := read_u16(definition, 4 + 6 * middle) or_else 0
			end := read_u16(definition, 6 + 6 * middle) or_else 0
			switch {
			case glyph < start:
				high = middle
			case glyph > end:
				low = middle + 1
			case:
				return read_u16(definition, 8 + 6 * middle) or_else 0
			}
		}
	}
	return 0
}

// glyph_class_of gives the class of a glyph in GDEF; a value past the four
// classes is None.
glyph_class_of :: proc "contextless" (gdef: ^Gdef, glyph: int) -> Glyph_Class {
	value := class_value(gdef.glyph_classes, glyph)
	if value < 1 || value > 4 {
		return .None
	}
	return Glyph_Class(value)
}

// mark_set_holds says if the mark set of an index holds a glyph; false for
// a set that the table lacks.
mark_set_holds :: proc "contextless" (gdef: ^Gdef, set, glyph: int) -> bool {
	if (read_u16(gdef.mark_sets, 0) or_else 0) != 1 {
		return false
	}
	count := read_u16(gdef.mark_sets, 2) or_else 0
	if set < 0 || set >= count {
		return false
	}
	offset := read_u32(gdef.mark_sets, 4 + 4 * set) or_else -1
	coverage, ok := part_at(gdef.mark_sets, offset)
	if !ok || offset < 0 {
		return false
	}
	index, problem := coverage_index_of(coverage, glyph)
	return problem == .None && index >= 0
}
