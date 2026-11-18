#+build !freestanding
package operation_sequence

import "core:testing"
import "modus:contract/fixed_addresses"
import "modus:contract/operation"

// The places of the mailbox do not meet: the header fits its page, the
// sequence place holds the largest sequence, and the results start on a
// page after it and end in the mailbox.
@(test)
the_places_of_the_mailbox_do_not_meet :: proc(t: ^testing.T) {
	testing.expect(t, size_of(Mailbox_Header) <= MAILBOX_SEQUENCE_OFFSET, "the header passes its page")
	testing.expect(t, MAILBOX_RESULTS_OFFSET % operation.PAGE_SIZE == 0, "the results do not start on a page")
	testing.expect(t, MAILBOX_RESULTS_OFFSET >= MAILBOX_SEQUENCE_OFFSET + SEQUENCE_BYTES_MOST, "the results meet the largest sequence")
	testing.expect(t, MAILBOX_RESULTS_OFFSET + size_of(Runner_Results) <= MAILBOX_PAGES * operation.PAGE_SIZE, "the results pass the mailbox")
	testing.expect(t, SEQUENCE_OBJECT_PAGES * operation.PAGE_SIZE >= SEQUENCE_BYTES_MOST, "the copy of the sequence is smaller than the largest sequence")
	testing.expect(t, RESULTS_OBJECT_PAGES * operation.PAGE_SIZE >= size_of(Runner_Results), "the result object is smaller than the results")
}

// The objects of the runner are at addresses of its own choice, outside
// the band of the fixed ranges, and each area with the room of its page
// with no access meets neither the next area nor the other objects.
@(test)
the_objects_of_the_runner_do_not_meet :: proc(t: ^testing.T) {
	testing.expect(t, RUNNER_SEQUENCE_ADDRESS >= fixed_addresses.OWN_CHOICE_START, "the copy of the sequence is in the band")
	testing.expect(t, RUNNER_SEQUENCE_ADDRESS + SEQUENCE_OBJECT_PAGES * operation.PAGE_SIZE <= RUNNER_RESULTS_ADDRESS, "the copy of the sequence meets the results")
	testing.expect(t, RUNNER_RESULTS_ADDRESS + RESULTS_OBJECT_PAGES * operation.PAGE_SIZE <= RUNNER_AREAS_ADDRESS, "the results meet the first area")
	for area in 0 ..< AREAS_MOST - 1 {
		testing.expect(t, area_address(area) + (AREA_PAGES_MOST + 1) * operation.PAGE_SIZE <= area_address(area + 1), "an area and its page with no access meet the next area")
	}
	testing.expect(t, area_address(AREAS_MOST - 1) + AREA_ROOM <= operation.USER_END, "the last area passes the end of the addresses of a process")
}

// A command that succeeds leaves the pattern: each word of the pattern is
// one that no error record of the kernel holds in each field.
@(test)
the_pattern_of_a_table_is_no_error_record :: proc(t: ^testing.T) {
	pattern := details_pattern()
	testing.expect_value(t, pattern.kind, i64(DETAILS_PATTERN_WORD))
	testing.expect_value(t, pattern.found, i64(DETAILS_PATTERN_WORD))
	testing.expect(t, pattern.kind != 0 && pattern.argument != 0, "the pattern is the record of no error")
}

// Each source gives its word: the start handles, the address of an area
// with its offset, up to the last byte of its page with no access, a
// thread entry, and a value of the completion of an earlier step with its
// offset.
@(test)
each_source_gives_its_word :: proc(t: ^testing.T) {
	start := Start_Words{budget = 11, log = 12, machine = 0}
	for area in 0 ..< AREAS_MOST {
		start.areas[area] = u64(20 + area)
	}
	start.entries[.Wait_On_Word] = 0x1000
	start.entries[.Return] = 0x2000
	start.entries[.Read_Address_Zero] = 0x3000
	results: Runner_Results
	results.results[3].values[ARGUMENTS - 1] = 500
	testing.expect_value(t, argument_word({source = .Value, value = max(u64)}, &start, &results), max(u64))
	testing.expect_value(t, argument_word({source = .Budget}, &start, &results), 11)
	testing.expect_value(t, argument_word({source = .Log}, &start, &results), 12)
	testing.expect_value(t, argument_word({source = .Machine}, &start, &results), 0)
	testing.expect_value(t, argument_word({source = .Area_Handle, area = AREAS_MOST - 1}, &start, &results), u64(20 + AREAS_MOST - 1))
	largest := u64(AREA_PAGES_MOST + 1) * operation.PAGE_SIZE - 1
	last := argument_word({source = .Area_Address, area = 2, offset = largest}, &start, &results)
	testing.expect_value(t, last, area_address(2) + largest)
	testing.expect(t, last < area_address(3), "the largest offset of an area reaches the next area")
	testing.expect_value(t, argument_word({source = .Thread_Entry, entry = .Read_Address_Zero}, &start, &results), 0x3000)
	testing.expect_value(t, argument_word({source = .Result, step = 3, place = ARGUMENTS - 1, offset = 7}, &start, &results), 507)
}
