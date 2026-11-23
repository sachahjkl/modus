// The sizes of the tables of the kernel, from the memory of the machine
// (src/md/data/table_sizes.md). The kernel counts the usable pages of the
// memory map once, at its start, and takes each table from the free frames
// at the size that this package gives: no table grows while the machine
// runs.
//
// This package allocates no memory and calls no kernel operation.
package table_sizes

import op "modus:contract/operation"

// The usable pages of memory for each process slot: 4 MiB. A process slot
// costs about 200 KiB of the kernel with its threads and its memory objects,
// so the tables take about 5 % of the memory.
PAGES_OF_A_PROCESS_SLOT :: 1024
// The process slots are a multiple of this: a set of slots is whole words.
PROCESS_SLOTS_STEP :: 64
// The threads and the memory objects of the machine for each process slot.
THREADS_OF_A_PROCESS_SLOT :: 4
REGIONS_OF_A_PROCESS_SLOT :: 64

// The most of each table, for the parts of the kernel that keep a table at
// its most: a set of process slots, a lock of each process.
THREADS_MOST :: op.PROCESS_SLOTS_MOST * THREADS_OF_A_PROCESS_SLOT
REGIONS_MOST :: op.PROCESS_SLOTS_MOST * REGIONS_OF_A_PROCESS_SLOT

#assert(op.PROCESS_SLOTS_LEAST % PROCESS_SLOTS_STEP == 0)
#assert(op.PROCESS_SLOTS_MOST % PROCESS_SLOTS_STEP == 0)
#assert(op.PROCESS_SLOTS_LEAST <= op.PROCESS_SLOTS_MOST)

// The sizes of the tables of one machine. Each count holds the entry 0,
// which names nothing.
Table_Sizes :: struct {
	process_slots: u32,
	threads:       u32,
	regions:       u32,
}

// sizes_of_memory gives the sizes of the tables of a machine with
// usable_pages pages of usable memory: one process slot for each
// PAGES_OF_A_PROCESS_SLOT pages, rounded up to a multiple of
// PROCESS_SLOTS_STEP, never fewer than op.PROCESS_SLOTS_LEAST and never
// more than op.PROCESS_SLOTS_MOST.
//
// Example: 252 000 pages (a machine of 1 GiB) give 256 slots, 1024 threads
// and 16 384 memory objects.
sizes_of_memory :: proc "contextless" (usable_pages: u64) -> Table_Sizes {
	slots := min(usable_pages / PAGES_OF_A_PROCESS_SLOT, u64(op.PROCESS_SLOTS_MOST))
	slots = (slots + PROCESS_SLOTS_STEP - 1) / PROCESS_SLOTS_STEP * PROCESS_SLOTS_STEP
	slots = clamp(slots, u64(op.PROCESS_SLOTS_LEAST), u64(op.PROCESS_SLOTS_MOST))
	return {process_slots = u32(slots), threads = u32(slots * THREADS_OF_A_PROCESS_SLOT), regions = u32(slots * REGIONS_OF_A_PROCESS_SLOT)}
}
