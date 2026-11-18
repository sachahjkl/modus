#+build !freestanding
package errors

import "core:testing"

// An error record comes from another process. Each word of its kind, its
// unit and its end that names no member is refused first: -1, one past the
// last member, the largest and the smallest word. Then each member comes
// back from its own word.
@(test)
a_word_of_an_error_record_that_names_no_member_is_refused :: proc(t: ^testing.T) {
	refuse :: proc(t: ^testing.T, words: []i64, read: proc "contextless" (word: i64) -> bool) {
		for word in words {
			testing.expectf(t, !read(word), "the word %d names no member, and it is taken", word)
		}
	}
	refuse(t, {-1, i64(max(Kind)) + 1, max(i64), min(i64)}, proc "contextless" (word: i64) -> bool {
		_, ok := kind_of_word(word)
		return ok
	})
	refuse(t, {-1, i64(max(Unit)) + 1, max(i64), min(i64)}, proc "contextless" (word: i64) -> bool {
		_, ok := unit_of_word(word)
		return ok
	})
	refuse(t, {-1, i64(max(End)) + 1, max(i64), min(i64)}, proc "contextless" (word: i64) -> bool {
		_, ok := end_of_word(word)
		return ok
	})
	for member in Kind {
		read, ok := kind_of_word(i64(member))
		testing.expect(t, ok)
		testing.expect_value(t, read, member)
	}
	for member in Unit {
		read, ok := unit_of_word(i64(member))
		testing.expect(t, ok)
		testing.expect_value(t, read, member)
	}
	for member in End {
		read, ok := end_of_word(i64(member))
		testing.expect(t, ok)
		testing.expect_value(t, read, member)
	}
}
