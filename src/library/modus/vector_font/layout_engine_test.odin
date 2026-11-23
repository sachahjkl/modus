#+build !freestanding
package vector_font

import "core:testing"

// The engine of the lookups (layout_engine.odin) on tables GSUB that the
// test builds: each lookup type and format that it reads, then the bounds
// that a hostile table meets: a cycle of contextual lookups, the steps,
// the nesting, 64 and 65 lookups of a feature, sequences of 0, 8 and 9
// glyphs, a class at the count of the class sets, a buffer that would pass
// its limit.

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

// A coverage of format 1.
@(private = "file")
coverage_bytes :: proc(glyphs: []int) -> []u8 {
	bytes := make(Bytes, context.temp_allocator)
	put16(&bytes, 1)
	put16(&bytes, len(glyphs))
	for glyph in glyphs {
		put16(&bytes, glyph)
	}
	return bytes[:]
}

// joined writes a head of words, then parts after it; each word of
// offset_places is the offset of the part of its number (from the start).
@(private = "file")
Part :: struct {
	at:   int, // The place of its offset word in the head.
	data: []u8,
}

@(private = "file")
with_parts :: proc(head: []u8, parts: []Part, wide := false) -> []u8 {
	bytes := make(Bytes, context.temp_allocator)
	append(&bytes, ..head)
	for part in parts {
		offset := len(bytes)
		if wide {
			bytes[part.at], bytes[part.at + 1], bytes[part.at + 2], bytes[part.at + 3] = u8(offset >> 24), u8(offset >> 16), u8(offset >> 8), u8(offset)
		} else {
			set16(&bytes, part.at, offset)
		}
		append(&bytes, ..part.data)
	}
	return bytes[:]
}

@(private = "file")
lookup_bytes :: proc(type, flag: int, subtables: [][]u8) -> []u8 {
	head := make(Bytes, context.temp_allocator)
	put16(&head, type)
	put16(&head, flag)
	put16(&head, len(subtables))
	parts := make([dynamic]Part, context.temp_allocator)
	for subtable in subtables {
		append(&parts, Part{len(head), subtable})
		put16(&head, 0)
	}
	return with_parts(head[:], parts[:])
}

// gsub_bytes writes a table GSUB: the script DFLT, one feature "test" with
// the lookups that feature_lookups names, and the lookups.
@(private = "file")
gsub_bytes :: proc(lookups: [][]u8, feature_lookups: []int) -> []u8 {
	script_list := make(Bytes, context.temp_allocator)
	put16(&script_list, 1)
	append(&script_list, 'D', 'F', 'L', 'T')
	put16(&script_list, 8) // The script, after the list.
	put16(&script_list, 4) // Its default language system, after the script.
	put16(&script_list, 0)
	put16(&script_list, 0) // lookupOrder
	put16(&script_list, 0xFFFF) // requiredFeatureIndex
	put16(&script_list, 1)
	put16(&script_list, 0)
	feature_list := make(Bytes, context.temp_allocator)
	put16(&feature_list, 1)
	append(&feature_list, 't', 'e', 's', 't')
	put16(&feature_list, 8)
	put16(&feature_list, 0)
	put16(&feature_list, len(feature_lookups))
	for index in feature_lookups {
		put16(&feature_list, index)
	}
	lookup_head := make(Bytes, context.temp_allocator)
	put16(&lookup_head, len(lookups))
	parts := make([dynamic]Part, context.temp_allocator)
	for lookup in lookups {
		append(&parts, Part{len(lookup_head), lookup})
		put16(&lookup_head, 0)
	}
	lookup_list := with_parts(lookup_head[:], parts[:])
	head := make(Bytes, context.temp_allocator)
	put16(&head, 1)
	put16(&head, 0)
	put16(&head, 0)
	put16(&head, 0)
	put16(&head, 0)
	return with_parts(head[:], {{4, script_list[:]}, {6, feature_list[:]}, {8, lookup_list}})
}

@(private = "file")
TEST :: Feature_Tag{'t', 'e', 's', 't'}

// engine_run shapes glyphs with a table GSUB of the test.
@(private = "file")
engine_run :: proc(gsub: []u8, glyphs: []int) -> (buffer: Engine_Buffer, problem: Font_Problem) {
	font: Font_File
	font.bytes = gsub
	font.gsub = {offset = 0, length = len(gsub)}
	font.glyph_count = 100
	buffer.count = len(glyphs)
	for glyph, index in glyphs {
		buffer.glyphs[index] = {glyph = u16(glyph), place = u8(index), mask = 1}
	}
	engine_buffer_prepare(&font, &buffer)
	features := [1]Engine_Feature{{TEST, 1}}
	problem = engine_stage(&font, .Substitution, {'D', 'F', 'L', 'T'}, features[:], &buffer)
	return buffer, problem
}

@(private = "file")
glyphs_of :: proc(buffer: ^Engine_Buffer) -> []int {
	out := make([]int, buffer.count, context.temp_allocator)
	for glyph, index in buffer.glyphs[:buffer.count] {
		out[index] = int(glyph.glyph)
	}
	return out
}

@(private = "file")
same :: proc(a, b: []int) -> bool {
	if len(a) != len(b) {
		return false
	}
	for value, index in a {
		if b[index] != value {
			return false
		}
	}
	return true
}

// single (format 2): the substitute of each covered glyph.
@(private = "file")
single_bytes :: proc(from, to: []int) -> []u8 {
	head := make(Bytes, context.temp_allocator)
	put16(&head, 2)
	put16(&head, 0)
	put16(&head, len(to))
	for glyph in to {
		put16(&head, glyph)
	}
	return with_parts(head[:], {{2, coverage_bytes(from)}})
}

// multiple (format 1): one sequence for one glyph.
@(private = "file")
multiple_bytes :: proc(from: int, sequence: []int) -> []u8 {
	sequence_bytes := make(Bytes, context.temp_allocator)
	put16(&sequence_bytes, len(sequence))
	for glyph in sequence {
		put16(&sequence_bytes, glyph)
	}
	head := make(Bytes, context.temp_allocator)
	put16(&head, 1)
	put16(&head, 0)
	put16(&head, 1)
	put16(&head, 0)
	return with_parts(head[:], {{2, coverage_bytes({from})}, {6, sequence_bytes[:]}})
}

// A contextual rule of format 3: the coverages of its input, and its
// records (the place in the input, the lookup).
@(private = "file")
context_format_3 :: proc(inputs: []int, records: [][2]int) -> []u8 {
	head := make(Bytes, context.temp_allocator)
	put16(&head, 3)
	put16(&head, len(inputs))
	put16(&head, len(records))
	parts := make([dynamic]Part, context.temp_allocator)
	for input in inputs {
		append(&parts, Part{len(head), coverage_bytes({input})})
		put16(&head, 0)
	}
	for record in records {
		put16(&head, record[0])
		put16(&head, record[1])
	}
	return with_parts(head[:], parts[:])
}

// A chaining contextual rule of format 3.
@(private = "file")
chain_format_3 :: proc(backtrack, inputs, lookahead: []int, records: [][2]int) -> []u8 {
	head := make(Bytes, context.temp_allocator)
	put16(&head, 3)
	parts := make([dynamic]Part, context.temp_allocator)
	for group in ([3][]int{backtrack, inputs, lookahead}) {
		put16(&head, len(group))
		for glyph in group {
			append(&parts, Part{len(head), coverage_bytes({glyph})})
			put16(&head, 0)
		}
	}
	put16(&head, len(records))
	for record in records {
		put16(&head, record[0])
		put16(&head, record[1])
	}
	return with_parts(head[:], parts[:])
}

// Each type and format: single, multiple, ligature of three glyphs over a
// skipped mark, contextual 1, 2 and 3, chaining 1, 2 and 3 with a
// backtrack and a lookahead, and reverse chaining.
@(test)
the_engine_applies_each_lookup :: proc(t: ^testing.T) {
	to_9 := lookup_bytes(1, 0, {single_bytes({5}, {9})})
	// Single.
	buffer, problem := engine_run(gsub_bytes({to_9}, {0}), {4, 5, 6})
	testing.expect(t, problem == .None && same(glyphs_of(&buffer), {4, 9, 6}))
	// Multiple: 5 becomes 7 8, and the places stay those of 5.
	buffer, _ = engine_run(gsub_bytes({lookup_bytes(2, 0, {multiple_bytes(5, {7, 8})})}, {0}), {4, 5, 6})
	testing.expect(t, same(glyphs_of(&buffer), {4, 7, 8, 6}) && buffer.glyphs[2].place == 1)
	// Ligature: 1 2 3 becomes 50.
	ligature := make(Bytes, context.temp_allocator)
	put16(&ligature, 50)
	put16(&ligature, 3)
	put16(&ligature, 2)
	put16(&ligature, 3)
	set_head := make(Bytes, context.temp_allocator)
	put16(&set_head, 1)
	put16(&set_head, 0)
	set := with_parts(set_head[:], {{2, ligature[:]}})
	ligature_head := make(Bytes, context.temp_allocator)
	put16(&ligature_head, 1)
	put16(&ligature_head, 0)
	put16(&ligature_head, 1)
	put16(&ligature_head, 0)
	ligature_subtable := with_parts(ligature_head[:], {{2, coverage_bytes({1})}, {6, set}})
	buffer, _ = engine_run(gsub_bytes({lookup_bytes(4, 0, {ligature_subtable})}, {0}), {1, 2, 3, 4})
	testing.expect(t, same(glyphs_of(&buffer), {50, 4}))
	// Contextual, format 3: in 4 5, the 5 becomes 9 by the lookup 1.
	context_lookup := lookup_bytes(5, 0, {context_format_3({4, 5}, {{1, 1}})})
	buffer, _ = engine_run(gsub_bytes({context_lookup, to_9}, {0}), {4, 5, 5})
	testing.expect(t, same(glyphs_of(&buffer), {4, 9, 5}), "contextual 3")
	// Chaining, format 3: 5 after 4 and before 6.
	chain_lookup := lookup_bytes(6, 0, {chain_format_3({4}, {5}, {6}, {{0, 1}})})
	buffer, _ = engine_run(gsub_bytes({chain_lookup, to_9}, {0}), {4, 5, 6, 5, 7})
	testing.expect(t, same(glyphs_of(&buffer), {4, 9, 6, 5, 7}), "chaining 3")
	// Chaining, format 1: glyphs.
	rule := make(Bytes, context.temp_allocator)
	put16(&rule, 1)
	put16(&rule, 4) // backtrack
	put16(&rule, 1) // input: 5 alone
	put16(&rule, 1)
	put16(&rule, 6) // lookahead
	put16(&rule, 1)
	put16(&rule, 0)
	put16(&rule, 1)
	rule_set_head := make(Bytes, context.temp_allocator)
	put16(&rule_set_head, 1)
	put16(&rule_set_head, 0)
	rule_set := with_parts(rule_set_head[:], {{2, rule[:]}})
	chain_1_head := make(Bytes, context.temp_allocator)
	put16(&chain_1_head, 1)
	put16(&chain_1_head, 0)
	put16(&chain_1_head, 1)
	put16(&chain_1_head, 0)
	chain_1 := with_parts(chain_1_head[:], {{2, coverage_bytes({5})}, {6, rule_set}})
	buffer, _ = engine_run(gsub_bytes({lookup_bytes(6, 0, {chain_1}), to_9}, {0}), {4, 5, 6, 5})
	testing.expect(t, same(glyphs_of(&buffer), {4, 9, 6, 5}), "chaining 1")
	// Contextual, format 2: classes; the class of 5 is 1, of 4 is 2.
	classes := make(Bytes, context.temp_allocator)
	put16(&classes, 1)
	put16(&classes, 4)
	put16(&classes, 2)
	put16(&classes, 2)
	put16(&classes, 1)
	class_rule := make(Bytes, context.temp_allocator)
	put16(&class_rule, 2) // glyphCount
	put16(&class_rule, 1)
	put16(&class_rule, 1) // the second glyph: class 1
	put16(&class_rule, 1)
	put16(&class_rule, 1)
	class_set_head := make(Bytes, context.temp_allocator)
	put16(&class_set_head, 1)
	put16(&class_set_head, 0)
	class_set := with_parts(class_set_head[:], {{2, class_rule[:]}})
	context_2_head := make(Bytes, context.temp_allocator)
	put16(&context_2_head, 2)
	put16(&context_2_head, 0)
	put16(&context_2_head, 0)
	put16(&context_2_head, 3) // class sets 0, 1, 2
	put16(&context_2_head, 0)
	put16(&context_2_head, 0)
	put16(&context_2_head, 0)
	context_2 := with_parts(context_2_head[:], {{2, coverage_bytes({4})}, {4, classes[:]}, {12, class_set}})
	buffer, _ = engine_run(gsub_bytes({lookup_bytes(5, 0, {context_2}), to_9}, {0}), {4, 5})
	testing.expect(t, same(glyphs_of(&buffer), {4, 9}), "contextual 2")
	// The class of the first glyph at the count of the class sets: no set,
	// and no read past them.
	short_head := make(Bytes, context.temp_allocator)
	put16(&short_head, 2)
	put16(&short_head, 0)
	put16(&short_head, 0)
	put16(&short_head, 2) // class sets 0 and 1: the class 2 of glyph 4 is at the count
	put16(&short_head, 0)
	put16(&short_head, 0)
	short := with_parts(short_head[:], {{2, coverage_bytes({4})}, {4, classes[:]}})
	buffer, problem = engine_run(gsub_bytes({lookup_bytes(5, 0, {short}), to_9}, {0}), {4, 5})
	testing.expect(t, problem == .None && same(glyphs_of(&buffer), {4, 5}), "a class at the count of the sets")
	// Reverse chaining: 5 before 6 becomes 9, from the end.
	reverse_head := make(Bytes, context.temp_allocator)
	put16(&reverse_head, 1)
	put16(&reverse_head, 0)
	put16(&reverse_head, 0) // no backtrack
	put16(&reverse_head, 1)
	put16(&reverse_head, 0) // lookahead coverage
	put16(&reverse_head, 1)
	put16(&reverse_head, 9)
	reverse := with_parts(reverse_head[:], {{2, coverage_bytes({5})}, {8, coverage_bytes({6})}})
	buffer, _ = engine_run(gsub_bytes({lookup_bytes(8, 0, {reverse})}, {0}), {5, 6, 5})
	testing.expect(t, same(glyphs_of(&buffer), {9, 6, 5}), "reverse chaining")
}

// The bounds: a contextual lookup that calls itself, and two that call
// each other, end at the nesting bound; a sequence of 0 glyphs and of 9 is
// refused, of 8 is taken; a sequence that would pass 32 glyphs is not
// made; 65 lookups of a feature keep 64.
@(test)
the_engine_meets_its_bounds :: proc(t: ^testing.T) {
	itself := lookup_bytes(5, 0, {context_format_3({5}, {{0, 0}})})
	buffer, problem := engine_run(gsub_bytes({itself}, {0}), {5, 5, 5})
	testing.expect(t, problem == .None && same(glyphs_of(&buffer), {5, 5, 5}))
	first := lookup_bytes(6, 0, {chain_format_3({}, {5}, {}, {{0, 1}})})
	second := lookup_bytes(5, 0, {context_format_3({5}, {{0, 0}})})
	buffer, problem = engine_run(gsub_bytes({first, second}, {0, 1}), {5, 5})
	testing.expect(t, problem == .None && buffer.count == 2)
	for length in ([3]int{0, SEQUENCE_LIMIT, SEQUENCE_LIMIT + 1}) {
		sequence := make([]int, length, context.temp_allocator)
		for &glyph, index in sequence {
			glyph = 10 + index
		}
		buffer, _ = engine_run(gsub_bytes({lookup_bytes(2, 0, {multiple_bytes(5, sequence)})}, {0}), {5})
		taken := length >= 1 && length <= SEQUENCE_LIMIT
		testing.expectf(t, (buffer.count == length) == taken && (taken || buffer.glyphs[0].glyph == 5), "a sequence of %d glyphs: %v", length, glyphs_of(&buffer))
	}
	// 30 glyphs, and a sequence of 4 for one of them: 33 would pass 32.
	glyphs := make([]int, 30, context.temp_allocator)
	for &glyph in glyphs {
		glyph = 4
	}
	glyphs[0] = 5
	buffer, _ = engine_run(gsub_bytes({lookup_bytes(2, 0, {multiple_bytes(5, {7, 7, 7, 7})})}, {0}), glyphs)
	testing.expect_value(t, buffer.count, 30)
	// 65 lookups of one feature, each single 5 to 9: the walk keeps 64.
	many := make([][]u8, SUBSTITUTION_LOOKUP_LIMIT + 1, context.temp_allocator)
	names := make([]int, SUBSTITUTION_LOOKUP_LIMIT + 1, context.temp_allocator)
	for index in 0 ..< len(many) {
		many[index] = lookup_bytes(1, 0, {single_bytes({5}, {9})})
		names[index] = index
	}
	table := gsub_bytes(many, names)
	font: Font_File
	font.bytes = table
	font.gsub = {offset = 0, length = len(table)}
	font.glyph_count = 100
	lookups: Layout_Lookups
	testing.expect_value(t, layout_lookups(&font, font.gsub, {'D', 'F', 'L', 'T'}, {'D', 'F', 'L', 'T'}, TEST, &lookups), Font_Problem.None)
	testing.expect_value(t, lookups.count, SUBSTITUTION_LOOKUP_LIMIT)
	// A feature that names one lookup 64 times walks it once.
	repeated := make([]int, SUBSTITUTION_LOOKUP_LIMIT, context.temp_allocator)
	table = gsub_bytes(many[:1], repeated)
	font.bytes = table
	font.gsub = {offset = 0, length = len(table)}
	testing.expect_value(t, layout_lookups(&font, font.gsub, {'D', 'F', 'L', 'T'}, {'D', 'F', 'L', 'T'}, TEST, &lookups), Font_Problem.None)
	testing.expect_value(t, lookups.count, 1)
}
