package store

import "modus:contract/enum_word"
import "modus:contract/text_encoding"

// Strict object path parser and validator for read-only object lookups across
// granted trees (src/md/features/objects_by_hash.md).
//
// A valid object path is one or more single-step entry names separated by '/':
//   - 1 to OBJECT_PATH_LIMIT (4096) bytes total;
//   - 1 to OBJECT_PATH_DEPTH_LIMIT (32) segments;
//   - each segment is 1 to ENTRY_NAME_CAPACITY (255) bytes of valid UTF-8 with
//     no control characters, no NUL byte, no '/', and neither "." nor "..";
//   - no leading '/', no trailing '/', and no empty segment ("//").
//
// Every routine is pure, contextless, and allocates no memory.

// Format property: maximum total byte length of an object path, fitting within
// one 4096-byte page of a call region.
OBJECT_PATH_LIMIT :: 4096

// Format property: maximum segment depth of an object path, matching the tree
// nesting limit of a store (NESTING_LIMIT).
OBJECT_PATH_DEPTH_LIMIT :: NESTING_LIMIT
#assert(OBJECT_PATH_DEPTH_LIMIT == 32)

// Closed set of refusals returned by object_path_validate and object_path_split.
// Explicit values allow crossing a contract border through
// object_path_problem_of_word.
Object_Path_Problem :: enum u8 {
	None             = 0, // The path is valid.
	Empty            = 1, // The path has zero bytes.
	Leading_Slash    = 2, // The path starts with '/'.
	Trailing_Slash   = 3, // The path ends with '/'.
	Empty_Segment    = 4, // Two '/' separators appear with no segment between them.
	Dot_Segment      = 5, // A segment is "." or "..".
	Bad_Byte         = 6, // A segment holds a NUL byte, a control byte, or invalid UTF-8.
	Segment_Too_Long = 7, // A segment exceeds ENTRY_NAME_CAPACITY (255) bytes.
	Too_Deep         = 8, // The path has more than OBJECT_PATH_DEPTH_LIMIT (32) segments.
	Too_Long         = 9, // The path exceeds OBJECT_PATH_LIMIT (4096) bytes.
}

// object_path_problem_of_word converts a transport word into an
// Object_Path_Problem member, refusing any word that names no member.
object_path_problem_of_word :: proc "contextless" (word: u64) -> (problem: Object_Path_Problem, ok: bool) {
	return enum_word.member_of_word(Object_Path_Problem, word)
}

// object_path_validate checks every rule of an object path without allocation.
// On success, returns segment_count (1 ..= OBJECT_PATH_DEPTH_LIMIT) and .None.
// On refusal, returns segment_count 0, the problem, the byte offset of the
// fault, and the offending byte (or 0 when no single byte caused the refusal).
object_path_validate :: proc "contextless" (path: string) -> (segment_count: int, problem: Object_Path_Problem, offset: int, bad_byte: u8) {
	if len(path) == 0 {
		return 0, .Empty, 0, 0
	}
	if len(path) > OBJECT_PATH_LIMIT {
		return 0, .Too_Long, OBJECT_PATH_LIMIT, 0
	}
	if path[0] == '/' {
		return 0, .Leading_Slash, 0, '/'
	}
	if path[len(path) - 1] == '/' {
		return 0, .Trailing_Slash, len(path) - 1, '/'
	}
	count := 0
	segment_start := 0
	for index := 0; index <= len(path); index += 1 {
		if index < len(path) && path[index] != '/' {
			continue
		}
		segment_len := index - segment_start
		if segment_len == 0 {
			return 0, .Empty_Segment, index, '/'
		}
		count += 1
		if count > OBJECT_PATH_DEPTH_LIMIT {
			return 0, .Too_Deep, segment_start, 0
		}
		if segment_len > ENTRY_NAME_CAPACITY {
			return 0, .Segment_Too_Long, segment_start, 0
		}
		segment := path[segment_start:index]
		if segment == "." || segment == ".." {
			return 0, .Dot_Segment, segment_start, '.'
		}
		// Reject NUL bytes explicitly before UTF-8 validation so offset is exact.
		for byte_index in 0 ..< segment_len {
			if segment[byte_index] == 0 {
				return 0, .Bad_Byte, segment_start + byte_index, 0
			}
		}
		if place, invalid := text_encoding.invalid_sequence_find(transmute([]u8)segment); invalid {
			return 0, .Bad_Byte, segment_start + place, segment[place]
		}
		segment_start = index + 1
	}
	return count, .None, 0, 0
}

// Object_Path_Iterator walks the '/' separated segments of an already-validated
// object path with zero heap allocation.
Object_Path_Iterator :: struct {
	path:   string,
	cursor: int,
}

// object_path_iterator_make prepares an iterator over a validated object path.
object_path_iterator_make :: proc "contextless" (path: string) -> Object_Path_Iterator {
	return {path = path, cursor = 0}
}

// object_path_next returns the next segment slice and true, or empty and false
// when the path is exhausted. Callers must validate the path with
// object_path_validate before iterating.
object_path_next :: proc "contextless" (iterator: ^Object_Path_Iterator) -> (segment: string, ok: bool) {
	if iterator == nil || iterator.cursor >= len(iterator.path) {
		return "", false
	}
	start := iterator.cursor
	end := start
	for end < len(iterator.path) && iterator.path[end] != '/' {
		end += 1
	}
	if end < len(iterator.path) {
		iterator.cursor = end + 1
	} else {
		iterator.cursor = len(iterator.path)
	}
	return iterator.path[start:end], true
}

// object_path_split validates path and fills out[:count] with zero-allocation
// segment slices. When validation refuses path, out is left untouched and
// count is 0.
object_path_split :: proc "contextless" (path: string, out: ^[OBJECT_PATH_DEPTH_LIMIT]string) -> (count: int, problem: Object_Path_Problem, offset: int, bad_byte: u8) {
	segment_count, refusal, refusal_offset, refusal_byte := object_path_validate(path)
	if refusal != .None {
		return 0, refusal, refusal_offset, refusal_byte
	}
	if out != nil {
		iterator := object_path_iterator_make(path)
		index := 0
		for seg in object_path_next(&iterator) {
			out[index] = seg
			index += 1
		}
	}
	return segment_count, .None, 0, 0
}
