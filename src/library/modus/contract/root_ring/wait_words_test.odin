#+build !freestanding
package root_ring

import "core:testing"
import op "modus:contract/operation"

// The words of the wait at the edges: no place, one place, the places of a
// machine of 1 GiB, the largest count of places, and a negative count,
// which counts as none. Each fits the most words of a wait of the kernel.
@(test)
the_wait_of_the_root_service_holds_each_queue_of_its_places :: proc(t: ^testing.T) {
	testing.expect_value(t, ROOT_WAIT_FIXED_WORDS, 12)
	testing.expect_value(t, root_wait_words(0), 18)
	testing.expect_value(t, root_wait_words(-1), 18)
	testing.expect_value(t, root_wait_words(1), 22)
	testing.expect_value(t, root_wait_words(255), 1038)
	most := root_wait_words(op.PROCESS_SLOTS_MOST - 1)
	testing.expect_value(t, most, 4110)
	testing.expect(t, most <= op.WORD_WAIT_MOST)
	// Each place adds the two words of each of its two queues.
	testing.expect_value(t, root_wait_words(101) - root_wait_words(100), ROOT_WAIT_QUEUES_OF_A_PLACE * ROOT_WAIT_WORDS_OF_A_QUEUE)
}
