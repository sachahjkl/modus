package machine

import "core:strings"
import "core:testing"
import "internal:root/entropy_read_deadline"

// The step that waits for the line of the deadline of an entropy read has a
// bound larger than that deadline, and the line names the deadline of the
// system in seconds, with no mark of the format left in it.
@(test)
the_step_of_the_entropy_deadline_outlasts_the_deadline :: proc(t: ^testing.T) {
	testing.expect(t, ENTROPY_READ_LATE_STEP_SECONDS * 1000 > entropy_read_deadline.READ_DEADLINE_MILLISECONDS, "the step must outlast the deadline of the read that it waits for")
	line := entropy_read_late_line()
	defer delete(line)
	testing.expect(t, !strings.contains(line, "%"), "the line has no mark of its format")
	testing.expect(t, strings.has_prefix(line, "root: the entropy device did not answer a read in "), "the line is the line of the root service")
}
