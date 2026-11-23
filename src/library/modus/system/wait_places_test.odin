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

// A wait set of the caller gives the list its places, up to the room that
// the kernel gave the thread; its words are the words that wait_end gives
// to the kernel. The edges: the room full, one word past it.
@(test)
a_wait_set_holds_the_words_of_its_room :: proc(t: ^testing.T) {
	WORDS :: 1036 // The root service of a machine of 1 GiB.
	words := make([]op.Word, WORDS)
	parts := make([]Wait_Part, WORDS)
	defer delete(words)
	defer delete(parts)
	set := wait_set_of(words, parts)
	set.room = WORDS // What the kernel gave: a host test has no kernel.
	word, flag: u32
	wait: Wait
	wait.set = &set
	testing.expect_value(t, wait_room_left(&wait), WORDS)
	for index in 0 ..< WORDS / 2 {
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
	testing.expect_value(t, command.values[1], u64(WORDS / 2))
}

// A set whose room the kernel refused holds the words of the kernel with no
// room: the word past them is refused, not sent.
@(test)
a_wait_set_with_no_room_refuses_past_the_inline_words :: proc(t: ^testing.T) {
	words: [200]op.Word
	parts: [200]Wait_Part
	set := wait_set_of(words[:], parts[:])
	set.room = WAIT_INLINE_WORDS
	word: u32
	wait := Wait{set = &set}
	for _ in 0 ..< WAIT_INLINE_WORDS {
		testing.expect(t, wait_word(&wait, &word, 0))
	}
	testing.expect(t, !wait_word(&wait, &word, 0))
	testing.expect(t, wait.refused)
	testing.expect_value(t, wait.count, WAIT_INLINE_WORDS)
}

// A set takes the shorter of its two tables, and at most the words of a
// wait of the kernel; an empty set has no place.
@(test)
a_wait_set_takes_the_shorter_table :: proc(t: ^testing.T) {
	words: [10]op.Word
	parts: [7]Wait_Part
	testing.expect_value(t, len(wait_set_of(words[:], parts[:]).words), 7)
	testing.expect_value(t, len(wait_set_of(words[:0], parts[:]).parts), 0)
	many_words := make([]op.Word, op.WORD_WAIT_MOST + 1)
	many_parts := make([]Wait_Part, op.WORD_WAIT_MOST + 1)
	defer delete(many_words)
	defer delete(many_parts)
	testing.expect_value(t, len(wait_set_of(many_words, many_parts).words), op.WORD_WAIT_MOST)
}

// The list on the stack is far below the list of the kernel.
@(test)
a_wait_on_the_stack_is_small :: proc(t: ^testing.T) {
	testing.expect(t, size_of(Wait) < 4096, "a wait takes more than a page of the stack")
	// A set names the places of its caller, and holds none itself.
	testing.expect(t, size_of(Wait_Set) <= 48)
}
