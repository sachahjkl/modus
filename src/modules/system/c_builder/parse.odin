// Pure argument and input parsing helpers for the C builder module
// (src/md/features/application_projects.md, "The catalog of the system").
package c_builder

import "modus:contract/blake3"
import "modus:contract/declaration_eval"
import "modus:contract/object_cache"
import pr "modus:contract/plans_recipes"
import "modus:contract/tree_hash"

// Format property: maximum path depth inside a project source tree.
MAX_SOURCE_PATH_SEGMENTS :: 32

// Format property: maximum path length in bytes.
MAX_SOURCE_PATH_BYTES :: 1024

// Plan value: maximum C translation units in one multi-unit c_builder recipe
// (covers chibicc's 14 units and C libraries such as Lua and zstd).
MAX_BUILD_UNITS :: 64

// Plan value: maximum assembly support units in one multi-unit c_builder recipe.
MAX_BUILD_ASSEMBLY :: 16

// Plan value: maximum header files packed into one multi-unit c_builder recipe.
MAX_BUILD_HEADERS :: 256

// Closed set of build modes accepted by c_builder.
Build_Mode :: enum u8 {
	None        = 0,
	Single_Unit = 1,
	Multi_Unit  = 2,
}

// Parsed arguments of one c_builder invocation (single-file or multi-unit).
Build_Arguments :: struct {
	mode:           Build_Mode,
	single_path:    string,
	units:          [MAX_BUILD_UNITS]string,
	unit_count:     int,
	assembly:       [MAX_BUILD_ASSEMBLY]string,
	assembly_count: int,
	headers:        [MAX_BUILD_HEADERS]string,
	header_count:   int,
	exports:        string,
}

// parse_path_list_value reads a canonical declaration_eval List of Text paths
// into out, validating every path and refusing non-Text items, duplicates, or overflow.
@(private = "file")
parse_path_list_value :: proc "contextless" (reader: ^declaration_eval.Output_Reader, out: []string) -> (count: int, ok: bool) {
	item_count, count_refusal := declaration_eval.output_read_u32(reader)
	if count_refusal != .None || int(item_count) > len(out) {
		return 0, false
	}
	for _ in 0 ..< item_count {
		item_tag, tag_refusal := declaration_eval.output_read_tag(reader)
		if tag_refusal != .None || item_tag != .Text {
			return 0, false
		}
		item, text_refusal := declaration_eval.output_read_string(reader)
		if text_refusal != .None || !source_path_valid(item) {
			return 0, false
		}
		for prev in out[:count] {
			if prev == item {
				return 0, false
			}
		}
		out[count] = item
		count += 1
	}
	return count, true
}

// arguments_parse reads the canonical declaration_eval argument record for
// either single-file mode (`path`: Text) or multi-unit mode (`units`: List of Text,
// optional `assembly`: List of Text, optional `headers`: List of Text, optional
// `exports`: Text). Refuses mixing modes, duplicate fields, bad paths, or trailing bytes.
arguments_parse :: proc "contextless" (arguments: []u8, out: ^Build_Arguments) -> bool {
	if out == nil {
		return false
	}
	out^ = {}
	reader := declaration_eval.Output_Reader{bytes = arguments}
	tag, tag_refusal := declaration_eval.output_read_tag(&reader)
	if tag_refusal != .None || tag != .Record {
		return false
	}
	count, count_refusal := declaration_eval.output_read_u32(&reader)
	if count_refusal != .None {
		return false
	}
	found_path := false
	found_units := false
	found_assembly := false
	found_headers := false
	found_exports := false

	for _ in 0 ..< count {
		field, field_refusal := declaration_eval.output_read_string(&reader)
		if field_refusal != .None {
			return false
		}
		start := reader.offset
		value_tag, value_refusal := declaration_eval.output_read_tag(&reader)
		if value_refusal != .None {
			return false
		}
		switch field {
		case "path":
			if found_path || value_tag != .Text {
				return false
			}
			value, text_refusal := declaration_eval.output_read_string(&reader)
			if text_refusal != .None || !source_path_valid(value) {
				return false
			}
			out.single_path = value
			found_path = true
		case "units":
			if found_units || value_tag != .List {
				return false
			}
			n, list_ok := parse_path_list_value(&reader, out.units[:])
			if !list_ok || n == 0 {
				return false
			}
			out.unit_count = n
			found_units = true
		case "assembly":
			if found_assembly || value_tag != .List {
				return false
			}
			n, list_ok := parse_path_list_value(&reader, out.assembly[:])
			if !list_ok {
				return false
			}
			out.assembly_count = n
			found_assembly = true
		case "headers":
			if found_headers || value_tag != .List {
				return false
			}
			n, list_ok := parse_path_list_value(&reader, out.headers[:])
			if !list_ok {
				return false
			}
			out.header_count = n
			found_headers = true
		case "exports":
			if found_exports || value_tag != .Text {
				return false
			}
			value, text_refusal := declaration_eval.output_read_string(&reader)
			if text_refusal != .None {
				return false
			}
			out.exports = value
			found_exports = true
		case:
			reader.offset = start
			if declaration_eval.output_skip_value(&reader, 1) != .None {
				return false
			}
		}
	}
	if reader.offset != len(arguments) {
		return false
	}
	if found_path && found_units {
		return false
	}
	if found_path {
		if found_assembly || found_headers || found_exports {
			return false
		}
		out.mode = .Single_Unit
		return true
	}
	if found_units {
		out.mode = .Multi_Unit
		return true
	}
	return false
}

// argument_path reads the required text field "path" from a single-unit
// declaration_eval argument record.
argument_path :: proc "contextless" (arguments: []u8) -> (path: string, ok: bool) {
	parsed: Build_Arguments
	if !arguments_parse(arguments, &parsed) || parsed.mode != .Single_Unit {
		return "", false
	}
	return parsed.single_path, true
}

// source_path_valid validates a relative forward-slash path inside a source tree.
source_path_valid :: proc "contextless" (path: string) -> bool {
	if len(path) == 0 || len(path) > MAX_SOURCE_PATH_BYTES {
		return false
	}
	if path[0] == '/' || path[len(path) - 1] == '/' {
		return false
	}
	segments := 0
	rest := path
	for len(rest) > 0 {
		segment, next, ok := path_segment_next(rest)
		if !ok || len(segment) == 0 {
			return false
		}
		if tree_hash.tree_name_validate(transmute([]u8)segment) != .None {
			return false
		}
		segments += 1
		if segments > MAX_SOURCE_PATH_SEGMENTS {
			return false
		}
		rest = next
	}
	return segments > 0
}

// path_segment_next splits the leading path segment from rest.
path_segment_next :: proc "contextless" (rest: string) -> (segment: string, remaining: string, ok: bool) {
	if len(rest) == 0 {
		return "", "", false
	}
	for index in 0 ..< len(rest) {
		if rest[index] == '/' {
			if index == 0 || index + 1 >= len(rest) {
				return "", "", false
			}
			return rest[:index], rest[index + 1:], true
		}
	}
	return rest, "", true
}

// input_row_find locates an input row by exact name and expected object kind.
input_row_find :: proc "contextless" (
	rows: []pr.Recipe_Input_Row,
	name: string,
	expected_kind: object_cache.Cache_Object_Kind,
) -> (hash: blake3.Hash, found: bool) {
	for &row in rows {
		name_len := 0
		for name_len < len(row.name) && row.name[name_len] != 0 {
			name_len += 1
		}
		if string(row.name[:name_len]) != name {
			continue
		}
		kind, kind_ok := object_cache.cache_object_kind_of_word(u64(row.kind))
		if !kind_ok || kind != expected_kind {
			return {}, false
		}
		result := blake3.Hash(row.hash)
		if object_cache.hash_is_zero(result) {
			return {}, false
		}
		return result, true
	}
	return {}, false
}
