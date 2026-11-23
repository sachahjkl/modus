#+build !freestanding
package word_table

import "core:testing"

// A table of 16 frames on the host.
test_table :: proc() -> Table {
	return {heads = make([]^Entry, buckets_of_frames(16)), frames = 16}
}

// The entries of a word, in a list: the threads that hold it.
threads_of :: proc(table: ^Table, word: u64) -> (threads: [dynamic]u32) {
	first, _ := first_of_word(table, word)
	for entry := first; entry != nil; entry = entry.word_next {
		append(&threads, entry.thread)
	}
	return threads
}

// A thread holds a word once: the second entry of the same word and the
// same thread is refused and changes nothing; another thread is taken.
@(test)
a_word_twice_in_one_thread_is_refused :: proc(t: ^testing.T) {
	table := test_table()
	defer delete(table.heads)
	entries: [3]Entry
	ok, _ := insert(&table, &entries[0], 0x1000, 7, 1)
	testing.expect(t, ok)
	twice, _ := insert(&table, &entries[1], 0x1000, 7, 1)
	testing.expect(t, !twice)
	testing.expect_value(t, entries[1], Entry{})
	other, _ := insert(&table, &entries[2], 0x1000, 8, 1)
	testing.expect(t, other)
	listed := threads_of(&table, 0x1000)
	defer delete(listed)
	testing.expect_value(t, len(listed), 2)
}

// The cost bound: a frame full of distinct words, each held by one thread,
// and one word held by 100 threads. A wake of that word reads at most the
// distinct words of its frame and the entries of its word; a word of
// another frame reads nothing of this frame. The edges: the first word of
// the frame, the last, and a frame with no word.
@(test)
a_wake_reads_its_frame_and_its_word_only :: proc(t: ^testing.T) {
	table := test_table()
	defer delete(table.heads)
	entries := make([]Entry, WORDS_OF_A_FRAME + 100)
	defer delete(entries)
	frame := u64(3) * PAGE_SIZE
	for index in 0 ..< WORDS_OF_A_FRAME {
		ok, _ := insert(&table, &entries[index], frame + u64(index) * 4, u32(index + 1), 0)
		testing.expect(t, ok)
	}
	shared := frame + 8
	for index in 0 ..< 100 {
		ok, steps := insert(&table, &entries[WORDS_OF_A_FRAME + index], shared, u32(10_000 + index), 0)
		testing.expect(t, ok)
		testing.expect(t, steps <= WORDS_OF_A_FRAME + 1 + index + 1)
	}
	first, steps := first_of_word(&table, shared)
	testing.expect(t, first != nil && steps <= WORDS_OF_A_FRAME)
	held := 0
	for entry := first; entry != nil; entry = entry.word_next {
		held += 1
		testing.expect_value(t, entry.word, shared)
	}
	testing.expect_value(t, held, 101)
	_, last_steps := first_of_word(&table, frame + (WORDS_OF_A_FRAME - 1) * 4)
	testing.expect(t, last_steps <= WORDS_OF_A_FRAME)
	none, none_steps := first_of_word(&table, 5 * PAGE_SIZE)
	testing.expect(t, none == nil && none_steps == 0)
	// A word of a device, past the frames: its own bucket.
	device := u64(1 << 40)
	device_entry: Entry
	ok, device_steps := insert(&table, &device_entry, device, 1, 0)
	testing.expect(t, ok && device_steps == 0)
	found, _ := first_of_word(&table, device)
	testing.expect(t, found == &device_entry)
}

// A remove of a first entry gives its place to the next entry of its word;
// a remove of a middle entry and of the last leaves the others. Each
// remove leaves a table that finds each word that is left, and none that
// is gone.
@(test)
a_remove_keeps_each_other_entry :: proc(t: ^testing.T) {
	table := test_table()
	defer delete(table.heads)
	entries: [6]Entry
	words := [6]u64{0x2000, 0x2000, 0x2000, 0x2004, 0x2008, 0x2004}
	for &entry, index in entries {
		ok, _ := insert(&table, &entry, words[index], u32(index + 1), 0)
		testing.expect(t, ok)
	}
	first, _ := first_of_word(&table, 0x2000)
	testing.expect(t, first == &entries[0])
	remove(&table, &entries[0])
	first, _ = first_of_word(&table, 0x2000)
	testing.expect(t, first != nil && first != &entries[0] && first.word_previous == nil)
	remove(&table, &entries[2])
	remove(&table, &entries[4])
	gone, _ := first_of_word(&table, 0x2008)
	testing.expect(t, gone == nil)
	left := threads_of(&table, 0x2000)
	defer delete(left)
	testing.expect_value(t, len(left), 1)
	testing.expect_value(t, left[0], u32(2))
	remove(&table, &entries[1])
	remove(&table, &entries[3])
	remove(&table, &entries[5])
	for head in table.heads {
		testing.expect(t, head == nil)
	}
}

// Many inserts and removes in a mixed order, against a count of the
// entries of each word.
@(test)
the_table_matches_a_count_of_each_word :: proc(t: ^testing.T) {
	table := test_table()
	defer delete(table.heads)
	WORDS :: 37
	THREADS :: 23
	entries := make([]Entry, WORDS * THREADS)
	in_table := make([]bool, WORDS * THREADS)
	defer delete(entries)
	defer delete(in_table)
	state := u64(0x2545_F491_4F6C_DD1D)
	for _ in 0 ..< 20_000 {
		state = state * 6364136223846793005 + 1442695040888963407
		place := int(state >> 33) % len(entries)
		word := u64(0x3000 + (place % WORDS) * 4 + (place % 3) * PAGE_SIZE)
		if in_table[place] {
			remove(&table, &entries[place])
			in_table[place] = false
		} else {
			ok, _ := insert(&table, &entries[place], word, u32(place / WORDS + 1), 0)
			testing.expect(t, ok)
			in_table[place] = true
		}
	}
	for place in 0 ..< len(entries) {
		word := u64(0x3000 + (place % WORDS) * 4 + (place % 3) * PAGE_SIZE)
		listed := threads_of(&table, word)
		found := false
		for thread in listed {
			found ||= thread == u32(place / WORDS + 1)
		}
		delete(listed)
		testing.expect_value(t, found, in_table[place])
	}
}
