#+build !freestanding
#+build !modus
package module

import "core:testing"

// category_test_file gives the least valid module file, a header and an
// empty table directory, with a category word, a tag word and a reserved
// byte written as numbers: a value that names no member too.
@(private = "file")
category_test_file :: proc(category_word: u8, tag_word: u16, reserved: u8) -> [size_of(Header) + TABLE_COUNT * size_of(Table_Entry)]u8 {
	file: [size_of(Header) + TABLE_COUNT * size_of(Table_Entry)]u8
	head := Header {
		magic       = MAGIC,
		version     = VERSION,
		header_size = size_of(Header),
		machine     = .X86_64,
		table_count = TABLE_COUNT,
	}
	(^Header)(&file[0])^ = head
	file[offset_of(Header, category)] = category_word
	file[offset_of(Header, reserved)] = reserved
	(^u16)(&file[offset_of(Header, tags)])^ = tag_word
	return file
}

// The border of the category and of the tags is the header: a word one past
// the last category, the largest byte, a tag bit one past the last tag, the
// highest bit, every bit, a reserved byte of 1 and the largest are each
// refused by header alone, and so by validate and by the reader, which then
// gives no category. The last cases are taken:
// None, each category, each tag at once.
@(test)
a_category_or_a_tag_that_names_nothing_is_refused :: proc(t: ^testing.T) {
	Case :: struct {
		category: u8,
		tags:     u16,
		reserved: u8,
	}
	refused := []Case {
		{category = u8(max(Module_Category)) + 1},
		{category = max(u8)},
		{tags = 1 << len(Module_Tag)},
		{tags = 1 << 15},
		{tags = max(u16)},
		{reserved = 1},
		{reserved = max(u8)},
	}
	for item in refused {
		file := category_test_file(item.category, item.tags, item.reserved)
		_, header_error := header(file[:])
		testing.expectf(t, header_error == .Unknown_Category, "%v is not refused by the header: %v", item, header_error)
		testing.expectf(t, validate(file[:]) == .Unknown_Category, "%v is not refused: %v", item, validate(file[:]))
		category, tags, ok := module_category_of(file[:])
		testing.expectf(t, !ok && category == .None && tags == {}, "%v gives a category", item)
	}
	for category in Module_Category {
		file := category_test_file(u8(category), MODULE_TAG_BITS, 0)
		testing.expect_value(t, validate(file[:]), Error.None)
		read, tags, ok := module_category_of(file[:])
		testing.expect(t, ok && read == category && card(tags) == len(Module_Tag))
	}
	// A file that the header refuses gives no category.
	_, _, ok := module_category_of(nil)
	testing.expect(t, !ok)
}
