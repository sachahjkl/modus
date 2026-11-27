// The test of an arena paid by the budget (src/md/features/memory_without_a_bound.md).
//
// The process reserves an arena a little larger than its whole budget,
// and pushes one page at a time until the budget refuses a commit. Then it
// checks:
//
// - the refusal is the status `No_Budget` with its error record, and the
//   process still runs;
// - the refused push changed nothing in the arena, and the budget holds no
//   page;
// - each page that a push gave read zero before its first write;
// - after a reset, the same pushes give the same addresses and commit
//   nothing;
// - after the end of the arena, the budget holds again each page that it
//   held before the reservation.
//
// **What it is for.** It proves on a machine that a process can hold data
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
// process stops with `Done`, or with `Failed` after a WRONG line.
package arena

import "modus:contract/call_outcome"
import "base:intrinsics"
import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:system"

// entry runs the test, writes its result on the log, and stops.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	// Signal the first state of work before reading the starting budget and
	// spending the whole budget on purpose, and wait until the starter closes
	// its side of the ready ring so those pages do not return during the test.
	had_ready := ctx.handles[op.CONTEXT_READY_RING] != 0
	before_ready, _ := system.budget_read()
	system.ready_at_end()
	if had_ready {
		deadline := system.time() + system.ANSWER_BOUND_MILLISECONDS
		for system.time() < deadline {
			now_budget, _ := system.budget_read()
			if now_budget.pages > before_ready.pages {
				break
			}
			system.sleep(system.time() + 1)
		}
	}
	before, _ := system.budget_read()
	// The reservation holds more pages than the budget can pay, so the
	// budget refuses first, not the end of the reservation.
	reservation := system.arena_reservation_pages(before.pages)
	record: errors.Error_Record
	arena, created := system.arena_create(reservation, error = &record)
	if created != .Succeeded {
		system.log_fact(.Info, Wrong_Reservation{reservation_pages = reservation, status = call_outcome.Call_Outcome_Word(created)})
		system.stop(.Failed)
	}

	first: rawptr
	pushes: u64
	nonzero: u64
	refused: call_outcome.Call_Outcome
	for {
		page, status := system.arena_push(&arena, system.PAGE_SIZE, system.PAGE_SIZE, &record)
		if status != .Succeeded {
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
	refusal_is_of_the_budget := refused == .Budget_Or_Capacity_Exhausted && (record.kind == i64(errors.Kind.Budget) || record.kind == i64(errors.Kind.Budget_Hidden))
	system.log_fact(.Info, Arena_Grew{committed_pages = arena.committed_pages, commits = arena.commit_count, reservation_pages = reservation, pushes = pushes, budget_pages_before = before.pages, budget_pages_after = held.pages})

	// A second refused push: the process still runs, and nothing changed.
	_, again := system.arena_push(&arena, system.PAGE_SIZE, system.PAGE_SIZE)
	unchanged := again == .Budget_Or_Capacity_Exhausted && arena == kept

	// The same pushes after a reset: each address the one of its page
	// before the reset, and no commit.
	system.arena_reset(&arena)
	reused := true
	for index in 0 ..< pushes {
		page, status := system.arena_push(&arena, system.PAGE_SIZE, system.PAGE_SIZE)
		if status != .Succeeded || uintptr(page) != uintptr(first) + uintptr(index * system.PAGE_SIZE) {
			reused = false
			break
		}
	}
	reused = reused && arena.commit_count == kept.commit_count && arena.committed_pages == kept.committed_pages

	ended := system.arena_end(&arena)
	after, _ := system.budget_read()

	// Each WRONG case stops with Failed: a test that says Done after a
	// wrong line would read as a clean end to its starter.
	right := false
	switch {
	case !refusal_is_of_the_budget:
		system.log_fact(.Info, Wrong_Growth_Stop{status = call_outcome.Call_Outcome_Word(refused), error_kind = errors.Kind_Word(record.kind)})
	case pushes == 0 || nonzero != 0:
		system.log_fact(.Info, Wrong_Pushes{pushes = pushes, nonzero_pages = nonzero})
	case held.pages != 0 || !unchanged:
		system.log_fact(.Info, Wrong_After_Refusal{budget_pages = held.pages, status = call_outcome.Call_Outcome_Word(again)})
	case !reused:
		system.log_fact(.Info, Wrong_Reset{})
	case ended != .Succeeded || after.pages != before.pages:
		system.log_fact(.Info, Wrong_End{status = call_outcome.Call_Outcome_Word(ended), budget_pages_after = after.pages, budget_pages_before = before.pages})
	case:
		system.log_fact(.Info, Arena_Checked{})
		right = true
	}
	if !right {
		system.stop(.Failed)
	}
	system.stop(.Done)
}
