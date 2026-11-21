#+build !freestanding
package store

import "core:testing"

// A word of the kind of an entry that names no kind is refused: one past
// the last kind, a word past 255 and the largest word. The record keeps its
// size and the place of its kind. Each kind then reads back from its word.
@(test)
a_word_of_an_entry_kind_that_names_no_kind :: proc(t: ^testing.T) {
	refused_words := [?]u64{u64(max(Entry_Kind)) + 1, 0x100, max(u64)}
	for word in refused_words {
		_, ok := entry_kind_of_word(word)
		testing.expectf(t, !ok, "the word %d names no kind of an entry, and it is taken", word)
	}
	testing.expect_value(t, size_of(Entry), 104)
	testing.expect_value(t, offset_of(Entry, kind), 0)
	for member in Entry_Kind {
		kind, ok := entry_kind_of_word(u64(member))
		testing.expect(t, ok)
		testing.expect_value(t, kind, member)
	}
}
