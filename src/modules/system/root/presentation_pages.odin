package root

import "modus:contract/call_outcome"
import "modus:contract/settings"
import "modus:system"

// The presentation pages (src/md/features/module_settings.md, "The
// presentation record"): one page for each place of `started`, mapped with
// Write into the process of the place only, at
// settings.PRESENTATION_PAGE_ADDRESS. The display library of the process
// writes there the presentation record that the holder of the display
// gives on its window ring, and its drawing module reads it. No window maps
// the settings page of the machine: what a window draws with comes from
// the holder of the display, through its own ring.
//
// One object, not one for each process, for the reason of the fresh bytes
// (fresh_bytes.odin): each object is one more handle of this service.

presentation_memory: system.Handle // STARTED_CAPACITY pages; 0: no presentation pages.
presentation_address: uintptr // The object, mapped with Write in this service.

// presentation_pages_create creates the pages. A failure is not a failure
// of the start: a window then draws with the defaults, and the log says it
// once.
presentation_pages_create :: proc "contextless" () {
	status: call_outcome.Call_Outcome
	presentation_memory, status = system.memory_create(STARTED_CAPACITY)
	address: rawptr
	if status == .Succeeded {
		address, status = system.memory_map(presentation_memory)
	}
	if status != .Succeeded {
		system.log_fact(.Warning, Presentation_Pages_Failed{status = status})
		if presentation_memory != 0 {
			system.close(presentation_memory)
		}
		presentation_memory = 0
		return
	}
	presentation_address = uintptr(address)
}

// presentation_page_give writes the defaults on the page of the place of a
// process and adds it, with Write, to the mappings of the process, with the
// bit of its range. The defaults come before the start: the process reads
// nothing that the process before it in the place was told, and draws with
// the defaults until its first presentation record.
presentation_page_give :: proc "contextless" (item: ^Started, mappings: []system.Mapping, count: ^int, values: ^system.Context_Values) {
	if presentation_memory == 0 {
		return
	}
	index := disk_process_page_index(item)
	if index < 0 || index >= STARTED_CAPACITY {
		return
	}
	if count^ >= len(mappings) {
		mapping_dropped_log("the presentation page", len(mappings))
		return
	}
	settings.page_defaults_write((^settings.Page)(presentation_address + uintptr(index) * uintptr(system.PAGE_SIZE)))
	mappings[count^] = {memory = presentation_memory, address = settings.PRESENTATION_PAGE_ADDRESS, first = u64(index), page_count = 1, flags = {.Write}}
	count^ += 1
	system.range_mapped_put(values, .Presentation_Page)
}
