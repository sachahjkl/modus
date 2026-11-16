package root

import "base:intrinsics"
import "modus:contract/fixed_addresses"
import "modus:contract/fresh_bytes"
import op "modus:contract/operation"
import "modus:support/random"
import "modus:support/system"

// The fresh bytes (src/md/features/fresh_bytes.md): this service creates
// one memory object with one page for each place of `started`, and maps
// the page of a place, read-only, into the program that it starts there.
// After each read of the entropy device that it mixed into its generator
// (entropy.odin), it writes 32 bytes of its stream in the page of each
// program: each program has its own bytes, which its generator mixes into
// its key at its next refill or key.
//
// One object, not one for each program: each object would be one more
// handle of this service, and a full handle table refuses the load of the
// next program (font_service.odin says how the table fills).

fresh_bytes_memory: system.Handle // STARTED_CAPACITY pages; 0: no fresh bytes.
fresh_bytes_address: uintptr // The object, mapped with Write in this service.
fresh_bytes_given: [STARTED_CAPACITY]bool // The program of the place maps the page of the place.

// fresh_bytes_create creates the pages. A failure is not a failure of the
// start: the programs then get no page, and the log says it once.
fresh_bytes_create :: proc "contextless" () {
	status: system.Status
	fresh_bytes_memory, status = system.memory_create(STARTED_CAPACITY)
	address: rawptr
	if status == .Ok {
		address, status = system.memory_map(fresh_bytes_memory)
	}
	if status != .Ok {
		system.log_in("programs", .Warning, "root: cannot create the fresh bytes pages: status ", status, ": a running program mixes no new bytes into its generator")
		if fresh_bytes_memory != 0 {
			system.close(fresh_bytes_memory)
		}
		fresh_bytes_memory = 0
		return
	}
	fresh_bytes_address = uintptr(address)
}

// fresh_bytes_page_of gives the page of a place of `started`.
fresh_bytes_page_of :: proc "contextless" (index: int) -> ^fresh_bytes.Page {
	return (^fresh_bytes.Page)(fresh_bytes_address + uintptr(index) * uintptr(system.PAGE_SIZE))
}

// fresh_bytes_page_give clears the page of the place of a program and adds
// it, read-only, to the mappings of the program, with the bit of its range.
// The clear comes before the start: the program reads no byte that the
// program before it in the place read.
fresh_bytes_page_give :: proc "contextless" (item: ^Started, mappings: []system.Mapping, count: ^int, values: ^[op.CONTEXT_VALUES]u64) {
	if fresh_bytes_memory == 0 {
		return
	}
	index := disk_program_page_index(item)
	if index < 0 || index >= STARTED_CAPACITY {
		return
	}
	if count^ >= len(mappings) {
		mapping_dropped_log("the fresh bytes page", len(mappings))
		return
	}
	fresh_bytes.clear(fresh_bytes_page_of(index))
	mappings[count^] = {memory = fresh_bytes_memory, address = fresh_bytes.PAGE_ADDRESS, first = u64(index), page_count = 1, flags = {}}
	count^ += 1
	fixed_addresses.range_mapped_add(values, .Fresh_Bytes_Page)
	fresh_bytes_given[index] = true
}

// fresh_bytes_forget ends the page of a place that this service releases:
// no more bytes are written there until the next program of the place.
fresh_bytes_forget :: proc "contextless" (item: ^Started) {
	index := disk_program_page_index(item)
	if fresh_bytes_memory == 0 || index < 0 || index >= STARTED_CAPACITY || !fresh_bytes_given[index] {
		return
	}
	fresh_bytes_given[index] = false
	fresh_bytes.clear(fresh_bytes_page_of(index))
}

// fresh_bytes_write_all writes 32 bytes of the stream of this service in
// the page of each program that has one, after a read of the device that
// this service mixed into its generator. It gives the count of the pages
// that it wrote. It wakes no program: a program reads its page at its next
// refill or key.
fresh_bytes_write_all :: proc "contextless" () -> (programs: u64) {
	if fresh_bytes_memory == 0 {
		return 0
	}
	for given, index in fresh_bytes_given {
		if !given || started[index].program == 0 {
			continue
		}
		bytes: [fresh_bytes.BYTES]u8
		random.fill(&program_generator, bytes[:])
		fresh_bytes.write(fresh_bytes_page_of(index), &bytes)
		intrinsics.mem_zero_volatile(&bytes, size_of(bytes))
		programs += 1
	}
	return programs
}
