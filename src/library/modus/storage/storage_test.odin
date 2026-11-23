#+build !freestanding
package storage

import "core:testing"

// The kind of a Listed row comes from the storage service. Each word that
// names no entry is refused first: None, one past the last kind, a
// negative word, the largest and the smallest word. Then each kind of an
// entry comes back from its own word.
@(test)
a_kind_that_names_no_entry_is_refused :: proc(t: ^testing.T) {
	refused := [?]i64{i64(Entry_Kind.None), i64(max(Entry_Kind)) + 1, -1, max(i64), min(i64)}
	for word in refused {
		_, ok := entry_kind_of_word(word)
		testing.expectf(t, !ok, "the kind %d names no entry, and it is taken", word)
	}
	for kind in Entry_Kind {
		if kind == .None {
			continue
		}
		read, ok := entry_kind_of_word(i64(kind))
		testing.expect(t, ok)
		testing.expect_value(t, read, kind)
	}
}
