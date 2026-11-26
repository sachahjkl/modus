#+build !freestanding
#+build !modus
package module

import "core:strings"
import "core:testing"

// One row of a test file: the enum index, the member number, the language
// tag and the text. text_offset or tag_offset not 0 places the text or the
// tag at that offset of the string table in place of its own.
@(private = "file")
Test_Text :: struct {
	enum_index:    u32,
	member_number: u32,
	tag:           string,
	text:          string,
	text_offset:   u32,
	tag_offset:    u32,
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
		item := Member_Text{enum_index = row.enum_index, member_number = row.member_number}
		item.text_offset, item.text_count = add(&strings_table, row.text)
		item.tag_offset, item.tag_count = add(&strings_table, row.tag)
		if row.text_offset != 0 {
			item.text_offset = row.text_offset
		}
		if row.tag_offset != 0 {
			item.tag_offset = row.tag_offset
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

// Each rule of a row refuses its edges: the enum, the member, the tag and
// the text; then the order of the rows refuses a member and a tag given
// twice, and a row before the row before it.
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
		{{{0, 0, "en", "1.25", 0, 0}}, 1, .No_Enum},
		{{{3, 0, "en", "1.25", 0, 0}}, 1, .No_Enum},
		{{{max(u32), 0, "en", "1.25", 0, 0}}, 1, .No_Enum},
		// No member: the count of the enum, and the largest number.
		{{{2, 3, "en", "1.25", 0, 0}}, 1, .No_Member},
		{{{1, 2, "en", "bold", 0, 0}}, 1, .No_Member},
		{{{2, max(u32), "en", "1.25", 0, 0}}, 1, .No_Member},
		// A tag: empty, not well-formed, outside the string table, past its
		// bound, and well-formed in another case than its canonical one.
		{{{2, 0, "", "1.25", 0, 0}}, 1, .Bad_Tag},
		{{{2, 0, "-fr", "1.25", 0, 0}}, 1, .Bad_Tag},
		{{{2, 0, "fr--CA", "1.25", 0, 0}}, 1, .Bad_Tag},
		{{{2, 0, "english-fra", "1.25", 0, 0}}, 1, .Bad_Tag},
		{{{2, 0, "en", "1.25", 0, max(u32)}}, 1, .Bad_Tag},
		{{{2, 0, "en-aaaaaaaa-bbbbbbbb-cccccccc-dddddd", "1.25", 0, 0}}, 1, .Bad_Tag},
		{{{2, 0, "EN", "1.25", 0, 0}}, 1, .Bad_Tag},
		{{{2, 0, "fr-ca", "1.25", 0, 0}}, 1, .Bad_Tag},
		// A text: empty, one byte past the bound, outside the string table,
		// a broken sequence, a control character.
		{{{2, 0, "en", "", 0, 0}}, 1, .Bad_Text},
		{{{2, 0, "en", past_bound, 0, 0}}, 1, .Bad_Text},
		{{{2, 0, "en", "1.25", max(u32), 0}}, 1, .Bad_Text},
		{{{2, 0, "en", "1.\xff", 0, 0}}, 1, .Bad_Text},
		{{{2, 0, "en", "1.25\n", 0, 0}}, 1, .Bad_Text},
		// A text that a reader would read as another one: a space of no
		// width (U+200B), a mark of direction (U+202E), an isolate
		// (U+2066), the mark of the byte order (U+FEFF), a separator of
		// paragraphs (U+2029), spaces only (U+0020; U+00A0, U+2000, U+3000).
		{{{2, 0, "en", "1.\xe2\x80\x8b25", 0, 0}}, 1, .Bad_Text},
		{{{2, 0, "en", "\xe2\x80\xae52.1", 0, 0}}, 1, .Bad_Text},
		{{{2, 0, "en", "1.25\xe2\x81\xa6", 0, 0}}, 1, .Bad_Text},
		{{{2, 0, "en", "\xef\xbb\xbf1.25", 0, 0}}, 1, .Bad_Text},
		{{{2, 0, "en", "1.25\xe2\x80\xa9", 0, 0}}, 1, .Bad_Text},
		{{{2, 0, "en", " ", 0, 0}}, 1, .Bad_Text},
		{{{2, 0, "en", "\xc2\xa0\xe2\x80\x80\xe3\x80\x80", 0, 0}}, 1, .Bad_Text},
		// The second row: a broken row after a good one.
		{{{2, 0, "en", "1.25", 0, 0}, {2, 1, "en-", "1.375", 0, 0}}, 2, .Bad_Tag},
		// Two rows for one member and one tag, then a row before the one
		// before it: by its tag, by its member, and by its enum.
		{{{2, 0, "en", "1.25", 0, 0}, {2, 0, "en", "one and a quarter", 0, 0}}, 2, .Twice},
		{{{2, 0, "fr", "1,25", 0, 0}, {2, 0, "en", "1.25", 0, 0}}, 2, .Out_Of_Order},
		{{{2, 1, "en", "1.375", 0, 0}, {2, 0, "en", "1.25", 0, 0}}, 2, .Out_Of_Order},
		{{{2, 0, "en", "1.25", 0, 0}, {1, 1, "en", "spleen", 0, 0}}, 2, .Out_Of_Order},
	}
	for item in cases {
		file := texts_file_of(item.rows)
		row, problem := member_texts_check(file)
		testing.expectf(t, row == item.row && problem == item.problem, "%v gives %v at %d, not %v at %d", item.rows, problem, row, item.problem, item.row)
	}
	// The reader refuses a broken row too: the member shows its name.
	broken := texts_file_of({{2, 0, "en", "1.25\n", 0, 0}})
	scale, _ := enum_type(broken, 2)
	testing.expect_value(t, member_display_text(broken, 2, scale, 0, nil), "ten_eighths")
	// The edges that are taken: a text of the largest length, and of one
	// byte; tags of each form, in their order of bytes; a file with no row.
	// A letter of another script that looks like a Latin one is taken: a
	// translation needs each script. A space between words too.
	longest := strings.repeat("é", MEMBER_TEXT_CAPACITY / 2, context.temp_allocator)
	taken := texts_file_of({
		{1, 0, "en", "\xd0\x92ector", 0, 0},
		{1, 1, "en", "S", 0, 0},
		{2, 0, "en", longest, 0, 0},
		{2, 0, "en-x-private", "1,25", 0, 0},
		{2, 0, "fr", "1,25", 0, 0},
		{2, 0, "fr-CA", "1,25", 0, 0},
		{2, 0, "zh-Hant-TW", "1.25", 0, 0},
		{2, 1, "en", "1 3/8", 0, 0},
	})
	row, problem := member_texts_check(taken)
	testing.expect(t, row == 0 && problem == .None)
	row, problem = member_texts_check(texts_file_of(nil))
	testing.expect(t, row == 0 && problem == .None)
}

// A reader takes the text of the member for the tags of the principal, as
// the Lookup of RFC 4647: each tag, its shorter tags, the next tag, then
// en, then the name. A tag in another case finds its row; a tag that is
// not well-formed finds none; a shorter tag never finds the text of another
// member or of another enum.
@(test)
a_member_shows_its_text_or_its_name :: proc(t: ^testing.T) {
	file := texts_file_of({
		{1, 1, "en", "Spleen 8x16", 0, 0},
		{2, 0, "en", "1.25", 0, 0},
		{2, 0, "fr", "1,25", 0, 0},
		{2, 0, "zh-Hant", "1.25 zh", 0, 0},
		{2, 2, "en", "1.5", 0, 0},
		{2, 2, "fr-CA", "1,5 CA", 0, 0},
	})
	font, _ := enum_type(file, 1)
	scale, _ := enum_type(file, 2)
	// No text: the name.
	testing.expect_value(t, member_display_text(file, 1, font, 0, {"fr"}), "vector")
	testing.expect_value(t, member_display_text(file, 2, scale, 1, {"fr-CA", "de"}), "eleven_eighths")
	// A member past the enum: no text and no name.
	testing.expect_value(t, member_display_text(file, 2, scale, 3, nil), "")
	_, found := member_text(file, 3, 0, nil)
	testing.expect(t, !found)
	// A tag that is not well-formed: no row, then en.
	_, found = member_text_of_tag(file, 2, 0, "fr--CA")
	testing.expect(t, !found)
	testing.expect_value(t, member_display_text(file, 2, scale, 0, {"fr--CA"}), "1.25")
	// The exact search: the tag in another case, and no shorter tag.
	text, exact := member_text_of_tag(file, 2, 0, "FR")
	testing.expect(t, exact && text == "1,25")
	_, found = member_text_of_tag(file, 2, 0, "fr-CA")
	testing.expect(t, !found)
	// The Lookup: fr-CA falls to fr; zh-Hant-TW to zh-Hant; de to en; the
	// longer tag first when it has a row.
	testing.expect_value(t, member_display_text(file, 2, scale, 0, {"fr-CA"}), "1,25")
	testing.expect_value(t, member_display_text(file, 2, scale, 0, {"zh-Hant-TW"}), "1.25 zh")
	testing.expect_value(t, member_display_text(file, 2, scale, 0, {"de", "fr"}), "1,25")
	testing.expect_value(t, member_display_text(file, 2, scale, 0, {"de"}), "1.25")
	testing.expect_value(t, member_display_text(file, 2, scale, 2, {"fr-CA"}), "1,5 CA")
	testing.expect_value(t, member_display_text(file, 2, scale, 2, {"fr"}), "1.5")
	testing.expect_value(t, member_display_text(file, 1, font, 1, nil), "Spleen 8x16")
}
