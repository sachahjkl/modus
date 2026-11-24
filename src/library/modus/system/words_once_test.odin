#+build !freestanding
package system

import "modus:contract/call_outcome"
import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:contract/ring"
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

// The words before a word that the kernel refused as named twice: the place
// of the record, at most the count; a place past the count gives the count;
// a record of another kind, a negative place, or the place 0 give no word,
// and the wait then waits on none until its deadline.
@(test)
the_words_before_a_refused_word :: proc(t: ^testing.T) {
	of :: proc(record: errors.Error_Record) -> ring.Record {
		return {kind = u32(call_outcome.Call_Outcome.Argument_Refused), values = transmute([7]u64)record}
	}
	twice :: proc(place: i64) -> errors.Error_Record {
		return {kind = i64(errors.Kind.Bad_Value), unit = i64(errors.Unit.Words), argument = 1, value = place}
	}
	testing.expect_value(t, words_before_refused(of(twice(3)), 10), 3)
	testing.expect_value(t, words_before_refused(of(twice(0)), 10), 0)
	testing.expect_value(t, words_before_refused(of(twice(10)), 10), 10)
	testing.expect_value(t, words_before_refused(of(twice(11)), 10), 10)
	testing.expect_value(t, words_before_refused(of(twice(max(i64))), 10), 10)
	testing.expect_value(t, words_before_refused(of(twice(-1)), 10), 0)
	other := errors.Error_Record{kind = i64(errors.Kind.Bad_Address), unit = i64(errors.Unit.Bytes), value = 3}
	testing.expect_value(t, words_before_refused(of(other), 10), 0)
}
