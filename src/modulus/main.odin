// The kernel: the handle table, memory, the scheduler, the rings and the waits, the device grants and the interrupts (docs/ARCHITECTURE.md, "Kernel systems").
//
// The kernel is the one module that runs in kernel mode. It keeps the
// tables that no process can be trusted to keep: which process holds which
// [handle](term:handle) with which rights, which page frame belongs to which
// [memory object](term:memory-object), which thread runs on which processor.
// Every other part of the system is a process: the device services, the
// storage, the network, the compositor, the console. The kernel has no
// driver, no file system, no network protocol, no loader of modules and no
// name of a user (docs/ARCHITECTURE.md, "What the kernel does not contain").
//
// **What it is for.** A process asks the kernel for a thing with a
// [kernel operation](term:kernel-operation): a record in its kernel ring,
// or a direct entry. The kernel checks the kind and the rights of each
// handle in the record, does the operation, and writes a status. The
// operations, their arguments and their statuses are in
// `src/library/modus/contract/operation/operation.odin`; the page of each operation on the
// site comes from there.
//
// **The five systems.**
//
// - The handle table: one table of handles for each process; the check of
//   the kind and the rights of a handle (`src/modulus/process.odin`).
// - Memory: the page frames, the page tables, the memory objects, the
//   [budgets](term:budget) that pay for each page (`src/modulus/memory.odin`,
//   `src/modulus/virtual_memory.odin`, `src/modulus/paging.odin`).
// - The scheduler: one [run queue](term:run-queue) for each processor, and
//   the [strategy](term:strategy) of the machine (`src/modulus/schedule.odin`,
//   `src/modulus/strategy.odin`; docs/SCHEDULING.md).
// - The rings and the waits: the kernel ring of each process, the
//   [word wait](term:word-wait), the wait on rings (`src/modulus/wait.odin`).
// - The device grants and the interrupts: device memory and message
//   interrupts for a device service (`src/modulus/apic.odin`).
//
// Around them: the [log records](term:log-record) and the serial port
// (`src/modulus/serial.odin`), the [fault ring](term:fault-ring)
// (`src/modulus/fault_ring.odin`), the [kernel events](term:kernel-event)
// (`src/modulus/events.odin`), the [extended state](term:extended-state) of the
// processor (`src/modulus/extended_state.odin`) and the
// [stop report](term:stop-report) (`src/modulus/diagnose.odin`).
//
// **How it starts.** The [boot program](term:boot-program) loads the kernel
// and the [boot image](term:boot-image), builds the first page tables and
// jumps to the export `entry` with the [boot record](term:boot-record). The
// kernel then builds the [root service](term:root-service), the first
// process, and gives it every handle that exists at boot. From that point
// the kernel only answers: every other process is built by a process, with
// kernel operations (docs/ARCHITECTURE.md, "Boot").
//
// **What a reader sees.** The kernel writes its lines to the serial port and
// to the log, from its first steps on: `kernel: <count> processors`,
// `kernel: free memory <size>`, the size and the address of the
// framebuffer, `kernel: ok`, then one line for each [stage](term:stage) of
// the start with its time. The console line
// `processes()` lists the processes that the kernel runs.
//
// The locks of the kernel and their order are in docs/ARCHITECTURE.md,
// "Locks of the kernel".
package kernel

import info "modus:contract/boot_info"
import module "modus:contract/module"
import op "modus:contract/operation"
import "base:intrinsics"

KERNEL_MARK :: "kernel: ok"
ROOT_NAME :: "root"

// entry starts the kernel: the boot program jumps here once, on the first
// processor, with the boot record, and the kernel never returns to it.
//
// **Parameter**: `boot`, the [boot record](term:boot-record) that the boot
// program wrote: the memory map, the framebuffer, the boot image, the debug
// image, the cycle counts of the firmware and of the load, and the
// [self test](term:self-test) to run. The kernel copies it into
// `boot_record`, because the memory of the boot program is not kept.
//
// **What it does**, in order:
//
// 1. It starts the serial port, then checks the magic number of the boot
//    record. A wrong number writes `kernel: the boot record is not valid`
//    and stops the machine with the code 1.
// 2. It takes the free page frames and builds the page table of the kernel
//    (`memory_start`).
// 3. It starts this processor (`processor_start`), chooses the strategy of
//    each run queue (`strategy_start`), then starts the other processors
//    (`processors_start`).
// 4. It writes the count of processors, the free memory and the
//    framebuffer on the log, turns the translation of the IOMMU on when the
//    firmware lists one (`iommu_start`; else one line says that there is
//    none), and writes the mark `kernel: ok`.
// 5. It builds the [root service](term:root-service) from the module
//    `root` of the boot image, and gives it every handle that exists at
//    boot (`root_start`). If that fails, the log names the reason and the
//    machine stops with the code 1.
// 6. It checks the rules of the kernel half of the page tables
//    (`paging_audit`), and writes one log record for each
//    [stage](term:stage) of the start, with its time in microseconds.
// 7. It moves to the kernel stack of this processor, which has guard
//    pages, runs the self test that the boot record names (none in a normal
//    start), and enters the scheduler. The first thread to run is the
//    first thread of the root service.
//
// The entry has no result and no stop code: the machine stops only with
// the operation `Machine_Stop` or a stop of the kernel itself.
@(export, link_name = "entry")
entry :: proc "c" (boot: ^info.Boot_Info) -> ! {
	stage_end(.Boot_Program_Tables)
	serial_start()
	if boot.magic != info.MAGIC {
		log("kernel: the boot record is not valid")
		machine_stop(.Start_Failed)
	}
	boot_record = boot^
	stage_cycles[.Firmware] = boot.cycles_start
	stage_cycles[.Boot_Program_Load] = boot.cycles_loaded
	memory_start(boot)
	stage_end(.Kernel_Memory)
	processor_start()
	stage_end(.Kernel_Processor)
	// The strategy of each run queue, and the lengths in cycles, before
	// another processor reads them (timer_calibrate measured the frequency).
	strategy_start()
	processors_start(boot)
	stage_end(.Kernel_Processors)
	log("kernel: ", u64(processor_count), " processors")
	stolen_time_log()
	log("kernel: free memory ", Size{free_frames * PAGE_SIZE >> 20, .Mebibytes})
	log("kernel: framebuffer ", u64(boot.framebuffer.width), "x", u64(boot.framebuffer.height), " at ", Hex(boot.framebuffer.address))
	when KERNEL_EDGE_COUNTERS {
		edge_counters_start()
	}
	// Before any device service: from translation on, a device reaches only
	// the memory that its service declares.
	iommu_start(boot)
	log(KERNEL_MARK)
	control_take()
	root_start(boot)
	control_free()
	intrinsics.atomic_store(&root_started, true)
	stage_end(.Kernel_Root)
	paging_audit()
	// Each stage lasts from the end of the stage before it; the firmware,
	// the first one, from 0.
	stage_before_end := u64(0)
	for stage in Stage {
		log_with_level(.Info, "kernel: boot: ", STAGE_NAMES[stage], ": ", Duration{microseconds(stage_cycles[stage] - stage_before_end), .Microseconds})
		stage_before_end = stage_cycles[stage]
	}
	// The stack of the boot program has no guard pages: the processor
	// continues on its own kernel stack.
	stack_switch(processors[0].stack_top, rawptr(first_run))
}

first_run :: proc "c" () -> ! {
	// The boot program writes the word of the test: a word that names no
	// test stops the machine, so the kernel runs no test and no normal boot
	// that the boot program did not name.
	test, test_known := info.self_test_of_word(boot_record.self_test)
	if !test_known {
		log("kernel: the boot record names the self test ", boot_record.self_test, ", which names no test")
		machine_stop(.Start_Failed)
	}
	self_test(test, &boot_record)
	schedule()
}

// debug_image_pages checks the range of the debug image that the boot
// program gives: on a page, inside the bound, and inside one range of the
// memory of the boot, which the kernel never gives as a free frame. A
// memory object over other memory would let the root service read and
// give pages that the kernel uses.
debug_image_pages :: proc "contextless" (boot: ^info.Boot_Info) -> (pages: u64, accepted: bool) {
	start, size := boot.debug_image, boot.debug_image_size
	if start == 0 || start % PAGE_SIZE != 0 || size == 0 || size > info.DEBUG_IMAGE_LIMIT || start > max(u64) - info.DEBUG_IMAGE_LIMIT - PAGE_SIZE {
		return 0, false
	}
	pages = (size + PAGE_SIZE - 1) / PAGE_SIZE
	end := start + pages * PAGE_SIZE
	for range in info.physical_slice(boot.memory_ranges, boot.memory_range_count, info.Memory_Range) {
		if range.kind != .Boot || range.page_count > (max(u64) - range.start) / PAGE_SIZE {
			continue
		}
		if start >= range.start && end <= range.start + range.page_count * PAGE_SIZE {
			return pages, true
		}
	}
	return 0, false
}

// root_start builds the first process from the module "root" of the boot
// image. Every other process is built by a process, with kernel operations.
root_start :: proc "contextless" (boot: ^info.Boot_Info) {
	fail :: proc "contextless" (text: string) -> ! {
		log("kernel: cannot start the root service: ", text)
		machine_stop(.Start_Failed)
	}
	image := info.physical_slice(boot.boot_image, boot.boot_image_size, u8)
	if len(image) < size_of(info.Image_Header) || (^info.Image_Header)(raw_data(image)).magic != info.IMAGE_MAGIC {
		fail("the boot image is not valid")
	}
	file: []u8
	hash: [32]u8 // As the boot image names it.
	entries := ([^]info.Image_Entry)(raw_data(image[size_of(info.Image_Header):]))[:(^info.Image_Header)(raw_data(image)).count]
	for &item in entries {
		name := ROOT_NAME
		if string(item.name[:len(name)]) == name && item.name[len(name)] == 0 {
			file = image[item.offset:][:item.size]
			hash = item.hash
		}
	}
	if file == nil || module.validate(file) != .None {
		fail("the boot image has no valid module \"root\"")
	}
	head, _ := module.header(file)
	name := ROOT_NAME
	// The time page is memory of the kernel: no budget has it.
	if !time_page_create() {
		fail("no memory for the time page")
	}
	// The one budget that comes from nothing: all the free memory, all the
	// slots, and the log records of each second of the whole machine.
	ROOT_BUDGET :: 1
	budgets[ROOT_BUDGET] = {
		live = true,
		amounts = {pages = free_frames, processes = PROCESS_CAPACITY - 1, threads = THREAD_TABLE_CAPACITY - 1, processor = u64(processor_count) * 1_000_000, log_records = op.LOG_RECORDS_OF_THE_MACHINE},
	}
	index, _ := process_create(ROOT_BUDGET, transmute([]u8)name)
	// The kernel writes the module and the context through the direct map:
	// these two are contiguous. The stack has its pages on first use.
	code, _ := region_create(ROOT_BUDGET, head.memory_size / PAGE_SIZE, contiguous = true)
	stack, _ := region_create(ROOT_BUDGET, op.STACK_PAGES)
	ctx, _ := region_create(ROOT_BUDGET, 1, contiguous = true)
	if index == 0 || code == 0 || stack == 0 || ctx == 0 {
		fail("no memory")
	}
	process := &processes[index]
	taken := process_lock(index)
	defer process_unlock(index, taken)
	// The kernel is the starter of the root service: the record is of the
	// writer Starter, which the root service cannot change.
	process_module(process, {base = op.PROCESS_BASE, size = head.memory_size, hash = hash}, by_the_process = false)
	memory := info.physical_slice(regions[code].physical, head.memory_size, u8)
	module.copy_segments(file, memory)
	// The root service has no loader for imports: the kernel writes its
	// own-hash place and the index of each record stream, as a loader
	// writes the places of each module.
	if module.rebase(file, memory, op.PROCESS_BASE) != .None || module.count(file, .Imports) > 1 || !module.own_hash_write(file, memory, hash) || !module.record_stream_indexes_write(file, memory) {
		fail("the module cannot be loaded")
	}
	for segment_index in 1 ..< module.count(file, .Segments) {
		segment, _ := module.record(file, .Segments, segment_index, module.Segment)
		flags: op.Map_Flags
		if .Write in segment.flags && .Read_Only_After_Load not_in segment.flags {
			flags += {.Write}
		}
		if .Execute in segment.flags {
			flags += {.Execute}
		}
		if _, status := map_region(process, code, op.PROCESS_BASE + segment.memory_offset, flags, segment.memory_offset / PAGE_SIZE, segment.memory_size / PAGE_SIZE); status != .Ok {
			fail("a segment cannot be mapped")
		}
	}
	_, stack_status := map_region(process, stack, op.STACK_TOP - op.STACK_PAGES * PAGE_SIZE, {.Write}, 0, 0)
	_, context_status := map_region(process, ctx, op.CONTEXT_ADDRESS, {.Write}, 0, 0)
	start, has_entry := module.export_address(file, op.PROCESS_BASE, head.entry_export)
	if stack_status != .Ok || context_status != .Ok || !has_entry {
		fail("the module has no entry")
	}

	// The root service receives every handle that exists at boot.
	record := direct(regions[ctx].physical, op.Context)
	record.handles[op.CONTEXT_BUDGET] = handle_insert(process, {kind = .Budget, rights = RIGHTS_BUDGET, object = ROOT_BUDGET})
	record.handles[op.CONTEXT_LOG] = handle_insert(process, {kind = .Log, rights = RIGHTS_LOG})
	if log_head != nil {
		log_region = region_device(physical_of(log_head), op.LOG_PAGES)
		record.handles[op.ROOT_LOG_RECORDS] = handle_insert(process, {kind = .Memory, rights = {.Give, .Read}, object = log_region})
	}
	record.handles[op.ROOT_MACHINE] = handle_insert(process, {kind = .Machine, rights = RIGHTS_MACHINE})
	framebuffer := boot.framebuffer
	if framebuffer.format != .None {
		pages := (u64(framebuffer.pixels_per_line) * u64(framebuffer.height) * 4 + PAGE_SIZE - 1) / PAGE_SIZE
		record.handles[op.ROOT_FRAMEBUFFER] = handle_insert(process, {kind = .Memory, rights = {.Give, .Read, .Write}, object = region_device(framebuffer.address, pages)})
		record.values[op.ROOT_VALUE_WIDTH] = u64(framebuffer.width)
		record.values[op.ROOT_VALUE_HEIGHT] = u64(framebuffer.height)
		record.values[op.ROOT_VALUE_PIXELS_PER_LINE] = u64(framebuffer.pixels_per_line)
		record.values[op.ROOT_VALUE_FORMAT] = u64(framebuffer.format)
	}
	record.handles[op.ROOT_BOOT_IMAGE] = handle_insert(process, {kind = .Memory, rights = {.Give, .Read}, object = region_device(boot.boot_image, (boot.boot_image_size + PAGE_SIZE - 1) / PAGE_SIZE)})
	record.values[op.ROOT_VALUE_BOOT_IMAGE_SIZE] = boot.boot_image_size
	// The debug image: the kernel gives its pages and reads none of them
	// (docs/MODULE_CONTRACT.md, "Debug information").
	if boot.debug_image_size != 0 {
		if pages, accepted := debug_image_pages(boot); accepted {
			record.handles[op.ROOT_DEBUG_IMAGE] = handle_insert(process, {kind = .Memory, rights = {.Give, .Read}, object = region_device(boot.debug_image, pages)})
			record.values[op.ROOT_VALUE_DEBUG_IMAGE_SIZE] = boot.debug_image_size
		} else {
			log("kernel: the debug image of the boot program is refused: its range is not on a page, is over its bound, or is not memory of the boot; a stop report names no procedure")
		}
	}

	if _, status := thread_create(index, ROOT_BUDGET, u64(start), op.STACK_TOP, op.CONTEXT_ADDRESS); status != .Ok {
		fail("no memory for the first thread")
	}
	process.state = .Ready
}
