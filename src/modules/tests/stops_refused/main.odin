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

import "modus:system"

@(export, link_name = "entry")
entry :: proc "c" (_: ^system.Context) -> ! {
	system.log_fact(.Info, Refuses_On_Purpose{})
	system.stop(.Refused)
}

// Measure pending: the 2048 pages of the least budget in which it ran
// before its floor was counted. The first machine pass with the check of
// the floors (the check boot-test of the flake) writes the peak of its
// budget at its first state of work; modustool floors measured on the log
// of that pass gives the working memory that replaces this number
// (src/md/features/module_budget_request.md, "The first state of work").
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 2048}
