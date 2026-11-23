package locks

import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:system"

// The wait room of the kernel at its edges (op.Thread_Control_Command.
// Wait_Room): a wait of one word past the words that a thread has with no
// room is refused, and names that count as its limit; a room past the most
// words, or for another thread, is refused; a room of one word past them
// holds a whole page of words more, and its pages leave the budget; a wait
// of each word of the room passes, one word more is refused with the room
// as its limit; the room given back returns its pages to the budget.
// Each condition is a status, a record or a count of pages: no time.
ROOM_WORDS_ASKED :: op.WORD_WAIT_INLINE + 1
ROOM_WORDS_HELD :: op.WORD_WAIT_INLINE + op.WAIT_ROOM_WORDS_OF_A_PAGE

wait_room_case :: proc "contextless" () {
	// Each word holds another value than the one that the wait names: a
	// wait that the kernel takes ends at once.
	changed: u32 = 1
	words: [ROOM_WORDS_HELD + 1]op.Word
	for &word in words {
		word = {address = u64(uintptr(&changed)), value = 0}
	}
	wait_of :: proc "contextless" (words: []op.Word, record: ^errors.Error_Record) -> system.Status {
		_, status := system.call_with_error(record, .Word_Wait, u64(uintptr(raw_data(words))), u64(len(words)))
		return status
	}
	room_of :: proc "contextless" (thread: u64, words: u64, record: ^errors.Error_Record) -> (held: u64, status: system.Status) {
		results: [7]u64
		results, status = system.call_with_error(record, .Thread_Control, thread, 0, u64(op.Thread_Control_Command.Wait_Room), 0, words)
		return results[0], status
	}

	no_room: errors.Error_Record
	no_room_status := wait_of(words[:op.WORD_WAIT_INLINE + 1], &no_room)
	right := no_room_status == .No_Slot && no_room.kind == i64(errors.Kind.Too_Long) && no_room.unit == i64(errors.Unit.Words) && no_room.limit == op.WORD_WAIT_INLINE
	inline_status := wait_of(words[:op.WORD_WAIT_INLINE], nil)
	right &&= inline_status == .Ok

	too_many: errors.Error_Record
	_, too_many_status := room_of(0, op.WORD_WAIT_MOST + 1, &too_many)
	right &&= too_many_status == .Bad_Operation && too_many.kind == i64(errors.Kind.Too_Long) && too_many.limit == op.WORD_WAIT_MOST
	_, other_status := room_of(1, ROOM_WORDS_ASKED, nil)
	right &&= other_status == .Bad_Operation

	before, _ := system.budget_read()
	held, room_status := room_of(0, ROOM_WORDS_ASKED, nil)
	with_room, _ := system.budget_read()
	pages := before.pages - with_room.pages
	right &&= room_status == .Ok && held == ROOM_WORDS_HELD && pages == op.wait_room_pages(ROOM_WORDS_ASKED)

	held_status := wait_of(words[:ROOM_WORDS_HELD], nil)
	past: errors.Error_Record
	past_status := wait_of(words[:ROOM_WORDS_HELD + 1], &past)
	right &&= held_status == .Ok && past_status == .No_Slot && past.limit == ROOM_WORDS_HELD

	back, back_status := room_of(0, 0, nil)
	after, _ := system.budget_read()
	returned := back_status == .Ok && back == op.WORD_WAIT_INLINE && after.pages == before.pages
	right &&= returned

	system.log_fact(.Info, Wait_Room_Checked{
		inline_words = op.WORD_WAIT_INLINE,
		no_room_status = op.Status_Word(no_room_status),
		most_words = op.WORD_WAIT_MOST,
		too_many_status = op.Status_Word(too_many_status),
		other_status = op.Status_Word(other_status),
		asked = ROOM_WORDS_ASKED,
		held = held,
		pages = pages,
		held_status = op.Status_Word(held_status),
		past_status = op.Status_Word(past_status),
		returned = u64(returned),
		verdict = verdict_field(right),
	})
}
