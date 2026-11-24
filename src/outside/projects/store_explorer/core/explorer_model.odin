// Immutable worker-produced Explorer_Snapshot, off-thread filtering,
// BLAKE3 hex formatting, UTF-8 vs binary inspection, and canonical 16-byte
// hex dump formatting for store_explorer (src/md/features/store_explorer.md).
package store_explorer_core

import "modus:contract/blake3"
import "modus:contract/store"
import "modus:contract/text_encoding"

// Format property: STORAGE7 entry name maximum length is 255 bytes.
ENTRY_NAME_MAX_BYTES :: 255

// Format property: STORAGE7 store name maximum length is 32 bytes.
STORE_NAME_MAX_BYTES :: store.NAME_CAPACITY

// Plan values: fixed snapshot table bounds sized for store_explorer's 8 MiB
// working-memory budget (two double-buffered snapshots in module memory).
MAX_STORES :: 64
MAX_PATH_DEPTH :: 16
MAX_TREE_ENTRIES :: 512
MAX_PREVIEW_LINES :: 2048 // Pre-indexed UTF-8 line offsets for O(1) viewport rendering.
MAX_VERSION_ROWS :: 128
MAX_DIFF_RANGES :: 64
FILTER_MAX_BYTES :: 64
HEX_BYTES_PER_ROW :: 16

// Inline capacity: first 64 KiB load into memory for instant text/hex preview;
// larger objects continue streaming in 32 KiB chunks for full BLAKE3 hashing.
PREVIEW_MAX_BYTES :: 65536

Entry_Kind :: enum u8 {
	None   = 0,
	Object = 1,
	Tree   = 2,
}

Inspector_Mode :: enum u8 {
	Text = 0,
	Hex  = 1,
}

Store_Item :: struct {
	name:     [STORE_NAME_MAX_BYTES]u8,
	name_len: u8,
}

Path_Segment :: struct {
	name:     [ENTRY_NAME_MAX_BYTES]u8,
	name_len: u16,
}

Entry_Row :: struct {
	name:       [ENTRY_NAME_MAX_BYTES]u8,
	name_len:   u16,
	kind:       Entry_Kind,
	size:       i64,
	generation: i64,
}

Version_Row :: struct {
	generation: i64,
	date:       i64,
	bytes:      i64,
	own_blocks: i64,
	current:    bool,
}

Diff_Range :: struct {
	first: i64,
	count: i64,
}

Usage_Info :: struct {
	objects:   i64,
	trees:     i64,
	versions:  i64,
	blocks:    i64,
	limit:     i64,
	has_usage: bool,
}

Text_Line_Span :: struct {
	start:  u32,
	length: u32,
}

// Immutable snapshot published by the worker thread; the interface thread only
// reads visible rows and lines from snapshots[active_snapshot].
Explorer_Snapshot :: struct {
	serial:            u64,
	stores:            [MAX_STORES]Store_Item,
	store_count:       int,
	active_store:      int,
	path:              [MAX_PATH_DEPTH]Path_Segment,
	path_depth:        int,
	entries:           [MAX_TREE_ENTRIES]Entry_Row,
	entry_count:       int,
	entries_truncated: bool,
	filtered:          [MAX_TREE_ENTRIES]u16,
	filtered_count:    int,
	filter_text:       [FILTER_MAX_BYTES]u8,
	filter_len:        int,
	selected_entry:    int, // Index into filtered[], -1 when none.

	// Selected object inspection state.
	has_object:        bool,
	object_name:       [ENTRY_NAME_MAX_BYTES]u8,
	object_name_len:   u16,
	object_size:       i64,
	object_generation: i64,
	object_hash:       blake3.Hash,
	has_hash:          bool,
	preview_bytes:     [PREVIEW_MAX_BYTES]u8,
	preview_len:       int,
	preview_truncated: bool,
	preview_is_utf8:   bool,
	preview_lines:     [MAX_PREVIEW_LINES]Text_Line_Span,
	preview_line_count: int,

	// Version history & comparison state for selected object.
	versions:           [MAX_VERSION_ROWS]Version_Row,
	version_count:      int,
	versions_truncated: bool,
	version_chosen:     int,
	preview_generation: i64,
	diff_ranges:        [MAX_DIFF_RANGES]Diff_Range,
	diff_count:         int,

	usage:             Usage_Info,
}

append_text :: proc "contextless" (out: []u8, pos: ^int, s: string) {
	if pos^ >= len(out) {
		return
	}
	pos^ += copy(out[pos^:], s)
}

format_u64 :: proc "contextless" (value: u64, out: []u8) -> string {
	if len(out) == 0 {
		return ""
	}
	if value == 0 {
		out[0] = '0'
		return string(out[:1])
	}
	digits: [24]u8
	count := 0
	v := value
	for v > 0 {
		digits[count] = u8('0' + v % 10)
		v /= 10
		count += 1
	}
	n := min(count, len(out))
	for i in 0 ..< n {
		out[i] = digits[count - 1 - i]
	}
	return string(out[:n])
}

format_i64 :: proc "contextless" (value: i64, out: []u8) -> string {
	if len(out) == 0 {
		return ""
	}
	if value >= 0 {
		return format_u64(u64(value), out)
	}
	out[0] = '-'
	mag := u64(0) - u64(value)
	rest := format_u64(mag, out[1:])
	return string(out[:1 + len(rest)])
}

// format_blake3_hex formats a 32-byte BLAKE3 digest as lowercase hex (64 bytes, or shorter prefix if out is smaller).
format_blake3_hex :: proc "contextless" (hash: blake3.Hash, out: []u8) -> string {
	HEX :: "0123456789abcdef"
	hex := HEX
	pairs := min(len(hash), len(out) / 2)
	for i in 0 ..< pairs {
		b := hash[i]
		out[i * 2] = hex[b >> 4]
		out[i * 2 + 1] = hex[b & 0x0F]
	}
	return string(out[:pairs * 2])
}

// format_byte_size writes human-readable binary byte sizes (`0 B`, `512 B`, `12 KiB`, `4 MiB`).
format_byte_size :: proc "contextless" (bytes: i64, out: []u8) -> string {
	b := u64(max(bytes, 0))
	pos := 0
	num: [24]u8
	switch {
	case b < 1024:
		append_text(out, &pos, format_u64(b, num[:]))
		append_text(out, &pos, " B")
	case b < 1024 * 1024:
		append_text(out, &pos, format_u64((b + 512) / 1024, num[:]))
		append_text(out, &pos, " KiB")
	case b < 1024 * 1024 * 1024:
		append_text(out, &pos, format_u64((b + 512 * 1024) / (1024 * 1024), num[:]))
		append_text(out, &pos, " MiB")
	case:
		append_text(out, &pos, format_u64(b / (1024 * 1024 * 1024), num[:]))
		append_text(out, &pos, " GiB")
	}
	return string(out[:pos])
}

// ascii_lower folds ASCII uppercase bytes to lowercase for case-insensitive entry filtering.
@(private = "file")
ascii_lower :: proc "contextless" (b: u8) -> u8 {
	if b >= 'A' && b <= 'Z' {
		return b + ('a' - 'A')
	}
	return b
}

// contains_ascii_ci reports whether needle occurs inside haystack (ASCII case-insensitive).
contains_ascii_ci :: proc "contextless" (haystack, needle: []u8) -> bool {
	if len(needle) == 0 {
		return true
	}
	if len(needle) > len(haystack) {
		return false
	}
	limit := len(haystack) - len(needle)
	for i := 0; i <= limit; i += 1 {
		matched := true
		for j := 0; j < len(needle); j += 1 {
			if ascii_lower(haystack[i + j]) != ascii_lower(needle[j]) {
				matched = false
				break
			}
		}
		if matched {
			return true
		}
	}
	return false
}

// filter_entries_off_thread populates snap.filtered[] from snap.entries[] using
// snap.filter_text (trees first, preserving B+ tree byte order within each kind).
filter_entries_off_thread :: proc "contextless" (snap: ^Explorer_Snapshot, query: string) {
	if snap == nil {
		return
	}
	q_len := min(len(query), FILTER_MAX_BYTES)
	copy(snap.filter_text[:q_len], query[:q_len])
	snap.filter_len = q_len
	needle := snap.filter_text[:q_len]

	count := 0
	// Trees first, then objects, keeping deterministic sorted B+ tree order.
	for pass in 0 ..< 2 {
		want := pass == 0 ? Entry_Kind.Tree : Entry_Kind.Object
		for i in 0 ..< snap.entry_count {
			e := &snap.entries[i]
			if e.kind != want {
				continue
			}
			if contains_ascii_ci(e.name[:e.name_len], needle) {
				snap.filtered[count] = u16(i)
				count += 1
			}
		}
	}
	snap.filtered_count = count
	if count == 0 {
		snap.selected_entry = -1
	} else if snap.selected_entry < 0 || snap.selected_entry >= count {
		snap.selected_entry = 0
	}
}

// is_preview_text_utf8 returns true if data is valid UTF-8 allowing newline,
// carriage return, and tab while refusing NUL, other C0/DEL controls, and
// malformed UTF-8 byte sequences. (text_encoding.text_valid refuses '\n'.)
is_preview_text_utf8 :: proc "contextless" (data: []u8) -> bool {
	i := 0
	for i < len(data) {
		b := data[i]
		if b < 0x80 {
			if (b < 0x20 && b != '\n' && b != '\r' && b != '\t') || b == 0x7F {
				return false
			}
			i += 1
			continue
		}
		_, step, valid := text_encoding.character_decode(data, i)
		if !valid || step <= 0 || i + step > len(data) {
			return false
		}
		i += step
	}
	return true
}

// index_preview_lines splits UTF-8 preview bytes into line spans off-thread so
// the UI renders visible viewport lines in O(1) without scanning.
index_preview_lines :: proc "contextless" (snap: ^Explorer_Snapshot) {
	snap.preview_line_count = 0
	data := snap.preview_bytes[:snap.preview_len]
	if len(data) == 0 {
		return
	}
	start := 0
	for i := 0; i < len(data) && snap.preview_line_count < MAX_PREVIEW_LINES; i += 1 {
		if data[i] == '\n' {
			end := i
			if end > start && data[end - 1] == '\r' {
				end -= 1
			}
			snap.preview_lines[snap.preview_line_count] = {start = u32(start), length = u32(end - start)}
			snap.preview_line_count += 1
			start = i + 1
		}
	}
	if start < len(data) && snap.preview_line_count < MAX_PREVIEW_LINES {
		end := len(data)
		if end > start && data[end - 1] == '\r' {
			end -= 1
		}
		snap.preview_lines[snap.preview_line_count] = {start = u32(start), length = u32(end - start)}
		snap.preview_line_count += 1
	}
}

// hex_row_count gives the total number of 16-byte rows for the preview bytes.
hex_row_count :: proc "contextless" (byte_len: int) -> int {
	if byte_len <= 0 {
		return 0
	}
	return (byte_len + HEX_BYTES_PER_ROW - 1) / HEX_BYTES_PER_ROW
}

// format_hex_row formats one canonical 16-byte hex inspector line:
// `00000010  48 65 6c 6c 6f 20 77 6f  72 6c 64 21              |Hello world!|`
format_hex_row :: proc "contextless" (data: []u8, row_index: int, out: []u8) -> string {
	HEX :: "0123456789abcdef"
	hex := HEX
	base := row_index * HEX_BYTES_PER_ROW
	if row_index < 0 || base >= len(data) || len(out) < 78 {
		return ""
	}
	pos := 0
	// 8-hex-digit offset.
	off := u32(base)
	for shift := uint(28); shift < 32; shift -= 4 {
		out[pos] = hex[(off >> shift) & 0xF]
		pos += 1
	}
	out[pos] = ' '
	out[pos + 1] = ' '
	pos += 2

	count := min(HEX_BYTES_PER_ROW, len(data) - base)
	for i in 0 ..< HEX_BYTES_PER_ROW {
		if i == 8 {
			out[pos] = ' '
			pos += 1
		}
		if i < count {
			b := data[base + i]
			out[pos] = hex[b >> 4]
			out[pos + 1] = hex[b & 0x0F]
			out[pos + 2] = ' '
		} else {
			out[pos] = ' '
			out[pos + 1] = ' '
			out[pos + 2] = ' '
		}
		pos += 3
	}
	out[pos] = ' '
	out[pos + 1] = '|'
	pos += 2
	for i in 0 ..< count {
		b := data[base + i]
		out[pos] = (b >= 0x20 && b <= 0x7E) ? b : '.'
		pos += 1
	}
	out[pos] = '|'
	pos += 1
	return string(out[:pos])
}

// validate_entry_name checks a new object or subtree name against STORAGE7 rules.
validate_entry_name :: proc "contextless" (name: string) -> bool {
	if len(name) == 0 || len(name) > ENTRY_NAME_MAX_BYTES {
		return false
	}
	raw := transmute([]u8)name
	if !text_encoding.text_valid(raw) {
		return false
	}
	for b in raw {
		if b < 0x20 || b == 0x7F || b == '/' {
			return false
		}
	}
	refusal, _, _ := store.name_refusal(name)
	return refusal == .None
}

// parse_stores_listing parses the lines returned by the storage service `stores`
// export (line 0 is the disk header, each subsequent line is `<name>: ...`).
parse_stores_listing :: proc "contextless" (text: []u8, out: []Store_Item) -> int {
	count := 0
	i := 0
	// Skip header line.
	for i < len(text) && text[i] != '\n' {
		i += 1
	}
	if i < len(text) {
		i += 1
	}
	for i < len(text) && count < len(out) {
		line_start := i
		for i < len(text) && text[i] != '\n' {
			i += 1
		}
		line := text[line_start:i]
		if i < len(text) {
			i += 1
		}
		// Extract name before ": ".
		colon := -1
		for k := 0; k + 1 < len(line); k += 1 {
			if line[k] == ':' && line[k + 1] == ' ' {
				colon = k
				break
			}
		}
		if colon <= 0 || colon > STORE_NAME_MAX_BYTES {
			continue
		}
		name_bytes := line[:colon]
		if !text_encoding.text_valid(name_bytes) {
			continue
		}
		item := &out[count]
		item^ = {}
		copy(item.name[:colon], name_bytes)
		item.name_len = u8(colon)
		count += 1
	}
	return count
}

snapshot_store_name :: proc "contextless" (snap: ^Explorer_Snapshot, index: int) -> string {
	if snap == nil || index < 0 || index >= snap.store_count {
		return ""
	}
	return string(snap.stores[index].name[:snap.stores[index].name_len])
}

snapshot_filtered_entry :: proc "contextless" (snap: ^Explorer_Snapshot, filtered_idx: int) -> (^Entry_Row, bool) {
	if snap == nil || filtered_idx < 0 || filtered_idx >= snap.filtered_count {
		return nil, false
	}
	raw_idx := int(snap.filtered[filtered_idx])
	if raw_idx < 0 || raw_idx >= snap.entry_count {
		return nil, false
	}
	return &snap.entries[raw_idx], true
}

// format_breadcrumb_path writes `<store>/<seg1>/<seg2>` into out.
format_breadcrumb_path :: proc "contextless" (snap: ^Explorer_Snapshot, out: []u8) -> string {
	pos := 0
	store_name := snapshot_store_name(snap, snap.active_store)
	if store_name == "" {
		store_name = "private"
	}
	append_text(out, &pos, store_name)
	append_text(out, &pos, "/")
	for i in 0 ..< snap.path_depth {
		seg := &snap.path[i]
		append_text(out, &pos, string(seg.name[:seg.name_len]))
		append_text(out, &pos, "/")
	}
	return string(out[:pos])
}

// format_usage_summary states each storage quota fact once on the status band right.
format_usage_summary :: proc "contextless" (usage: Usage_Info, read_only: bool, out: []u8) -> string {
	pos := 0
	num: [24]u8
	if usage.has_usage && usage.blocks >= 0 {
		append_text(out, &pos, format_i64(usage.blocks, num[:]))
		if usage.limit > 0 {
			append_text(out, &pos, "/")
			append_text(out, &pos, format_i64(usage.limit, num[:]))
		}
		append_text(out, &pos, " blocks · ")
		append_text(out, &pos, format_i64(max(usage.objects, 0), num[:]))
		append_text(out, &pos, usage.objects == 1 ? " object · " : " objects · ")
		append_text(out, &pos, format_i64(max(usage.versions, 0), num[:]))
		append_text(out, &pos, usage.versions == 1 ? " version" : " versions")
	}
	if read_only {
		if pos > 0 {
			append_text(out, &pos, " · ")
		}
		append_text(out, &pos, "read only")
	}
	return string(out[:pos])
}

// format_diff_summary summarizes storage.compare ranges cleanly for the inspector header.
format_diff_summary :: proc "contextless" (ranges: []Diff_Range, out: []u8) -> string {
	pos := 0
	num: [24]u8
	if len(ranges) == 0 {
		append_text(out, &pos, "Matches current version")
		return string(out[:pos])
	}
	total_bytes: i64 = 0
	for r in ranges {
		total_bytes += max(r.count, 0)
	}
	append_text(out, &pos, format_u64(u64(len(ranges)), num[:]))
	append_text(out, &pos, len(ranges) == 1 ? " changed range (" : " changed ranges (")
	sz_buf: [32]u8
	append_text(out, &pos, format_byte_size(total_bytes, sz_buf[:]))
	append_text(out, &pos, ")")
	return string(out[:pos])
}
