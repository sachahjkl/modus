package notify_border_of_the_compositor

import "modus:contract/errors"

// The log facts of the test of the border of compositor.notify for a caller
// that does not act for the principal (src/md/features/tray_widgets.md,
// "The export notify"). A Text field comes last.

// Each check held.
@(log_fact = "notify_border_of_the_compositor: ok, the cards of a caller stop at {limit} with Full and their count, a post within 500 ms is refused with Busy or came later by the clock, and the cards carry a name of {name_bytes} bytes")
Border_Held :: struct {
	limit:      u64,
	name_bytes: u64,
}

// A check did not hold: what was checked.
@(log_fact = "notify_border_of_the_compositor: WRONG: {what}")
Wrong :: struct {
	what: [96]u8,
}

// A post that the check did not expect to be refused, with its record.
@(log_fact = "notify_border_of_the_compositor: WRONG: a refusal: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Wrong_Refusal :: distinct errors.Error_Record_Fact_Fields
