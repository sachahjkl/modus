package output

import "base:intrinsics"
import "modus:contract/text_encoding"

// The names of the source of a wiring, for its reader
// (src/md/features/module_outputs.md, "The collector"). The collector keys
// a space by the name of the source process and the name of its record
// output, and a reader has no way to learn them: the writer could lie, and
// the asker names a process by a handle. So the root service writes them,
// after the terms, in the page of the terms of each reader end that takes
// terms. The page is given with Read only: the reader cannot change them,
// and the writer never sees the page.
//
// The page holds the terms at offset 0, at most module.RECORD_SIZE_LIMIT
// bytes, and this record at SOURCE_NAMES_OFFSET, its last 64 bytes.

// The bytes of each name: a name of a process or of a record output is an
// identifier of at most SOURCE_NAME_BYTES - 1 bytes, then zero bytes.
SOURCE_NAME_BYTES :: 32

// The names in the page of the terms of a reader end.
Source_Names :: struct {
	source: [SOURCE_NAME_BYTES]u8, // The module name of the writer process.
	output: [SOURCE_NAME_BYTES]u8, // The name of its record output, or `log`.
}
#assert(size_of(Source_Names) == 64)

// The page of the terms is one page: the names take its last bytes, after
// the largest terms.
SOURCE_NAMES_PAGE_BYTES :: 4096
SOURCE_NAMES_OFFSET :: SOURCE_NAMES_PAGE_BYTES - size_of(Source_Names)
#assert(SOURCE_NAMES_OFFSET >= 256)

// The name of the record output `log`, which no module declares.
LOG_OUTPUT_NAME :: "log"

// source_name_field_check gives the length of the name in one field, and
// refuses a field with no name, a name of the whole field (no zero after
// it), a byte that is not a visible character of ASCII, and a byte after
// the name that is not 0.
@(private = "file")
source_name_field_check :: proc "contextless" (field: []u8) -> (length: int, ok: bool) {
	for length < len(field) && field[length] != 0 {
		length += 1
	}
	if length == 0 || length >= len(field) || !text_encoding.identifier_valid(field[:length]) {
		return 0, false
	}
	for value in field[length:] {
		if value != 0 {
			return 0, false
		}
	}
	return length, true
}

// source_names_of_bytes checks the names, and gives the length of each.
source_names_of_bytes :: proc "contextless" (names: Source_Names) -> (source_length: int, output_length: int, ok: bool) {
	copy_of_names := names
	source_length = source_name_field_check(copy_of_names.source[:]) or_return
	output_length = source_name_field_check(copy_of_names.output[:]) or_return
	return source_length, output_length, true
}

// source_names_write writes the names of a source into the page of the
// terms, at SOURCE_NAMES_OFFSET. false: a page too small, or a name that
// source_names_of_bytes refuses; the page is then unchanged.
source_names_write :: proc "contextless" (page: []u8, source: string, output_name: string) -> bool {
	if len(page) < SOURCE_NAMES_PAGE_BYTES || len(source) >= SOURCE_NAME_BYTES || len(output_name) >= SOURCE_NAME_BYTES {
		return false
	}
	names: Source_Names
	copy(names.source[:], source)
	copy(names.output[:], output_name)
	if _, _, ok := source_names_of_bytes(names); !ok {
		return false
	}
	intrinsics.mem_copy_non_overlapping(&page[SOURCE_NAMES_OFFSET], &names, size_of(names))
	return true
}

// source_names_of_page is the border of the reader: it copies the names
// once out of the page of the terms, then checks the copy. false: a page
// too small, or a field that source_names_of_bytes refuses.
source_names_of_page :: proc "contextless" (page: []u8) -> (names: Source_Names, source_length: int, output_length: int, ok: bool) {
	if len(page) < SOURCE_NAMES_PAGE_BYTES {
		return {}, 0, 0, false
	}
	intrinsics.mem_copy_non_overlapping(&names, &page[SOURCE_NAMES_OFFSET], size_of(names))
	source_length, output_length, ok = source_names_of_bytes(names)
	if !ok {
		return {}, 0, 0, false
	}
	return names, source_length, output_length, true
}
