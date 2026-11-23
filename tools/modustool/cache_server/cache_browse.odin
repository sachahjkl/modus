// The browser pages of an object cache (src/md/infrastructure/cache_browser.md):
// trees, blobs (with modus module metadata, text/hex/PNG previews, and raw
// download), realisations (with signature verification and recipe objects),
// release pointers, and bounded prefix search. Every byte read from the store
// is checked against its hash before any byte reaches a page.
package cache_server

import "core:fmt"
import "core:os"
import "core:strings"
import "core:unicode/utf8"
import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/module"
import "modus:contract/object_cache"
import "modus:contract/plans_recipes"
import "modus:contract/tree_hash"
import "modus:contract/value_kinds"
import "modustool:foundation"
import "modustool:site"

// Entries shown on one page of a tree.
BROWSE_TREE_PAGE_ENTRIES :: 100

// Maximum rows of objects and of realisations shown for one search prefix.
BROWSE_SEARCH_ROWS :: 20

// Maximum release pointers shown on /releases.
BROWSE_RELEASE_ROWS :: 50

// Maximum bytes shown in a text preview, cut on a whole UTF-8 character.
BROWSE_TEXT_PREVIEW_BYTES :: 4096

// Maximum bytes shown in a hexadecimal preview.
BROWSE_HEX_PREVIEW_BYTES :: 256

// Maximum exports listed on a modus module blob page.
BROWSE_MODULE_EXPORTS_MAX :: 200

// The bytes of one name that a module file states (an export, a parameter,
// a record, an enum), and of one line of summary. A string of a module is a
// count into its string table that the module chooses, so each one is cut
// before it reaches a page.
BROWSE_MODULE_NAME_BYTES :: 128
BROWSE_MODULE_SUMMARY_BYTES :: 512

// The largest page of the browser. A page that would pass it is replaced by
// a page that says so.
BROWSE_PAGE_BYTES_MOST :: 1 << 20

// The most records of a table of a module that the page validates: the
// check of a module costs work in proportion to its tables, and the page
// runs within the deadline of one connection.
BROWSE_MODULE_SEGMENTS_MOST :: 256
BROWSE_MODULE_TABLE_RECORDS_MOST :: 1 << 16
BROWSE_MODULE_REBASE_WORDS_MOST :: 1 << 20

// One HTTP answer produced by a browse handler.
Browse_Answer :: struct {
	status:              Status_Answer,
	content_type:        string,
	cache_control:       string,
	security_policy:     string,
	content_disposition: string,
	body:                []u8,
}

// Outcome of reading and hash-verifying an object in objects/.
Browse_Object_State :: enum u8 {
	Absent,
	Blob,
	Tree,
	Damaged,
}

// Classification of a verified blob.
Browse_Blob_Kind :: enum u8 {
	Module,
	Damaged_Module,
	Module_Past_Bounds, // A module whose tables pass the bounds of this page: not validated.
	Image_Png,
	Text,
	Other,
}

// PNG signature bytes.
@(private = "file")
PNG_SIGNATURE :: [8]u8{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A}

// browse_html_answer wraps rendered HTML in a Browse_Answer with the page
// security policy of this host.
@(private = "file")
browse_html_answer :: proc(page: Cache_Page_Settings, status: Status_Answer, cache_control: string, html: string) -> Browse_Answer {
	return Browse_Answer {
		status          = status,
		content_type    = "text/html; charset=utf-8",
		cache_control   = cache_control,
		security_policy = cache_page_security_policy(page.site_address),
		body            = transmute([]u8)html,
	}
}

// browse_not_found_page renders a 404 HTML page in the style of the site.
@(private = "file")
browse_not_found_page :: proc(page: Cache_Page_Settings, heading: string, sentence: string) -> Browse_Answer {
	b := strings.builder_make(context.temp_allocator)
	cache_page_start(&b, page, heading, sentence, .None)
	strings.write_string(&b, "<h1>")
	foundation.html_escape(&b, heading)
	strings.write_string(&b, "</h1>\n<section class=\"card accent-kernel\">\n<p>")
	foundation.html_escape(&b, sentence)
	strings.write_string(&b, "</p>\n<p><a href=\"/\">Return to the overview</a> or <a href=\"/search\">search by hash prefix</a>.</p>\n</section>\n")
	cache_page_end(&b)
	return browse_html_answer(page, .Not_Found, "no-store", strings.to_string(b))
}

// browse_damaged_page renders a page stating that a stored file failed its
// hash check and showing none of its bytes.
@(private = "file")
browse_damaged_page :: proc(page: Cache_Page_Settings, title: string, digest: blake3.Hash, sentence: string) -> Browse_Answer {
	b := strings.builder_make(context.temp_allocator)
	cache_page_start(&b, page, title, sentence, .None)
	strings.write_string(&b, "<h1>")
	foundation.html_escape(&b, title)
	strings.write_string(&b, "</h1>\n<section class=\"card accent-process\">\n<dl class=\"symbol-facts\">\n<dt>Hash</dt><dd>")
	hash_write(&b, digest)
	strings.write_string(&b, "</dd>\n</dl>\n<p>")
	foundation.html_escape(&b, sentence)
	strings.write_string(&b, "</p>\n<p>None of its bytes are shown.</p>\n</section>\n")
	cache_page_end(&b)
	return browse_html_answer(page, .Ok, "no-store", strings.to_string(b))
}

// browse_read_object reads objects/<hash> within MAX_OBJECT_PAYLOAD_BYTES and
// verifies its content hash. A file larger than the bound is damaged and not
// read into memory.
browse_read_object :: proc(server: ^Cache_Server, digest: blake3.Hash, allocator := context.temp_allocator) -> (data: []u8, state: Browse_Object_State) {
	if server == nil || object_cache.hash_is_zero(digest) {
		return nil, .Absent
	}
	hex := hash_to_hex(digest)
	path, path_ok := store_path_for_hex(server.root_directory, .Objects, string(hex[:]), context.temp_allocator)
	if !path_ok {
		return nil, .Absent
	}
	info, stat_err := os.stat(path, context.temp_allocator)
	if stat_err != nil {
		return nil, .Absent
	}
	if info.type != .Regular || info.size < 0 || info.size > i64(object_cache.MAX_OBJECT_PAYLOAD_BYTES) {
		return nil, .Damaged
	}
	bytes, read_err := os.read_entire_file(path, allocator)
	if read_err != nil {
		return nil, .Damaged
	}
	if len(bytes) > object_cache.MAX_OBJECT_PAYLOAD_BYTES {
		return nil, .Damaged
	}
	if object_cache.verify_object_content(.Blob, digest, bytes) == .Trust_By_Hash {
		return bytes, .Blob
	}
	if object_cache.verify_object_content(.Tree, digest, bytes) == .Trust_By_Hash {
		return bytes, .Tree
	}
	return nil, .Damaged
}

// browse_object_stat checks whether objects/<hash> exists on disk and gives
// its regular-file size (at most one stat call, reading no bytes).
@(private = "file")
browse_object_stat :: proc(server: ^Cache_Server, digest: blake3.Hash) -> (size: u64, exists: bool) {
	hex := hash_to_hex(digest)
	path, path_ok := store_path_for_hex(server.root_directory, .Objects, string(hex[:]), context.temp_allocator)
	if !path_ok {
		return 0, false
	}
	info, stat_err := os.stat(path, context.temp_allocator)
	if stat_err != nil || info.type != .Regular || info.size < 0 {
		return 0, false
	}
	return u64(info.size), true
}

// browse_object_looks_like_tree peeks at the first 8 bytes of objects/<hash>
// to link a search row to /tree/ or /blob/ without reading a whole blob.
@(private = "file")
browse_object_looks_like_tree :: proc(server: ^Cache_Server, digest: blake3.Hash) -> bool {
	hex := hash_to_hex(digest)
	path, path_ok := store_path_for_hex(server.root_directory, .Objects, string(hex[:]), context.temp_allocator)
	if !path_ok {
		return false
	}
	file, open_err := os.open(path)
	if open_err != nil {
		return false
	}
	defer os.close(file)
	head: [8]u8
	count, read_err := os.read(file, head[:])
	if read_err != nil || count < len(head) {
		return false
	}
	return head == tree_hash.HEADER_MAGIC
}

// browse_blob_is_text reports whether bytes is non-empty valid UTF-8 with no
// control byte other than tab, line feed, and carriage return.
browse_blob_is_text :: proc(data: []u8) -> bool {
	if len(data) == 0 {
		return false
	}
	index := 0
	for index < len(data) {
		b := data[index]
		if b < 0x80 {
			if b < 0x20 && b != '\t' && b != '\n' && b != '\r' {
				return false
			}
			if b == 0x7F {
				return false
			}
			index += 1
			continue
		}
		r, width := utf8.decode_rune_in_bytes(data[index:])
		if r == utf8.RUNE_ERROR && width == 1 {
			return false
		}
		if r >= 0x80 && r <= 0x9F {
			return false
		}
		index += width
	}
	return true
}

// browse_module_tables_within_bounds reads the counts of the table
// directory, before any check of a module: a count past its bound refuses
// the module for this page. The string table counts bytes, which the bound
// of an object already bounds.
browse_module_tables_within_bounds :: proc(file: []u8) -> bool {
	for kind in module.Table_Kind {
		count := module.count(file, kind)
		#partial switch kind {
		case .Strings:
			continue
		case .Segments:
			if count > BROWSE_MODULE_SEGMENTS_MOST {
				return false
			}
		case .Rebases:
			if count > BROWSE_MODULE_REBASE_WORDS_MOST {
				return false
			}
		case:
			if count > BROWSE_MODULE_TABLE_RECORDS_MOST {
				return false
			}
		}
	}
	return true
}

// browse_module_text gives a text of a module file as a page shows it: cut
// to bound bytes on a whole character, with a mark when it was cut, each
// byte that is not UTF-8 and each control character (a tab and an end of
// line kept when lines is true) replaced by U+FFFD.
browse_module_text :: proc(text: string, bound: int, lines := false) -> string {
	b := strings.builder_make(context.temp_allocator)
	index := 0
	for index < len(text) {
		r, width := utf8.decode_rune_in_string(text[index:])
		replaced := r == utf8.RUNE_ERROR && width <= 1
		if !replaced && (r < 0x20 || (r >= 0x7F && r <= 0x9F)) {
			replaced = !(lines && (r == '\t' || r == '\n'))
		}
		piece_width := replaced ? 3 : width
		if strings.builder_len(b) + piece_width > bound {
			strings.write_string(&b, "…")
			break
		}
		if replaced {
			strings.write_rune(&b, utf8.RUNE_ERROR)
		} else {
			strings.write_string(&b, text[index:index + width])
		}
		index += max(width, 1)
	}
	return strings.to_string(b)
}

// browse_module_name gives a name of the string table, cut and cleaned.
@(private = "file")
browse_module_name :: proc(file: []u8, offset, count: u32, bound := BROWSE_MODULE_NAME_BYTES) -> string {
	return browse_module_text(module.string_at(file, offset, count), bound)
}

// browse_classify_blob detects the kind of a verified blob in fixed order:
// modus module (validated or damaged), PNG image, UTF-8 text, or other bytes.
browse_classify_blob :: proc(data: []u8) -> (kind: Browse_Blob_Kind, module_error: module.Error) {
	if len(data) >= 8 && byte_order.read_u64_little_endian(data, 0) == module.MAGIC {
		if !browse_module_tables_within_bounds(data) {
			return .Module_Past_Bounds, .None
		}
		err := module.validate(data)
		if err == .None {
			return .Module, .None
		}
		return .Damaged_Module, err
	}
	if len(data) >= len(PNG_SIGNATURE) {
		png_magic := PNG_SIGNATURE
		if string(data[:len(png_magic)]) == string(png_magic[:]) {
			return .Image_Png, .None
		}
	}
	if browse_blob_is_text(data) {
		return .Text, .None
	}
	return .Other, .None
}

// browse_utf8_prefix_cut returns the longest prefix of text of at most limit
// bytes that ends on a whole UTF-8 character boundary.
@(private = "file")
browse_utf8_prefix_cut :: proc(text: string, limit: int) -> string {
	if len(text) <= limit {
		return text
	}
	end := limit
	// Back up past any UTF-8 continuation bytes (10xxxxxx).
	for end > 0 && (text[end] & 0xC0) == 0x80 {
		end -= 1
	}
	return text[:end]
}

// browse_write_hex_preview writes up to BROWSE_HEX_PREVIEW_BYTES in a
// canonical 16-byte-per-line hexadecimal dump with ASCII column.
@(private = "file")
browse_write_hex_preview :: proc(b: ^strings.Builder, data: []u8) {
	shown := min(len(data), BROWSE_HEX_PREVIEW_BYTES)
	digits := HEX_DIGITS
	strings.write_string(b, "<pre><code>")
	for row := 0; row < shown; row += 16 {
		fmt.sbprintf(b, "%04x  ", row)
		for col in 0 ..< 16 {
			if col == 8 {
				strings.write_byte(b, ' ')
			}
			if row + col < shown {
				val := data[row + col]
				strings.write_byte(b, digits[val >> 4])
				strings.write_byte(b, digits[val & 0x0F])
				strings.write_byte(b, ' ')
			} else {
				strings.write_string(b, "   ")
			}
		}
		strings.write_string(b, " |")
		for col in 0 ..< 16 {
			if row + col >= shown {
				break
			}
			val := data[row + col]
			if val >= 0x20 && val <= 0x7E {
				switch val {
				case '&':
					strings.write_string(b, "&amp;")
				case '<':
					strings.write_string(b, "&lt;")
				case '>':
					strings.write_string(b, "&gt;")
				case:
					strings.write_byte(b, val)
				}
			} else {
				strings.write_byte(b, '.')
			}
		}
		strings.write_string(b, "|\n")
	}
	strings.write_string(b, "</code></pre>\n")
	if len(data) > shown {
		fmt.sbprintf(b, "<p>Showing the first %d of %d bytes.</p>\n", shown, len(data))
	}
}

@(private = "file")
module_error_words :: proc(err: module.Error) -> string {
	switch err {
	case .None:
		return "none"
	case .Too_Small:
		return "file is shorter than a module header"
	case .Bad_Magic:
		return "header magic does not match a module"
	case .Unknown_Version:
		return "unknown module format version"
	case .Unknown_Feature:
		return "required feature bit is not understood"
	case .Unknown_Machine:
		return "unknown target processor"
	case .Bad_Table:
		return "table directory or table bounds are wrong"
	case .Bad_Segment:
		return "segment alignment, bounds, or permissions are wrong"
	case .Bad_Rebase:
		return "rebase entry points outside a writable segment"
	case .Bad_Import_Slot:
		return "import slot is outside a writable segment"
	case .Bad_Import:
		return "import declaration does not match"
	case .Bad_Export:
		return "entry export index is out of range"
	case .Bad_Own_Hash_Place:
		return "own-hash place is outside a writable segment"
	case .Bad_Record_Stream_Place:
		return "record stream place is outside a writable segment"
	case .Too_Many_Record_Streams:
		return "record stream count passes the bound"
	case .Unknown_Category:
		return "category or tag bits name no known member"
	}
	return "unknown validation refusal"
}

@(private = "file")
module_category_words :: proc(category: module.Module_Category) -> string {
	switch category {
	case .None:
		return "none"
	case .Application:
		return "application"
	case .System_Tool:
		return "system tool"
	case .Developer_Tool:
		return "developer tool"
	case .Service:
		return "service"
	case .Library:
		return "library"
	case .Demonstration:
		return "demonstration"
	case .Test:
		return "test"
	}
	return "none"
}

@(private = "file")
module_type_text :: proc(file: []u8, type: module.Type, detail: u32, direction: module.Direction, is_parameter: bool) -> string {
	prefix := ""
	if is_parameter && (type == .Table || type == .Bytes) {
		switch direction {
		case .Read:
		case .Change:
			prefix = "change "
		case .Append:
			prefix = "append "
		}
	}
	switch type {
	case .None:
		return "None"
	case .Integer:
		return "Integer"
	case .Text:
		return "Text"
	case .Handle:
		return "Handle"
	case .Bytes:
		return strings.concatenate({prefix, "Bytes"}, context.temp_allocator)
	case .Record:
		if rec, ok := module.record(file, .Records, detail, module.Record); ok {
			name := browse_module_name(file, rec.name_offset, rec.name_count)
			if name != "" {
				return name
			}
		}
		return "Record"
	case .Table:
		if rec, ok := module.record(file, .Records, detail, module.Record); ok {
			name := browse_module_name(file, rec.name_offset, rec.name_count)
			if name != "" {
				return strings.concatenate({prefix, "Table of ", name}, context.temp_allocator)
			}
		}
		return strings.concatenate({prefix, "Table"}, context.temp_allocator)
	case .Enum:
		enum_index, _ := module.enum_detail_of(detail)
		if described, prob := module.enum_type(file, enum_index); prob == .None {
			name := browse_module_text(module.enum_name(file, described), BROWSE_MODULE_NAME_BYTES)
			if name != "" {
				return name
			}
		}
		return "Enum"
	}
	return "Unknown"
}

// browse_module_export_signature formats one export of a validated module file
// in the console signature form: name(param: Type, ...) -> Result.
@(private = "file")
browse_module_export_signature :: proc(file: []u8, function: module.Function) -> string {
	b := strings.builder_make(context.temp_allocator)
	name := browse_module_name(file, function.name_offset, function.name_count)
	strings.write_string(&b, name)
	strings.write_byte(&b, '(')
	count := min(int(function.parameter_count), module.PARAMETER_CAPACITY)
	for index in 0 ..< count {
		if index > 0 {
			strings.write_string(&b, ", ")
		}
		param_name := browse_module_name(file, function.parameter_names[index], u32(function.parameter_name_counts[index]))
		if param_name != "" {
			strings.write_string(&b, param_name)
			strings.write_string(&b, ": ")
		}
		param_type, type_ok := module.function_parameter_type(function, index)
		direction, dir_ok := module.direction_of_word(function.parameter_directions[index])
		if !dir_ok {
			direction = .Read
		}
		if type_ok {
			strings.write_string(&b, module_type_text(file, param_type, function.parameter_details[index], direction, true))
		} else {
			strings.write_string(&b, "Unknown")
		}
	}
	strings.write_byte(&b, ')')
	if res_type, res_ok := module.function_result_type(function); res_ok && res_type != .None {
		strings.write_string(&b, " -> ")
		strings.write_string(&b, module_type_text(file, res_type, function.result_detail, .Read, false))
	}
	return strings.to_string(b)
}

// cache_browse_tree answers GET /tree/<hash> and /tree/<hash>?page=<n>.
cache_browse_tree :: proc(server: ^Cache_Server, page_settings: Cache_Page_Settings, digest: blake3.Hash, page_number: int) -> Browse_Answer {
	data, state := browse_read_object(server, digest, context.temp_allocator)
	switch state {
	case .Absent:
		return browse_not_found_page(page_settings, "Tree not found", "No object with this hash is in this object cache.")
	case .Damaged:
		return browse_damaged_page(page_settings, "Damaged object", digest, "This object is damaged: its bytes do not match its hash.")
	case .Blob:
		hex := hash_to_hex(digest)
		b := strings.builder_make(context.temp_allocator)
		cache_page_start(&b, page_settings, "Blob, not a tree", "This hash names a blob in this object cache.", .None)
		strings.write_string(&b, "<h1>Blob, not a tree</h1>\n<section class=\"card accent-kernel\">\n<p>The hash ")
		hash_write(&b, digest)
		fmt.sbprintf(&b, " is a blob, not a tree. <a href=\"/blob/%s\">Open the blob page</a>.</p>\n</section>\n", string(hex[:]))
		cache_page_end(&b)
		return browse_html_answer(page_settings, .Ok, "no-store", strings.to_string(b))
	case .Tree:
	}

	entry_count, refusal := tree_hash.tree_validate(data)
	if refusal != .None {
		return browse_damaged_page(page_settings, "Damaged tree", digest, "This tree is damaged: its canonical entries do not validate.")
	}
	total_pages := max(1, (entry_count + BROWSE_TREE_PAGE_ENTRIES - 1) / BROWSE_TREE_PAGE_ENTRIES)
	if page_number < 1 || page_number > total_pages {
		return browse_not_found_page(page_settings, "Tree page not found", "This tree does not have that page number.")
	}

	hex := hash_to_hex(digest)
	hex_str := string(hex[:])
	b := strings.builder_make(context.temp_allocator)
	cache_page_start(&b, page_settings, "tree", "An immutable tree verified by its domain-separated BLAKE3 hash.", .None)
	strings.write_string(&b, "<nav class=\"crumbs\" aria-label=\"Breadcrumb\"><ol><li><a href=\"/\">Overview</a></li><li>Tree</li></ol></nav>\n")
	strings.write_string(&b, "<h1>Tree</h1>\n")

	strings.write_string(&b, "<section class=\"card accent-kernel\" aria-labelledby=\"tree-facts\">\n<h2 id=\"tree-facts\">Tree</h2>\n<dl class=\"symbol-facts\">\n")
	strings.write_string(&b, "<dt>Hash</dt><dd>")
	hash_write(&b, digest)
	strings.write_string(&b, "</dd>\n<dt>Entries</dt><dd>")
	site.site_value(&b, .Number, fmt.tprintf("%d", entry_count), false)
	strings.write_string(&b, "</dd>\n<dt>Encoded size</dt><dd>")
	site.site_value(&b, .Size, cache_page_bytes_text(u64(len(data))), false)
	strings.write_string(&b, "</dd>\n<dt>Check</dt><dd>Verified against its canonical tree hash on this request.</dd>\n</dl>\n</section>\n")

	strings.write_string(&b, "<section class=\"card accent-boot\" aria-labelledby=\"tree-entries\">\n<h2 id=\"tree-entries\">Entries</h2>\n")
	if entry_count == 0 {
		strings.write_string(&b, "<p>This tree holds no entries.</p>\n")
	} else {
		first := (page_number - 1) * BROWSE_TREE_PAGE_ENTRIES
		last := min(first + BROWSE_TREE_PAGE_ENTRIES, entry_count)
		if total_pages > 1 {
			fmt.sbprintf(&b, "<p>Showing entries %d to %d of %d (page %d of %d).</p>\n", first + 1, last, entry_count, page_number, total_pages)
		}
		columns := [?]site.Site_Column{{"Name", .Name}, {"Kind", .Short}, {"Size", .Number}, {"Hash", .Hash}}
		kinds := [?]value_kinds.Value_Kind{.None, .None, .Size, .Version}
		table := site.site_table_start(&b, "Tree entries", columns[:], kinds[:])
		for index in first ..< last {
			entry, ok := tree_hash.tree_entry_at(data, index)
			if !ok {
				continue
			}
			name := tree_hash.tree_entry_name(&entry)
			entry_kind_label := entry.kind == .Tree ? "tree" : "blob"
			entry_prefix := entry.kind == .Tree ? "/tree/" : "/blob/"
			entry_size, held := browse_object_stat(server, entry.hash)
			strings.write_string(&b, "<tr><td>")
			foundation.html_escape(&b, name)
			fmt.sbprintf(&b, "</td><td>%s</td><td>", entry_kind_label)
			if held {
				strings.write_string(&b, cache_page_bytes_text(entry_size))
			} else {
				strings.write_string(&b, "not held")
			}
			strings.write_string(&b, "</td><td>")
			if held {
				hash_link_write(&b, entry_prefix, entry.hash)
			} else {
				hash_write(&b, entry.hash)
			}
			strings.write_string(&b, "</td></tr>\n")
		}
		site.site_table_end(&b, table)
		if total_pages > 1 {
			strings.write_string(&b, "<nav class=\"pager\" aria-label=\"Tree pages\">")
			if page_number > 1 {
				if page_number == 2 {
					fmt.sbprintf(&b, "<a href=\"/tree/%s\">Previous page</a>", hex_str)
				} else {
					fmt.sbprintf(&b, "<a href=\"/tree/%s?page=%d\">Previous page</a>", hex_str, page_number - 1)
				}
			}
			fmt.sbprintf(&b, "<span>Page %d of %d</span>", page_number, total_pages)
			if page_number < total_pages {
				fmt.sbprintf(&b, "<a href=\"/tree/%s?page=%d\">Next page</a>", hex_str, page_number + 1)
			}
			strings.write_string(&b, "</nav>\n")
		}
	}
	strings.write_string(&b, "</section>\n")
	cache_page_end(&b)
	return browse_html_answer(page_settings, .Ok, "no-store", strings.to_string(b))
}

// cache_browse_blob answers GET /blob/<hash>.
cache_browse_blob :: proc(server: ^Cache_Server, page_settings: Cache_Page_Settings, digest: blake3.Hash) -> Browse_Answer {
	data, state := browse_read_object(server, digest, context.temp_allocator)
	switch state {
	case .Absent:
		return browse_not_found_page(page_settings, "Blob not found", "No object with this hash is in this object cache.")
	case .Damaged:
		return browse_damaged_page(page_settings, "Damaged object", digest, "This object is damaged: its bytes do not match its hash.")
	case .Tree:
		hex := hash_to_hex(digest)
		b := strings.builder_make(context.temp_allocator)
		cache_page_start(&b, page_settings, "Tree, not a blob", "This hash names a tree in this object cache.", .None)
		strings.write_string(&b, "<h1>Tree, not a blob</h1>\n<section class=\"card accent-kernel\">\n<p>The hash ")
		hash_write(&b, digest)
		fmt.sbprintf(&b, " is a tree, not a blob. <a href=\"/tree/%s\">Open the tree page</a>.</p>\n</section>\n", string(hex[:]))
		cache_page_end(&b)
		return browse_html_answer(page_settings, .Ok, "no-store", strings.to_string(b))
	case .Blob:
	}

	blob_kind, mod_err := browse_classify_blob(data)
	hex := hash_to_hex(digest)
	hex_str := string(hex[:])
	kind_text: string
	switch blob_kind {
	case .Module:
		kind_text = "modus module"
	case .Damaged_Module:
		kind_text = "modus module (did not parse)"
	case .Module_Past_Bounds:
		kind_text = "modus module past the bounds of this page"
	case .Image_Png:
		kind_text = "PNG image"
	case .Text:
		kind_text = "UTF-8 text"
	case .Other:
		kind_text = "bytes"
	}

	b := strings.builder_make(context.temp_allocator)
	cache_page_start(&b, page_settings, "blob", "A content-addressed blob verified by its BLAKE3 hash.", .None)
	strings.write_string(&b, "<nav class=\"crumbs\" aria-label=\"Breadcrumb\"><ol><li><a href=\"/\">Overview</a></li><li>Blob</li></ol></nav>\n")
	strings.write_string(&b, "<h1>Blob</h1>\n")

	strings.write_string(&b, "<section class=\"card accent-memory\" aria-labelledby=\"blob-facts\">\n<h2 id=\"blob-facts\">Blob</h2>\n<dl class=\"symbol-facts\">\n")
	strings.write_string(&b, "<dt>Hash</dt><dd>")
	hash_write(&b, digest)
	strings.write_string(&b, "</dd>\n<dt>Size</dt><dd>")
	site.site_value(&b, .Size, cache_page_bytes_text(u64(len(data))), false)
	fmt.sbprintf(&b, " (%d bytes)</dd>\n<dt>Detected kind</dt><dd>%s</dd>\n", len(data), kind_text)
	strings.write_string(&b, "<dt>Check</dt><dd>Verified against its BLAKE3 hash on this request.</dd>\n")
	fmt.sbprintf(&b, "<dt>Download</dt><dd><a href=\"/blob/%s/raw\">Download raw bytes</a></dd>\n</dl>\n</section>\n", hex_str)

	switch blob_kind {
	case .Module:
		browse_write_module_sections(&b, data)
		strings.write_string(&b, "<section class=\"card accent-kernel\" aria-labelledby=\"blob-head\">\n<h2 id=\"blob-head\">Head bytes</h2>\n")
		browse_write_hex_preview(&b, data)
		strings.write_string(&b, "</section>\n")
	case .Damaged_Module:
		strings.write_string(&b, "<section class=\"card accent-process\" aria-labelledby=\"module-refusal\">\n<h2 id=\"module-refusal\">Module check</h2>\n<p>This blob starts with the header of a modus module, and validation refused it: ")
		foundation.html_escape(&b, module_error_words(mod_err))
		strings.write_string(&b, ". No module metadata is shown.</p>\n</section>\n")
		strings.write_string(&b, "<section class=\"card accent-kernel\" aria-labelledby=\"blob-head\">\n<h2 id=\"blob-head\">Head bytes</h2>\n")
		browse_write_hex_preview(&b, data)
		strings.write_string(&b, "</section>\n")
	case .Module_Past_Bounds:
		strings.write_string(&b, "<section class=\"card accent-process\" aria-labelledby=\"module-refusal\">\n<h2 id=\"module-refusal\">Module check</h2>\n<p>This blob starts with the header of a modus module, and its tables hold more records than this page checks. It is not validated, and no module metadata is shown.</p>\n</section>\n")
		strings.write_string(&b, "<section class=\"card accent-kernel\" aria-labelledby=\"blob-head\">\n<h2 id=\"blob-head\">Head bytes</h2>\n")
		browse_write_hex_preview(&b, data)
		strings.write_string(&b, "</section>\n")
	case .Image_Png:
		strings.write_string(&b, "<section class=\"card accent-boot\" aria-labelledby=\"blob-image\">\n<h2 id=\"blob-image\">Preview</h2>\n")
		fmt.sbprintf(&b, "<img class=\"blob-image\" src=\"/blob/%s/raw\" alt=\"PNG image %s\">\n</section>\n", hex_str, hex_str)
	case .Text:
		strings.write_string(&b, "<section class=\"card accent-boot\" aria-labelledby=\"blob-text\">\n<h2 id=\"blob-text\">Preview</h2>\n")
		preview := browse_utf8_prefix_cut(string(data), BROWSE_TEXT_PREVIEW_BYTES)
		strings.write_string(&b, "<pre><code>")
		foundation.html_escape(&b, preview)
		strings.write_string(&b, "</code></pre>\n")
		if len(preview) < len(data) {
			fmt.sbprintf(&b, "<p>Showing the first %d of %d bytes.</p>\n", len(preview), len(data))
		}
		strings.write_string(&b, "</section>\n")
	case .Other:
		strings.write_string(&b, "<section class=\"card accent-kernel\" aria-labelledby=\"blob-head\">\n<h2 id=\"blob-head\">Preview</h2>\n")
		if len(data) == 0 {
			strings.write_string(&b, "<p>This blob holds zero bytes.</p>\n")
		} else {
			browse_write_hex_preview(&b, data)
		}
		strings.write_string(&b, "</section>\n")
	}

	cache_page_end(&b)
	if strings.builder_len(b) > BROWSE_PAGE_BYTES_MOST {
		return browse_too_large_page(page_settings, digest)
	}
	return browse_html_answer(page_settings, .Ok, "no-store", strings.to_string(b))
}

// browse_too_large_page replaces a page past BROWSE_PAGE_BYTES_MOST: the
// blob stays whole at its raw path.
@(private = "file")
browse_too_large_page :: proc(page: Cache_Page_Settings, digest: blake3.Hash) -> Browse_Answer {
	hex := hash_to_hex(digest)
	b := strings.builder_make(context.temp_allocator)
	cache_page_start(&b, page, "Blob page too large", "The page of this blob passes the bound of a page.", .None)
	strings.write_string(&b, "<h1>Blob page too large</h1>\n<section class=\"card accent-process\">\n<dl class=\"symbol-facts\">\n<dt>Hash</dt><dd>")
	hash_write(&b, digest)
	fmt.sbprintf(&b, "</dd>\n</dl>\n<p>The page of this blob passes %d bytes, the bound of a page of this host, so this host does not show it. <a href=\"/blob/%s/raw\">Download the raw bytes</a>.</p>\n</section>\n", BROWSE_PAGE_BYTES_MOST, string(hex[:]))
	cache_page_end(&b)
	return browse_html_answer(page, .Ok, "no-store", strings.to_string(b))
}

// browse_write_module_sections renders the metadata of a validated modus module.
@(private = "file")
browse_write_module_sections :: proc(b: ^strings.Builder, file: []u8) {
	hdr, hdr_err := module.header(file)
	if hdr_err != .None {
		return
	}
	about_raw, doc_text_raw := module.documentation(file)
	about := browse_module_text(about_raw, BROWSE_MODULE_SUMMARY_BYTES)
	doc_text := browse_module_text(doc_text_raw, BROWSE_TEXT_PREVIEW_BYTES, true)
	export_total := int(module.count(file, .Exports))
	export_count := max(0, export_total - 1)
	budget, budget_stated := module.budget_request(file)

	strings.write_string(b, "<section class=\"card accent-boot\" aria-labelledby=\"module-meta\">\n<h2 id=\"module-meta\">Module</h2>\n<dl class=\"symbol-facts\">\n")
	fmt.sbprintf(b, "<dt>Category</dt><dd>%s</dd>\n", module_category_words(hdr.category))
	strings.write_string(b, "<dt>Memory size</dt><dd>")
	site.site_value(b, .Size, cache_page_bytes_text(hdr.memory_size), false)
	strings.write_string(b, "</dd>\n<dt>Entry export</dt><dd>")
	if hdr.entry_export > 0 {
		if entry_fn, ok := module.function(file, hdr.entry_export); ok {
			entry_name := browse_module_name(file, entry_fn.name_offset, entry_fn.name_count)
			if entry_name != "" {
				strings.write_string(b, "<code>")
				foundation.html_escape(b, entry_name)
				strings.write_string(b, "</code>")
			} else {
				fmt.sbprintf(b, "export %d", hdr.entry_export)
			}
		} else {
			fmt.sbprintf(b, "export %d", hdr.entry_export)
		}
	} else {
		strings.write_string(b, "none (library)")
	}
	strings.write_string(b, "</dd>\n<dt>Exports</dt><dd>")
	site.site_value(b, .Number, fmt.tprintf("%d", export_count), false)
	strings.write_string(b, "</dd>\n")
	if budget_stated {
		strings.write_string(b, "<dt>Requested budget</dt><dd>")
		fmt.sbprintf(b, "%d pages (%s), %d processes, %d threads", budget.pages, cache_page_bytes_text(budget.pages > max(u64) / module.PAGE_SIZE ? max(u64) : budget.pages * module.PAGE_SIZE), budget.processes, budget.threads)
		strings.write_string(b, "</dd>\n")
	} else {
		strings.write_string(b, "<dt>Requested budget</dt><dd>none stated</dd>\n")
	}
	if about != "" {
		strings.write_string(b, "<dt>Summary</dt><dd>")
		foundation.html_escape(b, about)
		strings.write_string(b, "</dd>\n")
	}
	strings.write_string(b, "</dl>\n")
	if doc_text != "" && doc_text != about {
		strings.write_string(b, "<p>")
		foundation.html_escape(b, doc_text)
		strings.write_string(b, "</p>\n")
	}
	strings.write_string(b, "<p>A module file holds no file name of its own; the tree that references it names it.</p>\n</section>\n")

	if export_count > 0 {
		strings.write_string(b, "<section class=\"card accent-machine\" aria-labelledby=\"module-exports\">\n<h2 id=\"module-exports\">Exports</h2>\n")
		shown := min(export_count, BROWSE_MODULE_EXPORTS_MAX)
		columns := [?]site.Site_Column{{"Signature", .Line}, {"Summary", .Prose}}
		table := site.site_table_start(b, "Module exports", columns[:])
		for index in u32(1) ..= u32(shown) {
			if strings.builder_len(b^) > BROWSE_PAGE_BYTES_MOST {
				break
			}
			fn, ok := module.function(file, index)
			if !ok {
				continue
			}
			sig := browse_module_export_signature(file, fn)
			fn_about := browse_module_name(file, fn.about_offset, fn.about_count, BROWSE_MODULE_SUMMARY_BYTES)
			strings.write_string(b, "<tr><td><code>")
			foundation.html_escape(b, sig)
			strings.write_string(b, "</code></td><td>")
			foundation.html_escape(b, fn_about)
			strings.write_string(b, "</td></tr>\n")
		}
		site.site_table_end(b, table)
		if export_count > shown {
			fmt.sbprintf(b, "<p>Showing the first %d of %d exports.</p>\n", shown, export_count)
		}
		strings.write_string(b, "</section>\n")
	}
}

// cache_browse_blob_raw answers GET /blob/<hash>/raw with the raw verified
// bytes, a safe content type, Content-Disposition attachment, and a sandboxed
// security policy so uploaded HTML cannot execute on this host.
cache_browse_blob_raw :: proc(server: ^Cache_Server, digest: blake3.Hash) -> Browse_Answer {
	data, state := browse_read_object(server, digest, context.temp_allocator)
	if state != .Blob {
		return Browse_Answer{status = .Not_Found}
	}
	blob_kind, _ := browse_classify_blob(data)
	content_type := "application/octet-stream"
	extension := ".bin"
	switch blob_kind {
	case .Module:
		content_type = "application/octet-stream"
		extension = ".module"
	case .Damaged_Module, .Module_Past_Bounds, .Other:
		content_type = "application/octet-stream"
		extension = ".bin"
	case .Image_Png:
		content_type = "image/png"
		extension = ".png"
	case .Text:
		content_type = "text/plain; charset=utf-8"
		extension = ".txt"
	}
	hex := hash_to_hex(digest)
	disposition := fmt.tprintf("attachment; filename=\"%s%s\"", string(hex[:]), extension)
	return Browse_Answer {
		status              = .Ok,
		content_type        = content_type,
		cache_control       = "public, max-age=31536000, immutable",
		security_policy     = "default-src 'none'; sandbox",
		content_disposition = disposition,
		body                = data,
	}
}

// cache_browse_realisation answers GET /realisation/<recipe hash>.
cache_browse_realisation :: proc(server: ^Cache_Server, page_settings: Cache_Page_Settings, recipe_digest: blake3.Hash) -> Browse_Answer {
	if server == nil || object_cache.hash_is_zero(recipe_digest) {
		return browse_not_found_page(page_settings, "Realisation not found", "No realisation for this recipe is in this object cache.")
	}
	hex := hash_to_hex(recipe_digest)
	hex_str := string(hex[:])
	// The size of the file first: a record has one size, and no file past
	// it is read.
	realisation_path, realisation_path_ok := store_path_for_hex(server.root_directory, .Realisations, hex_str, context.temp_allocator)
	if !realisation_path_ok {
		return browse_not_found_page(page_settings, "Realisation not found", "No realisation for this recipe is in this object cache.")
	}
	realisation_stat, realisation_stat_error := os.stat(realisation_path, context.temp_allocator)
	if realisation_stat_error != nil {
		return browse_not_found_page(page_settings, "Realisation not found", "No realisation for this recipe is in this object cache.")
	}
	if realisation_stat.type != .Regular || realisation_stat.size != object_cache.REALISATION_WIRE_SIZE {
		return browse_damaged_page(page_settings, "Damaged realisation", recipe_digest, "This realisation file does not have the size of a realisation record.")
	}
	data, found, read_ok := store_read_by_hex(server, .Realisations, hex_str, context.temp_allocator)
	if !read_ok || !found {
		return browse_damaged_page(page_settings, "Damaged realisation", recipe_digest, "This host did not read the realisation file.")
	}
	record, decode_refusal := object_cache.decode_realisation_record(data)
	if decode_refusal != .None || !object_cache.hashes_equal_constant_time(record.recipe_hash, recipe_digest) {
		return browse_damaged_page(page_settings, "Damaged realisation", recipe_digest, "This realisation record is damaged or names another recipe.")
	}

	signing_bytes, sign_bytes_ok := object_cache.realisation_signing_bytes(&record)
	sig_valid := sign_bytes_ok && cache_server_verify_ed25519(record.signer_public_key, signing_bytes[:], record.signature)
	// A record whose signature does not verify is damaged: none of its
	// fields is a fact that this host checked.
	if !sig_valid {
		return browse_damaged_page(page_settings, "Damaged realisation", recipe_digest, "The signature of this realisation does not verify against the key that it names.")
	}
	signer_authorised := object_cache.signer_is_trusted(server.authorized_signers[:], record.signer_public_key)
	_, output_held := browse_object_stat(server, record.output_hash)

	b := strings.builder_make(context.temp_allocator)
	cache_page_start(&b, page_settings, "realisation", "A signed realisation record binding a recipe hash to its output.", .None)
	strings.write_string(&b, "<nav class=\"crumbs\" aria-label=\"Breadcrumb\"><ol><li><a href=\"/\">Overview</a></li><li>Realisation</li></ol></nav>\n")
	strings.write_string(&b, "<h1>Realisation</h1>\n")

	strings.write_string(&b, "<section class=\"card accent-boot\" aria-labelledby=\"realisation-facts\">\n<h2 id=\"realisation-facts\">Realisation</h2>\n<dl class=\"symbol-facts\">\n")
	strings.write_string(&b, "<dt>Recipe</dt><dd>")
	hash_write(&b, record.recipe_hash)
	fmt.sbprintf(&b, "</dd>\n<dt>Output kind</dt><dd>%s</dd>\n<dt>Output</dt><dd>", object_kind_text(record.output_kind))
	if output_held {
		hash_link_write(&b, object_path_prefix(record.output_kind), record.output_hash)
	} else {
		hash_write(&b, record.output_hash)
		strings.write_string(&b, " (not held on this host)")
	}
	strings.write_string(&b, "</dd>\n<dt>Signer</dt><dd>")
	hash_write(&b, record.signer_public_key)
	strings.write_string(&b, "</dd>\n<dt>Signature check</dt><dd>")
	if signer_authorised {
		strings.write_string(&b, "Verified by this host against the signer key above, which is an authorised upload key of this host.")
	} else {
		strings.write_string(&b, "Verified by this host against the signer key above. This key is not in the authorised upload keys of this host.")
	}
	strings.write_string(&b, "</dd>\n</dl>\n")
	strings.write_string(&b, "<p>This check ran on this host. A client must still trust a publisher key from the publisher and verify the signature itself, never this host.</p>\n</section>\n")

	// Recipe object section: check recipes/<recipe hash> and verify that its
	// canonical recipe_hash equals recipe_digest before showing any field.
	strings.write_string(&b, "<section class=\"card accent-kernel\" aria-labelledby=\"recipe-section\">\n<h2 id=\"recipe-section\">Recipe</h2>\n")
	recipe_path, recipe_path_ok := store_path_for_hex(server.root_directory, .Recipes, hex_str, context.temp_allocator)
	recipe_stat, recipe_stat_err := os.stat(recipe_path, context.temp_allocator)
	if !recipe_path_ok || recipe_stat_err != nil {
		strings.write_string(&b, "<p>This host holds the realisation, not the recipe object.</p>\n")
	} else if recipe_stat.type != .Regular || recipe_stat.size < 0 || recipe_stat.size > i64(plans_recipes.MAX_RECIPE_OBJECT_BYTES) {
		strings.write_string(&b, "<p>The recipe object stored for this hash is damaged. None of its bytes are shown.</p>\n")
	} else {
		recipe_bytes, recipe_read_err := os.read_entire_file(recipe_path, context.temp_allocator)
		spec := new(plans_recipes.Recipe_Spec, context.temp_allocator)
		computed_digest, recipe_refusal := plans_recipes.recipe_object_decode(recipe_bytes, spec)
		if recipe_read_err != nil || recipe_refusal != .None || !object_cache.hashes_equal_constant_time(computed_digest, recipe_digest) {
			strings.write_string(&b, "<p>The recipe object stored for this hash is damaged: its canonical hash does not match. None of its bytes are shown.</p>\n")
		} else {
			_, builder_held := browse_object_stat(server, spec.builder_hash)
			strings.write_string(&b, "<dl class=\"symbol-facts\">\n<dt>Builder</dt><dd>")
			if builder_held {
				hash_link_write(&b, "/blob/", spec.builder_hash)
			} else {
				hash_write(&b, spec.builder_hash)
			}
			fmt.sbprintf(&b, "</dd>\n<dt>Output kind</dt><dd>%s</dd>\n", object_kind_text(spec.output_kind))
			fmt.sbprintf(&b, "<dt>Source date (Unix)</dt><dd>%d</dd>\n", spec.source_date_unix)
			fmt.sbprintf(&b, "<dt>Output block limit</dt><dd>%d</dd>\n", spec.output_block_limit)
			fmt.sbprintf(&b, "<dt>Arguments</dt><dd>%d bytes</dd>\n</dl>\n", spec.arguments_length)

			if spec.input_count == 0 {
				strings.write_string(&b, "<p>This recipe takes no inputs.</p>\n")
			} else {
				columns := [?]site.Site_Column{{"Input", .Name}, {"Kind", .Short}, {"Hash", .Hash}}
				kinds := [?]value_kinds.Value_Kind{.None, .None, .Version}
				table := site.site_table_start(&b, "Recipe inputs", columns[:], kinds[:])
				for index in u32(0) ..< spec.input_count {
					item := &spec.inputs[index]
					name := string(item.name_bytes[:item.name_length])
					_, input_held := browse_object_stat(server, item.hash)
					strings.write_string(&b, "<tr><td>")
					foundation.html_escape(&b, name)
					fmt.sbprintf(&b, "</td><td>%s</td><td>", object_kind_text(item.kind))
					if input_held {
						hash_link_write(&b, object_path_prefix(item.kind), item.hash)
					} else {
						hash_write(&b, item.hash)
					}
					strings.write_string(&b, "</td></tr>\n")
				}
				site.site_table_end(&b, table)
			}
			if spec.arguments_length > 0 {
				strings.write_string(&b, "<h3>Arguments head</h3>\n")
				browse_write_hex_preview(&b, spec.arguments[:spec.arguments_length])
			}
		}
	}
	strings.write_string(&b, "</section>\n")

	cache_page_end(&b)
	return browse_html_answer(page_settings, .Ok, "no-store", strings.to_string(b))
}

// cache_browse_releases answers GET /releases.
cache_browse_releases :: proc(server: ^Cache_Server, page_settings: Cache_Page_Settings) -> Browse_Answer {
	rows := cache_status_release_rows(&server.status)
	b := strings.builder_make(context.temp_allocator)
	cache_page_start(&b, page_settings, "releases", "Signed release pointers stored on this object cache.", .Releases)
	strings.write_string(&b, "<h1>Releases</h1>\n<section class=\"card accent-boot\" aria-labelledby=\"releases-heading\">\n<h2 id=\"releases-heading\">Release pointers</h2>\n")
	strings.write_string(&b, "<p>Each row is a release pointer whose signature this host checked against its publisher key when it kept it. A client trusts the publisher key from the publisher, never this list.</p>\n")
	if rows.shown == 0 {
		strings.write_string(&b, "<p>No release pointer yet.</p>\n")
	} else {
		columns := [?]site.Site_Column{{"Name", .Short}, {"Number", .Number}, {"Tree", .Hash}, {"Publisher", .Hash}, {"Key of this host", .Short}, {"Written", .Date}}
		kinds := [?]value_kinds.Value_Kind{.None, .Number, .Version, .Version, .None, .None}
		table := site.site_table_start(&b, "Release pointers", columns[:], kinds[:])
		for index in 0 ..< rows.shown {
			kept := rows.rows[index]
			name := object_cache.release_pointer_name(&kept.pointer)
			_, tree_held := browse_object_stat(server, kept.pointer.tree_hash)
			strings.write_string(&b, "<tr><td>")
			foundation.html_escape(&b, name)
			fmt.sbprintf(&b, "</td><td>%d</td><td>", kept.pointer.number)
			if tree_held {
				hash_link_write(&b, "/tree/", kept.pointer.tree_hash)
			} else {
				hash_write(&b, kept.pointer.tree_hash)
			}
			strings.write_string(&b, "</td><td>")
			hash_write(&b, kept.pointer.publisher_public_key)
			// The host checked the signature when it kept the pointer; whether
			// it authorises the key is a fact of now.
			authorised := object_cache.signer_is_trusted(server.authorized_signers[:], kept.pointer.publisher_public_key)
			fmt.sbprintf(&b, "</td><td>%s</td><td>", authorised ? "authorised" : "not authorised now")
			time_write(&b, kept.written)
			strings.write_string(&b, "</td></tr>\n")
		}
		site.site_table_end(&b, table)
		if rows.total > rows.shown {
			fmt.sbprintf(&b, "<p>Showing the newest %d of %d release pointers.</p>\n", rows.shown, rows.total)
		}
	}
	strings.write_string(&b, "</section>\n")
	cache_page_end(&b)
	return browse_html_answer(page_settings, .Ok, "no-store", strings.to_string(b))
}

// hash_prefix_string formats a validated Hash_Prefix back to lowercase ASCII hex.
@(private = "file")
hash_prefix_string :: proc(prefix: Hash_Prefix, allocator := context.temp_allocator) -> string {
	digits := HEX_DIGITS
	out := make([]u8, prefix.count, allocator)
	for index in 0 ..< prefix.count {
		out[index] = digits[prefix.digits[index] & 0x0F]
	}
	return string(out)
}

// cache_browse_search answers GET /search and /search?h=<prefix>.
cache_browse_search :: proc(server: ^Cache_Server, page_settings: Cache_Page_Settings, prefix: Hash_Prefix, prefix_state: Search_Prefix_State) -> Browse_Answer {
	b := strings.builder_make(context.temp_allocator)
	cache_page_start(&b, page_settings, "search", "Search objects and realisations by lowercase hexadecimal hash prefix.", .Search)
	strings.write_string(&b, "<h1>Search</h1>\n<section class=\"card accent-kernel\" aria-labelledby=\"search-heading\">\n<h2 id=\"search-heading\">Hash prefix</h2>\n")
	strings.write_string(&b, "<form class=\"search-form\" method=\"get\" action=\"/search\">\n<label class=\"search-label\" for=\"search-h\">Hash prefix</label>\n<input id=\"search-h\" name=\"h\" type=\"text\" placeholder=\"Lowercase hexadecimal prefix\"")
	if prefix_state == .Valid {
		strings.write_string(&b, " value=\"")
		strings.write_string(&b, hash_prefix_string(prefix))
		strings.write_string(&b, "\"")
	}
	strings.write_string(&b, ">\n<button type=\"submit\">Search</button>\n</form>\n")

	switch prefix_state {
	case .None:
		strings.write_string(&b, "<p>Enter 1 to 64 lowercase hexadecimal digits (0 to 9 and a to f) to match objects and realisations in this object cache.</p>\n")
	case .Refused:
		strings.write_string(&b, "<p>A hash prefix must be 1 to 64 lowercase hexadecimal digits (0 to 9 and a to f).</p>\n")
	case .Valid:
		result := cache_status_search(&server.status, prefix)
		if result.object_count == 0 && result.realisation_count == 0 {
			strings.write_string(&b, "<p>No object or realisation starts with this prefix.</p>\n")
		} else {
			if result.object_count > 0 {
				strings.write_string(&b, "<h3>Objects</h3>\n")
				columns := [?]site.Site_Column{{"Kind", .Short}, {"Hash", .Hash}}
				kinds := [?]value_kinds.Value_Kind{.None, .Version}
				table := site.site_table_start(&b, "Matching objects", columns[:], kinds[:])
				for index in 0 ..< result.objects_shown {
					digest := result.objects[index]
					is_tree := browse_object_looks_like_tree(server, digest)
					fmt.sbprintf(&b, "<tr><td>%s</td><td>", is_tree ? "tree" : "blob")
					hash_link_write(&b, is_tree ? "/tree/" : "/blob/", digest)
					strings.write_string(&b, "</td></tr>\n")
				}
				site.site_table_end(&b, table)
				if result.object_count > result.objects_shown {
					fmt.sbprintf(&b, "<p>Showing the first %d of %d matching objects. Enter more digits to narrow the list.</p>\n", result.objects_shown, result.object_count)
				}
			}
			if result.realisation_count > 0 {
				strings.write_string(&b, "<h3>Realisations</h3>\n")
				columns := [?]site.Site_Column{{"Recipe", .Hash}}
				kinds := [?]value_kinds.Value_Kind{.Version}
				table := site.site_table_start(&b, "Matching realisations", columns[:], kinds[:])
				for index in 0 ..< result.realisations_shown {
					digest := result.realisations[index]
					strings.write_string(&b, "<tr><td>")
					hash_link_write(&b, "/realisation/", digest)
					strings.write_string(&b, "</td></tr>\n")
				}
				site.site_table_end(&b, table)
				if result.realisation_count > result.realisations_shown {
					fmt.sbprintf(&b, "<p>Showing the first %d of %d matching realisations. Enter more digits to narrow the list.</p>\n", result.realisations_shown, result.realisation_count)
				}
			}
		}
	}
	strings.write_string(&b, "</section>\n")
	cache_page_end(&b)
	return browse_html_answer(page_settings, .Ok, "no-store", strings.to_string(b))
}
