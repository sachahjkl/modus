// The memory of a Linux guest, as the process that runs it maps it: one
// memory object of the process, mapped here with no Execute and in the guest
// in switching mappings, whose pages the kernel switches between Write and
// Execute one by one (src/md/features/guest.md, "The switch of a page"),
// and the copy of the kernel image at the top of it
// (src/md/features/foreign_systems.md, "The machine of a Linux guest"). The
// guest builder and the process `linux` run their guests with it.
package guest_regions

import op "modus:contract/operation"
import "modus:system"

// The memory of the guest is mapped in mappings of at least 2 MiB, so that
// the process has at most REGIONS_MOST mappings in the guest.
REGION_BYTES_LEAST :: u64(2 * 1024 * 1024)
REGIONS_MOST :: u64(120)

// One memory object of this process, mapped here.
Owned_Memory :: struct {
	handle: system.Handle,
	bytes:  []u8,
}

// owned_memory_make makes a memory object of at least byte_count bytes and
// maps it here for writing.
owned_memory_make :: proc "contextless" (byte_count: u64) -> (memory: Owned_Memory, status: system.Status) {
	pages := max((byte_count + system.PAGE_SIZE - 1) / system.PAGE_SIZE, 1)
	handle: system.Handle
	handle, status = system.memory_create(pages)
	if status != .Ok {
		return {}, status
	}
	address: rawptr
	address, status = system.memory_map(handle, {.Write})
	if status != .Ok {
		system.close(handle)
		return {}, status
	}
	return {handle = handle, bytes = ([^]u8)(address)[:pages * system.PAGE_SIZE]}, .Ok
}

owned_memory_end :: proc "contextless" (memory: ^Owned_Memory) {
	if memory.bytes != nil {
		system.memory_unmap(raw_data(memory.bytes))
	}
	if memory.handle != 0 {
		system.close(memory.handle)
	}
	memory^ = {}
}

// kernel_staging_bytes gives the page-aligned size of the copy of the kernel
// image, which waits at the top of the memory of the guest while the kernel
// loads below it. The count is checked before the rounding: a count near the
// largest u64 wraps the rounded size to 0, past every later check.
kernel_staging_bytes :: proc "contextless" (kernel_count: u64, memory_bytes: u64) -> (staging_bytes: u64, fits: bool) {
	if kernel_count == 0 || kernel_count >= memory_bytes {
		return 0, false
	}
	staging_bytes = (kernel_count + system.PAGE_SIZE - 1) &~ u64(system.PAGE_SIZE - 1)
	if staging_bytes >= memory_bytes {
		return 0, false
	}
	return staging_bytes, true
}

// region_bytes gives the size of one mapping of the memory of the guest:
// 2 MiB, or more for a memory past REGIONS_MOST regions of 2 MiB.
region_bytes :: proc "contextless" (memory_bytes: u64) -> u64 {
	least := (memory_bytes + REGIONS_MOST - 1) / REGIONS_MOST
	return max(REGION_BYTES_LEAST, (least + REGION_BYTES_LEAST - 1) / REGION_BYTES_LEAST * REGION_BYTES_LEAST)
}

// map_memory maps the memory of the guest into the guest process in
// switching mappings of region_bytes, and gives each one Execute for the
// whole: a page on first use that a read touches is then executable, as a
// kernel starts by running code, and the kernel switches each page at the
// fault of the guest. step names the operation that failed.
map_memory :: proc "contextless" (guest: system.Handle, memory: system.Handle, memory_bytes: u64) -> (status: system.Status, step: string) {
	region := region_bytes(memory_bytes)
	for address: u64 = 0; address < memory_bytes; address += region {
		pages := min(region, memory_bytes - address) / system.PAGE_SIZE
		flags := op.Map_Flags{.Write, .Execute, .No_Access}
		if address == 0 {
			flags += {.At_Address_Zero}
		}
		if _, status = system.memory_map(memory, flags, guest, address, address / system.PAGE_SIZE, pages); status != .Ok {
			return status, "Memory_Map of guest memory"
		}
		ranges := [1]op.Address_Range{{address = address, page_count = pages}}
		if _, status = system.memory_protect(ranges[:], {.Execute}, process = guest); status != .Ok {
			return status, "Memory_Protect of guest memory"
		}
	}
	return .Ok, ""
}


#assert(REGION_BYTES_LEAST % system.PAGE_SIZE == 0)
