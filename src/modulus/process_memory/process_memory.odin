// The copy between the kernel and the memory of a process when the kernel
// cannot reach the process at its own addresses: on a browser machine, a
// pointer of the kernel has 32 bits and the address of a process has 64
// (src/md/features/browser_machine.md, "What the arch layer becomes"). The
// copy walks the table of the process in software, with the checks of the
// processor for a user access: present, user and, for a write, write, at
// each level and on each page that the range touches. The kernel calls it
// in user_copy_from_process and user_copy_to_process; the host tests call it
// on a memory that they build.
//
// A copy is whole or nothing: each page of the range is checked before the
// first byte moves, so a refused copy writes no byte and sets no accessed
// or dirty bit.
//
// This package allocates no memory and calls no kernel operation.
package process_memory

import software "modus:contract/software_machine"

// copy_from_process copies len(destination) bytes from the address
// process_source of the process whose table is at the physical address
// table. physical_memory is the whole physical memory of the machine, from
// address 0. false: an address of the range is not canonical, wraps past
// the top of the address space, or has no present user page; destination
// is unchanged.
copy_from_process :: proc "contextless" (physical_memory: []u8, table: u64, process_source: u64, destination: []u8) -> bool {
	result := software.mmu_read_bytes(nil, physical_memory, table, process_source, .User, .Read, destination)
	return result.status == .Ok
}

// copy_to_process copies source to the address process_destination of the
// process whose table is at the physical address table. false: an address
// of the range is not canonical, wraps past the top of the address space,
// or has no present, user and writable page; no byte of the process
// changes.
copy_to_process :: proc "contextless" (physical_memory: []u8, table: u64, process_destination: u64, source: []u8) -> bool {
	result := software.mmu_write_bytes(nil, physical_memory, table, process_destination, .User, source)
	return result.status == .Ok
}
