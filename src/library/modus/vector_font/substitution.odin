package vector_font

// One form of the substitutions of the table GSUB (OpenType): the single
// substitution (lookup type 1, or type 7 that holds a type 1) of a feature,
// such as "zero", whose lookup maps the glyph of '0' to a slashed zero. The
// modus tool uses it to put that form of a glyph in a subset
// (docs/FONTS.md, section 6, "The zero of Paper Mono").
//
// The feature is found as a shaper finds it: in the default language
// system of the script DFLT, or of the script latn when DFLT is absent.
//
// The table is hostile input like the rest of the file: each offset is
// checked against the length of the table before a read, each count
// bounds its loop, and the work is bounded: at most SUBSTITUTION_FEATURE_LIMIT
// features of the tag, SUBSTITUTION_LOOKUP_LIMIT lookups of a feature,
// SUBSTITUTION_SUBTABLE_LIMIT subtables of a lookup, and a binary search
// in each coverage (a coverage out of order gives no glyph, never a read
// out of the table).

SUBSTITUTION_FEATURE_LIMIT :: 16
SUBSTITUTION_LOOKUP_LIMIT :: 64
SUBSTITUTION_SUBTABLE_LIMIT :: 64

// A tag of four bytes, as the table writes it.
Feature_Tag :: [4]u8

// part_at gives the bytes of a table from an offset that the table holds:
// false when the offset passes its end.
@(private)
part_at :: proc "contextless" (bytes: []u8, at: int) -> (part: []u8, ok: bool) {
	if at < 0 || at > len(bytes) {
		return nil, false
	}
	return bytes[at:], true
}

@(private)
tag_at :: proc "contextless" (bytes: []u8, at: int) -> (tag: Feature_Tag, ok: bool) {
	if at < 0 || at + 4 > len(bytes) {
		return {}, false
	}
	return {bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3]}, true
}

// single_substitution gives the glyph that the feature `tag` puts in the
// place of `glyph` by a single substitution. .No_Feature when the font has
// no table GSUB, no such feature in its default language system, or no
// single substitution of the glyph in its lookups.
single_substitution :: proc "contextless" (font: ^Font_File, tag: Feature_Tag, glyph: int) -> (substitute: int, problem: Font_Problem) {
	return gsub_find(font, {'D', 'F', 'L', 'T'}, {'l', 'a', 't', 'n'}, tag, .Single, glyph, 0)
}

// script_single_substitution is single_substitution in the default
// language system of a script, else of DFLT: the forms of the letters of
// Arabic are the features isol, init, medi and fina of the script arab.
script_single_substitution :: proc "contextless" (font: ^Font_File, script, tag: Feature_Tag, glyph: int) -> (substitute: int, problem: Font_Problem) {
	return gsub_find(font, script, {'D', 'F', 'L', 'T'}, tag, .Single, glyph, 0)
}

// script_ligature gives the ligature of two glyphs that a feature of a
// script makes (a lookup of type 4): lam and alef of Arabic make one glyph
// by the feature rlig. .No_Feature when the font has none.
script_ligature :: proc "contextless" (font: ^Font_File, script, tag: Feature_Tag, first, second: int) -> (ligature: int, problem: Font_Problem) {
	return gsub_find(font, script, {'D', 'F', 'L', 'T'}, tag, .Ligature, first, second)
}

// script_substitution applies the lookups of a feature of a script (else
// of DFLT) to one glyph, in the order of the lookup list, as a shaper does
// on a glyph alone: a single substitution (type 1) changes the glyph, and a
// multiple substitution (type 2) puts a sequence in its place, whose first
// glyph the next lookups take; the others follow it. It writes the glyphs
// into out and gives their count: 1 and the glyph itself when no lookup
// takes it, .No_Feature when the font has no such feature. A sequence past
// len(out) keeps its first len(out) glyphs. Noto Sans Arabic makes beh a
// dotless body and a dot below by the feature ccmp, then the form of the
// body by init, medi or fina.
script_substitution :: proc "contextless" (font: ^Font_File, script, tag: Feature_Tag, glyph: int, out: []int) -> (count: int, problem: Font_Problem) {
	if len(out) == 0 {
		return 0, .Too_Short
	}
	lookups: Layout_Lookups
	layout_lookups(font, font.gsub, script, {'D', 'F', 'L', 'T'}, tag, &lookups) or_return
	out[0] = glyph
	count = 1
	for lookup in lookups.parts[:lookups.count] {
		substitute: int
		found := lookup_single_substitution(lookup, out[0], &substitute) or_return
		if found {
			if substitute <= 0 || substitute >= font.glyph_count {
				return 0, .Unknown_Format
			}
			out[0] = substitute
			continue
		}
		sequence: [SEQUENCE_LIMIT]int
		length: int
		length, found = lookup_multiple_substitution(lookup, out[0], sequence[:]) or_return
		if !found {
			continue
		}
		for value in sequence[:length] {
			if value <= 0 || value >= font.glyph_count {
				return 0, .Unknown_Format
			}
		}
		// The sequence in the place of the first glyph, before the rest.
		rest := min(count - 1, len(out) - length)
		if rest > 0 {
			copy(out[length:][:rest], out[1:][:rest])
		}
		taken := copy(out, sequence[:length])
		count = taken + max(rest, 0)
	}
	return count, .None
}

// The most glyphs of the sequence of one multiple substitution.
SEQUENCE_LIMIT :: 8

// The lookups that gsub_find reads.
@(private)
Gsub_Kind :: enum u8 {
	Single, // Type 1: one glyph for one glyph.
	Ligature, // Type 4: one glyph for two glyphs.
}

// Layout_Lookups: the lookups of one feature of a table GSUB or GPOS, in
// the order of the lookup list, which is the order in which a shaper
// applies them.
Layout_Lookups :: struct {
	parts:   [SUBSTITUTION_LOOKUP_LIMIT][]u8,
	indices: [SUBSTITUTION_LOOKUP_LIMIT]u16, // The index of each in the lookup list.
	count:   int,
}

// layout_has_script says if the script list of a table GSUB or GPOS names
// a script.
layout_has_script :: proc "contextless" (font: ^Font_File, place: Table, script: Feature_Tag) -> bool {
	if place.length == 0 || place.offset < 0 || place.length < 0 || place.offset + place.length > len(font.bytes) {
		return false
	}
	table := font.bytes[place.offset:][:place.length]
	script_list_offset := read_u16(table, 4) or_return
	script_list := part_at(table, script_list_offset) or_return
	count := read_u16(script_list, 0) or_return
	for index in 0 ..< count {
		tag := tag_at(script_list, 2 + 6 * index) or_return
		if tag == script {
			return true
		}
	}
	return false
}

// layout_lookups finds the lookups of a feature in the default language
// system of a script (else of a second script) of a table GSUB or GPOS: the
// two tables share the lists of scripts, features and lookups.
// .No_Feature when the font has no such table, script or feature.
layout_lookups :: proc "contextless" (font: ^Font_File, place: Table, script, other_script, tag: Feature_Tag, out: ^Layout_Lookups) -> (problem: Font_Problem) {
	out.count = 0
	if place.length == 0 {
		return .No_Feature
	}
	if place.offset < 0 || place.length < 0 || place.offset + place.length > len(font.bytes) {
		return .Too_Short
	}
	table := font.bytes[place.offset:][:place.length]
	major, major_read := read_u16(table, 0)
	minor, minor_read := read_u16(table, 2)
	script_list_offset, script_read := read_u16(table, 4)
	feature_list_offset, feature_read := read_u16(table, 6)
	lookup_list_offset, lookup_read := read_u16(table, 8)
	if !major_read || !minor_read || !script_read || !feature_read || !lookup_read {
		return .Too_Short
	}
	if major != 1 || minor > 1 {
		return .Unknown_Format
	}
	script_list, script_list_ok := part_at(table, script_list_offset)
	feature_list, feature_list_ok := part_at(table, feature_list_offset)
	lookup_list, lookup_list_ok := part_at(table, lookup_list_offset)
	if !script_list_ok || !feature_list_ok || !lookup_list_ok {
		return .Too_Short
	}
	// The default language system of the script, else of the other one.
	language_system: []u8
	system_found := false
	script_count := read_u16(script_list, 0) or_else 0
	for wanted in ([2]Feature_Tag{script, other_script}) {
		for index in 0 ..< script_count {
			script_tag, tag_read := tag_at(script_list, 2 + 6 * index)
			script_offset, offset_read := read_u16(script_list, 6 + 6 * index)
			if !tag_read || !offset_read {
				return .Too_Short
			}
			if script_tag != wanted {
				continue
			}
			script, script_ok := part_at(script_list, script_offset)
			default_offset, default_read := read_u16(script, 0)
			if !script_ok || !default_read {
				return .Too_Short
			}
			if default_offset != 0 {
				system_part, system_ok := part_at(script, default_offset)
				if !system_ok {
					return .Too_Short
				}
				language_system = system_part
				system_found = true
			}
			break
		}
		if system_found {
			break
		}
	}
	if !system_found {
		return .No_Feature
	}
	// The features of the language system with the tag, then their lookups.
	feature_count := read_u16(feature_list, 0) or_else 0
	index_count, index_count_read := read_u16(language_system, 4)
	if !index_count_read {
		return .Too_Short
	}
	lookup_count := read_u16(lookup_list, 0) or_else 0
	features_seen := 0
	for index_number in 0 ..< index_count {
		feature_index, index_read := read_u16(language_system, 6 + 2 * index_number)
		if !index_read {
			return .Too_Short
		}
		if feature_index >= feature_count {
			return .Unknown_Format
		}
		feature_tag, feature_tag_read := tag_at(feature_list, 2 + 6 * feature_index)
		feature_offset, feature_offset_read := read_u16(feature_list, 6 + 6 * feature_index)
		if !feature_tag_read || !feature_offset_read {
			return .Too_Short
		}
		if feature_tag != tag {
			continue
		}
		features_seen += 1
		if features_seen > SUBSTITUTION_FEATURE_LIMIT {
			break
		}
		feature, feature_ok := part_at(feature_list, feature_offset)
		lookups_of_feature, lookups_read := read_u16(feature, 2)
		if !feature_ok || !lookups_read {
			return .Too_Short
		}
		for lookup_number in 0 ..< lookups_of_feature {
			lookup_index, lookup_index_read := read_u16(feature, 4 + 2 * lookup_number)
			if !lookup_index_read {
				return .Too_Short
			}
			if lookup_index >= lookup_count {
				return .Unknown_Format
			}
			// Each lookup once, in the order of the lookup list.
			place_of := out.count
			seen := false
			for existing, position in out.indices[:out.count] {
				if int(existing) == lookup_index {
					seen = true
					break
				}
				if int(existing) > lookup_index {
					place_of = position
					break
				}
			}
			if seen {
				continue
			}
			if out.count == SUBSTITUTION_LOOKUP_LIMIT {
				break
			}
			lookup_offset, lookup_offset_read := read_u16(lookup_list, 2 + 2 * lookup_index)
			lookup, lookup_ok := part_at(lookup_list, lookup_offset)
			if !lookup_offset_read || !lookup_ok {
				return .Too_Short
			}
			for position := out.count; position > place_of; position -= 1 {
				out.indices[position] = out.indices[position - 1]
				out.parts[position] = out.parts[position - 1]
			}
			out.indices[place_of] = u16(lookup_index)
			out.parts[place_of] = lookup
			out.count += 1
		}
	}
	if out.count == 0 {
		return .No_Feature
	}
	return .None
}

// layout_lookup_of gives the lookup of an index in the lookup list of a
// table GSUB or GPOS: a nested lookup of a contextual lookup names its
// index.
layout_lookup_of :: proc "contextless" (font: ^Font_File, place: Table, index: int) -> (lookup: []u8, ok: bool) {
	if place.length < 10 || place.offset < 0 || place.offset + place.length > len(font.bytes) {
		return nil, false
	}
	table := font.bytes[place.offset:][:place.length]
	list := part_at(table, read_u16(table, 8) or_else -1) or_return
	count := read_u16(list, 0) or_return
	if index < 0 || index >= count {
		return nil, false
	}
	return part_at(list, read_u16(list, 2 + 2 * index) or_else -1)
}

// gsub_find finds the glyph that a feature of the default language system
// of a script (else of a second script) gives for a glyph, or for a pair
// of glyphs by a ligature: the first lookup that takes it.
@(private)
gsub_find :: proc "contextless" (font: ^Font_File, script, other_script, tag: Feature_Tag, kind: Gsub_Kind, glyph, second: int) -> (substitute: int, problem: Font_Problem) {
	lookups: Layout_Lookups
	layout_lookups(font, font.gsub, script, other_script, tag, &lookups) or_return
	for lookup in lookups.parts[:lookups.count] {
		found: bool
		lookup_problem: Font_Problem
		switch kind {
		case .Single:
			found, lookup_problem = lookup_single_substitution(lookup, glyph, &substitute)
		case .Ligature:
			found, lookup_problem = lookup_ligature(lookup, glyph, second, &substitute)
		}
		if lookup_problem != .None {
			return 0, lookup_problem
		}
		if found {
			if substitute <= 0 || substitute >= font.glyph_count {
				return 0, .Unknown_Format
			}
			return substitute, .None
		}
	}
	return 0, .No_Feature
}

// lookup_subtable gives a subtable of a lookup, through an extension (type
// 7 of GSUB, type 9 of GPOS) when the lookup is one: false with no problem
// when the subtable is of another type than wanted.
@(private)
lookup_subtable :: proc "contextless" (lookup: []u8, number: int, wanted, extension: int) -> (subtable: []u8, taken: bool, problem: Font_Problem) {
	lookup_type, type_read := read_u16(lookup, 0)
	subtable_offset, offset_read := read_u16(lookup, 6 + 2 * number)
	if !type_read || !offset_read {
		return nil, false, .Too_Short
	}
	subtable_ok: bool
	subtable, subtable_ok = part_at(lookup, subtable_offset)
	if !subtable_ok {
		return nil, false, .Too_Short
	}
	if lookup_type == extension {
		extension_format, format_read := read_u16(subtable, 0)
		held_type, held_read := read_u16(subtable, 2)
		held_offset, held_offset_read := read_u32(subtable, 4)
		if !format_read || !held_read || !held_offset_read {
			return nil, false, .Too_Short
		}
		if extension_format != 1 {
			return nil, false, .Unknown_Format
		}
		if held_type != wanted {
			return nil, false, .None
		}
		subtable, subtable_ok = part_at(subtable, held_offset)
		if !subtable_ok {
			return nil, false, .Too_Short
		}
		return subtable, true, .None
	}
	return subtable, lookup_type == wanted, .None
}

// lookup_multiple_substitution reads one lookup of type 2, or of type 7
// that holds a type 2: the sequence of glyphs in the place of one glyph.
// A sequence of no glyph, which deletes the glyph, and one past len(out),
// are refused.
@(private)
lookup_multiple_substitution :: proc "contextless" (lookup: []u8, glyph: int, out: []int) -> (count: int, found: bool, problem: Font_Problem) {
	subtable_count, count_read := read_u16(lookup, 4)
	if !count_read {
		return 0, false, .Too_Short
	}
	for number in 0 ..< min(subtable_count, SUBSTITUTION_SUBTABLE_LIMIT) {
		subtable, taken := lookup_subtable(lookup, number, 2, 7) or_return
		if !taken {
			continue
		}
		format, format_read := read_u16(subtable, 0)
		coverage_offset, coverage_read := read_u16(subtable, 2)
		sequence_count, sequence_count_read := read_u16(subtable, 4)
		coverage, coverage_ok := part_at(subtable, coverage_offset)
		if !format_read || !coverage_read || !sequence_count_read || !coverage_ok {
			return 0, false, .Too_Short
		}
		if format != 1 {
			return 0, false, .Unknown_Format
		}
		index := coverage_index_of(coverage, glyph) or_return
		if index < 0 {
			continue
		}
		if index >= sequence_count {
			return 0, false, .Unknown_Format
		}
		sequence_offset, sequence_offset_read := read_u16(subtable, 6 + 2 * index)
		sequence, sequence_ok := part_at(subtable, sequence_offset)
		glyph_count, glyph_count_read := read_u16(sequence, 0)
		if !sequence_offset_read || !sequence_ok || !glyph_count_read {
			return 0, false, .Too_Short
		}
		if glyph_count == 0 || glyph_count > len(out) {
			return 0, false, .Unknown_Format
		}
		for place in 0 ..< glyph_count {
			value, value_read := read_u16(sequence, 2 + 2 * place)
			if !value_read {
				return 0, false, .Too_Short
			}
			out[place] = value
		}
		return glyph_count, true, .None
	}
	return 0, false, .None
}

// lookup_single_substitution reads one lookup: type 1, or type 7 (an
// extension) that holds a type 1. Another type substitutes nothing here.
@(private)
lookup_single_substitution :: proc "contextless" (lookup: []u8, glyph: int, substitute: ^int) -> (found: bool, problem: Font_Problem) {
	lookup_type, type_read := read_u16(lookup, 0)
	subtable_count, count_read := read_u16(lookup, 4)
	if !type_read || !count_read {
		return false, .Too_Short
	}
	if lookup_type != 1 && lookup_type != 7 {
		return false, .None
	}
	for number in 0 ..< min(subtable_count, SUBSTITUTION_SUBTABLE_LIMIT) {
		subtable_offset, offset_read := read_u16(lookup, 6 + 2 * number)
		subtable, subtable_ok := part_at(lookup, subtable_offset)
		if !offset_read || !subtable_ok {
			return false, .Too_Short
		}
		if lookup_type == 7 {
			// An extension: format 1, the type of the lookup that it holds,
			// and a 32-bit offset from the extension to that subtable.
			extension_format, extension_format_read := read_u16(subtable, 0)
			held_type, held_read := read_u16(subtable, 2)
			held_offset, held_offset_read := read_u32(subtable, 4)
			if !extension_format_read || !held_read || !held_offset_read {
				return false, .Too_Short
			}
			if extension_format != 1 {
				return false, .Unknown_Format
			}
			if held_type != 1 {
				continue
			}
			subtable, subtable_ok = part_at(subtable, held_offset)
			if !subtable_ok {
				return false, .Too_Short
			}
		}
		format, format_read := read_u16(subtable, 0)
		coverage_offset, coverage_read := read_u16(subtable, 2)
		coverage, coverage_ok := part_at(subtable, coverage_offset)
		if !format_read || !coverage_read || !coverage_ok {
			return false, .Too_Short
		}
		coverage_index := coverage_index_of(coverage, glyph) or_return
		if coverage_index < 0 {
			continue
		}
		switch format {
		case 1:
			delta, delta_read := read_i16(subtable, 4)
			if !delta_read {
				return false, .Too_Short
			}
			substitute^ = (glyph + delta) & 0xFFFF
			return true, .None
		case 2:
			glyph_count, glyph_count_read := read_u16(subtable, 4)
			if !glyph_count_read {
				return false, .Too_Short
			}
			if coverage_index >= glyph_count {
				return false, .Unknown_Format
			}
			value, value_read := read_u16(subtable, 6 + 2 * coverage_index)
			if !value_read {
				return false, .Too_Short
			}
			substitute^ = value
			return true, .None
		case:
			return false, .Unknown_Format
		}
	}
	return false, .None
}

// lookup_ligature reads one lookup of type 4, or of type 7 that holds a
// type 4: the ligature of a first glyph whose components are the second
// glyph alone.
@(private)
lookup_ligature :: proc "contextless" (lookup: []u8, first, second: int, ligature: ^int) -> (found: bool, problem: Font_Problem) {
	lookup_type, type_read := read_u16(lookup, 0)
	subtable_count, count_read := read_u16(lookup, 4)
	if !type_read || !count_read {
		return false, .Too_Short
	}
	if lookup_type != 4 && lookup_type != 7 {
		return false, .None
	}
	for number in 0 ..< min(subtable_count, SUBSTITUTION_SUBTABLE_LIMIT) {
		subtable_offset, offset_read := read_u16(lookup, 6 + 2 * number)
		subtable, subtable_ok := part_at(lookup, subtable_offset)
		if !offset_read || !subtable_ok {
			return false, .Too_Short
		}
		if lookup_type == 7 {
			held_type, held_read := read_u16(subtable, 2)
			held_offset, held_offset_read := read_u32(subtable, 4)
			if !held_read || !held_offset_read {
				return false, .Too_Short
			}
			if held_type != 4 {
				continue
			}
			subtable, subtable_ok = part_at(subtable, held_offset)
			if !subtable_ok {
				return false, .Too_Short
			}
		}
		format, format_read := read_u16(subtable, 0)
		coverage_offset, coverage_read := read_u16(subtable, 2)
		set_count, set_count_read := read_u16(subtable, 4)
		coverage, coverage_ok := part_at(subtable, coverage_offset)
		if !format_read || !coverage_read || !set_count_read || !coverage_ok {
			return false, .Too_Short
		}
		if format != 1 {
			return false, .Unknown_Format
		}
		index := coverage_index_of(coverage, first) or_return
		if index < 0 {
			continue
		}
		if index >= set_count {
			return false, .Unknown_Format
		}
		set_offset, set_offset_read := read_u16(subtable, 6 + 2 * index)
		set, set_ok := part_at(subtable, set_offset)
		ligature_count, ligature_count_read := read_u16(set, 0)
		if !set_offset_read || !set_ok || !ligature_count_read {
			return false, .Too_Short
		}
		for ligature_number in 0 ..< min(ligature_count, SUBSTITUTION_SUBTABLE_LIMIT) {
			ligature_offset, ligature_offset_read := read_u16(set, 2 + 2 * ligature_number)
			entry, entry_ok := part_at(set, ligature_offset)
			glyph, glyph_read := read_u16(entry, 0)
			components, components_read := read_u16(entry, 2)
			if !ligature_offset_read || !entry_ok || !glyph_read || !components_read {
				return false, .Too_Short
			}
			if components != 2 {
				continue
			}
			component, component_read := read_u16(entry, 4)
			if !component_read {
				return false, .Too_Short
			}
			if component == second {
				ligature^ = glyph
				return true, .None
			}
		}
	}
	return false, .None
}

// coverage_index_of gives the index of a glyph in a coverage table, or -1:
// a binary search in format 1 (a sorted list of glyphs) and in format 2
// (sorted ranges, each with the coverage index of its first glyph).
@(private)
coverage_index_of :: proc "contextless" (coverage: []u8, glyph: int) -> (index: int, problem: Font_Problem) {
	format, format_read := read_u16(coverage, 0)
	count, count_read := read_u16(coverage, 2)
	if !format_read || !count_read {
		return -1, .Too_Short
	}
	low, high := 0, count
	switch format {
	case 1:
		if 4 + 2 * count > len(coverage) {
			return -1, .Too_Short
		}
		for low < high {
			middle := low + (high - low) / 2
			value := read_u16(coverage, 4 + 2 * middle) or_else 0
			switch {
			case value == glyph:
				return middle, .None
			case value < glyph:
				low = middle + 1
			case:
				high = middle
			}
		}
	case 2:
		if 4 + 6 * count > len(coverage) {
			return -1, .Too_Short
		}
		for low < high {
			middle := low + (high - low) / 2
			start := read_u16(coverage, 4 + 6 * middle) or_else 0
			end := read_u16(coverage, 6 + 6 * middle) or_else 0
			switch {
			case glyph < start:
				high = middle
			case glyph > end:
				low = middle + 1
			case:
				first_index := read_u16(coverage, 8 + 6 * middle) or_else 0
				return first_index + glyph - start, .None
			}
		}
	case:
		return -1, .Unknown_Format
	}
	return -1, .None
}
