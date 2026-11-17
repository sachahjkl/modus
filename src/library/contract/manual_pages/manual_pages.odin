// The format of the link pages of the manual (src/md/features/manual_links.md):
// the pages of the terms of the glossary, of the headings of the guides and
// of the declarations of the sources that no module describes, which the
// documentation of the modules of the boot image links, in one resource
// that the modus tool writes and the program `manual` reads in place. All
// numbers are little-endian.
//
//   Header      32 bytes, at 0
//   Page_Entry  24 bytes, page_count times, at 32, in the order of the bytes of their targets
//   text        text_size bytes, at text_offset: the targets, the titles and the texts
//
// A target is the target of a link as a comment writes it: `term:handle`,
// `docs/ARCHITECTURE.md#the-fault-ring`, `system.word_wait`. A title is one line. A text is
// Markdown of a source comment, with line feeds.
//
// A reader does not trust the file: `validate` checks each count, each
// range and each byte of text once, and the reads after it need no check.
//
// See [link page](term:link-page) and [resource](term:resource).
package manual_pages

import "modus:contract/byte_order"
import "modus:contract/text_encoding"

MAGIC :: u64(0x5345474150_4E414D) // The bytes "MANPAGES".
VERSION :: 1 // The version of the format. A reader refuses another.
HEADER_SIZE :: 32 // The bytes of `Header`.
PAGE_ENTRY_SIZE :: 24 // The bytes of `Page_Entry`.
PAGE_COUNT_LIMIT :: 1 << 14 // The pages of one file.
TARGET_SIZE_LIMIT :: 256 // The bytes of the longest target.
TITLE_SIZE_LIMIT :: 256 // The bytes of the longest title.
TEXT_SIZE_LIMIT :: 1 << 26 // The bytes of the text area.

// The name of the file in the resource table of the boot image.
RESOURCE_NAME :: "manual_pages"

// The prefix of a target that names a term of the glossary: "term:handle".
TERM_PREFIX :: "term:"
// The prefix of a target that names a guide, or a heading of it: "docs/ARCHITECTURE.md#the-fault-ring".
GUIDE_PREFIX :: "docs/"

Header :: struct #packed {
	magic:       u64, // MAGIC.
	version:     u32, // VERSION.
	page_count:  u32, // The entries after the header.
	text_offset: u32, // The first byte of the text area: HEADER_SIZE + page_count * PAGE_ENTRY_SIZE.
	text_size:   u32, // The bytes of the text area, to the end of the file.
	reserved:    u64, // 0.
}
#assert(size_of(Header) == HEADER_SIZE)

// One page. Each offset is from the start of the text area.
Page_Entry :: struct #packed {
	target_offset: u32,
	target_size:   u32, // 1 to TARGET_SIZE_LIMIT.
	title_offset:  u32,
	title_size:    u32, // 1 to TITLE_SIZE_LIMIT.
	text_offset:   u32,
	text_size:     u32, // 0 or more.
}
#assert(size_of(Page_Entry) == PAGE_ENTRY_SIZE)

// Why a file is not valid.
Problem :: enum u8 {
	None,
	Too_Short, // The file has no whole header.
	Magic, // The magic is not MAGIC.
	Version, // The version is not VERSION.
	Count, // The count of pages is over PAGE_COUNT_LIMIT, or the reserved field is not 0.
	Layout, // The text area does not start after the entries, or does not end at the end of the file.
	Range, // A target, a title or a text is outside the text area.
	Size, // A target or a title is empty, or longer than its limit.
	Not_Text, // A target or a title is not a text, or a line of a text is not a text.
	Order, // The targets are not in the order of their bytes, or two are the same.
}

// A valid file: the reads below take it.
Pages :: struct {
	file:  []u8,
	count: int,
	text:  []u8,
}

// The kinds of the target of a link (docs/SITE.md, "The links of a comment").
Link_Target_Kind :: enum u8 {
	Name, // A module, a module and its export, a record or another declaration: "manual.show", "information.Module".
	Address, // An address of another host: "https://...".
	Term, // A term of the glossary: "term:handle".
	Guide, // A guide, or a heading of it: "docs/ARCHITECTURE.md#the-fault-ring".
}

// link_target_kind gives the kind of the target of a link, by its prefix.
// The tool and the manual read a target with this one rule.
link_target_kind :: proc "contextless" (target: string) -> Link_Target_Kind {
	switch {
	case has_prefix(target, "https://") || has_prefix(target, "http://"):
		return .Address
	case has_prefix(target, TERM_PREFIX) && len(target) > len(TERM_PREFIX):
		return .Term
	case has_prefix(target, GUIDE_PREFIX) && len(target) > len(GUIDE_PREFIX):
		return .Guide
	}
	return .Name
}

@(private = "file")
has_prefix :: proc "contextless" (text, prefix: string) -> bool {
	return len(text) >= len(prefix) && text[:len(prefix)] == prefix
}

// bytes_compare gives the order of two texts by their bytes: negative when
// the first comes before the second, 0 when they are the same, positive
// after. The tool sorts the pages with the same rule.
bytes_compare :: proc "contextless" (first, second: string) -> int {
	for index in 0 ..< min(len(first), len(second)) {
		if first[index] != second[index] {
			return int(first[index]) - int(second[index])
		}
	}
	return len(first) - len(second)
}

// entry_at reads the entry of a page, by its index, from a file whose
// count the caller checked.
@(private = "file")
entry_at :: proc "contextless" (file: []u8, index: int) -> Page_Entry {
	at := HEADER_SIZE + index * PAGE_ENTRY_SIZE
	return {
		target_offset = byte_order.read_u32_little_endian(file, at),
		target_size = byte_order.read_u32_little_endian(file, at + 4),
		title_offset = byte_order.read_u32_little_endian(file, at + 8),
		title_size = byte_order.read_u32_little_endian(file, at + 12),
		text_offset = byte_order.read_u32_little_endian(file, at + 16),
		text_size = byte_order.read_u32_little_endian(file, at + 20),
	}
}

// range_inside says if a range is inside an area of `size` bytes, with no
// overflow.
@(private = "file")
range_inside :: proc "contextless" (offset, count: u32, size: int) -> bool {
	return u64(offset) <= u64(size) && u64(count) <= u64(size) - u64(offset)
}

// markdown_valid says if each line of a Markdown text is a text: line feeds
// end the lines, and no other control character is allowed.
markdown_valid :: proc "contextless" (bytes: []u8) -> bool {
	start := 0
	for index in 0 ..= len(bytes) {
		if index == len(bytes) || bytes[index] == '\n' {
			if !text_encoding.text_valid(bytes[start:index]) {
				return false
			}
			start = index + 1
		}
	}
	return true
}

// validate checks a file once: the header, each entry, each range, each
// byte of text, and the order of the targets.
validate :: proc "contextless" (file: []u8) -> (pages: Pages, problem: Problem) {
	if len(file) < HEADER_SIZE {
		return {}, .Too_Short
	}
	magic := byte_order.read_u64_little_endian(file, 0)
	if magic != MAGIC {
		return {}, .Magic
	}
	if byte_order.read_u32_little_endian(file, 8) != VERSION {
		return {}, .Version
	}
	count := byte_order.read_u32_little_endian(file, 12)
	text_offset := byte_order.read_u32_little_endian(file, 16)
	text_size := byte_order.read_u32_little_endian(file, 20)
	if count > PAGE_COUNT_LIMIT || byte_order.read_u32_little_endian(file, 24) != 0 || byte_order.read_u32_little_endian(file, 28) != 0 {
		return {}, .Count
	}
	if u64(text_offset) != u64(HEADER_SIZE) + u64(count) * PAGE_ENTRY_SIZE || text_size > TEXT_SIZE_LIMIT || u64(text_offset) + u64(text_size) != u64(len(file)) {
		return {}, .Layout
	}
	text := file[text_offset:]
	previous: string
	for index in 0 ..< int(count) {
		entry := entry_at(file, index)
		if entry.target_size == 0 || entry.target_size > TARGET_SIZE_LIMIT || entry.title_size == 0 || entry.title_size > TITLE_SIZE_LIMIT {
			return {}, .Size
		}
		if !range_inside(entry.target_offset, entry.target_size, len(text)) || !range_inside(entry.title_offset, entry.title_size, len(text)) || !range_inside(entry.text_offset, entry.text_size, len(text)) {
			return {}, .Range
		}
		target := text[entry.target_offset:][:entry.target_size]
		title := text[entry.title_offset:][:entry.title_size]
		if !text_encoding.text_valid(target) || !text_encoding.text_valid(title) || !markdown_valid(text[entry.text_offset:][:entry.text_size]) {
			return {}, .Not_Text
		}
		if index > 0 && bytes_compare(previous, string(target)) >= 0 {
			return {}, .Order
		}
		previous = string(target)
	}
	return {file = file, count = int(count), text = text}, .None
}

// target_of gives the target of a page of a valid file.
target_of :: proc "contextless" (pages: Pages, index: int) -> string {
	if index < 0 || index >= pages.count {
		return ""
	}
	entry := entry_at(pages.file, index)
	return string(pages.text[entry.target_offset:][:entry.target_size])
}

// title_of gives the title of a page of a valid file.
title_of :: proc "contextless" (pages: Pages, index: int) -> string {
	if index < 0 || index >= pages.count {
		return ""
	}
	entry := entry_at(pages.file, index)
	return string(pages.text[entry.title_offset:][:entry.title_size])
}

// text_of gives the Markdown text of a page of a valid file.
text_of :: proc "contextless" (pages: Pages, index: int) -> string {
	if index < 0 || index >= pages.count {
		return ""
	}
	entry := entry_at(pages.file, index)
	return string(pages.text[entry.text_offset:][:entry.text_size])
}

// find gives the index of the page of a target, by a search in the order
// of the targets.
find :: proc "contextless" (pages: Pages, target: string) -> (index: int, found: bool) {
	low, high := 0, pages.count
	for low < high {
		middle := low + (high - low) / 2
		order := bytes_compare(target_of(pages, middle), target)
		switch {
		case order == 0:
			return middle, true
		case order < 0:
			low = middle + 1
		case:
			high = middle
		}
	}
	return -1, false
}

// One page that a writer gives to `encode`.
Page_Source :: struct {
	target, title, text: string,
}

// encoded_size gives the bytes of the file of these pages.
encoded_size :: proc "contextless" (sources: []Page_Source) -> int {
	size := HEADER_SIZE + len(sources) * PAGE_ENTRY_SIZE
	for source in sources {
		size += len(source.target) + len(source.title) + len(source.text)
	}
	return size
}

// encode writes the file of these pages into a buffer of encoded_size
// bytes. The pages must be in the order of the bytes of their targets. It
// gives false, and writes nothing that a reader takes, when a page breaks
// a rule of `validate` or the buffer is too small.
encode :: proc "contextless" (sources: []Page_Source, buffer: []u8) -> bool {
	size := encoded_size(sources)
	if len(sources) > PAGE_COUNT_LIMIT || len(buffer) < size {
		return false
	}
	text_offset := HEADER_SIZE + len(sources) * PAGE_ENTRY_SIZE
	if size - text_offset > TEXT_SIZE_LIMIT {
		return false
	}
	file := buffer[:size]
	byte_order.write_u64_little_endian(file, 0, MAGIC)
	byte_order.write_u32_little_endian(file, 8, VERSION)
	byte_order.write_u32_little_endian(file, 12, u32(len(sources)))
	byte_order.write_u32_little_endian(file, 16, u32(text_offset))
	byte_order.write_u32_little_endian(file, 20, u32(size - text_offset))
	byte_order.write_u32_little_endian(file, 24, 0)
	byte_order.write_u32_little_endian(file, 28, 0)
	at := 0
	text := file[text_offset:]
	for source, index in sources {
		entry := HEADER_SIZE + index * PAGE_ENTRY_SIZE
		byte_order.write_u32_little_endian(file, entry, u32(at))
		byte_order.write_u32_little_endian(file, entry + 4, u32(len(source.target)))
		at += copy(text[at:], source.target)
		byte_order.write_u32_little_endian(file, entry + 8, u32(at))
		byte_order.write_u32_little_endian(file, entry + 12, u32(len(source.title)))
		at += copy(text[at:], source.title)
		byte_order.write_u32_little_endian(file, entry + 16, u32(at))
		byte_order.write_u32_little_endian(file, entry + 20, u32(len(source.text)))
		at += copy(text[at:], source.text)
	}
	_, problem := validate(file)
	if problem != .None {
		file[0] = 0 // A reader refuses the magic.
		return false
	}
	return true
}
