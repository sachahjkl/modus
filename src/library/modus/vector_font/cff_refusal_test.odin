#+build !freestanding
#+build !modus
package vector_font

import "core:testing"

// The refusals of the reader of CFF and CFF2 (cff.odin) on tables that the
// test builds: each bound at its edge and one past it, and each check names
// the problem that it expects.

// cff_index_bytes writes an INDEX of the items, with offsets of one byte.
@(private = "file")
cff_index_bytes :: proc(items: [][]u8, version: int) -> []u8 {
	bytes := make([dynamic]u8, context.temp_allocator)
	count := len(items)
	if version == 2 {
		append(&bytes, u8(count >> 24), u8(count >> 16), u8(count >> 8), u8(count))
	} else {
		append(&bytes, u8(count >> 8), u8(count))
	}
	if count == 0 {
		return bytes[:]
	}
	append(&bytes, 1)
	offset := 1
	append(&bytes, u8(offset))
	for item in items {
		offset += len(item)
		append(&bytes, u8(offset))
	}
	for item in items {
		append(&bytes, ..item)
	}
	return bytes[:]
}

// A font whose CFF table is the bytes given, for a run of a charstring.
@(private = "file")
cff_test_font :: proc(table: []u8, version: int) -> (font: Font_File) {
	font.bytes = table
	font.cff.table = {offset = 0, length = len(table)}
	font.cff.version = version
	font.glyph_count = 1
	font.cff.fd_select = -1
	font.cff.private_offset = -1
	font.cff.variation_store = -1
	return font
}

@(private = "file")
cff_test_run :: proc(font: ^Font_File, charstring: []u8) -> Font_Problem {
	points: [256]Outline_Point
	contours: [32]int
	outline := Outline{points = points[:], contour_ends = contours[:]}
	machine: Cff_Machine
	machine.font, machine.table, machine.outline = font, cff_table(font), &outline
	machine.contour_first = -1
	machine.width_done = font.cff.version == 2
	cff_run(&machine, charstring, 0)
	return machine.problem
}

// The depth of the subroutines: a chain of 10 calls runs, one of 11 is
// refused, and a subroutine that calls itself stops at the bound.
@(test)
cff_subroutines_nest_at_most_ten_deep :: proc(t: ^testing.T) {
	for chain in ([2]int{CFF_CALL_DEPTH, CFF_CALL_DEPTH + 1}) {
		subrs := make([][]u8, chain, context.temp_allocator)
		for index in 0 ..< chain {
			// Each subroutine in memory of its own: the number of the next,
			// less the bias of 107, then callgsubr; the last returns.
			code := make([]u8, 2, context.temp_allocator)
			code[0], code[1] = u8(index + 1 - 107 + 139), 29
			subrs[index] = index + 1 < chain ? code : code[1:]
			if index + 1 == chain {
				code[1] = 11
			}
		}
		table := cff_index_bytes(subrs, 1)
		font := cff_test_font(table, 1)
		font.cff.global_subrs, _, _ = cff_index_read(table, 0, 1)
		problem := cff_test_run(&font, []u8{u8(0 - 107 + 139), 29})
		testing.expectf(t, problem == (chain > CFF_CALL_DEPTH ? Font_Problem.Composite_Too_Deep : Font_Problem.None), "a chain of %d calls: %v", chain, problem)
	}
	itself := [1][]u8{{u8(0 - 107 + 139), 29}}
	table := cff_index_bytes(itself[:], 1)
	font := cff_test_font(table, 1)
	font.cff.global_subrs, _, _ = cff_index_read(table, 0, 1)
	testing.expect_value(t, cff_test_run(&font, []u8{u8(0 - 107 + 139), 29}), Font_Problem.Composite_Too_Deep)
}

// The steps of one glyph: a charstring of more than CFF_STEP_LIMIT
// operators and operands is refused.
@(test)
cff_a_charstring_runs_a_bounded_count_of_steps :: proc(t: ^testing.T) {
	font := cff_test_font(nil, 1)
	long := make([dynamic]u8, context.temp_allocator)
	for _ in 0 ..< CFF_STEP_LIMIT / 3 + 2 {
		append(&long, 139, 139, 1) // 0 0 hstem
	}
	testing.expect_value(t, cff_test_run(&font, long[:]), Font_Problem.Composite_Too_Deep)
	short := long[:3 * 100]
	testing.expect_value(t, cff_test_run(&font, short), Font_Problem.None)
}

// The operand stack: 513 operands, the limit of CFF2, are taken; 514 are
// refused. A blend that names more operands than the stack holds is
// refused; one that names none is taken.
@(test)
cff_the_operand_stack_and_the_blend :: proc(t: ^testing.T) {
	font := cff_test_font(nil, 2)
	for count in ([2]int{CFF_STACK_LIMIT, CFF_STACK_LIMIT + 1}) {
		operands := make([]u8, count, context.temp_allocator)
		for &byte in operands {
			byte = 139
		}
		problem := cff_test_run(&font, operands)
		testing.expectf(t, problem == (count > CFF_STACK_LIMIT ? Font_Problem.Unknown_Format : Font_Problem.None), "%d operands: %v", count, problem)
	}
	testing.expect_value(t, cff_test_run(&font, []u8{139 + 5, 16}), Font_Problem.Unknown_Format)
	testing.expect_value(t, cff_test_run(&font, []u8{139 + 1, 139 + 1, 16}), Font_Problem.None)
	testing.expect_value(t, cff_test_run(&font, []u8{139 - 1, 16}), Font_Problem.Unknown_Format)
}

// An INDEX: an offset size of 0 or 5 is refused; offsets that go down give
// no item; a count past the table is refused.
@(test)
cff_an_index_refuses_its_bad_forms :: proc(t: ^testing.T) {
	for size in ([2]u8{0, 5}) {
		table := []u8{0, 1, size, 1, 2, 9}
		_, _, problem := cff_index_read(table, 0, 1)
		testing.expectf(t, problem == .Unknown_Format, "an offset size of %d: %v", size, problem)
	}
	down := []u8{0, 2, 1, 1, 5, 3, 7, 7, 7, 7}
	index, _, problem := cff_index_read(down, 0, 1)
	testing.expect_value(t, problem, Font_Problem.None)
	_, read := cff_item(down, &index, 1)
	testing.expect(t, !read, "an item whose end is before its start is refused")
	_, read = cff_item(down, &index, 0)
	testing.expect(t, read)
	_, read = cff_item(down, &index, 2)
	testing.expect(t, !read, "an item past the count is refused")
	_, _, problem = cff_index_read([]u8{0xFF, 0xFF, 1}, 0, 1)
	testing.expect(t, problem != .None)
}

// FDSelect that names a dictionary past FDArray is refused, in format 0
// and in format 3.
@(test)
cff_fd_select_past_the_font_dictionaries :: proc(t: ^testing.T) {
	format_0 := []u8{0, 1, 5}
	font := cff_test_font(format_0, 1)
	font.cff.fd_select = 0
	font.cff.font_dict_count = 2
	_, problem := cff_font_dict_of(&font, format_0, 0)
	testing.expect_value(t, problem, Font_Problem.None)
	_, problem = cff_font_dict_of(&font, format_0, 1)
	testing.expect_value(t, problem, Font_Problem.Unknown_Format)
	_, problem = cff_font_dict_of(&font, format_0, 9)
	testing.expect_value(t, problem, Font_Problem.Too_Short)
	// Format 3: one range from glyph 0 with the dictionary 7, then the end.
	format_3 := []u8{3, 0, 1, 0, 0, 7, 0, 2}
	font.bytes = format_3
	_, problem = cff_font_dict_of(&font, format_3, 1)
	testing.expect_value(t, problem, Font_Problem.Unknown_Format)
}

// cff2_table writes a table CFF2 with one charstring, a FDArray of a count
// of empty dictionaries, and a variation store of a count of item
// variation data.
@(private = "file")
cff2_table :: proc(dictionaries, variation_data: int) -> []u8 {
	offset_operand :: proc(bytes: ^[dynamic]u8, value: int) {
		append(bytes, 29, u8(value >> 24), u8(value >> 16), u8(value >> 8), u8(value))
	}
	top_length := 5 + 1 + 5 + 2 + 5 + 1
	header := 5
	global_at := header + top_length
	global := cff_index_bytes(nil, 2)
	char_strings_at := global_at + len(global)
	char_strings := cff_index_bytes([][]u8{{139}}, 2)
	fd_array_at := char_strings_at + len(char_strings)
	empty := make([][]u8, dictionaries, context.temp_allocator)
	fd_array := make([dynamic]u8, context.temp_allocator)
	append(&fd_array, u8(dictionaries >> 24), u8(dictionaries >> 16), u8(dictionaries >> 8), u8(dictionaries), 1)
	for _ in 0 ..= dictionaries {
		append(&fd_array, 1)
	}
	_ = empty
	store_at := fd_array_at + len(fd_array)
	store := make([dynamic]u8, context.temp_allocator)
	// The length, then the item variation store: format 1, the offset of
	// the region list, the count of item variation data and their offsets.
	data_at := 2 + 8 + 4 * variation_data
	append(&store, 0, 0, 0, 1, 0, 0, 0, 0, u8(variation_data >> 8), u8(variation_data))
	for _ in 0 ..< variation_data {
		offset := data_at - 2
		append(&store, u8(offset >> 24), u8(offset >> 16), u8(offset >> 8), u8(offset))
	}
	append(&store, 0, 0, 0, 0, 0, 1, 0, 0)
	bytes := make([dynamic]u8, context.temp_allocator)
	append(&bytes, 2, 0, u8(header), u8(top_length >> 8), u8(top_length))
	offset_operand(&bytes, char_strings_at)
	append(&bytes, 17)
	offset_operand(&bytes, fd_array_at)
	append(&bytes, 12, 36)
	offset_operand(&bytes, store_at)
	append(&bytes, 24)
	append(&bytes, ..global)
	append(&bytes, ..char_strings)
	append(&bytes, ..fd_array[:])
	append(&bytes, ..store[:])
	return bytes[:]
}

// The bounds of the open of a table CFF2: 64 font dictionaries and 64 item
// variation data are taken, 65 of either are refused.
@(test)
cff2_dictionaries_and_variation_data_are_bounded :: proc(t: ^testing.T) {
	Case :: struct {
		dictionaries, variation_data: int,
		problem:                      Font_Problem,
	}
	cases := [?]Case {
		{CFF_FONT_DICT_LIMIT, 1, .None},
		{CFF_FONT_DICT_LIMIT + 1, 1, .Unknown_Format},
		{1, CFF_REGION_DATA_LIMIT, .None},
		{1, CFF_REGION_DATA_LIMIT + 1, .Unknown_Format},
	}
	for each in cases {
		table := cff2_table(each.dictionaries, each.variation_data)
		font := cff_test_font(table, 2)
		problem := cff_open(&font)
		testing.expectf(t, problem == each.problem, "%d dictionaries, %d variation data: %v", each.dictionaries, each.variation_data, problem)
	}
}
