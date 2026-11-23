package root

// The growth of the budgets of a screen of memory (src/md/features/screen_of_memory.md,
// "The growth of the budgets"): one command of the service of the remote
// display makes one extra budget for the compositor and one for that
// service, both or neither, within the share of each process; each one ends
// when its process closes it, or at the stop of its process.

import "internal:root/screen_budgets"
import "modus:contract/errors"
import "modus:contract/memory_screen"
import "modus:contract/ring"
import "modus:contract/root_ring"
import "modus:contract/value_kinds"
import "modus:display"
import "modus:system"

// The extra budgets that this service holds a handle of.
screen_budget_table: screen_budgets.Table

// The bytes of the Text field of the cause of a refused growth: the
// longest sentence of memory_screen.GROW_REFUSAL_SENTENCES, and a zero byte.
GROW_REFUSAL_FIELD_BYTES :: 96

// screen_budget_command runs Screen_Budget: the border of its words, then
// Grow or Release.
screen_budget_command :: proc "contextless" (item: ^Started, record: ring.Record, values: ^[7]u64) -> system.Status {
	command := root_ring.Root_Command.Screen_Budget
	step, step_ok := root_ring.screen_budget_step_of_word(record.values[0])
	if !step_ok {
		values^ = root_ring.word_refusal(command, 1, record.values[0], u64(max(root_ring.Screen_Budget_Step)))
		return .Bad_Operation
	}
	// The words after the size are 0: a word that names nothing is refused.
	first_free := step == .Grow ? 3 : 1
	for place in first_free ..< len(record.values) {
		if record.values[place] != 0 {
			values^ = root_ring.word_refusal(command, i64(place + 1), record.values[place], 0)
			return .Bad_Operation
		}
	}
	switch step {
	case .Release:
		if !screen_budget_release(.Service, system.name_of(item.name[:])) {
			values^ = errors.ring_fail(u32(command), .Absent, .Pages, 1, i64(step))
			return .Bad_State
		}
		return .Ok
	case .Grow:
		return screen_budget_grow(item, record.values[1], record.values[2], values)
	}
	return .Bad_Operation
}

// screen_budget_grow decides a growth for both processes together, makes
// the two extra budgets, gives each process its handle, and answers with the
// handle of the sender. A refusal makes nothing, and its record names the
// cause (memory_screen.Grow_Refusal).
@(private = "file")
screen_budget_grow :: proc "contextless" (item: ^Started, width, height: u64, values: ^[7]u64) -> system.Status {
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
		compositor_extra_open = screen_budgets.open(&screen_budget_table, .Compositor),
		service_extra_open    = screen_budgets.open(&screen_budget_table, .Service),
		service_paid          = item.budget_pages,
		share                 = u64(largest_budget.pages),
	}
	if compositor != nil {
		facts.compositor_paid = compositor.budget_pages
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
	given_compositor, given_service: system.Handle
	if refusal == .None {
		compositor_status, service_status: system.Status
		given_compositor, compositor_status = system.give(display_holder, compositor_budget, {.Read, .Spend})
		if compositor_status == .Ok {
			given_service, service_status = system.give(item.process, service_budget, {.Read, .Spend})
		}
		if compositor_status != .Ok || service_status != .Ok {
			// A handle given to the compositor alone holds its budget until
			// the compositor stops; it never learns of it, and makes nothing
			// from it. The give fails only on a full handle table.
			refusal = .No_Pages
		}
	}
	if refusal == .None && !system.send(&control.commands, ring.Record{kind = u32(display.Control.Screen_Budget_Give), values = {0 = u64(given_compositor), 1 = compositor_pages, 2 = width, 3 = height}}) {
		refusal = .No_Pages
	}
	if refusal == .None && !screen_budgets.grow_take(&screen_budget_table, {u64(compositor_budget), compositor_pages}, {u64(service_budget), service_pages}) {
		refusal = .Extra_Open
	}
	if refusal != .None {
		for handle in ([2]system.Handle{compositor_budget, service_budget}) {
			if handle != 0 {
				system.close(handle)
			}
		}
		system.log_fact(.Info, Screen_Budget_Refused{width = width, height = height, grow_refusal = text_field(memory_screen.GROW_REFUSAL_SENTENCES[refusal], GROW_REFUSAL_FIELD_BYTES)})
		values^ = errors.ring_fail(u32(root_ring.Root_Command.Screen_Budget), .Refused, .Pages, 2, i64(width), 0, i64(refusal))
		return .No_Budget
	}
	budget_pages_note()
	system.log_fact(.Info, Screen_Budget_Grown{width = width, height = height, compositor_pages = value_kinds.Size_In_Pages(compositor_pages), service_pages = value_kinds.Size_In_Pages(service_pages)})
	values^ = {0 = u64(given_service), 1 = service_pages}
	return .Ok
}

// screen_budget_release ends the extra budget of a process that closed its
// handle: this service closes its own, and the pages return when the
// budget ends. false: the process holds none.
screen_budget_release :: proc "contextless" (side: screen_budgets.Side, holder: string) -> bool {
	handle, held := screen_budgets.release(&screen_budget_table, side)
	if !held {
		system.log_fact(.Warning, Screen_Budget_Release_Refused{holder = module_name_field(holder)})
		return false
	}
	system.close(system.Handle(handle))
	budget_pages_note()
	system.log_fact(.Info, Screen_Budget_Released{holder = module_name_field(holder)})
	return true
}

// screen_budget_stopped ends the extra budget of a process that stopped.
screen_budget_stopped :: proc "contextless" (side: screen_budgets.Side, holder: string) {
	if handle := screen_budgets.stop(&screen_budget_table, side); handle != 0 {
		system.close(system.Handle(handle))
		budget_pages_note()
		system.log_fact(.Info, Screen_Budget_Ended_At_Stop{holder = module_name_field(holder)})
	}
}
