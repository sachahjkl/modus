package kernel

import info "modus:contract/boot_info"
import "modulus:acpi_processors"
import "modulus:time_base"
import "base:intrinsics"

// The interrupt controller of each processor (local APIC): the timer, and
// the interrupts that one processor sends to another. It also holds the
// search of the processors in the ACPI tables, and their start.
//
// The 16 device lines stay on the 8259, which interrupts the first
// processor. A device with more needs sends its interrupts to a local APIC
// by a message; no device does that yet.

MSR_APIC_BASE :: 0x1B
APIC_ID :: 0x20
APIC_PRIORITY :: 0x80
APIC_END :: 0xB0
APIC_SPURIOUS :: 0xF0
APIC_SEND_LOW :: 0x300
APIC_SEND_HIGH :: 0x310
APIC_TIMER :: 0x320
APIC_LINE_0 :: 0x350
APIC_ERROR :: 0x370
APIC_TIMER_START :: 0x380
APIC_TIMER_NOW :: 0x390
APIC_TIMER_DIVIDE :: 0x3E0
APIC_MASKED :: 1 << 16
APIC_PERIODIC :: 1 << 17

apic_msr: bool // The registers are model-specific registers (x2APIC), not memory.
apic_address: uintptr
timer_count: u32 // The counts of the timer in one tick.
direct_map_size: u64

apic_read :: proc "contextless" (register: u32) -> u32 {
	if apic_msr {
		return u32(model_specific_register_read(0x800 + register >> 4))
	}
	return intrinsics.volatile_load((^u32)(apic_address + uintptr(register)))
}

apic_write :: proc "contextless" (register: u32, value: u32) {
	if apic_msr {
		model_specific_register_write(0x800 + register >> 4, u64(value))
	} else {
		intrinsics.volatile_store((^u32)(apic_address + uintptr(register)), value)
	}
}

apic_id :: proc "contextless" () -> u32 {
	return apic_msr ? apic_read(APIC_ID) : apic_read(APIC_ID) >> 24
}

// The bit of the send register that says that the controller has not sent
// the interrupt yet. The x2APIC has no such bit: its write sends.
APIC_SEND_PENDING :: 1 << 12
// How long a send waits for that bit. A controller sends in a few
// microseconds; one that has not sent in this time is broken, and a wake
// path that waits for it for ever would stop its processor with its locks.
APIC_SEND_BOUND_MICROSECONDS :: 10_000
// The sends that did not leave in their bound. A sender can hold the run
// lock, which comes after the log lock, so it cannot write a line: the
// tick writes the count (delivery_faults_log).
apic_sends_not_sent: u64

// apic_send sends an interrupt to the processor with this identifier.
// value is a vector, or a start command. false: the controller did not
// send it within APIC_SEND_BOUND_MICROSECONDS, and the send is counted.
apic_send :: proc "contextless" (id: u32, value: u32) -> (sent: bool) {
	if apic_msr {
		model_specific_register_write(0x800 + APIC_SEND_LOW >> 4, u64(id) << 32 | u64(value))
		return true
	}
	apic_write(APIC_SEND_HIGH, id << 24)
	apic_write(APIC_SEND_LOW, value)
	end := time_base.deadline(cycles_now(), APIC_SEND_BOUND_MICROSECONDS, cycle_frequency)
	for apic_read(APIC_SEND_LOW) & APIC_SEND_PENDING != 0 {
		if cycles_now() >= end {
			intrinsics.atomic_add(&apic_sends_not_sent, 1)
			return false
		}
		intrinsics.cpu_relax()
	}
	return true
}

// apic_start finds the registers. The first processor runs it once.
apic_start :: proc "contextless" () {
	base := model_specific_register_read(MSR_APIC_BASE)
	if base & (1 << 11) == 0 {
		base |= 1 << 11
		model_specific_register_write(MSR_APIC_BASE, base)
	}
	apic_msr = base & (1 << 10) != 0
	apic_address = info.DIRECT_MAP_BASE + uintptr(base & 0x000F_FFFF_FFFF_F000)
}

// apic_setup prepares the controller of the processor that runs it.
apic_setup :: proc "contextless" (cpu: ^Processor) {
	base := model_specific_register_read(MSR_APIC_BASE)
	if apic_msr && base & (1 << 10) == 0 {
		model_specific_register_write(MSR_APIC_BASE, base | 1 << 10 | 1 << 11)
	}
	apic_write(APIC_PRIORITY, 0)
	apic_write(APIC_SPURIOUS, 0x100 | VECTOR_SPURIOUS)
	apic_write(APIC_ERROR, APIC_MASKED)
	// The 8259 interrupts the first processor only.
	apic_write(APIC_LINE_0, cpu.index == 0 ? 0x700 : APIC_MASKED)
}

// The bit of the port 0x61 that is the output of channel 2 of the 8254.
PIT_OUTPUT :: 0x20
// The bound of a wait for the 8254: one second at the highest frequency
// that the kernel takes, so a hundred times the wait of the calibration on
// any processor. A host that stops the machine for a while then does not
// make the kernel call a working 8254 absent.
PIT_WAIT_BOUND_MICROSECONDS :: 1_000_000
// The starts of a count before the kernel takes a high output as no 8254.
// A real 8254 does not count while its gate is low, so its output is low
// at the read. An emulation that ignores the gate in this mode, such as
// QEMU or the 8254 of KVM, counts from the write of the count: a host that
// stops the machine for the whole count before the read gives a high
// output once. An absent 8254 gives it at each start.
PIT_START_ATTEMPTS :: 3

// pit_wait waits with the 8254 timer, channel 2. At most 50000
// microseconds. false: the 8254 does not count. Its output is high before
// the count starts, as a read of a port with no device gives, or it is not
// high after PIT_WAIT_BOUND_MICROSECONDS. At each start it also starts the
// timer of the processor from its largest count, just after the gate goes
// high, and gives the cycle counter of that moment: a start that is tried
// again puts none of the time of the earlier start in the measures.
pit_wait :: proc "contextless" (microseconds: u64) -> (counted: bool, cycles_at_start: u64) {
	count := microseconds * 1193182 / 1_000_000
	for _ in 0 ..< PIT_START_ATTEMPTS {
		port_write_8(0x61, port_read_8(0x61) &~ 3) // The gate is low: the count does not run.
		port_write_8(0x43, 0xB0) // Channel 2, one count, then the output goes high.
		port_write_8(0x42, u8(count))
		port_write_8(0x42, u8(count >> 8))
		// The write of the mode makes the output low until the end of the count.
		if port_read_8(0x61) & PIT_OUTPUT != 0 {
			continue
		}
		port_write_8(0x61, port_read_8(0x61) &~ 2 | 1)
		apic_write(APIC_TIMER_START, max(u32))
		cycles_at_start = cycles_now()
		end := time_base.deadline(cycles_at_start, PIT_WAIT_BOUND_MICROSECONDS, cycle_frequency)
		for port_read_8(0x61) & PIT_OUTPUT == 0 {
			if cycles_now() >= end {
				return false, 0
			}
			intrinsics.cpu_relax()
		}
		return true, cycles_at_start
	}
	return false, 0
}

// cycles_wait waits with the cycle counter, after the calibration.
cycles_wait :: proc "contextless" (microseconds: u64) {
	end := time_base.deadline(cycles_now(), microseconds, cycle_frequency)
	for cycles_now() < end {
		intrinsics.cpu_relax()
	}
}

// time_base_identification reads the leaves of CPUID that state the
// frequency of the cycle counter; a leaf above the highest is not read,
// and neither is a leaf of a processor that is not of Intel.
time_base_identification :: proc "contextless" () -> (identification: time_base.Identification) {
	vendor_b, vendor_c, vendor_d: u32
	identification.highest_leaf, vendor_b, vendor_c, vendor_d = intrinsics.x86_cpuid(0, 0)
	identification.vendor_is_intel = time_base.is_intel_signature(vendor_b, vendor_c, vendor_d)
	if !identification.vendor_is_intel {
		return
	}
	if identification.highest_leaf >= time_base.FREQUENCY_RATIO_LEAF {
		identification.ratio_denominator, identification.ratio_numerator, identification.crystal_hertz, _ = intrinsics.x86_cpuid(time_base.FREQUENCY_RATIO_LEAF, 0)
	}
	if identification.highest_leaf >= time_base.BASE_FREQUENCY_LEAF {
		identification.base_frequency, _, _, _ = intrinsics.x86_cpuid(time_base.BASE_FREQUENCY_LEAF, 0)
	}
	return
}

// timer_calibrate measures the timer of the processor and the cycle
// counter against the 8254. When the 8254 does not count, the time base is
// the frequency of the cycle counter that the processor states, and the
// timer is measured against the cycle counter. With neither, the kernel
// cannot keep time, and stops.
timer_calibrate :: proc "contextless" () {
	MEASURE_TICKS :: 10
	MEASURE_MICROSECONDS :: MEASURE_TICKS * 1_000_000 / TICKS_PER_SECOND
	apic_write(APIC_TIMER_DIVIDE, 3) // Divide by 16.
	apic_write(APIC_TIMER, APIC_MASKED)
	// pit_wait starts the timer of the processor at the start of its count.
	if counted, cycles := pit_wait(MEASURE_MICROSECONDS); counted {
		timer_count = (max(u32) - apic_read(APIC_TIMER_NOW)) / MEASURE_TICKS
		// The same wait measures the cycle counter: the boot record uses it.
		cycle_frequency = (cycles_now() - cycles) * TICKS_PER_SECOND / MEASURE_TICKS
	} else {
		hertz, absence := time_base.stated_frequency(time_base_identification())
		if absence != .None {
			log("kernel: the 8254 does not count, and the processor states no frequency of its cycle counter (", time_base.ABSENCE_TEXTS[absence], "): the kernel has no time base")
			machine_stop(.Start_Failed)
		}
		// The timer starts again: the failed wait ran it for up to its bound.
		apic_write(APIC_TIMER_START, max(u32))
		end := time_base.deadline(cycles_now(), MEASURE_MICROSECONDS, hertz)
		for cycles_now() < end {
			intrinsics.cpu_relax()
		}
		timer_count = (max(u32) - apic_read(APIC_TIMER_NOW)) / MEASURE_TICKS
		cycle_frequency = hertz
		log("kernel: the 8254 does not count: the time base is the cycle counter, at ", hertz, " Hz, which the processor states in CPUID")
	}
	apic_write(APIC_TIMER_START, 0)
	if timer_count == 0 {
		log("kernel: the timer of the processor does not count")
		machine_stop(.Start_Failed)
	}
}

// timer_start starts the tick of the processor that runs it.
timer_start :: proc "contextless" () {
	apic_write(APIC_TIMER_DIVIDE, 3)
	apic_write(APIC_TIMER, VECTOR_TIMER | APIC_PERIODIC)
	apic_write(APIC_TIMER_START, timer_count)
}

// timer_pause stops, or continues, the tick of the processor that runs it.
// An idle processor needs no tick, except the first processor: it counts
// the time.
timer_pause :: proc "contextless" (pause: bool) {
	apic_write(APIC_TIMER, VECTOR_TIMER | APIC_PERIODIC | (pause ? APIC_MASKED : 0))
}

// acpi_bytes gives count bytes of physical memory, or nil if the direct
// map does not hold them.
@(private = "file")
acpi_bytes :: proc "contextless" (address: u64, count: u64) -> [^]u8 {
	// No sum: an address of the firmware near 2^64 would wrap it.
	if address == 0 || count > direct_map_size || address > direct_map_size - count {
		return nil
	}
	return ([^]u8)(direct(address, u8))
}

@(private = "file")
load :: proc "contextless" (bytes: [^]u8, offset: u64, $T: typeid) -> T {
	return intrinsics.unaligned_load((^T)(&bytes[offset]))
}

ACPI_HEADER_SIZE :: 36

// acpi_table gives the ACPI table with this signature, and its size. The
// IOMMU reads the tables DMAR and MCFG with it (iommu.odin).
acpi_table :: proc "contextless" (root: u64, signature: string) -> (table: [^]u8, size: u64) {
	record := acpi_bytes(root, 36)
	if record == nil || string(record[:8]) != "RSD PTR " {
		return nil, 0
	}
	list_address := u64(load(record, 16, u32))
	entry_size := u64(4)
	if record[15] >= 2 && load(record, 24, u64) != 0 {
		list_address = load(record, 24, u64)
		entry_size = 8
	}
	list := acpi_bytes(list_address, ACPI_HEADER_SIZE)
	if list == nil {
		return nil, 0
	}
	list_size := u64(load(list, 4, u32))
	if acpi_bytes(list_address, list_size) == nil {
		return nil, 0
	}
	for offset := u64(ACPI_HEADER_SIZE); offset + entry_size <= list_size; offset += entry_size {
		address := entry_size == 8 ? load(list, offset, u64) : u64(load(list, offset, u32))
		table = acpi_bytes(address, ACPI_HEADER_SIZE)
		if table == nil || string(table[:4]) != signature {
			continue
		}
		size = u64(load(table, 4, u32))
		if acpi_bytes(address, size) != nil {
			return table, size
		}
	}
	return nil, 0
}

// processors_find reads the identifiers of the processors that the firmware
// lists as usable, and why the table gives none. The reader of the table is
// a kernel part, so that the host reads the same bytes in its tests and its
// fuzz target.
@(private = "file")
processors_find :: proc "contextless" (root: u64, ids: []u32) -> (count: int, absence: acpi_processors.Table_Absence) {
	table, size := acpi_table(root, "APIC")
	if table == nil {
		return 0, acpi_processors.table_absence(false, nil, 0)
	}
	count = acpi_processors.processors_read(table[:size], apic_msr, ids)
	return count, acpi_processors.table_absence(true, table[:size], count)
}

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
		if range.kind == .Free && range.start <= AP_BASE && AP_BASE + PAGE_SIZE <= range.start + range.page_count * PAGE_SIZE {
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
