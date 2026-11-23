#+build !freestanding
// The tables of the wiring service on the heap of a host, for its host
// tests: a machine grows them in arenas of the budget of the service
// (src/modules/system/wiring). No build of the system reads this file.
package wiring_core

import "base:runtime"

// The entries that a table on the heap holds at most: a host test that
// passes it asks for a budget that a test does not reach.
WIRING_HEAP_ENTRIES_MOST :: 1024

// The tables of one state on the heap, and the entries that the budget of
// the test pays for each.
Wiring_Heap_Tables :: struct {
	processes:      ^[WIRING_HEAP_ENTRIES_MOST]Process_Entry,
	wirings:        ^[WIRING_HEAP_ENTRIES_MOST]Wiring_Entry,
	processes_paid: int,
	wirings_paid:   int,
}

// wiring_tables_heap gives tables on the heap with a budget of
// processes_paid processes and wirings_paid wirings. They live as long as
// the test that made them: a host test does not free them.
wiring_tables_heap :: proc "contextless" (processes_paid: int = 256, wirings_paid: int = 256) -> (port: Wiring_Tables_Port, tables: ^Wiring_Heap_Tables) {
	tables = (^Wiring_Heap_Tables)(runtime.heap_alloc(size_of(Wiring_Heap_Tables)))
	tables.processes = (^[WIRING_HEAP_ENTRIES_MOST]Process_Entry)(runtime.heap_alloc(size_of([WIRING_HEAP_ENTRIES_MOST]Process_Entry)))
	tables.wirings = (^[WIRING_HEAP_ENTRIES_MOST]Wiring_Entry)(runtime.heap_alloc(size_of([WIRING_HEAP_ENTRIES_MOST]Wiring_Entry)))
	tables.processes_paid = min(processes_paid, WIRING_HEAP_ENTRIES_MOST)
	tables.wirings_paid = min(wirings_paid, WIRING_HEAP_ENTRIES_MOST)
	processes :: proc "contextless" (user: rawptr, count: int) -> []Process_Entry {
		tables := (^Wiring_Heap_Tables)(user)
		if count > tables.processes_paid {
			return nil
		}
		return tables.processes[:count]
	}
	wirings :: proc "contextless" (user: rawptr, count: int) -> []Wiring_Entry {
		tables := (^Wiring_Heap_Tables)(user)
		if count > tables.wirings_paid {
			return nil
		}
		return tables.wirings[:count]
	}
	return {user = tables, processes_grow = processes, wirings_grow = wirings}, tables
}

// wiring_tables_heap_port gives tables on the heap with a budget that a
// test does not reach.
wiring_tables_heap_port :: proc "contextless" () -> Wiring_Tables_Port {
	port, _ := wiring_tables_heap()
	return port
}
