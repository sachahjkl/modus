#+build !freestanding
package operation

import "core:testing"
import "modus:contract/call_outcome"

// The arguments of a Memory_Read that the kernel refuses before it reads a
// page: the edges of the object, of the length and of the limit.
@(test)
memory_read_arguments_refuse_each_edge :: proc(t: ^testing.T) {
	PAGES :: 4
	END :: PAGES * PAGE_SIZE
	// The offset at the end with a length: past the object. One past the end
	// with no length: past it too.
	testing.expect_value(t, memory_read_arguments_outcome(END, 1, PAGES, false), call_outcome.Call_Outcome.Argument_Refused)
	testing.expect_value(t, memory_read_arguments_outcome(END + 1, 0, PAGES, false), call_outcome.Call_Outcome.Argument_Refused)
	testing.expect_value(t, memory_read_arguments_outcome(END - 1, 2, PAGES, false), call_outcome.Call_Outcome.Argument_Refused)
	testing.expect_value(t, memory_read_arguments_outcome(max(u64), 1, PAGES, false), call_outcome.Call_Outcome.Argument_Refused)
	testing.expect_value(t, memory_read_arguments_outcome(1, max(u64), PAGES, false), call_outcome.Call_Outcome.Argument_Refused)
	// One past the limit, and device memory, whatever the range.
	testing.expect_value(t, memory_read_arguments_outcome(0, MEMORY_READ_LIMIT + 1, 1 << 20, false), call_outcome.Call_Outcome.Argument_Refused)
	testing.expect_value(t, memory_read_arguments_outcome(0, 1, PAGES, true), call_outcome.Call_Outcome.Argument_Refused)
	testing.expect_value(t, memory_read_arguments_outcome(0, 0, PAGES, true), call_outcome.Call_Outcome.Argument_Refused)
	// An object whose bytes do not fit the type.
	testing.expect_value(t, memory_read_arguments_outcome(0, 1, max(u64), false), call_outcome.Call_Outcome.Argument_Refused)
	// An object of no page holds no byte.
	testing.expect_value(t, memory_read_arguments_outcome(0, 1, 0, false), call_outcome.Call_Outcome.Argument_Refused)
	// The last cases: a length of 0 at the end, the last byte, the limit.
	testing.expect_value(t, memory_read_arguments_outcome(END, 0, PAGES, false), call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, memory_read_arguments_outcome(0, 0, 0, false), call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, memory_read_arguments_outcome(END - 1, 1, PAGES, false), call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, memory_read_arguments_outcome(0, MEMORY_READ_LIMIT, MEMORY_READ_LIMIT / PAGE_SIZE, false), call_outcome.Call_Outcome.Succeeded)
}

// A destination that meets a mapping of the object it reads, by one byte
// at each side, is refused; one that touches its edge is not.
@(test)
memory_read_destination_meets_a_mapping_of_its_object :: proc(t: ^testing.T) {
	MAPPING :: u64(0x10000)
	BYTES :: u64(2 * PAGE_SIZE)
	testing.expect(t, memory_read_destination_meets(MAPPING, 1, MAPPING, BYTES))
	testing.expect(t, memory_read_destination_meets(MAPPING + BYTES - 1, 10, MAPPING, BYTES))
	testing.expect(t, memory_read_destination_meets(MAPPING - 1, 2, MAPPING, BYTES))
	testing.expect(t, memory_read_destination_meets(MAPPING - PAGE_SIZE, 4 * PAGE_SIZE, MAPPING, BYTES))
	testing.expect(t, !memory_read_destination_meets(MAPPING - 10, 10, MAPPING, BYTES))
	testing.expect(t, !memory_read_destination_meets(MAPPING + BYTES, 10, MAPPING, BYTES))
	testing.expect(t, !memory_read_destination_meets(MAPPING, 0, MAPPING, BYTES))
	testing.expect(t, !memory_read_destination_meets(MAPPING, 10, MAPPING, 0))
}
