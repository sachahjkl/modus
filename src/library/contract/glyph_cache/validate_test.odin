#+build !freestanding
package glyph_cache

import "core:slice"
import "core:testing"

// The layout of the small caches of these cases: one size, the glyphs of
// one position, the advances, the pairs of a proportional cache, then the
// words of one glyph with ink.
@(private = "file")
GLYPHS_PLACE :: HEADER_SIZE + SIZE_ENTRY_SIZE
@(private = "file")
ADVANCES_PLACE :: GLYPHS_PLACE + CHARACTER_COUNT * GLYPH_ENTRY_SIZE
@(private = "file")
PAIRS_PLACE :: ADVANCES_PLACE + CHARACTER_COUNT * ADVANCE_SIZE
@(private = "file")
PAIR_COUNT :: 2 // The pairs of the proportional cache.
@(private = "file")
MONOSPACE_TABLES_END :: PAIRS_PLACE
@(private = "file")
PROPORTIONAL_TABLES_END :: PAIRS_PLACE + PAIR_COUNT * PAIR_ENTRY_SIZE
@(private = "file")
MONOSPACE_WORD_PLACE :: (MONOSPACE_TABLES_END + 63) / 64 * 64
@(private = "file")
PROPORTIONAL_WORD_PLACE :: (PROPORTIONAL_TABLES_END + 63) / 64 * 64
@(private = "file")
WORD_COUNT :: 4 // The words of the one glyph with ink: two rows of two words.
@(private = "file")
INK_ROWS :: 2
@(private = "file")
INK_WIDTH :: 2
#assert(INK_ROWS * INK_WIDTH == WORD_COUNT)
@(private = "file")
FONT_NAME_SIZE :: size_of(Header{}.font_name) // The bytes of the name: one byte each.
@(private = "file")
CELL_WIDTH :: 8 // The cell of scale 1.
@(private = "file")
CELL_HEIGHT :: 16

// A cache file in memory aligned on 8, as validate needs it.
@(private = "file")
Test_File :: struct {
	words: [(max(MONOSPACE_WORD_PLACE, PROPORTIONAL_WORD_PLACE) + WORD_COUNT * 4 + 7) / 8]u64,
	size:  int, // The bytes of the file.
}

@(private = "file")
bytes_of :: proc(file: ^Test_File) -> []u8 {
	return ([^]u8)(&file.words)[:file.size]
}

@(private = "file")
header_of :: proc(file: ^Test_File) -> ^Header {
	return (^Header)(&file.words)
}

@(private = "file")
size_entry_of :: proc(file: ^Test_File) -> ^Size_Entry {
	return (^Size_Entry)(&([^]u8)(&file.words)[HEADER_SIZE])
}

@(private = "file")
glyph_entry_of :: proc(file: ^Test_File, index: int) -> ^Glyph_Entry {
	return (^Glyph_Entry)(&([^]u8)(&file.words)[GLYPHS_PLACE + index * GLYPH_ENTRY_SIZE])
}

@(private = "file")
advance_of :: proc(file: ^Test_File, index: int) -> ^i32 {
	return (^i32)(&([^]u8)(&file.words)[ADVANCES_PLACE + index * ADVANCE_SIZE])
}

@(private = "file")
pair_of :: proc(file: ^Test_File, index: int) -> ^Pair_Entry {
	return (^Pair_Entry)(&([^]u8)(&file.words)[PAIRS_PLACE + index * PAIR_ENTRY_SIZE])
}

// cut gives the file a new size, in the file and in its header.
@(private = "file")
cut :: proc(file: ^Test_File, size: int) {
	file.size = size
	header_of(file).file_size = u64(size)
}

// valid_cache writes a valid cache of one size: a monospace one, or a
// proportional one with two pairs. The glyph of the first character has
// ink: two rows of two words, which are all the words.
@(private = "file")
valid_cache :: proc(file: ^Test_File, proportional: bool) {
	file^ = {}
	word_place := proportional ? PROPORTIONAL_WORD_PLACE : MONOSPACE_WORD_PLACE
	file.size = word_place + WORD_COUNT * 4
	header := header_of(file)
	header^ = {
		magic           = MAGIC,
		version         = VERSION,
		file_size       = u64(file.size),
		character_count = CHARACTER_COUNT,
		size_count      = 1,
		flags           = proportional ? u32(FLAG_PROPORTIONAL) : 0,
		word_offset     = u64(word_place),
		word_count      = WORD_COUNT,
		pair_count      = proportional ? u32(PAIR_COUNT) : 0,
	}
	// By index: the header is packed, and a slice of its field is not taken.
	name := "Test Font"
	for index in 0 ..< len(name) {
		header.font_name[index] = name[index]
	}
	size_entry_of(file)^ = {cell_width = CELL_WIDTH, cell_height = CELL_HEIGHT, baseline = 12, position_count = 1, first_glyph = 0}
	glyph_entry_of(file, 0)^ = {first_row = 4, row_count = INK_ROWS, word_offset = 0, left = 0, width = INK_WIDTH}
	for index in 0 ..< CHARACTER_COUNT {
		advance_of(file, index)^ = CELL_WIDTH * SUBPIXEL
	}
	if proportional {
		pair_of(file, 0)^ = {left = 0, right = 1, adjustment = -SUBPIXEL}
		pair_of(file, 1)^ = {left = 0, right = 2, adjustment = SUBPIXEL}
	}
}

@(private = "file")
Damage :: struct {
	name:         string,
	proportional: bool, // The damage is made to the proportional cache.
	damage:       proc(file: ^Test_File),
	kind:         Problem_Kind,
	index:        u32,
	value:        u64,
}

// Each refusal of validate, one field damaged in a valid cache for each:
// the kind, the index and the value of the problem, no cache, and no byte
// of the file changed. The edges come first: one past each limit, 0, and
// the largest value of the field. Proportional and Not_Mapped are not
// refusals of validate: the reader that needs a font of cells and the
// reader of a fixed address give them.
@(test)
validate_refuses_each_damaged_field :: proc(t: ^testing.T) {
	damages := [?]Damage {
		// The file is shorter than its tables.
		{"a file cut to its sizes", false, proc(file: ^Test_File) {cut(file, HEADER_SIZE + SIZE_ENTRY_SIZE - 1)}, .Too_Short, 0, HEADER_SIZE + SIZE_ENTRY_SIZE - 1},
		{"a file cut inside its advances", false, proc(file: ^Test_File) {cut(file, MONOSPACE_TABLES_END - 1)}, .Too_Short, 0, MONOSPACE_TABLES_END - 1},
		{"a file cut inside its pairs", true, proc(file: ^Test_File) {cut(file, PROPORTIONAL_TABLES_END - 1)}, .Too_Short, 0, PROPORTIONAL_TABLES_END - 1},
		// The magic.
		{"a magic of 0", false, proc(file: ^Test_File) {header_of(file).magic = 0}, .Bad_Magic, 0, 0},
		{"a magic one past", false, proc(file: ^Test_File) {header_of(file).magic = MAGIC + 1}, .Bad_Magic, 0, MAGIC + 1},
		{"the largest magic", false, proc(file: ^Test_File) {header_of(file).magic = max(u64)}, .Bad_Magic, 0, max(u64)},
		// The version.
		{"a version of 0", false, proc(file: ^Test_File) {header_of(file).version = 0}, .Bad_Version, 0, 0},
		{"the version before", false, proc(file: ^Test_File) {header_of(file).version = VERSION - 1}, .Bad_Version, 0, VERSION - 1},
		{"the next version", false, proc(file: ^Test_File) {header_of(file).version = VERSION + 1}, .Bad_Version, 0, VERSION + 1},
		{"the largest version", false, proc(file: ^Test_File) {header_of(file).version = max(u32)}, .Bad_Version, 0, u64(max(u32))},
		// The size of the file.
		{"a size of 0", false, proc(file: ^Test_File) {header_of(file).file_size = 0}, .Bad_Size, 0, 0},
		{"a size one short", false, proc(file: ^Test_File) {header_of(file).file_size = u64(file.size - 1)}, .Bad_Size, 0, MONOSPACE_WORD_PLACE + WORD_COUNT * 4 - 1},
		{"a size one past", false, proc(file: ^Test_File) {header_of(file).file_size = u64(file.size + 1)}, .Bad_Size, 0, MONOSPACE_WORD_PLACE + WORD_COUNT * 4 + 1},
		{"the largest size", false, proc(file: ^Test_File) {header_of(file).file_size = max(u64)}, .Bad_Size, 0, max(u64)},
		// The counts and the reserved fields.
		{"no character", false, proc(file: ^Test_File) {header_of(file).character_count = 0}, .Bad_Count, 0, 0},
		{"one character short", false, proc(file: ^Test_File) {header_of(file).character_count = CHARACTER_COUNT - 1}, .Bad_Count, 0, CHARACTER_COUNT - 1},
		{"one character past", false, proc(file: ^Test_File) {header_of(file).character_count = CHARACTER_COUNT + 1}, .Bad_Count, 0, CHARACTER_COUNT + 1},
		{"a first reserved field of 1", false, proc(file: ^Test_File) {header_of(file).reserved_first = 1}, .Bad_Count, 0, 1},
		{"a last reserved field of 1", false, proc(file: ^Test_File) {header_of(file).reserved = 1}, .Bad_Count, 0, 1},
		{"the largest last reserved field", false, proc(file: ^Test_File) {header_of(file).reserved = max(u32)}, .Bad_Count, 0, u64(max(u32))},
		{"no size", false, proc(file: ^Test_File) {header_of(file).size_count = 0}, .Bad_Count, 0, 0},
		{"one size past the limit", false, proc(file: ^Test_File) {header_of(file).size_count = SIZE_LIMIT + 1}, .Bad_Count, 0, SIZE_LIMIT + 1},
		{"the largest count of sizes", false, proc(file: ^Test_File) {header_of(file).size_count = max(u32)}, .Bad_Count, 0, u64(max(u32))},
		{"one pair past the limit", true, proc(file: ^Test_File) {header_of(file).pair_count = PAIR_LIMIT + 1}, .Bad_Count, 0, PAIR_LIMIT + 1},
		{"the largest count of pairs", true, proc(file: ^Test_File) {header_of(file).pair_count = max(u32)}, .Bad_Count, 0, u64(max(u32))},
		{"a pair in a monospace cache", false, proc(file: ^Test_File) {header_of(file).pair_count = 1}, .Bad_Count, 0, 1},
		{"no position", false, proc(file: ^Test_File) {size_entry_of(file).position_count = 0}, .Bad_Count, 0, 0},
		{"two positions in a monospace cache", false, proc(file: ^Test_File) {size_entry_of(file).position_count = 2}, .Bad_Count, 0, 2},
		{"one position past the limit", true, proc(file: ^Test_File) {size_entry_of(file).position_count = POSITION_LIMIT + 1}, .Bad_Count, 0, POSITION_LIMIT + 1},
		{"a first glyph one past", false, proc(file: ^Test_File) {size_entry_of(file).first_glyph = 1}, .Bad_Count, 0, 1},
		{"the largest first glyph", false, proc(file: ^Test_File) {size_entry_of(file).first_glyph = max(u32)}, .Bad_Count, 0, u64(max(u32))},
		{"a reserved field of a size of 1", false, proc(file: ^Test_File) {size_entry_of(file).reserved = 1}, .Bad_Count, 0, 1},
		// The cell.
		{"a cell one too wide", false, proc(file: ^Test_File) {size_entry_of(file).cell_width = CELL_WIDTH + 1}, .Bad_Cell, 0, CELL_WIDTH + 1},
		{"a cell of no width", false, proc(file: ^Test_File) {size_entry_of(file).cell_width = 0}, .Bad_Cell, 0, 0},
		{"a cell one too short", false, proc(file: ^Test_File) {size_entry_of(file).cell_height = CELL_HEIGHT - 1}, .Bad_Cell, 0, CELL_WIDTH},
		{"a baseline of 0", false, proc(file: ^Test_File) {size_entry_of(file).baseline = 0}, .Bad_Cell, 0, CELL_WIDTH},
		{"a baseline under the line", false, proc(file: ^Test_File) {size_entry_of(file).baseline = CELL_HEIGHT + 1}, .Bad_Cell, 0, CELL_WIDTH},
		// The words.
		{"words one line late", false, proc(file: ^Test_File) {header_of(file).word_offset += 64}, .Bad_Words, 0, MONOSPACE_WORD_PLACE + 64},
		{"words one line early", false, proc(file: ^Test_File) {header_of(file).word_offset -= 64}, .Bad_Words, 0, MONOSPACE_WORD_PLACE - 64},
		{"words not on a line", false, proc(file: ^Test_File) {header_of(file).word_offset += 4}, .Bad_Words, 0, MONOSPACE_WORD_PLACE + 4},
		{"one word past the file", false, proc(file: ^Test_File) {header_of(file).word_count += 1}, .Bad_Words, 0, MONOSPACE_WORD_PLACE},
		{"one word short of the file", false, proc(file: ^Test_File) {header_of(file).word_count -= 1}, .Bad_Words, 0, MONOSPACE_WORD_PLACE},
		{"a count of words whose bytes wrap", false, proc(file: ^Test_File) {header_of(file).word_count = max(u64) / 4 + 2}, .Bad_Words, 0, MONOSPACE_WORD_PLACE},
		{"a file that ends with its tables", false, proc(file: ^Test_File) {header_of(file).word_count = 0; cut(file, MONOSPACE_TABLES_END)}, .Bad_Words, 0, MONOSPACE_WORD_PLACE},
		// The glyphs.
		{"rows one past the line", false, proc(file: ^Test_File) {glyph_entry_of(file, 0).first_row = CELL_HEIGHT - INK_ROWS + 1}, .Bad_Glyph, 0, WORD_COUNT},
		{"the largest first row", false, proc(file: ^Test_File) {glyph_entry_of(file, 0).first_row = max(u16)}, .Bad_Glyph, 0, WORD_COUNT},
		{"words one past the words", false, proc(file: ^Test_File) {glyph_entry_of(file, 0).word_offset = 1}, .Bad_Glyph, 0, WORD_COUNT + 1},
		{"the largest place of words", false, proc(file: ^Test_File) {glyph_entry_of(file, 0).word_offset = max(u32)}, .Bad_Glyph, 0, u64(max(u32)) + WORD_COUNT},
		{"the largest rows and width", false, proc(file: ^Test_File) {glyph_entry_of(file, CHARACTER_COUNT - 1)^ = {row_count = max(u16), width = max(u16)}}, .Bad_Glyph, CHARACTER_COUNT - 1, u64(max(u16)) * u64(max(u16))},
		{"a monospace glyph one right of its cell", false, proc(file: ^Test_File) {glyph_entry_of(file, 1).left = 1}, .Bad_Glyph, 1, 0},
		{"a monospace glyph one left of its cell", false, proc(file: ^Test_File) {glyph_entry_of(file, 1).left = -1}, .Bad_Glyph, 1, 0},
		{"a monospace glyph one wider than its cell", false, proc(file: ^Test_File) {glyph_entry_of(file, 1).width = CELL_WIDTH + 1}, .Bad_Glyph, 1, 0},
		{"a glyph one wider than the limit", true, proc(file: ^Test_File) {glyph_entry_of(file, 1).width = GLYPH_WIDTH_LIMIT + 1}, .Bad_Glyph, 1, 0},
		{"a glyph one left of the limit", true, proc(file: ^Test_File) {glyph_entry_of(file, 1).left = -LEFT_LIMIT - 1}, .Bad_Glyph, 1, 0},
		{"a glyph one right of the limit", true, proc(file: ^Test_File) {glyph_entry_of(file, 1).left = GLYPH_WIDTH_LIMIT + 1}, .Bad_Glyph, 1, 0},
		{"the most negative left side", true, proc(file: ^Test_File) {glyph_entry_of(file, 1).left = min(i16)}, .Bad_Glyph, 1, 0},
		// The advances.
		{"a monospace advance one past its cell", false, proc(file: ^Test_File) {advance_of(file, 5)^ = CELL_WIDTH * SUBPIXEL + 1}, .Bad_Advance, 5, CELL_WIDTH * SUBPIXEL + 1},
		{"a monospace advance of 0", false, proc(file: ^Test_File) {advance_of(file, CHARACTER_COUNT - 1)^ = 0}, .Bad_Advance, CHARACTER_COUNT - 1, 0},
		{"a negative advance", true, proc(file: ^Test_File) {advance_of(file, CHARACTER_COUNT - 1)^ = -1}, .Bad_Advance, CHARACTER_COUNT - 1, max(u64)},
		{"an advance one past the limit", true, proc(file: ^Test_File) {advance_of(file, 0)^ = ADVANCE_LIMIT + 1}, .Bad_Advance, 0, ADVANCE_LIMIT + 1},
		{"the largest advance", true, proc(file: ^Test_File) {advance_of(file, 0)^ = max(i32)}, .Bad_Advance, 0, u64(max(i32))},
		// The pairs.
		{"a left character past the cache", true, proc(file: ^Test_File) {pair_of(file, 0).left = CHARACTER_COUNT}, .Bad_Pair, 0, CHARACTER_COUNT << 8 | 1},
		{"a right character past the cache", true, proc(file: ^Test_File) {pair_of(file, 1).right = CHARACTER_COUNT}, .Bad_Pair, 1, CHARACTER_COUNT},
		{"the largest characters", true, proc(file: ^Test_File) {pair_of(file, 1)^ = {left = max(u8), right = max(u8)}}, .Bad_Pair, 1, u64(max(u8)) << 8 | u64(max(u8))},
		{"a pair twice", true, proc(file: ^Test_File) {pair_of(file, 1)^ = pair_of(file, 0)^}, .Bad_Pair, 1, 1},
		{"pairs out of order", true, proc(file: ^Test_File) {pair_of(file, 1).right = 0}, .Bad_Pair, 1, 0},
		{"an adjustment one past the limit", true, proc(file: ^Test_File) {pair_of(file, 0).adjustment = ADVANCE_LIMIT + 1}, .Bad_Pair, 0, 1},
		{"an adjustment one past the negative limit", true, proc(file: ^Test_File) {pair_of(file, 1).adjustment = -ADVANCE_LIMIT - 1}, .Bad_Pair, 1, 2},
		{"the most negative adjustment", true, proc(file: ^Test_File) {pair_of(file, 1).adjustment = min(i32)}, .Bad_Pair, 1, 2},
		// The value is the field, not the key of the pair: the two differ.
		{"a reserved field of a pair of 7", true, proc(file: ^Test_File) {pair_of(file, 1).reserved = 7}, .Bad_Pair, 1, 7},
		{"the largest reserved field of a pair", true, proc(file: ^Test_File) {pair_of(file, 0).reserved = max(u16)}, .Bad_Pair, 0, u64(max(u16))},
		// The flags.
		{"a flag that no reader knows", false, proc(file: ^Test_File) {header_of(file).flags = FLAG_PROPORTIONAL << 1}, .Bad_Flags, 0, FLAG_PROPORTIONAL << 1},
		{"a flag past the filter", false, proc(file: ^Test_File) {header_of(file).flags = 1 << (FILTER_SHIFT + 8)}, .Bad_Flags, 0, 1 << (FILTER_SHIFT + 8)},
		{"the filter one past the last", false, proc(file: ^Test_File) {header_of(file).flags = FILTER_COUNT << FILTER_SHIFT}, .Bad_Flags, 0, FILTER_COUNT << FILTER_SHIFT},
		{"the largest filter", false, proc(file: ^Test_File) {header_of(file).flags = 0xFF << FILTER_SHIFT}, .Bad_Flags, 0, 0xFF << FILTER_SHIFT},
		{"every flag", false, proc(file: ^Test_File) {header_of(file).flags = max(u32)}, .Bad_Flags, 0, u64(max(u32))},
		// The name of the font.
		{"a control character first", false, proc(file: ^Test_File) {header_of(file).font_name[0] = 31}, .Bad_Name, 0, 31},
		{"a byte past the tilde", false, proc(file: ^Test_File) {header_of(file).font_name[1] = 127}, .Bad_Name, 1, 127},
		{"the largest byte", false, proc(file: ^Test_File) {header_of(file).font_name[2] = max(u8)}, .Bad_Name, 2, u64(max(u8))},
		{"a byte after the end", false, proc(file: ^Test_File) {header_of(file).font_name[FONT_NAME_SIZE - 1] = 'A'}, .Bad_Name, FONT_NAME_SIZE - 1, 'A'},
		{"a name with no end", false, proc(file: ^Test_File) {for index in 0 ..< FONT_NAME_SIZE {header_of(file).font_name[index] = 'A'}}, .Bad_Name, FONT_NAME_SIZE, 0},
	}
	for damage in damages {
		file: Test_File
		valid_cache(&file, damage.proportional)
		damage.damage(&file)
		before := slice.clone(file.words[:])
		cache, problem := validate(bytes_of(&file))
		testing.expectf(t, problem.kind == damage.kind, "%s: the kind %v, not %v", damage.name, problem.kind, damage.kind)
		testing.expectf(t, problem.index == damage.index, "%s: the index %v, not %v", damage.name, problem.index, damage.index)
		testing.expectf(t, problem.value == damage.value, "%s: the value %v, not %v", damage.name, problem.value, damage.value)
		testing.expectf(t, cache.header == nil && cache.words == nil, "%s: a refused file gives no cache", damage.name)
		testing.expectf(t, slice.equal(before, file.words[:]), "%s: validate writes no byte", damage.name)
		delete(before)
	}
}

// A file shorter than its header, of no byte, or not aligned on 8 is
// refused before a field is read.
@(test)
validate_refuses_a_file_shorter_than_its_header :: proc(t: ^testing.T) {
	file: Test_File
	valid_cache(&file, false)
	bytes := bytes_of(&file)
	_, empty := validate(bytes[:0])
	testing.expect_value(t, empty.kind, Problem_Kind.Too_Short)
	testing.expect_value(t, empty.value, 0)
	_, short := validate(bytes[:HEADER_SIZE - 1])
	testing.expect_value(t, short.kind, Problem_Kind.Too_Short)
	testing.expect_value(t, short.value, HEADER_SIZE - 1)
	_, nil_file := validate(nil)
	testing.expect_value(t, nil_file.kind, Problem_Kind.Too_Short)
	_, unaligned := validate(bytes[1:])
	testing.expect_value(t, unaligned.kind, Problem_Kind.Too_Short)
	testing.expect_value(t, unaligned.value, u64(len(bytes) - 1))
}

// validate_at refuses an address of 0, an address not on 8, and a size in
// the header under the header or over the span of the range, then gives
// the problem of validate.
@(test)
validate_at_refuses_each_bad_range :: proc(t: ^testing.T) {
	file: Test_File
	valid_cache(&file, false)
	address := uintptr(&file.words)
	span := u64(file.size)
	_, zero := validate_at(0, span)
	testing.expect_value(t, zero.kind, Problem_Kind.Too_Short)
	_, unaligned := validate_at(address + 4, span)
	testing.expect_value(t, unaligned.kind, Problem_Kind.Too_Short)
	_, over := validate_at(address, span - 1)
	testing.expect_value(t, over.kind, Problem_Kind.Bad_Size)
	testing.expect_value(t, over.value, span)
	testing.expect_value(t, over.limit, span - 1)
	_, no_span := validate_at(address, 0)
	testing.expect_value(t, no_span.kind, Problem_Kind.Bad_Size)
	header_of(&file).file_size = HEADER_SIZE - 1
	_, under := validate_at(address, span)
	testing.expect_value(t, under.kind, Problem_Kind.Bad_Size)
	testing.expect_value(t, under.value, HEADER_SIZE - 1)
	header_of(&file).file_size = 0
	_, none := validate_at(address, span)
	testing.expect_value(t, none.kind, Problem_Kind.Bad_Size)
	// A size that the span holds, of a file that validate refuses.
	valid_cache(&file, false)
	header_of(&file).magic = 0
	_, damaged := validate_at(address, span)
	testing.expect_value(t, damaged.kind, Problem_Kind.Bad_Magic)
	// The successful cases last: a span of the file, and the largest span.
	valid_cache(&file, false)
	cache, problem := validate_at(address, span)
	testing.expect_value(t, problem.kind, Problem_Kind.None)
	testing.expect(t, cache.header != nil)
	_, largest := validate_at(address, max(u64))
	testing.expect_value(t, largest.kind, Problem_Kind.None)
}

// Each field at its limit is valid, and a valid cache gives each table at
// its size. These come after the refusals: they say that each limit above
// is the limit, not a value before it.
@(test)
validate_takes_each_field_at_its_limit :: proc(t: ^testing.T) {
	Limit :: struct {
		name:         string,
		proportional: bool,
		change:       proc(file: ^Test_File),
	}
	limits := [?]Limit {
		{"the valid monospace cache", false, proc(file: ^Test_File) {}},
		{"the valid proportional cache", true, proc(file: ^Test_File) {}},
		{"rows to the end of the line", false, proc(file: ^Test_File) {glyph_entry_of(file, 0).first_row = CELL_HEIGHT - INK_ROWS}},
		{"a baseline at the end of the line", false, proc(file: ^Test_File) {size_entry_of(file).baseline = CELL_HEIGHT}},
		{"a monospace glyph as wide as its cell", false, proc(file: ^Test_File) {glyph_entry_of(file, 1).width = CELL_WIDTH}},
		{"a glyph as wide as the limit", true, proc(file: ^Test_File) {glyph_entry_of(file, 1).width = GLYPH_WIDTH_LIMIT}},
		{"a glyph at the left limit", true, proc(file: ^Test_File) {glyph_entry_of(file, 1).left = -LEFT_LIMIT}},
		{"a glyph at the right limit", true, proc(file: ^Test_File) {glyph_entry_of(file, 1).left = GLYPH_WIDTH_LIMIT}},
		{"an advance of 0", true, proc(file: ^Test_File) {advance_of(file, 0)^ = 0}},
		{"an advance at the limit", true, proc(file: ^Test_File) {advance_of(file, CHARACTER_COUNT - 1)^ = ADVANCE_LIMIT}},
		{"adjustments at the two limits", true, proc(file: ^Test_File) {pair_of(file, 0).adjustment = -ADVANCE_LIMIT; pair_of(file, 1).adjustment = ADVANCE_LIMIT}},
		{"a pair of the last characters", true, proc(file: ^Test_File) {pair_of(file, 1)^ = {left = CHARACTER_COUNT - 1, right = CHARACTER_COUNT - 1}}},
		{"the last filter and grid fit", false, proc(file: ^Test_File) {header_of(file).flags = FLAG_GRID_FIT | (FILTER_COUNT - 1) << FILTER_SHIFT}},
		{"a name with no byte", false, proc(file: ^Test_File) {header_of(file).font_name = {}}},
		{"a name of every byte but its end", false, proc(file: ^Test_File) {
				header := header_of(file)
				for index in 0 ..< FONT_NAME_SIZE - 1 {
					header.font_name[index] = u8(ASCII_FIRST + index % ASCII_COUNT)
				}
				header.font_name[FONT_NAME_SIZE - 1] = 0
			}},
		{"the last printable byte", false, proc(file: ^Test_File) {header_of(file).font_name[0] = ASCII_LAST}},
	}
	for limit in limits {
		file: Test_File
		valid_cache(&file, limit.proportional)
		limit.change(&file)
		cache, problem := validate(bytes_of(&file))
		testing.expectf(t, problem.kind == .None, "%s: the problem %v at %v, value %v", limit.name, problem.kind, problem.index, problem.value)
		if problem.kind != .None {
			continue
		}
		testing.expect_value(t, len(cache.sizes), 1)
		testing.expect_value(t, len(cache.glyphs), CHARACTER_COUNT)
		testing.expect_value(t, len(cache.advances), CHARACTER_COUNT)
		testing.expect_value(t, len(cache.pairs), limit.proportional ? PAIR_COUNT : 0)
		testing.expect_value(t, len(cache.words), WORD_COUNT)
	}
}
