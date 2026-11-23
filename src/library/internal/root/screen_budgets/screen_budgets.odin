// The extra budgets of a screen of memory that the root service holds: for
// the compositor and for the service of the remote display, made together
// by a growth and ended one by one (src/md/features/screen_of_memory.md,
// "The growth of the budgets"). A process has at most two places: the
// extra budget of the size in force, and the one of the size that replaces
// it. A released extra budget keeps its place, and its pages count against
// the share, until it drains: a release does not prove that the process
// closed its handle and its objects. A pure part, which the host tests: the
// handles are the words of the root service.
package screen_budgets

import "modus:contract/memory_screen"

// The process of an extra budget.
Side :: enum u8 {
	Compositor = 0,
	Service    = 1, // The service of the remote display.
}

// One extra budget: the handle that the root service keeps, its pages, the
// number of its growth, which names it in a release, and whether its
// process released it. A handle of 0 is no extra budget.
Extra :: struct {
	handle:   u64,
	pages:    u64,
	growth:   u64,
	draining: bool, // Released: the root service took back the handle of the process, and waits until no object of the budget is left.
}

Table :: struct {
	extras:         [Side][memory_screen.EXTRAS_PER_PROCESS]Extra,
	last_growth:    u64, // The number of the last growth: the next one is past it, and 0 is none.
	last_growth_at: u64, // The time of the last growth, in milliseconds of the clock of the system; 0: none.
}

// held gives the count of the places of a process that an extra budget
// holds, draining or not, and their pages: both count until the budget
// drains.
held :: proc "contextless" (table: ^Table, side: Side) -> (count: int, pages: u64) {
	for extra in table.extras[side] {
		if extra.handle != 0 {
			count += 1
			pages = pages > max(u64) - extra.pages ? max(u64) : pages + extra.pages
		}
	}
	return
}

// draining says if an extra budget of either process waits to drain.
draining :: proc "contextless" (table: ^Table) -> bool {
	for side in Side {
		for extra in table.extras[side] {
			if extra.handle != 0 && extra.draining {
				return true
			}
		}
	}
	return false
}

// grow_take keeps the two new extra budgets of a growth made at now, and
// gives the number of the growth: both, or neither when either process has
// no free place, a handle is 0, or one handle is given twice. 0: nothing
// changed, and the root service closes the two handles that it made.
grow_take :: proc "contextless" (table: ^Table, compositor_handle, compositor_pages, service_handle, service_pages, now: u64) -> (growth: u64) {
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
	table.last_growth_at = now
	growth = table.last_growth
	table.extras[.Compositor][compositor_place] = {compositor_handle, compositor_pages, growth, false}
	table.extras[.Service][service_place] = {service_handle, service_pages, growth, false}
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

// grow_undo takes back the two extra budgets of a growth that did not reach
// the compositor: its places free, and nothing drains. false: no extra
// budget of that growth.
grow_undo :: proc "contextless" (table: ^Table, growth: u64) -> bool {
	found := false
	for side in Side {
		for &extra in table.extras[side] {
			if growth != 0 && extra.handle != 0 && extra.growth == growth && !extra.draining {
				extra = {}
				found = true
			}
		}
	}
	return found
}

// release marks the extra budget of a growth of a process as draining, and
// gives its handle: the root service takes back the handle of the process,
// then closes its own when the budget drains. false: the process holds none
// of that growth, or released it already; nothing changes.
release :: proc "contextless" (table: ^Table, side: Side, growth: u64) -> (handle: u64, ok: bool) {
	if growth == 0 {
		return 0, false
	}
	for &extra in table.extras[side] {
		if extra.handle != 0 && extra.growth == growth && !extra.draining {
			extra.draining = true
			return extra.handle, true
		}
	}
	return 0, false
}

// drained ends a draining extra budget whose pages are all back: it frees
// its place, and gives the handle that the root service closes. pages_left
// is what the budget can still pay. false: the budget still pays objects,
// or no draining extra budget has that handle; nothing changes.
drained :: proc "contextless" (table: ^Table, handle, pages_left: u64) -> bool {
	for side in Side {
		for &extra in table.extras[side] {
			if extra.handle == handle && handle != 0 && extra.draining {
				if pages_left < extra.pages {
					return false
				}
				extra = {}
				return true
			}
		}
	}
	return false
}

// stop ends each extra budget of a process that stopped, draining or not:
// the stop closed its handles and its objects, and the root service closes
// the handles that this gives, so the pages return. A handle of 0 is no
// extra budget.
stop :: proc "contextless" (table: ^Table, side: Side) -> (handles: [memory_screen.EXTRAS_PER_PROCESS]u64) {
	for &extra, place in table.extras[side] {
		handles[place] = extra.handle
		extra = {}
	}
	return
}

// The two processes in the order of the gives of a growth: the sender
// first, so a refused give leaves no handle in a process that would not
// learn of it, and a refused second give takes back the first.
GIVE_ORDER :: [2]Side{.Service, .Compositor}

// The give of the handle of a side to its process, and the take-back of a
// handle that it gave.
Give_Procedure :: #type proc "contextless" (side: Side) -> bool
Take_Back_Procedure :: #type proc "contextless" (side: Side)

// give_both gives each process its handle, in GIVE_ORDER: both, or
// neither, as each give that passed is taken back when a later one fails.
give_both :: proc "contextless" (give: Give_Procedure, take_back: Take_Back_Procedure) -> bool {
	order := GIVE_ORDER
	for side, place in order {
		if !give(side) {
			for given in order[:place] {
				take_back(given)
			}
			return false
		}
	}
	return true
}

// The lines of refused commands of the budgets that the root service writes
// in one second: a sender that sends in a loop cannot fill the log.
REFUSED_LINES_PER_SECOND :: 4

// The lines written in the second in force.
Line_Bound :: struct {
	second: u64,
	count:  u64,
}

// line_allowed says if a refusal at now (milliseconds) writes its line.
line_allowed :: proc "contextless" (bound: ^Line_Bound, now: u64) -> bool {
	second := now / 1000
	if second != bound.second {
		bound.second, bound.count = second, 0
	}
	if bound.count >= REFUSED_LINES_PER_SECOND {
		return false
	}
	bound.count += 1
	return true
}
