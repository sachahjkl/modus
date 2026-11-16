package root

import "modus:contract/fixed_addresses"
import "modus:contract/date"
import op "modus:contract/operation"
import "modus:support/system"

// The date (src/library/contract/date): this service creates the date page, gives it
// with Write and the two ports of the real-time clock to the program
// `date`, and maps it read-only into each program that it starts.

date_memory: system.Handle

date_page_create :: proc "contextless" () {
	status: system.Status
	date_memory, status = system.memory_create(1)
	if status != .Ok {
		fail("cannot create the date page", status)
	}
}

// mapping_dropped_log writes the one line of a mapping that a start drops:
// the list of the mappings of the start is full. The program starts
// without it, and reads nothing at its fixed range, as its bit is clear; a
// list that a new mapping fills says so at once, not by a missing picture.
mapping_dropped_log :: proc "contextless" (what: string, capacity: int) {
	system.log_in("programs", .Warning, "root: no room for ", what, " in the mappings of a start, which holds ", u64(capacity), ": the program starts without it")
}

// mapping_needed_log writes the one line of a mapping that a program cannot
// start without (the file of a service, the file of the storage service)
// when the list of the mappings of its start is full: the start fails with
// this line, and the list never takes an index past its end.
mapping_needed_log :: proc "contextless" (what: string, name: string, capacity: int) {
	system.log_in("programs", .Warning, "root: no room for ", what, " in the mappings of a start, which holds ", u64(capacity), ": the start of ", system.Module_Name{name}, " fails")
}

// date_page_give adds the date page, read-only, to the mappings of a
// program, and sets its bit in the values.
date_page_give :: proc "contextless" (mappings: []system.Mapping, count: ^int, values: ^[op.CONTEXT_VALUES]u64) {
	if date_memory == 0 {
		return
	}
	if count^ >= len(mappings) {
		mapping_dropped_log("the date page", len(mappings))
		return
	}
	mappings[count^] = {memory = date_memory, address = date.PAGE_ADDRESS, first = 0, page_count = 1, flags = {}}
	count^ += 1
	fixed_addresses.range_mapped_add(values, .Date_Page)
}
