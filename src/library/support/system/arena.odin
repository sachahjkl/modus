package system

import "modus:contract/errors"
import op "modus:contract/operation"

// An arena: an uncommitted memory object of this process that grows by an
// explicit commit and ends whole. It holds data with no known bound, as the
// tree of a document. See [arena](term:arena), and the design in
// src/md/features/memory_without_a_bound.md.
//
// The arena reserves its addresses once and never moves, so an address
// that a push gave stays valid until `arena_reset` or `arena_end`. A push
// past the committed end commits the next pages; a budget that cannot pay
// them refuses with `No_Budget`, which the push gives back, and the arena
// stays as it was. A scratch arena of a frame is an arena that the process
// resets at the start of each frame: it keeps its committed pages, so a
// frame commits nothing in the usual case.
//
// The arena owns its memory object alone: one handle and one mapping, in
// this process. A process that copies the handle or maps the object again
// breaks the undo of a refused push, because a decommit of an object that
// another holder names is refused.
//
// ```odin
// arena := system.arena_create(4096) or_return
// node := (^Node)(system.arena_push(&arena, size_of(Node), align_of(Node)) or_return)
// system.arena_end(&arena)
// ```
Arena :: struct {
	memory:            Handle, // The uncommitted object; 0 for an arena that a host test drives.
	budget:            Handle, // The budget that pays the commits; 0: the budget of this process.
	base:              [^]u8, // The first byte of the reserved range: it never moves.
	reserved_pages:    u64, // The pages of the object.
	committed_pages:   u64, // The pages from the base that the budget pays.
	used_bytes:        u64, // The end of the last push, from the base.
	growth_step_pages: u64, // The least pages of the next commit.
	commit_count:      u64, // The commits that the budget accepted: a measure of the step of the growth.
	page_change:       Arena_Page_Change,
}

// The procedure that commits or decommits one range of the pages of an
// arena: `Memory_Commit` on a machine, a fake in a host test, so that the
// arithmetic of a push runs with no kernel.
Arena_Page_Change :: #type proc "contextless" (arena: ^Arena, range: op.Page_Range, flags: op.Commit_Flags, error: ^errors.Error_Record) -> Status

// The step of the growth: the first commit takes 16 pages, and each one
// after it the double of the step before, up to 512 pages, so that a run of
// small pushes costs few kernel commands and a small arena pays little. A
// step that the budget refused halves, down to the first step: the budget
// is near its end, and a step that it refuses again costs one more call.
ARENA_GROWTH_STEP_FIRST_PAGES :: 16
ARENA_GROWTH_STEP_LIMIT_PAGES :: 512
// A retry commits fewer pages than a step, so it is always one call: only
// a push larger than a step makes several calls.
#assert(ARENA_GROWTH_STEP_LIMIT_PAGES <= op.RANGE_TABLE_PAGE_LIMIT)
// The largest alignment of a push: the base of the reserved range is
// aligned on a page, and on nothing larger.
ARENA_ALIGNMENT_LIMIT :: PAGE_SIZE

// arena_create reserves an arena of `reserve_pages` pages: an uncommitted
// object, mapped once with Write. The budget (0: the budget of this
// process) pays the frame list now and each page at its commit.
//
// - `reserve_pages`: from 1 to `op.MEMORY_PAGE_LIMIT` (1 GiB);
//   `arena_reservation_pages` gives a size from what a budget holds.
// - `budget`: a budget handle with **Spend**.
//
// The statuses are those of `Memory_Create` and of `Memory_Map`; after a
// refused map, the object is closed and the budget holds what it held.
arena_create :: proc "contextless" (reserve_pages: u64, budget: Handle = 0, error: ^errors.Error_Record = nil) -> (arena: Arena, status: Status) {
	memory: Handle
	memory, status = memory_create(reserve_pages, budget, {.Uncommitted}, error)
	if status != .Ok {
		return {}, status
	}
	address: rawptr
	address, status = memory_map(memory, {.Write}, error = error)
	if status != .Ok {
		close(memory)
		return {}, status
	}
	arena = arena_of_reservation(([^]u8)(address), reserve_pages, arena_kernel_page_change)
	arena.memory = memory
	arena.budget = budget
	return arena, .Ok
}

// arena_of_reservation gives an arena over a reserved range that commits
// its pages with `page_change`. arena_create calls it with the kernel; a
// host test calls it with a fake. A reservation above `op.MEMORY_PAGE_LIMIT`
// pages, which no memory object has, gives the zero arena, which refuses
// each push: so the reserved bytes never wrap.
arena_of_reservation :: proc "contextless" (base: [^]u8, reserved_pages: u64, page_change: Arena_Page_Change) -> Arena {
	if reserved_pages > op.MEMORY_PAGE_LIMIT {
		return {}
	}
	return {base = base, reserved_pages = reserved_pages, growth_step_pages = ARENA_GROWTH_STEP_FIRST_PAGES, page_change = page_change}
}

// arena_reservation_pages gives the size of a reservation for a budget
// that holds `budget_pages`: those pages rounded up to a whole list page of
// the frame list (512 pages), at least one, at most `op.MEMORY_PAGE_LIMIT`.
// The frame list then costs at most one page in 512 of the budget, and a
// commit meets the budget before the end of the reservation.
//
// Example: `arena_reservation_pages(1900)` is 2048.
arena_reservation_pages :: proc "contextless" (budget_pages: u64) -> u64 {
	if budget_pages >= op.MEMORY_PAGE_LIMIT {
		return op.MEMORY_PAGE_LIMIT
	}
	rounded := budget_pages + (op.MEMORY_LIST_ENTRIES - budget_pages % op.MEMORY_LIST_ENTRIES) % op.MEMORY_LIST_ENTRIES
	return max(rounded, op.MEMORY_LIST_ENTRIES)
}

// arena_push gives `size` bytes of the arena at an address that is a
// multiple of `alignment`, after the bytes of the push before. It commits
// the pages that the bytes need and that are not committed. A refusal
// changes nothing in the arena and gives no address.
//
// The statuses:
//
// - `Bad_Operation`: `size` is 0 (`Too_Small`); `alignment` is not a power
//   of two or is above `ARENA_ALIGNMENT_LIMIT` (`Bad_Value`); `size` is
//   above the whole reservation (`Too_Long`).
// - `No_Slot`: the bytes do not fit in the rest of the reservation
//   (`Full`, unit `Bytes`).
// - `No_Budget`: the budget cannot pay the pages that the push needs; the
//   error record is the record of `Memory_Commit`.
// - `Bad_State`: a push of several calls was refused, and the decommit of
//   the pages that it had committed was refused too; the error record is
//   the record of that decommit. The arena keeps the pages that stay
//   committed. It happens only when another holder names the object of
//   the arena, which an arena forbids (the type `Arena`).
// - Each other status of `Memory_Commit`, with its record, and with no
//   retry.
//
// The records that the arena writes itself name no operation
// (`op.Operation.None`), and a value past `max(i64)` is written as
// `max(i64)`: a record holds signed values.
//
// ```odin
// bytes, status := system.arena_push(&arena, 100, 8)
// if status == .No_Budget {
// 	system.log("reader: this page is too large")
// }
// ```
arena_push :: proc "contextless" (arena: ^Arena, size: u64, alignment: u64, error: ^errors.Error_Record = nil) -> (result: rawptr, status: Status) {
	reserved_bytes := arena.reserved_pages * PAGE_SIZE
	if size == 0 {
		arena_refusal_write(error, arena_record(.Too_Small, 2, 0, 1, 0))
		return nil, .Bad_Operation
	}
	if alignment == 0 || alignment & (alignment - 1) != 0 || alignment > ARENA_ALIGNMENT_LIMIT {
		arena_refusal_write(error, arena_record(.Bad_Value, 3, alignment, ARENA_ALIGNMENT_LIMIT, 0))
		return nil, .Bad_Operation
	}
	// Before any sum: a size near the top of the type would wrap the end of
	// the push to a small one.
	if size > reserved_bytes {
		arena_refusal_write(error, arena_record(.Too_Long, 2, size, reserved_bytes, 0))
		return nil, .Bad_Operation
	}
	// The used bytes are at most the reserved bytes, a whole number of
	// pages, so the rounded start stays inside the reservation.
	start := (arena.used_bytes + alignment - 1) & ~(alignment - 1)
	if start > reserved_bytes || size > reserved_bytes - start {
		arena_refusal_write(error, arena_record(.Full, 2, size, reserved_bytes, arena.used_bytes))
		return nil, .No_Slot
	}
	end := start + size
	needed_pages := end / PAGE_SIZE
	if end % PAGE_SIZE != 0 {
		needed_pages += 1
	}
	if needed_pages > arena.committed_pages {
		if grown := arena_grow(arena, needed_pages - arena.committed_pages, error); grown != .Ok {
			return nil, grown
		}
	}
	arena.used_bytes = end
	return &arena.base[start], .Ok
}

// arena_reset sets the end of the arena back to its start and keeps its
// committed pages: the next pushes take the same addresses and commit
// nothing until they pass the largest end so far. The bytes are not
// cleared. It is the start of each frame of a scratch arena.
arena_reset :: proc "contextless" (arena: ^Arena) {
	arena.used_bytes = 0
}

// arena_end ends the arena whole: it unmaps the range and closes the
// object, so each committed page and the frame list return to the budget
// at once. Each address of the arena is then invalid. The arena becomes
// the zero arena, which refuses each push; a zero arena ends with `Ok`.
arena_end :: proc "contextless" (arena: ^Arena, error: ^errors.Error_Record = nil) -> Status {
	if arena.memory == 0 {
		arena^ = {}
		return .Ok
	}
	status := memory_unmap(rawptr(arena.base), 0, error)
	close(arena.memory)
	arena^ = {}
	return status
}

// arena_grow commits at least `missing_pages` after the committed end: one
// step of the growth, or only the missing pages when the budget refuses
// the step. So the arena grows until its budget holds no page for the
// push, not until it holds less than a step.
//
// An accepted step doubles the next one. A retry halves it, down to the
// first step: near the end of the budget, a step that doubled after each
// retry was refused again at each push, and each push then paid two calls.
@(private = "file")
arena_grow :: proc "contextless" (arena: ^Arena, missing_pages: u64, error: ^errors.Error_Record) -> Status {
	step := min(max(missing_pages, arena.growth_step_pages), arena.reserved_pages - arena.committed_pages)
	// The record of the last refusal only: a step that the budget refused
	// and a smaller commit that it paid is no failure.
	refusal: errors.Error_Record
	status := arena_commit_run(arena, step, &refusal)
	retried := false
	if status == .No_Budget && step > missing_pages {
		retried = true
		status = arena_commit_run(arena, missing_pages, &refusal)
	}
	if status != .Ok {
		arena_refusal_write(error, refusal)
		return status
	}
	arena.commit_count += 1
	if retried {
		arena.growth_step_pages = max(arena.growth_step_pages / 2, ARENA_GROWTH_STEP_FIRST_PAGES)
	} else {
		arena.growth_step_pages = min(arena.growth_step_pages * 2, ARENA_GROWTH_STEP_LIMIT_PAGES)
	}
	return .Ok
}

// arena_commit_run commits `page_count` pages after the committed end, in
// calls of at most `op.RANGE_TABLE_PAGE_LIMIT` pages, and moves the
// committed end past them. A refused call gives back the pages that the
// calls before it committed, so a push is whole or changes nothing, as one
// call is. The undo gives back the last call first: when a decommit is
// refused, the pages that stay committed follow the committed end, which
// moves past them, and the run gives `Bad_State` with the record of the
// decommit.
@(private = "file")
arena_commit_run :: proc "contextless" (arena: ^Arena, page_count: u64, error: ^errors.Error_Record) -> Status {
	first := arena.committed_pages
	done: u64
	for done < page_count {
		part := min(page_count - done, op.RANGE_TABLE_PAGE_LIMIT)
		status := arena.page_change(arena, {first = first + done, page_count = part}, {}, error)
		if status != .Ok {
			// The calls before it each committed a whole part, so the undo
			// takes the same parts back, from the last one.
			for done > 0 {
				back := done % op.RANGE_TABLE_PAGE_LIMIT
				if back == 0 {
					back = op.RANGE_TABLE_PAGE_LIMIT
				}
				if arena.page_change(arena, {first = first + done - back, page_count = back}, {.Decommit}, error) != .Ok {
					arena.committed_pages = first + done
					return .Bad_State
				}
				done -= back
			}
			return status
		}
		done += part
	}
	arena.committed_pages = first + page_count
	return .Ok
}

// arena_kernel_page_change is the page change of an arena on a machine:
// one Memory_Commit of one range, paid by the budget of the arena.
@(private = "file")
arena_kernel_page_change :: proc "contextless" (arena: ^Arena, range: op.Page_Range, flags: op.Commit_Flags, error: ^errors.Error_Record) -> Status {
	ranges := [1]op.Page_Range{range}
	if .Decommit in flags {
		_, decommitted := memory_decommit(arena.memory, ranges[:], error)
		return decommitted
	}
	_, committed := memory_commit(arena.memory, ranges[:], arena.budget, error)
	return committed
}

// arena_record gives a record of a refusal of the arena itself. The
// values are unsigned in the arena and signed in the record: a value past
// `max(i64)` is written as `max(i64)`, never as a negative number.
@(private = "file")
arena_record :: proc "contextless" (kind: errors.Kind, argument: i64, value, limit, found: u64) -> errors.Error_Record {
	record := errors.error_make(kind, .Bytes, argument, arena_record_value(value), arena_record_value(limit), arena_record_value(found))
	record.operation = i64(op.Operation.None)
	return record
}

@(private = "file")
arena_record_value :: proc "contextless" (value: u64) -> i64 {
	return value > u64(max(i64)) ? max(i64) : i64(value)
}

@(private = "file")
arena_refusal_write :: proc "contextless" (error: ^errors.Error_Record, record: errors.Error_Record) {
	if error != nil {
		error^ = record
	}
}
