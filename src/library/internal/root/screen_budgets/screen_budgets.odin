// The extra budgets of a screen of memory that the root service holds: for
// the compositor and for the service of the remote display, made together
// by a growth and ended one by one (src/md/features/screen_of_memory.md,
// "The growth of the budgets"). A process holds at most two: the one of the
// size in force, and the one of the size that replaces it. A pure part,
// which the host tests: the handles are the words of the root service, and
// the table gives back the handles that the root service closes.
package screen_budgets

import "modus:contract/memory_screen"

// The process of an extra budget.
Side :: enum u8 {
	Compositor = 0,
	Service    = 1, // The service of the remote display.
}

// One extra budget: the handle that the root service keeps, its pages, and
// the number of its growth, which names it in a release. A handle of 0 is
// no extra budget.
Extra :: struct {
	handle: u64,
	pages:  u64,
	growth: u64,
}

Table :: struct {
	extras:      [Side][memory_screen.EXTRAS_PER_PROCESS]Extra,
	last_growth: u64, // The number of the last growth: the next one is past it, and 0 is none.
}

// held gives the count of the extra budgets of a process, and their pages.
held :: proc "contextless" (table: ^Table, side: Side) -> (count: int, pages: u64) {
	for extra in table.extras[side] {
		if extra.handle != 0 {
			count += 1
			pages += extra.pages
		}
	}
	return
}

// grow_take keeps the two new extra budgets of a growth and gives the
// number of the growth: both, or neither when either process holds two
// already, a handle is 0, or one handle is given twice. 0: nothing changed,
// and the root service closes the two handles that it made.
grow_take :: proc "contextless" (table: ^Table, compositor_handle, compositor_pages, service_handle, service_pages: u64) -> (growth: u64) {
	if compositor_handle == 0 || service_handle == 0 || compositor_handle == service_handle || table.last_growth == max(u64) {
		return 0
	}
	compositor_place, compositor_free := free_place(table, .Compositor)
	service_place, service_free := free_place(table, .Service)
	if !compositor_free || !service_free {
		return 0
	}
	for side in Side {
		for extra in table.extras[side] {
			if extra.handle != 0 && (extra.handle == compositor_handle || extra.handle == service_handle) {
				return 0
			}
		}
	}
	table.last_growth += 1
	growth = table.last_growth
	table.extras[.Compositor][compositor_place] = {compositor_handle, compositor_pages, growth}
	table.extras[.Service][service_place] = {service_handle, service_pages, growth}
	return growth
}

@(private = "file")
free_place :: proc "contextless" (table: ^Table, side: Side) -> (place: int, ok: bool) {
	for extra, index in table.extras[side] {
		if extra.handle == 0 {
			return index, true
		}
	}
	return 0, false
}

// release ends the extra budget of a growth of a process that closed its
// own handle: it gives the handle that the root service closes, or false
// when the process holds none of that growth, and nothing changes.
release :: proc "contextless" (table: ^Table, side: Side, growth: u64) -> (handle: u64, ok: bool) {
	if growth == 0 {
		return 0, false
	}
	for &extra in table.extras[side] {
		if extra.handle != 0 && extra.growth == growth {
			handle = extra.handle
			extra = {}
			return handle, true
		}
	}
	return 0, false
}

// stop ends each extra budget of a process that stopped, also in the
// middle of a replacement: the stop closed its handles and its objects, and
// the root service closes the handles that this gives, so the pages return.
// A handle of 0 is no extra budget.
stop :: proc "contextless" (table: ^Table, side: Side) -> (handles: [memory_screen.EXTRAS_PER_PROCESS]u64) {
	for &extra, place in table.extras[side] {
		handles[place] = extra.handle
		extra = {}
	}
	return
}
