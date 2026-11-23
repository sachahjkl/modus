package vector_font

// The engine of the lookups of GSUB and GPOS over a buffer of glyphs
// (src/md/features/written_shaping.md, "The engine of the lookups"): the
// one engine of the written shaper. The shaper of a script fills the
// buffer with the glyphs of a syllable or a word and the mask of the
// features of each, then applies the features in stages (engine_stage).
//
// The tables are hostile input as the rest of the file: each read is
// checked against its table, each count bounds its loop, a contextual
// lookup nests at most ENGINE_NESTING_LIMIT deep, a run applies at most
// ENGINE_STEP_LIMIT lookups at a position and tries at most
// ENGINE_WORK_LIMIT rules and subtables, and a substitution that would pass
// ENGINE_GLYPH_LIMIT glyphs is not made.

ENGINE_GLYPH_LIMIT :: 32
ENGINE_NESTING_LIMIT :: 4
ENGINE_STEP_LIMIT :: 4096
ENGINE_WORK_LIMIT :: 1 << 16
// The features of one stage: the presentation stage of the scripts of
// India names eleven.
ENGINE_STAGE_FEATURE_LIMIT :: 16

// One glyph of the buffer.
Engine_Glyph :: struct {
	glyph:     u16,
	place:     u8, // The first character of the glyph in the run.
	class:     Glyph_Class,
	mask:      u32, // The features that apply to it.
	x_advance: i32, // In units of the font: the advance of hmtx, and the adjustments of GPOS.
	x_offset:  i32, // From its own origin, after engine_positions_finish.
	y_offset:  i32,
	attach_dx: i32, // A mark: the anchor of the glyph that it attaches to, less its own.
	attach_dy: i32,
	attach:    i8, // The glyph that a mark attaches to; -1: none.
}

Engine_Buffer :: struct {
	glyphs: [ENGINE_GLYPH_LIMIT]Engine_Glyph,
	count:  int,
}

// The table of a stage.
Layout_Kind :: enum u8 {
	Substitution, // GSUB.
	Positioning, // GPOS.
}

// A feature of a stage, and the bit of the mask of the glyphs that it
// applies to.
Engine_Feature :: struct {
	tag:  Feature_Tag,
	mask: u32,
}

@(private)
Engine :: struct {
	font:   ^Font_File,
	place:  Table,
	kind:   Layout_Kind,
	gdef:   Gdef,
	buffer: ^Engine_Buffer,
	mask:   u32,
	steps:  int,
	work:   int,
}

// The header of a lookup.
@(private)
Lookup_Head :: struct {
	type:      int, // The type of its subtables, through an extension.
	flag:      int,
	filter:    int, // The mark set of UseMarkFilteringSet.
	subtables: int,
}

@(private)
LOOKUP_IGNORE_BASES :: 0x0002
@(private)
LOOKUP_IGNORE_LIGATURES :: 0x0004
@(private)
LOOKUP_IGNORE_MARKS :: 0x0008
@(private)
LOOKUP_MARK_FILTERING_SET :: 0x0010

// engine_buffer_prepare gives each glyph of a buffer its class of GDEF, its
// advance, no offset and no attachment: the shaper fills the glyph, the
// place and the mask first.
engine_buffer_prepare :: proc "contextless" (font: ^Font_File, buffer: ^Engine_Buffer) {
	gdef := gdef_of(font)
	buffer.count = clamp(buffer.count, 0, ENGINE_GLYPH_LIMIT)
	for &glyph in buffer.glyphs[:buffer.count] {
		glyph.class = glyph_class_of(&gdef, int(glyph.glyph))
		glyph.x_advance = i32(glyph_advance(font, int(glyph.glyph)))
		glyph.x_offset, glyph.y_offset, glyph.attach_dx, glyph.attach_dy, glyph.attach = 0, 0, 0, 0, -1
	}
}

// engine_stage applies the features of one stage to a buffer: their lookups
// merged in the order of the lookup list, each to the glyphs whose mask
// holds the bit of a feature that names it. A feature that the font lacks
// applies nothing.
engine_stage :: proc "contextless" (font: ^Font_File, kind: Layout_Kind, script: Feature_Tag, features: []Engine_Feature, buffer: ^Engine_Buffer) -> Font_Problem {
	// The lookups of each feature, in the order of the lookup list; the
	// stage merges them, so it has no bound of its own past the lookups of
	// each feature.
	indices: [ENGINE_STAGE_FEATURE_LIMIT][SUBSTITUTION_LOOKUP_LIMIT]u16
	counts, cursors: [ENGINE_STAGE_FEATURE_LIMIT]int
	place := kind == .Substitution ? font.gsub : font.gpos
	feature_count := min(len(features), ENGINE_STAGE_FEATURE_LIMIT)
	for feature, number in features[:feature_count] {
		lookups: Layout_Lookups
		problem := layout_lookups(font, place, script, {'D', 'F', 'L', 'T'}, feature.tag, &lookups)
		if problem == .No_Feature {
			continue
		}
		if problem != .None {
			return problem
		}
		copy(indices[number][:], lookups.indices[:lookups.count])
		counts[number] = lookups.count
	}
	engine := Engine{font = font, place = place, kind = kind, gdef = gdef_of(font), buffer = buffer}
	for {
		next := max(int)
		for number in 0 ..< feature_count {
			if cursors[number] < counts[number] {
				next = min(next, int(indices[number][cursors[number]]))
			}
		}
		if next == max(int) {
			break
		}
		mask: u32
		for number in 0 ..< feature_count {
			if cursors[number] < counts[number] && int(indices[number][cursors[number]]) == next {
				mask |= features[number].mask
				cursors[number] += 1
			}
		}
		lookup, found := layout_lookup_of(font, place, next)
		if !found {
			return .Too_Short
		}
		engine_lookup_apply(&engine, lookup, mask)
	}
	return .None
}

// engine_positions_finish gives each mark that a lookup attached its offset
// from its own origin: the origin of the glyph that it attaches to, plus
// the difference of the anchors, less its own place on the line.
engine_positions_finish :: proc "contextless" (buffer: ^Engine_Buffer) {
	pens: [ENGINE_GLYPH_LIMIT]i32
	pen: i32
	for index in 0 ..< buffer.count {
		pens[index] = pen
		pen += buffer.glyphs[index].x_advance
	}
	for index in 0 ..< buffer.count {
		glyph := &buffer.glyphs[index]
		target := int(glyph.attach)
		if target < 0 || target >= index {
			continue
		}
		base := &buffer.glyphs[target]
		glyph.x_offset = pens[target] + base.x_offset + glyph.attach_dx - pens[index]
		glyph.y_offset = base.y_offset + glyph.attach_dy
	}
}

@(private)
lookup_head :: proc "contextless" (lookup: []u8, extension: int) -> (head: Lookup_Head, ok: bool) {
	head.type = read_u16(lookup, 0) or_return
	head.flag = read_u16(lookup, 2) or_return
	// No bound of its own on the subtables: ENGINE_WORK_LIMIT counts each
	// that a run tries, and a font has lookups of more than 100 (the
	// conjuncts of Noto Sans Devanagari).
	head.subtables = read_u16(lookup, 4) or_return
	if head.flag & LOOKUP_MARK_FILTERING_SET != 0 {
		head.filter = read_u16(lookup, 6 + 2 * (read_u16(lookup, 4) or_return)) or_return
	}
	if head.type == extension && head.subtables > 0 {
		subtable := part_at(lookup, read_u16(lookup, 6) or_return) or_return
		head.type = read_u16(subtable, 2) or_return
	}
	return head, true
}

// engine_subtable gives a subtable of a lookup, through an extension.
@(private)
engine_subtable :: proc "contextless" (engine: ^Engine, lookup: []u8, number: int) -> (subtable: []u8, ok: bool) {
	extension := engine.kind == .Substitution ? 7 : 9
	subtable = part_at(lookup, read_u16(lookup, 6 + 2 * number) or_return) or_return
	if (read_u16(lookup, 0) or_return) == extension {
		if (read_u16(subtable, 0) or_return) != 1 {
			return nil, false
		}
		subtable = part_at(subtable, read_u32(subtable, 4) or_return) or_return
	}
	return subtable, true
}

// engine_skips says if a lookup skips a glyph by its flags.
@(private)
engine_skips :: proc "contextless" (engine: ^Engine, head: ^Lookup_Head, glyph: ^Engine_Glyph) -> bool {
	switch glyph.class {
	case .Base:
		return head.flag & LOOKUP_IGNORE_BASES != 0
	case .Ligature:
		return head.flag & LOOKUP_IGNORE_LIGATURES != 0
	case .Mark:
		if head.flag & LOOKUP_IGNORE_MARKS != 0 {
			return true
		}
		if head.flag & LOOKUP_MARK_FILTERING_SET != 0 {
			return !mark_set_holds(&engine.gdef, head.filter, int(glyph.glyph))
		}
		if attachment := head.flag >> 8; attachment != 0 {
			return class_value(engine.gdef.mark_classes, int(glyph.glyph)) != attachment
		}
	case .None, .Component:
	}
	return false
}

// engine_next gives the next glyph from a place in a direction that the
// lookup does not skip: count or -1 past the edge.
@(private)
engine_next :: proc "contextless" (engine: ^Engine, head: ^Lookup_Head, from, direction: int) -> int {
	for index := from; index >= 0 && index < engine.buffer.count; index += direction {
		if !engine_skips(engine, head, &engine.buffer.glyphs[index]) {
			return index
		}
	}
	return direction > 0 ? engine.buffer.count : -1
}

// engine_lookup_apply applies one lookup to each glyph of the buffer that
// its mask names and its flags do not skip: from the end for a reverse
// chaining substitution, else from the start.
@(private)
engine_lookup_apply :: proc "contextless" (engine: ^Engine, lookup: []u8, mask: u32) {
	head, ok := lookup_head(lookup, engine.kind == .Substitution ? 7 : 9)
	if !ok {
		return
	}
	engine.mask = mask
	buffer := engine.buffer
	if engine.kind == .Substitution && head.type == 8 {
		for index := buffer.count - 1; index >= 0; index -= 1 {
			glyph := &buffer.glyphs[index]
			if glyph.mask & mask != 0 && !engine_skips(engine, &head, glyph) {
				engine_apply_at(engine, lookup, &head, index, 0)
			}
			if engine.steps >= ENGINE_STEP_LIMIT {
				return
			}
		}
		return
	}
	for index := 0; index < buffer.count; {
		if engine.steps >= ENGINE_STEP_LIMIT {
			return
		}
		glyph := &buffer.glyphs[index]
		if glyph.mask & mask != 0 && !engine_skips(engine, &head, glyph) {
			if applied, next := engine_apply_at(engine, lookup, &head, index, 0); applied && next > index {
				index = next
				continue
			}
		}
		index += 1
	}
}

// engine_apply_at applies a lookup at one glyph: the first subtable that
// takes it. It gives the place after what it changed.
@(private)
engine_apply_at :: proc "contextless" (engine: ^Engine, lookup: []u8, head: ^Lookup_Head, index, depth: int) -> (applied: bool, next: int) {
	engine.steps += 1
	if engine.steps > ENGINE_STEP_LIMIT || index < 0 || index >= engine.buffer.count {
		return false, index + 1
	}
	buffer := engine.buffer
	glyph := int(buffer.glyphs[index].glyph)
	if engine.kind == .Substitution {
		switch head.type {
		case 1:
			substitute: int
			if found, problem := lookup_single_substitution(lookup, glyph, &substitute); problem == .None && found {
				return engine_replace(engine, index, substitute), index + 1
			}
			return false, index + 1
		case 2:
			sequence: [SEQUENCE_LIMIT]int
			count, found, problem := lookup_multiple_substitution(lookup, glyph, sequence[:])
			if problem != .None || !found {
				return false, index + 1
			}
			return engine_insert(engine, index, sequence[:count]), index + count
		}
	}
	for number in 0 ..< head.subtables {
		engine.work += 1
		if engine.work > ENGINE_WORK_LIMIT {
			return false, index + 1
		}
		subtable, ok := engine_subtable(engine, lookup, number)
		if !ok {
			continue
		}
		taken: bool
		after := index + 1
		switch engine.kind {
		case .Substitution:
			switch head.type {
			case 3:
				taken = engine_alternate(engine, subtable, index)
			case 4:
				taken = engine_ligature(engine, head, subtable, index)
			case 5:
				taken, after = engine_context(engine, head, subtable, index, depth)
			case 6:
				taken, after = engine_chain_context(engine, head, subtable, index, depth)
			case 8:
				taken = engine_reverse(engine, head, subtable, index)
			}
		case .Positioning:
			switch head.type {
			case 1:
				taken = engine_single_position(engine, subtable, index)
			case 2:
				taken = engine_pair_position(engine, head, subtable, index)
			case 4:
				taken = engine_mark_to_base(engine, subtable, index)
			case 5:
				taken = engine_mark_to_ligature(engine, subtable, index)
			case 6:
				taken = engine_mark_to_mark(engine, head, subtable, index)
			case 7:
				taken, after = engine_context(engine, head, subtable, index, depth)
			case 8:
				taken, after = engine_chain_context(engine, head, subtable, index, depth)
			}
		}
		if taken {
			return true, after
		}
	}
	return false, index + 1
}

// engine_replace puts a glyph in the place of another; false for a glyph
// past the font.
@(private)
engine_replace :: proc "contextless" (engine: ^Engine, index, substitute: int) -> bool {
	if substitute <= 0 || substitute >= engine.font.glyph_count {
		return false
	}
	glyph := &engine.buffer.glyphs[index]
	glyph.glyph = u16(substitute)
	glyph.class = glyph_class_of(&engine.gdef, substitute)
	glyph.x_advance = i32(glyph_advance(engine.font, substitute))
	return true
}

// engine_insert puts a sequence in the place of one glyph; false when the
// buffer has no room, or a glyph is past the font.
@(private)
engine_insert :: proc "contextless" (engine: ^Engine, index: int, sequence: []int) -> bool {
	buffer := engine.buffer
	if len(sequence) == 0 || buffer.count - 1 + len(sequence) > ENGINE_GLYPH_LIMIT {
		return false
	}
	for value in sequence {
		if value <= 0 || value >= engine.font.glyph_count {
			return false
		}
	}
	extra := len(sequence) - 1
	for move := buffer.count - 1; move > index; move -= 1 {
		buffer.glyphs[move + extra] = buffer.glyphs[move]
	}
	for value, offset in sequence {
		buffer.glyphs[index + offset] = buffer.glyphs[index]
		engine_replace(engine, index + offset, value)
	}
	buffer.count += extra
	return true
}

// engine_remove takes a glyph out of the buffer.
@(private)
engine_remove :: proc "contextless" (engine: ^Engine, index: int) {
	buffer := engine.buffer
	for move in index ..< buffer.count - 1 {
		buffer.glyphs[move] = buffer.glyphs[move + 1]
	}
	buffer.count -= 1
	for &glyph in buffer.glyphs[:buffer.count] {
		if int(glyph.attach) == index {
			glyph.attach = -1
		} else if int(glyph.attach) > index {
			glyph.attach -= 1
		}
	}
}

@(private)
covered :: proc "contextless" (subtable: []u8, coverage_at: int, glyph: int) -> (index: int) {
	coverage := part_at(subtable, read_u16(subtable, coverage_at) or_else -1) or_else nil
	if coverage == nil {
		return -1
	}
	found, problem := coverage_index_of(coverage, glyph)
	if problem != .None {
		return -1
	}
	return found
}

// An alternate substitution (type 3): the first alternate.
@(private)
engine_alternate :: proc "contextless" (engine: ^Engine, subtable: []u8, index: int) -> bool {
	coverage_index := covered(subtable, 2, int(engine.buffer.glyphs[index].glyph))
	if coverage_index < 0 || coverage_index >= (read_u16(subtable, 4) or_else 0) {
		return false
	}
	set := part_at(subtable, read_u16(subtable, 6 + 2 * coverage_index) or_else -1) or_else nil
	if (read_u16(set, 0) or_else 0) < 1 {
		return false
	}
	return engine_replace(engine, index, read_u16(set, 2) or_else 0)
}

// A ligature substitution (type 4): the components after the first glyph,
// over the glyphs that the lookup skips, which stay after the ligature.
@(private)
engine_ligature :: proc "contextless" (engine: ^Engine, head: ^Lookup_Head, subtable: []u8, index: int) -> bool {
	coverage_index := covered(subtable, 2, int(engine.buffer.glyphs[index].glyph))
	if coverage_index < 0 || coverage_index >= (read_u16(subtable, 4) or_else 0) {
		return false
	}
	set := part_at(subtable, read_u16(subtable, 6 + 2 * coverage_index) or_else -1) or_else nil
	ligature_count := read_u16(set, 0) or_else 0
	for number in 0 ..< ligature_count {
		engine.work += 1
		if engine.work > ENGINE_WORK_LIMIT {
			return false
		}
		entry := part_at(set, read_u16(set, 2 + 2 * number) or_else -1) or_else nil
		ligature := read_u16(entry, 0) or_else 0
		components := read_u16(entry, 2) or_else 0
		if components < 1 || components > ENGINE_GLYPH_LIMIT {
			continue
		}
		positions: [ENGINE_GLYPH_LIMIT]u8
		at := index
		matched := true
		for component in 1 ..< components {
			at = engine_next(engine, head, at + 1, 1)
			if at >= engine.buffer.count || int(engine.buffer.glyphs[at].glyph) != (read_u16(entry, 4 + 2 * (component - 1)) or_else -1) {
				matched = false
				break
			}
			positions[component] = u8(at)
		}
		if !matched || !engine_replace(engine, index, ligature) {
			continue
		}
		for component := components - 1; component >= 1; component -= 1 {
			engine_remove(engine, int(positions[component]))
		}
		return true
	}
	return false
}

// The forms of the items of a sequence of a contextual rule.
@(private)
Sequence_Form :: enum u8 {
	Glyphs, // Glyph indices.
	Classes, // Classes of a class definition.
	Coverages, // Offsets of coverages, from base.
}

@(private)
Sequence :: struct {
	form:    Sequence_Form,
	data:    []u8,
	at:      int, // The place of the first item in data.
	count:   int,
	classes: []u8, // Classes: the class definition.
	base:    []u8, // Coverages: what the offsets are from.
}

@(private)
sequence_item_matches :: proc "contextless" (sequence: ^Sequence, item, glyph: int) -> bool {
	value, ok := read_u16(sequence.data, sequence.at + 2 * item)
	if !ok {
		return false
	}
	switch sequence.form {
	case .Glyphs:
		return value == glyph
	case .Classes:
		return class_value(sequence.classes, glyph) == value
	case .Coverages:
		coverage := part_at(sequence.base, value) or_else nil
		found, problem := coverage_index_of(coverage, glyph)
		return coverage != nil && problem == .None && found >= 0
	}
	return false
}

// engine_match matches a rule at a glyph: its input after the first glyph,
// its backtrack before it and its lookahead after the input, each over the
// glyphs that the lookup skips. It gives the places of the input.
@(private)
engine_match :: proc "contextless" (engine: ^Engine, head: ^Lookup_Head, index: int, input, backtrack, lookahead: ^Sequence, positions: ^[ENGINE_GLYPH_LIMIT]u8) -> (input_count: int, matched: bool) {
	if input.count + 1 > ENGINE_GLYPH_LIMIT {
		return 0, false
	}
	buffer := engine.buffer
	positions[0] = u8(index)
	at := index
	for item in 0 ..< input.count {
		at = engine_next(engine, head, at + 1, 1)
		if at >= buffer.count || !sequence_item_matches(input, item, int(buffer.glyphs[at].glyph)) {
			return 0, false
		}
		positions[item + 1] = u8(at)
	}
	if backtrack != nil {
		back := index
		for item in 0 ..< backtrack.count {
			back = engine_next(engine, head, back - 1, -1)
			if back < 0 || !sequence_item_matches(backtrack, item, int(buffer.glyphs[back].glyph)) {
				return 0, false
			}
		}
	}
	if lookahead != nil {
		ahead := at
		for item in 0 ..< lookahead.count {
			ahead = engine_next(engine, head, ahead + 1, 1)
			if ahead >= buffer.count || !sequence_item_matches(lookahead, item, int(buffer.glyphs[ahead].glyph)) {
				return 0, false
			}
		}
	}
	return input.count + 1, true
}

// engine_records applies the nested lookups of a rule at the places of its
// input, and gives the place after the input. A substitution that changes
// the count of glyphs moves the places after it.
@(private)
engine_records :: proc "contextless" (engine: ^Engine, records: []u8, record_count, depth: int, positions: ^[ENGINE_GLYPH_LIMIT]u8, input_count: int) -> int {
	for record in 0 ..< record_count {
		sequence_index := read_u16(records, 4 * record) or_else -1
		lookup_index := read_u16(records, 4 * record + 2) or_else -1
		if sequence_index < 0 || sequence_index >= input_count || depth + 1 >= ENGINE_NESTING_LIMIT {
			continue
		}
		nested, found := layout_lookup_of(engine.font, engine.place, lookup_index)
		if !found {
			continue
		}
		head, ok := lookup_head(nested, engine.kind == .Substitution ? 7 : 9)
		if !ok {
			continue
		}
		position := int(positions[sequence_index])
		before := engine.buffer.count
		engine_apply_at(engine, nested, &head, position, depth + 1)
		delta := engine.buffer.count - before
		if delta != 0 {
			for &place in positions[:input_count] {
				if int(place) > position {
					place = u8(clamp(int(place) + delta, 0, ENGINE_GLYPH_LIMIT - 1))
				}
			}
		}
	}
	return min(int(positions[input_count - 1]) + 1, engine.buffer.count)
}

// A contextual lookup (GSUB 5, GPOS 7) in its three formats.
@(private)
engine_context :: proc "contextless" (engine: ^Engine, head: ^Lookup_Head, subtable: []u8, index, depth: int) -> (taken: bool, after: int) {
	glyph := int(engine.buffer.glyphs[index].glyph)
	positions: [ENGINE_GLYPH_LIMIT]u8
	format := read_u16(subtable, 0) or_else 0
	switch format {
	case 1, 2:
		coverage_index := covered(subtable, 2, glyph)
		if coverage_index < 0 {
			return false, index + 1
		}
		classes: []u8
		set_number := coverage_index
		count_at := 4
		if format == 2 {
			classes = part_at(subtable, read_u16(subtable, 4) or_else -1) or_else nil
			set_number = class_value(classes, glyph)
			count_at = 6
		}
		set_count := read_u16(subtable, count_at) or_else 0
		if set_number >= set_count {
			return false, index + 1
		}
		set := part_at(subtable, read_u16(subtable, count_at + 2 + 2 * set_number) or_else 0) or_else nil
		if set == nil || (read_u16(subtable, count_at + 2 + 2 * set_number) or_else 0) == 0 {
			return false, index + 1
		}
		rule_count := read_u16(set, 0) or_else 0
		for number in 0 ..< rule_count {
			engine.work += 1
			if engine.work > ENGINE_WORK_LIMIT {
				return false, index + 1
			}
			rule := part_at(set, read_u16(set, 2 + 2 * number) or_else -1) or_else nil
			glyph_count := read_u16(rule, 0) or_else 0
			record_count := read_u16(rule, 2) or_else 0
			if glyph_count < 1 {
				continue
			}
			input := Sequence{form = format == 1 ? .Glyphs : .Classes, data = rule, at = 4, count = glyph_count - 1, classes = classes}
			input_count, matched := engine_match(engine, head, index, &input, nil, nil, &positions)
			if !matched {
				continue
			}
			records := part_at(rule, 4 + 2 * (glyph_count - 1)) or_else nil
			return true, engine_records(engine, records, record_count, depth, &positions, input_count)
		}
	case 3:
		glyph_count := read_u16(subtable, 2) or_else 0
		record_count := read_u16(subtable, 4) or_else 0
		if glyph_count < 1 || covered(subtable, 6, glyph) < 0 {
			return false, index + 1
		}
		input := Sequence{form = .Coverages, data = subtable, at = 8, count = glyph_count - 1, base = subtable}
		input_count, matched := engine_match(engine, head, index, &input, nil, nil, &positions)
		if !matched {
			return false, index + 1
		}
		records := part_at(subtable, 6 + 2 * glyph_count) or_else nil
		return true, engine_records(engine, records, record_count, depth, &positions, input_count)
	}
	return false, index + 1
}

// A chaining contextual lookup (GSUB 6, GPOS 8) in its three formats.
@(private)
engine_chain_context :: proc "contextless" (engine: ^Engine, head: ^Lookup_Head, subtable: []u8, index, depth: int) -> (taken: bool, after: int) {
	glyph := int(engine.buffer.glyphs[index].glyph)
	positions: [ENGINE_GLYPH_LIMIT]u8
	format := read_u16(subtable, 0) or_else 0
	switch format {
	case 1, 2:
		coverage_index := covered(subtable, 2, glyph)
		if coverage_index < 0 {
			return false, index + 1
		}
		backtrack_classes, input_classes, lookahead_classes: []u8
		set_number := coverage_index
		count_at := 4
		if format == 2 {
			backtrack_classes = part_at(subtable, read_u16(subtable, 4) or_else -1) or_else nil
			input_classes = part_at(subtable, read_u16(subtable, 6) or_else -1) or_else nil
			lookahead_classes = part_at(subtable, read_u16(subtable, 8) or_else -1) or_else nil
			set_number = class_value(input_classes, glyph)
			count_at = 10
		}
		set_count := read_u16(subtable, count_at) or_else 0
		set_offset := read_u16(subtable, count_at + 2 + 2 * set_number) or_else 0
		if set_number >= set_count || set_offset == 0 {
			return false, index + 1
		}
		set := part_at(subtable, set_offset) or_else nil
		rule_count := read_u16(set, 0) or_else 0
		form := format == 1 ? Sequence_Form.Glyphs : Sequence_Form.Classes
		for number in 0 ..< rule_count {
			engine.work += 1
			if engine.work > ENGINE_WORK_LIMIT {
				return false, index + 1
			}
			rule := part_at(set, read_u16(set, 2 + 2 * number) or_else -1) or_else nil
			backtrack_count := read_u16(rule, 0) or_else -1
			input_at := 2 + 2 * backtrack_count
			input_count_word := read_u16(rule, input_at) or_else 0
			lookahead_at := input_at + 2 + 2 * max(input_count_word - 1, 0)
			lookahead_count := read_u16(rule, lookahead_at) or_else -1
			records_at := lookahead_at + 2 + 2 * lookahead_count
			record_count := read_u16(rule, records_at) or_else -1
			if backtrack_count < 0 || input_count_word < 1 || lookahead_count < 0 || record_count < 0 {
				continue
			}
			backtrack := Sequence{form = form, data = rule, at = 2, count = backtrack_count, classes = backtrack_classes}
			input := Sequence{form = form, data = rule, at = input_at + 2, count = input_count_word - 1, classes = input_classes}
			lookahead := Sequence{form = form, data = rule, at = lookahead_at + 2, count = lookahead_count, classes = lookahead_classes}
			input_count, matched := engine_match(engine, head, index, &input, &backtrack, &lookahead, &positions)
			if !matched {
				continue
			}
			records := part_at(rule, records_at + 2) or_else nil
			return true, engine_records(engine, records, record_count, depth, &positions, input_count)
		}
	case 3:
		backtrack_count := read_u16(subtable, 2) or_else -1
		input_at := 4 + 2 * backtrack_count
		input_count_word := read_u16(subtable, input_at) or_else 0
		lookahead_at := input_at + 2 + 2 * input_count_word
		lookahead_count := read_u16(subtable, lookahead_at) or_else -1
		records_at := lookahead_at + 2 + 2 * lookahead_count
		record_count := read_u16(subtable, records_at) or_else -1
		if backtrack_count < 0 || input_count_word < 1 || lookahead_count < 0 || record_count < 0 || covered(subtable, input_at + 2, glyph) < 0 {
			return false, index + 1
		}
		backtrack := Sequence{form = .Coverages, data = subtable, at = 4, count = backtrack_count, base = subtable}
		input := Sequence{form = .Coverages, data = subtable, at = input_at + 4, count = input_count_word - 1, base = subtable}
		lookahead := Sequence{form = .Coverages, data = subtable, at = lookahead_at + 2, count = lookahead_count, base = subtable}
		input_count, matched := engine_match(engine, head, index, &input, &backtrack, &lookahead, &positions)
		if !matched {
			return false, index + 1
		}
		records := part_at(subtable, records_at + 2) or_else nil
		return true, engine_records(engine, records, record_count, depth, &positions, input_count)
	}
	return false, index + 1
}

// A reverse chaining single substitution (GSUB 8), format 1.
@(private)
engine_reverse :: proc "contextless" (engine: ^Engine, head: ^Lookup_Head, subtable: []u8, index: int) -> bool {
	if (read_u16(subtable, 0) or_else 0) != 1 {
		return false
	}
	coverage_index := covered(subtable, 2, int(engine.buffer.glyphs[index].glyph))
	if coverage_index < 0 {
		return false
	}
	backtrack_count := read_u16(subtable, 4) or_else -1
	lookahead_at := 6 + 2 * backtrack_count
	lookahead_count := read_u16(subtable, lookahead_at) or_else -1
	substitutes_at := lookahead_at + 2 + 2 * lookahead_count
	substitute_count := read_u16(subtable, substitutes_at) or_else 0
	if backtrack_count < 0 || lookahead_count < 0 || coverage_index >= substitute_count {
		return false
	}
	positions: [ENGINE_GLYPH_LIMIT]u8
	input := Sequence{form = .Coverages, data = subtable, at = 0, count = 0, base = subtable}
	backtrack := Sequence{form = .Coverages, data = subtable, at = 6, count = backtrack_count, base = subtable}
	lookahead := Sequence{form = .Coverages, data = subtable, at = lookahead_at + 2, count = lookahead_count, base = subtable}
	if _, matched := engine_match(engine, head, index, &input, &backtrack, &lookahead, &positions); !matched {
		return false
	}
	return engine_replace(engine, index, read_u16(subtable, substitutes_at + 2 + 2 * coverage_index) or_else 0)
}

// value_record_read reads a value record of GPOS: its placements and its
// advance, and its size in bytes. The device tables are skipped.
@(private)
value_record_read :: proc "contextless" (data: []u8, at, format: int) -> (x_placement, y_placement, x_advance: i32, size: int) {
	place := at
	for bit in 0 ..< 8 {
		if format & (1 << uint(bit)) == 0 {
			continue
		}
		value := read_i16(data, place) or_else 0
		switch bit {
		case 0:
			x_placement = i32(value)
		case 1:
			y_placement = i32(value)
		case 2:
			x_advance = i32(value)
		}
		place += 2
	}
	return x_placement, y_placement, x_advance, place - at
}

@(private)
value_record_apply :: proc "contextless" (glyph: ^Engine_Glyph, data: []u8, at, format: int) {
	x_placement, y_placement, x_advance, _ := value_record_read(data, at, format)
	glyph.x_offset += x_placement
	glyph.y_offset += y_placement
	glyph.x_advance += x_advance
}

// A single adjustment (GPOS 1).
@(private)
engine_single_position :: proc "contextless" (engine: ^Engine, subtable: []u8, index: int) -> bool {
	coverage_index := covered(subtable, 2, int(engine.buffer.glyphs[index].glyph))
	if coverage_index < 0 {
		return false
	}
	format := read_u16(subtable, 0) or_else 0
	value_format := read_u16(subtable, 4) or_else 0
	switch format {
	case 1:
		value_record_apply(&engine.buffer.glyphs[index], subtable, 6, value_format)
		return true
	case 2:
		if coverage_index >= (read_u16(subtable, 6) or_else 0) {
			return false
		}
		_, _, _, size := value_record_read(subtable, 8, value_format)
		value_record_apply(&engine.buffer.glyphs[index], subtable, 8 + size * coverage_index, value_format)
		return true
	}
	return false
}

// A pair adjustment (GPOS 2), in its two formats: the glyph and the next
// glyph that the lookup does not skip.
@(private)
engine_pair_position :: proc "contextless" (engine: ^Engine, head: ^Lookup_Head, subtable: []u8, index: int) -> bool {
	buffer := engine.buffer
	coverage_index := covered(subtable, 2, int(buffer.glyphs[index].glyph))
	second := engine_next(engine, head, index + 1, 1)
	if coverage_index < 0 || second >= buffer.count {
		return false
	}
	format := read_u16(subtable, 0) or_else 0
	first_format := read_u16(subtable, 4) or_else 0
	second_format := read_u16(subtable, 6) or_else 0
	_, _, _, first_size := value_record_read(subtable, 0, first_format)
	_, _, _, second_size := value_record_read(subtable, 0, second_format)
	second_glyph := int(buffer.glyphs[second].glyph)
	switch format {
	case 1:
		if coverage_index >= (read_u16(subtable, 8) or_else 0) {
			return false
		}
		set := part_at(subtable, read_u16(subtable, 10 + 2 * coverage_index) or_else -1) or_else nil
		pair_count := read_u16(set, 0) or_else 0
		record_size := 2 + first_size + second_size
		low, high := 0, pair_count
		for low < high {
			middle := low + (high - low) / 2
			value := read_u16(set, 2 + record_size * middle) or_else -1
			switch {
			case value == second_glyph:
				at := 2 + record_size * middle + 2
				value_record_apply(&buffer.glyphs[index], set, at, first_format)
				value_record_apply(&buffer.glyphs[second], set, at + first_size, second_format)
				return true
			case value < second_glyph:
				low = middle + 1
			case:
				high = middle
			}
		}
	case 2:
		first_classes := part_at(subtable, read_u16(subtable, 8) or_else -1) or_else nil
		second_classes := part_at(subtable, read_u16(subtable, 10) or_else -1) or_else nil
		first_count := read_u16(subtable, 12) or_else 0
		second_count := read_u16(subtable, 14) or_else 0
		first_class := class_value(first_classes, int(buffer.glyphs[index].glyph))
		second_class := class_value(second_classes, second_glyph)
		if first_class >= first_count || second_class >= second_count {
			return false
		}
		at := 16 + (first_class * second_count + second_class) * (first_size + second_size)
		value_record_apply(&buffer.glyphs[index], subtable, at, first_format)
		value_record_apply(&buffer.glyphs[second], subtable, at + first_size, second_format)
		return true
	}
	return false
}

@(private)
engine_attach :: proc "contextless" (engine: ^Engine, index, target, dx, dy: int) {
	glyph := &engine.buffer.glyphs[index]
	glyph.attach = i8(target)
	glyph.attach_dx = i32(dx)
	glyph.attach_dy = i32(dy)
}

// A mark-to-base attachment (GPOS 4): the mark and the glyph before it
// that is no mark.
@(private)
engine_mark_to_base :: proc "contextless" (engine: ^Engine, subtable: []u8, index: int) -> bool {
	buffer := engine.buffer
	if buffer.glyphs[index].class != .Mark {
		return false
	}
	base := index - 1
	for base >= 0 && buffer.glyphs[base].class == .Mark {
		base -= 1
	}
	if base < 0 {
		return false
	}
	dx, dy, found, problem := mark_subtable_offset(subtable, int(buffer.glyphs[base].glyph), int(buffer.glyphs[index].glyph))
	if problem != .None || !found {
		return false
	}
	engine_attach(engine, index, base, dx, dy)
	return true
}

// A mark-to-ligature attachment (GPOS 5): the mark on the last component
// of the ligature before it.
@(private)
engine_mark_to_ligature :: proc "contextless" (engine: ^Engine, subtable: []u8, index: int) -> bool {
	buffer := engine.buffer
	if buffer.glyphs[index].class != .Mark || (read_u16(subtable, 0) or_else 0) != 1 {
		return false
	}
	ligature := index - 1
	for ligature >= 0 && buffer.glyphs[ligature].class == .Mark {
		ligature -= 1
	}
	if ligature < 0 {
		return false
	}
	mark_index := covered(subtable, 2, int(buffer.glyphs[index].glyph))
	ligature_index := covered(subtable, 4, int(buffer.glyphs[ligature].glyph))
	class_count := read_u16(subtable, 6) or_else 0
	mark_array := part_at(subtable, read_u16(subtable, 8) or_else -1) or_else nil
	ligature_array := part_at(subtable, read_u16(subtable, 10) or_else -1) or_else nil
	if mark_index < 0 || ligature_index < 0 || mark_index >= (read_u16(mark_array, 0) or_else 0) || ligature_index >= (read_u16(ligature_array, 0) or_else 0) {
		return false
	}
	class := read_u16(mark_array, 2 + 4 * mark_index) or_else -1
	mark_anchor := read_u16(mark_array, 4 + 4 * mark_index) or_else 0
	attach := part_at(ligature_array, read_u16(ligature_array, 2 + 2 * ligature_index) or_else -1) or_else nil
	components := read_u16(attach, 0) or_else 0
	if class < 0 || class >= class_count || components < 1 || mark_anchor == 0 {
		return false
	}
	anchor_offset := read_u16(attach, 2 + 2 * ((components - 1) * class_count + class)) or_else 0
	if anchor_offset == 0 {
		return false
	}
	mark_x, mark_y, mark_problem := anchor_read(mark_array, mark_anchor)
	base_x, base_y, base_problem := anchor_read(attach, anchor_offset)
	if mark_problem != .None || base_problem != .None {
		return false
	}
	engine_attach(engine, index, ligature, base_x - mark_x, base_y - mark_y)
	return true
}

// A mark-to-mark attachment (GPOS 6): the mark and the mark before it that
// the lookup does not skip.
@(private)
engine_mark_to_mark :: proc "contextless" (engine: ^Engine, head: ^Lookup_Head, subtable: []u8, index: int) -> bool {
	buffer := engine.buffer
	if buffer.glyphs[index].class != .Mark {
		return false
	}
	before := engine_next(engine, head, index - 1, -1)
	if before < 0 || buffer.glyphs[before].class != .Mark {
		return false
	}
	dx, dy, found, problem := mark_subtable_offset(subtable, int(buffer.glyphs[before].glyph), int(buffer.glyphs[index].glyph))
	if problem != .None || !found {
		return false
	}
	engine_attach(engine, index, before, dx, dy)
	return true
}
// layout_would_substitute says if a lookup of a feature applies to exactly
// these glyphs, with no context before or after them (HarfBuzz,
// would_substitute with a zero context): a single, multiple or alternate
// substitution to one glyph, a ligature of exactly these components, a
// contextual rule whose input is exactly these glyphs and that has no
// backtrack and no lookahead. The shaper of the scripts of India asks it
// which consonants take a below form or a post form, and if ra and the
// virama make a reph.
layout_would_substitute :: proc "contextless" (font: ^Font_File, script, tag: Feature_Tag, glyphs: []int) -> bool {
	if len(glyphs) == 0 || len(glyphs) > ENGINE_GLYPH_LIMIT {
		return false
	}
	lookups: Layout_Lookups
	if layout_lookups(font, font.gsub, script, {'D', 'F', 'L', 'T'}, tag, &lookups) != .None {
		return false
	}
	engine := Engine{font = font, place = font.gsub, kind = .Substitution, gdef = gdef_of(font)}
	for lookup in lookups.parts[:lookups.count] {
		head := lookup_head(lookup, 7) or_continue
		for number in 0 ..< head.subtables {
			engine.work += 1
			if engine.work > ENGINE_WORK_LIMIT {
				return false
			}
			subtable := engine_subtable(&engine, lookup, number) or_continue
			if subtable_would_apply(head.type, subtable, glyphs, &engine.work) {
				return true
			}
		}
	}
	return false
}

// rule_input_matches says if the input of a rule, after its first glyph,
// is exactly the glyphs after the first.
@(private)
rule_input_matches :: proc "contextless" (input: ^Sequence, glyphs: []int) -> bool {
	if input.count != len(glyphs) - 1 {
		return false
	}
	for item in 0 ..< input.count {
		if !sequence_item_matches(input, item, glyphs[item + 1]) {
			return false
		}
	}
	return true
}

@(private)
subtable_would_apply :: proc "contextless" (type: int, subtable: []u8, glyphs: []int, work: ^int) -> bool {
	first := glyphs[0]
	format := read_u16(subtable, 0) or_else 0
	switch type {
	case 1, 2, 3:
		return len(glyphs) == 1 && covered(subtable, 2, first) >= 0
	case 4:
		coverage_index := covered(subtable, 2, first)
		if coverage_index < 0 || coverage_index >= (read_u16(subtable, 4) or_else 0) {
			return false
		}
		set := part_at(subtable, read_u16(subtable, 6 + 2 * coverage_index) or_else -1) or_else nil
		for number in 0 ..< (read_u16(set, 0) or_else 0) {
			work^ += 1
			if work^ > ENGINE_WORK_LIMIT {
				return false
			}
			entry := part_at(set, read_u16(set, 2 + 2 * number) or_else -1) or_else nil
			if (read_u16(entry, 2) or_else 0) != len(glyphs) {
				continue
			}
			input := Sequence{form = .Glyphs, data = entry, at = 4, count = len(glyphs) - 1}
			if rule_input_matches(&input, glyphs) {
				return true
			}
		}
	case 5, 6:
		chain := type == 6
		switch format {
		case 1, 2:
			coverage_index := covered(subtable, 2, first)
			if coverage_index < 0 {
				return false
			}
			classes: []u8
			set_number := coverage_index
			count_at := 4
			if format == 2 {
				classes = part_at(subtable, read_u16(subtable, chain ? 6 : 4) or_else -1) or_else nil
				set_number = class_value(classes, first)
				count_at = chain ? 10 : 6
			}
			if set_number >= (read_u16(subtable, count_at) or_else 0) {
				return false
			}
			set_offset := read_u16(subtable, count_at + 2 + 2 * set_number) or_else 0
			if set_offset == 0 {
				return false
			}
			set := part_at(subtable, set_offset) or_else nil
			form := format == 1 ? Sequence_Form.Glyphs : Sequence_Form.Classes
			for number in 0 ..< (read_u16(set, 0) or_else 0) {
				work^ += 1
				if work^ > ENGINE_WORK_LIMIT {
					return false
				}
				rule := part_at(set, read_u16(set, 2 + 2 * number) or_else -1) or_else nil
				input_at := 0
				if chain {
					if (read_u16(rule, 0) or_else 1) != 0 {
						continue // A backtrack: a context.
					}
					input_at = 2
				}
				glyph_count := read_u16(rule, input_at) or_else 0
				if glyph_count != len(glyphs) {
					continue
				}
				items_at := chain ? input_at + 2 : 4
				if chain && (read_u16(rule, items_at + 2 * (glyph_count - 1)) or_else 1) != 0 {
					continue // A lookahead: a context.
				}
				input := Sequence{form = form, data = rule, at = items_at, count = glyph_count - 1, classes = classes}
				if rule_input_matches(&input, glyphs) {
					return true
				}
			}
		case 3:
			if !chain {
				glyph_count := read_u16(subtable, 2) or_else 0
				if glyph_count != len(glyphs) {
					return false
				}
				input := Sequence{form = .Coverages, data = subtable, at = 6, count = glyph_count, base = subtable}
				for item in 0 ..< glyph_count {
					if !sequence_item_matches(&input, item, glyphs[item]) {
						return false
					}
				}
				return true
			}
			if (read_u16(subtable, 2) or_else 1) != 0 {
				return false
			}
			glyph_count := read_u16(subtable, 4) or_else 0
			if glyph_count != len(glyphs) || (read_u16(subtable, 6 + 2 * glyph_count) or_else 1) != 0 {
				return false
			}
			input := Sequence{form = .Coverages, data = subtable, at = 6, count = glyph_count, base = subtable}
			for item in 0 ..< glyph_count {
				if !sequence_item_matches(&input, item, glyphs[item]) {
					return false
				}
			}
			return true
		}
	case 8:
		return len(glyphs) == 1 && (read_u16(subtable, 4) or_else 1) == 0 && covered(subtable, 2, first) >= 0 && (read_u16(subtable, 6) or_else 1) == 0
	}
	return false
}
