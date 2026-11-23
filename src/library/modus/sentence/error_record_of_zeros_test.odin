#+build !freestanding
package sentence

import "modus:contract/errors"
import "core:testing"

// A failed call whose callee wrote no record gives a record of zeros. Its
// sentence says that the call failed with no record, never "no error".
// A kind that names no member says so, with no number: the number is on
// the detail lines.
@(test)
a_record_of_zeros_says_that_the_call_wrote_none :: proc(t: ^testing.T) {
	buffer: [256]u8
	writer := Writer{buffer = buffer[:]}
	record: errors.Error_Record
	error_text(&writer, &record, "storage.read", "")
	testing.expect_value(t, written(&writer), "storage.read: the call failed and gave no error record, so the cause is not known")

	past_the_kinds := i64(max(errors.Kind)) + 1
	writer = Writer{buffer = buffer[:]}
	record = {kind = past_the_kinds}
	error_text(&writer, &record, "storage.read", "")
	testing.expect_value(t, written(&writer), "storage.read: the call failed with an error kind that this process does not know, so the cause is not known")
}
