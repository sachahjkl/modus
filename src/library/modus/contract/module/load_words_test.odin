#+build !freestanding
package module

import "core:testing"

// The borders of parameter directions and load error words refuse unknown
// values at the edges (one past the last member, 255/max) and round-trip
// every member.
@(test)
direction_and_load_error_borders_refuse_unknown_words :: proc(t: ^testing.T) {
	for word in ([?]u8{u8(max(Direction)) + 1, 100, max(u8)}) {
		direction, ok := direction_of_word(word)
		testing.expectf(t, !ok, "direction byte %d must be refused", word)
		testing.expect_value(t, direction, Direction.Read)
	}
	fn: Function
	fn.parameter_directions[0] = u8(max(Direction)) + 1
	_, bad_index_neg := function_parameter_direction(fn, -1)
	_, bad_index_hi := function_parameter_direction(fn, PARAMETER_CAPACITY)
	_, bad_byte := function_parameter_direction(fn, 0)
	testing.expect(t, !bad_index_neg && !bad_index_hi && !bad_byte)
	for member in Direction {
		fn.parameter_directions[0] = u8(member)
		read, ok := function_parameter_direction(fn, 0)
		testing.expect(t, ok)
		testing.expect_value(t, read, member)
	}

	for word in ([?]u32{u32(max(Load_Stage)) + 1, 256, max(u32)}) {
		stage, ok := load_stage_of_word(word)
		testing.expectf(t, !ok, "load stage word %d must be refused", word)
		testing.expect_value(t, stage, Load_Stage.None)
	}
	for member in Load_Stage {
		read, ok := load_stage_of_word(u32(member))
		testing.expect(t, ok)
		testing.expect_value(t, read, member)
	}

	for word in ([?]u32{u32(max(Error)) + 1, 256, max(u32)}) {
		file_error, ok := file_error_of_word(word)
		testing.expectf(t, !ok, "file error word %d must be refused", word)
		testing.expect_value(t, file_error, Error.None)
	}
	for member in Error {
		read, ok := file_error_of_word(u32(member))
		testing.expect(t, ok)
		testing.expect_value(t, read, member)
	}

	for word in ([?]u32{u32(max(Difference)) + 1, 256, max(u32)}) {
		difference, ok := difference_of_word(word)
		testing.expectf(t, !ok, "difference word %d must be refused", word)
		testing.expect_value(t, difference, Difference.None)
	}
	for member in Difference {
		read, ok := difference_of_word(u32(member))
		testing.expect(t, ok)
		testing.expect_value(t, read, member)
	}

	testing.expect_value(t, size_of(Function{}.parameter_directions), PARAMETER_CAPACITY)
	testing.expect_value(t, size_of(Described{}.direction), 1)
	testing.expect_value(t, size_of(Load_Error{}.stage), 4)
	testing.expect_value(t, size_of(Load_Error{}.file_error), 4)
	testing.expect_value(t, size_of(Load_Error{}.difference), 4)
}
