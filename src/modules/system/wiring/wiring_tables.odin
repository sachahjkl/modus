// The tables of the wiring service (src/md/features/module_outputs.md, "The
// bounds of the wirings"): no count of them is fixed. Each table grows in an
// arena of the budget of the service, never moves, and the tables beside it
// grow with it, so an index of a process or of a wiring names one entry of
// each.
package wiring

import "base:intrinsics"
import "internal:wiring/wiring_core"
import "modus:system"

Wiring_Tables :: struct {
	processes:      system.Arena,
	handles:        system.Arena,
	wirings:        system.Arena,
	end_memory:     system.Arena,
	ring_memory:    system.Arena,
	ring_capacity:  system.Arena,
	actions:        system.Arena,
	process_count:  int,
	wiring_count:   int,
}

wiring_tables: Wiring_Tables

// wiring_tables_reserve reserves the arenas from the budget that the
// service holds at its start, and gives the port of the tables. A
// reservation that the kernel refuses gives a port that grows nothing, so
// each registration is refused with its cause.
wiring_tables_reserve :: proc "contextless" () -> wiring_core.Wiring_Tables_Port {
	amounts, read := system.budget_read()
	if read != .Succeeded || amounts.pages == 0 {
		return {}
	}
	pages := system.arena_reservation_pages(amounts.pages)
	arenas := [?]^system.Arena{&wiring_tables.processes, &wiring_tables.handles, &wiring_tables.wirings, &wiring_tables.end_memory, &wiring_tables.ring_memory, &wiring_tables.ring_capacity, &wiring_tables.actions}
	for arena in arenas {
		made, status := system.arena_create(pages)
		if status != .Succeeded {
			return {}
		}
		// Exact commits keep each of the seven small tables to one page per
		// growth instead of committing ARENA_GROWTH_STEP_FIRST_PAGES each.
		made.exact_commits = true
		arena^ = made
	}
	return {user = &wiring_tables, processes_grow = processes_grow, wirings_grow = wirings_grow}
}

// arena_extend pushes the entries of a table past its count, zeroed: the
// pushes of one arena follow one another, so the table stays whole.
@(private = "file")
arena_extend :: proc "contextless" (arena: ^system.Arena, $T: typeid, before, count: int) -> bool {
	if count <= before {
		return true
	}
	size := u64(count - before) * size_of(T)
	added, status := system.arena_push(arena, size, align_of(T))
	if status != .Succeeded {
		return false
	}
	intrinsics.mem_zero(added, int(size))
	return true
}

@(private = "file")
processes_grow :: proc "contextless" (user: rawptr, count: int) -> []wiring_core.Process_Entry {
	tables := (^Wiring_Tables)(user)
	if count > tables.process_count {
		// Each table of a process grows, or none counts the new entries.
		if !arena_extend(&tables.processes, wiring_core.Process_Entry, tables.process_count, count) {
			return nil
		}
		if !arena_extend(&tables.handles, Process_Handles, tables.process_count, count) {
			_ = system.arena_pop(&tables.processes, u64(count - tables.process_count) * size_of(wiring_core.Process_Entry))
			return nil
		}
		tables.process_count = count
		process_handles = ([^]Process_Handles)(tables.handles.base)[:count]
		// The wait of the loop holds the wiring ring of each process. A
		// growth that the budget does not pay keeps its places.
		_ = system.wait_set_grow(&wiring_wait, wiring_wait_words(count))
	}
	return ([^]wiring_core.Process_Entry)(tables.processes.base)[:tables.process_count]
}

// wirings_grow grows the tables of the wirings from the service's own budget
// (Memory_Commit requires the budget that created each arena), after verifying
// that the asker holds a wiring budget so an asker without one cannot grow them.
@(private = "file")
wirings_grow :: proc "contextless" (user: rawptr, count: int, payer: int) -> []wiring_core.Wiring_Entry {
	tables := (^Wiring_Tables)(user)
	if count > tables.wiring_count {
		if payer < 0 || payer >= len(process_handles) || process_handles[payer].asker_budget == 0 {
			return nil
		}
		arenas := [?]^system.Arena{&tables.wirings, &tables.end_memory, &tables.ring_memory, &tables.ring_capacity, &tables.actions}
		before := tables.wiring_count
		grown := arena_extend(&tables.wirings, wiring_core.Wiring_Entry, before, count) && arena_extend(&tables.end_memory, system.Handle, before, count) && arena_extend(&tables.ring_memory, system.Handle, before, count) && arena_extend(&tables.ring_capacity, u32, before, count) && arena_extend(&tables.actions, wiring_core.Stop_Action, before, count)
		if !grown {
			// The tables that grew give their entries back: they keep one
			// length.
			sizes := [?]u64{size_of(wiring_core.Wiring_Entry), size_of(system.Handle), size_of(system.Handle), size_of(u32), size_of(wiring_core.Stop_Action)}
			for arena, index in arenas {
				pushed := arena.used_bytes - u64(before) * sizes[index]
				_ = system.arena_pop(arena, pushed)
			}
			return nil
		}
		tables.wiring_count = count
		wiring_end_memory = ([^]system.Handle)(tables.end_memory.base)[:count]
		wiring_ring_memory = ([^]system.Handle)(tables.ring_memory.base)[:count]
		wiring_ring_capacity = ([^]u32)(tables.ring_capacity.base)[:count]
		stop_actions = ([^]wiring_core.Stop_Action)(tables.actions.base)[:count]
	}
	return ([^]wiring_core.Wiring_Entry)(tables.wirings.base)[:tables.wiring_count]
}
