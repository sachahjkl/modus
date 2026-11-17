#+build !freestanding
package enum_word

import "core:testing"

// Each word that names no member is refused first: 0 where 0 is no member,
// one past the largest member, a word between two members, the largest
// word, and for an enumeration of negative values the word of a negative
// number that names none. Then each member comes back from its own word.
@(test)
member_of_word_refuses_a_word_that_names_no_member :: proc(t: ^testing.T) {
	From_One :: enum u64 {
		First  = 1,
		Second = 2,
	}
	With_A_Gap :: enum u64 {
		First = 1,
		Third = 3,
	}
	Negative :: enum i64 {
		Below = -2,
		Zero  = 0,
	}
	from_one_refused := [?]u64{0, u64(max(From_One)) + 1, 1 << 32, max(u64)}
	for word in from_one_refused {
		_, ok := member_of_word(From_One, word)
		testing.expectf(t, !ok, "the word %d names no member, and it is taken", word)
	}
	gap_refused := [?]u64{0, u64(With_A_Gap.First) + 1, u64(max(With_A_Gap)) + 1, max(u64)}
	for word in gap_refused {
		_, ok := member_of_word(With_A_Gap, word)
		testing.expectf(t, !ok, "the word %d names no member, and it is taken", word)
	}
	negative_refused := [?]u64{transmute(u64)i64(-1), transmute(u64)i64(-3), 1, max(u64) - 2}
	for word in negative_refused {
		_, ok := member_of_word(Negative, word)
		testing.expectf(t, !ok, "the word %d names no member, and it is taken", word)
	}
	for member in From_One {
		read, ok := member_of_word(From_One, u64(member))
		testing.expect(t, ok)
		testing.expect_value(t, read, member)
	}
	for member in With_A_Gap {
		read, ok := member_of_word(With_A_Gap, u64(member))
		testing.expect(t, ok)
		testing.expect_value(t, read, member)
	}
	for member in Negative {
		read, ok := member_of_word(Negative, transmute(u64)i64(member))
		testing.expect(t, ok)
		testing.expect_value(t, read, member)
	}
}
