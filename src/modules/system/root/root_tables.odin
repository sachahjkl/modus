package root

// The tables of this service that have an entry for each place, one place
// for each process slot of the machine but its own: `started`, the fresh
// bytes, the devices bound to a place, and the wait set of the loop, with
// each queue of each place. This service sizes them once, at its start,
// from the process slots that the kernel chose (System_Report.process_slots,
// src/md/data/table_sizes.md), in one arena that its budget pays: a small
// machine pays no entry for a place that no process can take.

import op "modus:contract/operation"
import rd "modus:contract/root_delegation"
import "modus:contract/root_ring"
import "modus:system"

// The process slots of this machine: a walk over the slots reads them,
// never op.PROCESS_SLOTS_MOST.
machine_process_slots: u64

// The arena of the tables. It lives as long as this service.
root_tables: system.Arena

// root_tables_start takes the tables, before anything reads a place. A
// machine whose slots this service cannot read, or whose tables its budget
// cannot pay, stops here with the cause on the screen.
root_tables_start :: proc "contextless" () {
	machine_process_slots = system.process_slots_of(machine)
	if machine_process_slots < op.PROCESS_SLOTS_LEAST {
		fail("cannot read the process slots of the machine", .Bad_State)
	}
	places := int(machine_process_slots) - 1
	words := root_ring.root_wait_words(places)
	sizes := [?]u64{
		u64(places) * size_of(Started),
		u64(places) * size_of(bool),
		u64(places) * size_of(rd.Pci_Discovered_Device),
		u64(places) * size_of(bool),
		u64(words) * size_of(op.Word),
		u64(words) * size_of(system.Wait_Part),
	}
	status: system.Status
	root_tables, status = system.arena_create(system.arena_take_pages(sizes[:]))
	if status != .Ok {
		fail("cannot take the tables of the places", status)
	}
	wait_words: []op.Word
	wait_parts: []system.Wait_Part
	ok := true
	started, status = system.arena_take(&root_tables, Started, places)
	ok &&= status == .Ok
	fresh_bytes_given, status = system.arena_take(&root_tables, bool, places)
	ok &&= status == .Ok
	bound_devices, status = system.arena_take(&root_tables, rd.Pci_Discovered_Device, places)
	ok &&= status == .Ok
	bound_device_present, status = system.arena_take(&root_tables, bool, places)
	ok &&= status == .Ok
	wait_words, status = system.arena_take(&root_tables, op.Word, words)
	ok &&= status == .Ok
	wait_parts, status = system.arena_take(&root_tables, system.Wait_Part, words)
	ok &&= status == .Ok
	if !ok {
		fail("cannot take the tables of the places", status)
	}
	root_wait_set = system.wait_set_of(wait_words, wait_parts)
}
