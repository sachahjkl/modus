package module

import "modus:contract/language_tag"
import "modus:contract/text_encoding"

// The display texts of the members (src/md/features/enum_parameters.md,
// "The display text of a member"): a member has a name, which a line types
// and a module compiles, and a display text, which a principal reads. The
// texts are a table of their own, apart from the enum, by member and by
// language tag (BCP 47): a translation is more rows, with no change of the
// code, of the names or of the format.

// The tag that a reader tries after the tags of the principal: each module
// of the system gives its texts in English.
FALLBACK_TAG :: "en"

MEMBER_TEXT_CAPACITY :: 24 // The bytes of a display text at most: one button of a row of the palette.

// One display text: a member of an enum in a language.
//
// Example: the scale `.fourteen_eighths` of the module settings has the
// text "1.75" for the tag `en`.
Member_Text :: struct {
	enum_index:    u32, // An index in the table Enums, from 1.
	member_number: u32, // The member in its enum, from 0.
	text_offset:   u32, // In the string table.
	text_count:    u32, // From 1 to MEMBER_TEXT_CAPACITY bytes of a display text (text_encoding.display_text_valid).
	tag_offset:    u32, // In the string table.
	tag_count:     u32, // From 1 to language_tag.TAG_CAPACITY bytes of a well-formed language tag in its canonical case (language_tag.canonical_check).
}
#assert(size_of(Member_Text) == 24)

// What member_texts_check refuses in a row.
Member_Text_Problem :: enum u8 {
	None         = 0, // The row keeps each rule.
	No_Enum      = 1, // The enum index names no valid enum of the table Enums.
	No_Member    = 2, // The member number is past the members of its enum.
	Bad_Text     = 3, // The text is empty, past MEMBER_TEXT_CAPACITY, outside the string table, or no display text: not UTF-8 with no control character, a hidden character, or spaces only (text_encoding.display_text_valid).
	Bad_Tag      = 4, // The tag is outside the string table, not well-formed, or not in its canonical case (language_tag.canonical_check).
	Twice        = 5, // The row has the enum, the member and the tag of the row before it.
	Out_Of_Order = 6, // The row comes before the row before it, in the order of the enum, the member and the bytes of the tag.
}

// member_text_order compares the key of a row with a key: the enum, then
// the member, then the bytes of the tag, which each row stores in its
// canonical case. It gives -1, 0 or 1. The writer of module files and the
// build order their parts with it.
member_text_order :: proc "contextless" (enum_index, member_number: u32, tag: string, other_enum, other_member: u32, other_tag: string) -> int {
	high := u64(enum_index) << 32 | u64(member_number)
	other_high := u64(other_enum) << 32 | u64(other_member)
	switch {
	case high < other_high:
		return -1
	case high > other_high:
		return 1
	case tag < other_tag:
		return -1
	case tag > other_tag:
		return 1
	}
	return 0
}

// member_text_row gives the row index of the table Member_Texts, from 1,
// its tag and its text, after it checked the row alone: its enum, its
// member, its tag and its text. The order of the rows is the part of
// member_texts_check.
member_text_row :: proc "contextless" (file: []u8, index: u32) -> (row: Member_Text, tag: string, text: string, problem: Member_Text_Problem) {
	found: bool
	row, found = record(file, .Member_Texts, index, Member_Text)
	if index == 0 || !found {
		return {}, "", "", .No_Enum
	}
	described, enum_problem := enum_type(file, row.enum_index)
	tag, text, problem = member_text_row_of_enum(file, row, described, enum_problem)
	return row, tag, text, problem
}

// member_text_row_of_enum checks a row whose enum the caller read with
// enum_type: the rows of one enum follow each other, so a check of each
// row reads each enum once, when the enum index changes.
@(private)
member_text_row_of_enum :: proc "contextless" (file: []u8, row: Member_Text, described: Enum_Type, enum_problem: Enum_Problem) -> (tag: string, text: string, problem: Member_Text_Problem) {
	if enum_problem != .None {
		return "", "", .No_Enum
	}
	if row.member_number >= described.member_count {
		return "", "", .No_Member
	}
	tag = string_at(file, row.tag_offset, row.tag_count)
	if u32(len(tag)) != row.tag_count || language_tag.canonical_check(tag) != .None {
		return "", "", .Bad_Tag
	}
	text = string_at(file, row.text_offset, row.text_count)
	if row.text_count == 0 || row.text_count > MEMBER_TEXT_CAPACITY || u32(len(text)) != row.text_count || !text_encoding.display_text_valid(transmute([]u8)text) {
		return "", "", .Bad_Text
	}
	return tag, text, .None
}

// member_texts_check checks each row of the table Member_Texts, and that
// each row comes after the row before it: two rows for one member and one
// tag are refused. It gives the first row that breaks a rule, from 1, and
// why; 0 and None for a file whose rows keep each rule, or that has no row.
member_texts_check :: proc "contextless" (file: []u8) -> (row_index: u32, problem: Member_Text_Problem) {
	before: Member_Text
	before_tag: string
	// The enum of the row before, read once for the rows that follow it.
	described: Enum_Type
	enum_problem: Enum_Problem
	enum_read := false
	for index in u32(1) ..< count(file, .Member_Texts) {
		row, _ := record(file, .Member_Texts, index, Member_Text)
		if !enum_read || before.enum_index != row.enum_index {
			described, enum_problem = enum_type(file, row.enum_index)
			enum_read = true
		}
		tag, _, row_problem := member_text_row_of_enum(file, row, described, enum_problem)
		if row_problem != .None {
			return index, row_problem
		}
		if index > 1 {
			switch member_text_order(row.enum_index, row.member_number, tag, before.enum_index, before.member_number, before_tag) {
			case 0:
				return index, .Twice
			case -1:
				return index, .Out_Of_Order
			}
		}
		before, before_tag = row, tag
	}
	return 0, .None
}

// member_text gives the display text of a member for a list of language
// tags, in the order of the preference of the principal, as the Lookup of
// RFC 4647 does: each tag, then each shorter tag (`zh-Hant-TW`, `zh-Hant`,
// `zh`), then the next tag, and FALLBACK_TAG last. A tag that is not
// well-formed is passed over whole. found is false when the
// module gives no text for any of them, or each row that matched breaks a
// rule: the reader then shows the name.
member_text :: proc "contextless" (file: []u8, enum_index, member_number: u32, tags: []string) -> (text: string, found: bool) {
	for index in 0 ..= len(tags) {
		tag := index < len(tags) ? tags[index] : FALLBACK_TAG
		// A tag that is not well-formed names no language: its pieces
		// are no shorter tags of it.
		if language_tag.problem(tag) != .None {
			continue
		}
		for {
			if text, found = member_text_of_tag(file, enum_index, member_number, tag); found {
				return
			}
			shorter, has_shorter := language_tag.lookup_shorter(tag)
			if !has_shorter {
				break
			}
			tag = shorter
		}
	}
	return "", false
}

// member_text_of_tag gives the display text of the row of a member for one
// tag, in any case, with no shorter tag and no other tag after it: the key
// of the row is the enum, the member and the canonical tag. The rows are in
// order, so a binary search finds one.
member_text_of_tag :: proc "contextless" (file: []u8, enum_index, member_number: u32, tag: string) -> (text: string, found: bool) {
	buffer: [language_tag.TAG_CAPACITY]u8
	wanted, canonical := language_tag.canonical(tag, buffer[:])
	if !canonical {
		return "", false
	}
	low, high := u32(1), count(file, .Member_Texts)
	for low < high {
		middle := low + (high - low) / 2
		row, row_found := record(file, .Member_Texts, middle, Member_Text)
		if !row_found {
			return "", false
		}
		row_tag := string_at(file, row.tag_offset, row.tag_count)
		switch member_text_order(row.enum_index, row.member_number, row_tag, enum_index, member_number, wanted) {
		case 0:
			_, _, row_text, problem := member_text_row(file, middle)
			return row_text, problem == .None
		case -1:
			low = middle + 1
		case:
			high = middle
		}
	}
	return "", false
}

// member_display_text gives what a principal reads for the member number of
// an enum: its display text for the tags, else for FALLBACK_TAG, else its
// name. A line never types the result: it types the name.
member_display_text :: proc "contextless" (file: []u8, enum_index: u32, of: Enum_Type, member_number: u32, tags: []string) -> string {
	if text, found := member_text(file, enum_index, member_number, tags); found {
		return text
	}
	member, member_found := enum_member(file, of, member_number)
	if !member_found {
		return ""
	}
	return string_at(file, member.name_offset, member.name_count)
}
