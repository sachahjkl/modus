package locker

// The log facts of locker (src/md/features/log_facts.md): each fact
// template is the line that the process wrote before it was a fact.

// The board of the lockers is not mapped, or the index of this locker in
// its context is past the board.
@(log_fact = "locker: no board, or the slot {slot} is past the board")
Slot_Past_Board :: struct {
	slot: u64,
}

// The board holds a word of the mode that names no mode.
@(log_fact = "locker: the board names the mode {mode_word}, which names no mode")
Mode_Word_Unknown :: struct {
	mode_word: u64,
}
