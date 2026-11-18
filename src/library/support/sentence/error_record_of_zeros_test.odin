#+build !freestanding
package sentence

import "modus:contract/errors"
import "core:fmt"
import "core:testing"

// A failed call whose callee wrote no record gives a record of zeros. Its
// sentence says that the call failed with no record, never "no error".
// A kind that names no member says its number.
@(test)
a_record_of_zeros_says_that_the_call_wrote_none :: proc(t: ^testing.T) {
	buffer: [256]u8
	writer := Writer{buffer = buffer[:]}
	record: errors.Error_Record
	error_text(&writer, &record, "storage.read", "")
	testing.expect_value(t, written(&writer), "storage.read: the call failed, and it wrote no error record")

	past_the_kinds := i64(max(errors.Kind)) + 1
	writer = Writer{buffer = buffer[:]}
	record = {kind = past_the_kinds}
	error_text(&writer, &record, "storage.read", "")
	testing.expect_value(t, written(&writer), fmt.tprintf("storage.read: an error of the kind %d, which this process does not know", past_the_kinds))
}
