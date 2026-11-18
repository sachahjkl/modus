package root

import program_page "modus:contract/disk_program_page"
import "modus:support/disk_program"
import "modus:support/system"

// The disk program page (modus:contract/disk_program_page): this service
// writes the nickname and the hash of each disk program that runs, at the
// row of its slot in `started`, and maps the page read-only into each
// program that it starts with the right Inspect. The monitor shows a disk
// program by its nickname with the hash of its file from it
// (src/md/features/programs_from_a_disk.md, "The grants of a disk program").

disk_program_page_memory: system.Handle
disk_program_page: ^program_page.Page

// A row is the place of a slot of `started`, and the nickname of a row is a
// name that this service checked.
#assert(STARTED_CAPACITY <= program_page.ROW_CAPACITY)
#assert(disk_program.NAME_LIMIT == program_page.NICKNAME_LIMIT)
#assert(disk_program.HASH_SIZE == program_page.HASH_SIZE)

disk_program_page_create :: proc "contextless" () {
	status: system.Status
	disk_program_page_memory, status = system.memory_create(1)
	address: rawptr
	if status == .Ok {
		address, status = system.memory_map(disk_program_page_memory)
	}
	if status != .Ok {
		fail("cannot create the disk program page", status)
	}
	disk_program_page = (^program_page.Page)(address)
}

// disk_program_page_give adds the disk program page, read-only, to the
// mappings of a program, and sets its bit in the values.
disk_program_page_give :: proc "contextless" (mappings: []system.Mapping, count: ^int, values: ^system.Context_Values) {
	if disk_program_page_memory == 0 {
		return
	}
	if count^ >= len(mappings) {
		mapping_dropped_log("the disk program page", len(mappings))
		return
	}
	mappings[count^] = {memory = disk_program_page_memory, address = program_page.PAGE_ADDRESS, first = 0, page_count = 1, flags = {}}
	count^ += 1
	system.range_mapped_put(values, .Disk_Program_Page)
}

// disk_program_page_index gives the row of a slot of `started`.
disk_program_page_index :: proc "contextless" (item: ^Started) -> int {
	return int((uintptr(item) - uintptr(&started[0])) / size_of(Started))
}

// disk_program_page_add writes the row of a disk program that started: the
// kernel gives the program slot and the program serial of its handle, so
// the row names this program and no other one with the same name.
disk_program_page_add :: proc "contextless" (item: ^Started) {
	results, status := system.call(.Program_State, u64(item.program))
	if status != .Ok {
		return
	}
	program_page.row_write(disk_program_page, disk_program_page_index(item), program_page.row_of(results[3], results[4], system.name_of(item.name[:]), item.hash))
}

// disk_program_page_remove clears the row of a slot that this service
// releases.
disk_program_page_remove :: proc "contextless" (item: ^Started) {
	if item.from_disk {
		program_page.row_write(disk_program_page, disk_program_page_index(item), {})
	}
}
