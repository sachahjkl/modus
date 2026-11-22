#+build !freestanding
package font_outlines

import "core:testing"

// Two small files in place of fonts: validate reads no byte of a font.
@(private = "file")
first_file := [?]u8{1, 2, 3, 4, 5}
@(private = "file")
second_file := [?]u8{6, 7, 8}

// A valid resource of two files, in words of the test.
@(private = "file")
resource_make :: proc(t: ^testing.T) -> (words: []u64, bytes: []u8) {
	fonts := [2]Font_Input{{"first", first_file[:]}, {"second", second_file[:]}}
	size := resource_size(fonts[:])
	words = make([]u64, (size + 7) / 8)
	bytes = ([^]u8)(raw_data(words))[:size]
	written, ok := resource_write(fonts[:], bytes)
	testing.expect(t, ok && written == size)
	return words, bytes
}

// The writer refuses what validate would refuse, and leaves its output as
// it was: no font, more than FONT_LIMIT fonts, an empty file, an empty
// name, a name of NAME_SIZE bytes, a name with a space or a byte past 126,
// two fonts of one name, an output one byte too short, and an output that
// does not start on 8 bytes.
@(test)
the_writer_refuses_a_wrong_list :: proc(t: ^testing.T) {
	out: [1024]u64
	bytes := ([^]u8)(raw_data(out[:]))[:size_of(out)]
	file := first_file[:]
	too_many: [FONT_LIMIT + 1]Font_Input
	names := [FONT_LIMIT + 1]string{"a", "b", "c", "d", "e", "f", "g", "h", "i"}
	for &font, index in too_many {
		font = {names[index], file}
	}
	long_name := "abcdefghijklmnopqrstuvwxyz012345"
	#assert(len("abcdefghijklmnopqrstuvwxyz012345") == NAME_SIZE)
	lists := [?][]Font_Input {
		{},
		too_many[:],
		{{"empty", {}}},
		{{"", file}},
		{{long_name, file}},
		{{"a name", file}},
		{{"café", file}},
		{{"twice", file}, {"twice", file}},
	}
	for list, index in lists {
		_, ok := resource_write(list, bytes)
		testing.expectf(t, !ok, "list %v is refused", index)
	}
	good := [1]Font_Input{{"good", file}}
	size := resource_size(good[:])
	_, ok := resource_write(good[:], bytes[:size - 1])
	testing.expect(t, !ok)
	_, ok = resource_write(good[:], bytes[1:][:size])
	testing.expect(t, !ok)
	for word in out {
		testing.expect_value(t, word, u64(0))
	}
	written: int
	written, ok = resource_write(good[:], bytes)
	testing.expect(t, ok && written == size)
	// The longest names that fit: NAME_SIZE - 1 bytes, and the longest
	// name of the resource of the build.
	longest := [2]Font_Input{{long_name[:NAME_SIZE - 1], file}, {"paper_mono_semibold", file}}
	written, ok = resource_write(longest[:], bytes)
	testing.expect(t, ok && written == resource_size(longest[:]))
	outlines, problem := validate(bytes[:written])
	testing.expect_value(t, problem.kind, Problem_Kind.None)
	testing.expect_value(t, name_of(&outlines.records[0]), long_name[:NAME_SIZE - 1])
	testing.expect_value(t, name_of(&outlines.records[1]), "paper_mono_semibold")
}

// validate refuses each damaged resource: too short, another magic,
// another version, a size that is not the size of the bytes, a count of 0
// and one past FONT_LIMIT, records past the bytes, a name with no byte,
// with no zero byte at its end, with a byte after its end, with a byte
// under 33, two records of one name, a font of 0 bytes, a font that starts
// in the records, a font past the end, and an offset and a size whose sum
// wraps. validate_at refuses the address 0, an address not on 8 bytes and
// a size past the span. A valid resource, last, gives each font.
@(test)
validate_refuses_a_damaged_resource :: proc(t: ^testing.T) {
	words, bytes := resource_make(t)
	defer delete(words)
	original := make([]u8, len(bytes))
	defer delete(original)
	copy(original, bytes)
	_, problem := validate(bytes[:HEADER_SIZE - 1])
	testing.expect_value(t, problem.kind, Problem_Kind.Too_Short)
	_, problem = validate(nil)
	testing.expect_value(t, problem.kind, Problem_Kind.Too_Short)
	Damage :: enum {
		Magic,
		Version,
		Size_Above,
		Size_Below,
		Count_Zero,
		Count_Past_The_Limit,
		Records_Past_The_Bytes,
		Name_Empty,
		Name_With_No_End,
		Name_With_A_Byte_After_Its_End,
		Name_With_A_Control_Byte,
		Two_Records_Of_One_Name,
		Font_Of_No_Byte,
		Font_In_The_Records,
		Font_Past_The_End,
		Offset_And_Size_That_Wrap,
	}
	expected := [Damage]Problem_Kind {
		.Magic                          = .Bad_Magic,
		.Version                        = .Bad_Version,
		.Size_Above                     = .Bad_Size,
		.Size_Below                     = .Bad_Size,
		.Count_Zero                     = .Bad_Count,
		.Count_Past_The_Limit           = .Bad_Count,
		.Records_Past_The_Bytes         = .Too_Short,
		.Name_Empty                     = .Bad_Name,
		.Name_With_No_End               = .Bad_Name,
		.Name_With_A_Byte_After_Its_End = .Bad_Name,
		.Name_With_A_Control_Byte       = .Bad_Name,
		.Two_Records_Of_One_Name        = .Bad_Name,
		.Font_Of_No_Byte                = .Font_Outside,
		.Font_In_The_Records            = .Font_Outside,
		.Font_Past_The_End              = .Font_Outside,
		.Offset_And_Size_That_Wrap      = .Font_Outside,
	}
	for damage in Damage {
		copy(bytes, original)
		header := (^Header)(raw_data(bytes))
		records := ([^]Font_Record)(&bytes[RECORDS_OFFSET])
		checked := bytes
		switch damage {
		case .Magic:
			header.magic ~= 1
		case .Version:
			header.version = VERSION + 1
		case .Size_Above:
			header.file_size += 1
		case .Size_Below:
			checked = bytes[:len(bytes) - 1]
		case .Count_Zero:
			header.font_count = 0
		case .Count_Past_The_Limit:
			header.font_count = FONT_LIMIT + 1
		case .Records_Past_The_Bytes:
			header.font_count = FONT_LIMIT
			header.file_size = RECORDS_OFFSET + RECORD_SIZE
			checked = bytes[:RECORDS_OFFSET + RECORD_SIZE]
		case .Name_Empty:
			records[0].name = {}
		case .Name_With_No_End:
			for &name_byte in records[0].name {
				name_byte = 'a'
			}
		case .Name_With_A_Byte_After_Its_End:
			records[0].name[NAME_SIZE - 1] = 'z'
		case .Name_With_A_Control_Byte:
			records[0].name[0] = 0x1B
		case .Two_Records_Of_One_Name:
			records[1].name = records[0].name
		case .Font_Of_No_Byte:
			records[1].size = 0
		case .Font_In_The_Records:
			records[0].offset = RECORDS_OFFSET
		case .Font_Past_The_End:
			records[1].size += 1
		case .Offset_And_Size_That_Wrap:
			records[1].size = max(u64)
		}
		_, problem = validate(checked)
		testing.expectf(t, problem.kind == expected[damage], "%v: %v, expected %v", damage, problem.kind, expected[damage])
	}
	copy(bytes, original)
	_, problem = validate_at(0, 1 << 20)
	testing.expect_value(t, problem.kind, Problem_Kind.Too_Short)
	_, problem = validate_at(uintptr(raw_data(bytes)) + 4, 1 << 20)
	testing.expect_value(t, problem.kind, Problem_Kind.Too_Short)
	_, problem = validate_at(uintptr(raw_data(bytes)), u64(len(bytes) - 1))
	testing.expect_value(t, problem.kind, Problem_Kind.Bad_Size)
	outlines: Outlines
	outlines, problem = validate_at(uintptr(raw_data(bytes)), u64(len(bytes)))
	testing.expect_value(t, problem.kind, Problem_Kind.None)
	testing.expect_value(t, outlines.count, 2)
	testing.expect_value(t, name_of(&outlines.records[0]), "first")
	testing.expect_value(t, name_of(&outlines.records[1]), "second")
	testing.expect(t, string(font_bytes(&outlines, 0)) == string(first_file[:]))
	testing.expect(t, string(font_bytes(&outlines, 1)) == string(second_file[:]))
	testing.expect_value(t, outlines.records[1].offset % FONT_ALIGNMENT, u64(0))
}

// The bytes of a resource can change after validate, as a call region that
// another thread writes: the span of each font stays the span that validate
// checked. A record whose offset and size are changed to pass the end of
// the resource, and a header whose count grows past the limit, change
// neither the count nor any span.
@(test)
a_change_after_validate_changes_no_span :: proc(t: ^testing.T) {
	words, bytes := resource_make(t)
	defer delete(words)
	outlines, problem := validate(bytes)
	testing.expect_value(t, problem.kind, Problem_Kind.None)
	header := (^Header)(raw_data(bytes))
	records := ([^]Font_Record)(&bytes[RECORDS_OFFSET])
	header.font_count = FONT_LIMIT + 1
	records[1].offset = max(u64)
	records[1].size = max(u64)
	records[0].name = {}
	testing.expect_value(t, outlines.count, 2)
	testing.expect_value(t, outlines.header.font_count, u32(2))
	testing.expect_value(t, name_of(&outlines.records[0]), "first")
	testing.expect(t, string(font_bytes(&outlines, 0)) == string(first_file[:]))
	testing.expect(t, string(font_bytes(&outlines, 1)) == string(second_file[:]))
}

// The lists of the characters past the glyph cache: each run is in order
// and after the run before it, no run is empty, each character is past
// the Latin-1 Supplement, and the counts are the counts of the constants.
@(test)
the_characters_past_the_glyph_cache :: proc(t: ^testing.T) {
	Case :: struct {
		ranges: []Character_Range,
		count:  int,
	}
	cases := [3]Case{{interface_past_cache_ranges[:], INTERFACE_PAST_CACHE_COUNT}, {cell_past_cache_ranges[:], CELL_PAST_CACHE_COUNT}, {script_fallback_past_cache_ranges[:], SCRIPT_FALLBACK_PAST_CACHE_COUNT}}
	for each in cases {
		count := 0
		previous_last := rune(0xFF)
		for range in each.ranges {
			testing.expectf(t, range.first <= range.last && range.first > previous_last, "the run %x to %x", range.first, range.last)
			previous_last = range.last
			count += int(range.last - range.first) + 1
		}
		testing.expect_value(t, count, each.count)
	}
}
