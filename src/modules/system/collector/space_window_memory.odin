// The memory of the spaces (src/md/features/wide_grants.md, "The memory of
// the spaces"): no count of it is fixed. At its start the collector reads
// its budget once and reserves from it: the windows, in one uncommitted
// object whose window of a slot is committed when a space opens and
// decommitted when it closes; the table of the places and the buffer of
// the index, each in an arena that grows by commits and never moves.
package collector_service

import "base:intrinsics"
import op "modus:contract/operation"
import "modus:contract/wide_grants"
import "modus:system"

Space_Memory :: struct {
	windows_memory:   system.Handle,
	windows_base:     [^]u8,
	windows_reserved: u32, // The slots of windows of the reservation: what the budget held at the start.
	windows_used:     []bool, // For each slot, whether a space holds its window: in the arena flags.
	flags:            system.Arena,
	places:           system.Arena,
	places_count:     u32,
	index:            system.Arena,
}

space_memory: Space_Memory

#assert(size_of(wide_grants.Space_Window) <= wide_grants.SPACE_WINDOW_PAGES * system.PAGE_SIZE)
#assert(align_of(wide_grants.Collector_Space) <= system.ARENA_ALIGNMENT_LIMIT)

// space_memory_reserve reserves the memory of the spaces from the budget,
// and gives its port. A reservation that the kernel refuses gives a port
// that pays nothing, so each space is refused with its cause.
space_memory_reserve :: proc "contextless" () -> (port: wide_grants.Space_Memory_Port, windows: u32) {
	amounts, read := system.budget_read()
	if read != .Succeeded || amounts.pages == 0 {
		return {}, 0
	}
	reserve_pages := system.arena_reservation_pages(amounts.pages)
	windows = u32(min(amounts.pages / wide_grants.SPACE_WINDOW_PAGES, u64(max(u32))))
	if windows == 0 {
		return {}, 0
	}
	memory, created := system.memory_create(u64(windows) * wide_grants.SPACE_WINDOW_PAGES, 0, {.Uncommitted})
	if created != .Succeeded {
		return {}, 0
	}
	address, mapped := system.memory_map(memory, {.Write})
	if mapped != .Succeeded {
		system.close(memory)
		return {}, 0
	}
	flags, flags_made := system.arena_create(system.arena_reservation_pages(u64(windows) / system.PAGE_SIZE + 1))
	places, places_made := system.arena_create(reserve_pages)
	index, index_made := system.arena_create(reserve_pages)
	if flags_made != .Succeeded || places_made != .Succeeded || index_made != .Succeeded {
		return {}, 0
	}
	used, pushed := system.arena_push(&flags, u64(windows), 1)
	if pushed != .Succeeded {
		return {}, 0
	}
	space_memory = {
		windows_memory   = memory,
		windows_base     = ([^]u8)(address),
		windows_reserved = windows,
		windows_used     = ([^]bool)(used)[:windows],
		flags            = flags,
		places           = places,
		index            = index,
	}
	return {
		user         = &space_memory,
		window_take  = space_window_commit,
		window_give  = space_window_decommit,
		windows_left = space_windows_paid_left,
		places_grow  = space_places_grow,
		index_grow   = space_index_grow,
	}, windows
}

// space_window_range gives the pages of the window of a slot.
@(private = "file")
space_window_range :: proc "contextless" (slot: u32) -> [1]op.Page_Range {
	return {{first = u64(slot) * wide_grants.SPACE_WINDOW_PAGES, page_count = wide_grants.SPACE_WINDOW_PAGES}}
}

// space_window_commit commits the window of a free slot from the budget;
// a page committed again is zero.
@(private = "file")
space_window_commit :: proc "contextless" (user: rawptr) -> ^wide_grants.Space_Window {
	memory := (^Space_Memory)(user)
	for &used, slot in memory.windows_used {
		if used {
			continue
		}
		ranges := space_window_range(u32(slot))
		if _, committed := system.memory_commit(memory.windows_memory, ranges[:]); committed != .Succeeded {
			return nil
		}
		used = true
		return (^wide_grants.Space_Window)(&memory.windows_base[u64(slot) * wide_grants.SPACE_WINDOW_PAGES * system.PAGE_SIZE])
	}
	return nil
}

// space_window_decommit returns the pages of a window to the budget.
@(private = "file")
space_window_decommit :: proc "contextless" (user: rawptr, window: ^wide_grants.Space_Window) {
	memory := (^Space_Memory)(user)
	offset := uintptr(window) - uintptr(memory.windows_base)
	slot := u64(offset) / (wide_grants.SPACE_WINDOW_PAGES * system.PAGE_SIZE)
	if uintptr(window) < uintptr(memory.windows_base) || slot >= u64(memory.windows_reserved) {
		return
	}
	ranges := space_window_range(u32(slot))
	if _, decommitted := system.memory_decommit(memory.windows_memory, ranges[:]); decommitted == .Succeeded {
		memory.windows_used[slot] = false
	}
}

// space_windows_paid_left gives the windows that the budget still pays now,
// and that the reservation still has a slot for.
@(private = "file")
space_windows_paid_left :: proc "contextless" (user: rawptr) -> u32 {
	memory := (^Space_Memory)(user)
	amounts, read := system.budget_read()
	if read != .Succeeded {
		return 0
	}
	free: u32 = 0
	for used in memory.windows_used {
		if !used {
			free += 1
		}
	}
	return u32(min(amounts.pages / wide_grants.SPACE_WINDOW_PAGES, u64(free)))
}

// space_places_grow commits the places past the last one, after it: the
// table never moves.
@(private = "file")
space_places_grow :: proc "contextless" (user: rawptr, count: u32) -> []wide_grants.Collector_Space {
	memory := (^Space_Memory)(user)
	if count > memory.places_count {
		size := u64(count - memory.places_count) * size_of(wide_grants.Collector_Space)
		added, pushed := system.arena_push(&memory.places, size, align_of(wide_grants.Collector_Space))
		if pushed != .Succeeded {
			return nil
		}
		intrinsics.mem_zero(added, int(size))
		memory.places_count = count
	}
	return ([^]wide_grants.Collector_Space)(memory.places.base)[:memory.places_count]
}

// space_index_grow gives a buffer of the index of bytes: the arena starts
// again from its base, so the buffer keeps its pages and holds no bytes of
// the index before; a write or a read of the index fills it whole.
@(private = "file")
space_index_grow :: proc "contextless" (user: rawptr, bytes: int) -> []u8 {
	memory := (^Space_Memory)(user)
	system.arena_reset(&memory.index)
	buffer, pushed := system.arena_push(&memory.index, u64(bytes), 8)
	if pushed != .Succeeded {
		return nil
	}
	return ([^]u8)(buffer)[:bytes]
}
