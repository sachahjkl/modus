package root

// The growth of the budgets of a screen of memory (src/md/features/screen_of_memory.md,
// "The growth of the budgets"): one command of the service of the remote
// display makes one extra budget for the compositor and one for that
// service, both or neither, within the share of each process; a growth while
// one is held replaces it; each one ends when its process closes it, or at
// the stop of its process.

import "internal:root/screen_budgets"
import "modus:contract/call_outcome"
import "modus:contract/memory_screen"
import "modus:contract/ring"
import "modus:contract/root_ring"
import "modus:contract/value_kinds"
import "modus:display"
import "modus:system"

// The extra budgets that this service holds a handle of.
screen_budget_table: screen_budgets.Table
// The bound of the lines of refused grows and releases.
screen_budget_lines: screen_budgets.Line_Bound

// The time between two passes over the draining extra budgets: a process
// that released one closes its objects soon after, and the pages count
// against the share until then.
SCREEN_BUDGET_DRAIN_PASS_MILLISECONDS :: 100

// The gives of the growth in work: give_both calls these, which hold no
// context.
@(private = "file")
Grow_Gives :: struct {
	process:      [screen_budgets.Side]system.Handle,
	budget:       [screen_budgets.Side]system.Handle,
	given:        [screen_budgets.Side]system.Handle,
}
@(private = "file")
grow_gives: Grow_Gives

// The bytes of the Text field of the cause of a refused growth: the
// longest sentence of memory_screen.GROW_REFUSAL_SENTENCES, and a zero byte.
GROW_REFUSAL_FIELD_BYTES :: 96

// screen_budget_command runs Screen_Budget: the border of its words, then
// Grow or Release.
screen_budget_command :: proc "contextless" (item: ^Started, record: ring.Record, values: ^[7]u64) -> call_outcome.Call_Outcome {
	screen_budgets_drain()
	command := root_ring.Root_Command.Screen_Budget
	words, refused_place, words_ok := root_ring.screen_budget_words_of_values(record.values)
	if !words_ok {
		word := record.values[refused_place - 1]
		most := refused_place == 1 ? u64(max(root_ring.Screen_Budget_Step)) : 0
		values^ = root_ring.word_refusal(command, i64(refused_place), word, most)
		return .Argument_Refused
	}
	switch words.step {
	case .Release:
		if !screen_budget_release(.Service, words.growth, system.name_of(item.name[:])) {
			return root_ring.refuse(values, .Nothing_Has_That_Name, u32(command), .Absent, .Pages, 2, i64(min(words.growth, u64(max(i64)))))
		}
		return .Succeeded
	case .Grow:
		return screen_budget_grow(item, words.width, words.height, values)
	}
	return root_ring.refuse(values, .Argument_Refused, u32(command), .Bad_Value, .None, 1, i64(words.step))
}

// screen_budget_grow decides a growth for both processes together, makes
// the two extra budgets, gives each process its handle, and answers with the
// handle of the sender. A refusal makes nothing, and its record names the
// cause (memory_screen.Grow_Refusal).
@(private = "file")
screen_budget_grow :: proc "contextless" (item: ^Started, width, height: u64, values: ^[7]u64) -> call_outcome.Call_Outcome {
	compositor: ^Started
	for &other in started {
		if display_holder != 0 && other.process == display_holder {
			compositor = &other
		}
	}
	facts := memory_screen.Grow_Facts {
		from_service          = .Screen_Capture in item.start_grant_set.grants,
		screen_of_memory      = desktop_of_memory && compositor != nil,
		width                 = width,
		height                = height,
		max_width             = u64(root_plan_in_force.memory_screen_most_width),
		max_height            = u64(root_plan_in_force.memory_screen_most_height),
		share                 = u64(largest_budget.pages),
		now                   = system.time(),
		last_growth_at        = screen_budget_table.last_growth_at,
	}
	// The pages of each process: its budget at its start and the extra
	// budgets that it holds, which a replacement keeps until its new
	// pictures are made.
	compositor_extra_pages, service_extra_pages: u64
	facts.compositor_extras, compositor_extra_pages = screen_budgets.held(&screen_budget_table, .Compositor)
	facts.service_extras, service_extra_pages = screen_budgets.held(&screen_budget_table, .Service)
	facts.service_paid = pages_sum(item.budget_pages, service_extra_pages)
	if compositor != nil {
		facts.compositor_paid = pages_sum(compositor.budget_pages, compositor_extra_pages)
	}
	refusal, compositor_pages, service_pages := memory_screen.screen_budget_grow_decide(facts)
	// The compositor learns of its extra budget on the control ring before
	// the answer: with no room there, the growth is refused before any
	// budget is made.
	if refusal == .None && ring.capacity(&control.commands) == ring.count(&control.commands) {
		refusal = .No_Pages
	}
	compositor_budget, service_budget: system.Handle
	if refusal == .None {
		status: system.Status
		if compositor_budget, status = system.budget_create({pages = compositor_pages}); status != .Ok {
			compositor_budget = 0
			refusal = .No_Pages
		} else if service_budget, status = system.budget_create({pages = service_pages}); status != .Ok {
			service_budget = 0
			refusal = .No_Pages
		}
	}
	if refusal == .None {
		// The sender first: a refused give takes back each handle given,
		// so no process holds a budget that it never learns of.
		grow_gives = {process = {.Compositor = display_holder, .Service = item.process}, budget = {.Compositor = compositor_budget, .Service = service_budget}}
		if !screen_budgets.give_both(grow_give, grow_take_back) {
			refusal = .No_Pages
		}
	}
	given_compositor, given_service := grow_gives.given[.Compositor], grow_gives.given[.Service]
	growth: u64
	if refusal == .None {
		if growth = screen_budgets.grow_take(&screen_budget_table, u64(compositor_budget), compositor_pages, u64(service_budget), service_pages, facts.now); growth == 0 {
			// The decision read the table: only a number past the last one
			// is left, after 2^64 growths.
			refusal = .No_Pages
		}
	}
	if refusal == .None && !system.send(&control.commands, ring.Record{kind = u32(display.Control.Screen_Budget_Give), values = {0 = u64(given_compositor), 1 = compositor_pages, 2 = width, 3 = height, 4 = growth}}) {
		// The room was checked before; the table and the processes give the
		// growth back.
		screen_budgets.grow_undo(&screen_budget_table, growth)
		refusal = .No_Pages
	}
	if refusal != .None {
		for handle in ([2]system.Handle{compositor_budget, service_budget}) {
			if handle != 0 {
				// A handle that a process holds ends with this one.
				system.handle_revoke(handle)
				system.close(handle)
			}
		}
		if screen_budgets.line_allowed(&screen_budget_lines, facts.now) {
			system.log_fact(.Info, Screen_Budget_Refused{width = width, height = height, grow_refusal = text_field(memory_screen.GROW_REFUSAL_SENTENCES[refusal], GROW_REFUSAL_FIELD_BYTES)})
		}
		return root_ring.refuse(values, .Budget_Or_Capacity_Exhausted, u32(root_ring.Root_Command.Screen_Budget), .Refused, .Pages, 2, i64(width), 0, i64(refusal))
	}
	budget_pages_note()
	system.log_fact(.Info, Screen_Budget_Grown{width = width, height = height, growth = growth, compositor_pages = value_kinds.Size_In_Pages(compositor_pages), service_pages = value_kinds.Size_In_Pages(service_pages)})
	values^ = {0 = u64(given_service), 1 = service_pages, 2 = growth}
	return .Succeeded
}

// grow_give gives a process its extra budget, with Read and Spend.
@(private = "file")
grow_give :: proc "contextless" (side: screen_budgets.Side) -> bool {
	given, status := system.give(grow_gives.process[side], grow_gives.budget[side], {.Read, .Spend})
	if status != .Ok {
		return false
	}
	grow_gives.given[side] = given
	return true
}

// grow_take_back ends the handle that grow_give gave: the process holds it
// and never learns of it.
@(private = "file")
grow_take_back :: proc "contextless" (side: screen_budgets.Side) {
	system.handle_revoke(grow_gives.budget[side], grow_gives.process[side])
	grow_gives.given[side] = 0
}

// pages_sum adds two counts of pages, held at the largest count: a sum
// past it passes every share.
@(private = "file")
pages_sum :: proc "contextless" (a, b: u64) -> u64 {
	return a > max(u64) - b ? max(u64) : a + b
}

// screen_budget_release ends the extra budget of a growth that a process
// released. A release does not prove that the process closed its handle
// and its objects: this service takes back each handle of the budget in
// other processes, so no object comes from it any more, and keeps its own,
// with the pages counted against the share, until the budget drains.
// false: the process holds none of that growth.
screen_budget_release :: proc "contextless" (side: screen_budgets.Side, growth: u64, holder: string) -> bool {
	handle, held := screen_budgets.release(&screen_budget_table, side, growth)
	if !held {
		if screen_budgets.line_allowed(&screen_budget_lines, system.time()) {
			system.log_fact(.Warning, Screen_Budget_Release_Refused{growth = growth, holder = module_name_field(holder)})
		}
		return false
	}
	system.handle_revoke(system.Handle(handle))
	system.log_fact(.Info, Screen_Budget_Released{growth = growth, holder = module_name_field(holder)})
	screen_budgets_drain()
	return true
}

// screen_budgets_drain closes each released extra budget whose pages are
// all back: no object of it is left, and no process holds a handle of it,
// so the budget ends and its pages return to this service.
screen_budgets_drain :: proc "contextless" () {
	if !screen_budgets.draining(&screen_budget_table) {
		return
	}
	for side in screen_budgets.Side {
		for extra in screen_budget_table.extras[side] {
			if extra.handle == 0 || !extra.draining {
				continue
			}
			amounts, status := system.budget_read(system.Handle(extra.handle))
			if status == .Ok && screen_budgets.drained(&screen_budget_table, extra.handle, amounts.pages) {
				system.close(system.Handle(extra.handle))
				budget_pages_note()
			}
		}
	}
}

// screen_budgets_drain_wake gives the time of the next pass over the
// draining extra budgets, or WAIT_FOREVER with none.
screen_budgets_drain_wake :: proc "contextless" () -> u64 {
	if !screen_budgets.draining(&screen_budget_table) {
		return system.WAIT_FOREVER
	}
	return system.time() + SCREEN_BUDGET_DRAIN_PASS_MILLISECONDS
}

// screen_budget_stopped ends each extra budget of a process that stopped,
// also in the middle of a replacement.
screen_budget_stopped :: proc "contextless" (side: screen_budgets.Side, holder: string) {
	for handle in screen_budgets.stop(&screen_budget_table, side) {
		if handle != 0 {
			system.close(system.Handle(handle))
			budget_pages_note()
			system.log_fact(.Info, Screen_Budget_Ended_At_Stop{holder = module_name_field(holder)})
		}
	}
}
