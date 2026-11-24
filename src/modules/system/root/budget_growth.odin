package root

// Budget_Grow on the root ring (src/md/features/module_budget_request.md,
// "The growth is a second budget"): a process with a growth row in the plan
// asks for a second budget handle up to its ceiling, rate-limited per
// process, optionally served from its own growth reserve before the shared
// free pool, drained on release and closed when the process stops.

import "internal:root/budget_growth"
import "modus:contract/call_outcome"
import "modus:contract/ring"
import "modus:contract/root_ring"
import "modus:contract/value_kinds"
import "modus:system"

// Extra budgets created through Budget_Grow that this service tracks.
budget_growth_table: budget_growth.Table
// Rate limit on refusal log lines.
budget_growth_lines: budget_growth.Line_Bound

// Interval between drain passes over released extra budgets, matching
// SCREEN_BUDGET_DRAIN_PASS_MILLISECONDS.
BUDGET_GROWTH_DRAIN_PASS_MILLISECONDS :: 100

// Bytes of the refusal cause text field: covers the longest sentence of
// budget_growth.GROW_REFUSAL_SENTENCES plus a zero byte.
BUDGET_GROW_REFUSAL_FIELD_BYTES :: 96

// budget_grow_command runs Root_Command.Budget_Grow: checks the word border,
// then executes Grow or Release.
budget_grow_command :: proc "contextless" (item: ^Started, record: ring.Record, values: ^[7]u64) -> call_outcome.Call_Outcome {
	budget_growth_drain()
	command := root_ring.Root_Command.Budget_Grow
	words, refused_place, words_ok := root_ring.budget_grow_words_of_values(record.values)
	if !words_ok {
		word := record.values[refused_place - 1]
		most := refused_place == 1 ? u64(max(root_ring.Budget_Grow_Step)) : 0
		values^ = root_ring.word_refusal(command, i64(refused_place), word, most)
		return .Argument_Refused
	}
	switch words.step {
	case .Release:
		return budget_grow_release(item, words.growth, values)
	case .Grow:
		return budget_grow_request(item, words.pages, values)
	}
	return root_ring.refuse(values, .Argument_Refused, u32(command), .Bad_Value, .None, 1, i64(words.step))
}

// growth_reserves_reserved_for_others sums the unspent growth reserves of
// every other running process of the boot image, so one process never draws
// from another process's growth reserve.
@(private = "file")
growth_reserves_reserved_for_others :: proc "contextless" (caller: ^Started) -> (reserved: u64) {
	for &other in started {
		if other.process == 0 || &other == caller || other.from_disk {
			continue
		}
		policy, _, _ := module_budget_policy_for(system.name_of(other.name[:]))
		if !policy.has_growth_reserve || policy.growth_reserve_pages == 0 {
			continue
		}
		_, _, used := budget_growth.held_by(&budget_growth_table, u64(other.process))
		if policy.growth_reserve_pages > used {
			left := policy.growth_reserve_pages - used
			reserved = reserved > max(u64) - left ? max(u64) : reserved + left
		}
	}
	return reserved
}

// budget_grow_request decides one Grow request. A process with no growth row
// (including any disk process) is refused at the border before reading the
// starter's free pages.
@(private = "file")
budget_grow_request :: proc "contextless" (item: ^Started, asked_pages: u64, values: ^[7]u64) -> call_outcome.Call_Outcome {
	command := u32(root_ring.Root_Command.Budget_Grow)
	name := system.name_of(item.name[:])
	owner := u64(item.process)
	now := system.time()

	ceiling_pages: u64
	growth_reserve_pages: u64
	if !item.from_disk {
		policy, _, _ := module_budget_policy_for(name)
		if policy.has_ceiling {
			ceiling_pages = policy.ceiling_pages
		}
		if policy.has_growth_reserve {
			growth_reserve_pages = policy.growth_reserve_pages
		}
	}

	// Refuse at border before touching starter pages when no growth row exists.
	if ceiling_pages == 0 {
		if budget_growth.line_allowed(&budget_growth_lines, now) {
			system.log_fact(.Info, Budget_Grow_Refused{pages = value_kinds.Size_In_Pages(min(asked_pages, u64(max(i64)))), requester = module_name_field(name), grow_refusal = text_field(budget_growth.GROW_REFUSAL_SENTENCES[.No_Row], BUDGET_GROW_REFUSAL_FIELD_BYTES)})
		}
		return root_ring.refuse(values, .Grant_Or_Right_Missing, command, .No_Grant, .Pages, 2, 0, 0, i64(budget_growth.Grow_Refusal.No_Row))
	}

	held_count, extra_pages, reserve_used := budget_growth.held_by(&budget_growth_table, owner)
	last_at, has_last := budget_growth.last_decision(&budget_growth_table, owner)
	own, _ := system.budget_read()
	reserved_start := start_list_reserved_all()
	reserved_other := growth_reserves_reserved_for_others(item)
	reserved_total := reserved_start > max(u64) - reserved_other ? max(u64) : reserved_start + reserved_other
	shared_pool := own.pages > reserved_total ? own.pages - reserved_total : 0

	paid := item.budget_pages > max(u64) - extra_pages ? max(u64) : item.budget_pages + extra_pages
	facts := budget_growth.Grow_Facts {
		ceiling_pages        = ceiling_pages,
		growth_reserve_pages = growth_reserve_pages,
		asked_pages          = asked_pages,
		paid_pages           = paid,
		reserve_used_pages   = reserve_used,
		extras_held          = held_count,
		table_used           = budget_growth.table_used(&budget_growth_table),
		now                  = now,
		last_decision_at     = last_at,
		has_last_decision    = has_last,
		period_ms            = root_plan_in_force.budget_growth_period_ms,
		shared_pool_pages    = shared_pool,
	}
	refusal, from_reserve, _, counts_as_decision := budget_growth.decide(facts)
	if counts_as_decision {
		budget_growth.note_decision(&budget_growth_table, owner, now)
	}

	extra_budget: system.Handle
	given_budget: system.Handle
	growth: u64
	if refusal == .None {
		status: system.Status
		extra_budget, status = system.budget_create({pages = asked_pages})
		if status != .Ok {
			extra_budget = 0
			refusal = .No_Pages
		}
	}
	if refusal == .None {
		status: system.Status
		given_budget, status = system.give(item.process, extra_budget, {.Read, .Spend})
		if status != .Ok {
			refusal = .No_Pages
		}
	}
	if refusal == .None {
		growth = budget_growth.grow_take(&budget_growth_table, owner, u64(extra_budget), asked_pages, from_reserve, now)
		if growth == 0 {
			refusal = .Full
		}
	}
	if refusal != .None {
		if extra_budget != 0 {
			system.handle_revoke(extra_budget)
			system.close(extra_budget)
		}
		if budget_growth.line_allowed(&budget_growth_lines, now) {
			system.log_fact(.Info, Budget_Grow_Refused{pages = value_kinds.Size_In_Pages(min(asked_pages, u64(max(i64)))), requester = module_name_field(name), grow_refusal = text_field(budget_growth.GROW_REFUSAL_SENTENCES[refusal], BUDGET_GROW_REFUSAL_FIELD_BYTES)})
		}
		outcome: call_outcome.Call_Outcome
		switch refusal {
		case .None:
			outcome = .Budget_Or_Capacity_Exhausted
		case .No_Row:
			outcome = .Grant_Or_Right_Missing
		case .Bad_Pages:
			outcome = .Argument_Refused
		case .Too_Soon:
			outcome = .Callee_Busy
		case .Over_Ceiling, .Full, .No_Pages:
			outcome = .Budget_Or_Capacity_Exhausted
		}
		// Never include any free-page count in the refusal record.
		return root_ring.refuse(values, outcome, command, .Refused, .Pages, 2, 0, 0, i64(refusal))
	}

	budget_pages_note()
	system.log_fact(.Info, Budget_Grow_Granted{pages = value_kinds.Size_In_Pages(min(asked_pages, u64(max(i64)))), growth = growth, requester = module_name_field(name)})
	values^ = {0 = u64(given_budget), 1 = asked_pages, 2 = growth}
	return .Succeeded
}

// budget_grow_release marks an extra budget of item as draining and revokes
// the caller's handle. Its pages return once no object of it remains.
@(private = "file")
budget_grow_release :: proc "contextless" (item: ^Started, growth: u64, values: ^[7]u64) -> call_outcome.Call_Outcome {
	command := u32(root_ring.Root_Command.Budget_Grow)
	name := system.name_of(item.name[:])
	handle, held := budget_growth.release(&budget_growth_table, u64(item.process), growth)
	if !held {
		if budget_growth.line_allowed(&budget_growth_lines, system.time()) {
			system.log_fact(.Warning, Budget_Grow_Release_Refused{growth = growth, holder = module_name_field(name)})
		}
		return root_ring.refuse(values, .Nothing_Has_That_Name, command, .Absent, .Pages, 2, i64(min(growth, u64(max(i64)))))
	}
	system.handle_revoke(system.Handle(handle))
	system.log_fact(.Info, Budget_Grow_Released{growth = growth, holder = module_name_field(name)})
	budget_growth_drain()
	return .Succeeded
}

// budget_growth_drain closes each released extra budget whose pages have all
// returned to it.
budget_growth_drain :: proc "contextless" () {
	if !budget_growth.draining(&budget_growth_table) {
		return
	}
	for extra in budget_growth_table.extras {
		if extra.handle == 0 || !extra.draining {
			continue
		}
		amounts, status := system.budget_read(system.Handle(extra.handle))
		if status == .Ok && budget_growth.drained(&budget_growth_table, extra.handle, amounts.pages) {
			system.close(system.Handle(extra.handle))
			budget_pages_note()
		}
	}
}

// budget_growth_drain_wake gives the next drain pass deadline, or
// WAIT_FOREVER when no extra budget is draining.
budget_growth_drain_wake :: proc "contextless" () -> u64 {
	if !budget_growth.draining(&budget_growth_table) {
		return system.WAIT_FOREVER
	}
	return system.time() + BUDGET_GROWTH_DRAIN_PASS_MILLISECONDS
}

// budget_growth_stopped closes every extra budget held by a stopped process.
budget_growth_stopped :: proc "contextless" (item: ^Started) {
	if item.process == 0 {
		return
	}
	handles, count := budget_growth.stop(&budget_growth_table, u64(item.process))
	if count == 0 {
		return
	}
	for handle in handles[:count] {
		if handle != 0 {
			system.close(system.Handle(handle))
		}
	}
	budget_pages_note()
	system.log_fact(.Info, Budget_Grow_Ended_At_Stop{count = u64(count), holder = module_name_field(system.name_of(item.name[:]))})
}
