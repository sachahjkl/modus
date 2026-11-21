#+build !freestanding
package module

import "core:testing"

// A file with one export whose function record states a parameter count.
// The fuzz target sentences found a count of 32: the sentence of an error
// then indexed the 12 names of the parameters past their end.
@(private = "file")
file_with_parameter_count :: proc(count: u8) -> [dynamic]u8 {
	TABLES :: int(Table_Kind.Functions) + 1
	exports_offset := size_of(Header) + TABLES * size_of(Table_Entry)
	functions_offset := exports_offset + 2 * size_of(Export)
	file := make([dynamic]u8, functions_offset + 2 * size_of(Function))
	(^Header)(&file[0])^ = {
		magic       = MAGIC,
		version     = VERSION,
		header_size = size_of(Header),
		machine     = .X86_64,
		table_count = u32(TABLES),
	}
	directory := size_of(Header)
	(^Table_Entry)(&file[directory + int(Table_Kind.Exports) * size_of(Table_Entry)])^ = {u64(exports_offset), 2, size_of(Export)}
	(^Table_Entry)(&file[directory + int(Table_Kind.Functions) * size_of(Table_Entry)])^ = {u64(functions_offset), 2, size_of(Function)}
	(^Export)(&file[exports_offset + size_of(Export)])^ = {function = 1}
	(^Function)(&file[functions_offset + size_of(Function)])^ = {parameter_count = count}
	return file
}

@(test)
function_with_too_many_parameters_is_refused :: proc(t: ^testing.T) {
	// The edges first: one past the capacity, the count of the finding, and
	// the largest count of the field. Each one gives no description.
	for count in ([3]u8{PARAMETER_CAPACITY + 1, 32, max(u8)}) {
		file := file_with_parameter_count(count)
		defer delete(file)
		value, ok := function(file[:], 1)
		testing.expectf(t, !ok, "a function of %d parameters is not refused", count)
		testing.expect_value(t, value.parameter_count, 0)
	}
	// An export index of 0 and one past the table name no function.
	file := file_with_parameter_count(1)
	defer delete(file)
	_, ok_zero := function(file[:], 0)
	testing.expect(t, !ok_zero)
	_, ok_past := function(file[:], 2)
	testing.expect(t, !ok_past)
	// The counts within the capacity are read: 0, 1 and the capacity.
	for count in ([3]u8{0, 1, PARAMETER_CAPACITY}) {
		accepted := file_with_parameter_count(count)
		defer delete(accepted)
		value, ok := function(accepted[:], 1)
		testing.expectf(t, ok, "a function of %d parameters is refused", count)
		testing.expect_value(t, value.parameter_count, count)
	}
}
