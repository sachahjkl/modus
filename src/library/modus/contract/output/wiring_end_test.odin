#+build !freestanding
#+build !modus
package output

import "core:testing"

// The order that broke the rule of one end word: the writer closes, the
// root service writes Side_Closed, then the writer stops before the reader
// reads. The stop of the writer writes nothing and does not end the
// wiring; the Closed of the reader then ends it with no word. A later word
// of any kind writes nothing over Side_Closed.
@(test)
a_writer_that_closed_then_stopped_leaves_side_closed_alone :: proc(t: ^testing.T) {
	written := false
	// The Closed of the writer, the reader still holding its end.
	word := end_word_to_write(written, .Side_Closed)
	testing.expect_value(t, word, End_Word.Side_Closed)
	written = written || word != .None
	// The stop of the writer, before the reader reads.
	testing.expect_value(t, stop_step_of(closed = true, other_closed = false), Stop_Step.Detach)
	// Each word that a later stop or a revocation asks for writes nothing.
	for asked in End_Word {
		testing.expectf(t, end_word_to_write(written, asked) == .None, "the word %v is written over Side_Closed", asked)
	}
}

// The other orders: a reader that closed and then stopped leaves too; a
// side that stops with no Closed ends the wiring, and its word goes into
// an empty page only; a stop after both sides closed ends nothing that
// runs, and the decision ends it; an empty page takes each word, last.
@(test)
a_stop_ends_the_wiring_unless_its_side_closed_alone :: proc(t: ^testing.T) {
	testing.expect_value(t, stop_step_of(closed = false, other_closed = false), Stop_Step.End_Wiring)
	testing.expect_value(t, stop_step_of(closed = false, other_closed = true), Stop_Step.End_Wiring)
	testing.expect_value(t, stop_step_of(closed = true, other_closed = true), Stop_Step.End_Wiring)
	testing.expect_value(t, end_word_to_write(true, .Writer_Stopped), End_Word.None)
	for asked in End_Word {
		testing.expect_value(t, end_word_to_write(false, asked), asked)
	}
}
