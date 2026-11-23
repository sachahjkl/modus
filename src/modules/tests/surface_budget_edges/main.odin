// The machine case of the budget of a surface
// (src/md/features/window_resize.md, "The compositor makes each surface").
// It speaks the ring of its window itself, so it can give the compositor
// each budget that the display package never gives, and checks each
// answer:
//
//   1. a budget one page short of the surface: Create_Refused;
//   2. a copy that the window revoked before it sent the record:
//      Create_Refused;
//   3. a budget handle with Read and no Spend: Create_Refused;
//   4. a budget whose own handle the window closed before the record: the
//      copy of the compositor holds it, and the answer Create_Taken names
//      the surface that the compositor made, with Read and Write; the
//      window draws and presents it, and a revocation of the window ends
//      no holding of the compositor.
//
// **Start**: `start("surface_budget_edges")` in the console. **What a
// reader sees**: a small window with one colour; one line
// "surface_budget_edges: ..." , or a line "surface_budget_edges: WRONG: ...".
package surface_budget_edges

import "modus:contract/ring"
import "modus:contract/scale_factor"
import "modus:display"
import "modus:graphics"
import "modus:system"

WIDTH :: 100
HEIGHT :: 100

// The window and the budgets of the surfaces that it gives.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 64, window_width = WIDTH, window_height = HEIGHT}

window_ring: ring.Ring
ring_memory: system.Handle

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	ring_memory = ctx.handles[system.GRANT_DISPLAY]
	opened, status := system.ring_open(ring_memory, receive_handles = true)
	if ring_memory == 0 || status != .Ok {
		wrong("the ring of the window does not open; the status word", u64(status))
	}
	window_ring = opened
	scale := scale_factor.DEFAULT
	screen_width, screen_height := display.surface_size_of(WIDTH, HEIGHT, scale)
	pages := display.surface_budget_pages(u64(screen_width), u64(screen_height))
	if pages < 2 {
		wrong("the surface of the case has no pages", pages)
	}

	// 1. A budget one page short of the surface.
	short := budget_make(pages - 1)
	expect_refused("a budget one page short", give(short, {.Spend, .Read}), scale)
	system.close(short)
	// 2. A copy that the window revoked before the record.
	revoked := budget_make(pages)
	revoked_copy := give(revoked, {.Spend, .Read})
	system.handle_revoke(revoked)
	system.close(revoked)
	expect_refused("a copy that the window revoked", revoked_copy, scale)
	// 3. Read and no Spend.
	no_spend := budget_make(pages)
	expect_refused("a budget handle with no Spend", give(no_spend, {.Read}), scale)
	system.close(no_spend)
	system.log_fact(.Info, Budgets_Refused{})

	// 4. The window closes its own handle: the copy of the compositor holds
	// the budget, and the compositor makes the surface.
	budget := budget_make(pages)
	copy_of_compositor := give(budget, {.Spend, .Read})
	system.close(budget)
	create_send(copy_of_compositor, scale)
	kind, memory := answer_wait()
	if kind != .Create_Taken {
		wrong("the surface of a whole budget was refused; the answer word", u64(kind))
	}
	memory_kind, rights, through := system.handle_state(memory, ring_memory)
	if !through || memory_kind != .Memory || rights & {.Read, .Write} != {.Read, .Write} {
		wrong("the surface that the compositor gave is no memory with Read and Write through the ring; the kind word", u64(memory_kind))
	}
	address, map_status := system.memory_map(memory, {.Write})
	if map_status != .Ok {
		wrong("the surface that the compositor gave does not map; the status word", u64(map_status))
	}
	picture := graphics.Canvas{pixels = ([^]graphics.Color)(address), width = screen_width, height = screen_height, stride = screen_width}
	graphics.fill(picture, 0, 0, screen_width, screen_height, graphics.colors.card_top)
	present := ring.Record{kind = u32(display.Command.Present), values = {display.PRESENT_SURFACE_SERIAL = 1}}
	if !system.send(&window_ring.commands, present) {
		wrong("the ring of the window took no Present", 0)
	}
	// The compositor is the origin of the copy of the window: a revocation
	// of the window ends no holding of the compositor.
	if ended, revoke_status := system.handle_revoke(memory); revoke_status != .Ok || ended != 0 {
		wrong("the revocation of the window ended holdings of its surface; the count", ended)
	}
	system.log_fact(.Info, Surface_Made_By_The_Compositor{width = u64(screen_width), height = u64(screen_height)})
	// The measure of the end of a budget: the compositor closes the last
	// handle of the budget of a surface right after it made the surface, on
	// its interface thread, and the kernel then walks the tables of the
	// objects, the processes, the threads and the budgets (budget_release).
	// The same close here: a budget that pays one object of the surface.
	// A measure, with no bound.
	measured := budget_make(pages)
	picture_pages := (u64(screen_width * screen_height * size_of(graphics.Color) * display.PICTURE_COUNT) + system.PAGE_SIZE - 1) / system.PAGE_SIZE
	object, object_status := system.memory_create(picture_pages, measured)
	if object_status != .Ok {
		wrong("the object of the measure was not made; the status word", u64(object_status))
	}
	start := system.nanoseconds()
	system.close(measured)
	spent := system.nanoseconds() - start
	system.close(object)
	system.log_fact(.Info, Budget_End_Measured{nanoseconds = spent})
	// The window stays, so the scenario sees its surface; it waits until
	// the scenario stops it, and at the hang bound it stops with a WRONG line.
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	for system.time() < deadline {
		for _ in system.receive(&window_ring.completions) {
		}
		wait := system.wait_begin()
		system.wait_records(&wait, &window_ring.completions)
		system.wait_end(&wait, deadline)
	}
	wrong("the scenario did not stop this process within the hang bound; the milliseconds", system.TEST_HANG_BOUND_MILLISECONDS)
}

@(private = "file")
budget_make :: proc "contextless" (pages: u64) -> system.Handle {
	budget, status := system.budget_create({pages = pages})
	if status != .Ok {
		wrong("a budget of the case was not made; the status word", u64(status))
	}
	return budget
}

// give gives a copy of a budget handle through the ring of the window.
@(private = "file")
give :: proc "contextless" (budget: system.Handle, rights: system.Rights) -> system.Handle {
	given, status := system.give(ring_memory, budget, rights)
	if status != .Ok {
		wrong("the budget did not go through the ring; the status word", u64(status))
	}
	return given
}

@(private = "file")
create_send :: proc "contextless" (given: system.Handle, scale: scale_factor.Scale) {
	name := system.name_pack("surface_budget_edges")
	record := ring.Record{kind = u32(display.Command.Surface_Create), values = {u64(given) | u64(scale) << display.SURFACE_CREATE_SCALE_SHIFT, WIDTH, HEIGHT, name[0], name[1], name[2], name[3]}}
	if !system.send(&window_ring.commands, record) {
		wrong("the ring of the window took no Surface_Create", 0)
	}
}

@(private = "file")
expect_refused :: proc "contextless" (what: string, given: system.Handle, scale: scale_factor.Scale) {
	create_send(given, scale)
	if kind, _ := answer_wait(); kind != .Create_Refused {
		system.log_fact(.Error, Wrong{value = u64(kind)}, what)
		system.stop(.Failed)
	}
}

// answer_wait waits for the answer of a Surface_Create, within the hang
// bound; the other events of the window are read and left.
@(private = "file")
answer_wait :: proc "contextless" () -> (kind: display.Surface_Answer_Kind, memory: system.Handle) {
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	for system.time() < deadline {
		for record in system.receive(&window_ring.completions) {
			event, ok := display.event_of_record(record)
			if ok && event.kind == .Surface_Answer && event.surface_serial == 1 {
				return event.surface_answer, event.surface_memory
			}
		}
		wait := system.wait_begin()
		system.wait_records(&wait, &window_ring.completions)
		system.wait_end(&wait, deadline)
	}
	wrong("no answer of Surface_Create came within the hang bound; the milliseconds", system.TEST_HANG_BOUND_MILLISECONDS)
}

@(private = "file")
wrong :: proc "contextless" (text: string, value: u64) -> ! {
	system.log_fact(.Error, Wrong{value = value}, text)
	system.stop(.Failed)
}
