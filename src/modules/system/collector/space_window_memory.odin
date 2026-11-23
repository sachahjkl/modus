// The windows of the spaces: one reservation of the memory of the
// collector, whose window of each place is committed from the budget when
// a space opens and decommitted when it closes
// (src/md/features/wide_grants.md, "The memory of the spaces").
package collector_service

import op "modus:contract/operation"
import "modus:contract/wide_grants"
import "modus:system"

// The reservation: an uncommitted object of a window for each place,
// mapped once.
Space_Windows :: struct {
	memory: system.Handle,
	base:   [^]u8,
}

space_windows: Space_Windows

#assert(size_of(wide_grants.Space_Window) <= wide_grants.SPACE_WINDOW_PAGES * system.PAGE_SIZE)

// space_windows_reserve makes the reservation, and gives the port of its
// windows and the windows that the budget pays: what it holds after the
// tables of the collector, at most the stated ones. A reservation that the
// kernel refuses pays no window, so each space is refused with its cause.
space_windows_reserve :: proc "contextless" () -> (port: wide_grants.Space_Window_Port, paid: u32) {
	memory, created := system.memory_create(wide_grants.SPACE_CAPACITY * wide_grants.SPACE_WINDOW_PAGES, 0, {.Uncommitted})
	if created != .Ok {
		return {}, 0
	}
	address, mapped := system.memory_map(memory, {.Write})
	if mapped != .Ok {
		system.close(memory)
		return {}, 0
	}
	space_windows = {memory = memory, base = ([^]u8)(address)}
	amounts, read := system.budget_read()
	if read == .Ok {
		paid = u32(min(amounts.pages / wide_grants.SPACE_WINDOW_PAGES, u64(wide_grants.SPACE_WINDOWS_STATED)))
	}
	return {user = &space_windows, take = space_window_commit, give = space_window_decommit}, paid
}

// space_window_range gives the pages of the window of a place.
@(private = "file")
space_window_range :: proc "contextless" (place: u32) -> [1]op.Page_Range {
	return {{first = u64(place) * wide_grants.SPACE_WINDOW_PAGES, page_count = wide_grants.SPACE_WINDOW_PAGES}}
}

// space_window_commit commits the window of a place from the budget; a
// page committed again is zero.
@(private = "file")
space_window_commit :: proc "contextless" (user: rawptr, place: u32) -> ^wide_grants.Space_Window {
	windows := (^Space_Windows)(user)
	if place >= wide_grants.SPACE_CAPACITY || windows.base == nil {
		return nil
	}
	ranges := space_window_range(place)
	if _, committed := system.memory_commit(windows.memory, ranges[:]); committed != .Ok {
		return nil
	}
	return (^wide_grants.Space_Window)(&windows.base[u64(place) * wide_grants.SPACE_WINDOW_PAGES * system.PAGE_SIZE])
}

// space_window_decommit returns the pages of the window of a place to the
// budget.
@(private = "file")
space_window_decommit :: proc "contextless" (user: rawptr, place: u32) {
	windows := (^Space_Windows)(user)
	if place >= wide_grants.SPACE_CAPACITY || windows.base == nil {
		return
	}
	ranges := space_window_range(place)
	_, _ = system.memory_decommit(windows.memory, ranges[:])
}
