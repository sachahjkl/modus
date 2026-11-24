// The machine case of the border of Memory_Read
// (docs/ARCHITECTURE.md, "The read of a memory object by its handle"). It
// gives the kernel each argument that the operation must refuse, checks
// the status, and checks that a refusal wrote no byte; then a whole read
// of 1 MiB, whose time it prints as a measure, with no bound.
//
// **Start**: `start("memory_read_border")` in the console. **What a reader
// sees**: no window; one line "memory_read_border: ..." with the time of
// the read of 1 MiB, or a line "memory_read_border: WRONG: ...".
package memory_read_border

import "modus:contract/call_outcome"
import op "modus:contract/operation"
import "modus:system"

OBJECT_PAGES :: 4
OBJECT_BYTES :: OBJECT_PAGES * system.PAGE_SIZE
LARGE_PAGES :: op.MEMORY_READ_LIMIT / system.PAGE_SIZE
// The byte that a refused read must leave in the buffer.
UNTOUCHED :: 0xAA

// The objects of the cases, the buffer of 1 MiB, the code.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 576}
#assert(MODULE_BUDGET.working_memory_pages == 2 * LARGE_PAGES + 64)

buffer: [op.MEMORY_READ_LIMIT]u8

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	object := object_make(OBJECT_PAGES)
	address, map_status := system.memory_map(object, {.Write})
	if map_status != .Succeeded {
		wrong("the object of the cases does not map; the status word", u64(map_status))
	}
	bytes := ([^]u8)(address)[:OBJECT_BYTES]
	for &byte, index in bytes {
		byte = u8(index % 251)
	}

	// The edges of the range and of the length.
	expect_refusal("an offset at the end with one byte", object, OBJECT_BYTES, 1, .Argument_Refused)
	expect_refusal("an offset one past the end with no byte", object, OBJECT_BYTES + 1, 0, .Argument_Refused)
	expect_refusal("a range one byte past the end", object, OBJECT_BYTES - 1, 2, .Argument_Refused)
	expect_refusal("a length one past the limit", object, 0, op.MEMORY_READ_LIMIT + 1, .Argument_Refused)
	if copied, status := raw_read(object, OBJECT_BYTES, raw_data(buffer[:]), 0); status != .Succeeded || copied != 0 {
		wrong("a length of 0 at the end did not copy nothing; the status word", u64(status))
	}
	// Device memory: the boot image, which the kernel names as such.
	image := ctx.handles[system.GRANT_IMAGE]
	if image == 0 {
		wrong("no handle of the boot image", 0)
	}
	expect_refusal("device memory", image, 0, 16, .Argument_Refused)
	// A handle with no Read.
	no_read, give_status := system.give(0, object, {})
	if give_status != .Succeeded {
		wrong("the copy of the handle with no right was not made; the status word", u64(give_status))
	}
	expect_refusal("a handle with no Read", no_read, 0, 16, .Grant_Or_Right_Missing)
	system.close(no_read)
	// A destination that the process cannot write: a read-only mapping of
	// another object, and an address that names no mapping.
	other := object_make(1)
	read_only, other_status := system.memory_map(other, {})
	if other_status != .Succeeded {
		wrong("the read-only object does not map; the status word", u64(other_status))
	}
	if _, status := raw_read(object, 0, read_only, 16); status != .Argument_Refused {
		wrong("a read-only destination was not refused with Argument_Refused; the status word", u64(status))
	}
	if _, status := raw_read(object, 0, rawptr(uintptr(system.PAGE_SIZE)), 16); status != .Argument_Refused {
		wrong("a destination with no mapping was not refused with Argument_Refused; the status word", u64(status))
	}
	// A destination inside a mapping of the same object: refused, and the
	// object is unchanged.
	if _, status := raw_read(object, 0, rawptr(uintptr(address) + system.PAGE_SIZE), 16); status != .Argument_Refused {
		wrong("a destination in a mapping of the same object was not refused with Argument_Refused; the status word", u64(status))
	}
	for index in 0 ..< OBJECT_BYTES {
		if bytes[index] != u8(index % 251) {
			wrong("a refused read changed the object at the byte", u64(index))
		}
	}
	// A range whose second page is not committed: nothing is written.
	uncommitted, uncommitted_status := system.memory_create(2, 0, {.Uncommitted})
	if uncommitted_status != .Succeeded {
		wrong("the Uncommitted object was not made; the status word", u64(uncommitted_status))
	}
	first_page := [1]op.Page_Range{{first = 0, page_count = 1}}
	if _, commit_status := system.memory_commit(uncommitted, first_page[:]); commit_status != .Succeeded {
		wrong("the first page was not committed; the status word", u64(commit_status))
	}
	expect_untouched_refusal("a page that is not committed", uncommitted, 0, 2 * system.PAGE_SIZE)
	if _, status := raw_read(uncommitted, 0, raw_data(buffer[:]), system.PAGE_SIZE); status != .Succeeded {
		wrong("the committed page alone was not read; the status word", u64(status))
	}
	// A page marked No_Access, as a mapping refuses it: nothing is written.
	marked := [1]op.Address_Range{{address = u64(uintptr(address)) + system.PAGE_SIZE, page_count = 1}}
	if _, protect_status := system.memory_protect(marked[:], {.No_Access}); protect_status != .Succeeded {
		wrong("the second page was not marked No_Access; the status word", u64(protect_status))
	}
	expect_untouched_refusal("a page marked No_Access", object, 0, OBJECT_BYTES)
	if _, status := raw_read(object, 2 * system.PAGE_SIZE, raw_data(buffer[:]), 2 * system.PAGE_SIZE); status != .Succeeded {
		wrong("the pages after the marked one were not read; the status word", u64(status))
	}
	system.log_fact(.Info, Refusals_Hold{})

	// The last case: one whole read of 1 MiB, and its time.
	large := object_make(LARGE_PAGES)
	large_address, large_status := system.memory_map(large, {.Write})
	if large_status != .Succeeded {
		wrong("the object of 1 MiB does not map; the status word", u64(large_status))
	}
	large_bytes := ([^]u8)(large_address)[:op.MEMORY_READ_LIMIT]
	for &byte, index in large_bytes {
		byte = u8(index % 253)
	}
	start := system.nanoseconds()
	copied, status := raw_read(large, 0, raw_data(buffer[:]), op.MEMORY_READ_LIMIT)
	spent := system.nanoseconds() - start
	if status != .Succeeded || copied != op.MEMORY_READ_LIMIT {
		wrong("the read of 1 MiB did not copy it whole; the status word", u64(status))
	}
	for index in 0 ..< op.MEMORY_READ_LIMIT {
		if buffer[index] != u8(index % 253) {
			wrong("the read of 1 MiB gave another byte at", u64(index))
		}
	}
	system.log_fact(.Info, Large_Read_Measured{nanoseconds = spent})
	system.stop(.Done)
}

@(private = "file")
object_make :: proc "contextless" (pages: u64) -> system.Handle {
	memory, status := system.memory_create(pages)
	if status != .Succeeded {
		wrong("an object was not made; the status word", u64(status))
	}
	return memory
}

// raw_read makes one operation Memory_Read: no wrapper cuts the length.
@(private = "file")
raw_read :: proc "contextless" (memory: system.Handle, offset: u64, address: rawptr, length: u64) -> (copied: u64, status: call_outcome.Call_Outcome) {
	results: [7]u64
	results, status = system.call(.Memory_Read, u64(memory), offset, u64(uintptr(address)), length)
	return results[0], status
}

@(private = "file")
expect_refusal :: proc "contextless" (what: string, memory: system.Handle, offset, length: u64, expected: call_outcome.Call_Outcome) {
	if _, status := raw_read(memory, offset, raw_data(buffer[:]), min(length, op.MEMORY_READ_LIMIT + 1)); status != expected {
		system.log_fact(.Error, Wrong_Status{status = u64(status), expected = u64(expected)}, what)
		system.stop(.Failed)
	}
}

// expect_untouched_refusal checks that a read that the kernel refuses with
// Bad_State wrote no byte of the buffer.
@(private = "file")
expect_untouched_refusal :: proc "contextless" (what: string, memory: system.Handle, offset, length: u64) {
	for index in 0 ..< length {
		buffer[index] = UNTOUCHED
	}
	expect_refusal(what, memory, offset, length, .Wrong_State)
	for index in 0 ..< length {
		if buffer[index] != UNTOUCHED {
			system.log_fact(.Error, Wrong{value = index}, what)
			system.stop(.Failed)
		}
	}
}

@(private = "file")
wrong :: proc "contextless" (text: string, value: u64) -> ! {
	system.log_fact(.Error, Wrong{value = value}, text)
	system.stop(.Failed)
}
