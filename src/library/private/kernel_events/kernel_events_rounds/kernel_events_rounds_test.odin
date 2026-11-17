#+build !freestanding
package kernel_events_rounds

import "core:testing"

// The word of the shared page crosses the border of the child. Each word
// that names no round to run is refused first: the word of None, one past
// the last round, the largest word. Then each round comes back from its
// own word.
@(test)
a_word_that_names_no_round_is_refused :: proc(t: ^testing.T) {
	refused := [?]u32{u32(Round.None), u32(max(Round)) + 1, max(u32)}
	for word in refused {
		round, ok := round_of_word(word)
		testing.expectf(t, !ok, "the word %d names no round to run, and it is taken", word)
		testing.expect_value(t, round, Round.None)
	}
	for round in Round {
		if round == .None {
			continue
		}
		read, ok := round_of_word(u32(round))
		testing.expect(t, ok)
		testing.expect_value(t, read, round)
	}
}
