package kernel

// The instructions of the processor on a browser machine
// (src/md/features/browser_machine.md, "What the arch layer becomes"). Each
// procedure here has the name and the signature of its instruction template
// in instructions_amd64.odin, so the kernel above the arch layer is the same
// source on both targets.
//
// WebAssembly has no control register, no model-specific register and no
// port. Each worker of the page is one processor and holds one instance of
// the kernel, so the registers of that processor are globals of the
// instance: the register file below. The page tables that the kernel writes
// keep the format of x86-64; the software processor walks them for the code
// of processes, so a write of cr3 and a page flush reach its translation
// cache.

import "base:intrinsics"
import software "modus:contract/software_machine"
import "modulus:process_memory"

// The imports that the page gives to each instance of the kernel. The
// device models of the page play the ports (browser_machine.md, "Ports and
// registers").
foreign import page "modus_page"

@(default_calling_convention = "contextless")
foreign page {
	page_port_write_8 :: proc(port: u16, value: u8) ---
	page_port_read_8 :: proc(port: u16) -> u8 ---
	// performance.timeOrigin + performance.now(), in nanoseconds: one clock
	// for all the workers (browser_machine.md, "The timer and the cycle
	// counter").
	page_clock_nanoseconds :: proc() -> u64 ---
}

// The capacity of the table of model-specific registers. The kernel writes
// fewer than this many distinct registers on its paths.
MODEL_SPECIFIC_REGISTER_CAPACITY :: 32

Model_Specific_Register_Slot :: struct {
	index:  u32,
	in_use: bool,
	value:  u64,
}

// The register file of the processor of this instance.
Software_Processor_Registers :: struct {
	control_register_0:          u64,
	control_register_2:          u64,
	control_register_4:          u64,
	extended_control_register_0: u64,
	debug_registers:             [8]u64,
	task_register:               u16,
	model_specific_registers:    [MODEL_SPECIFIC_REGISTER_CAPACITY]Model_Specific_Register_Slot,
}

// The linear memory is shared by the workers, so the register file of each
// processor is a thread-local of its instance.
@(thread_local)
software_processor_registers: Software_Processor_Registers

// The software processor that runs the code of processes on this
// processor. Its cr3 is the page table of the kernel, and its gs base is
// the gs register of the process (MSR_KERNEL_GS_BASE in the kernel).
@(thread_local)
software_processor: software.Processor_State

port_write_8 :: #force_inline proc "contextless" (port: u16, value: u8) {
	page_port_write_8(port, value)
}

port_read_8 :: #force_inline proc "contextless" (port: u16) -> u8 {
	return page_port_read_8(port)
}

// The cycle counter of a browser machine is the clock of the page, at
// 1 GHz.
cycles_now :: #force_inline proc "contextless" () -> u64 {
	return page_clock_nanoseconds()
}

@(private = "file")
model_specific_register_slot :: proc "contextless" (index: u32, take_free: bool) -> ^Model_Specific_Register_Slot {
	registers := &software_processor_registers
	free: ^Model_Specific_Register_Slot
	for &slot in registers.model_specific_registers {
		if slot.in_use && slot.index == index {
			return &slot
		}
		if !slot.in_use && free == nil {
			free = &slot
		}
	}
	if take_free && free != nil {
		free.in_use = true
		free.index = index
		free.value = 0
		return free
	}
	return nil
}

// A register that the kernel never wrote reads 0, as a register that the
// firmware left clear.
model_specific_register_read :: proc "contextless" (index: u32) -> u64 {
	if index == MSR_KERNEL_GS_BASE {
		return software_processor.gs_base
	}
	slot := model_specific_register_slot(index, false)
	if slot == nil {
		return 0
	}
	return slot.value
}

// model_specific_register_is_known says whether the register exists on this
// processor: the gs register of the process, or a register that the kernel
// wrote.
model_specific_register_is_known :: proc "contextless" (index: u32) -> bool {
	return index == MSR_KERNEL_GS_BASE || model_specific_register_slot(index, false) != nil
}

// A write past the capacity of the table is a fault of the kernel: it
// stops the instance, as a general protection fault of the kernel stops a
// processor.
model_specific_register_write :: proc "contextless" (index: u32, value: u64) {
	if index == MSR_KERNEL_GS_BASE {
		software_processor.gs_base = value
		return
	}
	slot := model_specific_register_slot(index, true)
	if slot == nil {
		intrinsics.trap()
	}
	slot.value = value
}

extended_control_register_write :: #force_inline proc "contextless" (index: u32, value: u64) {
	if index == 0 {
		software_processor_registers.extended_control_register_0 = value
	}
}

control_register_0_read :: #force_inline proc "contextless" () -> u64 {
	return software_processor_registers.control_register_0
}

control_register_0_write :: #force_inline proc "contextless" (value: u64) {
	software_processor_registers.control_register_0 = value
}

debug_register_6_write :: #force_inline proc "contextless" (value: u64) {
	software_processor_registers.debug_registers[6] = value
}

debug_register_6_read :: #force_inline proc "contextless" () -> u64 {
	return software_processor_registers.debug_registers[6]
}

debug_register_0_write :: #force_inline proc "contextless" (value: u64) {
	software_processor_registers.debug_registers[0] = value
}

debug_register_1_write :: #force_inline proc "contextless" (value: u64) {
	software_processor_registers.debug_registers[1] = value
}

debug_register_2_write :: #force_inline proc "contextless" (value: u64) {
	software_processor_registers.debug_registers[2] = value
}

debug_register_3_write :: #force_inline proc "contextless" (value: u64) {
	software_processor_registers.debug_registers[3] = value
}

debug_register_7_write :: #force_inline proc "contextless" (value: u64) {
	software_processor_registers.debug_registers[7] = value
}

// The exit path of the software processor copies the address of a page
// fault here before the kernel reads it, as the processor writes cr2.
control_register_2_read :: #force_inline proc "contextless" () -> u64 {
	return software_processor_registers.control_register_2
}

control_register_3_read :: #force_inline proc "contextless" () -> u64 {
	return software_processor.cr3
}

// A new page table empties the translation cache of the software
// processor, as a write of cr3 empties the TLB.
control_register_3_write :: #force_inline proc "contextless" (value: u64) {
	software.processor_set_cr3(&software_processor, value)
}

control_register_4_read :: #force_inline proc "contextless" () -> u64 {
	return software_processor_registers.control_register_4
}

control_register_4_write :: #force_inline proc "contextless" (value: u64) {
	software_processor_registers.control_register_4 = value
}

page_flush :: #force_inline proc "contextless" (address: u64) {
	software.processor_invlpg(&software_processor, address)
}

// The linear memory has no cache that a reader of memory misses: each
// worker and each device model reads the same bytes. The fence keeps the
// order of the writes before it, as clflush does.
cache_line_write_back :: #force_inline proc "contextless" (address: rawptr) {
	intrinsics.atomic_thread_fence(.Seq_Cst)
}

// The software processor delivers no vector through a table: its exits
// are the interrupts (browser_machine.md, "The processor loop"). The
// descriptor is a local of the caller, so nothing keeps it.
interrupt_table_load :: #force_inline proc "contextless" (descriptor: rawptr) {
}

task_register_load :: #force_inline proc "contextless" (selector: u16) {
	software_processor_registers.task_register = selector
}

// The kernel writes the address of the record of its processor to
// MSR_GS_BASE at the start of the processor, as on hardware; the field
// self is at offset 16 of the record on both targets. Before that write,
// the register reads 0, and a read through it would take the bytes at
// offset 16 of the linear memory as a record: the instance stops, as a
// read of gs:16 with no base faults on x86-64.
processor_self :: #force_inline proc "contextless" () -> ^Processor {
	record := model_specific_register_read(MSR_GS_BASE)
	if record == 0 {
		intrinsics.trap()
	}
	return (^Processor)(uintptr(record)).self
}

// The answer of cpuid on a browser machine: the baseline of x86-64 with
// SSE2, the answer that the software processor gives to processes
// (browser_machine.md, "The other instructions"). It names no APIC, no
// xsave, no virtualization, no processor counters and no hypervisor, so
// the kernel takes the paths of a machine that lacks them.
IDENTIFICATION_HIGHEST_BASIC_LEAF :: 1
IDENTIFICATION_HIGHEST_EXTENDED_LEAF :: 0x8000_0001
IDENTIFICATION_BASIC_FEATURES_EDX :: u32(1 << 0 | 1 << 4 | 1 << 5 | 1 << 8 | 1 << 15 | 1 << 24 | 1 << 25 | 1 << 26) // x87, rdtsc, rdmsr, cmpxchg8b, cmov, fxsave, SSE, SSE2.
IDENTIFICATION_EXTENDED_FEATURES_EDX :: u32(1 << 11 | 1 << 20 | 1 << 29) // syscall, no-execute, long mode.

processor_identification_read :: proc "contextless" (leaf, subleaf: u32) -> (eax, ebx, ecx, edx: u32) {
	switch leaf {
	case 0:
		return IDENTIFICATION_HIGHEST_BASIC_LEAF, 0, 0, 0
	case 1:
		return 0, 0, 0, IDENTIFICATION_BASIC_FEATURES_EDX
	case 0x8000_0000:
		return IDENTIFICATION_HIGHEST_EXTENDED_LEAF, 0, 0, 0
	case 0x8000_0001:
		return 0, 0, 0, IDENTIFICATION_EXTENDED_FEATURES_EDX
	}
	return 0, 0, 0, 0
}

// The memory of a process is not at its own addresses in the linear
// memory: a pointer of 32 bits cannot hold an address of a process. So the
// copy walks the table of cr3 in software, with the checks of the processor
// for a user access (browser_machine.md, "What the arch layer becomes").
// The caller checked the range under the process lock (user_range), so a
// refused walk is a fault of the kernel: the instance stops, as a page
// fault of the kernel in its copy stops a processor of x86-64.
user_copy_from_process :: proc "contextless" (destination: rawptr, process_source: u64, count: u64) {
	if count == 0 {
		return
	}
	if !process_memory.copy_from_process(linear_memory(), software_processor.cr3, process_source, ([^]u8)(destination)[:count]) {
		intrinsics.trap()
	}
}

user_copy_to_process :: proc "contextless" (process_destination: u64, source: rawptr, count: u64) {
	if count == 0 {
		return
	}
	if !process_memory.copy_to_process(linear_memory(), software_processor.cr3, process_destination, ([^]u8)(source)[:count]) {
		intrinsics.trap()
	}
}

WEBASSEMBLY_PAGE_SIZE :: u64(65536)

// linear_memory is the physical memory of the machine: the whole linear
// memory, from offset 0 (boot_info.DIRECT_MAP_POINTER_BASE).
linear_memory :: #force_inline proc "contextless" () -> []u8 {
	memory_start: [^]u8
	return memory_start[:u64(intrinsics.wasm_memory_size(0)) * WEBASSEMBLY_PAGE_SIZE]
}
