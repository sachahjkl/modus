// What the program `kernel_events` and its load child agree on: the round
// that the parent writes in the shared page, and the stop of a child that
// refuses it.
package kernel_events_rounds

// The rounds of the load child. The parent writes the word of a round in
// the shared page, so each value is explicit.
Round :: enum u32 {
	None              = 0, // No round yet: the word of the page before the first round.
	Exact             = 1,
	One_In            = 2,
	Full              = 3,
	Taken_Away        = 4,
	// One first use of a new page: the child writes its address in the
	// page that it shares.
	First_Use_All     = 5,
	First_Use_Named   = 6,
	// The loaders start, then stop.
	Loaders_Start     = 7,
	Loaders_Stop      = 8,
	// The rounds of the measure: the load child runs its loop of
	// Memory_Size for a fixed time, and writes its own count and its own
	// time.
	Measure_No_Rule   = 9,
	Measure_Other     = 10,
	Measure_Nothing   = 11,
	Measure_Each      = 12,
	// The right revoked: one count of operations before the revocation,
	// one after.
	Before_Revocation = 13,
	After_Revocation  = 14,
}

// The stop code of a load child that got a word that names no round, or
// the word of None: the parent reads it at once, and does not wait for the
// end of a round that never runs.
REFUSED_ROUND_STOP_CODE :: 21

// round_of_word is the border of the shared page. A word that names no
// round, and the word of None, which is no round to run, are refused: the
// child runs nothing in their place and stops with REFUSED_ROUND_STOP_CODE.
round_of_word :: proc "contextless" (word: u32) -> (round: Round, ok: bool) {
	for member in Round {
		if member != .None && u32(member) == word {
			return member, true
		}
	}
	return {}, false
}
