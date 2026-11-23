#+build !freestanding
package disk_process

import "core:strings"
import "core:testing"
import "modus:contract/errors"

@(private = "file")
expect_refusal :: proc(t: ^testing.T, record: errors.Error_Record, kind: errors.Kind, argument: i64, loc := #caller_location) {
	testing.expect_value(t, errors.Kind(record.kind), kind, loc = loc)
	testing.expect_value(t, record.argument, argument, loc = loc)
}

// The edges of a nickname: empty, the limit, one past it given whole, one
// past it after a cut copy, a byte 0, a /, "." and "..", the two reserved
// names. The accepted name comes last.
@(test)
nickname_refusal_refuses_each_edge :: proc(t: ^testing.T) {
	expect_refusal(t, nickname_refusal("", 0, 1, .Make), .Empty, 1)
	at_limit := strings.repeat("a", NAME_LIMIT, context.temp_allocator)
	past_limit := strings.repeat("a", NAME_LIMIT + 1, context.temp_allocator)
	expect_refusal(t, nickname_refusal(past_limit, NAME_LIMIT + 1, 1, .Make), .Too_Long, 1)
	// The copy kept NAME_LIMIT bytes: the length that the caller gave decides.
	cut := nickname_refusal(at_limit, NAME_LIMIT + 1, 1, .Make)
	expect_refusal(t, cut, .Too_Long, 1)
	testing.expect_value(t, cut.value, i64(NAME_LIMIT + 1))
	expect_refusal(t, nickname_refusal(at_limit, max(int), 1, .Make), .Too_Long, 1)
	zero := nickname_refusal("he\x00lo", 5, 1, .Make)
	expect_refusal(t, zero, .Bad_Byte, 1)
	testing.expect_value(t, zero.value, i64(2))
	expect_refusal(t, nickname_refusal("a/b", 3, 1, .Make), .Bad_Byte, 1)
	expect_refusal(t, nickname_refusal(".", 1, 1, .Make), .Bad_Byte, 1)
	expect_refusal(t, nickname_refusal("..", 2, 1, .Make), .Bad_Byte, 1)
	// The two names that the store keeps: they exist for a make, and name
	// no module file for a read.
	expect_refusal(t, nickname_refusal(STORE_NAME, len(STORE_NAME), 1, .Make), .Exists, 1)
	expect_refusal(t, nickname_refusal(TABLE_OBJECT_NAME, len(TABLE_OBJECT_NAME), 1, .Make), .Exists, 1)
	expect_refusal(t, nickname_refusal(STORE_NAME, len(STORE_NAME), 1, .Read), .Absent, 1)
	expect_refusal(t, nickname_refusal(TABLE_OBJECT_NAME, len(TABLE_OBJECT_NAME), 1, .Read), .Absent, 1)
	// A read refuses a bad name as a make does.
	expect_refusal(t, nickname_refusal("a/b", 3, 1, .Read), .Bad_Byte, 1)
	testing.expect_value(t, nickname_refusal(at_limit, NAME_LIMIT, 1, .Make), errors.Error_Record{})
	testing.expect_value(t, nickname_refusal("hello", 5, 1, .Make), errors.Error_Record{})
}

// The edges of the size of a put: 0, a negative size, the largest negative
// size, the bound, one past it, the largest size, one byte past the memory
// object; then a size that fits, last.
@(test)
put_size_refusal_refuses_each_edge :: proc(t: ^testing.T) {
	memory := u64(16 * 4096)
	for size in ([]i64{0, -1, min(i64), FILE_BYTES_LIMIT + 1, max(i64)}) {
		expect_refusal(t, put_size_refusal(size, u64(FILE_BYTES_LIMIT), 3), .Out_Of_Range, 3)
	}
	past := put_size_refusal(i64(memory) + 1, memory, 3)
	expect_refusal(t, past, .Out_Of_Range, 3)
	testing.expect_value(t, past.limit, i64(memory))
	expect_refusal(t, put_size_refusal(1, 0, 3), .Out_Of_Range, 3)
	testing.expect_value(t, put_size_refusal(FILE_BYTES_LIMIT, u64(FILE_BYTES_LIMIT), 3), errors.Error_Record{})
	testing.expect_value(t, put_size_refusal(i64(memory), memory, 3), errors.Error_Record{})
	testing.expect_value(t, put_size_refusal(1, memory, 3), errors.Error_Record{})
}

// An absent object, an object of 0 bytes, one past the bound, a negative
// size; then a stored file, last.
@(test)
stored_file_refusal_refuses_each_edge :: proc(t: ^testing.T) {
	expect_refusal(t, stored_file_refusal(0, true, 1), .Absent, 1)
	expect_refusal(t, stored_file_refusal(100, true, 1), .Absent, 1)
	expect_refusal(t, stored_file_refusal(0, false, 1), .Out_Of_Range, 1)
	expect_refusal(t, stored_file_refusal(-1, false, 1), .Out_Of_Range, 1)
	expect_refusal(t, stored_file_refusal(FILE_BYTES_LIMIT + 1, false, 1), .Out_Of_Range, 1)
	testing.expect_value(t, stored_file_refusal(FILE_BYTES_LIMIT, false, 1), errors.Error_Record{})
	testing.expect_value(t, stored_file_refusal(1, false, 1), errors.Error_Record{})
}

// A memory object too small by one byte, of no byte; then one that holds
// the file exactly, last.
@(test)
read_room_refusal_refuses_a_small_memory_object :: proc(t: ^testing.T) {
	small := read_room_refusal(4097, 4096, 2)
	expect_refusal(t, small, .Too_Small, 2)
	testing.expect_value(t, small.value, i64(4096))
	testing.expect_value(t, small.limit, i64(4097))
	expect_refusal(t, read_room_refusal(1, 0, 2), .Too_Small, 2)
	testing.expect_value(t, read_room_refusal(4096, 4096, 2), errors.Error_Record{})
}
