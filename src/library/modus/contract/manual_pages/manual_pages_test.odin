#+build !freestanding
#+build !modus
package manual_pages

import "core:testing"

// sample_file makes a valid file of three pages, in the order of their
// targets.
@(private = "file")
sample_file :: proc() -> []u8 {
	sources := [?]Page_Source {
		{target = "docs/ARCHITECTURE.md#the-fault-ring", title = "The fault ring", text = "A ring of **faults**.\n\n- one\n- two"},
		{target = "term:handle", title = "Handle", text = "A handle names an object."},
		{target = "term:ring", title = "Ring", text = ""},
	}
	file := make([]u8, encoded_size(sources[:]))
	if !encode(sources[:], file) {
		return nil
	}
	return file
}

@(test)
a_sample_file_is_valid_and_its_pages_are_found :: proc(t: ^testing.T) {
	file := sample_file()
	defer delete(file)
	testing.expect(t, file != nil)
	pages, problem := validate(file)
	testing.expect_value(t, problem, Problem.None)
	testing.expect_value(t, pages.count, 3)
	index, found := find(pages, "term:handle")
	testing.expect(t, found)
	testing.expect_value(t, title_of(pages, index), "Handle")
	testing.expect_value(t, text_of(pages, index), "A handle names an object.")
	index, found = find(pages, "docs/ARCHITECTURE.md#the-fault-ring")
	testing.expect(t, found)
	testing.expect_value(t, text_of(pages, index), "A ring of **faults**.\n\n- one\n- two")
	index, found = find(pages, "term:ring")
	testing.expect(t, found)
	testing.expect_value(t, text_of(pages, index), "")
	_, found = find(pages, "term:nothing")
	testing.expect(t, !found)
	_, found = find(pages, "")
	testing.expect(t, !found)
	testing.expect_value(t, target_of(pages, pages.count), "")
	testing.expect_value(t, title_of(pages, -1), "")
}

@(test)
the_kind_of_a_target_is_read_from_its_prefix :: proc(t: ^testing.T) {
	testing.expect_value(t, link_target_kind("https://www.rfc-editor.org/rfc/rfc8439"), Link_Target_Kind.Address)
	testing.expect_value(t, link_target_kind("http://example.org"), Link_Target_Kind.Address)
	testing.expect_value(t, link_target_kind("term:handle"), Link_Target_Kind.Term)
	testing.expect_value(t, link_target_kind("docs/ARCHITECTURE.md#the-fault-ring"), Link_Target_Kind.Guide)
	testing.expect_value(t, link_target_kind("docs/ARCHITECTURE.md"), Link_Target_Kind.Guide)
	testing.expect_value(t, link_target_kind("manual.show"), Link_Target_Kind.Name)
	testing.expect_value(t, link_target_kind("information.Module"), Link_Target_Kind.Name)
	// A prefix with nothing after it names nothing of its kind.
	testing.expect_value(t, link_target_kind("term:"), Link_Target_Kind.Name)
	testing.expect_value(t, link_target_kind("docs/"), Link_Target_Kind.Name)
	testing.expect_value(t, link_target_kind(""), Link_Target_Kind.Name)
	testing.expect_value(t, link_target_kind("https:/"), Link_Target_Kind.Name)
}

// A file from the boot image is not trusted: each field that a hostile
// file can change is refused, and the reader never reads outside it.
@(test)
a_hostile_file_is_refused :: proc(t: ^testing.T) {
	file := sample_file()
	defer delete(file)
	changed := make([]u8, len(file))
	defer delete(changed)

	word :: proc(bytes: []u8, offset: int, value: u32) {
		bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3] = u8(value), u8(value >> 8), u8(value >> 16), u8(value >> 24)
	}
	expect_problem :: proc(t: ^testing.T, bytes: []u8, wanted: Problem, loc := #caller_location) {
		_, problem := validate(bytes)
		testing.expect_value(t, problem, wanted, loc = loc)
	}

	expect_problem(t, file[:HEADER_SIZE - 1], .Too_Short)
	expect_problem(t, nil, .Too_Short)

	copy(changed, file)
	changed[0] ~= 1
	expect_problem(t, changed, .Magic)

	copy(changed, file)
	word(changed, 8, VERSION + 1)
	expect_problem(t, changed, .Version)

	copy(changed, file)
	word(changed, 12, PAGE_COUNT_LIMIT + 1)
	expect_problem(t, changed, .Count)

	copy(changed, file)
	changed[24] = 1
	expect_problem(t, changed, .Count)

	// A count that does not match the place of the text.
	copy(changed, file)
	word(changed, 12, 2)
	expect_problem(t, changed, .Layout)

	// A text area that ends before the end of the file, or after it.
	expect_problem(t, file[:len(file) - 1], .Layout)
	copy(changed, file)
	word(changed, 20, 0xFFFF_FFF0)
	expect_problem(t, changed, .Layout)

	text_offset := HEADER_SIZE + 3 * PAGE_ENTRY_SIZE
	text_size := len(file) - text_offset

	// A range past the end of the text area, and one whose sum overflows.
	copy(changed, file)
	word(changed, HEADER_SIZE + 16, u32(text_size))
	word(changed, HEADER_SIZE + 20, 1)
	expect_problem(t, changed, .Range)
	copy(changed, file)
	word(changed, HEADER_SIZE + 0, 0xFFFF_FFFF)
	word(changed, HEADER_SIZE + 4, 2)
	expect_problem(t, changed, .Range)

	// An empty target, and a title over its limit.
	copy(changed, file)
	word(changed, HEADER_SIZE + 4, 0)
	expect_problem(t, changed, .Size)
	copy(changed, file)
	word(changed, HEADER_SIZE + 12, TITLE_SIZE_LIMIT + 1)
	expect_problem(t, changed, .Size)

	// A control character in a target, a cut character in a title, and a
	// tab in a line of a text.
	copy(changed, file)
	changed[text_offset] = 0x07
	expect_problem(t, changed, .Not_Text)
	copy(changed, file)
	title_offset := text_offset + len("docs/ARCHITECTURE.md#the-fault-ring")
	changed[title_offset] = 0xC3
	expect_problem(t, changed, .Not_Text)
	copy(changed, file)
	changed[title_offset + len("The fault ring")] = '\t'
	expect_problem(t, changed, .Not_Text)

	// Two entries in the wrong order, and two with one target.
	copy(changed, file)
	copy(changed[HEADER_SIZE:][:PAGE_ENTRY_SIZE], file[HEADER_SIZE + PAGE_ENTRY_SIZE:][:PAGE_ENTRY_SIZE])
	copy(changed[HEADER_SIZE + PAGE_ENTRY_SIZE:][:PAGE_ENTRY_SIZE], file[HEADER_SIZE:][:PAGE_ENTRY_SIZE])
	expect_problem(t, changed, .Order)
	copy(changed, file)
	copy(changed[HEADER_SIZE + PAGE_ENTRY_SIZE:][:PAGE_ENTRY_SIZE], file[HEADER_SIZE:][:PAGE_ENTRY_SIZE])
	expect_problem(t, changed, .Order)
}

@(test)
encode_refuses_what_validate_refuses :: proc(t: ^testing.T) {
	buffer: [1024]u8
	unordered := [?]Page_Source{{target = "term:ring", title = "Ring"}, {target = "term:handle", title = "Handle"}}
	testing.expect(t, !encode(unordered[:], buffer[:]))
	no_title := [?]Page_Source{{target = "term:ring"}}
	testing.expect(t, !encode(no_title[:], buffer[:]))
	control := [?]Page_Source{{target = "term:ring", title = "Ring", text = "a\x01b"}}
	testing.expect(t, !encode(control[:], buffer[:]))
	small := [?]Page_Source{{target = "term:ring", title = "Ring", text = "A ring."}}
	testing.expect(t, !encode(small[:], buffer[:HEADER_SIZE]))
	testing.expect(t, encode(small[:], buffer[:]))
}
