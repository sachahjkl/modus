#+build !freestanding
package operation

import "core:testing"

@(test)
status_word_that_names_no_status_is_refused :: proc(t: ^testing.T) {
	// The edges first: one past the last member, and the largest word.
	for word in ([3]u64{u64(max(Status)) + 1, u64(max(u32)), max(u64)} ) {
		_, ok := status_of_word(word)
		testing.expectf(t, !ok, "the word %d is read as a status", word)
	}
	// Each member is read back as itself.
	for member in Status {
		status, ok := status_of_word(u64(member))
		testing.expect(t, ok)
		testing.expect_value(t, status, member)
	}
}
