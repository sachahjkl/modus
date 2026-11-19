package root

import process_page "modus:contract/disk_process_page"
import "modus:support/disk_process"
import "modus:support/system"

// The disk process page (modus:contract/disk_process_page): this service
// writes the nickname and the hash of each disk process that runs, at the
// row of its slot in `started`, and maps the page read-only into each
// process that it starts with the right Inspect. The monitor shows a disk
// process by its nickname with the hash of its file from it
// (src/md/features/processes_from_a_disk.md, "The grants of a disk process").

disk_process_page_memory: system.Handle
disk_process_page: ^process_page.Page

// A row is the place of a slot of `started`, and the nickname of a row is a
// name that this service checked.
#assert(STARTED_CAPACITY <= process_page.ROW_CAPACITY)
#assert(disk_process.NAME_LIMIT == process_page.NICKNAME_LIMIT)
#assert(disk_process.HASH_SIZE == process_page.HASH_SIZE)

disk_process_page_create :: proc "contextless" () {
	status: system.Status
	disk_process_page_memory, status = system.memory_create(1)
	address: rawptr
	if status == .Ok {
		address, status = system.memory_map(disk_process_page_memory)
	}
	if status != .Ok {
		fail("cannot create the disk process page", status)
	}
	disk_process_page = (^process_page.Page)(address)
}

// disk_process_page_give adds the disk process page, read-only, to the
// mappings of a process, and sets its bit in the values.
disk_process_page_give :: proc "contextless" (mappings: []system.Mapping, count: ^int, values: ^system.Context_Values) {
	if disk_process_page_memory == 0 {
		return
	}
	if count^ >= len(mappings) {
		mapping_dropped_log("the disk process page", len(mappings))
		return
	}
	mappings[count^] = {memory = disk_process_page_memory, address = process_page.PAGE_ADDRESS, first = 0, page_count = 1, flags = {}}
	count^ += 1
	system.range_mapped_put(values, .Disk_Process_Page)
}

// disk_process_page_index gives the row of a slot of `started`.
disk_process_page_index :: proc "contextless" (item: ^Started) -> int {
	return int((uintptr(item) - uintptr(&started[0])) / size_of(Started))
}

// disk_process_page_add writes the row of a disk process that started: the
// kernel gives the process slot and the process serial of its handle, so
// the row names this process and no other one with the same name.
disk_process_page_add :: proc "contextless" (item: ^Started) {
	results, status := system.call(.Process_State, u64(item.process))
	if status != .Ok {
		return
	}
	process_page.row_write(disk_process_page, disk_process_page_index(item), process_page.row_of(results[4], results[5], system.name_of(item.name[:]), item.hash))
}

// disk_process_page_remove clears the row of a slot that this service
// releases.
disk_process_page_remove :: proc "contextless" (item: ^Started) {
	if item.from_disk {
		process_page.row_write(disk_process_page, disk_process_page_index(item), {})
	}
}
