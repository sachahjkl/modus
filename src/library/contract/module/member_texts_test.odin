#+build !freestanding
package module

import "core:strings"
import "core:testing"

// One row of a test file: the enum index, the member number, the language
// byte, the text, and the reserved bytes. text_offset not 0 places the
// text at that offset of the string table in place of its own.
@(private = "file")
Test_Text :: struct {
	enum_index:    u32,
	member_number: u32,
	language:      u8,
	text:          string,
	reserved:      [7]u8,
	text_offset:   u32,
}

// texts_file_of writes a module file with two enums, Font (vector, spleen)
// and Scale (ten_eighths, eleven_eighths, twelve_eighths), and the rows of
// the table Member_Texts in the order given.
@(private = "file")
texts_file_of :: proc(rows: []Test_Text) -> []u8 {
	strings_table := make([dynamic]u8, context.temp_allocator)
	append(&strings_table, 0)
	add :: proc(strings_table: ^[dynamic]u8, text: string) -> (offset: u32, count: u32) {
		offset = u32(len(strings_table))
		append(strings_table, ..transmute([]u8)text)
		return offset, u32(len(text))
	}
	Source :: struct {
		name:    string,
		members: []string,
	}
	sources := [2]Source{{"Font", {"vector", "spleen"}}, {"Scale", {"ten_eighths", "eleven_eighths", "twelve_eighths"}}}
	enum_records := make([dynamic]Enum_Type, context.temp_allocator)
	member_records := make([dynamic]Member, context.temp_allocator)
	append(&enum_records, Enum_Type{})
	append(&member_records, Member{})
	for source in sources {
		described := Enum_Type{first_member = u32(len(member_records)), member_count = u32(len(source.members)), size = 4, unsigned = true}
		described.name_offset, described.name_count = add(&strings_table, source.name)
		append(&enum_records, described)
		for name, value in source.members {
			item := Member{value = i64(value)}
			item.name_offset, item.name_count = add(&strings_table, name)
			append(&member_records, item)
		}
	}
	text_records := make([dynamic]Member_Text, context.temp_allocator)
	append(&text_records, Member_Text{})
	for row in rows {
		item := Member_Text{enum_index = row.enum_index, member_number = row.member_number, language = row.language, reserved = row.reserved}
		item.text_offset, item.text_count = add(&strings_table, row.text)
		if row.text_offset != 0 {
			item.text_offset = row.text_offset
		}
		append(&text_records, item)
	}
	offset := size_of(Header) + TABLE_COUNT * size_of(Table_Entry)
	file := make([dynamic]u8, offset, context.temp_allocator)
	(^Header)(&file[0])^ = {magic = MAGIC, version = VERSION, header_size = size_of(Header), machine = .X86_64, table_count = TABLE_COUNT}
	place :: proc(file: ^[dynamic]u8, kind: Table_Kind, bytes: []u8, count: int, record_size: int) {
		entry := Table_Entry{offset = u64(len(file)), count = u32(count), record_size = u32(record_size)}
		append(file, ..bytes)
		(^Table_Entry)(&file[size_of(Header) + int(kind) * size_of(Table_Entry)])^ = entry
	}
	place(&file, .Enums, ([^]u8)(raw_data(enum_records))[:len(enum_records) * size_of(Enum_Type)], len(enum_records), size_of(Enum_Type))
	place(&file, .Members, ([^]u8)(raw_data(member_records))[:len(member_records) * size_of(Member)], len(member_records), size_of(Member))
	place(&file, .Member_Texts, ([^]u8)(raw_data(text_records))[:len(text_records) * size_of(Member_Text)], len(text_records), size_of(Member_Text))
	place(&file, .Strings, strings_table[:], len(strings_table), 1)
	return file[:]
}

ENGLISH :: u8(Language.English)

// Each rule of a row refuses its edges: the enum, the member, the language,
// the reserved bytes and the text; then the order of the rows refuses a
// member and a language given twice, and a row before the row before it.
@(test)
a_text_row_that_breaks_a_rule_is_refused :: proc(t: ^testing.T) {
	Case :: struct {
		rows:    []Test_Text,
		row:     u32,
		problem: Member_Text_Problem,
	}
	past_bound := strings.repeat("a", MEMBER_TEXT_CAPACITY + 1, context.temp_allocator)
	cases := [?]Case {
		// No enum: 0, one past the table, the largest index.
		{{{0, 0, ENGLISH, "1.25", {}, 0}}, 1, .No_Enum},
		{{{3, 0, ENGLISH, "1.25", {}, 0}}, 1, .No_Enum},
		{{{max(u32), 0, ENGLISH, "1.25", {}, 0}}, 1, .No_Enum},
		// No member: the count of the enum, and the largest number.
		{{{2, 3, ENGLISH, "1.25", {}, 0}}, 1, .No_Member},
		{{{1, 2, ENGLISH, "bold", {}, 0}}, 1, .No_Member},
		{{{2, max(u32), ENGLISH, "1.25", {}, 0}}, 1, .No_Member},
		// A language byte of no language: 0, one past the last, the largest.
		{{{2, 0, 0, "1.25", {}, 0}}, 1, .Bad_Language},
		{{{2, 0, u8(max(Language)) + 1, "1.25", {}, 0}}, 1, .Bad_Language},
		{{{2, 0, max(u8), "1.25", {}, 0}}, 1, .Bad_Language},
		// A reserved byte, the first and the last.
		{{{2, 0, ENGLISH, "1.25", {1, 0, 0, 0, 0, 0, 0}, 0}}, 1, .Bad_Reserved},
		{{{2, 0, ENGLISH, "1.25", {0, 0, 0, 0, 0, 0, max(u8)}, 0}}, 1, .Bad_Reserved},
		// A text: empty, one byte past the bound, outside the string table,
		// a broken sequence, a control character.
		{{{2, 0, ENGLISH, "", {}, 0}}, 1, .Bad_Text},
		{{{2, 0, ENGLISH, past_bound, {}, 0}}, 1, .Bad_Text},
		{{{2, 0, ENGLISH, "1.25", {}, max(u32)}}, 1, .Bad_Text},
		{{{2, 0, ENGLISH, "1.\xff", {}, 0}}, 1, .Bad_Text},
		{{{2, 0, ENGLISH, "1.25\n", {}, 0}}, 1, .Bad_Text},
		// The second row: a broken row after a good one.
		{{{2, 0, ENGLISH, "1.25", {}, 0}, {2, 1, 0, "1.375", {}, 0}}, 2, .Bad_Language},
		// Two rows for one member and one language, then a row before the
		// one before it: by its member, and by its enum.
		{{{2, 0, ENGLISH, "1.25", {}, 0}, {2, 0, ENGLISH, "one and a quarter", {}, 0}}, 2, .Twice},
		{{{2, 1, ENGLISH, "1.375", {}, 0}, {2, 0, ENGLISH, "1.25", {}, 0}}, 2, .Out_Of_Order},
		{{{2, 0, ENGLISH, "1.25", {}, 0}, {1, 1, ENGLISH, "spleen", {}, 0}}, 2, .Out_Of_Order},
	}
	for item in cases {
		file := texts_file_of(item.rows)
		row, problem := member_texts_check(file)
		testing.expectf(t, row == item.row && problem == item.problem, "%v gives %v at %d, not %v at %d", item.rows, problem, row, item.problem, item.row)
	}
	// The reader refuses a broken row too: the member shows its name.
	broken := texts_file_of({{2, 0, ENGLISH, "1.25\n", {}, 0}})
	scale, _ := enum_type(broken, 2)
	testing.expect_value(t, member_display_text(broken, 2, scale, 0, .English), "ten_eighths")
	// The edges that are taken: a text of the largest length, and of one
	// byte; a file with no row.
	longest := strings.repeat("é", MEMBER_TEXT_CAPACITY / 2, context.temp_allocator)
	taken := texts_file_of({{1, 1, ENGLISH, "S", {}, 0}, {2, 0, ENGLISH, longest, {}, 0}})
	row, problem := member_texts_check(taken)
	testing.expect(t, row == 0 && problem == .None)
	row, problem = member_texts_check(texts_file_of(nil))
	testing.expect(t, row == 0 && problem == .None)
}

// A name of no language is refused: the empty name, another case, a
// language that the set does not have yet.
@(test)
a_name_of_no_language_is_refused :: proc(t: ^testing.T) {
	for name in ([]string{"", "English", "ENGLISH", "french", "english "}) {
		_, found := language_of_name(name)
		testing.expectf(t, !found, "%q is taken as a language", name)
	}
	language, found := language_of_name("english")
	testing.expect(t, found && language == .English)
}

// A reader takes the text of the member in its language, finds each row
// of a table in order, and shows the name of a member with no text: the
// name, never the text of another member or of another enum.
@(test)
a_member_shows_its_text_or_its_name :: proc(t: ^testing.T) {
	file := texts_file_of({{1, 1, ENGLISH, "Spleen 8x16", {}, 0}, {2, 0, ENGLISH, "1.25", {}, 0}, {2, 2, ENGLISH, "1.5", {}, 0}})
	font, _ := enum_type(file, 1)
	scale, _ := enum_type(file, 2)
	// No text: the name.
	testing.expect_value(t, member_display_text(file, 1, font, 0, .English), "vector")
	testing.expect_value(t, member_display_text(file, 2, scale, 1, .English), "eleven_eighths")
	// A member past the enum: no text and no name.
	testing.expect_value(t, member_display_text(file, 2, scale, 3, .English), "")
	_, found := member_text(file, 3, 0, .English)
	testing.expect(t, !found)
	// The texts.
	testing.expect_value(t, member_display_text(file, 1, font, 1, .English), "Spleen 8x16")
	testing.expect_value(t, member_display_text(file, 2, scale, 0, .English), "1.25")
	testing.expect_value(t, member_display_text(file, 2, scale, 2, .English), "1.5")
}
