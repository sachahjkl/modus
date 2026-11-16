#+build !freestanding
package sentence

import "modus:contract/errors"
import "core:testing"

// A commit that the read back refused: the sentence says that the disk did
// not keep the blocks, and that the store keeps its state, not that the
// device reported an error, as the device answered Ok.
@(test)
a_commit_refused_by_its_read_back :: proc(t: ^testing.T) {
	buffer: [256]u8
	writer := Writer{buffer = buffer[:]}
	record := errors.error_make(.Device, .Dropped_Writes, 0, 0, 0, 1)
	error_text(&writer, &record, "storage.write", "")
	testing.expect_value(t, written(&writer), "storage.write: the disk did not keep 1 block of the commit: the commit is refused, and the store keeps its state before it")

	writer = Writer{buffer = buffer[:]}
	record = errors.error_make(.Device, .Dropped_Writes, 0, 0, 0, 3)
	error_text(&writer, &record, "storage.write", "")
	testing.expect_value(t, written(&writer), "storage.write: the disk did not keep 3 blocks of the commit: the commit is refused, and the store keeps its state before it")

	// With no unit, the sentence of a device that reported an error stays.
	writer = Writer{buffer = buffer[:]}
	record = errors.error_make(.Device)
	error_text(&writer, &record, "storage.write", "")
	testing.expect_value(t, written(&writer), "storage.write: the device reported an error")
}
