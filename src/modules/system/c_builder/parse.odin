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

// argument_path reads the required text field "path" from the canonical
// declaration_eval argument record and verifies that every slash-separated
// segment is a valid tree entry name (no empty segment, no leading or trailing
// slash, no "." or "..").
argument_path :: proc "contextless" (arguments: []u8) -> (path: string, ok: bool) {
	reader := declaration_eval.Output_Reader{bytes = arguments}
	tag, tag_refusal := declaration_eval.output_read_tag(&reader)
	if tag_refusal != .None || tag != .Record {
		return "", false
	}
	count, count_refusal := declaration_eval.output_read_u32(&reader)
	if count_refusal != .None {
		return "", false
	}
	found_path := false
	for _ in 0 ..< count {
		field, field_refusal := declaration_eval.output_read_string(&reader)
		if field_refusal != .None {
			return "", false
		}
		start := reader.offset
		value_tag, value_refusal := declaration_eval.output_read_tag(&reader)
		if value_refusal != .None {
			return "", false
		}
		if field == "path" {
			if found_path || value_tag != .Text {
				return "", false
			}
			value, text_refusal := declaration_eval.output_read_string(&reader)
			if text_refusal != .None || !source_path_valid(value) {
				return "", false
			}
			path = value
			found_path = true
			continue
		}
		reader.offset = start
		if declaration_eval.output_skip_value(&reader, 1) != .None {
			return "", false
		}
	}
	if !found_path || reader.offset != len(arguments) {
		return "", false
	}
	return path, true
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
