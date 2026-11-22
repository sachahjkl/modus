package kernel

import info "modus:contract/boot_info"
import "modulus:acpi_processors"
import "base:intrinsics"

// The start of the other processors of x86-64: the start code at a page of
// the first MiB, and the reset and start messages of the interrupt
// controller. A browser machine starts its processors as workers of the
// page (processors_start_wasm64p32.odin).

// The parameters at the end of the start code: see processor.asm.
Ap_Parameters :: struct {
	table:     u32,
	cr0:       u32,
	efer:      u32,
	mxcsr:     u32,
	stack:     u64,
	parameter: u64,
	entry:     u64,
}

AP_BASE :: 0x8000
started_count: u32
first_cr4: u64

foreign _ {
	ap_start_begin: u8
	ap_start_end: u8
}

// processors_start starts each other processor. The first processor runs
// it once. A new processor looks for a thread in the run queues.
processors_start :: proc "contextless" (boot: ^info.Boot_Info) {
	direct_map_size = boot.direct_map_size
	ids: [PROCESSOR_CAPACITY]u32
	count, absence := processors_find(boot.acpi_root, ids[:])
	if absence != .None {
		log("kernel: ", acpi_processors.TABLE_ABSENCE_TEXTS[absence], ": one processor")
		return
	}
	// One listed processor is this one: a machine of one processor, with
	// no line.
	if count <= 1 {
		return
	}
	// The start code runs at a fixed page of the first MiB. The kernel
	// keeps the first MiB out of the page frames that it gives.
	page_free := false
	for range in info.physical_slice(boot.memory_ranges, boot.memory_range_count, info.Memory_Range) {
		if kind, ok := info.memory_kind_of_word(range.kind); ok && kind == .Free && range.start <= AP_BASE && AP_BASE + PAGE_SIZE <= range.start + range.page_count * PAGE_SIZE {
			page_free = true
		}
	}
	// A processor starts with 32-bit addresses. Its first page table maps
	// the low addresses to the same physical addresses.
	table := frames_allocate(1)
	if !page_free || table == 0 || table >= 1 << 32 {
		log("kernel: cannot start the other processors: no low memory for the start code")
		if table != 0 {
			frames_free(table, 1)
		}
		return
	}
	direct(table, [512]u64)^ = direct(kernel_table, [512]u64)^
	// The start code executes at low addresses: this view of memory is executable.
	direct(table, [512]u64)[0] = direct(table, [512]u64)[DIRECT_MAP_INDEX] &~ PAGE_NO_EXECUTE

	code_size := int(uintptr(&ap_start_end) - uintptr(&ap_start_begin))
	code := ([^]u8)(direct(AP_BASE, u8))
	intrinsics.mem_copy_non_overlapping(code, &ap_start_begin, code_size)
	parameters := (^Ap_Parameters)(&code[code_size - size_of(Ap_Parameters)])
	parameters.table = u32(table)
	parameters.cr0 = u32(control_register_0_read())
	// Not the bit "long mode is active": the processor sets it. Not SVM: a
	// processor turns it on in its setup, after it checked that it has it.
	parameters.efer = u32(model_specific_register_read(0xC000_0080) &~ (1 << 10 | EFER_SECURE_VIRTUAL_MACHINE))
	parameters.entry = u64(uintptr(rawptr(processor_entry)))
	first_cr4 = control_register_4_read()

	self := apic_id()
	for id in ids[:count] {
		if id == self || processor_count == PROCESSOR_CAPACITY {
			continue
		}
		cpu := processor_create(processor_count, id)
		if cpu == nil {
			break
		}
		parameters.stack = cpu.stack_top
		parameters.parameter = u64(uintptr(cpu))
		before := intrinsics.atomic_load(&started_count)
		// The waits use the cycle counter: the 8254 can be absent, and the
		// calibration measured the counter, or took the frequency that the
		// processor states.
		// Reset. A controller that does not send it sends no start either:
		// no other processor starts. No start was sent, so nothing ran from
		// the record and the stacks of this processor, and they are freed.
		if !apic_send(id, 0x4500) {
			log("kernel: the interrupt controller did not send the reset of the processor ", u64(id), ": no other processor starts")
			stacks_free(cpu.index)
			frames_free(physical_of(cpu), (size_of(Processor) + PAGE_SIZE - 1) / PAGE_SIZE)
			break
		}
		cycles_wait(10_000)
		started := false
		start: for _ in 0 ..< 2 {
			// The result does not decide: a start that the controller sent
			// late can still start the processor, and started_count, then
			// the reset below, decide.
			apic_send(id, 0x4600 | AP_BASE >> 12) // Start at the page.
			for _ in 0 ..< 100 {
				cycles_wait(1_000)
				if intrinsics.atomic_load(&started_count) != before {
					started = true
					break start
				}
			}
		}
		if started && intrinsics.atomic_load(&cpu.extended_state_refused) {
			log("kernel: the processor ", u64(id), " cannot save the extended state that the first processor saves, or takes other bits of MXCSR: it stays stopped")
			started = false
		} else if !started {
			log("kernel: the processor ", u64(id), " did not start")
		}
		if !started {
			// It stays in reset: its record ends. A reset that the controller
			// did not send leaves a processor that can still run from its
			// record, from the stacks of its index and from the page table
			// of the start: they stay taken for ever, and no other processor
			// starts, since the next one would take the same index.
			if !apic_send(id, 0x4500) {
				log("kernel: the interrupt controller did not send the reset of the processor ", u64(id), ": its record, its stacks and the page table of the start stay taken, and no other processor starts")
				when KERNEL_EDGE_COUNTERS {
					// That processor can still run compiled code, which
					// the counted kernel would count (edge_counters_start).
					edge_counters_processor_not_reset = true
				}
				return
			}
			cycles_wait(10_000)
			stacks_free(cpu.index)
			frames_free(physical_of(cpu), (size_of(Processor) + PAGE_SIZE - 1) / PAGE_SIZE)
			continue
		}
		// The processor waits for this before it gives the host the address
		// of a record in its processor record (stolen_time.odin).
		intrinsics.atomic_store(&cpu.start_accepted, true)
		processors[processor_count] = cpu
		processor_count += 1
	}
	frames_free(table, 1)
}

// processor_entry is where each other processor arrives from the start code.
processor_entry :: proc "c" (cpu: ^Processor) -> ! {
	control_register_3_write(kernel_table)
	// Not OSXSAVE: a processor with no xsave faults on it. The setup of the
	// extended state sets it when this processor can save what the first
	// processor saves.
	control_register_4_write(first_cr4 &~ CR4_OSXSAVE)
	if !extended_state_other_setup(cpu) {
		// The first processor sees started_count move, reads the flag, logs
		// it, and resets this processor.
		intrinsics.atomic_store(&cpu.extended_state_refused, true)
		intrinsics.atomic_add(&started_count, 1)
		processor_stop()
	}
	processor_setup(cpu)
	timer_start()
	intrinsics.atomic_add(&started_count, 1)
	// A processor that the first processor did not see in time is reset,
	// and its processor record is freed: the host must never get the
	// address of a steal-time record in it. So the registration waits for
	// the acceptance, which a late processor never gets before its reset.
	for !intrinsics.atomic_load(&cpu.start_accepted) {
		intrinsics.cpu_relax()
	}
	stolen_time_processor_setup(cpu)
	schedule()
}
