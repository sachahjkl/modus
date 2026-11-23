#+build !freestanding
package system

import op "modus:contract/operation"
import "core:testing"

// A list with no word twice is kept whole; a word twice keeps its first
// place and the order of the others; a word with two values ends the wait
// at once; an empty list stays empty.
@(test)
a_list_keeps_each_word_once :: proc(t: ^testing.T) {
	empty: [0]op.Word
	kept, at_once := words_once(empty[:])
	testing.expect(t, kept == 0 && !at_once)
	whole := [3]op.Word{{address = 4, value = 1}, {address = 8, value = 1}, {address = 12, value = 0}}
	kept, at_once = words_once(whole[:])
	testing.expect(t, kept == 3 && !at_once)
	twice := [5]op.Word{{address = 4, value = 1}, {address = 8, value = 2}, {address = 4, value = 1}, {address = 12, value = 3}, {address = 8, value = 2}}
	kept, at_once = words_once(twice[:])
	testing.expect(t, kept == 3 && !at_once)
	testing.expect_value(t, twice[0].address, u64(4))
	testing.expect_value(t, twice[1].address, u64(8))
	testing.expect_value(t, twice[2].address, u64(12))
	// The value of a word is its low 32 bits: a high part differs, the
	// value is the same.
	same := [2]op.Word{{address = 4, value = 1}, {address = 4, value = 1 | 1 << 40}}
	kept, at_once = words_once(same[:])
	testing.expect(t, kept == 1 && !at_once)
	other := [2]op.Word{{address = 4, value = 1}, {address = 4, value = 2}}
	_, at_once = words_once(other[:])
	testing.expect(t, at_once)
}
