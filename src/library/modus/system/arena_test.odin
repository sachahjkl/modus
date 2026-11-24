#+build !freestanding
package system

import "modus:contract/call_outcome"
import "modus:contract/errors"
import op "modus:contract/operation"
import "core:testing"

// The arithmetic of an arena with no kernel (src/md/features/memory_without_a_bound.md):
// a fake reservation pays each commit from a count of pages, as a budget
// does, and refuses a whole range that the count cannot pay. Its base is
// an address that no test reads or writes: a push only computes addresses.

@(private = "file")
FAKE_BASE :: uintptr(0x4000_0000)

@(private = "file")
Fake_Reservation :: struct {
	// First, so that the page change finds the fake at the address of the
	// arena that the push passes.
	using arena:         Arena,
	budget_pages:        u64, // What the fake budget still pays.
	pages_of_the_fake:   u64, // The pages that the fake counts as committed.
	commit_calls:        int,
	decommit_calls:      int,
	ranges:              [16]op.Page_Range, // The ranges of the commits that the fake paid, in order.
	range_count:         int,
	// The decommits that the fake accepts before it refuses each one, as
	// the kernel refuses an object that another holder names. -1: all.
	decommits_accepted:  int,
	commit_refusal:      call_outcome.Call_Outcome, // Not Succeeded: the fake refuses each commit with it, as a commit with a bad handle.
}

@(private = "file")
fake_page_change :: proc "contextless" (arena: ^Arena, range: op.Page_Range, flags: op.Commit_Flags, error: ^errors.Error_Record) -> call_outcome.Call_Outcome {
	fake := (^Fake_Reservation)(rawptr(arena))
	if .Decommit in flags {
		fake.decommit_calls += 1
		if fake.decommits_accepted >= 0 && fake.decommit_calls > fake.decommits_accepted {
			if error != nil {
				error^ = errors.error_make(.State, .None, 1)
			}
			return .Wrong_State
		}
		fake.budget_pages += range.page_count
		fake.pages_of_the_fake -= range.page_count
		return .Succeeded
	}
	fake.commit_calls += 1
	if fake.commit_refusal != .Succeeded {
		if error != nil {
			error^ = errors.error_make(.Handle_Kind, .None, 1)
		}
		return fake.commit_refusal
	}
	if range.page_count > fake.budget_pages {
		if error != nil {
			error^ = errors.error_make(.Budget, .Pages, 3, 0, i64(range.page_count), i64(fake.budget_pages))
		}
		return .Budget_Or_Capacity_Exhausted
	}
	fake.budget_pages -= range.page_count
	fake.pages_of_the_fake += range.page_count
	if fake.range_count < len(fake.ranges) {
		fake.ranges[fake.range_count] = range
		fake.range_count += 1
	}
	return .Succeeded
}

@(private = "file")
fake_reservation :: proc(reserved_pages, budget_pages: u64) -> Fake_Reservation {
	return {arena = arena_of_reservation(([^]u8)(rawptr(FAKE_BASE)), reserved_pages, fake_page_change), budget_pages = budget_pages, decommits_accepted = -1}
}

@(private = "file")
offset_of_address :: proc(address: rawptr) -> u64 {
	return u64(uintptr(address) - FAKE_BASE)
}

// A size of 0 is refused before any commit, and the arena does not change.
@(test)
arena_push_refuses_a_size_of_zero :: proc(t: ^testing.T) {
	fake := fake_reservation(16, 100)
	before := fake.arena
	record: errors.Error_Record
	result, status := arena_push(&fake.arena, 0, 1, &record)
	testing.expect_value(t, status, call_outcome.Call_Outcome.Argument_Refused)
	testing.expect_value(t, result, nil)
	testing.expect_value(t, record.kind, i64(errors.Kind.Too_Small))
	testing.expect_value(t, record.argument, 2)
	testing.expect_value(t, fake.arena, before)
	testing.expect_value(t, fake.commit_calls, 0)
}

// An alignment of 0, one that is not a power of two, and a power of two
// past the page: each one refused with its value, and nothing changes.
@(test)
arena_push_refuses_an_alignment_that_is_not_a_power_of_two :: proc(t: ^testing.T) {
	refused := [?]u64{0, 3, 6, ARENA_ALIGNMENT_LIMIT - 1, ARENA_ALIGNMENT_LIMIT + 1, ARENA_ALIGNMENT_LIMIT * 2, max(u64)}
	for alignment in refused {
		fake := fake_reservation(16, 100)
		before := fake.arena
		record: errors.Error_Record
		result, status := arena_push(&fake.arena, 1, alignment, &record)
		testing.expectf(t, status == .Argument_Refused, "alignment %d: %v", alignment, status)
		testing.expect_value(t, result, nil)
		testing.expect_value(t, record.kind, i64(errors.Kind.Bad_Value))
		testing.expect_value(t, record.argument, 3)
		// A record holds signed values: the largest alignment is written as
		// the largest value of the record, never as a negative one.
		testing.expect_value(t, record.value, alignment > u64(max(i64)) ? max(i64) : i64(alignment))
		testing.expect(t, record.value >= 0)
		testing.expect_value(t, record.limit, i64(ARENA_ALIGNMENT_LIMIT))
		testing.expect_value(t, record.operation, i64(op.Operation.None))
		testing.expect_value(t, fake.arena, before)
		testing.expect_value(t, fake.commit_calls, 0)
	}
}

// A size past the whole reservation, the largest size, and a size whose
// sum with the used bytes wraps: each one is refused before any sum. Then
// a size that fits the reservation and not its rest is refused with Full.
// The last cases fill the reservation to its last byte, then one byte past.
@(test)
arena_push_refuses_a_size_past_the_reservation :: proc(t: ^testing.T) {
	RESERVED_PAGES :: 4
	reserved_bytes := u64(RESERVED_PAGES * PAGE_SIZE)
	fake := fake_reservation(RESERVED_PAGES, 100)
	record: errors.Error_Record
	refused_sizes := [?]u64{reserved_bytes + 1, max(u64)}
	for size in refused_sizes {
		result, status := arena_push(&fake.arena, size, 1, &record)
		testing.expect_value(t, status, call_outcome.Call_Outcome.Argument_Refused)
		testing.expect_value(t, result, nil)
		testing.expect_value(t, record.kind, i64(errors.Kind.Too_Long))
		testing.expect_value(t, record.value, size > u64(max(i64)) ? max(i64) : i64(size))
		testing.expect_value(t, record.limit, i64(reserved_bytes))
	}
	testing.expect_value(t, fake.commit_calls, 0)

	_, first := arena_push(&fake.arena, 1, 1)
	testing.expect_value(t, first, call_outcome.Call_Outcome.Succeeded)
	before := fake.arena
	record = {}
	_, wrapped := arena_push(&fake.arena, max(u64) - fake.used_bytes + 1, 1, &record)
	testing.expect_value(t, wrapped, call_outcome.Call_Outcome.Argument_Refused)
	testing.expect_value(t, record.kind, i64(errors.Kind.Too_Long))
	record = {}
	result, full := arena_push(&fake.arena, reserved_bytes, 1, &record)
	testing.expect_value(t, full, call_outcome.Call_Outcome.Budget_Or_Capacity_Exhausted)
	testing.expect_value(t, result, nil)
	testing.expect_value(t, record.kind, i64(errors.Kind.Full))
	testing.expect_value(t, record.unit, i64(errors.Unit.Bytes))
	testing.expect_value(t, record.found, 1)
	testing.expect_value(t, fake.arena, before)

	// The rest of the reservation, to its last byte: the bound.
	last, filled := arena_push(&fake.arena, reserved_bytes - 1, 1)
	testing.expect_value(t, filled, call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, offset_of_address(last), 1)
	testing.expect_value(t, fake.used_bytes, reserved_bytes)
	testing.expect_value(t, fake.committed_pages, RESERVED_PAGES)
	// One byte past the bound.
	before = fake.arena
	_, past := arena_push(&fake.arena, 1, 1)
	testing.expect_value(t, past, call_outcome.Call_Outcome.Budget_Or_Capacity_Exhausted)
	testing.expect_value(t, fake.arena, before)
}

// A zero arena (never created, or ended) refuses each push and calls no
// page change.
@(test)
arena_push_on_a_zero_arena_is_refused :: proc(t: ^testing.T) {
	arena: Arena
	record: errors.Error_Record
	result, status := arena_push(&arena, 1, 1, &record)
	testing.expect_value(t, status, call_outcome.Call_Outcome.Argument_Refused)
	testing.expect_value(t, result, nil)
	testing.expect_value(t, record.kind, i64(errors.Kind.Too_Long))
	testing.expect_value(t, arena, Arena{})
}

// A budget of 10 pages refuses a push of 16 pages, then one of 11: each
// gives No_Budget with the record of the commit, and the arena and the
// budget do not change. A push of 10 pages is refused its step of 16 pages
// and takes its 10 pages alone. A push past them is then refused.
@(test)
arena_push_gives_back_a_refused_commit :: proc(t: ^testing.T) {
	BUDGET_PAGES :: 10
	fake := fake_reservation(64, BUDGET_PAGES)
	before := fake.arena
	refused_pages := [?]u64{ARENA_GROWTH_STEP_FIRST_PAGES, BUDGET_PAGES + 1}
	for pages in refused_pages {
		record: errors.Error_Record
		result, status := arena_push(&fake.arena, pages * PAGE_SIZE, 1, &record)
		testing.expect_value(t, status, call_outcome.Call_Outcome.Budget_Or_Capacity_Exhausted)
		testing.expect_value(t, result, nil)
		testing.expect_value(t, record.kind, i64(errors.Kind.Budget))
		testing.expect_value(t, record.found, BUDGET_PAGES)
		testing.expect_value(t, fake.arena, before)
		testing.expect_value(t, fake.budget_pages, BUDGET_PAGES)
		testing.expect_value(t, fake.pages_of_the_fake, 0)
	}
	// The step of 16 pages alone, then the step and the 11 pages.
	testing.expect_value(t, fake.commit_calls, 3)

	result, status := arena_push(&fake.arena, BUDGET_PAGES * PAGE_SIZE, 1)
	testing.expect_value(t, status, call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, offset_of_address(result), 0)
	testing.expect_value(t, fake.committed_pages, BUDGET_PAGES)
	testing.expect_value(t, fake.budget_pages, 0)

	before = fake.arena
	record: errors.Error_Record
	result, status = arena_push(&fake.arena, 1, 1, &record)
	testing.expect_value(t, status, call_outcome.Call_Outcome.Budget_Or_Capacity_Exhausted)
	testing.expect_value(t, result, nil)
	testing.expect_value(t, record.found, 0)
	testing.expect_value(t, fake.arena, before)
}

// A push larger than one call of Memory_Commit takes two calls. When the
// second call is refused, the pages of the first return, and the arena
// does not change; with a budget that pays, the same push passes.
@(test)
arena_push_commits_past_the_pages_of_one_call :: proc(t: ^testing.T) {
	PUSH_PAGES :: op.RANGE_TABLE_PAGE_LIMIT + 2
	fake := fake_reservation(2 * op.RANGE_TABLE_PAGE_LIMIT, op.RANGE_TABLE_PAGE_LIMIT + 1)
	before := fake.arena
	record: errors.Error_Record
	result, status := arena_push(&fake.arena, PUSH_PAGES * PAGE_SIZE, 1, &record)
	testing.expect_value(t, status, call_outcome.Call_Outcome.Budget_Or_Capacity_Exhausted)
	testing.expect_value(t, result, nil)
	testing.expect_value(t, record.kind, i64(errors.Kind.Budget))
	testing.expect_value(t, fake.arena, before)
	testing.expect_value(t, fake.pages_of_the_fake, 0)
	testing.expect_value(t, fake.budget_pages, op.RANGE_TABLE_PAGE_LIMIT + 1)
	testing.expect_value(t, fake.commit_calls, 2)
	testing.expect_value(t, fake.decommit_calls, 1)

	fake.budget_pages = 2 * op.RANGE_TABLE_PAGE_LIMIT
	fake.range_count = 0
	result, status = arena_push(&fake.arena, PUSH_PAGES * PAGE_SIZE, 1)
	testing.expect_value(t, status, call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, offset_of_address(result), 0)
	testing.expect_value(t, fake.committed_pages, PUSH_PAGES)
	testing.expect_value(t, fake.pages_of_the_fake, PUSH_PAGES)
	testing.expect_value(t, fake.range_count, 2)
	testing.expect_value(t, fake.ranges[0], op.Page_Range{first = 0, page_count = op.RANGE_TABLE_PAGE_LIMIT})
	testing.expect_value(t, fake.ranges[1], op.Page_Range{first = op.RANGE_TABLE_PAGE_LIMIT, page_count = 2})
}

// Each power of two up to the page aligns the address of a push, after a
// push of one byte that leaves the end unaligned; the gap is less than the
// alignment.
@(test)
arena_push_aligns_at_each_power_up_to_the_page :: proc(t: ^testing.T) {
	fake := fake_reservation(16, 100)
	for alignment: u64 = 1; alignment <= ARENA_ALIGNMENT_LIMIT; alignment *= 2 {
		_, one := arena_push(&fake.arena, 1, 1)
		testing.expect_value(t, one, call_outcome.Call_Outcome.Succeeded)
		end := fake.used_bytes
		result, status := arena_push(&fake.arena, 1, alignment)
		testing.expect_value(t, status, call_outcome.Call_Outcome.Succeeded)
		offset := offset_of_address(result)
		testing.expectf(t, offset % alignment == 0, "alignment %d: offset %d", alignment, offset)
		testing.expectf(t, offset >= end && offset - end < alignment, "alignment %d: offset %d after the end %d", alignment, offset, end)
		testing.expect_value(t, fake.used_bytes, offset + 1)
	}
}

// The step of the growth: 16 pages, then the double of each step, up to
// 512 pages, each range after the one before.
@(test)
arena_growth_steps_double_up_to_their_limit :: proc(t: ^testing.T) {
	PUSHED_PAGES :: 2000
	fake := fake_reservation(4096, 4096)
	for _ in 0 ..< PUSHED_PAGES {
		_, status := arena_push(&fake.arena, PAGE_SIZE, PAGE_SIZE)
		testing.expect_value(t, status, call_outcome.Call_Outcome.Succeeded)
	}
	steps := [?]u64{16, 32, 64, 128, 256, 512, 512, 512}
	testing.expect_value(t, fake.range_count, len(steps))
	testing.expect_value(t, fake.commit_count, u64(len(steps)))
	first: u64
	for step, index in steps {
		testing.expect_value(t, fake.ranges[index], op.Page_Range{first = first, page_count = step})
		first += step
	}
	testing.expect_value(t, fake.committed_pages, first)
	testing.expect_value(t, fake.used_bytes, PUSHED_PAGES * PAGE_SIZE)
}

// A step is cut at the end of the reservation: the last commit takes the
// pages that are left, not the step.
@(test)
arena_growth_step_stops_at_the_reservation :: proc(t: ^testing.T) {
	fake := fake_reservation(20, 100)
	_, first := arena_push(&fake.arena, PAGE_SIZE, 1)
	testing.expect_value(t, first, call_outcome.Call_Outcome.Succeeded)
	_, second := arena_push(&fake.arena, ARENA_GROWTH_STEP_FIRST_PAGES * PAGE_SIZE, 1)
	testing.expect_value(t, second, call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, fake.range_count, 2)
	testing.expect_value(t, fake.ranges[1], op.Page_Range{first = ARENA_GROWTH_STEP_FIRST_PAGES, page_count = 20 - ARENA_GROWTH_STEP_FIRST_PAGES})
	testing.expect_value(t, fake.committed_pages, 20)
}

// A reset keeps the committed pages: the same pushes give the same
// addresses, and commit nothing.
@(test)
arena_reset_then_reuse_commits_nothing :: proc(t: ^testing.T) {
	fake := fake_reservation(64, 100)
	first, status := arena_push(&fake.arena, 3 * PAGE_SIZE, 8)
	testing.expect_value(t, status, call_outcome.Call_Outcome.Succeeded)
	second, _ := arena_push(&fake.arena, 100, 8)
	committed := fake.committed_pages
	calls := fake.commit_calls
	arena_reset(&fake.arena)
	testing.expect_value(t, fake.used_bytes, 0)
	testing.expect_value(t, fake.committed_pages, committed)
	again, again_status := arena_push(&fake.arena, 3 * PAGE_SIZE, 8)
	testing.expect_value(t, again_status, call_outcome.Call_Outcome.Succeeded)
	second_again, _ := arena_push(&fake.arena, 100, 8)
	testing.expect_value(t, again, first)
	testing.expect_value(t, second_again, second)
	testing.expect_value(t, fake.commit_calls, calls)
	testing.expect_value(t, fake.committed_pages, committed)
	testing.expect_value(t, fake.budget_pages, 100 - committed)
}

// A pop takes back the last bytes: the next push takes the same address,
// the pages stay committed; a pop of more than the arena gave, and of one
// byte more, change nothing; a pop of 0 is no change.
@(test)
arena_pop_takes_back_the_last_push :: proc(t: ^testing.T) {
	fake := fake_reservation(64, 100)
	_, _ = arena_push(&fake.arena, 100, 8)
	last, _ := arena_push(&fake.arena, 64, 8)
	committed := fake.committed_pages
	used := fake.used_bytes
	testing.expect(t, !arena_pop(&fake.arena, used + 1), "a pop past the arena is taken")
	testing.expect_value(t, fake.used_bytes, used)
	testing.expect(t, arena_pop(&fake.arena, 0), "a pop of 0 is refused")
	testing.expect_value(t, fake.used_bytes, used)
	testing.expect(t, arena_pop(&fake.arena, 64), "the pop of the last push is refused")
	testing.expect_value(t, fake.used_bytes, used - 64)
	testing.expect_value(t, fake.committed_pages, committed)
	again, _ := arena_push(&fake.arena, 64, 8)
	testing.expect_value(t, again, last)
	testing.expect(t, arena_pop(&fake.arena, fake.used_bytes), "the pop of the whole arena is refused")
	testing.expect_value(t, fake.used_bytes, 0)
}

// The size of a reservation: the edges 0 and 1, a page below and at a list
// page, one past it, the largest object and past it.
@(test)
arena_reservation_pages_rounds_to_a_list_page :: proc(t: ^testing.T) {
	testing.expect_value(t, arena_reservation_pages(0), op.MEMORY_LIST_ENTRIES)
	testing.expect_value(t, arena_reservation_pages(1), op.MEMORY_LIST_ENTRIES)
	testing.expect_value(t, arena_reservation_pages(op.MEMORY_LIST_ENTRIES - 1), op.MEMORY_LIST_ENTRIES)
	testing.expect_value(t, arena_reservation_pages(op.MEMORY_LIST_ENTRIES), op.MEMORY_LIST_ENTRIES)
	testing.expect_value(t, arena_reservation_pages(op.MEMORY_LIST_ENTRIES + 1), 2 * op.MEMORY_LIST_ENTRIES)
	testing.expect_value(t, arena_reservation_pages(1900), 2048)
	testing.expect_value(t, arena_reservation_pages(op.MEMORY_PAGE_LIMIT - 1), op.MEMORY_PAGE_LIMIT)
	testing.expect_value(t, arena_reservation_pages(op.MEMORY_PAGE_LIMIT), op.MEMORY_PAGE_LIMIT)
	testing.expect_value(t, arena_reservation_pages(op.MEMORY_PAGE_LIMIT + 1), op.MEMORY_PAGE_LIMIT)
	testing.expect_value(t, arena_reservation_pages(max(u64)), op.MEMORY_PAGE_LIMIT)
}

// A reservation past the largest object gives the zero arena, which
// refuses each push, so its reserved bytes never wrap; the largest object
// itself is taken.
@(test)
arena_of_reservation_refuses_more_than_the_largest_object :: proc(t: ^testing.T) {
	refused := [?]u64{op.MEMORY_PAGE_LIMIT + 1, max(u64) / PAGE_SIZE + 1, max(u64)}
	for pages in refused {
		arena := arena_of_reservation(([^]u8)(rawptr(FAKE_BASE)), pages, fake_page_change)
		testing.expect_value(t, arena, Arena{})
		_, status := arena_push(&arena, 1, 1)
		testing.expect_value(t, status, call_outcome.Call_Outcome.Argument_Refused)
	}
	largest := arena_of_reservation(([^]u8)(rawptr(FAKE_BASE)), op.MEMORY_PAGE_LIMIT, fake_page_change)
	testing.expect_value(t, largest.reserved_pages, op.MEMORY_PAGE_LIMIT)
}

// A commit refused with another status than No_Budget is given back with
// its record and with no retry of the missing pages, and nothing changes.
@(test)
arena_push_gives_back_another_refusal_with_no_retry :: proc(t: ^testing.T) {
	fake := fake_reservation(64, 100)
	fake.commit_refusal = .Argument_Refused
	before := fake.arena
	record: errors.Error_Record
	result, status := arena_push(&fake.arena, 1, 1, &record)
	testing.expect_value(t, status, call_outcome.Call_Outcome.Argument_Refused)
	testing.expect_value(t, result, nil)
	testing.expect_value(t, record.kind, i64(errors.Kind.Handle_Kind))
	testing.expect_value(t, fake.commit_calls, 1)
	testing.expect_value(t, fake.arena, before)
	testing.expect_value(t, fake.budget_pages, 100)
}

// A push of the whole reservation into an empty arena is the bound: it is
// taken. Then a push aligned on a page, with the used bytes at the end of
// the reservation, and with one byte left before the end: each one is
// refused with Full, and nothing changes.
@(test)
arena_push_of_the_whole_reservation_then_a_page_alignment_at_the_end :: proc(t: ^testing.T) {
	RESERVED_PAGES :: 4
	reserved_bytes := u64(RESERVED_PAGES * PAGE_SIZE)
	whole := fake_reservation(RESERVED_PAGES, 100)
	result, status := arena_push(&whole.arena, reserved_bytes, 1)
	testing.expect_value(t, status, call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, offset_of_address(result), 0)
	testing.expect_value(t, whole.used_bytes, reserved_bytes)
	testing.expect_value(t, whole.committed_pages, RESERVED_PAGES)
	before := whole.arena
	record: errors.Error_Record
	result, status = arena_push(&whole.arena, 1, PAGE_SIZE, &record)
	testing.expect_value(t, status, call_outcome.Call_Outcome.Budget_Or_Capacity_Exhausted)
	testing.expect_value(t, result, nil)
	testing.expect_value(t, record.kind, i64(errors.Kind.Full))
	testing.expect_value(t, whole.arena, before)

	one_left := fake_reservation(RESERVED_PAGES, 100)
	_, filled := arena_push(&one_left.arena, reserved_bytes - 1, 1)
	testing.expect_value(t, filled, call_outcome.Call_Outcome.Succeeded)
	before = one_left.arena
	result, status = arena_push(&one_left.arena, 1, PAGE_SIZE)
	testing.expect_value(t, status, call_outcome.Call_Outcome.Budget_Or_Capacity_Exhausted)
	testing.expect_value(t, result, nil)
	testing.expect_value(t, one_left.arena, before)
}

// The step after a retry: a step that the budget refused is followed by
// the missing page alone, and the next step halves, down to the first
// step; it never doubles. An accepted step doubles it again.
@(test)
arena_growth_step_halves_after_a_retry :: proc(t: ^testing.T) {
	fake := fake_reservation(200, ARENA_GROWTH_STEP_FIRST_PAGES + 4)
	_, status := arena_push(&fake.arena, PAGE_SIZE, PAGE_SIZE)
	testing.expect_value(t, status, call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, fake.growth_step_pages, 2 * ARENA_GROWTH_STEP_FIRST_PAGES)

	// The step of 32 pages is refused: the missing page alone, and the
	// step halves to 16.
	_, status = arena_push(&fake.arena, ARENA_GROWTH_STEP_FIRST_PAGES * PAGE_SIZE, PAGE_SIZE)
	testing.expect_value(t, status, call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, fake.growth_step_pages, ARENA_GROWTH_STEP_FIRST_PAGES)
	// The step of 16 pages is refused: the step stays at the first step.
	_, status = arena_push(&fake.arena, PAGE_SIZE, PAGE_SIZE)
	testing.expect_value(t, status, call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, fake.growth_step_pages, ARENA_GROWTH_STEP_FIRST_PAGES)
	testing.expect_value(t, fake.commit_calls, 5)

	// A budget that pays: the step of 16 pages, then 32, each accepted.
	fake.budget_pages = 1000
	_, status = arena_push(&fake.arena, PAGE_SIZE, PAGE_SIZE)
	testing.expect_value(t, status, call_outcome.Call_Outcome.Succeeded)
	_, status = arena_push(&fake.arena, ARENA_GROWTH_STEP_FIRST_PAGES * PAGE_SIZE, PAGE_SIZE)
	testing.expect_value(t, status, call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, fake.growth_step_pages, 4 * ARENA_GROWTH_STEP_FIRST_PAGES)
	// A step of 64 pages refused: the missing page alone, and the step
	// halves to 32.
	fake.budget_pages = 1
	_, status = arena_push(&fake.arena, 2 * ARENA_GROWTH_STEP_FIRST_PAGES * PAGE_SIZE, PAGE_SIZE)
	testing.expect_value(t, status, call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, fake.growth_step_pages, 2 * ARENA_GROWTH_STEP_FIRST_PAGES)

	expected := [?]op.Page_Range{{0, 16}, {16, 1}, {17, 1}, {18, 16}, {34, 32}, {66, 1}}
	testing.expect_value(t, fake.range_count, len(expected))
	for expected_range, index in expected {
		testing.expect_value(t, fake.ranges[index], expected_range)
	}
	testing.expect_value(t, fake.commit_count, u64(len(expected)))
	testing.expect_value(t, fake.committed_pages, 67)
	testing.expect_value(t, fake.pages_of_the_fake, 67)
}

// The undo of a refused push of several calls, whose decommit is refused:
// the push gives Bad_State with the record of the decommit, and the arena
// counts the pages that stay committed, as the fake does. With three
// calls, the undo gives back the last call first, so the pages that stay
// follow the committed end. The arena then still serves a push inside
// those pages.
@(test)
arena_push_with_a_refused_undo_keeps_the_committed_pages :: proc(t: ^testing.T) {
	LIMIT :: op.RANGE_TABLE_PAGE_LIMIT
	// Two calls, and the one decommit of the undo is refused.
	two := fake_reservation(3 * LIMIT, LIMIT + 1)
	two.decommits_accepted = 0
	record: errors.Error_Record
	result, status := arena_push(&two.arena, (LIMIT + 2) * PAGE_SIZE, 1, &record)
	testing.expect_value(t, status, call_outcome.Call_Outcome.Wrong_State)
	testing.expect_value(t, result, nil)
	testing.expect_value(t, record.kind, i64(errors.Kind.State))
	testing.expect_value(t, two.committed_pages, LIMIT)
	testing.expect_value(t, two.pages_of_the_fake, LIMIT)
	testing.expect_value(t, two.used_bytes, 0)
	testing.expect_value(t, two.commit_count, 0)
	testing.expect_value(t, two.decommit_calls, 1)

	// Three calls: the undo gives back the second call, then its decommit
	// of the first call is refused.
	three := fake_reservation(3 * LIMIT, 2 * LIMIT + 1)
	three.decommits_accepted = 1
	record = {}
	result, status = arena_push(&three.arena, (2 * LIMIT + 2) * PAGE_SIZE, 1, &record)
	testing.expect_value(t, status, call_outcome.Call_Outcome.Wrong_State)
	testing.expect_value(t, result, nil)
	testing.expect_value(t, record.kind, i64(errors.Kind.State))
	testing.expect_value(t, three.committed_pages, LIMIT)
	testing.expect_value(t, three.pages_of_the_fake, LIMIT)
	testing.expect_value(t, three.budget_pages, LIMIT + 1)
	testing.expect_value(t, three.decommit_calls, 2)

	// A push inside the pages that stay committed needs no commit.
	calls := three.commit_calls
	result, status = arena_push(&three.arena, PAGE_SIZE, 1)
	testing.expect_value(t, status, call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, offset_of_address(result), 0)
	testing.expect_value(t, three.commit_calls, calls)
}

// A buffer that grows in one arena: each refusal first (past the
// reservation, a budget that pays neither step), then the doubled step,
// the minimum alone when the budget refuses the double, and a size already
// in use, which commits nothing. The base never moves.
@(test)
arena_extend_to_grows_one_buffer_in_place :: proc(t: ^testing.T) {
	RESERVED_PAGES :: 8
	past := fake_reservation(RESERVED_PAGES, 100)
	bytes, status := arena_extend_to(&past.arena, RESERVED_PAGES * PAGE_SIZE + 1)
	testing.expect_value(t, status, call_outcome.Call_Outcome.Budget_Or_Capacity_Exhausted)
	testing.expect(t, bytes == nil)
	testing.expect_value(t, past.used_bytes, 0)
	testing.expect_value(t, past.commit_calls, 0)

	poor := fake_reservation(RESERVED_PAGES, 0)
	bytes, status = arena_extend_to(&poor.arena, 1)
	testing.expect_value(t, status, call_outcome.Call_Outcome.Budget_Or_Capacity_Exhausted)
	testing.expect_value(t, poor.used_bytes, 0)
	testing.expect_value(t, poor.pages_of_the_fake, 0)

	fake := fake_reservation(RESERVED_PAGES, 100)
	bytes, status = arena_extend_to(&fake.arena, 100)
	testing.expect_value(t, status, call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, len(bytes), 100)
	testing.expect_value(t, uintptr(raw_data(bytes)), FAKE_BASE)
	// Past the end: the double of the bytes in use, from the same base.
	bytes, status = arena_extend_to(&fake.arena, 150)
	testing.expect_value(t, status, call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, len(bytes), 200)
	testing.expect_value(t, uintptr(raw_data(bytes)), FAKE_BASE)
	// A size in use commits nothing.
	calls := fake.commit_calls
	bytes, status = arena_extend_to(&fake.arena, 10)
	testing.expect_value(t, len(bytes), 200)
	testing.expect_value(t, fake.commit_calls, calls)
	// The reservation whole: the double is cut to it.
	bytes, status = arena_extend_to(&fake.arena, RESERVED_PAGES * PAGE_SIZE)
	testing.expect_value(t, status, call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, len(bytes), RESERVED_PAGES * PAGE_SIZE)

	// A budget of 3 pages refuses the doubled step of 4 pages and pays the
	// minimum of 3.
	tight := fake_reservation(RESERVED_PAGES, 3)
	_, status = arena_extend_to(&tight.arena, 2 * PAGE_SIZE)
	testing.expect_value(t, status, call_outcome.Call_Outcome.Succeeded)
	bytes, status = arena_extend_to(&tight.arena, 2 * PAGE_SIZE + 1)
	testing.expect_value(t, status, call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, len(bytes), 2 * PAGE_SIZE + 1)
	testing.expect_value(t, uintptr(raw_data(bytes)), FAKE_BASE)
}

// The growth of a buffer of records of 12 bytes: past the reservation and
// a budget that pays nothing first (refused, the arena as it was), then a
// negative count (no growth), then whole records only, from the same base.
@(test)
arena_grow_gives_whole_records_in_place :: proc(t: ^testing.T) {
	Record :: [3]u32
	RESERVED_PAGES :: 2
	none: []Record
	past := fake_reservation(RESERVED_PAGES, 100)
	grown, ok := arena_grow(&past.arena, none, RESERVED_PAGES * PAGE_SIZE / size_of(Record) + 1)
	testing.expect(t, !ok && grown == nil)
	testing.expect_value(t, past.used_bytes, 0)

	poor := fake_reservation(RESERVED_PAGES, 0)
	grown, ok = arena_grow(&poor.arena, none, 1)
	testing.expect(t, !ok && grown == nil)
	testing.expect_value(t, poor.used_bytes, 0)

	fake := fake_reservation(RESERVED_PAGES, 100)
	grown, ok = arena_grow(&fake.arena, none, -1)
	testing.expect(t, ok)
	testing.expect_value(t, len(grown), 0)
	testing.expect_value(t, fake.used_bytes, 0)
	grown, ok = arena_grow(&fake.arena, grown, 10)
	testing.expect(t, ok)
	testing.expect_value(t, len(grown), 10)
	testing.expect_value(t, uintptr(raw_data(grown)), FAKE_BASE)
	// The doubled step is 240 bytes: 20 whole records.
	grown, ok = arena_grow(&fake.arena, grown, 11)
	testing.expect(t, ok)
	testing.expect_value(t, len(grown), 20)
	testing.expect_value(t, uintptr(raw_data(grown)), FAKE_BASE)
	// The reservation whole: the records that fit in it, a part cut off.
	grown, ok = arena_grow(&fake.arena, grown, RESERVED_PAGES * PAGE_SIZE / size_of(Record))
	testing.expect(t, ok)
	testing.expect_value(t, len(grown), RESERVED_PAGES * PAGE_SIZE / size_of(Record))
}

// A trim gives back the committed pages past the bytes that it keeps, from
// the end, and moves the end of the arena back; a push past it commits
// again. A trim past the committed end, and a trim to 0, are edges; a
// refused decommit leaves the pages before it committed.
@(test)
arena_trim_gives_back_the_pages_past_what_it_keeps :: proc(t: ^testing.T) {
	fake := fake_reservation(4096, 4096)
	_, status := arena_push(&fake.arena, 1000 * PAGE_SIZE, 1)
	testing.expect_value(t, status, call_outcome.Call_Outcome.Succeeded)
	committed := fake.committed_pages
	testing.expect(t, committed >= 1000)
	// Past the committed end: nothing changes.
	testing.expect_value(t, arena_trim(&fake.arena, committed * PAGE_SIZE + 1), call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, fake.committed_pages, committed)
	testing.expect_value(t, fake.decommit_calls, 0)
	// To 10 pages and one byte: 11 pages stay, the rest goes back.
	testing.expect_value(t, arena_trim(&fake.arena, 10 * PAGE_SIZE + 1), call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, fake.committed_pages, 11)
	testing.expect_value(t, fake.pages_of_the_fake, 11)
	testing.expect_value(t, fake.used_bytes, 10 * PAGE_SIZE + 1)
	testing.expect_value(t, fake.growth_step_pages, ARENA_GROWTH_STEP_FIRST_PAGES)
	// A push past it commits again.
	_, status = arena_push(&fake.arena, 100 * PAGE_SIZE, 1)
	testing.expect_value(t, status, call_outcome.Call_Outcome.Succeeded)
	testing.expect(t, fake.committed_pages >= 111)
	// To 0: each page goes back.
	testing.expect_value(t, arena_trim(&fake.arena, 0), call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, fake.committed_pages, 0)
	testing.expect_value(t, fake.pages_of_the_fake, 0)
	testing.expect_value(t, fake.used_bytes, 0)
	// A refused decommit, past the first call of a trim of two calls: the
	// pages before it stay committed, and the end follows them.
	large := fake_reservation(3 * op.RANGE_TABLE_PAGE_LIMIT, 3 * op.RANGE_TABLE_PAGE_LIMIT)
	_, status = arena_push(&large.arena, 2 * op.RANGE_TABLE_PAGE_LIMIT * PAGE_SIZE, 1)
	testing.expect_value(t, status, call_outcome.Call_Outcome.Succeeded)
	committed = large.committed_pages
	large.decommits_accepted = 1
	testing.expect_value(t, arena_trim(&large.arena, 0), call_outcome.Call_Outcome.Wrong_State)
	testing.expect(t, large.committed_pages > 0 && large.committed_pages < committed)
	testing.expect_value(t, large.pages_of_the_fake, large.committed_pages)
	testing.expect(t, large.used_bytes <= large.committed_pages * PAGE_SIZE)
}

// An arena of exact commits: arena_push_commit_pages gives each page that
// the push then takes from the budget, at the edges of a page and of the
// budget; a push that the budget cannot pay changes nothing. With the step
// of the growth, the count is the step.
@(test)
arena_push_commit_pages_names_each_page_that_the_push_takes :: proc(t: ^testing.T) {
	fake := fake_reservation(1024, 3)
	fake.arena.exact_commits = true
	pages, fits := arena_push_commit_pages(&fake.arena, PAGE_SIZE, 8)
	testing.expect(t, fits && pages == 1)
	_, status := arena_push(&fake.arena, PAGE_SIZE, 8)
	testing.expect_value(t, status, call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, fake.budget_pages, u64(2))
	// One byte more needs one page; the two pages left pay two pages, not three.
	pages, fits = arena_push_commit_pages(&fake.arena, 1, 1)
	testing.expect(t, fits && pages == 1)
	pages, fits = arena_push_commit_pages(&fake.arena, 2 * PAGE_SIZE, 1)
	testing.expect(t, fits && pages == 2)
	pages, fits = arena_push_commit_pages(&fake.arena, 2 * PAGE_SIZE + 1, 1)
	testing.expect(t, fits && pages == 3)
	_, status = arena_push(&fake.arena, 2 * PAGE_SIZE + 1, 1)
	testing.expect_value(t, status, call_outcome.Call_Outcome.Budget_Or_Capacity_Exhausted)
	testing.expect(t, fake.budget_pages == 2 && fake.arena.committed_pages == 1)
	_, status = arena_push(&fake.arena, 2 * PAGE_SIZE, 1)
	testing.expect(t, status == .Succeeded && fake.budget_pages == 0)
	// Inside the committed pages: no page.
	fake.arena.used_bytes = PAGE_SIZE
	pages, fits = arena_push_commit_pages(&fake.arena, PAGE_SIZE, 1)
	testing.expect(t, fits && pages == 0)
	// Past the reservation, a size of 0, a bad alignment: no push.
	_, fits = arena_push_commit_pages(&fake.arena, 1024 * PAGE_SIZE, 1)
	testing.expect(t, !fits)
	_, fits = arena_push_commit_pages(&fake.arena, 0, 1)
	testing.expect(t, !fits)
	_, fits = arena_push_commit_pages(&fake.arena, 1, 3)
	testing.expect(t, !fits)

	stepped := fake_reservation(1024, 1000)
	pages, fits = arena_push_commit_pages(&stepped.arena, 1, 1)
	testing.expect(t, fits && pages == ARENA_GROWTH_STEP_FIRST_PAGES)
	_, status = arena_push(&stepped.arena, 1, 1)
	testing.expect(t, status == .Succeeded && stepped.budget_pages == 1000 - ARENA_GROWTH_STEP_FIRST_PAGES)
}
