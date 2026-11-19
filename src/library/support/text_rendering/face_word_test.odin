#+build !freestanding
package text_rendering

import "core:testing"

@(test)
face_word_that_names_no_face_is_refused :: proc(t: ^testing.T) {
	// The edges first: None, one past the last member, a negative word and
	// the largest words.
	for word in ([6]i64{i64(Face.None), i64(max(Face)) + 1, -1, min(i64), max(i64), 256 + i64(Face.Interface)}) {
		face, ok := face_of_word(word)
		testing.expectf(t, !ok, "the word %d is read as the face %v", word, face)
		testing.expect_value(t, face, Face.None)
	}
	// Each member but None is read back as itself.
	for member in Face {
		if member == .None {
			continue
		}
		face, ok := face_of_word(i64(member))
		testing.expect(t, ok)
		testing.expect_value(t, face, member)
	}
}
