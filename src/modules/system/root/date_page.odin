package root

import "modus:contract/date"
import "modus:support/system"

// The date (src/library/contract/date): this service creates the date page, gives it
// with Write and the two ports of the real-time clock to the process
// `date`, and maps it read-only into each process that it starts.

date_memory: system.Handle

date_page_create :: proc "contextless" () {
	status: system.Status
	date_memory, status = system.memory_create(1)
	if status != .Ok {
		fail("cannot create the date page", status)
	}
}

// mapping_dropped_log writes the one line of a mapping that a start drops:
// the list of the mappings of the start is full. The process starts
// without it, and reads nothing at its fixed range, as its bit is clear; a
// list that a new mapping fills says so at once, not by a missing picture.
mapping_dropped_log :: proc "contextless" (what: string, capacity: int) {
	system.log_fact(.Warning, Mapping_Dropped{capacity = u64(capacity), mapping = text_field(what, 40)})
}

// mapping_needed_log writes the one line of a mapping that a process cannot
// start without (the file of a service, the file of the storage service)
// when the list of the mappings of its start is full: the start fails with
// this line, and the list never takes an index past its end.
mapping_needed_log :: proc "contextless" (what: string, name: string, capacity: int) {
	system.log_fact(.Warning, Mapping_Needed{capacity = u64(capacity), refused_process = module_name_field(name), mapping = text_field(what, 40)})
}

// date_page_give adds the date page, read-only, to the mappings of a
// process, and sets its bit in the values.
date_page_give :: proc "contextless" (mappings: []system.Mapping, count: ^int, values: ^system.Context_Values) {
	if date_memory == 0 {
		return
	}
	if count^ >= len(mappings) {
		mapping_dropped_log("the date page", len(mappings))
		return
	}
	mappings[count^] = {memory = date_memory, address = date.PAGE_ADDRESS, first = 0, page_count = 1, flags = {}}
	count^ += 1
	system.range_mapped_put(values, .Date_Page)
}
