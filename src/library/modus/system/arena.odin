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
	// A commit takes only the pages that a push needs, never a step: an
	// owner that keeps a part of its budget for other work then knows, from
	// arena_push_commit_pages, each page that a push takes.
	exact_commits:     bool,
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
// 	system.log(.Info, "reader: this page is too large")
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

// arena_take gives count values of T from an arena, zero when the arena
// never held them: a table whose size the process learns at its start, as
// one entry for each process slot of the machine (process_slots_of). A count
// of 0 gives an empty table and takes nothing. The statuses are those of
// arena_push.
//
// ```odin
// started = system.arena_take(&tables, Started, int(slots) - 1) or_return
// ```
arena_take :: proc "contextless" (arena: ^Arena, $T: typeid, count: int, error: ^errors.Error_Record = nil) -> (values: []T, status: Status) {
	if count <= 0 {
		return nil, .Ok
	}
	address := arena_push(arena, u64(count) * size_of(T), align_of(T), error) or_return
	return ([^]T)(address)[:count], .Ok
}

// arena_take_pages gives the pages that an arena reserves for tables of
// these sizes in bytes, each aligned on at most 64 bytes.
arena_take_pages :: proc "contextless" (sizes: []u64) -> u64 {
	bytes: u64
	for size in sizes {
		bytes = (bytes + 63) & ~u64(63) + size
	}
	return max((bytes + PAGE_SIZE - 1) / PAGE_SIZE, 1)
}

// process_slots_of gives the process slots of the machine
// (System_Report.process_slots), which the kernel chose at its start: a
// table with one entry for each process slot is this long. 0: the handle
// cannot read the report of the machine (it needs Inspect).
process_slots_of :: proc "contextless" (machine: Handle) -> u64 {
	report: op.System_Report
	if _, status := call(.Inspect, u64(machine), u64(op.Inspect_Kind.System), 0, u64(uintptr(&report)), size_of(report)); status != .Ok {
		return 0
	}
	return min(report.process_slots, op.PROCESS_SLOTS_MOST)
}

// arena_extend_to makes the one buffer of an arena, from its base, at least
// minimum_bytes long, and gives it whole. An arena that holds one buffer
// that grows (the bytes of a text, the rows of its layout) never moves: its
// pushes are contiguous, so the bytes before the growth stay in place and
// the caller copies nothing. The step doubles the bytes in use; when the
// budget refuses the doubled step, the minimum alone is asked for. A
// refusal is the status of arena_push, and the arena stays as it was.
//
// - `No_Slot`: minimum_bytes is past the reservation (`Full`, unit
//   `Bytes`).
// - `No_Budget`: the budget cannot pay the minimum.
arena_extend_to :: proc "contextless" (arena: ^Arena, minimum_bytes: u64, error: ^errors.Error_Record = nil) -> (bytes: []u8, status: Status) {
	if minimum_bytes <= arena.used_bytes {
		return arena.base[:arena.used_bytes], .Ok
	}
	reserved_bytes := arena.reserved_pages * PAGE_SIZE
	if minimum_bytes > reserved_bytes {
		arena_refusal_write(error, arena_record(.Full, 2, minimum_bytes, reserved_bytes, arena.used_bytes))
		return nil, .No_Slot
	}
	// The used bytes are at most the reservation, at most 1 GiB: the double
	// does not wrap.
	target := min(max(arena.used_bytes * 2, minimum_bytes), reserved_bytes)
	if _, pushed := arena_push(arena, target - arena.used_bytes, 1, error); pushed != .Ok {
		if target == minimum_bytes {
			return nil, pushed
		}
		if _, pushed = arena_push(arena, minimum_bytes - arena.used_bytes, 1, error); pushed != .Ok {
			return nil, pushed
		}
	}
	return arena.base[:arena.used_bytes], .Ok
}

// arena_grow is the growth of one buffer of records that an arena holds,
// in the form that a buffer of a caller takes (the bytes of a text, the
// rows of its layout, the places of the matches of a search): data is the
// ^Arena, and the buffer grows in place to at least minimum records, so
// the records before stay where they are. false: the arena refused, and
// the buffer is as it was. The caller gives it where a procedure of its
// record type is wanted, and the compiler makes the form of that type.
arena_grow :: proc "contextless" (data: rawptr, current: []$Record, minimum: int) -> (grown: []Record, ok: bool) {
	bytes, status := arena_extend_to((^Arena)(data), u64(max(minimum, 0) * size_of(Record)))
	if status != .Ok {
		return nil, false
	}
	return ([^]Record)(raw_data(bytes))[:len(bytes) / size_of(Record)], true
}

// arena_push_commit_pages gives the pages that a push of `size` bytes at
// `alignment` commits now: 0 when the committed pages hold it, the missing
// pages with `exact_commits`, else the step of the growth when it is
// larger. fits is false for a push that arena_push refuses for its size,
// its alignment or the rest of the reservation. It changes nothing.
arena_push_commit_pages :: proc "contextless" (arena: ^Arena, size: u64, alignment: u64) -> (pages: u64, fits: bool) {
	reserved_bytes := arena.reserved_pages * PAGE_SIZE
	if size == 0 || alignment == 0 || alignment & (alignment - 1) != 0 || alignment > ARENA_ALIGNMENT_LIMIT || size > reserved_bytes {
		return 0, false
	}
	start := (arena.used_bytes + alignment - 1) & ~(alignment - 1)
	if start > reserved_bytes || size > reserved_bytes - start {
		return 0, false
	}
	end := start + size
	needed := end / PAGE_SIZE + (end % PAGE_SIZE != 0 ? 1 : 0)
	if needed <= arena.committed_pages {
		return 0, true
	}
	missing := needed - arena.committed_pages
	if arena.exact_commits {
		return missing, true
	}
	return min(max(missing, arena.growth_step_pages), arena.reserved_pages - arena.committed_pages), true
}

// arena_reset sets the end of the arena back to its start and keeps its
// committed pages: the next pushes take the same addresses and commit
// nothing until they pass the largest end so far. The bytes are not
// cleared. It is the start of each frame of a scratch arena.
arena_reset :: proc "contextless" (arena: ^Arena) {
	arena.used_bytes = 0
}

// arena_reset_to sets the end of the arena back to a mark that an earlier
// end gave (arena.used_bytes), and keeps what was pushed before it. A mark
// past the end changes nothing: no push gave the bytes up to it.
arena_reset_to :: proc "contextless" (arena: ^Arena, mark: u64) {
	if mark <= arena.used_bytes {
		arena.used_bytes = mark
	}
}

// arena_trim gives back the committed pages past keep_bytes, and moves the
// end of the arena back to keep_bytes when it is past it: the bytes before
// keep_bytes keep their place and their value, and a push past it commits
// again (a page committed again is zero). So an arena that grew for a
// large use pays only for the use after it. It decommits from the end, in
// calls of at most `op.RANGE_TABLE_PAGE_LIMIT` pages: a refused call
// leaves the pages before it committed, the committed end follows them,
// and the status of the call comes back.
arena_trim :: proc "contextless" (arena: ^Arena, keep_bytes: u64, error: ^errors.Error_Record = nil) -> Status {
	keep_pages := min((keep_bytes + PAGE_SIZE - 1) / PAGE_SIZE, arena.committed_pages)
	status := Status.Ok
	for arena.committed_pages > keep_pages {
		part := min(arena.committed_pages - keep_pages, op.RANGE_TABLE_PAGE_LIMIT)
		if status = arena.page_change(arena, {first = arena.committed_pages - part, page_count = part}, {.Decommit}, error); status != .Ok {
			break
		}
		arena.committed_pages -= part
	}
	arena.used_bytes = min(arena.used_bytes, keep_bytes, arena.committed_pages * PAGE_SIZE)
	// The growth starts again from its first step: the next use is new.
	arena.growth_step_pages = ARENA_GROWTH_STEP_FIRST_PAGES
	return status
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
	step := arena.exact_commits ? missing_pages : min(max(missing_pages, arena.growth_step_pages), arena.reserved_pages - arena.committed_pages)
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
