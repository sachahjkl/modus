#+build !freestanding
package plans_recipes

import "core:testing"
import "modus:contract/blake3"
import "modus:contract/errors"

@(private = "file")
expect_refusal :: proc(t: ^testing.T, record: errors.Error_Record, kind: errors.Kind, argument: i64, loc := #caller_location) {
	testing.expect_value(t, errors.Kind(record.kind), kind, loc = loc)
	testing.expect_value(t, record.argument, i64(argument), loc = loc)
}

// The name of a source: empty, the bound, one past it, the largest length;
// the bound is accepted, last.
@(test)
c_build_name_refusal_refuses_each_edge :: proc(t: ^testing.T) {
	expect_refusal(t, c_build_name_refusal(0), .Empty, C_BUILD_ARGUMENT_NAME)
	expect_refusal(t, c_build_name_refusal(MAX_ENTRY_NAME_BYTES + 1), .Too_Long, C_BUILD_ARGUMENT_NAME)
	expect_refusal(t, c_build_name_refusal(max(int)), .Too_Long, C_BUILD_ARGUMENT_NAME)
	testing.expect_value(t, c_build_name_refusal(MAX_ENTRY_NAME_BYTES), errors.Error_Record{})
	testing.expect_value(t, c_build_name_refusal(1), errors.Error_Record{})
}

// The size of a source: 0, -1, the smallest size, the bound plus one, the
// largest size, one byte past the memory object, a memory object of no
// byte; then the bound and one byte, last.
@(test)
c_build_source_refusal_refuses_each_edge :: proc(t: ^testing.T) {
	memory := u64(C_SOURCE_BYTES_LIMIT)
	for size in ([]i64{0, -1, min(i64), C_SOURCE_BYTES_LIMIT + 1, max(i64)}) {
		expect_refusal(t, c_build_source_refusal(size, memory), .Out_Of_Range, C_BUILD_ARGUMENT_SIZE)
	}
	past := c_build_source_refusal(4097, 4096)
	expect_refusal(t, past, .Out_Of_Range, C_BUILD_ARGUMENT_SIZE)
	testing.expect_value(t, past.limit, i64(4096))
	expect_refusal(t, c_build_source_refusal(1, 0), .Out_Of_Range, C_BUILD_ARGUMENT_SIZE)
	testing.expect_value(t, c_build_source_refusal(C_SOURCE_BYTES_LIMIT, memory), errors.Error_Record{})
	testing.expect_value(t, c_build_source_refusal(1, 4096), errors.Error_Record{})
}

// The count that a call host gives: none, negative, the bound plus one,
// the largest count; the bound is accepted, last.
@(test)
c_build_written_refusal_refuses_each_edge :: proc(t: ^testing.T) {
	expect_refusal(t, c_build_written_refusal(0, C_TEXT_BYTES_LIMIT), .Empty, 0)
	expect_refusal(t, c_build_written_refusal(-1, C_TEXT_BYTES_LIMIT), .Empty, 0)
	expect_refusal(t, c_build_written_refusal(min(i64), C_TEXT_BYTES_LIMIT), .Empty, 0)
	expect_refusal(t, c_build_written_refusal(C_TEXT_BYTES_LIMIT + 1, C_TEXT_BYTES_LIMIT), .Out_Of_Range, 0)
	expect_refusal(t, c_build_written_refusal(max(i64), C_TEXT_BYTES_LIMIT), .Out_Of_Range, 0)
	testing.expect_value(t, c_build_written_refusal(C_TEXT_BYTES_LIMIT, C_TEXT_BYTES_LIMIT), errors.Error_Record{})
}

// A call host that writes nothing leaves the bytes of a new memory object,
// all zero, under the count that it gives: they are refused, and no bytes
// of an earlier build can stand in for them, because each build has new
// memory objects. No byte at all is refused too.
@(test)
c_build_module_refusal_refuses_a_module_that_was_not_written :: proc(t: ^testing.T) {
	zeros: [4096]u8
	expect_refusal(t, c_build_module_refusal(zeros[:]), .Malformed, 0)
	expect_refusal(t, c_build_module_refusal(zeros[:1]), .Malformed, 0)
	expect_refusal(t, c_build_module_refusal(nil), .Malformed, 0)
	garbage := [8]u8{'n', 'o', 't', ' ', 'a', ' ', 'm', 'o'}
	expect_refusal(t, c_build_module_refusal(garbage[:]), .Malformed, 0)
}

// The module of a realisation whose bytes changed under its output hash:
// one changed byte, a byte less, no byte; the bytes of the hash, last.
@(test)
c_build_substitute_refusal_refuses_changed_bytes :: proc(t: ^testing.T) {
	bytes := [5]u8{1, 2, 3, 4, 5}
	hash := blake3.hash(bytes[:])
	changed := bytes
	changed[4] = 6
	expect_refusal(t, c_build_substitute_refusal(changed[:], hash), .Damaged, 0)
	expect_refusal(t, c_build_substitute_refusal(bytes[:4], hash), .Damaged, 0)
	expect_refusal(t, c_build_substitute_refusal(nil, hash), .Damaged, 0)
	testing.expect_value(t, c_build_substitute_refusal(bytes[:], hash), errors.Error_Record{})
}

// The memory object for the module: one byte too small, no byte; exactly
// the module, last.
@(test)
c_build_module_room_refusal_refuses_a_small_memory_object :: proc(t: ^testing.T) {
	small := c_build_module_room_refusal(4097, 4096)
	expect_refusal(t, small, .Too_Small, C_BUILD_ARGUMENT_MODULE)
	testing.expect_value(t, small.value, i64(4096))
	expect_refusal(t, c_build_module_room_refusal(1, 0), .Too_Small, C_BUILD_ARGUMENT_MODULE)
	testing.expect_value(t, c_build_module_room_refusal(4096, 4096), errors.Error_Record{})
}
