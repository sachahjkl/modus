package modustool

import "core:strings"
import "core:testing"
import "modus:contract/manual_pages"

// The documents of the tests: a glossary of two terms in two groups, and
// one guide.
@(private = "file")
manual_test_read :: proc(path: string) -> (text: string, ok: bool) {
	switch path {
	case GLOSSARY_INDEX_FILE:
		return `# Glossary

The terms.

## The groups

- [Code](code.md)
- [Communication](communication.md): the rings.
`, true
	case GLOSSARY_FOLDER + "/code.md":
		return `## Code

### Handle

A handle names an object of the kernel in a table of a process.

A process passes a handle to an operation.

| Field | Meaning |
|---|---|
| rights | what it allows |

Do not use: descriptor.
`, true
	case GLOSSARY_FOLDER + "/communication.md":
		return `## Communication

### Ring

A ring is a queue of records in shared memory.
`, true
	case "docs/SAMPLE.md":
		return `# The sample guide

The guide starts here.

## 1. The fault ring

A ring of faults, as in [the storage](STORAGE.md#4-7-the-same-object) and [here](#2-the-end).

> A quote.

| Kind | Size |
|---|---|
| Page | 4 KiB |
| Ring \| table | 64 |

### The record

One record for each fault.

` + "```" + `
	not a heading:
# inside a fence
` + "```" + `

### The record

The second heading of one text.

#### A deep part

Deep.

## 2. The end

The end.
`, true
	}
	return "", false
}

@(test)
manual_link_pages_of_a_term_and_of_a_guide :: proc(t: ^testing.T) {
	targets := []string {
		"term:handle",
		"term:Ring",
		"docs/SAMPLE.md#1-the-fault-ring",
		"manual.show", // A name with no declaration and no reader of the sources: no page.
		"https://example.org", // An address: shown, never a page.
		"term:nothing",
		"docs/SAMPLE.md#no-such-heading",
		"docs/ABSENT.md",
		"term:handle", // A target twice is one page.
	}
	pages, missing := manual_link_pages_of_targets(targets, {documents = manual_test_read})
	page_of :: proc(pages: []manual_pages.Page_Source, target: string) -> (manual_pages.Page_Source, bool) {
		for page in pages {
			if page.target == target {
				return page, true
			}
		}
		return {}, false
	}

	testing.expect_value(t, len(missing), 4)
	if len(missing) == 4 {
		testing.expect_value(t, missing[0], "docs/ABSENT.md")
		testing.expect_value(t, missing[1], "docs/SAMPLE.md#no-such-heading")
		testing.expect_value(t, missing[2], "manual.show")
		testing.expect_value(t, missing[3], "term:nothing")
	}
	// The pages are in the order of the bytes of their targets.
	for index in 1 ..< len(pages) {
		testing.expect(t, manual_pages.bytes_compare(pages[index - 1].target, pages[index].target) < 0)
	}

	handle, found := page_of(pages, "term:handle")
	testing.expect(t, found)
	testing.expect_value(t, handle.title, "Handle")
	testing.expect_value(t, handle.text, "A handle names an object of the kernel in a table of a process.\n\nA process passes a handle to an operation.\n\n- Field; Meaning\n- rights; what it allows")
	ring, ring_found := page_of(pages, "term:Ring")
	testing.expect(t, ring_found)
	testing.expect_value(t, ring.text, "A ring is a queue of records in shared memory.")

	section, section_found := page_of(pages, "docs/SAMPLE.md#1-the-fault-ring")
	testing.expect(t, section_found)
	testing.expect_value(t, section.title, "1. The fault ring")
	expected := "A ring of faults, as in [the storage](docs/STORAGE.md#4-7-the-same-object) and [here](docs/SAMPLE.md#2-the-end).\n\nA quote.\n\n- Kind; Size\n- Page; 4 KiB\n- Ring | table; 64\n\n- [The record](docs/SAMPLE.md#the-record)\n- [The record](docs/SAMPLE.md#the-record-2)"
	testing.expect_value(t, section.text, expected)

	// The headings directly under a section have their pages; a heading
	// in a fence is no heading, and a deeper heading is a page of its
	// parent only.
	first, first_found := page_of(pages, "docs/SAMPLE.md#the-record")
	testing.expect(t, first_found)
	testing.expect(t, strings.contains(first.text, "One record for each fault."))
	testing.expect(t, strings.contains(first.text, "# inside a fence"))
	testing.expect(t, strings.contains(first.text, "    not a heading:"))
	second, second_found := page_of(pages, "docs/SAMPLE.md#the-record-2")
	testing.expect(t, second_found)
	testing.expect_value(t, second.text, "The second heading of one text.\n\n- [A deep part](docs/SAMPLE.md#a-deep-part)")
	_, deep_found := page_of(pages, "docs/SAMPLE.md#a-deep-part")
	testing.expect(t, deep_found)
	// A heading beside the section is not under it.
	_, end_found := page_of(pages, "docs/SAMPLE.md#2-the-end")
	testing.expect(t, !end_found)
	testing.expect_value(t, len(pages), 6)

	// The pages make a valid file of the format.
	buffer := make([]u8, manual_pages.encoded_size(pages), context.temp_allocator)
	testing.expect(t, manual_pages.encode(pages, buffer))
	read, problem := manual_pages.validate(buffer)
	testing.expect_value(t, problem, manual_pages.Problem.None)
	index, in_file := manual_pages.find(read, "docs/SAMPLE.md#1-the-fault-ring")
	testing.expect(t, in_file)
	testing.expect_value(t, manual_pages.text_of(read, index), expected)
}

@(test)
manual_link_pages_of_a_whole_guide :: proc(t: ^testing.T) {
	targets := []string{"docs/SAMPLE.md"}
	pages, missing := manual_link_pages_of_targets(targets, {documents = manual_test_read})
	testing.expect_value(t, len(missing), 0)
	for page in pages {
		if page.target == "docs/SAMPLE.md" {
			testing.expect_value(t, page.title, "The sample guide")
			testing.expect_value(t, page.text, "The guide starts here.\n\n- [1. The fault ring](docs/SAMPLE.md#1-the-fault-ring)\n- [2. The end](docs/SAMPLE.md#2-the-end)")
		}
	}
	// The guide, its two sections, the two headings of the first and the
	// deep part.
	testing.expect_value(t, len(pages), 6)
}

// The sources of the tests: one file of a support package, with a
// procedure that has a comment and a constant that has none.
@(private = "file")
MANUAL_TEST_SOURCE_PATH :: "src/library/support/system/wait.odin"
@(private = "file")
MANUAL_TEST_SOURCE :: `package system

// word_wait stops the thread while the word holds value.
// Read the word **again** after the wait: see [handle](term:handle).
word_wait :: proc "contextless" (word: ^u32, value: u32) -> u64 {
	return 0
}

WAIT_FOREVER :: ~u64(0)
`

@(private = "file")
manual_test_declarations :: proc(names: []string) -> (index: Site_Declaration_Index, ok: bool) {
	index = site_declaration_index_make()
	found, parsed := site_declarations_of_file(MANUAL_TEST_SOURCE_PATH, MANUAL_TEST_SOURCE)
	if !parsed {
		return index, false
	}
	for declaration in found {
		site_declaration_add(&index, declaration)
	}
	return index, true
}

@(test)
manual_link_pages_of_a_declaration :: proc(t: ^testing.T) {
	targets := []string {
		"system.word_wait",
		"system.WAIT_FOREVER",
		"word_wait()", // The same declaration by another target: a page of its own target.
		"system.word_wake", // No declaration has the name: no page.
		"other.word_wait", // No package of the name: no page.
	}
	pages, missing := manual_link_pages_of_targets(targets, {documents = manual_test_read, declarations = manual_test_declarations})
	page_of :: proc(pages: []manual_pages.Page_Source, target: string) -> (manual_pages.Page_Source, bool) {
		for page in pages {
			if page.target == target {
				return page, true
			}
		}
		return {}, false
	}
	testing.expect_value(t, len(pages), 3)
	testing.expect_value(t, len(missing), 2)
	if len(missing) == 2 {
		testing.expect_value(t, missing[0], "other.word_wait")
		testing.expect_value(t, missing[1], "system.word_wake")
	}

	wait, found := page_of(pages, "system.word_wait")
	testing.expect(t, found)
	testing.expect_value(t, wait.title, "system.word_wait")
	// The kind, the file and the line; the one line of Odin in a block; the
	// comment as its author wrote it. The link of the comment stays: the
	// tool walks no link of a declaration.
	testing.expect(t, strings.has_prefix(wait.text, "A procedure of `" + MANUAL_TEST_SOURCE_PATH + "`, line 5.\n\n```odin\nword_wait :: proc \"contextless\" ("))
	testing.expect(t, strings.contains(wait.text, "-> u64\n```\n\n"))
	testing.expect(t, strings.has_suffix(wait.text, "\n```\n\nword_wait stops the thread while the word holds value.\nRead the word **again** after the wait: see [handle](term:handle)."))
	_, term_found := page_of(pages, "term:handle")
	testing.expect(t, !term_found)

	called, called_found := page_of(pages, "word_wait()")
	testing.expect(t, called_found)
	testing.expect_value(t, called.title, "system.word_wait")
	testing.expect_value(t, called.text, wait.text)

	constant, constant_found := page_of(pages, "system.WAIT_FOREVER")
	testing.expect(t, constant_found)
	testing.expect(t, strings.has_prefix(constant.text, "A constant of `" + MANUAL_TEST_SOURCE_PATH + "`, line 9.\n\n```odin\nWAIT_FOREVER :: "))
	testing.expect(t, strings.has_suffix(constant.text, "\n```\n\nIt has no comment in its source."))

	// The pages make a valid file, and the manual finds each one by the
	// target of its link.
	buffer := make([]u8, manual_pages.encoded_size(pages), context.temp_allocator)
	testing.expect(t, manual_pages.encode(pages, buffer))
	read, problem := manual_pages.validate(buffer)
	testing.expect_value(t, problem, manual_pages.Problem.None)
	index, in_file := manual_pages.find(read, "system.word_wait")
	testing.expect(t, in_file)
	testing.expect_value(t, manual_pages.title_of(read, index), "system.word_wait")
	testing.expect_value(t, manual_pages.link_target_kind("system.word_wait"), manual_pages.Link_Target_Kind.Name)
}

@(test)
manual_name_with_no_module_is_not_described :: proc(t: ^testing.T) {
	// A module file that is not valid describes nothing, even with the
	// name of the target.
	modules := []Manual_Module_File{{name = "system", file = []u8{1, 2, 3}}}
	testing.expect(t, !manual_name_described(modules, "system"))
	testing.expect(t, !manual_name_described(modules, "system.word_wait"))
	testing.expect(t, !manual_name_described(nil, "information.Module"))
}

@(test)
manual_markdown_of_a_guide_keeps_what_the_reader_reads :: proc(t: ^testing.T) {
	testing.expect_value(t, manual_target_from_root("STORAGE.md#x", "docs/A.md"), "docs/STORAGE.md#x")
	testing.expect_value(t, manual_target_from_root("#x", "docs/A.md"), "docs/A.md#x")
	testing.expect_value(t, manual_target_from_root("../src/md/README.md", "docs/A.md"), "../src/md/README.md")
	testing.expect_value(t, manual_target_from_root("https://example.org/a.md", "docs/A.md"), "https://example.org/a.md")
	testing.expect_value(t, manual_target_from_root("term:ring", "docs/A.md"), "term:ring")
	testing.expect_value(t, manual_target_from_root("manual.show", "docs/A.md"), "manual.show")
	// A title has no marks of Markdown and no tab.
	testing.expect_value(t, manual_title_of("The `ring` of **faults**"), "The ring of faults")
	testing.expect(t, manual_table_separator("|---|:--:|"))
	testing.expect(t, !manual_table_separator("| a | b |"))
	testing.expect(t, !manual_table_separator("|  |"))
	// A label of a heading with brackets does not end its link.
	testing.expect_value(t, manual_link_label_of("A [b] c"), "A (b) c")
}
