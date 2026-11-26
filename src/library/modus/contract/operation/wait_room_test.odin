#+build !freestanding
#+build !modus
package operation

import "core:testing"

// The pages of a wait room at the edges: no room up to the inline words,
// the first word past them, the words of one page, one past them, the most
// words, and the words of a room of each count of pages, back.
@(test)
the_pages_of_a_wait_room :: proc(t: ^testing.T) {
	testing.expect_value(t, wait_room_pages(0), u64(0))
	testing.expect_value(t, wait_room_pages(WORD_WAIT_INLINE), u64(0))
	testing.expect_value(t, wait_room_pages(WORD_WAIT_INLINE + 1), u64(2))
	testing.expect_value(t, wait_room_pages(WORD_WAIT_INLINE + WAIT_ROOM_WORDS_OF_A_PAGE), u64(2))
	testing.expect_value(t, wait_room_pages(WORD_WAIT_INLINE + WAIT_ROOM_WORDS_OF_A_PAGE + 1), u64(3))
	testing.expect_value(t, wait_room_pages(2048), u64(32))
	most := wait_room_pages(WORD_WAIT_MOST)
	testing.expect(t, most - 1 <= WAIT_ROOM_PAGES_MOST)
	testing.expect(t, wait_room_words(most) >= WORD_WAIT_MOST)
	testing.expect_value(t, wait_room_words(0), u64(WORD_WAIT_INLINE))
	// A room holds at least the words that it was asked for, and less than
	// one page more.
	for words in ([?]u64{1, WORD_WAIT_INLINE, WORD_WAIT_INLINE + 1, 1036, 4108, WORD_WAIT_MOST}) {
		held := wait_room_words(wait_room_pages(words))
		testing.expectf(t, held >= words && held < words + WAIT_ROOM_WORDS_OF_A_PAGE + WORD_WAIT_INLINE, "%d words hold %d", words, held)
	}
}

// The command of a wait room names no thread and reads no handle; no other
// command does so.
@(test)
only_the_wait_room_sizes_the_wait :: proc(t: ^testing.T) {
	for command in Thread_Control_Command {
		testing.expect_value(t, thread_control_sizes_the_wait(command), command == .Wait_Room)
	}
}
