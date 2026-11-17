#+build !freestanding
package module

import "core:testing"

// A byte of a type that names no type is refused by each border: one past
// the last type, a byte in the middle of the rest, and the largest byte. An
// index of a parameter that is negative or past the capacity is refused.
// The size of a field of no type is 0, so a record with it is refused. Each
// type then reads back from its own byte.
@(test)
a_byte_that_names_no_type_is_refused :: proc(t: ^testing.T) {
	refused_bytes := [?]u8{u8(max(Type)) + 1, 200, max(u8)}
	for word in refused_bytes {
		_, ok := type_of_word(word)
		testing.expectf(t, !ok, "the byte %d names no type, and it is taken", word)
		function: Function
		function.result = word
		_, result_ok := function_result_type(function)
		testing.expectf(t, !result_ok, "the result byte %d names no type, and it is taken", word)
		function.parameters[PARAMETER_CAPACITY - 1] = word
		_, parameter_ok := function_parameter_type(function, PARAMETER_CAPACITY - 1)
		testing.expectf(t, !parameter_ok, "the parameter byte %d names no type, and it is taken", word)
		field := Field{type = word, detail = 8}
		_, field_ok := field_type(field)
		testing.expectf(t, !field_ok, "the field byte %d names no type, and it is taken", word)
		testing.expect_value(t, field_size(field), 0)
		testing.expect_value(t, call_argument_count(1, word, false), 1)
	}
	function: Function
	_, below_ok := function_parameter_type(function, -1)
	_, past_ok := function_parameter_type(function, PARAMETER_CAPACITY)
	testing.expect(t, !below_ok && !past_ok)
	for member in Type {
		read, ok := type_of_word(u8(member))
		testing.expect(t, ok)
		testing.expect_value(t, read, member)
		function.result = u8(member)
		function.parameters[0] = u8(member)
		result, result_ok := function_result_type(function)
		parameter, parameter_ok := function_parameter_type(function, 0)
		field_read, field_ok := field_type(Field{type = u8(member)})
		testing.expect(t, result_ok && parameter_ok && field_ok)
		testing.expect_value(t, result, member)
		testing.expect_value(t, parameter, member)
		testing.expect_value(t, field_read, member)
	}
}
