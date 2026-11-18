// The test of an arena paid by the budget (src/md/features/memory_without_a_bound.md).
//
// The program reserves an arena a little larger than its whole budget,
// and pushes one page at a time until the budget refuses a commit. Then it
// checks:
//
// - the refusal is the status `No_Budget` with its error record, and the
//   program still runs;
// - the refused push changed nothing in the arena, and the budget holds no
//   page;
// - each page that a push gave read zero before its first write;
// - after a reset, the same pushes give the same addresses and commit
//   nothing;
// - after the end of the arena, the budget holds again each page that it
//   held before the reservation.
//
// **What it is for.** It proves on a machine that a program can hold data
// with no known bound and read a lack of memory as a value: the
// [arena](term:arena) grows by an explicit commit, the kernel refuses the
// commit that the budget cannot pay, and the end of the arena returns
// every page at once.
//
// **Start**: `start("arena")` in the console. It needs no grant: an arena
// is memory of its own budget.
//
// **What a reader sees**: no window. The log has one line of counts,
// "arena: grew to ... pages in ... commits ...", then "arena: the budget
// refused the commit with No_Budget, the arena kept its state, a reset
// took the same pages again with no commit, and its end gave every page
// back to the budget: as it must", or a line "arena: WRONG: ...". The
// program stops with the code 0.
package arena

import "base:intrinsics"
import "modus:contract/errors"
import "modus:support/system"

// entry runs the test, writes its result on the log, and stops.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	before, _ := system.budget_read()
	// The reservation holds more pages than the budget can pay, so the
	// budget refuses first, not the end of the reservation.
	reservation := system.arena_reservation_pages(before.pages)
	record: errors.Error_Record
	arena, created := system.arena_create(reservation, error = &record)
	if created != .Ok {
		system.log("arena: WRONG: the reservation of ", reservation, " pages failed with ", created)
		system.stop(0)
	}

	first: rawptr
	pushes: u64
	nonzero: u64
	refused: system.Status
	for {
		page, status := system.arena_push(&arena, system.PAGE_SIZE, system.PAGE_SIZE, &record)
		if status != .Ok {
			refused = status
			break
		}
		if first == nil {
			first = page
		}
		// A committed page is zero, and takes its frame at this first touch.
		first_byte := (^u8)(page)
		if intrinsics.volatile_load(first_byte) != 0 {
			nonzero += 1
		}
		intrinsics.volatile_store(first_byte, 1)
		pushes += 1
	}
	kept := arena
	held, _ := system.budget_read()
	refusal_is_of_the_budget := refused == .No_Budget && (record.kind == i64(errors.Kind.Budget) || record.kind == i64(errors.Kind.Budget_Hidden))
	system.log("arena: grew to ", arena.committed_pages, " pages in ", arena.commit_count, " commits, in a reservation of ", reservation, " pages, and gave ", pushes, " pushes of one page; the budget held ", before.pages, " pages before, and ", held.pages, " after the refusal")

	// A second refused push: the program still runs, and nothing changed.
	_, again := system.arena_push(&arena, system.PAGE_SIZE, system.PAGE_SIZE)
	unchanged := again == .No_Budget && arena == kept

	// The same pushes after a reset: each address the one of its page
	// before the reset, and no commit.
	system.arena_reset(&arena)
	reused := true
	for index in 0 ..< pushes {
		page, status := system.arena_push(&arena, system.PAGE_SIZE, system.PAGE_SIZE)
		if status != .Ok || uintptr(page) != uintptr(first) + uintptr(index * system.PAGE_SIZE) {
			reused = false
			break
		}
	}
	reused = reused && arena.commit_count == kept.commit_count && arena.committed_pages == kept.committed_pages

	ended := system.arena_end(&arena)
	after, _ := system.budget_read()

	switch {
	case !refusal_is_of_the_budget:
		system.log("arena: WRONG: the growth stopped with ", refused, " and the error kind ", record.kind, ", not with No_Budget")
	case pushes == 0 || nonzero != 0:
		system.log("arena: WRONG: ", pushes, " pushes, and ", nonzero, " pages that did not read zero before their first write")
	case held.pages != 0 || !unchanged:
		system.log("arena: WRONG: after the refusal the budget held ", held.pages, " pages, and a second push gave ", again, " or changed the arena")
	case !reused:
		system.log("arena: WRONG: after a reset the same pushes did not take the same pages with no commit")
	case ended != .Ok || after.pages != before.pages:
		system.log("arena: WRONG: the end gave ", ended, ", and the budget holds ", after.pages, " pages of ", before.pages)
	case:
		system.log("arena: the budget refused the commit with No_Budget, the arena kept its state, a reset took the same pages again with no commit, and its end gave every page back to the budget: as it must")
	}
	system.stop(0)
}
