package output

// The end words of a wiring as the root service writes them
// (src/md/features/module_outputs.md, "The end of a stream"). An end page
// gets one end word, ever: a side that read Side_Closed, or a stop, never
// reads a second word beside the first, with stop words that belong to
// another end. Each decision is pure, so a host test gives it each order
// of a close and a stop.

// end_word_to_write gives the end word that the root service writes in an
// end page: the word asked for when the page holds none, else None, which
// writes nothing.
end_word_to_write :: proc "contextless" (written: bool, asked: End_Word) -> End_Word {
	if written {
		return .None
	}
	return asked
}

// What the root service does with a wiring when one of its sides stops.
Stop_Step :: enum u8 {
	End_Wiring = 0, // The wiring ends: the end word of the stop, when the page holds none, and the close of the wiring.
	Detach     = 1, // The side closed its end before its stop: the other side holds its end and read Side_Closed. The side leaves the wiring with no word, and the wiring ends at the Closed or the stop of the other side.
}

// stop_step_of gives what a stop does to a wiring: closed says that the
// side that stops said Closed before, other_closed that the other side
// did. A side that closed and whose other side still holds its end
// leaves; each other stop ends the wiring. A wiring whose two sides closed
// has ended before any stop.
stop_step_of :: proc "contextless" (closed, other_closed: bool) -> Stop_Step {
	if closed && !other_closed {
		return .Detach
	}
	return .End_Wiring
}
