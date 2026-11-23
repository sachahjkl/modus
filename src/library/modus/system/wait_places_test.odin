#+build !freestanding
package system

import "core:testing"
import op "modus:contract/operation"

// The places of a list at their edges: the last word that fits is taken,
// one more is refused and changes nothing; a word with a flag needs two
// places, so it is refused with one left. A refused list is marked refused,
// never full: full ends a wait at once, which a loop would turn into a loop
// with no wait.
@(test)
a_word_past_the_places_is_refused_and_never_ends_the_wait_at_once :: proc(t: ^testing.T) {
	word, flag: u32
	wait: Wait
	testing.expect_value(t, wait_room_left(&wait), WAIT_INLINE_WORDS)
	for _ in 0 ..< WAIT_INLINE_WORDS - 1 {
		testing.expect(t, wait_word(&wait, &word, 0))
	}
	// One place left: a word with a flag needs two.
	testing.expect(t, !wait_word(&wait, &word, 0, &flag))
	testing.expect(t, wait.refused && !wait.full)
	testing.expect_value(t, wait.count, WAIT_INLINE_WORDS - 1)
	testing.expect_value(t, wait.flag_count, 0)
	testing.expect(t, wait_word(&wait, &word, 0))
	testing.expect_value(t, wait_room_left(&wait), 0)
	testing.expect(t, !wait_word(&wait, &word, 0))
	testing.expect_value(t, wait.count, WAIT_INLINE_WORDS)
	testing.expect(t, !wait.full)
}

// A wait set of the caller gives the list the places of the kernel; its
// words are the words that wait_end gives to the kernel.
@(test)
a_wait_set_holds_the_words_of_the_kernel :: proc(t: ^testing.T) {
	set := new(Wait_Set)
	defer free(set)
	word, flag: u32
	wait: Wait
	wait.set = set
	testing.expect_value(t, wait_room_left(&wait), op.WORD_WAIT_CAPACITY)
	for index in 0 ..< op.WORD_WAIT_CAPACITY / 2 {
		testing.expect(t, wait_word(&wait, &word, u32(index), &flag))
	}
	testing.expect_value(t, wait_room_left(&wait), 0)
	testing.expect(t, !wait_word(&wait, &word, 0))
	testing.expect(t, wait.refused)
	testing.expect_value(t, set.words[3].value, u64(3))
	testing.expect_value(t, set.parts[3].flag, &flag)
	// The inline places stay untouched with a set.
	testing.expect_value(t, wait.inline_words[3].address, u64(0))
	command := wait_command(set.words[:wait.count])
	testing.expect_value(t, command.values[0], u64(uintptr(&set.words[0])))
	testing.expect_value(t, command.values[1], u64(op.WORD_WAIT_CAPACITY / 2))
}

// The list on the stack is far below the list of the kernel.
@(test)
a_wait_on_the_stack_is_small :: proc(t: ^testing.T) {
	testing.expect(t, size_of(Wait) < 4096, "a wait takes more than a page of the stack")
	testing.expect(t, size_of(Wait_Set) > size_of(Wait))
}
