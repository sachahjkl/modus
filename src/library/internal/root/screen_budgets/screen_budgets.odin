// The extra budgets of a screen of memory that the root service holds: one
// for the compositor and one for the service of the remote display, made
// together by a growth and ended one by one (src/md/features/screen_of_memory.md,
// "The growth of the budgets"). A pure part, which the host tests: the
// handles are the words of the root service, and the table gives back the
// handle that the root service closes.
package screen_budgets

// The process of an extra budget.
Side :: enum u8 {
	Compositor = 0,
	Service    = 1, // The service of the remote display.
}

// One extra budget: the handle that the root service keeps, and its pages.
// A handle of 0 is no extra budget.
Extra :: struct {
	handle: u64,
	pages:  u64,
}

Table :: struct {
	extras: [Side]Extra,
}

// open says if a process holds an extra budget.
open :: proc "contextless" (table: ^Table, side: Side) -> bool {
	return table.extras[side].handle != 0
}

// grow_take keeps the two extra budgets of a growth: both, or neither when
// either process holds one already, or a handle is 0. false: nothing
// changed, and the root service closes the two handles that it made.
grow_take :: proc "contextless" (table: ^Table, compositor, service: Extra) -> bool {
	if open(table, .Compositor) || open(table, .Service) || compositor.handle == 0 || service.handle == 0 || compositor.handle == service.handle {
		return false
	}
	table.extras[.Compositor] = compositor
	table.extras[.Service] = service
	return true
}

// release ends the extra budget of a process that closed its own handle:
// it gives the handle that the root service closes, or false when the
// process holds none, and nothing changes.
release :: proc "contextless" (table: ^Table, side: Side) -> (handle: u64, ok: bool) {
	if !open(table, side) {
		return 0, false
	}
	handle = table.extras[side].handle
	table.extras[side] = {}
	return handle, true
}

// stop ends the extra budget of a process that stopped: the stop closed
// its handle and its objects, and the root service closes the handle that
// this gives, so the pages return. 0: the process held none.
stop :: proc "contextless" (table: ^Table, side: Side) -> (handle: u64) {
	handle, _ = release(table, side)
	return
}
