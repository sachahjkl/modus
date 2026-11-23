#+build !freestanding
package plans_recipes

import "core:testing"

// The border of a refusal word: None, the first word past the last member,
// a word past 255 that a cast to u8 would wrap to a member, and the largest
// word are refused; each member but None comes back as itself.
@(test)
a_refusal_word_that_names_no_refusal_is_refused :: proc(t: ^testing.T) {
	last := u64(max(Recipe_Refusal))
	for word in ([?]u64{0, last + 1, 256 + u64(Recipe_Refusal.Builder_Absent), max(u64)}) {
		_, ok := recipe_refusal_of_word(word)
		testing.expectf(t, !ok, "the word %d is refused", word)
	}
	for member in Recipe_Refusal {
		if member == .None {
			continue
		}
		refusal, ok := recipe_refusal_of_word(u64(member))
		testing.expect(t, ok && refusal == member)
	}
}
