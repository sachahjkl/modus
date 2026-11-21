package module

import "modus:contract/enum_word"
import "modus:contract/text_encoding"

// The display texts of the members (src/md/features/enum_parameters.md,
// "The display text of a member"): a member has a name, which a line types
// and a module compiles, and a display text, which a principal reads. The
// texts are a table of their own, apart from the enum, by member and by
// language: a translation is more rows, with no change of the code, of the
// names or of the format.

// A language of a display text. The byte 0 names none, so a row of zeros
// is refused. A translation adds a member here and rows in the files.
Language :: enum u8 {
	English = 1,
}

// The name of each language, as the attribute `member_texts` of a source
// names it.
@(rodata)
LANGUAGE_NAMES := [Language]string {
	.English = "english",
}

// The language that a reader takes when the language of the principal has
// no row for a member.
LANGUAGE_FALLBACK :: Language.English

MEMBER_TEXT_CAPACITY :: 24 // The bytes of a display text at most: one button of a row of the palette.

// One display text: a member of an enum in a language.
//
// Example: the scale `.fourteen_eighths` of the module settings has the
// English text "1.75".
Member_Text :: struct {
	enum_index:    u32, // An index in the table Enums, from 1.
	member_number: u32, // The member in its enum, from 0.
	text_offset:   u32, // In the string table.
	text_count:    u32, // From 1 to MEMBER_TEXT_CAPACITY bytes of UTF-8 with no control character.
	language:      u8, // A Language.
	reserved:      [7]u8, // 0.
}
#assert(size_of(Member_Text) == 24)

// What member_texts_check refuses in a row.
Member_Text_Problem :: enum u8 {
	None         = 0, // The row keeps each rule.
	No_Enum      = 1, // The enum index names no valid enum of the table Enums.
	No_Member    = 2, // The member number is past the members of its enum.
	Bad_Text     = 3, // The text is empty, past MEMBER_TEXT_CAPACITY, outside the string table, or not UTF-8 with no control character.
	Bad_Language = 4, // The language byte names no member of Language.
	Bad_Reserved = 5, // A reserved byte is not 0.
	Twice        = 6, // The row has the enum, the member and the language of the row before it.
	Out_Of_Order = 7, // The row comes before the row before it, in the order of the enum, the member and the language.
}

// language_of_name gives the language of a name, "english". found is false
// for a name of no language.
language_of_name :: proc "contextless" (name: string) -> (language: Language, found: bool) {
	for item, known in LANGUAGE_NAMES {
		if item == name {
			return known, true
		}
	}
	return {}, false
}

// member_text_key orders the rows: the enum, then the member, then the
// language. Each part is within its bits: an index and a number of 32 bits,
// and a byte.
@(private)
member_text_key :: proc "contextless" (row: Member_Text) -> (high: u64, low: u64) {
	return u64(row.enum_index) << 32 | u64(row.member_number), u64(row.language)
}

// member_text_row gives the row index of the table Member_Texts, from 1,
// and its text, after it checked the row alone: its enum, its member, its
// language, its reserved bytes and its text. The order of the rows is the
// part of member_texts_check.
member_text_row :: proc "contextless" (file: []u8, index: u32) -> (row: Member_Text, text: string, problem: Member_Text_Problem) {
	found: bool
	row, found = record(file, .Member_Texts, index, Member_Text)
	if index == 0 || !found {
		return {}, "", .No_Enum
	}
	described, enum_problem := enum_type(file, row.enum_index)
	if enum_problem != .None {
		return row, "", .No_Enum
	}
	if row.member_number >= described.member_count {
		return row, "", .No_Member
	}
	if _, known := enum_word.member_of_word(Language, u64(row.language)); !known {
		return row, "", .Bad_Language
	}
	if row.reserved != {} {
		return row, "", .Bad_Reserved
	}
	text = string_at(file, row.text_offset, row.text_count)
	if row.text_count == 0 || row.text_count > MEMBER_TEXT_CAPACITY || u32(len(text)) != row.text_count || !text_encoding.text_valid(transmute([]u8)text) {
		return row, "", .Bad_Text
	}
	return row, text, .None
}

// member_texts_check checks each row of the table Member_Texts, and that
// each row comes after the row before it: two rows for one member and one
// language are refused. It gives the first row that breaks a rule, from 1,
// and why; 0 and None for a file whose rows keep each rule, or that has no
// row.
member_texts_check :: proc "contextless" (file: []u8) -> (row_index: u32, problem: Member_Text_Problem) {
	before_high, before_low: u64
	for index in u32(1) ..< count(file, .Member_Texts) {
		row, _, row_problem := member_text_row(file, index)
		if row_problem != .None {
			return index, row_problem
		}
		high, low := member_text_key(row)
		if index > 1 {
			switch {
			case high == before_high && low == before_low:
				return index, .Twice
			case high < before_high || high == before_high && low < before_low:
				return index, .Out_Of_Order
			}
		}
		before_high, before_low = high, low
	}
	return 0, .None
}

// member_text gives the display text of a member in a language: the row of
// the language, else the row of LANGUAGE_FALLBACK. found is false when the
// module gives no text for the member, or the row breaks a rule: the reader
// then shows the name. The rows are in order, so a binary search finds one.
member_text :: proc "contextless" (file: []u8, enum_index, member_number: u32, language: Language) -> (text: string, found: bool) {
	if text, found = member_text_of_language(file, enum_index, member_number, language); found {
		return
	}
	return member_text_of_language(file, enum_index, member_number, LANGUAGE_FALLBACK)
}

@(private)
member_text_of_language :: proc "contextless" (file: []u8, enum_index, member_number: u32, language: Language) -> (text: string, found: bool) {
	wanted_high, wanted_low := member_text_key({enum_index = enum_index, member_number = member_number, language = u8(language)})
	low, high := u32(1), count(file, .Member_Texts)
	for low < high {
		middle := low + (high - low) / 2
		row, row_found := record(file, .Member_Texts, middle, Member_Text)
		if !row_found {
			return "", false
		}
		row_high, row_low := member_text_key(row)
		switch {
		case row_high == wanted_high && row_low == wanted_low:
			_, row_text, problem := member_text_row(file, middle)
			return row_text, problem == .None
		case row_high < wanted_high || row_high == wanted_high && row_low < wanted_low:
			low = middle + 1
		case:
			high = middle
		}
	}
	return "", false
}

// member_display_text gives what a principal reads for the member number of
// an enum: its display text in the language, else in LANGUAGE_FALLBACK,
// else its name. A line never types the result: it types the name.
member_display_text :: proc "contextless" (file: []u8, enum_index: u32, of: Enum_Type, member_number: u32, language: Language) -> string {
	if text, found := member_text(file, enum_index, member_number, language); found {
		return text
	}
	member, member_found := enum_member(file, of, member_number)
	if !member_found {
		return ""
	}
	return string_at(file, member.name_offset, member.name_count)
}
