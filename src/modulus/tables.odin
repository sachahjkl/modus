package kernel

import op "modus:contract/operation"
import "modulus:table_sizes"

// The tables of the kernel whose size follows the memory of the machine
// (src/md/data/table_sizes.md). The kernel chooses the sizes once, at its
// start, from the free frames that memory_start counted, and takes each
// table from them in one contiguous run, with zeros. No table grows while
// the machine runs. The root budget is made after them: it holds the free
// frames that are left.

// The sizes of this machine. Written once by tables_start, before a second
// processor runs; read only after.
process_capacity: u32
thread_table_capacity: u32
region_capacity: u32

// tables_start takes the tables. A machine that has no contiguous run for a
// table stops with one line: it could start no process.
tables_start :: proc "contextless" () {
	sizes := table_sizes.sizes_of_memory(free_frames)
	process_capacity = sizes.process_slots
	thread_table_capacity = sizes.threads
	region_capacity = sizes.regions
	before := free_frames
	processes = table_take(Process, process_capacity, "the processes")
	origins = table_take(Origin_Link, process_capacity * HOLDINGS_PER_PROCESS, "the origin tree")
	process_records = table_take(Process_Record_State, process_capacity, "the records of the processes")
	threads = table_take(Thread, thread_table_capacity, "the threads")
	wait_entries = table_take(Wait_Entry, thread_table_capacity * op.WORD_WAIT_INLINE, "the word wait")
	regions = table_take(Region, region_capacity, "the memory objects")
	region_locks = table_take(Lock, region_capacity, "the locks of the memory objects")
	log("kernel: tables: ", u64(process_capacity), " process slots, ", u64(thread_table_capacity), " threads, ", u64(region_capacity), " memory objects: ", Size{(before - free_frames) * PAGE_SIZE >> 20, .Mebibytes})
}

// table_take gives a table of count records of T in frames of its own, with
// zeros.
@(private = "file")
table_take :: proc "contextless" ($T: typeid, count: u32, name: string) -> []T {
	pages := (u64(size_of(T)) * u64(count) + PAGE_SIZE - 1) / PAGE_SIZE
	address := frames_allocate(pages)
	if address == 0 {
		log("kernel: no contiguous memory for ", name, ": ", Size{pages * PAGE_SIZE >> 20, .Mebibytes})
		machine_stop(.Start_Failed)
	}
	#assert(PAGE_SIZE % 64 == 0) // A frame is aligned for a record of 64 bytes, as a thread.
	return ([^]T)(direct(address, T))[:count]
}
