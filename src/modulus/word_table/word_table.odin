// The lists of the word wait, keyed by the word (docs/ARCHITECTURE.md,
// "Locks of the kernel", "The word wait"; src/md/data/table_sizes.md).
//
// A waited word is a word of 32 bits in a page frame. The table has one
// bucket for each frame of the machine, and a few for the frames of
// devices, so a bucket holds only the words of one frame: at most
// WORDS_OF_A_FRAME distinct words, whatever a process does. In a bucket each
// distinct word has one first entry, in the list of the bucket; the other
// entries of the same word hang from it. So a wake walks the distinct words
// of its frame to find its word, then only the entries of its word. A
// thread holds a word at most once in one wait: a second entry of the same
// word and the same thread is refused.
//
// The caller holds the lock of the bucket (lock_of). This package allocates
// no memory and calls no kernel operation; host tests count its steps.
package word_table

PAGE_SIZE :: 4096
// The distinct words of 32 bits in one frame: the most first entries in
// one bucket.
WORDS_OF_A_FRAME :: PAGE_SIZE / 4
// The buckets past the frames of the machine. The kernel refuses a wait on
// a word of device memory (word_address), so only a frame past the memory
// map that is no device reaches these; they keep the table whole for any
// address that a caller gives.
DEVICE_BUCKETS :: 64

// One word of the wait of one thread. 64 bytes on each target, also where
// a pointer has 4 bytes: a page of a wait room holds a fixed count of them.
Entry :: struct #align (64) {
	// The first entries of the distinct words of a bucket. Only a first
	// entry is in this list.
	bucket_next, bucket_previous: ^Entry,
	// The entries of one word: the first entry has no previous.
	word_next, word_previous:     ^Entry,
	word:                         u64, // The physical address of the word.
	thread:                       u32, // The place of the thread in its table.
	serial:                       u32, // The wait serial of the thread at the registration.
}
#assert(size_of(Entry) == 64)

// The bits of an entry of a page table that word_physical reads, as the
// kernel writes them (memory.odin asserts the same values).
ENTRY_PRESENT :: u64(1) << 0
ENTRY_USER :: u64(1) << 2
ENTRY_LARGE :: u64(1) << 7
ENTRY_ADDRESS :: u64(0x000F_FFFF_FFFF_F000)
LARGE_PAGE_SIZE :: 2 * 1024 * 1024
GIANT_PAGE_SIZE :: 1024 * 1024 * 1024

// The size of the page mapped by a leaf page table entry.
Entry_Size :: enum u8 {
	Size_4K = 0,
	Size_2M = 1,
	Size_1G = 2,
}

// word_physical_of_size gives the physical address of a waited word from a
// leaf page table entry of the given size (4 KiB, 2 MiB, or 1 GiB), or false
// when the entry names no frame of the process.
word_physical_of_size :: proc "contextless" (entry: u64, address: u64, size: Entry_Size) -> (physical: u64, ok: bool) {
	if entry & (ENTRY_PRESENT | ENTRY_USER) != ENTRY_PRESENT | ENTRY_USER {
		return 0, false
	}
	switch size {
	case .Size_4K:
		if entry & ENTRY_LARGE != 0 {
			return 0, false
		}
		return entry & ENTRY_ADDRESS | address & (PAGE_SIZE - 1), true
	case .Size_2M:
		if entry & ENTRY_LARGE == 0 {
			return 0, false
		}
		return entry & ENTRY_ADDRESS &~ u64(LARGE_PAGE_SIZE - 1) | address & (LARGE_PAGE_SIZE - 1), true
	case .Size_1G:
		if entry & ENTRY_LARGE == 0 {
			return 0, false
		}
		return entry & ENTRY_ADDRESS &~ u64(GIANT_PAGE_SIZE - 1) | address & (GIANT_PAGE_SIZE - 1), true
	}
	return 0, false
}

// word_physical gives the physical address of a waited word from the entry
// of its page (4 KiB or 2 MiB), or false when the entry names no frame of
// the process: not present, or not a page of the process. Only an entry that
// names a frame gives an address: an entry with no frame would give the
// offset of the word alone, a low physical address that the same offset in a
// page of another process gives too, and the two waits would share a word.
// The wait makes the page present first, as a read of the word would
// (src/md/data/table_sizes.md, "The word of a wait is a frame of its
// process"); this is the check that it did.
word_physical :: proc "contextless" (entry: u64, address: u64) -> (physical: u64, ok: bool) {
	return word_physical_of_size(entry, address, entry & ENTRY_LARGE != 0 ? .Size_2M : .Size_4K)
}

// The buckets: frames buckets, one for each frame, then DEVICE_BUCKETS.
Table :: struct {
	heads:  []^Entry,
	frames: u64,
}

// buckets_of_frames gives the buckets of a table for a machine of frames
// page frames.
buckets_of_frames :: proc "contextless" (frames: u64) -> u64 {
	return frames + DEVICE_BUCKETS
}

// bucket_of gives the bucket of a word: its frame, or a device bucket.
bucket_of :: #force_inline proc "contextless" (table: ^Table, word: u64) -> u64 {
	frame := word / PAGE_SIZE
	if frame < table.frames {
		return frame
	}
	return table.frames + frame % DEVICE_BUCKETS
}

// first_of_word gives the first entry of a word, or nil, and the first
// entries that it read: at most WORDS_OF_A_FRAME for a word of memory.
first_of_word :: proc "contextless" (table: ^Table, word: u64) -> (first: ^Entry, steps: int) {
	for entry := table.heads[bucket_of(table, word)]; entry != nil; entry = entry.bucket_next {
		steps += 1
		if entry.word == word {
			return entry, steps
		}
	}
	return nil, steps
}

// insert adds the entry of a thread for a word. false: the thread holds the
// word already, and nothing changed. steps counts the entries read: the
// first entries of the bucket up to the word, and the entries of the word.
insert :: proc "contextless" (table: ^Table, entry: ^Entry, word: u64, thread: u32, serial: u32) -> (inserted: bool, steps: int) {
	first, first_steps := first_of_word(table, word)
	steps = first_steps
	entry^ = {word = word, thread = thread, serial = serial}
	if first == nil {
		bucket := &table.heads[bucket_of(table, word)]
		entry.bucket_next = bucket^
		if bucket^ != nil {
			bucket^.bucket_previous = entry
		}
		bucket^ = entry
		return true, steps
	}
	for other := first; other != nil; other = other.word_next {
		steps += 1
		if other.thread == thread {
			entry^ = {}
			return false, steps
		}
	}
	// After the first entry: the first entry keeps its place in the bucket.
	entry.word_previous = first
	entry.word_next = first.word_next
	if first.word_next != nil {
		first.word_next.word_previous = entry
	}
	first.word_next = entry
	return true, steps
}

// remove takes an entry out of the table. The next entry of its word, if
// any, takes the place of a first entry in the bucket.
remove :: proc "contextless" (table: ^Table, entry: ^Entry) {
	if entry.word_previous != nil {
		entry.word_previous.word_next = entry.word_next
		if entry.word_next != nil {
			entry.word_next.word_previous = entry.word_previous
		}
		entry^ = {}
		return
	}
	bucket := &table.heads[bucket_of(table, entry.word)]
	next := entry.word_next
	if next != nil {
		next.word_previous = nil
		next.bucket_next = entry.bucket_next
		next.bucket_previous = entry.bucket_previous
		if entry.bucket_next != nil {
			entry.bucket_next.bucket_previous = next
		}
		if entry.bucket_previous != nil {
			entry.bucket_previous.bucket_next = next
		} else {
			bucket^ = next
		}
	} else {
		if entry.bucket_next != nil {
			entry.bucket_next.bucket_previous = entry.bucket_previous
		}
		if entry.bucket_previous != nil {
			entry.bucket_previous.bucket_next = entry.bucket_next
		} else {
			bucket^ = entry.bucket_next
		}
	}
	entry^ = {}
}
