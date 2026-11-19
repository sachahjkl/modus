// A row of the test of the restarts of a start policy
// (src/md/features/start_policy.md, "The subtle points").
//
// **What it shows.** A row that stops itself with the stop outcome
// `Refused` does not start again, whatever its count of restarts: the same
// input would give the same refusal.
//
// **Start**: the rescue list of the image of the test of the rescue names
// it, with a count of restarts. Only that image holds it. It needs no
// grant.
//
// **What a reader sees.** No window: the line `stops_refused: it refuses
// its context on purpose`, once, and the lines of the root service and of
// the start policy about its stop.
package stops_refused

import "modus:support/system"

@(export, link_name = "entry")
entry :: proc "c" (_: ^system.Context) -> ! {
	system.log("stops_refused: it refuses its context on purpose")
	system.stop(.Refused)
}
