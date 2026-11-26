#+build !freestanding
#+build !modus
package vector_font

import "core:testing"

// The engine of the lookups against built tables that a hostile font can
// hold: a script list with a repeated tag (the cache answers as the walk),
// the variations of the features (the record that holds, and counts past
// the bound), GDEF with a mark filtering set under a mark-to-base of GPOS,
// a rule that names 65 535 records, and a stage that passes
// ENGINE_STEP_LIMIT.

@(private = "file")
Bytes :: [dynamic]u8

@(private = "file")
put16 :: proc(bytes: ^Bytes, value: int) {
	append(bytes, u8(value >> 8), u8(value))
}

@(private = "file")
put32 :: proc(bytes: ^Bytes, value: int) {
	append(bytes, u8(value >> 24), u8(value >> 16), u8(value >> 8), u8(value))
}

@(private = "file")
set16 :: proc(bytes: ^Bytes, at, value: int) {
	bytes[at], bytes[at + 1] = u8(value >> 8), u8(value)
}

@(private = "file")
set32 :: proc(bytes: ^Bytes, at, value: int) {
	bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3] = u8(value >> 24), u8(value >> 16), u8(value >> 8), u8(value)
}

@(private = "file")
coverage :: proc(glyphs: []int) -> []u8 {
	bytes := make(Bytes, context.temp_allocator)
	put16(&bytes, 1)
	put16(&bytes, len(glyphs))
	for glyph in glyphs {
		put16(&bytes, glyph)
	}
	return bytes[:]
}

// A lookup of one subtable, with a mark filtering set when filter >= 0.
@(private = "file")
lookup :: proc(type, flag: int, subtable: []u8, filter := -1) -> []u8 {
	bytes := make(Bytes, context.temp_allocator)
	put16(&bytes, type)
	put16(&bytes, flag | (filter >= 0 ? LOOKUP_MARK_FILTERING_SET : 0))
	put16(&bytes, 1)
	put16(&bytes, 0)
	if filter >= 0 {
		put16(&bytes, filter)
	}
	set16(&bytes, 6, len(bytes))
	append(&bytes, ..subtable)
	return bytes[:]
}

// A single substitution of format 2.
@(private = "file")
single :: proc(from, to: int) -> []u8 {
	bytes := make(Bytes, context.temp_allocator)
	put16(&bytes, 2)
	put16(&bytes, 0)
	put16(&bytes, 1)
	put16(&bytes, to)
	set16(&bytes, 2, len(bytes))
	append(&bytes, ..coverage({from}))
	return bytes[:]
}

@(private = "file")
Script_Of :: struct {
	tag:      Feature_Tag,
	default:  bool, // It has a default language system.
	features: []int, // The indices of its features in the feature list.
}

@(private = "file")
Feature_Of :: struct {
	tag:     Feature_Tag,
	lookups: []int,
}

// table writes a table GSUB or GPOS: version 1.0, or 1.1 with the
// variations of the features when variations is not nil.
@(private = "file")
table :: proc(scripts: []Script_Of, features: []Feature_Of, lookups: [][]u8, variations: []u8 = nil) -> []u8 {
	head_size := variations == nil ? 10 : 14
	bytes := make(Bytes, context.temp_allocator)
	put16(&bytes, 1)
	put16(&bytes, variations == nil ? 0 : 1)
	for _ in 2 ..< head_size / 2 {
		put16(&bytes, 0)
	}
	// The script list.
	script_list := len(bytes)
	set16(&bytes, 4, script_list)
	put16(&bytes, len(scripts))
	for script in scripts {
		append(&bytes, script.tag[0], script.tag[1], script.tag[2], script.tag[3])
		put16(&bytes, 0)
	}
	for script, number in scripts {
		set16(&bytes, script_list + 2 + 6 * number + 4, len(bytes) - script_list)
		script_at := len(bytes)
		put16(&bytes, script.default ? 4 : 0)
		put16(&bytes, 0)
		_ = script_at
		if script.default {
			put16(&bytes, 0)
			put16(&bytes, 0xFFFF)
			put16(&bytes, len(script.features))
			for index in script.features {
				put16(&bytes, index)
			}
		}
	}
	// The feature list.
	feature_list := len(bytes)
	set16(&bytes, 6, feature_list)
	put16(&bytes, len(features))
	for feature in features {
		append(&bytes, feature.tag[0], feature.tag[1], feature.tag[2], feature.tag[3])
		put16(&bytes, 0)
	}
	for feature, number in features {
		set16(&bytes, feature_list + 2 + 6 * number + 4, len(bytes) - feature_list)
		put16(&bytes, 0)
		put16(&bytes, len(feature.lookups))
		for index in feature.lookups {
			put16(&bytes, index)
		}
	}
	// The lookup list.
	lookup_list := len(bytes)
	set16(&bytes, 8, lookup_list)
	put16(&bytes, len(lookups))
	for _ in lookups {
		put16(&bytes, 0)
	}
	for one, number in lookups {
		set16(&bytes, lookup_list + 2 + 2 * number, len(bytes) - lookup_list)
		append(&bytes, ..one)
	}
	if variations != nil {
		set32(&bytes, 10, len(bytes))
		append(&bytes, ..variations)
	}
	return bytes[:]
}

// The feature table of a variation: no parameters, its lookups.
@(private = "file")
feature_table :: proc(lookups: []int) -> []u8 {
	bytes := make(Bytes, context.temp_allocator)
	put16(&bytes, 0)
	put16(&bytes, len(lookups))
	for index in lookups {
		put16(&bytes, index)
	}
	return bytes[:]
}

@(private = "file")
Variation_Of :: struct {
	condition:  bool, // It has a condition set of conditions_count conditions of the range low to high.
	conditions: int,
	low, high:  int, // F2Dot14.
	feature:    int, // The feature that it puts another table in the place of.
	lookups:    []int,
}

// variations writes the variations of the features: a record for each,
// then record_count in the header, which a test can set past them.
@(private = "file")
variations :: proc(records: []Variation_Of, record_count := -1) -> []u8 {
	bytes := make(Bytes, context.temp_allocator)
	put16(&bytes, 1)
	put16(&bytes, 0)
	put32(&bytes, record_count < 0 ? len(records) : record_count)
	for _ in records {
		put32(&bytes, 0)
		put32(&bytes, 0)
	}
	for record, number in records {
		if record.condition {
			set32(&bytes, 8 + 8 * number, len(bytes))
			set_at := len(bytes)
			put16(&bytes, record.conditions)
			for _ in 0 ..< record.conditions {
				put32(&bytes, 0)
			}
			for condition in 0 ..< record.conditions {
				set32(&bytes, set_at + 2 + 4 * condition, len(bytes) - set_at)
				put16(&bytes, 1)
				put16(&bytes, 0)
				put16(&bytes, record.low)
				put16(&bytes, record.high)
			}
		}
		set32(&bytes, 12 + 8 * number, len(bytes))
		substitution_at := len(bytes)
		put16(&bytes, 1)
		put16(&bytes, 0)
		put16(&bytes, 1)
		put16(&bytes, record.feature)
		put32(&bytes, 0)
		set32(&bytes, substitution_at + 8, len(bytes) - substitution_at)
		append(&bytes, ..feature_table(record.lookups))
	}
	return bytes[:]
}

@(private = "file")
TEST :: Feature_Tag{'t', 'e', 's', 't'}
@(private = "file")
DFLT :: Feature_Tag{'D', 'F', 'L', 'T'}

// font_of gives a font of the tables: GSUB, GPOS and GDEF, one after the
// other in its bytes.
@(private = "file")
font_of :: proc(gsub, gpos, gdef: []u8) -> (font: Font_File) {
	bytes := make(Bytes, context.temp_allocator)
	place :: proc(bytes: ^Bytes, part: []u8) -> Table {
		at := len(bytes)
		append(bytes, ..part)
		for len(bytes) % 4 != 0 {
			append(bytes, 0)
		}
		return {offset = at, length = len(part)}
	}
	font.gsub = place(&bytes, gsub)
	font.gpos = place(&bytes, gpos)
	font.gdef = place(&bytes, gdef)
	font.bytes = bytes[:]
	font.glyph_count = 100
	return font
}

@(private = "file")
stage_of :: proc(font: ^Font_File, kind: Layout_Kind, glyphs: []int, limit := LAYOUT_WORK_FLOOR) -> (buffer: Engine_Buffer, problem: Font_Problem, budget: Layout_Budget) {
	budget = {limit = limit}
	for glyph, index in glyphs {
		buffer.glyphs[index] = {glyph = u16(glyph), place = u8(index), mask = 1}
	}
	buffer.count = len(glyphs)
	engine_buffer_prepare(font, &buffer)
	features := [1]Engine_Feature{{TEST, 1}}
	problem = engine_stage(font, kind, DFLT, features[:], &buffer, &budget)
	return
}

// A script list where a tag comes twice: the walk reads the first record
// of the tag only, so a feature of the second is no feature; the cache
// gives the same answers, for each tag, and for a first record with no
// default language system.
@(test)
the_cache_answers_as_the_walk_with_a_repeated_script :: proc(t: ^testing.T) {
	XXXX :: Feature_Tag{'x', 'x', 'x', 'x'}
	AAAA :: Feature_Tag{'a', 'a', 'a', 'a'}
	BBBB :: Feature_Tag{'b', 'b', 'b', 'b'}
	scripts := []Script_Of{{DFLT, true, {0}}, {DFLT, true, {1}}, {XXXX, false, nil}, {XXXX, true, {1}}}
	features := []Feature_Of{{AAAA, {0}}, {BBBB, {0}}}
	gsub := table(scripts, features, {lookup(1, 0, single(5, 6))})
	walked := font_of(gsub, nil, nil)
	cached := walked
	entries: [64]Layout_Cache_Entry
	indices: [64]u16
	cache := Layout_Cache{entries = entries[:], indices = indices[:]}
	fill_status, _ := layout_cache_fill(&cached, &cache)
	testing.expect(t, fill_status == .Complete && cached.layout_cache == &cache)
	// Inline capacity edge: an empty pool returns Pool_Full (not Refused)
	// for a valid font, leaves layout_cache nil, and layout_lookups falls
	// back to the uncached table walk with the same results.
	small_cached := walked
	small_cache := Layout_Cache{}
	small_status, _ := layout_cache_fill(&small_cached, &small_cache)
	testing.expect(t, small_status == .Pool_Full && small_cached.layout_cache == nil)
	for script in ([2]Feature_Tag{DFLT, XXXX}) {
		for tag in ([2]Feature_Tag{AAAA, BBBB}) {
			from_walk, from_cache: Layout_Lookups
			walk_problem := layout_lookups(&walked, walked.gsub, script, DFLT, tag, &from_walk)
			cache_problem := layout_lookups(&cached, cached.gsub, script, DFLT, tag, &from_cache)
			testing.expectf(t, walk_problem == cache_problem && from_walk.count == from_cache.count, "%s %s: the walk %v %d, the cache %v %d", script, tag, walk_problem, from_walk.count, cache_problem, from_cache.count)
		}
	}
	from_walk: Layout_Lookups
	testing.expect_value(t, layout_lookups(&walked, walked.gsub, DFLT, DFLT, BBBB, &from_walk), Font_Problem.No_Feature)
}

// The variations of the features at the default coordinates: a record
// whose condition does not hold (0.5 to 1) is passed, the next with no
// condition puts its table in the place of the feature, and the lookup of
// that table applies. 65 records, or a condition set of 65 conditions, is
// refused, not cut.
@(test)
the_variations_of_the_features :: proc(t: ^testing.T) {
	scripts := []Script_Of{{DFLT, true, {0}}}
	features := []Feature_Of{{TEST, {0}}}
	lookups := [][]u8{lookup(1, 0, single(5, 6)), lookup(1, 0, single(5, 7)), lookup(1, 0, single(5, 8))}
	records := []Variation_Of{{condition = true, conditions = 1, low = 0x2000, high = 0x4000, feature = 0, lookups = {1}}, {feature = 0, lookups = {2}}}
	font := font_of(table(scripts, features, lookups, variations(records)), nil, nil)
	buffer, problem, _ := stage_of(&font, .Substitution, {5})
	testing.expectf(t, problem == .None && buffer.glyphs[0].glyph == 8, "the record that holds: %v, the glyph %d", problem, buffer.glyphs[0].glyph)
	// With no record that holds, the feature keeps its own lookup.
	font = font_of(table(scripts, features, lookups, variations(records[:1])), nil, nil)
	buffer, problem, _ = stage_of(&font, .Substitution, {5})
	testing.expect(t, problem == .None && buffer.glyphs[0].glyph == 6)
	// 64 conditions are read; 65 are refused.
	for count in ([2]int{FEATURE_VARIATION_LIMIT, FEATURE_VARIATION_LIMIT + 1}) {
		many := []Variation_Of{{condition = true, conditions = count, low = -0x4000, high = 0x4000, feature = 0, lookups = {2}}}
		font = font_of(table(scripts, features, lookups, variations(many)), nil, nil)
		lookups_found: Layout_Lookups
		found := layout_lookups(&font, font.gsub, DFLT, DFLT, TEST, &lookups_found)
		refused := count > FEATURE_VARIATION_LIMIT
		testing.expectf(t, refused ? found == .Unknown_Format : found == .None && lookups_found.indices[0] == 2, "%d conditions: %v", count, found)
	}
	// A count of records past the bound.
	font = font_of(table(scripts, features, lookups, variations(records, FEATURE_VARIATION_LIMIT + 1)), nil, nil)
	lookups_found: Layout_Lookups
	testing.expect_value(t, layout_lookups(&font, font.gsub, DFLT, DFLT, TEST, &lookups_found), Font_Problem.Unknown_Format)
}

// gdef writes a table GDEF 1.2: the class of each glyph from 4 (base,
// mark, mark), and one mark set of the glyphs of the set.
@(private = "file")
gdef :: proc(set: []int) -> []u8 {
	bytes := make(Bytes, context.temp_allocator)
	put16(&bytes, 1)
	put16(&bytes, 2)
	for _ in 0 ..< 5 {
		put16(&bytes, 0)
	}
	set16(&bytes, 4, len(bytes))
	put16(&bytes, 1)
	put16(&bytes, 4)
	put16(&bytes, 3)
	put16(&bytes, 1)
	put16(&bytes, 3)
	put16(&bytes, 3)
	set16(&bytes, 12, len(bytes))
	sets_at := len(bytes)
	put16(&bytes, 1)
	put16(&bytes, 1)
	put32(&bytes, 0)
	set32(&bytes, sets_at + 4, len(bytes) - sets_at)
	append(&bytes, ..coverage(set))
	return bytes[:]
}

// A mark-to-base of format 1: the marks 5 and 6 with their anchor at
// (10, 20), the base 4 with its anchor at (100, 200).
@(private = "file")
mark_to_base :: proc() -> []u8 {
	bytes := make(Bytes, context.temp_allocator)
	put16(&bytes, 1)
	for _ in 0 ..< 5 {
		put16(&bytes, 0)
	}
	set16(&bytes, 6, 1)
	set16(&bytes, 2, len(bytes))
	append(&bytes, ..coverage({5, 6}))
	set16(&bytes, 4, len(bytes))
	append(&bytes, ..coverage({4}))
	set16(&bytes, 8, len(bytes))
	marks_at := len(bytes)
	put16(&bytes, 2)
	put16(&bytes, 0)
	put16(&bytes, 10)
	put16(&bytes, 0)
	put16(&bytes, 10)
	put16(&bytes, 1)
	put16(&bytes, 10)
	put16(&bytes, 20)
	_ = marks_at
	set16(&bytes, 10, len(bytes))
	put16(&bytes, 1)
	put16(&bytes, 4)
	put16(&bytes, 1)
	put16(&bytes, 100)
	put16(&bytes, 200)
	return bytes[:]
}

// GPOS in the engine: a mark after a base attaches to it by their anchors,
// and engine_positions_finish gives its offset from the base; a lookup
// whose mark filtering set does not hold the mark skips it, so it does not
// attach; with the set that holds it, it does.
@(test)
a_mark_attaches_by_its_anchors_and_its_mark_set :: proc(t: ^testing.T) {
	scripts := []Script_Of{{DFLT, true, {0}}}
	features := []Feature_Of{{TEST, {0}}}
	for filter in ([3]int{-1, 0, 1}) {
		set := filter == 1 ? []int{5} : []int{9}
		used := filter == 1 ? 0 : filter
		gpos := table(scripts, features, {lookup(4, 0, mark_to_base(), used)})
		font := font_of(nil, gpos, gdef(set))
		buffer, problem, _ := stage_of(&font, .Positioning, {4, 5})
		engine_positions_finish(&buffer)
		attaches := filter != 0
		mark := buffer.glyphs[1]
		testing.expectf(t, problem == .None && buffer.glyphs[1].class == .Mark && (mark.attach == 0) == attaches, "the filter %d: %v, attached to %d", filter, problem, mark.attach)
		if attaches {
			testing.expectf(t, mark.x_offset == 90 && mark.y_offset == 180, "the offset of the mark: %d, %d", mark.x_offset, mark.y_offset)
		}
	}
}

// chain_rule writes a chaining contextual rule of format 3 on the glyph 5:
// record_count in its header, and records of the lookup 1 at the place 0,
// real_records of them in its bytes.
@(private = "file")
chain_rule :: proc(record_count, real_records: int) -> []u8 {
	bytes := make(Bytes, context.temp_allocator)
	put16(&bytes, 3)
	put16(&bytes, 0)
	put16(&bytes, 1)
	put16(&bytes, 0)
	put16(&bytes, 0)
	put16(&bytes, record_count)
	for _ in 0 ..< real_records {
		put16(&bytes, 0)
		put16(&bytes, 1)
	}
	set16(&bytes, 6, len(bytes))
	append(&bytes, ..coverage({5}))
	return bytes[:]
}

// A rule that names 65 535 records, of which its bytes hold two: each
// record that the engine skips takes from the budget, so a budget of 1 000
// ends the stage with Too_Much_Work, and the stage after it does no work.
// The floor of a budget, 65 536 units, does not hold the 65 535 records
// and their rule either: the stage keeps the glyph of the first record and
// ends with Too_Much_Work; a budget of a call of 64 bytes does, and the
// first record applies.
@(test)
a_rule_of_65535_records_takes_from_the_budget :: proc(t: ^testing.T) {
	scripts := []Script_Of{{DFLT, true, {0}}}
	features := []Feature_Of{{TEST, {0}}}
	gsub := table(scripts, features, {lookup(6, 0, chain_rule(65535, 2)), lookup(1, 0, single(5, 6))})
	font := font_of(gsub, nil, nil)
	buffer, problem, budget := stage_of(&font, .Substitution, {5}, 1000)
	testing.expectf(t, problem == .Too_Much_Work && layout_budget_spent(&budget), "a budget of 1 000: %v, %d units", problem, budget.work)
	again := [1]Engine_Feature{{TEST, 1}}
	before := budget.work
	testing.expect_value(t, engine_stage(&font, .Substitution, DFLT, again[:], &buffer, &budget), Font_Problem.Too_Much_Work)
	testing.expect_value(t, budget.work, before)
	buffer, problem, budget = stage_of(&font, .Substitution, {5}, layout_budget_of_text(0).limit)
	testing.expectf(t, problem == .Too_Much_Work && layout_budget_spent(&budget), "the floor of a budget: %v, the glyph %d, %d units", problem, buffer.glyphs[0].glyph, budget.work)
	buffer, problem, budget = stage_of(&font, .Substitution, {5}, layout_budget_of_text(64).limit)
	testing.expectf(t, problem == .None && buffer.glyphs[0].glyph == 6 && budget.work >= 65535, "the budget of a call of 64 bytes: %v, the glyph %d, %d units", problem, buffer.glyphs[0].glyph, budget.work)
	// The cap: no text gives a call more than LAYOUT_WORK_CAP.
	testing.expect_value(t, layout_budget_of_text(max(int)).limit, LAYOUT_WORK_CAP)
	testing.expect_value(t, layout_budget_of_text(-1).limit, LAYOUT_WORK_FLOOR)
	testing.expect_value(t, layout_budget_of_text(0).limit, LAYOUT_WORK_FLOOR)
}

// A stage of 32 glyphs, each with a rule of 200 records: 32 times 201
// applications pass ENGINE_STEP_LIMIT, so the stage stops before the last
// glyphs: the first glyph took the lookup, the last did not.
@(test)
a_stage_stops_at_its_steps :: proc(t: ^testing.T) {
	scripts := []Script_Of{{DFLT, true, {0}}}
	features := []Feature_Of{{TEST, {0}}}
	gsub := table(scripts, features, {lookup(6, 0, chain_rule(200, 200)), lookup(1, 0, single(5, 6))})
	font := font_of(gsub, nil, nil)
	glyphs: [ENGINE_GLYPH_LIMIT]int
	for &glyph in glyphs {
		glyph = 5
	}
	buffer, problem, _ := stage_of(&font, .Substitution, glyphs[:], 1 << 24)
	testing.expect_value(t, problem, Font_Problem.None)
	testing.expectf(t, buffer.glyphs[0].glyph == 6 && buffer.glyphs[ENGINE_GLYPH_LIMIT - 1].glyph == 5, "the first glyph %d, the last %d", buffer.glyphs[0].glyph, buffer.glyphs[ENGINE_GLYPH_LIMIT - 1].glyph)
}
