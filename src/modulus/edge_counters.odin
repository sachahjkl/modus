package kernel

import "modus:contract/operation_sequence"

// The counted kernel (src/md/infrastructure/kernel_fuzzing.md, "The test
// kernel"): the module kernel_edge_counters of
// tools/modustool/foundation/module_table.odin builds these sources with the
// setting below, and the tool adds a call of the callback of
// edge_counters.asm at each edge of the code. The callback counts only while
// the counting word is set, which kernel_interrupt sets around the dispatch
// of a kernel entry or an exception of a counted process. Only the tool
// reads the counters, through the memory file of the machine: no process
// has a handle to them.
//
// Each other kernel is built with the setting false, so none of the code
// below is in it, and its build does not link edge_counters.asm.
KERNEL_EDGE_COUNTERS :: #config(KERNEL_EDGE_COUNTERS, false)

// The start of the boot line of the counted kernel. Its numbers are the
// physical address of the counters and their count, in decimal. The release
// refuses a kernel module whose bytes hold "kernel: TEST BUILD:"
// (src/md/infrastructure/release_image.md).
TEST_BUILD_LINE_EDGE_COUNTERS :: "kernel: TEST BUILD: edge counters at "

// The name of the process that Process_Create marks as counted: the runner
// of the operation sequences. The children of a counted process are counted
// too, as a part of its sequence.
EDGE_COUNTED_PROCESS_NAME :: "operation_sequence_runner"
#assert(EDGE_COUNTED_PROCESS_NAME == operation_sequence.RUNNER_NAME)

when KERNEL_EDGE_COUNTERS {
	foreign _ {
		// 1 while the kernel runs the code of a counted process. One word
		// of the machine: the counted kernel runs on one processor
		// (edge_counters_start).
		edge_counting: u8
		// The first counter: one byte for each edge, up to edge_counter_count.
		edge_counters: u8
		edge_counter_count: u64
	}

	// The mark of each process slot: its process is counted. Each
	// Process_Create writes the byte of the slot that it fills, so a slot
	// that served a counted process loses the mark with its next process.
	edge_counted_processes: [PROCESS_CAPACITY_MOST]bool

	// The interrupt controller did not send the reset of a processor that
	// did not start in time (processors_start): that processor can still
	// run the code of the kernel.
	edge_counters_processor_not_reset: bool

	// edge_counters_start stops the machine when another processor than the
	// first one runs, or can run, compiled code of the kernel; it then finds
	// the physical pages of the counters through the page table of the
	// kernel, checks that they are one run of physical memory, and writes
	// the boot line that names them. The tool maps that run of its memory
	// file: a run with a gap would give it the bytes of other memory.
	edge_counters_start :: proc "contextless" () {
		if processor_count != 1 {
			log("kernel: TEST BUILD: the counted kernel counts the code of one processor, and the machine has ", u64(processor_count))
			machine_stop(.Start_Failed)
		}
		// A processor that reached processor_entry and that the first
		// processor did not count waits in a loop of compiled code, or
		// stopped after its setup: either way it ran code that the counters
		// would mix with the code of a sequence. One read of a word that
		// only grows: the import of the intrinsics in this file would be
		// unused in each other kernel.
		if started := started_count; started != processor_count - 1 {
			log("kernel: TEST BUILD: the counted kernel counts the code of one processor, and ", u64(started), " other processors ran its code")
			machine_stop(.Start_Failed)
		}
		if edge_counters_processor_not_reset {
			log("kernel: TEST BUILD: the counted kernel counts the code of one processor, and a processor that did not start was not reset")
			machine_stop(.Start_Failed)
		}
		first := u64(uintptr(&edge_counters))
		count := edge_counter_count
		first_page := first &~ (PAGE_SIZE - 1)
		physical_first_page: u64
		// Each entry is the entry of a page of 4 KiB: the boot program maps
		// each page of the kernel module with a small page
		// (src/boot/main.odin, "The kernel, in small pages"), and the kernel
		// changes no entry of its module; it splits only the large pages of
		// the direct map (paging_start). So kernel_entry walks three tables
		// and never reads a large page as a table. At this last level, bit 7
		// is the bit PAT of a small page, not the bit of a large page, so
		// it is not tested.
		for page := first_page; page < first + max(count, 1); page += PAGE_SIZE {
			entry := kernel_entry(page, create = false)
			if entry == nil || entry^ & PAGE_PRESENT == 0 {
				log("kernel: TEST BUILD: a page of the edge counters is not mapped")
				machine_stop(.Start_Failed)
			}
			physical := entry^ & PAGE_ADDRESS
			if page == first_page {
				physical_first_page = physical
			} else if physical != physical_first_page + (page - first_page) {
				log("kernel: TEST BUILD: the edge counters are not in one run of physical pages")
				machine_stop(.Start_Failed)
			}
		}
		log(TEST_BUILD_LINE_EDGE_COUNTERS, physical_first_page + (first - first_page), ", ", count, " edges")
	}

	// edge_counted_mark marks a process that Process_Create made: counted
	// when its name is the name of the runner, or when its creator is
	// counted.
	edge_counted_mark :: proc "contextless" (created, creator: u32, name: []u8) {
		edge_counted_processes[created] = edge_counted_processes[creator] || string(name) == EDGE_COUNTED_PROCESS_NAME
	}

	// edge_counting_set sets or clears the counting word.
	edge_counting_set :: proc "contextless" (counting: bool) {
		edge_counting = counting ? 1 : 0
	}
}
