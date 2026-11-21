#+build !freestanding
package twins

import "core:testing"

// The word of VALUE_MODE crosses the border of the context. Each word that
// names no mode is refused first: one past the last mode, a word past 32
// bits, the largest word. Then each mode comes back from its own word.
@(test)
the_word_of_the_mode_of_a_twin :: proc(t: ^testing.T) {
	refused := [?]u64{u64(max(Twin_Mode)) + 1, u64(max(Twin_Mode)) + 2, 1 << 32, max(u64)}
	for word in refused {
		_, ok := twin_mode_of_word(word)
		testing.expectf(t, !ok, "the word %d names no mode, and it is taken", word)
	}
	for mode in Twin_Mode {
		read, ok := twin_mode_of_word(u64(mode))
		testing.expect(t, ok)
		testing.expect_value(t, read, mode)
	}
}
